import Foundation
import Testing
import Studio
import Scene
import Character

private func exportValidationDocument(_ source: KoikatsuSceneDocument, rendered: Bool = true, baselines: Bool = true) -> StudioDocument {
    var document = StudioDocument()
    document.sourceSceneFile = "/fixture/original.png"; document.sourceSceneSHA256 = String(repeating: "a", count: 64)
    func append(_ record: KoikatsuObjectRecord, parent: UUID?, routeChild: Bool, attachment: Int32? = nil) {
        var object = StudioObject(name: record.name ?? "Source object \(record.sourceKey)", kind: .folder)
        object.sourceObjectKey = record.sourceKey; object.parent = parent; object.sourceAttachmentPoint = attachment
        if record.character != nil, !routeChild {
            if rendered {
                object.kind = .character; object.name = "Source character \(record.sourceKey)"
                object.sourceCharacter = .init(sceneFile: document.sourceSceneFile!, sceneSHA256: document.sourceSceneSHA256!,
                    rigFile: "/fixture/rig.json", boneCatalogFile: "/fixture/bones.json", objectKey: record.sourceKey)
            }
        } else if record.kind != .folder { object.name = "Unrendered source \(record.kind) \(record.sourceKey)" }
        if baselines { object.sourcePreviewName = object.name; object.sourcePreviewKind = object.kind }
        document.objects.append(object)
        for child in record.children { append(child, parent: object.id, routeChild: routeChild || record.kind == .route) }
        for (point, children) in record.character?.accessoryChildren ?? [:] {
            for child in children { append(child, parent: object.id, routeChild: routeChild, attachment: point) }
        }
    }
    for root in source.snapshot.roots { append(root, parent: nil, routeChild: false) }
    return document
}

@Test func sourceSceneExportValidationAcceptsBaselinesLegacyDocumentsAndSupportedEdits() throws {
    let source = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    for rendered in [false, true] { for baselines in [false, true] {
        var document = exportValidationDocument(source, rendered: rendered, baselines: baselines)
        document.objects[0].locked = true // Editor metadata has no source effect.
        document.objects[0].transform.position.x += 0.125
        document.objects[0].transform.rotation.y = 12
        if rendered {
            document.objects[0].sourceFKRotations = [1: SIMD3(11, 23, 7)]
            let original = try #require(document.objects[0].sourceCharacter)
            document.objects[0].sourceCharacter = .init(sceneFile: original.sceneFile, sceneSHA256: original.sceneSHA256,
                rigFile: "/different/converted-rig.json", boneCatalogFile: "/different/bones.json", objectKey: original.objectKey,
                makerLibraryFile: "/different/library.json", attachmentCatalogFile: "/different/attachments.json")
        }
        let restored = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(document))
        #expect(restored.objects[0].sourcePreviewName == document.objects[0].sourcePreviewName)
        #expect(restored.objects[0].sourcePreviewKind == document.objects[0].sourcePreviewKind)
        try SourceSceneExportValidation.validate(restored, against: source.snapshot)
    } }
}

