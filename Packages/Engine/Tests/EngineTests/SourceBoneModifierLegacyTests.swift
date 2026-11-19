import Foundation
import Testing
import simd
import Assets
import CoreMath
import Scene
@testable import Character

// ABMX card v1 legacy text (#403), synthetic inputs only. A token is
// "field0,name,field2,scaleX,scaleY,scaleZ,length"; fields 0 and 2 are never
// read. Tools/reverse/test_abmx_contract.py mirrors these cases and messages.

private func legacyToken(_ name: String, _ x: String = "1", _ y: String = "1", _ z: String = "1",
                         length: String? = "1", extra: [String] = []) -> String {
    (["0", name, "0", x, y, z] + (length.map { [$0] } ?? []) + extra).joined(separator: ",")
}

private func legacy(_ tokens: [String], separator: String = "\r\n") throws -> SourceBoneModifiers {
    try SourceBoneModifiers.decodeLegacyText(tokens.joined(separator: separator))
}

private func legacyRefusal(_ text: String) -> String? {
    do { _ = try SourceBoneModifiers.decodeLegacyText(text); return nil } catch RigError.invalid(let message) { return message } catch { return "\(error)" }
}

private func legacyBits(_ text: String) -> UInt32? {
    guard case .value(let value) = SourceBoneModifiers.legacyNumber(text) else { return nil }
    return value.bitPattern
}

@Test func sourceBoneModifierLegacySplitsOnTheDotNetWhitespaceSetOnly() throws {
    // aa has 8 fields; when a separator does not split, bb joins aa's field 7,
    // which is never read, and only aa remains.
    let a = legacyToken("aa", length: "2", extra: ["0"]), b = legacyToken("bb", "3", "3", "3", length: "3")
    let splitting = [" ", "\n", "\r\n", "\r", "\t", "\u{0B}", "\u{0C}", "\u{85}", "\u{A0}", "\u{1680}", "\u{180E}",
                     "\u{2000}", "\u{2005}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", " \r\n\t  "]
    for separator in splitting {
        let decoded = try SourceBoneModifiers.decodeLegacyText(separator + a + separator + separator + b + separator)
        #expect(decoded.modifiers.map(\.boneName) == ["aa", "bb"], "\(separator.unicodeScalars.map(\.value))")
        #expect(decoded.diagnostics?.isEmpty == true)
    }
    // char.IsWhiteSpace excludes U+001C-U+001F (Python's str.split includes
    // them), U+200B and U+FEFF.
    for separator in ["\u{1C}", "\u{1D}", "\u{1E}", "\u{1F}", "\u{200B}", "\u{FEFF}"] {
        let decoded = try SourceBoneModifiers.decodeLegacyText(a + separator + b)
        #expect(decoded.modifiers.map(\.boneName) == ["aa"], "\(separator.unicodeScalars.map(\.value))")
        #expect(decoded.modifiers.first?.coordinateModifiers.map(\.lengthModifier) == [2])
    }
    #expect(SourceBoneModifiers.legacyWhitespace.count == 26)
}

@Test func sourceBoneModifierLegacyFieldCountsKeepEmptyFields() throws {
    let decoded = try legacy([
        "0,five,0,2,2",                        // 5 fields: dropped
        legacyToken("six", "2", "3", "4", length: nil), // 6 fields: Length 1
        legacyToken("seven", "2", "3", "4", length: "5"),
        legacyToken("eight", "2", "3", "4", length: "5", extra: ["notanumber"]),
        ",empty,,2,3,4",                       // empty fields 0 and 2 still count
        legacyToken("trailing", "2", "3", "4", length: ""), // 7 fields, the 7th empty: unparsable
    ], separator: "\n")
    #expect(decoded.modifiers.map(\.boneName) == ["six", "seven", "eight", "empty"])
    #expect(decoded.modifiers.map { $0.coordinateModifiers[0].lengthModifier } == [1, 5, 5, 1])
    #expect(decoded.modifiers.allSatisfy {
        $0.boneLocation == 0 && $0.coordinateModifiers.count == 1 && $0.coordinateModifiers[0].scaleModifier == [2, 3, 4] &&
            $0.coordinateModifiers[0].positionModifier == [0, 0, 0] && $0.coordinateModifiers[0].rotationModifier == [0, 0, 0]
    })
    #expect(decoded.diagnostics?.map(\.message) == [
        "ABMX legacy line 6 for 'trailing' has an unparsable value in field 6; it is skipped, as the original skips lines that fail to parse."])
}

