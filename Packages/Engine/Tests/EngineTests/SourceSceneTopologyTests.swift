import Foundation
import Testing
import Assets
import Character
@testable import Studio

/// An original 1.0.4.2 scene tree written field by field from a spec, without
/// the reader's spans: each expected export is built from its final tree, so
/// a writer result is checked against an independent serialization.
indirect enum TopologyNode {
    case folder(Int32, [TopologyNode])
    case item(Int32, [TopologyNode])
    case camera(Int32, active: Bool)
    case light(Int32)
    case route(Int32, [TopologyNode])
    case character(Int32, [(point: Int32, children: [TopologyNode])])

    var key: Int32 {
        switch self {
        case .folder(let key, _), .item(let key, _), .camera(let key, _), .light(let key),
             .route(let key, _), .character(let key, _): return key
        }
    }
}

struct TopologyScene {
    static let card = OriginalCardFixture.card()
    var roots: [TopologyNode]
    var transforms: [Int32: [Float]] = [:]
    var cameraActive: [Int32: Bool] = [:]
    var sunCaster: Int32 = -1
    var trailer = Data()
    /// Root dictionary keys that differ from the record's own key.
    var rootKeys: [Int32: Int32] = [:]
    /// A copy's template: the record whose name, transform and item number
    /// the copy carries under its own key (ST-T03 duplicates).
    var copies: [Int32: Int32] = [:]
    /// Names that differ from the "Folder 1" / "Camera 2" pattern.
    var names: [Int32: String] = [:]
    /// Character FK bones and IK targets (ID, dicKey) in byte order, and the
    /// look-at target's dicKey (104 when absent).
    var fk: [Int32: [(id: Int32, key: Int32)]] = [:]
    var ik: [Int32: [(id: Int32, key: Int32)]] = [:]
    var lookAt: [Int32: Int32] = [:]
    /// Item FK bones (name, dicKey) in byte order.
    var itemBones: [Int32: [(name: String, key: Int32)]] = [:]
    /// Light records written with these fields instead of the fixed ones.
    var lights: [Int32: SourceSceneNewLight] = [:]
    /// Headers that are not closed (tree state 1) and visible.
    var treeStates: [Int32: Int32] = [:]
    var hidden: Set<Int32> = []

    static func transform(_ key: Int32) -> [Float] {
        [Float(key), Float(key) + 0.5, -Float(key), 0, Float(key) * 3, 0, 1, 1, 1]
    }

    var data: Data {
        var out = SceneDocumentBytes(data: OriginalCardFixture.png)
        out.s("1.0.4.2"); out.i(Int32(roots.count))
        for root in roots { out.i(rootKeys[root.key] ?? root.key); write(root, &out) }
        tail(&out)
        out.data += trailer
        return out.data
    }

