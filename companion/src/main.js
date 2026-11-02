import dgram from 'node:dgram'
import { InstanceBase, InstanceStatus, Regex } from '@companion-module/base'

const PAD4 = (length) => (length + 3) & ~3
const MIXER_CHOICES = [
	{ id: '1', label: 'Mixer 1' },
	{ id: '2', label: 'Mixer 2' },
]
const MIXER_STRIP_CHOICES = [
	...Array.from({ length: 16 }, (_, index) => ({
		id: String(index + 1),
		label: `Input ${index + 1}`,
	})),
	{ id: 'return', label: 'Return' },
	{ id: 'master', label: 'Master' },
]
const ROUTE_SOURCES = [
	{ id: 236, label: 'None' },
	...Array.from({ length: 8 }, (_, i) => ({ id: 32 + i, label: `Analog In ${i + 1}` })),
	...Array.from({ length: 8 }, (_, i) => ({ id: 40 + i, label: `Optical In ${i + 1}` })),
	...Array.from({ length: 16 }, (_, i) => ({ id: 192 + i, label: `DAW ${i + 1}` })),
	{ id: 64, label: 'Mixer 1 L' },
	{ id: 65, label: 'Mixer 1 R' },
	{ id: 96, label: 'Mixer 2 L' },
	{ id: 97, label: 'Mixer 2 R' },
]
const ROUTE_DESTINATIONS = [
	...Array.from({ length: 8 }, (_, i) => ({ id: 32 + i, label: `Analog Out ${i + 1}` })),
	...Array.from({ length: 8 }, (_, i) => ({ id: 40 + i, label: `Optical Out ${i + 1}` })),
	...Array.from({ length: 16 }, (_, i) => ({ id: 208 + i, label: `To Mac ${i + 1}` })),
	{ id: 224, label: 'Headphone 1 L' },
	{ id: 225, label: 'Headphone 1 R' },
	{ id: 226, label: 'Headphone 2 L' },
	{ id: 227, label: 'Headphone 2 R' },
	...Array.from({ length: 16 }, (_, i) => ({ id: 64 + i, label: `Mixer 1 Input ${i + 1}` })),
	...Array.from({ length: 16 }, (_, i) => ({ id: 96 + i, label: `Mixer 2 Input ${i + 1}` })),
]
function oscString(value) {
	const bytes = Buffer.from(`${value}\0`, 'utf8')
	const padded = Buffer.alloc(PAD4(bytes.length))
	bytes.copy(padded)
	return padded
}

function encodeMessage(path, value) {
	let tag = ''
	let payload = Buffer.alloc(0)
	if (typeof value === 'string') {
		tag = 's'
		payload = oscString(value)
	} else if (Number.isInteger(value)) {
		tag = 'i'
		payload = Buffer.alloc(4)
		payload.writeInt32BE(value)
	} else if (typeof value === 'number') {
		tag = 'f'
		payload = Buffer.alloc(4)
		payload.writeFloatBE(value)
	} else {
		tag = ''
	}

	return Buffer.concat([oscString(path), oscString(`,${tag}`), payload])
}

function readString(buffer, offset) {
	const end = buffer.indexOf(0, offset)
	if (end < 0) throw new Error('Malformed OSC string')
	return [buffer.toString('utf8', offset, end), offset + PAD4(end - offset + 1)]
}

function decodeMessage(buffer) {
	let offset = 0
	const [path, afterPath] = readString(buffer, offset)
	offset = afterPath
	if (!path.startsWith('/')) throw new Error('Malformed OSC address')
	if (offset >= buffer.length) return { path, args: [] }

	const [tags, afterTags] = readString(buffer, offset)
	offset = afterTags
	if (!tags.startsWith(',')) throw new Error('Malformed OSC type tag')
	const args = []
	for (const tag of tags.slice(1)) {
		if (tag === 'i' || tag === 'f') {
			if (offset + 4 > buffer.length) throw new Error('Truncated OSC argument')
			args.push(tag === 'i' ? buffer.readInt32BE(offset) : buffer.readFloatBE(offset))
			offset += 4
		} else if (tag === 's') {
			const [value, next] = readString(buffer, offset)
			args.push(value)
			offset = next
		} else if (tag === 'T') {
			args.push(1)
		} else if (tag === 'F') {
			args.push(0)
		} else {
			throw new Error(`Unsupported OSC type: ${tag}`)
		}
	}
	return { path, args }
}

export default class AntiSymphonyInstance extends InstanceBase {
	constructor(internal) {
		super(internal)
		this.values = new Map()
		this.socket = undefined
		this.renewTimer = undefined
		this.meterTimer = undefined
		this.responseTimer = undefined
		this.target = undefined
	}

	async init(config) {
		this.config = config
		this.updateActions()
		this.updateFeedbacks()
		this.updatePresets()
		this.updateVariableDefinitions()
		this.connect()
	}

	async destroy() {
		this.disconnect()
	}

