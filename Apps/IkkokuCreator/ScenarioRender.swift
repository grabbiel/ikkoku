import CoreGraphics

/// The pixel comparison behind the Studio and Maker scenarios'
/// `captureRender` and `assert render` steps. Both scenarios share it, so a
/// changed-pixel count means the same thing in every lane.
enum ScenarioRender {
    /// The single headless render size every `captureRender` uses, so a
    /// baseline and its comparison frame always share a resolution and the
    /// pixel counts mean the same thing across a scenario.
    static let side = 512

    /// Reads `image`'s RGBA8 pixels into a flat buffer, or nil when the
    /// bitmap context could not be built.
    static func bytes(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let read = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return read ? bytes : nil
    }

    /// Pixels that differ between two equal-size RGBA8 buffers, counting a
    /// pixel as changed when any of its four channels moves by more than 2.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> (changed: Int, exactChanged: Int, maximum: Int) {
        var count = 0, exactCount = 0, maximum = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            var delta = 0
            for channel in 0..<4 { delta = max(delta, abs(Int(a[i + channel]) - Int(b[i + channel]))) }
            if delta > 2 { count += 1 }
            if delta > 0 { exactCount += 1 }
            maximum = max(maximum, delta)
        }
        return (count, exactCount, maximum)
    }
}
