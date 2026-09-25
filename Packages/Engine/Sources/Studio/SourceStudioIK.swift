import Foundation
import simd
import CoreMath
import Scene

/// Restores source guide identities and executes recovered full-body mappings
/// when their serialized settings are present. Legacy bindings retain limb coverage.
public struct SourceStudioIK: Sendable {
    public struct Bindings: Decodable, Sendable {
        public struct NodeReference: Decodable, Sendable {
            public let sourceID: String
            public let name: String
        }
        public struct Target: Decodable, Sendable {
            public let id: Int32
            public let group: String
            public let rotationEnabled: Bool
            public let prefabTarget: NodeReference
        }
        public struct Limb: Decodable, Sendable {
            public let group: String
            public let targetIDs: [Int32]
            public let nodes: [NodeReference]
        }
        public let fullBody: SourceFullBodySettings?
        public let schemaVersion: Int
        public let root: NodeReference, pelvis: NodeReference, body: NodeReference
        public let iterations: Int
        public let pullBodyVertical: Float, pullBodyHorizontal: Float
        public let targets: [Target]
        public let limbs: [Limb]
    }
    public struct Guide: Sendable {
        public let targetID: Int32
        /// The saved object dictionary key is distinct from the 0...12 target ID.
        public let sourceKey: Int32?
        public let group: SourceStudioPose.Group
        public let rotationEnabled: Bool
        public let active: Bool
        public let position: Float3
        public let rotation: simd_quatf
    }
    public struct Result: Sendable {
        public let pose: RigPose
        public let guides: [Guide]
        public let appliedTargetIDs: Set<Int32>
        public let deferredTargetIDs: Set<Int32>
        /// Recovered left-then-right hand-pull prepass, applied through the body
        /// effector by schema-2 full-body bindings. Schema-1 only reports it.
        public let bodyPullOffset: Float3
        public let diagnostics: [String]
    }
    private struct Limb: Sendable {
        let group: SourceStudioPose.Group
        let targets: [Int32]
        let nodes: [Int]
    }
    private let ids: [String]
    private let parents: [Int?]
    private let bindings: Bindings
    private let targetNodes: [Int32: Int]
    private let limbs: [Limb]
    private let initializationPose: RigPose
    private let rootNode: Int
    private let fullBody: SourceFullBodyBiped?

    public init(rig: RigDefinition, bindings: Bindings, initializationPose: RigPose? = nil) throws {
        let expectedGroups = ["body", "leftArm", "leftArm", "leftArm", "rightArm", "rightArm", "rightArm", "leftLeg", "leftLeg", "leftLeg", "rightLeg", "rightLeg", "rightLeg"]
        guard [1, 2].contains(bindings.schemaVersion), (bindings.schemaVersion == 1 || bindings.fullBody != nil), bindings.targets.count == 13, bindings.limbs.count == 4,
              Set(bindings.targets.map(\.id)) == Set((0...12).map(Int32.init)),
              bindings.iterations >= 0, bindings.iterations <= 100,
              bindings.pullBodyVertical.isFinite, bindings.pullBodyHorizontal.isFinite,
              (-1...1).contains(bindings.pullBodyVertical), (-1...1).contains(bindings.pullBodyHorizontal) else {
            throw RigError.invalid("Studio IK binding does not match the recovered topology.")
        }
        func bind(_ reference: Bindings.NodeReference) throws -> Int {
            guard !reference.sourceID.isEmpty, reference.sourceID.utf8.count <= 1024 else { throw RigError.invalid("Invalid Studio IK source ID.") }
            let matches = rig.nodes.indices.filter {
                let node = rig.nodes[$0]
                return node.name == reference.name && (node.sourceID == reference.sourceID || node.sourceID.hasSuffix("/" + reference.sourceID))
            }
            guard matches.count == 1 else { throw RigError.invalid("Studio IK source transform \(reference.name) does not bind uniquely by identity.") }
            return matches[0]
        }
        var targets: [Int32: Int] = [:]
        for target in bindings.targets {
            guard target.group == expectedGroups[Int(target.id)], target.rotationEnabled == [3, 6, 9, 12].contains(target.id) else {
                throw RigError.invalid("Studio IK guide identity or rotation capability is inconsistent.")
            }
            targets[target.id] = try bind(target.prefabTarget)
        }
        var loaded: [Limb] = []
        let groups = ["leftArm", "rightArm", "leftLeg", "rightLeg"]
        for (index, limb) in bindings.limbs.enumerated() {
            guard limb.group == groups[index], limb.nodes.count == 3,
                  limb.targetIDs == [Int32(index * 3 + 1), Int32(index * 3 + 2), Int32(index * 3 + 3)] else {
                throw RigError.invalid("Studio IK limb order differs from the original chain order.")
            }
            let nodes = try limb.nodes.map(bind)
            func descendant(_ child: Int, of ancestor: Int) -> Bool {
                var current = rig.nodes[child].parent
                while let node = current { if node == ancestor { return true }; current = rig.nodes[node].parent }
                return false
            }
            guard Set(nodes).count == 3, descendant(nodes[1], of: nodes[0]), descendant(nodes[2], of: nodes[1]) else {
                throw RigError.invalid("Studio IK limb nodes are not an ordered hierarchy.")
            }
            loaded.append(.init(group: try Self.group(limb.group), targets: limb.targetIDs, nodes: nodes))
        }
        _ = try bind(bindings.body); _ = try bind(bindings.pelvis)
        rootNode = try bind(bindings.root)
        fullBody = try bindings.fullBody.map { try SourceFullBodyBiped(rig: rig, settings: $0, initialPose: initializationPose ?? rig.restPose, bind: bind) }
        if let fullBody {
            guard fullBody.chainBones[0] == [try bind(bindings.body)], Array(fullBody.chainBones.dropFirst()) == loaded.map(\.nodes) else {
                throw RigError.invalid("Full-body settings disagree with Studio guide/bone identities.")
            }
        }
        self.initializationPose = initializationPose ?? rig.restPose
        self.bindings = bindings; targetNodes = targets; self.limbs = loaded
        ids = rig.nodes.map(\.sourceID); parents = rig.nodes.map(\.parent)
    }

