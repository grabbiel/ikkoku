import Foundation
import Testing
@testable import Studio

/// ST-T03i export timing probe (opt-in: IKKOKU_PLUGIN_SCENE_PERF=1 plus
/// IKKOKU_STUDIO_SCENARIO_SCENE, the showoff scene, and the plug-in probe's
/// IKKOKU_PLUGIN_SCENE_PROBE and IKKOKU_PLUGIN_SCENE_PROBE_B folders; with
/// IKKOKU_PLUGIN_SCENE_PROBE_C also phase C's fixture, and with
/// IKKOKU_PLUGIN_SCENE_LARGEST a large installed scene with KKPE data).
/// Prints the median and p90 of the import's engine side (scene decode and
/// card decodes), of `editedData` per export, and of the plug-in data step
/// alone (`SourceScenePluginData.rewrite` on the same edit's
/// output): the cost with the step, and the cost it adds. Run it in a quiet
/// window with
/// `swift test -c release -Xswiftc -enable-testing --package-path Packages/Engine --filter SourceScenePluginDataPerformance`.
private let pluginPerfEnvironment = ProcessInfo.processInfo.environment
private let pluginPerfEnabled = pluginPerfEnvironment["IKKOKU_PLUGIN_SCENE_PERF"] == "1"
    && ["IKKOKU_STUDIO_SCENARIO_SCENE", "IKKOKU_PLUGIN_SCENE_PROBE", "IKKOKU_PLUGIN_SCENE_PROBE_B"]
        .allSatisfy { !(pluginPerfEnvironment[$0] ?? "").isEmpty }

private func pluginPerfMedian(_ label: String, iterations: Int = 60, _ body: () throws -> Void) rethrows {
    for _ in 0..<10 { try body() }
    var samples: [UInt64] = []
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        samples.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    let sorted = samples.sorted()
    let median = Double(sorted[sorted.count / 2]) / 1_000_000, p90 = Double(sorted[sorted.count * 9 / 10]) / 1_000_000
    print("[plugin-perf] \(label) median \(String(format: "%.3f", median)) ms p90 \(String(format: "%.3f", p90)) ms over \(iterations) calls")
}

/// `editedData`, then the plug-in step alone on the input `editedData` gives
/// it: the staged copies with the source trailer (`inserting`), the edited
/// body (`editedBody`) and the copies map. A refused export is timed up to
/// its refusal.
private func pluginPerfExport(_ label: String, _ document: KoikatsuSceneDocument, _ edits: SourceSceneEdits) throws {
    do { _ = try document.editedData(edits) } catch let error as SourceSceneTopologyError {
        print("[plugin-perf] \(label): refused (\(error.errorDescription?.prefix(80) ?? ""))")
        pluginPerfMedian("\(label) editedData (refused)") { _ = try? document.editedData(edits) }
        return
    }
    let stage = try document.inserting(edits.insertions)
    var rest = edits; rest.insertions = []
    let (body, final) = try stage.document.editedBody(rest)
    try pluginPerfMedian("\(label) editedData") { _ = try document.editedData(edits) }
    try pluginPerfMedian("\(label) plug-in step") {
        _ = try SourceScenePluginData.rewrite(body, final: final, source: document, copies: stage.copies, moved: !rest.reparents.isEmpty)
    }
}

/// The engine side of an import: the scene decode, which reads every
/// embedded card, and each character's card decode, as the Studio preview
/// does once per character.
private func pluginPerfImport(_ label: String, _ data: Data) throws {
    var characters: [KoikatsuCharacterRecord] = []
    func visit(_ record: KoikatsuObjectRecord) {
        if let character = record.character { characters.append(character) }
        record.children.forEach(visit)
    }
    try KoikatsuSceneReader.decodeDocument(data).snapshot.roots.forEach(visit)
    print("[plugin-perf] \(label) import: \(data.count) B, \(characters.count) characters")
    try pluginPerfMedian("\(label) import decodeDocument") { _ = try KoikatsuSceneReader.decodeDocument(data) }
    try pluginPerfMedian("\(label) import every card()") { for character in characters { _ = try character.card() } }
}

