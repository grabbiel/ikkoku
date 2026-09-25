import Foundation
import Testing
import Character
import Studio

private func editedSceneTransform(_ n: Float = 1) -> KoikatsuChangeAmount {
    .init(position: SIMD3(n, 2*n, -3*n), rotationDegrees: SIMD3(11*n, -22*n, 33*n), scale: SIMD3(0.9, 1.1, -1))
}
private func editedSceneCamera() -> KoikatsuCameraRecord {
    .init(position: SIMD3(1.5,2.5,-3.5), rotationDegrees: SIMD3(10,20,30), distance: SIMD3(0.2,-0.3,-4.5), fieldOfView: 42.5)
}

private func sceneObjects(_ roots: [KoikatsuObjectRecord]) -> [Int32: KoikatsuObjectRecord] {
    var result: [Int32: KoikatsuObjectRecord] = [:]
    func visit(_ object: KoikatsuObjectRecord) {
        result[object.sourceKey] = object
        for child in object.children { visit(child) }
        if let character = object.character { for children in character.accessoryChildren.values { for child in children { visit(child) } } }
    }
    for root in roots { visit(root) }
    return result
}

@Test func sourceSceneEditingNoopPreservesCompleteFileAndUnknownTrailer() throws {
    let input = SceneDocumentBytes.scene()
    for tail in [Data(), Data([0,255,193,17]), input.data.suffix(from: input.baseEnd)] {
        let bytes = input.data.prefix(input.baseEnd) + tail
        let document = try KoikatsuSceneReader.decodeDocument(bytes)
        #expect(try document.editedData(.init()) == bytes)
        let same = SourceSceneEdits.TransformEdit(.object(10), transform: document.snapshot.roots[0].transform)
        #expect(try document.editedData(.init(transforms: [same])) == bytes)
    }
}

