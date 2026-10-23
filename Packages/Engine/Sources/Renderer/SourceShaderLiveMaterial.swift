import Foundation
import CryptoKit
import Metal
import simd
import CoreMath

/// Why one material slot is not drawn by the opt-in live source-shader path.
/// The item keeps the native toon draw and this text is reported per material,
/// so a frame never mixes the two without a diagnostic.
public struct SourceShaderLiveReason: Error, CustomStringConvertible, Equatable, Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var description: String { text }
}

/// One texture input the live path needs pixels for: the native identity from
/// `SourceShaderBindingSet`, the program property, and (for material
/// textures) the renderer and material slot it belongs to.
public struct SourceShaderLiveTextureRequest: Sendable {
    public let identity: SourceShaderBindingSet.TextureIdentity
    public let property: String
    public let mesh: String?
    public let slot: Int?
    public init(identity: SourceShaderBindingSet.TextureIdentity, property: String, mesh: String?, slot: Int?) {
        self.identity = identity; self.property = property; self.mesh = mesh; self.slot = slot
    }
}

/// Pixels for one texture identity, plus the sampler state recorded with them
/// (the asset's own `m_TextureSettings`, or a capture row) for when the binding
/// identity carries none.
public struct SourceShaderLiveTexture: @unchecked Sendable {
    public let texture: any MTLTexture
    public let filter: String?, wrap: String?, aniso: Int?
    public let provenance: String
    public init(texture: any MTLTexture, filter: String?, wrap: String?, aniso: Int?, provenance: String) {
        self.texture = texture; self.filter = filter; self.wrap = wrap; self.aniso = aniso; self.provenance = provenance
    }
}

/// Supplies texture pixels by native identity. A provider never substitutes a
/// different texture: an identity it cannot supply is a reason, and the
/// material falls back to toon.
public protocol SourceShaderLiveTextureProvider: AnyObject, Sendable {
    /// Short label reported with every material (`native texture store`, …).
    var label: String { get }
    func texture(_ request: SourceShaderLiveTextureRequest, resources: ResourceStore) -> Result<SourceShaderLiveTexture, SourceShaderLiveReason>
}

