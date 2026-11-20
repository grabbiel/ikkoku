import Foundation
import Metal
import simd
import CoreMath
import Scene
import ShaderTypes

public struct MeshHandle: Hashable, Sendable { public let id: UInt32; public init(id: UInt32) { self.id = id } }
public struct TextureHandle: Hashable, Sendable { public let id: UInt32; public init(id: UInt32) { self.id = id } }

/// Everything a draw needs besides geometry. Plain data so it can be built on any thread.
public struct MaterialState: Sendable, Equatable {
    public var uniforms: MaterialUniforms
    public var base: TextureHandle?
    public var colorMask: TextureHandle?
    public var detail: TextureHandle?
    public var line: TextureHandle?
    public var normal: TextureHandle?
    public var overlay0: TextureHandle?
    public var overlay1: TextureHandle?
    public var overlay2: TextureHandle?
    public var pattern: TextureHandle?
    public var hairGloss: TextureHandle?
    public var bodyMask: TextureHandle?
    /// `MaterialKindMap` only (ST-A11 source maps): the baked lightmap, its
    /// CombinedDirectional direction map and the Standard emission map. The
    /// main pass binds them for map draws alone.
    public var lightmap: TextureHandle?
    public var lightmapDirection: TextureHandle?
    public var emission: TextureHandle?
    /// `MaterialKindSky` only (ST-A11 map sky): the Skybox/Cubemap `_Tex` cube,
    /// bound at `TextureIndexSkyCube` by the sky group alone.
    public var cubemap: TextureHandle?
    public var transparent: Bool = false     // draw in the transparent pass (blend)
    public var depthBias: Float = 0          // metres toward the camera (eyebrows over hair)

    public init(uniforms: MaterialUniforms) { self.uniforms = uniforms }

    public static func == (a: MaterialState, b: MaterialState) -> Bool {
        // Byte equality of the uniforms, as one memcmp: the render thread compares
        // neighbouring item records' materials every frame (ST-T04 instanced runs).
        withUnsafeBytes(of: a.uniforms) { ab in withUnsafeBytes(of: b.uniforms) { bb in memcmp(ab.baseAddress!, bb.baseAddress!, ab.count) == 0 } }
        && a.sameTexturesAndState(b)
    }

    /// `==` apart from `uniforms.baseColor`, without copying either material:
    /// the uniforms' bytes before and after the base colour, and the rest.
    /// Neighbouring static item records that pass merge into one instanced run
    /// (`Renderer.mergesWith`, ST-T04).
    func equalsApartFromBaseColor(_ other: MaterialState) -> Bool {
        withUnsafePointer(to: self) { a in withUnsafePointer(to: other) { b in Self.equalApartFromBaseColor(a, b) } }
    }

    /// `equalsApartFromBaseColor` on two materials read where they lie, such
    /// as inside draw records in their array's buffer (`Renderer.mergesWith`):
    /// the uniforms' bytes before and after the base colour, compared in
    /// place, and the rest field by field. The pointers are only read, and
    /// only for the duration of the call.
    @inline(__always)
    static func equalApartFromBaseColor(_ a: UnsafePointer<MaterialState>, _ b: UnsafePointer<MaterialState>) -> Bool {
        let colour = MemoryLayout<MaterialUniforms>.offset(of: \.baseColor)!, after = colour + MemoryLayout<Float4>.size
        let count = MemoryLayout<MaterialUniforms>.size, uniforms = MemoryLayout<MaterialState>.offset(of: \.uniforms)!
        let x = UnsafeRawPointer(a) + uniforms, y = UnsafeRawPointer(b) + uniforms
        return memcmp(x, y, colour) == 0 && memcmp(x + after, y + after, count - after) == 0 && sameTexturesAndState(a, b)
    }

    private func sameTexturesAndState(_ other: MaterialState) -> Bool {
        withUnsafePointer(to: self) { a in withUnsafePointer(to: other) { b in Self.sameTexturesAndState(a, b) } }
    }

