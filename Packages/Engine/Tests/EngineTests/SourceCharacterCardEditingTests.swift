import Foundation
import Testing
import Assets
import Character

private enum EditingFixture {
    typealias F = OriginalCardFixture
    static func fields(_ pairs: [(String, F.Value)]) -> Data { F.pack(F.map(pairs)) }
    static func color(_ r: Double = 0.1) -> F.Value { .array([.float(r), .float(0.2), .float(0.3), .float(1)]) }
    static func card(sex: Int = 1) -> Data {
        let face = fields([("version", .string("0.0.2")), ("headId", .integer(0)), ("shapeValueFace", .array(F.faceValues)), ("eyebrowColor", color()), ("unknownFace", .ext(4, Data([8, 7, 6])))])
        let body = fields([("version", .string("0.0.2")), ("shapeValueBody", .array(F.bodyValues)), ("skinMainColor", color()), ("unknownBody", .binary(Data([0xc1])))])
        let hair = fields([("version", .string("0.0.4")), ("parts", .array([F.map([("id", .integer(8123)), ("baseColor", color())])]))])
        let clothes = fields([("version", .string("0.0.1")), ("parts", .array([F.map([("id", .integer(80001)), ("colorInfo", .array([F.map([("baseColor", color())])]))])]))])
        let accessory = fields([("version", .string("0.0.2")), ("parts", .array([F.map([("color", .array([color()]))])]))])
        let makeup = fields([("version", .string("0.0.0")), ("lipColor", color())])
        let coordinate = F.lengthData(clothes) + F.lengthData(accessory) + Data([1]) + F.lengthData(makeup)
        let custom = F.lengthData(face) + F.lengthData(body) + F.lengthData(hair)
        var blocks = F.blocks(custom: custom, sex: .integer(Int64(sex)))
        blocks.insert(.init(name: "Coordinate", version: "0.0.0", data: F.pack(.array([.binary(coordinate), .binary(coordinate)]))), at: 1)
        blocks.append(F.extended(F.map([("unknown.resolver", F.plugin(123, data: F.map([("opaque", .ext(9, Data([1, 2, 3])))])))])))
        // Deliberately reverse header order while retaining source payload order.
        return F.card(blocks: blocks, order: Array(blocks.indices.reversed()), png: F.png,
                      trailer: F.legacy(F.map([("legacyPlugin", F.plugin(4))]), suffix: Data([0xde, 0xad])))
    }
    static func colors() -> [SourceCharacterCard.ColorEdit] {
        let rgba: [Float] = [0.8, 0.4, 0.2, 0.9]
        return [
            .init(record: .face, path: [.key("eyebrowColor")], rgba: rgba),
            .init(record: .body, path: [.key("skinMainColor")], rgba: rgba),
            .init(record: .hair, path: [.key("parts"), .index(0), .key("baseColor")], rgba: rgba),
            .init(record: .clothes(coordinate: 1), path: [.key("parts"), .index(0), .key("colorInfo"), .index(0), .key("baseColor")], rgba: rgba),
            .init(record: .accessory(coordinate: 1), path: [.key("parts"), .index(0), .key("color"), .index(0)], rgba: rgba),
            .init(record: .makeup(coordinate: 1), path: [.key("lipColor")], rgba: rgba)
        ]
    }
    static func field(_ card: SourceCharacterCard, edit: SourceCharacterCard.ColorEdit) throws -> [Float] {
        var value = try SourceMessagePack.decode(card.recordData(edit.record))
        for path in edit.path {
            switch path {
            case .key(let name): value = try #require(value.stringKeyedMap()[name])
            case .index(let index): value = try #require(value.arrayValue)[index]
            }
        }
        return try #require(value.arrayValue).map { if case .float(let f) = $0 { return Float(f) }; throw SourceCharacterCardError.invalid("Expected numeric color.") }
    }
}

@Test func sourceCardEditingNoOpRetainsEveryOriginalToken() throws {
    for bytes in [OriginalCardFixture.card(), EditingFixture.card()] {
        let card = try SourceCharacterCard.decode(bytes), values = try card.customization()
        #expect(try card.editedData(.init()) == bytes)
        #expect(try card.editedData(.init(faceValues: values.faceValues, bodyValues: values.bodyValues)) == bytes)
    }
}

