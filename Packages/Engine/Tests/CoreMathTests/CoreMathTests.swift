//
//  CoreMathTests.swift
//  Engine
//
//  Created by rumpology on 8/19/26.
//

import Testing
import CoreMath
import ShaderTypes
import simd

@Test func frameUniformsStride() {
    #expect(MemoryLayout<FrameUniforms>.stride == 160)
}

@Test func drawUniformsStride() {
    #expect(MemoryLayout<DrawUniforms>.stride == 112)
}

@Test func reverseZMapsNearToOneAndFarToZero() {
    let p = Projection.perspectiveReverseZ(
        fovyRadians: .pi / 3, aspect: 16.0 / 9.0, near: 0.1, far: 1000)

    let atNear = p * SIMD4<Float>(0, 0, -0.1, 1)
    let atFar  = p * SIMD4<Float>(0, 0, -1000, 1)

    #expect(abs(atNear.z / atNear.w - 1) < 1e-4)
    #expect(abs(atFar.z / atFar.w) < 1e-4)
}

@Test func infiniteReverseZMapsNearToOne() {
    let p = Projection.perspectiveReverseZInfinite(
        fovyRadians: .pi / 3, aspect: 1, near: 0.1)
    let atNear = p * SIMD4<Float>(0, 0, -0.1, 1)
    #expect(abs(atNear.z / atNear.w - 1) < 1e-4)

    let farAway = p * SIMD4<Float>(0, 0, -1e6, 1)
    #expect(farAway.z / farAway.w < 1e-5)
}