    private func header(_ kind: Int32, _ key: Int32, _ out: inout SceneDocumentBytes) {
        out.i(kind); out.i(key)
        for value in transforms[key] ?? Self.transform(copies[key] ?? key) { out.f(value) }
        out.i(treeStates[key] ?? 1); out.b(!hidden.contains(key))
    }
    private func name(_ prefix: String, _ key: Int32) -> String { names[key] ?? "\(prefix) \(copies[key] ?? key)" }
    private func list(_ children: [TopologyNode], _ out: inout SceneDocumentBytes) {
        out.i(Int32(children.count)); for child in children { write(child, &out) }
    }
    private func pattern(_ out: inout SceneDocumentBytes) {
        out.i(0); out.s(""); out.b(false); out.s(#"{"x":0,"y":0,"z":1,"w":1}"#); out.f(0)
    }
    private func write(_ node: TopologyNode, _ out: inout SceneDocumentBytes) {
        switch node {
        case let .folder(key, children):
            header(3, key, &out); out.s(name("Folder", key)); list(children, &out)
        case let .camera(key, active):
            header(5, key, &out); out.s(name("Camera", key)); out.b(cameraActive[key] ?? active)
        case let .light(key):
            if let light = lights[key] {
                header(2, key, &out); out.i(light.no); for index in 0..<4 { out.f(light.color[index]) }
                out.f(light.intensity); out.f(light.range); out.f(light.spotAngle)
                out.b(light.shadow); out.b(light.enable); out.b(light.drawTarget)
            } else {
                header(2, key, &out); out.i(0); for _ in 0..<4 { out.f(1) }
                out.f(1); out.f(10); out.f(30); out.b(true); out.b(true); out.b(false)
            }
        case let .item(key, children):
            header(1, key, &out); out.i(0); out.i(1); out.i(copies[key] ?? key); out.f(1)
            for _ in 0..<8 { out.color() }
            for _ in 0..<3 { pattern(&out) }
            out.f(1); out.color(); out.f(1); out.color(); out.f(0.5); out.f(0)
            pattern(&out); out.b(false)
            let bones = itemBones[key] ?? []
            out.i(Int32(bones.count)); for bone in bones { out.s(bone.name); out.bone(bone.key) }
            out.b(false); out.f(0)
            list(children, &out)
        case let .route(key, children):
            header(4, key, &out); out.s("Route \(key)"); list(children, &out)
            out.i(0); out.b(false); out.b(true); out.b(true); out.i(0); out.color()
        case let .character(key, groups):
            header(0, key, &out); out.i(1); out.data += Self.card
            for bones in [fk[key] ?? [], ik[key] ?? []] {
                out.i(Int32(bones.count)); for bone in bones { out.i(bone.id); out.bone(bone.key) }
            }
            out.i(Int32(groups.count))
            for group in groups { out.i(group.point); list(group.children, &out) }
            for v: Int32 in [1, 2, 3, 4, 5, 6] { out.i(v) }
            out.f(0.125); out.data += Data([0, 1, 2, 3, 4]); out.f(0.25); out.b(true); out.bone(lookAt[key] ?? 104)
            out.b(false); for v in [true, false, true, false, true] { out.b(v) }
            out.b(true); for v in [false, true, false, false, false, false, false] { out.b(v) }
            for v in [true, false, true, false, true, false, true, false] { out.b(v) }
            out.f(1.25); out.f(0.375); out.b(true); out.b(false)
            out.i(1); for v: Int32 in [4, 5, 6, 2] { out.i(v) }
            out.b(false); out.f(1.125); out.b(false); out.color(); out.f(0.25); out.f(0.75)
            for value in [Data([0, 1, 255]), Data([2, 3, 254])] { out.i(Int32(value.count)); out.data += value }
            out.f(0.625); out.i(1); out.i(7); out.i(1); out.i(1); out.i(8); out.i(0)
        }
    }
    /// `SceneDocumentBytes.tail()` with the `sunCaster` Int32 as a parameter.
    private func tail(_ out: inout SceneDocumentBytes) {
        out.i(-1); out.transform(); out.i(0); out.b(true); out.i(3); out.f(0.2)
        out.b(true); out.color(); out.f(0.1); out.b(true); for v: Float in [0.4, 0.8, 0.6] { out.f(v) }
        out.b(false); out.f(0.95); out.f(0.6); out.b(true); out.b(false); out.color(); out.f(1); out.f(0)
        out.b(false); out.color(); out.color(); out.i(sunCaster)
        out.b(true); out.b(false); out.b(true); out.f(0.3); out.color(); out.f(0.7); out.i(2); out.f(0.9)
        for _ in 0..<11 { out.camera() }
        for map in [false, true] { out.color(); out.f(1.5); out.f(45); out.f(180); out.b(true); if map { out.i(1) } }
        for no: Int32 in [12, 13] { out.i(2); out.i(no); out.b(false) }
        out.i(1); out.s("sample.wav"); out.b(false); out.s("background.png"); out.s("frame.png"); out.s("【KStudio】")
    }

    static func kkex(_ payload: SourceMessagePackValue) -> Data {
        let packed = OriginalCardFixture.pack(payload)
        return OriginalCardFixture.string("KKEx") + OriginalCardFixture.i32(3) + OriginalCardFixture.i32(Int32(packed.count)) + packed
    }
}

// Original tree:
//   0 camera (active)              root
//   1 folder [2 camera (active), 3 item [4 folder], 5 light]
//   6 folder [7 item]
//   8 route [9 folder]
//   10 character {point 0: [], point 7: [11 folder]}
//   12 item
// CharaStudio's load order makes camera 2 the looked-through camera.
private func folderF(_ children: [TopologyNode]? = nil) -> TopologyNode {
    .folder(1, children ?? [.camera(2, active: true), .item(3, [.folder(4, [])]), .light(5)])
}
private let cameraA = TopologyNode.camera(0, active: true)
private func folderH(_ children: [TopologyNode] = [.item(7, [])]) -> TopologyNode { .folder(6, children) }
private let routeR = TopologyNode.route(8, [.folder(9, [])])
private func characterC(_ attached: [TopologyNode] = [.folder(11, [])]) -> TopologyNode {
    // Explicit Int32 points: older compilers do not infer literals through
    // an unlabeled-to-labeled tuple conversion.
    let groups: [(point: Int32, children: [TopologyNode])] = [(point: Int32(0), children: [TopologyNode]()),
                                                             (point: Int32(7), children: attached)]
    return .character(10, groups)
}
private let itemK = TopologyNode.item(12, [])
private func base(sunCaster: Int32 = -1, trailer: Data = Data()) -> TopologyScene {
    TopologyScene(roots: [cameraA, folderF(), folderH(), routeR, characterC(), itemK], sunCaster: sunCaster, trailer: trailer)
}
private func document(_ scene: TopologyScene) throws -> KoikatsuSceneDocument {
    try KoikatsuSceneReader.decodeDocument(scene.data)
}
private func change(_ values: [Float]) -> KoikatsuChangeAmount {
    .init(position: SIMD3(values[0], values[1], values[2]), rotationDegrees: SIMD3(values[3], values[4], values[5]),
          scale: SIMD3(values[6], values[7], values[8]))
}
private func refusal(_ body: () throws -> Any) -> String {
    do { _ = try body(); return "accepted" }
    catch let error as SourceSceneTopologyError { return error.errorDescription ?? "" }
    catch { return "other error: \(error)" }
}

@Test func sourceSceneTopologySpecBuilderMatchesTheReader() throws {
    let scene = base(sunCaster: 3), original = try document(scene)
    #expect(original.snapshot.roots.map(\.sourceKey) == [0, 1, 6, 8, 10, 12])
    #expect(original.snapshot.roots[1].children.map(\.sourceKey) == [2, 3, 5])
    #expect(original.snapshot.roots[4].character?.accessoryChildren[7]?.map(\.sourceKey) == [11])
    #expect(original.settings.sunCaster == 3 && SourceStudioCameraObjects.activeAtLoad(original.snapshot) == 2)
    // No topology edit, or one that leaves every list as it was (re-appending
    // the last child), returns the input bytes.
    #expect(try original.editedData(.init()) == scene.data)
    #expect(try original.editedData(.init(reparents: [.init(object: 12, parent: nil)])) == scene.data)
    #expect(try original.editedData(.init(reparents: [.init(object: 5, parent: 1)])) == scene.data)
}

@Test func sourceSceneTopologyDeletesASubtreeWithSunCasterAndCameraRules() throws {
    let scene = base(sunCaster: 3), original = try document(scene)
    let result = try original.editedData(.init(deletions: [1]))
    // Folder 1 leaves the root dictionary with cameras 2, item 3, folder 4 and
    // light 5; the sun caster (3) resets to -1 (Studio.DeleteInfo), and the
    // deleted camera 2 was the looked-through one (Studio.DeleteCamera), so
    // the stale `active` byte on camera 0 is cleared as a save would write it.
    var expected = TopologyScene(roots: [cameraA, folderH(), routeR, characterC(), itemK], sunCaster: -1)
    expected.cameraActive[0] = false
    #expect(result == expected.data)
    let reloaded = try KoikatsuSceneReader.decodeDocument(result)
    #expect(reloaded.settings.sunCaster == -1 && SourceStudioCameraObjects.activeAtLoad(reloaded.snapshot) == nil)
    #expect(try original.editedData(.init()) == scene.data, "the source document is unchanged")
}

@Test func sourceSceneTopologyDeletesRootsCharactersAndNestedChildren() throws {
    let original = try document(base())
    // A root item: no camera or sun caster change.
    #expect(try original.editedData(.init(deletions: [12]))
            == TopologyScene(roots: [cameraA, folderF(), folderH(), routeR, characterC()]).data)
    // A character takes its accessory children with it.
    #expect(try original.editedData(.init(deletions: [10]))
            == TopologyScene(roots: [cameraA, folderF(), folderH(), routeR, itemK]).data)
    // An item's child and a route's child leave their lists; keys are not renumbered.
    let nested = try original.editedData(.init(deletions: [4, 9]))
    #expect(nested == TopologyScene(roots: [cameraA, folderF([.camera(2, active: true), .item(3, []), .light(5)]),
                                            folderH(), .route(8, []), characterC(), itemK]).data)
    #expect(try KoikatsuSceneReader.decodeDocument(nested).snapshot.roots.map(\.sourceKey) == [0, 1, 6, 8, 10, 12])
    // A deleted sun caster that is not the deleted top record still resets.
    let caster = try document(base(sunCaster: 4)).editedData(.init(deletions: [3]))
    #expect(caster == TopologyScene(roots: [cameraA, folderF([.camera(2, active: true), .light(5)]), folderH(), routeR,
                                            characterC(), itemK], sunCaster: -1).data)
}

