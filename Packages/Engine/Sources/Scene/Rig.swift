import Foundation
import simd
import CoreMath

public enum RigError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): return message } }
}

/// A source hierarchy, including every support transform between skin joints.
/// Names are labels; stable source IDs and node indices establish identity.
public struct RigDefinition: Sendable {
    public struct Node: Sendable {
        public let name: String
        public let sourceID: String
        public let parent: Int?
        public let translation: Float3
        public let rotation: simd_quatf
        public let scale: Float3
        public let authoredMatrix: float4x4?
        public let active: Bool
        public var localMatrix: float4x4 { authoredMatrix ?? Transform.trs(translation, rotation, scale) }

        public init(name: String, sourceID: String, parent: Int?, translation: Float3 = .zero,
                    rotation: simd_quatf = .identity, scale: Float3 = .one,
                    authoredMatrix: float4x4? = nil, active: Bool = true) {
            self.name = name; self.sourceID = sourceID; self.parent = parent
            self.translation = translation; self.rotation = rotation; self.scale = scale
            self.authoredMatrix = authoredMatrix; self.active = active
        }
    }

    /// Each renderer retains its own palette order and inverse binds.
    public struct Skin: Sendable {
        public let name: String
        public let meshNode: Int
        public let joints: [Int]
        public let inverseBindMatrices: [float4x4]
        public let rootJoint: Int?
        public init(name: String, meshNode: Int, joints: [Int], inverseBindMatrices: [float4x4], rootJoint: Int? = nil) {
            self.name = name; self.meshNode = meshNode; self.joints = joints
            self.inverseBindMatrices = inverseBindMatrices; self.rootJoint = rootJoint
        }
    }

    /// One per `init`, shared by every copy of its result. Every stored
    /// property is a `let` set once by `init`, so two rigs with the same
    /// identity have the same nodes, skins and order. Per-rig caches key on
    /// it (R7 phase 2, item 3) and hold it strongly, so it cannot be reused.
    public final class Identity: Sendable { fileprivate init() {} }

    public let nodes: [Node]
    public let skins: [Skin]
    public let order: [Int]
    public let activeNodes: [Bool]
    public let identity = Identity()
    /// The rest pose's signed TRS records (#406): one per TRS node whose rest
    /// scale has a component at or below zero, nil (no allocation) when there
    /// is none, the usual case.
    public let restSignedTRS: [Int: SignedTRS]?
    private let names: [String: [Int]]

    public init(nodes: [Node], skins: [Skin]) throws {
        guard !nodes.isEmpty else { throw RigError.invalid("Rig has no nodes.") }
        var ids = Set<String>(), children = [[Int]](repeating: [], count: nodes.count)
        var roots: [Int] = [], names: [String: [Int]] = [:]
        for (index, node) in nodes.enumerated() {
            guard !node.sourceID.isEmpty, ids.insert(node.sourceID).inserted else {
                throw RigError.invalid("Rig node \(index) has an empty or duplicate source ID.")
            }
            guard Self.isFiniteAffine(node.localMatrix) else { throw RigError.invalid("Rig node \(index) has an invalid local matrix.") }
            guard node.authoredMatrix != nil || abs(simd_length(node.rotation.vector) - 1) < 1e-3 else {
                throw RigError.invalid("Rig node \(index) has a nonunit rotation.")
            }
            if let parent = node.parent {
                guard nodes.indices.contains(parent), parent != index else { throw RigError.invalid("Rig node \(index) has an invalid parent.") }
                children[parent].append(index)
            } else { roots.append(index) }
            names[node.name, default: []].append(index)
        }
        var order = roots, cursor = 0, active = [Bool](repeating: false, count: nodes.count)
        while cursor < order.count {
            let index = order[cursor]; cursor += 1
            active[index] = nodes[index].active && (nodes[index].parent.map { active[$0] } ?? true)
            order.append(contentsOf: children[index])
        }
        guard order.count == nodes.count else { throw RigError.invalid("Rig hierarchy contains a cycle.") }
        for (index, skin) in skins.enumerated() {
            guard nodes.indices.contains(skin.meshNode), !skin.joints.isEmpty,
                  skin.joints.count == skin.inverseBindMatrices.count,
                  skin.joints.allSatisfy({ nodes.indices.contains($0) }),
                  skin.rootJoint.map({ nodes.indices.contains($0) }) ?? true,
                  skin.inverseBindMatrices.allSatisfy(Self.isFiniteAffine) else {
                throw RigError.invalid("Rig skin \(index) has invalid joint references or inverse binds.")
            }
        }
        self.nodes = nodes; self.skins = skins; self.order = order; self.activeNodes = active; self.names = names
        var rest: [Int: SignedTRS] = [:]
        for (index, node) in nodes.enumerated() where node.authoredMatrix == nil && SignedTRS.needsRecord(node.scale) {
            rest[index] = SignedTRS(translation: node.translation, rotation: node.rotation, scale: node.scale)
        }
        restSignedTRS = rest.isEmpty ? nil : rest
    }

