import CoreGraphics
import Foundation
import Metal
import Testing
@testable import Renderer

/// #192-D: `ResourceTextureLoadTimings` splits `metalTextureLoad` into the
/// in-line loader's stages. Clock check: an injected clock that counts its
/// reads, as the loader's own observation tests use. Every read of a timed
/// load goes through it, so its exact count shows no other clock is read;
/// a nil collector has no clock in its path and leaves the count unchanged.
private final class CountingClock: @unchecked Sendable {
    private(set) var reads = 0
    /// Each read is 0.25 s after the one before.
    func now() -> Double {
        defer { reads += 1 }
        return Double(reads) * 0.25
    }
}

/// The loader's eight stages, each lapped once by a one-strip load.
private let loaderStages = ["destinationAllocation", "permitWait", "decode", "stagingAllocation", "conversion",
                            "encodeSubmit", "completionWait", "cleanup"]

@Test func resourceTextureLoadTimingsSplitTheLoaderStagesWithOneClockAndNoneWhenNil() async throws {
    struct Outcome: Sendable {
        let coldReads: Int, hitReads: Int, nilReads: Int
        let calls: [String: Int], loaderCalls: [String: Int], loaderMilliseconds: [String: Double]
        let metalTextureLoad: Double?, hitLoaderCalls: [String: Int], same: Bool
    }
    let outcome = await onOwnThread { () -> Outcome? in
        guard let device = MTLCreateSystemDefaultDevice(),
              let image = TextureIdentityCases.plain(bpc: 8, components: 4, alpha: .last, order: [], float: false, width: 3, height: 5),
              let png = TextureIdentityCases.encode(image, as: "public.png") else { return nil }
        let resources = ResourceStore(device: device)
        let clock = CountingClock()
        let timings = ResourceTextureLoadTimings(clock: clock.now)
        // A cold load: five measured phases (two reads each) around the
        // loader's start and eight laps.
        guard let timed = try? resources.texture(data: png, key: "timed", timings: timings) else { return nil }
        let coldReads = clock.reads, cold = timings.sample
        // A shared-cache hit: only the data lookup is measured.
        guard (try? resources.texture(data: png, key: "timed", timings: timings)) == timed else { return nil }
        let hitReads = clock.reads - coldReads
        // The same image with no collector: no read, the same texture bytes.
        guard let plain = try? resources.texture(data: png, key: "plain", timings: nil) else { return nil }
        let nilReads = clock.reads - coldReads - hitReads
        var same = false
        if let queue = device.makeCommandQueue(), let a = resources.texture(timed), let b = resources.texture(plain),
           let left = try? TextureIdentityRecord(a, device: device, queue: queue),
           let right = try? TextureIdentityRecord(b, device: device, queue: queue) {
            same = left == right && left.levels.count == 3
        }
        return Outcome(coldReads: coldReads, hitReads: hitReads, nilReads: nilReads, calls: cold.calls,
                       loaderCalls: cold.loaderCalls, loaderMilliseconds: cold.loaderMilliseconds,
                       metalTextureLoad: cold.milliseconds["metalTextureLoad"], hitLoaderCalls: timings.sample.loaderCalls, same: same)
    }
    let result = try #require(outcome, "no Metal device, image or texture")
    #expect(result.coldReads == 5 * 2 + 1 + loaderStages.count)
    #expect(result.hitReads == 2 && result.nilReads == 0)
    #expect(result.calls == ["dataCacheLookup": 1, "imageCreation": 1, "imageCacheLookup": 1, "metalTextureLoad": 1, "registration": 1])
    #expect(result.loaderCalls == Dictionary(uniqueKeysWithValues: loaderStages.map { ($0, 1) }))
    // Nested: the eight laps (250 ms each) sit inside metalTextureLoad's ten steps.
    #expect(result.loaderMilliseconds.values.reduce(0, +) == 2000 && result.metalTextureLoad == 2500)
    // A hit makes no texture, so the loader's stages do not move.
    #expect(result.hitLoaderCalls == result.loaderCalls)
    #expect(result.same)
}

/// A collector that saw no texture creation reports no loader stage at all.
@Test func resourceTextureLoadTimingsReportNoLoaderStageWithoutACreation() {
    let clock = CountingClock()
    let sample = ResourceTextureLoadTimings(clock: clock.now).sample
    #expect(sample.loaderCalls.isEmpty && sample.loaderMilliseconds.isEmpty && clock.reads == 0)
}
