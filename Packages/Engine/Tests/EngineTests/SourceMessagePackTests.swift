import Foundation
import Testing
import Assets

private enum SourceMPFixture {
    static func word(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    static func hex(_ value: String) -> Data {
        let digits = Array(value.utf8)
        func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
        return Data(stride(from: 0, to: digits.count, by: 2).map { nibble(digits[$0]) << 4 | nibble(digits[$0 + 1]) })
    }

    static func wrapper(size: Int32, block: [UInt8]) -> Data {
        wrapper(header: [0xd2] + word(UInt64(UInt32(bitPattern: size)), count: 4), block: block)
    }

    static func wrapper(header: [UInt8], block: [UInt8]) -> Data {
        Data([0xc9] + word(UInt64(header.count + block.count), count: 4) + [99] + header + block)
    }

    static func literals(_ bytes: [UInt8]) -> [UInt8] {
        if bytes.count < 15 { return [UInt8(bytes.count << 4)] + bytes }
        var extra = bytes.count - 15
        var result: [UInt8] = [0xf0]
        while extra >= 255 { result.append(255); extra -= 255 }
        result.append(UInt8(extra))
        return result + bytes
    }

    // Independent Python msgpack + lz4.block outputs, synthetic data only.
    // These exercise distance-one overlap, extension lengths, and multiple matches.
    static let repeated = hex("c90000001563d20000025b4fc50258410100ffff41504141414141")
    static let periodic = hex("c90000003163d2000003efff0492da02586162636465666768696a6b6c6d6e6f0f00ffff387fc50190000102030400ff75500300010203")
}

@Test func sourceMessagePackDecodesAllScalarNumericCodesWithoutCoercion() throws {
    let cases: [([UInt8], SourceMessagePackValue)] = [
        ([0xc0], .null), ([0xc2], .bool(false)), ([0xc3], .bool(true)),
        ([0x00], .integer(0)), ([0x7f], .integer(127)), ([0xe0], .integer(-32)), ([0xff], .integer(-1)),
        ([0xcc, 0xff], .unsigned(255)), ([0xcd, 0xff, 0xff], .unsigned(65535)),
        ([0xce] + SourceMPFixture.word(UInt64(UInt32.max), count: 4), .unsigned(UInt64(UInt32.max))),
        ([0xcf] + SourceMPFixture.word(UInt64.max, count: 8), .unsigned(UInt64.max)),
        ([0xd0, 0x80], .integer(-128)), ([0xd1, 0x80, 0x00], .integer(-32768)),
        ([0xd2] + SourceMPFixture.word(0x80000000, count: 4), .integer(Int64(Int32.min))),
        ([0xd3] + SourceMPFixture.word(0x8000000000000000, count: 8), .integer(Int64.min)),
        ([0xd3] + SourceMPFixture.word(UInt64(Int64.max), count: 8), .integer(Int64.max)),
        ([0xca] + SourceMPFixture.word(UInt64(Float(-1.25).bitPattern), count: 4), .float(-1.25)),
        ([0xcb] + SourceMPFixture.word(Double.pi.bitPattern, count: 8), .float(.pi)),
    ]
    for (bytes, expected) in cases {
        let decoded = try SourceMessagePack.decode(Data(bytes))
        #expect(decoded == expected)
    }
    #expect(SourceMessagePackValue.unsigned(UInt64.max).integerValue == nil)
    #expect(SourceMessagePackValue.unsigned(42).integerValue == 42)
    #expect(SourceMessagePackValue.integer(-42).integerValue == -42)
    #expect(SourceMessagePackValue.float(42).integerValue == nil)
    #expect(SourceMessagePackValue.bool(true).integerValue == nil)
    for (bits, width, code): (UInt64, Int, UInt8) in [(0x7fc00001, 4, 0xca), (0x7ff0000000000000, 8, 0xcb)] {
        let value = try SourceMessagePack.decode(Data([code] + SourceMPFixture.word(bits, count: width)))
        guard case .float(let number) = value else { Issue.record("Expected floating point value"); continue }
        #expect(width == 4 ? number.isNaN : number == .infinity)
    }
}

@Test func sourceMessagePackDecodesStringBinaryAndAllContainerLengthForms() throws {
    let utf8 = Array("骨".utf8)
    for header: [UInt8] in [[0xa3], [0xd9, 3], [0xda, 0, 3], [0xdb, 0, 0, 0, 3]] {
        let value = try SourceMessagePack.decode(Data(header + utf8))
        #expect(value.stringValue == "骨")
    }
    for header: [UInt8] in [[0xc4, 3], [0xc5, 0, 3], [0xc6, 0, 0, 0, 3]] {
        let value = try SourceMessagePack.decode(Data(header + [0, 255, 193]))
        #expect(value.binaryValue == Data([0, 255, 193]))
    }
    for header: [UInt8] in [[0x92], [0xdc, 0, 2], [0xdd, 0, 0, 0, 2]] {
        let value = try SourceMessagePack.decode(Data(header + [0xc0, 0xc3]))
        #expect(value.arrayValue == [.null, .bool(true)])
    }
    for header: [UInt8] in [[0x81], [0xde, 0, 1], [0xdf, 0, 0, 0, 1]] {
        let value = try SourceMessagePack.decode(Data(header + [0xa1, 0x61, 7]))
        #expect(try value.stringKeyedMap() == ["a": .integer(7)])
    }
    let emptyCodes: [(UInt8, SourceMessagePackValue)] = [(0xa0, .string("")), (0x90, .array([])), (0x80, .map([]))]
    for (code, expected) in emptyCodes { #expect(try SourceMessagePack.decode(Data([code])) == expected) }
    let slice = Data([0xc1, 0xa1, 0x61]).dropFirst()
    #expect(try SourceMessagePack.decode(slice) == .string("a"))
}

@Test func sourceMessagePackPreservesUnknownExtensionsAndOrderedMapEntries() throws {
    for (code, count): (UInt8, Int) in [(0xd4, 1), (0xd5, 2), (0xd6, 4), (0xd7, 8), (0xd8, 16)] {
        let bytes = Array(repeating: UInt8(42), count: count)
        #expect(try SourceMessagePack.decode(Data([code, 0xff] + bytes)) == .ext(-1, Data(bytes)))
    }
    for header: [UInt8] in [[0xc7, 3], [0xc8, 0, 3], [0xc9, 0, 0, 0, 3]] {
        #expect(try SourceMessagePack.decode(Data(header + [77, 1, 2, 3])) == .ext(77, Data([1, 2, 3])))
    }
    #expect(try SourceMessagePack.decode(Data([0xc7, 0, 5])) == .ext(5, Data()))
    #expect(try SourceMessagePack.decodeLZ4(Data([0xd4, 55, 0x42])) == .ext(55, Data([0x42])))
    let value = try SourceMessagePack.decode(Data([0x83, 0xa1, 0x61, 1, 0xa1, 0x61, 2, 3, 0xc0]))
    #expect(value == .map([.init(key: .string("a"), value: .integer(1)),
                          .init(key: .string("a"), value: .integer(2)), .init(key: .integer(3), value: .null)]))
    #expect(throws: SourceMessagePackError.self) { try value.stringKeyedMap() }
    #expect(throws: SourceMessagePackError.self) {
        try SourceMessagePackValue.map([.init(key: .integer(0), value: .null)]).stringKeyedMap()
    }
    #expect(throws: SourceMessagePackError.self) { try SourceMessagePackValue.null.stringKeyedMap() }
}

