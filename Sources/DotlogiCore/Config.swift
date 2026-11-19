import Foundation
import notify

/// User settings in ~/.config/dotlogi/config.json, shared by the resident process and the settings app.
public struct Config: Codable, Equatable {
    public struct DeviceSettings: Codable, Equatable {
        /// Pointer resolution written to the mouse, 200-4000.
        public var dpi: Int?
        /// SmartShift auto-disengage threshold, 1-254.
        public var smartShiftThreshold: Int?
        /// Invert the main wheel in firmware (true = "standard" direction while macOS natural scrolling is on).
        public var wheelInvert: Bool?
        /// High-resolution wheel reports (finer steps if macOS honours them; off = classic notches).
        public var wheelHiRes: Bool?
        /// Invert the thumb wheel in firmware.
        public var thumbWheelInvert: Bool?
        public init() {}
    }

    /// Per-button actions. Keys of `buttons`: "middle", "back", "forward".
    /// `gesture` (thumb button) and `modeShift` (button behind the wheel) take
    /// "click", "up", "down", "left", "right", or "mode": "zoom".
    public struct Profile: Codable, Equatable {
        public var buttons: [String: String]?
        public var gesture: [String: String]?
        public var modeShift: [String: String]?
        public init() {}
    }

    public var device = DeviceSettings()
    /// Mouse movement (raw units) before a held gesture button counts as a swipe.
    public var gestureThreshold: Int = 50
    /// Apps where back/forward are sent as cmd+[ / cmd+] instead of mouse buttons 4/5.
    public var keyNavigationApps: [String] = []
    /// Write button events and fired actions to stderr (off by default).
    public var eventLog: Bool = false
    /// "default" plus bundle-ID overrides; an override replaces only the entries it names.
    public var profiles: [String: Profile] = [:]

    public init() {}

    public static let defaultProfile = "default"
    public static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/dotlogi/config.json")

    public static func load() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: path))
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Config.path, options: .atomic)
    }

    /// The entry a profile sets itself, without falling back to default.
    public func ownEntry(profile: String, group: String, key: String) -> String? {
        let p = profiles[profile]
        switch group {
        case "buttons": return p?.buttons?[key]
        case "gesture": return p?.gesture?[key]
        case "modeShift": return p?.modeShift?[key]
        default: return nil
        }
    }

    /// Looks up the action for a slot ("gesture.left", "buttons.back") in the app's profile, then in default.
    public func actionText(group: String, key: String, bundleID: String?) -> String? {
        if let bundleID, let value = ownEntry(profile: bundleID, group: group, key: key) { return value }
        return ownEntry(profile: Config.defaultProfile, group: group, key: key)
    }

    /// Sets (or with nil, removes) one entry of a profile.
    public mutating func setEntry(profile: String, group: String, key: String, value: String?) {
        var p = profiles[profile] ?? Profile()
        func apply(_ dict: [String: String]?) -> [String: String]? {
            var d = dict ?? [:]
            d[key] = value
            return d.isEmpty ? nil : d
        }
        switch group {
        case "buttons": p.buttons = apply(p.buttons)
        case "gesture": p.gesture = apply(p.gesture)
        case "modeShift": p.modeShift = apply(p.modeShift)
        default: return
        }
        profiles[profile] = p
    }
}

/// What the resident process last saw, for the settings app. Written only when something changes.
public struct Status: Codable, Equatable {
    public var pid: Int32 = 0
    public var connected = false
    public var deviceName: String?
    public var battery = -1
    public var smartShift: String?
    public var inputMonitoring = false
    public var accessibility = false
    public var lastError: String?
    public var updatedAt = Date()
    public init() {}

    public static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/dotlogI/status.json")
    /// The app bundle whose main executable is the resident process (scripts/install.sh).
    public static let agentApp = URL(fileURLWithPath: "/Applications/dotlogI.app")

    public func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Status.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Status.path, options: .atomic)
        Signal.post(Signal.status)
    }

    public static func read() -> Status? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: path)).flatMap { try? decoder.decode(Status.self, from: $0) }
    }
}

/// Darwin notifications between the two processes. Posting costs nothing when nobody listens.
public enum Signal {
    public static let status = "local.dotlogi.status"
    /// Posted with the control ID appended (e.g. "local.dotlogi.press.c3") when a button goes down.
    public static let pressPrefix = "local.dotlogi.press."

    public static func post(_ name: String) { notify_post(name) }
}
