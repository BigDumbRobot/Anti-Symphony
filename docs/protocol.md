# Symphony I/O Mk1 USB control protocol

Recovered 2026-10-30 from Apogee's `symphonyIOUSBDaemon` 1.9.33 (unoptimised arm64 build with symbols; class `SymphonyIOControl`), plus a capture of its startup traffic. Raw extraction: `tools/capture/request-map-raw.txt` (regenerate with `tools/capture/extract_requests.py`).

## Host-ready handshake (the "!" on the front panel)

The box only acts as a USB interface after a host tells it the host is ready. Until then the front panel shows "!", even though macOS has enumerated it and Apple's USB audio driver has opened it. On Tahoe, Apogee's daemon no longer runs, so nothing sends this. Confirmed 2026-10-30 on macOS 26.0.1: sending it clears the "!" and the box appears as an audio device.

From `SymphonyIO::SetPeripheralReady(bool)`, `SymphonyIOControl::waitForSystemReady`, and `SymphonyIOUSBAudioDeviceController::SystemSleep/SystemWake` in Apogee's daemon:

1. Poll `0xFF` (read, 4 bytes) until it returns `DA E5 C4 A1` (big-endian `0xDAE5C4A1`): the box has booted.
2. Write `0xDD` = `00`, read it back, repeat until it reads `00` (Apogee: up to 10 tries, 5 ms apart).
3. Poll `0x28` (parameter updates) about every 1.3 s.
4. Before system sleep write `0xDD` = `01`; after wake write `0xDD` = `00` again.

Apogee pushes its saved settings (I/O types, monitoring, clock, routing, mixer) between steps 1 and 2. That isn't needed: with nothing pushed, the box keeps the settings stored in it. `symphonyd` does steps 1 to 4; `symctl ready` / `symctl release` do step 2 by hand.

Side effects seen when host ready is set: `0x2B` (pop-up needs update) goes 1 → 0. After Apogee's full startup, byte 4 of `0x28` also went 1 → 0; with the handshake alone it stays 1 (meaning unknown).

## Transport

Every control is a vendor control transfer on endpoint 0, device recipient:

| | bmRequestType | bRequest | wValue | wIndex | data |
|---|---|---|---|---|---|
| write | `0x40` | command | `addr >> 16` | `addr & 0xFFFF` | `len` bytes host → device |
| read | `0xC0` | command | `addr >> 16` | `addr & 0xFFFF` | `len` bytes device → host |

`addr` is a 32-bit value per command (below). Apogee retries a failed request twice with a 1 ms pause, and serialises all requests behind one lock.

## Commands

`ch` = channel (0-based), `hp` = headphone index, `mix` = mixer index, `in` = mixer input. "IO bit" = `0x80000000` set for outputs, clear for inputs.

### Monitoring
| cmd | addr | len | meaning |
|---|---|---|---|
| 0x25 | 0 | 1 | speaker output mode (r/w) |
| 0x26 | 0 | 1 | speaker (main) output volume, signed byte (r/w) |
| 0x27 | 0 | 1 | speaker output mute, 0/1 (r/w) |
| 0x23 | hp | 1 | headphone volume, signed byte (r/w) |
| 0x24 | hp | 1 | headphone mute, 0/1 (r/w) |
| 0xE7 | out | 1 | dim, 0/1 (r/w). out: monitor output enum 1 → 2, 2 → 0, 3 → 1 |
| 0xE8 | out | 1 | sum to mono, 0/1 (r/w), same index map as dim |
| 0xE9 | 0 | 1 | active speaker set (r/w) |
| 0x54 | 0 | 1 | headphone source (r/w): low nibble = headphone 1, high nibble = headphone 2. Each value picks an output pair the headphone mirrors (from `setHeadphoneAssignmentData`; pair order not yet confirmed) |
| 0x2A | 0 | 1 | front panel output selection (r/w) |