@Test func sourceBoneModifierLegacyTrimsTheCoordinateSuffixInUTF16() throws {
    let suffixed = (0..<7).map { legacyToken("key__\($0)", "\($0 + 1)") }
    let decoded = try legacy(suffixed + [legacyToken("a__"), legacyToken("x_y"), legacyToken("ab"), legacyToken("_ab"),
                                         legacyToken("b___"), legacyToken("\u{1F600}__1"), legacyToken("c\u{1F600}")])
    #expect(decoded.modifiers.map(\.boneName) == ["key", "a__", "x_y", "ab", "_ab", "b", "\u{1F600}", "c\u{1F600}"])
    #expect(decoded.modifiers[0].coordinateModifiers.map { $0.scaleModifier[0] } == [1, 2, 3, 4, 5, 6, 7])
}

@Test func sourceBoneModifierLegacyOrdersGroupsByFirstUseAndEntriesOrdinally() throws {
    // Input order 6..0; ordinal order 0..6. Groups keep their first use.
    let zz = (0..<7).reversed().map { legacyToken("zz__\($0)", "\($0)") }
    let bb = [legacyToken("bb__0", "10"), legacyToken("bb__2", "2"), legacyToken("bb__0", "11"), legacyToken("bb__1", "1"),
              legacyToken("bb__3", "3"), legacyToken("bb__4", "4"), legacyToken("bb__5", "5")]
    // Ordinal UTF-16: '0' < 'A' < '_' < 'a'. A culture comparer differs here.
    let cc = ["cc__a", "cc___", "cc__A", "cc__1", "cc__0", "cc__2", "cc__3"].enumerated().map { legacyToken($0.element, "\($0.offset)") }
    let decoded = try legacy([zz[0], bb[0], cc[0]] + zz.dropFirst() + bb.dropFirst() + cc.dropFirst())
    #expect(decoded.modifiers.map(\.boneName) == ["zz", "bb", "cc"])
    #expect(decoded.modifiers[0].coordinateModifiers.map { $0.scaleModifier[0] } == [0, 1, 2, 3, 4, 5, 6])
    #expect(decoded.modifiers[1].coordinateModifiers.map { $0.scaleModifier[0] } == [10, 11, 1, 2, 3, 4, 5])
    #expect(decoded.modifiers[2].coordinateModifiers.map { $0.scaleModifier[0] } == [4, 3, 5, 6, 2, 1, 0])
    #expect(decoded.diagnostics?.isEmpty == true)
}

@Test func sourceBoneModifierLegacyKeepsTheLastSevenOrTheLastOne() throws {
    for (count, kept) in [(1, 1), (2, 1), (6, 1), (7, 7), (8, 7), (9, 7)] {
        let decoded = try legacy((0..<count).map { legacyToken("b__\($0)", "\($0)") })
        #expect(decoded.modifiers[0].coordinateModifiers.map { $0.scaleModifier[0] } == (count - kept..<count).map(Float.init))
        let expected = count == kept ? [] : ["ABMX legacy bone 'b' has \(count) parsed lines; the original keeps the last \(kept)."]
        #expect(decoded.diagnostics?.map(\.message) == expected)
    }
}

