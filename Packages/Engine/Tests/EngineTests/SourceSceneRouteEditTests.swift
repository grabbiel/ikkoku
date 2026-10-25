import Foundation
import Testing
import simd
import Assets
import Character
import CoreMath
@testable import Studio

// ST-T11: route point and setting edits and route copies in an exported
// original scene. Each expected export is the final tree written field by
// field by `TopologyScene` (an independent serialization), never by the
// writer, and each result is also read back with the scene reader.
//
// Original tree (as `SourceSceneInsertionTests`), with route 8's points:
//   0 camera (active)              root
//   1 folder [2 camera (active), 3 item {bone arm: 105} [4 folder], 5 light]
//   6 folder [7 item]
//   8 route [9 folder] points 13/14 (start), 15/16, 17/18 (point/aid keys)
//   10 character {FK 1: 101, 2: 102; IK 3: 103; look-at 104} {point 0: [], point 7: [11 folder]}
//   12 item
// Used keys: 0...18 and 101...105, so GetNewIndex hands out 19, 20, ...
private let camera0 = TopologyNode.camera(0, active: true)
private let item12 = TopologyNode.item(12, [])
private func route8(_ children: [TopologyNode] = [.folder(9, [])]) -> TopologyNode { .route(8, children) }
private func folder1() -> TopologyNode { .folder(1, [.camera(2, active: true), .item(3, [.folder(4, [])]), .light(5)]) }
private func folder6(_ children: [TopologyNode] = [.item(7, [])]) -> TopologyNode { .folder(6, children) }
private func character10() -> TopologyNode {
    let groups: [(point: Int32, children: [TopologyNode])] = [(point: Int32(0), children: [TopologyNode]()),
                                                             (point: Int32(7), children: [TopologyNode.folder(11, [])])]
    return .character(10, groups)
}
/// Route 8's saved points: a start rotated 30° about Y, a line point with
/// easeInQuad at speed 3, and a point whose aid was never placed.
private func points8() -> [TopologyRoutePoint] {
    [TopologyRoutePoint(key: 13, position: SIMD3(0, 0, 0), rotation: SIMD3(0, 30, 0), aidKey: 14),
     TopologyRoutePoint(key: 15, position: SIMD3(1, 0, 0), speed: 3, ease: 0, aidKey: 16),
     TopologyRoutePoint(key: 17, position: SIMD3(1, 0, 2), aidKey: 18)]
}
private func scene(_ roots: [TopologyNode]? = nil, trailer: Data = Data()) -> TopologyScene {
    var scene = TopologyScene(roots: roots ?? [camera0, folder1(), folder6(), route8(), character10(), item12], trailer: trailer)
    let fk: [(id: Int32, key: Int32)] = [(id: Int32(1), key: Int32(101)), (id: Int32(2), key: Int32(102))]
    let ik: [(id: Int32, key: Int32)] = [(id: Int32(3), key: Int32(103))]
    scene.fk[10] = fk; scene.ik[10] = ik
    scene.itemBones[3] = [(name: "arm", key: Int32(105))]
    scene.routePoints[8] = points8()
    scene.routeActive[8] = true
    return scene
}
private func decoded(_ scene: TopologyScene) throws -> KoikatsuSceneDocument { try KoikatsuSceneReader.decodeDocument(scene.data) }
private func reason(_ body: () throws -> Any) -> String {
    do { _ = try body(); return "accepted" }
    catch let error as SourceSceneTopologyError { return error.errorDescription ?? "" }
    catch let error as SourceStudioRouteEditError { return error.errorDescription ?? "" }
    catch { return "other error: \(error)" }
}
private func route(_ key: Int32, in document: KoikatsuSceneDocument) -> KoikatsuRouteRecord? {
    SourceSceneInsertionPlan.records(document.snapshot).first { $0.sourceKey == key }?.route
}
private func state(_ document: KoikatsuSceneDocument, _ key: Int32 = 8) throws -> SourceStudioRouteState {
    try #require(route(key, in: document).map(SourceStudioRouteState.init(record:)))
}

