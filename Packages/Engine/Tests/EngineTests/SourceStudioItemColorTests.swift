import Testing
import Foundation
import simd
import Assets
import Character
@testable import Studio

private func itemRecord(
    colors: [SIMD4<Float>] = (0..<8).map { SIMD4<Float>(Float($0) / 10, 0.25, 0.75, 1) },
    alpha: Float = 1
) -> KoikatsuItemRecord {
    let pattern = KoikatsuPatternRecord(key: -1, filePath: "", clamp: false, uv: SIMD4(0, 0, 1, 1), rotation: 0)
    return KoikatsuItemRecord(group: 0, category: 0, no: 1, animationSpeed: 1,
        colors: colors, patterns: [], alpha: alpha, lineColor: SIMD4(0, 0, 0, 1), lineWidth: 1,
        emissionColor: .zero, emissionPower: 0, lightCancel: 0, panel: pattern,
        enableFK: false, bones: [:], enableDynamicBone: false, animationNormalizedTime: 0)
}

private func extras(_ entries: [String: JSONValue]) -> JSONValue { .object(entries) }

@Test("Color slot selects the matching record color")
func slotSelectsRecordColor() throws {
    let record = itemRecord()
    for slot in 0..<3 {
        let tint = try #require(SourceStudioItemColor.tint(record: record,
            extras: extras(["itemColorSlot": .number(Double(slot))])))
        let color = record.colors[slot]
        // Passed verbatim; itemMaterial's RGB.linear completes the space change.
        #expect(tint.color == RGB(color.x, color.y, color.z))
        #expect(tint.alphaScale == 1)  // no itemAlphaProperty: exported alpha stands
    }
}

@Test("A missing or null color slot supplies no tint")
func nullSlotIsNoTint() {
    #expect(SourceStudioItemColor.tint(record: itemRecord(), extras: nil) == nil)
    #expect(SourceStudioItemColor.tint(record: itemRecord(), extras: extras([:])) == nil)
    #expect(SourceStudioItemColor.tint(record: itemRecord(), extras: extras(["itemColorSlot": .null])) == nil)
    // Slots the exporter refuses to attribute (fractional or multi-channel
    // masks) export null, and out-of-range or non-integral values are rejected.
    for bad in [JSONValue.number(-1), .number(0.5), .number(8), .number(.nan), .number(.infinity), .string("0")] {
        #expect(SourceStudioItemColor.tint(record: itemRecord(), extras: extras(["itemColorSlot": bad])) == nil)
    }
}

@Test("Alpha property multiplies the exported base alpha by the record alpha")
func alphaPropertyScalesBaseAlpha() throws {
    let tint = try #require(SourceStudioItemColor.tint(record: itemRecord(alpha: 0.5),
        extras: extras(["itemColorSlot": .number(0), "itemAlphaProperty": .string("_alpha")])))
    #expect(tint.color == RGB(0, 0.25, 0.75))
    #expect(tint.alphaScale == 0.5)
    #expect(SourceStudioItemColor.tint(record: itemRecord(alpha: 3),
        extras: extras(["itemColorSlot": .number(0), "itemAlphaProperty": .string("_alpha")]))?.alphaScale == 1)
    #expect(SourceStudioItemColor.tint(record: itemRecord(alpha: -1),
        extras: extras(["itemColorSlot": .number(0), "itemAlphaProperty": .string("_alpha")]))?.alphaScale == 0)
    // An unrelated property name must not scale anything.
    #expect(SourceStudioItemColor.tint(record: itemRecord(alpha: 0.5),
        extras: extras(["itemColorSlot": .number(0), "itemAlphaProperty": .string("_Color2")]))?.alphaScale == 1)
}

@Test("Non-finite colors and alphas reject the tint")
func nonFiniteValuesReject() {
    for bad in [SIMD4<Float>(.nan, 0.5, 0.5, 1), SIMD4<Float>(0.5, .infinity, 0.5, 1)] {
        #expect(SourceStudioItemColor.tint(record: itemRecord(colors: [bad]),
            extras: extras(["itemColorSlot": .number(0)])) == nil)
    }
    // The exported base alpha cannot be scaled by a non-finite record alpha.
    #expect(SourceStudioItemColor.tint(record: itemRecord(alpha: .nan),
        extras: extras(["itemColorSlot": .number(0), "itemAlphaProperty": .string("_alpha")])) == nil)
}

@Test("The stored-values entry point resolves the same tint as the record")
func storedValuesEntryMatchesRecord() throws {
    let record = itemRecord(alpha: 0.5)
    let extras = extras(["itemColorSlot": .number(1), "itemAlphaProperty": .string("_alpha")])
    let direct = try #require(SourceStudioItemColor.tint(record: record, extras: extras))
    // What the frame builder holds: the colors/alpha the import retained.
    let stored = try #require(SourceStudioItemColor.tint(colors: record.colors, alpha: record.alpha, extras: extras))
    #expect(stored == direct)
    #expect(SourceStudioItemColor.tint(colors: [], alpha: record.alpha, extras: extras) == nil)
}