@Test func sourceSceneEditingPatchesNestedObjectsFKIKAndLookAtWithoutOtherChanges() throws {
    let bytes = SceneDocumentBytes.scene().data, original = try KoikatsuSceneReader.decodeDocument(bytes)
    let transform = editedSceneTransform(), other = editedSceneTransform(2)
    let edits: [SourceSceneEdits.TransformEdit] = [
        .init(.object(11), transform: transform), // Nested accessory child, not a root dictionary key.
        .init(.characterFK(object: 10, bone: 1), transform: transform),
        .init(.characterIK(object: 10, target: 3), transform: other),
        .init(.lookAt(object: 10), transform: other)]
    let data = try original.editedData(.init(transforms: edits)), result = try KoikatsuSceneReader.decodeDocument(data)
    #expect(data.count == bytes.count && result.settings == original.settings)
    #expect(result.trailingData == original.trailingData)
    #expect(result.snapshot.roots[1] == original.snapshot.roots[1])
    let character = try #require(result.snapshot.roots[0].character), before = try #require(original.snapshot.roots[0].character)
    #expect(character.cardData == before.cardData && character.bones[1]?.sourceKey == 101 && character.ikTargets[3]?.sourceKey == 103)
    #expect(character.bones[1]?.transform == transform && character.bones[2] == before.bones[2])
    #expect(character.ikTargets[3]?.transform == other && character.lookAtTarget.transform == other)
    #expect(character.accessoryChildren[7]?.first?.transform == transform)
    #expect(character.animation == before.animation && character.voices == before.voices && character.neckData == before.neckData)
    // Reversing just the requested transforms restores every source byte.
    let reverse: [SourceSceneEdits.TransformEdit] = [
        .init(.object(11), transform: try #require(before.accessoryChildren[7]?.first).transform),
        .init(.characterFK(object: 10, bone: 1), transform: try #require(before.bones[1]).transform),
        .init(.characterIK(object: 10, target: 3), transform: try #require(before.ikTargets[3]).transform),
        .init(.lookAt(object: 10), transform: before.lookAtTarget.transform)]
    #expect(try result.editedData(.init(transforms: reverse)) == bytes)
}

@Test func sourceSceneEditingResizesEmbeddedCardsAndRetainsSceneAndCardPluginPayloads() throws {
    let plugins = OriginalCardFixture.map([("future.plugin", OriginalCardFixture.plugin(99,
        data: OriginalCardFixture.map([("identity", .string("Case.Sensitive")), ("opaque", .ext(77, Data([1,2,255])))])))])
    let card = OriginalCardFixture.card(blocks: OriginalCardFixture.blocks() + [OriginalCardFixture.extended(plugins)],
                                       trailer: OriginalCardFixture.legacy(plugins))
    let original = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene(card: card).data)
    let edits = SourceSceneEdits(transforms: [.init(.object(10), transform: editedSceneTransform()),
        .init(.object(11), transform: editedSceneTransform(2))],
        cards: [10: .init(bodyValues: Array(repeating: 0.45, count: 44), faceThumbnailData: OriginalCardFixture.png)],
        kinematics: [10: .init(enableFK: false, enableIK: true, activeFK: Array(repeating: false, count: 7), activeIK: Array(repeating: true, count: 5))])
    let bytes = try original.editedData(edits), result = try KoikatsuSceneReader.decodeDocument(bytes)
    #expect(result.settings == original.settings && result.trailingData == original.trailingData)
    #expect(result.snapshot.roots[1] == original.snapshot.roots[1])
    #expect(result.snapshot.roots[0].transform == editedSceneTransform())
    #expect(result.snapshot.roots[0].character?.accessoryChildren[7]?.first?.transform == editedSceneTransform(2))
    #expect(result.snapshot.roots[0].character?.enableFK == false && result.snapshot.roots[0].character?.enableIK == true)
    #expect(result.snapshot.roots[0].character?.activeFK == Array(repeating: false, count: 7))
    #expect(result.snapshot.roots[0].character?.activeIK == Array(repeating: true, count: 5))
    let before = try SourceCharacterCard.decode(card), after = try #require(result.snapshot.roots[0].character).card()
    #expect(after.thumbnailData.isEmpty && after.faceThumbnailData == OriginalCardFixture.png)
    #expect(try after.customization().bodyValues == Array(repeating: Float(0.45), count: 44))
    #expect(after.block(named: "KKEx")?.data == before.block(named: "KKEx")?.data)
    #expect(after.trailingData == before.trailingData && after.block(named: "FutureOpaque")?.data == before.block(named: "FutureOpaque")?.data)
    #expect(after.block(named: "Parameter")?.data == before.block(named: "Parameter")?.data)
    #expect(result.snapshot.objectSectionEndOffset - original.snapshot.objectSectionEndOffset == after.preservedData.count - card.count)
    #expect(result.baseSceneEndOffset - original.baseSceneEndOffset == after.preservedData.count - card.count)
}

@Test func sourceSceneEditingRejectsUnknownDuplicateInvalidAndIdentityChangingEdits() throws {
    let original = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    let transform = editedSceneTransform(), object = SourceSceneEdits.TransformEdit(.object(10), transform: transform)
    let unavailable: [SourceSceneEdits.Destination] = [.object(999), .characterFK(object: 10, bone: 101),
        .characterIK(object: 20, target: 3), .itemFK(object: 10, bone: "not-item"), .lookAt(object: 20)]
    for destination in unavailable {
        #expect(throws: (any Error).self) { try original.editedData(.init(transforms: [.init(destination, transform: transform)])) }
    }
    #expect(throws: (any Error).self) { try original.editedData(.init(transforms: [object, object])) }
    #expect(throws: (any Error).self) { try original.editedData(.init(transforms: [.init(.object(10), transform: editedSceneTransform(.nan))])) }
    #expect(throws: (any Error).self) { try original.editedData(.init(cards: [20: .init()])) }
    #expect(throws: (any Error).self) { try original.editedData(.init(kinematics: [20: .init(enableFK: true)])) }
    #expect(throws: (any Error).self) { try original.editedData(.init(kinematics: [10: .init(activeFK: [true])])) }
    #expect(throws: (any Error).self) { try original.editedData(.init(kinematics: [10: .init(activeIK: Array(repeating: false, count: 6))])) }
    #expect(throws: (any Error).self) { try original.editedData(.init(cards: [10: .init(thumbnailData: OriginalCardFixture.png)])) }
    let maleCard = OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(sex: .integer(0)))
    let mismatch = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene(card: maleCard).data)
    #expect(throws: (any Error).self) { try mismatch.editedData(.init(cards: [10: .init(bodyValues: Array(repeating: 0.5, count: 44))])) }
    #expect(try original.editedData(.init()) == original.preservedData)
}

