import SwiftUI

@main
struct SymphonyControlApp: App {
    @StateObject private var store: Store
    @StateObject private var calibration: Calibration
    @StateObject private var processing = InputProcessing()
    @StateObject private var speakers: Speakers

    init() {
        let s = Store()
        _store = StateObject(wrappedValue: s)
        _calibration = StateObject(wrappedValue: Calibration(store: s, meters: s.meters))
        _speakers = StateObject(wrappedValue: Speakers(store: s))
    }

    var body: some Scene {
        Window("Symphony Control", id: "main") {
            ContentView()
                .environmentObject(store).environmentObject(store.meters)
                .environmentObject(calibration).environmentObject(processing).environmentObject(speakers)
        }
        .defaultSize(width: 1000, height: 720)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Anti-Symphony Manual") { openManual() }
                Button("Anti-Symphony on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/BigDumbRobot/Anti-Symphony")!)
                }
            }
        }

        MenuBarExtra("Symphony", systemImage: "hifispeaker.fill") {
            MenuBarView().environmentObject(store).environmentObject(store.meters).environmentObject(speakers)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The PDF manual the installer copies next to symphonyd, or the copy on GitHub.
func openManual() {
    let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Anti-Symphony/Anti-Symphony Manual.pdf")
    if FileManager.default.fileExists(atPath: local.path) {
        NSWorkspace.shared.open(local)
    } else {
        NSWorkspace.shared.open(URL(string: "https://github.com/BigDumbRobot/Anti-Symphony/blob/main/docs/Anti-Symphony-Manual.pdf")!)
    }
}
