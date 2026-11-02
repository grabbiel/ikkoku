import Foundation
import CryptoKit
import Assets
import Scene
import Renderer
import CoreMath

/// Converted original/mod resources retain catalog IDs and ordinal GUID identity.
/// Selection never edits the imported card's source or runtime ID fields.
public struct SourceMakerLibrary: Sendable {
    public struct File: Decodable, Sendable { public let file: String, sha256: String }
    public struct Attachment: Decodable, Sendable {
        public let parent: String, positionScale: Float, moveNodes: [String]
        public let ignoreMoves: Bool?
    }
    /// A half-state mesh of a garment (ST-C03): a renderer under an
    /// alternate ChaReference switch node (n_top_b, n_bot_b, n_bot_c,
    /// n_panst_b) that the dressed `meshNames` leave out. `activeWhen` is the
    /// converter's conjunction of ChaControl.UpdateVisible conditions over
    /// its `switches`: every clause's clothes kind must be in its states.
    public struct Alternate: Decodable, Sendable, Equatable {
        public struct Clause: Decodable, Sendable, Equatable { public let kind: Int, states: [Int] }
        public let meshName: String, switches: [String], activeWhen: [Clause]
    }
    public struct Entry: Decodable, Sendable {
        public let category: Int, id: Int, name: String
        public let modGUID: String?, empty: Bool?
        public let rig: File?, appearance: File?, cardBindings: File?, bodyMask: File?
        /// Converted prefab renderers and serialized materials (`materials.json`);
        /// its `catalog` object is the original list row (ListInfoBase.dictInfo
        /// by KeyType name) of this entry.
        public let materialEvidence: File?
        public let meshNames: [String]?, attachment: Attachment?
        /// Half-state meshes, their renderers' material evidence
        /// (`alternates.json`), and the Studio wear appearance and bindings:
        /// the dressed parts and recipes unchanged, then the alternate ones.
        public let alternates: [Alternate]?
        public let alternateMaterialEvidence: File?, wearAppearance: File?, wearCardBindings: File?
    }
    public struct Assembly: Decodable, Sendable {
        public let sex: Int, headID: Int, exType: Int
        public let manifest: File
    }
    private struct Document: Decodable {
        let schemaVersion: Int, entries: [Entry], assemblies: [Assembly]?
        /// #346: which IDs every installed list bundle has, per category
        /// (`catalog-presence.json`, written by Tools/reverse/catalog_presence.py).
        let catalogPresence: File?
    }
    private struct Key: Hashable, Sendable { let category: Int, id: Int, guid: Data? }
    public let sourceURL: URL, directory: URL, entries: [Entry], assemblies: [Assembly]
    private let entryIndex: [Key: Int]
    /// The installed catalogs' IDs per hair and clothes category, read and
    /// SHA-verified once at load; nil when the library has no presence file.
    public private(set) var catalogPresence: [Int: Set<Int>]? = nil
    /// #351: the installed top and bra rows whose Sex column limits them to
    /// one sex, as category → Sex value (2 or 3) → IDs; empty when the
    /// presence file records none (its optional `sexLimited` key).
    public private(set) var catalogSexLimited: [Int: [Int: Set<Int>]] = [:]
    /// The Sex value LoadCharaFbxDataAsync does not draw for a card's sex
    /// (ChaControl.Koikatu.cs:8702-8726): 3 for a male (sex 0), 2 for a
    /// female (sex 1). Only tops (105) and bras (107) are checked.
    public static let catalogSexExcludedValue: [Int: Int] = [0: 3, 1: 2]
    /// #351 item 3: the installed rows whose MainAB is not numbered once
    /// Sideloader strips it (UniversalAutoResolver.ResolveStructure), by
    /// category. For a card whose mod is missing, Sideloader keeps such an ID
    /// and the vanilla row with it is drawn; any other ID becomes 99999999.
    public private(set) var catalogKeptForMissingMod: [Int: Set<Int>] = [:]
    /// #351 item 3: the GUIDs of the installed zipmods, or nil when the
    /// presence file does not list them (a mod is then never called missing).
    public private(set) var installedModGUIDs: Set<Data>? = nil
    /// ChaControl's default ID per category when a saved ID is in no installed
    /// list (recovered ChaControl.Koikatu.cs): hair `defId` {0, 1, 0, 0}
    /// (ChangeHairAsync :7015-7026), clothes 0 (top :7278, bottom :7778, bra
    /// :7893, shorts :8069, gloves :8164, pantyhose :8249, socks :8344, shoes
    /// `defID` :8404-8415). Accessories pass -1 (:8621) and load nothing, which
    /// is what an unresolved accessory already does here.
    public static let catalogDefaultIDs: [Int: Int] = [101: 0, 102: 1, 103: 0, 104: 0, 105: 0, 106: 0, 107: 0, 108: 0,
                                                       109: 0, 110: 0, 111: 0, 112: 0]
    private struct PresenceDocument: Decodable {
        let schemaVersion: Int, kind: String, categories: [String: [Int]]
        /// #351, optional: category → Sex value → IDs, written only when a
        /// checked row is sex-limited, so older v1 files are unchanged.
        let sexLimited: [String: [String: [Int]]]?
        /// #351 item 3, optional: category → IDs Sideloader keeps for a
        /// missing mod, and the installed zipmods' GUIDs.
        let nonNumericMainAB: [String: [Int]]?
        let installedMods: InstalledMods?
        struct InstalledMods: Decodable { let guids: [String] }
    }
    private struct LoadedPresence {
        var ids: [Int: Set<Int>] = [:], sexLimited: [Int: [Int: Set<Int>]] = [:]
        var keptForMissingMod: [Int: Set<Int>] = [:], installedMods: Set<Data>? = nil
    }