    @inline(__always)
    private static func sameTexturesAndState(_ a: UnsafePointer<MaterialState>, _ b: UnsafePointer<MaterialState>) -> Bool {
        a.pointee.base == b.pointee.base && a.pointee.colorMask == b.pointee.colorMask && a.pointee.detail == b.pointee.detail
            && a.pointee.line == b.pointee.line && a.pointee.normal == b.pointee.normal
            && a.pointee.overlay0 == b.pointee.overlay0 && a.pointee.overlay1 == b.pointee.overlay1
            && a.pointee.overlay2 == b.pointee.overlay2 && a.pointee.pattern == b.pointee.pattern
            && a.pointee.hairGloss == b.pointee.hairGloss && a.pointee.bodyMask == b.pointee.bodyMask
            && a.pointee.lightmap == b.pointee.lightmap && a.pointee.lightmapDirection == b.pointee.lightmapDirection
            && a.pointee.emission == b.pointee.emission && a.pointee.cubemap == b.pointee.cubemap
            && a.pointee.transparent == b.pointee.transparent && a.pointee.depthBias == b.pointee.depthBias
    }

    /// All explicit texture references, without fallback textures.
    public var textureHandles: [TextureHandle] {
        var handles: [TextureHandle] = []
        forEachTextureHandle { handles.append($0) }
        return handles
    }

    /// Calls `body` with each explicit texture reference, in `textureHandles`
    /// order, without building an array (`RenderFrame.retainTextures` visits
    /// every item's handles each frame).
    @inline(__always)
    func forEachTextureHandle(_ body: (TextureHandle) -> Void) {
        if let base { body(base) }; if let colorMask { body(colorMask) }; if let detail { body(detail) }
        if let line { body(line) }; if let normal { body(normal) }; if let overlay0 { body(overlay0) }
        if let overlay1 { body(overlay1) }; if let overlay2 { body(overlay2) }; if let pattern { body(pattern) }
        if let hairGloss { body(hairGloss) }; if let bodyMask { body(bodyMask) }; if let lightmap { body(lightmap) }
        if let lightmapDirection { body(lightmapDirection) }; if let emission { body(emission) }; if let cubemap { body(cubemap) }
    }

    /// What the main pass binds a material's textures from: its kind and its
    /// handles (`Renderer.bindTextures`). Equal sets bind equal textures in one frame.
    struct TextureSet: Equatable {
        var kind: UInt32
        var base, colorMask, detail, line, normal, overlay0, overlay1, overlay2, pattern, hairGloss, bodyMask: TextureHandle?
        var lightmap, lightmapDirection, emission, cubemap: TextureHandle?
    }

    var textureSet: TextureSet {
        TextureSet(kind: uniforms.kind, base: base, colorMask: colorMask, detail: detail, line: line, normal: normal,
                   overlay0: overlay0, overlay1: overlay1, overlay2: overlay2, pattern: pattern, hairGloss: hairGloss,
                   bodyMask: bodyMask, lightmap: lightmap, lightmapDirection: lightmapDirection, emission: emission, cubemap: cubemap)
    }

    public var kind: MaterialKind { MaterialKind(rawValue: Int32(uniforms.kind)) }

    public mutating func setFlag(_ f: MaterialFlags, _ on: Bool) {
        if on { uniforms.flags |= f.rawValue } else { uniforms.flags &= ~f.rawValue }
    }
}

