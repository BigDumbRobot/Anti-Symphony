import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case monitoring = "Monitoring", inputs = "Inputs & Outputs", routing = "Routing", mixer = "Mixer", clock = "Clock", profiles = "Profiles"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .monitoring: return "speaker.wave.2"
        case .inputs: return "cable.connector"
        case .routing: return "arrow.triangle.branch"
        case .mixer: return "slider.vertical.3"
        case .clock: return "metronome"
        case .profiles: return "square.stack"
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
                    case .profiles: ProfilesView()
                    }
                }
            }
            .frame(minWidth: 560, minHeight: 420)
            .navigationTitle((section ?? .monitoring).rawValue)
        }
        .overlay(alignment: .bottom) { ErrorBanner() }
        .overlay(alignment: .top) {
            if let n = store.notice {
                Text(n).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule()).padding(.top, 8)
            }
        }
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
                    headphoneSource(h)
                }
            }
            SwiftUI.Section {
                Text("Mirroring follows that output: if you reroute the output, the headphones follow. An own feed is independent of the outputs.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Identify (blink front panel)") {
                    store.send("/symphony/identify", [.int(1)])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { store.send("/symphony/identify", [.int(0)]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension MonitoringView {
    /// One picker per headphone: mirror an output (follows that output's routing) or take a
    /// source pair directly (its own feed, independent of the outputs).
    func headphoneSource(_ h: Int) -> some View {
        let mirrorPath = "/symphony/monitor/hp/\(h)/mirror"
        let left = "/symphony/route/\(Names.headphoneFeed(h))", right = "/symphony/route/\(Names.headphoneFeed(h) + 1)"
        let selection = Binding<String>(
            get: {
                let mirror = Int(store.value(mirrorPath) ?? -1)
                if mirror >= 0 { return "m\(mirror)" }
                let l = Int(store.value(left) ?? -1), r = Int(store.value(right) ?? -1)
                return r == l + 1 ? "d\(l)" : "custom"
            },
            set: { tag in
                guard let id = Int(tag.dropFirst()) else { return }
                if tag.hasPrefix("m") {
                    store.set(mirrorPath, Double(id), float: false)
                } else {
                    store.set(left, Double(id), float: false)
                    store.set(right, Double(id + 1), float: false)
                }
            })
        return Picker("Feed", selection: selection) {
            SwiftUI.Section("Mirror an output") {
                ForEach(Names.outputPairs) { Text("Mirror \($0.name)").tag("m\($0.id)") }
            }
            SwiftUI.Section("Own feed") {
                ForEach(Names.sourcePairs) { Text($0.name).tag("d\($0.id)") }
            }
            if selection.wrappedValue == "custom" {
                Text("\(Names.source(Int(store.value(left) ?? -1))) / \(Names.source(Int(store.value(right) ?? -1)))").tag("custom")
            }
        }
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
                            refPicker("/symphony/io/analog/in/\(c)/ref", Names.inputRefLevels)
                            Toggle("", isOn: store.flag("/symphony/io/analog/in/\(c)/softlimit")).labelsHidden()
                            refPicker("/symphony/io/analog/out/\(c)/ref", Names.outputRefLevels)
                        }
                    }
                }
            } header: {
                Text("Analog (8x8 Analog-Optical)")
            } footer: {
                Text("Levels measured with a loopback cable: +4 dBu and −10 dBV are 11.7 dB apart on this unit.")
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

    private func refPicker(_ path: String, _ levels: [Names.Item]) -> some View {
        let current = Int(store.value(path) ?? -1)
        return Picker("", selection: store.choice(path)) {
            ForEach(levels) { Text($0.name).tag($0.id) }
            if current >= 0, !levels.contains(where: { $0.id == current }) {
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
                        Strip(title: "In \(i)", base: "/symphony/mixer/\(mixer)/in/\(i)",
                              route: "/symphony/route/\((mixer == 1 ? 0x40 : 0x60) + i - 1)")
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
    var route: String? = nil
    var soloMute = true

    var body: some View {
        let fader = store.level("\(base)/fader", default: 0)
        VStack(spacing: 8) {
            Text(title).font(.caption).bold()
            if let route {
                Menu(Names.source(Int(store.value(route) ?? -1))) {
                    ForEach(Names.sources) { src in
                        Button(src.name) { store.set(route, Double(src.id), float: false) }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.caption2)
                .frame(width: 60)
                .help("Source for this mixer input")
            }
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
                Text("Choosing the clock source isn't available yet; these are the raw values the box reports.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Profiles

struct ProfilesView: View {
    @EnvironmentObject var store: Store
    @State private var newName = ""
    @State private var confirmOverwrite = false
    @State private var toDelete: String?

    var body: some View {
        Form {
            SwiftUI.Section {
                HStack {
                    TextField("Profile name", text: $newName)
                        .onSubmit(save)
                    Button("Save Current Setup", action: save)
                        .disabled(!Store.isValidProfileName(newName.trimmingCharacters(in: .whitespaces)))
                }
            } header: {
                Text("Save")
            } footer: {
                Text("A profile stores every setting: monitoring levels, headphone feeds, I/O levels, routing and both mixers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Saved profiles") {
                if store.profiles.isEmpty {
                    Text("No profiles yet.").foregroundStyle(.secondary)
                }
                ForEach(store.profiles, id: \.self) { name in
                    HStack {
                        Image(systemName: name == store.lastProfile ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(name == store.lastProfile ? Color.accentColor : .secondary)
                        Text(name)
                        Spacer()
                        Button("Load") { store.loadProfile(name) }
                        Button("Overwrite") { newName = name; confirmOverwrite = true }
                        Button(role: .destructive) { toDelete = name } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.send("/symphony/profile/list") }
        .confirmationDialog("Replace the profile \u{201C}\(newName)\u{201D} with the current setup?", isPresented: $confirmOverwrite) {
            Button("Replace") { store.saveProfile(newName.trimmingCharacters(in: .whitespaces)); newName = "" }
        }
        .confirmationDialog("Delete the profile \u{201C}\(toDelete ?? "")\u{201D}?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Delete", role: .destructive) { if let n = toDelete { store.deleteProfile(n) }; toDelete = nil }
        }
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard Store.isValidProfileName(name) else { return }
        if store.profiles.contains(name) { newName = name; confirmOverwrite = true; return }
        store.saveProfile(name)
        newName = ""
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
            if store.boxConnected && !store.profiles.isEmpty {
                Picker("Profile", selection: Binding(get: { store.lastProfile ?? "" },
                                                     set: { if !$0.isEmpty { store.loadProfile($0) } })) {
                    if store.lastProfile == nil { Text("Choose…").tag("") }
                    ForEach(store.profiles, id: \.self) { Text($0).tag($0) }
                }
            }
            Divider()
            Toggle("Mac volume keys control the Symphony", isOn: Binding(get: { VolumeKeys.enabled }, set: { VolumeKeys.enabled = $0 }))
                .help("When the Symphony is the Mac's sound output, the volume and mute keys change the main out level.")
            Toggle("Open at login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.set($0) }))
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
