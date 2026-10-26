import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Metal

/// Bounds how many texture loads hold decoded pixels and a staging buffer at
/// once. Unbounded, every load in flight leaves its freed decode buffer in
/// malloc's cache for reuse: 4 MB after one 1024² load, 32 MB after 8 at
/// once, 116–128 MB after 64, with 256 MB of staging at that peak. MetalKit
/// allowed three loads per loader.
///
/// The invariant: a holder makes progress without any pool thread. It
/// decodes and stages on its own thread and waits only for its own command
/// buffer, which the GPU completes. So a caller waiting for a permit always
/// gets one, however many cooperative threads are blocked
/// (`docs/reference/performance.md`, the pool rule).
///
/// The main thread never waits for a permit: a load from it runs at once,
/// as one holder over the limit, so it cannot stall behind other loads.
final class UploadPermits: @unchecked Sendable {
    static let limit = 8
    static let shared = UploadPermits(limit: limit)

    /// What the permits saw since the last reset (tests and measurements).
    struct Stats: Equatable {
        /// The most permits held at once.
        var mostHolders = 0
        /// The longest a caller waited for a permit, in seconds.
        var longestWait = 0.0
        /// Loads from the main thread, which take no permit.
        var mainThreadLoads = 0
    }

    private let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var holders = 0
    private var stats = Stats()

    init(limit: Int) { semaphore = DispatchSemaphore(value: limit) }

    /// Runs `body` holding a permit, or at once without one on the main thread.
    func withPermit<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            lock.lock(); stats.mainThreadLoads += 1; lock.unlock()
            return try body()
        }
        acquire()
        defer { release() }
        return try body()
    }

    func acquire() {
        let start = DispatchTime.now().uptimeNanoseconds
        semaphore.wait()
        let waited = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        lock.lock()
        holders += 1
        stats.mostHolders = max(stats.mostHolders, holders)
        stats.longestWait = max(stats.longestWait, waited)
        lock.unlock()
    }

    func release() {
        lock.lock(); holders -= 1; lock.unlock()
        semaphore.signal()
    }

    /// The statistics since the last reset, then a reset.
    func resetStats() -> Stats {
        lock.lock()
        defer { stats = Stats(mostHolders: holders); lock.unlock() }
        return stats
    }
}

/// Creates shader-read textures from images on the calling thread.
///
/// `MTKTextureLoader`'s synchronous calls hand the decode and upload to
/// MetalKit's own concurrent queues and block the caller until they finish.
/// Those queues run on GCD's constrained default-QoS pool. When every Swift
/// cooperative thread is blocked, the kernel grants that pool no thread, so a
/// cooperative caller waits forever (`docs/performance.md`, the pool rule).
/// This loader decodes, stages and blits on the caller's thread and waits only
/// on its own command buffer, so it needs no worker thread from any pool.
///
/// It reproduces MetalKit's results exactly: pixel format, size, mip count,
/// usage, storage mode and every texel of every level
/// (`InlineTextureLoaderIdentityTests`). MetalKit treats two kinds of image
/// differently:
/// - Images ImageIO decoded from a file (`Source.imageIO`): the `srgb` flag
///   picks the sRGB variant of 8-bit formats, 8-bit colour becomes BGRA
///   (premultiplied colour is unpremultiplied; HEIF and JPEG XL straight
///   colour is premultiplied, `Source.premultipliesStraightAlpha`),
///   and 16-bit and float colour gain an alpha channel when they have none.
/// - Other images (`Source.data`): the bytes are uploaded as they are, 8-bit
///   grey as R8 and any 32-bit pixel as RGBA8 or BGRA8 by where its alpha
///   sits; the `srgb` flag is ignored. Every other layout is rejected, as
///   MetalKit rejects it.
/// `ResourceStore` knows which kind it has: it decodes files and data itself.
/// GPU texture containers (KTX, KTX2, PVR, ASTC, DDS, ATX) are not images:
/// MetalKit parses some of them itself, and its ImageIO result for an
/// uncompressed DDS changes from call to call, so `ResourceStore` rejects
/// them by name (`container(of:)`, `container(ofType:)`).
enum InlineTextureLoader {
    enum Failure: Error, CustomStringConvertible {
        case unsupportedLayout(String)
        case decode(String)
        case gpu(String)

        var description: String {
            switch self {
            case .unsupportedLayout(let layout): return "Unsupported image layout for a texture: \(layout)"
            case .decode(let what): return "Image decode failed: \(what)"
            case .gpu(let what): return "Texture upload failed: \(what)"
            }
        }
    }

