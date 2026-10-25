import Foundation

/// Which display-link callbacks start a fixed-rate model step (R7 phase 2,
/// live pacing).
///
/// The Studio advances its live animation, timeline and plugin session in
/// steps of exactly `interval` (1/30 s). A step's frame is drawn by the first
/// callback after its `submit`. When a free-running 30 Hz timer started the
/// steps, nothing tied a step to the display's vsync grid. A submit that
/// landed just after a callback waited for the next one, so frames that
/// should be 4 vsyncs apart at 120 Hz came 3 and 5 apart. This policy starts
/// the steps from the viewport's display-link callbacks instead, so every
/// step starts the same time before the callback that draws it.
///
/// A step is due 1/30 s after the previous one, in target-presentation time.
/// The callback whose target is nearest that time asks for the step: the
/// first one whose target, plus half the gap since the previous callback, is
/// at or past it. The gap is the link's current period, so the rule follows
/// the display rate, the adaptive rate tiers, ProMotion and a window moving
/// to another display. At 120 Hz every 4th callback asks, at 60 Hz every
/// 2nd, and at a 30 Hz link every callback.
///
/// When the asking callback's target is within `snapTolerance` of the time
/// the step was due, as on 60, 120 or 240 Hz displays (and 59.94 or
/// 119.88 Hz), the next step is due one interval after that callback's
/// target: a fixed number of vsyncs, with no drift. Otherwise the steps stay
/// on the 30 Hz grid, so they keep 30 per second; at 144 Hz they then come
/// 5, 5, 4, 5 and 5 vsyncs apart.
///
/// The owner sends at most one request at a time and reports how it ended
/// (`finished`):
/// - `.ran`: a step started. The next one is due an interval later.
/// - `.busy`: the previous step was still running or not yet refreshed, so
///   this one could not start. As when a timer fire found a step running,
///   the step is skipped, not retried: steps never overlap or queue, and the
///   next one is due an interval later, on the same grid.
/// - `.idle`: there was nothing to step (live animation off, a drag, another
///   mode, steps stopped). The pacer parks: no callback asks until the owner
///   calls `resume()`, which the model does once it has something to step
///   again. An idle model is then sent no requests, and the first step after
///   `resume()` is asked for at the next callback.
///
/// While the viewport's window is not visible, no callback asks; when it is
/// visible again the next callback asks at once. A gap of more than
/// `resumeGap` between callbacks (the window was minimized, the thread
/// stalled) likewise asks at once instead of catching up.
///
/// Plain data: its owner calls it from the render thread, or under its own
/// lock. See docs/reference/renderer.md, "Live pacing".
public struct LiveStepPacer: Sendable, Equatable {
    /// How a request ended.
    public enum Result: String, Sendable, Equatable { case ran, busy, idle }

    /// The Studio's step: 1/30 s.
    public static let standardInterval = 1.0 / 30
    /// How close (seconds) to its due time a step's callback must be for the
    /// next step to count from that callback: 1% of a 30 Hz step.
    public static let snapTolerance = 0.01 / 30
    /// A longer gap between callbacks restarts the pacing.
    public static let resumeGap = 0.25

    public let interval: Double
    /// When the next step's frame should present (target-presentation time);
    /// nil asks at the next callback.
    public private(set) var due: Double?
    /// The target of the callback whose request is still unanswered.
    public private(set) var pending: Double?
    public private(set) var visible = true
    /// Set by an `.idle` answer: no callback asks until `resume()`.
    public private(set) var parked = false
    private var lastTarget: Double?

    public init(interval: Double = LiveStepPacer.standardInterval) {
        precondition(interval > 0, "the step interval must be positive")
        self.interval = interval
    }

    /// One callback whose frame targets `target` (seconds, the display link's
    /// clock). Returns true when it should ask for a step; the owner then
    /// sends the request and later calls `finished` with this `target`.
    public mutating func callback(target: Double) -> Bool {
        let gap = lastTarget.map { target - $0 }
        lastTarget = target
        guard visible, pending == nil, !parked else { return false }
        if let due, let gap, gap > 0, gap <= Self.resumeGap, target + gap / 2 < due { return false }
        pending = target
        return true
    }

    /// The request made by the callback that targeted `target` ended with
    /// `result`. An answer for another request (one from before a `reset`) is
    /// ignored.
    public mutating func finished(_ result: Result, target: Double) {
        guard pending == target else { return }
        pending = nil
        switch result {
        case .idle:
            due = target + interval
            parked = true
        case .ran, .busy:
            if let due, abs(target - due) <= Self.snapTolerance {
                // On the vsync grid: count from this callback.
                self.due = target + interval
            } else if let due, target - due < interval {
                // Between vsyncs (144 Hz): keep 30 steps a second.
                self.due = due + interval
            } else {
                // The first step, or more than a step behind.
                self.due = target + interval
            }
        }
    }

    /// The window became visible or stopped being visible. Hidden: no
    /// callback asks for a step. Visible again: the next callback asks at once.
    public mutating func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        due = nil
    }

    /// The owner has something to step again after an `.idle` answer: the
    /// next callback asks at once (its step is past due). Returns whether the
    /// pacer was parked.
    @discardableResult
    public mutating func resume() -> Bool {
        guard parked else { return false }
        parked = false
        return true
    }

    /// Forgets the schedule, any unanswered request and an `.idle` answer;
    /// the next callback asks.
    public mutating func reset() {
        due = nil
        pending = nil
        parked = false
        lastTarget = nil
    }
}
