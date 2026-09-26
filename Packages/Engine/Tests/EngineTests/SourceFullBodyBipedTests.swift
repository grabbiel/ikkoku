import Foundation
import Testing
import simd
import CoreMath
import Scene
@testable import Studio

private struct BodyOracle: Decodable {
    struct Node: Decodable {
        let id: Int64, sourceID: String?, name: String?, parent: Int64?
        let position, rotation, scale: [Float]
        let worldPosition, worldRotation: [Float]?
    }
    struct Guide: Decodable { let id: Int32; let position,rotation:[Float] }
    struct Expected: Decodable { let nodes:[Node],guides:[Guide],solverPositions:[[[Float]]] }
    struct Frame: Decodable {
        let name:String,bindings:SourceStudioIK.Bindings,nodes:[Node],pose:[Node],active:[Bool],expected:Expected
    }
    let kind:String,cases:[Frame]
}
private func bodyV(_ a:[Float]) -> Float3 { Float3(a[0],a[1],a[2]) }
private func bodyQ(_ a:[Float]) -> simd_quatf { simd_quatf(ix:a[0],iy:a[1],iz:a[2],r:a[3]) }

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_FULLBODY_REFERENCE"]), "Requires IKKOKU_FULLBODY_REFERENCE"))
func sourceFullBodyMatchesRecoveredCSharpOracleWhenRequested() throws {
    let path=try SourceFixtureSupport.require("IKKOKU_FULLBODY_REFERENCE")
    let reference=try JSONDecoder().decode(BodyOracle.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
    #expect(reference.kind == "recovered-finalik-csharp-numerical-oracle")
    #expect(reference.cases.count >= 12)
    var reports:[[String:Any]]=[]
    for frame in reference.cases {
        let index=Dictionary(uniqueKeysWithValues:frame.nodes.enumerated().map { ($0.element.id,$0.offset) })
        let rig=try RigDefinition(nodes:frame.nodes.map { n in
            .init(name:n.name!,sourceID:n.sourceID!,parent:n.parent.flatMap { index[$0] },translation:UnityCoordinates.position(bodyV(n.position)),rotation:UnityCoordinates.rotation(bodyQ(n.rotation)),scale:bodyV(n.scale))
        },skins:[])
        var pose=rig.restPose
        for n in frame.pose { pose.localMatrices[index[n.id]!] = UnityCoordinates.matrix(Transform.trs(bodyV(n.position),bodyQ(n.rotation),bodyV(n.scale))) }
        func bind(_ r:SourceStudioIK.Bindings.NodeReference) throws ->Int {
            try #require(rig.nodes.firstIndex { $0.sourceID==r.sourceID && $0.name==r.name })
        }
        let runtime=try SourceFullBodyBiped(rig:rig,settings:#require(frame.bindings.fullBody),initialPose:rig.restPose,bind:bind)
        let groups:[SourceStudioPose.Group]=[.body,.leftArm,.leftArm,.leftArm,.rightArm,.rightArm,.rightArm,.leftLeg,.leftLeg,.leftLeg,.rightLeg,.rightLeg,.rightLeg]
        let guides=frame.expected.guides.map { g in SourceStudioIK.Guide(targetID:g.id,sourceKey:1000+g.id,group:groups[Int(g.id)],rotationEnabled:[3,6,9,12].contains(g.id),active:true,position:UnityCoordinates.position(bodyV(g.position)),rotation:UnityCoordinates.rotation(bodyQ(g.rotation))) }
        let result=try runtime.solve(rig:rig,pose:pose,guides:guides,active:frame.active,iterations:frame.bindings.iterations,root:bind(frame.bindings.root),vertical:frame.bindings.pullBodyVertical,horizontal:frame.bindings.pullBodyHorizontal)
        let world=try rig.evaluate(result.0).worldMatrices
        var maxPosition:Float=0,maxRotation:Float=0,maxSolver:Float=0,worst=""
        for expected in frame.expected.nodes {
            let i=index[expected.id]!,m=world[i]
            let position=UnityCoordinates.position(Float3(m[3].x,m[3].y,m[3].z))
            let error=simd_distance(position,bodyV(expected.worldPosition!))
            if error>maxPosition {maxPosition=error;worst=rig.nodes[i].name}
            let rotation=try SourceStudioGuide.rotation(node:i,rig:rig,pose:result.0)
            maxRotation=max(maxRotation,1-abs(simd_dot(rotation.vector,UnityCoordinates.rotation(bodyQ(expected.worldRotation!)).normalized.vector)))
        }
        for i in result.2.indices {for j in result.2[i].indices {maxSolver=max(maxSolver,simd_distance(result.2[i][j],bodyV(frame.expected.solverPositions[i][j])))}}
        reports.append(["case":frame.name,"maximumWorldPositionError":maxPosition,"maximumQuaternionDotError":maxRotation,"maximumSolverPositionError":maxSolver,"worstTransform":worst])
        #expect(maxSolver<0.0001,"\(frame.name) solver positions error \(maxSolver)")
        #expect(maxPosition<0.0005,"\(frame.name) world error \(maxPosition) at \(worst)")
        #expect(maxRotation<0.00002,"\(frame.name) quaternion error \(maxRotation)")
        // Fresh state on every call prevents repeated preview evaluation from
        // accumulating constraint offsets or mutating saved guide identities.
        let repeatResult=try runtime.solve(rig:rig,pose:pose,guides:guides,active:frame.active,iterations:frame.bindings.iterations,root:bind(frame.bindings.root),vertical:frame.bindings.pullBodyVertical,horizontal:frame.bindings.pullBodyHorizontal)
        #expect(repeatResult.0.localMatrices == result.0.localMatrices)
    }
    if let report=ProcessInfo.processInfo.environment["IKKOKU_FULLBODY_REPORT"] {
        try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:report))
    }
}

