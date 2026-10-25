import Testing
import Foundation
import Metal
import simd
import CoreGraphics
import ImageIO
import CryptoKit
import Assets
import CoreMath
import ShaderTypes
import GPU
import Character
import Studio
@testable import Renderer

// R1/CMT-04 live source-shader path. Synthetic translated programs (written in
// the `program.json` + `source.metal` shape the probe reads) exercise the
// pipeline cache, material resolution, vertex-input conversion and draw
// binding; the gated check renders the controlled original fixture live.

/// Synthetic translated programs. Nothing here reads original data.
enum LiveProgramFixture {
    typealias Row = [String: Any]

    struct Stage: Sendable {
        var vectors: [(name: String, offset: Int, dimension: Int)] = []
        var matrices: [(name: String, offset: Int)] = []
        var textures: [String] = []
    }

    struct Spec {
        var inputs: [(semantic: String, index: Int)]
        var vertex = Stage()
        var fragment = Stage()
        var properties: [Row] = []
        var zWrite = 1, culling = 0, sourceBlend = 1, destinationBlend = 0
        var stencilCompare = 8, stencilPass = 0, stencilReference = 0
        var source: String
    }

    static func property(_ name: String, type: Int, defaults: [Double] = [0, 0, 0, 0], texture: String = "white") -> Row {
        var row: Row = ["m_Name": name, "m_Type": type, "m_DefTexture": ["m_DefaultName": texture]]
        for (index, value) in defaults.enumerated() { row["m_DefValue[\(index)]"] = value }
        return row
    }

    static func state(_ value: Int) -> Row { ["val": value, "name": "<noninit>"] }

    /// Writes `<directory>/<family>/program.json` and `source.metal`; returns the descriptor URL.
    @discardableResult
    static func write(_ spec: Spec, family: String, to directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent(family, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String: String] = [:], index: [String: Int] = [:]
        func id(_ name: String) -> Int {
            if let existing = index[name] { return existing }
            index[name] = index.count; names[String(index[name]!)] = name
            return index[name]!
        }
        func metadata(_ stage: Stage, buffer: String) -> Row {
            var buffers: [Row] = [], bindings: [Row] = []
            if !stage.vectors.isEmpty || !stage.matrices.isEmpty {
                let size = max(stage.vectors.map { $0.offset + 16 }.max() ?? 0, stage.matrices.map { $0.offset + 64 }.max() ?? 0)
                buffers.append(["m_NameIndex": id(buffer), "m_Size": size,
                                "m_VectorParams": stage.vectors.map { ["m_NameIndex": id($0.name), "m_Index": $0.offset, "m_Dim": $0.dimension] },
                                "m_MatrixParams": stage.matrices.map { ["m_NameIndex": id($0.name), "m_Index": $0.offset] }])
                bindings.append(["m_NameIndex": id(buffer), "m_Index": 0])
            }
            let textures: [Row] = stage.textures.enumerated().map { ["m_NameIndex": id($0.element), "m_Index": $0.offset, "m_SamplerIndex": $0.offset] }
            return ["m_ConstantBuffers": buffers, "m_ConstantBufferBindings": bindings, "m_TextureParams": textures]
        }
        let vertex = metadata(spec.vertex, buffer: "VertexGlobals"), fragment = metadata(spec.fragment, buffer: "FragmentGlobals")
        var semantics: Row = [:]
        for (register, input) in spec.inputs.enumerated() { semantics[String(register)] = ["name": input.semantic, "index": input.index, "mask": "xyzw"] }
        let source = Data(spec.source.utf8)
        let root: Row = [
            "schemaVersion": 1, "name": "Shader Forge/\(family)", "names": names, "properties": spec.properties,
            "passState": [
                "m_Name": "FORWARD", "zTest": state(4), "zWrite": state(spec.zWrite), "culling": state(spec.culling),
                "offsetFactor": state(0), "offsetUnits": state(0),
                "rtBlend0": ["srcBlend": state(spec.sourceBlend), "destBlend": state(spec.destinationBlend), "srcBlendAlpha": state(spec.sourceBlend),
                             "destBlendAlpha": state(spec.destinationBlend), "blendOp": state(0), "blendOpAlpha": state(0), "colMask": state(15)],
                "stencilOp": ["comp": state(spec.stencilCompare), "pass": state(spec.stencilPass), "fail": state(0), "zFail": state(0)],
                "stencilReadMask": state(255), "stencilWriteMask": state(255), "stencilRef": state(spec.stencilReference),
            ] as Row,
            "programs": ["vertex": ["inputSemantics": semantics, "metadata": vertex, "keywords": []] as Row,
                         "fragment": ["metadata": fragment, "keywords": []] as Row],
            "sourceMSLSHA256": SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(),
        ]
        try source.write(to: folder.appendingPathComponent("source.metal"))
        let url = folder.appendingPathComponent("program.json")
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }

    /// POSITION passes through as clip space (x, y); TEXCOORD1 reaches the
    /// fragment, which returns (u, v, `_Color`.b, 1).
    static let uvSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct SourceInput { float4 v0; float4 v1; };
    struct SourceOutput { float4 v0 [[position]]; float4 v1 [[user(locn1)]]; };
    vertex SourceOutput source_vertex(uint vid [[vertex_id]], device const SourceInput *input [[buffer(0)]]) {
        SourceOutput out; out.v0 = float4(input[vid].v0.xy, 0.5, 1.0); out.v1 = input[vid].v1; return out;
    }
    struct SourceFragmentInput { float4 v1 [[user(locn1)]]; };
    fragment float4 source_fragment(SourceFragmentInput in [[stage_in]], constant float4 *cb0 [[buffer(8)]]) {
        return float4(in.v1.x, in.v1.y, cb0[0].z, 1.0);
    }
    """

    static var uv: Spec {
        Spec(inputs: [("POSITION", 0), ("TEXCOORD", 1)], fragment: Stage(vectors: [("_Color", 0, 4)]),
             properties: [property("_Color", type: 0, defaults: [1, 1, 1, 1])], source: uvSource)
    }

    /// An outline/forward pair reading a material colour, a scene global, the
    /// ramp transform convention, a texture and a per-frame builtin.
    static func lineSpec(outline: Bool) -> Spec {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct SourceInput { float4 v0; };
        struct SourceOutput { float4 v0 [[position]]; };
        vertex SourceOutput source_vertex(uint vid [[vertex_id]], device const SourceInput *input [[buffer(0)]], constant float4 *cb0 [[buffer(8)]]) {
            SourceOutput out; out.v0 = float4(input[vid].v0.xy, 0.5, 1.0) + cb0[0] * 0.0; return out;
        }
        fragment float4 source_fragment(constant float4 *cb0 [[buffer(8)]], texture2d<float> t0 [[texture(0)]], sampler s0 [[sampler(0)]]) {
            return cb0[0] * cb0[1] * t0.sample(s0, float2(0.5)) + cb0[2] * 0.0;
        }
        """
        return Spec(inputs: [("POSITION", 0)], vertex: Stage(vectors: [("_WorldSpaceLightPos0", 0, 4)]),
                    fragment: Stage(vectors: [(outline ? "_LineColorG" : "_Color", 0, 4), ("_RampG_ST", 16, 4), ("_MainTex_ST", 32, 4)], textures: ["_MainTex"]),
                    properties: [property("_Color", type: 0, defaults: [1, 1, 1, 1]), property("_MainTex", type: 4)],
                    zWrite: outline ? 1 : 0, culling: outline ? 1 : 2, sourceBlend: outline ? 1 : 5, destinationBlend: outline ? 0 : 10,
                    stencilCompare: outline ? 6 : 8, stencilPass: outline ? 0 : 2, stencilReference: outline ? 0 : 2, source: source)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A texture provider over a fixed set of names; any other identity is a reason.
private final class StubTextureProvider: SourceShaderLiveTextureProvider, @unchecked Sendable {
    let label = "synthetic provider"
    let device: any MTLDevice
    let names: Set<String>
    init(device: any MTLDevice, names: Set<String>) { self.device = device; self.names = names }
    func texture(_ request: SourceShaderLiveTextureRequest, resources: ResourceStore) -> Result<SourceShaderLiveTexture, SourceShaderLiveReason> {
        guard let name = request.identity.name, names.contains(name) else { return .failure(.init("\(request.identity.name ?? "?") is not in the synthetic provider")) }
        do {
            return .success(SourceShaderLiveTexture(texture: try TranslatedSourceProgram.makeDefaultTexture("white", device: device),
                                                    filter: nil, wrap: nil, aniso: nil, provenance: "synthetic \(name)"))
        } catch { return .failure(.init("\(error)")) }
    }
}

typealias BindingSet = SourceShaderBindingSet

func liveMaterial(shader: String, queue: Int? = 2450, color: [Float]? = [0.5, 0.5, 0.5, 1], texture: String? = "tex_main",
                          unresolved: String? = nil) -> BindingSet.Material {
    var vectors: [String: BindingSet.Vector] = [:]
    if let color { vectors["_Color"] = .init(color, source: "card") }
    let identity = texture.map { BindingSet.TextureIdentity(kind: .asset, name: $0, bundle: "chara/test.unity3d", pathID: "1",
                                                            filter: "Bilinear", wrap: "Repeat", aniso: 1) }
    return BindingSet.Material(name: "m_test", shader: shader, queue: queue, queueSource: queue == nil ? "unresolved" : "prefab",
                               vectors: vectors, textures: ["_MainTex": .init(identity: identity, identitySource: "prefab", scale: [1, 1], offset: [0, 0], transformSource: "prefab")],
                               unresolved: unresolved)
}

private func liveRenderer(_ mesh: String, slot: Int = 0, visible: Bool = true, visibility: String = "enabled", material: BindingSet.Material) -> BindingSet.Renderer {
    .init(mesh: mesh, component: "synthetic", materialSlot: slot, submesh: 0, visible: visible, visibility: visibility, material: material)
}

/// The production pass graph built from `Shaders/` (the test bundle has no metallib).
private func makeLiveTestRenderer() throws -> Renderer {
    let gpu = try #require(GPUContext())
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ file: String) throws -> String { try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) }
    let header = try read("Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h")
    let common = try read("Shaders/Common.h").replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "")
    let shaders = try ["Deform", "Toon", "Shadow", "Outline", "Overlay", "Post"].map {
        try read("Shaders/\($0).metal").replacingOccurrences(of: "#include \"Common.h\"", with: "")
    }.joined(separator: "\n")
    let library = try gpu.device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + header + common + shaders, options: nil)
    return try Renderer(gpu: gpu, shaderLibrary: library)
}

