import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import MetalKit
import Testing
import UniformTypeIdentifiers
@testable import Renderer

// `InlineTextureLoader` replaces MetalKit's synchronous loads in
// `ResourceStore` and must give the same textures: same descriptor, same
// texels at every level, and failure for the same inputs. MetalKit is only
// called here, on a thread of its own: its synchronous calls wait on worker
// queues that a saturated cooperative pool can starve.

/// A MetalKit or in-line result reduced to what the comparison needs.
struct TextureIdentityRecord: Equatable, CustomStringConvertible {
    let descriptor: String
    let levels: [Data]

    var description: String { "\(descriptor) levels \(levels.map(\.count))" }

    static func failed(_ error: any Error) -> TextureIdentityRecord { .init(descriptor: "failed", levels: []) }

    init(descriptor: String, levels: [Data]) { self.descriptor = descriptor; self.levels = levels }

    init(_ texture: any MTLTexture, device: any MTLDevice, queue: any MTLCommandQueue) throws {
        let swizzle = texture.swizzle
        descriptor = "format \(texture.pixelFormat.rawValue) type \(texture.textureType.rawValue) \(texture.width)x\(texture.height)x\(texture.depth) "
            + "mips \(texture.mipmapLevelCount) array \(texture.arrayLength) samples \(texture.sampleCount) usage \(texture.usage.rawValue) "
            + "storage \(texture.storageMode.rawValue) cache \(texture.cpuCacheMode.rawValue) hazard \(texture.hazardTrackingMode.rawValue) "
            + "options \(texture.resourceOptions.rawValue) gpuOptimized \(texture.allowGPUOptimizedContents) compression \(texture.compressionType.rawValue) "
            + "framebufferOnly \(texture.isFramebufferOnly) swizzle \(swizzle.red.rawValue)\(swizzle.green.rawValue)\(swizzle.blue.rawValue)\(swizzle.alpha.rawValue)"
        let bytesPerPixel = try #require(Self.bytesPerPixel[texture.pixelFormat], "no readback size for format \(texture.pixelFormat.rawValue)")
        var levels: [Data] = []
        for level in 0..<texture.mipmapLevelCount {
            let width = max(1, texture.width >> level), height = max(1, texture.height >> level)
            let length = width * height * bytesPerPixel
            let buffer = try #require(device.makeBuffer(length: length, options: .storageModeShared))
            let command = try #require(queue.makeCommandBuffer()), blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                      destinationBytesPerRow: width * bytesPerPixel, destinationBytesPerImage: length)
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            levels.append(Data(bytes: buffer.contents(), count: length))
        }
        self.levels = levels
    }

    static let bytesPerPixel: [MTLPixelFormat: Int] = [
        .r8Unorm: 1, .r8Unorm_srgb: 1, .rg8Unorm: 2, .rg8Unorm_srgb: 2, .r16Unorm: 2, .r16Float: 2,
        .rgba8Unorm: 4, .rgba8Unorm_srgb: 4, .bgra8Unorm: 4, .bgra8Unorm_srgb: 4, .rg16Unorm: 4, .rg16Float: 4, .r32Float: 4,
        .rgba16Unorm: 8, .rgba16Float: 8, .rg32Float: 8, .rgba32Float: 16,
    ]
}

/// Runs `body` on a thread of its own; the calling task suspends meanwhile.
func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: body()) }
        thread.stackSize = 8 << 20
        thread.start()
    }
}

/// MetalKit's and the in-line loader's results for each case.
struct TextureIdentityComparison: Sendable {
    struct Mismatch: CustomStringConvertible {
        let name: String, metalKit: String, inline: String, detail: String
        var description: String { "\(name): MetalKit \(metalKit) | in-line \(inline) | \(detail)" }
    }

    static func options(_ srgb: Bool) -> [MTKTextureLoader.Option: Any] {
        [.SRGB: srgb, .generateMipmaps: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
         .textureStorageMode: MTLStorageMode.private.rawValue]
    }

