import Foundation
import CryptoKit
import Metal
import simd
import CoreMath
import Assets
import Scene
import Character
import Renderer
import ShaderTypes

// ST-A11 maps, slice 2: a converted map's baked lightmaps, drawn the way Unity
// 5.6.2f1's Standard shader applies them in the original player (Linear colour
// space, D3D11; docs/reference/studio/maps.md, "Baked lightmaps").
//
// Built-in shader sources, tag v5.6.2f1:
// - fragForwardBaseInternal (UnityStandardCore.cginc L407-L425):
//   c = UNITY_BRDF_PBS(diffColor, specColor, ..., gi.light, gi.indirect) + Emission(uv).
// - BRDF1_Unity_PBS (UnityStandardBRDF.cginc L304-L306):
//   diffColor * (gi.diffuse + light.color * diffuseTerm) + the two specular terms.
// - UnityGI_Base (UnityGlobalIllumination.cginc L88-L148): a lightmapped draw
//   samples no SH ambient (UNITY_SHOULD_SAMPLE_SH, UnityCG.cginc L49);
//   gi.diffuse = DecodeDirectionalLightmap(DecodeLightmap(unity_Lightmap),
//   unity_LightmapInd, normalWorld) * occlusion.
// - DecodeLightmapRGBM (UnityCG.cginc L517-L529), Linear:
//   unity_Lightmap_HDR.x * pow(data.a, unity_Lightmap_HDR.y) * data.rgb.
// - DecodeDirectionalLightmap (UnityCG.cginc L570-L582):
//   color * (dot(normalWorld, dir.xyz - 0.5) + 0.5) / max(1e-4, dir.w).
// - DiffuseAndSpecularFromMetallic / OneMinusReflectivityFromMetallic
//   (UnityStandardUtils.cginc L35-L51): diffColor = albedo * (0.96 - 0.96 * metallic)
//   with unity_ColorSpaceDielectricSpec.a = 1 - 0.04 in Linear (UnityCG.cginc L27).
// - Emission (UnityStandardInput.cginc L176-L183): tex2D(_EmissionMap).rgb * _EmissionColor.rgb.
// unity_Lightmap_HDR is set by the engine, not by the shader source: an RGBM
// lightmap has a range of 5 in gamma space, which Linear raises to
// GammaToLinearSpaceExact(5) = 5^2.2 with exponent 2.2 (UnityCG.cginc L88-L96).
// The original-player oracle capture checks these numbers.
// `map_fragment` (Shaders/Toon.metal) draws diffColor * gi.diffuse + Emission.

/// The recovered lightmap arithmetic, mirrored on the CPU for tests and tools.
public enum SourceStudioLightmapMath {
    /// unity_Lightmap_HDR.x for an RGBM lightmap in a Linear-colour-space player.
    public static let linearRGBMRange: Float = gammaToLinearExact(5)
    /// unity_Lightmap_HDR.y in Linear (the gamma exponent applied to the multiplier).
    public static let linearRGBMExponent: Float = 2.2
    /// unity_ColorSpaceDielectricSpec.a in Linear: 1 - 0.04.
    public static let oneMinusDielectricSpec: Float = 1 - 0.04

    /// `GammaToLinearSpaceExact` (UnityCG.cginc L88-L96), which also converts
    /// material colours in a Linear player.
    public static func gammaToLinearExact(_ value: Float) -> Float {
        if value <= 0.04045 { return value / 12.92 }
        if value < 1 { return powf((value + 0.055) / 1.055, 2.4) }
        return powf(value, 2.2)
    }

    /// `DecodeLightmapRGBM`, Linear branch. `data` is the sampled texel, its
    /// RGB already decoded from sRGB by the sampler.
    public static func decodeRGBM(_ data: SIMD4<Float>, range: Float = linearRGBMRange,
                                  exponent: Float = linearRGBMExponent) -> SIMD3<Float> {
        (range * powf(data.w, exponent)) * SIMD3(data.x, data.y, data.z)
    }

