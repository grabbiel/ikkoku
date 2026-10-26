import Foundation
import Testing
import Character
@testable import Studio

// The legacy-scene VM phase (Tools/reverse/original_legacy_scene_probe.py run,
// fixtures/OriginalLegacySceneProbe.cs), ST-T05a. The original CharaStudio
// 1.0.4.2 player read each uploaded record twice: SceneInfo.Load alone
// ("parse", saved as parsed-<label>.png by its own writer) and
// Studio.LoadScene ("load", saved as resave-<label>.png the way the
// scene-save button saves). Uploads: legacy records (l* from the corpus,
// s* synthetic) and our 1.0.4.2 export of each that is not refused (u*).

private let probeVariable = "IKKOKU_LEGACY_SCENE_PROBE"
private let uploadsVariable = "IKKOKU_LEGACY_SCENE_UPLOADS"
/// The synthetic records whose route points save no aid: refusal (i).
private let refusedLabels: Set<String> = ["s100-route", "s103-route", "s104-route"]

@Test(.enabled(if: SourceFixtureSupport.shouldRun([probeVariable, uploadsVariable]),
               "Requires IKKOKU_LEGACY_SCENE_PROBE (the phase folder) and IKKOKU_LEGACY_SCENE_UPLOADS (its uploads)"))