/// A clip-space triangle covering the viewport (x, y in [-1, 3]).
private func coverMesh(_ name: String, uvs1: [Float2] = []) -> MeshData {
    MeshData(name: name, positions: [Float3(-1, -1, 0), Float3(3, -1, 0), Float3(-1, 3, 0)], normals: Array(repeating: Float3(0, 0, 1), count: 3),
             uvs: Array(repeating: Float2(0.25, 0.25), count: 3), uvs1: uvs1, indices: [0, 1, 2])
}

private func floatBuffer(_ device: any MTLDevice, _ values: [Float]) throws -> any MTLBuffer {
    try #require(device.makeBuffer(bytes: values, length: values.count * 4, options: .storageModeShared))
}

/// Raw 8-bit, four-channel bytes without row padding.
private func rgba(_ image: CGImage) throws -> [UInt8] {
    try #require(image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
    let data = try #require(image.dataProvider?.data) as Data
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for row in 0..<image.height {
            for column in 0..<(image.width * 4) { bytes[row * image.width * 4 + column] = raw[row * image.bytesPerRow + column] }
        }
    }
    return bytes
}

/// Straight-alpha RGBA bytes (the comparator's PIL `convert('RGBA')` view of a PNG).
private func straightRGBA(_ image: CGImage) throws -> [UInt8] {
    try #require(image.alphaInfo == .last, "premultiplied or skipped alpha cannot be compared byte for byte")
    return try rgba(image)
}

private func centerPixel(_ image: CGImage) throws -> [UInt8] {
    let bytes = try rgba(image)
    let offset = ((image.height / 2) * image.width + image.width / 2) * 4
    return Array(bytes[offset..<offset + 4])
}

// MARK: - Programs and pipelines

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceProgramsCompileOncePerProgramAndTarget() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let directory = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let forwardURL = try LiveProgramFixture.write(LiveProgramFixture.lineSpec(outline: false), family: "live_line", to: directory)
    let outlineURL = try LiveProgramFixture.write(LiveProgramFixture.lineSpec(outline: true), family: "live_line_outline", to: directory)
    let cache = TranslatedSourcePipelineCache(device: device)
    let forward = try cache.program(url: forwardURL)
    #expect(try cache.program(url: forwardURL) === forward)
    #expect(cache.parsedPrograms == 1)
    // Pass state and register layout come from the descriptor.
    #expect(!forward.state.zWrite && forward.state.sourceRGB == .sourceAlpha && forward.state.destinationRGB == .oneMinusSourceAlpha)
    #expect(forward.state.stencilPass == .replace && forward.state.stencilReference == 2)
    #expect(SourceShaderLiveEncoder.layout(forward) == [0])

    let first = try cache.entry(forward, target: .probe)
    let again = try cache.entry(forward, target: .probe)
    #expect(first.pipeline === again.pipeline && cache.compiledPipelines == 1)
    let msaa = TranslatedSourceTarget(color: .rgba16Float, depthStencil: .depth32Float_stencil8, sampleCount: 4)
    let main = try cache.entry(forward, target: msaa)
    #expect(main.pipeline !== first.pipeline && cache.compiledPipelines == 2)
    let outline = try cache.entry(try cache.program(url: outlineURL), target: .probe)
    #expect(outline.pipeline !== first.pipeline && cache.compiledPipelines == 3 && cache.parsedPrograms == 2)
    #expect(outline.program.state.zWrite && outline.program.state.stencilCompare == .notEqual)

    // An edited source no longer matches the descriptor's hash.
    try Data("// edited\n".utf8).write(to: forwardURL.deletingLastPathComponent().appendingPathComponent("source.metal"))
    #expect(throws: TranslatedSourceProgram.ProgramError.self) { _ = try TranslatedSourceProgram(url: forwardURL) }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceRegisterLayoutCoversEverySupportedSemantic() throws {
    let directory = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var spec = LiveProgramFixture.uv
    spec.inputs = [("POSITION", 0), ("NORMAL", 0), ("TANGENT", 0), ("TEXCOORD", 0), ("TEXCOORD", 1), ("TEXCOORD", 2), ("TEXCOORD", 3), ("COLOR", 0)]
    let program = try TranslatedSourceProgram(url: try LiveProgramFixture.write(spec, family: "live_all", to: directory))
    #expect(SourceShaderLiveEncoder.layout(program) == [0, 1, 2, 3, 4, 5, 6, 7])
    spec.inputs = [("POSITION", 0), ("TEXCOORD", 4)]
    #expect(throws: TranslatedSourceProgram.ProgramError.self) { _ = try TranslatedSourceProgram(url: try LiveProgramFixture.write(spec, family: "live_uv4", to: directory)) }
}

