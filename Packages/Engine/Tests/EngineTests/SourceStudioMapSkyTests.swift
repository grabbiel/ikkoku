import Testing
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import Metal
import simd
import Assets
import CoreMath
import Character
import Scene
import ShaderTypes
@testable import Studio
@testable import Renderer

// ST-A11 maps, slice 3: BC block images and cubes uploaded byte for byte, the
// Skybox/Cubemap sky (sky_vertex / sky_fragment) and the Particles/Alpha
// Blended branch of map_fragment against the cited Unity 5.6.2f1 formulas,
// the sky's pass routing, and a converted map with block images, a sky and
// particles.

// MARK: - Helpers

/// One BC1 block whose 16 texels decode to color0 exactly (colour index 0, color1 0).
private func bc1Block(red: UInt16, green: UInt16, blue: UInt16) -> [UInt8] {
    let color = (red << 11) | (green << 5) | blue
    return [UInt8(color & 0xFF), UInt8(color >> 8), 0, 0, 0, 0, 0, 0]
}

/// Six solid 4x4 BC1 faces (+X, -X, +Y, -Y, +Z, -Z), one mip.
private let faceColors: [(UInt16, UInt16, UInt16)] = [(31, 0, 0), (0, 63, 0), (0, 0, 31), (31, 63, 0), (31, 0, 31), (0, 63, 31)]
private let faceLinear: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 1, 0), SIMD3(1, 0, 1), SIMD3(0, 1, 1)]
private func solidCube() -> Data { Data(faceColors.flatMap { bc1Block(red: $0.0, green: $0.1, blue: $0.2) }) }
/// Six 8x8 BC1 faces whose top block row is face f's colour and bottom block row face f+1's.
private func twoToneCube() -> Data {
    Data((0..<6).flatMap { f -> [UInt8] in
        let (top, bottom) = (faceColors[f], faceColors[(f + 1) % 6])
        let t = bc1Block(red: top.0, green: top.1, blue: top.2), b = bc1Block(red: bottom.0, green: bottom.1, blue: bottom.2)
        return t + t + b + b
    })
}

private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func json(_ value: [String: Any]) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
}

private func shaderLibrary(_ device: any MTLDevice) throws -> any MTLLibrary {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ file: String) throws -> String { try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) }
    let header = try read("Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h")
    let common = try read("Shaders/Common.h").replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "")
    let toon = try read("Shaders/Toon.metal").replacingOccurrences(of: "#include \"Common.h\"", with: "")
    return try device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + header + common + toon, options: nil)
}

/// Blits every level (and slice) of `texture` into one buffer, in the
/// converter's file order: slice by slice, each slice's levels in turn.
private func readBack(_ texture: any MTLTexture, format: SourceStudioBlockTexture.Format, slices: Int,
                      device: any MTLDevice, queue: any MTLCommandQueue) throws -> Data {
    let counts = SourceStudioBlockTexture.levelByteCounts(width: texture.width, height: texture.height,
                                                          mipCount: texture.mipmapLevelCount, format: format)
    let total = counts.reduce(0, +) * slices
    let buffer = try #require(device.makeBuffer(length: total, options: .storageModeShared))
    let command = try #require(queue.makeCommandBuffer())
    let blit = try #require(command.makeBlitCommandEncoder())
    var offset = 0
    for slice in 0..<slices {
        var (width, height) = (texture.width, texture.height)
        for level in 0..<texture.mipmapLevelCount {
            blit.copy(from: texture, sourceSlice: slice, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: offset,
                      destinationBytesPerRow: max(1, (width + 3) / 4) * format.blockBytes, destinationBytesPerImage: counts[level])
            offset += counts[level]
            (width, height) = (max(1, width / 2), max(1, height / 2))
        }
    }
    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
    try #require(command.status == .completed)
    return Data(bytes: buffer.contents(), count: total)
}

private func float16(_ bits: UInt16) -> Float { Float(Float16(bitPattern: bits)) }

// MARK: - Uniforms and kinds

@Test func theSkyKindKeepsTheUniformTailZeroAndTheNewBindPointsAreDistinct() {
    let tail = withUnsafeBytes(of: MaterialUniforms.make(kind: MaterialKindSky)) { Array($0[340..<352]) }
    #expect(tail == Array(repeating: 0, count: 12))
    #expect(MaterialKindSky.rawValue == 9 && TextureIndexSkyCube.rawValue == 19)
    #expect(MaterialFlagMapParticle.rawValue == 1 << 20 && MaterialFlagMapParticle.rawValue & MaterialFlagMapDirectionalLightmap.rawValue == 0)
}

// MARK: - Block upload: BC7 and cubes

