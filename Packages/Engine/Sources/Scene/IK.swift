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

    /// Checked `twoBone` (R4): throws `MathContractError` where `twoBone`
    /// would return NaN rotations, and otherwise returns exactly `twoBone`.
    /// Rejected: a nonfinite joint, target or pole; an upper (`b - a`) or lower
    /// (`c - b`) bone of length at most `Float3.minimumDirectionLength`; a reach
    /// with no direction (the target on the root and the end on the root too);
    /// and any remaining nonfinite solution, such as a lower bone so short that
    /// the solved mid and end joints coincide.
    public static func checkedTwoBone(a: Float3, b: Float3, c: Float3, target: Float3,
                                      pole: Float3?) throws -> (upper: simd_quatf, lower: simd_quatf) {
        var points: [(Float3, String)] = [(a, "IK root joint"), (b, "IK mid joint"), (c, "IK end joint"), (target, "IK target")]
        if let pole { points.append((pole, "IK pole")) }
        for (point, name) in points where !(point.x.isFinite && point.y.isFinite && point.z.isFinite) {
            throw MathContractError.nonfinite(name)
        }
        _ = try (b - a).checkedNormalized("IK upper bone")
        _ = try (c - b).checkedNormalized("IK lower bone")
        // Same choice as `twoBone`: aim at the target, or along the current
        // chain when the target sits on the root.
        let toTarget = target - a
        _ = try (length(toTarget) > 1e-6 ? toTarget : c - a).checkedNormalized("IK reach")
        let result = twoBone(a: a, b: b, c: c, target: target, pole: pole)
        guard isFinite(result.upper), isFinite(result.lower) else { throw MathContractError.nonfinite("IK solution") }
        return result
    }

    /// One chain of `pose` solved toward `target` (both in the skeleton's
    /// root space): `checkedTwoBone` on the current world joint positions of
    /// `upper`, `lower` and `end`, with its world deltas converted back to
    /// local rotations of `upper` and `lower`. A nil `pole` bends toward the
    /// current mid joint plus `defaultPoleOffset`. This is the per-chain update
    /// of `CharacterInstance.applyIK`. Throws `PoseError` for a pose that does
    /// not match `skeleton` or an index outside it, and `MathContractError` for
    /// a degenerate solve; nothing is written then, so the caller's pose stays
    /// unchanged.
    public static func solveTwoBone(_ pose: Pose, skeleton: Skeleton, upper ui: Int, lower li: Int, end ei: Int,
                                    target: Float3, pole: Float3?, defaultPoleOffset: Float3 = .zero) throws -> Pose {
        try pose.validate(for: skeleton)
        for index in [ui, li, ei] where !skeleton.bones.indices.contains(index) {
            throw PoseError.boneOutOfRange(index: index, count: skeleton.count)
        }
        var p = pose
        let world = p.worldMatrices(skeleton: skeleton)
        let a = world[ui].translation, b = world[li].translation, c = world[ei].translation
        let r = try checkedTwoBone(a: a, b: b, c: c, target: target, pole: pole ?? (b + defaultPoleOffset))
        // Upper: world delta → local
        let upperWorldRot = p.worldRotation(ui, skeleton: skeleton)
        let parentRot = skeleton.bones[ui].parent.map { p.worldRotation($0, skeleton: skeleton) } ?? .identity
        p.rotations[ui] = (parentRot.inverse * (r.upper * upperWorldRot)).normalized
        // Lower: kept exactly as before (R4 adds guards only). `p` already
        // holds the new upper rotation, so this applies the upper delta to the
        // lower bone a second time and the end can miss the target; see the
        // R4 remaining work in docs/reference/renderer.md.
        let lowerWorldRot = r.upper * p.worldRotation(li, skeleton: skeleton)
        let newUpperWorld = p.worldRotation(ui, skeleton: skeleton)
        p.rotations[li] = (newUpperWorld.inverse * (r.lower * lowerWorldRot)).normalized
        return p
    }

    private static func isFinite(_ q: simd_quatf) -> Bool {
        q.vector.x.isFinite && q.vector.y.isFinite && q.vector.z.isFinite && q.vector.w.isFinite
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
