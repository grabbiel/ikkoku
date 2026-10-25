import Testing
import Foundation
import Metal
import ImageIO
import CoreGraphics
import simd
import Assets
import CoreMath
import Character
import ShaderTypes
import Studio
@testable import Renderer

// ST-A11: the converted map catalog lookup, `MapCtrl.Reflect`'s transform rule
// and the paths that draw no map.

private let catalogJSON = """
{"version": 1, "kind": "ikkoku.sourceStudioMapCatalog", "maps": [
 {"no": 33, "name": "空き部室", "bundlePath": "studio/map/bushitu.unity3d", "scene": "bushitu",
  "file": "33-bushitu/bushitu.gltf", "approximations": ["no baked lightmaps", "shaders approximated (Standard)"]},
 {"no": 34, "name": "空き教室", "bundlePath": "studio/map/akikyoushitu.unity3d", "scene": "akikyoushitu", "file": null}
]}
"""

@Test func mapCatalogResolvesConvertedUnconvertedUnknownAndNoMap() throws {
    let directory = URL(fileURLWithPath: "/tmp/ikkoku-map-catalog", isDirectory: true)
    struct Maps: Decodable { let maps: [SourceStudioMapCatalog.Entry] }
    let entries = try JSONDecoder().decode(Maps.self, from: Data(catalogJSON.utf8)).maps
    let catalog = try SourceStudioMapCatalog(entries: entries, directory: directory)
    guard case .converted(let entry, let file, let root) = catalog.resolve(33) else { Issue.record("33 not converted"); return }
    #expect(entry.name == "空き部室" && entry.scene == "bushitu")
    #expect(file.path == "/tmp/ikkoku-map-catalog/33-bushitu/bushitu.gltf")
    #expect(root.path == "/tmp/ikkoku-map-catalog/33-bushitu")
    guard case .notConverted(let unconverted) = catalog.resolve(34) else { Issue.record("34 resolved"); return }
    #expect(unconverted.bundlePath == "studio/map/akikyoushitu.unity3d")
    // `Map.LoadMap`: -1 and any number without a row show no map; neither is
    // ever replaced by another map.
    #expect(catalog.resolve(-1) == .none)
    #expect(catalog.resolve(57) == .notInCatalog(57))
    #expect(catalog.resolve(Int32.min) == .notInCatalog(Int32.min))

    #expect(SourceStudioMapStatus.line(.none) == nil)
    #expect(SourceStudioMapStatus.line(catalog.resolve(34))
            == "Map 34 空き教室 (akikyoushitu): not converted (studio/map/akikyoushitu.unity3d); no map shown")
    #expect(SourceStudioMapStatus.line(catalog.resolve(57)) == "Map 57: not in the map catalog (mods are not evaluated); no map shown")
    #expect(SourceStudioMapStatus.approximationLabel
            == "approximated: no baked lightmaps, map lights, sun-type lighting, fog or ambient")
}

@Test func mapCatalogLoadsFromDiskAndRejectsUnsafeOrDuplicateRows() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-map-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let url = base.appendingPathComponent("catalog.json")
    try Data(catalogJSON.utf8).write(to: url)
    let catalog = try SourceStudioMapCatalog.load(url: url)
    #expect(catalog.entries.count == 2)
    guard case .converted(_, let file, _) = catalog.resolve(33) else { Issue.record("33 not converted"); return }
    #expect(file == base.appendingPathComponent("33-bushitu/bushitu.gltf").standardizedFileURL)

    try Data(catalogJSON.replacingOccurrences(of: "ikkoku.sourceStudioMapCatalog", with: "other").utf8).write(to: url)
    #expect(throws: (any Error).self) { try SourceStudioMapCatalog.load(url: url) }
    func entry(_ no: Int32, _ file: String?) -> SourceStudioMapCatalog.Entry {
        try! JSONDecoder().decode(SourceStudioMapCatalog.Entry.self, from: JSONSerialization.data(withJSONObject: [
            "no": no, "name": "m", "bundlePath": "b", "scene": "s", "file": file as Any]))
    }
    for unsafe in ["../x.gltf", "/abs/x.gltf", "a/../../x.gltf", "a//x.gltf", "a\\x.gltf", ""] {
        #expect(throws: (any Error).self) { try SourceStudioMapCatalog(entries: [entry(1, unsafe)], directory: base) }
    }
    #expect(throws: (any Error).self) { try SourceStudioMapCatalog(entries: [entry(1, nil), entry(1, nil)], directory: base) }
}

