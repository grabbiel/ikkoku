import Foundation
import Testing
import Assets
import Character
@testable import Studio

// ST-T03 / ST-S09 / ST-D03: duplicates and new folders, cameras and lights.
// Each expected export is the final tree written field by field by
// `TopologyScene` (an independent serialization), never by the writer.
//
// Original tree (as `SourceSceneTopologyTests`), with sub-info keys:
//   0 camera (active)              root
//   1 folder [2 camera (active), 3 item {bone arm: 105} [4 folder], 5 light]
//   6 folder [7 item]
//   8 route [9 folder]
//   10 character {FK 1: 101, 2: 102; IK 3: 103; look-at 104} {point 0: [], point 7: [11 folder]}
//   12 item
// Used keys: 0...12 and 101...105, so CharaStudio's GetNewIndex hands out 13, 14, ...
private let camera0 = TopologyNode.camera(0, active: true)
private let route8 = TopologyNode.route(8, [.folder(9, [])])
private let item12 = TopologyNode.item(12, [])
private func folder1(_ extra: [TopologyNode] = []) -> TopologyNode {
    .folder(1, [.camera(2, active: true), .item(3, [.folder(4, [])]), .light(5)] + extra)
}
private func folder6(_ children: [TopologyNode] = [.item(7, [])]) -> TopologyNode { .folder(6, children) }
private func character(_ key: Int32, attached: [TopologyNode]) -> TopologyNode {
    let groups: [(point: Int32, children: [TopologyNode])] = [(point: Int32(0), children: [TopologyNode]()),
                                                             (point: Int32(7), children: attached)]
    return .character(key, groups)
}
private func character10(_ attached: [TopologyNode] = [.folder(11, [])]) -> TopologyNode { character(10, attached: attached) }

/// The scene with the sub-info keys above, and any extra roots.
private func scene(_ roots: [TopologyNode]? = nil, trailer: Data = Data()) -> TopologyScene {
    var scene = TopologyScene(roots: roots ?? [camera0, folder1(), folder6(), route8, character10(), item12], trailer: trailer)
    let fk: [(id: Int32, key: Int32)] = [(id: Int32(1), key: Int32(101)), (id: Int32(2), key: Int32(102))]
    let ik: [(id: Int32, key: Int32)] = [(id: Int32(3), key: Int32(103))]
    scene.fk[10] = fk; scene.ik[10] = ik
    scene.itemBones[3] = [(name: "arm", key: Int32(105))]
    return scene
}
private func decoded(_ scene: TopologyScene) throws -> KoikatsuSceneDocument { try KoikatsuSceneReader.decodeDocument(scene.data) }
private func amount(_ values: [Float]) -> KoikatsuChangeAmount {
    .init(position: SIMD3(values[0], values[1], values[2]), rotationDegrees: SIMD3(values[3], values[4], values[5]),
          scale: SIMD3(values[6], values[7], values[8]))
}
private func reason(_ body: () throws -> Any) -> String {
    do { _ = try body(); return "accepted" }
    catch let error as SourceSceneTopologyError { return error.errorDescription ?? "" }
    catch { return "other error: \(error)" }
}
private let identity: [Float] = [0, 0, 0, 0, 0, 0, 1, 1, 1]

@Test func sourceSceneInsertionDuplicatesAFolderSubtreeUnderNewKeys() throws {
    let original = try decoded(scene())
    // Folder 6 and its item 7, copied the way Studio.Duplicate does it: the
    // copy is appended to the root dictionary (folder 6 was a root) under
    // the first free keys, folder before child (SceneInfo.Import order).
    let insertions = [SourceSceneInsertion(.duplicate(of: 6)), .init(.duplicate(of: 7), parent: .inserted(0))]
    let stage = try original.inserting(insertions)
    #expect(stage.keys == [13, 14])
    var expected = scene([camera0, folder1(), folder6(), route8, character10(), item12, .folder(13, [.item(14, [])])])
    expected.copies = [13: 6, 14: 7]
    #expect(stage.document.preservedData == expected.data)
    #expect(try original.editedData(.init(insertions: insertions)) == expected.data)
    // The reload reads the copy back with its own keys and the original's
    // name, placement and item catalog number.
    let copy = try #require(stage.document.snapshot.roots.last)
    #expect(copy.sourceKey == 13 && copy.rootDictionaryKey == 13 && copy.name == "Folder 6")
    #expect(copy.transform == amount(TopologyScene.transform(6)))
    #expect(copy.children.map(\.sourceKey) == [Int32(14)] && copy.children[0].item?.no == 7)
    #expect(try original.editedData(.init()) == scene().data, "the source document is unchanged")
}

