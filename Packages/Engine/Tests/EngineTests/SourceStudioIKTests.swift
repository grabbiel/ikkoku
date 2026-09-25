import Foundation
import Testing
import simd
import CoreMath
import Scene
@testable import Studio

private func studioIKFixture(scale: Float3 = .one) throws -> (RigDefinition, SourceStudioIK.Bindings) {
    var nodes = [RigDefinition.Node(name: "root", sourceID: "n0", parent: nil)]
    func ref(_ index: Int) -> [String: Any] { ["sourceID": "n\(index)", "name": nodes[index].name] }
    var targets: [[String: Any]] = [["id": 0, "group": "body", "rotationEnabled": false, "prefabTarget": ref(0)]]
    var limbs: [[String: Any]] = []
    for (index, group) in ["leftArm", "rightArm", "leftLeg", "rightLeg"].enumerated() {
        let root = nodes.count
        nodes.append(.init(name: group + "Root", sourceID: "n\(root)", parent: 0, translation: Float3(Float(index) * 4, 0, 0), scale: index == 0 ? scale : .one))
        nodes.append(.init(name: group + "Middle", sourceID: "n\(root + 1)", parent: root, translation: Float3(1, 0.5, 0)))
        nodes.append(.init(name: group + "End", sourceID: "n\(root + 2)", parent: root + 1, translation: Float3(1, -0.5, 0)))
        for offset in 0..<3 {
            targets.append(["id": index * 3 + offset + 1, "group": group, "rotationEnabled": offset == 2, "prefabTarget": ref(root + offset)])
        }
        limbs.append(["group": group, "targetIDs": [index * 3 + 1, index * 3 + 2, index * 3 + 3], "nodes": [ref(root), ref(root + 1), ref(root + 2)]])
    }
    let data: [String: Any] = ["schemaVersion": 1, "root": ref(0), "pelvis": ref(0), "body": ref(0), "iterations": 4,
                               "pullBodyVertical": 0.5, "pullBodyHorizontal": 0, "targets": targets, "limbs": limbs]
    return (try RigDefinition(nodes: nodes, skins: []), try JSONDecoder().decode(SourceStudioIK.Bindings.self, from: JSONSerialization.data(withJSONObject: data)))
}

