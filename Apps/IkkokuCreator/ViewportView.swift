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

final class ViewportNSView: NSView, CAMetalDisplayLinkDelegate {
    private let renderer: Renderer
    private var displayLink: CAMetalDisplayLink?
    weak var handler: (any ViewportInputHandler)?
    private var lastPoint = SIMD2<Float>(0, 0)
    private var tracking: NSTrackingArea?

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(renderer: Renderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
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
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        updateDrawableSize()
        if displayLink == nil {
            let link = CAMetalDisplayLink(metalLayer: metalLayer)
            link.delegate = self
            link.preferredFrameLatency = 2
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        window?.makeFirstResponder(self)
    }

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

    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        renderer.draw(to: update.drawable, timestamp: update.targetPresentationTimestamp)
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
        handler?.mouseDown(at: p, button: 0, modifiers: event.modifierFlags)
    }
    override func rightMouseDown(with event: NSEvent) { let p = pixel(event); lastPoint = p; handler?.mouseDown(at: p, button: 1, modifiers: event.modifierFlags) }
    override func otherMouseDown(with event: NSEvent) { let p = pixel(event); lastPoint = p; handler?.mouseDown(at: p, button: 2, modifiers: event.modifierFlags) }

    override func mouseDragged(with event: NSEvent) { drag(event, button: 0) }
    override func rightMouseDragged(with event: NSEvent) { drag(event, button: 1) }
    override func otherMouseDragged(with event: NSEvent) { drag(event, button: 2) }
    private func drag(_ event: NSEvent, button: Int) {
        let p = pixel(event)
        let d = p - lastPoint
        lastPoint = p
        handler?.mouseDragged(to: p, delta: d, button: button, modifiers: event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) { handler?.mouseUp(at: pixel(event), button: 0, modifiers: event.modifierFlags) }
    override func rightMouseUp(with event: NSEvent) { handler?.mouseUp(at: pixel(event), button: 1, modifiers: event.modifierFlags) }
    override func otherMouseUp(with event: NSEvent) { handler?.mouseUp(at: pixel(event), button: 2, modifiers: event.modifierFlags) }
    override func mouseMoved(with event: NSEvent) { handler?.mouseMoved(to: pixel(event)) }

    override func scrollWheel(with event: NSEvent) {
        let scale: Float = event.hasPreciseScrollingDeltas ? 0.15 : 1.0
        handler?.scrolled(delta: SIMD2<Float>(Float(event.scrollingDeltaX) * scale, Float(event.scrollingDeltaY) * scale), modifiers: event.modifierFlags)
    }
    override func magnify(with event: NSEvent) { handler?.magnified(by: Float(event.magnification)) }
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
}
