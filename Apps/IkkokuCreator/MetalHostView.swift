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
import Renderer

final class MetalView: NSView, CAMetalDisplayLinkDelegate {
    private let gpu: GPUContext
    private var displayLink: CAMetalDisplayLink?
    nonisolated(unsafe) private var renderer: Renderer?

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

        if renderer == nil {
            do {
                renderer = try Renderer(gpu: gpu, colorFormat: metalLayer.pixelFormat)
            } catch {
                print("[ikkoku] renderer init failed: \(error)")
                return
            }
        }

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
        renderer?.draw(to: update.drawable,
                       timestamp: update.targetPresentationTimestamp)
    }
}

struct MetalHostView: NSViewRepresentable {
    let gpu: GPUContext
    func makeNSView(context: Context) -> MetalView { MetalView(gpu: gpu) }
    func updateNSView(_ view: MetalView, context: Context) {}
}
