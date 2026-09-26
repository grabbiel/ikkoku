import Foundation
import Testing
import Metal
import simd
import Scene
import Character
import Renderer

private func maleAvatarURL() throws -> URL {
    URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SOURCE_MALE_AVATAR"))
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SOURCE_MALE_AVATAR"]),
               "Requires IKKOKU_SOURCE_MALE_AVATAR"))
func sourceMaleOriginalAssemblyAndPresetRemainDistinctWhenSupplied() throws {
    let url = try maleAvatarURL()
    let source = try SourceRig.loadModel(url: url)
    let folder = url.deletingLastPathComponent()
    let manifest = try JSONDecoder().decode(SourceAvatarManifest.self, from: Data(contentsOf: url))
    #expect(manifest.kind == "koikatsu-male-avatar" && manifest.sex == 0)
    let card = try SourceCharacterCard.load(url: folder.appendingPathComponent(try #require(manifest.defaultCard)))
    let values = try card.customization()
    #expect(values.sex == 0 && values.headID == 0 && values.boneType == 0)
    let contract = try SourceShapeContract.decode(Data(contentsOf: folder.appendingPathComponent("character-shape-contract.json")))
    #expect(contract.domain("body")?.defaultValues == values.bodyValues)
    #expect(contract.domain("face")?.defaultValues == values.faceValues)
    #expect(source.rig.nodes.count == 761 && source.parts.count == 18)
    #expect(source.parts.reduce(0) { $0 + $1.mesh.vertexCount } == 31_278)
    let names = Set(source.parts.map(\.mesh.name))
    #expect(names.contains("o_body_a/0") && names.contains("o_top_tsyats_a/0"))
    #expect(names.contains("o_bot_pants03/0") && names.contains("o_shoes_run01/0"))
    #expect(names.contains("cf_hair_b_33_00/0") && names.contains("cf_hair_f_05_00/0"))
    #expect(!names.contains { $0.contains("silhouette") || $0.contains("shadowcaster") || $0.contains("dankon") || $0.contains("dan_f") || $0.contains("gomu") })
    let rest = try source.rig.evaluate(source.rig.restPose)
    for part in source.parts {
        let vertices = try source.deformedPositions(part: part, evaluation: rest)
        #expect(vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SOURCE_MALE_AVATAR"]) && MTLCreateSystemDefaultDevice() != nil,
               "Requires IKKOKU_SOURCE_MALE_AVATAR and a Metal device"))
func sourceMaleOriginalPresetBuildsClothedMetalFrameWhenSupplied() throws {
    let url = try maleAvatarURL()
    let source = try SourceRig.loadModel(url: url), folder = url.deletingLastPathComponent()
    let contract = try SourceShapeContract.decode(Data(contentsOf: folder.appendingPathComponent("character-shape-contract.json")))
    let body = try #require(contract.domain("body")), face = try #require(contract.domain("face"))
    let bodyPose = try SourceBodyShapePose.make(rig: source.rig, domain: body, options: .init(sex: .male))
    let pose = try SourceFaceShapePose.make(rig: source.rig, domain: face, basePose: bodyPose)
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let appearance = try SourcePreviewAppearance.load(url: folder.appendingPathComponent("source-male-avatar.appearance.json"), resources: resources)
    let preview = try SourceRigPreview(source: source, contract: contract, resources: resources, appearance: appearance)
    let frame = try preview.frame(camera: OrbitCamera(), poseOverride: pose)
    #expect(frame.items.count == 19) // Source upper eyeline has an additional material pass.
    #expect(!frame.sceneBounds.isEmpty && frame.sceneBounds.radius.isFinite)
    #expect(frame.sceneBounds.radius > 0.5 && frame.sceneBounds.radius < 3)
    #expect(frame.items.allSatisfy { $0.morphWeights.isEmpty })
}
