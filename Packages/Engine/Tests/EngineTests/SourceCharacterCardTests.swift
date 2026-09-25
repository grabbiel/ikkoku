import Foundation
import CryptoKit
import Testing
import Assets
import Character

/// Synthetic BinaryWriter/MessagePack bytes. This deliberately does not use an
/// engine card encoder, source game files, or native CharacterCard serialization.
enum OriginalCardFixture {
    typealias Value = SourceMessagePackValue
    struct Block {
        var name: String
        var version: String
        var data: Data
    }

    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    static let faceValues = (0..<52).map { Value.float(Double(Float($0) / 51)) }
    static let bodyValues = (0..<44).map { Value.float(Double(Float($0) / 43)) }

    static func number(_ bits: UInt64, count: Int, bigEndian: Bool = false) -> Data {
        let bytes = (0..<count).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        return Data(bigEndian ? bytes.reversed() : bytes)
    }
    static func i32(_ value: Int32) -> Data { number(UInt64(UInt32(bitPattern: value)), count: 4) }
    static func lengthData(_ value: Data) -> Data { i32(Int32(value.count)) + value }
    static func string(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        var count = bytes.count, prefix = Data()
        while count >= 128 { prefix.append(UInt8(count & 127) | 128); count >>= 7 }
        prefix.append(UInt8(count))
        return prefix + bytes
    }
    static func map(_ pairs: [(String, Value)]) -> Value {
        .map(pairs.map { .init(key: .string($0.0), value: $0.1) })
    }
    static func pack(_ value: Value) -> Data {
        switch value {
        case .null: return Data([0xc0])
        case .bool(let value): return Data([value ? 0xc3 : 0xc2])
        case .integer(let value): return Data([0xd3]) + number(UInt64(bitPattern: value), count: 8, bigEndian: true)
        case .unsigned(let value): return Data([0xcf]) + number(value, count: 8, bigEndian: true)
        case .float(let value): return Data([0xcb]) + number(value.bitPattern, count: 8, bigEndian: true)
        case .string(let value):
            let data = Data(value.utf8)
            return Data([0xdb]) + number(UInt64(data.count), count: 4, bigEndian: true) + data
        case .binary(let value): return Data([0xc6]) + number(UInt64(value.count), count: 4, bigEndian: true) + value
        case .array(let values):
            return Data([0xdd]) + number(UInt64(values.count), count: 4, bigEndian: true) + values.reduce(into: Data()) { $0 += pack($1) }
        case .map(let entries):
            return Data([0xdf]) + number(UInt64(entries.count), count: 4, bigEndian: true)
                + entries.reduce(into: Data()) { $0 += pack($1.key); $0 += pack($1.value) }
        case .ext(let type, let value):
            return Data([0xc9]) + number(UInt64(value.count), count: 4, bigEndian: true) + Data([UInt8(bitPattern: type)]) + value
        }
    }

    static func custom(face: [Value] = faceValues, body: [Value] = bodyValues,
                       faceVersion: String = "0.0.2", bodyVersion: String = "0.0.2",
                       head: Value = .integer(0), boneType: Value? = .integer(0)) -> Data {
        let faceData = pack(map([("version", .string(faceVersion)), ("headId", head), ("shapeValueFace", .array(face))]))
        var bodyFields: [(String, Value)] = [("version", .string(bodyVersion)), ("shapeValueBody", .array(body))]
        if let boneType { bodyFields.append(("typeBone", boneType)) }
        let bodyData = pack(map(bodyFields))
        // Hair is intentionally opaque and not even MessagePack-valid.
        return lengthData(faceData) + lengthData(bodyData) + lengthData(Data([0xc1, 0xfe, 0xed]))
    }

    static func blocks(custom: Data? = nil, sex: Value = .integer(1)) -> [Block] {
        [Block(name: "Custom", version: "0.0.0", data: custom ?? self.custom()),
         Block(name: "Parameter", version: "0.0.5", data: pack(map([("sex", sex), ("version", .string("0.0.5"))]))),
         Block(name: "FutureOpaque", version: "9.9", data: Data([0x00, 0xc1, 0xff, 0x42]))]
    }

