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
    /// The eyeMaterial entry owning a render item's mesh, by index.  The
    /// exported `gameObject` is the source GameObject name, while loaded mesh
    /// names carry the GLTF primitive suffix (`cf_Ohitomi_L02/0`), so the
    /// match strips a trailing `/digits` component.
    public static func eye(ofMeshNamed name: String, in eyes: [SourceStudioEyeMaterialSettings]) -> Int? {
        let base = name.split(separator: "/").first.map(String.init) ?? name
        return eyes.firstIndex { $0.gameObject == base }
    }

    /// The eye's three _ST vectors in texStates order (_MainTex, _overtex1,
    /// _overtex2) for one frame's rates, replayed through `textureTransforms`
    /// with the eye's own exported offset/scale/hl snapshot — the card-driven
    /// values are not recovered, so the prefab snapshot is all a frame has.
    /// Rates (0, 0) are the resting offset the original still applies.
    public static func transforms(rateH: Double, rateV: Double,
                                  settings: SourceStudioEyeMaterialSettings) throws -> [Float4] {
        try SourceStudioEyeMaterialSettings.textureTransforms(
            rateH: rateH, rateV: rateV, settings: settings,
            offset: settings.offset, scale: settings.scale,
            hlUpOffsetY: settings.hlUpOffsetY, hlDownOffsetY: settings.hlDownOffsetY)
            .map { Float4(Float($0.scale.x), Float($0.scale.y), Float($0.offset.x), Float($0.offset.y)) }
    }
}