@Test func sourceSceneInsertionDuplicatesItemsWithBonesAndChildren() throws {
    let original = try decoded(scene())
    // Item 3 is duplicated beside itself in folder 1: its FK bone key comes
    // before its child's (OIItemInfo.Load), so item 13, bone 14, folder 15.
    let stage = try original.inserting([.init(.duplicate(of: 3), parent: .source(1)),
                                        .init(.duplicate(of: 4), parent: .inserted(0))])
    #expect(stage.keys == [13, 15])
    var expected = scene([camera0, folder1([.item(13, [.folder(15, [])])]), folder6(), route8, character10(), item12])
    expected.copies = [13: 3, 15: 4]; expected.itemBones[13] = [(name: "arm", key: Int32(14))]
    #expect(stage.document.preservedData == expected.data)
    // An item's own child list takes a duplicate of its child (OCIItem.OnLoadAttach).
    let beside = try original.inserting([.init(.duplicate(of: 4), parent: .source(3))])
    var besideExpected = scene([camera0, .folder(1, [.camera(2, active: true), .item(3, [.folder(4, []), .folder(13, [])]), .light(5)]),
                                folder6(), route8, character10(), item12])
    besideExpected.copies = [13: 4]
    #expect(beside.document.preservedData == besideExpected.data)
}

@Test func sourceSceneInsertionDuplicatesCamerasInactiveAndTakesTheViewOnlyWhenAsked() throws {
    let original = try decoded(scene())
    // Camera 2 is the looked-through camera; its copy is written inactive,
    // so the reload keeps looking through camera 2.
    let insertions = [SourceSceneInsertion(.duplicate(of: 2), parent: .source(1))]
    let stage = try original.inserting(insertions)
    var expected = scene([camera0, folder1([.camera(13, active: false)]), folder6(), route8, character10(), item12])
    expected.copies = [13: 2]
    #expect(stage.document.preservedData == expected.data)
    #expect(SourceStudioCameraObjects.activeAtLoad(stage.document.snapshot) == 2)
    // CharaStudio gives the view to the copy of the active camera; the
    // caller writes that with explicit flags keyed by the copy's key.
    let viewed = try original.editedData(.init(cameraActive: [0: false, 2: false, 13: true], insertions: insertions))
    var literal = expected; literal.cameraActive = [0: false, 2: false, 13: true]
    #expect(viewed == literal.data)
    #expect(SourceStudioCameraObjects.activeAtLoad(try KoikatsuSceneReader.decodeDocument(viewed).snapshot) == 13)
}

@Test func sourceSceneInsertionDuplicatesCharactersWithEverySubInfoKey() throws {
    let original = try decoded(scene())
    // OICharInfo.Load order: record 13, FK bones 14 and 15, IK target 16,
    // the accessory child 17, then the look-at target 18.
    let stage = try original.inserting([.init(.duplicate(of: 10)), .init(.duplicate(of: 11), parent: .inserted(0), attachment: 7)])
    #expect(stage.keys == [13, 17])
    var expected = scene([camera0, folder1(), folder6(), route8, character10(), item12, character(13, attached: [.folder(17, [])])])
    expected.copies = [13: 10, 17: 11]
    let fk: [(id: Int32, key: Int32)] = [(id: Int32(1), key: Int32(14)), (id: Int32(2), key: Int32(15))]
    let ik: [(id: Int32, key: Int32)] = [(id: Int32(3), key: Int32(16))]
    expected.fk[13] = fk; expected.ik[13] = ik; expected.lookAt[13] = 18
    #expect(stage.document.preservedData == expected.data)
    let copy = try #require(stage.document.snapshot.roots.last?.character)
    #expect(copy.cardData == original.snapshot.roots[4].character?.cardData)
    // A duplicate of an accessory child stays in its group (OCIChar.OnLoadAttach).
    let attached = try original.inserting([.init(.duplicate(of: 11), parent: .source(10), attachment: 7)])
    var attachedExpected = scene([camera0, folder1(), folder6(), route8, character10([.folder(11, []), .folder(13, [])]), item12])
    attachedExpected.copies = [13: 11]
    #expect(attached.document.preservedData == attachedExpected.data)
}

