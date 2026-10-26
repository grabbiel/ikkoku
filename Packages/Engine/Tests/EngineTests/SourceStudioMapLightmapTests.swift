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

// ST-A11 maps, slice 2: the recovered Unity 5.6.2f1 lightmap decode, the BC
// upload, the MaterialKindMap shader path and the lightmapped map load.

// MARK: - The uniform layout

/// The three map floats fill MaterialUniforms' former tail padding: the stride
/// stays 352, and every other kind leaves them zero, so a non-map draw writes
/// the same 352 bytes as before (bytes 340..<352 zero).
@Test func materialUniformsKeepTheirStrideWithTheMapFloatsInTheTail() {
    #expect(MemoryLayout<MaterialUniforms>.stride == 352)
    #expect(MemoryLayout<MaterialUniforms>.size == 352)
    #expect(MemoryLayout<MaterialUniforms>.offset(of: \MaterialUniforms.irisRotation) == 336)
    #expect(MemoryLayout<MaterialUniforms>.offset(of: \MaterialUniforms.lightmapRange) == 340)
    #expect(MemoryLayout<MaterialUniforms>.offset(of: \MaterialUniforms.lightmapExponent) == 344)
    #expect(MemoryLayout<MaterialUniforms>.offset(of: \MaterialUniforms.oneMinusReflectivity) == 348)
    for raw in Int32(0)...Int32(8) {
        let kind = MaterialKind(rawValue: raw)
        let tail = withUnsafeBytes(of: MaterialUniforms.make(kind: kind)) { Array($0[340..<352]) }
        #expect(tail == Array(repeating: 0, count: 12), "kind \(kind.rawValue)")
    }
}

// MARK: - The decode against the cited formula

/// UnityCG.cginc (v5.6.2f1) L517-L529 and L570-L582, Linear: unity_Lightmap_HDR
/// is (GammaToLinearSpaceExact(5), 2.2); the original player reported
/// (34.4932442, 2.2) (`original_map_probe.py oracle`).
@Test func lightmapDecodeFollowsTheCitedFormula() {
    #expect(abs(SourceStudioLightmapMath.linearRGBMRange - 34.4932442) < 1e-4)
    #expect(SourceStudioLightmapMath.linearRGBMExponent == 2.2)
    #expect(abs(SourceStudioLightmapMath.gammaToLinearExact(0.5) - 0.21404114) < 1e-6)
    #expect(abs(SourceStudioLightmapMath.gammaToLinearExact(0.04) - 0.04 / 12.92) < 1e-9)
    let data = SIMD4<Float>(0.5, 0.25, 1.0, 0.2)
    let scale = 34.4932442 * powf(0.2, 2.2)
    let decoded = SourceStudioLightmapMath.decodeRGBM(data)
    #expect(simd_length(decoded - SIMD3<Float>(0.5, 0.25, 1.0) * scale) < 1e-4)
    // DecodeDirectionalLightmap: color * (dot(n, dir - 0.5) + 0.5) / max(1e-4, dir.w),
    // with Unity's left-handed world reflected in Z into the engine basis.
    let color = SIMD3<Float>(1, 2, 3)
    let up = SourceStudioLightmapMath.directional(color, direction: SIMD4(0.5, 1, 0.5, 0.5), engineNormal: SIMD3(0, 1, 0))
    #expect(simd_length(up - color * 2) < 1e-5)
    // Unity +z (dir.z 1) is engine -z: lit for the engine normal -z, dark for +z.
    let towards = SourceStudioLightmapMath.directional(color, direction: SIMD4(0.5, 0.5, 1, 1), engineNormal: SIMD3(0, 0, -1))
    let away = SourceStudioLightmapMath.directional(color, direction: SIMD4(0.5, 0.5, 1, 1), engineNormal: SIMD3(0, 0, 1))
    #expect(simd_length(towards - color) < 1e-5 && simd_length(away) < 1e-5)
    #expect(SourceStudioLightmapMath.oneMinusReflectivity(metallic: 0) == 0.96)
    #expect(abs(SourceStudioLightmapMath.oneMinusReflectivity(metallic: 0.25) - 0.72) < 1e-6)
}

