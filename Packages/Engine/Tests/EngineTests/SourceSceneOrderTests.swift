import Foundation
import Testing
import Assets
import Character
@testable import Studio

// #278: ordered exports. Each case is a row of the original-player oracle
// (Tools/reverse/fixtures/OriginalPluginRewriteProbe.cs `OrderedCases`) on a
// scene laid out like that probe's phase A fixture, and each expected export
// is the final tree written field by field by `TopologyScene`, never by the
// writer:
//
//   F 0 folder [M2 3, V2 4]   V1 1 [M4 6]   M1 2   M3 5        (M, V: items)
//   R 7 route: points 8, 10, 12 with aids 9, 11, 13   C 14 camera   L 15 light
//
// Keys 0...15 are used, so CharaStudio's next key is 16. Phase C's fixture
// adds character W 16 (FK bones 17 and 18, IK target 19, look-at 20).

private let folderF = TopologyNode.folder(0, [.item(3, []), .item(4, [])])
private func v1(_ children: [TopologyNode] = [.item(6, [])]) -> TopologyNode { .item(1, children) }
private let m1 = TopologyNode.item(2, []), m3 = TopologyNode.item(5, [])
private let routeR = TopologyNode.route(7, []), cameraC = TopologyNode.camera(14, active: true), lightL = TopologyNode.light(15)
private func w(_ key: Int32 = 16, attached: [TopologyNode] = []) -> TopologyNode {
    let groups: [(point: Int32, children: [TopologyNode])] = [(point: Int32(0), children: [TopologyNode]()),
                                                             (point: Int32(7), children: attached)]
    return .character(key, groups)
}
private let rootsA: [TopologyNode] = [folderF, v1(), m1, m3, routeR, cameraC, lightL]
private let identity: [Float] = [0, 0, 0, 0, 0, 0, 1, 1, 1]

private func bones(_ pairs: [(Int32, Int32)]) -> [(id: Int32, key: Int32)] { pairs.map { (id: $0.0, key: $0.1) } }

/// The fixture with `roots` (phase A's by default), R's points and W's sub-infos.
private func fixture(_ roots: [TopologyNode] = rootsA) -> TopologyScene {
    var scene = TopologyScene(roots: roots)
    scene.routePoints[7] = [Int32(8), 10, 12].map { TopologyRoutePoint(key: $0, position: SIMD3(Float($0), 0, 1), aidKey: $0 + 1) }
    scene.fk[16] = bones([(1, 17), (2, 18)]); scene.ik[16] = bones([(3, 19)]); scene.lookAt[16] = 20
    return scene
}
private func expected(_ roots: [TopologyNode], copies: [Int32: Int32], _ change: (inout TopologyScene) -> Void = { _ in }) -> Data {
    var scene = fixture(roots); scene.copies = copies; change(&scene); return scene.data
}
/// `insertions` staged on `scene`, then exported with `deletions` and `order`.
private func export(_ scene: TopologyScene, _ insertions: [SourceSceneInsertion], deletions: Set<Int32>,
                    order: [SourceSceneInsertion.Step]?, _ change: (inout SourceSceneEdits) -> Void = { _ in }) throws -> Data {
    let stage = try KoikatsuSceneReader.decodeDocument(scene.data).inserting(insertions)
    var edits = SourceSceneEdits(deletions: deletions); edits.order = order; change(&edits)
    return try stage.editedData(edits)
}
private func reason(_ body: () throws -> Any) -> String {
    do { _ = try body(); return "accepted" }
    catch let error as SourceSceneTopologyError { return error.errorDescription ?? "" }
    catch { return "other error: \(error)" }
}
private let duplicateM3 = [SourceSceneInsertion(.duplicate(of: 5))]

