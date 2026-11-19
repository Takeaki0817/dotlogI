import Foundation
import IOKit.hid

/// Read-only diagnosis: prints the HID interfaces, the feature table and the current
/// state of the features this app manages. Never writes to the device.
enum Probe {
    static func run(productIDs: [Int]) {
        print("== Logitech HID interfaces")
        HIDPPMonitor.describeAll().forEach { print("  " + $0) }

        let monitor = HIDPPMonitor()
        var found: HIDPPDevice?
        monitor.onMatch = { device in if found == nil { found = HIDPPDevice(device: device) } }
        monitor.start(productIDs: productIDs)
        let deadline = Date().addingTimeInterval(3)
        while found == nil && Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, true) }
        guard let device = found else { print("No HID++ interface matched"); return }
        print("== Opening \(device.name) pid=\(String(format: "%04x", device.productID))")
        do {
            try device.open()
            try dump(device)
        } catch {
            print("ERROR: \(error)")
        }
        device.close()
    }

    static func hex(_ bytes: some Collection<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
    static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }

    static func dump(_ device: HIDPPDevice) throws {
        let protocolReply = try device.request(featureIndex: 0, function: 1, params: [0, 0, 0x5A])
        print("protocol \(protocolReply.bytes[4]).\(protocolReply.bytes[5])")

        if let fs = try device.index(of: .featureSet) {
            let count = Int(try device.request(featureIndex: fs, function: 0).bytes[4])
            print("== Features (\(count + 1))")
            for i in 0...count {
                let r = try device.request(featureIndex: fs, function: 1, params: [UInt8(i)]).bytes
                print(String(format: "  [%2d] 0x%04x type=%02x v%d", i, u16(r, 4), r[6], r[7]))
            }
        }

        if try device.index(of: .reprogControlsV4) != nil {
            let count = Int(try device.call(.reprogControlsV4, 0)[0])
            print("== Controls (\(count))  flags: divert=1 persist=4 rawXY=16 / remap")
            for i in 0..<count {
                let info = try device.call(.reprogControlsV4, 1, [UInt8(i)])
                let cid = u16(info, 0)
                let rep = try device.call(.reprogControlsV4, 2, [UInt8(cid >> 8), UInt8(cid & 0xFF)])
                print(String(format: "  cid=0x%02x(%3d) tid=0x%02x capFlags=%02x addl=%02x | report flags=%02x remap=0x%04x",
                             cid, cid, u16(info, 2), info[4], info[8], rep[2], u16(rep, 3)))
            }
        }

        for feature in [Feature.smartShift, .smartShiftEnhanced] where try device.index(of: feature) != nil {
            let get: UInt8 = feature == .smartShift ? 0 : 1
            let r = try device.call(feature, get)
            print(String(format: "== SmartShift 0x%04x: mode=%d (1=free,2=ratchet) autoDisengage=%d default=%d raw=%@", feature.rawValue, r[0], r[1], r[2], hex(r.prefix(6))))
        }
        if try device.index(of: .hiResWheel) != nil {
            let cap = try device.call(.hiResWheel, 0)
            let mode = try device.call(.hiResWheel, 1)
            print("== HiResWheel cap=\(hex(cap.prefix(4))) mode=\(String(format: "%02x", mode[0])) (bit0 divert, bit1 hires, bit2 invert)")
        }
        if try device.index(of: .thumbWheel) != nil {
            let info = try device.call(.thumbWheel, 0)
            let status = try device.call(.thumbWheel, 1)
            print("== ThumbWheel info=\(hex(info.prefix(8))) status=\(hex(status.prefix(4))) (status[0]=divert, [1]=invert)")
        }
        if try device.index(of: .adjustableDPI) != nil {
            let list = try device.call(.adjustableDPI, 1, [0])
            let current = try device.call(.adjustableDPI, 2, [0])
            print("== DPI list=\(hex(list.prefix(12))) current=\(u16(current, 1)) default=\(u16(current, 3))")
        }
        if try device.index(of: .unifiedBattery) != nil {
            let s = try device.call(.unifiedBattery, 1)
            print("== Battery (0x1004) percent=\(s[0]) level=\(s[1]) charging=\(s[3])")
        } else if try device.index(of: .batteryStatus) != nil {
            let s = try device.call(.batteryStatus, 0)
            print("== Battery (0x1000) level=\(s[0]) next=\(s[1]) status=\(s[2])")
        }
    }
}
