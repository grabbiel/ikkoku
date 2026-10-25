/// Presentation cadence used by the performance harness. Times are in seconds
/// on the same monotonic clock. Raw presentation intervals remain a separate metric.
public struct RenderPresentationSample: Sendable {
    public var target: Double
    public var presented: Double
    public init(target: Double, presented: Double) { self.target = target; self.presented = presented }

    /// Absolute delay against this drawable's target, independent of other
    /// presentations. A late first frame must not disappear from cadence metrics.
    public var lateness: Double { max(0, presented - target) }

    /// Cadence with intentional unchanged callbacks removed, not actual FPS or
    /// latency. Always report raw intervals and target-to-present lateness too:
    /// an already-late first presentation can shorten the following interval.
    /// Count each target interval independently because actual presentations can
    /// arrive out of target order (for example a callback during resize). Reversed
    /// target pairs receive no skip allowance. No missing/failed callback is a skip.
    public static func activeIntervals(_ samples: [Self], unchangedTargets: [Double], period: Double) -> [Double] {
        guard period > 0 else { return [] }
        return activeIntervals(samples, unchanged: unchangedTargets.map { Skip(target: $0, allowance: period) })
    }

    /// One unchanged callback: its target and the time it accounts for, the
    /// display period at full rate. While a viewport's link runs at a lowered
    /// rate (R7 P2), an unchanged callback accounts for the gap to the next
    /// callback, up to the lowered rate's period (`allowance(...)`).
    public struct Skip: Sendable {
        public var target: Double
        public var allowance: Double
        public init(target: Double, allowance: Double) { self.target = target; self.allowance = allowance }

        /// `period` at full rate (`hz` nil or 0). At a lowered rate, the gap
        /// to the next callback's target, at least `period` and at most one
        /// lowered period; anything longer is not deliberate.
        public static func allowance(period: Double, gapToNext: Double?, hz: Float?) -> Double {
            guard let hz, hz > 0 else { return period }
            return max(period, min(gapToNext ?? period, 1 / Double(hz)))
        }

        /// The targets a drawing callback skips on purpose while the link runs
        /// at a lowered rate (R7 phase 2, live pacing: paced playback asks for
        /// the step rate, and every callback renders). The skip sits half a
        /// period after the callback's `target` and accounts for the gap to the
        /// next callback beyond one period, at most one lowered period. Nil at
        /// full rate, for the last callback and for a gap of about one period.
        public static func afterLoweredDraw(target: Double, period: Double, gapToNext: Double?, hz: Float?) -> Skip? {
            guard let hz, hz > 0, let gapToNext else { return nil }
            let extra = min(gapToNext, 1 / Double(hz)) - period
            guard extra > period / 2 else { return nil }
            return Skip(target: target + period / 2, allowance: extra)
        }
    }

    /// `activeIntervals` with an explicit allowance per unchanged callback. With
    /// every allowance equal to `period` it is the function above.
    public static func activeIntervals(_ samples: [Self], unchanged: [Skip]) -> [Double] {
        let sorted = samples.sorted { $0.presented < $1.presented }
        let skips = unchanged.sorted { $0.target < $1.target }
        var prefix = [0.0]
        prefix.reserveCapacity(skips.count + 1)
        for skip in skips { prefix.append(prefix[prefix.count - 1] + skip.allowance) }
        func bound(_ value: Double, inclusive: Bool) -> Int {
            var low = 0, high = skips.count
            while low < high {
                let middle = (low + high) / 2
                if skips[middle].target < value || (inclusive && skips[middle].target == value) { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
        return zip(sorted, sorted.dropFirst()).map { previous, current in
            guard current.target > previous.target else { return max(0, current.presented - previous.presented) }
            let low = bound(previous.target, inclusive: true), high = bound(current.target, inclusive: false)
            let allowance = high > low ? prefix[high] - prefix[low] : 0
            return max(0, current.presented - previous.presented - allowance)
        }
    }
}
