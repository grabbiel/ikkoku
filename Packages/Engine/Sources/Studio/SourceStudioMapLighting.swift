import Foundation
import simd
import CoreMath
import Assets
import Scene
import Character
import Renderer
import ShaderTypes

// ST-A11 maps, slice 5: a converted map's realtime sun and RenderSettings
// ambient, drawn the way Unity 5.6.2f1's Standard shader lights a map renderer
// in the original player (ForwardBase, Linear colour space, D3D11;
// docs/reference/studio/maps.md, "Lighting (slice 5)").
//
// Built-in shader sources, tag v5.6.2f1:
// - BRDF1_Unity_PBS (UnityStandardBRDF.cginc): diffColor * (gi.diffuse +
//   light.color * diffuseTerm) + the two specular terms (not drawn), with
//   diffuseTerm = DisneyDiffuse(nv, nl, lh, perceptualRoughness) * nl,
//   perceptualRoughness = 1 - smoothness, nv = abs(dot(n, v)),
//   halfDir = Unity_SafeNormalize(l + v) = x * rsqrt(max(0.001, dot(x, x))).
// - DisneyDiffuse: fd90 = 0.5 + 2 * lh^2 * perceptualRoughness;
//   (1 + (fd90 - 1) * Pow5(1 - nl)) * (1 + (fd90 - 1) * Pow5(1 - nv)), no 1/pi.
// - ShadeSH9 (UnityCG.cginc): dot(unity_SHA*, (n, 1)) + dot(unity_SHB*, n.xyzz * n.yzzx)
//   + unity_SHC.rgb * (n.x^2 - n.y^2). Unity adds the L2 band per vertex and
//   L0/L1 per pixel; here the whole sum is per pixel. max(0) as in
//   ShadeSHPerPixel.
// - LightingLambert (Lighting.cginc), Legacy Shaders/Diffuse:
//   albedo * light.color * max(0, dot(n, l)) + albedo * gi.indirect.diffuse.
// - _LightColor0 is set by the engine: colour * intensity converted with
//   GammaToLinearSpace (the player's lightsUseLinearIntensity is off), the
//   exact curve (pow 2.2 at and above 1). Shadow attenuation is
//   lerp(1 - strength, 1, visibility) (_LightShadowData.r = 1 - strength).
// No map has light probes (0 in all 40), so a Standard renderer without a
// lightmap reads RenderSettings' ambient probe: SH9 of the serialized
// m_AmbientProbe in Skybox mode, the linearised sky colour * intensity in Flat
// mode (the serialized probe is stale there). The offline checks against the
// slice-4 oracle are in maps.md.

/// The CPU mirror of `map_fragment`'s slice-5 terms (Shaders/Toon.metal), for
/// tests and tools.
public enum SourceStudioMapLightingMath {
    /// `_LightColor0`: GammaToLinearSpace(colour.rgb * intensity), exact curve.
    public static func sunColor(_ color: Float3, intensity: Float) -> Float3 {
        let c = color * intensity
        return Float3(SourceStudioLightmapMath.gammaToLinearExact(c.x), SourceStudioLightmapMath.gammaToLinearExact(c.y),
                      SourceStudioLightmapMath.gammaToLinearExact(c.z))
    }

    /// `DisneyDiffuse` (UnityStandardBRDF.cginc).
    public static func disneyDiffuse(nv: Float, nl: Float, lh: Float, perceptualRoughness: Float) -> Float {
        let fd90 = 0.5 + 2 * lh * lh * perceptualRoughness
        let lightScatter = 1 + (fd90 - 1) * powf(1 - nl, 5)
        let viewScatter = 1 + (fd90 - 1) * powf(1 - nv, 5)
        return lightScatter * viewScatter
    }

    /// BRDF1's `diffuseTerm` for unit `normal`, `view` (to the eye) and
    /// `light` (to the light); LightingLambert's max(0, n.l) when `lambert`.
    public static func sunDiffuseTerm(normal n: Float3, view v: Float3, light l: Float3, smoothness: Float, lambert: Bool) -> Float {
        let nl = simd_clamp(simd_dot(n, l), 0, 1)
        if lambert { return nl }
        let hv = l + v
        let h = hv / sqrtf(max(0.001, simd_dot(hv, hv)))
        let nv = abs(simd_dot(n, v))
        let lh = simd_clamp(simd_dot(l, h), 0, 1)
        return disneyDiffuse(nv: nv, nl: nl, lh: lh, perceptualRoughness: 1 - smoothness) * nl
    }

    /// `light.color`'s attenuation for a shadow-map `visibility` (1 = lit).
    public static func shadowAttenuation(visibility: Float, strength: Float) -> Float {
        1 + (visibility - 1) * strength
    }