@Test func sourceSceneTopologyReparentsIntoFoldersAndTheRoot() throws {
    let original = try document(base())
    let moved: [Float] = [-4, 2.25, 9, 10, 20, 30, 1, 1, 1]
    // Folder child to another folder: appended after its remaining children,
    // with the re-authored local transform; its own bytes are otherwise kept.
    let toFolder = try original.editedData(.init(transforms: [.init(.object(7), transform: change(moved))],
                                                 reparents: [.init(object: 7, parent: 1)]))
    var expected = TopologyScene(roots: [cameraA, folderF([.camera(2, active: true), .item(3, [.folder(4, [])]), .light(5), .item(7, [])]),
                                         folderH([]), routeR, characterC(), itemK])
    expected.transforms[7] = moved
    #expect(toFolder == expected.data)
    // Folder child to the root: keyed by its own dicKey (Studio.AddInfo), appended.
    let toRoot = try original.editedData(.init(reparents: [.init(object: 3, parent: nil)]))
    #expect(toRoot == TopologyScene(roots: [cameraA, folderF([.camera(2, active: true), .light(5)]), folderH(), routeR,
                                            characterC(), itemK, .item(3, [.folder(4, [])])]).data)
    // Root to a folder, carrying a character with its accessory children.
    let rootToFolder = try original.editedData(.init(reparents: [.init(object: 10, parent: 6)]))
    #expect(rootToFolder == TopologyScene(roots: [cameraA, folderF(), folderH([.item(7, []), characterC()]), routeR, itemK]).data)
    // Moves apply in order; a folder moves with its subtree.
    let chain = try original.editedData(.init(reparents: [.init(object: 6, parent: 1), .init(object: 12, parent: 6)]))
    #expect(chain == TopologyScene(roots: [cameraA, folderF([.camera(2, active: true), .item(3, [.folder(4, [])]), .light(5),
                                                             folderH([.item(7, []), itemK])]), routeR, characterC()]).data)
}

