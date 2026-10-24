// Asset-free numerical diagnostic for #188. No Ikkoku runtime or original assets.
// Build: swiftc -O Tools/verification/metal_derivative_repro.swift -o <binary>
// CPU only: <binary> --self-check
// GPU: <binary> --output <new-directory> [--repeats 4]
import Foundation
import Metal
import CryptoKit
import Darwin

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}
private func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private struct Arguments {
    var output: URL?, repeats = 4, selfCheck = false
    init() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        var index = 0, seen = Set<String>()
        while index < args.count {
            let flag = args[index]; index += 1
            try require(seen.insert(flag).inserted, "Repeated argument: \(flag)")
            switch flag {
            case "--self-check": selfCheck = true
            case "--output", "--repeats":
                try require(index < args.count, "Missing value for \(flag)")
                let value = args[index]; index += 1
                if flag == "--output" { output = URL(fileURLWithPath: value).standardizedFileURL }
                else {
                    guard let count = Int(value), (2...32).contains(count) else { throw Failure("--repeats must be 2...32") }
                    repeats = count
                }
            case "--help":
                print("Usage: metal_derivative_repro --self-check | --output NEW_DIRECTORY [--repeats 2...32]")
                exit(0)
            default: throw Failure("Unknown argument: \(flag)")
            }
        }
        try require(selfCheck || output != nil, "--output is required unless --self-check is used")
    }
}

