import Foundation
import simd
import CoreMath
import Scene

/// Idle life: periodic blinking and a subtle breathing sway, like Koikatsu's characters at rest.
public enum LiveAnimation {

    /// Blink weight 0…1 at `time` for a character with `seed` (blinks every ~3–5 s, 0.24 s long).
    public static func blinkWeight(time: Double, seed: UInt64) -> Float {
        // Deterministic pseudo-random intervals from the seed.
        var t = time + Double(seed % 97) * 0.37
        var cycle: UInt64 = seed
        var interval = 3.6
        while t > interval {
            t -= interval
            cycle = cycle &* 6364136223846793005 &+ 1442695040888963407
            interval = 2.8 + Double((cycle >> 33) % 1000) / 1000 * 2.6
        }
        let d = 0.24
        guard t < d else { return 0 }
        let x = Float(t / d)
        // fast close, slower open
        return x < 0.4 ? smoothstep(0, 0.4, x) : 1 - smoothstep(0.4, 1, x)
    }

    /// Breathing / weight-shift sway (degrees) for a few bones.
    public static func breathing(time: Double, seed: UInt64, strength: Float = 1) -> PoseDelta {
        let phase = Float(time * 2 * .pi / 4.2 + Double(seed % 13) * 0.5)
        let s = sin(phase) * strength
        let s2 = sin(phase * 0.5 + 1.3) * strength
        return PoseDelta(rotations: [
            "spine02": Float3(0.9 * s, 0, 0),
            "spine03": Float3(0.7 * s, 0, 0.25 * s2),
            "neck": Float3(-0.5 * s, 0.3 * s2, 0),
            "head": Float3(-0.4 * s, 0.4 * s2, 0.2 * s2),
            "upperarm_L": Float3(0, 0, -0.6 * s), "upperarm_R": Float3(0, 0, 0.6 * s),
            "bust_L": Float3(0.8 * s, 0, 0), "bust_R": Float3(0.8 * s, 0, 0),
        ])
    }
}
