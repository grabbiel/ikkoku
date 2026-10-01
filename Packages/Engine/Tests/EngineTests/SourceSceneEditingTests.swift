import Foundation
import Testing
import Character
@testable import Studio

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

@Test func sourceSceneEditingWritesEmbeddedFaceShapeEditsAndNoChangeEditsKeepEveryByte() throws {
    let card = OriginalCardFixture.card()
    let scene = SceneDocumentBytes.scene(card: card).data
    let original = try KoikatsuSceneReader.decodeDocument(scene)
    let before = try SourceCharacterCard.decode(card)
    let savedFace = try before.customization().faceValues
    // Passing the card's own saved values patches no numeric token, so the
    // whole scene file stays byte-identical even though a card edit is asked for.
    #expect(try original.editedData(.init(cards: [10: .init(faceValues: savedFace)])) == scene)
    var face = savedFace; face[3] = savedFace[3] == 0.5 ? 0.25 : 0.5
    let edited = try KoikatsuSceneReader.decodeDocument(original.editedData(.init(cards: [10: .init(faceValues: face)])))
    #expect(edited.settings == original.settings && edited.trailingData == original.trailingData)
    #expect(edited.snapshot.roots[1] == original.snapshot.roots[1])
    let after = try #require(edited.snapshot.roots[0].character).card()
    #expect(try after.customization().faceValues == face)
    // Only the edited face array moved; every other card byte is untouched.
    #expect(try after.customization().bodyValues == before.customization().bodyValues)
    #expect(after.thumbnailData == before.thumbnailData && after.faceThumbnailData == before.faceThumbnailData)
    #expect(after.block(named: "Parameter")?.data == before.block(named: "Parameter")?.data)
    #expect(after.block(named: "FutureOpaque")?.data == before.block(named: "FutureOpaque")?.data)
    #expect(after.trailingData == before.trailingData)
    // Writing the saved values back restores the saved numbers. Edited tokens are
    // re-encoded as float32 while this fixture packs float64, so the reversal is
    // value-level here; everything outside the edited array keeps its own bytes.
    let reverted = try KoikatsuSceneReader.decodeDocument(edited.editedData(.init(cards: [10: .init(faceValues: savedFace)])))
    #expect(try #require(reverted.snapshot.roots[0].character).card().customization().faceValues == savedFace)
    #expect(reverted.trailingData == original.trailingData && reverted.snapshot.roots[1] == original.snapshot.roots[1])
}

/// The default fixture's Custom block owns no Unity Color arrays, so the
/// color tests use a face record with an eyebrowColor field next to the
/// shape array plus an unknown extension that must survive untouched.
private func colorCustom() -> Data {
    typealias F = OriginalCardFixture
    let color: F.Value = .array([.float(0.1), .float(0.2), .float(0.3), .float(1)])
    let face = F.pack(F.map([("version", .string("0.0.2")), ("headId", .integer(0)),
        ("shapeValueFace", .array(F.faceValues)), ("eyebrowColor", color),
        ("unknownFace", .ext(4, Data([8, 7, 6])))]))
    let body = F.pack(F.map([("version", .string("0.0.2")), ("shapeValueBody", .array(F.bodyValues))]))
    return F.lengthData(face) + F.lengthData(body) + F.lengthData(Data([0xc1, 0xfe, 0xed]))
}
private func eyebrowColor(_ card: SourceCharacterCard) throws -> [Float] {
    let fields = try card.recordFields(.face)
    let members = try #require(fields["eyebrowColor"]?.arrayValue)
    return try members.map { if case .float(let value) = $0 { return Float(value) }; throw SourceCharacterCardError.invalid("Expected numeric color.") }
}

