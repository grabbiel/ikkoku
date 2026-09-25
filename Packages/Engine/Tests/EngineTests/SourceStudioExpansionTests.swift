import Foundation
import Testing
import Metal
import simd
import CoreMath
import Scene
import Studio
import Character
import Renderer

@Test func sourceEditedEulerPreservesZXYRotationIncludingGimbalLock() {
    for angles: SIMD3<Float> in [.zero, .init(23, -41, 67), .init(90, 40, -70), .init(-90, 40, 70), .init(89.9, 179, -179), .init(450, -720, 1080)] {
        let original = UnityCoordinates.eulerDegrees(angles)
        let roundTrip = UnityCoordinates.eulerDegrees(UnityCoordinates.sourceEulerDegrees(original))
        #expect(abs(dot(original.vector, roundTrip.vector)) > 0.99999)
    }
}

@Test func sourceStudioCameraRestoresOffsetRollAndRoundTripsNativeDocument() throws {
    let source = KoikatsuCameraRecord(position: .init(1, 2, 3), rotationDegrees: .init(10, 20, 30), distance: .init(0.3, -0.4, -5), fieldOfView: 23)
    let camera = try source.nativeCamera()
    let sourceRotation = UnityCoordinates.rotation(UnityCoordinates.eulerDegrees(source.rotationDegrees))
    let expectedEye = UnityCoordinates.position(source.position + sourceRotation.act(source.distance))
    let expectedForward = UnityCoordinates.direction(sourceRotation.act(.init(0, 0, 1)))
    #expect(length(camera.position - expectedEye) < 0.00001)
    #expect(length(camera.forward - expectedForward) < 0.00001)
    let sourceUp = UnityCoordinates.direction(sourceRotation.act(.init(0, 1, 0)))
    let view = camera.viewMatrix()
    #expect(length(SIMD3(view[0][1], view[1][1], view[2][1]) - sourceUp) < 0.00001)
    let restored = try JSONDecoder().decode(OrbitCamera.self, from: JSONEncoder().encode(camera))
    #expect(restored == camera)
    let editedRoundTrip = try camera.sourceCameraRecord().nativeCamera()
    #expect(length(editedRoundTrip.position - camera.position) < 0.00001)
    #expect(length(editedRoundTrip.forward - camera.forward) < 0.00001)
    var edited = camera; edited.orbit(dx: 0.01, dy: 0.02)
    #expect(edited.orientationOverride == nil)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceStudioExpandedCardsUseMakerSelectionsAndAttachmentCatalogWhenSupplied() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["IKKOKU_STUDIO_EXPANSION"], let library = env["IKKOKU_MAKER_LIBRARY"],
          let female = env["IKKOKU_SOURCE_AVATAR"], let male = env["IKKOKU_SOURCE_MALE_AVATAR"],
          let catalog = env["IKKOKU_STUDIO_POSE_CONTRACT"] else { return }
    struct Fixtures: Decodable { struct Row: Decodable { let file: String, sex: Int, sha256: String }; let fixtures: [Row] }
    let folder = URL(fileURLWithPath: path)
    let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: folder.appendingPathComponent("fixtures.json")))
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    for fixture in fixtures.fixtures {
        let reference = SourceStudioCharacterReference(sceneFile: folder.appendingPathComponent(fixture.file).path,
            sceneSHA256: fixture.sha256, rigFile: fixture.sex == 0 ? male : female, boneCatalogFile: catalog, objectKey: 10,
            makerLibraryFile: library, attachmentCatalogFile: URL(fileURLWithPath: catalog).deletingLastPathComponent().appendingPathComponent("attachments.json").path)
        let preview = try SourceStudioCharacterPreview(reference: reference, resources: resources)
        #expect(preview.selections.count == 13)
        #expect(preview.selections.allSatisfy { $0.status == "converted" || $0.status == "empty" })
        #expect(preview.preview.bodyCoverage?.completeSlots.count == 44)
        let rig = preview.preview.source.rig, point = try preview.attachmentMatrix(pointID: 7)
        let expected = try rig.evaluate(preview.pose).worldMatrices[rig.uniqueNode(named: "a_n_head")]
        #expect(point == expected)
        #expect(throws: RigError.self) { try preview.attachmentMatrix(pointID: -1) }
        let frame = try preview.frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(), world: matrix_identity_float4x4, objectID: 77)
        #expect(frame.items.count >= 20 && frame.items.allSatisfy { $0.objectID == 77 })
        #expect(frame.sceneBounds.radius.isFinite)
        if let target = preview.controller.targets.first(where: { $0.hasGuide && preview.record.bones[Int32($0.bone.id)] != nil }) {
            let changed = try preview.editedPose(fkRotations: [target.bone.id: .init(11, 23, 7)])
            #expect(changed.localMatrices[target.node] != preview.pose.localMatrices[target.node])
            _ = try rig.evaluate(changed)
        }
    }
}
