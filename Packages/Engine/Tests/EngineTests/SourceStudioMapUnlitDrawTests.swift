import Testing
import Foundation
import CryptoKit
import Metal
import simd
import Assets
import CoreMath
import Character
import Scene
import ShaderTypes
@testable import Studio
@testable import Renderer

// ST-A11 maps, slice 4: the Unlit/Transparent, Particles/Anim Alpha Blended and
// Custom/Silhouette branches of map_fragment against their formulas, the
// silhouette's two passes through the renderer, RGBA32 lightmaps, and a
// converted map with block-only images (no image decoder ever sees their
// bytes), an option root and the slice-4 status line.

// MARK: - Helpers

private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func json(_ value: [String: Any]) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
}

private func float16(_ bits: UInt16) -> Float { Float(Float16(bitPattern: bits)) }

/// One BC1 block whose 16 texels decode to color0 exactly.
private func bc1Block(red: UInt16, green: UInt16, blue: UInt16) -> [UInt8] {
    let color = (red << 11) | (green << 5) | blue
    return [UInt8(color & 0xFF), UInt8(color >> 8), 0, 0, 0, 0, 0, 0]
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

/// A 2×1 linear RGBA8 texture: the left texel `left`, the right one `right` (0...255).
private func twoTexels(_ device: any MTLDevice, _ left: SIMD4<UInt8>, _ right: SIMD4<UInt8>) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 1, mipmapped: false)
    descriptor.usage = .shaderRead; descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    let bytes: [UInt8] = [left.x, left.y, left.z, left.w, right.x, right.y, right.z, right.w]
    texture.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 8)
    return texture
}

/// Draws one full-target triangle with `toon_vertex` + `map_fragment` and
/// returns the 1×1 rgba32Float pixel. Every vertex carries the same UV0, UV1
/// and UV2, so the sampled texels are exact.
private func renderMapFragment(material: MaterialUniforms, base: any MTLTexture, uv: Float2, uv1: Float2 = .zero, uv2: Float2 = .zero,
                               colors: [Float4] = []) throws -> Float4 {
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
    let data = MeshData(name: "quad", positions: [Float3(-1, -1, 0.25), Float3(3, -1, 0.25), Float3(-1, 3, 0.25)],
                        normals: Array(repeating: Float3(0, 0, 1), count: 3), uvs: Array(repeating: uv, count: 3),
                        uvs1: Array(repeating: uv1, count: 3), uvs2: Array(repeating: uv2, count: 3),
                        colors: colors, indices: [0, 1, 2])
    let handle = try resources.register(mesh: data)
    defer { resources.unregister(mesh: handle) }
    let mesh = try #require(resources.mesh(handle))
    var uniforms = material
    if mesh.colors != nil { uniforms.flags |= MaterialFlagHasVertexColor.rawValue }
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
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
    // A bright lightmap and emission that none of these branches may read.
    encoder.setFragmentTexture(base, index: Int(TextureIndexBase.rawValue))
    encoder.setFragmentTexture(resources.whiteTexture, index: Int(TextureIndexLightmap.rawValue))
    encoder.setFragmentTexture(resources.whiteTexture, index: Int(TextureIndexLightmapDirection.rawValue))
    encoder.setFragmentTexture(resources.whiteTexture, index: Int(TextureIndexEmission.rawValue))
    encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    try #require(command.status == .completed)
    var pixel = [Float](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
    return Float4(pixel[0], pixel[1], pixel[2], pixel[3])
}

private func silhouetteState() -> [String: Any] { [
    "kind": "ikkoku.unitySilhouette", "version": 1, "colorLinear": [0, 0, 1, 0.5],
    "colorSource": "AdditionalFunctionsSystem.mobColor default (0, 0, 1, 0.5); the user's config is not read",
    "passes": [["name": "", "lightMode": "", "cull": "Back", "zWrite": 1, "zTest": "LEqual", "blend": ["One", "Zero", "One", "Zero"], "colorMask": "0"],
               ["name": "", "lightMode": "", "cull": "Back", "zWrite": 0, "zTest": "LEqual",
                "blend": ["SrcAlpha", "OneMinusSrcAlpha", "SrcAlpha", "OneMinusSrcAlpha"], "colorMask": "RGBA"]],
    "queue": "Transparent", "fragment": "mov o0.xyzw, _Color ($Globals byte 32)"] }

// MARK: - The fragment branches

/// Unlit/Transparent: the texel times the (white) base colour, alpha included;
/// no lightmap, emission or vertex colour.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func unlitBranchDrawsTheTexelAlone() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try twoTexels(device, SIMD4(51, 102, 204, 128), SIMD4(255, 0, 0, 255))
    let gltf = MaterialData(name: "shadow", alphaMode: "BLEND")
    let material = SourceStudioUnlitInputs.material(gltf, base: TextureHandle(id: 1))
    #expect(SourceStudioMapAsset.Draw(material) == .unlit && material.transparent && material.uniforms.baseColor == Float4(1, 1, 1, 1))
    #expect(material.uniforms.flags & MaterialFlagDoubleSided.rawValue == 0 && SourceStudioMapMaterial.irradiance(material) == nil)
    let want = Float4(51, 102, 204, 128) / 255
    let pixel = try renderMapFragment(material: material.uniforms, base: texture, uv: Float2(0.25, 0.5),
                                      colors: Array(repeating: Float4(0.25, 0.25, 0.25, 0.25), count: 3))
    #expect(simd_length(pixel - want) < 1e-5, "\(pixel) != \(want)")
}