@Test func sourceSceneEditingEmbeddedColorEditsCombineWithFaceShapesAndRejectUnknownDestinations() throws {
    let card = OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(custom: colorCustom()))
    let scene = SceneDocumentBytes.scene(card: card).data
    let original = try KoikatsuSceneReader.decodeDocument(scene)
    let before = try SourceCharacterCard.decode(card)
    let savedColor: [Float] = [0.1, 0.2, 0.3, 1], editedColor: [Float] = [0.8, 0.4, 0.2, 0.9]
    // Writing the card's own saved color patches no numeric token, so the
    // whole scene file stays byte-identical even though a color edit is asked for.
    let noop = SourceCharacterCard.ColorEdit(record: .face, path: [.key("eyebrowColor")], rgba: savedColor)
    #expect(try original.editedData(.init(cards: [10: .init(colors: [noop])])) == scene)
    // A color and a face-shape edit on one character ride in a single Edits.
    var face = try before.customization().faceValues
    face[3] = face[3] == 0.5 ? 0.25 : 0.5
    let colorEdit = SourceCharacterCard.ColorEdit(record: .face, path: [.key("eyebrowColor")], rgba: editedColor)
    let edited = try KoikatsuSceneReader.decodeDocument(original.editedData(.init(cards: [10: .init(faceValues: face, colors: [colorEdit])])))
    #expect(edited.settings == original.settings && edited.trailingData == original.trailingData)
    #expect(edited.snapshot.roots[1] == original.snapshot.roots[1])
    let after = try #require(edited.snapshot.roots[0].character).card()
    #expect(try eyebrowColor(after) == editedColor)
    #expect(try after.customization().faceValues == face)
    // Only the edited tokens moved; every other card byte keeps its own bytes.
    #expect(try after.customization().bodyValues == before.customization().bodyValues)
    #expect(after.thumbnailData == before.thumbnailData && after.faceThumbnailData == before.faceThumbnailData)
    #expect(try after.recordFields(.face)["unknownFace"] == before.recordFields(.face)["unknownFace"])
    #expect(after.block(named: "Parameter")?.data == before.block(named: "Parameter")?.data)
    #expect(after.block(named: "FutureOpaque")?.data == before.block(named: "FutureOpaque")?.data)
    #expect(after.trailingData == before.trailingData)
    // Unknown destinations reject the whole edit before any bytes are returned:
    // a color field the record does not own, and an object key the scene lacks.
    #expect(throws: (any Error).self) {
        try original.editedData(.init(cards: [10: .init(colors: [.init(record: .face, path: [.key("missingColor")], rgba: editedColor)])]))
    }
    #expect(throws: (any Error).self) {
        try original.editedData(.init(cards: [99: .init(colors: [colorEdit])]))
    }
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

