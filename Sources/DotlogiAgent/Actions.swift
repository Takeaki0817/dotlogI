import ApplicationServices
import Foundation
import DotlogiCore

/// A keyboard shortcut such as "cmd+shift+z".
struct Shortcut {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    static let modifierNames: [String: CGEventFlags] = [
        "cmd": .maskCommand, "shift": .maskShift, "ctrl": .maskControl, "opt": .maskAlternate, "alt": .maskAlternate,
    ]
    static let arrowKeys: Set<CGKeyCode> = [123, 124, 125, 126]

    init?(_ text: String) {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            if let modifier = Shortcut.modifierNames[part] { flags.insert(modifier) }
            else if let code = KeyNames.codes[part], key == nil { key = code }
            else { return nil }
        }
        guard let key else { return nil }
        // System shortcuts on arrow keys (e.g. ctrl+→ for Spaces) only fire with these flags.
        if Shortcut.arrowKeys.contains(key) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        keyCode = key
        self.flags = flags
    }

    func post() {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// What a button or gesture direction does. Parsed from the config strings.
enum Action {
    case none
    case missionControl, appExpose, launchpad
    case back, forward
    case middleClick
    case smartShiftToggle
    case shortcut(Shortcut)

    init?(_ text: String) {
        switch text {
        case "none": self = .none
        case "mission-control": self = .missionControl
        case "app-expose": self = .appExpose
        case "launchpad": self = .launchpad
        case "back": self = .back
        case "forward": self = .forward
        case "smartshift-toggle": self = .smartShiftToggle
        case "middle-click": self = .middleClick
        default:
            guard let shortcut = Shortcut(text) else { return nil }
            self = .shortcut(shortcut)
        }
    }
}

enum SystemActions {
    private typealias DockNotify = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
    private static let dockNotify: DockNotify? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(symbol, to: DockNotify.self)
    }()

    static var isAvailable: Bool { dockNotify != nil }

    /// Mission Control, App Exposé and Launchpad through the Dock (no app launch, no AppKit).
    static func dock(_ notification: String) {
        dockNotify?(notification as CFString, nil)
    }

    /// A plain middle click at the pointer (for when the wheel button is assigned back to clicking).
    static func middleClick() {
        let location = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .center)?.post(tap: .cghidEventTap)
        }
    }

    /// Back / forward as mouse buttons 4 / 5, or as cmd+[ / cmd+] for apps that ignore those buttons.
    static func navigate(back: Bool, frontmost: String?, keyApps: Set<String>) {
        if let frontmost, keyApps.contains(frontmost) {
            Shortcut(back ? "cmd+[" : "cmd+]")?.post()
            return
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        let button = CGMouseButton(rawValue: back ? 3 : 4)!
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button)?.post(tap: .cghidEventTap)
        }
    }
}

/// Bundle ID of the frontmost app, looked up only when a button is pressed (no AppKit, no subscription).
enum FrontmostApp {
    private static var cache: [pid_t: String] = [:]

    static func bundleID() -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let front = windows.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let pid = front[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        if let cached = cache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        var url = URL(fileURLWithPath: String(cString: buffer))
        while url.path != "/" && url.pathExtension != "app" { url.deleteLastPathComponent() }
        guard url.pathExtension == "app", let bundle = CFBundleCreate(nil, url as CFURL),
              let identifier = CFBundleGetIdentifier(bundle) as String? else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[pid] = identifier
        return identifier
    }
}
