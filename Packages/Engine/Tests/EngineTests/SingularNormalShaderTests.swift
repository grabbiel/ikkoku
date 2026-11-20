import Testing
import Foundation
import Metal
import simd
import CoreMath
import ShaderTypes
@testable import Renderer

// #407: a vertex stage's world normal on a singular model. #404's normal
// matrix for a zero-scale axis is the cofactor matrix, which maps the normals
// perpendicular to that axis to exactly 0, and normalize(0) is NaN. The NaN
// reached every fragment of the triangle. toon_vertex and outline_vertex
// (guardedNormal, Common.h) and live_probe_vertex (its copy) give 0 there and
// exactly normalize(n) everywhere else.
//
// Math mode: every library here compiles from source with the default options,
// fast math, like the shipped metallib (MTL_FAST_MATH = YES) and the live probe
// library (options nil). The bit-for-bit test runs under that math.

private let side = 8

private func read(_ file: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
}

/// `name`'s definition in `source`, from `signature` to its closing brace.
private func definition(_ signature: String, in source: String) throws -> String {
    let start = try #require(source.range(of: signature), "\(signature) not found")
    let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
    return String(source[start.lowerBound..<end.upperBound])
}

/// `text` with `old` replaced by `new` exactly once.
private func replacingOnce(_ text: String, _ old: String, _ new: String) throws -> String {
    try #require(text.components(separatedBy: old).count == 2, "expected one \(old)")
    return text.replacingOccurrences(of: old, with: new)
}

/// The shipped toon_vertex and outline_vertex, a copy of each with the
/// pre-#407 `normalize(nm * v.normal)` (`_unguarded`), outline copies that
/// return the world normal as their colour (`_wn`), and flat read-outs.
private func toonLibrarySource() throws -> String {
    let header = try read("Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h")
    let common = try read("Shaders/Common.h").replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "")
    let toon = try read("Shaders/Toon.metal").replacingOccurrences(of: "#include \"Common.h\"", with: "")
    let outline = try read("Shaders/Outline.metal").replacingOccurrences(of: "#include \"Common.h\"", with: "")
    let guarded = "guardedNormal(nm * v.normal)", unguarded = "normalize(nm * v.normal)"
    let toonVertex = try definition("vertex ToonVertexOut toon_vertex(", in: toon)
    let outlineVertex = try definition("vertex OutlineVertexOut outline_vertex(", in: outline)
    let outlineWN = try replacingOnce(outlineVertex, "o.color = mat.outline.rgb;", "o.color = wn;")
    let copies = [
        try replacingOnce(try replacingOnce(toonVertex, " toon_vertex(", " toon_vertex_unguarded("), guarded, unguarded),
        try replacingOnce(outlineWN, " outline_vertex(", " outline_vertex_wn("),
        try replacingOnce(try replacingOnce(outlineWN, " outline_vertex(", " outline_vertex_wn_unguarded("), guarded, unguarded),
    ]
    let readouts = """
    struct GuardFlatNormal { float4 position [[position]]; float3 worldNormal [[flat]]; };
    fragment float4 guard_flat_normal(GuardFlatNormal in [[stage_in]]) { return float4(in.worldNormal, 1.0); }
    fragment float4 guard_smooth_normal(ToonVertexOut in [[stage_in]]) { return float4(in.worldNormal, 1.0); }
    struct GuardFlatColor { float4 position [[position]]; float3 color [[flat]]; };
    fragment float4 guard_flat_color(GuardFlatColor in [[stage_in]]) { return float4(in.color, 1.0); }

    """
    return "#include <metal_stdlib>\nusing namespace metal;\n" + header + common + toon + outline + "\n"
        + copies.joined(separator: "\n") + readouts
}

/// The live probe library as `captureSourceGeometry` builds it, a
/// `live_probe_vertex_unguarded` copy with the pre-#407 `normalize(n)`, and a
/// flat read-out of `Out.normal`.
private func liveLibrarySource() throws -> String {
    let live = Renderer.liveGeometryMSL
    let vertex = try definition("vertex Out live_probe_vertex(", in: live + "\n")
    let copy = try replacingOnce(try replacingOnce(vertex, " live_probe_vertex(", " live_probe_vertex_unguarded("),
                                 "n = dot(n, n) >= FLT_MIN ? normalize(n) : float3(0.0f);", "n = normalize(n);")
    let readout = """
    struct GuardFlatProbe { float4 position [[position]]; float3 normal [[flat]]; };
    fragment float4 guard_flat_probe(GuardFlatProbe in [[stage_in]]) { return float4(in.normal, 1.0); }

    """
    return OriginalFrameProbe.diagnosticMSL + live + "\n" + copy + readout
}

