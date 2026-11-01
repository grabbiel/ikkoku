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

@Test func sourceAppearanceScopesKeepNilLabelsLazyAndPreserveBodyResultsAndErrors() throws {
    var labels = 0, bodies = 0
    func identity() -> SourceAppearanceTimings.ScopeIdentity { labels += 1; return .base }
    let value = SourceAppearanceTimings.scoped(nil, identity()) { bodies += 1; return 17 }
    #expect(value == 17 && bodies == 1 && labels == 0)
    do {
        try SourceAppearanceTimings.scoped(nil, identity()) { () throws -> Void in
            bodies += 1; throw AppearanceLoadFailure(reason: "same error")
        }
        Issue.record("Nil diagnostics swallowed the body's error.")
    } catch let error as AppearanceLoadFailure { #expect(error.reason == "same error") }
    #expect(bodies == 2 && labels == 0)
}

@Test func sourceAppearanceScopesSeparatePartialDeltasFromUnscopedAggregateWork() throws {
    let timings = SourceAppearanceTimings()
    _ = SourceAppearanceTimings.measure(timings, .bindingPreparation) { 1 }
    let result = SourceAppearanceTimings.scoped(timings, .base) {
        SourceAppearanceTimings.measure(timings, .pixelReadHash) { 2 }
    }
    #expect(result == 2)
    _ = SourceAppearanceTimings.measure(timings, .pixelReadHash) { 3 }
    do {
        try SourceAppearanceTimings.scoped(timings,
            .component(index: 4, prefix: "accessory-2/", accessorySlot: 2, indoorShoes: false)) {
            _ = SourceAppearanceTimings.measure(timings, .pixelReadHash) { 4 }
            try SourceAppearanceTimings.measure(timings, .pixelReadHash) { () throws -> Void in
                throw AppearanceLoadFailure(reason: "partial")
            }
        }
        Issue.record("Scoped diagnostics swallowed the body's error.")
    } catch let error as AppearanceLoadFailure { #expect(error.reason == "partial") }
    let empty = SourceAppearanceTimings.scoped(timings, .bodyMaskRemove) { true }
    #expect(empty)
    let sample = timings.sample
    #expect(sample.calls == ["bindingPreparation": 1, "pixelReadHash": 4])
    #expect(sample.scopes.count == 3)
    let first = try #require(sample.scopes.first), last = try #require(sample.scopes.last)
    #expect(first.identity == .base && first.succeeded && first.calls == ["pixelReadHash": 1])
    let failed = try #require(sample.scopes.first { !$0.succeeded })
    #expect(failed.identity == .component(index: 4, prefix: "accessory-2/", accessorySlot: 2, indoorShoes: false))
    #expect(failed.calls == ["pixelReadHash": 2] && failed.milliseconds.keys.sorted() == ["pixelReadHash"])
    #expect(last.identity == .bodyMaskRemove && last.succeeded && last.calls.isEmpty && last.milliseconds.isEmpty)
    #expect(sample.composition == nil && sample.scopes.allSatisfy { $0.composition == nil })
}

private func appearanceValue<T>(_ value: T?, _ reason: String) throws -> T {
    guard let value else { throw AppearanceLoadFailure(reason: reason) }
    return value
}

/// Texture loads block their thread. Keep the
/// complete non-Sendable transaction on one dedicated thread, as in the live
/// tick fixture tests, and report every observation on the calling test task.
private func appearanceLoadChecks(_ body: @escaping @Sendable () throws -> [(String, Bool)]) async throws {
    let observations = try await liveTickOffPool(body)
    for (name, passed) in observations { #expect(passed, "\(name)") }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourcePreviewAppearanceLoadDiagnosticsDistinguishPrivateReuseAndSharedHits() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    try await appearanceLoadChecks {
        let fixture = try AppearanceLoadFixture(); defer { fixture.remove() }
        let url = try fixture.document("repeated", textures: ["candidate.png", "candidate.png"])
        let diagnostics = SourceBaseAppearanceTimings()
        let transaction = SourceAppearanceLoadTransaction(resources: resources)
        let appearance = try SourcePreviewAppearance.load(url: url, resources: resources,
            transaction: transaction, timings: diagnostics)
        let handle = try appearanceValue(appearance.materials["part0/0"]?.first?.base, "Private texture is absent")
        let sample = diagnostics.sample
        var checks: [(String, Bool)] = [
            ("Repeated references reuse one live private handle", appearance.materials["part1/0"]?.first?.base == handle && resources.texture(handle) != nil),
            ("Private handle is not published during load", resources.lookup(key: fixture.key("candidate.png")) == nil),
            ("Completed load is distinguished from failures", sample.loadAttempts == 1 && sample.loadFailures == 0),
            ("Repeated file reads count encoded bytes separately", sample.calls["textureFileRead"] == 2 && sample.encodedTextureBytesRead == fixture.png.count * 2),
            ("Document bytes measure the actual JSON read", sample.documentBytesRead == (try Data(contentsOf: url)).count),
            ("Private transaction reuse is not a shared cache hit", sample.textureRequests == 2 && sample.transactionReuses == 1 && sample.textureLoads.dataCacheHits == 0),
            ("Only one reference reaches ResourceStore", sample.textureLoads.dataRequests == 1 && sample.textureLoads.encodedBytesPresented == fixture.png.count),
            ("Both actual cache checks miss for the single new texture", sample.textureLoads.dataCacheMisses == 1 && sample.textureLoads.imageCacheMisses == 1),
            ("One image is created, loaded and registered", sample.textureLoads.calls["imageCreation"] == 1 && sample.textureLoads.calls["metalTextureLoad"] == 1 && sample.textureLoads.registeredTextures == 1),
            ("Successful APIs record no failures", sample.failures.isEmpty && sample.textureLoads.failures.isEmpty),
        ]
        transaction.commit()
        let warmDiagnostics = SourceBaseAppearanceTimings()
        let warmTransaction = SourceAppearanceLoadTransaction(resources: resources)
        let warm = try SourcePreviewAppearance.load(url: url, resources: resources,
            transaction: warmTransaction, timings: warmDiagnostics)
        let warmSample = warmDiagnostics.sample
        checks.append(("Warm load uses the published identity", warm.materials["part0/0"]?.first?.base == handle && warm.materials["part1/0"]?.first?.base == handle))
        checks.append(("Warm reads remain distinct from shared hits", warmSample.encodedTextureBytesRead == fixture.png.count * 2 && warmSample.textureLoads.dataCacheHits == 2 && warmSample.transactionReuses == 0))
        checks.append(("Shared hits skip image creation and registration", warmSample.textureLoads.calls["imageCreation"] == nil && warmSample.textureLoads.calls["metalTextureLoad"] == nil && warmSample.textureLoads.registeredTextures == 0))
        warmTransaction.commit()
        let ordinary = try SourcePreviewAppearance.load(url: url, resources: resources)
        checks.append(("Default caller preserves material and cache identity", ordinary.materials["part0/0"]?.first?.base == handle && ordinary.materials["part1/0"]?.first?.uniforms.baseColor == appearance.materials["part1/0"]?.first?.uniforms.baseColor && resources.lookup(key: fixture.key("candidate.png")) == handle))
        return checks
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourcePreviewAppearanceTextureDiagnosticsWarmHitBypassesInvalidImageBytes() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    try await appearanceLoadChecks {
        let fixture = try AppearanceLoadFixture(); defer { fixture.remove() }
        let key = "diagnostic-warm-" + UUID().uuidString
        let original = try resources.texture(data: fixture.png, key: key)
        let invalid = Data("not an image".utf8)
        let diagnostics = ResourceTextureLoadTimings()
        var creations: [TextureHandle] = []
        let warm = try resources.texture(data: invalid, key: key, timings: diagnostics, didCreate: { creations.append($0) })
        let ordinary = try resources.texture(data: invalid, key: key)
        let sample = diagnostics.sample
        return [
            ("Invalid bytes do not invalidate a warm shared texture", warm == original && ordinary == original && resources.texture(original) != nil),
            ("Warm load reports a data-cache hit only", sample.dataCacheHits == 1 && sample.dataCacheMisses == 0 && sample.calls == ["dataCacheLookup": 1]),
            ("Presented encoded bytes do not claim a file read or decode", sample.dataRequests == 1 && sample.encodedBytesPresented == invalid.count),
            ("Shared hit never reports actual creation", creations.isEmpty && sample.registeredTextures == 0 && sample.failures.isEmpty),
        ]
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourcePreviewAppearanceLoadDiagnosticsRetainFailuresAndRollBackOnlyPrivateTextures() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    try await appearanceLoadChecks {
        let fixture = try AppearanceLoadFixture(); defer { fixture.remove() }
        let original = try SourcePreviewAppearance.load(url: fixture.document("shared", textures: ["shared.png"]), resources: resources)
        let shared = try appearanceValue(original.materials["part0/0"]?.first?.base, "Shared texture is absent")
        let baseline = resources.statistics().textures
        let corrupt = Data("not an image".utf8)
        try corrupt.write(to: fixture.directory.appendingPathComponent("corrupt.png"))
        let url = try fixture.document("corrupt", textures: ["shared.png", "candidate.png", "corrupt.png"])
        let diagnostics = SourceBaseAppearanceTimings()
        var rejected = false
        do {
            let transaction = SourceAppearanceLoadTransaction(resources: resources)
            _ = try SourcePreviewAppearance.load(url: url, resources: resources, transaction: transaction, timings: diagnostics)
        } catch { rejected = true }
        let sample = diagnostics.sample
        var checks: [(String, Bool)] = [
            ("Corrupt image rejects the entire load", rejected && sample.loadAttempts == 1 && sample.loadFailures == 1),
            ("Successful reads precede the image-creation failure", sample.calls["textureFileRead"] == 3 && sample.encodedTextureBytesRead == fixture.png.count * 2 + corrupt.count && sample.failures.isEmpty),
            ("Failed image API is counted even though it throws", sample.textureLoads.calls["imageCreation"] == 2 && sample.textureLoads.failures["imageCreation"] == 1),
            ("Corrupt image never reaches the texture upload or registration", sample.textureLoads.calls["metalTextureLoad"] == 1 && sample.textureLoads.registeredTextures == 1),
            ("Partial private allocation is rolled back", resources.statistics().textures == baseline && resources.lookup(key: fixture.key("candidate.png")) == nil),
            ("Prior shared appearance and cache survive", resources.texture(shared) != nil && resources.lookup(key: fixture.key("shared.png")) == shared),
        ]
        let missing = SourceBaseAppearanceTimings()
        rejected = false
        do {
            _ = try SourcePreviewAppearance.load(url: fixture.document("missing", textures: ["absent.png"]), resources: resources, timings: missing)
        } catch { rejected = true }
        checks.append(("File-read failure is retained without successful bytes", rejected && missing.sample.loadFailures == 1 && missing.sample.calls["textureFileRead"] == 1 && missing.sample.failures["textureFileRead"] == 1 && missing.sample.encodedTextureBytesRead == 0))
        checks.append(("File-read failure never reaches the texture loader", missing.sample.textureLoads.dataRequests == 0 && missing.sample.textureLoads.registeredTextures == 0))
        return checks
    }
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
