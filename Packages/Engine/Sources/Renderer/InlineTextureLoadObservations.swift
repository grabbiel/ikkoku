import Foundation

/// Opt-in stage times of `InlineTextureLoader.texture`, for tests and
/// measurements; nothing in the app sets one. One caller owns it and uses it
/// on the loading thread, one load at a time, and may reuse it across loads to
/// sum them.
///
/// The loader calls `start()` as a load begins and `lap(_:)` as each stage
/// ends. A lap adds the time since the previous mark to its stage, so the
/// stages of one load add up to the whole call, cleanup included. Without an
/// observer, every mark is one predictable branch past it: no clock read,
/// call, lock or allocation. Times are wall time between marks, not CPU
/// decode or GPU execution time alone. A load that throws keeps the laps it
/// finished.
final class InlineTextureLoadObservations {
    enum Stage: Int, CaseIterable, Sendable {
        /// Layout choice, descriptor and texture allocation.
        case destinationAllocation
        /// Waiting for an upload permit (no wait on the main thread), and the
        /// autorelease pool's push.
        case permitWait
        /// The decoded pixels (`InlineTextureLoader.decodedPixels`): ImageIO
        /// decodes here, into a bitmap or the provider's copy.
        case decode
        /// The pixel-length check and the staging buffer.
        case stagingAllocation
        /// Per strip: converting into staging.
        case conversion
        /// Per strip: command buffer, blit (with the mips on the last strip)
        /// and commit.
        case encodeSubmit
        /// Per strip: waiting for the GPU and checking the status.
        case completionWait
        /// After the last strip: `didComplete`, then releasing the decoded
        /// pixels, the staging buffer, the autorelease pool and the permit.
        case cleanup
    }

    struct Aggregate: Equatable, Sendable {
        var calls = 0
        var milliseconds = 0.0
    }

    private var aggregates = [Aggregate](repeating: Aggregate(), count: Stage.allCases.count)
    private var mark = 0.0
    private let clock: () -> Double

    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    subscript(stage: Stage) -> Aggregate { aggregates[stage.rawValue] }

    /// All stages' milliseconds together.
    var milliseconds: Double { aggregates.reduce(0) { $0 + $1.milliseconds } }

    /// A load begins: the next lap counts from here, not from the last load.
    func start() { mark = clock() }

    /// `stage` ends: it gains the time since the previous mark.
    func lap(_ stage: Stage) {
        let now = clock()
        aggregates[stage.rawValue].calls += 1
        aggregates[stage.rawValue].milliseconds += (now - mark) * 1000
        mark = now
    }
}
