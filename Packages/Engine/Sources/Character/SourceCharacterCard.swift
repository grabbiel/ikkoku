import Foundation
import CryptoKit
import Assets

public enum SourceCharacterCardError: Error, LocalizedError, CustomStringConvertible, Sendable {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): message } }
    public var errorDescription: String? { description }
}

/// Original card framing and opaque blocks. Keeping the original bytes is essential:
/// decoding selected settings is not permission to discard unknown mod data.
public struct SourceCharacterCard: Sendable {
    public struct Block: Sendable {
        public let name: String, version: String, position: Int, data: Data
    }
    public struct Customization: Sendable {
        public let faceValues: [Float], bodyValues: [Float], headID: Int, sex: Int, boneType: Int, exType: Int
    }
    public struct PluginData: Sendable {
        public let id: String, version: Int, data: [String: SourceMessagePackValue]?
    }
    public struct Extensions: Sendable {
        public let format: String?, plugins: [String: PluginData], diagnostics: [String]
    }
    public struct PreviewSettings: Sendable {
        public let faceValues: [Float], bodyValues: [Float]
        public let boneModifiers: SourceBoneModifiers?
        public let diagnostics: [String]
    }
    public let product: Int, version: String, sourceSHA256: String
    public let thumbnailData: Data, faceThumbnailData: Data, headerData: Data
    public let blocks: [Block], trailingData: Data, payloadSize: Int
    /// Byte-identical source, including thumbnail, unknown blocks, gaps and trailers.
    public let preservedData: Data
    let payloadOffset: Int

