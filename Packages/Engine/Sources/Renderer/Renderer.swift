//
//  Renderer.swift
//  Engine
//
//  Created by rumpology on 8/20/26.
//
import Metal
import QuartzCore
import simd
import CoreMath
import GPU
import ShaderTypes

public enum RendererError: Error, CustomStringConvertible {
    case missingFunction(String)
    case depthStateCreationFailed
    case frameRingCreationFailed

    public var description: String {
        switch self {
        case .missingFunction(let name): return "Shader function '\(name)' not found."
        case .depthStateCreationFailed:  return "Could not create depth stencil state."
        case .frameRingCreationFailed:   return "Could not allocate the frame ring buffer."
        }
    }
}

public final class Renderer: @unchecked Sendable {
    public static let depthFormat: MTLPixelFormat = .depth32Float

    private let gpu: GPUContext
    private let pipelineState: any MTLRenderPipelineState
    private let depthState: any MTLDepthStencilState
    private let frameRing: FrameRing

    private var depthTexture: (any MTLTexture)?
    private var frameIndex = 0

    public var cameraDistance: Float = 3
    public var fieldOfView: Float = .pi / 3

    public init(gpu: GPUContext, colorFormat: MTLPixelFormat) throws {
        self.gpu = gpu

        let library = try gpu.makeShaderLibrary()
        guard let vertexFn = library.makeFunction(name: "triangle_vertex") else {
            throw RendererError.missingFunction("triangle_vertex")
        }
        guard let fragmentFn = library.makeFunction(name: "triangle_fragment") else {
            throw RendererError.missingFunction("triangle_fragment")
        }

        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.label = "Triangle"
        pipeline.vertexFunction = vertexFn
        pipeline.fragmentFunction = fragmentFn
        pipeline.colorAttachments[0].pixelFormat = colorFormat
        pipeline.depthAttachmentPixelFormat = Renderer.depthFormat
        self.pipelineState = try gpu.device.makeRenderPipelineState(descriptor: pipeline)

        let depth = MTLDepthStencilDescriptor()
        depth.label = "ReverseZ"
        depth.depthCompareFunction = .greater      // reverse-Z
        depth.isDepthWriteEnabled = true
        guard let depthState = gpu.device.makeDepthStencilState(descriptor: depth) else {
            throw RendererError.depthStateCreationFailed
        }
        self.depthState = depthState

        guard let ring = FrameRing(device: gpu.device) else {
            throw RendererError.frameRingCreationFailed
        }
        self.frameRing = ring
    }

    public func draw(to drawable: any CAMetalDrawable, timestamp: CFTimeInterval) {
        let width = drawable.texture.width
        let height = drawable.texture.height
        guard width > 0, height > 0 else { return }

        gpu.waitForFrameSlot()
        guard let commandBuffer = gpu.commandQueue.makeCommandBuffer() else {
            gpu.releaseFrameSlot()
            return
        }
        commandBuffer.label = "Frame"

        frameRing.beginFrame(frameIndex)

        let eye = SIMD3<Float>(0, 0, cameraDistance)
        let view = Projection.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        let projection = Projection.perspectiveReverseZInfinite(
            fovyRadians: fieldOfView,
            aspect: Float(width) / Float(height),
            near: 0.1)

        var frame = FrameUniforms()
        frame.viewProjection = projection * view
        frame.inverseView = view.inverse
        frame.cameraPosition = eye
        frame.time = Float(timestamp)
        let frameOffset = frameRing.allocate(frame)

        let model = Transform.rotationY(Float(timestamp))
        var draw = DrawUniforms()
        draw.model = model
        draw.normalMatrix = Transform.normalMatrix(from: model)
        let drawOffset = frameRing.allocate(draw)

        ensureDepthTexture(width: width, height: height)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor =
            MTLClearColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare   // memoryless: never leaves tile memory
        pass.depthAttachment.clearDepth = 0.0          // reverse-Z: far = 0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            gpu.releaseFrameSlot()
            return
        }
        encoder.label = "Forward"
        encoder.pushDebugGroup("Triangle")
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(frameRing.buffer, offset: frameOffset,
                                index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setVertexBuffer(frameRing.buffer, offset: drawOffset,
                                index: Int(BufferIndexDrawUniforms.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.popDebugGroup()
        encoder.endEncoding()

        gpu.releaseFrameSlot(onCompletionOf: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()

        frameIndex &+= 1
    }

    private func ensureDepthTexture(width: Int, height: Int) {
        if let existing = depthTexture, existing.width == width, existing.height == height {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Renderer.depthFormat,
            width: width, height: height, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .memoryless
        let texture = gpu.device.makeTexture(descriptor: desc)
        texture?.label = "Depth"
        depthTexture = texture
    }
}

