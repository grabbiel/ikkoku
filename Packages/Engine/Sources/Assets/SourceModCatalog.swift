import Foundation

/// Recovered key/category and asset-reference mappings, separate from any mod's data.
public struct SourceModCatalogContract: Decodable, Sendable {
    public struct Category: Decodable, Sendable {
        public let number: Int, name: String, properties: [String]
    }
    public struct ReferenceRule: Decodable, Sendable {
        public let role: String, categories: [Int], expectedType: String
        public let bundleField: String, assetField: String, manifestField: String?
        public let fallbackBundleField: String?, disabledAssetValues: [String]
        public let disabledBundleValues: [String]?
    }
    public let schemaVersion: Int, keyTypes: [String], categories: [Category], referenceRules: [ReferenceRule]
    public let sourceAssets: [SourceModCatalog.SourceAsset]?

    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, Set(value.keyTypes).count == value.keyTypes.count,
              Set(value.categories.map(\.number)).count == value.categories.count,
              ["Category", "DistributionNo", "ID", "Possess", "Name"].allSatisfy(value.keyTypes.contains) else {
            throw SourceModError.invalid("Invalid source catalog contract.")
        }
        for rule in value.referenceRules {
            let keys = [rule.bundleField, rule.assetField] + [rule.manifestField, rule.fallbackBundleField].compactMap { $0 }
            guard !rule.role.isEmpty, !rule.expectedType.isEmpty, keys.allSatisfy(value.keyTypes.contains),
                  rule.categories.allSatisfy({ number in value.categories.contains { $0.number == number } }) else {
                throw SourceModError.invalid("Invalid source catalog dependency rule.")
            }
        }
        return value
    }
}

/// Character catalog identities retain the original source slot. Runtime UAR
/// LocalSlot values are load-order counters and are never native save identities.
public struct SourceModCatalog: Sendable {
    public struct Key: Codable, Hashable, Sendable {
        public let modGUID: String, category: Int, sourceSlot: Int
        public init(modGUID: String, category: Int, sourceSlot: Int) {
            self.modGUID = modGUID; self.category = category; self.sourceSlot = sourceSlot
        }
    }
    public struct Reference: Sendable, Equatable {
        public let role: String, expectedType: String, manifest: String, bundlePath: String, assetName: String
    }
    public struct Entry: Sendable, Identifiable {
        public let key: Key, distribution: Int, sourcePath: String, sourceRow: Int
        public let sourceFilePath: String, properties: [String], fields: [String: String], references: [Reference]
        public var id: String { "\(key.modGUID):\(sourcePath):\(sourceRow)" }
        public var name: String { info("Name") }
        /// ListInfoBase returns the literal string 0 only for an absent key.
        public func info(_ key: String) -> String { fields[key] ?? "0" }
    }
    public struct SourceAsset: Decodable, Sendable {
        public let manifest: String, bundlePath: String, assetName: String, type: String
        public init(manifest: String = "abdata", bundlePath: String, assetName: String, type: String) {
            self.manifest = manifest; self.bundlePath = bundlePath; self.assetName = assetName; self.type = type
        }
    }
    public struct Dependency: Sendable {
        public let entry: Key, sourceRow: Int, reference: Reference
        public let sourcePath: String
        public let status: String, providerGUID: String?
    }
    public let entries: [Entry], diagnostics: [SourceModPackage.Diagnostic]
    private struct LookupKey: Hashable, Sendable {
        let guid: Data, category: Int, slot: Int
    }
    private let entryIndex: [LookupKey: [Int]]