// MARK: - Block-compressed upload

/// One BC3 block whose 16 texels all decode to the endpoints exactly: alpha0
/// with alpha index 0 and color0 (RGB565) with color index 0.
private func bc3Block(red: UInt16, green: UInt16, blue: UInt16, alpha: UInt8) -> [UInt8] {
    let color = (red << 11) | (green << 5) | blue
    return [alpha, 0, 0, 0, 0, 0, 0, 0, UInt8(color & 0xFF), UInt8(color >> 8), 0, 0, 0, 0, 0, 0]
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression == true))
func blockTextureUploadKeepsEveryMipLevelByteForByte() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    // 16x8 with its full chain: 16x8, 8x4, 4x2, 2x1, 1x1 (levels under 4x4 still take a block).
    let counts = SourceStudioBlockTexture.levelByteCounts(width: 16, height: 8, mipCount: 5, format: .bc3)
    #expect(counts == [128, 32, 16, 16, 16])
    #expect(SourceStudioBlockTexture.levelByteCounts(width: 1024, height: 1024, mipCount: 11, format: .bc3).reduce(0, +) == 1_398_128)
    #expect(SourceStudioBlockTexture.levelByteCounts(width: 8, height: 8, mipCount: 4, format: .bc1) == [32, 8, 8, 8])
    var generator = SystemRandomNumberGenerator()
    let data = Data((0..<counts.reduce(0, +)).map { _ in UInt8.random(in: 0...255, using: &generator) })
    for (format, srgb, pixelFormat) in [(SourceStudioBlockTexture.Format.bc3, true, MTLPixelFormat.bc3_rgba_srgb),
                                        (.bc3, false, .bc3_rgba)] {
        let texture = try SourceStudioBlockTexture.make(device: device, data: data, width: 16, height: 8, mipCount: 5,
                                                        format: format, srgb: srgb, label: "probe")
        #expect(texture.pixelFormat == pixelFormat && texture.mipmapLevelCount == 5 && texture.storageMode == .shared)
        // Blit every level back to a shared buffer: the uploaded chain is the file.
        let buffer = try #require(device.makeBuffer(length: data.count, options: .storageModeShared))
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        var (offset, width, height) = (0, 16, 8)
        for level in 0..<5 {
            let rowBytes = max(1, (width + 3) / 4) * 16
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: offset,
                      destinationBytesPerRow: rowBytes, destinationBytesPerImage: counts[level])
            offset += counts[level]
            (width, height) = (max(1, width / 2), max(1, height / 2))
        }
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        #expect(Data(bytes: buffer.contents(), count: data.count) == data)
    }
    #expect(SourceStudioBlockTexture.Format.bc1.pixelFormat(srgb: true) == .bc1_rgba_srgb)
    #expect(SourceStudioBlockTexture.Format.bc1.pixelFormat(srgb: false) == .bc1_rgba)
    // Sizes that do not add up, and more levels than the size allows, are refused.
    for (bytes, mips) in [(data.count - 1, 5), (data.count, 6)] {
        #expect(throws: RigError.self) {
            _ = try SourceStudioBlockTexture.make(device: device, data: data.prefix(bytes), width: 16, height: 8, mipCount: mips,
                                                  format: .bc3, srgb: true, label: "probe")
        }
    }
}

// MARK: - map_fragment through the real shaders

