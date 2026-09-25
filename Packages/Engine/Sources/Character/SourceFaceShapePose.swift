import Foundation
import simd
import CoreMath
import Scene

/// The female head-00 destination stage, after SourceShapeDomain has sampled the
/// original slider channels. This stage changes bones, not expression blend shapes.
public enum SourceFaceShapePose {
    public static var destinationNames: [String] { operations.map(\.name) }

    public static func make(rig: RigDefinition, domain: SourceShapeDomain,
                            values: [Float]? = nil, basePose: RigPose? = nil,
                            boneType: Int = 0, headCorrection: Float = 1) throws -> RigPose {
        guard domain.id == "face", Set(domain.destinationNames) == Set(destinationNames) else {
            throw RigError.invalid("Face contract does not match the supported female head destination set.")
        }
        return try make(rig: rig, state: domain.makeState(values: values), basePose: basePose,
                        boneType: boneType, headCorrection: headCorrection)
    }

    /// Applies the source's absolute assignments to the incoming local TRS (or
    /// authored rest pose when omitted). Axes and components not assigned by the
    /// source retain upstream animation. Reapplying slider values is idempotent;
    /// other nodes retain basePose, including body-derived parent scaling.
    ///
    /// The caller supplies the body-derived headCorrection for nonzero boneType.
    /// Parent scale must have a positive, orthogonal basis: Unity's signed/sheared
    /// lossyScale behavior has not been verified and is rejected rather than approximated.
    public static func make(rig: RigDefinition, state: [String: SourceShapeTransform],
                            basePose: RigPose? = nil, boneType: Int = 0,
                            headCorrection: Float = 1) throws -> RigPose {
        guard headCorrection.isFinite, headCorrection > 0 else {
            throw RigError.invalid("Head correction must be finite and positive.")
        }
        var pose = basePose ?? rig.restPose
        guard pose.localMatrices.count == rig.nodes.count else {
            throw RigError.invalid("Face base pose does not match rig node count.")
        }
        let indices = try operations.map { try rig.uniqueNode(named: $0.name) }
        for (operation, index) in zip(operations, indices) {
            let node = rig.nodes[index]
            guard node.authoredMatrix == nil else {
                throw RigError.invalid("Face target '\(node.name)' requires authored TRS.")
            }
            guard let value = state[operation.name],
                  (0..<3).allSatisfy({ value.position[$0].isFinite && value.rotationDegrees[$0].isFinite && value.scale[$0].isFinite }) else {
                throw SourceShapeError.incompleteState(operation.name)
            }
            let baseline: (position: Float3, rotation: simd_quatf, scale: Float3) = try basePose != nil
                ? SourceShapePoseBaseline.components(pose.localMatrices[index])
                : (node.translation, node.rotation, node.scale)
            var position = baseline.position
            let nativePosition = UnityCoordinates.position(value.position)
            for axis in 0..<3 where operation.position & (1 << axis) != 0 { position[axis] = nativePosition[axis] }
            let rotation: simd_quatf
            switch operation.rotation {
            case .unchanged: rotation = baseline.rotation
            case .x: rotation = UnityCoordinates.eulerDegrees(Float3(value.rotationDegrees.x, 0, 0))
            case .z: rotation = UnityCoordinates.eulerDegrees(Float3(0, 0, value.rotationDegrees.z))
            case .yz: rotation = UnityCoordinates.eulerDegrees(Float3(0, value.rotationDegrees.y, value.rotationDegrees.z))
            }
            let scale: Float3
            switch operation.scale {
            case .unchanged: scale = baseline.scale
            case .xyz: scale = value.scale
            case .x: scale = Float3(value.scale.x, 1, 1)
            case .z: scale = Float3(1, 1, value.scale.z)
            case .xy: scale = Float3(value.scale.x, value.scale.y, 1)
            case .head:
                guard let parent = node.parent else { throw RigError.invalid("Face base requires its source parent.") }
                // Evaluate parents using the incoming body pose. The source updates
                // FaceBase first, before any descendants are changed.
                let parentWorld = try rig.evaluate(pose).worldMatrices[parent]
                let parentScale = try positiveOrthogonalScale(parentWorld)
                let correctedY = parentScale.y * (boneType == 0 ? 1 : headCorrection)
                scale = Float3(correctedY / parentScale.x + (value.scale.x - 1),
                               correctedY / parentScale.y, correctedY / parentScale.z)
            }
            guard (0..<3).allSatisfy({ scale[$0].isFinite && scale[$0] > 0 }) else {
                throw RigError.invalid("Face target '\(node.name)' has a nonpositive or nonfinite scale.")
            }
            pose.localMatrices[index] = Transform.trs(position, rotation, scale)
        }
        // Validate ancestor input and finite world/palette output before exposing a pose.
        _ = try rig.evaluate(pose)
        return pose
    }

