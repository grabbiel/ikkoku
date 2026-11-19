import Testing
import Foundation
import CryptoKit
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
    let pixel = try renderSunPixel(material, lighting: lighting, normal: normal, eye: eye)
    return Float3(pixel.x, pixel.y, pixel.z)
}

/// renderSun's draw as RGBA, with `map_fragment` or with the ToonMapProbeLit pipelines'
/// `toon_map_probe_lit_fragment` (its item-only inputs bound to white, the lights empty), and a white or
/// black emission texture. With `bump`, the mesh carries `tangent` and a 1×1 normal texture holds the texel
/// (alpha, green) at `TextureIndexNormal`, as the renderer binds a map's normal map for both pipelines.
private func renderSunPixel(_ material: MaterialUniforms, lighting: MapLightingUniforms, normal: Float3, eye: Float3,
                            toonMapProbeLit: Bool = false, whiteEmission: Bool = false,
                            tangent: Float4 = .zero, bump: SIMD2<UInt8>? = nil) throws -> Float4 {
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
    descriptor.fragmentFunction = library.makeFunction(name: toonMapProbeLit ? Pipelines.ambientLitMapFunctions.fragment : "map_fragment")
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
                        normals: Array(repeating: normal, count: 3), tangents: bump == nil ? [] : Array(repeating: tangent, count: 3),
                        uvs: Array(repeating: Float2(0.5, 0.5), count: 3), indices: [0, 1, 2])
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
    encoder.setFragmentTexture(whiteEmission ? resources.whiteTexture : resources.blackTexture, index: Int(TextureIndexEmission.rawValue))
    if toonMapProbeLit {
        var lights = LightsUniforms()
        encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
        encoder.setFragmentBytes(&lights, length: MemoryLayout<LightsUniforms>.stride, index: Int(BufferIndexLights.rawValue))
        for index in [TextureIndexColorMask, TextureIndexDetail, TextureIndexLine, TextureIndexNormal, TextureIndexOverlay0, TextureIndexOverlay1,
                      TextureIndexOverlay2, TextureIndexHairGloss, TextureIndexPattern, TextureIndexBodyMask] {
            encoder.setFragmentTexture(resources.whiteTexture, index: Int(index.rawValue))
        }
        encoder.setFragmentTexture(try mapShadowPlaceholder(device), index: Int(TextureIndexShadowMap.rawValue))
    }
    if let bump {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        let image = try #require(device.makeTexture(descriptor: descriptor))
        image.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [0, bump.y, 0, bump.x], bytesPerRow: 4)
        encoder.setFragmentTexture(image, index: Int(TextureIndexNormal.rawValue))
    }
    encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    try #require(command.status == .completed, "map draw failed: \(String(describing: command.error))")
    var pixel = [Float](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
    return Float4(pixel[0], pixel[1], pixel[2], pixel[3])
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

/// P5: map_fragment skips the sun block where the normal faces away from the
/// sun (n.l <= 0). Every term of BRDF1_Unity_PBS and LightingLambert is scaled
/// by saturate(n.l) = 0 there, so the skip must leave the pixel bit-identical
/// to the same draw without the sun: probe ambient, Standard (with and without
/// highlights) and Lambert, with and without a shadowed receiver. Slice 6: the
/// test is on the shading normal, so a normal map that turns a back-facing
/// surface towards the sun keeps its sun.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func mapFragmentFacingAwayFromTheSunIsTheNoSunPixel() throws {
    let l = simd_normalize(Float3(0.5, 0.6, 0.62)), eye = Float3(-0.4, 0.3, 2)
    let sh = SourceStudioMapLightingMath.engineSH(testProbe())
    // Straight away from the sun, and grazing (n.l = -0.05).
    let side = simd_normalize(simd_cross(l, Float3(0, 0, 1)))
    let normals = [-l, simd_normalize(simd_normalize(side + simd_cross(l, side) * 0.3) - 0.05 * l)]
    for normal in normals { #expect(simd_dot(normal, l) < -0.04) }
    func material(smoothness: Float?, highlights: Bool, lambert: Bool, normalMapped: Bool = false) -> MaterialState {
        var standard = SourceStudioStandardInputs(albedo: Float4(0.5, 0.25, 1, 1), oneMinusReflectivity: lambert ? 1 : 0.8, emissionColor: nil,
                                                  emissionImage: nil, emissionSRGB: true)
        standard.smoothness = smoothness; standard.specularHighlights = highlights
        var gltf = MaterialData(name: "map"); gltf.alphaMode = "OPAQUE"
        var m = SourceStudioMapMaterial.make(gltf, standard: standard, base: nil, emission: nil, lightmap: nil, direction: nil,
                                             range: 0, exponent: 0, lambert: lambert, normal: normalMapped ? TextureHandle(id: 1) : nil)
        m.setFlag(MaterialFlagMapSunLit, true)
        return m
    }
    for strength: Float in [0, 0.8] {
        let lighting = Renderer.mapLightingUniforms(MapLighting(sh: sh, sun: MapLighting.Sun(directionToLight: l, color: Float3(1.3, 1.1, 0.9),
                                                                                             shadowStrength: strength)))
        for (smoothness, highlights, lambert) in [(Float(0.6), true, false), (Float(0), false, false), (nil, true, true)] {
            var m = material(smoothness: smoothness, highlights: highlights, lambert: lambert)
            m.setFlag(MaterialFlagReceiveShadow, true)
            var noSun = m; noSun.setFlag(MaterialFlagMapSunLit, false)
            for normal in normals {
                let lit = try renderSun(m.uniforms, lighting: lighting, normal: normal, eye: eye)
                let unlit = try renderSun(noSun.uniforms, lighting: lighting, normal: normal, eye: eye)
                #expect(lit == unlit, "strength \(strength) smoothness \(String(describing: smoothness)) lambert \(lambert): \(lit) != \(unlit)")
            }
            // The same draws facing the sun do add it, so the equality above is not vacuous.
            let facing = try renderSun(m.uniforms, lighting: lighting, normal: l, eye: eye)
            #expect(simd_length(facing - (try renderSun(noSun.uniforms, lighting: lighting, normal: l, eye: eye))) > 0.01)
        }
    }
    // Slice 6: a texel tilting the normal towards its tangent (xy = (0.80, 0.004), scale 1). mapNormal on the CPU.
    let toward = SIMD2<UInt8>(230, 128)
    func mapped(_ n: Float3, _ t: Float3) -> Float3 {
        let xy = Float2(Float(toward.x), Float(toward.y)) / 255 * 2 - 1
        let tn = Float3(xy.x, -xy.y, (1 - min(max(simd_dot(xy, xy), 0), 1)).squareRoot())
        return simd_normalize(t * tn.x + simd_cross(n, t) * tn.y + n * tn.z)
    }
    // At the grazing normal with the tangent towards the sun, the shading normal faces the sun; straight away, it does not.
    let grazing = normals[1], up = simd_normalize(l - simd_dot(l, grazing) * grazing)
    let away = -l, aside = side
    #expect(simd_dot(mapped(grazing, up), l) > 0.5 && simd_dot(mapped(away, aside), l) < -0.5)
    let lighting = Renderer.mapLightingUniforms(MapLighting(sh: sh, sun: MapLighting.Sun(directionToLight: l, color: Float3(1.3, 1.1, 0.9),
                                                                                         shadowStrength: 0.8)))
    for (smoothness, highlights) in [(Float(0.6), true), (Float(0), false)] {
        var m = material(smoothness: smoothness, highlights: highlights, lambert: false, normalMapped: true)
        m.setFlag(MaterialFlagReceiveShadow, true)
        var noSun = m; noSun.setFlag(MaterialFlagMapSunLit, false)
        let tangent = Float4(up.x, up.y, up.z, 1)
        let lit = try renderSunPixel(m.uniforms, lighting: lighting, normal: grazing, eye: eye, tangent: tangent, bump: toward)
        let unlit = try renderSunPixel(noSun.uniforms, lighting: lighting, normal: grazing, eye: eye, tangent: tangent, bump: toward)
        #expect(simd_length(lit - unlit) > 0.01, "smoothness \(smoothness): the mapped normal faces the sun, so the sun is drawn")
        // It is the whole sun term: the unmapped draw whose geometric normal is the mapped one.
        var plain = material(smoothness: smoothness, highlights: highlights, lambert: false); plain.setFlag(MaterialFlagReceiveShadow, true)
        let reference = try renderSunPixel(plain.uniforms, lighting: lighting, normal: mapped(grazing, up), eye: eye)
        #expect(simd_length(lit - reference) < 1e-4, "smoothness \(smoothness): \(lit) != \(reference)")
        // Still facing away after the map: skipped, bit for bit.
        let awayTangent = Float4(aside.x, aside.y, aside.z, 1)
        let awayLit = try renderSunPixel(m.uniforms, lighting: lighting, normal: away, eye: eye, tangent: awayTangent, bump: toward)
        let awayUnlit = try renderSunPixel(noSun.uniforms, lighting: lighting, normal: away, eye: eye, tangent: awayTangent, bump: toward)
        #expect(awayLit == awayUnlit, "smoothness \(smoothness): \(awayLit) != \(awayUnlit)")
    }
}

/// ST-A11 slice 5: the renderer draws ambient-lit map surfaces with the ToonMapProbeLit pipelines, whose
/// toon_map_probe_lit_fragment calls map_fragment's own Standard helpers. Its pixels must be map_fragment's, bit
/// for bit (rgba32Float): ambient, sun facing and facing away, Standard with and without highlights and
/// Lambert, a shadowed receiver, emission, alpha test (discarded and kept) and alpha blend.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func toonMapProbeLitDrawsAmbientLitMapSurfacesAsMapFragment() throws {
    let l = simd_normalize(Float3(0.5, 0.6, 0.62)), eye = Float3(-0.4, 0.3, 2)
    let sh = SourceStudioMapLightingMath.engineSH(testProbe())
    let normals = [simd_normalize(Float3(0.2, 0.3, 1)), l, -l]
    func material(smoothness: Float?, highlights: Bool, lambert: Bool, alpha: Float = 1, mode: String = "OPAQUE",
                  emission: Float3? = nil, normalMapped: Bool = false) -> MaterialState {
        var standard = SourceStudioStandardInputs(albedo: Float4(0.5, 0.25, 1, alpha), oneMinusReflectivity: lambert ? 1 : 0.8,
                                                  emissionColor: emission, emissionImage: nil, emissionSRGB: true)
        standard.smoothness = smoothness; standard.specularHighlights = highlights; standard.normalScale = 0.8
        var gltf = MaterialData(name: "map"); gltf.alphaMode = mode; gltf.alphaCutoff = 0.5
        var m = SourceStudioMapMaterial.make(gltf, standard: standard, base: nil, emission: nil, lightmap: nil, direction: nil,
                                             range: 0, exponent: 0, lambert: lambert, normal: normalMapped ? TextureHandle(id: 1) : nil)
        m.setFlag(MaterialFlagMapSunLit, true)
        return m
    }
    var cases: [(String, MaterialState)] = []
    for (smoothness, highlights, lambert) in [(Float(0.6), true, false), (Float(0), false, false), (nil, true, true)] {
        let base = material(smoothness: smoothness, highlights: highlights, lambert: lambert)
        cases.append(("s\(String(describing: smoothness)) hl\(highlights) lambert \(lambert)", base))
        var receiver = base; receiver.setFlag(MaterialFlagReceiveShadow, true)
        cases.append(("receiver s\(String(describing: smoothness)) lambert \(lambert)", receiver))
        var unlit = base; unlit.setFlag(MaterialFlagMapSunLit, false)
        cases.append(("not sun-lit s\(String(describing: smoothness)) lambert \(lambert)", unlit))
    }
    cases.append(("emission", material(smoothness: 0.6, highlights: true, lambert: false, emission: Float3(0.3, 0.2, 0.1))))
    cases.append(("alpha test kept", material(smoothness: 0.6, highlights: true, lambert: false, alpha: 0.75, mode: "MASK")))
    cases.append(("alpha test discarded", material(smoothness: 0.6, highlights: true, lambert: false, alpha: 0.25, mode: "MASK")))
    cases.append(("alpha blend", material(smoothness: 0.6, highlights: true, lambert: false, alpha: 0.4, mode: "BLEND")))
    var drawn = Set<[Float]>()
    for strength: Float in [0, 0.8] {
        let lighting = Renderer.mapLightingUniforms(MapLighting(sh: sh, sun: MapLighting.Sun(directionToLight: l, color: Float3(1.3, 1.1, 0.9),
                                                                                             shadowStrength: strength)))
        for (label, m) in cases {
            #expect(m.uniforms.kind == UInt32(MaterialKindMap.rawValue) && Renderer.drawsAmbientLitMap(m.uniforms), "\(label)")
            for normal in normals {
                for white in [false, true] {
                    let map = try renderSunPixel(m.uniforms, lighting: lighting, normal: normal, eye: eye, whiteEmission: white)
                    let toon = try renderSunPixel(m.uniforms, lighting: lighting, normal: normal, eye: eye, toonMapProbeLit: true, whiteEmission: white)
                    #expect(map == toon, "\(label), strength \(strength), normal \(normal), emission \(white): \(map) != \(toon)")
                    drawn.insert([map.x, map.y, map.z, map.w])
                }
            }
        }
    }
    // The sun, the ambient, the BRDF variant, emission and alpha each move the pixel (17 distinct values), so the equality is
    // not vacuous. The 1×1 placeholder compares lit, so the receivers' visibility is 1 here; the renderer-level shadow
    // test below draws real shadows through these pipelines.
    #expect(drawn.count >= 15, "\(drawn.count) distinct pixels")
    // Slice 6: normal-mapped ambient-lit surfaces shade with the same per-texel normal in both pipelines (Unity's usual
    // w = -1 tangent, two texels, scale 0.8). The map moves the pixel wherever it is not black, so the equality is not
    // vacuous. Black is opaque black: ShadeSH9 clamped to 0 and the sun behind, mapped or not.
    let tangent = Float4(simd_normalize(Float3(1, 0, -0.2)), -1)
    var mappedCases = [("normal-mapped s0.6", material(smoothness: 0.6, highlights: true, lambert: false, normalMapped: true)),
                       ("normal-mapped s0", material(smoothness: 0, highlights: false, lambert: false, normalMapped: true))]
    var receiver = mappedCases[0].1; receiver.setFlag(MaterialFlagReceiveShadow, true)
    mappedCases.append(("normal-mapped receiver", receiver))
    var moved = 0
    for strength: Float in [0, 0.8] {
        let lighting = Renderer.mapLightingUniforms(MapLighting(sh: sh, sun: MapLighting.Sun(directionToLight: l, color: Float3(1.3, 1.1, 0.9),
                                                                                             shadowStrength: strength)))
        for (label, m) in mappedCases {
            #expect(m.uniforms.flags & MaterialFlagMapNormal.rawValue != 0 && Renderer.drawsAmbientLitMap(m.uniforms), "\(label)")
            var unmapped = m; unmapped.setFlag(MaterialFlagMapNormal, false)
            for normal in normals {
                for bump in [SIMD2<UInt8>(200, 60), SIMD2<UInt8>(90, 220)] {
                    let map = try renderSunPixel(m.uniforms, lighting: lighting, normal: normal, eye: eye, tangent: tangent, bump: bump)
                    let toon = try renderSunPixel(m.uniforms, lighting: lighting, normal: normal, eye: eye, toonMapProbeLit: true,
                                                  tangent: tangent, bump: bump)
                    #expect(map == toon, "\(label), strength \(strength), normal \(normal), texel \(bump): \(map) != \(toon)")
                    let flat = try renderSunPixel(unmapped.uniforms, lighting: lighting, normal: normal, eye: eye, tangent: tangent, bump: bump)
                    if map != flat { moved += 1 } else {
                        #expect(map == Float4(0, 0, 0, 1), "\(label), normal \(normal), texel \(bump): the normal map does not reach the pixel")
                    }
                }
            }
        }
    }
    // 36 draws: all but the 6 at -l with the second texel, which are black either way.
    #expect(moved >= 30, "the normal map moved \(moved) of 36 pixels")
    // Silhouette, unlit and particle draws keep map_fragment's own branches; lightmapped draws keep the map pipeline.
    var particle = material(smoothness: 0.6, highlights: true, lambert: false); particle.setFlag(MaterialFlagMapParticle, true)
    #expect(!Renderer.drawsAmbientLitMap(particle.uniforms))
    var lightmapped = material(smoothness: 0.6, highlights: true, lambert: false); lightmapped.setFlag(MaterialFlagMapProbeLit, false)
    #expect(!Renderer.drawsAmbientLitMap(lightmapped.uniforms))
}

