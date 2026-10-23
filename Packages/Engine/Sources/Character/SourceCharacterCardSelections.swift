import Foundation
import Assets

/// Original ChaFile destinations. These are not native CharacterCard catalog slots.
public enum SourceMakerSelectionSlot: Hashable, Sendable {
    case hair(Int)
    case clothes(coordinate: Int, slot: Int)

    public struct Destination: Sendable {
        public let record: SourceCharacterCard.Record, slot: Int, category: Int, property: String
    }

    public func destination() throws -> Destination {
        switch self {
        case .hair(let slot):
            guard (0..<4).contains(slot) else { throw cardEditError("Unsupported source hair slot.") }
            return Destination(record: .hair, slot: slot, category: 101 + slot,
                property: "ChaFileHair." + ["HairBack", "HairFront", "HairSide", "HairOption"][slot])
        case .clothes(let coordinate, let slot):
            guard (0..<7).contains(coordinate), (0..<9).contains(slot), slot != 7 else {
                throw cardEditError("Unsupported source clothing slot or outfit; inner shoes are not assembled by Maker.")
            }
            return Destination(record: .clothes(coordinate: coordinate), slot: slot, category: min(105 + slot, 112),
                property: "outfit\(coordinate).ChaFileClothes.Clothes" + ["Top", "Bot", "Bra", "Shorts", "Gloves", "Pants", "Socks", "ShoesInner", "ShoesOuter"][slot])
        }
    }
}

extension SourceCharacterCard {
    /// Select a vanilla source catalog ID and remove all resolver records for
    /// this exact destination, including shadowed duplicates and both UAR
    /// markers. Other records retain their binary tokens, order and metadata.
    /// The caller must verify that this ID has a usable converted asset before
    /// committing editor state. This method does not read geometry or do I/O.
    public func selectingVanillaAsset(_ id: Int, at slot: SourceMakerSelectionSlot) throws -> Data {
        guard id >= 0, Int32(exactly: id) != nil else { throw cardEditError("Source selection ID must be a nonnegative Int32.") }
        let destination = try slot.destination()
        let originalRecord = try recordData(destination.record)
        let tokens = try CardTokenDocument(originalRecord)
        let field = try tokens.node(at: [.key("parts"), .index(destination.slot), .key("id")])
        guard let oldID = try tokens.value(field).integerValue, Int32(exactly: oldID) != nil else {
            throw cardEditError("Saved source selection ID is not an Int32.")
        }
        let record = oldID == id ? originalRecord : try tokens.applying([.init(range: field.range, replacement: cardInteger(id))])
        var replacements: [String: Data] = [:]
        if record != originalRecord {
            switch destination.record {
            case .hair:
                guard let block = block(named: "Custom") else { throw cardEditError("Custom block is absent.") }
                var reader = try CardReader(block.data)
                let face = try reader.lengthPrefixedData(), body = try reader.lengthPrefixedData()
                _ = try reader.lengthPrefixedData()
                guard reader.remaining == 0 else { throw cardEditError("Unexpected Custom record trailer.") }
                replacements["Custom"] = cardLengthData(face) + cardLengthData(body) + cardLengthData(record)
            case .clothes(let coordinate):
                guard let block = block(named: "Coordinate") else { throw cardEditError("Coordinate block is absent.") }
                let document = try CardTokenDocument(block.data), node = try document.node(at: [.index(coordinate)])
                guard let bytes = try document.value(node).binaryValue else { throw cardEditError("Coordinate is not binary.") }
                var reader = try CardReader(bytes)
                _ = try reader.lengthPrefixedData()
                let updated = cardLengthData(record) + bytes.subdata(in: reader.offset..<bytes.count)
                replacements["Coordinate"] = try document.applying([.init(range: node.range, replacement: cardBinary(updated))])
            default: throw cardEditError("Unsupported source selection record.")
            }
        }
        let resolver = try selectionResolverChanges(removing: destination.property)
        replacements.merge(resolver.blocks) { _, updated in updated }
        let trailer = resolver.trailer
        if replacements.isEmpty, trailer == trailingData { return preservedData }
        let verified = try replacingBlocks(replacements, trailer: trailer)
        let result = verified.preservedData
        let parts = try verified.recordFields(destination.record)["parts"]?.arrayValue
        guard let parts, parts.indices.contains(destination.slot),
              try parts[destination.slot].stringKeyedMap()["id"]?.integerValue == id,
              try verified.modReferences()?.records.contains(where: { $0.property.map { Data($0.utf8) } == Data(destination.property.utf8) }) != true else {
            throw cardEditError("Source selection verification failed.")
        }
        return result
    }