/// Unity's `Quaternion.Euler`: Z, then X, then Y about the parent axes.
private func unityRotation(_ degrees: Float3) -> float3x3 {
    let r = degrees * (.pi / 180)
    let x = float3x3(rows: [Float3(1, 0, 0), Float3(0, cos(r.x), -sin(r.x)), Float3(0, sin(r.x), cos(r.x))])
    let y = float3x3(rows: [Float3(cos(r.y), 0, sin(r.y)), Float3(0, 1, 0), Float3(-sin(r.y), 0, cos(r.y))])
    let z = float3x3(rows: [Float3(cos(r.z), -sin(r.z), 0), Float3(sin(r.z), cos(r.z), 0), Float3(0, 0, 1)])
    return y * x * z
}

@Test func mapTransformIsReflectsPositionAndEulerWithTheSavedScaleIgnored() throws {
    let position = Float3(1.25, -0.5, 3), rotation = Float3(10, 200, -35)
    let matrix = try SourceStudioMapPlacement.mapRootMatrix(
        KoikatsuChangeAmount(position: position, rotationDegrees: rotation, scale: Float3(7, 0.5, -2)))
    // The same transform with scale 1: `Reflect` never writes the scale.
    #expect(matrix == (try SourceStudioMapPlacement.mapRootMatrix(
        KoikatsuChangeAmount(position: position, rotationDegrees: rotation, scale: Float3(1, 1, 1)))))
    // Against Unity's own math: a map-root-local point x lands at
    // T(pos)·R(rot)·x in Unity world space; the engine basis reflects Z.
    let r = unityRotation(rotation)
    for local in [Float3(0, 0, 0), Float3(1, 0, 0), Float3(0, 2, -1), Float3(-3, 0.5, 4)] {
        let unityWorld = r * local + position
        let engine = matrix * Float4(local.x, local.y, -local.z, 1)
        #expect(simd_distance(Float3(engine.x, engine.y, engine.z), Float3(unityWorld.x, unityWorld.y, -unityWorld.z)) < 1e-5)
    }
    #expect(throws: (any Error).self) {
        try SourceStudioMapPlacement.mapRootMatrix(KoikatsuChangeAmount(position: Float3(.nan, 0, 0), rotationDegrees: .zero, scale: .one))
    }
    #expect(SourceStudioMapPlacement.sunTypeKey(0) == 0 && SourceStudioMapPlacement.sunTypeKey(2) == 2)
    #expect(SourceStudioMapPlacement.sunTypeKey(3) == -1 && SourceStudioMapPlacement.sunTypeKey(-1) == -1)
}

/// A converted map in the converter's layout: root "Map" (authored scale 2,
/// role mapRoot) over a mesh at local (0, 0, 1), and root "Scene" over a
/// mesh visible for sun type 1 only. Both sample one 1×1 PNG.
private struct MapFixture {
    let root: URL
    var url: URL { root.appendingPathComponent("map.gltf") }