/// ST-A11 slice 5: the ambient-lit map branch has its own entry point, so the item and character pipelines
/// (ToonOpaque, ToonBlend, both main-pass variants) keep toon_vertex + toon_fragment exactly as compiled.
/// Neither function declares a function constant: building them specialized (fix A, function constant 0)
/// moved 6 character pixels on map33-showoff, so a later constant here must fail this test.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func itemPipelinesBuildToonFragmentWithNoFunctionConstants() throws {
    #expect(Pipelines.itemFunctions.vertex == "toon_vertex" && Pipelines.itemFunctions.fragment == "toon_fragment")
    #expect(Pipelines.ambientLitMapFunctions.vertex == "toon_vertex")
    #expect(Pipelines.ambientLitMapFunctions.fragment != Pipelines.itemFunctions.fragment)
    let library = try makeSourceShaderRenderer().pipelines.library
    for name in [Pipelines.itemFunctions.vertex, Pipelines.itemFunctions.fragment, Pipelines.ambientLitMapFunctions.fragment] {
        let function = try #require(library.makeFunction(name: name), "\(name)")
        #expect(function.functionConstantsDictionary.isEmpty, "\(name) declares \(function.functionConstantsDictionary.keys.sorted())")
    }
}

// MARK: - The map sun's shadow map

