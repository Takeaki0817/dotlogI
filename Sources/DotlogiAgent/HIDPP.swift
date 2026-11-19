import Foundation
import IOKit.hid

/// HID++ 2.0 feature IDs used by this app.
enum Feature: UInt16 {
    case root = 0x0000
    case featureSet = 0x0001
    case batteryStatus = 0x1000
    case wirelessStatus = 0x1D4B
    case unifiedBattery = 0x1004
    case reprogControlsV4 = 0x1B04
    case smartShift = 0x2110
    case smartShiftEnhanced = 0x2111
    case hiResWheel = 0x2121
    case thumbWheel = 0x2150
    case adjustableDPI = 0x2201
}

struct HIDPPError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// A HID++ 2.0 message (long report, 20 bytes).
struct HIDPPMessage {
    static let longReportID: UInt8 = 0x11
    static let length = 20

    var bytes: [UInt8]

    var deviceIndex: UInt8 { bytes[1] }
    var featureIndex: UInt8 { bytes[2] }
    var function: UInt8 { bytes[3] >> 4 }
    var softwareID: UInt8 { bytes[3] & 0x0F }
    var params: ArraySlice<UInt8> { bytes[4...] }
    var isError: Bool { bytes[2] == 0xFF }
}

/// One HID++ capable Logitech device opened through IOHIDDevice.
final class HIDPPDevice {
    static let softwareID: UInt8 = 0x0B
    static let deviceIndex: UInt8 = 0xFF // direct (Bluetooth / USB) connection

    let device: IOHIDDevice
    let name: String
    let productID: Int
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var pending: [HIDPPMessage] = []
    private var featureIndexes: [UInt16: UInt8] = [:]
    private var waiting = false
    private var deferred: [HIDPPMessage] = []
    /// Device-initiated notifications (software ID 0), e.g. diverted button events.
    var onNotification: ((HIDPPMessage) -> Void)?

    init(device: IOHIDDevice) {
        self.device = device
        name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
        productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
    }

    func open() throws {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw HIDPPError(message: String(format: "IOHIDDeviceOpen failed: 0x%08x", result))
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let me = Unmanaged<HIDPPDevice>.fromOpaque(context).takeUnretainedValue()
            me.handleInput(reportID: reportID, report: report, length: length)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// The feature index of a feature resolved earlier, if any (no device round trip).
    func cachedIndex(of feature: Feature) -> UInt8? { featureIndexes[feature.rawValue] }

    /// Stops callbacks into this object before it can be freed (the callback context is unretained).
    func close() {
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        inputBuffer.deallocate()
    }

    private func handleInput(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length >= 4 else { return }
        var bytes = Array(UnsafeBufferPointer(start: report, count: length))
        // IOKit includes the report ID as the first byte for numbered reports.
        if bytes[0] != UInt8(truncatingIfNeeded: reportID) { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
        guard bytes[0] == HIDPPMessage.longReportID || bytes[0] == 0x10 else { return }
        if bytes.count < HIDPPMessage.length { bytes += [UInt8](repeating: 0, count: HIDPPMessage.length - bytes.count) }
        let message = HIDPPMessage(bytes: bytes)
        // Error replies are [id, dev, 0xFF, featureIndex, function|swID, code].
        let replySoftwareID = message.isError ? bytes[4] & 0x0F : message.softwareID
        if replySoftwareID == HIDPPDevice.softwareID {
            // Replies matter only while a request waits; never let a device fill memory with them.
            if waiting && pending.count < 32 { pending.append(message) }
        } else if message.softwareID == 0 && !message.isError {
            // Never run handlers inside a nested wait: they may send requests themselves.
            if waiting {
                if deferred.count < 64 { deferred.append(message) }
            } else {
                onNotification?(message)
            }
        }
    }

    private func write(featureIndex: UInt8, function: UInt8, params: [UInt8]) throws {
        var bytes = [UInt8](repeating: 0, count: HIDPPMessage.length)
        bytes[0] = HIDPPMessage.longReportID
        bytes[1] = HIDPPDevice.deviceIndex
        bytes[2] = featureIndex
        bytes[3] = (function << 4) | HIDPPDevice.softwareID
        for (offset, value) in params.prefix(16).enumerated() { bytes[4 + offset] = value }
        let result = bytes.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(HIDPPMessage.longReportID), buffer.baseAddress!, buffer.count)
        }
        guard result == kIOReturnSuccess else {
            throw HIDPPError(message: String(format: "IOHIDDeviceSetReport failed: 0x%08x", result))
        }
    }

