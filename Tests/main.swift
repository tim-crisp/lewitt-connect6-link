import Foundation

func db(_ levels: [Int]) -> OutputState { OutputState(levels: levels.map { $0 * 256 }) }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let baseline = db([-30, -20, -10])
let knob = db([-30, -23, -10])
let linked = LinkEngine.follow(previous: baseline, current: knob, mode: .relative)
expect(linked == db([-33, -23, -13]), "Turning Headphone 1 propagates its −3 dB movement")
expect(LinkEngine.follow(previous: linked, current: linked, mode: .relative) == linked,
       "Confirmed writes never produce feedback")
expect(LinkEngine.follow(previous: baseline, current: knob, mode: .equal) == db([-23, -23, -23]),
       "Any changed output can lead equal-level mode")
expect(LinkEngine.adjusting(baseline, source: 2, to: -5 * 256, linked: false, mode: .relative) == db([-30, -20, -5]),
       "Unlinked sliders change only one output")
expect(LinkEngine.follow(previous: db([-1, -20, -59]), current: db([-1, -25, -59]), mode: .relative) == db([-6, -25, -60]),
       "Lower limits clamp per output")
expect(LinkEngine.follow(previous: db([-1, -20, -59]), current: db([-1, -15, -59]), mode: .relative) == db([0, -15, -54]),
       "Upper limits clamp per output")
expect(LinkEngine.follow(previous: baseline, current: db([-28, -18, -8]), mode: .relative) == db([-28, -18, -8]),
       "Already coordinated native changes are not applied twice")
expect(LinkEngine.follow(previous: baseline, current: db([-29, -24, -10]), mode: .relative) == db([-34, -24, -14]),
       "Largest movement wins if two sources change in the same poll")
var muteChange = baseline
muteChange.mutes = [1, 0, 1]
expect(LinkEngine.follow(previous: baseline, current: muteChange, mode: .relative) == muteChange,
       "Independent mutes remain independent during volume linking")
var encoded = [UInt8](repeating: 0, count: 128)
encoded[0] = 0x00; encoded[1] = 0xc4
encoded[2] = 0xbe; encoded[3] = 0xe8
encoded[10] = 1
let decoded = OutputState(bytes: encoded)
expect(decoded.levels == [-15360, -5954, 0] && decoded.mutes == [1, 0, 0],
       "Device fixed-point levels and mutes decode correctly")
expect(decoded.valid && !OutputState(levels: [1, 0, 0]).valid,
       "Unexpected data fails validation")
let individuallyMuted = baseline.togglingMute(1)
expect(individuallyMuted.levels == baseline.levels && individuallyMuted.mutes == [0, 1, 0],
       "Muting Headphone 1 preserves every volume and the other outputs' mutes")
expect(LinkEngine.follow(previous: baseline, current: individuallyMuted, mode: .equal) == individuallyMuted,
       "Output linking does not propagate an individual mute")
expect(individuallyMuted.togglingMute(1) == baseline,
       "An individual output can be unmuted without affecting other outputs")

func encode(_ state: OutputState) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 128)
    for i in 0..<3 {
        let raw = UInt16(bitPattern: Int16(state.levels[i]))
        bytes[i * 2] = UInt8(raw & 0xff)
        bytes[i * 2 + 1] = UInt8(raw >> 8)
        bytes[10 + i] = state.mutes[i]
    }
    bytes[38] = state.nativeVolumeMapping
    return bytes
}

func encodeMobile(_ state: MobileInputState) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 128)
    for i in 0..<2 {
        let offset = [6, 20][i]
        let raw = UInt16(bitPattern: Int16(state.levels[i]))
        bytes[offset] = UInt8(raw & 0xff)
        bytes[offset + 1] = UInt8(raw >> 8)
        bytes[[46, 53][i]] = state.mutes[i]
    }
    return bytes
}

let mobileStart = MobileInputState(levels: [256, -12 * 256], mutes: [0, 1])
let mobileQuieter = mobileStart.adjusting(0, to: -6 * 256)
expect(MobileInputState(bytes: encodeMobile(mobileStart)) == mobileStart,
       "Mobile in levels and send mutes decode from the mixer block")
expect(mobileQuieter.levels == [-6 * 256, -12 * 256] && mobileQuieter.mutes == [0, 1],
       "Changing the listening send preserves the mic-only mix's muted Mobile send")
expect(mobileStart.togglingMute(0) == MobileInputState(levels: mobileStart.levels, mutes: [1, 1]),
       "Mobile sends can be muted independently without changing their levels")
expect(mobileStart.adjusting(1, to: 100 * 256).levels[1] == 10 * 256 &&
       mobileStart.adjusting(1, to: -100 * 256).levels[1] == -60 * 256,
       "Mobile send levels clamp to the fader range")

