import Testing
import Foundation
import Metal
import simd
import Assets
import CoreMath
import Character
import Scene
import ShaderTypes
@testable import Studio
@testable import Renderer

// ST-A11 maps, slice 5: the map lighting record and the shadow runs as the
// loader reads them, map_fragment's sun term against an independent float64
// re-implementation of Unity 5.6.2f1's BRDF1_Unity_PBS at smoothness above 0, the
// map sun's shadow map through the renderer, and a converted map with lighting.

// MARK: - Helpers

private func json(_ value: [String: Any]) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
}

private func float16(_ bits: UInt16) -> Float { Float(Float16(bitPattern: bits)) }

/// A `sun` record as the converter writes it (`export_map_scene.py`).
private func sunRecord(role: String = "mapRoot", visibleFor: [Int] = [-1, 0, 1, 2], type: String = "soft", strength: Double = 0.75,
                       direction: [Double] = [1, 0, 0]) -> [String: Any] {
    var states: [String: Any] = [:]
    for key in visibleFor { states[String(key)] = ["color": [0.5, 0.25, 1, 1], "intensity": 1.5, "directionToLight": direction] }
    return ["path": "Map/SunLight", "role": role, "cullingMask": 2048, "visibleFor": visibleFor,
            "shadows": ["type": type, "strength": strength, "bias": 0.05, "normalBias": 0.4, "nearPlane": 0.2],
            "bySunType": states]
}

private func flatAmbient() -> [String: Any] {
    ["mode": "flat", "unityMode": 3, "intensity": 1.0, "skyColor": [0.212, 0.227, 0.259, 1.0]]
}

/// A made-up 27-float ambient probe (nine RGB coefficients) with every sign.
private func testProbe() -> [Float] {
    (0..<27).map { (i: Int) -> Float in
        let a = Float(i % 9) * 0.013
        let b = Float(i / 9) * 0.021
        return a - b + 0.05
    }
}

private func lightingExtras(ambient: [String: Any] = flatAmbient(), sun: Any = NSNull(), casters: [[String: Any]]? = nil) -> [String: Any] {
    var record: [String: Any] = ["kind": "ikkoku.mapLighting", "version": 1, "ambient": ambient, "sun": sun]
    if let casters { record["shadowCasters"] = casters }
    return ["ikkokuMapLighting": record]
}

// MARK: - The lighting record

@Test func mapLightingParsesTheAmbientAndTheSunOfEachSunType() throws {
    #expect(try SourceStudioMapLightingData.parse(try json(["other": 1]), label: "m") == nil)

    // Skybox: Unity's seven constants from m_AmbientProbe, reflected in z.
    let probe = testProbe()
    let skybox = try #require(try SourceStudioMapLightingData.parse(try json(lightingExtras(ambient: [
        "mode": "skybox", "unityMode": 0, "intensity": 1.0, "probe": probe.map(Double.init)])), label: "m"))
    #expect(skybox.ambientMode == .skybox && skybox.ambient == SourceStudioMapLightingMath.engineSH(probe) && skybox.sun == nil)
    // Unity's layout: SHA = (c3, c1, c2, c0 - c6), SHB = (c4, c5, 3 c6, c7), SHC = c8.
    var unit = [Float](repeating: 0, count: 27); unit[6] = 1; unit[9 + 8] = 2
    let constants = SourceStudioMapLightingMath.unitySH(unit)
    #expect(constants[0] == Float4(0, 0, 0, -1) && constants[3] == Float4(0, 0, 3, 0) && constants[6] == Float4(0, 2, 0, 0))
    // The engine constants at an engine normal equal Unity's at the reflected normal.
    for normal in [Float3(0.2, 0.3, 0.9), Float3(-0.6, 0.1, -0.7), Float3(0, -1, 0.05)].map(simd_normalize) {
        let engine = SourceStudioMapLightingMath.shadeSH9(skybox.ambient, normal: normal)
        let unity = SourceStudioMapLightingMath.shadeSH9(SourceStudioMapLightingMath.unitySH(probe), normal: Float3(normal.x, normal.y, -normal.z))
        #expect(simd_length(engine - unity) < 1e-6, "\(normal): \(engine) != \(unity)")
    }

    // Flat: the linearised sky colour times the intensity at every normal (maps 1 and 41: 0.0370, 0.0421, 0.0546).
    let flat = try #require(try SourceStudioMapLightingData.parse(try json(lightingExtras()), label: "m"))
    #expect(flat.ambientMode == .flat)
    for normal in [Float3(0, 1, 0), Float3(0.6, -0.8, 0)] {
        #expect(simd_length(SourceStudioMapLightingMath.shadeSH9(flat.ambient, normal: normal) - Float3(0.0370, 0.0421, 0.0546)) < 1e-4)
    }

    // The sun: its colour is GammaToLinearSpace(colour × intensity); under "Map" it turns with the map.
    let lit = try #require(try SourceStudioMapLightingData.parse(try json(lightingExtras(sun: sunRecord())), label: "m"))
    let sun = try #require(lit.sun)
    #expect(sun.role == .mapRoot && sun.visibleFor == [-1, 0, 1, 2] && sun.cullingMask == 2048 && sun.casts)
    #expect(sun.shadowStrength == 0.75 && sun.shadowBias == 0.05 && sun.shadowNormalBias == 0.4)
    let yaw = float4x4(simd_quatf(angle: .pi / 2, axis: Float3(0, 1, 0)))
    let frame = lit.frame(mapRoot: yaw, sunTypeKey: 0)
    let frameSun = try #require(frame.sun)
    #expect(simd_length(frameSun.directionToLight - Float3(0, 0, -1)) < 1e-6)
    #expect(frameSun.color == SourceStudioMapLightingMath.sunColor(Float3(0.5, 0.25, 1), intensity: 1.5))
    #expect(abs(frameSun.color.x - 0.5225) < 1e-3 && abs(frameSun.color.z - powf(1.5, 2.2)) < 1e-4)
    #expect(frameSun.shadowStrength == 0.75 && frameSun.shadowBias == 0.05 && frameSun.shadowNormalBias == 0.4)
    #expect(frame.sh == lit.ambient && frame.casters.isEmpty)
    // A scene-space sun does not turn; a sun type that does not show it gives no sun; no shadows, strength 0.
    let scene = try #require(try SourceStudioMapLightingData.parse(try json(lightingExtras(sun: sunRecord(role: "scene", visibleFor: [0], type: "none"))), label: "m"))
    #expect(scene.frame(mapRoot: yaw, sunTypeKey: 0).sun?.directionToLight == Float3(1, 0, 0))
    #expect(scene.frame(mapRoot: yaw, sunTypeKey: 0).sun?.shadowStrength == 0 && scene.sun?.casts == false)
    #expect(scene.frame(mapRoot: yaw, sunTypeKey: 1).sun == nil)

    // The caster accessors the loader must decode.
    let casters: [[String: Any]] = [["role": "mapRoot", "visibleFor": [0], "renderers": 1, "triangles": 1, "positions": 7, "indices": 8]]
    #expect(SourceStudioMapLightingData.casterAccessors(try json(lightingExtras(sun: sunRecord(), casters: casters))) == [7, 8])
    #expect(SourceStudioMapLightingData.casterAccessors(try json(["other": 1])).isEmpty)

    // What it cannot draw is refused by name.
    var badSun = sunRecord(); badSun["shadows"] = ["type": "soft", "strength": 1.5, "bias": 0, "normalBias": 0, "nearPlane": 0.1]
    var noState = sunRecord(); noState["bySunType"] = ["0": ["color": [1, 1, 1, 1], "intensity": 1, "directionToLight": [1, 0, 0]]]
    for (extras, reason) in [
        (lightingExtras(ambient: ["mode": "trilight", "intensity": 1.0]), "ambient mode trilight"),
        (lightingExtras(sun: badSun), "strength is outside"),
        (lightingExtras(sun: sunRecord(direction: [1, 1, 0])), "not a unit vector"),
        (lightingExtras(sun: noState), "no state for sun type"),
        (lightingExtras(casters: casters), "shadow casters without a sun"),
        (["ikkokuMapLighting": ["kind": "ikkoku.mapLighting", "version": 2]], "version 1"),
    ] {
        #expect { _ = try SourceStudioMapLightingData.parse(try json(extras), label: "m") } throws: { "\($0)".contains(reason) }
    }
}

