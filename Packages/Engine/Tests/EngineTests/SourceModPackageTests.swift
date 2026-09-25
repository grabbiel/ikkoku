import Foundation
import Testing
import CryptoKit
import CoreGraphics
import ImageIO
import Assets

private let modTestBundle = "abdata/chara/mod/test.unity3d"

private func modTestHash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private func modTestPNG(_ rgba: [UInt8]) throws -> Data {
    let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
    let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return bytes as Data
}

private func modTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SourceModTests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct ModPackageFixture {
    let directory: URL
    var manifest: [String: Any]
    var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    init(directory: URL, guid: String, version: String = "1.0") throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manifest = ["schemaVersion": 1, "kind": "ikkoku-mod-package",
            "converter": ["id": "ikkoku.zipmod", "version": "1.0.0"],
            "source": ["guid": guid, "version": version, "name": "Synthetic test package",
                "archiveSHA256": modTestHash(Data(guid.utf8)), "games": ["Koikatsu"]],
            "resources": [] as [[String: Any]], "catalogs": [] as [[String: Any]],
            "diagnostics": [["code": "fixture", "severity": "info", "message": "Synthetic data only"]]]
    }

    @discardableResult
    mutating func addTexture(_ id: String, asset: String, rgba: [UInt8]) throws -> Data {
        let bytes = try modTestPNG(rgba)
        let path = "textures/\(id).png"
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        var resources = try #require(manifest["resources"] as? [[String: Any]])
        resources.append(["id": id, "kind": "texture2D", "bundlePath": modTestBundle, "assetName": asset,
            "sourcePathID": 100 + resources.count, "sourceSHA256": modTestHash(Data(("source:" + id).utf8)),
            "path": path, "sha256": modTestHash(bytes), "status": "converted", "width": 1, "height": 1])
        manifest["resources"] = resources
        return bytes
    }

    mutating func editResource(_ index: Int = 0, _ edit: (inout [String: Any]) -> Void) throws {
        var resources = try #require(manifest["resources"] as? [[String: Any]])
        edit(&resources[index]); manifest["resources"] = resources
    }

    @discardableResult
    func write() throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL)
        return data
    }

    func load() throws -> SourceModPackage {
        try write()
        return try SourceModPackage.load(url: manifestURL)
    }
}

@Test func sourceModPackageRetainsUnknownManifestAndPreservedCatalogMetadata() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModPackageFixture(directory: directory, guid: "test.retention")
    let png = try fixture.addTexture("face", asset: "face_texture", rgba: [255, 64, 0, 255])
    fixture.manifest["futureSchemaMetadata"] = ["migration": ["from": 17, "preserve": true], "opaque": ["a", "b"]] as [String: Any]
    let catalogData = Data("category=fixture\nid\tname\n42\tFixture\n".utf8)
    try catalogData.write(to: directory.appendingPathComponent("catalog.txt"))
    fixture.manifest["catalogs"] = [["sourcePath": "list/chara/fixture.csv", "path": "catalog.txt",
        "sha256": modTestHash(catalogData), "status": "preserved", "encoding": "utf-8",
        "preamble": ["category=fixture"], "columns": ["id", "name"], "rows": [["42", "Fixture"]]]]
    let expectedBytes = try fixture.write()
    let package = try SourceModPackage.load(url: fixture.manifestURL)
    #expect(package.manifestData == expectedBytes)
    let retained = try #require(try JSONSerialization.jsonObject(with: package.manifestData) as? [String: Any])
    #expect(retained["futureSchemaMetadata"] as? NSDictionary == fixture.manifest["futureSchemaMetadata"] as? NSDictionary)
    #expect(package.catalogs.first?.columns == ["id", "name"])
    #expect(package.catalogs.first?.rows == [["42", "Fixture"]])
    #expect(package.catalogs.first?.preamble == ["category=fixture"])
    #expect(package.diagnostics.first?.code == "fixture")
    let library = try SourceModLibrary(packages: [package])
    let resolved = try #require(try library.texture(bundlePath: modTestBundle, assetName: "face_texture"))
    #expect(resolved.data == png && resolved.modGUID == "test.retention")
    let imageSource = try #require(CGImageSourceCreateWithData(resolved.data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    #expect(image.width == 1 && image.height == 1)
}

