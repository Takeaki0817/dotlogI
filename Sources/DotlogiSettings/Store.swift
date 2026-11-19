import AppKit
import DotlogiCore
import notify
import SwiftUI

/// The physical controls the window can select.
enum Slot: String, CaseIterable, Identifiable {
    case middle, modeShift, forward, back, gesture, thumbWheel
    var id: String { rawValue }

    var title: String {
        switch self {
        case .middle: "ホイールクリック"
        case .modeShift: "ホイール後ろのボタン"
        case .forward: "進むボタン"
        case .back: "戻るボタン"
        case .gesture: "ジェスチャーボタン"
        case .thumbWheel: "親指ホイール"
        }
    }

    /// Config group and key for single-action buttons; the gesture-capable ones use five keys.
    var group: String {
        switch self {
        case .gesture: "gesture"
        case .modeShift: "modeShift"
        default: "buttons"
        }
    }

    var buttonKey: String? {
        switch self {
        case .middle: "middle"
        case .back: "back"
        case .forward: "forward"
        default: nil
        }
    }

    var controlID: String? {
        switch self {
        case .middle: "52"
        case .back: "53"
        case .forward: "56"
        case .gesture: "c3"
        case .modeShift: "c4"
        case .thumbWheel: nil
        }
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var config: Config {
        didSet { if config != oldValue { scheduleSave() } }
    }
    @Published private(set) var status: Status?
    @Published var profile = Config.defaultProfile
    @Published var slot: Slot = .gesture
    @Published var pane: Pane = .buttons
    /// The control that was just pressed on the mouse, lit red for a moment.
    @Published private(set) var lit: Slot?
    @Published private(set) var savedAt: Date?
    @Published private(set) var loadError: String?

    private var saveWork: DispatchWorkItem?
    private var lastAgentRestart = Date.distantPast
    private var litWork: DispatchWorkItem?
    private var tokens: [Int32] = []

    /// A preview store never reads or writes the real files (used for README screenshots).
    private let isPreview: Bool

    init(preview: (config: Config, status: Status)? = nil) {
        isPreview = preview != nil
        if let preview {
            config = preview.config
            status = preview.status
            return
        }
        do {
            config = try Config.load()
        } catch {
            config = Config()
            loadError = "設定ファイルを読めません（\(Config.path.path)）"
        }
        status = Status.read()
        listen()
        // Coming back from System Settings: if the agent still lacks a permission, restart it now so it reads
        // the new state (it would otherwise restart itself within 30 seconds). At most once every 20 seconds.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let status = self.status, !status.inputMonitoring || !status.accessibility,
                      Date().timeIntervalSince(self.lastAgentRestart) > 20 else { return }
                self.lastAgentRestart = Date()
                self.startAgent(restart: true)
            }
        }
    }

    /// Shows a control as just pressed (previews only).
    func previewPress(_ slot: Slot) {
        self.slot = slot
        lit = slot
    }

    /// The resident process is alive if the pid it last wrote still exists.
    var agentRunning: Bool {
        guard let pid = status?.pid, pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    var profileIDs: [String] {
        [Config.defaultProfile] + config.profiles.keys.filter { $0 != Config.defaultProfile }.sorted { appName($0) < appName($1) }
    }

    // MARK: Entries

    func entry(_ group: String, _ key: String) -> (value: String?, inherited: Bool) {
        if let own = config.ownEntry(profile: profile, group: group, key: key) { return (own, false) }
        if profile == Config.defaultProfile { return (nil, false) }
        return (config.ownEntry(profile: Config.defaultProfile, group: group, key: key), true)
    }

    func set(_ group: String, _ key: String, _ value: String?) {
        config.setEntry(profile: profile, group: group, key: key, value: value)
    }

    func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "追加"
        panel.message = "ボタンを別に設定するアプリを選んでください"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        if config.profiles[id] == nil { config.profiles[id] = Config.Profile() }
        profile = id
    }

    func removeApp(_ id: String) {
        guard id != Config.defaultProfile else { return }
        config.profiles[id] = nil
        if profile == id { profile = Config.defaultProfile }
    }

    // MARK: Apps

    func appName(_ id: String) -> String {
        if id == Config.defaultProfile { return "すべてのアプリ" }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func appIcon(_ id: String) -> NSImage? {
        guard id != Config.defaultProfile, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: Saving

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func save() {
        guard !isPreview else { return }
        do {
            try config.save()
            if agentRunning { signalAgent() } // the resident process re-reads the file
            savedAt = Date()
        } catch {
            loadError = "保存できませんでした: \(error.localizedDescription)"
        }
    }

    /// SIGHUP through launchd, so it can only ever reach our own agent (not whatever pid a file names).
    private func signalAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kill", "SIGHUP", "gui/\(getuid())/local.dotlogi"]
        try? process.run()
    }

    func startAgent(restart: Bool = false) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart"] + (restart ? ["-k"] : []) + ["gui/\(getuid())/local.dotlogi"]
        try? process.run()
    }

    // MARK: Signals from the resident process

    private func listen() {
        var token: Int32 = 0
        notify_register_dispatch(Signal.status, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.status = Status.read() }
        }
        tokens.append(token)
        for slot in Slot.allCases {
            guard let cid = slot.controlID else { continue }
            notify_register_dispatch(Signal.pressPrefix + cid, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.light(slot) }
            }
            tokens.append(token)
        }
    }

    /// A press on the real mouse selects that control and lights it, like "MIDI learn" on a mixer.
    private func light(_ slot: Slot) {
        self.slot = slot
        withAnimation(.easeOut(duration: 0.12)) { lit = slot }
        litWork?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.6)) { self?.lit = nil } }
        litWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
