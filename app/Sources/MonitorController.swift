import SwiftUI

/// Monitor controller: big main-level knob, DIM and MUTE, speaker sets, mono, and both
/// headphones (level, Bus A/B feed, mute). Shown in the menu bar and on the Monitoring page.
struct MonitorController: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var meters: Meters

    private let main = "/symphony/monitor/main"

    var body: some View {
        VStack(spacing: 14) {
            header
            HStack(alignment: .center, spacing: 18) {
                stereoMeter(dest: 0x20, labels: ("L", "R"))
                RotaryKnob(value: store.level("\(main)/level"), size: 168, label: "MAIN",
                           dimmed: store.flag("\(main)/dim").wrappedValue)
                stereoMeter(dest: 0x20, labels: ("L", "R")).hidden()     // keeps the knob centred
            }
            HStack(spacing: 14) {
                PanelKey(title: "DIM", isOn: store.flag("\(main)/dim"), color: .orange, width: 118, height: 44)
                PanelKey(title: "MUTE", isOn: store.flag("\(main)/mute"), color: .red, width: 118, height: 44)
            }
            speakers
            Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                headphone(1)
                Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1).padding(.vertical, 4)
                headphone(2)
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 14).fill(Panel.face))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .wantsMeters()
    }

    private var header: some View {
        HStack {
            Text("SYMPHONY").font(.system(size: 11, weight: .heavy)).tracking(2.5).foregroundStyle(Panel.text)
            Spacer()
            Circle().fill(store.boxConnected ? Color.green : .orange).frame(width: 6, height: 6)
                .shadow(color: store.boxConnected ? .green : .orange, radius: 2)
            Text(store.boxConnected ? "ONLINE" : "OFFLINE").font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundStyle(Panel.label)
        }
    }

    private var speakers: some View {
        let set = Int(store.value("/symphony/monitor/speakerset") ?? 0)
        return HStack(spacing: 6) {
            Text("SPEAKERS").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Panel.label)
            Spacer(minLength: 4)
            ForEach(0..<4, id: \.self) { s in
                SelectKey(title: ["A", "B", "C", "D"][s], selected: set == s, width: 34) {
                    store.set("/symphony/monitor/speakerset", Double(s), float: false)
                }
                .help("Speaker set \(["A", "B", "C", "D"][s])")
            }
            Spacer(minLength: 4)
            PanelKey(title: "MONO", isOn: store.flag("\(main)/mono"), color: Panel.ring, width: 52, height: 30,
                     font: .system(size: 10, weight: .bold))
        }
    }

    private func stereoMeter(dest: Int, labels: (String, String)) -> some View {
        HStack(spacing: 3) {
            LEDMeter(db: Levels.destination(dest, store: store, meters: meters))
            LEDMeter(db: Levels.destination(dest + 1, store: store, meters: meters))
        }
        .frame(height: 130)
        .help("Analog Out 1–2")
    }

    private func headphone(_ h: Int) -> some View {
        let base = "/symphony/monitor/hp/\(h)"
        let feed = Names.headphoneFeed(h)
        let left = Int(store.value("/symphony/route/\(feed)") ?? -1)
        let mirroring = Int(store.value("\(base)/mirror") ?? -1) >= 0
        let onBus = mirroring ? nil : (left == Names.busA ? 1 : left == Names.busB ? 2 : nil)
        return VStack(spacing: 8) {
            Text("PHONES \(h)").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Panel.label)
            HStack(spacing: 6) {
                LEDMeter(db: Levels.destination(feed, store: store, meters: meters), segments: 14)
                RotaryKnob(value: store.level("\(base)/level"), size: 74,
                           dimmed: store.flag("\(base)/dim").wrappedValue)
                LEDMeter(db: Levels.destination(feed + 1, store: store, meters: meters), segments: 14)
            }
            .frame(height: 74)
            HStack(spacing: 4) {
                ForEach(1...2, id: \.self) { b in
                    SelectKey(title: b == 1 ? "BUS A" : "BUS B", selected: onBus == b, width: 46) {
                        let src = b == 1 ? Names.busA : Names.busB
                        store.set("/symphony/route/\(feed)", Double(src), float: false)
                        store.set("/symphony/route/\(feed + 1)", Double(src + 1), float: false)
                    }
                }
            }
            feedMenu(h, label: onBus != nil ? "OTHER FEED…" : feedName(h, mirroring: mirroring))
            HStack(spacing: 4) {
                PanelKey(title: "DIM", isOn: store.flag("\(base)/dim"), color: .orange, width: 46, height: 24,
                         font: .system(size: 9, weight: .bold))
                PanelKey(title: "MUTE", isOn: store.flag("\(base)/mute"), color: .red, width: 46, height: 24,
                         font: .system(size: 9, weight: .bold))
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Any feed for a headphone: Bus A/B, mirror any output pair, or any source pair directly.
    private func feedMenu(_ h: Int, label: String) -> some View {
        let feed = Names.headphoneFeed(h)
        func own(_ id: Int) {
            store.set("/symphony/route/\(feed)", Double(id), float: false)
            store.set("/symphony/route/\(feed + 1)", Double(id + 1), float: false)
        }
        return Menu {
            SwiftUI.Section("Headphone mix") {
                Button("Bus A") { own(Names.busA) }
                Button("Bus B") { own(Names.busB) }
            }
            SwiftUI.Section("Mirror an output") {
                ForEach(Names.outputPairs) { o in
                    Button("Mirror \(o.name)") { store.set("/symphony/monitor/hp/\(h)/mirror", Double(o.id), float: false) }
                }
            }
            SwiftUI.Section("Own feed") {
                ForEach(Names.sourcePairs.filter { $0.id != Names.busA && $0.id != Names.busB }) { p in
                    Button(p.name) { own(p.id) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Panel.label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Phones \(h) feed: Bus A, Bus B, any output, or any source pair")
    }

    private func feedName(_ h: Int, mirroring: Bool) -> String {
        let mirror = Int(store.value("/symphony/monitor/hp/\(h)/mirror") ?? -1)
        if mirroring { return "Mirror " + (Names.outputPairs.first { $0.id == mirror }?.name ?? "output") }
        let l = Int(store.value("/symphony/route/\(Names.headphoneFeed(h))") ?? -1)
        return Names.sourcePairs.first { $0.id == l }?.name ?? Names.source(l)
    }
}
