import SwiftUI

@main
struct SymphonyControlApp: App {
    @StateObject private var store: Store
    @StateObject private var calibration: Calibration
    @StateObject private var processing = InputProcessing()

    init() {
        let s = Store()
        _store = StateObject(wrappedValue: s)
        _calibration = StateObject(wrappedValue: Calibration(store: s, meters: s.meters))
    }

    var body: some Scene {
        Window("Symphony Control", id: "main") {
            ContentView()
                .environmentObject(store).environmentObject(store.meters)
                .environmentObject(calibration).environmentObject(processing)
        }
        .defaultSize(width: 1000, height: 720)

        MenuBarExtra("Symphony", systemImage: "hifispeaker.fill") {
            MenuBarView().environmentObject(store).environmentObject(store.meters)
        }
        .menuBarExtraStyle(.window)
    }
}
