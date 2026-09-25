import Foundation
import Assets

/// A bounded token index, used only for editing existing fields. It never
/// re-encodes an unknown value or normalizes a map, numeric token or extension.
struct CardBytePatch {
    let range: Range<Int>, replacement: Data
}
struct CardTokenDocument {
    struct Node {
        enum Kind { case scalar, array, map }
        let kind: Kind, range: Range<Int>, children: [Node]
    }
    let data: Data, root: Node
    init(_ data: Data) throws {
        _ = try SourceMessagePack.decode(data)
        var scanner = Scanner(data: data)
        root = try scanner.node(depth: 0)
        guard scanner.offset == data.count else { throw cardEditError("Trailing MessagePack bytes.") }
        self.data = data
    }
    func value(_ node: Node) throws -> SourceMessagePackValue {
        try SourceMessagePack.decode(data.subdata(in: node.range))
    }
    func node(at path: [SourceCharacterCard.Field]) throws -> Node {
        var selected = root
        for component in path {
            switch component {
            case .index(let index):
                guard selected.kind == .array, selected.children.indices.contains(index) else { throw cardEditError("Array edit index is unavailable.") }
                selected = selected.children[index]
            case .key(let key):
                guard selected.kind == .map else { throw cardEditError("Edit path expected a string map.") }
                var keys = Set<String>(), found: Node?
                for index in stride(from: 0, to: selected.children.count, by: 2) {
                    guard let name = try value(selected.children[index]).stringValue, keys.insert(name).inserted else { throw cardEditError("Edited map has a non-string or duplicate key.") }
                    if name == key { found = selected.children[index + 1] }
                }
                guard let found else { throw cardEditError("Editable field '\(key)' is absent.") }
                selected = found
            }
        }
        return selected
    }
    func applying(_ patches: [CardBytePatch]) throws -> Data {
        var cursor = 0, result = Data()
        for patch in patches.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard patch.range.lowerBound >= cursor, patch.range.upperBound <= data.count else { throw cardEditError("Overlapping or invalid byte edits.") }
            result += data.subdata(in: cursor..<patch.range.lowerBound)
            result += patch.replacement
            cursor = patch.range.upperBound
            guard result.count <= 64 * 1024 * 1024 else { throw cardEditError("Edited MessagePack exceeds 64 MiB.") }
        }
        result += data.subdata(in: cursor..<data.count)
        guard result.count <= 64 * 1024 * 1024 else { throw cardEditError("Edited MessagePack exceeds 64 MiB.") }
        return result
    }
    private struct Scanner {
        let data: Data
        var offset = 0, budget = 1_000_000
        mutating func word(_ count: Int) throws -> Int {
            guard count <= data.count - offset else { throw cardEditError("Truncated MessagePack token.") }
            var result = 0
            for _ in 0..<count { result = (result << 8) | Int(data[offset]); offset += 1 }
            return result
        }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= data.count - offset else { throw cardEditError("Truncated MessagePack value.") }
            offset += count
        }
        mutating func node(depth: Int) throws -> Node {
            guard budget > 0 else { throw cardEditError("MessagePack token budget exceeded.") }
            budget -= 1
            let start = offset, code = try word(1)
            var kind = Node.Kind.scalar, count = 0, bytes = 0
            switch code {
            case 0x00...0x7f, 0xc0, 0xc2, 0xc3, 0xe0...0xff: break
            case 0x80...0x8f: kind = .map; count = (code & 15) * 2
            case 0x90...0x9f: kind = .array; count = code & 15
            case 0xa0...0xbf: bytes = code & 31
            case 0xcc, 0xd0: bytes = 1
            case 0xcd, 0xd1: bytes = 2
            case 0xca, 0xce, 0xd2: bytes = 4
            case 0xcb, 0xcf, 0xd3: bytes = 8
            case 0xc4, 0xd9: bytes = try word(1)
            case 0xc5, 0xda: bytes = try word(2)
            case 0xc6, 0xdb: bytes = try word(4)
            case 0xc7: bytes = try word(1) + 1
            case 0xc8: bytes = try word(2) + 1
            case 0xc9: bytes = try word(4) + 1
            case 0xd4...0xd8: bytes = (1 << (code - 0xd4)) + 1
            case 0xdc: kind = .array; count = try word(2)
            case 0xdd: kind = .array; count = try word(4)
            case 0xde: kind = .map; count = try word(2) * 2
            case 0xdf: kind = .map; count = try word(4) * 2
            default: throw cardEditError("Invalid MessagePack token.")
            }
            try skip(bytes)
            var children: [Node] = []
            if kind != .scalar {
                guard depth < 64, count <= budget, count <= data.count - offset else { throw cardEditError("MessagePack container bounds exceeded.") }
                children.reserveCapacity(count)
                for _ in 0..<count { children.append(try node(depth: depth + 1)) }
            }
            return .init(kind: kind, range: start..<offset, children: children)
        }
    }
}
