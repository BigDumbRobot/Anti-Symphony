# Anti-Symphony

A macOS integration layer for the **Apogee Symphony I/O Mk1** over USB, for macOS versions where the Mk1 is no longer recognised (Tahoe and later, after the Core Audio changes). It gives:

- a Core Audio device, so the Symphony shows up in Logic, Pro Tools and the rest;
- Maestro-style device control (levels, gain, routing, mixer, clock);
- OSC for all controls, so Bitfocus Companion can drive it.

No kernel extension and no Apple entitlements: a user-space service owns the USB device, and a Core Audio plug-in talks to that service.

## Status (2026-10-30)

Done, on macOS 13.7.8 (Apple Silicon) with a Mk1 attached:

- **USB descriptors decoded**: [docs/device-notes.md](docs/device-notes.md). The device's UAC2 descriptors point at two units that don't exist (0x0A, 0x0B) and declare an external clock. Likely why newer macOS rejects it; still to confirm on Tahoe.
- **Control protocol recovered** from Apogee's own daemon: [docs/protocol.md](docs/protocol.md). About 50 controls, all vendor requests on endpoint 0.
- **`symctl` works**: reads every setting, and a write (Identify) was accepted. No root needed.

Next:

1. On Tahoe: check how the device enumerates (`tools/usbdesc`), and that `symctl dump` works.
2. Work out value units (volume / gain bytes) and enum names from live readings.
3. `symphonyd`: user-space service that owns the device, streams audio (isochronous, 16 × 16, 24-bit) and exposes control + OSC.
4. Core Audio plug-in (AudioServerPlugIn) that exchanges audio with `symphonyd` through shared memory.
5. Small control app and a Companion module.

## Layout

| Path | What |
|---|---|
| `docs/device-notes.md` | USB descriptor breakdown and the likely Tahoe failure |
| `docs/protocol.md` | Vendor control protocol |
| `tools/usbdesc/` | Dumps the device's USB descriptors (read-only) |
| `tools/symctl/` | Command-line control of the Symphony |
| `tools/capture/` | How the protocol was recovered: USB request logger for Apogee's daemon, extraction script, Apogee's startup sequence |

## Build

Command Line Tools are enough (no Xcode needed).

```
cd tools/usbdesc && clang -framework IOKit -framework CoreFoundation usbdesc.c -o usbdesc && ./usbdesc
cd tools/symctl && clang -O2 -framework IOKit -framework CoreFoundation symctl.c -o symctl && ./symctl dump
```

`symctl`:

```
symctl dump                       # read all known settings
symctl read  <cmd> <addr> <len>   # e.g. symctl read 0x26 0 1   (main volume)
symctl write <cmd> <addr> <hex>   # e.g. symctl write 0x33 0 01 (identify on)
```

Only commands listed in `docs/protocol.md` are accepted. Firmware, DFU and reset commands are refused on purpose.

## Re-deriving the protocol

Needs Apogee's Symphony software installed (it provides `symphonyIOUSBDaemon`):

```
cd tools/capture
mkdir -p daemon-copy
cp "/Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems/SymphonyIOUSBPlugIn.bundle/Contents/MacOS/"{symphonyIOUSBDaemon,usbApogeeDaemonConstants.plist} daemon-copy/
otool -arch arm64 -tV daemon-copy/symphonyIOUSBDaemon | c++filt > daemon-arm64.s
python3 extract_requests.py daemon-arm64.s | sort
```

To log the daemon's live USB traffic: build `usbspy.dylib`, ad-hoc sign the copy (`codesign -f -s - daemon-copy/symphonyIOUSBDaemon`), then `sudo ./capture-start.sh`; undo with `sudo ./capture-stop.sh`.
