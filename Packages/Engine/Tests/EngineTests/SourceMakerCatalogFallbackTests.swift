import Foundation
import Testing
@testable import Character

/// #346: a hair or clothes ID that no installed list has draws the original's
/// fallback (LoadCharaFbxDataAsync, ChaControl.Koikatu.cs:8675-8700): the
/// category's default ID unless it is the saved one, else 0, else nothing.
/// Synthetic libraries and presence files only.
private enum CatalogFallbackFixture {
    static let hash = String(repeating: "0", count: 64)
    static func converted(_ category: Int, _ id: Int) -> [String: Any] {
        ["category": category, "id": id, "name": "\(category)-\(id)", "rig": ["file": "r\(category)-\(id).json", "sha256": hash],
         "meshNames": ["m"]]
    }
    static func empty(_ category: Int, _ id: Int) -> [String: Any] {
        ["category": category, "id": id, "name": "p_dummy", "empty": true]
    }
    /// The presence file's bytes for `categories`, as catalog_presence.py writes them.
    static func presenceData(_ categories: [Int: [Int]], kind: String = "koikatsu-catalog-presence") throws -> Data {
        let keyed = Dictionary(uniqueKeysWithValues: categories.map { (String($0.key), $0.value) })
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "kind": kind, "categories": keyed], options: [.sortedKeys])
    }
    static func library(_ entries: [[String: Any]], presence: Data?, directory: URL, file: String = "catalog-presence.json",
                        sha256: String? = nil) throws -> SourceMakerLibrary {
        var document: [String: Any] = ["schemaVersion": 1, "entries": entries]
        if let presence {
            try presence.write(to: directory.appendingPathComponent("catalog-presence.json"))
            document["catalogPresence"] = ["file": file, "sha256": sha256 ?? OriginalCardFixture.hash(presence)]
        }
        let url = directory.appendingPathComponent("library.json")
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        return try .load(url: url)
    }
    static let clothes = Array(105...112)
    /// Back 0 and front 1 are drawable defaults; side, option and clothes 0
    /// are the catalogs' empty rows, as in the installed base list.
    static var entries: [[String: Any]] {
        [converted(101, 0), converted(102, 1), empty(103, 0), empty(104, 0), converted(101, 28)] + clothes.map { empty($0, 0) }
    }
    static var presence: [Int: [Int]] {
        var result: [Int: [Int]] = [101: [0, 2, 28], 102: [1, 2], 103: [0], 104: [0, 7]]
        for category in clothes { result[category] = [0, 3] }
        return result
    }
}

@Test func sourceMakerCatalogFallbackDrawsEachCategoryDefaultForAnAbsentID() throws {
    typealias F = CatalogFallbackFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let library = try F.library(F.entries, presence: F.presenceData(F.presence), directory: directory)
    #expect(library.catalogPresence?[101] == [0, 2, 28] && library.catalogPresence?.count == 12)
    func select(_ category: Int, _ id: Int) -> SourceMakerLibrary.Selection {
        library.selection(category: category, savedID: id, property: "p\(category)", references: nil)
    }
    // Hair defaults {0, 1, 0, 0}: back 0 and front 1 are drawn, side and option 0 are empty.
    for (category, resolved, empty) in [(101, 0, false), (102, 1, false), (103, 0, true), (104, 0, true)] {
        let selected = select(category, 99)
        #expect(selected.status == "catalogFallback" && selected.resolvedID == resolved, "\(category)")
        #expect(selected.entry?.id == resolved && (selected.entry?.empty == true) == empty, "\(category)")
        // The saved identity is reported unchanged.
        #expect(selected.savedID == 99 && selected.sourceID == 99 && selected.modGUID == nil)
    }
    // Every clothes kind defaults to 0, the empty row: the original draws nothing there.
    for category in F.clothes {
        let selected = select(category, 99)
        #expect(selected.status == "catalogFallback" && selected.resolvedID == 0 && selected.entry?.empty == true, "\(category)")
    }
    // A present ID keeps today's statuses: converted, empty, or unconverted.
    #expect(select(101, 28).status == "converted" && select(101, 28).resolvedID == nil)
    #expect(select(103, 0).status == "empty")
    for (category, id) in [(101, 2), (102, 2), (104, 7), (105, 3)] {
        let selected = select(category, id)
        #expect(selected.status == "conversionMissing" && selected.entry == nil && selected.resolvedID == nil, "\(category):\(id)")
    }
}

