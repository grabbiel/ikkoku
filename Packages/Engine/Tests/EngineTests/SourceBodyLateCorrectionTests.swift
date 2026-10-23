import Foundation
import Testing
import Metal
import simd
import Assets
import CoreMath
import Character
@testable import Scene
import Renderer

private func correctionRig() throws -> SourceRig {
    let rig = try RigDefinition(nodes: [
        .init(name: "mesh", sourceID: "mesh", parent: nil),
        .init(name: "cf_j_forearm01_L", sourceID: "arm", parent: nil, translation: Float3(1, 0, 0), scale: Float3(repeating: 2)),
        .init(name: "cf_j_hand_L", sourceID: "hand", parent: 1, translation: Float3(1, 0, 0), scale: Float3(repeating: 3))], skins: [
            .init(name: "skin", meshNode: 0, joints: [2], inverseBindMatrices: [matrix_identity_float4x4])])
    let mesh = MeshData(name: "hand", positions: [Float3(0, 1, 1), Float3(1, 0, 0), .zero],
        normals: [Float3](repeating: Float3(0, 0, 1), count: 3), joints: [SIMD4<UInt16>](repeating: .zero, count: 3),
        weights: [Float4](repeating: Float4(1, 0, 0, 0), count: 3), indices: [0, 1, 2])
    return SourceRig(sourcePrefab: "late-correction", rig: rig,
        parts: [.init(mesh: mesh, node: 0, skin: 0, rendererEnabled: true)], morphChannelCount: 0)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceBodyLateCorrectionPreviewAndCPUUseOriginalFlags() throws {
    let source = try correctionRig(), resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    for arm in [false, true] { for hand in [false, true] {
        let options = SourceBodyLateCorrection.Options(enableCorrectArmSize: arm, enableCorrectHandSize: hand)
        let preview = try SourceRigPreview(source: source, contract: nil, resources: resources, lateCorrectionOptions: options)
        let pose = try preview.pose(), evaluation = try source.rig.evaluate(pose)
        let positions = try source.deformedPositions(part: source.parts[0], evaluation: evaluation)
        // Absolute late setters replace incoming scales 2 and 3; they do not multiply them.
        let armScale: Float = arm ? 0.92 : 1, handScale: Float = hand ? 0.9 : 1
        #expect(length(positions[0] - Float3(1 + armScale, handScale, handScale)) < 1e-6)
        #expect(length(positions[1] - Float3(1 + 2 * armScale, 0, 0)) < 1e-6)
        #expect(pose.localMatrices[0] == source.rig.restPose.localMatrices[0])
        #expect(preview.lateCorrectionOptions == options)
    } }
}

@Test func sourceBodyLateCorrectionSkipsMaleAndLowDetailAndRejectsAmbiguity() throws {
    let source = try correctionRig()
    for (sex, hiPoly) in [(SourceBodyShapePose.Sex.male, true), (.female, false)] {
        let correction = try SourceBodyLateCorrection(rig: source.rig, sex: sex, options: .init(hiPoly: hiPoly))
        var pose = source.rig.restPose
        try correction.apply(to: &pose)
        #expect(pose.localMatrices == source.rig.restPose.localMatrices)
    }
    let ambiguous = try RigDefinition(nodes: [
        .init(name: "cf_j_hand_L", sourceID: "first", parent: nil),
        .init(name: "cf_j_hand_L", sourceID: "second", parent: nil)], skins: [])
    #expect(throws: RigError.self) { try SourceBodyLateCorrection(rig: ambiguous, sex: .female, options: .init()) }
    let correction = try SourceBodyLateCorrection(rig: source.rig, sex: .female, options: .init())
    var invalid = ambiguous.restPose
    #expect(throws: RigError.self) { try correction.apply(to: &invalid) }
    // Head-only/reduced rigs legitimately omit hand and arm destinations.
    let head = try RigDefinition(nodes: [.init(name: "head", sourceID: "head", parent: nil)], skins: [])
    var headPose = head.restPose
    try SourceBodyLateCorrection(rig: head, sex: .female, options: .init()).apply(to: &headPose)
    #expect(headPose.localMatrices == head.restPose.localMatrices)
}

@Test func sourceBodyLateCorrectionRestoresAfterAnimatedScaleWithoutRepeatingModifiers() throws {
    let source = try correctionRig()
    let correction = try SourceBodyLateCorrection(rig: source.rig, sex: .female, options: .init())
    var baseline = source.rig.restPose
    try correction.apply(to: &baseline)
    // Supported static modifier already multiplied the corrected hand scale by 1.2.
    baseline.localMatrices[2] = baseline.localMatrices[2] * Transform.scale(Float3(repeating: 1.2))
    let finalCorrection = try correction.capturingScales(from: baseline)
    let animatedRotation = simd_quatf(angle: 0.3, axis: Float3(0, 0, 1))
    var animated = baseline
    animated.localMatrices[2] = Transform.trs(Float3(3, 2, 1), animatedRotation, Float3(repeating: 9))
    try finalCorrection.apply(to: &animated)
    let expected = Transform.trs(Float3(3, 2, 1), animatedRotation, Float3(1.2, 1.08, 1.08))
    for c in 0..<4 { #expect(simd_length(animated.localMatrices[2][c] - expected[c]) < 1e-6) }
    try finalCorrection.apply(to: &animated) // No cumulative 1.2 multiplication.
    for c in 0..<4 { #expect(simd_length(animated.localMatrices[2][c] - expected[c]) < 1e-6) }
}