@Test func sourceMessagePackRejectsTruncationReservedCodeInvalidUTF8AndTrailingBytes() throws {
    let fixtures: [[UInt8]] = [
        [0xcd, 1, 2], [0xd3] + Array(repeating: 0, count: 8),
        [0xcb] + SourceMPFixture.word(Double.pi.bitPattern, count: 8),
        [0xdb, 0, 0, 0, 3] + Array("骨".utf8), [0xc6, 0, 0, 0, 3, 0, 1, 2],
        [0xc9, 0, 0, 0, 2, 0xff, 8, 9], [0xd8, 0xff] + Array(repeating: 0, count: 16),
        [0x92, 0xc0, 0x81, 0xa1, 0x61, 1],
    ]
    for fixture in fixtures {
        for count in 0..<fixture.count {
            #expect(throws: SourceMessagePackError.self) { try SourceMessagePack.decode(Data(fixture.prefix(count))) }
        }
    }
    for invalid: [UInt8] in [[0xc1], [0xa1, 0xff], [0xa2, 0xc0, 0x80], [0xa1, 0xc2], [0xc0, 0xc0],
                            [0xdb, 0xff, 0xff, 0xff, 0xff], [0xc6, 0xff, 0xff, 0xff, 0xff],
                            [0xdd, 0xff, 0xff, 0xff, 0xff], [0xdf, 0xff, 0xff, 0xff, 0xff]] {
        #expect(throws: SourceMessagePackError.self) { try SourceMessagePack.decode(Data(invalid)) }
    }
}

