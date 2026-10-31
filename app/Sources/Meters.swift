import SwiftUI

/// Input meters from the box (about 15 updates a second). Separate from Store so meter updates
/// only redraw meter views. Meters are requested from symphonyd only while a view shows them.
final class Meters: ObservableObject {
    /// dBFS per input: board 1's 16 inputs (Analog In 1–8, Optical In 1–8), then board 2's.
    @Published private(set) var input: [Double] = Array(repeating: -120, count: 32)
    private var viewers = 0
    private var timer: Timer?
    var subscribe: (() -> Void)?

    func update(_ values: [Double]) {
        if values.count >= 16 { input = values }
    }

    /// Level for a routing source ID if it's a board input (0x20–0x3F), else nil.
    func level(forSource id: Int) -> Double? {
        (0x20...0x3F).contains(id) ? input[id - 0x20] : nil
    }

    func viewerAppeared() {
        viewers += 1
        if timer == nil {
            subscribe?()
            timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.subscribe?() }
        }
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            timer?.invalidate()
            timer = nil
            input = Array(repeating: -120, count: 32)
        }
    }
}

private func meterColor(_ db: Double) -> Color { db >= -3 ? .red : db >= -12 ? .yellow : .green }
private func meterFraction(_ db: Double) -> Double { min(max((db + 60) / 60, 0), 1) }   // -60 … 0 dBFS

/// Horizontal level meter, −60 to 0 dBFS.
struct MeterBar: View {
    let db: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(meterColor(db)).frame(width: g.size.width * meterFraction(db))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.07), value: db)
        .help(db <= -119 ? "−∞" : String(format: "%.1f dBFS", db))
        .accessibilityLabel("Level")
        .accessibilityValue(db <= -119 ? "silent" : String(format: "%.0f dB", db))
    }
}

/// Vertical level meter for mixer strips.
struct VerticalMeter: View {
    let db: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                Capsule().fill(.quaternary)
                Capsule().fill(meterColor(db)).frame(height: g.size.height * meterFraction(db))
            }
        }
        .frame(width: 5)
        .animation(.linear(duration: 0.07), value: db)
        .accessibilityLabel("Level")
        .accessibilityValue(db <= -119 ? "silent" : String(format: "%.0f dB", db))
    }
}

/// Asks symphonyd for meters while the view is on screen.
struct WantsMeters: ViewModifier {
    @EnvironmentObject var meters: Meters
    func body(content: Content) -> some View {
        content.onAppear { meters.viewerAppeared() }.onDisappear { meters.viewerDisappeared() }
    }
}

extension View {
    func wantsMeters() -> some View { modifier(WantsMeters()) }
}
