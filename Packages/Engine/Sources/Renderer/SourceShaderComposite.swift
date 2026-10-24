import Foundation
import Metal
import QuartzCore

/// Native `CustomTextureCreate` composition for the opt-in live source-shader
/// path (R1/CMT-04). `RebuildTextureAndSetMaterial` clears an ARGB32
/// `RenderTexture` (sRGB in the linear-space player) to transparent and runs
/// `Graphics.Blit(texMain, createTex, matCreate, 0)` with `GL.sRGBWrite` on;
/// `useMipMap` with Unity's default `autoGenerateMips` then fills the chain.
/// Here the create pass's translated fragment program runs over a native
/// full-target quad into an `rgba8Unorm_srgb` texture with the pass's blend
/// state, and the blit encoder generates the mip chain.
///
/// The quad gives `TEXCOORD0` = (0, 0) at the bottom-left and (1, 1) at the
/// top-right in Unity's convention, so texel (x, y) of the target samples at
/// its centre exactly as `Graphics.Blit`'s quad does. Composition runs when an
/// assembly resolves a material, never per frame.
public final class SourceShaderCompositor: @unchecked Sendable {
    /// Cost of one composition, for the live reports and benchmarks.
    public struct Statistics: Sendable, Equatable, Encodable {
        /// CPU time to build the pipeline (0 when cached) and encode until commit.
        public var cpuEncodeMilliseconds: Double
        /// GPU execution of the composite pass and its mip generation.
        public var gpuMilliseconds: Double
        /// Wall time from the start to the command buffer's completion.
        public var totalMilliseconds: Double
        public var pipelineCompiled: Bool
        /// `MTLTexture.allocatedSize` of the composite.
        public var bytes: Int
    }

    public let device: any MTLDevice
    private let lock = NSLock()
    private var queue: (any MTLCommandQueue)?
    private var pipelines: [String: any MTLRenderPipelineState] = [:]
    /// Pipelines compiled so far (cache misses).
    public private(set) var compiledPipelines = 0

    public init(device: any MTLDevice) { self.device = device }

    /// The `Graphics.Blit` quad as a vertex function feeding the translated
    /// fragment's inputs: `SV_POSITION` and `TEXCOORD0` only.
    static func blitVertexSource(_ program: TranslatedSourceProgram) throws -> String {
        var fields = ["float4 ikkoku_position [[position]];"], assignments: [String] = []
        for input in program.fragmentInputs {
            switch (input.semantic, input.index) {
            case ("SV_POSITION", _): continue
            case ("TEXCOORD", 0):
                fields.append("float4 v\(input.register) [[user(locn\(input.register))]];")
                assignments.append("out.v\(input.register) = float4(corner, 0.0, 0.0);")
            default:
                throw TranslatedSourceProgram.ProgramError.invalid("\(program.name): the Graphics.Blit quad supplies no \(input.semantic)\(input.index)")
            }
        }
        return """

        struct IkkokuBlitOutput { \(fields.joined(separator: " ")) };
        vertex IkkokuBlitOutput ikkoku_blit_vertex(uint vid [[vertex_id]]) {
            float2 corner = float2(float(vid & 1u), float((vid >> 1) & 1u));
            IkkokuBlitOutput out;
            out.ikkoku_position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
            \(assignments.joined(separator: "\n    "))
            return out;
        }

        """
    }

    /// The pipeline for `program` drawing into `rgba8Unorm_srgb` with the
    /// pass's blend factors. Culling, depth and stencil do not apply: the
    /// target has no depth buffer and the quad is drawn without culling.
    func pipeline(for program: TranslatedSourceProgram) throws -> (state: any MTLRenderPipelineState, compiled: Bool) {
        guard program.fragmentOnly else { throw TranslatedSourceProgram.ProgramError.invalid("\(program.name) is not a fragment-only create program") }
        let key = program.url.standardizedFileURL.path + "#" + program.sourceSHA256
        lock.lock(); if let cached = pipelines[key] { lock.unlock(); return (cached, false) }; lock.unlock()
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let library = try device.makeLibrary(source: program.source + (try Self.blitVertexSource(program)), options: options)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "ikkoku_blit_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "source_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .rgba8Unorm_srgb
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = program.state.sourceRGB; attachment.destinationRGBBlendFactor = program.state.destinationRGB
        attachment.sourceAlphaBlendFactor = program.state.sourceAlpha; attachment.destinationAlphaBlendFactor = program.state.destinationAlpha
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        lock.lock(); defer { lock.unlock() }
        if let cached = pipelines[key] { return (cached, false) }
        pipelines[key] = state; compiledPipelines += 1
        return (state, true)
    }

