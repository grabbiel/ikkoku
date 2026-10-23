import Testing
import Foundation
import simd
import CoreMath
import Assets
@testable import Scene

private func expectMatrix(_ actual: float4x4, _ expected: float4x4, tolerance: Float = 1e-5) {
    for column in 0..<4 { #expect(simd_length(actual[column] - expected[column]) < tolerance) }
}

@Test func fullRigPreservesSupportTransformsAndPerRendererBinds() throws {
    var shear = matrix_identity_float4x4
    shear[1].x = 0.25
    let root = Transform.trs(Float3(0, 2, 0), simd_quatf(angle: 0.5, axis: Float3(0, 1, 0)), Float3(-1, 2, 1))
    let jointWorld = root * shear * Transform.translation(Float3(0, 1, 0))
    let meshWorldA = root * Transform.translation(Float3(3, 0, 0))
    let meshWorldB = root * Transform.translation(Float3(-2, 0, 0))
    let nodes: [RigDefinition.Node] = [
        .init(name: "root", sourceID: "a", parent: nil, authoredMatrix: root),
        .init(name: "support", sourceID: "b", parent: 0, authoredMatrix: shear),
        .init(name: "joint", sourceID: "c", parent: 1, translation: Float3(0, 1, 0)),
        .init(name: "mesh", sourceID: "d", parent: 0, translation: Float3(3, 0, 0)),
        .init(name: "mesh", sourceID: "e", parent: 0, translation: Float3(-2, 0, 0))]
    let rig = try RigDefinition(nodes: nodes, skins: [
        .init(name: "A", meshNode: 3, joints: [2], inverseBindMatrices: [simd_inverse(jointWorld) * meshWorldA]),
        .init(name: "B", meshNode: 4, joints: [2], inverseBindMatrices: [simd_inverse(jointWorld) * meshWorldB])])
    let rest = try rig.evaluate(rig.restPose)
    expectMatrix(rest.worldMatrices[2], jointWorld)
    expectMatrix(rest.palettes[0][0], matrix_identity_float4x4)
    expectMatrix(rest.palettes[1][0], matrix_identity_float4x4)
    #expect(rig.nodes(named: "mesh") == [3, 4])
    #expect(throws: RigError.self) { try rig.uniqueNode(named: "mesh") }
    var pose = rig.restPose
    pose.localMatrices[1] = shear * Transform.scale(Float3(1, 1.5, 1))
    let posed = try rig.evaluate(pose)
    let expectedJoint = root * pose.localMatrices[1] * nodes[2].localMatrix
    for index in 0..<2 {
        expectMatrix(posed.worldMatrices[rig.skins[index].meshNode] * posed.palettes[index][0], expectedJoint * rig.skins[index].inverseBindMatrices[0])
    }
}

@Test func fullRigRejectsInvalidHierarchyBindsAndSingularMeshPose() throws {
    #expect(throws: RigError.self) { try RigDefinition(nodes: [.init(name: "a", sourceID: "a", parent: 1), .init(name: "b", sourceID: "b", parent: 0)], skins: []) }
    #expect(throws: RigError.self) { try RigDefinition(nodes: [.init(name: "a", sourceID: "a", parent: nil), .init(name: "b", sourceID: "a", parent: nil)], skins: []) }
    let nodes: [RigDefinition.Node] = [.init(name: "mesh", sourceID: "a", parent: nil), .init(name: "joint", sourceID: "b", parent: nil)]
    #expect(throws: RigError.self) { try RigDefinition(nodes: nodes, skins: [.init(name: "bad", meshNode: 0, joints: [1], inverseBindMatrices: [])]) }
    let rig = try RigDefinition(nodes: nodes, skins: [.init(name: "valid", meshNode: 0, joints: [1], inverseBindMatrices: [matrix_identity_float4x4])])
    var pose = rig.restPose
    pose.localMatrices[0] = Transform.scale(Float3(1, 0, 1))
    #expect(throws: RigError.self) { try rig.evaluate(pose) }
}

private func sourceRigFixture() -> [String: Any] {
    ["schemaVersion": 1, "coordinateSpace": "unity-left-handed-y-up", "matrixLayout": "column-major", "uvConvention": "unity-source", "sourcePrefab": "synthetic",
     "nodes": [["name": "mesh", "sourceID": "0", "translation": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]],
               ["name": "joint", "sourceID": "1", "translation": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]]],
     "skins": [["name": "skin", "meshNode": 0, "joints": [1], "inverseBindMatrices": [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]]]],
     "meshes": [["name": "triangle", "node": 0, "skin": 0, "positions": [[0, 0, 1], [1, 0, 1], [0, 1, 1]],
                 "normals": Array(repeating: [0, 0, 1], count: 3), "tangents": Array(repeating: [1, 0, 0, 1], count: 3),
                 "uv0": [[0, 0], [1, 0], [0, 1]], "joints": Array(repeating: [0, 0, 0, 0], count: 3),
                 "weights": Array(repeating: [1, 0, 0, 0], count: 3), "submeshes": [["indices": [0, 1, 2]]], "morphChannels": [], "initialMorphWeights": [], "rendererEnabled": true]]]
}