	async configUpdated(config) {
		this.config = config
		this.setVariableValues({ project_id: config.projectId ?? '' })
		this.connect()
	}

	getConfigFields() {
		return [
			{
				type: 'textinput',
				id: 'host',
				label: 'Target IP',
				width: 8,
				default: '127.0.0.1',
				regex: Regex.IP,
			},
			{
				type: 'textinput',
				id: 'port',
				label: 'Target Port',
				width: 4,
				default: '7100',
				regex: Regex.PORT,
			},
			{
				type: 'textinput',
				id: 'projectId',
				label: 'Project ID',
				width: 8,
				default: '',
			},
		]
	}

	connect() {
		this.disconnect()
		const host = this.config.host?.trim() || '127.0.0.1'
		const port = Number(this.config.port) || 7100
		this.target = { host, port }
		this.updateStatus(InstanceStatus.Connecting)

		this.socket = dgram.createSocket('udp4')
		this.socket.on('error', (error) => {
			this.log('error', `OSC socket error: ${error.message}`)
			this.updateStatus(InstanceStatus.ConnectionFailure, error.message)
		})
		this.socket.on('message', (message) => this.handleMessage(message))
		this.socket.bind(0, '0.0.0.0', () => {
			this.subscribe()
			this.renewTimer = setInterval(() => this.subscribe(), 20000)
			this.send('/symphony/meters/subscribe')
			this.meterTimer = setInterval(() => this.send('/symphony/meters/subscribe'), 5000)
		})
	}

	subscribe() {
		if (!this.socket) return
		if (this.responseTimer) clearTimeout(this.responseTimer)
		this.send('/symphony/subscribe')
		const { host, port } = this.target
		this.responseTimer = setTimeout(() => {
			this.updateStatus(
				InstanceStatus.ConnectionFailure,
				`No OSC reply from ${host}:${port}. Check the address, port, and symphonyd bind settings.`,
			)
		}, 5000)
	}

	disconnect() {
		if (this.renewTimer) clearInterval(this.renewTimer)
		this.renewTimer = undefined
		if (this.meterTimer) clearInterval(this.meterTimer)
		this.meterTimer = undefined
		if (this.responseTimer) clearTimeout(this.responseTimer)
		this.responseTimer = undefined
		if (this.socket) {
			this.socket.removeAllListeners()
			try {
				this.socket.close()
			} catch (error) {
				if (error.code !== 'ERR_SOCKET_DGRAM_NOT_RUNNING') {
					this.log('warn', `Could not close OSC socket: ${error.message}`)
				}
			}
			this.socket = undefined
		}
	}

	send(path, value) {
		if (!this.socket || !this.target) return
		const packet = encodeMessage(path, value)
		this.socket.send(packet, this.target.port, this.target.host, (error) => {
			if (error) {
				this.log('error', `Could not send ${path}: ${error.message}`)
				this.updateStatus(InstanceStatus.ConnectionFailure, error.message)
			}
		})
	}

	handleMessage(message) {
		try {
			if (this.responseTimer) clearTimeout(this.responseTimer)
			this.responseTimer = undefined
			const { path, args } = decodeMessage(message)
			if (path === '/symphony/connected') {
				this.values.set(path, args[0])
				this.updateStatus(InstanceStatus.Ok)
				this.checkFeedbacks('symphony_connected')
				this.setVariableValues({ connected: args[0] === 1 ? 'Connected' : 'Disconnected' })
				return
			}
			if (path === '/symphony/error') {
				this.updateStatus(InstanceStatus.Ok)
				this.log('warn', `Anti-Symphony rejected ${args[0] ?? 'OSC command'}: ${args[1] ?? 'unknown error'}`)
				this.setVariableValues({ last_error: `${args[0] ?? ''}: ${args[1] ?? 'unknown error'}` })
				return
			}
			if (path === '/symphony/profiles') {
				this.setVariableValues({ profiles: String(args[0] ?? '').replaceAll('\n', ', ') })
				return
			}
			if (path === '/symphony/meters/in') {
				const meters = {}
				args.forEach((value, index) => {
					meters[`input_${index + 1}_meter`] = `${Number(value).toFixed(1)} dBFS`
				})
				this.setVariableValues(meters)
				return
			}
			if (args.length > 0 && typeof args[0] === 'number') {
				this.values.set(path, args[0])
				this.checkAllFeedbacks()
			}
			this.updateVariables()
			this.updateStatus(InstanceStatus.Ok)
		} catch (error) {
			this.log('warn', `Ignoring malformed OSC response: ${error.message}`)
		}
	}

	updateVariables() {
		this.setVariableValues({
			main_level: this.values.get('/symphony/monitor/main/level') ?? '',
			main_muted: this.values.get('/symphony/monitor/main/mute') === 1 ? 'Muted' : 'Unmuted',
			hp1_level: this.values.get('/symphony/monitor/hp/1/level') ?? '',
			hp2_level: this.values.get('/symphony/monitor/hp/2/level') ?? '',
		})
	}

