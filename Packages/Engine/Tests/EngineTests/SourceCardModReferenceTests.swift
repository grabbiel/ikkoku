import Foundation
import Testing
import CryptoKit
import Assets
import Character

private enum ResolverFixture {
    typealias F = OriginalCardFixture
    typealias V = SourceMessagePackValue
    static func record(guid: String? = "fixture.mod", property: String? = "Access.id", slot: Int64 = 7,
                       category: Int64 = 122, localSlot: Int64 = 100_000_001, extra: [(String, V)] = []) -> Data {
        F.pack(F.map([("ModID", guid.map(V.string) ?? .null), ("Property", property.map(V.string) ?? .null),
            ("Slot", .integer(slot)), ("CategoryNo", .integer(category)), ("LocalSlot", .integer(localSlot))] + extra))
    }
    static func plugin(_ records: [Data], version: Int64 = 0) -> V {
        .array([.integer(version), F.map([("info", .array(records.map(V.binary)))])])
    }
    static func card(_ entries: [(String, V)]) throws -> SourceCharacterCard {
        try SourceCharacterCard.decode(F.card(blocks: [.init(name: "KKEx", version: "3", data: F.pack(F.map(entries)))]))
    }
    static func decode(_ records: [Data]) throws -> SourceCardModReferences {
        try #require(try card([(SourceCardModReferences.pluginIDs[1], plugin(records))]).modReferences())
    }
    static func destination(_ property: String = "Access.id", category: Int = 122, slot: Int = 999) -> SourceCardModReferences.Destination {
        .init(property: property, catalogProperty: "Access.id", category: category, sourceSlot: slot)
    }
}

@Test func sourceCardResolverDecodesOriginalMapAndPreservesUnknownBytes() throws {
    let bytes = ResolverFixture.record(guid: "\u{85}\u{a0}fixture.mod\u{3000}", slot: -7, localSlot: Int64(Int32.max),
        extra: [("Author", .string("Author")), ("Website", .null), ("Name", .string("Name")),
                ("Future", .ext(12, Data([1, 2, 3])))])
    let value = try #require(ResolverFixture.decode([bytes]).records.first)
    #expect(value.modGUID == "fixture.mod" && value.sourceSlot == -7 && value.localSlot == Int(Int32.max))
    #expect(value.property == "Access.id" && value.category == 122 && value.author == "Author")
    #expect(value.website == nil && value.name == "Name" && value.preservedData == bytes)
    #expect(value.sourceSHA256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    let significant = try #require(ResolverFixture.decode([ResolverFixture.record(guid: "\u{200b}fixture.mod\u{feff}")]).records.first)
    #expect(significant.modGUID == "\u{200b}fixture.mod\u{feff}")
}

@Test func sourceCardResolverFormatterDefaultsAndLastValidatedDuplicateWins() throws {
    typealias F = OriginalCardFixture
    let blank = try #require(ResolverFixture.decode([F.pack(F.map([]))]).records.first)
    #expect(blank.modGUID == nil && blank.property == nil && blank.author == nil)
    #expect(blank.sourceSlot == 0 && blank.localSlot == 0 && blank.category == 0)
    let duplicate = F.pack(F.map([("Slot", .integer(4)), ("Slot", .integer(9)), ("ModID", .string("first")),
                                 ("ModID", .null), ("Property", .string("Access.id"))]))
    let last = try #require(ResolverFixture.decode([duplicate]).records.first)
    #expect(last.sourceSlot == 9 && last.modGUID == nil)
    let badFirst = F.pack(F.map([("Slot", .string("invalid")), ("Slot", .integer(9))]))
    #expect(throws: (any Error).self) { try ResolverFixture.decode([badFirst]) }
}

@Test func sourceCardResolverMarkerPrecedenceAndIgnoredVersionMatchSource() throws {
    typealias F = OriginalCardFixture
    let ec = SourceCardModReferences.pluginIDs[0], kk = SourceCardModReferences.pluginIDs[1]
    let card = try ResolverFixture.card([(kk, ResolverFixture.plugin([ResolverFixture.record()])),
        (ec, .array([.integer(42), F.map([])]))])
    let references = try #require(try card.modReferences())
    #expect(references.pluginID == ec && references.pluginVersion == 42 && references.records.isEmpty)
    #expect(references.diagnostics.contains { $0.contains("takes precedence") })
    let unknownVersion = try #require(try ResolverFixture.card([(kk, ResolverFixture.plugin([ResolverFixture.record()], version: -4))]).modReferences())
    #expect(unknownVersion.pluginVersion == -4 && unknownVersion.records.count == 1)
    let nullEC = try ResolverFixture.card([(kk, ResolverFixture.plugin([ResolverFixture.record()])), (ec, .null)])
    #expect(try nullEC.modReferences()?.pluginID == kk)
    let nullData = try ResolverFixture.card([(ec, .array([.integer(0), .null])), (kk, ResolverFixture.plugin([]))])
    #expect(throws: (any Error).self) { try nullData.modReferences() }
}

