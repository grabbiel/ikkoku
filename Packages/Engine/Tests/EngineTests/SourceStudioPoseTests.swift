import Foundation
import Testing
import simd
import CoreMath
import Scene
import Studio

private func studioPoseRig() throws -> RigDefinition {
    var nodes = [RigDefinition.Node(name: "root", sourceID: "root", parent: nil)]
    for name in ["hair", "neck", "breast", "body", "rightHand", "leftHand", "skirt"] {
        nodes.append(.init(name: name, sourceID: name, parent: 0,
                           translation: Float3(1.25, -2.5, 3.75),
                           rotation: UnityCoordinates.eulerDegrees(Float3(10, 20, 30)), scale: Float3(0.5, 2, 3)))
    }
    return try RigDefinition(nodes: nodes, skins: [])
}

private func studioPoseController(_ rig: RigDefinition) throws -> SourceStudioPose {
    let categories = [7, 10, 11, 0, 5, 6, 13]
    return try SourceStudioPose(rig: rig, bones: categories.enumerated().map {
        .init(id: $0.offset, name: rig.nodes[$0.offset + 1].name, group: $0.element, level: 0)
    }, characterRoot: 0, hairRoot: 0, sex: 1, neckLookPattern: 2)
}

private func studioPoseNear(_ actual: float4x4, _ expected: float4x4, tolerance: Float = 0.00002) {
    for c in 0..<4 { for r in 0..<4 { #expect(abs(actual[c][r] - expected[c][r]) < tolerance) } }
}

@Test func sourceStudioPoseGroupMappingsAndPreferences() throws {
    for source in 0...4 {
        let bone = SourceStudioPose.Bone(id: source, name: "body", group: source, level: 0)
        #expect(bone.fkGroup == .body)
        #expect(bone.guideGroup.rawValue == 1 | (1 << source))
    }
    let rig = try studioPoseRig()
    var controller = try studioPoseController(rig)
    #expect(controller.activeFK == [false, true, false, true, false, false, false])
    #expect(controller.activeIK == [true, true, true, true, true])
    #expect(!controller.enableFK && !controller.enableIK)
    #expect(controller.targets.allSatisfy { $0.enabled })
    let change = controller.activateFK(mask: .rightHand, active: true)
    #expect(change.effects.isEmpty && change.identityResetNodes.isEmpty)
    #expect(controller.activeFK[4])
    #expect(try controller.applyingLateUpdate(rig: rig, pose: rig.restPose).localMatrices == rig.restPose.localMatrices)
}

@Test func sourceStudioPoseAbsoluteRotationPreservesFrameTranslationAndScale() throws {
    let rig = try studioPoseRig()
    var controller = try studioPoseController(rig)
    _ = controller.activateMode(.fk, active: true)
    try controller.setRotation(boneID: 3, degrees: Float3(90, 90, 0))
    let result = try controller.applyingLateUpdate(rig: rig, pose: rig.restPose)
    // Independent source Ry90 * Rx90, conjugated by Z reflection.
    let expected = float4x4(columns: (Float4(0, 0, 0.5, 0), Float4(2, 0, 0, 0),
                                     Float4(0, 3, 0, 0), Float4(1.25, -2.5, 3.75, 1)))
    studioPoseNear(result.localMatrices[4], expected)
    #expect(result.localMatrices[1] == rig.restPose.localMatrices[1])
    let repeated = try controller.applyingLateUpdate(rig: rig, pose: result)
    studioPoseNear(repeated.localMatrices[4], expected)
    var upstream = rig.restPose
    upstream.localMatrices[4] = Transform.trs(Float3(5, 6, 7), .identity, Float3(1, 2, 4))
    let updated = try controller.applyingLateUpdate(rig: rig, pose: upstream)
    #expect(updated.localMatrices[4][3] == Float4(5, 6, 7, 1))
    #expect(abs(simd_length(updated.localMatrices[4][2]) - 4) < 0.00001)
}

@Test func sourceStudioPoseDisableResetOnlyChangesReactiveGroupsOnce() throws {
    let rig = try studioPoseRig()
    var controller = try studioPoseController(rig)
    let all = SourceStudioPose.Group.fkParts.reduce(SourceStudioPose.Group()) { $0.union($1) }
    let reset = controller.activateFK(mask: all, active: false, force: true)
    #expect(reset.identityResetNodes == [1, 4, 7])
    #expect(controller.activeFK == [false, true, false, true, false, false, false])
    let result = try controller.applying(reset, rig: rig, pose: rig.restPose)
    for index in [1, 4, 7] {
        studioPoseNear(result.localMatrices[index], Transform.trs(Float3(1.25, -2.5, 3.75), .identity, Float3(0.5, 2, 3)))
    }
    for index in [2, 3, 5, 6] { #expect(result.localMatrices[index] == rig.restPose.localMatrices[index]) }
    #expect(controller.activateFK(mask: all, active: false, force: true).identityResetNodes.isEmpty)
}

@Test func sourceStudioPoseForcedNeckCapturesCurrentStateAgain() throws {
    let rig = try studioPoseRig()
    var controller = try studioPoseController(rig)
    _ = controller.activateFK(mask: .neck, active: true, force: true)
    #expect(controller.neckLookPattern == 4 && controller.previousNeckLookPattern == 2)
    _ = controller.activateFK(mask: .neck, active: true, force: true)
    #expect(controller.previousNeckLookPattern == 4)
    let off = controller.activateFK(mask: .neck, active: false, force: true)
    #expect(controller.neckLookPattern == 4)
    #expect(off.effects.first == .neckLookPattern(4))
    #expect(controller.activeFK[1])
}

@Test func sourceStudioPoseKinematicExclusivityAndIKOffWeights() throws {
    let rig = try studioPoseRig()
    var controller = try studioPoseController(rig)
    #expect(controller.activateIK(mask: .rightArm, active: false).effects == [
        .ikWeights(group: .rightArm, weight: 0), .ikGuide(group: .rightArm, active: false)])
    #expect(controller.activateIK(mask: .rightArm, active: true).effects == [
        .ikWeights(group: .rightArm, weight: 1), .ikGuide(group: .rightArm, active: false)])
    _ = controller.activateMode(.fk, active: true)
    #expect(controller.enableFK && !controller.enableIK)
    _ = controller.activateMode(.ik, active: true)
    #expect(!controller.enableFK && controller.enableIK)
    #expect(controller.activeFK == [false, true, false, true, false, false, false])
    #expect(controller.targets.allSatisfy { !$0.enabled })
    #expect(try controller.setPVEnabled([true, false, false, true]) == .pvCopy([true, false, false, true]))
    #expect(throws: RigError.self) { try controller.setPVEnabled([true]) }
}

