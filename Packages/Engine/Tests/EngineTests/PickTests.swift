import Testing
import Foundation
import Metal
import os
import simd
import Assets
import CoreMath
import Scene
import ShaderTypes
import Character
import Studio
@testable import Renderer

// R7 phase 2, item 5: the pick pass is scissored to the pixel it reads and the
// hover picks asynchronously for the latest pointer position only. The ids
// must not change, and a stale asynchronous result must never apply.

private typealias Queue = LatestPickQueue<Int>

/// A frame with every kind of pick target: a skinned, deformed character
/// (id 1), an opaque quad that discards through a mipmapped body mask (id 2),
/// a transparent quad in front of the character (id 3), a translate gizmo
/// (axes and plane handles), a rotate gizmo, a bone handle, an unpickable
/// line batch and the background (0).
private struct PickScene {
    let frame: RenderFrame
    let assets: UntexturedCharacterAssets
    let character: CharacterInstance

    init(renderer: Renderer) throws {
        assets = try UntexturedCharacterAssets()
        let library = AssetLibrary(resources: renderer.resources, root: assets.root)
        character = CharacterInstance(instanceID: 31, library: library, card: UntexturedCharacterAssets.card(garmentCount: 3))
        var frame = characterFrame(character)

        let resources = renderer.resources
        let quad = try resources.register(mesh: MeshData(
            name: "pick-quad", positions: [Float3(-0.25, -0.25, 0), Float3(0.25, -0.25, 0), Float3(0.25, 0.25, 0), Float3(-0.25, 0.25, 0)],
            normals: [Float3](repeating: Float3(0, 0, 1), count: 4),
            uvs: [Float2(0, 1), Float2(1, 1), Float2(1, 0), Float2(0, 0)], indices: [0, 1, 2, 0, 2, 3]))
        var masked = MaterialState(uniforms: .make(kind: MaterialKindItem))
        masked.bodyMask = try Self.mipmappedMask(device: renderer.gpu.device, resources: resources)
        masked.setFlag(MaterialFlagHasBodyMask, true)
        // Tilted away from the camera, so the mask's mip level changes across
        // the quad: its fragments read derivatives, which a scissor must not change.
        let tilt = Transform.trs(Float3(-0.45, 1.05, 0.1), simd_quatf(angle: 1.1, axis: normalize(Float3(1, 0.4, 0))), Float3(repeating: 1.4))
        frame.items.append(RenderItem(mesh: quad, material: masked, model: tilt, objectID: 2))
        var glass = MaterialState(uniforms: .make(kind: MaterialKindItem))
        glass.transparent = true
        frame.items.append(RenderItem(mesh: quad, material: glass,
                                      model: Transform.trs(Float3(0.12, 0.75, 0.35), .identity, Float3(repeating: 0.6)), objectID: 3))

        frame.gizmos += GizmoBuilder.build(mode: .translate, origin: Float3(0.15, 1.15, 0.3), orientation: .identity, size: 0.35, highlight: .y)
        frame.gizmos += GizmoBuilder.build(mode: .rotate, origin: Float3(0.45, 0.55, 0.2),
                                           orientation: simd_quatf(angle: 0.6, axis: Float3(0, 1, 0)), size: 0.25, highlight: nil)
        frame.gizmos.append(GizmoBuilder.handle(at: Float3(-0.1, 0.5, 0.3), size: 0.04, color: Float4(1, 1, 1, 1), id: PickIDs.bone(7)))
        frame.gizmos.append(GizmoBuilder.lines([(Float3(-1, 0.2, 0), Float3(1, 1.6, 0))], color: Float4(1, 1, 1, 1)))
        self.frame = frame
    }

    /// RGBA8 64×64 with every mip level: each level is a checkerboard of a
    /// different phase and cell size, so a wrong level discards different pixels.
    static func mipmappedMask(device: any MTLDevice, resources: ResourceStore) throws -> TextureHandle {
        let side = 64
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        for level in 0..<texture.mipmapLevelCount {
            let size = max(side >> level, 1), cell = max(8 >> level, 1)
            var bytes = [UInt8](repeating: 255, count: size * size * 4)
            for y in 0..<size {
                for x in 0..<size where (x / cell + y / cell + level) % 2 == 0 {
                    bytes[(y * size + x) * 4] = 0
                }
            }
            texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: level, withBytes: bytes, bytesPerRow: size * 4)
        }
        return resources.register(texture: texture)
    }
}