/// Native texture store written by `Tools/reverse/source_texture_store.py`:
/// each `Texture2D` the binding set names, decoded from the local game bundle
/// (authored mip chain, `m_ColorSpace` sRGB textures linearized as the GPU's
/// sRGB sampling would) into linear half-float levels, keyed by bundle and
/// `pathID`. Runtime composites (`CustomTextureCreate` render targets) are not
/// in the store; they are reported unavailable.
public final class SourceShaderTextureStore: SourceShaderLiveTextureProvider, @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public let bundle: String
        public let bundleSHA256: String
        public let name: String
        public let pathID: String
        public let serializedFile: String?
        public let width: Int, height: Int, mipLevels: Int
        public let colorSpace: String
        public let textureFormat: Int
        public let filter: String?, wrap: String?, aniso: Int?
        /// Level files (`level-0.rgba16f` …) relative to `directory`.
        public let directory: String
        public let files: [String]
        public let sha256: [String]
    }
    public struct Manifest: Codable, Sendable {
        public let schemaVersion: Int
        public let encoding: String
        public let entries: [Entry]
    }

    public let label = "native texture store"
    public let url: URL
    public let manifest: Manifest
    private let byPath: [String: Entry]
    private let byName: [String: [Entry]]

    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1, manifest.encoding == "linear-rgba16f-little-endian-bottom-up" else {
            throw SourceShaderLiveReason("Unsupported source texture store \(url.path)")
        }
        self.url = url; self.manifest = manifest
        var byPath: [String: Entry] = [:], byName: [String: [Entry]] = [:], levelPaths = Set<String>()
        for entry in manifest.entries {
            guard (1...4096).contains(entry.width), (1...4096).contains(entry.height),
                  (1...(1 + Int(log2(Double(max(entry.width, entry.height)))))).contains(entry.mipLevels),
                  entry.files.count == entry.mipLevels, entry.sha256.count == entry.mipLevels,
                  Self.safeComponent(entry.directory), entry.files.allSatisfy(Self.safeComponent),
                  Set(entry.files).count == entry.files.count else {
                throw SourceShaderLiveReason("Malformed texture store entry \(entry.name)")
            }
            // The converter gives each asset its own directory. Reject
            // aliases so path-only verification/upload caches cannot apply
            // one entry's dimensions or digest to another entry's pixels.
            guard entry.files.allSatisfy({ levelPaths.insert(entry.directory + "/" + $0).inserted }) else {
                throw SourceShaderLiveReason("Shared level path in texture store entry \(entry.name)")
            }
            guard byPath[entry.bundle + "#" + entry.pathID] == nil else { throw SourceShaderLiveReason("Duplicate store entry \(entry.bundle)#\(entry.pathID)") }
            byPath[entry.bundle + "#" + entry.pathID] = entry
            byName[entry.bundle + "/" + entry.name, default: []].append(entry)
        }
        self.byPath = byPath; self.byName = byName
    }

    public func texture(_ request: SourceShaderLiveTextureRequest, resources: ResourceStore) -> Result<SourceShaderLiveTexture, SourceShaderLiveReason> {
        let identity = request.identity
        guard identity.kind == .asset else {
            return .failure(.init("runtime composite \(identity.creator ?? identity.name ?? "texture") is not composed natively for the live path"))
        }
        guard let bundle = identity.bundle else { return .failure(.init("texture \(identity.name ?? "?") has no bundle identity")) }
        let entry: Entry
        if let pathID = identity.pathID {
            guard let found = byPath[bundle + "#" + pathID] else { return .failure(.init("\(bundle) is not in the native texture store (\(identity.name ?? pathID))")) }
            entry = found
        } else if let name = identity.name {
            let candidates = byName[bundle + "/" + name] ?? []
            guard candidates.count == 1 else {
                return .failure(.init(candidates.isEmpty ? "\(bundle)/\(name) is not in the native texture store" : "\(bundle)/\(name) is ambiguous in the native texture store"))
            }
            entry = candidates[0]
        } else { return .failure(.init("texture in \(bundle) has neither pathID nor name")) }
        if let expected = identity.bundleSHA256, expected != entry.bundleSHA256 {
            return .failure(.init("\(bundle) in the texture store has a different SHA-256 than the binding identity"))
        }
        if let name = identity.name, name != entry.name { return .failure(.init("\(entry.name) store name differs from the binding identity")) }
        if let file = identity.serializedFile, file != entry.serializedFile { return .failure(.init("\(entry.name) store serialized file differs")) }
        if let width = identity.width, width != entry.width { return .failure(.init("\(entry.name) store width differs")) }
        if let height = identity.height, height != entry.height { return .failure(.init("\(entry.name) store height differs")) }
        if let levels = identity.mipLevels, levels != entry.mipLevels { return .failure(.init("\(entry.name) store mip count differs")) }
        // One upload per store entry and resource store: several characters
        // (or a rebuilt assembly) share the GPU texture. Serialize cold misses
        // too; concurrent assembly construction must not upload duplicates.
        lock.lock(); defer { lock.unlock() }
        let owner = ObjectIdentifier(resources), cacheKey = entry.bundle + "#" + entry.pathID
        let cache: Uploads
        if let existing = uploaded[owner], existing.owner === resources {
            cache = existing
        } else {
            // A store may outlive a renderer. Weak ownership avoids retaining
            // old renderers and checking it prevents recycled object IDs from
            // returning another resource store's textures.
            uploaded = uploaded.filter { $0.value.owner != nil }
            cache = Uploads(owner: resources); uploaded[owner] = cache
        }
        if let cached = cache.textures[cacheKey] { return .success(cached) }
        do {
            let folder = url.deletingLastPathComponent().appendingPathComponent(entry.directory)
            let first = folder.appendingPathComponent(entry.files[0])
            // Hash every level once per immutable store, then load through the probe's
            // half-float loader (same bottom-up layout and authored-mip rule).
            for (level, pair) in zip(entry.files, entry.sha256).enumerated() {
                let (file, digest) = pair
                let key = folder.appendingPathComponent(file).path
                if verified.contains(key) { continue }
                let data = try Data(contentsOf: folder.appendingPathComponent(file))
                guard data.count == max(1, entry.width >> level) * max(1, entry.height >> level) * 8 else {
                    return .failure(.init("\(entry.name) store level \(file) byte count differs"))
                }
                guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
                    return .failure(.init("\(entry.name) store level \(file) does not match its SHA-256"))
                }
                verified.insert(key)
            }
            let handle = try loadOriginalProbeTexture(url: first, metadata: [
                "exportEncoding": "linear-rgba16f-little-endian-bottom-up", "width": entry.width, "height": entry.height,
                "mipLevels": entry.mipLevels, "mipFiles": entry.files], resources: resources)
            guard let texture = resources.texture(handle) else { return .failure(.init("\(entry.name) texture upload failed")) }
            let result = SourceShaderLiveTexture(texture: texture, filter: entry.filter, wrap: entry.wrap, aniso: entry.aniso,
                                                 provenance: "\(entry.bundle)#\(entry.pathID) (\(entry.colorSpace))")
            cache.textures[cacheKey] = result
            return .success(result)
        } catch { return .failure(.init("\(entry.name) store load failed: \(error)")) }
    }
    private static func safeComponent(_ path: String) -> Bool {
        !path.isEmpty && path == (path as NSString).lastPathComponent && !path.hasPrefix(".")
    }
    private final class Uploads {
        weak var owner: ResourceStore?
        var textures: [String: SourceShaderLiveTexture] = [:]
        init(owner: ResourceStore) { self.owner = owner }
    }
    private let lock = NSLock()
    private var verified = Set<String>()
    private var uploaded: [ObjectIdentifier: Uploads] = [:]
}

