import Testing
import Foundation
@testable import Renderer

/// `#expect` cannot call a mutating method on a local value; a reference can.
private final class Pacer {
    var value: LiveStepPacer
    init(_ value: LiveStepPacer = .init()) { self.value = value }
    func callback(target: Double) -> Bool { value.callback(target: target) }
    func finished(_ result: LiveStepPacer.Result, target: Double) { value.finished(result, target: target) }
    func setVisible(_ visible: Bool) { value.setVisible(visible) }

    /// Runs `count` callbacks `period` apart from `start`, answering every
    /// request with `answer(index)` at once. Returns the asking callbacks' indices.
    func run(period: Double, count: Int, start: Double = 1000, answer: (Int) -> LiveStepPacer.Result = { _ in .ran }) -> [Int] {
        var asked: [Int] = []
        for index in 0..<count {
            let target = start + Double(index) * period
            if value.callback(target: target) {
                asked.append(index)
                value.finished(answer(index), target: target)
            }
        }
        return asked
    }
}

private func gaps(_ indices: [Int]) -> [Int] { zip(indices.dropFirst(), indices).map { $0 - $1 } }

/// R7 phase 2, live pacing: which display-link callbacks start the Studio's
/// 1/30 s step (docs/reference/renderer.md, "Live pacing").
struct LiveStepPacerTests {
    /// The divisors: every 4th callback at 120 Hz, every 2nd at 60 Hz, every
    /// one at a 30 Hz link and every 8th at 240 Hz, the first one at once.
    @Test func integerMultiplesOfTheStepRateAskOnAFixedDivisor() {
        let rates: [(hz: Double, divisor: Int)] = [(120, 4), (60, 2), (30, 1), (240, 8)]
        for (hz, divisor) in rates {
            let asked = Pacer().run(period: 1 / hz, count: Int(hz) * 4)
            #expect(asked.first == 0)
            #expect(Set(gaps(asked)) == [divisor], "\(hz) Hz")
            #expect(asked.count == 4 * 30 || asked.count == 4 * 30 + 1, "\(hz) Hz: \(asked.count) steps in 4 s")
        }
    }

    /// 119.88 and 59.94 Hz: the asking callback is within the snap tolerance,
    /// so the steps keep a fixed divisor (29.97 steps a second) and never drift
    /// into a 3- or 5-vsync gap.
    @Test func ntscRatesSnapToTheVsyncGrid() {
        let rates: [(hz: Double, divisor: Int)] = [(120_000.0 / 1001, 4), (60_000.0 / 1001, 2)]
        for (hz, divisor) in rates {
            let asked = Pacer().run(period: 1 / hz, count: Int(hz) * 60)
            #expect(Set(gaps(asked)) == [divisor], "\(hz) Hz")
        }
    }

    /// 144 Hz is no multiple of 30: the steps stay on the 30 Hz grid, 5, 5, 4,
    /// 5 and 5 vsyncs apart, so they keep 30 a second.
    @Test func a144HzDisplayKeepsThirtyStepsASecond() {
        let asked = Pacer().run(period: 1.0 / 144, count: 144 * 10)
        #expect(Set(gaps(asked)) == [4, 5])
        #expect(Array(gaps(asked).prefix(10)) == [5, 5, 4, 5, 5, 5, 5, 4, 5, 5])
        #expect(asked.count == 300 || asked.count == 301)
    }