@Test func sourceSceneOrderReplaysTheOracleOperationOrders() throws {
    let a = fixture()
    // delete-duplicate: deleting V1 frees keys 1 and 6 and root slot 1, so
    // the copy is 1, in V1's place.
    let deleteDuplicate = try export(a, duplicateM3, deletions: [1], order: [.delete(1), .insert([0])])
    #expect(deleteDuplicate == expected([folderF, .item(1, []), m1, m3, routeR, cameraC, lightL], copies: [1: 5]))
    // Negative control: the set-based copy is 16, appended, which is what
    // duplicate-delete gives, where the key is taken before any is freed.
    let duplicateFirst = expected([folderF, m1, m3, routeR, cameraC, lightL, .item(16, [])], copies: [16: 5])
    #expect(try export(a, duplicateM3, deletions: [1], order: nil) == duplicateFirst)
    #expect(try export(a, duplicateM3, deletions: [1], order: [.insert([0]), .delete(1)]) == duplicateFirst)
    #expect(deleteDuplicate != duplicateFirst)
    // delete-delete-duplicate: R frees 7 and its point keys 8, 10 and 12,
    // not its aids (OIRoutePointInfo.cs:84), then its slot after V1's. The
    // copy takes the smallest free key, 1, and the last freed slot, R's.
    #expect(try export(a, duplicateM3, deletions: [1, 7], order: [.delete(1), .delete(7), .insert([0])])
            == expected([folderF, m1, m3, .item(1, []), cameraC, lightL], copies: [1: 5]))
    // Negative control: deleted the other way round, V1's slot is the last freed.
    #expect(try export(a, duplicateM3, deletions: [1, 7], order: [.delete(7), .delete(1), .insert([0])])
            == expected([folderF, .item(1, []), m1, m3, cameraC, lightL], copies: [1: 5]))
    // child-delete-duplicate: M4 frees key 6 but no root slot.
    #expect(try export(a, duplicateM3, deletions: [6], order: [.delete(6), .insert([0])])
            == expected([folderF, v1([]), m1, m3, routeR, cameraC, lightL, .item(6, [])], copies: [6: 5]))
    // route-delete-duplicate-folder: F's copy takes 7, its children 8 and
    // 10 (9 is R's first aid, still taken), and R's slot.
    let subtree = [SourceSceneInsertion(.duplicate(of: 0)), .init(.duplicate(of: 3), parent: .inserted(0)),
                   .init(.duplicate(of: 4), parent: .inserted(0))]
    #expect(try export(a, subtree, deletions: [7], order: [.delete(7), .insert([0, 1, 2])])
            == expected([folderF, v1(), m1, m3, .folder(7, [.item(8, []), .item(10, [])]), cameraC, lightL], copies: [7: 0, 8: 3, 10: 4]))
    #expect(try export(a, subtree, deletions: [7], order: nil)
            == expected([folderF, v1(), m1, m3, cameraC, lightL, .folder(16, [.item(17, []), .item(18, [])])], copies: [16: 0, 17: 3, 18: 4]))
    // delete-duplicate-duplicate: M3's copy takes 1 and slot 1; M1's then 6, appended.
    let twoCopies = [SourceSceneInsertion(.duplicate(of: 5)), .init(.duplicate(of: 2))]
    #expect(try export(a, twoCopies, deletions: [1], order: [.delete(1), .insert([0]), .insert([1])])
            == expected([folderF, .item(1, []), m1, m3, routeR, cameraC, lightL, .item(6, [])], copies: [1: 5, 6: 2]))
    #expect(try export(a, twoCopies, deletions: [1], order: nil)
            == expected([folderF, m1, m3, routeR, cameraC, lightL, .item(16, []), .item(17, [])], copies: [16: 5, 17: 2]))
    // delete-add-folder: a new folder takes the freed key and slot like a copy.
    #expect(try export(a, [.init(.folder(name: "New"))], deletions: [1], order: [.delete(1), .insert([0])])
            == expected([folderF, .folder(1, []), m1, m3, routeR, cameraC, lightL], copies: [:]) {
                $0.names[1] = "New"; $0.transforms[1] = identity })
}