@Test func sourceCardEditingShapesPreserveUneditedRecordsAndLegacyPluginPrecedence() throws {
    let original = try SourceCharacterCard.decode(EditingFixture.card())
    var face = try original.customization().faceValues, body = try original.customization().bodyValues
    face[23] = 0.8125; body[42] = 0.125
    let result = try SourceCharacterCard.decode(original.editedData(.init(faceValues: face, bodyValues: body)))
    #expect(try result.customization().faceValues == face)
    #expect(try result.customization().bodyValues == body)
    #expect(try result.recordData(.hair) == original.recordData(.hair))
    #expect(try result.recordFields(.face)["unknownFace"] == original.recordFields(.face)["unknownFace"])
    #expect(try result.recordFields(.body)["unknownBody"] == original.recordFields(.body)["unknownBody"])
    for block in original.blocks where block.name != "Custom" { #expect(result.block(named: block.name)?.data == block.data) }
    #expect(result.thumbnailData == original.thumbnailData && result.faceThumbnailData == original.faceThumbnailData)
    #expect(result.trailingData == original.trailingData)
    #expect(try result.extensions().format == "trailer-v2")
    #expect(try result.extensions().plugins.keys.sorted() == ["legacyPlugin"])
    #expect(result.blocks.map(\.name) == original.blocks.map(\.name))
}

@Test func sourceCardEditingColorsRetainSelectedAssetsAndUntouchedCoordinates() throws {
    let original = try SourceCharacterCard.decode(EditingFixture.card()), edits = EditingFixture.colors()
    let result = try SourceCharacterCard.decode(original.editedData(.init(colors: edits)))
    for edit in edits { #expect(try EditingFixture.field(result, edit: edit) == edit.rgba) }
    for record: SourceCharacterCard.Record in [.clothes(coordinate: 0), .accessory(coordinate: 0), .makeup(coordinate: 0)] {
        #expect(try result.recordData(record) == original.recordData(record))
    }
    let hairPart = try #require(result.recordFields(.hair)["parts"]?.arrayValue?.first).stringKeyedMap()
    #expect(hairPart["id"]?.integerValue == 8123)
    #expect(result.block(named: "KKEx")?.data == original.block(named: "KKEx")?.data)
    #expect(try result.editedData(.init(colors: edits)) == result.preservedData)
}

@Test func sourceCardEditingMaleAndExtendedShapeRangesRemainValidSerialization() throws {
    let original = try SourceCharacterCard.decode(EditingFixture.card(sex: 0))
    var values = try original.customization().bodyValues
    values[0] = -0.25; values[1] = 1.75; values[43] = -0.0
    let result = try SourceCharacterCard.decode(original.editedData(.init(bodyValues: values)))
    #expect(try result.customization().sex == 0)
    #expect(try result.customization().bodyValues == values)
    #expect(try result.customization().bodyValues[43].bitPattern == Float(-0.0).bitPattern)
}

@Test func sourceCardEditingPNGReplacementRejectsAppendedCardAndCorruptCRC() throws {
    let original = try SourceCharacterCard.decode(EditingFixture.card())
    let changed = try SourceCharacterCard.decode(original.editedData(.init(thumbnailData: Data(), faceThumbnailData: OriginalCardFixture.png)))
    #expect(changed.thumbnailData.isEmpty && changed.faceThumbnailData == OriginalCardFixture.png)
    #expect(changed.blocks.map(\.data) == original.blocks.map(\.data))
    let reinserted = try SourceCharacterCard.decode(changed.editedData(.init(thumbnailData: OriginalCardFixture.png)))
    #expect(reinserted.thumbnailData == OriginalCardFixture.png)
    var corrupt = OriginalCardFixture.png; corrupt[29] ^= 1
    for png in [corrupt, OriginalCardFixture.png + Data([1]), EditingFixture.card(), Data([1, 2, 3])] {
        #expect(throws: (any Error).self) { try original.editedData(.init(thumbnailData: png)) }
        #expect(throws: (any Error).self) { try original.editedData(.init(faceThumbnailData: png)) }
    }
}

@Test func sourceCardEditingRejectsOverlappingMissingAndInvalidValues() throws {
    let original = try SourceCharacterCard.decode(EditingFixture.card())
    for values in [Array(repeating: Float(0.5), count: 51), Array(repeating: .nan, count: 52)] {
        #expect(throws: (any Error).self) { try original.editedData(.init(faceValues: values)) }
    }
    let valid = EditingFixture.colors()[0]
    #expect(throws: (any Error).self) { try original.editedData(.init(colors: [valid, valid])) }
    for edit in [SourceCharacterCard.ColorEdit(record: .body, path: [.key("missingColor")], rgba: [0, 0, 0, 1]),
                 .init(record: .body, path: [.key("shapeValueBody")], rgba: [0, 0, 0, 1]),
                 .init(record: .makeup(coordinate: 20), path: [.key("lipColor")], rgba: [0, 0, 0, 1]),
                 .init(record: .face, path: [.key("eyebrowColor")], rgba: [0, .infinity, 0, 1])] {
        #expect(throws: (any Error).self) { try original.editedData(.init(colors: [edit])) }
    }
}

@Test func sourceCardEditingRetainsPayloadGapsAndMovesFollowingOffsets() throws {
    let blocks = OriginalCardFixture.blocks(), prefix = Data([0xfa, 0xfb]), gap = Data([0xde, 0xad, 0xbe])
    let positions: [Int64] = [2, Int64(2 + blocks[0].data.count + gap.count), Int64(2 + blocks[0].data.count + gap.count + blocks[1].data.count)]
    let payload = prefix + blocks[0].data + gap + blocks[1].data + blocks[2].data + Data([0xf0])
    let card = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: blocks, positions: positions, payload: payload))
    var face = try card.customization().faceValues; face[0] = 0.23
    let bytes = try card.editedData(.init(faceValues: face)), result = try SourceCharacterCard.decode(bytes)
    let custom = try #require(result.block(named: "Custom")), parameter = try #require(result.block(named: "Parameter"))
    #expect(custom.position == 2)
    #expect(parameter.position == custom.position + custom.data.count + gap.count)
    let payloadStart = bytes.count - result.payloadSize
    #expect(bytes.subdata(in: payloadStart..<(payloadStart + 2)) == prefix)
    #expect(bytes.subdata(in: (payloadStart + custom.position + custom.data.count)..<(payloadStart + parameter.position)) == gap)
    #expect(bytes.last == 0xf0)
}

