import Testing
import Foundation
@testable import Renderer

/// `#expect` cannot call a mutating method on a local value; a reference can.
private final class Policy {
    var value: DisplayLinkRatePolicy
    init(_ value: DisplayLinkRatePolicy = .init()) { self.value = value }
    var hz: Float? { value.hz }
    var visible: Bool { value.visible }
    func callback(at time: Double, outcome: RenderDrawResult.Outcome) -> Bool { value.callback(at: time, outcome: outcome) }
    func wake(at time: Double) -> Bool { value.wake(at: time) }
    func setVisible(_ visible: Bool, at time: Double) -> Bool { value.setVisible(visible, at: time) }
    func refreshAfter(_ interval: Double?) -> Double? { value.refreshAfter(interval) }
    func setPaced(_ hz: Float?, at time: Double) -> Bool { value.setPaced(hz, at: time) }
}

/// R7 phase 2, item 4, P2: the adaptive display-link rate, the keep-alive's
/// visibility rule and how the harness accounts for callbacks at a lowered rate.
struct DisplayLinkRatePolicyTests {
    @Test func unchangedCallbacksLowerTheRateInTiersAndAnyActivityRestoresItAtOnce() {
        let policy = Policy()
        #expect(policy.hz == nil)
        // The first callback only starts the idle clock.
        #expect(!policy.callback(at: 10, outcome: .unchanged))
        #expect(!policy.callback(at: 10.49, outcome: .unchanged))
        #expect(policy.callback(at: 10.5, outcome: .unchanged))
        #expect(policy.hz == 30)
        // Keep-alive refreshes present the same image: still idle.
        #expect(!policy.callback(at: 12, outcome: .refreshed))
        #expect(policy.callback(at: 13, outcome: .unchanged))
        #expect(policy.hz == 15)
        #expect(!policy.callback(at: 60, outcome: .unchanged))
        // A submit or input wakes it; a second wake changes nothing.
        #expect(policy.wake(at: 60.01))
        #expect(policy.hz == nil)
        #expect(!policy.wake(at: 60.02))
        // The idle clock restarts at the wake, not at the last callback.
        #expect(!policy.callback(at: 60.5, outcome: .unchanged))
        #expect(policy.callback(at: 60.52, outcome: .unchanged))
        #expect(policy.hz == 30)
        // A rendered callback is activity; so is a failed one, which the next callback retries.
        #expect(policy.callback(at: 61, outcome: .rendered))
        #expect(policy.hz == nil)
        #expect(!policy.callback(at: 61.6, outcome: .failed))
        #expect(!policy.callback(at: 62, outcome: .unchanged))
        #expect(policy.callback(at: 62.1, outcome: .unchanged))
        #expect(policy.callback(at: 62.2, outcome: .failed))
        #expect(policy.hz == nil)
        // A long first gap goes straight to the slowest tier it reached.
        let late = Policy()
        _ = late.callback(at: 0, outcome: .unchanged)
        #expect(late.callback(at: 4, outcome: .unchanged) && late.hz == 15)
        // No tiers: a fixed full rate.
        let fixed = Policy(DisplayLinkRatePolicy(tiers: []))
        _ = fixed.callback(at: 0, outcome: .unchanged)
        #expect(!fixed.callback(at: 100, outcome: .unchanged) && fixed.hz == nil)
    }

