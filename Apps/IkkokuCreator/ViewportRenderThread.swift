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
/// Sendable invariant: `renderer`, `log`, `link`, `finished` and `control`
/// are set in `init` and never reassigned; `renderer`, `log`, `finished` and
/// `control` are thread-safe. `link` is configured on the main thread before
/// the thread starts and afterwards used only on the render thread (added to
/// its run loop, called, invalidated). `started`, `stopRequested` and
/// `runLoop` are only read or written while holding `control`.
nonisolated final class ViewportRenderThread: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    /// How long app termination waits for a render thread to finish its draw.
    static let terminationWait: TimeInterval = 0.5

    private let renderer: Renderer
    private let log: PerfDrawLog?
    private let link: CAMetalDisplayLink
    /// Signalled when the thread has invalidated the link and is exiting.
    private let finished = DispatchSemaphore(value: 0)
    private let control = NSLock()
    private var stopRequested = false
    /// The render thread's run loop, once it runs.
    private var runLoop: CFRunLoop?
    private var started = false

    @MainActor
    init(layer: CAMetalLayer, renderer: Renderer, log: PerfDrawLog?) {
        self.renderer = renderer
        self.log = log
        link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameLatency = 2
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
        control.unlock()
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
        autoreleasepool { ViewportFrame.draw(update, renderer: renderer, log: log) }
    }
}
