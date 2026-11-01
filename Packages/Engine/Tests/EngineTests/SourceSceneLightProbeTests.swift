import Foundation
import CryptoKit
import Testing
@testable import Studio

// #316 and #320: the light phase of the plug-in scene probe (phase OL of
// Tools/reverse/original_plugin_scene_probe.py; `LightCases` and
// `LightInputs` in fixtures/OriginalPluginRewriteProbe.cs). One private
// root ran two original players on phase A's exact fixture (keys: folder
// F 0 [M2 3, V2 4], vanilla item V1 1 [M4 6], mod items M1 2 and M3 5,
// route R 7, camera C 14, light L 15):
// - vanilla CharaStudio 1.0.4.2 (OL, outputs vanilla-*);
// - the same root with KK_Fix_UnlimitedMapLights 22.1 copied in (OU).
// Each saved phase A's load-then-save, each light case from it, and the
// load-then-save of our exports with more than two lights. Every snapshot in
// the trace holds SceneInfo.lightCount and both light getters' results.

private let lightOracleVariable = "IKKOKU_LIGHT_ORACLE"
/// An optional path: the row report (drops, hashes, loaded lights, patches).
private let lightReportVariable = "IKKOKU_LIGHT_ORACLE_REPORT"
private let lightFixtureVariable = "IKKOKU_PLUGIN_SCENE_PROBE"
private let lightInputsVariable = "IKKOKU_LIGHT_PROBE_INPUTS"
private let lightCases: [(label: String, steps: [(operation: String, target: String)])] = [
    ("delete-duplicate-light", [("delete", "V1"), ("duplicate", "L")]),
    ("delete-light-add-light-twice", [("delete", "L"), ("add-light", "1"), ("add-light", "1")]),
    ("delete-duplicate-light-twice", [("delete", "V1"), ("duplicate", "L"), ("duplicate", "L")]),
    ("add-light-twice", [("add-light", "1"), ("add-light", "1")]),
]
/// The step, by index, that vanilla CharaStudio drops or refuses under the
/// recovered rules: a copy or an add once two lights are counted. The first
/// two rows never count more than two. With the fix nothing is dropped.
private let vanillaDropped: [String: Int] = ["delete-duplicate-light-twice": 2, "add-light-twice": 1]
private let lightInputs = ["ours-light-roots.png", "ours-light-nested.png"]
private let fixName = "KK_Fix_UnlimitedMapLights"

private func optIn(_ variables: [String]) -> Bool {
    variables.allSatisfy { !(ProcessInfo.processInfo.environment[$0] ?? "").isEmpty }
}

/// Our exports both players load, from phase A's fixture, for
/// `.unlimitedMapLights` (the default refuses both):
/// - roots: two point lights added at the root (keys 16, 17). CharaStudio
///   1.0.4.2 loads root lights unchecked (SceneInfo.cs:323–352).
/// - nested: a point light at the root (16) and a new folder (17) holding
///   another (18), which the load reads after two lights and drops
///   (ObjectInfoAssist.cs:30–44).
private func lightInputEdits(_ name: String) throws -> SourceSceneEdits {
    var edits = SourceSceneEdits()
    let point = SourceSceneInsertion.Record.light(SourceSceneNewLight(no: 1))
    switch name {
    case "ours-light-roots.png": edits.insertions = [.init(point), .init(point)]
    case "ours-light-nested.png": edits.insertions = [.init(point), .init(.folder(name: "フォルダー")), .init(point, parent: .inserted(1))]
    default: throw SourceFixtureError.missing("light input \(name)")
    }
    return edits
}

/// What the vanilla player keeps of an input: the nested input without its
/// folder's light. Every other load keeps the whole file.
private func vanillaKeptEdits(_ name: String) throws -> SourceSceneEdits? {
    guard name == "ours-light-nested.png" else { return nil }
    var edits = try lightInputEdits(name)
    edits.insertions.removeLast()
    return edits
}

@Test(.enabled(if: optIn([lightFixtureVariable, lightInputsVariable]),
               "Opt-in: set IKKOKU_PLUGIN_SCENE_PROBE (phase-a folder) and IKKOKU_LIGHT_PROBE_INPUTS (output folder)"))