@Test func sourceBoneModifierLegacySkipsUnparsableLines() throws {
    let failing = ["abc", "1e", "e1", "0x10", "inf", "infinity", "nan", "+Infinity", "", ".", "-", "+-1", "1.2.3", "1f",
                   "1d", "\u{FF11}", "1_0", "Infinity1", "\u{0661}"]
    for text in failing { #expect(SourceBoneModifiers.legacyNumber(text) == .failure, "\(text)") }
    let decoded = try legacy([legacyToken("aa__0", "2"), legacyToken("aa__1", "1", "abc"),
                              legacyToken("bb__0", length: "1e"), legacyToken("bb__1", "0x10", "Infinity")])
    #expect(decoded.modifiers.map(\.boneName) == ["aa"])
    #expect(decoded.modifiers[0].coordinateModifiers.map { $0.scaleModifier[0] } == [2])
    #expect(decoded.diagnostics?.map(\.message) == [
        "ABMX legacy line 2 for 'aa' has an unparsable value in field 4; it is skipped, as the original skips lines that fail to parse.",
        "ABMX legacy line 3 for 'bb' has an unparsable value in field 6; it is skipped, as the original skips lines that fail to parse.",
        "ABMX legacy line 4 for 'bb' has an unparsable value in field 3; it is skipped, as the original skips lines that fail to parse.",
    ])
    #expect(decoded.diagnostics?.map(\.code) == ["skipped-legacy-line", "skipped-legacy-line", "skipped-legacy-line"])
}

@Test func sourceBoneModifierLegacyNumbersParseAsDoubleThenFloat32() throws {
    // Bit patterns shared with the Python mirror.
    let table: [(String, UInt32)] = [
        ("1", 0x3F80_0000), ("1.", 0x3F80_0000), (".5", 0x3F00_0000), ("+1", 0x3F80_0000), ("-0", 0x8000_0000),
        ("0", 0x0000_0000), ("-1.25", 0xBFA0_0000), ("1e-3", 0x3A83_126F), ("1E+2", 0x42C8_0000), ("1.1", 0x3F8C_CCCD),
        ("007", 0x40E0_0000), ("1e-50", 0x0000_0000), ("1e-45", 0x0000_0001),
        ("3.4028234663852886e38", 0x7F7F_FFFF), ("1.0000000596046448", 0x3F80_0000),
        ("Infinity", 0x7F80_0000), ("-Infinity", 0xFF80_0000),
    ]
    for (text, bits) in table { #expect(legacyBits(text) == bits, "\(text)") }
    // Rounded straight to float32 this string gives 0x3F800001: the double
    // step is what makes it 1.
    #expect(Float("1.0000000596046448")?.bitPattern == 0x3F80_0001)
    #expect(legacyBits("NaN").map { Float(bitPattern: $0).isNaN } == true)
    // Beyond float32 range as a double, in either direction, even when it
    // would round to the largest float: infinite, which the caller refuses.
    for (text, bits) in [("3.4028235e38", 0x7F80_0000), ("1e39", 0x7F80_0000), ("-1e39", 0xFF80_0000),
                         ("1e400", 0x7F80_0000), ("-1e400", 0xFF80_0000)] as [(String, UInt32)] {
        #expect(legacyBits(text) == bits, "\(text)")
    }
}

@Test func sourceBoneModifierLegacyRefusesNonFiniteKeptValues() throws {
    let message = { (line: Int, name: String, field: Int) in
        "ABMX legacy line \(line) for '\(name)' has a non-finite or out-of-range value in field \(field); ABMX modifier values must be finite float32 numbers."
    }
    for (value, field) in [("NaN", 3), ("Infinity", 4), ("-Infinity", 5), ("1e39", 6), ("-1e39", 3), ("3.4028235e38", 4)] {
        let fields = (3...6).map { $0 == field ? value : "1" }
        let token = legacyToken("bb", fields[0], fields[1], fields[2], length: fields[3])
        #expect(legacyRefusal([legacyToken("aa"), token].joined(separator: "\n")) == message(2, "bb", field), "\(value)")
    }
    // Only kept entries count: a skipped line and a line the last-one rule
    // drops do not refuse the character.
    let decoded = try legacy([legacyToken("aa", "Infinity", "abc"), legacyToken("bb__0", "NaN"), legacyToken("bb__1", "2")])
    #expect(decoded.modifiers.map(\.boneName) == ["bb"])
    #expect(decoded.modifiers[0].coordinateModifiers.map { $0.scaleModifier[0] } == [2])
}

@Test func sourceBoneModifierLegacyNameIndexExceptionDropsAllModifiers() throws {
    for name in ["", "_", "a", "_a"] {
        let decoded = try legacy([legacyToken("valid"), legacyToken(name, "Infinity"), legacyToken("also")])
        #expect(decoded.modifiers.isEmpty, "\(name)")
        #expect(decoded.diagnostics?.map(\.code) == ["legacy-data-dropped"])
        #expect(decoded.diagnostics?.map(\.message) == [
            "ABMX legacy line 2 has a bone name the original cannot read; the original drops all ABMX data for this card."])
    }
    // "___" trims to an empty key; BoneModifier's constructor throws on it
    // once the group has a parsed line.
    let empty = try legacy([legacyToken("valid"), legacyToken("xx", "abc"), legacyToken("___")])
    #expect(empty.modifiers.isEmpty && empty.diagnostics?.map(\.message) == [
        "ABMX legacy line 3 has a bone name the original cannot read; the original drops all ABMX data for this card."])
    let unparsedEmpty = try legacy([legacyToken("valid"), legacyToken("___", "abc")])
    #expect(unparsedEmpty.modifiers.map(\.boneName) == ["valid"])
    // One non-BMP scalar is two UTF-16 units, so it reads like "ab".
    #expect(try legacy([legacyToken("\u{1F600}"), legacyToken("_\u{1F600}")]).modifiers.map(\.boneName) == ["\u{1F600}", "_\u{1F600}"])
}

