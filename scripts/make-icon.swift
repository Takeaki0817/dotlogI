// Draws the app icon: a black plate with a dot-matrix mouse lit white, and the gesture button lit red.
// Usage: swift scripts/make-icon.swift <out.iconset>   (then: iconutil -c icns <out.iconset>)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let red = NSColor(srgbRed: 0xD7 / 255, green: 0x19 / 255, blue: 0x21 / 255, alpha: 1)

/// The same top-down outline as the settings window, in a 220 x 320 design space.
func mousePath(in rect: CGRect) -> NSBezierPath {
    let sx = rect.width / 220, sy = rect.height / 320
    // Flip y: AppKit's origin is bottom-left.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.maxY - y * sy) }
    let path = NSBezierPath()
    path.move(to: p(122, 12))
    let curves: [(CGPoint, CGPoint)] = [
        (p(184, 72), p(170, 14)), (p(178, 252), p(196, 160)), (p(120, 306), p(172, 302)),
        (p(40, 284), p(74, 312)), (p(10, 214), p(6, 268)), (p(50, 148), p(12, 168)),
        (p(64, 60), p(54, 100)), (p(122, 12), p(76, 14)),
    ]
    var current = p(122, 12)
    for (to, control) in curves {
        // Quadratic -> cubic.
        let c1 = CGPoint(x: current.x + 2 / 3 * (control.x - current.x), y: current.y + 2 / 3 * (control.y - current.y))
        let c2 = CGPoint(x: to.x + 2 / 3 * (control.x - to.x), y: to.y + 2 / 3 * (control.y - to.y))
        path.curve(to: to, controlPoint1: c1, controlPoint2: c2)
        current = to
    }
    path.close()
    return path
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024

    // macOS icon grid: an 824 pt plate centred on the 1024 canvas.
    let plate = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)
    NSColor.black.setFill()
    platePath.fill()
    NSGraphicsContext.current?.saveGraphicsState()
    platePath.addClip()

    // Fewer, larger dots at small sizes so the shape survives.
    let across = max(6, min(21, Double(size) / 6))
    let pitch = plate.width / CGFloat(across)
    let mouseHeight = 0.84 * plate.height
    let mouseWidth = mouseHeight * 220 / 320 * 1.12
    let mouseRect = CGRect(x: plate.midX - mouseWidth / 2 + 0.03 * plate.width, y: plate.minY + 0.08 * plate.height,
                           width: mouseWidth, height: mouseHeight)
    let mouse = mousePath(in: mouseRect)
    let gesture = CGPoint(x: mouseRect.minX + 30 / 220 * mouseRect.width, y: mouseRect.maxY - 252 / 320 * mouseRect.height)
    let wheelX = mouseRect.minX + 120 / 220 * mouseRect.width
    // Lower than on the real mouse so the button seam above it is long enough to read at icon sizes.
    let wheelTop = mouseRect.maxY - 70 / 320 * mouseRect.height, wheelBottom = mouseRect.maxY - 128 / 320 * mouseRect.height

    var nearestToGesture: (CGPoint, CGFloat)?
    var y = plate.minY + pitch / 2
    while y < plate.maxY {
        var x = plate.minX + pitch / 2
        while x < plate.maxX {
            let point = CGPoint(x: x, y: y)
            if mouse.contains(point) {
                let d = hypot(point.x - gesture.x, point.y - gesture.y)
                if nearestToGesture == nil || d < nearestToGesture!.1 { nearestToGesture = (point, d) }
            }
            x += pitch
        }
        y += pitch
    }

    y = plate.minY + pitch / 2
    while y < plate.maxY {
        var x = plate.minX + pitch / 2
        while x < plate.maxX {
            let point = CGPoint(x: x, y: y)
            // Drop lone dots on the outline: keep a dot only if at least two of its four neighbours are inside too.
            let neighbours = [(pitch, 0), (-pitch, 0), (0, pitch), (0, -pitch)]
                .map { CGPoint(x: x + $0.0, y: y + $0.1) }
                .filter { mouse.contains($0) && !(abs($0.x - wheelX) < pitch / 2 && $0.y > wheelTop) } // the seam is empty
                .count
            let inside = mouse.contains(point) && neighbours >= 2
            let isGesture = nearestToGesture.map { $0.0 == point } ?? false
            let onWheelColumn = inside && abs(point.x - wheelX) < pitch / 2
            let onWheel = onWheelColumn && point.y <= wheelTop && point.y >= wheelBottom
            // The split between the left and right buttons, running from the wheel to the front edge.
            let onSeam = onWheelColumn && point.y > wheelTop
            let color: NSColor
            var radius = pitch * 0.30
            if isGesture {
                color = red
                radius = pitch * (size >= 64 ? 0.44 : 0.5)
            } else if onWheel {
                color = NSColor(white: 1, alpha: 1)
                radius = pitch * 0.4
            } else if onSeam {
                color = NSColor(white: 1, alpha: size >= 64 ? 0.09 : 0)
                radius = pitch * 0.2
            } else if inside {
                color = NSColor(white: 0.5, alpha: 1)
            } else {
                // Unlit LED dots across the plate; dropped at tiny sizes where they only add noise.
                color = NSColor(white: 1, alpha: size >= 64 ? 0.09 : 0)
                radius = pitch * 0.2
            }
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
            x += pitch
        }
        y += pitch
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    // A hairline edge so the black plate does not vanish on a dark Dock.
    NSColor(white: 1, alpha: 0.14).setStroke()
    let edge = NSBezierPath(roundedRect: plate.insetBy(dx: 1.5 * s, dy: 1.5 * s), xRadius: 184 * s, yRadius: 184 * s)
    edge.lineWidth = max(1, 3 * s)
    edge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
