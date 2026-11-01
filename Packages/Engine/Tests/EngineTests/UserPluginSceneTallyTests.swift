import Foundation
import Testing
import CryptoKit
import Assets
import Character
@testable import Studio

// ST-T03k: what the installed scenes' Sideloader records name, and where
// their lights are (docs/reference/studio/scene-editing.md, "Survey 3's
// stale Sideloader records"). Survey 3 counted 8 scenes with a Sideloader
// record naming an object the scene does not have. Those records name nested
// lights, which the survey's own walk had dropped: CharaStudio drops a nested
// light while two lights are counted (ObjectInfoAssist.LoadChild), the survey
// never reset that count between scenes, and its player root lacked
// KK_Fix_UnlimitedMapLights, which the install has. This tally reads the
// scenes as the writer does, which keeps every light, as the install does.
//
// Opt-in: IKKOKU_USER_PLUGIN_SCENES names a read-only copy of the install's
// UserData/studio/scene. Unset: skipped. Set but unreachable: skipped, or a
// failure under IKKOKU_REQUIRE_SOURCE_FIXTURES=1. AppleDouble `._*` files
// are skipped. Only counts and 12-digit SHA-256 prefixes are printed or
// asserted, never a file name. IKKOKU_USER_PLUGIN_SCENES_REPORT=<path> also
// writes the counts and per-scene rows (full SHA-256) as JSON to a private
// path. IKKOKU_USER_PLUGIN_SCENES_JUDGE=1 judges every single-target edit of
// the scenes whose records name nested lights, as the survey enumerates them
// (about 150 s with -c release).

