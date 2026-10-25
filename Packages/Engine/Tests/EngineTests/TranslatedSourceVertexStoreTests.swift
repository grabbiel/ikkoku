import Testing
import Foundation
import Metal
@testable import Renderer

// #188: translated draws keep their derivative quads within one primitive.
// Synthetic programs and geometry only; nothing here reads original data.

private let constInput = "device const SourceInput *input [[buffer(0)]]"

@Test func translatedVertexStoreRewritesOnlyTheVertexStage() throws {
    for source in [LiveProgramFixture.uvSource, LiveProgramFixture.lineSpec(outline: false).source] {
        let rewritten = try TranslatedSourceVertexStore.rewrite(source)
        #expect(!rewritten.contains(constInput))
        #expect(rewritten.components(separatedBy: "device SourceInput *input [[buffer(0)]]").count == 2)
        #expect(rewritten.components(separatedBy: "if (vid == 0xffffffffu) { input[0].v0 = float4(0.0f); } SourceOutput out;").count == 2)
        // Removing the two edits gives the source back byte for byte.
        let restored = rewritten.replacingOccurrences(of: "if (vid == 0xffffffffu) { input[0].v0 = float4(0.0f); } ", with: "")
            .replacingOccurrences(of: "device SourceInput *input [[buffer(0)]]", with: constInput)
        #expect(restored == source)
        // The fragment stage is untouched.
        let fragment = try #require(source.range(of: "fragment "))
        #expect(rewritten.hasSuffix(String(source[fragment.lowerBound...])))
    }
    // It composes with the probe's 24-bit depth emulation, which edits only the fragment.
    let fragmentShaped = """
    #include <metal_stdlib>
    using namespace metal;
    struct SourceInput { float4 v0; float4 v1; };
    struct SourceOutput { float4 v0 [[position]]; float4 v1 [[user(locn1)]]; };
    vertex SourceOutput source_vertex(uint vid [[vertex_id]], device const SourceInput *input [[buffer(0)]], constant float4 *cb0 [[buffer(8)]]) {
        float4 v0 = input[vid].v0;
        SourceOutput out; out.v0 = v0; out.v1 = input[vid].v1; return out;
    }
    struct SourceFragmentInput { float4 v1 [[user(locn1)]]; };
    fragment float4 source_fragment(SourceFragmentInput in [[stage_in]], bool isFront [[front_facing]], constant float4 *cb0 [[buffer(8)]]) {
        float4 o0 = in.v1;
        if (as_type<uint4>(o0).x != 0u) discard_fragment();
        return o0;
    }
    """
    let both = try TranslatedSourceDepth24.rewrite(try TranslatedSourceVertexStore.rewrite(fragmentShaped))
    #expect(both.contains("device SourceInput *input [[buffer(0)]]") && both.contains("ikkoku_depth [[depth(any)]]"))
    #expect(both.contains("if (as_type<uint4>(o0).x != 0u) discard_fragment();"))
    // Anything but the translation emitter's vertex shape is rejected, never guessed at.
    let rejected = [
        fragmentShaped.replacingOccurrences(of: "struct SourceInput { float4 v0; float4 v1; };", with: "struct SourceInput { };"),
        fragmentShaped.replacingOccurrences(of: "uint vid [[vertex_id]], ", with: ""),
        fragmentShaped.replacingOccurrences(of: constInput + ", constant", with: "constant float4 *cb1 [[buffer(9)]], " + constInput + ", constant"),
        fragmentShaped.replacingOccurrences(of: "SourceOutput out; out.v0 = v0;", with: "SourceOutput out; out.v0 = v0; SourceOutput out;"),
        fragmentShaped.replacingOccurrences(of: "SourceOutput out;", with: "SourceOutput result;"),
        try TranslatedSourceVertexStore.rewrite(fragmentShaped),
    ]
    for source in rejected {
        #expect(throws: OriginalFrameProbe.ProbeError.self) { _ = try TranslatedSourceVertexStore.rewrite(source) }
    }
}

