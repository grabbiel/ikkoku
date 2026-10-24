import Foundation
import Testing
import simd
import CoreMath
import Scene
import Character
import Studio
import Metal
import Renderer

private func studioSpring() throws -> (RigDefinition,SourceDynamicsDocument.Component) {
    let rig = try RigDefinition(nodes:[
        .init(name:"body",sourceID:"body",parent:nil),
        .init(name:"hair",sourceID:"hair-0/root",parent:0),
        .init(name:"tip",sourceID:"hair-0/tip",parent:1,translation:Float3(0,-1,0)),
        .init(name:"collider",sourceID:"body/collider",parent:0,translation:Float3(0.2,-0.5,0))],skins:[])
    return (rig,.init(sourceID:"source/component",ownerID:"hair-0/root",force:Float3(0.02,0,0),particles:[
        .init(nodeID:"hair-0/root",parent:nil),.init(nodeID:"hair-0/tip",parent:0,damping:0.1,elasticity:0.2,stiffness:0.1)],
        colliders:[.init(nodeID:"body/collider",radius:0.2,height:0.7,direction:1)]))
}

@Test func sourceStudioDynamicsRunsOnceAfterUpstreamAndDisablesForHairFK() throws {
    let (rig,definition) = try studioSpring()
    var session = try SourceStudioDynamics(rig:rig,initializationPose:rig.restPose,bindings:[.init(definition:definition,group:.hair)])
    var direct = try SourceDynamicBone(rig:rig,definition:definition)
    var input = rig.restPose; input.localMatrices[0] = Transform.trs(Float3(0.1,0,0),simd_quatf(angle:0.2,axis:Float3(0,0,1)),Float3(1.2,1,0.8))
    let expected = try direct.step(deltaTime:1/30,rig:rig,pose:input)
    let actual = try session.evaluate(time:1/30,rig:rig,upstream:input,enableFK:false,activeFK:Array(repeating:false,count:7),deltaTime:1/30)
    #expect(actual.localMatrices == expected.localMatrices)
    let particles = session.states[0].positions
    let repeated = try session.evaluate(time:1/30,rig:rig,upstream:input,enableFK:false,activeFK:Array(repeating:false,count:7),deltaTime:1/30)
    #expect(repeated.localMatrices == actual.localMatrices && particles == session.states[0].positions)
    var flags = Array(repeating:false,count:7); flags[0] = true
    let disabled = try session.evaluate(time:2/30,rig:rig,upstream:input,enableFK:true,activeFK:flags,deltaTime:1/30)
    #expect(disabled.localMatrices == input.localMatrices)
    let resumed = try session.evaluate(time:3/30,rig:rig,upstream:input,enableFK:false,activeFK:flags,deltaTime:1/30)
    #expect(resumed.localMatrices != input.localMatrices)
    let seek = try session.evaluate(time:0,rig:rig,upstream:rig.restPose,enableFK:false,activeFK:flags)
    #expect(seek.localMatrices == rig.restPose.localMatrices && session.time == 0)
}

@Test func sourceStudioDynamicsFailureCommitsNoPartialComponentState() throws {
    let (rig,definition) = try studioSpring()
    var session = try SourceStudioDynamics(rig:rig,initializationPose:rig.restPose,bindings:[.init(definition:definition,group:.hair)])
    let old = session.states[0].positions
    var invalid = rig.restPose; invalid.localMatrices[2][0].x = .nan
    #expect(throws:(any Error).self) { try session.evaluate(time:1/30,rig:rig,upstream:invalid,enableFK:false,activeFK:Array(repeating:false,count:7)) }
    #expect(session.time == 0 && session.states[0].positions == old)
}

