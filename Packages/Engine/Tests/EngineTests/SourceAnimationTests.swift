import Foundation
import Testing
import simd
import CoreMath
import Scene
@testable import Character

private func animationDocument() -> [String: Any] {
    let constant: (Float) -> [String: Any] = { ["kind": "constant", "value": $0] }
    let curves: [[String: Any]] = [
        ["kind": "streamed", "keys": [["time": 0, "coefficients": [1, 0, 0, 0]], ["time": 1, "coefficients": [0, 0, 0, 1]]]],
        ["kind": "dense", "beginTime": 0, "sampleRate": 1, "samples": [0, 2]], constant(3),
        constant(0), constant(sqrt(0.5)), constant(0), constant(sqrt(0.5)), constant(1), constant(1), constant(1),
    ]
    let bindings: [[String: Any]] = zip([1, 2, 3], [0, 3, 7]).map { attribute, offset in
        ["pathHash": 42, "attribute": attribute, "curveOffset": offset, "sourcePath": "joint", "targetSourceID": "source:joint", "targetName": "joint"]
    }
    return ["schemaVersion": 1, "converterVersion": "1.0.0", "kind": "ikkoku-source-animation",
        "coordinateSpace": "unity-left-handed-y-up", "scope": "explicit-state-base-layer-generic-transforms",
        "source": ["bundleSHA256": String(repeating: "a", count: 64), "rigSHA256": String(repeating: "b", count: 64), "controllerID": "source:controller", "controllerName": "synthetic"],
        "parameters": [["name": "MotionSpeed", "type": "float", "defaultValue": 1], ["name": "Speed", "type": "float", "defaultValue": 0]],
        "states": [["id": "idle", "name": "Idle", "sourceFullPath": "Base.Idle", "speed": 0.7, "speedParameter": "MotionSpeed", "cycleOffset": 0, "loop": true,
                    "motions": [["clipID": "clip", "threshold": 0, "cycleOffset": 0]]]],
        "clips": [["id": "clip", "name": "synthetic", "startTime": 0, "stopTime": 1, "sampleRate": 30, "loop": true,
                   "bindings": bindings, "curves": curves, "unboundPathHashes": []]], "diagnostics": []]
}

private func animationLibrary(_ document: [String: Any] = animationDocument()) throws -> SourceAnimationLibrary {
    try SourceAnimationLibrary.decode(JSONSerialization.data(withJSONObject: document))
}

@Test func sourceAnimationSamplesCubicDenseConstantAndLoopBoundaries() throws {
    let clip = try animationLibrary().clip(id: "clip")
    let middle = try clip.sample(time: 0.5)
    #expect(middle[0] == 0.125 && middle[1] == 1 && middle[2] == 3)
    #expect(try clip.sample(time: 1)[0] == 1)
    #expect(try clip.sample(time: 1, looping: true)[0] == 0)
    #expect(try clip.sample(time: 2.5, looping: true)[0] == 0.125)
    #expect(try clip.sample(time: 99)[1] == 2)
    #expect(throws: RigError.self) { try clip.sample(time: .infinity) }
    #expect(throws: RigError.self) { try clip.sample(time: -1) }
}

@Test func sourceAnimationAppliesExactBindingsAndReflectsOnce() throws {
    let library = try animationLibrary()
    let rig = try RigDefinition(nodes: [.init(name: "joint", sourceID: "source:joint", parent: nil,
        translation: Float3(10, 20, 30))], skins: [])
    let pose = try library.applying(clipID: "clip", time: 0.5, to: rig)
    let world = try rig.evaluate(pose).worldMatrices[0]
    #expect(simd_length(world.translation - Float3(0.125, 1, -3)) < 1e-6)
    let x = world * Float4(1, 0, 0, 0)
    #expect(simd_length(Float3(x.x, x.y, x.z) - Float3(0, 0, 1)) < 1e-5)
    let wrong = try RigDefinition(nodes: [.init(name: "joint", sourceID: "different", parent: nil)], skins: [])
    #expect(throws: RigError.self) { try library.applying(clipID: "clip", time: 0, to: wrong) }
}

@Test func sourceAnimationUnboundTracksNeedExplicitPartialOptIn() throws {
    var document = animationDocument(), clips = document["clips"] as! [[String: Any]]
    var bindings = clips[0]["bindings"] as! [[String: Any]]
    for index in bindings.indices {
        bindings[index].removeValue(forKey: "targetSourceID"); bindings[index].removeValue(forKey: "targetName"); bindings[index].removeValue(forKey: "sourcePath")
    }
    clips[0]["bindings"] = bindings; clips[0]["unboundPathHashes"] = [42]; document["clips"] = clips
    let library = try animationLibrary(document), rig = try RigDefinition(nodes: [.init(name: "other", sourceID: "other", parent: nil)], skins: [])
    #expect(throws: RigError.self) { try library.applying(clipID: "clip", time: 0, to: rig) }
    let pose = try library.applying(clipID: "clip", time: 0, to: rig, allowingUnbound: true)
    #expect(pose.localMatrices == rig.restPose.localMatrices)
}