@Test func sourceSceneOrderReplaysCharacterDeletesAndCopies() throws {
    let c = fixture(rootsA + [w()])
    // character-delete-duplicate: W frees 16 and its sub-info keys 17-20 and
    // the last slot; M3's copy is 16, there. Negative control: 21.
    #expect(try export(c, duplicateM3, deletions: [16], order: [.delete(16), .insert([0])])
            == expected(rootsA + [.item(16, [])], copies: [16: 5]))
    #expect(try export(c, duplicateM3, deletions: [16], order: nil) == expected(rootsA + [.item(21, [])], copies: [21: 5]))
    // delete-duplicate-character: W's copy takes 1, then its FK bones and IK
    // target before its children and its look-at target after them
    // (OICharInfo.Load): 6, then the next unused keys 21, 22 and 23.
    let copyW = [SourceSceneInsertion(.duplicate(of: 16))]
    #expect(try export(c, copyW, deletions: [1], order: [.delete(1), .insert([0])])
            == expected([folderF, w(1), m1, m3, routeR, cameraC, lightL, w()], copies: [1: 16]) {
                $0.fk[1] = bones([(1, 6), (2, 21)]); $0.ik[1] = bones([(3, 22)]); $0.lookAt[1] = 23 })
    #expect(try export(c, copyW, deletions: [1], order: nil)
            == expected([folderF, m1, m3, routeR, cameraC, lightL, w(), w(21)], copies: [21: 16]) {
                $0.fk[21] = bones([(1, 22), (2, 23)]); $0.ik[21] = bones([(3, 24)]); $0.lookAt[21] = 25 })
    // With an accessory child copied too, the child's key comes between the
    // IK target's and the look-at target's.
    let accessory = fixture(rootsA + [w(attached: [.folder(21, [])])])
    let copyWithChild = [SourceSceneInsertion(.duplicate(of: 16)), .init(.duplicate(of: 21), parent: .inserted(0), attachment: 7)]
    #expect(try export(accessory, copyWithChild, deletions: [1], order: [.delete(1), .insert([0, 1])])
            == expected([folderF, w(1, attached: [.folder(24, [])]), m1, m3, routeR, cameraC, lightL, w(attached: [.folder(21, [])])],
                        copies: [1: 16, 24: 21]) {
                $0.fk[1] = bones([(1, 6), (2, 22)]); $0.ik[1] = bones([(3, 23)]); $0.lookAt[1] = 25 })
}

@Test func sourceSceneOrderWithoutFreedKeysIsTheSetBasedExport() throws {
    // An order that frees nothing before it takes keys gives the set-based
    // keys and appended roots byte for byte: exports without deletes are
    // unchanged whichever path writes them.
    let a = fixture()
    let insertions = [SourceSceneInsertion(.duplicate(of: 0)), .init(.duplicate(of: 3), parent: .inserted(0)),
                      .init(.duplicate(of: 4), parent: .inserted(0)), .init(.duplicate(of: 5)), .init(.folder(name: "New"), parent: .source(0))]
    let setBased = try export(a, insertions, deletions: [], order: nil)
    #expect(try export(a, insertions, deletions: [], order: [.insert([0, 1, 2]), .insert([3]), .insert([4])]) == setBased)
    #expect(try export(a, insertions, deletions: [2], order: [.insert([0, 1, 2]), .insert([3]), .insert([4]), .delete(2)])
            == export(a, insertions, deletions: [2], order: nil))
    #expect(setBased != a.data)
}

@Test func sourceSceneOrderRefusesOrdersThatDoNotMatchTheExport() throws {
    let a = fixture()
    func refusal(_ order: [SourceSceneInsertion.Step], insertions: [SourceSceneInsertion] = duplicateM3, deletions: Set<Int32> = [1],
                 _ change: (inout SourceSceneEdits) -> Void = { _ in }) -> String {
        reason { try export(a, insertions, deletions: deletions, order: order, change) }
    }
    #expect(refusal([.delete(1), .insert([0])]) == "accepted")   // control
    #expect(refusal([.delete(99), .insert([0])]).contains("source object 99 is not there to delete"))
    #expect(refusal([.delete(1), .delete(1), .insert([0])]).contains("source object 1 is not there to delete"))
    #expect(refusal([.delete(1), .insert([0, 0])]).contains("an insertion is listed twice or not at all"))
    #expect(refusal([.delete(1), .insert([3])]).contains("an insertion is listed twice or not at all"))
    #expect(refusal([.delete(1), .insert([0]), .insert([0])]).contains("an insertion is listed twice or not at all"))
    #expect(refusal([.delete(1)]).contains("an insertion is in no step"))
    let subtree = [SourceSceneInsertion(.duplicate(of: 0)), .init(.duplicate(of: 3), parent: .inserted(0))]
    #expect(refusal([.delete(1), .insert([1]), .insert([0])], insertions: subtree).contains("insertion 1 comes before its parent"))
    #expect(refusal([.delete(0), .insert([0])], insertions: [.init(.duplicate(of: 3), parent: .source(0))], deletions: [0])
            .contains("insertion 0 goes under deleted source object 0"))
    #expect(refusal([.delete(7), .insert([0])]).contains("the replayed deletes differ from the document's"))
    #expect(refusal([.delete(1), .insert([0])]) { $0.reparents = [.init(object: 2, parent: 0)] }.contains("moves are not replayed"))
    let source = try KoikatsuSceneReader.decodeDocument(a.data)
    let route = try #require(source.snapshot.roots.first { $0.sourceKey == 7 }?.route)
    var fewer = SourceStudioRouteState(record: route); fewer.points.removeLast()
    #expect(refusal([.delete(1), .insert([0])]) { $0.routes[7] = fewer }.contains("route 7's added or deleted points are not replayed"))
    #expect(refusal([.delete(1), .insert([0])]) { $0.routes[7] = SourceStudioRouteState(record: route) } == "accepted")
    #expect(refusal([.delete(1), .insert([0])], insertions: [.init(.light(SourceSceneNewLight(no: 1)))]).contains("lights are not replayed"))
}

