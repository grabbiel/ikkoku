import Foundation
import CryptoKit
import Metal
import simd
import CoreMath

/// One translated original shader pass (DXBC→MSL): the `program.json`
/// descriptor `Tools/reverse/source_shader_translation.py` writes next to the
/// derived `source.metal`, parsed and validated once. Both the frozen-frame
/// probe (`TranslatedSourceShaderProbe`) and the opt-in live path
/// (`SourceShaderLiveRenderer`) bind and draw through this type, so the two
/// cannot drift apart.
///
/// Only the pass states the original programs use are accepted: reverse-Z
/// `LEqual` (`GreaterEqual` here), the four blend factors `Zero`/`One`/
/// `SrcAlpha`/`OneMinusSrcAlpha` with `Add`, `Always`/`NotEqual` stencil with
/// `Keep`/`Replace`, no depth offset. Anything else throws, so a caller can
/// fall back instead of drawing a different state.
public final class TranslatedSourceProgram: @unchecked Sendable {
    public enum ProgramError: Error, CustomStringConvertible, Equatable {
        case invalid(String)
        public var description: String { switch self { case .invalid(let message): message } }
    }

    /// A matrix parameter: float offset of its first column in the buffer.
    public struct Matrix: Sendable, Equatable { public let name: String; public let offset: Int }
    /// A vector parameter: float offset and the lanes the program reads (`m_Dim`).
    public struct Vector: Sendable, Equatable { public let name: String; public let offset: Int; public let dimension: Int }
    /// One constant buffer, bound at `slot + 8` (translated register `cb<slot>`).
    public struct ConstantBuffer: Sendable, Equatable {
        public let slot: Int, size: Int
        public let matrices: [Matrix], vectors: [Vector]
    }
    public struct TextureParameter: Sendable, Equatable { public let name: String; public let slot: Int; public let samplerSlot: Int }
    public struct Stage: Sendable, Equatable { public let constantBuffers: [ConstantBuffer]; public let textures: [TextureParameter] }
    /// A vertex input register in `SourceInput` order (one float4 per register,
    /// ascending register number). `index` is the semantic index (`TEXCOORD3`).
    public struct VertexInput: Sendable, Equatable { public let register: Int; public let semantic: String; public let index: Int }
    public struct Property: Sendable, Equatable {
        public let type: Int
        public let defaultValue: [Float]
        public let defaultTexture: String?
    }
    public struct PassState: Sendable, Equatable {
        public let zWrite: Bool
        /// Unity `CullMode`: 0 off, 1 front, 2 back.
        public let culling: Int
        public let sourceRGB: MTLBlendFactor, destinationRGB: MTLBlendFactor
        public let sourceAlpha: MTLBlendFactor, destinationAlpha: MTLBlendFactor
        public let stencilCompare: MTLCompareFunction, stencilPass: MTLStencilOperation
        public let stencilReadMask: UInt32, stencilWriteMask: UInt32, stencilReference: UInt32
        public var cullMode: MTLCullMode { culling == 0 ? .none : culling == 1 ? .front : .back }
    }

    public let url: URL
    /// Original shader name (`Shader Forge/main_hair`).
    public let name: String
    /// Original pass name (`passState.m_Name`), e.g. `OUTLINE`, `FORWARD`.
    public let pass: String
    public let sourceSHA256: String
    public let source: String
    public let vertex: Stage
    public let fragment: Stage
    public let vertexInputs: [VertexInput]
    public let state: PassState
    public let properties: [String: Property]

    /// Parses and validates `program.json` and the hash of its `source.metal`.
    public init(url: URL) throws {
        typealias Row = [String: Any]
        func invalid(_ message: String) -> ProgramError { .invalid("\(url.deletingLastPathComponent().lastPathComponent): \(message)") }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? Row else { throw invalid("Shader descriptor") }
        func integer(_ value: Any?) throws -> Int { guard let n = value as? NSNumber else { throw invalid("Missing integer shader binding") }; return n.intValue }
        guard let name = root["name"] as? String, let stages = root["programs"] as? [String: Row],
              let names = root["names"] as? [String: String], let properties = root["properties"] as? [Row],
              let state = root["passState"] as? Row else { throw invalid("Incomplete shader descriptor") }
        let sourceData = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("source.metal"))
        let digest = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        guard root["sourceMSLSHA256"] as? String == digest, let source = String(data: sourceData, encoding: .utf8) else { throw invalid("Translated shader identity changed") }
        func nameOf(_ index: Any?) throws -> String { guard let result = names[String(try integer(index))] else { throw invalid("Unknown uniform name") }; return result }

