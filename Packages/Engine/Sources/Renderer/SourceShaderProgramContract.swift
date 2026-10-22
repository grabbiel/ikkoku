import Foundation

/// Input contract of one translated original program pair: the `program.json`
/// descriptor that `Tools/reverse/source_shader_translation.py` writes next to
/// the derived MSL. It lists exactly the constant-buffer vectors and textures
/// that `TranslatedSourceShaderProbe.encodeTranslatedShader` binds per draw
/// (its `stage`/`uniform`/`defaultValue` functions), classified by where the
/// probe takes each value from. Matrices (`m_MatrixParams`) are always computed
/// from the frozen renderer transform and camera, so they are not listed.
///
/// Classification is source-backed rather than name-guessed: Unity only fills
/// a constant from a material when the shader's `Properties` block declares it
/// (or, for `<texture>_ST`, declares that texture); every other non-builtin
/// uniform is a `Shader.SetGlobal*` value (for example `_ambientshadowG`,
/// `_LineColorG`, `_RampG`, which `ChaShader` sets).
public struct SourceShaderProgramContract: Sendable, Equatable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// Camera, light and screen values the probe computes from the frozen scene.
        case builtin
        /// Declared non-texture property: the material value, else the property default.
        case materialVector
        /// `<texture>_ST` of a declared texture property: the material's texture scale/offset.
        case materialTextureTransform
        /// Declared texture property: the material's texture, else the Unity default texture.
        case materialTexture
        /// Undeclared vector uniform: a global shader value (including the
        /// `_Time` clock, which the probe takes from the capture's globals).
        case globalVector
        /// Undeclared texture: a global shader texture.
        case globalTexture
    }

    public struct Input: Sendable, Equatable, Codable {
        public let name: String
        public let isTexture: Bool
        /// Lanes the program reads (1–4) for vectors; 0 for textures.
        public let dimension: Int
        public let source: Source
        /// Stages that read the input, in `vertex`, `fragment` order.
        public let stages: [String]
    }

    /// One declared shader property (`m_Type` 0 colour, 1 vector, 2 float,
    /// 3 range, 4 texture). The probe linearizes colour properties at bind time.
    public struct Property: Sendable, Equatable, Codable {
        public let name: String
        public let type: Int
        public let defaultValue: [Float]
        /// Unity default texture kind (`white`, `black`, `gray`, `bump`) for textures.
        public let defaultTexture: String?
        public var isColor: Bool { type == 0 }
        public var isTexture: Bool { type == 4 }
    }

    /// Uniforms the probe computes from the frozen camera, light and viewport
    /// instead of the material or the global table (`uniform`'s first branches).
    public static let builtinNames: Set<String> = [
        "_ScreenParams", "_ProjectionParams", "unity_WorldTransformParams",
        "_WorldSpaceCameraPos", "_WorldSpaceLightPos0", "_LightColor0",
    ]

    /// Original shader name, for example `Shader Forge/main_hair`.
    public let shader: String
    /// Serialized pass name (`FORWARD` or `OUTLINE`).
    public let pass: String
    /// Translated program directory name (`main_hair`, `main_hair_outline`).
    public let program: String
    public let inputs: [Input]
    public let properties: [String: Property]
    /// Constant pass state as serialized (`zTest`, `zWrite`, `culling`,
    /// `srcBlend`…, `stencilRef`, `stencilComp`…). Values whose `name` is not
    /// `<noninit>` would be material-driven; the probe rejects those.
    public let passState: [String: Int]
    /// Pass-state entries driven by a material property (empty for every
    /// observed program).
    public let propertyDrivenPassState: [String: String]
    /// Union of both stages' compiled keyword variant (for example `DIRECTIONAL`).
    public let keywords: [String]

    public enum ContractError: Error, CustomStringConvertible, Equatable {
        case invalid(String)
        public var description: String { switch self { case .invalid(let message): message } }
    }

    public static func load(url: URL, program: String? = nil) throws -> Self {
        try decode(Data(contentsOf: url), program: program ?? url.deletingLastPathComponent().lastPathComponent)
    }

    public static func decode(_ data: Data, program: String) throws -> Self {
        typealias Row = [String: Any]
        guard let root = try JSONSerialization.jsonObject(with: data) as? Row,
              let shader = root["name"] as? String, !shader.isEmpty,
              let stages = root["programs"] as? [String: Row],
              let names = root["names"] as? [String: String],
              let propertyRows = root["properties"] as? [Row],
              let state = root["passState"] as? Row,
              let pass = state["m_Name"] as? String else { throw ContractError.invalid("Incomplete translated program descriptor") }
        func integer(_ value: Any?) throws -> Int {
            guard let number = value as? NSNumber else { throw ContractError.invalid("Missing integer in \(program)") }
            return number.intValue
        }
        var properties: [String: Property] = [:]
        for row in propertyRows {
            guard let name = row["m_Name"] as? String, !name.isEmpty else { throw ContractError.invalid("Unnamed property in \(program)") }
            let type = try integer(row["m_Type"])
            guard (0...4).contains(type) else { throw ContractError.invalid("Unknown property type \(type) for \(name)") }
            let defaults = (0..<4).map { (row["m_DefValue[\($0)]"] as? NSNumber)?.floatValue ?? 0 }
            let texture = (row["m_DefTexture"] as? Row)?["m_DefaultName"] as? String
            guard properties.updateValue(Property(name: name, type: type, defaultValue: defaults, defaultTexture: type == 4 ? texture : nil), forKey: name) == nil else {
                throw ContractError.invalid("Duplicate property \(name) in \(program)")
            }
        }
        var order: [String] = [], found: [String: (isTexture: Bool, dimension: Int, stages: [String])] = [:]
        func add(_ name: String, texture: Bool, dimension: Int, stage: String) throws {
            if let existing = found[name] {
                guard existing.isTexture == texture else { throw ContractError.invalid("\(name) is both a texture and a vector") }
                found[name] = (texture, max(existing.dimension, dimension), existing.stages.contains(stage) ? existing.stages : existing.stages + [stage])
            } else {
                order.append(name); found[name] = (texture, dimension, [stage])
            }
        }
        var keywords: [String] = []
        for stage in ["vertex", "fragment"] {
            guard let description = stages[stage], let metadata = description["metadata"] as? Row,
                  let buffers = metadata["m_ConstantBuffers"] as? [Row],
                  let textures = metadata["m_TextureParams"] as? [Row] else { throw ContractError.invalid("Missing \(stage) metadata in \(program)") }
            for keyword in description["keywords"] as? [String] ?? [] where !keywords.contains(keyword) { keywords.append(keyword) }
            for buffer in buffers {
                for parameter in buffer["m_VectorParams"] as? [Row] ?? [] {
                    guard let name = names[String(try integer(parameter["m_NameIndex"]))] else { throw ContractError.invalid("Unknown uniform name in \(program)") }
                    let dimension = try integer(parameter["m_Dim"])
                    guard (1...4).contains(dimension) else { throw ContractError.invalid("Unsupported vector size for \(name)") }
                    try add(name, texture: false, dimension: dimension, stage: stage)
                }
            }
            for texture in textures {
                guard let name = names[String(try integer(texture["m_NameIndex"]))] else { throw ContractError.invalid("Unknown texture name in \(program)") }
                try add(name, texture: true, dimension: 0, stage: stage)
            }
        }
        let inputs = order.map { name -> Input in
            let entry = found[name]!
            return Input(name: name, isTexture: entry.isTexture, dimension: entry.dimension,
                         source: classify(name, isTexture: entry.isTexture, properties: properties), stages: entry.stages)
        }
        var passState: [String: Int] = [:], driven: [String: String] = [:]
        func record(_ key: String, _ value: Any?) throws {
            guard let row = value as? Row else { return }
            passState[key] = try integer(row["val"])
            if let name = row["name"] as? String, name != "<noninit>" { driven[key] = name }
        }
        for key in ["zTest", "zWrite", "culling", "offsetFactor", "offsetUnits", "alphaToMask", "stencilRef", "stencilReadMask", "stencilWriteMask"] {
            try record(key, state[key])
        }
        if let blend = state["rtBlend0"] as? Row {
            for key in ["srcBlend", "destBlend", "srcBlendAlpha", "destBlendAlpha", "blendOp", "blendOpAlpha", "colMask"] { try record(key, blend[key]) }
        }
        if let stencil = state["stencilOp"] as? Row {
            for key in ["comp", "pass", "fail", "zFail"] { try record("stencil" + key.prefix(1).uppercased() + key.dropFirst(), stencil[key]) }
        }
        return Self(shader: shader, pass: pass, program: program, inputs: inputs, properties: properties,
                    passState: passState, propertyDrivenPassState: driven, keywords: keywords)
    }

    /// Source of one uniform, using only the program's declared properties.
    public static func classify(_ name: String, isTexture: Bool, properties: [String: Property]) -> Source {
        if isTexture { return properties[name]?.isTexture == true ? .materialTexture : .globalTexture }
        if builtinNames.contains(name) { return .builtin }
        if let property = properties[name], !property.isTexture { return .materialVector }
        if name.hasSuffix("_ST"), properties[String(name.dropLast(3))]?.isTexture == true { return .materialTextureTransform }
        return .globalVector
    }
}