    /// R7 phase 2, live pacing: while paced steps change the frames, rendered
    /// frames are not activity and the tiers do not apply. After `pacedIdle`
    /// without a wake the link asks for the step rate; a wake (input, a resize,
    /// an edit's submit) or a failed callback returns full rate at once.
    @Test func pacedPlaybackLowersToTheStepRateUntilAWake() {
        let policy = Policy()
        // Starting paced playback from full rate changes nothing yet.
        #expect(!policy.setPaced(30, at: 10))
        #expect(!policy.callback(at: 10.2, outcome: .rendered))
        #expect(!policy.callback(at: 10.49, outcome: .unchanged))
        #expect(policy.callback(at: 10.5, outcome: .rendered))
        #expect(policy.hz == 30)
        // Neither unchanged nor rendered callbacks reach a tier while paced.
        #expect(!policy.callback(at: 20, outcome: .unchanged))
        #expect(!policy.callback(at: 20.1, outcome: .rendered))
        #expect(policy.hz == 30)
        // Input returns full rate at once; the wait starts again from it.
        #expect(policy.wake(at: 20.2))
        #expect(policy.hz == nil)
        #expect(!policy.callback(at: 20.6, outcome: .rendered))
        #expect(policy.callback(at: 20.75, outcome: .rendered) && policy.hz == 30)
        // A failure is activity: the next callback retries at full rate.
        #expect(policy.callback(at: 21, outcome: .failed) && policy.hz == nil)
        // Paced playback ends: full rate, and the tiers count from then on.
        #expect(policy.callback(at: 21.5, outcome: .rendered) && policy.hz == 30)
        #expect(policy.setPaced(nil, at: 22))
        #expect(policy.hz == nil)
        #expect(!policy.callback(at: 22.2, outcome: .unchanged))
        #expect(policy.callback(at: 22.5, outcome: .unchanged) && policy.hz == 30)
        // Starting paced playback from a lowered tier returns full rate first.
        #expect(policy.callback(at: 26, outcome: .unchanged) && policy.hz == 15)
        #expect(policy.setPaced(30, at: 26.1) && policy.hz == nil)
    }

    /// Hidden while paced: the slowest tier, as for any hidden window, and no
    /// paced lowering. Visible again, paced playback lowers after `pacedIdle`.
    @Test func aHiddenWindowOverridesPacedPlayback() {
        let policy = Policy()
        _ = policy.setPaced(30, at: 0)
        _ = policy.callback(at: 1, outcome: .rendered)
        #expect(policy.hz == 30)
        #expect(policy.setVisible(false, at: 2))
        #expect(policy.hz == 15)
        #expect(!policy.callback(at: 5, outcome: .rendered))
        #expect(!policy.wake(at: 5.1))
        #expect(policy.hz == 15)
        // Paced playback ends while hidden: still the slowest tier.
        #expect(!policy.setPaced(nil, at: 6))
        #expect(policy.hz == 15)
        // Visible and paced again: full rate, then the step rate.
        #expect(!policy.setVisible(true, at: 7))
        #expect(policy.setPaced(30, at: 7.1) && policy.hz == nil)
        #expect(policy.callback(at: 7.7, outcome: .rendered) && policy.hz == 30)
    }

    /// The keep-alive needs a callback once per interval at every rate.
    @Test func theSlowestStandardTierStillServesTheKeepAliveInterval() throws {
        let slowest = try #require(DisplayLinkRatePolicy.standardTiers.last)
        #expect(Double(slowest.hz) * DisplayLinkRatePolicy.keepAliveInterval >= 1 - 1e-9)
        // Under the 0.17 s present gap after which drag starts dropped frames,
        // with room for one dropped refresh.
        #expect(2 * DisplayLinkRatePolicy.keepAliveInterval < 0.15)
    }

