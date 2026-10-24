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
        public enum Group: String, Codable, Sendable { case hair, skirt, clothes }
        /// Schema 1 omits this field and is strictly hair-only.
        public var group: Group?
        public var clothesKind: Int?
        public var sourceID: String, ownerID: String
        public var updateRate: Float, gravity: Float3, force: Float3
        public var freezeAxis: Int
        public var particles: [Particle]
        public var colliders: [Collider]
        public init(sourceID: String, ownerID: String, updateRate: Float = 60,
                    gravity: Float3 = .zero, force: Float3 = .zero, freezeAxis: Int = 0,
                    particles: [Particle], colliders: [Collider] = [], group: Group? = nil, clothesKind: Int? = nil) {
            self.sourceID = sourceID; self.ownerID = ownerID; self.updateRate = updateRate
            self.gravity = gravity; self.force = force; self.freezeAxis = freezeAxis
            self.particles = particles; self.colliders = colliders; self.group = group; self.clothesKind = clothesKind
        }
    }
    public struct Rejection: Codable, Sendable {
        public let sourceID: String, ownerID: String?, reason: String, detail: String
    }
    public var rejected: [Rejection]?
    public var schemaVersion: Int, coordinateSpace: String
    public var components: [Component]
    public init(components: [Component], schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion; coordinateSpace = "native-right-handed-y-up"; self.components = components
    }
    public static func load(url: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024 else { throw RigError.invalid("Dynamics document exceeds 16 MiB.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard (1...2).contains(value.schemaVersion), value.coordinateSpace == "native-right-handed-y-up",
              value.components.count <= 256, (value.rejected?.count ?? 0) <= 4096 else { throw RigError.invalid("Unsupported dynamics document.") }
        try value.validateGroups()
        return value
    }
    public func validateGroups() throws {
        guard (1...2).contains(schemaVersion) else { throw RigError.invalid("Unsupported dynamics schema.") }
        for component in components {
            if schemaVersion == 1 {
                guard component.group == nil || component.group == .hair, component.clothesKind == nil,
                      component.ownerID.hasPrefix("hair-") else { throw RigError.invalid("Schema 1 dynamics is hair-only.") }
            } else {
                guard let group = component.group else { throw RigError.invalid("Schema 2 dynamics requires explicit groups.") }
                switch group {
                case .hair:
                    guard component.clothesKind == nil, component.ownerID.hasPrefix("hair-") else { throw RigError.invalid("Invalid hair dynamics identity.") }
                case .skirt, .clothes:
                    guard let kind = component.clothesKind, (0...1).contains(kind),
                          component.ownerID.hasPrefix("clothes-\(kind)/") else { throw RigError.invalid("Invalid clothes dynamics identity.") }
                }
            }
        }
    }
}

/// Particle update and transform application from this installation's DynamicBone.
/// This version supports real transforms with positive local TRS. Virtual ends,
/// exclusions, reparenting notRoll topology and signed scales must be rejected
/// by the exporter. Truncated notRoll chains retain direct transform parents.
public struct SourceDynamicBone: Sendable {
    public private(set) var positions: [Float3]
    public private(set) var previousPositions: [Float3]
    public private(set) var remainder: Float = 0
    public private(set) var lastStepCount = 0
    public private(set) var weight: Float = 1
    public let definition: SourceDynamicsDocument.Component
    /// Compact transform slots (see `DynamicsTopology`) of the particles, the
    /// colliders and the owner.
    private let nodes: [Int], colliderNodes: [Int], owner: Int
    private let topology: DynamicsTopology
    private let initialPosition: [Float3], initialRotation: [simd_quatf]
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
        // The hierarchy is immutable for a bound component, so its topology
        // (which transforms the step reads and which its output changes) is
        // resolved once here and shared by every copy of the component.
        let topology = DynamicsTopology(rig: rig, particles: nodes, colliders: colliderNodes, owner: owner)
        let state = try DynamicsTransforms(topology: topology, rig: rig, pose: pose ?? rig.restPose)
        self.definition = definition; self.topology = topology
        self.nodes = nodes.map(topology.slot); self.colliderNodes = colliderNodes.map(topology.slot); self.owner = topology.slot(owner)
        positions = self.nodes.map { state.world[$0].translation }; previousPositions = positions
        previousOwner = state.world[self.owner].translation
        initialPosition = self.nodes.map { state.translations[$0] }; initialRotation = self.nodes.map { state.rotations[$0] }
        localGravity = state.worldRotations[self.nodes[0]].inverse.act(definition.gravity)
    }

    /// Source Update/OnDisable reset positions and rotations, retaining scale.
    public func resettingTransforms(rig: RigDefinition, pose: RigPose) throws -> RigPose {
        try validate(rig)
        var state = try DynamicsTransforms(topology: topology, rig: rig, pose: pose)
        for (i, node) in nodes.enumerated() {
            state.translations[node] = initialPosition[i]; state.rotations[node] = initialRotation[i]; state.changed[node] = true
        }
        return try state.pose(pose, rig: rig, validatedInput: false)
    }

    public mutating func resetParticles(rig: RigDefinition, pose: RigPose) throws {
        try validate(rig)
        let state = try DynamicsTransforms(topology: topology, rig: rig, pose: pose)
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
        try step(deltaTime: deltaTime, rig: rig, pose: pose, validatedInput: false)
    }

    /// `step` for a caller that knows `pose` passes `rig.evaluate` (for
    /// example the output of an earlier component's step). The output then
    /// differs from that valid input only in this component's particle
    /// subtree, so only that subtree, and the skin palette entries it moves,
    /// are checked: the same checks `rig.evaluate` makes, in its order and
    /// with its messages, so the step throws exactly when `rig.evaluate` of
    /// its output would. With `validatedInput: false` it is `step`.
    package mutating func step(deltaTime: Float, rig: RigDefinition, pose: RigPose, validatedInput: Bool) throws -> RigPose {
        guard deltaTime.isFinite, deltaTime >= 0 else { throw RigError.invalid("Dynamics delta must be finite and nonnegative.") }
        try validate(rig)
        guard weight > 0 else { return pose }
        var candidate = self
        let state = try candidate.advance(deltaTime: deltaTime, rig: rig, pose: pose)
        let result = try state.pose(pose, rig: rig, validatedInput: validatedInput)
        self = candidate; return result
    }

    private func validate(_ rig: RigDefinition) throws {
        guard topology.matches(rig) else { throw RigError.invalid("Dynamics state belongs to a different rig.") }
    }

    private mutating func advance(deltaTime: Float, rig: RigDefinition, pose: RigPose) throws -> DynamicsTransforms {
        var state = try DynamicsTransforms(topology: topology, rig: rig, pose: pose)
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
            if topology.childCount[parentNode] <= 1 {
                let from = state.worldRotations[parentNode].act(state.translations[node])
                let to = positions[i] - positions[parent]
                if length_squared(from) > 1e-12 && length_squared(to) > 1e-12 {
                    let rotation = simd_quatf.rotation(from: from, to: to) * state.worldRotations[parentNode]
                    let grandparent = topology.parent[parentNode]
                    state.rotations[parentNode] = (grandparent >= 0 ? state.worldRotations[grandparent].inverse * rotation : rotation).normalized
                    state.changed[parentNode] = true; state.updateSubtree(parentNode)
                }
            }
            let nodeParent = topology.parent[node]
            if nodeParent >= 0 {
                guard abs(simd_determinant(state.world[nodeParent])) > 1e-12 else { throw RigError.invalid("Singular dynamics parent.") }
                state.translations[node] = state.world[nodeParent].inverse.transformPoint(positions[i])
            } else { state.translations[node] = positions[i] }
            state.changed[node] = true; state.updateSubtree(node)
        }
        return state
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

/// A bound component's view of its rig, resolved once and shared by every
/// copy of the component (the state of a session, its initial state, a
/// candidate step).
///
/// - The step reads only the particles, the colliders, the owner and their
///   ancestors: the required set, which is ancestor-closed. Each required node
///   has a compact slot; slots ascend with the node index.
/// - The step writes only particle transforms, so its output differs from its
///   input only inside the root particle's subtree (every particle descends
///   from the root particle). `validateChanges` checks just that subtree and
///   the skin palette entries it moves.
private final class DynamicsTopology: Sendable {
    /// How the incremental check finds a parent, mesh or joint world: none (a
    /// rig root), an earlier entry of the check's own walk, or a required
    /// slot of the step's transforms, which the step did not move.
    enum World: Sendable { case root, walk(Int), slot(Int) }
    struct WalkNode: Sendable { let node: Int; let parent: World; let moves: Bool }
    struct PaletteEntry: Sendable { let position: Int; let world: World }
    struct SkinCheck: Sendable {
        let index: Int, meshNode: Int, joints: [Int]
        let mesh: World, meshMoves: Bool
        let entries: [PaletteEntry]
    }

    /// Rig node of each slot.
    let nodes: [Int]
    /// Parent slot of each slot, -1 for a rig root.
    let parent: [Int]
    /// Slots in rig hierarchy order.
    let order: [Int]
    /// Required children of each slot, and the rig's full child count.
    let children: [[Int]], childCount: [Int]
    private let slots: [Int]
    private let rigIdentity: RigDefinition.Identity
    private let rigIDs: [String], rigParents: [Int?]
    /// The incremental check's walk in rig order: the root particle's subtree
    /// (`moves`), then whatever unmoved, unrequired ancestors the palette
    /// entries below need.
    private let walk: [WalkNode]
    private let skins: [SkinCheck], skinCount: Int
    /// False when the walk could not be planned; the check then evaluates the
    /// whole rig. Never false for a rig the component was bound to.
    private let planned: Bool

    init(rig: RigDefinition, particles: [Int], colliders: [Int], owner: Int) {
        var required = Set(particles + colliders + [owner])
        for node in required { var parent = rig.nodes[node].parent; while let index = parent { required.insert(index); parent = rig.nodes[index].parent } }
        let nodes = required.sorted()
        var slots = [Int](repeating: -1, count: rig.nodes.count)
        for (slot, node) in nodes.enumerated() { slots[node] = slot }
        var children = [[Int]](repeating: [], count: rig.nodes.count)
        for (i, node) in rig.nodes.enumerated() { if let parent = node.parent { children[parent].append(i) } }
        self.nodes = nodes; self.slots = slots
        parent = nodes.map { rig.nodes[$0].parent.map { slots[$0] } ?? -1 }
        order = rig.order.compactMap { slots[$0] >= 0 ? slots[$0] : nil }
        self.children = nodes.map { children[$0].compactMap { slots[$0] >= 0 ? slots[$0] : nil } }
        childCount = nodes.map { children[$0].count }
        rigIdentity = rig.identity; rigIDs = rig.nodes.map(\.sourceID); rigParents = rig.nodes.map(\.parent)

        var moves = [Bool](repeating: false, count: rig.nodes.count)
        for i in rig.order { moves[i] = i == particles[0] || (rig.nodes[i].parent.map { moves[$0] } ?? false) }
        var needed = Set<Int>(), relevant: [(index: Int, meshMoves: Bool, positions: [Int])] = []
        for (index, skin) in rig.skins.enumerated() {
            let meshMoves = moves[skin.meshNode]
            let positions = skin.joints.indices.filter { meshMoves || moves[skin.joints[$0]] }
            guard !positions.isEmpty || meshMoves else { continue }
            relevant.append((index, meshMoves, positions))
            for node in [skin.meshNode] + positions.map({ skin.joints[$0] }) where !moves[node] {
                var cursor: Int? = node
                while let index = cursor, slots[index] < 0, needed.insert(index).inserted { cursor = rig.nodes[index].parent }
            }
        }
        var position = [Int](repeating: -1, count: rig.nodes.count), walk: [WalkNode] = [], planned = true
        func world(_ node: Int) -> World? { position[node] >= 0 ? .walk(position[node]) : slots[node] >= 0 ? .slot(slots[node]) : nil }
        for i in rig.order where moves[i] || needed.contains(i) {
            let source: World?
            if let parent = rig.nodes[i].parent { source = world(parent) } else { source = .root }
            guard let source else { planned = false; break }
            position[i] = walk.count; walk.append(WalkNode(node: i, parent: source, moves: moves[i]))
        }
        var skins: [SkinCheck] = []
        for (index, meshMoves, positions) in relevant where planned {
            let skin = rig.skins[index]
            guard let mesh = world(skin.meshNode) else { planned = false; break }
            var entries: [PaletteEntry] = []
            for p in positions {
                guard let joint = world(skin.joints[p]) else { planned = false; break }
                entries.append(PaletteEntry(position: p, world: joint))
            }
            skins.append(SkinCheck(index: index, meshNode: skin.meshNode, joints: skin.joints, mesh: mesh, meshMoves: meshMoves, entries: entries))
        }
        self.walk = walk; self.skins = skins; skinCount = rig.skins.count; self.planned = planned
    }

    func slot(_ node: Int) -> Int { slots[node] }

    /// The hierarchy this component was bound to: same node count, source IDs
    /// and parents. The rig it was bound to (the usual case) matches by identity.
    func matches(_ rig: RigDefinition) -> Bool {
        rig.identity === rigIdentity || rig.nodes.count == rigIDs.count && rig.nodes.indices.allSatisfy({
            rig.nodes[$0].sourceID == rigIDs[$0] && rig.nodes[$0].parent == rigParents[$0]
        })
    }

    /// Throws exactly when `rig.evaluate(value)` would, with its message, for
    /// a `value` that differs from a pose passing `rig.evaluate` only inside
    /// the root particle's subtree, `world` being the step's required world
    /// matrices (unmoved outside that subtree). Nodes and palette entries
    /// outside the subtree compute bit-identically to the valid pose, so they
    /// pass again; the subtree's nodes are checked in rig order (local, then
    /// world) and the moved palette entries skin by skin, as `rig.evaluate`
    /// does, so the first failure is the one it reports.
    func validateChanges(_ value: RigPose, rig: RigDefinition, world: [float4x4]) throws {
        guard planned, rig.skins.count == skinCount, skins.allSatisfy({
            rig.skins[$0.index].meshNode == $0.meshNode && rig.skins[$0.index].joints == $0.joints
        }) else { _ = try rig.evaluate(value); return }
        var walked = [float4x4](repeating: matrix_identity_float4x4, count: walk.count)
        func matrix(_ source: World) -> float4x4 {
            switch source { case .root: matrix_identity_float4x4; case .walk(let i): walked[i]; case .slot(let s): world[s] }
        }
        for (i, entry) in walk.enumerated() {
            let local = value.localMatrices[entry.node]
            if entry.moves { guard RigDefinition.isFiniteAffine(local) else { throw RigError.invalid("Pose node \(entry.node) has an invalid matrix.") } }
            let result: float4x4
            switch entry.parent {
            case .root: result = local
            case .walk(let p): result = walked[p] * local
            case .slot(let s): result = world[s] * local
            }
            if entry.moves { guard RigDefinition.isFiniteAffine(result) else { throw RigError.invalid("Pose hierarchy overflow at node \(entry.node).") } }
            walked[i] = result
        }
        for skin in skins {
            let meshWorld = matrix(skin.mesh)
            if skin.meshMoves {
                guard abs(simd_determinant(meshWorld)) > 1e-12 else { throw RigError.invalid("Skin \(skin.index) has a singular mesh transform.") }
            }
            let meshInverse = simd_inverse(meshWorld), inverseBinds = rig.skins[skin.index].inverseBindMatrices
            for entry in skin.entries {
                guard RigDefinition.isFiniteAffine(meshInverse * matrix(entry.world) * inverseBinds[entry.position]) else {
                    throw RigError.invalid("Skin \(skin.index) produced a nonfinite palette.")
                }
            }
        }
    }
}

/// Unity world rotation is the product of local rotations, not a decomposition
/// of a possibly sheared world matrix produced by nonuniform ancestor scales.
/// Holds the required slots only (`DynamicsTopology`); every other transform
/// keeps its input local matrix, which `pose` carries through verbatim.
private struct DynamicsTransforms {
    var translations: [Float3], rotations: [simd_quatf], scales: [Float3]
    var world: [float4x4], worldRotations: [simd_quatf]
    var changed: [Bool]
    let original: [float4x4]
    let topology: DynamicsTopology
    init(topology: DynamicsTopology, rig: RigDefinition, pose: RigPose) throws {
        guard pose.localMatrices.count == rig.nodes.count else { throw RigError.invalid("Dynamics pose count mismatch.") }
        let count = topology.nodes.count
        translations = []; rotations = []; scales = []
        translations.reserveCapacity(count); rotations.reserveCapacity(count); scales.reserveCapacity(count)
        original = pose.localMatrices; self.topology = topology
        // Unrelated authored matrices (for example a mirrored accessory) are
        // carried through verbatim. Only particle/collider/owner ancestors
        // need local quaternion decomposition for this component.
        for i in topology.nodes {
            let m = original[i], scale = m.scaleFactors
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
        world = .init(repeating: matrix_identity_float4x4, count: count)
        worldRotations = .init(repeating: .identity, count: count)
        changed = .init(repeating: false, count: count)
        for slot in topology.order { updateNode(slot) }
    }
    mutating func updateSubtree(_ root: Int) {
        var pending = [root]
        while let slot = pending.popLast() { updateNode(slot); pending += topology.children[slot] }
    }
    private mutating func updateNode(_ slot: Int) {
        let local = changed[slot] ? Transform.trs(translations[slot], rotations[slot], scales[slot]) : original[topology.nodes[slot]]
        let parent = topology.parent[slot]
        if parent >= 0 {
            world[slot] = world[parent] * local; worldRotations[slot] = (worldRotations[parent] * rotations[slot]).normalized
        } else { world[slot] = local; worldRotations[slot] = rotations[slot] }
    }
    /// `input` with the changed transforms written back. `input` is the pose
    /// these transforms were built from.
    func pose(_ input: RigPose, rig: RigDefinition, validatedInput: Bool) throws -> RigPose {
        var value = input
        for slot in changed.indices where changed[slot] {
            value.localMatrices[topology.nodes[slot]] = Transform.trs(translations[slot], rotations[slot], scales[slot])
        }
        if validatedInput { try topology.validateChanges(value, rig: rig, world: world) } else { _ = try rig.evaluate(value) }
        return value
    }
}
