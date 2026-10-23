import Foundation
import Testing
import Assets
import Character

private enum SelectionFixture {
    typealias F = OriginalCardFixture
    typealias V = SourceMessagePackValue
    static let target = "ChaFileHair.HairBack"
    static func resolver(_ property: String, id: Int64 = 99) -> Data {
        F.pack(F.map([("Property", .string(property)), ("Slot", .integer(id)),
            ("ModID", .string("fixture.mod")), ("CategoryNo", .integer(101)), ("LocalSlot", .integer(2)),
            ("Unknown", .ext(17, Data([9, 2, 1])))]))
    }
    static func plugins(_ records: [Data]) -> V {
        F.map(SourceCardModReferences.pluginIDs.map { marker in
            (marker, F.plugin(42, data: F.map([("info", .array(records.map(V.binary))),
                ("other", .ext(3, Data([6, 7])))])))
        } + [("unknown.plugin", F.plugin(23, data: F.map([("opaque", .binary(Data([0xc1, 0xff])))])))])
    }
    static func card(records: [Data]? = nil, legacy: Bool = false, badID: V? = nil) throws -> SourceCharacterCard {
        let face = F.pack(F.map([("version", .string("0.0.2")), ("headId", .integer(0)), ("shapeValueFace", .array(F.faceValues))]))
        let body = F.pack(F.map([("version", .string("0.0.2")), ("shapeValueBody", .array(F.bodyValues))]))
        let hair = F.pack(F.map([("version", .string("0.0.4")), ("parts", .array((0..<4).map { _ in
            F.map([("id", badID ?? .integer(2)), ("untouched", .ext(5, Data([8, 9])))])
        }))]))
        let clothes = F.pack(F.map([("version", .string("0.0.1")), ("parts", .array((0..<9).map { _ in F.map([("id", .integer(3))]) }))]))
        let accessory = F.pack(F.map([("version", .string("0.0.2")), ("parts", .array([]))]))
        let makeup = F.pack(F.map([("version", .string("0.0.0")), ("unknown", .ext(9, Data([9])))]))
        let outfit = F.lengthData(clothes) + F.lengthData(accessory) + Data([0]) + F.lengthData(makeup)
        var blocks = F.blocks(custom: F.lengthData(face) + F.lengthData(body) + F.lengthData(hair))
        blocks.append(.init(name: "Coordinate", version: "0.0.0", data: F.pack(.array(Array(repeating: .binary(outfit), count: 7)))))
        if let records { blocks.append(F.extended(plugins(records))) }
        return try SourceCharacterCard.decode(F.card(blocks: blocks, order: Array(blocks.indices.reversed()), png: F.png,
            trailer: legacy ? F.legacy(plugins(records ?? []), suffix: Data([0xde, 0xad])) : Data([0xfe, 0xed])))
    }
    static func id(_ card: SourceCharacterCard, at slot: SourceMakerSelectionSlot) throws -> Int? {
        let destination = try slot.destination()
        return try card.recordFields(destination.record)["parts"]?.arrayValue?[destination.slot].stringKeyedMap()["id"]?.integerValue
    }
    static func records(_ block: Data, marker: String) throws -> [Data] {
        let fields = try SourceMessagePack.decode(block).stringKeyedMap()
        let plugin = try #require(fields[marker]?.arrayValue)
        return try #require(plugin[1].stringKeyedMap()["info"]?.arrayValue).map { try #require($0.binaryValue) }
    }
}

@Test func sourceCardSelectionNoOpPreservesEveryByte() throws {
    let card = try SelectionFixture.card()
    #expect(try card.selectingVanillaAsset(2, at: .hair(0)) == card.preservedData)
    #expect(try card.selectingVanillaAsset(3, at: .clothes(coordinate: 6, slot: 8)) == card.preservedData)
}