        var byName: [String: Property] = [:]
        for property in properties {
            guard let key = property["m_Name"] as? String else { throw invalid("Property name") }
            guard byName[key] == nil else { throw invalid("Duplicate property \(key)") }
            byName[key] = Property(type: (property["m_Type"] as? NSNumber)?.intValue ?? -1,
                                   defaultValue: (0..<4).map { (property["m_DefValue[\($0)]"] as? NSNumber)?.floatValue ?? 0 },
                                   defaultTexture: (property["m_DefTexture"] as? Row)?["m_DefaultName"] as? String)
        }

        func stage(_ key: String) throws -> Stage {
            guard let description = stages[key], let metadata = description["metadata"] as? Row,
                  let buffers = metadata["m_ConstantBuffers"] as? [Row], let bindings = metadata["m_ConstantBufferBindings"] as? [Row],
                  let textures = metadata["m_TextureParams"] as? [Row] else { throw invalid("Shader stage metadata") }
            var result: [ConstantBuffer] = []
            for buffer in buffers {
                let bufferName = try integer(buffer["m_NameIndex"])
                guard let binding = bindings.first(where: { ($0["m_NameIndex"] as? NSNumber)?.intValue == bufferName }) else { throw invalid("Unbound source constant buffer") }
                let slot = try integer(binding["m_Index"]), size = try integer(buffer["m_Size"])
                guard (1...65536).contains(size), size % 4 == 0, (0..<16).contains(slot) else { throw invalid("Source buffer size/index") }
                let floats = size / 4
                let matrices = try (buffer["m_MatrixParams"] as? [Row] ?? []).map { parameter -> Matrix in
                    let matrix = Matrix(name: try nameOf(parameter["m_NameIndex"]), offset: try integer(parameter["m_Index"]) / 4)
                    guard matrix.offset >= 0, matrix.offset + 16 <= floats else { throw invalid("Source matrix range") }
                    return matrix
                }
                let vectors = try (buffer["m_VectorParams"] as? [Row] ?? []).map { parameter -> Vector in
                    let vector = Vector(name: try nameOf(parameter["m_NameIndex"]), offset: try integer(parameter["m_Index"]) / 4,
                                        dimension: try integer(parameter["m_Dim"]))
                    guard (1...4).contains(vector.dimension), vector.offset >= 0, vector.offset + vector.dimension <= floats else { throw invalid("Source vector range \(vector.name)") }
                    return vector
                }
                result.append(ConstantBuffer(slot: slot, size: size, matrices: matrices, vectors: vectors))
            }
            let parameters = try textures.map { texture in
                TextureParameter(name: try nameOf(texture["m_NameIndex"]), slot: try integer(texture["m_Index"]), samplerSlot: try integer(texture["m_SamplerIndex"]))
            }
            return Stage(constantBuffers: result, textures: parameters)
        }

        guard let semantics = stages["vertex"]?["inputSemantics"] as? [String: Row] else { throw invalid("Source vertex inputs") }
        let inputs = try semantics.map { key, semantic -> VertexInput in
            guard let register = Int(key) else { throw invalid("Vertex register") }
            guard let semanticName = semantic["name"] as? String else { throw invalid("Unsupported source vertex semantic") }
            let index = semanticName == "TEXCOORD" ? try integer(semantic["index"]) : ((semantic["index"] as? NSNumber)?.intValue ?? 0)
            switch semanticName {
            case "POSITION", "NORMAL", "TANGENT", "COLOR": break
            case "TEXCOORD": guard (0...3).contains(index) else { throw invalid("Unsupported source UV set") }
            default: throw invalid("Unsupported source vertex semantic")
            }
            return VertexInput(register: register, semantic: semanticName, index: index)
        }.sorted { $0.register < $1.register }

