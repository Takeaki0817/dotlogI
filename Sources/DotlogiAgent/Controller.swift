import ApplicationServices
import Foundation
import IOKit.hid
import DotlogiCore

/// Applies the config to the mouse and turns diverted button and wheel events into actions.
/// Everything is event-driven: no polling. The only timers run while a smooth-scroll glide is moving or a
/// permission is missing.
final class Controller {
    // Control IDs of the MX Master 3, as listed by the mouse itself (REPROG_CONTROLS_V4, see `probe`).
    static let middle: UInt16 = 0x52, back: UInt16 = 0x53, forward: UInt16 = 0x56
    static let gesture: UInt16 = 0xC3, modeShift: UInt16 = 0xC4
    static let divertedControls: [UInt16] = [middle, back, forward, gesture, modeShift]
    static let rawXYControls: Set<UInt16> = [gesture, modeShift]

    private(set) var config: Config
    private var keyNavigationApps: Set<String>
    private let monitor = HIDPPMonitor()
    private var device: HIDPPDevice?

    private var pressed: Set<UInt16> = []
    private var swipe: (cid: UInt16, app: String?, dx: Int, dy: Int, fired: Bool, zoom: Bool)?
    private var smartShiftMode: UInt8 = 0
    private var batteryLevel = -1
    private var status = Status()
    private var configuring = false
    private var needsReconfigure = false
    private var lastBatteryWarning = Date.distantPast
    private let scroller = SmoothScroller()
    private let wheelTap = WheelTap()
    /// True while smooth scrolling has handed the wheel back to the mouse because Control is held.
    private var wheelWithMouse = false
    /// True while the wheel is diverted to this process (smooth scrolling on and allowed to post events).
    private var smoothScrollOn = false
    /// Hi-res wheel units per notch, read from the mouse.
    private var wheelMultiplier = 8.0
    /// The wheel mode (free spin / ratchet) last chosen with the wheel button, put back on every connect
    /// because the mouse may forget it when it powers off.
    private static let wheelModeKey = "WheelMode"

    init(config: Config) {
        self.config = config
        keyNavigationApps = Set(config.keyNavigationApps)
    }

    func start(productIDs: [Int]) {
        log("start: postEventAccess=\(CGPreflightPostEventAccess()) inputMonitoring=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)")
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
        monitor.onMatch = { [weak self] device in self?.attach(device) }
        monitor.onRemove = { [weak self] device in
            guard let self, let current = self.device, current.device == device else { return }
            self.log("device removed")
            self.scroller.stop()
            self.wheelTap.stop()
            self.smoothScrollOn = false
            current.close()
            self.device = nil
            self.status.connected = false
            self.publish()
        }
        publish()
        if !(status.inputMonitoring && status.accessibility) { watchPermissions() }
        monitor.start(productIDs: productIDs)
    }

    /// macOS does not tell a running process that it has been granted access, and the process's own checks keep
    /// the old answer. So while a permission is missing, hand the buttons back and exit after 30 seconds; launchd
    /// (KeepAlive) starts a fresh process, which reads the current state. No other program is ever executed.
    /// The settings window can restart us sooner (launchctl kickstart, by label).
    private var permissionTimer: DispatchSourceTimer?
    private func watchPermissions() {
        guard permissionTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { [weak self] in
            self?.log("a permission is still missing; restarting to check again")
            self?.restore()
            exit(0)
        }
        permissionTimer = timer
        timer.resume()
    }

