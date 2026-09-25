import Foundation
import Testing
import simd
import Assets
import CoreMath
@testable import Scene

private struct AvatarFixture {
    let bodySkeleton: SourceRig, headSkeleton: SourceRig, body: SourceRig, head: SourceRig, clothes: SourceRig, hair: SourceRig

    func assemble(bodyNames: [String]? = ["body-normal"], clothingNames: [[String]?]? = [["clothes-normal"]]) throws -> SourceRig {
        try SourceAvatar.assemble(name: "synthetic-avatar", bodySkeleton: bodySkeleton, headSkeleton: headSkeleton,
            body: body, head: head, clothes: [clothes], hair: [hair], bodyMeshNames: bodyNames, clothingMeshNames: clothingNames)
    }
}

private func avatarNode(_ name: String, _ parent: Int?, _ position: Float3 = .zero, active: Bool = true) -> RigDefinition.Node {
    .init(name: name, sourceID: name, parent: parent, translation: position, active: active)
}

private func avatarPart(_ name: String, node: Int, skin: Int) -> SourceRig.Part {
    let mesh = MeshData(name: name, positions: [Float3(1, 2, 3)], normals: [Float3(0, 1, 0)],
        joints: [SIMD4<UInt16>(0, 1, 0, 0)], weights: [Float4(0.25, 0.75, 0, 0)], indices: [0, 0, 0])
    return .init(mesh: mesh, node: node, skin: skin, rendererEnabled: true)
}

private func avatarSource(_ nodes: [RigDefinition.Node], _ skins: [RigDefinition.Skin] = [],
                          _ parts: [SourceRig.Part] = []) throws -> SourceRig {
    .init(sourcePrefab: nodes[0].name, rig: try .init(nodes: nodes, skins: skins), parts: parts, morphChannelCount: 0)
}

private func avatarMeshSource(prefix: String, skeletonRoot: String, jointNames: [String],
                              jointPositions: [Float3], rootPosition: Float3 = .zero) throws -> SourceRig {
    // Renderer siblings of a disposable skeleton, matching the source prefab structure.
    let nodes = [avatarNode(prefix + "-prefab", nil, rootPosition), avatarNode(skeletonRoot, 0, Float3(100, 100, 100)),
        avatarNode(jointNames[0], 1, jointPositions[0]), avatarNode(jointNames[1], 2, jointPositions[1]),
        avatarNode(prefix + "-renderer", 0, Float3(0.3, 0.4, 0.5)), avatarNode(prefix + "-alternate", 0)]
    let binds = [Transform.translation(Float3(-0.5, 0.25, 0)), Transform.scale(Float3(1, 2, 3))]
    let skins: [RigDefinition.Skin] = [
        .init(name: prefix + "-normal", meshNode: 4, joints: [3, 2], inverseBindMatrices: binds, rootJoint: 1),
        .init(name: prefix + "-other", meshNode: 5, joints: [2, 3], inverseBindMatrices: binds, rootJoint: 1)]
    return try avatarSource(nodes, skins, [avatarPart(prefix + "/0", node: 4, skin: 0), avatarPart(prefix + "/1", node: 5, skin: 1)])
}

