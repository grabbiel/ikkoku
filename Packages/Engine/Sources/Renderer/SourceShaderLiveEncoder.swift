import Foundation
import Metal
import simd
import CoreMath
import ShaderTypes

/// GPU half of the opt-in live source-shader path: converts each frame's
/// deformed vertices into the translated programs' `SourceInput` layout and
/// encodes the draws. Shared by the main pass (HDR, MSAA) and the
/// validation capture (the probe's 8-bit sRGB target) so the two cannot
/// drift apart; the frozen-frame probe shares `TranslatedSourceProgram` and
/// `TranslatedSourcePipelineCache` with both.
final class SourceShaderLiveEncoder: @unchecked Sendable {
    /// `SourceInput` register semantics, as the conversion kernel numbers them.
    static func code(_ input: TranslatedSourceProgram.VertexInput) -> UInt32? {
        switch input.semantic {
        case "POSITION": return 0
        case "NORMAL": return 1
        case "TANGENT": return 2
        case "TEXCOORD": return (0...3).contains(input.index) ? UInt32(3 + input.index) : nil
        case "COLOR": return input.index == 0 ? 7 : nil
        default: return nil
        }
    }

    /// The program's register layout, or nil when a register is unsupported.
    static func layout(_ program: TranslatedSourceProgram) -> [UInt32]? {
        let codes = program.vertexInputs.compactMap(code)
        guard codes.count == program.vertexInputs.count, (1...8).contains(codes.count) else { return nil }
        return codes
    }