	updateActions() {
		const mixerChoices = MIXER_CHOICES
		const stripChoices = MIXER_STRIP_CHOICES
		const routeSources = ROUTE_SOURCES
		const mixerOptions = [
			{ type: 'dropdown', id: 'mixer', label: 'Mixer', default: '1', choices: mixerChoices },
			{ type: 'dropdown', id: 'strip', label: 'Strip', default: '1', choices: stripChoices },
		]

		this.setActionDefinitions({
			set_monitor_level: {
				name: 'Set monitor level',
				options: [
					{
						type: 'dropdown',
						id: 'output',
						label: 'Output',
						default: 'main',
						choices: [
							{ id: 'main', label: 'Main output' },
							{ id: '1', label: 'Headphone 1' },
							{ id: '2', label: 'Headphone 2' },
						],
					},
					{ type: 'number', id: 'level', label: 'Level (dB)', default: 0, min: -64, max: 0, step: 1 },
				],
				callback: ({ options }) => {
					const path = options.output === 'main'
						? '/symphony/monitor/main/level'
						: `/symphony/monitor/hp/${options.output}/level`
					this.send(path, Number(options.level))
				},
			},
			adjust_monitor_level: {
				name: 'Adjust monitor level',
				options: [
					{
						type: 'dropdown',
						id: 'output',
						label: 'Output',
						default: 'main',
						choices: [
							{ id: 'main', label: 'Main output' },
							{ id: '1', label: 'Headphone 1' },
							{ id: '2', label: 'Headphone 2' },
						],
					},
					{ type: 'dropdown', id: 'direction', label: 'Direction', default: 'inc', choices: [
						{ id: 'inc', label: 'Up' },
						{ id: 'dec', label: 'Down' },
					] },
					{ type: 'number', id: 'step', label: 'Step (dB)', default: 1, min: 1, max: 12, step: 1 },
				],
				callback: ({ options }) => {
					const base = options.output === 'main'
						? '/symphony/monitor/main/level'
						: `/symphony/monitor/hp/${options.output}/level`
					this.send(`${base}/${options.direction}`, Number(options.step))
				},
			},
			set_route: {
				name: 'Set routing destination source',
				options: [
					{ type: 'dropdown', id: 'destination', label: 'Destination', default: 32, choices: ROUTE_DESTINATIONS },
					{ type: 'dropdown', id: 'source', label: 'Source', default: 236, choices: ROUTE_SOURCES },
				],
				callback: ({ options }) => this.send(`/symphony/route/${Number(options.destination)}`, Number(options.source)),
			},
			set_headphone_mirror: {
				name: 'Set headphone feed or mirror',
				options: [
					{ type: 'dropdown', id: 'headphone', label: 'Headphone', default: '1', choices: [
						{ id: '1', label: 'Headphone 1' },
						{ id: '2', label: 'Headphone 2' },
					] },
					{ type: 'dropdown', id: 'outputPair', label: 'Mirror output pair', default: -1, choices: [
						{ id: -1, label: 'Use headphone feed routing' },
						...Array.from({ length: 8 }, (_, index) => ({
							id: 32 + index * 2,
							label: index < 4
								? `Analog Out ${index * 2 + 1}–${index * 2 + 2}`
								: `Optical Out ${(index - 4) * 2 + 1}–${(index - 4) * 2 + 2}`,
						})),
					] },
				],
				callback: ({ options }) => this.send(`/symphony/monitor/hp/${options.headphone}/mirror`, Number(options.outputPair)),
			},
			set_analog_input: {
				name: 'Set analog input reference level',
				options: [
					{ type: 'dropdown', id: 'channel', label: 'Input', default: 1, choices: Array.from({ length: 8 }, (_, i) => ({ id: i + 1, label: `Analog In ${i + 1}` })) },
					{ type: 'dropdown', id: 'value', label: 'Reference level', default: 2, choices: [
						{ id: 1, label: '−10 dBV' },
						{ id: 2, label: '+4 dBu' },
					] },
				],
				callback: ({ options }) => this.send(`/symphony/io/analog/in/${options.channel}/ref`, Number(options.value)),
			},
			set_softlimit: {
				name: 'Set analog input Soft Limit',
				options: [
					{ type: 'dropdown', id: 'channel', label: 'Input', default: 1, choices: Array.from({ length: 8 }, (_, i) => ({ id: i + 1, label: `Analog In ${i + 1}` })) },
					{ type: 'dropdown', id: 'enabled', label: 'State', default: 1, choices: [
						{ id: 1, label: 'On' },
						{ id: 0, label: 'Off' },
					] },
				],
				callback: ({ options }) => this.send(`/symphony/io/analog/in/${options.channel}/softlimit`, Number(options.enabled)),
			},
			set_analog_output: {
				name: 'Set analog output reference level',
				options: [
					{ type: 'dropdown', id: 'channel', label: 'Output', default: 1, choices: Array.from({ length: 8 }, (_, i) => ({ id: i + 1, label: `Analog Out ${i + 1}` })) },
					{ type: 'dropdown', id: 'value', label: 'Reference level', default: 2, choices: [
						{ id: 0, label: 'Default (+1 dBu)' },
						{ id: 1, label: '−10 dBV' },
						{ id: 2, label: '+4 dBu' },
					] },
				],
				callback: ({ options }) => this.send(`/symphony/io/analog/out/${options.channel}/ref`, Number(options.value)),
			},
			set_optical_mode: {
				name: 'Set optical input mode',
				options: [{ type: 'dropdown', id: 'mode', label: 'Mode', default: 0, choices: [
					{ id: 0, label: 'ADAT' },
					{ id: 1, label: 'S/PDIF' },
				] }],
				callback: ({ options }) => this.send('/symphony/io/optical/spdif', Number(options.mode)),
			},
			set_raw_monitor_control: {
				name: 'Set raw monitor mode or speaker selection',
				options: [
					{ type: 'dropdown', id: 'control', label: 'Control', default: 'mode', choices: [
						{ id: 'mode', label: 'Main output mode' },
						{ id: 'speakerset', label: 'Speaker set' },
						{ id: 'frontpanel', label: 'Front-panel output selection' },
					] },
					{ type: 'number', id: 'value', label: 'Value (raw)', default: 0, min: 0, max: 255, step: 1 },
				],
				callback: ({ options }) => {
					const path = options.control === 'mode'
						? '/symphony/monitor/main/mode'
						: `/symphony/monitor/${options.control}`
					this.send(path, Number(options.value))
				},
			},
			set_clock_rate: {
				name: 'Set sample rate',
				options: [{ type: 'dropdown', id: 'rate', label: 'Sample rate', default: 48000, choices: [
					{ id: 44100, label: '44.1 kHz' },
					{ id: 48000, label: '48 kHz' },
					{ id: 88200, label: '88.2 kHz' },
					{ id: 96000, label: '96 kHz' },
				] }],
				callback: ({ options }) => this.send('/symphony/clock/rate', Number(options.rate)),
			},
			adjust_mixer_fader: {
				name: 'Adjust mixer fader',
				options: [
					...mixerOptions,
					{ type: 'dropdown', id: 'direction', label: 'Direction', default: 'inc', choices: [
						{ id: 'inc', label: 'Up' },
						{ id: 'dec', label: 'Down' },
					] },
					{ type: 'number', id: 'step', label: 'Step (dB)', default: 1, min: 1, max: 12, step: 1 },
				],
				callback: ({ options }) => this.send(
					`/symphony/mixer/${options.mixer}/${options.strip}/fader/${options.direction}`,
					Number(options.step),
				),
			},
			set_monitor_switch: {
				name: 'Set monitor mute, dim, or mono',
				options: [
					{
						type: 'dropdown',
						id: 'output',
						label: 'Output',
						default: 'main',
						choices: [
							{ id: 'main', label: 'Main output' },
							{ id: '1', label: 'Headphone 1' },
							{ id: '2', label: 'Headphone 2' },
						],
					},
					{
						type: 'dropdown',
						id: 'control',
						label: 'Control',
						default: 'mute',
						choices: [
							{ id: 'mute', label: 'Mute' },
							{ id: 'dim', label: 'Dim' },
							{ id: 'mono', label: 'Mono' },
						],
					},
					{
						type: 'dropdown',
						id: 'enabled',
						label: 'State',
						default: '1',
						choices: [
							{ id: '1', label: 'On' },
							{ id: '0', label: 'Off' },
						],
					},
				],
				callback: ({ options }) => {
					const base = options.output === 'main'
						? '/symphony/monitor/main'
						: `/symphony/monitor/hp/${options.output}`
					this.send(`${base}/${options.control}`, Number(options.enabled))
				},
			},
			toggle_monitor_switch: {
				name: 'Toggle monitor mute, dim, or mono',
				options: [
					{
						type: 'dropdown',
						id: 'output',
						label: 'Output',
						default: 'main',
						choices: [
							{ id: 'main', label: 'Main output' },
							{ id: '1', label: 'Headphone 1' },
							{ id: '2', label: 'Headphone 2' },
						],
					},
					{
						type: 'dropdown',
						id: 'control',
						label: 'Control',
						default: 'mute',
						choices: [
							{ id: 'mute', label: 'Mute' },
							{ id: 'dim', label: 'Dim' },
							{ id: 'mono', label: 'Mono' },
						],
					},
				],
				callback: ({ options }) => {
					const base = options.output === 'main'
						? '/symphony/monitor/main'
						: `/symphony/monitor/hp/${options.output}`
					this.send(`${base}/${options.control}/toggle`)
				},
			},
			set_mixer_fader: {
				name: 'Set mixer fader',
				options: [
					...mixerOptions,
					{ type: 'number', id: 'value', label: 'Level (dB)', default: 0, min: -48, max: 0, step: 1 },
				],
				callback: ({ options }) => {
					this.send(`/symphony/mixer/${options.mixer}/${options.strip}/fader`, Number(options.value))
				},
			},
			set_mixer_pan: {
				name: 'Set mixer pan',
				options: [
					...mixerOptions,
					{ type: 'number', id: 'value', label: 'Pan (−1 left to 1 right)', default: 0, min: -1, max: 1, step: 0.05 },
				],
				callback: ({ options }) => {
					this.send(`/symphony/mixer/${options.mixer}/${options.strip}/pan`, Number(options.value))
				},
			},
			set_mixer_switch: {
				name: 'Set mixer mute or solo',
				options: [
					{ ...mixerOptions[0] },
					{
						type: 'dropdown',
						id: 'channel',
						label: 'Input',
						default: '1',
						choices: stripChoices.slice(0, 16),
					},
					{
						type: 'dropdown',
						id: 'control',
						label: 'Control',
						default: 'mute',
						choices: [
							{ id: 'mute', label: 'Mute' },
							{ id: 'solo', label: 'Solo' },
						],
					},
					{
						type: 'dropdown',
						id: 'enabled',
						label: 'State',
						default: '1',
						choices: [
							{ id: '1', label: 'On' },
							{ id: '0', label: 'Off' },
						],
					},
				],
				callback: ({ options }) => {
					this.send(`/symphony/mixer/${options.mixer}/in/${options.channel}/${options.control}`, Number(options.enabled))
				},
			},
			set_mixer_strip_switch: {
				name: 'Set mixer strip mute or solo',
				options: [
					{ ...mixerOptions[0] },
					{ type: 'dropdown', id: 'strip', label: 'Strip', default: 'return', choices: stripChoices },
					{ type: 'dropdown', id: 'control', label: 'Control', default: 'mute', choices: [
						{ id: 'mute', label: 'Mute' },
						{ id: 'solo', label: 'Solo' },
					] },
					{ type: 'dropdown', id: 'enabled', label: 'State', default: 1, choices: [
						{ id: 1, label: 'On' },
						{ id: 0, label: 'Off' },
					] },
				],
				callback: ({ options }) => this.send(
					`/symphony/mixer/${options.mixer}/${options.strip}/${options.control}`,
					Number(options.enabled),
				),
			},
			toggle_mixer_strip_switch: {
				name: 'Toggle mixer strip mute or solo',
				options: [
					{ ...mixerOptions[0] },
					{ type: 'dropdown', id: 'strip', label: 'Strip', default: 'return', choices: stripChoices },
					{ type: 'dropdown', id: 'control', label: 'Control', default: 'mute', choices: [
						{ id: 'mute', label: 'Mute' },
						{ id: 'solo', label: 'Solo' },
					] },
				],
				callback: ({ options }) => this.send(
					`/symphony/mixer/${options.mixer}/${options.strip}/${options.control}/toggle`,
				),
			},
			toggle_mixer_switch: {
				name: 'Toggle mixer mute or solo',
				options: [
					{ ...mixerOptions[0] },
					{
						type: 'dropdown',
						id: 'channel',
						label: 'Input',
						default: '1',
						choices: stripChoices.slice(0, 16),
					},
					{
						type: 'dropdown',
						id: 'control',
						label: 'Control',
						default: 'mute',
						choices: [
							{ id: 'mute', label: 'Mute' },
							{ id: 'solo', label: 'Solo' },
						],
					},
				],
				callback: ({ options }) => {
					this.send(`/symphony/mixer/${options.mixer}/in/${options.channel}/${options.control}/toggle`)
				},
			},
			set_mixer_source: {
				name: 'Set mixer input source',
				options: [
					{ ...mixerOptions[0] },
					{
						type: 'dropdown',
						id: 'channel',
						label: 'Mixer input',
						default: '1',
						choices: stripChoices.slice(0, 16),
					},
					{
						type: 'dropdown',
						id: 'source',
						label: 'Source',
						default: 236,
						choices: routeSources,
					},
				],
				callback: ({ options }) => {
					const destination = (options.mixer === '1' ? 64 : 96) + Number(options.channel) - 1
					this.send(`/symphony/route/${destination}`, Number(options.source))
				},
			},
			load_profile: {
				name: 'Load profile',
				options: [{ type: 'textinput', id: 'name', label: 'Profile name', default: '' }],
				callback: ({ options }) => this.send('/symphony/profile/load', String(options.name)),
			},
			save_profile: {
				name: 'Save profile',
				options: [{ type: 'textinput', id: 'name', label: 'Profile name', default: '' }],
				callback: ({ options }) => this.send('/symphony/profile/save', String(options.name)),
			},
			delete_profile: {
				name: 'Delete profile',
				options: [{ type: 'textinput', id: 'name', label: 'Profile name', default: '' }],
				callback: ({ options }) => this.send('/symphony/profile/delete', String(options.name)),
			},
			refresh_state: {
				name: 'Refresh all Symphony state',
				options: [],
				callback: () => this.send('/symphony/dump'),
			},
			subscribe_meters: {
				name: 'Subscribe to input meters',
				options: [],
				callback: () => this.send('/symphony/meters/subscribe'),
			},
			list_profiles: {
				name: 'Refresh profile list',
				options: [],
				callback: () => this.send('/symphony/profile/list'),
			},
			identify: {
				name: 'Identify Symphony (blink front panel)',
				options: [],
				callback: () => this.send('/symphony/identify', 1),
			},
		})
	}