public struct RenderItem: Sendable {
    public var mesh: MeshHandle
    public var material: MaterialState
    public var model: float4x4
    public var objectID: UInt32
    /// Unique key for the deformed vertex buffer (per character instance + mesh). nil = static mesh.
    public var deformKey: UInt64?
    /// Key into `RenderFrame.skinSets` (one matrix set per character, shared by its meshes).
    public var skinSet: UInt64?
    public var morphWeights: [(index: Int, weight: Float)]
    public var castsShadow: Bool = true
    public var outline: Bool = true
    public var outlineScale: Float = 1
    public var visible: Bool = true
    /// Bitmask of body regions to hide (1 << regionID).
    public var hiddenRegions: UInt32 = 0
    /// Per-vertex hidden bytes uploaded via `ResourceStore.hiddenBuffer`; overrides `hiddenRegions` when set.
    public var hiddenKey: UInt64? = nil
    /// Draw ordering within a pass (lower first). Eyebrows/eyelashes use a high order.
    public var order: Int = 0
    /// Opt-in live source-shader draw (`IKKOKU_LIVE_SOURCE_SHADERS`): when set,
    /// the main pass draws this item with the translated original programs
    /// instead of the native toon shader. Shadow and pick passes keep the
    /// native draw. nil (the default) renders exactly as before.
    public var sourceShader: SourceShaderLiveDraw? = nil
    /// An item with `objectID` 0 that still hides what is behind it from the
    /// pick pass (ST-A11 source map geometry): it writes depth and id 0, so a
    /// pick or hover over its pixels selects nothing. Gizmos still draw on top.
    /// false (the default) leaves an id-0 item out of the pick pass, as before.
    public var pickOccluder: Bool = false
    /// The model-space point whose camera distance orders this item among the
    /// transparent draws (ST-A11 slice 4: a map particle renderer's Unity
    /// `Renderer.bounds` centre, which a mesh baked into map space no longer
    /// has). nil (the default) uses the mesh's bounds centre, as before.
    public var sortCenter: Float3? = nil
    /// Unity's render queue for a transparent draw: transparent draws sort by
    /// it first (lower first), then back to front. Every item is 3000 (the
    /// "Transparent" queue) unless set, so the order is unchanged without it;
    /// map particle materials carry their own (slice 4).
    public var renderQueue: Int = 3000
    /// A static Studio prop (ST-T04): the Studio frame builder sets it on the
    /// parts of `.item` objects and of source item placeholders, and only such
    /// records may merge into an instanced run (`Renderer.instanceable` still
    /// checks every condition). false (the default) keeps every other record,
    /// characters and maps included, on its own draw.
    public var staticItem: Bool = false
    /// Maps slice 5: per-vertex receive bytes (1 = receives the map sun's
    /// shadow) for a map mesh that mixes receivers, read under
    /// `MaterialFlagMapReceivePerVertex`. nil (the default) for every other
    /// draw, which binds the shared dummy and reads the material's flag.
    public var vertexReceive: VertexBytes? = nil

    public init(mesh: MeshHandle, material: MaterialState, model: float4x4, objectID: UInt32,
                deformKey: UInt64? = nil, skinSet: UInt64? = nil, morphWeights: [(index: Int, weight: Float)] = []) {
        self.mesh = mesh; self.material = material; self.model = model; self.objectID = objectID
        self.deformKey = deformKey; self.skinSet = skinSet; self.morphWeights = morphWeights
    }
}

/// One byte per vertex of a mesh, owned by whoever built it (ST-A11 maps:
/// the loaded map asset). A frame that names it keeps the buffer alive.
public struct VertexBytes: @unchecked Sendable, Equatable {
    public let buffer: any MTLBuffer
    public init(buffer: any MTLBuffer) { self.buffer = buffer }
    public static func == (a: VertexBytes, b: VertexBytes) -> Bool { a.buffer === b.buffer }
}

/// Maps slice 5: the loaded map's ambient and realtime sun for one frame
/// (`map_fragment`, `MapLightingUniforms`), and the sun's shadow casters for
/// the map shadow map. Built by the map's owner once per placement (record's
/// map transform, sun type and map option); nil draws no map lighting.
public struct MapLighting: Sendable {
    /// Unity's seven SH constants (`unity_SHAr` … `unity_SHC`) in the engine
    /// basis (z reflected). A flat-ambient map holds its colour in the three
    /// constant terms.
    public var sh: [Float4]
    public var sun: Sun?
    /// The sun's shadow casters (`Renderer.encodeMapShadow`); empty draws no
    /// map shadow map, and nothing is shadowed.
    public var casters: [MapShadowCaster] = []
    /// World bounds of every caster: the map shadow map's depth range.
    public var casterBounds: AABB = .empty
    /// Names this placement's casters and sun. The renderer redraws the map
    /// shadow map when it changes (and when the camera target moves away);
    /// equal revisions must mean equal casters and sun.
    public var revision: UInt64 = 0