/// An indexed grid with shared vertices, w = 1 and a per-vertex hashed u, so
/// u is affine inside each triangle with a different gradient per triangle.
/// Positions and u are binary fractions, so each triangle's window-space
/// gradient is exact on the CPU.
private struct QuadMergeGrid {
    static let size = 128, cells = 16
    var inputs: [SIMD4<Float>] = []   // SourceInput { v0 position; v1 attribute }
    var indices: [UInt32] = []
    var gradients: [SIMD2<Double>] = []

    init() {
        var window: [SIMD2<Double>] = [], u: [Double] = []
        let cell = 6.0, origin = 16.0
        for row in 0...Self.cells { for column in 0...Self.cells {
            // Interior vertices are jittered by sixteenths, off the pixel-centre lattice.
            let interior = row > 0 && row < Self.cells && column > 0 && column < Self.cells
            let jx = interior ? Double((column * 7 + row * 3) % 5 - 2) * 0.4375 : 0
            let jy = interior ? Double((column * 5 + row * 11) % 7 - 3) * 0.3125 : 0
            let p = SIMD2(origin + Double(column) * cell + jx + 0.0625, origin + Double(row) * cell + jy + 0.1875)
            window.append(p)
            u.append(Double((column &* 73_856_093 ^ row &* 19_349_663) & 63) / 64)
            inputs.append(SIMD4(Float(p.x / 64 - 1), Float(1 - p.y / 64), 0.5, 1))
            inputs.append(SIMD4(Float(u.last!), 0, 0, 0))
        } }
        for row in 0..<Self.cells { for column in 0..<Self.cells {
            let a = UInt32(row * (Self.cells + 1) + column), b = a + 1, c = a + UInt32(Self.cells + 1), d = c + 1
            indices += (row + column) % 2 == 0 ? [a, b, c, b, d, c] : [a, b, d, a, d, c]
        } }
        for t in stride(from: 0, to: indices.count, by: 3) {
            let i = indices[t..<t + 3].map(Int.init)
            let p = window[i[1]] - window[i[0]], q = window[i[2]] - window[i[0]]
            let du = SIMD2(u[i[1]] - u[i[0]], u[i[2]] - u[i[0]])
            let determinant = p.x * q.y - p.y * q.x
            gradients.append(SIMD2((du.x * q.y - du.y * p.y) / determinant, (du.y * p.x - du.x * q.x) / determinant))
        }
    }
}

