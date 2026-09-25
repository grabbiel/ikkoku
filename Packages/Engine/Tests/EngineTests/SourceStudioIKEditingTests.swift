import Foundation
import Testing
import Metal
import simd
import CoreMath
import Scene
import Studio
import Character
import Renderer

private func ikTransformBytes(_ value: KoikatsuChangeAmount) -> Data {
    var data=Data()
    for vector in [value.position,value.rotationDegrees,value.scale] { for value in [vector.x,vector.y,vector.z] {data += OriginalCardFixture.i32(Int32(bitPattern:value.bitPattern))} }
    return data
}
/// An authored synthetic fixture expands its single test target to all original
/// target numbers. Production export deliberately cannot add source records.
private func allIKTargetFixture(_ bytes: Data, values: [Int32:SourceStudioIKEdit]) throws -> Data {
    let original=try KoikatsuSceneReader.decodeDocument(bytes),record=try #require(original.snapshot.roots.first?.character)
    #expect(record.ikTargets.count == 1)
    let old=try #require(record.ikTargets[3])
    let pattern=OriginalCardFixture.i32(1)+OriginalCardFixture.i32(3)+OriginalCardFixture.i32(old.sourceKey)+ikTransformBytes(old.transform)
    let range=try #require(bytes.range(of:pattern))
    var replacement=OriginalCardFixture.i32(13)
    for id:Int32 in 0...12 {
        let edit=values[id] ?? .init(position:Float3(Float(id)*0.01,1,0))
        replacement += OriginalCardFixture.i32(id)+OriginalCardFixture.i32(id==3 ? old.sourceKey:8000+id)
        replacement += ikTransformBytes(.init(position:edit.position,rotationDegrees:edit.rotationDegrees,scale:Float3(2,3,4)))
    }
    var result=bytes;result.replaceSubrange(range,with:replacement);return result
}

@Test func sourceIKWorldCallbacksInvertScaledAttachedCharacterAndKeepDisabledRotation() throws {
    let attachmentRotation=simd_quatf(eulerXYZ:Float3(0.2,-0.4,0.1)),characterRotation=simd_quatf(eulerXYZ:Float3(-0.1,0.3,0.2))
    let world=Transform.trs(Float3(2,3,4),attachmentRotation,Float3(2,1,0.7))*Transform.trs(Float3(0.2,0.4,0.1),characterRotation,Float3(1.1,0.9,1))
    let orientation=attachmentRotation*characterRotation,local=Float3(0.2,1.3,-0.4),angles=Float3(23,47,-16)
    let point=world*Float4(UnityCoordinates.position(local),1),rotation=orientation*UnityCoordinates.eulerDegrees(angles)
    let edit=try SourceStudioIKEditing.fromWorld(target:3,position:Float3(point.x,point.y,point.z),rotation:rotation,characterWorld:world,characterRotation:orientation,preserving:.init(position:.zero))
    #expect(simd_distance(edit.position,local)<0.000001)
    #expect(abs(simd_dot(UnityCoordinates.eulerDegrees(edit.rotationDegrees).vector,UnityCoordinates.eulerDegrees(angles).vector))>0.999999)
    let proximal=try SourceStudioIKEditing.fromWorld(target:1,position:Float3(point.x,point.y,point.z),rotation:nil,characterWorld:world,characterRotation:orientation,preserving:.init(position:.zero,rotationDegrees:Float3(7,8,9)))
    #expect(proximal.rotationDegrees == Float3(7,8,9))
    #expect(throws:(any Error).self) {try SourceStudioIKEditing.fromWorld(target:1,position:.zero,rotation:.identity,characterWorld:world,characterRotation:orientation,preserving:edit)}
    for id:Int32 in 0...12 {
        #expect(SourceStudioIKEditing.targetID(fromPick:SourceStudioIKEditing.pickID(id)) == id)
        #expect(PickIDs.ikIndex(from:SourceStudioIKEditing.pickID(id)) == nil)
    }
}