    public func nodes(named name: String) -> [Int] { names[name] ?? [] }
    /// SourceRig's inline stride already includes this struct's fields. Add only
    /// retained element/string payloads; dictionary bucket capacity is excluded.
    func addLogicalPayload(to charge: inout SourceRigLogicalCharge) -> Bool {
        guard charge.array(nodes), charge.array(skins), charge.array(order), charge.array(activeNodes),
              charge.product(names.count, MemoryLayout<(String, [Int])>.stride),
              charge.product(restSignedTRS?.count ?? 0, MemoryLayout<(Int, SignedTRS)>.stride) else { return false }
        for node in nodes {
            guard charge.string(node.name), charge.string(node.sourceID) else { return false }
        }
        for skin in skins {
            guard charge.string(skin.name), charge.array(skin.joints), charge.array(skin.inverseBindMatrices) else { return false }
        }
        for (name, indices) in names {
            guard charge.string(name), charge.array(indices) else { return false }
        }
        return true
    }
    public func uniqueNode(named name: String) throws -> Int {
        let matches = nodes(named: name)
        guard matches.count == 1 else { throw RigError.invalid("Expected one node named '\(name)', found \(matches.count).") }
        return matches[0]
    }
    public var restPose: RigPose { RigPose(rig: self) }

    public func evaluate(_ pose: RigPose) throws -> RigEvaluation {
        guard pose.localMatrices.count == nodes.count else { throw RigError.invalid("Pose does not match rig node count.") }
        var world = [float4x4](repeating: matrix_identity_float4x4, count: nodes.count)
        for index in order {
            let local = pose.localMatrices[index]
            guard Self.isFiniteAffine(local) else { throw RigError.invalid("Pose node \(index) has an invalid matrix.") }
            world[index] = nodes[index].parent.map { world[$0] * local } ?? local
            guard Self.isFiniteAffine(world[index]) else { throw RigError.invalid("Pose hierarchy overflow at node \(index).") }
        }
        var collapsed = Set<Int>()
        let palettes = try skins.enumerated().map { index, skin -> [float4x4] in
            let meshWorld = world[skin.meshNode]
            let matrices: [float4x4]
            if Self.skinsInMeshSpace(meshWorld) {
                let meshInverse = simd_inverse(meshWorld)
                matrices = zip(skin.joints, skin.inverseBindMatrices).map { meshInverse * world[$0] * $1 }
            } else {
                // #404: a zero shape scale above the renderer (hair under
                // HairParent, for one) leaves no mesh space to skin into.
                // Unity's SkinnedMeshRenderer skins from the bones alone and
                // ignores its own transform, so this skin's palette stays in
                // rig space, drawn with the identity: the limit of
                // meshWorld · meshInverse · world · inverseBind as det → 0.
                collapsed.insert(index)
                matrices = zip(skin.joints, skin.inverseBindMatrices).map { world[$0] * $1 }
            }
            guard matrices.allSatisfy(Self.isFiniteAffine) else { throw RigError.invalid("Skin \(index) produced a nonfinite palette.") }
            return matrices
        }
        return RigEvaluation(worldMatrices: world, palettes: palettes, collapsedSkins: collapsed)
    }

    /// True when `evaluate` skins `meshWorld`'s renderer in mesh space; false
    /// for a singular mesh world, whose palette stays in rig space (#404).
    public static func skinsInMeshSpace(_ meshWorld: float4x4) -> Bool {
        abs(simd_determinant(meshWorld)) > Transform.singularDeterminant
    }

