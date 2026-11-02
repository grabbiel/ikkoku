import Testing
import Foundation
import Metal
import simd
import Assets
import CoreMath
import ShaderTypes
@testable import Renderer

// The original player's sampler state for character and item textures
// (Common.h, forcedAnisoRepeat / forcedAnisoClamp): CharaStudio runs
// QualitySettings.anisotropicFiltering ForceEnable, so every mipmapped, non-point
// texture with anisoLevel above 0 samples with anisotropy 9 and linear mips. The
// map textures already did (mapTexturesSampleWithThePlayersForcedAnisotropy).
//
// Every draw here has the map test's footprint: 16 texels per pixel across and 1
// down (ratio 16) on a 1024² texture whose levels 0 and 1 are white and every
// coarser level black. Anisotropy 9 reads levels 0-1; trilinear (max_anisotropy 1)
// reads level 4 or coarser. Each texture slot is checked by difference: the draw
// with the level texture must match the draw with an all-white texture there, and
// the all-white and all-black draws must differ, so the slot is observed at all.

private let side = 64

private func shaderSource(anisotropy: Int = 9) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ file: String) throws -> String { try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) }
    let header = try read("Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h")
    var common = try read("Shaders/Common.h").replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "")
    if anisotropy != 9 {
        // The control: the same shaders with the forced samplers at another anisotropy.
        let forced = "mip_filter::linear, max_anisotropy(9)"
        #expect(common.components(separatedBy: forced).count == 3, "Common.h's two forced samplers")
        common = common.replacingOccurrences(of: forced, with: "mip_filter::linear, max_anisotropy(\(anisotropy))")
    }
    let shaders = try ["Toon", "Outline"].map {
        try read("Shaders/\($0).metal").replacingOccurrences(of: "#include \"Common.h\"", with: "")
    }.joined(separator: "\n")
    return "#include <metal_stdlib>\nusing namespace metal;\n" + header + common + shaders
}

private struct ToonAnisotropyProbe {
    let device: any MTLDevice
    let resources: ResourceStore
    let queue: any MTLCommandQueue
    let library: any MTLLibrary
    let target: any MTLTexture
    let depth: any MTLTexture
    let mesh: GPUMesh
    let handle: MeshHandle

    init(anisotropy: Int = 9) throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        resources = ResourceStore(device: device)
        queue = try #require(device.makeCommandQueue())
        library = try device.makeLibrary(source: try shaderSource(anisotropy: anisotropy), options: nil)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: side, height: side, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]; targetDescriptor.storageMode = .shared
        target = try #require(device.makeTexture(descriptor: targetDescriptor))
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1, mipmapped: false)
        depthDescriptor.usage = .shaderRead; depthDescriptor.storageMode = .private
        depth = try #require(device.makeTexture(descriptor: depthDescriptor))
        // Clip x -1...1 is u 0...1 (1024 texels over 64 pixels); clip y -1...1 is v 0...1/16 (64 texels).
        let positions = [Float3(-1, -1, 0.25), Float3(3, -1, 0.25), Float3(-1, 3, 0.25)]
        let uvs = positions.map { Float2(($0.x + 1) / 2, ($0.y + 1) / 32) }
        let data = MeshData(name: "toon-aniso-probe", positions: positions, normals: Array(repeating: Float3(0, 0, 1), count: 3),
                            uvs: uvs, uvs1: uvs, uvs2: uvs, indices: [0, 1, 2])
        handle = try resources.register(mesh: data)
        mesh = try #require(resources.mesh(handle))
    }

    /// A 1024² mipmapped RGBA8 texture: levels 0-1 `fine`, coarser levels `coarse`.
    func levels(fine: UInt8, coarse: UInt8, alpha: UInt8? = nil) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1024, height: 1024, mipmapped: true)
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        for level in 0..<texture.mipmapLevelCount {
            let size = 1024 >> level, value = level <= 1 ? fine : coarse
            var bytes = [UInt8](repeating: value, count: size * size * 4)
            if let alpha { for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = alpha } }
            texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: level, withBytes: bytes, bytesPerRow: size * 4)
        }
        return texture
    }

    /// The mean colour of one full-screen draw of `fragment` with `material`,
    /// `texture` bound at `index`, the transparent black 1×1 texture at `black` and
    /// the white 1×1 texture in every other slot.
    func render(vertex: String = "toon_vertex", fragment: String, material state: MaterialUniforms,
                texture: any MTLTexture, at index: TextureIndex, black: [TextureIndex] = []) throws -> Float3 {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        var material = state
        var frame = FrameUniforms(); frame.viewProjection = matrix_identity_float4x4
        frame.shadowViewProjection = matrix_identity_float4x4; frame.cameraPosition = Float4(0, 0, 1, 1)
        frame.mainLightDirection = Float4(0, 0, 1, 0)   // towards the camera; w 0: no shadow term
        frame.mainLightColor = Float4(1, 1, 1, 1)
        frame.viewport = Float4(Float(side), Float(side), 1 / Float(side), 1 / Float(side))
        var draw = DrawUniforms(); draw.model = matrix_identity_float4x4; draw.normalMatrix = matrix_identity_float4x4
        var lights = LightsUniforms()
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        for (buffer, slot) in [(mesh.baseVertices, BufferIndexVertices), (mesh.texcoords, BufferIndexTexcoords),
            (mesh.texcoords1, BufferIndexTexcoords1), (mesh.texcoords2, BufferIndexTexcoords2),
            (resources.dummyBuffer, BufferIndexVertexColors), (resources.dummyBuffer, BufferIndexVertexHidden)] {
            encoder.setVertexBuffer(buffer, offset: 0, index: Int(slot.rawValue))
        }
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
        encoder.setVertexBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
        encoder.setFragmentBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        encoder.setFragmentBytes(&lights, length: MemoryLayout<LightsUniforms>.stride, index: Int(BufferIndexLights.rawValue))
        for slot in 0...Int(TextureIndexBodyMask.rawValue) {
            encoder.setFragmentTexture(slot == Int(TextureIndexShadowMap.rawValue) ? depth : resources.whiteTexture, index: slot)
        }
        for slot in black { encoder.setFragmentTexture(resources.blackTexture, index: Int(slot.rawValue)) }
        encoder.setFragmentTexture(texture, index: Int(index.rawValue))
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed, "\(fragment) draw failed: \(String(describing: command.error))")
        var pixels = [Float](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: side * 16, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0) }
        var sum = Float3.zero
        for p in stride(from: 0, to: pixels.count, by: 4) { sum += Float3(pixels[p], pixels[p + 1], pixels[p + 2]) }
        return sum / Float(side * side)
    }
}

