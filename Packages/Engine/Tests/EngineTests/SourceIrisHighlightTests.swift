import Foundation
import Testing
import Metal
import simd
import Assets
import CoreMath
import ShaderTypes
import Renderer

private func irisProbeMesh(uv0: Float = 0.125, uv1: Float? = 0.375, uv2: Float? = 0.625) -> MeshData {
    MeshData(name: "iris-uv-probe", positions: [Float3(-1, -1, 0.25), Float3(3, -1, 0.25), Float3(-1, 3, 0.25)],
        normals: Array(repeating: Float3(0, 0, 1), count: 3),
        uvs: Array(repeating: Float2(uv0, 0.5), count: 3),
        uvs1: uv1.map { Array(repeating: Float2($0, 0.5), count: 3) } ?? [],
        uvs2: uv2.map { Array(repeating: Float2($0, 0.5), count: 3) } ?? [], indices: [0, 1, 2])
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceIrisExtraUVBuffersPreserveAuthoredValuesAndFallbackToUV0() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let source = irisProbeMesh()
    let mesh = try #require(resources.mesh(try resources.register(mesh: source)))
    for (buffer, values) in [(mesh.texcoords, source.uvs), (mesh.texcoords1, source.uvs1), (mesh.texcoords2, source.uvs2)] {
        #expect(buffer.length == values.count * MemoryLayout<Float2>.stride)
        #expect(Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: Float2.self), count: values.count)) == values)
    }
    let legacy = try #require(resources.mesh(try resources.register(mesh: irisProbeMesh(uv1: nil, uv2: nil))))
    #expect(legacy.texcoords1 === legacy.texcoords)
    #expect(legacy.texcoords2 === legacy.texcoords)
    var noUV = irisProbeMesh(uv1: nil, uv2: nil); noUV.uvs = []
    let zero = try #require(resources.mesh(try resources.register(mesh: noUV)))
    #expect(zero.texcoords1 === zero.texcoords && zero.texcoords2 === zero.texcoords)
    #expect(zero.texcoords.contents().load(as: Float2.self) == .zero)
    #expect(MemoryLayout<Float2>.stride == 8)
    #expect(MemoryLayout<MaterialUniforms>.stride == 288)
    #expect(MaterialUniforms.make(kind: MaterialKindEye).flags & MaterialFlagSourceIrisHighlights.rawValue == 0)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceIrisExtraUVsRejectPartialAndNonfiniteCoordinates() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    for set in 1...2 {
        for values in [[Float2.zero], Array(repeating: Float2(.nan, 0), count: 3), Array(repeating: Float2(0, .infinity), count: 3)] {
            var data = irisProbeMesh()
            if set == 1 { data.uvs1 = values } else { data.uvs2 = values }
            do {
                _ = try resources.register(mesh: data)
                Issue.record("Accepted invalid UV\(set)")
            } catch ResourceError.invalidUV(let reason) {
                #expect(reason.contains("UV\(set)"))
            }
        }
    }
}

