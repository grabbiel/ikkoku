import Foundation
import CryptoKit
import Assets

/// The saved UniversalAutoResolver identities. No managed code is executed and
/// no runtime LocalSlot is used as a native asset identity.
public struct SourceCardModReferences: Sendable {
    /// The installed source hook prefers the EC marker even in a Koikatsu card.
    public static let pluginIDs = ["EC.Core.Sideloader.UniversalAutoResolver",
                                   "com.bepis.sideloader.universalautoresolver"]
    public struct Record: Sendable {
        public let index: Int, modGUID: String?, sourceSlot: Int, localSlot: Int
        public let property: String?, category: Int
        public let author: String?, website: String?, name: String?
        public let preservedData: Data, sourceSHA256: String
    }
    /// A destination read from the actual Custom/Coordinate structure, not from
    /// a resolver record's advisory CategoryNo field.
    public struct Destination: Sendable, Equatable {
        public let property: String, catalogProperty: String, category: Int, sourceSlot: Int
        public init(property: String, catalogProperty: String, category: Int, sourceSlot: Int) {
            self.property = property; self.catalogProperty = catalogProperty
            self.category = category; self.sourceSlot = sourceSlot
        }
    }
    public struct Resolution: Sendable {
        public let record: Record, status: String, destination: Destination?
        public let entry: SourceModCatalog.Entry?, dependencies: [SourceModCatalog.Dependency]
    }
    public struct Report: Sendable {
        public let pluginID: String?, pluginVersion: Int?
        public let resolutions: [Resolution], diagnostics: [String]
    }
    public let pluginID: String, pluginVersion: Int, records: [Record], diagnostics: [String]

    public static func decode(from extensions: SourceCharacterCard.Extensions) throws -> Self? {
        guard let plugin = pluginIDs.compactMap({ extensions.plugins[$0] }).first else { return nil }
        var diagnostics: [String] = []
        if pluginIDs.allSatisfy({ extensions.plugins[$0] != nil }) {
            diagnostics.append("Both resolver markers are present; the EC marker takes precedence, matching the source loader.")
        }
        // Version is deliberately not a gate: the installed UAR hook never reads it.
        if plugin.version != 0 {
            diagnostics.append("Resolver version \(plugin.version) retained; the installed source loader reads info without a version check.")
        }
        guard let data = plugin.data else {
            throw SourceCharacterCardError.invalid("Resolver plug-in '\(plugin.id)' has null data; its original bytes remain preserved.")
        }
        guard let value = data["info"] else {
            diagnostics.append("The selected resolver marker has no info field. Source compatibility fallback is not applied by this report.")
            return Self(pluginID: plugin.id, pluginVersion: plugin.version, records: [], diagnostics: diagnostics)
        }
        guard let values = value.arrayValue, values.count <= 10_000 else {
            throw SourceCharacterCardError.invalid("Resolver info must be an array of at most 10,000 binary records.")
        }
        var records: [Record] = [], total = 0
        for (index, value) in values.enumerated() {
            guard let bytes = value.binaryValue, bytes.count <= 1024 * 1024 else {
                throw SourceCharacterCardError.invalid("Resolver record \(index) must be a binary MessagePack payload no larger than 1 MiB.")
            }
            total += bytes.count
            guard total <= 64 * 1024 * 1024 else {
                throw SourceCharacterCardError.invalid("Resolver records exceed the native 64 MiB limit.")
            }
            records.append(try decodeRecord(bytes, index: index))
        }
        return Self(pluginID: plugin.id, pluginVersion: plugin.version, records: records, diagnostics: diagnostics)
    }