@Test func sourceSceneExportValidationRejectsEveryUnserializedNativeOverride() throws {
    let source = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    let baseline = exportValidationDocument(source)
    let changes: [(String, (inout StudioObject) -> Void)] = [
        ("replaced card", { $0.card = CharacterCard() }),
        ("left hand", { $0.handGestureL = 1 }), ("right hand", { $0.handGestureR = 2 }),
        ("clothing visibility", { $0.clothingVisible = false }), ("accessory visibility", { $0.accessoriesVisible = false }),
        ("item identity", { $0.itemID = "replacement" }), ("asset", { $0.assetFile = "/fixture/asset.glb" }),
        ("tint", { $0.tint = .white }), ("emission", { $0.emissive = 0.25 }),
        ("light", { $0.light = SceneLight(kind: .point) }), ("camera", { $0.savedCamera = OrbitCamera() }),
        ("field of view", { $0.fov = 45 }), ("animation", { $0.animationPreset = "wave" }),
        ("IK", { $0.ikTargets[.handL] = .init(enabled: true) }),
        ("prototype pose", { $0.poseDelta.rotations["head"] = SIMD3(10, 0, 0) }),
        ("name", { $0.name += " edited" }), ("kind", { $0.kind = .folder }),
    ]
    for (name, change) in changes {
        var document = baseline; change(&document.objects[0])
        #expect(throws: (any Error).self, Comment(rawValue: name)) {
            try SourceSceneExportValidation.validate(document, against: source.snapshot)
        }
    }
    // Replacing a converted character by a placeholder must also fail if both
    // the native type and its reference were removed together.
    var removed = baseline; removed.objects[0].sourceCharacter = nil; removed.objects[0].kind = .folder
    #expect(throws: (any Error).self) { try SourceSceneExportValidation.validate(removed, against: source.snapshot) }
    #expect(try source.editedData(.init()) == source.preservedData)
}

@Test func sourceSceneExportValidationRejectsReferenceAndSourceIdentityDrift() throws {
    let source = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data), baseline = exportValidationDocument(source)
    let reference = try #require(baseline.objects[0].sourceCharacter)
    for (path, hash, key) in [("/fixture/other.png", reference.sceneSHA256, reference.objectKey),
                             (reference.sceneFile, String(repeating: "b", count: 64), reference.objectKey),
                             (reference.sceneFile, reference.sceneSHA256, Int32(11))] {
        var document = baseline
        document.objects[0].sourceCharacter = .init(sceneFile: path, sceneSHA256: hash,
            rigFile: reference.rigFile, boneCatalogFile: reference.boneCatalogFile, objectKey: key)
        #expect(throws: (any Error).self) { try SourceSceneExportValidation.validate(document, against: source.snapshot) }
    }
    var placeholder = baseline
    placeholder.objects[1].sourceCharacter = reference
    #expect(throws: (any Error).self) { try SourceSceneExportValidation.validate(placeholder, against: source.snapshot) }
    placeholder = baseline; placeholder.objects[1].sourceFKRotations = [1: .zero]
    #expect(throws: (any Error).self) { try SourceSceneExportValidation.validate(placeholder, against: source.snapshot) }
    var missing = baseline; missing.objects.removeLast()
    #expect(throws: (any Error).self) { try SourceSceneExportValidation.validate(missing, against: source.snapshot) }
    var duplicate = baseline; duplicate.objects[1].sourceObjectKey = duplicate.objects[0].sourceObjectKey
    #expect(throws: (any Error).self) { try SourceSceneExportValidation.validate(duplicate, against: source.snapshot) }
    // Swift's canonical String equality must not hide a changed name payload.
    var renamed = baseline; renamed.objects[0].sourcePreviewName = "caf\u{e9}"; renamed.objects[0].name = "cafe\u{301}"
    #expect(throws: (any Error).self) { try SourceSceneExportValidation.validate(renamed, against: source.snapshot) }
}

@Test func sourceSceneExportValidationHandlesLegacyUnrenderedRouteCharacters() throws {
    var bytes = SceneDocumentBytes(data: OriginalCardFixture.png)
    bytes.s("1.0.4.2"); bytes.i(1); bytes.i(20)
    bytes.header(4, 20); bytes.s("Route"); bytes.i(1); bytes.character(OriginalCardFixture.card(), both: false)
    bytes.i(0); bytes.b(false); bytes.b(true); bytes.b(true); bytes.i(2); bytes.color(); bytes.tail()
    let source = try KoikatsuSceneReader.decodeDocument(bytes.data)
    var document = exportValidationDocument(source, baselines: false)
    #expect(document.objects[1].name == "Unrendered source character 10")
    try SourceSceneExportValidation.validate(document, against: source.snapshot)
    document.objects[1].name = "Source object 10"
    #expect(throws: (any Error).self) { try SourceSceneExportValidation.validate(document, against: source.snapshot) }
}
