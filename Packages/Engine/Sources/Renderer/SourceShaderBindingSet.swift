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
        /// The full recipe of a `runtimeComposite` the derivation can name
        /// input by input; `nil` for composites that are only described by
        /// `creator` (their inputs are not derived).
        public var composite: CompositeRecipe?
        public init(kind: Kind, name: String? = nil, bundle: String? = nil, bundleSHA256: String? = nil, serializedFile: String? = nil,
                    pathID: String? = nil, width: Int? = nil, height: Int? = nil, mipLevels: Int? = nil, creator: String? = nil,
                    filter: String? = nil, wrap: String? = nil, aniso: Int? = nil, composite: CompositeRecipe? = nil) {
            self.kind = kind; self.name = name; self.bundle = bundle; self.bundleSHA256 = bundleSHA256
            self.serializedFile = serializedFile; self.pathID = pathID; self.width = width; self.height = height
            self.mipLevels = mipLevels; self.creator = creator; self.filter = filter; self.wrap = wrap; self.aniso = aniso
            self.composite = composite
        }
    }

    /// One `CustomTextureCreate` render target, as the source builds it:
    /// `Initialize` loads the create material (`CommonLib.LoadAsset(createMatABName,
    /// createMatName)`) and makes an ARGB32 (sRGB) `RenderTexture` with
    /// `useMipMap`; the create method sets textures and colours on that
    /// material; `RebuildTextureAndSetMaterial` clears the target to transparent
    /// and runs `Graphics.Blit(texMain, createTex, matCreate, 0)` under
    /// `GL.sRGBWrite`. The target size, mip count and sampler state are on the
    /// owning `TextureIdentity`.
    public struct CompositeRecipe: Codable, Sendable, Equatable {
        /// The `ChaControl` method that rebuilds this target (cited).
        public var method: String
        /// Create material identity.
        public var material: String
        public var bundle: String
        public var bundleSHA256: String?
        public var serializedFile: String?
        public var pathID: String?
        /// Create material shader (`Shader Forge/create_eye`).
        public var shader: String?
        /// SHA-256 of the create pass's DXBC fragment program the derivation
        /// verified against the source (`head_material_contract.py`).
        public var programSHA256: String?
        /// Material textures after the create method's setters: `_MainTex`
        /// is `texMain`, the `Graphics.Blit` source. Scale/offset stay the
        /// create material's saved `m_TexEnvs`.
        public var textures: [String: Texture]
        /// Material vectors after the setters (Unity `Material` values:
        /// gamma-space colours, as the draw materials store them).
        public var vectors: [String: Vector]
        /// Why this recipe cannot be composed (unconverted create material,
        /// unverified program, ...).
        public var unresolved: String?
        public init(method: String, material: String, bundle: String, bundleSHA256: String? = nil, serializedFile: String? = nil,
                    pathID: String? = nil, shader: String? = nil, programSHA256: String? = nil,
                    textures: [String: Texture] = [:], vectors: [String: Vector] = [:], unresolved: String? = nil) {
            self.method = method; self.material = material; self.bundle = bundle; self.bundleSHA256 = bundleSHA256
            self.serializedFile = serializedFile; self.pathID = pathID; self.shader = shader; self.programSHA256 = programSHA256
            self.textures = textures; self.vectors = vectors; self.unresolved = unresolved
        }
    }
}
