import Foundation
import Testing
@testable import Character
import Scene

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

/// The #346 lane card pair. Only hair and clothes IDs change
/// (`selectingVanillaAsset`): the absent card saves `absentID`, which no
/// installed catalog has, in all four hair slots and in every saved outfit's
/// clothes slots but the indoor shoes, which the selection editor leaves as
/// saved (the Maker never assembles them). Its twin saves the original's
/// defaults there explicitly: hair 0/1/0/0 and clothes 0.
enum CatalogFallbackCards {
    static let absentID = 999_999
    static let hairDefaults = [0, 1, 0, 0]
    static func selecting(_ card: SourceCharacterCard, hair: [Int], clothes: Int) throws -> SourceCharacterCard {
        var current = card
        for (slot, id) in hair.enumerated() {
            current = try SourceCharacterCard.decode(current.selectingVanillaAsset(id, at: .hair(slot)))
        }
        for coordinate in 0..<(try current.coordinateCount()) {
            for slot in 0..<9 where slot != 7 {
                current = try SourceCharacterCard.decode(current.selectingVanillaAsset(clothes, at: .clothes(coordinate: coordinate, slot: slot)))
            }
        }
        return current
    }
    static func absent(_ card: SourceCharacterCard) throws -> SourceCharacterCard {
        try selecting(card, hair: Array(repeating: absentID, count: 4), clothes: absentID)
    }
    static func explicitDefaults(_ card: SourceCharacterCard) throws -> SourceCharacterCard {
        try selecting(card, hair: hairDefaults, clothes: 0)
    }
    /// The same assembled rig and geometry, part by part.
    static func sameAssembly(_ a: SourceRig, _ b: SourceRig) -> Bool {
        guard a.rig.nodes.count == b.rig.nodes.count, a.rig.skins.count == b.rig.skins.count, a.parts.count == b.parts.count,
              a.rig.order == b.rig.order, a.rig.activeNodes == b.rig.activeNodes else { return false }
        for (left, right) in zip(a.rig.nodes, b.rig.nodes) {
            guard left.name == right.name, left.sourceID == right.sourceID, left.parent == right.parent else { return false }
            guard left.localMatrix == right.localMatrix, left.active == right.active else { return false }
        }
        for (left, right) in zip(a.rig.skins, b.rig.skins) {
            guard left.name == right.name, left.meshNode == right.meshNode, left.rootJoint == right.rootJoint else { return false }
            guard left.joints == right.joints, left.inverseBindMatrices == right.inverseBindMatrices else { return false }
        }
        for (left, right) in zip(a.parts, b.parts) {
            guard left.node == right.node, left.skin == right.skin, left.rendererEnabled == right.rendererEnabled else { return false }
            let x = left.mesh, y = right.mesh
            guard x.name == y.name, x.positions == y.positions, x.normals == y.normals, x.uvs == y.uvs else { return false }
            guard x.joints == y.joints, x.weights == y.weights, x.indices == y.indices, x.materialIndex == y.materialIndex else { return false }
        }
        return true
    }
}

// Optional fixture writer, not a fixture test: the lane card pair under .local.
@Test(.enabled(if: (ProcessInfo.processInfo.environment["IKKOKU_MAKER_FALLBACK_OUTPUT"] ?? "").isEmpty == false,
               "Writes the #346 lane cards only when IKKOKU_MAKER_FALLBACK_OUTPUT is set"))
func sourceMakerCatalogFallbackWritesTheLaneCards() throws {
    let directory = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_FALLBACK_OUTPUT")).standardizedFileURL
    // Derived from a private card: the pair stays in the ignored .local tree.
    try #require(directory.pathComponents.contains(".local"))
    let source = try SourceCharacterCard.load(url: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_SCENARIO_CARD")))
    let absent = try CatalogFallbackCards.absent(source)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try absent.preservedData.write(to: directory.appendingPathComponent("absent-ids.png"))
    try CatalogFallbackCards.explicitDefaults(absent).preservedData.write(to: directory.appendingPathComponent("explicit-defaults.png"))
}

/// The lane card against its explicit-default twin through the env Maker
/// library and its installed catalog presence. Scope: every saved outfit
/// resolves the same rig files (`rigFiles`, no decode); outfit 0 is also
/// assembled in full for the Maker and a Studio wear assembly, where every
/// edited hair and clothes selection falls back to the default and both
/// cards build the same rig and geometry. Outfits 1-6 are not assembled.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_FALLBACK_CARD", "IKKOKU_MAKER_LIBRARY", "IKKOKU_SOURCE_AVATAR"]),
               "Requires IKKOKU_MAKER_FALLBACK_CARD, IKKOKU_MAKER_LIBRARY and IKKOKU_SOURCE_AVATAR"))