@Test func sourceCardEditingRejectsGappedExtendedSaveAndAmbiguousEmptyOffsets() throws {
    var blocks = OriginalCardFixture.blocks()
    blocks.append(OriginalCardFixture.extended(OriginalCardFixture.map([])))
    let sizes = blocks.map { $0.data.count }, positions = [0, sizes[0], sizes[0] + sizes[1], sizes[0] + sizes[1] + sizes[2]]
    let raw = blocks.reduce(into: Data()) { $0 += $1.data } + Data([0])
    let card = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: blocks, positions: positions.map(Int64.init), payload: raw))
    #expect(try card.editedData(.init()) == card.preservedData)
    var face = try card.customization().faceValues; face[0] = 0.33
    #expect(throws: (any Error).self) { try card.editedData(.init(faceValues: face)) }
    var empty = OriginalCardFixture.blocks(); empty.append(.init(name: "Empty", version: "0", data: Data()))
    let emptyCard = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: empty, positions: [0, Int64(empty[0].data.count), Int64(empty[0].data.count + empty[1].data.count), 10]))
    #expect(throws: (any Error).self) { try emptyCard.editedData(.init(faceValues: face)) }
}

@Test func sourceCardEditingKeepsOpaqueHairWhenOnlyShapesChange() throws {
    let card = try SourceCharacterCard.decode(OriginalCardFixture.card())
    var body = try card.customization().bodyValues; body[32] = 0.72
    let next = try SourceCharacterCard.decode(card.editedData(.init(bodyValues: body)))
    #expect(try next.customization().bodyValues == body)
    #expect(throws: (any Error).self) { try next.recordData(.hair) }
}