// MARK: - The order the export builds from the document

/// The app's import of the fixture: one object per record, an empty log.
private struct Session {
    let source: KoikatsuSceneDocument
    var document = StudioDocument()

    init(_ scene: TopologyScene = fixture()) throws {
        self.init(source: try KoikatsuSceneReader.decodeDocument(scene.data))
    }

    init(source: KoikatsuSceneDocument) {
        self.source = source
        document.sourceSceneFile = "/fixture/a.png"; document.sourceSceneSHA256 = String(repeating: "a", count: 64)
        document.sourceStructuralEdits = SourceSceneEditLog()
        func append(_ record: KoikatsuObjectRecord, parent: UUID?, point: Int32? = nil) {
            var object = StudioObject(name: record.name ?? "Source \(record.sourceKey)", kind: .folder)
            object.sourceObjectKey = record.sourceKey; object.parent = parent; object.sourceAttachmentPoint = point
            document.objects.append(object)
            for child in record.children { append(child, parent: object.id) }
            for (point, children) in (record.character?.accessoryChildren ?? [:]).sorted(by: { $0.key < $1.key }) {
                for child in children { append(child, parent: object.id, point: point) }
            }
        }
        for root in source.snapshot.roots { append(root, parent: nil) }
    }

    func id(_ key: Int32) -> UUID { document.objects.first { $0.sourceObjectKey == key }!.id }
    mutating func delete(_ key: Int32) { document.removeRecordingSourceEdit(id(key)) }
    @discardableResult mutating func duplicate(_ key: Int32, logged: Bool = true) -> UUID {
        var copy = document.objects.first { $0.sourceObjectKey == key }!
        copy.id = UUID(); copy.sourceObjectKey = nil; copy.sourceDuplicateOf = key
        document.objects.append(copy)
        if logged { document.recordSourceEdit(.insert([copy.id])) }
        return copy.id
    }
    func order() throws -> (order: SourceSceneExportValidation.Order, staged: SourceSceneExportValidation.Staged, deletions: Set<Int32>) {
        let staged = try SourceSceneExportValidation.stage(document, source: source)
        let topology = try SourceSceneExportValidation.topologyEdits(document, against: staged.stage.document.snapshot, keys: staged.keys)
        return (SourceSceneExportValidation.order(document, staged: staged, deletions: topology.deletions, reparents: topology.reparents),
                staged, topology.deletions)
    }
}

@Test func sourceSceneOrderBuildsTheReplayFromTheDocumentLog() throws {
    var session = try Session()
    session.delete(1); session.duplicate(5)
    #expect(session.document.sourceStructuralEdits?.edits.count == 2)
    let (order, staged, deletions) = try session.order()
    #expect(order == .replayed([.delete(1), .insert([0])]))
    // End to end: the export with the built steps is delete-duplicate's.
    guard case .replayed(let steps) = order else { return }
    var edits = SourceSceneEdits(deletions: deletions); edits.order = steps
    #expect(try staged.stage.editedData(edits) == expected([folderF, .item(1, []), m1, m3, routeR, cameraC, lightL], copies: [1: 5]))
    // A child deleted before its parent: the parent's delete covers it again.
    var nested = try Session()
    nested.delete(6); nested.delete(1); nested.duplicate(5)
    #expect(try nested.order().order == .replayed([.delete(6), .delete(1), .insert([0])]))
}

