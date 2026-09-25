import Foundation
import simd
import CoreMath
import Scene
import Studio

private struct StudioPoseRequest: Decodable {
    struct Rotation: Decodable { let boneID: Int, degrees: [Float] }
    struct Command: Decodable {
        let operation: String
        let active: Bool?
        let force: Bool?
        let mask: Int?
        let boneID: Int?
        let degrees: [Float]?
    }
    let schemaVersion: Int, characterRoot: Int, bodyRoot: Int?, hairRoot: Int?, sex: Int
    let bones: [SourceStudioPose.Bone], rotations: [Rotation], commands: [Command]
}

func inspectStudioPose(rigURL: URL, requestURL: URL) throws -> [String: Any] {
    let handle = try FileHandle(forReadingFrom: requestURL)
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
    guard bytes.count <= 16 * 1024 * 1024 else { throw RigError.invalid("Studio FK request exceeds 16 MiB.") }
    let input = try JSONDecoder().decode(StudioPoseRequest.self, from: bytes)
    guard input.schemaVersion == 1, input.rotations.count <= 100_000, input.commands.count <= 10_000,
          input.bones.count <= 100_000 else { throw RigError.invalid("Unsupported or oversized Studio FK request.") }
    func vector(_ value: [Float]) throws -> Float3 {
        guard value.count == 3, value.allSatisfy(\.isFinite) else { throw RigError.invalid("Studio FK rotation requires three finite degrees.") }
        return Float3(value[0], value[1], value[2])
    }
    var rotations: [Int: Float3] = [:]
    for rotation in input.rotations {
        guard rotations[rotation.boneID] == nil else { throw RigError.invalid("Duplicate Studio FK saved bone ID.") }
        rotations[rotation.boneID] = try vector(rotation.degrees)
    }
    let source = try SourceRig.loadModel(url: rigURL)
    var controller = try SourceStudioPose(rig: source.rig, bones: input.bones, rotations: rotations,
        characterRoot: input.characterRoot, bodyRoot: input.bodyRoot, hairRoot: input.hairRoot, sex: input.sex)
    var pose = source.rig.restPose
    var steps: [[String: Any]] = []
    for command in input.commands {
        var candidate = controller
        let transition: SourceStudioPose.Transition?
        switch command.operation {
        case "fk", "ik", "fkGroup", "ikGroup":
            guard let active = command.active else { throw RigError.invalid("Studio activation requires active.") }
            if command.operation == "fk" || command.operation == "ik" {
                transition = candidate.activateMode(command.operation == "fk" ? .fk : .ik,
                    active: active, force: command.force ?? false)
            } else {
                guard let mask = command.mask, mask >= 0, mask <= 2047 else { throw RigError.invalid("Studio group mask is invalid.") }
                if command.operation == "fkGroup" {
                    transition = candidate.activateFK(mask: .init(rawValue: mask), active: active, force: command.force ?? false)
                } else {
                    transition = candidate.activateIK(mask: .init(rawValue: mask), active: active, force: command.force ?? false)
                }
            }
        case "rotation":
            guard let id = command.boneID, let degrees = command.degrees else { throw RigError.invalid("Studio rotation requires boneID and degrees.") }
            try candidate.setRotation(boneID: id, degrees: vector(degrees))
            transition = nil
        default: throw RigError.invalid("Unknown Studio FK operation '\(command.operation)'.")
        }
        let changed = try transition.map { try candidate.applying($0, rig: source.rig, pose: pose) } ?? pose
        let evaluated = try candidate.applyingLateUpdate(rig: source.rig, pose: changed)
        controller = candidate; pose = evaluated
        steps.append(["operation": command.operation, "enableFK": controller.enableFK, "enableIK": controller.enableIK,
            "activeFK": controller.activeFK, "activeIK": controller.activeIK,
            "identityResetNodes": transition?.identityResetNodes ?? [],
            "deferredEffects": transition?.effects.map { String(describing: $0) } ?? []])
    }
    func matrix(_ m: float4x4) -> [Float] { (0..<4).flatMap { column in (0..<4).map { m[column][$0] } } }
    let evaluation = try source.rig.evaluate(pose)
    let bounds = try source.bounds(evaluation: evaluation)
    guard !bounds.isEmpty, bounds.radius.isFinite else { throw RigError.invalid("Studio FK produced no finite geometry bounds.") }
    let boundIDs = Set(controller.targets.map { $0.bone.id })
    return ["request": requestURL.path, "steps": steps,
        "coordinateSpace": "native-right-handed-y-up", "matrixLayout": "column-major",
        "inputAngleConvention": "Unity Euler degrees, Z then X then Y, reflected across Z",
        "unboundCatalogIDs": input.bones.filter { !boundIDs.contains($0.id) }.map(\.id),
        "unboundSavedRotationIDs": rotations.keys.filter { !boundIDs.contains($0) }.sorted(),
        "targets": controller.targets.map { ["boneID": $0.bone.id, "name": $0.bone.name, "node": $0.node,
            "hasGuide": $0.hasGuide, "enabled": $0.enabled] as [String: Any] },
        "localMatrices": pose.localMatrices.map(matrix), "worldMatrices": evaluation.worldMatrices.map(matrix),
        "bounds": ["min": [bounds.min.x, bounds.min.y, bounds.min.z], "max": [bounds.max.x, bounds.max.y, bounds.max.z]],
        "scope": "Each command evaluates static FK on the selected source rig. No upstream animation step or immediate guide callbacks run. IK solvers, dynamics, look controllers and source character scene loading are not executed."]
}
