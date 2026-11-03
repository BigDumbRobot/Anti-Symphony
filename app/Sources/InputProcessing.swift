import AVFoundation
import AudioToolbox
import SwiftUI

/// Input Processing: plugin inserts per input channel, with odd/even channels linkable into a
/// stereo pair (odd = left, even = right). A linked pair uses the stereo version of each plugin,
/// and settings carry over whenever a pair is linked or unlinked.
///
/// This holds the setup; the processing engine that runs it is described in docs/input-processor.md.
/// Saved in ~/Library/Application Support/Anti-Symphony/input-processing.json.
@MainActor
final class InputProcessing: ObservableObject {
    nonisolated static let slotsPerChannel = 4

    /// An Audio Unit, by its component description.
    struct Plugin: Codable, Hashable, Identifiable {
        var type: UInt32, subType: UInt32, manufacturer: UInt32
        var name: String, vendor: String
        var id: String { "\(type)-\(subType)-\(manufacturer)" }
    }

    struct Slot: Codable, Equatable {
        var plugin: Plugin?
        var bypass = false
        var state: Data?            // the plugin's saved settings (AU class info)
    }

    struct Channel: Codable, Equatable {
        var slots = Array(repeating: Slot(), count: InputProcessing.slotsPerChannel)
    }

    /// Channels 1–16: Analog In 1–8, Optical In 1–8.
    @Published private(set) var channels = Array(repeating: Channel(), count: 16)
    /// Linked pairs, by their odd (left) channel: 1, 3, 5 … 15.
    @Published private(set) var linked: Set<Int> = []
    @Published private(set) var available: [Plugin] = []
    @Published var problem: String?

    private let url: URL

    /// `url` and `plugins` are for tests: another file, and a fixed plugin list instead of this Mac's.
    init(url: URL = InputProcessing.defaultURL, plugins: [Plugin]? = nil) {
        self.url = url
        load()
        if let plugins { available = plugins } else { refreshPlugins() }
    }

    static func name(_ ch: Int) -> String { ch <= 8 ? "Analog \(ch)" : "Optical \(ch - 8)" }
    static func pairName(_ left: Int) -> String {
        left <= 8 ? "Analog \(left)–\(left + 1)" : "Optical \(left - 8)–\(left - 7)"
    }

    func isLinked(_ ch: Int) -> Bool { linked.contains(ch % 2 == 1 ? ch : ch - 1) }

    // MARK: plugins on this Mac