@Test func sourceMessagePackBoundsBytesNestingAndTotalValuesBeforeAllocation() throws {
    #expect(try SourceMessagePack.decode(Data([0xc0]), maximumBytes: 1) == .null)
    for limit in [-1, 0] {
        #expect(throws: SourceMessagePackError.self) { try SourceMessagePack.decode(Data([0xc0]), maximumBytes: limit) }
    }
    #expect(throws: SourceMessagePackError.self) { try SourceMessagePack.decode(Data([0xa1, 0x61]), maximumBytes: 1) }
    let nested = Data(Array(repeating: UInt8(0x91), count: 64) + [0xc0])
    _ = try SourceMessagePack.decode(nested)
    #expect(throws: SourceMessagePackError.self) { try SourceMessagePack.decode(Data([0x91]) + nested) }
    // Counts alone exceed the aggregate budget; no large input/allocation needed.
    for bytes: [UInt8] in [[0xdd, 0, 0x0f, 0x42, 0x40],
                          [0x92, 0xc0, 0xdd, 0, 0x0f, 0x42, 0x3e],
                          [0xdf, 0, 0x07, 0xa1, 0x20]] {
        #expect(throws: SourceMessagePackError.invalid("decoded value limit exceeded")) {
            try SourceMessagePack.decode(Data(bytes))
        }
    }
}

@Test func sourceMessagePackLZ4MatchesIndependentCompressedFixturesAndPlainFallback() throws {
    #expect(try SourceMessagePack.decodeLZ4(Data([0x92, 0xc0, 0xc3])) == .array([.null, .bool(true)]))
    #expect(try SourceMessagePack.decodeLZ4(SourceMPFixture.repeated) == .binary(Data(repeating: 65, count: 600)))
    let periodic = try SourceMessagePack.decodeLZ4(SourceMPFixture.periodic)
    #expect(periodic == .array([.string(String(repeating: "abcdefghijklmno", count: 40)),
                               .binary(Data(Array(repeating: [UInt8(0), 1, 2, 3], count: 100).flatMap { $0 }))]))
    let raw: [UInt8] = [0xc5, 0x02, 0x58] + Array(repeating: 0x41, count: 600)
    #expect(try SourceMessagePack.decodeLZ4(SourceMPFixture.wrapper(size: 603, block: SourceMPFixture.literals(raw)))
            == .binary(Data(repeating: 65, count: 600)))
    // Source ReadInt32 also accepts compact positive integer representations.
    #expect(try SourceMessagePack.decodeLZ4(SourceMPFixture.wrapper(header: [1], block: [0x10, 0xc0])) == .null)
    // Unknown extension payloads inside decompressed data are retained, not recursively interpreted.
    let nestedExtension: [UInt8] = [0xd4, 99, 0]
    #expect(try SourceMessagePack.decodeLZ4(SourceMPFixture.wrapper(size: 3, block: SourceMPFixture.literals(nestedExtension)))
            == .ext(99, Data([0])))
}

