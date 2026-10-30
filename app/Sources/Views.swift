import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case monitoring = "Monitoring", inputs = "Inputs & Outputs", routing = "Routing", mixer = "Mixer", clock = "Clock"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .monitoring: return "speaker.wave.2"
        case .inputs: return "cable.connector"
        case .routing: return "arrow.triangle.branch"
        case .mixer: return "slider.vertical.3"
        case .clock: return "metronome"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var section: Section? = .monitoring

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { StatusBadge().padding(10) }
        } detail: {
            Group {
                if !store.daemonReachable {
                    ContentUnavailableMessage(title: "symphonyd isn't running",
                                              detail: "Install it with `make install` in the Anti-Symphony folder.")
                } else if !store.boxConnected {
                    ContentUnavailableMessage(title: "Symphony not connected",
                                              detail: "Check the USB cable and that the box is powered on.")
                } else {
                    switch section ?? .monitoring {
                    case .monitoring: MonitoringView()
                    case .inputs: IOView()
                    case .routing: RoutingView()
                    case .mixer: MixerView()
                    case .clock: ClockView()
                    }
                }
            }
            .frame(minWidth: 560, minHeight: 420)
            .navigationTitle((section ?? .monitoring).rawValue)
        }
        .overlay(alignment: .bottom) { ErrorBanner() }
    }
}