    /// `savedTargets` and `guideOverrides` contain raw Unity-local ChangeAmount
    /// values. Overrides change the pose without rewriting any saved dictionary ID.
    public func apply(rig: RigDefinition, baseline: RigPose, savedTargets: [Int32: KoikatsuBoneRecord],
                      enabled: Bool, activeGroups: [Bool], characterRoot: Int,
                      guideOverrides: [Int32: KoikatsuChangeAmount] = [:]) throws -> Result {
        guard rig.nodes.map(\.sourceID) == ids, rig.nodes.map(\.parent) == parents,
              activeGroups.count == 5, rig.nodes.indices.contains(characterRoot),
              guideOverrides.keys.allSatisfy({ (0...12).contains($0) }) else {
            throw RigError.invalid("Studio IK frame does not match its bound hierarchy or activation state.")
        }
        let original = try rig.evaluate(baseline).worldMatrices
        let initial = fullBody != nil ? try rig.evaluate(initializationPose).worldMatrices : original
        let parentWorld = original[characterRoot]
        let parentRotation = try SourceStudioGuide.rotation(node: characterRoot, rig: rig, pose: baseline)
        var guides: [Guide] = [], messages: [String] = []
        let unknown = savedTargets.keys.filter { !(0...12).contains($0) }.sorted()
        if !unknown.isEmpty { messages.append("Unrecognized saved IK target IDs retained: \(unknown).") }
        func active(_ group: SourceStudioPose.Group) -> Bool {
            enabled && (SourceStudioPose.Group.ikParts.firstIndex(of: group).map { activeGroups[$0] } ?? false)
        }
        for target in bindings.targets.sorted(by: { $0.id < $1.id }) {
            let source = guideOverrides[target.id] ?? savedTargets[target.id]?.transform
            let group = try Self.group(target.group)
            let position: Float3, rotation: simd_quatf
            if let source {
                guard Self.finite(source.position), Self.finite(source.rotationDegrees), Self.finite(source.scale) else {
                    throw RigError.invalid("Studio IK guide contains a nonfinite saved transform.")
                }
                // AddIKTarget creates a work transform parented to charInfo.
                // GuideObject.CalcPosition/CalcRotation apply local ChangeAmount.
                let point = parentWorld * Float4(UnityCoordinates.position(source.position), 1)
                position = Float3(point.x, point.y, point.z)
                rotation = target.rotationEnabled ? (parentRotation * UnityCoordinates.eulerDegrees(source.rotationDegrees)).normalized : parentRotation
            } else {
                let fallback: Int
                if fullBody != nil {
                    // IKCtrl.InitTargetCoroutine calls IKInfo.CopyBone. Prefab
                    // targets are placeholders, often all at the origin. Capture
                    // once at initialization; later animation must not drag a guide.
                    fallback = target.id == 0 ? try Self.boundIndex(bindings.pelvis, rig: rig) : limbs[(Int(target.id)-1)/3].nodes[(Int(target.id)-1)%3]
                } else { fallback = targetNodes[target.id]! }
                if fullBody != nil {
                    let initialParent = initial[characterRoot]
                    let local = initialParent.inverse * Float4(Self.position(initial[fallback]), 1)
                    let point = parentWorld * local
                    position = Float3(point.x, point.y, point.z)
                    if target.rotationEnabled {
                        let initialParentRotation = try SourceStudioGuide.rotation(node: characterRoot, rig: rig, pose: initializationPose)
                        let initialBoneRotation = try SourceStudioGuide.rotation(node: fallback, rig: rig, pose: initializationPose)
                        rotation = (parentRotation * initialParentRotation.inverse * initialBoneRotation).normalized
                    } else { rotation = parentRotation }
                } else {
                    position = Self.position(original[fallback])
                    rotation = target.rotationEnabled ? try SourceStudioGuide.rotation(node: fallback, rig: rig, pose: baseline) : parentRotation
                }
            }
            guides.append(.init(targetID: target.id, sourceKey: savedTargets[target.id]?.sourceKey, group: group,
                                rotationEnabled: target.rotationEnabled, active: active(group), position: position, rotation: rotation))
        }
        let byID = Dictionary(uniqueKeysWithValues: guides.map { ($0.targetID, $0) })
        var result = baseline, applied = Set<Int32>(), deferred = Set(unknown)
        var pull = Float3.zero
        if enabled, let fullBody {
            let solved = try fullBody.solve(rig: rig, pose: baseline, guides: guides, active: activeGroups,
                                            iterations: bindings.iterations, root: rootNode,
                                            vertical: bindings.pullBodyVertical, horizontal: bindings.pullBodyHorizontal)
            return .init(pose: solved.0, guides: guides, appliedTargetIDs: Set(guides.filter { $0.active && fullBody.settings.weight > 0 && (bindings.iterations > 0 || ![1,4,7,10].contains($0.targetID)) }.map(\.targetID)),
                         deferredTargetIDs: deferred, bodyPullOffset: solved.1, diagnostics: messages)
        }
        if enabled {
            messages.append("Rigid limb IK preview only: iterative FBBIK child constraints, effector planes, spine mapping and proximal/body target solving remain deferred.")
            // This is the exact sequential GetBodyOffset/PullBody prepass; expose it
            // as solver input rather than guessing how the unported spine uses it.
            if bindings.iterations > 0 {
                let left = limbs[0], right = limbs[1]
                func reach(_ limb: Limb) -> Float {
                    simd_distance(Self.position(original[limb.nodes[0]]), Self.position(original[limb.nodes[1]]))
                    + simd_distance(Self.position(original[limb.nodes[1]]), Self.position(original[limb.nodes[2]]))
                }
                let up = try Self.rotation(original[rootNode], uniform: false).act(Float3(0, 1, 0))
                pull = try Self.handBodyPull(leftRoot: Self.position(original[left.nodes[0]]), leftTarget: byID[3]!.position,
                    leftLength: reach(left), leftWeight: active(.leftArm) ? 1 : 0,
                    rightRoot: Self.position(original[right.nodes[0]]), rightTarget: byID[6]!.position,
                    rightLength: reach(right), rightWeight: active(.rightArm) ? 1 : 0,
                    up: up, vertical: bindings.pullBodyVertical, horizontal: bindings.pullBodyHorizontal)
                if simd_length_squared(pull) > 1e-12 { messages.append("Recovered hand-to-body pull is computed but deferred until the full-body constraint/spine stage is available.") }
            }
            if active(.body) { deferred.insert(0) }
            for limb in limbs where active(limb.group) {
                deferred.insert(limb.targets[0])
                do {
                    var candidate = result
                    let before = try rig.evaluate(candidate).worldMatrices
                    func bone(_ index: Int) throws -> SourceTrigonometricIK.Bone {
                        .init(position: Self.position(before[index]), rotation: try Self.rotation(before[index], uniform: true))
                    }
                    let input = try SourceTrigonometricIK.Pose(root: bone(limb.nodes[0]), middle: bone(limb.nodes[1]), end: bone(limb.nodes[2]))
                    let end = byID[limb.targets[2]]!, pole = byID[limb.targets[1]]!
                    var normal = simd_cross(pole.position - input.root.position, end.position - input.root.position)
                    if simd_length_squared(normal) < 1e-10 { normal = simd_cross(input.middle.position - input.root.position, input.end.position - input.middle.position) }
                    guard simd_length_squared(normal) >= 1e-10 else { throw RigError.invalid("Pole and limb are collinear.") }
                    var solver = try SourceTrigonometricIK(pose: input, bendNormal: normal)
                    try solver.setBendGoalPosition(pole.position, targetPosition: end.position, pose: input, weight: 1)
                    let solved = try solver.solve(pose: input, targetPosition: end.position, targetRotation: end.rotation)
                    for (index, rotation) in zip(limb.nodes, [solved.root.rotation, solved.middle.rotation, solved.end.rotation]) {
                        let world = try rig.evaluate(candidate).worldMatrices
                        let parent = try rig.nodes[index].parent.map { try Self.rotation(world[$0], uniform: true) } ?? .identity
                        let local = candidate.localMatrices[index]
                        let scale = Float3(simd_length(Float3(local[0].x, local[0].y, local[0].z)), simd_length(Float3(local[1].x, local[1].y, local[1].z)), simd_length(Float3(local[2].x, local[2].y, local[2].z)))
                        candidate.localMatrices[index] = Transform.trs(Self.position(local), (parent.inverse * rotation).normalized, scale)
                    }
                    let after = try rig.evaluate(candidate).worldMatrices
                    guard zip(limb.nodes, [solved.root.position, solved.middle.position, solved.end.position]).allSatisfy({ simd_distance(Self.position(after[$0.0]), $0.1) < 0.0001 }) else {
                        throw RigError.invalid("Intermediate/scaled hierarchy differs from the rigid-chain kernel.")
                    }
                    result = candidate
                    applied.formUnion([limb.targets[1], limb.targets[2]])
                } catch {
                    deferred.formUnion(limb.targets)
                    messages.append("IK limb \(limb.targets) retained its incoming pose: \(error)")
                }
            }
        }
        return .init(pose: result, guides: guides, appliedTargetIDs: applied, deferredTargetIDs: deferred,
                     bodyPullOffset: pull, diagnostics: messages)
    }