@Test func sourceMakerCatalogFallbackFollowsTheOriginalOrderAndScope() throws {
    typealias F = CatalogFallbackFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    // Front's default 1 is absent: 0 is next, and its row is unconverted, so
    // the reference part stays (no entry). Back has neither its default nor
    // 0: the original loads nothing. Bottom 106 has no presence record.
    let presence: [Int: [Int]] = [101: [5], 102: [0, 5], 103: [0], 105: [0]]
    let library = try F.library([F.converted(101, 5), F.empty(105, 0)], presence: F.presenceData(presence), directory: directory)
    func select(_ category: Int, _ id: Int, _ references: SourceCardModReferences? = nil) -> SourceMakerLibrary.Selection {
        library.selection(category: category, savedID: id, property: "ChaFileHair.HairBack", references: references)
    }
    let front = select(102, 99)
    #expect(front.status == "catalogFallback" && front.resolvedID == 0 && front.entry == nil)
    // A saved ID equal to the default that is itself absent goes to 0.
    #expect(select(102, 1).status == "catalogFallback" && select(102, 1).resolvedID == 0)
    let back = select(101, 99)
    #expect(back.status == "catalogFallback" && back.resolvedID == nil)
    #expect(back.entry?.empty == true && back.entry?.rig == nil && back.entry?.id == 99)
    // Outside the presence record or the hair/clothes categories: unchanged.
    #expect(select(106, 99).status == "conversionMissing")
    #expect(select(121, 99).status == "conversionMissing")
    // A resolver record naming a mod never falls back to a vanilla row; one
    // without a GUID still needs its compatibility data.
    let mod = try MakerLibraryReferences.make([("Example.Mod", "ChaFileHair.HairBack", 99, 1)])
    #expect(select(101, 99, mod).status == "conversionMissing" && select(101, 99, mod).resolvedID == nil)
    let anonymous = try MakerLibraryReferences.make([(nil, "ChaFileHair.HairBack", 99, 1)])
    #expect(select(101, 99, anonymous).status == "compatibilityRequired")
    // Without a presence file nothing is known to be absent: today's behaviour.
    let plain = try F.library([F.converted(101, 5)], presence: nil, directory: directory)
    #expect(plain.catalogPresence == nil)
    #expect(plain.selection(category: 101, savedID: 99, property: "p", references: nil).status == "conversionMissing")
}

@Test func sourceMakerCatalogPresenceIsVerifiedOnceAtLoad() throws {
    typealias F = CatalogFallbackFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let valid = try F.presenceData([101: [0]])
    _ = try F.library([], presence: valid, directory: directory)
    // A changed presence file is a load error, as for every other sidecar.
    #expect(throws: (any Error).self) { try F.library([], presence: valid, directory: directory, sha256: F.hash) }
    #expect(throws: (any Error).self) { try F.library([], presence: valid, directory: directory, file: "../catalog-presence.json") }
    for invalid in [try F.presenceData([101: [0]], kind: "other"), try F.presenceData([121: [0]]), try F.presenceData([101: [-1]]),
                    try F.presenceData([101: [Int(Int32.max) + 1]]), Data("{\"schemaVersion\":2,\"kind\":\"koikatsu-catalog-presence\",\"categories\":{}}".utf8)] {
        #expect(throws: (any Error).self) { try F.library([], presence: invalid, directory: directory) }
    }
    // Loaded once: editing the file after load changes nothing already loaded.
    let library = try F.library([F.converted(101, 0)], presence: try F.presenceData([101: [0, 1]]), directory: directory)
    try F.presenceData([101: [0, 1, 99]]).write(to: directory.appendingPathComponent("catalog-presence.json"))
    #expect(library.selection(category: 101, savedID: 99, property: "p", references: nil).status == "catalogFallback")
}

/// Resolver records (com.bepis.sideloader.universalautoresolver) for the synthetic cards.
private enum MakerLibraryReferences {
    typealias F = OriginalCardFixture
    static func make(_ records: [(String?, String, Int, Int)]) throws -> SourceCardModReferences {
        let values = records.map { guid, property, source, local in F.Value.binary(F.pack(F.map([
            ("ModID", guid.map(F.Value.string) ?? .null), ("Property", .string(property)),
            ("Slot", .integer(Int64(source))), ("LocalSlot", .integer(Int64(local))),
            ("CategoryNo", .integer(999))]))) }
        let plugin = F.plugin(0, data: F.map([("info", .array(values))]))
        let card = try SourceCharacterCard.decode(F.card(blocks: F.blocks() + [F.extended(F.map([
            ("com.bepis.sideloader.universalautoresolver", plugin)]))]))
        return try #require(try card.modReferences())
    }
}