/// Runs one asynchronous pick and returns its result.
private func pickAsync(_ renderer: Renderer, _ frame: RenderFrame, _ pixel: Float2, _ size: (Int, Int)) -> RenderPickResult? {
    let done = DispatchSemaphore(value: 0)
    let result = OSAllocatedUnfairLock<RenderPickResult?>(initialState: nil)
    renderer.pick(frame: frame, pixel: pixel, size: size) { picked in
        result.withLock { $0 = picked }
        done.signal()
    }
    guard done.wait(timeout: .now() + 10) == .success else { return nil }
    return result.withLock { $0 }
}

@Test func latestPickQueueKeepsOnePickInFlightAndAppliesOnlyTheLatestMove() {
    var queue = Queue()
    #expect(queue.isIdle)
    // The first move starts a pick; moves while it runs only wait, the latest replacing the earlier.
    let first = queue.move(to: Float2(10, 10), context: 1)
    #expect(first == Queue.Request(move: 1, pixel: Float2(10, 10), context: 1))
    #expect(queue.move(to: Float2(11, 10), context: 1) == nil)
    #expect(queue.move(to: Float2(12, 10), context: 1) == nil)
    #expect(!queue.isIdle)
    // The first result answers move 1, not the latest move 3: dropped, and move 3 is picked.
    let afterFirst = queue.finish(first!, current: 1)
    #expect(afterFirst.outcome == .stale)
    #expect(afterFirst.next == Queue.Request(move: 3, pixel: Float2(12, 10), context: 1))
    // Move 2 is never picked. Move 3's result applies; nothing is left to pick.
    let afterLatest = queue.finish(afterFirst.next!, current: 1)
    #expect(afterLatest.outcome == .apply)
    #expect(afterLatest.next == nil)
    #expect(queue.isIdle)
    #expect(queue.statistics == {
        var s = Queue.Statistics(); s.moves = 3; s.coalesced = 2; s.issued = 2; s.applied = 1; s.stale = 1; return s
    }())
    // A result handed back twice, or one never issued, changes nothing.
    #expect(queue.finish(afterFirst.next!, current: 1).outcome == .stale)
    #expect(queue.isIdle)
}

@Test func latestPickQueueRepicksTheLatestMoveWhenTheFrameChanged() {
    var queue = Queue()
    let request = queue.move(to: Float2(5, 6), context: 7)!
    // The frame changed while the pick ran: its result is stale, and the same
    // move is picked again against the current frame.
    let changed = queue.finish(request, current: 8)
    #expect(changed.outcome == .stale)
    #expect(changed.next == Queue.Request(move: 1, pixel: Float2(5, 6), context: 8))
    #expect(queue.finish(changed.next!, current: 8).outcome == .apply)
    // An answered move stays answered: a later frame change starts nothing.
    #expect(queue.isIdle)
    let next = queue.move(to: Float2(5, 6), context: 9)
    #expect(next?.move == 2)
}

@Test func latestPickQueueCancelDropsThePickInFlightAndPicksNothingMore() {
    var queue = Queue()
    let request = queue.move(to: Float2(1, 2), context: 0)!
    #expect(queue.move(to: Float2(3, 4), context: 0) == nil)
    queue.cancel()
    let finished = queue.finish(request, current: 0)
    #expect(finished.outcome == .stale)
    #expect(finished.next == nil)
    #expect(queue.isIdle)
}

@Test func pickMailboxHandsResultsOverInOrderAndWakesAWaiter() {
    let mailbox = PickMailbox<Int>()
    #expect(mailbox.take() == nil)
    #expect(!mailbox.waitForDelivery(timeout: 0.01))
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
        mailbox.deliver(1, RenderPickResult(id: 10))
        mailbox.deliver(2, RenderPickResult(id: 20, gpuTime: 0.001))
    }
    #expect(mailbox.waitForDelivery(timeout: 5))
    #expect(eventually { mailbox.take().map { $0.request == 1 && $0.result.id == 10 } ?? false })
    #expect(mailbox.waitForDelivery(timeout: 5))
    let second = mailbox.take()
    #expect(second?.request == 2 && second?.result == RenderPickResult(id: 20, gpuTime: 0.001))
    // The second delivery's signal is left over; a wait still reports the empty box.
    #expect(!mailbox.waitForDelivery(timeout: 0.01))
}