@Test func sourceCardResolverRejectsMalformedAndOversizedRecords() throws {
    typealias F = OriginalCardFixture
    let invalid: [Data] = [Data([0xc0]), Data([0x90]), F.pack(.ext(99, Data([1, 2]))),
        ResolverFixture.record() + Data([0]), ResolverFixture.record(slot: Int64(Int32.max) + 1),
        F.pack(F.map([("Slot", .null)])), F.pack(F.map([("Property", .binary(Data()))])),
        F.pack(.map([.init(key: .integer(1), value: .null)])), Data(repeating: 0, count: 1024 * 1024 + 1),
        ResolverFixture.record(guid: String(repeating: "a", count: 65_537))]
    for bytes in invalid { #expect(throws: (any Error).self) { try ResolverFixture.decode([bytes]) } }
    for info in [SourceMessagePackValue.null, .binary(Data()), .array([.null]), .array(Array(repeating: .binary(Data([0x80])), count: 10_001))] {
        let card = try ResolverFixture.card([(SourceCardModReferences.pluginIDs[1], .array([.integer(0), F.map([("info", info)])]))])
        #expect(throws: (any Error).self) { try card.modReferences() }
    }
    let bytes = ResolverFixture.record()
    for length in 0..<bytes.count { #expect(throws: (any Error).self) { try ResolverFixture.decode([bytes.prefix(length)]) } }
}

@Test func sourceCardResolverFirstExactPropertyWinsWithoutUnicodeNormalization() throws {
    let composed = "Face.\u{e9}", decomposed = "Face.e\u{301}"
    let references = try ResolverFixture.decode([
        ResolverFixture.record(guid: "", property: "Access.id"), ResolverFixture.record(property: "Access.id"),
        ResolverFixture.record(property: composed), ResolverFixture.record(property: decomposed),
        ResolverFixture.record(property: "access.id"), ResolverFixture.record(property: nil)])
    let report = try references.report(destinations: [ResolverFixture.destination(), ResolverFixture.destination(composed), ResolverFixture.destination(decomposed)])
    #expect(report.resolutions.map(\.status) == ["compatibilityRequired", "shadowed", "libraryNotLoaded", "libraryNotLoaded", "unmatchedProperty", "unmatchedProperty"])
    #expect(report.resolutions[0].destination?.sourceSlot == 999)
}

@Test func sourceCardResolverUsesSavedSlotAndActualDestinationCategoryForCatalogLookup() throws {
    let directory = try catalogTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let csv = "122\n0\ntarget\nID,Name,MainManifest,MainAB,MainData\n7,first,abdata,chara/base.unity3d,prefab\n7,second,abdata,chara/other.unity3d,other\n"
    let library = try SourceModLibrary(packages: [catalogTestPackage(directory, csvs: [csv])])
    let catalog = try SourceModCatalog(library: library, contract: catalogTestContract())
    let references = try ResolverFixture.decode([ResolverFixture.record(property: "outfit0.accessory2.Access.id", category: 999)])
    let destination = ResolverFixture.destination("outfit0.accessory2.Access.id", slot: 12345)
    let report = try references.report(destinations: [destination], library: library, catalog: catalog,
        sourceAssets: [.init(bundlePath: "chara/base.unity3d", assetName: "prefab", type: "GameObject")])
    let result = try #require(report.resolutions.first)
    #expect(result.status == "resolved" && result.entry?.key.sourceSlot == 7 && result.entry?.key.category == 122)
    #expect(result.entry?.name == "first" && result.dependencies.count == 1)
    #expect(result.dependencies.first?.status == "sourceOnly" && result.dependencies.first?.reference.assetName == "prefab")
    #expect(report.diagnostics.contains { $0.contains("declares category 999") })
    let wrongSlot = try ResolverFixture.decode([ResolverFixture.record(slot: 100_000_001, localSlot: 7)])
    #expect(try wrongSlot.report(destinations: [ResolverFixture.destination()], library: library, catalog: catalog).resolutions.first?.status == "catalogEntryMissing")
}

@Test func sourceCardResolverReportsMissingLibraryAndUnresolvedIdentitiesWithoutFallback() throws {
    let directory = try catalogTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SourceModLibrary(packages: [catalogTestPackage(directory, csvs: ["122\n0\ntarget\nID,Name\n7,fixture\n"])])
    let catalog = try SourceModCatalog(library: library, contract: catalogTestContract())
    let references = try ResolverFixture.decode([ResolverFixture.record()]), destinations = [ResolverFixture.destination()]
    #expect(try references.report(destinations: nil).resolutions.first?.status == "metadataOnly")
    #expect(try references.report(destinations: destinations).resolutions.first?.status == "libraryNotLoaded")
    #expect(try references.report(destinations: destinations, library: library).resolutions.first?.status == "catalogUnavailable")
    for guid in ["missing.mod", "Fixture.mod", "\u{200b}fixture.mod"] {
        let missing = try ResolverFixture.decode([ResolverFixture.record(guid: guid)])
        #expect(try missing.report(destinations: destinations, library: library, catalog: catalog).resolutions.first?.status == "modNotMounted")
    }
    let unknownCategory = [ResolverFixture.destination(category: 123)]
    #expect(try references.report(destinations: unknownCategory, library: library, catalog: catalog).resolutions.first?.status == "catalogEntryMissing")
    #expect(throws: (any Error).self) { try references.report(destinations: destinations + destinations) }
}

@Test func sourceModCatalogResolverKeepsSourceGUIDWhitespaceAndOrdinalIdentity() throws {
    let directory = try catalogTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SourceModLibrary(packages: [catalogTestPackage(directory, guid: "fixture.\u{e9}", csvs: ["122\n0\ntarget\nID,Name\n7,fixture\n"])])
    let catalog = try SourceModCatalog(library: library, contract: catalogTestContract())
    #expect(catalog.resolve(modGUID: " \u{85}fixture.\u{e9}\u{3000}", category: 122, sourceSlot: 7) != nil)
    #expect(catalog.resolve(modGUID: "fixture.e\u{301}", category: 122, sourceSlot: 7) == nil)
    #expect(catalog.resolve(modGUID: "\u{200b}fixture.\u{e9}", category: 122, sourceSlot: 7) == nil)
    #expect(SourceModCatalog.trimSourceGUID("\u{3000}\u{85}\n").isEmpty)
}

private struct ResolverOracle: Decodable {
    struct Record: Decodable {
        let ordinal: Int, ModID: String?, Property: String?, Author: String?, Website: String?, Name: String?
        let Slot: Int, LocalSlot: Int, CategoryNo: Int, sha256: String, bytes: Int
    }
    let cardSHA256: String, pluginID: String?, pluginVersion: Int?, records: [Record]
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SOURCE_RESOLVER_FIXTURES"]),
               "Requires IKKOKU_SOURCE_RESOLVER_FIXTURES"))
func sourceCardResolverMatchesIndependentSourceFormatOracle() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SOURCE_RESOLVER_FIXTURES"))
    for name in ["synthetic-current", "synthetic-ec-precedence", "synthetic-ec-without-info",
                 "synthetic-null-ec-falls-back", "synthetic-legacy-override"] {
        let card = try SourceCharacterCard.load(url: root.appendingPathComponent(name + ".png"))
        let expected = try JSONDecoder().decode(ResolverOracle.self, from: Data(contentsOf: root.appendingPathComponent(name + ".json")))
        let actual = try #require(try card.modReferences())
        #expect(card.sourceSHA256 == expected.cardSHA256)
        #expect(actual.pluginID == expected.pluginID && actual.pluginVersion == expected.pluginVersion)
        #expect(actual.records.count == expected.records.count)
        for (record, oracle) in zip(actual.records, expected.records) {
            #expect(record.index == oracle.ordinal && record.modGUID == oracle.ModID && record.property == oracle.Property)
            #expect(record.sourceSlot == oracle.Slot && record.localSlot == oracle.LocalSlot && record.category == oracle.CategoryNo)
            #expect(record.author == oracle.Author && record.website == oracle.Website && record.name == oracle.Name)
            #expect(record.preservedData.count == oracle.bytes && record.sourceSHA256 == oracle.sha256)
        }
    }
}
