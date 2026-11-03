import SwiftUI

/// "From Canada with love" with the Canadian flag, small and tone on tone (same as Pink Spider):
/// darker bars, a centre a shade lighter, and the maple leaf (the official flag's outline).
struct CanadaBadge: View {
    private static let leaf: [(CGFloat, CGFloat)] = [
        (-0.0223, 0.5000), (-0.0112, 0.2859), (-0.0387, 0.2615), (-0.2519, 0.2990), (-0.2231, 0.2196),
        (-0.2280, 0.2015), (-0.4615, 0.0124), (-0.4089, -0.0122), (-0.4005, -0.0318), (-0.4467, -0.1737),
        (-0.3122, -0.1452), (-0.2940, -0.1546), (-0.2680, -0.2159), (-0.1630, -0.1032), (-0.1355, -0.1174),
        (-0.1861, -0.3784), (-0.1050, -0.3315), (-0.0824, -0.3382), (0.0000, -0.5000), (0.0824, -0.3382),
        (0.1050, -0.3315), (0.1861, -0.3784), (0.1355, -0.1174), (0.1630, -0.1032), (0.2680, -0.2159),
        (0.2940, -0.1546), (0.3122, -0.1452), (0.4467, -0.1737), (0.4005, -0.0318), (0.4089, -0.0122),
        (0.4615, 0.0124), (0.2280, 0.2015), (0.2231, 0.2196), (0.2519, 0.2990), (0.0387, 0.2615),
        (0.0112, 0.2859), (0.0223, 0.5000)]

    var body: some View {
        VStack(spacing: 1) {
            Canvas { ctx, size in
                let r = CGRect(origin: .zero, size: size)
                ctx.clip(to: Path(roundedRect: r, cornerRadius: 1.5))
                let bar = r.width * 0.25
                ctx.fill(Path(CGRect(x: 0, y: 0, width: bar, height: r.height)), with: .color(.primary.opacity(0.22)))
                ctx.fill(Path(CGRect(x: r.width - bar, y: 0, width: bar, height: r.height)), with: .color(.primary.opacity(0.22)))
                ctx.fill(Path(CGRect(x: bar, y: 0, width: r.width - 2 * bar, height: r.height)), with: .color(.primary.opacity(0.07)))
                let s = r.height * 0.86, c = CGPoint(x: r.midX, y: r.midY - s * 0.01)
                var p = Path()
                for (i, pt) in Self.leaf.enumerated() {
                    let q = CGPoint(x: c.x + pt.0 * s, y: c.y + pt.1 * s)
                    if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                }
                p.closeSubpath()
                ctx.fill(p, with: .color(.primary.opacity(0.30)))
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.5),
                           with: .color(.primary.opacity(0.18)), lineWidth: 0.8)
            }
            .frame(width: 36, height: 18)
            Text("From Canada with love")
                .font(.system(size: 9).italic())
                .foregroundStyle(.secondary.opacity(0.8))
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)     // clear of the window's rounded corner
        .offset(y: 3)               // centred on the toolbar, not its top edge
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From Canada with love")
    }
}