/// toon_vertex + map_fragment compiled from the shipped sources, one
/// full-target triangle with constant UV1 and normal, against
/// SourceStudioLightmapMath. The light map is 4x8 (two BC3 blocks, rows
/// bottom-up like Unity's memory): the first block (Unity's bottom, glTF
/// v 0.75) and the second (glTF v 0.25) hold different texels, so a missing V
/// flip reads the wrong one; the two engine normals tell a missing Z flip.
@Test(.enabled(if: MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression == true))
func mapFragmentDrawsTheDecodedDirectionalLightmapTimesDiffColorPlusEmission() throws {
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
    descriptor.fragmentFunction = library.makeFunction(name: "map_fragment")
    descriptor.colorAttachments[0].pixelFormat = .rgba32Float
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    let queue = try #require(device.makeCommandQueue())
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
    targetDescriptor.usage = [.renderTarget, .shaderRead]; targetDescriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: targetDescriptor))

    // Light map: bottom block (31, 63, 0) alpha 51 = (1, 1, 0, 0.2); top block (0, 0, 31) alpha 255.
    let light = try SourceStudioBlockTexture.make(device: device,
        data: Data(bc3Block(red: 31, green: 63, blue: 0, alpha: 51) + bc3Block(red: 0, green: 0, blue: 31, alpha: 255)),
        width: 4, height: 8, mipCount: 1, format: .bc3, srgb: true, label: "light")
    // Direction map (linear): (1, 1, 0) with w 128/255 in both blocks.
    let direction = try SourceStudioBlockTexture.make(device: device,
        data: Data(bc3Block(red: 31, green: 63, blue: 0, alpha: 128) + bc3Block(red: 31, green: 63, blue: 0, alpha: 128)),
        width: 4, height: 8, mipCount: 1, format: .bc3, srgb: false, label: "direction")
    let white = resources.whiteTexture, black = resources.blackTexture
    var frame = FrameUniforms(); frame.viewProjection = matrix_identity_float4x4
    frame.shadowViewProjection = matrix_identity_float4x4; frame.cameraPosition = Float4(0, 0, 1, 1)
    var draw = DrawUniforms(); draw.model = matrix_identity_float4x4; draw.normalMatrix = matrix_identity_float4x4

    func render(_ state: MaterialState, normal: Float3, v: Float) throws -> Float3 {
        let data = MeshData(name: "map-probe", positions: [Float3(-1, -1, 0.25), Float3(3, -1, 0.25), Float3(-1, 3, 0.25)],
                            normals: Array(repeating: normal, count: 3), uvs: Array(repeating: Float2(0.5, 0.5), count: 3),
                            uvs1: Array(repeating: Float2(0.5, v), count: 3), uvs2: [], indices: [0, 1, 2])
        let handle = try resources.register(mesh: data)
        defer { resources.unregister(mesh: handle) }
        let mesh = try #require(resources.mesh(handle))
        var material = state.uniforms
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
        encoder.setFragmentBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
        encoder.setFragmentTexture(white, index: Int(TextureIndexBase.rawValue))
        encoder.setFragmentTexture(light, index: Int(TextureIndexLightmap.rawValue))
        encoder.setFragmentTexture(direction, index: Int(TextureIndexLightmapDirection.rawValue))
        encoder.setFragmentTexture(state.emission == nil ? black : white, index: Int(TextureIndexEmission.rawValue))
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed, "map_fragment draw failed: \(String(describing: command.error))")
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
        return Float3(pixel[0], pixel[1], pixel[2])
    }

    let standard = SourceStudioStandardInputs(albedo: Float4(0.5, 0.25, 1, 1), oneMinusReflectivity: 0.8, emissionColor: nil,
                                              emissionImage: nil, emissionSRGB: true)
    var gltf = MaterialData(name: "map")
    gltf.alphaMode = "OPAQUE"
    let handle = TextureHandle(id: 1)
    let material = SourceStudioMapMaterial.make(gltf, standard: standard, base: nil, emission: nil, lightmap: handle,
                                                direction: handle, range: SourceStudioLightmapMath.linearRGBMRange,
                                                exponent: SourceStudioLightmapMath.linearRGBMExponent)
    #expect(material.kind == MaterialKindMap && material.uniforms.flags & MaterialFlagMapDirectionalLightmap.rawValue != 0)
    let bottom = SIMD4<Float>(1, 1, 0, 51.0 / 255), top = SIMD4<Float>(0, 0, 1, 1), dir = SIMD4<Float>(1, 1, 0, 128.0 / 255)
    func expected(_ texel: SIMD4<Float>, normal: Float3, directional: Bool = true, emission: Float3 = .zero) -> Float3 {
        var gi = SourceStudioLightmapMath.decodeRGBM(texel)
        if directional { gi = SourceStudioLightmapMath.directional(gi, direction: dir, engineNormal: normal) }
        return Float3(0.5, 0.25, 1) * 0.8 * gi + emission
    }
    func check(_ result: Float3, _ want: Float3, _ label: String) {
        #expect(simd_length(result - want) <= 1e-4 * max(1, simd_length(want)), "\(label): \(result) != \(want)")
    }
    // The direction texel (1, 1, 0) is Unity (0.5, 0.5, -0.5), engine (0.5, 0.5, 0.5) after the
    // flip: the engine normal +z (Unity -z) faces it, dot 0.5, half-Lambert 1.
    let lit = try render(material, normal: Float3(0, 0, 1), v: 0.75)
    check(lit, expected(bottom, normal: Float3(0, 0, 1)), "bottom block, lit normal")
    #expect(lit.x > 0.1 && abs(lit.x - 2 * lit.y) < 1e-4 && lit.z == 0)
    // The other block (glTF v 0.25 is Unity's top half).
    check(try render(material, normal: Float3(0, 0, 1), v: 0.25), expected(top, normal: Float3(0, 0, 1)), "top block")
    // Engine -z: dot -0.5, half-Lambert 0 (without the flip this side would be the lit one).
    check(try render(material, normal: Float3(0, 0, -1), v: 0.75), .zero, "averted normal")
    // Non-directional: the decoded color alone.
    var flat = material; flat.setFlag(MaterialFlagMapDirectionalLightmap, false)
    check(try render(flat, normal: Float3(0, 0, 1), v: 0.75), expected(bottom, normal: Float3(0, 0, 1), directional: false), "non-directional")
    // Emission: tex2D(_EmissionMap) (white here) * _EmissionColor, added.
    let emissive = SourceStudioStandardInputs(albedo: Float4(0.5, 0.25, 1, 1), oneMinusReflectivity: 0.8,
                                              emissionColor: Float3(0.25, 0.5, 2), emissionImage: 3, emissionSRGB: true)
    let glowing = SourceStudioMapMaterial.make(gltf, standard: emissive, base: nil, emission: handle, lightmap: handle, direction: handle,
                                               range: SourceStudioLightmapMath.linearRGBMRange, exponent: SourceStudioLightmapMath.linearRGBMExponent)
    check(try render(glowing, normal: Float3(0, 0, -1), v: 0.75), Float3(0.25, 0.5, 2), "emission over a dark side")
    check(try render(glowing, normal: Float3(0, 0, 1), v: 0.75), expected(bottom, normal: Float3(0, 0, 1), emission: Float3(0.25, 0.5, 2)),
          "emission over a lit side")
    // The probe's irradiance material writes gi alone; its controls differ.
    let irradiance = try #require(SourceStudioMapMaterial.irradiance(material))
    let gi = SourceStudioLightmapMath.directional(SourceStudioLightmapMath.decodeRGBM(bottom), direction: dir, engineNormal: Float3(0, 0, 1))
    check(try render(irradiance, normal: Float3(0, 0, 1), v: 0.75), gi, "irradiance")
    let gamma = try #require(SourceStudioMapMaterial.irradiance(material, variant: .gammaConstants))
    check(try render(gamma, normal: Float3(0, 0, 1), v: 0.75),
          SourceStudioLightmapMath.directional(SourceStudioLightmapMath.decodeRGBM(bottom, range: 5, exponent: 1), direction: dir,
                                               engineNormal: Float3(0, 0, 1)), "gamma-constant control")
    let undirected = try #require(SourceStudioMapMaterial.irradiance(material, variant: .nonDirectional))
    check(try render(undirected, normal: Float3(0, 0, -1), v: 0.75), SourceStudioLightmapMath.decodeRGBM(bottom), "non-directional control")
    #expect(SourceStudioMapMaterial.irradiance(MaterialState(uniforms: .make(kind: MaterialKindItem))) == nil)
}

