import Foundation
import Testing
import Assets
import Character
@testable import Studio

// Phases C and D of the plug-in scene probe (Tools/reverse/original_plugin_scene_probe.py,
// fixtures/OriginalPluginRewriteProbe.cs), ST-T03j. Phase C: CharaStudio,
// with KKPE, NodesConstraints and MaterialEditor loaded, gave phase A's
// fixture a female W (a default ChaFileControl) and data in all three
// plug-ins, saved its load-then-save as fixture.png, and saved its own
// delete and duplicate edits of that (edit-<label>.png). Our export of each
// edit must be CharaStudio's file apart from KKPE's per-session instance
// IDs, in the scene's KKPE entry and in every character card. Phase D
// loaded both, and our exports' plug-in state after the load must be
// CharaStudio's, object by object.
//
// The fixture's keys come from phase A (folder F 0 [M2 3, V2 4], vanilla item
// V1 1 [M4 6], mod items M1 2 and M3 5, route R 7, camera C 14, light L 15);
// W, W2 and the lone collider LC are in phase C's plugin-scene-trace.json.

private let phaseCVariable = "IKKOKU_PLUGIN_SCENE_PROBE_C"
private let phaseCInputsVariable = "IKKOKU_PLUGIN_SCENE_INPUTS_C"
private let phaseDVariable = "IKKOKU_PLUGIN_SCENE_PROBE_D"
private let phaseBVariable = "IKKOKU_PLUGIN_SCENE_PROBE_B"
private let rewriteEdits = ["delete", "delete-folder", "delete-character", "delete-parent", "duplicate",
                            "duplicate-subtree", "duplicate-character", "delete-duplicate"]
private let colliderEdits = ["lc-delete-character", "lc-delete-collider", "lc-duplicate-collider", "lc-duplicate-character"]
/// Edits our writer refuses: a delete with an item copy (#278), and a copy of
/// a controller a lone collider names (DynamicBonesEditor.cs:1799).
private let refusedEdits = ["delete-duplicate": "KKPE", "lc-duplicate-character": "KKPE"]

