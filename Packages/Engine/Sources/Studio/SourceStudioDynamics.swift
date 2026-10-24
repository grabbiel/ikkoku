import Foundation
import simd
import CoreMath
import Scene
import Character

/// Stateful late-frame DynamicBone execution. Input is a fresh animation/FK/IK
/// pose, so source Update's transform reset never overwrites the solved pose.
/// Repeated consumers at the same clock return one result; backwards seeks and
/// edits while paused reset particles rather than integrating time twice.
public struct SourceStudioDynamics {
    public struct Binding: Sendable {
        public enum Group: Sendable { case hair, skirt, always }
        public let definition: SourceDynamicsDocument.Component
        public let group: Group
        public init(definition: SourceDynamicsDocument.Component, group: Group) { self.definition = definition; self.group = group }
    }
    public private(set) var states: [SourceDynamicBone]
    public let bindings: [Binding]
    public private(set) var time: Float = 0
    private let initialStates: [SourceDynamicBone]
    private var enabled: [Bool]
    private var input: RigPose?
    private var output: RigPose?
    private var requiresReset = false
    public init(rig: RigDefinition, initializationPose: RigPose, bindings: [Binding]) throws {
        guard bindings.count <= 256, Set(bindings.map { $0.definition.sourceID }).count == bindings.count,
              bindings.allSatisfy({ $0.definition.clothesKind.map { (0...1).contains($0) } ?? true }) else {
            throw RigError.invalid("Studio dynamics requires unique bounded component identities.")
        }
        self.bindings = bindings
        states = try bindings.map { try SourceDynamicBone(rig: rig, pose: initializationPose, definition: $0.definition) }
        initialStates = states; enabled = bindings.map { _ in true }
    }
    /// Seek/scene discontinuities discard transient particles on the next
    /// solved upstream pose; no stale impulse crosses the seek boundary.
    public mutating func resetHistory() { input = nil; output = nil; requiresReset = true }
    public mutating func evaluate(time: Float, rig: RigDefinition, upstream: RigPose, enableFK: Bool, activeFK: [Bool], deltaTime: Float? = nil, activeClothes: UInt16 = 0x1ff) throws -> RigPose {
        guard time.isFinite, time >= 0, activeFK.count == 7, deltaTime.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw RigError.invalid("Invalid Studio dynamics time or FK activation.") }
        let current = bindings.map { binding in
            if let kind = binding.definition.clothesKind, activeClothes & (1 << kind) == 0 { return false }
            switch binding.group {
            case .hair: return !(enableFK && activeFK[0])
            case .skirt: return !(enableFK && activeFK[6])
            case .always: return true
            }
        }
        if let input, let output, time == self.time, input.localMatrices == upstream.localMatrices, current == enabled { return output }
        var candidate = self
        let discontinuity = requiresReset || time < self.time || (time == self.time && input != nil)
        if discontinuity { candidate.states = initialStates }
        var result = upstream
        // True once `result` is known to pass `rig.evaluate`: after the first
        // component that steps, which evaluates the whole rig. Each later step
        // checks only what it changed (`SourceDynamicBone.step(validatedInput:)`),
        // and the final check is needed only when no component stepped.
        var validated = false
        for i in candidate.states.indices {
            if discontinuity || (current[i] && !enabled[i]) { try candidate.states[i].resetParticles(rig: rig, pose: result) }
            // OCIChar.ActiveFKGroup disables the corresponding components. A
            // fresh upstream pose already includes reset + Animator/FK/IK, so
            // disabling must not overwrite a hair/skirt FK guide here.
            if current[i] && time > 0 && !discontinuity {
                result = try candidate.states[i].step(deltaTime: deltaTime ?? (time - self.time), rig: rig, pose: result, validatedInput: validated)
                // A zero-weight component returns its input unchanged and unchecked.
                if candidate.states[i].weight > 0 { validated = true }
            }
        }
        if !validated { _ = try rig.evaluate(result) }
        candidate.requiresReset = false; candidate.time = time; candidate.input = upstream; candidate.output = result; candidate.enabled = current
        self = candidate; return result
    }

    /// Schema-1 compatibility entry point. New consumers use `bind` to include
    /// supported garment-root components alongside hair.
    public static func bindHair(_ document: SourceDynamicsDocument, rig: RigDefinition) throws -> (bindings: [Binding], diagnostics: [String]) {
        guard document.components.allSatisfy({ $0.ownerID.hasPrefix("hair-") }) else {
            throw RigError.invalid("This dynamics import requires an explicit hair component namespace.")
        }
        return try bind(document, rig: rig)
    }

    /// Exact CAB/path identities distinguish assets. Assembly slot compaction may
    /// change hair/clothes namespaces, but never the source transform identity.
    /// Resolve once during assembly; no names or catalog IDs enter the frame path.
    public static func bind(_ document: SourceDynamicsDocument, rig: RigDefinition, clothingSlots: [Int] = []) throws -> (bindings: [Binding], diagnostics: [String]) {
        try document.validateGroups()
        var bound: [Binding] = [], missing = 0, diagnostics: [String] = []
        let exact = Set(rig.nodes.map(\.sourceID))
        var aliases: [String: [String]] = [:]
        for node in rig.nodes {
            guard let slash = node.sourceID.firstIndex(of: "/") else { continue }
            let prefix = node.sourceID[..<slash]
            let family = prefix.hasPrefix("hair-") ? "hair" : prefix.hasPrefix("clothes-") ? "clothes" : nil
            if let family { aliases[family + "/" + node.sourceID[node.sourceID.index(after: slash)...], default: []].append(node.sourceID) }
        }
        func resolve(_ id: String) throws -> String? {
            guard let slash = id.firstIndex(of: "/") else { return exact.contains(id) ? id : nil }
            let prefix = id[..<slash], suffix = id[id.index(after: slash)...]
            let family = prefix.hasPrefix("hair-") ? "hair" : prefix.hasPrefix("clothes-") ? "clothes" : nil
            guard let family else { return exact.contains(id) ? id : nil }
            let matches = aliases[family + "/" + suffix] ?? []
            guard matches.count <= 1 else { throw RigError.invalid("Ambiguous source dynamics asset identity.") }
            return matches.first
        }
        for var definition in document.components {
            guard let owner = try resolve(definition.ownerID) else { missing += 1; continue }
            if let kind = definition.clothesKind {
                let prefix = owner.prefix { $0 != "/" }
                guard let index = Int(prefix.dropFirst("clothes-".count)), clothingSlots.indices.contains(index),
                      clothingSlots[index] == kind else { throw RigError.invalid("Selected dynamics garment has a different clothing slot.") }
            }
            definition.ownerID = owner
            for i in definition.particles.indices {
                guard let id = try resolve(definition.particles[i].nodeID) else { throw RigError.invalid("Selected dynamics asset has an incomplete particle hierarchy.") }
                definition.particles[i].nodeID = id
            }
            for i in definition.colliders.indices {
                guard let id = try resolve(definition.colliders[i].nodeID) else { throw RigError.invalid("Selected dynamics asset has a missing body collider.") }
                definition.colliders[i].nodeID = id
            }
            let group: Binding.Group = definition.group == .skirt ? .skirt : definition.group == .clothes ? .always : .hair
            bound.append(.init(definition: definition, group: group))
        }
        for rejection in document.rejected ?? [] {
            if let owner = rejection.ownerID, try resolve(owner) != nil {
                diagnostics.append("Selected DynamicBone \(rejection.sourceID) was rejected: \(rejection.reason) (\(rejection.detail)).")
            }
        }
        if missing > 0 { diagnostics.append("\(missing) converted DynamicBone components do not match the assembled hair/clothes source identities; those components were not attached.") }
        return (bound, diagnostics)
    }
}
