import Foundation
import CryptoKit
import Testing
import Metal
import simd
import Assets
import CoreMath
import Scene
import Studio
import Character
@testable import Renderer

private func sourceStudioPreviewInputs() throws -> (scene: URL, rig: URL, catalog: URL) {
    let scenes = try SourceFixtureSupport.require("IKKOKU_STUDIO_SCENE_FIXTURES")
    let rig = try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR")
    let catalog = try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT")
    return (URL(fileURLWithPath: scenes).appendingPathComponent("synthetic-current.png"),
            URL(fileURLWithPath: rig), URL(fileURLWithPath: catalog))
}

private func sourceStudioReference(scene: URL, data: Data, rig: URL, catalog: URL, key: Int32 = 10) -> SourceStudioCharacterReference {
    SourceStudioCharacterReference(sceneFile: scene.path, sceneSHA256: OriginalCardFixture.hash(data),
        rigFile: rig.path, boneCatalogFile: catalog.path, objectKey: key)
}

@Test func sourceStudioCharacterReferenceSurvivesNativeSceneCardRoundTrip() throws {
    let reference = SourceStudioCharacterReference(sceneFile: "/local/original scene.png", sceneSHA256: String(repeating: "a", count: 64),
        rigFile: "/local/source-avatar.json", boneCatalogFile: "/local/bone-catalog.json", objectKey: 42)
    var document = StudioDocument()
    var object = StudioObject(name: "Source character", kind: .character)
    object.sourceObjectKey = 42; object.sourceCharacter = reference
    object.transform.rotation = SIMD3<Float>(10, 20, 30)
    object.transform.rotationOverride = UnityCoordinates.eulerDegrees(SIMD3<Float>(-15, 20, 35)).vector
    document.objects = [object]
    document.sourceSceneFile = reference.sceneFile; document.sourceSceneSHA256 = reference.sceneSHA256
    document.sourcePreviewDiagnostics = ["Reference avatar; original appearance and animation pending."]
    let encoded = try CardIO.encode(document, keyword: CardIO.sceneKeyword, thumbnail: nil)
    let decoded = try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: encoded)
    #expect(decoded == document)
    #expect(decoded.objects[0].sourceCharacter == reference && decoded.objects[0].card == nil)
    #expect(decoded.objects[0].transform.matrix == object.transform.matrix)
    try decoded.validateHierarchy()
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_SCENE_FIXTURES", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT"]) && MTLCreateSystemDefaultDevice() != nil,
               "Requires IKKOKU_STUDIO_SCENE_FIXTURES, IKKOKU_SOURCE_AVATAR, IKKOKU_STUDIO_POSE_CONTRACT and a Metal device"))
func sourceStudioCharacterPreviewBuildsSupportedSyntheticPoseAndFiniteWorldBoundsWhenSupplied() throws {
    let input = try sourceStudioPreviewInputs()
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let data = try Data(contentsOf: input.scene)
    var preview: SourceStudioCharacterPreview? = try SourceStudioCharacterPreview(
        reference: sourceStudioReference(scene: input.scene, data: data, rig: input.rig, catalog: input.catalog), resources: resources)
    weak var weakPreview = preview
    let original = try #require(preview)
    #expect(original.record.enableFK && !original.record.enableIK)
    #expect(original.pose.localMatrices.count == original.preview.source.rig.nodes.count)
    _ = try original.preview.source.rig.evaluate(original.pose)
    let frame = try original.frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(), world: matrix_identity_float4x4, objectID: 73)
    #expect(!frame.items.isEmpty && frame.items.allSatisfy { $0.objectID == 73 })
    #expect(!frame.sceneBounds.isEmpty && frame.sceneBounds.radius.isFinite)
    #expect(!original.diagnostics.isEmpty && original.diagnostics[0].contains("Converted card"))
    let moved = try original.frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(),
        world: Transform.translation(SIMD3<Float>(2, 3, -4)), objectID: 91)
    let expected = frame.sceneBounds.center + SIMD3<Float>(2, 3, -4)
    #expect(simd_length(moved.sceneBounds.center - expected) < 0.0001)
    #expect(moved.items.allSatisfy { $0.objectID == 91 })
    #expect(moved.skinSets.keys.sorted() == frame.skinSets.keys.sorted())
    preview = nil
    // `original` intentionally retains this instance while prepared frames exist.
    #expect(weakPreview != nil)
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_SCENE_FIXTURES", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT"]) && MTLCreateSystemDefaultDevice() != nil,
               "Requires IKKOKU_STUDIO_SCENE_FIXTURES, IKKOKU_SOURCE_AVATAR, IKKOKU_STUDIO_POSE_CONTRACT and a Metal device"))