private let width = 128, height = 128
private struct Vertex { var position: SIMD4<Float>; var uv: SIMD4<Float> }
private struct Mesh {
    let name: String, vertices: [Vertex]
    var bytes: Data { vertices.withUnsafeBytes { Data($0) } }
    var triangleCount: Int { vertices.count / 3 }
}
private func vertex(_ x: Float, _ y: Float, _ u: Float, _ v: Float) -> Vertex {
    Vertex(position: SIMD4(x / 64 - 1, 1 - y / 64, 0.5, 1), uv: SIMD4(u, v, 0, 0))
}
private func screen(_ vertex: Vertex) -> SIMD2<Float> {
    SIMD2((vertex.position.x + 1) * 64, (1 - vertex.position.y) * 64)
}
private func meshes() -> [Mesh] {
    let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
    let order = [[0, 1, 3], [1, 2, 3]]
    let large = order.flatMap { triangle in triangle.map { index in
        let p = corners[index]
        return vertex(32 + p.x * 64, 32 + p.y * 64, p.x, p.y)
    } }
    var continuous: [Vertex] = [], discontinuous: [Vertex] = []
    continuous.reserveCapacity(6144); discontinuous.reserveCapacity(6144)
    // Binary fractions make the affine UV gradients independently checkable.
    let localUV: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(24, 8), SIMD2(8, 40)]
    var triangleID = 0
    for y in 0..<32 { for x in 0..<32 {
        for triangle in order {
            let origin = SIMD2<Float>(Float((triangleID * 17) % 128), Float((triangleID * 37) % 128))
            for (local, index) in triangle.enumerated() {
                let p = SIMD2<Float>(Float(x), Float(y)) * 2 + corners[index] * 2 + SIMD2(repeating: 32)
                continuous.append(vertex(p.x, p.y, (p.x - 32) / 64, (p.y - 32) / 64))
                let uv = (origin + localUV[local]) / 128
                discontinuous.append(vertex(p.x, p.y, uv.x, uv.y))
            }
            triangleID += 1
        }
    } }
    func transformed(shear: Float) -> [Vertex] {
        discontinuous.map { original in
            let p = screen(original)
            let x = p.x + (p.y - 64) * shear + 5.0 / 16
            let y = p.y + 3.0 / 16
            var result = original
            result.position.x = x / 64 - 1; result.position.y = 1 - y / 64
            return result
        }
    }
    return [Mesh(name: "large-continuous", vertices: large), Mesh(name: "small-continuous", vertices: continuous),
            Mesh(name: "small-discontinuous", vertices: discontinuous),
            Mesh(name: "small-discontinuous-translated", vertices: transformed(shear: 0)),
            Mesh(name: "small-discontinuous-sheared", vertices: transformed(shear: 3.0 / 16))]
}
private struct Mip { let size: Int; let bytes: Data }
private func mips() -> [Mip] {
    (0..<8).map { level in
        let size = 128 >> level
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let base = 64 + (((x / 8 + y / 8) & 1) * 128), offset = (y * size + x) * 4
            // All arithmetic is Int before the explicit modulo-256 conversion.
            for channel in 0..<3 { bytes[offset + channel] = UInt8((base + level * 37 * (channel + 1)) & 255) }
            bytes[offset + 3] = 255
        } }
        return Mip(size: size, bytes: Data(bytes))
    }
}
private func gradients(_ mesh: Mesh) -> [SIMD4<Float>] {
    stride(from: 0, to: mesh.vertices.count, by: 3).map { index in
        let a = mesh.vertices[index], b = mesh.vertices[index + 1], c = mesh.vertices[index + 2]
        let p = screen(b) - screen(a), q = screen(c) - screen(a)
        let u = SIMD2(b.uv.x - a.uv.x, b.uv.y - a.uv.y), v = SIMD2(c.uv.x - a.uv.x, c.uv.y - a.uv.y)
        let determinant = p.x * q.y - p.y * q.x
        let dx = (u * q.y - v * p.y) / determinant, dy = (v * p.x - u * q.x) / determinant
        return SIMD4(dx.x, dx.y, dy.x, dy.y)
    }
}
// Inclusive triangle union, not a general Metal rasterizer: these fixture outer
// edges never cross pixel centers. Shared-edge ownership is irrelevant to union.
private func coverage(_ mesh: Mesh) throws -> [Bool] {
    try require(mesh.vertices.count % 3 == 0, "Incomplete coverage triangle")
    var covered = [Bool](repeating: false, count: width * height)
    func point(_ vertex: Vertex) throws -> SIMD2<Double> {
        let p = screen(vertex)
        try require(p.x.isFinite && p.y.isFinite && vertex.position.w == 1, "Coverage requires finite affine positions")
        return SIMD2(Double(p.x), Double(p.y))
    }
    func edge(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ p: SIMD2<Double>) -> Double {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }
    for index in stride(from: 0, to: mesh.vertices.count, by: 3) {
        let a = try point(mesh.vertices[index]), b = try point(mesh.vertices[index + 1]), c = try point(mesh.vertices[index + 2])
        if edge(a, b, c) == 0 { continue }
        let lowX = max(0, min(a.x, min(b.x, c.x))), highX = min(Double(width), max(a.x, max(b.x, c.x)))
        let lowY = max(0, min(a.y, min(b.y, c.y))), highY = min(Double(height), max(a.y, max(b.y, c.y)))
        if lowX >= highX || lowY >= highY { continue }
        for y in Int(floor(lowY))..<Int(ceil(highY)) { for x in Int(floor(lowX))..<Int(ceil(highX)) {
            let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
            let ab = edge(a, b, p), bc = edge(b, c, p), ca = edge(c, a, p)
            if (ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0) { covered[y * width + x] = true }
        } }
    }
    return covered
}
private func words(_ bytes: Data) throws -> [UInt32] {
    try require(bytes.count % 4 == 0, "Float data has a partial word")
    var result = [UInt32](repeating: 0, count: bytes.count / 4)
    result.withUnsafeMutableBytes { target in bytes.copyBytes(to: target) }
    return result
}
private struct Difference {
    var mask: [Bool]
    var numericalPixels = 0, nonfiniteComponents = 0, maxAbsolute = 0.0
    var changedPixels: Int { mask.filter { $0 }.count }
    func report(overlap: [Bool]) -> [String: Any] {
        ["bitChangedPixels": changedPixels, "finiteNumericallyChangedPixels": numericalPixels,
         "nonfiniteComponentsInEitherDraw": nonfiniteComponents, "maximumFiniteAbsDifference": maxAbsolute,
         "overlapWithColorChanges": zip(mask, overlap).filter { pair in pair.0 && pair.1 }.count]
    }
}
private func compare(_ current: [UInt32], _ baseline: [UInt32], channels: Range<Int>) throws -> Difference {
    try require(current.count == baseline.count && current.count % 4 == 0, "Incompatible float planes")
    var result = Difference(mask: [Bool](repeating: false, count: current.count / 4))
    for pixel in result.mask.indices {
        var numerical = false
        for channel in channels {
            let index = pixel * 4 + channel, a = Float(bitPattern: current[index]), b = Float(bitPattern: baseline[index])
            result.mask[pixel] = result.mask[pixel] || current[index] != baseline[index]
            if !a.isFinite || !b.isFinite { result.nonfiniteComponents += 1 }
            else {
                numerical = numerical || a != b
                result.maxAbsolute = max(result.maxAbsolute, abs(Double(a) - Double(b)))
            }
        }
        if numerical { result.numericalPixels += 1 }
    }
    return result
}
private func selfCheck() throws {
    try require(MemoryLayout<Vertex>.stride == 32 && MemoryLayout<Vertex>.offset(of: \.uv) == 16, "Swift/MSL vertex layout mismatch")
    let all = meshes(), levels = mips()
    try require(all.map(\.triangleCount) == [2, 2048, 2048, 2048, 2048], "Triangle count mismatch")
    try require(zip(all[1].vertices, all[2].vertices).allSatisfy { pair in pair.0.position == pair.1.position }, "UV cases have different geometry")
    try require(zip(all[1].vertices, all[2].vertices).contains { pair in pair.0.uv != pair.1.uv }, "Missing UV discontinuity")
    try require(all.allSatisfy { $0.vertices.allSatisfy { $0.position.z == 0.5 && $0.position.w == 1 } }, "Unexpected depth/perspective")
    try require(gradients(all[0]).allSatisfy { $0 == SIMD4(1.0/64, 0, 0, 1.0/64) }, "Large-quad analytic gradient")
    try require(gradients(all[2])[0] == SIMD4(0.09375, 0.03125, 0.03125, 0.15625), "First discontinuous triangle gradient")
    let translatedPositions: [SIMD2<Float>] = [SIMD2(32.3125, 32.1875), SIMD2(34.3125, 32.1875), SIMD2(32.3125, 34.1875)]
    let shearedPositions: [SIMD2<Float>] = [SIMD2(26.3125, 32.1875), SIMD2(28.3125, 32.1875), SIMD2(26.6875, 34.1875)]
    try require(all[3].vertices.prefix(3).map(screen) == translatedPositions, "Literal translated positions")
    try require(all[4].vertices.prefix(3).map(screen) == shearedPositions, "Literal sheared positions")
    try require(gradients(all[3])[0] == SIMD4(0.09375, 0.03125, 0.03125, 0.15625), "Literal translated gradient")
    // x' = x + 3y/16: dUV/dy' = dUV/dy - 3*dUV/dx/16.
    try require(gradients(all[4])[0] == SIMD4(0.09375, 0.03125, 0.013671875, 0.150390625), "Literal sheared gradient")
    for mesh in all.suffix(2) {
        try require(zip(all[2].vertices, mesh.vertices).allSatisfy { pair in
            pair.0.uv == pair.1.uv && pair.0.position.z == pair.1.position.z && pair.0.position.w == pair.1.position.w
        }, "Transforms must preserve ordered UVs, depth and clip w")
    }
    func literalCoverage(_ points: [SIMD2<Float>]) throws -> [Bool] {
        try coverage(Mesh(name: "coverage-self-check", vertices: points.map { vertex($0.x, $0.y, 0, 0) }))
    }
    let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(2, 0), SIMD2(0, 2), SIMD2(2, 0), SIMD2(2, 2), SIMD2(0, 2)]
    let union = try literalCoverage(square + square)
    try require(union.enumerated().filter { $0.element }.map { $0.offset } == [0, 1, 128, 129], "Literal union including duplicate/shared edges")
    let clippedSquare: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
    let clipped = try literalCoverage(clippedSquare)
    try require(clipped.enumerated().filter { $0.element }.map { $0.offset } == [0], "Literal viewport-clipped union")
    try require(try literalCoverage([]).allSatisfy { !$0 }, "Empty coverage")
    try require(try literalCoverage([SIMD2(0, 1), SIMD2(1, 1), SIMD2(2, 1)]).allSatisfy { !$0 }, "Degenerate coverage")
    try require(try coverage(all[0]).filter { $0 }.count == 4096, "Original large-quad coverage")
    try require(levels.map { $0.bytes.count }.reduce(0, +) == 87_380, "Authored mip byte counts")
    let examples: [(Int, Int, Int, [UInt8])] = [(0, 0, 0, [64,64,64,255]), (0, 8, 0, [192,192,192,255]),
        (1, 0, 0, [101,138,175,255]), (1, 8, 0, [229,10,47,255]), (7, 0, 0, [67,70,73,255])]
    for (level, x, y, expected) in examples {
        let offset = (y * levels[level].size + x) * 4
        try require(Array(levels[level].bytes[offset..<(offset + 4)]) == expected, "Literal mip texel mismatch")
    }
    let zero = Float(0).bitPattern, negativeZero = Float(-0.0).bitPattern, nan: UInt32 = 0x7fc00001
    let result = try compare([negativeZero, Float(1).nextUp.bitPattern, nan, Float.infinity.bitPattern],
                             [zero, Float(1).bitPattern, nan, Float.infinity.bitPattern], channels: 0..<4)
    try require(result.changedPixels == 1 && result.numericalPixels == 1 && result.nonfiniteComponents == 2,
                "Float comparison must retain signed zero, one-ULP changes and unchanged nonfinite values")
    try require(try words(Data([0,0,128,63])) == [Float(1).bitPattern], "Float byte decoding")
}