func legacyScenesReadAndSaveAsCharaStudio() throws {
    let probe = URL(fileURLWithPath: try SourceFixtureSupport.require(probeVariable))
    let uploads = URL(fileURLWithPath: try SourceFixtureSupport.require(uploadsVariable))
    let trace = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: probe.appendingPathComponent("legacy-trace.json"))) as? [String: Any])
    let cases = try #require(trace["cases"] as? [String: [String: Any]])
    func upload(_ label: String) throws -> Data { try Data(contentsOf: uploads.appendingPathComponent("reload-\(label).png")) }
    func saved(_ name: String) throws -> Data { try Data(contentsOf: probe.appendingPathComponent(name)) }
    func scene(_ label: String, _ phase: String) throws -> [String: Any] {
        let entry = try #require(cases[label]?[phase] as? [String: Any], "\(label): no \(phase) trace")
        return try #require(entry["scene"] as? [String: Any], "\(label): \(phase) has no scene")
    }
    var lines: [String] = [], itemControls = 0, settingControls = 0, byteIdentical = 0
    let legacyLabels = cases.keys.filter { $0.hasPrefix("l") || $0.hasPrefix("s") }.sorted()
    #expect(legacyLabels.count == 14)
    for label in legacyLabels {
        let legacyData = try upload(label), legacy = try KoikatsuSceneReader.decodeDocument(legacyData)
        let parse = try #require(cases[label]?["parse"] as? [String: Any])
        #expect(parse["dataVersion"] as? String == legacy.snapshot.version, "\(label): CharaStudio read another version")
        #expect(legacy.isLegacy, "\(label) is not a legacy record")
        // (a) What SceneInfo.Load read is what our reader decodes, field by field.
        let readDifferences = differences(try scene(label, "parse"), mirror(legacy))
        #expect(readDifferences.isEmpty, "\(label): parse differs from our decode: \(readDifferences.prefix(8))")
        if refusedLabels.contains(label) {
            try refusedRoute(label, legacy, loaded: try scene(label, "load"), resave: try saved("resave-\(label).png"), into: &lines)
            continue
        }
        let ourLabel = "u" + label.dropFirst()
        let ours = try upload(ourLabel), upgraded = try legacy.upgraded()
        // (b) The uploaded upgrade is what our writer saves now, and
        // CharaStudio reads it as we do.
        #expect(upgraded.preservedData == ours, "\(ourLabel) is not our current upgrade of \(label)")
        let oursRead = differences(try scene(ourLabel, "parse"), mirror(upgraded))
        #expect(oursRead.isEmpty, "\(ourLabel): parse differs from our decode: \(oursRead.prefix(8))")
        // After Studio.LoadScene CharaStudio holds our upgraded document,
        // apart from each character's neck and eye bytes: the load hands
        // them to the look controllers and leaves the fields null until the
        // save writes them again from the running controllers.
        let eyesKept = legacy.dataVersion < KoikatsuSceneVersion(0, 0, 8)
        // The FK bone count is checked against the save below: the load adds
        // the bones the catalog has and the record lacks.
        let loaded = differences(try scene(label, "load"), mirror(upgraded))
            .filter { !$0.contains(".character.eyes: null vs ") && !$0.contains(".character.neckBytes: -1.0 vs ") && !$0.contains(".character.bones: ") }
        #expect(loaded.isEmpty, "\(label): LoadScene holds other values than our upgrade: \(loaded.prefix(8))")
        // (c) CharaStudio's writer on its own parse: our upgrade, apart from
        // the cards (its card writer rewrites every card) and, below 0.0.8,
        // the eye bytes it saves unchanged (its save button rewrites them).
        let parsedSave = try saved("parsed-\(label).png")
        let p = try Comparable(parsedSave, dropEyes: eyesKept), o = try Comparable(ours, dropEyes: eyesKept)
        #expect(p.body == o.body && p.bones == o.bones, "\(label): CharaStudio's save of its parse differs from our upgrade")
        // With no card to rewrite, nothing is masked: every byte after the
        // PNG is CharaStudio's.
        if o.cards.isEmpty {
            #expect(try afterPNG(parsedSave) == afterPNG(ours), "\(label): CharaStudio's save of its parse is not our upgrade byte for byte")
            byteIdentical += 1
        }
        // (d) CharaStudio's load-then-save of the legacy record and of ours.
        let resaveLegacy = try saved("resave-\(label).png"), resaveOurs = try saved("resave-\(ourLabel).png")
        let strictL = try Comparable(resaveLegacy, items: false), strictO = try Comparable(resaveOurs, items: false)
        let fullL = try Comparable(resaveLegacy), fullO = try Comparable(resaveOurs)
        let itemTimes = try #require(strictL.differingOffsets(strictO), "\(label): the resaves differ in length")
        let timedItems = fullL.itemTimes.filter { _, range in itemTimes.contains { range.contains($0) } }.keys.sorted()
        #expect(onlyItemTimes(itemTimes, fullL.itemTimes),
                "\(label): the resaves differ outside the characters' live state and the items' animator time")
        #expect(fullL.body == fullO.body && fullL.bones == fullO.bones, "\(label): CharaStudio saves our upgrade differently from the legacy record")
        // Controls for that mask (finding 1), on the first item: a change in
        // its animator time is masked; one in the field before it
        // (enableDynamicBone) or after it (the child count) is not.
        if let (key, span) = fullO.itemTimes.min(by: { $0.key < $1.key }) {
            var inside = resaveOurs; inside[span.lowerBound] ^= 0x5a
            #expect(try Comparable(inside).body == fullO.body, "\(label): a change in item \(key)'s animator time is not masked")
            var before = resaveOurs; before[span.lowerBound - 1] ^= 1
            let changed = try #require(try Comparable(before, items: false).differingOffsets(strictO))
            #expect(try Comparable(before).body != fullO.body && changed == [span.lowerBound - 1] && !onlyItemTimes(changed, fullO.itemTimes),
                    "\(label): a change in item \(key)'s enableDynamicBone is masked")
            #expect(!onlyItemTimes([span.upperBound], fullO.itemTimes), "\(label): item \(key)'s child count is masked")
            itemControls += 1
        }
        // (e) Our upgrade against CharaStudio's save of the legacy record.
        // Its load adds each FK bone the character's catalog has and the
        // record lacks, with a fresh key (AddObjectAssist.InitBone :38-46,
        // InitHairBone :103-113), after the saved ones; it does the same
        // when it loads our upgrade (d).
        let oursMasked = try Comparable(ours)
        #expect(oursMasked.objects == fullL.objects, "\(label): our upgrade differs from CharaStudio's save \(firstDifference(oursMasked.objects, fullL.objects))")
        // A map with a SunLightInfo sets the scene's sun-shafts colour when
        // it loads (Map.sunType's setter, Map.cs:30-46, calls
        // SystemButtonCtrl.MapDependent, :1394-1402), after LoadScene
        // returns; every scene on that map is saved with the map's colour.
        var mapSun = ""
        if oursMasked.settings != fullL.settings {
            let theirs = settingsMirror(try KoikatsuSceneReader.decodeDocument(resaveLegacy)), mine = settingsMirror(upgraded)
            let settingDifferences = differences(theirs, mine), map = upgraded.settings.map
            let atLoad = try scene(label, "load")["sunColor"] as? [NSNumber], atSave = try scene(label, "saved")["sunColor"] as? [NSNumber]
            #expect(mapSetSunColor(settingDifferences, atLoad: atLoad, atSave: atSave, map: map),
                    "\(label): CharaStudio's save has other settings: \(settingDifferences.prefix(8))")
            // Controls (finding 3): any other colour differing as well is
            // caught, and so is the sun colour without the map that sets it
            // or without the trace showing it changed after the load.
            for other in upgraded.settings.colorSettings.keys.sorted() where other != "sunColor" {
                var changed = theirs; changed[other] = v4(upgraded.settings.colorSettings[other]! + SIMD4(0.25, 0, 0, 0))
                #expect(!mapSetSunColor(differences(changed, mine), atLoad: atLoad, atSave: atSave, map: map), "\(label): a change of \(other) passes")
                settingControls += 1
            }
            #expect(!mapSetSunColor(settingDifferences, atLoad: atSave, atSave: atSave, map: map))
            #expect(!mapSetSunColor(settingDifferences, atLoad: atLoad, atSave: atSave, map: -1))
            mapSun = " and the sun-shafts colour map \(map) sets"
        }
        var addedBones = 0
        for (key, mine) in oursMasked.bones {
            let theirs = try #require(fullL.bones[key])
            #expect(Array(theirs.prefix(mine.count)) == mine, "\(label): character \(key)'s saved FK bones are not kept first")
            let used = Set(oursMasked.keys)
            for entry in theirs.dropFirst(mine.count) {
                let fresh = entry.subdata(in: (entry.startIndex + 4)..<(entry.startIndex + 8)).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
                #expect(!used.contains(fresh), "\(label): an added FK bone reuses key \(fresh)")
            }
            addedBones += theirs.count - mine.count
        }
        // (f) Cards: ours are the legacy record's bytes; CharaStudio writes
        // the same rewrite of each in all four of its saves.
        var cardNotes: [String] = []
        for (key, card) in o.cards.sorted(by: { $0.key < $1.key }) {
            let original = try #require(legacy.cardData(key)); #expect(card == original, "\(label): card \(key) is not kept")
            let theirs = [p.cards[key], strictL.cards[key], strictO.cards[key], try Comparable(saved("parsed-\(ourLabel).png")).cards[key]]
            #expect(Set(theirs.map { $0 ?? Data() }).count == 1, "\(label): CharaStudio's saves hold different bytes for card \(key)")
            if let rewrite = theirs[0], rewrite != card { cardNotes.append(try cardDifference(card, rewrite)) }
        }
        lines.append("\(label) (\(legacy.snapshot.version)): read as decoded; upgrade \(legacyData.count) -> \(ours.count) B, "
            + "CharaStudio's parse-save \(p.body == o.body ? "equal" : "DIFFERS"), resaves equal"
            + (timedItems.isEmpty ? "" : " beyond the animator time of items \(timedItems)")
            + "; ours vs its save equal" + (addedBones == 0 ? "" : " beyond the \(addedBones) FK bones its load adds") + mapSun + "; \(o.cards.count) cards" + (cardNotes.isEmpty ? "" : " rewritten by CharaStudio: " + Set(cardNotes).sorted().joined(separator: "; ")))
    }
    // The controls ran: items in the resaves, and the map scene's colours.
    #expect(itemControls > 0 && settingControls > 0)
    lines.append("controls: item-time mask on \(itemControls) scenes; \(settingControls) other colours caught; "
        + "\(byteIdentical) card-free records saved byte for byte as our upgrade")
    print(lines.joined(separator: "\n"))
}

