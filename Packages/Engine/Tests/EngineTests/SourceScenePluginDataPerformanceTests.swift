import Foundation
import Testing
@testable import Studio

/// ST-T03i export timing probe (opt-in: IKKOKU_PLUGIN_SCENE_PERF=1 plus
/// IKKOKU_STUDIO_SCENARIO_SCENE, the showoff scene, and the plug-in probe's
/// IKKOKU_PLUGIN_SCENE_PROBE and IKKOKU_PLUGIN_SCENE_PROBE_B folders).
/// Prints the median and p90 of `editedData` per export, and of the plug-in
/// data step alone (`SourceScenePluginData.rewrite` on the same edit's
/// output): the cost with the step, and the cost it adds. Run it in a quiet
/// window with
/// `swift test -c release --package-path Packages/Engine --filter SourceScenePluginDataPerformance`.
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

/// `editedData`, then the plug-in step alone on its output, for one export.
/// A refused export is timed up to its refusal.
private func pluginPerfExport(_ label: String, _ document: KoikatsuSceneDocument, _ edits: SourceSceneEdits) throws {
    let output: Data
    do { output = try document.editedData(edits) } catch let error as SourceSceneTopologyError {
        print("[plugin-perf] \(label): refused (\(error.errorDescription?.prefix(80) ?? ""))")
        pluginPerfMedian("\(label) editedData (refused)") { _ = try? document.editedData(edits) }
        return
    }
    let final = try KoikatsuSceneReader.decodeDocument(output)
    try pluginPerfMedian("\(label) editedData") { _ = try document.editedData(edits) }
    try pluginPerfMedian("\(label) plug-in step") {
        _ = try SourceScenePluginData.rewrite(output, final: final, source: document, copies: [:], moved: !edits.reparents.isEmpty)
    }
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
    // light's delete keeps them and rewrites Sideloader; an item's delete is
    // refused by KKPE.
    let fixtureB = try load("IKKOKU_PLUGIN_SCENE_PROBE_B", "fixture.png")
    try pluginPerfExport("fixture B delete light", fixtureB, .init(deletions: [15]))
    try pluginPerfExport("fixture B move", fixtureB, .init(reparents: [.init(object: 5, parent: 0)]))
    try pluginPerfExport("fixture B delete item", fixtureB, .init(deletions: [2]))
}
