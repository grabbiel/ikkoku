import Foundation
import CoreMath
import Assets
import Scene
import Character
import Renderer
import ShaderTypes

// ST-A11 maps, slice 4: the map draws that sample no light — Unlit/Transparent
// and Studio's Custom/Silhouette mob shader — and the guard that keeps the
// converter's block-only images away from every image decoder
// (docs/reference/studio/maps.md, "Slice 4").
//
// - Unlit-Alpha.shader v5.6.2f1 ("Unlit/Transparent"): Queue Transparent,
//   ZWrite Off, Blend SrcAlpha OneMinusSrcAlpha, Cull Back (unset);
//   col = tex2D(_MainTex, TRANSFORM_TEX(uv)), then fog. The converter reads the
//   pass state from the bundle and checks the DX11 fragment is that one sample.
// - Custom/Silhouette (the game's shader; its pass state and DX11 programs are
//   read from the bundle, `export_map_scene.py silhouette_state`): pass 1
//   ColorMask 0, ZWrite On, ZTest LEqual; pass 2 ZWrite Off, ZTest LEqual,
//   Blend SrcAlpha OneMinusSrcAlpha, fragment `mov o0, _Color`. Both Cull Back.
//   `Studio.Map` sets _Color to the user's mob colour through a
//   MaterialPropertyBlock; the converter writes the setting's default.

/// What decides whether a map image's bytes may reach an image decoder.
public enum SourceStudioMapImageBytes {
    /// PNG (`89 50 4E 47 0D 0A 1A 0A`) or JPEG (`FF D8 FF`) magic.
    public static func isPNGOrJPEG(_ data: Data) -> Bool {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        return data.starts(with: png) || data.starts(with: jpeg)
    }
}

/// An Unlit/Transparent material (`ikkokuUnlit`).
public enum SourceStudioUnlitInputs {
    public static let kind = "ikkoku.unityUnlitTransparent"

    /// true for an `ikkokuUnlit` record, nil without one.
    public static func parse(_ extras: JSONValue?) throws -> Bool? {
        guard let value = extras?["ikkokuUnlit"] else { return nil }
        guard value["kind"]?.stringValue == kind, value["version"]?.doubleValue == 1 else {
            throw RigError.invalid("A map material's Unlit/Transparent record is not a version 1 \(kind).")
        }
        return true
    }

    /// `MaterialKindMap` with `MaterialFlagMapUnlit`: texture × baseColor
    /// (white as the converter writes it), blended as the glTF alpha mode
    /// says, culled as its `doubleSided` says.
    public static func material(_ material: MaterialData, base: TextureHandle?) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindMap))
        m.uniforms.flags = MaterialFlagNoOutline.rawValue | MaterialFlagMapUnlit.rawValue
        m.uniforms.baseColor = material.baseColorFactor
        m.base = base
        m.setFlag(MaterialFlagHasBaseTexture, base != nil)
        m.setFlag(MaterialFlagDoubleSided, material.doubleSided)
        m.setFlag(MaterialFlagAlphaBlend, material.alphaMode == "BLEND")
        m.transparent = material.alphaMode == "BLEND"
        return m
    }
}

/// A Custom/Silhouette material (`ikkokuSilhouette`): the mob colour and the
/// two passes, which must be the state the renderer draws.
public struct SourceStudioSilhouetteInputs: Sendable, Equatable {
    public static let kind = "ikkoku.unitySilhouette"
    /// _Color as a Linear player uploads it (the converter's default mob colour).
    public let color: Float4

    public static func parse(_ extras: JSONValue?) throws -> SourceStudioSilhouetteInputs? {
        guard let value = extras?["ikkokuSilhouette"] else { return nil }
        func fail(_ reason: String) -> Error { RigError.invalid("A map silhouette material \(reason).") }
        guard value["kind"]?.stringValue == kind, value["version"]?.doubleValue == 1 else { throw fail("is not a version 1 \(kind)") }
        guard let color = value["colorLinear"]?.arrayValue?.compactMap(\.doubleValue), color.count == 4, color.allSatisfy(\.isFinite) else {
            throw fail("has no colour")
        }
        // The renderer draws exactly these two passes (Renderer's transparent group).
        let passes = value["passes"]?.arrayValue ?? []
        func pass(_ index: Int, zWrite: Double, blend: [String], colorMask: String) -> Bool {
            guard passes.indices.contains(index) else { return false }
            let p = passes[index]
            return p["cull"]?.stringValue == "Back" && p["zWrite"]?.doubleValue == zWrite && p["zTest"]?.stringValue == "LEqual"
                && p["blend"]?.arrayValue?.compactMap(\.stringValue) == blend && p["colorMask"]?.stringValue == colorMask
        }
        guard passes.count == 2,
              pass(0, zWrite: 1, blend: ["One", "Zero", "One", "Zero"], colorMask: "0"),
              pass(1, zWrite: 0, blend: ["SrcAlpha", "OneMinusSrcAlpha", "SrcAlpha", "OneMinusSrcAlpha"], colorMask: "RGBA") else {
            throw fail("is not the two-pass state the app draws (depth only, then blended at ZTest LEqual, Cull Back)")
        }
        return SourceStudioSilhouetteInputs(color: Float4(Float(color[0]), Float(color[1]), Float(color[2]), Float(color[3])))
    }

    /// `MaterialKindMap` with `MaterialFlagMapSilhouette`: `map_fragment`
    /// returns the colour; the renderer draws the depth pass first. Cull Back.
    public func material() -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindMap))
        m.uniforms.flags = MaterialFlagNoOutline.rawValue | MaterialFlagMapSilhouette.rawValue | MaterialFlagAlphaBlend.rawValue
        m.uniforms.baseColor = color
        m.transparent = true
        return m
    }
}
