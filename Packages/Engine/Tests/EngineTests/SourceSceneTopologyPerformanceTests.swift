import Foundation
import Testing
import Studio

/// ST-T03 topology export timing probe (opt-in: IKKOKU_TOPOLOGY_PERF=1 plus
/// IKKOKU_STUDIO_SCENARIO_SCENE). Prints the median CPU cost of reading the
/// scenario scene and of `editedData` for a one-transform export and for the
/// `topology-reparent` scenario's edits (three moves with their re-authored
/// transforms and one subtree deletion). Run it with
/// `swift test -c release --package-path Packages/Engine --filter SourceSceneTopologyPerformance`.
private let topologyPerfEnabled = (ProcessInfo.processInfo.environment["IKKOKU_TOPOLOGY_PERF"] ?? "") == "1"
    && (ProcessInfo.processInfo.environment["IKKOKU_STUDIO_SCENARIO_SCENE"] ?? "").isEmpty == false

private func topologyPerfMedian(_ label: String, iterations: Int = 60, _ body: () throws -> Void) rethrows {
    for _ in 0..<10 { try body() }
    var samples: [UInt64] = []
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        samples.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    let sorted = samples.sorted()
    let median = Double(sorted[sorted.count / 2]) / 1_000_000, p90 = Double(sorted[sorted.count * 9 / 10]) / 1_000_000
    print("[topology-perf] \(label) median \(String(format: "%.3f", median)) ms p90 \(String(format: "%.3f", p90)) ms over \(iterations) calls")
}

private func topologyPerfScene() throws -> (data: Data, document: KoikatsuSceneDocument) {
    let data = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["IKKOKU_STUDIO_SCENARIO_SCENE"]!))
    return (data, try KoikatsuSceneReader.decodeDocument(data))
}

private func topologyPerfMoved(_ transform: KoikatsuChangeAmount) -> KoikatsuChangeAmount {
    KoikatsuChangeAmount(position: transform.position + SIMD3(0.125, 0, 0), rotationDegrees: transform.rotationDegrees, scale: transform.scale)
}

@Test(.enabled(if: topologyPerfEnabled, "Opt-in timing probe: IKKOKU_TOPOLOGY_PERF=1 plus IKKOKU_STUDIO_SCENARIO_SCENE"))
func sourceSceneTopologyPerformanceBaseline() throws {
    let (data, document) = try topologyPerfScene()
    let record = try #require(document.snapshot.roots.first { $0.sourceKey == 622 })
    let edits = SourceSceneEdits(transforms: [.init(.object(622), transform: topologyPerfMoved(record.transform))])
    try topologyPerfMedian("decodeDocument") { _ = try KoikatsuSceneReader.decodeDocument(data) }
    try topologyPerfMedian("editedData no-op") { _ = try document.editedData(SourceSceneEdits()) }
    try topologyPerfMedian("editedData one transform") { _ = try document.editedData(edits) }
}

@Test(.enabled(if: topologyPerfEnabled, "Opt-in timing probe: IKKOKU_TOPOLOGY_PERF=1 plus IKKOKU_STUDIO_SCENARIO_SCENE"))
func sourceSceneTopologyPerformanceReparent() throws {
    let (_, document) = try topologyPerfScene()
    var transforms: [Int32: KoikatsuChangeAmount] = [:]
    func walk(_ records: [KoikatsuObjectRecord]) {
        for record in records {
            transforms[record.sourceKey] = record.transform; walk(record.children)
            record.character?.accessoryChildren.values.forEach(walk)
        }
    }
    walk(document.snapshot.roots)
    let moved: [Int32] = [623, 65, 1129]
    let edits = SourceSceneEdits(transforms: try moved.map { .init(.object($0), transform: topologyPerfMoved(try #require(transforms[$0]))) },
                                 deletions: [1298],
                                 reparents: [.init(object: 623, parent: 962), .init(object: 65, parent: 626), .init(object: 1129, parent: nil)])
    let output = try document.editedData(edits)
    let reread = try KoikatsuSceneReader.decode(output)
    #expect(reread.roots.map(\.sourceKey) == [622, 962, 626, 1130, 794, 1540, 1129])
    try topologyPerfMedian("editedData reparent scenario (3 moves, 1 subtree deletion)") { _ = try document.editedData(edits) }
}
