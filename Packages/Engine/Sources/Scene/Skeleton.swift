import Foundation
import simd
import CoreMath
import Assets

/// Defined failures of the legacy name-keyed skeleton (R4). Construction
/// validates the bone graph and rest data, so name lookups, parent-first
/// evaluation and parent walks cannot trap, loop or start from nonfinite data.
public enum SkeletonError: Error, Equatable, CustomStringConvertible {
    /// Names are this skeleton's lookup key, so each must be unique.
    case duplicateName(String)
    /// The parent index is out of range or is the bone's own index.
    case invalidParent(bone: String, parent: Int)
    /// Following parents from this bone returns to it.
    case cycle(bone: String)
    /// A rest translation/scale is nonfinite or the rest rotation is not a finite unit quaternion.
    case invalidRestTransform(bone: String)
    /// The inverse bind matrix is nonfinite or not affine.
    case invalidInverseBind(bone: String)
    /// An imported rest matrix has no translation/rotation/scale form (see `float4x4.checkedTRS`).
    case unsupportedTransform(bone: String, MathContractError)
    /// The glTF skin references a missing node, repeats a joint or lacks one bind per joint.
    case invalidSkin(String)

    public var description: String {
        switch self {
        case .duplicateName(let name): return "Skeleton has more than one bone named \"\(name)\"."
        case .invalidParent(let bone, let parent): return "Skeleton bone \"\(bone)\" has invalid parent index \(parent)."
        case .cycle(let bone): return "Skeleton hierarchy contains a cycle at bone \"\(bone)\"."
        case .invalidRestTransform(let bone): return "Skeleton bone \"\(bone)\" has a nonfinite rest transform or nonunit rest rotation."
        case .invalidInverseBind(let bone): return "Skeleton bone \"\(bone)\" has a nonfinite or nonaffine inverse bind matrix."
        case .unsupportedTransform(let bone, let error): return "Skeleton bone \"\(bone)\" has an unsupported rest transform: \(error)"
        case .invalidSkin(let message): return "Skeleton skin is invalid: \(message)."
        }
    }
}

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

        /// `children` and `length` are derived by `Skeleton.init(bones:)`.
        public init(name: String, parent: Int?, restTranslation: Float3 = .zero, restRotation: simd_quatf = .identity,
                    restScale: Float3 = .one, inverseBind: float4x4 = matrix_identity_float4x4) {
            self.name = name; self.parent = parent; self.restTranslation = restTranslation
            self.restRotation = restRotation; self.restScale = restScale; self.inverseBind = inverseBind
        }
    }

    // Read-only outside construction so the validated graph cannot be broken later.
    public private(set) var bones: [Bone]
    public private(set) var nameToIndex: [String: Int]
    public private(set) var order: [Int]  // parents before children

    /// Validates the graph and rest data; see `SkeletonError`. Bones may appear
    /// in any index order because `order` lists every parent before its children.
    public init(bones: [Bone]) throws {
        var nameToIndex: [String: Int] = [:]
        for (index, bone) in bones.enumerated() {
            guard nameToIndex.updateValue(index, forKey: bone.name) == nil else { throw SkeletonError.duplicateName(bone.name) }
            if let parent = bone.parent, !bones.indices.contains(parent) || parent == index {
                throw SkeletonError.invalidParent(bone: bone.name, parent: parent)
            }
            let q = bone.restRotation.vector
            guard Self.isFinite(bone.restTranslation), Self.isFinite(bone.restScale),
                  q.x.isFinite, q.y.isFinite, q.z.isFinite, q.w.isFinite, abs(simd_length(q) - 1) < 1e-3 else {
                throw SkeletonError.invalidRestTransform(bone: bone.name)
            }
            guard RigDefinition.isFiniteAffine(bone.inverseBind) else { throw SkeletonError.invalidInverseBind(bone: bone.name) }
        }
        // Appends each unvisited ancestor chain root-most first: the order of the
        // former recursive visit, without recursion. Reaching a bone already on
        // the current chain is a cycle.
        var visited = [Bool](repeating: false, count: bones.count)
        var order: [Int] = []
        order.reserveCapacity(bones.count)
        for start in bones.indices where !visited[start] {
            var chain: [Int] = []
            var onChain = Set<Int>()
            var current: Int? = start
            while let index = current, !visited[index] {
                guard onChain.insert(index).inserted else { throw SkeletonError.cycle(bone: bones[index].name) }
                chain.append(index)
                current = bones[index].parent
            }
            for index in chain.reversed() { visited[index] = true; order.append(index) }
        }
        var bs = bones
        for i in bs.indices { bs[i].children = [] }
        for (i, b) in bs.enumerated() { if let p = b.parent { bs[p].children.append(i) } }
        for i in bs.indices {
            if let c = bs[i].children.first { bs[i].length = max(0.01, length(bs[c].restTranslation)) }
        }
        self.bones = bs
        self.nameToIndex = nameToIndex
        self.order = order
    }

    private static func isFinite(_ value: Float3) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }

    public var count: Int { bones.count }
    public func index(of name: String) -> Int? { nameToIndex[name] }
    public subscript(name: String) -> Int? { nameToIndex[name] }

    /// Builds a skeleton from a glTF skin. Joint order = skin joint order (so vertex joint indices map directly).
    /// Returns nil when the asset has no skin at `skinIndex`; a malformed skin or
    /// bone graph throws `SkeletonError`. A root joint's non-joint ancestors (e.g.
    /// the Armature object) fold into its rest transform, and non-identity
    /// non-joint nodes between two joints fold into the child's. Folded and
    /// authored matrices decompose with `checkedTRS`: a reflection becomes a
    /// negative scale and shear is rejected instead of silently dropped. A TRS
    /// joint directly under its joint parent keeps its authored values.
    public static func from(asset: GLTFAsset, skinIndex: Int = 0) throws -> Skeleton? {
        guard asset.skins.indices.contains(skinIndex) else { return nil }
        let skin = asset.skins[skinIndex]
        guard skin.inverseBindMatrices.count == skin.jointNodes.count else {
            throw SkeletonError.invalidSkin("\(skin.jointNodes.count) joints but \(skin.inverseBindMatrices.count) inverse bind matrices")
        }
        var jointSet: [Int: Int] = [:]
        for (ji, ni) in skin.jointNodes.enumerated() {
            guard asset.nodes.indices.contains(ni) else { throw SkeletonError.invalidSkin("joint \(ji) references missing node \(ni)") }
            guard jointSet.updateValue(ji, forKey: ni) == nil else { throw SkeletonError.invalidSkin("node \(ni) is listed as more than one joint") }
        }
        var bones: [Bone] = []
        for (ji, ni) in skin.jointNodes.enumerated() {
            let n = asset.nodes[ni]
            var parent: Int? = nil
            var between: [Int] = []  // non-joint nodes from n's parent up to the joint parent
            var p = n.parent
            while let pi = p {
                guard asset.nodes.indices.contains(pi), between.count < asset.nodes.count else {
                    throw SkeletonError.invalidSkin("node \(ni) has a missing or cyclic ancestor")
                }
                if let j = jointSet[pi] { parent = j; break }
                between.append(pi); p = asset.nodes[pi].parent
            }
            var folded = n.authoredMatrix
            if parent == nil {
                // Fold non-joint ancestors (e.g. the Armature object) into the root bone.
                folded = asset.worldMatrix(ofNode: ni)
            } else if between.contains(where: { asset.nodes[$0].localMatrix != matrix_identity_float4x4 }) {
                // parentJointWorld * between[last] * … * between[0] * nLocal = nWorld.
                var local = n.localMatrix
                for b in between { local = asset.nodes[b].localMatrix * local }
                folded = local
            }
            var t = n.translation, r = n.rotation, s = n.scale
            if let folded {
                do {
                    let trs = try folded.checkedTRS("rest matrix")
                    t = trs.translation; r = trs.rotation; s = trs.scale
                } catch let error as MathContractError {
                    throw SkeletonError.unsupportedTransform(bone: n.name, error)
                }
            }
            bones.append(Bone(name: n.name, parent: parent, restTranslation: t, restRotation: r, restScale: s,
                              inverseBind: skin.inverseBindMatrices[ji]))
        }
        return try Skeleton(bones: bones)
    }

    public var restPose: Pose { Pose(skeleton: self) }

    /// A copy with extra bones appended (their `parent` indices refer to this
    /// skeleton or to other extras), validated like `init(bones:)`.
    public func extended(with extras: [Bone]) throws -> Skeleton { try Skeleton(bones: bones + extras) }

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
