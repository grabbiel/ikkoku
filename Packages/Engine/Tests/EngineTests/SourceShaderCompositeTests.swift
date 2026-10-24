import Testing
import Foundation
import Metal
import CryptoKit
import Character
import Studio
@testable import Renderer

// R1/CMT-04 runtime composites (`CustomTextureCreate` render targets) composed
// natively for the live path. The synthetic store below holds a hand-written
// fragment-only program with the `create_eye` arithmetic (the CPU reference is
// `create_eye_base` in Tools/reverse/head_material_contract.py); nothing here
// reads original data. The gated check at the end composes the controlled
// fixture's irises from the private store and compares them with the retained
// original composite readback.

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A schema-2 texture store: 4×4 inputs (bottom-up rows) and one create program.
private enum CompositeStoreFixture {
    static let programSHA = String(repeating: "c", count: 64)

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

    struct Store { let url: URL; let folder: URL }

    static func write(schemaVersion: Int = 2, compositeOverrides: [String: Any] = [:], extraComposite: Bool = false) throws -> Store {
        let folder = try LiveProgramFixture.temporaryDirectory()
        var entries: [[String: Any]] = []
        for (name, pathID, pixels) in [("main", "11", main), ("mask", "12", mask), ("main2", "13", otherMain)] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
            let data = pixels.flatMap { [Float16($0.x), Float16($0.y), Float16($0.z), Float16($0.w)] }.withUnsafeBytes { Data($0) }
            try data.write(to: folder.appendingPathComponent(name + "/level-0.rgba16f"))
            entries.append(["bundle": "chara/inputs.unity3d", "bundleSHA256": "inputs-hash", "name": name, "pathID": pathID,
                            "serializedFile": "CAB-inputs", "width": 4, "height": 4, "mipLevels": 1, "colorSpace": "linear",
                            "textureFormat": 4, "filter": "Bilinear", "wrap": "Clamp", "aniso": 1, "directory": name,
                            "files": ["level-0.rgba16f"], "sha256": [hex(data)]])
        }
        let program = folder.appendingPathComponent("create")
        try FileManager.default.createDirectory(at: program, withIntermediateDirectories: true)
        let sourceData = Data(source.utf8)
        try sourceData.write(to: program.appendingPathComponent("source.metal"))
        let names = ["0": "$Globals", "1": "_Color2", "2": "_MainTex_ST", "3": "_Color", "4": "_ColorMask_ST", "5": "_Blend", "6": "_grad",
                     "7": "_MainTex", "8": "_ColorMask"]
        let vectors: [[String: Any]] = [(1, 32, 4), (2, 48, 4), (3, 64, 4), (4, 80, 4), (5, 96, 1), (6, 112, 4)].map {
            ["m_NameIndex": $0.0, "m_Index": $0.1, "m_Dim": $0.2]
        }
        let metadata: [String: Any] = [
            "m_ConstantBuffers": [["m_NameIndex": 0, "m_Size": 128, "m_VectorParams": vectors, "m_MatrixParams": []]],
            "m_ConstantBufferBindings": [["m_NameIndex": 0, "m_Index": 0]],
            "m_TextureParams": [["m_NameIndex": 7, "m_Index": 0, "m_SamplerIndex": 0], ["m_NameIndex": 8, "m_Index": 1, "m_SamplerIndex": 1]],
        ]
        let state = LiveProgramFixture.state
        let root: [String: Any] = [
            "schemaVersion": 1, "stages": ["fragment"], "name": "Shader Forge/create_test", "material": "m_create", "materialPathID": "5",
            "bundleSHA256": "create-hash", "serializedFile": "CAB-create", "names": names,
            "properties": [LiveProgramFixture.property("_Color", type: 0, defaults: [1, 1, 1, 1]), LiveProgramFixture.property("_Color2", type: 0),
                           LiveProgramFixture.property("_Blend", type: 3), LiveProgramFixture.property("_grad", type: 1),
                           LiveProgramFixture.property("_MainTex", type: 4), LiveProgramFixture.property("_ColorMask", type: 4)],
            // The create passes keep Shader Forge's ZTest LEqual, ZWrite On, Cull Back state.
            "passState": [
                "m_Name": "FORWARD", "zTest": state(4), "zWrite": state(1), "culling": state(2), "offsetFactor": state(0), "offsetUnits": state(0),
                "rtBlend0": ["srcBlend": state(5), "destBlend": state(10), "srcBlendAlpha": state(5), "destBlendAlpha": state(10),
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
    #expect(stride(from: 0, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 0 && bytes[$0 + 1] == 0 && bytes[$0 + 2] == 0 && bytes[$0 + 3] == 255 },
            "\(Array(bytes.prefix(8)))")
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
}
