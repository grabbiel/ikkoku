import Testing
import Foundation
import simd
import CoreMath
import Scene
@testable import Studio

private func cameraWorld(position: SIMD3<Float>, eulerDegrees: SIMD3<Float>, scale: SIMD3<Float>) -> float4x4 {
    // Exactly how the importer authors an object transform
    // (`StudioModel.importSourceScenePreview`).
    Transform.trs(UnityCoordinates.position(position), UnityCoordinates.eulerDegrees(eulerDegrees), scale)
}

private func viewUp(_ camera: OrbitCamera) -> SIMD3<Float> {
    let view = camera.viewMatrix()
    return SIMD3(view[0][1], view[1][1], view[2][1])
}

@Test func sourceCameraObjectViewCameraMatchesNativeCameraConvention() throws {
    let native = try KoikatsuCameraRecord(position: SIMD3(1, 2, 3), rotationDegrees: SIMD3(10, 70, 25),
        distance: .zero, fieldOfView: 40).nativeCamera()
    var base = OrbitCamera()
    base.fovDegrees = 40
    let view = try SourceStudioCameraObjects.viewCamera(
        world: cameraWorld(position: SIMD3(1, 2, 3), eulerDegrees: SIMD3(10, 70, 25), scale: .one), base: base)
    #expect(length(view.position - native.position) < 0.0001)
    #expect(length(view.forward - native.forward) < 0.0001)
    #expect(length(viewUp(view) - viewUp(native)) < 0.0001)
    #expect(view.fovDegrees == 40)
    #expect(view.near == base.near)
}

@Test func sourceCameraObjectViewCameraIgnoresUniformParentScale() throws {
    let rotation = UnityCoordinates.eulerDegrees(SIMD3(10, 70, 25))
    let parentScaled = Transform.trs(UnityCoordinates.position(SIMD3(-1, 0.5, 2)), rotation, SIMD3(repeating: 2))
    let parentPlain = Transform.trs(UnityCoordinates.position(SIMD3(-1, 0.5, 2)), rotation, .one)
    let local = cameraWorld(position: SIMD3(0.2, 0.1, -0.3), eulerDegrees: SIMD3(-15, 40, 5), scale: .one)
    var base = OrbitCamera()
    base.fovDegrees = 40
    let scaled = try SourceStudioCameraObjects.viewCamera(world: parentScaled * local, base: base)
    let plain = try SourceStudioCameraObjects.viewCamera(world: parentPlain * local, base: base)
    // The scaled parent moves the child's world position, but the LateUpdate
    // copy uses that translation as-is and strips scale from the rotation.
    #expect(abs(dot(scaled.orientationOverride!, plain.orientationOverride!)) > 0.9999)
    #expect(length(viewUp(scaled) - viewUp(plain)) < 0.0001)
    #expect(length(scaled.forward - plain.forward) < 0.0001)
}

@Test func sourceCameraObjectViewCameraRejectsDegenerateWorldMatrices() {
    var base = OrbitCamera()
    let rotation = UnityCoordinates.eulerDegrees(SIMD3(10, 20, 30))
    #expect(throws: RigError.self) {
        try SourceStudioCameraObjects.viewCamera(world: Transform.trs(.zero, rotation, .zero), base: base)
    }
    var nan = Transform.trs(UnityCoordinates.position(SIMD3(1, 2, 3)), rotation, .one)
    nan.columns.3 = Float4(nan.columns.3.x, .nan, nan.columns.3.z, 1)
    #expect(throws: RigError.self) {
        try SourceStudioCameraObjects.viewCamera(world: nan, base: base)
    }
}

/// The former unchecked `viewCamera(world:base:)` body, the reference for accepted input.
private func formerViewCamera(world: float4x4, base: OrbitCamera) -> OrbitCamera {
    let orientation = world.rotationQuaternion
    let forward = orientation.act(Float3(0, 0, -1))
    var camera = OrbitCamera()
    camera.distance = max(base.distance, 0.001)
    camera.target = world.translation + forward * camera.distance
    camera.yaw = atan2(-forward.x, -forward.z)
    camera.pitch = asin(min(max(-forward.y, -1), 1))
    camera.fovDegrees = base.fovDegrees
    camera.near = base.near
    camera.orientationOverride = orientation.vector
    return camera
}