final class DelayedTransport: SettingsTransport {
    var responses: [[UInt8]]
    var reads = 0
    var writes = 0
    var result: Int32 = 0
    var mixerResponses: [[UInt8]] = [encodeMobile(mobileStart)]
    var mixerReads = 0
    var mobileWrites = 0
    var mobileMasks: (UInt8, UInt8)?
    var outputMasks: (UInt8, UInt8)?
    var mappingWrites = 0
    var requestedMapping: UInt8?
    init(_ states: [OutputState]) { responses = states.map(encode) }
    func read() throws -> [UInt8] {
        reads += 1
        return responses[min(reads - 1, responses.count - 1)]
    }
    func apply(_ target: OutputState, expected: [UInt8], volumeMask: UInt8, muteMask: UInt8) -> Int32 {
        writes += 1
        outputMasks = (volumeMask, muteMask)
        return result
    }
    func readMixer() throws -> [UInt8] {
        mixerReads += 1
        return mixerResponses[min(mixerReads - 1, mixerResponses.count - 1)]
    }
    func applyMobile(_ target: MobileInputState, expected: [UInt8], levelMask: UInt8, muteMask: UInt8) -> Int32 {
        mobileWrites += 1
        mobileMasks = (levelMask, muteMask)
        return result
    }
    func setNativeVolumeMapping(_ mapping: UInt8, expected: [UInt8]) -> Int32 {
        mappingWrites += 1
        requestedMapping = mapping
        return result
    }
}