// MARK: - The shadow runs

@Test func shadowRunsCoverTheIndicesAndSplitReceiversPerVertex() throws {
    func runs(_ value: [[Any]], _ count: Int) throws -> [SourceStudioMapShadowRuns.Run]? {
        try SourceStudioMapShadowRuns.parse(try json(["r": value])["r"], indexCount: count, label: "mesh")
    }
    #expect(try SourceStudioMapShadowRuns.parse(nil, indexCount: 3, label: "mesh") == nil)
    let parsed = try #require(try runs([[0, 6, 1, true, true], [6, 6, 0, false, true], [12, 3, 2, true, false]], 15))
    #expect(parsed.map(\.casts) == [true, false, false] && parsed.map(\.receives) == [true, false, true])
    for (value, count, reason) in [([[0, 3, 1, true, true], [6, 3, 1, true, true]], 9, "whole triangles"),
                                   ([[0, 4, 1, true, true]], 4, "whole triangles"),
                                   ([[0, 3, 3, true, true]], 3, "cast mode 3"),
                                   ([[0, 3, 1, true, true]], 6, "cover 3 of 6")] as [([[Any]], Int, String)] {
        #expect { _ = try runs(value, count) } throws: { "\($0)".contains(reason) }
    }

    // Two triangles with no shared vertex: one byte per vertex, the run's receive flag.
    let split = try #require(try runs([[0, 3, 1, true, true], [3, 3, 1, false, true]], 6))
    let disjoint: [UInt32] = [0, 1, 2, 3, 4, 5]
    let bytes = disjoint.withUnsafeBufferPointer { SourceStudioMapShadowRuns.vertexReceive(runs: split, indices: $0, vertexCount: 7) }
    #expect(bytes.bytes == [1, 1, 1, 0, 0, 0, 0] && bytes.conflicts == 0)
    // A vertex both runs use cannot carry one flag: no bytes, and the count.
    let shared: [UInt32] = [0, 1, 2, 2, 1, 3]
    let conflict = shared.withUnsafeBufferPointer { SourceStudioMapShadowRuns.vertexReceive(runs: split, indices: $0, vertexCount: 4) }
    #expect(conflict.bytes == nil && conflict.conflicts == 2)

    // Casting runs: off and out-of-mask runs dropped, touching runs of one cull mode merged.
    let casting = try #require(try runs([[0, 3, 1, true, true], [3, 3, 1, false, true], [6, 3, 2, true, true], [9, 3, 0, true, true],
                                         [12, 3, 1, true, false], [15, 3, 1, true, true]], 18))
    #expect(SourceStudioMapShadowRuns.casterRuns(casting).map { "\($0.first),\($0.count),\($0.twoSided)" } == ["0,6,false", "6,3,true", "15,3,false"])
}