@Test func sourceModLibraryMountOrderResolvesIndividualAssetsWithinSharedBundles() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var first = try ModPackageFixture(directory: directory.appendingPathComponent("first"), guid: "test.first")
    let firstShared = try first.addTexture("shared-a", asset: "shared", rgba: [255, 0, 0, 255])
    let onlyFirst = try first.addTexture("first", asset: "only_first", rgba: [0, 255, 0, 255])
    var second = try ModPackageFixture(directory: directory.appendingPathComponent("second"), guid: "test.second")
    let secondShared = try second.addTexture("shared-b", asset: "shared", rgba: [0, 0, 255, 255])
    let onlySecond = try second.addTexture("second", asset: "only_second", rgba: [255, 255, 0, 255])
    let a = try first.load(), b = try second.load()
    let forward = try SourceModLibrary(packages: [a, b]), reverse = try SourceModLibrary(packages: [b, a])
    #expect(try forward.texture(bundlePath: modTestBundle, assetName: "shared")?.data == firstShared)
    #expect(try reverse.texture(bundlePath: modTestBundle, assetName: "shared")?.data == secondShared)
    for library in [forward, reverse] {
        #expect(try library.texture(bundlePath: modTestBundle, assetName: "only_first")?.data == onlyFirst)
        #expect(try library.texture(bundlePath: modTestBundle, assetName: "only_second")?.data == onlySecond)
        #expect(try library.texture(bundlePath: modTestBundle, assetName: "missing") == nil)
        #expect(try library.texture(bundlePath: modTestBundle.uppercased(), assetName: "shared") == nil)
        #expect(try library.texture(bundlePath: modTestBundle, assetName: "SHARED") == nil)
    }
    let firstIdentity = try #require(try forward.texture(bundlePath: modTestBundle, assetName: "shared"))
    let secondIdentity = try #require(try reverse.texture(bundlePath: modTestBundle, assetName: "shared"))
    #expect(firstIdentity.cacheKey != secondIdentity.cacheKey)
    #expect(firstIdentity.modGUID == "test.first" && secondIdentity.modGUID == "test.second")
}

@Test func sourceModLibraryUsesRecordedSourceBundleOrderAndAssetLevelPackageFallthrough() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let sourceKey = "chara/mod/test.unity3d"
    let firstPath = "a-prefix/" + sourceKey, registeredFirstPath = "z-prefix/" + sourceKey
    var first = try ModPackageFixture(directory: directory.appendingPathComponent("first"), guid: "source.first")
    for (id, asset) in [("a-shared", "shared"), ("b-only-a", "only_a"), ("z-shared", "shared")] {
        try first.addTexture(id, asset: asset, rgba: [255, 0, 0, 255])
    }
    try first.editResource(0) { $0["bundlePath"] = firstPath }
    try first.editResource(1) { $0["bundlePath"] = firstPath }
    try first.editResource(2) { $0["bundlePath"] = registeredFirstPath }
    first.manifest["converter"] = ["id": "ikkoku.zipmod", "version": "1.1.0"]
    // Resource IDs and paths sort a before z, but original registration order is z before a.
    first.manifest["bundleRegistrationOrder"] = [registeredFirstPath, firstPath]
    let a = try first.load()
    #expect(a.bundleRegistrationOrder == [registeredFirstPath, firstPath])
    var second = try ModPackageFixture(directory: directory.appendingPathComponent("second"), guid: "source.second")
    try second.addTexture("second-shared", asset: "shared", rgba: [0, 0, 255, 255])
    try second.addTexture("second-only", asset: "only_second", rgba: [0, 0, 255, 255])
    let secondPath = "another-root/" + sourceKey
    for index in 0..<2 { try second.editResource(index) { $0["bundlePath"] = secondPath } }
    second.manifest["converter"] = ["id": "ikkoku.zipmod", "version": "1.1.0"]
    second.manifest["bundleRegistrationOrder"] = [secondPath]
    let b = try second.load()
    let forward = try SourceModLibrary(packages: [a, b]), reverse = try SourceModLibrary(packages: [b, a])
    let winner = try #require(try forward.sourceTextureProvider(bundlePath: sourceKey, assetName: "shared"))
    #expect(winner.modGUID == "source.first" && winner.resource.id == "z-shared")
    #expect(try forward.sourceTextureProvider(bundlePath: sourceKey, assetName: "only_a")?.resource.id == "b-only-a")
    #expect(try forward.sourceTextureProvider(bundlePath: sourceKey, assetName: "only_second")?.modGUID == "source.second")
    #expect(try reverse.sourceTextureProvider(bundlePath: sourceKey, assetName: "shared")?.modGUID == "source.second")
    #expect(try reverse.sourceTextureProvider(bundlePath: sourceKey, assetName: "only_a")?.modGUID == "source.first")
    #expect(try forward.sourceTextureProvider(bundlePath: sourceKey, assetName: "missing") == nil)
    #expect(forward.textureProvider(bundlePath: firstPath, assetName: "shared")?.resource.id == "a-shared")
}