@Test func sourceRigConvertsSkinSpaceGeometryAndWindingExactlyOnce() throws {
    let rig = try SourceRig.decode(JSONSerialization.data(withJSONObject: sourceRigFixture()))
    let part = try #require(rig.parts.first)
    #expect(part.mesh.positions[0] == Float3(0, 0, -1))
    #expect(part.mesh.indices == [0, 2, 1])
    #expect(part.mesh.uvs[0] == Float2(0, 1))
    #expect(part.mesh.tangents[0] == Float4(1, 0, 0, 1))
    var pose = rig.rig.restPose
    pose.localMatrices[1] = Transform.translation(Float3(0, 0, -2))
    let evaluation = try rig.rig.evaluate(pose)
    let deformed = try rig.deformedPositions(part: part, evaluation: evaluation)
    #expect(deformed[0] == Float3(0, 0, -3))
}

@Test func sourceRigRejectsZeroWeightOutOfRangeJointAndNonzeroUnportedMorph() throws {
    for field in ["joints", "weights", "initialMorphWeights"] {
        var document = sourceRigFixture()
        var meshes = try #require(document["meshes"] as? [[String: Any]])
        if field == "joints" { meshes[0][field] = Array(repeating: [0, 5, 0, 0], count: 3) }
        if field == "weights" { meshes[0][field] = Array(repeating: [0, 0, 0, 0], count: 3) }
        if field == "initialMorphWeights" { meshes[0][field] = [25] }
        document["meshes"] = meshes
        #expect(throws: RigError.self) { try SourceRig.decode(JSONSerialization.data(withJSONObject: document)) }
    }
}

private func sourceMorphFixture() throws -> [String: Any] {
    var document = sourceRigFixture()
    var meshes = try #require(document["meshes"] as? [[String: Any]])
    meshes[0]["uv1"] = [[0.2, 0.3], [0.4, 0.5], [0.6, 0.7]]
    meshes[0]["uv2"] = [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]
    meshes[0]["morphChannels"] = [["name": "source.close", "frames": [["weight": 100,
        "indices": [1], "positionDeltas": [[1, 2, 3]], "normalDeltas": [], "tangentDeltas": []]]]]
    document["meshes"] = meshes
    return document
}

