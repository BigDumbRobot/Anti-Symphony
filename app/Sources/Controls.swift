import SwiftUI

/// Level in dB as text: "−25.0 dB", "−∞" at the bottom of a fader.
func dbText(_ v: Double, floor: Double? = nil) -> String {
    if let floor, v <= floor { return "−∞" }
    return String(format: "%@%.0f dB", v < 0 ? "−" : "", abs(v))
}

/// Horizontal level control with a dB readout.
struct LevelRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -64...0

    var body: some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: $value, in: range, step: 1)
            Text(dbText(value)).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
    }
}

/// Small on/off button styled like a hardware key (mute, dim, solo...).
struct KeyToggle: View {
    let title: String
    @Binding var isOn: Bool
    var tint: Color = .accentColor

    var body: some View {
        Button(title) { isOn.toggle() }
            .buttonStyle(.bordered)
            .tint(isOn ? tint : nil)
            .background(isOn ? tint.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityValue(isOn ? "on" : "off")
    }
}

/// Vertical mixer fader. Double-click returns it to 0 dB.
struct VerticalFader: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -48...0

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .bottom) {
                Capsule().fill(.quaternary).frame(width: 6)
                Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: 6, height: max(0, h * fraction))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .controlColor))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary, lineWidth: 0.5))
                    .overlay(Rectangle().fill(.secondary).frame(height: 1))
                    .frame(width: 30, height: 16)
                    .offset(y: -(h - 16) * fraction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = 1 - min(max((drag.location.y - 8) / max(h - 16, 1), 0), 1)
                value = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
            })
            .onTapGesture(count: 2) { value = 0 }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: 1) { Text("Fader") }
        }
    }
}