/// VALIDATION ONLY. Takes pixels from an original-player capture
/// (`frame-mips.json` texture rows) for the material slot the request names,
/// accepted only when the captured texture's type, name and size match the
/// native identity — the #102 substitution rule. Used to measure the live
/// path independently of native asset-store coverage (including runtime
/// composites); never a production texture source.
public final class SourceShaderCaptureTextureProvider: SourceShaderLiveTextureProvider, @unchecked Sendable {
    public let label = "capture pixels matched by native identity (validation only)"
    public let frameURL: URL
    private let rows: [String: [String: Any]]
    private let materials: [String: [[String: Any]]]
    private let globals: [String: Any]

    public init(frameURL: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: frameURL)) as? [String: Any],
              let textures = root["textures"] as? [[String: Any]], let meshes = root["meshes"] as? [[String: Any]] else {
            throw SourceShaderLiveReason("Capture frame lacks textures or meshes")
        }
        self.frameURL = frameURL
        var rows: [String: [String: Any]] = [:]
        for row in textures { if let file = row["file"] as? String { rows[file] = row } }
        var materials: [String: [[String: Any]]] = [:]
        for mesh in meshes {
            guard let name = mesh["name"] as? String, let list = mesh["materials"] as? [[String: Any]] else { continue }
            // Two renderers with one name (inner/outer shoes) cannot be told apart by name.
            materials[name] = materials[name] == nil ? list : []
        }
        self.rows = rows; self.materials = materials; self.globals = root["globals"] as? [String: Any] ?? [:]
    }

    public func texture(_ request: SourceShaderLiveTextureRequest, resources: ResourceStore) -> Result<SourceShaderLiveTexture, SourceShaderLiveReason> {
        let file: String?
        if let mesh = request.mesh, let slot = request.slot {
            guard let list = materials[mesh], !list.isEmpty else { return .failure(.init("capture has no unique renderer \(mesh)")) }
            guard list.indices.contains(slot) else { return .failure(.init("capture renderer \(mesh) has no material slot \(slot)")) }
            file = ((list[slot]["properties"] as? [String: Any])?[request.property] as? [String: Any])?["file"] as? String
        } else { file = globals[request.property] as? String }
        guard let file, let row = rows[file] else { return .failure(.init("capture binds no texture to \(request.property)")) }
        let identity = request.identity
        guard row["textureType"] as? String == (identity.kind == .asset ? "Texture2D" : "RenderTexture"),
              identity.kind != .asset || identity.name == row["name"] as? String,
              identity.width.map({ $0 == (row["width"] as? NSNumber)?.intValue }) ?? true,
              identity.height.map({ $0 == (row["height"] as? NSNumber)?.intValue }) ?? true else {
            return .failure(.init("captured \(request.property) is not the native identity \(identity.name ?? identity.creator ?? "?")"))
        }
        do {
            let handle = try loadOriginalProbeTexture(url: frameURL.deletingLastPathComponent().appendingPathComponent(file), metadata: row, resources: resources)
            guard let texture = resources.texture(handle) else { return .failure(.init("capture texture upload failed")) }
            return .success(SourceShaderLiveTexture(texture: texture, filter: row["filter"] as? String, wrap: row["wrap"] as? String,
                                                    aniso: (row["aniso"] as? NSNumber)?.intValue, provenance: "capture \(file)"))
        } catch { return .failure(.init("capture texture \(file): \(error)")) }
    }
}

