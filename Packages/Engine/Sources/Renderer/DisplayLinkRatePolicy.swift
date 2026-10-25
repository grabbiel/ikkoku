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
/// Paced playback (R7 phase 2, live pacing): while the viewport's display
/// link paces a fixed-rate model step (`LiveStepPacer`) and the frames change
/// only through those steps, the owner sets `pacedHz` (`setPaced`). Rendered
/// frames then come from the steps, not from activity, and the tiers would
/// slow the steps down, so they do not apply. After `pacedIdle` seconds
/// without a wake the policy asks for `pacedHz`, the step rate, so callbacks
/// that would find nothing new are not made. A wake (input, a resize, a
/// submit that is not a step's) or a failed callback returns it to full rate
/// at once, as outside paced playback.
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

    /// How long paced playback runs without a wake before the link asks for
    /// the step rate (`pacedHz`): the first tier's wait.
    public static let pacedIdle = 0.5

    public let tiers: [Tier]
    /// Index of the tier in force; nil at the display's full rate.
    public private(set) var tier: Int?
    /// The paced step rate while paced playback runs (`setPaced`); nil otherwise.
    public private(set) var pacedHz: Float?
    /// Whether paced playback has gone `pacedIdle` without a wake, so the link
    /// asks for `pacedHz`.
    public private(set) var pacedLowered = false
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
    public var hz: Float? {
        if pacedHz != nil { return pacedLowered && visible ? pacedHz : tier.map { tiers[$0].hz } }
        return tier.map { tiers[$0].hz }
    }

    /// The keep-alive interval for the next callback: `interval` while the
    /// window is visible, nil (no refresh) while it is not.
    public func refreshAfter(_ interval: Double?) -> Double? { visible ? interval : nil }

    /// Updates the policy after one callback at `time` (seconds, any monotonic
    /// clock shared with `wake`). Returns true when the requested rate changed.
    public mutating func callback(at time: Double, outcome: RenderDrawResult.Outcome) -> Bool {
        guard visible else { return false }
        if pacedHz != nil {
            // The steps change the frames; only a failure is activity here.
            guard outcome != .failed else { return activity(at: time) }
            guard !pacedLowered, time - (lastActivity ?? time) >= Self.pacedIdle else {
                if lastActivity == nil { lastActivity = time }
                return false
            }
            pacedLowered = true
            return true
        }
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
        let before = hz
        self.visible = visible
        pacedLowered = false
        if visible {
            // The idle clock restarts; the rate stays low until activity.
            lastActivity = time
            return hz != before
        }
        tier = tiers.isEmpty ? nil : tiers.count - 1
        return hz != before
    }

    /// Paced playback started (`hz`, the step rate) or ended (nil) at `time`.
    /// Either way the link returns to full rate and the idle clock restarts:
    /// starting, the steps run at full rate for `pacedIdle` first; ending, the
    /// tiers count from here. Returns true when the requested rate changed.
    public mutating func setPaced(_ hz: Float?, at time: Double) -> Bool {
        guard hz != pacedHz else { return false }
        let before = self.hz
        pacedHz = hz
        pacedLowered = false
        if visible { tier = nil }
        lastActivity = time
        return self.hz != before
    }

    private mutating func activity(at time: Double) -> Bool {
        lastActivity = max(lastActivity ?? time, time)
        guard tier != nil || pacedLowered else { return false }
        tier = nil
        pacedLowered = false
        return true
    }
}
