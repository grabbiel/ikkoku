import Testing
import Foundation
import Metal
import simd
import Assets
import CoreMath
import Scene
import ShaderTypes
@testable import Studio
@testable import Renderer

// ST-A11 maps, slice 6: map_fragment's normal map against Unity 5.6.2f1's
// UnpackScaleNormal and PerPixelWorldNormal, re-implemented here in float64
// from the formulas of the built-in shader sources (UnityStandardUtils.cginc,
// UnityStandardCore.cginc) on the Unity-side data, then compared with what the
// engine draws from the same data after the export's conversion (positions,
// normals and tangent xyz Z-reflected, tangent w kept, UV (u, 1 - v), texture
// rows reversed to top-down).

/// Unity-side float64 reference: xy = (a, g) * 2 - 1, scaled; z = sqrt(1 -
/// saturate(|xy|²)); normalize(t x + b y + n z), b = cross(n, t) w.
private func unityWorldNormal(a: Double, g: Double, scale: Double, n: SIMD3<Double>, t: SIMD3<Double>, w: Double) -> SIMD3<Double> {
    let x = (a * 2 - 1) * scale, y = (g * 2 - 1) * scale
    let z = (1 - min(1, max(0, x * x + y * y))).squareRoot()
    let b = simd_cross(n, t) * w
    return simd_normalize(t * x + b * y + n * z)
}

/// The export's basis change: Z reflected.
private func reflectZ(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(v.x, v.y, -v.z) }

/// A Unity texture of 4×4 RGBA8 texels, rows bottom-up as Unity stores them:
/// alpha and green vary by column and row so a wrong row or column shows.
private struct Bump {
    static let size = 4
    static func a(_ i: Int, _ j: Int) -> UInt8 { UInt8(64 + 40 * i + 3 * j) }
    /// Green stays at least 52 steps from 127.5 so the y sign moves every texel's normal.
    static func g(_ i: Int, _ j: Int) -> UInt8 { UInt8([230, 180, 75, 25][j] + 4 * i) }
}

