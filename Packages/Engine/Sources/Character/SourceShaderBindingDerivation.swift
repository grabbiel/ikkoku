import Foundation
import CryptoKit
import Assets
import Renderer

/// Derives the per-renderer, per-material inputs of the translated original
/// programs (`SourceShaderBindingSet`) for one source character from native
/// data only: the card, the converted Maker library (`materials.json` prefab
/// evidence), the converted head material contract and the translated program
/// descriptors (for `Properties` defaults). It never reads an original-player
/// capture.
///
/// The recipe is the source one: a renderer starts from its prefab material
/// (`m_SavedProperties`; an unsaved property keeps its shader default, an
/// unsaved texture slot is empty with scale/offset `[1, 1, 0, 0]`), then the
/// `ChaControl` setters that the card and status drive are applied. Every
/// setter is cited by method. Inputs whose source data is not converted
/// (catalogs, config, runtime controllers) carry an `unresolved` reason.
///
/// It lives in Character because it needs the card and Maker library types;
/// the data model, program contract and comparison stay in Renderer so the
/// translated probe can consume them without importing Character.
public enum SourceShaderBindingDerivation {
    /// Scene-level `Shader.SetGlobal*` values. They are not character data:
    /// Studio takes them from `SceneInfo`, the fixture harness sets constants.
    public struct SceneGlobals: Sendable, Equatable {
        /// `ChaShader.ChangeLineColor(depth)`: `_LineColorG = (0.5, 0.5, 0.5, 1 - depth)`.
        public var lineDepth: Float
        /// `ChaShader.ChangeLineWidth(width)`: `_linewidthG`.
        public var lineWidth: Float
        /// `Shader.SetGlobalColor(_ambientshadowG, …)`.
        public var ambientShadow: [Float]
        /// `mt_ramp` catalog ID loaded into `_RampG` (`ChaShader.ChangeRampTexture`).
        public var rampID: Int
        public var source: String
        public init(lineDepth: Float, lineWidth: Float, ambientShadow: [Float], rampID: Int, source: String) {
            self.lineDepth = lineDepth; self.lineWidth = lineWidth; self.ambientShadow = ambientShadow; self.rampID = rampID; self.source = source
        }
        /// The constants `OriginalCharacterProbe.Capture` sets before the
        /// R1 fixture frame (`Tools/reverse/fixtures/OriginalCharacterProbe.cs`).
        public static let originalCharacterProbeHarness = SceneGlobals(
            lineDepth: 1, lineWidth: 0.307, ambientShadow: [0.5, 0.5, 0.5, 0.74], rampID: 1,
            source: "OriginalCharacterProbe.Capture harness constants")
    }

    /// One frame's `EyeLookMaterialControll` texture transforms, as the Studio
    /// eye-look code computes them (`SourceStudioIrisRendering.bindingEyeLook`):
    /// renderer node name (`cf_Ohitomi_L02`) → texture property (`_MainTex`,
    /// `_overtex1`, `_overtex2`) → Unity scale/offset. It is a look state, not
    /// card data, so the caller supplies it; without it the iris transforms stay
    /// unresolved.
    public struct EyeLook: Sendable, Equatable {
        public struct Transform: Sendable, Equatable {
            public var scale: [Float]
            public var offset: [Float]
            /// A `isYure` texState: the original re-rolls a random jitter that
            /// is not modelled, so the value is reported unresolved.
            public var yure: Bool
            public init(scale: [Float], offset: [Float], yure: Bool) { self.scale = scale; self.offset = offset; self.yure = yure }
        }
        public var transforms: [String: [String: Transform]]
        public var source: String
        public init(transforms: [String: [String: Transform]], source: String) { self.transforms = transforms; self.source = source }
    }

    public enum DerivationError: Error, CustomStringConvertible, Equatable {
        case invalid(String)
        public var description: String { switch self { case .invalid(let message): message } }
    }

    // MARK: - Converted evidence

    struct Evidence: Decodable {
        struct Pass: Decodable { let name: String; let tags: [String: String]?; let state: JSONValue?; let blend: JSONValue? }
        struct Reference: Decodable { let serializedFile: String?; let pathID: String?; let name: String? }
        struct TexEnv: Decodable { let texture: Reference?; let scale: [Double]; let offset: [Double] }
        let name: String, serializedFile: String?, pathID: String?, shader: String, renderQueue: Int
        let passes: [Pass], floats: [String: Double], colors: [String: [Double]], textures: [String: TexEnv]
    }

    struct LibraryMaterials: Decodable {
        struct Source: Decodable { let bundle: String; let bundleSHA256: String }
        struct CatalogTexture: Decodable { let name: String; let width: Int; let height: Int }
        struct Renderer: Decodable {
            let meshName: String, nodeName: String, materialSlot: Int, material: Evidence
            /// The serialized material typetree (carries `m_ShaderKeywords`).
            let materialTree: JSONValue?
        }
        let category: Int, id: Int, source: Source
        let catalog: [String: String]
        let catalogTextures: [String: CatalogTexture]
        let componentTrees: [JSONValue]
        let renderers: [Renderer]
    }

    struct HeadContract: Decodable {
        struct Source: Decodable { let path: String; let sha256: String }
        struct CatalogRow: Decodable { let table: String; let category: Int; let selectedID: Int; let row: [String: String] }
        struct Texture: Decodable { let name: String; let bundle: String; let serializedFile: String; let pathID: String; let width: Int; let height: Int }
        struct Slot: Decodable { let name: String; let pathID: String }
        struct Draw: Decodable { let materialSlot: Int; let submesh: Int }
        struct Renderer: Decodable { let nodeName: String; let activeSelf: Bool; let enabled: Bool; let materialSlots: [Slot]; let draws: [Draw] }
        /// `head_material_contract.py`: the create pass's DXBC fragment program
        /// hash, checked against the equations recovered for that shader.
        struct VerifiedShader: Decodable { let shader: String; let programSHA256: String }
        let sources: [Source], catalogRows: [CatalogRow], textures: [Texture], drawMaterials: [Evidence], renderers: [Renderer]
        /// `chara/mm_base.unity3d` create materials (`cf_m_eye_create`, ...).
        let createMaterials: [Evidence]?
        let verifiedCreateShaders: [VerifiedShader]?
    }

    /// `Tools/reverse/source_binding_supplement.py` output: source metadata the
    /// other converted contracts omit (keywords, sampler state, the body draw
    /// material, extra catalog rows). Optional; without it those inputs stay
    /// unresolved.
    struct Supplement: Decodable {
        struct MaterialRow: Decodable { let serializedFile: String; let pathID: String; let shaderKeywords: [String] }
        struct TextureRow: Decodable {
            let bundle: String, bundleSHA256: String, serializedFile: String, pathID: String, name: String
            let filter: String, wrap: String, aniso: Int, mipLevels: Int?, width: Int, height: Int
        }
        struct Draw: Decodable { let bundle: String; let bundleSHA256: String; let material: Evidence }
        struct Row: Decodable { let table: String; let category: Int; let id: Int; let row: [String: String] }
        let materials: [MaterialRow], textures: [TextureRow], drawMaterials: [Draw], catalogRows: [Row]
    }

    typealias Set_ = SourceShaderBindingSet
    typealias Property = SourceShaderProgramContract.Property

