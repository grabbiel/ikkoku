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

/// The Metal viewport. Its display link runs on its own render thread
/// (`ViewportRenderThread`) while the view is in a window; input is handled
/// on the main thread and forwarded to the `handler`.
final class ViewportNSView: NSView {
    private let renderer: Renderer
    private var renderThread: ViewportRenderThread?
    weak var handler: (any ViewportInputHandler)?
    private var lastPoint = SIMD2<Float>(0, 0)
    private var tracking: NSTrackingArea?

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
        guard window != nil else {
            stopRendering()
            return
        }
        updateDrawableSize()
        if renderThread == nil {
            let thread = ViewportRenderThread(layer: metalLayer, renderer: renderer, log: PerfTrace.active?.drawLog)
            thread.start()
            renderThread = thread
        }
        window?.makeFirstResponder(self)
    }

    /// Stops the render thread (it exits after any draw in progress).
    func stopRendering() {
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
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        metalLayer.drawableSize = size
        handler?.viewportSize = SIMD2<Float>(Float(size.width), Float(size.height))
    }

    // MARK: Input

    private func pixel(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        let scale = Float(window?.backingScaleFactor ?? 2)
        return SIMD2<Float>(Float(p.x) * scale, Float(p.y) * scale)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = pixel(event); lastPoint = p
        PerfTrace.input("mouseDown") { handler?.mouseDown(at: p, button: 0, modifiers: event.modifierFlags) }
    }
    override func rightMouseDown(with event: NSEvent) {
        let p = pixel(event); lastPoint = p
        PerfTrace.input("mouseDown") { handler?.mouseDown(at: p, button: 1, modifiers: event.modifierFlags) }
    }
    override func otherMouseDown(with event: NSEvent) {
        let p = pixel(event); lastPoint = p
        PerfTrace.input("mouseDown") { handler?.mouseDown(at: p, button: 2, modifiers: event.modifierFlags) }
    }

    override func mouseDragged(with event: NSEvent) { drag(event, button: 0) }
    override func rightMouseDragged(with event: NSEvent) { drag(event, button: 1) }
    override func otherMouseDragged(with event: NSEvent) { drag(event, button: 2) }
    private func drag(_ event: NSEvent, button: Int) {
        let p = pixel(event)
        let d = p - lastPoint
        lastPoint = p
        PerfTrace.input("mouseDragged") { handler?.mouseDragged(to: p, delta: d, button: button, modifiers: event.modifierFlags) }
    }

    override func mouseUp(with event: NSEvent) { up(event, button: 0) }
    override func rightMouseUp(with event: NSEvent) { up(event, button: 1) }
    override func otherMouseUp(with event: NSEvent) { up(event, button: 2) }
    private func up(_ event: NSEvent, button: Int) {
        let p = pixel(event)
        PerfTrace.input("mouseUp") { handler?.mouseUp(at: p, button: button, modifiers: event.modifierFlags) }
    }
    override func mouseMoved(with event: NSEvent) {
        let p = pixel(event)
        PerfTrace.input("mouseMoved") { handler?.mouseMoved(to: p) }
    }

    override func scrollWheel(with event: NSEvent) {
        let scale: Float = event.hasPreciseScrollingDeltas ? 0.15 : 1.0
        let delta = SIMD2<Float>(Float(event.scrollingDeltaX) * scale, Float(event.scrollingDeltaY) * scale)
        PerfTrace.input("scrolled") { handler?.scrolled(delta: delta, modifiers: event.modifierFlags) }
    }
    override func magnify(with event: NSEvent) {
        let amount = Float(event.magnification)
        PerfTrace.input("magnified") { handler?.magnified(by: amount) }
    }
    override func keyDown(with event: NSEvent) {
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
