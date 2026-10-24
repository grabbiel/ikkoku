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
    /// The player's `QualitySettings.anisotropicFiltering`, for samplers a
    /// provider builds itself (composite inputs).
    public let anisotropicFiltering: String?
    public init(identity: SourceShaderBindingSet.TextureIdentity, property: String, mesh: String?, slot: Int?, anisotropicFiltering: String? = nil) {
        self.identity = identity; self.property = property; self.mesh = mesh; self.slot = slot; self.anisotropicFiltering = anisotropicFiltering
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
/// `pathID`. Runtime composites (`CustomTextureCreate` render targets) hold no
/// pixels in the store. A composite whose binding identity carries its recipe
/// is composed on the GPU (`SourceShaderCompositor`) from store inputs and the
/// store's translated create program (schema 2 `composites`); any other
/// composite is reported unavailable.
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
    /// A translated `CustomTextureCreate` fragment program (schema 2): the
    /// create material identity, its verified DXBC program hash and the
    /// `program.json`/`source.metal` pair with their SHA-256.
    public struct Composite: Codable, Sendable {
        public let material: String
        public let bundle: String
        public let bundleSHA256: String
        public let serializedFile: String
        public let pathID: String
        public let shader: String
        public let programSHA256: String
        public let directory: String
        public let files: [String]
        public let sha256: [String]
    }
    public struct Manifest: Codable, Sendable {
        public let schemaVersion: Int
        public let encoding: String
        public let entries: [Entry]
        public let composites: [Composite]?
    }
    /// One composition (or composite cache hit) since the store was loaded.
    public struct CompositeEvent: Sendable, Encodable {
        public let creator: String
        public let contentKey: String
        public let cacheHit: Bool
        public let statistics: SourceShaderCompositor.Statistics?
    }

    public let label = "native texture store"
    public let url: URL
    public let manifest: Manifest
    private let byPath: [String: Entry]
    private let byName: [String: [Entry]]

    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard (1...2).contains(manifest.schemaVersion), manifest.encoding == "linear-rgba16f-little-endian-bottom-up",
              manifest.schemaVersion == 2 || manifest.composites == nil else {
            throw SourceShaderLiveReason("Unsupported source texture store \(url.path)")
        }
        self.url = url; self.manifest = manifest
        var byPath: [String: Entry] = [:], byName: [String: [Entry]] = [:], levelPaths = Set<String>()
        for entry in manifest.entries {
            guard (1...4096).contains(entry.width), (1...4096).contains(entry.height),
                  (1...(1 + Int(log2(Double(max(entry.width, entry.height)))))).contains(entry.mipLevels),
                  entry.files.count == entry.mipLevels, entry.sha256.count == entry.mipLevels,
                  entry.sha256.allSatisfy(Self.validDigest),
                  Self.safeComponent(entry.directory), entry.files.allSatisfy(Self.safeComponent),
                  Set(entry.files).count == entry.files.count else {
                throw SourceShaderLiveReason("Malformed texture store entry \(entry.name)")
            }
            // The converter gives each asset its own directory. Reject
            // conflicting asset declarations for a single level file.
            guard entry.files.allSatisfy({ levelPaths.insert(entry.directory + "/" + $0).inserted }) else {
                throw SourceShaderLiveReason("Shared level path in texture store entry \(entry.name)")
            }
            guard byPath[entry.bundle + "#" + entry.pathID] == nil else { throw SourceShaderLiveReason("Duplicate store entry \(entry.bundle)#\(entry.pathID)") }
            byPath[entry.bundle + "#" + entry.pathID] = entry
            byName[entry.bundle + "/" + entry.name, default: []].append(entry)
        }
        var programs: [String: Composite] = [:]
        for composite in manifest.composites ?? [] {
            guard Self.safeComponent(composite.directory), composite.files == ["program.json", "source.metal"],
                  composite.sha256.count == 2, composite.sha256.allSatisfy(Self.validDigest), Self.validDigest(composite.programSHA256),
                  !levelPaths.contains(where: { $0.hasPrefix(composite.directory + "/") }) else {
                throw SourceShaderLiveReason("Malformed composite program entry \(composite.material)")
            }
            let key = composite.bundle + "#" + composite.pathID + "#" + composite.programSHA256
            guard programs[key] == nil else { throw SourceShaderLiveReason("Duplicate composite program \(composite.material)") }
            programs[key] = composite
        }
        self.byPath = byPath; self.byName = byName; self.programs = programs
    }

    public func texture(_ request: SourceShaderLiveTextureRequest, resources: ResourceStore) -> Result<SourceShaderLiveTexture, SourceShaderLiveReason> {
        let identity = request.identity
        guard identity.kind == .asset else { return composite(request, resources: resources) }
        let entry: Entry
        switch self.entry(for: identity) {
        case .failure(let reason): return .failure(reason)
        case .success(let found): entry = found
        }
        return upload(entry, resources: resources)
    }

    /// The store entry for an asset identity: matched by bundle and path ID
    /// (else a unique name), with every recorded identity field checked.
    func entry(for identity: SourceShaderBindingSet.TextureIdentity) -> Result<Entry, SourceShaderLiveReason> {
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
        return .success(entry)
    }

    static func contentKey(_ entry: Entry) -> String {
        "source-native-linear-half-v1#\(entry.width)x\(entry.height)#\(entry.mipLevels)#" + entry.sha256.joined(separator: "#")
    }

    private func uploads(_ resources: ResourceStore) -> Uploads {
        // Caller holds `lock`.
        let owner = ObjectIdentifier(resources)
        if let existing = uploaded[owner], existing.owner === resources { return existing }
        // A store may outlive a renderer. Weak ownership avoids retaining
        // old renderers and checking it prevents recycled object IDs from
        // returning another resource store's textures.
        uploaded = uploaded.filter { $0.value.owner != nil }
        let cache = Uploads(owner: resources); uploaded[owner] = cache
        return cache
    }

    private func upload(_ entry: Entry, resources: ResourceStore) -> Result<SourceShaderLiveTexture, SourceShaderLiveReason> {
        // One upload per store entry and resource store: several characters
        // (or a rebuilt assembly) share the GPU texture. Serialize cold misses
        // too; concurrent assembly construction must not upload duplicates.
        lock.lock(); defer { lock.unlock() }
        let cacheKey = entry.bundle + "#" + entry.pathID
        let cache = uploads(resources)
        if let cached = cache.textures[cacheKey] { return .success(cached) }
        do {
            let contentKey = Self.contentKey(entry)
            let handle: TextureHandle
            if let existing = resources.lookup(key: contentKey) {
                // A newly constructed store can reuse previously verified
                // content even when its manifest lives at another path.
                handle = existing
            } else {
                let folder = url.deletingLastPathComponent().appendingPathComponent(entry.directory)
                var levels: [Data] = []
                for (level, pair) in zip(entry.files, entry.sha256).enumerated() {
                    let (file, digest) = pair
                    let data = try Data(contentsOf: folder.appendingPathComponent(file))
                    guard data.count == max(1, entry.width >> level) * max(1, entry.height >> level) * 8 else {
                        return .failure(.init("\(entry.name) store level \(file) byte count differs"))
                    }
                    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
                        return .failure(.init("\(entry.name) store level \(file) does not match its SHA-256"))
                    }
                    levels.append(data)
                }
                handle = try uploadOriginalProbeTexture(levels: levels, width: entry.width, height: entry.height, mipLevels: entry.mipLevels,
                                                       generateMips: false, cacheKey: contentKey, resources: resources)
            }
            guard let texture = resources.texture(handle) else { return .failure(.init("\(entry.name) texture upload failed")) }
            let result = SourceShaderLiveTexture(texture: texture, filter: entry.filter, wrap: entry.wrap, aniso: entry.aniso,
                                                 provenance: "\(entry.bundle)#\(entry.pathID) (\(entry.colorSpace))")
            cache.textures[cacheKey] = result
            return .success(result)
        } catch { return .failure(.init("\(entry.name) store load failed: \(error)")) }
    }
    private func compositeDefault(_ kind: String, resources: ResourceStore) throws -> any MTLTexture {
        lock.lock(); defer { lock.unlock() }
        let cache = uploads(resources)
        if let texture = cache.defaults[kind] { return texture }
        // Only the four supported Unity defaults can enter this cache.
        let texture = try TranslatedSourceProgram.makeDefaultTexture(kind, device: resources.device)
        cache.defaults[kind] = texture
        return texture
    }

    private func compositeSampler(_ configuration: TranslatedSourceProgram.SamplerConfiguration, resources: ResourceStore) -> (any MTLSamplerState)? {
        lock.lock(); defer { lock.unlock() }
        let cache = uploads(resources)
        if let sampler = cache.samplers[configuration] { return sampler }
        guard let sampler = resources.device.makeSamplerState(descriptor: configuration.makeDescriptor()) else { return nil }
        cache.samplers[configuration] = sampler
        return sampler
    }

    // Test visibility for allocations not registered in ResourceStore. The
    // fixed defaults and normalized sampler combinations are bounded; no
    // composite colour or recipe content enters either key.
    struct CompositeInputStatistics: Equatable {
        let defaults: Int
        let samplers: Int
    }
    func compositeInputStatistics(for resources: ResourceStore) -> CompositeInputStatistics {
        lock.lock(); defer { lock.unlock() }
        guard let cache = uploaded[ObjectIdentifier(resources)], cache.owner === resources else {
            return .init(defaults: 0, samplers: 0)
        }
        return .init(defaults: cache.defaults.count, samplers: cache.samplers.count)
    }

    /// Composes a `CustomTextureCreate` target from its recipe (R1/CMT-04):
    /// the store's translated create program, the recipe's textures from the
    /// store (or the program's Unity defaults where the recipe binds none) and
    /// its vectors (colours linearized as a linear-space player binds them).
    /// All-or-nothing: any input the store or recipe cannot supply is the
    /// slot's fallback reason. The result is cached per resource store by a
    /// content key over the recipe version, the program, the target layout,
    /// every input's content key and sampler, and every vector's bits. The
    /// cache holds composites weakly: the materials that bind a composite own
    /// it, and it is released with them.
    private func composite(_ request: SourceShaderLiveTextureRequest, resources: ResourceStore) -> Result<SourceShaderLiveTexture, SourceShaderLiveReason> {
        let identity = request.identity
        let label = identity.creator ?? identity.name ?? "texture"
        guard let recipe = identity.composite else {
            return .failure(.init("runtime composite \(label) is not composed natively for the live path"))
        }
        func fail(_ text: String) -> Result<SourceShaderLiveTexture, SourceShaderLiveReason> {
            .failure(.init("runtime composite \(recipe.material): \(text)"))
        }
        if let reason = recipe.unresolved { return fail(reason) }
        guard let width = identity.width, let height = identity.height, let mipLevels = identity.mipLevels else { return fail("target size not derived") }
        guard let pathID = recipe.pathID, let programSHA = recipe.programSHA256 else { return fail("create material identity not derived") }
        guard let entry = programs[recipe.bundle + "#" + pathID + "#" + programSHA] else {
            return fail("create program \(programSHA) is not in the native texture store")
        }
        if let expected = recipe.bundleSHA256, expected != entry.bundleSHA256 { return fail("store create program comes from a different \(recipe.bundle)") }
        if recipe.shader != entry.shader || recipe.serializedFile != entry.serializedFile || recipe.material != entry.material {
            return fail("store create program identity differs from the recipe")
        }
        let program: TranslatedSourceProgram
        switch loadProgram(entry) {
        case .failure(let reason): return fail(reason.text)
        case .success(let loaded): program = loaded
        }
        // Inputs, resolved through the store exactly like material textures.
        var textures: [Int: any MTLTexture] = [:], samplers: [Int: any MTLSamplerState] = [:]
        var keyParts: [String] = [], provenance: [String] = []
        for parameter in program.fragment.textures {
            let name = parameter.name
            guard let binding = recipe.textures[name] else { return fail("input \(name) not derived") }
            if let reason = binding.identityUnresolved { return fail("input \(name): \(reason)") }
            let texture: any MTLTexture, filter: String?, wrap: String?, aniso: Int?, inputKey: String
            if let input = binding.identity {
                guard input.kind == .asset else { return fail("input \(name) is itself a runtime composite (not modelled)") }
                let found: Entry
                switch self.entry(for: input) {
                case .failure(let reason): return fail("input \(name): \(reason.text)")
                case .success(let value): found = value
                }
                switch upload(found, resources: resources) {
                case .failure(let reason): return fail("input \(name): \(reason.text)")
                case .success(let uploaded):
                    texture = uploaded.texture; provenance.append("\(name)=\(uploaded.provenance)")
                }
                if let f = input.filter, let w = input.wrap, let a = input.aniso { filter = f; wrap = w; aniso = a }
                else if let f = found.filter, let w = found.wrap, let a = found.aniso { filter = f; wrap = w; aniso = a }
                else { return fail("input \(name) sampler state not derived") }
                inputKey = Self.contentKey(found)
            } else {
                guard let kind = program.properties[name]?.defaultTexture else { return fail("input \(name) has no Unity default") }
                do { texture = try compositeDefault(kind, resources: resources) }
                catch { return fail("default texture \(kind): \(error)") }
                filter = nil; wrap = nil; aniso = nil; inputKey = "unity-default-" + kind
                provenance.append("\(name)=Unity default \(kind)")
            }
            let configuration = TranslatedSourceProgram.SamplerConfiguration(filter: filter, wrap: wrap, aniso: aniso, anisotropicFiltering: request.anisotropicFiltering)
            guard let sampler = compositeSampler(configuration, resources: resources) else { return fail("sampler state for \(name)") }
            textures[parameter.slot] = texture; samplers[parameter.samplerSlot] = sampler
            keyParts.append("t:\(name)@\(parameter.slot)/\(parameter.samplerSlot)=\(inputKey)|\(filter ?? "-")|\(wrap ?? "-")|\(aniso.map(String.init) ?? "-")|\(configuration.maxAnisotropy)|\(configuration.mipFilter.rawValue)")
        }
        // Constants: recipe vectors and the textures' saved transforms. The
        // create programs read no per-frame or global values; any other name
        // is a reason, never a default.
        var values: [String: [Float]] = [:]
        for buffer in program.fragment.constantBuffers {
            for parameter in buffer.vectors where values[parameter.name] == nil {
                let name = parameter.name
                var value: [Float]
                if let property = program.properties[name], property.type != 4 {
                    guard let vector = recipe.vectors[name] else { return fail("\(name) not derived") }
                    guard let found = vector.values else { return fail("\(name): \(vector.unresolved ?? "unresolved")") }
                    value = found
                    if property.type == 0 { for i in 0..<min(3, value.count) { value[i] = TranslatedSourceProgram.linear(value[i]) } }
                } else if name.hasSuffix("_ST"), program.properties[String(name.dropLast(3))]?.type == 4 {
                    let base = String(name.dropLast(3))
                    guard let texture = recipe.textures[base], let scale = texture.scale, let offset = texture.offset,
                          scale.count == 2, offset.count == 2 else { return fail("\(name) not derived") }
                    value = scale + offset
                } else {
                    return fail("create program reads \(name), which the compositor does not supply")
                }
                guard value.count >= parameter.dimension, value.allSatisfy(\.isFinite) else { return fail("\(name) has \(value.count) lanes") }
                values[name] = value
                keyParts.append("v:\(name)=" + value.prefix(parameter.dimension).map { String(format: "%08x", $0.bitPattern) }.joined(separator: ","))
            }
        }
        let buffers: [(slot: Int, data: [Float])]
        do {
            buffers = try TranslatedSourceProgram.pack(program.fragment, uniform: { name in
                guard let value = values[name] else { throw SourceShaderLiveReason("\(name) not resolved") }
                return value
            }, matrix: { name in throw SourceShaderLiveReason("create program matrix \(name) is not supplied") })
        } catch { return fail("\(error)") }
        let material = keyParts.sorted().joined(separator: "#")
        let contentKey = SHA256.hash(data: Data([
            Self.compositeRecipeVersion, programSHA, program.sourceSHA256, entry.sha256[0],
            "\(width)x\(height)", "\(mipLevels)", "rgba8Unorm_srgb", "clear-0000", material,
        ].joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
        let description = "composite \(recipe.material) \(width)x\(height) [\(contentKey.prefix(12))] from " + provenance.sorted().joined(separator: ", ")

        // Serialize compositions: concurrent assemblies with one content key
        // must share one GPU composite, and `lock` is not held while the
        // inputs upload (`upload` takes it).
        compositeLock.lock(); defer { compositeLock.unlock() }
        lock.lock()
        let cache = uploads(resources)
        if let cached = cache.composites[contentKey]?.texture {
            record(CompositeEvent(creator: label, contentKey: contentKey, cacheHit: true, statistics: nil))
            lock.unlock()
            return .success(SourceShaderLiveTexture(texture: cached, filter: nil, wrap: nil, aniso: nil, provenance: description))
        }
        cache.composites = cache.composites.filter { $0.value.texture != nil }
        let compositor = cache.compositor ?? SourceShaderCompositor(device: resources.device)
        cache.compositor = compositor
        lock.unlock()
        do {
            let (texture, statistics) = try compositor.compose(program: program, width: width, height: height, mipLevels: mipLevels,
                                                               textures: textures, samplers: samplers, buffers: buffers, label: recipe.material)
            lock.lock()
            cache.composites[contentKey] = WeakComposite(texture: texture, provenance: description)
            record(CompositeEvent(creator: label, contentKey: contentKey, cacheHit: false, statistics: statistics))
            lock.unlock()
            return .success(SourceShaderLiveTexture(texture: texture, filter: nil, wrap: nil, aniso: nil, provenance: description))
        } catch { return fail("composition failed: \(error)") }
    }

    /// Bumped whenever composition changes what a content key produces.
    static let compositeRecipeVersion = "source-composite-v1"

    /// The translated create program for a store entry, with both files
    /// checked against the manifest and the program's own DXBC and material
    /// identity checked against the entry. Loaded once per store.
    private func loadProgram(_ entry: Composite) -> Result<TranslatedSourceProgram, SourceShaderLiveReason> {
        lock.lock(); defer { lock.unlock() }
        if let loaded = loadedPrograms[entry.directory] { return .success(loaded) }
        let folder = url.deletingLastPathComponent().appendingPathComponent(entry.directory)
        do {
            for (file, digest) in zip(entry.files, entry.sha256) {
                let data = try Data(contentsOf: folder.appendingPathComponent(file))
                guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
                    return .failure(.init("create program \(file) does not match its SHA-256"))
                }
            }
            let programURL = folder.appendingPathComponent("program.json")
            guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: programURL)) as? [String: Any],
                  ((root["programs"] as? [String: Any])?["fragment"] as? [String: Any])?["sha256"] as? String == entry.programSHA256,
                  root["materialPathID"] as? String == entry.pathID, root["material"] as? String == entry.material,
                  root["bundleSHA256"] as? String == entry.bundleSHA256, root["name"] as? String == entry.shader else {
                return .failure(.init("create program identity differs from the store entry"))
            }
            let program = try TranslatedSourceProgram(url: programURL, fragmentOnly: true)
            loadedPrograms[entry.directory] = program
            return .success(program)
        } catch { return .failure(.init("create program unusable: \(error)")) }
    }

    private static func safeComponent(_ path: String) -> Bool {
        !path.isEmpty && path == (path as NSString).lastPathComponent && !path.hasPrefix(".")
    }
    private static func validDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private final class Uploads {
        weak var owner: ResourceStore?
        var textures: [String: SourceShaderLiveTexture] = [:]
        var defaults: [String: any MTLTexture] = [:]
        var samplers: [TranslatedSourceProgram.SamplerConfiguration: any MTLSamplerState] = [:]
        /// Composites are owned by the materials that bind them (never
        /// registered in the resource store): the cache only shares a live
        /// one between owners with the same content key.
        var composites: [String: WeakComposite] = [:]
        var compositor: SourceShaderCompositor?
        init(owner: ResourceStore) { self.owner = owner }
    }
    final class WeakComposite {
        weak var texture: (any MTLTexture)?
        let provenance: String
        init(texture: any MTLTexture, provenance: String) { self.texture = texture; self.provenance = provenance }
    }
    private let lock = NSLock()
    private let compositeLock = NSLock()
    private var uploaded: [ObjectIdentifier: Uploads] = [:]
    private let programs: [String: Composite]
    private var loadedPrograms: [String: TranslatedSourceProgram] = [:]
    private var events: [CompositeEvent] = []

    /// Compositions and cache hits so far, in order (the most recent 256).
    public func compositeEvents() -> [CompositeEvent] { lock.lock(); defer { lock.unlock() }; return events }
    /// Caller holds `lock`. A long Maker session must not grow the log without bound.
    private func record(_ event: CompositeEvent) {
        events.append(event)
        if events.count > 256 { events.removeFirst(events.count - 256) }
    }
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
                    switch provider.texture(.init(identity: identity, property: name, mesh: request.mesh, slot: request.slot,
                                                   anisotropicFiltering: anisotropicFiltering), resources: resources) {
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
