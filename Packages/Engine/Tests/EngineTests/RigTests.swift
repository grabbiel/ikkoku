import Testing
import Foundation
import simd
import CoreMath
@testable import Scene

private func expectMatrix(_ actual: float4x4, _ expected: float4x4, tolerance: Float = 1e-5) {
    for column in 0..<4 { #expect(simd_length(actual[column] - expected[column]) < tolerance) }
}

@Test func fullRigPreservesSupportTransformsAndPerRendererBinds() throws {
    var shear = matrix_identity_float4x4
    shear[1].x = 0.25
    let root = Transform.trs(Float3(0, 2, 0), simd_quatf(angle: 0.5, axis: Float3(0, 1, 0)), Float3(-1, 2, 1))
    let jointWorld = root * shear * Transform.translation(Float3(0, 1, 0))
    let meshWorldA = root * Transform.translation(Float3(3, 0, 0))
    let meshWorldB = root * Transform.translation(Float3(-2, 0, 0))
    let nodes: [RigDefinition.Node] = [
        .init(name: "root", sourceID: "a", parent: nil, authoredMatrix: root),
        .init(name: "support", sourceID: "b", parent: 0, authoredMatrix: shear),
        .init(name: "joint", sourceID: "c", parent: 1, translation: Float3(0, 1, 0)),
        .init(name: "mesh", sourceID: "d", parent: 0, translation: Float3(3, 0, 0)),
        .init(name: "mesh", sourceID: "e", parent: 0, translation: Float3(-2, 0, 0))]
    let rig = try RigDefinition(nodes: nodes, skins: [
        .init(name: "A", meshNode: 3, joints: [2], inverseBindMatrices: [simd_inverse(jointWorld) * meshWorldA]),
        .init(name: "B", meshNode: 4, joints: [2], inverseBindMatrices: [simd_inverse(jointWorld) * meshWorldB])])
    let rest = try rig.evaluate(rig.restPose)
    expectMatrix(rest.worldMatrices[2], jointWorld)
    expectMatrix(rest.palettes[0][0], matrix_identity_float4x4)
    expectMatrix(rest.palettes[1][0], matrix_identity_float4x4)
    #expect(rig.nodes(named: "mesh") == [3, 4])
    #expect(throws: RigError.self) { try rig.uniqueNode(named: "mesh") }
    var pose = rig.restPose
    pose.localMatrices[1] = shear * Transform.scale(Float3(1, 1.5, 1))
    let posed = try rig.evaluate(pose)
    let expectedJoint = root * pose.localMatrices[1] * nodes[2].localMatrix
    for index in 0..<2 {
        expectMatrix(posed.worldMatrices[rig.skins[index].meshNode] * posed.palettes[index][0], expectedJoint * rig.skins[index].inverseBindMatrices[0])
    }
}

@Test func fullRigRejectsInvalidHierarchyBindsAndSingularMeshPose() throws {
    #expect(throws: RigError.self) { try RigDefinition(nodes: [.init(name: "a", sourceID: "a", parent: 1), .init(name: "b", sourceID: "b", parent: 0)], skins: []) }
    #expect(throws: RigError.self) { try RigDefinition(nodes: [.init(name: "a", sourceID: "a", parent: nil), .init(name: "b", sourceID: "a", parent: nil)], skins: []) }
    let nodes: [RigDefinition.Node] = [.init(name: "mesh", sourceID: "a", parent: nil), .init(name: "joint", sourceID: "b", parent: nil)]
    #expect(throws: RigError.self) { try RigDefinition(nodes: nodes, skins: [.init(name: "bad", meshNode: 0, joints: [1], inverseBindMatrices: [])]) }
    let rig = try RigDefinition(nodes: nodes, skins: [.init(name: "valid", meshNode: 0, joints: [1], inverseBindMatrices: [matrix_identity_float4x4])])
    var pose = rig.restPose
    pose.localMatrices[0] = Transform.scale(Float3(1, 0, 1))
    #expect(throws: RigError.self) { try rig.evaluate(pose) }
}

private func sourceRigFixture() -> [String: Any] {
    ["schemaVersion": 1, "coordinateSpace": "unity-left-handed-y-up", "matrixLayout": "column-major", "uvConvention": "unity-source", "sourcePrefab": "synthetic",
     "nodes": [["name": "mesh", "sourceID": "0", "translation": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]],
               ["name": "joint", "sourceID": "1", "translation": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]]],
     "skins": [["name": "skin", "meshNode": 0, "joints": [1], "inverseBindMatrices": [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]]]],
     "meshes": [["name": "triangle", "node": 0, "skin": 0, "positions": [[0, 0, 1], [1, 0, 1], [0, 1, 1]],
                 "normals": Array(repeating: [0, 0, 1], count: 3), "tangents": Array(repeating: [1, 0, 0, 1], count: 3),
                 "uv0": [[0, 0], [1, 0], [0, 1]], "joints": Array(repeating: [0, 0, 0, 0], count: 3),
                 "weights": Array(repeating: [1, 0, 0, 0], count: 3), "submeshes": [["indices": [0, 1, 2]]], "morphChannels": [], "initialMorphWeights": [], "rendererEnabled": true]]]
}

