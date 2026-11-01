import CoreGraphics
import Foundation
import Metal
import MetalKit
import Testing
@testable import Renderer

/// A clock for observations: read `n` returns `time(n)`, by default 0.25 s
/// after the read before.
private final class ObservationClock {
    private(set) var reads = 0
    private let time: (Int) -> Double
    init(_ time: @escaping (Int) -> Double = { Double($0) * 0.25 }) { self.time = time }
    func now() -> Double {
        defer { reads += 1 }
        return time(reads)
    }
}

private typealias Stage = InlineTextureLoadObservations.Stage
private typealias Aggregate = InlineTextureLoadObservations.Aggregate

/// Laps per stage, in `Stage.allCases` order, of one load of a 3×5 RGBA8
/// image staged two rows at a time: three strips, the last of one row.
private let threeStripLaps = [1, 1, 1, 1, 3, 3, 3, 1]
/// Staging for two rows of a 3-pixel RGBA8 image.
private let twoRowStaging = 3 * 4 * 2

private func laps(_ observer: InlineTextureLoadObservations) -> [Aggregate] { Stage.allCases.map { observer[$0] } }

/// The expected aggregates when every lap of the stepping clock is 250 ms.
private func steppedLaps(_ calls: [Int]) -> [Aggregate] { calls.map { Aggregate(calls: $0, milliseconds: Double($0) * 250) } }

@Suite struct InlineTextureLoadObservationCPUTests {
    @Test func lapsCountFromThePreviousMarkAndStartResetsIt() {
        let times = [10.0, 10.5, 12.0, 12.25, 20.0, 20.125]
        let clock = ObservationClock { times[$0] }
        let observer = InlineTextureLoadObservations(clock: clock.now)
        observer.start()
        observer.lap(.providerAccess)
        observer.lap(.conversion)
        observer.lap(.conversion)
        observer.start() // The 7.75 s between loads count nowhere.
        observer.lap(.cleanup)
        #expect(observer[.providerAccess] == Aggregate(calls: 1, milliseconds: 500))
        #expect(observer[.conversion] == Aggregate(calls: 2, milliseconds: 1750))
        #expect(observer[.cleanup] == Aggregate(calls: 1, milliseconds: 125))
        #expect(Stage.allCases.filter { observer[$0].calls > 0 } == [.providerAccess, .conversion, .cleanup])
        #expect(observer.milliseconds == 2375 && clock.reads == 6)
    }
}

/// The marks in `InlineTextureLoader.texture`, with ImageIO and Metal.
@Suite struct InlineTextureLoadObservationNativeTests {
    /// One 3-strip load on a plain thread, which takes an upload permit,
    /// laps every stage, and its texture equals a load without an observer.
    @Test func workerThreadLoadLapsEveryStageAndMatchesANilLoad() async throws {
        let outcome = await onOwnThread { () -> (laps: [Aggregate], reads: Int, completedAtCallback: Int, cleanedAtCallback: Int,
                                                main: Bool, same: Bool?)? in
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let image = TextureIdentityCases.plain(bpc: 8, components: 4, alpha: .last, order: [], float: false,
                                                         width: 3, height: 5) else { return nil }
            let clock = ObservationClock()
            let observer = InlineTextureLoadObservations(clock: clock.now)
            var completedAtCallback = -1, cleanedAtCallback = -1
            let source = InlineTextureLoader.Image(cgImage: image, source: .data)
            let observed = try? InlineTextureLoader.texture(source, srgb: true, device: device, queue: queue, observations: observer,
                                                            stagingLimit: twoRowStaging) { _ in
                completedAtCallback = observer[.completionWait].calls; cleanedAtCallback = observer[.cleanup].calls
            }
            let plain = try? InlineTextureLoader.texture(source, srgb: true, device: device, queue: queue, stagingLimit: twoRowStaging)
            var same: Bool?
            if let observed, let plain,
               let a = try? TextureIdentityRecord(observed, device: device, queue: queue),
               let b = try? TextureIdentityRecord(plain, device: device, queue: queue) { same = a == b && a.levels.count == 3 }
            return (laps(observer), clock.reads, completedAtCallback, cleanedAtCallback, Thread.isMainThread, same)
        }
        let result = try #require(outcome, "no Metal device, queue or image")
        #expect(!result.main)
        #expect(result.laps == steppedLaps(threeStripLaps) && result.reads == 15)
        // `didComplete` runs after the last completion lap, inside cleanup.
        #expect(result.completedAtCallback == 3 && result.cleanedAtCallback == 0)
        #expect(result.same == true)
    }