/// Source vertex channels the converted rigs do not (always) carry: Unity
/// `TEXCOORD3` (`m_UV3`), `COLOR` (`m_Colors`) and `TEXCOORD1`/`TEXCOORD2`
/// (`m_UV1`/`m_UV2`) of one source mesh, in the source vertex order the
/// converted mesh keeps (`Tools/reverse/source_vertex_streams.py`). UV1/UV2
/// are used only where the converted mesh carries none (it would alias UV0).
public final class SourceVertexStreams: @unchecked Sendable {
    public let mesh: String
    public let vertexCount: Int
    /// float2 per vertex, Unity convention (no V flip); nil when the source
    /// mesh has no such channel.
    public let uv1: (any MTLBuffer)?, uv2: (any MTLBuffer)?, uv3: (any MTLBuffer)?
    /// float4 per vertex.
    public let colors: (any MTLBuffer)?
    public let provenance: String
    public init(mesh: String, vertexCount: Int, uv1: (any MTLBuffer)? = nil, uv2: (any MTLBuffer)? = nil,
                uv3: (any MTLBuffer)?, colors: (any MTLBuffer)?, provenance: String) {
        self.mesh = mesh; self.vertexCount = vertexCount; self.uv1 = uv1; self.uv2 = uv2; self.uv3 = uv3; self.colors = colors
        self.provenance = provenance
    }

    public struct Manifest: Codable, Sendable {
        public struct Entry: Codable, Sendable {
            public let mesh: String
            public let bundle: String
            public let bundleSHA256: String
            public let pathID: String
            public let vertexCount: Int
            /// `nil` when the source mesh has no such channel (UV1/UV2 are
            /// absent from schema 1 manifests).
            public let uv1File: String?, uv1SHA256: String?
            public let uv2File: String?, uv2SHA256: String?
            public let uv3File: String?, uv3SHA256: String?
            public let colorsFile: String?, colorsSHA256: String?
        }
        public let schemaVersion: Int
        public let entries: [Entry]
    }

