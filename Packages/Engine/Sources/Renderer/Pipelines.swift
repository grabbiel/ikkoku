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
    let eyeBlend: any MTLRenderPipelineState
    /// ST-A11 source map surfaces (`MaterialKindMap`): the Standard baked-lightmap subset.
    let map: any MTLRenderPipelineState
    let mapBlend: any MTLRenderPipelineState
    /// ST-A11 slice 4: Custom/Silhouette's first pass (ColorMask 0, ZWrite On):
    /// `map_fragment` with no colour written, so the colour pass that follows
    /// runs the same functions and lands on the same depths.
    let mapDepthOnly: any MTLRenderPipelineState
    /// ST-A11 map sky (`MaterialKindSky`): Skybox/Cubemap on a mesh, no blending.
    let sky: any MTLRenderPipelineState
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
    /// ZTest LEqual in reverse Z (Custom/Silhouette's two passes).
    let depthWriteLEqual: any MTLDepthStencilState    // greaterEqual, write
    let depthTestLEqual: any MTLDepthStencilState     // greaterEqual, no write

    init(gpu: GPUContext, library: any MTLLibrary) throws {
        let device = gpu.device
        self.device = device
        self.library = library

        func fn(_ name: String) throws -> any MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw RendererError.missingFunction(name) }
            return f
        }
        func render(_ label: String, _ v: String, _ f: String?, color: MTLPixelFormat?, depth: MTLPixelFormat?, samples: Int,
                    blend: Blend = .none, configure: ((MTLRenderPipelineDescriptor) -> Void)? = nil) throws -> any MTLRenderPipelineState {
            try Pipelines.build(device: device, library: library, label, v, f, color: color, depth: depth, samples: samples, blend: blend, configure: configure)
        }

        let hdr = Pipelines.hdrFormat, ldr = Pipelines.ldrFormat, dep = Pipelines.depthFormat, ms = Pipelines.sampleCount

        deform = try device.makeComputePipelineState(function: fn("deform_vertices"))
        toonOpaque = try render("ToonOpaque", "toon_vertex", "toon_fragment", color: hdr, depth: dep, samples: ms)
        toonBlend = try render("ToonBlend", "toon_vertex", "toon_fragment", color: hdr, depth: dep, samples: ms, blend: .alpha)
        eye = try render("Eye", "toon_vertex", "eye_fragment", color: hdr, depth: dep, samples: ms)
        eyeBlend = try render("EyeBlend", "toon_vertex", "eye_fragment", color: hdr, depth: dep, samples: ms, blend: .alpha)
        map = try render("Map", "toon_vertex", "map_fragment", color: hdr, depth: dep, samples: ms)
        mapBlend = try render("MapBlend", "toon_vertex", "map_fragment", color: hdr, depth: dep, samples: ms, blend: .alpha)
        mapDepthOnly = try render("MapDepthOnly", "toon_vertex", "map_fragment", color: hdr, depth: dep, samples: ms,
                                  configure: Pipelines.noColorWrites)
        sky = try render("Sky", "sky_vertex", "sky_fragment", color: hdr, depth: dep, samples: ms)
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
        depthWriteLEqual = try depthState("DepthWriteLEqual", .greaterEqual, write: true)
        depthTestLEqual = try depthState("DepthTestLEqual", .greaterEqual, write: false)
    }

    /// A pipeline that writes depth only (ColorMask 0).
    static func noColorWrites(_ d: MTLRenderPipelineDescriptor) { d.colorAttachments[0].writeMask = [] }

    enum Blend { case none, alpha, additive }

    static func build(device: any MTLDevice, library: any MTLLibrary, _ label: String, _ v: String, _ f: String?, color: MTLPixelFormat?, depth: MTLPixelFormat?,
                      stencil: MTLPixelFormat? = nil, samples: Int, blend: Blend = .none,
                      configure: ((MTLRenderPipelineDescriptor) -> Void)? = nil) throws -> any MTLRenderPipelineState {
        func fn(_ name: String) throws -> any MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw RendererError.missingFunction(name) }
            return f
        }
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
        if let stencil { d.stencilAttachmentPixelFormat = stencil }
        configure?(d)
        return try device.makeRenderPipelineState(descriptor: d)
    }

    /// The main-pass pipelines. The live source-shader path needs a stencil
    /// buffer (the original hair-front and eye passes test and write stencil
    /// reference 2), so a frame with live draws renders its main pass into a
    /// depth+stencil target with these same shaders recompiled for that
    /// attachment; a frame without live draws keeps the depth-only set.
    struct MainPass {
        let background, grid, outline, toonOpaque, toonBlend, eye, eyeBlend, map, mapBlend, mapDepthOnly, sky, gizmoHDR: any MTLRenderPipelineState

        /// Every pipeline's label in field order, so tests can check that the
        /// depth-only and stencil variants carry the same groups.
        var labels: [String] {
            [background, grid, outline, toonOpaque, toonBlend, eye, eyeBlend, map, mapBlend, mapDepthOnly, sky, gizmoHDR].map { $0.label ?? "" }
        }
    }
    static let depthStencilFormat: MTLPixelFormat = .depth32Float_stencil8
    var depthOnlyMainPass: MainPass {
        MainPass(background: background, grid: grid, outline: outline, toonOpaque: toonOpaque, toonBlend: toonBlend,
                 eye: eye, eyeBlend: eyeBlend, map: map, mapBlend: mapBlend, mapDepthOnly: mapDepthOnly, sky: sky, gizmoHDR: gizmoHDR)
    }
    private let stencilLock = NSLock()
    private var stencilPass: MainPass?
    /// Built on first use (only when a frame has live source-shader draws).
    func stencilMainPass() throws -> MainPass {
        stencilLock.lock(); defer { stencilLock.unlock() }
        if let stencilPass { return stencilPass }
        let hdr = Pipelines.hdrFormat, ds = Pipelines.depthStencilFormat, ms = Pipelines.sampleCount
        func render(_ label: String, _ v: String, _ f: String, blend: Blend = .none,
                    configure: ((MTLRenderPipelineDescriptor) -> Void)? = nil) throws -> any MTLRenderPipelineState {
            try Pipelines.build(device: device, library: library, label + "Stencil", v, f, color: hdr, depth: ds, stencil: ds, samples: ms,
                                blend: blend, configure: configure)
        }
        let result = MainPass(
            background: try render("Background", "fullscreen_vertex", "background_fragment"),
            grid: try render("Grid", "grid_vertex", "grid_fragment", blend: .alpha),
            outline: try render("Outline", "outline_vertex", "outline_fragment"),
            toonOpaque: try render("ToonOpaque", "toon_vertex", "toon_fragment"),
            toonBlend: try render("ToonBlend", "toon_vertex", "toon_fragment", blend: .alpha),
            eye: try render("Eye", "toon_vertex", "eye_fragment"),
            eyeBlend: try render("EyeBlend", "toon_vertex", "eye_fragment", blend: .alpha),
            map: try render("Map", "toon_vertex", "map_fragment"),
            mapBlend: try render("MapBlend", "toon_vertex", "map_fragment", blend: .alpha),
            mapDepthOnly: try render("MapDepthOnly", "toon_vertex", "map_fragment", configure: Pipelines.noColorWrites),
            sky: try render("Sky", "sky_vertex", "sky_fragment"),
            gizmoHDR: try render("GizmoHDR", "gizmo_vertex", "gizmo_fragment", blend: .alpha))
        stencilPass = result
        return result
    }
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