@Test func sourceSceneTopologyKeepsTheLookedThroughCameraAfterAMove() throws {
    let original = try document(base())
    // Moving camera 0 after camera 2 in load order would make it the
    // winner; the reload keeps camera 2, so camera 0's stale byte is cleared.
    let result = try original.editedData(.init(reparents: [.init(object: 0, parent: 6)]))
    var expected = TopologyScene(roots: [folderF(), folderH([.item(7, []), .camera(0, active: true)]), routeR, characterC(), itemK])
    expected.cameraActive[0] = false
    #expect(result == expected.data)
    #expect(SourceStudioCameraObjects.activeAtLoad(try KoikatsuSceneReader.decodeDocument(result).snapshot) == 2)
    // An explicit camera edit is written literally instead.
    let explicit = try original.editedData(.init(cameraActive: [0: true, 2: false], reparents: [.init(object: 0, parent: 6)]))
    var literal = TopologyScene(roots: expected.roots); literal.cameraActive[2] = false
    #expect(explicit == literal.data)
}

@Test func sourceSceneTopologyMoveOutThenDeleteAndRevert() throws {
    let scene = base(sunCaster: 3), original = try document(scene)
    // CharaStudio lets an object leave a folder before the folder is deleted.
    let rescued = try original.editedData(.init(deletions: [1], reparents: [.init(object: 3, parent: nil)]))
    var expected = TopologyScene(roots: [cameraA, folderH(), routeR, characterC(), itemK, .item(3, [.folder(4, [])])], sunCaster: 3)
    expected.cameraActive[0] = false
    #expect(rescued == expected.data)
    // Edit then revert: moving the last child away and back, with its
    // original transform, returns the original bytes.
    let away = try KoikatsuSceneReader.decodeDocument(original.editedData(.init(
        transforms: [.init(.object(7), transform: change([5, 5, 5, 0, 90, 0, 1, 1, 1]))], reparents: [.init(object: 7, parent: nil)])))
    #expect(away.preservedData != scene.data)
    let back = try away.editedData(.init(transforms: [.init(.object(7), transform: change(TopologyScene.transform(7)))],
                                         reparents: [.init(object: 7, parent: 6)]))
    #expect(back == scene.data)
}

