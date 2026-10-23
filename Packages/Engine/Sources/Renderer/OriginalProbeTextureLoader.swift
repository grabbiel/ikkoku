import Foundation
import Metal

/// The probe exports sampled linear RGBA half floats to avoid quantizing dark
/// source textures to eight bits. Source pixels are bottom-up; Metal is top-down.
/// Authored mip levels are used when the decoder has verified the source base
/// against the original GPU capture. Generated mip levels remain a diagnostic
/// approximation, explicitly recorded by the comparison report.
func loadOriginalProbeTexture(url: URL, metadata: [String: Any], resources: ResourceStore) throws -> TextureHandle {
    if url.pathExtension == "png" { return try resources.texture(url: url, srgb: false) }
    guard url.pathExtension == "rgba16f", metadata["exportEncoding"] as? String == "linear-rgba16f-little-endian-bottom-up",
          let width = metadata["width"] as? Int, let height = metadata["height"] as? Int,
          let mipLevels = metadata["mipLevels"] as? Int,
          (1...4096).contains(width), (1...4096).contains(height),
          (1...(1 + Int(log2(Double(max(width, height)))))).contains(mipLevels) else { throw OriginalFrameProbe.ProbeError.invalid("Unknown original texture encoding or mip layout") }
    let authored = metadata["mipFiles"] as? [String]
    if let authored {
        guard authored.count == mipLevels, authored.first == url.lastPathComponent,
              authored.allSatisfy({ $0 == ($0 as NSString).lastPathComponent && !$0.hasPrefix(".") }) else { throw OriginalFrameProbe.ProbeError.invalid("Invalid authored mip paths") }
    }
    let key = url.path + "#original-linear-half-v3-mips\(mipLevels)-authored\(authored != nil)"
    if let cached = resources.lookup(key: key) { return cached }
    let levels = try (authored ?? [url.lastPathComponent]).map {
        try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent($0))
    }
    return try uploadOriginalProbeTexture(levels: levels, width: width, height: height, mipLevels: mipLevels,
                                          generateMips: authored == nil, cacheKey: key, resources: resources)
}

/// Uploads exactly the supplied buffers. Native stores hash these same bytes
/// before calling, and use a content key covering dimensions and every mip.
/// No files are reopened between verification and upload.
func uploadOriginalProbeTexture(levels: [Data], width: Int, height: Int, mipLevels: Int,
                                generateMips: Bool, cacheKey: String, resources: ResourceStore) throws -> TextureHandle {
    guard (1...4096).contains(width), (1...4096).contains(height),
          (1...(1 + Int(log2(Double(max(width, height)))))).contains(mipLevels),
          levels.count == (generateMips ? 1 : mipLevels) else { throw OriginalFrameProbe.ProbeError.invalid("Unknown original texture mip layout") }
    for (level, data) in levels.enumerated() {
        guard data.count == max(1, width >> level) * max(1, height >> level) * 8 else {
            throw OriginalFrameProbe.ProbeError.invalid("Original half-float texture dimensions")
        }
    }
    if let cached = resources.lookup(key: cacheKey) { return cached }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: mipLevels > 1)
    descriptor.mipmapLevelCount = mipLevels; descriptor.usage = .shaderRead; descriptor.storageMode = .shared
    guard let texture = resources.device.makeTexture(descriptor: descriptor) else { throw OriginalFrameProbe.ProbeError.gpu("Original half-float texture") }
    for (level, data) in levels.enumerated() {
        let w = max(1, width >> level), h = max(1, height >> level), stride = w * 8
        var upright = Data(count: data.count)
        data.withUnsafeBytes { source in upright.withUnsafeMutableBytes { destination in
            for y in 0..<h { destination.baseAddress!.advanced(by: y * stride).copyMemory(from: source.baseAddress!.advanced(by: (h - 1 - y) * stride), byteCount: stride) }
        } }
        upright.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level, withBytes: $0.baseAddress!, bytesPerRow: stride) }
    }
    if mipLevels > 1, generateMips {
        guard let queue = resources.device.makeCommandQueue(), let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { throw OriginalFrameProbe.ProbeError.gpu("Original half-float mip generation") }
        blit.generateMipmaps(for: texture); blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw OriginalFrameProbe.ProbeError.gpu(error.localizedDescription) }
    }
    return resources.register(texture: texture, key: cacheKey)
}