    public init(library: SourceModLibrary, contract: SourceModCatalogContract) throws {
        let known = Set(contract.keyTypes)
        var entries: [Entry] = [], diagnostics: [SourceModPackage.Diagnostic] = []
        var seen = Set<Key>()
        for package in library.packages {
            for catalog in package.catalogs {
                // Studio/excel CSVs have a different injection path.
                guard catalog.sourcePath.lowercased().hasPrefix("abdata/list/characustom"),
                      catalog.sourcePath.lowercased().hasSuffix(".csv") else { continue }
                do {
                    let table = try Self.readSourceCSV(package.catalogData(catalog))
                    guard let category = contract.categories.first(where: { $0.number == table.category }) else {
                        throw SourceModError.invalid("Category \(table.category) has no recovered native mapping.")
                    }
                    var rows: [Entry] = []
                    for (rowIndex, sourceCells) in table.rows.enumerated() {
                        guard sourceCells.count >= table.columns.count, let slot = Self.integer(sourceCells[0]),
                              table.columns.first == "ID" else {
                            throw SourceModError.invalid("Row \(rowIndex) is short or has no supported original ID column.")
                        }
                        var cells = sourceCells
                        if let possess = table.columns.firstIndex(of: "Possess") { cells[possess] = "1" }
                        var fields = ["Category": String(table.category), "DistributionNo": String(table.distribution)]
                        for (index, column) in table.columns.enumerated() where known.contains(column) { fields[column] = cells[index] }
                        func info(_ key: String) -> String { fields[key] ?? "0" }
                        let references = contract.referenceRules.filter {
                            $0.categories.isEmpty || $0.categories.contains(table.category)
                        }.compactMap { rule -> Reference? in
                            let asset = info(rule.assetField)
                            guard !rule.disabledAssetValues.contains(asset) else { return nil }
                            var bundle = info(rule.bundleField)
                            if bundle == "0", let fallback = rule.fallbackBundleField { bundle = info(fallback) }
                            guard rule.disabledBundleValues?.contains(bundle) != true else { return nil }
                            let manifest = rule.manifestField.map(info) ?? ""
                            return Reference(role: rule.role, expectedType: rule.expectedType,
                                manifest: manifest.isEmpty ? "abdata" : manifest, bundlePath: bundle, assetName: asset)
                        }
                        rows.append(Entry(key: Key(modGUID: package.source.guid, category: table.category, sourceSlot: slot),
                            distribution: Self.integer(info("DistributionNo")) ?? -1, sourcePath: catalog.sourcePath, sourceRow: rowIndex,
                            sourceFilePath: table.filePath, properties: category.properties, fields: fields, references: references))
                    }
                    for row in rows {
                        if !seen.insert(row.key).inserted {
                            diagnostics.append(.init(code: "duplicate_source_slot", severity: "warning",
                                message: "\(package.source.guid), category \(row.key.category), slot \(row.key.sourceSlot): lookup uses the first row in the explicit native mount/catalog order."))
                        }
                    }
                    let unknown = table.columns.filter { !known.contains($0) }
                    if !unknown.isEmpty {
                        diagnostics.append(.init(code: "unknown_catalog_columns", severity: "warning",
                            message: "\(package.source.guid)/\(catalog.sourcePath): unknown columns retained in raw bytes: \(unknown.joined(separator: ", "))."))
                    }
                    entries.append(contentsOf: rows)
                } catch {
                    diagnostics.append(.init(code: "catalog_injection_unsupported", severity: "error",
                        message: "\(package.source.guid)/\(catalog.sourcePath): \(error)"))
                }
            }
        }
        self.entries = entries; self.diagnostics = diagnostics
        var index: [LookupKey: [Int]] = [:]
        for (position, entry) in entries.enumerated() {
            index[LookupKey(guid: Data(entry.key.modGUID.utf8), category: entry.key.category,
                            slot: entry.key.sourceSlot), default: []].append(position)
        }
        self.entryIndex = index
    }

    public func resolve(modGUID: String, category: Int, sourceSlot: Int, property: String? = nil) -> Entry? {
        let guid = Self.trimSourceGUID(modGUID)
        let key = LookupKey(guid: Data(guid.utf8), category: category, slot: sourceSlot)
        for position in entryIndex[key] ?? [] {
            let entry = entries[position]
            if !entry.properties.isEmpty && (property.map { property in
                entry.properties.contains { $0.utf8.elementsEqual(property.utf8) }
            } ?? true) { return entry }
        }
        return nil
    }