@Test func sourceCardEditingRejectsDuplicatePathMapAndUnsupportedVersion() throws {
    let face = OriginalCardFixture.pack(.map([
        .init(key: .string("version"), value: .string("0.0.2")),
        .init(key: .string("headId"), value: .integer(0)),
        .init(key: .string("shapeValueFace"), value: .array(OriginalCardFixture.faceValues)),
        .init(key: .string("color"), value: EditingFixture.color()),
        .init(key: .string("color"), value: EditingFixture.color())]))
    let original = try SourceCharacterCard.decode(EditingFixture.card())
    let custom = OriginalCardFixture.lengthData(face) + OriginalCardFixture.lengthData(try original.recordData(.body)) + OriginalCardFixture.lengthData(try original.recordData(.hair))
    let duplicate = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(custom: custom)))
    #expect(throws: (any Error).self) { try duplicate.editedData(.init(colors: [.init(record: .face, path: [.key("color")], rgba: [1, 0, 0, 1])])) }
    #expect(throws: (any Error).self) { try original.recordData(.clothes(coordinate: -1)) }
}

// Optional evidence writer, not a fixture test.
@Test(.enabled(if: (ProcessInfo.processInfo.environment["IKKOKU_CARD_EDIT_OUTPUT"] ?? "").isEmpty == false,
               "Writes independent-oracle evidence only when IKKOKU_CARD_EDIT_OUTPUT is set"))
func sourceCardEditingWritesIndependentOracleEvidence() throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["IKKOKU_CARD_EDIT_OUTPUT"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = EditingFixture.card(sex: 0), card = try SourceCharacterCard.decode(source)
    var face = try card.customization().faceValues, body = try card.customization().bodyValues
    face[9] = 0.0625; body[0] = -0.25; body[32] = 0.8125
    let result = try card.editedData(.init(faceValues: face, bodyValues: body, colors: EditingFixture.colors(), faceThumbnailData: OriginalCardFixture.png))
    try source.write(to: directory.appendingPathComponent("source.png"))
    try result.write(to: directory.appendingPathComponent("edited.png"))
    try JSONSerialization.data(withJSONObject: ["faceValues": face, "bodyValues": body, "rgba": EditingFixture.colors()[0].rgba], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("edits.json"))
}


@Test func sourceCardEditingPreservesSpecialAssemblyTypeWhilePreviewRejectsIt() throws {
    typealias F = OriginalCardFixture
    let base = try SourceCharacterCard.decode(F.card(blocks: F.blocks(sex: .integer(0))))
    #expect(try base.customization().exType == 0)
    for exType: F.Value in [.integer(1), .integer(-1)] {
        var blocks = F.blocks(sex: .integer(0))
        blocks[1].data = F.pack(F.map([("version", .string("0.0.5")), ("sex", .integer(0)), ("exType", exType)]))
        let card = try SourceCharacterCard.decode(F.card(blocks: blocks))
        #expect(try card.customization().exType == exType.integerValue)
        #expect(throws: SourceCharacterCardError.self) { try card.previewSettings(contract: F.contract(), sex: 0) }
        var values = try card.customization().bodyValues; values[0] = 0.3
        let edited = try SourceCharacterCard.decode(card.editedData(.init(bodyValues: values)))
        #expect(edited.block(named: "Parameter")?.data == card.block(named: "Parameter")?.data)
    }
    for exType: F.Value in [.null, .float(0), .string("0"), .integer(Int64(Int32.max) + 1)] {
        var blocks = F.blocks()
        blocks[1].data = F.pack(F.map([("version", .string("0.0.5")), ("sex", .integer(1)), ("exType", exType)]))
        let card = try SourceCharacterCard.decode(F.card(blocks: blocks))
        #expect(throws: SourceCharacterCardError.self) { try card.customization() }
        #expect(try card.editedData(.init()) == card.preservedData)
    }
}

