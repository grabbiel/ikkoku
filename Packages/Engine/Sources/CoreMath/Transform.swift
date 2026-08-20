//
//  Transform.swift
//  Engine
//
//  Created by rumpology on 8/20/26.
//
import Foundation
import simd

public enum Transform {
    public static let identity = matrix_identity_float4x4

    public static func translation(_ t: SIMD3<Float>) -> matrix_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    public static func scale(_ s: SIMD3<Float>) -> matrix_float4x4 {
        matrix_float4x4(diagonal: SIMD4<Float>(s.x, s.y, s.z, 1))
    }

    public static func rotationY(_ radians: Float) -> matrix_float4x4 {
        let c = cos(radians), s = sin(radians)
        return matrix_float4x4(
            SIMD4<Float>( c, 0, -s, 0),
            SIMD4<Float>( 0, 1,  0, 0),
            SIMD4<Float>( s, 0,  c, 0),
            SIMD4<Float>( 0, 0,  0, 1)
        )
    }

    /// Inverse-transpose of the upper-left 3×3. Required once non-uniform
    /// scale enters the picture — which it will, with bone-scale body sliders.
    public static func normalMatrix(from m: matrix_float4x4) -> matrix_float3x3 {
        let upper = matrix_float3x3(
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        return upper.inverse.transpose
    }
}