@Test func sourceCardSelectionEditsOnlyHairOrSelectedOutfit() throws {
    let card = try SelectionFixture.card()
    let hair = try SourceCharacterCard.decode(card.selectingVanillaAsset(9, at: .hair(1)))
    #expect(try SelectionFixture.id(hair, at: .hair(1)) == 9)
    #expect(try hair.recordData(.face) == card.recordData(.face))
    #expect(try hair.recordData(.body) == card.recordData(.body))
    for block in card.blocks where block.name != "Custom" { #expect(hair.block(named: block.name)?.data == block.data) }
    let clothes = try SourceCharacterCard.decode(hair.selectingVanillaAsset(38, at: .clothes(coordinate: 4, slot: 0)))
    #expect(try SelectionFixture.id(clothes, at: .clothes(coordinate: 4, slot: 0)) == 38)
    #expect(try SelectionFixture.id(clothes, at: .hair(1)) == 9)
    for outfit in 0..<7 {
        if outfit != 4 { #expect(try clothes.recordData(.clothes(coordinate: outfit)) == card.recordData(.clothes(coordinate: outfit))) }
        #expect(try clothes.recordData(.accessory(coordinate: outfit)) == card.recordData(.accessory(coordinate: outfit)))
        #expect(try clothes.recordData(.makeup(coordinate: outfit)) == card.recordData(.makeup(coordinate: outfit)))
    }
    #expect(clothes.trailingData == card.trailingData)
    #expect(clothes.thumbnailData == card.thumbnailData && clothes.faceThumbnailData == card.faceThumbnailData)
    #expect(try clothes.selectingVanillaAsset(38, at: .clothes(coordinate: 4, slot: 0)) == clothes.preservedData)
}

@Test func sourceCardSelectionRemovesExactResolverDestinationFromBothMarkersAndFormats() throws {
    typealias F = SelectionFixture
    let retained = [F.resolver(F.target + " "), F.resolver("chafilehair.HairBack"),
        F.resolver("outfit1.ChaFileClothes.ClothesTop"), F.resolver("unrelated.é"), F.resolver("unrelated.e\u{301}")]
    let original = [F.resolver(F.target)] + retained + [F.resolver(F.target, id: 7)]
    for legacy in [false, true] {
        let card = try F.card(records: original, legacy: legacy)
        // Equal numeric ID still changes identity: the UAR record takes precedence.
        let edited = try SourceCharacterCard.decode(card.selectingVanillaAsset(2, at: .hair(0)))
        #expect(edited.preservedData != card.preservedData)
        #expect(try edited.recordData(.hair) == card.recordData(.hair))
        for marker in SourceCardModReferences.pluginIDs {
            let block = try #require(edited.block(named: "KKEx"))
            #expect(try F.records(block.data, marker: marker) == retained)
            let values = try SourceMessagePack.decode(block.data).stringKeyedMap()
            let before = try SourceMessagePack.decode(#require(card.block(named: "KKEx")).data).stringKeyedMap()
            #expect(values["unknown.plugin"] == before["unknown.plugin"])
        }
        #expect(try edited.modReferences()?.records.map(\.preservedData) == retained)
        if legacy { #expect(edited.trailingData.suffix(2) == Data([0xde, 0xad])) }
        else { #expect(edited.trailingData == card.trailingData) }
        for block in card.blocks where block.name != "KKEx" { #expect(edited.block(named: block.name)?.data == block.data) }
        #expect(try edited.selectingVanillaAsset(2, at: .hair(0)) == edited.preservedData)
        if let path = ProcessInfo.processInfo.environment["IKKOKU_CARD_EDIT_OUTPUT"], !path.isEmpty {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = legacy ? "selection-legacy" : "selection-block"
            try card.preservedData.write(to: directory.appendingPathComponent(name + "-source.png"))
            try edited.preservedData.write(to: directory.appendingPathComponent(name + "-edited.png"))
        }
    }
}

@Test func sourceCardSelectionRejectsMalformedOrUnsupportedRequests() throws {
    let card = try SelectionFixture.card()
    for slot: SourceMakerSelectionSlot in [.hair(-1), .hair(4), .clothes(coordinate: 7, slot: 0),
        .clothes(coordinate: 0, slot: 7), .clothes(coordinate: 0, slot: 9)] {
        #expect(throws: (any Error).self) { try card.selectingVanillaAsset(1, at: slot) }
    }
    for id in [-1, Int(Int32.max) + 1] { #expect(throws: (any Error).self) { try card.selectingVanillaAsset(id, at: .hair(0)) } }
    let invalid = try SelectionFixture.card(badID: .string("2"))
    #expect(throws: (any Error).self) { try invalid.selectingVanillaAsset(9, at: .hair(0)) }
    let malformed = try SelectionFixture.card(records: [Data([0xc1])])
    #expect(throws: (any Error).self) { try malformed.selectingVanillaAsset(9, at: .hair(0)) }
    #expect(try SelectionFixture.id(card, at: .hair(0)) == 2)
}

@Test func sourceCardSelectionRetainsEmptyResolverContainersAndValidatesShadowedData() throws {
    typealias F = SelectionFixture
    let card = try F.card(records: [F.resolver(F.target), F.resolver(F.target)], legacy: true)
    let edited = try SourceCharacterCard.decode(card.selectingVanillaAsset(2, at: .hair(0)))
    for marker in SourceCardModReferences.pluginIDs {
        #expect(try F.records(#require(edited.block(named: "KKEx")).data, marker: marker).isEmpty)
    }
    #expect(try edited.modReferences()?.records.isEmpty == true)
    try edited.validateMakerSelectionMetadata()
    // A valid preferred marker cannot make a malformed shadowed marker safe
    // to edit; the UI must disable replacement before showing a vanilla ID.
    typealias B = OriginalCardFixture
    let plugins = B.map([(SourceCardModReferences.pluginIDs[0], B.plugin(0, data: B.map([("info", .array([]))]))),
        (SourceCardModReferences.pluginIDs[1], B.plugin(0, data: B.map([("info", .array([.binary(Data([0xc1]))]))])) )])
    let blocks = card.blocks.filter { $0.name != "KKEx" }.map { B.Block(name: $0.name, version: $0.version, data: $0.data) } + [B.extended(plugins)]
    let malformed = try SourceCharacterCard.decode(B.card(blocks: blocks))
    #expect(try malformed.modReferences()?.records.isEmpty == true)
    #expect(throws: (any Error).self) { try malformed.validateMakerSelectionMetadata() }
    #expect(throws: (any Error).self) { try malformed.selectingVanillaAsset(2, at: .hair(0)) }
}

@Test func sourceCardSelectionRejectsAmbiguousExtendedSaveOffsetsEvenForSameID() throws {
    typealias F = OriginalCardFixture
    let card = try SelectionFixture.card(records: [])
    let blocks = card.blocks.map { F.Block(name: $0.name, version: $0.version, data: $0.data) }
    var cursor: Int64 = 1
    let positions = blocks.map { block in defer { cursor += Int64(block.data.count) }; return cursor }
    let payload = blocks.reduce(into: Data([0])) { $0 += $1.data }
    let gapped = try SourceCharacterCard.decode(F.card(blocks: blocks, positions: positions, payload: payload))
    #expect(throws: (any Error).self) { try gapped.validateMakerSelectionMetadata() }
    #expect(throws: (any Error).self) { try gapped.selectingVanillaAsset(2, at: .hair(0)) }
    #expect(throws: (any Error).self) { try gapped.selectingVanillaAsset(9, at: .hair(0)) }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]), "Requires IKKOKU_MAKER_SELECTION_FIXTURES"))
func sourceCardSelectionLoadsConvertedFixtureAndKeepsUnrelatedIdentity() throws {
    struct Fixtures: Decodable {
        struct Sample: Decodable { let file: String }
        let library: String, femaleBase: String, fixtures: [Sample]
    }
    let url = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_SELECTION_FIXTURES"))
    let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    #expect(!fixtures.fixtures.isEmpty)
    var preparedAssembly = false
    for sample in fixtures.fixtures {
        let original = try SourceCharacterCard.load(url: url.deletingLastPathComponent().appendingPathComponent(sample.file))
        let hair = try SourceCharacterCard.decode(original.selectingVanillaAsset(5, at: .hair(1)))
        let edited = try SourceCharacterCard.decode(hair.selectingVanillaAsset(38, at: .clothes(coordinate: 1, slot: 0)))
        #expect(try SelectionFixture.id(edited, at: .hair(1)) == 5)
        #expect(try SelectionFixture.id(edited, at: .clothes(coordinate: 1, slot: 0)) == 38)
        #expect(try edited.recordData(.face) == original.recordData(.face))
        #expect(try edited.recordData(.body) == original.recordData(.body))
        for index in 0..<7 where index != 1 {
            #expect(try edited.recordData(.clothes(coordinate: index)) == original.recordData(.clothes(coordinate: index)))
        }
        for block in original.blocks where !["Custom", "Coordinate"].contains(block.name) {
            #expect(edited.block(named: block.name)?.data == block.data)
        }
        if sample.file == "female-head0-bone0.png" {
            let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: fixtures.library))
            let prepared = try library.prepare(card: edited, coordinate: 1, baseURL: URL(fileURLWithPath: fixtures.femaleBase))
            preparedAssembly = true
            for property in ["ChaFileHair.HairFront", "outfit1.ChaFileClothes.ClothesTop"] {
                let selection = try #require(prepared.selections.first { $0.property == property })
                #expect(selection.status == "converted" && selection.modGUID == nil)
            }
        }
    }
    #expect(preparedAssembly)
}