### Inputs (mic pre)
| cmd | addr | len | meaning |
|---|---|---|---|
| 0xC3 | ch | 1 | mic gain, signed byte (r/w) |
| 0xC4 | ch | 1 | instrument gain, signed byte (r/w) |
| 0xC5 | ch | 1 | phase invert (r/w) |
| 0xC6 | ch | 1 | 48V phantom power (r/w) |
| 0xC7 | ch | 1 | mic pre group (r/w) |
| 0xC8 | ch | 1 | mic pre insert (r/w) |
| 0xC9 | ch | 1 | mic pre insert enable (r/w) |
| 0xCA | ch | 1 | high-pass filter (r/w) |

### Analog / digital I/O
| cmd | addr | len | meaning |
|---|---|---|---|
| 0x20 | IO bit \| (ch & 0x7FFF) << 16 \| type (read); IO bit \| ch (write) | 2 | analog I/O type / reference level. Byte 1 = trim, 0x7F reserved |
| 0x60 | IO bit \| ch | 1 | current analog I/O type (read) |
| 0x21 | IO bit \| ch | 1 | digital reference level (r/w) |
| 0x22 | ch | 1 | Soft Limit (r/w) |
| 0x34 | board | 1 | optical is S/PDIF (r/w) |
| 0x35 | board | 1 | S/PDIF coax replaces input (r/w) |
| 0x36 | board | 1 | S/PDIF coax mirrors output (r/w) |
| 0x32 | bank | 1 | device channel bank (r/w) |

### Routing and mixer
| cmd | addr | len | meaning |
|---|---|---|---|
| 0x31 | 0 | 2·n | set routes: pairs of (destination, source) bytes |
| 0x31 | dest | 1 | read the source for one destination |
| 0xC2 | 0 | 0 | reset routing (write, no data) |
| 0xB0 | mix << 16 \| in | 1 | mixer fader: byte = max(0, dB + 48) |
| 0xB1 | mix << 16 \| in | 1 | mixer pan |
| 0xB2 | mix << 16 \| in | 1 | mixer solo |
| 0xB3 | mix << 16 \| in | 1 | mixer mute |
| 0x55 | 0 | 1 | mixer visibility mask |

### Clock
| cmd | addr | len | meaning |
|---|---|---|---|
| 0x03 | 0 | 1 | sample rate code (write): 48k=0, 96k=1, 192k=2, 44.1k=4, 88.2k=5, 176.4k=6 |
| 0x50 | 0 | 4 | clock mode: source, flags, AES/opt board index (r/w) |
| 0x51 | 0 | 5 | external clock status (read) |
| 0x52 | 0 | 2 | I/O board digital input status (read) |
| 0x53 | 0 | 1 | Pro Tools star-sync mode (r/w) |

### Status, metering, identity
| cmd | addr | len | meaning |
|---|---|---|---|
| 0xFF | 0 | 4 | system ready (read). `DAE5C4A1` once booted; Apogee polls until it sees that |
| 0x28 | 1 | 12 | parameter updates: front-panel changes (polled about every 1.3 s). Bytes 0–3 big-endian sample rate (`0000BB80` = 48000) |
| 0x2B | 0 | 1 | pop-up needs update (read) |
| 0x30 | group | 0x40 or 0x20 | TDM meter data (read). Groups 0, 1 = 64 bytes, 2 = 32. Reads all zero over USB, even with a tone playing and Apogee's default metering mode set (0x10 0 = 2, 0x10 1 = 3); probably only filled on the PCIe/TDM path |
| 0x10 | n | 1 | front panel metering mode (write) |
| 0x11 / 0x12 | 0 | 1 | front panel peak / over hold mode (write) |
| 0x13 | 0 | 1 | clear front panel meters (write) |
| 0xA0 | type | 3 | firmware version (read) |
| 0xA1 | 0 / 1 | 1 | primary / secondary I/O board type (read) |
| 0xC0 | n | 8 | unique ID (read) |
| 0x33 | 0 | 1 | identify (blink) (write) |
| 0x37 | 0 | 1 | prefix (r/w) |
| 0xCD | 0x1234 | 1 | "daemon disabled from firmware" (r/w; Apogee polls the read) |
| 0xDB | 0 | 1 | reset request (read) / clear (write). Reads 2 at startup; Apogee's poll loop acts on 2, 3 and 4 and then clears it. We leave it alone: everything works without it |
| 0xDD | 0 | 1 | **host ready lock** (r/w): 0 = host ready, 1 = no host (front panel "!"). Apogee calls it "preference load lock". See the handshake above |
| 0xDE | 0 | 4 | preference settings (read) |

