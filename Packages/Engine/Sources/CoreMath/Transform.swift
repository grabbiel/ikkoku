import Foundation
import simd

public typealias Float3 = SIMD3<Float>
public typealias Float4 = SIMD4<Float>
public typealias Float2 = SIMD2<Float>

/// Defined failures of the checked CoreMath helpers (R4). The unchecked helpers
/// keep their historical formulas and assume usable finite input; import,
/// decoding and editing boundaries call the `checked…` forms instead, which
/// return exactly the unchecked result for accepted input. The associated text
/// names the rejected argument.
public enum MathContractError: Error, Equatable, CustomStringConvertible {
    /// A component, or a length computed from finite components, is NaN or infinite.
    case nonfinite(String)
    /// A direction is zero or shorter than `Float3.minimumDirectionLength`.
    case degenerateDirection(String)
    /// A basis column has (near-)zero length or the columns are dependent.
    case singularMatrix(String)
    /// The basis reflects, which a unit quaternion cannot represent.
    case reflectedMatrix(String)
    /// The basis is sheared or the bottom row is not affine, which TRS cannot represent.
    case unsupportedMatrix(String)

    public var description: String {
        switch self {
        case .nonfinite(let name): return "\(name) is not finite."
        case .degenerateDirection(let name): return "\(name) has zero or near-zero length and no direction."
        case .singularMatrix(let name): return "\(name) is singular."
        case .reflectedMatrix(let name): return "\(name) contains a reflection."
        case .unsupportedMatrix(let name): return "\(name) is sheared or not affine, so rotation and scale cannot represent it."
        }
    }
}

public extension SIMD3 where Scalar == Float {
    /// Shortest vector the checked direction helpers accept. Shorter input has
    /// no reliable direction, and normalizing zero yields NaN.
    static var minimumDirectionLength: Float { 1e-6 }

    /// Checked `normalize(self)`: throws for nonfinite input (including a
    /// squared length that overflows) and for length at most
    /// `minimumDirectionLength`; otherwise returns exactly `normalize(self)`.
    func checkedNormalized(_ name: String = "vector") throws -> SIMD3<Float> {
        let squared = length_squared(self)
        guard x.isFinite, y.isFinite, z.isFinite, squared.isFinite else { throw MathContractError.nonfinite(name) }
        guard squared > Self.minimumDirectionLength * Self.minimumDirectionLength else {
            throw MathContractError.degenerateDirection(name)
        }
        return normalize(self)
    }
}

public enum Transform {
    public static let identity = matrix_identity_float4x4

    public static func translation(_ t: Float3) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = Float4(t.x, t.y, t.z, 1)
        return m
    }

    public static func scale(_ s: Float3) -> float4x4 {
        float4x4(diagonal: Float4(s.x, s.y, s.z, 1))
    }

    public static func scale(_ s: Float) -> float4x4 { scale(Float3(repeating: s)) }

    public static func rotationX(_ r: Float) -> float4x4 {
        let c = cos(r), s = sin(r)
        return float4x4(Float4(1, 0, 0, 0), Float4(0, c, s, 0), Float4(0, -s, c, 0), Float4(0, 0, 0, 1))
    }

    public static func rotationY(_ r: Float) -> float4x4 {
        let c = cos(r), s = sin(r)
        return float4x4(Float4(c, 0, -s, 0), Float4(0, 1, 0, 0), Float4(s, 0, c, 0), Float4(0, 0, 0, 1))
    }

    public static func rotationZ(_ r: Float) -> float4x4 {
        let c = cos(r), s = sin(r)
        return float4x4(Float4(c, s, 0, 0), Float4(-s, c, 0, 0), Float4(0, 0, 1, 0), Float4(0, 0, 0, 1))
    }

    public static func rotation(_ q: simd_quatf) -> float4x4 { float4x4(q) }

    /// Compose translation · rotation · scale.
    public static func trs(_ t: Float3, _ r: simd_quatf, _ s: Float3) -> float4x4 {
        var m = float4x4(r)
        m.columns.0 *= s.x
        m.columns.1 *= s.y
        m.columns.2 *= s.z
        m.columns.3 = Float4(t.x, t.y, t.z, 1)
        return m
    }

    /// Inverse-transpose of the upper-left 3×3, returned as a 4×4 for alignment.
    public static func normalMatrix(from m: float4x4) -> float4x4 {
        let n = m.upperLeft3x3.inverse.transpose
        return float4x4(Float4(n.columns.0, 0), Float4(n.columns.1, 0), Float4(n.columns.2, 0), Float4(0, 0, 0, 1))
    }

    public static func normalMatrix3(from m: float4x4) -> float3x3 {
        m.upperLeft3x3.inverse.transpose
    }
}

public extension float4x4 {
    var upperLeft3x3: float3x3 {
        float3x3(Float3(columns.0.x, columns.0.y, columns.0.z),
                 Float3(columns.1.x, columns.1.y, columns.1.z),
                 Float3(columns.2.x, columns.2.y, columns.2.z))
    }
    var translation: Float3 {
        get { Float3(columns.3.x, columns.3.y, columns.3.z) }
        set { columns.3 = Float4(newValue.x, newValue.y, newValue.z, columns.3.w) }
    }
    var scaleFactors: Float3 {
        Float3(length(Float3(columns.0.x, columns.0.y, columns.0.z)),
               length(Float3(columns.1.x, columns.1.y, columns.1.z)),
               length(Float3(columns.2.x, columns.2.y, columns.2.z)))
    }
    /// Rotation with scale removed. Assumes no shear and no reflection: unsigned
    /// column lengths turn a reflected basis into a nonunit quaternion. Use
    /// `checkedRotationQuaternion` or `checkedTRS` for imported or decoded input.
    var rotationQuaternion: simd_quatf {
        let s = scaleFactors
        var m = upperLeft3x3
        m.columns.0 /= max(s.x, 1e-8)
        m.columns.1 /= max(s.y, 1e-8)
        m.columns.2 /= max(s.z, 1e-8)
        return simd_quatf(m)
    }

