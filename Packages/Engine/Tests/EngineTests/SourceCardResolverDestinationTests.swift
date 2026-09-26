import Foundation
import Testing
import Assets
import Character

private enum ResolverDestinationFixture {
    typealias F = OriginalCardFixture
    typealias V = SourceMessagePackValue

    static func record(_ version: String, _ fields: [(String, V)]) -> V {
        F.map([("version", .string(version))] + fields)
    }
    static func custom(face: V? = nil, body: V? = nil, hair: Data? = nil) -> Data {
        F.lengthData(F.pack(face ?? record("0.0.2", [("headId", .integer(0)),
            ("pupil", .array([F.map([("id", .integer(23)), ("gradMaskId", .integer(31))]),
                              F.map([("id", .integer(24)), ("gradMaskId", .integer(32))])])),
            ("baseMakeup", record("0.0.0", [("lipId", .integer(48)), ("paintId", .array([.integer(9), .integer(10)]))]))])))
        + F.lengthData(F.pack(body ?? record("0.0.2", [("detailId", .integer(73)),
            ("paintId", .array([.integer(41), .integer(42)])), ("paintLayoutId", .array([.integer(51), .integer(52)]))])))
        + F.lengthData(hair ?? F.pack(record("0.0.4", [("glossId", .integer(11)),
            ("parts", .array((60...63).map { F.map([("id", .integer(Int64($0)))]) }))])))
    }

    static func coordinate(accessories: [V]? = nil, clothesVersion: String = "0.0.1") -> Data {
        var parts: [V] = []
        for index in 0..<9 {
            let colors: [V] = (0..<4).map { color in
                F.map([("pattern", V.integer(Int64(index * 10 + color)))])
            }
            parts.append(F.map([
                ("id", .integer(Int64(100 + index))), ("emblemeId", .integer(Int64(200 + index))),
                ("emblemeId2", .integer(Int64(300 + index))), ("colorInfo", .array(colors))]))
        }
        let clothes = record(clothesVersion, [("parts", .array(parts)),
            ("subPartsId", .array([.integer(801), .integer(802), .integer(803)]))])
        let accessory = record("0.0.2", [("parts", .array(accessories ?? [
            F.map([("type", .integer(122)), ("id", .integer(1080))]),
            F.map([("type", .integer(123)), ("id", .integer(-9))])]))])
        // This optional makeup is deliberately populated. The installed UAR does
        // not visit its properties, even when enableMakeup is true.
        return F.lengthData(F.pack(clothes)) + F.lengthData(F.pack(accessory)) + Data([1])
            + F.lengthData(F.pack(record("0.0.0", [("lipId", .integer(999))])))
    }

    static func card(custom: Data? = nil, coordinates: [V]? = nil) throws -> SourceCharacterCard {
        var blocks = [F.Block(name: "Custom", version: "0.0.0", data: custom ?? self.custom())]
        if let coordinates { blocks.append(.init(name: "Coordinate", version: "0.0.0", data: F.pack(.array(coordinates)))) }
        return try SourceCharacterCard.decode(F.card(blocks: blocks))
    }

    static func contract(omitting: String? = nil) throws -> SourceModCatalogContract {
        var mappings: [(Int, String)] = [
            (100, "ChaFileFace.headId"), (408, "ChaFileFace.Pupil1"), (408, "ChaFileFace.Pupil2"),
            (409, "ChaFileFace.PupilGradient1"), (409, "ChaFileFace.PupilGradient2"),
            (420, "ChaFileBody.detailId"), (421, "ChaFileBody.PaintID1"), (421, "ChaFileBody.PaintID2"),
            (3, "ChaFileBody.PaintLayoutID1"), (3, "ChaFileBody.PaintLayoutID2"),
            (433, "ChaFileHair.glossId"), (101, "ChaFileHair.HairBack"), (102, "ChaFileHair.HairFront"),
            (103, "ChaFileHair.HairSide"), (104, "ChaFileHair.HairOption"),
            (403, "ChaFileMakeup.lipId"), (405, "ChaFileMakeup.PaintID1"), (405, "ChaFileMakeup.PaintID2"),
            (122, "ChaFileAccessory.PartsInfo.id"), (123, "ChaFileAccessory.PartsInfo.id")]
        let clothes = [("Top", 105), ("Bot", 106), ("Bra", 107), ("Shorts", 108), ("Gloves", 109),
            ("Pants", 110), ("Socks", 111), ("ShoesInner", 112), ("ShoesOuter", 112)]
        for (name, category) in clothes {
            let p = "ChaFileClothes.Clothes" + name
            mappings += [(category, p), (431, p + "Emblem"), (431, p + "Emblem2")]
            mappings += (0..<4).map { (430, p + "Pattern\($0)") }
        }
        mappings += [(210, "ChaFileClothes.ClothesJacketSubA"), (211, "ChaFileClothes.ClothesJacketSubB"),
            (212, "ChaFileClothes.ClothesJacketSubC"), (200, "ChaFileClothes.ClothesSailorSubA"),
            (201, "ChaFileClothes.ClothesSailorSubB"), (202, "ChaFileClothes.ClothesSailorSubC")]
        let groups = Dictionary(grouping: mappings.filter { $0.1 != omitting }, by: { $0.0 })
        let categories = groups.keys.sorted().map { category -> [String: Any] in
            ["number": category, "name": "test\(category)", "properties": groups[category]!.map(\.1)]
        }
        return try SourceModCatalogContract.decode(JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "keyTypes": ["Category", "DistributionNo", "ID", "Possess", "Name"], "categories": categories,
            "referenceRules": []]))
    }
}