@Test func sourceStudioPoseSearchIsDepthFirstScopedAndIgnoresActiveFlags() throws {
    let rig = try RigDefinition(nodes: [
        .init(name: "root", sourceID: "0", parent: nil),
        .init(name: "branch", sourceID: "1", parent: 0, active: false),
        .init(name: "same", sourceID: "2", parent: 0),
        .init(name: "same", sourceID: "3", parent: 1),
        .init(name: "hairRoot", sourceID: "4", parent: 0),
        .init(name: "same", sourceID: "5", parent: 4),
    ], skins: [])
    let catalog: [SourceStudioPose.Bone] = [
        .init(id: 0, name: "same", group: 0, level: 0), .init(id: 1, name: "same", group: 7, level: 0),
        .init(id: 2, name: "missing", group: 0, level: 0),
    ]
    let controller = try SourceStudioPose(rig: rig, bones: catalog, characterRoot: 0, hairRoot: 4, sex: 1)
    #expect(controller.targets.map(\.node) == [3, 5])
    let noHair = try SourceStudioPose(rig: rig, bones: catalog, characterRoot: 0, sex: 1)
    #expect(noHair.targets.map(\.node) == [3])
    let outsideBody = [SourceStudioPose.Bone(id: 8, name: "branch", group: 0, level: 0)]
    let fresh = try SourceStudioPose(rig: rig, bones: outsideBody, characterRoot: 0, bodyRoot: 4, sex: 1)
    #expect(fresh.targets.isEmpty)
    let saved = try SourceStudioPose(rig: rig, bones: outsideBody, rotations: [8: .zero], characterRoot: 0, bodyRoot: 4, sex: 1)
    #expect(saved.targets.map(\.node) == [1] && !saved.targets[0].hasGuide)
}

