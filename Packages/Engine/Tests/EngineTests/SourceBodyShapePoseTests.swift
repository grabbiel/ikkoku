import Foundation
import Testing
import simd
import CoreMath
import Scene
import Character

private func bodyPoseRig(names: [String] = Array(SourceBodyShapePose.destinationNames.prefix(5)),
                         authoredIndex: Int? = nil) throws -> RigDefinition {
    let nodes = names.enumerated().map { index, name in
        RigDefinition.Node(name: name, sourceID: String(index), parent: nil,
            translation: Float3(10, 20, 30), rotation: simd_quatf(angle: 0.4, axis: Float3(0, 1, 0)),
            scale: Float3(2, 3, 4), authoredMatrix: index == authoredIndex ? matrix_identity_float4x4 : nil)
    }
    return try RigDefinition(nodes: nodes, skins: [])
}

private func bodyPoseState() -> [String: SourceShapeTransform] {
    ["cf_a_height": .init(scale: Float3(0.8, 0.9, 1)),
     "cf_a_height_aid": .init(scale: Float3(1.2, 1.1, 1.3)),
     "cf_a_head": .init(position: Float3(99, 0.03, 99), scale: Float3(0.7, 0.8, 0.9)),
     "cf_a_neck": .init(position: Float3(99, 99, 0.04), scale: Float3(0.6, 99, 0.5))]
}

private func correctionData(head: SourceShapeTransform = .init(scale: .zero),
                             neck: SourceShapeTransform = .init(scale: .zero)) -> Data {
    var words: [UInt32] = [32]
    for index in 0..<32 {
        let value = index == 1 ? neck : (index == 2 ? head : .init(scale: .zero))
        for vector in [value.position, value.rotationDegrees, value.scale] {
            words.append(contentsOf: [vector.x.bitPattern, vector.y.bitPattern, vector.z.bitPattern])
        }
    }
    return Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
}