    static func card(blocks: [Block]? = nil, order: [Int]? = nil,
                     positions: [Int64]? = nil, sizes: [Int64]? = nil,
                     payload overridePayload: Data? = nil, header overrideHeader: Data? = nil,
                     png: Data = Data(), facePNG: Data = Data([0x13, 0x37]), trailer: Data = Data(),
                     product: Int32 = 100, marker: String = "【KoiKatuChara】", version: String = "0.0.0") -> Data {
        let blocks = blocks ?? self.blocks()
        var position = 0
        let entries: [Value] = blocks.enumerated().map { index, block in
            defer { position += block.data.count }
            return map([("name", .string(block.name)), ("version", .string(block.version)),
                        ("pos", .integer(positions?[index] ?? Int64(position))),
                        ("size", .integer(sizes?[index] ?? Int64(block.data.count)))])
        }
        let ordered = (order ?? Array(blocks.indices)).map { entries[$0] }
        let header = overrideHeader ?? pack(map([("lstInfo", .array(ordered)), ("unknownHeader", .ext(19, Data([1, 2, 3])))]))
        let payload = overridePayload ?? blocks.reduce(into: Data()) { $0 += $1.data }
        return png + i32(product) + string(marker) + string(version) + lengthData(facePNG) + lengthData(header)
            + number(UInt64(payload.count), count: 8) + payload + trailer
    }

    static func legacy(_ value: Value, version: Int32 = 2, suffix: Data = Data()) -> Data {
        string("KKEx") + i32(version) + lengthData(pack(value)) + suffix
    }
    static func extended(_ value: Value, version: String = "3") -> Block {
        Block(name: "KKEx", version: version, data: pack(value))
    }
    static func plugin(_ version: Int64, data: Value = .null) -> Value { .array([.integer(version), data]) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func contract(bodyCount: Int = 44, faceCount: Int = 52) throws -> SourceShapeContract {
        func domain(_ name: String, count: Int) -> [String: Any] {
            ["id": name, "valueCount": count, "defaultValues": Array(repeating: 0.375, count: count),
             "sourceNames": [], "destinationNames": [], "channels": [], "directTargets": [], "unportedDestinationNames": [],
             "slots": (0..<count).map { ["index": $0, "label": "Synthetic", "bindings": []] as [String: Any] }]
        }
        return try SourceShapeContract.decode(JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "coordinateSystem": "UnityLeftHandedYUp", "rotationUnit": "degrees", "valueRange": [0, 1],
            "domains": [domain("body", count: bodyCount), domain("face", count: faceCount)]]))
    }
}

@Test func sourceCharacterCardReadsRawAndPNGFramingWithByteIdenticalOpaqueData() throws {
    let blocks = OriginalCardFixture.blocks()
    let trailer = Data([0xde, 0xad, 0xbe, 0xef])
    for thumbnail in [Data(), OriginalCardFixture.png] {
        let bytes = OriginalCardFixture.card(blocks: blocks, order: [2, 0, 1], png: thumbnail, trailer: trailer)
        let card = try SourceCharacterCard.decode(bytes)
        #expect(card.product == 100 && card.version == "0.0.0")
        #expect(card.preservedData == bytes && card.sourceSHA256 == OriginalCardFixture.hash(bytes))
        #expect(card.thumbnailData == thumbnail && card.faceThumbnailData == Data([0x13, 0x37]))
        #expect(card.blocks.map(\.name) == ["FutureOpaque", "Custom", "Parameter"])
        #expect(card.block(named: "FutureOpaque")?.data == blocks[2].data)
        #expect(card.block(named: "Custom")?.data == blocks[0].data)
        #expect(card.block(named: "Custom")?.position == 0)
        #expect(card.trailingData == trailer)
        let custom = try card.customization()
        #expect(custom.sex == 1 && custom.headID == 0 && custom.boneType == 0)
        #expect(custom.faceValues == (0..<52).map { Float($0) / 51 })
        #expect(custom.bodyValues == (0..<44).map { Float($0) / 43 })
        let extensions = try card.extensions()
        #expect(extensions.plugins.isEmpty && !extensions.diagnostics.isEmpty)
    }
}

@Test func sourceCharacterCardRejectsEveryTruncationOfACompleteRawCard() throws {
    let complete = OriginalCardFixture.card()
    for length in 0..<complete.count {
        #expect(throws: (any Error).self) { try SourceCharacterCard.decode(complete.prefix(length)) }
    }
    let slice = (Data([0xff]) + complete).dropFirst()
    #expect(try SourceCharacterCard.decode(slice).preservedData == complete)
    for bytes in [OriginalCardFixture.card(product: -1), OriginalCardFixture.card(product: 101),
                  OriginalCardFixture.card(marker: "OtherCard"), OriginalCardFixture.card(version: "1.0.0")] {
        #expect(throws: SourceCharacterCardError.self) { try SourceCharacterCard.decode(bytes) }
    }
}

