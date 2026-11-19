import Metal

/// The render-command-encoder state one pass has set: a set
/// that would repeat what the encoder already holds is skipped, and a buffer
/// bound again at another offset only moves its offset. Neighbouring records
/// often share a mesh, pipeline, cull mode and textures, and each repeated
/// call costs driver time for nothing.
///
/// Objects are compared by identity and held while recorded, so a released
/// object's address can never pass for one that is still bound. The record
/// is only right while every state change in the encoder goes through it:
/// after code that sets state on `encoder` directly (the live source-shader
/// draws), call `forget()`. With `skips` false every call goes through, which
/// is the reference the tests compare against.
final class EncoderState {
    let encoder: any MTLRenderCommandEncoder
    let skips: Bool
    private var pipeline: (any MTLRenderPipelineState)?
    private var depthStencil: (any MTLDepthStencilState)?
    private var cull: MTLCullMode?
    private var winding: MTLWinding?
    private var vertexBuffers = [(any MTLBuffer)?](repeating: nil, count: EncoderState.slots)
    private var vertexOffsets = [Int](repeating: 0, count: EncoderState.slots)
    private var fragmentBuffers = [(any MTLBuffer)?](repeating: nil, count: EncoderState.slots)
    private var fragmentOffsets = [Int](repeating: 0, count: EncoderState.slots)
    private var fragmentTextures = [(any MTLTexture)?](repeating: nil, count: EncoderState.slots)
    /// The material whose textures `Renderer.bindTextures` bound last, by kind
    /// and handles: the same set binds the same textures again.
    var boundTextureSet: MaterialState.TextureSet?

    /// Buffer and texture indices tracked; `ShaderTypes.h` uses 0...19.
    static let slots = 32

    init(_ encoder: any MTLRenderCommandEncoder, skips: Bool) {
        self.encoder = encoder
        self.skips = skips
    }

    /// Forgets everything recorded: the next set of each state goes through.
    func forget() {
        pipeline = nil; depthStencil = nil; cull = nil; winding = nil; boundTextureSet = nil
        for i in 0..<Self.slots {
            vertexBuffers[i] = nil; fragmentBuffers[i] = nil; fragmentTextures[i] = nil
        }
    }

    func setPipeline(_ state: any MTLRenderPipelineState) {
        if skips, let bound = pipeline, bound === state { return }
        pipeline = state
        encoder.setRenderPipelineState(state)
    }

    func setDepthStencil(_ state: any MTLDepthStencilState) {
        if skips, let bound = depthStencil, bound === state { return }
        depthStencil = state
        encoder.setDepthStencilState(state)
    }

    func setCull(_ mode: MTLCullMode) {
        if skips, cull == mode { return }
        cull = mode
        encoder.setCullMode(mode)
    }

    func setFrontFacing(_ facing: MTLWinding) {
        if skips, winding == facing { return }
        winding = facing
        encoder.setFrontFacing(facing)
    }

    func setVertexBuffer(_ buffer: any MTLBuffer, offset: Int, index: Int) {
        if skips, let bound = vertexBuffers[index], bound === buffer {
            if vertexOffsets[index] == offset { return }
            vertexOffsets[index] = offset
            encoder.setVertexBufferOffset(offset, index: index)
            return
        }
        vertexBuffers[index] = buffer; vertexOffsets[index] = offset
        encoder.setVertexBuffer(buffer, offset: offset, index: index)
    }

    func setFragmentBuffer(_ buffer: any MTLBuffer, offset: Int, index: Int) {
        if skips, let bound = fragmentBuffers[index], bound === buffer {
            if fragmentOffsets[index] == offset { return }
            fragmentOffsets[index] = offset
            encoder.setFragmentBufferOffset(offset, index: index)
            return
        }
        fragmentBuffers[index] = buffer; fragmentOffsets[index] = offset
        encoder.setFragmentBuffer(buffer, offset: offset, index: index)
    }

    /// Moves the offset of the buffer bound at `index` (vertex and fragment).
    func setBufferOffsets(_ offset: Int, index: Int) {
        if !skips || vertexOffsets[index] != offset {
            vertexOffsets[index] = offset
            encoder.setVertexBufferOffset(offset, index: index)
        }
        if !skips || fragmentOffsets[index] != offset {
            fragmentOffsets[index] = offset
            encoder.setFragmentBufferOffset(offset, index: index)
        }
    }

    func setFragmentTexture(_ texture: any MTLTexture, index: Int) {
        if skips, let bound = fragmentTextures[index], bound === texture { return }
        fragmentTextures[index] = texture
        encoder.setFragmentTexture(texture, index: index)
    }
}
