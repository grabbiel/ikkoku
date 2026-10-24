import Testing
import Foundation
import Metal
import CryptoKit
import QuartzCore
import Character
import Studio
@testable import Renderer

// R1/CMT-04 runtime composites (`CustomTextureCreate` render targets) composed
// natively for the live path. The synthetic store below holds a hand-written
// fragment-only program with the `create_eye` or `create_eyewhite` arithmetic
// (the CPU references are `create_eye_base` and `create_eye_white` in
// Tools/reverse/head_material_contract.py); nothing here reads original data.
// The gated checks at the end compose the controlled fixture's irises and eye
// whites from the private store and compare them with the retained original
// composite readbacks.

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A schema-2 texture store: 4×4 inputs (bottom-up rows) and one create program.
private enum CompositeStoreFixture {
    static let programSHA = String(repeating: "c", count: 64)

    /// A hand-written create program: its source, `$Globals` layout, texture
    /// slots, properties and pass blend factors.
    struct Program: @unchecked Sendable {   // immutable once built; rows are plain JSON values
        var source: String
        var names: [String: String]
        var vectors: [(index: Int, offset: Int, dim: Int)]
        var bufferSize: Int
        var textures: [(name: Int, slot: Int)]
        var properties: [LiveProgramFixture.Row]
        var blend: (source: Int, destination: Int)
    }