do {
    let delayed = DelayedTransport([baseline, baseline, linked])
    var waits = 0
    let device = try Device(transport: delayed, waitForFirmware: { waits += 1 })
    let confirmed = try device.apply(linked, expected: encode(baseline))
    expect(confirmed == encode(linked) && delayed.writes == 1 && waits == 2,
           "Old readbacks are allowed to settle without repeating the write")

    // During a follow operation, Headphone 1 is the untouched leader. Its next
    // knob movement must remain visible to the following poll after settling.
    let nextMovement = db([-33, -24, -13])
    let moving = DelayedTransport([knob, nextMovement])
    let movingDevice = try Device(transport: moving, waitForFirmware: {})
    let movingBytes = try movingDevice.apply(linked, expected: encode(knob))!
    expect(LinkEngine.follow(previous: linked, current: OutputState(bytes: movingBytes), mode: .relative) == db([-34, -24, -14]),
           "Continued leader movement during acknowledgement is not lost")

    let muteTarget = OutputState(levels: baseline.levels, mutes: [1, 1, 1])
    let delayedMute = DelayedTransport([baseline, muteTarget])
    let muteDevice = try Device(transport: delayedMute, waitForFirmware: {})
    let confirmedMute = try muteDevice.apply(muteTarget, expected: encode(baseline))
    expect(confirmedMute == encode(muteTarget),
           "Delayed mute acknowledgements are handled too")

    let oneMute = DelayedTransport([baseline, individuallyMuted])
    let oneMuteDevice = try Device(transport: oneMute, waitForFirmware: {})
    let oneConfirmed = try oneMuteDevice.apply(individuallyMuted, expected: encode(baseline))
    expect(oneConfirmed == encode(individuallyMuted) && oneMute.outputMasks?.0 == 0 && oneMute.outputMasks?.1 == 2,
           "An individual mute writes only the selected output's mute flag")

    let mobileDelay = DelayedTransport([baseline])
    mobileDelay.mixerResponses = [encodeMobile(mobileStart), encodeMobile(mobileStart), encodeMobile(mobileQuieter)]
    let mobileDevice = try Device(transport: mobileDelay, waitForFirmware: {})
    let mobileConfirmed = try mobileDevice.applyMobile(mobileQuieter, expected: encodeMobile(mobileStart))
    expect(mobileConfirmed == encodeMobile(mobileQuieter) && mobileDelay.mobileWrites == 1 && mobileDelay.mixerReads == 3,
           "Mobile level acknowledgements may be delayed without repeated writes")
    expect(mobileDelay.mobileMasks?.0 == 1 && mobileDelay.mobileMasks?.1 == 0 && mobileDelay.writes == 0,
           "Changing Mobile Mix A touches no other send, route, mute or output setting")

    let mobileMuted = mobileStart.togglingMute(0)
    let mobileMuteDelay = DelayedTransport([baseline])
    mobileMuteDelay.mixerResponses = [encodeMobile(mobileStart), encodeMobile(mobileMuted)]
    let mobileMuteDevice = try Device(transport: mobileMuteDelay, waitForFirmware: {})
    let mutedConfirmed = try mobileMuteDevice.applyMobile(mobileMuted, expected: encodeMobile(mobileStart))
    expect(mutedConfirmed == encodeMobile(mobileMuted) && mobileMuteDelay.mobileMasks?.0 == 0 && mobileMuteDelay.mobileMasks?.1 == 1,
           "A Mobile send mute preserves its volume and the other bus")

    let stuck = DelayedTransport([baseline])
    let stuckDevice = try Device(transport: stuck, waitForFirmware: {})
    var rejected = false
    do { _ = try stuckDevice.apply(linked, expected: encode(baseline)) }
    catch { rejected = true }
    expect(rejected && stuck.reads == 7 && stuck.writes == 1,
           "A genuinely unconfirmed write stops after a bounded wait")

    let busy = DelayedTransport([baseline])
    busy.result = Int32(bitPattern: 0xe00002d5)
    let busyDevice = try Device(transport: busy, waitForFirmware: {})
    let competing = try busyDevice.apply(linked, expected: encode(baseline))
    expect(competing == nil && busy.reads == 0,
           "Pre-write competing changes are reconsidered without a writeback baseline")

    let busyMobile = try busyDevice.applyMobile(mobileQuieter, expected: encodeMobile(mobileStart))
    expect(busyMobile == nil && busy.mixerReads == 0,
           "Mobile send conflicts are reconsidered without changing output feedback")

    let stuckMobile = DelayedTransport([baseline])
    let stuckMobileDevice = try Device(transport: stuckMobile, waitForFirmware: {})
    var mobileRejected = false
    do { _ = try stuckMobileDevice.applyMobile(mobileQuieter, expected: encodeMobile(mobileStart)) }
    catch { mobileRejected = true }
    expect(mobileRejected && stuckMobile.mixerReads == 7 && stuckMobile.mobileWrites == 1,
           "Unconfirmed Mobile edits stop after a bounded wait")

    for output in 0..<3 {
        var assigned = baseline
        assigned.nativeVolumeMapping = UInt8(1 << output)
        expect(OutputState(bytes: encode(assigned)).volumeKeyTarget == output,
               "Volume-key target decodes for each output")
    }
    expect(baseline.volumeKeyTarget == nil,
           "None mapping does not show an active output")
    var assigned = baseline
    assigned.nativeVolumeMapping = 4
    let mappingDelay = DelayedTransport([baseline, baseline, assigned])
    let mappingDevice = try Device(transport: mappingDelay, waitForFirmware: {})
    let assignedBytes = try mappingDevice.setNativeVolumeMapping(4, expected: encode(baseline))
    expect(assignedBytes == encode(assigned) && mappingDelay.mappingWrites == 1 && mappingDelay.requestedMapping == 4,
           "Volume-key assignment waits for delayed firmware confirmation")
    expect(mappingDelay.writes == 0 && mappingDelay.mobileWrites == 0,
           "Activation never writes levels, mutes or Mobile sends")
    expect(LinkEngine.follow(previous: baseline, current: assigned, mode: .equal) == assigned,
           "Changing the active target alone never synchronizes output volumes")
    let alreadyAssigned = try mappingDevice.setNativeVolumeMapping(4, expected: encode(assigned))
    expect(alreadyAssigned == encode(assigned) && mappingDelay.mappingWrites == 1,
           "Activating the current target does not write again")
    let competingMapping = try busyDevice.setNativeVolumeMapping(2, expected: encode(baseline))
    expect(competingMapping == nil && busy.mappingWrites == 1,
           "Concurrent mapping edits are reconsidered without volume changes")
    var invalidMappingRejected = false
    do { _ = try mappingDevice.setNativeVolumeMapping(3, expected: encode(baseline)) }
    catch { invalidMappingRejected = true }
    expect(invalidMappingRejected && mappingDelay.mappingWrites == 1,
           "Invalid volume-key targets never reach the device")
    let stuckMapping = DelayedTransport([baseline])
    let stuckMappingDevice = try Device(transport: stuckMapping, waitForFirmware: {})
    var mappingRejected = false
    do { _ = try stuckMappingDevice.setNativeVolumeMapping(1, expected: encode(baseline)) }
    catch { mappingRejected = true }
    expect(mappingRejected && stuckMapping.reads == 7 && stuckMapping.mappingWrites == 1,
           "Unconfirmed volume-key assignment has a bounded wait")
} catch {
    fputs("FAIL: delayed acknowledgement checks: \(error)\n", stderr)
    exit(1)
}
print("PASS: 40 checks for linking, mutes, Mobile in, volume-key activation, isolation and delayed acknowledgements")
