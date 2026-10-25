import SwiftUI
import AppKit
import Metal
import QuartzCore
import simd
import GPU
import Renderer

/// Receives viewport input in pixel coordinates (origin top-left).
@MainActor
protocol ViewportInputHandler: AnyObject {
    var viewportSize: SIMD2<Float> { get set }
    func mouseDown(at p: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags)
    func mouseDragged(to p: SIMD2<Float>, delta: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags)
    func mouseUp(at p: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags)
    func mouseMoved(to p: SIMD2<Float>)
    func scrolled(delta: SIMD2<Float>, modifiers: NSEvent.ModifierFlags)
    func magnified(by amount: Float)
    func keyDown(_ event: NSEvent) -> Bool
}

/// A viewport model whose fixed-rate step the viewport's display link starts
/// (R7 phase 2, live pacing; docs/reference/renderer.md, "Live pacing"). The
/// Studio is one; the Maker keeps its own timer.
@MainActor
protocol LivePacedHandler: AnyObject {
    /// The viewport `owner`'s display link starts the steps from now on.
    func attachLivePacing(_ owner: AnyObject)
    /// It no longer does (its thread stopped, or the handler changed).
    func detachLivePacing(_ owner: AnyObject)
    /// One step the link asked for; how it ended (`LiveStepPacer.Result`).
    func displayStep() -> LiveStepPacer.Result
}

/// The Metal viewport. Its display link runs on its own render thread
/// (`ViewportRenderThread`) while the view is in a window; input is handled
/// on the main thread and forwarded to the `handler`.
final class ViewportNSView: NSView {
    private let renderer: Renderer
    private var renderThread: ViewportRenderThread?
    weak var handler: (any ViewportInputHandler)? {
        didSet {
            guard handler !== oldValue, threadPaces else { return }
            (oldValue as? LivePacedHandler)?.detachLivePacing(self)
            (handler as? LivePacedHandler)?.attachLivePacing(self)
        }
    }
    /// Whether this viewport's display link may start its model's steps (off
    /// under `IKKOKU_PERF_LIVE_PACING=timer`, a measurement control).
    private let pacesSteps = PerfTrace.active?.configuration.livePacing != "timer"
    /// Whether the running render thread starts the steps: decided when it
    /// starts, from `pacesSteps` and whether the handler is a `LivePacedHandler`
    /// (the Maker's is not, so its link sends no requests).
    private var threadPaces = false
    private var lastPoint = SIMD2<Float>(0, 0)
    private var tracking: NSTrackingArea?
    /// The window whose occlusion and minimizing this view follows.
    private weak var observedWindow: NSWindow?

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(renderer: Renderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        // Removed automatically when the view deallocates.
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer.gpu.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        return layer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeOcclusion(of: window)
        guard let window else {
            stopRendering()
            return
        }
        updateDrawableSize()
        if renderThread == nil {
            let paces = pacesSteps && (handler as? LivePacedHandler) != nil
            var step: (@MainActor () -> LiveStepPacer.Result)?
            if paces { step = { [weak self] in self?.displayStep() ?? .idle } }
            let thread = ViewportRenderThread(layer: metalLayer, renderer: renderer, log: PerfTrace.active?.drawLog, pacedStep: step)
            thread.setVisible(isVisible(window))
            thread.start()
            renderThread = thread
            threadPaces = paces
            if paces { (handler as? LivePacedHandler)?.attachLivePacing(self) }
        }
        window.makeFirstResponder(self)
    }

    /// The step the render thread asked for, on the main thread.
    private func displayStep() -> LiveStepPacer.Result {
        guard threadPaces, let model = handler as? LivePacedHandler else { return .idle }
        return model.displayStep()
    }

    /// The notifications that can change whether the window shows the viewport.
    private static let visibilityNotifications = [NSWindow.didChangeOcclusionStateNotification,
                                                  NSWindow.willMiniaturizeNotification,
                                                  NSWindow.didDeminiaturizeNotification]

