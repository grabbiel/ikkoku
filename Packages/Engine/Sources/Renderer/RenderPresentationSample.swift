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
        let sorted = samples.sorted { $0.presented < $1.presented }
        let skips = unchangedTargets.sorted()
        func bound(_ value: Double, inclusive: Bool) -> Int {
            var low = 0, high = skips.count
            while low < high {
                let middle = (low + high) / 2
                if skips[middle] < value || (inclusive && skips[middle] == value) { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
        return zip(sorted, sorted.dropFirst()).map { previous, current in
            let count = current.target > previous.target
                ? max(0, bound(current.target, inclusive: false) - bound(previous.target, inclusive: true)) : 0
            return max(0, current.presented - previous.presented - Double(count) * period)
        }
    }
}
