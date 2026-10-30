# Symphony I/O Mk1 (USB) — device notes

Captured 2026-10-30 on macOS 13.7.8 (Apple Silicon). Raw dump: `tools/usbdesc/symphony-mk1-descriptors.txt`.

## Identity

- VID 0x0C60 (Apogee), PID 0x0010, bcdDevice 0x1648 (unit seen here), USB 2.0 high speed, self powered.
- One configuration, 3 interfaces, grouped by an IAD (class Audio, protocol 0x20 = UAC2).
- Old Apogee override kext matched PIDs 0x0011/0x0012, not 0x0010.

## Audio control (interface 0, UAC2, category 0x08 I/O box)

| ID | Unit | Notes |
|---|---|---|
| 0x29 | Clock source | **type external** (bmAttributes 0), freq r/w, validity read-only |
| 0x02 | Input terminal, USB streaming | 16 ch, clock 0x29, channel names string 0x0D |
| 0x14 | Output terminal, speaker | **source 0x0A: no such unit** |
| 0x01 | Input terminal, microphone | 16 ch, clock 0x29, channel names string 0x1D |
| 0x16 | Output terminal, USB streaming | **source 0x0B: no such unit** |

No interrupt endpoint and no feature units: all real control is vendor-specific (see below).

**Likely Tahoe failure:** both output terminals point at units that don't exist, and the clock is declared "external". Older AppleUSBAudio tolerated this; a stricter parser would plausibly reject the device. Not yet confirmed on Tahoe.

## Streaming

| Interface | Direction | Endpoint | Format |
|---|---|---|---|
| 1 alt 1 | Playback (to device) | 0x01 OUT, iso async, 1024 B, every microframe | 16 ch, 24-bit in 3-byte slots, PCM |
| | Feedback | 0x81 IN, iso feedback, 4 B, interval 8 (16 ms) | |
| 2 alt 1 | Record (from device) | 0x82 IN, iso async, 1024 B, every microframe | 16 ch, 24-bit in 3-byte slots, PCM |

- The OUT endpoint is flagged "implicit feedback data" yet has an explicit feedback endpoint (another spec slip).
- 1024 B per microframe limits 16 ch × 3 B to 96 kHz (21 frames). Higher rates need fewer channels or a different mode (Maestro has a "192K mode").

## Apogee's control path (what Maestro uses)

- `symphonyIOUSBDaemon` (in `/Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems/SymphonyIOUSBPlugIn.bundle`) opens the device from user space and sends vendor-specific control requests.
- Maestro features named in the daemon: main out level / mute / dim, headphone 1 & 2 level / mute / dim, mic gain, instrument gain, gain range, reference level, routing, mixer faders and mutes, software return, meters (peak / over hold), clock source (incl. word clock), 192K mode, CD mode, SRC out rate, Soft Saturate, I/O module detection (2x6, AD16, DA16, AD/DA16, Analog AES, Analog Optical).
- The daemon also has DFU firmware-update and "vendor specific reset / revert" commands. **Never send those.**
- Firmware versions it expects: Main FPGA 68, XMOS 1.6.24.
