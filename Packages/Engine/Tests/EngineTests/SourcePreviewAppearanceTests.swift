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
