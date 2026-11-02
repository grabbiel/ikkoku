import Foundation
import Testing
import Metal
import CoreGraphics
import Assets
import CoreMath
import ShaderTypes
import Character
@testable import Renderer

// #332: the appearance texture cache keeps unpinned textures up to its byte
// budget and retires the least recently used beyond it. Pins come from live
// appearances (their texture owners' leases), so nothing a live appearance
// draws is evicted, and an evicted texture stays for a frame created before
// the eviction. The next submit of a later frame releases it, with or without
// a prepared frame (run D of #358: an occluded viewport prepares nothing).

private func cachedTexture(_ resources: ResourceStore, key: String) throws -> TextureHandle {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
    descriptor.usage = .shaderRead
    let texture = try #require(resources.device.makeTexture(descriptor: descriptor))
    return resources.register(texture: texture, key: key)
}

private func bytes(_ resources: ResourceStore, _ handle: TextureHandle) throws -> Int {
    try #require(resources.texture(handle)).allocatedSize
}

/// Releases every retirement, as the next submitted frame's preparation does.
private func nextFrame(_ resources: ResourceStore) {
    resources.completeRetirements(createdBefore: ResourceClock.tick())
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func unpinnedTexturesPastTheBudgetGoLeastRecentlyUsedFirst() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let keys = ["a", "b", "c"].map { "lru-\($0)-" + UUID().uuidString }
    let handles = try keys.map { try cachedTexture(resources, key: $0) }
    let size = try bytes(resources, handles[0])
    resources.unpinnedTextureBudget = 2 * size
    for (handle, key) in zip(handles, keys) { #expect(resources.pinCachedTexture(handle, key: key)) }
    #expect(resources.statistics().unpinnedTextures == 0)
    for handle in handles { resources.unpinTexture(handle) }
    // a was unpinned first: it goes, b and c fit.
    #expect(resources.lookup(key: keys[0]) == nil)
    #expect(resources.lookup(key: keys[1]) == handles[1] && resources.lookup(key: keys[2]) == handles[2])
    #expect(resources.statistics().unpinnedTextures == 2 && resources.statistics().unpinnedTextureBytes == 2 * size)
    // A hit makes b the most recent; one texture's budget then keeps b.
    #expect(resources.pinCachedTexture(handles[1], key: keys[1]))
    resources.unpinTexture(handles[1])
    resources.unpinnedTextureBudget = size
    #expect(resources.lookup(key: keys[2]) == nil && resources.lookup(key: keys[1]) == handles[1])
    #expect(resources.statistics().unpinnedTextureBytes == size)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func aPinnedTextureStaysPastTheBudgetUntilItsLastPinEnds() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    resources.unpinnedTextureBudget = 0
    let key = "lru-pinned-" + UUID().uuidString
    let handle = try cachedTexture(resources, key: key)
    #expect(resources.pinCachedTexture(handle, key: key))
    #expect(resources.pinCachedTexture(handle, key: key))
    resources.unpinTexture(handle)
    nextFrame(resources)
    #expect(resources.lookup(key: key) == handle && resources.texture(handle) != nil)
    resources.unpinTexture(handle)
    #expect(resources.lookup(key: key) == nil)
    // An extra unpin does nothing.
    resources.unpinTexture(handle)
    #expect(resources.statistics().unpinnedTextures == 0 && resources.statistics().unpinnedTextureBytes == 0)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func anEvictedTextureStaysForAFrameCreatedBeforeTheEviction() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    resources.unpinnedTextureBudget = 0
    let key = "lru-pending-" + UUID().uuidString
    let handle = try cachedTexture(resources, key: key)
    #expect(resources.pinCachedTexture(handle, key: key))
    let pendingFrame = ResourceClock.tick()
    resources.unpinTexture(handle)
    #expect(resources.lookup(key: key) == nil)
    resources.completeRetirements(createdBefore: pendingFrame)
    #expect(resources.texture(handle) != nil)
    nextFrame(resources)
    #expect(resources.texture(handle) == nil)
    // Released: a late pin fails, so its load runs again.
    #expect(!resources.pinCachedTexture(handle, key: key))
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func aPinBetweenEvictionAndReleaseTakesTheTextureBack() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    resources.unpinnedTextureBudget = 0
    let key = "lru-rescue-" + UUID().uuidString
    let handle = try cachedTexture(resources, key: key)
    #expect(resources.pinCachedTexture(handle, key: key))
    resources.unpinTexture(handle)
    #expect(resources.lookup(key: key) == nil && resources.statistics().retiring == 1)
    // A load's lookup returned the handle just before the eviction.
    #expect(resources.pinCachedTexture(handle, key: key))
    #expect(resources.lookup(key: key) == handle && resources.statistics().retiring == 0)
    nextFrame(resources)
    #expect(resources.texture(handle) != nil)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func anOwnersRetireOrUnregisterEndsTheCachesInterest() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let retiredKey = "lru-retired-" + UUID().uuidString, droppedKey = "lru-dropped-" + UUID().uuidString
    let retired = try cachedTexture(resources, key: retiredKey), dropped = try cachedTexture(resources, key: droppedKey)
    #expect(resources.pinCachedTexture(retired, key: retiredKey) && resources.pinCachedTexture(dropped, key: droppedKey))
    resources.unpinTexture(dropped)
    resources.retire(textures: [retired])
    resources.unregister(texture: dropped)
    #expect(!resources.pinCachedTexture(retired, key: retiredKey) && !resources.pinCachedTexture(dropped, key: droppedKey))
    resources.unpinTexture(retired)
    #expect(resources.statistics().unpinnedTextures == 0 && resources.statistics().unpinnedTextureBytes == 0)
}

private struct TextureCacheFixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        for name in ["direct.png", "published.png"] { try png.write(to: directory.appendingPathComponent(name)) }
    }
    func document(_ texture: String) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".json")
        let part: [String: Any] = ["part": "part0/0", "kind": "unlit", "color": [1, 1, 1, 1], "alphaMode": "OPAQUE", "texture": texture]
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "parts": [part]]).write(to: url)
        return url
    }
    func key(_ name: String) -> String { directory.appendingPathComponent(name).resolvingSymlinksInPath().path + "#true#true" }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Both publication paths pin what the appearance draws: the default load's
