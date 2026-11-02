import Foundation
import Testing
import Metal
import simd
import Assets
import CoreMath
@testable import Scene
import Character
@testable import Renderer

// #344: a frame being prepared resolves an item's mesh (Renderer.swift, the
// deform pass) and then requests the item's deformation buffer, without the
// store's lock in between. An owner dropped there must not leave a buffer
// cached for a key nothing releases again.

private func triangle(_ name: String) -> MeshData {
    MeshData(name: name, positions: [.zero, Float3(1, 0, 0), Float3(0, 1, 0)],
             normals: [Float3](repeating: Float3(0, 0, 1), count: 3), indices: [0, 1, 2])
}

/// A skinned one-triangle rig: its preview item deforms, and draws live with
/// the `live_uv` fixture program (which reads both UV sets).
private func skinnedRig() throws -> SourceRig {
    let rig = try RigDefinition(nodes: [
        .init(name: "mesh", sourceID: "mesh", parent: nil),
        .init(name: "joint", sourceID: "joint", parent: nil)], skins: [
            .init(name: "skin", meshNode: 0, joints: [1], inverseBindMatrices: [matrix_identity_float4x4])])
    let mesh = MeshData(name: "o_uv/0", positions: [.zero, Float3(1, 0, 0), Float3(0, 1, 0)],
                        normals: [Float3](repeating: Float3(0, 0, 1), count: 3),
                        uvs: [Float2](repeating: Float2(0.25, 0.25), count: 3), uvs1: [Float2](repeating: Float2(1, 1), count: 3),
                        joints: [SIMD4<UInt16>](repeating: .zero, count: 3),
                        weights: [Float4](repeating: Float4(1, 0, 0, 0), count: 3), indices: [0, 1, 2])
    return SourceRig(sourcePrefab: "test", rig: rig, parts: [SourceRig.Part(mesh: mesh, node: 0, skin: 0, rendererEnabled: true)],
                     morphChannelCount: 0)
}

/// The store-level interleaving: the render thread's mesh lookup succeeds,
/// the owner unregisters the mesh and releases the key, then the render
/// thread requests the buffer. The frame gets one, and the store caches none.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func deformBufferRequestedAfterItsOwnerWasDroppedIsTransient() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let baseline = resources.statistics().deformBuffers
    let mesh = try resources.register(mesh: triangle("dropped"))
    let frame = RenderFrame()
    #expect(resources.mesh(mesh) != nil)          // the render thread's lookup
    resources.unregister(mesh: mesh)              // SourceRigPreview.deinit
    resources.releaseDeformBuffers(keys: [7])
    let buffer = try #require(resources.deformBuffer(for: 7, mesh: mesh, vertexCount: 3, frameCreatedAt: frame.createdAt))
    #expect(buffer.label == "deform.7.transient")
    #expect(resources.statistics().deformBuffers == baseline)

    // A registered mesh's new buffer is cached, and a released key whose mesh
    // is still registered is re-created on its next use, as before.
    let kept = try resources.register(mesh: triangle("kept"))
    let cached = try #require(resources.deformBuffer(for: 8, mesh: kept, vertexCount: 3, frameCreatedAt: RenderFrame().createdAt))
    #expect(resources.statistics().deformBuffers == baseline + 1)
    #expect(resources.deformBuffer(for: 8, mesh: kept, vertexCount: 3) === cached)
    resources.releaseDeformBuffers(keys: [8])
    let again = try #require(resources.deformBuffer(for: 8, mesh: kept, vertexCount: 3, frameCreatedAt: RenderFrame().createdAt))
    #expect(again !== cached && again.label == "deform.8")
    #expect(resources.statistics().deformBuffers == baseline + 1)
    resources.releaseDeformBuffers(keys: [8])
    #expect(resources.statistics().deformBuffers == baseline)
}