@Test func sourceCharacterCardRejectsDuplicateOverlappingNegativeAndOutOfBoundsBlocks() throws {
    let blocks = [OriginalCardFixture.Block(name: "A", version: "0", data: Data([1, 2])),
                  OriginalCardFixture.Block(name: "B", version: "0", data: Data([3, 4]))]
    for positions: [Int64] in [[0, 1], [-1, 2], [0, 5], [0, Int64.max]] {
        #expect(throws: SourceCharacterCardError.self) {
            try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: blocks, positions: positions))
        }
    }
    for sizes: [Int64] in [[-1, 2], [2, 3], [Int64.max, 2]] {
        #expect(throws: SourceCharacterCardError.self) {
            try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: blocks, sizes: sizes))
        }
    }
    var duplicate = blocks; duplicate[1].name = "A"
    #expect(throws: SourceCharacterCardError.self) { try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: duplicate)) }
    var invalid = blocks; invalid[0].name = "bad\0name"
    #expect(throws: SourceCharacterCardError.self) { try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: invalid)) }
    let emptyAtEnd = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: blocks, positions: [0, 4], sizes: [2, 0]))
    #expect(emptyAtEnd.blocks[1].data.isEmpty && emptyAtEnd.blocks[1].position == 4)
    let gapPayload = Data([1, 2, 0xcc, 0xdd, 3, 4])
    let gap = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: blocks, positions: [0, 4], payload: gapPayload))
    #expect(gap.payloadSize == 6 && gap.blocks[1].data == Data([3, 4]))
    #expect(gap.preservedData.suffix(6) == gapPayload)
}

@Test func sourceCharacterCardValidatesHeaderAndPNGContainerIntegrity() throws {
    var corrupt = OriginalCardFixture.png
    corrupt[29] ^= 1 // IHDR CRC, independently of any card framing.
    for thumbnail in [corrupt, Data(OriginalCardFixture.png.dropLast(12))] {
        #expect(throws: SourceCharacterCardError.self) {
            try SourceCharacterCard.decode(OriginalCardFixture.card(png: thumbnail))
        }
    }
    #expect(throws: SourceCharacterCardError.self) { try SourceCharacterCard.decode(OriginalCardFixture.png.dropLast(12)) }
    let duplicateHeader = OriginalCardFixture.Value.map([
        .init(key: .string("lstInfo"), value: .array([])), .init(key: .string("lstInfo"), value: .array([]))])
    for value: OriginalCardFixture.Value in [.null, .array([]), OriginalCardFixture.map([]), duplicateHeader,
                                              OriginalCardFixture.map([("lstInfo", .array(Array(repeating: .null, count: 1025)))])] {
        #expect(throws: (any Error).self) {
            try SourceCharacterCard.decode(OriginalCardFixture.card(header: OriginalCardFixture.pack(value)))
        }
    }
}

@Test func sourceCharacterCardValidatesCustomizationVersionsLengthsAndNumericValues() throws {
    var invalidCustom: [Data] = [
        OriginalCardFixture.custom(faceVersion: "0.0.1"), OriginalCardFixture.custom(bodyVersion: "9.0.0"),
        OriginalCardFixture.custom(face: Array(repeating: .float(0.5), count: 51)),
        OriginalCardFixture.custom(body: Array(repeating: .float(0.5), count: 45)),
        OriginalCardFixture.custom(head: .string("0")), OriginalCardFixture.custom() + Data([0]),
    ]
    for value: OriginalCardFixture.Value in [.float(.nan), .float(.infinity), .float(-.infinity),
                                             .float(Double(Float.greatestFiniteMagnitude) * 2), .bool(true), .null, .string("0.5")] {
        var face = OriginalCardFixture.faceValues; face[17] = value
        invalidCustom.append(OriginalCardFixture.custom(face: face))
    }
    for value: OriginalCardFixture.Value in [.null, .string("0"), .float(0), .unsigned(UInt64.max)] {
        invalidCustom.append(OriginalCardFixture.custom(boneType: value))
    }
    for custom in invalidCustom {
        let card = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(custom: custom)))
        #expect(throws: (any Error).self) { try card.customization() }
    }
    for sex: OriginalCardFixture.Value in [.integer(2), .integer(-1), .float(1), .string("1")] {
        let card = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(sex: sex)))
        #expect(throws: SourceCharacterCardError.self) { try card.customization() }
    }
    for index in [0, 1] {
        var blocks = OriginalCardFixture.blocks(); blocks[index].version = "unsupported"
        let card = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: blocks))
        #expect(throws: SourceCharacterCardError.self) { try card.customization() }
    }
    let missingBone = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(custom: OriginalCardFixture.custom(boneType: nil))))
    #expect(try missingBone.customization().boneType == 0)
    var numeric = OriginalCardFixture.faceValues; numeric[0] = .integer(0); numeric[51] = .unsigned(1)
    let integers = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(custom: OriginalCardFixture.custom(face: numeric))))
    #expect(try integers.customization().faceValues[51] == 1)
}