@Test(.enabled(if: MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression == true))
func blockTexturesAndCubesUploadEveryFaceAndLevelByteForByte() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    var generator = SystemRandomNumberGenerator()
    func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
    // 2D BC1/BC3 (the converter's row-flipped images) and BC7, full chains.
    for (format, pixelFormat) in [(SourceStudioBlockTexture.Format.bc1, MTLPixelFormat.bc1_rgba_srgb),
                                  (.bc3, .bc3_rgba_srgb), (.bc7, .bc7_rgbaUnorm_srgb)] {
        let size = SourceStudioBlockTexture.levelByteCounts(width: 16, height: 8, mipCount: 5, format: format).reduce(0, +)
        let data = random(size)
        let texture = try SourceStudioBlockTexture.make(device: device, data: data, width: 16, height: 8, mipCount: 5,
                                                        format: format, srgb: true, label: "probe")
        #expect(texture.pixelFormat == pixelFormat && texture.textureType == .type2D && texture.mipmapLevelCount == 5)
        #expect(try readBack(texture, format: format, slices: 1, device: device, queue: queue) == data, "\(format)")
    }
    #expect(SourceStudioBlockTexture.Format.bc7.pixelFormat(srgb: false) == .bc7_rgbaUnorm)
    // Cubes: six faces, each with its own chain (BC1 with three levels, BC7 with one).
    for (format, mips) in [(SourceStudioBlockTexture.Format.bc1, 3), (.bc7, 1)] {
        let face = SourceStudioBlockTexture.levelByteCounts(width: 8, height: 8, mipCount: mips, format: format).reduce(0, +)
        let data = random(face * 6)
        let cube = try SourceStudioBlockTexture.make(device: device, data: data, width: 8, height: 8, mipCount: mips,
                                                     format: format, srgb: true, faces: 6, label: "cube")
        #expect(cube.textureType == .typeCube && cube.mipmapLevelCount == mips && cube.storageMode == .shared)
        #expect(try readBack(cube, format: format, slices: 6, device: device, queue: queue) == data, "cube \(format)")
        // One byte short, or a non-square cube, is refused.
        #expect(throws: RigError.self) {
            _ = try SourceStudioBlockTexture.make(device: device, data: data.dropLast(), width: 8, height: 8, mipCount: mips,
                                                  format: format, srgb: true, faces: 6, label: "cube")
        }
        #expect(throws: RigError.self) {
            _ = try SourceStudioBlockTexture.make(device: device, data: data, width: 16, height: 4, mipCount: 1,
                                                  format: format, srgb: true, faces: 6, label: "cube")
        }
    }
}

// MARK: - The sky formula

/// Skybox-Cubed.shader / UnityCG.cginc (v5.6.2f1), CPU mirror.
@Test func skyMathFollowsTheCitedFormula() {
    // RotateAroundYInDegrees: x' = cos a x - sin a z, z' = sin a x + cos a z.
    let rotated = SourceStudioSkyMath.rotateAroundY(SIMD3(1, 2, 0), degrees: 90)
    #expect(simd_length(rotated - SIMD3(0, 2, 1)) < 1e-6)
    // DecodeHDR, Linear: (x * pow(w * (a - 1) + 1, y)) * rgb.
    let texel = SIMD4<Float>(0.5, 0.25, 1, 0.5)
    #expect(SourceStudioSkyMath.decodeHDR(texel, SIMD4(1, 1, 0, 0)) == SIMD3(0.5, 0.25, 1))
    let rgbm = SourceStudioSkyMath.decodeHDR(texel, SIMD4(34.4932442, 2.2, 0, 1))
    #expect(simd_length(rgbm - SIMD3(0.5, 0.25, 1) * 34.4932442 * powf(0.5, 2.2)) < 1e-4)
    let sky = SourceStudioSkyInputs(cube: 0, tint: SIMD3(repeating: 0.4052621771), exposure: 1, rotationDegrees: 0,
                                    colorSpaceDouble: SourceStudioSkyMath.colorSpaceDoubleLinear, decodeInstructions: SIMD4(1, 1, 0, 0))
    // _Tint 0.6691 (hiru00) linearized, times 4.5947938: the sky is brighter than its texture.
    #expect(abs(sky.scale.x - 0.4052621771 * 4.59479380) < 1e-6)
    #expect(simd_length(SourceStudioSkyMath.radiance(SIMD4(0.5, 0.5, 0.5, 1), sky: sky) - SIMD3(repeating: 0.5 * sky.scale.x)) < 1e-6)
}