/// The bytes after the PNG (the thumbnails are different screenshots).
private func afterPNG(_ data: Data) throws -> Data {
    var reader = try KoikatsuBinaryReader(data); try reader.skipPNG()
    return data.subdata(in: (data.startIndex + reader.offset)..<data.endIndex)
}

/// Finding 1: every offset where two resaves differ lies in an item's
/// animator time (OCIItem.OnSavePreprocessing writes the running value).
private func onlyItemTimes(_ offsets: [Int], _ spans: [Int32: Range<Int>]) -> Bool {
    offsets.allSatisfy { offset in spans.values.contains { $0.contains(offset) } }
}

/// Finding 3: the settings differ only in the sun-shafts colour, on a map
/// scene, and the trace shows it changed after LoadScene returned (the
/// map's SunLightInfo, Map.sunType's setter, Map.cs:30-46).
private func mapSetSunColor(_ differences: [String], atLoad: [NSNumber]?, atSave: [NSNumber]?, map: Int32) -> Bool {
    !differences.isEmpty && differences.allSatisfy { $0.hasPrefix(".sunColor[") || $0.hasPrefix(".sunColor.count") }
        && atLoad != nil && atLoad != atSave && map >= 0
}

/// refusal (i): our export refuses it; CharaStudio's load gives each point a
/// fresh aid key (AddObjectRoute.InitAid) at the prefab's (1, 1, 1), and
/// saves the route fields our decode gives the record.
private func refusedRoute(_ label: String, _ legacy: KoikatsuSceneDocument, loaded: [String: Any], resave: Data, into lines: inout [String]) throws {
    var refusal = ""
    do { _ = try legacy.upgraded(); Issue.record("\(label): upgraded, but its route points save no aid") }
    catch { refusal = error.localizedDescription }
    #expect(refusal.contains("saves no aid") && refusal.contains("InitAid"), "\(label): \(refusal)")
    let theirs = try KoikatsuSceneReader.decodeDocument(resave)
    #expect(!theirs.isLegacy)
    // Field by field, with only the aid keys CharaStudio allocated left out.
    let fields = differences(mirror(theirs), mirror(legacy, aidKeys: false)).filter { !$0.contains(".aid") }
    #expect(fields.isEmpty, "\(label): CharaStudio's save differs from our decode: \(fields.prefix(8))")
    var used = Set<Int32>(), aids: [Int32] = []
    func visit(_ record: KoikatsuObjectRecord) {
        used.insert(record.sourceKey)
        for point in record.route?.points ?? [] { used.insert(point.bone.sourceKey) }
        record.children.forEach(visit)
    }
    legacy.snapshot.roots.forEach(visit)
    for root in theirs.snapshot.roots { for point in root.route?.points ?? [] {
        aids.append(try #require(point.aidKey))
        #expect(point.aidTransform == KoikatsuLegacyDefaults.aidTransform && !point.aidInitialized)
    } }
    #expect(aids.allSatisfy { !used.contains($0) } && Set(aids).count == aids.count, "\(label): aid keys \(aids) are not fresh")
    lines.append("\(label) (\(legacy.snapshot.version)): read as decoded; refused (i); CharaStudio's save gives aids \(aids) at (1, 1, 1), not initialized; every other field as decoded")
}

/// A saved scene's bytes after the PNG through the 【KStudio】 marker, each
/// character card cut out (kept in `cards`), the live state CharaStudio's
/// save takes from the running scene zeroed at the same length: each
/// character's neck bytes, eye bytes and animator time (as #287 masks
/// them), and with `items` each item's animator time (OCIItem
/// .OnSavePreprocessing, OCIItem.cs:289–297). `dropEyes` removes each
/// character's eye bytes and their length instead.
private struct Comparable {
    var body = Data(), cards: [Int32: Data] = [:], itemTimes: [Int32: Range<Int>] = [:]
    /// `body` split at the end of the object section.
    var objects: Data { body.prefix(body.count - settings.count) }
    var settings = Data()
    /// Each character's FK bone entries (Int32 bone ID, then OIBoneInfo
    /// .Save: dicKey and change amount, 44 bytes), cut out like the cards.
    var bones: [Int32: [Data]] = [:]
    /// Every object and sub-info key the records use.
    var keys: [Int32] = []
    var masked = Data(), start = 0, end = 0

    init(_ data: Data, items: Bool = true, dropEyes: Bool = false) throws {
        var reader = try KoikatsuBinaryReader(data)
        try reader.skipPNG(); start = reader.offset
        #expect(try reader.sceneVersion() == "1.0.4.2")
        var records: [KoikatsuObjectRecord] = []
        func index(_ record: KoikatsuObjectRecord) {
            records.append(record)
            for children in record.character?.accessoryChildren.values.map({ $0 }) ?? [] { children.forEach(index) }
            record.children.forEach(index)
        }
        for _ in 0..<(try reader.count()) { index(try reader.object(depth: 0, rootKey: try reader.int32())) }
        let objectEnd = reader.offset
        _ = try reader.sceneSettings(); _ = try reader.string(); end = reader.offset
        settings = data.subdata(in: objectEnd..<end)
        var bytes = [UInt8](data), cut: [(Range<Int>, Data)] = []
        for record in records {
            if let character = record.character {
                let time = try #require(reader.editSpans.animations[record.sourceKey]?.normalizedTime)
                let eyes = (time.lowerBound - character.eyesData.count)..<time.lowerBound
                let neck = (eyes.lowerBound - 4 - character.neckData.count)..<(eyes.lowerBound - 4)
                for range in [neck, eyes, time] { for offset in range { bytes[offset] = 0 } }
                if dropEyes { cut.append(((eyes.lowerBound - 4)..<eyes.upperBound, Data())) }
                let card = try #require(reader.editSpans.cards[record.sourceKey])
                cards[record.sourceKey] = data.subdata(in: card)
                cut.append((card, Data("<card \(record.sourceKey)>".utf8)))
                let list = card.upperBound..<(card.upperBound + 4 + 44 * character.bones.count)
                bones[record.sourceKey] = (0..<character.bones.count).map { data.subdata(in: (list.lowerBound + 4 + 44 * $0)..<(list.lowerBound + 48 + 44 * $0)) }
                cut.append((list, Data("<bones \(record.sourceKey)>".utf8)))
                keys += character.bones.values.map(\.sourceKey) + character.ikTargets.values.map(\.sourceKey) + [character.lookAtTarget.sourceKey]
            }
            if record.item != nil, let slot = reader.editSpans.topology.slots[record.sourceKey]?.first {
                let time = (slot.count - 4)..<slot.count
                itemTimes[record.sourceKey] = time
                if items { for offset in time { bytes[offset] = 0 } }
            }
        }
        for record in records {
            keys.append(record.sourceKey)
            keys += record.item?.bones.values.map(\.sourceKey) ?? []
            for point in record.route?.points ?? [] { keys += [point.bone.sourceKey] + (point.aidKey.map { [$0] } ?? []) }
        }
        masked = Data(bytes)
        var at = start
        for (range, marker) in cut.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            body += masked[at..<range.lowerBound] + marker; at = range.upperBound
        }
        body += masked[at..<end]
    }

    /// Offsets (in this file) where two saves of the same scene layout
    /// differ after their PNGs (the thumbnails are different screenshots);
    /// nil when the scenes' lengths differ.
    func differingOffsets(_ other: Comparable) -> [Int]? {
        guard end - start == other.end - other.start else { return nil }
        return (0..<(end - start)).filter { masked[start + $0] != other.masked[other.start + $0] }.map { start + $0 }
    }
}