    /// Unity's seven SH constants (unity_SHAr, SHAg, SHAb, SHBr, SHBg, SHBb,
    /// SHC) from a serialized `m_AmbientProbe` (27 floats: red 0-8, green
    /// 9-17, blue 18-26), in Unity's basis: SHA = (c3, c1, c2, c0 - c6),
    /// SHB = (c4, c5, 3 c6, c7), SHC = c8 per colour.
    public static func unitySH(_ probe: [Float]) -> [Float4] {
        precondition(probe.count == 27, "m_AmbientProbe has 27 coefficients")
        func c(_ channel: Int, _ k: Int) -> Float { probe[channel * 9 + k] }
        let a = (0..<3).map { Float4(c($0, 3), c($0, 1), c($0, 2), c($0, 0) - c($0, 6)) }
        let b = (0..<3).map { Float4(c($0, 4), c($0, 5), 3 * c($0, 6), c($0, 7)) }
        return a + b + [Float4(c(0, 8), c(1, 8), c(2, 8), 0)]
    }

    /// The same constants for an engine-basis normal: the engine reflects
    /// Unity's z, which negates the z, yz and zx terms.
    public static func engineSH(_ probe: [Float]) -> [Float4] {
        let unity = unitySH(probe)
        return unity.enumerated().map { index, v in
            switch index {
            case 0...2: return Float4(v.x, v.y, -v.z, v.w)
            case 3...5: return Float4(v.x, -v.y, v.z, -v.w)
            default: return v
            }
        }
    }

    /// Flat ambient: the colour alone in the constant terms.
    public static func flatSH(_ color: Float3) -> [Float4] {
        [Float4(0, 0, 0, color.x), Float4(0, 0, 0, color.y), Float4(0, 0, 0, color.z)] + Array(repeating: .zero, count: 4)
    }

    /// ShadeSH9 of seven constants at a unit normal in their basis, max 0.
    public static func shadeSH9(_ sh: [Float4], normal n: Float3) -> Float3 {
        let n1 = Float4(n.x, n.y, n.z, 1)
        let vB = Float4(n.x * n.y, n.y * n.z, n.z * n.z, n.z * n.x)
        let vC = n.x * n.x - n.y * n.y
        let x1 = Float3(simd_dot(sh[0], n1), simd_dot(sh[1], n1), simd_dot(sh[2], n1))
        let x2 = Float3(simd_dot(sh[3], vB), simd_dot(sh[4], vB), simd_dot(sh[5], vB))
        let shc = Float3(sh[6].x, sh[6].y, sh[6].z)
        return simd_max(.zero, x1 + x2 + shc * vC)
    }
}

/// A converted map's `ikkokuMapLighting` scene extras (slice 5 exports): the
/// RenderSettings ambient and the realtime sun with its per-sun-type state.
public struct SourceStudioMapLightingData: Sendable, Equatable {
    public enum AmbientMode: String, Sendable { case skybox, flat }

    /// One sun type's state (`SunLightInfo.Set`, or the authored light for
    /// a type without an entry).
    public struct SunState: Sendable, Equatable {
        /// The light's colour as serialized (gamma) and its intensity.
        public let color: Float3
        public let intensity: Float
        /// Unit direction to the light, engine basis, in the sun's role frame.
        public let directionToLight: Float3
    }

    public struct Sun: Sendable, Equatable {
        /// `mapRoot`: the direction turns with the record's map transform.
        public let role: SourceStudioMapAsset.Role
        /// The sun-type keys the light is shown for.
        public let visibleFor: Set<Int32>
        public let cullingMask: UInt32
        /// "none", "hard" or "soft" (LightShadows).
        public let shadowType: String
        public let shadowStrength: Float
        public let shadowBias: Float
        public let shadowNormalBias: Float
        public let shadowNearPlane: Float
        public let bySunType: [Int32: SunState]
    }

    public let ambientMode: AmbientMode
    public let ambientIntensity: Float
    /// The ambient as Unity's seven SH constants in the engine basis.
    public let ambient: [Float4]
    public let sun: Sun?