@Test func sourceSceneInsertionWritesNewFoldersCamerasAndLights() throws {
    let original = try decoded(scene())
    // AddObjectFolder/Camera/Light defaults: zero placement, unit scale,
    // closed, visible; a new camera inactive; OILightInfo's constructor values.
    let placed: [Float] = [1, 2, -3, 10, 20, 30, 1, 1, 1]
    let header = SourceSceneInsertion.Header(transform: amount(placed), treeState: 0, visible: false)
    let light = SourceSceneNewLight(no: 1)
    let stage = try original.inserting([.init(.folder(name: "フォルダー")),
                                        .init(.camera(name: "カメラ0", header: header), parent: .inserted(0)),
                                        .init(.light(light), parent: .source(6))])
    #expect(stage.keys == [13, 14, 15])
    var expected = scene([camera0, folder1(), folder6([.item(7, []), .light(15)]), route8, character10(), item12,
                          .folder(13, [.camera(14, active: false)])])
    expected.names = [13: "フォルダー", 14: "カメラ0"]
    expected.transforms = [13: identity, 14: placed, 15: identity]
    expected.treeStates[14] = 0; expected.hidden = [14]
    expected.lights[15] = light
    #expect(stage.document.preservedData == expected.data)
    let added = try #require(stage.document.snapshot.roots[2].children.last?.light)
    #expect(added == KoikatsuLightRecord(no: 1, color: .one, intensity: 1, range: 10, spotAngle: 30, shadow: true, enable: true, drawTarget: true))
    #expect(SourceStudioCameraObjects.activeAtLoad(stage.document.snapshot) == 2, "a new camera is written inactive")
}

@Test func sourceSceneInsertionCombinesWithLeafEditsDeletionsAndMoves() throws {
    let original = try decoded(scene())
    // Duplicate folder 6 with item 7, delete the original folder, move root
    // item 12 into the copy, and move and rename the copy: one plan.
    let moved: [Float] = [4, 5, 6, 0, 90, 0, 1, 1, 1]
    let edits = SourceSceneEdits(transforms: [.init(.object(13), transform: amount(moved))], names: [13: "Copy"],
                                 deletions: [6], reparents: [.init(object: 12, parent: 13)],
                                 insertions: [.init(.duplicate(of: 6)), .init(.duplicate(of: 7), parent: .inserted(0))])
    let result = try original.editedData(edits)
    var expected = scene([camera0, folder1(), route8, character10(), .folder(13, [.item(14, []), item12])])
    expected.copies = [13: 6, 14: 7]; expected.names[13] = "Copy"; expected.transforms[13] = moved
    #expect(result == expected.data)
    // An edit can address the copy's sub-infos by its key too: the copied
    // character's FK bone 1 and its look-at target.
    let posed = try original.editedData(.init(transforms: [.init(.characterFK(object: 13, bone: 1), transform: amount(moved)),
                                                           .init(.lookAt(object: 13), transform: amount(moved))],
                                              insertions: [.init(.duplicate(of: 10))]))
    let copy = try #require(KoikatsuSceneReader.decodeDocument(posed).snapshot.roots.last?.character)
    #expect(copy.bones[1]?.transform == amount(moved) && copy.bones[1]?.sourceKey == 14 && copy.lookAtTarget.transform == amount(moved))
    #expect(copy.lookAtTarget.sourceKey == 17 && copy.accessoryChildren[7]?.isEmpty == true)
}

