import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case monitoring = "Monitoring", inputs = "Inputs & Outputs", routing = "Routing"
    case processing = "Input Processing", mixes = "Headphone Mixes", settings = "Settings", profiles = "Profiles"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .monitoring: return "speaker.wave.2"
        case .inputs: return "cable.connector"
        case .routing: return "arrow.triangle.branch"
        case .processing: return "waveform.badge.plus"
        case .mixes: return "headphones"
        case .settings: return "gearshape"
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
                    case .processing: InputProcessingView()
                    case .mixes: HeadphoneMixView()
                    case .settings: SettingsView()
                    case .profiles: ProfilesView()
                    }
                }
            }
            .frame(minWidth: 560, minHeight: 420)
            .navigationTitle((section ?? .monitoring).rawValue)
            .toolbar {
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .primaryAction) { CanadaBadge() }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) { CanadaBadge() }
                }
            }
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
            SwiftUI.Section {
                MonitorController()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            ForEach(1...2, id: \.self) { h in
                SwiftUI.Section("Headphones \(h)") {
                    HStack {
                        headphoneSource(h)
                        HStack(spacing: 2) {
                            DestinationLED(dest: Names.headphoneFeed(h), segments: 10)
                            DestinationLED(dest: Names.headphoneFeed(h) + 1, segments: 10)
                        }
                        .frame(height: 28)
                    }
                    Toggle("Mono", isOn: store.flag("/symphony/monitor/hp/\(h)/mono"))
                }
            }
            SwiftUI.Section {
                Text("Bus A and Bus B are the two headphone mixes (Headphone Mixes page). Mirroring follows that output: if you reroute the output, the headphones follow. An own feed is independent of the outputs.")
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
            SwiftUI.Section("Headphone mix") {
                Text("Bus A").tag("d\(Names.busA)")
                Text("Bus B").tag("d\(Names.busB)")
            }
            SwiftUI.Section("Mirror an output") {
                ForEach(Names.outputPairs) { Text("Mirror \($0.name)").tag("m\($0.id)") }
            }
            SwiftUI.Section("Own feed") {
                ForEach(Names.sourcePairs.filter { $0.id != Names.busA && $0.id != Names.busB }) {
                    Text($0.name).tag("d\($0.id)")
                }
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
                        Text("Input").foregroundStyle(.secondary)
                        Text("Input level").foregroundStyle(.secondary)
                        Text("Soft Limit").foregroundStyle(.secondary)
                        Text("Output level").foregroundStyle(.secondary)
                        Text("Output").foregroundStyle(.secondary)
                    }
                    ForEach(1...8, id: \.self) { c in
                        GridRow {
                            Text("Analog \(c)")
                            InputMeterBar(index: c - 1).frame(width: 110)
                            refPicker("/symphony/io/analog/in/\(c)/ref", Names.inputRefLevels)
                            Toggle("", isOn: store.flag("/symphony/io/analog/in/\(c)/softlimit")).labelsHidden()
                            refPicker("/symphony/io/analog/out/\(c)/ref", Names.outputRefLevels)
                            OutputMeter(dest: 0x20 + c - 1).frame(width: 90)
                        }
                    }
                }
            } header: {
                Text("Analog (8x8 Analog-Optical)")
            } footer: {
                Text("Levels measured with a loopback cable: +4 dBu and −10 dBV are 11.7 dB apart on this unit. The box only sends input meters: an output shows a level when it carries an input or a headphone bus (estimated), not yet when it plays from the DAW.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Optical") {
                Picker("Format", selection: store.choice("/symphony/io/optical/spdif")) {
                    Text("ADAT").tag(0)
                    Text("S/PDIF").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow {
                            ForEach(1...4, id: \.self) { k in
                                let c = row * 4 + k
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("In \(c)").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                                        InputMeterBar(index: 7 + c).frame(width: 70)
                                    }
                                    HStack(spacing: 6) {
                                        Text("Out \(c)").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                                        OutputMeter(dest: 0x28 + c - 1).frame(width: 70)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .wantsMeters()
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
        .wantsMeters()
    }

    private func row(_ dest: Names.Item) -> some View {
        let path = "/symphony/route/\(dest.id)"
        let current = Int(store.value(path) ?? -1)
        return HStack {
            Picker(dest.name, selection: store.choice(path)) {
                ForEach(Names.sources) { Text($0.name).tag($0.id) }
                if current >= 0, !Names.sources.contains(where: { $0.id == current }) {
                    Text(Names.source(current)).tag(current)
                }
            }
            OutputMeter(dest: dest.id).frame(width: 60)
        }
    }
}

// MARK: - Headphone mixes

/// Output meter row: level of whatever feeds the destination; faint when it isn't measured.
struct OutputMeter: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var outputMeters: Meters
    let dest: Int
    var body: some View {
        let db = Levels.destination(dest, store: store, meters: outputMeters)
        MeterBar(db: db ?? Levels.silent).opacity(db == nil ? 0.25 : 1)
            .help(db == nil ? "Not measured (the box doesn't send output meters; DAW playback isn't metered yet)" : "")
    }
}

/// Two small LED meters side by side.
struct LEDPair: View {
    let left: Double?, right: Double?
    var height: CGFloat = 28
    var body: some View {
        HStack(spacing: 2) { LEDMeter(db: left, segments: 10); LEDMeter(db: right, segments: 10) }
            .frame(height: height)
    }
}

/// Bus A and Bus B: the two zero-latency headphone mixes (the box's hardware mixers 1 and 2).
struct HeadphoneMixView: View {
    @EnvironmentObject var store: Store
    @AppStorage("mixesBus") private var mixer = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ForEach(1...2, id: \.self) { m in
                    Button { mixer = m } label: {
                        Text(Names.busName(m)).font(.headline).frame(width: 110, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .tint(mixer == m ? .accentColor : nil)
                    .background(mixer == m ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                Spacer()
                Menu("DAW Rough Mix") {
                    ForEach(0..<8, id: \.self) { p in
                        Button("DAW \(2 * p + 1)–\(2 * p + 2) on faders 15–16") { roughMix(dawPair: p) }
                    }
                }
                .fixedSize()
                .help("Puts a DAW output pair on input faders 15 and 16, panned left and right, so your session's rough mix plays in this bus with zero-latency inputs.")
            }
            .padding([.horizontal, .top])
            Text("Each headphone output picks Bus A or Bus B on the Monitoring page. Inputs are mixed in the box, with no latency.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal).padding(.top, 6)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(1...16, id: \.self) { i in
                        Strip(title: "In \(i)", base: "/symphony/mixer/\(mixer)/in/\(i)",
                              route: "/symphony/route/\((mixer == 1 ? 0x40 : 0x60) + i - 1)")
                    }
                    Divider()
                    Strip(title: "Return", base: "/symphony/mixer/\(mixer)/return")
                    Strip(title: Names.busName(mixer), base: "/symphony/mixer/\(mixer)/master", soloMute: false,
                          busMixer: mixer)
                }
                .padding()
            }
        }
        .wantsMeters()
    }

    private func roughMix(dawPair p: Int) {
        let first = mixer == 1 ? 0x40 : 0x60
        for (k, input) in [15, 16].enumerated() {
            store.set("/symphony/route/\(first + input - 1)", Double(0xC0 + 2 * p + k), float: false)
            store.set("/symphony/mixer/\(mixer)/in/\(input)/pan", k == 0 ? -1 : 1, float: true)
            store.set("/symphony/mixer/\(mixer)/in/\(input)/fader", 0, float: true)
            store.set("/symphony/mixer/\(mixer)/in/\(input)/mute", 0, float: false)
        }
    }
}

struct Strip: View {
    @EnvironmentObject var store: Store
    let title: String
    let base: String
    var route: String? = nil
    var soloMute = true
    var busMixer: Int? = nil

    var body: some View {
        let fader = store.level("\(base)/fader", default: 0)
        let src = route.map { Int(store.value($0) ?? -1) }
        VStack(spacing: 8) {
            Text(title).font(.caption).bold()
            if let route {
                Menu(Names.source(src ?? -1)) {
                    ForEach(Names.sources) { s in
                        Button(s.name) { store.set(route, Double(s.id), float: false) }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.caption2)
                .frame(width: 60)
                .help("Source for this mixer input")
            }
            if busMixer == nil {
                PanControl(value: store.number("\(base)/pan"))
            } else {
                Text("Output").font(.caption2).foregroundStyle(.secondary).frame(height: 26)
            }
            HStack(spacing: 4) {
                VerticalFader(value: fader)
                    .frame(width: 44, height: 220)
                if let busMixer {
                    BusLED(mixer: busMixer, right: false, segments: 40).frame(height: 220)
                    BusLED(mixer: busMixer, right: true, segments: 40).frame(height: 220)
                } else if let src {
                    SourceLED(source: src, segments: 40).frame(height: 220)
                }
            }
            .frame(minWidth: 56)
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
            if store.daemonReachable && store.boxConnected {
                MonitorController()
            } else {
                StatusBadge()
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
        .padding(12)
        .frame(width: 354)
    }
}