@Test func sourceSceneRouteEditBuilderAndStateMatchTheReader() throws {
    let input = scene(), original = try decoded(input)
    let record = try #require(route(8, in: original))
    #expect(record.points.map(\.bone.sourceKey) == [13, 15, 17] && record.points.map(\.aid.sourceKey) == [14, 16, 18])
    #expect(record.points[1].speed == 3 && record.points[1].easeType == 0 && record.active && record.loop)
    let unchanged = SourceStudioRouteState(record: record)
    #expect(unchanged.record(authored: record) == record)
    // An unchanged state writes nothing: the export is the input, byte for byte.
    #expect(try original.editedData(.init(routes: [8: unchanged])) == input.data)
    #expect(SourceSceneInsertionPlan.usedKeys(original.snapshot).count == 24)
}

@Test func sourceSceneRouteEditMovesRotatesAndPlacesAids() throws {
    let original = try decoded(scene())
    var edit = try state(original)
    try edit.movePoint(2, to: SIMD3(1.5, 0.25, 2))
    try edit.rotateStart(to: SIMD3(0, 45, 0))
    try edit.setConnection(1, .curve)
    try edit.moveAid(1, to: SIMD3(0.5, 1, -0.5))
    let result = try original.editedData(.init(routes: [8: edit]))
    var expected = scene()
    expected.routePoints[8]![2].position = SIMD3(1.5, 0.25, 2)
    expected.routePoints[8]![0].rotation = SIMD3(0, 45, 0)
    expected.routePoints[8]![1].connection = 1
    expected.routePoints[8]![1].aid = SIMD3(0.5, 1, -0.5)
    expected.routePoints[8]![1].aidInitialized = true
    #expect(result == expected.data)
    // Independent read-back of the destination.
    let back = try #require(route(8, in: KoikatsuSceneReader.decodeDocument(result)))
    #expect(back.points[2].bone.transform.position == SIMD3(1.5, 0.25, 2) && back.points[2].bone.sourceKey == 17)
    #expect(back.points[1].aid.transform.position == SIMD3(0.5, 1, -0.5) && back.points[1].aidInitialized && back.points[1].connection == 1)
    // Editing back to the saved values returns the original bytes.
    var revert = edit
    try revert.movePoint(2, to: SIMD3(1, 0, 2)); try revert.rotateStart(to: SIMD3(0, 30, 0))
    try revert.setConnection(1, .line)
    revert.points[1].aidPosition = SIMD3(1, 1, 1); revert.points[1].aidInitialized = false
    #expect(try original.editedData(.init(routes: [8: revert])) == scene().data)
}

@Test func sourceSceneRouteEditAddsAndDeletesPointsWithCharaStudioKeys() throws {
    let original = try decoded(scene())
    var edit = try state(original)
    // AddPoint appends at the last point's local position with the
    // OIRoutePointInfo defaults; its point and aid take the two smallest
    // free keys (19, 20). Deleting point 1 drops its point and aid records.
    #expect(try edit.addPoint() == 3)
    try edit.movePoint(3, to: SIMD3(0, 0, 2))
    try edit.deletePoint(1)
    let result = try original.editedData(.init(routes: [8: edit]))
    var expected = scene()
    expected.routePoints[8] = [points8()[0], points8()[2], TopologyRoutePoint(key: 19, position: SIMD3(0, 0, 2), aidKey: 20)]
    #expect(result == expected.data)
    let back = try #require(route(8, in: KoikatsuSceneReader.decodeDocument(result)))
    #expect(back.points.map(\.bone.sourceKey) == [13, 17, 19] && back.points.map(\.aid.sourceKey) == [14, 18, 20])
    #expect(back.points[2].speed == 2 && back.points[2].easeType == 21 && back.points[2].aid.transform.position == SIMD3(1, 1, 1))
    // A deleted point's keys are not reused in the same export, and an added
    // point allocates after every insertion of the export.
    var again = try state(original)
    try again.deletePoint(2); _ = try again.addPoint()
    let staged = try decoded(scene()).inserting([.init(.folder(name: "New"))])
    #expect(staged.keys == [19])
    let combined = try staged.editedData(.init(routes: [8: again]))
    let read = try #require(route(8, in: KoikatsuSceneReader.decodeDocument(combined)))
    #expect(read.points.map(\.bone.sourceKey) == [13, 15, 20] && read.points.map(\.aid.sourceKey) == [14, 16, 21])
}