@Test func sourceSceneOrderNamesWhyItKeepsTheSetBasedKeys() throws {
    func outcome(_ build: (inout Session) throws -> Void) throws -> SourceSceneExportValidation.Order {
        var session = try Session(); try build(&session); return try session.order().order
    }
    // Nothing freed before a key is taken, or nothing added: the set-based
    // keys are CharaStudio's.
    #expect(try outcome { $0.duplicate(5); $0.delete(1) } == .unneeded)
    #expect(try outcome { $0.duplicate(5); $0.duplicate(2) } == .unneeded)
    #expect(try outcome { $0.delete(1) } == .unneeded)
    #expect(try outcome { _ in } == .unneeded)
    // A document saved before the log: only a delete with an addition names it.
    #expect(try outcome { $0.document.sourceStructuralEdits = nil; $0.delete(1); $0.duplicate(5) } == .fallback(.noLog))
    #expect(try outcome { $0.document.sourceStructuralEdits = nil; $0.duplicate(5) } == .unneeded)
    // An added object deleted again, with or without a source delete.
    #expect(try outcome { let copy = $0.duplicate(5); $0.duplicate(2); $0.document.removeRecordingSourceEdit(copy) } == .fallback(.addThenDelete))
    #expect(try outcome { $0.duplicate(6); $0.delete(1); $0.duplicate(5) } == .fallback(.addThenDelete))   // M4's copy went with V1
    // An addition or delete the log does not hold.
    #expect(try outcome { $0.delete(1); $0.duplicate(5); $0.duplicate(2, logged: false) } == .fallback(.mismatch))
    #expect(try outcome { $0.delete(1); $0.document.remove($0.id(2)); $0.duplicate(5) } == .fallback(.mismatch))
    #expect(try outcome { $0.delete(1); $0.duplicate(5); $0.document.recordSourceEdit(.insert([UUID()])) } == .fallback(.mismatch))
    #expect(try outcome { $0.delete(1); $0.duplicate(5); let id = $0.id(2); $0.document.objects[$0.document.objects.firstIndex { $0.id == id }!].parent = $0.id(0) }
            == .fallback(.mismatch))
    // Moves and route point edits before an addition, even without a delete.
    func move(_ session: inout Session) {
        let id = session.id(2), folder = session.id(0)
        session.document.objects[session.document.objects.firstIndex { $0.id == id }!].parent = folder
        session.document.recordSourceEdit(.unordered(.move))
    }
    #expect(try outcome { $0.delete(1); move(&$0); $0.duplicate(5) } == .fallback(.move))
    #expect(try outcome { move(&$0); $0.duplicate(5) } == .fallback(.move))
    #expect(try outcome { $0.duplicate(5); move(&$0) } == .unneeded)
    #expect(try outcome { $0.document.recordSourceEdit(.unordered(.routePoints)); $0.duplicate(5) } == .fallback(.routePoints))
    #expect(try outcome { $0.delete(1); $0.document.recordSourceEdit(.unordered(.routePoints)); $0.duplicate(5) } == .fallback(.routePoints))
    #expect(try outcome { $0.duplicate(5); $0.document.recordSourceEdit(.unordered(.routePoints)) } == .unneeded)
    // A copied light (SceneInfo.isLightCheck), and a full log.
    #expect(try outcome { $0.delete(1); $0.duplicate(15) } == .fallback(.light))
    #expect(try outcome {
        $0.delete(1); $0.duplicate(5)
        $0.document.sourceStructuralEdits = SourceSceneEditLog(Array(repeating: .unordered(.move), count: SourceSceneEditLog.capacity + 1))
    } == .fallback(.overflow))
    for reason in [SourceSceneOrderFallback.noLog, .move, .routePoints, .addThenDelete, .light, .overflow, .mismatch, .legacyBones] {
        #expect(!reason.reason.isEmpty)
    }
}

// MARK: - A legacy scene (ST-T05a)

