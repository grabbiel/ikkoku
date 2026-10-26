import Foundation
import Metal
import simd
import CoreMath
import Assets
import Scene
import Character
import Renderer
import ShaderTypes

// ST-A11 maps, slice 3: a converted map's textures as native BC blocks, its
// Skybox/Cubemap sky and its Particles/Alpha Blended draws
// (docs/reference/studio/maps.md, "Block images", "The sky", "Particles").
//
// Built-in shader sources, tag v5.6.2f1:
// - Skybox-Cubed.shader: Queue Background, Cull Off, ZWrite Off. The vertex is
//   rotated by RotateAroundYInDegrees(v.vertex, _Rotation) for the clip
//   position; the cube is sampled at the unrotated v.vertex.xyz; the fragment
//   is DecodeHDR(texCUBE(_Tex, dir), _Tex_HDR) * _Tint.rgb *
//   unity_ColorSpaceDouble.rgb * _Exposure.
// - DecodeHDR (UnityCG.cginc L497-L512), Linear: alpha = w * (a - 1) + 1;
//   (x * pow(alpha, y)) * rgb.
// - unity_ColorSpaceDouble (UnityCG.cginc L26), Linear: 4.59479380.
// - Particle Alpha Blend.shader: o.color = v.color * _TintColor;
//   col = 2 * i.color * tex2D(_MainTex); Blend SrcAlpha OneMinusSrcAlpha,
//   ColorMask RGB, Cull Off, ZWrite Off, no lighting.
// `sky_vertex` / `sky_fragment` and `map_fragment`'s particle branch
// (Shaders/Toon.metal) draw these.

/// The converter's block files for a map's images and cubes
/// (`ikkokuBlockImages` in the glTF's top-level extras).
public struct SourceStudioBlockImages: Sendable {
    public static let kind = "ikkoku.unityBlockImages"
    public static let faceOrder = ["+X", "-X", "+Y", "-Y", "+Z", "-Z"]
    /// BC1/BC3 blocks of a glTF image, by image index (rows top-down like its PNG).
    public let images: [Int: SourceStudioBlockTexture.File]
    /// Six-face cubes by cube index.
    public let cubes: [Int: SourceStudioBlockTexture.File]

    /// nil when the glTF lists none. Refuses a row order, face order or file it
    /// does not reproduce.
    public static func parse(_ extras: JSONValue?, label: String) throws -> SourceStudioBlockImages? {
        guard let value = extras?["ikkokuBlockImages"] else { return nil }
        func fail(_ reason: String) -> Error { RigError.invalid("\(label) block images: \(reason).") }
        guard value["kind"]?.stringValue == kind, value["version"]?.doubleValue == 1 else { throw fail("not a version 1 \(kind)") }
        guard value["rows"]?.stringValue == "topDown" else { throw fail("rows \(value["rows"]?.stringValue ?? "none") are not top-down") }
        func index(_ json: JSONValue, _ key: String) throws -> Int {
            guard let number = json[key]?.doubleValue, let index = Int(exactly: number), index >= 0 else { throw fail("an entry has no \(key) index") }
            return index
        }
        var images: [Int: SourceStudioBlockTexture.File] = [:]
        for json in value["images"]?.arrayValue ?? [] {
            let image = try index(json, "image")
            guard images[image] == nil else { throw fail("image \(image) is listed twice") }
            let file = try SourceStudioBlockTexture.parseFile(json, failure: fail, role: "image \(image)")
            // BC7 cannot be row-flipped losslessly; the converter keeps those PNG-only.
            guard file.format != .bc7 else { throw fail("image \(image) is BC7") }
            images[image] = file
        }
        var cubes: [Int: SourceStudioBlockTexture.File] = [:]
        for json in value["cubes"]?.arrayValue ?? [] {
            let cube = try index(json, "cube")
            guard cubes[cube] == nil else { throw fail("cube \(cube) is listed twice") }
            let file = try SourceStudioBlockTexture.parseFile(json, failure: fail, role: "cube \(cube)")
            guard json["faces"]?.doubleValue == 6, file.width == file.height,
                  json["faceOrder"]?.arrayValue?.compactMap(\.stringValue) == faceOrder,
                  json["rows"]?.stringValue == "topDown" else {
                throw fail("cube \(cube) is not six square faces in D3D order, rows top-down")
            }
            cubes[cube] = file
        }
        return SourceStudioBlockImages(images: images, cubes: cubes)
    }
}