@Test func sourceBoneModifierLegacyLimitsDynamicBonesAndProvenance() throws {
    let text = [legacyToken("cf_d_sk_00__0", "1.5"), legacyToken("cf_J_Hips", "0.5", "1", "1", length: "2")].joined(separator: "\r\n")
    let decoded = try SourceBoneModifiers.decodeLegacyText(text)
    #expect(decoded.source.dataKind == "card" && decoded.source.dataVersion == 1)
    #expect(decoded.source.payloadSHA256 == OriginalCardFixture.hash(Data(text.utf8)))
    #expect(decoded.modifiers.map(\.boneName) == ["cf_d_sk_00", "cf_J_Hips"])
    #expect(decoded.diagnostics?.map(\.code) == ["unsupported-dynamic-bone"])
    #expect(legacyRefusal("") == "ABMX card v1 boneData must contain 1 byte through 16 MiB of text.")
    #expect(legacyRefusal(String(repeating: " ", count: 16 * 1024 * 1024 + 1)) == "ABMX card v1 boneData must contain 1 byte through 16 MiB of text.")
    #expect(legacyRefusal(legacyToken(String(repeating: "n", count: 1025))) == "ABMX BoneName must contain 1 through 1024 source characters and no NUL.")
    #expect(legacyRefusal(legacyToken("bo\0ne")) == "ABMX BoneName must contain 1 through 1024 source characters and no NUL.")
    #expect(legacyRefusal((0...10_000).map { legacyToken("g\($0)") }.joined(separator: "\n")) == "ABMX boneData requires at most 10000 BoneModifier records.")
    #expect(throws: RigError.self) { try SourceBoneModifiers.decodeLegacyText(legacyToken("aa"), assemblySHA256: "invalid") }
    // Whitespace only: no tokens, an empty document.
    let blank = try SourceBoneModifiers.decodeLegacyText(" \r\n ")
    #expect(blank.modifiers.isEmpty && blank.diagnostics?.isEmpty == true)
    let notText = try SourceBoneModifiers.legacyNotText()
    #expect(notText.modifiers.isEmpty && notText.source.dataVersion == 1)
    #expect(notText.diagnostics?.map(\.message) == [
        "ABMX card v1 boneData is not text; the original's legacy reader returns no modifiers, so the character loads without ABMX."])
}