/// cached registration, and a transaction's commit. A later load's hit pins
/// again, so the texture stays until the last appearance drawing it goes.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveAppearancesPinTheirCachedTexturesOnBothPublicationPaths() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    resources.unpinnedTextureBudget = 0
    let observations = try await liveTickOffPool { () throws -> [(String, Bool)] in
        let fixture = try TextureCacheFixture(); defer { fixture.remove() }
        var checks: [(String, Bool)] = []
        let directURL = try fixture.document("direct.png")
        var direct: SourcePreviewAppearance? = try SourcePreviewAppearance.load(url: directURL, resources: resources)
        let directHandle = direct?.materials["part0/0"]?.first?.base
        checks.append(("The default load publishes its texture", directHandle != nil && resources.lookup(key: fixture.key("direct.png")) == directHandle))
        var hit: SourcePreviewAppearance? = try SourcePreviewAppearance.load(url: directURL, resources: resources,
            transaction: SourceAppearanceLoadTransaction(resources: resources))
        checks.append(("A transaction's load hits the published texture", hit?.materials["part0/0"]?.first?.base == directHandle))
        withExtendedLifetime(hit) {
            direct = nil
            checks.append(("The hit's pin keeps the texture after its publisher goes", resources.lookup(key: fixture.key("direct.png")) == directHandle))
        }
        hit = nil
        checks.append(("The last appearance's release evicts it past the budget", resources.lookup(key: fixture.key("direct.png")) == nil))

        let transaction = SourceAppearanceLoadTransaction(resources: resources)
        var published: SourcePreviewAppearance? = try SourcePreviewAppearance.load(url: try fixture.document("published.png"),
            resources: resources, transaction: transaction)
        let publishedHandle = published?.materials["part0/0"]?.first?.base
        checks.append(("A transaction's candidate stays private until commit", resources.lookup(key: fixture.key("published.png")) == nil))
        withExtendedLifetime(published) {
            transaction.commit()
            checks.append(("Commit publishes the candidate pinned for its appearance", publishedHandle != nil && resources.lookup(key: fixture.key("published.png")) == publishedHandle))
            nextFrame(resources)
            checks.append(("The pinned texture stays past a frame", publishedHandle.flatMap { resources.texture($0) } != nil))
        }
        published = nil
        checks.append(("Its appearance's release evicts it", resources.lookup(key: fixture.key("published.png")) == nil))
        nextFrame(resources)
        checks.append(("The next frame releases it", publishedHandle.flatMap { resources.texture($0) } == nil))
        checks.append(("No unpinned bytes remain", resources.statistics().unpinnedTextureBytes == 0))
        return checks
    }
    for (name, passed) in observations { #expect(passed, "\(name)") }
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

/// Run D of #358: no viewport prepared a frame, so evicted textures were never
/// released. The next submit of a later frame releases them now, with no
/// draw, capture or pick, and bumps the resource generation. Meshes and keys
/// still wait for a prepared frame, and a submit with nothing retiring
/// changes nothing.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func anEvictedTextureIsReleasedByTheNextSubmitWithoutAPreparedFrame() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    resources.unpinnedTextureBudget = 0
    let key = "lru-submit-" + UUID().uuidString
    let handle = try cachedTexture(resources, key: key)
    let mesh = try resources.register(mesh: MeshData(name: "retired", positions: [Float3(0, 0, 0), Float3(1, 0, 0), Float3(0, 1, 0)],
                                                     normals: [Float3](repeating: Float3(0, 0, 1), count: 3), indices: [0, 1, 2]))
    var generation = resources.generation
    renderer.submit(RenderFrame())
    #expect(resources.generation == generation)
    #expect(resources.pinCachedTexture(handle, key: key))
    resources.unpinTexture(handle)
    resources.retire(meshes: [mesh])
    let retiring = resources.statistics()
    #expect(retiring.retiring == 2 && retiring.retiringTextures == 1 && retiring.retiringMeshes == 1, "\(retiring)")
    generation = resources.generation
    renderer.submit(RenderFrame())
    let submitted = resources.statistics()
    #expect(resources.texture(handle) == nil && submitted.retiringTextures == 0, "\(submitted)")
    #expect(resources.generation != generation)
    #expect(resources.mesh(mesh) != nil && submitted.retiringMeshes == 1, "\(submitted)")
    // Released: a late pin fails, so its load runs again.
    #expect(!resources.pinCachedTexture(handle, key: key))
    nextFrame(resources)
    #expect(resources.mesh(mesh) == nil && resources.statistics().retiring == 0)
}

