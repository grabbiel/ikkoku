//
//  Projection.swift
//  Engine
//
//  Created by rumpology on 8/19/26.
//
import Foundation
import simd

public enum Projection {
    /// Right-handed perspective with reverse-Z.
    /// View space: camera at origin looking down -Z.
    /// Clip space: Metal NDC, depth in [0,1] with near→1, far→0.
    public static func perspectiveReverseZ(
        fovyRadians: Float, aspect: Float, near: Float, far: Float
    ) -> matrix_float4x4 {
        let f = 1 / tan(fovyRadians * 0.5)
        let a = near / (far - near)
        let b = (near * far) / (far - near)
        return matrix_float4x4(
            SIMD4<Float>(f / aspect, 0, 0,  0),
            SIMD4<Float>(0,          f, 0,  0),
            SIMD4<Float>(0,          0, a, -1),
            SIMD4<Float>(0,          0, b,  0)
        )
    }

    /// Infinite far plane. Best depth precision — prefer this.
    public static func perspectiveReverseZInfinite(
        fovyRadians: Float, aspect: Float, near: Float
    ) -> matrix_float4x4 {
        let f = 1 / tan(fovyRadians * 0.5)
        return matrix_float4x4(
            SIMD4<Float>(f / aspect, 0, 0,    0),
            SIMD4<Float>(0,          f, 0,    0),
            SIMD4<Float>(0,          0, 0,   -1),
            SIMD4<Float>(0,          0, near, 0)
        )
    }

    public static func lookAt(
        eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>
    ) -> matrix_float4x4 {
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return matrix_float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        )
    }
}