    enum Conversion: Equatable {
        /// Source pixels as they are.
        case copy
        /// RGBA8 or RGBX8 to BGRA8.
        case swapRedBlue
        /// Premultiplied RGBA8 to straight BGRA8.
        case unpremultiplySwapRedBlue
        /// Straight RGBA8 to premultiplied BGRA8 (the HEIF decoder's own layout).
        case premultiplySwapRedBlue
        /// Three 16-bit channels gain a fourth holding these two bytes.
        case appendAlpha16(UInt8, UInt8)
        /// Three 32-bit float channels gain an alpha of 1.
        case appendAlphaFloat32
    }

    struct Layout: Equatable {
        let pixelFormat: MTLPixelFormat
        let bytesPerPixel: Int
        let conversion: Conversion
    }

    /// Where an image's pixels come from, which decides MetalKit's handling.
    enum Source: Equatable {
        /// A data provider: CGContext, Core Image or hand-built images.
        case data
        /// ImageIO decoded the image from an encoded file of this type.
        /// MetalKit asks ImageIO for BGRA pixels; the HEIF family and JPEG XL
        /// answer with premultiplied pixels whatever the image declares.
        case imageIO(type: String)

        /// Measured per decoder on straight-alpha RGBA8 files: HEIC, HEICS,
        /// HEIF, AVIF, AVIF sequences and JPEG XL premultiply; PNG, TIFF,
        /// BMP, TGA, ICO, ICNS, PSD, SGI, GIF, PICT and WebP do not. AVCI
        /// (no encoder to measure with) shares the HEIF decoder.
        static let premultiplyingTypes: Set<String> = ["public.heic", "public.heics", "public.heif", "public.avci",
                                                       "public.avif", "public.avis", "public.jpeg-xl"]

        var premultipliesStraightAlpha: Bool {
            guard case .imageIO(let type) = self else { return false }
            return Self.premultiplyingTypes.contains(type)
        }
    }

    /// An image together with how it was made.
    struct Image {
        let cgImage: CGImage
        let source: Source
    }

    /// The source of an image a caller hands in. ImageIO sets `utType` on the
    /// images it decodes, and a copy keeps it. A crop of a decoded image loses
    /// it although ImageIO still provides the pixels; such an image is taken
    /// as a data image here and can differ from MetalKit (no caller makes one).
    static func source(of image: CGImage) -> Source {
        guard let type = image.utType as String? else { return .data }
        return .imageIO(type: type)
    }

    /// MetalKit's choice for `image`, or nil where MetalKit fails.
    static func layout(for image: Image, srgb: Bool) -> Layout? {
        layout(for: image.cgImage, srgb: srgb, source: image.source)
    }