    /// `DecodeDirectionalLightmap`, with the normal in the engine basis. The
    /// direction was baked in Unity's left-handed world: the engine basis
    /// reflects Z, which leaves the dot product unchanged.
    public static func directional(_ color: SIMD3<Float>, direction: SIMD4<Float>, engineNormal: SIMD3<Float>) -> SIMD3<Float> {
        let unityDirection = SIMD3(direction.x - 0.5, direction.y - 0.5, -(direction.z - 0.5))
        let halfLambert = simd_dot(engineNormal, unityDirection) + 0.5
        return color * halfLambert / max(1e-4, direction.w)
    }

    /// `OneMinusReflectivityFromMetallic` (Linear).
    public static func oneMinusReflectivity(metallic: Float) -> Float {
        oneMinusDielectricSpec - metallic * oneMinusDielectricSpec
    }
}

/// Block-compressed textures uploaded exactly as the bundle serialized them
/// (the converter writes Unity's `image_data` unchanged: every mip level,
/// largest first, rows bottom-up like Unity's texture memory).
public enum SourceStudioBlockTexture {
    public enum Format: String, Sendable {
        /// Unity DXT1 (TextureFormat 10).
        case bc1 = "BC1"
        /// Unity DXT5 (TextureFormat 12).
        case bc3 = "BC3"

        public var blockBytes: Int { self == .bc1 ? 8 : 16 }

        public func pixelFormat(srgb: Bool) -> MTLPixelFormat {
            switch self {
            case .bc1: return srgb ? .bc1_rgba_srgb : .bc1_rgba
            case .bc3: return srgb ? .bc3_rgba_srgb : .bc3_rgba
            }
        }
    }

    /// Bytes of each mip level, largest first. A level smaller than 4×4 still
    /// takes one block per dimension.
    public static func levelByteCounts(width: Int, height: Int, mipCount: Int, format: Format) -> [Int] {
        var counts: [Int] = []
        counts.reserveCapacity(mipCount)
        var (w, h) = (width, height)
        for _ in 0..<mipCount {
            counts.append(max(1, (w + 3) / 4) * max(1, (h + 3) / 4) * format.blockBytes)
            (w, h) = (max(1, w / 2), max(1, h / 2))
        }
        return counts
    }

    /// A shared-storage texture holding `data` level by level. Refuses sizes
    /// that do not add up, more levels than the size allows, and a device
    /// without BC sampling.
    public static func make(device: any MTLDevice, data: Data, width: Int, height: Int, mipCount: Int,
                            format: Format, srgb: Bool, label: String) throws -> any MTLTexture {
        guard (1...16384).contains(width), (1...16384).contains(height) else {
            throw RigError.invalid("\(label): block texture size \(width)×\(height) is out of range.")
        }
        let fullChain = Int(log2(Double(max(width, height)))) + 1
        guard (1...fullChain).contains(mipCount) else {
            throw RigError.invalid("\(label): \(mipCount) mip levels for \(width)×\(height) (at most \(fullChain)).")
        }
        let counts = levelByteCounts(width: width, height: height, mipCount: mipCount, format: format)
        let total = counts.reduce(0, +)
        guard data.count == total else {
            throw RigError.invalid("\(label): \(data.count) bytes, \(format.rawValue) \(width)×\(height) with \(mipCount) levels needs \(total).")
        }
        guard device.supportsBCTextureCompression else {
            throw RigError.invalid("\(label): this GPU does not sample BC textures.")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format.pixelFormat(srgb: srgb),
                                                                  width: width, height: height, mipmapped: mipCount > 1)
        descriptor.mipmapLevelCount = mipCount
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RigError.invalid("\(label): Metal refused a \(format.rawValue) texture.")
        }
        texture.label = label
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            var (w, h) = (width, height)
            for level in 0..<mipCount {
                texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level,
                                withBytes: raw.baseAddress!.advanced(by: offset), bytesPerRow: max(1, (w + 3) / 4) * format.blockBytes)
                offset += counts[level]
                (w, h) = (max(1, w / 2), max(1, h / 2))
            }
        }
        return texture
    }
}

/// The lightmaps a converted map carries (`ikkokuLightmaps` in the glTF's
/// top-level extras, written by `export_map_scene.py`).
public struct SourceStudioLightmapSet: Sendable {
    public struct Texture: Sendable, Equatable {
        public let name: String
        public let file: String
        public let format: SourceStudioBlockTexture.Format
        public let width: Int, height: Int, mipCount: Int
        public let srgb: Bool
        public let sha256: String
        public let bytes: Int
    }
    public struct Entry: Sendable, Equatable {
        public let index: Int
        public let light: Texture
        /// The CombinedDirectional direction map; nil for NonDirectional.
        public let direction: Texture?
    }