/// Particles/Anim Alpha Blended: 2 × colour × tint × lerp(tex(uv0), tex(uv2), uv1.x).
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func animatedParticleBranchBlendsToTheSecondUVByTheFirstUVsX() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try twoTexels(device, SIMD4(255, 0, 0, 255), SIMD4(0, 255, 0, 51))
    let inputs = SourceStudioParticleInputs(tint: Float4(0.5, 0.25, 0.5, 1), animBlend: true)
    let material = inputs.material(base: TextureHandle(id: 1))
    #expect(material.uniforms.flags & MaterialFlagMapParticleAnim.rawValue != 0 && SourceStudioMapAsset.Draw(material) == .particle)
    let (a, b) = (Float4(1, 0, 0, 1), Float4(0, 1, 0, 0.2))
    for blend: Float in [0, 0.25, 1] {
        let pixel = try renderMapFragment(material: material.uniforms, base: texture, uv: Float2(0.25, 0.5), uv1: Float2(blend, 0.75),
                                          uv2: Float2(0.75, 0.5))
        let want = 2 * inputs.tint * (a + (b - a) * blend)
        #expect(simd_length(pixel - want) < 1e-5, "blend \(blend): \(pixel) != \(want)")
    }
    // Without the flag the same mesh samples UV0 only (the slice-3 particle).
    let plain = SourceStudioParticleInputs(tint: inputs.tint).material(base: TextureHandle(id: 1))
    let pixel = try renderMapFragment(material: plain.uniforms, base: texture, uv: Float2(0.25, 0.5), uv1: Float2(1, 0), uv2: Float2(0.75, 0.5))
    #expect(simd_length(pixel - 2 * inputs.tint * a) < 1e-5)
    #expect(try SourceStudioParticleInputs.parse(try json(["ikkokuParticle": ["tintLinear": [1, 1, 1, 1], "animBlend": true]]))?.animBlend == true)
    #expect(try SourceStudioParticleInputs.parse(try json(["ikkokuParticle": ["tintLinear": [1, 1, 1, 1]]]))?.animBlend == false)
    #expect(throws: RigError.self) { _ = try SourceStudioParticleInputs.parse(try json(["ikkokuParticle": ["tintLinear": [1, 1, 1, 1], "animBlend": 1]])) }
}

/// Custom/Silhouette's colour pass: `mov o0, _Color`, whatever the texture,
/// vertex colour or lightmap.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func silhouetteBranchReturnsTheMobColour() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let inputs = try #require(try SourceStudioSilhouetteInputs.parse(try json(["ikkokuSilhouette": silhouetteState()])))
    #expect(inputs.color == Float4(0, 0, 1, 0.5))
    let material = inputs.material()
    #expect(SourceStudioMapAsset.Draw(material) == .silhouette && material.transparent && material.textureHandles.isEmpty)
    #expect(material.uniforms.flags & MaterialFlagDoubleSided.rawValue == 0 && SourceStudioMapMaterial.irradiance(material) == nil)
    let pixel = try renderMapFragment(material: material.uniforms, base: try twoTexels(device, SIMD4(9, 9, 9, 9), SIMD4(9, 9, 9, 9)),
                                      uv: Float2(0.25, 0.5), colors: Array(repeating: Float4(0.5, 0.5, 0.5, 0.5), count: 3))
    #expect(pixel == Float4(0, 0, 1, 0.5))
    // Any other state is refused: the renderer draws exactly these two passes.
    var oneSided = silhouetteState()
    var passes = silhouetteState()["passes"] as! [[String: Any]]
    passes[1]["zTest"] = "Always"
    oneSided["passes"] = passes
    var single = silhouetteState()
    single["passes"] = [passes[0]]
    for extras in [oneSided, single] {
        #expect(throws: RigError.self) { _ = try SourceStudioSilhouetteInputs.parse(try json(["ikkokuSilhouette": extras])) }
    }
    #expect(try SourceStudioSilhouetteInputs.parse(nil) == nil)
}

