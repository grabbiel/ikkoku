import Foundation
import simd

public enum Projection {
    /// Right-handed, reverse-Z, Metal NDC depth [0,1] with near→1, far→0.
    public static func perspectiveReverseZ(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let f = 1 / tan(fovyRadians * 0.5)
        let a = near / (far - near)
        let b = (near * far) / (far - near)
        return float4x4(Float4(f / aspect, 0, 0, 0), Float4(0, f, 0, 0), Float4(0, 0, a, -1), Float4(0, 0, b, 0))
    }

    /// Infinite far plane; best depth precision.
    public static func perspectiveReverseZInfinite(fovyRadians: Float, aspect: Float, near: Float) -> float4x4 {
        let f = 1 / tan(fovyRadians * 0.5)
        return float4x4(Float4(f / aspect, 0, 0, 0), Float4(0, f, 0, 0), Float4(0, 0, 0, -1), Float4(0, 0, near, 0))
    }

    /// Orthographic reverse-Z (near→1, far→0), right-handed looking down -Z.
    public static func orthographicReverseZ(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> float4x4 {
        let sx = 2 / (right - left)
        let sy = 2 / (top - bottom)
        let sz = 1 / (far - near)
        let tx = -(right + left) / (right - left)
        let ty = -(top + bottom) / (top - bottom)
        // z_ndc = (z_view + far) / (far - near)  →  view z = -near → 1, -far → 0
        return float4x4(Float4(sx, 0, 0, 0), Float4(0, sy, 0, 0), Float4(0, 0, sz, 0), Float4(tx, ty, far * sz, 1))
    }

    public static func lookAt(eye: Float3, center: Float3, up: Float3) -> float4x4 {
        let z = normalize(eye - center)
        var upv = up
        if abs(dot(normalize(upv), z)) > 0.999 { upv = Float3(0, 0, 1) }
        let x = normalize(cross(upv, z))
        let y = cross(z, x)
        return float4x4(Float4(x.x, y.x, z.x, 0), Float4(x.y, y.y, z.y, 0), Float4(x.z, y.z, z.z, 0),
                        Float4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1))
    }
}