    /// nil for an export without the extras (before slice 5). Trilight
    /// ambient (no map uses it) and a malformed record are refused by name.
    public static func parse(_ extras: JSONValue?, label: String) throws -> SourceStudioMapLightingData? {
        guard let value = extras?["ikkokuMapLighting"] else { return nil }
        func fail(_ reason: String) -> Error { RigError.invalid("\(label) map lighting: \(reason).") }
        guard value["kind"]?.stringValue == "ikkoku.mapLighting", value["version"]?.doubleValue == 1 else {
            throw fail("not an ikkoku.mapLighting version 1 record")
        }
        func floats(_ json: JSONValue?, _ count: Int, _ what: String) throws -> [Float] {
            guard let array = json?.arrayValue, array.count == count else { throw fail("\(what) is not \(count) numbers") }
            let numbers = array.compactMap(\.doubleValue)
            guard numbers.count == count, numbers.allSatisfy(\.isFinite) else { throw fail("\(what) is not \(count) finite numbers") }
            return numbers.map { Float($0) }
        }
        func number(_ json: JSONValue?, _ what: String) throws -> Float {
            guard let n = json?.doubleValue, n.isFinite else { throw fail("\(what) is not a finite number") }
            return Float(n)
        }
        guard let ambient = value["ambient"] else { throw fail("no ambient") }
        let modeName = ambient["mode"]?.stringValue ?? "?"
        guard let mode = AmbientMode(rawValue: modeName) else {
            throw fail("ambient mode \(modeName) is not drawn (only skybox and flat)")
        }
        let intensity = try number(ambient["intensity"], "ambient intensity")
        let sh: [Float4]
        switch mode {
        case .skybox:
            sh = SourceStudioMapLightingMath.engineSH(try floats(ambient["probe"], 27, "the ambient probe"))
        case .flat:
            let sky = try floats(ambient["skyColor"], 4, "the ambient sky colour")
            let linear = Float3(SourceStudioLightmapMath.gammaToLinearExact(sky[0]), SourceStudioLightmapMath.gammaToLinearExact(sky[1]),
                                SourceStudioLightmapMath.gammaToLinearExact(sky[2]))
            sh = SourceStudioMapLightingMath.flatSH(linear * intensity)
        }
        var sun: Sun?
        if let json = value["sun"], json != .null {
            guard let roleName = json["role"]?.stringValue, let role = SourceStudioMapAsset.Role(rawValue: roleName) else {
                throw fail("the sun has no role")
            }
            var keys = Set<Int32>()
            for key in json["visibleFor"]?.arrayValue ?? [] {
                guard let n = key.doubleValue, let k = Int32(exactly: n), (-1...2).contains(k) else { throw fail("the sun has an invalid sun-type key") }
                keys.insert(k)
            }
            guard let maskValue = json["cullingMask"]?.doubleValue, let mask = UInt32(exactly: maskValue) else {
                throw fail("the sun has no culling mask")
            }
            guard let shadows = json["shadows"], let type = shadows["type"]?.stringValue, ["none", "hard", "soft"].contains(type) else {
                throw fail("the sun's shadow type is not none, hard or soft")
            }
            let strength = try number(shadows["strength"], "the sun's shadow strength")
            guard (0...1).contains(strength) else { throw fail("the sun's shadow strength is outside 0...1") }
            var states: [Int32: SunState] = [:]
            for key in keys {
                guard let entry = json["bySunType"]?[String(key)] else { throw fail("the sun has no state for sun type \(key)") }
                let color = try floats(entry["color"], 4, "the sun colour")
                let direction = try floats(entry["directionToLight"], 3, "the sun direction")
                let d = Float3(direction[0], direction[1], direction[2])
                guard abs(simd_length(d) - 1) < 1e-3 else { throw fail("the sun direction for type \(key) is not a unit vector") }
                states[key] = SunState(color: Float3(color[0], color[1], color[2]), intensity: try number(entry["intensity"], "the sun intensity"),
                                       directionToLight: simd_normalize(d))
            }
            sun = Sun(role: role, visibleFor: keys, cullingMask: mask, shadowType: type, shadowStrength: strength,
                      shadowBias: try number(shadows["bias"], "the shadow bias"),
                      shadowNormalBias: try number(shadows["normalBias"], "the shadow normal bias"),
                      shadowNearPlane: try number(shadows["nearPlane"], "the shadow near plane"), bySunType: states)
        }
        return SourceStudioMapLightingData(ambientMode: mode, ambientIntensity: intensity, ambient: sh, sun: sun)
    }

    /// The frame's map lighting for a record: the ambient, and the sun of
    /// its sun type (`SourceStudioMapPlacement.sunTypeKey`) turned by the map
    /// root when it hangs under "Map". No sun when the type does not show it.
    public func frame(mapRoot: float4x4, sunTypeKey key: Int32) -> MapLighting {
        guard let sun, sun.visibleFor.contains(key), let state = sun.bySunType[key] else { return MapLighting(sh: ambient, sun: nil) }
        let direction = sun.role == .mapRoot ? simd_normalize(mapRoot.upperLeft3x3 * state.directionToLight) : state.directionToLight
        let strength = sun.shadowType == "none" ? 0 : sun.shadowStrength
        return MapLighting(sh: ambient, sun: MapLighting.Sun(directionToLight: direction,
            color: SourceStudioMapLightingMath.sunColor(state.color, intensity: state.intensity), shadowStrength: strength))
    }
}