    public static let kind = "ikkoku.unityLightmaps"
    /// `LightmapSettings.m_LightmapsMode` 0 or 1.
    public let directional: Bool
    /// unity_Lightmap_HDR (x, y) for the lightmaps' encoding and the player's colour space.
    public let range: Float, exponent: Float
    public let entries: [Int: Entry]

    /// nil when the glTF has no lightmaps (a slice-1 export). Refuses an
    /// encoding, colour space, row order or file it does not reproduce.
    public static func parse(_ extras: JSONValue?, label: String) throws -> SourceStudioLightmapSet? {
        guard let value = extras?["ikkokuLightmaps"] else { return nil }
        func fail(_ reason: String) -> Error { RigError.invalid("\(label) lightmaps: \(reason).") }
        guard value["kind"]?.stringValue == kind, value["version"]?.doubleValue == 1 else { throw fail("not a version 1 \(kind)") }
        let directional: Bool
        switch value["mode"]?.stringValue {
        case "CombinedDirectional"?: directional = true
        case "NonDirectional"?: directional = false
        case let other: throw fail("mode \(other ?? "none") is not drawn")
        }
        // Only RGBM in a Linear player is recovered (UnityCG.cginc L517-L529).
        guard value["encoding"]?.stringValue == "RGBM" else { throw fail("encoding \(value["encoding"]?.stringValue ?? "none") is not RGBM") }
        guard value["colorSpace"]?.stringValue == "Linear" else { throw fail("colour space \(value["colorSpace"]?.stringValue ?? "none") is not Linear") }
        guard value["rows"]?.stringValue == "bottomUp" else { throw fail("rows \(value["rows"]?.stringValue ?? "none") are not Unity's bottom-up order") }
        func texture(_ json: JSONValue?, _ role: String) throws -> Texture {
            guard let json, let name = json["name"]?.stringValue, let file = json["file"]?.stringValue,
                  let format = json["format"]?.stringValue.flatMap(SourceStudioBlockTexture.Format.init(rawValue:)),
                  let width = json["width"]?.doubleValue, let height = json["height"]?.doubleValue,
                  let mips = json["mipCount"]?.doubleValue, let srgb = json["srgb"]?.boolValue,
                  let sha = json["sha256"]?.stringValue, let bytes = json["bytes"]?.doubleValue else {
                throw fail("the \(role) map is incomplete")
            }
            let parts = file.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.isEmpty, !file.hasPrefix("/"), !file.contains("\\"),
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw fail("\(file) leaves the map's directory")
            }
            return Texture(name: name, file: file, format: format, width: Int(width), height: Int(height),
                           mipCount: Int(mips), srgb: srgb, sha256: sha, bytes: Int(bytes))
        }
        var entries: [Int: Entry] = [:]
        for map in value["maps"]?.arrayValue ?? [] {
            guard let number = map["index"]?.doubleValue, let index = Int(exactly: number), index >= 0 else { throw fail("a map has no index") }
            guard entries[index] == nil else { throw fail("index \(index) is listed twice") }
            let light = try texture(map["light"], "light")
            let direction = directional ? try texture(map["direction"], "direction") : nil
            entries[index] = Entry(index: index, light: light, direction: direction)
        }
        guard !entries.isEmpty else { throw fail("no maps") }
        return SourceStudioLightmapSet(directional: directional, range: SourceStudioLightmapMath.linearRGBMRange,
                                       exponent: SourceStudioLightmapMath.linearRGBMExponent, entries: entries)
    }

    /// Reads one listed file, checks its size and SHA-256, and uploads it.
    public static func upload(_ texture: Texture, directory: URL, device: any MTLDevice) throws -> any MTLTexture {
        let url = directory.appendingPathComponent(texture.file)
        let data = try Data(contentsOf: url)
        guard data.count == texture.bytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == texture.sha256 else {
            throw RigError.invalid("Lightmap \(texture.file) does not match its recorded size and SHA-256.")
        }
        return try SourceStudioBlockTexture.make(device: device, data: data, width: texture.width, height: texture.height,
                                                 mipCount: texture.mipCount, format: texture.format, srgb: texture.srgb,
                                                 label: texture.name)
    }
}