@Test(.enabled(if: SourceFixtureSupport.shouldRun([phaseCVariable]), "Requires IKKOKU_PLUGIN_SCENE_PROBE_C (the probe's phase-c folder)"))
func sourceScenePluginRewritesMatchCharaStudioEdits() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require(phaseCVariable))
    func load(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }
    let keys = try probeKeys(root)
    var lines: [String] = []
    for (fixtureName, labels) in try fixtures(root) {
        let fixture = try load(fixtureName)
        let source = try KoikatsuSceneReader.decodeDocument(fixture)
        // The fixture holds data in all three plug-ins and in W's card.
        let kkex = try SourceSceneKKEx.parse(source.trailingData)
        let xml = try kkpeSceneInfo(kkex) ?? ""
        #expect(xml.contains("<advancedObjects>"), "\(fixtureName): no KKPE bone data")
        #expect(try materialRecordCount(kkex) >= 4, "\(fixtureName): fewer MaterialEditor records than authored")
        #expect(try constraintCount(kkex) == 3, "\(fixtureName): not the three authored constraints")
        let w = try #require(record(source, keys["W"]!)?.character)
        #expect(try KKPEPlan.card(w.cardData, key: keys["W"]!)?.offset != nil, "W's card has no KKPE data in its current block")
        // CharaStudio's load-then-save is a fixed point up to KKPE's IDs; the
        // comparison sees one changed KKPE attribute of the same length.
        #expect(try pluginProbeComparable(load("resave-\(fixtureName)")) == pluginProbeComparable(fixture), "resave-\(fixtureName)")
        let flag = Data(#"enabled="true""#.utf8), changed = Data(#"enabled="tru_""#.utf8)
        var mutated = fixture; mutated.replaceSubrange(try #require(fixture.range(of: flag, options: .backwards)), with: changed)
        #expect(try pluginProbeComparable(mutated) != pluginProbeComparable(fixture))
        lines.append("\(fixtureName): \(kkex.entries.map(\.id).joined(separator: ", ")); resave is a fixed point")
        for label in labels {
            let saved = try load("edit-\(label).png")
            let theirs = try KoikatsuSceneReader.decodeDocument(saved)
            var edits = try rewriteProbeEdits(label, keys: keys, source: source, theirs: theirs)
            edits.thumbnailData = try leadingPNG(saved)
            do {
                let ours = try source.editedData(edits)
                #expect(refusedEdits[label] == nil, "\(label): accepted, but expected a refusal")
                let same = try pluginProbeComparable(ours) == pluginProbeComparable(saved)
                #expect(same, "\(label): the file differs beyond KKPE's instance IDs")
                lines.append("\(label): " + (ours == saved ? "byte-identical" : same ? "identical apart from KKPE's instance IDs (\(ours.count) and \(saved.count) B)" : "DIFFERS"))
            } catch let error as SourceSceneTopologyError {
                let reason = error.errorDescription ?? ""
                #expect(refusedEdits[label].map { reason.contains($0) } == true, "\(label): \(reason)")
                lines.append("\(label): refused (\(reason))")
            }
            #expect(try pluginProbeComparable(load("resave-edit-\(label).png")) == pluginProbeComparable(saved), "resave-edit-\(label)")
        }
    }
    print("plug-in probe phase C:\n" + lines.joined(separator: "\n"))
}

/// Phase D's inputs: our export of each edit phase C saved (ours-<label>.png;
/// an edit our writer refuses has none), and card-link-int32.png.
@Test(.enabled(if: SourceFixtureSupport.shouldRun([phaseCVariable, phaseCInputsVariable]),
               "Requires IKKOKU_PLUGIN_SCENE_PROBE_C (phase-c folder) and IKKOKU_PLUGIN_SCENE_INPUTS_C (output folder)"))
func sourceScenePluginRewritesWriteThePhaseDInputs() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require(phaseCVariable))
    let output = URL(fileURLWithPath: try SourceFixtureSupport.require(phaseCInputsVariable))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let keys = try probeKeys(root)
    var written: [String] = []
    for (fixtureName, labels) in try fixtures(root) {
        let source = try KoikatsuSceneReader.decodeDocument(Data(contentsOf: root.appendingPathComponent(fixtureName)))
        for label in labels where refusedEdits[label] == nil {
            let saved = try Data(contentsOf: root.appendingPathComponent("edit-\(label).png"))
            var edits = try rewriteProbeEdits(label, keys: keys, source: source, theirs: KoikatsuSceneReader.decodeDocument(saved))
            edits.thumbnailData = try leadingPNG(saved)
            try source.editedData(edits).write(to: output.appendingPathComponent("ours-\(label).png"))
            written.append(label)
        }
    }
    #expect(written.count >= rewriteEdits.count - 1)
    // card-link.png's KK_AnimationController keys are MessagePack fixints,
    // which NodesConstraints' `(int)` cast rejects (NodesConstraints.cs:2290);
    // the variant writes them as Int32 and shortens Pad by the bytes that adds.
    let trace = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("plugin-scene-trace.json"))) as? [String: Any]
    let link = try #require((trace?["cases"] as? [String: Any])?["card-link"] as? [String: Any])
    let target = try #require(link["ikTarget"] as? String)
    let linked = try #require(link["linked"] as? Int), eyes = try #require(link["eyes"] as? Int)
    let original = try Data(contentsOf: root.appendingPathComponent("card-link.png"))
    let variant = try int32CardLinks(original, target: target, linked: linked, eyes: eyes)
    #expect(variant.count == original.count)
    let w2 = try #require(record(KoikatsuSceneReader.decodeDocument(variant), keys["W2"]!)?.character)
    #expect(try SourceScenePluginData.cardLinkSteps(w2.card().extensions().payload) == [Int32(linked), Int32(eyes)])
    let before = try #require(record(KoikatsuSceneReader.decodeDocument(original), keys["W2"]!)?.character)
    #expect(try SourceScenePluginData.cardLinkSteps(before.card().extensions().payload) == [])
    try variant.write(to: output.appendingPathComponent("card-link-int32.png"))
    // PR 1's card rule: deleting a live link's target is refused only in the variant.
    let source = try KoikatsuSceneReader.decodeDocument(variant)
    #expect(throws: SourceSceneTopologyError.self) { try source.editedData(.init(deletions: [Int32(linked)])) }
    _ = try KoikatsuSceneReader.decodeDocument(original).editedData(.init(deletions: [Int32(linked)]))
    _ = try source.editedData(.init(deletions: [1]))
}

