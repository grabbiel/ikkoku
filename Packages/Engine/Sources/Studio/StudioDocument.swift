import Foundation
import simd
import CoreMath
import Scene
import Renderer
import Character

public enum StudioObjectKind: String, Codable, Sendable { case character, item, light, camera, folder }

public struct StudioTransform: Codable, Sendable, Equatable {
    public var position = Float3.zero
    public var rotation = Float3.zero       // Euler XYZ degrees
    public var scale = Float3(repeating: 1)
    public init() {}
    public var matrix: float4x4 { Transform.trs(position, simd_quatf(eulerXYZ: rotation.degreesToRadians), scale) }
    public var quaternion: simd_quatf { simd_quatf(eulerXYZ: rotation.degreesToRadians) }
}

/// One node of the studio workspace tree.
public struct StudioObject: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var kind: StudioObjectKind
    public var parent: UUID?
    public var visible = true
    public var locked = false
    public var transform = StudioTransform()
    // character
    public var card: CharacterCard?
    public var poseDelta = PoseDelta()
    public var ikTargets: [IKChain: IKTarget] = [:]
    public var animationPreset: String?
    public var clothingVisible = true
    public var accessoriesVisible = true
    public var handGestureL = 0
    public var handGestureR = 0
    // item
    public var itemID: String?
    public var tint: RGB?
    public var emissive: Float = 0
    // light
    public var light: SceneLight?
    // camera
    public var fov: Float = 30
    public var savedCamera: OrbitCamera?

    public init(name: String, kind: StudioObjectKind) { self.name = name; self.kind = kind }

    public static func character(_ card: CharacterCard) -> StudioObject {
        var o = StudioObject(name: card.profile.name, kind: .character)
        o.card = card
        return o
    }
    public static func item(id: String, name: String) -> StudioObject {
        var o = StudioObject(name: name, kind: .item)
        o.itemID = id
        return o
    }
    public static func light(_ kind: LightKind) -> StudioObject {
        var o = StudioObject(name: kind.rawValue.capitalized + " light", kind: .light)
        var l = SceneLight(kind: kind)
        switch kind {
        case .directional: l.rotation = Float3(50, -30, 0); l.intensity = 0.6
        case .point: l.position = Float3(0.6, 1.5, 0.6); l.range = 3; l.intensity = 0.5; l.color = Float3(1, 0.9, 0.8)
        case .spot: l.position = Float3(0, 2.4, 1.2); l.rotation = Float3(-60, 0, 0); l.range = 6; l.spotAngle = 45; l.intensity = 0.7
        }
        o.light = l
        o.transform.position = l.position
        o.transform.rotation = l.rotation
        return o
    }
}

/// A studio scene: object tree, camera slots, character light and effects. Saved as a PNG "scene card".
public struct StudioDocument: Codable, Sendable, Equatable {
    public var version = 1
    public var name = "Untitled scene"
    public var objects: [StudioObject] = []
    public var camera = OrbitCamera()
    public var cameraSlots: [OrbitCamera?] = Array(repeating: nil, count: 10)
    public var mainLight = MainLight()
    public var effects = SceneEffects()
    public var captureWidth = 1920
    public var captureHeight = 1080
    public var timeline = Timeline()

    public init() {
        camera.target = Float3(0, 0.9, 0); camera.distance = 3.4; camera.yaw = 0.35; camera.pitch = 0.12
    }

    public func object(_ id: UUID) -> StudioObject? { objects.first { $0.id == id } }
    public func index(of id: UUID) -> Int? { objects.firstIndex { $0.id == id } }
    public func children(of id: UUID?) -> [StudioObject] { objects.filter { $0.parent == id } }

    /// World matrix including parents.
    public func worldMatrix(of id: UUID) -> float4x4 {
        guard let o = object(id) else { return matrix_identity_float4x4 }
        var m = o.transform.matrix
        var p = o.parent
        var guardCount = 0
        while let pid = p, let po = object(pid), guardCount < 64 { m = po.transform.matrix * m; p = po.parent; guardCount += 1 }
        return m
    }

    public func isVisible(_ id: UUID) -> Bool {
        var cur: UUID? = id
        var n = 0
        while let c = cur, let o = object(c), n < 64 { if !o.visible { return false }; cur = o.parent; n += 1 }
        return true
    }

    public func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        var cur = object(id)?.parent
        var n = 0
        while let c = cur, n < 64 { if c == ancestor { return true }; cur = object(c)?.parent; n += 1 }
        return false
    }

    public mutating func remove(_ id: UUID) {
        let victims = objects.filter { $0.id == id || isDescendant($0.id, of: id) }.map(\.id)
        objects.removeAll { victims.contains($0.id) }
    }

    /// Depth-first ordered list of (object, depth) for the tree view.
    public func flattened() -> [(object: StudioObject, depth: Int)] {
        var out: [(StudioObject, Int)] = []
        func visit(_ parent: UUID?, _ depth: Int) {
            for o in objects where o.parent == parent { out.append((o, depth)); visit(o.id, depth + 1) }
        }
        visit(nil, 0)
        return out
    }
}
