import CoreGraphics
import Foundation
import Metal
import Testing
@testable import Renderer

private enum ObservationProbeError: Error { case sentinel }
private final class ObservationClock {
    var reads = 0
    var value = 0.0
    func now() -> Double {
        reads += 1
        defer { value += 0.25 }
        return value
    }
}

@Suite struct InlineTextureLoadObservationCPUTests {
    @Test func nilObserverRunsBodiesOnceAndPreservesErrorWithoutClockWork() throws {
        let clock = ObservationClock()
        let unused = InlineTextureLoadObservations(clock: clock.now)
        var bodies = 0
        let result = InlineTextureLoadObservations.measure(nil, .conversion) { bodies += 1; return 17 }
        #expect(result == 17 && bodies == 1)
        do {
            try InlineTextureLoadObservations.measure(nil, .completionWait) { () throws -> Void in
                bodies += 1
                throw ObservationProbeError.sentinel
            }
            Issue.record("Nil observations swallowed the original error.")
        } catch ObservationProbeError.sentinel {}
        #expect(bodies == 2 && clock.reads == 0 && unused.sample.stages.isEmpty)
        #expect(ResourceTextureLoadTimings().inlineObservations == nil)
    }

    @Test func fakeClockRecordsSuccessFailureAndPartialPriorStages() throws {
        let clock = ObservationClock()
        let observer = InlineTextureLoadObservations(clock: clock.now)
        let result = InlineTextureLoadObservations.measure(observer, .providerAccess) { 23 }
        #expect(result == 23)
        do {
            try InlineTextureLoadObservations.measure(observer, .conversion) { () throws -> Void in
                throw ObservationProbeError.sentinel
            }
            Issue.record("Observed body error was swallowed.")
        } catch ObservationProbeError.sentinel {}
        let sample = observer.sample
        #expect(clock.reads == 4)
        #expect(sample.stages[.providerAccess] == InlineTextureLoadObservations.Aggregate(calls: 1, failures: 0, milliseconds: 250))
        #expect(sample.stages[.conversion] == InlineTextureLoadObservations.Aggregate(calls: 1, failures: 1, milliseconds: 250))
        #expect(sample.stages[.encodeSubmit] == nil && sample.convertedRows == 0)
    }

    @Test func repeatedStagesStayAggregatedWithoutPerStripRecords() {
        let clock = ObservationClock()
        let observer = InlineTextureLoadObservations(clock: clock.now)
        for _ in 0..<64 {
            InlineTextureLoadObservations.measure(observer, .conversion) {}
            observer.recordConvertedRows(2)
        }
        observer.recordMipmapEncode()
        let sample = observer.sample
        #expect(sample.stages.count == 1 && sample.stages.count <= InlineTextureLoadObservations.Stage.allCases.count)
        #expect(sample.stages[.conversion] == InlineTextureLoadObservations.Aggregate(calls: 64, failures: 0, milliseconds: 16_000))
        #expect(sample.convertedRows == 128 && sample.mipmapEncodes == 1 && clock.reads == 128)
    }

    @Test func permitObservationReusesSuppliedDurationWithoutObserverClock() {
        let clock = ObservationClock()
        let observer = InlineTextureLoadObservations(clock: clock.now)
        observer.recordPermitWait(seconds: 0.125)
        observer.recordPermitWait(seconds: 0.25)
        #expect(observer.sample.stages[.permitWait] == InlineTextureLoadObservations.Aggregate(calls: 2, failures: 0, milliseconds: 375))
        #expect(clock.reads == 0 && observer.sample.mainThreadBypasses == 0)
    }

    @Test @MainActor func mainThreadBypassIsDistinctAndKeepsThrownError() throws {
        try #require(Thread.isMainThread)
        let clock = ObservationClock()
        let observer = InlineTextureLoadObservations(clock: clock.now)
        let permits = UploadPermits(limit: 1)
        let result = permits.withPermit(observations: observer) { 7 }
        do {
            try permits.withPermit(observations: observer) { () throws -> Void in
                throw ObservationProbeError.sentinel
            }
            Issue.record("Main-thread permit bypass swallowed an error.")
        } catch ObservationProbeError.sentinel {}
        #expect(result == 7 && observer.sample.mainThreadBypasses == 2)
        #expect(observer.sample.stages[.permitWait] == nil && clock.reads == 0)
        #expect(permits.resetStats().mainThreadLoads == 2)
    }

