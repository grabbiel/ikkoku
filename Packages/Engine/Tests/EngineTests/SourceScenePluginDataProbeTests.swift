import Foundation
import Testing
import Assets
@testable import Studio

// Phase A of the plug-in scene probe (Tools/reverse/original_plugin_scene_probe.py):
// CharaStudio, with the installed plug-ins and one Sideloader mod item,
// authored fixture.png and saved each supported edit of it as
// edit-<label>.png. Our export of the same edit on fixture.png must write
// the same plug-in trailer: with CharaStudio's thumbnail, the whole file is
// byte-identical where CharaStudio's object keys and dictionary order match
// ours, and otherwise the trailer holds the same records under our keys
// (delete-duplicate, issue #278).
//
// The fixture's keys (plugin-scene-trace.json): folder F 0 [M2 3, V2 4],
// vanilla item V1 1 [M4 6], mod items M1 2 and M3 5, route R 7 (points 8,
// 10, 12 with aids 9, 11, 13), camera C 14, light L 15. M1 to M4 are the
// mod item, V1 and V2 a vanilla one.

private let probeVariable = "IKKOKU_PLUGIN_SCENE_PROBE"
private let inputsVariable = "IKKOKU_PLUGIN_SCENE_INPUTS"
private let phaseBVariable = "IKKOKU_PLUGIN_SCENE_PROBE_B"
private let phaseAEdits = ["delete", "delete-folder", "duplicate", "delete-duplicate", "move", "route-add", "route-delete"]

@Test(.enabled(if: SourceFixtureSupport.shouldRun([probeVariable]), "Requires IKKOKU_PLUGIN_SCENE_PROBE (the probe's phase-a folder)"))
func sourceScenePluginDataMatchesCharaStudioEdits() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require(probeVariable))
    let fixture = try Data(contentsOf: root.appendingPathComponent("fixture.png"))
    let source = try KoikatsuSceneReader.decodeDocument(fixture)
    #expect(try sideloaderRecords(source.trailingData) == [[3, 0], [6, 3], [2, 4], [5, 5]])
    var results: [String] = []
    for label in phaseAEdits {
        let saved = try Data(contentsOf: root.appendingPathComponent("edit-\(label).png"))
        let theirs = try KoikatsuSceneReader.decodeDocument(saved)
        var edits = try probeEdits(label, source: source, theirs: theirs)
        edits.thumbnailData = try pngPrefix(saved)
        let ours = try source.editedData(edits)
        let document = try KoikatsuSceneReader.decodeDocument(ours)
        if label == "delete-duplicate" {
            // CharaStudio's delete frees key 1 and the copy of M3 takes it,
            // in V1's dictionary slot (#278); ours keeps deleted keys out
            // of this export and the copy takes 16, appended to the roots.
            #expect(document.snapshot.roots.map(\.sourceKey) == [0, 2, 5, 7, 14, 15, 16])
            #expect(theirs.snapshot.roots.map(\.sourceKey) == [0, 1, 2, 5, 7, 14, 15])
            #expect(try sideloaderRecords(theirs.trailingData) == [[3, 0], [1, 2], [2, 3], [5, 4]])
            // CharaStudio's rule on our layout: F's M2 0, M1 2, M3 3, the
            // copy 4 (V2 is item 1).
            #expect(try sideloaderRecords(document.trailingData) == [[3, 0], [2, 2], [5, 3], [16, 4]])
            // Every record is CharaStudio's apart from the key and position,
            // and both keys encode in one byte, so the trailers have the
            // same length and differ only in those bytes.
            #expect(document.trailingData.count == theirs.trailingData.count)
            #expect(try sideloaderRecordFields(document.trailingData) == sideloaderRecordFields(theirs.trailingData))
            results.append("\(label): decoded-equal under our keys (#278)")
        } else {
            // With CharaStudio's thumbnail, the whole file is CharaStudio's.
            #expect(document.trailingData == theirs.trailingData, "\(label): trailer")
            #expect(ours == saved, "\(label): the file differs at \(firstDifference(ours, saved))")
            results.append("\(label): \(ours == saved ? "byte-identical file" : "differs at \(firstDifference(ours, saved))")")
        }
    }
    print("plug-in probe phase A:\n" + results.joined(separator: "\n"))

    // passthrough.png carries an entry no installed plug-in owns. CharaStudio
    // keeps its bytes through a delete (ExtendedSave writes back what no
    // controller replaced); our writer has no rule for it and refuses by name.
    let passthrough = try KoikatsuSceneReader.decodeDocument(Data(contentsOf: root.appendingPathComponent("passthrough.png")))
    let deleted = try KoikatsuSceneReader.decodeDocument(Data(contentsOf: root.appendingPathComponent("passthrough-delete.png")))
    func probeEntry(_ document: KoikatsuSceneDocument) throws -> [UInt8] {
        let kkex = try SourceSceneKKEx.parse(document.trailingData)
        let entry = try #require(kkex.entries.first { $0.id == "org.ikkoku.probe.passthrough" })
        return Array(kkex.bytes[entry.span])
    }
    #expect(try probeEntry(passthrough) == probeEntry(deleted))
    do {
        _ = try passthrough.editedData(.init(deletions: [2]))
        Issue.record("an entry without a rule must refuse the delete")
    } catch let error as SourceSceneTopologyError {
        #expect(error.errorDescription?.contains("plug-in data 'org.ikkoku.probe.passthrough' has no rule") == true)
    }
    // A move keeps it.
    let move = try #require(passthrough.snapshot.roots.first { $0.sourceKey == 5 })
    let moved = try KoikatsuSceneReader.decodeDocument(passthrough.editedData(
        .init(transforms: [.init(.object(5), transform: move.transform)], reparents: [.init(object: 5, parent: 0)])))
    #expect(try probeEntry(moved) == probeEntry(passthrough))
}