@Test func sourceSceneRouteEditWritesPointAndRouteSettings() throws {
    let original = try decoded(scene())
    var edit = try state(original)
    try edit.setSpeed(0, 4.5)
    try edit.setEase(0, .easeOutBounce)
    try edit.setConnection(0, .curve)
    try edit.setConnection(1, .curve)
    try edit.setLink(1, true)
    edit.loop = false; edit.visibleLine = false
    edit.setOrientation(.y)
    try edit.setColor(red: 0.5, green: 0.25, blue: 1)
    let result = try original.editedData(.init(routes: [8: edit]))
    // InitAidPos: the point-local midpoint to the next point. Point 0 is
    // rotated 30° about Y, so the route-local midpoint (0.5, 0, 0) maps to
    // (cos 30°·0.5, 0, sin 30°·0.5) in its frame; point 1's is (0, 0, 1).
    let aid0 = SourceStudioRouteState.inversePointTransform(edit.points[0], SIMD3(0.5, 0, 0))
    #expect(abs(aid0.x - 0.4330127) < 1e-6 && abs(aid0.y) < 1e-7 && abs(aid0.z - 0.25) < 1e-6)
    #expect(edit.points[0].aidPosition == aid0 && edit.points[1].aidPosition == SIMD3(0, 0, 1))
    var expected = scene()
    expected.routePoints[8]![0].speed = 4.5; expected.routePoints[8]![0].ease = 24
    expected.routePoints[8]![0].connection = 1; expected.routePoints[8]![0].aid = aid0; expected.routePoints[8]![0].aidInitialized = true
    expected.routePoints[8]![1].connection = 1; expected.routePoints[8]![1].aid = SIMD3(0, 0, 1)
    expected.routePoints[8]![1].aidInitialized = true; expected.routePoints[8]![1].linked = true
    expected.routeLoop[8] = false; expected.routeLine[8] = false; expected.routeOrientation[8] = 2
    expected.routeColor[8] = #"{"r":0.5,"g":0.25,"b":1.0,"a":1.0}"#
    #expect(result == expected.data)
    let back = try #require(route(8, in: KoikatsuSceneReader.decodeDocument(result)))
    #expect(!back.loop && !back.visibleLine && back.orientation == 2 && back.color == SIMD4(0.5, 0.25, 1, 1) && back.active)
    // The linked curve point after a curve point has its speed and ease
    // greyed out (MPRoutePointCtrl.UpdateInteractable).
    #expect(edit.speedAndEaseLocked(at: 1) && !edit.speedAndEaseLocked(at: 0) && !edit.speedAndEaseLocked(at: 2))
    // A colour that does not round-trip a short decimal still reads back exactly.
    var odd = try state(original); try odd.setColor(red: 0.11724184, green: 0.39215678, blue: 0.501960814)
    let oddBack = try #require(route(8, in: KoikatsuSceneReader.decodeDocument(original.editedData(.init(routes: [8: odd])))))
    #expect(oddBack.color == odd.color)
}