    /// Texture identity, sampler state and keyword lookups shared by all
    /// evidence kinds, keyed by serialized file and path ID.
    struct TextureIndex {
        var byReference: [String: Set_.TextureIdentity] = [:]
        var bundleByFile: [String: (bundle: String, sha256: String?)] = [:]
        var settings: [String: Supplement.TextureRow] = [:]
        var byBundleName: [String: [Supplement.TextureRow]] = [:]
        var keywords: [String: [String]] = [:]
        func identity(_ reference: Evidence.Reference) -> Set_.TextureIdentity {
            let key = (reference.serializedFile ?? "") + ":" + (reference.pathID ?? "")
            var result = byReference[key] ?? Set_.TextureIdentity(kind: .asset, name: reference.name, serializedFile: reference.serializedFile, pathID: reference.pathID)
            if result.bundle == nil, let file = reference.serializedFile, let bundle = bundleByFile[file] { result.bundle = bundle.bundle; result.bundleSHA256 = bundle.sha256 }
            if let row = settings[key] { enrich(&result, row) }
            return result
        }
        func enrich(_ identity: inout Set_.TextureIdentity, _ row: Supplement.TextureRow) {
            identity.bundle = row.bundle; identity.bundleSHA256 = row.bundleSHA256; identity.serializedFile = row.serializedFile
            identity.pathID = row.pathID; identity.width = row.width; identity.height = row.height; identity.mipLevels = row.mipLevels
            identity.filter = row.filter; identity.wrap = row.wrap; identity.aniso = row.aniso
        }
        /// `CommonLib.LoadAsset(bundle, name)` identity of a catalog texture.
        func catalogIdentity(bundle: String, name: String, head: [HeadContract.Texture], bundleSHA: [String: String]) -> Set_.TextureIdentity {
            var result = Set_.TextureIdentity(kind: .asset, name: name, bundle: bundle, bundleSHA256: bundleSHA[bundle])
            if let known = head.first(where: { $0.name == name && $0.bundle == bundle }) {
                result.serializedFile = known.serializedFile; result.pathID = known.pathID; result.width = known.width; result.height = known.height
            }
            if let rows = byBundleName[bundle + "/" + name], rows.count == 1 { enrich(&result, rows[0]) }
            return result
        }
    }

    // MARK: - Material construction

    /// One material being derived: prefab evidence first, then setters.
    struct Builder {
        var material: Set_.Material
        let declared: [String: Property]
        let fallbackReason: String?
        var setters: [String] = []

        init(evidence: Evidence?, missingReason: String? = nil, shader: String? = nil, catalog: SourceShaderProgramCatalog, index: TextureIndex) {
            let shaderName = evidence?.shader ?? shader
            declared = shaderName.map { catalog.properties(for: $0) } ?? [:]
            guard let evidence else {
                fallbackReason = missingReason ?? "no converted material evidence"
                material = Set_.Material(shader: shaderName, queueSource: "unresolved: " + fallbackReason!,
                                         keywordsSource: "unresolved: " + fallbackReason!, unresolved: fallbackReason)
                for (name, property) in declared {
                    if property.isTexture {
                        material.textures[name] = Set_.Texture(identity: nil, identitySource: "unresolved", identityUnresolved: fallbackReason,
                            scale: nil, offset: nil, transformSource: "unresolved", transformUnresolved: fallbackReason)
                    } else { material.vectors[name] = .init(unresolved: fallbackReason!) }
                }
                return
            }
            fallbackReason = nil
            material = Set_.Material(name: evidence.name, shader: evidence.shader)
            let (queue, queueSource) = Self.queue(evidence)
            material.queue = queue; material.queueSource = queueSource
            if let file = evidence.serializedFile, let pathID = evidence.pathID, let words = index.keywords[file + ":" + pathID] {
                // No ChaControl path calls EnableKeyword/DisableKeyword.
                material.keywords = words; material.keywordsSource = "prefab m_ShaderKeywords (source binding supplement)"
            } else {
                material.keywordsSource = "unresolved: converted material evidence omits m_ShaderKeywords"
            }
            var passStates: [String: [String: Int]] = [:]
            for pass in evidence.passes where pass.name != "SHADOWCASTER" { passStates[pass.name] = Self.passState(pass) }
            material.passStates = passStates
            if declared.isEmpty {
                // No translated program: keep the saved values only.
                for (name, value) in evidence.colors { material.vectors[name] = .init(value.map(Float.init), source: "prefab m_Colors") }
                for (name, value) in evidence.floats { material.vectors[name] = .init([Float(value)], source: "prefab m_Floats") }
            }
            for (name, property) in declared {
                if property.isTexture {
                    if let saved = evidence.textures[name] {
                        material.textures[name] = Set_.Texture(identity: saved.texture.map(index.identity), identitySource: "prefab m_TexEnvs",
                            scale: saved.scale.map(Float.init), offset: saved.offset.map(Float.init), transformSource: "prefab m_TexEnvs")
                    } else {
                        material.textures[name] = Set_.Texture(identity: nil, identitySource: "shader default (no saved TexEnv)",
                            scale: [1, 1], offset: [0, 0], transformSource: "shader default (no saved TexEnv)")
                    }
                } else if property.type <= 1, let saved = evidence.colors[name], saved.count == 4 {
                    material.vectors[name] = .init(saved.map(Float.init), source: "prefab m_Colors")
                } else if property.type >= 2, let saved = evidence.floats[name] {
                    material.vectors[name] = .init([Float(saved)], source: "prefab m_Floats")
                } else {
                    material.vectors[name] = .init(property.type <= 1 ? property.defaultValue : [property.defaultValue[0]], source: "shader default (not saved)")
                }
            }
        }

        static func queue(_ evidence: Evidence) -> (Int, String) {
            if evidence.renderQueue >= 0 { return (evidence.renderQueue, "prefab m_CustomRenderQueue") }
            let tag = evidence.passes.lazy.compactMap { $0.tags?["QUEUE"] }.first
            guard let tag else { return (2000, "shader has no QUEUE tag: Unity Geometry 2000") }
            let bases: [(String, Int)] = [("Background", 1000), ("Geometry", 2000), ("AlphaTest", 2450), ("Transparent", 3000), ("Overlay", 4000)]
            for (name, base) in bases where tag.lowercased().hasPrefix(name.lowercased()) {
                let rest = tag.dropFirst(name.count)
                if rest.isEmpty { return (base, "shader QUEUE tag \(tag)") }
                if let offset = Int(rest.hasPrefix("+") ? String(rest.dropFirst()) : String(rest)) { return (base + offset, "shader QUEUE tag \(tag)") }
            }
            if let value = Int(tag) { return (value, "shader QUEUE tag \(tag)") }
            return (-1, "unresolved: unparsed QUEUE tag \(tag)")
        }

        static func passState(_ pass: Evidence.Pass) -> [String: Int] {
            var result: [String: Int] = [:]
            func value(_ row: JSONValue?) -> Int? { row?["val"]?.doubleValue.map { Int($0) } }
            for key in ["zTest", "zWrite", "culling", "offsetFactor", "offsetUnits", "alphaToMask", "stencilRef", "stencilReadMask", "stencilWriteMask"] {
                if let v = value(pass.state?[key]) { result[key] = v }
            }
            for key in ["srcBlend", "destBlend", "srcBlendAlpha", "destBlendAlpha", "blendOp", "blendOpAlpha", "colMask"] {
                if let v = value(pass.blend?[key]) { result[key] = v }
            }
            for key in ["comp", "pass", "fail", "zFail"] {
                if let v = value(pass.state?["stencilOp"]?[key]) { result["stencil" + key.prefix(1).uppercased() + key.dropFirst()] = v }
            }
            return result
        }

        var hasEvidence: Bool { fallbackReason == nil }

        /// `m_ShaderKeywords` from the Maker library's serialized material
        /// tree (Unity 5.6 stores one space-separated string).
        mutating func keywords(fromTree tree: JSONValue?) {
            guard hasEvidence, tree?["m_Name"]?.stringValue == material.name,
                  let words = tree?["m_ShaderKeywords"]?.stringValue else { return }
            material.keywords = words.split(separator: " ").map(String.init)
            material.keywordsSource = "prefab m_ShaderKeywords (Maker library material tree)"
        }

        /// A setter value. Undeclared properties are recorded for completeness
        /// only when the material has evidence for its shader.
        mutating func set(_ name: String, _ values: [Float], source: String) {
            guard declared.isEmpty || declared[name] != nil || !hasEvidence else { setters.append("\(name): not declared by \(material.shader ?? "?")"); return }
            material.vectors[name] = .init(values, source: source)
        }
        mutating func set(_ name: String, _ value: Float, source: String) { set(name, [value], source: source) }
        mutating func unresolve(_ name: String, _ reason: String) {
            guard declared.isEmpty || declared[name] != nil || !hasEvidence else { return }
            material.vectors[name] = .init(unresolved: reason)
        }