@Test func sourceIKAllGuidesNativeAndOriginalExportPreserveKeysScalePluginsAndActivation() throws {
    let bytes=try allIKTargetFixture(SceneDocumentBytes.scene().data,values:[:]),source=try KoikatsuSceneReader.decodeDocument(bytes)
    let record=try #require(source.snapshot.roots.first?.character)
    let overrides=Dictionary(uniqueKeysWithValues:(0...12).map { id in (Int32(id),SourceStudioIKEdit(position:Float3(Float(id)*0.02,1.2,-0.1),rotationDegrees:Float3(10,20,30))) })
    let state=SourceStudioKinematicState(enableFK:false,enableIK:true,activeFK:record.activeFK,activeIK:[true,false,true,true,false])
    var scene=StudioDocument(),object=StudioObject(name:"Original",kind:.character)
    object.sourceIKOverrides=overrides;object.sourceKinematics=state;object.sourceObjectKey=10;scene.objects=[object]
    let native=try CardIO.encode(scene,keyword:CardIO.sceneKeyword,thumbnail:nil)
    #expect(try CardIO.decode(StudioDocument.self,keyword:CardIO.sceneKeyword,from:native) == scene)
    var edits=SourceSceneEdits();try SourceStudioIKEditing.appendEdits(objectKey:10,record:record,overrides:overrides,state:state,to:&edits)
    let changed=try source.editedData(edits),after=try KoikatsuSceneReader.decodeDocument(changed),result=try #require(after.snapshot.roots.first?.character)
    #expect(after.trailingData == source.trailingData && result.cardData == record.cardData)
    #expect(result.activeIK == state.activeIK && result.activeFK == state.activeFK && result.enableIK && !result.enableFK)
    for id:Int32 in 0...12 {
        #expect(result.ikTargets[id]?.sourceKey == record.ikTargets[id]?.sourceKey)
        #expect(result.ikTargets[id]?.transform.scale == Float3(2,3,4))
        #expect(result.ikTargets[id]?.transform.position == overrides[id]?.position)
        #expect(result.ikTargets[id]?.transform.rotationDegrees == (SourceStudioIKEditing.allowsRotation(id) ? overrides[id]?.rotationDegrees:record.ikTargets[id]?.transform.rotationDegrees))
    }
    let reverse=SourceSceneEdits(transforms:record.ikTargets.map { .init(.characterIK(object:10,target:$0.key),transform:$0.value.transform) },kinematics:[10:SourceStudioKinematicState(record:record).edit])
    #expect(try after.editedData(reverse) == bytes)
}

@Test(.enabled(if:MTLCreateSystemDefaultDevice() != nil))
func sourceIKEditedAllBodyProximalAndDistalGuidesMatchOriginalSceneReloadWhenSupplied() throws {
    let env=ProcessInfo.processInfo.environment
    guard let directory=env["IKKOKU_STUDIO_EXPANSION"],let library=env["IKKOKU_MAKER_LIBRARY"],let avatar=env["IKKOKU_SOURCE_AVATAR"],let catalog=env["IKKOKU_STUDIO_POSE_CONTRACT"] else{return}
    let folder=URL(fileURLWithPath:directory),originalURL=folder.appendingPathComponent("studio-female-head200-bone1.png")
    let originalData=try Data(contentsOf:originalURL),resources=ResourceStore(device:try #require(MTLCreateSystemDefaultDevice()))
    func load(_ url:URL,_ data:Data)throws->SourceStudioCharacterPreview {
        try SourceStudioCharacterPreview(reference:.init(sceneFile:url.path,sceneSHA256:OriginalCardFixture.hash(data),rigFile:avatar,boneCatalogFile:catalog,objectKey:10,makerLibraryFile:library),resources:resources)
    }
    let seed=try load(originalURL,originalData),parent=try seed.ikCharacterFrame(pose:seed.pose)
    var values:[Int32:SourceStudioIKEdit]=[:]
    for guide in seed.ikGuides {
        values[guide.targetID]=try SourceStudioIKEditing.fromWorld(target:guide.targetID,position:guide.position,rotation:guide.rotationEnabled ? guide.rotation:nil,characterWorld:parent.matrix,characterRotation:parent.rotation,preserving:.init(position:.zero))
    }
    #expect(values.count == 13)
    let input=try allIKTargetFixture(originalData,values:values),inputURL=folder.appendingPathComponent("studio-ik-all-guides.png")
    try input.write(to:inputURL)
    let before=try load(inputURL,input),source=try KoikatsuSceneReader.decodeDocument(input)
    var overrides=values
    for id:Int32 in 0...12 {
        overrides[id]!.position += Float3(Float(id%3-1)*0.025,0.02,Float(id%2)*0.015)
        if SourceStudioIKEditing.allowsRotation(id) {overrides[id]!.rotationDegrees += Float3(5,-7,3)}
    }
    let state=SourceStudioKinematicState(enableFK:false,enableIK:true,activeFK:before.record.activeFK,activeIK:[true,true,true,true,true])
    var edits=SourceSceneEdits();try SourceStudioIKEditing.appendEdits(objectKey:10,record:before.record,overrides:overrides,state:state,to:&edits)
    let output=try source.editedData(edits),outputURL=folder.appendingPathComponent("studio-ik-all-guides-edited.png");try output.write(to:outputURL)
    let after=try load(outputURL,output),pose=try before.editedPose(ikTargets:overrides,kinematics:state)
    let a=try before.preview.source.rig.evaluate(pose),b=try after.preview.source.rig.evaluate(after.pose)
    var localError:Float=0,vertexError:Float=0,vertices=0
    for i in pose.localMatrices.indices {for c in 0..<4 {for r in 0..<4 {localError=max(localError,abs(pose.localMatrices[i][c][r]-after.pose.localMatrices[i][c][r]))}}}
    let expression=try #require(before.preview.expressionContract),inputs=try #require(before.expressionInputs)
    let weights=try expression.weights(source:before.preview.source,inputs:inputs)
    for (left,right) in zip(before.preview.source.parts,after.preview.source.parts) {
        let lp=try before.preview.source.deformedPositions(part:left,evaluation:a,morphWeights:weights[left.mesh.name] ?? [])
        let rp=try after.preview.source.deformedPositions(part:right,evaluation:b,morphWeights:weights[right.mesh.name] ?? [])
        for (x,y) in zip(lp,rp) {vertices+=1;vertexError=max(vertexError,simd_distance(x,y))}
    }
    #expect(localError==0 && vertexError==0)
    #expect(after.record.cardData == before.record.cardData)
    #expect(try KoikatsuSceneReader.decodeDocument(output).trailingData == source.trailingData)
    let report:[String:Any]=["targets":13,"localMatrixMaximumError":localError,"deformedVertexMaximumError":vertexError,"vertices":vertices,"cardByteIdentical":true,"scenePluginTrailerByteIdentical":true,"input":inputURL.path,"output":outputURL.path]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("ik-roundtrip-audit.json"))
    let capture:[[String:Any]]=[["objectKey":10,"ikTargets":Dictionary(uniqueKeysWithValues:overrides.map {(String($0.key),["position":[$0.value.position.x,$0.value.position.y,$0.value.position.z],"rotationDegrees":[$0.value.rotationDegrees.x,$0.value.rotationDegrees.y,$0.value.rotationDegrees.z]])}),"kinematics":["enableFK":false,"enableIK":true,"activeFK":state.activeFK,"activeIK":state.activeIK]]]
    try JSONSerialization.data(withJSONObject:capture,options:.prettyPrinted).write(to:folder.appendingPathComponent("ik-capture-edits.json"))
}