// MARK: - Phase B

/// The phase-B player run's inputs, from phase A: our export of each phase-A
/// edit of fixture.png as the app writes it (the source thumbnail kept),
/// ours-<edit>.png, and fixture-nil.png, phase A's fixture with nil
/// MaterialEditor and example.nil entries added to its KKEx map.
@Test(.enabled(if: SourceFixtureSupport.shouldRun([probeVariable, inputsVariable]),
               "Requires IKKOKU_PLUGIN_SCENE_PROBE (phase-a folder) and IKKOKU_PLUGIN_SCENE_INPUTS (output folder)"))
func sourceScenePluginDataWritesThePhaseBInputs() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require(probeVariable))
    let output = URL(fileURLWithPath: try SourceFixtureSupport.require(inputsVariable))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let fixture = try Data(contentsOf: root.appendingPathComponent("fixture.png"))
    let source = try KoikatsuSceneReader.decodeDocument(fixture)
    for label in phaseAEdits {
        let theirs = try KoikatsuSceneReader.decodeDocument(Data(contentsOf: root.appendingPathComponent("edit-\(label).png")))
        let ours = try source.editedData(probeEdits(label, source: source, theirs: theirs))
        try ours.write(to: output.appendingPathComponent("ours-\(label).png"))
    }
    let withNil = try nilEntries(fixture, trailer: source.trailingData,
                                 ids: [SourceScenePluginData.materialEditor, "example.nil"])
    let decoded = try SourceSceneKKEx.parse(KoikatsuSceneReader.decodeDocument(withNil).trailingData)
    #expect(decoded.entries.map(\.isNil) == [false, false, true, true])
    try withNil.write(to: output.appendingPathComponent("fixture-nil.png"))
}

