import Foundation
import simd
import CoreMath
import Character

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
        try unityTransforms(rateH: rateH, rateV: rateV, settings: settings, card: card)
            .map { nativeST(scale: $0.scale, offset: $0.offset) }
    }

    /// `transforms` before the native-V conversion: the Unity-convention
    /// scale/offset EyeLookMaterialControll writes per texState.
    public static func unityTransforms(rateH: Double, rateV: Double,
                                       settings: SourceStudioEyeMaterialSettings,
                                       card: CardValues? = nil) throws
        -> [(offset: SIMD2<Double>, scale: SIMD2<Double>, yure: Bool)] {
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
    }

    /// The card's six pupil/highlight face fields as `cardOverrides` values,
    /// the same load-time rule the Studio preview applies: a missing field
    /// keeps the whole prefab snapshot (`values` nil, `missing` names it).
    public static func cardValues(appearance: SourceCardAppearance?, sex: Int, exType: Int) -> (values: CardValues?, missing: [String]) {
        let paths = ["face.pupilX", "face.pupilY", "face.pupilWidth", "face.pupilHeight", "face.hlUpY", "face.hlDownY"]
        let labels = ["pupil X", "pupil Y", "pupil width", "pupil height", "highlight up Y", "highlight down Y"]
        var fields: [Double] = [], missing: [String] = []
        for (path, label) in zip(paths, labels) {
            guard let value = appearance?.number(path) else { missing.append(label); continue }
            fields.append(Double(value))
        }
        guard fields.count == paths.count else { return (nil, missing) }
        return (cardOverrides(pupilX: fields[0], pupilY: fields[1], pupilWidth: fields[2], pupilHeight: fields[3],
                              hlUpY: fields[4], hlDownY: fields[5], sex: sex, exType: exType), [])
    }

    /// One frame's iris transforms as the shader binding set's eye-look input
    /// (`SourceShaderBindingDerivation.EyeLook`), keyed by each eyeMaterial
    /// entry's source GameObject and texState texture name. `rates` are the
    /// frame's per-eye horizontal and shared vertical iris-shift rates; nil is
    /// the resting (0, 0) rate the original still applies.
    public static func bindingEyeLook(eyes: [SourceStudioEyeMaterialSettings], card: CardValues?,
                                      rates: (horizontal: [Double], vertical: Double)?, source: String) throws
        -> SourceShaderBindingDerivation.EyeLook {
        var transforms: [String: [String: SourceShaderBindingDerivation.EyeLook.Transform]] = [:]
        for settings in eyes {
            var rateH = 0.0, rateV = 0.0
            if let rates, rates.horizontal.indices.contains(settings.eyeLR) { rateH = rates.horizontal[settings.eyeLR]; rateV = rates.vertical }
            let values = try unityTransforms(rateH: rateH, rateV: rateV, settings: settings, card: card)
            for (state, value) in zip(settings.texStates, values) {
                transforms[settings.gameObject, default: [:]][state.texName] = .init(
                    scale: [Float(value.scale.x), Float(value.scale.y)], offset: [Float(value.offset.x), Float(value.offset.y)], yure: value.yure)
            }
        }
        return .init(transforms: transforms, source: source)
    }

    /// Converts a Unity `_ST` (uv' = uv·scale + offset, Unity V) to the shader
    /// layout in native V. `SourceRig` stores source UVs as (u, 1 − v) over
    /// upright textures, so the native sample must equal 1 − (the Unity
    /// sample): v' = v·scale.y + (1 − scale.y − offset.y). U is unchanged.
    public static func nativeST(scale: SIMD2<Double>, offset: SIMD2<Double>) -> Float4 {
        Float4(Float(scale.x), Float(scale.y), Float(offset.x), Float(1 - scale.y - offset.y))
    }
}