    /// Compares one image (or file) both ways; nil when they agree.
    static func compare(name: String, image: InlineTextureLoader.Image?, url: URL?, srgb: Bool, device: any MTLDevice,
                        loader: MTKTextureLoader, queue: any MTLCommandQueue) -> Mismatch? {
        func record(_ make: () throws -> any MTLTexture) -> TextureIdentityRecord {
            do { return try TextureIdentityRecord(try make(), device: device, queue: queue) } catch { return .failed(error) }
        }
        let metalKit = record {
            if let url { return try loader.newTexture(URL: url, options: options(srgb)) }
            return try loader.newTexture(cgImage: image!.cgImage, options: options(srgb))
        }
        let inline = record {
            if let url {
                guard let decoded = InlineTextureLoader.image(data: try Data(contentsOf: url)) else { throw InlineTextureLoader.Failure.decode(url.lastPathComponent) }
                return try InlineTextureLoader.texture(decoded, srgb: srgb, device: device, queue: queue)
            }
            return try InlineTextureLoader.texture(image!, srgb: srgb, device: device, queue: queue)
        }
        if metalKit == inline { return nil }
        var detail = metalKit.descriptor == inline.descriptor ? "same descriptor" : "descriptor differs"
        if metalKit.levels.count == inline.levels.count {
            for (level, (a, b)) in zip(metalKit.levels, inline.levels).enumerated() where a != b {
                let first = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
                let count = zip(a, b).filter { $0 != $1 }.count + abs(a.count - b.count)
                let largest = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
                detail += "; level \(level): \(count) of \(a.count) bytes differ, first at \(first), largest byte difference \(largest)"
                break
            }
        }
        return Mismatch(name: name, metalKit: metalKit.description, inline: inline.description, detail: detail)
    }
}

/// Synthetic images covering every layout MetalKit could be handed.
enum TextureIdentityCases {
    static let alphas: [CGImageAlphaInfo] = [.none, .premultipliedLast, .premultipliedFirst, .last, .first, .noneSkipLast, .noneSkipFirst]
    static let orders: [CGBitmapInfo] = [[], .byteOrder16Little, .byteOrder32Little, .byteOrder16Big, .byteOrder32Big]