    public struct Sun: Sendable, Equatable {
        /// Unit direction to the light, engine world.
        public var directionToLight: Float3
        /// `_LightColor0`: GammaToLinearSpace(colour × intensity), linear.
        public var color: Float3
        /// The light's shadow strength (1 − `_LightShadowData.r`); 0 when the
        /// light casts no shadows.
        public var shadowStrength: Float
        /// The light's shadow bias and normal bias, in Unity's units (scaled by
        /// the shadow map's world texel size when drawn).
        public var shadowBias: Float = 0
        public var shadowNormalBias: Float = 0
        public init(directionToLight: Float3, color: Float3, shadowStrength: Float, shadowBias: Float = 0, shadowNormalBias: Float = 0) {
            self.directionToLight = directionToLight; self.color = color; self.shadowStrength = shadowStrength
            self.shadowBias = shadowBias; self.shadowNormalBias = shadowNormalBias
        }
    }

    public init(sh: [Float4], sun: Sun?) {
        precondition(sh.count == 7, "MapLighting needs Unity's seven SH constants")
        self.sh = sh; self.sun = sun
    }
}

/// One draw of the map shadow map: index runs of a mesh placed by `model`.
public struct MapShadowCaster: Sendable {
    public var mesh: MeshHandle
    public var model: float4x4
    /// (first index, index count) runs, in index order.
    public var runs: [(first: Int, count: Int)]
    /// Unity's cast mode On culls the faces turned away from the light; Two
    /// Sided culls nothing.
    public var twoSided: Bool
    /// An alpha-tested caster's material (`map_shadow_fragment` clips its
    /// base alpha × baseColor.a at params.w); nil for an opaque one.
    public var alphaTest: MaterialState?

    public init(mesh: MeshHandle, model: float4x4, runs: [(first: Int, count: Int)], twoSided: Bool, alphaTest: MaterialState? = nil) {
        self.mesh = mesh; self.model = model; self.runs = runs; self.twoSided = twoSided; self.alphaTest = alphaTest
    }
}

public struct GizmoBatch: Sendable {
    public enum Primitive: Sendable { case lines, triangles }
    public var primitive: Primitive
    public var vertices: [GizmoVertex]
    public var model: float4x4 = matrix_identity_float4x4
    public var depthTest: Bool
    public var objectID: UInt32 = 0     // > 0 makes it pickable
    public init(primitive: Primitive, vertices: [GizmoVertex], model: float4x4 = matrix_identity_float4x4, depthTest: Bool = false, objectID: UInt32 = 0) {
        self.primitive = primitive; self.vertices = vertices; self.model = model; self.depthTest = depthTest; self.objectID = objectID
    }
}

public struct MainLight: Sendable, Equatable, Codable {
    public var rotation: Float3 = Float3(35, -35, 0)    // Euler degrees; default 3/4 key light from the front
    public var color: Float3 = Float3(1, 0.98, 0.95)
    public var intensity: Float = 1.0
    public var shadowStrength: Float = 0.85
    public var castsShadow: Bool = true
    /// Koikatsu-style: the light rotation is relative to the camera, so the key light follows the view.
    public var cameraRelative: Bool = true
    public init() {}
    /// Direction the light travels (world space) for a given camera.
    public func direction(camera: OrbitCamera) -> Float3 {
        let q = simd_quatf(eulerXYZ: rotation.degreesToRadians)
        let local = normalize(q.act(Float3(0, 0, -1)))
        guard cameraRelative else { return local }
        // Camera basis: forward = view direction; rotate the local direction into it (yaw + pitch).
        let f = camera.forward
        let yaw = atan2(f.x, f.z)
        let camRot = simd_quatf(angle: yaw + .pi, axis: Float3(0, 1, 0))
        return normalize(camRot.act(local))
    }
    /// World-space direction ignoring the camera (used when cameraRelative is off).
    public var direction: Float3 {
        let q = simd_quatf(eulerXYZ: rotation.degreesToRadians)
        return normalize(q.act(Float3(0, 0, -1)))
    }
}