@Test func sourceSceneEditingThumbnailReplacementIsExplicitExactAndCRCValidated() throws {
    let original = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    #expect(try original.editedData(.init(thumbnailData: OriginalCardFixture.png)) == original.preservedData)
    var corrupt = OriginalCardFixture.png; corrupt[29] ^= 1
    for png in [Data(), corrupt, OriginalCardFixture.png + Data([0]), Data(OriginalCardFixture.png.dropLast())] {
        #expect(throws: (any Error).self) { try original.editedData(.init(thumbnailData: png)) }
    }
    let text = Data("Comment\0Native scene fixture".utf8), chunk = Data("tEXt".utf8) + text
    var crc = UInt32.max
    for byte in chunk { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) } }
    let ancillary = OriginalCardFixture.number(UInt64(text.count), count: 4, bigEndian: true) + chunk
        + OriginalCardFixture.number(UInt64(~crc), count: 4, bigEndian: true)
    let replacement = OriginalCardFixture.png.dropLast(12) + ancillary + OriginalCardFixture.png.suffix(12)
    let changed = try original.editedData(.init(thumbnailData: replacement))
    #expect(changed.prefix(replacement.count) == replacement)
    #expect(changed.dropFirst(replacement.count) == original.preservedData.dropFirst(OriginalCardFixture.png.count))
    #expect(try KoikatsuSceneReader.decodeDocument(changed).settings == original.settings)
}