private extension KoikatsuSceneDocument {
    func cardData(_ key: Int32) -> Data? {
        func find(_ records: [KoikatsuObjectRecord]) -> Data? {
            for record in records {
                if record.sourceKey == key, let character = record.character { return character.cardData }
                if let found = find(record.children + (record.character?.accessoryChildren.values.flatMap { $0 } ?? [])) { return found }
            }
            return nil
        }
        return find(snapshot.roots)
    }
}

/// How CharaStudio's rewrite of a card differs from the card: block names,
/// versions and sizes.
private func cardDifference(_ ours: Data, _ theirs: Data) throws -> String {
    let a = try SourceCharacterCard.decode(ours), b = try SourceCharacterCard.decode(theirs)
    var notes: [String] = []
    let removed = Set(a.blocks.map(\.name)).subtracting(b.blocks.map(\.name)).sorted()
    if !removed.isEmpty { notes.append("drops " + removed.joined(separator: ", ")) }
    for block in b.blocks {
        guard let mine = a.block(named: block.name) else { notes.append("adds \(block.name) \(block.version)"); continue }
        if mine.version != block.version { notes.append("\(block.name) \(mine.version) -> \(block.version)") }
        else if mine.data != block.data { notes.append("\(block.name) \(mine.data.count) -> \(block.data.count) B") }
    }
    if a.faceThumbnailData != b.faceThumbnailData { notes.append("face thumbnail \(a.faceThumbnailData.count) -> \(b.faceThumbnailData.count) B") }
    if a.trailingData != b.trailingData { notes.append("trailer \(a.trailingData.count) -> \(b.trailingData.count) B") }
    return notes.isEmpty ? "same blocks, other header bytes" : notes.joined(separator: ", ")
}