        func stateValue(_ key: String, in row: Row? = nil) throws -> Int { guard let v = (row ?? state)[key] as? Row else { throw invalid("Pass state \(key)") }; return try integer(v["val"]) }
        guard try stateValue("zTest") == 4, [0, 1].contains(try stateValue("zWrite")),
              let stencil = state["stencilOp"] as? Row, let blend = state["rtBlend0"] as? Row,
              try stateValue("blendOp", in: blend) == 0, try stateValue("blendOpAlpha", in: blend) == 0,
              try stateValue("offsetFactor") == 0, try stateValue("offsetUnits") == 0 else { throw invalid("Unimplemented source render-pass state") }
        func factor(_ key: String) throws -> MTLBlendFactor {
            switch try stateValue(key, in: blend) { case 0: return .zero; case 1: return .one; case 5: return .sourceAlpha; case 10: return .oneMinusSourceAlpha; default: throw invalid("Unsupported source blend factor") }
        }
        let compare: MTLCompareFunction, operation: MTLStencilOperation
        switch try stateValue("comp", in: stencil) { case 8: compare = .always; case 6: compare = .notEqual; default: throw invalid("Unsupported source stencil comparison") }
        switch try stateValue("pass", in: stencil) { case 0: operation = .keep; case 2: operation = .replace; default: throw invalid("Unsupported source stencil operation") }
        guard try stateValue("fail", in: stencil) == 0, try stateValue("zFail", in: stencil) == 0 else { throw invalid("Unsupported source stencil failure") }
        let readMask = try stateValue("stencilReadMask"), writeMask = try stateValue("stencilWriteMask"), reference = try stateValue("stencilRef")
        guard (0...255).contains(readMask), (0...255).contains(writeMask), (0...255).contains(reference) else { throw invalid("Source stencil mask") }
        let culling = try stateValue("culling"); guard (0...2).contains(culling) else { throw invalid("Source culling state") }