    public static func load(url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0,
              size.int64Value <= CardReader.maximumBytes else {
            throw SourceCharacterCardError.invalid("Source card must be a regular file no larger than 256 MiB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try decode(handle.read(upToCount: CardReader.maximumBytes + 1) ?? Data())
    }

    public static func decode(_ data: Data) throws -> Self {
        var reader = try CardReader(data)
        let thumbnail = try reader.pngIfPresent()
        let product = try reader.nonnegativeInt32()
        guard product == 100, try reader.string() == "【KoiKatuChara】" else {
            throw SourceCharacterCardError.invalid("Unsupported source card product or character-card marker.")
        }
        let version = try reader.string()
        guard version == "0.0.0" else { throw SourceCharacterCardError.invalid("Unsupported source character-card version '\(version)'.") }
        let face = try reader.lengthPrefixedData()
        let header = try reader.lengthPrefixedData(maximum: 1024 * 1024)
        let fields = try SourceMessagePack.decode(header, maximumBytes: 1024 * 1024).stringKeyedMap()
        guard let info = fields["lstInfo"]?.arrayValue, info.count <= 1024 else {
            throw SourceCharacterCardError.invalid("Source card block header has no bounded lstInfo array.")
        }
        let payloadSize = try reader.nonnegativeInt64()
        let payloadOffset = reader.offset
        let payload = try reader.take(payloadSize)
        var blocks: [Block] = [], names = Set<String>(), occupied: [Range<Int>] = []
        for value in info {
            let fields = try value.stringKeyedMap()
            guard let name = fields["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 1024,
                  !name.contains("\0"), names.insert(name).inserted,
                  let version = fields["version"]?.stringValue, version.utf8.count <= 128,
                  let position = fields["pos"]?.integerValue, let size = fields["size"]?.integerValue,
                  position >= 0, position <= payload.count, size >= 0, size <= payload.count - position else {
                throw SourceCharacterCardError.invalid("Source card block has an invalid identity or payload range.")
            }
            let range = position..<(position + size)
            guard range.isEmpty || !occupied.contains(where: { $0.overlaps(range) }) else {
                throw SourceCharacterCardError.invalid("Source card blocks overlap.")
            }
            if !range.isEmpty { occupied.append(range) }
            blocks.append(Block(name: name, version: version, position: position, data: payload.subdata(in: range)))
        }
        return Self(product: product, version: version,
            sourceSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            thumbnailData: thumbnail, faceThumbnailData: face, headerData: header, blocks: blocks,
            trailingData: try reader.take(reader.remaining), payloadSize: payloadSize, preservedData: data,
            payloadOffset: payloadOffset)
    }

    public func block(named name: String) -> Block? { blocks.first { $0.name == name } }

    /// Current Extended Save is a normal block. A valid legacy trailer takes
    /// precedence, matching the installed plugin's load postfix.
    public func extensions() throws -> Extensions {
        var format: String?, diagnostics: [String] = [], plugins: [String: PluginData] = [:]
        if let current = block(named: "KKEx") {
            if current.version == "3" {
                // The installed hook computes its base from the payload end and
                // sum of sizes, not the normal payload start. Preserve that rule
                // even when the block ranges leave gaps in the payload.
                do {
                    let start = payloadOffset + payloadSize - blocks.reduce(0, { $0 + $1.data.count }) + current.position
                    guard start >= 0, start <= preservedData.count else {
                        throw SourceCharacterCardError.invalid("Extended Save hook offset is outside the source card.")
                    }
                    let count = min(current.data.count, preservedData.count - start)
                    let decoded = try Self.pluginData(preservedData.subdata(in: start..<(start + count)))
                    plugins = decoded.plugins; diagnostics += decoded.diagnostics; format = "block-v3"
                } catch { diagnostics.append("Current Extended Save could not be read: \(error). Its bytes remain preserved.") }
            } else { diagnostics.append("Extended Save block version \(current.version) is preserved but unsupported.") }
        }
        if !trailingData.isEmpty {
            var legacy = try CardReader(trailingData)
            if (try? legacy.string()) == "KKEx" {
                do {
                    let version = try legacy.nonnegativeInt32()
                    if version == 2 {
                        let declaredCount = try legacy.nonnegativeInt32(maximum: 64 * 1024 * 1024)
                        guard declaredCount > 0 else { throw SourceCharacterCardError.invalid("Legacy Extended Save has an empty payload.") }
                        // BinaryReader.ReadBytes may return fewer bytes at EOF.
                        let payload = try legacy.take(min(declaredCount, legacy.remaining))
                        let decoded = try Self.pluginData(payload)
                        plugins = decoded.plugins; diagnostics += decoded.diagnostics; format = "trailer-v2"
                        if legacy.remaining > 0 { diagnostics.append("Bytes after legacy Extended Save remain preserved and uninterpreted.") }
                    } else { diagnostics.append("Legacy Extended Save version \(version) is preserved but unsupported.") }
                } catch { diagnostics.append("Legacy Extended Save could not be read; current block data remains selected: \(error).") }
            } else { diagnostics.append("Unknown source-card trailer remains preserved and uninterpreted.") }
        }
        return Extensions(format: format, plugins: plugins, diagnostics: diagnostics)
    }

    private static func pluginData(_ bytes: Data) throws -> (plugins: [String: PluginData], diagnostics: [String]) {
        var diagnostics: [String] = []
        let value = try SourceMessagePack.decode(bytes)
        if case .null = value { return ([:], []) }
        let entries = try value.stringKeyedMap()
        guard entries.count <= 4096 else { throw SourceCharacterCardError.invalid("Extended Save exceeds 4096 plug-in entries.") }
        var plugins: [String: PluginData] = [:]
        for (id, value) in entries {
            guard id.utf8.count <= 4096 else { throw SourceCharacterCardError.invalid("Extended Save plug-in identity exceeds 4096 bytes.") }
            if case .null = value { diagnostics.append("Null plug-in entry '\(id)' remains preserved."); continue }
            guard let fields = value.arrayValue else {
                throw SourceCharacterCardError.invalid("Invalid Extended Save PluginData entry '\(id)'.")
            }
            let version = fields.isEmpty ? 0 : fields[0].integerValue
            guard let version, Int32(exactly: version) != nil else {
                throw SourceCharacterCardError.invalid("Invalid Extended Save version for '\(id)'.")
            }
            let data: [String: SourceMessagePackValue]?
            if fields.count < 2 { data = nil }
            else if case .null = fields[1] { data = nil }
            else { data = try fields[1].stringKeyedMap() }
            plugins[id] = PluginData(id: id, version: version, data: data)
        }
        return (plugins, diagnostics)
    }

    public func boneModifiers() throws -> SourceBoneModifiers? {
        try Self.boneModifiers(from: extensions())
    }

    private static func boneModifiers(from extensions: Extensions) throws -> SourceBoneModifiers? {
        guard let plugin = extensions.plugins["KKABMPlugin.ABMData"] else { return nil }
        guard let value = plugin.data?["boneData"] else { return nil }
        guard let bytes = value.binaryValue else { throw SourceCharacterCardError.invalid("ABMX boneData is not a binary payload.") }
        return try SourceBoneModifiers.decodeBoneData(bytes, dataKind: "card", dataVersion: plugin.version)
    }

    /// Explicit assembly identity prevents applying a card to the wrong native
    /// rig. Defaults retain the original female head-00 call-site behavior.
    public func previewSettings(contract: SourceShapeContract, sex: Int = 1,
                                headID: Int = 0, boneType: Int = 0) throws -> PreviewSettings {
        let source = try customization()
        guard source.exType == 0 else {
            throw SourceCharacterCardError.invalid("This card uses a special character assembly (exType \(source.exType)) that is not supported by the native preview.")
        }
        guard source.sex == sex, source.headID == headID, source.boneType == boneType else {
            throw SourceCharacterCardError.invalid("Card character sex, head or body-bone identity does not match the selected source assembly.")
        }
        guard contract.domain("body")?.defaultValues.count == 44,
              contract.domain("face")?.defaultValues.count == 52 else {
            throw SourceCharacterCardError.invalid("The current source rig lacks the required 44-body/52-face shape contract.")
        }
        let body = source.bodyValues
        guard source.faceValues.allSatisfy({ (0...1).contains($0) }), body.allSatisfy({ (0...1).contains($0) }) else {
            throw SourceCharacterCardError.invalid("This card uses extended shape ranges not yet supported by the native shape evaluator.")
        }
        let extensions = try extensions()
        var diagnostics = ["Applied 52 face controls and 44 body controls. Card appearance compatibility is reported separately; unsupported asset selections and plug-in data remain preserved."]
            + extensions.diagnostics
        for id in extensions.plugins.keys.sorted() where id != "KKABMPlugin.ABMData" && !SourceCardModReferences.pluginIDs.contains(id) {
            diagnostics.append("Plug-in data preserved without execution: \(id).")
        }
        let modifiers = try Self.boneModifiers(from: extensions)
        diagnostics += (modifiers?.diagnostics ?? []).map(\.message)
        return PreviewSettings(faceValues: source.faceValues, bodyValues: body, boneModifiers: modifiers, diagnostics: diagnostics)
    }

    /// Decode only the current shape records. Materials, hair, outfits and modded
    /// asset selections remain preserved in the original blocks for future adapters.
    public func customization() throws -> Customization {
        guard let custom = block(named: "Custom"), custom.version == "0.0.0" else {
            throw SourceCharacterCardError.invalid("Source card has no supported Custom block.")
        }
        var reader = try CardReader(custom.data)
        let face = try SourceMessagePack.decode(reader.lengthPrefixedData()).stringKeyedMap()
        let body = try SourceMessagePack.decode(reader.lengthPrefixedData()).stringKeyedMap()
        _ = try reader.lengthPrefixedData() // Hair bytes stay in the unchanged Custom block.
        guard reader.remaining == 0 else { throw SourceCharacterCardError.invalid("Unexpected bytes after source Custom records.") }
        guard face["version"]?.stringValue == "0.0.2", body["version"]?.stringValue == "0.0.2",
              let head = face["headId"]?.integerValue else {
            throw SourceCharacterCardError.invalid("Unsupported source face/body version or missing head identity.")
        }
        guard let parameter = block(named: "Parameter"), parameter.version == "0.0.5" else {
            throw SourceCharacterCardError.invalid("Source card has no supported Parameter block for character sex.")
        }
        let parameters = try SourceMessagePack.decode(parameter.data).stringKeyedMap()
        guard let sex = parameters["sex"]?.integerValue, sex == 0 || sex == 1 else {
            throw SourceCharacterCardError.invalid("Source card has no supported character sex.")
        }
        let exType: Int
        if let value = parameters["exType"] {
            guard let integer = value.integerValue, Int32(exactly: integer) != nil else {
                throw SourceCharacterCardError.invalid("Source character assembly type is not an int32.")
            }
            exType = integer
        } else { exType = 0 }
        let boneType: Int
        if let value = body["typeBone"] {
            guard let integer = value.integerValue, Int32(exactly: integer) != nil else {
                throw SourceCharacterCardError.invalid("Source body bone type is not an int32.")
            }
            boneType = integer
        } else { boneType = 0 }
        func shapes(_ value: SourceMessagePackValue?, count: Int) throws -> [Float] {
            guard let values = value?.arrayValue, values.count == count else {
                throw SourceCharacterCardError.invalid("Source card shape array has an unexpected size.")
            }
            return try values.map { value in
                let number: Double
                switch value {
                case .float(let float): number = float
                case .integer(let integer): number = Double(integer)
                case .unsigned(let integer): number = Double(integer)
                default: throw SourceCharacterCardError.invalid("Source shape value is not numeric.")
                }
                guard number.isFinite, abs(number) <= Double(Float.greatestFiniteMagnitude) else {
                    throw SourceCharacterCardError.invalid("Source shape value is not a finite float32.")
                }
                return Float(number)
            }
        }
        return try Customization(faceValues: shapes(face["shapeValueFace"], count: 52),
            bodyValues: shapes(body["shapeValueBody"], count: 44), headID: head, sex: sex,
            boneType: boneType, exType: exType)
    }
}

struct CardReader {
    static let maximumBytes = 256 * 1024 * 1024
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    init(_ data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw SourceCharacterCardError.invalid("Source card exceeds 256 MiB.") }
        self.data = Data(data)
    }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SourceCharacterCardError.invalid("Source card is truncated at byte \(offset).") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func unsigned(_ bytes: Int, bigEndian: Bool = false) throws -> UInt64 {
        let value = try take(bytes)
        if bigEndian { return value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
        return value.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    }
    mutating func lengthPrefixedData(maximum: Int = Self.maximumBytes) throws -> Data {
        let length = try nonnegativeInt32(maximum: maximum)
        return try take(length)
    }
    mutating func nonnegativeInt32(maximum: Int = Self.maximumBytes) throws -> Int {
        let value = Int32(bitPattern: UInt32(try unsigned(4)))
        guard value >= 0, value <= maximum else { throw SourceCharacterCardError.invalid("Invalid source card int32 length/value.") }
        return Int(value)
    }
    mutating func nonnegativeInt64() throws -> Int {
        let value = try unsigned(8)
        guard value <= Self.maximumBytes else { throw SourceCharacterCardError.invalid("Invalid source card int64 payload length.") }
        return Int(value)
    }
    mutating func string() throws -> String {
        var count = 0
        for index in 0..<5 {
            let byte = Int(try unsigned(1))
            if index == 4 && byte > 7 { throw SourceCharacterCardError.invalid("Invalid .NET string length.") }
            count |= (byte & 127) << (index * 7)
            if byte & 128 == 0 {
                guard count <= 1024 * 1024, let result = String(data: try take(count), encoding: .utf8) else {
                    throw SourceCharacterCardError.invalid("Source card string is oversized or invalid UTF-8.")
                }
                return result
            }
        }
        throw SourceCharacterCardError.invalid("Unterminated .NET string length.")
    }
    mutating func pngIfPresent() throws -> Data {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return Data() }
        offset = 8
        var seenHeader = false, chunkCount = 0
        while remaining > 0 {
            chunkCount += 1
            guard chunkCount <= 100_000 else { throw SourceCharacterCardError.invalid("Source PNG has too many chunks.") }
            let length = Int(try unsigned(4, bigEndian: true)), start = offset
            let type = try take(4)
            guard type.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }), length <= remaining - 4 else {
                throw SourceCharacterCardError.invalid("Source PNG has an invalid chunk.")
            }
            if !seenHeader {
                guard type == Data("IHDR".utf8), length == 13 else { throw SourceCharacterCardError.invalid("Source PNG lacks its IHDR.") }
                seenHeader = true
            } else if type == Data("IHDR".utf8) { throw SourceCharacterCardError.invalid("Source PNG has duplicate IHDR chunks.") }
            _ = try take(length)
            let expected = UInt32(try unsigned(4, bigEndian: true))
            var crc: UInt32 = .max
            for byte in data[start..<(start + 4 + length)] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
            }
            guard ~crc == expected else { throw SourceCharacterCardError.invalid("Source PNG chunk CRC does not match.") }
            if type == Data("IEND".utf8) {
                guard length == 0 else { throw SourceCharacterCardError.invalid("Source PNG IEND is not empty.") }
                return data.subdata(in: 0..<offset)
            }
        }
        throw SourceCharacterCardError.invalid("Source PNG is missing IEND.")
    }
}