@Test func sourceSceneTopologyDeletesInsideARecordMovedOutOfADeletedFolder() throws {
    // CharaStudio: move folder B (22) out of folder A (20) to the root, delete
    // B's child item C (23, with its folder 24), then delete A. C leaves A
    // with B, so it is deleted on its own, not "with its parent".
    let folderB = TopologyNode.folder(22, [.item(23, [.folder(24, [])]), .light(25)])
    let scene = TopologyScene(roots: [cameraA, .folder(20, [folderB, .light(21)]), itemK])
    let original = try document(scene)
    let deletions: Set<Int32> = [20, 23]
    let reparents: [SourceSceneEdits.Reparent] = [.init(object: 22, parent: nil)]
    let plan = try SourceSceneTopology.plan(original.snapshot, deletions: deletions, reparents: reparents)
    #expect(plan.deleted == Set<Int32>([20, 21, 23, 24]) && plan.moved == Set<Int32>([22]))
    let moved: [Float] = [1, 2, 3, 0, 45, 0, 1, 1, 1]
    let result = try original.editedData(.init(transforms: [.init(.object(22), transform: change(moved))],
                                               deletions: deletions, reparents: reparents))
    // Independent serialization of the final tree: A is gone, B is the last
    // root with its own key and the re-authored transform, without C.
    var expected = TopologyScene(roots: [cameraA, itemK, .folder(22, [.light(25)])])
    expected.transforms[22] = moved
    #expect(result == expected.data)
    let reloaded = try KoikatsuSceneReader.decodeDocument(result).snapshot
    #expect(reloaded.roots.map(\.sourceKey) == [Int32(0), 12, 22])
    #expect(reloaded.roots.allSatisfy { $0.rootDictionaryKey == $0.sourceKey })
    #expect(reloaded.roots.last?.children.map(\.sourceKey) == [Int32(25)])
    // The app derivation from that final tree gives the same edits.
    let survivors: [SourceSceneTopology.Placement] = [.init(key: 0, parent: nil), .init(key: 12, parent: nil),
                                                      .init(key: 22, parent: nil), .init(key: 25, parent: 22)]
    let derived = try SourceSceneTopology.edits(from: original.snapshot, survivors: survivors)
    #expect(derived.deletions == deletions && derived.reparents == reparents)
    // Without the move, C is still inside the deleted A: listing it is refused.
    #expect(refusal { try original.editedData(.init(deletions: deletions)) }.contains("already deleted with its parent"))
}

