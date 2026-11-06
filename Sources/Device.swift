import Foundation

struct DeviceError: Error, CustomStringConvertible {
    let description: String
}

// Keep the transport replaceable so delayed USB acknowledgements can be tested.
protocol SettingsTransport {
    func read() throws -> [UInt8]
    func apply(_ target: OutputState, expected: [UInt8], volumeMask: UInt8, muteMask: UInt8) -> Int32
    func readMixer() throws -> [UInt8]
    func applyMobile(_ target: MobileInputState, expected: [UInt8], levelMask: UInt8, muteMask: UInt8) -> Int32
    func setNativeVolumeMapping(_ mapping: UInt8, expected: [UInt8]) -> Int32
}

private final class USBTransport: SettingsTransport {
    private let handle: OpaquePointer

    init() throws {
        var code: Int32 = 0
        guard let handle = c6_open(&code) else {
            let reason: String
            switch UInt32(bitPattern: code) {
            case 0xe00002c0: reason = "CONNECT 6 disconnected. Waiting for it…"
            case 0xe00002c7: reason = "Unsupported firmware. This build requires CONNECT 6 firmware 2.2.7."
            case 0xe00002c5: reason = "Connect one CONNECT 6 at a time."
            default: reason = "Cannot access CONNECT 6 (USB \(String(UInt32(bitPattern: code), radix: 16)))."
            }
            throw DeviceError(description: reason)
        }
        self.handle = handle
    }

    deinit { c6_close(handle) }

    func read() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 128)
        let result = c6_read(handle, &bytes)
        guard result == 0 else { throw DeviceError(description: "USB read failed. Reconnecting…") }
        return bytes
    }

    func apply(_ target: OutputState, expected: [UInt8], volumeMask: UInt8, muteMask: UInt8) -> Int32 {
        c6_apply(handle, expected, target.levels.map(Int16.init), volumeMask, target.mutes, muteMask)
    }

    func readMixer() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 128)
        guard c6_read_mixer(handle, &bytes) == 0 else {
            throw DeviceError(description: "USB mixer read failed. Reconnecting…")
        }
        return bytes
    }

    func applyMobile(_ target: MobileInputState, expected: [UInt8], levelMask: UInt8, muteMask: UInt8) -> Int32 {
        c6_apply_mobile(handle, expected, target.levels.map(Int16.init), levelMask, target.mutes, muteMask)
    }

    func setNativeVolumeMapping(_ mapping: UInt8, expected: [UInt8]) -> Int32 {
        c6_set_native_volume_mapping(handle, expected, mapping)
    }
}

final class Device {
    private let transport: SettingsTransport
    private let waitForFirmware: () -> Void

    init(transport: SettingsTransport? = nil,
         waitForFirmware: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.02) }) throws {
        self.transport = try transport ?? USBTransport()
        self.waitForFirmware = waitForFirmware
    }

    func read() throws -> [UInt8] {
        let bytes = try transport.read()
        guard bytes.count == 128, OutputState(bytes: bytes).valid else {
            throw DeviceError(description: "Unexpected output data. Linking has stopped.")
        }
        return bytes
    }

    func readMixer() throws -> [UInt8] {
        let bytes = try transport.readMixer()
        guard bytes.count == 128, MobileInputState(bytes: bytes).valid else {
            throw DeviceError(description: "Unexpected Mobile in data. Controls have stopped.")
        }
        return bytes
    }

    func setNativeVolumeMapping(_ mapping: UInt8, expected: [UInt8]) throws -> [UInt8]? {
        guard expected.count == 128, [0, 1, 2, 4].contains(mapping) else {
            throw DeviceError(description: "Invalid volume-key assignment.")
        }
        if expected[38] == mapping { return expected }
        let result = transport.setNativeVolumeMapping(mapping, expected: expected)
        if UInt32(bitPattern: result) == 0xe00002d5 { return nil }
        guard result == 0 else {
            throw DeviceError(description: "USB volume-key assignment failed. Controls have stopped.")
        }
        for attempt in 0..<7 {
            if attempt > 0 { waitForFirmware() }
            let confirmed = try read()
            if confirmed[38] == mapping { return confirmed }
        }
        throw DeviceError(description: "CONNECT 6 did not confirm the volume-key assignment. Controls have stopped.")
    }

    func applyMobile(_ target: MobileInputState, expected: [UInt8]) throws -> [UInt8]? {
        guard expected.count == 128, target.valid else {
            throw DeviceError(description: "Invalid Mobile in setting.")
        }
        let old = MobileInputState(bytes: expected)
        let levelMask = (0..<2).reduce(UInt8(0)) { $0 | (old.levels[$1] != target.levels[$1] ? 1 << $1 : 0) }
        let muteMask = (0..<2).reduce(UInt8(0)) { $0 | (old.mutes[$1] != target.mutes[$1] ? 1 << $1 : 0) }
        if levelMask == 0 && muteMask == 0 { return expected }
        let result = transport.applyMobile(target, expected: expected, levelMask: levelMask, muteMask: muteMask)
        if UInt32(bitPattern: result) == 0xe00002d5 { return nil }
        guard result == 0 else {
            throw DeviceError(description: "USB Mobile in write failed. Controls have stopped.")
        }
        for attempt in 0..<7 {
            if attempt > 0 { waitForFirmware() }
            let confirmed = try readMixer()
            let state = MobileInputState(bytes: confirmed)
            var matches = true
            for i in 0..<2 {
                let bit = UInt8(1 << i)
                let levelOK = levelMask & bit == 0 || state.levels[i] == target.levels[i]
                let muteOK = muteMask & bit == 0 || state.mutes[i] == target.mutes[i]
                matches = matches && levelOK && muteOK
            }
            if matches { return confirmed }
        }
        throw DeviceError(description: "CONNECT 6 did not confirm the Mobile in setting. Controls have stopped.")
    }

    // Returns nil on a competing change; the next poll will reconsider it.
    func apply(_ target: OutputState, expected: [UInt8]) throws -> [UInt8]? {
        guard target.valid else { throw DeviceError(description: "Invalid output level.") }
        let old = OutputState(bytes: expected)
        let volumeMask = (0..<3).reduce(UInt8(0)) { $0 | (old.levels[$1] != target.levels[$1] ? 1 << $1 : 0) }
        let muteMask = (0..<3).reduce(UInt8(0)) { $0 | (old.mutes[$1] != target.mutes[$1] ? 1 << $1 : 0) }
        if volumeMask == 0 && muteMask == 0 { return expected }
        let result = transport.apply(target, expected: expected, volumeMask: volumeMask, muteMask: muteMask)
        if UInt32(bitPattern: result) == 0xe00002d5 { return nil } // kIOReturnBusy
        guard result == 0 else {
            throw DeviceError(description: "USB write failed. Linking has stopped.")
        }
        // USB completion means the request was received, not that the DSP has
        // applied it. Firmware 2.2.7 can return the pre-write settings for the
        // first few reads. Wait up to 120 ms, without resending the command.
        for attempt in 0..<7 {
            if attempt > 0 { waitForFirmware() }
            let confirmed = try read()
            let state = OutputState(bytes: confirmed)
            var matches = true
            for i in 0..<3 {
                let bit = UInt8(1 << i)
                let volumeOK = volumeMask & bit == 0 || state.levels[i] == target.levels[i]
                let muteOK = muteMask & bit == 0 || state.mutes[i] == target.mutes[i]
                matches = matches && volumeOK && muteOK
            }
            if matches { return confirmed }
        }
        throw DeviceError(description: "CONNECT 6 did not confirm the new levels. Linking has stopped.")
    }
}