@Test func sourceCardResolverDestinationsReadRawCustomValues() throws {
    let F = ResolverDestinationFixture.self
    let scan = try F.card().resolverDestinations(contract: F.contract())
    let destinations = Dictionary(uniqueKeysWithValues: scan.destinations.map { ($0.property, $0) })
    #expect(destinations.count == 18)
    #expect(destinations["ChaFileFace.Pupil1"] == .init(property: "ChaFileFace.Pupil1", catalogProperty: "ChaFileFace.Pupil1", category: 408, sourceSlot: 23))
    #expect(destinations["ChaFileFace.Pupil2"]?.sourceSlot == 24)
    #expect(destinations["ChaFileFace.PupilGradient2"]?.category == 409)
    #expect(destinations["ChaFileFace.PupilGradient2"]?.sourceSlot == 32)
    #expect(destinations["ChaFileBody.PaintLayoutID2"]?.category == 3)
    #expect(destinations["ChaFileBody.PaintLayoutID2"]?.sourceSlot == 52)
    #expect(destinations["ChaFileHair.HairOption"]?.category == 104)
    #expect(destinations["ChaFileHair.HairOption"]?.sourceSlot == 63)
    #expect(destinations["ChaFileMakeup.lipId"]?.sourceSlot == 48)
    #expect(!scan.diagnostics.isEmpty) // Missing fields remain absent, never zero-filled.
}

@Test func sourceCardResolverDestinationsUseActualAccessoryTypeAndOutfitPrefix() throws {
    let F = ResolverDestinationFixture.self
    let scan = try F.card(coordinates: [.binary(F.coordinate()), .binary(F.coordinate())])
        .resolverDestinations(contract: F.contract())
    let destinations = Dictionary(uniqueKeysWithValues: scan.destinations.map { ($0.property, $0) })
    #expect(destinations["outfit1.accessory0.ChaFileAccessory.PartsInfo.id"] == .init(
        property: "outfit1.accessory0.ChaFileAccessory.PartsInfo.id", catalogProperty: "ChaFileAccessory.PartsInfo.id", category: 122, sourceSlot: 1080))
    #expect(destinations["outfit0.accessory1.ChaFileAccessory.PartsInfo.id"]?.category == 123)
    #expect(destinations["outfit0.accessory1.ChaFileAccessory.PartsInfo.id"]?.sourceSlot == -9)
    #expect(destinations["outfit0.ChaFileClothes.ClothesShoesOuter"]?.category == 112)
    #expect(destinations["outfit0.ChaFileClothes.ClothesShoesOuter"]?.sourceSlot == 108)
    #expect(destinations["outfit0.ChaFileClothes.ClothesShoesOuterEmblem2"]?.sourceSlot == 308)
    #expect(destinations["outfit0.ChaFileClothes.ClothesBotPattern3"]?.sourceSlot == 13)
    #expect(destinations["outfit0.ChaFileClothes.ClothesJacketSubA"]?.sourceSlot == 801)
    #expect(destinations["outfit0.ChaFileClothes.ClothesSailorSubA"]?.sourceSlot == 801)
    #expect(!destinations.keys.contains { $0.hasPrefix("outfit") && $0.contains("ChaFileMakeup") })
    #expect(scan.destinations.count == 18 + 71 * 2)
}