@Test func sourceStudioDynamicsBindsExactAssetIDsAcrossCompactedSlots() throws {
    let (rig,original) = try studioSpring()
    var definition = original
    definition.ownerID = "hair-2/root"; definition.particles[0].nodeID = "hair-2/root"; definition.particles[1].nodeID = "hair-2/tip"
    let bound = try SourceStudioDynamics.bindHair(.init(components:[definition]),rig:rig)
    #expect(bound.bindings.count == 1 && bound.bindings[0].definition.ownerID == original.ownerID)
    definition.ownerID = "hair-2/different-asset/root"
    let absent = try SourceStudioDynamics.bindHair(.init(components:[definition]),rig:rig)
    #expect(absent.bindings.isEmpty && !absent.diagnostics.isEmpty)
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_DYNAMICS_FIXTURE", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT", "IKKOKU_MAKER_LIBRARY", "IKKOKU_STUDIO_ANIMATION_CATALOG", "IKKOKU_SOURCE_DYNAMICS"]), "Requires IKKOKU_STUDIO_DYNAMICS_FIXTURE, IKKOKU_SOURCE_AVATAR, IKKOKU_STUDIO_POSE_CONTRACT, IKKOKU_MAKER_LIBRARY, IKKOKU_STUDIO_ANIMATION_CATALOG, IKKOKU_SOURCE_DYNAMICS"))
func sourceStudioDynamicsActualAnimationIKOrderingAndRollbackWhenSupplied() throws {
    let env = ProcessInfo.processInfo.environment
    let input = try SourceFixtureSupport.require("IKKOKU_STUDIO_DYNAMICS_FIXTURE")
    let avatar = try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR")
    let catalog = try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT")
    let maker = try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")
    let animations = try SourceFixtureSupport.require("IKKOKU_STUDIO_ANIMATION_CATALOG")
    let contract = try SourceFixtureSupport.require("IKKOKU_SOURCE_DYNAMICS")
    let url = URL(fileURLWithPath:input),data = try Data(contentsOf:url)
    let resources = ResourceStore(device:try #require(MTLCreateSystemDefaultDevice()))
    func preview() throws -> SourceStudioCharacterPreview {
        try .init(reference:.init(sceneFile:input,sceneSHA256:OriginalCardFixture.hash(data),rigFile:avatar,boneCatalogFile:catalog,objectKey:10,makerLibraryFile:maker,animationCatalogFile:animations,dynamicsFile:contract),resources:resources)
    }
    let actual = try preview(),upstream = try preview(),rig = actual.preview.source.rig
    #expect(actual.dynamicsComponentCount == 5, "\(actual.diagnostics)")
    let sourceCard = try actual.record.card()
    let identity = try sourceCard.customization(),shape = try #require(actual.preview.contract)
    let settings = try sourceCard.previewSettings(contract:shape,sex:identity.sex,headID:identity.headID,boneType:identity.boneType)
    let initial = try actual.preview.pose(bodyValues:settings.bodyValues,faceValues:settings.faceValues,boneModifiers:settings.boneModifiers,coordinate:actual.coordinate)
    let definitions = try SourceStudioDynamics.bindHair(SourceDynamicsDocument.load(url:URL(fileURLWithPath:contract)),rig:rig).bindings
    var direct = try definitions.map {try SourceDynamicBone(rig:rig,pose:initial,definition:$0.definition)}
    var animation = SourceStudioAnimationState(record:actual.record)
    animation.group = 0; animation.category = 4; animation.no = 0; animation.normalizedTime = 0.25; animation.speed = 0.75
    let kinematics = SourceStudioKinematicState(enableFK:false,enableIK:true,activeFK:Array(repeating:false,count:7),activeIK:Array(repeating:true,count:5))
    let parent = try actual.ikCharacterFrame(pose:actual.pose)
    var targets:[Int32:SourceStudioIKEdit] = [:]
    for guide in actual.ikGuides {
        targets[guide.targetID] = try SourceStudioIKEditing.fromWorld(target:guide.targetID,position:guide.position,rotation:guide.rotationEnabled ? guide.rotation:nil,characterWorld:parent.matrix,characterRotation:parent.rotation,preserving:.init(position:.zero))
    }
    var maximum:Float = 0
    for frame in 1...12 {
        let time = Float(frame)/30
        targets[0]!.position.x = sin(time)*0.025
        let baseline = try upstream.editedPose(ikTargets:targets,kinematics:kinematics,animationState:animation,animationElapsed:time)
        var expected = baseline
        for index in direct.indices {expected = try direct[index].step(deltaTime:1/30,rig:rig,pose:expected)}
        let checkpoint = actual.captureDynamicsCheckpoint()
        // Gaze reads the solved pose before the live tick supplies dynamics.
        // Reuse that upstream cache, but integrate the new step exactly once.
        _ = try actual.editedPose(ikTargets:targets,kinematics:kinematics,animationState:animation,animationElapsed:time)
        try actual.setDynamicsStep(elapsed:time,deltaTime:1/30)
        let output = try actual.editedPose(ikTargets:targets,kinematics:kinematics,animationState:animation,animationElapsed:time)
        #expect(output.localMatrices == expected.localMatrices)
        let a = try rig.evaluate(output).worldMatrices,b = try rig.evaluate(expected).worldMatrices
        for (left,right) in zip(a,b) {maximum = max(maximum,simd_distance(left.translation,right.translation))}
        #expect(try actual.editedPose(ikTargets:targets,kinematics:kinematics,animationState:animation,animationElapsed:time).localMatrices == output.localMatrices)
        try actual.restoreDynamicsCheckpoint(checkpoint)
        try actual.setDynamicsStep(elapsed:time,deltaTime:1/30)
        #expect(try actual.editedPose(ikTargets:targets,kinematics:kinematics,animationState:animation,animationElapsed:time).localMatrices == output.localMatrices)
    }
    let report:[String:Any] = ["components":5,"frames":12,"upstream":"normal source animation + nonuniform Maker shape + full-body IK","maximumWorldError":maximum,"checkpointReplayIdentical":true]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url.deletingLastPathComponent().appendingPathComponent("native-ordering.json"))
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_DYNAMICS_FIXTURE", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT", "IKKOKU_MAKER_LIBRARY", "IKKOKU_STUDIO_MAKER_DYNAMICS"]), "Requires IKKOKU_STUDIO_DYNAMICS_FIXTURE, IKKOKU_SOURCE_AVATAR, IKKOKU_STUDIO_POSE_CONTRACT, IKKOKU_MAKER_LIBRARY, IKKOKU_STUDIO_MAKER_DYNAMICS"))
func sourceStudioDynamicsExpandedMakerHairIDsRetainSourceBindingsWhenSupplied() throws {
    let env = ProcessInfo.processInfo.environment
    let fixture = try SourceFixtureSupport.require("IKKOKU_STUDIO_DYNAMICS_FIXTURE")
    let avatar = try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR")
    let catalog = try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT")
    let maker = try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")
    let contract = try SourceFixtureSupport.require("IKKOKU_STUDIO_MAKER_DYNAMICS")
    let folder = URL(fileURLWithPath:fixture).deletingLastPathComponent()
    let resources = ResourceStore(device:try #require(MTLCreateSystemDefaultDevice()))
    var report:[[String:Any]] = []
    for (front,count) in [(1,8),(2,7),(5,6)] {
        let url = folder.appendingPathComponent(front == 1 ? "clothed-source.png" : "clothed-source-front\(front).png")
        let bytes = try Data(contentsOf:url)
        let preview = try SourceStudioCharacterPreview(reference:.init(sceneFile:url.path,sceneSHA256:OriginalCardFixture.hash(bytes),rigFile:avatar,boneCatalogFile:catalog,objectKey:10,makerLibraryFile:maker,dynamicsFile:contract),resources:resources)
        #expect(preview.dynamicsComponentCount == count,"\(preview.diagnostics)")
        let kinematics = SourceStudioKinematicState(enableFK:false,enableIK:false,activeFK:Array(repeating:false,count:7),activeIK:Array(repeating:false,count:5))
        let baseline = try preview.editedPose(kinematics:kinematics)
        var output = baseline
        for i in 1...6 {
            try preview.setDynamicsStep(elapsed:Float(i)/30,deltaTime:1/30)
            output = try preview.editedPose(kinematics:kinematics,animationElapsed:Float(i)/30)
            _ = try preview.preview.source.rig.evaluate(output)
        }
        #expect(output.localMatrices != baseline.localMatrices)
        #expect(preview.record.cardData == (try KoikatsuSceneReader.decodeDocument(bytes).snapshot.roots[0].character?.cardData))
        report.append(["frontHairID":front,"backHairID":0,"components":count,"frames":6,"cardUnchanged":true])
    }
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("maker-hair-coverage.json"))
}