/// mapShadowVisibility across a straight shadow edge equals a 3-texel-wide
/// triangle filter over the per-texel compares: with the edge at texel
/// coordinate 8 and d the receiver's distance from it in texels,
/// V(d) = (1.5 + d)^2 / 4.5 for -1.5 <= d <= 0 and 1 - (1.5 - d)^2 / 4.5 for
/// 0 <= d <= 1.5 (0 and 1 beyond). The 4 bilinear compares carry the
/// hardware's filtering precision, hence the tolerance.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func mapShadowVisibilityIsATriangleFilterOfTheCompares() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ file: String) throws -> String { try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) }
    let header = try read("Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h")
    let common = try read("Shaders/Common.h").replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "")
    let toon = try read("Shaders/Toon.metal").replacingOccurrences(of: "#include \"Common.h\"", with: "")
    let probe = """
    kernel void shadow_visibility_probe(depth2d<float> shadow [[texture(0)]], constant MapLightingUniforms& light [[buffer(0)]],
                                        device const float4* positions [[buffer(1)]], device float* out [[buffer(2)]],
                                        uint i [[thread_position_in_grid]]) {
        out[i] = mapShadowVisibility(positions[i].xyz, light, shadow);
    }
    """
    let library = try device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + header + common + toon + probe, options: nil)
    let pipeline = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: "shadow_visibility_probe")))

    // A 16x16 reverse-Z shadow map: columns 0-7 hold a caster at depth 1, columns 8-15 the cleared far depth 0.
    let size = 16
    var depths = [Float](repeating: 0, count: size * size)
    for y in 0..<size { for x in 0..<8 { depths[y * size + x] = 1 } }
    let staging = try #require(device.makeBuffer(bytes: depths, length: depths.count * 4, options: .storageModeShared))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
    descriptor.usage = .shaderRead; descriptor.storageMode = .private
    let shadow = try #require(device.makeTexture(descriptor: descriptor))

    var lighting = MapLightingUniforms()
    lighting.shadowViewProjection = matrix_identity_float4x4
    lighting.shadowParams = Float4(1, 1 / Float(size), 0, 1)
    // Receivers at depth 0.5 (behind the caster, in front of the far depth), d from -2.5 to 2.5 texels
    // in quarter texels, on a row away from texel boundaries.
    let ds = stride(from: Float(-2.5), through: 2.5, by: 0.25).map { $0 }
    let positions = ds.map { d -> Float4 in
        let u = (8 + d) / Float(size)
        return Float4(2 * u - 1, 1 - 2 * (5.3 / Float(size)), 0.5, 1)
    }
    let positionBuffer = try #require(device.makeBuffer(bytes: positions, length: positions.count * 16, options: .storageModeShared))
    let out = try #require(device.makeBuffer(length: positions.count * 4, options: .storageModeShared))
    let queue = try #require(device.makeCommandQueue())
    let command = try #require(queue.makeCommandBuffer())
    let blit = try #require(command.makeBlitCommandEncoder())
    blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: size * 4, sourceBytesPerImage: size * size * 4,
              sourceSize: MTLSize(width: size, height: size, depth: 1), to: shadow, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin())
    blit.endEncoding()
    let compute = try #require(command.makeComputeCommandEncoder())
    compute.setComputePipelineState(pipeline)
    compute.setTexture(shadow, index: 0)
    compute.setBytes(&lighting, length: MemoryLayout<MapLightingUniforms>.stride, index: 0)
    compute.setBuffer(positionBuffer, offset: 0, index: 1)
    compute.setBuffer(out, offset: 0, index: 2)
    compute.dispatchThreads(MTLSize(width: positions.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: positions.count, height: 1, depth: 1))
    compute.endEncoding()
    command.commit(); command.waitUntilCompleted()
    try #require(command.status == .completed, "probe failed: \(String(describing: command.error))")
    let values = (0..<positions.count).map { out.contents().load(fromByteOffset: $0 * 4, as: Float.self) }

    func expected(_ d: Float) -> Float {
        if d <= -1.5 { return 0 }
        if d >= 1.5 { return 1 }
        return d <= 0 ? (1.5 + d) * (1.5 + d) / 4.5 : 1 - (1.5 - d) * (1.5 - d) / 4.5
    }
    for (d, v) in zip(ds, values) { #expect(abs(v - expected(d)) < 0.02, "d \(d): \(v) vs \(expected(d))") }
    #expect(zip(values, values.dropFirst()).allSatisfy { $1 >= $0 - 1e-3 }, "not monotonic: \(values)")
    #expect(abs(values[ds.firstIndex(of: 0)!] - 0.5) < 0.01)
}

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