@Test func sourceSceneEditingVisibilityPatchesOwnFlagBytesAndReversesExactly() throws {
    let bytes = SceneDocumentBytes.scene().data, original = try KoikatsuSceneReader.decodeDocument(bytes)
    func changedOffsets(_ data: Data) -> [Int] { (0..<bytes.count).filter { data[$0] != bytes[$0] } }
    // A transform-only edit locates each object's 36-byte span; its visible byte sits
    // 40 bytes later (after treeState). Every fixture header stores visible = true.
    // The probe's byte patterns differ from the header's [1,2,3,0,15,0,1,1,1] at every
    // position, so exactly 36 contiguous bytes change.
    let probe = KoikatsuChangeAmount(
        position: SIMD3(Float(bitPattern:0x2468ACE1), Float(bitPattern:0x13579BD0), Float(bitPattern:0x02468AC8)),
        rotationDegrees: SIMD3(Float(bitPattern:0x79BDF135), Float(bitPattern:0x2468ACE0), Float(bitPattern:0x13579BDF)),
        scale: SIMD3(Float(bitPattern:0x2468ACE1), Float(bitPattern:0x13579BD0), Float(bitPattern:0x02468AC8)))
    func transformSpanStart(_ key: Int32) throws -> Int {
        let span = changedOffsets(try original.editedData(.init(transforms: [.init(.object(key), transform: probe)])))
        let start = try #require(span.first)
        try #require(span.count == 36 && span.last == start + 35)
        return start
    }
    let visibleOffsets = [try transformSpanStart(11) + 40, try transformSpanStart(20) + 40].sorted()
    let hidden = try original.editedData(.init(visibility: [11: false, 20: false]))
    #expect(hidden.count == bytes.count && changedOffsets(hidden) == visibleOffsets)
    #expect(visibleOffsets.allSatisfy { bytes[$0] == 1 && hidden[$0] == 0 })
    let result = try KoikatsuSceneReader.decodeDocument(hidden)
    let before = sceneObjects(original.snapshot.roots), after = sceneObjects(result.snapshot.roots)
    #expect(Set(before.keys) == Set(after.keys))
    #expect(after[11]?.visible == false && after[20]?.visible == false)
    #expect(after[10]?.visible == true && after[21]?.visible == true)
    for key in before.keys where key != 10 && key != 11 && key != 20 { #expect(after[key] == before[key]) }
    let root = try #require(after[10]), originalRoot = try #require(before[10])
    #expect(root.transform == originalRoot.transform && root.treeState == originalRoot.treeState && root.visible)
    #expect(root.character?.cardData == originalRoot.character?.cardData && root.character?.bones == originalRoot.character?.bones)
    #expect(result.settings == original.settings && result.trailingData == original.trailingData)
    // Reversing restores every source byte; an edit to the current value is identity.
    #expect(try result.editedData(.init(visibility: [11: true, 20: true])) == bytes)
    #expect(try original.editedData(.init(visibility: [10: true, 11: true])) == bytes)
    #expect(throws: (any Error).self) { try original.editedData(.init(visibility: [999: false])) }
}

@Test func sourceSceneEditingVisibilityAndTransformOnOneObjectCombineAndReverse() throws {
    let bytes = SceneDocumentBytes.scene().data, original = try KoikatsuSceneReader.decodeDocument(bytes)
    let before = try #require(original.snapshot.roots[0].character?.accessoryChildren[7]?.first)
    let transform = editedSceneTransform()
    let data = try original.editedData(.init(transforms: [.init(.object(11), transform: transform)], visibility: [11: false]))
    let result = try KoikatsuSceneReader.decodeDocument(data)
    let after = try #require(result.snapshot.roots[0].character?.accessoryChildren[7]?.first)
    #expect(after.transform == transform && !after.visible)
    #expect(data.count == bytes.count)
    #expect(try result.editedData(.init(transforms: [.init(.object(11), transform: before.transform)], visibility: [11: true])) == bytes)
}

@Test func sourceSceneEditingNamePatchesResizeRecordsAndReverseExactly() throws {
    let bytes = SceneDocumentBytes.scene().data, original = try KoikatsuSceneReader.decodeDocument(bytes)
    let before = sceneObjects(original.snapshot.roots)
    let folderName = "フォルダ名 — renamed" // Longer and multi-byte: shifts every following record.
    let delta = try KoikatsuBinaryReader.dotNetString(folderName).count - KoikatsuBinaryReader.dotNetString("Child").count
        + KoikatsuBinaryReader.dotNetString("").count - KoikatsuBinaryReader.dotNetString("Route").count
    let edited = try original.editedData(.init(names: [11: folderName, 20: ""]))
    let result = try KoikatsuSceneReader.decodeDocument(edited)
    #expect(edited.count == bytes.count + delta)
    let after = sceneObjects(result.snapshot.roots)
    #expect(after[11]?.name == folderName && after[20]?.name == "")
    #expect(before[11]?.name == "Child" && before[20]?.name == "Route")
    // Record 10 contains child 11, so compare its own fields explicitly.
    for key in before.keys where key != 10 && key != 11 && key != 20 { #expect(after[key] == before[key]) }
    let root = try #require(after[10]), originalRoot = try #require(before[10])
    #expect(root.transform == originalRoot.transform && root.name == originalRoot.name)
    #expect(root.character?.cardData == originalRoot.character?.cardData && root.character?.bones == originalRoot.character?.bones)
    #expect(after[11]?.name == folderName && root.character?.accessoryChildren[7]?.first?.sourceKey == 11)
    #expect(result.settings == original.settings && result.trailingData == original.trailingData)
    // Reversing restores every source byte; an edit to the stored name is identity.
    #expect(try result.editedData(.init(names: [11: "Child", 20: "Route"])) == bytes)
    #expect(try original.editedData(.init(names: [11: "Child"])) == bytes)
}

@Test func sourceSceneEditingRouteNameEditsWriteNothingUnchangedAndExactlyTheNewName() throws {
    let bytes = SceneDocumentBytes.scene().data, original = try KoikatsuSceneReader.decodeDocument(bytes)
    let before = sceneObjects(original.snapshot.roots)
    let routeName = try #require(before[20]?.name) // "Route"
    // The export baselines a route on its record name (like a folder): an
    // untouched route's diff is empty, so writing the stored name back is a
    // byte-identical no-op and no name edit exists to write.
    #expect(try original.editedData(.init(names: [20: routeName])) == bytes)
    #expect(try original.editedData(.init()) == original.preservedData)
    // A rename writes exactly the new name; reversing restores the source bytes.
    let renamed = try original.editedData(.init(names: [20: "IKKOKU-R3"]))
    let result = try KoikatsuSceneReader.decodeDocument(renamed)
    #expect(try #require(sceneObjects(result.snapshot.roots)[20]?.name) == "IKKOKU-R3")
    #expect(try result.editedData(.init(names: [20: routeName])) == bytes)
}

@Test func sourceSceneEditingNameEditsRejectRecordsWithoutSerializedNames() throws {
    let character = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    #expect(throws: (any Error).self) { try character.editedData(.init(names: [10: "renamed"])) } // Its name lives in the card.
    #expect(throws: (any Error).self) { try character.editedData(.init(names: [999: "renamed"])) }
    var bytes = SceneDocumentBytes(data: OriginalCardFixture.png)
    bytes.s("1.0.4.2"); bytes.i(2); bytes.i(13)
    bytes.header(1, 13) // Item: kind 1 carries no serialized name.
    bytes.i(7); bytes.i(8); bytes.i(9); bytes.f(1.25)
    for index in 0..<8 { bytes.s("{\"r\":\(index),\"g\":0.25,\"b\":0.5,\"a\":1}") }
    for key: Int32 in [3, 4, 5] { bytes.i(key); bytes.s("p.png"); bytes.b(true); bytes.s(#"{"x":0.25,"y":0.5,"z":2,"w":3}"#); bytes.f(45) }
    bytes.f(0.75); bytes.s(#"{"r":0.1,"g":0.2,"b":0.3,"a":1}"#); bytes.f(0.7)
    bytes.s(#"{"r":0.4,"g":0.5,"b":0.6,"a":1}"#); bytes.f(2); bytes.f(0.25)
    bytes.i(-1); bytes.s("panel.png"); bytes.b(true); bytes.s(#"{"x":0.25,"y":0.5,"z":2,"w":3}"#); bytes.f(45) // panel
    bytes.b(true) // enableFK
    bytes.i(1); bytes.s("bone"); bytes.i(77); bytes.transform()
    bytes.b(false); bytes.f(0.375) // enableDynamicBone, normalized time
    bytes.i(0) // children
    bytes.i(12); bytes.header(5, 12); bytes.s("Camera A"); bytes.b(true)
    bytes.tail()
    let scene = try KoikatsuSceneReader.decodeDocument(bytes.data)
    #expect(throws: (any Error).self) { try scene.editedData(.init(names: [13: "renamed"])) }
    let renamed = try scene.editedData(.init(names: [12: "カメラ B"]))
    let result = try KoikatsuSceneReader.decodeDocument(renamed)
    #expect(result.snapshot.roots[1].name == "カメラ B" && result.snapshot.roots[0] == scene.snapshot.roots[0])
    #expect(try result.editedData(.init(names: [12: "Camera A"])) == bytes.data)
}

@Test func sourceSceneDotNetStringEncodingUsesSevenBitUTF8ByteLengths() throws {
    for (count, prefix): (Int, [UInt8]) in [(0, [0]), (1, [1]), (127, [127]), (128, [128, 1]), (16_383, [255, 127]), (16_384, [128, 128, 1])] {
        let value = String(repeating: "x", count: count)
        let encoded = try KoikatsuBinaryReader.dotNetString(value)
        #expect(encoded.starts(with: prefix))
        #expect(encoded.count == prefix.count + count)
        var reader = try KoikatsuBinaryReader(encoded)
        #expect(try reader.string() == value)
    }
    // The prefix counts UTF-8 bytes, not characters: 60 × 庭 = 180 bytes.
    let multi = try KoikatsuBinaryReader.dotNetString(String(repeating: "庭", count: 60))
    #expect(multi.first == 0xb4 && multi.count == 182) // 180 bytes need a two-byte prefix.
    #expect(throws: (any Error).self) { try KoikatsuBinaryReader.dotNetString(String(repeating: "x", count: 1_048_577)) }
}

@Test func sourceSceneEditingNameAndVisibilityOnOneObjectCombineAndReverse() throws {
    let bytes = SceneDocumentBytes.scene().data, original = try KoikatsuSceneReader.decodeDocument(bytes)
    let before = sceneObjects(original.snapshot.roots)
    let shrink = try KoikatsuBinaryReader.dotNetString("Route").count - KoikatsuBinaryReader.dotNetString("R").count
    let data = try original.editedData(.init(visibility: [20: false], names: [20: "R"]))
    #expect(data.count == bytes.count - shrink)
    let result = try KoikatsuSceneReader.decodeDocument(data)
    let after = sceneObjects(result.snapshot.roots)
    #expect(after[20]?.name == "R" && after[20]?.visible == false)
    for key in before.keys where key != 20 { #expect(after[key] == before[key]) }
    #expect(try result.editedData(.init(visibility: [20: true], names: [20: "Route"])) == bytes)
}

@Test func sourceSceneEditingCameraAndRouteActiveFlagsPatchOwnBytesAndReverseExactly() throws {
    let bytes = SceneDocumentBytes.scene(cameraObject: true).data, original = try KoikatsuSceneReader.decodeDocument(bytes)
    func changedOffsets(_ data: Data) -> [Int] { (0..<bytes.count).filter { data[$0] != bytes[$0] } }
    // The camera record saves active = true, the route active = false; each
    // single edit shifts exactly one byte and only its own record's flag.
    #expect(original.snapshot.roots[2].cameraActive == true && original.snapshot.roots[1].route?.active == false)
    let cameraOffsets = changedOffsets(try original.editedData(.init(cameraActive: [30: false])))
    let routeOffsets = changedOffsets(try original.editedData(.init(routeActive: [20: true])))
    #expect(cameraOffsets.count == 1 && routeOffsets.count == 1)
    let edited = try original.editedData(.init(cameraActive: [30: false], routeActive: [20: true]))
    #expect(edited.count == bytes.count && changedOffsets(edited) == (cameraOffsets + routeOffsets).sorted())
    #expect(bytes[cameraOffsets[0]] == 1 && edited[cameraOffsets[0]] == 0)
    #expect(bytes[routeOffsets[0]] == 0 && edited[routeOffsets[0]] == 1)
    let result = try KoikatsuSceneReader.decodeDocument(edited)
    let before = sceneObjects(original.snapshot.roots), after = sceneObjects(result.snapshot.roots)
    #expect(Set(before.keys) == Set(after.keys))
    #expect(after[30]?.cameraActive == false && after[20]?.route?.active == true)
    for key in before.keys where key != 20 && key != 30 { #expect(after[key] == before[key]) }
    #expect(result.settings == original.settings && result.trailingData == original.trailingData)
    // Reversing restores every source byte; an edit to the stored flags is identity.
    #expect(try result.editedData(.init(cameraActive: [30: true], routeActive: [20: false])) == bytes)
    #expect(try original.editedData(.init(cameraActive: [30: true], routeActive: [20: false])) == bytes)
    // The active byte exists only on its own record kind: folders, characters
    // and (for the camera destination) routes have no such span; unknown keys
    // have none either.
    for key: Int32 in [10, 11, 20, 999] {
        #expect(throws: (any Error).self) { try original.editedData(.init(cameraActive: [key: false])) }
    }
    for key: Int32 in [10, 11, 30, 999] {
        #expect(throws: (any Error).self) { try original.editedData(.init(routeActive: [key: true])) }
    }
    // A visibility edit on the same route combines and reverses.
    let combined = try original.editedData(.init(visibility: [20: false], cameraActive: [30: false], routeActive: [20: true]))
    #expect(combined.count == bytes.count)
    let combinedResult = try KoikatsuSceneReader.decodeDocument(combined)
    let combinedAfter = sceneObjects(combinedResult.snapshot.roots)
    #expect(combinedAfter[20]?.visible == false && combinedAfter[20]?.route?.active == true && combinedAfter[30]?.cameraActive == false)
    #expect(try combinedResult.editedData(.init(visibility: [20: true], cameraActive: [30: true], routeActive: [20: false])) == bytes)
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_SCENE_FIXTURES"]),
               "Requires IKKOKU_STUDIO_SCENE_FIXTURES"))
func sourceSceneEditingRoundTripsIndependentSceneFixturesWhenSupplied() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_STUDIO_SCENE_FIXTURES"))
    // The fixtures directory also contains source/; avoid duplicate work.
    let urls = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        .compactMap { $0 as? URL }
        .filter { $0.deletingLastPathComponent() == root
            && ["synthetic-current.png", "synthetic-legacy-card.png", "synthetic-both-modes.png"].contains($0.lastPathComponent) }
    try sceneEditingRoundTrips(urls)
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_ORIGINAL_SCENES"]),
               "Requires IKKOKU_STUDIO_ORIGINAL_SCENES"))
func sourceSceneEditingRoundTripsRecoveredOriginalScenesWhenSupplied() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_STUDIO_ORIGINAL_SCENES"))
    let urls = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "png" }
    try sceneEditingRoundTrips(urls)
}

private func sceneEditingRoundTrips(_ urls: [URL]) throws {
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
    // A supplied fixture set must actually be exercised, never skipped vacuously.
    #expect(!urls.isEmpty)
    #expect(objectsChecked > 0 && charactersChecked > 0)
}
