import Foundation
import Metal
import CoreGraphics
import simd
import CoreMath
import Assets
import Scene
import ShaderTypes

/// Validation-only boundary for a controlled original-player capture. Geometry
/// is the ORIGINAL evaluated pose, not a claim of native rig/animation parity.
public struct OriginalFrameProbe {
    public let width: Int, height: Int
    public let frame: RenderFrame
    public let sourceMeshCount: Int
    public let materialDiagnostics: [String]
    public let sourceFar: Float

    public enum ProbeError: Error { case invalid(String), gpu(String) }

    public static func load(url: URL, resources: ResourceStore) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              (root["schemaVersion"] as? Int) == 1,
              let width = root["width"] as? Int, let height = root["height"] as? Int,
              (1...4096).contains(width), (1...4096).contains(height),
              let sourceMeshes = root["meshes"] as? [[String: Any]], (1...512).contains(sourceMeshes.count),
              let camera = root["camera"] as? [String: Any], let light = root["light"] as? [String: Any] else {
            throw ProbeError.invalid("Unsupported or incomplete original frame descriptor")
        }
        let folder = url.deletingLastPathComponent()
        guard let textureRows = root["textures"] as? [[String: Any]] else { throw ProbeError.invalid("Missing texture metadata") }
        var textureMetadata: [String: [String: Any]] = [:]
        for texture in textureRows { guard let name = texture["file"] as? String, textureMetadata[name] == nil else { throw ProbeError.invalid("Ambiguous texture metadata") }; textureMetadata[name] = texture }
        func file(_ name: String) throws -> URL {
            guard name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else { throw ProbeError.invalid("Unsafe fixture filename") }
            return folder.appendingPathComponent(name)
        }
        func vector(_ value: Any?, count: Int) throws -> [Float] {
            guard let values = value as? [NSNumber], values.count == count else { throw ProbeError.invalid("Invalid vector") }
            let result = values.map(\.floatValue)
            guard result.allSatisfy(\.isFinite) else { throw ProbeError.invalid("Nonfinite vector") }
            return result
        }
        func v3(_ value: Any?) throws -> Float3 { let v = try vector(value, count: 3); return Float3(v[0], v[1], v[2]) }
        let position = UnityCoordinates.position(try v3(camera["position"]))
        let target = UnityCoordinates.position(try v3(camera["target"]))
        var orbit = OrbitCamera(); orbit.target = target; orbit.distance = length(position - target)
        guard orbit.distance > 0, let fov = (camera["fov"] as? NSNumber)?.floatValue, (1...170).contains(fov),
              let near = (camera["near"] as? NSNumber)?.floatValue, near > 0, let far = (camera["far"] as? NSNumber)?.floatValue, far > near else {
            throw ProbeError.invalid("Invalid camera frustum")
        }
        orbit.fovDegrees = fov; orbit.near = near
        let delta = normalize(position - target); orbit.yaw = atan2(delta.x, delta.z); orbit.pitch = asin(delta.y)
        // Current probe camera has no roll. Validate this contract rather than
        // silently discarding a future arbitrary camera orientation.
        let q = try vector(camera["rotation"], count: 4)
        let up = UnityCoordinates.rotation(simd_quatf(vector: Float4(q))).act(Float3(0, 1, 0))
        guard length(up - Float3(0, 1, 0)) < 0.0001 else { throw ProbeError.invalid("Probe camera roll/pitch is not supported by this fixture version") }
        var main = MainLight(); main.cameraRelative = false; main.castsShadow = false
        let direction = normalize(UnityCoordinates.direction(try v3(light["direction"])))
        // The general renderer currently uses XYZ light Euler; invert that
        // constructor for this exact world-space direction without camera bias.
        main.rotation = Float3(asin(direction.y), atan2(-direction.x, -direction.z), 0) * (180 / .pi)
        let color = try vector(light["color"], count: 4)
        main.color = Float3(color[0], color[1], color[2]); main.intensity = (light["intensity"] as? NSNumber)?.floatValue ?? 1
        var effects = SceneEffects(); effects.showGrid = false; effects.bloomEnabled = false; effects.fxaa = false
        effects.vignetteEnabled = false; effects.saturation = 1; effects.toneMappingEnabled = false
        let background = try vector(root["background"], count: 4)
        effects.backgroundTop = Float3(background[0], background[1], background[2]); effects.backgroundBottom = effects.backgroundTop
        let ambient = try vector(light["ambient"], count: 4)
        effects.ambientSky = Float3(ambient[0], ambient[1], ambient[2]); effects.ambientGround = effects.ambientSky
        var items: [RenderItem] = [], diagnostics: [String] = []; var allPositions: [Float3] = []
        var textureCache: [String: TextureHandle] = [:]
        func linearColor(_ value: Float) -> Float { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        func colorVector(_ value: Any?) throws -> Float4 {
            let color = try vector(value, count: 4); return Float4(linearColor(color[0]), linearColor(color[1]), linearColor(color[2]), color[3])
        }
        func material(_ row: [String: Any]) throws -> MaterialState {
            guard let name = row["name"] as? String, let shader = row["shader"] as? String,
                  let properties = row["properties"] as? [String: Any] else { throw ProbeError.invalid("Missing source material identity") }
            let kind = shader.contains("hair") ? MaterialKindHair : shader.contains("skin") ? MaterialKindSkin : MaterialKindCloth
            var state = MaterialState(uniforms: .make(kind: kind))
            state.uniforms.flags = MaterialFlagNoOutline.rawValue
            state.uniforms.baseColor = Float4(repeating: 1)
            // This baseline uses the existing renderer and reports every source
            // shader as unverified. It must never be presented as a shader port.
            diagnostics.append("\(name): \(shader) uses current native toon baseline; original lighting/stencil/outline contract not verified")
            func texture(_ property: String) throws -> TextureHandle? {
                guard let t = properties[property] as? [String: Any], let name = t["file"] as? String else { return nil }
                if let cached = textureCache[name] { return cached }
                let handle = try loadOriginalProbeTexture(url: file(name), metadata: textureMetadata[name] ?? [:], resources: resources)
                textureCache[name] = handle; return handle
            }
            state.base = try texture("_MainTex"); state.setFlag(MaterialFlagHasBaseTexture, state.base != nil)
            if kind == MaterialKindHair {
                state.colorMask = try texture("_ColorMask"); state.setFlag(MaterialFlagHasColorMask, state.colorMask != nil)
                state.uniforms.tint1 = try colorVector(properties["_Color"])
                state.uniforms.tint2 = try colorVector(properties["_Color2"])
                state.uniforms.tint3 = try colorVector(properties["_Color3"])
            } else if let color = properties["_Color"] { state.uniforms.baseColor = try colorVector(color) }
            state.detail = try texture("_DetailMask"); state.setFlag(MaterialFlagHasDetail, state.detail != nil)
            state.line = try texture("_LineMask"); state.setFlag(MaterialFlagHasLine, state.line != nil)
            state.bodyMask = try texture("_AlphaMask"); state.setFlag(MaterialFlagSourceBodyMask, state.bodyMask != nil); state.setFlag(MaterialFlagHasBodyMask, state.bodyMask != nil)
            state.uniforms.sourceAlphaA = (properties["_alpha_a"] as? NSNumber)?.floatValue ?? 1
            state.uniforms.sourceAlphaB = (properties["_alpha_b"] as? NSNumber)?.floatValue ?? 1
            state.setFlag(MaterialFlagAlphaTest, shader.contains("hair") || shader.contains("eye"))
            state.setFlag(MaterialFlagDoubleSided, (properties["_Cull"] as? NSNumber)?.floatValue == 0)
            return state
        }
        for row in sourceMeshes {
            guard let name = row["name"] as? String, let filename = row["file"] as? String,
                  let materials = row["materials"] as? [[String: Any]] else { throw ProbeError.invalid("Missing source mesh identity") }
            var reader = ProbeBinary(data: try Data(contentsOf: file(filename)))
            let count = try reader.count(max: 1_000_000), submeshes = try reader.count(max: 128)
            guard count > 0, submeshes > 0, materials.count >= submeshes else { throw ProbeError.invalid("Invalid mesh or material count") }
            var p: [Float3] = [], n: [Float3] = [], t: [Float4] = [], uv: [Float2] = [], uv1: [Float2] = [], uv2: [Float2] = [], colors: [Float4] = []
            for _ in 0..<count {
                p.append(UnityCoordinates.position(try reader.float3())); n.append(UnityCoordinates.normal(try reader.float3()))
                t.append(UnityCoordinates.tangent(try reader.float4()))
                for set in 0..<3 {
                    let u = try reader.float(), v = try reader.float(); let value = Float2(u, 1 - v)
                    if set == 0 { uv.append(value) } else if set == 1 { uv1.append(value) } else { uv2.append(value) }
                }
                colors.append(try reader.float4())
            }
            guard allPositions.count + p.count <= 2_000_000 else { throw ProbeError.invalid("Total fixture vertex bound") }
            allPositions += p
            for submesh in 0..<submeshes {
                let indexCount = try reader.count(max: 6_000_000)
                guard indexCount > 0, indexCount.isMultiple(of: 3) else { throw ProbeError.invalid("Invalid triangle count") }
                var indices: [UInt32] = []
                for _ in 0..<indexCount { let index = try reader.uint(); guard index < count else { throw ProbeError.invalid("Out-of-range triangle") }; indices.append(index) }
                let mesh = MeshData(name: "\(name)/\(submesh)", positions: p, normals: n, tangents: t, uvs: uv, uvs1: uv1, uvs2: uv2, colors: colors, indices: try UnityCoordinates.triangleIndices(indices))
                let handle = try resources.register(mesh: mesh, smoothOutlineNormals: false)
                var item = RenderItem(mesh: handle, material: try material(materials[submesh]), model: matrix_identity_float4x4, objectID: UInt32(items.count + 1))
                item.outline = false; item.castsShadow = false
                item.order = (materials[submesh]["queue"] as? Int) ?? 2000
                // This original shader contains only a shadow-caster pass.
                item.visible = (materials[submesh]["shader"] as? String) != "Shader Forge/shadowcast"
                items.append(item)
            }
            guard reader.offset == reader.data.count else { throw ProbeError.invalid("Trailing mesh bytes") }
        }
        let frame = RenderFrame(camera: orbit, mainLight: main, items: items, effects: effects, sceneBounds: .of(points: allPositions))
        return Self(width: width, height: height, frame: frame, sourceMeshCount: sourceMeshes.count, materialDiagnostics: diagnostics, sourceFar: far)
    }
}

private struct ProbeBinary {
    let data: Data; var offset = 0
    mutating func uint() throws -> UInt32 {
        guard offset <= data.count - 4 else { throw OriginalFrameProbe.ProbeError.invalid("Truncated mesh") }
        defer { offset += 4 }; return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    mutating func count(max: Int) throws -> Int { let n = Int(try uint()); guard n <= max else { throw OriginalFrameProbe.ProbeError.invalid("Mesh allocation bound") }; return n }
    mutating func float() throws -> Float { let f = Float(bitPattern: try uint()); guard f.isFinite else { throw OriginalFrameProbe.ProbeError.invalid("Nonfinite mesh value") }; return f }
    mutating func float3() throws -> Float3 { try Float3(float(), float(), float()) }
    mutating func float4() throws -> Float4 { try Float4(float(), float(), float(), float()) }
}