/// The translated programs available for one fixture (`<probe>/shaders/*`),
/// grouped by original shader. The draw order matches the probe's
/// `translatedDrawOrder`: a `<family>_outline` program, when present, draws
/// before the `<family>` forward program of the same material.
public struct SourceShaderProgramCatalog: Sendable {
    public let programs: [String: [SourceShaderProgramContract]]

    public init(programs: [String: [SourceShaderProgramContract]]) { self.programs = programs }

    public static func load(directory: URL) throws -> Self {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
        var byShader: [String: [SourceShaderProgramContract]] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name).appendingPathComponent("program.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let contract = try SourceShaderProgramContract.load(url: url, program: name)
            byShader[contract.shader, default: []].append(contract)
        }
        for (shader, list) in byShader {
            byShader[shader] = list.sorted { ($0.pass == "OUTLINE" ? 0 : 1, $0.program) < ($1.pass == "OUTLINE" ? 0 : 1, $1.program) }
            guard Set(list.map(\.pass)).count == list.count else {
                throw SourceShaderProgramContract.ContractError.invalid("Duplicate translated pass for \(shader)")
            }
        }
        return Self(programs: byShader)
    }

    /// Ordered programs (outline first) for a shader; empty when not translated.
    public func passes(for shader: String) -> [SourceShaderProgramContract] { programs[shader] ?? [] }

    /// Union of one shader's inputs over its translated passes, in first-use order.
    public func inputs(for shader: String) -> [SourceShaderProgramContract.Input] {
        var seen = Set<String>(), result: [SourceShaderProgramContract.Input] = []
        for contract in passes(for: shader) {
            for input in contract.inputs where seen.insert(input.name).inserted { result.append(input) }
        }
        return result
    }

    /// Declared properties of a shader (identical across its passes).
    public func properties(for shader: String) -> [String: SourceShaderProgramContract.Property] {
        passes(for: shader).reduce(into: [:]) { result, contract in result.merge(contract.properties) { first, _ in first } }
    }
}