@Test func sourceModLibraryLegacySourceAliasesResolveUniquelyAndRejectAmbiguousWinners() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModPackageFixture(directory: directory, guid: "source.legacy")
    try fixture.addTexture("one", asset: "paint", rgba: [255, 0, 0, 255])
    try fixture.editResource { $0["bundlePath"] = "other/chara/paint.unity3d" }
    let unique = try SourceModLibrary(packages: [fixture.load()])
    #expect(try unique.sourceTextureProvider(bundlePath: "chara/paint.unity3d", assetName: "paint")?.resource.id == "one")
    try fixture.addTexture("two", asset: "paint", rgba: [0, 0, 255, 255])
    try fixture.editResource(1) { $0["bundlePath"] = "abdata/chara/paint.unity3d" }
    let ambiguous = try SourceModLibrary(packages: [fixture.load()])
    #expect(throws: SourceModError.self) { try ambiguous.sourceTextureProvider(bundlePath: "chara/paint.unity3d", assetName: "paint") }
    #expect(ambiguous.textureProvider(bundlePath: "other/chara/paint.unity3d", assetName: "paint")?.resource.id == "one")
    #expect(ambiguous.textureProvider(bundlePath: "abdata/chara/paint.unity3d", assetName: "paint")?.resource.id == "two")
    // No slash means there is no archive directory component to remove.
    try fixture.editResource(1) { $0["bundlePath"] = "single.unity3d" }
    let single = try SourceModLibrary(packages: [fixture.load()])
    #expect(try single.sourceTextureProvider(bundlePath: "single.unity3d", assetName: "paint")?.resource.id == "two")
}

@Test func sourceModPackageConverter11RequiresCompleteUnambiguousBundleRegistrationMetadata() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModPackageFixture(directory: directory, guid: "source.metadata")
    try fixture.addTexture("one", asset: "paint", rgba: [255, 0, 0, 255])
    fixture.manifest["converter"] = ["id": "ikkoku.zipmod", "version": "1.1.0"]
    #expect(throws: SourceModError.self) { try fixture.load() }
    let invalidOrders: [[String]] = [[], [modTestBundle, modTestBundle], ["../escape.unity3d"], ["notes.txt"], ["other/unrelated.unity3d"]]
    for value in invalidOrders {
        fixture.manifest["bundleRegistrationOrder"] = value
        #expect(throws: SourceModError.self) { try fixture.load() }
    }
    fixture.manifest["bundleRegistrationOrder"] = "not an array"
    #expect(throws: DecodingError.self) { try fixture.load() }
    fixture.manifest["bundleRegistrationOrder"] = [modTestBundle]
    #expect(try fixture.load().bundleRegistrationOrder == [modTestBundle])
    fixture.manifest["resources"] = [] as [[String: Any]]
    fixture.manifest.removeValue(forKey: "bundleRegistrationOrder")
    #expect(throws: SourceModError.self) { try fixture.load() }
    fixture.manifest["bundleRegistrationOrder"] = [] as [String]
    #expect(try fixture.load().resources.isEmpty == true)
}

@Test func sourceModPackageAllowsDistinctAssetIdentitiesToShareOneContentAddressedPNG() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModPackageFixture(directory: directory, guid: "test.shared-content")
    let png = try fixture.addTexture("a", asset: "shared_name", rgba: [128, 64, 32, 255])
    try fixture.addTexture("b", asset: "shared_name", rgba: [128, 64, 32, 255])
    try fixture.addTexture("c", asset: "other_name", rgba: [128, 64, 32, 255])
    let digest = modTestHash(png), path = "textures/\(modTestHash(png)).png"
    try png.write(to: directory.appendingPathComponent(path))
    for (index, id) in ["a", "b", "c"].enumerated() {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("textures/\(id).png"))
        try fixture.editResource(index) { $0["path"] = path; $0["sha256"] = digest }
    }
    let otherBundle = "abdata/chara/mod/other.unity3d"
    try fixture.editResource(1) { $0["bundlePath"] = otherBundle }
    let package = try fixture.load(), library = try SourceModLibrary(packages: [package])
    #expect(package.resources.count == 3)
    #expect(Set(package.resources.map(\.path)) == [path])
    var keys = Set<String>()
    for (bundle, name) in [(modTestBundle, "shared_name"), (otherBundle, "shared_name"), (modTestBundle, "other_name")] {
        let resolved = try #require(try library.texture(bundlePath: bundle, assetName: name))
        #expect(resolved.data == png && resolved.resource.path == path)
        #expect(keys.insert(resolved.cacheKey).inserted)
    }
    // Sharing storage does not permit different manifests of the same file's bytes.
    try fixture.editResource(2) { $0["sha256"] = modTestHash(Data("different bytes".utf8)) }
    #expect(throws: SourceModError.self) { try fixture.load() }
}