    /// IKSolverFullBodyBiped.GetBodyOffset is left-then-right, not a symmetric sum.
    public static func handBodyPull(leftRoot: Float3, leftTarget: Float3, leftLength: Float, leftWeight: Float,
                                    rightRoot: Float3, rightTarget: Float3, rightLength: Float, rightWeight: Float,
                                    up: Float3, vertical: Float, horizontal: Float) throws -> Float3 {
        guard [leftRoot, leftTarget, rightRoot, rightTarget, up].allSatisfy(finite),
              [leftLength, leftWeight, rightLength, rightWeight, vertical, horizontal].allSatisfy(\.isFinite),
              leftLength > 0, rightLength > 0, abs(simd_length(up) - 1) < 0.001 else {
            throw RigError.invalid("Invalid source hand/body pull input.")
        }
        func contribution(_ root: Float3, _ target: Float3, _ length: Float, _ offset: Float3) -> Float3 {
            let delta = target - (root + offset), distance = simd_length(delta)
            return distance <= length ? .zero : delta / distance * (distance - length)
        }
        var offset = contribution(leftRoot, leftTarget, leftLength, .zero) * min(1, max(0, leftWeight))
        offset += contribution(rightRoot, rightTarget, rightLength, offset) * min(1, max(0, rightWeight))
        let projected = up * simd_dot(offset, up)
        return projected * vertical + (offset - projected) * horizontal
    }

