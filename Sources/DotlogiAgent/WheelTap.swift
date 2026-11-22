import ApplicationServices
import Foundation

/// One event tap that keeps Control+scroll screen zoom (Accessibility Zoom) working the way the mouse does
/// by itself. Zoom reacts only to the real wheel, and the firmware invert bit would reverse it too, so:
/// - `reverse`: reverses the vertical wheel direction in the event stream instead of in the mouse. Events with
///   Control held pass through untouched, so zoom gets the wheel's own direction whether it reads before or
///   after this tap. Only line-based (non-continuous) events are touched; trackpads send continuous ones.
/// - `onControl`: reports Control going down and up, so smooth scrolling can hand the wheel back to the mouse
///   while Control is held.
/// - `onWheelWithoutControl`: a real vertical wheel event with Control up, so a missed release can be noticed.
final class WheelTap {
    var reverse = false
    var onControl: ((Bool) -> Void)?
    var onWheelWithoutControl: (() -> Void)?
    private(set) var controlDown = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Installs the tap; `modify` is needed only for `reverse` (a listen-only tap asks for less permission).
    /// Returns false when macOS refuses it (a permission is missing).
    func start(modify: Bool) -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
            | CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: modify ? .defaultTap : .listenOnly,
            eventsOfInterest: mask, callback: wheelTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        controlDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskControl)
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        reverse = false
        onControl = nil
        onWheelWithoutControl = nil
        controlDown = false
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off when it is slow or on secure input; switch it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let down = event.flags.contains(.maskControl)
            if down != controlDown {
                controlDown = down
                onControl?(down)
            }
        case .scrollWheel:
            guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
                  !event.flags.contains(.maskControl) else { break }
            if event.getIntegerValueField(.scrollWheelEventDeltaAxis1) != 0 { onWheelWithoutControl?() }
            if reverse { WheelTap.flipVertical(event) }
        default:
            break
        }
        return event
    }

    /// Negates the three vertical deltas (lines, points, fixed point); the horizontal axis is left alone.
    static func flipVertical(_ event: CGEvent) {
        let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -line)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
    }
}

private func wheelTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let wheelTap = Unmanaged<WheelTap>.fromOpaque(userInfo).takeUnretainedValue()
    return Unmanaged.passUnretained(wheelTap.handle(type, event))
}
