import Foundation
import Testing
import Assets
import Character
@testable import Studio

// ST-T03i: the plug-in (ExtendedSave) trailer through object edits. Each
// scene is written field by field (TopologyScene) with a trailer built here,
// and each expected trailer is built from its final records, independently
// of the writer's byte patching.

// MARK: - MessagePack as MessagePack-CSharp 1.x writes it

/// A MessagePack value in MessagePack-CSharp 1.x's shortest encodings,
/// written here independently of `SourceMessagePackWriter`.
indirect enum PluginMP {
    case int(Int64), str(String), bin([UInt8]), arr([PluginMP]), null, bool(Bool), f32(Float)
    case map([(String, PluginMP)])
    /// An integer-keyed map (`Dictionary<int, T>`).
    case imap([(Int64, PluginMP)])
    /// Bytes written as given (a non-canonical encoding).
    case raw([UInt8])

    static func bigEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }
    static func header(_ count: Int, fix: UInt8, _ two: UInt8, _ four: UInt8) -> [UInt8] {
        if count <= 15 { return [fix | UInt8(count)] }
        if count <= 0xffff { return [two] + bigEndian(UInt64(count), 2) }
        return [four] + bigEndian(UInt64(count), 4)
    }
    static func integer(_ value: Int64) -> [UInt8] {
        if value >= 0 {
            if value <= 0x7f { return [UInt8(value)] }
            if value <= 0xff { return [0xcc, UInt8(value)] }
            if value <= 0xffff { return [0xcd] + bigEndian(UInt64(value), 2) }
            if value <= 0xffff_ffff { return [0xce] + bigEndian(UInt64(value), 4) }
            return [0xcf] + bigEndian(UInt64(value), 8)
        }
        let bits = UInt64(bitPattern: value)
        if value >= -32 { return [UInt8(truncatingIfNeeded: bits)] }
        if value >= -128 { return [0xd0, UInt8(truncatingIfNeeded: bits)] }
        if value >= -32_768 { return [0xd1] + bigEndian(bits, 2) }
        if value >= Int64(Int32.min) { return [0xd2] + bigEndian(bits, 4) }
        return [0xd3] + bigEndian(bits, 8)
    }

    var bytes: [UInt8] {
        switch self {
        case .null: return [0xc0]
        case .bool(let value): return [value ? 0xc3 : 0xc2]
        case .f32(let value): return [0xca] + Self.bigEndian(UInt64(value.bitPattern), 4)
        case .raw(let bytes): return bytes
        case .int(let value): return Self.integer(value)
        case .str(let text):
            let utf8 = Array(text.utf8)
            if utf8.count <= 31 { return [0xa0 | UInt8(utf8.count)] + utf8 }
            if utf8.count <= 0xff { return [0xd9, UInt8(utf8.count)] + utf8 }
            if utf8.count <= 0xffff { return [0xda] + Self.bigEndian(UInt64(utf8.count), 2) + utf8 }
            return [0xdb] + Self.bigEndian(UInt64(utf8.count), 4) + utf8
        case .bin(let bytes):
            if bytes.count <= 0xff { return [0xc4, UInt8(bytes.count)] + bytes }
            if bytes.count <= 0xffff { return [0xc5] + Self.bigEndian(UInt64(bytes.count), 2) + bytes }
            return [0xc6] + Self.bigEndian(UInt64(bytes.count), 4) + bytes
        case .arr(let values):
            return Self.header(values.count, fix: 0x90, 0xdc, 0xdd) + values.flatMap(\.bytes)
        case .map(let entries):
            return Self.header(entries.count, fix: 0x80, 0xde, 0xdf) + entries.flatMap { PluginMP.str($0.0).bytes + $0.1.bytes }
        case .imap(let entries):
            return Self.header(entries.count, fix: 0x80, 0xde, 0xdf) + entries.flatMap { Self.integer($0.0) + $0.1.bytes }
        }
    }
}

/// `PluginData`: `[version, data]`.
private func plugin(_ version: Int64, _ data: PluginMP) -> PluginMP { .arr([.int(version), data]) }
/// Serialized data a plug-in stores as bytes in its `PluginData` map.
private func packed(_ value: PluginMP) -> PluginMP { .bin(value.bytes) }

/// ExtendedSave's scene trailer: the .NET string "KKEx", data version 3,
/// the payload length, then `Dictionary<string, PluginData>`. `header` and
/// `keys` replace the map header and an entry's key bytes.
private func pluginTrailer(_ entries: [(String, PluginMP)], header: [UInt8]? = nil, keys: [String: [UInt8]] = [:]) -> Data {
    var payload = header ?? PluginMP.header(entries.count, fix: 0x80, 0xde, 0xdf)
    for (id, value) in entries { payload += (keys[id] ?? PluginMP.str(id).bytes) + value.bytes }
    var out: [UInt8] = [4] + Array("KKEx".utf8)
    withUnsafeBytes(of: Int32(3).littleEndian) { out += $0 }
    withUnsafeBytes(of: Int32(payload.count).littleEndian) { out += $0 }
    return Data(out + payload)
}

// MARK: - Scene

private let sideloaderID = "com.bepis.sideloader.universalautoresolver"
private let settingsID = "com.deathweasel.bepinex.studioscenesettings"
private let settings = (settingsID, plugin(0, .map([("NearClipPlane", .f32(0.1)), ("ShadowDistance", .f32(40))])))

/// 0 folder [1 item [2 item], 3 item], 4 item, 5 light, 6 route (points 7
/// and 9, aids 8 and 10), 11 camera, 12 character (look-at target 104).
/// With `hole` the character is 13: key 12 is free, and the next new object
/// takes it, below the character in key order.
private func pluginScene(_ entries: [(String, PluginMP)]?, hole: Bool = false, card: Data? = nil) -> TopologyScene {
    let groups: [(point: Int32, children: [TopologyNode])] = [(point: Int32(0), children: [TopologyNode]())]
    let character: Int32 = hole ? 13 : 12
    let folder = TopologyNode.folder(0, [.item(1, [.item(2, [])]), .item(3, [])])
    var scene = TopologyScene(roots: [folder, .item(4, []), .light(5), .route(6, []), .camera(11, active: false),
                                      .character(character, groups)])
    scene.routePoints[6] = [TopologyRoutePoint(key: 7, position: .zero, aidKey: 8),
                            TopologyRoutePoint(key: 9, position: SIMD3(0, 0, 1), aidKey: 10)]
    if let entries { scene.trailer = pluginTrailer(entries) }
    if let card { scene.cards[character] = card }
    return scene
}

