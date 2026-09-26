import Foundation
import Testing
import simd
import CoreMath
import Scene
import Character

private func faceRig(parentScale: Float3 = .one) throws -> RigDefinition {
    let parent = RigDefinition.Node(name: "head_parent", sourceID: "root", parent: nil,
                                    translation: Float3(3, 4, 5),
                                    rotation: UnityCoordinates.eulerDegrees(Float3(17, 23, 31)), scale: parentScale)
    let targets = SourceFaceShapePose.destinationNames.enumerated().map { index, name in
        RigDefinition.Node(name: name, sourceID: "target-\(index)", parent: 0,
                           translation: Float3(10, 20, 30),
                           rotation: UnityCoordinates.eulerDegrees(Float3(13, 29, 37)),
                           scale: Float3(0.9, 1.1, 1.3))
    }
    return try RigDefinition(nodes: [parent] + targets, skins: [])
}

private func faceState() -> [String: SourceShapeTransform] {
    Dictionary(uniqueKeysWithValues: SourceFaceShapePose.destinationNames.map {
        ($0, SourceShapeTransform(position: Float3(2, 3, 4), rotationDegrees: Float3(11, 19, 41), scale: Float3(1.2, 1.4, 1.6)))
    })
}

private func closeMatrix(_ a: float4x4, _ b: float4x4, tolerance: Float = 2e-5) -> Bool {
    (0..<4).allSatisfy { column in (0..<4).allSatisfy { row in abs(a[column][row] - b[column][row]) < tolerance } }
}

@Test func sourceFaceMasksPreserveRestAxesAndApplyExplicitUnitAxes() throws {
    let rig = try faceRig(), state = faceState()
    let pose = try SourceFaceShapePose.make(rig: rig, state: state)
    #expect(SourceFaceShapePose.destinationNames.count == 59)
    let zOnly = try rig.uniqueNode(named: "cf_J_Nose_tip")
    #expect(closeMatrix(pose.localMatrices[zOnly], Transform.trs(Float3(10, 20, -4), rig.nodes[zOnly].rotation, Float3(0.9, 1.1, 1.3))))
    let cheek = try rig.uniqueNode(named: "cf_J_CheekUp2_L")
    #expect(closeMatrix(pose.localMatrices[cheek], Transform.trs(Float3(2, 20, -4), rig.nodes[cheek].rotation, Float3(1.2, 1, 1))))
    let eye = try rig.uniqueNode(named: "cf_J_Eye_rz_R")
    #expect(closeMatrix(pose.localMatrices[eye], Transform.trs(Float3(2, 20, 30), rig.nodes[eye].rotation, Float3(1.2, 1.4, 1))))
    let chin = try rig.uniqueNode(named: "cf_J_ChinLow")
    #expect(closeMatrix(pose.localMatrices[chin], Transform.trs(Float3(10, 3, 30), rig.nodes[chin].rotation, Float3(1.2, 1.4, 1.6))))
}

@Test func sourceFaceUsesIndependentSidesAndAbsoluteUnityRotations() throws {
    let rig = try faceRig()
    var state = faceState()
    state["cf_J_Eye_tx_R"]!.rotationDegrees = Float3(-99, 123, -23)
    let pose = try SourceFaceShapePose.make(rig: rig, state: state)
    let left = try rig.uniqueNode(named: "cf_J_Eye_tx_L"), right = try rig.uniqueNode(named: "cf_J_Eye_tx_R")
    #expect(closeMatrix(pose.localMatrices[left], Transform.trs(Float3(10, 3, 30), UnityCoordinates.eulerDegrees(Float3(0, 0, 41)), Float3(0.9, 1.1, 1.3))))
    #expect(closeMatrix(pose.localMatrices[right], Transform.trs(Float3(10, 3, 30), UnityCoordinates.eulerDegrees(Float3(0, 0, -23)), Float3(0.9, 1.1, 1.3))))
    let ear = try rig.uniqueNode(named: "cf_J_EarBase_ry_L")
    #expect(closeMatrix(pose.localMatrices[ear], Transform.trs(Float3(10, 20, 30), UnityCoordinates.eulerDegrees(Float3(0, 19, 41)), Float3(1.2, 1.4, 1.6))))
}

@Test func sourceFaceHeadCorrectionUsesCurrentParentScaleAndBoneType() throws {
    let rig = try faceRig()
    var state = faceState(); state["cf_J_FaceBase"]!.scale.x = 1
    var base = rig.restPose
    base.localMatrices[0] = Transform.trs(Float3(7, 8, 9), rig.nodes[0].rotation, Float3(2, 3, 4))
    let head = try rig.uniqueNode(named: "cf_J_FaceBase")
    let normal = try SourceFaceShapePose.make(rig: rig, state: state, basePose: base, headCorrection: 0.8)
    #expect(closeMatrix(normal.localMatrices[head], Transform.trs(rig.nodes[head].translation, rig.nodes[head].rotation, Float3(1.5, 1, 0.75))))
    let corrected = try SourceFaceShapePose.make(rig: rig, state: state, basePose: base, boneType: 1, headCorrection: 0.8)
    #expect(closeMatrix(corrected.localMatrices[head], Transform.trs(rig.nodes[head].translation, rig.nodes[head].rotation, Float3(1.2, 0.8, 0.6))))
    #expect(closeMatrix(corrected.localMatrices[0], base.localMatrices[0]))
}