    /// Validate both resolver markers and both supported Extended Save locations,
    /// including metadata shadowed by the source loader. The selection UI must
    /// not infer a vanilla identity when any data needed for cleanup is invalid.
    public func validateMakerSelectionMetadata() throws {
        _ = try selectionResolverChanges(removing: nil)
    }

    private func selectionResolverChanges(removing property: String?) throws -> (blocks: [String: Data], trailer: Data) {
        var replacements: [String: Data] = [:]
        if let block = block(named: "KKEx") {
            // The original hook locates KKEx from payloadEnd - sum(sizes).
            // A gap can therefore make its effective bytes differ from the
            // header's normal block range, even for an equal-ID request.
            guard blocks.reduce(0, { $0 + $1.data.count }) == payloadSize else {
                throw cardEditError("Cannot select assets in a gapped Extended Save payload with ambiguous resolver offsets.")
            }
            guard block.version == "3" else { throw cardEditError("Selection edits require Extended Save block version 3.") }
            let updated = try Self.removingResolverDestination(property, from: block.data)
            if updated != block.data { replacements["KKEx"] = updated }
        }
        var trailer = trailingData
        if !trailer.isEmpty {
            var reader = try CardReader(trailer)
            if (try? reader.string()) == "KKEx" {
                guard try reader.nonnegativeInt32() == 2 else { throw cardEditError("Selection edits require legacy Extended Save version 2.") }
                let lengthOffset = reader.offset
                let count = try reader.nonnegativeInt32(maximum: 64 * 1024 * 1024)
                guard count > 0, count <= reader.remaining else { throw cardEditError("Legacy Extended Save payload is incomplete.") }
                let bytes = try reader.take(count)
                let updated = try Self.removingResolverDestination(property, from: bytes)
                if updated != bytes {
                    trailer = trailer.prefix(lengthOffset) + cardLengthData(updated) + trailer.suffix(from: reader.offset)
                }
            }
        }
        return (replacements, trailer)
    }

    private static func removingResolverDestination(_ property: String?, from bytes: Data) throws -> Data {
        let document = try CardTokenDocument(bytes)
        if case .null = try document.value(document.root) { return bytes }
        let fields = try document.value(document.root).stringKeyedMap()
        var patches: [CardBytePatch] = []
        for marker in SourceCardModReferences.pluginIDs {
            guard let value = fields[marker] else { continue }
            if case .null = value { continue }
            guard let members = value.arrayValue else { throw cardEditError("Resolver PluginData is not an array.") }
            let version = members.isEmpty ? 0 : members[0].integerValue
            guard let version, Int32(exactly: version) != nil else { throw cardEditError("Resolver version is not an Int32.") }
            guard members.count >= 2, case .map = members[1] else { throw cardEditError("Resolver data is absent or unsupported.") }
            let data = try members[1].stringKeyedMap()
            guard data["info"] != nil else { continue }
            // Reuse the recovered formatter's validation and last-known-field
            // rules; raw surviving records below are never re-encoded.
            let refs = try SourceCardModReferences.decode(from: Extensions(format: nil,
                plugins: [marker: PluginData(id: marker, version: version, data: data)], diagnostics: []))
            guard let refs else { throw cardEditError("Resolver records could not be read.") }
            guard let property else { continue }
            let removed = Set(refs.records.filter { $0.property.map { Data($0.utf8) } == Data(property.utf8) }.map(\.index))
            guard !removed.isEmpty else { continue }
            let info = try document.node(at: [.key(marker), .index(1), .key("info")])
            guard info.kind == .array, info.children.count == refs.records.count else { throw cardEditError("Resolver info changed unexpectedly.") }
            let count = info.children.count - removed.count
            let headerEnd = info.children.first?.range.lowerBound ?? info.range.upperBound
            // Keep the old array-header width where possible, including zero
            // remaining records, so only the count and removed records change.
            let header: Data
            switch bytes[info.range.lowerBound] {
            case 0x90...0x9f: header = Data([0x90 | UInt8(count)])
            case 0xdc: header = Data([0xdc]) + cardBig(UInt64(count), count: 2)
            case 0xdd: header = Data([0xdd]) + cardBig(UInt64(count), count: 4)
            default: throw cardEditError("Unsupported resolver array header.")
            }
            patches.append(.init(range: info.range.lowerBound..<headerEnd, replacement: header))
            for index in removed { patches.append(.init(range: info.children[index].range, replacement: Data())) }
        }
        return patches.isEmpty ? bytes : try document.applying(patches)
    }
}
