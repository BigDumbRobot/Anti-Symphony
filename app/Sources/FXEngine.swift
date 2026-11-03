import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Runs the Input Processing plugin chains live, without a DAW.
///
/// A HAL IOProc on the Symphony (the approach RemoteSession's rs-capture uses): each cycle it reads
/// the inputs that have plugins, applies the calibration trim, runs the plugin chain and writes the
/// result to a spare DAW playback channel (a "return", from DAW 16 down). Headphone Mixes and the
/// outputs can then use that channel. The IOProc runs at its own small buffer (CoreAudio keeps one
/// per process, so the DAW's buffer setting doesn't change it).
///
/// The audio goes through the Mac, so it's late by one round trip: 2 × buffer plus the device's
/// fixed latencies (about 270 samples on the Symphony over USB), plus the plugins' own latency.
/// Zero-latency monitoring stays on Bus A / Bus B (dry, in the box).
@MainActor
final class FXEngine: ObservableObject {
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "fxEnabled"); check() } }
    @Published var bufferFrames: Int { didSet { UserDefaults.standard.set(bufferFrames, forKey: "fxBuffer"); check() } }
    @Published private(set) var running = false
    @Published private(set) var status = "Off"
    /// Estimated input → plugins → output time through the Mac, in ms.
    @Published private(set) var roundTripMs: Double?
    /// Input channel (1–16) → the DAW channel (1–16) its processed signal plays on.
    @Published private(set) var returns: [Int: Int] = [:]
    /// Problems per input channel (no recording channel carries it, a plugin didn't load…).
    @Published private(set) var problems: [Int: String] = [:]

    let meters = FXMeters()

    private let store: Store
    private let proc: InputProcessing
    private let cal: Calibration
    private var timer: Timer?
    private var meterTimer: Timer?
    private var signature = ""
    private var building = false

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let graph = OSAllocatedUnfairLock<FXGraph?>(initialState: nil)
    /// Live plugin instances, by strip/slot/plugin/width, reused across rebuilds so settings stay.
    private var units: [String: AVAudioUnit] = [:]

    init(store: Store, proc: InputProcessing, cal: Calibration) {
        self.store = store
        self.proc = proc
        self.cal = cal
        enabled = UserDefaults.standard.object(forKey: "fxEnabled") as? Bool ?? true
        let b = UserDefaults.standard.integer(forKey: "fxBuffer")
        bufferFrames = b > 0 ? b : 32
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readMeters() }
        }
        PluginWindows.shared.engine = self
    }

    static let bufferChoices = [16, 32, 64, 128, 256]

    /// The live instance for a slot, if the engine is running it.
    func unit(channel ch: Int, slot: Int) -> AVAudioUnit? {
        let left = proc.isLinked(ch) ? (ch % 2 == 1 ? ch : ch - 1) : ch
        guard let p = proc.channels[left - 1].slots[slot].plugin else { return nil }
        return units[key(left, slot, p, proc.isLinked(ch) ? 2 : 1)]
    }

    private func key(_ ch: Int, _ slot: Int, _ p: InputProcessing.Plugin, _ n: Int) -> String { "\(ch)/\(slot)/\(p.id)/\(n)" }

    // MARK: what to run

    private struct StripPlan {
        let ch: Int                    // first input channel (1–16)
        let width: Int                 // 1 or 2
        let slots: [(Int, InputProcessing.Slot)]
    }

    private func plans() -> [StripPlan] {
        var out: [StripPlan] = []
        var ch = 1
        while ch <= 16 {
            let linked = ch % 2 == 1 && proc.isLinked(ch)
            let slots = proc.channels[ch - 1].slots.enumerated().filter { $0.element.plugin != nil }.map { ($0.offset, $0.element) }
            if !slots.isEmpty { out.append(StripPlan(ch: ch, width: linked ? 2 : 1, slots: slots)) }
            ch += linked ? 2 : 1
        }
        return out
    }

    /// Returns from DAW 16 down: stereo strips take a whole odd/even pair, mono strips one channel.
    /// An input keeps the return it had, so headphone mixes using it stay right.
    private func allocateReturns(_ plans: [StripPlan]) -> [Int: Int] {
        var free = Set(1...16)
        var r: [Int: Int] = [:]
        var todo: [StripPlan] = []
        for p in plans {
            let old = (0..<p.width).map { returns[p.ch + $0] }
            if old.allSatisfy({ $0 != nil }), let first = old[0], (0..<p.width).allSatisfy({ old[$0] == first + $0 && free.contains(first + $0) }),
               p.width == 1 || first % 2 == 1 {
                for k in 0..<p.width { r[p.ch + k] = first + k; free.remove(first + k) }
            } else { todo.append(p) }
        }
        for p in todo.sorted(by: { $0.width > $1.width || ($0.width == $1.width && $0.ch < $1.ch) }) {
            if p.width == 2 {
                guard let d = stride(from: 15, through: 1, by: -2).first(where: { free.contains($0) && free.contains($0 + 1) }) else { continue }
                free.subtract([d, d + 1]); r[p.ch] = d; r[p.ch + 1] = d + 1
            } else {
                guard let d = (1...16).reversed().first(where: { free.contains($0) }) else { continue }
                free.remove(d); r[p.ch] = d
            }
        }
        return r
    }

    /// Recording channel (0-based input stream channel) that carries board input `ch`.
    private func recordingChannel(for ch: Int) -> Int? {
        let src = Double(0x20 + ch - 1)
        return (0xD0...0xDF).first { store.value("/symphony/route/\($0)") == src }.map { $0 - 0xD0 }
    }

    private func trim(_ ch: Int) -> Float {
        guard ch <= 8, let t = cal.inputTrim(ch), !cal.inputStale(ch) else { return 1 }
        return Float(pow(10, t / 20))
    }

    private func currentSignature(_ plans: [StripPlan]) -> String {
        var s = "\(enabled)|\(bufferFrames)|\(ToneOut.symphonyDevice() ?? 0)|\(Self.rate(ToneOut.symphonyDevice()))|"
        for p in plans {
            s += "\(p.ch)x\(p.width):"
            for (i, slot) in p.slots { s += "\(i)=\(slot.plugin!.id)\(slot.bypass ? "b" : ""),"; }
            for c in p.ch..<(p.ch + p.width) { s += "r\(recordingChannel(for: c) ?? -1)t\(trim(c));" }
        }
        return s
    }

    // MARK: start / rebuild / stop

    func check() {
        guard !building else { return }
        let p = plans()
        let sig = currentSignature(p)
        guard sig != signature else { return }
        signature = sig
        guard enabled else { stop(); status = "Off"; return }
        guard !p.isEmpty else { stop(); status = "Waiting for plugins"; return }
        guard let dev = ToneOut.symphonyDevice() else { stop(); status = "The Symphony isn't available"; return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Task { await rebuild(p, device: dev) }
        case .notDetermined:
            // macOS gives silent input until the app may use audio input: ask once, then try again.
            signature = ""
            building = true
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.building = false; self.check() }
            }
            status = "Waiting for permission to read the inputs"
        default:
            stop()
            status = "Allow Symphony Control in System Settings → Privacy & Security → Microphone"
        }
    }

    private static func rate(_ dev: AudioObjectID?) -> Double {
        guard let dev else { return 0 }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var r = Float64(0); var n = UInt32(8)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &n, &r)
        return r
    }

    private func rebuild(_ plans: [StripPlan], device dev: AudioObjectID) async {
        building = true
        defer { building = false }
        let rate = Self.rate(dev)
        guard rate > 0 else { status = "The Symphony has no sample rate yet"; return }
        if dev != device { stop(); device = dev }
        let returns = allocateReturns(plans)
        var problems: [Int: String] = [:]
        var strips: [FXStrip] = []
        var used = Set<String>()

        for p in plans {
            guard let first = returns[p.ch] else { problems[p.ch] = "No free DAW channel for its return."; continue }
            var ins: [Int] = []
            for c in p.ch..<(p.ch + p.width) {
                if let r = recordingChannel(for: c) { ins.append(r) }
            }
            guard ins.count == p.width else {
                problems[p.ch] = "No recording channel carries this input. On Routing, set a \u{201C}To Mac\u{201D} channel to it."
                continue
            }
            var stages: [(AUAudioUnit, Bool)] = []
            for (slot, s) in p.slots {
                guard let plugin = s.plugin else { continue }
                let k = key(p.ch, slot, plugin, p.width)
                used.insert(k)
                do {
                    let u: AVAudioUnit
                    if let existing = units[k] { u = existing } else {
                        u = try await Self.instantiate(plugin)
                        if let data = s.state,
                           let st = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                            u.auAudioUnit.fullState = st
                        }
                        units[k] = u
                    }
                    try Self.prepare(u.auAudioUnit, channels: p.width, rate: rate)
                    stages.append((u.auAudioUnit, s.bypass))
                } catch {
                    problems[p.ch] = "\(plugin.name) can't run here: \(error.localizedDescription)"
                }
            }
            let outs = (0..<p.width).map { first + $0 - 1 }
            strips.append(FXStrip(channel: p.ch, inChannels: ins, outChannels: outs,
                                  gains: (p.ch..<(p.ch + p.width)).map(trim), stages: stages))
        }

        let next = FXGraph(strips: strips)
        let old = graph.withLock { (g: inout FXGraph?) -> FXGraph? in
            let o = g
            g = next
            return o
        }
        _ = old   // released here, after the audio thread has let go of it
        for (k, u) in units where !used.contains(k) {
            u.auAudioUnit.deallocateRenderResources()
            units.removeValue(forKey: k)
        }
        revertPhones(from: self.returns, to: returns)
        self.returns = returns
        self.problems = problems
        Names.returnLabels = Dictionary(uniqueKeysWithValues: returns.map { (0xC0 + $0.value - 1, "\(InputProcessing.name($0.key)) FX") })
        startDevice(dev)
        roundTripMs = Self.roundTrip(dev, buffer: bufferFrames, rate: rate)
        status = running ? "Processing \(strips.count) input\(strips.count == 1 ? "" : "s")" : status
    }

    private static func instantiate(_ p: InputProcessing.Plugin) async throws -> AVAudioUnit {
        let desc = AudioComponentDescription(componentType: p.type, componentSubType: p.subType,
                                             componentManufacturer: p.manufacturer, componentFlags: 0, componentFlagsMask: 0)
        return try await withCheckedThrowingContinuation { c in
            AVAudioUnit.instantiate(with: desc, options: []) { u, e in
                if let u { c.resume(returning: u) } else { c.resume(throwing: e ?? CalibrationError("didn't load")) }
            }
        }
    }

    private static func prepare(_ au: AUAudioUnit, channels: Int, rate: Double) throws {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) else { return }
        let inFmt = au.inputBusses.count > 0 ? au.inputBusses[0].format : nil
        if au.renderResourcesAllocated, inFmt == fmt, au.outputBusses[0].format == fmt,
           au.inputBusses[0].isEnabled, au.outputBusses[0].isEnabled { return }
        if au.renderResourcesAllocated { au.deallocateRenderResources() }
        guard au.inputBusses.count > 0 else { throw CalibrationError("it has no audio input") }
        try au.inputBusses[0].setFormat(fmt)
        try au.outputBusses[0].setFormat(fmt)
        // Plugins start with their busses disabled: render then fails with "no connection" (-10876).
        au.inputBusses[0].isEnabled = true
        au.outputBusses[0].isEnabled = true
        au.maximumFramesToRender = AUAudioFrameCount(FXGraph.maxFrames)
        try au.allocateRenderResources()
    }

    private func startDevice(_ dev: AudioObjectID) {
        var size = UInt32(bufferFrames)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &size)
        guard ioProc == nil else { running = true; return }
        let g = graph
        var id: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&id, dev, nil) { _, inData, inTime, outData, _ in
            g.withLockIfAvailable { graph in graph?.render(input: inData, output: outData, time: inTime.pointee) }
        }
        guard err == noErr, let id else { status = "Couldn't open the Symphony (\(err))"; running = false; return }
        ioProc = id
        AudioDeviceStart(dev, id)
        running = true
    }

    // MARK: processed audio in the headphones

    /// Headphone mix inputs (Bus A, Bus B) and the headphone feeds.
    private static let phoneDests = Array(0x40...0x4F) + Array(0x60...0x6F) + Array(0xE0...0xE3)

    private func channels(of ch: Int) -> [Int] {
        guard proc.isLinked(ch) else { return [ch] }
        let l = ch % 2 == 1 ? ch : ch - 1
        return [l, l + 1]
    }

    /// The headphones get this input processed (instead of dry).
    func processedInPhones(_ ch: Int) -> Bool {
        channels(of: ch).contains { c in
            guard let r = returns[c] else { return false }
            return Self.phoneDests.contains { store.value("/symphony/route/\($0)") == Double(0xC0 + r - 1) }
        }
    }

    /// The input is in a headphone mix at all (dry or processed).
    func inPhones(_ ch: Int) -> Bool {
        processedInPhones(ch) || channels(of: ch).contains { c in
            Self.phoneDests.contains { store.value("/symphony/route/\($0)") == Double(0x20 + c - 1) }
        }
    }

    /// Swaps the input for its processed return (or back) wherever the headphone mixes use it.
    func setProcessedInPhones(_ ch: Int, _ on: Bool) {
        for c in channels(of: ch) {
            guard let r = returns[c] else { continue }
            let dry = Double(0x20 + c - 1), wet = Double(0xC0 + r - 1)
            for d in Self.phoneDests {
                let path = "/symphony/route/\(d)"
                if on, store.value(path) == dry { store.set(path, wet, float: false) }
                if !on, store.value(path) == wet { store.set(path, dry, float: false) }
            }
        }
        objectWillChange.send()
    }

    /// When an input's return goes away or moves, its headphone feeds go back to dry.
    private func revertPhones(from old: [Int: Int], to new: [Int: Int]) {
        for (c, r) in old where new[c] != r {
            let wet = Double(0xC0 + r - 1)
            for d in Self.phoneDests where store.value("/symphony/route/\(d)") == wet {
                store.set("/symphony/route/\(d)", Double(0x20 + c - 1), float: false)
            }
        }
    }

    func stop() {
        if let p = ioProc {
            AudioDeviceStop(device, p)
            AudioDeviceDestroyIOProcID(device, p)
            ioProc = nil
        }
        graph.withLock { $0 = nil }
        running = false
        revertPhones(from: returns, to: [:])
        returns = [:]
        Names.returnLabels = [:]
    }

    /// 2 × buffer + device latencies + safety offsets + stream latencies, in ms.
    private static func roundTrip(_ dev: AudioObjectID, buffer: Int, rate: Double) -> Double {
        func u32(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> Int {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var v = UInt32(0); var n = UInt32(4)
            AudioObjectGetPropertyData(dev, &a, 0, nil, &n, &v)
            return Int(v)
        }
        func streamLatency(_ scope: AudioObjectPropertyScope) -> Int {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var n = UInt32(0)
            guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &n) == noErr, n >= 4 else { return 0 }
            var ids = [AudioObjectID](repeating: 0, count: Int(n) / 4)
            AudioObjectGetPropertyData(dev, &a, 0, nil, &n, &ids)
            var l = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var v = UInt32(0); var m = UInt32(4)
            AudioObjectGetPropertyData(ids[0], &l, 0, nil, &m, &v)
            return Int(v)
        }
        let frames = 2 * buffer
            + u32(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput) + u32(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput)
            + u32(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) + u32(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
            + streamLatency(kAudioObjectPropertyScopeInput) + streamLatency(kAudioObjectPropertyScopeOutput)
        return Double(frames) / rate * 1000
    }

    private func readMeters() {
        guard running else { if !meters.levels.isEmpty { meters.levels = [:] }; return }
        let peaks = graph.withLockIfAvailable { $0?.takePeaks() } ?? nil
        guard let peaks else { return }
        var l: [Int: Double] = [:]
        for (ch, p) in peaks { l[ch] = p > 0 ? 20 * log10(Double(p)) : -120 }
        meters.levels = l
    }
}