struct StatusBadge: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let (color, text): (Color, String) = !store.daemonReachable ? (.red, "symphonyd offline")
            : !store.boxConnected ? (.orange, "Symphony not connected") : (.green, "Connected")
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct ContentUnavailableMessage: View {
    let title: String, detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(.init(detail)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if let e = store.lastError {
            HStack {
                Image(systemName: "exclamationmark.circle")
                Text(e).lineLimit(2)
                Spacer()
                Button("Dismiss") { store.clearError() }.buttonStyle(.borderless)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()
        }
    }
}

// MARK: - Monitoring

struct MonitoringView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Form {
            SwiftUI.Section("Main out") {
                LevelRow(title: "Level", value: store.level("/symphony/monitor/main/level"))
                HStack {
                    KeyToggle(title: "Mute", isOn: store.flag("/symphony/monitor/main/mute"), tint: .red)
                    KeyToggle(title: "Dim", isOn: store.flag("/symphony/monitor/main/dim"), tint: .orange)
                    KeyToggle(title: "Mono", isOn: store.flag("/symphony/monitor/main/mono"))
                    Spacer()
                    Stepper("Speaker set \(Int(store.value("/symphony/monitor/speakerset") ?? 0))",
                            value: store.number("/symphony/monitor/speakerset"), in: 0...3)
                }
            }
            ForEach(1...2, id: \.self) { h in
                SwiftUI.Section("Headphones \(h)") {
                    LevelRow(title: "Level", value: store.level("/symphony/monitor/hp/\(h)/level"))
                    HStack {
                        KeyToggle(title: "Mute", isOn: store.flag("/symphony/monitor/hp/\(h)/mute"), tint: .red)
                        KeyToggle(title: "Dim", isOn: store.flag("/symphony/monitor/hp/\(h)/dim"), tint: .orange)
                        KeyToggle(title: "Mono", isOn: store.flag("/symphony/monitor/hp/\(h)/mono"))
                    }
                    LabeledContent("Source") {
                        Text("Mirror any output: not available yet (the box's headphone source setting isn't decoded)")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
            SwiftUI.Section {
                Button("Identify (blink front panel)") {
                    store.send("/symphony/identify", [.int(1)])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { store.send("/symphony/identify", [.int(0)]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Inputs & outputs

struct IOView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Form {
            SwiftUI.Section {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Channel").foregroundStyle(.secondary)
                        Text("Input level").foregroundStyle(.secondary)
                        Text("Soft Limit").foregroundStyle(.secondary)
                        Text("Output level").foregroundStyle(.secondary)
                    }
                    ForEach(1...8, id: \.self) { c in
                        GridRow {
                            Text("Analog \(c)")
                            refPicker("/symphony/io/analog/in/\(c)/ref")
                            Toggle("", isOn: store.flag("/symphony/io/analog/in/\(c)/softlimit")).labelsHidden()
                            refPicker("/symphony/io/analog/out/\(c)/ref")
                        }
                    }
                }
            } header: {
                Text("Analog (8x8 Analog-Optical)")
            } footer: {
                Text("Level names are provisional until checked against the front panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Optical") {
                Picker("Format", selection: store.choice("/symphony/io/optical/spdif")) {
                    Text("ADAT").tag(0)
                    Text("S/PDIF").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
        }
        .formStyle(.grouped)
    }

    private func refPicker(_ path: String) -> some View {
        let current = Int(store.value(path) ?? -1)
        return Picker("", selection: store.choice(path)) {
            ForEach(Names.refLevels) { Text($0.name).tag($0.id) }
            if current >= 0, !Names.refLevels.contains(where: { $0.id == current }) {
                Text("Code \(current)").tag(current)
            }
        }
        .labelsHidden()
        .frame(width: 130)
    }
}

// MARK: - Routing

struct RoutingView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Form {
            SwiftUI.Section("Outputs") {
                ForEach(Names.outputs) { row($0) }
            }
            SwiftUI.Section("Recording channels (to the Mac)") {
                ForEach(Names.toMac) { row($0) }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ dest: Names.Item) -> some View {
        let path = "/symphony/route/\(dest.id)"
        let current = Int(store.value(path) ?? -1)
        return Picker(dest.name, selection: store.choice(path)) {
            ForEach(Names.sources) { Text($0.name).tag($0.id) }
            if current >= 0, !Names.sources.contains(where: { $0.id == current }) {
                Text(Names.source(current)).tag(current)
            }
        }
    }
}

// MARK: - Mixer

struct MixerView: View {
    @EnvironmentObject var store: Store
    @State private var mixer = 1

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Mixer", selection: $mixer) {
                Text("Mixer 1").tag(1)
                Text("Mixer 2").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .padding([.horizontal, .top])

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(1...16, id: \.self) { i in
                        Strip(title: "In \(i)", base: "/symphony/mixer/\(mixer)/in/\(i)")
                    }
                    Divider()
                    Strip(title: "Return", base: "/symphony/mixer/\(mixer)/return")
                    Strip(title: "Master", base: "/symphony/mixer/\(mixer)/master", soloMute: false)
                }
                .padding()
            }
        }
    }
}

struct Strip: View {
    @EnvironmentObject var store: Store
    let title: String
    let base: String
    var soloMute = true

    var body: some View {
        let fader = store.level("\(base)/fader", default: 0)
        VStack(spacing: 8) {
            Text(title).font(.caption).bold()
            Slider(value: store.number("\(base)/pan"), in: -1...1)
                .controlSize(.mini)
                .frame(width: 52)
                .help("Pan")
            VerticalFader(value: fader)
                .frame(width: 52, height: 220)
            Text(dbText(fader.wrappedValue, floor: -48)).font(.caption2).monospacedDigit()
            if soloMute {
                HStack(spacing: 2) {
                    KeyToggle(title: "S", isOn: store.flag("\(base)/solo"), tint: .yellow)
                    KeyToggle(title: "M", isOn: store.flag("\(base)/mute"), tint: .red)
                }
                .controlSize(.small)
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Clock

struct ClockView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Form {
            SwiftUI.Section("Sample rate") {
                Picker("Rate", selection: Binding(
                    get: { Int(store.value("/symphony/clock/rate") ?? 0) },
                    set: { store.set("/symphony/clock/rate", Double($0), float: true) })) {
                    ForEach(Names.rates, id: \.self) { Text(String(format: "%.1f kHz", Double($0) / 1000)).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Set through macOS, so it's the same as changing it in Audio MIDI Setup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Clock source") {
                LabeledContent("Source code", value: "\(Int(store.value("/symphony/clock/source") ?? -1))")
                LabeledContent("External clock status", value: "\(Int(store.value("/symphony/clock/external") ?? -1))")
                Text("Choosing the clock source isn't available yet; these are the raw values the box reports.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusBadge()
            if store.boxConnected {
                LevelRow(title: "Main", value: store.level("/symphony/monitor/main/level"))
                HStack {
                    KeyToggle(title: "Mute", isOn: store.flag("/symphony/monitor/main/mute"), tint: .red)
                    KeyToggle(title: "Dim", isOn: store.flag("/symphony/monitor/main/dim"), tint: .orange)
                }
                LevelRow(title: "Headphones 1", value: store.level("/symphony/monitor/hp/1/level"))
                LevelRow(title: "Headphones 2", value: store.level("/symphony/monitor/hp/2/level"))
            }
            Divider()
            HStack {
                Button("Open Symphony Control") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}