    /// Every element is finite and the bottom row is (0, 0, 0, 1) within 1e-5.
    /// Four lanes at a time: in each column, `abs(x) < .infinity` is false
    /// exactly for NaN and ±infinity, and the w lane's `abs(w) < 1e-5`
    /// (`abs(w - 1)` in the last column, where `x - 0` is `x`) is false for
    /// those too. So this returns what the former element loop (`isFinite`
    /// on all 16 elements, then the four w checks) returned for every input;
    /// `RigFiniteAffineTests` keeps that loop as its reference. It runs for
    /// every node twice and every palette entry of each `evaluate`.
    public static func isFiniteAffine(_ matrix: float4x4) -> Bool {
        let limit = SIMD4<Float>(.infinity, .infinity, .infinity, 1e-5)
        let x = abs(matrix.columns.0) .< limit, y = abs(matrix.columns.1) .< limit
        let z = abs(matrix.columns.2) .< limit, w = abs(matrix.columns.3 - SIMD4<Float>(0, 0, 0, 1)) .< limit
        return all(x .& y .& z .& w)
    }
}

/// A local transform as its writer set it: translation, rotation and a
/// signed scale (#406). Unity keeps a Transform's localScale signed, so a
/// reflected or collapsed shape bone still has a rotation, which its
/// descendants' world rotation and DynamicBone's mirror compensation read; a
/// matrix alone cannot give that rotation back.
public struct SignedTRS: Sendable {
    public var translation: Float3, rotation: simd_quatf, scale: Float3
    public init(translation: Float3, rotation: simd_quatf, scale: Float3) {
        self.translation = translation; self.rotation = rotation; self.scale = scale
    }
    /// A scale with a component at or below zero (negative zero included):
    /// the only scales a record is kept for.
    @inline(__always) public static func needsRecord(_ scale: Float3) -> Bool { scale.x <= 0 || scale.y <= 0 || scale.z <= 0 }
    /// True while `local` is, bit for bit, `Transform.trs` of this record:
    /// any writer that changed the matrix since invalidated the record.
    public func describes(_ local: float4x4) -> Bool {
        let m = Transform.trs(translation, rotation, scale)
        func bits(_ c: Float4) -> SIMD4<UInt32> { unsafeBitCast(c, to: SIMD4<UInt32>.self) }
        return bits(m.columns.0) == bits(local.columns.0) && bits(m.columns.1) == bits(local.columns.1)
            && bits(m.columns.2) == bits(local.columns.2) && bits(m.columns.3) == bits(local.columns.3)
    }
}

public struct RigPose: Sendable {
    public var localMatrices: [float4x4]
    /// Signed TRS records of nodes whose scale has a component at or below
    /// zero, keyed by node (#406). Only the rest pose and the shape stages
    /// write them; a record counts only while it still `describes` its node's
    /// local matrix, so any other writer invalidates it by writing the matrix.
    /// Nil, with nothing allocated or retained on a copy, when no node has one.
    public var signedTRS: [Int: SignedTRS]?
    public init(rig: RigDefinition) { localMatrices = rig.nodes.map(\.localMatrix); signedTRS = rig.restSignedTRS }

    /// The record for `node` if it still describes the node's local matrix.
    @inline(__always) public func validSignedTRS(_ node: Int) -> SignedTRS? {
        guard let record = signedTRS?[node], record.describes(localMatrices[node]) else { return nil }
        return record
    }

    /// Keeps the table in step after a writer set `localMatrices[node]` to
    /// `Transform.trs(translation, rotation, scale)`: a non-positive scale is
    /// recorded, and a positive one drops any earlier record for the node.
    /// A positive write to a node without a record touches nothing.
    @inline(__always) public mutating func recordTRS(_ node: Int, translation: Float3, rotation: simd_quatf, scale: Float3) {
        if SignedTRS.needsRecord(scale) {
            if signedTRS == nil { signedTRS = [:] }
            signedTRS![node] = SignedTRS(translation: translation, rotation: rotation, scale: scale)
        } else if signedTRS?[node] != nil {
            // Checked first: removing an absent key would still copy a table
            // this pose shares with the pose it was copied from.
            signedTRS![node] = nil
            if signedTRS!.isEmpty { signedTRS = nil }
        }
    }
}

public struct RigEvaluation: Sendable {
    public let worldMatrices: [float4x4]
    /// Mesh-local palettes, drawn with `model(skin:meshNode:)`.
    public let palettes: [[float4x4]]
    /// Skins whose mesh world is singular (|det| at most
    /// `Transform.singularDeterminant`, #404). Their palettes are in rig
    /// space and draw with the identity model; the set is empty, with no
    /// allocation, when every mesh world is regular.
    public let collapsedSkins: Set<Int>

    /// The model matrix `palettes[skin]` is drawn with: the renderer node's
    /// world, or the identity for a collapsed skin.
    public func model(skin: Int, meshNode: Int) -> float4x4 {
        collapsedSkins.contains(skin) ? matrix_identity_float4x4 : worldMatrices[meshNode]
    }
}
