import Foundation
import Testing
import Metal
import CryptoKit
import Assets
import CoreMath
import ShaderTypes
import Renderer
import Character
import Scene

private struct AppearanceLoadFixture {
    let directory: URL
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["shared.png", "candidate.png"] { try png.write(to: directory.appendingPathComponent(name)) }
    }
    func document(_ name: String, textures: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name + ".json")
        let parts: [[String: Any]] = textures.enumerated().map { i, texture in
            ["part": "part\(i)/0", "kind": "unlit", "color": [1, 1, 1, 1],
             "alphaMode": "OPAQUE", "texture": texture]
        }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "parts": parts]).write(to: url)
        return url
    }
    func key(_ name: String) -> String { directory.appendingPathComponent(name).resolvingSymlinksInPath().path + "#true#true" }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private struct AppearanceLoadFailure: Error { let reason: String }

private func appearanceValue<T>(_ value: T?, _ reason: String) throws -> T {
    guard let value else { throw AppearanceLoadFailure(reason: reason) }
    return value
}

/// MetalKit's synchronous texture loads may wait for dispatch work. Keep the
/// complete non-Sendable transaction on one dedicated thread, as in the live
/// tick fixture tests, and report every observation on the calling test task.
private func appearanceLoadChecks(_ body: @escaping @Sendable () throws -> [(String, Bool)]) async throws {
    let observations = try await liveTickOffPool(body)
    for (name, passed) in observations { #expect(passed, "\(name)") }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourcePreviewAppearanceCandidateRollsBackPartialLoadWithoutEvictingSharedTextures() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    try await appearanceLoadChecks {
        let fixture = try AppearanceLoadFixture(); defer { fixture.remove() }
        let original = try SourcePreviewAppearance.load(url: fixture.document("shared", textures: ["shared.png"]), resources: resources)
        let shared = try appearanceValue(original.materials["part0/0"]?.first?.base, "Shared base texture is absent")
        let baseline = resources.statistics().textures
        let broken = try fixture.document("broken", textures: ["shared.png", "candidate.png", "absent.png"])
        var rejected = false
        do {
            let transaction = SourceAppearanceLoadTransaction(resources: resources)
            _ = try SourcePreviewAppearance.load(url: broken, resources: resources, transaction: transaction)
        } catch { rejected = true }
        return [
            ("Partial load throws", rejected),
            ("Partial load returns texture count to baseline", resources.statistics().textures == baseline),
            ("Partial load never publishes its candidate", resources.lookup(key: fixture.key("candidate.png")) == nil),
            ("Partial load preserves shared cache identity", resources.lookup(key: fixture.key("shared.png")) == shared),
            ("Partial load preserves shared texture", resources.texture(shared) != nil),
        ]
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourcePreviewAppearanceCandidateRetainsPrivateTextureUntilLastAppearanceIsReleased() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    try await appearanceLoadChecks {
        let fixture = try AppearanceLoadFixture(); defer { fixture.remove() }
        let url = try fixture.document("candidate", textures: ["candidate.png", "candidate.png"])
        let baseline = resources.statistics().textures
        var candidate: SourcePreviewAppearance?
        var checks: [(String, Bool)] = []
        do {
            let transaction = SourceAppearanceLoadTransaction(resources: resources)
            candidate = try SourcePreviewAppearance.load(url: url, resources: resources, transaction: transaction)
            checks.append(("Repeated slots share the private handle", candidate?.materials["part0/0"]?.first?.base == candidate?.materials["part1/0"]?.first?.base))
            // A later validation failure abandons the uncommitted transaction.
            checks.append(("Uncommitted handle stays unpublished", resources.lookup(key: fixture.key("candidate.png")) == nil))
        }
        let handle = try appearanceValue(candidate?.materials["part0/0"]?.first?.base, "Private base texture is absent")
        checks.append(("Appearance retains the abandoned transaction's handle", resources.texture(handle) != nil))
        checks.append(("Appearance owns exactly one private texture", resources.statistics().textures == baseline + 1))
        candidate = nil
        checks.append(("Last appearance release removes its private texture", resources.texture(handle) == nil))
        checks.append(("Last appearance release restores baseline", resources.statistics().textures == baseline))
        return checks
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourcePreviewAppearanceCandidateCommitKeepsCacheCollisionReferencesValid() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    try await appearanceLoadChecks {
        let fixture = try AppearanceLoadFixture(); defer { fixture.remove() }
        let url = try fixture.document("candidate", textures: ["candidate.png"])
        let transaction = SourceAppearanceLoadTransaction(resources: resources)
        var candidate: SourcePreviewAppearance? = try SourcePreviewAppearance.load(url: url, resources: resources, transaction: transaction)
        let privateHandle = try appearanceValue(candidate?.materials["part0/0"]?.first?.base, "Private base texture is absent")
        // Another consumer publishes this key while the candidate is uncommitted.
        let other = try SourcePreviewAppearance.load(url: url, resources: resources)
        let shared = try appearanceValue(other.materials["part0/0"]?.first?.base, "Published base texture is absent")
        var checks = [("Concurrent cache publication owns a distinct handle", privateHandle != shared)]
        transaction.commit()
        checks.append(("Commit preserves the published cache identity", resources.lookup(key: fixture.key("candidate.png")) == shared))
        checks.append(("Both references remain valid after collision", resources.texture(privateHandle) != nil && resources.texture(shared) != nil))
        candidate = nil
        checks.append(("Collision appearance release removes only its private texture", resources.texture(privateHandle) == nil))
        checks.append(("Collision appearance release preserves the shared texture", resources.texture(shared) != nil))
        let cachedTransaction = SourceAppearanceLoadTransaction(resources: resources)
        let cached = try SourcePreviewAppearance.load(url: url, resources: resources, transaction: cachedTransaction)
        checks.append(("Later transactions use the shared handle", cached.materials["part0/0"]?.first?.base == shared))
        cachedTransaction.commit()
        checks.append(("Cached transaction commit preserves cache identity", resources.lookup(key: fixture.key("candidate.png")) == shared))
        return checks
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourcePreviewAppearanceCandidateCommitPreservesSuccessfulCacheBehavior() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    try await appearanceLoadChecks {
        let fixture = try AppearanceLoadFixture(); defer { fixture.remove() }
        let url = try fixture.document("candidate", textures: ["candidate.png"])
        var candidate: SourcePreviewAppearance?
        do {
            let transaction = SourceAppearanceLoadTransaction(resources: resources)
            candidate = try SourcePreviewAppearance.load(url: url, resources: resources, transaction: transaction)
            transaction.commit()
        }
        let handle = try appearanceValue(candidate?.materials["part0/0"]?.first?.base, "Committed base texture is absent")
        candidate = nil
        var checks = [
            ("Committed texture survives appearance release", resources.texture(handle) != nil),
            ("Committed texture is cached", resources.lookup(key: fixture.key("candidate.png")) == handle),
        ]
        var created: [TextureHandle] = []
        let existing = try resources.texture(data: fixture.png, key: fixture.directory.appendingPathComponent("candidate.png").resolvingSymlinksInPath().path + "#true",
            didCreate: { created.append($0) })
        checks.append(("Cache hit does not report a creation", existing == handle && created.isEmpty))
        let new = try resources.texture(data: fixture.png, key: "private-callback", cacheNew: false, didCreate: { created.append($0) })
        checks.append(("Private creation reports its handle without caching", created == [new] && resources.lookup(key: "private-callback#true") == nil))
        resources.unregister(texture: new)
        return checks
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourcePreviewAppearanceEnablesBothLoadedIrisHighlightsAndOriginalUVPath() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Public synthetic 1×1 PNG; no extracted game assets are needed for this loader check.
    let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    for name in ["iris.png", "upper.png", "lower.png"] {
        try png.write(to: directory.appendingPathComponent(name))
    }
    let document: [String: Any] = ["schemaVersion": 1, "parts": [
        ["part": "iris/0", "kind": "unlit", "color": [1, 1, 1, 1], "alphaMode": "BLEND",
         "texture": "iris.png", "irisHighlights": ["upper": "upper.png", "lower": "lower.png",
             "colors": [[1, 0.25, 0.125, 0.5], [0.125, 0.5, 1, 1]], "strength": 0.75]],
        ["part": "plain/0", "kind": "unlit", "color": [1, 1, 1, 1], "alphaMode": "OPAQUE"],
    ]]
    let url = directory.appendingPathComponent("appearance.json")
    try JSONSerialization.data(withJSONObject: document).write(to: url)
    let appearance = try SourcePreviewAppearance.load(url: url, resources: resources)
    let iris = try #require(appearance.materials["iris/0"]?.first)
    let upper = try #require(iris.overlay0), lower = try #require(iris.overlay1)
    #expect(upper != lower)
    for handle in [try #require(iris.base), upper, lower] {
        let texture = try #require(resources.texture(handle))
        #expect(texture.width == 1 && texture.height == 1)
    }
    // Loading textures alone does not activate the shader samples. All three bits
    // are required: the source bit chooses UV1/UV2; overlay bits enable each map.
    for flag in [MaterialFlagHasBaseTexture, MaterialFlagHasOverlay0, MaterialFlagHasOverlay1,
                 MaterialFlagSourceIrisHighlights] {
        #expect((iris.uniforms.flags & flag.rawValue) != 0)
    }
    #expect(iris.uniforms.overlayColor0 == Float4(1, 0.25, 0.125, 0.5))
    #expect(iris.uniforms.overlayColor1 == Float4(0.125, 0.5, 1, 1))
    #expect(iris.uniforms.eye.w == 0.75 && iris.transparent)
    let plain = try #require(appearance.materials["plain/0"]?.first)
    #expect(plain.overlay0 == nil && plain.overlay1 == nil)
    for flag in [MaterialFlagHasOverlay0, MaterialFlagHasOverlay1, MaterialFlagSourceIrisHighlights] {
        #expect((plain.uniforms.flags & flag.rawValue) == 0)
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourcePreviewAppearanceResolvesPackageTextureBindingsWithoutFallbackFiles() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let packageDirectory = directory.appendingPathComponent("package")
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    let pngHash = hash(png), archiveHash = hash(Data("synthetic preview package archive".utf8))
    try png.write(to: packageDirectory.appendingPathComponent("converted.png"))
    let bundlePath = "abdata/chara/synthetic.unity3d", assetName = "synthetic-base"
    let manifest: [String: Any] = [
        "schemaVersion": 1, "kind": "ikkoku-mod-package",
        "converter": ["id": "ikkoku.zipmod", "version": "1.0.0"],
        "source": ["guid": "test.preview.texture", "version": "1", "name": "Synthetic preview texture",
                   "archiveSHA256": archiveHash, "games": ["Koikatsu"]],
        "resources": [["id": "texture-1", "kind": "texture2D", "bundlePath": bundlePath, "assetName": assetName,
                       "sourcePathID": 1, "sourceSHA256": pngHash, "path": "converted.png",
                       "sha256": pngHash, "status": "converted", "width": 1, "height": 1]],
        "catalogs": [], "diagnostics": [],
    ]
    let packageURL = packageDirectory.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: manifest).write(to: packageURL)
    let textureKey = "avatar-base.png"
    var document: [String: Any] = [
        "schemaVersion": 1, "modPackages": ["package/manifest.json"],
        "textureBindings": [textureKey: ["bundlePath": bundlePath, "assetName": assetName]],
        "parts": [["part": "avatar/0", "kind": "unlit", "color": [1, 1, 1, 1],
                   "alphaMode": "OPAQUE", "texture": textureKey]],
    ]
    let appearanceURL = directory.appendingPathComponent("appearance.json")
    try JSONSerialization.data(withJSONObject: document).write(to: appearanceURL)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(textureKey).path))
    let appearance = try SourcePreviewAppearance.load(url: appearanceURL, resources: resources)
    let material = try #require(appearance.materials["avatar/0"]?.first)
    let base = try #require(material.base)
    let texture = try #require(resources.texture(base))
    #expect(texture.width == 1 && texture.height == 1)
    #expect((material.uniforms.flags & MaterialFlagHasBaseTexture.rawValue) != 0)

    // The appearance loader must use the mounted source identity and its content
    // hashes, not manufacture a fallback file identity for the converted bytes.
    let library = try SourceModLibrary(packages: [SourceModPackage.load(url: packageURL)])
    let resolved = try #require(try library.texture(bundlePath: bundlePath, assetName: assetName))
    #expect(resolved.data == png)
    #expect(resolved.cacheKey.contains(pngHash) && resolved.cacheKey.contains(archiveHash))
    let expectedHandle = try resources.texture(data: resolved.data, key: resolved.cacheKey + "#true", srgb: true)
    #expect(base == expectedHandle)

    // A broken explicit binding must report the missing mounted asset even if a
    // same-named loose PNG happens to exist beside the appearance document.
    try png.write(to: directory.appendingPathComponent(textureKey))
    document["textureBindings"] = [textureKey: ["bundlePath": bundlePath, "assetName": "absent-texture"]]
    try JSONSerialization.data(withJSONObject: document).write(to: appearanceURL)
    #expect(throws: RigError.self) { try SourcePreviewAppearance.load(url: appearanceURL, resources: resources) }
}
