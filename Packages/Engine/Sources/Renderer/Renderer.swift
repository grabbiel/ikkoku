import Foundation
import Metal
import QuartzCore
import CoreGraphics
import simd
import CoreMath
import GPU
import Assets
import Scene
import ShaderTypes

/// Limit and uniform-storage counters of the most recently prepared frame: the
/// last interactive draw, pick, capture or benchmark sample, whichever ran last.
public struct RenderFrameStatistics: Sendable, Equatable {
    /// Enabled `RenderFrame.lights`.
    public var enabledLights = 0
    /// Enabled lights that were shaded: the first `IK_MAX_LIGHTS` in list order.
    public var shadedLights = 0
    /// Enabled lights left unshaded because the frame exceeded `IK_MAX_LIGHTS`.
    public var droppedLights: Int { enabledLights - shadedLights }
    /// Deform dispatches and the meaningful morph entries they accumulate.
    public var deformDispatches = 0
    public var activeMorphEntries = 0
    /// Largest entry list of one dispatch. Lists above `IK_MAX_ACTIVE_MORPHS` are
    /// accumulated in full, not truncated.
    public var largestActiveMorphSet = 0
    /// Where the frame's uniforms were placed. Nonzero overflow means the frame
    /// needed more than its ring region, or found every region still in flight.
    public var uniforms = FrameRing.Statistics()
    public init() {}
}

/// Why the renderer skipped (interactive draw) or failed (pick, capture, benchmark)
/// a frame. Invalid skin bindings are reported in `Renderer.lastDeformationErrors`.
public enum RenderFrameError: Error, Equatable, CustomStringConvertible {
    case commandBufferUnavailable
    case renderTargetsUnavailable(width: Int, height: Int)
    case readbackUnavailable
    case uniformAllocation(FrameRingError)

    public var description: String {
        switch self {
        case .commandBufferUnavailable: return "Metal did not provide a command buffer."
        case let .renderTargetsUnavailable(width, height): return "Could not allocate \(width)x\(height) render targets."
        case .readbackUnavailable: return "Could not allocate the pick readback buffer."
        case let .uniformAllocation(error): return "Frame uniforms: \(error)"
        }
    }
}

/// Debounced status-line text for renderer problems an editor should show: a
/// skipped frame (`Renderer.lastFrameError`) or unshaded lights
/// (`RenderFrameStatistics.droppedLights`). The app polls it from its editor
/// timer, not from the draw. A new problem shows at once, and the line is written
/// again only when the problem text changes. Once frames have rendered without a
/// problem for `clearDelay` seconds, the status it replaced comes back. If other
/// code wrote the status line meanwhile, that text is kept, and the same problem
/// is not written over it again.
public struct RenderStatusReporter: Sendable {
    public static let clearDelay: Double = 1
    private var shown: String?
    private var replaced = ""
    private var lastProblem: String?
    private var healthySince: Double?

    public init() {}

    /// The problem text for one frame's outcome, or nil when it rendered fully.
    public static func message(error: RenderFrameError?, statistics: RenderFrameStatistics) -> String? {
        if let error { return "Renderer skipped a frame: \(error)" }
        let dropped = statistics.droppedLights
        guard dropped > 0 else { return nil }
        let lights = dropped == 1 ? "1 enabled light is" : "\(dropped) enabled lights are"
        return "\(lights) not shaded: frames shade at most \(IK_MAX_LIGHTS) lights."
    }

    /// The new status-line text, or nil to leave `current` unchanged. `now` is in seconds.
    public mutating func status(current: String, error: RenderFrameError?, statistics: RenderFrameStatistics,
                                now: Double) -> String? {
        if let shown, current != shown { self.shown = nil }
        guard let problem = Self.message(error: error, statistics: statistics) else {
            guard lastProblem != nil else { return nil }
            guard let since = healthySince else { healthySince = now; return nil }
            guard now - since >= Self.clearDelay else { return nil }
            let restore = shown != nil ? replaced : nil
            shown = nil; lastProblem = nil; healthySince = nil
            return restore
        }
        healthySince = nil
        guard problem != lastProblem else { return nil }
        if shown == nil { replaced = current }
        shown = problem; lastProblem = problem
        return problem
    }
}

/// Frame graph: deform → shadow → toon+outline → transparent → post → overlay.
public final class Renderer: @unchecked Sendable {
    public static let shadowMapSize = 2048

    public let gpu: GPUContext
    public let resources: ResourceStore
    let pipelines: Pipelines
    let frameRing: FrameRing
    let shadowMap: any MTLTexture

    private let renderLock = NSLock()
    private let frameLock = NSLock()
    private var pendingFrame = RenderFrame()
    private var targets: RenderTargets?
    private var frameIndex = 0
    public private(set) var lastFrameGPUTime: Double = 0
    /// Invalid skin bindings are skipped during interactive rendering; captures fail.
    public private(set) var lastDeformationErrors: [String] = []
    /// Live source-shader draws encoded by the last prepared frame, and any
    /// item that fell back to its native toon draw at render time (with why).
    public internal(set) var lastSourceShaderLive = SourceShaderLiveFrameReport()
    var liveEncoder: SourceShaderLiveEncoder?
    var liveEncoderError: String?

    private let statusLock = NSLock()
    private var publishedStatistics = RenderFrameStatistics()
    private var publishedError: RenderFrameError?
    /// Counters of the most recently prepared frame (see `RenderFrameStatistics`).
    public var lastFrameStatistics: RenderFrameStatistics {
        statusLock.lock(); defer { statusLock.unlock() }; return publishedStatistics
    }
    /// Nil when the most recent frame was encoded; otherwise why it was skipped or failed.
    public var lastFrameError: RenderFrameError? {
        statusLock.lock(); defer { statusLock.unlock() }; return publishedError
    }

    /// Loads the bundled `IkkokuShaders.metallib`.
    public convenience init(gpu: GPUContext) throws {
        let library = try gpu.makeShaderLibrary()
        try self.init(gpu: gpu, shaderLibrary: library)
    }

    /// Uses an explicit shader library, for example one compiled from `Shaders/` in tests.
    public init(gpu: GPUContext, shaderLibrary: any MTLLibrary) throws {
        self.gpu = gpu
        self.resources = ResourceStore(device: gpu.device)
        self.pipelines = try Pipelines(gpu: gpu, library: shaderLibrary)
        guard let ring = FrameRing(device: gpu.device) else { throw RendererError.frameRingCreationFailed }
        self.frameRing = ring
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Pipelines.depthFormat, width: Renderer.shadowMapSize, height: Renderer.shadowMapSize, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .private
        guard let sm = gpu.device.makeTexture(descriptor: sd) else { throw RendererError.textureCreationFailed }
        sm.label = "ShadowMap"
        self.shadowMap = sm
    }

