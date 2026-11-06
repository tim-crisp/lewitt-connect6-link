import Foundation

do {
    let device = try Device()
    let bytes = try device.read()
    let original = OutputState(bytes: bytes)
    let names = ["Speakers", "Headphone 1", "Headphone 2"]
    for i in 0..<3 {
        print("\(names[i]): \(Double(original.levels[i]) / 256) dB, mute=\(original.mutes[i])")
    }
    print("Mac volume keys: \(original.volumeKeyTarget.map { names[$0] } ?? "None / unrecognized mapping")")
    let mixerBytes = try device.readMixer()
    let mobile = MobileInputState(bytes: mixerBytes)
    for i in 0..<2 {
        print("Mobile in → Mix \(i == 0 ? "A" : "B"): \(Double(mobile.levels[i]) / 256) dB, mute=\(mobile.mutes[i])")
    }
    if CommandLine.arguments.contains("--verify-volume-keys") {
        for output in 0..<3 {
            let before = try device.read()
            let oldMapping = before[38]
            let mapping = UInt8(1 << output)
            var changed = true
            do {
                guard let assigned = try device.setNativeVolumeMapping(mapping, expected: before) else {
                    throw DeviceError(description: "A competing volume-key assignment prevented verification.")
                }
                for i in 0..<128 where i != 38 {
                    guard assigned[i] == before[i] else {
                        throw DeviceError(description: "An unrelated setting changed during volume-key verification.")
                    }
                }
                guard let restored = try device.setNativeVolumeMapping(oldMapping, expected: assigned) else {
                    throw DeviceError(description: "Could not restore volume-key assignment.")
                }
                changed = false
                guard restored == before, try device.readMixer() == mixerBytes else {
                    throw DeviceError(description: "Settings differ after restoring the volume-key assignment.")
                }
                print("PASS: activated \(names[output]) for Mac volume keys and restored mapping; all levels/mutes/mixer settings preserved.")
            } catch {
                if changed, let now = try? device.read(), now[38] == mapping {
                    _ = try? device.setNativeVolumeMapping(oldMapping, expected: now)
                }
                throw error
            }
        }
    }
    if CommandLine.arguments.contains("--verify-controls") {
        // Attenuation/muting only: never temporarily unmute an output or send
        // that was muted on entry, particularly the mic-only Mix B send.
        for output in 0..<3 {
            let before = try device.read()
            let start = OutputState(bytes: before)
            if start.mutes[output] == 1 {
                print("SKIP: \(names[output]) already muted; left muted.")
                continue
            }
            let target = start.togglingMute(output)
            var changed = true
            do {
                guard let confirmed = try device.apply(target, expected: before),
                      let restored = try device.apply(start, expected: confirmed) else {
                    throw DeviceError(description: "Competing output adjustment during mute check.")
                }
                changed = false
                guard restored == before, try device.readMixer() == mixerBytes else {
                    throw DeviceError(description: "Unrelated settings changed during output mute check.")
                }
                print("PASS: \(names[output]) muted/restored independently; general and mixer settings preserved.")
            } catch {
                if changed, let now = try? device.read(), OutputState(bytes: now) == target {
                    _ = try? device.apply(start, expected: now)
                }
                throw error
            }
        }
        for mix in 0..<2 {
            let generalBefore = try device.read()
            for checkMute in [false, true] {
                let before = try device.readMixer()
                let start = MobileInputState(bytes: before)
                if checkMute && start.mutes[mix] == 1 {
                    print("SKIP: Mobile in → Mix \(mix == 0 ? "A" : "B") already muted; left muted.")
                    continue
                }
                let target = checkMute ? start.togglingMute(mix) : start.adjusting(mix, to: start.levels[mix] - 128)
                var changed = true
                do {
                    guard let confirmed = try device.applyMobile(target, expected: before),
                          let restored = try device.applyMobile(start, expected: confirmed) else {
                        throw DeviceError(description: "Competing Mobile in adjustment during check.")
                    }
                    changed = false
                    guard restored == before, try device.read() == generalBefore else {
                        throw DeviceError(description: "Unrelated settings changed during Mobile in check.")
                    }
                    print("PASS: Mobile in → Mix \(mix == 0 ? "A" : "B") \(checkMute ? "mute" : "level") changed/restored; all other settings preserved.")
                } catch {
                    if changed, let now = try? device.readMixer(), MobileInputState(bytes: now) == target {
                        _ = try? device.applyMobile(start, expected: now)
                    }
                    throw error
                }
            }
        }
    }
    if CommandLine.arguments.contains("--verify-write") {
        var quieter = original
        quieter.levels = original.levels.map { LinkEngine.clamp($0 - 128) }
        var changed = false
        do {
            guard let confirmed = try device.apply(quieter, expected: bytes) else {
                throw DeviceError(description: "Device changed before test; no write made.")
            }
            changed = true
            guard let restored = try device.apply(original, expected: confirmed) else {
                throw DeviceError(description: "Device changed during test; automatic restoration skipped.")
            }
            changed = false
            guard restored == bytes else {
                throw DeviceError(description: "An unrelated setting changed during verification.")
            }
            print("PASS: lowered all outputs by 0.5 dB, read back, restored originals; all 128 settings bytes unchanged.")
        } catch {
            if changed {
                // Only restore if the test levels are still present; respect user adjustments.
                if let now = try? device.read(), OutputState(bytes: now).levels == quieter.levels {
                    _ = try? device.apply(original, expected: now)
                }
            }
            throw error
        }
    }
    if CommandLine.arguments.contains("--verify-link") {
        // Exercise the same source-change/follow cycle as the worker for each
        // possible leader. Only attenuate, and restore before trying the next.
        for source in 0..<3 {
            let before = try device.read()
            let start = OutputState(bytes: before)
            let input = LinkEngine.adjusting(start, source: source,
                to: start.levels[source] - 128, linked: false, mode: .relative)
            var changed = false
            var expectedLevels = input.levels
            do {
                guard let inputBytes = try device.apply(input, expected: before) else {
                    throw DeviceError(description: "Competing adjustment before link check.")
                }
                changed = true
                let target = LinkEngine.follow(previous: start,
                    current: OutputState(bytes: inputBytes), mode: .relative)
                expectedLevels = target.levels
                guard let linkedBytes = try device.apply(target, expected: inputBytes) else {
                    throw DeviceError(description: "Competing adjustment during link check.")
                }
                guard OutputState(bytes: linkedBytes).levels == target.levels,
                      let restored = try device.apply(start, expected: linkedBytes) else {
                    throw DeviceError(description: "Could not restore after link check.")
                }
                changed = false
                guard restored == before else {
                    throw DeviceError(description: "An unrelated setting changed during link check.")
                }
                print("PASS: \(names[source]) led a 0.5 dB reduction; followers confirmed; all settings restored.")
            } catch {
                if changed, let now = try? device.read(), OutputState(bytes: now).levels == expectedLevels {
                    _ = try? device.apply(start, expected: now)
                }
                throw error
            }
        }
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