    private static func decodeRecord(_ bytes: Data, index: Int) throws -> Record {
        guard case .map(let fields) = try SourceMessagePack.decode(bytes, maximumBytes: 1024 * 1024) else {
            throw SourceCharacterCardError.invalid("Resolver record \(index) is not a non-null ResolveInfo map.")
        }
        var guid: String?, property: String?, author: String?, website: String?, name: String?
        var slot = 0, localSlot = 0, category = 0
        func string(_ value: SourceMessagePackValue) throws -> String? {
            if case .null = value { return nil }
            guard let result = value.stringValue, result.utf8.count <= 65_536 else {
                throw SourceCharacterCardError.invalid("Resolver record \(index) contains an invalid or oversized string field.")
            }
            return result
        }
        func integer(_ value: SourceMessagePackValue) throws -> Int {
            guard let result = value.integerValue, Int32(exactly: result) != nil else {
                throw SourceCharacterCardError.invalid("Resolver record \(index) contains a non-Int32 numeric field.")
            }
            return result
        }
        // The original generated class formatter validates every occurrence and
        // assigns the last known key. Missing fields remain nil / zero.
        for field in fields {
            guard let key = field.key.stringValue else {
                throw SourceCharacterCardError.invalid("Resolver record \(index) has a non-string map key.")
            }
            switch key {
            case "ModID": guid = try string(field.value).map(SourceModCatalog.trimSourceGUID)
            case "Slot": slot = try integer(field.value)
            case "LocalSlot": localSlot = try integer(field.value)
            case "CategoryNo": category = try integer(field.value)
            case "Property": property = try string(field.value)
            case "Author": author = try string(field.value)
            case "Website": website = try string(field.value)
            case "Name": name = try string(field.value)
            default: break // Unknown fields remain in preservedData.
            }
        }
        return Record(index: index, modGUID: guid, sourceSlot: slot, localSlot: localSlot,
            property: property, category: category, author: author, website: website, name: name,
            preservedData: bytes, sourceSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    /// Read-only direct lookup. Migrations and the source's ID-only compatibility
    /// fallback need more installation state and are never guessed here.
    public func report(destinations: [Destination]?, library: SourceModLibrary? = nil,
                       catalog: SourceModCatalog? = nil, sourceAssets: [SourceModCatalog.SourceAsset] = []) throws -> Report {
        var diagnostics = self.diagnostics
        diagnostics.append("Direct mod references are inspected only. Catalog matches do not apply appearance; GUID migrations and ID-only compatibility fallback remain unsupported.")
        var destinationIndex: [Data: Destination] = [:]
        for destination in destinations ?? [] {
            let key = Data(destination.property.utf8)
            guard destinationIndex[key] == nil else {
                throw SourceCharacterCardError.invalid("Duplicate source resolver destination '\(destination.property)'.")
            }
            destinationIndex[key] = destination
        }
        struct Row: Hashable {
            let guid: Data, path: Data, index: Int
        }
        var dependenciesByRow: [Row: [SourceModCatalog.Dependency]] = [:]
        let mountedGUIDs = Set((library?.packages ?? []).map { Data($0.source.guid.utf8) })
        var seen = Set<Data>()
        let results = try records.map { record -> Resolution in
            let key = record.property.map { Data($0.utf8) }
            let destination = key.flatMap { destinationIndex[$0] }
            let status: String
            var entry: SourceModCatalog.Entry?
            if let key, !seen.insert(key).inserted { status = "shadowed" }
            else if destinations == nil { status = "metadataOnly" }
            else if let destination {
                if record.category != destination.category {
                    diagnostics.append("Record \(record.index) declares category \(record.category); lookup uses the actual destination category \(destination.category) for \(destination.property).")
                }
                if let guid = record.modGUID, !guid.isEmpty {
                    if library != nil {
                        if let catalog {
                            if mountedGUIDs.contains(Data(guid.utf8)) {
                                entry = catalog.resolve(modGUID: guid, category: destination.category,
                                    sourceSlot: record.sourceSlot, property: destination.catalogProperty)
                                status = entry == nil ? "catalogEntryMissing" : "resolved"
                            } else { status = "modNotMounted" }
                        } else { status = "catalogUnavailable" }
                    } else { status = "libraryNotLoaded" }
                } else { status = "compatibilityRequired" }
            } else { status = "unmatchedProperty" }
            var dependencies: [SourceModCatalog.Dependency] = []
            if let entry, let library, let catalog {
                let row = Row(guid: Data(entry.key.modGUID.utf8), path: Data(entry.sourcePath.utf8), index: entry.sourceRow)
                if let existing = dependenciesByRow[row] { dependencies = existing }
                else {
                    dependencies = try catalog.dependencies(for: entry, library: library, sourceAssets: sourceAssets)
                    dependenciesByRow[row] = dependencies
                }
            }
            return Resolution(record: record, status: status, destination: destination, entry: entry, dependencies: dependencies)
        }
        return Report(pluginID: pluginID, pluginVersion: pluginVersion, resolutions: results, diagnostics: diagnostics)
    }
}

extension SourceCharacterCard {
    public func modReferences() throws -> SourceCardModReferences? {
        try SourceCardModReferences.decode(from: extensions())
    }

    public func modReferenceReport(library: SourceModLibrary? = nil, catalog: SourceModCatalog? = nil,
                                   contract: SourceModCatalogContract? = nil) throws -> SourceCardModReferences.Report {
        let extensions = try extensions()
        guard let references = try SourceCardModReferences.decode(from: extensions) else {
            return .init(pluginID: nil, pluginVersion: nil, resolutions: [], diagnostics: extensions.diagnostics)
        }
        let scan = try contract.map { try resolverDestinations(contract: $0) }
        let report = try references.report(destinations: scan?.destinations, library: library, catalog: catalog,
                                           sourceAssets: contract?.sourceAssets ?? [])
        return .init(pluginID: report.pluginID, pluginVersion: report.pluginVersion, resolutions: report.resolutions,
                     diagnostics: extensions.diagnostics + (scan?.diagnostics ?? []) + report.diagnostics)
    }
}