@Test func sourceSceneInsertionEditThenRevertReturnsTheOriginalBytes() throws {
    let source = scene(), original = try decoded(source)
    // Copy folder 6 with item 7 (13, 14) and add a folder into folder 1
    // (15); deleting what was added restores every list count and byte.
    let added = try KoikatsuSceneReader.decodeDocument(original.editedData(.init(insertions: [
        .init(.duplicate(of: 6)), .init(.duplicate(of: 7), parent: .inserted(0)), .init(.folder(name: "New"), parent: .source(1))])))
    #expect(added.preservedData != source.data)
    #expect(try added.editedData(.init(deletions: [13, 15])) == source.data)
    // A character copy with its accessory child goes with the character.
    let character = try KoikatsuSceneReader.decodeDocument(original.editedData(.init(insertions: [
        .init(.duplicate(of: 10)), .init(.duplicate(of: 11), parent: .inserted(0), attachment: 7)])))
    #expect(try character.editedData(.init(deletions: [13])) == source.data)
    #expect(try original.inserting([]).document.preservedData == source.data)
}

@Test func sourceSceneInsertionAllocatesTheSmallestFreeKeysAcrossSubInfos() throws {
    // Keys 0 and 5 are records; 1 and 2 a character's FK bone and look-at
    // target, so new keys skip them: 3, 4, then 6.
    var gaps = TopologyScene(roots: [.folder(0, []), character(5, attached: [])])
    let fk: [(id: Int32, key: Int32)] = [(id: Int32(9), key: Int32(1))]
    gaps.fk[5] = fk; gaps.lookAt[5] = 2
    let original = try decoded(gaps)
    let stage = try original.inserting([.init(.folder(name: "a")), .init(.folder(name: "b")), .init(.folder(name: "c"))])
    #expect(stage.keys == [3, 4, 6])
    // A key deleted in the same export stays used: allocation reads the
    // source scene, so the new folder is 3, not the deleted folder's 0.
    let reused = try KoikatsuSceneReader.decodeDocument(original.editedData(.init(deletions: [0], insertions: [.init(.folder(name: "a"))])))
    #expect(reused.snapshot.roots.map(\.sourceKey) == [Int32(5), 3])
    let keys = SourceSceneInsertionPlan.usedKeys(stage.document.snapshot)
    #expect(Set(keys).count == keys.count && Set(keys) == Set<Int32>([0, 1, 2, 3, 4, 5, 6]))
}

@Test func sourceSceneInsertionPluginTrailerRules() throws {
    // ST-T03i: an entry without a rule refuses copies and new records alike
    // (its plug-in may save data for every object, or address objects by
    // position). Staging still succeeds: the export refuses.
    let plugins = TopologyScene.kkex(OriginalCardFixture.map([("example.scene", .integer(7))]))
    let original = try decoded(scene(trailer: plugins))
    #expect(try original.inserting([.init(.duplicate(of: 12))]).keys == [13])
    #expect(reason { try original.editedData(.init(insertions: [.init(.duplicate(of: 12))])) }
        .contains("cannot duplicate objects in this scene: plug-in data 'example.scene'"))
    #expect(reason { try original.editedData(.init(insertions: [.init(.folder(name: "New"))])) }
        .contains("cannot add objects in this scene: plug-in data 'example.scene'"))
    // Scene-global data names no object: a new folder keeps the trailer
    // byte for byte.
    let global = TopologyScene.kkex(OriginalCardFixture.map([("com.deathweasel.bepinex.studioscenesettings",
                                                               OriginalCardFixture.plugin(0, data: OriginalCardFixture.map([("NearClipPlane", .float(0.1))])))]))
    let added = try decoded(scene(trailer: global)).editedData(.init(insertions: [.init(.folder(name: "New"))]))
    var expected = scene([camera0, folder1(), folder6(), route8, character10(), item12, .folder(13, [])], trailer: global)
    expected.names[13] = "New"; expected.transforms[13] = identity
    #expect(added == expected.data)
    // An empty KKEx block does not block duplicates.
    let empty = try decoded(scene(trailer: TopologyScene.kkex(.null)))
    #expect(try empty.inserting([.init(.duplicate(of: 12))]).keys == [13])
}

