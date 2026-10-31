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