@Test func sourceAnimationProjectsStateSpeedAndOneDimensionalWeights() throws {
    var document = animationDocument(), states = document["states"] as! [[String: Any]]
    states[0]["blendParameter"] = "Speed"
    states[0]["motions"] = [["clipID": "clip", "threshold": 0, "cycleOffset": 0], ["clipID": "clip", "threshold": 1, "cycleOffset": 0.5]]
    document["states"] = states
    let library = try animationLibrary(document)
    #expect(try library.stateSpeed(stateID: "idle") == 0.7)
    #expect(try library.stateSpeed(stateID: "idle", floatParameters: ["MotionSpeed": 2]) == 1.4)
    let motions = try library.motions(stateID: "idle", floatParameters: ["Speed": 0.25])
    #expect(motions.map(\.weight) == [0.75, 0.25])
    #expect(motions.map(\.cycleOffset) == [0, 0.5])
    #expect(try library.motions(stateID: "idle", floatParameters: ["Speed": 99]).count == 1)
    #expect(throws: RigError.self) { try library.stateSpeed(stateID: "idle", floatParameters: ["MotionSpeed": -1]) }
}

@Test func sourceAnimationRejectsInvalidBindingsAndCurveData() throws {
    let original = animationDocument()
    for mutation in 0..<5 {
        var document = original, clips = document["clips"] as! [[String: Any]], curves = clips[0]["curves"] as! [[String: Any]]
        switch mutation {
        case 0: clips[0]["stopTime"] = 0
        case 1:
            var bindings = clips[0]["bindings"] as! [[String: Any]]; bindings[1]["curveOffset"] = 2; clips[0]["bindings"] = bindings
        case 2: curves[1]["samples"] = []
        case 3: curves[0]["keys"] = [["time": 0, "coefficients": [0, 0, 0, 0]], ["time": 0, "coefficients": [0, 0, 0, 1]]]
        default: clips[0]["unboundPathHashes"] = [42]
        }
        clips[0]["curves"] = curves; document["clips"] = clips
        #expect(throws: RigError.self) { try animationLibrary(document) }
    }
}

@Test func sourceAnimationBlendsActualPosesAtSynchronizedNormalizedTime() throws {
    var document = animationDocument(), states = document["states"] as! [[String: Any]]
    states[0]["blendParameter"] = "Speed"
    states[0]["motions"] = [["clipID": "clip", "threshold": 0, "cycleOffset": 0], ["clipID": "clip", "threshold": 1, "cycleOffset": 0.5]]
    document["states"] = states
    let library = try animationLibrary(document), rig = try RigDefinition(nodes: [.init(name: "joint", sourceID: "source:joint", parent: nil)], skins: [])
    let pose = try library.applying(stateID: "idle", normalizedTime: 0.25, floatParameters: ["Speed": 0.25], to: rig)
    let a = try library.applying(clipID: "clip", time: 0.25, to: rig), b = try library.applying(clipID: "clip", time: 0.75, to: rig)
    let expected = a.localMatrices[0].translation * 0.75 + b.localMatrices[0].translation * 0.25
    #expect(simd_distance(pose.localMatrices[0].translation, expected) < 0.000001)
    #expect(try library.stateDuration(stateID: "idle", floatParameters: ["Speed": 0.25]) == 1)
    #expect(try library.applying(stateID: "idle", normalizedTime: 10.25, floatParameters: ["Speed": 0.25], to: rig).localMatrices == pose.localMatrices)
}

@Test func sourceAnimationInstalledCurvesMatchIndependentSampler() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let libraryPath = environment["IKKOKU_ANIMATION_LIBRARY"], let referencePath = environment["IKKOKU_ANIMATION_REFERENCE"] else { return }
    struct Reference: Decodable {
        struct Sample: Decodable { let clipID: String, time: Float, values: [Float] }
        let samples: [Sample]
    }
    let library = try SourceAnimationLibrary.load(url: URL(fileURLWithPath: libraryPath))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: URL(fileURLWithPath: referencePath)))
    #expect(reference.samples.count == 18)
    for sample in reference.samples {
        let actual = try library.clip(id: sample.clipID).sample(time: sample.time)
        #expect(actual.count == sample.values.count)
        for (a, b) in zip(actual, sample.values) {
            #expect(abs(a - b) < max(0.00002, abs(b) * 0.00002))
        }
    }
    if let rigPath = environment["IKKOKU_SOURCE_AVATAR"] {
        let rig = try SourceRig.loadModel(url: URL(fileURLWithPath: rigPath)).rig
        let idle = try #require(library.clips.first { $0.name == "f_stand_00_00" })
        let a = try library.applying(clipID: idle.id, time: 0, to: rig)
        let b = try library.applying(clipID: idle.id, time: 1, to: rig)
        _ = try rig.evaluate(a); _ = try rig.evaluate(b)
        #expect(a.localMatrices != b.localMatrices)
    }
}
