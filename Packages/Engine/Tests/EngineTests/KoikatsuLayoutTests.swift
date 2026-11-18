import Testing
import Foundation
import simd
import CoreMath
import Assets
@testable import Studio

private func layoutRecord(kind: KoikatsuObjectKind = .item, children: [KoikatsuObjectRecord] = [], key: Int32 = 1) -> KoikatsuObjectRecord {
    let pattern = KoikatsuPatternRecord(key: -1, filePath: "", clamp: false, uv: SIMD4(0, 0, 1, 1), rotation: 0)
    let item = KoikatsuItemRecord(group: 2, category: 13, no: 73, animationSpeed: 1,
        colors: [], patterns: [], alpha: 1, lineColor: SIMD4(0, 0, 0, 1), lineWidth: 1,
        emissionColor: .zero, emissionPower: 0, lightCancel: 0, panel: pattern,
        enableFK: false, bones: [:], enableDynamicBone: false, animationNormalizedTime: 0)
    return KoikatsuObjectRecord(kind: kind, rootDictionaryKey: nil, sourceKey: key,
        transform: KoikatsuChangeAmount(position: SIMD3(1, 2, 3), rotationDegrees: SIMD3(89.99, 41, -27), scale: SIMD3(-2, 3, 0.5)),
        treeState: 1, visible: true, name: "Folder", cameraActive: nil,
        item: kind == .item ? item : nil, light: nil, children: children)
}

private var layoutCatalog: KoikatsuAssetCatalog {
    KoikatsuAssetCatalog(version: 1, items: [.init(group: 2, category: 13, no: 73, name: "Chair", file: "chair/chair.gltf")])
}

@Test func KoikatsuLayoutBindsRealCatalogIdentityAndPreservesExactLocalTransforms() throws {
    let source = layoutRecord()
    let folder = layoutRecord(kind: .folder, children: [source], key: 2)
    let snapshot = KoikatsuSceneSnapshot(version: "1.0.4.2", roots: [folder], objectSectionEndOffset: 0)
    let result = try KoikatsuLayoutImporter.convert(snapshot, catalog: layoutCatalog, catalogDirectory: URL(fileURLWithPath: "/local"))
    #expect(result.objects.count == 2)
    let object = result.objects[1]
    #expect(object.sourceObjectKey == 1)
    #expect(object.assetFile == "/local/chair/chair.gltf")
    #expect(object.parent == result.objects[0].id)
    #expect(object.transform.position == SIMD3(1, 2, -3))
    #expect(object.transform.scale == SIMD3(-2, 3, 0.5))
    let e = source.transform.rotationDegrees * (.pi / 180)
    let rawQ = simd_quatf(angle: e.y, axis: SIMD3(0, 1, 0))
        * simd_quatf(angle: e.x, axis: SIMD3(1, 0, 0))
        * simd_quatf(angle: e.z, axis: SIMD3(0, 0, 1))
    let rawMatrix = Transform.trs(source.transform.position, rawQ, source.transform.scale)
    let expected = UnityCoordinates.basis * rawMatrix * UnityCoordinates.basis
    for column in 0..<4 { #expect(simd_length(object.transform.matrix[column] - expected[column]) < 1e-5) }
    let saved = try JSONEncoder().encode(result)
    let loaded = try JSONDecoder().decode(StudioDocument.self, from: saved)
    for column in 0..<4 { #expect(simd_length(loaded.objects[1].transform.matrix[column] - expected[column]) < 1e-5) }
    var edited = object.transform
    edited.rotation.y += 10
    #expect(edited.rotationOverride == nil)
}

@Test func KoikatsuLayoutFailsUnmappedAndUnsupportedObjectsBeforeReturningDocument() {
    let snapshot = KoikatsuSceneSnapshot(version: "1.0.4.2", roots: [layoutRecord()], objectSectionEndOffset: 0)
    let directory = URL(fileURLWithPath: "/local")
    let empty = KoikatsuAssetCatalog(version: 1, items: [])
    #expect(throws: KoikatsuLayoutError.self) { try KoikatsuLayoutImporter.convert(snapshot, catalog: empty, catalogDirectory: directory) }
    var duplicate = layoutCatalog
    duplicate.items.append(duplicate.items[0])
    #expect(throws: KoikatsuLayoutError.self) { try KoikatsuLayoutImporter.convert(snapshot, catalog: duplicate, catalogDirectory: directory) }
    let camera = KoikatsuSceneSnapshot(version: "1.0.4.2", roots: [layoutRecord(kind: .camera)], objectSectionEndOffset: 0)
    #expect(throws: KoikatsuLayoutError.self) { try KoikatsuLayoutImporter.convert(camera, catalog: layoutCatalog, catalogDirectory: directory) }
}

@Test func KoikatsuAssetResolverResolvesAbsoluteAndRelativePaths() throws {
    let catalog = KoikatsuAssetCatalog(version: 1, items: [
        .init(group: 2, category: 13, no: 73, name: "Chair", file: "chair/chair.gltf"),
        .init(group: 0, category: 0, no: 1, name: "Cube", file: "/converted/cube.glb"),
    ])
    let resolver = try KoikatsuAssetResolver(catalog: catalog, directory: URL(fileURLWithPath: "/local"))
    let relative = try resolver.resolve(group: 2, category: 13, no: 73)
    #expect(relative.name == "Chair")
    #expect(relative.url == URL(fileURLWithPath: "/local/chair/chair.gltf"))
    let absolute = try resolver.resolve(group: 0, category: 0, no: 1)
    #expect(absolute.name == "Cube")
    #expect(absolute.url == URL(fileURLWithPath: "/converted/cube.glb"))
}

@Test func KoikatsuAssetResolverRejectsInvalidReferencesAndDuplicates() throws {
    let directory = URL(fileURLWithPath: "/local")
    func resolver(_ file: String) throws -> KoikatsuAssetResolver {
        try KoikatsuAssetResolver(catalog: KoikatsuAssetCatalog(version: 1, items: [
            .init(group: 2, category: 13, no: 73, name: "Chair", file: file)]), directory: directory)
    }
    #expect(throws: KoikatsuLayoutError.self) { try resolver("https://example.invalid/chair.glb").resolve(group: 2, category: 13, no: 73) }
    #expect(throws: KoikatsuLayoutError.self) { try resolver("chair/chair.fbx").resolve(group: 2, category: 13, no: 73) }
    #expect(throws: KoikatsuLayoutError.self) { try resolver("").resolve(group: 2, category: 13, no: 73) }
    var missingError: KoikatsuLayoutError?
    do { try resolver("chair/chair.gltf").resolve(group: 0, category: 1, no: 11) }
    catch let error as KoikatsuLayoutError { missingError = error }
    #expect(missingError?.description.contains("0/1/11") == true)
    #expect(throws: KoikatsuLayoutError.self) { try resolver("chair/chair.gltf").resolve(group: 9, category: 9, no: 9) }
    #expect(throws: KoikatsuLayoutError.self) {
        try KoikatsuAssetResolver(catalog: KoikatsuAssetCatalog(version: 1, items: [
            .init(group: 2, category: 13, no: 73, name: "Chair", file: "a.gltf"),
            .init(group: 2, category: 13, no: 73, name: "Chair again", file: "b.glb")]), directory: directory)
    }
    #expect(throws: KoikatsuLayoutError.self) {
        try KoikatsuAssetResolver(catalog: KoikatsuAssetCatalog(version: 2, items: []), directory: directory)
    }
}

