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
    public struct Entry: Decodable, Sendable {
        public let category: Int, id: Int, name: String
        public let modGUID: String?, empty: Bool?
        public let rig: File?, appearance: File?, cardBindings: File?, bodyMask: File?
        public let meshNames: [String]?, attachment: Attachment?
    }
    public struct Assembly: Decodable, Sendable {
        public let sex: Int, headID: Int, exType: Int
        public let manifest: File
    }
    private struct Document: Decodable { let schemaVersion: Int, entries: [Entry], assemblies: [Assembly]? }
    private struct Key: Hashable, Sendable { let category: Int, id: Int, guid: Data? }
    public let directory: URL, entries: [Entry], assemblies: [Assembly]
    private let entryIndex: [Key: Int]

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
        }
        let result = Self(directory: url.deletingLastPathComponent().resolvingSymlinksInPath(), entries: doc.entries, assemblies: doc.assemblies ?? [], entryIndex: index)
        for entry in result.entries {
            for ref in [entry.rig, entry.appearance, entry.cardBindings, entry.bodyMask].compactMap({ $0 }) { _ = try result.contained(ref) }
        }
        var identities = Set<String>()
        for assembly in result.assemblies {
            guard [0, 1].contains(assembly.sex), assembly.headID >= 0, assembly.exType == 0,
                  identities.insert("\(assembly.sex):\(assembly.headID):\(assembly.exType)").inserted else { throw RigError.invalid("Duplicate or unsupported Maker assembly identity.") }
            _ = try result.contained(assembly.manifest)
        }
        return result
    }
    public func assemblyURL(for identity: SourceCharacterCard.Customization) throws -> URL? {
        guard let entry = assemblies.first(where: { $0.sex == identity.sex && $0.headID == identity.headID && $0.exType == identity.exType }) else { return nil }
        return try verified(entry.manifest, maximumBytes: 1024 * 1024)
    }
    private func contained(_ ref: File) throws -> URL {
        let url = directory.appendingPathComponent(ref.file).resolvingSymlinksInPath()
        guard !ref.file.isEmpty, !ref.file.hasPrefix("/"), url.path.hasPrefix(directory.path + "/"),
              ref.sha256.count == 64, ref.sha256.allSatisfy({ $0.isHexDigit }) else { throw RigError.invalid("Invalid Maker library file reference.") }
        return url
    }
    private func verified(_ ref: File, maximumBytes: Int = 128 * 1024 * 1024) throws -> URL {
        let url = try contained(ref), input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let bytes = try input.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == ref.sha256.lowercased() else { throw RigError.invalid("Changed or oversized converted Maker asset: \(ref.file).") }
        return url
    }
    public struct Selection: Sendable {
        public let property: String, category: Int, savedID: Int, sourceID: Int
        public let modGUID: String?, entry: Entry?, status: String
    }
    public func selection(category: Int, savedID: Int, property: String, references: SourceCardModReferences?) -> Selection {
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
        return Selection(property: property, category: category, savedID: savedID, sourceID: id, modGUID: guid,
            entry: entry, status: entry == nil ? "conversionMissing" : entry?.empty == true ? "empty" : "converted")
    }
    fileprivate struct MaterialComponent: Sendable {
        let appearance: URL, bindings: URL?, meshNames: Set<String>, prefix: String, accessorySlot: Int?
    }
    public struct Prepared: Sendable {
        public let source: SourceRig, selections: [Selection], diagnostics: [String]
        fileprivate let components: [MaterialComponent]
        fileprivate let bodyMask: URL?
        public var geometryChanged: Bool { selections.contains { $0.entry != nil } }
        public func appearance(base: SourcePreviewAppearance?, card: SourceCardAppearance, resources: ResourceStore,
                               modLibrary: SourceModLibrary?) throws -> SourcePreviewAppearance.CardApplication? {
            var combined = base, fields = Set<String>(), messages = diagnostics
            for component in components {
                var appearance = try SourcePreviewAppearance.load(url: component.appearance, resources: resources, modLibrary: modLibrary)
                if let url = component.bindings {
                    var bindings = try SourceAppearanceBindings.load(url: url)
                    if let slot = component.accessorySlot { bindings = try bindings.contextualized(accessorySlot: slot) }
                    let applied = try appearance.applying(card, bindings: bindings, directory: url.deletingLastPathComponent(), resources: resources)
                    appearance = applied.appearance; fields.formUnion(applied.appliedFields); messages += applied.diagnostics
                }
                appearance = appearance.renaming(component.meshNames, prefix: component.prefix)
                combined = combined.map { $0.merging(appearance) } ?? appearance
            }
            if let mask = bodyMask, let current = combined {
                combined = try current.replacingBodyMask(data: Data(contentsOf: mask), resources: resources)
            }
            guard let combined else { return nil }
            return .init(appearance: combined, appliedFields: fields, diagnostics: messages)
        }
    }
    public func prepare(card: SourceCharacterCard, coordinate: Int, baseURL: URL) throws -> Prepared {
        guard (0..<7).contains(coordinate) else { throw RigError.invalid("Invalid Maker outfit index.") }
        let manifest = try JSONDecoder().decode(SourceAvatarManifest.self, from: Data(contentsOf: baseURL))
        let folder = baseURL.deletingLastPathComponent().resolvingSymlinksInPath()
        func base(_ path: String) throws -> SourceRig {
            let url = folder.appendingPathComponent(path).resolvingSymlinksInPath()
            guard !path.hasPrefix("/"), url.path.hasPrefix(folder.path + "/") else { throw RigError.invalid("Base component escapes its folder.") }
            return try SourceRig.load(url: url)
        }
        let references = try card.modReferences()
        var selections: [Selection] = [], diagnostics: [String] = [], materials: [MaterialComponent] = []
        var bodyMask: URL?
        // Legacy reference manifests explicitly selected these three garments.
        // New manifests carry slots instead of inferring them from filenames.
        guard manifest.clothes.count == 3 || manifest.clothes.allSatisfy({ $0.slot != nil }), manifest.hair.count <= 4 else {
            throw RigError.invalid("Base avatar requires explicit clothing slot metadata.")
        }
        var hairBySlot: [Int: (SourceRig, [String]?)] = [:], clothesBySlot: [Int: (SourceRig, [String]?)] = [:]
        for (i, part) in manifest.hair.enumerated() { hairBySlot[part.slot ?? i] = (try base(part.file), part.meshNames) }
        for (i, part) in manifest.clothes.enumerated() { clothesBySlot[part.slot ?? [0, 1, 8][i]] = (try base(part.file), part.meshNames) }
        func integer(_ fields: [String: SourceMessagePackValue], _ name: String) throws -> Int {
            guard let value = fields[name]?.integerValue, Int32(exactly: value) != nil else { throw RigError.invalid("Missing or invalid Maker selection \(name).") }
            return value
        }
        func selected(_ category: Int, _ id: Int, _ property: String, _ prefix: String, accessorySlot: Int? = nil) throws -> (SourceRig, [String]?)? {
            let resolution = selection(category: category, savedID: id, property: property, references: references); selections.append(resolution)
            guard let entry = resolution.entry else {
                diagnostics.append("\(property): \(resolution.status), source ID \(resolution.sourceID). Card identity preserved; reference geometry retained where available."); return nil
            }
            guard entry.empty != true else { return nil }
            if let mask = entry.bodyMask { bodyMask = try verified(mask, maximumBytes: 32 * 1024 * 1024) }
            guard let rigFile = entry.rig else { throw RigError.invalid("Converted Maker geometry is absent.") }
            let rig = try SourceRig.load(url: verified(rigFile))
            if let file = entry.appearance {
                materials.append(.init(appearance: try verified(file, maximumBytes: 1024 * 1024),
                    bindings: try entry.cardBindings.map { try verified($0, maximumBytes: 1024 * 1024) },
                    meshNames: Set(rig.parts.map { $0.mesh.name }), prefix: prefix, accessorySlot: accessorySlot))
            } else { diagnostics.append("\(property): converted geometry has a neutral material; shader conversion is missing.") }
            return (rig.namespacingMeshes(prefix), entry.meshNames)
        }
        let hairFields = try card.recordFields(.hair)
        guard let hairParts = hairFields["parts"]?.arrayValue, hairParts.count <= 4 else { throw RigError.invalid("Unsupported hair part array.") }
        for (slot, part) in hairParts.enumerated() {
            let id = try integer(part.stringKeyedMap(), "id"), property = "ChaFileHair." + ["HairBack", "HairFront", "HairSide", "HairOption"][slot]
            let value = try selected(101 + slot, id, property, "hair-\(slot)/")
            if selections.last?.entry != nil { hairBySlot[slot] = value }
        }
        let clothesFields = try card.recordFields(.clothes(coordinate: coordinate))
        guard let parts = clothesFields["parts"]?.arrayValue, parts.count <= 9 else { throw RigError.invalid("Unsupported clothes array.") }
        for (slot, part) in parts.enumerated() where slot != 7 {
            let id = try integer(part.stringKeyedMap(), "id")
            let property = "outfit\(coordinate).ChaFileClothes.Clothes" + ["Top", "Bot", "Bra", "Shorts", "Gloves", "Pants", "Socks", "ShoesInner", "ShoesOuter"][slot]
            let value = try selected(min(105 + slot, 112), id, property, "clothes-\(slot)/")
            if selections.last?.entry != nil { clothesBySlot[slot] = value }
        }
        diagnostics.append("Maker previews outdoor shoes and fully-on clothes; saved wear state is preserved.")
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
        let hair = hairBySlot.keys.sorted().compactMap { hairBySlot[$0] }, clothes = clothesBySlot.keys.sorted().compactMap { clothesBySlot[$0] }
        let source = try SourceAvatar.assemble(name: manifest.name, bodySkeleton: base(manifest.bodySkeleton), headSkeleton: base(manifest.headSkeleton),
            body: base(manifest.body.file), head: base(manifest.head.file), clothes: clothes.map(\.0), hair: hair.map(\.0),
            bodyMeshNames: manifest.body.meshNames, headMeshNames: manifest.head.meshNames,
            clothingMeshNames: clothes.map(\.1), hairMeshNames: hair.map(\.1), accessories: accessories)
        return Prepared(source: source, selections: selections, diagnostics: diagnostics, components: materials, bodyMask: bodyMask)
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