@Test func sourceMorphUsesSparseDeltasBeforeSkinningAndPreservesExtraUVs() throws {
    let source = try SourceRig.decode(JSONSerialization.data(withJSONObject: sourceMorphFixture()))
    let part = try #require(source.parts.first)
    #expect(part.mesh.morphTargets[0].positionDeltas == [.zero, Float3(1, 2, -3), .zero])
    #expect(part.mesh.morphTargets[0].normalDeltas == Array(repeating: .zero, count: 3))
    #expect(part.mesh.uvs1[0] == Float2(0.2, 0.7))
    #expect(part.mesh.uvs2[0] == Float2(0.1, 0.8))
    var pose = source.rig.restPose
    pose.localMatrices[1] = Transform.translation(Float3(3, 4, 5)) * Transform.scale(Float3(2, 3, 4))
    let evaluation = try source.rig.evaluate(pose)
    let result = try source.deformedPositions(part: part, evaluation: evaluation, morphWeights: [(0, 0.5)])
    #expect(result[0] == Float3(3, 4, 1))
    #expect(result[1] == Float3(6, 7, -5))
    #expect(throws: RigError.self) { try source.deformedPositions(part: part, evaluation: evaluation, morphWeights: [(0, .nan)]) }
    #expect(throws: RigError.self) { try source.deformedPositions(part: part, evaluation: evaluation, morphWeights: [(1, 1)]) }
    #expect(throws: RigError.self) { try source.deformedPositions(part: part, evaluation: evaluation, morphWeights: [(0, 1), (0, 0.5)]) }
}

@Test func sourceMorphRejectsMalformedSparseFramesAndUnknownInterpolation() throws {
    for change in ["duplicate", "outOfBounds", "negative", "badCount", "non100", "multiple", "tangents", "missing", "uvCount"] {
        var document = try sourceMorphFixture()
        var meshes = try #require(document["meshes"] as? [[String: Any]])
        var channels = try #require(meshes[0]["morphChannels"] as? [[String: Any]])
        var frames = try #require(channels[0]["frames"] as? [[String: Any]])
        switch change {
        case "duplicate": frames[0]["indices"] = [1, 1]; frames[0]["positionDeltas"] = [[1, 2, 3], [1, 2, 3]]
        case "outOfBounds": frames[0]["indices"] = [3]
        case "negative": frames[0]["indices"] = [-1]
        case "badCount": frames[0]["positionDeltas"] = [] as [[Float]]
        case "non100": frames[0]["weight"] = 50
        case "multiple": frames.append(frames[0])
        case "tangents": frames[0]["tangentDeltas"] = [[1, 0, 0]]
        case "missing": channels.append(["name": "metadata-only"])
        case "uvCount": meshes[0]["uv1"] = [[0, 0]]
        default: break
        }
        channels[0]["frames"] = frames; meshes[0]["morphChannels"] = channels; document["meshes"] = meshes
        #expect(throws: RigError.self) { try SourceRig.decode(JSONSerialization.data(withJSONObject: document)) }
    }
}

// MARK: - Legacy name-keyed Skeleton contracts (R4)

private func legacyBone(_ name: String, _ parent: Int?, translation: Float3 = Float3(0, 1, 0)) -> Skeleton.Bone {
    Skeleton.Bone(name: name, parent: parent, restTranslation: translation)
}

/// A JSON glTF with one skin and no buffers; inverse binds default to identity.
private func skinnedGLTF(_ nodes: [[String: Any]], joints: [Int]) throws -> GLTFAsset {
    let root: [String: Any] = ["asset": ["version": "2.0"], "nodes": nodes, "skins": [["joints": joints]],
                               "scenes": [["nodes": [0]]], "scene": 0]
    return try GLBLoader.load(data: JSONSerialization.data(withJSONObject: root))
}