/// An EditingFixture-shaped card with three saved outfits and a Status block
/// whose integers use the fixture's int64 encoding (so a changed outfit also
/// resizes the block), a stale backCoordinateType and an unknown extension.
/// `status` replaces the Status block's bytes.
func outfitCard(coordinateType: Int64 = 1, back: Int64 = 2, statusVersion: String = "0.0.0", png: Data = OriginalCardFixture.png, trailer: Data? = nil,
                status statusData: Data? = nil) throws -> Data {
    typealias F = OriginalCardFixture
    let base = try SourceCharacterCard.decode(EditingFixture.card())
    let coordinates = try #require(base.block(named: "Coordinate"))
    let entry = try #require(SourceMessagePack.decode(coordinates.data).arrayValue?.first?.binaryValue)
    let status = EditingFixture.fields([("version", .string("0.0.0")), ("coordinateType", .integer(coordinateType)),
        ("backCoordinateType", .integer(back)), ("clothesState", .binary(Data([0, 1, 2, 3, 0, 0, 0, 0, 0]))),
        ("showAccessory", .array(Array(repeating: .bool(true), count: 20))), ("unknownStatus", .ext(5, Data([4, 5, 6])))])
    var blocks = base.blocks.map { F.Block(name: $0.name, version: $0.version, data: $0.data) }
    blocks.sort { (base.block(named: $0.name)?.position ?? 0) < (base.block(named: $1.name)?.position ?? 0) }
    let index = try #require(blocks.firstIndex { $0.name == "Coordinate" })
    blocks[index].data = F.pack(.array(Array(repeating: .binary(entry), count: 3)))
    // Status sits before the plug-in block, so a resize moves its offsets.
    let plugins = try #require(blocks.firstIndex { $0.name == "KKEx" })
    blocks.insert(.init(name: "Status", version: statusVersion, data: statusData ?? status), at: plugins)
    return F.card(blocks: blocks, png: png, trailer: trailer ?? base.trailingData)
}

@Test func sourceCardEditingOutfitWritesOnlyStatusCoordinateAndBackType() throws {
    let bytes = try outfitCard(), original = try SourceCharacterCard.decode(bytes)
    #expect(try original.savedCoordinateType() == 1 && original.coordinateCount() == 3)
    // Selecting the saved outfit is a no-op: every byte, including the
    // non-compact integer encoding, survives.
    #expect(try original.editedData(.init(coordinateType: 1)) == bytes)
    let edited = try SourceCharacterCard.decode(original.editedData(.init(coordinateType: 0)))
    #expect(try edited.savedCoordinateType() == 0)
    let originalStatus = try #require(original.block(named: "Status")), editedStatus = try #require(edited.block(named: "Status"))
    let before = try SourceMessagePack.decode(originalStatus.data).stringKeyedMap()
    let after = try SourceMessagePack.decode(editedStatus.data).stringKeyedMap()
    // ChangeCoordinateType(type, changeBackCoordinateType: true) keeps the
    // outfit that was worn (the saved one) as backCoordinateType.
    #expect(after["coordinateType"]?.integerValue == 0 && after["backCoordinateType"]?.integerValue == 1)
    #expect(after.filter { !["coordinateType", "backCoordinateType"].contains($0.key) } == before.filter { !["coordinateType", "backCoordinateType"].contains($0.key) })
    // The two changed int64 tokens became one-byte fixints.
    #expect(editedStatus.data.count == originalStatus.data.count - 16)
    // No Coordinate record, Custom record, plug-in block, legacy trailer or
    // thumbnail moved; only the following block's offset changed.
    for block in original.blocks where block.name != "Status" {
        #expect(edited.block(named: block.name)?.data == block.data, Comment(rawValue: block.name))
    }
    #expect(edited.trailingData == original.trailingData && edited.thumbnailData == original.thumbnailData && edited.faceThumbnailData == original.faceThumbnailData)
    #expect(try edited.extensions().plugins.keys.sorted() == original.extensions().plugins.keys.sorted())
    #expect(try edited.recordData(.clothes(coordinate: 2)) == original.recordData(.clothes(coordinate: 2)))
    // Combined with a shape edit in one Edits, both land.
    var face = try original.customization().faceValues; face[5] = 0.625
    let combined = try SourceCharacterCard.decode(original.editedData(.init(faceValues: face, coordinateType: 2)))
    #expect(try combined.savedCoordinateType() == 2 && combined.customization().faceValues == face)
    // An already-current back value is not rewritten: only coordinateType moves.
    let aligned = try SourceCharacterCard.decode(outfitCard(coordinateType: 1, back: 1))
    let onlyType = try SourceCharacterCard.decode(aligned.editedData(.init(coordinateType: 2)))
    let alignedStatus = try #require(aligned.block(named: "Status")), onlyTypeStatus = try #require(onlyType.block(named: "Status"))
    #expect(onlyTypeStatus.data.count == alignedStatus.data.count - 8)
    #expect(try SourceMessagePack.decode(onlyTypeStatus.data).stringKeyedMap()["backCoordinateType"]?.integerValue == 1)
}

