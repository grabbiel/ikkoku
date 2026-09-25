import simd
import CoreMath
import Scene

/// Component setters in the source retain the incoming transform's untouched
/// channels. This decomposition is limited to the positive local TRS pose path.
enum SourceShapePoseBaseline {
    static func components(_ matrix: float4x4) throws -> (position: Float3, rotation: simd_quatf, scale: Float3) {
        let scale = matrix.scaleFactors
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }),
              matrix[0].w == 0, matrix[1].w == 0, matrix[2].w == 0, matrix[3].w == 1,
              (0..<3).allSatisfy({ scale[$0] > 1e-8 && scale[$0].isFinite }) else {
            throw RigError.invalid("Shape baseline requires finite affine nonsingular TRS.")
        }
        let basis = float3x3(Float3(matrix[0].x, matrix[0].y, matrix[0].z) / scale.x,
                             Float3(matrix[1].x, matrix[1].y, matrix[1].z) / scale.y,
                             Float3(matrix[2].x, matrix[2].y, matrix[2].z) / scale.z)
        guard abs(simd_determinant(basis) - 1) < 1e-4,
              abs(dot(basis[0], basis[1])) < 1e-4, abs(dot(basis[0], basis[2])) < 1e-4,
              abs(dot(basis[1], basis[2])) < 1e-4 else {
            throw RigError.invalid("Shape baseline does not support local reflection or shear.")
        }
        return (matrix.translation, simd_quatf(basis).normalized, scale)
    }
}
