//
//  CoreMathTests.swift
//  Engine
//
//  Created by rumpology on 8/19/26.
//

import Testing
import CoreMath
import ShaderTypes

@Test func frameUniformsStride() {
    #expect(MemoryLayout<FrameUniforms>.stride == 160)
}

@Test func drawUniformsStride() {
    #expect(MemoryLayout<DrawUniforms>.stride == 112)
}
