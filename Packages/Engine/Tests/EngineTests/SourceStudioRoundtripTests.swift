import Foundation
import Testing
import Metal
import simd
import CoreMath
import Character
import Scene
import Studio
import Renderer

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_EXPANSION", "IKKOKU_MAKER_LIBRARY", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT"]) && MTLCreateSystemDefaultDevice() != nil,
               "Requires IKKOKU_STUDIO_EXPANSION, IKKOKU_MAKER_LIBRARY, IKKOKU_SOURCE_AVATAR, IKKOKU_STUDIO_POSE_CONTRACT and a Metal device"))
func sourceStudioEditedFKMatchesExportReloadPoseAndDeformedVerticesWhenSupplied() throws {
    let directory = try SourceFixtureSupport.require("IKKOKU_STUDIO_EXPANSION")
    let library = try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")
    let female = try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR")
    let catalogPath = try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT")
    let folder = URL(fileURLWithPath: directory), input = folder.appendingPathComponent("studio-female-head200-bone1.png")
    let data = try Data(contentsOf: input), scene = try KoikatsuSceneReader.decodeDocument(data)
    let original = try #require(scene.snapshot.roots.first { $0.sourceKey == 10 }?.character)
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    func preview(_ url: URL, _ data: Data) throws -> SourceStudioCharacterPreview {
        try SourceStudioCharacterPreview(reference: .init(sceneFile: url.path, sceneSHA256: OriginalCardFixture.hash(data),
            rigFile: female, boneCatalogFile: catalogPath, objectKey: 10, makerLibraryFile: library), resources: resources)
    }
    let before = try preview(input, data), edit = Float3(11,23,7)
    let bone = try #require(original.bones[1]), target = try #require(before.controller.targets.first { $0.bone.id == 1 })
    var groups = original.activeFK
    for (index, group) in SourceStudioPose.Group.fkParts.enumerated() where !group.intersection(target.bone.fkGroup).isEmpty { groups[index] = true }
    let editedData = try scene.editedData(.init(transforms: [.init(.characterFK(object: 10, bone: 1),
        transform: .init(position: bone.transform.position, rotationDegrees: edit, scale: bone.transform.scale))],
        kinematics: [10: .init(enableFK: true, enableIK: false, activeFK: groups)]))
    let output = folder.appendingPathComponent("pose-roundtrip-" + UUID().uuidString + ".png")
    try editedData.write(to: output); defer { try? FileManager.default.removeItem(at: output) }
    let after = try preview(output, editedData), editedPose = try before.editedPose(fkRotations: [1: edit])
    #expect(before.record.cardData == after.record.cardData && before.expressionInputs == after.expressionInputs)
    let a = before.preview.source, b = after.preview.source
    #expect(a.rig.nodes.map(\.sourceID) == b.rig.nodes.map(\.sourceID))
    #expect(a.parts.map(\.mesh.name) == b.parts.map(\.mesh.name))
    var localMaximum: Float = 0, changedNodes: [[String: Any]] = []
    for index in a.rig.nodes.indices {
        var delta: Float = 0
        for column in 0..<4 { for row in 0..<4 { delta = max(delta, abs(editedPose.localMatrices[index][column][row] - after.pose.localMatrices[index][column][row])) } }
        localMaximum = max(localMaximum, delta)
        if delta > 0 { changedNodes.append(["name": a.rig.nodes[index].name, "maximumComponentError": delta]) }
    }
    let ae = try a.rig.evaluate(editedPose), be = try b.rig.evaluate(after.pose)
    let expression = try #require(before.expressionInputs)
    let weights = try #require(before.preview.expressionContract).weights(source: a, inputs: expression)
    var vertexMaximum: Float = 0, changedVertices = 0, vertices = 0
    for (ap,bp) in zip(a.parts,b.parts) {
        let av = try a.deformedPositions(part: ap, evaluation: ae, morphWeights: weights[ap.mesh.name] ?? [])
        let bv = try b.deformedPositions(part: bp, evaluation: be, morphWeights: weights[bp.mesh.name] ?? [])
        for (x,y) in zip(av,bv) {
            let difference = simd_distance(x,y); vertexMaximum = max(vertexMaximum,difference)
            vertices += 1; if difference > 0 { changedVertices += 1 }
        }
    }
    let report: [String: Any] = ["localMatrixMaximumError": localMaximum, "changedNodes": changedNodes,
        "deformedVertexMaximumError": vertexMaximum, "changedVertices": changedVertices, "vertices": vertices,
        "cardByteIdentical": before.record.cardData == after.record.cardData,
        "expressionInputsIdentical": before.expressionInputs == after.expressionInputs]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("pose-roundtrip-audit.json"))
    #expect(localMaximum == 0 && vertexMaximum == 0 && changedVertices == 0)
}
