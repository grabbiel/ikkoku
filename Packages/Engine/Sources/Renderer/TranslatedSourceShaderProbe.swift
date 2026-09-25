import Foundation
import CryptoKit
import Metal
import CoreGraphics
import simd
import CoreMath
import ShaderTypes

/// Runs a recovered, hash-identified shader stage pair against the exact source
/// fixture inputs. Unknown constant bindings/pass states fail instead of silently
/// substituting the native toon shader. Derived MSL stays in private local assets.
public extension OriginalFrameProbe {
    func captureTranslatedShader(frameURL: URL, programURL: URL, resources: ResourceStore, queue: any MTLCommandQueue, allFamilies: Bool = false) throws -> CGImage {
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: false); colorDescriptor.usage = .renderTarget; colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: width, height: height, mipmapped: false); depthDescriptor.usage = .renderTarget; depthDescriptor.storageMode = .private
        guard let color = resources.device.makeTexture(descriptor: colorDescriptor), let depth = resources.device.makeTexture(descriptor: depthDescriptor), let command = queue.makeCommandBuffer() else { throw ProbeError.gpu("Source shader targets") }
        let outline = programURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(programURL.deletingLastPathComponent().lastPathComponent + "_outline/program.json")
        let programs = FileManager.default.fileExists(atPath: outline.path) ? [outline, programURL] : [programURL]
        var jobs: [(program: URL, item: Int?)] = programs.map { ($0, nil) }
        if allFamilies {
            guard let source = try JSONSerialization.jsonObject(with: Data(contentsOf: frameURL)) as? [String: Any], let meshes = source["meshes"] as? [[String: Any]] else { throw ProbeError.invalid("Source mesh list") }
            var draws: [(queue: Int, index: Int, programs: [URL])] = [], index = 0
            let directory = programURL.deletingLastPathComponent().deletingLastPathComponent()
            for mesh in meshes {
                guard let materials = mesh["materials"] as? [[String: Any]], let count = mesh["submeshes"] as? Int, count <= materials.count else { throw ProbeError.invalid("Source material list") }
                for material in materials.prefix(count) {
                    defer { index += 1 }
                    guard let shader = material["shader"] as? String, let renderQueue = material["queue"] as? Int else { throw ProbeError.invalid("Source shader identity") }
                    // This original shader contains only a ShadowCaster pass;
                    // the controlled camera has shadows disabled.
                    if shader == "Shader Forge/shadowcast" { continue }
                    guard shader.hasPrefix("Shader Forge/"), shader.split(separator: "/").count == 2 else { throw ProbeError.invalid("Unknown source shader family") }
                    let name = String(shader.split(separator: "/")[1])
                    let forward = directory.appendingPathComponent(name + "/program.json")
                    let outline = directory.appendingPathComponent(name + "_outline/program.json")
                    guard FileManager.default.fileExists(atPath: forward.path) else { throw ProbeError.invalid("Missing translated shader \(shader)") }
                    draws.append((renderQueue, index, FileManager.default.fileExists(atPath: outline.path) ? [outline, forward] : [forward]))
                }
            }
            jobs = draws.sorted { $0.queue == $1.queue ? $0.index < $1.index : $0.queue < $1.queue }.flatMap { draw in draw.programs.map { ($0, Optional(draw.index)) } }
        }
        for (index, job) in jobs.enumerated() { try encodeTranslatedShader(frameURL: frameURL, programURL: job.program, resources: resources, color: color, depth: depth, command: command, clear: index == 0, selectedItem: job.item, sourceBackground: allFamilies) }
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw ProbeError.gpu(error.localizedDescription) }
        var bytes = [UInt8](repeating: 0, count: width * height * 4); bytes.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ProbeError.gpu("Source shader image") }
        return image
    }

    private func encodeTranslatedShader(frameURL: URL, programURL: URL, resources: ResourceStore, color: any MTLTexture, depth: any MTLTexture, command: any MTLCommandBuffer, clear: Bool, selectedItem: Int?, sourceBackground: Bool) throws {
        typealias Row = [String: Any]
        func object(_ url: URL) throws -> Row { guard let row = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? Row else { throw ProbeError.invalid("Shader descriptor") }; return row }
        func integer(_ value: Any?) throws -> Int { guard let n = value as? NSNumber else { throw ProbeError.invalid("Missing integer shader binding") }; return n.intValue }
        func floats(_ value: Any?) throws -> [Float] { guard let a = value as? [NSNumber], a.allSatisfy({ $0.floatValue.isFinite }) else { throw ProbeError.invalid("Invalid shader vector") }; return a.map(\.floatValue) }
        let original = try object(frameURL), program = try object(programURL)
        guard let shaderName = program["name"] as? String, let stages = program["programs"] as? [String: Row],
              let names = program["names"] as? [String: String], let properties = program["properties"] as? [Row],
              let state = program["passState"] as? Row, let sourceMeshes = original["meshes"] as? [Row],
              let globals = original["globals"] as? Row, let sourceCamera = original["camera"] as? Row,
              let light = original["light"] as? Row, let textureRows = original["textures"] as? [Row] else { throw ProbeError.invalid("Incomplete shader capture descriptor") }
        func name(_ index: Any?) throws -> String { guard let result = names[String(try integer(index))] else { throw ProbeError.invalid("Unknown uniform name") }; return result }
        let propertiesByName = Dictionary(uniqueKeysWithValues: try properties.map { p -> (String, Row) in guard let n = p["m_Name"] as? String else { throw ProbeError.invalid("Property name") }; return (n, p) })
        let texturesByFile = Dictionary(uniqueKeysWithValues: try textureRows.map { t -> (String, Row) in guard let n = t["file"] as? String else { throw ProbeError.invalid("Texture name") }; return (n, t) })
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let sourceData = try Data(contentsOf: programURL.deletingLastPathComponent().appendingPathComponent("source.metal"))
        guard program["sourceMSLSHA256"] as? String == SHA256.hash(data: sourceData).map({ String(format: "%02x", $0) }).joined(), let sourceCode = String(data: sourceData, encoding: .utf8) else { throw ProbeError.invalid("Translated shader identity changed") }
        let library = try resources.device.makeLibrary(source: sourceCode, options: options)
        let descriptor = MTLRenderPipelineDescriptor(); descriptor.vertexFunction = library.makeFunction(name: "source_vertex"); descriptor.fragmentFunction = library.makeFunction(name: "source_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm_srgb; descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8; descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        func stateValue(_ key: String, in row: Row? = nil) throws -> Int { guard let v = (row ?? state)[key] as? Row else { throw ProbeError.invalid("Pass state \(key)") }; return try integer(v["val"]) }
        guard try stateValue("zTest") == 4, [0, 1].contains(try stateValue("zWrite")),
              let stencil = state["stencilOp"] as? Row, let blend = state["rtBlend0"] as? Row,
              try stateValue("blendOp", in: blend) == 0, try stateValue("blendOpAlpha", in: blend) == 0,
              try stateValue("offsetFactor") == 0, try stateValue("offsetUnits") == 0 else { throw ProbeError.invalid("Unimplemented source render-pass state") }
        func factor(_ name: String) throws -> MTLBlendFactor {
            switch try stateValue(name, in: blend) { case 0: return .zero; case 1: return .one; case 5: return .sourceAlpha; case 10: return .oneMinusSourceAlpha; default: throw ProbeError.invalid("Unsupported source blend factor") }
        }
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = try factor("srcBlend"); descriptor.colorAttachments[0].sourceAlphaBlendFactor = try factor("srcBlendAlpha")
        descriptor.colorAttachments[0].destinationRGBBlendFactor = try factor("destBlend"); descriptor.colorAttachments[0].destinationAlphaBlendFactor = try factor("destBlendAlpha")
        let pipeline = try resources.device.makeRenderPipelineState(descriptor: descriptor)
        let depthStateDescriptor = MTLDepthStencilDescriptor(); depthStateDescriptor.depthCompareFunction = .greaterEqual; depthStateDescriptor.isDepthWriteEnabled = try stateValue("zWrite") == 1
        let stencilDescriptor = MTLStencilDescriptor()
        switch try stateValue("comp", in: stencil) { case 8: stencilDescriptor.stencilCompareFunction = .always; case 6: stencilDescriptor.stencilCompareFunction = .notEqual; default: throw ProbeError.invalid("Unsupported source stencil comparison") }
        switch try stateValue("pass", in: stencil) { case 0: stencilDescriptor.depthStencilPassOperation = .keep; case 2: stencilDescriptor.depthStencilPassOperation = .replace; default: throw ProbeError.invalid("Unsupported source stencil operation") }
        guard try stateValue("fail", in: stencil) == 0, try stateValue("zFail", in: stencil) == 0 else { throw ProbeError.invalid("Unsupported source stencil failure") }
        let readMask = try stateValue("stencilReadMask"), writeMask = try stateValue("stencilWriteMask"), stencilReference = try stateValue("stencilRef")
        guard (0...255).contains(readMask), (0...255).contains(writeMask), (0...255).contains(stencilReference) else { throw ProbeError.invalid("Source stencil mask") }
        stencilDescriptor.readMask = UInt32(readMask); stencilDescriptor.writeMask = UInt32(writeMask)
        depthStateDescriptor.frontFaceStencil = stencilDescriptor; depthStateDescriptor.backFaceStencil = stencilDescriptor
        guard let depthState = resources.device.makeDepthStencilState(descriptor: depthStateDescriptor) else { throw ProbeError.gpu("Source depth state") }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = clear ? .clear : .load; pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        if sourceBackground, let background = original["background"] as? [NSNumber], background.count == 4 {
            func linearBackground(_ n: NSNumber) -> Double { let x = n.doubleValue; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            pass.colorAttachments[0].clearColor = MTLClearColorMake(linearBackground(background[0]), linearBackground(background[1]), linearBackground(background[2]), background[3].doubleValue)
        }
        pass.stencilAttachment.texture = depth; pass.stencilAttachment.loadAction = clear ? .clear : .load; pass.stencilAttachment.storeAction = .store; pass.stencilAttachment.clearStencil = 0
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = clear ? .clear : .load; pass.depthAttachment.storeAction = .store; pass.depthAttachment.clearDepth = 0
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw ProbeError.gpu("Source shader encoder") }
        var endedEncoding = false
        defer { if !endedEncoding { encoder.endEncoding() } }
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState); encoder.setFrontFacing(.counterClockwise); encoder.setStencilReferenceValue(UInt32(stencilReference))
        let culling = try stateValue("culling"); guard (0...2).contains(culling) else { throw ProbeError.invalid("Source culling state") }; encoder.setCullMode(culling == 0 ? .none : culling == 1 ? .front : .back)
        let folder = frameURL.deletingLastPathComponent()
        var retainedBuffers: [any MTLBuffer] = [], retainedTextures: [any MTLTexture] = [], retainedSamplers: [any MTLSamplerState] = []
        func file(_ name: String) throws -> URL { guard name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else { throw ProbeError.invalid("Source texture path") }; return folder.appendingPathComponent(name) }
        func linear(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        func defaultValue(_ name: String) throws -> [Float] {
            guard let property = propertiesByName[name] else { throw ProbeError.invalid("Unknown source shader constant \(name)") }
            return (0..<4).map { (property["m_DefValue[\($0)]"] as? NSNumber)?.floatValue ?? 0 }
        }
        var objectToWorld = matrix_identity_float4x4
        func uniform(_ key: String, material: Row) throws -> [Float] {
            if key == "_ScreenParams" { return [Float(width), Float(height), 1 + 1 / Float(width), 1 + 1 / Float(height)] }
            if key == "_ProjectionParams" { return [1, frame.camera.near, sourceFar, 1 / sourceFar] }
            if key == "unity_WorldTransformParams" { return [0, 0, 0, simd_determinant(objectToWorld) < 0 ? -1 : 1] }
            if key == "_WorldSpaceCameraPos" { return try floats(sourceCamera["position"]) }
            if key == "_WorldSpaceLightPos0" { return try floats(light["direction"]).map(-) + [0] }
            if key == "_LightColor0" { var c = try floats(light["color"]); let intensity = (light["intensity"] as? NSNumber)?.floatValue ?? 1; for i in 0..<3 { c[i] = linear(c[i]) * intensity }; return c }
            if let value = globals[key] { if let scalar = value as? NSNumber { return [scalar.floatValue] }; return try floats(value) }
            if key.hasSuffix("_ST") { let base = String(key.dropLast(3)); if let texture = material[base] as? Row { return try floats(texture["scale"]) + floats(texture["offset"]) }; return [1, 1, 0, 0] }
            var value: [Float]
            if let input = material[key] as? NSNumber { value = [input.floatValue] }
            else if let input = material[key] { value = try floats(input) }
            else { value = try defaultValue(key) }
            if (propertiesByName[key]?["m_Type"] as? NSNumber)?.intValue == 0 { for i in 0..<min(3, value.count) { value[i] = linear(value[i]) } }
            return value
        }
        func stage(_ stage: String, material: Row) throws {
            guard let description = stages[stage], let metadata = description["metadata"] as? Row,
                  let buffers = metadata["m_ConstantBuffers"] as? [Row], let bindings = metadata["m_ConstantBufferBindings"] as? [Row],
                  let textures = metadata["m_TextureParams"] as? [Row] else { throw ProbeError.invalid("Shader stage metadata") }
            for buffer in buffers {
                let bufferName = try integer(buffer["m_NameIndex"])
                guard let binding = bindings.first(where: { ($0["m_NameIndex"] as? NSNumber)?.intValue == bufferName }) else { throw ProbeError.invalid("Unbound source constant buffer") }
                let slot = try integer(binding["m_Index"]), size = try integer(buffer["m_Size"])
                guard (1...65536).contains(size), size % 4 == 0, (0..<16).contains(slot) else { throw ProbeError.invalid("Source buffer size/index") }
                var data = [Float](repeating: 0, count: size / 4)
                for parameter in buffer["m_MatrixParams"] as? [Row] ?? [] {
                    let key = try name(parameter["m_NameIndex"]), offset = try integer(parameter["m_Index"]) / 4
                    let matrix: float4x4
                    switch key {
                    case "unity_ObjectToWorld": matrix = objectToWorld
                    case "unity_WorldToObject": matrix = objectToWorld.inverse
                    case "unity_MatrixV": matrix = frame.camera.viewMatrix() * UnityCoordinates.basis
                    case "glstate_matrix_projection", "unity_CameraProjection": matrix = frame.camera.projectionMatrix(aspect: Float(width) / Float(height))
                    case "unity_MatrixVP": matrix = frame.camera.projectionMatrix(aspect: Float(width) / Float(height)) * frame.camera.viewMatrix() * UnityCoordinates.basis
                    default: throw ProbeError.invalid("Unknown source shader matrix \(key)")
                    }
                    guard offset >= 0, offset + 16 <= data.count else { throw ProbeError.invalid("Source matrix range") }
                    for column in 0..<4 { for row in 0..<4 { data[offset + column * 4 + row] = matrix[column][row] } }
                }
                for parameter in buffer["m_VectorParams"] as? [Row] ?? [] {
                    let key = try name(parameter["m_NameIndex"]), offset = try integer(parameter["m_Index"]) / 4, dimension = try integer(parameter["m_Dim"])
                    let value = try uniform(key, material: material)
                    guard (1...4).contains(dimension), value.count >= dimension, offset >= 0, offset + dimension <= data.count else { throw ProbeError.invalid("Source vector range \(key)") }
                    for lane in 0..<dimension { data[offset + lane] = value[lane] }
                }
                guard let gpu = resources.device.makeBuffer(bytes: data, length: size) else { throw ProbeError.gpu("Source constants") }; retainedBuffers.append(gpu)
                if stage == "vertex" { encoder.setVertexBuffer(gpu, offset: 0, index: slot + 8) } else { encoder.setFragmentBuffer(gpu, offset: 0, index: slot + 8) }
            }
            for texture in textures {
                let key = try name(texture["m_NameIndex"]), slot = try integer(texture["m_Index"]), samplerSlot = try integer(texture["m_SamplerIndex"])
                let gpuTexture: any MTLTexture; var row: Row = [:]
                let filename = (material[key] as? Row)?["file"] as? String ?? globals[key] as? String
                if let filename {
                    let handle = try loadOriginalProbeTexture(url: file(filename), metadata: texturesByFile[filename] ?? [:], resources: resources)
                    guard let loaded = resources.texture(handle) else { throw ProbeError.gpu("Source texture") }; gpuTexture = loaded; row = texturesByFile[filename] ?? [:]
                } else {
                    guard let property = propertiesByName[key], let defaults = property["m_DefTexture"] as? Row, let kind = defaults["m_DefaultName"] as? String else { throw ProbeError.invalid("Missing original texture \(key)") }
                    let value: Float4
                    switch kind { case "white": value = Float4(repeating: 1); case "black": value = Float4(repeating: 0); case "gray": value = Float4(repeating: 0.5); case "bump": value = Float4(0.5, 0.5, 1, 0.5); default: throw ProbeError.invalid("Unknown Unity fallback texture \(kind)") }
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false); d.usage = .shaderRead
                    guard let texture = resources.device.makeTexture(descriptor: d) else { throw ProbeError.gpu("Source fallback") }; var pixel = value
                    withUnsafeBytes(of: &pixel) { texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }; gpuTexture = texture
                }
                let sampler = MTLSamplerDescriptor(); sampler.minFilter = row["filter"] as? String == "Point" ? .nearest : .linear; sampler.magFilter = sampler.minFilter; sampler.mipFilter = row["filter"] as? String == "Trilinear" ? .linear : .nearest
                sampler.sAddressMode = row["wrap"] as? String == "Clamp" ? .clampToEdge : .repeat; sampler.tAddressMode = sampler.sAddressMode; sampler.maxAnisotropy = max(1, min(16, (row["aniso"] as? Int) ?? 1))
                let anisotropicMode = original["anisotropicFiltering"] as? String
                if anisotropicMode == "Disable" { sampler.maxAnisotropy = 1 }
                else if anisotropicMode == "ForceEnable", (row["aniso"] as? Int ?? 0) > 0, row["filter"] as? String != "Point" { sampler.maxAnisotropy = max(9, sampler.maxAnisotropy) }
                // The original player uses D3D11: anisotropic samplers always
                // enable trilinear mip filtering, independently of Texture.filterMode.
                if sampler.maxAnisotropy > 1 { sampler.mipFilter = .linear }
                guard let gpuSampler = resources.device.makeSamplerState(descriptor: sampler) else { throw ProbeError.gpu("Source sampler") }
                retainedTextures.append(gpuTexture); retainedSamplers.append(gpuSampler)
                if stage == "vertex" { encoder.setVertexTexture(gpuTexture, index: slot); encoder.setVertexSamplerState(gpuSampler, index: samplerSlot) } else { encoder.setFragmentTexture(gpuTexture, index: slot); encoder.setFragmentSamplerState(gpuSampler, index: samplerSlot) }
            }
        }
        var itemIndex = 0, draws = 0
        for sourceMesh in sourceMeshes {
            guard let materials = sourceMesh["materials"] as? [Row], let submeshes = sourceMesh["submeshes"] as? Int else { throw ProbeError.invalid("Source mesh metadata") }
            for index in 0..<submeshes {
                defer { itemIndex += 1 }
                guard index < materials.count, itemIndex < frame.items.count else { throw ProbeError.invalid("Source material index") }
                let material = materials[index]; if material["shader"] as? String != shaderName || (selectedItem != nil && itemIndex != selectedItem) { continue }
                let transform = try floats(sourceMesh["rendererMatrix"])
                guard transform.count == 16 else { throw ProbeError.invalid("Source object transform") }
                objectToWorld = float4x4(columns: (Float4(transform[0], transform[1], transform[2], transform[3]), Float4(transform[4], transform[5], transform[6], transform[7]), Float4(transform[8], transform[9], transform[10], transform[11]), Float4(transform[12], transform[13], transform[14], transform[15])))
                guard abs(simd_determinant(objectToWorld)) > 1e-8 else { throw ProbeError.invalid("Singular source object transform") }
                let worldToObject = objectToWorld.inverse
                guard let values = material["properties"] as? Row, let mesh = resources.mesh(frame.items[itemIndex].mesh),
                      let semantics = stages["vertex"]?["inputSemantics"] as? [String: Row] else { throw ProbeError.invalid("Source vertex inputs") }
                var uv3: [Float2] = []
                if let uv3File = sourceMesh["uv3File"] as? String {
                    let bytes = try Data(contentsOf: file(uv3File)); guard bytes.count == mesh.vertexCount * 8 else { throw ProbeError.invalid("Source UV3 dimensions") }
                    uv3 = bytes.withUnsafeBytes { raw in (0..<mesh.vertexCount).map { Float2(raw.loadUnaligned(fromByteOffset: $0 * 8, as: Float.self), raw.loadUnaligned(fromByteOffset: $0 * 8 + 4, as: Float.self)) } }
                }
                let registers = try semantics.keys.map { key -> Int in guard let value = Int(key) else { throw ProbeError.invalid("Vertex register") }; return value }.sorted()
                var input: [Float4] = []
                let vertices = mesh.baseVertices.contents().bindMemory(to: DeformedVertex.self, capacity: mesh.vertexCount)
                for vertex in 0..<mesh.vertexCount {
                    for register in registers {
                        let semantic = semantics[String(register)]!, key = semantic["name"] as? String
                        switch key {
                        case "POSITION": let p = vertices[vertex].position; input.append(worldToObject * Float4(p.x, p.y, -p.z, 1))
                        case "NORMAL": let n = vertices[vertex].normal; input.append(objectToWorld.transpose * Float4(n.x, n.y, -n.z, 0))
                        case "TANGENT": let tangent = UnityCoordinates.tangent(vertices[vertex].tangent); let transformed = worldToObject * Float4(tangent.x, tangent.y, tangent.z, 0); input.append(Float4(simd_normalize(Float3(transformed.x, transformed.y, transformed.z)), tangent.w))
                        case "TEXCOORD":
                            let set = try integer(semantic["index"])
                            if set == 3 { guard uv3.count == mesh.vertexCount else { throw ProbeError.invalid("Missing source UV3") }; input.append(Float4(uv3[vertex].x, uv3[vertex].y, 0, 0)) }
                            else { guard (0...2).contains(set) else { throw ProbeError.invalid("Unsupported source UV set") }; let buffer = set == 0 ? mesh.texcoords : set == 1 ? mesh.texcoords1 : mesh.texcoords2; let uv = buffer.contents().bindMemory(to: Float2.self, capacity: mesh.vertexCount)[vertex]; input.append(Float4(uv.x, 1 - uv.y, 0, 0)) }
                        case "COLOR": if let color = mesh.colors { let c = color.contents().bindMemory(to: SIMD4<UInt8>.self, capacity: mesh.vertexCount)[vertex]; input.append(Float4(c) / 255) } else { input.append(Float4(repeating: 1)) }
                        default: throw ProbeError.invalid("Unsupported source vertex semantic")
                        }
                    }
                }
                guard let buffer = resources.device.makeBuffer(bytes: input, length: input.count * 16) else { throw ProbeError.gpu("Source vertex input") }; retainedBuffers.append(buffer)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0); try stage("vertex", material: values); try stage("fragment", material: values)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0); draws += 1
            }
        }
        guard draws > 0 else { throw ProbeError.invalid("No source materials match the translated shader") }
        encoder.endEncoding(); endedEncoding = true
        withExtendedLifetime((retainedBuffers, retainedTextures, retainedSamplers)) {}

    }
}