/// A retiring mesh stays registered until a later submitted frame completes
/// its retirement. A new buffer for it is transient: the pending frame still
/// deforms into it, and completion finds no key cached behind its back.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func deformBufferRequestedForARetiringMeshIsTransient() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let baseline = resources.statistics().deformBuffers
    let mesh = try resources.register(mesh: triangle("retiring"))
    let pending = RenderFrame()
    resources.retire(meshes: [mesh])
    #expect(resources.mesh(mesh) != nil)
    let buffer = try #require(resources.deformBuffer(for: 9, mesh: mesh, vertexCount: 3, frameCreatedAt: pending.createdAt))
    #expect(buffer.label == "deform.9.transient")
    #expect(resources.statistics().deformBuffers == baseline)
    resources.completeRetirements(createdBefore: RenderFrame().createdAt)
    #expect(resources.mesh(mesh) == nil)
    #expect(resources.statistics().deformBuffers == baseline)
}

/// End to end through frame preparation: a preview dropped between its
/// item's mesh lookup and its buffer request (the store's test hook, on the
/// capture thread) leaves no deformation buffer, mesh or live input behind,
/// and the frame still deforms and draws. The item draws live, so the drop
/// also runs the live encoder's release eviction (#337) mid-preparation.
/// Without the drop the buffer is cached.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func droppingAPreviewDuringItsDeformPassLeavesNoBuffer() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    let directory = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let program = try resources.translatedPipelines.program(url: try LiveProgramFixture.write(LiveProgramFixture.uv, family: "live_uv", to: directory))
    let material = SourceShaderLiveMaterial(label: "o_uv slot 0", family: "live_uv", queue: 2000, passes: [program],
                                            vectors: ["_Color": [0, 0, 1, 1]], textures: [:], conventions: [], textureSources: [:])
    func liveFrame(_ preview: SourceRigPreview) throws -> RenderFrame {
        var frame = try preview.frame(camera: OrbitCamera())
        frame.items = frame.items.map { item in
            var item = item
            item.sourceShader = SourceShaderLiveDraw(material: material, streams: nil, sourceOrder: 0)
            return item
        }
        return frame
    }
    let before = resources.statistics()

    // Control: a preview that stays caches its key's buffer and live input;
    // dropping it between frames releases both.
    var kept: SourceRigPreview? = try SourceRigPreview(source: skinnedRig(), contract: nil, resources: resources)
    let keptFrame = try liveFrame(try #require(kept))
    _ = try #require(renderer.capture(frame: keptFrame, width: 16, height: 16))
    #expect(renderer.lastSourceShaderLive.draws == 1)
    let encoder = try #require(renderer.liveEncoder)
    #expect(resources.statistics().deformBuffers == before.deformBuffers + 1)
    #expect(encoder.bufferCount == 1)
    kept = nil
    #expect(resources.statistics().deformBuffers == before.deformBuffers)
    #expect(encoder.bufferCount == 0)

    final class Owner: @unchecked Sendable { var preview: SourceRigPreview?; var dropped = false }
    let owner = Owner()
    owner.preview = try SourceRigPreview(source: skinnedRig(), contract: nil, resources: resources)
    let frame = try liveFrame(try #require(owner.preview))
    let key = try #require(frame.items.first?.deformKey)
    resources.beforeDeformBuffer = { requested in
        guard requested == key, !owner.dropped else { return }
        owner.dropped = true
        owner.preview = nil   // SourceRigPreview.deinit: its meshes, then its keys
    }
    defer { resources.beforeDeformBuffer = nil }
    _ = try #require(renderer.capture(frame: frame, width: 16, height: 16))
    #expect(owner.dropped)
    let frameError = renderer.lastFrameError
    #expect(frameError == nil, "\(String(describing: frameError))")
    // The frame deforms and draws from the mesh it resolved.
    #expect(renderer.lastFrameStatistics.deformDispatches == 1)
    #expect(renderer.lastSourceShaderLive.draws == 1)
    let after = resources.statistics()
    #expect(after.deformBuffers == before.deformBuffers)
    #expect(after.meshes == before.meshes)
    #expect(encoder.bufferCount == 0)
}
