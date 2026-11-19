import SwiftUI

/// Our own dot drawing of the mouse seen from above (not Logitech artwork), with the controls as hotspots.
struct MouseSchematic: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette

    /// Design space 220 x 320.
    static let size = CGSize(width: 220, height: 320)

    static func body(in rect: CGRect) -> Path {
        let sx = rect.width / size.width, sy = rect.height / size.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(122, 12))
        path.addQuadCurve(to: p(184, 72), control: p(170, 14))
        path.addQuadCurve(to: p(178, 252), control: p(196, 160))
        path.addQuadCurve(to: p(120, 306), control: p(172, 302))
        path.addQuadCurve(to: p(40, 284), control: p(74, 312))
        path.addQuadCurve(to: p(10, 214), control: p(6, 268))
        path.addQuadCurve(to: p(50, 148), control: p(12, 168))
        path.addQuadCurve(to: p(64, 60), control: p(54, 100))
        path.addQuadCurve(to: p(122, 12), control: p(76, 14))
        path.closeSubpath()
        return path
    }

    /// Hotspot centre in design space, and which side its label sits on.
    static let spots: [(Slot, CGPoint, Bool)] = [
        (.middle, CGPoint(x: 120, y: 58), false),
        (.modeShift, CGPoint(x: 120, y: 108), false),
        (.thumbWheel, CGPoint(x: 46, y: 160), true),
        (.forward, CGPoint(x: 34, y: 186), true),
        (.back, CGPoint(x: 26, y: 212), true),
        (.gesture, CGPoint(x: 30, y: 252), true),
    ]

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / (Self.size.width + 200), geo.size.height / Self.size.height)
            let drawSize = CGSize(width: Self.size.width * scale, height: Self.size.height * scale)
            // Shifted right: the thumb-side labels on the left need more room than the right-side ones.
            let origin = CGPoint(x: (geo.size.width - drawSize.width) / 2 + 36, y: (geo.size.height - drawSize.height) / 2)
            let rect = CGRect(origin: origin, size: drawSize)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let shape = Self.body(in: rect)
                    let pitch: CGFloat = 7 * scale
                    var y = rect.minY
                    while y < rect.maxY {
                        var x = rect.minX
                        while x < rect.maxX {
                            if shape.contains(CGPoint(x: x, y: y)) {
                                context.fill(Path(ellipseIn: CGRect(x: x - 1.3, y: y - 1.3, width: 2.6, height: 2.6)), with: .color(palette.body))
                            }
                            x += pitch
                        }
                        y += pitch
                    }
                    // The wheel as a column of lit dots.
                    var wy = rect.minY + 36 * scale
                    while wy < rect.minY + 82 * scale {
                        let wx = rect.minX + 120 * scale
                        context.fill(Path(ellipseIn: CGRect(x: wx - 2, y: wy - 2, width: 4, height: 4)), with: .color(palette.muted))
                        wy += 5 * scale
                    }
                }
                ForEach(Self.spots, id: \.0) { slot, point, labelLeft in
                    let center = CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
                    Hotspot(slot: slot, labelLeft: labelLeft)
                        .position(x: labelLeft ? center.x - 70 : center.x + 70, y: center.y)
                }
            }
        }
    }
}

/// A selectable control: a dot on the mouse joined by a dotted leader to its name.
private struct Hotspot: View {
    @EnvironmentObject private var store: Store
    @Environment(\.palette) private var palette
    let slot: Slot
    let labelLeft: Bool

    var body: some View {
        let selected = store.slot == slot
        let lit = store.lit == slot
        Button { store.slot = slot } label: {
            HStack(spacing: 6) {
                if labelLeft { label(selected) }
                if labelLeft { leader }
                ZStack {
                    Circle().strokeBorder(lit ? palette.red : (selected ? palette.ink : palette.muted), lineWidth: 1.5)
                    Circle().fill(lit ? palette.red : (selected ? palette.ink : Color.clear)).padding(3.5)
                }
                .frame(width: 16, height: 16)
                .scaleEffect(lit ? 1.35 : 1)
                if !labelLeft { leader }
                if !labelLeft { label(selected) }
            }
            .frame(width: 156, alignment: labelLeft ? .trailing : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(slot.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func label(_ selected: Bool) -> some View {
        Text(slot.title)
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? palette.ink : palette.muted)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 3)
            .background(palette.background) // keeps the name readable over the dots
    }

    private var leader: some View {
        Line().stroke(palette.line, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            .frame(width: 18, height: 1)
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
