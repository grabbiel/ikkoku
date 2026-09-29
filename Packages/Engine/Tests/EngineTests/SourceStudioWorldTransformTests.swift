import Testing
import Foundation
import simd
import CoreMath
import Scene
@testable import Studio

// Fixture written by the ST-A06 capture rig on the original player
// (`Tools/reverse/fixtures/camera-object-reference.json`), copied here
// byte-for-byte. Unity conventions: positions in metres, quaternions
// x, y, z, w, and Euler degrees applied z, x, then y.
private let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures/camera-object-reference.json")

private func fixtureJSON() throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
}

private func fixtureVector(_ value: Any?, _ label: String) throws -> SIMD3<Float> {
    let rows = value as? [Any]
    guard let rows, rows.count == 3 else { throw RigError.invalid("Fixture vector for \(label) has the wrong length.") }
    let numbers = try rows.map { let n = try #require($0 as? NSNumber); return n.doubleValue }
    return SIMD3(Float(numbers[0]), Float(numbers[1]), Float(numbers[2]))
}

private func fixtureQuaternion(_ value: Any?, _ label: String) throws -> simd_quatf {
    let rows = value as? [Any]
    guard let rows, rows.count == 4 else { throw RigError.invalid("Fixture quaternion for \(label) has the wrong length.") }
    let numbers = try rows.map { let n = try #require($0 as? NSNumber); return n.doubleValue }
    return simd_quatf(ix: Float(numbers[0]), iy: Float(numbers[1]), iz: Float(numbers[2]), r: Float(numbers[3]))
}

private func kindOf(_ raw: Int32, _ label: String) throws -> KoikatsuObjectKind {
    guard let kind = KoikatsuObjectKind(rawValue: raw) else { throw RigError.invalid("Fixture kind for \(label) is unknown.") }
    return kind
}

/// Sign-insensitive angle between two rotations, degrees. Both quaternions
/// are normalized and the cosine goes through `Double`: the fixture stores
/// six-decimal quaternions whose norm is off by ~3e-7, and `acos` near 1
/// amplifies that defect (or `Float` dot rounding) into ~0.09° of noise.
private func angleDegrees(_ a: simd_quatf, _ b: simd_quatf) -> Double {
    let av = a.normalized.vector, bv = b.normalized.vector
    let cosine = (Double(av.x * bv.x) + Double(av.y * bv.y) + Double(av.z * bv.z) + Double(av.w * bv.w)).magnitude
    return 2 * acos(min(1, cosine)) * 180 / .pi
}

private func baseCamera(fov: Float) -> OrbitCamera {
    var camera = OrbitCamera()
    camera.fovDegrees = fov
    return camera
}

@Test func sourceWorldTransformReplaysCapturedCameraObjects() throws {
    let cases = try #require(try fixtureJSON()["objectCases"] as? [Any])
    #expect(!cases.isEmpty)
    for rawCase in cases {
        let testCase = try #require(rawCase as? [String: Any])
        let name = try #require(testCase["name"] as? String)
        let local = try #require(testCase["local"] as? [String: Any])
        let camera = try #require(testCase["camera"] as? [String: Any])
        var parentFrame = Transform.identity
        if let parent = testCase["parent"] as? [String: Any] {
            parentFrame = try SourceStudioWorldTransform.world(
                parentFrame: Transform.identity,
                localPosition: UnityCoordinates.position(try fixtureVector(parent["authoredPosition"], "\(name).authoredPosition")),
                localRotation: UnityCoordinates.eulerDegrees(try fixtureVector(parent["authoredRotation"], "\(name).authoredRotation")),
                localScale: try fixtureVector(parent["authoredScale"], "\(name).authoredScale"),
                scalable: try #require(parent["scaleApplied"] as? Bool, "\(name).scaleApplied"))
            let world = try #require(parent["world"] as? [String: Any])
            let worldPosition = UnityCoordinates.position(try fixtureVector(world["position"], "\(name).parentWorldPosition"))
            let worldRotation = UnityCoordinates.rotation(try fixtureQuaternion(world["rotation"], "\(name).parentWorldRotation"))
            let worldScale = try fixtureVector(world["scale"], "\(name).parentWorldScale")
            #expect(length(parentFrame.translation - worldPosition) < 0.0001, "\(name)")
            #expect(angleDegrees(parentFrame.rotationQuaternion, worldRotation) < 0.01, "\(name)")
            #expect(length(parentFrame.scaleFactors - worldScale) < 0.00001, "\(name)")
        }
        let cameraWorld = try SourceStudioWorldTransform.world(
            parentFrame: parentFrame,
            localPosition: UnityCoordinates.position(try fixtureVector(local["position"], "\(name).localPosition")),
            localRotation: UnityCoordinates.eulerDegrees(try fixtureVector(local["rotation"], "\(name).localRotation")),
            localScale: .one, scalable: false)
        let base = baseCamera(fov: Float(truncating: try #require(camera["fov"] as? NSNumber, "\(name).fov")))
        let view = try SourceStudioCameraObjects.viewCamera(world: cameraWorld, base: base)
        let capturedPosition = UnityCoordinates.position(try fixtureVector(camera["position"], "\(name).cameraPosition"))
        let capturedRotation = UnityCoordinates.rotation(try fixtureQuaternion(camera["rotation"], "\(name).cameraRotation"))
        let viewOrientation = try #require(view.orientationOverride, "\(name).viewRotation")
        let viewRotation = simd_quatf(vector: viewOrientation)
        #expect(length(view.position - capturedPosition) < 0.0001, "\(name)")
        #expect(angleDegrees(viewRotation, capturedRotation) < 0.01, "\(name)")
        #expect(view.fovDegrees == base.fovDegrees, "\(name)")
    }
}

@Test func naiveCompoundedFolderScaleMissesCapturedCamera() throws {
    // The previous walk multiplied full TRS matrices up the chain, so the
    // folder's authored scale 2 scaled the nested camera's local position.
    // This proves the fixture discriminates the Studio scale rule.
    let cases = try #require(try fixtureJSON()["objectCases"] as? [Any])
    let folderCase = try #require(cases.first { ($0 as? [String: Any])?["name"] as? String == "folder" } as? [String: Any])
    let local = try #require(folderCase["local"] as? [String: Any])
    let parent = try #require(folderCase["parent"] as? [String: Any])
    let camera = try #require(folderCase["camera"] as? [String: Any])
    let naiveParent = Transform.trs(
        UnityCoordinates.position(try fixtureVector(parent["authoredPosition"], "folder.authoredPosition")),
        UnityCoordinates.eulerDegrees(try fixtureVector(parent["authoredRotation"], "folder.authoredRotation")),
        try fixtureVector(parent["authoredScale"], "folder.authoredScale"))
    let naiveWorld = naiveParent * Transform.trs(
        UnityCoordinates.position(try fixtureVector(local["position"], "folder.localPosition")),
        UnityCoordinates.eulerDegrees(try fixtureVector(local["rotation"], "folder.localRotation")), .one)
    let view = try SourceStudioCameraObjects.viewCamera(world: naiveWorld,
        base: baseCamera(fov: Float(truncating: try #require(camera["fov"] as? NSNumber, "folder.fov"))))
    #expect(length(view.position - UnityCoordinates.position(try fixtureVector(camera["position"], "folder.cameraPosition"))) > 1)
}

@Test func sourceLoadCasesResolveActiveCameraAtLoad() throws {
    let cases = try #require(try fixtureJSON()["loadCases"] as? [Any])
    #expect(cases.count == 3)
    for rawCase in cases {
        let testCase = try #require(rawCase as? [String: Any])
        let name = try #require(testCase["name"] as? String)
        let rows = try #require(testCase["records"] as? [Any])
        var parsed: [(name: String, dicKey: Int32, kind: KoikatsuObjectKind, active: Bool?,
                      parent: String?, position: SIMD3<Float>, rotation: SIMD3<Float>)] = []
        for rawRecord in rows {
            let record = try #require(rawRecord as? [String: Any])
            let local = try #require(record["local"] as? [String: Any])
            parsed.append((
                name: try #require(record["name"] as? String, #"\#(name) record name"#),
                dicKey: Int32(truncating: try #require(record["dicKey"] as? NSNumber, "\(name).dicKey")),
                kind: try kindOf(Int32(truncating: try #require(record["kind"] as? NSNumber, "\(name).kind")), "\(name).kind"),
                active: record["active"] as? Bool,
                parent: record["parent"] as? String,
                position: try fixtureVector(local["position"], "\(name).local position"),
                rotation: try fixtureVector(local["rotation"], "\(name).local rotation")))
        }
        func build(_ node: Int) -> KoikatsuObjectRecord {
            // Children keep array order, which follows the file's load order.
            let children = parsed.indices.filter { parsed[$0].parent == parsed[node].name }.map(build)
            return KoikatsuObjectRecord(kind: parsed[node].kind, rootDictionaryKey: parsed[node].dicKey,
                sourceKey: parsed[node].dicKey,
                transform: KoikatsuChangeAmount(position: parsed[node].position, rotationDegrees: parsed[node].rotation, scale: .one),
                treeState: 1, visible: true, name: parsed[node].name, cameraActive: parsed[node].active,
                item: nil, light: nil, children: children)
        }
        let roots = parsed.indices.filter { parsed[$0].parent == nil }.map(build)
        let snapshot = KoikatsuSceneSnapshot(version: "1.0.4.2", roots: roots, objectSectionEndOffset: 0)
        let expectedName = testCase["activeAfterLoad"] as? String
        let expected = expectedName.flatMap { wanted in parsed.first { $0.name == wanted }?.dicKey }
        #expect(SourceStudioCameraObjects.activeAtLoad(snapshot) == expected, "\(name)")
    }
}

@Test func nonScalableWorldIgnoresAuthoredScaleEntirely() throws {
    let rotation = UnityCoordinates.eulerDegrees(SIMD3(10, 40, 15))
    let position = UnityCoordinates.position(SIMD3(0.5, 0.25, -0.75))
    let scaled = try SourceStudioWorldTransform.world(parentFrame: Transform.identity, localPosition: position,
        localRotation: rotation, localScale: SIMD3(2, 2, 2), scalable: false)
    let plain = try SourceStudioWorldTransform.world(parentFrame: Transform.identity, localPosition: position,
        localRotation: rotation, localScale: .one, scalable: false)
    #expect(length(scaled.translation - plain.translation) < 0.000001)
    #expect(length(scaled.scaleFactors - .one) < 0.000001)
}

@Test func worldScaleDoesNotCompoundButPositionsStillUseParentScale() throws {
    let rotation = UnityCoordinates.eulerDegrees(SIMD3(0, 40, 15))
    let parent = try SourceStudioWorldTransform.world(parentFrame: Transform.identity,
        localPosition: UnityCoordinates.position(SIMD3(1, 0.5, 2)), localRotation: rotation,
        localScale: SIMD3(repeating: 3), scalable: true)
    let local = UnityCoordinates.position(SIMD3(0.3, 0.6, -0.9))
    let child = try SourceStudioWorldTransform.world(parentFrame: parent, localPosition: local,
        localRotation: UnityCoordinates.eulerDegrees(SIMD3(10, 70, 25)), localScale: SIMD3(repeating: 2), scalable: true)
    // The item's own 3 is replaced by its own authored 2 ...
    #expect(length(child.scaleFactors - SIMD3(repeating: 2)) < 0.00001)
    // ... but the parent's 3 still moves the child's world position.
    #expect(length(child.translation - parent.transformPoint(local)) < 0.00001)
    #expect(length(parent.transformPoint(local) - parent.translation) > 1)
}

@Test func nonUniformParentScaleLeavesChildRotationUnsheared() throws {
    let parentRotation = UnityCoordinates.eulerDegrees(SIMD3(0, 40, 15))
    let frame = try SourceStudioWorldTransform.world(parentFrame: Transform.identity,
        localPosition: UnityCoordinates.position(SIMD3(-0.4, 0.3, 0.6)), localRotation: parentRotation,
        localScale: SIMD3(1, 2, 0.5), scalable: true)
    let localRotation = UnityCoordinates.eulerDegrees(SIMD3(10, 70, 25))
    let child = try SourceStudioWorldTransform.world(parentFrame: frame,
        localPosition: UnityCoordinates.position(SIMD3(0.3, 0.6, -0.9)), localRotation: localRotation,
        localScale: .one, scalable: false)
    #expect(angleDegrees(child.rotationQuaternion, parentRotation * localRotation) < 0.001)
}

@Test func worldRejectsNonFiniteAndDegenerateInputs() {
    let rotation = UnityCoordinates.eulerDegrees(SIMD3(10, 20, 30))
    #expect(throws: RigError.self) {
        try SourceStudioWorldTransform.world(parentFrame: Transform.identity,
            localPosition: SIMD3(Float.nan, 0, 0), localRotation: rotation, localScale: .one, scalable: true)
    }
    #expect(throws: RigError.self) {
        try SourceStudioWorldTransform.world(parentFrame: Transform.identity,
            localPosition: SIMD3(1, 2, 3), localRotation: simd_quatf(ix: .infinity, iy: 0, iz: 0, r: 1),
            localScale: .one, scalable: true)
    }
    #expect(throws: RigError.self) {
        try SourceStudioWorldTransform.world(parentFrame: Transform.identity,
            localPosition: SIMD3(1, 2, 3), localRotation: rotation, localScale: SIMD3(2, .nan, 2), scalable: true)
    }
    // A parent frame whose basis columns collapsed (zero or near-zero scale)
    // cannot carry a child position.
    for scale in [SIMD3<Float>.zero, SIMD3(repeating: 1e-7)] {
        let degenerate = Transform.trs(.zero, rotation, scale)
        #expect(throws: RigError.self) {
            try SourceStudioWorldTransform.world(parentFrame: degenerate,
                localPosition: SIMD3(1, 2, 3), localRotation: rotation, localScale: .one, scalable: false)
        }
    }
}

@Test func localRoundTripsWorldAcrossParentFrames() throws {
    let localPosition = UnityCoordinates.position(SIMD3(0.3, 0.6, -0.9))
    let localRotation = UnityCoordinates.eulerDegrees(SIMD3(10, 70, 25))
    let parents: [(name: String, frame: float4x4)] = [
        ("identity", Transform.identity),
        ("rotated-scaled", try SourceStudioWorldTransform.world(parentFrame: Transform.identity,
            localPosition: UnityCoordinates.position(SIMD3(1, 0.5, 2)),
            localRotation: UnityCoordinates.eulerDegrees(SIMD3(0, 40, 15)),
            localScale: SIMD3(repeating: 3), scalable: true)),
        ("non-uniform-scaled", try SourceStudioWorldTransform.world(parentFrame: Transform.identity,
            localPosition: UnityCoordinates.position(SIMD3(-0.4, 0.3, 0.6)),
            localRotation: UnityCoordinates.eulerDegrees(SIMD3(20, 40, 15)),
            localScale: SIMD3(1, 2, 0.5), scalable: true)),
    ]
    for parent in parents {
        let world = try SourceStudioWorldTransform.world(parentFrame: parent.frame, localPosition: localPosition,
            localRotation: localRotation, localScale: SIMD3(repeating: 2), scalable: true)
        // The rotation composes through the scale-free parent rotation, which
        // is what `local` must undo for a non-uniform parent.
        #expect(angleDegrees(world.rotationQuaternion, parent.frame.rotationQuaternion * localRotation) < 0.001,
            "\(parent.name)")
        let restored = try SourceStudioWorldTransform.local(
            world: (world.translation, world.rotationQuaternion), parentFrame: parent.frame)
        #expect(length(restored.position - localPosition) < 0.00001, "\(parent.name)")
        #expect(angleDegrees(restored.rotation, localRotation) < 0.00001, "\(parent.name)")
    }
}

@Test func localRejectsSingularAndNonFiniteFrames() {
    let rotation = UnityCoordinates.eulerDegrees(SIMD3(10, 20, 30))
    for scale in [SIMD3<Float>.zero, SIMD3(repeating: 1e-7)] {
        let degenerate = Transform.trs(.zero, rotation, scale)
        #expect(throws: RigError.self) {
            try SourceStudioWorldTransform.local(world: (SIMD3(1, 2, 3), rotation), parentFrame: degenerate)
        }
    }
    #expect(throws: RigError.self) {
        try SourceStudioWorldTransform.local(world: (SIMD3(Float.nan, 0, 0), rotation), parentFrame: Transform.identity)
    }
    #expect(throws: RigError.self) {
        try SourceStudioWorldTransform.local(world: (SIMD3(1, 2, 3), simd_quatf(ix: .infinity, iy: 0, iz: 0, r: 1)),
            parentFrame: Transform.identity)
    }
    var nonFiniteFrame = Transform.identity
    nonFiniteFrame.columns.3 = Float4(Float.nan, 0, 0, 1)
    #expect(throws: RigError.self) {
        try SourceStudioWorldTransform.local(world: (SIMD3(1, 2, 3), rotation), parentFrame: nonFiniteFrame)
    }
}

@Test func reparentedSourceChildKeepsWorldPoseAndDropsAttachment() throws {
    // A source item hangs under a scalable scale-2 parent, where the Studio
    // rule still moves the child by the parent's scale. Reparenting to the
    // root must keep the world position and rotation, drop a stale attachment
    // point and keep the item's own authored scale.
    let parentFrame = try SourceStudioWorldTransform.world(parentFrame: Transform.identity,
        localPosition: UnityCoordinates.position(SIMD3(1, 0.5, 2)),
        localRotation: UnityCoordinates.eulerDegrees(SIMD3(0, 40, 15)),
        localScale: SIMD3(repeating: 2), scalable: true)
    var child = StudioObject(name: "Source item", kind: .item)
    child.sourceObjectKey = 7; child.sourceRecordKind = .item
    child.transform.position = UnityCoordinates.position(SIMD3(0.3, 0.6, -0.9))
    let localRotation = UnityCoordinates.eulerDegrees(SIMD3(10, 70, 25))
    child.transform.rotation = localRotation.eulerXYZ.radiansToDegrees
    child.transform.rotationOverride = localRotation.vector
    child.transform.scale = SIMD3(repeating: 2)
    child.sourceAttachmentPoint = 17
    let world = try SourceStudioWorldTransform.world(parentFrame: parentFrame,
        localPosition: child.transform.position, localRotation: child.transform.quaternion,
        localScale: child.transform.scale, scalable: true)
    // The parent's scale really moved the child, so the placement is real.
    #expect(length(world.translation - parentFrame.translation) > 1)
    let moved = try SourceStudioWorldTransform.reparented(child, world: world, parentFrame: Transform.identity)
    let worldAfter = try SourceStudioWorldTransform.world(parentFrame: Transform.identity,
        localPosition: moved.transform.position, localRotation: moved.transform.quaternion,
        localScale: moved.transform.scale, scalable: true)
    #expect(length(worldAfter.translation - world.translation) < 0.00001)
    #expect(angleDegrees(worldAfter.rotationQuaternion, world.rotationQuaternion) < 0.001)
    #expect(moved.sourceAttachmentPoint == nil)
    #expect(moved.transform.scale == child.transform.scale)
    #expect(moved.sourceObjectKey == child.sourceObjectKey)
}

@Test func reparentedStoresRotationExactlyAsQuaternionOverride() throws {
    // The import keeps the exact quaternion as `rotationOverride`; the native
    // reparent walk wrote Euler and lost it. Reparenting under the same frame
    // must hand that quaternion back: an Euler-decomposed replacement misses
    // the exact rotation at the 1e-5 degrees asserted here.
    var object = StudioObject(name: "Source child", kind: .folder)
    object.sourceObjectKey = 3
    let localRotation = UnityCoordinates.eulerDegrees(SIMD3(12, 51, 77))
    object.transform.position = UnityCoordinates.position(SIMD3(0.5, 1.5, -2.5))
    object.transform.rotation = localRotation.eulerXYZ.radiansToDegrees
    object.transform.rotationOverride = localRotation.vector
    let parentFrame = try SourceStudioWorldTransform.world(parentFrame: Transform.identity,
        localPosition: UnityCoordinates.position(SIMD3(2, 1, 3)), localRotation: localRotation,
        localScale: SIMD3(repeating: 0.5), scalable: true)
    let world = try SourceStudioWorldTransform.world(parentFrame: parentFrame,
        localPosition: object.transform.position, localRotation: object.transform.quaternion,
        localScale: .one, scalable: false)
    // Reparenting away and back to the same frame keeps the rotation a
    // quaternion: each move stores `local`'s exact product as the override —
    // bit-for-bit, not an Euler-quantised replacement — and the transform
    // answers its rotation from that override, as the import's does.
    let toRoot = try SourceStudioWorldTransform.reparented(object, world: world, parentFrame: Transform.identity)
    let toRootExpected = try SourceStudioWorldTransform.local(
        world: (world.translation, world.rotationQuaternion), parentFrame: Transform.identity).rotation
    #expect(toRoot.transform.rotationOverride == toRootExpected.vector)
    let toRootWorld = try SourceStudioWorldTransform.world(parentFrame: Transform.identity,
        localPosition: toRoot.transform.position, localRotation: toRoot.transform.quaternion,
        localScale: .one, scalable: false)
    #expect(angleDegrees(toRootWorld.rotationQuaternion, world.rotationQuaternion) < 0.001)
    let back = try SourceStudioWorldTransform.reparented(toRoot, world: toRootWorld, parentFrame: parentFrame)
    let backExpected = try SourceStudioWorldTransform.local(
        world: (toRootWorld.translation, toRootWorld.rotationQuaternion), parentFrame: parentFrame).rotation
    let override = try #require(back.transform.rotationOverride)
    #expect(override == backExpected.vector)
    #expect(back.transform.quaternion == simd_quatf(vector: override))
    // Back under the original frame the rotation agrees with the authored one
    // to float32 matrix-extraction accuracy (the same ~0.09° noise source the
    // fixture helper above documents), never to Euler-quantisation accuracy.
    #expect(angleDegrees(back.transform.quaternion, localRotation) < 0.05)
}