/// sky_vertex + sky_fragment from the shipped sources against the formula: a
/// triangle whose pixel lands at a chosen object-space point samples the cube
/// at that unrotated Unity direction (engine z negated), times the scale.
@Test(.enabled(if: MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression == true))
func skyShadersSampleTheUnrotatedUnityDirectionTimesTintColorSpaceDoubleAndExposure() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let resources = ResourceStore(device: device)
    let library = try shaderLibrary(device)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "sky_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "sky_fragment")
    descriptor.colorAttachments[0].pixelFormat = .rgba32Float
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    let queue = try #require(device.makeCommandQueue())
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
    targetDescriptor.usage = [.renderTarget, .shaderRead]; targetDescriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: targetDescriptor))
    let cube = try SourceStudioBlockTexture.make(device: device, data: solidCube(), width: 4, height: 4, mipCount: 1,
                                                 format: .bc1, srgb: true, faces: 6, label: "sky")
    var draw = DrawUniforms(); draw.model = matrix_identity_float4x4; draw.normalMatrix = matrix_identity_float4x4

    /// Draws one triangle in the plane `axis` = `depth` (engine object space)
    /// and returns the pixel at the clip-space origin. `point` is where on the
    /// plane, after the vertex rotation, the pixel lands.
    func render(_ sky: SourceStudioSkyInputs, positions: [Float3], at clip: Float2,
                variant: SourceStudioSkyMaterial.Variant = .decoded, texture: (any MTLTexture)? = nil) throws -> SIMD3<Float> {
        let data = MeshData(name: "sky", positions: positions, normals: Array(repeating: Float3(0, 0, 1), count: 3), indices: [0, 1, 2])
        let handle = try resources.register(mesh: data)
        defer { resources.unregister(mesh: handle) }
        let mesh = try #require(resources.mesh(handle))
        let made = SourceStudioSkyMaterial.make(sky, cube: TextureHandle(id: 1))
        var material = try #require(SourceStudioSkyMaterial.variant(made, variant)).uniforms
        // Clip = (x - clip.x, y - clip.y, 0.5 z + 0.5): the chosen point lands on the pixel.
        var frame = FrameUniforms()
        frame.viewProjection = float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0.5, 0),
                                                  SIMD4(-clip.x, -clip.y, 0.5, 1)))
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(mesh.baseVertices, offset: 0, index: Int(BufferIndexVertices.rawValue))
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
        encoder.setVertexBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        encoder.setFragmentBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        encoder.setFragmentTexture(texture ?? cube, index: Int(TextureIndexSkyCube.rawValue))
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed, "sky draw failed: \(String(describing: command.error))")
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
        #expect(pixel[3] == 1)
        return SIMD3(pixel[0], pixel[1], pixel[2])
    }
    func plane(z: Float) -> [Float3] { [Float3(-4, -4, z), Float3(8, -4, z), Float3(-4, 8, z)] }
    let sky = SourceStudioSkyInputs(cube: 0, tint: SIMD3(0.4, 0.3, 0.2), exposure: 1.5, rotationDegrees: 0,
                                    colorSpaceDouble: SourceStudioSkyMath.colorSpaceDoubleLinear, decodeInstructions: SIMD4(1, 1, 0, 0))
    func check(_ result: SIMD3<Float>, face: Int, _ sky: SourceStudioSkyInputs, _ label: String) {
        let want = faceLinear[face] * sky.scale
        #expect(simd_length(result - want) <= 1e-4 * max(1, simd_length(want)), "\(label): \(result) != face \(face) \(want)")
    }
    // Engine z 0.9 is Unity z -0.9: the -Z face (index 5). A missing reflection reads +Z (index 4).
    check(try render(sky, positions: plane(z: 0.9), at: Float2(0, 0)), face: 5, sky, "engine +z")
    check(try render(sky, positions: plane(z: -0.9), at: Float2(0, 0)), face: 4, sky, "engine -z")
    check(try render(sky, positions: plane(z: 0.1), at: Float2(0.9, 0)), face: 0, sky, "+x")
    check(try render(sky, positions: plane(z: 0.1), at: Float2(-0.9, 0)), face: 1, sky, "-x")
    check(try render(sky, positions: plane(z: 0.1), at: Float2(0, 0.9)), face: 2, sky, "+y")
    check(try render(sky, positions: plane(z: 0.1), at: Float2(0, -0.9)), face: 3, sky, "-y")
    // _Rotation 90: Unity (x, y, z) is drawn at (-z, y, x). A triangle in the engine
    // plane x = -0.9 (Unity x -0.9) lands at clip x = engine z; at engine z 0.1
    // (Unity z -0.1) the cube is sampled at Unity (-0.9, 0, -0.1), the -X face,
    // although the drawn position is near the +/-z axis.
    let turned = SourceStudioSkyInputs(cube: 0, tint: sky.tint, exposure: sky.exposure, rotationDegrees: 90,
                                       colorSpaceDouble: sky.colorSpaceDouble, decodeInstructions: sky.decodeInstructions)
    let side = [Float3(-0.9, -4, -4), Float3(-0.9, -4, 8), Float3(-0.9, 8, -4)]
    check(try render(turned, positions: side, at: Float2(0.1, 0)), face: 1, turned, "rotated")
    // DecodeHDR's multiplier (an opaque BC1 texel has alpha 1, so the exponent is moot).
    let doubled = SourceStudioSkyInputs(cube: 0, tint: sky.tint, exposure: sky.exposure, rotationDegrees: 0,
                                        colorSpaceDouble: sky.colorSpaceDouble, decodeInstructions: SIMD4(2, 2.2, 0, 1))
    let twice = try render(doubled, positions: plane(z: 0.9), at: Float2(0, 0))
    #expect(simd_length(twice - 2 * faceLinear[5] * sky.scale) < 1e-4)
    // The rows-flipped control: each face read upside down. Unity (0, 0.45, -0.9) is the -Z
    // face's upper half (tc = -y / |z|, v 0.25); flipped, its lower half.
    let toned = try SourceStudioBlockTexture.make(device: device, data: twoToneCube(), width: 8, height: 8, mipCount: 1,
                                                  format: .bc1, srgb: true, faces: 6, label: "two-tone")
    check(try render(sky, positions: plane(z: 0.9), at: Float2(0, 0.45), texture: toned), face: 5, sky, "-Z upper half")
    check(try render(sky, positions: plane(z: 0.9), at: Float2(0, 0.45), variant: .rowsFlipped, texture: toned), face: 0, sky, "-Z flipped")
    // +Y: a model that swaps y and z draws the object plane y = 0.9 facing the camera; the
    // pixel at clip (0, -0.45) samples Unity (0, 0.9, 0.45): tc = z / |y|, v 0.75, the lower
    // half (face 3's colour); flipped, z is negated and the upper half (face 2's) is read.
    draw.model = float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)))
    let top = [Float3(-4, 0.9, -4), Float3(8, 0.9, -4), Float3(-4, 0.9, 8)]
    check(try render(sky, positions: top, at: Float2(0, -0.45), texture: toned), face: 3, sky, "+Y lower half")
    check(try render(sky, positions: top, at: Float2(0, -0.45), variant: .rowsFlipped, texture: toned), face: 2, sky, "+Y flipped")
}