// MARK: - map_fragment's sun term

/// Draws one full-target triangle with `toon_vertex` + `map_fragment` (1×1
/// rgba32Float) at the pixel's world position (0, 0, 0.25), with `normal`
/// and the camera at `eye`.
private func renderSun(_ material: MaterialUniforms, lighting: MapLightingUniforms, normal: Float3, eye: Float3) throws -> Float3 {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let resources = ResourceStore(device: device)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ file: String) throws -> String { try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) }
    let header = try read("Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h")
    let common = try read("Shaders/Common.h").replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "")
    let toon = try read("Shaders/Toon.metal").replacingOccurrences(of: "#include \"Common.h\"", with: "")
    let library = try device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + header + common + toon, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "toon_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "map_fragment")
    descriptor.colorAttachments[0].pixelFormat = .rgba32Float
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    let queue = try #require(device.makeCommandQueue())
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
    targetDescriptor.usage = [.renderTarget, .shaderRead]; targetDescriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: targetDescriptor))
    var frame = FrameUniforms(); frame.viewProjection = matrix_identity_float4x4
    frame.shadowViewProjection = matrix_identity_float4x4; frame.cameraPosition = Float4(eye.x, eye.y, eye.z, 1)
    var draw = DrawUniforms(); draw.model = matrix_identity_float4x4; draw.normalMatrix = matrix_identity_float4x4
    let data = MeshData(name: "sun-probe", positions: [Float3(-1, -1, 0.25), Float3(3, -1, 0.25), Float3(-1, 3, 0.25)],
                        normals: Array(repeating: normal, count: 3), uvs: Array(repeating: Float2(0.5, 0.5), count: 3), indices: [0, 1, 2])
    let handle = try resources.register(mesh: data)
    defer { resources.unregister(mesh: handle) }
    let mesh = try #require(resources.mesh(handle))
    var uniforms = material
    let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
    let command = try #require(queue.makeCommandBuffer())
    let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
    encoder.setRenderPipelineState(pipeline)
    for (buffer, index) in [(mesh.baseVertices, BufferIndexVertices), (mesh.texcoords, BufferIndexTexcoords),
        (mesh.texcoords1, BufferIndexTexcoords1), (mesh.texcoords2, BufferIndexTexcoords2),
        (resources.dummyBuffer, BufferIndexVertexColors), (resources.dummyBuffer, BufferIndexVertexHidden), (resources.dummyBuffer, BufferIndexVertexReceive)] {
        encoder.setVertexBuffer(buffer, offset: 0, index: Int(index.rawValue))
    }
    encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Int(BufferIndexFrameUniforms.rawValue))
    encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
    bindMapLighting(encoder, frame: frame, lighting: lighting, shadow: try mapShadowPlaceholder(device))
    // A bright lightmap and emission that a probe-lit draw may not read.
    encoder.setFragmentTexture(resources.whiteTexture, index: Int(TextureIndexBase.rawValue))
    encoder.setFragmentTexture(resources.whiteTexture, index: Int(TextureIndexLightmap.rawValue))
    encoder.setFragmentTexture(resources.whiteTexture, index: Int(TextureIndexLightmapDirection.rawValue))
    encoder.setFragmentTexture(resources.blackTexture, index: Int(TextureIndexEmission.rawValue))
    encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    try #require(command.status == .completed, "map_fragment draw failed: \(String(describing: command.error))")
    var pixel = [Float](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
    return Float3(pixel[0], pixel[1], pixel[2])
}

