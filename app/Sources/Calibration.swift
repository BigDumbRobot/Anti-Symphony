import Foundation
import SwiftUI

/// Analog calibration: how many dBu each analog input and output gives at digital full scale, and
/// the trims that line every channel up with the chosen calibration level (+4 dBu = level dBFS).
///
/// Inputs are measured from a known +4 dBu 1 kHz tone (the one absolute reference). Outputs are then
/// measured automatically: the app plays the tone on a spare DAW channel, routes it to the output,
/// reads it back on a calibrated input through a loopback cable, and puts the routing back.
///
/// The Symphony Mk1 has no fine trim of its own (only +4 dBu / −10 dBV), so trims are applied by
/// Input Processing. Saved in ~/Library/Application Support/Anti-Symphony/calibration.json.
@MainActor
final class Calibration: ObservableObject {
    struct Reading: Codable, Equatable {
        var fullScaleDBu: Double    // analog level at 0 dBFS
        var ref: Int                // reference level code when measured
        var date: Date
    }

    static let levels: [Double] = [-14, -16, -18, -20, -22]
    static let toneVolts = 1.228   // +4 dBu RMS

    @Published var level: Double = -18 { didSet { save() } }
    @Published private(set) var inputs: [Int: Reading] = [:]
    @Published private(set) var outputs: [Int: Reading] = [:]
    @Published var loopback: [Int: Int] = [:] { didSet { save() } }      // output -> input it's cabled to
    @Published var status: String?
    @Published var problem: String?
    @Published private(set) var running = false

    private let store: Store
    private let meters: Meters
    private let tone = ToneOut()
    private var cancel = false

    init(store: Store, meters: Meters) {
        self.store = store
        self.meters = meters
        load()
    }

    // MARK: trims

    /// dB to add to an input so +4 dBu reads `level` dBFS.
    func inputTrim(_ c: Int) -> Double? { inputs[c].map { $0.fullScaleDBu - 4 + level } }
    /// dB to add before an output so `level` dBFS plays at +4 dBu.
    func outputTrim(_ c: Int) -> Double? { outputs[c].map { 4 - level - $0.fullScaleDBu } }

    func inputRef(_ c: Int) -> Int { Int(store.value("/symphony/io/analog/in/\(c)/ref") ?? -1) }
    func outputRef(_ c: Int) -> Int { Int(store.value("/symphony/io/analog/out/\(c)/ref") ?? -1) }

    /// The reading was made at a different reference level than the channel has now.
    func inputStale(_ c: Int) -> Bool { inputs[c].map { $0.ref != inputRef(c) } ?? false }
    func outputStale(_ c: Int) -> Bool { outputs[c].map { $0.ref != outputRef(c) } ?? false }

    func loop(_ out: Int) -> Int { loopback[out] ?? out }

    // MARK: measuring

    /// Average input meter levels over `seconds` (meters update ~15/s).
    private func sample(_ channels: [Int], seconds: Double = 1.5) async -> [Int: (mean: Double, spread: Double)] {
        var seen: [Int: [Double]] = [:]
        let steps = Int(seconds / 0.1)
        for _ in 0..<steps {
            try? await Task.sleep(nanoseconds: 100_000_000)
            for c in channels { seen[c, default: []].append(meters.input[c - 1]) }
        }
        return seen.mapValues { v in
            let power = v.map { pow(10, $0 / 10) }.reduce(0, +) / Double(v.count)
            return (10 * log10(max(power, 1e-12)), (v.max() ?? 0) - (v.min() ?? 0))
        }
    }

    /// Inputs: reads every analog input that has the +4 dBu tone on it.
    func measureInputs() async {
        guard !running else { return }
        running = true; problem = nil; cancel = false
        defer { running = false }
        status = "Reading the analog inputs…"
        try? await Task.sleep(nanoseconds: 500_000_000)
        let got = await sample(Array(1...8), seconds: 2)
        var done: [Int] = [], unsteady: [Int] = []
        for c in 1...8 {
            guard let r = got[c], r.mean > -40 else { continue }
            if r.spread > 1 { unsteady.append(c); continue }
            inputs[c] = Reading(fullScaleDBu: 4 - r.mean, ref: inputRef(c), date: Date())
            done.append(c)
        }
        save()
        if done.isEmpty {
            problem = "No steady tone found. Feed a 1 kHz +4 dBu tone (1.228 V RMS) to the inputs and try again."
        }
        if !unsteady.isEmpty {
            problem = (problem.map { $0 + " " } ?? "") + "Unsteady level on In \(unsteady.map(String.init).joined(separator: ", ")): skipped."
        }
        status = done.isEmpty ? nil : "Calibrated In \(done.map(String.init).joined(separator: ", "))."
    }

    /// Outputs: tone out, loop back, measure, restore. Every step is automatic.
    func measureOutputs(_ outs: [Int]) async {
        guard !running else { return }
        running = true; problem = nil; cancel = false
        defer { running = false; tone.stop() }
        for out in outs.sorted() {
            if cancel { status = "Stopped."; return }
            let input = loop(out)
            guard let inCal = inputs[input], !inputStale(input) else {
                problem = "Out \(out): calibrate In \(input) first (it's the input the loopback cable goes to)."
                continue
            }
            guard let daw = spareDAWChannel() else {
                problem = "Every DAW channel is in use somewhere in the routing, so the test tone would leak. Free one up and try again."
                return
            }
            let route = "/symphony/route/\(0x20 + out - 1)"
            let saved = store.value(route)
            status = "Out \(out) → In \(input): playing a 1 kHz tone at \(Int(level)) dBFS…"
            store.set(route, Double(0xC0 + daw - 1), float: false)
            do {
                try tone.start(channel: daw, dbfs: level)
            } catch {
                problem = error.localizedDescription
                if let saved { store.set(route, saved, float: false) }
                return
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
            let got = await sample([input])
            tone.stop()
            if let saved { store.set(route, saved, float: false) }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let r = got[input], r.mean > -60 else {
                problem = "Out \(out): nothing came back on In \(input). Check the loopback cable from Analog Out \(out) to Analog In \(input)."
                continue
            }
            let analog = r.mean + inCal.fullScaleDBu
            outputs[out] = Reading(fullScaleDBu: analog - level, ref: outputRef(out), date: Date())
            save()
        }
        status = "Output calibration finished. Routing is back as it was."
    }

    func stop() { cancel = true }

    func clear() { inputs = [:]; outputs = [:]; status = nil; problem = nil; save() }

    /// A DAW channel that no destination plays, so the tone only reaches the output being measured.
    private func spareDAWChannel() -> Int? {
        let dests = Array(0x20...0x2F) + Array(0x40...0x4F) + Array(0x60...0x6F) + Array(0xE0...0xE3)
        let used = Set(dests.compactMap { store.value("/symphony/route/\($0)").map(Int.init) })
        return (1...16).reversed().first { !used.contains(0xC0 + $0 - 1) }
    }

    // MARK: file

    private struct File: Codable {
        var level: Double
        var inputs: [Int: Reading]
        var outputs: [Int: Reading]
        var loopback: [Int: Int]
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anti-Symphony/calibration.json")
    }

    private var loading = false

    private func load() {
        guard let d = try? Data(contentsOf: Self.url), let f = try? JSONDecoder().decode(File.self, from: d) else { return }
        loading = true
        level = f.level; inputs = f.inputs; outputs = f.outputs; loopback = f.loopback
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let f = File(level: level, inputs: inputs, outputs: outputs, loopback: loopback)
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(f) { try? d.write(to: Self.url, options: .atomic) }
    }
}
