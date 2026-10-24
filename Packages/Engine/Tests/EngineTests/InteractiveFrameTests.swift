import Testing
import Foundation
import Metal
import QuartzCore
import os
import simd
import Scene
import Assets
import CoreMath
import ShaderTypes
@testable import Renderer

/// Exercises Renderer.draw with real CAMetalLayer drawables, including the early
/// skip path. Sentinel pixels show that a skipped drawable is never encoded into;
/// forced draws of the same snapshot verify byte-identical interactive output.
private final class InteractiveFixture {
    let renderer: Renderer
    let layer: CAMetalLayer
    var time: Double = 1
    let mesh: MeshHandle
    var frame: RenderFrame

    init() throws {
        renderer = try makeSourceShaderRenderer()
        layer = CAMetalLayer()
        layer.device = renderer.gpu.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 64, height: 64)
        let p = [Float3(-0.6, 0, 0), Float3(0.6, 0, 0), Float3(0, 1.5, 0)]
        let morph = MeshData.MorphTarget(name: "move", positionDeltas: [Float3](repeating: Float3(0.2, 0, 0), count: 3), normalDeltas: [])
        mesh = try renderer.resources.register(mesh: MeshData(name: "interactive", positions: p,
            normals: [Float3](repeating: Float3(0, 0, 1), count: 3), indices: [0, 1, 2], morphTargets: [morph]))
        var item = RenderItem(mesh: mesh, material: MaterialState(uniforms: .make(kind: MaterialKindItem)),
                              model: matrix_identity_float4x4, objectID: 1, deformKey: 42)
        item.hiddenKey = 43
        frame = RenderFrame(items: [item])
        frame.effects.showGrid = false
        renderer.submit(frame)
    }

    /// Fill a fresh swapchain drawable, run the interactive path, and read its
    /// actual pixels after that command buffer completes. No capture API involved.
    func draw(layer override: CAMetalLayer? = nil, failPrepare: Bool = false) throws -> (RenderDrawResult, Data) {
        try autoreleasepool {
            let drawable = try #require((override ?? layer).nextDrawable())
            let texture = drawable.texture
            let size = texture.width * texture.height * 4
            let staging = try #require(renderer.gpu.device.makeBuffer(length: size, options: .storageModeShared))
            memset(staging.contents(), 0xA5, size)
            let fill = try #require(renderer.gpu.commandQueue.makeCommandBuffer())
            let blit = try #require(fill.makeBlitCommandEncoder())
            blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: texture.width * 4, sourceBytesPerImage: size,
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: texture,
                      destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding(); fill.commit(); fill.waitUntilCompleted()
            let finished = DispatchSemaphore(value: 0)
            let completion = OSAllocatedUnfairLock<RenderDrawCompletion?>(initialState: nil)
            time += 1.0 / 120
            let didComplete: @Sendable (RenderDrawCompletion) -> Void = { value in
                completion.withLock { $0 = value }; finished.signal()
            }
            let result = failPrepare
                ? renderer.draw(to: drawable, timestamp: time, completion: didComplete,
                                configureFrameRing: { $0.abandonFrame() })
                : renderer.draw(to: drawable, timestamp: time, completion: didComplete)
            if result.outcome == .rendered {
                try #require(finished.wait(timeout: .now() + 10) == .success)
                #expect(completion.withLock { $0?.succeeded } == true)
            } else {
                #expect(completion.withLock { $0 == nil })
            }
            let read = try #require(renderer.gpu.commandQueue.makeCommandBuffer())
            let readBlit = try #require(read.makeBlitCommandEncoder())
            readBlit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: staging,
                          destinationOffset: 0, destinationBytesPerRow: texture.width * 4, destinationBytesPerImage: size)
            readBlit.endEncoding(); read.commit(); read.waitUntilCompleted()
            return (result, Data(bytes: staging.contents(), count: size))
        }
    }
}

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct InteractiveFrameTests {
    @Test func unchangedDrawLeavesTheDrawableUntouchedAndForcedDrawMatchesPixels() throws {
        let f = try InteractiveFixture()
        let first = try f.draw()
        #expect(first.0.outcome == .rendered)
        #expect(first.0.statistics.deformDispatches == 1)
        let skipped = try f.draw()
        #expect(skipped.0.outcome == .unchanged)
        #expect(skipped.1 == Data(repeating: 0xA5, count: 64 * 64 * 4))
        #expect(first.1 != skipped.1)
        #expect(skipped.0.statistics.deformDispatches == 0)
        f.renderer.invalidateInteractiveFrame()
        let forced = try f.draw()
        #expect(forced.0.outcome == .rendered && forced.1 == first.1)
        // The same frame keeps its retirement stamp but is a new submission.
        f.renderer.submit(f.frame)
        #expect(try f.draw().0.outcome == .rendered)
        #expect(try f.draw().0.outcome == .unchanged)
    }

    @Test func failedPreparationRetriesTheSameSubmissionAndPreservesItsPixels() throws {
        let f = try InteractiveFixture()
        let reference = try f.draw().1
        f.renderer.submit(f.frame)
        let failed = try f.draw(failPrepare: true)
        #expect(failed.0.outcome == .failed)
        #expect(failed.1 == Data(repeating: 0xA5, count: 64 * 64 * 4))
        #expect(f.renderer.lastFrameError == .uniformAllocation(.noOpenFrame))
        // No new submit or invalidation: failed work must never establish a hit.
        let retried = try f.draw()
        #expect(retried.0.outcome == .rendered && retried.1 == reference)
        #expect(f.renderer.lastFrameError == nil)
        #expect(try f.draw().0.outcome == .unchanged)
    }

    @Test func changesAndViewportResumeRedrawWithoutChangingTheReferencePixels() throws {
        let f = try InteractiveFixture()
        let initial = try f.draw().1
        f.frame.camera.yaw = 0.4
        f.renderer.submit(f.frame)
        let camera = try f.draw()
        #expect(camera.0.outcome == .rendered && camera.1 != initial)
        f.renderer.invalidateInteractiveFrame()
        #expect(try f.draw().1 == camera.1)
        f.frame.mainLight.rotation.x += 30
        f.frame.items[0].morphWeights = [(index: 0, weight: 1)]
        f.renderer.submit(f.frame)
        let changed = try f.draw()
        #expect(changed.0.outcome == .rendered && changed.1 != camera.1)
        #expect(try f.draw().0.outcome == .unchanged)
        f.time += 1 // display callbacks suspended while minimized/occluded
        #expect(try f.draw().0.outcome == .rendered)
        f.layer.drawableSize = CGSize(width: 128, height: 64)
        #expect(try f.draw().0.outcome == .rendered)
        let replacement = CAMetalLayer()
        replacement.device = f.renderer.gpu.device; replacement.pixelFormat = .bgra8Unorm
        replacement.framebufferOnly = false; replacement.drawableSize = f.layer.drawableSize
        #expect(try f.draw(layer: replacement).0.outcome == .rendered)
    }

    @Test func resourceChangesRedrawAndOffscreenWorkNeverPoisonsTheDisplayedSnapshot() throws {
        let f = try InteractiveFixture()
        let initial = try f.draw().1
        #expect(f.renderer.resources.setHiddenBuffer(key: 43, bytes: [1, 1, 1]))
        let hidden = try f.draw()
        #expect(hidden.0.outcome == .rendered && hidden.1 != initial)
        f.renderer.resources.releaseHiddenBuffers(keys: [43])
        #expect(try f.draw().1 == initial)
        var other = f.frame
        other.items[0].morphWeights = [(index: 0, weight: 1)]
        other.mainLight.rotation.y += 70
        #expect(f.renderer.capture(frame: other, width: 128, height: 64) != nil)
        _ = f.renderer.pick(frame: other, pixel: Float2(32, 32), size: (128, 64))
        _ = try f.renderer.benchmark(frame: other, width: 32, height: 32, warmupFrames: 0, measuredFrames: 1)
        #expect(try f.draw().0.outcome == .unchanged)
        f.renderer.invalidateInteractiveFrame()
        #expect(try f.draw().1 == initial)
        f.renderer.resources.retire(meshes: [f.mesh], deformKeys: [42])
        #expect(try f.draw().0.outcome == .unchanged) // old pending frame still owns them
        f.renderer.submit(RenderFrame())
        #expect(try f.draw().0.outcome == .rendered)
        #expect(f.renderer.resources.statistics().retiring == 0)
        #expect(f.renderer.resources.mesh(f.mesh) == nil)
    }

    @Test func visibleLiveMaterialsRemainContinuousAndResourceGenerationsCoverMutations() throws {
        let f = try InteractiveFixture()
        let r = f.renderer.resources
        var generation = r.generation
        let texture = try #require(r.texture(r8: [128], width: 1, height: 1, key: "mask"))
        #expect(r.generation != generation); generation = r.generation
        _ = r.texture(r8: [255], width: 1, height: 1, key: "mask")
        #expect(r.generation != generation); generation = r.generation
        r.unregister(texture: texture)
        #expect(r.generation != generation); generation = r.generation
        r.unregister(mesh: f.mesh)
        #expect(r.generation != generation)
        // No translated fixture needed: even a live material that falls back
        // remains conservative, rather than freezing a future time-reading pass.
        let material = SourceShaderLiveMaterial(label: "time", family: "test", queue: 2000,
            passes: [], vectors: [:], textures: [:], conventions: [], textureSources: [:])
        f.frame.items[0].sourceShader = SourceShaderLiveDraw(material: material, streams: nil, sourceOrder: 0)
        f.renderer.submit(f.frame)
        #expect(try f.draw().0.outcome == .rendered)
        #expect(try f.draw().0.outcome == .rendered)
        f.frame.items[0].visible = false
        f.renderer.submit(f.frame)
        #expect(try f.draw().0.outcome == .rendered)
        #expect(try f.draw().0.outcome == .unchanged)
    }
}