/// Processed output levels per input channel, separate so only meters redraw.
final class FXMeters: ObservableObject {
    @Published var levels: [Int: Double] = [:]
}

// MARK: - audio thread

/// One input (or linked pair) and its plugin chain. Buffers are allocated once.
final class FXStrip: @unchecked Sendable {
    let channel: Int
    let inChannels: [Int], outChannels: [Int]
    let gains: [Float]
    let width: Int
    /// bufs[i] = audio into stage i (bufs[0] = the input), bufs[last] = the chain's output.
    let bufs: [[UnsafeMutablePointer<Float>]]
    let renders: [AURenderBlock?]       // nil = bypassed
    let pulls: [AURenderPullInputBlock]
    let outLists: [UnsafeMutableAudioBufferListPointer]
    let peaks: UnsafeMutablePointer<Float>

    init(channel: Int, inChannels: [Int], outChannels: [Int], gains: [Float], stages: [(AUAudioUnit, Bool)]) {
        self.channel = channel
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.gains = gains
        width = inChannels.count
        let n = width
        bufs = (0...stages.count).map { _ in
            (0..<n).map { _ in
                let p = UnsafeMutablePointer<Float>.allocate(capacity: FXGraph.maxFrames)
                p.initialize(repeating: 0, count: FXGraph.maxFrames)
                return p
            }
        }
        renders = stages.map { $0.1 ? nil : $0.0.renderBlock }
        var pulls: [AURenderPullInputBlock] = []
        for i in 0..<stages.count {
            let src = bufs[i]
            pulls.append { _, _, frames, _, abl in
                let l = UnsafeMutableAudioBufferListPointer(abl)
                for c in 0..<min(l.count, src.count) {
                    if l[c].mData == nil { l[c].mData = UnsafeMutableRawPointer(src[c]) }
                    else { l[c].mData!.copyMemory(from: src[c], byteCount: Int(frames) * 4) }
                    l[c].mDataByteSize = frames * 4
                }
                return noErr
            }
        }
        self.pulls = pulls
        outLists = stages.map { _ in AudioBufferList.allocate(maximumBuffers: n) }
        peaks = UnsafeMutablePointer<Float>.allocate(capacity: n)
        peaks.initialize(repeating: 0, count: n)
    }

