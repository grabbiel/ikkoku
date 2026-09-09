import Foundation
import Metal
import ShaderTypes

/// Size-dependent textures. One set per (width, height).
final class RenderTargets: @unchecked Sendable {
    let width: Int
    let height: Int
    let msaaColor: any MTLTexture
    let msaaDepth: any MTLTexture
    let hdr: any MTLTexture
    let ldr: any MTLTexture
    let overlayDepth: any MTLTexture
    let bloom: [any MTLTexture]
    let pick: any MTLTexture
    let pickDepth: any MTLTexture

    init(device: any MTLDevice, width: Int, height: Int) throws {
        self.width = width; self.height = height
        func tex(_ format: MTLPixelFormat, _ w: Int, _ h: Int, samples: Int = 1, usage: MTLTextureUsage, memoryless: Bool = false, label: String) throws -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.sampleCount = samples
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.usage = usage
            d.storageMode = memoryless ? .memoryless : .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.textureCreationFailed }
            t.label = label
            return t
        }
        let ms = Pipelines.sampleCount
        msaaColor = try tex(Pipelines.hdrFormat, width, height, samples: ms, usage: .renderTarget, memoryless: true, label: "MSAAColor")
        msaaDepth = try tex(Pipelines.depthFormat, width, height, samples: ms, usage: .renderTarget, memoryless: true, label: "MSAADepth")
        hdr = try tex(Pipelines.hdrFormat, width, height, usage: [.renderTarget, .shaderRead], label: "HDR")
        ldr = try tex(Pipelines.ldrFormat, width, height, usage: [.renderTarget, .shaderRead], label: "LDR")
        overlayDepth = try tex(Pipelines.depthFormat, width, height, usage: .renderTarget, memoryless: true, label: "OverlayDepth")
        var mips: [any MTLTexture] = []
        var w = width / 2, h = height / 2
        for i in 0..<5 {
            mips.append(try tex(Pipelines.hdrFormat, w, h, usage: [.renderTarget, .shaderRead], label: "Bloom\(i)"))
            w = max(w / 2, 1); h = max(h / 2, 1)
        }
        bloom = mips
        pick = try tex(Pipelines.pickFormat, width, height, usage: .renderTarget, label: "Pick")
        pickDepth = try tex(Pipelines.depthFormat, width, height, usage: .renderTarget, memoryless: true, label: "PickDepth")
    }
}
