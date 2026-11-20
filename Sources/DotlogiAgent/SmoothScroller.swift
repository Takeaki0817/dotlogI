import ApplicationServices
import Foundation

/// Turns wheel notches into a short eased glide of pixel scroll events.
/// A timer exists only while a glide is running; when the wheel is still, this costs nothing.
final class SmoothScroller {
    var pixelsPerNotch = 48.0
    /// Time constant of the exponential ease-out; a glide is ~3 tau long.
    var tau = 0.05
    /// +1 sends wheel-away as scroll up ("standard"), -1 inverts it ("natural").
    var direction = 1.0
    /// Trackpad-style began/changed/ended phases. Off by default: some apps ignore or rubber-band phased
    /// events that do not come from a real touch.
    var usePhases = false
    /// Called once per glide with the pixels posted, the event count and the duration (for the event log).
    var onGlideEnd: ((Int, Int, Double) -> Void)?

    /// The most a glide may still have to travel, so a fast free spin cannot run on for seconds.
    private let maxPending = 4000.0
    private var pending = 0.0
    private var carry = 0.0
    private var lastTick = 0.0
    private var timer: DispatchSourceTimer?
    private var began = false
    private var glidePixels = 0
    private var glideEvents = 0
    private var glideStart = 0.0

    /// - Parameter notches: signed wheel movement in notches (positive = rolled away from the user).
    func add(notches: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        // Reversing direction drops what is left of the previous glide.
        if pending != 0 && (pending > 0) != (notches * direction > 0) { pending = 0; carry = 0 }
        pending = min(max(pending + notches * pixelsPerNotch * direction, -maxPending), maxPending)
        if timer == nil { start(now) }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        pending = 0
        carry = 0
        if began {
            if usePhases { post(0, phase: 4) } // ended
            onGlideEnd?(glidePixels, glideEvents, ProcessInfo.processInfo.systemUptime - glideStart)
        }
        began = false
        glidePixels = 0
        glideEvents = 0
    }

    private func start(_ now: Double) {
        lastTick = now
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(now - lastTick, 0.001)
        lastTick = now
        var step = pending * (1 - exp(-dt / tau))
        if abs(pending - step) < 0.5 { step = pending }
        pending -= step
        carry += step
        let pixels = carry.rounded(.towardZero)
        carry -= pixels
        if pixels != 0 {
            if !began { glideStart = now }
            post(Int32(clamping: Int(pixels)), phase: began ? 2 : 1) // changed : began
            began = true
            glidePixels += Int(pixels)
            glideEvents += 1
        }
        if pending == 0 { stop() }
    }

    private func post(_ pixels: Int32, phase: Int64) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if usePhases { event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase) }
        // Keep held modifiers so shift+scroll and cmd+scroll still work.
        event.flags = CGEventSource.flagsState(.combinedSessionState)
        event.post(tap: .cghidEventTap)
    }
}