private func skirtSpring() throws -> (RigDefinition, SourceDynamicsDocument.Component) {
    let rig = try RigDefinition(nodes: [
        .init(name: "body", sourceID: "body-master/CAB-body:0", parent: nil),
        .init(name: "skirt", sourceID: "body-master/CAB-body:1", parent: 0),
        .init(name: "tip", sourceID: "body-master/CAB-body:2", parent: 1, translation: Float3(0, -1, 0)),
        .init(name: "garment", sourceID: "clothes-0/CAB-cloth:1", parent: 0)], skins: [])
    let definition = SourceDynamicsDocument.Component(sourceID: "CAB-cloth:2", ownerID: "clothes-1/CAB-cloth:1",
        force: Float3(0.02, 0, 0), particles: [.init(nodeID: "body-master/CAB-body:1", parent: nil),
        .init(nodeID: "body-master/CAB-body:2", parent: 0)], group: .skirt, clothesKind: 1)
    return (rig, definition)
}

@Test func sourceStudioDynamicsSkirtBindsCompactedGarmentAndRejectsWrongIdentity() throws {
    let (rig, definition) = try skirtSpring()
    let document = SourceDynamicsDocument(components: [definition], schemaVersion: 2)
    let bindings = try SourceStudioDynamics.bind(document, rig: rig, clothingSlots: [1]).bindings
    #expect(bindings.count == 1 && bindings[0].group == .skirt)
    #expect(bindings[0].definition.ownerID == "clothes-0/CAB-cloth:1")
    #expect(bindings[0].definition.particles[0].nodeID == definition.particles[0].nodeID)
    #expect(throws: (any Error).self) { try SourceStudioDynamics.bind(document, rig: rig, clothingSlots: [0]) }
    var wrong = definition; wrong.ownerID = "clothes-1/CAB-other:1"
    let absent = try SourceStudioDynamics.bind(.init(components: [wrong], schemaVersion: 2), rig: rig, clothingSlots: [1])
    #expect(absent.bindings.isEmpty && absent.diagnostics.count == 1)
    wrong = definition; wrong.particles[1].nodeID = "body-master/CAB-other:2"
    #expect(throws: (any Error).self) { try SourceStudioDynamics.bind(.init(components: [wrong], schemaVersion: 2), rig: rig, clothingSlots: [1]) }
    #expect(throws: (any Error).self) { try SourceStudioDynamics.bind(.init(components: [definition]), rig: rig, clothingSlots: [1]) }
    wrong = definition; wrong.group = nil
    #expect(throws: (any Error).self) { try SourceStudioDynamics.bind(.init(components: [wrong], schemaVersion: 2), rig: rig, clothingSlots: [1]) }
    let legacy = try studioSpring()
    let migrated = SourceDynamicsDocument(components: [legacy.1], schemaVersion: 1)
    #expect(try SourceStudioDynamics.bind(migrated, rig: legacy.0).bindings.count == 1)
}