func sourceSceneLightProbeWritesItsInputs() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require(lightFixtureVariable))
    let output = URL(fileURLWithPath: try SourceFixtureSupport.require(lightInputsVariable))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let source = try KoikatsuSceneReader.decodeDocument(Data(contentsOf: root.appendingPathComponent("fixture.png")))
    try #require(lightKeys(source) == [15], "phase A's fixture does not hold its one light L 15")
    for (name, expected) in zip(lightInputs, [[15, 16, 17], [15, 16, 18]] as [[Int32]]) {
        var edits = try lightInputEdits(name)
        #expect(throws: SourceSceneTopologyError.self, "\(name): the default should refuse three lights") { try source.editedData(edits) }
        edits.lightLimit = .unlimitedMapLights
        let data = try source.editedData(edits)
        #expect(try lightKeys(KoikatsuSceneReader.decodeDocument(data)) == expected, "\(name): not the planned lights")
        try data.write(to: output.appendingPathComponent(name))
    }
}

// Opt-in, like the ordered oracle, until the shared fixture map names an OL
// folder: the oracle is a private original-player run.
@Test(.enabled(if: optIn([lightOracleVariable]), "Opt-in: set IKKOKU_LIGHT_ORACLE to the probe's phase OL output folder"))
func sourceSceneLightExportsMatchCharaStudio() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require(lightOracleVariable))
    func load(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }
    func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func json(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: load(name)) as? [String: Any], "\(name) is not an object")
    }
    // The fix changes no byte of the one-light baseline save apart from
    // Sideloader's per-session LocalSlot values.
    let (vanillaBaseline, vanillaSlots) = lightSlotMasked(try load("vanilla-fixture.png"))
    let (fixBaseline, fixSlots) = lightSlotMasked(try load("fixture.png"))
    #expect(vanillaSlots == fixSlots && !fixSlots.isEmpty, "the two baselines' LocalSlot values are not in the same places")
    #expect(vanillaBaseline == fixBaseline, "the fix changed the baseline save outside Sideloader's LocalSlot values")
    // Our inputs, rebuilt from the exact fixture the run sent: they must be the bytes it sent.
    let run = try json("run.json")
    let sent = try #require(run["inputs"] as? [String: String])
    let input = try KoikatsuSceneReader.decodeDocument(load("source-fixture.png"))
    var ours: [String: Data] = [:]
    for name in lightInputs {
        var edits = try lightInputEdits(name); edits.lightLimit = .unlimitedMapLights
        ours[name] = try input.editedData(edits)
        try #require(sent[name] == hash(ours[name]!), "\(name): our export is not the input the run sent")
    }
    var rows: [[String: Any]] = [], postfixes: [Bool: [String: Set<String>]] = [:], highest: [Bool: Int] = [:]
    for unlimited in [false, true] {
        let prefix = unlimited ? "" : "vanilla-", limit: SourceSceneLightLimit = unlimited ? .unlimitedMapLights : .charaStudio
        let status = try json(prefix + "status.json"), trace = try json(prefix + "plugin-scene-trace.json")
        try #require(status["error"] is NSNull, "Do not compare a partial original-player run (\(prefix)status.json)")
        try #require(status["phase"] as? String == (unlimited ? "OU" : "OL"))
        #expect(((trace["plugins"] as? [String: Any])?[fixName] != nil) == unlimited, "\(prefix): \(fixName) loaded \(!unlimited)")
        let cases = try #require(trace["cases"] as? [String: [String: Any]])
        let names = try #require(trace["keys"] as? [String: Int]).mapValues { Int32($0) }
        // Each snapshot's getters: vanilla's follow lightCount, the fix's are forced.
        func check(_ snapshot: Any?, _ stage: String) throws {
            let s = try #require(snapshot as? [String: Any], "\(stage): no snapshot")
            let count = try #require(s["lightCount"] as? Int), lights = try #require(s["lights"] as? [Int])
            let allowed = try #require(s["isLightCheck"] as? Bool), over = try #require(s["isLightLimitOver"] as? Bool)
            #expect(count == lights.count, "\(stage): lightCount \(count) for lights \(lights)")
            #expect(allowed == (unlimited || count < 2) && over == (!unlimited && count > 2),
                    "\(stage): isLightCheck \(allowed) and isLightLimitOver \(over) at lightCount \(count)")
            highest[unlimited] = max(highest[unlimited] ?? 0, count)
        }
        let baseline = try load(prefix + "fixture.png")
        try #require(baseline == (try load(prefix + "resave-fixture.png")), "\(prefix): the baseline is not a fixed point")
        let source = try KoikatsuSceneReader.decodeDocument(baseline)
        try #require(lightKeys(source) == [names["L"]!])
        for row in lightCases {
            let observed = try #require(cases[row.label], "no trace for \(prefix)\(row.label)")
            let actions = try #require(observed["actions"] as? [[String: Any]])
            try #require(actions.map { $0["operation"] as? String } == row.steps.map(\.operation), "\(row.label): other operations than LightCases")
            try #require(actions.map { $0["name"] as? String } == row.steps.map(\.target))
            for stage in ["loaded", "afterSave", "reloaded", "afterResave"] { try check(observed[stage], "\(prefix)\(row.label) \(stage)") }
            for (index, action) in actions.enumerated() {
                for stage in ["before", "afterImmediate", "afterSettled"] { try check(action[stage], "\(prefix)\(row.label) step \(index) \(stage)") }
            }
            let saved = try load(prefix + "edit-\(row.label).png"), resaved = try load(prefix + "resave-edit-\(row.label).png")
            try #require(observed["savedSHA256"] as? String == hash(saved) && observed["resavedSHA256"] as? String == hash(resaved))
            #expect(saved == resaved, "\(prefix)\(row.label): CharaStudio's edit is not a fixed point")
            // A step that added nothing was dropped or refused, and left the keys and lights as they were.
            let dropped = actions.indices.filter { actions[$0]["operation"] as? String != "delete"
                && ((actions[$0]["copies"] ?? actions[$0]["added"]) as? [Int])?.isEmpty == true }
            #expect(dropped == (unlimited ? [] : vanillaDropped[row.label].map { [$0] } ?? []), "\(prefix)\(row.label): dropped steps \(dropped)")
            for index in dropped {
                let before = try #require(actions[index]["before"] as? [String: Any]), after = try #require(actions[index]["afterSettled"] as? [String: Any])
                #expect(before["usedKeys"] as? [Int] == after["usedKeys"] as? [Int] && before["lights"] as? [Int] == after["lights"] as? [Int],
                        "\(prefix)\(row.label): the dropped step \(index) changed the keys or the lights")
            }
            // Our export of the steps CharaStudio performed is its file; with a dropped step, ours of all of them is refused.
            let performed = row.steps.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
            var edits = try lightProbeEdits(performed, keys: names, source: source)
            edits.lightLimit = limit; edits.thumbnailData = try lightLeadingPNG(saved)
            let export = try source.editedData(edits)
            #expect(export == saved, "\(prefix)\(row.label): our export is not CharaStudio's file")
            var refused: Bool? = nil
            if !dropped.isEmpty {
                var all = try lightProbeEdits(row.steps, keys: names, source: source); all.lightLimit = limit
                refused = (try? source.editedData(all)) == nil
                #expect(refused == true, "\(prefix)\(row.label): our export of every step should be refused")
            }
            rows.append(["root": unlimited ? "fix" : "vanilla", "label": row.label, "dropped": dropped, "refusedAll": refused.map { $0 as Any } ?? NSNull(),
                         "copies": actions.compactMap { $0["copies"] ?? $0["added"] }, "expectedSHA256": hash(saved),
                         "actualSHA256": hash(export), "parity": export == saved, "leakedAtReload": observed["leakedAtReload"] ?? NSNull()])
        }
        if !unlimited {
            // The dropped copy left nothing behind: its file is the one-copy row's.
            #expect(try load(prefix + "edit-delete-duplicate-light-twice.png") == load(prefix + "edit-delete-duplicate-light.png"),
                    "vanilla: the dropped copy left a trace in the saved file")
        }
        for name in lightInputs {
            let observed = try #require(cases[name], "no trace for \(prefix)\(name)")
            let loaded = try #require(observed["loaded"] as? [String: Any])
            try check(loaded, "\(prefix)\(name) loaded"); try check(observed["afterResave"], "\(prefix)\(name) afterResave")
            let kept = unlimited ? nil : try vanillaKeptEdits(name)
            let expected: [Int] = name == "ours-light-roots.png" ? [15, 16, 17] : kept == nil ? [15, 16, 18] : [15, 16]
            #expect(loaded["lights"] as? [Int] == expected, "\(prefix)\(name): loaded lights \(loaded["lights"] ?? "none")")
            if kept != nil { #expect((loaded["usedKeys"] as? [Int])?.contains(18) == false, "\(prefix)\(name): the dropped light kept its key") }
            let resave = try load(prefix + "resave-" + name)
            try #require(observed["resavedSHA256"] as? String == hash(resave))
            // The resave is the scene the player kept, apart from the thumbnail and LocalSlot values.
            let keptData = try kept.map { try input.editedData($0) } ?? ours[name]!
            #expect(try lightSlotMasked(afterPNG(resave)).0 == lightSlotMasked(afterPNG(keptData)).0, "\(prefix)\(name): the resave is not the kept scene")
            rows.append(["root": unlimited ? "fix" : "vanilla", "input": name, "lights": loaded["lights"] ?? NSNull(), "resavedSHA256": hash(resave)])
        }
        var patched: [String: Set<String>] = [:]
        for patch in (trace["patches"] as? [[String: Any]]) ?? [] {
            let method = try #require(patch["method"] as? String)
            patched[method, default: []].formUnion(((patch["Postfixes"] as? [[String: Any]]) ?? []).compactMap { $0["owner"] as? String })
        }
        postfixes[unlimited] = patched
    }
    // The fix answers through both getters: forced values at three lights, and a postfix on each only it adds.
    #expect((highest[true] ?? 0) >= 3, "the fix player never held three lights")
    let added = Set((postfixes[true] ?? [:]).filter { !$0.value.subtracting(postfixes[false]?[$0.key] ?? []).isEmpty }.keys)
    #expect(added.isSuperset(of: ["get_isLightCheck", "get_isLightLimitOver"]), "the fix's postfixes are on \(added.sorted())")
    if let path = ProcessInfo.processInfo.environment[lightReportVariable], !path.isEmpty {
        let report: [String: Any] = ["schemaVersion": 1, "oracle": root.path, "rows": rows, "fixPostfixes": added.sorted()]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    print("light oracle:\n" + rows.map { row in
        if let label = row["label"] { return "\(row["root"]!) \(label): parity \(row["parity"]!), dropped \(row["dropped"]!)" }
        return "\(row["root"]!) \(row["input"]!): lights \(row["lights"]!)"
    }.joined(separator: "\n"))
}