        self.url = url; self.name = name; self.pass = (state["m_Name"] as? String) ?? ""
        self.sourceSHA256 = digest; self.source = source
        self.vertex = try stage("vertex"); self.fragment = try stage("fragment")
        self.vertexInputs = inputs; self.properties = byName
        self.state = PassState(zWrite: try stateValue("zWrite") == 1, culling: culling,
            sourceRGB: try factor("srcBlend"), destinationRGB: try factor("destBlend"),
            sourceAlpha: try factor("srcBlendAlpha"), destinationAlpha: try factor("destBlendAlpha"),
            stencilCompare: compare, stencilPass: operation,
            stencilReadMask: UInt32(readMask), stencilWriteMask: UInt32(writeMask), stencilReference: UInt32(reference))
    }

    /// The stage's input names the draw must supply (matrices excluded),
    /// for fallback decisions before anything is encoded.
    public var vectorNames: Set<String> { Set((vertex.constantBuffers + fragment.constantBuffers).flatMap { $0.vectors.map(\.name) }) }
    public var matrixNames: Set<String> { Set((vertex.constantBuffers + fragment.constantBuffers).flatMap { $0.matrices.map(\.name) }) }
    public var textureNames: Set<String> { Set((vertex.textures + fragment.textures).map(\.name)) }

    /// Packs one stage's constant buffers the way the probe always has: zeroed
    /// `m_Size` bytes, matrices column-major at their offsets, then each vector's
    /// first `m_Dim` lanes. `uniform` supplies vectors and `matrix` matrices by
    /// uniform name.
    public static func pack(_ stage: Stage, uniform: (String) throws -> [Float], matrix: (String) throws -> float4x4) throws -> [(slot: Int, data: [Float])] {
        try stage.constantBuffers.map { buffer in
            var data = [Float](repeating: 0, count: buffer.size / 4)
            for parameter in buffer.matrices {
                let value = try matrix(parameter.name)
                for column in 0..<4 { for row in 0..<4 { data[parameter.offset + column * 4 + row] = value[column][row] } }
            }
            for parameter in buffer.vectors {
                let value = try uniform(parameter.name)
                guard value.count >= parameter.dimension else { throw ProgramError.invalid("Source vector range \(parameter.name)") }
                for lane in 0..<parameter.dimension { data[parameter.offset + lane] = value[lane] }
            }
            return (buffer.slot, data)
        }
    }

    /// The probe's sampler rule for an original `Texture2D`/render target:
    /// Unity filter/wrap/aniso, the player's `QualitySettings.anisotropicFiltering`
    /// (`ForceEnable` raises aniso textures to at least 9) and D3D11's trilinear
    /// mip filtering whenever anisotropy is above 1.
    public static func samplerDescriptor(filter: String?, wrap: String?, aniso: Int?, anisotropicFiltering: String?) -> MTLSamplerDescriptor {
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = filter == "Point" ? .nearest : .linear; sampler.magFilter = sampler.minFilter; sampler.mipFilter = filter == "Trilinear" ? .linear : .nearest
        sampler.sAddressMode = wrap == "Clamp" ? .clampToEdge : .repeat; sampler.tAddressMode = sampler.sAddressMode; sampler.maxAnisotropy = max(1, min(16, aniso ?? 1))
        if anisotropicFiltering == "Disable" { sampler.maxAnisotropy = 1 }
        else if anisotropicFiltering == "ForceEnable", (aniso ?? 0) > 0, filter != "Point" { sampler.maxAnisotropy = max(9, sampler.maxAnisotropy) }
        if sampler.maxAnisotropy > 1 { sampler.mipFilter = .linear }
        return sampler
    }

    /// Unity's built-in default texture for an unbound property (`white`,
    /// `black`, `gray`, `bump`) as a 1×1 float texel.
    public static func defaultTexel(_ kind: String) -> Float4? {
        switch kind {
        case "white": return Float4(repeating: 1)
        case "black": return Float4(repeating: 0)
        case "gray": return Float4(repeating: 0.5)
        case "bump": return Float4(0.5, 0.5, 1, 0.5)
        default: return nil
        }
    }

    public static func makeDefaultTexture(_ kind: String, device: any MTLDevice) throws -> any MTLTexture {
        guard var value = defaultTexel(kind) else { throw ProgramError.invalid("Unknown Unity fallback texture \(kind)") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false); descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw ProgramError.invalid("Source fallback") }
        withUnsafeBytes(of: &value) { texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
        return texture
    }

    /// sRGB → linear for colour properties (`m_Type` 0), as the probe binds them.
    public static func linear(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
}

/// Render-target configuration a translated pipeline is compiled for.
public struct TranslatedSourceTarget: Hashable, Sendable {
    public var color: MTLPixelFormat
    public var depthStencil: MTLPixelFormat
    public var sampleCount: Int
    public init(color: MTLPixelFormat, depthStencil: MTLPixelFormat, sampleCount: Int) {
        self.color = color; self.depthStencil = depthStencil; self.sampleCount = sampleCount
    }
    /// The frozen-frame probe's target: 8-bit sRGB, depth+stencil, no MSAA.
    public static let probe = TranslatedSourceTarget(color: .rgba8Unorm_srgb, depthStencil: .depth32Float_stencil8, sampleCount: 1)
}

/// Programs and pipeline states, each built once per program and target
/// (and per 24-bit depth emulation). Thread-safe.
public final class TranslatedSourcePipelineCache: @unchecked Sendable {
    public struct Entry {
        public let program: TranslatedSourceProgram
        public let pipeline: any MTLRenderPipelineState
        public let depthState: any MTLDepthStencilState
    }
    private struct Key: Hashable { let program: String; let target: TranslatedSourceTarget; let depth24: Bool }

    public let device: any MTLDevice
    private let lock = NSLock()
    private var programs: [String: TranslatedSourceProgram] = [:]
    private var entries: [Key: Entry] = [:]
    /// Number of pipelines compiled so far (cache misses).
    public private(set) var compiledPipelines = 0
    public private(set) var parsedPrograms = 0