/// Phase D: every plug-in's per-object state after the original player
/// loaded our export is the state it has after loading CharaStudio's own
/// edit; our exports' load-then-save is CharaStudio's edit up to KKPE's IDs;
/// the card-link controls; survey 3 against survey 2.
@Test(.enabled(if: SourceFixtureSupport.shouldRun([phaseCVariable, phaseDVariable]),
               "Requires IKKOKU_PLUGIN_SCENE_PROBE_C and IKKOKU_PLUGIN_SCENE_PROBE_D (the probe's phase-c and phase-d folders)"))
func sourceScenePluginRewritesReloadAsCharaStudioEdits() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require(phaseDVariable))
    let phaseC = URL(fileURLWithPath: try SourceFixtureSupport.require(phaseCVariable))
    func load(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }
    let trace = try JSONSerialization.jsonObject(with: load("plugin-scene-trace.json")) as? [String: Any]
    let cases = try #require(trace?["cases"] as? [String: Any])
    let readback = try #require(cases["readback"] as? [String: Any])
    func state(_ name: String) throws -> NSDictionary {
        try #require((readback[name] as? [String: Any])?["state"] as? NSDictionary, "no state for \(name)")
    }
    var lines: [String] = []
    let ours = readback.keys.filter { $0.hasPrefix("ours-") }.sorted()
    #expect(ours.count >= rewriteEdits.count - 1)
    for name in ours {
        let label = String(name.dropFirst("ours-".count).dropLast(".png".count))
        let theirs = try state("edit-\(label).png"), mine = try state(name)
        #expect(mine == theirs, "\(label): plug-in state after the load differs")
        for plugin in ["kkpe", "materialEditor", "nodesConstraints"] where (mine[plugin] as? NSObject) != (theirs[plugin] as? NSObject) {
            lines.append("\(label): \(plugin) differs")
        }
        let same = try pluginProbeComparable(load("resave-\(name)")) == pluginProbeComparable(Data(contentsOf: phaseC.appendingPathComponent("edit-\(label).png")))
        #expect(same, "resave-\(name)")
        lines.append("\(label): same plug-in state as CharaStudio's edit; resave \(same ? "is CharaStudio's edit apart from KKPE's IDs" : "DIFFERS")")
    }
    // The fixture's state is not empty: the comparison above saw real data.
    let fixture = try state("fixture.png")
    let controllers = (fixture["kkpe"] as? [String: [String: Any]]) ?? [:]
    #expect(controllers.values.filter { ($0["xml"] as? String)?.contains("advancedObjects") == true }.count >= 2)
    #expect(((fixture["nodesConstraints"] as? [Any])?.count) == 3)
    #expect(((fixture["materialEditor"] as? [String: Any])?["textures"] as? [Any])?.count == 2)
    // NodesConstraints attaches KK_AnimationController card links only when
    // the keys are Int32 (PR 1's card rule), and the survey model counts them.
    let link = try #require(cases["card-link"] as? [String: Any])
    let fixint = ((link["card-link.png"] as? [String: Any])?["nodesConstraints"] as? [Any])?.count
    let int32 = ((link["card-link-int32.png"] as? [String: Any])?["nodesConstraints"] as? [Any])?.count
    #expect(fixint == 0); #expect(int32 == 2)
    let survey = try JSONSerialization.jsonObject(with: load("card-link-survey.json")) as? [String: Any]
    func counts(_ name: String) -> [String: Any]? { (survey?[name] as? [String: Any])?["counts"] as? [String: Any] }
    #expect(counts("card-link.png")?["cardStepScenes"] as? Int == 0)
    #expect(counts("card-link-int32.png")?["cardLiveScenes"] as? Int == 1)
    lines.append("card links: \(fixint ?? -1) constraints from fixint keys, \(int32 ?? -1) from Int32 keys")
    // Survey 3 (these rules) against survey 2 (PR 1's), per edit kind.
    let three = try JSONSerialization.jsonObject(with: load("survey3.json")) as? [String: Any]
    #expect(three?["parityMismatches"] as? Int == 0)
    if let path = ProcessInfo.processInfo.environment[phaseBVariable],
       let two = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("survey2.json"))) as? [String: Any],
       let after = three?["scenesByEditKindAfter"] as? [String: [String: Int]], let before = two["scenesByEditKindAfter"] as? [String: [String: Int]] {
        for kind in after.keys.sorted() {
            func split(_ d: [String: Int]?) -> String { ["all", "some", "none", "notApplicable"].map { "\(d?[$0] ?? 0)" }.joined(separator: "/") }
            lines.append("survey \(kind) all/some/none/n.a.: \(split(before[kind])) -> \(split(after[kind]))")
        }
    }
    print("plug-in probe phase D:\n" + lines.joined(separator: "\n"))
}