@Test func sourceRigConvertsSkinSpaceGeometryAndWindingExactlyOnce() throws {
    let rig = try SourceRig.decode(JSONSerialization.data(withJSONObject: sourceRigFixture()))
    let part = try #require(rig.parts.first)
    #expect(part.mesh.positions[0] == Float3(0, 0, -1))
    #expect(part.mesh.indices == [0, 2, 1])
    #expect(part.mesh.uvs[0] == Float2(0, 1))
    #expect(part.mesh.tangents[0] == Float4(1, 0, 0, 1))
    var pose = rig.rig.restPose
    pose.localMatrices[1] = Transform.translation(Float3(0, 0, -2))
    let evaluation = try rig.rig.evaluate(pose)
    let deformed = try rig.deformedPositions(part: part, evaluation: evaluation)
    #expect(deformed[0] == Float3(0, 0, -3))
}

@Test func sourceRigRejectsZeroWeightOutOfRangeJointAndNonzeroUnportedMorph() throws {
    for field in ["joints", "weights", "initialMorphWeights"] {
        var document = sourceRigFixture()
        var meshes = try #require(document["meshes"] as? [[String: Any]])
        if field == "joints" { meshes[0][field] = Array(repeating: [0, 5, 0, 0], count: 3) }
        if field == "weights" { meshes[0][field] = Array(repeating: [0, 0, 0, 0], count: 3) }
        if field == "initialMorphWeights" { meshes[0][field] = [25] }
        document["meshes"] = meshes
        #expect(throws: RigError.self) { try SourceRig.decode(JSONSerialization.data(withJSONObject: document)) }
    }
}

private func sourceMorphFixture() throws -> [String: Any] {
    var document = sourceRigFixture()
    var meshes = try #require(document["meshes"] as? [[String: Any]])
    meshes[0]["uv1"] = [[0.2, 0.3], [0.4, 0.5], [0.6, 0.7]]
    meshes[0]["uv2"] = [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]
    meshes[0]["morphChannels"] = [["name": "source.close", "frames": [["weight": 100,
        "indices": [1], "positionDeltas": [[1, 2, 3]], "normalDeltas": [], "tangentDeltas": []]]]]
    document["meshes"] = meshes
    return document
}

@Test func sourceMorphUsesSparseDeltasBeforeSkinningAndPreservesExtraUVs() throws {
    let source = try SourceRig.decode(JSONSerialization.data(withJSONObject: sourceMorphFixture()))
    let part = try #require(source.parts.first)
    #expect(part.mesh.morphTargets[0].positionDeltas == [.zero, Float3(1, 2, -3), .zero])
    #expect(part.mesh.morphTargets[0].normalDeltas == Array(repeating: .zero, count: 3))
    #expect(part.mesh.uvs1[0] == Float2(0.2, 0.7))
    #expect(part.mesh.uvs2[0] == Float2(0.1, 0.8))
    var pose = source.rig.restPose
    pose.localMatrices[1] = Transform.translation(Float3(3, 4, 5)) * Transform.scale(Float3(2, 3, 4))
    let evaluation = try source.rig.evaluate(pose)
    let result = try source.deformedPositions(part: part, evaluation: evaluation, morphWeights: [(0, 0.5)])
    #expect(result[0] == Float3(3, 4, 1))
    #expect(result[1] == Float3(6, 7, -5))
    #expect(throws: RigError.self) { try source.deformedPositions(part: part, evaluation: evaluation, morphWeights: [(0, .nan)]) }
    #expect(throws: RigError.self) { try source.deformedPositions(part: part, evaluation: evaluation, morphWeights: [(1, 1)]) }
    #expect(throws: RigError.self) { try source.deformedPositions(part: part, evaluation: evaluation, morphWeights: [(0, 1), (0, 0.5)]) }
}

@Test func sourceMorphRejectsMalformedSparseFramesAndUnknownInterpolation() throws {
    for change in ["duplicate", "outOfBounds", "negative", "badCount", "non100", "multiple", "tangents", "missing", "uvCount"] {
        var document = try sourceMorphFixture()
        var meshes = try #require(document["meshes"] as? [[String: Any]])
        var channels = try #require(meshes[0]["morphChannels"] as? [[String: Any]])
        var frames = try #require(channels[0]["frames"] as? [[String: Any]])
        switch change {
        case "duplicate": frames[0]["indices"] = [1, 1]; frames[0]["positionDeltas"] = [[1, 2, 3], [1, 2, 3]]
        case "outOfBounds": frames[0]["indices"] = [3]
        case "negative": frames[0]["indices"] = [-1]
        case "badCount": frames[0]["positionDeltas"] = [] as [[Float]]
        case "non100": frames[0]["weight"] = 50
        case "multiple": frames.append(frames[0])
        case "tangents": frames[0]["tangentDeltas"] = [[1, 0, 0]]
        case "missing": channels.append(["name": "metadata-only"])
        case "uvCount": meshes[0]["uv1"] = [[0, 0]]
        default: break
        }
        channels[0]["frames"] = frames; meshes[0]["morphChannels"] = channels; document["meshes"] = meshes
        #expect(throws: RigError.self) { try SourceRig.decode(JSONSerialization.data(withJSONObject: document)) }
    }
}
