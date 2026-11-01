import CoreGraphics
import Foundation
import Metal
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