private let addFolder = SourceSceneEdits(insertions: [.init(.folder(name: "New"))])
private let addLight = SourceSceneEdits(insertions: [.init(.light(SourceSceneNewLight(no: 0)))])
private let addCamera = SourceSceneEdits(insertions: [.init(.camera(name: "New"))])
/// Folder 0 with its items: copies 13 [14 [15], 16] (Studio.Duplicate).
private let copyFolder = SourceSceneEdits(insertions: [
    .init(.duplicate(of: 0)), .init(.duplicate(of: 1), parent: .inserted(0)),
    .init(.duplicate(of: 2), parent: .inserted(1)), .init(.duplicate(of: 3), parent: .inserted(0))])
private let copyItem = SourceSceneEdits(insertions: [.init(.duplicate(of: 4))])
private let copyLight = SourceSceneEdits(insertions: [.init(.duplicate(of: 5))])
/// Item 4 into folder 0, after item 3: no object's walk position changes.
private let moveItem = SourceSceneEdits(reparents: [.init(object: 4, parent: 0)])

/// `OCIRoute.AddPoint` on route 6.
private func addPoint(hole: Bool = false) throws -> SourceSceneEdits {
    let document = try KoikatsuSceneReader.decodeDocument(pluginScene(nil, hole: hole).data)
    let route = try #require(document.snapshot.roots.first { $0.sourceKey == 6 }?.route)
    var state = SourceStudioRouteState(record: route)
    _ = try state.addPoint()
    return .init(routes: [6: state])
}