@Test func sourceStudioPoseFemaleLevelTwoFilterDoesNotRemoveSavedFKRecord() throws {
    let rig = try studioPoseRig()
    let bones = [SourceStudioPose.Bone(id: 7, name: "body", group: 0, level: 2)]
    let fresh = try SourceStudioPose(rig: rig, bones: bones, characterRoot: 0, sex: 1)
    #expect(fresh.targets.isEmpty)
    let saved = try SourceStudioPose(rig: rig, bones: bones, rotations: [7: Float3(10, 20, 30)], characterRoot: 0, sex: 1)
    #expect(saved.targets.count == 1 && !saved.targets[0].hasGuide)
    let male = try SourceStudioPose(rig: rig, bones: bones, characterRoot: 0, sex: 0)
    #expect(male.targets.count == 1 && male.targets[0].hasGuide)
}

@Test func sourceStudioPoseSameNodeUsesCatalogOrder() throws {
    let rig = try studioPoseRig()
    var controller = try SourceStudioPose(rig: rig, bones: [
        .init(id: 1, name: "body", group: 0, level: 0), .init(id: 2, name: "body", group: 0, level: 0),
    ], rotations: [1: Float3(90, 0, 0), 2: Float3(0, 0, 90)], characterRoot: 0, sex: 1)
    _ = controller.activateMode(.fk, active: true)
    let result = try controller.applyingLateUpdate(rig: rig, pose: rig.restPose)
    studioPoseNear(result.localMatrices[4], Transform.trs(Float3(1.25, -2.5, 3.75),
        simd_quatf(angle: .pi / 2, axis: Float3(0, 0, 1)), Float3(0.5, 2, 3)))
}

@Test func sourceStudioPoseRejectsMalformedBindingsAndAmbiguousTRS() throws {
    let rig = try studioPoseRig()
    #expect(throws: RigError.self) { try SourceStudioPose(rig: rig, bones: [.init(id: 1, name: "body", group: -1, level: 0)], characterRoot: 0, sex: 1) }
    #expect(throws: RigError.self) { try SourceStudioPose(rig: rig, bones: [], characterRoot: 900, sex: 1) }
    #expect(throws: RigError.self) { try SourceStudioPose(rig: rig, bones: [.init(id: Int(Int32.max) + 1, name: "body", group: 0, level: 0)], characterRoot: 0, sex: 1) }
    #expect(throws: RigError.self) { try SourceStudioPose(rig: rig, bones: [.init(id: 0, name: "body", group: 0, level: Int(Int32.min) - 1)], characterRoot: 0, sex: 1) }
    #expect(throws: RigError.self) { try SourceStudioPose(rig: rig, bones: [], rotations: [Int(Int32.max) + 1: .zero], characterRoot: 0, sex: 1) }
    var controller = try studioPoseController(rig)
    #expect(throws: RigError.self) { try controller.setRotation(boneID: 900, degrees: .zero) }
    #expect(throws: RigError.self) { try controller.setRotation(boneID: 0, degrees: Float3(.infinity, 0, 0)) }
    _ = controller.activateMode(.fk, active: true)
    var sheared = rig.restPose; sheared.localMatrices[4][0].y += 0.5
    #expect(throws: RigError.self) { try controller.applyingLateUpdate(rig: rig, pose: sheared) }
    var invalid = rig.restPose; invalid.localMatrices.removeLast()
    #expect(throws: RigError.self) { try controller.applyingLateUpdate(rig: rig, pose: invalid) }
    let signedRig = try RigDefinition(nodes: [.init(name: "body", sourceID: "body", parent: nil, scale: Float3(-1, -1, 1))], skins: [])
    var signed = try SourceStudioPose(rig: signedRig, bones: [.init(id: 0, name: "body", group: 0, level: 0)], characterRoot: 0, sex: 1)
    _ = signed.activateMode(.fk, active: true)
    #expect(throws: RigError.self) { try signed.applyingLateUpdate(rig: signedRig, pose: signedRig.restPose) }
}