@Test func liveSourceFrameUniformsUseTheUnityBasis() throws {
    let view = Transform.translation(Float3(0, -0.8, -3.8)), projection = float4x4(diagonal: Float4(2, 3, -1, 1))
    let state = SourceShaderLiveEncoder.FrameState(view: view, projection: projection, cameraPosition: Float3(0, 0.8, 3.8),
        lightDirection: Float3(0.25, -0.5, -0.75), lightColor: Float3(0.5, 1, 0), lightIntensity: 2, width: 768, height: 1024, time: 4)
    func uniform(_ name: String, determinant: Float = 1) -> [Float]? { SourceShaderLiveEncoder.frameUniform(name, state: state, determinant: determinant) }
    #expect(uniform("_WorldSpaceCameraPos") == [0, 0.8, -3.8, 1])
    #expect(uniform("_WorldSpaceLightPos0") == [-0.25, 0.5, -0.75, 0])
    let linearHalf = TranslatedSourceProgram.linear(0.5)
    #expect(uniform("_LightColor0") == [linearHalf * 2, 2, 0, 1])
    #expect(uniform("_Time") == [0.2, 4, 8, 12])
    #expect(uniform("_ScreenParams") == [768, 1024, 1 + 1 / Float(768), 1 + 1 / Float(1024)])
    #expect(uniform("unity_WorldTransformParams", determinant: -1) == [0, 0, 0, -1])
    #expect(uniform("_Color") == nil)
    let basis = UnityCoordinates.basis
    let model = Transform.translation(Float3(1, 2, 3))
    #expect(try SourceShaderLiveEncoder.matrix("unity_ObjectToWorld", model: model, state: state) == basis * model * basis)
    #expect(try SourceShaderLiveEncoder.matrix("unity_MatrixVP", model: model, state: state) == projection * view * basis)
    // The clip position is the native one: VP · O2W = P · V · model · B.
    let clip = try SourceShaderLiveEncoder.matrix("unity_MatrixVP", model: model, state: state) * SourceShaderLiveEncoder.matrix("unity_ObjectToWorld", model: model, state: state)
    #expect(clip == projection * view * model * basis)
    #expect(throws: SourceShaderLiveReason.self) { _ = try SourceShaderLiveEncoder.matrix("unity_MatrixInvV", model: model, state: state) }
}

// MARK: - Material resolution

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceMaterialResolutionIsAllOrNothing() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let resources = ResourceStore(device: device)
    let directory = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try LiveProgramFixture.write(LiveProgramFixture.lineSpec(outline: false), family: "live_line", to: directory)
    try LiveProgramFixture.write(LiveProgramFixture.lineSpec(outline: true), family: "live_line_outline", to: directory)
    let provider = StubTextureProvider(device: device, names: ["tex_main"])
    let globals: [String: BindingSet.Vector] = ["_LineColorG": .init([0.5, 0.5, 0.5, 0], source: "scene")]
    func resolve(_ material: BindingSet.Material, globals: [String: BindingSet.Vector] = globals) throws -> SourceShaderLiveMaterial {
        let renderer = liveRenderer("o_line", material: material)
        let bindings = BindingSet(scope: "synthetic", renderers: [renderer], globalVectors: globals)
        return try SourceShaderLiveMaterial.resolve(renderer: renderer, bindings: bindings, programs: directory, resources: resources,
                                                    textures: provider, anisotropicFiltering: nil)
    }
    func reason(_ body: () throws -> SourceShaderLiveMaterial) -> String? {
        do { _ = try body(); return nil } catch let reason as SourceShaderLiveReason { return reason.text } catch { return "\(error)" }
    }

    let material = try resolve(liveMaterial(shader: "Shader Forge/live_line"))
    #expect(material.family == "live_line" && material.queue == 2450 && material.label == "o_line slot 0")
    #expect(material.passes.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["live_line_outline", "live_line"])
    // Colour properties are linearized as the probe does; globals and transforms are bound as derived.
    let half = TranslatedSourceProgram.linear(0.5)
    #expect(material.vectors["_Color"] == [half, half, half, 1])
    #expect(material.vectors["_LineColorG"] == [0.5, 0.5, 0.5, 0])
    #expect(material.vectors["_MainTex_ST"] == [1, 1, 0, 0])
    // `_RampG_ST` is a documented convention, listed on the material.
    #expect(material.vectors["_RampG_ST"] == [1, 1, 0, 0])
    #expect(material.conventions.contains { $0.hasPrefix("_RampG_ST = [1,1,0,0]") })
    // Per-frame builtins are left to the encoder.
    #expect(material.vectors["_WorldSpaceLightPos0"] == nil)
    #expect(material.textureSources["_MainTex"] == "synthetic tex_main")

    // Any unresolved input keeps the slot toon, with the reason.
    #expect(reason { try resolve(liveMaterial(shader: "Shader Forge/live_line", unresolved: "no converted material")) } == "no converted material")
    #expect(reason { try resolve(liveMaterial(shader: "Shader Forge/live_line", color: nil)) } == "_Color not derived")
    #expect(reason { try resolve(liveMaterial(shader: "Shader Forge/live_line"), globals: [:]) } == "global _LineColorG: not derived")
    #expect(reason { try resolve(liveMaterial(shader: "Shader Forge/live_line"), globals: ["_LineColorG": .init(unresolved: "scene mapping not recovered")]) }
        == "global _LineColorG: scene mapping not recovered")
    #expect(reason { try resolve(liveMaterial(shader: "Shader Forge/live_line", texture: "tex_missing")) } == "texture _MainTex: tex_missing is not in the synthetic provider")
    #expect(reason { try resolve(liveMaterial(shader: "Shader Forge/live_line", queue: nil)) } == "render queue not derived (unresolved)")
    #expect(reason { try resolve(liveMaterial(shader: "Shader Forge/untranslated")) } == "no translated program for Shader Forge/untranslated")
    #expect(reason { try resolve(liveMaterial(shader: "Legacy Shaders/Diffuse")) } == "shader Legacy Shaders/Diffuse is not a translated Shader Forge family")
}

