import ApplicationServices
import Foundation
import IOKit.hid
import DotlogiCore

let mxMaster3MacBLE = 0xB023
let arguments = CommandLine.arguments.dropFirst()

func loadConfig() -> Config {
    do {
        return try Config.load()
    } catch {
        FileHandle.standardError.write(Data("cannot read \(Config.path.path): \(error)\n".utf8))
        exit(1)
    }
}

switch arguments.first {
case "run":
    // stderr is the launchd log file; start it over once it passes 1 MB (only that file, never another one).
    var info = stat()
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    if fcntl(STDERR_FILENO, F_GETPATH, &path) == 0, String(cString: path).hasSuffix("/Library/Logs/dotlogi.log"),
       fstat(STDERR_FILENO, &info) == 0, info.st_size > 1_000_000 {
        ftruncate(STDERR_FILENO, 0)
    }
    let controller = Controller(config: loadConfig())
    controller.start(productIDs: [mxMaster3MacBLE])
    // Hand the buttons back to the mouse when stopped (launchctl bootout / Ctrl+C).
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            if sig == SIGHUP { controller.reload(); return } // the settings app saved config.json
            controller.restore()
            exit(0)
        }
        source.resume()
        sources.append(source)
    }
    CFRunLoopRun()
case "check":
    // Validates every action string in the config without touching the device.
    let config = loadConfig()
    var bad = 0
    for (name, profile) in config.profiles {
        let groups = ["buttons": profile.buttons, "gesture": profile.gesture, "modeShift": profile.modeShift]
        for (group, entries) in groups {
            for (key, value) in entries ?? [:] where !(key == "mode" && value == "zoom") && Action(value) == nil {
                print("\(name).\(group).\(key): unknown action '\(value)'")
                bad += 1
            }
        }
    }
    let d = config.device
    func outOfRange(_ name: String, _ value: Double?, _ range: ClosedRange<Double>) {
        if let value, !range.contains(value) { print("device.\(name): \(value) is outside \(range)"); bad += 1 }
    }
    outOfRange("dpi", d.dpi.map(Double.init), 200...4000)
    outOfRange("smartShiftThreshold", d.smartShiftThreshold.map(Double.init), 1...254)
    outOfRange("smoothScrollSpeed", d.smoothScrollSpeed, 0.2...5)
    outOfRange("smoothScrollDuration", d.smoothScrollDuration, 0.03...0.6)
    outOfRange("gestureThreshold", Double(config.gestureThreshold), 20...150)
    print("dock actions available: \(SystemActions.isAvailable)  frontmost app: \(FrontmostApp.bundleID() ?? "-")")
    print("permissions: postEvents=\(CGPreflightPostEventAccess()) inputMonitoring=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted)")
    print(bad == 0 ? "config ok" : "\(bad) problem(s)")
    exit(bad == 0 ? 0 : 1)
case "probe":
    Probe.run(productIDs: [mxMaster3MacBLE])
case nil, .some(_) where arguments.first!.hasPrefix("-psn"):
    // Opened from Finder or the Dock. Check in with LaunchServices (AppKit is loaded only here, never in
    // the resident `run` mode), ask for the two permissions so macOS lists dotlogI and shows its prompts,
    // then open the settings window. The resident copy is started by launchd with `run`.
    checkInWithLaunchServices()
    if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
    if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
    let settings = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dotlogI Settings.app")
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [settings.path]
    try? open.run()
    // Stay a little while so the system prompts are not cut short, then leave.
    RunLoop.main.run(until: Date().addingTimeInterval(20))
    exit(0)
default:
    print("usage: DotlogiAgent run | check | probe   (no arguments: open the settings window)")
}

/// Registers this process as a running app, the way NSApplication does at launch, so Finder does not report
/// "not responding". AppKit is loaded dynamically to keep it out of the resident process.
func checkInWithLaunchServices() {
    guard dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW) != nil,
          let applicationClass = NSClassFromString("NSApplication"),
          let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return }
    typealias SendObject = @convention(c) (AnyObject, Selector) -> AnyObject?
    typealias SendVoid = @convention(c) (AnyObject, Selector) -> Void // finishLaunching returns nothing
    guard let application = unsafeBitCast(symbol, to: SendObject.self)(applicationClass as AnyObject, NSSelectorFromString("sharedApplication")) else { return }
    unsafeBitCast(symbol, to: SendVoid.self)(application, NSSelectorFromString("finishLaunching"))
}
