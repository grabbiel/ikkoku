import Foundation
import simd
import CoreMath

/// Pure mapping from the eye-look frame's iris-shift rates to the three
/// `MaterialUniforms.irisST` vectors of one eye, the renderer-side half of
/// EyeLookMaterialControll.Update.  The original calls
/// SetTextureOffset/SetTextureScale per eye for _MainTex, _overtex1 and
/// _overtex2; Unity's sampling convention is uv' = uv * scale + offset with
/// _ST = (scaleU, scaleV, offsetU, offsetV), which is exactly the layout
/// Toon.metal reads.  Split out of SourceStudioCharacterPreview so the
/// mapping is testable without Metal or a loaded character.
public enum SourceStudioIrisRendering {
    /// One character's card-driven EyeLookMaterialControll values, as the
    /// load-time ChangeSettingEye* calls compute them before the per-eye
    /// writes: `offsetX` is the shared x offset before SetEyeTexOffsetX
    /// negates it for the right eye, `scale` is (pupilWidth, pupilHeight)
    /// and `hlUp`/`hlDown` the two highlight offsets.
    public typealias CardValues = (offsetX: Double, offsetY: Double, scale: SIMD2<Double>,
                                   hlUp: Double, hlDown: Double)

    /// The eyeMaterial entry owning a render item's mesh, by index.  The
    /// exported `gameObject` is the source GameObject name, while loaded mesh
    /// names carry the GLTF primitive suffix (`cf_Ohitomi_L02/0`), so the
    /// match strips a trailing `/digits` component.
    public static func eye(ofMeshNamed name: String, in eyes: [SourceStudioEyeMaterialSettings]) -> Int? {
        let base = name.split(separator: "/").first.map(String.init) ?? name
        return eyes.firstIndex { $0.gameObject == base }
    }

    /// The card-driven values CharaStudio's load-time ChangeSettingEyeHLUpPosY,
    /// ChangeSettingEyeHLDownPosY, ChangeSettingEyePosX, ChangeSettingEyePosY,
    /// ChangeSettingEyeScaleWidth and ChangeSettingEyeScaleHeight write over
    /// the prefab's serialized offset/scale/hl on both eyes'
    /// EyeLookMaterialControll, as Unity Mathf.Lerp over the face record's
    /// pupil/highlight fields.  Every ChangeSettingEye* returns early for a
    /// special male (sex 0 && exType 1), so this returns nil there and the
    /// prefab snapshot stays.  Mathf.Lerp clamps t to 0...1; a NaN t propagates
    /// the way Mathf.Clamp01 leaves it.
    public static func cardOverrides(pupilX: Double, pupilY: Double,
                                     pupilWidth: Double, pupilHeight: Double,
                                     hlUpY: Double, hlDownY: Double,
                                     sex: Int, exType: Int) -> CardValues? {
        guard sex != 0 || exType != 1 else { return nil }
        return CardValues(offsetX: lerp(0.2, -0.6, pupilX),
                          offsetY: lerp(-0.5, 0.5, pupilY),
                          scale: SIMD2(lerp(1.8, -0.2, pupilWidth), lerp(1.8, -0.2, pupilHeight)),
                          hlUp: lerp(0.1, -0.1, hlUpY), hlDown: lerp(0.1, -0.1, hlDownY))
    }

    /// Mathf.Lerp: a + (b - a) * Mathf.Clamp01(t), so t outside 0...1 clamps
    /// and NaN passes through to the product.
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * min(max(t, 0), 1)
    }

    /// The eye's three _ST vectors in texStates order (_MainTex, _overtex1,
    /// _overtex2) for one frame's rates, replayed through `textureTransforms`
    /// with `card` substituted for the eye's exported offset/scale/hl
    /// snapshot — SetEyeTexOffsetX writes the shared x offset negated on the
    /// right eye, the other card values unchanged.  Without card values the
    /// eye's prefab snapshot is all a frame has.  Rates (0, 0) are the resting
    /// offset the original still applies.
    public static func transforms(rateH: Double, rateV: Double,
                                  settings: SourceStudioEyeMaterialSettings,
                                  card: CardValues? = nil) throws -> [Float4] {
        // ChangeSettingEyePosX hands one Lerped value to both eyes'
        // SetEyeTexOffsetX, which negates it when eyeLR is the right eye.
        let offset: SIMD2<Double>
        if let card {
            offset = SIMD2(settings.eyeLR == 1 ? -card.offsetX : card.offsetX, card.offsetY)
        } else {
            offset = settings.offset
        }
        return try SourceStudioEyeMaterialSettings.textureTransforms(
            rateH: rateH, rateV: rateV, settings: settings,
            offset: offset, scale: card?.scale ?? settings.scale,
            hlUpOffsetY: card?.hlUp ?? settings.hlUpOffsetY,
            hlDownOffsetY: card?.hlDown ?? settings.hlDownOffsetY)
            .map { Float4(Float($0.scale.x), Float($0.scale.y), Float($0.offset.x), Float($0.offset.y)) }
    }
}
