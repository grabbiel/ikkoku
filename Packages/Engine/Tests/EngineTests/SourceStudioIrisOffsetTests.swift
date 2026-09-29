import Foundation
import simd
import Testing
@testable import Studio

// Fixture tests for SourceStudioEyeMaterialSettings and the recovered
// EyeLookMaterialControll.Update math.  The decode fixture below is the
// eyeMaterial block Tools/reverse/studio_look_settings.py exports from
// bo_head_00.unity3d (byte-for-byte values, sorted eyeLR 0,1 — the L eye on
// cf_Ohitomi_L02, the R on cf_Ohitomi_R02); the branch expectations are
// hand-computed in double precision from the exported waits/limits/power and
// replayed exactly (Mathf semantics: Lerp/InverseLerp clamp to [0,1]).

/// The exported document, verbatim (source: studio-look-settings.json).
private let exportedEyeMaterialJSON = #"""
{"eyeMaterial": [{"DownLimit": 80.0, "DownWait": 100, "InsideLimit": -100.0, "InsideWait": -100, "OutsideLimit": 100.0, "OutsideWait": 100, "UpLimit": -80.0, "UpWait": -100, "YureDown": -4, "YureInside": 4, "YureOutside": -4, "YureTime": 0.30000001192092896, "YureUp": 4, "eyeLR": 0, "gameObject": "cf_Ohitomi_L02", "hlDownOffsetY": 0.0, "hlUpOffsetY": 0.0, "materials": ["cf_m_hitomi_00"], "offset": [-0.20000000298023224, -0.20000000298023224], "power": 0.0010000000474974513, "scale": [0.0, 0.0], "texStates": [{"isYure": 0, "texID": -1, "texName": "_MainTex"}, {"isYure": 0, "texID": -1, "texName": "_overtex1"}, {"isYure": 0, "texID": -1, "texName": "_overtex2"}]}, {"DownLimit": 80.0, "DownWait": 100, "InsideLimit": -100.0, "InsideWait": -100, "OutsideLimit": 100.0, "OutsideWait": 100, "UpLimit": -80.0, "UpWait": -100, "YureDown": -4, "YureInside": 4, "YureOutside": -4, "YureTime": 0.30000001192092896, "YureUp": 4, "eyeLR": 1, "gameObject": "cf_Ohitomi_R02", "hlDownOffsetY": 0.0, "hlUpOffsetY": 0.0, "materials": ["cf_m_hitomi_00"], "offset": [0.20000000298023224, -0.20000000298023224], "power": 0.0010000000474974513, "scale": [0.0, 0.0], "texStates": [{"isYure": 0, "texID": -1, "texName": "_MainTex"}, {"isYure": 0, "texID": -1, "texName": "_overtex1"}, {"isYure": 0, "texID": -1, "texName": "_overtex2"}]}]}
"""#

private func exportedSettings() throws -> [SourceStudioEyeMaterialSettings] {
    try SourceStudioEyeMaterialSettings.document(json: Data(exportedEyeMaterialJSON.utf8))
}

/// The exported document with every occurrence of one substring replaced —
/// the limits and isYure flags the branch tests need differ from the prefab
/// only in those numbers.
private func patchedSettings(_ replace: [(String, String)]) throws -> [SourceStudioEyeMaterialSettings] {
    var json = exportedEyeMaterialJSON
    for (from, to) in replace {
        #expect(json.contains(from), "fixture carries \(from)")
        json = json.replacingOccurrences(of: from, with: to)
    }
    return try SourceStudioEyeMaterialSettings.document(json: Data(json.utf8))
}

private let identityOffset = SIMD2<Double>(0, 0)
private let identityScale = SIMD2<Double>(0, 0)

private func expectClose(_ a: Double, _ b: Double, _ context: String) {
    // Exact double replay: the same operations in the same order, so the
    // tolerance is only the 1 ulp the printed decimal literals carry.
    #expect(abs(a - b) <= abs(b) * 1e-15 + 1e-300, "\(context): \(a) vs \(b)")
}

private func expectClose(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ context: String) {
    expectClose(a.x, b.x, "\(context).x")
    expectClose(a.y, b.y, "\(context).y")
}

@Test func studioIrisOffsetSettingsDecodeExportedEyeMaterialBlock() throws {
    let settings = try exportedSettings()
    #expect(settings.map(\.eyeLR) == [0, 1], "sorted L,R")
    let l = settings[0], r = settings[1]
    #expect(l.gameObject == "cf_Ohitomi_L02" && r.gameObject == "cf_Ohitomi_R02")
    #expect(l.materials == ["cf_m_hitomi_00"] && r.materials == ["cf_m_hitomi_00"])
    // Waits, limits and power are the same on both eyes (exported, not the
    // script's Reset defaults assumed); the offset mirrors x only.
    for eye in settings {
        expectClose(eye.insideWait, -100, "InsideWait")
        expectClose(eye.outsideWait, 100, "OutsideWait")
        expectClose(eye.upWait, -100, "UpWait")
        expectClose(eye.downWait, 100, "DownWait")
        expectClose(eye.insideLimit, -100, "InsideLimit")
        expectClose(eye.outsideLimit, 100, "OutsideLimit")
        expectClose(eye.upLimit, -80, "UpLimit")
        expectClose(eye.downLimit, 80, "DownLimit")
        expectClose(eye.power, 0.0010000000474974513, "power")
        expectClose(eye.yureInside, 4, "YureInside")
        expectClose(eye.yureOutside, -4, "YureOutside")
        expectClose(eye.yureUp, 4, "YureUp")
        expectClose(eye.yureDown, -4, "YureDown")
        expectClose(eye.yureTime, 0.30000001192092896, "YureTime")
        #expect(eye.texStates.map(\.texName) == ["_MainTex", "_overtex1", "_overtex2"])
        #expect(eye.texStates.allSatisfy { $0.texID == -1 && !$0.isYure },
                "the prefab marks none of the three Yure")
    }
    expectClose(l.offset.x, -0.20000000298023224, "L offset.x")
    expectClose(r.offset.x, 0.20000000298023224, "R offset.x")
    for eye in settings {
        expectClose(eye.offset.y, -0.20000000298023224, "offset.y")
        expectClose(eye.scale.x, 0, "scale.x")
        expectClose(eye.scale.y, 0, "scale.y")
        expectClose(eye.hlUpOffsetY, 0, "hlUpOffsetY")
        expectClose(eye.hlDownOffsetY, 0, "hlDownOffsetY")
    }
}

@Test func studioIrisOffsetSettingsRejectMalformedEntries() throws {
    // A document without the block (the solver's minimal fixtures) decodes
    // nothing rather than defaulting.
    #expect(throws: (any Error).self) {
        _ = try SourceStudioEyeMaterialSettings.document(json: Data(#"{"schema":1}"#.utf8))
    }
    for (target, broken, what) in [
        (#""offset": [-0.20000000298023224, -0.20000000298023224]"#,
         #""offset": [-0.2, -0.2, 0.0]"#, "a three-component offset"),
        (#""scale": [0.0, 0.0]"#, #""scale": [0.0]"#, "a one-component scale"),
        (#""_MainTex""#, "\u{22}\u{22}", "an empty texName"),
        (#""texStates": [{"isYure": 0, "texID": -1, "texName": "_MainTex"}, {"isYure": 0, "texID": -1, "texName": "_overtex1"}, {"isYure": 0, "texID": -1, "texName": "_overtex2"}]"#,
         #""texStates": []"#, "an empty texStates"),
    ] {
        #expect(exportedEyeMaterialJSON.contains(target))
        let json = exportedEyeMaterialJSON.replacingOccurrences(of: target, with: broken)
        #expect(throws: (any Error).self, "\(what) is a diagnostic") {
            _ = try SourceStudioEyeMaterialSettings.document(json: Data(json.utf8))
        }
    }
}

@Test func studioIrisOffsetRestingRatesGiveExportedEyeOffsets() throws {
    // The Reset-default replay: rates (0, 0) with the eye's own exported
    // offset/scale/hl snapshot.  v = offset = (-+0.2, -0.2) stays inside the
    // unit circle, so x reads num = 200 * 0.4 - 100 = -20 (L) and y reads
    // num2 = 100 - 200 * 0.4 = +20 with Down-first; times power (100 = +-0.1
    // full scale) gives +-0.02 / +0.02, and all three textures move alike.
    let settings = try exportedSettings()
    let resting: [SIMD2<Double>] = [
        SIMD2<Double>(-0.020000001247972264, 0.020000001247972264),
        SIMD2<Double>(0.020000001247972264, 0.020000001247972264),
    ]
    for (eye, expected) in zip(settings, resting) {
        let transforms = try SourceStudioEyeMaterialSettings.textureTransforms(
            rateH: 0, rateV: 0, settings: eye, offset: eye.offset, scale: eye.scale,
            hlUpOffsetY: eye.hlUpOffsetY, hlDownOffsetY: eye.hlDownOffsetY)
        #expect(transforms.count == 3)
        #expect(transforms.allSatisfy { !$0.yure })
        for entry in transforms {
            expectClose(entry.offset, expected, "eyeLR \(eye.eyeLR) resting")
            expectClose(entry.scale, SIMD2<Double>(1, 1), "resting texture scale")
        }
    }
}

@Test func studioIrisOffsetNormalizesVectorsOutsideUnitCircle() throws {
    let l = try #require((try exportedSettings()).first)
    // (3, 4) leaves the unit circle and is re-normalized to (0.6, 0.8);
    // (0.6, 0.8) itself sits on it and the gate is strict (> 1), so both
    // frames must read the same shift: num = 200 * 0.8 - 100 = 60, and with
    // Down-first num2 = 100 - 200 * 0.9 = -80, times power.
    let outside = try SourceStudioEyeMaterialSettings.textureTransforms(
        rateH: 3, rateV: 4, settings: l, offset: identityOffset, scale: identityScale,
        hlUpOffsetY: 0, hlDownOffsetY: 0)
    let onCircle = try SourceStudioEyeMaterialSettings.textureTransforms(
        rateH: 0.6, rateV: 0.8, settings: l, offset: identityOffset, scale: identityScale,
        hlUpOffsetY: 0, hlDownOffsetY: 0)
    let expected = SIMD2<Double>(0.06000000284984708, -0.0800000037997961)
    expectClose(outside[0].offset, expected, "(3, 4) normalized")
    expectClose(onCircle[0].offset, expected, "(0.6, 0.8) untouched")
}

@Test func studioIrisOffsetHorizontalAndVerticalSignsFollowWaits() throws {
    let l = try #require((try exportedSettings()).first)
    func shift(_ rateH: Double, _ rateV: Double) throws -> SIMD2<Double> {
        let transforms = try SourceStudioEyeMaterialSettings.textureTransforms(
            rateH: rateH, rateV: rateV, settings: l, offset: identityOffset, scale: identityScale,
            hlUpOffsetY: 0, hlDownOffsetY: 0)
        return try #require(transforms.first).offset
    }
    // InsideWait -100 / OutsideWait +100: rateH +1 is +0.1, so positive x is
    // Outside.  DownWait +100 / UpWait -100 with Down-first: rateV +1 is
    // -0.1, so positive y (texture offset y) is Down... the script's y axis
    // reads inverted, which the sign of the replay pins.
    expectClose(try shift(1, 0), SIMD2<Double>(0.10000000474974513, 0), "rateH +1 outside")
    expectClose(try shift(-1, 0), SIMD2<Double>(-0.10000000474974513, 0), "rateH -1 inside")
    expectClose(try shift(0, 1), SIMD2<Double>(0, -0.10000000474974513), "rateV +1")
    expectClose(try shift(0, -1), SIMD2<Double>(0, 0.10000000474974513), "rateV -1")
}

@Test func studioIrisOffsetLimitsClampBothAxes() throws {
    // Tighten OutsideLimit and DownLimit in the exported document; the full-
    // deflection shifts (+-0.1 x, +0.1 y at rateV -1) stop at the limits.
    let settings = try patchedSettings([
        (#""OutsideLimit": 100.0"#, #""OutsideLimit": 0.02"#),
        (#""DownLimit": 80.0"#, #""DownLimit": 0.05"#),
    ])
    let l = try #require(settings.first)
    let out = try SourceStudioEyeMaterialSettings.textureTransforms(
        rateH: 1, rateV: -1, settings: l, offset: identityOffset, scale: identityScale,
        hlUpOffsetY: 0, hlDownOffsetY: 0)
    expectClose(out[0].offset, SIMD2<Double>(0.02, 0.05), "clamped at OutsideLimit/DownLimit")
    // The inverted clamp range is a diagnostic, not a silent swap.
    let inverted = try patchedSettings([(#""InsideLimit": -100.0"#, #""InsideLimit": 300.0"#)])
    #expect(throws: (any Error).self) {
        _ = try SourceStudioEyeMaterialSettings.textureTransforms(
            rateH: 0, rateV: 0, settings: try #require(inverted.first),
            offset: identityOffset, scale: identityScale, hlUpOffsetY: 0, hlDownOffsetY: 0)
    }
}

@Test func studioIrisOffsetHighlightOffsetsTouchOnlyTexturesOneAndTwo() throws {
    // The eye's resting y (+0.02...) shifts by hlUpOffsetY on texStates 1 and
    // by hlDownOffsetY on texStates 2 only, AFTER the clamp — the main tex is
    // untouched and the x column never sees the highlights.
    let l = try #require((try exportedSettings()).first)
    let out = try SourceStudioEyeMaterialSettings.textureTransforms(
        rateH: 0, rateV: 0, settings: l, offset: l.offset, scale: identityScale,
        hlUpOffsetY: 0.5, hlDownOffsetY: -0.25)
    let resting = SIMD2<Double>(-0.020000001247972264, 0.020000001247972264)
    expectClose(out[0].offset, resting, "texStates 0 untouched")
    expectClose(out[1].offset, SIMD2<Double>(resting.x, resting.y + 0.5), "texStates 1 hl up")
    expectClose(out[2].offset, SIMD2<Double>(resting.x, resting.y - 0.25), "texStates 2 hl down")
    #expect(out.allSatisfy { $0.scale == SIMD2<Double>(1, 1) && !$0.yure })
}

@Test func studioIrisOffsetNonYureScaleSubtractsHalfAndReturnsOnePlusScale() throws {
    // scale (2, 4): the Lerp(1, 5, t) factors clamp to 5 on both axes, so at
    // rateH 0.5 (num 50) the main tex reads 50 * power * 5 = 0.25 before the
    // scale/2 subtract (0.25 - 1 = -0.75) and y 0 - 2 = -2, and the texture
    // scale is 1 + scale = (3, 5).
    let l = try #require((try exportedSettings()).first)
    let out = try SourceStudioEyeMaterialSettings.textureTransforms(
        rateH: 0.5, rateV: 0, settings: l, offset: identityOffset,
        scale: SIMD2<Double>(2, 4), hlUpOffsetY: 0, hlDownOffsetY: 0)
    for entry in out {
        expectClose(entry.offset, SIMD2<Double>(-0.7499999881256372, -2.0), "scale-shifted offset")
        expectClose(entry.scale, SIMD2<Double>(3, 5), "1 + scale")
    }
}

@Test func studioIrisOffsetYureEntrySkipsScaleAndFlagsJitter() throws {
    // The same scale (2, 4) frame with _MainTex marked Yure: its power is
    // stepped by 0.8/0.5, the scale/2 subtract is skipped (that write belongs
    // to the non-Yure branch) and the texture scale stays (1, 1) because the
    // random YureAddScale/YureAddVec jitter is not modeled — `yure` is set so
    // the caller knows the value is the unjittered placeholder.
    let settings = try patchedSettings([(
        #""isYure": 0, "texID": -1, "texName": "_MainTex""#,
        #""isYure": 1, "texID": -1, "texName": "_MainTex""#)])
    let l = try #require(settings.first)
    #expect(l.texStates[0].isYure, "the exported int flag decodes as Yure")
    let out = try SourceStudioEyeMaterialSettings.textureTransforms(
        rateH: 0.5, rateV: 0, settings: l, offset: identityOffset,
        scale: SIMD2<Double>(2, 4), hlUpOffsetY: 0, hlDownOffsetY: 0)
    expectClose(out[0].offset, SIMD2<Double>(0.20000000949949026, 0), "yure 0.8 x factor, no subtract")
    expectClose(out[0].scale, SIMD2<Double>(1, 1), "yure writes no texture scale")
    #expect(out[0].yure)
    // The unflagged siblings keep the non-Yure branch of the same frame.
    expectClose(out[1].offset, SIMD2<Double>(-0.7499999881256372, -2.0), "non-yure sibling")
    #expect(!out[1].yure && !out[2].yure)
}