/// Phase B: CharaStudio with KKPE, NodesConstraints and MaterialEditor
/// loaded as well saved phase A's fixture again (fixture.png, which now
/// carries their entries), each edit of it (edit-<label>.png), the
/// load-then-save of every one of those (resave-*.png), of our phase-A
/// exports (resave-ours-*.png) and of the nil-entry fixture.
@Test(.enabled(if: SourceFixtureSupport.shouldRun([phaseBVariable]), "Requires IKKOKU_PLUGIN_SCENE_PROBE_B (the probe's phase-b folder)"))
func sourceScenePluginDataMatchesCharaStudioWithEveryPlugin() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require(phaseBVariable))
    func load(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }
    let fixture = try load("fixture.png")
    let source = try KoikatsuSceneReader.decodeDocument(fixture)
    let kkex = try SourceSceneKKEx.parse(source.trailingData)
    var lines = ["fixture entries: " + kkex.entries.map { "\($0.id) \($0.span.count) B" }.joined(separator: ", ")]
    for id in [SourceScenePluginData.kkpe, SourceScenePluginData.nodesConstraints, SourceScenePluginData.materialEditor] {
        #expect(kkex.entries.contains { $0.id == id }, "fixture.png has no \(id) entry")
    }
    // Our export of each edit of this fixture: refused where an item is
    // added or removed (KKPE's per-item list is positional; its rewrite is
    // PR 2), otherwise CharaStudio's file.
    var refused: [String] = []
    for label in phaseAEdits + ["delete-light", "add-folder"] {
        let saved = try load("edit-\(label).png")
        let theirs = try KoikatsuSceneReader.decodeDocument(saved)
        var edits = try label == "delete-light" ? .init(deletions: [15])
            : label == "add-folder" ? addedFolder(source: source, theirs: theirs)
            : probeEdits(label, source: source, theirs: theirs)
        edits.thumbnailData = try pngPrefix(saved)
        do {
            let ours = try source.editedData(edits)
            #expect(ours == saved, "\(label): the file differs at \(firstDifference(ours, saved))")
            lines.append("\(label): \(ours == saved ? "byte-identical file" : "differs at \(firstDifference(ours, saved))")")
        } catch let error as SourceSceneTopologyError {
            let reason = error.errorDescription ?? ""
            #expect(reason.contains("KKPE"), "\(label): \(reason)")
            refused.append(label)
            lines.append("\(label): refused (\(reason))")
        }
    }
    #expect(refused == ["delete", "delete-folder", "duplicate", "delete-duplicate"])
    // CharaStudio's load-then-save is a fixed point of its own saves.
    for name in ["fixture.png"] + (phaseAEdits + ["delete-light", "add-folder"]).map({ "edit-\($0).png" }) {
        let same = try afterPNG(load("resave-\(name)")) == afterPNG(load(name))
        #expect(same, "resave-\(name)")
        lines.append("resave-\(name): \(same ? "same scene bytes" : "differs")")
    }
    // Our phase-A exports, loaded and saved by this player, are its own
    // edits of the phase-B fixture; delete-duplicate's copy keeps our key.
    for label in phaseAEdits {
        let resaved = try afterPNG(load("resave-ours-\(label).png")), theirs = try afterPNG(load("edit-\(label).png"))
        if label == "delete-duplicate" {
            let ours = try KoikatsuSceneReader.decodeDocument(load("resave-ours-\(label).png"))
            #expect(ours.snapshot.roots.map(\.sourceKey) == [0, 2, 5, 7, 14, 15, 16])
            lines.append("resave-ours-\(label): \(resaved.count == theirs.count ? "same length" : "length differs"), keys as ours (#278)")
        } else {
            #expect(resaved == theirs, "resave-ours-\(label)")
            lines.append("resave-ours-\(label): \(resaved == theirs ? "same scene bytes as CharaStudio's edit" : "differs")")
        }
    }
    // Nil entries are inert: the nil-entry fixture saves as the fixture does.
    let nilSame = try afterPNG(load("resave-fixture-nil.png")) == afterPNG(fixture)
    #expect(nilSame)
    lines.append("resave-fixture-nil: \(nilSame ? "same scene bytes as fixture.png" : "differs")")
    print("plug-in probe phase B:\n" + lines.joined(separator: "\n"))
}

/// AddObjectFolder.Add's folder as CharaStudio saved it: the root record
/// whose key the fixture does not have.
private func addedFolder(source: KoikatsuSceneDocument, theirs: KoikatsuSceneDocument) throws -> SourceSceneEdits {
    let keys = Set(source.snapshot.roots.map(\.sourceKey))
    let added = try #require(theirs.snapshot.roots.first { !keys.contains($0.sourceKey) })
    #expect(added.kind == .folder && added.sourceKey == 16)
    let header = SourceSceneInsertion.Header(transform: added.transform, treeState: added.treeState, visible: added.visible)
    return .init(insertions: [.init(.folder(name: added.name ?? "", header: header))])
}

/// The scene after its leading PNG.
private func afterPNG(_ data: Data) throws -> Data { data.dropFirst(try pngPrefix(data).count) }

/// `scene` with nil entries `ids` appended to its KKEx map (a fixmap).
private func nilEntries(_ scene: Data, trailer: Data, ids: [String]) throws -> Data {
    var bytes = [UInt8](trailer)
    let count = Int(bytes[13]) - 0x80
    guard bytes[13] & 0xf0 == 0x80, count + ids.count <= 15 else { throw SourceFixtureError.missing("a fixmap KKEx payload") }
    bytes[13] = UInt8(0x80 + count + ids.count)
    for id in ids {
        let utf8 = Array(id.utf8)
        bytes += utf8.count < 32 ? [UInt8(0xa0 + utf8.count)] : [0xd9, UInt8(utf8.count)]
        bytes += utf8 + [0xc0]
    }
    let length = UInt32(bytes.count - 13)
    bytes.replaceSubrange(9..<13, with: [UInt8(length & 0xff), UInt8(length >> 8 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 24)])
    return scene.prefix(scene.count - trailer.count) + Data(bytes)
}