    static func plain(bpc: Int, components: Int, alpha: CGImageAlphaInfo, order: CGBitmapInfo, float: Bool,
                      width: Int, height: Int, space: CGColorSpace? = nil) -> CGImage? {
        let colourSpace = space ?? (components <= 2 ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)! : CGColorSpace(name: CGColorSpace.sRGB)!)
        let rowBytes = width * bpc * components / 8 + 3 // padded rows
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: (i &* 37) &+ (i >> 5) &+ 11) }
        if float {
            bytes.withUnsafeMutableBytes { raw in
                for y in 0..<height {
                    let row = raw.baseAddress! + y * rowBytes
                    for i in 0..<(width * components) {
                        let v = Float((i + y * 7) % 97) / 96
                        if bpc == 32 { (row + i * 4).storeBytes(of: v.bitPattern, as: UInt32.self) }
                        else { (row + i * 2).storeBytes(of: Float16(v).bitPattern, as: UInt16.self) }
                    }
                }
            }
        }
        var info = alpha.rawValue | order.rawValue
        if float { info |= CGBitmapInfo.floatComponents.rawValue }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: bpc, bitsPerPixel: bpc * components, bytesPerRow: rowBytes,
                       space: colourSpace, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    static func encode(_ image: CGImage, as type: String) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }

    /// Every encoder ImageIO offers that the decoder reads back.
    static let encodedTypes: [String] = ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.microsoft.bmp", "com.compuserve.gif",
                                         "com.microsoft.ico", "com.truevision.tga-image", "public.jpeg-2000", "com.ilm.openexr-image",
                                         "org.khronos.ktx", "org.khronos.astc", "public.heics", "org.webmproject.webp",
                                         "public.heif", "public.avif", "public.avci", "public.jpeg-xl"]

    /// (name, image, encoded data if any). Deduplicated by layout and source.
    /// Decoded images carry their source structurally, as `ResourceStore`
    /// passes it; handed-in images are classified by `utType`.
    static func all() -> [(name: String, image: InlineTextureLoader.Image, encoded: Data?)] {
        var out: [(String, InlineTextureLoader.Image, Data?)] = []
        var seen = Set<String>()
        func add(_ kind: String, _ image: InlineTextureLoader.Image, _ data: Data?) {
            let key = "\(kind) \(InlineTextureLoader.describe(image.cgImage))"
            if seen.insert(key).inserted { out.append((key, image, data)) }
        }
        func add(_ kind: String, _ image: CGImage, _ data: Data?) {
            add(kind, InlineTextureLoader.Image(cgImage: image, source: InlineTextureLoader.source(of: image)), data)
        }
        for (width, height) in [(37, 23), (1, 1), (1, 9), (64, 64)] {
            for bpc in [8, 16, 32] { for components in [1, 2, 3, 4] { for alpha in alphas { for order in orders { for float in [false, true] {
                if float && bpc == 8 { continue }
                guard let image = plain(bpc: bpc, components: components, alpha: alpha, order: order, float: float, width: width, height: height) else { continue }
                add("plain", image, nil)
                for type in encodedTypes {
                    guard let data = encode(image, as: type), InlineTextureLoader.container(of: data) == nil,
                          let decoded = InlineTextureLoader.image(data: data) else { continue }
                    add(type, decoded, data)
                }
            } } } } }
        }
        // Colour spaces MetalKit must not convert from.
        for name in [CGColorSpace.displayP3, CGColorSpace.linearSRGB, CGColorSpace.adobeRGB1998, CGColorSpace.genericRGBLinear, CGColorSpace.itur_2020] {
            guard let space = CGColorSpace(name: name),
                  let image = plain(bpc: 8, components: 4, alpha: .last, order: [], float: false, width: 37, height: 23, space: space) else { continue }
            add("plain \(name)", image, nil)
            if let data = encode(image, as: "public.png"), let decoded = InlineTextureLoader.image(data: data) { add("public.png \(name)", decoded, data) }
        }
        // Indexed and low bit depth images.
        var table = [UInt8](); for i in 0..<16 { table += [UInt8(i * 16), UInt8(255 - i * 16), UInt8(i * 7)] }
        if let space = CGColorSpace(indexedBaseSpace: CGColorSpace(name: CGColorSpace.sRGB)!, last: 15, colorTable: table),
           let indexed = CGImage(width: 37, height: 23, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 37, space: space, bitmapInfo: [],
                                 provider: CGDataProvider(data: Data((0..<(37 * 23)).map { UInt8($0 % 16) }) as CFData)!, decode: nil,
                                 shouldInterpolate: false, intent: .defaultIntent) {
            add("plain indexed", indexed, nil)
            for type in ["public.png", "com.compuserve.gif", "public.tiff"] {
                if let data = encode(indexed, as: type), let decoded = InlineTextureLoader.image(data: data) { add("\(type) indexed", decoded, data) }
            }
        }
        for bpc in [1, 2, 4] {
            let rowBytes = (37 * bpc + 7) / 8
            if let gray = CGImage(width: 37, height: 23, bitsPerComponent: bpc, bitsPerPixel: bpc, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: [], provider: CGDataProvider(data: Data((0..<(rowBytes * 23)).map { UInt8(truncatingIfNeeded: $0 &* 29) }) as CFData)!,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                add("plain gray\(bpc)", gray, nil)
                if let data = encode(gray, as: "public.png"), let decoded = InlineTextureLoader.image(data: data) { add("public.png gray\(bpc)", decoded, data) }
            }
        }
        // Images derived from decoded ones, and CGContext and Core Image output.
        if let base = plain(bpc: 8, components: 4, alpha: .last, order: [], float: false, width: 37, height: 23),
           let data = encode(base, as: "public.png"), let decoded = InlineTextureLoader.image(data: data) {
            if let copy = decoded.cgImage.copy() { add("copy of png", copy, nil) }
            if let recoloured = decoded.cgImage.copy(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!) { add("colour-space copy of png", recoloured, nil) }
            let context = CIContext(options: [.useSoftwareRenderer: false])
            if let ci = context.createCGImage(CIImage(cgImage: decoded.cgImage), from: CGRect(x: 0, y: 0, width: 37, height: 23)) { add("core image", ci, nil) }
        }
        for (alpha, order) in [(CGImageAlphaInfo.premultipliedLast, CGBitmapInfo()), (.premultipliedFirst, .byteOrder32Little), (.noneSkipLast, [])] {
            guard let context = CGContext(data: nil, width: 37, height: 23, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue | order.rawValue) else { continue }
            context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 0.7); context.fill(CGRect(x: 0, y: 0, width: 20, height: 23))
            if let image = context.makeImage() { add("cgcontext", image, nil) }
        }
        return out
    }
}

