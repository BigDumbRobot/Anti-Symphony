import Foundation
import SwiftUI

/// Monitor speakers: three stereo pairs and three surround formats.
///
/// - MAIN, ALT, MINI: each any stereo output pair (ALT and MINI can be off; no pair is used twice).
///   The stereo source plays on the selected pair.
/// - QUAD (L R on Out 1–2, Ls Rs on Out 7–8), 5.1 (Out 1–6: L R C LFE Ls Rs), 7.1 (Out 1–8: L R C LFE Ls Rs Lrs Rrs):
///   DAW channels from the surround start, in that order.
/// Pressing a stereo pair while in surround goes back to stereo on that pair.
///
/// Switching is done by routing: whatever this drove before and doesn't drive now gets "None",
/// and other outputs are left alone. The box's speaker layout register sets which analog outputs
/// the main level, dim and mute reach (2 = Out 1–2, 5 = Out 1–6, 6 = Out 1–8), so it's set to
/// cover what's playing. Writing the layout resets the box's mute, so mute and dim are put back.
/// Saved in ~/Library/Application Support/Anti-Symphony/speakers.json.
@MainActor
final class Speakers: ObservableObject {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case main, alt, mini, quad, surround51, surround71
        var id: String { rawValue }
        var title: String {
            switch self {
            case .main: return "MAIN"; case .alt: return "ALT"; case .mini: return "MINI"
            case .quad: return "QUAD"; case .surround51: return "5.1"; case .surround71: return "7.1"
            }
        }
        var isStereo: Bool { self == .main || self == .alt || self == .mini }
        /// Analog outputs each surround channel plays on (destination IDs), in channel order.
        var outputs: [Int] {
            switch self {
            case .quad: return [0x20, 0x21, 0x26, 0x27]          // fronts Out 1–2, rears Out 7–8
            case .surround51: return Array(0x20...0x25)
            case .surround71: return Array(0x20...0x27)
            default: return []
            }
        }
        /// Where it plays, for labels.
        var outputsText: String {
            switch self { case .quad: return "Out 1–2 + 7–8"; case .surround51: return "Out 1–6"; case .surround71: return "Out 1–8"; default: return "" }
        }
        /// Surround channel count.
        var channels: Int { switch self { case .quad: return 4; case .surround51: return 6; case .surround71: return 8; default: return 2 } }
        var channelNames: [String] {
            switch self {
            case .quad: return ["L", "R", "Ls", "Rs"]
            case .surround51: return ["L", "R", "C", "LFE", "Ls", "Rs"]
            case .surround71: return ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"]
            default: return ["L", "R"]
            }
        }
    }

    /// Left source ID of the stereo source (DAW 1–2 = 0xC0).
    @Published private(set) var source = 0xC0
    /// First DAW channel of the surround source (0xC0 = DAW 1).
    @Published private(set) var surroundStart = 0xC0
    /// Left destination ID of each stereo pair (Analog Out 1–2 = 0x20); ALT and MINI can be off.
    @Published private(set) var main = 0x20
    @Published private(set) var alt: Int?
    @Published private(set) var mini: Int?
    @Published private(set) var mode: Mode = .main

    /// Outputs this drove last time (cleared to None when they stop being used).
    private var driven: Set<Int> = []
    private var configured = false

    private let value: (String) -> Double?
    private let send: (String, Double, Bool) -> Void
    private let later: (@escaping () -> Void) -> Void
    private let url: URL

    init(store: Store, url: URL = Speakers.defaultURL) {
        self.value = { store.value($0) }
        self.send = { store.set($0, $1, float: $2) }
        self.later = { f in
            nonisolated(unsafe) let f = f        // runs on the main queue, where it was made
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { f() }
        }
        self.url = url
        load()
    }

    /// For tests: the box's values and the writes go through closures.
    init(value: @escaping (String) -> Double?, send: @escaping (String, Double, Bool) -> Void, url: URL) {
        self.value = value
        self.send = send
        self.later = { $0() }
        self.url = url
        load()
    }

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anti-Symphony/speakers.json")
    }

    static func pairName(_ dest: Int?) -> String {
        guard let dest else { return "Off" }
        return Names.outputPairs.first { $0.id == dest }?.name ?? String(format: "Output 0x%02X", dest)
    }

    func pair(_ m: Mode) -> Int? {
        switch m { case .main: return main; case .alt: return alt; case .mini: return mini; default: return nil }
    }

    func isAvailable(_ m: Mode) -> Bool { !m.isStereo || pair(m) != nil }

    /// Pairs a stereo slot may use: every pair except those the other two slots use.
    func choices(for m: Mode) -> [Names.Item] {
        let taken = Set([Mode.main, .alt, .mini].filter { $0 != m }.compactMap { pair($0) })
        return Names.outputPairs.filter { !taken.contains($0.id) }
    }

    /// Output → source for the current mode.
    var targets: [Int: Int] {
        if mode.isStereo, let p = pair(mode) { return [p: source, p + 1: source == Names.none ? Names.none : source + 1] }
        var t: [Int: Int] = [:]
        for (k, dest) in mode.outputs.enumerated() { t[dest] = surroundStart + k }
        return t
    }

    /// The box's speaker layout that puts what's playing under the main level.
    var layout: Int {
        let top = targets.keys.filter { (0x20...0x27).contains($0) }.max() ?? 0x21
        return top <= 0x21 ? 2 : top <= 0x25 ? 5 : 6
    }

    var coveredOutputs: String { layout == 2 ? "Analog Out 1–2" : layout == 5 ? "Analog Out 1–6" : "Analog Out 1–8" }

    /// What the engineer should know about the current mode.
    var notice: String? {
        switch mode {
        case .quad:
            return "QUAD: front L and R play on Analog Out 1–2, rear L and R on Analog Out 7–8 (DAW channels 1–2 front, 3–4 rear from the surround source). Analog Out 3–6 also follow the main level while QUAD is on."
        case .surround51:
            return "5.1 plays on Analog Out 1–6 in the order L, R, C, LFE, Ls, Rs. Set your DAW's 5.1 output to this order (Pro Tools' default is L C R Ls Rs LFE)."
        case .surround71:
            return "7.1 plays on Analog Out 1–8 in the order L, R, C, LFE, Ls, Rs, Lrs, Rrs."
        default:
            return nil
        }
    }

    // MARK: actions

    func select(_ m: Mode) {
        guard isAvailable(m) else { return }
        mode = m
        apply()
    }

    func setSource(_ left: Int) { source = left; apply() }
    func setSurroundStart(_ first: Int) { surroundStart = first; apply() }

    /// Sets a stereo slot's pair (nil = off; MAIN can't be off). A pair another slot uses is refused.
    func assign(_ m: Mode, _ p: Int?) {
        guard m.isStereo else { return }
        if let p, !choices(for: m).contains(where: { $0.id == p }) { return }
        switch m {
        case .main: if let p { main = p }
        case .alt: alt = p
        case .mini: mini = p
        default: break
        }
        if !isAvailable(mode) { mode = .main }
        apply()
    }

    private func apply() {
        configured = true
        let t = targets
        for dest in driven.subtracting(t.keys) {
            send("/symphony/route/\(dest)", Double(Names.none), false)
        }
        for (dest, src) in t.sorted(by: { $0.key < $1.key }) {
            send("/symphony/route/\(dest)", Double(src), false)
        }
        driven = Set(t.keys)
        setLayout()
        save()
    }

    private func setLayout() {
        let path = "/symphony/monitor/main/mode"
        guard Int(value(path) ?? -1) != layout else { return }
        let mute = value("/symphony/monitor/main/mute") ?? 0
        let dim = value("/symphony/monitor/main/dim") ?? 0
        send(path, Double(layout), false)
        send("/symphony/monitor/speakerset", 0, false)
        later { [send] in
            send("/symphony/monitor/main/mute", mute, false)
            send("/symphony/monitor/main/dim", dim, false)
        }
    }

    /// Before the first change, show what Out 1–2 plays now as the stereo source.
    func adoptCurrentSource() {
        guard !configured, let v = value("/symphony/route/32"), Int(v) != Names.none else { return }
        source = Int(v)
    }

    // MARK: file

    private struct File: Codable {
        var source: Int, surroundStart: Int, main: Int, alt: Int?, mini: Int?, mode: Mode, driven: [Int]
    }

    private func load() {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else { return }
        source = f.source; surroundStart = f.surroundStart; main = f.main; alt = f.alt; mini = f.mini
        mode = f.mode; driven = Set(f.driven)
        configured = true
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let f = File(source: source, surroundStart: surroundStart, main: main, alt: alt, mini: mini, mode: mode, driven: driven.sorted())
        if let d = try? JSONEncoder().encode(f) { try? d.write(to: url, options: .atomic) }
    }
}