	updateFeedbacks() {
		this.setFeedbackDefinitions({
			symphony_connected: {
				type: 'boolean',
				name: 'Symphony is connected',
				defaultStyle: { bgcolor: 0x008000, color: 0xffffff },
				options: [],
				callback: () => this.values.get('/symphony/connected') === 1,
			},
			monitor_switch: {
				type: 'boolean',
				name: 'Monitor mute, dim, or mono is on',
				defaultStyle: { bgcolor: 0xff0000, color: 0xffffff },
				options: [
					{
						type: 'dropdown',
						id: 'output',
						label: 'Output',
						default: 'main',
						choices: [
							{ id: 'main', label: 'Main output' },
							{ id: '1', label: 'Headphone 1' },
							{ id: '2', label: 'Headphone 2' },
						],
					},
					{
						type: 'dropdown',
						id: 'control',
						label: 'Control',
						default: 'mute',
						choices: [
							{ id: 'mute', label: 'Mute' },
							{ id: 'dim', label: 'Dim' },
							{ id: 'mono', label: 'Mono' },
						],
					},
				],
				callback: ({ options }) => {
					const base = options.output === 'main'
						? '/symphony/monitor/main'
						: `/symphony/monitor/hp/${options.output}`
					return this.values.get(`${base}/${options.control}`) === 1
				},
			},
			mixer_switch: {
				type: 'boolean',
				name: 'Mixer input mute or solo is on',
				defaultStyle: { bgcolor: 0xff8000, color: 0x000000 },
				options: [
					{ type: 'dropdown', id: 'mixer', label: 'Mixer', default: '1', choices: MIXER_CHOICES },
					{ type: 'dropdown', id: 'channel', label: 'Input', default: '1', choices: MIXER_STRIP_CHOICES.slice(0, 16) },
					{
						type: 'dropdown',
						id: 'control',
						label: 'Control',
						default: 'mute',
						choices: [
							{ id: 'mute', label: 'Mute' },
							{ id: 'solo', label: 'Solo' },
						],
					},
				],
				callback: ({ options }) =>
					this.values.get(`/symphony/mixer/${options.mixer}/in/${options.channel}/${options.control}`) === 1,
			},
		})
	}

