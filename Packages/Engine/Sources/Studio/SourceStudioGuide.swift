import simd
import CoreMath
import Scene

/// Unity Transform.rotation composes local rotations independently of scale.
/// Extracting a quaternion from a sheared world matrix changes guide behavior.
public enum SourceStudioGuide {
    public static func rotation(node: Int, rig: RigDefinition, pose: RigPose) throws -> simd_quatf {
        guard rig.nodes.indices.contains(node), pose.localMatrices.count == rig.nodes.count else { throw RigError.invalid("Guide has no source transform.") }
        var current: Int? = node, rotation = simd_quatf.identity
        while let index = current {
            guard rig.nodes[index].authoredMatrix == nil, (0..<3).allSatisfy({ rig.nodes[index].scale[$0] > 0 }) else {
                throw RigError.invalid("Guide cannot infer signed or matrix-authored local rotation.")
            }
            let matrix = pose.localMatrices[index], scale = matrix.scaleFactors
            guard (0..<3).allSatisfy({ scale[$0].isFinite && scale[$0] > 1e-8 }) else { throw RigError.invalid("Guide local scale is singular.") }
            let basis = float3x3(Float3(matrix[0].x, matrix[0].y, matrix[0].z) / scale.x,
                Float3(matrix[1].x, matrix[1].y, matrix[1].z) / scale.y,
                Float3(matrix[2].x, matrix[2].y, matrix[2].z) / scale.z)
            guard abs(simd_determinant(basis) - 1) < 1e-4,
                  abs(dot(basis[0], basis[1])) < 1e-4, abs(dot(basis[0], basis[2])) < 1e-4,
                  abs(dot(basis[1], basis[2])) < 1e-4 else { throw RigError.invalid("Guide requires unambiguous local TRS rotation.") }
            rotation = (simd_quatf(basis).normalized * rotation).normalized
            current = rig.nodes[index].parent
        }
        return rotation
    }
}
