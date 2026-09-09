import Foundation
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
    public var transparent: Bool = false     // draw in the transparent pass (blend)
    public var depthBias: Float = 0          // metres toward the camera (eyebrows over hair)

    public init(uniforms: MaterialUniforms) { self.uniforms = uniforms }

    public static func == (a: MaterialState, b: MaterialState) -> Bool {
        withUnsafeBytes(of: a.uniforms) { ab in withUnsafeBytes(of: b.uniforms) { bb in ab.elementsEqual(bb) } }
        && a.base == b.base && a.colorMask == b.colorMask && a.detail == b.detail && a.line == b.line && a.normal == b.normal
        && a.overlay0 == b.overlay0 && a.overlay1 == b.overlay1 && a.overlay2 == b.overlay2 && a.pattern == b.pattern
        && a.hairGloss == b.hairGloss && a.bodyMask == b.bodyMask && a.transparent == b.transparent && a.depthBias == b.depthBias
    }

    public var kind: MaterialKind { MaterialKind(rawValue: Int32(uniforms.kind)) ?? MaterialKindItem }

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

    public init(mesh: MeshHandle, material: MaterialState, model: float4x4, objectID: UInt32,
                deformKey: UInt64? = nil, skinSet: UInt64? = nil, morphWeights: [(index: Int, weight: Float)] = []) {
        self.mesh = mesh; self.material = material; self.model = model; self.objectID = objectID
        self.deformKey = deformKey; self.skinSet = skinSet; self.morphWeights = morphWeights
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
    public var time: Double = 0

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
        m.kind = UInt32(kind.rawValue)
        m.flags = MaterialFlagReceiveShadow.rawValue
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