private func avatarFixture() throws -> AvatarFixture {
    let bodySkeleton = try avatarSource([
        avatarNode("body-master", nil, Float3(1, 0, 0)), avatarNode("cf_j_root", 0, Float3(0, 1, 0)),
        avatarNode("cf_j_hips", 1, Float3(0, 2, 0)), avatarNode("cf_s_head", 2, Float3(0, 3, 0))])
    let headSkeleton = try avatarSource([
        avatarNode("head-master", nil, Float3(0, 0.5, 0)), avatarNode("cf_J_N_FaceRoot", 0, Float3(0, 0.1, 0)),
        avatarNode("cf_J_FaceUp_ty", 1, Float3(0, 0.2, 0)), avatarNode("face-joint", 2, Float3(1, 0, 0)),
        avatarNode("head-only-helper", 1, Float3(7, 8, 9))])
    let body = try avatarMeshSource(prefix: "body", skeletonRoot: "cf_j_root", jointNames: ["cf_j_hips", "cf_s_head"],
        jointPositions: [Float3(40, 40, 40), Float3(50, 50, 50)], rootPosition: Float3(-1, 0, 0))
    let clothes = try avatarMeshSource(prefix: "clothes", skeletonRoot: "cf_j_root", jointNames: ["cf_j_hips", "cf_s_head"],
        jointPositions: [Float3(60, 60, 60), Float3(70, 70, 70)])
    // Original inactive prefab bones are copied only as local TRS, never as active state.
    let headNodes = [avatarNode("head-prefab", nil, Float3(0, 0.7, 0)), avatarNode("cf_J_N_FaceRoot", 0, Float3(0, 0.4, 0)),
        avatarNode("cf_J_FaceUp_ty", 1, Float3(0, 0.6, 0), active: false), avatarNode("face-joint", 2, Float3(2, 0, 0)),
        avatarNode("head-renderer", 0, Float3(0.1, 0.2, 0.3))]
    let head = try avatarSource(headNodes,
        [.init(name: "head-skin", meshNode: 4, joints: [3, 2], inverseBindMatrices: [matrix_identity_float4x4, matrix_identity_float4x4], rootJoint: 1)],
        [avatarPart("head/0", node: 4, skin: 0)])
    // A hair joint deliberately shares a master bone name, proving it remains self-skinned.
    let hair = try avatarSource([avatarNode("hair-prefab", nil, Float3(0, 0, 0.8)), avatarNode("cf_j_hips", 0, Float3(0, 0, 0.9)),
        avatarNode("hair-renderer", 0, Float3(0.6, 0, 0))],
        [.init(name: "hair-skin", meshNode: 2, joints: [1, 0], inverseBindMatrices: [matrix_identity_float4x4, matrix_identity_float4x4], rootJoint: 0)],
        [avatarPart("hair/0", node: 2, skin: 0)])
    return AvatarFixture(bodySkeleton: bodySkeleton, headSkeleton: headSkeleton, body: body, head: head, clothes: clothes, hair: hair)
}

private func avatarIndex(_ assembled: SourceRig, _ id: String) throws -> Int {
    try #require(assembled.rig.nodes.firstIndex { $0.sourceID == id })
}