    public static func load(url: URL) throws -> Self {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let data = try input.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024 else { throw RigError.invalid("Maker library exceeds 16 MiB.") }
        let doc = try JSONDecoder().decode(Document.self, from: data)
        guard doc.schemaVersion == 1, doc.entries.count <= 10_000, (doc.assemblies?.count ?? 0) <= 256 else { throw RigError.invalid("Unsupported Maker library.") }
        var index: [Key: Int] = [:]
        for (i, entry) in doc.entries.enumerated() {
            let key = Key(category: entry.category, id: entry.id, guid: entry.modGUID.map { Data($0.utf8) })
            guard entry.category >= 0, entry.id >= 0, entry.modGUID?.isEmpty != true,
                  entry.empty == true || (entry.rig != nil && entry.meshNames?.isEmpty == false),
                  index.updateValue(i, forKey: key) == nil else { throw RigError.invalid("Invalid or duplicate Maker asset identity.") }
            if let alternates = entry.alternates {
                let names = alternates.map(\.meshName)
                guard entry.empty != true, [105, 106, 107, 108, 110].contains(entry.category), !alternates.isEmpty, alternates.count <= 64,
                      Set(names).count == names.count, Set(names).isDisjoint(with: entry.meshNames ?? []),
                      alternates.allSatisfy({ alternate in
                          // The converter emits one nonempty clause per clothes
                          // kind. An empty conjunction would make the binding
                          // derivation show an alternate in every wear state.
                          !alternate.meshName.isEmpty && !alternate.switches.isEmpty && alternate.switches.allSatisfy { !$0.isEmpty }
                              && !alternate.activeWhen.isEmpty && alternate.activeWhen.count <= 9
                              && Set(alternate.activeWhen.map(\.kind)).count == alternate.activeWhen.count
                              && alternate.activeWhen.allSatisfy {
                                  (0..<9).contains($0.kind) && !$0.states.isEmpty && $0.states.count <= 4
                                      && Set($0.states).count == $0.states.count && $0.states.allSatisfy { (0...3).contains($0) }
                              }
                      })
                else { throw RigError.invalid("Invalid Maker half-state meshes.") }
            }
            guard entry.alternates != nil || (entry.wearAppearance == nil && entry.wearCardBindings == nil) else {
                throw RigError.invalid("Maker wear appearance requires half-state meshes.")
            }
        }
        var result = Self(sourceURL: url.resolvingSymlinksInPath(), directory: url.deletingLastPathComponent().resolvingSymlinksInPath(), entries: doc.entries, assemblies: doc.assemblies ?? [], entryIndex: index)
        if let presence = doc.catalogPresence {
            // Two assignments, not a tuple: Swift 6.3.3 (CI) does not convert a tuple element to an optional.
            let loaded = try result.presence(presence)
            result.catalogPresence = loaded.ids
            result.catalogSexLimited = loaded.sexLimited
            result.catalogKeptForMissingMod = loaded.keptForMissingMod
            result.installedModGUIDs = loaded.installedMods
        }
        for entry in result.entries {
            for ref in [entry.rig, entry.appearance, entry.cardBindings, entry.bodyMask, entry.materialEvidence,
                        entry.alternateMaterialEvidence, entry.wearAppearance, entry.wearCardBindings].compactMap({ $0 }) { _ = try result.contained(ref) }
        }
        var identities = Set<String>()
        for assembly in result.assemblies {
            guard [0, 1].contains(assembly.sex), assembly.headID >= 0, assembly.exType == 0,
                  identities.insert("\(assembly.sex):\(assembly.headID):\(assembly.exType)").inserted else { throw RigError.invalid("Duplicate or unsupported Maker assembly identity.") }
            _ = try result.contained(assembly.manifest)
        }
        return result
    }
    public func assemblyURL(for identity: SourceCharacterCard.Customization, timings: SourceMakerPreparationTimings? = nil) throws -> URL? {
        guard let entry = assemblies.first(where: { $0.sex == identity.sex && $0.headID == identity.headID && $0.exType == identity.exType }) else { return nil }
        return try verified(entry.manifest, maximumBytes: 1024 * 1024, timings: timings)
    }
    /// Until the assembly registry carries mod GUIDs, a resolver-backed head must
    /// never alias a numerically equal vanilla head. Imported bytes stay intact.
    public static func validateAssemblyIdentity(card: SourceCharacterCard) throws {
        let refs = try card.modReferences()
        guard refs?.records.contains(where: { $0.property.map { Data($0.utf8) } == Data("ChaFileFace.headId".utf8) }) != true else {
            throw RigError.invalid("This card selects a mod head whose assembly conversion is unavailable. Its saved head and mod identities remain unchanged.")
        }
    }
    /// The presence sidecar: contained, SHA-verified (a mismatch is a load
    /// error, as for every other sidecar) and decoded into one set per category.
    private func presence(_ ref: File) throws -> LoadedPresence {
        let url = try verified(ref, maximumBytes: 8 * 1024 * 1024)
        let document = try JSONDecoder().decode(PresenceDocument.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1, document.kind == "koikatsu-catalog-presence" else {
            throw RigError.invalid("Unsupported Maker catalog presence file.")
        }
        var result: [Int: Set<Int>] = [:]
        for (key, ids) in document.categories {
            guard let category = Int(key), Self.catalogDefaultIDs[category] != nil, ids.count <= 1_000_000,
                  ids.allSatisfy({ $0 >= 0 && Int32(exactly: $0) != nil }) else {
                throw RigError.invalid("Invalid Maker catalog presence category \(key).")
            }
            result[category] = Set(ids)
        }
        // Every category is recorded; an empty one is `[]` (the original's
        // work.Count == 0, ChaControl.Koikatu.cs:8679-8683, loads nothing). A
        // missing key would silently keep the reference part instead.
        guard result.count == Self.catalogDefaultIDs.count else {
            throw RigError.invalid("Maker catalog presence must record every hair and clothes category.")
        }
        // A sex-limited row is an installed top or bra row with Sex 2 or 3;
        // anything else is a writer error, not a rule to guess at.
        var limited: [Int: [Int: Set<Int>]] = [:]
        for (key, values) in document.sexLimited ?? [:] {
            guard let category = Int(key), [105, 107].contains(category), let present = result[category], !values.isEmpty else {
                throw RigError.invalid("Invalid Maker catalog sex-limited category \(key).")
            }
            for (valueKey, ids) in values {
                guard let value = Int(valueKey), [2, 3].contains(value), !ids.isEmpty, ids.allSatisfy(present.contains) else {
                    throw RigError.invalid("Invalid Maker catalog sex-limited rows \(key):\(valueKey).")
                }
                limited[category, default: [:]][value] = Set(ids)
            }
        }
        var loaded = LoadedPresence(ids: result, sexLimited: limited)
        for (key, ids) in document.nonNumericMainAB ?? [:] {
            guard let category = Int(key), let present = result[category], !ids.isEmpty, ids.allSatisfy(present.contains) else {
                throw RigError.invalid("Invalid Maker catalog non-numeric bundle rows \(key).")
            }
            loaded.keptForMissingMod[category] = Set(ids)
        }
        if let mods = document.installedMods {
            guard mods.guids.count <= 1_000_000, mods.guids.allSatisfy({ !$0.isEmpty }) else {
                throw RigError.invalid("Invalid Maker catalog installed-mod list.")
            }
            // Ordinal UTF-8 bytes, as resolver GUIDs are compared (`Key`).
            loaded.installedMods = Set(mods.guids.map { Data($0.utf8) })
        }
        return loaded
    }
    private func contained(_ ref: File) throws -> URL {
        let url = directory.appendingPathComponent(ref.file).resolvingSymlinksInPath()
        guard !ref.file.isEmpty, !ref.file.hasPrefix("/"), url.path.hasPrefix(directory.path + "/"),
              ref.sha256.count == 64, ref.sha256.allSatisfy({ $0.isHexDigit }) else { throw RigError.invalid("Invalid Maker library file reference.") }
        return url
    }
    private func verified(_ ref: File, maximumBytes: Int = 128 * 1024 * 1024,
                          timings: SourceMakerPreparationTimings? = nil) throws -> URL {
        let url = try contained(ref)
        let bytes = try SourceMakerPreparationTimings.read(timings, .verifiedFileRead) {
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            return try input.read(upToCount: maximumBytes + 1) ?? Data()
        }
        guard bytes.count <= maximumBytes, SourceMakerPreparationTimings.measure(timings, .verifiedFileSHA, {
            let matches = SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == ref.sha256.lowercased()
            timings?.hashed(bytes.count, phase: .verifiedFileSHA, matches: matches)
            return matches
        }) else { throw RigError.invalid("Changed or oversized converted Maker asset: \(ref.file).") }
        return url
    }
    /// Verified bytes of an entry's converted material evidence, or `nil`
    /// when the library has none for it.
    public func materialEvidenceData(for entry: Entry) throws -> Data? {
        guard let ref = entry.materialEvidence else { return nil }
        return try Data(contentsOf: verified(ref, maximumBytes: 32 * 1024 * 1024))
    }
    /// Verified bytes of an entry's half-state renderer evidence
    /// (`alternates.json`), or `nil` when the library has none for it.
    public func alternateMaterialEvidenceData(for entry: Entry) throws -> Data? {
        guard let ref = entry.alternateMaterialEvidence else { return nil }
        return try Data(contentsOf: verified(ref, maximumBytes: 32 * 1024 * 1024))
    }
    public struct Selection: Sendable {
        public let property: String, category: Int, savedID: Int, sourceID: Int
        public let modGUID: String?, entry: Entry?, status: String
        /// `catalogFallback` only: the catalog ID the original draws instead
        /// (its default, else 0), or nil when it draws nothing. `entry` is
        /// that ID's library entry, nil while that row is unconverted. The
        /// saved ID is kept, a deliberate divergence: the original writes the
        /// drawn ID back into its loaded card (hair ChaControl.Koikatu.cs:7059,
        /// clothes into nowCoordinate :7292 and the other Change*Async sites).
        public var resolvedID: Int? = nil
        /// `catalogFallback` only: why the saved row is not drawn.
        public var fallbackReason: FallbackReason? = nil
        public enum FallbackReason: Sendable, Equatable {
            /// The saved ID is in no installed list (#346).
            case notInstalled
            /// The installed row's Sex column excludes the card's sex (#351):
            /// `value` 2 is not drawn for a female, 3 not for a male.
            case sexLimited(value: Int)
            /// The resolver record's mod `guid` is not installed (#351 item
            /// 3). `keptSlot`: Sideloader kept the saved ID, so the vanilla
            /// row with it is drawn in the mod's slot; otherwise the ID
            /// became 99999999 and the category's default chain applies.
            case missingMod(guid: String, keptSlot: Bool)
        }
        /// `catalogFallback` only: what the original draws, as diagnostics and
        /// pickers show it: "ID n", "ID n (unconverted: reference part
        /// shown)" or "nothing"; a missing mod's kept slot reads "vanilla
        /// ID n in the mod's slot".
        public var drawnDescription: String? {
            guard status == "catalogFallback" else { return nil }
            guard let resolvedID else { return "nothing" }
            var drawn = "ID \(resolvedID)"
            if case .missingMod(_, true) = fallbackReason, resolvedID == savedID { drawn = "vanilla ID \(resolvedID) in the mod's slot" }
            return entry == nil ? drawn + " (unconverted: reference part shown)" : drawn
        }
    }
    /// Why a `catalogFallback` row's saved ID is not drawn, as the
    /// diagnostics word it.
    public static func fallbackCause(_ reason: Selection.FallbackReason?) -> String {
        switch reason {
        case .sexLimited(let value):
            // In effect Sex 3 rows draw only for a female, 2 only for a male (:8706, :8710).
            return value == 3 ? "is a female-only row (Sex 3), which the original does not draw for a male card"
                : "is a male-only row (Sex 2), which the original does not draw for a female card"
        case .missingMod(let guid, let keptSlot):
            return "names mod \(guid), which is not installed; Sideloader " + (keptSlot
                ? "keeps the ID because its vanilla row's MainAB is not numbered"
                : "sets the ID to \(missingModID), which no catalog has")
        case .notInstalled, nil: return "is in no installed catalog"
        }
    }
    /// `sex` is the card's ChaControl.sex (0 male, 1 female), or nil when
    /// unknown: the Sex rule (#351) then excludes nothing.
    public func selection(category: Int, savedID: Int, property: String, references: SourceCardModReferences?,
                          sex: Int?) -> Selection {
        let record = references?.records.first { $0.property.map { Data($0.utf8) } == Data(property.utf8) }
        let id: Int, guid: String?
        if let record {
            guard let value = record.modGUID, !value.isEmpty else {
                return Selection(property: property, category: category, savedID: savedID, sourceID: record.sourceSlot,
                    modGUID: record.modGUID, entry: nil, status: "compatibilityRequired")
            }
            id = record.sourceSlot; guid = value
        } else { id = savedID; guid = nil }
        let entry = entryIndex[Key(category: category, id: id, guid: guid.map { Data($0.utf8) })].map { entries[$0] }
        if guid == nil, let fallback = catalogFallback(category: category, id: id, converted: entry != nil, sex: sex) {
            return Selection(property: property, category: category, savedID: savedID, sourceID: id, modGUID: nil,
                             entry: fallbackEntry(category: category, savedID: savedID, resolved: fallback.resolved),
                             status: "catalogFallback", resolvedID: fallback.resolved, fallbackReason: fallback.reason)
        }
        // #351 item 3: a resolver record whose mod is not installed (and was
        // never converted). Sideloader (UniversalAutoResolver.ResolveStructure)
        // keeps the saved ID when a vanilla row has it and that row's MainAB is
        // not numbered ("matching ID found"); otherwise it sets 99999999, which
        // no catalog has. ChaControl then loads that ID like any vanilla one.
        if let guid, entry == nil, let installed = installedModGUIDs, !installed.contains(Data(guid.utf8)),
           let present = catalogPresence?[category] {
            let kept = present.contains(savedID) && catalogKeptForMissingMod[category]?.contains(savedID) == true
            let loaded = kept ? savedID : Self.missingModID
            // Explicit optional: Swift 6.3.3 (CI) does not promote the mixed ternary.
            var resolved: Int? = loaded
            if let fallback = catalogFallback(category: category, id: loaded, converted: false, sex: sex) { resolved = fallback.resolved }
            return Selection(property: property, category: category, savedID: savedID, sourceID: id, modGUID: guid,
                             entry: fallbackEntry(category: category, savedID: savedID, resolved: resolved),
                             status: "catalogFallback", resolvedID: resolved, fallbackReason: .missingMod(guid: guid, keptSlot: kept))
        }
        return Selection(property: property, category: category, savedID: savedID, sourceID: id, modGUID: guid,
            entry: entry, status: entry == nil ? "conversionMissing" : entry?.empty == true ? "empty" : "converted")
    }
    /// The ID Sideloader gives a missing mod's selection it cannot keep.
    public static let missingModID = 99_999_999
    /// What LoadCharaFbxDataAsync draws instead of vanilla `id`, or nil when it
    /// draws `id` itself (ChaControl.Koikatu.cs:8675-8726).
    /// - #346: an ID that no installed list has (and the library never
    ///   converted) takes the default unless it is that ID, else 0, else
    ///   nothing (:8685-8700).
    /// - #351: an installed top or bra row whose Sex excludes the card's sex
    ///   takes the same chain (:8702-8724). When the ID is the default, the
    ///   original never looks the default up again (:8716) and keeps the
    ///   excluded row (:8720), so it is drawn as saved. The row the chain
    ///   lands on is not checked again.
    private func catalogFallback(category: Int, id: Int, converted: Bool,
                                 sex: Int?) -> (reason: Selection.FallbackReason, resolved: Int?)? {
        guard let present = catalogPresence?[category], let defaultID = Self.catalogDefaultIDs[category] else { return nil }
        let reason: Selection.FallbackReason
        if !present.contains(id) {
            guard !converted else { return nil }
            reason = .notInstalled
        } else if let sex, let value = Self.catalogSexExcludedValue[sex],
                  catalogSexLimited[category]?[value]?.contains(id) == true, id != defaultID {
            reason = .sexLimited(value: value)
        } else { return nil }
        // Explicit optional: Swift 6.3.3 (CI) does not promote the mixed ternary.
        var resolved: Int? = nil
        if id != defaultID && present.contains(defaultID) { resolved = defaultID } else if present.contains(0) { resolved = 0 }
        return (reason, resolved)
    }
    /// The drawn ID's entry, nil while it is unconverted (the reference part
    /// stays), or for nothing an entry assembled as the empty row is, with no part.
    private func fallbackEntry(category: Int, savedID: Int, resolved: Int?) -> Entry? {
        if let resolved { return entryIndex[Key(category: category, id: resolved, guid: nil)].map { entries[$0] } }
        return Entry(category: category, id: savedID, name: "", modGUID: nil, empty: true, rig: nil, appearance: nil,
                     cardBindings: nil, bodyMask: nil, materialEvidence: nil, meshNames: nil, attachment: nil,
                     alternates: nil, alternateMaterialEvidence: nil, wearAppearance: nil, wearCardBindings: nil)
    }
    /// What one saved clothing or accessory selection tells the source about
    /// its catalog row (the ListInfoBase ChaControl reads StateType,
    /// Coordinate, NotBra, HideShorts and HideHair from): the library's
    /// explicit empty entry is the id-0 "none" row (StateType 3, so the kind
    /// is not a clothes-state kind), a converted entry carries its row in the
    /// verified material evidence, and anything else is unknown, never guessed.
    public enum CatalogRow: Sendable, Equatable {
        case none
        case row([String: String])
        case unknown(String)
    }
    public struct WearCatalog: Sendable, Equatable {
        /// One row per ChaFileDefine.ClothesKind (top ... shoes_outer).
        public let clothes: [CatalogRow]
        /// The saved clothes IDs, and whether a resolver record names a mod.
        public let clothesIDs: [Int], clothesModded: [Bool]
        /// Rows of the saved accessory slots (type 121...130 only).
        public let accessories: [Int: CatalogRow]
        public init(clothes: [CatalogRow], clothesIDs: [Int], clothesModded: [Bool], accessories: [Int: CatalogRow]) {
            self.clothes = clothes; self.clothesIDs = clothesIDs; self.clothesModded = clothesModded; self.accessories = accessories
        }
    }
    /// The catalog rows of the outfit's nine clothes kinds and its saved
    /// accessories. Shoes inner and outer both resolve in category 112.
    public func wearCatalog(card: SourceCharacterCard, coordinate: Int) throws -> WearCatalog {
        guard (0..<7).contains(coordinate) else { throw RigError.invalid("Invalid Maker outfit index.") }
        let references = try card.modReferences()
        let sex = (try? card.customization())?.sex
        func row(_ resolution: Selection) throws -> CatalogRow {
            guard let entry = resolution.entry else { return .unknown(resolution.status) }
            if entry.empty == true { return .none }
            guard let evidence = try materialEvidenceData(for: entry) else { return .unknown("no catalog evidence") }
            struct Evidence: Decodable { let catalog: [String: String]? }
            let decoded = try JSONDecoder().decode(Evidence.self, from: evidence)
            return decoded.catalog.map(CatalogRow.row) ?? .unknown("no catalog evidence")
        }
        let parts = try card.recordFields(.clothes(coordinate: coordinate))["parts"]?.arrayValue ?? []
        guard parts.count <= 9 else { throw RigError.invalid("Unsupported clothes array.") }
        var clothes: [CatalogRow] = [], ids: [Int] = [], modded: [Bool] = []
        for slot in 0..<9 {
            guard slot < parts.count else { clothes.append(.unknown("not saved")); ids.append(0); modded.append(false); continue }
            guard let id = try parts[slot].stringKeyedMap()["id"]?.integerValue, Int32(exactly: id) != nil else {
                throw RigError.invalid("Missing or invalid Maker selection id.")
            }
            let property = "outfit\(coordinate).ChaFileClothes.Clothes" + ["Top", "Bot", "Bra", "Shorts", "Gloves", "Pants", "Socks", "ShoesInner", "ShoesOuter"][slot]
            let resolution = selection(category: min(105 + slot, 112), savedID: id, property: property, references: references, sex: sex)
            clothes.append(try row(resolution)); ids.append(id)
            modded.append(resolution.modGUID != nil || resolution.status == "compatibilityRequired")
        }
        var accessories: [Int: CatalogRow] = [:]
        let accessoryParts = try card.recordFields(.accessory(coordinate: coordinate))["parts"]?.arrayValue ?? []
        guard accessoryParts.count <= 20 else { throw RigError.invalid("Accessory preview supports the original 20-slot array.") }
        for (slot, part) in accessoryParts.enumerated() {
            let fields = try part.stringKeyedMap()
            guard let category = fields["type"]?.integerValue, (121...130).contains(category),
                  let id = fields["id"]?.integerValue, Int32(exactly: id) != nil else { continue }
            accessories[slot] = try row(selection(category: category, savedID: id,
                property: "outfit\(coordinate).accessory\(slot).ChaFileAccessory.PartsInfo.id", references: references, sex: sex))
        }
        return WearCatalog(clothes: clothes, clothesIDs: ids, clothesModded: modded, accessories: accessories)
    }
    fileprivate struct MaterialComponent: Sendable, Equatable {
        let appearance: URL, bindings: URL?, meshNames: Set<String>, prefix: String, accessorySlot: Int?
        let clothingSlot: Int?
        /// The indoor-shoe copy of a category 112 entry, whose recipes bind
        /// the outdoor slot (8) and are rebound to slot 7.
        var indoorShoes = false
        /// #346: a catalogFallback row, drawn from the resolved ID's entry
        /// while the card keeps the saved ID.
        var catalogFallback: CatalogFallback? = nil
        struct CatalogFallback: Sendable, Equatable {
            /// The slot-ID card path the entry's requirements name, such as
            /// "hair.parts.0.id" or "clothes.parts.7.id".
            let requirement: String, savedID: Int, resolvedID: Int
        }
        /// The catalog bindings as this component binds them, the same for
        /// prepared and direct application: slot-0 accessory keys moved to
        /// its slot, shoe keys moved to the indoor slot, and a fallback row's
        /// slot-ID requirement evaluated against the drawn ID.
        func contextualizing(_ input: SourceAppearanceBindings) throws -> SourceAppearanceBindings {
            var value = input
            if let accessorySlot { value = try value.contextualized(accessorySlot: accessorySlot) }
            if indoorShoes { value = try value.contextualizedIndoorShoes() }
            if let catalogFallback {
                value = value.resolvingCatalogFallback(requirement: catalogFallback.requirement,
                    savedID: catalogFallback.savedID, resolvedID: catalogFallback.resolvedID)
            }
            return value
        }
    }
    /// How a Studio wear assembly resolved the indoor shoes (clothes kind 7).
    public enum IndoorShoes: Sendable, Equatable {
        /// Converted and assembled as its own garment.
        case assembled
        /// The selection is the catalog's empty row: shoesType 0 draws no shoe.
        case empty
        /// Not assembled: a Maker assembly, or a selection without a conversion.
        case unconverted
    }
    public struct Prepared: Sendable {
        public let source: SourceRig, selections: [Selection], diagnostics: [String]
        /// ClothesKind of each assembled clothing component, in the order the
        /// assembly prefixes them ("clothes-0/", "clothes-1/", ...).
        public let clothingSlots: [Int]
        /// Clothing kinds rendered by the base avatar's reference geometry
        /// because the card's selection has no conversion.
        public let referenceClothingSlots: Set<Int>
        /// The indoor shoes of a Studio wear assembly; `.unconverted` for Maker.
        public let indoorShoes: IndoorShoes
        fileprivate let components: [MaterialComponent]
        fileprivate let bodyMask: URL?
        fileprivate let clearBodyMask: Bool
        public var geometryChanged: Bool { selections.contains { $0.entry != nil } }
        /// CPU-only input snapshots are scoped to this exact assembly/component
        /// context. The candidate owns them until its commit/cancellation ends;
        /// rendered appearances retain only the resulting GPU texture leases.
        public struct AppearanceInputs: Sendable {
            fileprivate struct Binding: Sendable {
                let url: URL, value: SourceAppearanceBindings, pixels: SourceAppearanceInputs
            }
            fileprivate let baseURL: URL, components: [MaterialComponent]
            fileprivate let base: Binding?, componentBindings: [Binding?]
            public let byteCount: Int
            public var perCallByteCounts: [Int] { [base?.pixels.byteCount ?? 0] + componentBindings.map { $0?.pixels.byteCount ?? 0 } }

            public func applyingBase(to appearance: SourcePreviewAppearance, card: SourceCardAppearance, baseURL: URL,
                                     resources: ResourceStore, timings: SourceAppearanceTimings? = nil) throws -> SourcePreviewAppearance.CardApplication? {
                guard self.baseURL == baseURL.standardizedFileURL else {
                    throw RigError.invalid("Prepared appearance inputs belong to a different base assembly.")
                }
                guard let base else { return nil }
                return try SourceAppearanceTimings.scoped(timings, .base) {
                    try appearance.applying(card, bindings: base.value, directory: base.url.deletingLastPathComponent(),
                        resources: resources, timings: timings, preparedInputs: base.pixels)
                }
            }
        }

        public func prepareAppearanceInputs(card: SourceCardAppearance, baseURL: URL,
                                            maximumBytes: Int = 128 * 1024 * 1024, timings: SourceMakerPreparationTimings? = nil) throws -> AppearanceInputs {
            guard (0...128 * 1024 * 1024).contains(maximumBytes) else {
                throw RigError.invalid("Invalid prepared appearance candidate byte limit.")
            }
            var totalBytes = 0
            func prepare(_ url: URL, transform: (SourceAppearanceBindings) throws -> SourceAppearanceBindings) throws -> AppearanceInputs.Binding {
                let bindings = try transform(SourceAppearanceBindings.load(url: url, timings: timings))
                let pixels = try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: url.deletingLastPathComponent(),
                    maximumBytes: maximumBytes - totalBytes, timings: timings)
                totalBytes += pixels.byteCount
                guard totalBytes <= maximumBytes else {
                    throw RigError.invalid("Prepared appearance inputs exceed their candidate byte limit.")
                }
                return .init(url: url, value: bindings, pixels: pixels)
            }
            let baseBindingsURL = baseURL.deletingPathExtension().appendingPathExtension("card-appearance.json")
            let base: AppearanceInputs.Binding?
            if FileManager.default.fileExists(atPath: baseBindingsURL.path) {
                base = try prepare(baseBindingsURL) { $0.restricted(to: Set(source.parts.map { $0.mesh.name })) }
            } else { base = nil }
            let values = try components.map { component -> AppearanceInputs.Binding? in
                guard let url = component.bindings else { return nil }
                return try prepare(url) { try component.contextualizing($0) }
            }
            return AppearanceInputs(baseURL: baseURL.standardizedFileURL, components: components, base: base,
                componentBindings: values, byteCount: totalBytes)
        }

        public func appearance(base: SourcePreviewAppearance?, card: SourceCardAppearance, resources: ResourceStore,
                               modLibrary: SourceModLibrary?, transaction: SourceAppearanceLoadTransaction? = nil,
                               timings: SourceAppearanceTimings? = nil, inputs: AppearanceInputs? = nil,
                               batchClothes: Bool = false) throws -> SourcePreviewAppearance.CardApplication? {
            guard inputs == nil || (inputs?.components == components && inputs?.componentBindings.count == components.count) else {
                throw RigError.invalid("Prepared appearance inputs belong to different selected components.")
            }
            var combined = base, fields = Set<String>(), messages = diagnostics
            let group = batchClothes ? SourceClothesMaterialGroup(resources: resources, timings: timings) : nil
            func merge(_ appearance: SourcePreviewAppearance, component: MaterialComponent) {
                let renamed = appearance.renaming(component.meshNames, prefix: component.prefix)
                combined = combined.map { $0.merging(renamed) } ?? renamed
            }
            func merge(_ completed: [SourceClothesMaterialGroup.Completed]) {
                for item in completed {
                    fields.formUnion(item.application.appliedFields); messages += item.application.diagnostics
                    merge(item.application.appearance, component: components[item.identity.index])
                }
            }
            for (index, component) in components.enumerated() {
                let grouped = group != nil && component.clothingSlot != nil
                if !grouped { merge(try group?.finish() ?? []) }
                func prepareComponent() throws -> SourcePreparedMetalCardApplication? {
                    try SourceAppearanceTimings.scoped(timings, .component(index: index, prefix: component.prefix,
                        accessorySlot: component.accessorySlot, indoorShoes: component.indoorShoes)) {
                        var appearance = try SourceAppearanceTimings.measure(timings, .componentLoad) {
                            try SourcePreviewAppearance.load(url: component.appearance, resources: resources, modLibrary: modLibrary,
                                transaction: transaction)
                        }
                        if let url = component.bindings {
                            let bindings = try SourceAppearanceTimings.measure(timings, .bindingPreparation) {
                                if let inputs {
                                    guard let prepared = inputs.componentBindings[index], prepared.url == url else {
                                        throw RigError.invalid("Prepared component appearance binding is missing or mismatched.")
                                    }
                                    return prepared.value
                                }
                                return try component.contextualizing(SourceAppearanceBindings.load(url: url))
                            }
                            if grouped {
                                return try appearance.prepareMetalApplication(card, bindings: bindings, directory: url.deletingLastPathComponent(),
                                    timings: timings, preparedInputs: inputs?.componentBindings[index]?.pixels)
                            }
                            let applied = try appearance.applying(card, bindings: bindings, directory: url.deletingLastPathComponent(), resources: resources,
                                timings: timings, preparedInputs: inputs?.componentBindings[index]?.pixels)
                            appearance = applied.appearance; fields.formUnion(applied.appliedFields); messages += applied.diagnostics
                        }
                        if grouped {
                            // A garment without bindings must still preserve merge order.
                            return .init(source: appearance, recipes: [], replays: [], diagnostics: [],
                                maximumLogicalInputBytes: SourceMaterialMetalInputBudget.defaultMaximumBytes)
                        }
                        merge(appearance, component: component)
                        return nil
                    }
                }
                let plan: SourcePreparedMetalCardApplication?
                if let group { plan = try group.preparing(prepareComponent) }
                else { plan = try prepareComponent() }
                if let plan, let group, let slot = component.clothingSlot {
                    merge(try group.append(plan, identity: .init(index: index, slot: slot, prefix: component.prefix)))
                }
            }
            merge(try group?.finish() ?? [])
            if let mask = bodyMask, let current = combined {
                combined = try SourceAppearanceTimings.scoped(timings, .bodyMaskLoad) {
                    try SourceAppearanceTimings.measure(timings, .bodyMaskLoad) {
                        try current.replacingBodyMask(data: Data(contentsOf: mask), resources: resources)
                    }
                }
            } else if clearBodyMask, let current = combined {
                combined = SourceAppearanceTimings.scoped(timings, .bodyMaskRemove) { current.removingBodyMask() }
            }
            guard let combined else { return nil }
            return .init(appearance: combined, appliedFields: fields, diagnostics: messages)
        }
    }
    /// `wear` (CharaStudio) also assembles each converted garment's
    /// half-state meshes with its wear appearance, and the converted indoor
    /// shoes as clothing kind 7; UpdateVisible then selects among them per
    /// clothes state and shoesType. The Maker assembly (`wear` false) keeps
    /// only the fully dressed meshes and the outdoor shoes.
    public func prepare(card: SourceCharacterCard, coordinate: Int, baseURL: URL, wear: Bool = false, timings: SourceMakerPreparationTimings? = nil) throws -> Prepared {
        try prepare(card: card, coordinate: coordinate, baseURL: baseURL, wear: wear, timings: timings, rigReuse: nil)
    }
    /// Explicit initial-session opt-in. The caller keeps the prospective token
    /// and publishes this candidate only after all owner load gates succeed.
    /// A thrown preparation returns no partial candidate. Nil adds no worker,
    /// actual-byte hashing or ledger work to the existing preparation path.
    public func prepare(card: SourceCharacterCard, coordinate: Int, baseURL: URL, wear: Bool = false,
                        timings: SourceMakerPreparationTimings? = nil, seeding input: SourceMakerRigReuse.Input?) throws
        -> (prepared: Prepared, candidate: SourceMakerRigReuse.Candidate?, sample: SourceMakerRigReuse.Sample?) {
        let worker = input.map(SourceRigReuseWorker.init)
        let prepared = try prepare(card: card, coordinate: coordinate, baseURL: baseURL,
                                   wear: wear, timings: timings, rigReuse: worker)
        let finished = worker?.finish()
        return (prepared, finished?.0, finished?.1)
    }
    /// The same preparation with every converted rig file decoded through
    /// `rigs` (R7 phase 2 item 6): a Studio batch decodes each distinct file
    /// once across its characters. The result equals the unshared `prepare`.
    public func prepare(card: SourceCharacterCard, coordinate: Int, baseURL: URL, wear: Bool,
                        sharing rigs: SourceRigDecodeShare) throws -> Prepared {
        try prepare(card: card, coordinate: coordinate, baseURL: baseURL, wear: wear, timings: nil, rigReuse: rigs)
    }
    /// The converted rig files `prepare` decodes for this card and outfit,
    /// in its order, found without reading, verifying or decoding any of
    /// them (R7 phase 2 item 6 follow-up): the converted hair, clothes and
    /// accessory selections, the base hair and clothes those leave, then the
    /// base skeletons, body and head. A hint for starting the decodes early
    /// (`SourceRigDecodeShare.prefetch`); `prepare` still selects, verifies
    /// and reads every file itself, so a list that misses or adds a file
    /// costs time, never a different result. A card or manifest `prepare`
    /// would reject gives the files found before the problem.
    public func rigFiles(card: SourceCharacterCard, coordinate: Int, baseURL: URL, wear: Bool) -> [URL] {
        var files: [URL] = []
        func add(_ url: URL?) { if let url, !files.contains(url) { files.append(url) } }
        let references: SourceCardModReferences?
        do { references = try card.modReferences() } catch { return [] }
        let sex = (try? card.customization())?.sex
        guard (0..<7).contains(coordinate), let bytes = try? Data(contentsOf: baseURL),
              let manifest = try? JSONDecoder().decode(SourceAvatarManifest.self, from: bytes) else { return [] }
        let folder = baseURL.deletingLastPathComponent().resolvingSymlinksInPath()
        func component(_ path: String) -> URL? {
            let url = folder.appendingPathComponent(path).resolvingSymlinksInPath()
            return !path.hasPrefix("/") && url.path.hasPrefix(folder.path + "/") ? url : nil
        }
        var referenceHair: [Int: String] = [:], referenceClothes: [Int: String] = [:]
        for (i, part) in manifest.hair.enumerated() { referenceHair[part.slot ?? i] = part.file }
        for (i, part) in manifest.clothes.enumerated() where i < 3 || part.slot != nil { referenceClothes[part.slot ?? [0, 1, 8][i]] = part.file }
        func ids(_ fields: [String: SourceMessagePackValue]?, limit: Int) -> [(slot: Int, fields: [String: SourceMessagePackValue])] {
            guard let parts = fields?["parts"]?.arrayValue, parts.count <= limit else { return [] }
            return parts.enumerated().compactMap { slot, part in (try? part.stringKeyedMap()).map { (slot, $0) } }
        }
        /// The selection's converted rig, if any; true when a library entry
        /// (converted or explicitly empty) replaces the base part.
        func selected(_ category: Int, _ fields: [String: SourceMessagePackValue], _ property: String) -> Bool {
            guard let id = fields["id"]?.integerValue,
                  let entry = selection(category: category, savedID: id, property: property, references: references, sex: sex).entry else { return false }
            if entry.empty != true, let rig = entry.rig { add(try? contained(rig)) }
            return true
        }
        let hairNames = ["HairBack", "HairFront", "HairSide", "HairOption"]
        for (slot, fields) in ids(try? card.recordFields(.hair), limit: 4) where selected(101 + slot, fields, "ChaFileHair." + hairNames[slot]) {
            referenceHair[slot] = nil
        }
        let clothesNames = ["Top", "Bot", "Bra", "Shorts", "Gloves", "Pants", "Socks", "ShoesInner", "ShoesOuter"]
        for (slot, fields) in ids(try? card.recordFields(.clothes(coordinate: coordinate)), limit: 9) where slot != 7 || wear {
            if selected(min(105 + slot, 112), fields, "outfit\(coordinate).ChaFileClothes.Clothes" + clothesNames[slot]) { referenceClothes[slot] = nil }
        }
        for (slot, fields) in ids(try? card.recordFields(.accessory(coordinate: coordinate)), limit: 20) {
            guard let category = fields["type"]?.integerValue, (121...130).contains(category) else { continue }
            _ = selected(category, fields, "outfit\(coordinate).accessory\(slot).ChaFileAccessory.PartsInfo.id")
        }
        for slot in referenceHair.keys.sorted() { add(component(referenceHair[slot]!)) }
        for slot in referenceClothes.keys.sorted() { add(component(referenceClothes[slot]!)) }
        for path in [manifest.bodySkeleton, manifest.headSkeleton, manifest.body.file, manifest.head.file] { add(component(path)) }
        return files
    }
    func prepare(card: SourceCharacterCard, coordinate: Int, baseURL: URL, wear: Bool,
                 timings: SourceMakerPreparationTimings?, rigReuse: (any SourceRigDecoding)?) throws -> Prepared {
        guard (0..<7).contains(coordinate) else { throw RigError.invalid("Invalid Maker outfit index.") }
        try Self.validateAssemblyIdentity(card: card)
        let manifestBytes = try SourceMakerPreparationTimings.read(timings, .libraryManifestRead) { try Data(contentsOf: baseURL) }
        let manifest = try SourceMakerPreparationTimings.measure(timings, .libraryManifestDecode) {
            try JSONDecoder().decode(SourceAvatarManifest.self, from: manifestBytes)
        }
        let identity = try card.customization()
        guard identity.sex == (manifest.sex ?? (manifest.kind == "koikatsu-male-avatar" ? 0 : 1)),
              identity.headID == (manifest.headID ?? 0), identity.exType == 0 else {
            throw RigError.invalid("Selected card and base assembly identities differ.")
        }
        let folder = baseURL.deletingLastPathComponent().resolvingSymlinksInPath()
        func componentURL(_ path: String) throws -> URL {
            let url = folder.appendingPathComponent(path).resolvingSymlinksInPath()
            guard !path.hasPrefix("/"), url.path.hasPrefix(folder.path + "/") else { throw RigError.invalid("Base component escapes its folder.") }
            return url
        }
        // Identical to SourceRig.load: Data(contentsOf:) then decode (which also
        // validates and converts the rig). Resolve each URL before its read.
        func loadRig(_ url: URL) throws -> SourceRig {
            let bytes = try SourceMakerPreparationTimings.read(timings, .rigRead) { try Data(contentsOf: url) }
            if let rigReuse { return try rigReuse.decode(bytes, timings: timings) }
            return try SourceMakerPreparationTimings.measure(timings, .rigDecode) { try SourceRig.decode(bytes) }
        }
        func base(_ path: String) throws -> SourceRig { try loadRig(componentURL(path)) }
        let references = try card.modReferences()
        var selections: [Selection] = [], diagnostics: [String] = [], materials: [MaterialComponent] = []
        var bodyMask: URL?, clearBodyMask = false
        // Legacy reference manifests explicitly selected these three garments.
        // New manifests carry slots instead of inferring them from filenames.
        guard manifest.clothes.count == 3 || manifest.clothes.allSatisfy({ $0.slot != nil }), manifest.hair.count <= 4 else {
            throw RigError.invalid("Base avatar requires explicit clothing slot metadata.")
        }
        var hairBySlot: [Int: (SourceRig, [String]?)] = [:], clothesBySlot: [Int: (SourceRig, [String]?)] = [:]
        // Validate every reference path and slot, but parse its geometry only
        // if the resolved selection still needs that fallback. Converted and
        // explicit-empty selections otherwise discarded these expensive loads.
        var referenceHair: [Int: (URL, [String]?)] = [:], referenceClothes: [Int: (URL, [String]?)] = [:]
        for (i, part) in manifest.hair.enumerated() {
            let slot = part.slot ?? i
            guard (0..<4).contains(slot), referenceHair[slot] == nil else { throw RigError.invalid("Invalid or duplicate base hair slot.") }
            referenceHair[slot] = (try componentURL(part.file), part.meshNames)
        }
        for (i, part) in manifest.clothes.enumerated() {
            let slot = part.slot ?? [0, 1, 8][i]
            guard (0..<9).contains(slot), referenceClothes[slot] == nil else { throw RigError.invalid("Invalid or duplicate base clothing slot.") }
            referenceClothes[slot] = (try componentURL(part.file), part.meshNames)
        }
        func integer(_ fields: [String: SourceMessagePackValue], _ name: String) throws -> Int {
            guard let value = fields[name]?.integerValue, Int32(exactly: value) != nil else { throw RigError.invalid("Missing or invalid Maker selection \(name).") }
            return value
        }
        /// `slotPath` is the card path of the slot's ID ("hair.parts.0.id"),
        /// which the entry's bindings name as a requirement.
        func selected(_ category: Int, _ id: Int, _ property: String, _ prefix: String, accessorySlot: Int? = nil,
                      indoorShoes: Bool = false, clothingSlot: Int? = nil, slotPath: String? = nil) throws -> (SourceRig, [String]?)? {
            let resolution = selection(category: category, savedID: id, property: property, references: references, sex: identity.sex)
            selections.append(resolution)
            if let drawn = resolution.drawnDescription {
                diagnostics.append("\(property): catalogFallback, source ID \(resolution.sourceID) \(Self.fallbackCause(resolution.fallbackReason)), so the original draws \(drawn). The saved ID is kept, unlike the original, which writes the drawn ID back.")
            }
            guard let entry = resolution.entry else {
                // An unconverted fallback row was diagnosed above.
                if resolution.status != "catalogFallback" {
                    diagnostics.append("\(property): \(resolution.status), source ID \(resolution.sourceID). Card identity preserved; reference geometry retained where available.")
                }
                return nil
            }
            guard entry.empty != true else { return nil }
            // The indoor shoes never replace the top's body cut-out.
            if !indoorShoes, let mask = entry.bodyMask { bodyMask = try verified(mask, maximumBytes: 32 * 1024 * 1024, timings: timings) }
            guard let rigFile = entry.rig else { throw RigError.invalid("Converted Maker geometry is absent.") }
            let rig = try loadRig(verified(rigFile, timings: timings))
            // Half-state meshes join only with their wear appearance (or when
            // the whole garment is neutral), never as unmaterialed parts.
            let halfStates = wear && entry.alternates != nil && (entry.appearance == nil || entry.wearAppearance != nil)
            // A fallback row binds the card's colors as the original does after
            // writing the drawn ID back (ChaControl.Koikatu.cs:7059 hair, :7292
            // clothes): its slot-ID requirement is checked against that ID.
            var fallback: MaterialComponent.CatalogFallback? = nil
            if let resolved = resolution.resolvedID, let slotPath {
                fallback = MaterialComponent.CatalogFallback(requirement: slotPath, savedID: id, resolvedID: resolved)
            }
            if let file = halfStates ? entry.wearAppearance ?? entry.appearance : entry.appearance {
                let bindings = halfStates ? entry.wearCardBindings ?? entry.cardBindings : entry.cardBindings
                materials.append(.init(appearance: try verified(file, maximumBytes: 1024 * 1024, timings: timings),
                    bindings: try bindings.map { try verified($0, maximumBytes: 1024 * 1024, timings: timings) },
                    meshNames: Set(rig.parts.map { $0.mesh.name }), prefix: prefix, accessorySlot: accessorySlot,
                    clothingSlot: clothingSlot, indoorShoes: indoorShoes, catalogFallback: fallback))
            } else { diagnostics.append("\(property): converted geometry has a neutral material; shader conversion is missing.") }
            return (rig.namespacingMeshes(prefix), halfStates ? entry.meshNames.map { $0 + entry.alternates!.map(\.meshName) } : entry.meshNames)
        }
        let hairFields = try card.recordFields(.hair)
        guard let hairParts = hairFields["parts"]?.arrayValue, hairParts.count <= 4 else { throw RigError.invalid("Unsupported hair part array.") }
        for (slot, part) in hairParts.enumerated() {
            let id = try integer(part.stringKeyedMap(), "id"), property = "ChaFileHair." + ["HairBack", "HairFront", "HairSide", "HairOption"][slot]
            let value = try selected(101 + slot, id, property, "hair-\(slot)/", slotPath: "hair.parts.\(slot).id")
            if selections.last?.entry != nil { hairBySlot[slot] = value; referenceHair[slot] = nil }
        }
        let clothesFields = try card.recordFields(.clothes(coordinate: coordinate))
        guard let parts = clothesFields["parts"]?.arrayValue, parts.count <= 9 else { throw RigError.invalid("Unsupported clothes array.") }
        var indoorShoes = IndoorShoes.unconverted
        for (slot, part) in parts.enumerated() where slot != 7 || wear {
            let id = try integer(part.stringKeyedMap(), "id")
            let property = "outfit\(coordinate).ChaFileClothes.Clothes" + ["Top", "Bot", "Bra", "Shorts", "Gloves", "Pants", "Socks", "ShoesInner", "ShoesOuter"][slot]
            let value = try selected(min(105 + slot, 112), id, property, "clothes-\(slot)/", indoorShoes: slot == 7, clothingSlot: slot,
                                     slotPath: "clothes.parts.\(slot).id")
            if selections.last?.entry != nil { clothesBySlot[slot] = value; referenceClothes[slot] = nil }
            if slot == 0, selections.last?.entry?.empty == true { clearBodyMask = true }
            if slot == 7, let entry = selections.last?.entry { indoorShoes = entry.empty == true ? .empty : .assembled }
        }
        if wear {
            diagnostics.append("Converted clothing assembles the dressed and half-state meshes and both shoe slots; the saved clothes state and shoesType select among them.")
        } else {
            diagnostics.append("Converted clothing assembles the outdoor shoes and only the fully-dressed meshes; the saved clothes state is preserved (Studio renders it on these meshes, the Maker preview does not).")
        }
        let accessoryFields = try card.recordFields(.accessory(coordinate: coordinate))
        guard let parts = accessoryFields["parts"]?.arrayValue, parts.count <= 20 else { throw RigError.invalid("Accessory preview supports the original 20-slot array.") }
        var accessories: [SourceAvatar.Accessory] = []
        for (slot, part) in parts.enumerated() {
            let fields = try part.stringKeyedMap(), category = try integer(fields, "type")
            guard (121...130).contains(category) else { continue }
            let id = try integer(fields, "id"), property = "outfit\(coordinate).accessory\(slot).ChaFileAccessory.PartsInfo.id"
            guard let (rig, meshes) = try selected(category, id, property, "accessory-\(slot)/", accessorySlot: slot),
                  let attachment = selections.last?.entry?.attachment else { continue }
            let savedParent = fields["parentKey"]?.stringValue ?? "", parent = savedParent.isEmpty ? attachment.parent : savedParent
            guard attachment.parent != "0", attachment.parent != "null", attachment.moveNodes.count <= 2,
                  attachment.positionScale == 0.01 else { throw RigError.invalid("Unsupported accessory attachment behavior.") }
            accessories.append(.init(source: rig, parent: parent, slot: slot, meshNames: meshes,
                overrides: try SourceAccessoryMove.overrides(fields: fields, rig: rig, attachment: attachment)))
        }
        for slot in referenceHair.keys.sorted() {
            let (url, meshes) = referenceHair[slot]!
            hairBySlot[slot] = (try loadRig(url), meshes)
        }
        for slot in referenceClothes.keys.sorted() {
            let (url, meshes) = referenceClothes[slot]!
            clothesBySlot[slot] = (try loadRig(url), meshes)
        }
        let hair = hairBySlot.keys.sorted().compactMap { hairBySlot[$0] }, clothes = clothesBySlot.keys.sorted().compactMap { clothesBySlot[$0] }
        let convertedSlots = Set(selections.filter { $0.entry != nil && $0.property.contains(".ChaFileClothes.Clothes") }.compactMap { selection in
            ["Top", "Bot", "Bra", "Shorts", "Gloves", "Pants", "Socks", "ShoesInner", "ShoesOuter"].firstIndex { selection.property.hasSuffix(".ChaFileClothes.Clothes" + $0) }
        })
        // Preserve the original argument-evaluation order; assembly excludes reads/decode.
        let bodySkeleton = try base(manifest.bodySkeleton), headSkeleton = try base(manifest.headSkeleton)
        let body = try base(manifest.body.file), head = try base(manifest.head.file)
        let source = try SourceMakerPreparationTimings.measure(timings, .assembly) {
            try SourceAvatar.assemble(name: manifest.name, bodySkeleton: bodySkeleton, headSkeleton: headSkeleton,
                body: body, head: head, clothes: clothes.map(\.0), hair: hair.map(\.0),
                bodyMeshNames: manifest.body.meshNames, headMeshNames: manifest.head.meshNames,
                clothingMeshNames: clothes.map(\.1), hairMeshNames: hair.map(\.1), accessories: accessories)
        }
        return Prepared(source: source, selections: selections, diagnostics: diagnostics,
            clothingSlots: clothesBySlot.keys.sorted(), referenceClothingSlots: Set(clothesBySlot.keys).subtracting(convertedSlots),
            indoorShoes: indoorShoes, components: materials, bodyMask: bodyMask, clearBodyMask: clearBodyMask)
    }
}