    deinit {
        bufs.flatMap { $0 }.forEach { $0.deallocate() }
        outLists.forEach { free($0.unsafeMutablePointer) }
        peaks.deallocate()
    }
}

final class FXGraph: @unchecked Sendable {
    static let maxFrames = 4096
    let strips: [FXStrip]
    init(strips: [FXStrip]) { self.strips = strips }

    /// Called on the HAL's real-time thread: no allocation, no locks beyond the caller's try-lock.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, time: AudioTimeStamp) {
        let inL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outL = UnsafeMutableAudioBufferListPointer(output)
        for b in outL { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        guard let firstIn = inL.first, firstIn.mNumberChannels > 0 else { return }
        let frames = Int(firstIn.mDataByteSize) / 4 / Int(firstIn.mNumberChannels)
        guard frames > 0, frames <= Self.maxFrames else { return }

        for s in strips {
            // Input channels → bufs[0], with the calibration trim.
            for (k, ch) in s.inChannels.enumerated() {
                Self.read(inL, channel: ch, frames: frames, into: s.bufs[0][k], gain: s.gains[k])
            }
            // The chain.
            for i in 0..<s.renders.count {
                let src = s.bufs[i], dst = s.bufs[i + 1]
                guard let render = s.renders[i] else {
                    for c in 0..<s.width { dst[c].update(from: src[c], count: frames) }
                    continue
                }
                let l = s.outLists[i]
                for c in 0..<s.width {
                    l[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(dst[c]))
                }
                var flags = AudioUnitRenderActionFlags()
                var ts = AudioTimeStamp()
                ts.mSampleTime = time.mSampleTime
                ts.mFlags = .sampleTimeValid
                let err = render(&flags, &ts, AUAudioFrameCount(frames), 0, l.unsafeMutablePointer, s.pulls[i])
                for c in 0..<s.width {
                    if err != noErr {
                        dst[c].update(from: src[c], count: frames)
                    } else if let d = l[c].mData, d != UnsafeMutableRawPointer(dst[c]) {
                        dst[c].update(from: d.assumingMemoryBound(to: Float.self), count: frames)
                    }
                }
            }
            // Chain output → the return channels, and its peak.
            let out = s.bufs[s.renders.count]
            for (k, ch) in s.outChannels.enumerated() {
                var peak = s.peaks[k]
                let p = out[k]
                for f in 0..<frames { let v = abs(p[f]); if v > peak { peak = v } }
                s.peaks[k] = peak
                Self.write(outL, channel: ch, frames: frames, from: p)
            }
        }
    }