private struct SlotCase {
    let label: String
    var vertex = "toon_vertex"
    let fragment: String
    let index: TextureIndex
    /// Alpha of every level when the slot reads only RGB and a zero alpha would
    /// change the draw some other way (the eye white treats alpha 0 as absent).
    var alpha: UInt8? = nil
    /// Slots bound to transparent black instead of white.
    var black: [TextureIndex] = []
    let material: MaterialUniforms
}

private func slotCases() -> [SlotCase] {
    func make(_ kind: MaterialKind, _ flags: [MaterialFlags], _ edit: (inout MaterialUniforms) -> Void = { _ in }) -> MaterialUniforms {
        var material = MaterialUniforms.make(kind: kind)
        material.flags = flags.reduce(0) { $0 | $1.rawValue }
        edit(&material)
        return material
    }
    let unlit = MaterialKindUnlit, cloth = MaterialKindCloth
    return [
        SlotCase(label: "toon base, repeat", fragment: "toon_fragment", index: TextureIndexBase,
                 material: make(unlit, [MaterialFlagHasBaseTexture])),
        SlotCase(label: "toon base, iris clamp", fragment: "toon_fragment", index: TextureIndexBase,
                 material: make(unlit, [MaterialFlagHasBaseTexture, MaterialFlagSourceIrisHighlights])),
        SlotCase(label: "colour mask", fragment: "toon_fragment", index: TextureIndexColorMask,
                 material: make(unlit, [MaterialFlagHasColorMask]) {
                     $0.tint1 = Float4(0, 0, 0, 1); $0.tint2 = Float4(0, 0, 0, 1); $0.tint3 = Float4(0, 0, 0, 1)
                 }),
        SlotCase(label: "pattern", fragment: "toon_fragment", index: TextureIndexPattern,
                 material: make(unlit, [MaterialFlagHasColorMask, MaterialFlagHasPattern]) { $0.patternColor = Float4(0, 0, 0, 1) }),
        SlotCase(label: "overlay 0", fragment: "toon_fragment", index: TextureIndexOverlay0,
                 material: make(unlit, [MaterialFlagHasOverlay0]) { $0.overlayColor0 = Float4(0, 0, 0, 1) }),
        SlotCase(label: "overlay 1", fragment: "toon_fragment", index: TextureIndexOverlay1,
                 material: make(unlit, [MaterialFlagHasOverlay1]) { $0.overlayColor1 = Float4(0, 0, 0, 1) }),
        SlotCase(label: "overlay 2", fragment: "toon_fragment", index: TextureIndexOverlay2,
                 material: make(unlit, [MaterialFlagHasOverlay2]) { $0.overlayColor2 = Float4(0, 0, 0, 1) }),
        SlotCase(label: "iris highlight, upper (UV1, clamp)", fragment: "toon_fragment", index: TextureIndexOverlay0,
                 material: make(unlit, [MaterialFlagSourceIrisHighlights, MaterialFlagHasOverlay0]) { $0.overlayColor0 = Float4(0, 0, 0, 1) }),
        SlotCase(label: "iris highlight, lower (UV2, clamp)", fragment: "toon_fragment", index: TextureIndexOverlay1,
                 material: make(unlit, [MaterialFlagSourceIrisHighlights, MaterialFlagHasOverlay1]) { $0.overlayColor1 = Float4(0, 0, 0, 1) }),
        SlotCase(label: "normal map", fragment: "toon_fragment", index: TextureIndexNormal,
                 material: make(cloth, [MaterialFlagHasNormal])),
        SlotCase(label: "detail mask", fragment: "toon_fragment", index: TextureIndexDetail,
                 material: make(cloth, [MaterialFlagHasDetail])),
        SlotCase(label: "line mask", fragment: "toon_fragment", index: TextureIndexLine,
                 material: make(cloth, [MaterialFlagHasLine])),
        SlotCase(label: "body mask", fragment: "toon_fragment", index: TextureIndexBodyMask,
                 material: make(unlit, [MaterialFlagHasBodyMask])),
        SlotCase(label: "eye iris", fragment: "eye_fragment", index: TextureIndexBase,
                 material: make(MaterialKindEye, []) { $0.tint1 = Float4(0, 0, 0, 1); $0.eye.w = 0 }),
        SlotCase(label: "eye white", fragment: "eye_fragment", index: TextureIndexColorMask, alpha: 255, black: [TextureIndexBase],
                 material: make(MaterialKindEye, []) { $0.eye.w = 0 }),
        SlotCase(label: "eye highlight", fragment: "eye_fragment", index: TextureIndexDetail,
                 material: make(MaterialKindEye, []) { $0.tint1 = Float4(0, 0, 0, 1); $0.baseColor = Float4(0, 0, 0, 0) }),
        SlotCase(label: "outline alpha test", vertex: "outline_vertex", fragment: "outline_fragment", index: TextureIndexBase,
                 material: make(MaterialKindCloth, [MaterialFlagHasBaseTexture, MaterialFlagAlphaTest]) {
                     $0.outline = Float4(1, 1, 1, 0)   // no extrusion: the hull is the probe triangle
                 }),
    ]
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func characterAndItemTexturesSampleWithThePlayersForcedAnisotropy() throws {
    let probe = try ToonAnisotropyProbe()
    defer { probe.resources.unregister(mesh: probe.handle) }
    var textures: [String: any MTLTexture] = [:]
    func levels(_ fine: UInt8, _ coarse: UInt8, _ alpha: UInt8?) throws -> any MTLTexture {
        let key = "\(fine) \(coarse) \(alpha.map(String.init) ?? "-")"
        if let texture = textures[key] { return texture }
        let texture = try probe.levels(fine: fine, coarse: coarse, alpha: alpha)
        textures[key] = texture
        return texture
    }
    for slot in slotCases() {
        func draw(_ texture: any MTLTexture) throws -> Float3 {
            try probe.render(vertex: slot.vertex, fragment: slot.fragment, material: slot.material, texture: texture, at: slot.index, black: slot.black)
        }
        let fine = try draw(try levels(255, 0, slot.alpha))
        let white = try draw(try levels(255, 255, slot.alpha))
        let black = try draw(try levels(0, 0, slot.alpha))
        let span = simd_length(white - black)
        #expect(span > 0.05, "\(slot.label): the slot does not change the draw (white \(white), black \(black))")
        #expect(simd_length(fine - white) <= 0.1 * span, "\(slot.label): \(fine) is not the fine levels' \(white) (coarse \(black))")
    }
}

/// The control: with the forced samplers at anisotropy 1 (trilinear) or 4, the
/// same footprint reads the coarse levels, so the test above can fail.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func lowAnisotropyReadsTheCoarseLevelsOfTheProbeTexture() throws {
    for anisotropy in [1, 4] {
        let probe = try ToonAnisotropyProbe(anisotropy: anisotropy)
        defer { probe.resources.unregister(mesh: probe.handle) }
        let slot = try #require(slotCases().first)
        let fine = try probe.render(fragment: slot.fragment, material: slot.material, texture: try probe.levels(fine: 255, coarse: 0), at: slot.index)
        let black = try probe.render(fragment: slot.fragment, material: slot.material, texture: try probe.levels(fine: 0, coarse: 0), at: slot.index)
        #expect(simd_length(fine - black) < 0.01, "anisotropy \(anisotropy): \(fine) should read the coarse levels (\(black))")
    }
}