    /// A layout the loader rejects throws before the first lap.
    @Test func rejectedLayoutThrowsBeforeTheFirstLap() throws {
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = try #require(device.makeCommandQueue())
        let unsupported = try #require(TextureIdentityCases.plain(bpc: 8, components: 3, alpha: .none, order: [], float: false,
                                                                width: 3, height: 5))
        let clock = ObservationClock()
        let observer = InlineTextureLoadObservations(clock: clock.now)
        do {
            _ = try InlineTextureLoader.texture(.init(cgImage: unsupported, source: .data), srgb: true, device: device,
                                                queue: queue, observations: observer)
            Issue.record("Unsupported data-image layout unexpectedly loaded.")
        } catch InlineTextureLoader.Failure.unsupportedLayout(let detail) {
            #expect(detail == InlineTextureLoader.describe(unsupported))
        }
        #expect(laps(observer) == steppedLaps(Array(repeating: 0, count: Stage.allCases.count)) && clock.reads == 1)
    }

    /// Exact paired readback: the copy and ImageIO channel-swap conversions,
    /// both colour flags and a short last strip, each loaded without and with
    /// an observer on the main thread (no permit). Not a cost measurement.
    @Test @MainActor func observedAndNilTexturesMatchEveryMipForCopyAndSwap() throws {
        try #require(Thread.isMainThread)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let queue = resources.uploadQueue
        let plain = try #require(TextureIdentityCases.plain(bpc: 8, components: 4, alpha: .last,
                                                          order: [], float: false, width: 3, height: 5))
        try #require(plain.bytesPerRow == 15) // Twelve bytes of pixels plus three of padding.
        let encoded = try #require(TextureIdentityCases.encode(plain, as: "public.png"))
        let decoded = try #require(InlineTextureLoader.image(data: encoded))
        try #require(decoded.source == .imageIO(type: "public.png"))
        let fixtures: [(image: InlineTextureLoader.Image, conversion: InlineTextureLoader.Conversion)] = [
            (.init(cgImage: plain, source: .data), .copy), (decoded, .swapRedBlue),
        ]
        var uploads = 0
        for fixture in fixtures {
            let image = fixture.image.cgImage
            try #require(image.width == 3 && image.height == 5 && image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
            for srgb in [false, true] {
                let layout = try #require(InlineTextureLoader.layout(for: fixture.image, srgb: srgb))
                try #require(layout.conversion == fixture.conversion && layout.bytesPerPixel == 4)
                var nilCallbacks = 0, observedCallbacks = 0, completedAtCallback = 0
                var nilStatus: MTLCommandBufferStatus?, observedStatus: MTLCommandBufferStatus?
                var nilLabel: String?, observedLabel: String?
                let nilTexture = try InlineTextureLoader.texture(fixture.image, srgb: srgb, device: device,
                    queue: queue, observations: nil, stagingLimit: twoRowStaging) { command in
                        nilCallbacks += 1; nilStatus = command.status; nilLabel = command.label
                    }
                uploads += 1
                let clock = ObservationClock()
                let observer = InlineTextureLoadObservations(clock: clock.now)
                let observedTexture = try InlineTextureLoader.texture(fixture.image, srgb: srgb, device: device,
                    queue: queue, observations: observer, stagingLimit: twoRowStaging) { command in
                        observedCallbacks += 1; observedStatus = command.status; observedLabel = command.label
                        completedAtCallback = observer[.completionWait].calls
                    }
                uploads += 1
                let baseline = try TextureIdentityRecord(nilTexture, device: device, queue: queue)
                let observed = try TextureIdentityRecord(observedTexture, device: device, queue: queue)
                #expect(baseline.descriptor == observed.descriptor)
                #expect(baseline.levels == observed.levels)
                #expect(baseline.levels.map(\.count) == [60, 8, 4]) // 3×5, 1×2, 1×1 at four bytes per pixel.
                #expect(nilCallbacks == 1 && observedCallbacks == 1 && nilStatus == .completed && observedStatus == .completed)
                #expect(nilLabel == "InlineTextureLoader strip 3/3" && observedLabel == nilLabel && completedAtCallback == 3)
                #expect(laps(observer) == steppedLaps(threeStripLaps) && clock.reads == 15)
            }
        }
        #expect(uploads == 8)
    }
}