        /// `Material.SetTexture`: the identity changes, scale/offset stay.
        mutating func setTexture(_ name: String, _ identity: Set_.TextureIdentity?, source: String) {
            guard declared.isEmpty || declared[name] != nil || !hasEvidence else { return }
            var texture = material.textures[name] ?? Set_.Texture(identity: nil, identitySource: "", scale: nil, offset: nil,
                transformSource: "unresolved", transformUnresolved: fallbackReason ?? "no saved TexEnv")
            texture.identity = identity; texture.identitySource = source; texture.identityUnresolved = nil
            material.textures[name] = texture
        }
        mutating func unresolveTexture(_ name: String, _ reason: String) {
            guard declared.isEmpty || declared[name] != nil || !hasEvidence else { return }
            var texture = material.textures[name] ?? Set_.Texture(identity: nil, identitySource: "", scale: nil, offset: nil,
                transformSource: "unresolved", transformUnresolved: fallbackReason ?? "no saved TexEnv")
            texture.identity = nil; texture.identitySource = "unresolved"; texture.identityUnresolved = reason
            material.textures[name] = texture
        }
        /// `Material.SetTextureOffset`/`SetTextureScale` on an existing slot.
        mutating func setTransform(_ name: String, scale: [Float], offset: [Float], source: String) {
            guard var texture = material.textures[name] else { return }
            texture.scale = scale; texture.offset = offset; texture.transformSource = source; texture.transformUnresolved = nil
            material.textures[name] = texture
        }
        mutating func unresolveTransform(_ name: String, _ reason: String) {
            guard var texture = material.textures[name] else { return }
            texture.scale = nil; texture.offset = nil; texture.transformSource = "unresolved"; texture.transformUnresolved = reason
            material.textures[name] = texture
        }
    }

    // MARK: - Card access

    struct Card {
        let appearance: SourceCardAppearance
        let status: [String: SourceMessagePackValue]?
        let statusError: String?
        func number(_ path: String) -> Float? {
            if path.hasPrefix("status.") { return status?[String(path.dropFirst(7))].flatMap(Self.number) }
            return appearance.number(path)
        }
        func bool(_ path: String) -> Bool? {
            let value = path.hasPrefix("status.") ? status?[String(path.dropFirst(7))] : appearance.value(path)
            if case .bool(let flag)? = value { return flag }
            return nil
        }
        func color(_ path: String) -> [Float]? {
            guard let list = appearance.value(path)?.arrayValue, list.count == 4 else { return nil }
            let values = list.compactMap(Self.number)
            return values.count == 4 ? values : nil
        }
        func bytes(_ key: String) -> [Int]? {
            guard let value = status?[key] else { return nil }
            if let data = value.binaryValue { return data.map(Int.init) }
            return value.arrayValue?.compactMap(\.integerValue)
        }
        static func number(_ value: SourceMessagePackValue) -> Float? {
            switch value {
            case .float(let n): return Float(n)
            case .integer(let n): return Float(n)
            case .unsigned(let n): return Float(n)
            default: return nil
            }
        }
        func missing(_ path: String) -> String {
            path.hasPrefix("status.") && status == nil ? "card Status record unavailable (\(statusError ?? "absent"))" : "card field \(path) missing"
        }
    }

    // MARK: - Derivation

