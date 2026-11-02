# symphonyd OSC

`symphonyd` serves every Symphony setting over OSC (UDP). By default it listens on `127.0.0.1:7100`, so only this Mac can reach it. To let Companion on another machine reach it, start `symphonyd` with `--osc-bind 0.0.0.0` (and `--osc-port` to change the port).

## Talking to it

| Send | What happens |
| --- | --- |
| `/symphony/subscribe` | You get the full state now, then every change (including front-panel changes) for 60 s. Send it, or `/symphony/renew`, every 20 s or so to keep receiving. |
| `/symphony/unsubscribe` | Stop receiving changes. |
| `/symphony/dump` | Get the full state once. |
| `<address>` with no argument | Get one value. |
| `<address> <value>` | Set a value. |
| `<address>/toggle` | Flip an on/off control. |
| `<address>/inc [step]`, `<address>/dec [step]` | Nudge a level (default step 1 dB, or 1 for other controls). |

Values are sent back on the same addresses. Problems come back as `/symphony/error <address> <reason>`. `/symphony/connected 0|1` reports whether the box is attached.

## Addresses

Levels are floats in dB; on/off controls are ints (0/1).

### Monitoring
| Address | Value |
| --- | --- |
| `/symphony/monitor/main/level` | −64 … 0 dB |
| `/symphony/monitor/main/mute`, `/dim`, `/mono` | 0/1 |
| `/symphony/monitor/main/mode` | speaker output mode (raw) |
| `/symphony/monitor/speakerset` | active speaker set (raw) |
| `/symphony/monitor/frontpanel` | front-panel output selection (raw) |
| `/symphony/monitor/hp/1/level`, `/hp/2/level` | −64 … 0 dB |
| `/symphony/monitor/hp/N/mute`, `/dim`, `/mono` | 0/1 |
| `/symphony/monitor/hp/N/mirror` | output pair the headphone mirrors, by its left destination (32 = Analog Out 1–2 … 46 = Optical Out 7–8), or −1 for its own feed. While mirroring, the headphone follows any change to that output's routing. Remembered across restarts |

### Analog I/O (8x8 boards)
| Address | Value |
| --- | --- |
| `/symphony/io/analog/in/N/ref`, `/io/analog/out/N/ref` (N = 1–8) | 1 = −10 dBV, 2 = +4 dBu (measured); outputs also have 0 = power-on default |
| `/symphony/io/analog/in/N/softlimit` | 0/1 |
| `/symphony/io/optical/spdif` | 0 = ADAT, 1 = S/PDIF (Analog-Optical board) |

### Routing
`/symphony/route/<dest>` = source ID, both as decimal numbers:

| dest | what |
| --- | --- |
| 32–47 | board outputs: Analog Out 1–8, Optical Out 1–8 |
| 208–223 | the 16 channels the Mac records |
| 224, 225 / 226, 227 | headphone 1 / headphone 2 feed, left and right (setting these ends mirroring) |
| 64–79 / 96–111 | mixer 1 / mixer 2 inputs 1–16 |

Sources: 32–39 Analog In 1–8, 40–47 Optical In 1–8, 192–207 DAW 1–16, 64/65 Mixer 1 L/R, 96/97 Mixer 2 L/R, 236 none.

### Mixers
`/symphony/mixer/M/in/N/fader|pan|solo|mute` (M = 1–2, N = 1–16), plus `/symphony/mixer/M/master/...` and `/symphony/mixer/M/return/...`. Fader: −48 … 0 dB. Pan: −1 (left) … 1 (right).

### Clock and other
| Address | Value |
| --- | --- |
| `/symphony/clock/rate` | 44100, 48000, 88200 or 96000 (set through Core Audio) |
| `/symphony/identify` | 1/0: blink the front panel |

## Meters

Send `/symphony/meters/subscribe` (and again every few seconds while you want them) to receive `/symphony/meters/in` about 15 times a second: 32 floats in dBFS (a full-scale sine reads 0), board 1's inputs 1–16 (Analog In 1–8, Optical In 1–8) then board 2's. symphonyd only reads the meters while someone is subscribed. The box doesn't send output meters over USB.

## Profiles

| Send | What happens |
| --- | --- |
| `/symphony/profile/save "<name>"` | Save every setting (and headphone mirror choices) under that name. Names: 1–64 letters, digits, spaces or `- _ . ( )`. |
| `/symphony/profile/load "<name>"` | Put that profile back on the box. |
| `/symphony/profile/delete "<name>"` | Delete it. |
| `/symphony/profile/list` | Reply `/symphony/profiles "<name>\n<name>…"` (also sent on subscribe and after any change). |

Profiles are text files in `~/Library/Application Support/Anti-Symphony/profiles/`. Separately, symphonyd keeps the current settings in `…/Anti-Symphony/settings` and puts them back when the box comes back with defaults (it forgets host-set settings when it reboots).

## Companion

Anti-Symphony includes a custom Bitfocus Companion module in [`companion/`](../companion/README.md). Add the **Anti-Symphony** connection, enter the Mac running `symphonyd` and OSC port 7100, then choose its native actions or add one of its ready-made presets. Presets cover monitor controls, both mixers' strips, all routing destinations, headphone feeds, analog I/O, clock, profiles, meters, and interface identification.

The module subscribes to `symphonyd` for live state and renews the subscription automatically. If Companion runs on another computer, configure `symphonyd` to bind to a reachable interface (for example `--osc-bind 0.0.0.0`) and permit UDP port 7100 on a trusted LAN. OSC has no authentication; do not expose it to the public internet. The generic OSC module remains usable for controls not covered by the custom module.

If Companion reports no OSC reply, check that its target IP and port match `symphonyd`; remote Companion also requires a network-reachable bind address because the daemon defaults to `127.0.0.1`. If it reports that the Symphony is disconnected, OSC is working but the daemon does not currently see the interface.
