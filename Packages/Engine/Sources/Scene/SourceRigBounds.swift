import Foundation
import simd
import CoreMath

/// Conservative bounds for live skinning. A vertex with normalized, nonnegative
/// weights is a convex combination of its joint-transformed positions, so the
/// union of per-joint transformed boxes contains every skinned vertex. Exact
/// CPU deformation remains available on SourceRig for camera fitting/oracles.
public struct SourceRigBounds: Sendable {
    private struct Weight: Equatable, Sendable { let index: Int, weight: Float }
    private struct PartCache: Sendable { let weights: [Weight], joints: [AABB] }
    private let source: SourceRig
    private var cache: [Int: PartCache] = [:]
    public init(source: SourceRig) { self.source = source }

    public mutating func bounds(evaluation: RigEvaluation, morphWeights: [String: [(index: Int, weight: Float)]] = [:]) throws -> AABB {
        guard evaluation.worldMatrices.count == source.rig.nodes.count, evaluation.palettes.count == source.rig.skins.count,
              Set(morphWeights.keys).isSubset(of: Set(source.parts.map { $0.mesh.name })) else {
            throw RigError.invalid("Live bounds do not match their source rig.")
        }
        var result = AABB.empty
        for (index, part) in source.parts.enumerated() where part.rendererEnabled && source.rig.activeNodes[part.node] {
            let active = morphWeights[part.mesh.name] ?? []
            let key = active.map { Weight(index: $0.index, weight: $0.weight) }
            let count = source.rig.skins[part.skin].joints.count
            guard evaluation.palettes[part.skin].count == count else { throw RigError.invalid("Live bounds palette count differs.") }
            if cache[index]?.weights != key {
                try SourceRig.validateMorphWeights(active, mesh: part.mesh)
                guard part.mesh.joints.count == part.mesh.vertexCount, part.mesh.weights.count == part.mesh.vertexCount else {
                    throw RigError.invalid("Live bounds require complete skin weights.")
                }
                var boxes = [AABB](repeating: .empty, count: count)
                for vertex in part.mesh.positions.indices {
                    let joints = part.mesh.joints[vertex], weights = part.mesh.weights[vertex]
                    guard (0..<4).allSatisfy({ weights[$0].isFinite && weights[$0] >= 0 && Int(joints[$0]) < count }),
                          abs(weights.x + weights.y + weights.z + weights.w - 1) <= 0.00001 else {
                        throw RigError.invalid("Live bounds require normalized nonnegative skin weights.")
                    }
                    var point = part.mesh.positions[vertex]
                    for morph in active { point += part.mesh.morphTargets[morph.index].positionDeltas[vertex] * morph.weight }
                    guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { throw RigError.invalid("Live bounds contain a nonfinite morph position.") }
                    for lane in 0..<4 where weights[lane] > 0 { boxes[Int(joints[lane])].expand(point) }
                }
                cache[index] = PartCache(weights: key, joints: boxes)
            }
            let boxes = cache[index]!.joints, model = evaluation.worldMatrices[part.node]
            for joint in boxes.indices where !boxes[joint].isEmpty {
                result.expand(boxes[joint].transformed(by: model * evaluation.palettes[part.skin][joint]))
            }
        }
        if !result.isEmpty {
            // Covers Float summation/weight-normalization rounding at the hull.
            let padding = (simd_max(simd_abs(result.min), simd_abs(result.max)) + SIMD3(repeating: 1)) * 0.0001
            result.min -= padding; result.max += padding
            guard result.min.x.isFinite, result.min.y.isFinite, result.min.z.isFinite,
                  result.max.x.isFinite, result.max.y.isFinite, result.max.z.isFinite else { throw RigError.invalid("Live skinning bounds overflowed.") }
        }
        return result
    }
}