/// #291's 0.0.7 fixture (`legacy-0.0.7-f64181bf3ded.png`): character 0 with
/// sub-info keys 1...148 and accessory item 149, lights 150 and 151, root
/// items 152...158. Every key 0...158 is taken, so the first key free at
/// load is 159. CharaStudio's load then gives the character the FK bones its
/// record lacks (10 back-hair bones, finding 2) under the smallest free
/// keys, after every saved key (Studio.cs:515–519, AddObjectAssist.cs:44,
/// :111): 159...168, which the upgrade does not hold. The expected keys and
/// roots below come from this file's records and those rules, never from
/// the writer.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_LEGACY_SCENE"]), "Requires IKKOKU_STUDIO_LEGACY_SCENE (a 0.0.7 scene)"))
func sourceSceneOrderReplaysALegacySceneOnItsUpgrade() throws {
    let legacy = try KoikatsuSceneReader.decodeDocument(Data(contentsOf: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_STUDIO_LEGACY_SCENE"))))
    let upgraded = try legacy.upgraded()
    #expect(legacy.snapshot.version == "0.0.7" && legacy.isLegacy && !upgraded.isLegacy && legacy.orphanPluginIDs.isEmpty)
    // The scene's keys, walked here: records, a character's FK bones, IK
    // targets and look-at target, an item's FK bones, route points and aids.
    var used = Set<Int32>()
    func walk(_ record: KoikatsuObjectRecord) {
        used.insert(record.sourceKey)
        if let character = record.character {
            character.bones.values.forEach { used.insert($0.sourceKey) }
            character.ikTargets.values.forEach { used.insert($0.sourceKey) }
            used.insert(character.lookAtTarget.sourceKey)
            character.accessoryChildren.values.joined().forEach(walk)
        }
        record.item?.bones.values.forEach { used.insert($0.sourceKey) }
        for point in record.route?.points ?? [] { used.insert(point.bone.sourceKey); if let aid = point.aidKey { used.insert(aid) } }
        record.children.forEach(walk)
    }
    legacy.snapshot.roots.forEach(walk)
    let firstFreeAtLoad = (Int32(0)...).first { !used.contains($0) }!
    let roots = legacy.snapshot.roots.map(\.sourceKey)
    #expect(firstFreeAtLoad == 159 && roots == [0, 150, 151, 152, 153, 154, 155, 156, 157, 158])
    let deleted = try #require(legacy.snapshot.roots.first { $0.sourceKey == 153 })
    let template = try #require(legacy.snapshot.roots.first { $0.sourceKey == 156 })
    #expect(deleted.kind == .item && template.kind == .item && deleted.children.isEmpty && template.children.isEmpty)
    #expect(deleted.item?.bones.isEmpty == true && template.item?.bones.isEmpty == true)
    #expect(deleted.item != template.item || deleted.transform != template.transform)   // the copy is visible

    // Delete 153, then duplicate 156. DeleteKey frees 153 alone; GetNewIndex
    // gives the copy the smallest free key, 153 (below 159, so no load-time
    // bone holds it); the copy's root takes the slot 153 left (slot 4).
    let expectedKey: Int32 = 153, expectedSlot = roots.firstIndex(of: 153)!
    #expect(expectedKey < firstFreeAtLoad)
    var expectedRoots = roots; expectedRoots[expectedSlot] = expectedKey
    func session(_ source: KoikatsuSceneDocument, _ build: (inout Session) -> Void) throws
        -> (order: SourceSceneExportValidation.Order, staged: SourceSceneExportValidation.Staged, deletions: Set<Int32>) {
        var session = Session(source: source); build(&session); return try session.order()
    }
    var exports: [Data] = []
    for source in [legacy, upgraded] {
        let (order, staged, deletions) = try session(source) { $0.delete(153); $0.duplicate(156) }
        #expect(order == .replayed([.delete(153), .insert([0])]))
        #expect(staged.legacyCharacters == source.isLegacy)
        guard case .replayed(let steps) = order else { continue }
        var edits = SourceSceneEdits(deletions: deletions); edits.order = steps
        exports.append(try staged.stage.editedData(edits))
        // The set-based keys append the copy as 159: the negative control.
        let setBased = try KoikatsuSceneReader.decodeDocument(staged.stage.editedData(SourceSceneEdits(deletions: deletions)))
        #expect(setBased.snapshot.roots.map(\.sourceKey) == roots.filter { $0 != 153 } + [159])
        #expect(setBased.snapshot.roots.map(\.sourceKey) != expectedRoots)
    }
    try #require(exports.count == 2)
    // The legacy export is the export of its upgrade, saved as 1.0.4.2.
    #expect(exports[0] == exports[1])
    let exported = try KoikatsuSceneReader.decodeDocument(exports[0])
    #expect(exported.snapshot.version == "1.0.4.2" && !exported.isLegacy)
    var reader = try KoikatsuBinaryReader(exports[0]); try reader.skipPNG()
    #expect(try reader.string() == "1.0.4.2")
    #expect(exported.snapshot.roots.map(\.sourceKey) == expectedRoots)
    let copy = exported.snapshot.roots[expectedSlot], upgradedTemplate = try #require(upgraded.snapshot.roots.first { $0.sourceKey == 156 })
    #expect(copy.sourceKey == expectedKey && copy.rootDictionaryKey == expectedKey)
    #expect(copy.kind == .item && copy.item == upgradedTemplate.item && copy.transform == upgradedTemplate.transform && copy.name == upgradedTemplate.name)
    // Every other root is the upgrade's own record.
    for (index, root) in exported.snapshot.roots.enumerated() where index != expectedSlot {
        #expect(root == upgraded.snapshot.roots.first { $0.sourceKey == root.sourceKey })
    }
    // The status carries the legacy note, and a replayed order adds no reason.
    let replayedStatus = SourceSceneExportValidation.exportStatus(fileName: "legacy-ordered.png", source: legacy, order: .replayed([.delete(153), .insert([0])]))
    #expect(replayedStatus == "Exported edited original scene to legacy-ordered.png, saved as 1.0.4.2 from CharaStudio 0.0.7, as CharaStudio does")

    // A second copy needs a key nothing freed: 159 here, which CharaStudio's
    // load gave a back-hair bone, so its copy would take 169. The legacy
    // export keeps the set-based keys and names why; its upgrade, a 1.0.4.2
    // scene whose records hold every bone, replays.
    let (second, secondStaged, secondDeletions) = try session(legacy) { $0.delete(153); $0.duplicate(156); $0.duplicate(157) }
    #expect(second == .fallback(.legacyBones))
    _ = try secondStaged.stage.editedData(SourceSceneEdits(deletions: secondDeletions))   // no refusal
    #expect(try session(upgraded) { $0.delete(153); $0.duplicate(156); $0.duplicate(157) }.order == .replayed([.delete(153), .insert([0]), .insert([1])]))
    // A copy of the legacy character takes its hidden bones' keys too, even
    // when its own key was freed.
    #expect(try session(legacy) { $0.delete(153); $0.duplicate(0) }.order == .fallback(.legacyBones))
    // Without a delete the set-based keys stand (the replay is not needed).
    #expect(try session(legacy) { $0.duplicate(156) }.order == .unneeded)
    // The legacy note comes first, then the reason.
    let fallbackStatus = SourceSceneExportValidation.exportStatus(fileName: "legacy-ordered.png", source: legacy, order: second)
    let note = try #require(fallbackStatus.range(of: ", saved as 1.0.4.2 from CharaStudio 0.0.7, as CharaStudio does"))
    let reason = try #require(fallbackStatus.range(of: ". Added objects took keys after the scene's own, which can differ from CharaStudio's for these edits: "
                                                    + SourceSceneOrderFallback.legacyBones.reason))
    #expect(note.upperBound <= reason.lowerBound && fallbackStatus.hasSuffix(SourceSceneOrderFallback.legacyBones.reason))
    // A current scene's status carries neither.
    #expect(SourceSceneExportValidation.exportStatus(fileName: "a.png", source: upgraded, order: .unneeded) == "Exported edited original scene to a.png")
}

