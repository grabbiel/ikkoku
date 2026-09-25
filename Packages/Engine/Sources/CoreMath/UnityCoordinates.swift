import simd

/// Changes raw Unity left-handed, Y-up data to the engine's right-handed, Y-up basis.
///
/// This boundary reflects Z. It does not change units, UVs, or texture encoding.
/// Apply it exactly once to raw Unity data, never to an already converted glTF.
/// The basis-change operations are involutions and also convert back; the
/// Euler helper instead constructs a native quaternion from source degrees.
public enum UnityCoordinates {
    public static let basis = float4x4(diagonal: Float4(1, 1, -1, 1))

    /// A point in local or world space. Unity +Z becomes engine -Z.
    public static func position(_ value: Float3) -> Float3 {
        Float3(value.x, value.y, -value.z)
    }

    /// A polar vector, including linear velocity and position/morph deltas.
    /// Magnitude is preserved; zero vectors and deltas are not normalized.
    public static func direction(_ value: Float3) -> Float3 {
        position(value)
    }

    /// A surface normal or normal delta. Reflection is its own inverse transpose.
    /// Do not normalize normal deltas before blending them with the base normal.
    public static func normal(_ value: Float3) -> Float3 {
        direction(value)
    }

    /// An axial vector, such as angular velocity or a cross product.
    /// Axial vectors require det(C) * C, unlike positions and linear velocities.
    public static func axialVector(_ value: Float3) -> Float3 {
        Float3(-value.x, -value.y, value.z)
    }

    /// A tangent with bitangent = cross(normal, tangent.xyz) * tangent.w.
    /// Reflection reverses the basis orientation, so handedness must flip too.
    public static func tangent(_ value: Float4) -> Float4 {
        Float4(value.x, value.y, -value.z, -value.w)
    }

    /// Unity quaternion components in (x, y, z, w) order, without Euler conversion.
    /// Satisfies R(convert(q)) = C * R(q) * C. Unit input remains unit length.
    public static func rotation(_ value: simd_quatf) -> simd_quatf {
        let q = value.vector
        return simd_quatf(ix: -q.x, iy: -q.y, iz: q.z, r: q.w)
    }

    /// Unity Quaternion.Euler: degrees, rotating Z first, then X, then Y.
    /// Returns the rotation already converted into the engine basis.
    /// Unity's order differs from the engine's `simd_quatf(eulerXYZ:)`.
    public static func eulerDegrees(_ value: Float3) -> simd_quatf {
        let radians = value * (.pi / 180)
        let x = simd_quatf(angle: radians.x, axis: Float3(1, 0, 0))
        let y = simd_quatf(angle: radians.y, axis: Float3(0, 1, 0))
        let z = simd_quatf(angle: radians.z, axis: Float3(0, 0, 1))
        return rotation(y * x * z)
    }

    /// A source Z-X-Y Euler representation of an edited native quaternion.
    /// Existing source Euler bytes should be retained for an unedited rotation.
    public static func sourceEulerDegrees(_ native: simd_quatf) -> Float3 {
        let m = float3x3(rotation(native).normalized)
        let cosine = sqrt(m[0][1] * m[0][1] + m[1][1] * m[1][1])
        let x = atan2(-m[2][1], cosine)
        let y: Float, z: Float
        if cosine > 0.00001 {
            y = atan2(m[2][0], m[2][2]); z = atan2(m[0][1], m[1][1])
        } else {
            y = atan2(-m[0][2], m[0][0]); z = 0
        }
        return Float3(x, y, z) * (180 / .pi)
    }

    /// Converts a local/world transform or inverse bind matrix, in column layout.
    /// Both the input and output spaces change basis: M' = C * M * C^-1.
    /// Preserves signed scales and shear, without a lossy TRS decomposition.
    /// This is not a conversion of Unity clip-space projection conventions.
    public static func matrix(_ value: float4x4) -> float4x4 {
        basis * value * basis
    }

    public enum ConversionError: Error, Equatable {
        case incompleteTriangle(indexCount: Int)
    }

    /// Reverses each triangle after reflecting its positions, preserving its
    /// outward normal. Index values, vertex order, and joint indices are unchanged.
    /// Non-indexed triangles should first receive sequential vertex indices.
    public static func triangleIndices(_ values: [UInt32]) throws -> [UInt32] {
        guard values.count.isMultiple(of: 3) else {
            throw ConversionError.incompleteTriangle(indexCount: values.count)
        }
        var result = values
        for index in stride(from: 0, to: result.count, by: 3) {
            result.swapAt(index + 1, index + 2)
        }
        return result
    }
}
