import Testing
import Foundation
import simd
import CoreMath
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