/// Scale (1, 1, 0) moved to z 0.25: a flattened surface. Its normal matrix is
/// the cofactor diag(0, 0, 1): +z stays +z, and x and y map to exactly 0.
private let flattened = Transform.translation(Float3(0, 0, 0.25)) * Transform.scale(Float3(1, 1, 0))

/// One triangle per normal, each around its own pixel centre of the
/// side × side target with that normal on its first (provoking) vertex, in
/// clip space: drawn with `viewProjection` the model's inverse, a flat
/// fragment reads each vertex's output from its pixel.
private func perPixel(_ normals: [Float3]) -> (vertices: [DeformedVertex], indices: [UInt32]) {
    precondition(normals.count <= side * side)
    let d = 0.6 * 2 / Float(side)
    var vertices: [DeformedVertex] = []
    for (i, n) in normals.enumerated() {
        let cx = (Float(i % side) + 0.5) / Float(side) * 2 - 1, cy = 1 - (Float(i / side) + 0.5) / Float(side) * 2
        for p in [Float3(cx - d, cy - d, 0.25), Float3(cx + 2 * d, cy - d, 0.25), Float3(cx - d, cy + 2 * d, 0.25)] {
            vertices.append(DeformedVertex(position: Float4(p, 0), normal: Float4(n, 1), tangent: Float4(1, 0, 0, 1)))
        }
    }
    return (vertices, (0..<UInt32(vertices.count)).map { $0 })
}

/// One triangle over the whole target: +z on vertices 0 and 1, `third` on
/// vertex 2 (outside the target, so every pixel has a nonzero share of +z).
/// `first` rotates the index list so that vertex is the provoking one.
private func fullTarget(third: Float3, first: Int = 0) -> (vertices: [DeformedVertex], indices: [UInt32]) {
    let positions = [Float3(-1, -1, 0.25), Float3(3, -1, 0.25), Float3(-1, 3, 0.25)], normals = [Float3(0, 0, 1), Float3(0, 0, 1), third]
    let vertices = (0..<3).map { DeformedVertex(position: Float4(positions[$0], 0), normal: Float4(normals[$0], 1), tangent: Float4(1, 0, 0, 1)) }
    return (vertices, (0..<3).map { UInt32(($0 + first) % 3) })
}