    /// An occluded, minimizing or minimized window shows nothing the viewport
    /// presents: its render thread idles without the keep-alive until the
    /// window is visible again (R7 phase 2, item 4).
    private func observeOcclusion(of window: NSWindow?) {
        guard window !== observedWindow else { return }
        let center = NotificationCenter.default
        if let observedWindow {
            for name in Self.visibilityNotifications { center.removeObserver(self, name: name, object: observedWindow) }
        }
        observedWindow = window
        minimizing = false
        if let window {
            for name in Self.visibilityNotifications {
                center.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: window)
            }
        }
    }

    /// From `willMiniaturize` to `didDeminiaturize`. The occlusion state only
    /// loses `.visible` when the minimize animation ends, about 0.7 s later.
    private var minimizing = false

    private func isVisible(_ window: NSWindow) -> Bool {
        window.occlusionState.contains(.visible) && !window.isMiniaturized && !minimizing
    }

    @objc private func visibilityChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        if notification.name == NSWindow.willMiniaturizeNotification { minimizing = true }
        if notification.name == NSWindow.didDeminiaturizeNotification { minimizing = false }
        renderThread?.setVisible(isVisible(window))
    }

    /// Stops the render thread (it exits after any draw in progress).
    func stopRendering() {
        if threadPaces { (handler as? LivePacedHandler)?.detachLivePacing(self) }
        threadPaces = false
        renderThread?.stop()
        renderThread = nil
    }

    /// Quitting while the link draws: let the draw in progress finish before
    /// the process exits.
    @objc private func applicationWillTerminate(_ notification: Notification) {
        renderThread?.stopAndWait(ViewportRenderThread.terminationWait)
    }

    // `stop()` is thread-safe and idempotent; this covers a view released
    // without leaving its window.
    deinit { renderThread?.stop() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateDrawableSize() }

    private func updateDrawableSize() {
        renderThread?.wake()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        metalLayer.drawableSize = size
        handler?.viewportSize = SIMD2<Float>(Float(size.width), Float(size.height))
    }

    // MARK: Input

    // Every input returns the display link to full rate before its handler
    // runs (R7 phase 2, item 4, P2), even when the handler submits nothing yet
    // (a hover pick still in flight, a key the handler ignores).

    private func pixel(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        let scale = Float(window?.backingScaleFactor ?? 2)
        return SIMD2<Float>(Float(p.x) * scale, Float(p.y) * scale)
    }

    override func mouseDown(with event: NSEvent) {
        renderThread?.wake()
        window?.makeFirstResponder(self)
        let p = pixel(event); lastPoint = p
        PerfTrace.input("mouseDown") { handler?.mouseDown(at: p, button: 0, modifiers: event.modifierFlags) }
    }
    override func rightMouseDown(with event: NSEvent) {
        renderThread?.wake()
        let p = pixel(event); lastPoint = p
        PerfTrace.input("mouseDown") { handler?.mouseDown(at: p, button: 1, modifiers: event.modifierFlags) }
    }
    override func otherMouseDown(with event: NSEvent) {
        renderThread?.wake()
        let p = pixel(event); lastPoint = p
        PerfTrace.input("mouseDown") { handler?.mouseDown(at: p, button: 2, modifiers: event.modifierFlags) }
    }

    override func mouseDragged(with event: NSEvent) { drag(event, button: 0) }
    override func rightMouseDragged(with event: NSEvent) { drag(event, button: 1) }
    override func otherMouseDragged(with event: NSEvent) { drag(event, button: 2) }
    private func drag(_ event: NSEvent, button: Int) {
        renderThread?.wake()
        let p = pixel(event)
        let d = p - lastPoint
        lastPoint = p
        PerfTrace.input("mouseDragged") { handler?.mouseDragged(to: p, delta: d, button: button, modifiers: event.modifierFlags) }
    }

    override func mouseUp(with event: NSEvent) { up(event, button: 0) }
    override func rightMouseUp(with event: NSEvent) { up(event, button: 1) }
    override func otherMouseUp(with event: NSEvent) { up(event, button: 2) }
    private func up(_ event: NSEvent, button: Int) {
        renderThread?.wake()
        let p = pixel(event)
        PerfTrace.input("mouseUp") { handler?.mouseUp(at: p, button: button, modifiers: event.modifierFlags) }
    }
    override func mouseMoved(with event: NSEvent) {
        renderThread?.wake()
        let p = pixel(event)
        PerfTrace.input("mouseMoved") { handler?.mouseMoved(to: p) }
    }

    override func scrollWheel(with event: NSEvent) {
        renderThread?.wake()
        let scale: Float = event.hasPreciseScrollingDeltas ? 0.15 : 1.0
        let delta = SIMD2<Float>(Float(event.scrollingDeltaX) * scale, Float(event.scrollingDeltaY) * scale)
        PerfTrace.input("scrolled") { handler?.scrolled(delta: delta, modifiers: event.modifierFlags) }
    }
    override func magnify(with event: NSEvent) {
        renderThread?.wake()
        let amount = Float(event.magnification)
        PerfTrace.input("magnified") { handler?.magnified(by: amount) }
    }
    override func keyDown(with event: NSEvent) {
        renderThread?.wake()
        if handler?.keyDown(event) != true { super.keyDown(with: event) }
    }
}

struct ViewportView: NSViewRepresentable {
    let renderer: Renderer
    let handler: any ViewportInputHandler

    func makeNSView(context: Context) -> ViewportNSView {
        let v = ViewportNSView(renderer: renderer)
        v.handler = handler
        return v
    }
    func updateNSView(_ view: ViewportNSView, context: Context) { view.handler = handler }
    static func dismantleNSView(_ view: ViewportNSView, coordinator: ()) { view.stopRendering() }
}
