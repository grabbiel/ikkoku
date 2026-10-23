import Foundation
import CryptoKit
import Metal
import CoreGraphics
import simd
import CoreMath
import ShaderTypes

/// One source draw in the fixture's draw order: its render queue, the flat index
/// of its item in `frame.items`, the renderer material slot, its source mesh,
/// its shader family, and the programs to draw — outline before forward when the
/// family has both programs, otherwise a single forward program. A material slot
/// beyond the mesh's submesh count draws over the last submesh, as Unity does,
/// so its `item` is that submesh's item.
public struct TranslatedDraw {
    public let queue: Int
    public let item: Int
    public let slot: Int
    public let mesh: String
    public let family: String
    public let passes: [(pass: String, program: URL)]
    public init(queue: Int, item: Int, slot: Int, mesh: String, family: String, passes: [(pass: String, program: URL)]) {
        self.queue = queue; self.item = item; self.slot = slot; self.mesh = mesh; self.family = family; self.passes = passes
    }
}

/// One snapshot of the draw trace: everything drawn so far in the full render
/// (list index `draw`, 1…N) plus the RGBA and depth remaining at each traced pixel.
public struct DrawTraceRecord: Codable, Sendable {
    public let draw: Int
    public let family: String
    public let mesh: String
    public let pass: String
    public let queue: Int
    public let pixels: [String: DrawTraceSample]
    public init(draw: Int, family: String, mesh: String, pass: String, queue: Int, pixels: [String: DrawTraceSample]) {
        self.draw = draw; self.family = family; self.mesh = mesh; self.pass = pass; self.queue = queue; self.pixels = pixels
    }
}

/// Original RGBA bytes and reverse-Z depth sampled at one traced pixel.
public struct DrawTraceSample: Codable, Sendable {
    public let rgba: [Int]
    public let depth: Float
    public init(rgba: [Int], depth: Float) { self.rgba = rgba; self.depth = depth }
}