    public init(device: any MTLDevice) { self.device = device }

    /// The parsed program for `url`; parsed (and hash-checked) once.
    public func program(url: URL) throws -> TranslatedSourceProgram {
        let key = url.standardizedFileURL.path
        lock.lock(); if let cached = programs[key] { lock.unlock(); return cached }; lock.unlock()
        let program = try TranslatedSourceProgram(url: url)
        lock.lock(); defer { lock.unlock() }
        if let cached = programs[key] { return cached }
        programs[key] = program; parsedPrograms += 1
        return program
    }

    /// Pipeline and depth/stencil state for `program` on `target`. With
    /// `depth24Quantized` the fragment re-emits depth snapped to 24-bit fixed
    /// point (`TranslatedSourceDepth24.rewrite`).
    public func entry(_ program: TranslatedSourceProgram, target: TranslatedSourceTarget, depth24Quantized: Bool = false) throws -> Entry {
        let key = Key(program: program.url.standardizedFileURL.path + "#" + program.sourceSHA256, target: target, depth24: depth24Quantized)
        lock.lock(); if let cached = entries[key] { lock.unlock(); return cached }; lock.unlock()
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let library = try device.makeLibrary(source: depth24Quantized ? try TranslatedSourceDepth24.rewrite(program.source) : program.source, options: options)
        let descriptor = MTLRenderPipelineDescriptor(); descriptor.vertexFunction = library.makeFunction(name: "source_vertex"); descriptor.fragmentFunction = library.makeFunction(name: "source_fragment")
        descriptor.rasterSampleCount = target.sampleCount
        descriptor.colorAttachments[0].pixelFormat = target.color; descriptor.depthAttachmentPixelFormat = target.depthStencil; descriptor.stencilAttachmentPixelFormat = target.depthStencil
        let state = program.state
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = state.sourceRGB; descriptor.colorAttachments[0].sourceAlphaBlendFactor = state.sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = state.destinationRGB; descriptor.colorAttachments[0].destinationAlphaBlendFactor = state.destinationAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depthDescriptor = MTLDepthStencilDescriptor(); depthDescriptor.depthCompareFunction = .greaterEqual; depthDescriptor.isDepthWriteEnabled = state.zWrite
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = state.stencilCompare; stencil.depthStencilPassOperation = state.stencilPass
        stencil.readMask = state.stencilReadMask; stencil.writeMask = state.stencilWriteMask
        depthDescriptor.frontFaceStencil = stencil; depthDescriptor.backFaceStencil = stencil
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw TranslatedSourceProgram.ProgramError.invalid("Source depth state") }
        let entry = Entry(program: program, pipeline: pipeline, depthState: depthState)
        lock.lock(); defer { lock.unlock() }
        if let cached = entries[key] { return cached }
        entries[key] = entry; compiledPipelines += 1
        return entry
    }

    /// Sets the entry's pipeline, depth/stencil state, stencil reference,
    /// winding and cull mode on `encoder`.
    public static func apply(_ entry: Entry, to encoder: any MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(entry.pipeline); encoder.setDepthStencilState(entry.depthState)
        encoder.setFrontFacing(.counterClockwise); encoder.setStencilReferenceValue(entry.program.state.stencilReference)
        encoder.setCullMode(entry.program.state.cullMode)
    }
}

