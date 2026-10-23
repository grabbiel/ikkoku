import Testing
import Foundation
import Assets
import Scene
import CoreMath
import simd

private func fixtureURL(_ name: String) -> URL {
    // Packages/Engine/Tests/EngineTests/ → repo root
    let here = URL(fileURLWithPath: #filePath)
    return here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets/fixtures/\(name)")
}

@Test func loadsRigFixtureWithSkinAndMorphs() throws {
    let asset = try GLBLoader.load(url: fixtureURL("rig_fixture.gltf"))
    #expect(asset.skins.count == 1)
    let mesh = try #require(asset.meshes.first?.primitives.first)
    #expect(mesh.vertexCount == 425)
    #expect(mesh.isSkinned)
    #expect(mesh.morphTargets.map(\.name) == ["DisplaceY", "DisplaceX"])
    // The fixture's second influence set is folded to four lanes; that loss is reported.
    #expect(asset.diagnostics.map(\.code) == ["skin_influences_reduced"])
    #expect(asset.diagnostics.first?.message.contains("88 of 425 vertices lost nonzero weight") == true)
    let skel = try #require(Skeleton.from(asset: asset))
    #expect(skel.count == 6)
    #expect(skel["spine_b"] != nil)
    let rest = skel.restPose.skinMatrices(skeleton: skel)
    // Bind pose skin matrices should be identity-ish.
    for m in rest {
        #expect(abs(m.columns.3.x) < 1e-3 && abs(m.columns.3.y) < 1e-3 && abs(m.columns.3.z) < 1e-3)
    }
}

@Test func bundledAssetsLoadUnchangedUnderInterchangeChecks() throws {
    // Every checked-in GLB/glTF passes the stricter R5 validation, decodes no secondary UVs
    // or texture-coordinate selections, and reports nothing except the fixtures' influence fold.
    let assets = fixtureURL("").deletingLastPathComponent()
    let files = try #require(FileManager.default.enumerator(at: assets, includingPropertiesForKeys: [.isRegularFileKey]))
    var count = 0
    for case let url as URL in files where ["glb", "gltf"].contains(url.pathExtension.lowercased()) {
        let asset = try GLBLoader.load(url: url)
        count += 1
        let expected: [String] = url.deletingLastPathComponent().lastPathComponent == "fixtures" ? ["skin_influences_reduced"] : []
        #expect(asset.diagnostics.map(\.code) == expected, "\(url.lastPathComponent): \(asset.diagnostics)")
        #expect(asset.meshes.allSatisfy { $0.primitives.allSatisfy { $0.uvs1.isEmpty && $0.uvs2.isEmpty } }, "\(url.lastPathComponent)")
        #expect(asset.materials.allSatisfy { $0.baseColorTexCoord == 0 && $0.normalTexCoord == 0 }, "\(url.lastPathComponent)")
    }
    #expect(count > 2)
}

@Test func poseDeltaRotatesBone() throws {
    let asset = try GLBLoader.load(url: fixtureURL("rig_fixture.gltf"))
    let skel = try #require(Skeleton.from(asset: asset))
    let pose = PoseDelta(rotations: ["spine_a": Float3(0, 0, 90)]).apply(to: skel)
    let world = pose.worldMatrices(skeleton: skel)
    let tipIndex = try #require(skel["tip"])
    let tip = world[tipIndex].translation
    // Rotating spine_a 90° about Z swings the tip sideways.
    #expect(abs(tip.x) > 0.5)
}

@Test func twoBoneIKReachesTarget() {
    let a = Float3(0, 1, 0), b = Float3(0, 0.5, 0.05), c = Float3(0, 0, 0)
    let target = Float3(0.3, 0.4, 0.2)
    let r = IKSolver.twoBone(a: a, b: b, c: c, target: target, pole: Float3(0, 0.5, 1))
    let nb = a + r.upper.act(b - a)
    let nc = nb + r.lower.act(c - b)
    #expect(length(nc - target) < 0.05)
}
