import SwiftUI

@main
struct SymphonyControlApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Symphony Control", id: "main") {
            ContentView().environmentObject(store)
        }
        .defaultSize(width: 900, height: 640)

        MenuBarExtra("Symphony", systemImage: "hifispeaker.fill") {
            MenuBarView().environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}
