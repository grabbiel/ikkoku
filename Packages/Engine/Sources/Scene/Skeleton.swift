import Foundation
import simd
import CoreMath
import Assets

/// Immutable bone hierarchy shared by every mesh skinned to it.
public struct Skeleton: Sendable {
    public struct Bone: Sendable {
        public var name: String
        public var parent: Int?          // index into bones
        public var restTranslation: Float3
        public var restRotation: simd_quatf
        public var restScale: Float3
        public var inverseBind: float4x4
        public var children: [Int] = []
        public var length: Float = 0.05  // for drawing/IK; distance to first child
    }

    public var bones: [Bone]
    public var nameToIndex: [String: Int]
    public var order: [Int]  // parents before children

    public init(bones: [Bone]) {
        var bs = bones
        for i in bs.indices { bs[i].children = [] }
        for (i, b) in bs.enumerated() { if let p = b.parent { bs[p].children.append(i) } }
        for i in bs.indices {
            if let c = bs[i].children.first { bs[i].length = max(0.01, length(bs[c].restTranslation)) }
        }
        self.bones = bs
        self.nameToIndex = Dictionary(uniqueKeysWithValues: bs.enumerated().map { ($1.name, $0) })
        var visited = [Bool](repeating: false, count: bs.count)
        var out: [Int] = []
        func visit(_ i: Int) {
            if visited[i] { return }
            if let p = bs[i].parent { visit(p) }
            visited[i] = true
            out.append(i)
        }
        for i in bs.indices { visit(i) }
        self.order = out
    }

    public var count: Int { bones.count }
    public func index(of name: String) -> Int? { nameToIndex[name] }
    public subscript(name: String) -> Int? { nameToIndex[name] }

    /// Builds a skeleton from a glTF skin. Joint order = skin joint order (so vertex joint indices map directly).
    public static func from(asset: GLTFAsset, skinIndex: Int = 0) -> Skeleton? {
        guard skinIndex < asset.skins.count else { return nil }
        let skin = asset.skins[skinIndex]
        let jointSet = Dictionary(uniqueKeysWithValues: skin.jointNodes.enumerated().map { ($1, $0) })
        var bones: [Bone] = []
        for (ji, ni) in skin.jointNodes.enumerated() {
            let n = asset.nodes[ni]
            var parent: Int? = nil
            var p = n.parent
            while let pi = p { if let j = jointSet[pi] { parent = j; break }; p = asset.nodes[pi].parent }
            var t = n.translation, r = n.rotation, s = n.scale
            if parent == nil {
                // Fold non-joint ancestors (e.g. the Armature object) into the root bone.
                let world = asset.worldMatrix(ofNode: ni)
                t = world.translation; r = world.rotationQuaternion; s = world.scaleFactors
            }
            bones.append(Bone(name: n.name, parent: parent, restTranslation: t, restRotation: r, restScale: s,
                              inverseBind: skin.inverseBindMatrices[ji]))
        }
        return Skeleton(bones: bones)
    }

    public var restPose: Pose { Pose(skeleton: self) }

    /// A copy with extra bones appended (their `parent` indices refer to this skeleton or to earlier extras).
    public func extended(with extras: [Bone]) -> Skeleton { Skeleton(bones: bones + extras) }

    /// Rest-pose world matrices (bind pose).
    public func restWorldMatrices() -> [float4x4] { restPose.worldMatrices(skeleton: self) }
}

/// Per-bone local overrides. Rotations are absolute local rotations (not deltas) so poses are stable.
public struct Pose: Sendable, Equatable {
    public var rotations: [simd_quatf]
    public var translations: [Float3]   // absolute local translation (rest by default)
    public var scales: [Float3]         // propagating local scale (head size, hand size)
    public var skinScales: [Float3]     // non-propagating scale applied to skinning only (thickness, length fill)

    public init(skeleton: Skeleton) {
        rotations = skeleton.bones.map { $0.restRotation }
        translations = skeleton.bones.map { $0.restTranslation }
        scales = skeleton.bones.map { $0.restScale }
        skinScales = skeleton.bones.map { _ in Float3(repeating: 1) }
    }

    public init(rotations: [simd_quatf], translations: [Float3], scales: [Float3], skinScales: [Float3]) {
        self.rotations = rotations; self.translations = translations; self.scales = scales; self.skinScales = skinScales
    }

    public var count: Int { rotations.count }