    @Test func workerPermitObservationsKeepReleaseAfterError() async {
        // The observer is created/used on one caller thread, never shared.
        let result = await onOwnThread { () -> (Bool, Int, InlineTextureLoadObservations.Sample) in
            let clock = ObservationClock()
            let observer = InlineTextureLoadObservations(clock: clock.now)
            let permits = UploadPermits(limit: 1)
            var originalError = false
            do {
                try permits.withPermit(observations: observer) { () throws -> Void in
                    throw ObservationProbeError.sentinel
                }
            } catch ObservationProbeError.sentinel { originalError = true }
            catch {}
            // A leaked first permit blocks this second call; the future frozen
            // test runner needs an outer bound, as for existing permit tests.
            let second = permits.withPermit(observations: observer) { 11 }
            return (originalError && second == 11 && !Thread.isMainThread, clock.reads, observer.sample)
        }
        #expect(result.0 && result.1 == 0)
        #expect(result.2.mainThreadBypasses == 0)
        #expect(result.2.stages[.permitWait]?.calls == 2 && result.2.stages[.permitWait]?.failures == 0)
        // No duration assertion on the real semaphore clock: functional only.
    }
}

/// Separate native gate proposal. These controls are NOT CPU-only and must not
/// be included in a CPU grant. No pixel/readback equivalence claim is made here.
@Suite struct InlineTextureLoadObservationNativeTests {
    private var png: Data {
        // Existing public synthetic 1x1 PNG used by SourcePreviewAppearanceTests.
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    @Test @MainActor func uncachedDataCreatesOnceAndKeepsPublicPhaseNames() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let clock = ObservationClock()
        let observer = InlineTextureLoadObservations(clock: clock.now)
        let timings = ResourceTextureLoadTimings(inlineObservations: observer)
        var created: [TextureHandle] = []
        let handle = try resources.texture(data: png, key: "observed-private", cacheNew: false,
                                          timings: timings, didCreate: { created.append($0) })
        let publicSample = timings.sample, nested = observer.sample
        #expect(created == [handle] && resources.lookup(key: "observed-private#true") == nil)
        #expect(resources.texture(handle) != nil && publicSample.registeredTextures == 1)
        #expect(publicSample.calls == ["dataCacheLookup": 1, "imageCreation": 1, "imageCacheLookup": 1,
                                      "metalTextureLoad": 1, "registration": 1])
        #expect(publicSample.failures.isEmpty && nested.mainThreadBypasses == 1)
        for stage in InlineTextureLoadObservations.Stage.allCases where stage != .permitWait {
            #expect(nested.stages[stage] == InlineTextureLoadObservations.Aggregate(calls: 1, failures: 0, milliseconds: 250))
        }
        #expect(nested.stages[.permitWait] == nil && nested.convertedRows == 1 && nested.mipmapEncodes == 0)
        #expect(clock.reads == 12)
        #expect(resources.cacheTextureIfAbsent(handle, key: "observed-private#true"))
        #expect(resources.lookup(key: "observed-private#true") == handle)
    }

    @Test @MainActor func sharedDataAndImageCacheHitsHaveNoNestedWorkOrCreation() throws {
        let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
        let prior = try resources.texture(data: png, key: "observed-warm")
        let clock = ObservationClock()
        let observer = InlineTextureLoadObservations(clock: clock.now)
        let dataTimings = ResourceTextureLoadTimings(inlineObservations: observer)
        var creations = 0
        let warm = try resources.texture(data: Data("invalid image".utf8), key: "observed-warm",
                                         timings: dataTimings, didCreate: { _ in creations += 1 })
        let image = try #require(TextureIdentityCases.plain(bpc: 8, components: 4, alpha: .last,
                                                          order: [], float: false, width: 3, height: 5))
        let imageTimings = ResourceTextureLoadTimings(inlineObservations: observer)
        let imageHit = try resources.texture(cgImage: image, key: "observed-warm#true",
                                             timings: imageTimings, didCreate: { _ in creations += 1 })
        #expect(warm == prior && imageHit == prior && creations == 0)
        #expect(dataTimings.sample.calls == ["dataCacheLookup": 1] && dataTimings.sample.dataCacheHits == 1)
        #expect(imageTimings.sample.calls == ["imageCacheLookup": 1] && imageTimings.sample.imageCacheHits == 1)
        #expect(observer.sample.stages.isEmpty && observer.sample.mainThreadBypasses == 0 && clock.reads == 0)
    }

    @Test @MainActor func shortLastStripCountsConversionSubmitCompletionAndFinalMipOnce() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let image = try #require(TextureIdentityCases.plain(bpc: 8, components: 4, alpha: .last,
                                                          order: [], float: false, width: 3, height: 5))
        let clock = ObservationClock()
        let observer = InlineTextureLoadObservations(clock: clock.now)
        var callbacks = 0
        var status: MTLCommandBufferStatus?
        var completedCallsAtCallback = 0
        let texture = try InlineTextureLoader.texture(.init(cgImage: image, source: .data), srgb: true,
            device: device, queue: resources.uploadQueue, observations: observer, stagingLimit: 3 * 4 * 2) { command in
                callbacks += 1; status = command.status
                completedCallsAtCallback = observer.sample.stages[.completionWait]?.calls ?? 0
            }
        let sample = observer.sample
        #expect(texture.width == 3 && texture.height == 5 && texture.mipmapLevelCount == 3)
        #expect(callbacks == 1 && status == .completed && completedCallsAtCallback == 3)
        for stage in [InlineTextureLoadObservations.Stage.conversion, .encodeSubmit, .completionWait] {
            #expect(sample.stages[stage] == InlineTextureLoadObservations.Aggregate(calls: 3, failures: 0, milliseconds: 750))
        }
        #expect(sample.stages[.providerAccess]?.calls == 1 && sample.stages[.stagingAllocation]?.calls == 1)
        #expect(sample.convertedRows == 5 && sample.mipmapEncodes == 1 && sample.mainThreadBypasses == 1)
        #expect(clock.reads == 24)
    }

    @Test @MainActor func originalPreUploadErrorsKeepPartialPhasesAndNeverRegister() throws {
        let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
        let clock = ObservationClock()
        let observer = InlineTextureLoadObservations(clock: clock.now)
        let timings = ResourceTextureLoadTimings(inlineObservations: observer)
        var creations = 0
        do {
            _ = try resources.texture(data: Data("invalid image".utf8), key: "observed-invalid", timings: timings,
                                      didCreate: { _ in creations += 1 })
            Issue.record("Invalid image unexpectedly loaded.")
        } catch ResourceError.imageDecode(let key) { #expect(key == "observed-invalid") }
        #expect(timings.sample.failures == ["imageCreation": 1] && observer.sample.stages.isEmpty)
        let unsupported = try #require(TextureIdentityCases.plain(bpc: 8, components: 3, alpha: .none,
                                                                order: [], float: false, width: 3, height: 5))
        do {
            _ = try resources.texture(cgImage: unsupported, key: "observed-layout", timings: timings,
                                      didCreate: { _ in creations += 1 })
            Issue.record("Unsupported data-image layout unexpectedly loaded.")
        } catch InlineTextureLoader.Failure.unsupportedLayout(let detail) {
            #expect(detail == InlineTextureLoader.describe(unsupported))
        }
        #expect(timings.sample.failures == ["imageCreation": 1, "metalTextureLoad": 1])
        #expect(observer.sample.stages[.destinationAllocation] == InlineTextureLoadObservations.Aggregate(calls: 1, failures: 1, milliseconds: 250))
        #expect(observer.sample.stages.count == 1 && observer.sample.mainThreadBypasses == 0)
        #expect(clock.reads == 2 && creations == 0 && timings.sample.registeredTextures == 0)
        #expect(resources.lookup(key: "observed-invalid#true") == nil && resources.lookup(key: "observed-layout") == nil)
    }
}