/// A frame created before an eviction and submitted after it took its own
/// reference at its submit: once a later frame's submit releases the texture,
/// that frame (the replaced pending frame, or a copy from `currentFrame`)
/// still draws exactly what it drew before the eviction.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func aFrameCreatedBeforeAnEvictionAndSubmittedAfterItStillDrawsTheTexture() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    resources.unpinnedTextureBudget = 0
    let key = "lru-drawn-" + UUID().uuidString
    let handle = try solidTexture(resources, key: key)
    #expect(resources.pinCachedTexture(handle, key: key))
    let frame = try triangleFrame(resources, base: handle)
    let textured = try pixels(renderer, frame)
    var fallback = frame
    fallback.items[0].material.base = nil
    #expect(try pixels(renderer, fallback) != textured)

    resources.unpinTexture(handle)
    #expect(resources.lookup(key: key) == nil && resources.statistics().retiringTextures == 1)
    renderer.submit(frame)
    // Created before the eviction: its submit releases nothing.
    #expect(resources.texture(handle) != nil && resources.statistics().retiringTextures == 1)
    let pending = renderer.currentFrame()
    renderer.submit(RenderFrame())
    #expect(resources.texture(handle) == nil && resources.statistics().retiring == 0)
    #expect(try pixels(renderer, pending) == textured)
}

/// The rescue still works with the release at submit: a pin between the
/// eviction and the next submit takes the texture back, and that submit
/// keeps it. A later eviction releases it at the following submit.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func aPinBeforeTheNextSubmitTakesAnEvictedTextureBack() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    resources.unpinnedTextureBudget = 0
    let key = "lru-submit-rescue-" + UUID().uuidString
    let handle = try cachedTexture(resources, key: key)
    #expect(resources.pinCachedTexture(handle, key: key))
    resources.unpinTexture(handle)
    #expect(resources.lookup(key: key) == nil && resources.statistics().retiringTextures == 1)
    #expect(resources.pinCachedTexture(handle, key: key))
    renderer.submit(RenderFrame())
    #expect(resources.texture(handle) != nil && resources.lookup(key: key) == handle)
    #expect(resources.statistics().retiring == 0)
    resources.unpinTexture(handle)
    renderer.submit(RenderFrame())
    #expect(resources.texture(handle) == nil && resources.statistics().retiring == 0)
}

/// A texture release at submit leaves the deformation-key ordering alone: a
/// frame created before the eviction still caches its new deformation buffer,
/// instead of getting a transient one on every preparation (during a drag).
/// A completed mesh retirement, which does order deformation keys, still makes
/// such a frame's new buffer transient.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func aTextureReleaseAtSubmitKeepsDeformationBuffersCachedForOlderFrames() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    resources.unpinnedTextureBudget = 0
    let key = "lru-deform-" + UUID().uuidString
    let handle = try cachedTexture(resources, key: key)
    #expect(resources.pinCachedTexture(handle, key: key))
    let older = try triangleFrame(resources, base: nil, deformKey: 0x5ec0_0001)
    resources.unpinTexture(handle)
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