@Test func sourceCardEditingOutfitRejectsInvalidMissingAndUnsupportedSelections() throws {
    let original = try SourceCharacterCard.decode(outfitCard())
    // Outside CoordinateType, or not one of the card's saved outfits.
    for index in [-1, 7, 3, 6] {
        #expect(throws: (any Error).self, Comment(rawValue: "\(index)")) { try original.editedData(.init(coordinateType: index)) }
    }
    // A newer Status block version is not edited, and a card without a
    // Status block keeps its implicit outfit 0 but cannot select another.
    let newer = try SourceCharacterCard.decode(outfitCard(statusVersion: "0.0.1"))
    #expect(throws: (any Error).self) { try newer.editedData(.init(coordinateType: 0)) }
    let statusless = try SourceCharacterCard.decode(EditingFixture.card())
    #expect(try statusless.savedCoordinateType() == 0)
    #expect(try statusless.editedData(.init(coordinateType: 0)) == statusless.preservedData)
    #expect(throws: (any Error).self) { try statusless.editedData(.init(coordinateType: 1)) }
}

/// Compact MessagePack-CSharp spellings (fixmap / fixstr / fixint) for Status
/// blocks the wide-token fixture packer cannot express.
private func compactStatus(_ pairs: [(String, Data)]) -> Data {
    pairs.reduce(into: Data([0x80 | UInt8(pairs.count)])) { result, pair in
        result += Data([0xa0 | UInt8(pair.0.utf8.count)]) + Data(pair.0.utf8) + pair.1
    }
}
private let compactVersion = Data([0xa5]) + Data("0.0.0".utf8)

private func differingOffsets(_ a: Data, _ b: Data) -> [Int] {
    precondition(a.count == b.count)
    return a.indices.filter { a[$0] != b[$0] }
}

@Test func sourceCardEditingClothesStateAndAccessoryFlagsPatchOnlyTheirTokens() throws {
    let bytes = try outfitCard(), original = try SourceCharacterCard.decode(bytes)
    let saved = try original.savedStatusWear()
    #expect(saved.clothesState == [0, 1, 2, 3, 0, 0, 0, 0, 0] && saved.shoesType == 0 && saved.showAccessory == Array(repeating: true, count: 20))
    // Requesting the saved values (alone or together) changes no byte.
    #expect(try original.editedData(.init(clothesState: saved.clothesState)) == bytes)
    #expect(try original.editedData(.init(clothesState: saved.clothesState, showAccessory: saved.showAccessory)) == bytes)
    #expect(try original.editedData(.init(coordinateType: 1, clothesState: saved.clothesState, showAccessory: saved.showAccessory)) == bytes)

    let clothes: [UInt8] = [3, 1, 2, 0, 3, 0, 0, 3, 3]
    var flags = saved.showAccessory; flags[0] = false; flags[19] = false
    let edited = try SourceCharacterCard.decode(original.editedData(.init(clothesState: clothes, showAccessory: flags)))
    let reread = try edited.savedStatusWear()
    #expect(reread.clothesState == clothes && reread.showAccessory == flags && reread.shoesType == 0)
    #expect(try edited.savedCoordinateType() == 1)
    // The bin payload and two bool tokens are patched in place: same block
    // length, and only the changed values' bytes differ.
    let before = try #require(original.block(named: "Status")).data, after = try #require(edited.block(named: "Status")).data
    #expect(after.count == before.count)
    let changed = differingOffsets(before, after)
    // top 0->3, shorts 3->0, gloves 0->3, both shoes 0->3, and two flags.
    #expect(changed.count == 7)
    let decodedBefore = try SourceMessagePack.decode(before).stringKeyedMap(), decodedAfter = try SourceMessagePack.decode(after).stringKeyedMap()
    #expect(decodedAfter.filter { !["clothesState", "showAccessory"].contains($0.key) } == decodedBefore.filter { !["clothesState", "showAccessory"].contains($0.key) })
    for block in original.blocks where block.name != "Status" {
        #expect(edited.block(named: block.name)?.data == block.data, Comment(rawValue: block.name))
    }
    #expect(edited.trailingData == original.trailingData && edited.thumbnailData == original.thumbnailData)
    // Writing the saved values back restores the original bytes exactly.
    #expect(try edited.editedData(.init(clothesState: saved.clothesState, showAccessory: saved.showAccessory)) == bytes)
    // One field at a time leaves the other as saved.
    let onlyFlags = try SourceCharacterCard.decode(original.editedData(.init(showAccessory: flags)))
    #expect(try onlyFlags.savedStatusWear().clothesState == saved.clothesState && onlyFlags.savedStatusWear().showAccessory == flags)
    // Combined with an outfit change, all three fields land.
    let combined = try SourceCharacterCard.decode(original.editedData(.init(coordinateType: 0, clothesState: clothes)))
    #expect(try combined.savedCoordinateType() == 0 && combined.savedStatusWear().clothesState == clothes)
}