func sourceStudioCharacterPreviewCachesKeepExplicitAnimationRequirementWhenSupplied() throws {
    let input = try sourceStudioPreviewInputs(), data = try Data(contentsOf: input.scene)
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let preview = try SourceStudioCharacterPreview(
        reference: sourceStudioReference(scene: input.scene, data: data, rig: input.rig, catalog: input.catalog), resources: resources)
    // The reference has no animation catalog: a saved unconverted animation
    // may retain its rest pose, but an explicit edit must still report failure.
    let implicit = try preview.editedPose(animationElapsed: 0.5)
    let explicit = SourceStudioAnimationState(record: preview.record)
    #expect(throws: RigError.self) { try preview.editedPose(animationState: explicit, animationElapsed: 0.5) }
    // This invalidates only the evaluated result, exercising the solved cache.
    let checkpoint = preview.captureDynamicsCheckpoint()
    try preview.setDynamicsStep(elapsed: 0.5, deltaTime: 0)
    #expect(throws: RigError.self) { try preview.editedPose(animationState: explicit, animationElapsed: 0.5) }
    try preview.restoreDynamicsCheckpoint(checkpoint)
    #expect(try preview.editedPose(animationElapsed: 0.5).localMatrices == implicit.localMatrices)
    #expect(throws: RigError.self) { try preview.editedPose(animationState: explicit, animationElapsed: 0.5) }
    preview.resetAnimationPlayback()
    #expect(throws: RigError.self) { try preview.editedPose(animationState: explicit, animationElapsed: 0.5) }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_SCENE_FIXTURES", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT"]) && MTLCreateSystemDefaultDevice() != nil,
               "Requires IKKOKU_STUDIO_SCENE_FIXTURES, IKKOKU_SOURCE_AVATAR, IKKOKU_STUDIO_POSE_CONTRACT and a Metal device"))
func sourceStudioCharacterPreviewShapeChangesInvalidateCachedPoseAtSameTimeWhenSupplied() throws {
    let input = try sourceStudioPreviewInputs(), data = try Data(contentsOf: input.scene)
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    func fresh() throws -> SourceStudioCharacterPreview {
        try .init(reference: sourceStudioReference(scene: input.scene, data: data, rig: input.rig, catalog: input.catalog), resources: resources)
    }
    let preview = try fresh()
    let initial = try preview.editedPose(animationElapsed: 0.5)
    var body = preview.savedBodyValues
    body[0] = body[0] < 0.5 ? 0.9 : 0.1
    let edited = try preview.editedPose(bodyValues: body, animationElapsed: 0.5)
    #expect(edited.localMatrices != initial.localMatrices)
    #expect(edited.localMatrices == (try fresh().editedPose(bodyValues: body, animationElapsed: 0.5)).localMatrices)
    #expect(try preview.editedPose(animationElapsed: 0.5).localMatrices == initial.localMatrices)
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_SCENE_FIXTURES", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT"]) && MTLCreateSystemDefaultDevice() != nil,
               "Requires IKKOKU_STUDIO_SCENE_FIXTURES, IKKOKU_SOURCE_AVATAR, IKKOKU_STUDIO_POSE_CONTRACT and a Metal device"))