private func expectMatrix(_ actual: float4x4, _ expected: float4x4, tolerance: Float = 1e-6) {
    for column in 0..<4 { for row in 0..<4 { #expect(abs(actual[column][row] - expected[column][row]) <= tolerance) } }
}

@Test func sourceBodyShapeUsesFiveAbsoluteOperationsAndPreservesUntouchedComponents() throws {
    let rig = try bodyPoseRig(names: Array(SourceBodyShapePose.destinationNames.prefix(5)) + ["unported"])
    let pose = try SourceBodyShapePose.make(rig: rig, state: bodyPoseState())
    let rotation = rig.nodes[0].rotation, unchanged = Float3(10, 20, 30)
    expectMatrix(pose.localMatrices[0], Transform.trs(unchanged, rotation, Float3(0.8, 0.9, 1)))
    expectMatrix(pose.localMatrices[1], Transform.trs(unchanged, rotation, Float3(1.2, 1.1, 1.3)))
    expectMatrix(pose.localMatrices[2], pose.localMatrices[1])
    expectMatrix(pose.localMatrices[3], Transform.trs(Float3(10, 0.03, 30), rotation, Float3(0.84, 0.88, 1.17)))
    expectMatrix(pose.localMatrices[4], Transform.trs(Float3(10, 0, -0.04), .identity, Float3(0.72, 1, 0.65)))
    expectMatrix(pose.localMatrices[5], rig.nodes[5].localMatrix)
    // Repeated application must not multiply the original scale into source scales.
    let again = try SourceBodyShapePose.make(rig: rig, state: bodyPoseState())
    for index in pose.localMatrices.indices { expectMatrix(again.localMatrices[index], pose.localMatrices[index]) }
}

@Test func sourceBodyShapeAppliesCorrectionAfterMultiplicationAndResetsNeckRotation() throws {
    let head = SourceShapeTransform(position: Float3(50, -0.005, 50), rotationDegrees: Float3(repeating: 70), scale: Float3(0.25, 0.15, 0.22))
    let neck = SourceShapeTransform(position: Float3(50, -0.005, 50), rotationDegrees: Float3(12, 60, 70), scale: Float3(0.15, 80, 0.12))
    let table = try SourceBodyShapeCorrectionTable.decode(correctionData(head: head, neck: neck))
    let rig = try bodyPoseRig()
    for sex in [SourceBodyShapePose.Sex.female, .male] {
        let size: Float = sex == .female ? 1 : 0.91
        let pose = try SourceBodyShapePose.make(rig: rig, state: bodyPoseState(), options: .init(sex: sex, boneType: .corrected(table)))
        expectMatrix(pose.localMatrices[3], Transform.trs(Float3(10, 0.025, 30), rig.nodes[3].rotation,
            Float3(0.84, 0.88, 1.17) * size + Float3(0.25, 0.15, 0.22)))
        expectMatrix(pose.localMatrices[4], Transform.trs(Float3(10, -0.005, -0.04),
            simd_quatf(angle: -12 * Float.pi / 180, axis: Float3(1, 0, 0)), Float3(0.72 * size + 0.15, 1, 0.65 * size + 0.12)))
        expectMatrix(pose.localMatrices[1], Transform.trs(Float3(10, 20, 30), rig.nodes[1].rotation, Float3(1.2, 1.1, 1.3)))
    }
}

@Test func sourceBodyShapeComposesWithAnimationWithoutAccumulatingOrErasingOtherBones() throws {
    let rig = try bodyPoseRig(names: Array(SourceBodyShapePose.destinationNames.prefix(5)) + ["animated-spine"])
    var animated = rig.restPose
    let translation = Float3(0.2, 1.4, -0.3)
    let rotation = simd_quatf(angle: 0.7, axis: normalize(Float3(1, 2, 3)))
    let motion = Transform.trs(translation, rotation, Float3(1.1, 0.9, 1))
    for index in animated.localMatrices.indices { animated.localMatrices[index] = motion }
    let combined = try SourceBodyShapePose.make(rig: rig, state: bodyPoseState(), basePose: animated)
    expectMatrix(combined.localMatrices[0], Transform.trs(translation, rotation, Float3(0.8, 0.9, 1)))
    expectMatrix(combined.localMatrices[1], Transform.trs(translation, rotation, Float3(1.2, 1.1, 1.3)))
    expectMatrix(combined.localMatrices[2], combined.localMatrices[1])
    expectMatrix(combined.localMatrices[3], Transform.trs(Float3(0.2, 0.03, -0.3), rotation, Float3(0.84, 0.88, 1.17)))
    expectMatrix(combined.localMatrices[4], Transform.trs(Float3(0.2, 0, -0.04), .identity, Float3(0.72, 1, 0.65)))
    expectMatrix(combined.localMatrices.last!, motion)
    let again = try SourceBodyShapePose.make(rig: rig, state: bodyPoseState(), basePose: combined)
    for index in combined.localMatrices.indices { expectMatrix(again.localMatrices[index], combined.localMatrices[index]) }
    animated.localMatrices.removeLast()
    #expect(throws: RigError.self) { try SourceBodyShapePose.make(rig: rig, state: bodyPoseState(), basePose: animated) }
}

@Test func sourceBodyShapeRejectsAmbiguousAnimatedDestinationMatrices() throws {
    let rig = try bodyPoseRig()
    var shear = matrix_identity_float4x4; shear[0].y = 0.5
    var perspective = matrix_identity_float4x4; perspective[0].w = 0.1
    for bad in [shear, perspective, Transform.scale(Float3(-1, 1, 1)), Transform.scale(Float3(0, 1, 1))] {
        var pose = rig.restPose; pose.localMatrices[0] = bad
        #expect(throws: RigError.self) { try SourceBodyShapePose.make(rig: rig, state: bodyPoseState(), basePose: pose) }
    }
}

@Test func sourceBodyCorrectionTableRejectsWrongCountTruncationTrailingDataAndNonfiniteValues() throws {
    let valid = correctionData()
    #expect(try SourceBodyShapeCorrectionTable.decode(valid).entries.count == 32)
    for count in 0..<valid.count {
        #expect(throws: RigError.self) { try SourceBodyShapeCorrectionTable.decode(valid.prefix(count)) }
    }
    var wrongCount = valid; wrongCount[0] = 31
    #expect(throws: RigError.self) { try SourceBodyShapeCorrectionTable.decode(wrongCount) }
    #expect(throws: RigError.self) { try SourceBodyShapeCorrectionTable.decode(valid + Data([0])) }
    let nonfinite = correctionData(head: .init(scale: Float3(.nan, 0, 0)))
    #expect(throws: RigError.self) { try SourceBodyShapeCorrectionTable.decode(nonfinite) }
}

@Test func sourceBodyShapeRejectsMissingAmbiguousAuthoredAndNonfiniteInput() throws {
    let state = bodyPoseState(), rig = try bodyPoseRig()
    var incomplete = state; incomplete.removeValue(forKey: "cf_a_height_aid")
    #expect(throws: SourceShapeError.self) { try SourceBodyShapePose.make(rig: rig, state: incomplete) }
    for scale in [Float.nan, .infinity, .greatestFiniteMagnitude] {
        var overflow = state; overflow["cf_a_head"]?.scale = Float3(repeating: scale)
        #expect(throws: (any Error).self) { try SourceBodyShapePose.make(rig: rig, state: overflow) }
    }
    let reduced = try bodyPoseRig(names: Array(SourceBodyShapePose.destinationNames.prefix(4)))
    #expect(try SourceBodyShapePose.make(rig: reduced, state: state).localMatrices.count == 4)
    #expect(throws: RigError.self) {
        try SourceBodyShapePose.make(rig: bodyPoseRig(names: Array(SourceBodyShapePose.destinationNames.prefix(5)) + ["cf_s_head"]), state: state)
    }
    #expect(throws: RigError.self) { try SourceBodyShapePose.make(rig: bodyPoseRig(authoredIndex: 3), state: state) }
}

@Test func sourceBodyShapeMatchesLocalRecoveredCSharpReferenceWhenRequested() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_BODY_SHAPE_REFERENCE"] else { return }
    struct TransformRecord: Decodable { let name: String?, position: [Float], rotation: [Float], scale: [Float] }
    struct StateRecord: Decodable {
        let position: [Float], rotationDegrees: [Float], scale: [Float]
        var transform: SourceShapeTransform {
            .init(position: Float3(position), rotationDegrees: Float3(rotationDegrees), scale: Float3(scale))
        }
    }
    struct Case: Decodable {
        let values: [Float], sex: Int, corrected: Bool, destinations: [TransformRecord]
        let updateMask: UInt8?, applyAlways: Bool?, rawState: [StateRecord]?, correctionOverride: [StateRecord]?
    }
    struct Reference: Decodable {
        let rigPath: String, shapeContractPath: String, correctionPath: String, cases: [Case]
    }
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let source = try SourceRig.load(url: URL(fileURLWithPath: reference.rigPath))
    let contract = try SourceShapeContract.decode(Data(contentsOf: URL(fileURLWithPath: reference.shapeContractPath)))
    let body = try #require(contract.domain("body"))
    let corrections = try SourceBodyShapeCorrectionTable.decode(Data(contentsOf: URL(fileURLWithPath: reference.correctionPath)))
    #expect(reference.cases.count >= 100)
    for test in reference.cases {
        #expect(test.destinations.count == 5 || test.destinations.count == 88)
        let sex = try #require(SourceBodyShapePose.Sex(rawValue: test.sex))
        let table: SourceBodyShapeCorrectionTable
        if let override = test.correctionOverride {
            table = try SourceBodyShapeCorrectionTable.decode(bodyFullCorrectionData(override.map(\.transform)))
        } else { table = corrections }
        let options = SourceBodyShapePose.Options(sex: sex, boneType: test.corrected ? .corrected(table) : .standard,
            updateMask: test.updateMask ?? 7, applyAlways: test.applyAlways ?? true)
        let pose: RigPose
        if let raw = test.rawState {
            pose = try SourceBodyShapePose.make(rig: source.rig,
                state: Dictionary(uniqueKeysWithValues: zip(SourceBodyShapePose.sourceNames, raw.map(\.transform))), options: options)
        } else { pose = try SourceBodyShapePose.make(rig: source.rig, domain: body, values: test.values, options: options) }
        for (recordIndex, record) in test.destinations.enumerated() {
            let name = record.name ?? SourceBodyShapePose.destinationNames[recordIndex]
            let index = try source.rig.uniqueNode(named: name)
            let t = Float3(record.position[0], record.position[1], -record.position[2])
            let q = simd_quatf(vector: Float4(-record.rotation[0], -record.rotation[1], record.rotation[2], record.rotation[3]))
            let s = Float3(record.scale[0], record.scale[1], record.scale[2])
            expectMatrix(pose.localMatrices[index], Transform.trs(t, q, s), tolerance: 4e-6)
        }
    }
}