/// Speakers section for the Monitoring page.
struct SpeakerSetup: View {
    @EnvironmentObject var speakers: Speakers

    var body: some View {
        SwiftUI.Section {
            Picker("Stereo source", selection: Binding(get: { speakers.source }, set: { speakers.setSource($0) })) {
                SwiftUI.Section("Headphone mixes") {
                    Text("Bus A").tag(Names.busA)
                    Text("Bus B").tag(Names.busB)
                }
                SwiftUI.Section("Pairs") {
                    ForEach(Names.sourcePairs.filter { $0.id != Names.busA && $0.id != Names.busB }) { Text($0.name).tag($0.id) }
                }
                if ![Names.busA, Names.busB].contains(speakers.source) && !Names.sourcePairs.contains(where: { $0.id == speakers.source }) {
                    Text(Names.source(speakers.source)).tag(speakers.source)
                }
            }
            ForEach([Speakers.Mode.main, .alt, .mini]) { m in
                HStack {
                    Picker(m.title, selection: Binding<Int>(
                        get: { speakers.pair(m) ?? -1 },
                        set: { speakers.assign(m, $0 < 0 ? nil : $0) })) {
                        if m != .main { Text("Off").tag(-1) }
                        ForEach(speakers.choices(for: m)) { Text($0.name).tag($0.id) }
                    }
                    activeMark(m)
                }
            }
            Picker("Surround source", selection: Binding(get: { speakers.surroundStart }, set: { speakers.setSurroundStart($0) })) {
                Text("DAW 1–8").tag(0xC0)
                Text("DAW 9–16").tag(0xC8)
            }
            HStack(spacing: 8) {
                Text("Surround").foregroundStyle(.secondary)
                Spacer()
                ForEach([Speakers.Mode.quad, .surround51, .surround71]) { m in
                    Button(m.title) { speakers.select(m) }
                        .buttonStyle(.bordered)
                        .tint(speakers.mode == m ? .accentColor : nil)
                }
            }
            if let n = speakers.notice {
                Label(n, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
            }
        } header: {
            Text("Speakers")
        } footer: {
            Text("MAIN, ALT and MINI play the stereo source on their pair; QUAD plays DAW channels on Analog Out 1–2 (front) and 7–8 (rear); 5.1 and 7.1 on Analog Out 1–6 and 1–8. Pressing a stereo button goes back to stereo on that pair, and only outputs used here are switched. The main level, DIM and MUTE act on \(speakers.coveredOutputs) right now (the box counts its speaker outputs from Out 1), so don't use those for line-level sends. Optical pairs switch but have no level control.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { speakers.adoptCurrentSource() }
    }

    @ViewBuilder private func activeMark(_ m: Speakers.Mode) -> some View {
        if speakers.mode == m {
            Text("ACTIVE").font(.caption2).bold().foregroundStyle(Color.accentColor)
        } else if speakers.isAvailable(m) {
            Button("Select") { speakers.select(m) }.controlSize(.small)
        }
    }
}
