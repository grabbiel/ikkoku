// Asset-free reproducer for #188: does an indexed draw take fragment
// derivatives from a neighbouring triangle? No Ikkoku runtime or original assets.
// Build: swiftc -O Tools/verification/metal_quad_merge_repro.swift -o <binary>
// CPU only: <binary> --self-check
// GPU: <binary> [--repeats 2...32] > report.json
import Foundation
import Metal

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}

private let size = 128

/// A regular grid of `cells` x `cells` quads, two triangles each, sharing
/// vertices. Clip w is 1 and positions are multiples of 1/256 px, so u is
/// affine in window space inside each triangle. u is hashed per vertex
/// (k/64), so neighbouring triangles have different u gradients.
private struct Grid {
    let name: String, cells: Int
    var window: [SIMD2<Double>] = [], u: [Double] = [], indices: [UInt32] = []
    var gradients: [SIMD2<Double>] = []

    init(name: String, cells: Int, cell256: Int) {
        self.name = name; self.cells = cells
        let cell = Double(cell256) / 256, extent = Double(cells) * cell, origin = (Double(size) - extent) / 2
        for row in 0...cells { for column in 0...cells {
            let interior = row > 0 && row < cells && column > 0 && column < cells
            // Jitter interior vertices by up to 0.15 cell, snapped to 1/256 px.
            let jx = interior ? (Double((column * 7 + row * 3) % 5 - 2) * 0.075 * cell * 256).rounded() / 256 : 0
            let jy = interior ? (Double((column * 5 + row * 11) % 7 - 3) * 0.05 * cell * 256).rounded() / 256 : 0
            window.append(SIMD2(origin + Double(column) * cell + jx + 1.0 / 16, origin + Double(row) * cell + jy + 3.0 / 16))
            u.append(Double((column &* 73_856_093 ^ row &* 19_349_663) & 63) / 64)
        } }
        for row in 0..<cells { for column in 0..<cells {
            let a = UInt32(row * (cells + 1) + column), b = a + 1, c = a + UInt32(cells + 1), d = c + 1
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

    /// Per-vertex inputs `{ position, attribute }`, shared or expanded per triangle.
    func inputs(expanded: Bool) -> [SIMD4<Float>] {
        let order = expanded ? indices.map(Int.init) : Array(window.indices)
        return order.flatMap { i in [SIMD4(Float(window[i].x / 64 - 1), Float(1 - window[i].y / 64), 0.5, 1), SIMD4(Float(u[i]), 0, 0, 0)] }
    }
}

/// Fragment alpha test: none, on an interpolated attribute, or on a texture
/// sample taken after the derivatives (the translated programs' shape).
private enum Discard: String, CaseIterable { case none, attribute, sample }

private func source(discard: Discard, vertexStore: Bool) -> String {
    let test: String
    switch discard {
    case .none: test = ""
    case .attribute: test = "if (in.attribute.w < 0.0f) discard_fragment();"
    case .sample: test = "float4 texel = texture.sample(linear, in.attribute.xy); if (texel.w - 0.5f < 0.0f) discard_fragment();"
    }
    return """
    #include <metal_stdlib>
    using namespace metal;
    struct Input { float4 position; float4 attribute; };
    struct Raster { float4 position [[position]]; float4 attribute [[user(locn1)]]; };
    vertex Raster vertexMain(uint vid [[vertex_id]], device \(vertexStore ? "" : "const ")Input *input [[buffer(0)]]) {
        \(vertexStore ? "if (vid == 0xffffffffu) { input[0].position = float4(0.0f); }" : "")
        Raster out; out.position = input[vid].position; out.attribute = input[vid].attribute; return out;
    }
    fragment float4 fragmentMain(Raster in [[stage_in]], uint primitive [[primitive_id]],
                                 texture2d<float> texture [[texture(0)]], sampler linear [[sampler(0)]]) {
        float4 result = float4(dfdx(in.attribute.x), dfdy(in.attribute.x), float(primitive + 1u), 1.0f);
        \(test)
        return result;
    }
    """
}

private func selfCheck() throws {
    let grid = Grid(name: "check", cells: 16, cell256: 1536)
    try require(grid.window.count == 289 && grid.indices.count == 1536 && grid.gradients.count == 512, "Grid counts")
    try require(grid.window[0] == SIMD2(16.0625, 16.1875) && grid.window[288] == SIMD2(112.0625, 112.1875), "Grid corners")
    try require(grid.window.allSatisfy { ($0 * 256).x.rounded() == $0.x * 256 && ($0 * 256).y.rounded() == $0.y * 256 }, "Positions on the 1/256 grid")
    // The first triangle (0, 1, 17): u = 0, 29/64 and 31/64 over a 6 x 6 px right corner.
    try require(grid.u[0] == 0 && grid.u[1] == 29.0 / 64 && grid.u[17] == 31.0 / 64, "Hashed u literals")
    try require(grid.gradients[0] == SIMD2(29.0 / 384, 31.0 / 384), "First triangle gradient")
    try require(Set(grid.gradients.map { "\($0)" }).count > 400, "Neighbouring triangles must have distinct gradients")
    let expanded = grid.inputs(expanded: true), shared = grid.inputs(expanded: false)
    try require(expanded.count == 2 * 1536 && shared.count == 2 * 289 && expanded[2] == shared[2 * 1], "Input layouts")
    let fine = Grid(name: "check", cells: 96, cell256: 192)
    try require(fine.window.first == SIMD2(28.0625, 28.1875) && fine.gradients.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "Sub-pixel grid")
}

private func run(repeats: Int) throws -> [String: Any] {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure("No Metal device/queue") }
    func texture(_ format: MTLPixelFormat, shared: Bool) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        descriptor.usage = .renderTarget; descriptor.storageMode = shared ? .shared : .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure("Target allocation") }
        return texture
    }
    let color = try texture(.rgba32Float, shared: true), depth = try texture(.depth32Float, shared: false)
    let depthDescriptor = MTLDepthStencilDescriptor(); depthDescriptor.depthCompareFunction = .greaterEqual; depthDescriptor.isDepthWriteEnabled = true
    guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw Failure("Depth state") }
    // An opaque 4 x 4 texture: the sampled alpha test never discards.
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
    textureDescriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: textureDescriptor), let sampler = device.makeSamplerState(descriptor: {
        let descriptor = MTLSamplerDescriptor(); descriptor.minFilter = .linear; descriptor.magFilter = .linear
        descriptor.sAddressMode = .repeat; descriptor.tAddressMode = .repeat; return descriptor }()) else { throw Failure("Texture/sampler") }
    let opaque = [UInt8](repeating: 255, count: 64)
    texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: opaque, bytesPerRow: 16)
    let options = MTLCompileOptions(); options.fastMathEnabled = false
    var cases: [[String: Any]] = []
    for grid in [Grid(name: "grid-6px", cells: 16, cell256: 1536), Grid(name: "grid-0.75px", cells: 96, cell256: 192)] {
        for indexed in [true, false] { for blend in [false, true] { for discard in Discard.allCases { for vertexStore in [false, true] {
            let library = try device.makeLibrary(source: source(discard: discard, vertexStore: vertexStore), options: options)
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexMain"); pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
            pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba32Float; pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
            // Translated pipelines always enable blending, even for one/zero passes.
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = blend
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one; pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .zero
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one; pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .zero
            let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            let inputs = grid.inputs(expanded: !indexed)
            guard let input = device.makeBuffer(bytes: inputs, length: inputs.count * 16, options: .storageModeShared),
                  let indexBuffer = device.makeBuffer(bytes: grid.indices, length: grid.indices.count * 4, options: .storageModeShared)
            else { throw Failure("Buffer allocation") }
            var readbacks: [[Float]] = []
            for _ in 0..<repeats {
                guard let command = queue.makeCommandBuffer() else { throw Failure("Command buffer") }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.clearDepth = 0
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure("Encoder") }
                encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState); encoder.setCullMode(.none)
                encoder.setVertexBuffer(input, offset: 0, index: 0)
                encoder.setFragmentTexture(texture, index: 0); encoder.setFragmentSamplerState(sampler, index: 0)
                if indexed {
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: grid.indices.count, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0)
                } else {
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: grid.indices.count)
                }
                encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                try require(command.status == .completed, "GPU command failed: \(command.error?.localizedDescription ?? "unknown")")
                var pixels = [Float](repeating: 0, count: size * size * 4)
                pixels.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: size * 16, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
                readbacks.append(pixels)
            }
            var covered = 0, otherPrimitive = 0
            for pixel in 0..<(size * size) where readbacks[0][pixel * 4 + 3] == 1 {
                covered += 1
                let id = Int(readbacks[0][pixel * 4 + 2]) - 1
                try require(grid.gradients.indices.contains(id), "Invalid primitive ID")
                let expected = grid.gradients[id], dx = Double(readbacks[0][pixel * 4]), dy = Double(readbacks[0][pixel * 4 + 1])
                // Relative tolerance: sub-pixel triangles have steep gradients.
                let tolerance = 1e-4 * max(1, abs(expected.x), abs(expected.y))
                if abs(dx - expected.x) > tolerance || abs(dy - expected.y) > tolerance { otherPrimitive += 1 }
            }
            let changed = readbacks.dropFirst().map { readback in
                (0..<(size * size)).filter { pixel in (0..<4).contains { readback[pixel * 4 + $0] != readbacks[0][pixel * 4 + $0] } }.count
            }
            cases.append(["grid": grid.name, "triangles": grid.gradients.count, "draw": indexed ? "indexed-shared-vertices" : "non-indexed",
                          "blendingEnabled": blend, "fragmentDiscard": discard.rawValue, "vertexStore": vertexStore, "coveredPixels": covered,
                          "pixelsWithAnotherTrianglesDerivatives": otherPrimitive, "repeatChangedPixels": changed])
        } } } }
    }
    return ["schemaVersion": 1, "device": device.name, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "compiler": ["languageVersionRaw": options.languageVersion.rawValue, "fastMathEnabled": options.fastMathEnabled],
            "width": size, "height": size, "repeats": repeats, "cases": cases,
            "limits": "Synthetic geometry and one attribute; a pixel counts when its dfdx or dfdy of u is not its own triangle's analytic window-space gradient. No discard is ever taken and the vertex store never runs. Whether a GPU merges derivative quads across primitives is driver behaviour, not a Metal contract. No performance measurement; exit 0 means collection completed."]
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    try selfCheck()
    if args == ["--self-check"] { print("CPU self-check passed; no Metal device created"); exit(0) }
    var repeats = 4
    if args.count == 2, args[0] == "--repeats", let value = Int(args[1]), (2...32).contains(value) { repeats = value }
    else if !args.isEmpty { throw Failure("Usage: metal_quad_merge_repro --self-check | [--repeats 2...32]") }
    let report = try run(repeats: repeats)
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
} catch {
    fputs("metal_quad_merge_repro: \(error)\n", stderr)
    exit(1)
}
