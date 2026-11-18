import Foundation

/// A dictionary key whose saved order is fixed (#394).
///
/// `Dictionary` encodes a key that is not `String`, `Int` or
/// `CodingKeyRepresentable` (an enum, `Int32`, `UUID`) as one array that
/// alternates keys and values: `["top", {…}, "bra", {…}]`. That array follows
/// the dictionary's iteration order, which depends on Swift's per-process hash
/// seed, and `JSONEncoder.OutputFormatting.sortedKeys` does not reach it. The
/// same card or document therefore saved different bytes in different runs.
///
/// For a conforming key, the `KeyedEncodingContainer` overloads below write the
/// same alternating array in `encodingPrecedes` order. Synthesized `Codable`
/// conformances pick the overloads up wherever this module is imported, so a
/// stored property keeps its type and the format does not change. Decoding is
/// untouched and accepts any order, including files written before this.
public protocol StableEncodingKey: Encodable, Hashable {
    /// Whether `lhs` is written before `rhs`.
    static func encodingPrecedes(_ lhs: Self, _ rhs: Self) -> Bool
}

extension StableEncodingKey where Self: CaseIterable {
    /// Declaration order (`allCases`).
    public static func encodingPrecedes(_ lhs: Self, _ rhs: Self) -> Bool {
        let cases = Array(allCases)
        guard let left = cases.firstIndex(of: lhs), let right = cases.firstIndex(of: rhs) else { return false }
        return left < right
    }
}

extension Int32: StableEncodingKey {
    public static func encodingPrecedes(_ lhs: Int32, _ rhs: Int32) -> Bool { lhs < rhs }
}

extension UUID: StableEncodingKey {
    /// The uppercase string `Codable` writes, in byte order.
    public static func encodingPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.utf8.lexicographicallyPrecedes(rhs.uuidString.utf8)
    }
}

extension KeyedEncodingContainer {
    /// `Dictionary`'s own alternating key/value array, in key order.
    public mutating func encode<EntryKey: StableEncodingKey, Value: Encodable>(_ value: [EntryKey: Value], forKey key: Key) throws {
        var array = nestedUnkeyedContainer(forKey: key)
        for (entryKey, entryValue) in value.sorted(by: { EntryKey.encodingPrecedes($0.key, $1.key) }) {
            try array.encode(entryKey)
            try array.encode(entryValue)
        }
    }

    /// The optional form synthesized conformances call; nil writes nothing.
    public mutating func encodeIfPresent<EntryKey: StableEncodingKey, Value: Encodable>(_ value: [EntryKey: Value]?, forKey key: Key) throws {
        guard let value else { return }
        try encode(value, forKey: key)
    }
}