public struct SceneEffects: Sendable, Equatable, Codable {
    public var bloomEnabled = true
    public var bloomThreshold: Float = 1.0
    public var bloomIntensity: Float = 0.18
    public var bloomRadius: Float = 1.0
    public var vignetteEnabled = false
    public var vignetteIntensity: Float = 0.35
    public var vignetteSmoothness: Float = 0.4
    public var fxaa = true
    /// nil preserves the historical native highlight roll-off in older scenes.
    /// Source-frame validation disables it to match an unprocessed Unity camera.
    public var toneMappingEnabled: Bool?
    public var exposure: Float = 1.0
    public var contrast: Float = 1.0
    public var saturation: Float = 1.05
    public var temperature: Float = 0.0
    public var outlineWidth: Float = 1.0
    public var ambientSky: Float3 = Float3(0.62, 0.66, 0.74)
    public var ambientGround: Float3 = Float3(0.50, 0.44, 0.46)
    public var fogEnabled = false
    public var fogColor: Float3 = Float3(0.8, 0.85, 0.95)
    public var fogStart: Float = 8
    public var fogEnd: Float = 30
    public var shadowSoftness: Float = 1.0
    public var showGrid = true
    public var backgroundTop: Float3 = Float3(0.83, 0.88, 0.96)
    public var backgroundBottom: Float3 = Float3(0.96, 0.94, 0.95)
    public var transparentBackground = false
    public init() {}
}

/// Orders frame creation against resource retirement (R6). Each `RenderFrame`
/// takes a stamp when it is created and each `ResourceStore.retire` call takes one,
/// so the renderer can tell a frame built before a retirement, which may still name
/// the retired handles and keys, from one built after it.
enum ResourceClock {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var value: UInt64 = 0
    }
    private static let storage = Storage()

    /// A stamp larger than every earlier one, on any thread.
    static func tick() -> UInt64 {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.value &+= 1
        return storage.value
    }
}

/// Immutable per-frame snapshot handed from the UI to the render thread.
public struct RenderFrame: Sendable {
    public var camera: OrbitCamera
    public var mainLight: MainLight
    public var lights: [SceneLight]
    public var items: [RenderItem]
    public var skinSets: [UInt64: [float4x4]] = [:]
    public var gizmos: [GizmoBatch]
    public var effects: SceneEffects
    public var sceneBounds: AABB          // used to fit the shadow map
    /// Maps slice 5: the loaded map's ambient and sun (nil: no map lighting).
    public var mapLighting: MapLighting? = nil
    public var time: Double = 0
    // Metal resources support concurrent reference ownership. The snapshot never
    // mutates texture contents and its dictionary is copied with this frame value.
    private struct RetainedTexture: @unchecked Sendable { let texture: any MTLTexture }
    private var retainedTextures: [TextureHandle: RetainedTexture] = [:]
    /// `ResourceClock` stamp taken when this value was created; copies keep it.
    /// Orders the frame against `ResourceStore.retire` (R6).
    var createdAt: UInt64 = ResourceClock.tick()
    /// Set by `Renderer.submit`. Only a submitted frame completes retirements: it
    /// replaced the pending frame the interactive draw would otherwise prepare.
    var submitted = false

    /// Freeze explicit texture resources while their appearance still owns them.
    /// Later unregistering a handle cannot change this frame's sampled materials.
    /// Repeating this after editing items prunes removed references and keeps existing
    /// snapshots; new handles are resolved from the resource store.
    public mutating func retainTextures(from resources: ResourceStore) {
        // One pass over the items' handles in place, without an array per item
        // or a set of them (a 3,506-item frame spent 0.23 ms here). Each handle
        // is resolved once, as before: a retained one keeps its snapshot, a new
        // one is looked up in the store, and one the store lacks is skipped.
        let previous = retainedTextures
        var snapshot: [TextureHandle: RetainedTexture] = [:]
        snapshot.reserveCapacity(previous.count)
        var unresolved: Set<TextureHandle> = []
        items.withUnsafeBufferPointer { items in
            for index in items.indices {
                items[index].material.forEachTextureHandle { handle in
                    guard snapshot[handle] == nil, unresolved.isEmpty || !unresolved.contains(handle) else { return }
                    if let retained = previous[handle] { snapshot[handle] = retained }
                    else if let texture = resources.texture(handle) { snapshot[handle] = RetainedTexture(texture: texture) }
                    else { unresolved.insert(handle) }
                }
            }
        }
        // Maps slice 5: an alpha-tested map shadow caster samples its base texture in the shadow pass.
        for caster in mapLighting?.casters ?? [] {
            guard let handle = caster.alphaTest?.base, snapshot[handle] == nil, !unresolved.contains(handle) else { continue }
            if let retained = previous[handle] { snapshot[handle] = retained }
            else if let texture = resources.texture(handle) { snapshot[handle] = RetainedTexture(texture: texture) }
            else { unresolved.insert(handle) }
        }
        retainedTextures = snapshot
    }