    /// A rate change (ProMotion, the adaptive link, another display) needs no
    /// notice: the rule reads the callbacks' own gap. 120 Hz, then a 30 Hz
    /// link, then 60 Hz, on one vsync grid: the steps stay 1/30 s apart.
    @Test func theRuleFollowsTheLinkRateAsItChanges() {
        let vsync = 1.0 / 120
        let callbacks = Array(0..<40) + (0..<10).map { 40 + 4 * $0 } + (0..<20).map { 80 + 2 * $0 }
        let pacer = Pacer()
        var steps: [Int] = []
        for vsyncs in callbacks {
            let target = 1000 + Double(vsyncs) * vsync
            if pacer.callback(target: target) {
                steps.append(vsyncs)
                pacer.finished(.ran, target: target)
            }
        }
        #expect(steps == Array(stride(from: 0, to: 120, by: 4)))
        // A slower link whose callbacks fall between the steps' vsyncs: the
        // step due between two callbacks waits for the later one, once; then
        // the steps follow the new callbacks, still one per 1/30 s.
        let shifted = Pacer()
        steps = []
        for vsyncs in Array(0...36) + (0..<10).map { 42 + 4 * $0 } {
            let target = 1000 + Double(vsyncs) * vsync
            if shifted.callback(target: target) {
                steps.append(vsyncs)
                shifted.finished(.ran, target: target)
            }
        }
        #expect(steps == Array(stride(from: 0, through: 36, by: 4)) + Array(stride(from: 42, through: 78, by: 4)), "\(steps)")
    }

    /// A busy answer (the previous step still running) skips that step, as a
    /// timer fire did: no retry, no queue, and the next step stays on the grid.
    @Test func aBusyStepIsSkippedAndTheNextOneStaysOnTheGrid() {
        let pacer = Pacer()
        var results: [Int: LiveStepPacer.Result] = [:]
        let asked = pacer.run(period: 1.0 / 120, count: 40) { index in
            let result: LiveStepPacer.Result = index == 8 || index == 12 ? .busy : .ran
            results[index] = result
            return result
        }
        #expect(asked == Array(stride(from: 0, to: 40, by: 4)))
        #expect(asked.filter { results[$0] == .ran }.count == 8)
    }

    /// Nothing to step (live animation off, a drag, another mode): asked again
    /// an interval later; the first step that runs then counts from its own
    /// callback.
    @Test func anIdleAnswerAsksAgainAnIntervalLater() {
        let pacer = Pacer()
        var answers: [LiveStepPacer.Result] = Array(repeating: .idle, count: 3) + Array(repeating: .ran, count: 10)
        let asked = pacer.run(period: 1.0 / 120, count: 40) { _ in answers.removeFirst() }
        #expect(asked == Array(stride(from: 0, to: 40, by: 4)))
    }

    /// One request at a time: while one is unanswered no callback asks, and
    /// an answer for another target (one from before a reset) is ignored.
    @Test func oneRequestIsInFlightAndStaleAnswersAreIgnored() {
        let pacer = Pacer()
        #expect(pacer.callback(target: 10))
        #expect(!pacer.callback(target: 10.1))
        #expect(!pacer.callback(target: 10.2))
        pacer.finished(.ran, target: 10.1)
        #expect(pacer.value.pending == 10)
        pacer.value.reset()
        pacer.finished(.ran, target: 10)
        #expect(pacer.value.pending == nil && pacer.value.due == nil)
        #expect(pacer.callback(target: 10.3))
        // A request answered after the following callbacks went by: the next
        // step is due an interval after its own target.
        #expect(!pacer.callback(target: 10.31))
        pacer.finished(.ran, target: 10.3)
        #expect(pacer.value.due == 10.3 + LiveStepPacer.standardInterval)
    }

    /// Hidden: no callback asks. Visible again: the next callback asks at once.
    @Test func aHiddenWindowAsksForNoStep() {
        let pacer = Pacer()
        _ = pacer.run(period: 1.0 / 120, count: 6)
        pacer.setVisible(false)
        #expect(pacer.run(period: 1.0 / 15, count: 30, start: 1001).isEmpty)
        pacer.setVisible(true)
        #expect(pacer.run(period: 1.0 / 120, count: 5, start: 1003) == [0, 4])
    }

    /// A long gap between callbacks (a stalled thread, a window that was
    /// off screen) asks at once instead of waiting out the old schedule.
    @Test func aLongGapBetweenCallbacksAsksAtOnce() {
        let pacer = Pacer()
        #expect(pacer.callback(target: 10))
        pacer.finished(.ran, target: 10)
        #expect(!pacer.callback(target: 10.01))
        // A due time far ahead (from a clock jump) is not waited for after a gap.
        #expect(pacer.callback(target: 10.01 + LiveStepPacer.resumeGap + 0.01))
    }
}
