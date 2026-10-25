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
    /// The newest drawable, kept as a window's compositor keeps the newest
    /// presented one, so the layer cannot hand it out again at once.
    private var held: (any CAMetalDrawable)?

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
    func draw(layer override: CAMetalLayer? = nil, failPrepare: Bool = false,
              refreshAfter: CFTimeInterval? = nil) throws -> (RenderDrawResult, Data) {
        try autoreleasepool {
            let drawable = try #require((override ?? layer).nextDrawable())
            defer { held = drawable }
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
                : renderer.draw(to: drawable, timestamp: time, refreshAfter: refreshAfter, completion: didComplete)
            if result.outcome == .rendered || result.outcome == .refreshed {
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

extension InteractiveFrameTests {
    /// The idle keep-alive (R7 phase 2, item 4): a refreshed callback presents
    /// exactly the last presented image's bytes, encodes no frame and never
    /// becomes a cached image of its own.
    @Test func keepAliveRefreshPresentsExactlyTheLastImageWithoutEncodingAFrame() throws {
        let f = try InteractiveFixture()
        let sentinel = Data(repeating: 0xA5, count: 64 * 64 * 4)
        let first = try f.draw(refreshAfter: 0.05)
        #expect(first.0.outcome == .rendered && first.1 != sentinel)
        // Before the interval has passed the callback stays untouched.
        let early = try f.draw(refreshAfter: 0.05)
        #expect(early.0.outcome == .unchanged && early.1 == sentinel)
        f.time += 0.05
        let refreshed = try f.draw(refreshAfter: 0.05)
        #expect(refreshed.0.outcome == .refreshed)
        #expect(refreshed.1 == first.1)
        #expect(refreshed.0.statistics.deformDispatches == 0)
        // A refresh is the newest present itself: the next one copies its bytes.
        #expect(try f.draw(refreshAfter: 0.05).0.outcome == .unchanged)
        f.time += 0.05
        let again = try f.draw(refreshAfter: 0.05)
        #expect(again.0.outcome == .refreshed && again.1 == first.1)
        // Without an interval nothing is refreshed, however long it has been.
        f.time += 0.2
        #expect(try f.draw().1 == sentinel)
        // A new submission renders; later refreshes copy the new image.
        f.frame.camera.yaw = 0.4
        f.renderer.submit(f.frame)
        let moved = try f.draw(refreshAfter: 0.05)
        #expect(moved.0.outcome == .rendered && moved.1 != first.1)
        f.time += 0.05
        let movedAgain = try f.draw(refreshAfter: 0.05)
        #expect(movedAgain.0.outcome == .refreshed && movedAgain.1 == moved.1)
        // A forced redraw of the same submission gives the bytes the refresh showed.
        f.renderer.invalidateInteractiveFrame()
        let forced = try f.draw(refreshAfter: 0.05)
        #expect(forced.0.outcome == .rendered && forced.1 == moved.1)
        // A new viewport thread has no image to refresh until it presents one.
        f.renderer.invalidateInteractiveFrame()
        f.time += 0.05
        #expect(try f.draw(refreshAfter: 0.05).0.outcome == .rendered)
        // The refresh copies a whole drawable, so a resize renders first.
        f.layer.drawableSize = CGSize(width: 32, height: 64)
        f.time += 0.05
        #expect(try f.draw(refreshAfter: 0.05).0.outcome == .rendered)
    }

    /// `Renderer.submit` calls its observers after the frame is pending, outside the locks.
    @Test func submitObserversRunAfterEverySubmitUntilRemoved() throws {
        let f = try InteractiveFixture()
        let count = OSAllocatedUnfairLock(initialState: 0)
        let renderer = f.renderer
        let token = renderer.addSubmitObserver {
            // Outside the frame lock: the observer can read the frame it was told about.
            _ = renderer.currentFrame()
            count.withLock { $0 += 1 }
        }
        f.renderer.submit(f.frame)
        f.renderer.submit(f.frame)
        #expect(count.withLock { $0 } == 2)
        f.renderer.removeSubmitObserver(token)
        f.renderer.submit(f.frame)
        #expect(count.withLock { $0 } == 2)
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

/// Deformed-vertex reuse (R7 phase 2, item 4): an interactive draw or pick
/// skips a deform dispatch only when the buffer's last committed dispatch had
/// the same inputs, and its pixels are byte-identical to a frame that
/// dispatched. Each test returns to earlier content after changing it, which a
/// record of "the previous frame" instead of "the buffer's last write" would get wrong.
extension InteractiveFrameTests {
    /// Redraws the pending submission (no new submit) and returns the draw.
    private func redraw(_ f: InteractiveFixture) throws -> (RenderDrawResult, Data) {
        f.renderer.invalidateInteractiveFrame()
        return try f.draw()
    }

    private func submitAndDraw(_ f: InteractiveFixture) throws -> (RenderDrawResult, Data) {
        f.renderer.submit(f.frame)
        return try f.draw()
    }

    /// Submits `f.frame` and returns its pixels with every deformation
    /// dispatched, as before reuse.
    private func dispatchedPixels(_ f: InteractiveFixture) throws -> Data {
        f.renderer.reusesDeformedVertices = false
        defer { f.renderer.reusesDeformedVertices = true }
        let drawn = try submitAndDraw(f)
        #expect(drawn.0.outcome == .rendered && drawn.0.statistics.deformReuses == 0)
        return drawn.1
    }

    private func expectReused(_ drawn: (RenderDrawResult, Data), _ pixels: Data, _ comment: Comment) {
        #expect(drawn.0.outcome == .rendered, comment)
        #expect(drawn.0.statistics.deformDispatches == 0 && drawn.0.statistics.deformReuses == 1, comment)
        #expect(drawn.1 == pixels, comment)
    }

    private func expectDispatched(_ drawn: (RenderDrawResult, Data), _ pixels: Data, _ comment: Comment) {
        #expect(drawn.0.outcome == .rendered, comment)
        #expect(drawn.0.statistics.deformDispatches == 1 && drawn.0.statistics.deformReuses == 0, comment)
        #expect(drawn.1 == pixels, comment)
    }

    /// Two bones, half each, so either matrix moves every vertex.
    private func registerSkinned(_ f: InteractiveFixture, name: String = "skinned", shift: Float = 0) throws -> MeshHandle {
        let p = [Float3(-0.6, 0, 0), Float3(0.6, 0, 0), Float3(0, 1.5, 0)].map { $0 + Float3(shift, 0, 0) }
        let morph = MeshData.MorphTarget(name: "move", positionDeltas: [Float3](repeating: Float3(0.2, 0, 0), count: 3), normalDeltas: [])
        return try f.renderer.resources.register(mesh: MeshData(name: name, positions: p,
            normals: [Float3](repeating: Float3(0, 0, 1), count: 3),
            joints: [SIMD4<UInt16>](repeating: SIMD4(0, 1, 0, 0), count: 3), weights: [Float4](repeating: Float4(0.5, 0.5, 0, 0), count: 3),
            indices: [0, 1, 2], morphTargets: [morph]))
    }

    @Test func deformReuseFollowsThePaletteTheMorphsAndTheMeshAndChangesBack() throws {
        let f = try InteractiveFixture()
        let skinned = try registerSkinned(f)
        f.frame.items[0].mesh = skinned
        f.frame.items[0].skinSet = 7
        f.frame.skinSets[7] = [matrix_identity_float4x4, matrix_identity_float4x4]
        let a = try submitAndDraw(f)
        expectDispatched(a, try dispatchedPixels(f), "first draw")
        expectReused(try redraw(f), a.1, "same submission")
        // Equal matrices in new storage compare by value.
        f.frame.skinSets[7] = [matrix_identity_float4x4] + [matrix_identity_float4x4]
        expectReused(try submitAndDraw(f), a.1, "equal palette, new array")

        // Palette.
        f.frame.skinSets[7] = [matrix_identity_float4x4, Transform.translation(Float3(0.3, 0, 0))]
        let palette = try dispatchedPixels(f)
        #expect(palette != a.1)
        // The reference above dispatched, so the buffer already holds this palette.
        expectReused(try submitAndDraw(f), palette, "moved bone")
        f.frame.skinSets[7] = [matrix_identity_float4x4, matrix_identity_float4x4]
        expectDispatched(try submitAndDraw(f), a.1, "bone back")
        // One bit of one matrix element.
        var nudged = matrix_identity_float4x4
        nudged.columns.3.x = Float(bitPattern: 1)
        f.frame.skinSets[7] = [matrix_identity_float4x4, nudged]
        #expect(try submitAndDraw(f).0.statistics.deformDispatches == 1)
        f.frame.skinSets[7] = [matrix_identity_float4x4, matrix_identity_float4x4]
        expectDispatched(try submitAndDraw(f), a.1, "nudge back")

        // Morphs: weight, then order of the same entries, then none again.
        f.frame.items[0].morphWeights = [(index: 0, weight: 1)]
        let morphed = try dispatchedPixels(f)
        #expect(morphed != a.1)
        expectReused(try submitAndDraw(f), morphed, "morph on")
        f.frame.items[0].morphWeights = [(index: 0, weight: 0.5)]
        #expect(try submitAndDraw(f).0.statistics.deformDispatches == 1)
        // Entries below 1e-4 are not meaningful: the same content as no morph.
        f.frame.items[0].morphWeights = [(index: 0, weight: 0.00001)]
        expectDispatched(try submitAndDraw(f), a.1, "morph off")
        f.frame.items[0].morphWeights = []
        expectReused(try submitAndDraw(f), a.1, "no entries")

        // Mesh: another mesh on the same deformation key, then back.
        let other = try registerSkinned(f, name: "shifted", shift: 0.2)
        f.frame.items[0].mesh = other
        let shifted = try dispatchedPixels(f)
        #expect(shifted != a.1)
        expectReused(try submitAndDraw(f), shifted, "other mesh")
        f.frame.items[0].mesh = skinned
        expectDispatched(try submitAndDraw(f), a.1, "mesh back")

        // Without skin: the morph-only fixture mesh.
        f.frame.items[0].mesh = f.mesh
        f.frame.items[0].skinSet = nil
        let unskinned = try dispatchedPixels(f)
        expectReused(try submitAndDraw(f), unskinned, "unskinned")
        f.frame.items[0].mesh = skinned
        f.frame.items[0].skinSet = 7
        expectDispatched(try submitAndDraw(f), a.1, "skinned again")
    }

    @Test func deformReuseNeverTrustsAReleasedGrownOrTransientBuffer() throws {
        let f = try InteractiveFixture()
        let a = try f.draw()
        #expect(a.0.statistics.deformDispatches == 1)
        expectReused(try redraw(f), a.1, "persistent buffer")
        // A released key gets a new buffer, which no write has filled.
        f.renderer.resources.releaseDeformBuffers(keys: [42])
        expectDispatched(try redraw(f), a.1, "released")
        expectReused(try redraw(f), a.1, "new buffer filled")
        // A larger mesh grows the key's buffer; the original mesh then reads
        // the grown buffer, which holds the larger mesh's vertices.
        let quad = try f.renderer.resources.register(mesh: MeshData(name: "quad",
            positions: [Float3(-0.6, 0, 0), Float3(0.6, 0, 0), Float3(0, 1.5, 0), Float3(0.6, 1.5, 0)],
            normals: [Float3](repeating: Float3(0, 0, 1), count: 4), indices: [0, 1, 2, 1, 3, 2],
            morphTargets: [MeshData.MorphTarget(name: "move", positionDeltas: [Float3](repeating: Float3(0.2, 0, 0), count: 4), normalDeltas: [])]))
        let original = f.frame
        f.frame.items[0].mesh = quad
        let grown = try submitAndDraw(f)
        #expect(grown.0.statistics.deformDispatches == 1 && grown.1 != a.1)
        f.frame = original
        expectDispatched(try submitAndDraw(f), a.1, "back in the grown buffer")
        // A frame created before a completed retirement of its key gets a
        // transient buffer each time: always dispatched.
        f.renderer.resources.retire(deformKeys: [42])
        f.renderer.submit(RenderFrame())
        #expect(try f.draw().0.outcome == .rendered)
        expectDispatched(try submitAndDraw(f), a.1, "transient")
        expectDispatched(try redraw(f), a.1, "transient again")
    }

    /// The record holds its buffer strongly. A frame that does not use a key
    /// drops the key's record, which releases a removed character's buffer,
    /// and the key's next use dispatches again.
    @Test func framesDropTheRecordsOfKeysTheyDoNotUse() throws {
        let f = try InteractiveFixture()
        let a = try f.draw()
        #expect(a.0.statistics.deformDispatches == 1)
        weak var released: (any MTLBuffer)?
        autoreleasepool {
            released = f.renderer.resources.deformBuffer(for: 42, vertexCount: 3)
            f.renderer.resources.releaseDeformBuffers(keys: [42])
        }
        #expect(released != nil, "the record holds the released buffer")
        let original = f.frame
        f.frame.items = []
        #expect(try submitAndDraw(f).0.statistics.deformDispatches == 0)
        #expect(released == nil, "the frame without the key released it")
        f.frame = original
        expectDispatched(try submitAndDraw(f), a.1, "key used again")
        expectReused(try redraw(f), a.1, "recorded again")
    }

    /// Captures, benchmarks and picks write the same buffers. Every writer
    /// commits under the render lock, so a later draw reads what the last of
    /// them wrote, in queue order, even when the pick ran on the pick queue.
    @Test func offscreenWritesBetweenDrawsKeepTheContentRecordInQueueOrder() throws {
        let f = try InteractiveFixture()
        let a = try f.draw()
        var other = f.frame
        other.items[0].morphWeights = [(index: 0, weight: 1)]
        #expect(f.renderer.capture(frame: other, width: 64, height: 64) != nil)
        expectDispatched(try redraw(f), a.1, "after a capture")
        _ = try f.renderer.benchmark(frame: other, width: 32, height: 32, warmupFrames: 0, measuredFrames: 2)
        expectDispatched(try redraw(f), a.1, "after a benchmark")
        // A capture of the drawn content still dispatches, and leaves the record valid.
        #expect(f.renderer.capture(frame: f.frame, width: 64, height: 64) != nil)
        #expect(f.renderer.lastFrameStatistics.deformDispatches == 1)
        expectReused(try redraw(f), a.1, "after a capture of the same content")

        // Picks reuse too, and pick the same ids either way.
        let pixel = Float2(32, 40), size = (64, 64)
        let id = f.renderer.pick(frame: f.frame, pixel: pixel, size: size)
        #expect(f.renderer.lastFrameStatistics.deformReuses == 1)
        let otherID = f.renderer.pick(frame: other, pixel: pixel, size: size)
        #expect(f.renderer.lastFrameStatistics.deformDispatches == 1)
        expectDispatched(try redraw(f), a.1, "after a pick of other content")
        f.renderer.reusesDeformedVertices = false
        #expect(f.renderer.pick(frame: f.frame, pixel: pixel, size: size) == id)
        #expect(f.renderer.pick(frame: other, pixel: pixel, size: size) == otherID)
        f.renderer.reusesDeformedVertices = true
        expectDispatched(try redraw(f), a.1, "after a dispatched pick")

        // Asynchronous picks of other content interleaved with draws on this thread.
        let finished = DispatchSemaphore(value: 0)
        for round in 0..<12 {
            f.renderer.pick(frame: round.isMultiple(of: 2) ? other : f.frame, pixel: pixel, size: size) { _ in finished.signal() }
            let drawn = try redraw(f)
            #expect(drawn.0.outcome == .rendered && drawn.1 == a.1, "round \(round)")
        }
        for _ in 0..<12 { #expect(finished.wait(timeout: .now() + 10) == .success) }
        // Whatever the order, the last writer was round 11's pick or draw, both of this content.
        expectReused(try redraw(f), a.1, "after the asynchronous picks")
    }

    /// A live source-shader draw reads the deformation the frame reused.
    @Test func liveDrawsReadReusedDeformedVertices() throws {
        let f = try InteractiveFixture()
        let resources = f.renderer.resources
        let directory = try LiveProgramFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let program = try resources.translatedPipelines.program(url: try LiveProgramFixture.write(LiveProgramFixture.uv, family: "live_uv", to: directory))
        let material = SourceShaderLiveMaterial(label: "o_uv slot 0", family: "live_uv", queue: 2000, passes: [program],
                                                vectors: ["_Color": [0, 0, 1, 1]], textures: [:], conventions: [], textureSources: [:])
        let mesh = try resources.register(mesh: MeshData(name: "o_uv/0",
            positions: [Float3(-0.6, -0.6, 0), Float3(0.6, -0.6, 0), Float3(0, 0.8, 0)],
            normals: [Float3](repeating: Float3(0, 0, 1), count: 3), uvs: [Float2](repeating: Float2(0.25, 0.25), count: 3),
            uvs1: [Float2](repeating: Float2(1, 1), count: 3), indices: [0, 1, 2],
            morphTargets: [MeshData.MorphTarget(name: "move", positionDeltas: [Float3](repeating: Float3(0.3, 0, 0), count: 3), normalDeltas: [])]))
        f.frame.items[0].mesh = mesh
        f.frame.items[0].sourceShader = SourceShaderLiveDraw(material: material, streams: nil, sourceOrder: 0)
        f.frame.items[0].morphWeights = [(index: 0, weight: 1)]
        let reference = try dispatchedPixels(f)
        #expect(f.renderer.lastSourceShaderLive.draws == 1 && f.renderer.lastSourceShaderLive.fallbacks.isEmpty)
        // Live frames render every callback; after the first, each reuses the deformation.
        let first = try submitAndDraw(f)
        expectReused(first, reference, "live, first")
        for round in 0..<3 { expectReused(try f.draw(), reference, "live, round \(round)") }
        #expect(f.renderer.lastSourceShaderLive.draws == 1 && f.renderer.lastSourceShaderLive.fallbacks.isEmpty)
        f.frame.items[0].morphWeights = []
        let moved = try submitAndDraw(f)
        #expect(moved.0.statistics.deformDispatches == 1 && moved.1 != reference)
        f.frame.items[0].morphWeights = [(index: 0, weight: 1)]
        expectDispatched(try submitAndDraw(f), reference, "live, morph back")
    }
}