/// The probe's sky variants change only their own term.
@Test func skyProbeVariantsChangeOnlyTheirTerm() throws {
    let sky = SourceStudioSkyInputs(cube: 0, tint: SIMD3(0.4, 0.3, 0.2), exposure: 1.5, rotationDegrees: 291,
                                    colorSpaceDouble: SourceStudioSkyMath.colorSpaceDoubleLinear, decodeInstructions: SIMD4(1, 1, 0, 0))
    let base = SourceStudioSkyMaterial.make(sky, cube: TextureHandle(id: 3))
    func made(_ v: SourceStudioSkyMaterial.Variant) throws -> MaterialState { try #require(SourceStudioSkyMaterial.variant(base, v)) }
    #expect(try made(.decoded) == base)
    let flipped = try made(.rowsFlipped)
    #expect(flipped.uniforms.flags == base.uniforms.flags | MaterialFlagSkyRowsFlipped.rawValue && flipped.cubemap == base.cubemap)
    let unturned = try made(.rotationIgnored)
    #expect(unturned.uniforms.params == Float4(0, 1, 1, 0) && base.uniforms.params.x == 291)
    let gamma = try made(.gammaConstants)
    let expected = sky.tint * 2 * sky.exposure
    #expect(simd_length(SIMD3(gamma.uniforms.baseColor.x, gamma.uniforms.baseColor.y, gamma.uniforms.baseColor.z) - expected) < 1e-5)
    #expect(gamma.uniforms.baseColor.w == 1 && gamma.uniforms.params == base.uniforms.params)
    // Not a sky material: no variant.
    #expect(SourceStudioSkyMaterial.variant(MaterialState(uniforms: .make(kind: MaterialKindMap)), .rowsFlipped) == nil)
    #expect(MaterialFlagSkyRowsFlipped.rawValue == 1 << 21 && MaterialFlagSkyRowsFlipped.rawValue & MaterialFlagMapParticle.rawValue == 0)
}

// MARK: - Particles

/// map_fragment's particle branch: 2 * vertex colour * tint * texture, alpha
/// included, nothing from the lightmap.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func particleBranchDrawsTwiceVertexColorTimesTintTimesTexture() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let resources = ResourceStore(device: device)
    let library = try shaderLibrary(device)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "toon_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "map_fragment")
    descriptor.colorAttachments[0].pixelFormat = .rgba32Float
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    let queue = try #require(device.makeCommandQueue())
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
    targetDescriptor.usage = [.renderTarget, .shaderRead]; targetDescriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: targetDescriptor))
    var frame = FrameUniforms(); frame.viewProjection = matrix_identity_float4x4; frame.shadowViewProjection = matrix_identity_float4x4
    var draw = DrawUniforms(); draw.model = matrix_identity_float4x4; draw.normalMatrix = matrix_identity_float4x4
    let tint = SourceStudioParticleInputs(tint: Float4(0.684, 0.6395, 0.6395, 0.534))

    func render(colors: [Float4]) throws -> (pixel: Float4, vertex: Float4) {
        let data = MeshData(name: "leaf", positions: [Float3(-1, -1, 0.25), Float3(3, -1, 0.25), Float3(-1, 3, 0.25)],
                            normals: Array(repeating: Float3(0, 0, 1), count: 3), uvs: Array(repeating: Float2(0.5, 0.5), count: 3),
                            colors: colors, indices: [0, 1, 2])
        let handle = try resources.register(mesh: data)
        defer { resources.unregister(mesh: handle) }
        let mesh = try #require(resources.mesh(handle))
        var vertex = Float4(1, 1, 1, 1)
        if let buffer = mesh.colors {
            let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
            vertex = Float4(Float(bytes[0]), Float(bytes[1]), Float(bytes[2]), Float(bytes[3])) / 255
        }
        var material = tint.material(base: TextureHandle(id: 1)).uniforms
        if mesh.colors != nil { material.flags |= MaterialFlagHasVertexColor.rawValue }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        for (buffer, index) in [(mesh.baseVertices, BufferIndexVertices), (mesh.texcoords, BufferIndexTexcoords),
            (mesh.texcoords1, BufferIndexTexcoords1), (mesh.texcoords2, BufferIndexTexcoords2),
            (mesh.colors ?? resources.dummyBuffer, BufferIndexVertexColors), (resources.dummyBuffer, BufferIndexVertexHidden)] {
            encoder.setVertexBuffer(buffer, offset: 0, index: Int(index.rawValue))
        }
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
        encoder.setVertexBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        encoder.setFragmentBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        // White texture; a bright lightmap that must not be read.
        encoder.setFragmentTexture(resources.whiteTexture, index: Int(TextureIndexBase.rawValue))
        encoder.setFragmentTexture(resources.whiteTexture, index: Int(TextureIndexLightmap.rawValue))
        encoder.setFragmentTexture(resources.whiteTexture, index: Int(TextureIndexLightmapDirection.rawValue))
        encoder.setFragmentTexture(resources.whiteTexture, index: Int(TextureIndexEmission.rawValue))
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed)
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
        return (Float4(pixel[0], pixel[1], pixel[2], pixel[3]), vertex)
    }
    for colors in [Array(repeating: Float4(0.5, 1, 0.25, 0.8), count: 3), []] {
        let (pixel, vertex) = try render(colors: colors)
        let want = 2 * vertex * tint.tint
        #expect(simd_length(pixel - want) < 1e-5, "\(colors.isEmpty ? "white" : "coloured") vertices: \(pixel) != \(want)")
    }
    let material = tint.material(base: nil)
    #expect(material.transparent && material.kind == MaterialKindMap && SourceStudioMapAsset.Draw(material) == .particle)
    #expect(material.uniforms.flags & MaterialFlagHasBaseTexture.rawValue == 0 && material.uniforms.flags & MaterialFlagDoubleSided.rawValue != 0)
    #expect(SourceStudioMapMaterial.irradiance(material) == nil)
}