    /// Sends without waiting for the reply (for the button hot path).
    func send(_ feature: Feature, _ function: UInt8, _ params: [UInt8] = []) {
        guard let index = featureIndexes[feature.rawValue] else { return }
        try? write(featureIndex: index, function: function, params: params)
    }

    /// Sends a request and waits (spinning the main run loop) for the matching reply.
    /// Notifications that arrive meanwhile are delivered after the reply.
    @discardableResult
    func request(featureIndex: UInt8, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 1.0) throws -> HIDPPMessage {
        pending.removeAll()
        try write(featureIndex: featureIndex, function: function, params: params)
        waiting = true
        defer {
            waiting = false
            let queued = deferred
            deferred.removeAll()
            queued.forEach { onNotification?($0) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = pending.firstIndex(where: { reply in
                if reply.isError { return reply.bytes[3] == featureIndex && reply.bytes[4] >> 4 == function }
                return reply.featureIndex == featureIndex && reply.function == function
            }) {
                let reply = pending.remove(at: index)
                if reply.isError {
                    throw HIDPPError(message: String(format: "HID++ error 0x%02x (feature index %d, function %d)", reply.bytes[5], featureIndex, function))
                }
                return reply
            }
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        throw HIDPPError(message: "HID++ timeout (feature index \(featureIndex), function \(function))")
    }

    /// Resolves (and caches) the feature index for a feature ID through the Root feature.
    func index(of feature: Feature) throws -> UInt8? {
        if let cached = featureIndexes[feature.rawValue] { return cached }
        let reply = try request(featureIndex: 0, function: 0, params: [UInt8(feature.rawValue >> 8), UInt8(feature.rawValue & 0xFF)])
        let index = reply.bytes[4]
        guard index != 0 || feature == .root else { return nil }
        featureIndexes[feature.rawValue] = index
        return index
    }

    func call(_ feature: Feature, _ function: UInt8, _ params: [UInt8] = []) throws -> [UInt8] {
        guard let index = try index(of: feature) else {
            throw HIDPPError(message: String(format: "feature 0x%04x not supported", feature.rawValue))
        }
        return Array(try request(featureIndex: index, function: function, params: params).params)
    }

    func resetFeatureCache() { featureIndexes.removeAll() }
}

/// Finds Logitech HID++ interfaces (vendor usage 0xFF43:0202 over BLE, 0xFF00 otherwise) and reports matches/removals.
final class HIDPPMonitor {
    static let logitechVendorID = 0x046D
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var onMatch: ((IOHIDDevice) -> Void)?
    var onRemove: ((IOHIDDevice) -> Void)?

    func start(productIDs: [Int]) {
        let matches: [[String: Any]] = productIDs.flatMap { pid in
            // The HID++ collection is not the primary usage (that is the keyboard collection),
            // so match on any of the device's usage pairs.
            [(0xFF43, 0x0202), (0xFF00, 0x0002)].map { page, usage in
                [kIOHIDVendorIDKey: HIDPPMonitor.logitechVendorID, kIOHIDProductIDKey: pid,
                 kIOHIDDeviceUsagePageKey: page, kIOHIDDeviceUsageKey: usage] as [String: Any]
            }
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDPPMonitor>.fromOpaque(context).takeUnretainedValue().onMatch?(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDPPMonitor>.fromOpaque(context).takeUnretainedValue().onRemove?(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Lists every HID interface of the given vendor, for diagnosis.
    static func describeAll(vendorID: Int = logitechVendorID) -> [String] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.map { device in
            func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
            let pairs = (prop(kIOHIDDeviceUsagePairsKey) as? [[String: Int]] ?? []).map {
                String(format: "%04x:%04x", $0[kIOHIDDeviceUsagePageKey] ?? 0, $0[kIOHIDDeviceUsageKey] ?? 0)
            }
            return String(format: "%@ pid=%04x transport=%@ primary=%04x:%04x out=%d in=%d pairs=%@",
                          (prop(kIOHIDProductKey) as? String) ?? "?",
                          (prop(kIOHIDProductIDKey) as? Int) ?? 0,
                          (prop(kIOHIDTransportKey) as? String) ?? "?",
                          (prop(kIOHIDPrimaryUsagePageKey) as? Int) ?? 0,
                          (prop(kIOHIDPrimaryUsageKey) as? Int) ?? 0,
                          (prop(kIOHIDMaxOutputReportSizeKey) as? Int) ?? 0,
                          (prop(kIOHIDMaxInputReportSizeKey) as? Int) ?? 0,
                          pairs.joined(separator: ","))
        }
    }
}