func sourceStudioCharacterPreviewRejectsChangedSceneBeforeAssetRegistrationWhenSupplied() throws {
    let input = try sourceStudioPreviewInputs()
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let reference = SourceStudioCharacterReference(sceneFile: input.scene.path, sceneSHA256: String(repeating: "0", count: 64),
        rigFile: input.rig.path, boneCatalogFile: input.catalog.path, objectKey: 10)
    #expect(throws: RigError.self) { try SourceStudioCharacterPreview(reference: reference, resources: resources) }
    #expect(resources.mesh(MeshHandle(id: 1)) == nil)
    let data = try Data(contentsOf: input.scene)
    #expect(throws: RigError.self) {
        try SourceStudioCharacterPreview(reference: sourceStudioReference(scene: input.scene, data: data,
            rig: input.rig, catalog: input.catalog, key: -900), resources: resources)
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_SCENE_FIXTURES", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT"]) && MTLCreateSystemDefaultDevice() != nil,
               "Requires IKKOKU_STUDIO_SCENE_FIXTURES, IKKOKU_SOURCE_AVATAR, IKKOKU_STUDIO_POSE_CONTRACT and a Metal device"))
func sourceStudioCharacterPreviewRejectsUnsupportedEmbeddedSexAndHeadWhenSupplied() throws {
    let input = try sourceStudioPreviewInputs()
    let data = try Data(contentsOf: input.scene), parsed = try KoikatsuSceneReader.decodeDocument(data)
    let original = try #require(parsed.snapshot.roots.first?.character)
    let range = try #require(data.range(of: original.cardData))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cards = [OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(sex: .integer(0))),
                 OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(custom: OriginalCardFixture.custom(head: .integer(1))))]
    for (index, card) in cards.enumerated() {
        var changed = data; changed.replaceSubrange(range, with: card)
        let file = folder.appendingPathComponent("unsupported-\(index).png"); try changed.write(to: file)
        let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            _ = try SourceStudioCharacterPreview(reference: sourceStudioReference(scene: file, data: changed,
                rig: input.rig, catalog: input.catalog), resources: resources)
            Issue.record("Unsupported embedded character unexpectedly produced a reference preview.")
        } catch {
            #expect(String(describing: error).contains("identities differ") || String(describing: error).contains("assembly conversion is missing"))
        }
        // Initialization creates the source rig first; failed compatibility must
        // still release its registered geometry when the partial object dies.
        #expect(resources.mesh(MeshHandle(id: 1)) == nil)
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_SCENE_FIXTURES", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT"]) && MTLCreateSystemDefaultDevice() != nil,
               "Requires IKKOKU_STUDIO_SCENE_FIXTURES, IKKOKU_SOURCE_AVATAR, IKKOKU_STUDIO_POSE_CONTRACT and a Metal device"))
func sourceStudioCharacterPreviewRejectsUnsavedOutfitSelectionBeforeAssetRegistrationWhenSupplied() throws {
    let input = try sourceStudioPreviewInputs()
    let data = try Data(contentsOf: input.scene)
    let reference = sourceStudioReference(scene: input.scene, data: data, rig: input.rig, catalog: input.catalog)
    // The synthetic card saves no Coordinate entries: its implicit outfit 0
    // still previews, but no outfit can be selected explicitly.
    for (index, expected) in [(0, "saves no outfit 0"), (7, "0...6"), (-1, "0...6")] {
        let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            _ = try SourceStudioCharacterPreview(reference: reference, resources: resources, coordinate: index)
            Issue.record("Outfit \(index) unexpectedly produced a preview.")
        } catch { #expect(String(describing: error).contains(expected), Comment(rawValue: "\(error)")) }
        #expect(resources.mesh(MeshHandle(id: 1)) == nil)
    }
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let saved = try SourceStudioCharacterPreview(reference: reference, resources: resources)
    #expect(saved.coordinate == 0 && saved.savedCoordinate == 0 && saved.outfitCount == 0)
}