// MARK: - The probe's trace shape for our records

/// Our document in the probe's JSON shape (OriginalLegacySceneProbe.cs
/// SceneRecord/Record), so both flatten to the same paths.
private func mirror(_ document: KoikatsuSceneDocument, aidKeys: Bool = true) -> [String: Any] {
    let s = document.settings
    func camera(_ c: KoikatsuCameraRecord) -> [String: Any] {
        ["pos": v3(c.position), "rotate": v3(c.rotationDegrees), "distance": v3(c.distance), "parse": c.fieldOfView]
    }
    var result: [String: Any] = ["roots": document.snapshot.roots.map { ["key": $0.rootDictionaryKey ?? -1, "object": record($0, aidKeys: aidKeys)] as [String: Any] },
        "map": s.map, "caMap": change(s.mapTransform), "sunLightType": s.sunLightType, "mapOption": s.mapOption, "aceNo": s.colorCorrection,
        "sunCaster": s.sunCaster, "rampG": s.ramp, "camera": camera(s.camera), "cameraSlots": s.cameraSlots.map(camera),
        "background": s.background, "frame": s.frame]
    for (key, value) in s.floatSettings { result[key] = value }
    for (key, value) in s.boolSettings { result[key] = value }
    for (key, value) in s.colorSettings { result[key] = v4(value) }
    return result
}