@Test func sourceSceneTopologyDerivesEditsFromTheFinalTree() throws {
    let original = try document(base()).snapshot
    func placements(_ nodes: [TopologyNode], parent: Int32?, attachment: Int32? = nil) -> [SourceSceneTopology.Placement] {
        nodes.flatMap { node -> [SourceSceneTopology.Placement] in
            var result = [SourceSceneTopology.Placement(key: node.key, parent: parent, attachment: attachment)]
            switch node {
            case let .folder(key, children), let .item(key, children), let .route(key, children):
                result += placements(children, parent: key)
            case let .character(key, groups):
                for group in groups { result += placements(group.children, parent: key, attachment: group.point) }
            case .camera, .light: break
            }
            return result
        }
    }
    let unchanged = try SourceSceneTopology.edits(from: original, survivors: placements(base().roots, parent: nil))
    #expect(unchanged.deletions.isEmpty && unchanged.reparents.isEmpty)
    // Folder 1 deleted after item 3 moved to the root; only the top of the
    // deleted subtree is listed.
    let rescued = try SourceSceneTopology.edits(from: original, survivors: placements(
        [cameraA, folderH(), routeR, characterC(), itemK, .item(3, [.folder(4, [])])], parent: nil))
    #expect(rescued.deletions == [1] && rescued.reparents == [.init(object: 3, parent: nil)])
    // A reorder inside a folder keeps the longest in-order prefix and re-appends the rest.
    let reordered = try SourceSceneTopology.edits(from: original, survivors: placements(
        [cameraA, folderF([.item(3, [.folder(4, [])]), .camera(2, active: true), .light(5)]), folderH(), routeR, characterC(), itemK], parent: nil))
    #expect(reordered.deletions.isEmpty && reordered.reparents == [.init(object: 2, parent: 1), .init(object: 5, parent: 1)])
    // A survivor list with unknown or repeated keys is refused.
    #expect(refusal { try SourceSceneTopology.edits(from: original, survivors: [.init(key: 99, parent: nil)]) }.contains("unknown source object 99"))
    #expect(refusal { try SourceSceneTopology.edits(from: original, survivors: [.init(key: 0, parent: nil), .init(key: 0, parent: nil)]) }.contains("twice"))
}

@Test func sourceSceneTopologyPluginTrailerRules() throws {
    let plugins = TopologyScene.kkex(OriginalCardFixture.map([("example.scene", .integer(7))]))
    // Plug-in data is keyed by object; deleting would leave stale entries.
    for trailer in [plugins, Data([0, 255, 3])] {
        let original = try document(base(trailer: trailer))
        #expect(refusal { try original.editedData(.init(deletions: [12])) }.contains("plug-in (ExtendedSave) data"))
        // Reparenting keeps every key, so the trailer is kept byte for byte.
        let moved = try original.editedData(.init(reparents: [.init(object: 12, parent: 6)]))
        var expected = TopologyScene(roots: [cameraA, folderF(), folderH([.item(7, []), itemK]), routeR, characterC()])
        expected.trailer = trailer
        #expect(moved == expected.data)
    }
    // A KKEx block with no entries does not block deletion and is kept.
    for trailer in [TopologyScene.kkex(.null), TopologyScene.kkex(OriginalCardFixture.map([]))] {
        let result = try document(base(trailer: trailer)).editedData(.init(deletions: [12]))
        var expected = TopologyScene(roots: [cameraA, folderF(), folderH(), routeR, characterC()]); expected.trailer = trailer
        #expect(result == expected.data)
    }
}