@Test func sourceCharacterCardCurrentPluginArraysRetainDefaultsExtrasAndOpaqueFields() throws {
    let opaque = OriginalCardFixture.map([("raw", .binary(Data([0, 255, 193]))), ("future", .ext(-27, Data([3, 1, 4]))),
                                         ("nested", .array([.bool(true), .null, .float(0.25)]))])
    let plugins = OriginalCardFixture.map([
        ("empty", .array([])), ("versionOnly", .array([.integer(7)])), ("nilData", .array([.integer(-2), .null])),
        ("future", .array([.integer(9), opaque, .ext(77, Data([9])), .array([.null])])), ("nullEntry", .null),
    ])
    let blocks = OriginalCardFixture.blocks() + [OriginalCardFixture.extended(plugins)]
    let bytes = OriginalCardFixture.card(blocks: blocks)
    let card = try SourceCharacterCard.decode(bytes), extensions = try card.extensions()
    #expect(extensions.format == "block-v3")
    #expect(extensions.plugins["empty"]?.version == 0 && extensions.plugins["empty"]?.data == nil)
    #expect(extensions.plugins["versionOnly"]?.version == 7 && extensions.plugins["versionOnly"]?.data == nil)
    #expect(extensions.plugins["nilData"]?.version == -2 && extensions.plugins["nilData"]?.data == nil)
    #expect(extensions.plugins["future"]?.version == 9)
    #expect(extensions.plugins["future"]?.data == (try opaque.stringKeyedMap()))
    #expect(extensions.plugins["nullEntry"] == nil && extensions.diagnostics.contains { $0.contains("nullEntry") })
    #expect(card.block(named: "KKEx")?.data == OriginalCardFixture.pack(plugins))
    #expect(card.preservedData == bytes)
    let nilCard = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: [OriginalCardFixture.extended(.null)]))
    let nilExtensions = try nilCard.extensions()
    #expect(nilExtensions.format == "block-v3" && nilExtensions.plugins.isEmpty)
}

@Test func sourceCharacterCardLegacyOverrideAndMalformedTrailerFallbackMatchSourcePrecedence() throws {
    let current = OriginalCardFixture.map([("shared", OriginalCardFixture.plugin(3)), ("currentOnly", OriginalCardFixture.plugin(1))])
    let legacy = OriginalCardFixture.map([("shared", OriginalCardFixture.plugin(8)), ("legacyOnly", OriginalCardFixture.plugin(2))])
    let blocks = OriginalCardFixture.blocks() + [OriginalCardFixture.extended(current)]
    let trailer = OriginalCardFixture.legacy(legacy, suffix: Data([0xde, 0xad]))
    let bytes = OriginalCardFixture.card(blocks: blocks, trailer: trailer)
    let card = try SourceCharacterCard.decode(bytes), extensions = try card.extensions()
    #expect(extensions.format == "trailer-v2" && extensions.plugins["shared"]?.version == 8)
    #expect(extensions.plugins["legacyOnly"] != nil && extensions.plugins["currentOnly"] == nil)
    #expect(card.trailingData == trailer && card.preservedData == bytes)
    #expect(!extensions.diagnostics.isEmpty)
    let malformedPayload = OriginalCardFixture.string("KKEx") + OriginalCardFixture.i32(2) + OriginalCardFixture.i32(1000) + Data([0x81])
    let malformedPlugin = OriginalCardFixture.legacy(OriginalCardFixture.map([("bad", .bool(true))]))
    let invalidTrailers = [malformedPayload, malformedPlugin, OriginalCardFixture.legacy(legacy, version: 1),
                           OriginalCardFixture.string("KKEx") + OriginalCardFixture.i32(2) + OriginalCardFixture.i32(0)]
    for invalid in invalidTrailers {
        let decoded = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: blocks, trailer: invalid))
        let selected = try decoded.extensions()
        #expect(selected.format == "block-v3" && selected.plugins["shared"]?.version == 3)
        #expect(selected.plugins["currentOnly"] != nil && !selected.diagnostics.isEmpty)
        #expect(decoded.trailingData == invalid)
    }
    let nilLegacy = OriginalCardFixture.string("KKEx") + OriginalCardFixture.i32(2) + OriginalCardFixture.i32(1000) + Data([0xc0])
    let nilSelection = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: blocks, trailer: nilLegacy)).extensions()
    #expect(nilSelection.format == "trailer-v2" && nilSelection.plugins.isEmpty)
}

