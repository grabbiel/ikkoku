import Foundation
import Testing
import Metal
import simd
import Assets
import CoreMath
@testable import Scene
import Character
@testable import Renderer

private func previewRigFixture(malformedSecondPart: Bool = false) throws -> SourceRig {
    let rig = try RigDefinition(nodes: [
        .init(name: "mesh", sourceID: "mesh", parent: nil),
        .init(name: "joint", sourceID: "joint", parent: nil)], skins: [
            .init(name: "skin", meshNode: 0, joints: [1], inverseBindMatrices: [matrix_identity_float4x4])])
    let mesh = MeshData(name: "preview triangle", positions: [.zero, Float3(1, 0, 0), Float3(0, 1, 0)],
                        normals: [Float3](repeating: Float3(0, 0, 1), count: 3),
                        joints: [SIMD4<UInt16>](repeating: .zero, count: 3),
                        weights: [Float4](repeating: Float4(1, 0, 0, 0), count: 3), indices: [0, 1, 2])
    var parts = [SourceRig.Part(mesh: mesh, node: 0, skin: 0, rendererEnabled: true)]
    if malformedSecondPart {
        var invalid = mesh
        invalid.weights = [Float4](repeating: .zero, count: 3)
        parts.append(SourceRig.Part(mesh: invalid, node: 0, skin: 0, rendererEnabled: true))
    }
    return SourceRig(sourcePrefab: "test", rig: rig, parts: parts, morphChannelCount: 0)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceRigPreviewReleasesMeshesAndDeformationBuffers() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    var preview: SourceRigPreview? = try SourceRigPreview(source: previewRigFixture(), contract: nil, resources: resources)
    weak var weakPreview = preview
    let frame = try #require(preview).frame(camera: OrbitCamera())
    let item = try #require(frame.items.first)
    let retainedMesh = try #require(resources.mesh(item.mesh))
    let key = try #require(item.deformKey)
    let oldDeform = resources.deformBuffer(for: key, vertexCount: 3)
    preview = nil
    #expect(weakPreview == nil)
    #expect(resources.mesh(item.mesh) == nil)
    #expect(retainedMesh.vertexCount == 3) // A prepared frame can still retain its mesh.
    let replacement = resources.deformBuffer(for: key, vertexCount: 3)
    #expect(oldDeform !== replacement)
    resources.releaseDeformBuffers(keys: [key])
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceRigPreviewRollsBackMeshesWhenLaterRegistrationFails() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let source = try previewRigFixture(malformedSecondPart: true)
    #expect(throws: ResourceError.self) {
        try SourceRigPreview(source: source, contract: nil, resources: resources)
    }
    // A fresh store assigns handle one to the valid first part before the second fails.
    #expect(resources.mesh(MeshHandle(id: 1)) == nil)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceRigPreviewRejectsInactiveBoundsAndAcceptsSkeletonOnly() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    for active in [false, true] {
        let rig = try RigDefinition(nodes: [.init(name: "root", sourceID: "root", parent: nil, active: active)], skins: [])
        let source = SourceRig(sourcePrefab: "skeleton", rig: rig, parts: [], morphChannelCount: 0)
        if active {
            let preview = try SourceRigPreview(source: source, contract: nil, resources: resources)
            #expect(try preview.bounds().center == .zero)
        } else {
            #expect(throws: RigError.self) { try SourceRigPreview(source: source, contract: nil, resources: resources) }
        }
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceRigPreviewRepeatsMaterialSlotsWithoutDuplicatingGeometry() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("appearance.json")
    try Data(#"{"schemaVersion":1,"parts":[{"part":"preview triangle","kind":"unlit","color":[1,1,1,1],"alphaMode":"BLEND"},{"part":"preview triangle","pass":1,"kind":"unlit","color":[1,0,0,1],"alphaMode":"BLEND"}]}"#.utf8).write(to: url)
    let appearance = try SourcePreviewAppearance.load(url: url, resources: resources)
    let preview = try SourceRigPreview(source: previewRigFixture(), contract: nil, resources: resources, appearance: appearance)
    let frame = try preview.frame(camera: OrbitCamera())
    #expect(frame.items.count == 2)
    #expect(frame.items[0].mesh == frame.items[1].mesh)
    #expect(frame.items[0].deformKey == frame.items[1].deformKey)
    #expect(frame.items.map(\.order) == [0, 1])
    #expect(frame.items[0].material.uniforms.baseColor != frame.items[1].material.uniforms.baseColor)
    #expect(frame.skinSets.count == 1)
}