private let shader = """
#include <metal_stdlib>
using namespace metal;
struct Vertex { float4 position; float4 uv; };
struct Raster { float4 position [[position]]; float4 uv [[user(locn0)]]; };
struct Output {
    float4 color [[color(0)]];
    float4 uvDx [[color(1)]];
    float4 dyID [[color(2)]];
    float4 sampled [[color(3)]];
};
vertex Raster vertexMain(uint index [[vertex_id]], device const Vertex *vertices [[buffer(0)]]) {
    Raster out; out.position = vertices[index].position; out.uv = vertices[index].uv; return out;
}
fragment Output fragmentMain(Raster in [[stage_in]], uint primitive [[primitive_id]],
                             texture2d<float> texture [[texture(0)]], sampler sourceSampler [[sampler(0)]]) {
    float2 uv = in.uv.xy;
    float4 sampled = texture.sample(sourceSampler, uv);
    Output out;
    out.color = float4(sampled.rgb, 1.0f);
    out.uvDx = float4(uv, dfdx(uv));
    out.dyID = float4(dfdy(uv), float(primitive + 1u), 1.0f);
    out.sampled = sampled;
    return out;
}
"""

private func run(output: URL, repeats: Int) throws {
    // mkdir is atomic: a concurrent creator cannot turn this into an overwrite.
    guard Darwin.mkdir(output.path, 0o755) == 0 else { throw Failure("Cannot create new output directory: \(String(cString: strerror(errno)))") }
    var hashes: [String: String] = [:]
    func save(_ data: Data, _ name: String) throws {
        try data.write(to: output.appendingPathComponent(name), options: .withoutOverwriting)
        hashes[name] = sha(data)
    }
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure("No Metal device/queue") }
    let options = MTLCompileOptions(); options.fastMathEnabled = false
    let library = try device.makeLibrary(source: shader, options: options)
    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexMain")
    pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
    pipelineDescriptor.rasterSampleCount = 1
    for index in 0...3 { pipelineDescriptor.colorAttachments[index].pixelFormat = index == 0 ? .rgba8Unorm_srgb : .rgba32Float }
    pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
    pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
    pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
    let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    let depthDescriptor = MTLDepthStencilDescriptor()
    depthDescriptor.depthCompareFunction = .greaterEqual; depthDescriptor.isDepthWriteEnabled = true
    guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw Failure("Depth state allocation") }
    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .linear; samplerDescriptor.magFilter = .linear; samplerDescriptor.mipFilter = .linear
    samplerDescriptor.sAddressMode = .repeat; samplerDescriptor.tAddressMode = .repeat; samplerDescriptor.rAddressMode = .repeat
    samplerDescriptor.maxAnisotropy = 9
    guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { throw Failure("Sampler allocation") }
    let levels = mips()
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 128, height: 128, mipmapped: true)
    textureDescriptor.usage = .shaderRead; textureDescriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: textureDescriptor) else { throw Failure("Input texture allocation") }
    for (level, mip) in levels.enumerated() {
        mip.bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, mip.size, mip.size), mipmapLevel: level, withBytes: $0.baseAddress!, bytesPerRow: mip.size * 4) }
        try save(mip.bytes, "input-mip\(level).rgba8")
    }
    func target(_ format: MTLPixelFormat, shared: Bool) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget; descriptor.storageMode = shared ? .shared : .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure("Output texture allocation") }
        return texture
    }
    let colors = try [target(.rgba8Unorm_srgb, shared: true)] + (0..<3).map { _ in try target(.rgba32Float, shared: true) }
    let depth = try target(.depth32Float, shared: false)
    try save(Data(shader.utf8), "shader.metal")
    var cases: [[String: Any]] = [], allStable = true, allFinite = true
    for mesh in meshes() {
        let vertices = mesh.bytes, expected = gradients(mesh)
        let expectedCoverage = try coverage(mesh), expectedVisible = expectedCoverage.filter { $0 }.count
        let buffer = vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: vertices.count, options: .storageModeShared) }
        guard let buffer else { throw Failure("Vertex buffer allocation") }
        try save(vertices, "\(mesh.name)-vertices.bin")
        try save(Data(expectedCoverage.map { $0 ? UInt8(1) : UInt8(0) }), "\(mesh.name)-coverage.raw")
        var baseline: [Data] = [], baselineWords: [[UInt32]] = [], draws: [[String: Any]] = []
        for iteration in 0..<repeats {
            guard let command = queue.makeCommandBuffer() else { throw Failure("Command allocation") }
            let pass = MTLRenderPassDescriptor()
            for index in 0...3 {
                pass.colorAttachments[index].texture = colors[index]
                pass.colorAttachments[index].loadAction = .clear; pass.colorAttachments[index].storeAction = .store
                pass.colorAttachments[index].clearColor = MTLClearColorMake(0, 0, 0, 0)
            }
            pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 0
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure("Encoder allocation") }
            encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState); encoder.setCullMode(.none)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0); encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertices.count)
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            try require(command.status == .completed, "GPU command failed: \(command.error?.localizedDescription ?? "unknown")")
            var planes: [Data] = []
            for (index, color) in colors.enumerated() {
                let stride = index == 0 ? 4 : 16
                var bytes = Data(count: width * height * stride)
                bytes.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: width * stride, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
                planes.append(bytes)
                try save(bytes, "\(mesh.name)-\(iteration)-color\(index).raw")
            }
            let floatPlanes = try planes.dropFirst().map(words)
            var visible = 0, nonfinite = 0, maximumGradientError = 0.0
            for pixel in 0..<(width * height) {
                let id = Float(bitPattern: floatPlanes[1][pixel * 4 + 2])
                let valid = Float(bitPattern: floatPlanes[1][pixel * 4 + 3])
                try require((valid == 1) == expectedCoverage[pixel], "CPU/GPU coverage mismatch at pixel \(pixel), \(mesh.name)")
                try require(planes[0][pixel * 4 + 3] == (expectedCoverage[pixel] ? 255 : 0), "Color alpha coverage mismatch")
                if valid == 0 { try require(id == 0, "Background primitive ID"); continue }
                try require(valid == 1 && id.isFinite && id >= 1 && id <= Float(mesh.triangleCount) && id.rounded(.towardZero) == id, "Invalid primitive ID")
                visible += 1
                for plane in floatPlanes { for channel in 0..<4 where !Float(bitPattern: plane[pixel * 4 + channel]).isFinite { nonfinite += 1 } }
                let actual = [floatPlanes[0][pixel * 4 + 2], floatPlanes[0][pixel * 4 + 3], floatPlanes[1][pixel * 4], floatPlanes[1][pixel * 4 + 1]]
                for channel in 0..<4 {
                    let value = Float(bitPattern: actual[channel])
                    if value.isFinite { maximumGradientError = max(maximumGradientError, abs(Double(value) - Double(expected[Int(id) - 1][channel]))) }
                }
            }
            if nonfinite > 0 { allFinite = false }
            try require(visible == expectedVisible, "Unexpected visible pixel count \(visible), CPU union expects \(expectedVisible)")
            var row: [String: Any] = ["iteration": iteration, "visiblePixels": visible, "nonfiniteVisibleComponents": nonfinite,
                                     "maximumAbsAnalyticGradientError": maximumGradientError]
            if iteration == 0 { baseline = planes; baselineWords = floatPlanes }
            else {
                var colorMask = [Bool](repeating: false, count: width * height), maxByte = 0
                for byte in planes[0].indices where planes[0][byte] != baseline[0][byte] {
                    colorMask[byte / 4] = true; maxByte = max(maxByte, abs(Int(planes[0][byte]) - Int(baseline[0][byte])))
                }
                row["colorChangedPixels"] = colorMask.filter { $0 }.count; row["maximumColorByteDifference"] = maxByte
                if colorMask.contains(true) { allStable = false }
                for (name, plane, channels) in [("uv", 0, 0..<2), ("dx", 0, 2..<4), ("dy", 1, 0..<2), ("primitiveID", 1, 2..<4), ("sample", 2, 0..<4)] {
                    let result = try compare(floatPlanes[plane], baselineWords[plane], channels: channels)
                    row[name] = result.report(overlap: colorMask)
                    if result.changedPixels > 0 { allStable = false }
                }
            }
            draws.append(row)
        }
        cases.append(["name": mesh.name, "triangles": mesh.triangleCount, "verticesSHA256": sha(vertices), "expectedCoveredPixels": expectedVisible, "draws": draws])
    }
    // Check every input mip remained unchanged after all draws.
    for (level, mip) in levels.enumerated() {
        var bytes = Data(count: mip.bytes.count)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: mip.size * 4, from: MTLRegionMake2D(0, 0, mip.size, mip.size), mipmapLevel: level) }
        try require(bytes == mip.bytes, "Input mip changed during drawing")
    }
    guard let executable = Bundle.main.executableURL else { throw Failure("Cannot identify running executable") }
    let report: [String: Any] = ["schemaVersion": 1, "referenceTier": "synthetic", "renderingStable": allStable, "allVisibleValuesFinite": allFinite,
        "width": width, "height": height, "repeats": repeats, "cases": cases, "filesSHA256": hashes,
        "binarySHA256": sha(try Data(contentsOf: executable)), "shaderSHA256": sha(Data(shader.utf8)),
        "device": device.name, "registryID": device.registryID, "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "compiler": ["languageVersionRaw": options.languageVersion.rawValue, "fastMathEnabled": options.fastMathEnabled, "preserveInvariance": options.preserveInvariance],
        "sampler": ["minFilter": "linear", "magFilter": "linear", "mipFilter": "linear", "address": "repeat", "maxAnisotropy": 9],
        "inputMipsUnchanged": true,
        "limits": "MRT instrumentation may perturb execution. Affine synthetic UVs, two triangles or a regular grid, one texture and no branch/discard do not establish parity or explain the recovered shader. No performance measurement. Exit0 means collection completed, not repeatability passed."]
    let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: output.appendingPathComponent("report.json"), options: .withoutOverwriting)
    try require(allFinite, "Nonfinite visible values recorded; see report.json")
    print("Collected \(cases.count) cases × \(repeats) draws; renderingStable=\(allStable). Report: \(output.appendingPathComponent("report.json").path)")
}

do {
    let arguments = try Arguments()
    try selfCheck()
    if arguments.selfCheck { print("CPU self-check passed; no Metal device created") }
    else { try run(output: arguments.output!, repeats: arguments.repeats) }
} catch {
    fputs("metal_derivative_repro: \(error)\n", stderr)
    exit(1)
}
