import Foundation
import simd
import Testing
@testable import Studio

// The renderer-side mapping from eye-look rates to MaterialUniforms.irisST,
// replayed against the exported bo_head_00 eyeMaterial block without Metal or
// a loaded character.  The same JSON fixture as SourceStudioIrisOffsetTests,
// so the resting anchors are the ones that file pins in double precision.

private let exportedEyeMaterialJSON = #"""
{"eyeMaterial": [{"DownLimit": 80.0, "DownWait": 100, "InsideLimit": -100.0, "InsideWait": -100, "OutsideLimit": 100.0, "OutsideWait": 100, "UpLimit": -80.0, "UpWait": -100, "YureDown": -4, "YureInside": 4, "YureOutside": -4, "YureTime": 0.30000001192092896, "YureUp": 4, "eyeLR": 0, "gameObject": "cf_Ohitomi_L02", "hlDownOffsetY": 0.0, "hlUpOffsetY": 0.0, "materials": ["cf_m_hitomi_00"], "offset": [-0.20000000298023224, -0.20000000298023224], "power": 0.0010000000474974513, "scale": [0.0, 0.0], "texStates": [{"isYure": 0, "texID": -1, "texName": "_MainTex"}, {"isYure": 0, "texID": -1, "texName": "_overtex1"}, {"isYure": 0, "texID": -1, "texName": "_overtex2"}]}, {"DownLimit": 80.0, "DownWait": 100, "InsideLimit": -100.0, "InsideWait": -100, "OutsideLimit": 100.0, "OutsideWait": 100, "UpLimit": -80.0, "UpWait": -100, "YureDown": -4, "YureInside": 4, "YureOutside": -4, "YureTime": 0.30000001192092896, "YureUp": 4, "eyeLR": 1, "gameObject": "cf_Ohitomi_R02", "hlDownOffsetY": 0.0, "hlUpOffsetY": 0.0, "materials": ["cf_m_hitomi_00"], "offset": [0.20000000298023224, -0.20000000298023224], "power": 0.0010000000474974513, "scale": [0.0, 0.0], "texStates": [{"isYure": 0, "texID": -1, "texName": "_MainTex"}, {"isYure": 0, "texID": -1, "texName": "_overtex1"}, {"isYure": 0, "texID": -1, "texName": "_overtex2"}]}]}
"""#

private func exportedSettings() throws -> [SourceStudioEyeMaterialSettings] {
    try SourceStudioEyeMaterialSettings.document(json: Data(exportedEyeMaterialJSON.utf8))
}

@Test func irisRenderingMatchesExportedGameObjectsToLoadedMeshNames() throws {
    let eyes = try exportedSettings()
    // Loaded mesh names carry the GLTF primitive suffix; the export's
    // gameObject is the bare GameObject name.
    #expect(SourceStudioIrisRendering.eye(ofMeshNamed: "cf_Ohitomi_L02/0", in: eyes) == 0)
    #expect(SourceStudioIrisRendering.eye(ofMeshNamed: "cf_Ohitomi_R02/0", in: eyes) == 1)
    #expect(SourceStudioIrisRendering.eye(ofMeshNamed: "cf_Ohitomi_L02", in: eyes) == 0)
    #expect(SourceStudioIrisRendering.eye(ofMeshNamed: "cf_m_hitomi_00/0", in: eyes) == nil)
    #expect(SourceStudioIrisRendering.eye(ofMeshNamed: "o_body_a/0", in: eyes) == nil)
}

@Test func irisRenderingRestingRatesWriteExportedOffsetsIntoAllThreeSTVectors() throws {
    // Rates (0, 0) — eye look not live — must still write the resting offset
    // the original applies, exactly the double values the offset tests pin,
    // narrowed to the Float the shader reads: +-0.02 / +0.02 per eye.
    let eyes = try exportedSettings()
    let resting = [SIMD2<Double>(-0.020000001247972264, 0.020000001247972264),
                   SIMD2<Double>(0.020000001247972264, 0.020000001247972264)]
    for (eye, expected) in zip(eyes, resting) {
        let st = try SourceStudioIrisRendering.transforms(rateH: 0, rateV: 0, settings: eye)
        #expect(st.count == 3)
        for vector in st {
            #expect(vector.x == 1 && vector.y == 1, "scale is 1 + scale = (1, 1)")
            #expect(abs(Double(vector.z) - expected.x) <= abs(expected.x) * 1e-6 + 1e-300, "offset u \(eye.eyeLR)")
            #expect(abs(Double(vector.w) - expected.y) <= abs(expected.y) * 1e-6 + 1e-300, "offset v \(eye.eyeLR)")
        }
    }
}

@Test func irisRenderingLiveRatesShiftTheWrittenOffsetsFromResting() throws {
    let eyes = try exportedSettings()
    let l = try #require(eyes.first)
    // rateH +1 with the prefab offset (-0.2, -0.2): v = (0.8, -0.2) reads
    // num = -100 + 200 * 0.9 = 80 and num2 = 100 - 200 * 0.4 = 20 (v.y is the
    // resting one, rateV is 0), times power -> (0.08, 0.02), inside the
    // +-100/+-80 limits, all three textures.  Tolerance 1e-7 absorbs the Float
    // narrowing only; the visual shift from resting is ~0.1.
    let st = try SourceStudioIrisRendering.transforms(rateH: 1, rateV: 0, settings: l)
    for vector in st {
        #expect(abs(Double(vector.z) - 0.08000000350177286) <= 1e-7, "live offset u")
        #expect(abs(Double(vector.w) - 0.020000001247972264) <= 1e-7, "live offset v")
        #expect(vector.x == 1 && vector.y == 1)
    }
    // The resting write differs on the u axis, so a frame at (0, 0) is not
    // the same uniform as one at (1, 0): the irises visibly follow the gaze.
    // rateV is 0 here, so v stays on its resting 0.02.
    let resting = try SourceStudioIrisRendering.transforms(rateH: 0, rateV: 0, settings: l)
    #expect(resting[0].z != st[0].z && resting[0].w == st[0].w)
    // A vertical rate moves both components: v = (-0.2, -1.2) normalizes to
    // (-0.164, -0.986) on the unit circle, so u drifts with it and num2 reads
    // 100 - 200 * 0.0068 down the Down/Up waits -> (-0.0164, 0.0986).
    let down = try SourceStudioIrisRendering.transforms(rateH: 0, rateV: -1, settings: l)
    #expect(abs(Double(down[0].z) - (-0.016439899710016248)) <= 1e-7, "vertical offset u")
    #expect(abs(Double(down[0].w) - 0.09863939703522955) <= 1e-7, "vertical offset v")
    #expect(down[0].w != resting[0].w, "the gaze moves the vertical write")
}

private func defaults(
    pupilX: Double = 0.5, pupilY: Double = 0.5,
    pupilWidth: Double = 0.9, pupilHeight: Double = 0.9,
    hlUpY: Double = 0.5, hlDownY: Double = 0.5) -> SourceStudioIrisRendering.CardValues? {
    SourceStudioIrisRendering.cardOverrides(pupilX: pupilX, pupilY: pupilY,
                                            pupilWidth: pupilWidth, pupilHeight: pupilHeight,
                                            hlUpY: hlUpY, hlDownY: hlDownY, sex: 1, exType: 0)
}

@Test func irisCardOverridesAtChaFileFaceDefaults() throws {
    // ChaFileFace's Initialize defaults: pupilX/Y 0.5, pupilWidth/Height 0.9,
    // hlUpY/hlDownY 0.5.  Mathf.Lerp: offsetX = 0.2 + (-0.8) * 0.5 = -0.2,
    // offsetY = -0.5 + 1.0 * 0.5 = 0.0 (the prefab snapshot carries -0.2, so
    // the resting preview was wrong vertically), scale = 1.8 + (-2.0) * 0.9 =
    // 0 on both axes, hl = 0.1 + (-0.2) * 0.5 = 0.0.
    let card = try #require(defaults())
    #expect(abs(card.offsetX - (-0.2)) <= 1e-7)
    #expect(card.offsetY == 0.0)
    #expect(card.scale.x == 0 && card.scale.y == 0)
    #expect(card.hlUp == 0.0 && card.hlDown == 0.0)
}

@Test func irisCardOverridesAtFieldExtremes() throws {
    // Each Lerp's endpoints: x (0.2, -0.6), y (-0.5, 0.5), scale (1.8, -0.2)
    // and hl (0.1, -0.1).  All extremes sit on exactly representable doubles,
    // so the t = 0 / t = 1 Lerps are exact.
    let zero = try #require(defaults(pupilX: 0, pupilY: 0, pupilWidth: 0, pupilHeight: 0,
                                     hlUpY: 0, hlDownY: 0))
    #expect(zero.offsetX == 0.2 && zero.offsetY == -0.5)
    #expect(zero.scale == SIMD2(1.8, 1.8))
    #expect(zero.hlUp == 0.1 && zero.hlDown == 0.1)
    let one = try #require(defaults(pupilX: 1, pupilY: 1, pupilWidth: 1, pupilHeight: 1,
                                    hlUpY: 1, hlDownY: 1))
    #expect(abs(one.offsetX - (-0.6)) <= 1e-7)
    #expect(one.offsetY == 0.5)
    #expect(abs(one.scale.x - (-0.2)) <= 1e-7 && abs(one.scale.y - (-0.2)) <= 1e-7)
    #expect(one.hlUp == -0.1 && one.hlDown == -0.1)
}

@Test func irisCardOverridesClampOutOfRangeFields() throws {
    // Mathf.Lerp clamps t to 0...1, so fields outside the slider range pin to
    // the Lerp endpoints instead of extrapolating.
    let low = try #require(defaults(pupilX: -3, pupilY: -1, pupilWidth: -0.5, pupilHeight: -2,
                                    hlUpY: -1, hlDownY: -0.25))
    #expect(low.offsetX == 0.2 && low.offsetY == -0.5)
    #expect(low.scale == SIMD2(1.8, 1.8))
    #expect(low.hlUp == 0.1 && low.hlDown == 0.1)
    let high = try #require(defaults(pupilX: 4, pupilY: 2, pupilWidth: 1.5, pupilHeight: 3,
                                     hlUpY: 1.2, hlDownY: 8))
    #expect(abs(high.offsetX - (-0.6)) <= 1e-7)
    #expect(high.offsetY == 0.5)
    #expect(abs(high.scale.x - (-0.2)) <= 1e-7 && abs(high.scale.y - (-0.2)) <= 1e-7)
    #expect(high.hlUp == -0.1 && high.hlDown == -0.1)
}

@Test func irisCardOverridesSkipKeepsThePrefabSnapshot() throws {
    // sex == 0 && exType == 1 makes every ChangeSettingEye* return early, so
    // cardOverrides reports nil and the transforms keep the exported prefab
    // offset/scale/hl: the resting write stays the pinned (+-0.02, 0.02).
    let eyes = try exportedSettings()
    #expect(SourceStudioIrisRendering.cardOverrides(pupilX: 0, pupilY: 1, pupilWidth: 0,
                                                    pupilHeight: 1, hlUpY: 0, hlDownY: 0,
                                                    sex: 0, exType: 1) == nil)
    // Any other identity applies: a normal male or a female with exType 1.
    #expect(SourceStudioIrisRendering.cardOverrides(pupilX: 0.5, pupilY: 0.5, pupilWidth: 0.9,
                                                    pupilHeight: 0.9, hlUpY: 0.5, hlDownY: 0.5,
                                                    sex: 0, exType: 0) != nil)
    #expect(SourceStudioIrisRendering.cardOverrides(pupilX: 0.5, pupilY: 0.5, pupilWidth: 0.9,
                                                    pupilHeight: 0.9, hlUpY: 0.5, hlDownY: 0.5,
                                                    sex: 1, exType: 1) != nil)
    // The nil card value writes the prefab resting offsets, not the card math
    // (pupilX 0 would have given a positive left-eye offset u).
    let st = try SourceStudioIrisRendering.transforms(rateH: 0, rateV: 0, settings: eyes[0], card: nil)
    #expect(abs(Double(st[0].z) - (-0.020000001247972264)) <= 1e-7)
}

@Test func irisCardOffsetXNegatesOnlyForTheRightEye() throws {
    // ChangeSettingEyePosX hands both eyes' SetEyeTexOffsetX the same Lerped
    // value; the R eye stores its negation.  With offsetX 0.3, offsetY 0 and
    // zero scale the _MainTex write is a straight passthrough of
    // lerp(-100, 100, inverseLerp(-1, 1, +-0.3)) * power 0.001: +-0.03.
    let eyes = try exportedSettings()
    let card: SourceStudioIrisRendering.CardValues =
        (offsetX: 0.3, offsetY: 0, scale: SIMD2(0, 0), hlUp: 0, hlDown: 0)
    let l = try SourceStudioIrisRendering.transforms(rateH: 0, rateV: 0, settings: eyes[0], card: card)
    let r = try SourceStudioIrisRendering.transforms(rateH: 0, rateV: 0, settings: eyes[1], card: card)
    #expect(abs(Double(l[0].z) - 0.030000000000000002) <= 1e-7, "left keeps the value")
    #expect(abs(Double(r[0].z) - (-0.030000000000000002)) <= 1e-7, "right stores the negation")
    // The y offset is shared, not negated: offset 0 reads v.y 0, the midpoint
    // of the Down/Up waits -> num2 0 -> a zero vertical write on both eyes.
    #expect(abs(Double(l[0].w)) <= 1e-7 && abs(Double(r[0].w)) <= 1e-7)
}

@Test func irisDefaultCardWritesGroundedRestingOffsetsEndToEnd() throws {
    // The default card at rates (0, 0).  Offsets are in the [-100, 100] space
    // of #56's textureTransforms: v = (0, 0) + card offset, so v = (-0.2, 0)
    // for L and (0.2, 0) for R (SetEyeTexOffsetX negates the shared -0.2 for
    // the right eye).  num = lerp(-100, 100, inverseLerp(-1, 1, -0.2) = 0.4)
    // = -20 for L and +20 for R; num2 = lerp(100, -100, inverseLerp(-1, 1, 0)
    // = 0.5) = 0; scale 0 keeps the 1...5 factors at 1 and subtracts nothing;
    // power 0.001 -> u = -0.02 / +0.02, v = 0.  So the default card's resting
    // u coincides with the prefab snapshot's (+-0.02) but its v write drops
    // from the prefab's +0.02 (num2 was 100 - 200 * 0.4 = 20 off the prefab's
    // offset.y = -0.2) to 0: the resting iris grounds on the card.  hl 0 adds
    // nothing to _overtex1/2.
    let eyes = try exportedSettings()
    let card = try #require(defaults())
    let expectedU = [-0.02, 0.02]
    for (eye, expected) in zip(eyes, expectedU) {
        let st = try SourceStudioIrisRendering.transforms(rateH: 0, rateV: 0, settings: eye, card: card)
        #expect(st.count == 3)
        for vector in st {
            #expect(vector.x == 1 && vector.y == 1, "scale is 1 + 0 = (1, 1)")
            #expect(abs(Double(vector.z) - expected) <= 1e-7, "offset u eye \(eye.eyeLR)")
            #expect(abs(Double(vector.w)) <= 1e-7, "offset v eye \(eye.eyeLR)")
        }
    }
}