// MARK: - Pass routing

/// The sky group exists in both main-pass variants (frames with live source
/// draws use the stencil set): every field matches by label.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func depthOnlyAndStencilMainPassesCarryTheSameGroups() throws {
    let renderer = try makeSourceShaderRenderer()
    let depthOnly = renderer.pipelines.depthOnlyMainPass.labels
    let stencil = try renderer.pipelines.stencilMainPass().labels
    #expect(depthOnly.contains("Sky") && depthOnly.count == 11)
    #expect(stencil == depthOnly.map { $0 + "Stencil" })
}

/// A sky item draws its cube times its scale behind everything, writes no
/// depth, and is dropped when its cube does not resolve.
@Test(.enabled(if: MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression == true))
func theSkyGroupDrawsItsCubeBehindTheSceneAndNeedsTheCube() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    let device = resources.device
    // Every face the same colour, so every view direction reads it.
    let gray = Data((0..<6).flatMap { _ in bc1Block(red: 16, green: 32, blue: 16) })
    let cube = resources.register(texture: try SourceStudioBlockTexture.make(device: device, data: gray, width: 4, height: 4, mipCount: 1,
                                                                             format: .bc1, srgb: false, faces: 6, label: "sky"))
    defer { resources.unregister(texture: cube) }
    // An octahedron of radius 1 around the camera target, scaled by 500.
    let corners: [Float3] = [Float3(1, 0, 0), Float3(-1, 0, 0), Float3(0, 1, 0), Float3(0, -1, 0), Float3(0, 0, 1), Float3(0, 0, -1)]
    let faces: [UInt32] = [0, 2, 4, 2, 1, 4, 1, 3, 4, 3, 0, 4, 2, 0, 5, 1, 2, 5, 3, 1, 5, 0, 3, 5]
    let mesh = try resources.register(mesh: MeshData(name: "sky", positions: corners, normals: corners, indices: faces))
    defer { resources.unregister(mesh: mesh) }
    let sky = SourceStudioSkyInputs(cube: 0, tint: SIMD3(0.25, 0.25, 0.25), exposure: 1, rotationDegrees: 30,
                                    colorSpaceDouble: SourceStudioSkyMath.colorSpaceDoubleLinear, decodeInstructions: SIMD4(1, 1, 0, 0))
    var camera = OrbitCamera(); camera.target = Float3(0, 0, 0)
    var item = RenderItem(mesh: mesh, material: SourceStudioSkyMaterial.make(sky, cube: cube),
                          model: Transform.trs(.zero, simd_quatf(angle: 0, axis: Float3(0, 1, 0)), Float3(repeating: 500)), objectID: 0)
    item.castsShadow = false; item.outline = false
    var effects = SceneEffects(); effects.transparentBackground = true; effects.showGrid = false
    func center(_ items: [RenderItem]) throws -> Float4 {
        let frame = RenderFrame(camera: camera, items: items, effects: effects)
        let bits = try #require(renderer.captureSceneHDR(frame: frame, width: 8, height: 8))
        let i = (4 * 8 + 4) * 4
        return Float4(float16(bits[i]), float16(bits[i + 1]), float16(bits[i + 2]), float16(bits[i + 3]))
    }
    let texel = Float(16) / 31  // RGB565 red 16 of 31 (linear texture)
    let drawn = try center([item])
    #expect(abs(drawn.x - texel * sky.scale.x) < 2e-3 && drawn.w == 1, "\(drawn)")
    // An unresolved cube drops the draw: transparent black stays.
    var orphan = item; orphan.material.cubemap = TextureHandle(id: 999_999)
    #expect(try center([orphan]) == .zero)
}

// MARK: - Records

private func blockImagesExtras(rows: String = "topDown", images: [[String: Any]] = [], cubes: [[String: Any]] = []) -> [String: Any] {
    ["ikkokuBlockImages": ["kind": "ikkoku.unityBlockImages", "version": 1, "rows": rows, "images": images, "cubes": cubes]]
}

private func blockFile(_ name: String, _ file: String, _ data: Data, format: String, size: Int, srgb: Bool = true) -> [String: Any] {
    ["name": name, "file": file, "format": format, "width": size, "height": size, "mipCount": 1, "srgb": srgb,
     "bytes": data.count, "sha256": sha256(data)]
}

private func cubeEntry(_ data: Data, faceOrder: [String] = SourceStudioBlockImages.faceOrder, faces: Int = 6) -> [String: Any] {
    blockFile("sky", "cube-0-sky.bc1", data, format: "BC1", size: 4).merging(
        ["cube": 0, "faces": faces, "faceOrder": faceOrder, "rows": "topDown"]) { $1 }
}