/// Opt-in timing, Release (`swift test -c release -Xswiftc -enable-testing`
/// with `IKKOKU_TEXTURE_FORMAT_PERF=1`): where an encoded JPEG, HEIC or PNG
/// load spends its time, against MetalKit's whole load (#290). Each round
/// times, in rotating order on one plain thread: MetalKit's
/// `newTexture(data:)`; ours, `image(data:)` then `texture`, without an
/// observer; the same with an observer, for the stage split; and MetalKit's
/// `newTexture(cgImage:)` on a fresh ImageIO image, which shows how fast
/// MetalKit reaches decoded pixels. A second provider access on the observed
/// image afterwards separates the copy from the decode. Medians of 16 rounds
/// after 3 warm-ups; the stage medians need not add up to the median whole.
@Suite struct InlineTextureLoadFormatTiming {
    /// Photo-like content: smooth waves with a little noise, so JPEG and
    /// HEIC compress it as they would a texture, not as noise.
    static func image(side: Int, alpha: Bool) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: side * side * 4), seed: UInt32 = 0x9e37_79b9
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int(seed >> 27)) - 16
        }
        func channel(_ value: Float) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
        for y in 0..<side {
            for x in 0..<side {
                let fx = Float(x), fy = Float(y), i = (y * side + x) * 4
                bytes[i] = channel(128 + 100 * sin(fx * 0.013 + fy * 0.007) + noise())
                bytes[i + 1] = channel(128 + 100 * sin(fx * 0.005 - fy * 0.011 + 1) + noise())
                bytes[i + 2] = channel(128 + 100 * cos((fx + fy) * 0.009) + noise())
                if alpha { bytes[i + 3] = channel(160 + 90 * sin(fx * 0.004 + fy * 0.003)) }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = alpha ? CGImageAlphaInfo.last : .noneSkipLast
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func encode(_ image: CGImage, as type: String, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }

    @Test(.enabled(if: (ProcessInfo.processInfo.environment["IKKOKU_TEXTURE_FORMAT_PERF"] ?? "") == "1" && MTLCreateSystemDefaultDevice() != nil,
                   "Opt-in timing probe: IKKOKU_TEXTURE_FORMAT_PERF=1 and a Metal device"))
    func formatLoadStages() async throws {
        let specs: [(name: String, side: Int, alpha: Bool, type: String, quality: Double?)] = [
            ("jpeg-1024", 1024, false, "public.jpeg", 0.9), ("jpeg-2048", 2048, false, "public.jpeg", 0.9),
            ("heic-rgba-1024", 1024, true, "public.heic", 0.9), ("heic-rgba-2048", 2048, true, "public.heic", 0.9),
            ("png-rgba-1024", 1024, true, "public.png", nil),
        ]
        var files: [(name: String, data: Data)] = []
        for spec in specs {
            let image = try #require(Self.image(side: spec.side, alpha: spec.alpha))
            files.append((spec.name, try #require(Self.encode(image, as: spec.type, quality: spec.quality), "\(spec.name) encode")))
        }
        let inputs = files
        let lines = await onOwnThread { () -> [String] in
            let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!, loader = MTKTextureLoader(device: device)
            let options = TextureIdentityComparison.options(true)
            func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
            func ms(_ start: UInt64, _ end: UInt64) -> Double { Double(end - start) / 1e6 }
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            return inputs.map { name, data -> String in
                var metalKitData: [Double] = [], metalKitImage: [Double] = [], ours: [Double] = [], observed: [Double] = []
                var creation: [Double] = []
                var again: [Double] = [], stages = [[Double]](repeating: [], count: InlineTextureLoadObservations.Stage.allCases.count)
                var conversion = "?", failures = 0
                for round in 0..<19 {
                    let warm = round < 3
                    func runMetalKitData() {
                        let start = now()
                        if (try? loader.newTexture(data: data, options: options)) == nil { failures += 1 }
                        if !warm { metalKitData.append(ms(start, now())) }
                    }
                    func runMetalKitImage() {
                        guard let decoded = InlineTextureLoader.image(data: data) else { failures += 1; return }
                        let start = now()
                        if (try? loader.newTexture(cgImage: decoded.cgImage, options: options)) == nil { failures += 1 }
                        if !warm { metalKitImage.append(ms(start, now())) }
                    }
                    func runOurs() {
                        let start = now()
                        guard let decoded = InlineTextureLoader.image(data: data),
                              (try? InlineTextureLoader.texture(decoded, srgb: true, device: device, queue: queue)) != nil else {
                            failures += 1; return
                        }
                        if !warm { ours.append(ms(start, now())) }
                    }
                    func runObserved() {
                        let observer = InlineTextureLoadObservations()
                        let start = now()
                        guard let decoded = InlineTextureLoader.image(data: data) else { failures += 1; return }
                        let created = now()
                        if (try? InlineTextureLoader.texture(decoded, srgb: true, device: device, queue: queue, observations: observer)) == nil {
                            failures += 1; return
                        }
                        let end = now()
                        let copy = decoded.cgImage.dataProvider?.data
                        let secondEnd = now()
                        withExtendedLifetime(copy) {}
                        conversion = InlineTextureLoader.layout(for: decoded, srgb: true).map { "\($0.conversion)" } ?? "none"
                        guard !warm else { return }
                        observed.append(ms(start, end)); creation.append(ms(start, created)); again.append(ms(end, secondEnd))
                        for stage in InlineTextureLoadObservations.Stage.allCases { stages[stage.rawValue].append(observer[stage].milliseconds) }
                    }
                    let order: [() -> Void] = [runMetalKitData, runOurs, runObserved, runMetalKitImage]
                    for k in 0..<order.count { order[(k + round) % order.count]() }
                }
                guard failures == 0, !ours.isEmpty else { return "[texture-format-perf] \(name): \(failures) failures" }
                let split = InlineTextureLoadObservations.Stage.allCases.map { "\($0) " + String(format: "%.2f", median(stages[$0.rawValue])) }
                return "[texture-format-perf] \(name) (\(data.count / 1024) KB, \(conversion)): "
                    + String(format: "MetalKit data %.2f ms; MetalKit cgImage %.2f ms; ours %.2f ms; observed %.2f ms = image creation %.2f + texture [",
                             median(metalKitData), median(metalKitImage), median(ours), median(observed), median(creation))
                    + split.joined(separator: ", ")
                    + String(format: "]; provider data again %.2f ms", median(again))
            }
        }
        for line in lines { print(line) }
        if let path = ProcessInfo.processInfo.environment["IKKOKU_TEXTURE_FORMAT_PERF_REPORT"] {
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(lines.allSatisfy { !$0.contains("failures") })
    }
}