/// #399: the sun's compare bias and caster normal offset are Unity's biases,
/// in world texels, × the tent's 2-texel reach.
@Test func mapSunBiasesScaleUnitysBiasesByTheTentsReach() {
    #expect(Renderer.mapShadowFilterReach == 2)
    // The parse fixture's sun (bias 0.05, normal bias 0.4) on the ±40 m map shadow map.
    let texel = 2 * Renderer.mapShadowRadius / Float(Renderer.mapShadowMapSize), range: Float = 80
    let biases = Renderer.mapSunBiases(shadowBias: 0.05, normalBias: 0.4, texelWorld: texel, depthRange: range)
    #expect(biases.compare == 2 * 0.05 * texel / range)
    #expect(biases.normalOffset == 2 * 0.4 * texel)
    let none = Renderer.mapSunBiases(shadowBias: 0, normalBias: 0, texelWorld: texel, depthRange: range)
    #expect(none.compare == 0 && none.normalOffset == 0)
}

/// A box of half-size `half`: 6 faces of 4 vertices (no vertex shared across
/// faces), outward normals, counter-clockwise seen from outside.
private func mapStateBox(_ name: String, half: Float3) -> MeshData {
    let faces: [(n: Float3, u: Float3, v: Float3)] = [
        (Float3(1, 0, 0), Float3(0, 0, -1), Float3(0, 1, 0)), (Float3(-1, 0, 0), Float3(0, 0, 1), Float3(0, 1, 0)),
        (Float3(0, 1, 0), Float3(1, 0, 0), Float3(0, 0, -1)), (Float3(0, -1, 0), Float3(1, 0, 0), Float3(0, 0, 1)),
        (Float3(0, 0, 1), Float3(1, 0, 0), Float3(0, 1, 0)), (Float3(0, 0, -1), Float3(-1, 0, 0), Float3(0, 1, 0)),
    ]
    var positions: [Float3] = [], normals: [Float3] = [], uvs: [Float2] = [], indices: [UInt32] = []
    for face in faces {
        let first = UInt32(positions.count)
        for (a, b, uv) in [(Float(-1), Float(-1), Float2(0, 1)), (1, -1, Float2(1, 1)), (1, 1, Float2(1, 0)), (-1, 1, Float2(0, 0))] {
            positions.append((face.n + face.u * a + face.v * b) * half); normals.append(face.n); uvs.append(uv)
        }
        indices += [first, first + 1, first + 2, first, first + 2, first + 3]
    }
    return MeshData(name: name, positions: positions, normals: normals, uvs: uvs, indices: indices)
}

