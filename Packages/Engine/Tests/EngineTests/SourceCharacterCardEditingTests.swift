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

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_CARD_EDIT_OUTPUT"]),
               "Requires IKKOKU_CARD_EDIT_OUTPUT"))
func sourceCardEditingWritesIndependentOracleEvidence() throws {
    let directory = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_CARD_EDIT_OUTPUT"))
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