// MARK: - The converted map's lightmap records

private func lightmapsExtras(mode: String = "CombinedDirectional", encoding: String = "RGBM", colorSpace: String = "Linear",
                             rows: String = "bottomUp", file: String = "lightmap-0-light.bc3", maps: [[String: Any]]? = nil,
                             light: Data, direction: Data) -> [String: Any] {
    func texture(_ name: String, _ file: String, _ data: Data, srgb: Bool) -> [String: Any] {
        ["name": name, "file": file, "format": "BC3", "width": 4, "height": 4, "mipCount": 1, "srgb": srgb, "bytes": data.count,
         "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }
    return ["ikkokuLightmaps": ["kind": "ikkoku.unityLightmaps", "version": 1, "mode": mode, "encoding": encoding,
                                "colorSpace": colorSpace, "rows": rows,
                                "maps": maps ?? [["index": 0, "light": texture("Lightmap-0_comp_light", file, light, srgb: true),
                                                  "direction": texture("Lightmap-0_comp_dir", "lightmap-0-dir.bc3", direction, srgb: false)]]]]
}

private func json(_ value: [String: Any]) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func lightmapRecordsParseAndRefuseWhatTheyDoNotReproduce() throws {
    let light = Data(bc3Block(red: 31, green: 63, blue: 31, alpha: 51)), direction = Data(bc3Block(red: 16, green: 32, blue: 16, alpha: 255))
    let set = try #require(try SourceStudioLightmapSet.parse(try json(lightmapsExtras(light: light, direction: direction)), label: "m"))
    #expect(set.directional && set.entries.count == 1 && set.range == SourceStudioLightmapMath.linearRGBMRange && set.exponent == 2.2)
    let entry = try #require(set.entries[0])
    #expect(entry.light.srgb && entry.direction?.srgb == false && entry.light.format == .bc3 && entry.light.bytes == 16)
    #expect(try SourceStudioLightmapSet.parse(try json(["other": 1]), label: "m") == nil)
    #expect(try SourceStudioLightmapSet.parse(nil, label: "m") == nil)
    let lightOnly = ((lightmapsExtras(light: light, direction: direction)["ikkokuLightmaps"] as! [String: Any])["maps"] as! [[String: Any]])[0]["light"]!
    let refused: [(String, [String: Any])] = [
        ("encoding dLDR is not RGBM", lightmapsExtras(encoding: "dLDR", light: light, direction: direction)),
        ("colour space Gamma is not Linear", lightmapsExtras(colorSpace: "Gamma", light: light, direction: direction)),
        ("rows topDown", lightmapsExtras(rows: "topDown", light: light, direction: direction)),
        ("mode SeparateDirectional is not drawn", lightmapsExtras(mode: "SeparateDirectional", light: light, direction: direction)),
        ("leaves the map's directory", lightmapsExtras(file: "../lightmap.bc3", light: light, direction: direction)),
        ("leaves the map's directory", lightmapsExtras(file: "/tmp/lightmap.bc3", light: light, direction: direction)),
        ("no maps", lightmapsExtras(maps: [], light: light, direction: direction)),
        ("the direction map is incomplete", lightmapsExtras(maps: [["index": 0, "light": lightOnly]], light: light, direction: direction)),
        ("index 0 is listed twice", lightmapsExtras(maps: [["index": 0, "light": lightOnly, "direction": lightOnly],
                                                           ["index": 0, "light": lightOnly, "direction": lightOnly]], light: light, direction: direction)),
    ]
    for (reason, extras) in refused {
        do {
            _ = try SourceStudioLightmapSet.parse(try json(extras), label: "m")
            Issue.record("accepted: \(reason)")
        } catch {
            #expect("\(error)".contains(reason), "\(error) lacks \(reason)")
        }
    }
    // The Standard inputs: emission without a texture samples white (image nil).
    let inputs = try #require(try SourceStudioStandardInputs.parse(try json(["ikkokuStandard": [
        "albedoLinear": [1, 0.5, 0.25, 1], "oneMinusReflectivity": 0.7, "emission": ["colorLinear": [2, 1, 0], "image": NSNull(), "srgb": true]]])))
    #expect(inputs.albedo == Float4(1, 0.5, 0.25, 1) && inputs.oneMinusReflectivity == 0.7)
    #expect(inputs.emissionColor == Float3(2, 1, 0) && inputs.emissionImage == nil)
    #expect(throws: RigError.self) { _ = try SourceStudioStandardInputs.parse(try json(["ikkokuStandard": ["albedoLinear": [1, 1, 1]]])) }
}