/// RGBA8 4×4 of one colour.
private func mapStateTexture(_ renderer: Renderer, _ rgba: [UInt8]) throws -> TextureHandle {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    let texture = try #require(renderer.gpu.device.makeTexture(descriptor: descriptor))
    texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: [UInt8]((0..<16).flatMap { _ in rgba }), bytesPerRow: 16)
    return renderer.resources.register(texture: texture)
}

/// Frame preparation's `EncoderState` (merged from main) on a slice-5 frame:
/// the main pass alternates the Map, ToonMapProbeLit, toon and outline
/// pipelines in its opaque records, and MapDepthOnly + MapBlend (silhouette),
/// ToonMapProbeLitBlend, MapBlend and ToonBlend in its transparent ones, under
/// the map sun with a map shadow map, between draws that do and do not bind
/// their own receive bytes. Records 5 and 6 have the same texture set (kind
/// and handles) and differ only in their pipeline. The frame renders, shades
/// and picks byte for byte as it does with every state set for every draw
/// (the reference `EncoderState` documents). The controls show that each
/// switch, the lightmap texture and the map shadow map reach the image, so a
/// dropped one would differ.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func skippingRepeatedEncoderStateKeepsAlternatingMapAndAmbientLitDrawsByteForByte() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    let cube = try resources.register(mesh: mapStateBox("map-state-cube", half: Float3(repeating: 0.2)))
    let backdrop = try resources.register(mesh: mapStateBox("map-state-backdrop", half: Float3(2.4, 1.5, 0.05)))
    let red = try mapStateTexture(renderer, [230, 40, 30, 255])
    let lightA = try mapStateTexture(renderer, [200, 180, 120, 255]), lightB = try mapStateTexture(renderer, [60, 90, 220, 255])
    defer {
        [cube, backdrop].forEach { resources.unregister(mesh: $0) }
        [red, lightA, lightB].forEach { resources.unregister(texture: $0) }
    }
    func map(lightmap: TextureHandle? = nil, base: TextureHandle? = nil, alpha: Float = 1, blend: Bool = false) -> MaterialState {
        var standard = SourceStudioStandardInputs(albedo: Float4(0.8, 0.7, 0.6, alpha), oneMinusReflectivity: 0.9, emissionColor: nil,
                                                  emissionImage: nil, emissionSRGB: true)
        standard.smoothness = 0.4; standard.specularHighlights = true
        var gltf = MaterialData(name: "map"); gltf.alphaMode = blend ? "BLEND" : "OPAQUE"
        var m = SourceStudioMapMaterial.make(gltf, standard: standard, base: base, emission: nil, lightmap: lightmap, direction: nil,
                                             range: 1, exponent: 1)
        m.setFlag(MaterialFlagMapSunLit, true)
        m.setFlag(MaterialFlagReceiveShadow, true)
        return m
    }
    func toon(_ base: TextureHandle? = nil, alpha: Float = 1) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindItem))
        if let base { m.base = base; m.setFlag(MaterialFlagHasBaseTexture, true) }
        if alpha < 1 { m.transparent = true; m.uniforms.baseColor.w = alpha }
        return m
    }
    var lightmappedRed = map(base: red); lightmappedRed.setFlag(MaterialFlagMapProbeLit, false)
    var perVertex = map(); perVertex.setFlag(MaterialFlagMapReceivePerVertex, true); perVertex.setFlag(MaterialFlagReceiveShadow, false)
    let receive = try #require(resources.device.makeBuffer(bytes: [UInt8](repeating: 1, count: 12) + [UInt8](repeating: 0, count: 12),
                                                           length: 24, options: .storageModeShared))
    let silhouette = SourceStudioSilhouetteInputs(color: Float4(0.2, 0.6, 0.9, 0.5)).material()

    struct Spec { var mesh: MeshHandle; var material: MaterialState; var at: Float3; var receive: VertexBytes? = nil; var outline = false }
    // Opaque records draw in this order (`order` is their index); the transparent ones by their render queue.
    let opaque: [Spec] = [
        Spec(mesh: backdrop, material: map(), at: Float3(0, 1.2, -0.8)),                       // 1: ToonMapProbeLit, receives the cubes' shadows
        Spec(mesh: cube, material: toon(red), at: Float3(-1.5, 0.5, 0), outline: true),       // 2: outline, then ToonOpaque
        Spec(mesh: cube, material: map(), at: Float3(-0.9, 0.5, 0)),                          // 3: ToonMapProbeLit after toon
        Spec(mesh: cube, material: map(lightmap: lightA), at: Float3(-0.3, 0.5, 0)),          // 4: Map after ToonMapProbeLit
        Spec(mesh: cube, material: map(lightmap: lightB), at: Float3(0.3, 0.5, 0)),           // 5: Map, another lightmap
        Spec(mesh: cube, material: map(base: red), at: Float3(0.9, 0.5, 0)),                  // 6: ToonMapProbeLit after Map
        Spec(mesh: cube, material: lightmappedRed, at: Float3(1.5, 0.5, 0)),                  // 7: Map, the texture set of 6
        Spec(mesh: cube, material: toon(), at: Float3(-0.9, 1.1, 0)),                         // 8: ToonOpaque after Map
        Spec(mesh: cube, material: perVertex, at: Float3(-0.3, 1.1, 0),
             receive: VertexBytes(buffer: receive)),                                           // 9: ToonMapProbeLit, its own receive bytes
        Spec(mesh: cube, material: map(), at: Float3(0.3, 1.1, 0)),                           // 10: ToonMapProbeLit, the material's flag
    ]
    let transparent: [Spec] = [
        Spec(mesh: cube, material: silhouette, at: Float3(-1.2, 1.8, 0.4)),                  // 11: MapDepthOnly, MapBlend
        Spec(mesh: cube, material: map(alpha: 0.5, blend: true), at: Float3(-0.6, 1.8, 0.4)), // 12: ToonMapProbeLitBlend after the silhouette
        Spec(mesh: cube, material: map(lightmap: lightA, alpha: 0.5, blend: true),
             at: Float3(0, 1.8, 0.4)),                                                         // 13: MapBlend
        Spec(mesh: cube, material: toon(alpha: 0.5), at: Float3(0.6, 1.8, 0.4)),              // 14: ToonBlend
        Spec(mesh: cube, material: map(alpha: 0.5, blend: true), at: Float3(1.2, 1.8, 0.4)),  // 15: ToonMapProbeLitBlend after ToonBlend
        Spec(mesh: cube, material: silhouette, at: Float3(0.3, 2.3, 0.4)),                   // 16: the silhouette after it
    ]
    let toLight = simd_normalize(Float3(0.35, 0.5, 1))
    func frame(_ opaque: [Spec], _ transparent: [Spec], casters: Bool = true) throws -> RenderFrame {
        var items: [RenderItem] = []
        for (index, spec) in (opaque + transparent).enumerated() {
            var item = RenderItem(mesh: spec.mesh, material: spec.material, model: Transform.trs(spec.at, simd_quatf(angle: 0, axis: Float3(0, 1, 0)), Float3(repeating: 1)),
                                  objectID: UInt32(index + 1))
            item.outline = spec.outline
            item.vertexReceive = spec.receive
            item.castsShadow = spec.material.uniforms.kind != UInt32(MaterialKindMap.rawValue)
            if index < opaque.count { item.order = index } else { item.renderQueue = 3000 + index }
            items.append(item)
        }
        var lighting = MapLighting(sh: [Float4(0, 0, 0, 0.35), Float4(0, 0, 0, 0.3), Float4(0, 0, 0, 0.25)] + Array(repeating: .zero, count: 4),
                                   sun: MapLighting.Sun(directionToLight: toLight, color: Float3(1.2, 1.1, 0.95), shadowStrength: 0.8))
        var bounds = AABB.empty
        for spec in opaque[2...] where spec.mesh == cube && casters {
            let model = Transform.trs(spec.at, simd_quatf(angle: 0, axis: Float3(0, 1, 0)), Float3(repeating: 1))
            lighting.casters.append(MapShadowCaster(mesh: cube, model: model, runs: [(0, 36)], twoSided: false))
            bounds.expand(AABB(min: spec.at - 0.2, max: spec.at + 0.2))
        }
        lighting.casterBounds = bounds
        lighting.revision = casters ? 1 : 2
        var camera = OrbitCamera()
        camera.target = Float3(0, 1.2, 0); camera.distance = 6; camera.yaw = 0; camera.pitch = 0
        var effects = SceneEffects(); effects.showGrid = false
        var frame = RenderFrame(camera: camera, items: items, effects: effects, sceneBounds: AABB(min: Float3(-2.5, -0.5, -1), max: Float3(2.5, 2.8, 1)))
        frame.mapLighting = lighting
        return frame
    }
    struct Rendered: Equatable { let hdr: [UInt16]; let ldr: [UInt8]; let pick: [UInt32] }
    func render(_ frame: RenderFrame, skips: Bool) throws -> Rendered {
        renderer.skipsRedundantEncoderState = skips
        defer { renderer.skipsRedundantEncoderState = true }
        let hdr = try #require(renderer.captureSceneHDR(frame: frame, width: 320, height: 240), "\(String(describing: renderer.lastFrameError))")
        let image = try #require(renderer.capture(frame: frame, width: 320, height: 240))
        let data = try #require(image.dataProvider?.data as Data?)
        let pick = try #require(renderer.pickTarget(frame: frame, size: (320, 240)))
        return Rendered(hdr: hdr, ldr: [UInt8](data), pick: pick)
    }
    let reference = try frame(opaque, transparent)
    let skipped = try render(reference, skips: true)
    let full = try render(reference, skips: false)
    #expect(skipped.hdr == full.hdr, "HDR scene differs at \(skipped.hdr.indices.filter { skipped.hdr[$0] != full.hdr[$0] }.prefix(8))")
    #expect(skipped.ldr == full.ldr, "LDR image differs")
    #expect(skipped.pick == full.pick, "Pick ids differ")
    #expect(renderer.hasMapShadowMap)

    // Controls: given the state of the record before it, a record renders differently.
    let ids = Set(full.pick)
    #expect(ids.isSuperset(of: Set(2...UInt32(opaque.count + transparent.count))), "\(ids.sorted())")
    var variants: [(String, [Spec], [Spec], Bool)] = []
    var o = opaque; o[2].material = toon(); variants.append(("ToonOpaque → ToonMapProbeLit", o, transparent, true))
    o = opaque; o[3].material = map(); variants.append(("ToonMapProbeLit → Map", o, transparent, true))
    o = opaque; o[4].material = map(lightmap: lightA); variants.append(("lightmap texture", o, transparent, true))
    o = opaque; o[5].material = lightmappedRed; variants.append(("Map → ToonMapProbeLit", o, transparent, true))
    o = opaque; o[6].material = map(base: red); variants.append(("ToonMapProbeLit → Map, same textures", o, transparent, true))
    o = opaque; o[7].material = lightmappedRed; variants.append(("Map → ToonOpaque", o, transparent, true))
    var t = transparent; t[1].material.setFlag(MaterialFlagMapProbeLit, false); variants.append(("MapBlend → ToonMapProbeLitBlend", opaque, t, true))
    t = transparent; t[2].material = map(alpha: 0.5, blend: true); variants.append(("ToonMapProbeLitBlend → MapBlend", opaque, t, true))
    t = transparent; t[4].material = toon(alpha: 0.5); variants.append(("ToonBlend → ToonMapProbeLitBlend", opaque, t, true))
    variants.append(("map shadow map", opaque, transparent, false))
    for (label, o, t, casters) in variants {
        let other = try render(try frame(o, t, casters: casters), skips: false)
        #expect(other.hdr != full.hdr, "\(label): the change does not reach the image")
    }
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
/// sun type 0), the sun, and one ShadowsOnly group for sun type 0. With
/// `normal` (slice 6), the opaque material carries a block-only BC3 normal
/// map at `_BumpScale` 0.8 and A and C carry tangents, or one of them is
/// broken as the variant says.
private struct LitMapFixture {
    enum Normal { case mapped, noTangent, noMark, badPacking }
    let root: URL
    var url: URL { root.appendingPathComponent("map.gltf") }
    /// One constant BC3 block: alpha 200, colour (0, 63, 0) in 5:6:5.
    static let bump: [UInt8] = [200, 200, 0, 0, 0, 0, 0, 0, 0xE0, 0x07, 0xE0, 0x07, 0, 0, 0, 0]

