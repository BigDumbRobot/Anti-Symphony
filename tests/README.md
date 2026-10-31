# Hardware tests

`make test` runs `tests/hwtest.py` against a real Symphony I/O Mk1. It plays a different tone on each of the 16 DAW channels and measures the inputs, so every check is made on real audio rather than on what the box reports.

## Setup

- `symphonyd` installed and running (`make install`).
- Loopback cables:

  | From | To |
  | --- | --- |
  | Headphone 1 | Analog In 1 (TRS, so left and right both arrive: L − R) |
  | Headphone 2 | Analog In 2 |
  | Analog Out 3 | Analog In 3 (a compressor in between is fine) |

Your speakers on Analog Out 1–2 will play quiet test tones (−24 dBFS).

## What it covers

Handshake; OSC (state dump, errors, malformed packets, set/inc/dec/toggle/clamping, following changes made elsewhere); headphone own feeds and mirroring (including following a rerouted output); headphone level, mute, dim and mono; routing of outputs and recording channels (bit-exact digital loopback); reference levels (+4 dBu vs −10 dBV measured at 11.7 dB); soft limit; optical format; both mixers (fader, mute, solo, pan, master); all four sample rates; profiles; restoring settings the box lost; recovery from a dropped handshake, a killed symphonyd and a USB reset; a 2-minute soak; and that the app launches.

Every setting is snapshotted first and restored at the end, even when a test fails. Mixer inputs are fed from DAW channels during the run so nothing can loop back through the cables.

Run part of it by name: `python3 -I tests/hwtest.py mixer profiles`. Results also go to `build/test-results.md`.