@Test func sourceCameraObjectViewCameraRejectsMirroredParentsAndKeepsOthersExact() throws {
    var base = OrbitCamera()
    base.fovDegrees = 40
    let parentPosition = UnityCoordinates.position(SIMD3(-1, 0.5, 2))
    let parentRotation = UnityCoordinates.eulerDegrees(SIMD3(10, 70, 25))
    let localPosition = UnityCoordinates.position(SIMD3(0.2, 0.1, -0.3))
    let localRotation = UnityCoordinates.eulerDegrees(SIMD3(-15, 40, 5))
    let local = Transform.trs(localPosition, localRotation, .one)
    // Non-mirrored parents give exactly the former result, through the full-TRS world matrix (uniform
    // scale only: a non-uniform parent shears it) and through the Studio-rule parent frame.
    for scale in [SIMD3<Float>(repeating: 1), SIMD3(repeating: 2), SIMD3(1, 2, 0.5)] {
        let parent = Transform.trs(parentPosition, parentRotation, scale)
        if scale.x == scale.y, scale.y == scale.z {
            #expect(try SourceStudioCameraObjects.viewCamera(world: parent * local, base: base)
                == formerViewCamera(world: parent * local, base: base))
        }
        let studioWorld = try SourceStudioWorldTransform.world(parentFrame: parent, localPosition: localPosition,
            localRotation: localRotation, localScale: .one, scalable: false)
        let view = try SourceStudioCameraObjects.viewCamera(parentFrame: parent, localPosition: localPosition,
            localRotation: localRotation, base: base)
        #expect(view == formerViewCamera(world: studioWorld, base: base))
        try view.validate()
    }
    // A mirror on any one axis, or all three, is rejected by name in both forms. The Studio walk
    // folds a mirrored parent into a nonunit rotation, so only the parent frame still shows it.
    for signs in [SIMD3<Float>(-1, 1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, -1), SIMD3(-1, -1, -1)] {
        let mirrored = Transform.trs(parentPosition, parentRotation, signs * 1.5)
        #expect(throws: SourceStudioCameraObjectError.reflectedFrame("world frame")) {
            try SourceStudioCameraObjects.viewCamera(world: mirrored * local, base: base)
        }
        #expect(throws: SourceStudioCameraObjectError.reflectedFrame("parent frame")) {
            try SourceStudioCameraObjects.viewCamera(parentFrame: mirrored, localPosition: localPosition,
                localRotation: localRotation, base: base)
        }
    }
    // The result is validated like an imported camera.
    var badLens = base
    badLens.near = 0
    #expect(throws: RigError.self) { try SourceStudioCameraObjects.viewCamera(world: local, base: badLens) }
}

private func cameraObjectRecord(key: Int32, active: Bool?, children: [KoikatsuObjectRecord] = []) -> KoikatsuObjectRecord {
    KoikatsuObjectRecord(kind: .camera, rootDictionaryKey: nil, sourceKey: key,
        transform: KoikatsuChangeAmount(position: .zero, rotationDegrees: .zero, scale: .one),
        treeState: 1, visible: true, name: "Camera \(key)", cameraActive: active,
        item: nil, light: nil, children: children)
}

@Test func sourceCameraObjectsActiveAtLoadFollowsPreorderChangeCamera() {
    let none = KoikatsuSceneSnapshot(version: "1.0.4.2", roots: [cameraObjectRecord(key: 1, active: false)],
        objectSectionEndOffset: 0)
    #expect(SourceStudioCameraObjects.activeAtLoad(none) == nil)
    let single = KoikatsuSceneSnapshot(version: "1.0.4.2",
        roots: [cameraObjectRecord(key: 1, active: true), cameraObjectRecord(key: 2, active: false)],
        objectSectionEndOffset: 0)
    #expect(SourceStudioCameraObjects.activeAtLoad(single) == 1)
    // `ChangeCamera(c, true)` deactivates the previous camera, so the last
    // active record in load order wins even when it is nested and later.
    let folder = KoikatsuObjectRecord(kind: .folder, rootDictionaryKey: nil, sourceKey: 3,
        transform: KoikatsuChangeAmount(position: .zero, rotationDegrees: .zero, scale: .one),
        treeState: 1, visible: true, name: "Folder", cameraActive: nil,
        item: nil, light: nil, children: [cameraObjectRecord(key: 4, active: true)])
    let nested = KoikatsuSceneSnapshot(version: "1.0.4.2",
        roots: [cameraObjectRecord(key: 1, active: true), folder], objectSectionEndOffset: 0)
    #expect(SourceStudioCameraObjects.activeAtLoad(nested) == 4)
}
