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

private func cameraRight(_ camera: OrbitCamera) -> SIMD3<Float> {
    let view = camera.viewMatrix()
    return SIMD3(view[0][0], view[1][0], view[2][0])
}

private func cameraUp(_ camera: OrbitCamera) -> SIMD3<Float> {
    let view = camera.viewMatrix()
    return SIMD3(view[0][1], view[1][1], view[2][1])
}

@Test func importedCameraRollAndLensSurviveDocumentAndOriginalExportUntilOrbitEdit() throws {
    let scene = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    // Rolled source cameras (Unity Z) with offset distance vectors and narrow, normal and wide lenses.
    let records = [
        KoikatsuCameraRecord(position: .init(0.2, 1.1, -0.4), rotationDegrees: .init(12, -35, 40), distance: .init(0.1, -0.2, -3), fieldOfView: 10),
        KoikatsuCameraRecord(position: .init(-1, 0.5, 2), rotationDegrees: .init(70, 150, -75), distance: .init(0, 0, -1.5), fieldOfView: 60),
        KoikatsuCameraRecord(position: .init(3, -2, 0.5), rotationDegrees: .init(-60, 10, -130), distance: .init(0.4, 0.3, -8), fieldOfView: 150)]
    for record in records {
        // Original file → native camera: the override keeps the roll; FOV is the vertical lens.
        let source = try KoikatsuSceneReader.decodeDocument(scene.editedData(.init(currentCamera: record, cameraSlots: [4: record])))
        let camera = try source.settings.camera.nativeCamera()
        try camera.validate()
        let roll = try #require(camera.orientationOverride)
        #expect(abs(cameraRight(camera).y) > 0.1)
        #expect(try source.settings.cameraSlots[4].nativeCamera() == camera)
        #expect(camera.fovDegrees == record.fieldOfView)
        #expect(camera.projectionMatrix(aspect: 1.5) == Projection.perspectiveReverseZInfinite(
            fovyRadians: record.fieldOfView.degreesToRadians, aspect: 1.5, near: camera.near))

        // Native scene card: every field survives exactly, including the native-only near plane, so the
        // app's export comparison against the re-imported record writes nothing for an unedited camera.
        var nearEdited = camera
        nearEdited.near = 0.02
        var document = StudioDocument()
        document.camera = camera
        document.cameraSlots[3] = nearEdited
        let restored = try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword,
                                         from: CardIO.encode(document, keyword: CardIO.sceneKeyword, thumbnail: nil))
        try restored.validateCameras()
        #expect(try restored.camera == source.settings.camera.nativeCamera())
        #expect(restored.cameraSlots[3] == nearEdited)

        // Dolly, pan and lens edits keep the roll; the edited original export re-imports to the same view.
        var edited = restored.camera
        edited.dolly(1.5)
        edited.pan(dx: 20, dy: -10)
        edited.fovDegrees = 35
        #expect(edited.orientationOverride == roll)
        let exported = try KoikatsuSceneReader.decodeDocument(source.editedData(.init(currentCamera: edited.sourceCameraRecord())))
        let reimported = try exported.settings.camera.nativeCamera()
        #expect(reimported.fovDegrees == 35)
        #expect(simd_length(reimported.position - edited.position) < 1e-4)
        #expect(simd_length(reimported.forward - edited.forward) < 1e-4)
        #expect(simd_length(cameraUp(reimported) - cameraUp(edited)) < 1e-4)

        // An orbit edit is the intentional change that returns to two-angle control: the roll goes away.
        var orbited = restored.camera
        orbited.orbit(dx: 0.05, dy: 0.02)
        #expect(orbited.orientationOverride == nil)
        #expect(abs(cameraRight(orbited).y) < 1e-6)
        #expect(orbited.fovDegrees == record.fieldOfView)
        try orbited.validate()
    }
}

@Test func studioDocumentRejectsDegenerateDecodedCameras() throws {
    try StudioDocument().validateCameras()
    func makeCamera(_ edit: (inout OrbitCamera) -> Void) -> OrbitCamera {
        var result = OrbitCamera()
        edit(&result)
        return result
    }
    let invalid = [
        makeCamera { $0.distance = 0 }, makeCamera { $0.distance = -1 }, makeCamera { $0.near = 0 },
        makeCamera { $0.near = .infinity }, makeCamera { $0.fovDegrees = 0 }, makeCamera { $0.fovDegrees = 180 },
        makeCamera { $0.fovDegrees = .nan }, makeCamera { $0.target.x = .nan }, makeCamera { $0.yaw = .infinity },
        makeCamera { $0.orientationOverride = Float4(0, 0, 0, 0) }, makeCamera { $0.orientationOverride = Float4(0, 0, 0, 2) },
        makeCamera { $0.orientationOverride = Float4(.nan, 0, 0, 1) },
        // A distance that vanishes against a far target leaves no view direction.
        makeCamera { $0.target = Float3(repeating: 1e6); $0.distance = 1e-30 }]
    for value in invalid {
        #expect(throws: RigError.self) { try value.validate() }
        var current = StudioDocument()
        current.camera = value
        #expect(throws: RigError.self) { try current.validateCameras() }
        var slot = StudioDocument()
        slot.cameraSlots[7] = value
        #expect(throws: RigError.self) { try slot.validateCameras() }
        var object = StudioObject(name: "Camera", kind: .camera)
        object.savedCamera = value
        var saved = StudioDocument()
        saved.objects.append(object)
        #expect(throws: RigError.self) { try saved.validateCameras() }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_EXPANSION", "IKKOKU_MAKER_LIBRARY", "IKKOKU_SOURCE_AVATAR", "IKKOKU_SOURCE_MALE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT"]) && MTLCreateSystemDefaultDevice() != nil,
               "Requires IKKOKU_STUDIO_EXPANSION, IKKOKU_MAKER_LIBRARY, IKKOKU_SOURCE_AVATAR, IKKOKU_SOURCE_MALE_AVATAR, IKKOKU_STUDIO_POSE_CONTRACT and a Metal device"))
func sourceStudioExpandedCardsUseMakerSelectionsAndAttachmentCatalogWhenSupplied() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_STUDIO_EXPANSION")
    let library = try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")
    let female = try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR")
    let male = try SourceFixtureSupport.require("IKKOKU_SOURCE_MALE_AVATAR")
    let catalog = try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT")
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