    /// The `create_eye` fragment, written the way the translator emits it:
    /// `cb0[2]` `_Color2`, `cb0[3]` `_MainTex_ST`, `cb0[4]` `_Color`,
    /// `cb0[5]` `_ColorMask_ST`, `cb0[6].x` `_Blend`, `cb0[7]` `_grad`;
    /// textures sampled at (u, 1 − v).
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct SourceFragmentInput { float4 v1 [[user(locn1)]]; };
    fragment float4 source_fragment(SourceFragmentInput in [[stage_in]], constant float4 *cb0 [[buffer(8)]],
                                    texture2d<float> t0 [[texture(0)]], texture2d<float> t1 [[texture(1)]],
                                    sampler s0 [[sampler(0)]], sampler s1 [[sampler(1)]]) {
        float2 uv = in.v1.xy;
        float k = 1.0 - cb0[7].w;
        float2 g = ((uv + cb0[7].xy) * (k + k) + (0.5 - k)) * cb0[5].xy + cb0[5].zw;
        float m = t1.sample(s1, float2(g.x, 1.0 - g.y)).x;
        float3 c = m * (cb0[4].xyz - cb0[2].xyz) + cb0[2].xyz;
        float2 mu = uv * cb0[3].xy + cb0[3].zw;
        float4 base = t0.sample(s0, float2(mu.x, 1.0 - mu.y));
        float t = base.x;
        float3 low = 1.0 - ((1.0 - c) * 0.5) / t;
        float3 high = c / ((1.0 - t) + (1.0 - t));
        float3 overlay = saturate(0.5 < t ? high : low);
        return float4(cb0[6].x * (overlay - t * c) + c * t, base.w * cb0[4].w);
    }
    """

    /// Main input: R is the overlay `t`, A the coverage. Bottom-up rows.
    static let main: [SIMD4<Float>] = (0..<16).map { index in
        let t: [Float] = [0.25, 0.375, 0.625, 0.875, 0.125, 0.5, 0.75, 0.9375]
        let a: [Float] = [1, 0.75, 0.5, 0.25]
        return SIMD4(t[index % 8], 0, 0, a[index / 4])
    }
    static let otherMain: [SIMD4<Float>] = main.map { SIMD4($0.x * 0.5, 0, 0, $0.w) }
    /// Mask input: R picks `_Color` (1) over `_Color2` (0).
    static let mask: [SIMD4<Float>] = (0..<16).map { SIMD4(Float($0 % 5) * 0.25, 0, 0, 1) }

    /// `create_eye` pass 0: Blend SrcAlpha OneMinusSrcAlpha.
    static let eye = Program(
        source: source,
        names: ["0": "$Globals", "1": "_Color2", "2": "_MainTex_ST", "3": "_Color", "4": "_ColorMask_ST", "5": "_Blend", "6": "_grad",
                "7": "_MainTex", "8": "_ColorMask"],
        vectors: [(1, 32, 4), (2, 48, 4), (3, 64, 4), (4, 80, 4), (5, 96, 1), (6, 112, 4)], bufferSize: 128,
        textures: [(7, 0), (8, 1)],
        properties: [LiveProgramFixture.property("_Color", type: 0, defaults: [1, 1, 1, 1]), LiveProgramFixture.property("_Color2", type: 0),
                     LiveProgramFixture.property("_Blend", type: 3), LiveProgramFixture.property("_grad", type: 1),
                     LiveProgramFixture.property("_MainTex", type: 4), LiveProgramFixture.property("_ColorMask", type: 4)],
        blend: (5, 10))

    /// The `create_eyewhite` fragment, written the way the translator emits it:
    /// `cb0[2]` `_Color`, `cb0[3]` `_MainTex_ST`, `cb0[4]` `_Color2`; the
    /// colour is `lerp(_Color2, _Color, texMain.r)` with alpha 1, and pass 0
    /// blends One Zero.
    static let eyeWhite = Program(
        source: """
        #include <metal_stdlib>
        using namespace metal;
        struct SourceFragmentInput { float4 v1 [[user(locn1)]]; };
        fragment float4 source_fragment(SourceFragmentInput in [[stage_in]], constant float4 *cb0 [[buffer(8)]],
                                        texture2d<float> t0 [[texture(0)]], sampler s0 [[sampler(0)]]) {
            float2 mu = in.v1.xy * cb0[3].xy + cb0[3].zw;
            float t = t0.sample(s0, float2(mu.x, 1.0 - mu.y)).x;
            return float4(t * (cb0[2].xyz - cb0[4].xyz) + cb0[4].xyz, 1.0);
        }
        """,
        names: ["0": "$Globals", "1": "_Color", "2": "_MainTex_ST", "3": "_Color2", "7": "_MainTex"],
        vectors: [(1, 32, 4), (2, 48, 4), (3, 64, 4)], bufferSize: 80,
        textures: [(7, 0)],
        properties: [LiveProgramFixture.property("_Color", type: 0, defaults: [1, 1, 1, 1]), LiveProgramFixture.property("_Color2", type: 0, defaults: [1, 1, 1, 1]),
                     LiveProgramFixture.property("_MainTex", type: 4)],
        blend: (1, 0))

    struct Store { let url: URL; let folder: URL }

    static func write(schemaVersion: Int = 2, compositeOverrides: [String: Any] = [:], extraComposite: Bool = false,
                      program spec: Program = eye, mainWrap: String = "Clamp") throws -> Store {
        let folder = try LiveProgramFixture.temporaryDirectory()
        var entries: [[String: Any]] = []
        for (name, pathID, pixels) in [("main", "11", main), ("mask", "12", mask), ("main2", "13", otherMain)] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
            let data = pixels.flatMap { [Float16($0.x), Float16($0.y), Float16($0.z), Float16($0.w)] }.withUnsafeBytes { Data($0) }
            try data.write(to: folder.appendingPathComponent(name + "/level-0.rgba16f"))
            let wrap: String = name == "main" ? mainWrap : "Clamp"
            entries.append(["bundle": "chara/inputs.unity3d", "bundleSHA256": "inputs-hash", "name": name, "pathID": pathID,
                            "serializedFile": "CAB-inputs", "width": 4, "height": 4, "mipLevels": 1, "colorSpace": "linear",
                            "textureFormat": 4, "filter": "Bilinear", "wrap": wrap, "aniso": 1, "directory": name,
                            "files": ["level-0.rgba16f"], "sha256": [hex(data)]])
        }
        let program = folder.appendingPathComponent("create")
        try FileManager.default.createDirectory(at: program, withIntermediateDirectories: true)
        let sourceData = Data(spec.source.utf8)
        try sourceData.write(to: program.appendingPathComponent("source.metal"))
        let vectors: [[String: Any]] = spec.vectors.map { ["m_NameIndex": $0.index, "m_Index": $0.offset, "m_Dim": $0.dim] }
        let metadata: [String: Any] = [
            "m_ConstantBuffers": [["m_NameIndex": 0, "m_Size": spec.bufferSize, "m_VectorParams": vectors, "m_MatrixParams": []]],
            "m_ConstantBufferBindings": [["m_NameIndex": 0, "m_Index": 0]],
            "m_TextureParams": spec.textures.map { ["m_NameIndex": $0.name, "m_Index": $0.slot, "m_SamplerIndex": $0.slot] },
        ]
        let state = LiveProgramFixture.state
        let root: [String: Any] = [
            "schemaVersion": 1, "stages": ["fragment"], "name": "Shader Forge/create_test", "material": "m_create", "materialPathID": "5",
            "bundleSHA256": "create-hash", "serializedFile": "CAB-create", "names": spec.names,
            "properties": spec.properties,
            // The create passes keep Shader Forge's ZTest LEqual, ZWrite On, Cull Back state.
            "passState": [
                "m_Name": "FORWARD", "zTest": state(4), "zWrite": state(1), "culling": state(2), "offsetFactor": state(0), "offsetUnits": state(0),
                "rtBlend0": ["srcBlend": state(spec.blend.source), "destBlend": state(spec.blend.destination),
                             "srcBlendAlpha": state(spec.blend.source), "destBlendAlpha": state(spec.blend.destination),
                             "blendOp": state(0), "blendOpAlpha": state(0), "colMask": state(15)],
                "stencilOp": ["comp": state(8), "pass": state(0), "fail": state(0), "zFail": state(0)],
                "stencilReadMask": state(255), "stencilWriteMask": state(255), "stencilRef": state(0),
            ] as [String: Any],
            "programs": ["fragment": ["metadata": metadata, "sha256": programSHA, "variants": 2,
                                      "inputSemantics": ["0": ["name": "SV_POSITION", "index": 0], "1": ["name": "TEXCOORD", "index": 0]]] as [String: Any]],
            "sourceMSLSHA256": hex(sourceData),
        ]
        let programData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try programData.write(to: program.appendingPathComponent("program.json"))
        var composite: [String: Any] = ["material": "m_create", "bundle": "chara/create.unity3d", "bundleSHA256": "create-hash",
                                        "serializedFile": "CAB-create", "pathID": "5", "shader": "Shader Forge/create_test",
                                        "programSHA256": programSHA, "directory": "create", "files": ["program.json", "source.metal"],
                                        "sha256": [hex(programData), hex(sourceData)]]
        composite.merge(compositeOverrides) { _, new in new }
        let url = folder.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": schemaVersion, "encoding": "linear-rgba16f-little-endian-bottom-up",
                                                    "entries": entries, "composites": extraComposite ? [composite, composite] : [composite]])
            .write(to: url)
        return Store(url: url, folder: folder)
    }

    static func input(_ name: String, pathID: String) -> SourceShaderBindingSet.TextureIdentity {
        .init(kind: .asset, name: name, bundle: "chara/inputs.unity3d", bundleSHA256: "inputs-hash", serializedFile: "CAB-inputs", pathID: pathID,
              width: 4, height: 4, mipLevels: 1)
    }

    static let color: [Float] = [0.8, 0.3, 0.2, 0.9], color2: [Float] = [0.1, 0.5, 0.9, 1], blend: Float = 0.6

    /// The composite identity as the derivation writes it (`irisComposite`).
    static func identity(size: Int = 4) -> SourceShaderBindingSet.TextureIdentity {
        func texture(_ identity: SourceShaderBindingSet.TextureIdentity) -> SourceShaderBindingSet.Texture {
            .init(identity: identity, identitySource: "synthetic", scale: [1, 1], offset: [0, 0], transformSource: "create material m_TexEnvs")
        }
        let recipe = SourceShaderBindingSet.CompositeRecipe(
            method: "synthetic ChangeSettingEye", material: "m_create", bundle: "chara/create.unity3d", bundleSHA256: "create-hash",
            serializedFile: "CAB-create", pathID: "5", shader: "Shader Forge/create_test", programSHA256: programSHA,
            textures: ["_MainTex": texture(input("main", pathID: "11")), "_ColorMask": texture(input("mask", pathID: "12"))],
            vectors: ["_Color": .init(color, source: "card"), "_Color2": .init(color2, source: "card"), "_Blend": .init([blend], source: "card"),
                      "_grad": .init([0, 0, 0, 0.5], source: "card"), "_Cutoff": .init([0.5], source: "create material m_Floats")])
        var identity = SourceShaderBindingSet.TextureIdentity(kind: .runtimeComposite, name: "", width: size, height: size,
                                                              mipLevels: 1 + Int(log2(Double(size))), creator: "synthetic iris",
                                                              filter: "Bilinear", wrap: "Clamp", aniso: 1)
        identity.composite = recipe
        return identity
    }

    /// The eye-white composite identity as the derivation writes it
    /// (`eyeWhiteComposite`): one main input and the two card colours.
    static func eyeWhiteIdentity(size: Int = 16) -> SourceShaderBindingSet.TextureIdentity {
        let recipe = SourceShaderBindingSet.CompositeRecipe(
            method: "synthetic ChangeSettingWhiteOfEye", material: "m_create", bundle: "chara/create.unity3d", bundleSHA256: "create-hash",
            serializedFile: "CAB-create", pathID: "5", shader: "Shader Forge/create_test", programSHA256: programSHA,
            textures: ["_MainTex": .init(identity: input("main", pathID: "11"), identitySource: "synthetic", scale: [1, 1], offset: [0, 0],
                                         transformSource: "create material m_TexEnvs")],
            vectors: ["_Color": .init(color, source: "card"), "_Color2": .init(color2, source: "card")])
        var identity = SourceShaderBindingSet.TextureIdentity(kind: .runtimeComposite, name: "", width: size, height: size,
                                                              mipLevels: 1 + Int(log2(Double(size))), creator: "synthetic eye white",
                                                              filter: "Bilinear", wrap: "Clamp", aniso: 1)
        identity.composite = recipe
        return identity
    }
}

/// Metal's linear filter of a bottom-up input's red channel at Unity (u, v),
/// with `repeat` or clamp-to-edge addressing (the input texture's own wrap).
private func bilinearRed(_ texels: [SIMD4<Float>], width: Int, height: Int, u: Float, v: Float, repeats: Bool) -> Float {
    let x = u * Float(width) - 0.5, y = v * Float(height) - 0.5
    let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down)), fx = x - x.rounded(.down), fy = y - y.rounded(.down)
    func at(_ column: Int, _ row: Int) -> Float {
        let i = repeats ? ((column % width) + width) % width : min(max(column, 0), width - 1)
        let j = repeats ? ((row % height) + height) % height : min(max(row, 0), height - 1)
        return texels[j * width + i].x
    }
    let a = at(x0, y0), b = at(x0 + 1, y0), c = at(x0, y0 + 1), d = at(x0 + 1, y0 + 1)
    let lower: Float = a + (b - a) * fx
    let upper: Float = c + (d - c) * fx
    return lower + (upper - lower) * fy
}

/// D3D `create_eyewhite` on one texel: `lerp(_Color2, _Color, t)` in linear
/// colour (the colours are linearized at bind) with alpha 1; pass 0 blends One Zero.
private func createEyeWhiteReference(t: Float, color: [Float], color2: [Float]) -> [Float] {
    let linear = TranslatedSourceProgram.linear
    var result: [Float] = []
    for lane in 0..<3 {
        let high = linear(color[lane]), low = linear(color2[lane])
        result.append(t * (high - low) + low)
    }
    result.append(1)
    return result
}

/// Largest byte difference between an `rgba8Unorm_srgb` level and the
/// eye-white reference over `texels` sampled with the given addressing.
private func eyeWhiteLargestError(_ bytes: [UInt8], size: Int, texels: [SIMD4<Float>], inputSize: Int, repeats: Bool,
                                  color: [Float], color2: [Float]) -> Float {
    var largest: Float = 0
    for row in 0..<size {
        for column in 0..<size {
            // Target row `row` is top-down; Unity's v runs bottom-up.
            let u = (Float(column) + 0.5) / Float(size), v = 1 - (Float(row) + 0.5) / Float(size)
            let t = bilinearRed(texels, width: inputSize, height: inputSize, u: u, v: v, repeats: repeats)
            let expected = createEyeWhiteReference(t: t, color: color, color2: color2)
            let reference = [srgbByte(expected[0]), srgbByte(expected[1]), srgbByte(expected[2]), 255]
            for lane in 0..<4 { largest = max(largest, abs(Float(bytes[(row * size + column) * 4 + lane]) - reference[lane])) }
        }
    }
    return largest
}

/// D3D `create_eye` arithmetic on one texel, then the pass blend
/// (SrcAlpha, OneMinusSrcAlpha for colour and alpha) over the cleared target.
/// `saturate` maps NaN to 0 as D3D does.
private func createEyeReference(main: SIMD4<Float>, mask: Float, color: [Float], color2: [Float], blend: Float) -> SIMD4<Float> {
    let linear = TranslatedSourceProgram.linear
    let c1 = SIMD3(linear(color[0]), linear(color[1]), linear(color[2])), c2 = SIMD3(linear(color2[0]), linear(color2[1]), linear(color2[2]))
    let c = mask * (c1 - c2) + c2, t = main.x
    func saturate(_ x: Float) -> Float { x.isNaN ? 0 : min(max(x, 0), 1) }
    var rgb = SIMD3<Float>()
    for i in 0..<3 {
        let overlay = saturate(t > 0.5 ? c[i] / ((1 - t) + (1 - t)) : 1 - ((1 - c[i]) * 0.5) / t)
        rgb[i] = blend * (overlay - t * c[i]) + c[i] * t
    }
    let a = main.w * color[3]
    return SIMD4(rgb * a, a * a)
}

private func srgbByte(_ x: Float) -> Float {
    let v = min(max(x, 0), 1)
    return ((v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255).rounded()
}

/// RGBA8 bytes of one level of a (private) texture, top-down rows.
private func readback(_ texture: any MTLTexture, level: Int, device: any MTLDevice) throws -> [UInt8] {
    try autoreleasepool { try readbackLevel(texture, level: level, device: device) }
}

private func readbackLevel(_ texture: any MTLTexture, level: Int, device: any MTLDevice) throws -> [UInt8] {
    let width = max(1, texture.width >> level), height = max(1, texture.height >> level)
    let buffer = try #require(device.makeBuffer(length: width * height * 4, options: .storageModeShared))
    let queue = try #require(device.makeCommandQueue()), command = try #require(queue.makeCommandBuffer())
    let blit = try #require(command.makeBlitCommandEncoder())
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
              to: buffer, destinationOffset: 0, destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: width * height * 4))
}

private func srgbToLinear(_ byte: UInt8) -> Float { TranslatedSourceProgram.linear(Float(byte) / 255) }

/// Literal expected states pin the legacy sampler contract independently of
/// the cache key. In particular Point still enables linear mip filtering when
/// anisotropic, and Disable does not change Trilinear's linear mip filter.
@Test
func liveSourceSamplerConfigurationPreservesTheDescriptorContract() {
    typealias Configuration = TranslatedSourceProgram.SamplerConfiguration
    struct Case {
        let filter: String?, wrap: String?, aniso: Int?, quality: String?
        let minMag: MTLSamplerMinMagFilter, mip: MTLSamplerMipFilter
        let address: MTLSamplerAddressMode, effectiveAniso: Int
    }
    let cases: [Case] = [
        .init(filter: nil, wrap: nil, aniso: nil, quality: nil, minMag: .linear, mip: .nearest, address: .repeat, effectiveAniso: 1),
        .init(filter: "unknown", wrap: "unknown", aniso: 0, quality: "unknown", minMag: .linear, mip: .nearest, address: .repeat, effectiveAniso: 1),
        .init(filter: "Bilinear", wrap: "Clamp", aniso: -1, quality: nil, minMag: .linear, mip: .nearest, address: .clampToEdge, effectiveAniso: 1),
        .init(filter: "Point", wrap: "Repeat", aniso: 1, quality: nil, minMag: .nearest, mip: .nearest, address: .repeat, effectiveAniso: 1),
        .init(filter: "Trilinear", wrap: "Clamp", aniso: 1, quality: nil, minMag: .linear, mip: .linear, address: .clampToEdge, effectiveAniso: 1),
        .init(filter: "Bilinear", wrap: "Clamp", aniso: 8, quality: nil, minMag: .linear, mip: .linear, address: .clampToEdge, effectiveAniso: 8),
        .init(filter: "Bilinear", wrap: "Clamp", aniso: 9, quality: nil, minMag: .linear, mip: .linear, address: .clampToEdge, effectiveAniso: 9),
        .init(filter: "Bilinear", wrap: "Clamp", aniso: 16, quality: nil, minMag: .linear, mip: .linear, address: .clampToEdge, effectiveAniso: 16),
        .init(filter: "Point", wrap: "Clamp", aniso: Int.max, quality: nil, minMag: .nearest, mip: .linear, address: .clampToEdge, effectiveAniso: 16),
        .init(filter: "Point", wrap: "Clamp", aniso: Int.min, quality: nil, minMag: .nearest, mip: .nearest, address: .clampToEdge, effectiveAniso: 1),
        .init(filter: "Point", wrap: "Clamp", aniso: 8, quality: "Disable", minMag: .nearest, mip: .nearest, address: .clampToEdge, effectiveAniso: 1),
        .init(filter: "Trilinear", wrap: "Clamp", aniso: Int.max, quality: "Disable", minMag: .linear, mip: .linear, address: .clampToEdge, effectiveAniso: 1),
        .init(filter: "Bilinear", wrap: "Repeat", aniso: 8, quality: "Disable", minMag: .linear, mip: .nearest, address: .repeat, effectiveAniso: 1),
        .init(filter: "Bilinear", wrap: "Clamp", aniso: nil, quality: "ForceEnable", minMag: .linear, mip: .nearest, address: .clampToEdge, effectiveAniso: 1),
        .init(filter: "Bilinear", wrap: "Clamp", aniso: Int.min, quality: "ForceEnable", minMag: .linear, mip: .nearest, address: .clampToEdge, effectiveAniso: 1),
        .init(filter: "Bilinear", wrap: "Clamp", aniso: 0, quality: "ForceEnable", minMag: .linear, mip: .nearest, address: .clampToEdge, effectiveAniso: 1),
        .init(filter: "Bilinear", wrap: "Clamp", aniso: 1, quality: "ForceEnable", minMag: .linear, mip: .linear, address: .clampToEdge, effectiveAniso: 9),
        .init(filter: "Bilinear", wrap: "Clamp", aniso: 8, quality: "ForceEnable", minMag: .linear, mip: .linear, address: .clampToEdge, effectiveAniso: 9),
        .init(filter: "Bilinear", wrap: "Clamp", aniso: Int.max, quality: "ForceEnable", minMag: .linear, mip: .linear, address: .clampToEdge, effectiveAniso: 16),
        .init(filter: "Point", wrap: "Clamp", aniso: 1, quality: "ForceEnable", minMag: .nearest, mip: .nearest, address: .clampToEdge, effectiveAniso: 1),
        .init(filter: "Point", wrap: "Clamp", aniso: 8, quality: "ForceEnable", minMag: .nearest, mip: .linear, address: .clampToEdge, effectiveAniso: 8),
        .init(filter: "unknown", wrap: "unknown", aniso: 1, quality: "ForceEnable", minMag: .linear, mip: .linear, address: .repeat, effectiveAniso: 9),
    ]
    var configurations: [Configuration] = []
    for item in cases {
        let configuration = Configuration(filter: item.filter, wrap: item.wrap, aniso: item.aniso, anisotropicFiltering: item.quality)
        #expect(configuration.minFilter == item.minMag && configuration.magFilter == item.minMag)
        #expect(configuration.mipFilter == item.mip && configuration.maxAnisotropy == item.effectiveAniso)
        #expect(configuration.sAddressMode == item.address && configuration.tAddressMode == item.address)
        // Exercise the existing public API too: unrelated descriptor defaults
        // stay at their Metal defaults, not new cache-specific values.
        let descriptor = TranslatedSourceProgram.samplerDescriptor(filter: item.filter, wrap: item.wrap, aniso: item.aniso, anisotropicFiltering: item.quality)
        let defaults = MTLSamplerDescriptor()
        #expect(descriptor.minFilter == item.minMag && descriptor.magFilter == item.minMag)
        #expect(descriptor.mipFilter == item.mip && descriptor.maxAnisotropy == item.effectiveAniso)
        #expect(descriptor.sAddressMode == item.address && descriptor.tAddressMode == item.address)
        #expect(descriptor.rAddressMode == defaults.rAddressMode && descriptor.compareFunction == defaults.compareFunction)
        #expect(descriptor.normalizedCoordinates == defaults.normalizedCoordinates)
        #expect(descriptor.lodMinClamp == defaults.lodMinClamp && descriptor.lodMaxClamp == defaults.lodMaxClamp)
        configurations.append(configuration)
    }
    // Equality and hashing use effective state, including address and mip
    // modes. These two raw states normalize to the same default sampler.
    #expect(configurations[0] == configurations[1])
    #expect(Set([configurations[0], configurations[1]]).count == 1)
    #expect(Set([configurations[2], configurations[3], configurations[4], configurations[5]]).count == 4)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceCompositeSharesNormalizedSamplersButKeepsRawInputIdentity() throws {
    let device = try #require(MTLCreateSystemDefaultDevice()), fixture = try CompositeStoreFixture.write()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = try SourceShaderTextureStore(url: fixture.url), resources = ResourceStore(device: device)
    // Complete overrides are required: partial input sampler state falls back
    // to the store entry as a unit. All three inputs below mean linear/clamp/1.
    let variants: [(String, Int)] = [("Bilinear", 1), ("Bilinear", 0), ("unknown", -1)]
    var targets: [any MTLTexture] = [], keys: Set<String> = []
    for (filter, aniso) in variants {
        var identity = CompositeStoreFixture.identity()
        identity.composite?.textures["_MainTex"]?.identity?.filter = filter
        identity.composite?.textures["_MainTex"]?.identity?.wrap = "Clamp"
        identity.composite?.textures["_MainTex"]?.identity?.aniso = aniso
        let request = SourceShaderLiveTextureRequest(identity: identity, property: "_MainTex", mesh: nil, slot: nil)
        let target = try store.texture(request, resources: resources).get().texture
        let event = try #require(store.compositeEvents().last)
        #expect(!event.cacheHit && keys.insert(event.contentKey).inserted)
        #expect(targets.allSatisfy { $0 !== target })
        targets.append(target)
        #expect(try store.texture(request, resources: resources).get().texture === target)
        #expect(store.compositeInputStatistics(for: resources) == .init(defaults: 0, samplers: 1))
        #expect(resources.statistics().textures == 2)
    }
    let first = try readback(targets[0], level: 0, device: device)
    for target in targets.dropFirst() { #expect(try readback(target, level: 0, device: device) == first) }
    // Request-level quality changes the effective state, adding exactly one
    // sampler. Repeating it must reuse both the target and that sampler.
    let forced = SourceShaderLiveTextureRequest(identity: CompositeStoreFixture.identity(), property: "_MainTex", mesh: nil, slot: nil,
                                               anisotropicFiltering: "ForceEnable")
    let forcedTarget = try store.texture(forced, resources: resources).get().texture
    #expect(keys.insert(try #require(store.compositeEvents().last?.contentKey)).inserted)
    #expect(store.compositeInputStatistics(for: resources) == .init(defaults: 0, samplers: 2))
    #expect(try store.texture(forced, resources: resources).get().texture === forcedTarget)
    #expect(store.compositeInputStatistics(for: resources) == .init(defaults: 0, samplers: 2))
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceCompositeConcurrentMissesShareWithinEachOwner() throws {
    final class Results: @unchecked Sendable {
        let lock = NSLock()
        var values: [(Int, SourceShaderLiveTexture)] = []
        func append(_ value: SourceShaderLiveTexture, owner: Int) {
            lock.lock(); defer { lock.unlock() }; values.append((owner, value))
        }
    }
    let device = try #require(MTLCreateSystemDefaultDevice()), fixture = try CompositeStoreFixture.write()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = try SourceShaderTextureStore(url: fixture.url), owners = [ResourceStore(device: device), ResourceStore(device: device)]
    let request = SourceShaderLiveTextureRequest(identity: CompositeStoreFixture.identity(), property: "_MainTex", mesh: nil, slot: nil)
    let results = Results()
    DispatchQueue.concurrentPerform(iterations: 16) { index in
        do { results.append(try store.texture(request, resources: owners[index % 2]).get(), owner: index % 2) }
        catch { Issue.record(error) }
    }
    #expect(results.values.count == 16)
    let first = try #require(results.values.first { $0.0 == 0 }?.1.texture)
    let second = try #require(results.values.first { $0.0 == 1 }?.1.texture)
    #expect(first !== second && first.device === device && second.device === device)
    for (owner, value) in results.values { #expect(value.texture === (owner == 0 ? first : second)) }
    for owner in owners {
        #expect(store.compositeInputStatistics(for: owner) == .init(defaults: 0, samplers: 1))
        #expect(owner.statistics().textures == 2)
    }
    let events = store.compositeEvents()
    #expect(events.filter { !$0.cacheHit }.count == 2 && events.filter(\.cacheHit).count == 14)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceCompositeMatchesTheCreateEyeReferenceAndBuildsTheMipChain() throws {
    let device = try #require(MTLCreateSystemDefaultDevice()), resources = ResourceStore(device: device)
    let fixture = try CompositeStoreFixture.write()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = try SourceShaderTextureStore(url: fixture.url)
    let identity = CompositeStoreFixture.identity()
    let result = try store.texture(.init(identity: identity, property: "_MainTex", mesh: "iris", slot: 0), resources: resources).get()
    let texture = result.texture
    #expect(texture.width == 4 && texture.height == 4 && texture.mipmapLevelCount == 3 && texture.pixelFormat == .rgba8Unorm_srgb)
    #expect(result.provenance.hasPrefix("composite m_create 4x4 ["), "\(result.provenance)")
    #expect(result.provenance.contains("_MainTex=chara/inputs.unity3d#11") && result.provenance.contains("_ColorMask=chara/inputs.unity3d#12"))
    // Composites are owned by their materials, never registered in the resource store.
    #expect(resources.statistics().textures == 2)
    let base = try readback(texture, level: 0, device: device)
    var largest: Float = 0
    for row in 0..<4 {
        for column in 0..<4 {
            // Target row `row` (top-down) is Unity row 3 − row, which samples input row 3 − row.
            let source = (3 - row) * 4 + column
            let expected = createEyeReference(main: CompositeStoreFixture.main[source], mask: CompositeStoreFixture.mask[source].x,
                                              color: CompositeStoreFixture.color, color2: CompositeStoreFixture.color2, blend: CompositeStoreFixture.blend)
            let bytes = (0..<4).map { Float(base[(row * 4 + column) * 4 + $0]) }
            let reference = [srgbByte(expected.x), srgbByte(expected.y), srgbByte(expected.z), (min(max(expected.w, 0), 1) * 255).rounded()]
            for lane in 0..<4 { largest = max(largest, abs(bytes[lane] - reference[lane])) }
        }
    }
    #expect(largest <= 1, "largest byte difference \(largest)")
    // The chain is filled (Unity's autoGenerateMips): each level is the box
    // average of the one above in linear colour.
    for level in 1..<3 {
        let upper = try readback(texture, level: level - 1, device: device), lower = try readback(texture, level: level, device: device)
        let width = 4 >> level, upperWidth = 4 >> (level - 1)
        var mipLargest: Float = 0
        for row in 0..<width {
            for column in 0..<width {
                for lane in 0..<4 {
                    let samples = [(0, 0), (0, 1), (1, 0), (1, 1)].map { upper[((row * 2 + $0.0) * upperWidth + column * 2 + $0.1) * 4 + lane] }
                    let mean = lane == 3 ? samples.map { Float($0) / 255 }.reduce(0, +) / 4 : samples.map(srgbToLinear).reduce(0, +) / 4
                    let expected = lane == 3 ? (mean * 255).rounded() : srgbByte(mean)
                    mipLargest = max(mipLargest, abs(Float(lower[(row * width + column) * 4 + lane]) - expected))
                }
            }
        }
        #expect(mipLargest <= 2, "mip \(level) largest byte difference \(mipLargest)")
    }
    let events = store.compositeEvents()
    #expect(events.count == 1 && events[0].cacheHit == false && events[0].statistics?.bytes ?? 0 > 0)
    #expect(events[0].statistics?.pipelineCompiled == true)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceCompositeMapsTheUndefinedOverlayToZeroLikeD3D() throws {
    // t = 0 with c = 1 divides 0 by 0 in the overlay's low branch; D3D's
    // saturate returns 0 for NaN, so the texel is `c·t` = 0 for any _Blend.
    let device = try #require(MTLCreateSystemDefaultDevice()), resources = ResourceStore(device: device)
    let fixture = try CompositeStoreFixture.write()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let mainURL = fixture.folder.appendingPathComponent("main/level-0.rgba16f")
    let texels: [Float16] = Array(Array(repeating: [Float16(0), 0, 0, 1], count: 16).joined())
    let pixels = texels.withUnsafeBytes { Data($0) }
    try pixels.write(to: mainURL)
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any])
    var entries = try #require(manifest["entries"] as? [[String: Any]])
    entries[0]["sha256"] = [hex(pixels)]; manifest["entries"] = entries
    try JSONSerialization.data(withJSONObject: manifest).write(to: fixture.url)
    var identity = CompositeStoreFixture.identity()
    identity.composite?.vectors["_Color"] = .init([1, 1, 1, 1], source: "synthetic")
    identity.composite?.vectors["_Color2"] = .init([1, 1, 1, 1], source: "synthetic")
    identity.composite?.vectors["_Blend"] = .init([1], source: "synthetic")
    let texture = try SourceShaderTextureStore(url: fixture.url).texture(.init(identity: identity, property: "_MainTex", mesh: nil, slot: nil),
                                                                        resources: resources).get().texture
    let bytes = try readback(texture, level: 0, device: device)
    let opaqueBlack: [UInt8] = [0, 0, 0, 255]
    let texelsAreOpaqueBlack = stride(from: 0, to: bytes.count, by: 4).allSatisfy { (offset: Int) -> Bool in
        Array(bytes[offset ..< offset + 4]) == opaqueBlack
    }
    #expect(texelsAreOpaqueBlack, "\(Array(bytes.prefix(8)))")
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceCompositeCacheKeysEveryInputAndReleasesWithItsOwner() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fixture = try CompositeStoreFixture.write()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = try SourceShaderTextureStore(url: fixture.url)
    let resources = ResourceStore(device: device)
    func compose(_ identity: SourceShaderBindingSet.TextureIdentity, anisotropicFiltering: String? = nil, in owner: ResourceStore? = nil) throws -> any MTLTexture {
        try store.texture(.init(identity: identity, property: "_MainTex", mesh: nil, slot: nil, anisotropicFiltering: anisotropicFiltering),
                          resources: owner ?? resources).get().texture
    }
    let base = CompositeStoreFixture.identity()
    // Only this array holds composites strongly (as materials would).
    var textures: [any MTLTexture] = [try compose(base)]
    #expect(try compose(base) === textures[0])
    #expect(store.compositeEvents().map(\.cacheHit) == [false, true])

    var changed: [(String, SourceShaderBindingSet.TextureIdentity, String?)] = []
    func variant(_ label: String, anisotropicFiltering: String? = nil, _ edit: (inout SourceShaderBindingSet.CompositeRecipe) -> Void) {
        var identity = base; edit(&identity.composite!); changed.append((label, identity, anisotropicFiltering))
    }
    variant("_Color") { $0.vectors["_Color"] = .init([0.8, 0.3, 0.21, 0.9], source: "edit") }
    variant("_Color alpha") { $0.vectors["_Color"] = .init([0.8, 0.3, 0.2, 0.8], source: "edit") }
    variant("_Color2") { $0.vectors["_Color2"] = .init([0.1, 0.5, 0.8, 1], source: "edit") }
    variant("_Blend") { $0.vectors["_Blend"] = .init([0.61], source: "edit") }
    variant("_grad") { $0.vectors["_grad"] = .init([0, 0.25, 0, 0.5], source: "edit") }
    variant("_MainTex_ST") { $0.textures["_MainTex"]?.scale = [2, 1] }
    variant("_ColorMask_ST") { $0.textures["_ColorMask"]?.offset = [0.25, 0] }
    variant("main texture") { $0.textures["_MainTex"]?.identity = CompositeStoreFixture.input("main2", pathID: "13") }
    variant("mask texture") { $0.textures["_ColorMask"]?.identity = CompositeStoreFixture.input("main2", pathID: "13") }
    variant("default mask") { $0.textures["_ColorMask"]?.identity = nil }
    variant("input sampler", anisotropicFiltering: "ForceEnable") { _ in }
    var size = base; size.width = 8; size.height = 8; size.mipLevels = 4
    changed.append(("target size", size, nil))
    var keys = Set([store.compositeEvents()[0].contentKey])
    for (label, identity, filtering) in changed {
        let texture = try compose(identity, anisotropicFiltering: filtering)
        let event = try #require(store.compositeEvents().last)
        #expect(event.cacheHit == false && keys.insert(event.contentKey).inserted, "\(label) must change the content key")
        #expect(textures.allSatisfy { $0 !== texture }, "\(label) must compose a new target")
        textures.append(texture)
    }
    // A colour edit changes pixels, not only the key.
    #expect(try readback(textures[0], level: 0, device: device) != readback(textures[1], level: 0, device: device))
    // Another resource owner composes its own target.
    let other = ResourceStore(device: device)
    #expect(try compose(base, in: other) !== textures[0])
    // Released with its owner: once no material holds the composite, the
    // cache does not keep it alive and the next request composes again.
    weak var released = textures[0]
    textures.removeAll()
    #expect(released == nil)
    let before = store.compositeEvents().count
    _ = try compose(base)
    #expect(store.compositeEvents().count == before + 1 && store.compositeEvents().last?.cacheHit == false)
    // One pipeline per program and resource owner.
    #expect(store.compositeEvents().filter { $0.statistics?.pipelineCompiled == true }.count == 2)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceCompositeReusesDefaultsAndSamplersWithoutRetainingResourceOwners() throws {
    let device = try #require(MTLCreateSystemDefaultDevice()), fixture = try CompositeStoreFixture.write()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = try SourceShaderTextureStore(url: fixture.url)
    var identity = CompositeStoreFixture.identity()
    identity.composite?.textures["_ColorMask"]?.identity = nil
    let request = SourceShaderLiveTextureRequest(identity: identity, property: "_MainTex", mesh: nil, slot: nil)
    var owner: ResourceStore? = ResourceStore(device: device)
    weak var weakOwner = owner
    let target = try store.texture(request, resources: owner!).get().texture
    let statistics = store.compositeInputStatistics(for: owner!)
    // The asset clamps; the Unity default repeats, so there are two samplers.
    #expect(statistics == .init(defaults: 1, samplers: 2))
    let registered = owner!.statistics().textures
    for _ in 0..<20 {
        #expect(try store.texture(request, resources: owner!).get().texture === target)
        #expect(store.compositeInputStatistics(for: owner!) == statistics)
        #expect(owner!.statistics().textures == registered)
    }
    // Editing and reverting use the same fixed input objects; only the
    // changed recipe needs a new target, which the materials own.
    var edited = identity
    edited.composite?.vectors["_Color"] = .init([0.1, 0.8, 0.3, 1], source: "edit")
    let other = try store.texture(.init(identity: edited, property: "_MainTex", mesh: nil, slot: nil), resources: owner!).get().texture
    #expect(other !== target && store.compositeInputStatistics(for: owner!) == statistics)
    #expect(try store.texture(request, resources: owner!).get().texture === target)
    owner = nil
    #expect(weakOwner == nil)
    let next = ResourceStore(device: device)
    #expect(store.compositeInputStatistics(for: next) == .init(defaults: 0, samplers: 0))
    #expect(try store.texture(request, resources: next).get().texture !== target)
    #expect(store.compositeInputStatistics(for: next) == statistics)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceCompositeKeepsAnExplicitReasonForEveryMissingInput() throws {
    let device = try #require(MTLCreateSystemDefaultDevice()), resources = ResourceStore(device: device)
    let fixture = try CompositeStoreFixture.write()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = try SourceShaderTextureStore(url: fixture.url)
    let base = CompositeStoreFixture.identity()
    var cases: [(SourceShaderBindingSet.TextureIdentity, String)] = []
    func reason(_ expected: String, _ edit: (inout SourceShaderBindingSet.TextureIdentity) -> Void) {
        var identity = base; edit(&identity); cases.append((identity, expected))
    }
    reason("runtime composite synthetic iris is not composed natively for the live path") { $0.composite = nil }
    reason("runtime composite m_create: create material not converted") { $0.composite?.unresolved = "create material not converted" }
    reason("runtime composite m_create: input _ColorMask: chara/inputs.unity3d is not in the native texture store (mask)") {
        $0.composite?.textures["_ColorMask"]?.identity?.pathID = "99"
    }
    reason("runtime composite m_create: input _MainTex: mt_eye row 7 has no texture") {
        $0.composite?.textures["_MainTex"]?.identity = nil; $0.composite?.textures["_MainTex"]?.identityUnresolved = "mt_eye row 7 has no texture"
    }
    reason("runtime composite m_create: input _ColorMask not derived") { $0.composite?.textures["_ColorMask"] = nil }
    reason("runtime composite m_create: input _MainTex is itself a runtime composite (not modelled)") {
        $0.composite?.textures["_MainTex"]?.identity = CompositeStoreFixture.identity()
    }
    reason("runtime composite m_create: _Color: card lacks face.pupil.0.baseColor") {
        $0.composite?.vectors["_Color"] = .init(unresolved: "card lacks face.pupil.0.baseColor")
    }
    reason("runtime composite m_create: _Blend not derived") { $0.composite?.vectors["_Blend"] = nil }
    reason("runtime composite m_create: _MainTex_ST not derived") { $0.composite?.textures["_MainTex"]?.scale = nil }
    reason("runtime composite m_create: create program \(String(repeating: "d", count: 64)) is not in the native texture store") {
        $0.composite?.programSHA256 = String(repeating: "d", count: 64)
    }
    reason("runtime composite m_create: store create program comes from a different chara/create.unity3d") { $0.composite?.bundleSHA256 = "other" }
    reason("runtime composite m_create: store create program identity differs from the recipe") { $0.composite?.shader = "Shader Forge/create_eye" }
    reason("runtime composite m_create: target size not derived") { $0.width = nil }
    for (identity, expected) in cases {
        let result = store.texture(.init(identity: identity, property: "_MainTex", mesh: nil, slot: nil), resources: resources)
        guard case .failure(let failure) = result else { Issue.record("expected \(expected)"); continue }
        #expect(failure.text == expected)
    }
    #expect(store.compositeEvents().isEmpty)
    // A changed program file is caught before compilation.
    let damaged = try SourceShaderTextureStore(url: fixture.url)
    try Data((CompositeStoreFixture.source + "\n").utf8).write(to: fixture.folder.appendingPathComponent("create/source.metal"))
    guard case .failure(let failure) = damaged.texture(.init(identity: base, property: "_MainTex", mesh: nil, slot: nil), resources: resources) else {
        Issue.record("a damaged program must not compose"); return
    }
    #expect(failure.text == "runtime composite m_create: create program source.metal does not match its SHA-256")
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceMaterialsBindComposedTargetsOrFallBackWithTheCompositeReason() throws {
    let device = try #require(MTLCreateSystemDefaultDevice()), resources = ResourceStore(device: device)
    let fixture = try CompositeStoreFixture.write()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = try SourceShaderTextureStore(url: fixture.url)
    let programs = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: programs) }
    try LiveProgramFixture.write(LiveProgramFixture.lineSpec(outline: false), family: "toon_test", to: programs)
    var material = liveMaterial(shader: "Shader Forge/toon_test")
    material.textures["_MainTex"]?.identity = CompositeStoreFixture.identity()
    let bindings = BindingSet(scope: "synthetic", globalVectors: ["_RampG_ST": .init([1, 1, 0, 0], source: "synthetic")])
    let renderer = BindingSet.Renderer(mesh: "iris", component: "synthetic", materialSlot: 0, submesh: 0, visible: true, visibility: "enabled", material: material)
    let live = try SourceShaderLiveMaterial.resolve(renderer: renderer, bindings: bindings, programs: programs, resources: resources,
                                                    textures: store, anisotropicFiltering: nil)
    #expect(live.textureSources["_MainTex"]?.hasPrefix("composite m_create 4x4") == true)
    let bound = try #require(live.textures["_MainTex"])
    #expect(bound.texture.pixelFormat == .rgba8Unorm_srgb && bound.texture.mipmapLevelCount == 3)
    var missing = material
    missing.textures["_MainTex"]?.identity?.composite?.textures["_ColorMask"]?.identity?.pathID = "99"
    let fallback = BindingSet.Renderer(mesh: "iris", component: "synthetic", materialSlot: 0, submesh: 0, visible: true, visibility: "enabled", material: missing)
    #expect(throws: SourceShaderLiveReason("texture _MainTex: runtime composite m_create: input _ColorMask: chara/inputs.unity3d is not in the native texture store (mask)")) {
        _ = try SourceShaderLiveMaterial.resolve(renderer: fallback, bindings: bindings, programs: programs, resources: resources,
                                                 textures: store, anisotropicFiltering: nil)
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceCompositeProgramsAreFragmentOnlyAndValidated() throws {
    let device = try #require(MTLCreateSystemDefaultDevice()), resources = ResourceStore(device: device)
    let fixture = try CompositeStoreFixture.write()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let createURL = fixture.folder.appendingPathComponent("create/program.json")
    let create = try TranslatedSourceProgram(url: createURL, fragmentOnly: true)
    #expect(create.fragmentOnly && create.vertex.constantBuffers.isEmpty && create.fragmentInputs.map(\.semantic) == ["SV_POSITION", "TEXCOORD"])
    #expect(throws: TranslatedSourceProgram.ProgramError.self) { _ = try TranslatedSourceProgram(url: createURL) }
    #expect(throws: TranslatedSourceProgram.ProgramError.self) { _ = try resources.translatedPipelines.entry(create, target: .probe) }
    let programs = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: programs) }
    let drawURL = try LiveProgramFixture.write(LiveProgramFixture.uv, family: "toon_uv", to: programs)
    #expect(throws: TranslatedSourceProgram.ProgramError.self) { _ = try TranslatedSourceProgram(url: drawURL, fragmentOnly: true) }
    #expect(throws: TranslatedSourceProgram.ProgramError.self) {
        _ = try SourceShaderCompositor(device: device).pipeline(for: try TranslatedSourceProgram(url: drawURL))
    }
    // The Blit quad supplies only SV_POSITION and TEXCOORD0.
    var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: createURL)) as? [String: Any])
    var stages = try #require(root["programs"] as? [String: Any]), fragment = try #require(stages["fragment"] as? [String: Any])
    fragment["inputSemantics"] = ["0": ["name": "SV_POSITION", "index": 0], "1": ["name": "TEXCOORD", "index": 1]]
    stages["fragment"] = fragment; root["programs"] = stages
    try JSONSerialization.data(withJSONObject: root).write(to: createURL)
    #expect(throws: TranslatedSourceProgram.ProgramError.self) { _ = try SourceShaderCompositor.blitVertexSource(try TranslatedSourceProgram(url: createURL, fragmentOnly: true)) }

    // Manifests: composites need schema 2, the exact file pair, a safe
    // directory of their own and one entry per program.
    for (schema, overrides, duplicate) in [(1, [:], false), (2, ["files": ["program.json"], "sha256": [String(repeating: "0", count: 64)]], false),
                                           (2, ["directory": "../create"], false), (2, ["directory": "main"], false),
                                           (2, ["programSHA256": "short"], false), (2, [:], true)] as [(Int, [String: Any], Bool)] {
        let bad = try CompositeStoreFixture.write(schemaVersion: schema, compositeOverrides: overrides, extraComposite: duplicate)
        defer { try? FileManager.default.removeItem(at: bad.folder) }
        #expect(throws: SourceShaderLiveReason.self) { _ = try SourceShaderTextureStore(url: bad.url) }
    }
    let good = try SourceShaderTextureStore(url: fixture.url)
    #expect(good.manifest.composites?.count == 1)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func liveSourceEyeWhiteCompositeMatchesTheReferenceWithTheInputsOwnSampler() throws {
    // `create_eyewhite` magnifies its input (8×8 in the game, 4×4 here) with
    // the input texture's own sampler: Repeat for `cw_t_sirome_kage_000`, so
    // the edge texels blend with the opposite edge. Pass 0 blends One Zero,
    // so the target's alpha is 1 whatever the input's alpha.
    let device = try #require(MTLCreateSystemDefaultDevice()), resources = ResourceStore(device: device)
    var keys: [String] = []
    var levels: [[UInt8]] = []
    for repeats in [true, false] {
        let fixture = try CompositeStoreFixture.write(program: CompositeStoreFixture.eyeWhite, mainWrap: repeats ? "Repeat" : "Clamp")
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = try SourceShaderTextureStore(url: fixture.url)
        let result = try store.texture(.init(identity: CompositeStoreFixture.eyeWhiteIdentity(), property: "_MainTex", mesh: "eye white", slot: 0),
                                       resources: resources).get()
        #expect(result.texture.width == 16 && result.texture.mipmapLevelCount == 5 && result.texture.pixelFormat == .rgba8Unorm_srgb)
        #expect(result.provenance.contains("_MainTex=chara/inputs.unity3d#11"), "\(result.provenance)")
        let bytes = try readback(result.texture, level: 0, device: device)
        levels.append(bytes)
        let largest = eyeWhiteLargestError(bytes, size: 16, texels: CompositeStoreFixture.main, inputSize: 4, repeats: repeats,
                                           color: CompositeStoreFixture.color, color2: CompositeStoreFixture.color2)
        #expect(largest <= 1, "\(repeats ? "Repeat" : "Clamp"): largest byte difference \(largest)")
        // The other addressing mode is a mutation control: it must not match.
        let other = eyeWhiteLargestError(bytes, size: 16, texels: CompositeStoreFixture.main, inputSize: 4, repeats: !repeats,
                                         color: CompositeStoreFixture.color, color2: CompositeStoreFixture.color2)
        #expect(other > 8, "the \(repeats ? "Clamp" : "Repeat") reference must differ, got \(other)")
        keys += store.compositeEvents().map(\.contentKey)
    }
    // The input sampler is part of the content key.
    #expect(keys.count == 2 && keys[0] != keys[1])
    #expect(levels[0] != levels[1])
}

// MARK: - Controlled original fixture (private data)

/// Composes the fixture card's irises (`ctCreateEyeL`/`R`) from the private
/// store and compares level 0 with the retained original composite readback
/// (`texture-21`/`texture-24`: `Graphics.Blit` of the ARGB32 target into
/// ARGBHalf, bottom-up, base level only). The fixture's iris is black
/// (`_Color` [0, 0, 0, 1]) over a white sub colour with `_Blend` 0, so the
/// oracle checks coverage (alpha²), orientation and the blend, not the
/// overlay colours; the same real translated program is then checked against
/// the CPU reference with synthetic, non-degenerate colours.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SHADER_BINDING_PROBE", "IKKOKU_MAKER_LIBRARY", "IKKOKU_HEAD_MATERIAL_CONTRACT",
    "IKKOKU_SHADER_BINDING_SUPPLEMENT", "IKKOKU_LIVE_SOURCE_TEXTURES"])))
func liveSourceIrisCompositesMatchTheRetainedOriginalComposites() throws {
    let folder = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_PROBE"), isDirectory: true)
    let inputs = SourceShaderLiveAssembly.Inputs(programs: folder.appendingPathComponent("shaders"),
        makerLibrary: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")),
        headContract: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_HEAD_MATERIAL_CONTRACT")),
        supplement: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_SUPPLEMENT")))
    let card = try SourceCharacterCard.load(url: folder.appendingPathComponent("fixture-card.png"))
    let bindings = try inputs.derive(card: card, scene: .originalCharacterProbeHarness, sceneReason: "", eyeLook: nil)
    let frameURL = folder.appendingPathComponent("frame-mips.json")
    let frame = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: frameURL)) as? [String: Any])
    let store = try SourceShaderTextureStore(url: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_LIVE_SOURCE_TEXTURES")))
    let device = try #require(MTLCreateSystemDefaultDevice()), resources = ResourceStore(device: device)
    var irises: [any MTLTexture] = []
    for (mesh, capture) in [("cf_Ohitomi_L02", "texture-21.rgba16f"), ("cf_Ohitomi_R02", "texture-24.rgba16f")] {
        let renderer = try #require(bindings.renderers.first { $0.mesh == mesh && $0.materialSlot == 0 })
        let identity = try #require(renderer.material.textures["_MainTex"]?.identity)
        let recipe = try #require(identity.composite)
        #expect(recipe.material == "cf_m_eye_create" && recipe.programSHA256 == "c4bd7e1ec704b84075a666316519230ce163e1f4540be2af7ed25b9f3934fece")
        #expect(identity.width == 512 && identity.height == 512 && identity.mipLevels == 10)
        let texture = try store.texture(.init(identity: identity, property: "_MainTex", mesh: mesh, slot: 0,
                                              anisotropicFiltering: frame["anisotropicFiltering"] as? String), resources: resources).get().texture
        irises.append(texture)
        let ours = try readback(texture, level: 0, device: device)
        let original = try Data(contentsOf: folder.appendingPathComponent(capture)).withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        #expect(original.count == 512 * 512 * 4)
        var linearLargest: Float = 0, byteLargest: Float = 0, differing = 0, total: Double = 0
        for row in 0..<512 {
            for column in 0..<512 {
                let target = (row * 512 + column) * 4, source = ((511 - row) * 512 + column) * 4   // capture rows are bottom-up
                for lane in 0..<4 {
                    let reference = Float(original[source + lane])
                    let value = lane == 3 ? Float(ours[target + lane]) / 255 : srgbToLinear(ours[target + lane])
                    let referenceByte = lane == 3 ? (min(max(reference, 0), 1) * 255).rounded() : srgbByte(reference)
                    let byteError = abs(Float(ours[target + lane]) - referenceByte)
                    linearLargest = max(linearLargest, abs(value - reference)); byteLargest = max(byteLargest, byteError)
                    if byteError > 0 { differing += 1 }
                    total += Double(abs(value - reference))
                }
            }
        }
        print("[iris composite] \(mesh) vs \(capture): max |linear| \(linearLargest), max byte \(byteLargest), \(differing) differing channels, mean |linear| \(total / Double(512 * 512 * 4))")
        #expect(byteLargest <= 1, "\(mesh): largest byte difference \(byteLargest)")
    }
    // Both eyes have one recipe on the fixture card: one composite is shared.
    #expect(irises[0] === irises[1])
    print("[iris composite] events " + store.compositeEvents().map { event in
        "\(event.cacheHit ? "hit" : "composed") \(event.contentKey.prefix(12))" + (event.statistics.map {
            String(format: " cpu %.3f ms gpu %.3f ms total %.3f ms compiled %@ %d bytes", $0.cpuEncodeMilliseconds, $0.gpuMilliseconds,
                   $0.totalMilliseconds, $0.pipelineCompiled ? "yes" : "no", $0.bytes) } ?? "")
    }.joined(separator: "; "))

    // The real translated program against the CPU reference, with colours
    // that exercise both overlay branches and the gradient lerp. `_grad.w`
    // 0.5 maps the mask 1:1 (512 → 512), so every sample is an exact texel.
    var identity = try #require(bindings.renderers.first { $0.mesh == "cf_Ohitomi_L02" }?.material.textures["_MainTex"]?.identity)
    identity.composite?.vectors["_Color"] = .init([0.8, 0.3, 0.2, 0.9], source: "synthetic")
    identity.composite?.vectors["_Color2"] = .init([0.1, 0.5, 0.9, 1], source: "synthetic")
    identity.composite?.vectors["_Blend"] = .init([0.6], source: "synthetic")
    identity.composite?.vectors["_grad"] = .init([0, 0, 0, 0.5], source: "synthetic")
    let synthetic = try store.texture(.init(identity: identity, property: "_MainTex", mesh: nil, slot: nil), resources: resources).get().texture
    let bytes = try readback(synthetic, level: 0, device: device)
    func level(_ textureIdentity: SourceShaderBindingSet.TextureIdentity?) throws -> [Float16] {
        let entry = try store.entry(for: try #require(textureIdentity)).get()
        let file = store.url.deletingLastPathComponent().appendingPathComponent(entry.directory + "/" + entry.files[0])
        return try Data(contentsOf: file).withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
    }
    let main = try level(identity.composite?.textures["_MainTex"]?.identity), mask = try level(identity.composite?.textures["_ColorMask"]?.identity)
    var largest: Float = 0, overlayHigh = 0
    for row in 0..<512 {
        for column in 0..<512 {
            let source = ((511 - row) * 512 + column) * 4
            let texel = SIMD4(Float(main[source]), Float(main[source + 1]), Float(main[source + 2]), Float(main[source + 3]))
            if texel.x > 0.5 { overlayHigh += 1 }
            let expected = createEyeReference(main: texel, mask: Float(mask[source]), color: [0.8, 0.3, 0.2, 0.9], color2: [0.1, 0.5, 0.9, 1], blend: 0.6)
            let reference = [srgbByte(expected.x), srgbByte(expected.y), srgbByte(expected.z), (min(max(expected.w, 0), 1) * 255).rounded()]
            for lane in 0..<4 { largest = max(largest, abs(Float(bytes[(row * 512 + column) * 4 + lane]) - reference[lane])) }
        }
    }
    print("[iris composite] real program vs CPU reference (synthetic colours): max byte \(largest); \(overlayHigh) texels in the t > 0.5 branch")
    #expect(largest <= 1 && overlayHigh > 0 && overlayHigh < 512 * 512)

    // Edit cost (a Maker iris colour edit: new content key, warm pipeline)
    // and the cache-hit cost of an unchanged recipe, as medians of 15.
    func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
    var edits: [SourceShaderCompositor.Statistics] = [], hits: [Double] = [], kept: [any MTLTexture] = []
    for index in 0..<15 {
        var edited = identity
        edited.composite?.vectors["_Color"] = .init([0.8, 0.3, Float(index) / 32, 0.9], source: "synthetic edit")
        kept.append(try store.texture(.init(identity: edited, property: "_MainTex", mesh: nil, slot: nil), resources: resources).get().texture)
        let event = try #require(store.compositeEvents().last)
        #expect(event.cacheHit == false && event.statistics?.pipelineCompiled == false)
        edits.append(try #require(event.statistics))
        let start = CACurrentMediaTime()
        _ = try store.texture(.init(identity: edited, property: "_MainTex", mesh: nil, slot: nil), resources: resources).get()
        hits.append((CACurrentMediaTime() - start) * 1000)
        #expect(store.compositeEvents().last?.cacheHit == true)
    }
    print(String(format: "[iris composite] edit (median of 15): cpu encode %.3f ms, gpu %.3f ms, total %.3f ms, %d bytes; cache hit %.3f ms",
                 median(edits.map(\.cpuEncodeMilliseconds)), median(edits.map(\.gpuMilliseconds)), median(edits.map(\.totalMilliseconds)),
                 edits[0].bytes, median(hits)))
}

/// Composes the fixture card's eye whites (`ctCreateEyeW`, one target that
/// both `rendEyeW` renderers share) from the private store and compares level
/// 0 with the retained original composite readback (`texture-20`). The card
/// keeps the default white base and sub colours over `whiteId` 0, whose 8×8
/// `cw_t_sirome_kage_000` is uniformly 1, so this oracle sees only a constant
/// white, opaque target of the right size: it cannot observe the input's
/// sampling or the colour order. The real translated program is then checked
/// against the CPU reference with synthetic, distinct colours over a
/// non-uniform store texture (the iris gradient mask) with its own sampler;
/// `liveSourceCompositesMatchTheDistinctColourCapture` has the independent check.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SHADER_BINDING_PROBE", "IKKOKU_MAKER_LIBRARY", "IKKOKU_HEAD_MATERIAL_CONTRACT",
    "IKKOKU_SHADER_BINDING_SUPPLEMENT", "IKKOKU_LIVE_SOURCE_TEXTURES"])))
func liveSourceEyeWhiteCompositesMatchTheRetainedOriginalComposite() throws {
    let folder = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_PROBE"), isDirectory: true)
    let inputs = SourceShaderLiveAssembly.Inputs(programs: folder.appendingPathComponent("shaders"),
        makerLibrary: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")),
        headContract: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_HEAD_MATERIAL_CONTRACT")),
        supplement: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_SUPPLEMENT")))
    let card = try SourceCharacterCard.load(url: folder.appendingPathComponent("fixture-card.png"))
    let bindings = try inputs.derive(card: card, scene: .originalCharacterProbeHarness, sceneReason: "", eyeLook: nil)
    let frame = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("frame-mips.json"))) as? [String: Any])
    let store = try SourceShaderTextureStore(url: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_LIVE_SOURCE_TEXTURES")))
    let device = try #require(MTLCreateSystemDefaultDevice()), resources = ResourceStore(device: device)
    let original = try Data(contentsOf: folder.appendingPathComponent("texture-20.rgba16f")).withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
    #expect(original.count == 512 * 512 * 4)
    var whites: [any MTLTexture] = []
    for mesh in ["cf_Ohitomi_L", "cf_Ohitomi_R"] {
        let renderer = try #require(bindings.renderers.first { $0.mesh == mesh && $0.materialSlot == 0 })
        let identity = try #require(renderer.material.textures["_MainTex"]?.identity)
        let recipe = try #require(identity.composite)
        #expect(recipe.material == "cf_m_eyewhite_create" && recipe.programSHA256 == "4f4f69fd421ab35d9e380e418ae04b22ac88852cad0ecf6c63f75285c895b1f9")
        #expect(identity.width == 512 && identity.height == 512 && identity.mipLevels == 10)
        #expect(recipe.textures["_MainTex"]?.identity?.name == "cw_t_sirome_kage_000")
        let texture = try store.texture(.init(identity: identity, property: "_MainTex", mesh: mesh, slot: 0,
                                              anisotropicFiltering: frame["anisotropicFiltering"] as? String), resources: resources).get().texture
        whites.append(texture)
        let ours = try readback(texture, level: 0, device: device)
        var byteLargest: Float = 0, differing = 0
        for row in 0..<512 {
            for column in 0..<512 {
                let target = (row * 512 + column) * 4, source = ((511 - row) * 512 + column) * 4   // capture rows are bottom-up
                for lane in 0..<4 {
                    let reference = Float(original[source + lane])
                    let referenceByte = lane == 3 ? (min(max(reference, 0), 1) * 255).rounded() : srgbByte(reference)
                    let byteError = abs(Float(ours[target + lane]) - referenceByte)
                    byteLargest = max(byteLargest, byteError)
                    if byteError > 0 { differing += 1 }
                }
            }
        }
        print("[eye-white composite] \(mesh) vs texture-20.rgba16f: max byte \(byteLargest), \(differing) differing channels")
        #expect(byteLargest <= 1, "\(mesh): largest byte difference \(byteLargest)")
    }
    // rendEyeW[1].material = rendEyeW[0].material: one composite for both.
    #expect(whites[0] === whites[1])

    func texels(_ entry: SourceShaderTextureStore.Entry) throws -> [SIMD4<Float>] {
        let file = store.url.deletingLastPathComponent().appendingPathComponent(entry.directory + "/" + entry.files[0])
        let halves = try Data(contentsOf: file).withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        var result: [SIMD4<Float>] = []
        result.reserveCapacity(entry.width * entry.height)
        for texel in 0..<entry.width * entry.height {
            let base = texel * 4
            let r = Float(halves[base]), g = Float(halves[base + 1])
            let b = Float(halves[base + 2]), a = Float(halves[base + 3])
            result.append(SIMD4(r, g, b, a))
        }
        return result
    }
    var identity = try #require(bindings.renderers.first { $0.mesh == "cf_Ohitomi_L" }?.material.textures["_MainTex"]?.identity)
    let input = try store.entry(for: try #require(identity.composite?.textures["_MainTex"]?.identity)).get()
    #expect(input.width == 8 && input.height == 8 && input.wrap == "Repeat" && input.filter == "Bilinear")
    #expect(Set(try texels(input).map(\.x)) == [1], "whiteId 0 is uniformly white")

    // The real translated program against the CPU reference with distinct
    // colours, over a non-uniform 512² store texture and its own sampler.
    let iris = try #require(bindings.renderers.first { $0.mesh == "cf_Ohitomi_L02" }?.material.textures["_MainTex"]?.identity?.composite)
    // The iris pattern (`_MainTex`), not its gradient mask: the mask is uniform.
    let gradient = try #require(iris.textures["_MainTex"]?.identity)
    identity.composite?.textures["_MainTex"]?.identity = gradient
    let color: [Float] = [0.8, 0.3, 0.2, 1], color2: [Float] = [0.1, 0.5, 0.9, 1]
    identity.composite?.vectors["_Color"] = .init(color, source: "synthetic")
    identity.composite?.vectors["_Color2"] = .init(color2, source: "synthetic")
    let synthetic = try store.texture(.init(identity: identity, property: "_MainTex", mesh: nil, slot: nil), resources: resources).get().texture
    let gradientEntry = try store.entry(for: gradient).get()
    let gradientTexels = try texels(gradientEntry), reds = Set(gradientTexels.map(\.x))
    let bytes = try readback(synthetic, level: 0, device: device)
    let largest = eyeWhiteLargestError(bytes, size: 512, texels: gradientTexels, inputSize: gradientEntry.width,
                                       repeats: gradientEntry.wrap == "Repeat", color: color, color2: color2)
    print("[eye-white composite] real program vs CPU reference (synthetic colours over \(gradientEntry.name), \(gradientEntry.wrap ?? "?")): "
          + "max byte \(largest); \(reds.count) distinct input reds in [\(reds.min() ?? 0), \(reds.max() ?? 0)]")
    #expect(gradientEntry.width == 512 && largest <= 1 && reds.count > 16)

    // Edit cost (a Maker eye-white colour edit: new content key, warm
    // pipeline) and the cache-hit cost of an unchanged recipe, as medians of 15.
    func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
    var edits: [SourceShaderCompositor.Statistics] = [], hits: [Double] = [], kept: [any MTLTexture] = []
    for index in 0..<15 {
        var edited = identity
        edited.composite?.vectors["_Color"] = .init([0.8, 0.3, Float(index) / 32, 1], source: "synthetic edit")
        kept.append(try store.texture(.init(identity: edited, property: "_MainTex", mesh: nil, slot: nil), resources: resources).get().texture)
        let event = try #require(store.compositeEvents().last)
        #expect(event.cacheHit == false && event.statistics?.pipelineCompiled == false)
        edits.append(try #require(event.statistics))
        let start = CACurrentMediaTime()
        _ = try store.texture(.init(identity: edited, property: "_MainTex", mesh: nil, slot: nil), resources: resources).get()
        hits.append((CACurrentMediaTime() - start) * 1000)
        #expect(store.compositeEvents().last?.cacheHit == true)
    }
    print("[eye-white composite] events " + store.compositeEvents().prefix(2).map { event in
        "\(event.cacheHit ? "hit" : "composed") \(event.contentKey.prefix(12))" + (event.statistics.map {
            String(format: " cpu %.3f ms gpu %.3f ms total %.3f ms compiled %@ %d bytes", $0.cpuEncodeMilliseconds, $0.gpuMilliseconds,
                   $0.totalMilliseconds, $0.pipelineCompiled ? "yes" : "no", $0.bytes) } ?? "")
    }.joined(separator: "; "))
    print(String(format: "[eye-white composite] edit (median of 15): cpu encode %.3f ms, gpu %.3f ms, total %.3f ms, %d bytes; cache hit %.3f ms",
                 median(edits.map(\.cpuEncodeMilliseconds)), median(edits.map(\.gpuMilliseconds)), median(edits.map(\.totalMilliseconds)),
                 edits[0].bytes, median(hits)))
}

/// The independent colour check: a second controlled original capture whose
/// card sets a non-uniform eye-white texture, distinct eye-white colours and
/// distinct iris colours, alpha, blend and gradient (the capture's own
/// `character-settings.tsv`). Its eye-white and iris composites are composed
/// from the card alone (with a supplement that adds the `mt_eye_white` rows and
/// a store built for this card) and compared with the capture's readbacks of
/// the original targets' base level. `IKKOKU_COMPOSITE_COLOUR_PROBE` holds
/// `fixture-card.png`, `frame.json`, the readbacks, `supplement.json` and
/// `textures/manifest.json`.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_COMPOSITE_COLOUR_PROBE", "IKKOKU_SHADER_BINDING_PROBE", "IKKOKU_MAKER_LIBRARY",
    "IKKOKU_HEAD_MATERIAL_CONTRACT"])))
func liveSourceCompositesMatchTheDistinctColourCapture() throws {
    let folder = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_COMPOSITE_COLOUR_PROBE"), isDirectory: true)
    let programs = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_PROBE"), isDirectory: true).appendingPathComponent("shaders")
    let inputs = SourceShaderLiveAssembly.Inputs(programs: programs,
        makerLibrary: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")),
        headContract: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_HEAD_MATERIAL_CONTRACT")),
        supplement: folder.appendingPathComponent("supplement.json"))
    let card = try SourceCharacterCard.load(url: folder.appendingPathComponent("fixture-card.png"))
    let bindings = try inputs.derive(card: card, scene: .originalCharacterProbeHarness, sceneReason: "", eyeLook: nil)
    let frame = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("frame.json"))) as? [String: Any])
    let meshes = try #require(frame["meshes"] as? [[String: Any]])
    let store = try SourceShaderTextureStore(url: folder.appendingPathComponent("textures/manifest.json"))
    let device = try #require(MTLCreateSystemDefaultDevice()), resources = ResourceStore(device: device)
    for (mesh, material) in [("cf_Ohitomi_L", "cf_m_eyewhite_create"), ("cf_Ohitomi_R", "cf_m_eyewhite_create"),
                             ("cf_Ohitomi_L02", "cf_m_eye_create"), ("cf_Ohitomi_R02", "cf_m_eye_create")] {
        let source = try #require(meshes.first { $0["name"] as? String == mesh }?["materials"] as? [[String: Any]])
        let properties = try #require(source.first?["properties"] as? [String: Any])
        let capture = try #require((properties["_MainTex"] as? [String: Any])?["file"] as? String)
        let renderer = try #require(bindings.renderers.first { $0.mesh == mesh && $0.materialSlot == 0 })
        let identity = try #require(renderer.material.textures["_MainTex"]?.identity)
        let recipe = try #require(identity.composite)
        #expect(recipe.material == material && recipe.unresolved == nil && identity.width == 512 && identity.mipLevels == 10)
        let texture = try store.texture(.init(identity: identity, property: "_MainTex", mesh: mesh, slot: 0,
                                              anisotropicFiltering: frame["anisotropicFiltering"] as? String), resources: resources).get().texture
        let ours = try readback(texture, level: 0, device: device)
        let original = try Data(contentsOf: folder.appendingPathComponent(capture)).withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        #expect(original.count == 512 * 512 * 4)
        var byteLargest: Float = 0, differing = 0, total: Double = 0
        var distinct = Set<UInt32>()
        for row in 0..<512 {
            for column in 0..<512 {
                let target = (row * 512 + column) * 4, source = ((511 - row) * 512 + column) * 4   // capture rows are bottom-up
                var packed: UInt32 = 0
                for lane in 0..<4 {
                    let reference = Float(original[source + lane])
                    let referenceByte = lane == 3 ? (min(max(reference, 0), 1) * 255).rounded() : srgbByte(reference)
                    let byteError = abs(Float(ours[target + lane]) - referenceByte)
                    byteLargest = max(byteLargest, byteError); total += Double(byteError)
                    if byteError > 0 { differing += 1 }
                    packed = packed << 8 | UInt32(referenceByte)
                }
                distinct.insert(packed)
            }
        }
        print("[colour capture] \(mesh) (\(material)) vs \(capture): max byte \(byteLargest), \(differing) differing channels, "
              + "mean byte \(total / Double(512 * 512 * 4)); \(distinct.count) distinct original colours")
        #expect(byteLargest <= 1 && distinct.count > 16, "\(mesh): largest byte difference \(byteLargest), \(distinct.count) colours")
    }
}


/// The first normal top target is checked against two independent original
/// base-level readbacks: the retained base card and a distinct-colour capture.
/// Authored input mips are decoded by the store; generated target mips are
/// structural checks only because the source capture exposes only level zero.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_GARMENT_COMPOSITE_PROBE", "IKKOKU_SHADER_BINDING_PROBE", "IKKOKU_MAKER_LIBRARY",
    "IKKOKU_HEAD_MATERIAL_CONTRACT", "IKKOKU_SHADER_BINDING_SUPPLEMENT", "IKKOKU_LIVE_SOURCE_TEXTURES"])))
func liveSourceNormalTopCompositeMatchesBaseAndDistinctOriginalColours() throws {
    try verifyNormalGarmentComposite(slot: 0, colourProbe: "IKKOKU_GARMENT_COMPOSITE_PROBE")
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_BOTTOM_COMPOSITE_PROBE", "IKKOKU_SHADER_BINDING_PROBE", "IKKOKU_MAKER_LIBRARY",
    "IKKOKU_HEAD_MATERIAL_CONTRACT", "IKKOKU_SHADER_BINDING_SUPPLEMENT", "IKKOKU_LIVE_SOURCE_TEXTURES"])))
func liveSourceNormalBottomCompositeMatchesBaseAndDistinctOriginalColours() throws {
    try verifyNormalGarmentComposite(slot: 1, colourProbe: "IKKOKU_BOTTOM_COMPOSITE_PROBE")
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_INNER_SHOE_COMPOSITE_PROBE", "IKKOKU_SHADER_BINDING_PROBE", "IKKOKU_MAKER_LIBRARY",
    "IKKOKU_HEAD_MATERIAL_CONTRACT", "IKKOKU_SHADER_BINDING_SUPPLEMENT", "IKKOKU_LIVE_SOURCE_TEXTURES"])))
func liveSourceNormalInnerShoeCompositeMatchesBaseAndDistinctOriginalColours() throws {
    try verifyNormalGarmentComposite(slot: 7, colourProbe: "IKKOKU_INNER_SHOE_COMPOSITE_PROBE")
}

private func verifyNormalGarmentComposite(slot: Int, colourProbe: String) throws {
    let role: String, mesh: String, width: Int, height: Int, targetMips: Int, inputMips: Int
    let expectedColours: [[[Float]]], assetInputs: [(String, String, String)]
    let inputBundleHash: String, inputFile: String, captureHashes: [String]
    switch slot {
    case 0:
        role = "top"; mesh = "o_top_tsyats_a"; width = 1024; height = 1024; targetMips = 11; inputMips = 11
        expectedColours = [Array(repeating: [0.12, 0.28, 0.5, 1], count: 3), [[0.72, 0.13, 0.04, 1], [0.09, 0.66, 0.31, 1], [0.16, 0.23, 0.84, 1]]]
        assetInputs = [("_MainTex", "cf_top_tsyatu02_t", "-6233972938813170750"), ("_ColorMask", "cf_top_tsyatu02_mc", "-1591564840063675426")]
        inputBundleHash = "2df694771a8c6437f5e966e94747f48ed905d611a7f2de036a5d64956996657a"
        inputFile = "CAB-ea71f5c3f889c85d158dd90d78f65595"
        captureHashes = ["c9020d7ceeaf413ea4199482e52ce66b51e85bd34912493a5d21eea5adf1dd11", "2ba4e150536fbe5e103430dc1ceb18f988dd169c275d8846ab394e96fb91445a"]
    case 1:
        role = "bottom"; mesh = "o_bot_pants03"; width = 512; height = 1024; targetMips = 11; inputMips = 1
        expectedColours = [Array(repeating: [0.12, 0.13, 0.16, 1], count: 3), [[0.68, 0.12, 0.83, 1], [0.07, 0.74, 0.29, 1], [0.91, 0.38, 0.05, 1]]]
        assetInputs = [("_MainTex", "cf_bot_pants03_t", "1799539927781456382"), ("_ColorMask", "cf_bot_pants03_mc", "2152893568627913941")]
        inputBundleHash = "99ca895979e691caf55c1a68a4ffd9a6892b3d8fdfe9b260cb0812cd5fbf9d29"
        inputFile = "CAB-633e5b9224bb4b60a1d0f9eeb80cf32d"
        captureHashes = ["e896dd7f15c967a5ca310eb46448cafcce5dd601a3b8995bee32f7a0e9e5393d", "8b5641111b0c210c872ff26ce522de1c7846e3d511b32295e6c2a28c07d58ae6"]
    default:
        try #require(slot == 7)
        role = "inner shoe"; mesh = "o_shoes_run01"; width = 512; height = 512; targetMips = 10; inputMips = 1
        expectedColours = [Array(repeating: [0.12, 0.13, 0.16, 1], count: 3), [[0.83, 0.18, 0.07, 1], [0.09, 0.62, 0.87, 1], [0.74, 0.11, 0.58, 1]]]
        assetInputs = [("_MainTex", "cf_shoes_run01_t", "-7640729741191341103"), ("_ColorMask", "cf_shoes_run01_mc", "-2274634555552161051")]
        inputBundleHash = "dde13cf97a4160d9d13cb8ea8102c7ba6e6c092908855180110c6391cf6066d0"
        inputFile = "CAB-b9a8ff574f24c2b427e59cd30ae00421"
        captureHashes = ["0cac5ab425329461f568cd0b5a681e9965e0c0938b22e8778e4ded8a38d3f0f5", "753a6e98a391b2fc3f511152dadd532dca52f2c89227c12abc2bdca359ebbc4f"]
    }
    let base = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_PROBE"), isDirectory: true)
    let colour = URL(fileURLWithPath: try SourceFixtureSupport.require(colourProbe), isDirectory: true)
    let inputs = SourceShaderLiveAssembly.Inputs(programs: base.appendingPathComponent("shaders"),
        makerLibrary: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")),
        headContract: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_HEAD_MATERIAL_CONTRACT")),
        supplement: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_SUPPLEMENT")))
    let store = try SourceShaderTextureStore(url: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_LIVE_SOURCE_TEXTURES")))
    let device = try #require(MTLCreateSystemDefaultDevice()), resources = ResourceStore(device: device)
    var textures: [any MTLTexture] = [], images: [[UInt8]] = [], identities: [SourceShaderBindingSet.TextureIdentity] = []
    for (index, folder) in [base, colour].enumerated() {
        let frame = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(index == 0 ? "frame-mips.json" : "frame.json"))) as? [String: Any])
        let meshes = try #require(frame["meshes"] as? [[String: Any]])
        let materials = try #require(meshes.first { $0["name"] as? String == mesh }?["materials"] as? [[String: Any]])
        let properties = try #require(materials.first?["properties"] as? [String: Any])
        let capture = try #require((properties["_MainTex"] as? [String: Any])?["file"] as? String)
        let card = try SourceCharacterCard.load(url: folder.appendingPathComponent("fixture-card.png"))
        let bindings = try inputs.derive(card: card, scene: .originalCharacterProbeHarness, sceneReason: "", eyeLook: nil)
        let selected = try #require(bindings.renderers.first { $0.mesh == mesh && $0.materialSlot == 0 && $0.visible == true })
        let identity = try #require(selected.material.textures["_MainTex"]?.identity)
        if slot == 7 {
            #expect(selected.component == "clothes.7 112:3")
            let outer = try #require(bindings.renderers.first { $0.component == "clothes.8 112:3" && $0.materialSlot == 0 })
            #expect(outer.visible == false && outer.material.textures["_MainTex"]?.identity?.composite == nil)
            if index == 1 {
                let readbacks = try #require(frame["innerShoeCompositeInputs"] as? [String: Any])
                let selection = try #require(readbacks["selection"] as? [String: Any])
                #expect(selection["slot"] as? Int == 7 && selection["shoesType"] as? Int == 0 && selection["id"] as? Int == 3)
                #expect(selection["object"] as? String == "ct_shoes_inner" && selection["active"] as? Bool == true)
                #expect(selection["MainData"] as? String == "p_o_shoes_run01" && selection["MainAB"] as? String == "chara/co_shoes_00.unity3d")
                #expect(selection["MainManifest"] as? String == "abdata")
                let normal = try #require(selection["normalRenderers"] as? [[String: Any]])
                try #require(normal.count == 1)
                #expect(normal[0]["enabled"] as? Bool == true && normal[0]["active"] as? Bool == true)
                #expect(normal[0]["mainTex"] as? String == capture)
                #expect((normal[0]["path"] as? String)?.contains("/ct_shoes_inner/") == true)
                for (key, name, format, hash) in [
                    ("MainTex", "cf_shoes_run01_t", "BC7", "22a30559f504740547c2f8d7749bb0e01cc7aaa340cf85cdb04baf846974d186"),
                    ("ColorMaskTex", "cf_shoes_run01_mc", "RGB24", "db3d1c8217367e9fdf190df1c4e1a542065f8e66444adfe54f37381afd178611")
                ] {
                    let input = try #require(readbacks[key] as? [String: Any])
                    #expect(input["bundleSHA256"] as? String == inputBundleHash && input["name"] as? String == name)
                    #expect(input["format"] as? String == format && input["mipLevels"] as? Int == 1)
                    #expect(input["width"] as? Int == width && input["height"] as? Int == height)
                    let file = try #require(input["file"] as? String)
                    #expect(hex(try Data(contentsOf: folder.appendingPathComponent(file))) == hash)
                }
            }
        }
        let recipe = try #require(identity.composite)
        #expect(recipe.material == "cf_m_clothesN_create" && recipe.shader == "Shader Forge/create_topN" && recipe.unresolved == nil)
        #expect(recipe.programSHA256 == "d709d6fc92ebecd4f8b579041c8a7abce3a13c20c18985812bde6bc42881f579")
        #expect(recipe.bundleSHA256 == "3944a1d7a9e446f15714bcca0b2faebd7b760fdc010139fad677ce24c422175e")
        #expect(recipe.serializedFile == "CAB-0d1f3d8317188244dde38c81a889d1d4" && recipe.pathID == "3922150014319152921")
        #expect(identity.width == width && identity.height == height && identity.mipLevels == targetMips)
        for (property, name, pathID) in assetInputs {
            let asset = try #require(recipe.textures[property]?.identity)
            let entry = try store.entry(for: asset).get()
            #expect(entry.name == name && entry.pathID == pathID && entry.mipLevels == inputMips)
            #expect(entry.bundleSHA256 == inputBundleHash && entry.serializedFile == inputFile)
            #expect(entry.width == width && entry.height == height)
            #expect(entry.filter == "Bilinear" && entry.wrap == "Repeat" && entry.aniso == 1)
            if slot == 7 {
                #expect(entry.textureFormat == (property == "_MainTex" ? 25 : 3))
                #expect(entry.colorSpace == (property == "_MainTex" ? "srgb" : "linear"))
            }
        }
        for (lane, name) in ["_Color", "_Color2", "_Color3"].enumerated() {
            #expect(recipe.vectors[name]?.values == expectedColours[index][lane])
            #expect(recipe.vectors[name]?.source.contains("clothes.parts.\(slot).colorInfo.\(lane).baseColor") == true)
        }
        let request = SourceShaderLiveTextureRequest(identity: identity, property: "_MainTex", mesh: mesh, slot: 0)
        let texture = try store.texture(request, resources: resources).get().texture
        #expect(texture.mipmapLevelCount == targetMips && texture.pixelFormat == .rgba8Unorm_srgb)
        let resourcesBefore = resources.statistics().textures
        let auxiliaries = store.compositeInputStatistics(for: resources)
        #expect(auxiliaries == .init(defaults: 1, samplers: 1))
        #expect(try store.texture(request, resources: resources).get().texture === texture)
        #expect(resources.statistics().textures == resourcesBefore && store.compositeEvents().last?.cacheHit == true)
        #expect(store.compositeInputStatistics(for: resources) == auxiliaries)
        let ours = try readback(texture, level: 0, device: device)
        let originalData = try Data(contentsOf: folder.appendingPathComponent(capture))
        #expect(hex(originalData) == captureHashes[index])
        let original = originalData.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        try #require(original.count == width * height * 4)
        var largest: Float = 0, total: Double = 0, differing = 0
        var errors: [Int: Int] = [:], examples: [String] = []
        for row in 0..<height {
            for column in 0..<width {
                let target = (row * width + column) * 4, source = ((height - 1 - row) * width + column) * 4
                for lane in 0..<4 {
                    let reference = Float(original[source + lane])
                    let referenceByte = lane == 3 ? (min(max(reference, 0), 1) * 255).rounded() : srgbByte(reference)
                    let error = abs(Float(ours[target + lane]) - referenceByte)
                    largest = max(largest, error); total += Double(error)
                    if error > 0 { differing += 1; errors[Int(error), default: 0] += 1 }
                    if error > 1 && examples.count < 8 { examples.append("(\(column),\(row)) lane\(lane) ours\(ours[target + lane]) ref\(referenceByte)") }
                }
            }
        }
        print("[normal \(role) composite] \(index == 0 ? "base" : "distinct colour"): max byte \(largest), mean byte \(total / Double(ours.count)), \(differing) differing channels")
        print("[normal \(role) composite] error histogram \(errors); examples \(examples)")
        #expect(largest <= 1)
        identities.append(identity); textures.append(texture); images.append(ours)
    }
    let changed = zip(images[0], images[1]).filter { $0 != $1 }.count
    #expect(changed > width * height, "The counterfactual must change more than a single channel per pixel on average")
    #expect(textures[0] !== textures[1])
    let uploads = resources.statistics().textures
    #expect(uploads == 2, "Only the source main and colour-mask assets should be uploaded")
    // Every edit releases its target, while input uploads and the warm
    // pipeline are shared. The store must not retain unbounded old targets.
    var edits: [SourceShaderCompositor.Statistics] = [], hits: [Double] = []
    for index in 0..<15 {
        weak var released: (any MTLTexture)?
        try autoreleasepool {
            var edited = identities[1]
            var editColour = expectedColours[1][0]; editColour[1] = Float(index) / 32
            edited.composite?.vectors["_Color"] = .init(editColour, source: "colour edit")
            let request = SourceShaderLiveTextureRequest(identity: edited, property: "_MainTex", mesh: mesh, slot: 0)
            let texture = try store.texture(request, resources: resources).get().texture
            released = texture
            let event = try #require(store.compositeEvents().last)
            #expect(event.cacheHit == false && event.statistics?.pipelineCompiled == false)
            edits.append(try #require(event.statistics))
            let start = CACurrentMediaTime()
            #expect(try store.texture(request, resources: resources).get().texture === texture)
            hits.append((CACurrentMediaTime() - start) * 1000)
            #expect(store.compositeEvents().last?.cacheHit == true)
        }
        #expect(released == nil && resources.statistics().textures == uploads)
        #expect(store.compositeInputStatistics(for: resources) == .init(defaults: 1, samplers: 1))
    }
    let reverted = try store.texture(.init(identity: identities[0], property: "_MainTex", mesh: mesh, slot: 0), resources: resources).get().texture
    #expect(reverted === textures[0] && store.compositeEvents().last?.cacheHit == true)
    #expect(try readback(reverted, level: 0, device: device) == images[0])
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    print("[normal \(role) composite] first events " + store.compositeEvents().prefix(4).map { event in
        "\(event.cacheHit ? "hit" : "composed")" + (event.statistics.map {
            String(format: " cpu %.3f ms gpu %.3f ms total %.3f ms compiled %@ %d bytes", $0.cpuEncodeMilliseconds, $0.gpuMilliseconds,
                   $0.totalMilliseconds, $0.pipelineCompiled ? "yes" : "no", $0.bytes) } ?? "")
    }.joined(separator: "; "))
    print(String(format: "[normal \(role) composite] 15 warm edits median cpu %.3f ms gpu %.3f ms total %.3f ms; unchanged hit %.3f ms; %d uploaded textures",
                 median(edits.map(\.cpuEncodeMilliseconds)), median(edits.map(\.gpuMilliseconds)), median(edits.map(\.totalMilliseconds)), median(hits), uploads))
}