    /// Checked `inverse`: throws for nonfinite input and for a zero
    /// determinant or nonfinite inverse; otherwise returns exactly `inverse`.
    func checkedInverse(_ name: String = "matrix") throws -> float4x4 {
        guard entriesAreFinite else { throw MathContractError.nonfinite(name) }
        let determinant = simd_determinant(self)
        guard determinant.isFinite, determinant != 0 else { throw MathContractError.singularMatrix(name) }
        let result = inverse
        guard result.entriesAreFinite else { throw MathContractError.singularMatrix(name) }
        return result
    }

    /// Checked `rotationQuaternion`: throws for nonfinite, singular, reflected,
    /// sheared or nonaffine input, none of which a unit quaternion with
    /// unsigned scale represents; otherwise returns exactly `rotationQuaternion`.
    /// `tolerance` bounds the bottom-row error and the cosine between
    /// normalized basis columns.
    func checkedRotationQuaternion(_ name: String = "matrix", tolerance: Float = 1e-4) throws -> simd_quatf {
        let reflects = try checkedRotationScaleBasis(name, tolerance: tolerance)
        guard !reflects else { throw MathContractError.reflectedMatrix(name) }
        return rotationQuaternion
    }

    /// Checked translation · rotation · scale decomposition such that
    /// `Transform.trs` rebuilds the matrix. A reflection is kept as a negative X
    /// scale instead of being lost to unsigned column lengths; shear, nonaffine,
    /// singular and nonfinite input throws. Input without a reflection returns
    /// exactly (`translation`, `rotationQuaternion`, `scaleFactors`).
    func checkedTRS(_ name: String = "matrix", tolerance: Float = 1e-4) throws
        -> (translation: Float3, rotation: simd_quatf, scale: Float3) {
        let reflects = try checkedRotationScaleBasis(name, tolerance: tolerance)
        guard reflects else { return (translation, rotationQuaternion, scaleFactors) }
        // M = R * diag(s) with det(R) = -1 equals R' * diag(-s.x, s.y, s.z),
        // where R' (R with its X column negated) is a proper rotation.
        var proper = self
        proper.columns.0 = -proper.columns.0
        let s = scaleFactors
        return (translation, proper.rotationQuaternion, Float3(-s.x, s.y, s.z))
    }

    /// Validates the matrix for the checked rotation/TRS decompositions and
    /// returns whether its basis reflects. Column lengths are the unsigned
    /// scale; the normalized columns must be independent and mutually
    /// orthogonal within `tolerance`, and the bottom row must be (0, 0, 0, 1).
    private func checkedRotationScaleBasis(_ name: String, tolerance: Float) throws -> Bool {
        guard entriesAreFinite else { throw MathContractError.nonfinite(name) }
        guard abs(columns.0.w) <= tolerance, abs(columns.1.w) <= tolerance, abs(columns.2.w) <= tolerance,
              abs(columns.3.w - 1) <= tolerance else { throw MathContractError.unsupportedMatrix(name) }
        let s = scaleFactors
        guard s.x.isFinite, s.y.isFinite, s.z.isFinite else { throw MathContractError.nonfinite(name) }
        // `rotationQuaternion` clamps lengths at 1e-8; such a column has no direction.
        guard s.x > 1e-8, s.y > 1e-8, s.z > 1e-8 else { throw MathContractError.singularMatrix(name) }
        let m = upperLeft3x3
        let x = m.columns.0 / s.x, y = m.columns.1 / s.y, z = m.columns.2 / s.z
        let handedness = dot(cross(x, y), z)
        guard abs(handedness) > tolerance else { throw MathContractError.singularMatrix(name) }
        guard abs(dot(x, y)) <= tolerance, abs(dot(x, z)) <= tolerance, abs(dot(y, z)) <= tolerance else {
            throw MathContractError.unsupportedMatrix(name)
        }
        return handedness < 0
    }

    private var entriesAreFinite: Bool {
        (0..<4).allSatisfy { column in (0..<4).allSatisfy { self[column][$0].isFinite } }
    }
    func transformPoint(_ p: Float3) -> Float3 {
        let v = self * Float4(p.x, p.y, p.z, 1)
        return Float3(v.x, v.y, v.z) / v.w
    }
    func transformDirection(_ d: Float3) -> Float3 {
        let v = self * Float4(d.x, d.y, d.z, 0)
        return Float3(v.x, v.y, v.z)
    }
    init(columns c0: Float4, _ c1: Float4, _ c2: Float4, _ c3: Float4) {
        self.init(c0, c1, c2, c3)
    }
}

public extension Float {
    var degreesToRadians: Float { self * .pi / 180 }
    var radiansToDegrees: Float { self * 180 / .pi }
}

@inlinable public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
@inlinable public func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inlinable public func lerp(_ a: Float3, _ b: Float3, _ t: Float) -> Float3 { a + (b - a) * t }
@inlinable public func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clamp((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}