// MARK: - A lightmapped converted map

/// The converter's layout with lightmaps: "Map" over a lightmapped mesh (UV1,
/// `ikkokuStandard` material) and "Scene" over an unlightmapped one, two BC3
/// files and the top-level `ikkokuLightmaps` record.
private struct LightmappedMapFixture {
    let root: URL
    var url: URL { root.appendingPathComponent("map.gltf") }
    static let light = Data(bc3Block(red: 31, green: 63, blue: 31, alpha: 51))
    static let direction = Data(bc3Block(red: 16, green: 32, blue: 16, alpha: 255))

    init(uv1: Bool = true, corruptLight: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-lightmapped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var buffer = Data()
        for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0.25, 0.25, 0.75, 0.25, 0.25, 0.75] {
            var bits = value.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { buffer.append(contentsOf: $0) }
        }
        try buffer.write(to: root.appendingPathComponent("map.bin"))
        try MapFixtureImages.rgbaPNG().write(to: root.appendingPathComponent("0_tex.png"))
        try (corruptLight ? Data(Self.light.reversed()) : Self.light).write(to: root.appendingPathComponent("lightmap-0-light.bc3"))
        try Self.direction.write(to: root.appendingPathComponent("lightmap-0-dir.bc3"))
        func mesh(_ role: String, _ keys: [Int], lightmapIndex: Int, material: Int, uv1: Bool) -> [String: Any] {
            var attributes: [String: Int] = ["POSITION": 0, "TEXCOORD_0": 1]
            if uv1 { attributes["TEXCOORD_1"] = 2 }
            return ["name": role, "primitives": [["attributes": attributes, "material": material]],
                    "extras": ["ikkokuMap": ["role": role, "visibleFor": keys, "lightmapIndex": lightmapIndex, "renderers": 1]]]
        }
        let standard: [String: Any] = ["albedoLinear": [0.5, 0.25, 1, 1], "metallic": 0.25, "oneMinusReflectivity": 0.72,
                                       "metallicSource": "_Metallic", "emission": NSNull()]
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
                          ["name": "item", "pbrMetallicRoughness": ["baseColorTexture": ["index": 0], "baseColorFactor": [1, 1, 1, 1]]]],
            "meshes": [mesh("mapRoot", [-1, 0, 1, 2], lightmapIndex: 0, material: 0, uv1: uv1),
                       mesh("scene", [-1, 0, 1, 2], lightmapIndex: -1, material: 1, uv1: false)],
            "nodes": [["name": "Map", "children": [2], "extras": ["ikkokuMapRole": "mapRoot"]],
                      ["name": "Scene", "children": [3], "extras": ["ikkokuMapRole": "scene"]],
                      ["name": "a", "mesh": 0], ["name": "b", "mesh": 1, "translation": [0, 3, 0]]],
            "scenes": [["nodes": [0, 1]]], "scene": 0,
            "extras": lightmapsExtras(light: Self.light, direction: Self.direction),
        ]
        try JSONSerialization.data(withJSONObject: gltf, options: [.sortedKeys]).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// The 2×2 RGBA PNG the converter writes, shared with SourceStudioMapTests' fixture shape.