/// The recovered sky arithmetic, mirrored on the CPU for tests and tools.
public enum SourceStudioSkyMath {
    /// unity_ColorSpaceDouble.rgb in a Linear player.
    public static let colorSpaceDoubleLinear: Float = 4.59479380

    /// `RotateAroundYInDegrees` on a Unity object-space position.
    public static func rotateAroundY(_ p: SIMD3<Float>, degrees: Float) -> SIMD3<Float> {
        let a = degrees * .pi / 180
        return SIMD3(cos(a) * p.x - sin(a) * p.z, p.y, sin(a) * p.x + cos(a) * p.z)
    }

    /// `DecodeHDR`, Linear branch, of a sampled texel (RGB already linear).
    public static func decodeHDR(_ texel: SIMD4<Float>, _ instructions: SIMD4<Float>) -> SIMD3<Float> {
        let alpha = instructions.w * (texel.w - 1) + 1
        return (instructions.x * powf(alpha, instructions.y)) * SIMD3(texel.x, texel.y, texel.z)
    }

    /// The fragment: DecodeHDR(texel) * _Tint.rgb * unity_ColorSpaceDouble * _Exposure.
    public static func radiance(_ texel: SIMD4<Float>, sky: SourceStudioSkyInputs) -> SIMD3<Float> {
        decodeHDR(texel, sky.decodeInstructions) * sky.scale
    }
}

/// A Skybox/Cubemap material as the converter recovered it (`ikkokuSkybox`).
public struct SourceStudioSkyInputs: Sendable, Equatable {
    public let cube: Int
    /// _Tint.rgb in Linear.
    public let tint: SIMD3<Float>
    /// _Exposure in Linear (a [Gamma] property).
    public let exposure: Float
    public let rotationDegrees: Float
    public let colorSpaceDouble: Float
    /// _Tex_HDR (x, y, z, w).
    public let decodeInstructions: SIMD4<Float>

    /// `_Tint.rgb * unity_ColorSpaceDouble.rgb * _Exposure`.
    public var scale: SIMD3<Float> { tint * colorSpaceDouble * exposure }

    public static func parse(_ extras: JSONValue?) throws -> SourceStudioSkyInputs? {
        guard let value = extras?["ikkokuSkybox"] else { return nil }
        guard value["kind"]?.stringValue == "ikkoku.unitySkyboxCubemap", value["version"]?.doubleValue == 1,
              let cube = value["cube"]?.doubleValue.flatMap({ Int(exactly: $0) }), cube >= 0,
              let tint = value["tintLinear"]?.arrayValue?.compactMap(\.doubleValue), tint.count == 3,
              let exposure = value["exposure"]?.doubleValue, let rotation = value["rotationDegrees"]?.doubleValue,
              let double = value["colorSpaceDouble"]?.doubleValue,
              let decode = value["decodeInstructions"]?.arrayValue?.compactMap(\.doubleValue), decode.count == 4,
              (tint + decode + [exposure, rotation, double]).allSatisfy(\.isFinite) else {
            throw RigError.invalid("A map sky material's Skybox/Cubemap inputs are incomplete.")
        }
        return SourceStudioSkyInputs(cube: cube, tint: SIMD3(Float(tint[0]), Float(tint[1]), Float(tint[2])),
                                     exposure: Float(exposure), rotationDegrees: Float(rotation), colorSpaceDouble: Float(double),
                                     decodeInstructions: SIMD4(Float(decode[0]), Float(decode[1]), Float(decode[2]), Float(decode[3])))
    }
}