@Test func sourceSceneRouteEditCombinesWithTopologyInsertionAndLeafEdits() throws {
    let original = try decoded(scene())
    var edit = try state(original)
    _ = try edit.addPoint(); try edit.movePoint(1, to: SIMD3(2, 0, 0))
    // One export: a copied folder (key 19), the route's child deleted, the
    // route renamed and stopped, and the route's points edited (the added
    // point takes 20/21, after the insertion).
    let staged = try original.inserting([.init(.duplicate(of: 6)), .init(.duplicate(of: 7), parent: .inserted(0))])
    #expect(staged.keys == [19, 20])
    let result = try staged.editedData(.init(names: [8: "Edited"], routeActive: [8: false], deletions: [9], routes: [8: edit]))
    var expected = scene([camera0, folder1(), folder6(), route8([]), character10(), item12, .folder(19, [.item(20, [])])])
    expected.copies = [19: 6, 20: 7]; expected.names[8] = "Edited"; expected.routeActive[8] = false
    expected.routePoints[8]![1].position = SIMD3(2, 0, 0)
    expected.routePoints[8]!.append(TopologyRoutePoint(key: 21, position: SIMD3(1, 0, 2), aidKey: 22))
    #expect(result == expected.data)
}

@Test func sourceSceneRouteEditDuplicatesRoutesWithTheirChildrenAndPoints() throws {
    let original = try decoded(scene())
    // Studio.Duplicate of route 8: the copy (19) and its child's copy (20)
    // take the first free keys, then its points and aids (21...26) load with
    // _import: false after the children (SetNewIndex finds 13...18 taken).
    let copy: [SourceSceneInsertion] = [.init(.duplicate(of: 8)), .init(.duplicate(of: 9), parent: .inserted(0))]
    let stage = try original.inserting(copy)
    #expect(stage.keys == [19, 20])
    var expected = scene([camera0, folder1(), folder6(), route8(), character10(), item12, .route(19, [.folder(20, [])])])
    expected.copies = [19: 8, 20: 9]; expected.routeActive[19] = true
    expected.routePoints[19] = points8().enumerated().map { index, point in
        var point = point; point.key = Int32(21 + 2 * index); point.aidKey = Int32(22 + 2 * index); return point
    }
    #expect(try stage.editedData(.init()) == expected.data)
    // The copy's own edits address its staged key: stopped, one point
    // added (27/28, after every insertion), its second point moved.
    var edit = try state(stage.document, 19)
    _ = try edit.addPoint(); try edit.movePoint(1, to: SIMD3(1, 1, 0))
    let edited = try stage.editedData(.init(routeActive: [19: false], routes: [19: edit]))
    expected.routeActive[19] = false
    expected.routePoints[19]![1].position = SIMD3(1, 1, 0)
    expected.routePoints[19]!.append(TopologyRoutePoint(key: 27, position: SIMD3(1, 0, 2), aidKey: 28))
    #expect(edited == expected.data)
    // A route child duplicated beside its original stays in the route's
    // child list with its local placement (OCIRoute.OnLoadAttach).
    let child = try original.editedData(.init(insertions: [.init(.duplicate(of: 9), parent: .source(8))]))
    var beside = scene([camera0, folder1(), folder6(), route8([.folder(9, []), .folder(19, [])]), character10(), item12])
    beside.copies = [19: 9]
    #expect(child == beside.data)
}