    init(mapNode: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-map-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var buffer = Data()
        for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0] {
            var bits = value.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { buffer.append(contentsOf: $0) }
        }
        try buffer.write(to: root.appendingPathComponent("map.bin"))
        try Self.rgbaPNG().write(to: root.appendingPathComponent("0_tex.png"))
        func mesh(_ role: String, _ keys: [Int]) -> [String: Any] {
            ["name": role, "primitives": [["attributes": ["POSITION": 0, "TEXCOORD_0": 1], "material": 0]],
             "extras": ["ikkokuMap": ["role": role, "visibleFor": keys, "lightmapIndex": 0, "renderers": 1]]]
        }
        let gltf: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": buffer.count, "uri": "map.bin"]],
            "bufferViews": [["buffer": 0, "byteLength": 36], ["buffer": 0, "byteOffset": 36, "byteLength": 24]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]],
                          ["bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC2"]],
            "images": [["uri": "0_tex.png"]], "textures": [["source": 0]],
            "materials": [["name": "m", "pbrMetallicRoughness": ["baseColorTexture": ["index": 0], "baseColorFactor": [1, 1, 1, 1]]]],
            "meshes": [mesh("mapRoot", [-1, 0, 1, 2]), mesh("scene", [1])],
            "nodes": [["name": mapNode ? "Map" : "Root", "scale": [2, 2, 2], "children": [2], "extras": ["ikkokuMapRole": "mapRoot"]],
                      ["name": "Scene", "children": [3], "extras": ["ikkokuMapRole": "scene"]],
                      ["name": "a", "mesh": 0, "translation": [0, 0, 1]], ["name": "b", "mesh": 1, "translation": [0, 3, 0]]],
            "scenes": [["nodes": [0, 1]]], "scene": 0,
        ]
        try JSONSerialization.data(withJSONObject: gltf, options: [.sortedKeys]).write(to: url)
    }

    /// A 2×2 RGBA PNG, as the converter writes (UnityPy RGBA output).
    static func rgbaPNG() throws -> Data {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// A map load blocks its thread in MetalKit's synchronous texture load, and
/// `SourceStudioMapLoad.wait()` blocks until it ends. Both run on a thread of
/// their own (`liveTickOffPool`), so these tests hold no test-pool thread
/// (a parallel `swift test` once hung with every pool thread in that load);
/// the checks stay in the test's task.
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct SourceStudioMapAssetTests {
    @Test func mapPartsArePlacedByRoleAndFilteredBySunType() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let fixture = try MapFixture()
        defer { fixture.remove() }
        let (url, packageRoot) = (fixture.url, fixture.root)
        let asset = try await liveTickOffPool { try SourceStudioMapAsset.load(url: url, packageRoot: packageRoot, resources: resources) }
        #expect(asset.parts.count == 2 && asset.textures.count == 1 && asset.triangles == 2 && asset.textureBytes > 0)
        // Private registration: the image's texture is not in the store's key cache.
        #expect(resources.lookup(key: "\(fixture.url.standardizedFileURL.path)#img0#true") == nil)

        let amount = KoikatsuChangeAmount(position: Float3(1, 2, 3), rotationDegrees: Float3(0, 90, 0), scale: Float3(9, 9, 9))
        let root = try SourceStudioMapPlacement.mapRootMatrix(amount)
        let evening = try asset.items(transform: amount, sunLightType: 1)
        #expect(evening.count == 2)
        let mapRoot = try #require(evening.first { $0.mesh == asset.parts.first { $0.role == .mapRoot }!.mesh })
        let scene = try #require(evening.first { $0.mesh == asset.parts.first { $0.role == .scene }!.mesh })
        // Under "Map": the record's transform above the authored scale 2 (the
        // saved scale 9 is ignored); a scene-space root does not move.
        let expectedMapRoot = root * Transform.trs(.zero, .identity, Float3(repeating: 2)) * Transform.trs(Float3(0, 0, 1), .identity, .one)
        #expect(simd_almost_equal_elements(mapRoot.model, expectedMapRoot, 1e-6))
        #expect(simd_almost_equal_elements(scene.model, Transform.trs(Float3(0, 3, 0), .identity, .one), 1e-6))
        for item in evening {
            #expect(item.objectID == 0 && item.pickOccluder && !item.castsShadow && !item.outline && item.order == 100)
            #expect(item.material.base != nil && item.material.uniforms.kind == MaterialKindItem.rawValue)
        }
        // Day shows the map-root geometry only; a saved type with no
        // SunLightInfo entry keeps the authored state (-1).
        #expect(try asset.items(transform: amount, sunLightType: 0).map(\.mesh) == [mapRoot.mesh])
        #expect(try asset.items(transform: amount, sunLightType: 7).map(\.mesh) == [mapRoot.mesh])

        // Release is deferred (R6): the handles resolve until a later frame.
        let before = resources.statistics()
        asset.release(); asset.release()
        #expect(resources.statistics().retiring == 3)
        #expect(resources.texture(asset.textures[0]) != nil && resources.mesh(asset.parts[0].mesh) != nil)
        resources.completeRetirements(createdBefore: ResourceClock.tick())
        #expect(resources.statistics().retiring == 0)
        #expect(resources.statistics().meshes == before.meshes - 2 && resources.statistics().textures == before.textures - 1)
        #expect(resources.texture(asset.textures[0]) == nil)
    }

    @Test func aFileThatIsNotAConvertedMapFailsByNameAndRegistersNothing() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let fixture = try MapFixture(mapNode: false)
        defer { fixture.remove() }
        let (url, root) = (fixture.url, fixture.root)
        let before = resources.statistics()
        // The load's error text, or nil when it loaded.
        let failures = try await liveTickOffPool { () -> [String?] in
            [url, root.appendingPathComponent("absent.gltf")].map { file in
                do { _ = try SourceStudioMapAsset.load(url: file, packageRoot: root, resources: resources); return nil }
                catch { return "\(error)" }
            }
        }
        #expect(failures[0]?.contains("is not a converted map") == true, "\(failures[0] ?? "loaded")")
        let after = resources.statistics()
        #expect(after.meshes == before.meshes && after.textures == before.textures)
        // A missing file is an error too, never a substitute.
        #expect(failures[1] != nil)
    }

    @Test func aLoadIsTakenOnceAndACancelledLoadReleasesItsAsset() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let fixture = try MapFixture()
        defer { fixture.remove() }
        let (url, root) = (fixture.url, fixture.root)
        let load = SourceStudioMapLoad(url: url, packageRoot: root, resources: resources) { _ in }
        let (taken, again) = try await liveTickOffPool { (try load.wait()?.get(), load.wait() == nil) }
        let asset = try #require(taken)
        #expect(load.isFinished && asset.parts.count == 2)
        #expect(again) // taken once
        load.cancel()  // a taken asset stays its owner's
        #expect(!asset.isReleased)
        asset.release()

        let cancelled = SourceStudioMapLoad(url: url, packageRoot: root, resources: resources) { _ in
            Issue.record("a cancelled load delivered")
        }
        cancelled.cancel()
        // The worker drops what it built: everything it registered retires.
        let nothing = try await liveTickOffPool { () -> Bool in
            let delivered = cancelled.wait() != nil
            let deadline = Date().addingTimeInterval(10)
            while resources.statistics().retiring < 6, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            return !delivered
        }
        #expect(nothing)
        resources.completeRetirements(createdBefore: ResourceClock.tick())
        #expect(resources.statistics().meshes == 0 && resources.statistics().textures == 0)
    }
}

/// Texture retirement keeps the handle until a later frame and drops the
/// cache key at once; `unregister` still releases immediately.
@Test func retiredTexturesResolveUntilALaterFrameAndLoseTheirKeyAtOnce() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let resources = ResourceStore(device: device)
    let a = try #require(resources.texture(r8: [1], width: 1, height: 1, key: "a"))
    let b = try #require(resources.texture(r8: [2], width: 1, height: 1, key: "b"))
    let stampBefore = ResourceClock.tick()
    resources.retire(textures: [a])
    #expect(resources.lookup(key: "a") == nil && resources.texture(a) != nil)
    #expect(resources.statistics().retiring == 1)
    resources.completeRetirements(createdBefore: stampBefore) // a frame created before the retirement
    #expect(resources.texture(a) != nil)
    resources.completeRetirements(createdBefore: ResourceClock.tick())
    #expect(resources.texture(a) == nil && resources.statistics().retiring == 0)
    resources.retire(textures: [b])
    resources.unregister(texture: b)
    #expect(resources.statistics().retiring == 0 && resources.texture(b) == nil)
}
