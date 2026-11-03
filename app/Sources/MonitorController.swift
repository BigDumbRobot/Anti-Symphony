import SwiftUI

/// Monitor controller: big main-level knob, DIM and MUTE, speaker sets, mono, and both
/// headphones (level, Bus A/B feed, mute). Shown in the menu bar and on the Monitoring page.
struct MonitorController: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var speakers: Speakers

    private let main = "/symphony/monitor/main"

    var body: some View {
        VStack(spacing: 14) {
            header
            HStack(alignment: .center, spacing: 18) {
                stereoMeter(dest: speakers.pair(speakers.mode) ?? 0x20, labels: ("L", "R"))
                RotaryKnob(value: store.level("\(main)/level"), size: 168, label: "MAIN",
                           dimmed: store.flag("\(main)/dim").wrappedValue)
                stereoMeter(dest: 0x20, labels: ("L", "R")).hidden()     // keeps the knob centred
            }
            HStack(spacing: 14) {
                PanelKey(title: "DIM", isOn: store.flag("\(main)/dim"), color: .orange, width: 118, height: 44)
                PanelKey(title: "MUTE", isOn: store.flag("\(main)/mute"), color: .red, width: 118, height: 44)
            }
            speakerRow
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

    private var speakerRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach([Speakers.Mode.main, .alt, .mini]) { m in
                    let ok = speakers.isAvailable(m)
                    SelectKey(title: m.title, selected: speakers.mode == m, width: 54) { speakers.select(m) }
                        .opacity(ok ? 1 : 0.35)
                        .disabled(!ok)
                        .help(ok ? "\(m.title): \(Speakers.pairName(speakers.pair(m)))" : "\(m.title) is off (Monitoring page)")
                }
                Spacer(minLength: 4)
                PanelKey(title: "MONO", isOn: store.flag("\(main)/mono"), color: Panel.ring, width: 60, height: 30,
                         font: .system(size: 10, weight: .bold))
            }
            HStack(spacing: 6) {
                ForEach([Speakers.Mode.quad, .surround51, .surround71]) { m in
                    SelectKey(title: m.title, selected: speakers.mode == m, color: .purple, width: 54) { speakers.select(m) }
                        .help("\(m.title): \(m.outputsText) (\(m.channelNames.joined(separator: " ")))")
                }
                Spacer(minLength: 4)
                Text(speakers.mode.isStereo ? Speakers.pairName(speakers.pair(speakers.mode)) : speakers.mode.outputsText.uppercased())
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Panel.label)
                    .frame(width: 60).lineLimit(1).minimumScaleFactor(0.7)
            }
            if speakers.mode == .quad {
                Text("Front: Analog Out 1–2 · Rear: Analog Out 7–8")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
            }
        }
    }

    private func stereoMeter(dest: Int, labels: (String, String)) -> some View {
        HStack(spacing: 3) {
            DestinationLED(dest: dest)
            DestinationLED(dest: dest + 1)
        }
        .frame(height: 130)
        .help(speakers.mode.isStereo ? Speakers.pairName(speakers.pair(speakers.mode)) : "Analog Out 1–2 (front L/R)")
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
                DestinationLED(dest: feed, segments: 14)
                RotaryKnob(value: store.level("\(base)/level"), size: 74,
                           dimmed: store.flag("\(base)/dim").wrappedValue)
                DestinationLED(dest: feed + 1, segments: 14)
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
            feedMenu(h, label: onBus != nil ? "HP MIX" : feedName(h, mirroring: mirroring))
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
