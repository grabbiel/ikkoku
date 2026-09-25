import Foundation
import simd
import CoreMath
import Scene

/// First verified destination operation from ShapeBodyInfoFemale.Update.
/// Other sampled body channels need their original composition formulas before use.
public enum SourceRigCustomization {
    public static func heightPose(source: SourceRig, contract: SourceShapeContract, rate: Float) throws -> RigPose {
        guard let body = contract.domain("body"), let heightSlot = body.slots.first, heightSlot.index == 0,
              let heightBinding = heightSlot.bindings.first(where: { $0.sourceName == "cf_a_height" }),
              heightBinding.scaleMask == [true, true, true],
              let operation = body.directTargets.first(where: { $0.sourceName == "cf_a_height" && $0.destinationName == "cf_n_height" }),
              operation.scaleMask == [true, true, true], operation.positionMask == [false, false, false],
              operation.rotationMask == [false, false, false] else {
            throw RigError.invalid("Shape contract does not contain the verified female height operation.")
        }
        var values = body.defaultValues
        values[0] = rate
        let state = try body.makeState(values: values)
        guard let height = state[operation.sourceName] else { throw RigError.invalid("Height source channel is missing.") }
        let nodeIndex = try source.rig.uniqueNode(named: operation.destinationName)
        let node = source.rig.nodes[nodeIndex]
        guard node.authoredMatrix == nil else { throw RigError.invalid("Height node requires an authored TRS transform.") }
        var pose = source.rig.restPose
        pose.localMatrices[nodeIndex] = Transform.trs(node.translation, node.rotation, height.scale)
        return pose
    }
}