private func syntheticFullBody(scale: Float3 = .one, iterations: Int = 4) throws -> (RigDefinition, SourceStudioIK.Bindings) {
    var nodes:[RigDefinition.Node]=[]
    func add(_ name:String,_ parent:Int?,_ position:Float3,_ scale:Float3 = .one)->Int {
        let i=nodes.count;nodes.append(.init(name:name,sourceID:"synthetic/\(i)",parent:parent,translation:UnityCoordinates.position(position),scale:scale));return i
    }
    func ref(_ i:Int)->[String:Any] {["sourceID":nodes[i].sourceID,"name":nodes[i].name]}
    let root=add("root",nil,.zero),pelvis=add("pelvis",root,Float3(0,1,0),scale)
    let body=add("spine1",pelvis,Float3(0,0.2,0)),spine2=add("spine2",body,Float3(0,0.2,0)),neck=add("neck",spine2,Float3(0,0.2,0))
    let head=add("head",neck,Float3(0,0.15,0))
    var limbs:[[Int]]=[],parents:[Int?]=[]
    for i in 0..<4 {
        let arm=i<2,side:Float=(i==0 || i==2) ? -1:1
        let parent=arm ? add("shoulder\(i)",spine2,Float3(side * 0.1,0.12,0)):pelvis
        let a=add("proximal\(i)",parent,arm ? Float3(side * 0.1,0,0):Float3(side * 0.1,-0.07,0))
        let b=add("bend\(i)",a,arm ? Float3(side * 0.25,-0.03,0.05):Float3(0,-0.42,0.04))
        let c=add("distal\(i)",b,arm ? Float3(side * 0.24,-0.02,-0.03):Float3(0,-0.4,-0.02))
        limbs.append([a,b,c]);parents.append(arm ? parent:nil)
    }
    let unrelated=add("mirrored accessory",root,Float3(2,0,0),Float3(-1,1,1))
    _=unrelated
    let groups=["leftArm","rightArm","leftLeg","rightLeg"]
    var targets:[[String:Any]]=[["id":0,"group":"body","rotationEnabled":false,"prefabTarget":ref(pelvis)]]
    var limbBindings:[[String:Any]]=[]
    for i in 0..<4 {
        for j in 0..<3 { targets.append(["id":i*3+j+1,"group":groups[i],"rotationEnabled":j==2,"prefabTarget":ref(limbs[i][j])]) }
        limbBindings.append(["group":groups[i],"targetIDs":[i*3+1,i*3+2,i*3+3],"nodes":limbs[i].map(ref)])
    }
    let chainNodes=[[body]]+limbs
    let pairs=[(1,4),(2,3),(1,2),(3,4)]
    let constraints:[[String:Any]]=pairs.enumerated().map { i,pair in ["bone1":ref(chainNodes[pair.0][0]),"bone2":ref(chainNodes[pair.1][0]),"pushElasticity":0,"pullElasticity":i<2 ? 1:0] }
    let chains:[[String:Any]]=chainNodes.enumerated().map { i,n in ["nodes":n.map(ref),"children":i==0 ? [1,2,3,4]:[],"constraints":i==0 ? constraints:[],"pin":0,"pull":1,"push":0,"pushParent":0,"reach":0,"reachSmoothing":1,"pushSmoothing":1,"bendWeight":i==0 ? 0:1] }
    let effectorNodes=[body]+limbs.map { $0[0] }+limbs.map { $0[2] }
    let planes=[[],[],[],[],[],[limbs[0][0],limbs[1][0],body],[limbs[1][0],limbs[0][0],body],[limbs[2][0],limbs[3][0],body],[limbs[3][0],limbs[2][0],body]]
    let effects:[[String:Any]]=effectorNodes.enumerated().map { i,n in ["bone":ref(n),"children":i==0 ? [ref(limbs[2][0]),ref(limbs[3][0])]:[],"plane":planes[i].map(ref),"effectChildNodes":true,"positionWeight":0,"rotationWeight":0,"maintainRelativePositionWeight":0] }
    let mappings:[[String:Any]]=limbs.enumerated().map { i,n in ["parent":parents[i].map(ref) as Any? ?? NSNull(),"bones":n.map(ref),"maintainRotationWeight":i>=2 ? 1:0,"weight":1] }
    let full:[String:Any]=["weight":1,"spineStiffness":0.5,"chains":chains,"effectors":effects,"spine":["bones":[pelvis,body,spine2,neck].map(ref),"iterations":3,"twistWeight":1],"bones":[["bone":ref(head),"maintainRotationWeight":1]],"limbs":mappings]
    let data:[String:Any]=["schemaVersion":2,"root":ref(root),"pelvis":ref(pelvis),"body":ref(body),"iterations":iterations,"pullBodyVertical":0.5,"pullBodyHorizontal":0,"targets":targets,"limbs":limbBindings,"fullBody":full]
    return (try RigDefinition(nodes:nodes,skins:[]),try JSONDecoder().decode(SourceStudioIK.Bindings.self,from:JSONSerialization.data(withJSONObject:data)))
}

