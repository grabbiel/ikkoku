import Foundation

public enum SourceMessagePackError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self { case .invalid(let reason): return "Invalid source MessagePack: \(reason)." }
    }
}

/// Wire values without schema-specific coercion. Map order, duplicate keys, and
/// unknown extension payloads are preserved until a caller requests a typed map.
public enum SourceMessagePackValue: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let key: SourceMessagePackValue
        public let value: SourceMessagePackValue
        public init(key: SourceMessagePackValue, value: SourceMessagePackValue) {
            self.key = key; self.value = value
        }
    }

    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
    case float(Double)
    case string(String)
    case binary(Data)
    case array([Self])
    case map([Entry])
    case ext(Int8, Data)

    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var integerValue: Int? {
        switch self {
        case .integer(let value): return Int(exactly: value)
        case .unsigned(let value): return Int(exactly: value)
        default: return nil
        }
    }
    public var arrayValue: [Self]? { if case .array(let value) = self { return value }; return nil }
    public var binaryValue: Data? { if case .binary(let value) = self { return value }; return nil }

    /// Schema-bound maps must not silently overwrite duplicate or non-string keys.
    public func stringKeyedMap() throws -> [String: Self] {
        guard case .map(let entries) = self else { throw SourceMessagePackError.invalid("expected a map") }
        var result: [String: Self] = [:]
        for entry in entries {
            guard case .string(let key) = entry.key else { throw SourceMessagePackError.invalid("map key is not a string") }
            guard result.updateValue(entry.value, forKey: key) == nil else {
                throw SourceMessagePackError.invalid("duplicate string map key '\(key)'")
            }
        }
        return result
    }
}

public enum SourceMessagePack {
    /// Limits apply independently to encoded and decompressed bytes. At most
    /// 1,000,000 total values (including map keys) and 64 container levels decode.
    public static func decode(_ data: Data, maximumBytes: Int = 64 * 1024 * 1024) throws -> SourceMessagePackValue {
        try validate(data: data, maximumBytes: maximumBytes)
        var reader = Reader(bytes: Array(data))
        let value = try reader.value(depth: 0)
        guard reader.offset == reader.bytes.count else { throw SourceMessagePackError.invalid("trailing bytes") }
        return value
    }

    /// Original MessagePack v1 LZ4MessagePackSerializer framing: extension 99,
    /// MessagePack Int32 expanded length, then a raw LZ4 block. Its writer forces
    /// ext32/int32; its reader accepts other integer encodings fitting Int32.
    /// Only the top-level compression wrapper is interpreted. Other extensions
    /// remain values, and both outer and expanded MessagePack consume exactly.
    public static func decodeLZ4(_ data: Data, maximumBytes: Int = 64 * 1024 * 1024) throws -> SourceMessagePackValue {
        let outer = try decode(data, maximumBytes: maximumBytes)
        guard case .ext(99, let payload) = outer else { return outer }
        var reader = Reader(bytes: Array(payload))
        let sizeValue = try reader.value(depth: 0)
        guard let size = sizeValue.integerValue, size > 0, size <= Int(Int32.max), size <= maximumBytes else {
            throw SourceMessagePackError.invalid("LZ4 expanded size must be a positive bounded Int32")
        }
        let expanded = try expandLZ4(reader.bytes, offset: reader.offset, size: size)
        return try decode(Data(expanded), maximumBytes: maximumBytes)
    }