// MARK: - The silhouette's two passes in the renderer

/// Pass 1 writes depth only, pass 2 blends at ZTest LEqual: one renderer whose
/// faces overlap blends its colour once (no double blend), and covers every
/// pixel its depth pass wrote; two renderers blend twice, as Unity draws them.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func silhouettesBlendOncePerRendererAndCoverTheirDepthPass() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    var camera = OrbitCamera(); camera.pitch = 0; camera.yaw = 0
    // Two screen-filling quads around the target, 0.1 apart in depth, each in
    // both windings so Cull Back keeps exactly one face of each.
    func quads(_ depths: [Float]) -> MeshData {
        var positions: [Float3] = [], indices: [UInt32] = []
        for z in depths {
            let base = UInt32(positions.count)
            let t = camera.target
            positions += [Float3(t.x - 50, t.y - 50, t.z + z), Float3(t.x + 50, t.y - 50, t.z + z),
                          Float3(t.x + 50, t.y + 50, t.z + z), Float3(t.x - 50, t.y + 50, t.z + z)]
            indices += [0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2].map { base + $0 }
        }
        return MeshData(name: "mob", positions: positions, normals: Array(repeating: Float3(0, 0, 1), count: positions.count), indices: indices)
    }
    let material = try #require(try SourceStudioSilhouetteInputs.parse(try json(["ikkokuSilhouette": silhouetteState()]))).material()
    var effects = SceneEffects(); effects.transparentBackground = true; effects.showGrid = false
    func capture(_ meshes: [MeshData]) throws -> [Float4] {
        let handles = try meshes.map { try resources.register(mesh: $0) }
        defer { handles.forEach { resources.unregister(mesh: $0) } }
        let items = handles.map { handle -> RenderItem in
            var item = RenderItem(mesh: handle, material: material, model: matrix_identity_float4x4, objectID: 0)
            item.castsShadow = false; item.outline = false; item.order = 100
            return item
        }
        let bits = try #require(renderer.captureSceneHDR(frame: RenderFrame(camera: camera, items: items, effects: effects), width: 8, height: 8))
        return (0..<64).map { i in Float4(float16(bits[i * 4]), float16(bits[i * 4 + 1]), float16(bits[i * 4 + 2]), float16(bits[i * 4 + 3])) }
    }
    // One renderer, two overlapping faces: blended once over transparent black.
    let once = try capture([quads([-0.05, 0.05])])
    #expect(once.allSatisfy { abs($0.z - 0.5) < 2e-3 && abs($0.x) < 1e-6 }, "\(once.prefix(4))")
    // Two renderers: Unity draws each with both passes, so the nearer blends again.
    let twice = try capture([quads([-0.05]), quads([0.05])])
    #expect(twice.allSatisfy { abs($0.z - 0.75) < 2e-3 }, "\(twice.prefix(4))")
}