/// Draws a full-target quad with `toon_vertex` + `map_fragment` into a 4×4
/// rgba32Float target. The draw is ambient-lit with an ambient whose L1 band
/// returns the shaded normal: gi = n + 2 (white albedo, diffColor factor 1), so
/// each pixel reads back the engine's world normal. `placement` scales the
/// model uniformly (the mesh is shrunk by as much, so the quad still fills
/// the target): the world tangent then is that many times longer.
private func renderNormals(normal: Float3, tangent: Float4, uvs: [Float2], scale: Float, mapped: Bool = true,
                           placement: Float = 1) throws -> [Float3] {
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
    let size = Bump.size
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: size, height: size, mipmapped: false)
    targetDescriptor.usage = [.renderTarget, .shaderRead]; targetDescriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: targetDescriptor))
    // The export's image: Unity's rows reversed to top-down, linear RGBA8.
    let imageDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
    imageDescriptor.storageMode = .shared
    let image = try #require(device.makeTexture(descriptor: imageDescriptor))
    var texels = [UInt8]()
    for row in 0..<size {
        let j = size - 1 - row
        for i in 0..<size { texels += [0, Bump.g(i, j), 0, Bump.a(i, j)] }
    }
    image.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: texels, bytesPerRow: 4 * size)
    var frame = FrameUniforms(); frame.viewProjection = matrix_identity_float4x4
    frame.shadowViewProjection = matrix_identity_float4x4; frame.cameraPosition = Float4(0, 0, 2, 1)
    var draw = DrawUniforms()
    draw.model = Transform.trs(.zero, .identity, Float3(repeating: placement))
    draw.normalMatrix = Transform.trs(.zero, .identity, Float3(repeating: 1 / placement))
    let corners = [Float3(-1, -1, 0.25), Float3(1, -1, 0.25), Float3(1, 1, 0.25), Float3(-1, 1, 0.25)].map { $0 / placement }
    let data = MeshData(name: "normal-probe", positions: corners,
                        normals: Array(repeating: normal, count: 4), tangents: Array(repeating: tangent, count: 4), uvs: uvs,
                        indices: [0, 1, 2, 0, 2, 3])
    let handle = try resources.register(mesh: data)
    defer { resources.unregister(mesh: handle) }
    let mesh = try #require(resources.mesh(handle))
    var standard = SourceStudioStandardInputs(albedo: Float4(1, 1, 1, 1), oneMinusReflectivity: 1, emissionColor: nil,
                                              emissionImage: nil, emissionSRGB: true)
    standard.smoothness = 0; standard.normalScale = scale
    var gltf = MaterialData(name: "map"); gltf.alphaMode = "OPAQUE"
    let material = SourceStudioMapMaterial.make(gltf, standard: standard, base: nil, emission: nil, lightmap: nil, direction: nil,
                                                range: 0, exponent: 0, normal: mapped ? TextureHandle(id: 1) : nil)
    var uniforms = material.uniforms
    var sh = Array(repeating: Float4.zero, count: 7)
    sh[0] = Float4(1, 0, 0, 2); sh[1] = Float4(0, 1, 0, 2); sh[2] = Float4(0, 0, 1, 2)
    let lighting = Renderer.mapLightingUniforms(MapLighting(sh: sh, sun: nil))
    let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
    let command = try #require(queue.makeCommandBuffer())
    let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
    encoder.setRenderPipelineState(pipeline)
    for (buffer, index) in [(mesh.baseVertices, BufferIndexVertices), (mesh.texcoords, BufferIndexTexcoords),
        (mesh.texcoords1, BufferIndexTexcoords1), (mesh.texcoords2, BufferIndexTexcoords2),
        (resources.dummyBuffer, BufferIndexVertexColors), (resources.dummyBuffer, BufferIndexVertexHidden), (resources.dummyBuffer, BufferIndexVertexReceive)] {
        encoder.setVertexBuffer(buffer, offset: 0, index: Int(index.rawValue))
    }
    encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Int(BufferIndexFrameUniforms.rawValue))
    encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: Int(BufferIndexDrawUniforms.rawValue))
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndexMaterial.rawValue))
    bindMapLighting(encoder, frame: frame, lighting: lighting, shadow: try mapShadowPlaceholder(device))
    encoder.setFragmentTexture(resources.whiteTexture, index: Int(TextureIndexBase.rawValue))
    encoder.setFragmentTexture(resources.blackTexture, index: Int(TextureIndexLightmap.rawValue))
    encoder.setFragmentTexture(resources.blackTexture, index: Int(TextureIndexLightmapDirection.rawValue))
    encoder.setFragmentTexture(resources.blackTexture, index: Int(TextureIndexEmission.rawValue))
    encoder.setFragmentTexture(image, index: Int(TextureIndexNormal.rawValue))
    encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    try #require(command.status == .completed, "map_fragment draw failed: \(String(describing: command.error))")
    var pixels = [Float](repeating: 0, count: 4 * size * size)
    pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 16 * size, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
    return (0..<(size * size)).map { Float3(pixels[4 * $0], pixels[4 * $0 + 1], pixels[4 * $0 + 2]) - Float3(repeating: 2) }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func mapFragmentDrawsUnitysDXT5nmNormalThroughTheExportedTangentFrame() throws {
    // A tilted Unity frame, so a sign error in any converted component shows.
    let tilt = simd_quatd(angle: 0.6, axis: simd_normalize(SIMD3<Double>(1, 2, 3)))
    let nU = tilt.act(SIMD3<Double>(0, 0, -1)), tU = tilt.act(SIMD3<Double>(1, 0, 0))
    let scale = 0.7
    // Unity UVs at the quad's corners (positions (-1,-1), (1,-1), (1,1), (-1,1)), u along +x. In the
    // untilted Unity frame (n = -z, t = +x) cross(n, t) is -y, so w = -1 is the usual layout (v grows with
    // +y) and w = +1 the mirrored one (v grows with -y). Both signs are drawn.
    for (w, placement) in [(-1.0, Float(1)), (1.0, Float(1)), (-1.0, Float(2.5))] {
        let unityUV: [SIMD2<Double>] = w < 0 ? [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
                                             : [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
        // The export's conversion.
        let nE = reflectZ(nU), tE = reflectZ(tU)
        let pixels = try renderNormals(normal: Float3(Float(nE.x), Float(nE.y), Float(nE.z)),
                                       tangent: Float4(Float(tE.x), Float(tE.y), Float(tE.z), Float(w)),
                                       uvs: unityUV.map { Float2(Float($0.x), Float(1 - $0.y)) }, scale: Float(scale), placement: placement)
        var flippedApart = 0
        for row in 0..<Bump.size {
            for column in 0..<Bump.size {
                // The pixel centre's Unity UV and the Unity texel it falls in (rows bottom-up).
                let u = (Double(column) + 0.5) / 4, yNDC = 1 - (Double(row) + 0.5) / 2
                let v = w < 0 ? (yNDC + 1) / 2 : (1 - yNDC) / 2
                let i = Int(u * 4), j = Int(v * 4)
                let a = Double(Bump.a(i, j)) / 255, g = Double(Bump.g(i, j)) / 255
                let want = reflectZ(unityWorldNormal(a: a, g: g, scale: scale, n: nU, t: tU, w: w))
                let got = pixels[row * Bump.size + column]
                let label = "w \(w) placement \(placement) pixel (\(column), \(row)) texel (\(i), \(j))"
                #expect(simd_length(SIMD3<Double>(Double(got.x), Double(got.y), Double(got.z)) - want) < 2e-3, "\(label): \(got) != \(want)")
                // Negative control: Unity's formula with the green channel unflipped by the export (the
                // engine's y not negated) lands elsewhere.
                let unflipped = reflectZ(unityWorldNormal(a: a, g: 1 - g, scale: scale, n: nU, t: tU, w: w))
                if simd_length(unflipped - want) > 0.05 { flippedApart += 1 }
            }
        }
        #expect(flippedApart == 16, "w \(w) placement \(placement): the y sign must matter on every texel")
    }
    // Without the flag the geometric normal is drawn, whatever the texture holds.
    let flat = try renderNormals(normal: Float3(0, 0, 1), tangent: Float4(1, 0, 0, -1),
                                 uvs: [Float2(0, 1), Float2(1, 1), Float2(1, 0), Float2(0, 0)], scale: 1, mapped: false)
    #expect(flat.allSatisfy { simd_length($0 - Float3(0, 0, 1)) < 1e-5 })
}

@Test func standardInputsReadTheNormalMapAndTheMaterialDrawsItOnlyForStandard() throws {
    func parse(_ normal: Any) throws -> SourceStudioStandardInputs? {
        let record: [String: Any] = ["albedoLinear": [1, 1, 1, 1], "oneMinusReflectivity": 0.9, "emission": NSNull(),
                                     "smoothness": 0.5, "specularHighlights": true, "premultiplyAlpha": false, "normal": normal]
        let data = try JSONSerialization.data(withJSONObject: ["ikkokuStandard": record])
        return try SourceStudioStandardInputs.parse(try JSONDecoder().decode(JSONValue.self, from: data))
    }
    let inputs = try #require(try parse(["image": 3, "scale": 0.3, "packing": "unityDXT5nm", "srgb": false, "textureFormat": "DXT5"]))
    #expect(inputs.normalImage == 3 && inputs.normalScale == 0.3 && !inputs.normalSRGB)
    #expect(try parse(NSNull())?.normalImage == nil)
    for bad: [String: Any] in [["image": 3, "scale": 0.3, "packing": "rgb", "srgb": false],
                               ["image": -1, "scale": 0.3, "packing": "unityDXT5nm", "srgb": false],
                               ["image": 3, "packing": "unityDXT5nm", "srgb": false]] {
        #expect(throws: RigError.self) { try parse(bad) }
    }
    var gltf = MaterialData(name: "m"); gltf.alphaMode = "OPAQUE"
    let normal = TextureHandle(id: 9)
    let standard = SourceStudioMapMaterial.make(gltf, standard: inputs, base: nil, emission: nil, lightmap: nil, direction: nil,
                                                range: 0, exponent: 0, normal: normal)
    #expect(standard.normal == normal && standard.uniforms.flags & MaterialFlagMapNormal.rawValue != 0 && standard.uniforms.params.z == 0.3)
    let lambert = SourceStudioMapMaterial.make(gltf, standard: inputs, base: nil, emission: nil, lightmap: nil, direction: nil,
                                               range: 0, exponent: 0, lambert: true, normal: normal)
    #expect(lambert.normal == nil && lambert.uniforms.flags & MaterialFlagMapNormal.rawValue == 0)
    // The irradiance image matches the slice-4 oracle's template, which samples no _BumpMap.
    let lit = SourceStudioMapMaterial.make(gltf, standard: inputs, base: nil, emission: nil, lightmap: TextureHandle(id: 4), direction: nil,
                                           range: 5, exponent: 1, normal: normal)
    let irradiance = try #require(SourceStudioMapMaterial.irradiance(lit))
    #expect(irradiance.normal == nil && irradiance.uniforms.flags & MaterialFlagMapNormal.rawValue == 0)
    // The export's mark.
    func mark(_ value: Any) throws -> Bool {
        let data = try JSONSerialization.data(withJSONObject: ["ikkokuMapNormals": value])
        return try SourceStudioMapNormals.exported(try JSONDecoder().decode(JSONValue.self, from: data), label: "m")
    }
    #expect(try mark(["kind": "ikkoku.unityNormalMaps", "version": 1, "packing": "unityDXT5nm", "materials": 2, "images": 1]))
    #expect(try SourceStudioMapNormals.exported(nil, label: "m") == false)
    #expect(throws: RigError.self) { try mark(["kind": "ikkoku.unityNormalMaps", "version": 2, "packing": "unityDXT5nm"]) }
}