@Test func legacySkeletonRejectsInvalidGraphsAndRestDataNamingTheBone() throws {
    let root = legacyBone("root", nil)
    #expect(throws: SkeletonError.duplicateName("arm")) { try Skeleton(bones: [root, legacyBone("arm", 0), legacyBone("arm", 0)]) }
    #expect(throws: SkeletonError.duplicateName("")) { try Skeleton(bones: [legacyBone("", nil), legacyBone("", 0)]) }
    #expect(throws: SkeletonError.invalidParent(bone: "arm", parent: 5)) { try Skeleton(bones: [root, legacyBone("arm", 5)]) }
    #expect(throws: SkeletonError.invalidParent(bone: "arm", parent: -1)) { try Skeleton(bones: [root, legacyBone("arm", -1)]) }
    #expect(throws: SkeletonError.invalidParent(bone: "arm", parent: 1)) { try Skeleton(bones: [root, legacyBone("arm", 1)]) }
    #expect(throws: SkeletonError.cycle(bone: "a")) {
        try Skeleton(bones: [legacyBone("a", 1), legacyBone("b", 2), legacyBone("c", 0)])
    }
    var nonfinite = legacyBone("arm", 0)
    nonfinite.restScale.y = .infinity
    #expect(throws: SkeletonError.invalidRestTransform(bone: "arm")) { try Skeleton(bones: [root, nonfinite]) }
    var nonunit = legacyBone("arm", 0)
    nonunit.restRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 0.5)
    #expect(throws: SkeletonError.invalidRestTransform(bone: "arm")) { try Skeleton(bones: [root, nonunit]) }
    var projective = legacyBone("arm", 0)
    projective.inverseBind.columns.3.w = 2
    #expect(throws: SkeletonError.invalidInverseBind(bone: "arm")) { try Skeleton(bones: [root, projective]) }
    let base = try Skeleton(bones: [root, legacyBone("head", 0)])
    let hair = try base.extended(with: [legacyBone("front/hair1", 1), legacyBone("front/hair2", 2)])
    #expect(hair.count == 4 && hair["front/hair2"] == 3 && hair.order == [0, 1, 2, 3])
    #expect(throws: SkeletonError.duplicateName("head")) { try base.extended(with: [legacyBone("head", 1)]) }
}

@Test func legacySkeletonEvaluatesChildrenListedBeforeParentsInFormerOrder() throws {
    // Indices: 0 = tip (child of 2), 1 = root, 2 = mid (child of 1).
    let skeleton = try Skeleton(bones: [
        legacyBone("tip", 2, translation: Float3(0, 0.5, 0)), legacyBone("root", nil, translation: Float3(1, 0, 0)),
        Skeleton.Bone(name: "mid", parent: 1, restTranslation: Float3(0, 1, 0),
                      restRotation: simd_quatf(angle: .pi / 2, axis: Float3(0, 0, 1)), restScale: Float3(repeating: 2))])
    #expect(skeleton.order == [1, 2, 0])
    #expect(skeleton["tip"] == 0 && skeleton["root"] == 1 && skeleton["mid"] == 2)
    #expect(skeleton.bones[1].children == [2] && skeleton.bones[2].children == [0])
    // The tip's (0, 0.5, 0) offset is scaled by 2 and turned 90 degrees about Z under mid at (1, 1, 0).
    let world = skeleton.restWorldMatrices()
    #expect(simd_length(world[0].translation - Float3(0, 1, 0)) < 1e-5)

    // Same parent-first order as the former recursive visit for an arbitrary index order.
    let parents: [Int?] = [3, nil, 1, 1, 0, 3, 7, nil, 5, 2]
    let shuffled = try Skeleton(bones: parents.enumerated().map { legacyBone("b\($0.offset)", $0.element) })
    var visited = [Bool](repeating: false, count: parents.count), former: [Int] = []
    func visit(_ index: Int) {
        if visited[index] { return }
        if let parent = parents[index] { visit(parent) }
        visited[index] = true
        former.append(index)
    }
    for index in parents.indices { visit(index) }
    #expect(shuffled.order == former)
}

