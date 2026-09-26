import Foundation
import Testing
import simd
import CoreMath
import Assets
@testable import Scene

@Test func sourceRigLiveBoundsContainEveryDeformedVertexWithMorphsReflectionAndShear() throws {
    let rig = try RigDefinition(nodes: [
        .init(name: "mesh", sourceID: "mesh", parent: nil),
        .init(name: "left", sourceID: "left", parent: nil),
        .init(name: "right", sourceID: "right", parent: nil)], skins: [
            .init(name: "skin", meshNode: 0, joints: [1, 2], inverseBindMatrices: [matrix_identity_float4x4, matrix_identity_float4x4])])
    let points: [Float3] = (0..<120).map { i in Float3(Float(i % 9) / 4 - 1, Float(i % 13) / 6 - 1, Float(i % 7) / 3 - 1) }
    let mesh = MeshData(name: "fixture", positions: points, normals: points.map { _ in Float3(0, 1, 0) },
        joints: points.map { _ in SIMD4<UInt16>(0, 1, 0, 0) },
        weights: points.indices.map { let w = Float($0 % 11) / 10; return Float4(w, 1-w, 0, 0) }, indices: [0,1,2],
        morphTargets: [.init(name: "expand", positionDeltas: points.map { $0 * 0.3 + Float3(0, 0.4, -0.1) }, normalDeltas: points.map { _ in .zero })])
    let source = SourceRig(sourcePrefab: "fixture", rig: rig, parts: [.init(mesh: mesh, node: 0, skin: 0, rendererEnabled: true)], morphChannelCount: 1)
    var bounds = SourceRigBounds(source: source)
    for i in 0..<50 {
        var pose = rig.restPose
        var shear = matrix_identity_float4x4; shear[1].x = Float(i % 7) * 0.13
        pose.localMatrices[0] = Transform.trs(Float3(4, 2, -3), .identity, Float3(-1, 2, 0.5))
        pose.localMatrices[1] = Transform.trs(Float3(Float(i) * 0.1, 1, 2), simd_quatf(angle: Float(i)*0.17, axis: Float3(0,1,0)), Float3(1, 0.7, 1.3))
        pose.localMatrices[2] = shear * Transform.translation(Float3(-2, 0, -1))
        let active: [(index: Int, weight: Float)] = i.isMultiple(of: 3) ? [] : [(0, Float(i % 10) / 10)]
        let evaluation = try rig.evaluate(pose), fast = try bounds.bounds(evaluation: evaluation, morphWeights: ["fixture": active])
        for point in try source.deformedPositions(part: source.parts[0], evaluation: evaluation, morphWeights: active) {
            #expect((0..<3).allSatisfy { point[$0] >= fast.min[$0] && point[$0] <= fast.max[$0] })
        }
        #expect(try bounds.bounds(evaluation: evaluation, morphWeights: ["fixture": active]) == fast)
    }
}

@Test func sourceRigLiveBoundsRejectUnknownMorphsAndExcludeDisabledParts() throws {
    let rig = try RigDefinition(nodes: [.init(name: "root", sourceID: "root", parent: nil)], skins: [])
    let source = SourceRig(sourcePrefab: "empty", rig: rig, parts: [], morphChannelCount: 0)
    var bounds = SourceRigBounds(source: source)
    #expect(try bounds.bounds(evaluation: rig.evaluate(rig.restPose)).isEmpty)
    #expect(throws: RigError.self) { try bounds.bounds(evaluation: rig.evaluate(rig.restPose), morphWeights: ["missing": []]) }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SOURCE_AVATAR"]),
               "Requires IKKOKU_SOURCE_AVATAR"))
func sourceRigLiveBoundsContainConvertedSourceAvatarAcrossPoseChanges() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR")
    let source = try SourceRig.loadModel(url: URL(fileURLWithPath: path)); var bounds = SourceRigBounds(source: source)
    for i in 0..<6 {
        var pose = source.rig.restPose
        for name in ["cf_j_arm00_L", "cf_j_arm00_R"] {
            let node = try source.rig.uniqueNode(named: name)
            pose.localMatrices[node] *= Transform.rotation(simd_quatf(angle: Float(i)*0.1, axis: Float3(0, 0, 1)))
        }
        let evaluation = try source.rig.evaluate(pose), fast = try bounds.bounds(evaluation: evaluation), exact = try source.bounds(evaluation: evaluation)
        #expect((0..<3).allSatisfy { fast.min[$0] <= exact.min[$0] && fast.max[$0] >= exact.max[$0] })
    }
}