/// The actual vertex and fragment entry points exercise three independent GPU UV buffers.
/// Binary-fraction samples and hand-calculated results isolate composition from lighting/sRGB.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceIrisHighlightsUseOriginalUVChannelsAndRecoveredMetalComposition() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let resources = ResourceStore(device: device)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ file: String) throws -> String { try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) }
    let header = try read("Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h")
    let common = try read("Shaders/Common.h").replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "")
    let toon = try read("Shaders/Toon.metal").replacingOccurrences(of: "#include \"Common.h\"", with: "")
    let library = try device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + header + common + toon, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "toon_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "toon_fragment")
    descriptor.colorAttachments[0].pixelFormat = .rgba16Float
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    let queue = try #require(device.makeCommandQueue())

    func rgbaTexture(_ pixels: [Float4], renderTarget: Bool = false) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: pixels.count, height: 1, mipmapped: false)
        descriptor.usage = renderTarget ? [.renderTarget, .shaderRead] : .shaderRead
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let data = pixels.flatMap { p in (0..<4).map { Float16(p[$0]).bitPattern } }
        data.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, pixels.count, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: data.count * 2) }
        return texture
    }
    let base = try rgbaTexture([Float4(0.125, 0.25, 0.375, 0.0625), Float4(0.5, 0.125, 0.25, 0.25), Float4(0, 1, 0, 1), Float4(1, 0, 0, 1)])
    // RGB is deliberately irrelevant: source highlight maps provide alpha only.
    let upper = try rgbaTexture([0, 0.5, 1, 0.25].map { Float4(1, 0, 1, $0) })
    let lower = try rgbaTexture([0, 0.25, 0.75, 1].map { Float4(0, 1, 0, $0) })
    let target = try rgbaTexture([.zero], renderTarget: true)
    let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1, mipmapped: false)
    depthDescriptor.usage = .shaderRead; depthDescriptor.storageMode = .private
    let depth = try #require(device.makeTexture(descriptor: depthDescriptor))
    var frame = FrameUniforms(); frame.viewProjection = matrix_identity_float4x4
    frame.shadowViewProjection = matrix_identity_float4x4; frame.cameraPosition = Float4(0, 0, 1, 1)
    var draw = DrawUniforms(); draw.model = matrix_identity_float4x4; draw.normalMatrix = matrix_identity_float4x4
    var lights = LightsUniforms()

    func render(mesh data: MeshData = irisProbeMesh(), source: Bool = true, strength: Float = 1,
                hasUpper: Bool = true, hasLower: Bool = true, baseAlpha: Float = 1) throws -> Float4 {
        let handle = try resources.register(mesh: data)
        defer { resources.unregister(mesh: handle) }
        let mesh = try #require(resources.mesh(handle))
        var material = MaterialUniforms.make(kind: MaterialKindUnlit)
        material.baseColor = Float4(1, 1, 1, baseAlpha)
        material.flags = MaterialFlagHasBaseTexture.rawValue | MaterialFlagAlphaBlend.rawValue
        if source { material.flags |= MaterialFlagSourceIrisHighlights.rawValue }
        if hasUpper { material.flags |= MaterialFlagHasOverlay0.rawValue }
        if hasLower { material.flags |= MaterialFlagHasOverlay1.rawValue }
        material.overlayColor0 = Float4(1, 0.25, 0.125, 0.5)
        material.overlayColor1 = Float4(0.125, 0.5, 1, 1)
        material.eye.w = strength
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        for (buffer, index) in [(mesh.baseVertices, BufferIndexVertices), (mesh.texcoords, BufferIndexTexcoords),
            (mesh.texcoords1, BufferIndexTexcoords1), (mesh.texcoords2, BufferIndexTexcoords2),
            (resources.dummyBuffer, BufferIndexVertexColors), (resources.dummyBuffer, BufferIndexVertexHidden)] {
            encoder.setVertexBuffer(buffer, offset: 0, index: Int(index.rawValue))
        }
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
        encoder.setVertexBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
        encoder.setFragmentBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        encoder.setFragmentBytes(&lights, length: MemoryLayout<LightsUniforms>.stride, index: Int(BufferIndexLights.rawValue))
        for index in 0...15 { encoder.setFragmentTexture(index == Int(TextureIndexShadowMap.rawValue) ? depth : resources.blackTexture, index: index) }
        encoder.setFragmentTexture(base, index: Int(TextureIndexBase.rawValue))
        encoder.setFragmentTexture(upper, index: Int(TextureIndexOverlay0.rawValue))
        encoder.setFragmentTexture(lower, index: Int(TextureIndexOverlay1.rawValue))
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed, "Iris Metal draw failed: \(String(describing: command.error))")
        var pixel = [UInt16](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
        return Float4(pixel.map { Float(Float16(bitPattern: $0)) })
    }
    func expect(_ result: Float4, _ expected: Float4, _ label: String) {
        #expect((0..<4).allSatisfy { abs(result[$0] - expected[$0]) < 0.0005 }, "\(label): \(result) != \(expected)")
    }
    let unchanged = Float4(0.125, 0.25, 0.375, 0.0625)
    expect(try render(), Float4(0.40625, 0.34375, 0.65625, 0.75), "component maximum / separate UVs")
    expect(try render(strength: 0.5), Float4(0.265625, 0.296875, 0.515625, 0.375), "fractional enable")
    expect(try render(strength: 0), unchanged, "disabled highlights")
    expect(try render(hasLower: false), Float4(0.21875, 0.21875, 0.296875, 0.25), "upper only / color alpha")
    expect(try render(hasUpper: false), Float4(0.1015625, 0.34375, 0.65625, 0.75), "lower only")
    expect(try render(hasUpper: false, hasLower: false), unchanged, "absent masks")
    expect(try render(mesh: irisProbeMesh(uv1: 0.625, uv2: 0.375)), Float4(0.5625, 0.25, 0.3125, 0.5), "channel direction")
    expect(try render(mesh: irisProbeMesh(uv1: 1.375, uv2: -0.375)), Float4(0.40625, 0.34375, 0.65625, 0.75), "authored repeat sampling")
    expect(try render(mesh: irisProbeMesh(uv1: nil, uv2: nil)), unchanged, "legacy buffers alias UV0")
    expect(try render(baseAlpha: 14), Float4(0.40625, 0.34375, 0.65625, 0.875), "preserves greater base alpha")
    expect(try render(source: false), unchanged, "generic overlays use UV0")
    expect(try render(mesh: irisProbeMesh(uv0: 0.375), source: false), Float4(0.390625, 0.0888671875, 0.1953125, 0.25), "generic tint composition preserved")
}