@Test func sourceStudioIKRestoresGuidesAndMovesEnabledLimbWithoutIdentityRewrite() throws {
    let (rig, bindings) = try studioIKFixture()
    let solver = try SourceStudioIK(rig: rig, bindings: bindings)
    let transform = KoikatsuChangeAmount(position: Float3(1.5, 0.8, -0.2), rotationDegrees: Float3(10, 20, 30), scale: Float3(repeating: 100))
    let saved = [Int32(3): KoikatsuBoneRecord(sourceKey: 12345, transform: transform)]
    let result = try solver.apply(rig: rig, baseline: rig.restPose, savedTargets: saved, enabled: true, activeGroups: [false, false, false, false, true], characterRoot: 0)
    #expect(result.appliedTargetIDs == [2, 3])
    #expect(result.deferredTargetIDs == [1])
    let guide = try #require(result.guides.first { $0.targetID == 3 })
    #expect(guide.sourceKey == 12345)
    #expect(guide.position == Float3(1.5, 0.8, 0.2))
    #expect(guide.rotationEnabled && guide.active)
    let matrices = try rig.evaluate(result.pose).worldMatrices
    #expect(simd_distance(Float3(matrices[3][3].x, matrices[3][3].y, matrices[3][3].z), guide.position) < 0.00001)
    let expected = UnityCoordinates.eulerDegrees(transform.rotationDegrees)
    #expect(abs(simd_dot(simd_quatf(matrices[3]).normalized.vector, expected.vector)) > 0.99999)
    for node in 4..<rig.nodes.count { #expect(result.pose.localMatrices[node] == rig.restPose.localMatrices[node]) }
    let repeated = try solver.apply(rig: rig, baseline: rig.restPose, savedTargets: saved, enabled: true, activeGroups: [false, false, false, false, true], characterRoot: 0)
    #expect(repeated.pose.localMatrices == result.pose.localMatrices)
}

@Test func sourceStudioIKDisabledKeepsPoseAndGuideOverrideRetainsDictionaryKey() throws {
    let (rig, bindings) = try studioIKFixture()
    let solver = try SourceStudioIK(rig: rig, bindings: bindings)
    let old = KoikatsuChangeAmount(position: .zero, rotationDegrees: .zero, scale: .one)
    let edited = KoikatsuChangeAmount(position: Float3(3, 4, 5), rotationDegrees: Float3(25, 0, 0), scale: .one)
    let result = try solver.apply(rig: rig, baseline: rig.restPose, savedTargets: [2: .init(sourceKey: 777, transform: old)], enabled: false,
        activeGroups: [true, true, true, true, true], characterRoot: 0, guideOverrides: [2: edited])
    #expect(result.pose.localMatrices == rig.restPose.localMatrices)
    #expect(result.appliedTargetIDs.isEmpty)
    let guide = try #require(result.guides.first { $0.targetID == 2 })
    #expect(guide.sourceKey == 777 && !guide.active && !guide.rotationEnabled)
    #expect(guide.position == Float3(3, 4, -5))
    #expect(guide.rotation.vector == simd_quatf.identity.vector)
}

@Test func sourceStudioIKRejectsNonuniformLimbWithoutPartialMutation() throws {
    let (rig, bindings) = try studioIKFixture(scale: Float3(2, 1, 1))
    let solver = try SourceStudioIK(rig: rig, bindings: bindings)
    let result = try solver.apply(rig: rig, baseline: rig.restPose, savedTargets: [:], enabled: true,
        activeGroups: [false, false, false, false, true], characterRoot: 0)
    #expect(result.pose.localMatrices == rig.restPose.localMatrices)
    #expect(result.appliedTargetIDs.isEmpty)
    #expect(result.deferredTargetIDs == [1, 2, 3])
    #expect(result.diagnostics.contains { $0.contains("nonuniform") })
}

@Test func sourceStudioIKBodyPullKeepsSequentialSourceOrder() throws {
    // Left contributes (2,0,0). Right sees its root shifted by that contribution,
    // so its target is now within reach: a symmetric sum would incorrectly be 4.
    let value = try SourceStudioIK.handBodyPull(leftRoot: .zero, leftTarget: Float3(4, 0, 0), leftLength: 2, leftWeight: 1,
        rightRoot: .zero, rightTarget: Float3(4, 0, 0), rightLength: 2, rightWeight: 1, up: Float3(0, 1, 0), vertical: 0.5, horizontal: 1)
    #expect(simd_distance(value, Float3(2, 0, 0)) < 0.000001)
    let vertical = try SourceStudioIK.handBodyPull(leftRoot: .zero, leftTarget: Float3(0, 4, 0), leftLength: 2, leftWeight: 1,
        rightRoot: .zero, rightTarget: Float3(0, 4, 0), rightLength: 2, rightWeight: 1, up: Float3(0, 1, 0), vertical: 0.5, horizontal: 0)
    #expect(simd_distance(vertical, Float3(0, 1, 0)) < 0.000001)
    #expect(throws: (any Error).self) {
        try SourceStudioIK.handBodyPull(leftRoot: .zero, leftTarget: .zero, leftLength: 0, leftWeight: 1,
            rightRoot: .zero, rightTarget: .zero, rightLength: 2, rightWeight: 1, up: Float3(0, 1, 0), vertical: 0.5, horizontal: 0)
    }
}

@Test func sourceStudioIKRejectsChangedRigAndNonfiniteGuides() throws {
    let (rig, bindings) = try studioIKFixture()
    let solver = try SourceStudioIK(rig: rig, bindings: bindings)
    #expect(throws: (any Error).self) {
        try solver.apply(rig: rig, baseline: rig.restPose, savedTargets: [:], enabled: false, activeGroups: [], characterRoot: 0)
    }
    #expect(throws: (any Error).self) {
        try solver.apply(rig: rig, baseline: rig.restPose, savedTargets: [:], enabled: false, activeGroups: [true, true, true, true, true], characterRoot: 0,
            guideOverrides: [3: .init(position: Float3(.nan, 0, 0), rotationDegrees: .zero, scale: .one)])
    }
}

@Test func sourceStudioIKOriginalBindingsBindAndReportActualCoverage() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["IKKOKU_SOURCE_AVATAR"], let bindingPath = env["IKKOKU_STUDIO_IK_BINDINGS"] else { return }
    let source = try SourceRig.loadModel(url: URL(fileURLWithPath: path))
    let bindings = try JSONDecoder().decode(SourceStudioIK.Bindings.self, from: Data(contentsOf: URL(fileURLWithPath: bindingPath)))
    let solver = try SourceStudioIK(rig: source.rig, bindings: bindings)
    let result = try solver.apply(rig: source.rig, baseline: source.rig.restPose, savedTargets: [:], enabled: true,
        activeGroups: [true, true, true, true, true], characterRoot: 0)
    #expect(result.guides.count == 13)
    #expect(bindings.schemaVersion == 2)
    #expect(result.deferredTargetIDs.isEmpty)
    #expect(result.appliedTargetIDs == Set((0...12).map(Int32.init)))
    #expect(result.diagnostics.isEmpty)
    _ = try source.rig.evaluate(result.pose)
}