    /// Loads every stream in `manifest.json` (hash-checked) for `device`.
    public static func load(manifest url: URL, device: any MTLDevice) throws -> [String: [SourceVertexStreams]] {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard (1...2).contains(manifest.schemaVersion) else { throw SourceShaderLiveReason("Unsupported vertex stream manifest") }
        var result: [String: [SourceVertexStreams]] = [:]
        func buffer(_ file: String?, _ digest: String?, stride: Int, count: Int) throws -> (any MTLBuffer)? {
            guard let file else { return nil }
            guard file == (file as NSString).lastPathComponent, !file.hasPrefix(".") else { throw SourceShaderLiveReason("Unsafe stream file name") }
            let data = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(file))
            guard data.count == stride * count, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
                throw SourceShaderLiveReason("Vertex stream \(file) length or SHA-256 mismatch")
            }
            return data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: data.count, options: .storageModeShared) }
        }
        for entry in manifest.entries {
            let streams = SourceVertexStreams(mesh: entry.mesh, vertexCount: entry.vertexCount,
                uv1: try buffer(entry.uv1File, entry.uv1SHA256, stride: 8, count: entry.vertexCount),
                uv2: try buffer(entry.uv2File, entry.uv2SHA256, stride: 8, count: entry.vertexCount),
                uv3: try buffer(entry.uv3File, entry.uv3SHA256, stride: 8, count: entry.vertexCount),
                colors: try buffer(entry.colorsFile, entry.colorsSHA256, stride: 16, count: entry.vertexCount),
                provenance: "\(entry.bundle)#\(entry.pathID)")
            result[entry.mesh, default: []].append(streams)
        }
        return result
    }
}

/// Inputs the binding set leaves unresolved that the live path binds anyway,
/// each with the documented reason. Every material that uses one lists it in
/// its `conventions`, so nothing is substituted silently.
public struct SourceShaderLiveConventions: Sendable {
    public var globalVectors: [String: (values: [Float], note: String)]
    public init(globalVectors: [String: (values: [Float], note: String)]) { self.globalVectors = globalVectors }
    /// `_RampG_ST`: `ChaShader.ChangeRampTexture` sets only the texture, and
    /// Unity's value for an unset global `_ST` is not verified; the translated
    /// probe binds `[1, 1, 0, 0]`, the value under which its ramp-lit families
    /// match the original capture (R1 numbers).
    public static let probe = SourceShaderLiveConventions(globalVectors: [
        "_RampG_ST": ([1, 1, 0, 0], "_RampG_ST = [1,1,0,0], the translated probe's convention for the unset global ramp transform"),
    ])
}

/// One renderer material slot resolved for the live path: its translated
/// programs (outline before forward), every constant the programs read except
/// the per-frame ones (camera, light, viewport, `_Time`), and every texture
/// with its sampler state. Resolution is all-or-nothing: any unresolved input
/// throws a `SourceShaderLiveReason` and the slot stays toon.
public final class SourceShaderLiveMaterial: @unchecked Sendable {
    public let label: String
    /// Original shader family (`main_skin`).
    public let family: String
    public let queue: Int
    public let passes: [TranslatedSourceProgram]
    /// Bind-ready values (colour properties linearized as the probe does).
    let vectors: [String: [Float]]
    let textures: [String: (texture: any MTLTexture, sampler: any MTLSamplerState)]
    /// Inputs bound by a documented convention rather than the binding set.
    public let conventions: [String]
    /// Texture provenance, property → source.
    public let textureSources: [String: String]

    /// Per-frame uniforms the live encoder computes.
    public static let frameUniforms: Set<String> = ["_WorldSpaceCameraPos", "_WorldSpaceLightPos0", "_LightColor0", "_ScreenParams",
                                                    "unity_WorldTransformParams", "_Time"]

    init(label: String, family: String, queue: Int, passes: [TranslatedSourceProgram], vectors: [String: [Float]],
         textures: [String: (texture: any MTLTexture, sampler: any MTLSamplerState)], conventions: [String], textureSources: [String: String]) {
        self.label = label; self.family = family; self.queue = queue; self.passes = passes; self.vectors = vectors
        self.textures = textures; self.conventions = conventions; self.textureSources = textureSources
    }