private func avatarMatrixEqual(_ a: float4x4, _ b: float4x4) {
    for column in 0..<4 { for row in 0..<4 { #expect(abs(a[column][row] - b[column][row]) < 1e-6) } }
}

@Test func sourceAvatarUsesSourceParentsCopiesHeadLocalsAndRemovesOnlyDisposableBranches() throws {
    let fixture = try avatarFixture(), avatar = try fixture.assemble()
    let headContainer = try avatarIndex(avatar, "head-master/head-master")
    let headParent = try avatarIndex(avatar, "body-master/cf_s_head")
    let hairParent = try avatarIndex(avatar, "head-master/cf_J_FaceUp_ty")
    #expect(avatar.rig.nodes[headContainer].parent == headParent)
    #expect(avatar.rig.nodes[try avatarIndex(avatar, "head/head-prefab")].parent == headContainer)
    #expect(avatar.rig.nodes[try avatarIndex(avatar, "hair-0/hair-prefab")].parent == hairParent)
    #expect(avatar.rig.nodes[try avatarIndex(avatar, "body/body-prefab")].parent == 0)
    #expect(avatar.rig.nodes[try avatarIndex(avatar, "clothes-0/clothes-prefab")].parent == 0)
    #expect(avatar.rig.nodes[hairParent].translation == Float3(0, 0.6, 0))
    #expect(avatar.rig.nodes[hairParent].active) // CopySameNameTransform does not copy active state.
    #expect(avatar.rig.nodes[try avatarIndex(avatar, "head-master/face-joint")].translation == Float3(2, 0, 0))
    #expect(avatar.rig.nodes[try avatarIndex(avatar, "head-master/head-only-helper")].translation == Float3(7, 8, 9))
    #expect(!avatar.rig.nodes.contains { $0.sourceID == "body/cf_j_root" || $0.sourceID == "head/cf_J_N_FaceRoot" || $0.sourceID == "clothes-0/cf_j_root" })
    #expect(avatar.rig.nodes[headContainer].translation == fixture.headSkeleton.rig.nodes[0].translation)
    #expect(avatar.rig.nodes[try avatarIndex(avatar, "body-master/cf_j_hips")].translation == Float3(0, 2, 0))
}

@Test func sourceAvatarPreservesPaletteOrderInverseBindsAndSourceHairSkinning() throws {
    let fixture = try avatarFixture(), avatar = try fixture.assemble()
    #expect(avatar.parts.map(\.mesh.name) == ["body/0", "head/0", "clothes/0", "hair/0"])
    let body = avatar.rig.skins[0], head = avatar.rig.skins[1], clothes = avatar.rig.skins[2], hair = avatar.rig.skins[3]
    #expect(body.joints == [try avatarIndex(avatar, "body-master/cf_s_head"), try avatarIndex(avatar, "body-master/cf_j_hips")])
    #expect(clothes.joints == body.joints)
    #expect(head.joints == [try avatarIndex(avatar, "head-master/face-joint"), try avatarIndex(avatar, "head-master/cf_J_FaceUp_ty")])
    #expect(hair.joints == [try avatarIndex(avatar, "hair-0/cf_j_hips"), try avatarIndex(avatar, "hair-0/hair-prefab")])
    #expect(hair.rootJoint == hair.joints[1])
    let hips = try avatarIndex(avatar, "body-master/cf_j_hips")
    #expect(body.rootJoint == hips && head.rootJoint == hips && clothes.rootJoint == hips)
    for index in 0..<2 { avatarMatrixEqual(body.inverseBindMatrices[index], fixture.body.rig.skins[0].inverseBindMatrices[index]) }
    #expect(avatar.parts[0].mesh.joints == fixture.body.parts[0].mesh.joints)
    #expect(avatar.parts[0].mesh.weights == fixture.body.parts[0].mesh.weights)
    // Evaluate a weighted source vertex with independent known master-world transforms.
    let evaluation = try avatar.rig.evaluate(avatar.rig.restPose)
    let p = Float4(1, 2, 3, 1)
    let expected = (Transform.translation(Float3(1, 6, 0)) * fixture.body.rig.skins[0].inverseBindMatrices[0] * p) * 0.25
        + (Transform.translation(Float3(1, 3, 0)) * fixture.body.rig.skins[0].inverseBindMatrices[1] * p) * 0.75
    let actual = try #require(avatar.deformedPositions(part: avatar.parts[0], evaluation: evaluation).first)
    #expect(simd_distance(actual, Float3(expected.x, expected.y, expected.z)) < 1e-5)
    let hairVertex = try #require(avatar.deformedPositions(part: avatar.parts[3], evaluation: evaluation).first)
    #expect(simd_distance(hairVertex, Float3(2, 9.5, 4.025)) < 1e-5)
}

@Test func sourceAvatarRejectsAmbiguousMasterUnresolvedPaletteAndInvalidSelections() throws {
    let fixture = try avatarFixture()
    #expect(throws: RigError.self) { try fixture.assemble(bodyNames: nil) }
    #expect(throws: RigError.self) { try fixture.assemble(bodyNames: ["missing"]) }
    #expect(throws: RigError.self) { try fixture.assemble(bodyNames: ["body-normal", "body-normal"]) }
    #expect(throws: RigError.self) { try fixture.assemble(clothingNames: []) }
    let duplicate = try avatarSource(fixture.bodySkeleton.rig.nodes + [
        .init(name: "cf_j_hips", sourceID: "another-hip", parent: 1)])
    #expect(throws: RigError.self) {
        try SourceAvatar.assemble(name: "bad", bodySkeleton: duplicate, headSkeleton: fixture.headSkeleton,
            body: fixture.body, head: fixture.head, clothes: [fixture.clothes], hair: [], bodyMeshNames: ["body-normal"])
    }
    let unresolved = try avatarMeshSource(prefix: "clothes", skeletonRoot: "cf_j_root", jointNames: ["unknown", "cf_s_head"], jointPositions: [.zero, .zero])
    #expect(throws: RigError.self) {
        try SourceAvatar.assemble(name: "bad", bodySkeleton: fixture.bodySkeleton, headSkeleton: fixture.headSkeleton,
            body: fixture.body, head: fixture.head, clothes: [unresolved], hair: [], bodyMeshNames: ["body-normal"])
    }
    for clothPart in 0..<2 {
        let parts = fixture.clothes.parts.enumerated().map { index, part in
            SourceRig.Part(mesh: part.mesh, node: part.node, skin: part.skin, rendererEnabled: part.rendererEnabled, hasCloth: index == clothPart)
        }
        let cloth = SourceRig(sourcePrefab: "cloth", rig: fixture.clothes.rig, parts: parts, morphChannelCount: 0)
        let withCloth = AvatarFixture(bodySkeleton: fixture.bodySkeleton, headSkeleton: fixture.headSkeleton,
            body: fixture.body, head: fixture.head, clothes: cloth, hair: fixture.hair)
        if clothPart == 0 {
            #expect(throws: RigError.self) { try withCloth.assemble() }
        } else {
            // A skipped alternate state has no effect on the selected non-Cloth renderer.
            #expect(try withCloth.assemble().parts.count == 4)
        }
    }
}