    /// .NET String.Trim / Char.IsWhiteSpace; Foundation's whitespace set also
    /// removes U+200B, which is a significant character in a source mod GUID.
    public static func trimSourceGUID(_ value: String) -> String {
        func whitespace(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a,
                 0x2028, 0x2029, 0x202f, 0x205f, 0x3000: return true
            default: return false
            }
        }
        let scalars = value.unicodeScalars
        let start = scalars.firstIndex { !whitespace($0) } ?? scalars.endIndex
        let end = scalars.lastIndex { !whitespace($0) }.map { scalars.index(after: $0) } ?? start
        return String(scalars[start..<end])
    }

    /// Source-only availability is an explicit inventory, never guessed from a
    /// filename. Unindexed base/mod assets stay unresolved rather than declared absent.
    public func dependencies(library: SourceModLibrary, sourceAssets: [SourceAsset] = []) throws -> [Dependency] {
        try entries.flatMap { try dependencies(for: $0, library: library, sourceAssets: sourceAssets) }
    }

    /// A card only needs the dependencies of the rows it actually resolves.
    public func dependencies(for entry: Entry, library: SourceModLibrary, sourceAssets: [SourceAsset] = []) throws -> [Dependency] {
        entry.references.map { reference in
            let status: String, provider: String?
            let sources = sourceAssets.filter {
                $0.manifest == reference.manifest && $0.bundlePath == reference.bundlePath && $0.assetName == reference.assetName
            }
            do {
                let texture = try library.sourceTextureProvider(bundlePath: reference.bundlePath, assetName: reference.assetName)
                if let texture, reference.expectedType == "Texture2D" { status = "convertedTexture"; provider = texture.modGUID }
                else if sources.contains(where: { $0.type == reference.expectedType }) { status = "sourceOnly"; provider = nil }
                else if let texture { status = "wrongAssetType"; provider = texture.modGUID }
                else { status = sources.isEmpty ? "unresolved" : "wrongAssetType"; provider = nil }
            } catch { status = "ambiguousSourceBundle"; provider = nil }
            return Dependency(entry: entry.key, sourceRow: entry.sourceRow, reference: reference,
                sourcePath: entry.sourcePath, status: status, providerGUID: provider)
        }
    }

    private struct Table {
        let category: Int, distribution: Int, filePath: String, columns: [String], rows: [[String]]
    }
    private static func integer(_ text: String) -> Int? {
        Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)).map(Int.init)
    }
    private static func readSourceCSV(_ data: Data) throws -> Table {
        guard data.count <= 8 * 1024 * 1024 else { throw SourceModError.invalid("Source catalog exceeds the native parser limit.") }
        // Match StreamReader BOM detection for supported valid Unicode input.
        let encodings: [([UInt8], String.Encoding)] = [([0xff, 0xfe, 0, 0], .utf32LittleEndian),
            ([0, 0, 0xfe, 0xff], .utf32BigEndian), ([0xff, 0xfe], .utf16LittleEndian),
            ([0xfe, 0xff], .utf16BigEndian), ([0xef, 0xbb, 0xbf], .utf8)]
        let bom = encodings.first { data.starts(with: $0.0) }
        guard let text = String(data: data.dropFirst(bom?.0.count ?? 0), encoding: bom?.1 ?? .utf8) else {
            throw SourceModError.invalid("Catalog is not valid source UTF-8 or BOM-declared Unicode; raw bytes remain preserved.")
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard lines.count >= 4 else { throw SourceModError.invalid("Source catalog lacks its three preamble lines and header.") }
        func preamble(_ index: Int) -> String { lines[index].components(separatedBy: ",")[0].trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let category = integer(preamble(0)), let distribution = integer(preamble(1)) else { throw SourceModError.invalid("Invalid source category/distribution number.") }
        let columns = lines[3].trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",")
        var rows: [[String]] = []
        for line in lines.dropFirst(4) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.contains(",") { break }
            rows.append(value.components(separatedBy: ","))
        }
        return Table(category: category, distribution: distribution, filePath: preamble(2), columns: columns, rows: rows)
    }
}