private struct NormalGuardProbe {
    let device: any MTLDevice
    let resources: ResourceStore
    let queue: any MTLCommandQueue
    let toon: any MTLLibrary
    let live: any MTLLibrary
    let depth: any MTLTexture

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        resources = ResourceStore(device: device)
        queue = try #require(device.makeCommandQueue())
        toon = try device.makeLibrary(source: try toonLibrarySource(), options: nil)
        live = try device.makeLibrary(source: try liveLibrarySource(), options: nil)
        depth = try mapShadowPlaceholder(device)
    }

    private func target(_ size: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func pass(_ target: any MTLTexture) -> MTLRenderPassDescriptor {
        // Cleared to -1: a pixel no triangle reaches reads -1 in every channel.
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: -1, green: -1, blue: -1, alpha: -1)
        return pass
    }

    private func pixels(_ target: any MTLTexture) -> [Float] {
        var pixels = [Float](repeating: 0, count: target.width * target.height * 4)
        pixels.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: target.width * 16, from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        }
        return pixels
    }

    private func buffer<T>(_ values: [T]) throws -> any MTLBuffer {
        try #require(values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
    }

    /// The rgba32Float pixels of one draw of `vertex` + `fragment` from the
    /// toon library: `model` with its `Transform.normalMatrix`, every colour
    /// texture white, both shadow maps a depth placeholder.
    func render(_ vertex: String, _ fragment: String, mesh: (vertices: [DeformedVertex], indices: [UInt32]), model: float4x4,
                viewProjection: float4x4 = matrix_identity_float4x4, material: MaterialUniforms,
                mapLighting: MapLightingUniforms = MapLightingUniforms(), size: Int = side) throws -> [Float] {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try #require(toon.makeFunction(name: vertex))
        descriptor.fragmentFunction = try #require(toon.makeFunction(name: fragment))
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let target = try target(size)
        var material = material, lights = LightsUniforms()
        var frame = FrameUniforms(); frame.viewProjection = viewProjection
        frame.shadowViewProjection = matrix_identity_float4x4; frame.cameraPosition = Float4(0, 0, 2, 1)
        frame.mainLightDirection = Float4(0, 0, 1, 0); frame.mainLightColor = Float4(1, 1, 1, 1)
        frame.viewport = Float4(Float(size), Float(size), 1 / Float(size), 1 / Float(size))
        frame.outlineParams = Float4(1, 0, 4, 0)
        var draw = DrawUniforms(); draw.model = model; draw.normalMatrix = Transform.normalMatrix(from: model); draw.outlineScale = 1
        let uvs = try buffer([Float2](repeating: Float2(0.5, 0.5), count: mesh.vertices.count))
        let vertices = try buffer(mesh.vertices), indices = try buffer(mesh.indices)
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass(target)))
        encoder.setRenderPipelineState(pipeline)
        for (buffer, slot) in [(vertices, BufferIndexVertices), (uvs, BufferIndexTexcoords), (uvs, BufferIndexTexcoords1), (uvs, BufferIndexTexcoords2),
            (resources.dummyBuffer, BufferIndexVertexColors), (resources.dummyBuffer, BufferIndexVertexHidden), (resources.dummyBuffer, BufferIndexVertexReceive)] {
            encoder.setVertexBuffer(buffer, offset: 0, index: Int(slot.rawValue))
        }
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
        encoder.setVertexBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
        encoder.setFragmentBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        encoder.setFragmentBytes(&lights, length: MemoryLayout<LightsUniforms>.stride, index: Int(BufferIndexLights.rawValue))
        for slot in 0...Int(TextureIndexEmission.rawValue) { encoder.setFragmentTexture(resources.whiteTexture, index: slot) }
        encoder.setFragmentTexture(depth, index: Int(TextureIndexShadowMap.rawValue))
        bindMapLighting(encoder, frame: frame, lighting: mapLighting, shadow: depth)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indices.count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed, "\(vertex) + \(fragment): \(String(describing: command.error))")
        return pixels(target)
    }

    /// The same for the live probe library: `projection · view · model`, with
    /// `view` the identity so `Out.normal` is the world normal itself.
    func renderLive(_ vertex: String, _ fragment: String, mesh: (vertices: [DeformedVertex], indices: [UInt32]), model: float4x4,
                    projection: float4x4 = matrix_identity_float4x4, size: Int = side) throws -> [Float] {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try #require(live.makeFunction(name: vertex))
        descriptor.fragmentFunction = try #require(live.makeFunction(name: fragment))
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let target = try target(size)
        var view = matrix_identity_float4x4, projection = projection, model = model, normal = Transform.normalMatrix(from: model), far: Float = 10
        let vertices = try buffer(mesh.vertices), indices = try buffer(mesh.indices)
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass(target)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&view, length: MemoryLayout<float4x4>.stride, index: 1)
        encoder.setVertexBytes(&projection, length: MemoryLayout<float4x4>.stride, index: 2)
        encoder.setVertexBytes(&model, length: MemoryLayout<float4x4>.stride, index: 3)
        encoder.setVertexBytes(&normal, length: MemoryLayout<float4x4>.stride, index: 4)
        encoder.setFragmentBytes(&far, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indices.count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed, "\(vertex) + \(fragment): \(String(describing: command.error))")
        return pixels(target)
    }
}

private func rgba(_ pixels: [Float]) -> [Float4] {
    stride(from: 0, to: pixels.count, by: 4).map { Float4(pixels[$0], pixels[$0 + 1], pixels[$0 + 2], pixels[$0 + 3]) }
}

/// Every pixel drawn (none left at the -1 clear) and every channel finite.
private func expectDrawnAndFinite(_ pixels: [Float], _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let values = rgba(pixels)
    #expect(values.allSatisfy { $0 != Float4(repeating: -1) }, "\(label): a pixel was not drawn", sourceLocation: sourceLocation)
    let bad = values.filter { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite) }
    #expect(bad.isEmpty, "\(label): \(bad.count) of \(values.count) pixels not finite, e.g. \(bad.first.map { "\($0)" } ?? "")",
            sourceLocation: sourceLocation)
}

