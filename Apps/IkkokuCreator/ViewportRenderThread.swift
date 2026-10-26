import Foundation
import AppKit
import QuartzCore
import Metal
import Renderer

/// Runs one viewport's `CAMetalDisplayLink` on a dedicated thread (R7 phase 2,
/// item 2), so main-thread work (the 30 Hz Studio tick, input handlers, the
/// hover pick, SwiftUI layout) no longer delays presentation. The thread only
/// draws the renderer's pending frame (`Renderer.draw`, which takes it under
/// the renderer's own locks) and presents it; models keep calling
/// `Renderer.submit` on the main thread. See docs/reference/renderer.md,
/// "Renderer threads".
///
/// Lifetime: `ViewportNSView` calls `start()` when it enters a window and
/// `stop()` when it leaves one, is dismantled or deinitializes. `stop()`
/// returns at once; the thread invalidates the link and exits after the
/// draw in progress, if any. When the app terminates, the view stops its
/// thread and waits for it (at most `terminationWait`) before the process
/// exits, so `exit` never tears the process down under a draw.
///
/// Core Animation may still deliver an occasional callback on the main
/// thread. In four ThreadSanitizer Debug runs of the `viewport-lifecycle`
/// workload, 2 of about 2,000 callbacks did, each shortly after the layer
/// changed size; three Release runs had none. Creating the link on the
/// render thread instead did not prevent it. The callback is thread-agnostic:
/// `Renderer.draw` is safe from any thread, and the harness records which
/// thread drew.
///
/// Adaptive link rate and keep-alive (R7 phase 2, item 4, P2): after each
/// render-thread callback, `DisplayLinkRatePolicy` may lower the link's
/// `preferredFrameRateRange` (30 Hz after 0.5 s of unchanged frames, 15 Hz
/// after 3 s). `wake()` (viewport input, a resize, every `Renderer.submit`)
/// returns it to the link's original range at once: it schedules the change
/// on the render thread's run loop and wakes it. Each callback passes the
/// keep-alive interval to `Renderer.draw(refreshAfter:)`, so an idle viewport
/// presents its image again every 1/15 s. `setVisible(false)` (the window is
/// occluded, minimizing or minimized) drops the link to 15 Hz and turns the
/// keep-alive off until the window is visible again. `IKKOKU_PERF_LINK_RATE=fixed`
/// keeps the full rate and `IKKOKU_PERF_KEEPALIVE_MS` overrides the interval
/// (0 turns it off), measurement controls.
///
/// Live pacing (R7 phase 2): with a `pacedStep`, the callbacks also start the
/// model's fixed-rate step. A render-thread callback that `LiveStepPacer`
/// says is due asks the main thread for one step (`pacedStep`, in the main
/// run loop's default mode, like the timer it replaces), before it draws; the
/// answer goes back to the pacer. One request is in flight at a time. After
/// an `.idle` answer the pacer is parked until `resumePacing`. The step's
/// submit wakes the link like any other, so playback keeps the full rate. `IKKOKU_PERF_LIVE_PACING=timer` (no `pacedStep`) is a measurement
/// control. See docs/reference/renderer.md, "Live pacing".
///
/// Sendable invariant: `renderer`, `log`, `link`, `fullRate`, `adaptive`,
/// `keepAlive`, `pacedStep`, `finished` and `control` are set in `init` and
/// never reassigned; `renderer`, `log`, `finished` and `control` are
/// thread-safe, and `pacedStep` is only called on the main thread. `link` is
/// configured on the main thread before the thread starts and afterwards used
/// only on the render thread (added to its run loop, called, its rate set,
/// invalidated). `started`, `stopRequested`, `runLoop`, `policy`, `pacer` and
/// `submitObserver` are only read or written while holding `control`.
nonisolated final class ViewportRenderThread: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    /// How long app termination waits for a render thread to finish its draw.
    static let terminationWait: TimeInterval = 0.5

    private let renderer: Renderer
    private let log: PerfDrawLog?
    private let link: CAMetalDisplayLink
    /// The link's own range, restored whenever the policy returns to full rate.
    private let fullRate: CAFrameRateRange
    /// False under `IKKOKU_PERF_LINK_RATE=fixed`: the link never slows down.
    private let adaptive: Bool
    /// The idle keep-alive interval (`Renderer.draw(refreshAfter:)`); nil under
    /// `IKKOKU_PERF_KEEPALIVE_MS=0`.
    private let keepAlive: CFTimeInterval?
    /// No tiers under `IKKOKU_PERF_LINK_RATE=fixed`.
    private var policy: DisplayLinkRatePolicy
    private var submitObserver: UInt64?
    /// The model's paced step, called on the main thread; nil when the
    /// viewport's model has none or under `IKKOKU_PERF_LIVE_PACING=timer`.
    private let pacedStep: (@MainActor () -> LiveStepPacer.Result)?
    private var pacer = LiveStepPacer()
    /// Signalled when the thread has invalidated the link and is exiting.
    private let finished = DispatchSemaphore(value: 0)
    private let control = NSLock()
    private var stopRequested = false
    /// The render thread's run loop, once it runs.
    private var runLoop: CFRunLoop?
    private var started = false

    @MainActor
    init(layer: CAMetalLayer, renderer: Renderer, log: PerfDrawLog?, pacedStep: (@MainActor () -> LiveStepPacer.Result)? = nil) {
        self.renderer = renderer
        self.log = log
        self.pacedStep = pacedStep
        link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameLatency = 2
        fullRate = link.preferredFrameRateRange
        adaptive = PerfTrace.active?.configuration.linkRate != "fixed"
        policy = DisplayLinkRatePolicy(tiers: adaptive ? DisplayLinkRatePolicy.standardTiers : [])
        keepAlive = PerfTrace.active?.configuration.keepAliveMilliseconds.map { $0 > 0 ? Double($0) / 1000 : nil }
            ?? DisplayLinkRatePolicy.keepAliveInterval
        super.init()
        link.delegate = self
    }

    /// Starts the render thread; the display link begins calling on it.
    @MainActor
    func start() {
        control.lock()
        guard !started, !stopRequested else { control.unlock(); return }
        started = true
        control.unlock()
        let thread = Thread { [self] in run() }
        renderer.invalidateInteractiveFrame()
        if adaptive {
            let token = renderer.addSubmitObserver { [weak self] in self?.wake() }
            control.lock()
            let stopped = stopRequested
            if !stopped { submitObserver = token }
            control.unlock()
            if stopped { renderer.removeSubmitObserver(token) }
        }
        thread.name = ViewportFrame.renderThreadName
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Asks the thread to invalidate the link and exit; returns at once.
    /// Safe from any thread and more than once.
    func stop() {
        control.lock()
        stopRequested = true
        let loop = runLoop
        let observer = submitObserver
        submitObserver = nil
        control.unlock()
        if let observer { renderer.removeSubmitObserver(observer) }
        // A stop requested before the loop runs is seen by its first check.
        if let loop { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) }
    }

    /// `stop()`, then waits up to `seconds` for the thread to exit.
    /// Returns whether it did (true when it never started).
    @discardableResult
    func stopAndWait(_ seconds: TimeInterval) -> Bool {
        stop()
        control.lock()
        let running = started
        control.unlock()
        guard running else { return true }
        let exited = finished.wait(timeout: .now() + seconds) == .success
        if exited { finished.signal() }   // keep it signalled for a later wait
        return exited
    }

    private var isStopRequested: Bool { control.lock(); defer { control.unlock() }; return stopRequested }

    /// The thread's body: the link's run loop until `stop`.
    private func run() {
        Thread.current.name = ViewportFrame.renderThreadName
        control.lock()
        runLoop = CFRunLoopGetCurrent()
        control.unlock()
        // A port keeps the run loop waiting (rather than returning at once)
        // whenever the link has nothing scheduled, for example while the
        // window is minimized.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        link.add(to: .current, forMode: .default)
        // A visibility change before the loop ran could not schedule its rate.
        applyRate()
        while !isStopRequested {
            // Returns after each callback, on `stop` (CFRunLoopStop) or after
            // a quarter second, so the flag is checked even if a stop's wake-up
            // were missed.
            autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, 0.25, true) }
        }
        link.invalidate()
        control.lock()
        runLoop = nil
        control.unlock()
        finished.signal()
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let target = update.targetPresentationTimestamp
        // Only render-thread callbacks pace the step (see the type's notes).
        let paces = pacedStep != nil && pthread_main_np() == 0
        control.lock()
        let refreshAfter = policy.refreshAfter(keepAlive)
        let step = paces && pacer.callback(target: target)
        control.unlock()
        // Asked before the draw, so the step runs beside it.
        if step { requestStep(target: target) }
        autoreleasepool {
            ViewportFrame.draw(update, renderer: renderer, log: log, refreshAfter: refreshAfter) { self.afterDraw($0) }
        }
    }

    // MARK: Live pacing (R7 phase 2)

    /// Asks the main thread for one paced step for the callback targeting
    /// `target`, in the main run loop's default mode: like the 30 Hz timer
    /// this replaces, a step never runs during AppKit event tracking.
    private func requestStep(target: CFTimeInterval) {
        let asked = CACurrentMediaTime()
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.defaultMode.rawValue) { [self] in
            let started = CACurrentMediaTime()
            // A thread stopped since it asked (its view left the window, or a
            // new thread replaced it) starts no step.
            let result = isStopRequested ? .idle : MainActor.assumeIsolated { pacedStep?() } ?? .idle
            log?.didPace(target: target, asked: asked, started: started, result: result)
            control.lock()
            pacer.finished(result, target: target)
            control.unlock()
        }
        CFRunLoopWakeUp(main)
    }

    /// The model has something to step again: a pacer parked by an `.idle`
    /// answer asks at the next callback, and the link returns to full rate
    /// so that callback comes within a vsync. Safe from any thread.
    func resumePacing() {
        control.lock()
        let resumed = pacer.resume()
        control.unlock()
        if resumed { wake() }
    }

    // MARK: Adaptive link rate (R7 phase 2, item 4, P2)

    /// Returns the link to full rate at once after input, a resize or a
    /// submit. Thread-safe and cheap while the rate is already full: one lock.
    func wake() {
        guard adaptive else { return }
        control.lock()
        let restore = policy.wake(at: CACurrentMediaTime())
        let loop = restore ? runLoop : nil
        control.unlock()
        if let loop { scheduleRate(on: loop) }
    }

    /// The window's visibility changed (`ViewportNSView`: its occlusion state
    /// and minimizing). Not visible: the link idles at its slowest rate without the keep-alive,
    /// ignoring submits and input. Visible again: the cached image is dropped
    /// so the next callback renders and presents the current frame, which
    /// returns the link to full rate. Safe from any thread.
    func setVisible(_ visible: Bool) {
        control.lock()
        let returned = visible && !policy.visible
        // Hidden: the link asks for no step.
        pacer.setVisible(visible)
        let changed = policy.setVisible(visible, at: CACurrentMediaTime())
        let loop = changed ? runLoop : nil
        control.unlock()
        if returned { renderer.invalidateInteractiveFrame() }
        if let loop { scheduleRate(on: loop) }
    }

    /// The link is only touched on its thread: run the change there now.
    private func scheduleRate(on loop: CFRunLoop) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in applyRate() }
        CFRunLoopWakeUp(loop)
    }

    /// After one callback: updates the policy and, on the render thread,
    /// applies a changed rate. Returns the rate in force for the interval that
    /// follows (0 for full rate), which the harness records.
    private func afterDraw(_ outcome: RenderDrawResult.Outcome) -> Float {
        control.lock()
        // A callback Core Animation delivers on the main thread draws but
        // leaves the policy and the link alone.
        let changed = pthread_main_np() == 0 && policy.callback(at: CACurrentMediaTime(), outcome: outcome)
        let hz = policy.hz
        control.unlock()
        if changed { link.preferredFrameRateRange = range(hz) }
        return hz ?? 0
    }

    /// Render thread only: sets the link to the policy's current rate.
    private func applyRate() {
        control.lock(); let hz = policy.hz; control.unlock()
        link.preferredFrameRateRange = range(hz)
    }

    private func range(_ hz: Float?) -> CAFrameRateRange {
        hz.map { CAFrameRateRange(minimum: $0, maximum: $0, preferred: $0) } ?? fullRate
    }
}