/// Runs a recovered, hash-identified shader stage pair against the exact source
/// fixture inputs. Unknown constant bindings/pass states fail instead of silently
/// substituting the native toon shader. Derived MSL stays in private local assets.
public extension OriginalFrameProbe {
    func captureTranslatedShader(frameURL: URL, programURL: URL, resources: ResourceStore, queue: any MTLCommandQueue, allFamilies: Bool = false, families: Set<String>? = nil, depth24Quantized: Bool = false) throws -> CGImage {
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: false); colorDescriptor.usage = .renderTarget; colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: width, height: height, mipmapped: false); depthDescriptor.usage = .renderTarget; depthDescriptor.storageMode = .private
        guard let color = resources.device.makeTexture(descriptor: colorDescriptor), let depth = resources.device.makeTexture(descriptor: depthDescriptor), let command = queue.makeCommandBuffer() else { throw ProbeError.gpu("Source shader targets") }
        let outline = programURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(programURL.deletingLastPathComponent().lastPathComponent + "_outline/program.json")
        let programs = FileManager.default.fileExists(atPath: outline.path) ? [outline, programURL] : [programURL]
        var jobs: [(program: URL, selected: (item: Int, slot: Int)?)] = programs.map { ($0, nil) }
        if allFamilies || families != nil {
            jobs = try translatedDrawOrder(frameURL: frameURL, programURL: programURL, families: families)
                .flatMap { draw in draw.passes.map { ($0.program, (draw.item, draw.slot)) } }
        }
        for (index, job) in jobs.enumerated() { try encodeTranslatedShader(frameURL: frameURL, programURL: job.program, resources: resources, color: color, depth: depth, command: command, clear: index == 0, selected: job.selected, sourceBackground: allFamilies, depth24Quantized: depth24Quantized) }
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw ProbeError.gpu(error.localizedDescription) }
        var bytes = [UInt8](repeating: 0, count: width * height * 4); bytes.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ProbeError.gpu("Source shader image") }
        return image
    }

    /// Traces every draw in the full-character sequence — the same sorted draws
    /// `captureTranslatedShader` renders — re-rendering the truncated list so each
    /// record shows what remains at each traced pixel after draw `k`, to locate
    /// exactly which draw erases or moves a silhouette pixel. Depth reaches the
    /// report through a blit copy of the 4-byte float depth plane into a shared
    /// buffer using `.depthFromDepthStencil`: `getBytes` is not usable on
    /// `depth32Float_stencil8` textures (the synchronous copy crashes).
    func captureTranslatedDrawTrace(frameURL: URL, programURL: URL, resources: ResourceStore, queue: any MTLCommandQueue, pixels: [(x: Int, y: Int)]) throws -> [DrawTraceRecord] {
        guard (1...256).contains(pixels.count) else { throw ProbeError.invalid("Trace pixel list must contain 1–256 pixels") }
        guard pixels.allSatisfy({ (0..<width).contains($0.x) && (0..<height).contains($0.y) }) else { throw ProbeError.invalid("Trace pixel outside the capture") }
        struct Unit { let queue: Int; let item: Int; let slot: Int; let mesh: String; let family: String; let pass: String; let program: URL }
        let order = try translatedDrawOrder(frameURL: frameURL, programURL: programURL, families: nil)
        let units: [Unit] = order.flatMap { draw in draw.passes.map { Unit(queue: draw.queue, item: draw.item, slot: draw.slot, mesh: draw.mesh, family: draw.family, pass: $0.pass, program: $0.program) } }
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: false); colorDescriptor.usage = .renderTarget; colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: width, height: height, mipmapped: false); depthDescriptor.usage = [.renderTarget, .shaderRead]; depthDescriptor.storageMode = .private
        guard let color = resources.device.makeTexture(descriptor: colorDescriptor), let depth = resources.device.makeTexture(descriptor: depthDescriptor) else { throw ProbeError.gpu("Source shader trace targets") }
        var records: [DrawTraceRecord] = []
        for count in 1...units.count {
            guard let command = queue.makeCommandBuffer() else { throw ProbeError.gpu("Source shader trace command") }
            for (index, unit) in units.prefix(count).enumerated() {
                try encodeTranslatedShader(frameURL: frameURL, programURL: unit.program, resources: resources, color: color, depth: depth, command: command, clear: index == 0, selected: (unit.item, unit.slot), sourceBackground: true)
            }
            guard let readback = resources.device.makeBuffer(length: 4 * pixels.count) else { throw ProbeError.gpu("Source shader trace readback") }
            guard let blit = command.makeBlitCommandEncoder() else { throw ProbeError.gpu("Source shader trace blit") }
            for (slot, pixel) in pixels.enumerated() {
                blit.copy(from: depth, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: pixel.x, y: pixel.y, z: 0), sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: readback, destinationOffset: 4 * slot, destinationBytesPerRow: 4, destinationBytesPerImage: 4, options: .depthFromDepthStencil)
            }
            blit.endEncoding()
            command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw ProbeError.gpu("Source shader trace draw \(count): \(error.localizedDescription)") }
            var colorBytes = [UInt8](repeating: 0, count: width * height * 4)
            colorBytes.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
            var samples: [String: DrawTraceSample] = [:]
            for (slot, pixel) in pixels.enumerated() {
                let depth = readback.contents().load(fromByteOffset: 4 * slot, as: Float.self)
                let offset = (pixel.y * width + pixel.x) * 4
                samples["\(pixel.x),\(pixel.y)"] = DrawTraceSample(rgba: Array(colorBytes[offset..<(offset + 4)]).map(Int.init), depth: depth)
            }
            let last = units[count - 1]
            records.append(DrawTraceRecord(draw: count, family: last.family, mesh: last.mesh, pass: last.pass, queue: last.queue, pixels: samples))
        }
        return records
    }

    /// Builds the fixture's whole draw list: one source draw per material slot
    /// that has a translated program, sorted by render queue first and source
    /// material order second; within one object the outline program precedes
    /// the forward program. A slot beyond the submesh count draws the last
    /// submesh again with its own material (Unity's extra-material rule). No
    /// per-queue distance ordering or shader pass order yet (R1).
    private func translatedDrawOrder(frameURL: URL, programURL: URL, families: Set<String>?) throws -> [TranslatedDraw] {
        guard let source = try JSONSerialization.jsonObject(with: Data(contentsOf: frameURL)) as? [String: Any], let meshes = source["meshes"] as? [[String: Any]] else { throw ProbeError.invalid("Source mesh list") }
        var draws: [(draw: TranslatedDraw, order: Int)] = [], firstItem = 0, order = 0
        let directory = programURL.deletingLastPathComponent().deletingLastPathComponent()
        for mesh in meshes {
            guard let materials = mesh["materials"] as? [[String: Any]], let count = mesh["submeshes"] as? Int, count > 0, count <= materials.count else { throw ProbeError.invalid("Source material list") }
            defer { firstItem += count }
            for (slot, material) in materials.enumerated() {
                defer { order += 1 }
                guard let shader = material["shader"] as? String, let renderQueue = material["queue"] as? Int else { throw ProbeError.invalid("Source shader identity") }
                // This original shader contains only a ShadowCaster pass;
                // the controlled camera has shadows disabled.
                if shader == "Shader Forge/shadowcast" { continue }
                guard shader.hasPrefix("Shader Forge/"), shader.split(separator: "/").count == 2 else { throw ProbeError.invalid("Unknown source shader family") }
                let name = String(shader.split(separator: "/")[1])
                if let filter = families, !filter.contains(name) { continue }
                let forward = directory.appendingPathComponent(name + "/program.json")
                let outline = directory.appendingPathComponent(name + "_outline/program.json")
                guard FileManager.default.fileExists(atPath: forward.path) else { throw ProbeError.invalid("Missing translated shader \(shader)") }
                draws.append((TranslatedDraw(queue: renderQueue, item: firstItem + min(slot, count - 1), slot: slot, mesh: (mesh["name"] as? String) ?? name, family: name,
                    passes: FileManager.default.fileExists(atPath: outline.path) ? [("outline", outline), ("forward", forward)] : [("forward", forward)]), order))
            }
        }
        return draws.sorted { $0.draw.queue == $1.draw.queue ? $0.order < $1.order : $0.draw.queue < $1.draw.queue }.map(\.draw)
    }

    private func encodeTranslatedShader(frameURL: URL, programURL: URL, resources: ResourceStore, color: any MTLTexture, depth: any MTLTexture, command: any MTLCommandBuffer, clear: Bool, selected: (item: Int, slot: Int)?, sourceBackground: Bool, depth24Quantized: Bool = false) throws {
        typealias Row = [String: Any]
        func object(_ url: URL) throws -> Row { guard let row = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? Row else { throw ProbeError.invalid("Shader descriptor") }; return row }
        func floats(_ value: Any?) throws -> [Float] { guard let a = value as? [NSNumber], a.allSatisfy({ $0.floatValue.isFinite }) else { throw ProbeError.invalid("Invalid shader vector") }; return a.map(\.floatValue) }
        let original = try object(frameURL)
        guard let sourceMeshes = original["meshes"] as? [Row],
              let globals = original["globals"] as? Row, let sourceCamera = original["camera"] as? Row,
              let light = original["light"] as? Row, let textureRows = original["textures"] as? [Row] else { throw ProbeError.invalid("Incomplete shader capture descriptor") }
        // Shared with the live path: the program is parsed (and its MSL hash
        // verified) once, and its pipeline is compiled once per target. The
        // original capture ran under a Direct3D 11 player whose depth buffer
        // was 24-bit; Apple GPUs expose no depth24+stencil format
        // (isDepth24Stencil8PixelFormatSupported is false on Apple silicon), so
        // the opt-in emulation re-emits the rasterized depth quantized to
        // 24-bit fixed point from the fragment (`TranslatedSourceDepth24`).
        let program = try resources.translatedPipelines.program(url: programURL)
        let entry = try resources.translatedPipelines.entry(program, target: .probe, depth24Quantized: depth24Quantized)
        let shaderName = program.name
        let texturesByFile = Dictionary(uniqueKeysWithValues: try textureRows.map { t -> (String, Row) in guard let n = t["file"] as? String else { throw ProbeError.invalid("Texture name") }; return (n, t) })
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
        TranslatedSourcePipelineCache.apply(entry, to: encoder)
        let folder = frameURL.deletingLastPathComponent()
        var retainedBuffers: [any MTLBuffer] = [], retainedTextures: [any MTLTexture] = [], retainedSamplers: [any MTLSamplerState] = []
        func file(_ name: String) throws -> URL { guard name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else { throw ProbeError.invalid("Source texture path") }; return folder.appendingPathComponent(name) }
        let linear = TranslatedSourceProgram.linear
        func defaultValue(_ name: String) throws -> [Float] {
            guard let property = program.properties[name] else { throw ProbeError.invalid("Unknown source shader constant \(name)") }
            return property.defaultValue
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
            if program.properties[key]?.type == 0 { for i in 0..<min(3, value.count) { value[i] = linear(value[i]) } }
            return value
        }
        func matrix(_ key: String) throws -> float4x4 {
            switch key {
            case "unity_ObjectToWorld": return objectToWorld
            case "unity_WorldToObject": return objectToWorld.inverse
            case "unity_MatrixV": return frame.camera.viewMatrix() * UnityCoordinates.basis
            case "glstate_matrix_projection", "unity_CameraProjection": return frame.camera.projectionMatrix(aspect: Float(width) / Float(height))
            case "unity_MatrixVP": return frame.camera.projectionMatrix(aspect: Float(width) / Float(height)) * frame.camera.viewMatrix() * UnityCoordinates.basis
            default: throw ProbeError.invalid("Unknown source shader matrix \(key)")
            }
        }
        func stage(_ stage: TranslatedSourceProgram.Stage, vertexStage: Bool, material: Row) throws {
            for buffer in try TranslatedSourceProgram.pack(stage, uniform: { try uniform($0, material: material) }, matrix: matrix) {
                guard let gpu = resources.device.makeBuffer(bytes: buffer.data, length: buffer.data.count * 4) else { throw ProbeError.gpu("Source constants") }; retainedBuffers.append(gpu)
                if vertexStage { encoder.setVertexBuffer(gpu, offset: 0, index: buffer.slot + 8) } else { encoder.setFragmentBuffer(gpu, offset: 0, index: buffer.slot + 8) }
            }
            for texture in stage.textures {
                let key = texture.name
                let gpuTexture: any MTLTexture; var row: Row = [:]
                let filename = (material[key] as? Row)?["file"] as? String ?? globals[key] as? String
                if let filename {
                    let handle = try loadOriginalProbeTexture(url: file(filename), metadata: texturesByFile[filename] ?? [:], resources: resources)
                    guard let loaded = resources.texture(handle) else { throw ProbeError.gpu("Source texture") }; gpuTexture = loaded; row = texturesByFile[filename] ?? [:]
                } else {
                    guard let kind = program.properties[key]?.defaultTexture else { throw ProbeError.invalid("Missing original texture \(key)") }
                    gpuTexture = try TranslatedSourceProgram.makeDefaultTexture(kind, device: resources.device)
                }
                let sampler = TranslatedSourceProgram.samplerDescriptor(filter: row["filter"] as? String, wrap: row["wrap"] as? String, aniso: row["aniso"] as? Int,
                                                                         anisotropicFiltering: original["anisotropicFiltering"] as? String)
                guard let gpuSampler = resources.device.makeSamplerState(descriptor: sampler) else { throw ProbeError.gpu("Source sampler") }
                retainedTextures.append(gpuTexture); retainedSamplers.append(gpuSampler)
                if vertexStage { encoder.setVertexTexture(gpuTexture, index: texture.slot); encoder.setVertexSamplerState(gpuSampler, index: texture.samplerSlot) } else { encoder.setFragmentTexture(gpuTexture, index: texture.slot); encoder.setFragmentSamplerState(gpuSampler, index: texture.samplerSlot) }
            }
        }
        var firstItem = 0, draws = 0
        for sourceMesh in sourceMeshes {
            guard let materials = sourceMesh["materials"] as? [Row], let submeshes = sourceMesh["submeshes"] as? Int, submeshes > 0 else { throw ProbeError.invalid("Source mesh metadata") }
            guard submeshes <= materials.count else { throw ProbeError.invalid("Source material index") }
            defer { firstItem += submeshes }
            // Unity draws a material slot beyond the submesh count over the
            // last submesh, with that slot's material.
            for (slot, material) in materials.enumerated() {
                let itemIndex = firstItem + min(slot, submeshes - 1)
                guard itemIndex < frame.items.count else { throw ProbeError.invalid("Source material index") }
                if material["shader"] as? String != shaderName { continue }
                if let selected, selected.item != itemIndex || selected.slot != slot { continue }
                let transform = try floats(sourceMesh["rendererMatrix"])
                guard transform.count == 16 else { throw ProbeError.invalid("Source object transform") }
                objectToWorld = float4x4(columns: (Float4(transform[0], transform[1], transform[2], transform[3]), Float4(transform[4], transform[5], transform[6], transform[7]), Float4(transform[8], transform[9], transform[10], transform[11]), Float4(transform[12], transform[13], transform[14], transform[15])))
                guard abs(simd_determinant(objectToWorld)) > 1e-8 else { throw ProbeError.invalid("Singular source object transform") }
                let worldToObject = objectToWorld.inverse
                guard let values = material["properties"] as? Row, let mesh = resources.mesh(frame.items[itemIndex].mesh) else { throw ProbeError.invalid("Source vertex inputs") }
                var uv3: [Float2] = []
                if let uv3File = sourceMesh["uv3File"] as? String {
                    let bytes = try Data(contentsOf: file(uv3File)); guard bytes.count == mesh.vertexCount * 8 else { throw ProbeError.invalid("Source UV3 dimensions") }
                    uv3 = bytes.withUnsafeBytes { raw in (0..<mesh.vertexCount).map { Float2(raw.loadUnaligned(fromByteOffset: $0 * 8, as: Float.self), raw.loadUnaligned(fromByteOffset: $0 * 8 + 4, as: Float.self)) } }
                }
                // Source NORMAL: a hashed renderer-local sidecar when the capture
                // carries one; otherwise (old captures) the legacy transpose of the
                // normalized world normal below, which loses skinned magnitude.
                let sourceNormals = try Self.sourceVertexNormals(sourceMesh["sourceVertexNormals"], vertexCount: mesh.vertexCount, geometryFile: sourceMesh["file"], directory: folder)
                var input: [Float4] = []
                let vertices = mesh.baseVertices.contents().bindMemory(to: DeformedVertex.self, capacity: mesh.vertexCount)
                for vertex in 0..<mesh.vertexCount {
                    for register in program.vertexInputs {
                        switch register.semantic {
                        case "POSITION": let p = vertices[vertex].position; input.append(worldToObject * Float4(p.x, p.y, -p.z, 1))
                        case "NORMAL":
                            if let sourceNormals { input.append(Float4(sourceNormals[vertex], 0)) }
                            else { let n = vertices[vertex].normal; input.append(objectToWorld.transpose * Float4(n.x, n.y, -n.z, 0)) }
                        case "TANGENT": let tangent = UnityCoordinates.tangent(vertices[vertex].tangent); let transformed = worldToObject * Float4(tangent.x, tangent.y, tangent.z, 0); input.append(Float4(simd_normalize(Float3(transformed.x, transformed.y, transformed.z)), tangent.w))
                        case "TEXCOORD":
                            let set = register.index
                            if set == 3 { guard uv3.count == mesh.vertexCount else { throw ProbeError.invalid("Missing source UV3") }; input.append(Float4(uv3[vertex].x, uv3[vertex].y, 0, 0)) }
                            else { let buffer = set == 0 ? mesh.texcoords : set == 1 ? mesh.texcoords1 : mesh.texcoords2; let uv = buffer.contents().bindMemory(to: Float2.self, capacity: mesh.vertexCount)[vertex]; input.append(Float4(uv.x, 1 - uv.y, 0, 0)) }
                        case "COLOR": if let color = mesh.colors { let c = color.contents().bindMemory(to: SIMD4<UInt8>.self, capacity: mesh.vertexCount)[vertex]; input.append(Float4(c) / 255) } else { input.append(Float4(repeating: 1)) }
                        default: throw ProbeError.invalid("Unsupported source vertex semantic")
                        }
                    }
                }
                guard let buffer = resources.device.makeBuffer(bytes: input, length: input.count * 16) else { throw ProbeError.gpu("Source vertex input") }; retainedBuffers.append(buffer)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0); try stage(program.vertex, vertexStage: true, material: values); try stage(program.fragment, vertexStage: false, material: values)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0); draws += 1
            }
        }
        guard draws > 0 else { throw ProbeError.invalid("No source materials match the translated shader") }
        encoder.endEncoding(); endedEncoding = true
        withExtendedLifetime((retainedBuffers, retainedTextures, retainedSamplers)) {}

    }
}
