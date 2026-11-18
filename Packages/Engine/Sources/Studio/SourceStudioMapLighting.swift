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
// Built-in shader sources, Unity 5.6.2f1 (CGIncludes):
// - BRDF1_Unity_PBS (UnityStandardBRDF.cginc), the desktop BRDF (UNITY_BRDF_GGX 1):
//     diffColor * (gi.diffuse + light.color * diffuseTerm)
//     + specularTerm * light.color * FresnelTerm(specColor, lh)
//     + surfaceReduction * gi.specular * FresnelLerp(...)        (indirect: not drawn)
//   diffuseTerm = DisneyDiffuse(nv, nl, lh, perceptualRoughness) * nl,
//   perceptualRoughness = 1 - smoothness, roughness = perceptualRoughness^2,
//   nv = abs(dot(n, v)), nl = saturate(dot(n, l)), nh = saturate(dot(n, h)),
//   lh = saturate(dot(l, h)), h = Unity_SafeNormalize(l + v) = x * rsqrt(max(0.001, dot(x, x))),
//   specularTerm = max(0, SmithJointGGXVisibilityTerm(nl, nv, roughness) * GGXTerm(nh, roughness) * pi * nl),
//   0 under _SPECULARHIGHLIGHTS_OFF or when specColor is black.
// - DisneyDiffuse: fd90 = 0.5 + 2 lh^2 perceptualRoughness;
//   (1 + (fd90 - 1) Pow5(1 - nl)) (1 + (fd90 - 1) Pow5(1 - nv)), no 1/pi.
// - SmithJointGGXVisibilityTerm (the approximation): lambdaV = nl (nv (1 - a) + a),
//   lambdaL = nv (nl (1 - a) + a), 0.5 / (lambdaV + lambdaL + 1e-5).
// - GGXTerm: d = (nh a2 - nh) nh + 1, a2 / pi / (d^2 + 1e-7).
// - FresnelTerm(F0, cosA) = F0 + (1 - F0) Pow5(1 - cosA).
// - DiffuseAndSpecularFromMetallic (UnityStandardUtils.cginc): specColor =
//   lerp(0.04, albedo, metallic), oneMinusReflectivity = 0.96 - 0.96 metallic,
//   so metallic = 1 - oneMinusReflectivity / 0.96.
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
// - The caster's normal offset (UnityClipSpaceShadowCasterPos, UnityCG.cginc):
//   wPos -= wNormal * normalBias * sqrt(1 - cos^2(n, l)), unity_LightShadowBias.z
//   being the light's normal bias times the shadow map's world texel size.
// No map has light probes (none of the 42 map scenes), so a Standard renderer without a
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

    static func pow5(_ x: Float) -> Float { x * x * x * x * x }

    /// `DisneyDiffuse` (UnityStandardBRDF.cginc).
    public static func disneyDiffuse(nv: Float, nl: Float, lh: Float, perceptualRoughness: Float) -> Float {
        let fd90 = 0.5 + 2 * lh * lh * perceptualRoughness
        let lightScatter = 1 + (fd90 - 1) * pow5(1 - nl)
        let viewScatter = 1 + (fd90 - 1) * pow5(1 - nv)
        return lightScatter * viewScatter
    }

    /// `SmithJointGGXVisibilityTerm`, the approximation Unity 5.6 compiles.
    public static func smithJointGGXVisibility(nl: Float, nv: Float, roughness a: Float) -> Float {
        let lambdaV = nl * (nv * (1 - a) + a)
        let lambdaL = nv * (nl * (1 - a) + a)
        return 0.5 / (lambdaV + lambdaL + 1e-5)
    }

    /// `GGXTerm`.
    public static func ggx(nh: Float, roughness: Float) -> Float {
        let a2 = roughness * roughness
        let d = (nh * a2 - nh) * nh + 1
        return (1 / Float.pi) * a2 / (d * d + 1e-7)
    }

    /// The angles BRDF1 reads, for unit `n`, `v` (to the eye) and `l` (to the light).
    public struct Angles: Sendable { public let nv, nl, nh, lh: Float }
    public static func angles(normal n: Float3, view v: Float3, light l: Float3) -> Angles {
        let hv = l + v
        let h = hv / sqrtf(max(0.001, simd_dot(hv, hv)))
        return Angles(nv: abs(simd_dot(n, v)), nl: simd_clamp(simd_dot(n, l), 0, 1), nh: simd_clamp(simd_dot(n, h), 0, 1),
                      lh: simd_clamp(simd_dot(l, h), 0, 1))
    }

    /// BRDF1's `diffuseTerm`, or LightingLambert's max(0, n.l) when `lambert`.
    public static func sunDiffuseTerm(normal n: Float3, view v: Float3, light l: Float3, smoothness: Float, lambert: Bool) -> Float {
        let a = angles(normal: n, view: v, light: l)
        if lambert { return a.nl }
        return disneyDiffuse(nv: a.nv, nl: a.nl, lh: a.lh, perceptualRoughness: 1 - smoothness) * a.nl
    }

    /// BRDF1's `specularTerm` (before `FresnelTerm`), 0 when the highlights are off.
    public static func sunSpecularTerm(normal n: Float3, view v: Float3, light l: Float3, smoothness: Float, highlights: Bool) -> Float {
        guard highlights else { return 0 }
        let a = angles(normal: n, view: v, light: l)
        let perceptual = 1 - smoothness
        let roughness = perceptual * perceptual
        let term = smithJointGGXVisibility(nl: a.nl, nv: a.nv, roughness: roughness) * ggx(nh: a.nh, roughness: roughness) * .pi
        return max(0, term * a.nl)
    }

    /// `FresnelTerm`.
    public static func fresnel(_ f0: Float3, cosA: Float) -> Float3 { f0 + (Float3(repeating: 1) - f0) * pow5(1 - cosA) }

    /// `DiffuseAndSpecularFromMetallic`'s specColor, with metallic recovered
    /// from the material's oneMinusReflectivity.
    public static func specColor(albedo: Float3, oneMinusReflectivity: Float) -> Float3 {
        let metallic = 1 - oneMinusReflectivity / SourceStudioLightmapMath.oneMinusDielectricSpec
        return simd_mix(Float3(repeating: 0.04), albedo, Float3(repeating: metallic))
    }

    /// The sun's contribution to one pixel of a Standard map draw:
    /// `diffColor * light * diffuseTerm + specularTerm * light * Fresnel(specColor, lh)`,
    /// light = `sunColor * attenuation`. `albedo` is the sampled albedo
    /// (texture × `_Color`); Legacy Diffuse (`lambert`) has no specular term.
    public static func sunRadiance(albedo: Float3, oneMinusReflectivity: Float, smoothness: Float, highlights: Bool, lambert: Bool,
                                   normal n: Float3, view v: Float3, light l: Float3, sunColor: Float3, attenuation: Float) -> Float3 {
        let light = sunColor * attenuation
        let diffColor = albedo * oneMinusReflectivity
        let diffuse = diffColor * light * sunDiffuseTerm(normal: n, view: v, light: l, smoothness: smoothness, lambert: lambert)
        guard !lambert else { return diffuse }
        let spec = specColor(albedo: albedo, oneMinusReflectivity: oneMinusReflectivity)
        guard spec != .zero else { return diffuse }
        let term = sunSpecularTerm(normal: n, view: v, light: l, smoothness: smoothness, highlights: highlights)
        return diffuse + term * light * fresnel(spec, cosA: angles(normal: n, view: v, light: l).lh)
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

/// A lit map mesh's `ikkokuMap.shadowRuns` (slice 5 exports): how each
/// renderer's triangles meet the sun. The runs cover the mesh's indices in order.
public enum SourceStudioMapShadowRuns {
    public struct Run: Sendable, Equatable {
        public let first: Int
        public let count: Int
        /// Renderer.shadowCastingMode: 0 off, 1 on, 2 two-sided (3, shadows
        /// only, never reaches a drawn mesh).
        public let castMode: Int
        public let receives: Bool
        /// The renderer's layer is in the sun's culling mask: the sun lights
        /// and shadows only those.
        public let inSunMask: Bool
        public init(first: Int, count: Int, castMode: Int, receives: Bool, inSunMask: Bool) {
            self.first = first; self.count = count; self.castMode = castMode; self.receives = receives; self.inSunMask = inSunMask
        }
        public var casts: Bool { inSunMask && castMode != 0 }
    }

    /// nil for a mesh without runs. Refuses runs that do not cover `indexCount`
    /// in order, split a triangle, or carry another cast mode.
    public static func parse(_ json: JSONValue?, indexCount: Int, label: String) throws -> [Run]? {
        guard let json, json != .null else { return nil }
        func fail(_ reason: String) -> Error { RigError.invalid("\(label) shadow runs: \(reason).") }
        guard let entries = json.arrayValue, !entries.isEmpty else { throw fail("not a list of runs") }
        var runs: [Run] = []
        var next = 0
        for entry in entries {
            guard let fields = entry.arrayValue, fields.count == 5,
                  let first = fields[0].doubleValue.flatMap({ Int(exactly: $0) }), let count = fields[1].doubleValue.flatMap({ Int(exactly: $0) }),
                  let mode = fields[2].doubleValue.flatMap({ Int(exactly: $0) }), let receives = fields[3].boolValue,
                  let inMask = fields[4].boolValue else {
                throw fail("a run is not [first, count, cast mode, receives, in the sun's mask]")
            }
            guard first == next, count > 0, count % 3 == 0 else { throw fail("the runs do not cover the indices in whole triangles") }
            guard (0...2).contains(mode) else { throw fail("cast mode \(mode) is not off, on or two-sided") }
            runs.append(Run(first: first, count: count, castMode: mode, receives: receives, inSunMask: inMask))
            next = first + count
        }
        guard next == indexCount else { throw fail("the runs cover \(next) of \(indexCount) indices") }
        return runs
    }

    /// One byte per vertex (1 = receives) for a mesh whose runs mix the receive
    /// flag, so one draw needs no split: `toon_vertex` passes it [[flat]], so
    /// every vertex of a triangle must carry its run's value. nil, with the
    /// number of vertices that runs of both values share, when that does not
    /// hold (the caller then draws the mesh receiving nothing).
    public static func vertexReceive(runs: [Run], indices: UnsafeBufferPointer<UInt32>, vertexCount: Int) -> (bytes: [UInt8]?, conflicts: Int) {
        // 0 = unused, 1 = receives, 2 = does not, 3 = both.
        var state = [UInt8](repeating: 0, count: vertexCount)
        for run in runs {
            let bit: UInt8 = run.receives ? 1 : 2
            for k in run.first..<(run.first + run.count) {
                let v = Int(indices[k])
                guard v < vertexCount else { return (nil, -1) }
                state[v] |= bit
            }
        }
        let conflicts = state.reduce(0) { $0 + ($1 == 3 ? 1 : 0) }
        guard conflicts == 0 else { return (nil, conflicts) }
        return (state.map { $0 == 1 ? 1 : 0 }, 0)
    }

    /// The runs that cast, merged where they touch with the same cull mode:
    /// (first, count, two-sided).
    public static func casterRuns(_ runs: [Run]) -> [(first: Int, count: Int, twoSided: Bool)] {
        var out: [(first: Int, count: Int, twoSided: Bool)] = []
        for run in runs where run.casts {
            let twoSided = run.castMode == 2
            if let last = out.last, last.first + last.count == run.first, last.twoSided == twoSided {
                out[out.count - 1].count += run.count
            } else {
                out.append((run.first, run.count, twoSided))
            }
        }
        return out
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
        /// Whether the sun draws a shadow map at all.
        public var casts: Bool { shadowType != "none" && shadowStrength > 0 }
    }

    /// One `shadowCasters` group: ShadowsOnly renderers in the sun's mask,
    /// merged per role, visibility and option (positions and indices accessors).
    public struct CasterGroup: Sendable, Equatable {
        public let role: SourceStudioMapAsset.Role
        public let visibleFor: Set<Int32>
        public let option: Bool
        public let positions: Int
        public let indices: Int
        public let triangles: Int
    }

    public let ambientMode: AmbientMode
    public let ambientIntensity: Float
    /// The ambient as Unity's seven SH constants in the engine basis.
    public let ambient: [Float4]
    public let sun: Sun?
    public let casterGroups: [CasterGroup]

    /// The accessors the shadow-only casters name, for the glTF loader
    /// (`GLBLoader.load(url:packageRoot:accessors:)`). Malformed entries are
    /// left to `parse`, which refuses them.
    public static func casterAccessors(_ extras: JSONValue?) -> Set<Int> {
        var out = Set<Int>()
        for group in extras?["ikkokuMapLighting"]?["shadowCasters"]?.arrayValue ?? [] {
            for key in ["positions", "indices"] {
                if let n = group[key]?.doubleValue, let index = Int(exactly: n), index >= 0 { out.insert(index) }
            }
        }
        return out
    }

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
        func keys(_ json: JSONValue?, _ what: String) throws -> Set<Int32> {
            var out = Set<Int32>()
            for key in json?.arrayValue ?? [] {
                guard let n = key.doubleValue, let k = Int32(exactly: n), (-1...2).contains(k) else { throw fail("\(what) has an invalid sun-type key") }
                out.insert(k)
            }
            return out
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
            let visible = try keys(json["visibleFor"], "the sun")
            guard let maskValue = json["cullingMask"]?.doubleValue, let mask = UInt32(exactly: maskValue) else {
                throw fail("the sun has no culling mask")
            }
            guard let shadows = json["shadows"], let type = shadows["type"]?.stringValue, ["none", "hard", "soft"].contains(type) else {
                throw fail("the sun's shadow type is not none, hard or soft")
            }
            let strength = try number(shadows["strength"], "the sun's shadow strength")
            guard (0...1).contains(strength) else { throw fail("the sun's shadow strength is outside 0...1") }
            var states: [Int32: SunState] = [:]
            for key in visible {
                guard let entry = json["bySunType"]?[String(key)] else { throw fail("the sun has no state for sun type \(key)") }
                let color = try floats(entry["color"], 4, "the sun colour")
                let direction = try floats(entry["directionToLight"], 3, "the sun direction")
                let d = Float3(direction[0], direction[1], direction[2])
                guard abs(simd_length(d) - 1) < 1e-3 else { throw fail("the sun direction for type \(key) is not a unit vector") }
                states[key] = SunState(color: Float3(color[0], color[1], color[2]), intensity: try number(entry["intensity"], "the sun intensity"),
                                       directionToLight: simd_normalize(d))
            }
            sun = Sun(role: role, visibleFor: visible, cullingMask: mask, shadowType: type, shadowStrength: strength,
                      shadowBias: try number(shadows["bias"], "the shadow bias"),
                      shadowNormalBias: try number(shadows["normalBias"], "the shadow normal bias"),
                      shadowNearPlane: try number(shadows["nearPlane"], "the shadow near plane"), bySunType: states)
        }
        var groups: [CasterGroup] = []
        for json in value["shadowCasters"]?.arrayValue ?? [] {
            guard sun != nil else { throw fail("shadow casters without a sun") }
            guard let roleName = json["role"]?.stringValue, let role = SourceStudioMapAsset.Role(rawValue: roleName),
                  let positions = json["positions"]?.doubleValue.flatMap({ Int(exactly: $0) }),
                  let indices = json["indices"]?.doubleValue.flatMap({ Int(exactly: $0) }),
                  let triangles = json["triangles"]?.doubleValue.flatMap({ Int(exactly: $0) }) else {
                throw fail("a shadow caster group lacks its role, accessors or triangle count")
            }
            groups.append(CasterGroup(role: role, visibleFor: try keys(json["visibleFor"], "a shadow caster group"),
                                      option: json["option"]?.boolValue == true, positions: positions, indices: indices, triangles: triangles))
        }
        return SourceStudioMapLightingData(ambientMode: mode, ambientIntensity: intensity, ambient: sh, sun: sun, casterGroups: groups)
    }

    /// The frame's ambient and sun for a record: the sun of its sun type
    /// (`SourceStudioMapPlacement.sunTypeKey`) turned by the map root when it
    /// hangs under "Map". No sun when the type does not show it. Casters are
    /// the asset's (`SourceStudioMapAsset.lighting`).
    public func frame(mapRoot: float4x4, sunTypeKey key: Int32) -> MapLighting {
        guard let sun, sun.visibleFor.contains(key), let state = sun.bySunType[key] else { return MapLighting(sh: ambient, sun: nil) }
        let direction = sun.role == .mapRoot ? simd_normalize(mapRoot.upperLeft3x3 * state.directionToLight) : state.directionToLight
        let strength = sun.casts ? sun.shadowStrength : 0
        return MapLighting(sh: ambient, sun: MapLighting.Sun(directionToLight: direction,
            color: SourceStudioMapLightingMath.sunColor(state.color, intensity: state.intensity), shadowStrength: strength,
            shadowBias: sun.shadowBias, shadowNormalBias: sun.shadowNormalBias))
    }
}