@Test func sourceCardEditingWearRejectsInvalidValuesAndUnreadableFields() throws {
    let original = try SourceCharacterCard.decode(outfitCard())
    for clothes: [UInt8] in [[0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], [4, 0, 0, 0, 0, 0, 0, 0, 0]] {
        #expect(throws: (any Error).self, Comment(rawValue: "\(clothes)")) { try original.editedData(.init(clothesState: clothes)) }
    }
    for count in [0, 19, 21] {
        #expect(throws: (any Error).self, Comment(rawValue: "\(count)")) { try original.editedData(.init(showAccessory: Array(repeating: false, count: count))) }
    }
    // A newer Status version is never edited.
    let newer = try SourceCharacterCard.decode(outfitCard(statusVersion: "0.0.1"))
    #expect(throws: (any Error).self) { try newer.editedData(.init(clothesState: [3, 3, 3, 3, 3, 3, 3, 3, 3])) }
    // Without a Status block the MemberInit defaults are kept (no-op) but
    // nothing else can be written.
    let statusless = try SourceCharacterCard.decode(EditingFixture.card())
    #expect(try statusless.savedStatusWear() == .memberInit)
    #expect(try statusless.editedData(.init(clothesState: Array(repeating: 0, count: 9), showAccessory: Array(repeating: true, count: 20))) == statusless.preservedData)
    #expect(throws: (any Error).self) { try statusless.editedData(.init(clothesState: [3, 0, 0, 0, 0, 0, 0, 0, 0])) }
    #expect(throws: (any Error).self) { try statusless.editedData(.init(showAccessory: [false] + Array(repeating: true, count: 19))) }
    // Wrongly shaped saved fields are reported, never guessed or rewritten.
    typealias F = OriginalCardFixture
    let shapes: [(String, F.Value)] = [
        ("clothesState", .binary(Data([0, 0, 0]))), ("clothesState", .binary(Data([0, 0, 0, 0, 9, 0, 0, 0, 0]))),
        ("clothesState", .string("000000000")), ("showAccessory", .array(Array(repeating: .bool(true), count: 19))),
        ("showAccessory", .array([.integer(1)] + Array(repeating: .bool(true), count: 19))), ("shoesType", .string("1")),
    ]
    for (key, value) in shapes {
        let status = F.pack(F.map([("version", .string("0.0.0")), ("coordinateType", .integer(1)), (key, value)]))
        let card = try SourceCharacterCard.decode(outfitCard(status: status))
        #expect(throws: (any Error).self, Comment(rawValue: key)) { try card.savedStatusWear() }
        #expect(throws: (any Error).self, Comment(rawValue: key)) { try card.editedData(.init(clothesState: [3, 3, 3, 3, 3, 3, 3, 3, 3])) }
    }
}