/// The probe's light steps as our export's, with `order` set. A light has no
/// children, so a duplicate is one insertion; add-light is a new
/// `OILightInfo` with the constructor's values (`SourceSceneNewLight`).
private func lightProbeEdits(_ steps: [(operation: String, target: String)], keys: [String: Int32],
                             source: KoikatsuSceneDocument) throws -> SourceSceneEdits {
    var edits = SourceSceneEdits(), order: [SourceSceneInsertion.Step] = []
    for step in steps {
        let first = edits.insertions.count
        switch step.operation {
        case "delete":
            let key = try #require(keys[step.target]); edits.deletions.insert(key); order.append(.delete(key))
        case "duplicate":
            let key = try #require(keys[step.target])
            let record = try #require(lightRecord(source.snapshot.roots, key), "no record \(key)")
            try #require(record.kind == .light && record.children.isEmpty, "light cases copy one light")
            edits.insertions.append(.init(.duplicate(of: key))); order.append(.insert([first]))
        case "add-light":
            edits.insertions.append(.init(.light(SourceSceneNewLight(no: try #require(Int32(step.target)))))); order.append(.insert([first]))
        default: throw SourceFixtureError.missing("light operation \(step.operation)")
        }
    }
    edits.order = order
    return edits
}

private func lightRecord(_ records: [KoikatsuObjectRecord], _ key: Int32) -> KoikatsuObjectRecord? {
    for record in records {
        if record.sourceKey == key { return record }
        if let found = lightRecord(record.children, key) { return found }
        for children in (record.character?.accessoryChildren ?? [:]).values {
            if let found = lightRecord(children, key) { return found }
        }
    }
    return nil
}

/// Every light record's key, nested ones included, sorted.
private func lightKeys(_ document: KoikatsuSceneDocument) -> [Int32] {
    var keys: [Int32] = []
    func visit(_ records: [KoikatsuObjectRecord]) {
        for record in records {
            if record.kind == .light { keys.append(record.sourceKey) }
            visit(record.children)
            for children in (record.character?.accessoryChildren ?? [:]).values { visit(children) }
        }
    }
    visit(document.snapshot.roots)
    return keys.sorted()
}

private func lightLeadingPNG(_ data: Data) throws -> Data {
    var reader = try KoikatsuBinaryReader(data)
    try reader.skipPNG()
    return data.prefix(reader.offset)
}

private func afterPNG(_ data: Data) throws -> Data {
    var reader = try KoikatsuBinaryReader(data)
    try reader.skipPNG()
    return Data(data.suffix(from: data.startIndex + reader.offset))
}

/// The data with every Sideloader `LocalSlot` uint32 zeroed, and their ranges.
private func lightSlotMasked(_ data: Data) -> (Data, [Range<Int>]) {
    var bytes = [UInt8](data)
    let head: [UInt8] = [0xa9] + Array("LocalSlot".utf8) + [0xce]
    var ranges: [Range<Int>] = [], start = 0
    while start + head.count <= bytes.count {
        if Array(bytes[start..<(start + head.count)]) == head, start + head.count + 4 <= bytes.count {
            ranges.append((start + head.count)..<(start + head.count + 4)); start += head.count
        } else { start += 1 }
    }
    for range in ranges { for offset in range { bytes[offset] = 0 } }
    return (Data(bytes), ranges)
}