private func studioPoseEffectJSON(_ effect: SourceStudioPose.Effect) -> [Any] {
    switch effect {
    case .neckLookPattern(let value): return ["neck", value]
    case .breastDynamics(let left, let right): return ["breast", left, right]
    case .hairDynamics(let value): return ["hair", value]
    case .skirtDynamics(let value): return ["skirt", value]
    case .fkGuide(let group, let value): return ["fkGuide", group.rawValue, value]
    case .ikGuide(let group, let value): return ["ikGuide", group.rawValue, value]
    case .ikWeights(let group, let value): return ["ikWeights", group.rawValue, Int(value)]
    case .pvCopy(let values): return ["pv"] + values.map { $0 as Any }
    }
}

@Test func sourceStudioPoseMatchesIndependentInstalledContractOracleWhenSupplied() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_POSE_CONTRACT"] else { return }
    let contract = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    let oracle = try #require(contract["oracle"] as? [String: Any])
    let rig = try studioPoseRig()
    var controller = try studioPoseController(rig)
    for item in try #require(oracle["matrixCases"] as? [[String: Any]]) {
        _ = controller.activateMode(.fk, active: true)
        let degrees = try #require(item["degrees"] as? [Double])
        try controller.setRotation(boneID: 3, degrees: Float3(degrees.map(Float.init)))
        let matrix = try controller.applyingLateUpdate(rig: rig, pose: rig.restPose).localMatrices[4]
        let rows = try #require(item["nativeMatrixRows"] as? [[Double]])
        for r in 0..<4 { for c in 0..<4 { #expect(abs(matrix[c][r] - Float(rows[r][c])) < 0.00003) } }
    }
    controller = try studioPoseController(rig)
    controller.dynamicBreastRight = false
    _ = try controller.setPVEnabled([true, false, true, false])
    for item in try #require(oracle["activationCases"] as? [[String: Any]]) {
        let command = try #require(item["command"] as? [Any])
        let transition: SourceStudioPose.Transition
        switch command[0] as? String {
        case "mode": transition = controller.activateMode((command[1] as? String) == "fk" ? .fk : .ik,
            active: try #require(command[2] as? Bool), force: try #require(command[3] as? Bool))
        case "fk": transition = controller.activateFK(mask: .init(rawValue: try #require(command[1] as? Int)),
            active: try #require(command[2] as? Bool), force: try #require(command[3] as? Bool))
        default: transition = controller.activateIK(mask: .init(rawValue: try #require(command[1] as? Int)),
            active: try #require(command[2] as? Bool), force: try #require(command[3] as? Bool))
        }
        #expect(controller.enableFK == item["enableFK"] as? Bool)
        #expect(controller.enableIK == item["enableIK"] as? Bool)
        #expect(controller.activeFK == item["activeFK"] as? [Bool])
        #expect(controller.activeIK == item["activeIK"] as? [Bool])
        #expect(controller.neckLookPattern == item["neck"] as? Int)
        #expect(controller.previousNeckLookPattern == item["previousNeck"] as? Int)
        #expect(controller.targets.map(\.enabled) == item["enabledTargets"] as? [Bool])
        let resetGroups = transition.identityResetNodes.map { controller.targets[$0 - 1].bone.fkGroup.rawValue }
        #expect(resetGroups == item["resetGroups"] as? [Int])
        let events = try JSONSerialization.data(withJSONObject: transition.effects.map(studioPoseEffectJSON))
        let expected = try JSONSerialization.data(withJSONObject: #require(item["events"]))
        #expect(events == expected)
    }
}
