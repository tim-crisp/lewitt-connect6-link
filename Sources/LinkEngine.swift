import Foundation

enum LinkMode: String, CaseIterable {
    case relative = "Keep level differences"
    case equal = "Same dB level"
}

struct OutputState: Equatable {
    var levels: [Int]
    var mutes: [UInt8]
    var nativeVolumeMapping: UInt8

    init(bytes: [UInt8]) {
        levels = (0..<3).map { i in
            Int(Int16(bitPattern: UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8))
        }
        mutes = Array(bytes[10..<13])
        nativeVolumeMapping = bytes[38]
    }

    init(levels: [Int], mutes: [UInt8] = [0, 0, 0], nativeVolumeMapping: UInt8 = 0) {
        self.levels = levels
        self.mutes = mutes
        self.nativeVolumeMapping = nativeVolumeMapping
    }

    var volumeKeyTarget: Int? {
        (0..<3).first { nativeVolumeMapping == UInt8(1 << $0) }
    }

    var valid: Bool {
        levels.count == 3 && mutes.count == 3 &&
        levels.allSatisfy { (-60 * 256...0).contains($0) } &&
        mutes.allSatisfy { $0 <= 1 }
    }

    func togglingMute(_ output: Int) -> OutputState {
        var target = self
        target.mutes[output] = mutes[output] == 0 ? 1 : 0
        return target
    }
}

struct MobileInputState: Equatable {
    var levels: [Int]
    var mutes: [UInt8]

    init(bytes: [UInt8]) {
        levels = [6, 20].map { offset in
            Int(Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8))
        }
        mutes = [bytes[46], bytes[53]]
    }

    init(levels: [Int], mutes: [UInt8]) {
        self.levels = levels
        self.mutes = mutes
    }

    var valid: Bool {
        levels.count == 2 && mutes.count == 2 &&
        levels.allSatisfy { (-60 * 256...10 * 256).contains($0) } &&
        mutes.allSatisfy { $0 <= 1 }
    }

    func adjusting(_ mix: Int, to raw: Int) -> MobileInputState {
        var target = self
        target.levels[mix] = min(10 * 256, max(-60 * 256, raw))
        return target
    }

    func togglingMute(_ mix: Int) -> MobileInputState {
        var target = self
        target.mutes[mix] = mutes[mix] == 0 ? 1 : 0
        return target
    }
}

struct LinkEngine {
    static func clamp(_ raw: Int) -> Int { min(0, max(-60 * 256, raw)) }

    // Derive from the previous confirmed state, so our own writes do not feed
    // back into the next poll. If multiple controls change between polls, the
    // largest movement wins; ties use Speakers, then Headphone 1, then 2.
    static func follow(previous: OutputState, current: OutputState,
                       mode: LinkMode) -> OutputState {
        let deltas = zip(current.levels, previous.levels).map(-)
        guard let source = deltas.indices.max(by: {
            abs(deltas[$0]) < abs(deltas[$1]) ||
            (abs(deltas[$0]) == abs(deltas[$1]) && $0 > $1)
        }), deltas[source] != 0 else { return current }
        var target = current
        if mode == .equal {
            target.levels = Array(repeating: current.levels[source], count: 3)
        } else {
            target.levels = previous.levels.map { clamp($0 + deltas[source]) }
        }
        return target
    }

    static func adjusting(_ current: OutputState, source: Int, to raw: Int,
                          linked: Bool, mode: LinkMode) -> OutputState {
        var target = current
        target.levels[source] = clamp(raw)
        return linked ? follow(previous: current, current: target, mode: mode) : target
    }
}
