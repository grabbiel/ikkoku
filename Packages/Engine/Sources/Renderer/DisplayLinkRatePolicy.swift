import Foundation

/// The display-link rate a viewport asks for, and whether its idle callbacks
/// present the unchanged image again (R7 phase 2, item 4, P2 and the keep-alive).
///
/// A viewport's link runs at the display's full rate while anything changes.
/// When its callbacks have found nothing to draw (`RenderDrawResult.Outcome.unchanged`,
/// or `.refreshed`: the keep-alive presenting the same image) for a tier's
/// `idle` seconds, with no wake in between, the policy asks for that tier's
/// lower rate. Any rendered or failed callback, and any wake (viewport input,
/// a resize, a `Renderer.submit`), returns it to full rate at once. A failed
/// callback counts as activity because the next callback retries it.
///
/// While the viewport's window is not visible (occluded, minimizing or
/// minimized), nothing it presents is shown: the policy asks for its slowest
/// tier at once, turns the keep-alive off (`refreshAfter`) and ignores
/// activity. Once the window is visible again, the first activity returns the
/// link to full rate.
///
/// The slowest standard tier still calls back once per `keepAliveInterval`,
/// so the keep-alive keeps its interval at every rate (a test pins it). See
/// docs/reference/renderer.md, "Renderer threads".
///
/// The policy is plain data. Its owner calls it from the thread that runs the
/// link, or under its own lock, and applies `hz` to the link.
public struct DisplayLinkRatePolicy: Sendable, Equatable {
    /// One step down: after `idle` seconds without activity, ask for `hz`.
    public struct Tier: Sendable, Equatable {
        public var idle: Double
        public var hz: Float
        public init(idle: Double, hz: Float) { self.idle = idle; self.hz = hz }
    }

    /// The idle keep-alive interval (`Renderer.draw(refreshAfter:)`): after
    /// this long without a present, an unchanged callback presents the image
    /// again. After about 0.17 s without a present, the first presents of the
    /// next change never reach the screen; 1/15 s leaves room for one dropped
    /// refresh (performance.md, "Phase 2, item 4").
    public static let keepAliveInterval: Double = 1.0 / 15

    /// 30 Hz after half a second without change, 15 Hz (one callback per
    /// keep-alive interval) after three seconds.
    public static let standardTiers = [Tier(idle: 0.5, hz: 30), Tier(idle: 3, hz: 15)]

    public let tiers: [Tier]
    /// Index of the tier in force; nil at the display's full rate.
    public private(set) var tier: Int?
    /// Whether the viewport's window is visible (in the app: its occlusion
    /// state, and not minimizing or minimized).
    public private(set) var visible = true
    private var lastActivity: Double?

    /// `tiers` in increasing `idle` order, each slower than the one before.
    public init(tiers: [Tier] = DisplayLinkRatePolicy.standardTiers) {
        precondition(zip(tiers, tiers.dropFirst()).allSatisfy { $0.idle < $1.idle && $0.hz > $1.hz },
                     "tiers must slow down as idle time grows")
        self.tiers = tiers
    }

    /// The requested rate in Hz; nil for the display's full rate.
    public var hz: Float? { tier.map { tiers[$0].hz } }

    /// The keep-alive interval for the next callback: `interval` while the
    /// window is visible, nil (no refresh) while it is not.
    public func refreshAfter(_ interval: Double?) -> Double? { visible ? interval : nil }

    /// Updates the policy after one callback at `time` (seconds, any monotonic
    /// clock shared with `wake`). Returns true when the requested rate changed.
    public mutating func callback(at time: Double, outcome: RenderDrawResult.Outcome) -> Bool {
        guard visible else { return false }
        guard outcome == .unchanged || outcome == .refreshed else { return activity(at: time) }
        guard let since = lastActivity else { lastActivity = time; return false }
        let idle = time - since
        let wanted = tiers.lastIndex { idle >= $0.idle }
        guard wanted != tier, (wanted ?? -1) > (tier ?? -1) else { return false }
        tier = wanted
        return true
    }

    /// Input, a resize or a submit at `time`. Returns true when the rate must
    /// return to full (it was lowered). Ignored while the window is not visible.
    public mutating func wake(at time: Double) -> Bool {
        guard visible else { return false }
        return activity(at: time)
    }

    /// The window became visible or stopped being visible at `time`. Returns
    /// true when the requested rate changed.
    public mutating func setVisible(_ visible: Bool, at time: Double) -> Bool {
        guard visible != self.visible else { return false }
        self.visible = visible
        if visible {
            // The idle clock restarts; the rate stays low until activity.
            lastActivity = time
            return false
        }
        let slowest = tiers.isEmpty ? nil : tiers.count - 1
        guard slowest != tier else { return false }
        tier = slowest
        return true
    }

    private mutating func activity(at time: Double) -> Bool {
        lastActivity = max(lastActivity ?? time, time)
        guard tier != nil else { return false }
        tier = nil
        return true
    }
}
