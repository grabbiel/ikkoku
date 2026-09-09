import Foundation
import simd
import CoreMath

/// Analytic two-bone IK (shoulder→elbow→wrist or hip→knee→ankle) with a pole target.
public enum IKSolver {

    /// Rotation deltas (world space) for the upper and lower bones so that the chain end reaches `target`.
    /// - Parameters: a = root joint, b = mid joint, c = end effector (world, current pose).
    ///   `pole` = world point the middle joint bends toward (nil keeps the current bend plane).
    /// Apply as `newUpperWorld = upper * oldUpperWorld`, `newLowerWorld = lower * oldLowerWorld`.
    public static func twoBone(a: Float3, b: Float3, c: Float3, target: Float3, pole: Float3?) -> (upper: simd_quatf, lower: simd_quatf) {
        let l1 = max(length(b - a), 1e-5)
        let l2 = max(length(c - b), 1e-5)
        let eps: Float = 1e-4
        let toT = target - a
        let d = clamp(length(toT), eps, l1 + l2 - eps)
        let x = length(toT) > 1e-6 ? normalize(toT) : normalize(c - a)

        // Bend direction: perpendicular component of (pole - a), else of the current mid joint.
        var bendRef = pole.map { $0 - a } ?? (b - a)
        var y = bendRef - x * dot(bendRef, x)
        if length_squared(y) < 1e-8 {
            bendRef = b - a
            y = bendRef - x * dot(bendRef, x)
            if length_squared(y) < 1e-8 {
                y = abs(x.y) < 0.9 ? cross(x, Float3(0, 1, 0)) : cross(x, Float3(1, 0, 0))
            }
        }
        y = normalize(y)

        let cosA = clamp((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d), -1, 1)
        let sinA = sqrt(max(0, 1 - cosA * cosA))
        let newB = a + x * (l1 * cosA) + y * (l1 * sinA)
        let newC = a + x * d

        let upper = simd_quatf.rotation(from: b - a, to: newB - a)
        let lowerOld = c - b
        let lower = simd_quatf.rotation(from: lowerOld, to: newC - newB)
        return (upper.normalized, lower.normalized)
    }

    /// Cyclic coordinate descent for arbitrary chains. `positions` are world joint positions root→tip.
    /// Returns world rotation deltas to apply to each joint except the tip.
    public static func ccd(positions: [Float3], target: Float3, iterations: Int = 8) -> [simd_quatf] {
        var pos = positions
        let n = pos.count
        guard n >= 2 else { return [] }
        var deltas = [simd_quatf](repeating: .identity, count: n - 1)
        for _ in 0..<iterations {
            for j in stride(from: n - 2, through: 0, by: -1) {
                let toTip = pos[n - 1] - pos[j]
                let toTarget = target - pos[j]
                if length_squared(toTip) < 1e-8 || length_squared(toTarget) < 1e-8 { continue }
                let q = simd_quatf.rotation(from: toTip, to: toTarget)
                deltas[j] = q * deltas[j]
                for k in (j + 1)..<n { pos[k] = pos[j] + q.act(pos[k] - pos[j]) }
                for k in (j + 1)..<(n - 1) { deltas[k] = q * deltas[k] }
            }
            if length(pos[n - 1] - target) < 1e-4 { break }
        }
        return deltas
    }
}