/// The Standard inputs the converter recovered for one map material
/// (`ikkokuStandard` in the material's extras).
public struct SourceStudioStandardInputs: Sendable, Equatable {
    /// `_Color` converted to Linear (rgb), with its alpha.
    public let albedo: Float4
    public let oneMinusReflectivity: Float
    /// `_EmissionColor` converted to Linear when `_EMISSION` is on.
    public let emissionColor: Float3?
    /// The glTF image of `_EmissionMap` (the base image when they are the same
    /// texture); nil samples Unity's default, white.
    public let emissionImage: Int?
    /// Whether that texture is sRGB (Unity m_ColorSpace 1).
    public let emissionSRGB: Bool

    public static func parse(_ extras: JSONValue?) throws -> SourceStudioStandardInputs? {
        guard let value = extras?["ikkokuStandard"] else { return nil }
        guard let color = value["albedoLinear"]?.arrayValue?.compactMap(\.doubleValue), color.count == 4,
              let reflectivity = value["oneMinusReflectivity"]?.doubleValue,
              color.allSatisfy(\.isFinite), reflectivity.isFinite else {
            throw RigError.invalid("A map material's Standard inputs are incomplete.")
        }
        var emission: Float3?
        var image: Int?
        var srgb = true
        if let json = value["emission"], json != .null {
            guard let rgb = json["colorLinear"]?.arrayValue?.compactMap(\.doubleValue), rgb.count == 3, rgb.allSatisfy(\.isFinite),
                  let isSRGB = json["srgb"]?.boolValue else {
                throw RigError.invalid("A map material's emission is incomplete.")
            }
            if let number = json["image"], number != .null {
                guard let index = number.doubleValue.flatMap({ Int(exactly: $0) }), index >= 0 else {
                    throw RigError.invalid("A map material's emission image is not an index.")
                }
                image = index
            }
            emission = Float3(Float(rgb[0]), Float(rgb[1]), Float(rgb[2]))
            srgb = isSRGB
        }
        return SourceStudioStandardInputs(albedo: Float4(Float(color[0]), Float(color[1]), Float(color[2]), Float(color[3])),
                                          oneMinusReflectivity: Float(reflectivity), emissionColor: emission, emissionImage: image,
                                          emissionSRGB: srgb)
    }
}

/// `MaterialKindMap`: the Standard baked-lightmap subset `map_fragment` draws.
public enum SourceStudioMapMaterial {
    public static func make(_ material: MaterialData, standard: SourceStudioStandardInputs, base: TextureHandle?,
                            emission: TextureHandle?, lightmap: TextureHandle, direction: TextureHandle?,
                            range: Float, exponent: Float) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindMap))
        m.uniforms.flags = MaterialFlagNoOutline.rawValue
        m.uniforms.baseColor = standard.albedo
        m.base = base
        m.setFlag(MaterialFlagHasBaseTexture, base != nil)
        m.lightmap = lightmap
        m.lightmapDirection = direction
        m.setFlag(MaterialFlagMapDirectionalLightmap, direction != nil)
        m.uniforms.lightmapRange = range
        m.uniforms.lightmapExponent = exponent
        m.uniforms.oneMinusReflectivity = standard.oneMinusReflectivity
        // Without an emission texture the renderer binds white (Unity's default).
        if let color = standard.emissionColor {
            m.emission = emission
            m.uniforms.emissive = Float4(color.x, color.y, color.z, 1)
        } else {
            m.uniforms.emissive = .zero
        }
        // glTF alpha modes as the converter wrote them (Standard _Mode).
        m.setFlag(MaterialFlagDoubleSided, material.doubleSided)
        m.setFlag(MaterialFlagAlphaTest, material.alphaMode == "MASK")
        m.setFlag(MaterialFlagAlphaBlend, material.alphaMode == "BLEND")
        m.transparent = material.alphaMode == "BLEND"
        if material.alphaMode == "MASK" { m.uniforms.params.w = material.alphaCutoff }
        return m
    }
}
