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
    #expect(MemoryLayout<FrameUniforms>.stride == 560)
}

@Test func drawUniformsStride() {
    #expect(MemoryLayout<DrawUniforms>.stride == 144)
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

// MARK: - Checked contracts (R4): accepted input returns exactly the unchecked result.

@Test func checkedNormalizedMatchesNormalizeAndRejectsDegenerateVectors() throws {
    for vector in [Float3(3, -4, 12), Float3(1e-5, 0, 0), Float3(-2e6, 1, 0.5)] {
        #expect(try vector.checkedNormalized() == normalize(vector))
    }
    #expect(throws: MathContractError.degenerateDirection("v")) { try Float3.zero.checkedNormalized("v") }
    #expect(throws: MathContractError.degenerateDirection("v")) { try Float3(1e-7, 0, -1e-7).checkedNormalized("v") }
    #expect(throws: MathContractError.nonfinite("v")) { try Float3(.nan, 0, 1).checkedNormalized("v") }
    #expect(throws: MathContractError.nonfinite("v")) { try Float3(0, -.infinity, 1).checkedNormalized("v") }
    // Finite components whose squared length overflows are not normalizable either.
    #expect(throws: MathContractError.nonfinite("v")) { try Float3(3e38, 3e38, 0).checkedNormalized("v") }
}

@Test func checkedRotationMatchesShortestArcAndRejectsDegenerateDirections() throws {
    let pairs: [(Float3, Float3)] = [(Float3(0, 0, 1), Float3(0.3, -0.4, 2)), (Float3(1, 0, 0), Float3(-3, 0, 0)),
                                     (Float3(0, 2, 0), Float3(0, 5, 0)), (Float3(2, -1, 0.5), Float3(-0.2, 0.7, 4))]
    for (from, to) in pairs {
        let checked = try simd_quatf.checkedRotation(from: from, to: to)
        #expect(checked.vector == simd_quatf.rotation(from: from, to: to).vector)
        #expect(simd_length(checked.act(normalize(from)) - normalize(to)) < 1e-5)
    }
    #expect(throws: MathContractError.degenerateDirection("rotation from")) {
        try simd_quatf.checkedRotation(from: .zero, to: Float3(0, 0, 1))
    }
    #expect(throws: MathContractError.degenerateDirection("rotation to")) {
        try simd_quatf.checkedRotation(from: Float3(0, 0, 1), to: Float3(0, 1e-8, 0))
    }
    #expect(throws: MathContractError.nonfinite("rotation to")) {
        try simd_quatf.checkedRotation(from: Float3(0, 0, 1), to: Float3(.nan, 0, 0))
    }
}

@Test func checkedLookRotationMatchesLookRotationAndRejectsDegenerateBases() throws {
    // The last pair exercises the parallel-up fallback, which is still defined here.
    let cases: [(Float3, Float3)] = [(Float3(0, 0, 1), Float3(0, 1, 0)), (Float3(1, 2, -3), Float3(0.2, 1, 0)),
                                     (Float3(0, 1, 0), Float3(0, 3, 0))]
    for (forward, up) in cases {
        let checked = try simd_quatf.checkedLookRotation(forward: forward, up: up)
        #expect(checked.vector == simd_quatf.lookRotation(forward: forward, up: up).vector)
        #expect(simd_length(checked.forward - normalize(forward)) < 1e-5)
    }
    #expect(throws: MathContractError.degenerateDirection("look forward")) { try simd_quatf.checkedLookRotation(forward: .zero) }
    #expect(throws: MathContractError.degenerateDirection("look up")) {
        try simd_quatf.checkedLookRotation(forward: Float3(0, 0, 1), up: .zero)
    }
    #expect(throws: MathContractError.nonfinite("look forward")) {
        try simd_quatf.checkedLookRotation(forward: Float3(0, .infinity, 1))
    }
    // An up parallel to forward falls back to +X, which has no perpendicular when forward is along X too.
    #expect(throws: MathContractError.degenerateDirection("look basis")) {
        try simd_quatf.checkedLookRotation(forward: Float3(-1, 0, 0), up: Float3(2, 0, 0))
    }
}

@Test func checkedInverseMatchesInverseAndRejectsSingularMatrices() throws {
    let matrix = Transform.trs(Float3(1, -2, 3), simd_quatf(angle: 0.7, axis: normalize(Float3(1, 2, 3))), Float3(2, -0.5, 3))
    #expect(try matrix.checkedInverse() == matrix.inverse)
    #expect(throws: MathContractError.singularMatrix("scale")) { try Transform.scale(Float3(1, 0, 1)).checkedInverse("scale") }
    var nonfinite = matrix
    nonfinite.columns.2.y = .nan
    #expect(throws: MathContractError.nonfinite("matrix")) { try nonfinite.checkedInverse() }
}

@Test func checkedDecompositionKeepsReflectionsAndRejectsShear() throws {
    let rotation = simd_quatf(angle: 0.9, axis: normalize(Float3(-1, 2, 0.5)))
    let translation = Float3(0.5, 1, -2), scale = Float3(2, 0.5, 3)
    let rigid = Transform.trs(translation, rotation, scale)
    let trs = try rigid.checkedTRS()
    #expect(trs.translation == rigid.translation && trs.scale == rigid.scaleFactors)
    #expect(trs.rotation.vector == rigid.rotationQuaternion.vector)
    #expect(try rigid.checkedRotationQuaternion().vector == rigid.rotationQuaternion.vector)

    // A reflection survives as a negative X scale and `Transform.trs` rebuilds the matrix.
    for signs in [Float3(-1, 1, 1), Float3(1, -1, 1), Float3(1, 1, -1), Float3(-1, -1, -1)] {
        let reflected = Transform.trs(translation, rotation, scale * signs)
        let decomposed = try reflected.checkedTRS()
        #expect(decomposed.scale.x < 0 && decomposed.scale.y > 0 && decomposed.scale.z > 0)
        #expect(abs(simd_length(decomposed.rotation.vector) - 1) < 1e-5)
        let rebuilt = Transform.trs(decomposed.translation, decomposed.rotation, decomposed.scale)
        for column in 0..<4 { #expect(simd_length(rebuilt[column] - reflected[column]) < 1e-5) }
        #expect(throws: MathContractError.reflectedMatrix("matrix")) { try reflected.checkedRotationQuaternion() }
    }

    var shear = matrix_identity_float4x4
    shear[1].x = 0.25
    #expect(throws: MathContractError.unsupportedMatrix("matrix")) { try (rigid * shear).checkedTRS() }
    #expect(throws: MathContractError.unsupportedMatrix("matrix")) { try (rigid * shear).checkedRotationQuaternion() }
    var projective = rigid
    projective.columns.0.w = 0.5
    #expect(throws: MathContractError.unsupportedMatrix("matrix")) { try projective.checkedTRS() }
    #expect(throws: MathContractError.singularMatrix("root")) { try Transform.scale(Float3(1, 0, 1)).checkedTRS("root") }
    var dependent = matrix_identity_float4x4
    dependent.columns.1 = dependent.columns.0
    #expect(throws: MathContractError.singularMatrix("matrix")) { try dependent.checkedTRS() }
    var nonfinite = rigid
    nonfinite.columns.3.x = .infinity
    #expect(throws: MathContractError.nonfinite("matrix")) { try nonfinite.checkedTRS() }
}