// MARK: - Vertex inputs

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceVertexInputsFollowTheSourceLayoutAndKeepSkinnedNormalMagnitude() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let encoder = try SourceShaderLiveEncoder(device: device)
    let queue = try #require(device.makeCommandQueue())
    let base = DeformedVertex(position: Float4(1, 2, 3, 0), normal: Float4(0, 0, 1, 1), tangent: Float4(3, 0, 0, -1))
    let deformed = DeformedVertex(position: Float4(1, 2, 3, 0), normal: Float4(0, 0, 1, 1), tangent: Float4(0, 0, 2, 1))
    let skin = SkinVertex(joints: SIMD4<UInt16>(0, 1, 0, 0), weights: Float4(0.5, 0.5, 0, 0))
    let bones = [float4x4(diagonal: Float4(2, 2, 2, 1)), matrix_identity_float4x4]
    let morphs = [MorphWeightEntry(index: 0, weight: 1)]
    func buffer<T>(_ values: [T]) throws -> any MTLBuffer { try #require(device.makeBuffer(bytes: values, length: MemoryLayout<T>.stride * values.count, options: .storageModeShared)) }

    func convert(hasUV3: Bool, hasColors: Bool, uv1Mode: SourceShaderLiveEncoder.UVSource, uv2Mode: SourceShaderLiveEncoder.UVSource) throws -> [Float4] {
        let output = try #require(device.makeBuffer(length: 8 * 16, options: .storageModeShared))
        var params = SourceShaderLiveEncoder.Params()
        params.vertexCount = 1; params.registerCount = 8; params.hasSkin = 1; params.boneCount = 2
        params.activeMorphCount = 1; params.hasMorphNormals = 1; params.hasUV3 = hasUV3 ? 1 : 0; params.hasColors = hasColors ? 1 : 0
        params.semantics = (0, 1, 2, 3, 4, 5, 6, 7); params.uv1Mode = uv1Mode.rawValue; params.uv2Mode = uv2Mode.rawValue
        let cb = try #require(queue.makeCommandBuffer()), enc = try #require(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(encoder.convert)
        let buffers: [any MTLBuffer] = [try buffer([base]), try buffer([deformed]), try buffer([skin]), try buffer(bones), try buffer(morphs),
            try floatBuffer(device, [0, 1, 0]), try floatBuffer(device, [0.25, 0.75]), try floatBuffer(device, [0.5, 1]), try floatBuffer(device, [0.1, 0.2]),
            try floatBuffer(device, [0.3, 0.4]), try floatBuffer(device, [0.1, 0.2, 0.3, 0.4]), output]
        for (index, value) in buffers.enumerated() { enc.setBuffer(value, offset: 0, index: index) }
        enc.setBytes(&params, length: MemoryLayout<SourceShaderLiveEncoder.Params>.stride, index: 12)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: output.contents().bindMemory(to: Float4.self, capacity: 8), count: 8))
    }

    let registers = try convert(hasUV3: true, hasColors: true, uv1Mode: .native, uv2Mode: .stream)
    #expect(registers[0] == Float4(1, 2, -3, 1))                 // POSITION, Z mirrored into Unity's basis
    // NORMAL: rest + morph normal delta, skinned linearly (0.5·2 + 0.5·1 = 1.5),
    // NOT renormalized (#96), Z mirrored.
    #expect(registers[1] == Float4(0, 1.5, -1.5, 0))
    #expect(registers[2] == Float4(0, 0, -1, -1))                // TANGENT normalized, handedness from the rest vertex
    #expect(registers[3] == Float4(0.25, 0.25, 0, 0))            // TEXCOORD0 un-flipped (native V = 1 − Unity V)
    #expect(registers[4] == Float4(0.5, 0, 0, 0))                // TEXCOORD1 from the native mesh, un-flipped
    #expect(registers[5] == Float4(0.1, 0.2, 0, 0))              // TEXCOORD2 from the source stream, as stored
    #expect(registers[6] == Float4(0.3, 0.4, 0, 0))              // TEXCOORD3 stream
    #expect(registers[7] == Float4(0.1, 0.2, 0.3, 0.4))          // COLOR stream
    // Channels the source mesh lacks: the capture fixture's defaults.
    let missing = try convert(hasUV3: false, hasColors: false, uv1Mode: .zero, uv2Mode: .zero)
    #expect(missing[4] == .zero && missing[5] == .zero && missing[6] == .zero && missing[7] == Float4(1, 1, 1, 1))
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceUVSourceNeverAliasesUV0() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let resources = ResourceStore(device: device)
    let native = try #require(resources.mesh(try resources.register(mesh: coverMesh("with-uv1", uvs1: Array(repeating: Float2(0, 1), count: 3)))))
    let aliased = try #require(resources.mesh(try resources.register(mesh: coverMesh("without-uv1"))))
    #expect(native.carriesUV1 && !native.carriesUV2 && !aliased.carriesUV1)
    let withUV1 = SourceVertexStreams(mesh: "m", vertexCount: 3, uv1: try floatBuffer(device, Array(repeating: 0, count: 6)), uv3: nil, colors: nil, provenance: "test")
    let without = SourceVertexStreams(mesh: "m", vertexCount: 3, uv3: nil, colors: nil, provenance: "test")
    #expect(SourceShaderLiveEncoder.uvSource(set: 1, mesh: native, streams: nil) == .native)
    #expect(SourceShaderLiveEncoder.uvSource(set: 1, mesh: aliased, streams: nil) == nil)
    #expect(SourceShaderLiveEncoder.uvSource(set: 1, mesh: aliased, streams: withUV1) == .stream)
    #expect(SourceShaderLiveEncoder.uvSource(set: 1, mesh: aliased, streams: without) == .zero)
    #expect(SourceShaderLiveEncoder.uvSource(set: 2, mesh: native, streams: withUV1) == .zero)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceVertexStreamManifestIsHashCheckedAndVersioned() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let directory = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    let uv = Data([Float](repeating: 0.5, count: 4).withUnsafeBytes { Array($0) })
    try uv.write(to: directory.appendingPathComponent("a-uv1.bin"))
    func manifest(version: Int, file: String = "a-uv1.bin", digest: String? = nil, count: Int = 2) throws -> URL {
        var entry: [String: Any] = ["mesh": "o_hair", "bundle": "chara/hair.unity3d", "bundleSHA256": "abc", "pathID": "5", "vertexCount": count]
        if version == 2 { entry["uv1File"] = file; entry["uv1SHA256"] = digest ?? sha(uv) }
        let url = directory.appendingPathComponent("manifest-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "entries": [entry]]).write(to: url)
        return url
    }
    let loaded = try SourceVertexStreams.load(manifest: try manifest(version: 2), device: device)
    let stream = try #require(loaded["o_hair"]?.first)
    #expect(stream.uv1 != nil && stream.uv2 == nil && stream.uv3 == nil && stream.colors == nil && stream.provenance == "chara/hair.unity3d#5")
    // Schema 1 manifests (UV3/COLOR only) still load.
    #expect(try SourceVertexStreams.load(manifest: try manifest(version: 1), device: device)["o_hair"]?.first?.uv1 == nil)
    #expect(throws: SourceShaderLiveReason.self) { _ = try SourceVertexStreams.load(manifest: try manifest(version: 3), device: device) }
    #expect(throws: SourceShaderLiveReason.self) { _ = try SourceVertexStreams.load(manifest: try manifest(version: 2, digest: String(repeating: "0", count: 64)), device: device) }
    #expect(throws: SourceShaderLiveReason.self) { _ = try SourceVertexStreams.load(manifest: try manifest(version: 2, count: 3), device: device) }
    #expect(throws: SourceShaderLiveReason.self) { _ = try SourceVertexStreams.load(manifest: try manifest(version: 2, file: "../a-uv1.bin"), device: device) }
}