@Test func presentationCadenceExcludesOnlyDeliberatelyUnchangedCallbacks() {
    let period = 1.0 / 120
    let samples = [RenderPresentationSample(target: 0, presented: period),
                   RenderPresentationSample(target: 4 * period, presented: 5 * period)]
    let unchanged = [period, 2 * period, 3 * period]
    let normal = RenderPresentationSample.activeIntervals(samples, unchangedTargets: unchanged, period: period)
    #expect(abs(normal[0] - period) < 1e-10)
    // Missing or failed callbacks are not supplied as intentional skips.
    let missed = RenderPresentationSample.activeIntervals(samples, unchangedTargets: [period], period: period)
    #expect(abs(missed[0] - 3 * period) < 1e-10)
    var late = samples
    late[1].presented += 2 * period
    let delayed = RenderPresentationSample.activeIntervals(late, unchangedTargets: unchanged, period: period)
    #expect(abs(delayed[0] - 3 * period) < 1e-10)
    #expect(RenderPresentationSample.activeIntervals([], unchangedTargets: unchanged, period: period).isEmpty)
}

@Test func presentationLatenessSurvivesALateFirstFrameAndOutOfOrderTargets() {
    let period = 1.0 / 120
    let lateFirst = [RenderPresentationSample(target: 0, presented: 5 * period),
                     RenderPresentationSample(target: 4 * period, presented: 6 * period)]
    let adjusted = RenderPresentationSample.activeIntervals(lateFirst,
        unchangedTargets: [period, 2 * period, 3 * period], period: period)
    #expect(adjusted == [0]) // adjusted cadence is explicitly not latency
    #expect(abs(lateFirst[0].lateness - 5 * period) < 1e-10)
    #expect(abs(lateFirst[1].lateness - 2 * period) < 1e-10)
    let reordered = [RenderPresentationSample(target: 4 * period, presented: 5 * period),
                     RenderPresentationSample(target: 0, presented: 6 * period),
                     RenderPresentationSample(target: 8 * period, presented: 10 * period)]
    let intervals = RenderPresentationSample.activeIntervals(reordered,
        unchangedTargets: [period, 2 * period, 3 * period, 5 * period, 6 * period, 7 * period], period: period)
    #expect(abs(intervals[0] - period) < 1e-10) // reversed targets get no allowance
    #expect(intervals[1] == 0) // independently counted despite the reversed prior pair
    #expect(abs(reordered[1].lateness - 6 * period) < 1e-10)
}
