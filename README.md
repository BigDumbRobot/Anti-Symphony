# Anti-Symphony

Makes the **Apogee Symphony I/O Mk1** work over USB on macOS versions Apogee no longer supports (Tahoe and later), and adds what Maestro used to provide:

- the Symphony working as a normal Core Audio device in Logic, Pro Tools and the rest;
- Maestro-style device control (levels, gain, routing, mixer, clock);
- OSC control plus a custom Bitfocus Companion module with ready-made actions and feedbacks.

No kernel extension, no root, no Apple entitlements.

## Why it stopped working, and the fix

On Tahoe the Mac sees the Symphony fine, and Apple's built-in USB audio driver opens it as a 16 × 16 device. But the box waits for its host software to say "host ready" (one vendor USB request: command `0xDD` = 0). Until it hears that, the front panel shows "!" and it doesn't act as an interface. Apogee's daemon used to send it, and that daemon doesn't run on Tahoe.

`symphonyd` sends it. Details: [docs/protocol.md](docs/protocol.md#host-ready-handshake-the--on-the-front-panel).

## Install

Command Line Tools are enough (no Xcode needed).

```sh
make install
```

This builds everything, puts **Symphony Control** (the Maestro replacement) in `~/Applications`, and installs `symphonyd` as a LaunchAgent for your user: it starts at login and restarts if it ever exits. The log is `~/Library/Logs/symphonyd.log`. Remove it all with `make uninstall`.

Other targets: `make` (build only, warnings are errors), `make test` (hardware tests, see [tests/README.md](tests/README.md)), `make dist` (release zip), `make clean`. The version is in `VERSION`.

## What you get

**symphonyd** (background service)
- Sends the host-ready handshake when the box connects or finishes booting, and again if the box drops it; releases it around sleep, as Apogee did.
- Recovers a box that stops answering by resetting the USB connection (no unplugging needed).
- Keeps a live copy of every setting and serves it over OSC for the app and Companion ([docs/osc.md](docs/osc.md)).
- Saves your settings and puts them back if the box comes back with defaults (it forgets host-set settings when it reboots).
- Profiles: save and recall complete setups by name.

**Symphony Control** (app, plus a menu-bar icon)
- Monitoring: main out level, mute, dim, mono, speaker set; both headphones' level, mute, dim, mono and feed. Each headphone can mirror any output pair (and follows it if that output is rerouted) or take its own feed: any DAW pair, input pair or mixer.
- Inputs & Outputs: input meters, reference level per analog channel (+4 dBu / −10 dBV), Soft Limit, optical ADAT / S/PDIF.
- Input meters also on mixer strips and routing rows fed by an input.
- Routing: a source for each output and each channel the Mac records.
- Mixer: both monitor mixers with source, fader, pan, solo and mute per input, plus return and master.
- Clock: sample rate (44.1 / 48 / 88.2 / 96 kHz). The clock source is chosen on the box (hold a rotary encoder).
- Profiles: save, load, overwrite, delete; quick load from the menu bar.
- Mac volume keys control the main out level while the Symphony is the Mac's sound output, with an on-screen level indicator. (macOS's own volume slider stays greyed out: the box has no USB volume control.)
- Open at login.

## Status (2026-10-31)

Working on macOS 26.0.1 (Apple Silicon), version 0.3.0. The hardware test suite passes (29 checks, measured on real audio through loopback cables).

Known limits:
- Output meters: the box only sends input meters over USB.
- Never read command 0x51 (external clock status): it crashes the box. Nothing here does.

## Layout

| Path | What |
| --- | --- |
| `symphonyd/` | The background service (handshake, recovery, device control, OSC, profiles), its LaunchAgent and install scripts |
| `app/` | Symphony Control, the SwiftUI control app (Swift package; talks to symphonyd over OSC) |
| `companion/` | Custom Bitfocus Companion module with native actions and ready-made presets for Symphony controls |
| `tests/` | Hardware test suite and the `symtest` audio measurement tool |
| `avbbridge/` | Optional: puts the Symphony's channels on AVB through the Mac (parked) |
| `docs/osc.md` | OSC addresses, for Companion and other controllers |
| `docs/input-processor.md` | Design: UAD-style input processor (Pink Spider-DMP) for any interface, Symphony first |
| `lib/symusb.*` | Shared USB access with the command allowlist |
| `tools/symctl/` | Command-line control of the Symphony |
| `tools/usbdesc/` | Dumps the device's USB descriptors (read-only) |
| `tools/capture/` | How the protocol was recovered: USB request logger for Apogee's daemon, extraction script, Apogee's startup sequence |
| `docs/protocol.md` | Vendor control protocol and the handshake |
| `docs/device-notes.md` | USB descriptor breakdown |

## symctl

```sh
symctl dump                       # read all known settings
symctl ready | release            # send or undo host ready (symphonyd re-sends it within ~1 s)
symctl read  <cmd> <addr> <len>   # e.g. symctl read 0x26 0 1   (main volume)
symctl write <cmd> <addr> <hex>   # e.g. symctl write 0x33 0 01 (identify on)
```

`make` puts it in `build/`; `make install` also copies it to `~/Library/Application Support/Anti-Symphony/`.

Only commands listed in `docs/protocol.md` are accepted (the allowlist in `lib/symusb.c`). Firmware, DFU and reset commands are refused on purpose.

## Re-deriving the protocol

Needs Apogee's Symphony software. It doesn't have to be installed: download "Symphony System Release v5.5" from Apogee's knowledge base, mount the DMG, and run `pkgutil --expand-full "Symphony Software Installer.pkg" <dir>`. The daemon is in `Maestro2.pkg/Payload/Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems/SymphonyIOUSBPlugIn.bundle/Contents/MacOS/`.

```sh
cd tools/capture
mkdir -p daemon-copy
cp <that folder>/{symphonyIOUSBDaemon,usbApogeeDaemonConstants.plist} daemon-copy/
otool -arch arm64 -tV daemon-copy/symphonyIOUSBDaemon | c++filt > daemon-arm64.s
python3 extract_requests.py daemon-arm64.s | sort
```

To log the daemon's live USB traffic (needs a macOS version where it still runs): build `usbspy.dylib`, ad-hoc sign the copy (`codesign -f -s - daemon-copy/symphonyIOUSBDaemon`), then `sudo ./capture-start.sh`; undo with `sudo ./capture-stop.sh`.