// MARK: - Draws

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceDrawsBindMaterialValuesAndUVSourcesOrFallBack() throws {
    let renderer = try makeLiveTestRenderer()
    let device = renderer.gpu.device, resources = renderer.resources
    let directory = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let program = try resources.translatedPipelines.program(url: try LiveProgramFixture.write(LiveProgramFixture.uv, family: "live_uv", to: directory))
    let material = SourceShaderLiveMaterial(label: "o_uv slot 0", family: "live_uv", queue: 2000, passes: [program],
                                            vectors: ["_Color": [0, 0, TranslatedSourceProgram.linear(0.5), 1]], textures: [:], conventions: [], textureSources: [:])
    func render(_ mesh: MeshData, streams: SourceVertexStreams?) throws -> (pixel: [UInt8], report: SourceShaderLiveFrameReport) {
        var item = RenderItem(mesh: try resources.register(mesh: mesh), material: MaterialState(uniforms: .make(kind: MaterialKindItem)),
                              model: matrix_identity_float4x4, objectID: 1)
        item.sourceShader = SourceShaderLiveDraw(material: material, streams: streams, sourceOrder: 0)
        let image = try renderer.captureSourceShaderLive(frame: RenderFrame(items: [item]), width: 8, height: 8)
        return (try centerPixel(image), renderer.lastSourceShaderLive)
    }
    func near(_ pixel: [UInt8], _ expected: [UInt8]) -> Bool { zip(pixel, expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 } }

    // Native UV1 (native V 1 → Unity V 0); `_Color.b` linearized then sRGB-encoded back to 0.5.
    let native = try render(coverMesh("o_uv/0", uvs1: Array(repeating: Float2(1, 1), count: 3)), streams: nil)
    #expect(native.report.draws == 1 && native.report.fallbacks.isEmpty)
    #expect(near(native.pixel, [255, 0, 128, 255]), "\(native.pixel)")
    // No native UV1: the source stream's UV1, as stored.
    let uv1 = try floatBuffer(device, [0, 1, 0, 1, 0, 1])
    let stream = try render(coverMesh("o_uv/0"), streams: SourceVertexStreams(mesh: "o_uv", vertexCount: 3, uv1: uv1, uv3: nil, colors: nil, provenance: "test"))
    #expect(near(stream.pixel, [0, 255, 128, 255]), "\(stream.pixel)")
    // A stream record without UV1: the source mesh has none, bound as zero.
    let zero = try render(coverMesh("o_uv/0"), streams: SourceVertexStreams(mesh: "o_uv", vertexCount: 3, uv3: nil, colors: nil, provenance: "test"))
    #expect(near(zero.pixel, [0, 0, 128, 255]), "\(zero.pixel)")
    // Neither: never alias UV0; the item returns to its toon draw with the reason
    // (the validation capture draws live items only, so nothing is drawn).
    let refused = try render(coverMesh("o_uv/0"), streams: nil)
    #expect(refused.report.draws == 0)
    #expect(refused.report.fallbacks.count == 1 && refused.report.fallbacks[0].contains("reads TEXCOORD1; the converted mesh carries no UV1"))
    #expect(refused.pixel == [0, 0, 0, 0])
    // Stream vertex counts must match the mesh.
    let mismatch = try render(coverMesh("o_uv/0"), streams: SourceVertexStreams(mesh: "o_uv", vertexCount: 4, uv3: nil, colors: nil, provenance: "test"))
    #expect(mismatch.report.fallbacks.first?.contains("vertex streams have 4 vertices, mesh 3") == true)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceDrawsRunInTheProductionMainPassAndLeaveToonFramesUnchanged() throws {
    let renderer = try makeLiveTestRenderer()
    let resources = renderer.resources
    let directory = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let program = try resources.translatedPipelines.program(url: try LiveProgramFixture.write(LiveProgramFixture.uv, family: "live_uv", to: directory))
    let material = SourceShaderLiveMaterial(label: "o_uv slot 0", family: "live_uv", queue: 2000, passes: [program],
                                            vectors: ["_Color": [0, 0, 1, 1]], textures: [:], conventions: [], textureSources: [:])
    let mesh = try resources.register(mesh: coverMesh("o_uv/0", uvs1: Array(repeating: Float2(1, 1), count: 3)))
    let toonItem = RenderItem(mesh: mesh, material: MaterialState(uniforms: .make(kind: MaterialKindItem)), model: matrix_identity_float4x4, objectID: 1)
    var liveItem = toonItem
    liveItem.sourceShader = SourceShaderLiveDraw(material: material, streams: nil, sourceOrder: 0)

    let toonBefore = try rgba(try #require(renderer.capture(frame: RenderFrame(items: [toonItem]), width: 16, height: 16)))
    let live = try rgba(try #require(renderer.capture(frame: RenderFrame(items: [liveItem]), width: 16, height: 16)))
    let frameError = renderer.lastFrameError
    #expect(frameError == nil, "\(String(describing: frameError))")
    #expect(renderer.lastSourceShaderLive.draws == 1 && renderer.lastSourceShaderLive.fallbacks.isEmpty)
    let toonAfter = try rgba(try #require(renderer.capture(frame: RenderFrame(items: [toonItem]), width: 16, height: 16)))
    #expect(renderer.lastSourceShaderLive.draws == 0)
    // The live draw replaced the toon draw; a frame without live items renders as before.
    #expect(live != toonBefore)
    #expect(toonAfter == toonBefore)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceDrawsFallBackToToonWhenTheStencilTargetIsUnavailable() throws {
    let renderer = try makeLiveTestRenderer()
    let resources = renderer.resources
    let directory = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let program = try resources.translatedPipelines.program(url: try LiveProgramFixture.write(LiveProgramFixture.uv, family: "live_uv", to: directory))
    let material = SourceShaderLiveMaterial(label: "o_uv slot 0", family: "live_uv", queue: 2000, passes: [program],
                                            vectors: ["_Color": [0, 0, 1, 1]], textures: [:], conventions: [], textureSources: [:])
    let mesh = try resources.register(mesh: coverMesh("o_uv/0", uvs1: Array(repeating: Float2(1, 1), count: 3)))
    let toonItem = RenderItem(mesh: mesh, material: MaterialState(uniforms: .make(kind: MaterialKindItem)), model: matrix_identity_float4x4, objectID: 1)
    var liveItem = toonItem
    liveItem.sourceShader = SourceShaderLiveDraw(material: material, streams: nil, sourceOrder: 0)

    let toon = try rgba(try #require(renderer.capture(frame: RenderFrame(items: [toonItem]), width: 16, height: 16)))
    // The MSAA depth-stencil target cannot be created: the live item is drawn
    // toon and reported, never dropped.
    let failed = try rgba(try #require(renderer.capture(frame: RenderFrame(items: [liveItem]), width: 16, height: 16, configureTargets: {
        $0.failDepthStencilCreation(with: RendererError.textureCreationFailed)
    })))
    #expect(renderer.lastFrameError == nil)
    #expect(renderer.lastSourceShaderLive.draws == 0)
    #expect(renderer.lastSourceShaderLive.fallbacks.count == 1)
    #expect(renderer.lastSourceShaderLive.fallbacks.first?.hasPrefix("o_uv slot 0: stencil main pass unavailable (") == true)
    #expect(renderer.lastSourceShaderLive.fallbacks.first?.hasSuffix("); drawn toon") == true)
    #expect(failed == toon)
    // Mutation control: with the target available the same frame draws live.
    let live = try rgba(try #require(renderer.capture(frame: RenderFrame(items: [liveItem]), width: 16, height: 16)))
    #expect(renderer.lastSourceShaderLive.draws == 1 && renderer.lastSourceShaderLive.fallbacks.isEmpty)
    #expect(live != toon)
}

// MARK: - Assembly

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceAssemblyMapsRendererSlotsHidesAndReportsEveryFallback() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let resources = ResourceStore(device: device)
    let directory = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try LiveProgramFixture.write(LiveProgramFixture.uv, family: "live_uv", to: directory)
    let uv = liveMaterial(shader: "Shader Forge/live_uv", texture: nil)
    let bindings = BindingSet(scope: "synthetic", renderers: [
        liveRenderer("o_live", material: uv),
        liveRenderer("o_hidden", visible: false, visibility: "ChaControl.synthetic: off", material: uv),
        liveRenderer("o_shadow", material: liveMaterial(shader: "Shader Forge/shadowcast")),
        liveRenderer("o_untranslated", material: liveMaterial(shader: "Shader Forge/untranslated")),
        liveRenderer("o_unmatched", material: uv),
        liveRenderer("o_nostream", material: uv),
        liveRenderer("o_stream", material: uv),
    ])
    let streams = ["o_stream": [SourceVertexStreams(mesh: "o_stream", vertexCount: 3, uv1: try floatBuffer(device, Array(repeating: 0, count: 6)),
                                                    uv3: nil, colors: nil, provenance: "test")]]
    let assembly = SourceShaderLiveAssembly(bindings: bindings, programs: directory, resources: resources,
                                            textures: StubTextureProvider(device: device, names: []), streams: streams, anisotropicFiltering: nil)
    var frame = RenderFrame()
    for (name, uvs1) in [("part/o_live/0", true), ("part/o_hidden/0", true), ("part/o_shadow/0", true), ("part/o_untranslated/0", true),
                         ("part/o_nostream/0", false), ("part/o_stream/0", false), ("native-only", true)] {
        let handle = try resources.register(mesh: coverMesh(name, uvs1: uvs1 ? Array(repeating: .zero, count: 3) : []))
        frame.items.append(RenderItem(mesh: handle, material: MaterialState(uniforms: .make(kind: MaterialKindItem)), model: matrix_identity_float4x4, objectID: 1))
    }
    let report = assembly.attach(to: &frame, resources: resources)
    #expect(report.live == ["o_live slot 0 (live_uv)", "o_stream slot 0 (live_uv); TEXCOORD1 from the source stream"])
    #expect(report.hidden == ["o_hidden/0 pass 0: ChaControl.synthetic: off", "o_shadow slot 0: ShadowCaster-only source shader (no forward pass)"])
    #expect(report.fallbacks == ["o_untranslated slot 0 (untranslated): no translated program for Shader Forge/untranslated",
                                 "o_nostream slot 0 (live_uv): no source vertex stream for this mesh (reads UV1 (the converted mesh has none))"])
    #expect(report.unmatched == ["o_unmatched slot 0 (live_uv): no native item draws this source slot"])
    #expect(frame.items.map { $0.sourceShader != nil } == [true, false, false, false, false, true, false])
    #expect(frame.items.map(\.visible) == [true, false, false, true, true, true, true])
    let parsed = SourceShaderLiveAssembly.sourceMesh("hair-0/cf_hair_b_03_00/0")
    #expect(parsed?.mesh == "cf_hair_b_03_00" && parsed?.submesh == 0)
    #expect(SourceShaderLiveAssembly.sourceMesh("native-only") == nil)
}