@Test func sourceFullBodyCouplesBodySpineAndShouldersAndPreservesHeadRotation() throws {
    let (rig,bindings)=try syntheticFullBody()
    let solver=try SourceStudioIK(rig:rig,bindings:bindings)
    let saved:[Int32:KoikatsuBoneRecord]=[0:.init(sourceKey:7301,transform:.init(position:Float3(0.1,1.18,0.08),rotationDegrees:.zero,scale:.one)),1:.init(sourceKey:9312,transform:.init(position:Float3(-0.28,1.55,0.12),rotationDegrees:.zero,scale:.one))]
    let result=try solver.apply(rig:rig,baseline:rig.restPose,savedTargets:saved,enabled:true,activeGroups:[true,true,true,true,true],characterRoot:0)
    #expect(result.appliedTargetIDs == Set((0...12).map(Int32.init)))
    #expect(result.deferredTargetIDs.isEmpty && result.diagnostics.isEmpty)
    #expect(result.guides.first {$0.targetID==0}?.sourceKey == 7301)
    let pelvis=try rig.uniqueNode(named:"pelvis"),shoulder=try rig.uniqueNode(named:"shoulder0"),head=try rig.uniqueNode(named:"head")
    #expect(result.pose.localMatrices[pelvis] != rig.restPose.localMatrices[pelvis])
    #expect(result.pose.localMatrices[shoulder] != rig.restPose.localMatrices[shoulder])
    let headRotation=try SourceStudioGuide.rotation(node:head,rig:rig,pose:result.pose)
    #expect(abs(simd_dot(headRotation.vector,simd_quatf.identity.vector)) > 0.99999)
    let accessory=try rig.uniqueNode(named:"mirrored accessory")
    #expect(result.pose.localMatrices[accessory] == rig.restPose.localMatrices[accessory])
}

