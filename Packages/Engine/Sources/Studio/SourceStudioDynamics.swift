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
        guard bindings.count <= 256, Set(bindings.map { $0.definition.sourceID }).count == bindings.count else {
            throw RigError.invalid("Studio dynamics requires unique bounded component identities.")
        }
        self.bindings = bindings
        states = try bindings.map { try SourceDynamicBone(rig: rig, pose: initializationPose, definition: $0.definition) }
        initialStates = states; enabled = bindings.map { _ in true }
    }
    /// Seek/scene discontinuities discard transient particles on the next
    /// solved upstream pose; no stale impulse crosses the seek boundary.
    public mutating func resetHistory() { input = nil; output = nil; requiresReset = true }
    public mutating func evaluate(time: Float, rig: RigDefinition, upstream: RigPose, enableFK: Bool, activeFK: [Bool], deltaTime: Float? = nil) throws -> RigPose {
        guard time.isFinite, time >= 0, activeFK.count == 7, deltaTime.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw RigError.invalid("Invalid Studio dynamics time or FK activation.") }
        let current = bindings.map { binding in
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
        for i in candidate.states.indices {
            if discontinuity || (current[i] && !enabled[i]) { try candidate.states[i].resetParticles(rig: rig, pose: result) }
            // OCIChar.ActiveFKGroup disables the corresponding components. A
            // fresh upstream pose already includes reset + Animator/FK/IK, so
            // disabling must not overwrite a hair/skirt FK guide here.
            if current[i] && time > 0 && !discontinuity {
                result = try candidate.states[i].step(deltaTime: deltaTime ?? (time - self.time), rig: rig, pose: result)
            }
        }
        _ = try rig.evaluate(result)
        candidate.requiresReset = false; candidate.time = time; candidate.input = upstream; candidate.output = result; candidate.enabled = current
        self = candidate; return result
    }

    /// Exact source IDs distinguish selected assets. Only an assembly namespace
    /// may differ (slot compaction); the CAB/path identity itself never changes.
    public static func bindHair(_ document: SourceDynamicsDocument, rig: RigDefinition) throws -> (bindings: [Binding], diagnostics: [String]) {
        var bound: [Binding] = [], missing = 0
        func resolve(_ id: String) throws -> String? {
            if rig.nodes.contains(where: { $0.sourceID == id }) { return id }
            guard let slash = id.firstIndex(of: "/") else { return nil }
            let prefix = id[..<slash], suffix = id[id.index(after: slash)...]
            guard prefix.hasPrefix("hair-") else { return nil }
            let matches = rig.nodes.filter { $0.sourceID.hasPrefix("hair-") && $0.sourceID.hasSuffix("/" + suffix) }
            guard matches.count <= 1 else { throw RigError.invalid("Ambiguous source dynamics asset identity.") }
            return matches.first?.sourceID
        }
        for var definition in document.components {
            guard definition.ownerID.hasPrefix("hair-") else { throw RigError.invalid("This dynamics import requires an explicit hair component namespace.") }
            guard let owner = try resolve(definition.ownerID) else { missing += 1; continue }
            definition.ownerID = owner
            for i in definition.particles.indices {
                guard let id = try resolve(definition.particles[i].nodeID) else { throw RigError.invalid("Selected dynamics asset has an incomplete particle hierarchy.") }
                definition.particles[i].nodeID = id
            }
            for i in definition.colliders.indices {
                guard let id = try resolve(definition.colliders[i].nodeID) else { throw RigError.invalid("Selected dynamics asset has a missing body collider.") }
                definition.colliders[i].nodeID = id
            }
            bound.append(.init(definition: definition, group: .hair))
        }
        return (bound, missing > 0 ? ["\(missing) converted DynamicBone components do not match the selected hair source identities; those components were not attached."] : [])
    }
}
