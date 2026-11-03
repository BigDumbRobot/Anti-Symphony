import Foundation
import SwiftUI

/// Speakers A–D: each is any output pair; the monitor source plays on the active one.
///
/// The box's own speaker sets are fixed (A = Analog Out 1–2, B = 3–4, measured), so switching is
/// done by routing: the monitor source goes to the active pair and the other assigned pairs get
/// "None". The main level, dim and mute act on the analog outputs the box's speaker layout covers,
/// so the layout is set to cover every assigned analog pair:
///   2 = Stereo (Out 1–2), 5 = 5.1 (Out 1–6), 6 = 7.1 (Out 1–8)   (1 = Line, 3/4 = 2/3 speaker sets)
/// Optical pairs can be speakers too, but the main level doesn't reach them.
/// Saved in ~/Library/Application Support/Anti-Symphony/speakers.json.
@MainActor
final class Speakers: ObservableObject {
    static let names = ["A", "B", "C", "D"]

    /// Left source ID of the monitor source pair (DAW 1–2 = 0xC0).
    @Published private(set) var source: Int = 0xC0
    /// Left destination ID of each speaker's output pair, or nil when unassigned.
    @Published private(set) var pairs: [Int?] = [0x20, nil, nil, nil]
    @Published private(set) var active = 0

    private let store: Store
    private let url: URL
    private var configured = false

    init(store: Store, url: URL = Speakers.defaultURL) {
        self.store = store
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

    static func isAnalog(_ dest: Int) -> Bool { (0x20...0x27).contains(dest) }

    /// The box speaker layout that puts every assigned analog pair under the main level.
    var neededLayout: Int {
        let top = pairs.compactMap { $0 }.filter(Self.isAnalog).max() ?? 0x20
        return top <= 0x20 ? 2 : top <= 0x24 ? 5 : 6
    }

    /// Analog outputs the main level, dim and mute act on.
    var coveredOutputs: String {
        switch neededLayout { case 2: return "Analog Out 1–2"; case 5: return "Analog Out 1–6"; default: return "Analog Out 1–8" }
    }

    // MARK: actions

    func select(_ i: Int) {
        guard pairs[i] != nil else { return }
        active = i
        apply()
    }

    func setSource(_ left: Int) {
        source = left
        apply()
    }

    func assign(_ i: Int, pair: Int?) {
        // A pair belongs to one speaker; switching it off routes it to None.
        if let pair { for j in pairs.indices where j != i && pairs[j] == pair { pairs[j] = nil } }
        if let old = pairs[i], old != pair { route(old, to: Names.none) }
        pairs[i] = pair
        if pairs[active] == nil, let first = pairs.firstIndex(where: { $0 != nil }) { active = first }
        apply()
    }

    /// Routes the source to the active pair, None to the other speaker pairs, and sets the layout.
    private func apply() {
        configured = true
        for (j, p) in pairs.enumerated() {
            guard let p else { continue }
            route(p, to: j == active ? source : Names.none)
        }
        setLayout()
        save()
    }

    private func route(_ pair: Int, to left: Int) {
        store.set("/symphony/route/\(pair)", Double(left), float: false)
        store.set("/symphony/route/\(pair + 1)", Double(left == Names.none ? Names.none : left + 1), float: false)
    }

    /// Changing the layout resets the box's main mute (measured), so mute and dim are put back.
    private func setLayout() {
        let mode = "/symphony/monitor/main/mode"
        let need = neededLayout
        guard Int(store.value(mode) ?? -1) != need else { return }
        let mute = store.value("/symphony/monitor/main/mute") ?? 0
        let dim = store.value("/symphony/monitor/main/dim") ?? 0
        store.set(mode, Double(need), float: false)
        store.set("/symphony/monitor/speakerset", 0, float: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [store] in
            store.set("/symphony/monitor/main/mute", mute, float: false)
            store.set("/symphony/monitor/main/dim", dim, float: false)
        }
    }

    // MARK: file

    private struct File: Codable { var source: Int; var pairs: [Int?]; var active: Int }

    private func load() {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d),
              f.pairs.count == 4 else { return }
        source = f.source; pairs = f.pairs; active = min(max(f.active, 0), 3)
        configured = true
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(File(source: source, pairs: pairs, active: active)) {
            try? d.write(to: url, options: .atomic)
        }
    }

    /// Before the first change, show what Out 1–2 plays now as the source.
    func adoptCurrentSource() {
        guard !configured, let v = store.value("/symphony/route/32") else { return }
        let id = Int(v)
        if id != Names.none { source = id }
    }
}

/// Speakers section for the Monitoring page.
struct SpeakerSetup: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var speakers: Speakers

    var body: some View {
        SwiftUI.Section {
            Picker("Monitor source", selection: Binding(get: { speakers.source }, set: { speakers.setSource($0) })) {
                SwiftUI.Section("Headphone mixes") {
                    Text("Bus A").tag(Names.busA)
                    Text("Bus B").tag(Names.busB)
                }
                SwiftUI.Section("Pairs") {
                    ForEach(Names.sourcePairs.filter { $0.id != Names.busA && $0.id != Names.busB }) { Text($0.name).tag($0.id) }
                }
                if !Names.sourcePairs.contains(where: { $0.id == speakers.source }) && speakers.source != Names.busA && speakers.source != Names.busB {
                    Text(Names.source(speakers.source)).tag(speakers.source)
                }
            }
            ForEach(0..<4, id: \.self) { i in
                HStack {
                    Picker("Speakers \(Speakers.names[i])", selection: Binding<Int>(
                        get: { speakers.pairs[i] ?? -1 },
                        set: { speakers.assign(i, pair: $0 < 0 ? nil : $0) })) {
                        Text("Off").tag(-1)
                        ForEach(Names.outputPairs) { Text($0.name).tag($0.id) }
                    }
                    if speakers.active == i && speakers.pairs[i] != nil {
                        Text("ACTIVE").font(.caption2).bold().foregroundStyle(Color.accentColor)
                    } else if speakers.pairs[i] != nil {
                        Button("Select") { speakers.select(i) }.controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Main output and speakers")
        } footer: {
            Text("The monitor source plays on the active speakers; the other assigned pairs are silent. The main level, DIM and MUTE act on \(speakers.coveredOutputs) (the box's speaker outputs start at Out 1), so don't use those outputs for line-level sends. Optical pairs switch but have no level control. Mirroring headphones follow the output they mirror, so a headphone mirroring the speakers goes quiet when you switch to another pair.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { speakers.adoptCurrentSource() }
    }
}