private func bodyFullCorrectionData(_ entries: [SourceShapeTransform]) -> Data {
    var words: [UInt32] = [UInt32(entries.count)]
    for value in entries {
        for vector in [value.position, value.rotationDegrees, value.scale] {
            words.append(contentsOf: [vector.x.bitPattern, vector.y.bitPattern, vector.z.bitPattern])
        }
    }
    return Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
}

private func bodyCompleteState() -> [String: SourceShapeTransform] {
    Dictionary(uniqueKeysWithValues: SourceBodyShapePose.sourceNames.map { ($0, SourceShapeTransform()) })
}

@Test func sourceBodyShapeRespectsIndependentUpdateMasksAndAlwaysOrder() throws {
    let names = ["cf_s_spine03", "cf_s_bust00_L", "cf_s_bust00_R", "cf_d_kokan", "cf_d_shoulder_L", "cf_d_shoulder_R"]
    let rig = try bodyPoseRig(names: names)
    var state = bodyCompleteState()
    state["cf_a_spine03"]?.position.z = 0.8
    state["cf_a_bust_ty"]?.position.y = 0.3
    state["cf_a_dan"]?.position.z = 0.2
    for mask in UInt8(0)...7 {
        for always in [false, true] {
            let pose = try SourceBodyShapePose.make(rig: rig, state: state, options: .init(updateMask: mask, applyAlways: always))
            #expect(pose.localMatrices[0].translation.z == (mask & 4 != 0 ? -0.8 : 30))
            #expect(pose.localMatrices[1].translation.y == (mask & 1 != 0 ? 0.3 : 20))
            #expect(pose.localMatrices[2].translation.y == (mask & 2 != 0 ? 0.3 : 20))
            #expect(pose.localMatrices[3].translation.z == (always ? -0.2 : 30))
            #expect(pose.localMatrices[4].translation.x == (always ? -0.01563369 : 10))
            #expect(pose.localMatrices[5].translation.x == (always ? 0.01560147 : 10))
        }
    }
    #expect(throws: RigError.self) { try SourceBodyShapePose.make(rig: rig, state: state, options: .init(updateMask: 8)) }
}