private func quadMergeSpec(discard: Bool) -> LiveProgramFixture.Spec {
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct SourceInput { float4 v0; float4 v1; };
    struct SourceOutput { float4 v0 [[position]]; float4 v1 [[user(locn1)]]; };
    vertex SourceOutput source_vertex(uint vid [[vertex_id]], device const SourceInput *input [[buffer(0)]]) {
        SourceOutput out; out.v0 = input[vid].v0; out.v1 = input[vid].v1; return out;
    }
    struct SourceFragmentInput { float4 v1 [[user(locn1)]]; };
    fragment float4 source_fragment(SourceFragmentInput in [[stage_in]], uint primitive [[primitive_id]]) {
        float4 o0 = float4(dfdx(in.v1.x), dfdy(in.v1.x), float(primitive + 1u), 1.0f);
        \(discard ? "if (in.v1.w < 0.0f) discard_fragment();" : "")
        return o0;
    }
    """
    return LiveProgramFixture.Spec(inputs: [("POSITION", 0), ("TEXCOORD", 0)], source: source)
}

/// Draws the grid `repeats` times with `pipeline`; returns each readback and
/// the number of covered pixels whose derivatives are not their own triangle's.
private func drawGrid(_ grid: QuadMergeGrid, pipeline: any MTLRenderPipelineState, entry: TranslatedSourcePipelineCache.Entry,
                      device: any MTLDevice, repeats: Int) throws -> (readbacks: [[Float]], covered: Int, otherPrimitive: Int) {
    let size = QuadMergeGrid.size
    let queue = try #require(device.makeCommandQueue())
    let input = try #require(device.makeBuffer(bytes: grid.inputs, length: grid.inputs.count * 16, options: .storageModeShared))
    let indices = try #require(device.makeBuffer(bytes: grid.indices, length: grid.indices.count * 4, options: .storageModeShared))
    func target(_ format: MTLPixelFormat, shared: Bool) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        descriptor.usage = .renderTarget; descriptor.storageMode = shared ? .shared : .private
        return try #require(device.makeTexture(descriptor: descriptor))
    }
    let color = try target(.rgba32Float, shared: true), depth = try target(.depth32Float_stencil8, shared: false)
    var readbacks: [[Float]] = []
    for _ in 0..<repeats {
        let command = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.clearDepth = 0
        pass.stencilAttachment.texture = depth; pass.stencilAttachment.loadAction = .clear
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        TranslatedSourcePipelineCache.apply(entry, to: encoder)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(input, offset: 0, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: grid.indices.count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed)
        var pixels = [Float](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: size * 16, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
        readbacks.append(pixels)
    }
    var covered = 0, otherPrimitive = 0
    let first = readbacks[0]
    for pixel in 0..<(size * size) where first[pixel * 4 + 3] == 1 {
        covered += 1
        let id = Int(first[pixel * 4 + 2]) - 1
        try #require(grid.gradients.indices.contains(id))
        let expected = grid.gradients[id]
        if abs(Double(first[pixel * 4]) - expected.x) > 1e-4 || abs(Double(first[pixel * 4 + 1]) - expected.y) > 1e-4 { otherPrimitive += 1 }
    }
    return (readbacks, covered, otherPrimitive)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func translatedDrawsKeepDerivativeQuadsWithinOnePrimitive() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let directory = try LiveProgramFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let grid = QuadMergeGrid()
    #expect(grid.indices.count == 3 * 2 * QuadMergeGrid.cells * QuadMergeGrid.cells && grid.inputs.count == 2 * 17 * 17)
    let cache = TranslatedSourcePipelineCache(device: device)
    let target = TranslatedSourceTarget(color: .rgba32Float, depthStencil: .depth32Float_stencil8, sampleCount: 1)
    for discard in [true, false] {
        let program = try cache.program(url: try LiveProgramFixture.write(quadMergeSpec(discard: discard), family: discard ? "quad_discard" : "quad_plain", to: directory))
        let entry = try cache.entry(program, target: target)
        let drawn = try drawGrid(grid, pipeline: entry.pipeline, entry: entry, device: device, repeats: 4)
        // 96 x 96 px of grid; outer vertices sit on sixteenths, so the area is exact.
        #expect(drawn.covered == 96 * 96)
        #expect(drawn.otherPrimitive == 0, "discard \(discard): \(drawn.otherPrimitive) of \(drawn.covered) covered pixels took another triangle's derivatives")
        #expect(drawn.readbacks.dropFirst().allSatisfy { $0 == drawn.readbacks[0] }, "discard \(discard): repeated draws differ")

        // Unrewritten control, recorded but not asserted: whether a GPU merges
        // quads across primitives is driver behavior, not a contract.
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let library = try device.makeLibrary(source: program.source, options: options)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "source_vertex"); descriptor.fragmentFunction = library.makeFunction(name: "source_fragment")
        descriptor.colorAttachments[0].pixelFormat = target.color
        descriptor.depthAttachmentPixelFormat = target.depthStencil; descriptor.stencilAttachmentPixelFormat = target.depthStencil
        let control = try drawGrid(grid, pipeline: try device.makeRenderPipelineState(descriptor: descriptor), entry: entry, device: device, repeats: 4)
        let changed = control.readbacks.dropFirst().map { readback in (0..<(readback.count / 4)).filter { pixel in
            (0..<4).contains { readback[pixel * 4 + $0] != control.readbacks[0][pixel * 4 + $0] } }.count }
        print("[#188 quad merge] \(device.name) discard \(discard): with the vertex store 0 of \(drawn.covered) px take another triangle's "
              + "derivatives; without it \(control.otherPrimitive) px, repeat changes \(changed)")
    }
}
