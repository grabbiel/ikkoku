import Foundation
import Assets

extension SourceCharacterCard {
    public enum Field: Hashable, Sendable {
        case key(String), index(Int)
    }
    public enum Record: Hashable, Sendable {
        case face, body, hair
        case clothes(coordinate: Int), accessory(coordinate: Int), makeup(coordinate: Int)
    }
    /// A Unity Color is four numeric MessagePack array members in RGBA order.
    /// Asset identities cannot be changed here: their saved resolver metadata
    /// would also need a source-compatible rewrite.
    public struct ColorEdit: Sendable {
        public let record: Record, path: [Field], rgba: [Float]
        public init(record: Record, path: [Field], rgba: [Float]) {
            self.record = record; self.path = path; self.rgba = rgba
        }
    }
    public struct Edits: Sendable {
        public var faceValues: [Float]?, bodyValues: [Float]?
        public var colors: [ColorEdit]
        /// nil preserves the old image; empty Data removes it; nonempty data
        /// must contain exactly one CRC-valid PNG, without an appended card.
        public var thumbnailData: Data?, faceThumbnailData: Data?
        public init(faceValues: [Float]? = nil, bodyValues: [Float]? = nil,
                    colors: [ColorEdit] = [], thumbnailData: Data? = nil,
                    faceThumbnailData: Data? = nil) {
            self.faceValues = faceValues; self.bodyValues = bodyValues; self.colors = colors
            self.thumbnailData = thumbnailData; self.faceThumbnailData = faceThumbnailData
        }
    }

    /// Original bytes for one current-version appearance record. This does not
    /// load textures or execute extension callbacks; callers decode known fields.
    public func recordData(_ record: Record) throws -> Data {
        let bytes: Data, expected: String
        switch record {
        case .face, .body, .hair:
            guard let block = block(named: "Custom"), block.version == "0.0.0" else { throw cardEditError("Unsupported Custom block.") }
            var reader = try CardReader(block.data)
            let records = try (0..<3).map { _ in try reader.lengthPrefixedData() }
            guard reader.remaining == 0 else { throw cardEditError("Unexpected Custom record trailer.") }
            bytes = records[record == .face ? 0 : record == .body ? 1 : 2]
            expected = record == .hair ? "0.0.4" : "0.0.2"
        case .clothes(let index), .accessory(let index), .makeup(let index):
            guard let block = block(named: "Coordinate"), block.version == "0.0.0",
                  let entries = try SourceMessagePack.decode(block.data).arrayValue, entries.count <= 64,
                  entries.indices.contains(index), let data = entries[index].binaryValue else { throw cardEditError("Coordinate record is unavailable or unsupported.") }
            var reader = try CardReader(data)
            let clothes = try reader.lengthPrefixedData(), accessory = try reader.lengthPrefixedData()
            _ = try reader.take(1)
            let makeup = try reader.lengthPrefixedData()
            guard reader.remaining == 0 else { throw cardEditError("Unexpected Coordinate record trailer.") }
            switch record {
            case .clothes: bytes = clothes; expected = "0.0.1"
            case .accessory: bytes = accessory; expected = "0.0.2"
            default: bytes = makeup; expected = "0.0.0"
            }
        }
        guard try SourceMessagePack.decode(bytes).stringKeyedMap()["version"]?.stringValue == expected else { throw cardEditError("Unsupported appearance record version.") }
        return bytes
    }

    public func recordFields(_ record: Record) throws -> [String: SourceMessagePackValue] {
        try SourceMessagePack.decode(recordData(record)).stringKeyedMap()
    }