/// GPU pick tests, one at a time: each compiles the production shaders.
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct PickTests {
    static let size = (192, 144)

    /// The scissored pick (synchronous and asynchronous) returns the id the
    /// whole, unscissored pick pass writes at that pixel: at every pixel where
    /// the id changes (edges, where rasterization and the body mask's
    /// derivatives decide) and on a grid, covering gizmo axes and plane
    /// handles, the rotate rings, a bone handle, the character, the masked
    /// and transparent items and the background.
    @Test func scissoredPickMatchesTheWholePickPassAtEveryTestedPixel() throws {
        let renderer = try makeSourceShaderRenderer()
        let scene = try PickScene(renderer: renderer)
        defer { scene.assets.remove() }
        let (w, h) = Self.size
        let reference = try #require(renderer.pickTarget(frame: scene.frame, size: Self.size))
        #expect(renderer.lastDeformationErrors.isEmpty)
        func id(_ x: Int, _ y: Int) -> UInt32 { reference[y * w + x] }

        // Every kind of target is on screen.
        let ids = Set(reference)
        let expected: Set<UInt32> = [0, 1, 2, 3, PickIDs.bone(7)]
            .union([GizmoAxis.x, .y, .z, .xy, .yz, .xz].map(PickIDs.gizmo))
        #expect(expected.isSubset(of: ids), "missing \(expected.subtracting(ids).map { String($0, radix: 16) })")
        // The mask discards part of its quad: id 2 appears in pieces, so its
        // coverage is not the quad's full silhouette (checked by count below).
        let maskedPixels = reference.filter { $0 == 2 }.count
        #expect(maskedPixels > 20)

        var pixels: [(Int, Int)] = []
        for y in 0..<h {
            for x in 0..<w {
                let edge = (x + 1 < w && id(x, y) != id(x + 1, y)) || (y + 1 < h && id(x, y) != id(x, y + 1))
                    || (x > 0 && id(x, y) != id(x - 1, y)) || (y > 0 && id(x, y) != id(x, y - 1))
                if edge || (x % 9 == 4 && y % 9 == 4) { pixels.append((x, y)) }
            }
        }
        // The corners, which clamp exactly at the target's edge.
        pixels += [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
        var mismatches: [String] = []
        var seen = Set<UInt32>()
        for (index, (x, y)) in pixels.enumerated() {
            // Pixel centers and an off-center point inside the same pixel.
            let point = index % 2 == 0 ? Float2(Float(x) + 0.5, Float(y) + 0.5) : Float2(Float(x) + 0.9, Float(y) + 0.1)
            let picked = renderer.pick(frame: scene.frame, pixel: point, size: Self.size)
            seen.insert(picked)
            if picked != id(x, y) { mismatches.append("(\(x), \(y)): \(String(picked, radix: 16)) != \(String(id(x, y), radix: 16))") }
        }
        #expect(pixels.count > 500)
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(pixels.count) pixels: \(mismatches.prefix(10))")
        #expect(expected.isSubset(of: seen))
        // Out-of-range pixels clamp to the edge, as before.
        #expect(renderer.pick(frame: scene.frame, pixel: Float2(-5, -5), size: Self.size) == id(0, 0))
        #expect(renderer.pick(frame: scene.frame, pixel: Float2(1e6, 1e6), size: Self.size) == id(w - 1, h - 1))

        // The asynchronous pick encodes the same pass: same ids, and a GPU time.
        var asyncMismatches: [String] = []
        for (x, y) in pixels.enumerated().filter({ $0.offset % 7 == 0 }).map(\.element) {
            let result = try #require(pickAsync(renderer, scene.frame, Float2(Float(x) + 0.5, Float(y) + 0.5), Self.size))
            if result.id != id(x, y) { asyncMismatches.append("(\(x), \(y))") }
            #expect(result.gpuTime > 0)
        }
        #expect(asyncMismatches.isEmpty, "\(asyncMismatches)")
        // An empty viewport picks nothing, synchronously and asynchronously.
        #expect(renderer.pick(frame: scene.frame, pixel: Float2(1, 1), size: (0, 0)) == 0)
        #expect(pickAsync(renderer, scene.frame, Float2(1, 1), (0, 0)) == RenderPickResult(id: 0))
    }

    /// Asynchronous picks driven through `LatestPickQueue`, the way the
    /// Studio's hover runs them: a result for an older move or an older frame
    /// is dropped, never applied, and the latest move is picked again against
    /// the current frame. What applies equals the synchronous pick.
    @Test func staleAsynchronousPicksAreDroppedAndTheLatestMoveApplies() throws {
        let renderer = try makeSourceShaderRenderer()
        let scene = try PickScene(renderer: renderer)
        defer { scene.assets.remove() }
        let (w, _) = Self.size
        let reference = try #require(renderer.pickTarget(frame: scene.frame, size: Self.size))
        let axisPixel = try #require(reference.firstIndex(of: PickIDs.gizmo(.x)))
        let backgroundPixel = try #require(reference.firstIndex(of: 0))
        func point(_ index: Int) -> Float2 { Float2(Float(index % w) + 0.5, Float(index / w) + 0.5) }

        // Frame 2 moves the gizmos away: the axis pixel no longer picks the x axis.
        var moved = scene.frame
        moved.gizmos = moved.gizmos.map { var g = $0; g.model = Transform.trs(Float3(0, -5, 0), .identity, Float3(repeating: 1)) * g.model; return g }
        let frames = [1: scene.frame, 2: moved]
        let movedID = renderer.pick(frame: moved, pixel: point(axisPixel), size: Self.size)
        #expect(movedID != PickIDs.gizmo(.x))

        let mailbox = PickMailbox<Queue.Request>()
        let completions = OSAllocatedUnfairLock(initialState: 0)
        var queue = Queue()
        var currentFrame = 1
        var applied: [(request: Queue.Request, id: UInt32)] = []
        func start(_ request: Queue.Request) {
            renderer.pick(frame: frames[request.context]!, pixel: request.pixel, size: Self.size) { result in
                completions.withLock { $0 += 1 }
                mailbox.deliver(request, result)
            }
        }
        func settle() throws {
            while !queue.isIdle {
                try #require(mailbox.waitForDelivery(timeout: 10))
                let finished = try #require(mailbox.take())
                let (outcome, next) = queue.finish(finished.request, current: currentFrame)
                if outcome == .apply { applied.append((finished.request, finished.result.id)) }
                if let next { start(next) }
            }
        }

        // Over the axis, then straight to the background: the axis result is
        // stale even though its pick ran, and only the background applies.
        start(try #require(queue.move(to: point(axisPixel), context: currentFrame)))
        #expect(queue.move(to: point(backgroundPixel), context: currentFrame) == nil)
        try settle()
        #expect(applied.count == 1)
        #expect(applied.last?.request.pixel == point(backgroundPixel))
        #expect(applied.last?.id == 0)
        #expect(queue.statistics.stale == 1 && queue.statistics.coalesced == 1)

        // Over the axis, then the frame changes while the pick runs: the frame-1
        // result is dropped and the move is picked again against frame 2.
        let request = try #require(queue.move(to: point(axisPixel), context: currentFrame))
        currentFrame = 2
        start(request)
        try settle()
        #expect(applied.count == 2)
        #expect(applied.last?.request.context == 2)
        #expect(applied.last?.id == movedID)
        #expect(queue.statistics.stale == 2)

        // Back on frame 1, the axis applies and equals the synchronous pick.
        currentFrame = 1
        start(try #require(queue.move(to: point(axisPixel), context: currentFrame)))
        try settle()
        #expect(applied.last?.id == PickIDs.gizmo(.x))
        #expect(applied.last?.id == renderer.pick(frame: scene.frame, pixel: point(axisPixel), size: Self.size))
        // Every pick completed exactly once: five issued, five completions.
        #expect(queue.statistics.issued == 5)
        #expect(completions.withLock { $0 } == 5)
        #expect(mailbox.take() == nil)
    }
}