@Test func sourceSceneEditingItemFKUsesNamedDictionaryBoneAndPreservesItemIdentity() throws {
    var bytes = StudioBytes.prefix(); bytes.i32(700); bytes.item()
    var tail = SceneDocumentBytes(); tail.tail(); bytes.data += tail.data
    let original = try KoikatsuSceneReader.decodeDocument(bytes.data)
    let edit = SourceSceneEdits.TransformEdit(.itemFK(object: 13, bone: "chair_joint"), transform: editedSceneTransform())
    let result = try KoikatsuSceneReader.decodeDocument(original.editedData(.init(transforms: [edit])))
    let item = try #require(result.snapshot.roots.first?.item), before = try #require(original.snapshot.roots.first?.item)
    #expect(result.snapshot.roots.first?.rootDictionaryKey == 700 && result.snapshot.roots.first?.sourceKey == 13)
    #expect(item.group == before.group && item.category == before.category && item.no == before.no)
    #expect(item.bones["chair_joint"]?.sourceKey == 77 && item.bones["chair_joint"]?.transform == editedSceneTransform())
    let reverse = SourceSceneEdits.TransformEdit(.itemFK(object: 13, bone: "chair_joint"), transform: try #require(before.bones["chair_joint"]).transform)
    #expect(try result.editedData(.init(transforms: [reverse])) == bytes.data)
}

@Test func sourceSceneEditingNamedItemBoneLookupUsesSourceOrdinalIdentity() throws {
    var bytes = StudioBytes.prefix(); bytes.i32(700); bytes.item(bone: "caf\u{e9}")
    var tail = SceneDocumentBytes(); tail.tail(); bytes.data += tail.data
    let original = try KoikatsuSceneReader.decodeDocument(bytes.data)
    let destination = SourceSceneEdits.Destination.itemFK(object: 13, bone: "cafe\u{301}")
    #expect(throws: (any Error).self) { try original.editedData(.init(transforms: [.init(destination, transform: editedSceneTransform())])) }
    let valid = SourceSceneEdits.Destination.itemFK(object: 13, bone: "caf\u{e9}")
    #expect(try original.editedData(.init(transforms: [.init(valid, transform: editedSceneTransform())])) != bytes.data)
}

@Test func sourceSceneEditingSupportsSlicedDataWithNonzeroStartIndex() throws {
    let input = SceneDocumentBytes.scene().data
    let slice = (Data([9,8,7]) + input).dropFirst(3)
    let original = try KoikatsuSceneReader.decodeDocument(slice)
    let result = try KoikatsuSceneReader.decodeDocument(original.editedData(.init(transforms: [.init(.object(10), transform: editedSceneTransform())])))
    #expect(result.snapshot.roots[0].transform == editedSceneTransform())
    #expect(result.trailingData == original.trailingData)
}

@Test func sourceSceneEditingKinematicFlagsKeepUnrelatedSettingsAndReverseExactly() throws {
    let original = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene(both: true).data)
    let before = try #require(original.snapshot.roots[0].character)
    let fk = [true,false,true,false,true,false,true], ik = [false,true,false,true,false]
    let edit = SourceSceneEdits.KinematicEdit(enableFK: true, enableIK: false, activeFK: fk, activeIK: ik)
    let result = try KoikatsuSceneReader.decodeDocument(original.editedData(.init(kinematics: [10: edit])))
    let after = try #require(result.snapshot.roots[0].character)
    #expect(after.enableFK && !after.enableIK && after.activeFK == fk && after.activeIK == ik)
    #expect(after.cardData == before.cardData && after.bones == before.bones && after.ikTargets == before.ikTargets)
    #expect(after.animation == before.animation && after.kinematicMode == before.kinematicMode)
    #expect(result.settings == original.settings && result.trailingData == original.trailingData)
    let reverse = SourceSceneEdits.KinematicEdit(enableFK: before.enableFK, enableIK: before.enableIK, activeFK: before.activeFK, activeIK: before.activeIK)
    #expect(try result.editedData(.init(kinematics: [10: reverse])) == original.preservedData)
}

@Test func sourceSceneEditingRestoresCurrentCameraAndAllSlotComponentsIncludingRoll() throws {
    let original = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    let camera = editedSceneCamera()
    let data = try original.editedData(.init(currentCamera: camera, cameraSlots: [0: camera, 9: camera]))
    let result = try KoikatsuSceneReader.decodeDocument(data)
    #expect(result.settings.camera == camera && result.settings.cameraSlots[0] == camera && result.settings.cameraSlots[9] == camera)
    #expect(Array(result.settings.cameraSlots[1..<9]) == Array(original.settings.cameraSlots[1..<9]))
    #expect(result.snapshot == original.snapshot && result.trailingData == original.trailingData)
    #expect(data.count == original.preservedData.count)
    #expect(try result.editedData(.init(currentCamera: original.settings.camera,
        cameraSlots: [0: original.settings.cameraSlots[0], 9: original.settings.cameraSlots[9]])) == original.preservedData)
    for slot in [-1,10] { #expect(throws: (any Error).self) { try original.editedData(.init(cameraSlots: [slot: camera])) } }
    for fov: Float in [-1,0,180,.nan,.infinity] {
        let bad = KoikatsuCameraRecord(position: camera.position, rotationDegrees: camera.rotationDegrees, distance: camera.distance, fieldOfView: fov)
        #expect(throws: (any Error).self) { try original.editedData(.init(currentCamera: bad)) }
    }
    let bad = KoikatsuCameraRecord(position: SIMD3(.nan,1,2), rotationDegrees: camera.rotationDegrees, distance: camera.distance, fieldOfView: 45)
    #expect(throws: (any Error).self) { try original.editedData(.init(currentCamera: bad)) }
}