@Test func sourceFaceReapplyRetainsIncomingUnassignedChannelsWithoutAccumulation() throws {
    let rig = try faceRig(), state = faceState()
    let first = try SourceFaceShapePose.make(rig: rig, state: state)
    var edited = first
    let nose = try rig.uniqueNode(named: "cf_J_Nose_tip")
    edited.localMatrices[nose] = Transform.trs(Float3(888, 999, -555), .identity, Float3(3, 4, 5))
    let composed = try SourceFaceShapePose.make(rig: rig, state: state, basePose: edited)
    #expect(closeMatrix(composed.localMatrices[nose], Transform.trs(Float3(888, 999, -4), .identity, Float3(3, 4, 5))))
    for i in rig.nodes.indices where i != nose { #expect(closeMatrix(first.localMatrices[i], composed.localMatrices[i])) }
    let repeated = try SourceFaceShapePose.make(rig: rig, state: state, basePose: composed)
    #expect(zip(composed.localMatrices, repeated.localMatrices).allSatisfy { closeMatrix($0, $1) })
}

@Test func sourceFaceCompositionPreservesOnlyChannelsTheSourceLeavesUntouched() throws {
    let rig = try faceRig(), state = faceState()
    let incomingPosition = Float3(13, 23, 33), incomingScale = Float3(2, 3, 4)
    let incomingRotation = UnityCoordinates.eulerDegrees(Float3(7, 21, -14))
    var base = rig.restPose
    for index in 1..<rig.nodes.count { base.localMatrices[index] = Transform.trs(incomingPosition, incomingRotation, incomingScale) }
    let result = try SourceFaceShapePose.make(rig: rig, state: state, basePose: base)
    let expectations: [(String, Float3, simd_quatf, Float3)] = [
        ("cf_J_FaceBase", incomingPosition, incomingRotation, Float3(1.2, 1, 1)),
        ("cf_J_Nose_tip", Float3(13, 23, -4), incomingRotation, incomingScale),
        ("cf_J_MayuMid_s_L", incomingPosition, UnityCoordinates.eulerDegrees(Float3(0, 0, 41)), incomingScale),
        ("cf_J_CheekUp2_L", Float3(2, 23, -4), incomingRotation, Float3(1.2, 1, 1)),
        ("cf_J_EarBase_ry_L", incomingPosition, UnityCoordinates.eulerDegrees(Float3(0, 19, 41)), Float3(1.2, 1.4, 1.6)),
        ("cf_J_Eye_tx_L", Float3(13, 3, 33), UnityCoordinates.eulerDegrees(Float3(0, 0, 41)), incomingScale),
    ]
    for (name, position, rotation, scale) in expectations {
        let index = try rig.uniqueNode(named: name)
        #expect(closeMatrix(result.localMatrices[index], Transform.trs(position, rotation, scale)), "Source face assignments for \(name)")
    }
    #expect(closeMatrix(result.localMatrices[0], base.localMatrices[0]))
}

@Test func sourceFaceRejectsIncompleteStateAndUnsupportedParentTransforms() throws {
    let rig = try faceRig()
    var state = faceState(); state.removeValue(forKey: "cf_J_MouthLow")
    #expect(throws: SourceShapeError.self) { try SourceFaceShapePose.make(rig: rig, state: state) }
    state = faceState(); state["cf_J_MouthLow"]!.position.z = .nan
    #expect(throws: SourceShapeError.self) { try SourceFaceShapePose.make(rig: rig, state: state) }
    state = faceState()
    var base = rig.restPose
    for scale in [Float3(0, 1, 1), Float3(-1, 1, 1)] {
        base.localMatrices[0] = Transform.trs(.zero, .identity, scale)
        #expect(throws: RigError.self) { try SourceFaceShapePose.make(rig: rig, state: state, basePose: base) }
    }
    base.localMatrices[0] = matrix_identity_float4x4; base.localMatrices[0][1].x = 0.1
    #expect(throws: RigError.self) { try SourceFaceShapePose.make(rig: rig, state: state, basePose: base) }
    #expect(throws: RigError.self) { try SourceFaceShapePose.make(rig: rig, state: state, headCorrection: .infinity) }
    let missing = try RigDefinition(nodes: Array(rig.nodes.dropLast()), skins: [])
    #expect(throws: RigError.self) { try SourceFaceShapePose.make(rig: missing, state: state) }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_HEAD_RIG", "IKKOKU_SHAPE_CONTRACT"]),
               "Requires IKKOKU_HEAD_RIG, IKKOKU_SHAPE_CONTRACT"))
func sourceFaceLoadsLocalRecoveredHeadWhenRequested() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_HEAD_RIG")
    let contractPath = try SourceFixtureSupport.require("IKKOKU_SHAPE_CONTRACT")
    let source = try SourceRig.load(url: URL(fileURLWithPath: path))
    let contract = try SourceShapeContract.decode(Data(contentsOf: URL(fileURLWithPath: contractPath)))
    let face = try #require(contract.domain("face"))
    #expect(face.valueCount == 52)
    for rate: Float in [0, 0.5, 1] {
        let pose = try SourceFaceShapePose.make(rig: source.rig, domain: face, values: Array(repeating: rate, count: face.valueCount))
        let evaluation = try source.rig.evaluate(pose)
        #expect(evaluation.palettes.count == source.rig.skins.count)
        #expect(evaluation.worldMatrices.count == source.rig.nodes.count)
    }
    let defaults = try SourceFaceShapePose.make(rig: source.rig, domain: face)
    #expect(defaults.localMatrices.count == source.rig.nodes.count)
}