private func settingsMirror(_ document: KoikatsuSceneDocument) -> [String: Any] {
    var result = mirror(document); result["roots"] = nil; return result
}

private func record(_ r: KoikatsuObjectRecord, aidKeys: Bool) -> [String: Any] {
    var d: [String: Any] = ["kind": r.kind.rawValue, "dicKey": r.sourceKey, "change": change(r.transform), "treeState": r.treeState, "visible": r.visible]
    let children = r.children.map { record($0, aidKeys: aidKeys) }
    if let item = r.item {
        d["item"] = ["group": item.group, "category": item.category, "no": item.no, "animeSpeed": item.animationSpeed,
            "colors": item.colors.map(v4), "patterns": item.patterns.map(pattern), "alpha": item.alpha, "lineColor": v4(item.lineColor),
            "lineWidth": item.lineWidth, "emissionColor": v4(item.emissionColor), "emissionPower": item.emissionPower,
            "lightCancel": item.lightCancel, "panel": pattern(item.panel), "enableFK": item.enableFK, "bones": item.bones.count,
            "enableDynamicBone": item.enableDynamicBone, "animeNormalizedTime": item.animationNormalizedTime] as [String: Any]
        d["children"] = children
    }
    if let c = r.character {
        d["character"] = ["sex": c.sex, "expression": c.expressions, "neckBytes": c.neckData.count,
            "eyes": c.eyesData.map { String(format: "%02x", $0) }.joined(), "animeNormalizedTime": c.animationNormalizedTime,
            "bones": c.bones.count, "ikTargets": c.ikTargets.count] as [String: Any]
        d["accessoryChildren"] = c.accessoryChildren.keys.sorted().map { ["point": $0, "children": c.accessoryChildren[$0]!.map { record($0, aidKeys: aidKeys) }] as [String: Any] }
    }
    if let route = r.route {
        d["route"] = ["name": r.name ?? "", "active": route.active, "loop": route.loop, "visibleLine": route.visibleLine,
            "orient": route.orientation, "color": v4(route.color), "points": route.points.map { p -> [String: Any] in
                var aid: Any = NSNull()
                if let key = p.aidKey { aid = ["dicKey": aidKeys ? key : -1, "change": change(p.aidTransform), "isInit": p.aidInitialized] as [String: Any] }
                return ["dicKey": p.bone.sourceKey, "change": change(p.bone.transform), "speed": p.speed, "easeType": p.easeType,
                        "connection": p.connection, "link": p.linked, "aid": aid]
            }] as [String: Any]
        d["children"] = children
    }
    if r.kind == .folder { d["folder"] = ["name": r.name ?? ""]; d["children"] = children }
    if r.kind == .camera { d["camera"] = ["name": r.name ?? "", "active": r.cameraActive ?? false] as [String: Any] }
    if let l = r.light {
        d["light"] = ["no": l.no, "color": v4(l.color), "intensity": l.intensity, "range": l.range, "spotAngle": l.spotAngle,
                      "shadow": l.shadow, "enable": l.enable, "drawTarget": l.drawTarget] as [String: Any]
    }
    return d
}

