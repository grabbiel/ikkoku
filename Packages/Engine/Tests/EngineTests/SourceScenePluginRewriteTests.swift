import Foundation
import Testing
import Assets
import Character
@testable import Studio

// ST-T03i PR 2: KKPE, MaterialEditor and NodesConstraints data rewritten
// through deletes and copies (SourceScenePluginRewrites.swift). Each scene is
// written field by field (TopologyScene), and each expected trailer is built
// here from the records CharaStudio's save writes after the same edit,
// independently of the writer's byte patching.

private func rwPlugin(_ version: Int64, _ data: PluginMP) -> PluginMP { .arr([.int(version), data]) }
private func rwPacked(_ value: PluginMP) -> PluginMP { .bin(value.bytes) }

/// ExtendedSave's scene trailer: "KKEx", data version 3, the payload length,
/// then `Dictionary<string, PluginData>`.
private func rwTrailer(_ entries: [(String, PluginMP)]) -> Data {
    var payload = PluginMP.header(entries.count, fix: 0x80, 0xde, 0xdf)
    for (id, value) in entries { payload += PluginMP.str(id).bytes + value.bytes }
    var out: [UInt8] = [4] + Array("KKEx".utf8)
    withUnsafeBytes(of: Int32(3).littleEndian) { out += $0 }
    withUnsafeBytes(of: Int32(payload.count).littleEndian) { out += $0 }
    return Data(out + payload)
}

private let rwSettings: (String, PluginMP) = ("com.deathweasel.bepinex.studioscenesettings",
                                              rwPlugin(0, .map([("NearClipPlane", .f32(0.1))])))
private var rwGroups: [(point: Int32, children: [TopologyNode])] { [(point: Int32(0), children: [TopologyNode]())] }

/// 0 folder [1 item [2 item], 3 item], 4 item, 5 light, 6 route (points 7
/// and 9, aids 8 and 10), 11 camera, 12 character: object indices 0-8 in
/// key order. With `hole` the character is 13 and key 12 is free.
private func rwScene(_ entries: [(String, PluginMP)]?, hole: Bool = false, card: Data? = nil) -> TopologyScene {
    let character: Int32 = hole ? 13 : 12
    let folder = TopologyNode.folder(0, [.item(1, [.item(2, [])]), .item(3, [])])
    var scene = TopologyScene(roots: [folder, .item(4, []), .light(5), .route(6, []), .camera(11, active: false),
                                      .character(character, rwGroups)])
    scene.routePoints[6] = [TopologyRoutePoint(key: 7, position: .zero, aidKey: 8),
                            TopologyRoutePoint(key: 9, position: SIMD3(0, 0, 1), aidKey: 10)]
    if let entries { scene.trailer = rwTrailer(entries) }
    if let card { scene.cards[character] = card }
    return scene
}

private let rwCopyItem = SourceSceneEdits(insertions: [.init(.duplicate(of: 4))])
/// Folder 0 with its items: copies 13 [14 [15], 16].
private let rwCopyFolder = SourceSceneEdits(insertions: [
    .init(.duplicate(of: 0)), .init(.duplicate(of: 1), parent: .inserted(0)),
    .init(.duplicate(of: 2), parent: .inserted(1)), .init(.duplicate(of: 3), parent: .inserted(0))])
/// Item 1 with its child 2: copies 13 [14].
private let rwCopyPair = SourceSceneEdits(insertions: [
    .init(.duplicate(of: 1), parent: .source(0)), .init(.duplicate(of: 2), parent: .inserted(0))])
private let rwCopyCharacter = SourceSceneEdits(insertions: [.init(.duplicate(of: 12))])
private let rwAddFolder = SourceSceneEdits(insertions: [.init(.folder(name: "New"))])
private let rwMoveItem = SourceSceneEdits(reparents: [.init(object: 4, parent: 0)])

/// `OCIRoute.AddPoint` on route 6.
private func rwAddPoint() throws -> SourceSceneEdits {
    let document = try KoikatsuSceneReader.decodeDocument(rwScene(nil).data)
    let route = try #require(document.snapshot.roots.first { $0.sourceKey == 6 }?.route)
    var state = SourceStudioRouteState(record: route)
    _ = try state.addPoint()
    return .init(routes: [6: state])
}

private func rwEdited(_ scene: TopologyScene, _ edits: SourceSceneEdits) throws -> Data {
    try KoikatsuSceneReader.decodeDocument(scene.data).editedData(edits)
}
private func rwTrailerAfter(_ scene: TopologyScene, _ edits: SourceSceneEdits) throws -> Data {
    try KoikatsuSceneReader.decodeDocument(rwEdited(scene, edits)).trailingData
}
/// "kept" (the trailer as it was), "rewritten", or the refusal.
private func rwOutcome(_ scene: TopologyScene, _ edits: SourceSceneEdits) -> String {
    do {
        let original = try KoikatsuSceneReader.decodeDocument(scene.data)
        let result = try KoikatsuSceneReader.decodeDocument(original.editedData(edits))
        return result.trailingData == original.trailingData ? "kept" : "rewritten"
    } catch let error as SourceSceneTopologyError {
        return error.errorDescription ?? ""
    } catch {
        return "other error: \(error)"
    }
}

// MARK: - KKPE

/// `MainWindow.OnSceneSave`: `<root version=…>` with one `itemInfo` per item.
private func kkpeRoot(_ items: [String]) -> String {
    items.isEmpty ? #"<root version="2.21.4" />"# : #"<root version="2.21.4">"# + items.joined() + "</root>"
}
private func kkpeItem(_ key: Int32, _ id: Int32, _ body: String = "", name: String = "Item") -> String {
    let head = #"<itemInfo name="\#(name)" index="\#(key)" enabled="true" uniqueId="\#(id)""#
    return body.isEmpty ? head + " />" : head + ">" + body + "</itemInfo>"
}
private func kkpeEntry(_ xml: String) -> (String, PluginMP) { ("kkpe", rwPlugin(0, .map([("sceneInfo", .str(xml))]))) }