@Test func sourceBodyShapePreservesAnimationOnPositionOnlySkirtAndAlwaysSetters() throws {
    let rig = try bodyPoseRig(names: ["cf_d_sk_00_00", "cf_d_kokan", "cf_d_shoulder_L", "cf_d_shoulder_R"])
    var baseline = rig.restPose
    let t = Float3(0.1, 0.2, 0.3), s = Float3(0.8, 0.9, 1.1)
    let q = simd_quatf(angle: 0.4, axis: normalize(Float3(1, 2, 3)))
    for i in baseline.localMatrices.indices { baseline.localMatrices[i] = Transform.trs(t, q, s) }
    var state = bodyCompleteState()
    state["cf_a_sk_00_00"]?.position.x = 0.4
    state["cf_a_sk_00_00"]?.rotationDegrees = Float3(1, 2, 3)
    state["cf_a_sk_00_01"]?.rotationDegrees = Float3(5, 0, 7)
    state["cf_a_sk_thigh01_sz"]?.rotationDegrees.x = 350
    let pose = try SourceBodyShapePose.make(rig: rig, state: state, basePose: baseline)
    expectMatrix(pose.localMatrices[0], Transform.trs(Float3(0.4, 0.2, 0), UnityCoordinates.eulerDegrees(Float3(3, 2, 3)), s))
    expectMatrix(pose.localMatrices[1], Transform.trs(Float3(0.1, 0.2, 0), q, s))
    expectMatrix(pose.localMatrices[2], Transform.trs(Float3(-0.01563369, 0.2, 0.3), q, s))
    expectMatrix(pose.localMatrices[3], Transform.trs(Float3(0.01560147, 0.2, 0.3), q, s))
}