// MARK: - RGBA32 lightmaps

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func rgba32LightmapsUploadUncompressedAndParse() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    #expect(SourceStudioBlockTexture.levelByteCounts(width: 4, height: 2, mipCount: 3, format: .rgba8) == [32, 8, 4])
    #expect(SourceStudioBlockTexture.Format.rgba8.pixelFormat(srgb: true) == .rgba8Unorm_srgb && !SourceStudioBlockTexture.Format.rgba8.isBlock)
    let data = Data((0..<44).map { UInt8($0 * 5) })
    let texture = try SourceStudioBlockTexture.make(device: device, data: data, width: 4, height: 2, mipCount: 3, format: .rgba8,
                                                    srgb: false, label: "lightmap")
    #expect(texture.pixelFormat == .rgba8Unorm && texture.mipmapLevelCount == 3)
    var level0 = [UInt8](repeating: 0, count: 32), level2 = [UInt8](repeating: 0, count: 4)
    level0.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 2), mipmapLevel: 0) }
    level2.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 2) }
    #expect(level0 == Array(data.prefix(32)) && level2 == Array(data.suffix(4)))
    #expect(throws: RigError.self) {
        _ = try SourceStudioBlockTexture.make(device: device, data: data.dropLast(), width: 4, height: 2, mipCount: 3, format: .rgba8,
                                              srgb: false, label: "short")
    }
    let entry: [String: Any] = ["name": "l", "file": "lightmap-0-light.rgba8", "format": "RGBA8", "width": 4, "height": 2, "mipCount": 3,
                                "srgb": true, "bytes": data.count, "sha256": sha256(data)]
    let set = try #require(try SourceStudioLightmapSet.parse(try json(["ikkokuLightmaps": [
        "kind": "ikkoku.unityLightmaps", "version": 1, "mode": "NonDirectional", "encoding": "RGBM", "colorSpace": "Linear",
        "rows": "bottomUp", "maps": [["index": 0, "light": entry]]]]), label: "m"))
    #expect(set.entries[0]?.light.format == .rgba8 && !set.directional)
    // RGBA8 is a lightmap format only: never a block image or a cube.
    let image = entry.merging(["image": 0]) { $1 }
    do {
        _ = try SourceStudioBlockImages.parse(try json(["ikkokuBlockImages": ["kind": "ikkoku.unityBlockImages", "version": 1,
                                                                              "rows": "topDown", "images": [image]]]), label: "m")
        Issue.record("an RGBA8 block image was accepted")
    } catch {
        #expect("\(error)".contains("image 0 is RGBA8"))
    }
}

// MARK: - A converted map with block-only images, an option root and the new draws

/// The converter's slice-4 layout: "Map" over an Unlit/Transparent mesh, an
/// animated particle mesh (UV0-2), a Standard mesh drawn as an item, and a
/// silhouette mesh under an option root; one block-only BC1 image (no PNG:
/// the glTF image's uri is the .bc1 file, mimeType image/x-ikkoku-bc1).
private struct Slice4MapFixture {
    let root: URL
    var url: URL { root.appendingPathComponent("map.gltf") }
    static let image = Data(bc1Block(red: 31, green: 0, blue: 0))

    enum Variant { case normal, noBlockEntry, animWithoutUV2, silhouetteOutsideOption, garbageImage }