@Test func liveSourceConfigurationReadsOnlyItsVariables() {
    let avatar = URL(fileURLWithPath: "/rigs/source-avatar.json")
    let off = SourceShaderLiveConfiguration.environment(["IKKOKU_LIVE_SOURCE_SHADERS": "true"], sourceAvatar: avatar)
    #expect(!off.enabledAtLaunch && off.headContract?.path == "/rigs/head-materials/contract.json")
    #expect(off.missing(makerLibrary: nil) == ["IKKOKU_LIVE_SOURCE_PROGRAMS", "IKKOKU_LIVE_SOURCE_TEXTURES", "IKKOKU_MAKER_LIBRARY"])
    let on = SourceShaderLiveConfiguration.environment(["IKKOKU_LIVE_SOURCE_SHADERS": "1", "IKKOKU_LIVE_SOURCE_PROGRAMS": "/p", "IKKOKU_LIVE_SOURCE_TEXTURES": "/t",
                                                        "IKKOKU_LIVE_SOURCE_STREAMS": "", "IKKOKU_HEAD_MATERIAL_CONTRACT": "/h.json"], sourceAvatar: avatar)
    #expect(on.enabledAtLaunch && on.streams == nil && on.headContract?.path == "/h.json")
    #expect(on.missing(makerLibrary: URL(fileURLWithPath: "/library.json")).isEmpty)
}

// MARK: - Gated fixture check

/// `compare_original_frame.py`'s colour metrics (mean and numpy-linear p99 of
/// absolute RGB channel differences over `mask`).
private func colorMetrics(_ a: [UInt8], _ b: [UInt8], mask: [Bool]) -> (pixels: Int, mean: Double, p99: Double) {
    var errors: [Int] = []
    for (pixel, use) in mask.enumerated() where use {
        for channel in 0..<3 { errors.append(abs(Int(a[pixel * 4 + channel]) - Int(b[pixel * 4 + channel]))) }
    }
    guard !errors.isEmpty else { return (0, 0, 0) }
    let sorted = errors.sorted(), rank = 0.99 * Double(sorted.count - 1)
    let low = Int(rank.rounded(.down)), high = min(low + 1, sorted.count - 1)
    let p99 = Double(sorted[low]) + (Double(sorted[high]) - Double(sorted[low])) * (rank - Double(low))
    return (mask.filter { $0 }.count, Double(errors.reduce(0, +)) / Double(errors.count), p99)
}

private func nativeTextureStoreFixture(overrides: [String: Any] = [:], truncateLevel: Int? = nil) throws -> URL {
    let folder = try LiveProgramFixture.temporaryDirectory()
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("asset"), withIntermediateDirectories: true)
    let levels: [[Float16]] = [Array(repeating: Float16(0.25), count: 8) + Array(repeating: Float16(0.5), count: 8),
                             Array(repeating: Float16(0.75), count: 4)]
    var files: [String] = [], hashes: [String] = []
    for (level, pixels) in levels.enumerated() {
        let data = pixels.withUnsafeBytes { Data($0) }, name = "level-\(level).rgba16f"
        try (truncateLevel == level ? data.dropLast() : data).write(to: folder.appendingPathComponent("asset/" + name))
        files.append(name); hashes.append(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    var entry: [String: Any] = ["bundle": "chara/ramp.unity3d", "bundleSHA256": "source-hash", "name": "ramp", "pathID": "7",
                              "serializedFile": "CAB-source", "width": 2, "height": 2, "mipLevels": 2,
                              "colorSpace": "linear", "textureFormat": 4, "filter": "Bilinear", "wrap": "Clamp", "aniso": 1,
                              "directory": "asset", "files": files, "sha256": hashes]
    entry.merge(overrides) { _, new in new }
    let url = folder.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "encoding": "linear-rgba16f-little-endian-bottom-up", "entries": [entry]])
        .write(to: url)
    return url
}

private var nativeTextureIdentity: BindingSet.TextureIdentity {
    .init(kind: .asset, name: "ramp", bundle: "chara/ramp.unity3d", bundleSHA256: "source-hash", serializedFile: "CAB-source", pathID: "7",
          width: 2, height: 2, mipLevels: 2)
}