@Test func sourceSceneTopologyRefusesUnsupportedCasesAtomically() throws {
    let original = try document(base())
    func reason(_ edits: SourceSceneEdits) -> String { refusal { try original.editedData(edits) } }
    let cases: [(SourceSceneEdits, String)] = [
        (.init(deletions: [11]), "attached to a character's accessory point"),
        (.init(deletions: [1, 3]), "already deleted with its parent"),
        (.init(deletions: [99]), "cannot delete unknown source object 99"),
        (.init(reparents: [.init(object: 8, parent: 6)]), "does not reparent routes"),
        (.init(reparents: [.init(object: 11, parent: nil)]), "attached to a character's accessory points"),
        (.init(reparents: [.init(object: 9, parent: nil)]), "does not move route children"),
        (.init(reparents: [.init(object: 4, parent: nil)]), "does not move item children"),
        (.init(reparents: [.init(object: 12, parent: 3)]), "under items"),
        (.init(reparents: [.init(object: 12, parent: 8)]), "under routes"),
        (.init(reparents: [.init(object: 12, parent: 10)]), "onto a character's accessory points"),
        (.init(reparents: [.init(object: 12, parent: 0)]), "cannot hold children"),
        (.init(reparents: [.init(object: 12, parent: 5)]), "cannot hold children"),
        (.init(reparents: [.init(object: 6, parent: 6)]), "its own ancestor"),
        (.init(reparents: [.init(object: 1, parent: 6), .init(object: 6, parent: 1)]), "its own ancestor"),
        (.init(reparents: [.init(object: 12, parent: 6), .init(object: 12, parent: 1)]), "moved twice"),
        (.init(deletions: [12], reparents: [.init(object: 12, parent: 6)]), "both deleted and moved"),
        (.init(deletions: [6], reparents: [.init(object: 12, parent: 6)]), "under deleted source object 6"),
        (.init(reparents: [.init(object: 99, parent: nil)]), "cannot move unknown source object 99"),
        (.init(reparents: [.init(object: 12, parent: 99)]), "under unknown source object 99"),
        (.init(transforms: [.init(.object(3), transform: change(TopologyScene.transform(3)))], deletions: [1]), "targets deleted source object 3"),
        (.init(visibility: [2: true], deletions: [1]), "targets deleted source object 2"),
        (.init(cameraActive: [2: false], deletions: [1]), "targets deleted source object 2"),
    ]
    for (edits, expected) in cases {
        let text = reason(edits)
        #expect(text.contains(expected), "\(expected): \(text)")
        // The byte-free validation gives the same reason for every tree
        // refusal; leaf edits are checked only by the writer.
        let validation = refusal { try SourceSceneTopology.validate(original.snapshot, deletions: edits.deletions, reparents: edits.reparents) }
        #expect(validation == (expected.hasPrefix("targets deleted") ? "accepted" : text), "\(expected)")
    }
    // A root stored under a different dictionary key can be neither removed
    // nor moved, and no record can join the root dictionary under that key.
    var collided = base(); collided.rootKeys[12] = 7
    let mismatched = try document(collided)
    #expect(mismatched.snapshot.roots.last?.rootDictionaryKey == 7)
    #expect(refusal { try mismatched.editedData(.init(deletions: [12])) }.contains("Root dictionary key 7 differs"))
    #expect(refusal { try mismatched.editedData(.init(reparents: [.init(object: 12, parent: 6)])) }.contains("Root dictionary key 7 differs"))
    #expect(refusal { try mismatched.editedData(.init(reparents: [.init(object: 7, parent: nil)])) }.contains("another root already uses key 7"))
    #expect(try original.editedData(.init()) == base().data, "refusals leave the source document unchanged")
}