/// `pixels` match `reference` on every pixel within a relative 1e-4.
private func expectMatches(_ pixels: [Float], _ reference: [Float], _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let worst = zip(rgba(pixels), rgba(reference)).map { simd_length($0 - $1) / max(1, simd_length($1)) }.max() ?? .infinity
    #expect(worst <= 1e-4, "\(label): off the reference by \(worst), e.g. \(rgba(pixels).first!) vs \(rgba(reference).first!)",
            sourceLocation: sourceLocation)
}

private func probeLitMapMaterial() -> (MaterialUniforms, MapLightingUniforms) {
    var material = MaterialUniforms.make(kind: MaterialKindMap)
    material.flags |= MaterialFlagMapProbeLit.rawValue | MaterialFlagMapSunLit.rawValue
    material.oneMinusReflectivity = 0.8
    var lighting = MapLightingUniforms()
    // An ambient that varies with n (SHAr/g/b xyz) and a sun along +z.
    lighting.sh.0 = Float4(0.1, 0.2, 0.3, 0.5); lighting.sh.1 = Float4(0.3, 0.1, 0.2, 0.5); lighting.sh.2 = Float4(0.2, 0.3, 0.1, 0.5)
    lighting.sunDirection = Float4(0, 0, 1, 1); lighting.sunColor = Float4(1, 1, 1, 1)
    return (material, lighting)
}

// MARK: - The flattened model draws finite values

/// The cofactor normal matrix sends x to exactly 0: the case the guard is for.
@Test func flattenedModelsNormalMatrixSendsInPlaneNormalsToZero() {
    let nm = Transform.normalMatrix3(from: flattened)
    #expect(nm * Float3(1, 0, 0) == .zero && nm * Float3(0, 1, 0) == .zero)
    #expect(nm * Float3(0, 0, 1) == Float3(0, 0, 1))
}

/// 1. toon_vertex + map_fragment (probe-lit, sun-lit) and toon_vertex +
/// toon_fragment over a triangle whose third normal the flattened model sends
/// to 0: every pixel drawn and finite, and shaded as the same triangle with +z
/// on all three vertices (the plane normal the cofactor keeps). Without the
/// guard the NaN vertex normal reached every fragment; this GPU's interpolator
/// turned it into FLT_MAX, so the pixels were finite but wrongly shaded.
@Test func flattenedModelShadesLikeItsPlaneNormalThroughMapAndToonFragments() throws {
    let probe = try NormalGuardProbe()
    let mixed = fullTarget(third: Float3(1, 0, 0)), plane = fullTarget(third: Float3(0, 0, 1))
    let (map, lighting) = probeLitMapMaterial(), item = MaterialUniforms.make(kind: MaterialKindItem)
    for (fragment, material) in [("map_fragment", map), ("toon_fragment", item)] {
        let pixels = try probe.render("toon_vertex", fragment, mesh: mixed, model: flattened, material: material, mapLighting: lighting)
        expectDrawnAndFinite(pixels, fragment)
        expectMatches(pixels, try probe.render("toon_vertex", fragment, mesh: plane, model: flattened, material: material, mapLighting: lighting),
                      fragment)
    }
}

/// 2. toon_vertex's world normal on the flattened model: a normal the cofactor
/// sends to 0 comes out exactly 0, +z stays +z, and the interpolated normal of
/// the mixed triangle is finite and along +z everywhere. A normal too short to
/// normalize (|n|² below FLT_MIN) is 0 too.
@Test func flattenedModelsWorldNormalIsZeroOrAlongThePlaneNormal() throws {
    let probe = try NormalGuardProbe()
    let material = MaterialUniforms.make(kind: MaterialKindItem)
    let normals = [Float3(1, 0, 0), Float3(0, 1, 0), Float3(0.6, -0.8, 0), Float3(0, 0, 1), Float3(0, 0, -2), Float3(1, 1, 1)]
    let flat = rgba(try probe.render("toon_vertex", "guard_flat_normal", mesh: perPixel(normals), model: flattened, material: material))
    let expected = [Float3.zero, .zero, .zero, Float3(0, 0, 1), Float3(0, 0, -1), Float3(0, 0, 1)]
    for (i, want) in expected.enumerated() {
        #expect(flat[i] == Float4(want, 1), "normal \(normals[i]): \(flat[i])")
    }
    let smooth = rgba(try probe.render("toon_vertex", "guard_smooth_normal", mesh: fullTarget(third: Float3(1, 0, 0)), model: flattened,
                                       material: material))
    #expect(smooth.allSatisfy { $0.x == 0 && $0.y == 0 && $0.z > 0 && $0.z.isFinite && $0.w == 1 }, "\(smooth.first!)")
    // Below FLT_MIN (1.18e-38): |n|² 1e-40 under the identity model.
    let tiny = rgba(try probe.render("toon_vertex", "guard_flat_normal", mesh: perPixel([Float3(1e-20, 0, 0), Float3(0, 1e-20, 1e-20)]),
                                     model: matrix_identity_float4x4, material: material))
    #expect(tiny[0] == Float4(0, 0, 0, 1) && tiny[1] == Float4(0, 0, 0, 1), "\(tiny[0]) \(tiny[1])")
}