@Test func legacySkeletonImportFoldsMirroredAndIntermediateTransformsAndRejectsShear() throws {
    // Mirrored Armature (non-joint) → root joint → rotated offset (non-joint) → tip joint.
    let asset = try skinnedGLTF([
        ["name": "Armature", "children": [1], "scale": [-1, 1, 1]],
        ["name": "root", "children": [2], "translation": [0, 1, 0]],
        ["name": "offset", "children": [3], "rotation": [0, 0, 0.38268343, 0.9238795]],
        ["name": "tip", "translation": [0, 0.5, 0]]], joints: [1, 3])
    let skeleton = try #require(try Skeleton.from(asset: asset))
    #expect(skeleton.count == 2 && skeleton.bones[1].parent == 0)
    // The mirror is a negative scale instead of a nonunit quaternion with unsigned scale.
    #expect(skeleton.bones[0].restScale.x < 0)
    let world = skeleton.restWorldMatrices()
    for (index, node) in [(0, 1), (1, 3)] {
        let expected = asset.worldMatrix(ofNode: node)
        for column in 0..<4 { #expect(simd_length(world[index][column] - expected[column]) < 1e-5) }
    }

    let sheared = try skinnedGLTF([
        ["name": "Armature", "children": [1], "matrix": [1, 0, 0, 0, 0.5, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]],
        ["name": "root"]], joints: [1])
    #expect(throws: SkeletonError.unsupportedTransform(bone: "root", .unsupportedMatrix("rest matrix"))) {
        try Skeleton.from(asset: sheared)
    }
    let duplicate = try skinnedGLTF([["name": "root", "children": [1]], ["name": "root"]], joints: [0, 1])
    #expect(throws: SkeletonError.duplicateName("root")) { try Skeleton.from(asset: duplicate) }
    let unnamed = try skinnedGLTF([["children": [1]], [:]], joints: [0, 1])
    #expect(throws: SkeletonError.duplicateName("")) { try Skeleton.from(asset: unnamed) }

    let noSecondSkin = try Skeleton.from(asset: asset, skinIndex: 1) == nil
    let noNegativeSkin = try Skeleton.from(asset: asset, skinIndex: -1) == nil
    #expect(noSecondSkin && noNegativeSkin)
    var missingNode = asset
    missingNode.skins[0].jointNodes = [1, 9]
    #expect(throws: SkeletonError.self) { try Skeleton.from(asset: missingNode) }
    var repeatedJoint = asset
    repeatedJoint.skins[0].jointNodes = [1, 1]
    #expect(throws: SkeletonError.self) { try Skeleton.from(asset: repeatedJoint) }
    var missingBinds = asset
    missingBinds.skins[0].inverseBindMatrices = []
    #expect(throws: SkeletonError.self) { try Skeleton.from(asset: missingBinds) }
}

// MARK: - Pose sizes and two-bone IK (R4)

/// root → upperarm_L → forearm_L → hand_L, an arm hanging along -Y with a slight elbow bend.
private func armSkeleton() throws -> Skeleton {
    try Skeleton(bones: [
        legacyBone("root", nil, translation: Float3(0, 1.4, 0)), legacyBone("upperarm_L", 0, translation: Float3(0.2, 0, 0)),
        legacyBone("forearm_L", 1, translation: Float3(0, -0.3, 0.02)), legacyBone("hand_L", 2, translation: Float3(0, -0.28, 0))])
}

