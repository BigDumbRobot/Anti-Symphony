# Anti-Symphony

Makes the **Apogee Symphony I/O Mk1** work over USB on macOS versions Apogee no longer supports (Tahoe and later), and adds what Maestro used to provide:

- the Symphony working as a normal Core Audio device in Logic, Pro Tools and the rest;
- Maestro-style device control (levels, gain, routing, mixer, clock);
- OSC for all controls, so Bitfocus Companion can drive it.

No kernel extension, no root, no Apple entitlements.

## Why it stopped working, and the fix

On Tahoe the Mac sees the Symphony fine, and Apple's built-in USB audio driver opens it as a 16 × 16 device. But the box waits for its host software to say "host ready" (one vendor USB request: command `0xDD` = 0). Until it hears that, the front panel shows "!" and it doesn't act as an interface. Apogee's daemon used to send it, and that daemon doesn't run on Tahoe.

`symphonyd` sends it. Details: [docs/protocol.md](docs/protocol.md#host-ready-handshake-the--on-the-front-panel).

## Install

Command Line Tools are enough (no Xcode needed).

```sh
make install
```

This builds everything and installs `symphonyd` as a LaunchAgent for your user: it starts at login and restarts if it ever exits. The log is `~/Library/Logs/symphonyd.log`. Remove it with `make uninstall`.

What `symphonyd` does:

- when a Symphony is plugged in or powered on: waits for it to boot, then sends host ready;
- every 1.3 s: checks host ready is still set and sends it again if the box dropped it;
- before the Mac sleeps: releases the box, the same as Apogee did; after wake: sends host ready again.

It's a LaunchAgent, so it runs once you log in. Until someone logs in, the box shows "!".

## Status (2026-10-30)

- **Working on macOS 26.0.1 (Apple Silicon):** with the handshake sent, the "!" clears and the Symphony appears in audio devices. Apple's driver does the audio, so no audio code of ours is involved.
- **Control protocol recovered** from Apogee's own daemon: [docs/protocol.md](docs/protocol.md). About 50 controls, all vendor requests on endpoint 0.
- **USB descriptors decoded**: [docs/device-notes.md](docs/device-notes.md). They have spec errors, but Tahoe accepts them.

Next:

1. Prove it holds up: playback and recording in a DAW at 48k and 96k, long sessions, sleep/wake, unplug/replug, front-panel power cycle.
2. Work out value units (volume / gain bytes) and enum names from live readings.
3. Settings control and OSC in `symphonyd`, then a small control app and a Companion module.

The original plan included our own audio streaming and a Core Audio plug-in. Apple's driver already handles the audio, so those are dropped unless testing finds a problem.

## Layout

| Path | What |
| --- | --- |
| `symphonyd/` | The background service, its LaunchAgent and install scripts |
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
