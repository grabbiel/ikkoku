import Foundation
import Testing
import Studio

/// ST-T05a decode timing probe (opt-in: IKKOKU_LEGACY_SCENE_PERF=1 plus
/// IKKOKU_STUDIO_SCENARIO_SCENE, the showoff scene; IKKOKU_LEGACY_SCENE_LARGEST,
/// a large legacy scene; and IKKOKU_LEGACY_SCENE_UPGRADED, that scene saved
/// as 1.0.4.2 by `ikkoku-inspect scene-document --write-upgraded`). It uses
/// only APIs the base build has, so the same file times both builds: the
/// base refuses the legacy scene by version, and decodes its 1.0.4.2 form.
/// Prints the median and p90 of 60 calls after 10 warmups. Run it in a quiet
/// window with
/// `swift test -c release -Xswiftc -enable-testing --package-path Packages/Engine --filter KoikatsuLegacyScenePerformance`.
private let legacyPerfEnvironment = ProcessInfo.processInfo.environment
private let legacyPerfEnabled = legacyPerfEnvironment["IKKOKU_LEGACY_SCENE_PERF"] == "1"
    && ["IKKOKU_STUDIO_SCENARIO_SCENE", "IKKOKU_LEGACY_SCENE_LARGEST", "IKKOKU_LEGACY_SCENE_UPGRADED"]
        .allSatisfy { !(legacyPerfEnvironment[$0] ?? "").isEmpty }

private func legacyPerfMedian(_ label: String, iterations: Int = 60, _ body: () throws -> Void) rethrows {
    for _ in 0..<10 { try body() }
    var samples: [UInt64] = []
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        samples.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    let sorted = samples.sorted()
    let median = Double(sorted[sorted.count / 2]) / 1_000_000, p90 = Double(sorted[sorted.count * 9 / 10]) / 1_000_000
    print("[legacy-perf] \(label) median \(String(format: "%.3f", median)) ms p90 \(String(format: "%.3f", p90)) ms over \(iterations) calls")
}

@Test(.enabled(if: legacyPerfEnabled, "Opt-in timing probe: IKKOKU_LEGACY_SCENE_PERF=1 plus the showoff scene and a legacy scene with its upgrade"))
func koikatsuLegacyScenePerformance() throws {
    func data(_ variable: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: legacyPerfEnvironment[variable]!)) }
    let showoff = try data("IKKOKU_STUDIO_SCENARIO_SCENE"), legacy = try data("IKKOKU_LEGACY_SCENE_LARGEST")
    let upgradedData = try data("IKKOKU_LEGACY_SCENE_UPGRADED")
    print("[legacy-perf] showoff \(showoff.count) B, legacy \(legacy.count) B, its 1.0.4.2 form \(upgradedData.count) B")
    // Showoff is a 1.0.4.2 scene: the decode the change must leave as it was.
    try legacyPerfMedian("showoff decodeDocument") { _ = try KoikatsuSceneReader.decodeDocument(showoff) }
    // The same scene as 1.0.4.2: what a current scene of this content costs.
    try legacyPerfMedian("legacy as 1.0.4.2 decodeDocument") { _ = try KoikatsuSceneReader.decodeDocument(upgradedData) }
    // IKKOKU_LEGACY_SCENE_PERF_CURRENT_ONLY=1: only these two 1.0.4.2
    // decodes, for repeated rounds of the comparison with the base build.
    if legacyPerfEnvironment["IKKOKU_LEGACY_SCENE_PERF_CURRENT_ONLY"] == "1" { return }
    let document: KoikatsuSceneDocument
    do { document = try KoikatsuSceneReader.decodeDocument(legacy) } catch {
        print("[legacy-perf] legacy decodeDocument refused: \(error.localizedDescription.prefix(80))")
        legacyPerfMedian("legacy decodeDocument (refused)") { _ = try? KoikatsuSceneReader.decodeDocument(legacy) }
        return
    }
    #expect(document.snapshot.version != "1.0.4.2")
    try legacyPerfMedian("legacy decodeDocument") { _ = try KoikatsuSceneReader.decodeDocument(legacy) }
    // An unedited export: the 1.0.4.2 upgrade (its patches, then a decode
    // of the result) and the plug-in step.
    #expect(try document.editedData(SourceSceneEdits()) == upgradedData)
    try legacyPerfMedian("legacy export, no edit") { _ = try document.editedData(SourceSceneEdits()) }
}
