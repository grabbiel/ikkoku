import Testing
import Foundation
import Metal
import Assets
import Character
import Renderer
import Studio

// R5 package-root containment: `GLBLoader.load(url:packageRoot:)`, the explicit
// `loadTrustedFile(url:)` entry point, and the `AssetLibrary` consumers.

private let packageTriangle: Data = {
    var data = Data()
    for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0] {
        var bits = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
}()

private let packagePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aA20AAAAASUVORK5CYII=")!

/// A one-triangle glTF whose positions come from the external buffer `bufferURI`;
/// `imageURI`, when set, adds one external image.
private func triangleGLTF(bufferURI: String, imageURI: String? = nil) throws -> Data {
    var root: [String: Any] = [
        "asset": ["version": "2.0"],
        "buffers": [["byteLength": 36, "uri": bufferURI]],
        "bufferViews": [["buffer": 0, "byteLength": 36]],
        "accessors": [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"]],
        "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]],
        "nodes": [["mesh": 0]],
        "scenes": [["nodes": [0]]], "scene": 0,
    ]
    if let imageURI { root["images"] = [["uri": imageURI, "mimeType": "image/png"]] }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

/// `<temp>/package` (the root: `tri.bin`, `textures/a b.png`, and `asset.gltf` once
/// written) beside `<temp>/outside` (`secret.bin`, `secret.png`). The outside files are
/// valid payloads, so a rejection is the containment check, not a decode failure.
private struct PackageFixture {
    let base: URL, root: URL, outside: URL
    var asset: URL { root.appendingPathComponent("asset.gltf") }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ikkoku-package-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("package", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        self.base = base
        self.root = root
        self.outside = outside
        try fm.createDirectory(at: root.appendingPathComponent("textures", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try packageTriangle.write(to: root.appendingPathComponent("tri.bin"))
        try packagePNG.write(to: root.appendingPathComponent("textures/a b.png"))
        try packageTriangle.write(to: outside.appendingPathComponent("secret.bin"))
        try packagePNG.write(to: outside.appendingPathComponent("secret.png"))
    }

    func write(bufferURI: String, imageURI: String? = nil) throws {
        try triangleGLTF(bufferURI: bufferURI, imageURI: imageURI).write(to: asset)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

@Test func packagedGLTFLoadsContainedBuffersImagesDataURIsAndInternalSymlinks() throws {
    let fixture = try PackageFixture()
    defer { fixture.remove() }
    let fm = FileManager.default
    // A file symlink and a directory symlink whose targets stay inside the root.
    try fm.createSymbolicLink(at: fixture.root.appendingPathComponent("alias.bin"),
                              withDestinationURL: fixture.root.appendingPathComponent("tri.bin"))
    try fm.createSymbolicLink(at: fixture.root.appendingPathComponent("images"),
                              withDestinationURL: fixture.root.appendingPathComponent("textures"))
    let dataURI = "data:application/octet-stream;base64," + packageTriangle.base64EncodedString()
    let allowed: [(buffer: String, image: String)] = [
        ("tri.bin", "textures/a%20b.png"), ("alias.bin", "images/a%20b.png"), (dataURI, "textures/a b.png"),
    ]
    for (buffer, image) in allowed {
        try fixture.write(bufferURI: buffer, imageURI: image)
        let asset = try GLBLoader.load(url: fixture.asset, packageRoot: fixture.root)
        #expect(asset.meshes.first?.primitives.first?.vertexCount == 3, "\(buffer)")
        #expect(asset.images.first?.data == packagePNG, "\(image)")
        #expect(asset.url == fixture.asset)
    }
    // An asset in a subdirectory resolves its URIs beside itself, inside the given root.
    let items = fixture.root.appendingPathComponent("items", isDirectory: true)
    try fm.createDirectory(at: items, withIntermediateDirectories: true)
    try packageTriangle.write(to: items.appendingPathComponent("chair.bin"))
    try triangleGLTF(bufferURI: "chair.bin").write(to: items.appendingPathComponent("chair.gltf"))
    let nested = try GLBLoader.load(url: items.appendingPathComponent("chair.gltf"), packageRoot: fixture.root)
    #expect(nested.meshes.first?.primitives.first?.vertexCount == 3)
}

@Test func packagedGLTFRejectsEveryEscapingReference() throws {
    let fixture = try PackageFixture()
    defer { fixture.remove() }
    let fm = FileManager.default
    let secret = fixture.outside.appendingPathComponent("secret.bin")
    try fm.createSymbolicLink(at: fixture.root.appendingPathComponent("link.bin"), withDestinationURL: secret)
    try fm.createSymbolicLink(at: fixture.root.appendingPathComponent("linked"), withDestinationURL: fixture.outside)
    let encodedAbsolute = "%2F" + String(secret.path.dropFirst())
    let escaping: [String] = [
        "../outside/secret.bin",                    // relative traversal
        "textures/../../outside/secret.bin",        // traversal through a real directory
        secret.path,                                // absolute path
        encodedAbsolute,                            // percent-encoded absolute path
        secret.absoluteString,                      // file: URL
        "file:secret.bin",                          // file: scheme with a relative path
        "%2E%2E/outside/secret.bin",                // percent-encoded dot segment
        "..%2Foutside%2Fsecret.bin",                // percent-encoded separators
        "..\\outside\\secret.bin",                  // backslash separators
        "./tri.bin", "textures//a b.png", "",       // noncanonical relative paths
        "%zz.bin",                                  // invalid percent-encoding
        "link.bin",                                 // file symlink resolving outside
        "linked/secret.bin",                        // directory symlink resolving outside
    ]
    for uri in escaping {
        // The same reference is rejected as a buffer and as an image (with a valid buffer).
        let cases: [(buffer: String, image: String?)] = [(uri, nil), ("tri.bin", uri)]
        for (buffer, image) in cases {
            try fixture.write(bufferURI: buffer, imageURI: image)
            do {
                _ = try GLBLoader.load(url: fixture.asset, packageRoot: fixture.root)
                Issue.record("Package load accepted the escaping reference \(uri)")
            } catch GLTFError.escapesPackageRoot(let rejected, _) {
                #expect(rejected == uri)
            }
        }
    }
    // The asset file itself must resolve inside the root, directly or through a symlink.
    let outsideAsset = fixture.outside.appendingPathComponent("asset.gltf")
    try triangleGLTF(bufferURI: "secret.bin").write(to: outsideAsset)
    try fm.createSymbolicLink(at: fixture.root.appendingPathComponent("outside.gltf"), withDestinationURL: outsideAsset)
    for url in [outsideAsset, fixture.root.appendingPathComponent("outside.gltf"),
                fixture.root.appendingPathComponent("../outside/asset.gltf")] {
        do {
            _ = try GLBLoader.load(url: url, packageRoot: fixture.root)
            Issue.record("Package load accepted the asset \(url.path)")
        } catch GLTFError.escapesPackageRoot(let rejected, _) {
            #expect(rejected == url.path)
        }
    }
    // The explicit trusted-file entry point keeps the unconfined behavior; in-memory
    // data with no external access still refuses every external URI.
    try fixture.write(bufferURI: "../outside/secret.bin")
    let trusted = try GLBLoader.loadTrustedFile(url: fixture.asset)
    #expect(trusted.meshes.first?.primitives.first?.vertexCount == 3)
    #expect(throws: GLTFError.self) { try GLBLoader.load(data: Data(contentsOf: fixture.asset)) }
}

@Test func assetLibraryConfinesCatalogAndItemAssetsAndNamesTrustedImports() throws {
    let fixture = try PackageFixture()
    defer { fixture.remove() }
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let library = AssetLibrary(resources: resources, root: fixture.root)
    try fixture.write(bufferURI: "tri.bin")
    #expect(library.asset("asset.gltf")?.parts.count == 1)
    // A catalog-relative entry whose buffer leaves the asset root fails and is logged.
    let escaping = fixture.root.appendingPathComponent("escaping.gltf")
    try triangleGLTF(bufferURI: "../outside/secret.bin").write(to: escaping)
    let escapingLoaded = library.asset("escaping.gltf") != nil
    #expect(!escapingLoaded)
    #expect(library.log.contains { $0.hasPrefix("Failed escaping.gltf") && $0.contains("outside its package") })
    // A converted Studio item's package is the directory that holds it.
    let itemRoot = KoikatsuAssetResolver.packageRoot(of: escaping)
    #expect(itemRoot.path == fixture.root.path)
    #expect(throws: GLTFError.self) { try library.importStaticAsset(url: escaping, packageRoot: itemRoot) }
    #expect(try library.importStaticAsset(url: fixture.asset, packageRoot: itemRoot).parts.count == 1)
    // A model the user chose explicitly is the separately named trusted import.
    #expect(try library.importTrustedStaticAsset(url: escaping).parts.count == 1)
}