    static func layout(for image: CGImage, srgb: Bool, source: Source) -> Layout? {
        let bpc = image.bitsPerComponent, bpp = image.bitsPerPixel
        let alpha = image.alphaInfo
        let float = image.bitmapInfo.contains(.floatComponents)
        let order = CGBitmapInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue)
        let alphaLast: Set<CGImageAlphaInfo> = [.premultipliedLast, .last, .noneSkipLast]
        let alphaFirst: Set<CGImageAlphaInfo> = [.premultipliedFirst, .first, .noneSkipFirst]
        guard image.colorSpace?.model != .indexed else { return nil }
        let premultiplies = source.premultipliesStraightAlpha
        guard case .imageIO = source else {
            if bpp == 8 && bpc == 8 && alpha == .none { return Layout(pixelFormat: .r8Unorm, bytesPerPixel: 1, conversion: .copy) }
            if bpp == 32 && alphaLast.contains(alpha) { return Layout(pixelFormat: .rgba8Unorm, bytesPerPixel: 4, conversion: .copy) }
            if bpp == 32 && alphaFirst.contains(alpha) { return Layout(pixelFormat: .bgra8Unorm, bytesPerPixel: 4, conversion: .copy) }
            return nil
        }
        switch (bpc, float) {
        case (8, false):
            // 32-bit big-endian words hold the same bytes as the default order.
            guard order == [] || order == .byteOrder32Big else { return nil }
            switch (bpp, alpha) {
            case (8, .none): return Layout(pixelFormat: srgb ? .r8Unorm_srgb : .r8Unorm, bytesPerPixel: 1, conversion: .copy)
            case (16, .last), (16, .premultipliedLast):
                return Layout(pixelFormat: srgb ? .rg8Unorm_srgb : .rg8Unorm, bytesPerPixel: 2, conversion: .copy)
            case (32, .last):
                return Layout(pixelFormat: srgb ? .bgra8Unorm_srgb : .bgra8Unorm, bytesPerPixel: 4, conversion: premultiplies ? .premultiplySwapRedBlue : .swapRedBlue)
            case (32, .noneSkipLast):
                return Layout(pixelFormat: srgb ? .bgra8Unorm_srgb : .bgra8Unorm, bytesPerPixel: 4, conversion: .swapRedBlue)
            case (32, .premultipliedLast):
                return Layout(pixelFormat: srgb ? .bgra8Unorm_srgb : .bgra8Unorm, bytesPerPixel: 4, conversion: .unpremultiplySwapRedBlue)
            default: return nil
            }
        case (16, _):
            guard order == .byteOrder16Little else { return nil }
            let lastOrNone: Set<CGImageAlphaInfo> = [.none, .last, .premultipliedLast, .noneSkipLast]
            guard lastOrNone.contains(alpha) else { return nil }
            switch (bpp, alpha) {
            case (16, .none): return Layout(pixelFormat: float ? .r16Float : .r16Unorm, bytesPerPixel: 2, conversion: .copy)
            case (32, .last), (32, .premultipliedLast): return Layout(pixelFormat: float ? .rg16Float : .rg16Unorm, bytesPerPixel: 4, conversion: .copy)
            case (48, .none):
                return Layout(pixelFormat: float ? .rgba16Float : .rgba16Unorm, bytesPerPixel: 8,
                              conversion: float ? .appendAlpha16(0x01, 0x00) : .appendAlpha16(0xFF, 0xFF))
            case (64, .last), (64, .premultipliedLast), (64, .noneSkipLast):
                return Layout(pixelFormat: float ? .rgba16Float : .rgba16Unorm, bytesPerPixel: 8, conversion: .copy)
            default: return nil
            }
        case (32, true):
            guard order == .byteOrder32Little else { return nil }
            switch (bpp, alpha) {
            case (32, .none): return Layout(pixelFormat: .r32Float, bytesPerPixel: 4, conversion: .copy)
            case (64, .last), (64, .premultipliedLast): return Layout(pixelFormat: .rg32Float, bytesPerPixel: 8, conversion: .copy)
            case (96, .none): return Layout(pixelFormat: .rgba32Float, bytesPerPixel: 16, conversion: .appendAlphaFloat32)
            case (128, .last), (128, .premultipliedLast): return Layout(pixelFormat: .rgba32Float, bytesPerPixel: 16, conversion: .copy)
            default: return nil
            }
        default: return nil
        }
    }

    static func describe(_ image: CGImage) -> String {
        let order = (image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue) >> 12
        return "\(image.width)x\(image.height) bpc \(image.bitsPerComponent) bpp \(image.bitsPerPixel) alpha \(image.alphaInfo.rawValue) "
            + "order \(order) float \(image.bitmapInfo.contains(.floatComponents)) colour model \(image.colorSpace?.model.rawValue ?? -1) "
            + "type \(image.utType as String? ?? "none")"
    }

    /// Full mip chain, as MetalKit allocates with `.generateMipmaps`.
    static func mipLevelCount(width: Int, height: Int) -> Int {
        var levels = 1, size = max(width, height)
        while size > 1 { size >>= 1; levels += 1 }
        return levels
    }

    /// Decodes `image` into a staging buffer in the texture's layout.
    static func stage(_ image: CGImage, layout: Layout, device: any MTLDevice) throws -> any MTLBuffer {
        let width = image.width, height = image.height
        let rowBytes = width * layout.bytesPerPixel
        guard let data = image.dataProvider?.data, let source = CFDataGetBytePtr(data) else {
            throw Failure.decode(describe(image))
        }
        let sourceRow = image.bytesPerRow, sourcePixel = image.bitsPerPixel / 8
        guard CFDataGetLength(data) >= sourceRow * (height - 1) + width * sourcePixel else { throw Failure.decode(describe(image)) }
        guard let staging = device.makeBuffer(length: rowBytes * height, options: [.storageModeShared, .cpuCacheModeWriteCombined]) else {
            throw Failure.gpu("staging buffer of \(rowBytes * height) bytes")
        }
        let target = staging.contents()
        switch layout.conversion {
        case .copy:
            if sourceRow == rowBytes { target.copyMemory(from: source, byteCount: rowBytes * height) }
            else { for y in 0..<height { (target + y * rowBytes).copyMemory(from: source + y * sourceRow, byteCount: rowBytes) } }
        case .swapRedBlue:
            var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: vImagePixelCount(height),
                                     width: vImagePixelCount(width), rowBytes: sourceRow)
            var to = vImage_Buffer(data: target, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
            let map: [UInt8] = [2, 1, 0, 3]
            guard vImagePermuteChannels_ARGB8888(&from, &to, map, vImage_Flags(kvImageDoNotTile)) == kvImageNoError else {
                throw Failure.decode("channel order of \(describe(image))")
            }
        case .unpremultiplySwapRedBlue:
            for y in 0..<height {
                let s = source + y * sourceRow, t = (target + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let o = x * 4, a = Int(s[o + 3])
                    func straight(_ c: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (Int(c) * 255 + a / 2) / a)) }
                    t[o] = straight(s[o + 2]); t[o + 1] = straight(s[o + 1]); t[o + 2] = straight(s[o]); t[o + 3] = UInt8(a)
                }
            }
        case .premultiplySwapRedBlue:
            for y in 0..<height {
                let s = source + y * sourceRow, t = (target + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let o = x * 4, a = Int(s[o + 3])
                    func premultiplied(_ c: UInt8) -> UInt8 { UInt8((Int(c) * a + 127) / 255) }
                    t[o] = premultiplied(s[o + 2]); t[o + 1] = premultiplied(s[o + 1]); t[o + 2] = premultiplied(s[o]); t[o + 3] = UInt8(a)
                }
            }
        case .appendAlpha16(let low, let high):
            for y in 0..<height {
                let s = source + y * sourceRow, t = (target + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    for k in 0..<6 { t[x * 8 + k] = s[x * 6 + k] }
                    t[x * 8 + 6] = low; t[x * 8 + 7] = high
                }
            }
        case .appendAlphaFloat32:
            let one = Float(1).bitPattern.littleEndian
            for y in 0..<height {
                let s = UnsafeRawPointer(source + y * sourceRow), t = target + y * rowBytes
                for x in 0..<width {
                    (t + x * 16).copyMemory(from: s + x * 12, byteCount: 12)
                    (t + x * 16 + 12).storeBytes(of: one, as: UInt32.self)
                }
            }
        }
        return staging
    }

    /// The texture MetalKit's `newTexture(cgImage:options:)` makes with
    /// `.generateMipmaps`, `.shaderRead` usage and `.private` storage.
    /// Returns only after the upload's command buffer has completed, so no
    /// caller ever holds a texture the GPU is still writing. `didComplete`
    /// sees that command buffer as the texture is handed out (tests only).
    static func texture(_ source: Image, srgb: Bool, device: any MTLDevice, queue: any MTLCommandQueue,
                        didComplete: ((any MTLCommandBuffer) -> Void)? = nil) throws -> any MTLTexture {
        let image = source.cgImage
        guard let layout = layout(for: source, srgb: srgb) else {
            throw Failure.unsupportedLayout(describe(image))
        }
        let width = image.width, height = image.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: layout.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.mipmapLevelCount = mipLevelCount(width: width, height: height)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.gpu("texture \(describe(image))") }
        // The staging buffer lives only until the copy has completed. At most
        // `UploadPermits.limit` loads hold decoded pixels and staging at once,
        // plus one from the main thread, which never waits for a permit.
        try UploadPermits.shared.withPermit { try autoreleasepool {
            let staging = try stage(image, layout: layout, device: device)
            guard let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
                throw Failure.gpu("command buffer for \(describe(image))")
            }
            let rowBytes = width * layout.bytesPerPixel
            blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * height,
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture, destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            if texture.mipmapLevelCount > 1 { blit.generateMipmaps(for: texture) }
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            if command.status != .completed {
                throw Failure.gpu("\(describe(image)): \(command.error.map { "\($0)" } ?? "status \(command.status.rawValue)")")
            }
            didComplete?(command)
        } }
        return texture
    }

    /// The first image of an encoded file or buffer, decoded by ImageIO the
    /// way `ResourceStore.texture(data:)` always has.
    static func image(data: Data) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Image(cgImage: image, source: .imageIO(type: type))
    }

    /// A GPU texture container, by its magic bytes. `ResourceStore` rejects
    /// containers on every entry point; nothing in the repository loads one.
    static func container(of data: Data) -> String? {
        let head = [UInt8](data.prefix(64))
        func bytes(_ offset: Int, _ expected: [UInt8]) -> Bool {
            head.count >= offset + expected.count && Array(head[offset..<(offset + expected.count)]) == expected
        }
        let ktx: [UInt8] = [0xAB, 0x4B, 0x54, 0x58, 0x20]
        if bytes(0, ktx + [0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]) { return "KTX" }
        if bytes(0, ktx + [0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]) { return "KTX2" }
        if bytes(0, [0x50, 0x56, 0x52, 0x03]) || bytes(44, [0x50, 0x56, 0x52, 0x21]) { return "PVR" }
        if bytes(0, [0x13, 0xAB, 0xA1, 0x5C]) { return "ASTC" }
        if bytes(0, [0x44, 0x44, 0x53, 0x20]) { return "DDS" }
        return nil
    }

    /// The container an ImageIO type names, for images decoded elsewhere.
    static func container(ofType type: String) -> String? {
        switch type {
        case "org.khronos.ktx": return "KTX"
        case "org.khronos.ktx2": return "KTX2"
        case "public.pvr": return "PVR"
        case "org.khronos.astc": return "ASTC"
        case "com.microsoft.dds": return "DDS"
        case "com.apple.atx": return "ATX"
        default: return nil
        }
    }
}