@Test func sourceModPackagePreservesUnsupportedRawCatalogWithoutInventingParsedFields() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModPackageFixture(directory: directory, guid: "test.raw-catalog")
    let raw = Data([0xff, 0xfe, 0x00, 0x81, 0x5c, 0x09, 0x80, 0x00])
    let path = "raw-catalog.bin"
    try raw.write(to: directory.appendingPathComponent(path))
    fixture.manifest["catalogs"] = [["sourcePath": "abdata/list/unknown.csv", "path": path,
        "sha256": modTestHash(raw), "status": "preserved", "parseStatus": "unsupported"]]
    let manifestBytes = try fixture.write()
    let package = try SourceModPackage.load(url: fixture.manifestURL)
    let catalog = try #require(package.catalogs.first)
    #expect(catalog.parseStatus == "unsupported")
    #expect(catalog.encoding == nil && catalog.preamble == nil && catalog.columns == nil && catalog.rows == nil)
    #expect(package.manifestData == manifestBytes)
    #expect(try Data(contentsOf: package.directory.appendingPathComponent(catalog.path)) == raw)
    #expect(package.resources.isEmpty)
    let library = try SourceModLibrary(packages: [package])
    #expect(try library.texture(bundlePath: modTestBundle, assetName: "unknown") == nil)
    try (raw + Data([0])).write(to: directory.appendingPathComponent(path))
    #expect(throws: SourceModError.self) { try SourceModPackage.load(url: fixture.manifestURL) }
}

@Test func sourceModPackageRejectsAmbiguousResourceIdentitiesAndDuplicateMountedGUIDs() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModPackageFixture(directory: directory.appendingPathComponent("one"), guid: "test.duplicate")
    try fixture.addTexture("a", asset: "same_asset", rgba: [255, 0, 0, 255])
    let valid = try fixture.load()
    try fixture.addTexture("b", asset: "same_asset", rgba: [0, 0, 255, 255])
    // IDs and output paths differ; this fails specifically on bundle + asset ambiguity.
    #expect(throws: SourceModError.self) { try fixture.load() }
    try fixture.editResource(1) { $0["assetName"] = "different_asset"; $0["id"] = "a" }
    #expect(throws: SourceModError.self) { try fixture.load() }
    var otherVersion = try ModPackageFixture(directory: directory.appendingPathComponent("two"), guid: "test.duplicate", version: "2.0")
    try otherVersion.addTexture("v2", asset: "new_asset", rgba: [0, 255, 0, 255])
    let second = try otherVersion.load()
    #expect(throws: SourceModError.self) { try SourceModLibrary(packages: [valid, second]) }
}

@Test func sourceModLibraryRechecksChangedCacheAndUsesNewContentIdentityAfterReload() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModPackageFixture(directory: directory, guid: "test.integrity")
    try fixture.addTexture("face", asset: "face_texture", rgba: [255, 0, 0, 255])
    let package = try fixture.load(), library = try SourceModLibrary(packages: [package])
    let original = try #require(try library.texture(bundlePath: modTestBundle, assetName: "face_texture"))
    let replacement = try modTestPNG([0, 0, 255, 255])
    try replacement.write(to: directory.appendingPathComponent("textures/face.png"))
    #expect(throws: SourceModError.self) { try package.textureData(package.resources[0]) }
    #expect(throws: SourceModError.self) { try library.texture(bundlePath: modTestBundle, assetName: "face_texture") }
    #expect(throws: SourceModError.self) { try SourceModPackage.load(url: fixture.manifestURL) }
    try fixture.editResource { $0["sha256"] = modTestHash(replacement) }
    let refreshed = try SourceModLibrary(packages: [fixture.load()])
    let updated = try #require(try refreshed.texture(bundlePath: modTestBundle, assetName: "face_texture"))
    #expect(updated.data == replacement && updated.cacheKey != original.cacheKey)
    // Reloading one package does not silently refresh already-mounted package identities.
    #expect(throws: SourceModError.self) { try library.texture(bundlePath: modTestBundle, assetName: "face_texture") }
}