/// A card import's geometry (CXM1, #192). The card's selected assets replace
/// the whole reference model, so the reference model is read and decoded only
/// on a fallback path: no card, no Maker library, or a selected preparation
/// that throws. Before CXM1 the Maker decoded the reference model (nine files,
/// 32 MB of JSON for the female base) ahead of every import and discarded it
/// when the selection succeeded; `prepare` itself already skips parsing the
/// reference parts the selection replaces. A thrown selection still ends in
/// the reference model's own error when that model cannot load either.
public enum SourceMakerImportGeometry {
    public enum Outcome: String, Sendable, Encodable {
        case selectedAssets, referenceAfterSelectionFailure, referenceNoLibrary, referenceNoCard
    }
    public struct Loaded {
        public let source: SourceRig
        public let prepared: SourceMakerLibrary.Prepared?
        public let outcome: Outcome
        /// The selected preparation's error, for the reference fallback's diagnostic.
        public let selectionError: (any Error)?
        /// The staged seed of a successful seeded preparation; a thrown
        /// preparation stages none.
        public let rigReuseCandidate: SourceMakerRigReuse.Candidate?
        public let rigReuseSample: SourceMakerRigReuse.Sample?
        public var referenceLoaded: Bool { outcome != .selectedAssets }
    }
    public static func load(baseURL: URL, card: SourceCharacterCard?, library: SourceMakerLibrary?, coordinate: Int,
                            timings: SourceMakerPreparationTimings? = nil,
                            seeding: SourceMakerRigReuse.Input? = nil) throws -> Loaded {
        var selectionError: (any Error)?
        if let card, let library {
            do {
                // The reference model's manifest gate (SourceAvatar.load) still
                // applies; its failure falls back, so the import fails as before.
                try JSONDecoder().decode(SourceAvatarManifest.self, from: Data(contentsOf: baseURL)).validated()
                let selected = try library.prepare(card: card, coordinate: coordinate, baseURL: baseURL,
                                                   timings: timings, seeding: seeding)
                return Loaded(source: selected.prepared.source, prepared: selected.prepared, outcome: .selectedAssets,
                    selectionError: nil, rigReuseCandidate: selected.candidate, rigReuseSample: selected.sample)
            } catch { selectionError = error }
        }
        let source = try SourceRig.loadModel(url: baseURL)
        let outcome: Outcome = card == nil ? .referenceNoCard : library == nil ? .referenceNoLibrary : .referenceAfterSelectionFailure
        return Loaded(source: source, prepared: nil, outcome: outcome, selectionError: selectionError,
                      rigReuseCandidate: nil, rigReuseSample: nil)
    }
}