    private static func positiveOrthogonalScale(_ matrix: float4x4) throws -> Float3 {
        let x = Float3(matrix[0].x, matrix[0].y, matrix[0].z)
        let y = Float3(matrix[1].x, matrix[1].y, matrix[1].z)
        let z = Float3(matrix[2].x, matrix[2].y, matrix[2].z)
        let scale = Float3(simd_length(x), simd_length(y), simd_length(z))
        guard (0..<3).allSatisfy({ scale[$0].isFinite && scale[$0] > 1e-8 }),
              simd_determinant(float3x3(columns: (x, y, z))) > 0,
              abs(simd_dot(x / scale.x, y / scale.y)) < 1e-4,
              abs(simd_dot(x / scale.x, z / scale.z)) < 1e-4,
              abs(simd_dot(y / scale.y, z / scale.z)) < 1e-4 else {
            throw RigError.invalid("Face parent requires positive orthogonal scale; reflected, singular, or sheared parents are unsupported.")
        }
        return scale
    }

    private enum Rotation: Sendable { case unchanged, x, z, yz }
    private enum Scale: Sendable { case unchanged, xyz, x, z, xy, head }
    private struct Operation: Sendable {
        let name: String
        let position: Int
        let rotation: Rotation
        let scale: Scale
        init(_ name: String, _ position: Int = 0, _ rotation: Rotation = .unchanged, _ scale: Scale = .unchanged) {
            self.name = name; self.position = position; self.rotation = rotation; self.scale = scale
        }
    }

    // Position bitmask: X=1, Y=2, Z=4. Explicit unit scale/rotation axes are
    // intentional source assignments; they must not retain a target's rest axes.
    private static let operations: [Operation] = [
        .init("cf_J_FaceBase", 0, .unchanged, .head),
        .init("cf_J_FaceUp_tz", 4),
        .init("cf_J_NoseBridge_ty", 6),
        .init("cf_J_FaceUp_ty", 2, .unchanged, .xyz),
        .init("cf_J_FaceLow_tz", 4),
        .init("cf_J_FaceLow_sx", 0, .unchanged, .x),
        .init("cf_J_CheekUp2_L", 5, .unchanged, .x),
        .init("cf_J_CheekUp2_R", 5, .unchanged, .x),
        .init("cf_J_ChinLow", 2, .unchanged, .xyz),
        .init("cf_J_CheekLow_s_L", 4, .unchanged, .z),
        .init("cf_J_CheekLow_s_R", 4, .unchanged, .z),
        .init("cf_J_Chin_Base", 6, .unchanged, .x),
        .init("cf_J_ChinTip_Base", 6, .unchanged, .x),
        .init("cf_J_Nose_tip", 4),
        .init("cf_J_NoseBase_rx", 6),
        .init("cf_J_NoseBridge_rx", 4),
        .init("cf_J_CheekUpBase", 2),
        .init("cf_J_CheekUp_s_L", 7),
        .init("cf_J_CheekUp_s_R", 7),
        .init("cf_J_Eye_tx_L", 2, .z),
        .init("cf_J_Eye_tx_R", 2, .z),
        .init("cf_J_megane_rx_ear", 2, .x),
        .init("cf_J_Eye_rz_L", 1, .unchanged, .xy),
        .init("cf_J_Eye_rz_R", 1, .unchanged, .xy),
        .init("cf_J_Eye_tz", 4),
        .init("cf_J_Eye01_s_L", 1),
        .init("cf_J_Eye01_s_R", 1),
        .init("cf_J_Eye05_s_L", 2),
        .init("cf_J_Eye05_s_R", 2),
        .init("cf_J_Eye02_s_L", 2),
        .init("cf_J_Eye02_s_R", 2),
        .init("cf_J_Eye03_s_L", 2),
        .init("cf_J_Eye03_s_R", 2),
        .init("cf_J_Eye04_s_L", 2),
        .init("cf_J_Eye04_s_R", 2),
        .init("cf_J_Eye08_s_L", 2),
        .init("cf_J_Eye08_s_R", 2),
        .init("cf_J_Eye07_s_L", 2),
        .init("cf_J_Eye07_s_R", 2),
        .init("cf_J_Eye06_s_L", 2),
        .init("cf_J_Eye06_s_R", 2),
        .init("cf_J_Mayu_L", 7, .z),
        .init("cf_J_Mayu_R", 7, .z),
        .init("cf_J_MayuMid_s_L", 0, .z),
        .init("cf_J_MayuMid_s_R", 0, .z),
        .init("cf_J_MayuTip_s_L", 0, .z),
        .init("cf_J_MayuTip_s_R", 0, .z),
        .init("cf_J_EarBase_ry_L", 0, .yz, .xyz),
        .init("cf_J_EarBase_ry_R", 0, .yz, .xyz),
        .init("cf_J_EarUp_L", 3, .unchanged, .xyz),
        .init("cf_J_EarUp_R", 3, .unchanged, .xyz),
        .init("cf_J_EarLow_L", 2),
        .init("cf_J_EarLow_R", 2),
        .init("cf_J_MouthBase_ty", 6),
        .init("cf_J_Mouth_L", 3),
        .init("cf_J_Mouth_R", 3),
        .init("cf_J_MouthBase_rx", 4),
        .init("cf_J_Mouthup", 4),
        .init("cf_J_MouthLow", 4),
    ]
}
