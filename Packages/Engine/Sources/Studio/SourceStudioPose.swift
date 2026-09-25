import Foundation
import simd
import CoreMath
import Scene

/// The recovered CharaStudio FK controller and kinematic activation state. This
/// applies FK rotations; IK events describe solver inputs, not an IK solver.
public struct SourceStudioPose: Sendable {
    public struct Group: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let body = Self(rawValue: 1), rightLeg = Self(rawValue: 2), leftLeg = Self(rawValue: 4)
        public static let rightArm = Self(rawValue: 8), leftArm = Self(rawValue: 16)
        public static let rightHand = Self(rawValue: 32), leftHand = Self(rawValue: 64)
        public static let hair = Self(rawValue: 128), neck = Self(rawValue: 256)
        public static let breast = Self(rawValue: 512), skirt = Self(rawValue: 1024)
        public static let fkParts: [Self] = [.hair, .neck, .breast, .body, .rightHand, .leftHand, .skirt]
        public static let ikParts: [Self] = [.body, .rightLeg, .leftLeg, .rightArm, .leftArm]
    }

    /// Entries retain the source dictionary iteration order. `group` is the
    /// catalog classification (0...13), not the OIBoneInfo flag mask.
    public struct Bone: Codable, Sendable, Equatable {
        public let id: Int
        public let name: String
        public let group: Int
        public let level: Int
        public init(id: Int, name: String, group: Int, level: Int) {
            self.id = id; self.name = name; self.group = group; self.level = level
        }
        public var fkGroup: Group {
            switch group {
            case 0...4: return .body
            case 7...9: return .hair
            case 10: return .neck
            case 11...12: return .breast
            case 13: return .skirt
            default: return Group(rawValue: 1 << (group & 31))
            }
        }
        public var guideGroup: Group { (0...4).contains(group) ? [.body, Group(rawValue: 1 << group)] : fkGroup }
    }

    public struct Target: Sendable {
        public let bone: Bone
        public let node: Int
        public let hasGuide: Bool
        public fileprivate(set) var rotation: Float3
        public fileprivate(set) var enabled: Bool = true
    }

    public enum Mode: Sendable { case fk, ik }
    public enum Effect: Sendable, Equatable {
        case neckLookPattern(Int)
        case breastDynamics(left: Bool, right: Bool)
        case hairDynamics(Bool)
        case skirtDynamics(Bool)
        case fkGuide(group: Group, active: Bool)
        case ikGuide(group: Group, active: Bool)
        /// Body: spine twist + body effector; limbs: mapping + proximal/distal
        /// effector position and rotation weights. All use the same 0/1 value.
        case ikWeights(group: Group, weight: Float)
        case pvCopy([Bool])
    }
    public struct Transition: Sendable {
        public fileprivate(set) var identityResetNodes: [Int] = []
        public fileprivate(set) var effects: [Effect] = []
        fileprivate mutating func append(_ other: Self) {
            identityResetNodes += other.identityResetNodes; effects += other.effects
        }
    }

    public private(set) var targets: [Target]
    public private(set) var enableFK = false
    public private(set) var enableIK = false
    public private(set) var activeFK = [false, true, false, true, false, false, false]
    public private(set) var activeIK = [true, true, true, true, true]
    public private(set) var neckLookPattern: Int
    public private(set) var previousNeckLookPattern: Int
    public var dynamicBreastLeft = true
    public var dynamicBreastRight = true
    private var pvEnabled = [true, true, true, true]
    private let sourceIDs: [String]
    private let sourceParents: [Int?]

    /// Combines AddObjectAssist.InitBone with FKCtrl.InitBones. Missing targets
    /// are skipped. Female level-2 entries get no guide or new record; an existing
    /// saved record still participates in FKCtrl, exactly as in the source.
    /// Roots and sibling ordering must come from the original transform tree.
    public init(rig: RigDefinition, bones: [Bone], rotations: [Int: Float3] = [:],
                characterRoot: Int, bodyRoot: Int? = nil, hairRoot: Int? = nil, sex: Int,
                neckLookPattern: Int = 0) throws {
        guard rig.nodes.indices.contains(characterRoot), hairRoot.map({ rig.nodes.indices.contains($0) }) ?? true,
              bodyRoot.map({ rig.nodes.indices.contains($0) }) ?? true,
              sex == 0 || sex == 1, bones.count <= 100_000,
              Set(bones.map(\.id)).count == bones.count,
              bones.allSatisfy({ Int32(exactly: $0.id) != nil && Int32(exactly: $0.level) != nil
                  && !$0.name.isEmpty && $0.name.utf8.count <= 1024 && (0...13).contains($0.group) }),
              rotations.keys.allSatisfy({ Int32(exactly: $0) != nil }), Int32(exactly: neckLookPattern) != nil,
              rotations.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw RigError.invalid("Studio FK requires valid unique catalog rows, finite rotations, and source hierarchy roots.")
        }
        var children = [[Int]](repeating: [], count: rig.nodes.count)
        for (index, node) in rig.nodes.enumerated() { if let parent = node.parent { children[parent].append(index) } }
        func first(named name: String, below root: Int?) -> Int? {
            guard let root else { return nil }
            var pending = [root]
            while let node = pending.popLast() {
                // The recovered catalog has ASCII transform names. Refuse
                // culture-sensitive aliases instead of approximating .NET collation.
                if rig.nodes[node].name.utf8.elementsEqual(name.utf8) { return node }
                pending.append(contentsOf: children[node].reversed())
            }
            return nil
        }
        targets = bones.compactMap { bone in
            let isHair = (7...9).contains(bone.group)
            let hasGuide = (sex != 1 || bone.level != 2)
                && first(named: bone.name, below: isHair ? hairRoot : bodyRoot ?? characterRoot) != nil
            guard hasGuide || rotations[bone.id] != nil,
                  let node = first(named: bone.name, below: isHair ? hairRoot : characterRoot) else { return nil }
            return Target(bone: bone, node: node, hasGuide: hasGuide, rotation: rotations[bone.id] ?? .zero)
        }
        sourceIDs = rig.nodes.map(\.sourceID)
        sourceParents = rig.nodes.map(\.parent)
        self.neckLookPattern = neckLookPattern; previousNeckLookPattern = neckLookPattern
    }

    public mutating func setRotation(boneID: Int, degrees: Float3) throws {
        guard degrees.x.isFinite && degrees.y.isFinite && degrees.z.isFinite,
              let index = targets.firstIndex(where: { $0.bone.id == boneID }) else {
            throw RigError.invalid("Studio FK rotation has no bound bone or contains a nonfinite angle.")
        }
        targets[index].rotation = degrees
    }

    /// Changes the preference even while FK is off. Force applies the requested
    /// state without changing saved preferences and repeats nonreactive effects.
    public mutating func activateFK(mask: Group, active: Bool, force: Bool = false) -> Transition {
        var transition = Transition()
        for (index, group) in Group.fkParts.enumerated() where !mask.intersection(group).isEmpty {
            if !force {
                guard activeFK[index] != active else { continue }
                activeFK[index] = active
                guard enableFK else { continue }
            }
            switch group {
            case .neck:
                if active { previousNeckLookPattern = neckLookPattern; neckLookPattern = 4 }
                else { neckLookPattern = previousNeckLookPattern }
                transition.effects.append(.neckLookPattern(neckLookPattern))
            case .breast:
                transition.effects.append(.breastDynamics(left: !active && dynamicBreastLeft, right: !active && dynamicBreastRight))
            default: break
            }
            for target in targets.indices where !targets[target].bone.fkGroup.intersection(group).isEmpty {
                // BoolReactiveProperty emits only on a change. Only these three
                // groups subscribe to the identity reset callback.
                if targets[target].enabled != active {
                    targets[target].enabled = active
                    if !active && !group.intersection([.hair, .body, .skirt]).isEmpty {
                        transition.identityResetNodes.append(targets[target].node)
                    }
                }
            }
            if group == .hair { transition.effects.append(.hairDynamics(!active)) }
            if group == .skirt { transition.effects.append(.skirtDynamics(!active)) }
            transition.effects.append(.fkGuide(group: group, active: force ? active : enableFK && activeFK[index]))
        }
        return transition
    }

    /// Unlike ActiveFK, source ActiveIK updates solver weights even with IK off.
    public mutating func activateIK(mask: Group, active: Bool, force: Bool = false) -> Transition {
        var transition = Transition()
        for (index, group) in Group.ikParts.enumerated() where !mask.intersection(group).isEmpty {
            if !force {
                guard activeIK[index] != active else { continue }
                activeIK[index] = active
            }
            transition.effects.append(.ikWeights(group: group, weight: active ? 1 : 0))
            transition.effects.append(.ikGuide(group: group, active: force ? active : enableIK && activeIK[index]))
        }
        return transition
    }

    public mutating func activateMode(_ mode: Mode, active: Bool, force: Bool = false) -> Transition {
        var transition = Transition()
        switch mode {
        case .fk:
            if force || enableFK != active {
                enableFK = active
                for (index, group) in Group.fkParts.enumerated() {
                    transition.append(activateFK(mask: group, active: active && activeFK[index], force: true))
                }
                if enableFK { transition.append(activateMode(.ik, active: false, force: force)) }
            }
        case .ik:
            if force || enableIK != active {
                enableIK = active
                for (index, group) in Group.ikParts.enumerated() {
                    transition.append(activateIK(mask: group, active: active && activeIK[index], force: true))
                }
                if enableIK { transition.append(activateMode(.fk, active: false, force: force)) }
            }
        }
        transition.effects.append(.pvCopy(pvEnabled.map { !enableFK && $0 }))
        return transition
    }

    /// Animation metadata changes these four source pole-vector copy flags.
    /// Their consumers are reported as effects and are not implemented here.
    public mutating func setPVEnabled(_ values: [Bool]) throws -> Effect {
        guard values.count == 4 else { throw RigError.invalid("Studio requires four pole-vector flags.") }
        pvEnabled = values
        return .pvCopy(values.map { !enableFK && $0 })
    }

    /// Apply immediately when an activation command executes, not on every frame.
    public func applying(_ transition: Transition, rig: RigDefinition, pose: RigPose) throws -> RigPose {
        try validate(rig: rig, pose: pose)
        var result = pose
        for node in transition.identityResetNodes {
            guard rig.nodes.indices.contains(node) else { throw RigError.invalid("Studio transition targets a different rig.") }
            result.localMatrices[node] = try replacingRotation(.identity, node: node, rig: rig, matrix: result.localMatrices[node])
        }
        _ = try rig.evaluate(result)
        return result
    }

    /// Execute after the upstream frame pose. Each active target overwrites local
    /// rotation (not a rest-relative delta); dictionary iteration order wins when
    /// multiple source records resolve to one transform. No frame accumulation.
    public func applyingLateUpdate(rig: RigDefinition, pose: RigPose) throws -> RigPose {
        try validate(rig: rig, pose: pose)
        guard enableFK else { return pose }
        var result = pose
        for target in targets where target.enabled {
            result.localMatrices[target.node] = try replacingRotation(UnityCoordinates.eulerDegrees(target.rotation),
                node: target.node, rig: rig, matrix: result.localMatrices[target.node])
        }
        _ = try rig.evaluate(result)
        return result
    }

    private func validate(rig: RigDefinition, pose: RigPose) throws {
        guard rig.nodes.map(\.sourceID) == sourceIDs, rig.nodes.map(\.parent) == sourceParents else {
            throw RigError.invalid("Studio FK is bound to a different hierarchy.")
        }
        _ = try rig.evaluate(pose)
    }

    private func replacingRotation(_ rotation: simd_quatf, node: Int, rig: RigDefinition, matrix: float4x4) throws -> float4x4 {
        let authored = rig.nodes[node]
        guard authored.authoredMatrix == nil, (0..<3).allSatisfy({ authored.scale[$0] > 0 }) else {
            throw RigError.invalid("Studio FK cannot infer signed or matrix-authored local scales for '\(authored.name)'.")
        }
        let x = Float3(matrix[0].x, matrix[0].y, matrix[0].z)
        let y = Float3(matrix[1].x, matrix[1].y, matrix[1].z)
        let z = Float3(matrix[2].x, matrix[2].y, matrix[2].z)
        let scale = Float3(simd_length(x), simd_length(y), simd_length(z))
        guard (0..<3).allSatisfy({ scale[$0].isFinite && scale[$0] > 1e-8 }),
              simd_determinant(float3x3(columns: (x, y, z))) > 0,
              abs(simd_dot(x / scale.x, y / scale.y)) < 1e-4,
              abs(simd_dot(x / scale.x, z / scale.z)) < 1e-4,
              abs(simd_dot(y / scale.y, z / scale.z)) < 1e-4 else {
            throw RigError.invalid("Studio FK requires positive orthogonal local TRS for '\(authored.name)'.")
        }
        return Transform.trs(Float3(matrix[3].x, matrix[3].y, matrix[3].z), rotation, scale)
    }
}