## Values (decoded 2026-10-30 from the daemon and live reads)

### I/O board types (`0xA1`)
| code | board |
| --- | --- |
| 0 | none |
| 1 | 8 mic pre (MicPre8ch) |
| 2 | 8x8 Analog-AES |
| 3 | 8x8 Analog-Optical (the unit here) |
| 4 | AD16 |
| 5 | DA16 |
| 6 | AD/DA16 |
| 7 | 2x6 |

### Levels
- Main out (`0x26`) and headphones (`0x23`): **attenuation in dB**, 0 to 64. Level = −byte dB (so `0x19` = −25 dB). From `SymphonyIO::SetCoreAudioVolumeDB` and the 0x40 clamp in `changeMainOutAtten` / `changeHPLevel`.
- Mixer faders (`0xB0`): byte = max(0, dB + 48).

### Clock mode (`0x50`, 4 bytes)
Write: `[source, flag, flag, board index]`. The main unit uses sources 1, 2 and 3 (internal, word clock, loop sync; which is which is not yet confirmed); optical board inputs use 4 and 5. Read returns the source in byte 0 and the board index in byte 3. The sample rate itself is set from the Mac (Core Audio), because Apple's driver owns the USB stream.

### Routing (`0x31`)
Read `0x31 dest` returns the source for one destination. Write `0x31 0` takes (dest, src) byte pairs. Destinations from a full scan of 0x00–0xFF, with the defaults seen on the unit here:

| dest | what (likely) | default source |
| --- | --- | --- |
| 0x00–0x1F | USB record channels 1–32 (to the Mac) | 0x20–0x3F (board inputs) |
| 0x20–0x2F | board 1 outputs (8x8: analog out 1–8, optical out 1–8) | 0xC0–0xCF (DAW playback 1–16) |
| 0x30–0x3F | board 2 outputs (no board here) | 0xEC (none) |
| 0x40–0x4F, 0x50–0x5F | mixer 1 inputs (board 1, board 2) | 0x20–0x2F, 0x00 |
| 0x60–0x6F, 0x70–0x7F | mixer 2 inputs | 0x20–0x2F, 0x00 |
| 0xB0–0xB3 | headphone 1 L/R, headphone 2 L/R (unconfirmed) | 0xC0, 0xC1, 0xC0, 0xC1 |
| 0xB4–0xB7 | mixer 1 L/R and mixer 2 L/R outputs to somewhere (unconfirmed) | 0x40, 0x41, 0x60, 0x61 |
| 0x80–0xAF, 0xC0–0xFF | not yet identified | mixed |

Sources: 0x20–0x2F board 1 inputs, 0x30–0x3F board 2 inputs (`BoardForRoutingSource`); 0x40/0x41 and 0x60/0x61 mixer 1 and 2 outputs; 0xC0–0xCF DAW playback 1–16; 0xEC none.

## Never send

DFU, flash and reset commands live in `ApoUSB` / `XMOSUSB` (`EnterDFU`, `EraseFirmware`, `WriteDFUBlock`, `VendorSpecificReset`, `VendorSpecificRevertNormal`, `VendorSpecificSetRevertId`, `VendorSpecificFinalizeBootPartition`, `ResetFactorySettingsNVRAM`, `XMOSResetIntoDFU`). Their request numbers are not on this page on purpose. Our tool refuses any command not listed above. The functional-test commands (0xE5, 0xE6) are also excluded.

## Still to work out

- Units for the signed volume and gain bytes (live reads will show).
- The 12-byte parameter-update layout beyond the sample rate.
- What Apogee does for reset request values 2, 3 and 4 (`SymphonyIO::GetChangesFromHW`).
- Enum values: speaker output mode, clock source, analog I/O type, board types, routing source and destination IDs.