@Test func legacyPoseChecksArraySizesWhereItMeetsASkeleton() throws {
    let skeleton = try armSkeleton()
    var pose = skeleton.restPose
    pose.rotations[1] = simd_quatf(angle: 0.4, axis: normalize(Float3(0, 1, 1)))
    pose.skinScales[2] = Float3(1.2, 1, 1)
    try pose.validate(for: skeleton)
    // Accepted poses give exactly the unchecked results.
    let world = try pose.checkedWorldMatrices(skeleton: skeleton)
    #expect(world == pose.worldMatrices(skeleton: skeleton))
    #expect(try pose.checkedSkinMatrices(skeleton: skeleton) == pose.skinMatrices(skeleton: skeleton))
    #expect(try pose.checkedSkinMatrices(skeleton: skeleton, world: world) == pose.skinMatrices(skeleton: skeleton, world: world))
    #expect(try pose.checkedWorldRotation(3, skeleton: skeleton).vector == pose.worldRotation(3, skeleton: skeleton).vector)
    let other = PoseDelta(rotations: ["forearm_L": Float3(0, 0, 40)], translations: ["hand_L": Float3(0, 0.01, 0)]).apply(to: skeleton)
    #expect(try pose.checkedBlended(with: other, t: 0.3) == pose.blended(with: other, t: 0.3))
    let delta = PoseDelta(rotations: ["upperarm_L": Float3(10, 0, 0)], scales: ["root": Float3(repeating: 1.1)])
    #expect(try delta.checkedApply(to: skeleton, base: pose) == delta.apply(to: skeleton, base: pose))
    #expect(try delta.checkedApply(to: skeleton) == delta.apply(to: skeleton))

    // A pose of another skeleton, or one with a short array, fails by name instead of trapping.
    let short = try Skeleton(bones: [legacyBone("root", nil)]).restPose
    #expect(throws: PoseError.countMismatch(array: "rotations", count: 1, expected: 4)) {
        try short.checkedWorldMatrices(skeleton: skeleton)
    }
    var missingSkinScale = pose
    missingSkinScale.skinScales.removeLast()
    #expect(throws: PoseError.countMismatch(array: "skinScales", count: 3, expected: 4)) {
        try missingSkinScale.checkedSkinMatrices(skeleton: skeleton)
    }
    #expect(throws: PoseError.countMismatch(array: "world matrices", count: 2, expected: 4)) {
        try pose.checkedSkinMatrices(skeleton: skeleton, world: Array(world.prefix(2)))
    }
    #expect(throws: PoseError.countMismatch(array: "other rotations", count: 1, expected: 4)) {
        try pose.checkedBlended(with: short, t: 0.5)
    }
    #expect(throws: PoseError.countMismatch(array: "skinScales", count: 3, expected: 4)) {
        try missingSkinScale.checkedBlended(with: pose, t: 0.5)
    }
    #expect(throws: PoseError.boneOutOfRange(index: 4, count: 4)) { try pose.checkedWorldRotation(4, skeleton: skeleton) }
    #expect(throws: PoseError.boneOutOfRange(index: -1, count: 4)) { try pose.checkedWorldRotation(-1, skeleton: skeleton) }
    #expect(throws: PoseError.countMismatch(array: "rotations", count: 1, expected: 4)) {
        try delta.checkedApply(to: skeleton, base: short)
    }
}

@Test func checkedTwoBoneMatchesTwoBoneAndRejectsDegenerateChains() throws {
    let a = Float3(0, 1, 0), b = Float3(0, 0.5, 0.05), c = Float3(0, 0, 0)
    let cases: [(target: Float3, pole: Float3?)] = [
        (Float3(0.3, 0.4, 0.2), Float3(0, 0.5, 1)),
        (Float3(0, -3, 0), nil),                 // out of reach: the chain straightens
        (a, Float3(1, 0.5, 0)),                  // target on the root: aims along the current chain
        (Float3(0.1, 0.9, 0.4), b)]              // pole on the mid joint: keeps the current bend plane
    for (target, pole) in cases {
        let checked = try IKSolver.checkedTwoBone(a: a, b: b, c: c, target: target, pole: pole)
        let plain = IKSolver.twoBone(a: a, b: b, c: c, target: target, pole: pole)
        #expect(checked.upper.vector == plain.upper.vector && checked.lower.vector == plain.lower.vector)
    }
    let target = Float3(0.3, 0.4, 0.2)
    #expect(throws: MathContractError.nonfinite("IK target")) {
        try IKSolver.checkedTwoBone(a: a, b: b, c: c, target: Float3(.nan, 0, 0), pole: nil)
    }
    #expect(throws: MathContractError.nonfinite("IK pole")) {
        try IKSolver.checkedTwoBone(a: a, b: b, c: c, target: target, pole: Float3(0, .infinity, 0))
    }
    #expect(throws: MathContractError.nonfinite("IK root joint")) {
        try IKSolver.checkedTwoBone(a: Float3(0, .nan, 0), b: b, c: c, target: target, pole: nil)
    }
    #expect(throws: MathContractError.degenerateDirection("IK upper bone")) {
        try IKSolver.checkedTwoBone(a: a, b: a, c: c, target: target, pole: nil)
    }
    #expect(throws: MathContractError.degenerateDirection("IK lower bone")) {
        try IKSolver.checkedTwoBone(a: a, b: b, c: b, target: target, pole: nil)
    }
    // The target on the root and the end folded back onto the root: no direction to reach along.
    #expect(throws: MathContractError.degenerateDirection("IK reach")) {
        try IKSolver.checkedTwoBone(a: a, b: b, c: a, target: a, pole: nil)
    }
    // The unchecked solve returns NaN for the coincident joints the checked form rejects.
    let collapsed = IKSolver.twoBone(a: a, b: a, c: c, target: target, pole: nil)
    #expect(!collapsed.upper.vector.x.isFinite)
}