@Test func sourceCharacterCardMalformedOrUnsupportedCurrentExtensionsRemainOpaque() throws {
    let badPlugins: [OriginalCardFixture.Value] = [
        .array([]), OriginalCardFixture.map([("bad", .bool(false))]),
        OriginalCardFixture.map([("bad", .array([.null]))]),
        OriginalCardFixture.map([("bad", .array([.integer(Int64(Int32.max) + 1)]))]),
        OriginalCardFixture.map([("bad", .array([.integer(2), .array([])]))]),
    ]
    for plugin in badPlugins {
        let bytes = OriginalCardFixture.card(blocks: [OriginalCardFixture.extended(plugin)])
        let card = try SourceCharacterCard.decode(bytes), extensions = try card.extensions()
        #expect(extensions.format == nil && extensions.plugins.isEmpty && !extensions.diagnostics.isEmpty)
        #expect(card.preservedData == bytes)
    }
    let value = OriginalCardFixture.map([("ok", OriginalCardFixture.plugin(2))])
    let unsupported = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: [OriginalCardFixture.extended(value, version: "4")]))
    #expect(try unsupported.extensions().format == nil)
    let block = OriginalCardFixture.extended(value)
    let gapped = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: [block], payload: block.data + Data([0xaa])))
    let extensions = try gapped.extensions()
    #expect(extensions.format == nil && !extensions.diagnostics.isEmpty)
    // The source hook computes its base from payload end minus recorded sizes.
    // A leading gap therefore shifts KKEx reading, even though the stored block
    // range still starts at zero. Reading block.data directly would fail here.
    let sourceGapBytes = OriginalCardFixture.card(blocks: [block], payload: Data([0xaa]) + block.data)
    let sourceGap = try SourceCharacterCard.decode(sourceGapBytes)
    #expect(sourceGap.block(named: "KKEx")?.data != block.data)
    #expect(try sourceGap.extensions().plugins["ok"]?.version == 2)
    #expect(sourceGap.preservedData == sourceGapBytes)
    let leading = Data("gap!".utf8)
    let shortRead = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: [block],
        positions: [2], sizes: [Int64(block.data.count + 2)], payload: leading + block.data))
    #expect(try shortRead.extensions().plugins["ok"]?.version == 2)
    let crossesFooter = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: [block],
        positions: [2], payload: leading + block.data.dropLast(2), trailer: block.data.suffix(2)))
    #expect(try crossesFooter.extensions().plugins["ok"]?.version == 2)
    let legacyShort = OriginalCardFixture.string("KKEx") + OriginalCardFixture.i32(2)
        + OriginalCardFixture.i32(Int32(block.data.count + 10)) + block.data
    let shortLegacy = try SourceCharacterCard.decode(OriginalCardFixture.card(trailer: legacyShort))
    #expect(try shortLegacy.extensions().format == "trailer-v2")
    #expect(try shortLegacy.extensions().plugins["ok"]?.version == 2)
}