    /// Composes one target. `textures`/`samplers` are keyed by the program's
    /// texture and sampler slots; `buffers` are the packed fragment constant
    /// buffers (`TranslatedSourceProgram.pack`).
    public func compose(program: TranslatedSourceProgram, width: Int, height: Int, mipLevels: Int,
                        textures: [Int: any MTLTexture], samplers: [Int: any MTLSamplerState],
                        buffers: [(slot: Int, data: [Float])], label: String) throws -> (texture: any MTLTexture, statistics: Statistics) {
        // Drain the command buffer and encoders here: an autoreleased command
        // buffer would keep the target alive past its owning materials.
        try autoreleasepool { try encode(program: program, width: width, height: height, mipLevels: mipLevels,
                                         textures: textures, samplers: samplers, buffers: buffers, label: label) }
    }

    private func encode(program: TranslatedSourceProgram, width: Int, height: Int, mipLevels: Int,
                        textures: [Int: any MTLTexture], samplers: [Int: any MTLSamplerState],
                        buffers: [(slot: Int, data: [Float])], label: String) throws -> (texture: any MTLTexture, statistics: Statistics) {
        let start = CACurrentMediaTime()
        guard (1...4096).contains(width), (1...4096).contains(height),
              mipLevels == 1 + Int(log2(Double(max(width, height)))) else {
            throw TranslatedSourceProgram.ProgramError.invalid("composite \(width)x\(height) with \(mipLevels) mips is not a full RenderTexture chain")
        }
        let (pipeline, compiled) = try pipeline(for: program)
        for parameter in program.fragment.textures where textures[parameter.slot] == nil || samplers[parameter.samplerSlot] == nil {
            throw TranslatedSourceProgram.ProgramError.invalid("composite input \(parameter.name) is not bound")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: mipLevels > 1)
        descriptor.mipmapLevelCount = mipLevels; descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor) else { throw TranslatedSourceProgram.ProgramError.invalid("composite target allocation") }
        target.label = label
        let commandQueue: any MTLCommandQueue
        lock.lock()
        if let existing = queue { commandQueue = existing }
        else if let created = device.makeCommandQueue() { created.label = "Source composites"; queue = created; commandQueue = created }
        else { lock.unlock(); throw TranslatedSourceProgram.ProgramError.invalid("composite command queue") }
        lock.unlock()
        guard let command = commandQueue.makeCommandBuffer() else { throw TranslatedSourceProgram.ProgramError.invalid("composite command buffer") }
        command.label = label
        let pass = MTLRenderPassDescriptor()
        // GL.Clear(clearColor: true, Color.clear) before the blit.
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0); pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw TranslatedSourceProgram.ProgramError.invalid("composite encoder") }
        encoder.setRenderPipelineState(pipeline); encoder.setCullMode(.none)
        for (slot, data) in buffers { data.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: slot + 8) } }
        for (slot, texture) in textures { encoder.setFragmentTexture(texture, index: slot) }
        for (slot, sampler) in samplers { encoder.setFragmentSamplerState(sampler, index: slot) }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        if mipLevels > 1 {
            guard let blit = command.makeBlitCommandEncoder() else { throw TranslatedSourceProgram.ProgramError.invalid("composite mip encoder") }
            blit.generateMipmaps(for: target); blit.endEncoding()
        }
        command.commit()
        let encoded = CACurrentMediaTime()
        command.waitUntilCompleted()
        if let error = command.error { throw TranslatedSourceProgram.ProgramError.invalid("composite GPU error: \(error.localizedDescription)") }
        let statistics = Statistics(cpuEncodeMilliseconds: (encoded - start) * 1000,
                                    gpuMilliseconds: max(0, command.gpuEndTime - command.gpuStartTime) * 1000,
                                    totalMilliseconds: (CACurrentMediaTime() - start) * 1000,
                                    pipelineCompiled: compiled, bytes: target.allocatedSize)
        return (target, statistics)
    }
}
