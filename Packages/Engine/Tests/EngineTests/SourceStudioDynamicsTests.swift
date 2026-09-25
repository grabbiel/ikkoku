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

@Test func sourceStudioDynamicsActualAnimationIKOrderingAndRollbackWhenSupplied() throws {
    let env = ProcessInfo.processInfo.environment
    guard let input = env["IKKOKU_STUDIO_DYNAMICS_FIXTURE"],let avatar = env["IKKOKU_SOURCE_AVATAR"],
          let catalog = env["IKKOKU_STUDIO_POSE_CONTRACT"],let maker = env["IKKOKU_MAKER_LIBRARY"],
          let animations = env["IKKOKU_STUDIO_ANIMATION_CATALOG"],let contract = env["IKKOKU_SOURCE_DYNAMICS"] else {return}
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

@Test func sourceStudioDynamicsExpandedMakerHairIDsRetainSourceBindingsWhenSupplied() throws {
    let env = ProcessInfo.processInfo.environment
    guard let fixture = env["IKKOKU_STUDIO_DYNAMICS_FIXTURE"],let avatar = env["IKKOKU_SOURCE_AVATAR"],
          let catalog = env["IKKOKU_STUDIO_POSE_CONTRACT"],let maker = env["IKKOKU_MAKER_LIBRARY"],
          let contract = env["IKKOKU_STUDIO_MAKER_DYNAMICS"] else {return}
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
