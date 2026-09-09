import Foundation
import Metal
import GPU
import ShaderTypes

/// All pipeline and depth-stencil state objects, built once.
final class Pipelines: @unchecked Sendable {
    static let hdrFormat: MTLPixelFormat = .rgba16Float
    static let ldrFormat: MTLPixelFormat = .bgra8Unorm
    static let depthFormat: MTLPixelFormat = .depth32Float
    static let pickFormat: MTLPixelFormat = .r32Uint
    static let sampleCount = 4

    let device: any MTLDevice
    let library: any MTLLibrary

    let deform: any MTLComputePipelineState
    let toonOpaque: any MTLRenderPipelineState
    let toonBlend: any MTLRenderPipelineState
    let eye: any MTLRenderPipelineState
    let outline: any MTLRenderPipelineState
    let shadow: any MTLRenderPipelineState
    let background: any MTLRenderPipelineState
    let grid: any MTLRenderPipelineState
    let gizmoHDR: any MTLRenderPipelineState      // depth-tested, in the main pass
    let gizmoLDR: any MTLRenderPipelineState      // overlay on the final image
    let bloomThreshold: any MTLRenderPipelineState
    let bloomDown: any MTLRenderPipelineState
    let bloomUp: any MTLRenderPipelineState
    let composite: any MTLRenderPipelineState
    let fxaa: any MTLRenderPipelineState
    let blit: any MTLRenderPipelineState
    let pick: any MTLRenderPipelineState
    let pickGizmo: any MTLRenderPipelineState

    let depthWrite: any MTLDepthStencilState          // greater, write
    let depthTest: any MTLDepthStencilState           // greater, no write
    let depthNone: any MTLDepthStencilState           // always, no write

    init(gpu: GPUContext) throws {
        let device = gpu.device
        let library = try gpu.makeShaderLibrary()
        self.device = device
        self.library = library

        func fn(_ name: String) throws -> any MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw RendererError.missingFunction(name) }
            return f
        }
        func render(_ label: String, _ v: String, _ f: String?, color: MTLPixelFormat?, depth: MTLPixelFormat?, samples: Int,
                    blend: Blend = .none, configure: ((MTLRenderPipelineDescriptor) -> Void)? = nil) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = try fn(v)
            d.fragmentFunction = try f.map { try fn($0) }
            d.rasterSampleCount = samples
            if let color {
                d.colorAttachments[0].pixelFormat = color
                switch blend {
                case .none: break
                case .alpha:
                    let a = d.colorAttachments[0]!
                    a.isBlendingEnabled = true
                    a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
                    a.sourceRGBBlendFactor = .sourceAlpha; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                case .additive:
                    let a = d.colorAttachments[0]!
                    a.isBlendingEnabled = true
                    a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
                    a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .one
                    a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .one
                }
            }
            if let depth { d.depthAttachmentPixelFormat = depth }
            configure?(d)
            return try device.makeRenderPipelineState(descriptor: d)
        }

        let hdr = Pipelines.hdrFormat, ldr = Pipelines.ldrFormat, dep = Pipelines.depthFormat, ms = Pipelines.sampleCount

        deform = try device.makeComputePipelineState(function: fn("deform_vertices"))
        toonOpaque = try render("ToonOpaque", "toon_vertex", "toon_fragment", color: hdr, depth: dep, samples: ms)
        toonBlend = try render("ToonBlend", "toon_vertex", "toon_fragment", color: hdr, depth: dep, samples: ms, blend: .alpha)
        eye = try render("Eye", "toon_vertex", "eye_fragment", color: hdr, depth: dep, samples: ms)
        outline = try render("Outline", "outline_vertex", "outline_fragment", color: hdr, depth: dep, samples: ms)
        shadow = try render("Shadow", "shadow_vertex", "shadow_fragment", color: nil, depth: dep, samples: 1)
        background = try render("Background", "fullscreen_vertex", "background_fragment", color: hdr, depth: dep, samples: ms)
        grid = try render("Grid", "grid_vertex", "grid_fragment", color: hdr, depth: dep, samples: ms, blend: .alpha)
        gizmoHDR = try render("GizmoHDR", "gizmo_vertex", "gizmo_fragment", color: hdr, depth: dep, samples: ms, blend: .alpha)
        gizmoLDR = try render("GizmoLDR", "gizmo_vertex", "gizmo_fragment", color: ldr, depth: dep, samples: 1, blend: .alpha)
        bloomThreshold = try render("BloomThreshold", "fullscreen_vertex", "bloom_threshold_fragment", color: hdr, depth: nil, samples: 1)
        bloomDown = try render("BloomDown", "fullscreen_vertex", "bloom_downsample_fragment", color: hdr, depth: nil, samples: 1)
        bloomUp = try render("BloomUp", "fullscreen_vertex", "bloom_upsample_fragment", color: hdr, depth: nil, samples: 1, blend: .additive)
        composite = try render("Composite", "fullscreen_vertex", "composite_fragment", color: ldr, depth: nil, samples: 1)
        fxaa = try render("FXAA", "fullscreen_vertex", "fxaa_fragment", color: ldr, depth: nil, samples: 1)
        blit = try render("Blit", "fullscreen_vertex", "blit_fragment", color: ldr, depth: nil, samples: 1)
        pick = try render("Pick", "pick_vertex", "pick_fragment", color: Pipelines.pickFormat, depth: dep, samples: 1)
        pickGizmo = try render("PickGizmo", "pick_gizmo_vertex", "pick_gizmo_fragment", color: Pipelines.pickFormat, depth: dep, samples: 1)

        func depthState(_ label: String, _ compare: MTLCompareFunction, write: Bool) throws -> any MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.label = label
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            guard let s = device.makeDepthStencilState(descriptor: d) else { throw RendererError.depthStateCreationFailed }
            return s
        }
        depthWrite = try depthState("DepthWrite", .greater, write: true)
        depthTest = try depthState("DepthTest", .greater, write: false)
        depthNone = try depthState("DepthNone", .always, write: false)
    }

    enum Blend { case none, alpha, additive }
}

public enum RendererError: Error, CustomStringConvertible {
    case missingFunction(String)
    case depthStateCreationFailed
    case frameRingCreationFailed
    case textureCreationFailed
    public var description: String {
        switch self {
        case .missingFunction(let n): return "Shader function '\(n)' not found."
        case .depthStateCreationFailed: return "Could not create depth stencil state."
        case .frameRingCreationFailed: return "Could not allocate the frame ring buffer."
        case .textureCreationFailed: return "Could not allocate a render target."
        }
    }
}