    struct Params {
        var vertexCount: UInt32 = 0, registerCount: UInt32 = 0, hasSkin: UInt32 = 0, boneCount: UInt32 = 0
        var activeMorphCount: UInt32 = 0, hasMorphNormals: UInt32 = 0, hasUV3: UInt32 = 0, hasColors: UInt32 = 0
        var semantics: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0)
    }

    struct BufferKey: Hashable { let vertices: UInt64; let layout: [UInt32] }

    let device: any MTLDevice
    let convert: any MTLComputePipelineState
    private let lock = NSLock()
    private var buffers: [BufferKey: any MTLBuffer] = [:]

    init(device: any MTLDevice) throws {
        self.device = device
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let library = try device.makeLibrary(source: Self.kernelSource, options: options)
        guard let function = library.makeFunction(name: "source_vertex_inputs") else { throw SourceShaderLiveReason("source_vertex_inputs kernel missing") }
        convert = try device.makeComputePipelineState(function: function)
    }

    /// One reusable input buffer per (vertex source, layout), like the
    /// renderer's per-key deform buffers.
    func inputBuffer(_ key: BufferKey, vertexCount: Int) -> (any MTLBuffer)? {
        lock.lock(); defer { lock.unlock() }
        let length = max(16, vertexCount * key.layout.count * 16)
        if let buffer = buffers[key], buffer.length >= length { return buffer }
        guard let buffer = device.makeBuffer(length: length, options: .storageModePrivate) else { return nil }
        buffer.label = "source-input.\(key.vertices).\(key.layout.map(String.init).joined())"
        buffers[key] = buffer
        return buffer
    }

    func releaseBuffers() { lock.lock(); buffers = [:]; lock.unlock() }

    /// Unity's renderer-local vertex inputs from the native buffers:
    /// POSITION and TANGENT from the deformed vertex (Z mirrored into Unity's
    /// basis; tangent handedness is the source mesh's, as Unity keeps it);
    /// NORMAL recomputed from the rest normal plus active morph normal deltas,
    /// skinned linearly with the same normalized weights as `Deform.metal` and
    /// NOT renormalized (#96: Unity's skinned NORMAL keeps its magnitude, which
    /// the outline passes scale by); TEXCOORD0–2 un-flipped back to Unity's V;
    /// TEXCOORD3/COLOR from the source vertex streams.
    static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct DeformedVertex { float4 position; float4 normal; float4 tangent; };
    struct SkinVertex { ushort4 joints; float4 weights; };
    struct MorphWeightEntry { uint index; float weight; };
    struct Params {
        uint vertexCount; uint registerCount; uint hasSkin; uint boneCount;
        uint activeMorphCount; uint hasMorphNormals; uint hasUV3; uint hasColors;
        uint semantics[8];
    };
    kernel void source_vertex_inputs(uint vid [[thread_position_in_grid]],
        device const DeformedVertex *base [[buffer(0)]],
        device const DeformedVertex *deformed [[buffer(1)]],
        device const SkinVertex *skin [[buffer(2)]],
        device const float4x4 *bones [[buffer(3)]],
        device const MorphWeightEntry *morphs [[buffer(4)]],
        device const packed_float3 *normalDeltas [[buffer(5)]],
        device const float2 *uv0 [[buffer(6)]],
        device const float2 *uv1 [[buffer(7)]],
        device const float2 *uv2 [[buffer(8)]],
        device const float2 *uv3 [[buffer(9)]],
        device const float4 *colors [[buffer(10)]],
        device float4 *output [[buffer(11)]],
        constant Params &p [[buffer(12)]])
    {
        if (vid >= p.vertexCount) return;
        DeformedVertex b = base[vid], d = deformed[vid];
        float3 n = b.normal.xyz;
        if (p.hasMorphNormals != 0) {
            for (uint i = 0; i < p.activeMorphCount; ++i) {
                MorphWeightEntry e = morphs[i];
                n += float3(normalDeltas[e.index * p.vertexCount + vid]) * e.weight;
            }
        }
        if (p.hasSkin != 0) {
            SkinVertex s = skin[vid];
            float largest = max(max(s.weights.x, s.weights.y), max(s.weights.z, s.weights.w));
            if (all(uint4(s.joints) < p.boneCount) && all(isfinite(s.weights)) && all(s.weights >= 0.0f) && largest > 0.0f) {
                float4 w = s.weights / largest;
                w /= dot(w, float4(1.0f));
                float4x4 m = bones[s.joints.x] * w.x + bones[s.joints.y] * w.y + bones[s.joints.z] * w.z + bones[s.joints.w] * w.w;
                n = float3x3(m[0].xyz, m[1].xyz, m[2].xyz) * n;
            }
        }
        float3 t = float3(d.tangent.x, d.tangent.y, -d.tangent.z);
        float tl = length(t);
        t = (isfinite(tl) && tl > 0.0f) ? t / tl : float3(1.0f, 0.0f, 0.0f);
        for (uint r = 0; r < p.registerCount; ++r) {
            float4 v = float4(0.0f);
            switch (p.semantics[r]) {
                case 0: v = float4(d.position.x, d.position.y, -d.position.z, 1.0f); break;
                case 1: v = float4(n.x, n.y, -n.z, 0.0f); break;
                case 2: v = float4(t, b.tangent.w); break;
                case 3: v = float4(uv0[vid].x, 1.0f - uv0[vid].y, 0.0f, 0.0f); break;
                case 4: v = float4(uv1[vid].x, 1.0f - uv1[vid].y, 0.0f, 0.0f); break;
                case 5: v = float4(uv2[vid].x, 1.0f - uv2[vid].y, 0.0f, 0.0f); break;
                case 6: v = p.hasUV3 != 0 ? float4(uv3[vid], 0.0f, 0.0f) : float4(0.0f); break;
                case 7: v = p.hasColors != 0 ? colors[vid] : float4(1.0f); break;
            }
            output[vid * p.registerCount + r] = v;
        }
    }
    """

    /// Per-frame inputs of the builtin uniforms, in the native basis.
    struct FrameState {
        var view: float4x4
        var projection: float4x4
        var cameraPosition: Float3
        /// Direction the main light travels (native world space).
        var lightDirection: Float3
        var lightColor: Float3
        var lightIntensity: Float
        var width: Int, height: Int
        var time: Float
    }

    /// Builtins the translated programs read, from the live camera and main
    /// light (Unity basis B = diag(1, 1, -1)): `_WorldSpaceCameraPos = B·eye`,
    /// `_WorldSpaceLightPos0 = (-B·lightDirection, 0)`, `_LightColor0 =
    /// linear(colour)·intensity` (the light colour is the Unity gamma-space
    /// value, as the probe and Studio scene import store it), `_Time` from the
    /// frame clock.
    static func frameUniform(_ name: String, state: FrameState, determinant: Float) -> [Float]? {
        switch name {
        case "_WorldSpaceCameraPos": return [state.cameraPosition.x, state.cameraPosition.y, -state.cameraPosition.z, 1]
        case "_WorldSpaceLightPos0": return [-state.lightDirection.x, -state.lightDirection.y, state.lightDirection.z, 0]
        case "_LightColor0":
            let linear = TranslatedSourceProgram.linear
            return [linear(state.lightColor.x) * state.lightIntensity, linear(state.lightColor.y) * state.lightIntensity, linear(state.lightColor.z) * state.lightIntensity, 1]
        case "_ScreenParams": return [Float(state.width), Float(state.height), 1 + 1 / Float(state.width), 1 + 1 / Float(state.height)]
        case "unity_WorldTransformParams": return [0, 0, 0, determinant < 0 ? -1 : 1]
        case "_Time": return [state.time / 20, state.time, state.time * 2, state.time * 3]
        default: return nil
        }
    }

    /// Matrices for an item whose native model matrix is `model`; the clip
    /// position equals the native one (B·B = I), so depth interleaves with
    /// native draws.
    static func matrix(_ name: String, model: float4x4, state: FrameState) throws -> float4x4 {
        let basis = UnityCoordinates.basis
        switch name {
        case "unity_ObjectToWorld": return basis * model * basis
        case "unity_WorldToObject": return (basis * model * basis).inverse
        case "unity_MatrixV": return state.view * basis
        case "glstate_matrix_projection", "unity_CameraProjection": return state.projection
        case "unity_MatrixVP": return state.projection * state.view * basis
        default: throw SourceShaderLiveReason("Unknown source shader matrix \(name)")
        }
    }

    /// Encodes one live draw (every pass of its material) on `encoder`.
    /// `inputs` maps a register layout to its converted vertex buffer.
    func encode(_ encoder: any MTLRenderCommandEncoder, draw: SourceShaderLiveDraw, mesh: GPUMesh, model: float4x4,
                inputs: [[UInt32]: any MTLBuffer], target: TranslatedSourceTarget, state: FrameState, cache: TranslatedSourcePipelineCache) throws {
        let material = draw.material
        let objectToWorld = UnityCoordinates.basis * model * UnityCoordinates.basis
        let determinant = simd_determinant(objectToWorld)
        func uniform(_ name: String) throws -> [Float] {
            if let value = draw.vectorOverrides[name] { return value }
            if let value = Self.frameUniform(name, state: state, determinant: determinant) { return value }
            if let value = material.vectors[name] { return value }
            throw SourceShaderLiveReason("Unbound source constant \(name)")
        }
        for program in material.passes {
            guard let layout = Self.layout(program), let input = inputs[layout] else { throw SourceShaderLiveReason("No converted vertex input for \(program.name)") }
            let entry = try cache.entry(program, target: target)
            TranslatedSourcePipelineCache.apply(entry, to: encoder)
            // Mirrored nodes reverse triangle orientation, as in the native passes.
            encoder.setFrontFacing(simd_determinant(model.upperLeft3x3) < 0 ? .clockwise : .counterClockwise)
            encoder.setVertexBuffer(input, offset: 0, index: 0)
            for (stage, vertexStage) in [(program.vertex, true), (program.fragment, false)] {
                for buffer in try TranslatedSourceProgram.pack(stage, uniform: uniform, matrix: { try Self.matrix($0, model: model, state: state) }) {
                    let length = buffer.data.count * 4
                    try buffer.data.withUnsafeBytes { raw in
                        if length <= 4096 {
                            if vertexStage { encoder.setVertexBytes(raw.baseAddress!, length: length, index: buffer.slot + 8) }
                            else { encoder.setFragmentBytes(raw.baseAddress!, length: length, index: buffer.slot + 8) }
                        } else {
                            guard let gpu = device.makeBuffer(bytes: raw.baseAddress!, length: length) else { throw SourceShaderLiveReason("Source constants") }
                            if vertexStage { encoder.setVertexBuffer(gpu, offset: 0, index: buffer.slot + 8) }
                            else { encoder.setFragmentBuffer(gpu, offset: 0, index: buffer.slot + 8) }
                        }
                    }
                }
                for texture in stage.textures {
                    guard let bound = material.textures[texture.name] else { throw SourceShaderLiveReason("Unbound source texture \(texture.name)") }
                    if vertexStage { encoder.setVertexTexture(bound.texture, index: texture.slot); encoder.setVertexSamplerState(bound.sampler, index: texture.samplerSlot) }
                    else { encoder.setFragmentTexture(bound.texture, index: texture.slot); encoder.setFragmentSamplerState(bound.sampler, index: texture.samplerSlot) }
                }
            }
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        }
    }
}