@Test func sourceCharacterCardBridgesLegacyABMXText() throws {
    func card(_ boneData: OriginalCardFixture.Value?) throws -> SourceCharacterCard {
        let data: OriginalCardFixture.Value = boneData.map { OriginalCardFixture.map([("boneData", $0)]) } ?? OriginalCardFixture.map([])
        let plugins = OriginalCardFixture.map([("KKABMPlugin.ABMData", OriginalCardFixture.plugin(1, data: data))])
        return try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: OriginalCardFixture.blocks() + [OriginalCardFixture.extended(plugins)]))
    }
    let text = [legacyToken("cf_J_FaceRoot__0", "1.5"), legacyToken("cf_d_sk_00", length: "2")].joined(separator: "\r\n")
    let settings = try card(.string(text)).previewSettings(contract: OriginalCardFixture.contract())
    let modifiers = try #require(settings.boneModifiers)
    #expect(modifiers.source.dataVersion == 1 && modifiers.source.payloadSHA256 == OriginalCardFixture.hash(Data(text.utf8)))
    #expect(modifiers.modifiers.map(\.boneName) == ["cf_J_FaceRoot", "cf_d_sk_00"])
    #expect(modifiers.modifiers[0].coordinateModifiers[0].scaleModifier == [1.5, 1, 1])
    #expect(settings.diagnostics.contains { $0.contains("cf_d_sk_00") && $0.contains("dynamic") })
    #expect(try card(nil).boneModifiers() == nil)
    #expect(try card(.string("")).boneModifiers() == nil)
    let binary = try card(.binary(Data([0x90])))
    #expect(try binary.boneModifiers()?.modifiers.isEmpty == true)
    #expect(try binary.previewSettings(contract: OriginalCardFixture.contract()).diagnostics.contains {
        $0 == "ABMX card v1 boneData is not text; the original's legacy reader returns no modifiers, so the character loads without ABMX." })
    let refused = try card(.string(legacyToken("aa", "NaN")))
    #expect(throws: RigError.self) { try refused.previewSettings(contract: OriginalCardFixture.contract()) }
}

@Test func sourceBoneModifierLegacyAppliesLikeTheEquivalentV2Document() throws {
    let rig = try RigDefinition(nodes: [
        .init(name: "root", sourceID: "root", parent: nil, translation: Float3(0.2, -0.3, 0.4), scale: Float3(2, 1, 3)),
        .init(name: "bone", sourceID: "bone-1", parent: 0),
        .init(name: "child", sourceID: "child", parent: 1, translation: Float3(0.1, 0.2, -0.3)),
    ], skins: [])
    let migrated = try SourceBoneModifiers.decodeLegacyText(legacyToken("bone__0", "1.5", "0.5", "2", length: "1.25"))
    let document: [String: Any] = [
        "schemaVersion": 1, "kind": "ikkoku-source-bone-modifiers", "coordinateSpace": "unity-left-handed-y-up",
        "angleUnit": "degrees", "mode": "staticBaseline",
        "source": ["pluginGUID": "KKABMX.Core", "dataGUID": "KKABMPlugin.ABMData", "pluginVersion": "5.4",
                   "dataKind": "card", "dataVersion": 2, "assemblySHA256": String(repeating: "a", count: 64),
                   "payloadSHA256": String(repeating: "b", count: 64)],
        "modifiers": [["boneName": "bone", "boneLocation": 0, "coordinateModifiers": [
            ["scaleModifier": [1.5, 0.5, 2], "lengthModifier": 1.25, "positionModifier": [0, 0, 0], "rotationModifier": [0, 0, 0]]]]]]
    let v2 = try SourceBoneModifiers.decode(JSONSerialization.data(withJSONObject: document))
    for coordinate in [0, 3, 6] {
        let expected = try v2.applying(to: rig, baseline: rig.restPose, coordinate: coordinate)
        #expect(try migrated.applying(to: rig, baseline: rig.restPose, coordinate: coordinate).localMatrices == expected.localMatrices)
        #expect(expected.localMatrices != rig.restPose.localMatrices)
    }
}