@Test func sourceStudioRouteStateFollowsTheGuideAndPanelRules() throws {
    let original = try decoded(scene())
    var edit = try state(original)
    #expect(reason { try edit.movePoint(0, to: .one) }.contains("only rotates"))
    #expect(reason { try edit.deletePoint(0) }.contains("cannot be deleted"))
    #expect(reason { try edit.moveAid(1, to: .one) }.contains("curve"))
    #expect(reason { try edit.setEase(1, .easeOutCubic) }.contains("ease list"))
    #expect(reason { try edit.setColor(red: 2, green: 0, blue: 0) }.contains("between 0 and 1"))
    try edit.setSpeed(1, 1000); #expect(edit.points[1].speed == SourceStudioRouteState.speedRange.upperBound)
    for _ in 0..<8 { _ = try edit.addPoint() }
    #expect(edit.points.count == 11)
    #expect(reason { try edit.addPoint() }.contains("already has 11"))
    #expect(SourceStudioRouteState.Setting.addPoint.lockedWhilePlaying && SourceStudioRouteState.Setting.speed.lockedWhilePlaying)
    #expect(!SourceStudioRouteState.Setting.move.lockedWhilePlaying && !SourceStudioRouteState.Setting.visibleLine.lockedWhilePlaying)
    // The recovered InitAidPos on the route-scene capture: IKKOKU-B point 12
    // at (-0.4, 0.55, 0.3) rotated -15° about Y (the live rotation), next
    // point (-0.7, 0.5, -0.9) -> aid local (-0.3001803, -0.025, -0.5407326).
    let point = SourceStudioRouteState.Point(sourceIndex: nil, position: SIMD3(-0.4, 0.55, 0.3), rotationDegrees: SIMD3(0, -15, 0),
        scale: .one, speed: 2, easeType: 21, connection: 1, aidPosition: .one, aidRotationDegrees: .zero, aidScale: .one,
        aidInitialized: false, linked: false)
    let aid = SourceStudioRouteState.inversePointTransform(point, (point.position + SIMD3(-0.7, 0.5, -0.9)) * 0.5)
    #expect(abs(aid.x + 0.3001803) < 1e-6 && abs(aid.y + 0.025) < 1e-6 && abs(aid.z + 0.5407326) < 1e-6)
    // The editor line follows the playback path: a line route's segments.
    let line = try SourceStudioRoute(record: #require(route(8, in: original))).polyline()
    #expect(line.count == 6 && line[0] == SIMD3(0, 0, 0) && line[1] == SIMD3(1, 0, 0) && line[5] == SIMD3(0, 0, 0))
}

@Test func sourceSceneRouteEditRefusesWhatCharaStudioCannotDoAtomically() throws {
    let original = try decoded(scene())
    let saved = try state(original)
    func edited(_ change: (inout SourceStudioRouteState) -> Void) -> SourceStudioRouteState { var s = saved; change(&s); return s }
    let cases: [(SourceSceneEdits, String)] = [
        (.init(routes: [8: edited { $0.points[0].position = .one }]), "start point only rotates"),
        (.init(routes: [8: edited { $0.points[1].rotationDegrees = SIMD3(0, 10, 0) }]), "only moves"),
        (.init(routes: [8: edited { $0.points[2].scale = SIMD3(2, 2, 2) }]), "do not scale"),
        (.init(routes: [8: edited { $0.points.remove(at: 0) }]), "start point first"),
        (.init(routes: [8: edited { $0.points.swapAt(1, 2) }]), "only appends points"),
        (.init(routes: [8: edited { s in
            let added = s.points[1]; s.points.insert(.init(sourceIndex: nil, position: .zero, rotationDegrees: .zero, scale: .one,
                speed: 2, easeType: 21, connection: 0, aidPosition: .one, aidRotationDegrees: .zero, aidScale: .one,
                aidInitialized: false, linked: false), at: 1); _ = added }]), "only appends points"),
        (.init(routes: [8: edited { s in for _ in 0..<9 { _ = try? s.addPoint() }; s.points.append(s.points[3]) }]), "past 11"),
        (.init(routes: [8: edited { $0.points[1].easeType = 4 }]), "ease list"),
        (.init(routes: [8: edited { $0.points[1].speed = 0 }]), "outside the speed control"),
        (.init(routes: [8: edited { $0.points[1].connection = 1 }]), "needs its aid placed"),
        (.init(routes: [8: edited { $0.points[2].aidPosition = .zero }]), "never placed keeps its saved position"),
        (.init(routes: [8: edited { $0.color.w = 0.5 }]), "keeps the alpha"),
        (.init(routes: [8: edited { $0.orientation = 3 }]), "not None, XY or Y"),
        (.init(routes: [8: edited { $0.points[1].aidRotationDegrees = .one }]), "aid only moves"),
        (.init(routes: [6: saved]), "no such route record"),
        (.init(deletions: [8], routes: [8: saved]), "targets deleted source object 8"),
    ]
    for (edits, expected) in cases {
        let text = reason { try original.editedData(edits) }
        #expect(text.contains(expected), "\(expected): \(text)")
    }
    // Copies inside a route's subtree stay in their route; nothing new goes in.
    let insertions: [([SourceSceneInsertion], String)] = [
        ([.init(.duplicate(of: 9))], "keeps a copy of a route child"),
        ([.init(.duplicate(of: 8)), .init(.duplicate(of: 9), parent: .source(1))], "keeps a copy of a route child"),
        ([.init(.duplicate(of: 8)), .init(.folder(name: "x"), parent: .inserted(0))], "inside a route's subtree"),
        ([.init(.duplicate(of: 8)), .init(.duplicate(of: 9), parent: .inserted(0)), .init(.folder(name: "x"), parent: .inserted(1))],
         "inside a route's subtree"),
        ([.init(.duplicate(of: 8)), .init(.duplicate(of: 7), parent: .inserted(0))], "under routes"),
    ]
    for (list, expected) in insertions {
        let text = reason { try original.editedData(.init(insertions: list)) }
        #expect(text.contains(expected), "\(expected): \(text)")
    }
    // Plug-ins key data by object: adding or deleting route points (keyed
    // OCIRoutePoint objects) is refused with plug-in entries, moves are not.
    let plugins = try decoded(scene(trailer: TopologyScene.kkex(OriginalCardFixture.map([("example.scene", .integer(7))]))))
    var added = saved; _ = try added.addPoint()
    var deleted = saved; try deleted.deletePoint(1)
    var moved = saved; try moved.movePoint(1, to: SIMD3(0, 2, 0))
    #expect(reason { try plugins.editedData(.init(routes: [8: added])) }.contains("plug-in (ExtendedSave) data"))
    #expect(reason { try plugins.editedData(.init(routes: [8: deleted])) }.contains("plug-in (ExtendedSave) data"))
    #expect(reason { try plugins.editedData(.init(routes: [8: moved])) } == "accepted")
}

/// The editor's route line is the playback path: a line segment's two
/// points, a curve segment sampled between them, and no line below two
/// points (`OCIRoute.UpdateLine` deletes it there).
@Test func sourceStudioRoutePathLinesFollowThePlaybackSegments() throws {
    let record = try #require(route(8, in: try decoded(scene())))
    let unity = record.points.map(\.bone.transform.position)
    let identity = matrix_identity_float4x4
    let lines = SourceStudioRoutePlayback.pathLines(route: record, routeWorld: identity, pointLocals: [])
    let expected = [0, 1, 1, 2, 2, 0].map { UnityCoordinates.position(unity[$0]) } // looping: 2 -> 0 closes it
    #expect(lines.count == expected.count)
    #expect(zip(lines, expected).allSatisfy { simd_distance($0, $1) < 1e-5 })
    var edit = SourceStudioRouteState(record: record)
    try edit.setConnection(1, .curve)
    let curved = SourceStudioRoutePlayback.pathLines(route: edit.record(authored: record), routeWorld: identity, pointLocals: [])
    #expect(curved.count > lines.count)
    #expect(simd_distance(curved[2], UnityCoordinates.position(unity[1])) < 1e-5)
    #expect(simd_distance(curved[curved.count - 3], UnityCoordinates.position(unity[2])) < 1e-5)
    var raised = identity; raised.columns.3 = SIMD4<Float>(0, 2, 0, 1)
    let moved = SourceStudioRoutePlayback.pathLines(route: record, routeWorld: raised, pointLocals: [])
    #expect(zip(moved, lines).allSatisfy { simd_distance($0, $1 + SIMD3<Float>(0, 2, 0)) < 1e-5 })
    try edit.deletePoint(2); try edit.deletePoint(1)
    #expect(SourceStudioRoutePlayback.pathLines(route: edit.record(authored: record), routeWorld: identity, pointLocals: []).isEmpty)
}
