import Foundation
import QuartzCore
import Studio
import Gameplay

extension StudioModel {
    /// Measures advancing simulation and building render frames in an isolated
    /// document. GPU submission, asset cold load and PNG encoding are separate.
    func benchmarkSourceEvaluation(measuredFrames: Int, deltaTime: Float = 1 / 30) throws -> [String: Any] {
        guard (1...600).contains(measuredFrames), deltaTime.isFinite, deltaTime > 0 else {
            throw SourcePluginError.invalid("Invalid Studio evaluation benchmark duration.")
        }
        let fixture = StudioModel(host: host)
        defer { refresh() }
        fixture.stopBenchmarkTimer(); fixture.liveAnimation = false; fixture.showGizmos = showGizmos
        fixture.doc = doc
        try fixture.setSourceAnimationTime(sourceAnimationTime)
        try fixture.restoreSourcePlugins(restoreNativeAdapters: false)
        var samples: [Double] = [], statusChanges = Set<String>()
        let baselineStatus = fixture.status
        let warmup = 3
        for index in 0..<(measuredFrames + warmup) {
            let start = CACurrentMediaTime()
            if fixture.sourcePluginSession != nil { try fixture.stepSourcePlugins(deltaTime: deltaTime, advanceAnimation: true) }
            else { try fixture.advancePluginAnimation(by: deltaTime); fixture.refresh() }
            let milliseconds = (CACurrentMediaTime() - start) * 1000
            if index >= warmup { samples.append(milliseconds) }
            if fixture.status != baselineStatus { statusChanges.insert(fixture.status) }
        }
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double { sorted[max(0, Int(ceil(p * Double(sorted.count))) - 1)] }
        // The isolated StudioModel's refresh publishes to the shared renderer;
        // put the user's frame back after measurement without changing state.
        return ["schemaVersion": 1, "mode": "isolated-studio-simulation-and-frame-construction-no-gpu-submission",
            "warmupFrames": warmup, "measuredFrames": measuredFrames, "deltaTimeSeconds": deltaTime,
            "simulationMilliseconds": ["p50": percentile(0.5), "p95": percentile(0.95), "minimum": sorted.first!, "maximum": sorted.last!],
            "includes": ["source Animator sampling", "enabled source FK/IK and configured hair dynamics", "native transform traversal", "render item and skin palette construction", "loaded translated plugin callbacks and state snapshots"],
            "excludes": ["asset cold load", "GPU encoding and execution", "image readback", "PNG encoding", "display scheduling"],
            "pluginPackages": fixture.sourcePluginSession?.library.packages.count ?? 0,
            "source": fixture.sourceBenchmarkMetadata(), "statusChanges": statusChanges.sorted()]
    }
}
