//
//  MetalHostView.swift
//  IkkokuCreator
//
//  Created by rumpology on 8/19/26.
//

import SwiftUI
import Metal
import QuartzCore
import GPU

final class MetalView: NSView, CAMetalDisplayLinkDelegate {
    private let gpu: GPUContext
    private var displayLink: CAMetalDisplayLink?
    private var frameIndex = 0

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(gpu: GPUContext) {
        self.gpu = gpu
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = gpu.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
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
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.preferredFrameLatency = 2
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale))
    }

    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink,
                                      needsUpdate update: CAMetalDisplayLink.Update) {
        let drawable = update.drawable

        gpu.waitForFrameSlot()
        guard let commandBuffer = gpu.commandQueue.makeCommandBuffer() else {
            gpu.releaseFrameSlot()
            return
        }
        commandBuffer.label = "Frame"

        let t = update.targetPresentationTimestamp
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.5 + 0.5 * sin(t),
            green: 0.08,
            blue: 0.5 + 0.5 * cos(t * 0.7),
            alpha: 1)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.label = "Clear"
            encoder.endEncoding()
        }

        gpu.releaseFrameSlot(onCompletionOf: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct MetalHostView: NSViewRepresentable {
    let gpu: GPUContext
    func makeNSView(context: Context) -> MetalView { MetalView(gpu: gpu) }
    func updateNSView(_ view: MetalView, context: Context) {}
}