@Test func sourceStudioDynamicsSkirtFKWearReenableAndCheckpointReplay() throws {
    let (rig, definition) = try skirtSpring()
    let bindings = try SourceStudioDynamics.bind(.init(components: [definition], schemaVersion: 2), rig: rig, clothingSlots: [1]).bindings
    var session = try SourceStudioDynamics(rig: rig, initializationPose: rig.restPose, bindings: bindings)
    var fk = [Bool](repeating: false, count: 7)
    let moving = try session.evaluate(time: 1/30, rig: rig, upstream: rig.restPose, enableFK: false, activeFK: fk, deltaTime: 1/30)
    #expect(moving.localMatrices != rig.restPose.localMatrices)
    fk[6] = true
    let frozen = try session.evaluate(time: 2/30, rig: rig, upstream: rig.restPose, enableFK: true, activeFK: fk, deltaTime: 1/30)
    #expect(frozen.localMatrices == rig.restPose.localMatrices)
    var moved = rig.restPose; moved.localMatrices[0].translation = Float3(3, 0, 0)
    // Re-enable must seed particles at the current upstream pose, not carry
    // the impulse from the old owner position through a disabled interval.
    var fresh = try SourceDynamicBone(rig: rig, definition: bindings[0].definition)
    try fresh.resetParticles(rig: rig, pose: moved)
    let expected = try fresh.step(deltaTime: 1/30, rig: rig, pose: moved)
    let resumed = try session.evaluate(time: 3/30, rig: rig, upstream: moved, enableFK: false, activeFK: fk, deltaTime: 1/30)
    #expect(resumed.localMatrices == expected.localMatrices)
    let checkpoint = session
    let off = try session.evaluate(time: 4/30, rig: rig, upstream: moved, enableFK: false, activeFK: fk, deltaTime: 1/30, activeClothes: 0)
    #expect(off.localMatrices == moved.localMatrices)
    let on = try session.evaluate(time: 5/30, rig: rig, upstream: moved, enableFK: false, activeFK: fk, deltaTime: 1/30, activeClothes: 2)
    #expect(on.localMatrices == expected.localMatrices)
    session = checkpoint
    _ = try session.evaluate(time: 4/30, rig: rig, upstream: moved, enableFK: false, activeFK: fk, deltaTime: 1/30, activeClothes: 0)
    let replay = try session.evaluate(time: 5/30, rig: rig, upstream: moved, enableFK: false, activeFK: fk, deltaTime: 1/30, activeClothes: 2)
    #expect(replay.localMatrices == on.localMatrices)
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SKIRT_DYNAMICS_FIXTURE", "IKKOKU_SKIRT_DYNAMICS", "IKKOKU_SKIRT_MAKER_LIBRARY", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT"]),
               "Requires skirt fixture, dynamics, Maker library, source avatar and pose contract"))