@Test func blockImageSkyAndParticleRecordsParseAndRefuseWhatTheyDoNotReproduce() throws {
    let image = Data(bc1Block(red: 31, green: 0, blue: 0))
    let images = [blockFile("tex", "0_tex.bc1", image, format: "BC1", size: 4).merging(["image": 0]) { $1 }]
    let parsed = try #require(try SourceStudioBlockImages.parse(try json(blockImagesExtras(images: images, cubes: [cubeEntry(solidCube())])), label: "m"))
    #expect(parsed.images[0]?.format == .bc1 && parsed.images[0]?.bytes == 8 && parsed.cubes[0]?.bytes == 48)
    #expect(try SourceStudioBlockImages.parse(try json(["other": 1]), label: "m") == nil)
    let refused: [(String, [String: Any])] = [
        ("are not top-down", blockImagesExtras(rows: "bottomUp", images: images)),
        ("image 0 is BC7", blockImagesExtras(images: [blockFile("t", "0_t.bc7", image, format: "BC7", size: 4).merging(["image": 0]) { $1 }])),
        ("image 0 is listed twice", blockImagesExtras(images: images + images)),
        ("leaves the map's directory", blockImagesExtras(images: [blockFile("t", "../t.bc1", image, format: "BC1", size: 4).merging(["image": 0]) { $1 }])),
        ("an entry has no image index", blockImagesExtras(images: [blockFile("t", "t.bc1", image, format: "BC1", size: 4)])),
        ("not six square faces", blockImagesExtras(cubes: [cubeEntry(solidCube(), faces: 1)])),
        ("not six square faces", blockImagesExtras(cubes: [cubeEntry(solidCube(), faceOrder: ["+X", "-X", "+Y", "-Y", "-Z", "+Z"])])),
    ]
    for (reason, extras) in refused {
        do {
            _ = try SourceStudioBlockImages.parse(try json(extras), label: "m")
            Issue.record("accepted: \(reason)")
        } catch {
            #expect("\(error)".contains(reason), "\(error) lacks \(reason)")
        }
    }
    let sky = try #require(try SourceStudioSkyInputs.parse(try json(["ikkokuSkybox": [
        "kind": "ikkoku.unitySkyboxCubemap", "version": 1, "cube": 2, "tintLinear": [0.25, 0.5, 1], "exposure": 1.5,
        "rotationDegrees": 291, "colorSpaceDouble": 4.5947938, "decodeInstructions": [1, 1, 0, 0]]])))
    #expect(sky.cube == 2 && sky.rotationDegrees == 291 && sky.scale == SIMD3<Float>(0.25, 0.5, 1) * Float(4.5947938) * 1.5)
    let material = SourceStudioSkyMaterial.make(sky, cube: TextureHandle(id: 7))
    #expect(material.kind == MaterialKindSky && material.cubemap == TextureHandle(id: 7) && material.textureHandles == [TextureHandle(id: 7)])
    #expect(material.uniforms.params == Float4(291, 1, 1, 0) && !material.transparent && SourceStudioMapAsset.Draw(material) == .sky)
    #expect(throws: RigError.self) { _ = try SourceStudioSkyInputs.parse(try json(["ikkokuSkybox": ["kind": "ikkoku.unitySkyboxCubemap", "version": 1]])) }
    #expect(try SourceStudioSkyInputs.parse(nil) == nil)
    #expect(try SourceStudioParticleInputs.parse(try json(["ikkokuParticle": ["tintLinear": [0.5, 0.25, 1, 0.5]]]))?.tint == Float4(0.5, 0.25, 1, 0.5))
    #expect(throws: RigError.self) { _ = try SourceStudioParticleInputs.parse(try json(["ikkokuParticle": ["tintLinear": [1, 1, 1]]])) }
}

// MARK: - A converted map with block images, a sky and particles

/// The converter's slice-3 layout: "Map" over a lightmapped mesh, a particle
/// mesh and a sky mesh (`ikkokuMap.sky`), one BC1 image (its PNG and its row-
/// flipped blocks), one BC1 cube, one lightmap.
private struct SkyMapFixture {
    let root: URL
    var url: URL { root.appendingPathComponent("map.gltf") }
    static let image = Data(bc1Block(red: 31, green: 0, blue: 0))
    static let light = Data([51, 0, 0, 0, 0, 0, 0, 0] + bc1Block(red: 31, green: 63, blue: 31))

