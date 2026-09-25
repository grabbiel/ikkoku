import Foundation
import simd
import CoreMath
import Scene

/// Explicit, already converted DynamicBone data. Distribution curves are baked
/// at the source particle lengths by the converter. No name-based guessing.
public struct SourceDynamicsDocument: Codable, Sendable {
    public struct Particle: Codable, Sendable {
        public var nodeID: String
        public var parent: Int?
        public var damping: Float, elasticity: Float, stiffness: Float, inert: Float, radius: Float
        public init(nodeID: String, parent: Int?, damping: Float = 0.1, elasticity: Float = 0.1,
                    stiffness: Float = 0.1, inert: Float = 0, radius: Float = 0) {
            self.nodeID = nodeID; self.parent = parent; self.damping = damping; self.elasticity = elasticity
            self.stiffness = stiffness; self.inert = inert; self.radius = radius
        }
    }
    public struct Collider: Codable, Sendable {
        public var nodeID: String, center: Float3
        public var radius: Float, height: Float
        public var direction: Int, bound: Int
        public var enabled: Bool
        public init(nodeID: String, center: Float3 = .zero, radius: Float, height: Float = 0,
                    direction: Int = 0, bound: Int = 0, enabled: Bool = true) {
            self.nodeID = nodeID; self.center = center; self.radius = radius; self.height = height
            self.direction = direction; self.bound = bound; self.enabled = enabled
        }
    }
    public struct Component: Codable, Sendable {
        public var sourceID: String, ownerID: String
        public var updateRate: Float, gravity: Float3, force: Float3
        public var freezeAxis: Int
        public var particles: [Particle]
        public var colliders: [Collider]
        public init(sourceID: String, ownerID: String, updateRate: Float = 60,
                    gravity: Float3 = .zero, force: Float3 = .zero, freezeAxis: Int = 0,
                    particles: [Particle], colliders: [Collider] = []) {
            self.sourceID = sourceID; self.ownerID = ownerID; self.updateRate = updateRate
            self.gravity = gravity; self.force = force; self.freezeAxis = freezeAxis
            self.particles = particles; self.colliders = colliders
        }
    }
    public var schemaVersion: Int, coordinateSpace: String
    public var components: [Component]
    public init(components: [Component]) {
        schemaVersion = 1; coordinateSpace = "native-right-handed-y-up"; self.components = components
    }
    public static func load(url: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024 else { throw RigError.invalid("Dynamics document exceeds 16 MiB.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.coordinateSpace == "native-right-handed-y-up",
              value.components.count <= 256 else { throw RigError.invalid("Unsupported dynamics document.") }
        return value
    }
}

/// Particle update and transform application from this installation's DynamicBone.
/// This version supports real transforms with positive local TRS. Virtual ends,
/// exclusion/notRoll topology and signed scales must be rejected by the exporter.
public struct SourceDynamicBone: Sendable {
    public private(set) var positions: [Float3]
    public private(set) var previousPositions: [Float3]
    public private(set) var remainder: Float = 0
    public private(set) var lastStepCount = 0
    public private(set) var weight: Float = 1
    public let definition: SourceDynamicsDocument.Component
    private let nodes: [Int], colliderNodes: [Int], owner: Int
    private let requiredNodes: Set<Int>
    private let rigIDs: [String], initialPosition: [Float3], initialRotation: [simd_quatf]
    private let localGravity: Float3
    private var previousOwner: Float3

    public init(rig: RigDefinition, pose: RigPose? = nil, definition: SourceDynamicsDocument.Component) throws {
        guard definition.updateRate.isFinite, definition.updateRate >= 0,
              definition.updateRate <= 10_000, (0...3).contains(definition.freezeAxis),
              finite(definition.gravity), finite(definition.force),
              !definition.particles.isEmpty, definition.particles.count <= 4096,
              definition.colliders.count <= 1024 else { throw RigError.invalid("Invalid source dynamics configuration.") }
        let ids = Dictionary(uniqueKeysWithValues: rig.nodes.enumerated().map { ($0.element.sourceID, $0.offset) })
        func resolve(_ id: String) throws -> Int {
            guard let index = ids[id] else { throw RigError.invalid("Missing dynamics transform: \(id)") }; return index
        }
        let nodes = try definition.particles.map { try resolve($0.nodeID) }
        guard Set(nodes).count == nodes.count else { throw RigError.invalid("Duplicate dynamic particle transform.") }
        for (i, p) in definition.particles.enumerated() {
            guard [p.damping, p.elasticity, p.stiffness, p.inert].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  p.radius.isFinite, p.radius >= 0 else { throw RigError.invalid("Invalid dynamics particle parameters.") }
            if i == 0 {
                guard p.parent == nil else { throw RigError.invalid("Dynamic root must not have a particle parent.") }
            } else {
                guard let parent = p.parent, parent >= 0, parent < i,
                      rig.nodes[nodes[i]].parent == nodes[parent] else {
                    throw RigError.invalid("Unsupported dynamics particle topology.")
                }
            }
        }
        for c in definition.colliders {
            guard finite(c.center), c.radius.isFinite, c.radius >= 0, c.height.isFinite, c.height >= 0,
                  (0...2).contains(c.direction), (0...1).contains(c.bound) else { throw RigError.invalid("Invalid dynamic collider.") }
        }
        let colliderNodes = try definition.colliders.map { try resolve($0.nodeID) }
        let owner = try resolve(definition.ownerID)
        var required = Set(nodes + colliderNodes + [owner])
        for node in required { var parent = rig.nodes[node].parent; while let index = parent { required.insert(index); parent = rig.nodes[index].parent } }
        let state = try DynamicsTransforms(rig: rig, pose: pose ?? rig.restPose, requiredNodes: required)
        self.definition = definition; self.nodes = nodes; self.colliderNodes = colliderNodes
        self.owner = owner; self.requiredNodes = required; rigIDs = rig.nodes.map(\.sourceID)
        positions = nodes.map { state.world[$0].translation }; previousPositions = positions
        previousOwner = state.world[owner].translation
        initialPosition = nodes.map { state.translations[$0] }; initialRotation = nodes.map { state.rotations[$0] }
        localGravity = state.worldRotations[nodes[0]].inverse.act(definition.gravity)
    }

    /// Source Update/OnDisable reset positions and rotations, retaining scale.
    public func resettingTransforms(rig: RigDefinition, pose: RigPose) throws -> RigPose {
        try validate(rig)
        var state = try DynamicsTransforms(rig: rig, pose: pose, requiredNodes: requiredNodes)
        for (i, node) in nodes.enumerated() {
            state.translations[node] = initialPosition[i]; state.rotations[node] = initialRotation[i]; state.changed.insert(node)
        }
        return try state.pose(rig: rig)
    }

    public mutating func resetParticles(rig: RigDefinition, pose: RigPose) throws {
        try validate(rig)
        let state = try DynamicsTransforms(rig: rig, pose: pose, requiredNodes: requiredNodes)
        positions = nodes.map { state.world[$0].translation }; previousPositions = positions
        previousOwner = state.world[owner].translation
        // Source ResetParticlesPosition does not reset accumulated time.
    }

    public mutating func setWeight(_ value: Float, rig: RigDefinition, pose: RigPose) throws -> RigPose {
        guard value.isFinite, (0...1).contains(value) else { throw RigError.invalid("Dynamics weight must be within 0...1.") }
        var candidate = self
        let result: RigPose
        if value != weight && value == 0 { result = try resettingTransforms(rig: rig, pose: pose) }
        else { result = pose; if value != weight && weight == 0 { try candidate.resetParticles(rig: rig, pose: pose) } }
        candidate.weight = value; self = candidate; return result
    }

    /// Call once in the late-frame phase, after upstream animation. State commits
    /// only after all matrices/particles pass validation. Forces are per step,
    /// as in the source; they are not multiplied by deltaTime.
    public mutating func step(deltaTime: Float, rig: RigDefinition, pose: RigPose) throws -> RigPose {
        guard deltaTime.isFinite, deltaTime >= 0 else { throw RigError.invalid("Dynamics delta must be finite and nonnegative.") }
        try validate(rig)
        guard weight > 0 else { return pose }
        var candidate = self
        let result = try candidate.advance(deltaTime: deltaTime, rig: rig, pose: pose)
        self = candidate; return result
    }

    private func validate(_ rig: RigDefinition) throws {
        guard rig.nodes.map(\.sourceID) == rigIDs else { throw RigError.invalid("Dynamics state belongs to a different rig.") }
    }

    private mutating func advance(deltaTime: Float, rig: RigDefinition, pose: RigPose) throws -> RigPose {
        var state = try DynamicsTransforms(rig: rig, pose: pose, requiredNodes: requiredNodes)
        let objectScale = length(state.world[owner][0].xyz)
        var movement = state.world[owner].translation - previousOwner
        previousOwner = state.world[owner].translation
        var steps = 1
        if definition.updateRate > 0 {
            let interval: Float = 1 / definition.updateRate
            remainder += deltaTime
            guard remainder.isFinite else { throw RigError.invalid("Dynamics clock overflow.") }
            steps = 0
            while remainder >= interval {
                remainder -= interval; steps += 1
                if steps >= 3 { remainder = 0; break }
            }
        }
        lastStepCount = steps
        let normal = normalizedOrZero(definition.gravity)
        let transformedGravity = state.worldRotations[nodes[0]].act(localGravity)
        let removed = normal * max(dot(transformedGravity, normal), 0)
        let force = (definition.gravity - removed + definition.force) * objectScale
        for _ in 0..<steps {
            for (i, particle) in definition.particles.enumerated() {
                if particle.parent != nil {
                    let velocity = positions[i] - previousPositions[i]
                    let inertMovement = movement * particle.inert
                    previousPositions[i] = positions[i] + inertMovement
                    positions[i] += velocity * (1 - particle.damping) + force + inertMovement
                } else { previousPositions[i] = positions[i]; positions[i] = state.world[nodes[i]].translation }
            }
            constrain(state: state, objectScale: objectScale, simulate: true)
            movement = .zero
        }
        if steps == 0 {
            for (i, particle) in definition.particles.enumerated() {
                if particle.parent != nil { previousPositions[i] += movement; positions[i] += movement }
                else { previousPositions[i] = positions[i]; positions[i] = state.world[nodes[i]].translation }
            }
            constrain(state: state, objectScale: objectScale, simulate: false)
        }
        guard positions.allSatisfy(finite), previousPositions.allSatisfy(finite) else { throw RigError.invalid("Dynamic particles overflowed.") }
        for i in 1..<nodes.count {
            let parent = definition.particles[i].parent!, parentNode = nodes[parent], node = nodes[i]
            if state.children[parentNode].count <= 1 {
                let from = state.worldRotations[parentNode].act(state.translations[node])
                let to = positions[i] - positions[parent]
                if length_squared(from) > 1e-12 && length_squared(to) > 1e-12 {
                    let rotation = simd_quatf.rotation(from: from, to: to) * state.worldRotations[parentNode]
                    state.rotations[parentNode] = (rig.nodes[parentNode].parent.map { state.worldRotations[$0].inverse * rotation } ?? rotation).normalized
                    state.changed.insert(parentNode); state.updateSubtree(parentNode, rig: rig)
                }
            }
            if let parentNode = rig.nodes[node].parent {
                guard abs(simd_determinant(state.world[parentNode])) > 1e-12 else { throw RigError.invalid("Singular dynamics parent.") }
                state.translations[node] = state.world[parentNode].inverse.transformPoint(positions[i])
            } else { state.translations[node] = positions[i] }
            state.changed.insert(node); state.updateSubtree(node, rig: rig)
        }
        return try state.pose(rig: rig)
    }

    private mutating func constrain(state: DynamicsTransforms, objectScale: Float, simulate: Bool) {
        for i in 1..<nodes.count {
            let particle = definition.particles[i], parent = particle.parent!
            let parentNode = nodes[parent], node = nodes[i]
            let boneLength = length(state.world[parentNode].translation - state.world[node].translation)
            let stiffness = 1 + (particle.stiffness - 1) * weight
            if stiffness > 0 || (simulate && particle.elasticity > 0) {
                let desired = positions[parent] + state.world[parentNode].transformDirection(state.translations[node])
                if simulate { positions[i] += (desired - positions[i]) * particle.elasticity }
                if stiffness > 0 {
                    let delta = desired - positions[i], distance = length(delta)
                    let limit = boneLength * (1 - stiffness) * 2
                    if distance > limit { positions[i] += delta * ((distance - limit) / distance) }
                }
            }
            if simulate {
                for (j, collider) in definition.colliders.enumerated() where collider.enabled {
                    positions[i] = Self.collideUnchecked(position: positions[i], particleRadius: particle.radius * objectScale,
                        collider: collider, matrix: state.world[colliderNodes[j]])
                }
                if definition.freezeAxis != 0 {
                    var axis = Float3.zero; axis[definition.freezeAxis - 1] = 1
                    let normal = state.worldRotations[parentNode].act(axis)
                    positions[i] -= normal * dot(normal, positions[i] - positions[parent])
                }
            }
            let delta = positions[parent] - positions[i], distance = length(delta)
            if distance > 0 { positions[i] += delta * ((distance - boneLength) / distance) }
        }
    }

    /// Source collider uses abs(lossyScale.z), (height-radius)/2, and radius PLUS
    /// particleRadius for both Inside and Outside. These are intentional.
    public static func collide(position: Float3, particleRadius: Float,
                               collider: SourceDynamicsDocument.Collider, matrix: float4x4) throws -> Float3 {
        guard finite(position), particleRadius.isFinite, particleRadius >= 0,
              finite(collider.center), collider.radius.isFinite, collider.radius >= 0,
              collider.height.isFinite, collider.height >= 0, (0...2).contains(collider.direction),
              (0...1).contains(collider.bound), (0..<4).allSatisfy({ c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }) else {
            throw RigError.invalid("Invalid collider input.")
        }
        let result = collideUnchecked(position: position, particleRadius: particleRadius, collider: collider, matrix: matrix)
        guard finite(result) else { throw RigError.invalid("Collider output overflowed.") }
        return result
    }

    private static func collideUnchecked(position: Float3, particleRadius: Float,
                                         collider: SourceDynamicsDocument.Collider, matrix: float4x4) -> Float3 {
        let radius = collider.radius * length(matrix[2].xyz) + particleRadius
        let half = (collider.height - collider.radius) * 0.5
        func changes(_ distance2: Float) -> Bool {
            collider.bound == 0 ? (distance2 > 0 && distance2 < radius * radius) : distance2 > radius * radius
        }
        func sphere(_ center: Float3) -> Float3 {
            let delta = position - center, distance2 = length_squared(delta)
            return changes(distance2) ? center + delta * (radius / sqrt(distance2)) : position
        }
        if half <= 0 { return sphere(matrix.transformPoint(collider.center)) }
        var a = collider.center, b = collider.center
        a[collider.direction] -= half; b[collider.direction] += half
        a = matrix.transformPoint(a); b = matrix.transformPoint(b)
        let segment = b - a
        var offset = position - a
        let along = dot(offset, segment), segmentLength2 = length_squared(segment)
        if along <= 0 { return sphere(a) }
        if along >= segmentLength2 { return sphere(b) }
        if segmentLength2 > 0 {
            // Keep the source subtraction order: reassociating through a closest
            // point can invent a tiny radial vector on the exact capsule axis.
            offset -= segment * (along / segmentLength2)
            let distance2 = length_squared(offset)
            if changes(distance2) {
                let distance = sqrt(distance2)
                return position + offset * ((radius - distance) / distance)
            }
        }
        return position
    }
}

private func finite(_ v: Float3) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
private func normalizedOrZero(_ v: Float3) -> Float3 { let n = length(v); return n > 1e-5 ? v / n : .zero }
private extension SIMD4 where Scalar == Float { var xyz: Float3 { Float3(x, y, z) } }

/// Unity world rotation is the product of local rotations, not a decomposition
/// of a possibly sheared world matrix produced by nonuniform ancestor scales.
private struct DynamicsTransforms {
    var translations: [Float3], rotations: [simd_quatf], scales: [Float3]
    var world: [float4x4], worldRotations: [simd_quatf]
    let original: [float4x4]
    var changed = Set<Int>()
    var children: [[Int]]
    init(rig: RigDefinition, pose: RigPose, requiredNodes: Set<Int>) throws {
        guard pose.localMatrices.count == rig.nodes.count else { throw RigError.invalid("Dynamics pose count mismatch.") }
        translations = []; rotations = []; scales = []
        original = pose.localMatrices; children = Array(repeating: [], count: rig.nodes.count)
        for (i, node) in rig.nodes.enumerated() { if let parent = node.parent { children[parent].append(i) } }
        for (i, m) in pose.localMatrices.enumerated() {
            let scale = m.scaleFactors
            // Unrelated authored matrices (for example a mirrored accessory) are
            // carried through verbatim. Only particle/collider/owner ancestors
            // need local quaternion decomposition for this component.
            if !requiredNodes.contains(i) {
                translations.append(m.translation); rotations.append(.identity); scales.append(scale); continue
            }
            guard rig.nodes[i].authoredMatrix == nil, rig.nodes[i].scale.x > 0, rig.nodes[i].scale.y > 0, rig.nodes[i].scale.z > 0,
                  finite(m.translation), finite(scale), min(scale.x, min(scale.y, scale.z)) > 1e-6,
                  m[0].w == 0, m[1].w == 0, m[2].w == 0, m[3].w == 1 else {
                throw RigError.invalid("Dynamics requires finite positive local TRS.")
            }
            let r = float3x3(m[0].xyz / scale.x, m[1].xyz / scale.y, m[2].xyz / scale.z)
            guard abs(simd_determinant(r) - 1) < 1e-3,
                  abs(dot(r[0], r[1])) < 1e-4, abs(dot(r[0], r[2])) < 1e-4, abs(dot(r[1], r[2])) < 1e-4 else {
                throw RigError.invalid("Dynamics does not support local shear/reflection.")
            }
            translations.append(m.translation); rotations.append(simd_quatf(r).normalized); scales.append(scale)
        }
        world = .init(repeating: matrix_identity_float4x4, count: rig.nodes.count)
        worldRotations = .init(repeating: .identity, count: rig.nodes.count); update(rig: rig)
    }
    mutating func update(rig: RigDefinition) {
        for i in rig.order { updateNode(i, rig: rig) }
    }
    mutating func updateSubtree(_ root: Int, rig: RigDefinition) {
        var pending = [root]
        while let i = pending.popLast() { updateNode(i, rig: rig); pending += children[i] }
    }
    private mutating func updateNode(_ i: Int, rig: RigDefinition) {
        let local = changed.contains(i) ? Transform.trs(translations[i], rotations[i], scales[i]) : original[i]
        if let parent = rig.nodes[i].parent {
            world[i] = world[parent] * local; worldRotations[i] = (worldRotations[parent] * rotations[i]).normalized
        } else { world[i] = local; worldRotations[i] = rotations[i] }
    }
    func pose(rig: RigDefinition) throws -> RigPose {
        var value = rig.restPose
        value.localMatrices = original
        for i in changed { value.localMatrices[i] = Transform.trs(translations[i], rotations[i], scales[i]) }
        _ = try rig.evaluate(value); return value
    }
}