func sourceStudioDynamicsActualSkirtWearOutfitAndRollbackWhenSupplied() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_SKIRT_DYNAMICS_FIXTURE")
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    let reference = SourceStudioCharacterReference(sceneFile: path, sceneSHA256: OriginalCardFixture.hash(bytes),
        rigFile: try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR"),
        boneCatalogFile: try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT"), objectKey: 10,
        makerLibraryFile: try SourceFixtureSupport.require("IKKOKU_SKIRT_MAKER_LIBRARY"),
        dynamicsFile: try SourceFixtureSupport.require("IKKOKU_SKIRT_DYNAMICS"))
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let preview = try SourceStudioCharacterPreview(reference: reference, resources: resources)
    #expect(preview.dynamicsComponentCount == 16, "\(preview.diagnostics)")
    let rig = preview.preview.source.rig
    let skirtIndices = rig.nodes.indices.filter { rig.nodes[$0].sourceID.hasPrefix("body-master/") && rig.nodes[$0].name.hasPrefix("cf_j_sk_") }
    #expect(skirtIndices.count == 48)
    var flags = [Bool](repeating: false, count: 7)
    var kinematics = SourceStudioKinematicState(enableFK: false, enableIK: false, activeFK: flags, activeIK: [Bool](repeating: false, count: 5))
    let upstream = try preview.editedPose(kinematics: kinematics)
    var moving = upstream
    for frame in 1...8 {
        try preview.setDynamicsStep(elapsed: Float(frame)/60, deltaTime: 1/60)
        moving = try preview.editedPose(kinematics: kinematics, animationElapsed: Float(frame)/60)
    }
    #expect(skirtIndices.contains { moving.localMatrices[$0] != upstream.localMatrices[$0] })
    let checkpoint = preview.captureDynamicsCheckpoint()
    try preview.setDynamicsStep(elapsed: 9/60, deltaTime: 1/60)
    let advanced = try preview.editedPose(kinematics: kinematics, animationElapsed: 9/60)
    try preview.restoreDynamicsCheckpoint(checkpoint)
    try preview.setDynamicsStep(elapsed: 9/60, deltaTime: 1/60)
    #expect(try preview.editedPose(kinematics: kinematics, animationElapsed: 9/60).localMatrices == advanced.localMatrices)
    var wear = preview.clothesState; wear[1] = 3
    try preview.setWear(clothesState: wear, showAccessory: nil, shoesType: nil)
    let off = try preview.editedPose(kinematics: kinematics, animationElapsed: 9/60)
    #expect(skirtIndices.allSatisfy { off.localMatrices[$0] == upstream.localMatrices[$0] })
    // Half state changes renderer switches, but the garment root remains active.
    wear[1] = 1; try preview.setWear(clothesState: wear, showAccessory: nil, shoesType: nil)
    try preview.setDynamicsStep(elapsed: 10/60, deltaTime: 1/60)
    let half = try preview.editedPose(kinematics: kinematics, animationElapsed: 10/60)
    #expect(skirtIndices.contains { half.localMatrices[$0] != upstream.localMatrices[$0] })
    flags[6] = true
    kinematics = .init(enableFK: true, enableIK: false, activeFK: flags, activeIK: [Bool](repeating: false, count: 5))
    try preview.setDynamicsStep(elapsed: 11/60, deltaTime: 1/60)
    let frozen = try preview.editedPose(kinematics: kinematics, animationElapsed: 11/60)
    #expect(skirtIndices.allSatisfy { frozen.localMatrices[$0] == upstream.localMatrices[$0] })
    let plain = try SourceStudioCharacterPreview(reference: reference, resources: resources, coordinate: 1)
    #expect(plain.dynamicsComponentCount == 8, "\(plain.diagnostics)")
    let restored = try SourceStudioCharacterPreview(reference: reference, resources: resources, coordinate: 0)
    #expect(restored.dynamicsComponentCount == 16)
    #expect(preview.record.cardData == restored.record.cardData && plain.record.cardData == restored.record.cardData)
    print("Skirt preview: 8 skirt + 8 hair components; motion, wear off/half, FK, checkpoint replay and 16→8→16 outfit rebuild verified")
    if ProcessInfo.processInfo.environment["IKKOKU_SKIRT_PERF_OUTPUT"] != nil {
        try writeSkirtReleaseTiming()
    }
}

