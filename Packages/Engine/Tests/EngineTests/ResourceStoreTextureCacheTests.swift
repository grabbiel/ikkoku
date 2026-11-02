import Foundation
import Testing
import Metal
import Character
@testable import Renderer

// #332: the appearance texture cache keeps unpinned textures up to its byte
// budget and retires the least recently used beyond it. Pins come from live
// appearances (their texture owners' leases), so nothing a live appearance
// draws is evicted, and an evicted texture stays for a frame created before
// the eviction.

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