    /// The shader family name of `Shader Forge/<family>`, or nil.
    public static func family(of shader: String?) -> String? {
        guard let shader, shader.hasPrefix("Shader Forge/"), shader.split(separator: "/").count == 2 else { return nil }
        return String(shader.split(separator: "/")[1])
    }

    /// Resolves one binding-set renderer slot. `programs` is the translated
    /// program directory (`<family>[_outline]/program.json`).
    public static func resolve(renderer: SourceShaderBindingSet.Renderer, bindings: SourceShaderBindingSet, programs: URL,
                               resources: ResourceStore, textures provider: any SourceShaderLiveTextureProvider,
                               anisotropicFiltering: String?, conventions: SourceShaderLiveConventions = .probe) throws -> SourceShaderLiveMaterial {
        let material = renderer.material
        let label = "\(renderer.mesh) slot \(renderer.materialSlot)"
        if let reason = material.unresolved { throw SourceShaderLiveReason(reason) }
        guard let family = family(of: material.shader) else { throw SourceShaderLiveReason("shader \(material.shader ?? "unresolved") is not a translated Shader Forge family") }
        let forward = programs.appendingPathComponent(family + "/program.json"), outline = programs.appendingPathComponent(family + "_outline/program.json")
        guard FileManager.default.fileExists(atPath: forward.path) else { throw SourceShaderLiveReason("no translated program for \(material.shader!)") }
        guard let queue = material.queue else { throw SourceShaderLiveReason("render queue not derived (\(material.queueSource))") }
        let cache = resources.translatedPipelines
        var passes: [TranslatedSourceProgram] = []
        do {
            if FileManager.default.fileExists(atPath: outline.path) { passes.append(try cache.program(url: outline)) }
            passes.append(try cache.program(url: forward))
        } catch { throw SourceShaderLiveReason("translated program unusable: \(error)") }
        let linear = TranslatedSourceProgram.linear
        var vectors: [String: [Float]] = [:], notes: [String] = []
        var textures: [String: (texture: any MTLTexture, sampler: any MTLSamplerState)] = [:], sources: [String: String] = [:]
        for program in passes {
            for buffer in program.vertex.constantBuffers + program.fragment.constantBuffers {
                for parameter in buffer.vectors where vectors[parameter.name] == nil && !frameUniforms.contains(parameter.name) {
                    let name = parameter.name
                    var value: [Float]
                    if let property = program.properties[name], property.type != 4 {
                        guard let entry = material.vectors[name] else { throw SourceShaderLiveReason("\(name) not derived") }
                        guard let values = entry.values else { throw SourceShaderLiveReason("\(name): \(entry.unresolved ?? "unresolved")") }
                        value = values
                        if property.type == 0 { for i in 0..<min(3, value.count) { value[i] = linear(value[i]) } }
                    } else if name.hasSuffix("_ST"), program.properties[String(name.dropLast(3))]?.type == 4 {
                        let base = String(name.dropLast(3))
                        guard let texture = material.textures[base] else { throw SourceShaderLiveReason("\(base) transform not derived") }
                        guard let scale = texture.scale, let offset = texture.offset, scale.count == 2, offset.count == 2 else {
                            throw SourceShaderLiveReason("\(name): \(texture.transformUnresolved ?? "unresolved")")
                        }
                        value = scale + offset
                    } else if let values = bindings.globalVectors[name]?.values {
                        value = values
                    } else if let convention = conventions.globalVectors[name] {
                        value = convention.values; notes.append(convention.note)
                    } else if name == "_ProjectionParams" || name.hasPrefix("unity_") || name.hasPrefix("glstate_") {
                        throw SourceShaderLiveReason("builtin \(name) is not computed by the live path")
                    } else {
                        throw SourceShaderLiveReason("global \(name): \(bindings.globalVectors[name]?.unresolved ?? "not derived")")
                    }
                    guard value.count >= parameter.dimension, value.allSatisfy(\.isFinite) else { throw SourceShaderLiveReason("\(name) has \(value.count) lanes") }
                    vectors[name] = value
                }
            }
            for parameter in program.vertex.textures + program.fragment.textures where textures[parameter.name] == nil {
                let name = parameter.name
                let identity: SourceShaderBindingSet.TextureIdentity?, request: (mesh: String?, slot: Int?)
                if program.properties[name]?.type == 4 {
                    guard let entry = material.textures[name] else { throw SourceShaderLiveReason("texture \(name) not derived") }
                    if let reason = entry.identityUnresolved { throw SourceShaderLiveReason("texture \(name): \(reason)") }
                    identity = entry.identity; request = (renderer.mesh, renderer.materialSlot)
                } else {
                    guard let entry = bindings.globalTextures[name] else { throw SourceShaderLiveReason("global texture \(name) not derived") }
                    if let reason = entry.identityUnresolved { throw SourceShaderLiveReason("global texture \(name): \(reason)") }
                    guard let found = entry.identity else { throw SourceShaderLiveReason("global texture \(name) has no identity") }
                    identity = found; request = (nil, nil)
                }
                var filter: String?, wrap: String?, aniso: Int?
                let gpuTexture: any MTLTexture
                if let identity {
                    switch provider.texture(.init(identity: identity, property: name, mesh: request.mesh, slot: request.slot), resources: resources) {
                    case .failure(let reason): throw SourceShaderLiveReason("texture \(name): \(reason.text)")
                    case .success(let found):
                        gpuTexture = found.texture; sources[name] = found.provenance
                        if let f = identity.filter, let w = identity.wrap, let a = identity.aniso { filter = f; wrap = w; aniso = a }
                        else if let f = found.filter, let w = found.wrap, let a = found.aniso {
                            filter = f; wrap = w; aniso = a; notes.append("\(name) sampler state from \(found.provenance)")
                        } else { throw SourceShaderLiveReason("texture \(name) sampler state not derived") }
                    }
                } else {
                    guard let kind = program.properties[name]?.defaultTexture else { throw SourceShaderLiveReason("texture \(name) has no Unity default") }
                    do { gpuTexture = try TranslatedSourceProgram.makeDefaultTexture(kind, device: resources.device) }
                    catch { throw SourceShaderLiveReason("default texture \(kind): \(error)") }
                    sources[name] = "Unity default \(kind)"
                }
                let descriptor = TranslatedSourceProgram.samplerDescriptor(filter: filter, wrap: wrap, aniso: aniso, anisotropicFiltering: anisotropicFiltering)
                guard let sampler = resources.device.makeSamplerState(descriptor: descriptor) else { throw SourceShaderLiveReason("sampler state for \(name)") }
                textures[name] = (gpuTexture, sampler)
            }
        }
        return SourceShaderLiveMaterial(label: label, family: family, queue: queue, passes: passes, vectors: vectors,
                                        textures: textures, conventions: Array(Set(notes)).sorted(), textureSources: sources)
    }
}

/// What a `RenderItem` carries when the opt-in live path draws it with the
/// translated original programs instead of the native toon shader. Items
/// without it render exactly as before.
public struct SourceShaderLiveDraw: @unchecked Sendable {
    public let material: SourceShaderLiveMaterial
    /// `TEXCOORD3`/`COLOR` channels; required when a pass reads them.
    public let streams: SourceVertexStreams?
    /// Per-frame material values (the Studio eye look's iris `_ST`).
    public var vectorOverrides: [String: [Float]]
    /// Stable draw order inside one queue (the binding set's renderer order,
    /// which follows the original renderer and material order).
    public var sourceOrder: Int
    public init(material: SourceShaderLiveMaterial, streams: SourceVertexStreams?, vectorOverrides: [String: [Float]] = [:], sourceOrder: Int) {
        self.material = material; self.streams = streams; self.vectorOverrides = vectorOverrides; self.sourceOrder = sourceOrder
    }
}
