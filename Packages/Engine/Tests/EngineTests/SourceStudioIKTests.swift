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

/// `RigDefinition.isFiniteAffine` became four-lane (2026-11-17). The IK pass
/// still rejects a non-finite or projective baseline local matrix, with
/// `rig.evaluate`'s message, whether IK is on (a limb solve) or off.
@Test func sourceStudioIKRejectsNonfiniteBaselineMatrices() throws {
    let (rig, bindings) = try studioIKFixture()
    let solver = try SourceStudioIK(rig: rig, bindings: bindings)
    // Typed: CI's Swift 6.3.3 mis-infers untyped numeric literals in tuple arrays.
    let bad: [(Int, Int, Float)] = [(0, 0, .nan), (3, 1, .infinity), (2, 2, -.infinity), (0, 3, 0.25), (3, 3, 1.5)]
    for enabled in [false, true] {
        for (column, row, value) in bad {
            var baseline = rig.restPose
            baseline.localMatrices[5][column][row] = value
            do {
                _ = try solver.apply(rig: rig, baseline: baseline, savedTargets: [:], enabled: enabled,
                                     activeGroups: [true, true, true, true, true], characterRoot: 0)
                Issue.record("enabled \(enabled) [\(column)][\(row)] = \(value) was accepted")
            } catch {
                #expect("\(error)" == "Pose node 5 has an invalid matrix.", "enabled \(enabled) [\(column)][\(row)]")
            }
        }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_IK_BINDINGS"]),
               "Requires IKKOKU_SOURCE_AVATAR, IKKOKU_STUDIO_IK_BINDINGS"))
func sourceStudioIKOriginalBindingsBindAndReportActualCoverage() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR")
    let bindingPath = try SourceFixtureSupport.require("IKKOKU_STUDIO_IK_BINDINGS")
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

/// Every float of an IK result as a bit pattern, with its guides, target sets
/// and diagnostics, so two results compare exactly (a signed zero counts).
private func resultBits(_ result: SourceStudioIK.Result) -> [String] {
    func bits(_ values: [Float]) -> String { values.map { String($0.bitPattern, radix: 16) }.joined(separator: ",") }
    let pose = result.pose.localMatrices.map { m in bits((0..<4).flatMap { c in (0..<4).map { m[c][$0] } }) }
    let guides = result.guides.map { g in
        "\(g.targetID) \(String(describing: g.sourceKey)) \(g.group) \(g.rotationEnabled) \(g.active) "
            + bits([g.position.x, g.position.y, g.position.z, g.rotation.vector.x, g.rotation.vector.y, g.rotation.vector.z, g.rotation.vector.w])
    }
    return pose + guides + [result.appliedTargetIDs.sorted().description, result.deferredTargetIDs.sorted().description,
                            bits([result.bodyPullOffset.x, result.bodyPullOffset.y, result.bodyPullOffset.z])] + result.diagnostics
}

/// #371: `apply` skips the node comparison only for the rig the solver was
/// built for (`RigDefinition.Identity` guarantees the same nodes). A rig with
/// another identity still gets today's full comparison: with equal source IDs
/// and parents it passes and solves bit for bit as the built-for rig, and with
/// a changed node list it fails with today's message.
@Test func sourceStudioIKSkipsTheNodeComparisonOnlyForItsOwnRig() throws {
    let (rig, bindings) = try studioIKFixture()
    let solver = try SourceStudioIK(rig: rig, bindings: bindings)
    let saved = [Int32(3): KoikatsuBoneRecord(sourceKey: 12345, transform: KoikatsuChangeAmount(position: Float3(1.5, 0.8, -0.2),
                                                                                              rotationDegrees: Float3(10, 20, 30), scale: Float3(repeating: 100)))]
    func run(_ query: RigDefinition) throws -> SourceStudioIK.Result {
        try solver.apply(rig: query, baseline: query.restPose, savedTargets: saved, enabled: true,
                         activeGroups: [false, true, false, false, true], characterRoot: 0)
    }
    func node(_ index: Int, name: String? = nil, sourceID: String? = nil, parent: Int?? = nil) -> RigDefinition.Node {
        let n = rig.nodes[index]
        return .init(name: name ?? n.name, sourceID: sourceID ?? n.sourceID, parent: parent ?? n.parent, translation: n.translation,
                     rotation: n.rotation, scale: n.scale, authoredMatrix: n.authoredMatrix, active: n.active)
    }
    func variant(_ index: Int, _ replacement: RigDefinition.Node) throws -> RigDefinition {
        var nodes = rig.nodes.indices.map { node($0) }
        nodes[index] = replacement
        return try RigDefinition(nodes: nodes, skins: rig.skins)
    }

    // The rig it was built for, and a copy of that rig value: the identity path.
    let reference = try resultBits(run(rig))
    let copy = rig
    for same in [rig, copy] {
        #expect(solver.checked === same.identity)
        #expect(solver.bound(to: same) && solver.walkMatches(same))
        #expect(try resultBits(run(same)) == reference)
    }

    // Other identities with equal source IDs and parents (a rebuilt twin, and
    // one with a node renamed, which the comparison has never read): the full
    // comparison runs and passes, and the solve is the same bit for bit.
    let equal = [try RigDefinition(nodes: rig.nodes, skins: rig.skins), try variant(7, node(7, name: "renamed"))]
    for other in equal {
        #expect(other.identity !== solver.checked)
        #expect(solver.walkMatches(other) && solver.bound(to: other))
        #expect(try resultBits(run(other)) == reference)
    }

    // Changed node lists: a source ID, a parent, one node more, one fewer.
    var longer = rig.nodes.indices.map { node($0) }
    longer.append(.init(name: "extra", sourceID: "n13", parent: 0))
    let changed = [try variant(5, node(5, sourceID: "n5b")), try variant(4, node(4, parent: .some(1))),
                   try RigDefinition(nodes: longer, skins: rig.skins), try RigDefinition(nodes: Array(rig.nodes.dropLast()), skins: rig.skins)]
    for other in changed {
        #expect(!solver.walkMatches(other) && !solver.bound(to: other))
        do {
            _ = try run(other)
            Issue.record("a changed node list was accepted")
        } catch {
            #expect("\(error)" == "Studio IK frame does not match its bound hierarchy or activation state.")
        }
    }

    // The skip never changes the answer: for every rig above, `bound(to:)` is
    // the comparison `apply` made before #371.
    for query in [rig, copy] + equal + changed { #expect(solver.bound(to: query) == solver.walkMatches(query)) }
}