/// 3. outline_vertex on the flattened model: its extrusion normal (the
/// test copy returns it as the colour) is exactly 0 for the normal the
/// cofactor sends to 0 and +z for +z, and outline_vertex + outline_fragment
/// draw the outline colour over the whole target. (The draw alone also passed
/// without the guard: `len > 1e-5 ? dir / len : 0` dropped the NaN direction.)
@Test func flattenedModelsOutlineNormalIsFiniteAndItDraws() throws {
    let probe = try NormalGuardProbe()
    var material = MaterialUniforms.make(kind: MaterialKindItem)
    material.outline = Float4(0.25, 0.5, 0.75, 1)
    for (first, want) in [(0, Float3(0, 0, 1)), (2, Float3.zero)] {
        let flat = rgba(try probe.render("outline_vertex_wn", "guard_flat_color", mesh: fullTarget(third: Float3(1, 0, 0), first: first),
                                         model: flattened, material: material))
        #expect(flat.allSatisfy { $0 == Float4(want, 1) }, "provoking vertex \(first): \(flat.first!)")
    }
    let pixels = try probe.render("outline_vertex", "outline_fragment", mesh: fullTarget(third: Float3(1, 0, 0)), model: flattened,
                                  material: material)
    expectDrawnAndFinite(pixels, "outline_fragment")
    #expect(rgba(pixels).allSatisfy { Float3($0.x, $0.y, $0.z) == Float3(0.25, 0.5, 0.75) }, "\(rgba(pixels).first!)")
}

/// 4. live_probe_vertex on the flattened model: `Out.normal` is exactly 0 for
/// the normal the cofactor sends to 0 and +z for +z, and the depth-normals
/// encoding of the mixed triangle is finite and the same as the +z triangle's.
@Test func flattenedModelGivesTheLiveProbeAFiniteNormal() throws {
    let probe = try NormalGuardProbe()
    for (first, want) in [(0, Float3(0, 0, 1)), (2, Float3.zero)] {
        let flat = rgba(try probe.renderLive("live_probe_vertex", "guard_flat_probe", mesh: fullTarget(third: Float3(1, 0, 0), first: first),
                                             model: flattened))
        #expect(flat.allSatisfy { $0 == Float4(want, 1) }, "provoking vertex \(first): \(flat.first!)")
    }
    let pixels = try probe.renderLive("live_probe_vertex", "probe_depth_normals", mesh: fullTarget(third: Float3(1, 0, 0)), model: flattened)
    expectDrawnAndFinite(pixels, "probe_depth_normals")
    expectMatches(pixels, try probe.renderLive("live_probe_vertex", "probe_depth_normals", mesh: fullTarget(third: Float3(0, 0, 1)),
                                               model: flattened), "probe_depth_normals")
}

// MARK: - Every nonsingular model: bit for bit the pre-#407 output

/// 64 object normals: the axes, the diagonals and a Fibonacci sphere, with
/// lengths from 0.25 to 4 (a deformed normal need not be unit).
private let objectNormals: [Float3] = {
    var normals = [Float3(1, 0, 0), Float3(-1, 0, 0), Float3(0, 1, 0), Float3(0, -1, 0), Float3(0, 0, 1), Float3(0, 0, -1),
                   Float3(1, 1, 1), Float3(-1, 1, -1)]
    let lengths: [Float] = [1, 0.25, 0.5, 2, 4, 0.75, 1.5]
    let count = 64 - normals.count
    for i in 0..<count {
        let y = 1 - 2 * (Float(i) + 0.5) / Float(count), r = (1 - y * y).squareRoot(), phi = Float(i) * 2.39996323
        normals.append(Float3(r * cos(phi), y, r * sin(phi)) * lengths[i % lengths.count])
    }
    return normals
}()

