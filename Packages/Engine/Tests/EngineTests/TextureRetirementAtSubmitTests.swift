import Foundation
import Testing
import Metal
import CoreGraphics
import Assets
import CoreMath
import ShaderTypes
@testable import Renderer

// R6, #368: a texture an owner retires (`retire(textures:)`, the ST-A11 map
// path) is released by the next submit of a frame created after the
// retirement, with or without a prepared frame: an occluded or minimized
// viewport prepares nothing. A frame created before the retirement and
// submitted after it took its own reference at its submit, so it still draws
// the texture.

/// Releases every retirement, as the next submitted frame's preparation does.
private func nextFrame(_ resources: ResourceStore) {
    resources.completeRetirements(createdBefore: ResourceClock.tick())
}

/// A solid red texture, so a frame that samples it renders differently from
/// the white fallback a missing texture binds.
private func solidTexture(_ resources: ResourceStore, key: String) throws -> TextureHandle {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
    descriptor.usage = .shaderRead
    let texture = try #require(resources.device.makeTexture(descriptor: descriptor))
    let red = [UInt8](repeating: 0, count: 64).enumerated().map { $0.offset % 4 == 0 || $0.offset % 4 == 3 ? UInt8(255) : 0 }
    texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: red, bytesPerRow: 16)
    return resources.register(texture: texture, key: key)
}

/// A frame drawing one triangle that samples `base`; `deformKey` adds a morph
/// target, so the frame's deform pass asks the store for that key's buffer.
private func triangleFrame(_ resources: ResourceStore, base: TextureHandle?, deformKey: UInt64? = nil) throws -> RenderFrame {
    let positions = [Float3(-1.5, -0.5, 0), Float3(1.5, -0.5, 0), Float3(0, 3, 0)]
    let morph = MeshData.MorphTarget(name: "move", positionDeltas: [Float3](repeating: Float3(0.1, 0, 0), count: 3), normalDeltas: [])
    let mesh = try resources.register(mesh: MeshData(name: "submit-release", positions: positions,
        normals: [Float3](repeating: Float3(0, 0, 1), count: 3), uvs: [Float2](repeating: Float2(0.5, 0.5), count: 3),
        indices: [0, 1, 2], morphTargets: deformKey == nil ? [] : [morph]))
    var material = MaterialState(uniforms: .make(kind: MaterialKindItem))
    material.base = base
    // As the builders set it; preparation clears it when the texture is gone.
    material.setFlag(MaterialFlagHasBaseTexture, base != nil)
    var frame = RenderFrame(items: [RenderItem(mesh: mesh, material: material, model: matrix_identity_float4x4,
                                               objectID: 1, deformKey: deformKey)])
    frame.effects.showGrid = false
    return frame
}

private func pixels(_ renderer: Renderer, _ frame: RenderFrame) throws -> Data {
    let image = try #require(renderer.capture(frame: frame, width: 32, height: 32))
    return try #require(image.dataProvider?.data as Data?)
}

/// No prepared frame follows the submit: the retired texture goes at the next
/// submit of a later frame, with no draw, capture or pick, and the resource
/// generation moves. Meshes still wait for a prepared frame, and a submit
/// with nothing retiring changes nothing.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func aRetiredTextureIsReleasedByTheNextSubmitWithoutAPreparedFrame() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    let handle = try solidTexture(resources, key: "submit-release-" + UUID().uuidString)
    let mesh = try resources.register(mesh: MeshData(name: "retired", positions: [Float3(0, 0, 0), Float3(1, 0, 0), Float3(0, 1, 0)],
                                                     normals: [Float3](repeating: Float3(0, 0, 1), count: 3), indices: [0, 1, 2]))
    var generation = resources.generation
    renderer.submit(RenderFrame())
    #expect(resources.generation == generation)
    resources.retire(textures: [handle])
    resources.retire(meshes: [mesh])
    let retiring = resources.statistics()
    #expect(retiring.retiring == 2 && retiring.retiringTextures == 1 && retiring.retiringMeshes == 1, "\(retiring)")
    generation = resources.generation
    renderer.submit(RenderFrame())
    let submitted = resources.statistics()
    #expect(resources.texture(handle) == nil && submitted.retiringTextures == 0, "\(submitted)")
    #expect(resources.generation != generation)
    #expect(resources.mesh(mesh) != nil && submitted.retiringMeshes == 1, "\(submitted)")
    nextFrame(resources)
    #expect(resources.mesh(mesh) == nil && resources.statistics().retiring == 0)
}

/// A frame created before the retirement and submitted after it took its own
/// reference at its submit: once a later frame's submit releases the texture,
/// that frame (the replaced pending frame, or a copy from `currentFrame`)
/// still draws exactly what it drew before.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func aFrameCreatedBeforeATextureRetirementAndSubmittedAfterItStillDrawsTheTexture() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    let key = "submit-drawn-" + UUID().uuidString
    let handle = try solidTexture(resources, key: key)
    let frame = try triangleFrame(resources, base: handle)
    let textured = try pixels(renderer, frame)
    var fallback = frame
    fallback.items[0].material.base = nil
    #expect(try pixels(renderer, fallback) != textured)

    resources.retire(textures: [handle])
    #expect(resources.lookup(key: key) == nil && resources.statistics().retiringTextures == 1)
    renderer.submit(frame)
    // Created before the retirement: its submit releases nothing.
    #expect(resources.texture(handle) != nil && resources.statistics().retiringTextures == 1)
    let pending = renderer.currentFrame()
    renderer.submit(RenderFrame())
    #expect(resources.texture(handle) == nil && resources.statistics().retiring == 0)
    #expect(try pixels(renderer, pending) == textured)
}

/// A texture release at submit leaves the deformation-key ordering alone: a
/// frame created before the retirement still caches its new deformation
/// buffer, instead of getting a transient one on every preparation (during a
/// drag). A completed mesh retirement, which does order deformation keys,
/// still makes such a frame's new buffer transient.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func aTextureReleaseAtSubmitKeepsDeformationBuffersCachedForOlderFrames() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    let handle = try solidTexture(resources, key: "submit-deform-" + UUID().uuidString)
    let older = try triangleFrame(resources, base: nil, deformKey: 0x5ec0_0001)
    resources.retire(textures: [handle])
    renderer.submit(RenderFrame())
    #expect(resources.texture(handle) == nil && resources.statistics().retiring == 0)
    _ = try pixels(renderer, older)
    #expect(resources.holdsDeformBuffer(key: 0x5ec0_0001))

    let olderStill = try triangleFrame(resources, base: nil, deformKey: 0x5ec0_0002)
    let retired = try resources.register(mesh: MeshData(name: "retired", positions: [Float3(0, 0, 0), Float3(1, 0, 0), Float3(0, 1, 0)],
                                                        normals: [Float3](repeating: Float3(0, 0, 1), count: 3), indices: [0, 1, 2]))
    resources.retire(meshes: [retired])
    nextFrame(resources)
    _ = try pixels(renderer, olderStill)
    #expect(!resources.holdsDeformBuffer(key: 0x5ec0_0002))
}