@Test func sourceCharacterCardPreviewCopiesAllShapesAndBridgesOriginalABMX() throws {
    let vector0 = OriginalCardFixture.Value.array([.float(0), .float(0), .float(0)])
    let modifier = OriginalCardFixture.Value.array([
        .array([.float(1.02), .float(1), .float(1)]), .float(1), vector0, vector0])
    let records = OriginalCardFixture.Value.array([.array([.string("cf_J_FaceRoot"), .array([modifier]), .integer(1)])])
    let boneBytes = OriginalCardFixture.pack(records)
    let plugins = OriginalCardFixture.map([
        ("KKABMPlugin.ABMData", OriginalCardFixture.plugin(2, data: OriginalCardFixture.map([("boneData", .binary(boneBytes))]))),
        ("example.unknown", OriginalCardFixture.plugin(7, data: OriginalCardFixture.map([("opaque", .ext(88, Data([2, 7])))]))),
    ])
    let bytes = OriginalCardFixture.card(blocks: OriginalCardFixture.blocks() + [OriginalCardFixture.extended(plugins)])
    let card = try SourceCharacterCard.decode(bytes), contract = try OriginalCardFixture.contract()
    let settings = try card.previewSettings(contract: contract)
    #expect(settings.faceValues == (0..<52).map { Float($0) / 51 })
    #expect(settings.bodyValues == (0..<44).map { Float($0) / 43 })
    let modifiers = try #require(settings.boneModifiers)
    #expect(modifiers.count == 1 && modifiers.source.dataVersion == 2)
    #expect(modifiers.source.payloadSHA256 == OriginalCardFixture.hash(boneBytes))
    #expect(modifiers.modifiers[0].boneName == "cf_J_FaceRoot")
    #expect(modifiers.modifiers[0].coordinateModifiers[0].scaleModifier == [Float(1.02), 1, 1])
    #expect(settings.diagnostics.contains { $0.contains("44 body") })
    #expect(settings.diagnostics.contains { $0.contains("example.unknown") })
    #expect(card.preservedData == bytes)
}

@Test func sourceCharacterCardPreviewRejectsUnsupportedIdentityAndAppliedShapeRanges() throws {
    let contract = try OriginalCardFixture.contract()
    var face = OriginalCardFixture.faceValues; face[0] = .float(-0.01)
    var body = OriginalCardFixture.bodyValues; body[2] = .float(1.01)
    let unsupported = [OriginalCardFixture.blocks(custom: OriginalCardFixture.custom(face: face)),
                       OriginalCardFixture.blocks(custom: OriginalCardFixture.custom(body: body)),
                       OriginalCardFixture.blocks(custom: OriginalCardFixture.custom(head: .integer(1))),
                       OriginalCardFixture.blocks(custom: OriginalCardFixture.custom(boneType: .integer(1))),
                       OriginalCardFixture.blocks(sex: .integer(0))]
    for blocks in unsupported {
        let card = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: blocks))
        _ = try card.customization() // Raw settings survive even when preview is unsupported.
        #expect(throws: SourceCharacterCardError.self) { try card.previewSettings(contract: contract) }
    }
    let card = try SourceCharacterCard.decode(OriginalCardFixture.card())
    #expect(throws: SourceCharacterCardError.self) { try card.previewSettings(contract: OriginalCardFixture.contract(faceCount: 51)) }
    #expect(throws: SourceCharacterCardError.self) { try card.previewSettings(contract: OriginalCardFixture.contract(bodyCount: 43)) }
    body = OriginalCardFixture.bodyValues; body[43] = .float(1.5)
    let unapplied = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(custom: OriginalCardFixture.custom(body: body))))
    #expect(try unapplied.customization().bodyValues[43] == 1.5)
    #expect(throws: SourceCharacterCardError.self) { try unapplied.previewSettings(contract: contract) }
    let male = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(sex: .integer(0))))
    #expect(try male.previewSettings(contract: contract, sex: 0).bodyValues == (0..<44).map { Float($0) / 43 })
    let alternate = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: OriginalCardFixture.blocks(custom: OriginalCardFixture.custom(head: .integer(2), boneType: .integer(1)))))
    #expect(try alternate.previewSettings(contract: contract, headID: 2, boneType: 1).faceValues == (0..<52).map { Float($0) / 51 })
}