    init(_ variant: Variant = .normal) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-slice4map-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var buffer = Data()
        let floats: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0,   // POSITION
                               0, 0, 1, 0, 0, 1,            // TEXCOORD_0
                               0.25, 0, 0.25, 0, 0.25, 0,   // TEXCOORD_1
                               0.5, 0.5, 0.5, 0.5, 0.5, 0.5]  // TEXCOORD_2
        for value in floats {
            var bits = value.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { buffer.append(contentsOf: $0) }
        }
        try buffer.write(to: root.appendingPathComponent("map.bin"))
        try Self.image.write(to: root.appendingPathComponent("0_tex.bc1"))
        try Data("not an image".utf8).write(to: root.appendingPathComponent("1_garbage.dat"))
        func mesh(_ name: String, material: Int, uv1: Bool = false, uv2: Bool = false, option: Bool = false) -> [String: Any] {
            var attributes: [String: Int] = ["POSITION": 0, "TEXCOORD_0": 1]
            if uv1 { attributes["TEXCOORD_1"] = 2 }
            if uv2 { attributes["TEXCOORD_2"] = 3 }
            var info: [String: Any] = ["role": "mapRoot", "visibleFor": [-1, 0, 1, 2], "lightmapIndex": -1, "renderers": 1]
            if option { info["option"] = true }
            return ["name": name, "primitives": [["attributes": attributes, "material": material]], "extras": ["ikkokuMap": info]]
        }
        let standard: [String: Any] = ["albedoLinear": [1, 1, 1, 1], "metallic": 0, "oneMinusReflectivity": 0.96,
                                       "metallicSource": "_Metallic", "emission": NSNull()]
        var images: [[String: Any]] = [["uri": "0_tex.bc1", "mimeType": "image/x-ikkoku-bc1"]]
        if variant == .garbageImage { images.append(["uri": "1_garbage.dat"]) }
        let blockEntry: [String: Any] = ["image": 0, "name": "tex", "file": "0_tex.bc1", "format": "BC1", "width": 4, "height": 4,
                                         "mipCount": 1, "srgb": true, "bytes": Self.image.count, "sha256": sha256(Self.image)]
        let gltf: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": buffer.count, "uri": "map.bin"]],
            "bufferViews": [["buffer": 0, "byteLength": 36], ["buffer": 0, "byteOffset": 36, "byteLength": 24],
                            ["buffer": 0, "byteOffset": 60, "byteLength": 24], ["buffer": 0, "byteOffset": 84, "byteLength": 24]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]],
                          ["bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC2"],
                          ["bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2"],
                          ["bufferView": 3, "componentType": 5126, "count": 3, "type": "VEC2"]],
            "images": images, "textures": [["source": 0]] + (variant == .garbageImage ? [["source": 1]] : []),
            "materials": [["name": "shadow", "alphaMode": "BLEND", "doubleSided": false,
                           "pbrMetallicRoughness": ["baseColorTexture": ["index": 0], "baseColorFactor": [1, 1, 1, 1]],
                           "extras": ["ikkokuUnlit": ["kind": "ikkoku.unityUnlitTransparent", "version": 1]]],
                          ["name": "grass", "alphaMode": "BLEND", "doubleSided": true,
                           "pbrMetallicRoughness": ["baseColorTexture": ["index": 0], "baseColorFactor": [1, 1, 1, 1]],
                           "extras": ["ikkokuParticle": ["tintLinear": [0.5, 0.5, 0.5, 0.5], "animBlend": true]]],
                          ["name": "wall", "pbrMetallicRoughness": ["baseColorTexture": ["index": variant == .garbageImage ? 1 : 0],
                                                                    "baseColorFactor": [1, 1, 1, 1]],
                           "extras": ["ikkokuStandard": standard]],
                          ["name": "mob", "alphaMode": "BLEND", "doubleSided": false,
                           "pbrMetallicRoughness": ["baseColorFactor": [0, 0, 1, 0.5]],
                           "extras": ["ikkokuSilhouette": silhouetteState()]]],
            "meshes": [mesh("shadow", material: 0), mesh("grass", material: 1, uv1: true, uv2: variant != .animWithoutUV2),
                       mesh("wall", material: 2), mesh("mob", material: 3, option: variant != .silhouetteOutsideOption)],
            "nodes": [["name": "Map", "children": [2, 3, 4, 5], "extras": ["ikkokuMapRole": "mapRoot"]],
                      ["name": "Scene", "children": [], "extras": ["ikkokuMapRole": "scene"]],
                      ["name": "a", "mesh": 0], ["name": "b", "mesh": 1], ["name": "c", "mesh": 2], ["name": "d", "mesh": 3]],
            "scenes": [["nodes": [0, 1]]], "scene": 0,
            "extras": ["ikkokuBlockImages": ["kind": "ikkoku.unityBlockImages", "version": 1, "rows": "topDown",
                                             "images": variant == .noBlockEntry ? [] : [blockEntry], "cubes": []]],
        ]
        try JSONSerialization.data(withJSONObject: gltf, options: [.sortedKeys]).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Counts every decode the map loader asks for (the ImageIO / MetalKit path).
