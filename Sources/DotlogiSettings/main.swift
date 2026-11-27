import AppKit
import DotlogiCore
import SwiftUI

// Renders the window off screen to a PNG, without showing anything or taking focus:
//   DotlogiSettings --snapshot out.png [--pane buttons|scrolling] [--appearance dark|light] [--slot gesture]
//                   [--profile <bundle id>] [--press <slot>] [--config sample.json] [--status sample.json] [--scale 2]
//                   [--secure-input <app name>]
// With --config/--status the window shows that sample instead of your own settings (nothing is saved).
let args = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let output = option("--snapshot") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var preview: (Config, Status)?
        // Sample data only: if a sample was named but cannot be read, stop rather than fall back to the real settings.
        func fail(_ what: String) -> Never {
            FileHandle.standardError.write(Data("cannot read \(what)\n".utf8))
            exit(1)
        }
        if option("--status") != nil && option("--config") == nil { fail("--status without --config") }
        if let configPath = option("--config") {
            guard let data = FileManager.default.contents(atPath: configPath),
                  let config = try? JSONDecoder().decode(Config.self, from: data) else { fail(configPath) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var status = Status()
            if let statusPath = option("--status") {
                guard let data = FileManager.default.contents(atPath: statusPath),
                      let decoded = try? decoder.decode(Status.self, from: data) else { fail(statusPath) }
                status = decoded
            }
            status.pid = getpid() // shown as running
            preview = (config, status)
        }
        let store = Store(preview: preview, secureInputApp: option("--secure-input"))
        if let pane = option("--pane").flatMap({ name in Pane.allCases.first { "\($0)" == name } }) { store.pane = pane }
        if let slot = option("--slot").flatMap(Slot.init(rawValue:)) { store.slot = slot }
        if let profile = option("--profile") { store.profile = profile }
        if let slot = option("--press").flatMap(Slot.init(rawValue:)) { store.previewPress(slot) }
        let scale = CGFloat(Double(option("--scale") ?? "1") ?? 1)
        let size = NSSize(width: 940, height: 640)
        let host = NSHostingView(rootView: Root().environmentObject(store))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: option("--appearance") == "light" ? .aqua : .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()

        // Draw at the requested scale, with the window's rounded corners.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        let content = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        content.size = size
        host.cacheDisplay(in: host.bounds, to: content)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 12, yRadius: 12).addClip()
        content.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        exit(0)
    }
} else {
    DotlogiSettingsApp.main()
}