    private static func boundIndex(_ ref: Bindings.NodeReference, rig: RigDefinition) throws -> Int {
        guard let index = rig.nodes.firstIndex(where: { $0.name == ref.name && ($0.sourceID == ref.sourceID || $0.sourceID.hasSuffix("/" + ref.sourceID)) }) else { throw RigError.invalid("Missing full-body initialization bone.") }
        return index
    }
    private static func group(_ name: String) throws -> SourceStudioPose.Group {
        switch name {
        case "body": return .body
        case "leftArm": return .leftArm
        case "rightArm": return .rightArm
        case "leftLeg": return .leftLeg
        case "rightLeg": return .rightLeg
        default: throw RigError.invalid("Unknown Studio IK group.")
        }
    }
    private static func position(_ matrix: float4x4) -> Float3 { Float3(matrix[3].x, matrix[3].y, matrix[3].z) }
    private static func finite(_ value: Float3) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
    private static func rotation(_ matrix: float4x4, uniform: Bool) throws -> simd_quatf {
        let axes = [Float3(matrix[0].x, matrix[0].y, matrix[0].z), Float3(matrix[1].x, matrix[1].y, matrix[1].z), Float3(matrix[2].x, matrix[2].y, matrix[2].z)]
        let lengths = axes.map { simd_length($0) }
        guard lengths.allSatisfy({ $0.isFinite && $0 > 1e-7 }), !uniform || (lengths.max()! - lengths.min()! < lengths.max()! * 0.0001) else {
            throw RigError.invalid("Rigid IK cannot consume singular or nonuniform world scale.")
        }
        let unit = zip(axes, lengths).map { $0.0 / $0.1 }
        guard abs(simd_dot(unit[0], unit[1])) < 0.0001, abs(simd_dot(unit[0], unit[2])) < 0.0001,
              abs(simd_dot(unit[1], unit[2])) < 0.0001, simd_determinant(float3x3(columns: (unit[0], unit[1], unit[2]))) > 0 else {
            throw RigError.invalid("Rigid IK cannot consume sheared or reflected transforms.")
        }
        return simd_quatf(float3x3(columns: (unit[0], unit[1], unit[2]))).normalized
    }
}