@Test func sourceCardEditingWearReadsArraySpellingAndAppendsMissingFields() throws {
    // The synthetic Studio fixture's spelling: a fixmap whose clothesState
    // is an array of nine fixints and which saves no showAccessory.
    let clothesArray = Data([0x99, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    let status = compactStatus([("version", compactVersion), ("coordinateType", Data([0x01])), ("clothesState", clothesArray)])
    let bytes = try outfitCard(status: status), original = try SourceCharacterCard.decode(bytes)
    let saved = try original.savedStatusWear()
    #expect(saved.clothesState == Array(repeating: 0, count: 9) && saved.showAccessory == Array(repeating: true, count: 20))
    #expect(try original.editedData(.init(clothesState: saved.clothesState, showAccessory: saved.showAccessory)) == bytes)

    // Array members are patched as fixints in place.
    let clothes: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 1, 1]
    let edited = try SourceCharacterCard.decode(original.editedData(.init(clothesState: clothes)))
    let after = try #require(edited.block(named: "Status")).data
    #expect(after.count == status.count && differingOffsets(status, after).count == 3)
    #expect(try edited.savedStatusWear().clothesState == clothes)
    #expect(try edited.editedData(.init(clothesState: saved.clothesState)) == bytes)

    // A missing showAccessory is appended in MessagePack-CSharp's form; only
    // the map header changes among the existing bytes.
    var flags = saved.showAccessory; flags[0] = false
    let appended = try SourceCharacterCard.decode(original.editedData(.init(showAccessory: flags)))
    let grown = try #require(appended.block(named: "Status")).data
    let tail = Data([0xad]) + Data("showAccessory".utf8) + Data([0xdc, 0x00, 0x14, 0xc2]) + Data(repeating: 0xc3, count: 19)
    #expect(grown == Data([0x84]) + status.dropFirst() + tail)
    #expect(try appended.savedStatusWear().showAccessory == flags && appended.savedStatusWear().clothesState == saved.clothesState)
    for block in original.blocks where block.name != "Status" {
        #expect(appended.block(named: block.name)?.data == block.data, Comment(rawValue: block.name))
    }

    // A map32 Status without either field grows its 4-byte count and
    // appends the bin form; a fixmap of 15 entries becomes a map16.
    typealias F = OriginalCardFixture
    let wide = F.pack(F.map([("version", .string("0.0.0")), ("coordinateType", .integer(1))]))
    let wideCard = try SourceCharacterCard.decode(outfitCard(status: wide))
    let wideEdited = try #require(SourceCharacterCard.decode(wideCard.editedData(.init(clothesState: clothes))).block(named: "Status")).data
    var wideExpected = Data([0xdf, 0, 0, 0, 3]) + wide.dropFirst(5)
    wideExpected += Data([0xac]) + Data("clothesState".utf8)
    wideExpected += Data([0xc4, 0x09]) + Data(clothes)
    #expect(wideEdited == wideExpected)
    let fifteen = compactStatus([("version", compactVersion), ("coordinateType", Data([0x01]))] + (0..<13).map { ("k\($0)", Data([0x00])) })
    let fullCard = try SourceCharacterCard.decode(outfitCard(status: fifteen))
    let fullEdited = try SourceCharacterCard.decode(fullCard.editedData(.init(clothesState: clothes, showAccessory: flags)))
    let fullData = try #require(fullEdited.block(named: "Status")).data
    #expect(fullData.prefix(3) == Data([0xde, 0x00, 0x11]) && fullData.dropFirst(3).prefix(fifteen.count - 1) == fifteen.dropFirst())
    #expect(try fullEdited.savedStatusWear().clothesState == clothes && fullEdited.savedStatusWear().showAccessory == flags)
    // A non-fixint array member is not rewritten.
    let int64Zero: [UInt8] = [0xd3, 0, 0, 0, 0, 0, 0, 0, 0]
    let members: [UInt8] = [0x99] + int64Zero + [UInt8](repeating: 0, count: 8)
    let wideArray = compactStatus([("version", compactVersion), ("clothesState", Data(members))])
    let wideArrayCard = try SourceCharacterCard.decode(outfitCard(status: wideArray))
    #expect(try wideArrayCard.savedStatusWear().clothesState == Array(repeating: 0, count: 9))
    #expect(throws: (any Error).self) { try wideArrayCard.editedData(.init(clothesState: clothes)) }
}