private enum SourceAccessoryMove {
    static func overrides(fields: [String: SourceMessagePackValue], rig: SourceRig,
                          attachment: SourceMakerLibrary.Attachment) throws -> [String: RigDefinition.Node] {
        guard let encoded = fields["addMove"]?.arrayValue, encoded.count == 3, encoded[0].integerValue == 2,
              encoded[1].integerValue == 3, let vectors = encoded[2].arrayValue, vectors.count == 6 else {
            throw RigError.invalid("Accessory addMove requires the original 2×3 Vector3 array.")
        }
        func vector(_ index: Int) throws -> Float3 {
            guard let values = vectors[index].arrayValue, values.count == 3 else { throw RigError.invalid("Invalid accessory vector.") }
            let numbers = try values.map { value -> Float in
                let result: Float
                switch value { case .float(let v): result = Float(v); case .integer(let v): result = Float(v); default: throw RigError.invalid("Invalid accessory numeric value.") }
                guard result.isFinite, abs(result) <= 100_000 else { throw RigError.invalid("Accessory move is outside the finite native range.") }
                return result
            }
            return Float3(numbers)
        }
        let moves = try (0..<6).map(vector)
        var result: [String: RigDefinition.Node] = [:]
        for (i, name) in attachment.moveNodes.enumerated() {
            let matches = rig.rig.nodes.indices.filter { rig.rig.nodes[$0].name == name }
            guard matches.count <= 1 else { throw RigError.invalid("Ambiguous accessory move node.") }
            guard let index = matches.first else { continue } // source skips null correction transforms
            let original = rig.rig.nodes[index]
            let position = moves[i * 3], rotation = moves[i * 3 + 1], scale = moves[i * 3 + 2]
            let ignore = attachment.ignoreMoves == true
            result[name] = .init(name: name, sourceID: original.sourceID, parent: original.parent,
                translation: ignore ? .zero : UnityCoordinates.position(position * attachment.positionScale),
                rotation: ignore ? .init() : UnityCoordinates.eulerDegrees(rotation), scale: ignore ? .one : scale, active: original.active)
        }
        return result
    }
}