/// The reference values are BRDF1_Unity_PBS (UNITY_BRDF_GGX, Linear) and
/// LightingLambert, re-implemented in float64 from the formulas of Unity
/// 5.6.2f1's built-in shader sources (UnityStandardBRDF.cginc,
/// UnityStandardUtils.cginc, Lighting.cginc), independently of the engine's
/// CPU mirror (`.local/sta11d-slice5/tools/brdf1_reference.py`): n = normalize(0.2, 0.3, 1), l = normalize(0.5, 0.6, 0.62), the eye
/// at (-0.4, 0.3, 2) seen from (0, 0, 0.25), albedo (0.5, 0.25, 1), metallic
/// 1/6 (oneMinusReflectivity 0.8), light colour (1.3, 1.1, 0.9), no gi. The
/// original's oracle is at _Glossiness 0 only, so smoothness has no parity
/// check against a capture yet (maps.md, "Engine (slice 5)").
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func mapFragmentDrawsTheSunAsUnitysBRDF1AtSmoothnessAboveZero() throws {
    let reference: [String: Float3] = [
        "standard s0.0 hl1": Float3(0.478148686001901, 0.20672088534167152, 0.6548075005077866),
        "standard s0.0 hl0": Float3(0.4415358010329835, 0.1868036081293392, 0.6113572629687465),
        "standard s0.6 hl1": Float3(0.8538867219975674, 0.41112531159612314, 1.1007065281103827),
        "standard s0.6 hl0": Float3(0.44150031063806944, 0.18678859296226016, 0.6113081224219423),
        "standard s0.9 hl1": Float3(0.44790304849726587, 0.19027380495979482, 0.6189030422594125),
        "standard s0.9 hl0": Float3(0.4414825655819871, 0.18678108543853303, 0.6112835523442899),
        "lambert": Float3(0.5518691109204961, 0.23348308538944063, 0.764126461274533),
    ]
    let n = simd_normalize(Float3(0.2, 0.3, 1)), l = simd_normalize(Float3(0.5, 0.6, 0.62)), eye = Float3(-0.4, 0.3, 2)
    let v = simd_normalize(eye - Float3(0, 0, 0.25))
    let light = Float3(1.3, 1.1, 0.9), albedo = Float3(0.5, 0.25, 1)
    var lighting = Renderer.mapLightingUniforms(MapLighting(sh: Array(repeating: .zero, count: 7),
        sun: MapLighting.Sun(directionToLight: l, color: light, shadowStrength: 0)))
    func material(smoothness: Float?, highlights: Bool, lambert: Bool) -> MaterialState {
        var standard = SourceStudioStandardInputs(albedo: Float4(albedo, 1), oneMinusReflectivity: lambert ? 1 : 0.8, emissionColor: nil,
                                                  emissionImage: nil, emissionSRGB: true)
        standard.smoothness = smoothness; standard.specularHighlights = highlights
        var gltf = MaterialData(name: "map"); gltf.alphaMode = "OPAQUE"
        var m = SourceStudioMapMaterial.make(gltf, standard: standard, base: nil, emission: nil, lightmap: nil, direction: nil,
                                             range: 0, exponent: 0, lambert: lambert)
        m.setFlag(MaterialFlagMapSunLit, true)
        return m
    }
    func close(_ a: Float3, _ b: Float3, _ label: String) {
        #expect(simd_length(a - b) <= 2e-4 * max(1, simd_length(b)), "\(label): \(a) != \(b)")
    }
    for smoothness: Float in [0, 0.6, 0.9] {
        for highlights in [true, false] {
            let key = "standard s\(smoothness == 0 ? "0.0" : String(smoothness)) hl\(highlights ? 1 : 0)"
            let want = try #require(reference[key])
            let m = material(smoothness: smoothness, highlights: highlights, lambert: false)
            #expect(m.uniforms.params.x == smoothness && m.uniforms.flags & MaterialFlagMapProbeLit.rawValue != 0)
            // The engine's CPU mirror and the GPU both match the float64 reference.
            close(SourceStudioMapLightingMath.sunRadiance(albedo: albedo, oneMinusReflectivity: 0.8, smoothness: smoothness, highlights: highlights,
                                                          lambert: false, normal: n, view: v, light: l, sunColor: light, attenuation: 1), want, "CPU \(key)")
            close(try renderSun(m.uniforms, lighting: lighting, normal: n, eye: eye), want, "GPU \(key)")
        }
    }
    // The highlight at smoothness 0.6 is most of the pixel: a missing specular or roughness term cannot pass.
    #expect(try #require(reference["standard s0.6 hl1"]).x > 1.9 * (try #require(reference["standard s0.6 hl0"]).x))
    // Legacy Shaders/Diffuse: albedo × light × n.l, no Disney term or specular.
    let lambert = material(smoothness: nil, highlights: true, lambert: true)
    #expect(lambert.uniforms.flags & MaterialFlagMapSpecularHighlights.rawValue == 0)
    close(try renderSun(lambert.uniforms, lighting: lighting, normal: n, eye: eye), try #require(reference["lambert"]), "GPU lambert")

    // Outside the sun's mask, and with no sun in the frame, only the ambient is drawn.
    var unlit = material(smoothness: 0.6, highlights: true, lambert: false)
    unlit.setFlag(MaterialFlagMapSunLit, false)
    close(try renderSun(unlit.uniforms, lighting: lighting, normal: n, eye: eye), .zero, "not sun-lit")
    let noSun = Renderer.mapLightingUniforms(MapLighting(sh: Array(repeating: .zero, count: 7), sun: nil))
    close(try renderSun(material(smoothness: 0.6, highlights: true, lambert: false).uniforms, lighting: noSun, normal: n, eye: eye), .zero, "no sun")

    // Probe-lit ambient: albedo × oneMinusReflectivity × ShadeSH9, plus the sun.
    let probe = testProbe()
    let sh = SourceStudioMapLightingMath.engineSH(probe)
    lighting = Renderer.mapLightingUniforms(MapLighting(sh: sh, sun: MapLighting.Sun(directionToLight: l, color: light, shadowStrength: 0)))
    let ambient = albedo * 0.8 * SourceStudioMapLightingMath.shadeSH9(sh, normal: n)
    #expect(simd_length(ambient) > 0.01)
    close(try renderSun(material(smoothness: 0.6, highlights: true, lambert: false).uniforms, lighting: lighting, normal: n, eye: eye),
          ambient + (try #require(reference["standard s0.6 hl1"])), "GPU ambient + sun")
}

// MARK: - The map sun's shadow map

/// A receiver filling the view at z = target - 1, lit by a sun along +z
/// (toward the camera). Casters are invisible quads at z = target over the
/// left half (x < target.x): they darken that half by the strength, and cull
/// as Unity's cast modes do.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func mapSunShadowsFallBehindTheCastersByTheStrength() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    var camera = OrbitCamera(); camera.pitch = 0; camera.yaw = 0
    let t = camera.target
    func quad(_ name: String, x0: Float, x1: Float, z: Float, facing: Float = 1) -> MeshData {
        let positions = [Float3(x0, t.y - 50, z), Float3(x1, t.y - 50, z), Float3(x1, t.y + 50, z), Float3(x0, t.y + 50, z)]
        // Counter-clockwise seen from +z when facing +z.
        let indices: [UInt32] = facing > 0 ? [0, 1, 2, 0, 2, 3] : [0, 2, 1, 0, 3, 2]
        return MeshData(name: name, positions: positions, normals: Array(repeating: Float3(0, 0, facing), count: 4),
                        uvs: Array(repeating: .zero, count: 4), indices: indices)
    }
    // The receiver: two halves with no shared vertex (for the per-vertex case).
    var receiverData = quad("receiver", x0: t.x - 50, x1: t.x, z: t.z - 1)
    let right = quad("right", x0: t.x, x1: t.x + 50, z: t.z - 1)
    receiverData = MeshData(name: "receiver", positions: receiverData.positions + right.positions, normals: receiverData.normals + right.normals,
                            uvs: receiverData.uvs + right.uvs, indices: receiverData.indices + right.indices.map { $0 + 4 })
    let receiver = try resources.register(mesh: receiverData)
    let front = try resources.register(mesh: quad("caster", x0: t.x - 50, x1: t.x, z: t.z))
    let back = try resources.register(mesh: quad("caster-back", x0: t.x - 50, x1: t.x, z: t.z, facing: -1))
    let wide = try resources.register(mesh: quad("caster-wide", x0: t.x - 50, x1: t.x + 50, z: t.z))
    defer { [receiver, front, back, wide].forEach { resources.unregister(mesh: $0) } }

    var standard = SourceStudioStandardInputs(albedo: Float4(1, 1, 1, 1), oneMinusReflectivity: 0.96, emissionColor: nil,
                                              emissionImage: nil, emissionSRGB: true)
    standard.smoothness = 0; standard.specularHighlights = false
    var gltf = MaterialData(name: "map"); gltf.alphaMode = "OPAQUE"
    var material = SourceStudioMapMaterial.make(gltf, standard: standard, base: nil, emission: nil, lightmap: nil, direction: nil, range: 0, exponent: 0)
    material.setFlag(MaterialFlagMapSunLit, true)
    material.setFlag(MaterialFlagReceiveShadow, true)
    var effects = SceneEffects(); effects.showGrid = false
    let strength: Float = 0.75
    var revision: UInt64 = 0
    func capture(_ casters: [(MeshHandle, Bool)], material: MaterialState = material, receive: VertexBytes? = nil,
                 strength: Float = strength, newPlacement: Bool = true) throws -> [Float] {
        var item = RenderItem(mesh: receiver, material: material, model: matrix_identity_float4x4, objectID: 0)
        item.castsShadow = false; item.outline = false; item.order = 100; item.vertexReceive = receive
        var lighting = MapLighting(sh: Array(repeating: .zero, count: 7),
                                   sun: MapLighting.Sun(directionToLight: Float3(0, 0, 1), color: Float3(1, 1, 1), shadowStrength: strength))
        var bounds = AABB.empty
        for (mesh, twoSided) in casters {
            lighting.casters.append(MapShadowCaster(mesh: mesh, model: matrix_identity_float4x4, runs: [(0, 6)], twoSided: twoSided))
            bounds.expand(try #require(resources.mesh(mesh)).bounds)
        }
        lighting.casterBounds = bounds
        if newPlacement { revision += 1 }
        lighting.revision = revision
        var frame = RenderFrame(camera: camera, items: [item], effects: effects)
        frame.mapLighting = lighting
        let bits = try #require(renderer.captureSceneHDR(frame: frame, width: 8, height: 8))
        return (0..<64).map { float16(bits[$0 * 4]) }
    }
    /// Row 4's left pixels over their mirror images on the right (equal unshadowed radiance by symmetry).
    func ratios(_ red: [Float]) -> [Float] { (0..<4).map { red[4 * 8 + $0] / red[4 * 8 + 7 - $0] } }

    let unshadowed = try capture([])
    #expect(unshadowed.allSatisfy { $0 > 0.5 }, "\(unshadowed)")
    #expect(ratios(unshadowed).allSatisfy { abs($0 - 1) < 2e-3 })
    #expect(!renderer.lastFrameStatistics.mapShadowRedrawn)
    // Cast mode On, facing the light: 1 - strength of the sun is left.
    let shadowed = try capture([(front, false)])
    for ratio in ratios(shadowed) { #expect(abs(ratio - (1 - strength)) < 4e-3, "\(ratio)") }
    #expect(renderer.lastFrameStatistics.mapShadowRedrawn && renderer.lastFrameStatistics.mapShadowDraws == 1 && renderer.hasMapShadowMap)
    // The same placement and camera reuse the shadow map, unless the measurement control redraws it.
    #expect(try capture([(front, false)], newPlacement: false) == shadowed && !renderer.lastFrameStatistics.mapShadowRedrawn)
    renderer.redrawsMapShadowEveryFrame = true
    #expect(try capture([(front, false)], newPlacement: false) == shadowed && renderer.lastFrameStatistics.mapShadowRedrawn)
    renderer.redrawsMapShadowEveryFrame = false
    // A frame without map draws neither lights nor draws the map's shadow map.
    var toon = RenderItem(mesh: receiver, material: MaterialState(uniforms: .make(kind: MaterialKindItem)), model: matrix_identity_float4x4, objectID: 0)
    toon.castsShadow = false; toon.outline = false
    var noMap = RenderFrame(camera: camera, items: [toon], effects: effects)
    var placed = MapLighting(sh: Array(repeating: .zero, count: 7),
                             sun: MapLighting.Sun(directionToLight: Float3(0, 0, 1), color: Float3(1, 1, 1), shadowStrength: strength))
    placed.casters = [MapShadowCaster(mesh: front, model: matrix_identity_float4x4, runs: [(0, 6)], twoSided: false)]
    placed.casterBounds = try #require(resources.mesh(front)).bounds
    placed.revision = 1_000_000
    noMap.mapLighting = placed
    _ = try #require(renderer.captureSceneHDR(frame: noMap, width: 8, height: 8))
    #expect(!renderer.lastFrameStatistics.mapShadowRedrawn)
    // Facing away, Cull Back drops it; Two Sided draws it.
    for ratio in ratios(try capture([(back, false)])) { #expect(abs(ratio - 1) < 2e-3, "\(ratio)") }
    for ratio in ratios(try capture([(back, true)])) { #expect(abs(ratio - (1 - strength)) < 4e-3, "\(ratio)") }
    // A draw that does not receive, and strength 0, stay lit.
    var notReceiving = material; notReceiving.setFlag(MaterialFlagReceiveShadow, false)
    for ratio in ratios(try capture([(front, false)], material: notReceiving)) { #expect(abs(ratio - 1) < 2e-3, "\(ratio)") }
    let flat = try capture([(front, false)], strength: 0)
    #expect(zip(flat, unshadowed).allSatisfy { abs($0 - $1) < 2e-3 })

    // Per vertex: the left half receives, the right does not, under a caster over both.
    let device = renderer.resources.device
    let bytes: [UInt8] = [1, 1, 1, 1, 0, 0, 0, 0]
    let buffer = try #require(device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared))
    var perVertex = material; perVertex.setFlag(MaterialFlagMapReceivePerVertex, true); perVertex.setFlag(MaterialFlagReceiveShadow, false)
    let mixed = try capture([(wide, false)], material: perVertex, receive: VertexBytes(buffer: buffer))
    for ratio in ratios(mixed) { #expect(abs(ratio - (1 - strength)) < 4e-3, "\(ratio)") }
    // Without its bytes the draw receives nothing rather than a wrong flag.
    let missing = try capture([(wide, false)], material: perVertex)
    #expect(zip(missing, unshadowed).allSatisfy { abs($0 - $1) < 2e-3 })
}

/// The fit holds the caster bounds and the receivers within the radius in its
/// depth range, for a sun anywhere, the zenith included.
@Test func mapShadowFitKeepsCastersAndReceiversInsideItsDepthRange() {
    let casters = AABB(min: Float3(-5, 0, -5), max: Float3(5, 30, 5))
    for toLight in [Float3(0.3, 0.8, 0.2), Float3(0, 1, 0), Float3(0, -1, 0), Float3(1, 0, 0)] {
        let fit = Renderer.mapShadowFit(toLight: toLight, center: Float3(1, 0, 2), radius: 40, casterBounds: casters)
        #expect(fit.viewProjection.columns.0.x.isFinite && fit.depthRange > 0 && abs(fit.texelWorld - 80 / 2048) < 1e-6)
        for p in [casters.min, casters.max, Float3(1, 0, 2) + Float3(39, -39, 39), Float3(1, 0, 2) - Float3(39, 39, 39)] {
            let clip = fit.viewProjection * Float4(p, 1)
            #expect((0...1).contains(clip.z / clip.w), "\(toLight) \(p): depth \(clip.z / clip.w)")
        }
        // Nearer the light is nearer 1 (reverse Z).
        let near = fit.viewProjection * Float4(Float3(1, 0, 2) + simd_normalize(toLight) * 5, 1)
        let far = fit.viewProjection * Float4(Float3(1, 0, 2) - simd_normalize(toLight) * 5, 1)
        #expect(near.z > far.z)
    }
}

// MARK: - A converted map with lighting

/// A map in the slice-5 layout without lightmaps: "Map" (scale 2) over mesh A
/// (two triangles with no shared vertex, receive split, cast On then Two
/// Sided) and mesh C (one triangle twice, receive split on shared vertices),
/// "Scene" over mesh B (a Fade material in the Transparent mode, visible for
/// sun type 0), the sun, and one ShadowsOnly group for sun type 0.
private struct LitMapFixture {
    let root: URL
    var url: URL { root.appendingPathComponent("map.gltf") }

    init(smoothness: Any = 0.5, casterTriangles: Int = 1) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-litmap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var buffer = Data(), views: [[String: Any]] = [], accessors: [[String: Any]] = []
        func floats(_ values: [Float], type: String, count: Int, bounds: Bool = false) {
            var accessor: [String: Any] = ["bufferView": views.count, "componentType": 5126, "count": count, "type": type]
            if bounds {
                let xyz = stride(from: 0, to: values.count, by: 3).map { Float3(values[$0], values[$0 + 1], values[$0 + 2]) }
                accessor["min"] = [xyz.map(\.x).min()!, xyz.map(\.y).min()!, xyz.map(\.z).min()!]
                accessor["max"] = [xyz.map(\.x).max()!, xyz.map(\.y).max()!, xyz.map(\.z).max()!]
            }
            views.append(["buffer": 0, "byteOffset": buffer.count, "byteLength": values.count * 4])
            for value in values { var bits = value.bitPattern.littleEndian; Swift.withUnsafeBytes(of: &bits) { buffer.append(contentsOf: $0) } }
            accessors.append(accessor)
        }
        func indices(_ values: [UInt32]) {
            accessors.append(["bufferView": views.count, "componentType": 5125, "count": values.count, "type": "SCALAR"])
            views.append(["buffer": 0, "byteOffset": buffer.count, "byteLength": values.count * 4])
            for value in values { var bits = value.littleEndian; Swift.withUnsafeBytes(of: &bits) { buffer.append(contentsOf: $0) } }
        }
        floats([0, 0, 0, 1, 0, 0, 0, 1, 0, 2, 0, 0, 3, 0, 0, 2, 1, 0], type: "VEC3", count: 6, bounds: true)   // 0: A, C positions
        floats(Array(repeating: 0, count: 12), type: "VEC2", count: 6)                                          // 1: A, C uvs
        indices([0, 1, 2, 3, 4, 5])                                                                              // 2: A
        indices([0, 1, 2, 0, 2, 1])                                                                              // 3: C
        floats([0, 0, 0, 1, 0, 0, 0, 1, 0], type: "VEC3", count: 3, bounds: true)                               // 4: B positions
        floats(Array(repeating: 0, count: 6), type: "VEC2", count: 3)                                           // 5: B uvs
        indices([0, 1, 2])                                                                                       // 6: B
        floats([0, 0, -1, 1, 0, -1, 0, 1, -1], type: "VEC3", count: 3, bounds: true)                            // 7: caster positions
        indices([0, 1, 2])                                                                                       // 8: caster indices
        try buffer.write(to: root.appendingPathComponent("map.bin"))
        func mesh(_ name: String, role: String, keys: [Int], positions: Int, uvs: Int, indices: Int, material: Int, runs: [[Any]]) -> [String: Any] {
            ["name": name, "primitives": [["attributes": ["POSITION": positions, "TEXCOORD_0": uvs], "indices": indices, "material": material]],
             "extras": ["ikkokuMap": ["role": role, "visibleFor": keys, "lightmapIndex": -1, "renderers": 1, "shadowRuns": runs]]]
        }
        func standard(_ premultiply: Bool) -> [String: Any] {
            ["unityShader": "Standard", "ikkokuStandard": ["albedoLinear": [0.5, 0.5, 0.5, 1], "oneMinusReflectivity": 0.9,
                                                           "smoothness": smoothness, "specularHighlights": true, "premultiplyAlpha": premultiply]]
        }
        var sun = sunRecord(direction: [0.6, 0.8, 0])
        sun["shadows"] = ["type": "soft", "strength": 0.8, "bias": 0.05, "normalBias": 0.4, "nearPlane": 0.2]
        let gltf: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": buffer.count, "uri": "map.bin"]],
            "bufferViews": views, "accessors": accessors,
            "materials": [["name": "opaque", "extras": standard(false)],
                          ["name": "transparent", "alphaMode": "BLEND", "extras": standard(true)]],
            "meshes": [mesh("A", role: "mapRoot", keys: [-1, 0, 1, 2], positions: 0, uvs: 1, indices: 2, material: 0,
                            runs: [[0, 3, 1, true, true], [3, 3, 2, false, true]]),
                       mesh("C", role: "mapRoot", keys: [-1, 0, 1, 2], positions: 0, uvs: 1, indices: 3, material: 0,
                            runs: [[0, 3, 1, true, true], [3, 3, 1, false, true]]),
                       mesh("B", role: "scene", keys: [0], positions: 4, uvs: 5, indices: 6, material: 1, runs: [[0, 3, 0, true, true]])],
            "nodes": [["name": "Map", "scale": [2, 2, 2], "children": [2, 3], "extras": ["ikkokuMapRole": "mapRoot"]],
                      ["name": "Scene", "children": [4], "extras": ["ikkokuMapRole": "scene"]],
                      ["name": "a", "mesh": 0, "translation": [0, 0, 1]], ["name": "c", "mesh": 1],
                      ["name": "b", "mesh": 2, "translation": [0, 3, 0]]],
            "scenes": [["nodes": [0, 1]]], "scene": 0,
            "extras": lightingExtras(sun: sun, casters: [["role": "mapRoot", "visibleFor": [0], "renderers": 1, "triangles": casterTriangles,
                                                         "positions": 7, "indices": 8]]),
        ]
        try JSONSerialization.data(withJSONObject: gltf, options: [.sortedKeys]).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Loads block their thread (see `SourceStudioMapAssetTests`), so they run
/// off the test pool.
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct SourceStudioLitMapTests {
    @Test func aLitMapDrawsItsAmbientSunAndShadowRunsAndReleasesItsCasters() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let fixture = try LitMapFixture()
        defer { fixture.remove() }
        let (url, packageRoot) = (fixture.url, fixture.root)
        let before = resources.statistics()
        let asset = try await liveTickOffPool { try SourceStudioMapAsset.load(url: url, packageRoot: packageRoot, resources: resources) }
        #expect(asset.lighting?.sun != nil && asset.parts.count == 3 && asset.probeLitParts == 3 && asset.lightmappedParts == 0)
        let a = try #require(asset.parts.first { $0.casterRuns.count == 2 })
        let c = try #require(asset.parts.first { $0.role == .mapRoot && $0.mesh != a.mesh })
        let b = try #require(asset.parts.first { $0.role == .scene })
        for part in [a, b, c] {
            #expect(part.draw == .probeLit && part.material.uniforms.flags & MaterialFlagMapSunLit.rawValue != 0)
            #expect(part.material.uniforms.params.x == 0.5 && part.material.uniforms.flags & MaterialFlagMapSpecularHighlights.rawValue != 0)
        }
        // A: receive split with no shared vertex, one byte per vertex; casts On, then Two Sided.
        #expect(a.material.uniforms.flags & MaterialFlagMapReceivePerVertex.rawValue != 0)
        #expect(a.material.uniforms.flags & MaterialFlagReceiveShadow.rawValue == 0)
        let receive = try #require(a.vertexReceive)
        #expect(Array(UnsafeBufferPointer(start: receive.buffer.contents().assumingMemoryBound(to: UInt8.self), count: 6)) == [1, 1, 1, 0, 0, 0])
        #expect(a.casterRuns.map { "\($0.first),\($0.count),\($0.twoSided)" } == ["0,3,false", "3,3,true"])
        // C: the split shares vertices, so it receives nothing; its two On runs merge.
        #expect(c.vertexReceive == nil && c.material.uniforms.flags & (MaterialFlagMapReceivePerVertex.rawValue | MaterialFlagReceiveShadow.rawValue) == 0)
        #expect(c.casterRuns.map { "\($0.first),\($0.count),\($0.twoSided)" } == ["0,6,false"])
        // B: transparent, so it receives nothing; cast mode Off.
        #expect(b.material.transparent && b.vertexReceive == nil && b.casterRuns.isEmpty)
        #expect(b.material.uniforms.flags & (MaterialFlagMapReceivePerVertex.rawValue | MaterialFlagReceiveShadow.rawValue) == 0)
        var counts = SourceStudioMapAsset.SunCounts()
        counts.sunLit = 3; counts.receivingPerVertex = 1; counts.receiveFallbacks = 1; counts.transparentNotReceiving = 1
        counts.casterParts = 2; counts.casterRuns = 3
        #expect(asset.sunCounts == counts && asset.premultipliedParts == 1)
        // The ShadowsOnly group: positions in mapRoot's frame below its authored scale.
        let shell = try #require(asset.shadowOnlyParts.first)
        #expect(asset.shadowOnlyParts.count == 1 && shell.role == .mapRoot && shell.visibleFor == [0] && shell.triangles == 1)
        #expect(simd_almost_equal_elements(shell.local, Transform.trs(.zero, .identity, Float3(repeating: 2)), 1e-6))

        // Placed: the sun turns with the map; the casters are the parts' runs and the shell.
        let amount = KoikatsuChangeAmount(position: Float3(1, 2, 3), rotationDegrees: Float3(0, 90, 0), scale: Float3(1, 1, 1))
        let root = try SourceStudioMapPlacement.mapRootMatrix(amount)
        let day = try #require(try asset.lighting(transform: amount, sunLightType: 0, mapOption: true))
        let sun = try #require(day.sun)
        #expect(simd_length(sun.directionToLight - simd_normalize(root.upperLeft3x3 * Float3(0.6, 0.8, 0))) < 1e-5)
        #expect(sun.shadowStrength == 0.8 && sun.shadowNormalBias == 0.4)
        #expect(day.casters.count == 4 && day.casters.filter(\.twoSided).count == 1)
        let shellCaster = try #require(day.casters.last)
        #expect(shellCaster.mesh == shell.mesh && simd_almost_equal_elements(shellCaster.model, root * shell.local, 1e-6))
        let aCasters = day.casters.filter { $0.mesh == a.mesh }
        #expect(aCasters.count == 2 && aCasters.allSatisfy { simd_almost_equal_elements($0.model, root * a.local, 1e-6) && $0.alphaTest == nil })
        for corner in [Float3(0, 0, -1), Float3(1, 0, -1), Float3(0, 1, -1)] {
            let p = (root * shell.local).transformPoint(corner)
            let low = day.casterBounds.min - Float3(repeating: 1e-4), high = day.casterBounds.max + Float3(repeating: 1e-4)
            #expect(all(p .>= low) && all(p .<= high))
        }
        // Another sun type has no shell; every call is a new placement.
        let evening = try #require(try asset.lighting(transform: amount, sunLightType: 1, mapOption: true))
        #expect(evening.casters.count == 3 && evening.revision != day.revision)
        // The items carry the receive bytes.
        let items = try asset.items(transform: amount, sunLightType: 0, mapOption: true)
        #expect(items.first { $0.mesh == a.mesh }?.vertexReceive == receive && items.count == 3)

        let entry = try JSONDecoder().decode(SourceStudioMapCatalog.Entry.self, from: JSONSerialization.data(withJSONObject: [
            "no": 41, "name": "備品倉庫", "bundlePath": "studio/map/warehouse.unity3d", "scene": "Warehouse", "file": "map.gltf"]))
        #expect(SourceStudioMapStatus.loaded(entry, asset: asset) == "Map 41 備品倉庫 (Warehouse): the map's ambient, realtime sun with shadows; "
            + "approximated: Transparent mode drawn as Fade, no reflections, no normal, metallic or detail maps, no fog, no camera effects"
            + " · 5 triangles, 3 draws")

        // Release retires the three meshes and the shell.
        asset.release()
        #expect(resources.statistics().retiring == 4)
        resources.completeRetirements(createdBefore: ResourceClock.tick())
        #expect(resources.statistics().meshes == before.meshes && resources.statistics().textures == before.textures)
    }

    @Test func aLitMapWithoutSmoothnessOrWithABadShellFailsByNameAndRegistersNothing() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let before = resources.statistics()
        for (fixture, reason) in [(try LitMapFixture(smoothness: NSNull()), "has map lighting but no Standard smoothness"),
                                  (try LitMapFixture(casterTriangles: 2), "shadow caster group 0 has malformed")] {
            defer { fixture.remove() }
            let (url, packageRoot) = (fixture.url, fixture.root)
            // The load's error text, or nil when it loaded.
            let failure = try await liveTickOffPool { () -> String? in
                do { _ = try SourceStudioMapAsset.load(url: url, packageRoot: packageRoot, resources: resources); return nil }
                catch { return "\(error)" }
            }
            #expect(failure?.contains(reason) == true, "\(failure ?? "loaded")")
            #expect(resources.statistics().meshes == before.meshes && resources.statistics().textures == before.textures)
        }
    }
}
