import Foundation

/// Private diagnostic proposal: one synchronous caller owns this observer.
/// Never share it across callers or retain it in a store/queue/Metal command.
/// Children sit inside metalTextureLoad; do not add them to that parent again.
/// Cleanup, pointer/span validation and observer overhead remain unassigned.
/// Durations are elapsed call boundaries, not CPU decode or GPU execution time.
final class InlineTextureLoadObservations {
    enum Stage: CaseIterable, Hashable, Sendable {
        case destinationAllocation, permitWait, providerAccess, stagingAllocation
        case conversion, encodeSubmit, completionWait
    }
    struct Aggregate: Equatable, Sendable {
        var calls = 0
        var failures = 0
        var milliseconds = 0.0
    }
    struct Sample: Equatable, Sendable {
        let stages: [Stage: Aggregate]
        let mainThreadBypasses: Int
        let convertedRows: Int
        let mipmapEncodes: Int
    }

    // Fixed stage vocabulary; no per-load/per-strip event arrays or labels.
    private var stages: [Stage: Aggregate] = [:]
    private var mainThreadBypasses = 0
    private var convertedRows = 0
    private var mipmapEncodes = 0
    private let clock: () -> Double

    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    var sample: Sample {
        Sample(stages: stages, mainThreadBypasses: mainThreadBypasses,
               convertedRows: convertedRows, mipmapEncodes: mipmapEncodes)
    }

    static func measure<T>(_ observer: InlineTextureLoadObservations?, _ stage: Stage,
                           _ body: () throws -> T) rethrows -> T {
        // Nil means no new clock, counters, labels or diagnostic allocation.
        // This is a source property, not a measured zero-overhead claim.
        guard let observer else { return try body() }
        let start = observer.clock()
        var succeeded = false
        defer {
            let elapsed = observer.clock() - start
            observer.record(stage, seconds: elapsed, succeeded: succeeded)
        }
        let result = try body()
        succeeded = true
        return result
    }

    private func record(_ stage: Stage, seconds: Double, succeeded: Bool) {
        var aggregate = stages[stage, default: Aggregate()]
        aggregate.calls += 1
        if !succeeded { aggregate.failures += 1 }
        aggregate.milliseconds += seconds * 1000
        stages[stage] = aggregate
    }

    // Reuse the existing acquire() timestamps. Do not add a second wait clock
    // or derive one request from resettable global UploadPermits statistics.
    func recordPermitWait(seconds: Double) {
        record(.permitWait, seconds: seconds, succeeded: true)
    }
    func recordMainThreadBypass() { mainThreadBypasses += 1 }
    func recordConvertedRows(_ rows: Int) { convertedRows += rows }
    func recordMipmapEncode() { mipmapEncodes += 1 }
}