private struct OriginalCardOracle: Decodable {
    struct Block: Decodable { let name: String, version: String, pos: Int, size: Int, sha256: String }
    struct Custom: Decodable { let headId: Int, shapeValueFace: [Float], shapeValueBody: [Float] }
    struct Parameter: Decodable { let sex: Int }
    struct Binary: Decodable { let size: Int, sha256: String }
    struct Plugin: Decodable {
        let id: String, isNull: Bool
        let version: Int?
        let dataIsNull: Bool?
        let dataKeys: [String]?
        let binaryValues: [String: Binary]?
    }
    let sha256: String, bytes: Int, productNo: Int, version: String
    let pngBytes: Int, facePngBytes: Int, facePngSHA256: String, headerBytes: Int, headerSHA256: String, payloadBytes: Int
    let blocks: [Block], custom: Custom, parameter: Parameter, extendedDataSource: String, plugins: [Plugin], footer: Binary
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["IKKOKU_SOURCE_CARD_FIXTURE"] != nil &&
              ProcessInfo.processInfo.environment["IKKOKU_SOURCE_CARD_ORACLE"] != nil))
func sourceCharacterCardMatchesIndependentPythonOriginalFormatOracle() throws {
    let fixturePath = try #require(ProcessInfo.processInfo.environment["IKKOKU_SOURCE_CARD_FIXTURE"])
    let oraclePath = try #require(ProcessInfo.processInfo.environment["IKKOKU_SOURCE_CARD_ORACLE"])
    let bytes = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
    let oracle = try JSONDecoder().decode(OriginalCardOracle.self, from: Data(contentsOf: URL(fileURLWithPath: oraclePath)))
    let card = try SourceCharacterCard.load(url: URL(fileURLWithPath: fixturePath))
    #expect(card.preservedData == bytes && bytes.count == oracle.bytes && card.sourceSHA256 == oracle.sha256)
    #expect(card.product == oracle.productNo && card.version == oracle.version)
    #expect(card.thumbnailData.count == oracle.pngBytes && card.faceThumbnailData.count == oracle.facePngBytes)
    #expect(OriginalCardFixture.hash(card.faceThumbnailData) == oracle.facePngSHA256)
    #expect(card.headerData.count == oracle.headerBytes && OriginalCardFixture.hash(card.headerData) == oracle.headerSHA256)
    #expect(card.payloadSize == oracle.payloadBytes && card.blocks.count == oracle.blocks.count)
    for (actual, expected) in zip(card.blocks, oracle.blocks) {
        #expect(actual.name == expected.name && actual.version == expected.version && actual.position == expected.pos)
        #expect(actual.data.count == expected.size && OriginalCardFixture.hash(actual.data) == expected.sha256)
    }
    #expect(card.trailingData.count == oracle.footer.size && OriginalCardFixture.hash(card.trailingData) == oracle.footer.sha256)
    let custom = try card.customization()
    #expect(custom.headID == oracle.custom.headId && custom.sex == oracle.parameter.sex)
    #expect(custom.faceValues == oracle.custom.shapeValueFace && custom.bodyValues == oracle.custom.shapeValueBody)
    let extensions = try card.extensions()
    #expect(extensions.format == (oracle.extendedDataSource == "legacy-v2" ? "trailer-v2" : "block-v3"))
    #expect(Set(extensions.plugins.keys) == Set(oracle.plugins.filter { !$0.isNull }.map(\.id)))
    for expected in oracle.plugins where !expected.isNull {
        let actual = try #require(extensions.plugins[expected.id])
        #expect(actual.version == expected.version)
        #expect((actual.data == nil) == expected.dataIsNull)
        #expect(Set(actual.data?.keys.map { $0 } ?? []) == Set(expected.dataKeys ?? []))
        for (key, expectedBinary) in expected.binaryValues ?? [:] {
            let binary = try #require(actual.data?[key]?.binaryValue)
            #expect(binary.count == expectedBinary.size && OriginalCardFixture.hash(binary) == expectedBinary.sha256)
        }
    }
    let settings = try card.previewSettings(contract: OriginalCardFixture.contract())
    #expect(settings.faceValues == oracle.custom.shapeValueFace)
    if extensions.plugins["KKABMPlugin.ABMData"] != nil {
        let modifiers = try #require(settings.boneModifiers)
        #expect(modifiers.count > 0 && modifiers.source.dataVersion == 2)
        let boneData = try #require(extensions.plugins["KKABMPlugin.ABMData"]?.data?["boneData"]?.binaryValue)
        #expect(modifiers.source.payloadSHA256 == OriginalCardFixture.hash(boneData))
    }
    #expect(card.preservedData == bytes)
}
