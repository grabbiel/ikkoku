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

    public let nodes: [Node]
    public let skins: [Skin]
    public let order: [Int]
    public let activeNodes: [Bool]
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
    }

    public func nodes(named name: String) -> [Int] { names[name] ?? [] }
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
        let palettes = try skins.enumerated().map { index, skin -> [float4x4] in
            let meshWorld = world[skin.meshNode]
            guard abs(simd_determinant(meshWorld)) > 1e-12 else { throw RigError.invalid("Skin \(index) has a singular mesh transform.") }
            let meshInverse = simd_inverse(meshWorld)
            let matrices = zip(skin.joints, skin.inverseBindMatrices).map { meshInverse * world[$0] * $1 }
            guard matrices.allSatisfy(Self.isFiniteAffine) else { throw RigError.invalid("Skin \(index) produced a nonfinite palette.") }
            return matrices
        }
        return RigEvaluation(worldMatrices: world, palettes: palettes)
    }

    static func isFiniteAffine(_ matrix: float4x4) -> Bool {
        for column in 0..<4 { for row in 0..<4 where !matrix[column][row].isFinite { return false } }
        return abs(matrix[0].w) < 1e-5 && abs(matrix[1].w) < 1e-5 && abs(matrix[2].w) < 1e-5 && abs(matrix[3].w - 1) < 1e-5
    }
}

public struct RigPose: Sendable {
    public var localMatrices: [float4x4]
    public init(rig: RigDefinition) { localMatrices = rig.nodes.map(\.localMatrix) }
}

public struct RigEvaluation: Sendable {
    public let worldMatrices: [float4x4]
    /// Mesh-local palettes. Draw with the corresponding mesh node's world matrix.
    public let palettes: [[float4x4]]
}