@Test func sourceStudioDynamicsRejectsChangedTopologyBeforeUsingCachedChildren() throws {
    let (rig, definition) = try skirtSpring()
    let bound = try SourceStudioDynamics.bind(.init(components: [definition], schemaVersion: 2), rig: rig, clothingSlots: [1]).bindings[0]
    var state = try SourceDynamicBone(rig: rig, definition: bound.definition)
    let before = state.positions
    let changed = try RigDefinition(nodes: rig.nodes.enumerated().map { index, node in
        .init(name: node.name, sourceID: node.sourceID, parent: index == 2 ? 0 : node.parent,
              translation: node.translation, rotation: node.rotation, scale: node.scale)
    }, skins: [])
    #expect(throws: (any Error).self) { try state.step(deltaTime: 1/30, rig: changed, pose: changed.restPose) }
    #expect(state.positions == before)
}

/// Opt-in timing only: excluded even from strict fixture mode unless requested.
/// Run in Release with no other build/probe workload; this measures late-frame
/// evaluate on complete rigs, with FK disabled and every garment active.
private func writeSkirtReleaseTiming() throws {
    let env = ProcessInfo.processInfo.environment
    let output = try SourceFixtureSupport.require("IKKOKU_SKIRT_PERF_OUTPUT")
    let fixture = try SourceFixtureSupport.require("IKKOKU_SKIRT_DYNAMICS_FIXTURE")
    let scene = try SourceFixtureSupport.require("IKKOKU_STUDIO_SCENARIO_SCENE")
    let dynamicsURL = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SKIRT_DYNAMICS"))
    let document = try SourceDynamicsDocument.load(url: dynamicsURL)
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    var report: [[String: Any]] = []
    for (name, path) in [("skirt-fixture", fixture), ("character-scene", scene)] {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try KoikatsuSceneReader.decodeDocument(bytes)
        var stack = decoded.snapshot.roots, keys: [Int32] = []
        while let object = stack.popLast() {
            stack += object.children
            if let character = object.character { keys.append(object.sourceKey); stack += character.accessoryChildren.values.flatMap { $0 } }
        }
        var inputs: [(RigDefinition, RigPose, [SourceStudioDynamics.Binding])] = []
        for key in keys.sorted() {
            let preview = try SourceStudioCharacterPreview(reference: .init(sceneFile: path, sceneSHA256: OriginalCardFixture.hash(bytes),
                rigFile: try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR"), boneCatalogFile: try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT"),
                objectKey: key, makerLibraryFile: try SourceFixtureSupport.require("IKKOKU_SKIRT_MAKER_LIBRARY"), dynamicsFile: dynamicsURL.path), resources: resources)
            let bindings = try SourceStudioDynamics.bind(document, rig: preview.preview.source.rig, clothingSlots: preview.wearLayout.clothingKinds).bindings
            #expect(bindings.count == preview.dynamicsComponentCount)
            inputs.append((preview.preview.source.rig, preview.pose, bindings))
        }
        for skirt in [false, true] {
            let bindings = inputs.map { $0.2.filter { skirt || $0.group == .hair } }
            var sessions = try inputs.enumerated().map { i, input in try SourceStudioDynamics(rig: input.0, initializationPose: input.1, bindings: bindings[i]) }
            let flags = [Bool](repeating: false, count: 7)
            var times: [Double] = []
            for frame in 1...140 {
                let start = DispatchTime.now().uptimeNanoseconds
                for i in inputs.indices {
                    _ = try sessions[i].evaluate(time: Float(frame)/60, rig: inputs[i].0, upstream: inputs[i].1, enableFK: false, activeFK: flags, deltaTime: 1/60)
                }
                if frame > 20 { times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
            }
            times.sort()
            report.append(["input": name, "sceneSHA256": OriginalCardFixture.hash(bytes), "characters": keys.count,
                "mode": skirt ? "hair-and-clothes" : "hair-only", "components": bindings.map(\.count),
                "samples": times.count, "warmup": 20, "p50Milliseconds": times[times.count / 2], "p95Milliseconds": times[Int(Double(times.count) * 0.95)]])
        }
    }
    let result: [String: Any] = ["build": env["IKKOKU_SKIRT_PERF_BUILD"] ?? "unrecorded", "configuration": "Release; FK disabled; all garment roots active; static upstream; complete rigs; 1/60 delta",
        "dynamicsSHA256": OriginalCardFixture.hash(try Data(contentsOf: dynamicsURL)), "measurements": report]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    print("Skirt Release dynamics timing: \(report)")
}
