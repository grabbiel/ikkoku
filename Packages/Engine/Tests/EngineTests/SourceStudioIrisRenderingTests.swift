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