@Test(.enabled(if: pluginPerfEnabled, "Opt-in timing probe: IKKOKU_PLUGIN_SCENE_PERF=1 plus the showoff scene and the probe folders"))
func sourceScenePluginDataPerformance() throws {
    func load(_ variable: String, _ name: String? = nil) throws -> KoikatsuSceneDocument {
        var url = URL(fileURLWithPath: pluginPerfEnvironment[variable]!)
        if let name { url.appendPathComponent(name) }
        return try KoikatsuSceneReader.decodeDocument(Data(contentsOf: url))
    }
    // The showoff scene has no plug-in data: a transform edit returns at
    // once, and a subtree deletion checks each character's card for
    // KKAnimationController links.
    let showoff = try load("IKKOKU_STUDIO_SCENARIO_SCENE")
    try pluginPerfImport("showoff", showoff.preservedData)
    #expect(showoff.trailingData.isEmpty)
    let moved = try #require(showoff.snapshot.roots.first { $0.sourceKey == 622 })
    let transform = KoikatsuChangeAmount(position: moved.transform.position + SIMD3<Float>(0.125, 0, 0),
                                         rotationDegrees: moved.transform.rotationDegrees, scale: moved.transform.scale)
    try pluginPerfExport("showoff one transform", showoff, .init(transforms: [.init(.object(622), transform: transform)]))
    try pluginPerfExport("showoff subtree deletion", showoff, .init(deletions: [1298]))
    // Phase A's fixture (Sideloader, StudioSceneSettings): a delete rewrites
    // the Sideloader records; a move keeps every entry.
    let fixtureA = try load("IKKOKU_PLUGIN_SCENE_PROBE", "fixture.png")
    try pluginPerfExport("fixture A delete (Sideloader rewrite)", fixtureA, .init(deletions: [2]))
    try pluginPerfExport("fixture A move", fixtureA, .init(reparents: [.init(object: 5, parent: 0)]))
    // Phase B's fixture adds KKPE, NodesConstraints and MaterialEditor: a
    // light's delete keeps them and rewrites Sideloader; an item's delete
    // rewrites KKPE and MaterialEditor too.
    let fixtureB = try load("IKKOKU_PLUGIN_SCENE_PROBE_B", "fixture.png")
    try pluginPerfExport("fixture B delete light", fixtureB, .init(deletions: [15]))
    try pluginPerfExport("fixture B move", fixtureB, .init(reparents: [.init(object: 5, parent: 0)]))
    try pluginPerfExport("fixture B delete item", fixtureB, .init(deletions: [2]))
    // Phase C's fixture has data in all three plug-ins and a character with
    // KKPE card data: an item delete rewrites KKPE, MaterialEditor and
    // NodesConstraints; a copy clones records; a character copy patches its
    // card's controller ID.
    if !(pluginPerfEnvironment["IKKOKU_PLUGIN_SCENE_PROBE_C"] ?? "").isEmpty {
        let fixtureC = try load("IKKOKU_PLUGIN_SCENE_PROBE_C", "fixture.png")
        try pluginPerfExport("fixture C delete item (three rewrites)", fixtureC, .init(deletions: [2]))
        try pluginPerfExport("fixture C duplicate item", fixtureC, .init(insertions: [.init(.duplicate(of: 5))]))
        try pluginPerfExport("fixture C duplicate character (card patch)", fixtureC, .init(insertions: [.init(.duplicate(of: 16))]))
        try pluginPerfExport("fixture C move", fixtureC, .init(reparents: [.init(object: 5, parent: 0)]))
    }
    // A large installed scene with KKPE data: a delete, a copy and a move to
    // the root of its highest-keyed item without children that sits at the
    // root or in a folder (refused ones are timed to the refusal).
    if let path = pluginPerfEnvironment["IKKOKU_PLUGIN_SCENE_LARGEST"], !path.isEmpty {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let large = try KoikatsuSceneReader.decodeDocument(data)
        var items: [Int32] = [], objects = 0
        func visit(_ record: KoikatsuObjectRecord, inFolder: Bool) {
            objects += 1
            if record.kind == .item, record.children.isEmpty, inFolder { items.append(record.sourceKey) }
            for child in record.children { visit(child, inFolder: record.kind == .folder) }
        }
        for root in large.snapshot.roots { visit(root, inFolder: true) }
        print("[plugin-perf] large scene: \(data.count) B, \(objects) objects, \(large.trailingData.count) B of plug-in data")
        try pluginPerfImport("large", data)
        let item = try #require(items.max())
        try pluginPerfExport("large delete item", large, .init(deletions: [item]))
        try pluginPerfExport("large duplicate item", large, .init(insertions: [.init(.duplicate(of: item))]))
        try pluginPerfExport("large move item to the root", large, .init(reparents: [.init(object: item, parent: nil)]))
    }
}