@Test func sourceFullBodySupportsNonuniformCustomizationAndZeroIterationBodyBranch() throws {
    for iterations in [0,1,4] {
        let (rig,bindings)=try syntheticFullBody(scale:Float3(1.12,0.94,1.06),iterations:iterations)
        let solver=try SourceStudioIK(rig:rig,bindings:bindings,initializationPose:rig.restPose)
        let targets:[Int32:KoikatsuBoneRecord]=[0:.init(sourceKey:6,transform:.init(position:Float3(0.05,1.08,0.04),rotationDegrees:.zero,scale:.one))]
        let result=try solver.apply(rig:rig,baseline:rig.restPose,savedTargets:targets,enabled:true,activeGroups:[true,true,true,true,true],characterRoot:0)
        #expect(result.deferredTargetIDs.isEmpty)
        _=try rig.evaluate(result.pose)
        let again=try solver.apply(rig:rig,baseline:rig.restPose,savedTargets:targets,enabled:true,activeGroups:[true,true,true,true,true],characterRoot:0)
        #expect(again.pose.localMatrices == result.pose.localMatrices)
    }
}

@Test func sourceFullBodyInitializesMissingGuidesFromBonesAndRejectsReflectedSolverParents() throws {
    let (rig,bindings)=try syntheticFullBody()
    let solver=try SourceStudioIK(rig:rig,bindings:bindings)
    let result=try solver.apply(rig:rig,baseline:rig.restPose,savedTargets:[:],enabled:false,activeGroups:[true,true,true,true,true],characterRoot:0)
    #expect(result.guides.first {$0.targetID==0}?.position == Float3(0,1,0))
    #expect(result.pose.localMatrices == rig.restPose.localMatrices)
    #expect(throws:(any Error).self) {
        let (reflected,b)=try syntheticFullBody(scale:Float3(-1,1,1))
        _=try SourceStudioIK(rig:reflected,bindings:b)
    }
}

@Test func sourceFullBodyMissingTargetsCaptureInitializationInsteadOfFollowingAnimation() throws {
    let (rig,bindings)=try syntheticFullBody()
    let solver=try SourceStudioIK(rig:rig,bindings:bindings,initializationPose:rig.restPose)
    var animated=rig.restPose
    let body=try rig.uniqueNode(named:"spine1")
    animated.localMatrices[body]=Transform.trs(Float3(0,0.3,0),simd_quatf(angle:0.2,axis:Float3(0,0,1)),.one)
    let initial=try solver.apply(rig:rig,baseline:rig.restPose,savedTargets:[:],enabled:false,activeGroups:[true,true,true,true,true],characterRoot:0)
    let later=try solver.apply(rig:rig,baseline:animated,savedTargets:[:],enabled:false,activeGroups:[true,true,true,true,true],characterRoot:0)
    #expect(initial.guides.map(\.position) == later.guides.map(\.position))
    #expect(initial.guides.map { $0.rotation.vector } == later.guides.map { $0.rotation.vector })
}