    init(corruptCube: Bool = false, skyWithoutCube: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-skymap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var buffer = Data()
        for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0.25, 0.25, 0.75, 0.25, 0.25, 0.75] {
            var bits = value.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { buffer.append(contentsOf: $0) }
        }
        try buffer.write(to: root.appendingPathComponent("map.bin"))
        try skyFixturePNG().write(to: root.appendingPathComponent("0_tex.png"))
        try Self.image.write(to: root.appendingPathComponent("0_tex.bc1"))
        let cube = solidCube()
        try (corruptCube ? Data(cube.reversed()) : cube).write(to: root.appendingPathComponent("cube-0-sky.bc1"))
        try Self.light.write(to: root.appendingPathComponent("lightmap-0-light.bc3"))
        try Self.light.write(to: root.appendingPathComponent("lightmap-0-dir.bc3"))
        func mesh(_ name: String, material: Int, lightmapIndex: Int, uv1: Bool, sky: Bool = false) -> [String: Any] {
            var attributes: [String: Int] = ["POSITION": 0, "TEXCOORD_0": 1]
            if uv1 { attributes["TEXCOORD_1"] = 2 }
            var info: [String: Any] = ["role": "mapRoot", "visibleFor": [-1, 0, 1, 2], "lightmapIndex": lightmapIndex, "renderers": 1]
            if sky { info["sky"] = true }
            return ["name": name, "primitives": [["attributes": attributes, "material": material]], "extras": ["ikkokuMap": info]]
        }
        let standard: [String: Any] = ["albedoLinear": [1, 1, 1, 1], "metallic": 0, "oneMinusReflectivity": 0.96,
                                       "metallicSource": "_Metallic", "emission": NSNull()]
        let skybox: [String: Any] = ["kind": "ikkoku.unitySkyboxCubemap", "version": 1, "cube": 0, "tintLinear": [0.4, 0.4, 0.4],
                                     "exposure": 1, "rotationDegrees": 291, "colorSpaceDouble": 4.5947938, "decodeInstructions": [1, 1, 0, 0]]
        func light(_ name: String, _ file: String, srgb: Bool) -> [String: Any] {
            ["name": name, "file": file, "format": "BC3", "width": 4, "height": 4, "mipCount": 1, "srgb": srgb,
             "bytes": Self.light.count, "sha256": sha256(Self.light)]
        }
        let gltf: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": buffer.count, "uri": "map.bin"]],
            "bufferViews": [["buffer": 0, "byteLength": 36], ["buffer": 0, "byteOffset": 36, "byteLength": 24],
                            ["buffer": 0, "byteOffset": 60, "byteLength": 24]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]],
                          ["bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC2"],
                          ["bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2"]],
            "images": [["uri": "0_tex.png"]], "textures": [["source": 0]],
            "materials": [["name": "lit", "pbrMetallicRoughness": ["baseColorTexture": ["index": 0], "baseColorFactor": [1, 1, 1, 1]],
                           "extras": ["ikkokuStandard": standard]],
                          ["name": "leaf", "alphaMode": "BLEND", "doubleSided": true,
                           "pbrMetallicRoughness": ["baseColorTexture": ["index": 0], "baseColorFactor": [1, 1, 1, 1]],
                           "extras": ["ikkokuParticle": ["tintLinear": [0.5, 0.5, 0.5, 0.5]]]],
                          ["name": "sky", "alphaMode": "BLEND", "doubleSided": true,
                           "pbrMetallicRoughness": ["baseColorFactor": [0, 0, 0, 0]],
                           "extras": ["ikkokuSkybox": skybox]]],
            "meshes": [mesh("lit", material: 0, lightmapIndex: 0, uv1: true), mesh("leaf", material: 1, lightmapIndex: -1, uv1: false),
                       mesh("sky", material: 2, lightmapIndex: -1, uv1: false, sky: true)],
            "nodes": [["name": "Map", "children": [2, 3, 4], "extras": ["ikkokuMapRole": "mapRoot"]],
                      ["name": "Scene", "children": [], "extras": ["ikkokuMapRole": "scene"]],
                      ["name": "a", "mesh": 0], ["name": "b", "mesh": 1],
                      ["name": "c", "mesh": 2, "matrix": [500, 0, 0, 0, 0, 500, 0, 0, 0, 0, 500, 0, -14.9, -1.5, 168.6, 1]]],
            "scenes": [["nodes": [0, 1]]], "scene": 0,
            "extras": [
                "ikkokuLightmaps": ["kind": "ikkoku.unityLightmaps", "version": 1, "mode": "CombinedDirectional", "encoding": "RGBM",
                                    "colorSpace": "Linear", "rows": "bottomUp",
                                    "maps": [["index": 0, "light": light("l", "lightmap-0-light.bc3", srgb: true),
                                              "direction": light("d", "lightmap-0-dir.bc3", srgb: false)]]],
                "ikkokuBlockImages": blockImagesExtras(
                    images: [blockFile("tex", "0_tex.bc1", Self.image, format: "BC1", size: 4).merging(["image": 0]) { $1 }],
                    cubes: skyWithoutCube ? [] : [cubeEntry(cube)])["ikkokuBlockImages"]!,
            ],
        ]
        try JSONSerialization.data(withJSONObject: gltf, options: [.sortedKeys]).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// A 4×4 red PNG (what the converter's PNG of the BC1 block holds).
private func skyFixturePNG() throws -> Data {
    let pixels = [UInt8](repeating: 0, count: 64).enumerated().map { $0.offset % 4 == 0 || $0.offset % 4 == 3 ? UInt8(255) : 0 }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression == true))