private func change(_ c: KoikatsuChangeAmount) -> [String: Any] { ["pos": v3(c.position), "rot": v3(c.rotationDegrees), "scale": v3(c.scale)] }
private func pattern(_ p: KoikatsuPatternRecord) -> [String: Any] { ["key": p.key, "filePath": p.filePath, "clamp": p.clamp, "uv": v4(p.uv), "rot": p.rotation] }
private func v3(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
private func v4(_ v: SIMD4<Float>) -> [Float] { [v.x, v.y, v.z, v.w] }

/// Every leaf of both values by path; numbers compare as Float (the probe
/// writes C# floats with "R", ints exactly), keys of the second side's
/// character groups sorted as ours are. A path only one side has is a
/// difference; the probe's aid key -1 placeholder (`aidKeys: false`) is not.
private func differences(_ theirs: [String: Any], _ ours: [String: Any]) -> [String] {
    var a: [String: String] = [:], b: [String: String] = [:]
    flatten(theirs, "", &a); flatten(ours, "", &b)
    return Set(a.keys).union(b.keys).sorted().compactMap { key in a[key] == b[key] ? nil : "\(key): \(a[key] ?? "-") vs \(b[key] ?? "-")" }
}

private func flatten(_ value: Any, _ path: String, _ out: inout [String: String]) {
    switch value {
    case let d as [String: Any]:
        for (key, child) in d {
            if key == "accessoryChildren", let groups = child as? [[String: Any]] {
                // Only groups that hold records; the player keeps empty ones.
                let filled = groups.filter { (($0["children"] as? [Any]) ?? []).isEmpty == false }
                    .sorted { leaf($0["point"]) < leaf($1["point"]) }
                flatten(filled, path + ".accessoryChildren", &out)
            } else { flatten(child, path + "." + key, &out) }
        }
    case let list as [Any]:
        out[path + ".count"] = "\(list.count)"
        for (index, child) in list.enumerated() { flatten(child, path + "[\(index)]", &out) }
    case is NSNull: out[path] = "null"
    default: out[path] = leaf(value)
    }
}

private func leaf(_ value: Any?) -> String {
    switch value {
    case let flag as Bool where !(value is NSNumber) || CFGetTypeID(value as! NSNumber) == CFBooleanGetTypeID(): return flag ? "true" : "false"
    // The probe's C# 3.5 "R" format writes -0 as "0"; the byte comparisons
    // keep the sign.
    case let number as NSNumber: return "\(Float(truncating: number) + 0)"
    case let number as Float: return "\(number + 0)"
    case let number as Int32: return "\(Float(number))"
    case let number as Int: return "\(Float(number))"
    case let text as String: return text
    case nil: return "nil"
    default: return "\(value!)"
    }
}

/// Where two bodies first differ, with a little context, for failure messages.
private func firstDifference(_ a: Data, _ b: Data) -> String {
    let x = [UInt8](a), y = [UInt8](b)
    guard let at = (0..<min(x.count, y.count)).first(where: { x[$0] != y[$0] }) ?? (x.count == y.count ? nil : min(x.count, y.count)) else { return "" }
    func hex(_ bytes: [UInt8]) -> String { bytes[max(0, at - 24)..<min(bytes.count, at + 24)].map { String(format: "%02x", $0) }.joined() }
    return "at body byte \(at) of \(x.count)/\(y.count): \(hex(x)) vs \(hex(y))"
}