    /// Produces a new original-format card. This function performs no file I/O.
    /// Only changed numeric tokens and their enclosing length/offset fields are
    /// rewritten; all unrelated bytes, including opaque plug-ins, survive.
    public func editedData(_ edits: Edits) throws -> Data {
        guard edits.colors.count <= 4096 else { throw cardEditError("Too many color edits.") }
        var replacements: [String: Data] = [:]
        var recordEdits: [Record: [CardNumericEdit]] = [:]
        if let values = edits.faceValues {
            try Self.validateNumbers(values, count: 52)
            recordEdits[.face, default: []].append(.init(path: [.key("shapeValueFace")], values: values))
        }
        if let values = edits.bodyValues {
            try Self.validateNumbers(values, count: 44)
            recordEdits[.body, default: []].append(.init(path: [.key("shapeValueBody")], values: values))
        }
        for color in edits.colors {
            try Self.validateNumbers(color.rgba, count: 4)
            guard !color.path.isEmpty, color.path.count <= 32 else { throw cardEditError("Invalid color field path.") }
            // A caller may select a recovered Color field, but cannot use this
            // API to rewrite arbitrary float4 transforms or shape arrays.
            guard color.path.contains(where: { if case .key(let key) = $0 { return key.lowercased().contains("color") }; return false }) else {
                throw cardEditError("Color edit must address a named color field.")
            }
            recordEdits[color.record, default: []].append(.init(path: color.path, values: color.rgba))
        }
        if !recordEdits.isEmpty { _ = try customization() }
        let customKinds: [Record] = [.face, .body, .hair]
        if customKinds.contains(where: { recordEdits[$0] != nil }) {
            guard let custom = block(named: "Custom"), custom.version == "0.0.0" else { throw cardEditError("Unsupported Custom block.") }
            var reader = try CardReader(custom.data), result = Data()
            for record in customKinds {
                let old = try reader.lengthPrefixedData()
                let new = try recordEdits[record].map { try Self.editRecord(old, version: record == .hair ? "0.0.4" : "0.0.2", edits: $0) } ?? old
                result += cardLengthData(new)
            }
            guard reader.remaining == 0 else { throw cardEditError("Unexpected Custom record trailer.") }
            if result != custom.data { replacements["Custom"] = result }
        }
        let coordinateIndices = Set(recordEdits.keys.compactMap { record -> Int? in
            switch record { case .clothes(let index), .accessory(let index), .makeup(let index): return index; default: return nil }
        })
        if !coordinateIndices.isEmpty {
            guard let block = block(named: "Coordinate"), block.version == "0.0.0" else { throw cardEditError("Unsupported Coordinate block.") }
            let tokens = try CardTokenDocument(block.data)
            guard tokens.root.kind == .array, tokens.root.children.count <= 64 else { throw cardEditError("Coordinate list is not a bounded array.") }
            var patches: [CardBytePatch] = []
            for index in coordinateIndices.sorted() {
                guard tokens.root.children.indices.contains(index) else { throw cardEditError("Coordinate index is unavailable.") }
                let token = tokens.root.children[index]
                guard case .binary(let bytes) = try tokens.value(token) else { throw cardEditError("Coordinate entry is not binary.") }
                var reader = try CardReader(bytes), new = Data()
                let clothes = try reader.lengthPrefixedData(), accessory = try reader.lengthPrefixedData()
                let enabled = try reader.take(1), makeup = try reader.lengthPrefixedData()
                guard reader.remaining == 0 else { throw cardEditError("Unexpected Coordinate record trailer.") }
                for (record, original, version) in [(Record.clothes(coordinate: index), clothes, "0.0.1"), (.accessory(coordinate: index), accessory, "0.0.2")] {
                    new += cardLengthData(try recordEdits[record].map { try Self.editRecord(original, version: version, edits: $0) } ?? original)
                }
                new += enabled
                new += cardLengthData(try recordEdits[.makeup(coordinate: index)].map { try Self.editRecord(makeup, version: "0.0.0", edits: $0) } ?? makeup)
                if new != bytes { patches.append(.init(range: token.range, replacement: cardBinary(new))) }
            }
            let updated = try tokens.applying(patches)
            if updated != block.data { replacements["Coordinate"] = updated }
        }
        let thumbnail = try Self.editedPNG(edits.thumbnailData, original: thumbnailData)
        let faceThumbnail = try Self.editedPNG(edits.faceThumbnailData, original: faceThumbnailData)
        if replacements.isEmpty && thumbnail == thumbnailData && faceThumbnail == faceThumbnailData { return preservedData }

        // For non-contiguous payloads the installed Extended Save hook seeks
        // from payloadEnd - sum(sizes). Its target can overlap other blocks.
        // Changing such a layout could alter which plug-in bytes are selected.
        if !replacements.isEmpty, block(named: "KKEx") != nil,
           blocks.reduce(0, { $0 + $1.data.count }) != payloadSize {
            throw cardEditError("Cannot edit a gapped payload with Extended Save; its source hook uses ambiguous offsets.")
        }
        let originalPayload = preservedData.subdata(in: payloadOffset..<(payloadOffset + payloadSize))
        let ordered = blocks.sorted { $0.position < $1.position }
        var cursor = 0, payload = Data(), newPositions: [String: Int] = [:]
        for block in ordered where !block.data.isEmpty {
            guard block.position >= cursor else { throw cardEditError("Overlapping payload records.") }
            payload += originalPayload.subdata(in: cursor..<block.position)
            newPositions[block.name] = payload.count
            payload += replacements[block.name] ?? block.data
            cursor = block.position + block.data.count
        }
        payload += originalPayload.subdata(in: cursor..<originalPayload.count)
        for block in ordered where block.data.isEmpty {
            guard !ordered.contains(where: { replacements[$0.name] != nil && $0.position < block.position && block.position < $0.position + $0.data.count }) else {
                throw cardEditError("An empty block points inside a modified block.")
            }
            let shift = ordered.filter { !$0.data.isEmpty && $0.position + $0.data.count <= block.position }
                .reduce(0) { $0 + (replacements[$1.name]?.count ?? $1.data.count) - $1.data.count }
            newPositions[block.name] = block.position + shift
        }
        let header = try CardTokenDocument(headerData)
        let info = try header.node(at: [.key("lstInfo")])
        guard info.kind == .array, info.children.count == blocks.count else { throw cardEditError("Block header changed unexpectedly.") }
        var patches: [CardBytePatch] = []
        for (index, block) in blocks.enumerated() {
            for (key, next, old) in [("pos", newPositions[block.name]!, block.position), ("size", replacements[block.name]?.count ?? block.data.count, block.data.count)] where next != old {
                patches.append(.init(range: try header.node(at: [.key("lstInfo"), .index(index), .key(key)]).range, replacement: cardInteger(next)))
            }
        }
        let newHeader = try header.applying(patches)
        guard newHeader.count <= 1024 * 1024 else { throw cardEditError("Edited header exceeds 1 MiB.") }
        let headerLengthOffset = payloadOffset - 8 - headerData.count - 4
        let faceLengthOffset = headerLengthOffset - faceThumbnailData.count - 4
        var result = thumbnail + preservedData.subdata(in: thumbnailData.count..<faceLengthOffset)
        result += cardLengthData(faceThumbnail) + cardLengthData(newHeader) + cardLittle(UInt64(payload.count), count: 8) + payload + trailingData
        let verified = try Self.decode(result)
        if let face = edits.faceValues, try verified.customization().faceValues != face { throw cardEditError("Face edit verification failed.") }
        if let body = edits.bodyValues, try verified.customization().bodyValues != body { throw cardEditError("Body edit verification failed.") }
        guard verified.trailingData == trailingData else { throw cardEditError("Trailer preservation verification failed.") }
        for block in blocks where replacements[block.name] == nil {
            guard verified.block(named: block.name)?.data == block.data else { throw cardEditError("Unedited block preservation verification failed.") }
        }
        return result
    }