/// The former per-chain body of `CharacterInstance.applyIK`, the unchecked reference.
private func formerTwoBoneUpdate(_ pose: Pose, _ skeleton: Skeleton, upper ui: Int, lower li: Int, end ei: Int,
                                 target: Float3, pole: Float3?, offset: Float3) -> Pose {
    var p = pose
    let world = p.worldMatrices(skeleton: skeleton)
    let a = world[ui].translation, b = world[li].translation, c = world[ei].translation
    let r = IKSolver.twoBone(a: a, b: b, c: c, target: target, pole: pole ?? (b + offset))
    let upperWorldRot = p.worldRotation(ui, skeleton: skeleton)
    let parentRot = skeleton.bones[ui].parent.map { p.worldRotation($0, skeleton: skeleton) } ?? .identity
    p.rotations[ui] = (parentRot.inverse * (r.upper * upperWorldRot)).normalized
    let lowerWorldRot = r.upper * p.worldRotation(li, skeleton: skeleton)
    let newUpperWorld = p.worldRotation(ui, skeleton: skeleton)
    p.rotations[li] = (newUpperWorld.inverse * (r.lower * lowerWorldRot)).normalized
    return p
}

@Test func solveTwoBoneMatchesFormerUpdateAndRejectsDegeneratePoses() throws {
    let skeleton = try armSkeleton()
    let pose = PoseDelta(rotations: ["upperarm_L": Float3(0, 20, 10)]).apply(to: skeleton)
    let offset = Float3(0, -0.3, -0.5)
    let cases: [(target: Float3, pole: Float3?)] = [(Float3(0.45, 1.1, 0.3), nil), (Float3(0.1, 1.0, 0.3), Float3(0.6, 1.2, -0.4))]
    for (target, pole) in cases {
        let solved = try IKSolver.solveTwoBone(pose, skeleton: skeleton, upper: 1, lower: 2, end: 3, target: target,
                                               pole: pole, defaultPoleOffset: offset)
        #expect(solved == formerTwoBoneUpdate(pose, skeleton, upper: 1, lower: 2, end: 3, target: target, pole: pole, offset: offset))
        #expect(solved != pose)
    }
    let target = Float3(0.45, 1.1, 0.3)
    // The forearm on the shoulder leaves no upper bone; the caller keeps its pose.
    var folded = pose
    folded.translations[2] = .zero
    #expect(throws: MathContractError.degenerateDirection("IK upper bone")) {
        try IKSolver.solveTwoBone(folded, skeleton: skeleton, upper: 1, lower: 2, end: 3, target: target, pole: nil)
    }
    #expect(throws: MathContractError.nonfinite("IK target")) {
        try IKSolver.solveTwoBone(pose, skeleton: skeleton, upper: 1, lower: 2, end: 3, target: Float3(0, .nan, 0), pole: nil)
    }
    #expect(throws: PoseError.boneOutOfRange(index: 7, count: 4)) {
        try IKSolver.solveTwoBone(pose, skeleton: skeleton, upper: 1, lower: 2, end: 7, target: target, pole: nil)
    }
    let short = try Skeleton(bones: [legacyBone("root", nil)]).restPose
    #expect(throws: PoseError.countMismatch(array: "rotations", count: 1, expected: 4)) {
        try IKSolver.solveTwoBone(short, skeleton: skeleton, upper: 1, lower: 2, end: 3, target: target, pole: nil)
    }
}