func sourceMakerCatalogFallbackCardAssemblesItsExplicitDefaults() throws {
    typealias C = CatalogFallbackCards
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")))
    let presence = try #require(library.catalogPresence, "The Maker library records no installed catalog presence")
    for category in 101...112 { #expect(presence[category]?.contains(C.absentID) == false, "\(category)") }
    let card = try SourceCharacterCard.load(url: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_FALLBACK_CARD")))
    // The fixture is the absent card: deriving it again changes nothing.
    #expect(try C.absent(card).preservedData == card.preservedData)
    let twin = try C.explicitDefaults(card)
    let avatar = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR"))
    let base = try library.assemblyURL(for: card.customization()) ?? avatar
    // Every outfit resolves the same rig files (no decode); outfit 0 is also
    // assembled in full, as in the Maker and in a Studio wear assembly.
    for coordinate in 0..<(try card.coordinateCount()) {
        #expect(library.rigFiles(card: card, coordinate: coordinate, baseURL: base, wear: false)
                == library.rigFiles(card: twin, coordinate: coordinate, baseURL: base, wear: false), "\(coordinate)")
    }
    let coordinate = 0
    for wear in [false, true] {
        let fallback = try library.prepare(card: card, coordinate: coordinate, baseURL: base, wear: wear)
        let explicit = try library.prepare(card: twin, coordinate: coordinate, baseURL: base, wear: wear)
        // The indoor shoes keep their saved ID; `indoorShoes` compares them below.
        func edited(_ selection: SourceMakerLibrary.Selection) -> Bool {
            (101...112).contains(selection.category) && !selection.property.hasSuffix("ShoesInner")
        }
        let rows = fallback.selections.filter(edited), explicitRows = explicit.selections.filter(edited)
        // Four hair slots and eight clothes slots.
        #expect(rows.count == 12 && explicitRows.count == rows.count, "\(coordinate) \(wear)")
        for (row, twinRow) in zip(rows, explicitRows) {
            let resolved = row.category <= 104 ? C.hairDefaults[row.category - 101] : 0
            #expect(row.status == "catalogFallback" && row.savedID == C.absentID && row.sourceID == C.absentID, "\(row.property)")
            #expect(row.resolvedID == resolved && row.entry?.id == resolved && row.property == twinRow.property, "\(row.property)")
            #expect(twinRow.status == "converted" || twinRow.status == "empty", "\(twinRow.property)")
            #expect(twinRow.entry?.id == resolved && twinRow.resolvedID == nil, "\(twinRow.property)")
        }
        #expect(library.rigFiles(card: card, coordinate: coordinate, baseURL: base, wear: wear)
                == library.rigFiles(card: twin, coordinate: coordinate, baseURL: base, wear: wear))
        #expect(fallback.clothingSlots == explicit.clothingSlots && fallback.referenceClothingSlots == explicit.referenceClothingSlots)
        #expect(fallback.indoorShoes == explicit.indoorShoes)
        #expect(C.sameAssembly(fallback.source, explicit.source), "\(coordinate) \(wear)")
        // Each fallback is diagnosed; nothing else differs.
        let fallbackLines = fallback.diagnostics.filter { $0.contains(": catalogFallback, source ID \(C.absentID) ") }
        #expect(fallbackLines.count == rows.count)
        #expect(fallback.diagnostics.filter { !fallbackLines.contains($0) } == explicit.diagnostics)
    }
}