private enum MapFixtureImages {
    static func rgbaPNG() throws -> Data {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression == true))
struct SourceStudioLightmappedMapTests {
    @Test func aLightmappedPartDrawsTheMapMaterialAndTheRestStayItems() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let fixture = try LightmappedMapFixture()
        defer { fixture.remove() }
        let (url, root) = (fixture.url, fixture.root)
        let before = resources.statistics()
        let asset = try await liveTickOffPool { try SourceStudioMapAsset.load(url: url, packageRoot: root, resources: resources) }
        #expect(asset.parts.count == 2 && asset.lightmappedParts == 1 && asset.lightmapTextures == 2)
        #expect(asset.textures.count == 3 && asset.lightmapBytes > 0 && asset.textureBytes > asset.lightmapBytes)
        let items = try asset.items(transform: KoikatsuChangeAmount(position: .zero, rotationDegrees: .zero, scale: .one), sunLightType: 0)
        let map = try #require(items.first { $0.material.kind == MaterialKindMap })
        let item = try #require(items.first { $0.material.kind == MaterialKindItem })
        #expect(map.material.lightmap != nil && map.material.lightmapDirection != nil && map.material.base != nil && map.material.emission == nil)
        #expect(map.material.uniforms.flags & MaterialFlagMapDirectionalLightmap.rawValue != 0)
        #expect(map.material.uniforms.flags & MaterialFlagHasBaseTexture.rawValue != 0)
        #expect(map.material.uniforms.lightmapRange == SourceStudioLightmapMath.linearRGBMRange && map.material.uniforms.lightmapExponent == 2.2)
        #expect(map.material.uniforms.oneMinusReflectivity == 0.72 && map.material.uniforms.baseColor == Float4(0.5, 0.25, 1, 1))
        #expect(map.material.uniforms.emissive == .zero && !map.material.transparent)
        #expect(item.material.lightmap == nil && item.material.uniforms.lightmapRange == 0)
        #expect(map.pickOccluder && !map.castsShadow && !map.outline && map.objectID == 0)
        let uploaded = try #require(resources.texture(try #require(map.material.lightmap)))
        #expect(uploaded.pixelFormat == .bc3_rgba_srgb && uploaded.width == 4)
        #expect(resources.texture(try #require(map.material.lightmapDirection))?.pixelFormat == .bc3_rgba)