    public static func derive(card source: SourceCharacterCard, library: SourceMakerLibrary, headContract: Data,
                              catalog: SourceShaderProgramCatalog, supplement supplementData: Data? = nil,
                              scene: SceneGlobals = .originalCharacterProbeHarness,
                              hiPoly: Bool = true, eyeLook: EyeLook? = nil, provenance: [String: String] = [:]) throws -> SourceShaderBindingSet {
        var status: [String: SourceMessagePackValue]?, statusError: String?
        if let block = source.block(named: "Status") {
            do { status = try SourceMessagePack.decode(block.data).stringKeyedMap() } catch { statusError = "\(error)" }
        }
        let coordinateType = status?["coordinateType"]?.integerValue ?? 0
        let coordinate = (0..<7).contains(coordinateType) ? coordinateType : 0
        let card = Card(appearance: try SourceCardAppearance(card: source, coordinate: coordinate), status: status, statusError: statusError)
        let head = try JSONDecoder().decode(HeadContract.self, from: headContract)
        let supplement = try supplementData.map { try JSONDecoder().decode(Supplement.self, from: $0) }
        var result = SourceShaderBindingSet(scope: "Native source-derived shader inputs for one character (card, Maker library material "
            + "evidence, head material contract, translated program defaults). No original-player capture is read.")
        result.provenance = provenance
        result.provenance["cardSHA256"] = source.sourceSHA256
        result.provenance["makerLibrary"] = library.sourceURL.path
        result.provenance["headContractSHA256"] = SHA256.hash(data: headContract).map { String(format: "%02x", $0) }.joined()
        result.provenance["sceneGlobals"] = scene.source
        if let eyeLook { result.provenance["eyeLook"] = eyeLook.source }
        if let supplementData { result.provenance["supplementSHA256"] = SHA256.hash(data: supplementData).map { String(format: "%02x", $0) }.joined() }
        else { result.diagnostics.append("No source binding supplement: keywords, sampler state, the body draw material and non-ID0 catalog rows stay unresolved.") }
        result.provenance["hiPoly"] = String(hiPoly)
        result.provenance["coordinate"] = String(coordinate)
        result.diagnostics += card.appearance.diagnostics
        if let statusError { result.diagnostics.append("Status record unreadable: \(statusError)") }
        let references = try source.modReferences()

        // Head-contract texture identities and bundle hashes.
        var headIndex = TextureIndex()
        var bundleSHA: [String: String] = [:]
        for entry in head.sources {
            if let range = entry.path.range(of: "/abdata/") { bundleSHA[String(entry.path[range.upperBound...])] = entry.sha256 }
        }
        for texture in head.textures {
            headIndex.byReference[texture.serializedFile + ":" + texture.pathID] = Set_.TextureIdentity(kind: .asset, name: texture.name,
                bundle: texture.bundle, bundleSHA256: bundleSHA[texture.bundle], serializedFile: texture.serializedFile, pathID: texture.pathID,
                width: texture.width, height: texture.height)
            headIndex.bundleByFile[texture.serializedFile] = (texture.bundle, bundleSHA[texture.bundle])
        }
        for row in supplement?.textures ?? [] {
            headIndex.settings[row.serializedFile + ":" + row.pathID] = row
            headIndex.byBundleName[row.bundle + "/" + row.name, default: []].append(row)
        }
        for row in supplement?.materials ?? [] { headIndex.keywords[row.serializedFile + ":" + row.pathID] = row.shaderKeywords }
        let catalogRows = Dictionary(head.catalogRows.map { ($0.category, $0) }, uniquingKeysWith: { first, _ in first })
        var supplementRows: [Int: [Int: [String: String]]] = [:]
        for row in supplement?.catalogRows ?? [] { supplementRows[row.category, default: [:]][row.id] = row.row }
        /// A catalog row: the head contract's ID0 rows, else the supplement's.
        func catalogRow(_ category: Int, _ id: Int) -> [String: String]? {
            if let row = catalogRows[category], row.selectedID == id { return row.row }
            return supplementRows[category]?[id]
        }
        let materialsByName = Dictionary(head.drawMaterials.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        /// `ChaControl.GetTexture`: the catalog row's texture, `nil` for "0".
        /// `ChaControl.GetTexture`: the catalog row's texture, `nil` for "0".
        func catalogTexture(_ category: Int, table: String, id: Int, bundleKey: String = "MainAB", key: String,
                            lowSuffix: Bool = true, addHeadSuffix: Bool = false) -> Result<Set_.TextureIdentity?, Reason> {
            guard let row = catalogRow(category, id) else {
                return .failure(Reason("\(table) catalog row ID \(id) is not converted"))
            }
            guard let bundle = row[bundleKey], let asset = row[key] else { return .failure(Reason("\(table) row lacks \(bundleKey)/\(key)")) }
            if bundle == "0" || asset == "0" { return .success(nil) }
            if addHeadSuffix, let headID = card.number("face.headId"), headID != 0 {
                return .failure(Reason("head-specific \(table) variant (_\(Int(headID)) suffix, *50 bundle) is not converted"))
            }
            return .success(headIndex.catalogIdentity(bundle: bundle, name: hiPoly || !lowSuffix ? asset : asset + "_low", head: head.textures, bundleSHA: bundleSHA))
        }
        func catalogTexture(_ category: Int, table: String, id idPath: String, bundleKey: String = "MainAB", key: String,
                            addHeadSuffix: Bool = false) -> Result<Set_.TextureIdentity?, Reason> {
            guard let id = card.number(idPath).map(Int.init) else { return .failure(Reason(card.missing(idPath))) }
            return catalogTexture(category, table: table, id: id, bundleKey: bundleKey, key: key, addHeadSuffix: addHeadSuffix)
        }
        func apply(_ builder: inout Builder, texture name: String, _ value: Result<Set_.TextureIdentity?, Reason>, source: String) {
            switch value {
            case .success(let identity): builder.setTexture(name, identity, source: source)
            case .failure(let reason): builder.unresolveTexture(name, reason.text)
            }
        }
        func applyColor(_ builder: inout Builder, _ name: String, _ path: String, method: String, alpha: Float? = nil) {
            guard var rgba = card.color(path) else { builder.unresolve(name, card.missing(path)); return }
            if let alpha { rgba[3] = alpha }
            builder.set(name, rgba, source: "card \(path) via ChaControl.\(method)")
        }
        func applyNumber(_ builder: inout Builder, _ name: String, _ path: String, method: String, transform: (Float) -> Float = { $0 }) {
            guard let value = card.number(path) else { builder.unresolve(name, card.missing(path)); return }
            builder.set(name, transform(value), source: "card \(path) via ChaControl.\(method)")
        }
        let siru = card.bytes("siruLv")
        func applySiru(_ builder: inout Builder, face: Bool) {
            // ChaControl.UpdateSiru: face _liquidface = siruLv[SiruKao]; body and
            // clothes kinds 0-4 (UpdateClothesSiru) get front/back top/bottom.
            let names = face ? [("_liquidface", 0)] : [("_liquidftop", 1), ("_liquidfbot", 2), ("_liquidbtop", 3), ("_liquidbbot", 4)]
            for (name, index) in names {
                guard let siru, siru.indices.contains(index) else { builder.unresolve(name, card.missing("status.siruLv")); continue }
                builder.set(name, Float(siru[index]), source: "card status.siruLv[\(index)] via ChaControl.UpdateSiru")
            }
        }
        func composite(_ size: Int, _ height: Int? = nil, creator: String) -> Set_.TextureIdentity {
            let h = height ?? size
            // CustomTextureCreate.Initialize: new RenderTexture(w, h, 0, ARGB32) with useMipMap = true.
            let mips = 1 + Int(floor(log2(Double(max(size, h)))))
            // The game never sets the sampler, so Unity's RenderTexture constructor
            // defaults apply: Bilinear, aniso 1 and Clamp wrapping.
            var result = Set_.TextureIdentity(kind: .runtimeComposite, name: "", width: size, height: h, mipLevels: mips, creator: creator)
            result.filter = "Bilinear"; result.wrap = "Clamp"; result.aniso = 1
            return result
        }
        /// A `CustomTextureCreate` recipe before its create method's setters:
        /// `Initialize` clones the create material, so every saved value and
        /// texture transform is the material's own. `InitBaseCustomTextureEtc`
        /// and `InitBaseCustomTextureFace` load the create materials from
        /// `chara/mm_base.unity3d`.
        func createRecipe(material name: String, method: String) -> Set_.CompositeRecipe {
            let bundle = "chara/mm_base.unity3d"
            guard let evidence = head.createMaterials?.first(where: { $0.name == name }) else {
                return Set_.CompositeRecipe(method: method, material: name, bundle: bundle, bundleSHA256: bundleSHA[bundle],
                                            unresolved: "create material \(name) is not in the head material contract")
            }
            var recipe = Set_.CompositeRecipe(method: method, material: name, bundle: bundle, bundleSHA256: bundleSHA[bundle],
                serializedFile: evidence.serializedFile, pathID: evidence.pathID, shader: evidence.shader,
                programSHA256: head.verifiedCreateShaders?.first { $0.shader == evidence.shader }?.programSHA256)
            if recipe.programSHA256 == nil { recipe.unresolved = "\(evidence.shader) create program is not verified by the head material contract" }
            for (key, value) in evidence.colors where value.count == 4 { recipe.vectors[key] = .init(value.map(Float.init), source: "create material m_Colors") }
            for (key, value) in evidence.floats { recipe.vectors[key] = .init([Float(value)], source: "create material m_Floats") }
            for (key, environment) in evidence.textures {
                recipe.textures[key] = Set_.Texture(identity: environment.texture.map(headIndex.identity), identitySource: "create material m_TexEnvs",
                    scale: environment.scale.map(Float.init), offset: environment.offset.map(Float.init),
                    transformSource: "create material m_TexEnvs (Graphics.Blit sets only the texture)")
            }
            return recipe
        }
        /// `ChaControl.SetCreateTexture`: the catalog texture (`_low` unless
        /// hiPoly) becomes `texMain` (`main`) or a material texture. A `"0"`
        /// row loads null: `Graphics.Blit` with a null source is not modelled,
        /// and a null material texture samples the property's Unity default.
        func setCreateTexture(_ recipe: inout Set_.CompositeRecipe, _ property: String, main: Bool,
                              _ value: Result<Set_.TextureIdentity?, Reason>, source: String) {
            var texture = recipe.textures[property] ?? Set_.Texture(identity: nil, identitySource: "", scale: [1, 1], offset: [0, 0],
                                                                    transformSource: "no saved TexEnv: [1, 1, 0, 0]")
            switch value {
            case .success(let identity?):
                texture.identity = identity; texture.identitySource = source; texture.identityUnresolved = nil
            case .success(nil) where main:
                texture.identity = nil; texture.identitySource = "unresolved"
                texture.identityUnresolved = "\(source) loads no texture; Graphics.Blit with a null texMain is not modelled"
            case .success(nil):
                texture.identity = nil; texture.identitySource = "\(source) loads no texture: the property's Unity default"; texture.identityUnresolved = nil
            case .failure(let reason):
                texture.identity = nil; texture.identitySource = "unresolved"; texture.identityUnresolved = reason.text
            }
            recipe.textures[property] = texture
        }
        /// `ctCreateEyeL`/`R`: `ChangeSettingEye(lr, true, true, true)` as
        /// `ChangeHeadAsync` calls it (Maker pupil edits rerun parts of it with
        /// `releaseCustomInputTexture` off, so the full recipe is the same).
        func irisComposite(eye: Int) -> Set_.TextureIdentity {
            let creator = "ctCreateEye\(eye == 0 ? "L" : "R"): cf_m_eye_create (chara/mm_base.unity3d) over mt_eye[face.pupil.\(eye).id] and mt_eye_gradation"
            var identity = composite(hiPoly ? 512 : 256, creator: creator)
            var recipe = createRecipe(material: "cf_m_eye_create",
                method: "ChaControl.ChangeSettingEye(\(eye), updateBaseTex: true, updateMaskTex: true, updateColorAndOffset: true)")
            let pupil = "face.pupil.\(eye)"
            setCreateTexture(&recipe, "_MainTex", main: true,
                catalogTexture(408, table: "mt_eye", id: pupil + ".id", key: "EyeTex"),
                source: "mt_eye[\(pupil).id] MainAB/EyeTex via ChaControl.SetCreateTexture (main)")
            setCreateTexture(&recipe, "_ColorMask", main: false,
                catalogTexture(409, table: "mt_eye_gradation", id: pupil + ".gradMaskId", bundleKey: "ColorMaskAB", key: "ColorMaskTex"),
                source: "mt_eye_gradation[\(pupil).gradMaskId] ColorMaskAB/ColorMaskTex via ChaControl.SetCreateTexture (_ColorMask)")
            for (name, key) in [("_Color", "baseColor"), ("_Color2", "subColor")] {
                if let rgba = card.color("\(pupil).\(key)") {
                    recipe.vectors[name] = .init(rgba, source: "card \(pupil).\(key) via ChaControl.ChangeSettingEye → SetColor(\(name))")
                } else { recipe.vectors[name] = .init(unresolved: card.missing("\(pupil).\(key)")) }
            }
            if let blend = card.number("\(pupil).gradBlend") {
                recipe.vectors["_Blend"] = .init([blend], source: "card \(pupil).gradBlend via ChaControl.ChangeSettingEye → SetFloat(_Blend)")
            } else { recipe.vectors["_Blend"] = .init(unresolved: card.missing("\(pupil).gradBlend")) }
            if let offset = card.number("\(pupil).gradOffsetY"), let scale = card.number("\(pupil).gradScale") {
                recipe.vectors["_grad"] = .init([0, lerp(-0.5, 0.5, offset), 0, lerp(-1, 1, scale)],
                    source: "card \(pupil).gradOffsetY/gradScale via ChaControl.ChangeSettingEye → SetVector4(_grad, (0, Lerp(-0.5, 0.5, y), 0, Lerp(-1, 1, scale)))")
            } else { recipe.vectors["_grad"] = .init(unresolved: card.missing("\(pupil).gradOffsetY/gradScale")) }
            identity.composite = recipe
            return identity
        }
        /// `ctCreateEyeW`: `ChangeSettingWhiteOfEye(updateTex: true, updateColor:
        /// true)` as `ChangeHeadAsync` calls it. Maker reruns it for the texture
        /// or the colours alone (`releaseCustomInputTexture` off), so the full
        /// recipe is the same.
        func eyeWhiteComposite() -> Set_.TextureIdentity {
            var identity = composite(hiPoly ? 512 : 256,
                creator: "ctCreateEyeW: cf_m_eyewhite_create (chara/mm_base.unity3d) over mt_eye_white[face.whiteId] with whiteBaseColor/whiteSubColor")
            var recipe = createRecipe(material: "cf_m_eyewhite_create",
                method: "ChaControl.ChangeSettingWhiteOfEye(updateTex: true, updateColor: true)")
            setCreateTexture(&recipe, "_MainTex", main: true,
                catalogTexture(407, table: "mt_eye_white", id: "face.whiteId", key: "EyeWhiteTex"),
                source: "mt_eye_white[face.whiteId] MainAB/EyeWhiteTex via ChaControl.SetCreateTexture (main)")
            for (name, key) in [("_Color", "whiteBaseColor"), ("_Color2", "whiteSubColor")] {
                if let rgba = card.color("face.\(key)") {
                    recipe.vectors[name] = .init(rgba, source: "card face.\(key) via ChaControl.ChangeSettingWhiteOfEye → SetColor(\(name))")
                } else { recipe.vectors[name] = .init(unresolved: card.missing("face.\(key)")) }
            }
            identity.composite = recipe
            return identity
        }
        // MARK: Hair (ChaControl.ChangeHairAsync → ChangeSettingHair*)
        if let parts = card.appearance.value("hair.parts")?.arrayValue {
            // ChaControl.LoadHairGlossMask: mt_hairgloss[hair.glossId] MainTexAB/MainTex (no _low suffix).
            let gloss: Result<Set_.TextureIdentity?, Reason>
            if let glossID = card.number("hair.glossId").map(Int.init) {
                gloss = catalogTexture(433, table: "mt_hairgloss", id: glossID, bundleKey: "MainTexAB", key: "MainTex", lowSuffix: false)
            } else { gloss = .failure(Reason(card.missing("hair.glossId"))) }
            for slot in 0..<min(parts.count, 4) {
                guard let id = card.number("hair.parts.\(slot).id").map(Int.init) else { result.diagnostics.append("hair part \(slot) has no id"); continue }
                let property = "ChaFileHair." + ["HairBack", "HairFront", "HairSide", "HairOption"][slot]
                let selection = library.selection(category: 101 + slot, savedID: id, property: property, references: references)
                guard let entry = selection.entry else {
                    result.diagnostics.append("\(property) \(101 + slot):\(id): \(selection.status); renderers unknown."); continue
                }
                if entry.empty == true { continue }
                guard let data = try library.materialEvidenceData(for: entry) else {
                    result.diagnostics.append("\(property) \(101 + slot):\(id) has no converted material evidence."); continue
                }
                let evidence = try JSONDecoder().decode(LibraryMaterials.self, from: data)
                var index = headIndex
                if let file = evidence.renderers.first?.material.serializedFile { index.bundleByFile[file] = (evidence.source.bundle, evidence.source.bundleSHA256) }
                let hairCount = Self.componentRendererCount(evidence.componentTrees, key: "rendHair")
                let accessoryCount = Self.componentRendererCount(evidence.componentTrees, key: "rendAccessory")
                let allHair = hairCount == evidence.renderers.count && accessoryCount == 0
                if !allHair { result.diagnostics.append("\(101 + slot):\(id): rendHair/rendAccessory membership is not resolvable from evidence; hair setters left unresolved.") }
                for renderer in evidence.renderers {
                    var builder = Builder(evidence: renderer.material, catalog: catalog, index: index)
                    builder.keywords(fromTree: renderer.materialTree)
                    if allHair {
                        for (name, key) in [("_Color", "baseColor"), ("_Color2", "startColor"), ("_Color3", "endColor")] {
                            // ChangeSettingHairColor forces alpha to 1 before SetColor.
                            if let rgba = card.color("hair.parts.\(slot).\(key)") {
                                builder.set(name, [rgba[0], rgba[1], rgba[2], max(rgba[3], 1)], source: "card hair.parts.\(slot).\(key) via ChaControl.ChangeSettingHairColor (alpha raised to 1)")
                            } else { builder.unresolve(name, card.missing("hair.parts.\(slot).\(key)")) }
                        }
                        applyColor(&builder, "_LineColor", "hair.parts.\(slot).outlineColor", method: "ChangeSettingHairOutlineColor")
                        apply(&builder, texture: "_HairGloss", gloss, source: "ChaControl.LoadHairGlossMask → ChangeSettingHairGlossMask")
                    } else {
                        for name in ["_Color", "_Color2", "_Color3", "_LineColor"] { builder.unresolve(name, "hair renderer role unresolved") }
                        builder.unresolveTexture("_HairGloss", "hair renderer role unresolved")
                    }
                    result.renderers.append(.init(mesh: renderer.nodeName, component: "hair.\(slot) \(101 + slot):\(id)", materialSlot: renderer.materialSlot,
                        submesh: renderer.materialSlot, visible: true, visibility: "hair part: no status visibility rule", material: builder.material))
                }
            }
        } else { result.diagnostics.append("hair.parts missing; no hair renderers derived") }

        // MARK: Clothes (ChaControl.ChangeClothesAsync → ChangeCustomClothes)
        let clothesState = card.bytes("clothesState"), shoesType = card.number("status.shoesType").map(Int.init)
        var topBodyMask: Result<Set_.TextureIdentity?, Reason> = .failure(Reason("clothes top not derived"))
        var notBot = false
        for slot in 0..<9 {
            guard let id = card.number("clothes.parts.\(slot).id").map(Int.init) else { result.diagnostics.append("clothes part \(slot) has no id"); continue }
            let category = min(105 + slot, 112)
            let property = "outfit\(coordinate).ChaFileClothes.Clothes" + ["Top", "Bot", "Bra", "Shorts", "Gloves", "Pants", "Socks", "ShoesInner", "ShoesOuter"][slot]
            let selection = library.selection(category: category, savedID: id, property: property, references: references)
            guard let entry = selection.entry else {
                result.diagnostics.append("\(property) \(category):\(id): \(selection.status); renderers unknown.")
                if slot == 0 { topBodyMask = .failure(Reason("clothes top \(category):\(id) not converted")) }
                continue
            }
            if entry.empty == true {
                if slot == 0 { topBodyMask = .success(nil) }
                continue
            }
            guard let data = try library.materialEvidenceData(for: entry) else {
                result.diagnostics.append("\(property) \(category):\(id) has no converted material evidence."); continue
            }
            let evidence = try JSONDecoder().decode(LibraryMaterials.self, from: data)
            if slot == 0 {
                // LoadAlphaMaskTexture(OverBodyMaskAB, OverBodyMask) → customMatBody._AlphaMask.
                if let bundle = evidence.catalog["OverBodyMaskAB"], let asset = evidence.catalog["OverBodyMask"], bundle != "0", asset != "0" {
                    if let known = evidence.catalogTextures["bodyMask"], known.name == asset {
                        var identity = headIndex.catalogIdentity(bundle: bundle, name: known.name, head: [], bundleSHA: bundleSHA)
                        if identity.width == nil { identity.width = known.width; identity.height = known.height }
                        topBodyMask = .success(identity)
                    } else { topBodyMask = .failure(Reason("top body mask \(asset) is not converted")) }
                } else { topBodyMask = .success(nil) }
                notBot = evidence.catalog["Coordinate"] == "2"
            }
            var index = headIndex
            if let file = evidence.renderers.first?.material.serializedFile { index.bundleByFile[file] = (evidence.source.bundle, evidence.source.bundleSHA256) }
            let normal = Self.componentRendererCount(evidence.componentTrees, key: "rendNormal01")
            let others = ["rendNormal02", "rendNormal03", "rendAlpha01", "rendAlpha02"].map { Self.componentRendererCount(evidence.componentTrees, key: $0) }.reduce(0, +)
            let allNormal = normal >= evidence.renderers.count && others == 0
            for renderer in evidence.renderers {
                var builder = Builder(evidence: renderer.material, catalog: catalog, index: index)
                builder.keywords(fromTree: renderer.materialTree)
                if allNormal, let main = evidence.catalogTextures["main"], evidence.catalog["MainTex"] == main.name {
                    // InitBaseCustomTextureClothes sizes the composite from the main texture.
                    builder.setTexture("_MainTex", composite(main.width, main.height, creator: "ChaControl.ChangeCustomClothes: cf_m_clothesN_create (chara/mm_base.unity3d) over \(main.name) with card colorInfo"),
                                       source: "ChaControl.ChangeCustomClothes → rendNormal01 _MainTex")
                } else {
                    builder.unresolveTexture("_MainTex", allNormal ? "clothes main texture is not converted" : "rendNormal01 membership is not resolvable from evidence")
                }
                if slot <= 4 { applySiru(&builder, face: false) }
                var visible = true, rule = "clothesState[\(slot)] == 0"
                if let state = clothesState, state.indices.contains(slot) { visible = state[slot] == 0 } else { rule = "clothesState missing; assumed worn" ; visible = true }
                if slot == 7 || slot == 8 {
                    if let shoesType { visible = visible && shoesType == (slot == 7 ? 0 : 1); rule += ", shoesType == \(slot == 7 ? 0 : 1)" }
                    else { rule += ", shoesType missing" }
                }
                if slot == 1, notBot { visible = false; rule += ", top Coordinate == 2 hides the bottom" }
                if !allNormal { result.diagnostics.append("\(category):\(id): clothes renderer roles unresolved") }
                result.renderers.append(.init(mesh: renderer.nodeName, component: "clothes.\(slot) \(category):\(id)", materialSlot: renderer.materialSlot,
                    submesh: renderer.materialSlot, visible: visible, visibility: "ChaControl.UpdateVisible: " + rule, material: builder.material))
            }
        }

        // MARK: Head (ID0 head material contract)
        let headID = card.number("face.headId").map(Int.init)
        // ChaControl.ChangeEyesPtn: an unknown pattern falls back to row 0.
        let eyesPtn = card.number("status.eyesPtn").map(Int.init)
        let eyeSet: [String: String]? = eyesPtn.flatMap { catalogRow(2, $0) ?? catalogRow(2, 0) }
        let gagObject = eyeSet?["EyeObjNo"].flatMap(Int.init)
        let gagNote = eyesPtn == nil ? card.missing("status.eyesPtn") : "cha_eyeset catalog (EyeObjNo for status.eyesPtn) is not converted"
        if headID != 0 {
            result.diagnostics.append("face.headId \(headID.map(String.init) ?? "missing") has no converted head material contract; head renderers not derived.")
        } else {
            if let row = catalogRows[100], let matData = row.row["MatData"], materialsByName[matData] == nil {
                result.diagnostics.append("head draw material \(matData) is not in the head contract")
            }
            for renderer in head.renderers {
                for draw in renderer.draws {
                    guard renderer.materialSlots.indices.contains(draw.materialSlot) else { continue }
                    let slotName = renderer.materialSlots[draw.materialSlot].name
                    var builder = Builder(evidence: materialsByName[slotName], missingReason: "head material \(slotName) not in contract", catalog: catalog, index: headIndex)
                    var visible = renderer.activeSelf && renderer.enabled, rule = "prefab activeSelf/enabled"
                    switch renderer.nodeName {
                    case "cf_O_face":
                        // customTexCtrlFace.matDraw (catalog MatData) on rendFace slot 0.
                        builder.setTexture("_MainTex", composite(hiPoly ? 1024 : 512, creator: "CustomTextureControl face: cf_m_face_create (chara/mm_base.unity3d) over head MainTex, skin and makeup inputs"),
                                           source: "ChaControl.CreateFaceTexture → customTexCtrlFace")
                        apply(&builder, texture: "_NormalMapDetail", catalogTexture(400, table: "mt_face_detail", id: "face.detailId", key: "NormallMapDetail"), source: "ChaControl.ChangeSettingFaceDetail")
                        apply(&builder, texture: "_LineMask", catalogTexture(400, table: "mt_face_detail", id: "face.detailId", key: "LineMask"), source: "ChaControl.ChangeSettingFaceDetail")
                        applyNumber(&builder, "_DetailNormalMapScale", "face.detailPower", method: "ChangeSettingFaceDetailPower")
                        apply(&builder, texture: "_overtex1", catalogTexture(403, table: "mt_lip", id: "makeup.lipId", key: "LipTex"), source: "ChaControl.ChangeSettingLip")
                        applyColor(&builder, "_overcolor1", "makeup.lipColor", method: "ChangeSettingLipColor")
                        apply(&builder, texture: "_overtex3", catalogTexture(401, table: "mt_eyeshadow", id: "makeup.eyeshadowId", key: "EyeshadowTex"), source: "ChaControl.ChangeSettingEyeShadow")
                        if let gagObject {
                            // ChangeSettingEyeShadowColor: alpha 0 when IsGagEyes (EyeObjNo != 0).
                            applyColor(&builder, "_overcolor3", "makeup.eyeshadowColor", method: "ChangeSettingEyeShadowColor (cha_eyeset EyeObjNo \(gagObject))",
                                       alpha: gagObject != 0 ? 0 : nil)
                        } else {
                            builder.unresolve("_overcolor3", "ChangeSettingEyeShadowColor zeroes the alpha for gag eyes; IsGagEyes needs the \(gagNote)")
                        }
                        applyNumber(&builder, "_SpecularPower", "face.cheekGlossPower", method: "ChangeSettingCheekGlossPower")
                        applyNumber(&builder, "_SpecularPowerNail", "face.lipGlossPower", method: "ChangeSettingLipGlossPower")
                        // ChangeHohoAkaRate keeps the prefab RGB and sets alpha = lerp(0, 0.2, rate),
                        // or 0 when Config.EtcData.hohoAka is off (config is not modelled).
                        if let rgb = builder.material.vectors["_overcolor2"]?.values, rgb.count == 4, let rate = card.number("status.hohoAkaRate") {
                            if rate == 0 { builder.set("_overcolor2", [rgb[0], rgb[1], rgb[2], 0], source: "prefab RGB; alpha lerp(0, 0.2, status.hohoAkaRate = 0) via ChaControl.ChangeHohoAkaRate") }
                            else { builder.unresolve("_overcolor2", "alpha lerp(0, 0.2, hohoAkaRate) unless Config.EtcData.hohoAka is off; config is not modelled") }
                        } else { builder.unresolve("_overcolor2", card.missing("status.hohoAkaRate")) }
                        applySiru(&builder, face: true)
                    case "cf_O_eyeline":
                        if draw.materialSlot == 0 {
                            apply(&builder, texture: "_MainTex", catalogTexture(412, table: "mt_eyeline_up", id: "face.eyelineUpId", key: "EyelineUpTex", addHeadSuffix: true), source: "ChaControl.ChangeSettingEyelineUp")
                            applyColor(&builder, "_Color", "face.eyelineColor", method: "ChangeSettingEyelineColor")
                        } else {
                            apply(&builder, texture: "_MainTex", catalogTexture(412, table: "mt_eyeline_up", id: "face.eyelineUpId", key: "EyelineShadowTex", addHeadSuffix: true), source: "ChaControl.ChangeSettingEyelineUp")
                            applyColor(&builder, "_Color", "body.skinMainColor", method: "UpdateEyelineShadowColor")
                        }
                    case "cf_O_eyeline_low":
                        apply(&builder, texture: "_MainTex", catalogTexture(413, table: "mt_eyeline_down", id: "face.eyelineDownId", key: "EyelineDownTex", addHeadSuffix: true), source: "ChaControl.ChangeSettingEyelineDown")
                        applyColor(&builder, "_Color", "face.eyelineColor", method: "ChangeSettingEyelineColor")
                    case "cf_O_mayuge":
                        apply(&builder, texture: "_MainTex", catalogTexture(406, table: "mt_eyebrow", id: "face.eyebrowId", key: "EyebrowTex"), source: "ChaControl.ChangeSettingEyebrow")
                        applyColor(&builder, "_Color", "face.eyebrowColor", method: "ChangeSettingEyebrowColor")
                    case "cf_O_noseline":
                        apply(&builder, texture: "_MainTex", catalogTexture(414, table: "mt_nose", id: "face.noseId", key: "NoseTex"), source: "ChaControl.ChangeSettingNose")
                    case "cf_Ohitomi_L", "cf_Ohitomi_R":
                        // rendEyeW[0/1] (ChaReference ObjEyeWL/WR) share one material.
                        builder.setTexture("_MainTex", eyeWhiteComposite(), source: "ChaControl.ChangeSettingWhiteOfEye")
                    case "cf_Ohitomi_L02", "cf_Ohitomi_R02":
                        // rendEye[0] = ObjEyeL (cf_Ohitomi_L02), rendEye[1] = ObjEyeR.
                        let eye = renderer.nodeName == "cf_Ohitomi_L02" ? 0 : 1
                        builder.setTexture("_MainTex", irisComposite(eye: eye), source: "ChaControl.ChangeSettingEye")
                        apply(&builder, texture: "_overtex1", catalogTexture(410, table: "mt_eye_hi_up", id: "face.hlUpId", key: "EyeHiUpTex"), source: "ChaControl.ChangeSettingEyeHiUp")
                        applyColor(&builder, "_overcolor1", "face.hlUpColor", method: "ChangeSettingEyeHiUpColor")
                        apply(&builder, texture: "_overtex2", catalogTexture(411, table: "mt_eye_hi_down", id: "face.hlDownId", key: "EyeHiDownTex"), source: "ChaControl.ChangeSettingEyeHiDown")
                        applyColor(&builder, "_overcolor2", "face.hlDownColor", method: "ChangeSettingEyeHiDownColor")
                        if let tilt = card.appearance.value("face.shapeValueFace.33").flatMap(Card.number) {
                            let value = eye == 0 ? lerp(0.02, -0.02, tilt) : lerp(-0.02, 0.02, tilt)
                            builder.set("_rotation", value, source: "card face.shapeValueFace[33] via ChaControl.ChangeSettingEyeTilt")
                        } else { builder.unresolve("_rotation", card.missing("face.shapeValueFace.33")) }
                        if let hide = card.bool("status.hideEyesHighlight") {
                            builder.set("_isHighLight", hide ? 0 : 1, source: "card status.hideEyesHighlight via ChaControl.HideEyeHighlight")
                        } else { builder.unresolve("_isHighLight", card.missing("status.hideEyesHighlight")) }
                        if let eyeSet, let bundle = eyeSet["EpsTexAB"], let asset = eyeSet["EpsTex"] {
                            // ChangeEyesPtn: EpsTex loads into _expression with _exppower 1, else null and 0.
                            let texture = bundle == "0" || asset == "0" ? nil : headIndex.catalogIdentity(bundle: bundle, name: hiPoly ? asset : asset + "_low", head: head.textures, bundleSHA: bundleSHA)
                            builder.setTexture("_expression", texture, source: "cha_eyeset[\(eyesPtn ?? 0)] EpsTex via ChaControl.ChangeEyesPtn")
                            builder.set("_exppower", texture == nil ? 0 : 1, source: "cha_eyeset[\(eyesPtn ?? 0)] EpsTex via ChaControl.ChangeEyesPtn")
                        } else {
                            builder.unresolveTexture("_expression", "eye-pattern row (EpsTex for status.eyesPtn): \(gagNote)")
                            builder.unresolve("_exppower", "eye-pattern row (EpsTex for status.eyesPtn): \(gagNote)")
                        }
                        for name in ["_MainTex", "_overtex1", "_overtex2"] {
                            // EyeLookMaterialControll.Update writes SetTextureOffset/
                            // SetTextureScale every frame from the look state.
                            if let eyeLook, let transform = eyeLook.transforms[renderer.nodeName]?[name] {
                                if transform.yure {
                                    builder.unresolveTransform(name, "EyeLookMaterialControll Yure texState: the random YureAddScale/YureAddVec jitter is not modelled (\(eyeLook.source))")
                                } else {
                                    builder.setTransform(name, scale: transform.scale, offset: transform.offset, source: "\(eyeLook.source) via EyeLookMaterialControll.Update")
                                }
                            } else {
                                builder.unresolveTransform(name, eyeLook == nil
                                    ? "EyeLookMaterialControll texture offsets (gaze, pupil and highlight position) are not evaluated by this card-only derivation"
                                    : "the supplied eye-look state has no \(name) transform for \(renderer.nodeName)")
                            }
                        }
                    case "cf_O_canine":
                        if let flag = card.bool("face.doubleTooth") { visible = visible && flag; rule = "ChaControl.VisibleDoubleTooth: face.doubleTooth" }
                        else { rule = "unresolved: " + card.missing("face.doubleTooth") }
                    case "cf_O_namida_S", "cf_O_namida_M", "cf_O_namida_L":
                        let column = ["cf_O_namida_S": 0, "cf_O_namida_M": 1, "cf_O_namida_L": 2][renderer.nodeName]!
                        if let level = card.number("status.tearsLv").map(Int.init), (0...3).contains(level) {
                            visible = visible && level == column + 1; rule = "ChaControl.UpdateVisible: S_TEARS_0\(column + 1) when status.tearsLv == \(column + 1)"
                        } else { rule = "unresolved: " + card.missing("status.tearsLv") }
                    case "o_tang":
                        if let state = card.number("status.tongueState").map(Int.init) { visible = visible && state == 0; rule = "ChaControl.UpdateVisible: S_TongueF when status.tongueState == 0" }
                        else { rule = "unresolved: " + card.missing("status.tongueState") }
                    case let name where name.hasPrefix("cf_O_gag_eye"):
                        // ChangeEyesPtn: N_Gag0i is active iff i + 1 == EyeObjNo.
                        if let gagObject, let number = Int(name.suffix(2)) {
                            visible = renderer.enabled && number + 1 == gagObject
                            rule = "ChaControl.ChangeEyesPtn: N_Gag0\(number) active iff cha_eyeset[\(eyesPtn ?? 0)].EyeObjNo (\(gagObject)) == \(number + 1)"
                        } else { rule = "prefab activeSelf \(renderer.activeSelf); ChaControl.ChangeEyesPtn can activate it, but the \(gagNote)" }
                    default: break
                    }
                    result.renderers.append(.init(mesh: renderer.nodeName, component: "head 0", materialSlot: draw.materialSlot, submesh: draw.submesh,
                        visible: visible, visibility: rule, material: builder.material))
                }
            }
        }

        // MARK: Body (customTexCtrlBody.matDraw = mm_base cf_m_body)
        do {
            // InitBaseCustomTextureBody: drawMatName cf_m_body (female) / cm_m_body (male) from chara/mm_base.unity3d.
            let sex = (try? source.customization().sex) ?? 1
            let drawName = sex == 0 ? "cm_m_body" : "cf_m_body"
            let reason = "chara/mm_base.unity3d \(drawName) draw material is not converted (ChaControl.InitBaseCustomTextureBody)"
            let draw = supplement?.drawMaterials.first { $0.bundle == "chara/mm_base.unity3d" && $0.material.name == drawName }
            var bodyIndex = headIndex
            if let draw, let file = draw.material.serializedFile { bodyIndex.bundleByFile[file] = (draw.bundle, draw.bundleSHA256) }
            // Without the converted material the shader is unknown, so no program
            // property list is assumed: only setter values are known.
            var builder = Builder(evidence: draw?.material, missingReason: reason, catalog: catalog, index: bodyIndex)
            builder.setTexture("_MainTex", composite(hiPoly ? 2048 : 512, creator: "CustomTextureControl body: cf_m_body_create (chara/mm_base.unity3d) over body base, skin and paint inputs"),
                               source: "ChaControl.CreateBodyTexture → customTexCtrlBody")
            apply(&builder, texture: "_overtex1", catalogTexture(423, table: "mt_nip", id: "body.nipId", key: "NipTex"), source: "ChaControl.ChangeSettingNip")
            applyNumber(&builder, "_nipsize", "body.areolaSize", method: "ChangeSettingAreolaSize")
            applyColor(&builder, "_overcolor1", "body.nipColor", method: "ChangeSettingNipColor")
            applyNumber(&builder, "_nip_specular", "body.nipGlossPower", method: "ChangeSettingNipGlossPower")
            apply(&builder, texture: "_overtex2", catalogTexture(424, table: "mt_underhair", id: "body.underhairId", key: "UnderhairTex"), source: "ChaControl.ChangeSettingUnderhair")
            applyColor(&builder, "_overcolor2", "body.underhairColor", method: "ChangeSettingUnderhairColor")
            if let flag = card.bool("body.drawAddLine") { builder.set("_linetexon", flag ? 1 : 0, source: "card body.drawAddLine via ChaControl.VisibleAddBodyLine") }
            else { builder.unresolve("_linetexon", card.missing("body.drawAddLine")) }
            apply(&builder, texture: "_NormalMapDetail", catalogTexture(420, table: "mt_body_detail", id: "body.detailId", key: "NormallMapDetail"), source: "ChaControl.ChangeSettingBodyDetail")
            apply(&builder, texture: "_LineMask", catalogTexture(420, table: "mt_body_detail", id: "body.detailId", key: "LineMask"), source: "ChaControl.ChangeSettingBodyDetail")
            applyNumber(&builder, "_DetailNormalMapScale", "body.detailPower", method: "ChangeSettingBodyDetailPower")
            if let gloss = card.number("body.skinGlossPower"), let tuya = card.number("status.skinTuyaRate") {
                builder.set("_SpecularPower", lerp(gloss, 1, tuya), source: "lerp(card body.skinGlossPower, 1, status.skinTuyaRate) via ChaControl.ChangeSettingSkinGlossPower")
            } else { builder.unresolve("_SpecularPower", card.missing(card.number("body.skinGlossPower") == nil ? "body.skinGlossPower" : "status.skinTuyaRate")) }
            applyNumber(&builder, "_SpecularPowerNail", "body.nailGlossPower", method: "ChangeSettingNailGlossPower")
            if let state = clothesState, let top = state.first, (0...3).contains(top) {
                // ChaControl.UpdateVisible → ChangeAlphaMask(table[clothesState[0]]).
                let table: [[Float]] = [[1, 1], [0, 1], [0, 1], [0, 0]]
                builder.set("_alpha_a", table[top][0], source: "status.clothesState[0] table via ChaControl.ChangeAlphaMask")
                builder.set("_alpha_b", table[top][1], source: "status.clothesState[0] table via ChaControl.ChangeAlphaMask")
            } else { builder.unresolve("_alpha_a", card.missing("status.clothesState")); builder.unresolve("_alpha_b", card.missing("status.clothesState")) }
            apply(&builder, texture: "_AlphaMask", topBodyMask, source: "top catalog OverBodyMask via ChaControl.ChangeClothesTopAsync → LoadAlphaMaskTexture")
            applySiru(&builder, face: false)
            result.renderers.append(.init(mesh: "o_body_a", component: "body (ChaReference ObjBody)", materialSlot: 0, submesh: 0, visible: true,
                visibility: "body draw renderer; other body-prefab renderers are not enumerated (no converted body renderer evidence)", material: builder.material))
        }

        // MARK: Globals (scene inputs, not character data)
        result.globalVectors["_LineColorG"] = .init([0.5, 0.5, 0.5, 1 - scene.lineDepth], source: "\(scene.source): ChaShader.ChangeLineColor(\(scene.lineDepth))")
        result.globalVectors["_linewidthG"] = .init([scene.lineWidth], source: "\(scene.source): ChaShader.ChangeLineWidth")
        result.globalVectors["_ambientshadowG"] = .init(scene.ambientShadow, source: "\(scene.source): Shader.SetGlobalColor(_ambientshadowG)")
        for name in ["_rimG", "_FaceShadowG", "_FaceNormalG", "_TimeEditor"] {
            // No recovered method sets these; an unset Unity global reads zero.
            result.globalVectors[name] = .init([0, 0, 0, 0], source: "never set by recovered source; Unity unset global is zero")
        }
        result.globalVectors["_Time"] = .init(unresolved: "frame clock (Time.time at capture) is a playback input, not character data")
        result.globalVectors["_RampG_ST"] = .init(unresolved: "Unity value of an unset global texture transform is not verified (the probe binds [1,1,0,0] by convention)")
        switch catalogTexture(432, table: "mt_ramp", id: scene.rampID, bundleKey: "MainTexAB", key: "MainTex", lowSuffix: false) {
        case .success(let identity):
            result.globalTextures["_RampG"] = Set_.Texture(identity: identity, identitySource: "\(scene.source): mt_ramp[\(scene.rampID)] via ChaShader.ChangeRampTexture",
                scale: nil, offset: nil, transformSource: "unresolved", transformUnresolved: "global texture")
        case .failure(let reason):
            result.globalTextures["_RampG"] = Set_.Texture(identity: nil, identitySource: "unresolved", identityUnresolved: reason.text + " (ChaShader.ChangeRampTexture)",
                scale: nil, offset: nil, transformSource: "unresolved", transformUnresolved: "global texture")
        }
        return result
    }

    struct Reason: Error { let text: String; init(_ text: String) { self.text = text } }

    /// `Mathf.Lerp`, which clamps `t` to [0, 1].
    static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * min(max(t, 0), 1) }

    /// Renderer references a component lists under `key`, from the converted
    /// MonoBehaviour trees (null references excluded).
    static func componentRendererCount(_ trees: [JSONValue], key: String) -> Int {
        var count = 0
        for tree in trees {
            switch tree[key] {
            case .array(let list)?: count += list.filter { ($0["m_PathID"]?.doubleValue ?? 0) != 0 }.count
            case .object?: if (tree[key]?["m_PathID"]?.doubleValue ?? 0) != 0 { count += 1 }
            default: break
            }
        }
        return count
    }
}