    private func attach(_ hidDevice: IOHIDDevice) {
        // One mouse at a time; a second match (another or a spoofed device) is ignored.
        guard self.device == nil else {
            log("ignoring a second matching device")
            return
        }
        let device = HIDPPDevice(device: hidDevice)
        do {
            try device.open()
        } catch {
            log("open failed: \(error)")
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
                // Lists the app in System Settings > Input Monitoring; watchPermissions() restarts us once allowed.
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                log("waiting for Input Monitoring permission")
                status.lastError = "InputMonitoringRequired"
                publish()
                watchPermissions()
            }
            return
        }
        device.onNotification = { [weak self] message in self?.handle(message) }
        self.device = device
        configure()
    }

    /// Writes all settings and diversions. Run on connect and whenever the mouse reports a reconnection,
    /// because the mouse forgets diversions when it powers off or sleeps.
    func configure() {
        guard let device else { return }
        // A reconnect notice can arrive while configuring; run once more afterwards instead of recursing.
        if configuring {
            needsReconfigure = true
            return
        }
        configuring = true
        defer {
            configuring = false
            if needsReconfigure {
                needsReconfigure = false
                DispatchQueue.main.async { [weak self] in self?.configure() }
            }
        }
        device.resetFeatureCache()
        pressed.removeAll()
        swipe = nil
        do {
            for feature in [Feature.reprogControlsV4, .smartShift, .hiResWheel, .thumbWheel, .adjustableDPI, .batteryStatus, .wirelessStatus] {
                _ = try device.index(of: feature)
            }
            for cid in Controller.divertedControls {
                let flags: UInt8 = Controller.rawXYControls.contains(cid) ? 0x33 : 0x03 // divert (+ raw XY) with valid bits
                _ = try device.call(.reprogControlsV4, 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), flags, 0, 0])
            }
            scroller.stop()
            wheelTap.stop()
            // Take the wheel only when the scroll events can be posted; a diverted wheel without that
            // permission would not scroll at all. Otherwise macOS scrolls natively with no work here.
            smoothScrollOn = (config.device.smoothScroll ?? false) && CGPreflightPostEventAccess()
            var tapOn = false
            wheelWithMouse = false
            if smoothScrollOn {
                wheelMultiplier = Double(max(try device.call(.hiResWheel, 0)[0], 1))
                scroller.pixelsPerNotch = 48 * min(max(config.device.smoothScrollSpeed ?? 1, 0.2), 5)
                scroller.tau = min(max(config.device.smoothScrollDuration ?? 0.15, 0.03), 0.6) / 3
                scroller.usePhases = config.device.smoothScrollPhases ?? false
                // Posted events are not flipped by the firmware invert bit, so apply the chosen direction here.
                scroller.direction = Controller.standardDirection(config) ? 1 : -1
                scroller.onGlideEnd = { [weak self] px, n, secs in
                    self?.event(String(format: "glide %dpx in %d events over %.0fms", px, n, secs * 1000))
                }
                // Screen zoom ignores posted scroll events, so the real wheel goes back to the mouse while
                // Control is held (see controlChanged). Without the tap, smooth scrolling still works.
                tapOn = wheelTap.start(modify: false)
                if tapOn {
                    wheelTap.onControl = { [weak self] down in self?.controlChanged(down) }
                    wheelTap.onWheelWithoutControl = { [weak self] in self?.takeWheelBack() }
                }
                wheelWithMouse = tapOn && wheelTap.controlDown
                let mode: UInt8 = wheelWithMouse ? Controller.zoomWheelMode(config) : 0x03 // 0x03: diverted, hi-res
                _ = try device.call(.hiResWheel, 2, [mode])
            } else {
                // Reverse the wheel in the event stream when that works, because the mouse's own invert bit
                // also reverses Control+scroll screen zoom. Without the tap, fall back to the invert bit.
                var mode = Controller.nativeWheelMode(config)
                if (config.device.wheelInvert ?? false) && wheelTap.start(modify: true) {
                    wheelTap.reverse = true
                    tapOn = true
                    mode &= ~0x04
                }
                _ = try device.call(.hiResWheel, 2, [mode])
            }
            _ = try device.call(.thumbWheel, 2, [0x00, (config.device.thumbWheelInvert ?? false) ? 0x01 : 0x00])
            if let dpi = config.device.dpi.map({ min(max($0, 200), 4000) }) {
                _ = try device.call(.adjustableDPI, 3, [0, UInt8(dpi >> 8), UInt8(dpi & 0xFF)])
            }
            if let threshold = config.device.smartShiftThreshold {
                _ = try device.call(.smartShift, 1, [0, UInt8(min(max(threshold, 1), 254)), 0])
            }
            let savedMode = UserDefaults.standard.integer(forKey: Controller.wheelModeKey) // 0 when never set
            if savedMode == 1 || savedMode == 2 {
                _ = try device.call(.smartShift, 1, [UInt8(savedMode), 0, 0])
            }
            smartShiftMode = try device.call(.smartShift, 0)[0]
            batteryLevel = Int(try device.call(.batteryStatus, 0)[0])
            log("configured: smooth=\(smoothScrollOn ? 1 : 0) tap=\(tapOn ? 1 : 0) \(try readBack())")
            status.connected = true
            status.deviceName = device.name
            status.lastError = nil
        } catch {
            log("configure failed: \(error)")
            // The mouse is attached but not set up, so the buttons do nothing: show it as not connected,
            // which lets the settings window offer to reconnect.
            status.connected = false
            status.lastError = "\(error)"
        }
        publish()
    }

    /// Re-reads config.json (sent SIGHUP by the settings app after it saves).
    func reload() {
        do {
            config = try Config.load()
            keyNavigationApps = Set(config.keyNavigationApps)
            log("config reloaded")
            configure()
        } catch {
            log("reload failed: \(error)")
            status.lastError = "ConfigInvalid"
            publish()
        }
    }

    /// Writes the small status file the settings app reads. Only on changes, never on a timer.
    private func publish() {
        status.pid = getpid()
        status.battery = batteryLevel
        status.smartShift = smartShiftMode == 2 ? "ratchet" : smartShiftMode == 1 ? "free" : nil
        status.inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        status.accessibility = CGPreflightPostEventAccess()
        status.updatedAt = Date()
        status.write()
    }

    /// Current device state, for the log and for `dotlogi status`.
    func readBack() throws -> String {
        guard let device else { return "no device" }
        let wheel = try device.call(.hiResWheel, 1)[0]
        let thumb = try device.call(.thumbWheel, 1)
        let dpi = try device.call(.adjustableDPI, 2, [0])
        let shift = try device.call(.smartShift, 0)
        let diverted = try Controller.divertedControls.map { cid -> String in
            let reply = try device.call(.reprogControlsV4, 2, [UInt8(cid >> 8), UInt8(cid & 0xFF)])
            return String(format: "%02x:%02x", cid, reply[2])
        }
        return String(format: "wheel=%02x thumb=%02x,%02x dpi=%d smartshift=%d/%d battery=%d%% controls=%@",
                      wheel, thumb[0], thumb[1], Int(dpi[1]) << 8 | Int(dpi[2]), shift[0], shift[1], batteryLevel,
                      diverted.joined(separator: ","))
    }

    /// Wheel mode byte when the mouse scrolls by itself: bit2 invert, bit1 hi-res.
    static func nativeWheelMode(_ config: Config) -> UInt8 {
        ((config.device.wheelInvert ?? false) ? 0x04 : 0x00) | ((config.device.wheelHiRes ?? false) ? 0x02 : 0x00)
    }

    /// Wheel mode while Control is held during smooth scrolling: not diverted and never inverted, so screen
    /// zoom sees the real wheel in its own direction.
    static func zoomWheelMode(_ config: Config) -> UInt8 {
        nativeWheelMode(config) & ~0x04
    }

    /// Hands the wheel to the mouse while Control is held, and takes it back for smooth scrolling on release.
    /// Fire-and-forget (send), because this runs inside the event tap and must not wait for the mouse.
    private func controlChanged(_ down: Bool) {
        guard smoothScrollOn, !configuring, let device, down != wheelWithMouse else { return }
        if down { scroller.stop() }
        wheelWithMouse = down
        device.send(.hiResWheel, 2, [down ? Controller.zoomWheelMode(config) : 0x03])
        event("control \(down ? "down: wheel to the mouse" : "up: wheel to smooth scrolling")")
    }

    /// The real wheel scrolled with Control up while the mouse had it: a release was missed (screen lock,
    /// secure input, a paused tap). Take the wheel back so smooth scrolling does not stay off.
    private func takeWheelBack() {
        guard smoothScrollOn, wheelWithMouse, !configuring, let device else { return }
        wheelWithMouse = false
        device.send(.hiResWheel, 2, [0x03])
        event("wheel scrolled without control: wheel back to smooth scrolling")
    }

    /// Whether the chosen wheel direction is "standard" (wheel away = content up). The setting is stored
    /// as the firmware invert bit relative to macOS natural scrolling, as the settings window writes it.
    static func standardDirection(_ config: Config) -> Bool {
        let macNatural = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool ?? true
        return (config.device.wheelInvert ?? false) == macNatural
    }

    /// Returns the buttons and the wheel to the mouse's own behaviour (used on exit).
    func restore() {
        guard let device else { return }
        scroller.stop()
        wheelTap.stop()
        smoothScrollOn = false
        // The invert bit goes back on, so the chosen direction holds while dotlogI is not running.
        _ = try? device.call(.hiResWheel, 2, [Controller.nativeWheelMode(config)])
        for cid in Controller.divertedControls {
            let flags: UInt8 = Controller.rawXYControls.contains(cid) ? 0x22 : 0x02 // valid bits set, divert/rawXY cleared
            _ = try? device.call(.reprogControlsV4, 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), flags, 0, 0])
        }
        log("restored native buttons")
    }

    // MARK: - Events

    private func handle(_ message: HIDPPMessage) {
        guard let device else { return }
        let p = Array(message.params)
        switch message.featureIndex {
        case device.cachedIndex(of: .reprogControlsV4):
            if message.function == 0 { buttons(p) } else if message.function == 1 { rawXY(p) }
        case device.cachedIndex(of: .hiResWheel):
            // Wheel movement: flags (bit4 hi-res, bits0-3 periods), then signed vertical delta.
            // Only while smooth scrolling owns the wheel; another program may have diverted it.
            guard message.function == 0, p.count >= 3, smoothScrollOn else { break }
            let delta = Double(Int16(bitPattern: UInt16(p[1]) << 8 | UInt16(p[2])))
            let hiRes = p[0] & 0x10 != 0
            // One report never stands for more than a few dozen notches, whatever the device claims.
            scroller.add(notches: min(max(hiRes ? delta / wheelMultiplier : delta, -50), 50))
        case device.cachedIndex(of: .wirelessStatus):
            log("reconnected (status \(p[0]) request \(p[1]))")
            configure()
        case device.cachedIndex(of: .batteryStatus):
            battery(Int(p[0]))
        default:
            break
        }
    }

    private func buttons(_ p: [UInt8]) {
        var now: Set<UInt16> = []
        for i in stride(from: 0, to: 8, by: 2) {
            let cid = UInt16(p[i]) << 8 | UInt16(p[i + 1])
            if cid != 0 { now.insert(cid) }
        }
        for cid in now.subtracting(pressed) { press(cid) }
        for cid in pressed.subtracting(now) { release(cid) }
        pressed = now
    }

    private func press(_ cid: UInt16) {
        Signal.post(Signal.pressPrefix + String(format: "%02x", cid)) // lets an open settings window light the button up
        // Permissions granted after start are only noticed here; refresh what the settings window shows.
        if status.accessibility != CGPreflightPostEventAccess() { publish() }
        let app = FrontmostApp.bundleID()
        switch cid {
        case Controller.gesture, Controller.modeShift:
            let group = cid == Controller.gesture ? "gesture" : "modeShift"
            let zoom = config.actionText(group: group, key: "mode", bundleID: app) == "zoom"
            swipe = (cid, app, 0, 0, false, zoom)
            event(String(format: "press %02x app=%@ zoom=%d", cid, app ?? "-", zoom ? 1 : 0))
        case Controller.middle: perform(group: "buttons", key: "middle", app: app)
        case Controller.back: perform(group: "buttons", key: "back", app: app)
        case Controller.forward: perform(group: "buttons", key: "forward", app: app)
        default: break
        }
    }

    private func release(_ cid: UInt16) {
        guard let current = swipe, current.cid == cid else { return }
        swipe = nil
        if !current.fired {
            perform(group: cid == Controller.gesture ? "gesture" : "modeShift", key: "click", app: current.app)
        }
    }

    private func rawXY(_ p: [UInt8]) {
        guard var current = swipe else { return }
        current.dx += Int(Int16(bitPattern: UInt16(p[0]) << 8 | UInt16(p[1])))
        current.dy += Int(Int16(bitPattern: UInt16(p[2]) << 8 | UInt16(p[3])))
        let threshold = min(max(config.gestureThreshold, 20), 150)
        if current.zoom {
            // Hold and move up/down to zoom, repeating every threshold of travel.
            if abs(current.dy) >= threshold {
                Shortcut(current.dy < 0 ? "cmd+=" : "cmd+-")?.post()
                event("zoom \(current.dy < 0 ? "in" : "out")")
                current.dx = 0
                current.dy = 0
                current.fired = true
            }
        } else if !current.fired && max(abs(current.dx), abs(current.dy)) >= threshold {
            let key = abs(current.dx) > abs(current.dy) ? (current.dx > 0 ? "right" : "left") : (current.dy > 0 ? "down" : "up")
            current.fired = true
            perform(group: current.cid == Controller.gesture ? "gesture" : "modeShift", key: key, app: current.app)
        }
        swipe = current
    }

    private func perform(group: String, key: String, app: String?) {
        guard let text = config.actionText(group: group, key: key, bundleID: app) else { return }
        guard let action = Action(text) else {
            log("unknown action '\(text)' for \(group).\(key)")
            return
        }
        event("\(group).\(key) -> \(text) app=\(app ?? "-")")
        switch action {
        case .none: break
        case .missionControl: SystemActions.dock("com.apple.expose.awake")
        case .appExpose: SystemActions.dock("com.apple.expose.front.awake")
        case .launchpad: SystemActions.dock("com.apple.launchpad.toggle")
        case .back: SystemActions.navigate(back: true, frontmost: app, keyApps: keyNavigationApps)
        case .forward: SystemActions.navigate(back: false, frontmost: app, keyApps: keyNavigationApps)
        case .shortcut(let shortcut): shortcut.post()
        case .middleClick: SystemActions.middleClick()
        case .smartShiftToggle:
            smartShiftMode = smartShiftMode == 2 ? 1 : 2 // 1 free spin, 2 ratchet
            device?.send(.smartShift, 1, [smartShiftMode, 0, 0])
            UserDefaults.standard.set(Int(smartShiftMode), forKey: Controller.wheelModeKey)
            publish()
        }
    }

    private func battery(_ level: Int) {
        // At most one warning an hour, even if the reported level flaps around the threshold.
        if level <= 10 && (batteryLevel > 10 || batteryLevel < 0) && Date().timeIntervalSince(lastBatteryWarning) > 3600 {
            lastBatteryWarning = Date()
            let script = "display notification \"マウスの電池が残り \(level)% です\" with title \"MX Master 3\""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
        let changed = level != batteryLevel
        batteryLevel = level
        if changed {
            log("battery \(level)%")
            publish()
        }
    }

    // MARK: - Logging

    private func log(_ text: String) {
        FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8))
    }

    private func event(_ text: String) {
        if config.eventLog { log(text) }
    }
}

