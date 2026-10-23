import Foundation

/// Per-renderer, per-material inputs of the translated original programs, as
/// derived from native data (card, Maker library, converted asset contracts).
/// This is a data model only: `SourceShaderBindingDerivation` (Character)
/// fills it without reading an original-player capture, and
/// `SourceShaderBindingComparison` compares it with one afterwards.
///
/// Material values are stored exactly as a Unity `Material` would hold them
/// (gamma-space colours, unscaled floats); colour linearization stays a
/// bind-time step, as in `TranslatedSourceShaderProbe`. Every input that the
/// native data cannot supply carries an explicit `unresolved` reason instead
/// of a substitute value.
public struct SourceShaderBindingSet: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var scope: String
    /// Input identities (file paths and SHA-256) the derivation read.
    public var provenance: [String: String]
    public var renderers: [Renderer]
    /// Undeclared (`Shader.SetGlobal*`) vectors and textures.
    public var globalVectors: [String: Vector]
    public var globalTextures: [String: Texture]
    public var diagnostics: [String]

    public init(scope: String, provenance: [String: String] = [:], renderers: [Renderer] = [],
                globalVectors: [String: Vector] = [:], globalTextures: [String: Texture] = [:], diagnostics: [String] = []) {
        schemaVersion = 1; self.scope = scope; self.provenance = provenance; self.renderers = renderers
        self.globalVectors = globalVectors; self.globalTextures = globalTextures; self.diagnostics = diagnostics
    }

    /// One material slot of one renderer. Unity draws the last submesh once
    /// per material beyond the submesh count, so `submesh` can repeat.
    public struct Renderer: Codable, Sendable, Equatable {
        /// Renderer GameObject name (the capture's mesh-row `name`).
        public var mesh: String
        /// Source component, for example `hair.back 101:2` or `head 0`.
        public var component: String
        public var materialSlot: Int
        public var submesh: Int
        public var visible: Bool
        /// The visibility rule applied and its source inputs.
        public var visibility: String
        public var material: Material
        public init(mesh: String, component: String, materialSlot: Int, submesh: Int, visible: Bool, visibility: String, material: Material) {
            self.mesh = mesh; self.component = component; self.materialSlot = materialSlot; self.submesh = submesh
            self.visible = visible; self.visibility = visibility; self.material = material
        }
    }

    public struct Material: Codable, Sendable, Equatable {
        public var name: String?
        public var shader: String?
        public var queue: Int?
        public var queueSource: String
        public var keywords: [String]?
        public var keywordsSource: String
        /// Pass name → constant pass state from the converted material evidence.
        public var passStates: [String: [String: Int]]?
        public var vectors: [String: Vector]
        public var textures: [String: Texture]
        /// Set when no converted material evidence exists for this slot.
        public var unresolved: String?
        public init(name: String? = nil, shader: String? = nil, queue: Int? = nil, queueSource: String = "unresolved",
                    keywords: [String]? = nil, keywordsSource: String = "unresolved", passStates: [String: [String: Int]]? = nil,
                    vectors: [String: Vector] = [:], textures: [String: Texture] = [:], unresolved: String? = nil) {
            self.name = name; self.shader = shader; self.queue = queue; self.queueSource = queueSource
            self.keywords = keywords; self.keywordsSource = keywordsSource; self.passStates = passStates
            self.vectors = vectors; self.textures = textures; self.unresolved = unresolved
        }
    }

    public struct Vector: Codable, Sendable, Equatable {
        public var values: [Float]?
        public var source: String
        public var unresolved: String?
        public init(_ values: [Float], source: String) { self.values = values; self.source = source; unresolved = nil }
        public init(unresolved reason: String) { values = nil; source = "unresolved"; unresolved = reason }
    }

    public struct Texture: Codable, Sendable, Equatable {
        /// `nil` with no `identityUnresolved` reason means "no texture bound":
        /// the program samples its Unity default texture.
        public var identity: TextureIdentity?
        public var identitySource: String
        public var identityUnresolved: String?
        public var scale: [Float]?
        public var offset: [Float]?
        public var transformSource: String
        public var transformUnresolved: String?
        public init(identity: TextureIdentity?, identitySource: String, identityUnresolved: String? = nil,
                    scale: [Float]?, offset: [Float]?, transformSource: String, transformUnresolved: String? = nil) {
            self.identity = identity; self.identitySource = identitySource; self.identityUnresolved = identityUnresolved
            self.scale = scale; self.offset = offset; self.transformSource = transformSource; self.transformUnresolved = transformUnresolved
        }
    }

    /// Exact source identity of a texture asset, or the recipe of a texture
    /// the source composes at runtime (`CustomTextureCreate` render targets).
    public struct TextureIdentity: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case asset, runtimeComposite }
        public var kind: Kind
        public var name: String?
        public var bundle: String?
        public var bundleSHA256: String?
        public var serializedFile: String?
        public var pathID: String?
        public var width: Int?
        public var height: Int?
        public var mipLevels: Int?
        /// Creating material and inputs for `runtimeComposite`.
        public var creator: String?
        /// Sampler state; `nil` when no converted contract records it.
        public var filter: String?
        public var wrap: String?
        public var aniso: Int?
        public init(kind: Kind, name: String? = nil, bundle: String? = nil, bundleSHA256: String? = nil, serializedFile: String? = nil,
                    pathID: String? = nil, width: Int? = nil, height: Int? = nil, mipLevels: Int? = nil, creator: String? = nil,
                    filter: String? = nil, wrap: String? = nil, aniso: Int? = nil) {
            self.kind = kind; self.name = name; self.bundle = bundle; self.bundleSHA256 = bundleSHA256
            self.serializedFile = serializedFile; self.pathID = pathID; self.width = width; self.height = height
            self.mipLevels = mipLevels; self.creator = creator; self.filter = filter; self.wrap = wrap; self.aniso = aniso
        }
    }
}