/// An item controller with a dynamic bone.
private let kkpeBones = #"<dynamicBones><dynamicBone root="Bone" enabled="true" /></dynamicBones>"#
/// A lone collider's data naming dynamic bones by their controller's ID.
private func kkpeColliders(_ references: [String]) -> String {
    let head = #"<collider name="Collider" isNormalCollider="true""#
    let collider = references.isEmpty ? head + " />" : head + ">" + references.joined() + "</collider>"
    return "<colliders>" + collider + #"</colliders><collidersEditor addNewDynamicBonesAsDefault="true" />"#
}
private func kkpeBoneReference(_ id: Int32) -> String { #"<dynamicBoneData poseControllerId="\#(id)" root="Bone" enabled="false" />"# }
private func kkpeBoobReference(_ id: Int32) -> String { #"<dynamicBoneData2 poseControllerId="\#(id)" id="0" enabled="false" />"# }

/// A character card whose Extended Save holds KKPE's `characterInfo`
/// (`OnCharaSave`) with controller ID `id`, in the current block or, with
/// `legacy`, in the version 2 trailer.
private func kkpeCard(_ id: Int32, legacy: Bool = false) -> Data {
    kkpeCard(info: #"<characterInfo version="2.21.4" uniqueId="\#(id)"><boobs enabled="true" /></characterInfo>"#, legacy: legacy)
}
/// The same with `info` as KKPE's `characterInfo` string.
private func kkpeCard(info: String, legacy: Bool = false) -> Data {
    if legacy {
        let data = OriginalCardFixture.map([("characterInfo", .string(info))])
        let value = OriginalCardFixture.map([("kkpe", OriginalCardFixture.plugin(0, data: data))])
        return OriginalCardFixture.card(trailer: OriginalCardFixture.legacy(value))
    }
    let ext = PluginMP.map([("kkpe", rwPlugin(0, .map([("characterInfo", .str(info))])))])
    return OriginalCardFixture.card(blocks: OriginalCardFixture.blocks() + [OriginalCardFixture.Block(name: "KKEx", version: "3", data: Data(ext.bytes))])
}

private let kkpeItem1 = kkpeItem(1, -41250)
private let kkpeItem2 = kkpeItem(2, -41262, kkpeBones)
private let kkpeItem4 = kkpeItem(4, -41286)
/// Item 3, a lone collider ("Collider") naming item 2's and character 12's bones.
private func kkpeCollider(_ references: [String]) -> String { kkpeItem(3, -41274, kkpeColliders(references), name: "Collider") }
private let kkpeLinks = [kkpeBoneReference(-41262), kkpeBoobReference(-50000)]
private let kkpeLinked = kkpeRoot([kkpeItem1, kkpeItem2, kkpeCollider(kkpeLinks), kkpeItem4])
/// The same items without a lone collider.
private let kkpePlain = kkpeRoot([kkpeItem1, kkpeItem2, kkpeItem(3, -41274), kkpeItem4])

@Test func sourceScenePluginRewritesKKPEDeletes() throws {
    let scene = rwScene([kkpeEntry(kkpeLinked), rwSettings], card: kkpeCard(-50000))
    func expected(_ items: [String]) -> Data { rwTrailer([kkpeEntry(kkpeRoot(items)), rwSettings]) }
    // A deleted item's element goes; the rest keep their bytes in key order.
    #expect(try rwTrailerAfter(scene, .init(deletions: [4])) == expected([kkpeItem1, kkpeItem2, kkpeCollider(kkpeLinks)]))
    #expect(try rwTrailerAfter(scene, .init(deletions: [3])) == expected([kkpeItem1, kkpeItem2, kkpeItem4]))
    // References to a deleted controller go with it (the lone collider's
    // Update prunes them): item 2's with folder 1, character 12's with it.
    #expect(try rwTrailerAfter(scene, .init(deletions: [1])) == expected([kkpeCollider([kkpeBoobReference(-50000)]), kkpeItem4]))
    #expect(try rwTrailerAfter(scene, .init(deletions: [12])) == expected([kkpeItem1, kkpeItem2, kkpeCollider([kkpeBoneReference(-41262)]), kkpeItem4]))
    // With no reference left the collider stays dirty and empty.
    #expect(try rwTrailerAfter(scene, .init(deletions: [1, 12])) == expected([kkpeCollider([]), kkpeItem4]))
    // No item left: the root alone.
    #expect(try rwTrailerAfter(scene, .init(deletions: [0, 4])) == expected([]))
    // Controls: edits that move no item and drop no reference keep the bytes.
    for edits in [SourceSceneEdits(deletions: [5]), rwAddFolder, rwMoveItem] {
        #expect(rwOutcome(scene, edits) == "kept")
    }
    // A character delete with no reference in the scene data keeps it.
    #expect(rwOutcome(rwScene([kkpeEntry(kkpePlain)], card: kkpeCard(-50000)), .init(deletions: [12])) == "kept")
    #expect(try rwTrailerAfter(scene, .init(deletions: [4])) != scene.trailer)
}

@Test func sourceScenePluginRewritesKKPECopiesUnderFreshControllerIDs() throws {
    // A copy gets its template's element under its own key and a fresh ID;
    // references are copied as they are (CollidersEditor.LoadFrom).
    let linked = rwScene([kkpeEntry(kkpeLinked), rwSettings], card: kkpeCard(-50000))
    func expected(_ items: [String]) -> Data { rwTrailer([kkpeEntry(kkpeRoot(items)), rwSettings]) }
    let sources = [kkpeItem1, kkpeItem2, kkpeCollider(kkpeLinks), kkpeItem4]
    #expect(try rwTrailerAfter(linked, rwCopyItem) == expected(sources + [kkpeItem(13, -41287)]))
    let copyCollider = SourceSceneEdits(insertions: [.init(.duplicate(of: 3), parent: .source(0))])
    let colliderCopy = kkpeItem(13, -41275, kkpeColliders(kkpeLinks), name: "Collider")
    #expect(try rwTrailerAfter(linked, copyCollider) == expected(sources + [colliderCopy]))
    // Copies of folder 0's items 1-3, in key order.
    let plain = rwScene([kkpeEntry(kkpePlain)])
    let copies = [kkpeItem(14, -41251), kkpeItem(15, -41263, kkpeBones), kkpeItem(16, -41275)]
    let plainSources = [kkpeItem1, kkpeItem2, kkpeItem(3, -41274), kkpeItem4]
    #expect(try rwTrailerAfter(plain, rwCopyFolder) == rwTrailer([kkpeEntry(kkpeRoot(plainSources + copies))]))
    // A fresh ID avoids every ID in the file, cards included.
    let taken = rwScene([kkpeEntry(kkpePlain)], card: kkpeCard(-41287))
    #expect(try rwTrailerAfter(taken, rwCopyItem) == rwTrailer([kkpeEntry(kkpeRoot(plainSources + [kkpeItem(13, -41288)]))]))
    // Copies take IDs in key order: item copy 13 first, then character copy
    // 14, whose template -41285 would otherwise take -41287.
    let ordered = rwScene([kkpeEntry(kkpePlain)], card: kkpeCard(-41285))
    let both = SourceSceneEdits(insertions: [.init(.duplicate(of: 4)), .init(.duplicate(of: 12))])
    let written = try KoikatsuSceneReader.decodeDocument(rwEdited(ordered, both))
    #expect(written.trailingData == rwTrailer([kkpeEntry(kkpeRoot(plainSources + [kkpeItem(13, -41287)]))]))
    let character = try #require(written.snapshot.roots.first { $0.sourceKey == 14 }?.character)
    #expect(try KKPEPlan.card(character.cardData, key: 14)?.id == -41288)
}

@Test func sourceScenePluginRewritesKKPEFreshIDsDeterministically() {
    // The template's digit count and sign: magnitudes above it first, up to
    // the largest of that length, then below it; never 0 or a used ID.
    #expect(KKPEPlan.freshID(-41286, avoiding: []) == -41287)
    #expect(KKPEPlan.freshID(-41286, avoiding: [-41287, -41288]) == -41289)
    #expect(KKPEPlan.freshID(-99999, avoiding: []) == -99998)
    #expect(KKPEPlan.freshID(-99999, avoiding: [-99998]) == -99997)
    #expect(KKPEPlan.freshID(41286, avoiding: [41287]) == 41288)
    #expect(KKPEPlan.freshID(9, avoiding: []) == 8)
    #expect(KKPEPlan.freshID(-10, avoiding: Set((-99)...(-11))) == nil)
    #expect(KKPEPlan.freshID(-12, avoiding: Set((-99)...(-13))) == -11)
    #expect(KKPEPlan.freshID(Int32.max, avoiding: []) == Int32.max - 1)
    #expect(KKPEPlan.freshID(Int32.min, avoiding: []) == Int32.min + 1)
    #expect(KKPEPlan.freshID(Int32.min + 1, avoiding: [Int32.min + 2]) == Int32.min)
    // No free ID of the length (1-9 all used, 0 never): nil.
    #expect(KKPEPlan.freshID(1, avoiding: Set(2...9)) == nil)
    #expect(KKPEPlan.freshID(-1, avoiding: Set((-9)...(-2))) == nil)
    #expect(KKPEPlan.freshID(-5, avoiding: Set((-9)...(-6)).union([-4, -3, -2])) == -1)
    for template: Int32 in [-41286, -99999, 9, Int32.max, Int32.min, 100, -100] {
        let fresh = KKPEPlan.freshID(template, avoiding: [])
        #expect(fresh.map { String($0).count } == String(template).count, "\(template)")
        #expect(fresh.map { ($0 < 0) == (template < 0) && $0 != 0 && $0 != template } == true, "\(template)")
    }
}

@Test func sourceScenePluginRewritesKKPECardIDInPlace() throws {
    // (b) A copied character's card gets the copy's controller ID in place:
    // the file equals the topology writer's copy with that card, field by
    // field (record and length fields included), and the card differs from
    // its template only in the ID's digits.
    let template = kkpeCard(-50000)
    let scene = rwScene([kkpeEntry(kkpePlain), rwSettings], card: template)
    let written = try rwEdited(scene, rwCopyCharacter)
    var expected = scene
    expected.roots.append(.character(13, rwGroups))
    expected.copies[13] = 12; expected.lookAt[13] = 14
    expected.cards[13] = kkpeCard(-50001)
    #expect(written == expected.data)
    let document = try KoikatsuSceneReader.decodeDocument(written)
    #expect(document.trailingData == scene.trailer)
    let copy = try #require(document.snapshot.roots.first { $0.sourceKey == 13 }?.character).cardData
    #expect(copy.count == template.count)
    let id = try #require(copy.range(of: Data(#"uniqueId="-50001""#.utf8)))
    let digits = (id.upperBound - 7)..<(id.upperBound - 1)
    let changed = zip(copy, template).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
    #expect(!changed.isEmpty && changed.allSatisfy(digits.contains))
    // The card decodes, with its Extended Save in the current block.
    let extensions = try SourceCharacterCard.decode(copy).extensions()
    #expect(extensions.format == "block-v3" && extensions.plugins["kkpe"] != nil)
    #expect(try KKPEPlan.card(copy, key: 13)?.id == -50001)
    #expect(try KKPEPlan.card(template, key: 12)?.id == -50000)
    // The source character keeps its card.
    #expect(try #require(document.snapshot.roots.first { $0.sourceKey == 12 }?.character).cardData == template)
}

@Test func sourceScenePluginRewritesProbeComparisonRenamesOnlyInstanceIDs() throws {
    // The phase C/D comparison (pluginProbeComparable): CharaStudio's copy
    // gets a fresh controller ID of any length, so our same-length ID must
    // compare equal; the pattern of equal IDs and every other byte must not.
    let scene = rwScene([kkpeEntry(kkpePlain), rwSettings], card: kkpeCard(-50000))
    let ours = try rwEdited(scene, rwCopyCharacter)
    func theirs(_ card: Data, extra: Bool = false) -> Data {
        var expected = scene
        expected.roots.append(.character(13, rwGroups))
        if extra { expected.roots.append(.folder(15, [])) }
        expected.copies[13] = 12; expected.lookAt[13] = 14
        expected.cards[13] = card
        return expected.data
    }
    #expect(try pluginProbeComparable(ours) == pluginProbeComparable(theirs(kkpeCard(-7))))
    #expect(try pluginProbeComparable(ours) == pluginProbeComparable(theirs(kkpeCard(-50001))))
    #expect(try pluginProbeComparable(ours) != pluginProbeComparable(theirs(kkpeCard(-50000))))
    var changed = kkpeCard(-7)
    changed.replaceSubrange(try #require(changed.range(of: Data(#"enabled="true""#.utf8))), with: Data(#"enabled="tru_""#.utf8))
    #expect(try pluginProbeComparable(ours) != pluginProbeComparable(theirs(changed)))
    #expect(try pluginProbeComparable(ours) != pluginProbeComparable(theirs(kkpeCard(-7), extra: true)))
}

@Test func sourceScenePluginRewritesNoCardWithoutAKKPEEntry() throws {
    // (c) Without a kkpe scene entry nothing reads controller IDs: the copy's
    // card is its template's, byte for byte.
    let card = kkpeCard(-50000)
    for entries in [[rwSettings], [], nil] as [[(String, PluginMP)]?] {
        let scene = rwScene(entries, card: card)
        var expected = scene
        expected.roots.append(.character(13, rwGroups))
        expected.copies[13] = 12; expected.lookAt[13] = 14
        expected.cards[13] = card
        #expect(try rwEdited(scene, rwCopyCharacter) == expected.data)
    }
    // Nor is a card read whose KKPE data has no controller ID.
    let odd = kkpeCard(info: #"<characterInfo version="2.21.4" />"#)
    let oddScene = rwScene([rwSettings], card: odd)
    var oddExpected = oddScene
    oddExpected.roots.append(.character(13, rwGroups))
    oddExpected.copies[13] = 12; oddExpected.lookAt[13] = 14
    oddExpected.cards[13] = odd
    #expect(try rwEdited(oddScene, rwCopyCharacter) == oddExpected.data)
    // A kkpe entry with a plain card (no KKPE data in it) patches nothing.
    let plainCard = rwScene([kkpeEntry(kkpePlain)])
    var expected = plainCard
    expected.roots.append(.character(13, rwGroups))
    expected.copies[13] = 12; expected.lookAt[13] = 14
    #expect(try rwEdited(plainCard, rwCopyCharacter) == expected.data)
}

@Test func sourceScenePluginRewritesKKPERefusesWhatItsRuleDoesNotCover() throws {
    let label = "KKPE data ('kkpe')"
    func expectRefused(_ scene: TopologyScene, _ edits: SourceSceneEdits, _ reason: String,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        let result = rwOutcome(scene, edits)
        #expect(result.hasPrefix("Original-scene export cannot ") && result.contains("\(label) \(reason)"), "\(result)",
                sourceLocation: sourceLocation)
    }
    // A copy of an object a lone collider names: every controller registers
    // its dynamic bones with each lone collider, so CharaStudio's save would
    // name the copy's too.
    let linked = rwScene([kkpeEntry(kkpeLinked)], card: kkpeCard(-50000))
    let registered = "registers a copy's dynamic bones with every lone collider, and a lone collider names those of object"
    expectRefused(linked, rwCopyPair, "\(registered) 2,")
    expectRefused(linked, rwCopyCharacter, "\(registered) 12,")
    // Deletes and item copies in one edit (#278: the copies' keys).
    let plain = rwScene([kkpeEntry(kkpePlain)], card: kkpeCard(-50000))
    let deleteAndCopy = SourceSceneEdits(deletions: [3], insertions: [.init(.duplicate(of: 4))])
    expectRefused(plain, deleteAndCopy, "writes each item's key and matches pose data to items by position, and this edit both deletes objects and copies items")
    // A delete with a character copy keeps item keys: the card is patched.
    let characterOnly = SourceSceneEdits(deletions: [3], insertions: [.init(.duplicate(of: 12))])
    #expect(rwOutcome(plain, characterOnly) == "rewritten")
    // No free ID of the template's length.
    let filler = (5...9).map { #"<id uniqueId="-\#($0)" />"# }.joined()
    let full = rwScene([kkpeEntry(kkpeRoot([kkpeItem(1, -1, filler), kkpeItem(2, -2), kkpeItem(3, -3), kkpeItem(4, -4)]))])
    expectRefused(full, rwCopyItem, "has no free controller ID of the length of -4 for the copy of object 4")
    let spare = (5...8).map { #"<id uniqueId="-\#($0)" />"# }.joined()
    let roomy = rwScene([kkpeEntry(kkpeRoot([kkpeItem(1, -1, spare), kkpeItem(2, -2), kkpeItem(3, -3), kkpeItem(4, -4)]))])
    #expect(try rwTrailerAfter(roomy, rwCopyItem)
        == rwTrailer([kkpeEntry(kkpeRoot([kkpeItem(1, -1, spare), kkpeItem(2, -2), kkpeItem(3, -3), kkpeItem(4, -4), kkpeItem(13, -9)]))]))
    // A card in the version 2 trailer is not patched.
    expectRefused(rwScene([kkpeEntry(kkpePlain)], card: kkpeCard(-50000, legacy: true)), rwCopyCharacter,
                  "keeps character 12's pose data in a card whose Extended Save is not the current block, which this writer does not patch")
    // A card whose KKPE data has no non-zero controller ID: a copy needs
    // that ID, so it is refused by name; a delete without lone colliders
    // does not read cards.
    for info in [#"<characterInfo version="2.21.4"><boobs enabled="true" /></characterInfo>"#,
                 #"<characterInfo version="2.21.4" uniqueId="0" />"#, #"<other uniqueId="-50000" />"#] {
        let odd = rwScene([kkpeEntry(kkpePlain)], card: kkpeCard(info: info))
        expectRefused(odd, rwCopyCharacter, "has KKPE data in character 12's card in a form this writer does not read")
        #expect(rwOutcome(odd, .init(deletions: [12])) == "kept")
    }
    // A deleted controller's ID that two objects share.
    let shared = kkpeRoot([kkpeItem1, kkpeItem(2, -41286, kkpeBones), kkpeCollider([kkpeBoneReference(-41286)]), kkpeItem4])
    expectRefused(rwScene([kkpeEntry(shared)]), .init(deletions: [4]),
                  "names the dynamic bones of controller -41286, an ID more than one object has")
    // Forms KKPE does not write, refused for an edit that needs them read
    // and kept for one that does not.
    let forms: [(String, String)] = [
        (#"<root version="2.21.4"> </root>"#, "has pose data that is not in the XML form KKPE writes (text outside a tag at byte 23)"),
        (#"<root><itemInfo /></root>"#, "has pose data whose root is not KKPE's <root version=…>"),
        (#"<root version="1"><other /></root>"#, "has pose data with an element other than itemInfo under its root"),
        (kkpeRoot([kkpeItem1, kkpeItem2, kkpeItem4]), "has 3 item pose entries for the scene's 4 items, so they do not load one to one"),
        (kkpeRoot([kkpeItem1, kkpeItem2, kkpeItem4, kkpeItem(3, -41274)]), "has an item pose entry whose index is not item 3"),
        (kkpeRoot([kkpeItem1, kkpeItem2, kkpeItem(3, 0), kkpeItem4]), "has the pose entry of item 3 without a controller ID (uniqueId)"),
        (kkpeRoot([kkpeItem1, kkpeItem2, kkpeItem(3, -41274), #"<itemInfo index="4" uniqueId="-041286" />"#]),
         "has pose data KKPE does not write (itemInfo has a uniqueId that is not a canonical Int32)"),
        (kkpeRoot([kkpeItem1, kkpeItem2, kkpeCollider([#"<dynamicBoneData root="Bone" />"#]), kkpeItem4]),
         "has a dynamic bone reference (dynamicBoneData) without a canonical non-zero poseControllerId"),
    ]
    for (xml, reason) in forms {
        let scene = rwScene([kkpeEntry(xml)])
        expectRefused(scene, .init(deletions: [4]), reason)
        expectRefused(scene, rwCopyItem, reason)
        for edits in [SourceSceneEdits(deletions: [5]), rwMoveItem, rwAddFolder] { #expect(rwOutcome(scene, edits) == "kept", "\(xml)") }
    }
    let twoFields = ("kkpe", rwPlugin(0, .map([("sceneInfo", .str(kkpePlain)), ("future", .int(1))])))
    expectRefused(rwScene([twoFields]), .init(deletions: [4]), "has data other than one 'sceneInfo' XML string, which this writer does not read")
    expectRefused(rwScene([twoFields]), rwCopyCharacter, "has data other than one 'sceneInfo' XML string, which this writer does not read")
    // Edits that move no item and touch no character do not read the entry.
    for edits in [rwMoveItem, rwAddFolder, SourceSceneEdits(deletions: [5]), try rwAddPoint()] {
        #expect(rwOutcome(rwScene([twoFields]), edits) == "kept")
    }
}

// MARK: - MaterialEditor

private let materialID = "com.deathweasel.bepinex.materialeditor"

/// Records for item `id`, carrying the values of `source`'s (a copy's template).
private func materialFloat(_ id: Int64, _ source: Int64? = nil) -> PluginMP {
    .map([("ID", .int(id)), ("MaterialName", .str("mat")), ("Property", .str("_Glossiness")),
          ("Value", .str("0.\(source ?? id)")), ("ValueOriginal", .str("0"))])
}
private func materialColor(_ id: Int64, _ source: Int64? = nil) -> PluginMP {
    .map([("ID", .int(id)), ("MaterialName", .str("mat")), ("Property", .str("_Color")),
          ("Value", .str("\(source ?? id),0,0,1")), ("ValueOriginal", .str("1,1,1,1"))])
}
/// A texture record with `TexID` and, with `frames`, an animation whose
/// frames (`MEAnimationFrame`, key 0 the texture ID) use those textures.
private func materialTexture(_ id: Int64, _ texture: Int64, frames: [Int64] = []) -> PluginMP {
    let animation: PluginMP = frames.isEmpty ? .null
        : .map([("frames", .arr(frames.map { PluginMP.arr([.int($0), .f32(0.5)]) })), ("loop", .bool(true))])
    return .map([("ID", .int(id)), ("MaterialName", .str("mat")), ("Property", .str("_MainTex")), ("TexID", .int(texture)),
                 ("Offset", .null), ("OffsetOriginal", .null), ("Scale", .null), ("ScaleOriginal", .null),
                 ("TexAnimationDef", animation)])
}
private func materialTextures(_ keys: [Int64]) -> PluginMP {
    .imap(keys.map { ($0, PluginMP.bin([UInt8($0), UInt8($0), 0xff])) })
}

/// SceneController's data: a nil list for an empty one.
private func materialEntry(floats: [PluginMP], colors: [PluginMP], textures: [PluginMP], dictionary: [Int64],
                           shaders: PluginMP = .null, extra: [(String, PluginMP)] = [], version: Int64 = 1) -> (String, PluginMP) {
    func list(_ records: [PluginMP]) -> PluginMP { records.isEmpty ? .null : rwPacked(.arr(records)) }
    let fields: [(String, PluginMP)] = [
        ("TextureDictionary", dictionary.isEmpty ? .null : rwPacked(materialTextures(dictionary))),
        ("MaterialShaderList", shaders), ("MaterialFloatPropertyList", list(floats)),
        ("MaterialColorPropertyList", list(colors)), ("MaterialTexturePropertyList", list(textures)),
        ("RendererPropertyList", .null),
    ]
    return (materialID, rwPlugin(version, .map(fields + extra)))
}

/// Item 1: a float; item 3: texture 2; item 4: a float, a colour, texture 1
/// animated through texture 3.
private func materialSource(shaders: PluginMP = .null, version: Int64 = 1, extra: [(String, PluginMP)] = []) -> (String, PluginMP) {
    materialEntry(floats: [materialFloat(1), materialFloat(4)], colors: [materialColor(4)],
                  textures: [materialTexture(3, 2), materialTexture(4, 1, frames: [3])], dictionary: [1, 2, 3],
                  shaders: shaders, extra: extra, version: version)
}

@Test func sourceScenePluginRewritesMaterialEditorRecordsByItem() throws {
    let scene = rwScene([materialSource(), rwSettings])
    func expected(_ entry: (String, PluginMP)) -> Data { rwTrailer([entry, rwSettings]) }
    // A deleted item's records go; an emptied list is nil; textures no
    // record uses are purged (PurgeUnusedTextures), animation frames count.
    let deleteFour = materialEntry(floats: [materialFloat(1)], colors: [], textures: [materialTexture(3, 2)], dictionary: [2])
    #expect(try rwTrailerAfter(scene, .init(deletions: [4])) == expected(deleteFour))
    let deleteThree = materialEntry(floats: [materialFloat(1), materialFloat(4)], colors: [materialColor(4)],
                                    textures: [materialTexture(4, 1, frames: [3])], dictionary: [1, 3])
    #expect(try rwTrailerAfter(scene, .init(deletions: [3])) == expected(deleteThree))
    let deleteOne = materialEntry(floats: [materialFloat(4)], colors: [materialColor(4)],
                                  textures: [materialTexture(3, 2), materialTexture(4, 1, frames: [3])], dictionary: [1, 2, 3])
    #expect(try rwTrailerAfter(scene, .init(deletions: [1])) == expected(deleteOne))
    // A copy's records: its template's under its key, after the others, in
    // each list (OnObjectsCopied); the textures are shared.
    let copyFour = materialEntry(floats: [materialFloat(1), materialFloat(4), materialFloat(13, 4)],
                                 colors: [materialColor(4), materialColor(13, 4)],
                                 textures: [materialTexture(3, 2), materialTexture(4, 1, frames: [3]), materialTexture(13, 1, frames: [3])],
                                 dictionary: [1, 2, 3])
    #expect(try rwTrailerAfter(scene, rwCopyItem) == expected(copyFour))
    let copyFolder = materialEntry(floats: [materialFloat(1), materialFloat(4), materialFloat(14, 1)], colors: [materialColor(4)],
                                   textures: [materialTexture(3, 2), materialTexture(4, 1, frames: [3]), materialTexture(16, 2)],
                                   dictionary: [1, 2, 3])
    #expect(try rwTrailerAfter(scene, rwCopyFolder) == expected(copyFolder))
    // Controls: edits that delete or copy no item with records keep the bytes.
    let others = [SourceSceneEdits(deletions: [2]), .init(deletions: [5]), rwAddFolder, rwMoveItem, rwCopyCharacter,
                  .init(insertions: [.init(.duplicate(of: 2), parent: .source(1))])]
    for edits in others { #expect(rwOutcome(scene, edits) == "kept") }
    #expect(try rwTrailerAfter(scene, .init(deletions: [4])) != scene.trailer)
    // A delete with a copy of an item without records keeps every key that has records.
    let mixed = SourceSceneEdits(deletions: [3], insertions: [.init(.duplicate(of: 2), parent: .source(1))])
    #expect(try rwTrailerAfter(scene, mixed) == expected(deleteThree))
}

@Test func sourceScenePluginRewritesMaterialEditorStaleRecordsAndEncodings() throws {
    // A record for a key that is not an item loads nowhere (ExtractGameObject
    // binds items only) and is not saved again: kept until an item is
    // copied, whose key could be its key, then dropped.
    let stale = materialEntry(floats: [materialFloat(1), materialFloat(13)], colors: [], textures: [], dictionary: [])
    let scene = rwScene([stale])
    for edits in [SourceSceneEdits(deletions: [2]), .init(deletions: [5]), rwAddFolder, rwCopyCharacter] {
        #expect(rwOutcome(scene, edits) == "kept")
    }
    let copied = materialEntry(floats: [materialFloat(1)], colors: [], textures: [], dictionary: [])
    #expect(try rwTrailerAfter(scene, .init(insertions: [.init(.duplicate(of: 2), parent: .source(1))])) == rwTrailer([copied]))
    let elsewhere = rwScene([materialEntry(floats: [materialFloat(1), materialFloat(99)], colors: [], textures: [], dictionary: [])])
    #expect(try rwTrailerAfter(elsewhere, rwCopyItem) == rwTrailer([copied]))
    let deleted = materialEntry(floats: [], colors: [], textures: [], dictionary: [])
    #expect(try rwTrailerAfter(scene, .init(deletions: [1])) == rwTrailer([deleted]))
    // Lists the edit does not change keep their bytes; a rewritten list is
    // written as MessagePack-CSharp writes it (an Int32-coded ID shortest).
    func shader(_ id: PluginMP) -> PluginMP {
        .map([("ID", id), ("MaterialName", .str("mat")), ("ShaderName", .str("Shader")), ("ShaderNameOriginal", .str("Standard")),
              ("RenderQueue", .int(2000)), ("RenderQueueOriginal", .int(2000))])
    }
    let int32Four = PluginMP.raw([0xd2, 0, 0, 0, 4])
    let source = rwScene([materialSource(shaders: rwPacked(.arr([shader(int32Four)])))])
    let deleteOne = materialEntry(floats: [materialFloat(4)], colors: [materialColor(4)],
                                  textures: [materialTexture(3, 2), materialTexture(4, 1, frames: [3])], dictionary: [1, 2, 3],
                                  shaders: rwPacked(.arr([shader(int32Four)])))
    #expect(try rwTrailerAfter(source, .init(deletions: [1])) == rwTrailer([deleteOne]))
    let copyFour = materialEntry(floats: [materialFloat(1), materialFloat(4), materialFloat(13, 4)],
                                 colors: [materialColor(4), materialColor(13, 4)],
                                 textures: [materialTexture(3, 2), materialTexture(4, 1, frames: [3]), materialTexture(13, 1, frames: [3])],
                                 dictionary: [1, 2, 3], shaders: rwPacked(.arr([shader(.int(4)), shader(.int(13))])))
    #expect(try rwTrailerAfter(source, rwCopyItem) == rwTrailer([copyFour]))
}

@Test func sourceScenePluginRewritesMaterialEditorRefusesWhatItsRuleDoesNotCover() throws {
    let label = "MaterialEditor data ('\(materialID)')"
    func expectRefused(_ scene: TopologyScene, _ edits: SourceSceneEdits, _ reason: String,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        let result = rwOutcome(scene, edits)
        #expect(result.hasPrefix("Original-scene export cannot ") && result.contains("\(label) \(reason)"), "\(result)",
                sourceLocation: sourceLocation)
    }
    // Version 0 data CharaStudio's save would rewrite as version 1.
    let old = rwScene([materialSource(version: 0)])
    expectRefused(old, .init(deletions: [4]), "has version 0 data, which CharaStudio's save rewrites in its version 1 form; this writer rewrites version 1 only")
    #expect(rwOutcome(old, .init(deletions: [2])) == "kept")
    // Deletes and copies of items with records in one edit (#278).
    let scene = rwScene([materialSource()])
    expectRefused(scene, .init(deletions: [3], insertions: [.init(.duplicate(of: 4))]),
                  "keys its material edits by item, and this edit both deletes objects and copies items with material edits")
    // Textures Timeline may use are not purged here.
    let timeline = ("timeline", rwPlugin(0, .map([("sceneInfo", .str(#"<root><interpolable id="textureProperty" /></root>"#))])))
    let animated = rwScene([materialSource(), timeline])
    expectRefused(animated, .init(deletions: [4]), "purges textures no item uses on save except those Timeline's texture tracks use")
    #expect(rwOutcome(animated, .init(deletions: [1])) == "rewritten")   // every texture still used
    // Fields and record keys this writer does not read: textures saved
    // Deduped or Local, a newer MaterialEditor.
    expectRefused(rwScene([materialSource(extra: [("FutureList", .null)])]), .init(deletions: [4]),
                  "has a data key 'FutureList' this writer does not read")
    let extraKey = materialEntry(floats: [.map([("ID", .int(4)), ("Extra", .int(1))])], colors: [], textures: [], dictionary: [])
    expectRefused(rwScene([extraKey]), .init(deletions: [4]), "has a 'MaterialFloatPropertyList' record key 'Extra' this writer does not know")
    let notList = (materialID, rwPlugin(1, .map([("MaterialFloatPropertyList", .int(3))])))
    expectRefused(rwScene([notList]), .init(deletions: [4]), "has a 'MaterialFloatPropertyList' value that is not serialized bytes")
    let deduped = (materialID, rwPlugin(1, .map([("TextureDictionary", rwPacked(.map([("hash", .bin([1]))])))])))
    expectRefused(rwScene([deduped]), .init(deletions: [4]), "has a TextureDictionary that is not MaterialEditor's Bundled int-to-bytes map")
    // Moves keep any form.
    for entry in [materialSource(version: 0), materialSource(extra: [("FutureList", .null)]), notList] {
        #expect(rwOutcome(rwScene([entry]), rwMoveItem) == "kept")
    }
}

// MARK: - NodesConstraints

/// `OnSceneSave`: per constraint its objects' indices in the key-sorted
/// `dicObjectCtrl` (-2: the main camera) and its position.
private func constraint(_ parent: Int32, _ child: Int32, _ load: Int32, _ alias: String) -> String {
    #"<constraint parentObjectIndex="\#(parent)" parentPath="" childObjectIndex="\#(child)" childPath="" position="true" rotation="false" scale="false" alias="\#(alias)" uniqueLoadId="\#(load)" />"#
}
private func constraintsEntry(_ constraints: [String]) -> (String, PluginMP) {
    let xml = constraints.isEmpty ? #"<constraints version="1.6.2.1" />"#
        : #"<constraints version="1.6.2.1">"# + constraints.joined() + "</constraints>"
    return ("nodesConstraints", rwPlugin(0, .map([("constraints", .str(xml))])))
}
/// Item 1 to item 4; the camera to character 12; item 3 to camera 11.
private let constraintsSource = constraintsEntry([constraint(1, 4, 0, "a"), constraint(-2, 8, 1, "b"), constraint(3, 7, 2, "c")])

@Test func sourceScenePluginRewritesNodesConstraintsByPosition() throws {
    let scene = rwScene([constraintsSource, rwSettings])
    func expected(_ constraints: [String]) -> Data { rwTrailer([constraintsEntry(constraints), rwSettings]) }
    // Later objects move up; a constraint with a deleted end goes, and the
    // rest are numbered by position.
    #expect(try rwTrailerAfter(scene, .init(deletions: [2])) == expected([constraint(1, 3, 0, "a"), constraint(-2, 7, 1, "b"), constraint(2, 6, 2, "c")]))
    #expect(try rwTrailerAfter(scene, .init(deletions: [1])) == expected([constraint(-2, 6, 0, "b"), constraint(1, 5, 1, "c")]))
    #expect(try rwTrailerAfter(scene, .init(deletions: [12])) == expected([constraint(1, 4, 0, "a"), constraint(3, 7, 1, "c")]))
    #expect(try rwTrailerAfter(scene, .init(deletions: [5])) == expected([constraint(1, 4, 0, "a"), constraint(-2, 7, 1, "b"), constraint(3, 6, 2, "c")]))
    #expect(try rwTrailerAfter(scene, .init(deletions: [0, 11, 12])) == expected([]))
    // A new object below existing keys shifts them: character 13 to 9.
    let hole = rwScene([constraintsEntry([constraint(1, 4, 0, "a"), constraint(-2, 8, 1, "b")]), rwSettings], hole: true)
    #expect(try rwTrailerAfter(hole, rwAddFolder) == expected([constraint(1, 4, 0, "a"), constraint(-2, 9, 1, "b")]))
    // Copies after every key, of one end only, or of both ends of a
    // constraint after the first camera-parented one (where the duplicate
    // patch stops): nothing to write.
    let afterCamera = SourceSceneEdits(insertions: [.init(.duplicate(of: 3), parent: .source(0)), .init(.duplicate(of: 11))])
    for edits in [rwCopyItem, rwCopyPair, rwCopyCharacter, afterCamera, rwAddFolder, rwMoveItem] {
        #expect(rwOutcome(scene, edits) == "kept")
    }
    #expect(try rwTrailerAfter(scene, .init(deletions: [2])) != scene.trailer)
}

@Test func sourceScenePluginRewritesNodesConstraintsRefusesWhatItsRuleDoesNotCover() throws {
    let label = "NodesConstraints data ('nodesConstraints')"
    func expectRefused(_ scene: TopologyScene, _ edits: SourceSceneEdits, _ reason: String,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        let result = rwOutcome(scene, edits)
        #expect(result.hasPrefix("Original-scene export cannot ") && result.contains("\(label) \(reason)"), "\(result)",
                sourceLocation: sourceLocation)
    }
    let scene = rwScene([constraintsSource])
    // Both ends copied before the first camera-parented constraint: the
    // duplicate patch gives the copies a copy of the constraint.
    let bothEnds = SourceSceneEdits(insertions: [.init(.duplicate(of: 1), parent: .source(0)),
                                                 .init(.duplicate(of: 2), parent: .inserted(0)), .init(.duplicate(of: 4))])
    expectRefused(scene, bothEnds, "gives the copies of objects 1 and 4 a copy of their constraint when both are copied")
    // Deletes and copies in one edit, with constraints left (#278).
    expectRefused(scene, .init(deletions: [5], insertions: [.init(.duplicate(of: 4))]),
                  "addresses objects by their position in key order, and this edit both deletes and copies objects")
    #expect(try rwTrailerAfter(scene, .init(deletions: [0, 11, 12], insertions: [.init(.duplicate(of: 4))])) == rwTrailer([constraintsEntry([])]))
    // Timeline may animate constraints by number.
    let timeline = ("timeline", rwPlugin(0, .map([("sceneInfo", .str(#"<root><interpolable owner="NodesConstraints" id="constraint" /></root>"#))])))
    let animated = rwScene([constraintsSource, timeline])
    expectRefused(animated, .init(deletions: [1]), "numbers its constraints by position, and this edit removes or renumbers constraints that this scene's Timeline data may animate by number")
    #expect(rwOutcome(animated, .init(deletions: [5])) == "rewritten")   // indices change, numbers do not
    // Repeated pairs, in either direction.
    for repeated in [constraint(1, 4, 1, "x"), constraint(4, 1, 1, "x")] {
        expectRefused(rwScene([constraintsEntry([constraint(1, 4, 0, "a"), repeated])]), .init(deletions: [5]),
                      "has two constraints between the same transforms, of which NodesConstraints loads only the first")
    }
    #expect(rwOutcome(rwScene([constraintsEntry([constraint(1, 4, 0, "a"), constraint(4, 3, 1, "x")])]), .init(deletions: [2])) == "rewritten")
    // Forms NodesConstraints does not write; kept for moves and new objects
    // above every key, as before.
    let forms: [(String, String)] = [
        (#"<constraints version="1"><constraint parentObjectIndex="0" childObjectIndex="3" /></constraints>"#,
         "has a constraint without parentObjectIndex, childObjectIndex and uniqueLoadId"),
        (#"<constraints version="1"><other /></constraints>"#, "has an element other than an empty constraint under its root"),
        (#"<constraints version="1"><constraint parentObjectIndex="1" childObjectIndex="4" uniqueLoadId="0"/></constraints>"#,
         "has constraints that are not in the XML form NodesConstraints writes (a malformed start tag at byte"),
        (#"<nodes version="1"><constraint /></nodes>"#, "has constraints whose root is not NodesConstraints' <constraints version=…>"),
        (#"<constraints version="1">"# + constraint(1, 20, 0, "a") + "</constraints>", "has a constraint on object index 20, which this scene does not have"),
        (#"<constraints version="1">"# + constraint(-1, 4, 0, "a") + "</constraints>", "has a constraint on object index -1, which this scene does not have"),
        (#"<constraints version="1">"# + constraint(1, 4, 0, "a").replacingOccurrences(of: #"uniqueLoadId="0""#, with: #"uniqueLoadId="00""#) + "</constraints>",
         "has constraints NodesConstraints does not write (constraint has a uniqueLoadId that is not a canonical Int32)"),
    ]
    for (xml, reason) in forms {
        let form = rwScene([("nodesConstraints", rwPlugin(0, .map([("constraints", .str(xml))])))])
        expectRefused(form, .init(deletions: [5]), reason)
        expectRefused(form, rwCopyItem, reason)
        for edits in [rwAddFolder, rwMoveItem] { #expect(rwOutcome(form, edits) == "kept", "\(xml)") }
    }
}

// MARK: - Rule parity corpus

private func rwTimeline(_ xml: String) -> (String, PluginMP) { ("timeline", rwPlugin(0, .map([("sceneInfo", .str(xml))]))) }

/// The rewrite rules' entry forms for the rule parity corpus
/// (SourceScenePluginDataTests `ruleCorpusScenes`), each with the card its
/// KKPE rule reads: alone, and with a settings entry in the scene whose
/// character sits above a free key.
func pluginRewriteCorpusScenes() -> [TopologyScene] {
    let card = kkpeCard(-50000)
    // KKPE data whose characterInfo is not KKPE's form (a non-canonical ID).
    let info = #"<characterInfo version="2.21.4" uniqueId="-050000" />"#
    let ext = PluginMP.map([("kkpe", rwPlugin(0, .map([("characterInfo", .str(info))])))])
    let broken = OriginalCardFixture.card(blocks: OriginalCardFixture.blocks() + [OriginalCardFixture.Block(name: "KKEx", version: "3", data: Data(ext.bytes))])
    let filler = (5...9).map { #"<id uniqueId="-\#($0)" />"# }.joined()
    let full = kkpeRoot([kkpeItem(1, -1, filler), kkpeItem(2, -2), kkpeItem(3, -3), kkpeItem(4, -4)])
    let shared = kkpeRoot([kkpeItem1, kkpeItem(2, -41286, kkpeBones), kkpeCollider([kkpeBoneReference(-41286)]), kkpeItem4])
    let kkpeForms = [#"<root version="2.21.4"> </root>"#, kkpeRoot([kkpeItem1, kkpeItem2, kkpeItem(3, -41274)]),
                     "<root>" + [kkpeItem1, kkpeItem2, kkpeItem(3, -41274), kkpeItem4].joined() + "</root>",
                     kkpeRoot([kkpeItem1, kkpeItem2, kkpeItem4, kkpeItem(3, -41274)]),
                     kkpeRoot([kkpeItem1, kkpeItem2, kkpeCollider([#"<dynamicBoneData root="Bone" />"#]), kkpeItem4])]
    let stale = materialEntry(floats: [materialFloat(1), materialFloat(13)], colors: [], textures: [], dictionary: [])
    let extraKey = materialEntry(floats: [.map([("ID", .int(4)), ("Extra", .int(1))])], colors: [], textures: [], dictionary: [])
    let deduped = (materialID, rwPlugin(1, .map([("TextureDictionary", rwPacked(.map([("hash", .bin([1]))])))])))
    let textureTrack = rwTimeline(#"<root><interpolable id="textureProperty" /></root>"#)
    let constraintTrack = rwTimeline(#"<root><interpolable owner="NodesConstraints" id="constraint" /></root>"#)
    func nodes(_ xml: String) -> (String, PluginMP) { ("nodesConstraints", rwPlugin(0, .map([("constraints", .str(xml))]))) }
    let constraintForms = [#"<constraints version="1"><constraint parentObjectIndex="0" childObjectIndex="3" /></constraints>"#,
                           #"<constraints version="1">"# + constraint(1, 20, 0, "a") + "</constraints>",
                           #"<constraints version="1"><other /></constraints>"#,
                           #"<constraints version="1">"# + constraint(1, 4, 0, "a").replacingOccurrences(of: " />", with: "/>") + "</constraints>"]
    let staleOld = materialEntry(floats: [materialFloat(1), materialFloat(13)], colors: [], textures: [], dictionary: [], version: 0)
    var lists: [([(String, PluginMP)], Data?)] = [
        ([kkpeEntry(kkpeLinked)], card), ([kkpeEntry(kkpePlain)], card), ([kkpeEntry(kkpePlain)], kkpeCard(-50000, legacy: true)),
        ([kkpeEntry(kkpePlain)], kkpeCard(-41285)), ([kkpeEntry(kkpeLinked)], broken), ([kkpeEntry(kkpePlain)], broken),
        ([kkpeEntry(full)], nil), ([kkpeEntry(shared)], card), ([kkpeEntry(kkpeRoot([]))], card),
        ([("kkpe", rwPlugin(0, .map([("sceneInfo", .str(kkpePlain)), ("future", .int(1))])))], card),
        ([materialSource()], nil), ([materialSource(version: 0)], nil), ([stale], nil), ([materialSource(), textureTrack], nil),
        ([materialSource(extra: [("FutureList", .null)])], nil), ([extraKey], nil), ([deduped], nil),
        ([constraintsSource], nil), ([constraintsSource, constraintTrack], nil),
        ([constraintsEntry([constraint(1, 4, 0, "a"), constraint(4, 1, 1, "x")])], nil),
        ([constraintsEntry([constraint(1, 4, 0, "a"), constraint(4, 3, 1, "x")])], nil), ([staleOld], nil),
        // Item 1 and its child 2: a copy of either copies both ends, unless a
        // camera-parented constraint comes first.
        ([constraintsEntry([constraint(1, 2, 0, "a")])], nil), ([constraintsEntry([constraint(-2, 8, 0, "b"), constraint(1, 2, 1, "a")])], nil),
        ([kkpeEntry(kkpeLinked), materialSource(), constraintsSource, rwTimeline(#"<root><interpolable id="camera" /></root>"#)], card),
    ]
    for xml in kkpeForms { lists.append(([kkpeEntry(xml)], card)) }
    for xml in constraintForms { lists.append(([nodes(xml)], nil)) }
    var scenes: [TopologyScene] = []
    for (entries, card) in lists {
        scenes.append(rwScene(entries, card: card))
        scenes.append(rwScene(entries + [rwSettings], hole: true, card: card))
    }
    return scenes
}