    public static func == (a: Pose, b: Pose) -> Bool {
        a.translations == b.translations && a.scales == b.scales && a.skinScales == b.skinScales &&
        a.rotations.count == b.rotations.count && zip(a.rotations, b.rotations).allSatisfy { $0.vector == $1.vector }
    }

    /// World matrices (propagating TRS only).
    public func worldMatrices(skeleton: Skeleton) -> [float4x4] {
        var world = [float4x4](repeating: matrix_identity_float4x4, count: skeleton.count)
        for i in skeleton.order {
            let local = Transform.trs(translations[i], rotations[i], scales[i])
            if let p = skeleton.bones[i].parent { world[i] = world[p] * local } else { world[i] = local }
        }
        return world
    }

    /// Skin matrices: world · skinScale · inverseBind. The skin scale is applied about the bone origin
    /// and does not propagate to children, which is what thickness sliders need.
    public func skinMatrices(skeleton: Skeleton, world: [float4x4]? = nil) -> [float4x4] {
        let w = world ?? worldMatrices(skeleton: skeleton)
        var out = [float4x4](repeating: matrix_identity_float4x4, count: skeleton.count)
        for i in 0..<skeleton.count {
            let s = skinScales[i]
            if s == Float3(repeating: 1) {
                out[i] = w[i] * skeleton.bones[i].inverseBind
            } else {
                out[i] = w[i] * Transform.scale(s) * skeleton.bones[i].inverseBind
            }
        }
        return out
    }

    /// Blend toward another pose (rotations slerp, translations/scales lerp).
    public func blended(with other: Pose, t: Float) -> Pose {
        var p = self
        for i in 0..<count {
            p.rotations[i] = simd_slerp(rotations[i], other.rotations[i], t)
            p.translations[i] = lerp(translations[i], other.translations[i], t)
            p.scales[i] = lerp(scales[i], other.scales[i], t)
            p.skinScales[i] = lerp(skinScales[i], other.skinScales[i], t)
        }
        return p
    }

    /// World rotation of a bone (no scale).
    public func worldRotation(_ i: Int, skeleton: Skeleton) -> simd_quatf {
        var q = rotations[i]
        var p = skeleton.bones[i].parent
        while let pi = p { q = rotations[pi] * q; p = skeleton.bones[pi].parent }
        return q.normalized
    }
}

/// A pose expressed as deltas from rest, in degrees, which is how the UI and saved files see it.
public struct PoseDelta: Codable, Sendable, Equatable {
    public var rotations: [String: Float3]     // Euler XYZ degrees applied after rest rotation
    public var translations: [String: Float3]  // metres, added to rest translation
    public var scales: [String: Float3]        // propagating, multiplies rest scale
    public var skinScales: [String: Float3]    // non-propagating
    public init(rotations: [String: Float3] = [:], translations: [String: Float3] = [:], scales: [String: Float3] = [:], skinScales: [String: Float3] = [:]) {
        self.rotations = rotations; self.translations = translations; self.scales = scales; self.skinScales = skinScales
    }
    public var isEmpty: Bool { rotations.isEmpty && translations.isEmpty && scales.isEmpty && skinScales.isEmpty }

    /// Applies on top of `base` (rest pose by default). Translations/scales accumulate with the base.
    public func apply(to skeleton: Skeleton, base: Pose? = nil) -> Pose {
        var pose = base ?? skeleton.restPose
        for (name, e) in rotations {
            guard let i = skeleton[name] else { continue }
            let q = simd_quatf(eulerXYZ: e.degreesToRadians)
            pose.rotations[i] = (pose.rotations[i] * q).normalized
        }
        for (name, t) in translations {
            guard let i = skeleton[name] else { continue }
            pose.translations[i] += t
        }
        for (name, s) in scales {
            guard let i = skeleton[name] else { continue }
            pose.scales[i] *= s
        }
        for (name, s) in skinScales {
            guard let i = skeleton[name] else { continue }
            pose.skinScales[i] *= s
        }
        return pose
    }

    public mutating func merge(_ other: PoseDelta) {
        for (k, v) in other.rotations { rotations[k, default: .zero] += v }
        for (k, v) in other.translations { translations[k, default: .zero] += v }
        for (k, v) in other.scales { scales[k, default: Float3(repeating: 1)] *= v }
        for (k, v) in other.skinScales { skinScales[k, default: Float3(repeating: 1)] *= v }
    }
}

public extension Float3 {
    var degreesToRadians: Float3 { self * (.pi / 180) }
    var radiansToDegrees: Float3 { self * (180 / .pi) }
}