@Test func liveSourceTextureStoreRejectsMalformedMipManifests() throws {
    for overrides: [String: Any] in [["mipLevels": 0, "files": [], "sha256": []], ["width": 0], ["height": 8192],
                                   ["mipLevels": 3], ["files": ["level-0.rgba16f"]], ["sha256": []],
                                   ["sha256": ["short", String(repeating: "0", count: 64)]],
                                   ["sha256": [String(repeating: "A", count: 64), String(repeating: "0", count: 64)]],
                                   ["mipLevels": 1, "files": ["level-0.rgba16f"],
                                    "sha256": [String(repeating: "0", count: 64) + "#" + String(repeating: "1", count: 64)]],
                                   ["directory": "../outside"], ["files": ["../outside", "level-1.rgba16f"]],
                                   ["files": ["level-0.rgba16f", "level-0.rgba16f"]]] {
        let url = try nativeTextureStoreFixture(overrides: overrides)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: SourceShaderLiveReason.self) { _ = try SourceShaderTextureStore(url: url) }
    }
    let url = try nativeTextureStoreFixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let entries = try #require(manifest["entries"] as? [[String: Any]])
    var alias = try #require(entries.first)
    alias["name"] = "other"; alias["pathID"] = "8"; alias["width"] = 1
    manifest["entries"] = entries + [alias]
    try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    #expect(throws: SourceShaderLiveReason.self) { _ = try SourceShaderTextureStore(url: url) }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceTextureStoreRejectsWrongIdentityAndDamagedMipBeforeUpload() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let url = try nativeTextureStoreFixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SourceShaderTextureStore(url: url)
    var changes: [BindingSet.TextureIdentity] = []
    var wrong = nativeTextureIdentity; wrong.name = "other"; changes.append(wrong)
    wrong = nativeTextureIdentity; wrong.serializedFile = "CAB-other"; changes.append(wrong)
    wrong = nativeTextureIdentity; wrong.bundleSHA256 = "other"; changes.append(wrong)
    wrong = nativeTextureIdentity; wrong.width = 1; changes.append(wrong)
    wrong = nativeTextureIdentity; wrong.height = 1; changes.append(wrong)
    wrong = nativeTextureIdentity; wrong.mipLevels = 1; changes.append(wrong)
    for identity in changes {
        #expect(throws: SourceShaderLiveReason.self) { try store.texture(.init(identity: identity, property: "_RampG", mesh: nil, slot: nil), resources: resources).get() }
    }
    #expect(resources.statistics().textures == 0)
    // Even a correctly hashed manifest cannot upload a truncated mip.
    let shortURL = try nativeTextureStoreFixture(truncateLevel: 1)
    defer { try? FileManager.default.removeItem(at: shortURL.deletingLastPathComponent()) }
    let short = try SourceShaderTextureStore(url: shortURL)
    #expect(throws: SourceShaderLiveReason.self) { try short.texture(.init(identity: nativeTextureIdentity, property: "_RampG", mesh: nil, slot: nil), resources: resources).get() }
    #expect(resources.statistics().textures == 0)
    // Same byte count with modified pixels must also fail the SHA-256 check.
    try Data(repeating: 0, count: 8).write(to: url.deletingLastPathComponent().appendingPathComponent("asset/level-1.rgba16f"))
    #expect(throws: SourceShaderLiveReason.self) { try store.texture(.init(identity: nativeTextureIdentity, property: "_RampG", mesh: nil, slot: nil), resources: resources).get() }
    #expect(resources.statistics().textures == 0)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceTextureStoreUploadsAuthoredMipsOnceForConcurrentUsersWithoutRetainingOwner() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let url = try nativeTextureStoreFixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SourceShaderTextureStore(url: url)
    let request = SourceShaderLiveTextureRequest(identity: nativeTextureIdentity, property: "_RampG", mesh: nil, slot: nil)
    var owner: ResourceStore? = ResourceStore(device: device)
    weak var oldOwner = owner
    let texture: any MTLTexture = try {
        let resources = try #require(owner)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do { _ = try store.texture(request, resources: resources).get() }
            catch { Issue.record(error) }
        }
        let first = try store.texture(request, resources: resources).get()
        #expect(resources.statistics().textures == 1)
        #expect(first.filter == "Bilinear" && first.wrap == "Clamp" && first.aniso == 1)
        #expect(first.texture.mipmapLevelCount == 2 && first.texture.pixelFormat == .rgba16Float)
        // Source rows are bottom-up, and authored mip 1 is not regenerated
        // from the 0.25 / 0.5 base rows (whose mean would be 0.375).
        var base = [Float16](repeating: 0, count: 16), mip = [Float16](repeating: 0, count: 4)
        base.withUnsafeMutableBytes { first.texture.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0) }
        mip.withUnsafeMutableBytes { first.texture.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 1) }
        #expect(base == Array(repeating: Float16(0.5), count: 8) + Array(repeating: Float16(0.25), count: 8))
        #expect(mip == Array(repeating: Float16(0.75), count: 4))
        return first.texture
    }()
    owner = nil
    #expect(oldOwner == nil)
    let nextOwner = ResourceStore(device: device)
    let next = try store.texture(request, resources: nextOwner).get()
    #expect(next.texture !== texture && nextOwner.statistics().textures == 1)
    #expect(try store.texture(request, resources: nextOwner).get().texture === next.texture)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceTextureStoreKeysUploadsByEveryMipAndUsesVerifiedBuffers() throws {
    let device = try #require(MTLCreateSystemDefaultDevice()), resources = ResourceStore(device: device)
    let url = try nativeTextureStoreFixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let request = SourceShaderLiveTextureRequest(identity: nativeTextureIdentity, property: "_RampG", mesh: nil, slot: nil)
    let originalStore = try SourceShaderTextureStore(url: url)
    let original = try originalStore.texture(request, resources: resources).get().texture
    let mipURL = url.deletingLastPathComponent().appendingPathComponent("asset/level-1.rgba16f")
    let replacement = [Float16](repeating: 0.875, count: 4).withUnsafeBytes { Data($0) }
    try replacement.write(to: mipURL)
    // A different resource owner cannot rely on another owner's earlier
    // verification after the files change underneath the old manifest.
    #expect(throws: SourceShaderLiveReason.self) {
        try originalStore.texture(request, resources: ResourceStore(device: device)).get()
    }
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var entries = try #require(manifest["entries"] as? [[String: Any]])
    var hashes = try #require(entries[0]["sha256"] as? [String])
    hashes[1] = SHA256.hash(data: replacement).map { String(format: "%02x", $0) }.joined()
    entries[0]["sha256"] = hashes; manifest["entries"] = entries
    try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    let rebuilt = try SourceShaderTextureStore(url: url)
    let updated = try rebuilt.texture(request, resources: resources).get().texture
    #expect(updated !== original && resources.statistics().textures == 2)
    func mip(_ texture: any MTLTexture) -> [Float16] {
        var values = [Float16](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 1) }
        return values
    }
    #expect(mip(original) == Array(repeating: Float16(0.75), count: 4))
    #expect(mip(updated) == Array(repeating: Float16(0.875), count: 4))
    let equivalent = try SourceShaderTextureStore(url: url)
    #expect(try equivalent.texture(request, resources: resources).get().texture === updated)
    #expect(resources.statistics().textures == 2)
    // The upload helper has no file path: deleting the input after retaining
    // its verified bytes cannot cause it to reopen different pixels.
    try FileManager.default.removeItem(at: mipURL)
    let direct = try uploadOriginalProbeTexture(levels: [replacement], width: 1, height: 1, mipLevels: 1,
                                               generateMips: false, cacheKey: "verified-buffer-test", resources: resources)
    let directTexture = try #require(resources.texture(direct))
    var pixel = [Float16](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { directTexture.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
    #expect(pixel == Array(repeating: Float16(0.875), count: 4))
}

/// Renders the controlled original fixture live (the `IKKOKU_LIVE_SOURCE_PROBE`
/// path: live rig, card pose, CharaStudio hand pose, default expression, the
/// capture's view) and checks it with the comparator's gates. Capture pixels
/// stand in for textures (VALIDATION provider); the native store result is
/// checked separately below.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SHADER_BINDING_PROBE", "IKKOKU_SOURCE_AVATAR", "IKKOKU_MAKER_LIBRARY",
    "IKKOKU_HEAD_MATERIAL_CONTRACT", "IKKOKU_SHADER_BINDING_SUPPLEMENT", "IKKOKU_STUDIO_HAND_POSE", "IKKOKU_STUDIO_LOOK_SETTINGS",
    "IKKOKU_LIVE_SOURCE_STREAMS", "IKKOKU_LIVE_SOURCE_TEXTURES"])))
