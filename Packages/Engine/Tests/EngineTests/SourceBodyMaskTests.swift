import Foundation
import Testing
import Metal
import simd
import ShaderTypes
import Renderer

@Test func sourceBodyMaskUniformsKeepSharedLayoutAndExplicitDefaults() {
    let material = MaterialUniforms.make(kind: MaterialKindSkin)
    #expect(MemoryLayout<MaterialUniforms>.stride == 288)
    #expect(MemoryLayout<MaterialUniforms>.offset(of: \MaterialUniforms.sourceAlphaA) == 280)
    #expect(MemoryLayout<MaterialUniforms>.offset(of: \MaterialUniforms.sourceAlphaB) == 284)
    #expect(material.sourceAlphaA == 1 && material.sourceAlphaB == 1)
    #expect(material.flags & MaterialFlagSourceBodyMask.rawValue == 0)
}

/// Runs all four production fragment shaders, checking actual discard coverage in color,
/// shadow depth, outline, and object-ID attachments. Expected cases come from source truth tables.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceBodyMaskClipsActualMetalPassesWithIndependentRGControls() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ file: String) throws -> String { try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) }
    let header = try read("Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h")
    let common = try read("Shaders/Common.h").replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "")
    let shaders = try ["Toon", "Shadow", "Outline", "Overlay"].map {
        try read("Shaders/\($0).metal").replacingOccurrences(of: "#include \"Common.h\"", with: "")
    }.joined(separator: "\n")
    let probes = """
    inline float4 maskTestPosition(uint i) {
        float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
        return float4(p[i],0.25,1);
    }
    vertex ToonVertexOut mask_test_toon(uint i [[vertex_id]]) {
        ToonVertexOut o; o.position=maskTestPosition(i); o.worldPos=float3(0); o.worldNormal=float3(0,0,1);
        o.worldTangent=float4(1,0,0,1); o.uv=float2(0.5); o.uv1=o.uv; o.uv2=o.uv; o.color=float4(1); o.shadowCoord=float4(0,0,0,1); o.hidden=0; return o;
    }
    vertex ShadowVertexOut mask_test_shadow(uint i [[vertex_id]]) {
        ShadowVertexOut o; o.position=maskTestPosition(i); o.uv=float2(0.5); o.hidden=0; return o;
    }
    vertex OutlineVertexOut mask_test_outline(uint i [[vertex_id]]) {
        OutlineVertexOut o; o.position=maskTestPosition(i); o.color=float3(1); o.uv=float2(0.5); o.hidden=0; return o;
    }
    vertex PickOut mask_test_pick(uint i [[vertex_id]]) {
        PickOut o; o.position=maskTestPosition(i); o.uv=float2(0.5); return o;
    }
    """
    let library = try device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + header + common + shaders + probes, options: nil)
    let queue = try #require(device.makeCommandQueue())
    let passes = ["toon", "shadow", "outline", "pick"]
    let pipelines = try passes.map { name in
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "mask_test_" + name)
        descriptor.fragmentFunction = library.makeFunction(name: name + "_fragment")
        if name == "shadow" { descriptor.depthAttachmentPixelFormat = .depth32Float }
        else { descriptor.colorAttachments[0].pixelFormat = name == "pick" ? .r32Uint : .rgba8Unorm }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
    let depthState = MTLDepthStencilDescriptor()
    depthState.depthCompareFunction = .always; depthState.isDepthWriteEnabled = true
    let writeDepth = try #require(device.makeDepthStencilState(descriptor: depthState))

    func texture(_ format: MTLPixelFormat, usage: MTLTextureUsage, storage: MTLStorageMode = .shared) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
        descriptor.usage = usage; descriptor.storageMode = storage
        return try #require(device.makeTexture(descriptor: descriptor))
    }
    let mask = try texture(.rgba16Float, usage: .shaderRead)
    let color = try texture(.rgba8Unorm, usage: .renderTarget)
    let pick = try texture(.r32Uint, usage: .renderTarget)
    let depth = try texture(.depth32Float, usage: [.renderTarget, .shaderRead], storage: .private)
    let readback = try #require(device.makeBuffer(length: 256, options: .storageModeShared))
    var frame = FrameUniforms(); frame.cameraPosition = SIMD4(0, 0, 1, 1)
    var lights = LightsUniforms(), draw = DrawUniforms(); draw.objectID = 77

    func survives(passIndex: Int, material: MaterialUniforms) throws -> Bool {
        let name = passes[passIndex], target = name == "shadow" ? depth : (name == "pick" ? pick : color)
        let descriptor = MTLRenderPassDescriptor()
        if name == "shadow" {
            descriptor.depthAttachment.texture = target
            descriptor.depthAttachment.loadAction = .clear; descriptor.depthAttachment.storeAction = .store
            descriptor.depthAttachment.clearDepth = 1
        } else {
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .clear; descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        }
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: descriptor))
        encoder.setRenderPipelineState(pipelines[passIndex])
        if name == "shadow" { encoder.setDepthStencilState(writeDepth) }
        var material = material
        encoder.setFragmentBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
        encoder.setFragmentBytes(&lights, length: MemoryLayout<LightsUniforms>.stride, index: Int(BufferIndexLights.rawValue))
        for index in 0...15 { encoder.setFragmentTexture(index == Int(TextureIndexShadowMap.rawValue) ? depth : mask, index: index) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: readback, destinationOffset: 0,
            destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        blit.endEncoding()
        command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed, "Metal mask pass failed: \(String(describing: command.error))")
        if name == "shadow" { return readback.contents().load(as: Float.self) < 0.5 }
        if name == "pick" { return readback.contents().load(as: UInt32.self) == 77 }
        return readback.contents().load(fromByteOffset: 3, as: UInt8.self) == 255
    }

    // Exact half-float neighbors straddle the source clip boundary without texture quantization ambiguity.
    let below = Float(Float16(0.5).nextDown), above = Float(Float16(0.5).nextUp)
    let masks: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 0), SIMD2(1, 1),
        SIMD2(0.5, 0.5), SIMD2(below, 1), SIMD2(1, below), SIMD2(above, above)]
    let sourceFlags = MaterialFlagHasBodyMask.rawValue | MaterialFlagSourceBodyMask.rawValue
    let cases: [(String, UInt32, Float, Float, [Bool])] = [
        ("source 0/0", sourceFlags, 0, 0, [true, true, true, true, true, true, true, true]),
        ("source 0/1", sourceFlags, 0, 1, [false, true, false, true, true, true, false, true]),
        ("source 1/0", sourceFlags, 1, 0, [false, false, true, true, true, false, true, true]),
        ("source 1/1", sourceFlags, 1, 1, [false, false, false, true, true, false, false, true]),
        ("source floor at threshold", sourceFlags, 0.5, 0.5, [true, true, true, true, true, true, true, true]),
        ("source floor below threshold", sourceFlags, above, above, [false, false, false, true, true, false, false, true]),
        ("generated", MaterialFlagHasBodyMask.rawValue, 0, 0, [true, true, false, false, true, true, false, false]),
        ("no mask", 0, 1, 1, [true, true, true, true, true, true, true, true]),
        ("source convention without mask", MaterialFlagSourceBodyMask.rawValue, 1, 1, [true, true, true, true, true, true, true, true]),
    ]
    for (label, flags, alphaA, alphaB, expected) in cases {
        var material = MaterialUniforms.make(kind: MaterialKindUnlit)
        material.flags = flags; material.sourceAlphaA = alphaA; material.sourceAlphaB = alphaB
        for (index, value) in masks.enumerated() {
            let pixels = [Float16(value.x).bitPattern, Float16(value.y).bitPattern, Float16(0).bitPattern, Float16(1).bitPattern]
            pixels.withUnsafeBytes { mask.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
            for passIndex in passes.indices {
                #expect(try survives(passIndex: passIndex, material: material) == expected[index],
                    "\(passes[passIndex]) / \(label) / mask \(index)")
            }
        }
    }
}