/// Opt-in 24-bit depth emulation for the probe's translated programs.
public enum TranslatedSourceDepth24 {
    /// Parameter text between an entry point's opening parenthesis and the
    /// matching close, because attribute spellings such as `[[buffer(8)]]`
    /// contain nested parentheses.
    private static func fragmentParameters(_ source: String, from open: String.Index) -> String? {
        var depth = 0, index = open
        while index < source.endIndex {
            switch source[index] {
            case "(": depth += 1
            case ")": if depth == 0 { return String(source[open..<index]) }; depth -= 1
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Rewrite a verified translated program so its fragment output also emits
    /// depth snapped to a 24-bit fixed-point grid, emulating the 24-bit depth
    /// buffer of the Direct3D 11 device that produced the original capture.
    /// MSL forbids calling an entry point that takes a `[[stage_in]]`
    /// parameter, so the rewrite is in place: the fragment input struct gains
    /// the vertex output's `[[position]]` (MSL links stage-in members by
    /// attribute), the entry point returns a color+depth struct, and its
    /// single `return` becomes the quantization — clamp to [0,1], scale by
    /// 2^24−1, round half up to the integer grid. `[[depth(any)]]` under the
    /// probe pipeline's `.greaterEqual` keeps the GreaterEqual tie-pass rule
    /// the captured passes used. The translated body's color output and
    /// `discard_fragment()` paths are untouched. This models depth
    /// *precision* only — not the original driver's sample positions.
    public static func rewrite(_ source: String) throws -> String {
        typealias ProbeError = OriginalFrameProbe.ProbeError
        guard let signature = source.range(of: "fragment float4 source_fragment("),
              let inputStruct = source.range(of: "struct SourceFragmentInput {"),
              let inputEnd = source.range(of: "};", range: inputStruct.upperBound..<source.endIndex),
              let parameters = fragmentParameters(source, from: signature.upperBound),
              let bodyStart = source.range(of: "{", range: source.index(signature.upperBound, offsetBy: parameters.count)..<source.endIndex) else { throw ProbeError.invalid("Translated fragment shape") }
        var depth = 0, bodyEnd = bodyStart.lowerBound
        while bodyEnd < source.endIndex {
            switch source[bodyEnd] {
            case "{": depth += 1
            case "}": depth -= 1; if depth == 0 { break }
            default: break
            }
            if depth == 0 { break }
            bodyEnd = source.index(after: bodyEnd)
        }
        guard depth == 0, bodyEnd < source.endIndex else { throw ProbeError.invalid("Translated fragment body") }
        let body = bodyStart.upperBound..<bodyEnd
        guard source.range(of: "return ", range: body) == source.range(of: "return ", options: .backwards, range: body),
              let returnEnd = source.range(of: ";", range: source.range(of: "return ", range: body)!.upperBound..<body.upperBound) else { throw ProbeError.invalid("Translated fragment return shape") }
        let colorExpression = String(source[source.range(of: "return ", range: body)!.upperBound..<returnEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !colorExpression.isEmpty, !colorExpression.contains(";") else { throw ProbeError.invalid("Translated fragment return expression") }
        let stageIn = parameters.split(separator: ",").first { $0.contains("[[stage_in]]") }
        guard let positionInput = stageIn?.split(separator: " ").dropLast().last.map(String.init), !positionInput.isEmpty else { throw ProbeError.invalid("Translated fragment position") }
        let returnRange = source.range(of: "return ", range: body)!.lowerBound..<returnEnd.upperBound
        let replacements: [(Range<String.Index>, String)] = [
            (signature, "fragment IkkokuDepth24Output source_fragment("),
            (inputStruct, "struct SourceFragmentInput { float4 ikkoku_position [[position]];"),
            (inputEnd, "};\nstruct IkkokuDepth24Output { float4 ikkoku_color [[color(0)]]; float ikkoku_depth [[depth(any)]]; };"),
            (returnRange, """
            { IkkokuDepth24Output ikkoku_out;
                          ikkoku_out.ikkoku_color = \(colorExpression);
                          float ikkoku_z = clamp(\(positionInput).ikkoku_position.z, 0.0f, 1.0f);
                          float ikkoku_scaled = ikkoku_z * 16777215.0f;
                          float ikkoku_base = floor(ikkoku_scaled);
                          ikkoku_out.ikkoku_depth = (ikkoku_scaled - ikkoku_base >= 0.5f ? ikkoku_base + 1.0f : ikkoku_base) / 16777215.0f;
                          return ikkoku_out; }
            """),
        ]
        var result = source
        for (range, replacement) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { result.replaceSubrange(range, with: replacement) }
        return result
    }
}