// MARK: - The log

@Test func sourceSceneEditLogRecordsOnlyImportedScenes() {
    var native = StudioDocument()
    native.recordSourceEdit(.delete(sourceKey: 1))
    #expect(native.sourceStructuralEdits == nil)
    var legacy = StudioDocument(); legacy.sourceSceneSHA256 = String(repeating: "a", count: 64)
    legacy.recordSourceEdit(.delete(sourceKey: 1))
    #expect(legacy.sourceStructuralEdits == nil, "a document imported before the log keeps none")
    var imported = legacy; imported.sourceStructuralEdits = SourceSceneEditLog()
    let folder = StudioObject(name: "Folder", kind: .folder)
    var source = StudioObject(name: "Source", kind: .folder); source.sourceObjectKey = 3
    var child = StudioObject(name: "Added", kind: .folder); child.parent = source.id
    imported.objects = [folder, source, child]
    imported.removeRecordingSourceEdit(UUID())          // no such object: nothing recorded
    imported.removeRecordingSourceEdit(source.id)       // holds an added object
    imported.removeRecordingSourceEdit(folder.id)       // an added object itself
    #expect(imported.sourceStructuralEdits?.edits == [.delete(sourceKey: nil), .delete(sourceKey: nil)])
    #expect(imported.objects.isEmpty)
    var plain = legacy; plain.sourceStructuralEdits = SourceSceneEditLog(); plain.objects = [source]
    plain.removeRecordingSourceEdit(source.id)
    #expect(plain.sourceStructuralEdits?.edits == [.delete(sourceKey: 3)])
    // A recorded write applies the change, then logs it; a failed one logs nothing.
    struct Refused: Error {}
    plain.recordingSourceEdit(.insert([folder.id])) { $0.objects.append(folder) }
    #expect(plain.objects.map(\.id) == [folder.id] && plain.sourceStructuralEdits?.edits.last == .insert([folder.id]))
    #expect(throws: Refused.self) { try plain.recordingSourceEdit(.unordered(.move)) { _ in throw Refused() } }
    #expect(plain.sourceStructuralEdits?.edits.count == 2)
    native.recordingSourceEdit(.insert([folder.id])) { $0.objects.append(folder) }
    #expect(native.objects.count == 1 && native.sourceStructuralEdits == nil)
}