/// Rotated, non-uniformly scaled, mirrored and small-scaled models: all far
/// from `Transform.singularDeterminant`.
private let nonsingularModels: [(String, float4x4)] = [
    ("identity", matrix_identity_float4x4),
    ("rotation", Transform.trs(Float3(0.1, -0.2, 0.3), simd_quatf(angle: 0.7, axis: simd_normalize(Float3(1, 2, 3))), Float3(1, 1, 1))),
    ("non-uniform scale", Transform.trs(Float3(0, 0.5, 0), simd_quatf(angle: -1.1, axis: simd_normalize(Float3(-2, 1, 0.5))), Float3(0.3, 1.7, 2.5))),
    ("mirrored", Transform.trs(Float3(-0.4, 0, 0.2), simd_quatf(angle: 2.3, axis: simd_normalize(Float3(0, 1, 1))), Float3(-1, 0.8, 1.2))),
    ("small scale", Transform.trs(.zero, simd_quatf(angle: 0.4, axis: Float3(0, 1, 0)), Float3(1e-3, 1, 1))),
    ("sheared", float4x4(Float4(1, 0.3, 0, 0), Float4(0.5, 1, 0.2, 0), Float4(0, -0.4, 1, 0), Float4(0, 0, 0, 1))),
]

private func bits(_ pixels: [Float]) -> [UInt32] { pixels.map(\.bitPattern) }

/// 5. On every nonsingular model, toon_vertex's world normal, outline_vertex's
/// (returned as its colour in a test copy) and live_probe_vertex's are bit for
/// bit the pre-#407 `normalize` copies' in the same library, under the default
/// (fast) math. Each normal is its own triangle's provoking vertex, read flat.
@Test func guardedNormalsMatchThePreGuardNormalizeBitForBitOnNonsingularModels() throws {
    if #available(macOS 15, *) { #expect(MTLCompileOptions().mathMode == .fast, "the default math mode the libraries compile with") }
    let probe = try NormalGuardProbe()
    let mesh = perPixel(objectNormals)
    var material = MaterialUniforms.make(kind: MaterialKindItem)
    material.outline = Float4(1, 1, 1, 0)   // width 0: the outline's position stays on its pixel
    for (name, model) in nonsingularModels {
        #expect(abs(simd_determinant(model.upperLeft3x3)) > 1e3 * Transform.singularDeterminant, "\(name)")
        let inverse = model.inverse   // clip = model⁻¹ · model · p: each triangle stays on its pixel
        let pairs = [
            ("toon_vertex", try probe.render("toon_vertex", "guard_flat_normal", mesh: mesh, model: model, viewProjection: inverse, material: material),
             try probe.render("toon_vertex_unguarded", "guard_flat_normal", mesh: mesh, model: model, viewProjection: inverse, material: material)),
            ("outline_vertex", try probe.render("outline_vertex_wn", "guard_flat_color", mesh: mesh, model: model, viewProjection: inverse, material: material),
             try probe.render("outline_vertex_wn_unguarded", "guard_flat_color", mesh: mesh, model: model, viewProjection: inverse, material: material)),
            ("live_probe_vertex", try probe.renderLive("live_probe_vertex", "guard_flat_probe", mesh: mesh, model: model, projection: inverse),
             try probe.renderLive("live_probe_vertex_unguarded", "guard_flat_probe", mesh: mesh, model: model, projection: inverse)),
        ]
        for (function, guarded, reference) in pairs {
            // The reference is a real normal on every pixel: drawn, finite and unit length.
            let values = rgba(reference)
            #expect(values.allSatisfy { $0.w == 1 && abs(simd_length(Float3($0.x, $0.y, $0.z)) - 1) < 1e-3 }, "\(name) \(function): \(values.first!)")
            let mismatches = zip(bits(guarded), bits(reference)).filter { $0 != $1 }.count
            #expect(mismatches == 0, "\(name) \(function): \(mismatches) of \(reference.count) channels differ")
        }
    }
}
