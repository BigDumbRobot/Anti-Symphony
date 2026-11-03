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

### The engine (built, 2026-11-03)

`FXEngine` in Symphony Control runs the chains live, no DAW needed: a HAL IOProc on the Symphony at its own buffer (16–256 samples; CoreAudio keeps one per process), reading each processed input from the recording channel that carries it, applying the calibration trim, rendering the plugins and writing the result to a spare DAW playback channel (a "return", from DAW 16 down; an input keeps its return). Each strip shows a processed meter and its return, and a **Phones: dry / processed** button swaps the return in for the dry input in the headphone mixes (with a latency warning). Needs the Microphone permission (macOS gives silent input without it).

Verified on the box: Analog In 3 → Pink Spider-DMP (fresh, minimum 6 dB gain) → return looped to a recording channel: **+6.00 dB**. Gotcha found: Audio Units start with their busses disabled, and render fails with -10876 (no connection) until `isEnabled` is set.

Through-the-Mac time, from the device's figures: about 5 ms at a 32-sample buffer at 48 kHz (2 × buffer + latencies + safety offsets + stream latencies). RemoteSession measured this box's loop at 522 samples with a 128 buffer, a few samples off the prediction; measure it the same way before relying on the figure.

### 1:1 delivery to the DAW (built)

Processed input N arrives on the box's recording channel N, so the DAW's input N is the processed signal. The engine needs the input itself on some recording channel (USB carries only 16 from the box), so it's fed on a spare one (16 down), not meant for the DAW; what that channel carried comes back when processing stops.

### Measured on the box and in Pro Tools Developer (2026-11-03)

Clicks, Analog Out 3 → compressor → Analog In 3, Pink Spider-DMP on In 3, engine buffer 32, Pro Tools' buffer 512:

- DAW input 3 (processed, 1:1): round trip 1389 frames; the dry copy: 1198. **The processed path adds a constant 191 frames (3.98 ms)**, every click identical.
- Recorded with `rsession record -ptsl` against a Pro Tools session while it played, delivered twice from the same take: with the device's input latency (74) the processed clicks sit **+190** frames after the dry ones; with 74 + 191 = 265 they sit **−1** frame from the dry ones, on all 8 clicks. So the timestamp method with the measured path latency puts processed audio where the dry audio would be.
- Placement in the session via PTSL polling is only known to ±897 frames; the Link plugin makes it exact (RemoteSession, section 7). Next: the Link insert on the record track and the engine writing the take itself.

### Layers

1. **The box's mixers (Bus A / Bus B): dry, zero latency.** Headphones always hear inputs routed directly here.
2. **Input Processing: between the box and the DAW.** Delivers processed audio to the DAW, placed exactly, so what's printed lines up with everything else.

### Delivering processed audio to the DAW (next)

RemoteSession's timestamping method, applied here:

- **Link insert on each DAW record track** (from RemoteSession's `native/link`): a zero-latency pass-through that publishes the host's timeline position, play/record state and track name per block, with the host time of the block, through a memory-mapped ring.
- **The engine stamps every processed block** with the IOProc's input timestamp (device sample time and host time of the first input sample). The processed audio for input N is known to belong to device sample time T exactly; plugin latency (reported, and checked by cross-correlation against the dry input, as `rs-render` does) is removed.
- **Matching host times** maps device sample time to timeline position, so each processed sample has an exact timeline position.
- **Takes:** while the track records, the engine writes the processed, latency-removed audio losslessly with its stamps (RemoteSession's capture format: crash-safe, forced to disk every second). On stop it delivers a Broadcast Wave per run with its `bext` TimeReference, and imports it to the track's position over PTSL (Pro Tools). Other DAWs: "spot to original time" / drag in.
- **Live:** the return channels also let the DAW record the processed signal directly (route a recording channel from the return; bit-exact loopback on this box) for a rough take; the timestamped print replaces it exactly.

Open questions: Link AAX needs PACE signing for retail Pro Tools (AU/VST3 fine); which DAWs besides Pro Tools get automatic placement.