@Suite struct InlineTextureLoaderIdentityTests {
    @Test("In-line loads match MetalKit for every image layout, both colour flags, at every level")
    func inlineTextureLoaderMatchesMetalKitForEveryLayout() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cases = TextureIdentityCases.all()
        let result = await onOwnThread { () -> (compared: Int, mismatches: [String], failedBoth: Int) in
            let loader = MTKTextureLoader(device: device), queue = device.makeCommandQueue()!
            var mismatches: [String] = [], compared = 0, failedBoth = 0
            for (name, image, _) in cases { for srgb in [true, false] {
                compared += 1
                if let mismatch = TextureIdentityComparison.compare(name: "\(name) srgb \(srgb)", image: image, url: nil, srgb: srgb,
                                                                    device: device, loader: loader, queue: queue) {
                    mismatches.append(mismatch.description)
                }
                if InlineTextureLoader.layout(for: image, srgb: srgb) == nil { failedBoth += 1 }
            } }
            return (compared, mismatches, failedBoth)
        }
        if let path = ProcessInfo.processInfo.environment["IKKOKU_TEXTURE_IDENTITY_REPORT"] {
            try ((["cases \(result.compared), rejected by both \(result.failedBoth), mismatches \(result.mismatches.count)"] + result.mismatches)
                .joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(result.compared > 200)
        #expect(result.mismatches.isEmpty, "\(result.mismatches.count) of \(result.compared) cases differ:\n\(result.mismatches.prefix(20).joined(separator: "\n"))")
    }

    @Test("In-line file loads match MetalKit's URL loads for every encoded layout")
    func inlineTextureLoaderMatchesMetalKitForFiles() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-inline-texture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var files: [(String, URL)] = []
        for (index, entry) in TextureIdentityCases.all().enumerated() {
            guard let data = entry.encoded else { continue }
            let ext = UTType(entry.name.components(separatedBy: " ")[0])?.preferredFilenameExtension ?? "img"
            let url = directory.appendingPathComponent("case-\(index).\(ext)")
            try data.write(to: url)
            files.append((entry.name, url))
        }
        let snapshot = files
        let mismatches = await onOwnThread { () -> [String] in
            let loader = MTKTextureLoader(device: device), queue = device.makeCommandQueue()!
            return snapshot.flatMap { name, url in
                [true, false].compactMap { srgb in
                    TextureIdentityComparison.compare(name: "file \(name) srgb \(srgb)", image: nil, url: url, srgb: srgb,
                                                      device: device, loader: loader, queue: queue)?.description
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["IKKOKU_TEXTURE_IDENTITY_FILE_REPORT"] {
            try ((["files \(files.count), mismatches \(mismatches.count)"] + mismatches).joined(separator: "\n") + "\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(files.count > 20)
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(files.count * 2) files differ:\n\(mismatches.prefix(20).joined(separator: "\n"))")
    }

    @Test("A crop of a decoded image counts as a data image: the documented limit of texture(cgImage:)")
    func croppedDecodedImageIsADataImage() throws {
        let base = try #require(TextureIdentityCases.plain(bpc: 8, components: 4, alpha: .last, order: [], float: false, width: 37, height: 23))
        let encoded = try #require(TextureIdentityCases.encode(base, as: "public.png"))
        let decoded = try #require(InlineTextureLoader.image(data: encoded))
        #expect(decoded.source == .imageIO(type: "public.png"))
        #expect(InlineTextureLoader.source(of: decoded.cgImage) == .imageIO(type: "public.png"))
        #expect(InlineTextureLoader.source(of: try #require(decoded.cgImage.copy())) == .imageIO(type: "public.png"))
        // ImageIO still provides a crop's pixels, but nothing structural says so:
        // MetalKit would make BGRA8 of it, the in-line loader makes RGBA8.
        let crop = try #require(decoded.cgImage.cropping(to: CGRect(x: 3, y: 2, width: 20, height: 11)))
        #expect(InlineTextureLoader.source(of: crop) == .data)
        #expect(InlineTextureLoader.layout(for: crop, srgb: true, source: .data)?.pixelFormat == .rgba8Unorm)
    }

    @Test("Every entry point rejects GPU texture containers by name", arguments: [
        ("KTX", [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A] as [UInt8]),
        ("KTX2", [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]),
        ("PVR", [0x50, 0x56, 0x52, 0x03]),
        ("ASTC", [0x13, 0xAB, 0xA1, 0x5C]),
        ("DDS", [0x44, 0x44, 0x53, 0x20]),
    ])
    func textureEntryPointsRejectContainers(name: String, magic: [UInt8]) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let data = Data(magic + [UInt8](repeating: 0, count: 64))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-container-\(UUID().uuidString).bin")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(InlineTextureLoader.container(of: data) == name)
        let resources = ResourceStore(device: device)
        #expect {
            try resources.texture(url: url)
        } throws: { error in
            guard case ResourceError.unsupportedTextureContainer(let container, let path) = error else { return false }
            return container == name && path == url.path && "\(error)".contains(name)
        }
        #expect {
            try resources.texture(data: data, key: "container")
        } throws: { error in
            guard case ResourceError.unsupportedTextureContainer(let container, let key) = error else { return false }
            return container == name && key == "container"
        }
    }

    /// ImageIO decodes KTX and ASTC itself, so a container also reaches the
    /// loader as a decoded image: its ImageIO type rejects it on every path.
    @Test("Containers ImageIO decodes are rejected on every entry point, texture(cgImage:) included", arguments: [
        ("org.khronos.ktx", "KTX"), ("org.khronos.astc", "ASTC"),
    ])
    func imageIOContainersAreRejected(type: String, name: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let base = try #require(TextureIdentityCases.plain(bpc: 8, components: 4, alpha: .last, order: [], float: false, width: 8, height: 8))
        guard let data = TextureIdentityCases.encode(base, as: type) else { return } // no encoder on this system
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-container-\(UUID().uuidString).img")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let resources = ResourceStore(device: device)
        func rejected(_ error: any Error) -> Bool {
            guard case ResourceError.unsupportedTextureContainer(let container, _) = error else { return false }
            return container == name
        }
        #expect { try resources.texture(url: url) } throws: { rejected($0) }
        #expect { try resources.texture(data: data, key: "container") } throws: { rejected($0) }
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect { try resources.texture(cgImage: image, key: "container") } throws: { rejected($0) }
    }

    @Test("ImageIO's container types map to their names")
    func containerTypesMapToNames() {
        let expected = ["org.khronos.ktx": "KTX", "org.khronos.ktx2": "KTX2", "public.pvr": "PVR", "org.khronos.astc": "ASTC",
                        "com.microsoft.dds": "DDS", "com.apple.atx": "ATX"]
        for (type, name) in expected { #expect(InlineTextureLoader.container(ofType: type) == name) }
        for type in ["public.png", "public.heic", "public.avif", "public.jpeg-xl", "org.webmproject.webp"] {
            #expect(InlineTextureLoader.container(ofType: type) == nil)
        }
    }

    /// Files from decoders ImageIO cannot encode, or encoders other than
    /// ImageIO's, made from `plain(bpc: 8, components: 4, alpha: .last or
    /// .noneSkipLast, width: 37, height: 23)` written as PNG: JPEG XL by
    /// cjxl (lossless, lossy, 16-bit), AVIF by avifenc (8, 10 and 12 bit, and a
    /// three-frame sequence), HEIF by renaming an ImageIO HEIC's ftyp brands
    /// to mif1, WebP by cwebp, and PSD, SGI, CUR, BMP v5, TGA and both TIFF
    /// alpha kinds by ImageMagick; ICNS by sips from a 32x32 resize.
    @Test("In-line loads match MetalKit for decoder fixtures ImageIO cannot write")
    func inlineTextureLoaderMatchesMetalKitForDecoderFixtures() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/texture-identity")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names.count >= 19)
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            #expect(InlineTextureLoader.image(data: data) != nil, "\(name) does not decode")
        }
        let mismatches = await onOwnThread { () -> [String] in
            let loader = MTKTextureLoader(device: device), queue = device.makeCommandQueue()!
            return names.flatMap { name -> [String] in
                let url = directory.appendingPathComponent(name)
                let decoded = (try? Data(contentsOf: url)).flatMap(InlineTextureLoader.image(data:))
                return [true, false].flatMap { srgb in
                    [TextureIdentityComparison.compare(name: "fixture file \(name) srgb \(srgb)", image: nil, url: url, srgb: srgb,
                                                       device: device, loader: loader, queue: queue),
                     decoded.flatMap { TextureIdentityComparison.compare(name: "fixture image \(name) srgb \(srgb)", image: $0, url: nil,
                                                                         srgb: srgb, device: device, loader: loader, queue: queue) }]
                        .compactMap { $0?.description }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(names.count * 4) fixture loads differ:\n\(mismatches.prefix(20).joined(separator: "\n"))")
    }
}
