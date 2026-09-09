import Foundation
import simd

public typealias Float3 = SIMD3<Float>
public typealias Float4 = SIMD4<Float>
public typealias Float2 = SIMD2<Float>

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
    /// Rotation with scale removed. Assumes no shear.
    var rotationQuaternion: simd_quatf {
        let s = scaleFactors
        var m = upperLeft3x3
        m.columns.0 /= max(s.x, 1e-8)
        m.columns.1 /= max(s.y, 1e-8)
        m.columns.2 /= max(s.z, 1e-8)
        return simd_quatf(m)
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