private enum UserPluginScenes {
    static let key = "IKKOKU_USER_PLUGIN_SCENES"
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var root: String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
    static var strict: Bool { environment["IKKOKU_REQUIRE_SOURCE_FIXTURES"] == "1" }
    static var reachable: Bool {
        guard let root else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root, isDirectory: &directory) && directory.boolValue
    }
    /// Set and reachable, or set under strict mode, which then fails naming the cause.
    static var enabled: Bool { root != nil && (reachable || strict) }
    static var judge: Bool { enabled && environment["IKKOKU_USER_PLUGIN_SCENES_JUDGE"] == "1" }
    static let unreachable = "IKKOKU_USER_PLUGIN_SCENES is set but its folder is unreachable: is the My Book volume mounted?"

    /// The scene PNGs under the root, AppleDouble files skipped, in path order.
    static func files() -> [URL] {
        guard let root, let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "png" && !url.lastPathComponent.hasPrefix("._") {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Runs `body` on a thread with an 8 MiB stack. A Debug decode of the
    /// corpus's deepest scene needs close to 512 KiB, the default for
    /// secondary threads, Swift Testing's included (#321).
    static func onLargeStack(_ body: @escaping @Sendable () throws -> Void) throws {
        final class Box: @unchecked Sendable { var error: Error? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let thread = Thread { do { try body() } catch { box.error = error }; done.signal() }
        thread.stackSize = 8 << 20
        thread.start(); done.wait()
        if let error = box.error { throw error }
    }
}

private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// One scene's Sideloader records and lights.
private struct SceneTally {
    var objects = 0, depth = 0, nestedLights = 0, vanillaDroppedLights = 0
    var records = [String: Int](), recordsNamingNoObject = 0, wrongKind = 0, duplicates = 0, orderMismatches = 0, slotMismatches = 0
    var recordsNamingNestedLights = 0, recordsNamingVanillaDroppedLights = 0
    var sideloaderEntry = false, sideloaderRefusals = 0

    init(_ document: KoikatsuSceneDocument, trailer: SourceSceneKKEx) throws {
        let walk = SourceSceneInsertionPlan.records(document.snapshot)
        var objects: [Int32: KoikatsuObjectRecord] = [:], order: [Int32: Int] = [:], counters: [KoikatsuObjectKind: Int] = [:]
        for record in walk {
            objects[record.sourceKey] = record
            guard [.item, .light, .character].contains(record.kind) else { continue }
            order[record.sourceKey] = counters[record.kind, default: 0]; counters[record.kind, default: 0] += 1
        }
        self.objects = walk.count
        // Lights in file read order. Root lights always load; CharaStudio
        // without the light fix drops a nested light while two lights are
        // counted (ObjectInfoAssist.LoadChild; a dropped light uncounts
        // itself through OILightInfo.DeleteKey).
        var nested = Set<Int32>(), dropped = Set<Int32>(), kept = 0
        func visit(_ record: KoikatsuObjectRecord, _ level: Int, nestedIn: Bool) {
            depth = max(depth, level)
            if record.kind == .light {
                if nestedIn { nested.insert(record.sourceKey) }
                if nestedIn && kept >= 2 { dropped.insert(record.sourceKey) } else { kept += 1 }
            }
            for child in record.children { visit(child, level + 1, nestedIn: true) }
            for point in (record.character?.accessoryChildren ?? [:]).keys.sorted() {
                for child in record.character!.accessoryChildren[point]! { visit(child, level + 1, nestedIn: true) }
            }
        }
        for root in document.snapshot.roots { visit(root, 1, nestedIn: false) }
        nestedLights = nested.count; vanillaDroppedLights = dropped.count
        guard let entry = trailer.entries.first(where: { $0.id == SourceScenePluginData.sideloader && !$0.isNil }),
              let fields = try trailer.fields(entry) else { return }
        sideloaderEntry = true
        for field in fields where field.key == "itemInfo" || field.key == "patternInfo" {
            let pattern = field.key == "patternInfo"
            let list = try SourceMessagePack.decode(Data(trailer.bytes[field.value])).arrayValue ?? []
            records[field.key] = list.count
            var seen = Set<Int>()
            for value in list {
                guard let bytes = value.binaryValue else { continue }
                let map = try SourceMessagePack.decode(bytes).stringKeyedMap()
                let key = map["SceneDicKey"]?.integerValue ?? Int.min
                if !seen.insert(key).inserted { duplicates += 1 }
                guard let object = Int32(exactly: key).flatMap({ objects[$0] }) else { recordsNamingNoObject += 1; continue }
                if pattern ? object.kind != .item : ![.item, .light, .character].contains(object.kind) { wrongKind += 1 }
                if order[object.sourceKey] != map["SceneObjectOrder"]?.integerValue { orderMismatches += 1 }
                // SavePrefix writes the mod's own Slot into the object's number.
                if !pattern, let no = object.item?.no ?? object.light?.no ?? object.character?.animation.no,
                   Int(no) != map["Slot"]?.integerValue { slotMismatches += 1 }
                if nested.contains(object.sourceKey) { recordsNamingNestedLights += 1 }
                if dropped.contains(object.sourceKey) { recordsNamingVanillaDroppedLights += 1 }
            }
        }
        // The writer on two structural edits: a new folder and a delete.
        var edits = [SourceSceneEdits(insertions: [.init(.folder(name: "New"))])]
        if let last = walk.last { edits.append(SourceSceneEdits(deletions: [last.sourceKey])) }
        for edit in edits {
            let refusal: String? = autoreleasepool {
                do { _ = try document.editedData(edit); return nil } catch { return (error as? SourceSceneTopologyError)?.errorDescription ?? "" }
            }
            if let refusal, refusal.contains("Sideloader data") { sideloaderRefusals += 1 }
        }
    }
}

@Test(.enabled(if: UserPluginScenes.enabled, "Opt-in: IKKOKU_USER_PLUGIN_SCENES names the installed scenes"))
func installedScenesSideloaderRecordsNameLoadedObjects() throws {
    guard UserPluginScenes.reachable else { Issue.record(Comment(rawValue: UserPluginScenes.unreachable)); return }
    final class Result: @unchecked Sendable {
        var counts: [String: Int] = [:], rows: [[String: Any]] = [], undecodable: [String] = [], stale: [String] = [], refused: [String] = []
    }
    let result = Result()
    try UserPluginScenes.onLargeStack {
        func add(_ key: String, _ value: Int = 1) { result.counts[key, default: 0] += value }
        // One pool per scene: on a secondary thread, autoreleased file data would otherwise pile up.
        func scene(_ url: URL) throws {
            add("files")
            let data = try Data(contentsOf: url), hash = sha256(data)
            guard let document = try? KoikatsuSceneReader.decodeDocument(data) else { result.undecodable.append(String(hash.prefix(12))); return }
            func depth(_ record: KoikatsuObjectRecord) -> Int {
                1 + max(record.children.map(depth).max() ?? 0, record.character?.accessoryChildren.values.joined().map(depth).max() ?? 0)
            }
            result.counts["maxDepth"] = max(result.counts["maxDepth"] ?? 0, document.snapshot.roots.map(depth).max() ?? 0)
            // CharaStudio 1.0.4.2 keeps at most two lights; KK_Fix_UnlimitedMapLights lifts that.
            let lights = SourceSceneInsertionPlan.records(document.snapshot).filter { $0.kind == .light }.count
            if lights > 2 { add("scenesWithMoreThanTwoLights") }
            result.counts["maxLights"] = max(result.counts["maxLights"] ?? 0, lights)
            guard !document.trailingData.isEmpty else { add("noTrailer"); return }
            guard let trailer = try? SourceSceneKKEx.parse(document.trailingData) else { add("unreadableTrailer"); return }
            guard !trailer.entries.isEmpty else { add("emptyMap"); return }
            add("entries")
            let tally = try SceneTally(document, trailer: trailer)
            add("objects", tally.objects); add("nestedLights", tally.nestedLights); add("vanillaDroppedLights", tally.vanillaDroppedLights)
            if tally.nestedLights > 0 { add("nestedLightScenes") }
            guard tally.sideloaderEntry else { return }
            add("sideloaderScenes")
            if !tally.records.isEmpty { add("sideloaderScenesWithRecords") }
            add("itemInfoRecords", tally.records["itemInfo"] ?? 0); add("patternInfoRecords", tally.records["patternInfo"] ?? 0)
            add("recordsNamingNoObject", tally.recordsNamingNoObject); add("wrongKindRecords", tally.wrongKind)
            add("duplicateRecords", tally.duplicates); add("orderMismatches", tally.orderMismatches); add("slotMismatches", tally.slotMismatches)
            add("recordsNamingNestedLights", tally.recordsNamingNestedLights)
            add("recordsNamingVanillaDroppedLights", tally.recordsNamingVanillaDroppedLights)
            add("sideloaderRefusals", tally.sideloaderRefusals)
            if tally.recordsNamingNestedLights > 0 { add("scenesWithRecordsNamingNestedLights") }
            if tally.recordsNamingVanillaDroppedLights > 0 { add("scenesWithRecordsNamingVanillaDroppedLights") }
            if tally.recordsNamingNoObject + tally.wrongKind + tally.duplicates > 0 { result.stale.append(String(hash.prefix(12))) }
            if tally.sideloaderRefusals > 0 { result.refused.append(String(hash.prefix(12))) }
            result.rows.append(["sha256": hash, "objects": tally.objects, "depth": tally.depth, "nestedLights": tally.nestedLights,
                                "vanillaDroppedLights": tally.vanillaDroppedLights, "records": tally.records,
                                "recordsNamingNestedLights": tally.recordsNamingNestedLights,
                                "recordsNamingVanillaDroppedLights": tally.recordsNamingVanillaDroppedLights])
        }
        for url in UserPluginScenes.files() { try autoreleasepool { try scene(url) } }
        // What survey 3's walk held: every nested light dropped.
        result.counts["objectsWithoutNestedLights"] = (result.counts["objects"] ?? 0) - (result.counts["nestedLights"] ?? 0)
    }
    print("installed plug-in scenes: \(result.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
    let nested = result.rows.filter { ($0["recordsNamingNestedLights"] as? Int ?? 0) > 0 }.map { String(($0["sha256"] as! String).prefix(12)) }
    print("scenes whose Sideloader records name nested lights: \(nested.joined(separator: " "))")
    if let path = UserPluginScenes.environment["IKKOKU_USER_PLUGIN_SCENES_REPORT"], !path.isEmpty {
        let json = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "counts": result.counts, "rows": result.rows], options: [.sortedKeys, .prettyPrinted])
        try json.write(to: URL(fileURLWithPath: path))
    }
    #expect(result.counts["files", default: 0] > 0, "no scene files under IKKOKU_USER_PLUGIN_SCENES")
    #expect(result.undecodable.isEmpty, "scenes that do not decode: \(result.undecodable.joined(separator: " "))")
    // Every record names one loaded object of its kind; a scene with one that
    // does not would load partly unresolved (UniversalAutoResolver.cs:1334, :1342).
    #expect(result.stale.isEmpty, "scenes with a Sideloader record naming no object, the wrong kind or an object twice: \(result.stale.joined(separator: " "))")
    #expect(result.refused.isEmpty, "scenes whose structural edits the writer refuses for Sideloader: \(result.refused.joined(separator: " "))")
}

@Test(.enabled(if: UserPluginScenes.judge, "Opt-in: IKKOKU_USER_PLUGIN_SCENES_JUDGE=1 (use -c release)"))
func installedNestedLightScenesJudgeAsTheSurveyWould() throws {
    guard UserPluginScenes.reachable else { Issue.record(Comment(rawValue: UserPluginScenes.unreachable)); return }
    final class Result: @unchecked Sendable { var categories: [String: [String: Int]] = [:], reasons: [String: Int] = [:], sideloader = 0, scenes = 0 }
    let result = Result()
    try UserPluginScenes.onLargeStack {
        func scene(_ url: URL) throws {
            let data = try Data(contentsOf: url)
            guard let document = try? KoikatsuSceneReader.decodeDocument(data), !document.trailingData.isEmpty,
                  let trailer = try? SourceSceneKKEx.parse(document.trailingData),
                  try SceneTally(document, trailer: trailer).recordsNamingNestedLights > 0 else { return }
            result.scenes += 1
            let judged = try judgeSingleTargetEdits(document)
            for (kind, category) in judged.categories { result.categories[kind, default: [:]][category, default: 0] += 1 }
            for (reason, count) in judged.reasons { result.reasons[reason, default: 0] += count }
            result.sideloader += judged.sideloader
        }
        for url in UserPluginScenes.files() { try autoreleasepool { try scene(url) } }
    }
    print("nested-light scenes judged: \(result.scenes)")
    for (kind, categories) in result.categories.sorted(by: { $0.key < $1.key }) {
        print("  \(kind): all \(categories["all"] ?? 0), some \(categories["some"] ?? 0), none \(categories["none"] ?? 0)")
    }
    for (reason, count) in result.reasons.sorted(by: { $0.key < $1.key }) { print("  refused (\(count)): \(reason)") }
    #expect(result.sideloader == 0, "Sideloader refused \(result.sideloader) edits of the nested-light scenes")
}

/// Every single-target edit as the survey enumerates them (PluginSceneSurvey.cs):
/// delete and duplicate of every walk object, and adding a folder, a light and
/// a camera. Plug-in rules only, as the survey's port judges them: an
/// insertion the stage refuses for its two-light check (a topology rule) is
/// judged past it. Per kind "all", "some" or "none" accepted; a kind is cut
/// short once it has both. Reasons are counted with numbers as "#".
private func judgeSingleTargetEdits(_ document: KoikatsuSceneDocument) throws -> (categories: [String: String], reasons: [String: Int], sideloader: Int) {
    let walk = SourceSceneInsertionPlan.records(document.snapshot)
    var parents: [Int32: Int32] = [:], points: [Int32: Int32] = [:]
    for parent in walk {
        for child in parent.children { parents[child.sourceKey] = parent.sourceKey }
        for (point, children) in parent.character?.accessoryChildren ?? [:] {
            for child in children { parents[child.sourceKey] = parent.sourceKey; points[child.sourceKey] = point }
        }
    }
    // Studio.Duplicate: the record's copy under the same parent, then each descendant's under its parent's copy.
    func copy(_ record: KoikatsuObjectRecord) -> [SourceSceneInsertion] {
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
    var cases: [(String, SourceSceneEdits)] = []
    for record in walk { cases.append(("delete", .init(deletions: [record.sourceKey]))) }
    for record in walk { cases.append(("duplicate", .init(insertions: copy(record)))) }
    cases += [("addFolder", .init(insertions: [.init(.folder(name: "New"))])),
              ("addLight", .init(insertions: [.init(.light(SourceSceneNewLight(no: 0)))])),
              ("addCamera", .init(insertions: [.init(.camera(name: "New"))]))]
    let mask = try NSRegularExpression(pattern: "-?[0-9]+")
    var seen: [String: Set<Bool>] = [:], reasons: [String: Int] = [:], sideloader = 0
    for (kind, edit) in cases where seen[kind]?.count != 2 {
        let refusal: SourceSceneTopologyError? = autoreleasepool {
            func attempt(_ body: () throws -> Void) -> SourceSceneTopologyError? {
                do { try body(); return nil } catch let error as SourceSceneTopologyError { return error } catch { return .unsupported("\(error)") }
            }
            let first = attempt { _ = try document.editedData(edit) }
            guard let first, (first.errorDescription ?? "").contains("at most two lights") else { return first }
            return attempt {
                let base = document.isLegacy ? try document.upgraded() : document
                let stage = try base.inserting(edit.insertions)
                var rest = edit; rest.insertions = []
                _ = try stage.document.editedData(rest, source: stage.source, copies: stage.copies)
            }
        }
        guard let refusal else { seen[kind, default: []].insert(true); continue }
        let text = refusal.errorDescription ?? ""
        // Not a plug-in rule (the survey's port has none of these): no verdict.
        guard text.hasPrefix("Original-scene export cannot "), let colon = text.range(of: " in this scene: ") else { continue }
        seen[kind, default: []].insert(false)
        var body = String(text[colon.upperBound...])
        if body.hasSuffix(". Save in native format instead.") { body.removeLast(". Save in native format instead.".count) }
        for part in body.components(separatedBy: "; ") {
            if part.hasPrefix("Sideloader data") { sideloader += 1 }
            let masked = mask.stringByReplacingMatches(in: part, range: NSRange(part.startIndex..., in: part), withTemplate: "#")
            reasons[String(masked.prefix(160)), default: 0] += 1
        }
    }
    var categories: [String: String] = [:]
    for (kind, outcomes) in seen { categories[kind] = outcomes.count == 2 ? "some" : (outcomes.contains(true) ? "all" : "none") }
    return (categories, reasons, sideloader)
}
