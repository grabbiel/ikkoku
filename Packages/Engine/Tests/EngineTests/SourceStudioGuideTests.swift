import Testing
import simd
import CoreMath
import Scene
import Studio

@Test func sourceStudioGuideComposesRotationsAcrossNonuniformScale() throws {
    let parent = UnityCoordinates.eulerDegrees(Float3(14, 27, -9))
    let child = UnityCoordinates.eulerDegrees(Float3(23, -31, 47))
    let rig = try RigDefinition(nodes: [
        .init(name: "parent", sourceID: "parent", parent: nil, rotation: parent, scale: Float3(2, 0.7, 1.5)),
        .init(name: "child", sourceID: "child", parent: 0, translation: Float3(1, 2, 3), rotation: child, scale: Float3(0.8, 1.3, 1.1))
    ], skins: [])
    let result = try SourceStudioGuide.rotation(node: 1, rig: rig, pose: rig.restPose)
    let expected = (parent * child).normalized
    #expect(abs(dot(result.vector, expected.vector)) > 0.999999)
    let world = try rig.evaluate(rig.restPose).worldMatrices[1]
    let a = normalize(Float3(world[0].x, world[0].y, world[0].z)), b = normalize(Float3(world[1].x, world[1].y, world[1].z))
    #expect(abs(dot(a, b)) > 0.1) // This fixture actually produces world shear.
    // A zero drag must preserve the original local rotation and source Euler edit.
    let recoveredLocal = (parent.inverse * result).normalized
    let written = UnityCoordinates.eulerDegrees(UnityCoordinates.sourceEulerDegrees(recoveredLocal))
    #expect(abs(dot(child.vector, written.vector)) > 0.999999)
}

@Test func sourceStudioGuideUsesEditedLocalPoseAndRejectsLocalShear() throws {
    let rig = try RigDefinition(nodes: [
        .init(name: "root", sourceID: "r", parent: nil, scale: Float3(2, 3, 1)),
        .init(name: "child", sourceID: "c", parent: 0)
    ], skins: [])
    var pose = rig.restPose
    let changed = UnityCoordinates.eulerDegrees(Float3(-41, 62, 19))
    pose.localMatrices[1] = Transform.trs(.zero, changed, Float3(3, 1, 2))
    #expect(abs(dot(try SourceStudioGuide.rotation(node: 1, rig: rig, pose: pose).vector, changed.vector)) > 0.999999)
    pose.localMatrices[1] = matrix_identity_float4x4
    pose.localMatrices[1][1].x = 0.5
    #expect(throws: RigError.self) { try SourceStudioGuide.rotation(node: 1, rig: rig, pose: pose) }
    #expect(throws: RigError.self) { try SourceStudioGuide.rotation(node: 20, rig: rig, pose: rig.restPose) }
}

@Test func sourceStudioGuideRejectsAmbiguousSignedAndMatrixAuthoredRotation() throws {
    // Two negative axes retain a positive determinant, so determinant-only
    // decomposition would invent a half-turn that Unity's stored rotation lacks.
    for parent in [
        RigDefinition.Node(name: "signed", sourceID: "r", parent: nil, scale: Float3(-1, -1, 1)),
        RigDefinition.Node(name: "matrix", sourceID: "r", parent: nil, authoredMatrix: matrix_identity_float4x4)
    ] {
        let rig = try RigDefinition(nodes: [parent, .init(name: "child", sourceID: "c", parent: 0)], skins: [])
        #expect(throws: RigError.self) { try SourceStudioGuide.rotation(node: 1, rig: rig, pose: rig.restPose) }
    }
}