private final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var decoder: SourceStudioMapAsset.ImageDecoder {
        { [self] data, key, srgb, resources in
            lock.lock(); count += 1; lock.unlock()
            return try SourceStudioMapAsset.storeDecoder(data, key, srgb, resources)
        }
    }
}

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression == true))
struct SourceStudioSlice4MapTests {
    /// The guard on the PNG drop: a block-only map registers its BC blocks for
    /// every draw (the item draw included), the decoder is never called, and
    /// the store holds exactly the asset's textures.
    @Test func blockOnlyImagesNeverReachTheDecoderAndTheNewDrawsLoad() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let fixture = try Slice4MapFixture()
        defer { fixture.remove() }
        let (url, root) = (fixture.url, fixture.root)
        let counter = DecodeCounter()
        let decoder = counter.decoder
        let before = resources.statistics()
        let asset = try await liveTickOffPool {
            try SourceStudioMapAsset.load(url: url, packageRoot: root, resources: resources, imageSource: .blocks, decoder: decoder)
        }
        #expect(counter.calls == 0 && asset.decodedImages == 0 && asset.blockImages == 1)
        #expect(resources.statistics().textures - before.textures == asset.textures.count && asset.textures.count == 1)
        #expect(asset.parts.map(\.draw) == [.unlit, .particle, .item, .silhouette])
        #expect(asset.unlitParts == 1 && asset.silhouetteParts == 1 && asset.optionParts == 1 && asset.parts.map(\.option) == [false, false, false, true])
        let amount = KoikatsuChangeAmount(position: .zero, rotationDegrees: .zero, scale: .one)
        let shown = try asset.items(transform: amount, sunLightType: 0, mapOption: true)
        let hidden = try asset.items(transform: amount, sunLightType: 0, mapOption: false)
        #expect(shown.count == 4 && hidden.count == 3 && !hidden.contains { SourceStudioMapAsset.Draw($0.material) == .silhouette })
        #expect(asset.optionDraws(sunLightType: 0, mapOption: true) == 1 && asset.optionDraws(sunLightType: 0, mapOption: false) == 0)
        // Every textured draw samples the one BC1 upload, the item draw included.
        let bases = Set(shown.compactMap(\.material.base))
        #expect(bases.count == 1)
        #expect(resources.texture(try #require(bases.first))?.pixelFormat == .bc1_rgba_srgb)
        let grass = try #require(shown.first { $0.material.uniforms.flags & MaterialFlagMapParticleAnim.rawValue != 0 })
        #expect(grass.material.transparent && grass.pickOccluder)
        let entry = try JSONDecoder().decode(SourceStudioMapCatalog.Entry.self, from: JSONSerialization.data(withJSONObject: [
            "no": 38, "name": "電車(満員)", "bundlePath": "studio/map/m38.unity3d", "scene": "m38", "file": "map.gltf",
            "notDrawn": ["stage effects (2 renderers)", "animated objects (drawn in their authored pose): 1"]]))
        let head = "Map 38 電車(満員) (m38): approximated: no baked lightmaps, map lights, sun-type lighting, fog or ambient; "
            + "particles (no soft-particle fade or per-renderer sorting); unlit textures; "
            + "mob silhouettes in the default mob colour (the user's setting is not read) · 4 triangles, 4 draws"
        let tail = "; not reproduced: stage effects (2 renderers), animated objects (drawn in their authored pose): 1"
        #expect(SourceStudioMapStatus.loaded(entry, asset: asset) == head + tail)
        #expect(SourceStudioMapStatus.loaded(entry, asset: asset, mapOption: false) == head + "; map option off: 1 option draws hidden" + tail)
        asset.release()
        resources.completeRetirements(createdBefore: ResourceClock.tick())
        #expect(resources.statistics().textures == before.textures && resources.statistics().meshes == before.meshes)
    }

    /// The measurement switch cannot decode a block-only image: refused by
    /// name, nothing decoded or left registered. So are a block-only image the
    /// map lists no block file for, bytes that are not a PNG or JPEG, an
    /// animated particle without its second UV set and a silhouette outside
    /// an option root.
    @Test func whatTheLoaderCannotDrawIsRefusedByNameAndRegistersNothing() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let before = resources.statistics()
        let cases: [(Slice4MapFixture.Variant, SourceStudioMapAsset.ImageSource, String)] = [
            (.normal, .decoded, "is block-only (image/x-ikkoku-bc1, no PNG); IKKOKU_SOURCE_MAP_DECODED_TEXTURES=1 cannot decode it"),
            (.noBlockEntry, .blocks, "is block-only but the map lists no matching block file for it"),
            (.garbageImage, .blocks, "image 1 (no mimeType) is not a PNG or JPEG; it is not decoded"),
            (.animWithoutUV2, .blocks, "is an animated particle but lacks TEXCOORD_1 or TEXCOORD_2"),
            (.silhouetteOutsideOption, .blocks, "is not under a map option root"),
        ]
        for (variant, source, reason) in cases {
            let fixture = try Slice4MapFixture(variant)
            defer { fixture.remove() }
            let (url, root) = (fixture.url, fixture.root)
            let counter = DecodeCounter()
            let decoder = counter.decoder
            let failure = try await liveTickOffPool { () -> String? in
                do { _ = try SourceStudioMapAsset.load(url: url, packageRoot: root, resources: resources, imageSource: source, decoder: decoder); return nil }
                catch { return "\(error)" }
            }
            #expect(failure?.contains(reason) == true, "\(variant): \(failure ?? "loaded")")
            #expect(counter.calls == 0, "\(variant): \(counter.calls) decodes")
            let after = resources.statistics()
            #expect(after.meshes == before.meshes && after.textures == before.textures, "\(variant)")
        }
        #expect(SourceStudioMapImageBytes.isPNGOrJPEG(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])))
        #expect(SourceStudioMapImageBytes.isPNGOrJPEG(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        #expect(!SourceStudioMapImageBytes.isPNGOrJPEG(Slice4MapFixture.image) && !SourceStudioMapImageBytes.isPNGOrJPEG(Data()))
    }
}