func liveSourceShadersMeetTheControlledOriginalFrameGates() throws {
    let folder = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_PROBE"), isDirectory: true)
    let avatar = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR"))
    let makerLibrary = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY"))
    let configuration = SourceShaderLiveConfiguration.environment([
        "IKKOKU_LIVE_SOURCE_PROGRAMS": folder.appendingPathComponent("shaders").path,
        "IKKOKU_LIVE_SOURCE_TEXTURES": try SourceFixtureSupport.require("IKKOKU_LIVE_SOURCE_TEXTURES"),
        "IKKOKU_LIVE_SOURCE_STREAMS": try SourceFixtureSupport.require("IKKOKU_LIVE_SOURCE_STREAMS"),
        "IKKOKU_SHADER_BINDING_SUPPLEMENT": try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_SUPPLEMENT"),
        "IKKOKU_HEAD_MATERIAL_CONTRACT": try SourceFixtureSupport.require("IKKOKU_HEAD_MATERIAL_CONTRACT"),
    ], sourceAvatar: avatar)
    var request = SourceShaderLiveFixtureProbe.Request(
        frame: folder.appendingPathComponent("frame-mips.json"), avatar: avatar, card: folder.appendingPathComponent("fixture-card.png"),
        handPose: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_STUDIO_HAND_POSE")), expression: "defaults",
        lookSettings: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_STUDIO_LOOK_SETTINGS")),
        configuration: configuration, makerLibrary: makerLibrary, textureProvider: "capture")
    let renderer = try makeLiveTestRenderer()
    let probe = try SourceShaderLiveFixtureProbe(request, renderer: renderer)
    #expect(probe.frameSHA256 == "13bd11c2805ac99172dc7ce7539c3cb98f06edcb858af4a1136ce3570b66f039")
    // Every source slot draws live; only the disabled double tooth is hidden.
    #expect(probe.attach.live.count == 20 && probe.attach.fallbacks.isEmpty && probe.attach.unmatched.isEmpty)
    #expect(probe.attach.hidden == ["cf_O_canine/0 pass 0: ChaControl.VisibleDoubleTooth: face.doubleTooth"])
    #expect(probe.captureFamiliesNotLive.isEmpty)
    let images = Dictionary(uniqueKeysWithValues: try probe.translatedImages(renderer: renderer).map { ($0.name, try straightRGBA($0.image)) })
    #expect(renderer.lastSourceShaderLive.fallbacks.isEmpty)

    let original = try straightRGBA(try #require(CGImageSourceCreateWithURL(folder.appendingPathComponent("original-color.png") as CFURL, nil)
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }))
    let full = try #require(images["native-translated.png"])
    #expect(original.count == full.count)
    let count = original.count / 4
    let originalAlpha = (0..<count).map { original[$0 * 4 + 3] > 0 }, fullAlpha = (0..<count).map { full[$0 * 4 + 3] > 0 }
    // translatedCharacter: silhouette IoU ≥ 0.999, colour mean ≤ 1 and p99 ≤ 4.
    let union = zip(originalAlpha, fullAlpha).filter { $0 || $1 }.count, intersection = zip(originalAlpha, fullAlpha).map { $0 && $1 }
    let iou = Double(intersection.filter { $0 }.count) / Double(union)
    let character = colorMetrics(original, full, mask: intersection)
    #expect(iou >= 0.999, "silhouette IoU \(iou)")
    #expect(character.mean <= 1 && character.p99 <= 4, "character colour mean \(character.mean), p99 \(character.p99)")
    // Per family, where the family is frontmost in both renders.
    var families: [String: (pixels: Int, mean: Double, p99: Double)] = [:]
    for (name, only) in images where name.hasPrefix("native-translated-") {
        let family = String(name.dropFirst("native-translated-".count).dropLast(4))
        let mask = (0..<count).map { pixel in
            originalAlpha[pixel] && only[pixel * 4 + 3] > 0 && (0..<3).allSatisfy { full[pixel * 4 + $0] == only[pixel * 4 + $0] }
        }
        families[family] = colorMetrics(original, only, mask: mask)
    }
    print("[live fixture] silhouette IoU \(iou); character mean \(character.mean), p99 \(character.p99) over \(character.pixels) px; "
          + families.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.pixels) px mean \($0.value.mean) p99 \($0.value.p99)" }.joined(separator: "; "))
    for family in ["main_opaque", "main_skin", "toon_eye_lod0", "toon_eyew_lod0"] {
        let metrics = try #require(families[family])
        #expect(metrics.pixels > 0 && metrics.mean <= 1 && metrics.p99 <= 4, "\(family): \(metrics)")
    }
    // The hair pair is the known R1 residual: the frozen-geometry probe
    // measures the same (mean 1.00 / 0.84, p99 24 / 22), so it is bounded, not passed.
    for (family, bound) in [("main_hair", 24.0), ("main_hair_front", 22.0)] {
        let metrics = try #require(families[family])
        #expect(metrics.pixels > 3000 && metrics.mean <= 1.1 && metrics.p99 <= bound + 2, "\(family): \(metrics)")
    }

    // Native texture store only: all asset-backed slots resolve, including
    // the six ramp users and four hair-gloss users, and the iris
    // (`ctCreateEyeL`/`R`), eye-white (`ctCreateEyeW`) and normal top/bottom/inner-shoe
    // and head-zero face and ordinary female body composites are composed natively.
    let storeURL = try #require(configuration.textures)
    let storeData = try Data(contentsOf: storeURL)
    let storeManifest = try #require(JSONSerialization.jsonObject(with: storeData) as? [String: Any])
    #expect((storeManifest["entries"] as? [[String: Any]])?.count == 62)
    #expect((storeManifest["unavailable"] as? [[String: Any]])?.isEmpty == true)
    let compositeRows = storeManifest["composites"] as? [[String: Any]] ?? []
    let compositeMaterials: [String] = compositeRows.compactMap { $0["material"] as? String }
    #expect(compositeRows.count == 5 && compositeMaterials == ["cf_m_body_create", "cf_m_eyewhite_create", "cf_m_clothesN_create", "cf_m_face_create", "cf_m_eye_create"])
    #expect((storeManifest["unavailableComposites"] as? [[String: Any]])?.isEmpty == true)
    // Exclude machine-specific roots/source.file while pinning every asset,
    // mip hash, sampler and the source binding report's hash.
    var content = storeManifest.filter { ["schemaVersion", "encoding", "entries", "unavailable", "composites", "unavailableComposites"].contains($0.key) }
    content["sourceBindingsSHA256"] = try #require((storeManifest["source"] as? [String: Any])?["sha256"] as? String)
    let contentData = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys, .withoutEscapingSlashes])
    let contentHash = SHA256.hash(data: contentData).map { String(format: "%02x", $0) }.joined()
    print("[native texture fixture] store content \(contentHash)")
    #expect(contentHash == "b9ae136b9d4537bb8809f9f6207fb4ebdafbfa66ba0a4d4466b20ac83b4eadce")
    request.textureProvider = "store"
    let store = try SourceShaderLiveFixtureProbe(request, renderer: renderer)
    #expect(Set(store.attach.live) == Set([
        "cf_O_face slot 0 (main_skin); convention (capture fixture default, Unity's missing-channel value unverified): COLOR absent in the source mesh: white",
        "o_body_a slot 0 (main_skin); TEXCOORD1 from the source stream, TEXCOORD2 from the source stream",
        "cf_O_noseline slot 0 (toon_nose_lod0)", "cf_O_mayuge slot 0 (toon_eyew_lod0)", "cf_O_tooth slot 0 (main_item)",
        "cf_O_eyeline slot 0 (toon_eyew_lod0)", "cf_O_eyeline slot 1 (toon_eyew_lod0)", "cf_O_eyeline_low slot 0 (toon_eyew_lod0)",
        "cf_Ohitomi_L slot 0 (toon_eyew_lod0)", "cf_Ohitomi_R slot 0 (toon_eyew_lod0)", "o_top_tsyats_a slot 0 (main_opaque)",
        "cf_Ohitomi_L02 slot 0 (toon_eye_lod0)", "cf_Ohitomi_R02 slot 0 (toon_eye_lod0)", "o_bot_pants03 slot 0 (main_opaque)", "o_shoes_run01 slot 0 (main_opaque)", "o_tang slot 0 (main_item)", "cf_hair_b_03_00 slot 0 (main_hair); TEXCOORD1 from the source stream",
        "cf_hair_idol_hair_f_00 slot 0 (main_hair_front); TEXCOORD1 from the source stream",
        "cf_hair_idol_hair_f_01 slot 0 (main_hair_front); TEXCOORD1 from the source stream",
        "cf_hair_idol_hair_f_02 slot 0 (main_hair_front); TEXCOORD1 from the source stream"]))
    #expect(store.attach.fallbacks.isEmpty && store.attach.unmatched.isEmpty)
    // Both irises share one composite and both eye whites another (one recipe
    // each on this card): each is composed once, then hit once. The normal
    // top, bottom, inner shoe, face and body each have one visible renderer and compose once.
    let eventsByKey = Dictionary(grouping: store.composites, by: \.contentKey).mapValues { $0.map(\.cacheHit) }
    #expect(eventsByKey.count == 7 && eventsByKey.values.filter { $0 == [false, true] }.count == 2
            && eventsByKey.values.filter { $0 == [false] }.count == 5, "\(store.composites)")
    let resolvedTextureCount = renderer.resources.statistics().textures
    let nativeImages = Dictionary(uniqueKeysWithValues: try store.translatedImages(renderer: renderer).map { ($0.name, try straightRGBA($0.image)) })
    #expect(renderer.resources.statistics().textures == resolvedTextureCount, "Live draws must reuse assembly textures")
    #expect(renderer.lastSourceShaderLive.fallbacks.isEmpty)
    let nativeFull = try #require(nativeImages["native-translated.png"])
    for (family, bound) in [("main_opaque", 4.0), ("toon_eyew_lod0", 4.0), ("toon_eye_lod0", 4.0), ("main_hair", 24.0), ("main_hair_front", 22.0)] {
        let name = "native-translated-\(family).png"
        let only = try #require(nativeImages[name]), capturedOnly = try #require(images[name])
        // Retain the per-family comparison on pixels frontmost in both
        // providers. Resolving the final composite does not establish
        // whole-character colour or lighting parity.
        let mask = (0..<count).map { pixel in
            originalAlpha[pixel] && only[pixel * 4 + 3] > 0 && capturedOnly[pixel * 4 + 3] > 0 && (0..<3).allSatisfy {
                nativeFull[pixel * 4 + $0] == only[pixel * 4 + $0] && full[pixel * 4 + $0] == capturedOnly[pixel * 4 + $0]
            }
        }
        let metrics = colorMetrics(original, only, mask: mask)
        print("[native texture fixture] \(family): \(metrics.pixels) px mean \(metrics.mean) p99 \(metrics.p99)")
        let isHair = family.hasPrefix("main_hair")
        #expect(metrics.pixels > (isHair ? 3000 : 250) && metrics.mean <= (isHair ? 1.1 : 1) && metrics.p99 <= bound + (isHair ? 2 : 0),
                "\(family): \(metrics)")
    }
    // Tooth/tongue and nose resolve but are never frontmost in the complete
    // controlled view. Their colour has no independently observed pixels.
    for family in ["main_item", "toon_nose_lod0"] {
        #expect(try #require(families[family]).pixels == 0)
        print("[native texture fixture] \(family): resolution checked; no frontmost reference pixels for colour")
    }
}