@Test func sourceIKAppCapturePreservesAllGuideRecordsWhenSupplied() throws {
    guard let file = ProcessInfo.processInfo.environment["IKKOKU_IK_APP_ENVIRONMENT"] else { return }
    let environment = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: URL(fileURLWithPath:file)))
    func bytes(_ key:String) throws -> Data { try Data(contentsOf:URL(fileURLWithPath:try #require(environment[key]))) }
    let original = try KoikatsuSceneReader.decodeDocument(bytes("IKKOKU_SOURCE_SCENE"))
    let output = try KoikatsuSceneReader.decodeDocument(bytes("IKKOKU_EXPORT_SOURCE_SCENE"))
    let native = try CardIO.decode(StudioDocument.self,keyword:CardIO.sceneKeyword,from:bytes("IKKOKU_SAVE_SCENE"))
    let a = try #require(original.snapshot.roots.first?.character),b = try #require(output.snapshot.roots.first?.character)
    let object = try #require(native.objects.first {$0.sourceObjectKey == 10})
    let overrides = try #require(object.sourceIKOverrides), state = try #require(object.sourceKinematics)
    #expect(overrides.count == 13 && b.ikTargets.count == 13)
    #expect(a.cardData == b.cardData && original.trailingData == output.trailingData)
    #expect(b.enableIK == state.enableIK && b.enableFK == state.enableFK && b.activeIK == state.activeIK && b.activeFK == state.activeFK)
    for id:Int32 in 0...12 {
        #expect(b.ikTargets[id]?.sourceKey == a.ikTargets[id]?.sourceKey)
        #expect(b.ikTargets[id]?.transform.scale == a.ikTargets[id]?.transform.scale)
        #expect(b.ikTargets[id]?.transform.position == overrides[id]?.position)
        #expect(b.ikTargets[id]?.transform.rotationDegrees == (SourceStudioIKEditing.allowsRotation(id) ? overrides[id]?.rotationDegrees : a.ikTargets[id]?.transform.rotationDegrees))
    }
}