@Test func sourceMessagePackLZ4RejectsMalformedSizesOffsetsLengthsAndBombs() throws {
    for invalidSize: Int32 in [-1, 0, Int32.max] {
        #expect(throws: SourceMessagePackError.self) {
            try SourceMessagePack.decodeLZ4(SourceMPFixture.wrapper(size: invalidSize, block: [0x10, 0xc0]))
        }
    }
    for header: [UInt8] in [[], [0xd2], [0xd2, 0, 0], [0xc0], [0xc3], [0xca, 0x3f, 0x80, 0, 0],
                           [0xcf] + SourceMPFixture.word(UInt64.max, count: 8), [0xa1, 0x31]] {
        #expect(throws: SourceMessagePackError.self) {
            try SourceMessagePack.decodeLZ4(SourceMPFixture.wrapper(header: header, block: []))
        }
    }
    let invalidBlocks: [(Int32, [UInt8])] = [
        (1, []), (1, [0x10]), (1000, [0xf0]), (1000, [0xf0, 255]),
        (1, [0x20, 0xc0, 0xc0]), // Declared output overflow.
        (32, [0x10, 0xc0, 0, 0]), // Zero match distance.
        (32, [0x10, 0xc0, 2, 0]), // Match reaches before output start.
        (32, [0x10, 0xc0, 1]), // Truncated match distance.
        (10, [0x1f, 0xc0, 1, 0, 0]), // Match exceeds expanded size.
        (1000, [0x1f, 0xc0, 1, 0]), // Truncated extended match length.
        (5, [0x10, 0xc0, 1, 0]), // No final literal sequence.
        (6, [0x10, 0xc0, 1, 0, 0x10, 0xc0]), // Nonconforming short final literals.
        (2, [0x10, 0xc0]), // Expanded size mismatch.
        (2, [0x20, 0xc0, 0xc0]), // Expanded MessagePack has trailing data.
    ]
    for (size, block) in invalidBlocks {
        #expect(throws: SourceMessagePackError.self) {
            try SourceMessagePack.decodeLZ4(SourceMPFixture.wrapper(size: size, block: block))
        }
    }
    #expect(throws: SourceMessagePackError.self) {
        try SourceMessagePack.decodeLZ4(SourceMPFixture.repeated, maximumBytes: 100)
    }
    #expect(throws: SourceMessagePackError.self) {
        try SourceMessagePack.decodeLZ4(SourceMPFixture.repeated, maximumBytes: SourceMPFixture.repeated.count - 1)
    }
    #expect(throws: SourceMessagePackError.self) {
        try SourceMessagePack.decodeLZ4(SourceMPFixture.repeated + Data([0xc0]))
    }
    for count in 0..<SourceMPFixture.periodic.count {
        #expect(throws: SourceMessagePackError.self) { try SourceMessagePack.decodeLZ4(SourceMPFixture.periodic.prefix(count)) }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_ABMX_BONE_DATA"]),
               "Requires IKKOKU_ABMX_BONE_DATA"))
func sourceMessagePackOptionalOriginalABMXPayloadIsAnArray() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_ABMX_BONE_DATA")
    let value = try SourceMessagePack.decodeLZ4(Data(contentsOf: URL(fileURLWithPath: path)))
    let records = try #require(value.arrayValue)
    for record in records {
        let fields = try #require(record.arrayValue)
        #expect(fields.count == 3)
        #expect(fields.first?.stringValue != nil)
    }
}