/// "kept" (the trailer as it was), "rewritten", or the refusal.
private func verdict(_ scene: TopologyScene, _ edits: SourceSceneEdits) -> String {
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

private func trailer(_ scene: TopologyScene, _ edits: SourceSceneEdits) throws -> Data {
    let original = try KoikatsuSceneReader.decodeDocument(scene.data)
    return try KoikatsuSceneReader.decodeDocument(original.editedData(edits)).trailingData
}

// MARK: - Sideloader

/// One Sideloader record: the object it was written for (its fields), and
/// the key and per-kind walk position it carries.
private struct Record {
    let origin: Int32, key: Int32, order: Int32
    init(_ origin: Int32, _ key: Int32, _ order: Int32) { self.origin = origin; self.key = key; self.order = order }

    /// `StudioResolveInfo` (MessagePackObject(true)) in its field order.
    var item: PluginMP {
        packed(.map([("ModID", .str("mod.\(origin)")), ("Slot", .int(Int64(origin) + 100)),
                     ("LocalSlot", .int(100_000_000 + Int64(origin))), ("SceneDicKey", .int(Int64(key))),
                     ("SceneObjectOrder", .int(Int64(order))), ("ResolveItem", .bool(true)), ("Group", .int(1)),
                     ("Category", .int(2)), ("Author", .str("author")), ("Website", .str("")), ("Name", .str("mod \(origin)"))]))
    }
    var pattern: PluginMP {
        packed(.map([("SceneDicKey", .int(Int64(key))), ("SceneObjectOrder", .int(Int64(order))),
                     ("ObjectPatternInfo", .map([("1", .str("pattern.\(origin)"))]))]))
    }
}

private func sideloader(_ items: [Record], _ patterns: [Record] = [], map: Bool = true) -> PluginMP {
    var fields: [(String, PluginMP)] = []
    if !items.isEmpty { fields.append(("itemInfo", .arr(items.map(\.item)))) }
    if !patterns.isEmpty { fields.append(("patternInfo", .arr(patterns.map(\.pattern)))) }
    if map { fields.append(("mapInfoGUID", .str("map.guid"))) }
    return plugin(0, .map(fields))
}

@Test func sourceScenePluginDataRewritesSideloaderRecordsInCharaStudioOrder() throws {
    // Items 1-4 are items 0-3 in the walk, light 5 light 0, character 12
    // (a mod animation) character 0; item 3 has mod patterns.
    let items = [Record(1, 1, 0), Record(2, 2, 1), Record(3, 3, 2), Record(4, 4, 3), Record(5, 5, 0), Record(12, 12, 0)]
    let patterns = [Record(3, 3, 2)]
    func scene(_ items: [Record], _ patterns: [Record], map: Bool = true) -> TopologyScene {
        pluginScene([(sideloaderID, sideloader(items, patterns, map: map)), settings])
    }
    let original = scene(items, patterns)
    // Deleting item 1 with its child 2: items 3 and 4 move up.
    let deleted = try trailer(original, .init(deletions: [1]))
    #expect(deleted == scene([Record(3, 3, 0), Record(4, 4, 1), Record(5, 5, 0), Record(12, 12, 0)], [Record(3, 3, 0)]).trailer)
    // Copying folder 0: each copy takes its template's records under its
    // key and position, after the source objects in the walk.
    let copies = [Record(1, 14, 4), Record(2, 15, 5), Record(3, 16, 6)]
    let copied = try trailer(original, copyFolder)
    #expect(copied == scene(items + copies, patterns + [Record(3, 16, 6)]).trailer)
    // Moving item 3 to the root puts it last in the walk.
    let moved = try trailer(original, .init(reparents: [.init(object: 3, parent: nil)]))
    let movedItems = [Record(1, 1, 0), Record(2, 2, 1), Record(4, 4, 2), Record(5, 5, 0), Record(12, 12, 0), Record(3, 3, 3)]
    #expect(moved == scene(movedItems, [Record(3, 3, 3)]).trailer)
    // A light and a character leave only their own records.
    let others = try trailer(original, .init(deletions: [5, 12]))
    #expect(others == scene(Array(items.prefix(4)), patterns).trailer)
    // No record left: the scene identities stay; without them CharaStudio
    // removes the entry (SetSceneExtendedDataById(id, null)).
    let everything = SourceSceneEdits(deletions: [0, 4, 5, 12])
    #expect(try trailer(original, everything) == scene([], []).trailer)
    let bare = pluginScene([(sideloaderID, sideloader(items, patterns, map: false)), settings])
    #expect(try trailer(bare, everything) == pluginTrailer([settings]))
    // Edits that leave every record in place keep the trailer byte for byte.
    for edits in [addFolder, addLight, moveItem, try addPoint()] {
        #expect(verdict(original, edits) == "kept")
    }
}

@Test func sourceScenePluginDataRefusesSideloaderRecordsItCannotPlace() throws {
    let label = "Sideloader data ('\(sideloaderID)')"
    let cases: [([Record], String)] = [
        ([Record(99, 99, 0)], "has a record for object 99, which the scene does not have"),
        ([Record(0, 0, 0)], "has a record for object 0, a folder rather than an item, light or character"),
        ([Record(4, 4, 3), Record(4, 4, 3)], "has two records for object 4"),
    ]
    for (records, reason) in cases {
        let scene = pluginScene([(sideloaderID, sideloader(records))])
        let text = verdict(scene, .init(deletions: [1]))
        #expect(text == "Original-scene export cannot delete objects in this scene: \(label) \(reason). Save in native format instead.")
        // A move keeps the entry as before.
        #expect(verdict(scene, .init(reparents: [.init(object: 3, parent: nil)])) == "kept")
    }
    let unknownKey = plugin(0, .map([("itemInfo", .arr([])), ("futureInfo", .int(1))]))
    #expect(verdict(pluginScene([(sideloaderID, unknownKey)]), copyItem).contains("\(label) has a data key 'futureInfo' this writer does not know"))
    let unknownField = plugin(0, .map([("itemInfo", .arr([packed(.map([("SceneDicKey", .int(4)), ("SceneObjectOrder", .int(3)), ("Extra", .null)]))]))]))
    #expect(verdict(pluginScene([(sideloaderID, unknownField)]), copyItem).contains("\(label) has a record key 'Extra' this writer does not know"))
    #expect(verdict(pluginScene([(sideloaderID, plugin(1, .map([])))]), copyItem).contains("\(label) has version 1, which this writer has not recovered"))
}

// MARK: - Trailer framing

@Test func sourceScenePluginDataKeepsOtherEntriesBytesAndWritesCanonicalFraming() throws {
    // A map16 header, an entry key written as str8 and a version written as
    // an Int32: kept entries are copied byte for byte, and the dictionary
    // header is written as MessagePack-CSharp writes it.
    let odd = PluginMP.raw([0x92, 0xd2, 0, 0, 0, 0] + PluginMP.map([("Lut", .str("lut.png"))]).bytes)
    let oddKey: [UInt8] = [0xd9, 12] + Array("TwoLutPlugin".utf8)
    let orphan = ("KKVMDPlayExtSave", plugin(0, .map([("motion", .bin([1, 2, 3]))])))
    func entries(_ records: [Record]) -> [(String, PluginMP)] {
        [("TwoLutPlugin", odd), (sideloaderID, sideloader(records)), orphan, settings]
    }
    var scene = pluginScene(nil)
    scene.trailer = pluginTrailer(entries([Record(4, 4, 3)]), header: [0xde, 0, 4], keys: ["TwoLutPlugin": oddKey])
    let expected = pluginTrailer(entries([Record(4, 4, 1)]), keys: ["TwoLutPlugin": oddKey])
    #expect(try trailer(scene, .init(deletions: [1])) == expected)
    #expect(try KoikatsuSceneReader.decodeDocument(scene.data).orphanPluginIDs == ["KKVMDPlayExtSave"])
    // No trailer, an empty map and a nil map: the edit's bytes as before.
    for value in [nil, pluginTrailer([])] as [Data?] {
        var plain = pluginScene(nil)
        if let value { plain.trailer = value }
        #expect(verdict(plain, copyFolder) == "kept")
    }
}

@Test func sourceScenePluginDataDropsNilEntriesOnlyWhenItRewrites() throws {
    // ExtendedSave's save hook removes nil entries; a rewrite does the same.
    let scene = pluginScene([(sideloaderID, sideloader([Record(4, 4, 3)])), ("example.nil", .null), settings])
    let expected = pluginTrailer([(sideloaderID, sideloader([Record(4, 4, 1)])), settings])
    #expect(try trailer(scene, .init(deletions: [1])) == expected)
    // With nothing else to change the trailer stays as it was: a nil entry
    // is inert for any ID, and the next CharaStudio save drops it.
    #expect(verdict(pluginScene([("example.nil", .null), settings]), .init(deletions: [1])) == "kept")
}

@Test func sourceScenePluginDataRefusesUnreadableTrailersAndUnknownEntriesByName() throws {
    let unknown = ("example.scene", plugin(0, .map([("objects", packed(.arr([.int(4)])))])))
    let scene = pluginScene([unknown, settings])
    let reason = "plug-in data 'example.scene' has no rule in this writer for following object edits (its plug-in's save, copy and delete code is not recovered here)"
    // Unknown means unknown: deletions, copies, new objects and route points.
    let refusals: [(SourceSceneEdits, String)] = [
        (.init(deletions: [4]), "delete objects"), (copyItem, "duplicate objects"), (addFolder, "add objects"),
        (try addPoint(), "add or delete route points"),
    ]
    for (edits, action) in refusals {
        #expect(verdict(scene, edits) == "Original-scene export cannot \(action) in this scene: \(reason). Save in native format instead.")
    }
    // Moves and in-place edits keep every key, so the entry is kept.
    #expect(verdict(scene, moveItem) == "kept")
    #expect(verdict(scene, .init(names: [0: "Renamed"])) == "kept")
    // Every refused entry is named in one refusal.
    let second = ("example.other", plugin(0, .map([])))
    let both = verdict(pluginScene([unknown, settings, second]), .init(deletions: [4]))
    #expect(both.contains("plug-in data 'example.scene' has no rule") && both.contains("; plug-in data 'example.other' has no rule"))
    // A recovered ID with an unrecovered version or shape.
    let cases: [((String, PluginMP), String)] = [
        ((settingsID, plugin(1, .map([]))), "StudioSceneSettings data ('\(settingsID)') has version 1, which this writer has not recovered"),
        (("kkpe", plugin(2, .map([]))), "KKPE data ('kkpe') has version 2, which this writer has not recovered"),
        (("kkpe", .int(5)), "KKPE data ('kkpe') is not a [version, data] PluginData value"),
    ]
    for (entry, text) in cases { #expect(verdict(pluginScene([entry]), .init(deletions: [4])).contains(text)) }
    // Data a rule reads but cannot parse is unknown data: refused by name
    // for an edit that changes the objects, kept for a move.
    let unreadable = ("com.deathweasel.bepinex.materialeditor", plugin(1, .int(5)))
    #expect(verdict(pluginScene([unreadable]), .init(deletions: [4]))
        .contains("MaterialEditor data ('com.deathweasel.bepinex.materialeditor') has data this writer cannot read"))
    #expect(verdict(pluginScene([unreadable]), moveItem) == "kept")
    // Orphans (no installed plug-in reads or writes them) are kept.
    let orphan = pluginScene([("vnge_sss", plugin(0, .map([("objects", packed(.arr([.int(4)])))])))])
    for edits in [SourceSceneEdits(deletions: [4]), copyItem, addFolder] { #expect(verdict(orphan, edits) == "kept") }
    // A trailer that is not ExtendedSave data, or not exactly one map.
    let valid = pluginTrailer([settings])
    var extra = valid; extra.append(0xc0)
    var data = Array(extra); data[9] = UInt8(truncatingIfNeeded: Int(data[9]) + 1); extra = Data(data)
    let twice = pluginTrailer([settings, settings])
    for (bytes, text) in [(extra, "bytes follow the KKEx map"), (twice, "appears twice"), (Data([0, 255, 3]), "not ExtendedSave's KKEx block")] {
        var unreadable = pluginScene(nil); unreadable.trailer = bytes
        let refused = verdict(unreadable, .init(deletions: [4]))
        #expect(refused.contains("is not readable ExtendedSave data") && refused.contains(text), "\(refused)")
        #expect(verdict(unreadable, moveItem) == "kept")
    }
}

// MARK: - Positional data

@Test func sourceScenePluginDataKeepsPositionalDataOnlyWhilePositionsHold() throws {
    let route = try addPoint()
    // KKPE: one element per item in key order.
    let kkpe = [("kkpe", plugin(0, .map([("sceneInfo", .str("<root><item /></root>"))])))]
    for edits in [SourceSceneEdits(deletions: [5]), addFolder, addLight, moveItem, route] {
        #expect(verdict(pluginScene(kkpe), edits) == "kept")
    }
    let items = "KKPE data ('kkpe') matches its pose data to items by their position in key order, and this edit adds or removes items"
    #expect(verdict(pluginScene(kkpe), .init(deletions: [4])).contains(items))
    // Indirectly: copying a folder copies its items.
    #expect(verdict(pluginScene(kkpe), copyFolder).contains("cannot duplicate objects in this scene: \(items)"))
    // NodesConstraints and Timeline: indices in the key-sorted dicObjectCtrl.
    let constraints = [("nodesConstraints", plugin(0, .map([("constraints", .str(
        #"<constraints version="1"><constraint parentObjectIndex="0" childObjectIndex="3" /></constraints>"#))])))]
    let timeline = [("timeline", plugin(0, .map([("sceneInfo", .str(#"<root><interpolable objectIndex="3" /></root>"#))])))]
    let cases: [([(String, PluginMP)], String)] = [
        (constraints, "NodesConstraints data ('nodesConstraints')"), (timeline, "Timeline data ('timeline')"),
    ]
    for (entries, label) in cases {
        let shifted = "\(label) addresses objects by their index among all objects in key order, and this edit removes, copies or renumbers some"
        // A new object above every key, route points and moves keep each
        // object's index.
        for edits in [addFolder, addCamera, moveItem, route] { #expect(verdict(pluginScene(entries), edits) == "kept") }
        #expect(verdict(pluginScene(entries), .init(deletions: [5])).contains(shifted))
        #expect(verdict(pluginScene(entries), copyItem).contains(shifted))
        // Indirectly: a new folder takes the free key 12, below character 13.
        #expect(verdict(pluginScene(entries, hole: true), addFolder).contains("cannot add objects in this scene: \(shifted)"))
        // A route point taking the free key is not an object.
        #expect(verdict(pluginScene(entries, hole: true), try addPoint(hole: true)) == "kept")
    }
    // Timeline with global interpolables only names no object.
    let global = [("timeline", plugin(0, .map([("sceneInfo", .str("<root><interpolable id=\"camera\" /></root>"))])))]
    #expect(verdict(pluginScene(global), .init(deletions: [4])) == "kept")
}

@Test func sourceScenePluginDataJudgesRoutePointsAndNewObjectsOnTheWrittenKeys() throws {
    // Route points take keys from the scene's counter, but they are not in
    // dicObjectCtrl (AddObjectRoute.LoadPoint registers each with
    // Studio.AddCtrlInfo, which fills dicInfo only), so no plug-in indexes
    // them. In one export adding a folder and a route point, the folder is
    // written first and takes the smallest free key; the rule reads the
    // keys the export writes.
    let constraints = [("nodesConstraints", plugin(0, .map([("constraints", .str(
        #"<constraints version="1"><constraint parentObjectIndex="0" childObjectIndex="3" /></constraints>"#))])))]
    for hole in [false, true] {
        var edits = try addPoint(hole: hole)
        edits.insertions = [.init(.folder(name: "New"))]
        let plain = try KoikatsuSceneReader.decodeDocument(pluginScene(nil, hole: hole).data)
        let written = try KoikatsuSceneReader.decodeDocument(plain.editedData(edits)).snapshot
        let route = try #require(written.roots.first { $0.sourceKey == 6 }?.route)
        #expect(written.roots.last?.sourceKey == (hole ? 12 : 13))
        #expect(route.points.map(\.bone.sourceKey) == [7, 9, 14] && route.points.map(\.aid.sourceKey) == [8, 10, 15])
        let result = verdict(pluginScene(constraints, hole: hole), edits)
        if hole {
            #expect(result.contains("cannot add objects or add or delete route points in this scene: NodesConstraints data"))
        } else {
            #expect(result == "kept")
        }
    }
}

// MARK: - Data keyed by object

@Test func sourceScenePluginDataFollowsObjectKeyedRules() throws {
    func expectKept(_ entry: (String, PluginMP), _ edits: [SourceSceneEdits], sourceLocation: SourceLocation = #_sourceLocation) {
        for edit in edits { #expect(verdict(pluginScene([entry]), edit) == "kept", sourceLocation: sourceLocation) }
    }
    func expectRefused(_ entry: (String, PluginMP), _ edits: [SourceSceneEdits], _ text: String,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        for edit in edits {
            let result = verdict(pluginScene([entry]), edit)
            #expect(result.contains(text), "\(result)", sourceLocation: sourceLocation)
        }
    }
    let named = "names objects by key, and this edit deletes or copies one of them"
    let deleted = "names objects by key, and this edit deletes one of them"
    // MaterialEditor: item keys. Every list nil is the empty form.
    let materialID = "com.deathweasel.bepinex.materialeditor"
    let emptyMaterial = (materialID, plugin(1, .map(MaterialEditorForm.keys.sorted().map { ($0, PluginMP.null) })))
    expectKept(emptyMaterial, [.init(deletions: [4]), copyFolder])
    let material = (materialID, plugin(1, .map([("MaterialShaderList", packed(.arr([.map([("ID", .int(4))])])))])))
    expectKept(material, [.init(deletions: [5]), addFolder, moveItem])
    let materialReason = "MaterialEditor data ('\(materialID)') keys its material edits by item, and this edit deletes or copies items"
    expectRefused(material, [.init(deletions: [4]), copyFolder], materialReason)
    // StudioCustomMasking: folder keys.
    let maskingID = "com.deathweasel.bepinex.studiocustommasking"
    let masking = (maskingID, plugin(0, .map([("MaskingFolders", packed(.arr([.int(0)])))])))
    expectKept(masking, [.init(deletions: [4]), copyItem, addFolder])
    expectRefused(masking, [.init(deletions: [0]), copyFolder], "StudioCustomMasking data ('\(maskingID)') \(named)")
    expectKept((maskingID, plugin(0, .map([("MaskingFolders", .null)]))), [.init(deletions: [0]), copyFolder])
    // ItemLayerEdit: item keys; the copy takes the layer.
    let layers = ("keelhauled.itemlayeredit", plugin(0, .map([("SavedLayers", packed(.arr([.map([("ObjectId", .int(4)), ("Layer", .int(10))])])))])))
    expectKept(layers, [.init(deletions: [3]), copyFolder])
    expectRefused(layers, [.init(deletions: [4]), copyItem], "ItemLayerEdit data ('keelhauled.itemlayeredit') \(named)")
    // RealPOV and MoarCamz: copies are not handled, so only a delete counts.
    let pov = ("keelhauled.realpov", plugin(0, .map([("PovData", packed(.map([("CharaId", .int(12)), ("Fov", .f32(45))])))])))
    expectKept(pov, [.init(deletions: [4]), addFolder])
    expectRefused(pov, [.init(deletions: [12])], "RealPOV data ('keelhauled.realpov') \(deleted)")
    let moarID = "orange.spork.moarcamzplugin"
    let moar = (moarID, plugin(0, .map([("MoarCamz", packed(.arr([.map([("CenterTarget", .int(4))])]))), ("MoarCamzLastSelection", .int(0))])))
    expectKept(moar, [copyItem, .init(deletions: [3])])
    expectRefused(moar, [.init(deletions: [4])], "MoarCamz data ('\(moarID)') \(deleted)")
    // BetterScaling: hierarchy-scaled object keys; a copy is scaled too.
    let scaling = ("BetterScalingData", plugin(0, .map([("BetterScalingData_scaledFoldersFlag", .bool(true)),
                                                        ("BetterScalingData_scaledOCI", packed(.arr([.int(3)])))])))
    expectKept(scaling, [.init(deletions: [4]), copyItem])
    expectRefused(scaling, [.init(deletions: [0]), copyFolder], "BetterScaling data ('BetterScalingData') \(named)")
    // LightSettings: one record per light (-10 the character light), and
    // every live light gets one, so a new or copied light changes it.
    let lightRecords = PluginMP.arr([.map([("ObjectId", .int(-10)), ("Shadow", .bool(true))]), .map([("ObjectId", .int(5))])])
    let lights = ("LightSettingsData", plugin(0, .map([("LightSettingsData_lights", packed(lightRecords)),
                                                      ("LightSettingsData_cookies", .null)])))
    expectKept(lights, [.init(deletions: [4]), addFolder, copyItem])
    expectRefused(lights, [.init(deletions: [5]), copyLight], "LightSettings data ('LightSettingsData') \(named)")
    let characterLight = ("LightSettingsData", plugin(0, .map([("LightSettingsData_lights", packed(.arr([.map([("ObjectId", .int(-10))])])))])))
    expectKept(characterLight, [.init(deletions: [5])])
    expectRefused(characterLight, [addLight, copyLight], "writes a record for every light, and this edit adds or copies a light")
    // StudioItemIK: IK item keys with their target and pole items.
    let ikID = "org.njaecha.plugins.StudioItemIK"
    let ik = (ikID, plugin(0, .map([("activeIKs", packed(.arr([.int(4)]))),
                                    ("objectTargetPairs", packed(.imap([(Int64(4), .arr([.int(3), .int(1)]))])))])))
    expectKept(ik, [.init(deletions: [5]), addFolder])
    expectRefused(ik, [.init(deletions: [3]), .init(deletions: [4]), copyItem], "StudioItemIK data ('\(ikID)') \(named)")
    expectKept((ikID, plugin(0, .map([("activeIKs", packed(.arr([]))), ("objectTargetPairs", packed(.imap([])))]))), [copyFolder])
    // ObjImport: item keys of imported meshes; `[0, {}]` when empty.
    let objID = "org.njaecha.plugins.objimport"
    expectKept((objID, plugin(0, .map([]))), [.init(deletions: [4]), copyItem])
    let imported = (objID, plugin(0, .map([("version", .int(1)), ("meshes", .bin([1])), ("ids", packed(.arr([.int(4)])))])))
    expectRefused(imported, [.init(deletions: [4]), copyItem], "ObjImport data ('\(objID)') \(named)")
    // SaveCameraObjectFov: field of view per camera key, and the camera
    // selector's position. Its common form (no camera, main camera
    // selected, indices as forced Int32) names nothing.
    let fovID = "com.rikkibalboa.bepinex.savecameraobjectfov"
    let zero = PluginMP.raw([0xd2, 0, 0, 0, 0])
    expectKept((fovID, plugin(0, .map([("cameras", .null), ("mainFov", .f32(23)), ("previousCameraIndex", zero), ("cameraIndex", zero)]))),
               [addCamera, .init(deletions: [11]), copyItem])
    let viewing = (fovID, plugin(0, .map([("cameras", packed(.imap([(Int64(11), .f32(40))]))), ("mainFov", .f32(23)),
                                          ("previousCameraIndex", zero), ("cameraIndex", .raw([0xd2, 0, 0, 0, 1]))])))
    expectKept(viewing, [.init(deletions: [4]), addFolder])
    expectRefused(viewing, [.init(deletions: [11])], "SaveCameraObjectFov data ('\(fovID)') \(deleted)")
    expectRefused(viewing, [addCamera], "selects a camera by its position in the camera list, and this edit adds, copies or deletes cameras")
    // A field a rule does not list makes the entry unknown.
    expectRefused((maskingID, plugin(0, .map([("MaskingFolders", .null), ("Future", .int(1))]))), [.init(deletions: [4])],
                  "StudioCustomMasking data ('\(maskingID)') has no rule in this writer")
}

// MARK: - KK_AnimationController links

@Test func sourceScenePluginDataChecksAnimationControllerLinks() throws {
    // NodesConstraints.OnSceneLoad without KK_AnimationController installed:
    // with no `AnimationInfo` in the scene entry, each character's card
    // KKAnimationController links become constraints by object key.
    let linked = OriginalCardFixture.card(blocks: OriginalCardFixture.blocks() + [OriginalCardFixture.extended(OriginalCardFixture.map([
        ("com.deathweasel.bepinex.animationcontroller",
         OriginalCardFixture.plugin(0, data: OriginalCardFixture.map([("Links", .binary(Data([0x90]))), ("Eyes", .null)]))),
    ]))])
    let emptyNodes = ("nodesConstraints", plugin(0, .map([("constraints", .str(#"<constraints version="1" />"#))])))
    let cardReason = "NodesConstraints data ('nodesConstraints') would gain constraints on load: character 12's card carries KKAnimationController links"
    #expect(verdict(pluginScene([emptyNodes], card: linked), .init(deletions: [4])).contains(cardReason))
    #expect(verdict(pluginScene([emptyNodes], card: linked), copyItem).contains(cardReason))
    // A card without links, or an edit that deletes and copies nothing.
    #expect(verdict(pluginScene([emptyNodes]), .init(deletions: [4])) == "kept")
    #expect(verdict(pluginScene([emptyNodes], card: linked), addFolder) == "kept")
    // An `AnimationInfo` list, even empty, turns the card path off.
    let controller = "KK_AnimationController"
    let emptyList = (controller, plugin(0, .map([("AnimationInfo", .arr([]))])))
    #expect(verdict(pluginScene([emptyNodes, emptyList], card: linked), .init(deletions: [4])) == "kept")
    // An empty entry is the card path too, and names itself.
    let emptyEntry = (controller, plugin(0, .map([])))
    #expect(verdict(pluginScene([emptyEntry], card: linked), .init(deletions: [4]))
        .contains("KK_AnimationController data ('KK_AnimationController') would gain constraints on load"))
    // Links in the scene entry: character and object keys.
    let links = (controller, plugin(0, .map([("AnimationInfo", .arr([.map([("CharDicKey", .int(12)), ("ItemDicKey", .int(4))])]))])))
    #expect(verdict(pluginScene([links]), addFolder) == "kept")
    #expect(verdict(pluginScene([links]), .init(deletions: [5]))
        .contains("KK_AnimationController data ('KK_AnimationController') links characters to objects by key, and this edit deletes or copies objects"))
}

// MARK: - Encodings

@Test func sourceScenePluginDataWriterUsesMessagePackCSharpEncodings() {
    // Anchors from the MessagePack specification, then each boundary
    // against the independent encoder above.
    func written(_ value: Int64) -> [UInt8] { var out: [UInt8] = []; SourceMessagePackWriter.integer(value, into: &out); return out }
    #expect(written(127) == [0x7f] && written(128) == [0xcc, 0x80] && written(-32) == [0xe0] && written(-33) == [0xd0, 0xdf])
    #expect(written(65_536) == [0xce, 0, 1, 0, 0] && written(-32_769) == [0xd2, 0xff, 0xff, 0x7f, 0xff])
    let integers: [Int64] = [0, 1, 127, 128, 255, 256, 65_535, 65_536, 4_294_967_295, 4_294_967_296,
                             -1, -32, -33, -128, -129, -32_768, -32_769, Int64(Int32.min), Int64(Int32.min) - 1]
    for value in integers { #expect(written(value) == PluginMP.integer(value), "\(value)") }
    func header(_ container: SourceMessagePackWriter.Container, _ count: Int) -> [UInt8] {
        var out: [UInt8] = []; SourceMessagePackWriter.header(container, count: count, into: &out); return out
    }
    #expect(header(.map, 16) == [0xde, 0, 16] && header(.string, 32) == [0xd9, 32] && header(.binary, 0) == [0xc4, 0])
    for count in [0, 1, 15, 16, 31, 32, 255, 256, 65_535, 65_536] {
        #expect(header(.map, count) == PluginMP.header(count, fix: 0x80, 0xde, 0xdf), "map \(count)")
        #expect(header(.array, count) == PluginMP.header(count, fix: 0x90, 0xdc, 0xdd), "array \(count)")
        let bytes = [UInt8](repeating: 1, count: count), text = String(repeating: "a", count: count)
        #expect(header(.binary, count) + bytes == PluginMP.bin(bytes).bytes, "bin \(count)")
        #expect(header(.string, count) + Array(text.utf8) == PluginMP.str(text).bytes, "str \(count)")
    }
}

// MARK: - Rule parity corpus

/// The survey's C# port of these rules (Tools/reverse/fixtures/PluginSceneRules.cs)
/// must judge every single-target edit of these scenes as this writer does.
/// IKKOKU_PLUGIN_RULE_CORPUS names the JSON file this writes: each scene's
/// walk (key, kind, parent), used keys, characters whose card carries
/// KKAnimationController links and trailer, and per edit the verdict and
/// the entry IDs a refusal names.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_PLUGIN_RULE_CORPUS"]), "Requires IKKOKU_PLUGIN_RULE_CORPUS (an output JSON path)"))
func sourceScenePluginDataWritesTheRuleParityCorpus() throws {
    let output = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_PLUGIN_RULE_CORPUS"))
    var scenes: [[String: Any]] = [], cases: [[String: Any]] = []
    for (index, scene) in try ruleCorpusScenes().enumerated() {
        let document = try KoikatsuSceneReader.decodeDocument(scene.data)
        let model = try ruleModel(document)
        scenes.append(model)
        let walk = SourceSceneInsertionPlan.records(document.snapshot)
        var edits: [([String: Any], SourceSceneEdits)] = []
        for record in walk {
            edits.append((["kind": "delete", "key": Int(record.sourceKey)], .init(deletions: [record.sourceKey])))
            edits.append((["kind": "duplicate", "key": Int(record.sourceKey)], .init(insertions: copyInsertions(record, in: document.snapshot))))
        }
        edits.append((["kind": "add", "object": 3], addFolder))
        edits.append((["kind": "add", "object": 2], addLight))
        edits.append((["kind": "add", "object": 5], addCamera))
        if let route = walk.first(where: { $0.route != nil }), let points = route.route {
            var added = SourceStudioRouteState(record: points); _ = try added.addPoint()
            edits.append((["kind": "routeAdd", "key": Int(route.sourceKey)], .init(routes: [route.sourceKey: added])))
            if points.points.count > 1 {
                var deleted = SourceStudioRouteState(record: points); try deleted.deletePoint(1)
                edits.append((["kind": "routeDelete", "key": Int(route.sourceKey)], .init(routes: [route.sourceKey: deleted])))
            }
        }
        let ids = (try? SourceSceneKKEx.parse(document.trailingData))?.entries.map(\.id) ?? []
        for (spec, edit) in edits {
            var row: [String: Any] = ["scene": index, "edit": spec]
            do {
                let result = try KoikatsuSceneReader.decodeDocument(document.editedData(edit))
                row["verdict"] = result.trailingData == document.trailingData ? "kept" : "rewritten"
            } catch let error as SourceSceneTopologyError {
                let text = error.errorDescription ?? ""
                if text.hasPrefix("Original-scene export cannot ") {
                    row["verdict"] = "refused"
                    row["ids"] = ids.filter { text.contains("('\($0)')") || text.contains("plug-in data '\($0)'") }.sorted()
                } else {
                    row["verdict"] = "other"   // a topology rule, not plug-in data
                }
            }
            cases.append(row)
        }
    }
    let json = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "scenes": scenes, "cases": cases], options: [.sortedKeys])
    try json.write(to: output)
    let counts = Dictionary(grouping: cases, by: { $0["verdict"] as! String }).mapValues(\.count)
    print("rule corpus: \(scenes.count) scenes, \(cases.count) cases \(counts.sorted { $0.key < $1.key })")
}

/// Studio.Duplicate of a record: its copy under the same parent, then each
/// descendant's copy under its parent's copy.
private func copyInsertions(_ record: KoikatsuObjectRecord, in snapshot: KoikatsuSceneSnapshot) -> [SourceSceneInsertion] {
    var parents: [Int32: Int32] = [:], points: [Int32: Int32] = [:]
    for parent in SourceSceneInsertionPlan.records(snapshot) {
        for child in parent.children { parents[child.sourceKey] = parent.sourceKey }
        for (point, children) in parent.character?.accessoryChildren ?? [:] {
            for child in children { parents[child.sourceKey] = parent.sourceKey; points[child.sourceKey] = point }
        }
    }
    var result: [SourceSceneInsertion] = []
    func visit(_ node: KoikatsuObjectRecord, _ parent: SourceSceneInsertion.Parent) {
        let index = result.count
        result.append(.init(.duplicate(of: node.sourceKey), parent: parent, attachment: points[node.sourceKey]))
        for child in node.children { visit(child, .inserted(index)) }
        for point in (node.character?.accessoryChildren ?? [:]).keys.sorted() {
            for child in node.character!.accessoryChildren[point]! { visit(child, .inserted(index)) }
        }
    }
    visit(record, parents[record.sourceKey].map { .source($0) } ?? .root)
    return result
}

/// What the C# rules read: the walk, used keys, linked characters, trailer.
private func ruleModel(_ document: KoikatsuSceneDocument) throws -> [String: Any] {
    var objects: [[String: Any]] = [], linked: [Int] = []
    func visit(_ record: KoikatsuObjectRecord, _ parent: Int32?) throws {
        objects.append(["key": Int(record.sourceKey), "kind": Int(record.kind.rawValue), "parent": parent.map { Int($0) } ?? -1])
        if let character = record.character {
            let data = try character.card().extensions().plugins[SourceScenePluginData.cardAnimationController]?.data
            if [data?["Links"], data?["Eyes"]].contains(where: { value in value.map { $0 != .null } ?? false }) {
                linked.append(Int(record.sourceKey))
            }
        }
        for child in record.children { try visit(child, record.sourceKey) }
        for point in (record.character?.accessoryChildren ?? [:]).keys.sorted() {
            for child in record.character!.accessoryChildren[point]! { try visit(child, record.sourceKey) }
        }
    }
    for root in document.snapshot.roots { try visit(root, nil) }
    let used = SourceSceneInsertionPlan.usedKeys(document.snapshot).map { Int($0) }.sorted()
    let trailer = document.trailingData.map { String(format: "%02x", $0) }.joined()
    return ["objects": objects, "used": used, "linked": linked, "trailer": trailer]
}

/// Every entry form the tests above use, alone and in the combinations
/// whose rules interact, plus unreadable trailers.
private func ruleCorpusScenes() throws -> [TopologyScene] {
    let linked = OriginalCardFixture.card(blocks: OriginalCardFixture.blocks() + [OriginalCardFixture.extended(OriginalCardFixture.map([
        ("com.deathweasel.bepinex.animationcontroller",
         OriginalCardFixture.plugin(0, data: OriginalCardFixture.map([("Links", .binary(Data([0x90]))), ("Eyes", .null)]))),
    ]))])
    let items = [Record(1, 1, 0), Record(2, 2, 1), Record(3, 3, 2), Record(4, 4, 3), Record(5, 5, 0), Record(12, 12, 0)]
    let zero = PluginMP.raw([0xd2, 0, 0, 0, 0])
    let constraints = plugin(0, .map([("constraints", .str(#"<constraints version="1"><constraint parentObjectIndex="0" childObjectIndex="3" /></constraints>"#))]))
    let emptyNodes = plugin(0, .map([("constraints", .str(#"<constraints version="1" />"#))]))
    let forms: [(String, PluginMP)] = [
        (sideloaderID, sideloader(items, [Record(3, 3, 2)])), (sideloaderID, sideloader([Record(99, 99, 0)])),
        (sideloaderID, sideloader(items, map: false)), (sideloaderID, plugin(1, .map([]))), settings, (settingsID, plugin(1, .map([]))),
        ("kkpe", plugin(0, .map([("sceneInfo", .str("<root />"))]))), ("kkpe", .int(5)),
        ("com.deathweasel.bepinex.materialeditor", plugin(1, .map(MaterialEditorForm.keys.sorted().map { ($0, PluginMP.null) }))),
        ("com.deathweasel.bepinex.materialeditor", plugin(1, .map([("MaterialShaderList", packed(.arr([.map([("ID", .int(4))])])))]))),
        ("com.deathweasel.bepinex.materialeditor", plugin(1, .int(5))),
        ("nodesConstraints", constraints), ("nodesConstraints", emptyNodes),
        ("timeline", plugin(0, .map([("sceneInfo", .str(#"<root><interpolable objectIndex="3" /></root>"#))]))),
        ("timeline", plugin(0, .map([("sceneInfo", .str(#"<root><interpolable id="camera" /></root>"#))]))),
        ("KK_AnimationController", plugin(0, .map([]))), ("KK_AnimationController", plugin(0, .map([("AnimationInfo", .arr([]))]))),
        ("KK_AnimationController", plugin(0, .map([("AnimationInfo", .arr([.map([("CharDicKey", .int(12)), ("ItemDicKey", .int(4))])]))]))),
        ("com.deathweasel.bepinex.studiocustommasking", plugin(0, .map([("MaskingFolders", packed(.arr([.int(0)])))]))),
        ("com.deathweasel.bepinex.studiocustommasking", plugin(0, .map([("MaskingFolders", .null), ("Future", .int(1))]))),
        ("keelhauled.itemlayeredit", plugin(0, .map([("SavedLayers", packed(.arr([.map([("ObjectId", .int(4)), ("Layer", .int(10))])])))]))),
        ("keelhauled.realpov", plugin(0, .map([("PovData", packed(.map([("CharaId", .int(12)), ("Fov", .f32(45))])))]))),
        ("orange.spork.moarcamzplugin", plugin(0, .map([("MoarCamz", packed(.arr([.map([("CenterTarget", .int(4))])]))), ("MoarCamzLastSelection", .int(0))]))),
        ("BetterScalingData", plugin(0, .map([("BetterScalingData_scaledFoldersFlag", .bool(true)), ("BetterScalingData_scaledOCI", packed(.arr([.int(3)])))]))),
        ("LightSettingsData", plugin(0, .map([("LightSettingsData_lights", packed(.arr([.map([("ObjectId", .int(-10))]), .map([("ObjectId", .int(5))])]))),
                                             ("LightSettingsData_cookies", .null)]))),
        ("LightSettingsData", plugin(0, .map([("LightSettingsData_lights", packed(.arr([.map([("ObjectId", .int(-10))])])))]))),
        ("org.njaecha.plugins.StudioItemIK", plugin(0, .map([("activeIKs", packed(.arr([.int(4)]))),
                                                             ("objectTargetPairs", packed(.imap([(Int64(4), .arr([.int(3), .int(1)]))])))]))),
        ("org.njaecha.plugins.StudioItemIK", plugin(0, .map([("activeIKs", packed(.arr([]))), ("objectTargetPairs", packed(.imap([])))]))),
        ("org.njaecha.plugins.objimport", plugin(0, .map([]))),
        ("org.njaecha.plugins.objimport", plugin(0, .map([("version", .int(1)), ("meshes", .bin([1])), ("ids", packed(.arr([.int(4)])))]))),
        ("com.rikkibalboa.bepinex.savecameraobjectfov", plugin(0, .map([("cameras", .null), ("mainFov", .f32(23)), ("previousCameraIndex", zero), ("cameraIndex", zero)]))),
        ("com.rikkibalboa.bepinex.savecameraobjectfov", plugin(0, .map([("cameras", packed(.imap([(Int64(11), .f32(40))]))), ("mainFov", .f32(23)),
                                                                       ("previousCameraIndex", zero), ("cameraIndex", .raw([0xd2, 0, 0, 0, 1]))]))),
        ("vnge_sss", plugin(0, .map([("objects", packed(.arr([.int(4)])))]))), ("KKVMDPlayExtSave", plugin(0, .map([("motion", .bin([1]))]))),
        ("example.scene", plugin(0, .map([]))), ("example.nil", .null),
        ("com.jim60105.kk.studiocharalightlinkedtocamera", plugin(3, .map([("Locked", .bool(true))]))), ("TwoLutPlugin", plugin(0, .map([]))),
        ("com.deathweasel.bepinex.studioimageembed", plugin(0, .map([]))),
    ]
    var scenes: [TopologyScene] = []
    for form in forms {
        scenes.append(pluginScene([form]))
        scenes.append(pluginScene([form, settings], hole: true))
    }
    // Interacting rules: the card fallback, and several entries at once.
    let controllerEmpty = ("KK_AnimationController", plugin(0, .map([])))
    let controllerList = ("KK_AnimationController", plugin(0, .map([("AnimationInfo", .arr([]))])))
    for entries in [[("nodesConstraints", emptyNodes)], [("nodesConstraints", constraints)], [controllerEmpty],
                    [("nodesConstraints", emptyNodes), controllerList], [("nodesConstraints", emptyNodes), controllerEmpty]] {
        scenes.append(pluginScene(entries, card: linked))
        scenes.append(pluginScene(entries))
    }
    scenes.append(pluginScene(forms.filter { $0.0 != "example.scene" && $0.0 != "kkpe" }.reduce(into: [(String, PluginMP)]()) { list, form in
        if !list.contains(where: { $0.0 == form.0 }) { list.append(form) }
    }))
    // No trailer, an empty map, and trailers that do not parse.
    scenes.append(pluginScene(nil)); scenes.append(pluginScene([]))
    var extra = Array(pluginTrailer([settings])); extra.append(0xc0); extra[9] = UInt8(truncatingIfNeeded: Int(extra[9]) + 1)
    for bytes in [Data(extra), pluginTrailer([settings, settings]), Data([0, 255, 3])] {
        var scene = pluginScene(nil); scene.trailer = bytes; scenes.append(scene)
    }
    return scenes
}