    private static func editRecord(_ data: Data, version: String, edits: [CardNumericEdit]) throws -> Data {
        let tokens = try CardTokenDocument(data)
        guard try tokens.value(tokens.node(at: [.key("version")])).stringValue == version else { throw cardEditError("Unsupported editable record version.") }
        var patches: [CardBytePatch] = [], targets = Set<Range<Int>>()
        for edit in edits {
            let array = try tokens.node(at: edit.path)
            guard array.kind == .array, array.children.count == edit.values.count else { throw cardEditError("Editable numeric array has an unexpected size.") }
            for (node, next) in zip(array.children, edit.values) {
                guard targets.insert(node.range).inserted else { throw cardEditError("Overlapping numeric edits.") }
                let value = try tokens.value(node), old: Double
                switch value {
                case .float(let number): old = number
                case .integer(let number): old = Double(number)
                case .unsigned(let number): old = Double(number)
                default: throw cardEditError("Editable array contains a nonnumeric member.")
                }
                guard old.isFinite, abs(old) <= Double(Float.greatestFiniteMagnitude) else { throw cardEditError("Editable array contains a nonfinite float32.") }
                // Existing float64/int tokens are retained when they represent
                // the same float32 source value, including signed zero.
                if Float(old).bitPattern != next.bitPattern {
                    patches.append(.init(range: node.range, replacement: Data([0xca]) + cardBig(UInt64(next.bitPattern), count: 4)))
                }
            }
        }
        let result = try tokens.applying(patches)
        _ = try SourceMessagePack.decode(result)
        return result
    }
    private static func validateNumbers(_ values: [Float], count: Int) throws {
        guard values.count == count, values.allSatisfy(\.isFinite) else { throw cardEditError("Edited values must contain exactly \(count) finite float32 numbers.") }
    }
    private static func editedPNG(_ candidate: Data?, original: Data) throws -> Data {
        guard let candidate else { return original }
        if candidate.isEmpty { return candidate }
        var reader = try CardReader(candidate)
        let png = try reader.pngIfPresent()
        guard !png.isEmpty, reader.remaining == 0 else { throw cardEditError("Replacement thumbnail must be exactly one PNG.") }
        return png
    }
}

private struct CardNumericEdit {
    let path: [SourceCharacterCard.Field], values: [Float]
}
func cardEditError(_ message: String) -> SourceCharacterCardError { .invalid(message) }
func cardLittle(_ bits: UInt64, count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }) }
func cardBig(_ bits: UInt64, count: Int) -> Data { Data(cardLittle(bits, count: count).reversed()) }
func cardLengthData(_ data: Data) -> Data { cardLittle(UInt64(data.count), count: 4) + data }
func cardInteger(_ number: Int) -> Data { Data([0xd3]) + cardBig(UInt64(number), count: 8) }
func cardBinary(_ data: Data) -> Data { Data([0xc6]) + cardBig(UInt64(data.count), count: 4) + data }