    init(smoothness: Any = 0.5, casterTriangles: Int = 1, normal: Normal? = nil) throws {
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
        let tangents = normal != nil && normal != .noTangent
        if tangents { floats(Array([[Float]](repeating: [1, 0, 0, -1], count: 6).joined()), type: "VEC4", count: 6) }  // 9: A, C tangents
        try buffer.write(to: root.appendingPathComponent("map.bin"))
        func mesh(_ name: String, role: String, keys: [Int], positions: Int, uvs: Int, indices: Int, material: Int, runs: [[Any]]) -> [String: Any] {
            var attributes = ["POSITION": positions, "TEXCOORD_0": uvs]
            if tangents && positions == 0 { attributes["TANGENT"] = 9 }
            return ["name": name, "primitives": [["attributes": attributes, "indices": indices, "material": material]],
                    "extras": ["ikkokuMap": ["role": role, "visibleFor": keys, "lightmapIndex": -1, "renderers": 1, "shadowRuns": runs]]]
        }
        func standard(_ premultiply: Bool) -> [String: Any] {
            var inputs: [String: Any] = ["albedoLinear": [0.5, 0.5, 0.5, 1], "oneMinusReflectivity": 0.9,
                                         "smoothness": smoothness, "specularHighlights": true, "premultiplyAlpha": premultiply]
            if normal != nil && !premultiply {
                inputs["normal"] = ["image": 0, "scale": 0.8, "packing": normal == .badPacking ? "rgb" : "unityDXT5nm", "srgb": false,
                                    "textureFormat": "DXT5"]
            }
            return ["unityShader": "Standard", "ikkokuStandard": inputs]
        }
        var extras: [String: Any] = [:]
        var images: [[String: Any]] = []
        if normal != nil {
            let bump = Data(Self.bump)
            try bump.write(to: root.appendingPathComponent("0_bump.bc3"))
            images = [["uri": "0_bump.bc3", "mimeType": "image/x-ikkoku-bc3"]]
            let digest = SHA256.hash(data: bump).map { String(format: "%02x", $0) }.joined()
            extras["ikkokuBlockImages"] = ["kind": "ikkoku.unityBlockImages", "version": 1, "rows": "topDown", "cubes": [] as [Any],
                                           "images": [["image": 0, "name": "bump", "file": "0_bump.bc3", "format": "BC3", "width": 4,
                                                       "height": 4, "mipCount": 1, "srgb": false, "bytes": bump.count, "sha256": digest]]]
            if normal != .noMark {
                extras["ikkokuMapNormals"] = ["kind": "ikkoku.unityNormalMaps", "version": 1, "packing": "unityDXT5nm", "materials": 1, "images": 1]
            }
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
            "scenes": [["nodes": [0, 1]]], "scene": 0, "images": images, "textures": images.indices.map { ["source": $0] },
            "extras": lightingExtras(sun: sun, casters: [["role": "mapRoot", "visibleFor": [0], "renderers": 1, "triangles": casterTriangles,
                                                         "positions": 7, "indices": 8]]).merging(extras) { $1 },
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
        #expect(asset.sunCounts == counts && asset.premultipliedParts == 1 && asset.normalMaps == nil)
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

    /// Slice 6: the opaque material's normal map is one block-only BC3 image
    /// for A and C. It loads, counts and releases with the map's other
    /// textures; the Standard parts draw it at their `_BumpScale`, the
    /// transparent part (no `_NORMALMAP`) does not.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression == true))
    func aNormalMappedLitMapDrawsItsBumpOnItsStandardPartsAndReleasesIt() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let fixture = try LitMapFixture(normal: .mapped)
        defer { fixture.remove() }
        let (url, packageRoot) = (fixture.url, fixture.root)
        let before = resources.statistics()
        let asset = try await liveTickOffPool {
            try SourceStudioMapAsset.load(url: url, packageRoot: packageRoot, resources: resources, imageSource: .blocks)
        }
        let counts = try #require(asset.normalMaps)
        #expect(counts.draws == 2 && counts.textures == 1 && counts.bytes > 0 && counts.bytes <= asset.textureBytes)
        #expect(asset.blockImages == 1 && resources.statistics().textures == before.textures + 1)
        let mapped = asset.parts.filter { $0.material.uniforms.flags & MaterialFlagMapNormal.rawValue != 0 }
        #expect(mapped.count == 2 && mapped.allSatisfy { $0.role == .mapRoot && $0.draw == .probeLit && $0.material.uniforms.params.z == 0.8 })
        #expect(Set(mapped.compactMap(\.material.normal)).count == 1 && mapped.allSatisfy { $0.material.normal != nil })
        let b = try #require(asset.parts.first { $0.role == .scene })
        #expect(b.material.normal == nil && b.material.uniforms.flags & MaterialFlagMapNormal.rawValue == 0)
        let entry = try JSONDecoder().decode(SourceStudioMapCatalog.Entry.self, from: JSONSerialization.data(withJSONObject: [
            "no": 41, "name": "備品倉庫", "bundlePath": "studio/map/warehouse.unity3d", "scene": "Warehouse", "file": "map.gltf"]))
        #expect(SourceStudioMapStatus.loaded(entry, asset: asset) == "Map 41 備品倉庫 (Warehouse): the map's ambient, realtime sun with shadows; "
            + "approximated: Transparent mode drawn as Fade, no reflections, no metallic or detail maps, no fog, no camera effects"
            + " · 5 triangles, 3 draws")
        // Release retires the three meshes, the shell and the normal map.
        asset.release()
        #expect(resources.statistics().retiring == 5)
        resources.completeRetirements(createdBefore: ResourceClock.tick())
        #expect(resources.statistics().meshes == before.meshes && resources.statistics().textures == before.textures)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression == true))
    func aNormalMapWithoutTangentsMarkOrKnownPackingFailsByNameAndRegistersNothing() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let before = resources.statistics()
        for (variant, reason) in [(LitMapFixture.Normal.noTangent, "mesh A has a normal-mapped material but no TANGENT"),
                                  (.noMark, "material opaque has a normal map but the map does not mark its normal maps"),
                                  (.badPacking, "normal map has packing rgb, not unityDXT5nm")] {
            let fixture = try LitMapFixture(normal: variant)
            defer { fixture.remove() }
            let (url, packageRoot) = (fixture.url, fixture.root)
            let failure = try await liveTickOffPool { () -> String? in
                do { _ = try SourceStudioMapAsset.load(url: url, packageRoot: packageRoot, resources: resources, imageSource: .blocks); return nil }
                catch { return "\(error)" }
            }
            #expect(failure?.contains(reason) == true, "\(variant): \(failure ?? "loaded")")
            #expect(resources.statistics().meshes == before.meshes && resources.statistics().textures == before.textures)
        }
    }
}