@Test func sourceBodyShapeRejectsDivisionOverflowOnlyForBoundEnabledOperations() throws {
    let rig = try bodyPoseRig(names: ["cf_s_bnip025_L"])
    var state = bodyCompleteState(); state["cf_a_bnip01"]?.scale.x = 0
    #expect(throws: RigError.self) { try SourceBodyShapePose.make(rig: rig, state: state) }
    let skipped = try SourceBodyShapePose.make(rig: rig, state: [:], options: .init(updateMask: 2, applyAlways: false))
    expectMatrix(skipped.localMatrices[0], rig.nodes[0].localMatrix)
}

@Test func sourceBodyShapeCoverageReportsReducedRigAndEveryRecoveredSlotWhenRequested() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_SHAPE_CONTRACT"] else { return }
    let contract = try SourceShapeContract.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    let domain = try #require(contract.domain("body"))
    let reduced = try SourceBodyShapePose.coverage(rig: bodyPoseRig(), domain: domain)
    #expect(reduced.boundSlots == [0, 1, 2, 3])
    #expect(reduced.completeSlots == [1, 2, 3]) // height aid also drives torso, limbs and colliders.
    #expect(reduced.boundDestinations.count == 5)
    #expect(reduced.missingDestinations.count == 83)
    let complete = try bodyPoseRig(names: SourceBodyShapePose.destinationNames + Array(SourceBodyShapePose.alwaysDestinationNames.dropFirst()))
    let coverage = try SourceBodyShapePose.coverage(rig: complete, domain: domain)
    #expect(coverage.completeSlots == Array(0..<44))
    #expect(coverage.boundDestinations.count == 88)
    #expect(coverage.missingDestinations.isEmpty)
}

@Test func sourceBodyShapeAllSlotsAffectBoundDestinationsOnTheAssembledAvatarWhenRequested() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_SOURCE_AVATAR"] else { return }
    let url = URL(fileURLWithPath: path)
    let source = try SourceAvatar.load(url: url)
    let contract = try SourceShapeContract.decode(Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("character-shape-contract.json")))
    let domain = try #require(contract.domain("body"))
    let manifest = try JSONDecoder().decode(SourceAvatarManifest.self, from: Data(contentsOf: url))
    let options = SourceBodyShapePose.Options(sex: manifest.kind == "koikatsu-male-avatar" ? .male : .female)
    let coverage = try SourceBodyShapePose.coverage(rig: source.rig, domain: domain, options: options)
    #expect(coverage.completeSlots == Array(0..<44))
    for slot in domain.slots {
        var low = domain.defaultValues, high = domain.defaultValues
        low[slot.index] = 0; high[slot.index] = 1
        let a = try SourceBodyShapePose.make(rig: source.rig, domain: domain, values: low, options: options)
        let b = try SourceBodyShapePose.make(rig: source.rig, domain: domain, values: high, options: options)
        let changed = try coverage.slots[slot.index].boundDestinations.contains { name in
            let index = try source.rig.uniqueNode(named: name)
            return a.localMatrices[index] != b.localMatrices[index]
        }
        #expect(changed, "Recovered body slot \(slot.index) must reach its bound destination.")
        _ = try source.rig.evaluate(a); _ = try source.rig.evaluate(b)
    }
    for rate: Float in [0, 0.5, 1] {
        let pose = try SourceBodyShapePose.make(rig: source.rig, domain: domain,
            values: Array(repeating: rate, count: 44), options: options)
        let bounds = try source.bounds(evaluation: source.rig.evaluate(pose))
        #expect(!bounds.isEmpty && bounds.radius.isFinite)
    }
}