@Test func sourceModPackageRejectsUnsafeRelativePaths() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModPackageFixture(directory: directory, guid: "test.paths")
    try fixture.addTexture("face", asset: "face_texture", rgba: [255, 0, 0, 255])
    let original = fixture
    let invalid = ["", "../outside.png", "/outside.png", "./face.png", "textures/../face.png", "textures//face.png",
        "textures/", "C:/outside.png", "textures\\face.png", "textures/face\0.png"]
    for field in ["path", "bundlePath"] {
        for value in invalid {
            fixture = original
            try fixture.editResource { $0[field] = value }
            #expect(throws: SourceModError.self) { try fixture.load() }
        }
    }
}

@Test func sourceModPackageRejectsSymlinkEscapesAtMountAndAfterMount() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let packageDirectory = directory.appendingPathComponent("package")
    var fixture = try ModPackageFixture(directory: packageDirectory, guid: "test.symlink")
    let png = try fixture.addTexture("face", asset: "face_texture", rgba: [255, 0, 0, 255])
    let package = try fixture.load(), library = try SourceModLibrary(packages: [package])
    // Identical bytes outside the package prove the containment check is independent of hashing.
    let outside = directory.appendingPathComponent("outside.png")
    try png.write(to: outside)
    let texture = packageDirectory.appendingPathComponent("textures/face.png")
    try FileManager.default.removeItem(at: texture)
    try FileManager.default.createSymbolicLink(atPath: texture.path, withDestinationPath: outside.path)
    #expect(throws: SourceModError.self) { try SourceModPackage.load(url: fixture.manifestURL) }
    #expect(throws: SourceModError.self) { try library.texture(bundlePath: modTestBundle, assetName: "face_texture") }
    try FileManager.default.removeItem(at: texture)
    let outsideDirectory = directory.appendingPathComponent("outside-dir")
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    try png.write(to: outsideDirectory.appendingPathComponent("face.png"))
    let textures = packageDirectory.appendingPathComponent("textures")
    try FileManager.default.removeItem(at: textures)
    try FileManager.default.createSymbolicLink(atPath: textures.path, withDestinationPath: outsideDirectory.path)
    #expect(throws: SourceModError.self) { try SourceModPackage.load(url: fixture.manifestURL) }
}

@Test func sourceModPackageRejectsDimensionMismatchAndTruncatedPNGWithMatchingHash() throws {
    let directory = try modTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModPackageFixture(directory: directory, guid: "test.png")
    let png = try fixture.addTexture("face", asset: "face_texture", rgba: [255, 0, 0, 255])
    try fixture.editResource { $0["width"] = 2 }
    #expect(throws: SourceModError.self) { try fixture.load() }
    // Signature, IHDR marker and 1x1 dimensions survive, while image data/CRC/end are missing.
    let truncated = Data(png.prefix(24))
    try truncated.write(to: directory.appendingPathComponent("textures/face.png"))
    try fixture.editResource { $0["width"] = 1; $0["sha256"] = modTestHash(truncated) }
    #expect(throws: SourceModError.self) { try fixture.load() }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["IKKOKU_MOD_PACKAGE"] != nil))
func sourceModPackageLoadsNativeImportedPackageFromEnvironment() throws {
    let path = try #require(ProcessInfo.processInfo.environment["IKKOKU_MOD_PACKAGE"])
    var isDirectory: ObjCBool = false
    try #require(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
    let input = URL(fileURLWithPath: path)
    let manifest = isDirectory.boolValue ? input.appendingPathComponent("manifest.json") : input
    let package = try SourceModPackage.load(url: manifest)
    try #require(!package.resources.isEmpty, "Integration package must contain a converted texture.")
    let library = try SourceModLibrary(packages: [package])
    var keys = Set<String>()
    for resource in package.resources {
        let resolved = try #require(try library.texture(bundlePath: resource.bundlePath, assetName: resource.assetName))
        #expect(resolved.data == (try package.textureData(resource)))
        #expect(resolved.modGUID == package.source.guid && resolved.archiveSHA256 == package.source.archiveSHA256)
        #expect(keys.insert(resolved.cacheKey).inserted)
        let source = try #require(CGImageSourceCreateWithData(resolved.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == resource.width && image.height == resource.height)
    }
}
