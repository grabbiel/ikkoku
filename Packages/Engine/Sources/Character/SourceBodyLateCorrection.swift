import CoreMath
import Scene

/// ChaControl.LateUpdateForce runs these after the body/hand shape setters.
/// Manager.Character defaults to hand correction on and arm correction off.
/// Bind once per assembly; a posed frame only visits the four destinations.
public struct SourceBodyLateCorrection: Sendable {
    public struct Options: Sendable, Equatable {
        /// Raw shape-only inspection predates Manager.Start; opt in at the application boundary.
        public static let disabled = Self(hiPoly: false)
        public var hiPoly: Bool
        public var enableCorrectArmSize: Bool
        public var enableCorrectHandSize: Bool
        public init(hiPoly: Bool = true, enableCorrectArmSize: Bool = false, enableCorrectHandSize: Bool = true) {
            self.hiPoly = hiPoly
            self.enableCorrectArmSize = enableCorrectArmSize
            self.enableCorrectHandSize = enableCorrectHandSize
        }
    }
    private let destinations: [(index: Int, scale: Float3)]
    private let nodeCount: Int
    private init(destinations: [(index: Int, scale: Float3)], nodeCount: Int) {
        self.destinations = destinations; self.nodeCount = nodeCount
    }
    public init(rig: RigDefinition, sex: SourceBodyShapePose.Sex, options: Options) throws {
        nodeCount = rig.nodes.count
        guard options.hiPoly && sex == .female else { destinations = []; return }
        let arm = Float3(options.enableCorrectArmSize ? 0.92 : 1, 1, 1)
        let hand = Float3(1, options.enableCorrectHandSize ? 0.9 : 1, options.enableCorrectHandSize ? 0.9 : 1)
        var bound: [(Int, Float3)] = []
        for (name, scale) in [("cf_j_forearm01_L", arm), ("cf_j_forearm01_R", arm),
                              ("cf_j_hand_L", hand), ("cf_j_hand_R", hand)] {
            let indices = rig.nodes.indices.filter { rig.nodes[$0].name == name }
            guard indices.count <= 1 else { throw RigError.invalid("Ambiguous late body correction destination '\(name)'.") }
            if let index = indices.first { bound.append((index, scale)) }
        }
        destinations = bound
    }
    /// Studio's supported static ABMX edits are already part of this baseline.
    /// Cache their final scales so animation cannot overwrite the source late
    /// setters, without multiplying modifiers a second time each frame.
    public func capturingScales(from baseline: RigPose) throws -> Self {
        guard baseline.localMatrices.count == nodeCount else { throw RigError.invalid("Late correction baseline does not match its rig.") }
        return try Self(destinations: destinations.map {
            ($0.index, try SourceShapePoseBaseline.components(baseline.localMatrices[$0.index]).scale)
        }, nodeCount: nodeCount)
    }
    public func apply(to pose: inout RigPose) throws {
        guard pose.localMatrices.count == nodeCount else { throw RigError.invalid("Late body correction pose does not match its rig.") }
        guard !destinations.isEmpty else { return }
        for destination in destinations {
            let components = try SourceShapePoseBaseline.components(pose.localMatrices[destination.index])
            pose.localMatrices[destination.index] = Transform.trs(components.position, components.rotation, destination.scale)
        }
    }
}
