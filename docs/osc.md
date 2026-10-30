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
| `/symphony/monitor/hp/assign` | headphone assignment (raw; meaning not yet known) |

### Analog I/O (8x8 boards)
| Address | Value |
| --- | --- |
| `/symphony/io/analog/in/N/ref`, `/io/analog/out/N/ref` (N = 1–8) | reference level code (raw; names in docs/protocol.md, not yet confirmed) |
| `/symphony/io/analog/in/N/softlimit` | 0/1 |
| `/symphony/io/optical/spdif` | 0 = ADAT, 1 = S/PDIF (Analog-Optical board) |

### Routing
`/symphony/route/<dest>` = source ID, both as decimal numbers. Destinations 0–31 are the channels the Mac records, 32–47 are the board's outputs, and 176–183 (0xB0–0xB7) are headphone/mixer feeds. Source IDs are in docs/protocol.md (192–207 = DAW playback 1–16, 32–47 = board inputs).

### Mixers
`/symphony/mixer/M/in/N/fader|pan|solo|mute` (M = 1–2, N = 1–16), plus `/symphony/mixer/M/master/...` and `/symphony/mixer/M/return/...`. Fader: −48 … 0 dB. Pan: −1 (left) … 1 (right).

### Clock and other
| Address | Value |
| --- | --- |
| `/symphony/clock/rate` | 44100, 48000, 88200 or 96000 (set through Core Audio) |
| `/symphony/clock/source` | read-only, raw |
| `/symphony/clock/external` | read-only: external clock status byte |
| `/symphony/identify` | 1/0: blink the front panel |

## Companion

Use Companion's generic OSC module, pointed at this Mac and port 7100. For example, a mute button sends `/symphony/monitor/main/mute/toggle`, and a volume knob sends `/symphony/monitor/main/level/inc 1` and `/dec 1`.