    /// Occluded or minimized: nothing presented is shown, so the link idles at
    /// its slowest tier with no keep-alive, whatever is submitted; the first
    /// activity once the window is visible again restores full rate at once.
    @Test func aHiddenWindowIdlesWithoutKeepAliveUntilActivityAfterItIsVisibleAgain() {
        let policy = Policy()
        let interval = DisplayLinkRatePolicy.keepAliveInterval
        #expect(policy.refreshAfter(interval) == interval)
        #expect(policy.refreshAfter(nil) == nil)
        _ = policy.callback(at: 0, outcome: .rendered)
        #expect(policy.setVisible(false, at: 1))
        #expect(policy.hz == 15 && !policy.visible)
        #expect(policy.refreshAfter(interval) == nil)
        #expect(!policy.setVisible(false, at: 1.1))
        // Submits, input and rendered frames while hidden change nothing.
        #expect(!policy.wake(at: 2))
        #expect(!policy.callback(at: 2.1, outcome: .rendered))
        #expect(!policy.callback(at: 2.2, outcome: .failed))
        #expect(policy.hz == 15)
        // Visible again: the keep-alive resumes; the rate waits for activity.
        #expect(!policy.setVisible(true, at: 5))
        #expect(policy.refreshAfter(interval) == interval)
        #expect(!policy.callback(at: 5.1, outcome: .unchanged))
        #expect(policy.hz == 15)
        #expect(policy.wake(at: 5.2))
        #expect(policy.hz == nil)
        // Its idle clock restarted at the wake.
        #expect(!policy.callback(at: 5.6, outcome: .unchanged))
        #expect(policy.callback(at: 5.7, outcome: .unchanged) && policy.hz == 30)
        // A rendered callback after the window returns is activity too.
        _ = policy.setVisible(false, at: 6)
        _ = policy.setVisible(true, at: 7)
        #expect(policy.callback(at: 7.01, outcome: .rendered) && policy.hz == nil)
        // A fixed policy has no tier to idle at, but still stops the keep-alive.
        let fixed = Policy(DisplayLinkRatePolicy(tiers: []))
        #expect(!fixed.setVisible(false, at: 0))
        #expect(fixed.hz == nil && fixed.refreshAfter(interval) == nil)
    }

    @Test func lowRateCallbacksAccountForTheirGapButNoMoreThanOneLoweredPeriod() {
        let period = 1.0 / 120
        // Full rate: the allowance is one display period, as before P2.
        #expect(RenderPresentationSample.Skip.allowance(period: period, gapToNext: 4 * period, hz: nil) == period)
        #expect(RenderPresentationSample.Skip.allowance(period: period, gapToNext: 4 * period, hz: 0) == period)
        // At 30 Hz a 4-period gap is deliberate; a 6-period one is not, past 4.
        #expect(abs(RenderPresentationSample.Skip.allowance(period: period, gapToNext: 4 * period, hz: 30) - 4 * period) < 1e-12)
        #expect(abs(RenderPresentationSample.Skip.allowance(period: period, gapToNext: 6 * period, hz: 30) - 1.0 / 30) < 1e-12)
        // A wake that brings the next callback early never drops below one period.
        #expect(RenderPresentationSample.Skip.allowance(period: period, gapToNext: 0.5 * period, hz: 30) == period)

        // A frame, two unchanged callbacks at 30 Hz (four periods each), then
        // the next frame on time: its cadence is one period, not 9.
        let samples = [RenderPresentationSample(target: 0, presented: 0),
                       RenderPresentationSample(target: 9 * period, presented: 9 * period)]
        let skips = [RenderPresentationSample.Skip(target: period, allowance: 4 * period),
                     RenderPresentationSample.Skip(target: 5 * period, allowance: 4 * period)]
        let adjusted = RenderPresentationSample.activeIntervals(samples, unchanged: skips)
        #expect(abs(adjusted[0] - period) < 1e-12)
        // A frame one period late after them counts that period, nothing more.
        let late = [samples[0], RenderPresentationSample(target: 9 * period, presented: 10 * period)]
        #expect(abs(RenderPresentationSample.activeIntervals(late, unchanged: skips)[0] - 2 * period) < 1e-12)
        // Equal allowances reproduce the full-rate function exactly.
        let uniform = [period, 2 * period, 3 * period]
        let a = RenderPresentationSample.activeIntervals(samples, unchangedTargets: uniform, period: period)
        let b = RenderPresentationSample.activeIntervals(samples, unchanged: uniform.map { .init(target: $0, allowance: period) })
        #expect(a == b && abs(a[0] - 6 * period) < 1e-12)
    }
}