    // MARK: - Frame hand-off

    public func submit(_ frame: RenderFrame) {
        var snapshot = frame
        snapshot.retainTextures(from: resources)
        snapshot.submitted = true
        frameLock.lock(); pendingFrame = snapshot; frameLock.unlock()
    }
    public func currentFrame() -> RenderFrame { frameLock.lock(); defer { frameLock.unlock() }; return pendingFrame }

    // MARK: - Drawing to the swapchain

    public func draw(to drawable: any CAMetalDrawable, timestamp: CFTimeInterval) {
        let tex = drawable.texture
        guard tex.width > 0, tex.height > 0 else { return }
        var frame = currentFrame()
        frame.time = timestamp
        gpu.waitForFrameSlot()
        guard let cb = gpu.commandQueue.makeCommandBuffer() else {
            publish(error: .commandBufferUnavailable); gpu.releaseFrameSlot(); return
        }
        cb.label = "Frame"
        renderLock.lock()
        var encoded = false
        if let targets = ensureTargets(width: tex.width, height: tex.height) {
            frameRing.beginFrame(frameIndex); frameIndex &+= 1
            do {
                try encode(frame: frame, target: tex, targets: targets, commandBuffer: cb)
                frameRing.endFrame(retainedUntilCompletionOf: cb)
                encoded = true
            } catch {
                // `prepare` failed before any encoder existed and published the error.
                frameRing.abandonFrame()
            }
        } else {
            publish(error: .renderTargetsUnavailable(width: tex.width, height: tex.height))
        }
        renderLock.unlock()
        // A skipped frame keeps the previously presented image rather than
        // presenting a drawable nothing was rendered into.
        guard encoded else { gpu.releaseFrameSlot(); return }
        cb.addCompletedHandler { [weak self] c in
            self?.lastFrameGPUTime = c.gpuEndTime - c.gpuStartTime
        }
        gpu.releaseFrameSlot(onCompletionOf: cb)
        cb.present(drawable)
        cb.commit()
    }

    /// Runs `body` under the render lock (live validation captures).
    func renderLockedLive(_ body: () -> Void) { renderLock.lock(); body(); renderLock.unlock() }
    /// Opens a frame-ring frame for an offscreen frame; close it with
    /// `frameRing.endFrame(retainedUntilCompletionOf:)` or `abandonFrame()`.
    func frameRingBegin() { frameRing.beginFrame(frameIndex); frameIndex &+= 1 }

    private func ensureTargets(width: Int, height: Int) -> RenderTargets? {
        if let t = targets, t.width == width, t.height == height { return t }
        targets = try? RenderTargets(device: gpu.device, width: width, height: height)
        return targets
    }

    // MARK: - Picking

