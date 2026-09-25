import Foundation
import Character
import Scene
import CoreMath

func inspectSourceAnimation(url: URL, rigURL: URL? = nil, clipID: String? = nil,
                            time: Float = 0, allowingUnbound: Bool = false) throws -> [String: Any] {
    let library = try SourceAnimationLibrary.load(url: url)
    var result: [String: Any] = ["schemaVersion": 1, "kind": "ikkoku-source-animation-report",
        "controller": library.source.controllerName, "controllerID": library.source.controllerID,
        "bundleSHA256": library.source.bundleSHA256, "diagnostics": library.diagnostics,
        "clips": library.clips.map { clip -> [String: Any] in
            ["id": clip.id, "name": clip.name, "duration": clip.duration, "loop": clip.loop,
             "bindings": clip.bindings.count, "curves": clip.curves.count, "unboundPaths": clip.unboundPathHashes.count]
        }, "states": library.states.map { state -> [String: Any] in
            ["id": state.id, "name": state.name, "speed": state.speed, "motionCount": state.motions.count]
        }]
    if let rigURL {
        guard let chosen = clipID ?? library.states.first(where: { $0.name == "Idle" })?.motions.first?.clipID else {
            throw RigError.invalid("Choose a source clip for animation sampling.")
        }
        let source = try SourceRig.loadModel(url: rigURL), clip = try library.clip(id: chosen)
        let pose = try library.applying(clipID: chosen, time: time, to: source.rig, allowingUnbound: allowingUnbound)
        let evaluated = try source.rig.evaluate(pose)
        let values = try clip.sample(time: time)
        let changed = source.rig.nodes.indices.filter { pose.localMatrices[$0] != source.rig.nodes[$0].localMatrix }
        let bounds = try source.bounds(evaluation: evaluated)
        result["sample"] = ["clipID": chosen, "time": time, "values": values, "changedNodes": changed.count,
            "nodeCount": source.rig.nodes.count, "skinCount": evaluated.palettes.count,
            "boundsMin": [bounds.min.x, bounds.min.y, bounds.min.z], "boundsMax": [bounds.max.x, bounds.max.y, bounds.max.z],
            "allowingUnbound": allowingUnbound]
    }
    return result
}
