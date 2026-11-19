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
    /// A finite scalar is outside the helper's domain, such as a nonpositive
    /// near plane or a field of view outside (0, π).
    case outOfRange(String)

    public var description: String {
        switch self {
        case .nonfinite(let name): return "\(name) is not finite."
        case .degenerateDirection(let name): return "\(name) has zero or near-zero length and no direction."
        case .singularMatrix(let name): return "\(name) is singular."
        case .reflectedMatrix(let name): return "\(name) contains a reflection."
        case .unsupportedMatrix(let name): return "\(name) is sheared or not affine, so rotation and scale cannot represent it."
        case .outOfRange(let name): return "\(name) is outside its valid range."
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

    /// A basis whose |determinant| is at most this is singular for the
    /// normal matrix and the world-to-object inverse (#404), the same bound
    /// `RigDefinition.evaluate` uses for a mesh world. A finite zero or
    /// near-zero scale (an extended face slider) reaches it.
    public static let singularDeterminant: Float = 1e-12

    /// Inverse-transpose of the upper-left 3×3, returned as a 4×4 for alignment.
    /// See `normalMatrix3(from:)` for a singular basis.
    public static func normalMatrix(from m: float4x4) -> float4x4 {
        let n = normalMatrix3(from: m)
        return float4x4(Float4(n.columns.0, 0), Float4(n.columns.1, 0), Float4(n.columns.2, 0), Float4(0, 0, 0, 1))
    }

    /// Inverse-transpose of the upper-left 3×3: exactly `inverse.transpose`
    /// when |det| is above `singularDeterminant`. A singular basis has no
    /// inverse, so it gets the direction the inverse-transpose tends to
    /// instead: the cofactor matrix times the determinant's sign (as
    /// Deform.metal skins normals), scaled to a largest entry of 1, and the
    /// identity when fewer than two columns are independent (#404). A
    /// collapsed surface's normals point along the plane normal it keeps.
    /// A normal the cofactor maps to zero is left to the caller (#407).
    public static func normalMatrix3(from m: float4x4) -> float3x3 {
        let basis = m.upperLeft3x3
        guard abs(simd_determinant(basis)) <= singularDeterminant else { return basis.inverse.transpose }
        return singularNormalMatrix(basis)
    }

    private static func singularNormalMatrix(_ basis: float3x3) -> float3x3 {
        let identity = matrix_identity_float3x3
        let scale = largestMagnitude(basis)
        guard scale > 0, scale.isFinite else { return identity }
        let a = basis * (1 / scale)
        let cofactors = float3x3(simd_cross(a.columns.1, a.columns.2), simd_cross(a.columns.2, a.columns.0),
                                 simd_cross(a.columns.0, a.columns.1))
        let largest = largestMagnitude(cofactors)
        guard largest >= Float.leastNormalMagnitude, largest.isFinite else { return identity }
        let sign: Float = simd_dot(a.columns.0, cofactors.columns.0) < 0 ? -1 : 1
        return cofactors * (sign / largest)
    }

    private static func largestMagnitude(_ m: float3x3) -> Float {
        simd_reduce_max(simd_max(simd_max(simd_abs(m.columns.0), simd_abs(m.columns.1)), simd_abs(m.columns.2)))
    }

    /// Unity's Vector3f InverseSafe bound: an axis whose scale magnitude is
    /// at most this inverts to 0 instead of dividing (#404).
    public static let inverseSafeEpsilon: Float = 1e-5

    /// `m.inverse` when the upper-left 3×3's |det| is above
    /// `singularDeterminant`, bit for bit. A singular affine `m` has no
    /// inverse; it gets the InverseSafe form instead (#404; Unity's
    /// Vector3f InverseSafe gives 0 where |s| is at most 1e-5): each basis
    /// column `c` longer than `inverseSafeEpsilon` becomes the row `c / |c|²`
    /// and a shorter one the zero row, so a collapsed axis maps to 0. For a
    /// basis without shear (rotation times scale, a reflection included)
    /// that is the exact inverse on the axes that remain. The translation
    /// column is -B⁺·t. No length at or below the bound is divided by.
    public static func inverseSafe(_ m: float4x4) -> float4x4 {
        let basis = m.upperLeft3x3
        guard abs(simd_determinant(basis)) <= singularDeterminant else { return m.inverse }
        func row(_ c: Float3) -> Float3 {
            let squared = simd_length_squared(c)
            return squared > inverseSafeEpsilon * inverseSafeEpsilon && squared.isFinite ? c / squared : .zero
        }
        // Rows of B⁺ are the scaled columns of B, so B⁺ is the transpose of
        // the matrix whose columns are those rows.
        let rows = float3x3(row(basis.columns.0), row(basis.columns.1), row(basis.columns.2))
        let inverse = rows.transpose
        let t = -(inverse * m.translation)
        return float4x4(Float4(inverse.columns.0, 0), Float4(inverse.columns.1, 0), Float4(inverse.columns.2, 0), Float4(t, 1))
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

    /// `rotationQuaternion`, bit for bit, when the basis's |det| is above
    /// `Transform.singularDeterminant`. A collapsed basis (a zero shape
    /// scale, #404) has columns with no direction, and a Transform's
    /// rotation does not depend on its scale, so the directions are rebuilt
    /// first: the columns are orthonormalized in order, a column shorter than
    /// `Transform.inverseSafeEpsilon` after that is dropped, one dropped
    /// column becomes the cross product of the other two, two become a
    /// right-handed frame around the one left, and three give the identity.
    /// The result is always a unit rotation; like `rotationQuaternion`, it
    /// carries no reflection.
    var collapseSafeRotationQuaternion: simd_quatf {
        let basis = upperLeft3x3
        guard abs(simd_determinant(basis)) <= Transform.singularDeterminant else { return rotationQuaternion }
        var frame = matrix_identity_float3x3
        var alive = [false, false, false]
        for i in 0..<3 {
            var v = basis[i]
            for j in 0..<i where alive[j] { v -= simd_dot(v, frame[j]) * frame[j] }
            let size = simd_length(v)
            guard size > Transform.inverseSafeEpsilon, size.isFinite else { continue }
            frame[i] = v / size; alive[i] = true
        }
        let living = (0..<3).filter { alive[$0] }
        switch living.count {
        case 3:
            if simd_dot(simd_cross(frame[0], frame[1]), frame[2]) < 0 { frame[2] = -frame[2] }
        case 2:
            let k = (0..<3).first { !alive[$0] }!
            frame[k] = simd_cross(frame[(k + 1) % 3], frame[(k + 2) % 3])
        case 1:
            let i = living[0], j = (i + 1) % 3, k = (i + 2) % 3
            let axis = frame[i], magnitude = simd_abs(axis)
            let helper: Float3 = magnitude.x <= magnitude.y && magnitude.x <= magnitude.z ? Float3(1, 0, 0)
                : (magnitude.y <= magnitude.z ? Float3(0, 1, 0) : Float3(0, 0, 1))
            frame[j] = simd_normalize(simd_cross(helper, axis))
            frame[k] = simd_cross(axis, frame[j])
        default:
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_quatf(frame).normalized
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

    /// Whether all 16 entries are finite; shared by the checked CoreMath forms.
    internal var entriesAreFinite: Bool {
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