@Test func sourceSceneInsertionRefusesUnsupportedCasesAtomically() throws {
    let original = try decoded(scene())
    let cases: [([SourceSceneInsertion], String)] = [
        ([.init(.duplicate(of: 99))], "cannot duplicate unknown source object 99"),
        // Route 8 has no points here (see SourceSceneRouteEditTests for routes with points).
        ([.init(.duplicate(of: 8))], "it has no points"),
        ([.init(.duplicate(of: 9))], "keeps a copy of a route child"),
        ([.init(.duplicate(of: 9), parent: .source(1))], "keeps a copy of a route child"),
        ([.init(.folder(name: "x"), parent: .source(8))], "inside a route's subtree"),
        ([.init(.folder(name: "x"), parent: .source(9))], "inside a route's subtree"),
        ([.init(.folder(name: "x"), parent: .source(99))], "under unknown source object 99"),
        ([.init(.folder(name: "x"), parent: .source(12))], "under items"),
        ([.init(.duplicate(of: 7), parent: .source(12))], "under items"),
        ([.init(.folder(name: "x"), parent: .source(10), attachment: 7)], "accessory points"),
        ([.init(.duplicate(of: 11), parent: .source(10), attachment: 0)], "accessory points"),
        ([.init(.duplicate(of: 12), parent: .source(10), attachment: 7)], "accessory points"),
        ([.init(.folder(name: "x"), parent: .source(0))], "cannot hold children"),
        ([.init(.folder(name: "x"), parent: .source(5))], "cannot hold children"),
        ([.init(.camera(name: "c")), .init(.folder(name: "x"), parent: .inserted(0))], "cannot hold children"),
        ([.init(.folder(name: "x"), parent: .source(1), attachment: 7)], "Only a character's children name an accessory point"),
        ([.init(.folder(name: "x"), parent: .inserted(0))], "list parents before their children"),
        ([.init(.duplicate(of: 10)), .init(.duplicate(of: 11), parent: .inserted(0), attachment: 3)], "accessory points"),
        ([.init(.light(.init(no: 3)))], "catalog number must be 0"),
        ([.init(.light(.init(no: 0, range: 0)))], "positive range"),
        ([.init(.light(.init(no: 0, intensity: .nan)))], "nonnegative intensity"),
        ([.init(.folder(name: "x", header: .init(transform: amount([.infinity, 0, 0, 0, 0, 0, 1, 1, 1]))))], "nonfinite"),
        ([.init(.folder(name: "x", header: .init(treeState: 2)))], "tree state"),
    ]
    for (insertions, expected) in cases {
        let text = reason { try original.editedData(.init(insertions: insertions)) }
        #expect(text.contains(expected), "\(expected): \(text)")
    }
    // At most two lights: the scene has one, so a second is fine, a third
    // is refused, and deleting the original light makes room again.
    let two: [SourceSceneInsertion] = [.init(.light(.init(no: 0))), .init(.light(.init(no: 2)))]
    #expect(reason { try original.editedData(.init(insertions: [.init(.light(.init(no: 0)))])) } == "accepted")
    #expect(reason { try original.editedData(.init(insertions: two)) }.contains("at most two lights"))
    #expect(reason { try original.editedData(.init(insertions: [.init(.duplicate(of: 5)), .init(.duplicate(of: 5))])) }.contains("at most two lights"))
    #expect(reason { try original.editedData(.init(deletions: [5], insertions: two)) } == "accepted")
    // A leaf edit of a key nobody holds has no destination.
    #expect(reason { try original.editedData(.init(visibility: [14: false], insertions: [.init(.folder(name: "x"))])) }.contains("other error"))
    #expect(try original.editedData(.init()) == scene().data, "refusals leave the source document unchanged")
}