/// The probe's edits (OriginalPluginSceneProbe.cs `Edit`) as our export's.
private func probeEdits(_ label: String, source: KoikatsuSceneDocument, theirs: KoikatsuSceneDocument) throws -> SourceSceneEdits {
    switch label {
    case "delete": return .init(deletions: [2])
    case "delete-folder": return .init(deletions: [0])
    case "duplicate":
        // Studio.Duplicate of folder F (with M2 and V2), then of M3.
        return .init(insertions: [.init(.duplicate(of: 0)), .init(.duplicate(of: 3), parent: .inserted(0)),
                                  .init(.duplicate(of: 4), parent: .inserted(0)), .init(.duplicate(of: 5))])
    case "delete-duplicate":
        return .init(deletions: [1], insertions: [.init(.duplicate(of: 5))])
    case "move":
        // TreeNodeCtrl.SetParent keeps M3's world placement; the local one
        // is CharaStudio's saved value.
        let moved = try #require(theirs.snapshot.roots.first { $0.sourceKey == 0 }?.children.first { $0.sourceKey == 5 })
        return .init(transforms: [.init(.object(5), transform: moved.transform)], reparents: [.init(object: 5, parent: 0)])
    case "route-add", "route-delete":
        let before = try #require(source.snapshot.roots.first { $0.sourceKey == 7 }?.route)
        let after = try #require(theirs.snapshot.roots.first { $0.sourceKey == 7 }?.route)
        var state = SourceStudioRouteState(record: before)
        if label == "route-add" {
            let index = try state.addPoint()
            // OCIRoute.AddPoint's point, as CharaStudio saved it.
            var saved = SourceStudioRouteState(record: after).points[index]
            saved.sourceIndex = nil
            state.points[index] = saved
            #expect(after.points.map(\.bone.sourceKey) == [8, 10, 12, 16])
        } else {
            try state.deletePoint(1)
            #expect(after.points.map(\.bone.sourceKey) == [8, 12])
        }
        return .init(routes: [7: state])
    default: throw SourceFixtureError.missing("probe edit \(label)")
    }
}

/// The scene's leading PNG.
private func pngPrefix(_ data: Data) throws -> Data {
    var reader = try KoikatsuBinaryReader(data)
    try reader.skipPNG()
    return data.prefix(reader.offset)
}

private func firstDifference(_ a: Data, _ b: Data) -> String {
    let x = Array(a), y = Array(b)
    let index = x.indices.first { $0 < y.count && x[$0] != y[$0] } ?? min(x.count, y.count)
    return "byte \(index) (sizes \(a.count) and \(b.count))"
}

/// Sideloader's `itemInfo` records as [SceneDicKey, SceneObjectOrder].
private func sideloaderRecords(_ trailer: Data) throws -> [[Int]] {
    try sideloaderItemInfo(trailer).map { record in
        [try #require(record["SceneDicKey"]?.integerValue), try #require(record["SceneObjectOrder"]?.integerValue)]
    }
}

/// Sideloader's `itemInfo` records without their key and position.
private func sideloaderRecordFields(_ trailer: Data) throws -> [[String: SourceMessagePackValue]] {
    try sideloaderItemInfo(trailer).map { record in
        var record = record
        record["SceneDicKey"] = nil; record["SceneObjectOrder"] = nil
        return record
    }
}

private func sideloaderItemInfo(_ trailer: Data) throws -> [[String: SourceMessagePackValue]] {
    let kkex = try SourceSceneKKEx.parse(trailer)
    let entry = try #require(kkex.entries.first { $0.id == SourceScenePluginData.sideloader })
    let value = try SourceMessagePack.decode(Data(kkex.bytes[entry.value]))
    guard case .array(let pair) = value, pair.count == 2 else { throw SourceFixtureError.missing("Sideloader [version, data]") }
    let data = try pair[1].stringKeyedMap()
    guard case .array(let records) = data["itemInfo"] ?? .array([]) else { throw SourceFixtureError.missing("itemInfo list") }
    return try records.map { record in
        guard case .binary(let bytes) = record else { throw SourceFixtureError.missing("itemInfo bytes") }
        return try SourceMessagePack.decode(bytes).stringKeyedMap()
    }
}