@Test func sourceCardResolverDestinationsIgnoreUnvisitedOutfitsAndPreserveUnknownRecords() throws {
    let F = ResolverDestinationFixture.self
    let bytes = F.coordinate()
    let card = try F.card(custom: F.custom(hair: Data([0xc1])), coordinates: Array(repeating: .binary(bytes), count: 8))
    let original = card.preservedData
    let scan = try card.resolverDestinations(contract: F.contract())
    #expect(scan.destinations.contains { $0.property == "ChaFileFace.Pupil1" })
    #expect(!scan.destinations.contains { $0.property.hasPrefix("ChaFileHair") })
    #expect(scan.destinations.contains { $0.property.hasPrefix("outfit6.") })
    #expect(!scan.destinations.contains { $0.property.hasPrefix("outfit7.") })
    #expect(scan.diagnostics.contains { $0.contains("hair resolver destinations were not scanned") })
    #expect(scan.diagnostics.contains { $0.contains("after outfit6") })
    #expect(card.preservedData == original)
}

@Test func sourceCardResolverDestinationsRejectUnprovenValuesAndContractMappings() throws {
    let F = ResolverDestinationFixture.self
    let face = F.record("0.0.2", [("headId", .integer(Int64(Int32.max) + 1)),
        ("pupil", .array([OriginalCardFixture.map([("id", .integer(5)), ("gradMaskId", .float(8.0))])]))])
    let accessories: [SourceMessagePackValue] = [
        OriginalCardFixture.map([("id", .integer(20))]),
        OriginalCardFixture.map([("type", .integer(999)), ("id", .integer(21))]),
        OriginalCardFixture.map([("type", .integer(122)), ("id", .unsigned(UInt64.max))]),
        .null]
    let scan = try F.card(custom: F.custom(face: face), coordinates: [.binary(F.coordinate(accessories: accessories))])
        .resolverDestinations(contract: F.contract(omitting: "ChaFileFace.Pupil1"))
    #expect(!scan.destinations.contains { $0.property.hasPrefix("ChaFileFace") })
    #expect(!scan.destinations.contains { $0.property.contains("accessory") })
    #expect(scan.destinations.contains { $0.property == "ChaFileBody.detailId" })
    #expect(scan.diagnostics.contains { $0.contains("category 999") })
    #expect(scan.diagnostics.contains { $0.contains("PartsInfo.type is missing") })
    #expect(scan.diagnostics.contains { $0.contains("ChaFileFace.Pupil1 category 408") })
}

@Test func sourceCardResolverDestinationsIsolateUnsupportedVersionsAndFraming() throws {
    let F = ResolverDestinationFixture.self
    let scan = try F.card(custom: F.custom(body: F.record("9.9.9", [("detailId", .integer(1))])),
        coordinates: [.binary(F.coordinate(clothesVersion: "9.9.9")), .binary(Data([0, 0, 0])), .integer(5)])
        .resolverDestinations(contract: F.contract())
    #expect(!scan.destinations.contains { $0.property.hasPrefix("ChaFileBody") })
    #expect(!scan.destinations.contains { $0.property.hasPrefix("outfit0.ChaFileClothes") })
    #expect(scan.destinations.contains { $0.property == "outfit0.accessory0.ChaFileAccessory.PartsInfo.id" })
    #expect(scan.destinations.contains { $0.property == "ChaFileHair.HairBack" })
    #expect(scan.diagnostics.contains { $0.contains("outfit1.coordinate framing is incomplete") })
    #expect(scan.diagnostics.contains { $0.contains("outfit2 is not a binary") })
    // Every proper prefix of a coordinate is bounded and retains a diagnosable partial scan.
    let bytes = F.coordinate()
    for length in [0, 1, 3, 4, 8, bytes.count - 1] {
        let partial = try F.card(coordinates: [.binary(bytes.prefix(length))]).resolverDestinations(contract: F.contract())
        #expect(partial.diagnostics.contains { $0.contains("coordinate framing is incomplete") })
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MOD_CATALOG_CONTRACT"]),
               "Requires IKKOKU_MOD_CATALOG_CONTRACT"))
func sourceCardResolverDestinationsIndependentSourceContract() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_MOD_CATALOG_CONTRACT")
    let contract = try SourceModCatalogContract.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    let F = ResolverDestinationFixture.self
    let scan = try F.card(coordinates: [.binary(F.coordinate())]).resolverDestinations(contract: contract)
    #expect(scan.destinations.count == 18 + 71)
    #expect(!scan.diagnostics.contains { $0.contains("absent from the recovered catalog contract") })
}