@Test func sourceSceneEditingRoundTripsRecoveredOriginalScenesAndIndependentFixturesWhenSupplied() throws {
    var urls: [URL] = []
    for key in ["IKKOKU_STUDIO_SCENE_FIXTURES", "IKKOKU_STUDIO_ORIGINAL_SCENES"] {
        guard let path = ProcessInfo.processInfo.environment[key] else { continue }
        let root = URL(fileURLWithPath: path)
        for case let url as URL in try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])) where url.pathExtension.lowercased() == "png" {
            // The fixtures directory also contains source/; avoid duplicate work.
            if key == "IKKOKU_STUDIO_SCENE_FIXTURES" && (url.deletingLastPathComponent() != root || !["synthetic-current.png", "synthetic-legacy-card.png", "synthetic-both-modes.png"].contains(url.lastPathComponent)) { continue }
            urls.append(url)
        }
    }
    var objectsChecked = 0, charactersChecked = 0
    for url in urls {
        let bytes = try Data(contentsOf: url), original = try KoikatsuSceneReader.decodeDocument(bytes)
        #expect(try original.editedData(.init()) == bytes)
        guard let object = original.snapshot.roots.first else { continue }
        let changed = try original.editedData(.init(transforms: [.init(.object(object.sourceKey), transform: editedSceneTransform())]))
        let result = try KoikatsuSceneReader.decodeDocument(changed)
        #expect(result.snapshot.roots.first?.transform == editedSceneTransform())
        #expect(result.settings == original.settings && result.trailingData == original.trailingData)
        #expect(try result.editedData(.init(transforms: [.init(.object(object.sourceKey), transform: object.transform)])) == bytes)
        objectsChecked += 1
        var combined = SourceSceneEdits(transforms: [.init(.object(object.sourceKey), transform: editedSceneTransform())],
            currentCamera: editedSceneCamera(), cameraSlots: [0: editedSceneCamera(), 9: editedSceneCamera()])
        var cardObject: Int32?, expectedBody: [Float]?
        let objects = sceneObjects(original.snapshot.roots)
        if let key = objects.keys.sorted().first(where: { objects[$0]?.character != nil }), let character = objects[key]?.character {
            let card = try character.card(); var body = try card.customization().bodyValues
            body[1] = body[1] == 0.45 ? 0.55 : 0.45
            let edited = try KoikatsuSceneReader.decodeDocument(original.editedData(.init(cards: [key: .init(bodyValues: body)])))
            let after = try #require(sceneObjects(edited.snapshot.roots)[key]?.character).card()
            #expect(try after.customization().bodyValues == body)
            #expect(after.block(named: "KKEx")?.data == card.block(named: "KKEx")?.data)
            #expect(after.trailingData == card.trailingData)
            #expect(edited.trailingData == original.trailingData && edited.settings == original.settings)
            charactersChecked += 1
            cardObject = key; expectedBody = body; combined.cards[key] = .init(bodyValues: body)
            combined.kinematics[key] = .init(enableFK: true, enableIK: false, activeFK: Array(repeating: true, count: 7), activeIK: Array(repeating: false, count: 5))
        }
        if let path = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_EDIT_OUTPUT"] {
            let directory = URL(fileURLWithPath: path).standardizedFileURL
            guard directory.path.contains("/.local/") else { throw CocoaError(.fileWriteInvalidFileName) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent(url.lastPathComponent + ".edited.png")
            let data = try original.editedData(combined)
            try data.write(to: output)
            let report: [String: Any] = ["input": url.path, "output": output.path, "objectKey": object.sourceKey,
                "cardObject": cardObject as Any? ?? NSNull(), "expectedBody": expectedBody as Any? ?? NSNull(),
                "sourceSHA256": OriginalCardFixture.hash(bytes), "editedSHA256": OriginalCardFixture.hash(data)]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(url.lastPathComponent + ".roundtrip.json"))
        }
    }
    if !urls.isEmpty { #expect(objectsChecked > 0 && charactersChecked > 0) }
}
