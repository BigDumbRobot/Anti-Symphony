import SwiftUI

// Hardware-style controls: pan, rotary knobs, lit keys and LED meters.

/// Pan, −1 (left) … 1 (right). Draws outward from the centre so it can't be read as a level.
/// Drag sideways; double-click returns it to the centre.
struct PanControl: View {
    @Binding var value: Double
    var width: CGFloat = 56

    static func text(_ v: Double) -> String {
        let n = Int((abs(v) * 100).rounded())
        return n == 0 ? "C" : (v < 0 ? "L\(n)" : "R\(n)")
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { g in
                let w = g.size.width, mid = w / 2, x = mid + CGFloat(value) * mid
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 4)
                    Rectangle().fill(Color.accentColor)
                        .frame(width: max(1, abs(x - mid)), height: 4)
                        .offset(x: min(x, mid))
                    Rectangle().fill(.secondary).frame(width: 1, height: 10).offset(x: mid - 0.5)
                    Circle().fill(Color(nsColor: .controlColor))
                        .overlay(Circle().stroke(.secondary, lineWidth: 0.5))
                        .frame(width: 10, height: 10)
                        .offset(x: x - 5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    var v = Double((d.location.x - mid) / mid)
                    if abs(v) < 0.04 { v = 0 }          // centre detent
                    value = (min(max(v, -1), 1) * 100).rounded() / 100
                })
                .onTapGesture(count: 2) { value = 0 }
            }
            .frame(width: width, height: 12)
            Text(Self.text(value)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .help("Pan (double-click to centre)")
        .accessibilityRepresentation {
            Slider(value: $value, in: -1...1) { Text("Pan") }
        }
        .accessibilityValue(Self.text(value))
    }
}

/// Monitor-controller palette (dark hardware panel in both light and dark mode).
enum Panel {
    static let face = LinearGradient(colors: [Color(white: 0.20), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
    static let well = Color(white: 0.07)
    static let label = Color(white: 0.62)
    static let text = Color(white: 0.92)
    static let ring = Color(red: 0.36, green: 0.78, blue: 1.0)
}

/// Rotary level knob with an LED arc. Drag up/down (or use the arrow keys) to turn it.
struct RotaryKnob: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -64...0
    var size: CGFloat = 150
    var label: String = ""
    var dimmed = false
    var showReadout = true

    @State private var dragStart: Double?

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }
    private let sweep = 270.0       // degrees, from 7:30 to 4:30

    var body: some View {
        let ticks = size > 100 ? 31 : 17
        ZStack {
            // LED ring
            ForEach(0..<ticks, id: \.self) { i in
                let f = Double(i) / Double(ticks - 1)
                Capsule()
                    .fill(f <= fraction + 0.0001 ? (dimmed ? Color.orange : Panel.ring) : Color(white: 0.24))
                    .frame(width: size > 100 ? 3 : 2, height: size * 0.07)
                    .offset(y: -size * 0.47)
                    .rotationEffect(.degrees(-sweep / 2 + f * sweep))
                    .shadow(color: f <= fraction ? (dimmed ? .orange : Panel.ring).opacity(0.6) : .clear, radius: 2)
            }
            // knob body
            Circle()
                .fill(AngularGradient(colors: [Color(white: 0.34), Color(white: 0.14), Color(white: 0.30),
                                               Color(white: 0.12), Color(white: 0.34)], center: .center))
                .overlay(Circle().fill(RadialGradient(colors: [Color(white: 0.26), Color(white: 0.09)],
                                                      center: .init(x: 0.4, y: 0.3), startRadius: 0, endRadius: size * 0.4))
                    .padding(size * 0.05))
                .overlay(Circle().stroke(Color.black.opacity(0.8), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: size * 0.05, y: size * 0.03)
                .frame(width: size * 0.74, height: size * 0.74)
            // pointer
            Capsule().fill(Panel.text)
                .frame(width: max(2, size * 0.025), height: size * 0.14)
                .offset(y: -size * 0.26)
                .rotationEffect(.degrees(-sweep / 2 + fraction * sweep))
            if showReadout {
                VStack(spacing: 0) {
                    Text(dbText(value, floor: range.lowerBound))
                        .font(.system(size: size * 0.12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Panel.text)
                    if !label.isEmpty {
                        Text(label).font(.system(size: size * 0.07, weight: .medium)).foregroundStyle(Panel.label)
                    }
                }
                .offset(y: size * 0.03)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { d in
                if dragStart == nil { dragStart = value }
                let perPoint = (range.upperBound - range.lowerBound) / Double(size * 1.6)
                let v = (dragStart ?? value) - Double(d.translation.height) * perPoint
                value = min(max(v.rounded(), range.lowerBound), range.upperBound)
            }
            .onEnded { _ in dragStart = nil })
        .help("Drag up or down to change the level")
        .accessibilityElement()
        .accessibilityLabel(label.isEmpty ? "Level" : label)
        .accessibilityValue(dbText(value, floor: range.lowerBound))
        .accessibilityAdjustableAction { dir in
            value = min(max(value + (dir == .increment ? 1 : -1), range.lowerBound), range.upperBound)
        }
    }
}

/// Big lit key (MUTE, DIM...): glows in its colour when on.
struct PanelKey: View {
    let title: String
    @Binding var isOn: Bool
    var color: Color = .red
    var width: CGFloat = 92
    var height: CGFloat = 40
    var font: Font = .system(size: 13, weight: .bold)

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title)
                .font(font).tracking(1)
                .foregroundStyle(isOn ? Color.white : Panel.label)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isOn ? AnyShapeStyle(color.gradient) : AnyShapeStyle(LinearGradient(
                            colors: [Color(white: 0.27), Color(white: 0.17)], startPoint: .top, endPoint: .bottom)))
                )
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.7), lineWidth: 1))
                .shadow(color: isOn ? color.opacity(0.7) : .black.opacity(0.4), radius: isOn ? 6 : 1.5, y: isOn ? 0 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Small selector key with an LED (speaker sets, headphone bus).
struct SelectKey: View {
    let title: String
    let selected: Bool
    var color: Color = Panel.ring
    var width: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Circle().fill(selected ? color : Color(white: 0.22))
                    .frame(width: 5, height: 5)
                    .shadow(color: selected ? color : .clear, radius: 3)
                Text(title).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Panel.text : Panel.label)
            }
            .frame(width: width, height: 30)
            .background(RoundedRectangle(cornerRadius: 5).fill(LinearGradient(
                colors: [Color(white: 0.25), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Segmented LED meter, vertical, −60 … 0 dBFS. nil = no measurement available (dark).
struct LEDMeter: View {
    let db: Double?
    var segments = 24

    var body: some View {
        let lit = db.map { Int((min(max(($0 + 60) / 60, 0), 1) * Double(segments)).rounded()) } ?? 0
        VStack(spacing: 1.5) {
            ForEach((0..<segments).reversed(), id: \.self) { i in
                let segDb = -60 + 60 * Double(i + 1) / Double(segments)
                let c: Color = segDb > -3 ? .red : segDb > -12 ? .yellow : .green
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? c : c.opacity(db == nil ? 0.06 : 0.14))
            }
        }
        .frame(width: 6)
        .animation(.linear(duration: 0.07), value: lit)
        .help(db.map { $0 <= -119 ? "−∞" : String(format: "%.1f dBFS", $0) } ?? "No meter for this source")
        .accessibilityLabel("Level")
        .accessibilityValue(db.map { $0 <= -119 ? "silent" : String(format: "%.0f dB", $0) } ?? "not measured")
    }
}