    /// Returns the object id under a pixel (0 = nothing). Synchronous; a few milliseconds.
    public func pick(frame: RenderFrame, pixel: Float2, size: (Int, Int)) -> UInt32 {
        gpu.waitForFrameSlot()
        defer { gpu.releaseFrameSlot() }
        guard let cb = gpu.commandQueue.makeCommandBuffer() else { publish(error: .commandBufferUnavailable); return 0 }
        guard let readback = gpu.device.makeBuffer(length: 16, options: .storageModeShared) else {
            publish(error: .readbackUnavailable); return 0
        }
        renderLock.lock()
        guard let targets = ensureTargets(width: size.0, height: size.1) else {
            renderLock.unlock(); publish(error: .renderTargetsUnavailable(width: size.0, height: size.1)); return 0
        }
        frameRing.beginFrame(frameIndex); frameIndex &+= 1
        guard let ctx = try? prepare(frame: frame, targets: targets, forPick: true), lastDeformationErrors.isEmpty else {
            frameRing.abandonFrame(); renderLock.unlock(); return 0
        }
        encodeDeform(ctx, cb)
        encodePick(ctx, targets: targets, cb)
        let x = min(max(Int(pixel.x), 0), size.0 - 1), y = min(max(Int(pixel.y), 0), size.1 - 1)
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: targets.pick, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                      sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: readback, destinationOffset: 0, destinationBytesPerRow: 4, destinationBytesPerImage: 4)
            blit.endEncoding()
        }
        frameRing.endFrame(retainedUntilCompletionOf: cb)
        renderLock.unlock()
        cb.commit()
        cb.waitUntilCompleted()
        return readback.contents().load(as: UInt32.self)
    }

    // MARK: - Offscreen capture

    public func capture(frame: RenderFrame, width: Int, height: Int) -> CGImage? {
        capture(frame: frame, width: width, height: height, configureTargets: nil)
    }

    /// `capture` with a hook on the fresh render targets before encoding
    /// (tests inject target failures through it).
    func capture(frame: RenderFrame, width: Int, height: Int, configureTargets: ((RenderTargets) -> Void)?) -> CGImage? {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        gpu.waitForFrameSlot()
        defer { gpu.releaseFrameSlot() }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Pipelines.ldrFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = gpu.device.makeTexture(descriptor: d) else {
            publish(error: .renderTargetsUnavailable(width: width, height: height)); return nil
        }
        guard let cb = gpu.commandQueue.makeCommandBuffer() else { publish(error: .commandBufferUnavailable); return nil }
        renderLock.lock()
        guard let targets = try? RenderTargets(device: gpu.device, width: width, height: height) else {
            renderLock.unlock(); publish(error: .renderTargetsUnavailable(width: width, height: height)); return nil
        }
        configureTargets?(targets)
        frameRing.beginFrame(frameIndex); frameIndex &+= 1
        var encoded = true
        do { try encode(frame: frame, target: tex, targets: targets, commandBuffer: cb) } catch { encoded = false }
        let validDeformation = lastDeformationErrors.isEmpty
        if encoded && validDeformation { frameRing.endFrame(retainedUntilCompletionOf: cb) } else { frameRing.abandonFrame() }
        renderLock.unlock()
        guard encoded, validDeformation else { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { tex.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: cs,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Measures the same pass graph as capture while reusing all render targets.
    /// Each command buffer completes before the next sample. This is a render
    /// latency baseline, not an interactive application throughput measurement.
    public func benchmark(frame: RenderFrame, width: Int, height: Int,
                          warmupFrames: Int = 3, measuredFrames: Int = 20) throws -> RenderBenchmark {
        guard (1...8192).contains(width), (1...8192).contains(height),
              (0...100).contains(warmupFrames), (1...1000).contains(measuredFrames) else {
            throw RenderBenchmarkError.invalidConfiguration
        }
        let before = RenderBenchmark.residentBytes()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Pipelines.ldrFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .private
        guard let target = gpu.device.makeTexture(descriptor: descriptor) else { throw RendererError.textureCreationFailed }
        let targets = try RenderTargets(device: gpu.device, width: width, height: height)
        var cpu: [Double] = [], completion: [Double] = [], gpuTimes: [Double] = []
        for sample in 0..<(warmupFrames + measuredFrames) {
            try autoreleasepool {
                gpu.waitForFrameSlot(); defer { gpu.releaseFrameSlot() }
                guard let cb = gpu.commandQueue.makeCommandBuffer() else { throw RenderBenchmarkError.commandBuffer }
                cb.label = "Benchmark \(sample)"
                renderLock.lock()
                let start = CACurrentMediaTime()
                frameRing.beginFrame(frameIndex); frameIndex &+= 1
                var failure: RenderFrameError?
                do { try encode(frame: frame, target: target, targets: targets, commandBuffer: cb) }
                catch { failure = (error as? RenderFrameError) ?? .commandBufferUnavailable }
                let errors = lastDeformationErrors
                // Commit under the lock so interactive draws cannot submit after
                // reusing the same deformation buffers but before this frame.
                if failure == nil && errors.isEmpty {
                    frameRing.endFrame(retainedUntilCompletionOf: cb)
                    cb.commit()
                } else {
                    frameRing.abandonFrame()
                }
                let submitted = CACurrentMediaTime()
                renderLock.unlock()
                if let failure { throw RenderBenchmarkError.frame(failure) }
                guard errors.isEmpty else { throw RenderBenchmarkError.deformation(errors) }
                cb.waitUntilCompleted()
                let end = CACurrentMediaTime()
                guard cb.status == .completed else { throw RenderBenchmarkError.gpu(cb.error?.localizedDescription ?? "Command failed") }
                if sample >= warmupFrames {
                    cpu.append((submitted - start) * 1000); completion.append((end - start) * 1000)
                    if cb.gpuEndTime > cb.gpuStartTime, cb.gpuStartTime > 0 { gpuTimes.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
                }
            }
        }
        let visible = frame.items.filter(\.visible)
        let meshes = visible.compactMap { resources.mesh($0.mesh) }
        var unique = Set<UInt32>()
        let vertices = visible.reduce(0) { total, item in
            total + (unique.insert(item.mesh.id).inserted ? (resources.mesh(item.mesh)?.vertexCount ?? 0) : 0)
        }
        return RenderBenchmark(device: gpu.device.name, width: width, height: height,
            warmupFrames: warmupFrames, measuredFrames: measuredFrames, cpuEncodeMilliseconds: .init(cpu),
            completionMilliseconds: .init(completion), gpuMilliseconds: gpuTimes.count == measuredFrames ? .init(gpuTimes) : nil,
            residentBytesBefore: before, residentBytesAfter: RenderBenchmark.residentBytes(), metalAllocatedBytes: gpu.device.currentAllocatedSize,
            visibleItems: visible.count, missingMeshes: visible.count - meshes.count,
            drawnTriangles: meshes.reduce(0) { $0 + $1.indexCount / 3 }, uniqueVertices: vertices, resources: resources.statistics())
    }

    // MARK: - Frame preparation

    struct DrawRecord {
        let item: RenderItem
        let mesh: GPUMesh
        let vertexBuffer: any MTLBuffer
        let hiddenBuffer: (any MTLBuffer)?
        let draw: FrameAllocation
        let material: FrameAllocation
        let distance: Float
    }

    struct DeformRecord {
        let key: UInt64
        let mesh: GPUMesh
        let buffer: any MTLBuffer
        let skinBuffer: (any MTLBuffer)?
        let boneCount: Int
        let morphs: FrameAllocation
        let morphCount: Int
    }

    struct GizmoRecord {
        let batch: GizmoBatch
        let vertices: FrameAllocation
        let draw: FrameAllocation
    }

    /// Every ring allocation of a frame happens while preparing it, before any
    /// encoder exists, so a failed allocation leaves the command buffer empty.
    struct FrameContext {
        let frame: RenderFrame
        let frameUniforms: FrameAllocation
        let lights: FrameAllocation
        let post: FrameAllocation
        let background: FrameAllocation?
        let opaque: [DrawRecord]
        let transparent: [DrawRecord]
        let shadowCasters: [DrawRecord]
        let deforms: [DeformRecord]
        let gizmos: [GizmoRecord]
        let width: Int
        let height: Int
        /// Live source-shader draws in source queue order; empty unless an
        /// item carries `sourceShader`.
        var live: [LiveRecord] = []
        /// The stencil-capable main pass, set exactly when `live` is non-empty.
        var liveMainPass: LiveMainPass? = nil
    }

    /// What a main pass with live source-shader draws needs beyond the
    /// depth-only pass: stencil-capable pipelines and the MSAA depth-stencil
    /// target. Both are resolved in `prepare`, so a failure returns the live
    /// items to their toon draws with a reported reason instead of dropping them.
    struct LiveMainPass {
        let pipelines: Pipelines.MainPass
        let depthStencil: any MTLTexture
    }

    /// Enabled lights in list order. Only the first `IK_MAX_LIGHTS` fit
    /// `LightsUniforms`; `enabled` counts all of them so the rest can be reported.
    static func packLights(_ lights: [SceneLight]) -> (uniforms: LightsUniforms, enabled: Int) {
        var lu = LightsUniforms()
        var count = 0
        var enabled = 0
        withUnsafeMutableBytes(of: &lu.lights) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: LightUniform.self)
            for l in lights where l.enabled {
                enabled += 1
                guard count < Int(IK_MAX_LIGHTS) else { continue }
                var u = LightUniform()
                let type: Float = l.kind == .directional ? 0 : (l.kind == .point ? 1 : 2)
                u.position = Float4(l.position.x, l.position.y, l.position.z, type)
                let d = l.direction
                u.direction = Float4(d.x, d.y, d.z, l.range)
                let c = l.color * l.intensity
                let outer = cos(l.spotAngle.degreesToRadians * 0.5)
                let inner = cos(l.spotAngle.degreesToRadians * 0.5 * (1 - l.spotBlend * 0.9))
                u.color = Float4(c.x, c.y, c.z, outer)
                u.params = Float4(inner, 1, 0, 0)
                p[count] = u
                count += 1
            }
        }
        lu.count = UInt32(count)
        return (lu, enabled)
    }

    /// Meaningful morph entries in caller order: an index inside the mesh's targets
    /// and a finite weight above 1e-4 in magnitude. The deform kernel reads its
    /// entries from an unbounded device buffer, so one dispatch accumulates all of
    /// them; nothing is truncated at `IK_MAX_ACTIVE_MORPHS`.
    static func activeMorphEntries(_ weights: [(index: Int, weight: Float)], targetCount: Int) -> [MorphWeightEntry] {
        weights.compactMap { entry -> MorphWeightEntry? in
            guard entry.index >= 0, entry.index < targetCount, entry.weight.isFinite, abs(entry.weight) > 1e-4 else { return nil }
            return MorphWeightEntry(index: UInt32(entry.index), weight: entry.weight)
        }
    }

    private func publish(statistics: RenderFrameStatistics? = nil, error: RenderFrameError?) {
        statusLock.lock()
        if let statistics { publishedStatistics = statistics }
        publishedError = error
        statusLock.unlock()
    }

    /// Prepares a frame and publishes its statistics and error. Throws only
    /// `RenderFrameError.uniformAllocation`; nothing has been encoded by then.
    func prepare(frame input: RenderFrame, targets: RenderTargets, forPick: Bool = false) throws -> FrameContext {
        // A submitted frame created after a retirement replaced every pending frame
        // that could still name the retired resources (`ResourceStore.retire`).
        if input.submitted { resources.completeRetirements(createdBefore: input.createdAt) }
        var statistics = RenderFrameStatistics()
        do {
            let context = try buildContext(frame: input, targets: targets, forPick: forPick, statistics: &statistics)
            statistics.uniforms = frameRing.frameStatistics
            publish(statistics: statistics, error: nil)
            return context
        } catch let error as FrameRingError {
            statistics.uniforms = frameRing.frameStatistics
            publish(statistics: statistics, error: .uniformAllocation(error))
            throw RenderFrameError.uniformAllocation(error)
        }
    }

    private func buildContext(frame input: RenderFrame, targets: RenderTargets, forPick: Bool,
                              statistics: inout RenderFrameStatistics) throws -> FrameContext {
        var frame = input
        frame.retainTextures(from: resources)
        lastDeformationErrors = []
        let W = targets.width, H = targets.height
        let fw = Float(W), fh = Float(H)
        let cam = frame.camera
        let view = cam.viewMatrix()
        let proj = cam.projectionMatrix(aspect: fw / fh)
        let vp = proj * view
        let fx = frame.effects

        var fu = FrameUniforms()
        fu.viewProjection = vp
        fu.view = view
        fu.projection = proj
        fu.inverseView = view.inverse
        fu.inverseViewProjection = vp.inverse
        let toLight = -frame.mainLight.direction(camera: cam)
        let b = frame.sceneBounds
        let center = b.isEmpty ? Float3(0, 1, 0) : b.center
        let r = max(b.isEmpty ? 1.5 : b.radius, 1.0)
        let lview = Projection.lookAt(eye: center + toLight * (r * 3), center: center, up: Float3(0, 1, 0))
        let lproj = Projection.orthographicReverseZ(left: -r, right: r, bottom: -r, top: r, near: 0.05, far: r * 6)
        fu.shadowViewProjection = lproj * lview
        let cp = cam.position
        fu.cameraPosition = Float4(cp.x, cp.y, cp.z, 1)
        fu.viewport = Float4(fw, fh, 1 / fw, 1 / fh)
        fu.mainLightDirection = Float4(toLight.x, toLight.y, toLight.z, frame.mainLight.castsShadow ? frame.mainLight.shadowStrength : 0)
        let lc = frame.mainLight.color * frame.mainLight.intensity
        fu.mainLightColor = Float4(lc.x, lc.y, lc.z, 1)
        fu.ambientSky = Float4(fx.ambientSky.x, fx.ambientSky.y, fx.ambientSky.z, 1)
        fu.ambientGround = Float4(fx.ambientGround.x, fx.ambientGround.y, fx.ambientGround.z, 1)
        fu.shadowParams = Float4(1 / Float(Renderer.shadowMapSize), 0.0012, 0.0025, fx.shadowSoftness)
        fu.fogColor = Float4(fx.fogColor.x, fx.fogColor.y, fx.fogColor.z, fx.fogEnabled ? 1 : 0)
        fu.fogRange = Float4(fx.fogStart, fx.fogEnd, 0, 0)
        let resScale = fh / 1080
        fu.outlineParams = Float4(fx.outlineWidth * resScale, 0, 10 * resScale, 0)
        fu.time = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        fu.nearPlane = cam.near
        fu.exposure = fx.exposure
        let frameUniforms = try frameRing.allocate(fu)

        let packedLights = Renderer.packLights(frame.lights)
        statistics.enabledLights = packedLights.enabled
        statistics.shadedLights = Int(packedLights.uniforms.count)
        let lights = try frameRing.allocate(packedLights.uniforms)

        var pp = PostParams()
        pp.bloom = Float4(fx.bloomThreshold, fx.bloomIntensity, fx.bloomRadius, 0)
        pp.vignette = Float4(fx.vignetteEnabled ? fx.vignetteIntensity : 0, fx.vignetteSmoothness, fw / fh, 0)
        pp.grade = Float4(fx.exposure, fx.contrast, fx.saturation, fx.temperature)
        pp.texel = Float4(1 / fw, 1 / fh, fw, fh)
        pp.flags = (fx.fxaa ? 1 : 0) | (fx.bloomEnabled ? 2 : 0) | (fx.vignetteEnabled ? 4 : 0) | 8 | ((fx.toneMappingEnabled ?? true) ? 16 : 0)
        let post = try frameRing.allocate(pp)
        var background: FrameAllocation?
        if !forPick && !fx.transparentBackground {
            var bgFrame = FrameUniforms()
            bgFrame.ambientSky = Float4(fx.backgroundTop.x, fx.backgroundTop.y, fx.backgroundTop.z, 1)
            bgFrame.ambientGround = Float4(fx.backgroundBottom.x, fx.backgroundBottom.y, fx.backgroundBottom.z, 1)
            background = try frameRing.allocate(bgFrame)
        }

        // Retained per-frame buffers preserve the complete palette without consuming
        // the fixed-capacity uniform ring. Command buffers retain their resources.
        var skinBuffers: [UInt64: (buffer: any MTLBuffer, count: Int)] = [:]
        let referencedSkinSets = Set(frame.items.compactMap { item -> UInt64? in
            guard item.visible, resources.mesh(item.mesh)?.skin != nil else { return nil }
            return item.skinSet
        })
        for (key, mats) in frame.skinSets where referencedSkinSets.contains(key) {
            guard !mats.isEmpty, mats.count <= Int(UInt32.max), mats.allSatisfy({ m in
                (0..<4).allSatisfy { c in (0..<4).allSatisfy { r in m[c][r].isFinite } }
            }) else {
                lastDeformationErrors.append("Skin set \(key) is empty, oversized, or contains nonfinite matrices")
                continue
            }
            guard let buffer = gpu.device.makeBuffer(bytes: mats, length: MemoryLayout<float4x4>.stride * mats.count,
                                                     options: .storageModeShared) else {
                lastDeformationErrors.append("Could not allocate skin set \(key)")
                continue
            }
            buffer.label = "Skin set \(key)"
            skinBuffers[key] = (buffer, mats.count)
        }

        var opaque: [DrawRecord] = []
        var transparent: [DrawRecord] = []
        var casters: [DrawRecord] = []
        var deforms: [DeformRecord] = []
        var deformSeen = Set<UInt64>()
        var liveCandidates: [DrawRecord] = []

        for item in frame.items where item.visible {
            guard let mesh = resources.mesh(item.mesh) else { continue }
            let palette = item.skinSet.flatMap { skinBuffers[$0] }
            if mesh.skin != nil, let key = item.skinSet {
                do {
                    guard item.deformKey != nil, let palette else {
                        throw ResourceError.invalidSkin("\(mesh.name): missing deformation key or skin set \(key)")
                    }
                    try mesh.validateSkinPalette(boneCount: palette.count)
                } catch {
                    lastDeformationErrors.append(String(describing: error))
                    continue
                }
            }
            var vb: any MTLBuffer = mesh.baseVertices
            if let key = item.deformKey, mesh.needsDeform {
                guard let buf = resources.deformBuffer(for: key, vertexCount: mesh.vertexCount, frameCreatedAt: frame.createdAt) else {
                    lastDeformationErrors.append("\(mesh.name): could not allocate deformation buffer \(key)")
                    continue
                }
                vb = buf
                if !deformSeen.contains(key) {
                    deformSeen.insert(key)
                    let entries = Renderer.activeMorphEntries(item.morphWeights, targetCount: mesh.morphNames.count)
                    let morphs = try frameRing.allocate(array: entries)
                    let skin = mesh.skin != nil ? palette : nil
                    deforms.append(DeformRecord(key: key, mesh: mesh, buffer: buf, skinBuffer: skin?.buffer,
                                                boneCount: skin?.count ?? 0, morphs: morphs, morphCount: entries.count))
                    statistics.deformDispatches += 1
                    statistics.activeMorphEntries += entries.count
                    statistics.largestActiveMorphSet = max(statistics.largestActiveMorphSet, entries.count)
                }
            }
            let hb = item.hiddenKey.flatMap { resources.hiddenBuffer(key: $0) }.flatMap { $0.length >= mesh.vertexCount ? $0 : nil }
            var du = DrawUniforms()
            du.model = item.model
            du.normalMatrix = Transform.normalMatrix(from: item.model)
            du.objectID = item.objectID
            du.flags = hb != nil ? DrawFlagHasHiddenBuffer : item.hiddenRegions
            du.outlineScale = item.outlineScale
            du.depthBias = item.material.depthBias
            let drawUniforms = try frameRing.allocate(du)
            var mu = item.material.uniforms
            if item.material.transparent { mu.flags |= MaterialFlagAlphaBlend.rawValue }
            else { mu.flags &= ~MaterialFlagAlphaBlend.rawValue }
            if frame.texture(item.material.base, resources: resources) == nil { mu.flags &= ~MaterialFlagHasBaseTexture.rawValue }
            if frame.texture(item.material.bodyMask, resources: resources) == nil { mu.flags &= ~MaterialFlagHasBodyMask.rawValue }
            if mesh.colors != nil { mu.flags |= MaterialFlagHasVertexColor.rawValue } else { mu.flags &= ~MaterialFlagHasVertexColor.rawValue }
            let materialUniforms = try frameRing.allocate(mu)
            let c = item.model.transformPoint(mesh.bounds.center)
            let rec = DrawRecord(item: item, mesh: mesh, vertexBuffer: vb, hiddenBuffer: hb, draw: drawUniforms,
                                 material: materialUniforms, distance: length(c - cp))
            if item.sourceShader != nil { liveCandidates.append(rec) }
            else if item.material.transparent { transparent.append(rec) } else { opaque.append(rec) }
            if item.castsShadow && !item.material.transparent { casters.append(rec) }
        }
        var liveReport = SourceShaderLiveFrameReport()
        var live = liveCandidates.isEmpty ? [] : prepareLive(liveCandidates, deforms: deforms, report: &liveReport, opaque: &opaque, transparent: &transparent)
        var liveMainPass: LiveMainPass?
        if !live.isEmpty {
            do { liveMainPass = LiveMainPass(pipelines: try pipelines.stencilMainPass(), depthStencil: try targets.msaaDepthStencil()) }
            catch {
                // Without the stencil pipelines or the depth-stencil target
                // nothing can draw live: every live item returns to its
                // native draw, reported.
                liveReport.fallbacks += live.map { "\($0.draw.material.label): stencil main pass unavailable (\(error)); drawn toon" }
                liveReport.draws = 0
                for record in live.map(\.record) {
                    if record.item.material.transparent { transparent.append(record) } else { opaque.append(record) }
                }
                live = []
            }
        }
        lastSourceShaderLive = liveReport
        opaque = Self.sortedOpaque(opaque)
        transparent = Self.sortedTransparent(transparent)
        // Display frames draw every non-empty batch once (main pass when depth
        // tested, overlay otherwise); pick frames draw only pickable batches.
        var gizmos: [GizmoRecord] = []
        for g in frame.gizmos where !g.vertices.isEmpty && (!forPick || g.objectID != 0) {
            let vertices = try frameRing.allocate(array: g.vertices)
            var du = DrawUniforms()
            du.model = g.model
            du.normalMatrix = matrix_identity_float4x4
            du.objectID = g.objectID
            let draw = try frameRing.allocate(du)
            gizmos.append(GizmoRecord(batch: g, vertices: vertices, draw: draw))
        }
        return FrameContext(frame: frame, frameUniforms: frameUniforms, lights: lights, post: post, background: background,
                            opaque: opaque, transparent: transparent, shadowCasters: casters, deforms: deforms,
                            gizmos: gizmos, width: W, height: H, live: live, liveMainPass: liveMainPass)
    }

    static func sortedOpaque(_ records: [DrawRecord]) -> [DrawRecord] {
        records.sorted { a, b in
            if a.item.order != b.item.order { return a.item.order < b.item.order }
            if a.item.material.uniforms.kind != b.item.material.uniforms.kind { return a.item.material.uniforms.kind < b.item.material.uniforms.kind }
            return a.item.mesh.id < b.item.mesh.id
        }
    }

    static func sortedTransparent(_ records: [DrawRecord]) -> [DrawRecord] {
        records.sorted {
            if $0.distance != $1.distance { return $0.distance > $1.distance }
            if $0.item.order != $1.item.order { return $0.item.order < $1.item.order }
            return $0.item.mesh.id < $1.item.mesh.id
        }
    }

    // MARK: - Encoding

    private func encode(frame: RenderFrame, target: any MTLTexture, targets: RenderTargets, commandBuffer cb: any MTLCommandBuffer) throws {
        let ctx = try prepare(frame: frame, targets: targets)
        encodeDeform(ctx, cb)
        if !ctx.live.isEmpty { encodeLiveInputs(ctx, cb) }
        encodeShadow(ctx, cb)
        encodeMain(ctx, targets: targets, cb)
        encodePost(ctx, targets: targets, target: target, cb)
        encodeOverlay(ctx, targets: targets, target: target, cb)
    }

    func encodeDeform(_ ctx: FrameContext, _ cb: any MTLCommandBuffer) {
        guard !ctx.deforms.isEmpty, let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "Deform"
        enc.setComputePipelineState(pipelines.deform)
        let dummy = resources.dummyBuffer
        for d in ctx.deforms {
            var params = DeformParams(vertexCount: UInt32(d.mesh.vertexCount), activeMorphCount: UInt32(d.morphCount),
                                      hasSkin: d.skinBuffer != nil ? 1 : 0, hasMorphNormals: d.mesh.morphNormals != nil ? 1 : 0,
                                      boneCount: UInt32(d.boneCount))
            enc.setBuffer(d.mesh.baseVertices, offset: 0, index: Int(BufferIndexBaseVertices.rawValue))
            enc.setBuffer(d.buffer, offset: 0, index: Int(BufferIndexVertices.rawValue))
            enc.setBuffer(d.mesh.skin ?? dummy, offset: 0, index: Int(BufferIndexSkinData.rawValue))
            if let skin = d.skinBuffer { enc.setBuffer(skin, offset: 0, index: Int(BufferIndexSkinMatrices.rawValue)) }
            else { enc.setBuffer(dummy, offset: 0, index: Int(BufferIndexSkinMatrices.rawValue)) }
            enc.setBuffer(d.morphs.buffer, offset: d.morphs.offset, index: Int(BufferIndexMorphWeights.rawValue))
            enc.setBuffer(d.mesh.morphDeltas ?? dummy, offset: 0, index: Int(BufferIndexMorphDeltas.rawValue))
            enc.setBuffer(d.mesh.morphNormals ?? dummy, offset: 0, index: Int(BufferIndexMorphNormals.rawValue))
            enc.setBytes(&params, length: MemoryLayout<DeformParams>.stride, index: Int(BufferIndexDeformParams.rawValue))
            let w = min(pipelines.deform.maxTotalThreadsPerThreadgroup, 64)
            enc.dispatchThreads(MTLSize(width: d.mesh.vertexCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        }
        enc.endEncoding()
    }

    func bindCommon(_ enc: any MTLRenderCommandEncoder, _ ctx: FrameContext) {
        enc.setVertexBuffer(ctx.frameUniforms.buffer, offset: ctx.frameUniforms.offset, index: Int(BufferIndexFrameUniforms.rawValue))
        enc.setFragmentBuffer(ctx.frameUniforms.buffer, offset: ctx.frameUniforms.offset, index: Int(BufferIndexFrameUniforms.rawValue))
        enc.setFragmentBuffer(ctx.lights.buffer, offset: ctx.lights.offset, index: Int(BufferIndexLights.rawValue))
        enc.setFragmentTexture(shadowMap, index: Int(TextureIndexShadowMap.rawValue))
        enc.setFrontFacing(.counterClockwise)
    }

    private func bindDraw(_ enc: any MTLRenderCommandEncoder, _ rec: DrawRecord) {
        // Mirrored scene nodes reverse triangle orientation in every geometry pass.
        enc.setFrontFacing(simd_determinant(rec.item.model.upperLeft3x3) < 0 ? .clockwise : .counterClockwise)
        enc.setVertexBuffer(rec.vertexBuffer, offset: 0, index: Int(BufferIndexVertices.rawValue))
        enc.setVertexBuffer(rec.mesh.texcoords, offset: 0, index: Int(BufferIndexTexcoords.rawValue))
        enc.setVertexBuffer(rec.mesh.texcoords1, offset: 0, index: Int(BufferIndexTexcoords1.rawValue))
        enc.setVertexBuffer(rec.mesh.texcoords2, offset: 0, index: Int(BufferIndexTexcoords2.rawValue))
        enc.setVertexBuffer(rec.mesh.colors ?? resources.dummyBuffer, offset: 0, index: Int(BufferIndexVertexColors.rawValue))
        enc.setVertexBuffer(rec.draw.buffer, offset: rec.draw.offset, index: Int(BufferIndexDrawUniforms.rawValue))
        enc.setVertexBuffer(rec.material.buffer, offset: rec.material.offset, index: Int(BufferIndexMaterial.rawValue))
        enc.setVertexBuffer(rec.hiddenBuffer ?? resources.dummyBuffer, offset: 0, index: Int(BufferIndexVertexHidden.rawValue))
        enc.setFragmentBuffer(rec.draw.buffer, offset: rec.draw.offset, index: Int(BufferIndexDrawUniforms.rawValue))
        enc.setFragmentBuffer(rec.material.buffer, offset: rec.material.offset, index: Int(BufferIndexMaterial.rawValue))
    }

    private func bindTextures(_ enc: any MTLRenderCommandEncoder, _ m: MaterialState, frame: RenderFrame) {
        let white = resources.whiteTexture, black = resources.blackTexture
        enc.setFragmentTexture(frame.texture(m.base, resources: resources) ?? white, index: Int(TextureIndexBase.rawValue))
        enc.setFragmentTexture(frame.texture(m.colorMask, resources: resources) ?? black, index: Int(TextureIndexColorMask.rawValue))
        let isEye = m.uniforms.kind == UInt32(MaterialKindEye.rawValue)
        enc.setFragmentTexture(frame.texture(m.detail, resources: resources) ?? (isEye ? black : white), index: Int(TextureIndexDetail.rawValue))
        enc.setFragmentTexture(frame.texture(m.line, resources: resources) ?? black, index: Int(TextureIndexLine.rawValue))
        enc.setFragmentTexture(frame.texture(m.normal, resources: resources) ?? resources.flatNormalTexture, index: Int(TextureIndexNormal.rawValue))
        enc.setFragmentTexture(frame.texture(m.overlay0, resources: resources) ?? black, index: Int(TextureIndexOverlay0.rawValue))
        enc.setFragmentTexture(frame.texture(m.overlay1, resources: resources) ?? black, index: Int(TextureIndexOverlay1.rawValue))
        enc.setFragmentTexture(frame.texture(m.overlay2, resources: resources) ?? black, index: Int(TextureIndexOverlay2.rawValue))
        enc.setFragmentTexture(frame.texture(m.hairGloss, resources: resources) ?? white, index: Int(TextureIndexHairGloss.rawValue))
        enc.setFragmentTexture(frame.texture(m.pattern, resources: resources) ?? white, index: Int(TextureIndexPattern.rawValue))
        enc.setFragmentTexture(frame.texture(m.bodyMask, resources: resources) ?? black, index: Int(TextureIndexBodyMask.rawValue))
    }

    private func drawIndexed(_ enc: any MTLRenderCommandEncoder, _ mesh: GPUMesh) {
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
    }

    private func encodeShadow(_ ctx: FrameContext, _ cb: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = shadowMap
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Shadow"
        if ctx.frame.mainLight.castsShadow {
            enc.setRenderPipelineState(pipelines.shadow)
            enc.setDepthStencilState(pipelines.depthWrite)
            enc.setCullMode(.none)
            enc.setDepthBias(1.0, slopeScale: 1.5, clamp: 0.01)
            bindCommon(enc, ctx)
            for rec in ctx.shadowCasters {
                bindDraw(enc, rec)
                enc.setFragmentTexture(ctx.frame.texture(rec.item.material.base, resources: resources) ?? resources.whiteTexture, index: Int(TextureIndexBase.rawValue))
                enc.setFragmentTexture(ctx.frame.texture(rec.item.material.bodyMask, resources: resources) ?? resources.blackTexture, index: Int(TextureIndexBodyMask.rawValue))
                drawIndexed(enc, rec.mesh)
            }
        }
        enc.endEncoding()
    }

    private func encodeMain(_ ctx: FrameContext, targets: RenderTargets, _ cb: any MTLCommandBuffer) {
        let fx = ctx.frame.effects
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.msaaColor
        pass.colorAttachments[0].resolveTexture = targets.hdr
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = fx.transparentBackground ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            : MTLClearColor(red: Double(fx.backgroundBottom.x), green: Double(fx.backgroundBottom.y), blue: Double(fx.backgroundBottom.z), alpha: 1)
        pass.depthAttachment.texture = targets.msaaDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 0
        // Live source-shader draws need stencil; frames without them keep the
        // depth-only attachment and pipelines unchanged.
        var main = pipelines.depthOnlyMainPass
        if let liveMain = ctx.liveMainPass {
            main = liveMain.pipelines
            pass.depthAttachment.texture = liveMain.depthStencil
            pass.stencilAttachment.texture = liveMain.depthStencil
            pass.stencilAttachment.loadAction = .clear
            pass.stencilAttachment.storeAction = .dontCare
            pass.stencilAttachment.clearStencil = 0
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Main"
        bindCommon(enc, ctx)

        if !fx.transparentBackground, let background = ctx.background {
            enc.pushDebugGroup("Background")
            enc.setRenderPipelineState(main.background)
            enc.setDepthStencilState(pipelines.depthNone)
            enc.setCullMode(.none)
            enc.setFragmentBuffer(background.buffer, offset: background.offset, index: Int(BufferIndexFrameUniforms.rawValue))
            enc.setFragmentBuffer(ctx.post.buffer, offset: ctx.post.offset, index: Int(BufferIndexPostParams.rawValue))
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.setFragmentBuffer(ctx.frameUniforms.buffer, offset: ctx.frameUniforms.offset, index: Int(BufferIndexFrameUniforms.rawValue))
            enc.popDebugGroup()
        }
        if fx.showGrid {
            enc.pushDebugGroup("Grid")
            enc.setRenderPipelineState(main.grid)
            enc.setDepthStencilState(pipelines.depthTest)
            enc.setCullMode(.none)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.popDebugGroup()
        }

        enc.pushDebugGroup("Opaque")
        let outlinesOn = fx.outlineWidth > 0.001
        for rec in ctx.opaque {
            let m = rec.item.material
            bindDraw(enc, rec)
            bindTextures(enc, m, frame: ctx.frame)
            if outlinesOn && rec.item.outline && (m.uniforms.flags & MaterialFlagNoOutline.rawValue) == 0 {
                enc.setRenderPipelineState(main.outline)
                enc.setDepthStencilState(pipelines.depthWrite)
                enc.setCullMode(.front)
                drawIndexed(enc, rec.mesh)
            }
            let nativeEye = m.uniforms.kind == UInt32(MaterialKindEye.rawValue) && (m.uniforms.flags & MaterialFlagSourceIrisHighlights.rawValue) == 0
            enc.setRenderPipelineState(nativeEye ? main.eye : main.toonOpaque)
            enc.setDepthStencilState(pipelines.depthWrite)
            enc.setCullMode((m.uniforms.flags & MaterialFlagDoubleSided.rawValue) != 0 ? .none : .back)
            drawIndexed(enc, rec.mesh)
        }
        enc.popDebugGroup()

        if !ctx.live.isEmpty, ctx.liveMainPass != nil {
            enc.pushDebugGroup("SourceShaderLive")
            encodeLiveDraws(enc, ctx, target: TranslatedSourceTarget(color: Pipelines.hdrFormat, depthStencil: Pipelines.depthStencilFormat, sampleCount: Pipelines.sampleCount))
            // Translated programs bind buffers 0 and 8…, textures 0…; restore
            // the native frame bindings for the passes that follow.
            bindCommon(enc, ctx)
            enc.popDebugGroup()
        }

        if !ctx.transparent.isEmpty {
            enc.pushDebugGroup("Transparent")
            enc.setDepthStencilState(pipelines.depthTest)
            for rec in ctx.transparent {
                let material = rec.item.material.uniforms
                let nativeEye = material.kind == UInt32(MaterialKindEye.rawValue) && (material.flags & MaterialFlagSourceIrisHighlights.rawValue) == 0
                enc.setRenderPipelineState(nativeEye ? main.eyeBlend : main.toonBlend)
                bindDraw(enc, rec)
                bindTextures(enc, rec.item.material, frame: ctx.frame)
                enc.setCullMode((rec.item.material.uniforms.flags & MaterialFlagDoubleSided.rawValue) != 0 ? .none : .back)
                drawIndexed(enc, rec.mesh)
            }
            enc.popDebugGroup()
        }

        let depthGizmos = ctx.gizmos.filter { $0.batch.depthTest }
        if !depthGizmos.isEmpty {
            enc.pushDebugGroup("GizmosDepth")
            enc.setRenderPipelineState(main.gizmoHDR)
            enc.setDepthStencilState(pipelines.depthTest)
            enc.setCullMode(.none)
            encodeGizmos(enc, depthGizmos)
            enc.popDebugGroup()
        }
        enc.endEncoding()
    }

    private func encodeGizmos(_ enc: any MTLRenderCommandEncoder, _ records: [GizmoRecord]) {
        for g in records {
            enc.setVertexBuffer(g.vertices.buffer, offset: g.vertices.offset, index: Int(BufferIndexGizmoVertices.rawValue))
            enc.setVertexBuffer(g.draw.buffer, offset: g.draw.offset, index: Int(BufferIndexDrawUniforms.rawValue))
            enc.setFragmentBuffer(g.draw.buffer, offset: g.draw.offset, index: Int(BufferIndexDrawUniforms.rawValue))
            enc.drawPrimitives(type: g.batch.primitive == .lines ? .line : .triangle, vertexStart: 0, vertexCount: g.batch.vertices.count)
        }
    }

    private func fullscreen(_ cb: any MTLCommandBuffer, label: String, target: any MTLTexture, load: MTLLoadAction = .dontCare,
                            pipeline: any MTLRenderPipelineState, post: FrameAllocation, textures: [(any MTLTexture, TextureIndex)]) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = label
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBuffer(post.buffer, offset: post.offset, index: Int(BufferIndexPostParams.rawValue))
        for (t, i) in textures { enc.setFragmentTexture(t, index: Int(i.rawValue)) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func encodePost(_ ctx: FrameContext, targets: RenderTargets, target: any MTLTexture, _ cb: any MTLCommandBuffer) {
        let fx = ctx.frame.effects
        let po = ctx.post
        if fx.bloomEnabled {
            fullscreen(cb, label: "BloomThreshold", target: targets.bloom[0], pipeline: pipelines.bloomThreshold, post: po, textures: [(targets.hdr, TextureIndexSceneColor)])
            for i in 0..<(targets.bloom.count - 1) {
                fullscreen(cb, label: "BloomDown\(i)", target: targets.bloom[i + 1], pipeline: pipelines.bloomDown, post: po, textures: [(targets.bloom[i], TextureIndexSceneColor)])
            }
            for i in stride(from: targets.bloom.count - 2, through: 0, by: -1) {
                fullscreen(cb, label: "BloomUp\(i)", target: targets.bloom[i], load: .load, pipeline: pipelines.bloomUp, post: po, textures: [(targets.bloom[i + 1], TextureIndexSceneColor)])
            }
        }
        let bloomTex = fx.bloomEnabled ? targets.bloom[0] : resources.blackTexture
        if fx.fxaa {
            fullscreen(cb, label: "Composite", target: targets.ldr, pipeline: pipelines.composite, post: po, textures: [(targets.hdr, TextureIndexSceneColor), (bloomTex, TextureIndexBloom)])
            fullscreen(cb, label: "FXAA", target: target, pipeline: pipelines.fxaa, post: po, textures: [(targets.ldr, TextureIndexSceneColor)])
        } else {
            fullscreen(cb, label: "Composite", target: target, pipeline: pipelines.composite, post: po, textures: [(targets.hdr, TextureIndexSceneColor), (bloomTex, TextureIndexBloom)])
        }
    }

    private func encodeOverlay(_ ctx: FrameContext, targets: RenderTargets, target: any MTLTexture, _ cb: any MTLCommandBuffer) {
        let overlays = ctx.gizmos.filter { !$0.batch.depthTest }
        guard !overlays.isEmpty else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = targets.overlayDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 0
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Overlay"
        enc.setRenderPipelineState(pipelines.gizmoLDR)
        enc.setDepthStencilState(pipelines.depthWrite)
        enc.setCullMode(.none)
        enc.setVertexBuffer(ctx.frameUniforms.buffer, offset: ctx.frameUniforms.offset, index: Int(BufferIndexFrameUniforms.rawValue))
        encodeGizmos(enc, overlays)
        enc.endEncoding()
    }

    private func encodePick(_ ctx: FrameContext, targets: RenderTargets, _ cb: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.pick
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = targets.pickDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 0
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Pick"
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexBuffer(ctx.frameUniforms.buffer, offset: ctx.frameUniforms.offset, index: Int(BufferIndexFrameUniforms.rawValue))
        enc.setRenderPipelineState(pipelines.pick)
        enc.setDepthStencilState(pipelines.depthWrite)
        enc.setCullMode(.none)
        for rec in ctx.opaque + ctx.transparent + ctx.live.map(\.record) where rec.item.objectID != 0 {
            bindDraw(enc, rec)
            bindTextures(enc, rec.item.material, frame: ctx.frame)
            enc.setFragmentBuffer(rec.draw.buffer, offset: rec.draw.offset, index: Int(BufferIndexDrawUniforms.rawValue))
            drawIndexed(enc, rec.mesh)
        }
        // Pickable gizmos draw on top (depth cleared so handles always win).
        let pickable = ctx.gizmos.filter { $0.batch.objectID != 0 }
        if !pickable.isEmpty {
            enc.setRenderPipelineState(pipelines.pickGizmo)
            enc.setDepthStencilState(pipelines.depthNone)
            encodeGizmos(enc, pickable)
        }
        enc.endEncoding()
    }
}