    func texture(_ handle: TextureHandle?, resources: ResourceStore) -> (any MTLTexture)? {
        guard let handle else { return nil }
        return retainedTextures[handle]?.texture ?? resources.texture(handle)
    }

    public init(camera: OrbitCamera = OrbitCamera(), mainLight: MainLight = MainLight(), lights: [SceneLight] = [],
                items: [RenderItem] = [], gizmos: [GizmoBatch] = [], effects: SceneEffects = SceneEffects(),
                sceneBounds: AABB = AABB(min: Float3(-1, 0, -1), max: Float3(1, 2, 1))) {
        self.camera = camera; self.mainLight = mainLight; self.lights = lights; self.items = items
        self.gizmos = gizmos; self.effects = effects; self.sceneBounds = sceneBounds
    }
}

public extension MaterialUniforms {
    static func make(kind: MaterialKind) -> MaterialUniforms {
        var m = MaterialUniforms()
        m.baseColor = Float4(1, 1, 1, 1)
        m.shadowColor = Float4(0.78, 0.72, 0.80, 0.5)
        m.specular = Float4(1, 1, 1, 24)
        m.rim = Float4(0.35, 0.35, 0.4, 3.0)
        m.outline = Float4(0.15, 0.10, 0.14, 1.6)
        m.tint1 = Float4(1, 1, 1, 1); m.tint2 = Float4(1, 1, 1, 1); m.tint3 = Float4(1, 1, 1, 1)
        m.overlayColor0 = Float4(1, 1, 1, 0); m.overlayColor1 = Float4(1, 1, 1, 0); m.overlayColor2 = Float4(1, 1, 1, 0)
        m.patternColor = Float4(1, 1, 1, 0)
        m.hairGloss = Float4(0.45, 0.05, 0.62, 0)
        m.params = Float4(0.08, 0.5, 0.7, 0.5)
        m.eye = Float4(1, 0, 0, 1)
        m.emissive = Float4(0, 0, 0, 0)
        m.uvTransform = Float4(1, 1, 0, 0)
        m.irisST0 = Float4(1, 1, 0, 0); m.irisST1 = Float4(1, 1, 0, 0); m.irisST2 = Float4(1, 1, 0, 0)
        m.kind = UInt32(kind.rawValue)
        m.flags = MaterialFlagReceiveShadow.rawValue
        m.sourceAlphaA = 1
        m.sourceAlphaB = 1
        m.irisRotation = 0
        switch kind {
        case MaterialKindSkin:
            m.shadowColor = Float4(0.82, 0.66, 0.70, 0.52)
            m.specular = Float4(1, 0.95, 0.9, 32); m.params.y = 0.35
            m.outline = Float4(0.45, 0.22, 0.24, 1.4)
            m.rim = Float4(0.25, 0.2, 0.22, 3.5)
        case MaterialKindHair:
            m.shadowColor = Float4(0.62, 0.55, 0.72, 0.5)
            m.specular = Float4(1, 1, 1, 48); m.params.y = 0.8
            m.outline = Float4(0.2, 0.12, 0.2, 1.5)
            m.rim = Float4(0.3, 0.3, 0.35, 3.0)
        case MaterialKindCloth:
            m.shadowColor = Float4(0.66, 0.62, 0.74, 0.5)
            m.specular = Float4(1, 1, 1, 48); m.params.y = 0.15
            m.outline = Float4(0.12, 0.10, 0.16, 1.5)
        case MaterialKindEye:
            m.shadowColor = Float4(0.8, 0.75, 0.85, 0.5)
            m.flags |= MaterialFlagNoOutline.rawValue
        case MaterialKindEyelash:
            m.flags |= MaterialFlagNoOutline.rawValue | MaterialFlagAlphaTest.rawValue | MaterialFlagDoubleSided.rawValue
            m.baseColor = Float4(0.18, 0.12, 0.16, 1)
        case MaterialKindUnlit:
            m.flags |= MaterialFlagNoOutline.rawValue
        default: break
        }
        return m
    }
}