@Test func sourceSceneEditLogIsCappedAndDecodesLeniently() throws {
    let capacity = SourceSceneEditLog.capacity
    var log = SourceSceneEditLog()
    for _ in 0..<(capacity + 10) { log.append(.delete(sourceKey: 1)) }
    #expect(log.edits.count == capacity && log.edits.last == .unordered(.overflow))
    #expect(log.edits.dropLast().allSatisfy { $0 == .delete(sourceKey: 1) })
    #expect(SourceSceneEditLog(Array(repeating: .delete(sourceKey: 2), count: capacity + 1)).edits.last == .unordered(.overflow))
    #expect(SourceSceneEditLog(Array(repeating: .delete(sourceKey: 2), count: capacity)).edits.last == .delete(sourceKey: 2))
    // A plain array; an entry this version cannot read loads as a mismatch.
    let id = UUID()
    let edits: [SourceSceneStructuralEdit] = [.insert([id]), .delete(sourceKey: 3), .delete(sourceKey: nil), .unordered(.move)]
    let encoded = try JSONEncoder().encode(SourceSceneEditLog(edits))
    #expect(encoded == (try JSONEncoder().encode(edits)))
    #expect(try JSONDecoder().decode(SourceSceneEditLog.self, from: encoded).edits == edits)
    var text = String(decoding: encoded, as: UTF8.self)
    text.insert(contentsOf: #"{"futureEdit":{"x":1}},7,"#, at: text.index(after: text.startIndex))
    #expect(try JSONDecoder().decode(SourceSceneEditLog.self, from: Data(text.utf8)).edits
            == [.unordered(.mismatch), .unordered(.mismatch)] + edits)
    // A longer saved array is cut at the cap, its last entry the overflow.
    let long = try JSONEncoder().encode(Array(repeating: SourceSceneStructuralEdit.delete(sourceKey: 4), count: capacity + 3))
    let decoded = try JSONDecoder().decode(SourceSceneEditLog.self, from: long)
    #expect(decoded.edits.count == capacity && decoded.edits.last == .unordered(.overflow))
    #expect(throws: (any Error).self) { try JSONDecoder().decode(SourceSceneEditLog.self, from: Data(#"{"edits":[]}"#.utf8)) }
}

@Test func sourceSceneEditLogTravelsWithTheNativeSaveAndOldSavesLoad() throws {
    var document = StudioDocument()
    document.sourceSceneFile = "/fixture/a.png"; document.sourceSceneSHA256 = String(repeating: "a", count: 64)
    document.sourceStructuralEdits = SourceSceneEditLog([.delete(sourceKey: 1), .insert([UUID()])])
    let saved = try JSONEncoder().encode(document)
    #expect(try JSONDecoder().decode(StudioDocument.self, from: saved) == document)
    // A save from before the field: the key is absent, and the document loads with no log.
    var object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
    #expect(object.removeValue(forKey: "sourceStructuralEdits") != nil)
    let old = try JSONDecoder().decode(StudioDocument.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.sourceStructuralEdits == nil && old.sourceSceneSHA256 == document.sourceSceneSHA256)
}

@Test func sourceSceneFreeKeysHandOutTheSmallestFreeKey() throws {
    var keys = FreeKeys([0, 1, 2, 5])
    var taken = [try keys.take(), try keys.take()]
    keys.release(1); keys.release(4); keys.release(9)    // 9 was never taken
    taken += [try keys.take(), try keys.take(), try keys.take()]
    keys.release(0); keys.release(0)
    taken += [try keys.take(), try keys.take()]
    #expect(taken == [3, 4, 1, 4, 6, 0, 7])
}