	updatePresets() {
		const presets = {}
		const sections = []
		const colors = { white: 0xffffff, green: 0x008000, red: 0x800000, blue: 0x004080, orange: 0x804000 }
		const groups = new Map()

		const addPreset = (section, id, name, text, actionId, options, color = colors.white, bgcolor = 0x202020) => {
			const feedbacks = []
			if (actionId === 'toggle_monitor_switch') {
				feedbacks.push({
					feedbackId: 'monitor_switch',
					options: { output: options.output, control: options.control },
					style: { color: colors.white, bgcolor },
				})
			} else if (actionId === 'toggle_mixer_strip_switch' && /^\d+$/.test(options.strip)) {
				feedbacks.push({
					feedbackId: 'mixer_switch',
					options: { mixer: options.mixer, channel: options.strip, control: options.control },
					style: { color: colors.white, bgcolor },
				})
			}
			presets[id] = {
				type: 'simple',
				name,
				style: { text, size: 'auto', color, bgcolor },
				steps: [{ down: [{ actionId, options }], up: [] }],
				feedbacks,
			}
			if (!groups.has(section)) groups.set(section, [])
			groups.get(section).push(id)
		}

		addPreset(
			'Monitoring',
			'main_mute',
			'Main mute toggle',
			'Main\\nMute',
			'toggle_monitor_switch',
			{ output: 'main', control: 'mute' },
			colors.white,
			colors.red,
		)
		addPreset(
			'Monitoring',
			'main_dim',
			'Main dim toggle',
			'Main\\nDim',
			'toggle_monitor_switch',
			{ output: 'main', control: 'dim' },
		)
		addPreset(
			'Monitoring',
			'main_mono',
			'Main mono toggle',
			'Main\\nMono',
			'toggle_monitor_switch',
			{ output: 'main', control: 'mono' },
		)
		for (const direction of ['inc', 'dec']) {
			addPreset(
				'Monitoring',
				`main_level_${direction}`,
				`Main level ${direction === 'inc' ? 'up' : 'down'} 1 dB`,
				direction === 'inc' ? 'Main\\nVol +' : 'Main\\nVol -',
				'adjust_monitor_level',
				{ output: 'main', direction, step: 1 },
			)
		}
		for (const headphone of ['1', '2']) {
			for (const control of ['mute', 'dim', 'mono']) {
				addPreset(
					'Monitoring',
					`hp${headphone}_${control}`,
					`Headphone ${headphone} ${control} toggle`,
					`HP ${headphone}\\n${control}`,
					'toggle_monitor_switch',
					{ output: headphone, control },
					colors.white,
					control === 'mute' ? colors.red : 0x202020,
				)
			}
			for (const direction of ['inc', 'dec']) {
				addPreset(
					'Monitoring',
					`hp${headphone}_level_${direction}`,
					`Headphone ${headphone} level ${direction === 'inc' ? 'up' : 'down'} 1 dB`,
					`HP ${headphone}\\nVol ${direction === 'inc' ? '+' : '-'}`,
					'adjust_monitor_level',
					{ output: headphone, direction, step: 1 },
				)
			}
		}

		for (const mixer of ['1', '2']) {
			for (const strip of MIXER_STRIP_CHOICES) {
				const name = strip.label
				const value = strip.id
				for (const control of ['mute', 'solo']) {
					addPreset(
						`Mixer ${mixer}`,
						`m${mixer}_${value}_${control}`,
						`Mixer ${mixer} ${name} ${control} toggle`,
						`M${mixer} ${name}\\n${control}`,
						'toggle_mixer_strip_switch',
						{ mixer, strip: value, control },
						colors.white,
						control === 'mute' ? colors.red : 0x604000,
					)
				}
				for (const direction of ['inc', 'dec']) {
					addPreset(
						`Mixer ${mixer}`,
						`m${mixer}_${value}_fader_${direction}`,
						`Mixer ${mixer} ${name} fader ${direction === 'inc' ? 'up' : 'down'} 1 dB`,
						`M${mixer} ${name}\\nFader ${direction === 'inc' ? '+' : '-'}`,
						'adjust_mixer_fader',
						{ mixer, strip: value, direction, step: 1 },
					)
				}
				for (const level of [-48, -24, -12, -6, 0]) {
					addPreset(
						`Mixer ${mixer}`,
						`m${mixer}_${value}_level_${Math.abs(level)}`,
						`Mixer ${mixer} ${name} fader ${level} dB`,
						`M${mixer} ${name}\\n${level} dB`,
						'set_mixer_fader',
						{ mixer, strip: value, value: level },
					)
				}
				for (const pan of [-1, 0, 1]) {
					addPreset(
						`Mixer ${mixer}`,
						`m${mixer}_${value}_pan_${pan + 1}`,
						`Mixer ${mixer} ${name} pan ${pan}`,
						`M${mixer} ${name}\\nPan ${pan}`,
						'set_mixer_pan',
						{ mixer, strip: value, value: pan },
					)
				}
				if (/^\d+$/.test(value)) {
					const input = Number(value)
					addPreset(
						`Mixer ${mixer}`,
						`m${mixer}_in${input}_source`,
						`Mixer ${mixer} input ${input} source (edit after adding)`,
						`M${mixer} In ${input}\\nSource`,
						'set_mixer_source',
						{ mixer, channel: value, source: 236 },
						colors.white,
						colors.blue,
					)
				}
			}
		}

		addPreset(
			'Profiles and system',
			'identify',
			'Identify Symphony',
			'Identify\\nSymphony',
			'identify',
			{},
			colors.white,
			colors.blue,
		)
		addPreset(
			'Profiles and system',
			'load_profile',
			'Load profile (edit name after adding)',
			'Load\\nProfile',
			'load_profile',
			{ name: '' },
			colors.white,
			colors.blue,
		)
		addPreset(
			'Profiles and system',
			'save_profile',
			'Save profile (edit name after adding)',
			'Save\\nProfile',
			'save_profile',
			{ name: '' },
			colors.white,
			colors.blue,
		)
		addPreset(
			'Profiles and system',
			'refresh_state',
			'Refresh state from symphonyd',
			'Refresh\\nState',
			'refresh_state',
			{},
			colors.white,
			colors.blue,
		)
		addPreset(
			'Profiles and system',
			'subscribe_meters',
			'Subscribe to input meters',
			'Input\\nMeters',
			'subscribe_meters',
			{},
			colors.white,
			colors.blue,
		)
		addPreset(
			'Profiles and system',
			'list_profiles',
			'Refresh available profiles',
			'Refresh\\nProfiles',
			'list_profiles',
			{},
			colors.white,
			colors.blue,
		)
		addPreset(
			'Profiles and system',
			'delete_profile',
			'Delete profile (edit name after adding)',
			'Delete\\nProfile',
			'delete_profile',
			{ name: '' },
			colors.white,
			colors.red,
		)

		for (const output of ['main', '1', '2']) {
			const label = output === 'main' ? 'Main' : `Headphone ${output}`
			for (const level of [-64, -40, -20, -10, 0]) {
				addPreset(
					'Monitoring',
					`level_${output}_${Math.abs(level)}`,
					`${label} level ${level} dB`,
					`${label}\\n${level} dB`,
					'set_monitor_level',
					{ output, level },
				)
			}
		}

		for (const [destination, label] of ROUTE_DESTINATIONS.map(({ id, label }) => [id, label])) {
			addPreset(
				'Routing',
				`route_${destination}`,
				`Route ${label} (edit source after adding)`,
				`Route\\n${label}`,
				'set_route',
				{ destination, source: 236 },
				colors.white,
				colors.blue,
			)
		}

		for (const headphone of ['1', '2']) {
			for (const outputPair of [-1, 32, 34, 36, 38, 40, 42, 44, 46]) {
				const name = outputPair < 0
					? 'Use own feed routing'
					: outputPair < 40
						? `Analog Out ${((outputPair - 32) / 2) * 2 + 1}–${((outputPair - 32) / 2) * 2 + 2}`
						: `Optical Out ${((outputPair - 40) / 2) * 2 + 1}–${((outputPair - 40) / 2) * 2 + 2}`
				addPreset(
					'Headphone feeds',
					`hp${headphone}_mirror_${outputPair}`,
					`Headphone ${headphone}: ${name}`,
					`HP ${headphone}\\n${name}`,
					'set_headphone_mirror',
					{ headphone, outputPair },
				)
			}
		}

		for (let input = 1; input <= 8; input++) {
			for (const [value, level] of [[1, '-10 dBV'], [2, '+4 dBu']]) {
				addPreset(
					'Analog I/O',
					`analog_in${input}_ref_${value}`,
					`Analog input ${input} reference: ${level}`,
					`In ${input}\\n${level}`,
					'set_analog_input',
					{ channel: input, value },
				)
			}
			for (const enabled of [0, 1]) {
				addPreset(
					'Analog I/O',
					`analog_in${input}_softlimit_${enabled}`,
					`Analog input ${input} Soft Limit ${enabled ? 'on' : 'off'}`,
					`In ${input}\\nSL ${enabled ? 'On' : 'Off'}`,
					'set_softlimit',
					{ channel: input, enabled },
					colors.white,
					enabled ? colors.green : 0x202020,
				)
			}
			for (const [value, level] of [[0, 'Default'], [1, '-10 dBV'], [2, '+4 dBu']]) {
				addPreset(
					'Analog I/O',
					`analog_out${input}_ref_${value}`,
					`Analog output ${input} reference: ${level}`,
					`Out ${input}\\n${level}`,
					'set_analog_output',
					{ channel: input, value },
				)
			}
		}
		for (const [mode, label] of [[0, 'ADAT'], [1, 'S/PDIF']]) {
			addPreset(
				'Analog I/O',
				`optical_mode_${mode}`,
				`Optical input mode: ${label}`,
				`Optical\\n${label}`,
				'set_optical_mode',
				{ mode },
			)
		}

		for (const [rate, label] of [[44100, '44.1 kHz'], [48000, '48 kHz'], [88200, '88.2 kHz'], [96000, '96 kHz']]) {
			addPreset('Clock', `clock_${rate}`, `Set sample rate to ${label}`, `Clock\\n${label}`, 'set_clock_rate', { rate })
		}
		for (const control of ['mode', 'speakerset', 'frontpanel']) {
			addPreset(
				'Monitoring',
				`raw_${control}`,
				`Set ${control} (edit raw value after adding)`,
				`${control}\\nSet value`,
				'set_raw_monitor_control',
				{ control, value: 0 },
			)
		}

		for (const [section, presetIds] of groups) {
			sections.push({ id: section.toLowerCase().replaceAll(' ', '_'), name: section, definitions: presetIds })
		}
		this.setPresetDefinitions(sections, presets)
	}

	updateVariableDefinitions() {
		const variables = {
			project_id: { name: 'Project ID' },
			connected: { name: 'Connection state' },
			main_level: { name: 'Main output level (dB)' },
			main_muted: { name: 'Main output mute' },
			hp1_level: { name: 'Headphone 1 level (dB)' },
			hp2_level: { name: 'Headphone 2 level (dB)' },
			profiles: { name: 'Available profiles' },
			last_error: { name: 'Last OSC error' },
		}
		for (let input = 1; input <= 32; input++) {
			variables[`input_${input}_meter`] = { name: `Input ${input} meter (dBFS)` }
		}
		this.setVariableDefinitions(variables)
		this.setVariableValues({
			project_id: this.config.projectId ?? '',
			connected: 'Waiting for symphonyd',
			last_error: '',
		})
	}
}