/// ST-T04: a generated catalog (`Tools/reverse/item_catalog.py`) keeps the version 1
/// shape and adds fields the runtime ignores, plus `notConverted`. A hand-written
/// catalog without that list still decodes and lists nothing.
@Test func KoikatsuAssetCatalogDecodesAGeneratedCatalog() throws {
    let generated = #"""
    {"version": 1, "kind": "ikkoku.sourceStudioItemCatalog", "groups": [0],
     "sources": {"infoBundles": [], "assetBundles": []}, "coverage": {"rows": 3, "converted": 1, "notConverted": 2},
     "items": [{"group": 0, "category": 0, "no": 1, "name": "Shape", "file": "shape/shape.gltf"}],
     "notConverted": [{"group": 0, "category": 0, "no": 5, "reason": "Converted triangle faces away from authored normals"},
                      {"group": 0, "category": 2, "no": 7, "reason": "Bundle synthetic/missing.unity3d is not available here"}]}
    """#
    let catalog = try JSONDecoder().decode(KoikatsuAssetCatalog.self, from: Data(generated.utf8))
    #expect(catalog.items.count == 1 && catalog.notConverted?.count == 2)
    #expect(catalog.notConverted?.first?.reason == "Converted triangle faces away from authored normals")
    #expect(try KoikatsuAssetResolver(catalog: catalog, directory: URL(fileURLWithPath: "/local")).listsNotConverted)
    let handWritten = try JSONDecoder().decode(KoikatsuAssetCatalog.self, from: Data(#"""
        {"version": 1, "items": [{"group": 0, "category": 0, "no": 1, "name": "Shape", "file": "/shape.gltf"}]}
        """#.utf8))
    #expect(handWritten.notConverted == nil)
    #expect(try !KoikatsuAssetResolver(catalog: handWritten, directory: URL(fileURLWithPath: "/local")).listsNotConverted)
}

/// An unmapped key is not converted (with the generator's reason) or not in the
/// catalog, by its exact key: 0/0/50 is not 0/0/5. A key may not be both converted
/// and not converted, nor listed twice.
@Test func KoikatsuAssetResolverSplitsUnmappedKeysByExactKey() throws {
    let directory = URL(fileURLWithPath: "/local")
    var catalog = KoikatsuAssetCatalog(version: 1, items: [.init(group: 0, category: 0, no: 1, name: "Shape", file: "shape/shape.gltf")])
    catalog.notConverted = [.init(group: 0, category: 0, no: 5, reason: "Converted triangle faces away from authored normals")]
    let resolver = try KoikatsuAssetResolver(catalog: catalog, directory: directory)
    #expect(try resolver.resolve(group: 0, category: 0, no: 1).url == URL(fileURLWithPath: "/local/shape/shape.gltf"))
    func failure(_ group: Int32, _ category: Int32, _ no: Int32) -> KoikatsuLayoutError? {
        do { _ = try resolver.resolve(group: group, category: category, no: no); return nil }
        catch { return error as? KoikatsuLayoutError }
    }
    guard case .notConverted("0/0/5", let reason)? = failure(0, 0, 5) else {
        Issue.record("0/0/5 should be not converted: \(String(describing: failure(0, 0, 5)))"); return
    }
    #expect(reason == "Converted triangle faces away from authored normals")
    #expect(failure(0, 0, 5)?.description.contains("0/0/5") == true)
    for (group, category, no) in [(Int32(0), Int32(0), Int32(50)), (0, 5, 0), (5, 0, 0)] {
        guard case .missingItem(let key)? = failure(group, category, no) else {
            Issue.record("\(group)/\(category)/\(no) should be not in the catalog"); continue
        }
        #expect(key == "\(group)/\(category)/\(no)")
    }
    var both = catalog
    both.notConverted = [.init(group: 0, category: 0, no: 1, reason: "refused")]
    #expect(throws: KoikatsuLayoutError.self) { try KoikatsuAssetResolver(catalog: both, directory: directory) }
    var twice = catalog
    twice.notConverted = [.init(group: 0, category: 0, no: 5, reason: "a"), .init(group: 0, category: 0, no: 5, reason: "b")]
    #expect(throws: KoikatsuLayoutError.self) { try KoikatsuAssetResolver(catalog: twice, directory: directory) }
}

/// The generator writes each export into its own folder, which is that glTF's
/// package root: it loads its own buffer and image, and a reference to a sibling
/// export's image is refused, so shared images are cloned into each folder.
@Test func GeneratedCatalogExportsAreConfinedToTheirOwnFolders() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("ikkoku-items-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    var triangle = Data()
    for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0] { withUnsafeBytes(of: value.bitPattern.littleEndian) { triangle.append(contentsOf: $0) } }
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aA20AAAAASUVORK5CYII=")!
    func export(_ stem: String, image: String) throws {
        let folder = base.appendingPathComponent(stem, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try triangle.write(to: folder.appendingPathComponent("\(stem).bin"))
        try png.write(to: folder.appendingPathComponent("0_shared.png"))
        let root: [String: Any] = [
            "asset": ["version": "2.0"], "buffers": [["byteLength": 36, "uri": "\(stem).bin"]],
            "bufferViews": [["buffer": 0, "byteLength": 36]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]], "nodes": [["mesh": 0]],
            "scenes": [["nodes": [0]]], "scene": 0, "images": [["uri": image, "mimeType": "image/png"]]]
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: folder.appendingPathComponent("\(stem).gltf"))
    }
    try export("shape_a", image: "0_shared.png")
    try export("shape_b", image: "../shape_a/0_shared.png")
    let resolver = try KoikatsuAssetResolver(catalog: KoikatsuAssetCatalog(version: 1, items: [
        .init(group: 0, category: 0, no: 1, name: "A", file: "shape_a/shape_a.gltf"),
        .init(group: 0, category: 0, no: 2, name: "B", file: "shape_b/shape_b.gltf")]), directory: base)
    let a = try resolver.resolve(group: 0, category: 0, no: 1).url
    #expect(KoikatsuAssetResolver.packageRoot(of: a).standardizedFileURL == base.appendingPathComponent("shape_a").standardizedFileURL)
    _ = try GLBLoader.load(url: a, packageRoot: KoikatsuAssetResolver.packageRoot(of: a))
    let b = try resolver.resolve(group: 0, category: 0, no: 2).url
    do {
        _ = try GLBLoader.load(url: b, packageRoot: KoikatsuAssetResolver.packageRoot(of: b))
        Issue.record("A sibling export's image loaded outside the package root")
    } catch GLTFError.escapesPackageRoot(let rejected, _) {
        #expect(rejected == "../shape_a/0_shared.png")
    }
}