    func refreshPlugins() {
        var all: [Plugin] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let desc = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0,
                                                 componentFlags: 0, componentFlagsMask: 0)
            for c in AVAudioUnitComponentManager.shared().components(matching: desc) {
                let d = c.audioComponentDescription
                all.append(Plugin(type: d.componentType, subType: d.componentSubType, manufacturer: d.componentManufacturer,
                                  name: c.name, vendor: c.manufacturerName))
            }
        }
        available = all.sorted { ($0.vendor, $0.name) < ($1.vendor, $1.name) }
    }

    var vendors: [String] { Array(Set(available.map(\.vendor))).sorted() }

    /// Plugins with separate mono and stereo versions name them "X Mono" / "X Stereo", "X (m)" / "X (s)",
    /// "X mono" … This is the plugin's name without that suffix, and which width the suffix says.
    static func baseName(_ name: String) -> (base: String, width: Width?) {
        let n = name.trimmingCharacters(in: .whitespaces)
        let suffixes: [(String, Width)] = [
            (" (Mono)", .mono), (" (Stereo)", .stereo), (" (mono)", .mono), (" (stereo)", .stereo),
            (" Mono", .mono), (" Stereo", .stereo), (" mono", .mono), (" stereo", .stereo),
            (" (m)", .mono), (" (s)", .stereo), (" (M)", .mono), (" (S)", .stereo),
            (" Mono/Stereo", .stereo), (" (m/s)", .stereo)]
        for (s, w) in suffixes where n.hasSuffix(s) { return (String(n.dropLast(s.count)), w) }
        return (n, nil)
    }

    enum Width { case mono, stereo }

    /// The version of `p` for the given width: a sibling with the same vendor and base name, or `p`
    /// itself when the plugin handles both widths.
    func variant(of p: Plugin, _ width: Width) -> Plugin {
        let (base, w) = Self.baseName(p.name)
        guard w != nil, w != width else { return p }
        return available.first { $0.vendor == p.vendor && $0.manufacturer == p.manufacturer
            && Self.baseName($0.name).base == base && Self.baseName($0.name).width == width } ?? p
    }

    // MARK: editing

    func setPlugin(_ p: Plugin?, channel ch: Int, slot: Int) {
        let width: Width = isLinked(ch) ? .stereo : .mono
        let chosen = p.map { variant(of: $0, width) }
        for c in targets(ch) {
            channels[c - 1].slots[slot] = Slot(plugin: chosen)
        }
        save()
    }

    /// The plugin's saved settings (from its window), for the channel or the whole linked pair.
    func setState(_ data: Data, channel ch: Int, slot: Int) {
        guard channels[ch - 1].slots[slot].state != data else { return }
        for c in targets(ch) { channels[c - 1].slots[slot].state = data }
        save()
    }

    func toggleBypass(channel ch: Int, slot: Int) {
        for c in targets(ch) { channels[c - 1].slots[slot].bypass.toggle() }
        save()
    }

    /// Link or unlink an odd/even pair. Linking: the left channel's plugins become their stereo
    /// versions with the left channel's settings. Unlinking: both channels get the mono versions
    /// with the pair's settings.
    func setLinked(_ left: Int, _ on: Bool) {
        guard left % 2 == 1, left < 16 else { return }
        if on {
            var slots = channels[left - 1].slots
            for i in slots.indices {
                if slots[i].plugin == nil, let right = channels[left].slots[i].plugin {
                    slots[i] = channels[left].slots[i]; slots[i].plugin = right   // keep the right channel's plugin if the left slot was empty
                }
                slots[i].plugin = slots[i].plugin.map { variant(of: $0, .stereo) }
            }
            channels[left - 1].slots = slots
            channels[left].slots = slots
            linked.insert(left)
        } else {
            var slots = channels[left - 1].slots
            for i in slots.indices { slots[i].plugin = slots[i].plugin.map { variant(of: $0, .mono) } }
            channels[left - 1].slots = slots
            channels[left].slots = slots
            linked.remove(left)
        }
        save()
    }

    private func targets(_ ch: Int) -> [Int] {
        guard isLinked(ch) else { return [ch] }
        let l = ch % 2 == 1 ? ch : ch - 1
        return [l, l + 1]
    }

    // MARK: file

    private struct File: Codable { var channels: [Channel]; var linked: [Int] }

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anti-Symphony/input-processing.json")
    }

    private func load() {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d),
              f.channels.count == 16 else { return }
        channels = f.channels
        linked = Set(f.linked)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(File(channels: channels, linked: linked.sorted())) {
            try? d.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Page

struct InputProcessingView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var proc: InputProcessing
    @EnvironmentObject var cal: Calibration
    @EnvironmentObject var engine: FXEngine
    @State private var confirmPhones: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Choose plugins for each input and open them with the slider button; their settings are saved with the slot. Link a pair (odd = left, even = right) to use the stereo versions; settings carry over either way. Inputs with plugins are processed live by Symphony Control (no DAW needed) and reach the DAW processed on the same input number (1:1); the dry copy moves to a spare input. Zero-latency monitoring stays dry on Bus A / Bus B.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Rescan Plugins") { proc.refreshPlugins() }.controlSize(.small)
            }
            .padding([.horizontal, .top])
            engineBar.padding(.horizontal).padding(.top, 8)
            if let p = proc.problem {
                HStack {
                    Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                    Button("Dismiss") { proc.problem = nil }.buttonStyle(.borderless).font(.caption)
                }
                .padding(.horizontal).padding(.top, 6)
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(stride(from: 1, through: 15, by: 2)), id: \.self) { left in
                        if left == 9 { Divider() }
                        pair(left)
                    }
                }
                .padding()
            }
        }
        .wantsMeters()
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmPhones != nil }, set: { if !$0 { confirmPhones = nil } }),
                            titleVisibility: .visible) {
            Button("Send Processed to Headphones") { if let c = confirmPhones { engine.setProcessedInPhones(c, true) }; confirmPhones = nil }
        } message: {
            Text("The headphones will hear this input after your plugins, about \(latencyText) late because it goes through the Mac. Dry (zero latency) is one click away.")
        }
    }

    private var latencyText: String { engine.roundTripMs.map { String(format: "%.1f ms", $0) } ?? "5 ms" }
    private var confirmTitle: String {
        guard let c = confirmPhones else { return "" }
        return "Hear \(proc.isLinked(c) ? InputProcessing.pairName(c % 2 == 1 ? c : c - 1) : InputProcessing.name(c)) processed in the headphones?"
    }

    /// Dry (zero latency) or processed (through the Mac) in the headphone mixes.
    @ViewBuilder private func phonesButton(_ ch: Int) -> some View {
        let wet = engine.processedInPhones(ch)
        let used = engine.inPhones(ch)
        Button {
            if wet { engine.setProcessedInPhones(ch, false) } else { confirmPhones = ch }
        } label: {
            Label(wet ? "Phones: processed (+\(latencyText))" : "Phones: dry (0 ms)",
                  systemImage: wet ? "headphones.circle.fill" : "headphones")
                .font(.caption2)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(wet ? .orange : nil)
        .disabled(!used)
        .help(used ? (wet ? "Back to dry: zero latency, before the plugins." : "Send the processed signal to the headphone mixes instead of the dry input.")
                   : "This input isn't in a headphone mix (Headphone Mixes page or a headphone feed).")
    }

    @ViewBuilder
    private func pair(_ left: Int) -> some View {
        let isLinked = proc.isLinked(left)
        VStack(spacing: 6) {
            Button {
                proc.setLinked(left, !isLinked)
            } label: {
                Label(isLinked ? "Stereo" : "Link", systemImage: isLinked ? "link" : "link.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(isLinked ? .accentColor : nil)
            .help(isLinked ? "Unlink: back to two mono channels (mono plugin versions, same settings)"
                           : "Link \(InputProcessing.name(left)) and \(InputProcessing.name(left + 1)) as a stereo pair")
            if isLinked {
                strip(left, title: InputProcessing.pairName(left), stereo: true)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    strip(left, title: InputProcessing.name(left), stereo: false)
                    strip(left + 1, title: InputProcessing.name(left + 1), stereo: false)
                }
            }
        }
    }

    private func strip(_ ch: Int, title: String, stereo: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption).bold()
                Spacer()
                if stereo { Text("ST").font(.caption2).bold().foregroundStyle(Color.accentColor) }
            }
            HStack(spacing: 3) {
                InputMeterBar(index: ch - 1)
                if stereo { InputMeterBar(index: ch) }
            }
            .help("Input level (before processing)")
            if let r = engine.returns[ch] {
                HStack(spacing: 3) {
                    FXMeterBar(channel: ch)
                    if stereo { FXMeterBar(channel: ch + 1) }
                }
                .help("Processed level")
                Text(stereo ? "DAW inputs \(ch)–\(ch + 1): processed" : "DAW input \(ch): processed")
                    .font(.caption2).bold().foregroundStyle(Color.accentColor)
                    .help("The DAW records this input processed, on the same input number (1:1). Engine return: DAW \(r)\(stereo ? "–\(r + 1)" : "").")
                let copies = (stereo ? [ch, ch + 1] : [ch]).compactMap { engine.dryCopies[$0] }.map { String($0 - 0xD0 + 1) }
                if !copies.isEmpty {
                    Text("Dry copy on DAW input\(copies.count > 1 ? "s" : "") \(copies.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                phonesButton(ch)
            }
            if let p = engine.problems[ch] {
                Text(p).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if ch <= 8 { hardware(ch, stereo: stereo) }
            ForEach(0..<InputProcessing.slotsPerChannel, id: \.self) { i in
                slot(ch, i)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: stereo ? 236 : 150, alignment: .topLeading)
        .frame(minHeight: 260, alignment: .top)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Hardware settings for an analog input (both channels at once when linked).
    private func hardware(_ ch: Int, stereo: Bool) -> some View {
        let chans = stereo ? [ch, ch + 1] : [ch]
        let ref = Binding<Int>(
            get: { Int(store.value("/symphony/io/analog/in/\(ch)/ref") ?? -1) },
            set: { v in chans.forEach { store.set("/symphony/io/analog/in/\($0)/ref", Double(v), float: false) } })
        let soft = Binding<Bool>(
            get: { (store.value("/symphony/io/analog/in/\(ch)/softlimit") ?? 0) != 0 },
            set: { v in chans.forEach { store.set("/symphony/io/analog/in/\($0)/softlimit", v ? 1 : 0, float: false) } })
        return VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: ref) {
                ForEach(Names.inputRefLevels) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().controlSize(.small)
            HStack {
                Toggle("Soft Limit", isOn: soft).toggleStyle(.checkbox).controlSize(.small)
                Spacer()
                if let t = cal.inputTrim(ch) {
                    Text(String(format: "trim %+.1f", t)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .help("Calibration trim (Settings)")
                }
            }
        }
    }

    private func slot(_ ch: Int, _ i: Int) -> some View {
        let s = proc.channels[ch - 1].slots[i]
        return HStack(spacing: 4) {
            Menu {
                Button("None") { proc.setPlugin(nil, channel: ch, slot: i) }
                Divider()
                ForEach(proc.vendors, id: \.self) { v in
                    Menu(v) {
                        ForEach(proc.available.filter { $0.vendor == v }) { p in
                            Button(p.name) { proc.setPlugin(p, channel: ch, slot: i) }
                        }
                    }
                }
            } label: {
                Text(s.plugin?.name ?? "Insert \(i + 1)")
                    .font(.caption)
                    .foregroundStyle(s.plugin == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(s.plugin == nil ? Color.clear : Color.accentColor.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            if s.plugin != nil {
                Button {
                    PluginWindows.shared.show(proc, channel: ch, slot: i,
                                              title: proc.isLinked(ch) ? InputProcessing.pairName(ch % 2 == 1 ? ch : ch - 1) : InputProcessing.name(ch))
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Open the plugin window")
                Button { proc.toggleBypass(channel: ch, slot: i) } label: {
                    Image(systemName: "power").font(.caption2)
                        .foregroundStyle(s.bypass ? Color.secondary : Color.green)
                }
                .buttonStyle(.borderless)
                .help(s.bypass ? "Bypassed" : "Active")
            }
        }
    }
}

extension InputProcessingView {
    var engineBar: some View {
        HStack(spacing: 14) {
            Toggle("Process inputs", isOn: $engine.enabled).toggleStyle(.switch).controlSize(.small)
            Picker("Buffer", selection: $engine.bufferFrames) {
                ForEach(FXEngine.bufferChoices, id: \.self) { Text("\($0) samples").tag($0) }
            }
            .frame(width: 170)
            Circle().fill(engine.running ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(engine.status).font(.caption).foregroundStyle(.secondary)
            if engine.running, let ms = engine.roundTripMs {
                Text(String(format: "Through the Mac: about %.1f ms", ms)).font(.caption).foregroundStyle(.secondary)
                    .help("Input → plugins → output: 2 × buffer plus the Symphony's fixed USB latency, plus the plugins' own latency.")
            }
            Spacer()
        }
    }
}

/// Processed level for one input channel (watches the engine's meters on its own).
struct FXMeterBar: View {
    @EnvironmentObject var fx: FXMeters
    let channel: Int
    var body: some View { MeterBar(db: fx.levels[channel] ?? -120) }
}