struct SourceStudioSkyMapTests {
    @Test func blockImagesTheSkyAndParticlesLoadAndTheSwitchDecodesThePNGs() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let fixture = try SkyMapFixture()
        defer { fixture.remove() }
        let (url, root) = (fixture.url, fixture.root)
        let before = resources.statistics()
        let asset = try await liveTickOffPool {
            try SourceStudioMapAsset.load(url: url, packageRoot: root, resources: resources, imageSource: .blocks)
        }
        #expect(asset.parts.map(\.draw) == [.lightmapped, .particle, .sky])
        #expect(asset.lightmappedParts == 1 && asset.particleParts == 1 && asset.skyParts == 1)
        #expect(asset.blockImages == 1 && asset.decodedImages == 0 && asset.cubeTextures == 1 && asset.imageSource == .blocks)
        // The image, two lightmaps and the cube; the cube is six 8-byte faces.
        #expect(asset.textures.count == 4 && asset.cubeBytes >= 48 && asset.textureBytes > asset.lightmapBytes + asset.cubeBytes)
        let items = try asset.items(transform: KoikatsuChangeAmount(position: .zero, rotationDegrees: .zero, scale: .one), sunLightType: 0)
        let sky = try #require(items.first { SourceStudioMapAsset.Draw($0.material) == .sky })
        let leaf = try #require(items.first { SourceStudioMapAsset.Draw($0.material) == .particle })
        let lit = try #require(items.first { SourceStudioMapAsset.Draw($0.material) == .lightmapped })
        #expect(!sky.pickOccluder && !sky.castsShadow && !sky.outline && sky.objectID == 0)
        #expect(leaf.pickOccluder && leaf.material.transparent && lit.pickOccluder)
        #expect(resources.texture(try #require(sky.material.cubemap))?.textureType == .typeCube)
        // The base image is the BC1 file, sampled sRGB like the PNG would be.
        let base = try #require(resources.texture(try #require(lit.material.base)))
        #expect(base.pixelFormat == .bc1_rgba_srgb && leaf.material.base == lit.material.base)
        #expect(sky.model.columns.3.x == -14.9 && sky.model.columns.0.x == 500)
        let entry = try JSONDecoder().decode(SourceStudioMapCatalog.Entry.self, from: JSONSerialization.data(withJSONObject: [
            "no": 34, "name": "空き教室", "bundlePath": "studio/map/akikyoushitu.unity3d", "scene": "akikyoushitu", "file": "map.gltf"]))
        #expect(SourceStudioMapStatus.loaded(entry, asset: asset) == "Map 34 空き教室 (akikyoushitu): baked lightmaps, cubemap sky, "
            + "particles (no soft-particle fade or per-renderer sorting); approximated: no realtime sun or its shadows, no specular or "
            + "reflections, no normal, metallic or detail maps, no fog, no camera effects · 3 triangles, 3 draws")
        asset.release()
        resources.completeRetirements(createdBefore: ResourceClock.tick())
        #expect(resources.statistics().meshes == before.meshes && resources.statistics().textures == before.textures)

        // The measurement switch: the PNG decoded with generated mips instead.
        let decoded = try await liveTickOffPool {
            try SourceStudioMapAsset.load(url: url, packageRoot: root, resources: resources, imageSource: .decoded)
        }
        #expect(decoded.blockImages == 0 && decoded.decodedImages == 1 && decoded.imageSource == .decoded && decoded.skyParts == 1)
        let png = try #require(resources.texture(try #require(decoded.parts[0].material.base)))
        #expect(png.pixelFormat != .bc1_rgba_srgb)
        decoded.release()
        #expect(SourceStudioMapAsset.ImageSource.fromEnvironment(["IKKOKU_SOURCE_MAP_DECODED_TEXTURES": "1"]) == .decoded)
        #expect(SourceStudioMapAsset.ImageSource.fromEnvironment(["IKKOKU_SOURCE_MAP_DECODED_TEXTURES": "0"]) == .blocks)
        #expect(SourceStudioMapAsset.ImageSource.fromEnvironment([:]) == .blocks)
    }

    @Test func aChangedCubeOrAMissingCubeFailsTheLoadAndRegistersNothing() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let before = resources.statistics()
        for (fixture, reason) in [(try SkyMapFixture(corruptCube: true), "does not match its recorded size and SHA-256"),
                                  (try SkyMapFixture(skyWithoutCube: true), "names cube 0, which the map does not carry")] {
            defer { fixture.remove() }
            let (url, root) = (fixture.url, fixture.root)
            let failure = try await liveTickOffPool { () -> String? in
                do { _ = try SourceStudioMapAsset.load(url: url, packageRoot: root, resources: resources, imageSource: .blocks); return nil }
                catch { return "\(error)" }
            }
            #expect(failure?.contains(reason) == true, "\(failure ?? "loaded")")
            let after = resources.statistics()
            #expect(after.meshes == before.meshes && after.textures == before.textures)
        }
    }
}

// MARK: - The converted maps (shared fixture)

/// Every converted map in `IKKOKU_STUDIO_MAP_CATALOG` loads both ways
/// (block images, and the measurement switch's decoded PNGs); each listed
/// block image and cube uploads to its file byte for byte (blitted back); a
/// map without a sky or particles keeps its slice-2 status line.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_MAP_CATALOG"]) && MTLCreateSystemDefaultDevice() != nil),
      .timeLimit(.minutes(5)))
func everyConvertedMapLoadsItsBlockImagesByteForByte() async throws {
    let catalogURL = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_STUDIO_MAP_CATALOG"))
    let catalog = try SourceStudioMapCatalog.load(url: catalogURL)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let resources = ResourceStore(device: device)
    var converted = 0
    for number in Int32(-1)...Int32(400) {
        guard case .converted(let entry, let file, let packageRoot) = catalog.resolve(number) else { continue }
        converted += 1
        let directory = file.deletingLastPathComponent()
        let gltf = try GLBLoader.load(url: file, packageRoot: packageRoot)
        let blocks = try SourceStudioBlockImages.parse(gltf.extras, label: file.lastPathComponent)
        for (listed, faces) in (blocks?.images.values.map { ($0, 1) } ?? []) + (blocks?.cubes.values.map { ($0, 6) } ?? []) {
            let texture = try SourceStudioBlockTexture.upload(listed, directory: directory, device: device, faces: faces, what: "Fixture")
            let data = try Data(contentsOf: directory.appendingPathComponent(listed.file))
            #expect(try readBack(texture, format: listed.format, slices: faces, device: device, queue: queue) == data,
                    "map \(number) \(listed.file)")
        }
        let asset = try await liveTickOffPool {
            try SourceStudioMapAsset.load(url: file, packageRoot: packageRoot, resources: resources, imageSource: .blocks)
        }
        #expect(blocks == nil ? asset.blockImages == 0 : asset.blockImages > 0, "map \(number)")
        #expect(asset.cubeTextures == (blocks?.cubes.count ?? 0) || asset.skyParts == 0, "map \(number)")
        if asset.skyParts == 0, asset.particleParts == 0, asset.lightmappedParts == asset.parts.count, asset.lightmappedParts > 0 {
            #expect(SourceStudioMapStatus.loaded(entry, asset: asset).contains(": baked lightmaps; approximated: "), "map \(number)")
        }
        asset.release()
        let decoded = try await liveTickOffPool {
            try SourceStudioMapAsset.load(url: file, packageRoot: packageRoot, resources: resources, imageSource: .decoded)
        }
        #expect(decoded.blockImages == 0 && decoded.decodedImages > 0 && decoded.parts.count == asset.parts.count, "map \(number)")
        decoded.release()
    }
    #expect(converted > 0)
}