        let entry = try JSONDecoder().decode(SourceStudioMapCatalog.Entry.self, from: JSONSerialization.data(withJSONObject: [
            "no": 33, "name": "空き部室", "bundlePath": "studio/map/bushitu.unity3d", "scene": "bushitu", "file": "map.gltf"]))
        #expect(SourceStudioMapStatus.loaded(entry, asset: asset) == "Map 33 空き部室 (bushitu): baked lightmaps on 1 of 2 draws (the rest as items); "
            + "approximated: no realtime sun or its shadows, no specular or reflections, no normal, metallic or detail maps, no fog, no camera effects"
            + " · 2 triangles, 2 draws")

        // Release retires the two meshes and the three textures.
        asset.release()
        #expect(resources.statistics().retiring == 5)
        resources.completeRetirements(createdBefore: ResourceClock.tick())
        #expect(resources.statistics().meshes == before.meshes && resources.statistics().textures == before.textures)
    }

    @Test func aChangedLightmapOrAMissingUV1FailsTheLoadAndRegistersNothing() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let before = resources.statistics()
        for (fixture, reason) in [(try LightmappedMapFixture(corruptLight: true), "does not match its recorded size and SHA-256"),
                                  (try LightmappedMapFixture(uv1: false), "is lightmapped but has no TEXCOORD_1")] {
            defer { fixture.remove() }
            let (url, root) = (fixture.url, fixture.root)
            let failure = try await liveTickOffPool { () -> String? in
                do { _ = try SourceStudioMapAsset.load(url: url, packageRoot: root, resources: resources); return nil }
                catch { return "\(error)" }
            }
            #expect(failure?.contains(reason) == true, "\(failure ?? "loaded")")
            let after = resources.statistics()
            #expect(after.meshes == before.meshes && after.textures == before.textures)
        }
    }
}