    /// Peak per input channel since the last call (then reset).
    func takePeaks() -> [Int: Float] {
        var r: [Int: Float] = [:]
        for s in strips {
            for k in 0..<s.width { r[s.channel + k] = s.peaks[k]; s.peaks[k] = 0 }
        }
        return r
    }

    private static func locate(_ l: UnsafeMutableAudioBufferListPointer, _ channel: Int) -> (Int, Int, Int)? {
        var c = channel
        for (i, b) in l.enumerated() {
            let n = Int(b.mNumberChannels)
            if c < n { return (i, c, n) }
            c -= n
        }
        return nil
    }

    private static func read(_ l: UnsafeMutableAudioBufferListPointer, channel: Int, frames: Int, into dst: UnsafeMutablePointer<Float>, gain: Float) {
        guard let (b, c, n) = locate(l, channel), let d = l[b].mData else { dst.update(repeating: 0, count: frames); return }
        let src = d.assumingMemoryBound(to: Float.self)
        for f in 0..<frames { dst[f] = src[f * n + c] * gain }
    }

    private static func write(_ l: UnsafeMutableAudioBufferListPointer, channel: Int, frames: Int, from src: UnsafeMutablePointer<Float>) {
        guard let (b, c, n) = locate(l, channel), let d = l[b].mData else { return }
        let dst = d.assumingMemoryBound(to: Float.self)
        for f in 0..<frames { dst[f * n + c] = src[f] }
    }
}