// MARK: - Helpers

/// The fixtures phase C saved and the edits made from each.
private func fixtures(_ root: URL) throws -> [(String, [String])] {
    var result = [("fixture.png", rewriteEdits)]
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-lc.png").path) { result.append(("fixture-lc.png", colliderEdits)) }
    return result
}

private func probeKeys(_ root: URL) throws -> [String: Int32] {
    let trace = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("plugin-scene-trace.json"))) as? [String: Any]
    let keys = try #require(trace?["keys"] as? [String: Int])
    #expect(keys["F"] == 0 && keys["M1"] == 2 && keys["M3"] == 5 && keys["W"] != nil)
    return keys.mapValues { Int32($0) }
}

/// The probe's edits (OriginalPluginRewriteProbe.cs `Edit`) as our export's.
private func rewriteProbeEdits(_ label: String, keys: [String: Int32], source: KoikatsuSceneDocument,
                               theirs: KoikatsuSceneDocument) throws -> SourceSceneEdits {
    let w = keys["W"]!
    switch label {
    case "delete": return .init(deletions: [2])
    case "delete-folder": return .init(deletions: [0])
    case "delete-character", "lc-delete-character": return .init(deletions: [w])
    case "delete-parent": return .init(deletions: [5])
    case "duplicate": return .init(insertions: [.init(.duplicate(of: 5))])
    case "duplicate-subtree":
        return .init(insertions: [.init(.duplicate(of: 0)), .init(.duplicate(of: 3), parent: .inserted(0)),
                                  .init(.duplicate(of: 4), parent: .inserted(0))])
    case "duplicate-character", "lc-duplicate-character": return .init(insertions: [.init(.duplicate(of: w))])
    case "delete-duplicate": return .init(deletions: [1], insertions: [.init(.duplicate(of: 5))])
    case "lc-delete-collider": return .init(deletions: [try #require(keys["LC"])])
    case "lc-duplicate-collider": return .init(insertions: [.init(.duplicate(of: try #require(keys["LC"])))])
    default: throw SourceFixtureError.missing("probe edit \(label)")
    }
}

private func record(_ document: KoikatsuSceneDocument, _ key: Int32) -> KoikatsuObjectRecord? {
    func find(_ records: [KoikatsuObjectRecord]) -> KoikatsuObjectRecord? {
        for record in records {
            if record.sourceKey == key { return record }
            if let found = find(record.children) { return found }
        }
        return nil
    }
    return find(document.snapshot.roots)
}

private func leadingPNG(_ data: Data) throws -> Data {
    var reader = try KoikatsuBinaryReader(data)
    try reader.skipPNG()
    return data.prefix(reader.offset)
}

/// A scene compared up to KKPE's per-session instance IDs: the scene bytes
/// after the PNG with each character card cut out, each card as its own
/// parts, and the KKEx trailer entry by entry. Every `uniqueId` and
/// `poseControllerId` value, in the cards' KKPE `characterInfo` and the
/// scene's KKPE `sceneInfo`, is renamed in order of first appearance across
/// the file (cards first, as they come first), so a copy's fresh ID of any
/// length compares equal while the equality pattern among IDs must match.
func pluginProbeComparable(_ data: Data) throws -> [String] {
    let document = try KoikatsuSceneReader.decodeDocument(data)
    let trailer = document.trailingData
    let scene = Data(data.dropFirst(try leadingPNG(data).count).dropLast(trailer.count))
    var cards: [Data] = []
    func visit(_ record: KoikatsuObjectRecord) {
        if let character = record.character { cards.append(character.cardData) }
        for child in record.children { visit(child) }
    }
    document.snapshot.roots.forEach(visit)
    var names: [String: Int] = [:], parts: [String] = [], rest = Data(), at = scene.startIndex
    for card in cards {
        let range = try #require(scene.range(of: card, in: at..<scene.endIndex), "a character card is not in the scene bytes")
        rest += scene[at..<range.lowerBound] + Data("<card>".utf8)
        parts += try normalizedCard(card, names: &names)
        at = range.upperBound
    }
    rest += scene[at...]
    parts.insert(rest.base64EncodedString(), at: 0)
    guard !trailer.isEmpty else { return parts }
    let kkex = try SourceSceneKKEx.parse(trailer)
    parts.append("KKEx \(kkex.dataVersion)")
    for entry in kkex.entries {
        if entry.id == SourceScenePluginData.kkpe, let xml = try kkpeSceneInfo(kkex) {
            parts.append("kkpe \(entry.version.map(String.init) ?? "-") " + renamed(xml, names: &names))
        } else {
            parts.append(entry.id + " " + Data(kkex.bytes[entry.span]).base64EncodedString())
        }
    }
    return parts
}

/// A card's parts: its header fields, each block but KKEx by bytes, and its
/// Extended Save entries by bytes, KKPE's `characterInfo` renamed.
private func normalizedCard(_ data: Data, names: inout [String: Int]) throws -> [String] {
    let card = try SourceCharacterCard.decode(data)
    var parts = ["card \(card.product) \(card.version) face \(card.faceThumbnailData.base64EncodedString())"]
    for block in card.blocks where block.name != "KKEx" { parts.append("\(block.name) \(block.version) \(block.data.base64EncodedString())") }
    let extensions = try card.extensions()
    parts.append("extensions \(extensions.format ?? "-") trailing \(card.trailingData.count)")
    guard let payload = extensions.payload else { return parts }
    let bytes = [UInt8](payload)
    var cursor = SourceMessagePackSpans(bytes, range: 0..<bytes.count)
    for field in try cursor.fields() ?? [] {
        guard field.key == "kkpe" else { parts.append(field.key + " " + Data(bytes[field.value]).base64EncodedString()); continue }
        var plugin = SourceMessagePackSpans(bytes, range: field.value)
        guard case .array(2) = try plugin.head() else { parts.append("kkpe " + Data(bytes[field.value]).base64EncodedString()); continue }
        let versionStart = plugin.offset
        try plugin.skip()
        var line = "kkpe " + Data(bytes[versionStart..<plugin.offset]).base64EncodedString()
        for data in try plugin.fields() ?? [] {
            var value = SourceMessagePackSpans(bytes, range: data.value)
            if data.key == "characterInfo", case .string(let count) = try value.head() {
                let text = try value.payload(count)
                line += " characterInfo " + renamed(String(decoding: bytes[text], as: UTF8.self), names: &names)
            } else {
                line += " \(data.key) " + Data(bytes[data.value]).base64EncodedString()
            }
        }
        parts.append(line)
    }
    return parts
}

private func renamed(_ xml: String, names: inout [String: Int]) -> String {
    let pattern = try! NSRegularExpression(pattern: #"(uniqueId|poseControllerId)="(-?[0-9]+)""#)
    var result = "", last = xml.startIndex
    for match in pattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
        let attribute = Range(match.range(at: 1), in: xml)!, value = Range(match.range(at: 2), in: xml)!
        let name = names[String(xml[value])] ?? names.count
        names[String(xml[value])] = name
        result += xml[last..<attribute.lowerBound] + "\(xml[attribute])=\"#\(name)\""
        last = Range(match.range, in: xml)!.upperBound
    }
    return result + xml[last...]
}

private func kkpeSceneInfo(_ kkex: SourceSceneKKEx) throws -> String? {
    guard let entry = kkex.entries.first(where: { $0.id == SourceScenePluginData.kkpe }),
          let fields = try kkex.fields(entry), fields.count == 1, fields[0].key == "sceneInfo" else { return nil }
    return try kkex.string(fields[0].value)
}

private func materialRecordCount(_ kkex: SourceSceneKKEx) throws -> Int {
    guard let entry = kkex.entries.first(where: { $0.id == SourceScenePluginData.materialEditor }),
          let fields = try kkex.fields(entry) else { return 0 }
    var count = 0
    for field in fields where field.key.hasSuffix("List") {
        var list = SourceMessagePackSpans(kkex.bytes, range: field.value)
        if case .binary(let length) = try list.head() {
            let payload = try list.payload(length)
            var inner = SourceMessagePackSpans(kkex.bytes, range: payload)
            if case .array(let n) = try inner.head() { count += n }
        }
    }
    return count
}

private func constraintCount(_ kkex: SourceSceneKKEx) throws -> Int {
    guard let entry = kkex.entries.first(where: { $0.id == SourceScenePluginData.nodesConstraints }),
          let fields = try kkex.fields(entry), let field = fields.first(where: { $0.key == "constraints" }),
          let xml = try kkex.string(field.value) else { return 0 }
    return xml.components(separatedBy: "<constraint ").count - 1
}

/// card-link.png with W2's KK_AnimationController `Links` value and `Eyes`
/// written as MessagePack Int32 (d2) instead of fixints, and `Pad`'s str8
/// shortened by the eight bytes that adds, so no length in the card changes.
private func int32CardLinks(_ data: Data, target: String, linked: Int, eyes: Int) throws -> Data {
    let name = Array(target.utf8)
    guard name.count < 32, (0..<128).contains(linked), (0..<128).contains(eyes) else { throw SourceFixtureError.missing("fixint card links") }
    let links = Array("Links".utf8), eyesKey = Array("Eyes".utf8), padKey = Array("Pad".utf8)
    let patches: [([UInt8], [UInt8])] = [
        ([0xa5] + links + [0x81, UInt8(0xa0 + name.count)] + name + [UInt8(linked)],
         [0xa5] + links + [0x81, UInt8(0xa0 + name.count)] + name + [0xd2, 0, 0, 0, UInt8(linked)]),
        ([0xa4] + eyesKey + [UInt8(eyes)], [0xa4] + eyesKey + [0xd2, 0, 0, 0, UInt8(eyes)]),
        ([0xa3] + padKey + [0xd9, 40] + [UInt8](repeating: 0x70, count: 40), [0xa3] + padKey + [0xd9, 32] + [UInt8](repeating: 0x70, count: 32)),
    ]
    var bytes = [UInt8](data)
    var found: [(Range<Int>, [UInt8])] = []
    for (old, new) in patches {
        let ranges = occurrences(of: old, in: bytes)
        guard ranges.count == 1 else { throw SourceFixtureError.missing("one \(old.prefix(6)) sequence in card-link.png (found \(ranges.count))") }
        found.append((ranges[0], new))
    }
    for (range, new) in found.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { bytes.replaceSubrange(range, with: new) }
    return Data(bytes)
}

private func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Range<Int>] {
    guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
    var result: [Range<Int>] = []
    for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
        if Array(haystack[start..<(start + needle.count)]) == needle { result.append(start..<(start + needle.count)) }
    }
    return result
}
