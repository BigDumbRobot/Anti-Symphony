# Input processor (design)

A UAD-style input channel strip for any audio interface: each hardware input gets a processor, Pink Spider-DMP first, controlled from the interface's control app alongside that input's hardware settings. Version 1 targets the Symphony I/O; nothing in the design is Symphony-specific except one backend.

Status: design. Pink Spider-DMP (the first processor) is built and tested in `~/Anti-Music-Pink-Spider` (branch `mic-pre`).

## Requirements

- No added latency beyond the processor's own (Pink Spider-DMP: 3 samples at 48 kHz).
- The strip lives in the control app (Symphony Control): processor controls next to the input's reference level, meters and routing.
- Settings recall with profiles and with DAW sessions.
- Works with any interface; interface-specific parts sit behind a backend.

## Why the DSP runs in the DAW

The interface can't run plugins (the Symphony has no user DSP), so audio has to pass through the Mac. Processing in a separate program costs a round trip (two buffers plus USB, a few ms). Running the DSP in the DAW's insert on the record track costs nothing extra. The control app reaches it the way RemoteSession's Link plugin reaches its reader: shared memory, the audio thread never waits.

```
interface input ──► DAW record track ──► [Input Processor insert: Pink Spider-DMP DSP] ──► recorded
                                              ▲ parameters        │ meters, state, track name
                                              │                   ▼
                                    shared memory (per instance, memory-mapped file)
                                              ▲                   │
                                     control app (Symphony Control): "Inputs" strip
                                              │
                                     interface backend ──► symphonyd (OSC) for the Symphony
```

## Pieces

1. **Input Processor plugin** (AU / VST3 / AAX, JUCE): Pink Spider-DMP's DSP plus a link. It opens `~/Library/Application Support/Anti-Music/inputs/<pid>-<instance>.aminput` and:
   - reads parameters written by the control app (versioned, so the audio thread only copies when they change);
   - writes meters, gain reduction, state and the DAW track name;
   - keeps working standalone (its own editor) when no control app is running. Its state stays the source of truth for DAW session recall.
2. **Shared-memory format** (`InputShared.h`), in the same style as RemoteSession's `LinkShared.h`: fixed offsets, monotonic counters, no locks, writer never waits.
3. **Interface backend** (in the control app), the only interface-specific part:
   - list inputs (names, channel count) and their hardware settings (reference level, gain, phantom, pad, where they exist);
   - input meters;
   - zero-latency monitoring routes (e.g. Symphony headphone feeds and monitor mixers);
   - Symphony backend: symphonyd over OSC (all of the above already exists).
   - A generic Core Audio backend (any interface) gives input names and meters from the recorded stream; hardware settings only where a backend for that interface exists.
4. **Inputs strip in the control app**: one strip per hardware input: hardware settings, then the assigned processor's controls and meters.

## Which instance belongs to which input

The DAW doesn't tell a plugin which hardware input feeds its track. Two ways, both planned:

- **Pick it** in the plugin or the control app (stored in the plugin's state).
- **Detect it**: the control app correlates each instance's input level over time with the interface's input meters (the Symphony's meter stream) and suggests the match.

## Open questions

- AAX needs PACE signing to load in retail Pro Tools (same blocker as RemoteSession Link). AU and VST3 work now.
- Session recall vs profiles: the DAW session should win; a profile can push its settings to the matching instances.
- Monitoring through the processor still has DAW buffer latency; the zero-latency monitoring path is the interface's own (dry) route.

## Input Processing page and engine (2026-11-03)

The app's **Input Processing** page holds the setup: up to 4 plugin inserts per input (Analog 1–8, Optical 1–8). Odd/even inputs link into a stereo pair (odd = left). Linking swaps each plugin for its stereo version (same vendor, same name with Mono/Stereo or (m)/(s) swapped; plugins that handle both widths stay as they are) and keeps the settings. Unlinking does the reverse. Saved in `~/Library/Application Support/Anti-Symphony/input-processing.json`. Calibration trims (Settings page) live in `calibration.json` beside it, and the engine applies them as the first stage of each input.

The hardware mixers are no longer "Mixer 1 / Mixer 2". They are **Bus A / Bus B**, the two zero-latency headphone mixes, and they stay dry.

### Latency, plainly

The Symphony has no DSP, so every plugin runs on the Mac and the audio has to go there and back over USB. Nothing can hide that delay from someone listening live. A loopback through a headphone output adds a trip instead of removing one. What we can do:

1. **Monitor dry, record processed.** Bus A / B carry the inputs straight from the converters (zero latency), with a DAW rough mix on two faders. The processed signal goes to the recording. This is how most native setups work.
2. **Low-latency engine for processed monitoring.** A separate real-time process (not the DAW) opens the Symphony at the smallest buffer it accepts (16–32 samples), runs the insert chains, and plays the result to spare DAW channels. Bus A / B then mix those channels with everything else. Expected round trip: measure it with `symtest` (input → engine → output). It should be about 2–4 ms at 48 kHz, plus each plugin's own latency. Plugins that report latency get flagged on the strip.
3. **Delay compensation for recording.** The engine reports its total latency so the recorded, processed signal lines up. The DAW already does this for hardware inserts.

Next build steps: the engine process (AU hosting, mono/stereo state transfer through `fullState`), measuring the round trip on this box, and metering DAW playback (Core Audio process tap on the Symphony's output) so DAW-fed outputs show levels too.