    private static func validate(data: Data, maximumBytes: Int) throws {
        guard maximumBytes > 0, !data.isEmpty, data.count <= maximumBytes else {
            throw SourceMessagePackError.invalid("empty input or byte limit exceeded")
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var remainingValues = 1_000_000

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw SourceMessagePackError.invalid("truncated value") }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func word(_ count: Int) throws -> UInt64 {
            guard count <= bytes.count - offset else { throw SourceMessagePackError.invalid("truncated numeric value") }
            var result: UInt64 = 0
            for _ in 0..<count { result = result << 8 | UInt64(bytes[offset]); offset += 1 }
            return result
        }

        mutating func data(_ count: Int) throws -> Data {
            guard count >= 0, count <= bytes.count - offset else { throw SourceMessagePackError.invalid("truncated byte payload") }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }

        mutating func string(_ count: Int) throws -> SourceMessagePackValue {
            guard let result = String(data: try data(count), encoding: .utf8) else {
                throw SourceMessagePackError.invalid("string is not valid UTF-8")
            }
            return .string(result)
        }

        mutating func array(_ count: Int, depth: Int) throws -> SourceMessagePackValue {
            try container(count: count, depth: depth)
            var result: [SourceMessagePackValue] = []
            result.reserveCapacity(count)
            for _ in 0..<count { result.append(try value(depth: depth + 1)) }
            return .array(result)
        }

        mutating func map(_ count: Int, depth: Int) throws -> SourceMessagePackValue {
            // Counts are uint32, hence doubling is safe on supported 64-bit hosts.
            try container(count: count * 2, depth: depth)
            var result: [SourceMessagePackValue.Entry] = []
            result.reserveCapacity(count)
            for _ in 0..<count {
                let key = try value(depth: depth + 1)
                result.append(.init(key: key, value: try value(depth: depth + 1)))
            }
            return .map(result)
        }

        func container(count: Int, depth: Int) throws {
            guard depth < 64 else { throw SourceMessagePackError.invalid("container nesting exceeds 64") }
            guard count <= remainingValues else { throw SourceMessagePackError.invalid("decoded value limit exceeded") }
            // Each child needs at least one encoded byte; check before reserving.
            guard count <= bytes.count - offset else { throw SourceMessagePackError.invalid("truncated container") }
        }

        mutating func extended(_ count: Int) throws -> SourceMessagePackValue {
            let type = Int8(bitPattern: try byte())
            return .ext(type, try data(count))
        }

        mutating func value(depth: Int) throws -> SourceMessagePackValue {
            guard remainingValues > 0 else { throw SourceMessagePackError.invalid("decoded value limit exceeded") }
            remainingValues -= 1
            let code = try byte()
            switch code {
            case 0x00...0x7f: return .integer(Int64(code))
            case 0x80...0x8f: return try map(Int(code & 15), depth: depth)
            case 0x90...0x9f: return try array(Int(code & 15), depth: depth)
            case 0xa0...0xbf: return try string(Int(code & 31))
            case 0xc0: return .null
            case 0xc1: throw SourceMessagePackError.invalid("reserved code 0xc1")
            case 0xc2: return .bool(false)
            case 0xc3: return .bool(true)
            case 0xc4: let count = Int(try word(1)); return .binary(try data(count))
            case 0xc5: let count = Int(try word(2)); return .binary(try data(count))
            case 0xc6: let count = Int(try word(4)); return .binary(try data(count))
            case 0xc7: let count = Int(try word(1)); return try extended(count)
            case 0xc8: let count = Int(try word(2)); return try extended(count)
            case 0xc9: let count = Int(try word(4)); return try extended(count)
            case 0xca: return .float(Double(Float(bitPattern: UInt32(try word(4)))))
            case 0xcb: return .float(Double(bitPattern: try word(8)))
            case 0xcc: return .unsigned(try word(1))
            case 0xcd: return .unsigned(try word(2))
            case 0xce: return .unsigned(try word(4))
            case 0xcf: return .unsigned(try word(8))
            case 0xd0: return .integer(Int64(Int8(bitPattern: UInt8(try word(1)))))
            case 0xd1: return .integer(Int64(Int16(bitPattern: UInt16(try word(2)))))
            case 0xd2: return .integer(Int64(Int32(bitPattern: UInt32(try word(4)))))
            case 0xd3: return .integer(Int64(bitPattern: try word(8)))
            case 0xd4: return try extended(1)
            case 0xd5: return try extended(2)
            case 0xd6: return try extended(4)
            case 0xd7: return try extended(8)
            case 0xd8: return try extended(16)
            case 0xd9: let count = Int(try word(1)); return try string(count)
            case 0xda: let count = Int(try word(2)); return try string(count)
            case 0xdb: let count = Int(try word(4)); return try string(count)
            case 0xdc: let count = Int(try word(2)); return try array(count, depth: depth)
            case 0xdd: let count = Int(try word(4)); return try array(count, depth: depth)
            case 0xde: let count = Int(try word(2)); return try map(count, depth: depth)
            case 0xdf: let count = Int(try word(4)); return try map(count, depth: depth)
            case 0xe0...0xff: return .integer(Int64(Int8(bitPattern: code)))
            default: throw SourceMessagePackError.invalid("unrecognized code")
            }
        }
    }

    private static func expandLZ4(_ input: [UInt8], offset: Int, size: Int) throws -> [UInt8] {
        var cursor = offset
        var result: [UInt8] = []
        result.reserveCapacity(size)
        var lastMatchStart: Int?

        func length(_ nibble: Int, base: Int) throws -> Int {
            var length = nibble + base
            let available = size - result.count
            guard length <= available else { throw SourceMessagePackError.invalid("LZ4 output exceeds declared size") }
            if nibble == 15 {
                while true {
                    guard cursor < input.count else { throw SourceMessagePackError.invalid("truncated LZ4 length") }
                    let extra = Int(input[cursor]); cursor += 1
                    guard extra <= available - length else { throw SourceMessagePackError.invalid("LZ4 output exceeds declared size") }
                    length += extra
                    if extra != 255 { break }
                }
            }
            return length
        }

        while cursor < input.count {
            let token = input[cursor]; cursor += 1
            let literalCount = try length(Int(token >> 4), base: 0)
            guard literalCount <= input.count - cursor else { throw SourceMessagePackError.invalid("truncated LZ4 literals") }
            result.append(contentsOf: input[cursor..<(cursor + literalCount)])
            cursor += literalCount
            if cursor == input.count {
                guard result.count == size else { throw SourceMessagePackError.invalid("LZ4 expanded size mismatch") }
                // Standard raw LZ4 requires a final literal-only sequence and,
                // after a match, five final literals and a 12-byte match margin.
                if let lastMatchStart {
                    guard literalCount >= 5, size - lastMatchStart >= 12 else {
                        throw SourceMessagePackError.invalid("invalid LZ4 final sequence")
                    }
                }
                return result
            }
            guard input.count - cursor >= 2 else { throw SourceMessagePackError.invalid("truncated LZ4 match offset") }
            let distance = Int(input[cursor]) | Int(input[cursor + 1]) << 8
            cursor += 2
            guard distance > 0, distance <= result.count else { throw SourceMessagePackError.invalid("invalid LZ4 match offset") }
            let matchCount = try length(Int(token & 15), base: 4)
            lastMatchStart = result.count
            // A match may overlap itself: read each newly appended byte in order.
            for _ in 0..<matchCount { result.append(result[result.count - distance]) }
        }
        throw SourceMessagePackError.invalid("missing LZ4 final literal sequence")
    }
}