/// `MaterialKindSky`: what `sky_vertex` / `sky_fragment` read.
public enum SourceStudioSkyMaterial {
    public static func make(_ sky: SourceStudioSkyInputs, cube: TextureHandle) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindSky))
        m.uniforms.flags = MaterialFlagNoOutline.rawValue | MaterialFlagDoubleSided.rawValue
        let scale = sky.scale
        m.uniforms.baseColor = Float4(scale.x, scale.y, scale.z, 1)
        m.uniforms.params = Float4(sky.rotationDegrees, sky.decodeInstructions.x, sky.decodeInstructions.y, sky.decodeInstructions.w)
        m.cubemap = cube
        return m
    }

    /// The map probe's sky images (ST-A11 evidence, `compare_original_map.py`'s sky gate).
    public enum Variant: String, CaseIterable, Sendable {
        /// The recovered formula.
        case decoded
        /// Negative control: every cube face sampled with its rows flipped
        /// (`MaterialFlagSkyRowsFlipped`).
        case rowsFlipped
        /// Negative control: `_Rotation` ignored.
        case rotationIgnored
        /// Negative control: a Gamma player's `unity_ColorSpaceDouble` (2.0) in
        /// place of the Linear one.
        case gammaConstants
    }

    /// `material` (a `MaterialKindSky` material from `make`) drawn as `variant`;
    /// nil for any other kind.
    public static func variant(_ material: MaterialState, _ variant: Variant) -> MaterialState? {
        guard material.kind == MaterialKindSky else { return nil }
        var m = material
        switch variant {
        case .decoded:
            break
        case .rowsFlipped:
            m.setFlag(MaterialFlagSkyRowsFlipped, true)
        case .rotationIgnored:
            m.uniforms.params.x = 0
        case .gammaConstants:
            let k: Float = 2 / SourceStudioSkyMath.colorSpaceDoubleLinear
            let b = m.uniforms.baseColor
            m.uniforms.baseColor = Float4(b.x * k, b.y * k, b.z * k, b.w)
        }
        return m
    }
}

/// A Particles/Alpha Blended material (`ikkokuParticle`): _TintColor as a
/// Linear player uploads it.
public struct SourceStudioParticleInputs: Sendable, Equatable {
    public let tint: Float4

    public static func parse(_ extras: JSONValue?) throws -> SourceStudioParticleInputs? {
        guard let value = extras?["ikkokuParticle"] else { return nil }
        guard let tint = value["tintLinear"]?.arrayValue?.compactMap(\.doubleValue), tint.count == 4, tint.allSatisfy(\.isFinite) else {
            throw RigError.invalid("A map particle material's tint is incomplete.")
        }
        return SourceStudioParticleInputs(tint: Float4(Float(tint[0]), Float(tint[1]), Float(tint[2]), Float(tint[3])))
    }

    /// `MaterialKindMap` with `MaterialFlagMapParticle`: 2 * vertex colour *
    /// tint * texture, alpha blended, both faces, in the transparent pass.
    public func material(base: TextureHandle?) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindMap))
        m.uniforms.flags = MaterialFlagNoOutline.rawValue | MaterialFlagMapParticle.rawValue | MaterialFlagDoubleSided.rawValue
            | MaterialFlagAlphaBlend.rawValue
        m.uniforms.baseColor = tint
        m.base = base
        m.setFlag(MaterialFlagHasBaseTexture, base != nil)
        m.transparent = true
        return m
    }

    /// The map probe's particle images (ST-A11 evidence, `compare_original_map.py`'s particle gate).
    public enum Variant: String, CaseIterable, Sendable {
        /// The recovered formula.
        case decoded
        /// Negative control: `col = i.color * tex` (the shader's factor 2 left out, alpha included).
        case noDoubling
        /// Negative control: _TintColor as stored (sRGB), without the Linear player's conversion.
        case gammaTint
    }

    /// `material` (a particle material from `material(base:)`) drawn as
    /// `variant`; nil for any other draw.
    public static func variant(_ material: MaterialState, _ variant: Variant) -> MaterialState? {
        guard SourceStudioMapAsset.Draw(material) == .particle else { return nil }
        var m = material
        let t = m.uniforms.baseColor
        switch variant {
        case .decoded:
            break
        case .noDoubling:
            m.uniforms.baseColor = t * 0.5
        case .gammaTint:
            m.uniforms.baseColor = Float4(srgbEncoded(t.x), srgbEncoded(t.y), srgbEncoded(t.z), t.w)
        }
        return m
    }

    /// Unity's `Mathf.LinearToGammaSpace` (the sRGB transfer function).
    static func srgbEncoded(_ linear: Float) -> Float {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * powf(linear, 1 / 2.4) - 0.055
    }
}
