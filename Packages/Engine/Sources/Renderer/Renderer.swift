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
    /// Deform dispatches encoded.
    public var deformDispatches = 0
    /// Deformations whose buffer already held exactly this frame's vertices, so
    /// no dispatch was encoded (R7 phase 2, item 4; interactive draws and picks).
    public var deformReuses = 0
    /// Deformations dispatched without comparing or recording their content: an
    /// interactive draw while every deformation changes from frame to frame
    /// (`DeformMode.interactive`). Included in `deformDispatches`.
    public var deformUntracked = 0
    /// Meaningful morph entries of the frame's deformations, dispatched or reused.
    public var activeMorphEntries = 0
    /// Largest entry list of one deformation. Lists above `IK_MAX_ACTIVE_MORPHS`
    /// are accumulated in full, not truncated.
    public var largestActiveMorphSet = 0
    /// Skin palettes written to the frame ring: the referenced, valid
    /// `RenderFrame.skinSets` (their bytes are `uniforms.paletteBytes`).
    public var skinPalettes = 0
    /// Where the frame's uniforms were placed. Nonzero overflow means the frame
    /// needed more than its ring region, or found every region still in flight.
    public var uniforms = FrameRing.Statistics()
    /// The main pass's opaque and transparent records (live source-shader
    /// draws excluded), and the draws they took: one per pipeline used (toon,
    /// and outline when outlined) for each record drawn on its own and each
    /// instanced draw. Equal when nothing merged (ST-T04 instanced static items).
    public var mainPassRecords = 0
    public var mainPassRuns = 0
    /// Static item records drawn instanced (`Renderer.instancesStaticItems`),
    /// and the instanced draws they took. A record with no equal neighbour is
    /// drawn on its own, as before, and is not counted here.
    public var instancedRecords = 0
    public var instancedRuns = 0
    /// Shadow-pass casters, and the draws they took.
    public var shadowCasters = 0
    public var shadowDraws = 0
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

/// A finished asynchronous pick (`Renderer.pick(frame:pixel:size:completion:)`).
public struct RenderPickResult: Sendable, Equatable {
    /// The object id under the pixel; 0 for nothing, or when the pick could not run.
    public var id: UInt32
    /// The pick command buffer's GPU time in seconds (`gpuEndTime - gpuStartTime`); 0 when it did not run.
    public var gpuTime: Double
    public init(id: UInt32, gpuTime: Double = 0) { self.id = id; self.gpuTime = gpuTime }
}

/// Outcome of one display-link callback. An unchanged callback submits no GPU work
/// and leaves the previously presented image on screen. A refreshed callback
/// presents that same image again, copied into the callback's drawable (the
/// idle keep-alive, `draw(to:timestamp:refreshAfter:completion:)`).
public struct RenderDrawResult: Sendable {
    public enum Outcome: String, Sendable { case rendered, unchanged, failed, refreshed }
    public let outcome: Outcome
    /// Counters captured under the render lock, before a pick/capture can replace them.
    public let statistics: RenderFrameStatistics
}

/// Completion of exactly one interactive command buffer (never a cached GPU sample).
public struct RenderDrawCompletion: Sendable {
    public let succeeded: Bool
    public let gpuTime: Double
    /// The command buffer's `gpuStartTime` and `gpuEndTime` (seconds, the
    /// host clock `CACurrentMediaTime` reads); 0 when it did not run.
    public let gpuStart: Double
    public let gpuEnd: Double

    init(succeeded: Bool, gpuTime: Double, gpuStart: Double = 0, gpuEnd: Double = 0) {
        self.succeeded = succeeded; self.gpuTime = gpuTime; self.gpuStart = gpuStart; self.gpuEnd = gpuEnd
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
///
/// Threads (R7 phase 2, item 2; docs/reference/renderer.md, "Renderer threads").
/// Each viewport draws on its own render thread; the app's models call
/// `submit`, `pick`, `capture` and `benchmark` from the main thread. The
/// asynchronous `pick` prepares and encodes on `pickQueue` (R7 phase 2, item 5).
/// - `submit` and `currentFrame` exchange the pending frame under `frameLock`.
/// - Every frame is prepared, encoded and committed under `renderLock`, which
///   also guards the render targets, `frameIndex`, the frame ring's open frame,
///   the deformation buffers' content record and the live encoder. Committing
///   in the same hold keeps the queue in the order that record changed. `draw` takes the pending frame only once it holds
///   `renderLock`, so it always prepares the newest submitted frame, as when it
///   ran on the main thread (resource retirement, R6). Lock order: a frame
///   slot, then `renderLock`, then `frameLock` or `statusLock`.
/// - While no viewport draws, `submit` queues a retirement completion on
///   `retirementQueue` (#368). It takes `renderLock` only with `try`, then
///   `frameLock` for the pending frame's stamp, then the store lock, in the
///   order above, and never waits for `renderLock`.
/// - What the last prepared frame reported (`lastFrameStatistics`,
///   `lastFrameError`, `lastDeformationErrors`, `lastSourceShaderLive`) and
///   `lastFrameGPUTime` are published under `statusLock`. They describe the
///   most recent frame on any thread, so an offscreen caller reading them
///   after its own call can see a draw that ran in between.
///
/// Sendable invariant: every mutable stored property is guarded by one of the
/// locks above (`pendingFrame`, its revision and continuous flag by `frameLock`;
/// `targets`, `frameIndex`, interactive invalidation, the deformation buffers'
/// content record and live encoder state by `renderLock`; the published values
/// by `statusLock`; the submit observers, drawing viewports and the queued
/// completion's flag by `observerLock`); everything else is immutable after `init` or a
/// thread-safe Metal or store object (`pickQueue` and `retirementQueue` are serial dispatch queues).
public final class Renderer: @unchecked Sendable {
    public static let shadowMapSize = 2048

    public let gpu: GPUContext
    public let resources: ResourceStore
    let pipelines: Pipelines
    let frameRing: FrameRing
    let shadowMap: any MTLTexture

    private let renderLock = NSLock()
    private let frameLock = NSLock()
    /// Prepares, encodes and commits asynchronous picks, in the order they were
    /// requested, off the caller's thread.
    private let pickQueue = DispatchQueue(label: "com.grabbiel.Ikkoku.pick", qos: .userInteractive)
    private var pendingFrame = RenderFrame()
    private var pendingRevision: UInt64 = 0
    private var pendingContinuous = false
    private struct DrawnFrame: Equatable {
        var revision: UInt64
        var resources: UInt64
        var width: Int, height: Int
    }
    // Protected by renderLock. Weak identity avoids keeping a departed viewport alive.
    private weak var drawnLayer: CAMetalLayer?
    private var drawnFrame: DrawnFrame?
    private var drawSerial: UInt64 = 0
    /// The texture of the newest drawable this renderer presented (rendered or
    /// refreshed) and that callback's target time: the idle keep-alive's source.
    private var lastPresented: (any MTLTexture)?
    private var lastPresentTarget: CFTimeInterval?
    private var lastCallback: CFTimeInterval?
    private var targets: RenderTargets?
    private var frameIndex = 0
    /// What each deformation key's buffer holds (R7 phase 2, item 4): the
    /// buffer and the inputs of the last dispatch into it, in queue order. An
    /// entry is removed when a dispatch into its buffer is encoded and set
    /// again when that command buffer commits (`commit(_:writes:)`); every
    /// command buffer that dispatches the deform pass commits while holding
    /// renderLock, in the same hold that encoded it. Preparing a frame drops
    /// the entries of keys it does not use. See renderer.md, "Renderer
    /// threads". Protected by renderLock.
    private var deformContent: [UInt64: DeformBufferRecord] = [:]
    private var deformWriteSerial: UInt64 = 0
    /// Interactive draws stop tracking deformation content while every
    /// deformation changes (`DeformMode.interactive`): the draws left before
    /// the next tracked one, the run of tracked draws that compared records
    /// and reused none, and the last interactive draw's target time.
    private var deformBypass = 0
    private var deformMisses = 0
    private var lastInteractiveDraw: CFTimeInterval?
    /// Two tracked draws in a row that reuse nothing start a bypass of 30
    /// draws; the 30th is tracked again. A pause of 0.1 s between draws ends it.
    static let deformMissesBeforeBypass = 2
    static let deformBypassDraws = 30
    static let deformBypassPause: CFTimeInterval = 0.1
    private var deformReuse = true
    private var skipUnchanged = true
    private var instanceItems = true
    private var skipRedundantState = true
    /// Static item records' uniforms between `buildContext` and `assignRuns`
    /// (ST-T04), indexed by `DrawRecord.pending`. Kept, with their capacity,
    /// across frames; used only under `renderLock`.
    private var pendingDraws: [DrawUniforms] = []
    private var pendingMaterials: [MaterialUniforms] = []
    var liveEncoder: SourceShaderLiveEncoder?
    var liveEncoderError: String?

    /// Guards `submitObservers`, `drawingViewports` and `retirementScheduled`;
    /// never held while taking another lock.
    private let observerLock = NSLock()
    private var submitObservers: [UInt64: @Sendable () -> Void] = [:]
    private var nextObserver: UInt64 = 0
    /// #368: the viewports drawing this renderer's submits (`setViewport`).
    private var drawingViewports = Set<ObjectIdentifier>()
    /// #368: a completion is queued and has not started
    /// (`completeScheduledRetirements`).
    private var retirementScheduled = false
    /// #368: how many completions submits have scheduled (tests).
    private var retirementSchedules = 0
    /// #368: completes retirements off the main thread while no viewport draws.
    private let retirementQueue = DispatchQueue(label: "com.grabbiel.Ikkoku.retirements", qos: .utility)

    private let statusLock = NSLock()
    private var publishedStatistics = RenderFrameStatistics()
    private var publishedError: RenderFrameError?
    private var publishedDeformationErrors: [String] = []
    private var publishedSourceShaderLive = SourceShaderLiveFrameReport()
    private var publishedGPUTime: Double = 0
    /// GPU time (`gpuEndTime - gpuStartTime`) of the last completed interactive frame.
    public var lastFrameGPUTime: Double {
        statusLock.lock(); defer { statusLock.unlock() }; return publishedGPUTime
    }
    /// Invalid skin bindings of the most recently prepared frame. They are
    /// skipped during interactive rendering; captures fail.
    public var lastDeformationErrors: [String] {
        statusLock.lock(); defer { statusLock.unlock() }; return publishedDeformationErrors
    }
    /// Live source-shader draws encoded by the last prepared frame, and any
    /// item that fell back to its native toon draw at render time (with why).
    /// Written only while preparing or encoding a frame, under the render lock.
    public internal(set) var lastSourceShaderLive: SourceShaderLiveFrameReport {
        get { statusLock.lock(); defer { statusLock.unlock() }; return publishedSourceShaderLive }
        set { statusLock.lock(); publishedSourceShaderLive = newValue; statusLock.unlock() }
    }
    /// Counters of the most recently prepared frame (see `RenderFrameStatistics`).
    public var lastFrameStatistics: RenderFrameStatistics {
        statusLock.lock(); defer { statusLock.unlock() }; return publishedStatistics
    }
    /// Nil when the most recent frame was encoded; otherwise why it was skipped or failed.
    public var lastFrameError: RenderFrameError? {
        statusLock.lock(); defer { statusLock.unlock() }; return publishedError
    }
    /// Whether an interactive callback whose image is unchanged skips its draw
    /// (R7 G3; default true). False draws and presents every callback, as
    /// before G3: a measurement control. Safe from any thread.
    public var skipsUnchangedFrames: Bool {
        get { renderLock.lock(); defer { renderLock.unlock() }; return skipUnchanged }
        set { renderLock.lock(); skipUnchanged = newValue; renderLock.unlock() }
    }
    /// Whether the geometry passes skip encoder calls that repeat the state
    /// the encoder already holds (`EncoderState`; default true). False sets
    /// every state for every draw, as before: the reference of the
    /// state-skipping tests. Safe from any thread.
    var skipsRedundantEncoderState: Bool {
        get { renderLock.lock(); defer { renderLock.unlock() }; return skipRedundantState }
        set { renderLock.lock(); skipRedundantState = newValue; renderLock.unlock() }
    }
    /// Whether interactive draws and picks skip the deform dispatch of a
    /// deformation whose buffer already holds exactly the frame's vertices (R7
    /// phase 2, item 4; default true). False dispatches every deformation in
    /// every frame, as before: a measurement control. Captures, benchmarks and
    /// live validation captures always dispatch. Safe from any thread.
    public var reusesDeformedVertices: Bool {
        get { renderLock.lock(); defer { renderLock.unlock() }; return deformReuse }
        set { renderLock.lock(); deformReuse = newValue; renderLock.unlock() }
    }
    /// Whether static item records draw instanced (ST-T04; default true): each
    /// adjacent stretch of the sorted opaque or transparent records that share
    /// the mesh, the pipeline, the material identity, the textures and the cull
    /// and depth state is one draw (`instanceable`, `mergesWith`). False draws
    /// every record on its own, as before: a measurement control and the
    /// reference of the instanced-versus-per-draw tests. Safe from any thread.
    public var instancesStaticItems: Bool {
        get { renderLock.lock(); defer { renderLock.unlock() }; return instanceItems }
        set { renderLock.lock(); instanceItems = newValue; renderLock.unlock() }
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
        // R6: the snapshot now holds the textures it names, and the frame it
        // replaces has held its own since its submit, so textures retired before
        // this frame was created go now, not when a viewport prepares it (an
        // occluded or minimized one never does). Store lock only, before frameLock.
        // The same lock says whether meshes or keys are retiring (#368, below).
        let retiring = resources.completeTextureRetirements(createdBefore: snapshot.createdAt)
        // Native shaders do not read frame.time. Live programs may read _Time;
        // conservatively keep every visible live material at the display rate.
        let continuous = snapshot.items.contains { $0.visible && $0.sourceShader != nil }
        frameLock.lock()
        pendingFrame = snapshot; pendingRevision &+= 1; pendingContinuous = continuous
        frameLock.unlock()
        observerLock.lock()
        let observers = submitObservers.isEmpty ? [] : Array(submitObservers.values)
        // #368: meshes and keys still go when a prepare of a submitted frame
        // completes them, which a drawing viewport does within a frame. With no
        // viewport drawing (hidden, minimized, or none), nothing would prepare,
        // so a utility queue completes them under the render lock instead, once
        // for any number of submits before it starts. Nothing more runs on
        // this thread.
        var schedule = false
        if retiring, drawingViewports.isEmpty, !retirementScheduled {
            retirementScheduled = true; retirementSchedules += 1; schedule = true
        }
        observerLock.unlock()
        if schedule { retirementQueue.async { [weak self] in self?.completeScheduledRetirements() } }
        for observer in observers { observer() }
    }

    /// #368: a viewport says whether it draws this renderer's submits: visible
    /// with its display link running (`true`), or hidden, minimized or stopped
    /// (`false`). While no viewport draws, `submit` completes retirements off
    /// the main thread. Safe from any thread.
    public func setViewport(_ viewport: ObjectIdentifier, drawing: Bool) {
        observerLock.lock()
        if drawing { drawingViewports.insert(viewport) } else { drawingViewports.remove(viewport) }
        observerLock.unlock()
    }

    /// #368, on `retirementQueue`: completes what a prepare of the pending
    /// frame would, the retirements made before it was created, if no frame
    /// is being prepared (the render lock is free). Otherwise they stay, and
    /// the next submit or the prepare of a submitted frame completes them, as
    /// before. The pending frame is the submit that queued this or a later
    /// one; if a later submit put back a copy of an older frame, that older
    /// stamp applies, as at its prepare. Holding the render lock keeps every
    /// guarantee of a completion at prepare: no prepare runs, the pending
    /// frame was created after the retirements it completes, encoded command
    /// buffers hold their own references, and frames created earlier get
    /// transient deformation buffers. Internal so a test can run it with no
    /// submitted frame pending, when it completes nothing.
    func completeScheduledRetirements() {
        observerLock.lock(); retirementScheduled = false; observerLock.unlock()
        guard renderLock.try() else { return }
        frameLock.lock()
        let stamp: UInt64? = pendingFrame.submitted ? pendingFrame.createdAt : nil
        frameLock.unlock()
        if let stamp { dropDeformContent(resources.completeRetirements(createdBefore: stamp)) }
        renderLock.unlock()
    }

    /// Drops the content records of released deformation keys, which hold
    /// their buffers. A record only ever matches its own buffer (`===`), so a
    /// key's later buffer never reuses it. Caller holds renderLock.
    private func dropDeformContent(_ keys: [UInt64]) {
        guard !keys.isEmpty, !deformContent.isEmpty else { return }
        for key in keys { deformContent[key] = nil }
    }

    /// Waits for a scheduled completion (tests).
    func waitForScheduledRetirements() { retirementQueue.sync {} }

    /// Holds queued completions until released, so a test can submit again
    /// before one starts (tests).
    func holdScheduledRetirements(_ hold: Bool) { if hold { retirementQueue.suspend() } else { retirementQueue.resume() } }

    /// How many completions submits have scheduled so far (tests).
    var scheduledRetirementCount: Int { observerLock.lock(); defer { observerLock.unlock() }; return retirementSchedules }

    /// Whether a content record holds `key`'s buffer (tests).
    func holdsDeformContent(key: UInt64) -> Bool { renderLock.lock(); defer { renderLock.unlock() }; return deformContent[key] != nil }

    /// Calls `observer` after every `submit`, on the submitting thread and
    /// outside the renderer's locks, so a viewport can return its display link
    /// to full rate at once (R7 phase 2, item 4, P2). Returns a token for
    /// `removeSubmitObserver`. Safe from any thread.
    public func addSubmitObserver(_ observer: @escaping @Sendable () -> Void) -> UInt64 {
        observerLock.lock(); defer { observerLock.unlock() }
        nextObserver &+= 1
        submitObservers[nextObserver] = observer
        return nextObserver
    }

    /// Stops calling the observer `token` names. Safe from any thread; a call
    /// already in progress on another thread may still finish.
    public func removeSubmitObserver(_ token: UInt64) {
        observerLock.lock(); submitObservers[token] = nil; observerLock.unlock()
    }
    public func currentFrame() -> RenderFrame { frameLock.lock(); defer { frameLock.unlock() }; return pendingFrame }

    // MARK: - Drawing to the swapchain

    /// Invalidates the presented image when a viewport starts/rejoins its window.
    /// Safe from any thread. Does not change the resource-retirement frame stamp.
    public func invalidateInteractiveFrame() {
        renderLock.lock(); drawnFrame = nil; lastPresented = nil; lastPresentTarget = nil; renderLock.unlock()
    }

    /// Renders only when the submitted snapshot, resources, viewport or a live
    /// material requires it. The viewport's render thread may lower the
    /// display-link rate while frames are unchanged (P2). Offscreen entry
    /// points always encode their own complete pass graph.
    ///
    /// `refreshAfter` (seconds; nil disables it) is the idle keep-alive (R7
    /// phase 2, item 4). An unchanged callback whose target is at least that
    /// long after the viewport's last present copies the last presented image
    /// into its drawable and presents it, instead of presenting nothing. After
    /// about 0.17 s without a present, the first few presents of the next
    /// change never reach the screen (performance.md, "Phase 2, item 4"); the
    /// keep-alive keeps presenting at the cost of one blit.
    @discardableResult
    public func draw(to drawable: any CAMetalDrawable, timestamp: CFTimeInterval, refreshAfter: CFTimeInterval? = nil,
                     completion: (@Sendable (RenderDrawCompletion) -> Void)? = nil) -> RenderDrawResult {
        draw(to: drawable, timestamp: timestamp, refreshAfter: refreshAfter, completion: completion, configureFrameRing: nil)
    }

    /// Internal allocation-failure injection, like capture(configureTargets:).
    /// Called under renderLock after opening the ring and before prepare allocates.
    func draw(to drawable: any CAMetalDrawable, timestamp: CFTimeInterval, refreshAfter: CFTimeInterval? = nil,
              completion: (@Sendable (RenderDrawCompletion) -> Void)?,
              configureFrameRing: ((FrameRing) -> Void)?) -> RenderDrawResult {
        let tex = drawable.texture
        let failed = RenderDrawResult(outcome: .failed, statistics: .init())
        let unchanged = RenderDrawResult(outcome: .unchanged, statistics: .init())
        guard tex.width > 0, tex.height > 0 else { return failed }
        // Cheap first check avoids even a frame-slot wait on an unchanged callback.
        // Recheck after acquiring the slot: another callback may have drawn while
        // we waited. No path waits for a slot while holding renderLock.
        renderLock.lock()
        let resumed = lastCallback.map { timestamp - $0 > 0.25 || timestamp < $0 } ?? true
        lastCallback = timestamp
        if resumed { drawnFrame = nil }
        if interactiveUnchanged(layer: drawable.layer, width: tex.width, height: tex.height),
           !refreshDue(after: refreshAfter, into: tex, timestamp: timestamp) {
            renderLock.unlock()
            return unchanged
        }
        renderLock.unlock()
        gpu.waitForFrameSlot()
        renderLock.lock()
        if interactiveUnchanged(layer: drawable.layer, width: tex.width, height: tex.height) {
            guard refreshDue(after: refreshAfter, into: tex, timestamp: timestamp) else {
                renderLock.unlock(); gpu.releaseFrameSlot()
                return unchanged
            }
            return refreshPresented(drawable, timestamp: timestamp, completion: completion)
        }
        guard let cb = gpu.commandQueue.makeCommandBuffer() else {
            publish(error: .commandBufferUnavailable); drawnFrame = nil
            renderLock.unlock(); gpu.releaseFrameSlot(); return failed
        }
        cb.label = "Frame"
        // Frame and revision are one snapshot. Camera-only copies retain createdAt,
        // which orders retirements and must not be used as the submission revision.
        frameLock.lock()
        var frame = pendingFrame
        let revision = pendingRevision
        frameLock.unlock()
        let generation = resources.generation
        frame.time = timestamp
        var encoded = false
        var writes = DeformWrites.none
        // A pause ends whatever interaction changed every deformation.
        if let last = lastInteractiveDraw, !(0..<Self.deformBypassPause).contains(timestamp - last) {
            deformBypass = 0; deformMisses = 0
        }
        lastInteractiveDraw = timestamp
        if let targets = ensureTargets(width: tex.width, height: tex.height) {
            frameRing.beginFrame(frameIndex); frameIndex &+= 1
            do {
                configureFrameRing?(frameRing)
                writes = try encode(frame: frame, target: tex, targets: targets, commandBuffer: cb, deforms: .interactive)
                frameRing.endFrame(retainedUntilCompletionOf: cb)
                encoded = true
            } catch { frameRing.abandonFrame() }
        } else {
            publish(error: .renderTargetsUnavailable(width: tex.width, height: tex.height))
        }
        guard encoded else {
            drawnFrame = nil; renderLock.unlock(); gpu.releaseFrameSlot(); return failed
        }
        let statistics = lastFrameStatistics
        drawSerial &+= 1
        let serial = drawSerial
        // A mutation during preparation may change a lookup already performed.
        // Cache only a generation that stayed stable across the complete encoding.
        drawnFrame = resources.generation == generation
            ? DrawnFrame(revision: revision, resources: generation, width: tex.width, height: tex.height) : nil
        drawnLayer = drawable.layer
        cb.addCompletedHandler { [weak self] c in
            let succeeded = c.status == .completed
            let seconds = max(0, c.gpuEndTime - c.gpuStartTime)
            self?.publish(gpuTime: seconds)
            if !succeeded, let self {
                self.renderLock.lock()
                if self.drawSerial == serial { self.drawnFrame = nil }
                self.renderLock.unlock()
            }
            completion?(RenderDrawCompletion(succeeded: succeeded, gpuTime: seconds, gpuStart: c.gpuStartTime, gpuEnd: c.gpuEndTime))
        }
        gpu.releaseFrameSlot(onCompletionOf: cb)
        // Commit/present in draw order, before exposing this reusable image to a
        // second callback. Neither operation waits for GPU completion.
        cb.present(drawable)
        commit(cb, writes: writes)
        lastPresented = tex; lastPresentTarget = timestamp
        renderLock.unlock()
        return RenderDrawResult(outcome: .rendered, statistics: statistics)
    }

    /// Caller holds renderLock and found the image unchanged. Whether this
    /// callback should present it again (`refreshAfter`). The source is the
    /// viewport's newest presented drawable, which the layer cannot hand out
    /// again before a newer one is presented; when it does come back (its
    /// present was dropped), the callback skips the refresh rather than rely
    /// on a recycled drawable's contents.
    private func refreshDue(after interval: CFTimeInterval?, into texture: any MTLTexture, timestamp: CFTimeInterval) -> Bool {
        guard let interval, let source = lastPresented, let last = lastPresentTarget else { return false }
        // Targets sit on the display's vsync grid; a millisecond of slack keeps
        // an interval that is a whole number of periods from slipping one.
        return timestamp - last + 0.001 >= interval && source !== texture && !texture.isFramebufferOnly
            && source.width == texture.width && source.height == texture.height && source.pixelFormat == texture.pixelFormat
    }

    /// The idle keep-alive. Caller holds renderLock and a frame slot, and
    /// `refreshDue` held; both are released here. One blit copies the last
    /// presented image into `drawable`, which is then presented, in queue
    /// order after the command buffer that wrote the source.
    private func refreshPresented(_ drawable: any CAMetalDrawable, timestamp: CFTimeInterval,
                                  completion: (@Sendable (RenderDrawCompletion) -> Void)?) -> RenderDrawResult {
        let tex = drawable.texture
        guard let source = lastPresented, let cb = gpu.commandQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            // Nothing was presented; the image on screen is still the right one.
            renderLock.unlock(); gpu.releaseFrameSlot()
            return RenderDrawResult(outcome: .unchanged, statistics: .init())
        }
        cb.label = "Refresh"
        blit.label = "Refresh"
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                  to: tex, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        // A refresh shows the drawn image, so it shares that draw's serial: a
        // failure forces the next callback to render unless a newer draw did.
        let serial = drawSerial
        cb.addCompletedHandler { [weak self] c in
            let succeeded = c.status == .completed
            if !succeeded, let self {
                self.renderLock.lock()
                if self.drawSerial == serial { self.drawnFrame = nil }
                self.renderLock.unlock()
            }
            completion?(RenderDrawCompletion(succeeded: succeeded, gpuTime: max(0, c.gpuEndTime - c.gpuStartTime),
                                             gpuStart: c.gpuStartTime, gpuEnd: c.gpuEndTime))
        }
        gpu.releaseFrameSlot(onCompletionOf: cb)
        cb.present(drawable)
        cb.commit()
        lastPresented = tex; lastPresentTarget = timestamp
        renderLock.unlock()
        return RenderDrawResult(outcome: .refreshed, statistics: .init())
    }

    /// Caller holds renderLock. No per-item scan or buffer work on a skipped draw.
    private func interactiveUnchanged(layer: CAMetalLayer, width: Int, height: Int) -> Bool {
        guard skipUnchanged, drawnLayer === layer, let drawnFrame else { return false }
        frameLock.lock()
        let revision = pendingRevision, continuous = pendingContinuous
        frameLock.unlock()
        return !continuous && drawnFrame == DrawnFrame(revision: revision, resources: resources.generation,
                                                       width: width, height: height)
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

    /// Returns the object id under a pixel (0 = nothing). Synchronous: waits for
    /// the GPU, a few milliseconds. Clicks, drag starts and the scenario
    /// runner use it; the hover uses the asynchronous `pick` below. Both encode
    /// the same pick, so they return the same id for the same frame and pixel.
    public func pick(frame: RenderFrame, pixel: Float2, size: (Int, Int)) -> UInt32 {
        gpu.waitForFrameSlot()
        defer { gpu.releaseFrameSlot() }
        guard let encoded = commitPick(frame: frame, pixel: pixel, size: size) else { return 0 }
        encoded.commandBuffer.waitUntilCompleted()
        return encoded.readback.contents().load(as: UInt32.self)
    }

    /// Asynchronous `pick` (R7 phase 2, item 5). Returns at once. The pick
    /// queue prepares, encodes and commits the pick under the same frame slot
    /// and locks as every other frame, waits for the GPU there and then calls
    /// `completion` exactly once, on the pick queue, with the id and the
    /// command buffer's GPU time (id 0 when the pick could not run; the reason
    /// is published as for the synchronous pick). Picks run one at a time in
    /// the order they were requested. The caller decides whether a result is
    /// still wanted (`LatestPickQueue`).
    public func pick(frame: RenderFrame, pixel: Float2, size: (Int, Int),
                     completion: @escaping @Sendable (RenderPickResult) -> Void) {
        pickQueue.async { [self] in
            gpu.waitForFrameSlot()
            defer { gpu.releaseFrameSlot() }
            guard let encoded = commitPick(frame: frame, pixel: pixel, size: size) else {
                completion(RenderPickResult(id: 0)); return
            }
            let cb = encoded.commandBuffer
            cb.waitUntilCompleted()
            let gpuTime = cb.gpuEndTime > cb.gpuStartTime ? cb.gpuEndTime - cb.gpuStartTime : 0
            completion(RenderPickResult(id: encoded.readback.contents().load(as: UInt32.self), gpuTime: gpuTime))
        }
    }

    /// A pick encoded and committed under the render lock.
    private struct EncodedPick {
        let commandBuffer: any MTLCommandBuffer
        /// The id at the pixel (4 bytes), or the whole pick target (`pickTarget`).
        let readback: any MTLBuffer
    }

    /// Prepares `frame` for picking, encodes its deform pass (skipping
    /// deformations whose buffers already hold the frame's vertices), the pick
    /// pass and the readback copy, and commits it under the render lock like
    /// every command buffer that may dispatch the deform pass. With a pixel,
    /// the pick pass is scissored to that one pixel and only it is copied
    /// back: rasterization, the depth test and the fragment shader run per
    /// pixel, so the pixel's id is the one the whole pass would write there
    /// (`pickTarget` is the unscissored reference). The caller holds a frame
    /// slot and waits. Nil when the pick cannot run; the reason is published.
    private func commitPick(frame: RenderFrame, pixel: Float2?, size: (Int, Int)) -> EncodedPick? {
        // An empty viewport has no pixel to read (nothing is picked there).
        guard size.0 > 0, size.1 > 0 else { return nil }
        guard let cb = gpu.commandQueue.makeCommandBuffer() else { publish(error: .commandBufferUnavailable); return nil }
        cb.label = "Pick"
        let readbackLength = pixel == nil ? max(size.0, 1) * max(size.1, 1) * 4 : 16
        guard let readback = gpu.device.makeBuffer(length: readbackLength, options: .storageModeShared) else {
            publish(error: .readbackUnavailable); return nil
        }
        renderLock.lock()
        guard let targets = ensureTargets(width: size.0, height: size.1) else {
            renderLock.unlock(); publish(error: .renderTargetsUnavailable(width: size.0, height: size.1)); return nil
        }
        frameRing.beginFrame(frameIndex); frameIndex &+= 1
        guard let ctx = try? prepare(frame: frame, targets: targets, forPick: true, deforms: .reuse),
              lastDeformationErrors.isEmpty else {
            frameRing.abandonFrame(); renderLock.unlock(); return nil
        }
        let writes = encodeDeform(ctx, cb)
        if let pixel {
            let x = min(max(Int(pixel.x), 0), targets.width - 1), y = min(max(Int(pixel.y), 0), targets.height - 1)
            encodePick(ctx, targets: targets, scissor: MTLScissorRect(x: x, y: y, width: 1, height: 1), cb)
            if let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: targets.pick, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                          sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: readback, destinationOffset: 0, destinationBytesPerRow: 4, destinationBytesPerImage: 4)
                blit.endEncoding()
            }
        } else {
            encodePick(ctx, targets: targets, scissor: nil, cb)
            if let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: targets.pick, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: targets.width, height: targets.height, depth: 1), to: readback, destinationOffset: 0,
                          destinationBytesPerRow: targets.width * 4, destinationBytesPerImage: targets.width * targets.height * 4)
                blit.endEncoding()
            }
        }
        frameRing.endFrame(retainedUntilCompletionOf: cb)
        commit(cb, writes: writes)
        renderLock.unlock()
        return EncodedPick(commandBuffer: cb, readback: readback)
    }

    /// The whole pick target of `frame`, unscissored, row-major with the top
    /// row first: the reference that the scissored pick must match at every
    /// pixel (tests). Nil when the pick cannot run.
    func pickTarget(frame: RenderFrame, size: (Int, Int)) -> [UInt32]? {
        gpu.waitForFrameSlot()
        defer { gpu.releaseFrameSlot() }
        guard let encoded = commitPick(frame: frame, pixel: nil, size: size) else { return nil }
        encoded.commandBuffer.waitUntilCompleted()
        guard encoded.commandBuffer.status == .completed else { return nil }
        let count = size.0 * size.1
        return Array(UnsafeBufferPointer(start: encoded.readback.contents().assumingMemoryBound(to: UInt32.self), count: count))
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
        var writes = DeformWrites.none
        do { writes = try encode(frame: frame, target: tex, targets: targets, commandBuffer: cb, deforms: .always) } catch { encoded = false }
        let validDeformation = lastDeformationErrors.isEmpty
        // Commit under the lock, like every command buffer that dispatches the
        // deform pass, so the deformation buffers' content record stays in queue order.
        if encoded && validDeformation {
            frameRing.endFrame(retainedUntilCompletionOf: cb)
            commit(cb, writes: writes)
        } else { frameRing.abandonFrame() }
        renderLock.unlock()
        guard encoded, validDeformation else { return nil }
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

    /// Whether `captureSceneHDR(pixelCentreSamples: true)` can run here: the GPU
    /// has programmable sample positions.
    public var supportsPixelCentreSamples: Bool { gpu.device.areProgrammableSamplePositionsSupported }

    /// `capture`'s pass graph, returning the resolved linear scene colour
    /// (`RenderTargets.hdr`: the main passes after their MSAA resolve, before
    /// bloom, grading and the sRGB composite) as RGBA float16 bit patterns,
    /// rows top-down. ST-A11 evidence (the map probe's irradiance image); nil
    /// when the capture fails.
    ///
    /// `pixelCentreSamples` puts all of the main pass's MSAA samples at the pixel
    /// centre (programmable sample positions). Each pixel then holds the one
    /// surface that covers its centre, shaded there, as a single-sample render
    /// does: no partial coverage at edges and no fragment of a second triangle
    /// shaded at a centre outside it. The original player's oracle renders into a
    /// single-sample target (ST-A11 slice 4). Nil when the device has no
    /// programmable sample positions.
    public func captureSceneHDR(frame: RenderFrame, width: Int, height: Int, pixelCentreSamples: Bool = false) -> [UInt16]? {
        if pixelCentreSamples && !supportsPixelCentreSamples { return nil }
        var hdr: (any MTLTexture)?
        guard capture(frame: frame, width: width, height: height, configureTargets: {
            hdr = $0.hdr
            $0.pixelCentreSamples = pixelCentreSamples
        }) != nil, let hdr else { return nil }
        let bytesPerRow = width * 8
        guard let buffer = gpu.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let cb = gpu.commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: hdr, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt16.self), count: width * height * 4))
    }

    /// Measures the same pass graph as capture while reusing all render targets.
    /// Each command buffer completes before the next sample. This is a render
    /// latency baseline, not an interactive application throughput measurement.
    /// `camera`, when given, is each sample's camera by sample index (warmup
    /// samples first), set before the sample's timing starts: a scripted orbit
    /// (ST-T04 B2). Without it every sample draws `frame` as it is.
    public func benchmark(frame: RenderFrame, width: Int, height: Int,
                          warmupFrames: Int = 3, measuredFrames: Int = 20,
                          camera: ((Int) -> OrbitCamera)? = nil) throws -> RenderBenchmark {
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
        var counts: [String: [Double]] = [:]
        for sample in 0..<(warmupFrames + measuredFrames) {
            try autoreleasepool {
                var sampleFrame = frame
                if let camera { sampleFrame.camera = camera(sample) }
                gpu.waitForFrameSlot(); defer { gpu.releaseFrameSlot() }
                guard let cb = gpu.commandQueue.makeCommandBuffer() else { throw RenderBenchmarkError.commandBuffer }
                cb.label = "Benchmark \(sample)"
                renderLock.lock()
                let start = CACurrentMediaTime()
                frameRing.beginFrame(frameIndex); frameIndex &+= 1
                var failure: RenderFrameError?
                var writes = DeformWrites.none
                do { writes = try encode(frame: sampleFrame, target: target, targets: targets, commandBuffer: cb, deforms: .always) }
                catch { failure = (error as? RenderFrameError) ?? .commandBufferUnavailable }
                if sample >= warmupFrames, failure == nil {
                    // This sample's own statistics: no other frame prepares while the lock is held.
                    let s = lastFrameStatistics
                    for (name, value) in [("mainPassRecords", s.mainPassRecords), ("mainPassRuns", s.mainPassRuns),
                                          ("instancedRecords", s.instancedRecords), ("instancedRuns", s.instancedRuns),
                                          ("shadowCasters", s.shadowCasters), ("shadowDraws", s.shadowDraws)] {
                        counts[name, default: []].append(Double(value))
                    }
                }
                let errors = lastDeformationErrors
                // Commit under the lock so interactive draws cannot submit after
                // reusing the same deformation buffers but before this frame.
                if failure == nil && errors.isEmpty {
                    frameRing.endFrame(retainedUntilCompletionOf: cb)
                    commit(cb, writes: writes)
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
            drawnTriangles: meshes.reduce(0) { $0 + $1.indexCount / 3 }, uniqueVertices: vertices, resources: resources.statistics(),
            drawCounts: counts.mapValues { RenderBenchmark.Distribution($0) })
    }

    // MARK: - Frame preparation

    struct DrawRecord {
        let item: RenderItem
        let mesh: GPUMesh
        let vertexBuffer: any MTLBuffer
        let hiddenBuffer: (any MTLBuffer)?
        /// The record's DrawUniforms and MaterialUniforms. A member of an
        /// instanced draw (ST-T04) has its pass's table of DrawUniforms here,
        /// with its own element at `instance`, and its draw's one material
        /// element; every other record has its own allocations.
        var draw: FrameAllocation
        var material: FrameAllocation
        var instance = 0
        let distance: Float
        /// A static item record's index in `pendingDraws` and
        /// `pendingMaterials` until `assignRuns` places its uniforms; -1 for
        /// every other record. An index, not the 496 bytes of uniforms, so the
        /// record stays as small to sort and copy as before.
        var pending = -1
        /// The index of its run in its pass's runs when it is drawn instanced;
        /// -1 when it is drawn on its own.
        var run = -1
        var instanced: Bool { run >= 0 }
    }

    struct DeformRecord {
        let key: UInt64
        let mesh: GPUMesh
        let buffer: any MTLBuffer
        /// The skin palette's frame-ring buffer and offset (G4).
        let skinBuffer: (any MTLBuffer)?
        let skinOffset: Int
        let boneCount: Int
        let morphs: FrameAllocation
        let morphCount: Int
        /// The dispatch's inputs; recorded as `buffer`'s content once its
        /// command buffer commits. Nil when the frame does not track content.
        let content: DeformContent?
        /// False when `buffer` already holds exactly these vertices (`DeformMode.reuse`):
        /// nothing is encoded, and readers bind the buffer as it is.
        let dispatch: Bool
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
        /// `opaque` and `transparent` in runs, in order (ST-T04): each range is
        /// one record drawn on its own, or one instanced run, which is bound
        /// once and draws one or more instanced draws (`forEachDraw`).
        var opaqueRuns: [Range<Int>] = []
        var transparentRuns: [Range<Int>] = []
        /// The instanced shadow casters: stretches of the opaque instanced draws
        /// whose records cast shadows. Every other caster is in `shadowCasters`.
        var instancedShadowCasters: [Range<Int>] = []
        /// ST-A11 map sky draws (`MaterialKindSky`): drawn after the background
        /// with no depth test or write; never shadow casters, picked or live.
        var sky: [DrawRecord] = []
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

    /// True when every element of every matrix is finite. `abs(x) <= max`
    /// is false exactly for NaN and ±infinity, so this equals checking
    /// `isFinite` per element, four lanes at a time.
    static func allFinite(_ matrices: [float4x4]) -> Bool {
        let limit = SIMD4<Float>(repeating: .greatestFiniteMagnitude)
        for m in matrices {
            let a = abs(m.columns.0) .<= limit, b = abs(m.columns.1) .<= limit
            let c = abs(m.columns.2) .<= limit, d = abs(m.columns.3) .<= limit
            guard all(a .& b .& c .& d) else { return false }
        }
        return true
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

    private func publish(deformationErrors: [String]) {
        statusLock.lock(); publishedDeformationErrors = deformationErrors; statusLock.unlock()
    }

    private func publish(gpuTime: Double) {
        statusLock.lock(); publishedGPUTime = gpuTime; statusLock.unlock()
    }

    /// Prepares a frame and publishes its statistics and error. Throws only
    /// `RenderFrameError.uniformAllocation`; nothing has been encoded by then.
    /// Caller holds renderLock.
    func prepare(frame input: RenderFrame, targets: RenderTargets, forPick: Bool = false,
                 deforms mode: DeformMode = .always) throws -> FrameContext {
        // A submitted frame created after a retirement replaced every pending frame
        // that could still name the retired resources (`ResourceStore.retire`).
        if input.submitted { dropDeformContent(resources.completeRetirements(createdBefore: input.createdAt)) }
        var statistics = RenderFrameStatistics()
        var tracking: DeformTracking
        switch mode {
        case .always: tracking = DeformTracking(track: true, reuse: false)
        case .reuse: tracking = DeformTracking(track: true, reuse: deformReuse)
        case .interactive:
            if deformReuse, deformBypass > 0 { deformBypass -= 1 }
            let track = !deformReuse || deformBypass == 0
            tracking = DeformTracking(track: track, reuse: deformReuse && track)
        }
        do {
            let context = try buildContext(frame: input, targets: targets, forPick: forPick,
                                           deforms: &tracking, statistics: &statistics)
            if mode == .interactive, tracking.reuse {
                // Every deformation that had a record changed: after two such
                // draws, stop comparing and recording for a while (a Maker
                // slider drag), as the comparisons would only cost CPU.
                if statistics.deformReuses > 0 { deformMisses = 0 }
                else if tracking.compared > 0 {
                    deformMisses += 1
                    if deformMisses >= Self.deformMissesBeforeBypass { deformMisses = 0; deformBypass = Self.deformBypassDraws }
                }
            }
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
                              deforms tracking: inout DeformTracking,
                              statistics: inout RenderFrameStatistics) throws -> FrameContext {
        var frame = input
        frame.retainTextures(from: resources)
        // Published when the context is built or fails, like the statistics.
        var deformationErrors: [String] = []
        defer { publish(deformationErrors: deformationErrors) }
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

        // Complete skin palettes go to the frame ring's palette storage (G4):
        // one buffer per ring region, reused once its frames complete, so a
        // steady scene allocates nothing per draw. Each referenced set is
        // validated element by element first, as before.
        var skinPalettes: [UInt64: (allocation: FrameAllocation, count: Int, matrices: [float4x4])] = [:]
        // Only an item with a skin set can reference one: the mesh lookup
        // (the store's lock) is left for those.
        var referencedSkinSets = Set<UInt64>()
        frame.items.withUnsafeBufferPointer { items in
            for index in items.indices where items[index].visible {
                if let key = items[index].skinSet, resources.mesh(items[index].mesh)?.skin != nil { referencedSkinSets.insert(key) }
            }
        }
        var paletteKeys: [UInt64] = [], palettes: [[float4x4]] = []
        for (key, mats) in frame.skinSets where referencedSkinSets.contains(key) {
            guard !mats.isEmpty, mats.count <= Int(UInt32.max), Renderer.allFinite(mats) else {
                deformationErrors.append("Skin set \(key) is empty, oversized, or contains nonfinite matrices")
                continue
            }
            paletteKeys.append(key); palettes.append(mats)
        }
        if !palettes.isEmpty {
            do {
                skinPalettes.reserveCapacity(palettes.count)
                // The matrices stay with the allocation: a deformation's content names them.
                for (index, allocation) in try frameRing.allocatePalettes(palettes).enumerated() {
                    skinPalettes[paletteKeys[index]] = (allocation, palettes[index].count, palettes[index])
                }
                statistics.skinPalettes = palettes.count
            } catch {
                // As a refused per-set buffer did: the sets' draws are skipped.
                deformationErrors += paletteKeys.map { "Could not allocate skin set \($0)" }
            }
        }

        // Room for every item up front: a record holds its item, so regrowing
        // these arrays moved every record again.
        var opaque: [DrawRecord] = [], transparent: [DrawRecord] = [], casters: [DrawRecord] = []
        opaque.reserveCapacity(frame.items.count); transparent.reserveCapacity(frame.items.count); casters.reserveCapacity(frame.items.count)
        var sky: [DrawRecord] = []
        var deforms: [DeformRecord] = []
        // Each deformation key's buffer in this preparation, from the key's
        // first item. Its other items (one per material pass) draw what that
        // item's dispatch writes, so they reuse the buffer instead of asking
        // the store again: a transient buffer (a stale frame, or an owner
        // dropped mid-preparation, #344) is a new object per request, and a
        // second request would give a later item an undispatched buffer.
        var deformed: [UInt64: any MTLBuffer] = [:]
        var deformHeld = 0
        var liveCandidates: [DrawRecord] = []
        // ST-T04: static item records merge into instanced runs, except in a
        // frame with live source-shader draws, whose stencil main pass has no
        // instanced pipelines.
        let instancing = instanceItems && !frame.items.contains { $0.visible && $0.sourceShader != nil }
        pendingDraws.removeAll(keepingCapacity: true)
        pendingMaterials.removeAll(keepingCapacity: true)

        for item in frame.items where item.visible {
            guard let mesh = resources.mesh(item.mesh) else { continue }
            let isSky = item.material.uniforms.kind == UInt32(MaterialKindSky.rawValue)
            // A sky draw needs its cube: without it there is nothing to sample.
            if isSky, frame.texture(item.material.cubemap, resources: resources)?.textureType != .typeCube { continue }
            let palette = item.skinSet.flatMap { skinPalettes[$0] }
            if mesh.skin != nil, let key = item.skinSet {
                do {
                    guard item.deformKey != nil, let palette else {
                        throw ResourceError.invalidSkin("\(mesh.name): missing deformation key or skin set \(key)")
                    }
                    try mesh.validateSkinPalette(boneCount: palette.count)
                } catch {
                    deformationErrors.append(String(describing: error))
                    continue
                }
            }
            var vb: any MTLBuffer = mesh.baseVertices
            if let key = item.deformKey, mesh.needsDeform {
                if let first = deformed[key] {
                    vb = first
                } else {
                    guard let buf = resources.deformBuffer(for: key, mesh: item.mesh, vertexCount: mesh.vertexCount, frameCreatedAt: frame.createdAt) else {
                        deformationErrors.append("\(mesh.name): could not allocate deformation buffer \(key)")
                        continue
                    }
                    vb = buf
                    deformed[key] = buf
                    let entries = Renderer.activeMorphEntries(item.morphWeights, targetCount: mesh.morphNames.count)
                    let morphs = try frameRing.allocate(array: entries)
                    let skin = mesh.skin != nil ? palette : nil
                    var content: DeformContent?
                    var dispatch = true
                    if tracking.track {
                        let inputs = DeformContent(mesh: mesh, palette: skin?.matrices, morphs: entries)
                        // The buffer already holds these vertices when the last
                        // committed dispatch into it had the same inputs.
                        if let held = deformContent[key] {
                            deformHeld += 1; tracking.compared += 1
                            if tracking.reuse, held.buffer === buf, held.content.matches(inputs) { dispatch = false }
                        }
                        content = inputs
                    } else {
                        statistics.deformUntracked += 1
                    }
                    deforms.append(DeformRecord(key: key, mesh: mesh, buffer: buf, skinBuffer: skin?.allocation.buffer,
                                                skinOffset: skin?.allocation.offset ?? 0,
                                                boneCount: skin?.count ?? 0, morphs: morphs, morphCount: entries.count,
                                                content: content, dispatch: dispatch))
                    if dispatch { statistics.deformDispatches += 1 } else { statistics.deformReuses += 1 }
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
            var mu = item.material.uniforms
            if item.material.transparent { mu.flags |= MaterialFlagAlphaBlend.rawValue }
            else { mu.flags &= ~MaterialFlagAlphaBlend.rawValue }
            if frame.texture(item.material.base, resources: resources) == nil { mu.flags &= ~MaterialFlagHasBaseTexture.rawValue }
            if frame.texture(item.material.bodyMask, resources: resources) == nil { mu.flags &= ~MaterialFlagHasBodyMask.rawValue }
            if mesh.colors != nil { mu.flags |= MaterialFlagHasVertexColor.rawValue } else { mu.flags &= ~MaterialFlagHasVertexColor.rawValue }
            let c = item.model.transformPoint(item.sortCenter ?? mesh.bounds.center)
            if instancing, Self.instanceable(item, mesh: mesh, isSky: isSky) {
                // Its uniforms are placed once the passes are sorted (`assignRuns`):
                // in an instanced draw, which also casts its shadow, or on its own.
                let rec = DrawRecord(item: item, mesh: mesh, vertexBuffer: vb, hiddenBuffer: hb, draw: frameUniforms,
                                     material: frameUniforms, distance: length(c - cp), pending: pendingDraws.count)
                pendingDraws.append(du)
                pendingMaterials.append(mu)
                if item.material.transparent { transparent.append(rec) } else { opaque.append(rec) }
                continue
            }
            let drawUniforms = try frameRing.allocate(du)
            let materialUniforms = try frameRing.allocate(mu)
            let rec = DrawRecord(item: item, mesh: mesh, vertexBuffer: vb, hiddenBuffer: hb, draw: drawUniforms,
                                 material: materialUniforms, distance: length(c - cp))
            if isSky { sky.append(rec); continue }
            if item.sourceShader != nil { liveCandidates.append(rec) }
            else if item.material.transparent { transparent.append(rec) } else { opaque.append(rec) }
            if item.castsShadow && !item.material.transparent { casters.append(rec) }
        }
        // Records of keys this frame does not use name buffers and meshes that
        // may have been released: drop them, which also releases those.
        if tracking.track, deformContent.count > deformHeld { deformContent = deformContent.filter { deformed[$0.key] != nil } }
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
        Self.sortOpaque(&opaque)
        Self.sortTransparent(&transparent)
        Self.sortOpaque(&sky)
        let opaqueRuns = try assignRuns(&opaque, casters: &casters, statistics: &statistics)
        let transparentRuns = try assignRuns(&transparent, casters: &casters, statistics: &statistics)
        var instancedShadowCasters: [Range<Int>] = []
        for run in opaqueRuns where opaque[run.lowerBound].instanced {
            Self.forEachDraw(run, of: opaque) { instancedShadowCasters += Self.stretches($0, of: opaque) { $0.item.castsShadow } }
        }
        statistics.shadowCasters = casters.count + instancedShadowCasters.reduce(0) { $0 + $1.count }
        statistics.shadowDraws = casters.count + instancedShadowCasters.count
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
                            opaque: opaque, transparent: transparent, opaqueRuns: opaqueRuns, transparentRuns: transparentRuns,
                            instancedShadowCasters: instancedShadowCasters, sky: sky, shadowCasters: casters, deforms: deforms,
                            gizmos: gizmos, width: W, height: H, live: live, liveMainPass: liveMainPass)
    }

    // MARK: - Instanced static items (ST-T04)

    /// B1: only static item records merge: records the Studio marks as props
    /// (`RenderItem.staticItem`), with no deformation, skin or morphs, no
    /// hidden regions or hidden buffer, no live source shader, not the sky, and
    /// the item material kind only. Characters, eyes and maps are never marked
    /// and keep their per-draw path. Gizmos are `GizmoRecord`s and never reach here.
    static func instanceable(_ item: RenderItem, mesh: GPUMesh, isSky: Bool) -> Bool {
        item.staticItem && item.deformKey == nil && item.skinSet == nil && item.morphWeights.isEmpty && mesh.skin == nil
            && item.hiddenKey == nil && item.hiddenRegions == 0 && item.sourceShader == nil && !isSky
            && item.material.uniforms.kind == UInt32(MaterialKindItem.rawValue)
    }

    /// Whether two instanceable records draw with the same bindings and state,
    /// apart from their MaterialUniforms: the same mesh (so the same vertex,
    /// texcoord, colour and index buffers), the same material apart from its
    /// base colour (so the same pipeline, textures, alpha mode,
    /// double-sidedness and depth bias), the same outline choice, and the same
    /// winding (a mirrored model reverses front faces, set once per run).
    /// Records that merge share one instanced draw only when their
    /// MaterialUniforms are also equal byte for byte (`assignRuns`).
    ///
    /// The records are read where they lie, field by field (B2-v2): passing
    /// them by value copied each one, about 750 bytes with its item's
    /// references to retain and release, and on the instanced corpus frame
    /// those copies were about 16% of the CPU encode time. `a` and `b` point
    /// into `assignRuns`'s buffer and are only read here.
    @inline(__always)
    static func mergesWith(_ a: UnsafePointer<DrawRecord>, _ b: UnsafePointer<DrawRecord>) -> Bool {
        guard a.pointee.item.mesh == b.pointee.item.mesh, a.pointee.item.outline == b.pointee.item.outline,
              mirrored(a.pointee.item.model) == mirrored(b.pointee.item.model) else { return false }
        let material = MemoryLayout<DrawRecord>.offset(of: \DrawRecord.item.material)!
        return MaterialState.equalApartFromBaseColor((UnsafeRawPointer(a) + material).assumingMemoryBound(to: MaterialState.self),
                                                     (UnsafeRawPointer(b) + material).assumingMemoryBound(to: MaterialState.self))
    }

    static func mirrored(_ model: float4x4) -> Bool { simd_determinant(model.upperLeft3x3) < 0 }

    /// Groups sorted records into runs and draws (ST-T04). An instanced draw is
    /// an adjacent stretch of at least two instanceable records that merge
    /// (`mergesWith`) and whose MaterialUniforms are equal byte for byte, so the
    /// draw binds one material, as one record does, and the per-draw fragment
    /// functions shade every instance as they shade the record on its own. An
    /// instanced run is an adjacent stretch of instanced draws that merge, bound
    /// once. The draws' DrawUniforms go into the pass's table in record order
    /// (an instance's `instance_id` is its element), their materials into one
    /// allocation, one 256-byte aligned element per draw, so the next draw of a
    /// run changes only the bound material offset. Every other record is a run
    /// of its own with its own allocations; an instanceable one that casts a
    /// shadow joins `casters`. Merging adjacent records only keeps the sorted
    /// order, so the transparent pass blends exactly as it does one record at a time.
    func assignRuns(_ records: inout [DrawRecord], casters: inout [DrawRecord],
                    statistics: inout RenderFrameStatistics) throws -> [Range<Int>] {
        try Self.assignRuns(&records, casters: &casters, draws: pendingDraws, materials: pendingMaterials, ring: frameRing,
                            statistics: &statistics)
    }

    /// `assignRuns` on the given pending uniforms and ring (the tests run it
    /// beside the by-value version it replaced). The records are read and
    /// updated in their array's buffer, never copied, except a record drawn
    /// on its own that casts a shadow, which `casters` gets by value as before.
    ///
    /// Memory safety: `p`, `d` and `m` are the buffers of `records`,
    /// `pendingDraws` and `pendingMaterials`. They are valid only inside their
    /// `with…` closures and never escape them, and while the closures run
    /// nothing reaches those three arrays any other way (`casters` is another
    /// array). `m` is read only at a record's `pending` index, which exists
    /// exactly when `pendingMaterials` has that element.
    static func assignRuns(_ records: inout [DrawRecord], casters: inout [DrawRecord], draws pendingDraws: [DrawUniforms],
                           materials pendingMaterials: [MaterialUniforms], ring: FrameRing,
                           statistics: inout RenderFrameStatistics) throws -> [Range<Int>] {
        let count = records.count
        return try records.withUnsafeMutableBufferPointer { p -> [Range<Int>] in
            try pendingDraws.withUnsafeBufferPointer { d -> [Range<Int>] in
                try pendingMaterials.withUnsafeBufferPointer { m -> [Range<Int>] in
                    var draws: [Range<Int>] = []
                    var members = 0
                    if let r = p.baseAddress {
                        var i = 0
                        while i < count {
                            guard r[i].pending >= 0 else { i += 1; continue }
                            var j = i + 1
                            while j < count, r[j].pending >= 0, mergesWith(r + i, r + j),
                                  memcmp(m.baseAddress! + r[i].pending, m.baseAddress! + r[j].pending,
                                         MemoryLayout<MaterialUniforms>.size) == 0 { j += 1 }
                            if j - i > 1 { draws.append(i..<j); members += j - i }
                            i = j
                        }
                    }
                    statistics.mainPassRecords += count
                    statistics.mainPassRuns += count - members + draws.count
                    statistics.instancedRecords += members
                    statistics.instancedRuns += draws.count
                    guard let r = p.baseAddress else { return [] }
                    // The table's elements are written at the Swift stride, which the
                    // shaders' `constant DrawUniforms*` shares (144 bytes; the instanced
                    // versus per-draw tests compare).
                    let drawStride = MemoryLayout<DrawUniforms>.stride
                    let materialStride = (MemoryLayout<MaterialUniforms>.stride + FrameRing.alignment - 1) / FrameRing.alignment * FrameRing.alignment
                    let table = draws.isEmpty ? nil : try ring.allocate(byteCount: drawStride * members)
                    let materials = draws.isEmpty ? nil : try ring.allocate(byteCount: materialStride * draws.count)
                    var runs: [Range<Int>] = []
                    runs.reserveCapacity(count - members + draws.count)
                    var next = 0, instance = 0
                    var i = 0
                    while i < count {
                        if next < draws.count, draws[next].lowerBound == i, let table, let materials {
                            let run = runs.count
                            let tableBytes = table.buffer.contents(), materialBytes = materials.buffer.contents()
                            var end = i
                            repeat {
                                let draw = draws[next]
                                let element = materials.advanced(by: materialStride * next)
                                materialBytes.storeBytes(of: m[r[draw.lowerBound].pending], toByteOffset: element.offset,
                                                         as: MaterialUniforms.self)
                                for k in draw {
                                    tableBytes.storeBytes(of: d[r[k].pending], toByteOffset: table.offset + drawStride * instance,
                                                          as: DrawUniforms.self)
                                    r[k].draw = table; r[k].material = element; r[k].instance = instance
                                    r[k].pending = -1; r[k].run = run
                                    instance += 1
                                }
                                end = draw.upperBound
                                next += 1
                            } while next < draws.count && draws[next].lowerBound == end && mergesWith(r + i, r + end)
                            runs.append(i..<end)
                            i = end
                            continue
                        }
                        if r[i].pending >= 0 {
                            // No equal neighbour: drawn on its own, exactly as before.
                            let index = r[i].pending
                            r[i].draw = try ring.allocate(d[index])
                            r[i].material = try ring.allocate(m[index])
                            r[i].pending = -1
                            if r[i].item.castsShadow && !r[i].item.material.transparent { casters.append(r[i]) }
                        }
                        runs.append(i..<i + 1)
                        i += 1
                    }
                    return runs
                }
            }
        }
    }

    /// The instanced draws of an instanced run, in order: the stretches of its
    /// members that share one material element (one offset in one allocation).
    static func forEachDraw(_ run: Range<Int>, of records: [DrawRecord], _ body: (Range<Int>) -> Void) {
        var start = run.lowerBound
        for k in run.dropFirst() where records[k].material.offset != records[start].material.offset {
            body(start..<k)
            start = k
        }
        body(start..<run.upperBound)
    }

    /// The contiguous stretches of `run` whose records satisfy `include`, in order.
    static func stretches(_ run: Range<Int>, of records: [DrawRecord], where include: (DrawRecord) -> Bool) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for k in run {
            if include(records[k]) { if start == nil { start = k } }
            else if let first = start { result.append(first..<k); start = nil }
        }
        if let first = start { result.append(first..<run.upperBound) }
        return result
    }

    /// The opaque order: draw order, then material kind, then mesh id; equal
    /// records keep their input order.
    ///
    /// Both sorts sort small keys, not the records: a record holds its item,
    /// and moving whole records was the largest cost of preparing a
    /// 3,506-item frame (0.58 ms). Each key carries its record's index, which
    /// also decides between equal keys, so the order is the stable order the
    /// record sort gave. The records are then moved into that order in place
    /// (`permute`, B2-v2): mapping them into a new array copied each one and
    /// released the old array's.
    static func sortOpaque(_ records: inout [DrawRecord]) {
        var keys: [(order: Int, kind: UInt32, mesh: UInt32, index: Int)] = []
        keys.reserveCapacity(records.count)
        records.withUnsafeBufferPointer { records in
            for index in records.indices {
                keys.append((records[index].item.order, records[index].item.material.uniforms.kind, records[index].item.mesh.id, index))
            }
        }
        keys.sort { a, b in
            if a.order != b.order { return a.order < b.order }
            if a.kind != b.kind { return a.kind < b.kind }
            if a.mesh != b.mesh { return a.mesh < b.mesh }
            return a.index < b.index
        }
        permute(&records) { keys[$0].index }
    }

    /// Unity's order for transparent draws: render queue, then camera distance
    /// to the sort centre (back to front); then our draw order and mesh id;
    /// equal records keep their input order. Sorted by keys, as `sortOpaque`.
    static func sortTransparent(_ records: inout [DrawRecord]) {
        var keys: [(queue: Int, distance: Float, order: Int, mesh: UInt32, index: Int)] = []
        keys.reserveCapacity(records.count)
        records.withUnsafeBufferPointer { records in
            for index in records.indices {
                keys.append((records[index].item.renderQueue, records[index].distance, records[index].item.order,
                             records[index].item.mesh.id, index))
            }
        }
        keys.sort { a, b in
            if a.queue != b.queue { return a.queue < b.queue }
            if a.distance != b.distance { return a.distance > b.distance }
            if a.order != b.order { return a.order < b.order }
            if a.mesh != b.mesh { return a.mesh < b.mesh }
            return a.index < b.index
        }
        permute(&records) { keys[$0].index }
    }

    /// `sortOpaque` on a copy (the tests compare it with the record sort it replaced).
    static func sortedOpaque(_ records: [DrawRecord]) -> [DrawRecord] {
        var sorted = records
        sortOpaque(&sorted)
        return sorted
    }

    /// `sortTransparent` on a copy.
    static func sortedTransparent(_ records: [DrawRecord]) -> [DrawRecord] {
        var sorted = records
        sortTransparent(&sorted)
        return sorted
    }

    /// Puts the record at index `source(k)` at index `k`, for every `k`, by
    /// moving each record once along the permutation's cycles: no copy, no
    /// retain or release, no second array. `source` must be a permutation of
    /// the indices. A record already in its place (`source(k) == k`) is not
    /// touched, and each cycle is followed from its first unplaced index, so
    /// every record moves exactly once.
    ///
    /// Memory safety: `base` is `records`' buffer, valid only inside its
    /// closure, and never escapes it. Inside a cycle exactly one slot is
    /// uninitialized at a time (the hole): `held` takes the cycle's first
    /// record, each step moves a record into the hole and leaves its old slot
    /// as the new hole, and the last hole gets `held` back. Nothing in between
    /// can throw or read `records`.
    static func permute(_ records: inout [DrawRecord], source: (Int) -> Int) {
        let count = records.count
        guard count > 1 else { return }
        var placed = [Bool](repeating: false, count: count)
        records.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            for start in 0..<count where !placed[start] {
                placed[start] = true
                var from = source(start)
                guard from != start else { continue }
                var hole = start
                let held = (base + start).move()
                while from != start {
                    precondition(!placed[from], "permute: source is not a permutation")
                    (base + hole).moveInitialize(from: base + from, count: 1)
                    placed[from] = true
                    hole = from
                    from = source(hole)
                }
                (base + hole).initialize(to: held)
            }
        }
    }

    // MARK: - Encoding

    /// Encodes the whole pass graph; returns the deform writes for `commit(_:writes:)`.
    private func encode(frame: RenderFrame, target: any MTLTexture, targets: RenderTargets, commandBuffer cb: any MTLCommandBuffer,
                        deforms mode: DeformMode) throws -> DeformWrites {
        let ctx = try prepare(frame: frame, targets: targets, deforms: mode)
        let writes = encodeDeform(ctx, cb)
        if !ctx.live.isEmpty { encodeLiveInputs(ctx, cb) }
        encodeShadow(ctx, cb)
        encodeMain(ctx, targets: targets, cb)
        encodePost(ctx, targets: targets, target: target, cb)
        encodeOverlay(ctx, targets: targets, target: target, cb)
        return writes
    }

    /// Encodes the frame's deform dispatches (not the reused ones) and returns
    /// them for `commit(_:writes:)`. Caller holds renderLock and commits `cb`
    /// with `commit(_:writes:)` in the same hold, or abandons it. From here
    /// until that commit the record names no content for the written buffers,
    /// so an abandoned command buffer can only cost a later frame a dispatch.
    @discardableResult
    func encodeDeform(_ ctx: FrameContext, _ cb: any MTLCommandBuffer) -> DeformWrites {
        guard ctx.deforms.contains(where: \.dispatch), let enc = cb.makeComputeCommandEncoder() else { return .none }
        enc.label = "Deform"
        enc.setComputePipelineState(pipelines.deform)
        let dummy = resources.dummyBuffer
        for d in ctx.deforms where d.dispatch {
            if !deformContent.isEmpty { deformContent[d.key] = nil }
            var params = DeformParams(vertexCount: UInt32(d.mesh.vertexCount), activeMorphCount: UInt32(d.morphCount),
                                      hasSkin: d.skinBuffer != nil ? 1 : 0, hasMorphNormals: d.mesh.morphNormals != nil ? 1 : 0,
                                      boneCount: UInt32(d.boneCount))
            enc.setBuffer(d.mesh.baseVertices, offset: 0, index: Int(BufferIndexBaseVertices.rawValue))
            enc.setBuffer(d.buffer, offset: 0, index: Int(BufferIndexVertices.rawValue))
            enc.setBuffer(d.mesh.skin ?? dummy, offset: 0, index: Int(BufferIndexSkinData.rawValue))
            if let skin = d.skinBuffer { enc.setBuffer(skin, offset: d.skinOffset, index: Int(BufferIndexSkinMatrices.rawValue)) }
            else { enc.setBuffer(dummy, offset: 0, index: Int(BufferIndexSkinMatrices.rawValue)) }
            enc.setBuffer(d.morphs.buffer, offset: d.morphs.offset, index: Int(BufferIndexMorphWeights.rawValue))
            enc.setBuffer(d.mesh.morphDeltas ?? dummy, offset: 0, index: Int(BufferIndexMorphDeltas.rawValue))
            enc.setBuffer(d.mesh.morphNormals ?? dummy, offset: 0, index: Int(BufferIndexMorphNormals.rawValue))
            enc.setBytes(&params, length: MemoryLayout<DeformParams>.stride, index: Int(BufferIndexDeformParams.rawValue))
            let w = min(pipelines.deform.maxTotalThreadsPerThreadgroup, 64)
            enc.dispatchThreads(MTLSize(width: d.mesh.vertexCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        }
        enc.endEncoding()
        return DeformWrites(deforms: ctx.deforms)
    }

    /// Commits `cb`, which dispatched `writes`, and records what their buffers
    /// hold now. Caller holds renderLock and has held it since `encodeDeform`
    /// encoded `writes`: every command buffer that dispatches the deform pass
    /// commits here, on the one `gpu.commandQueue`, so the queue runs them in
    /// the order the record changed, and a buffer's recorded content is what
    /// the last command buffer to write it in queue order wrote. A later
    /// command buffer that binds the buffer without dispatching reads it after
    /// that write (Metal tracks the hazard between them). A command buffer that
    /// fails forgets its writes, unless a later one replaced them, and drops
    /// the cached interactive image, which may have read them.
    func commit(_ cb: any MTLCommandBuffer, writes: DeformWrites) {
        // This command buffer's records take consecutive serials from `first`.
        let first = deformWriteSerial &+ 1
        var count: UInt64 = 0
        for d in writes.deforms where d.dispatch {
            guard let content = d.content else { continue }
            deformWriteSerial &+= 1; count += 1
            deformContent[d.key] = DeformBufferRecord(buffer: d.buffer, content: content, serial: deformWriteSerial)
        }
        guard count > 0 else { cb.commit(); return }
        cb.addCompletedHandler { [weak self, count] c in
            guard c.status != .completed, let self else { return }
            self.renderLock.lock()
            // Its own records only: a later write's serial lies outside the range.
            self.deformContent = self.deformContent.filter { $0.value.serial &- first >= count }
            self.drawnFrame = nil
            self.renderLock.unlock()
        }
        cb.commit()
    }

    func bindCommon(_ s: EncoderState, _ ctx: FrameContext) {
        s.setVertexBuffer(ctx.frameUniforms.buffer, offset: ctx.frameUniforms.offset, index: Int(BufferIndexFrameUniforms.rawValue))
        s.setFragmentBuffer(ctx.frameUniforms.buffer, offset: ctx.frameUniforms.offset, index: Int(BufferIndexFrameUniforms.rawValue))
        s.setFragmentBuffer(ctx.lights.buffer, offset: ctx.lights.offset, index: Int(BufferIndexLights.rawValue))
        s.setFragmentTexture(shadowMap, index: Int(TextureIndexShadowMap.rawValue))
        s.setFrontFacing(.counterClockwise)
    }

    private func bindDraw(_ s: EncoderState, _ rec: DrawRecord) {
        // Mirrored scene nodes reverse triangle orientation in every geometry pass.
        s.setFrontFacing(simd_determinant(rec.item.model.upperLeft3x3) < 0 ? .clockwise : .counterClockwise)
        s.setVertexBuffer(rec.vertexBuffer, offset: 0, index: Int(BufferIndexVertices.rawValue))
        s.setVertexBuffer(rec.mesh.texcoords, offset: 0, index: Int(BufferIndexTexcoords.rawValue))
        s.setVertexBuffer(rec.mesh.texcoords1, offset: 0, index: Int(BufferIndexTexcoords1.rawValue))
        s.setVertexBuffer(rec.mesh.texcoords2, offset: 0, index: Int(BufferIndexTexcoords2.rawValue))
        s.setVertexBuffer(rec.mesh.colors ?? resources.dummyBuffer, offset: 0, index: Int(BufferIndexVertexColors.rawValue))
        s.setVertexBuffer(rec.draw.buffer, offset: rec.draw.offset, index: Int(BufferIndexDrawUniforms.rawValue))
        s.setVertexBuffer(rec.material.buffer, offset: rec.material.offset, index: Int(BufferIndexMaterial.rawValue))
        s.setVertexBuffer(rec.hiddenBuffer ?? resources.dummyBuffer, offset: 0, index: Int(BufferIndexVertexHidden.rawValue))
        s.setFragmentBuffer(rec.draw.buffer, offset: rec.draw.offset, index: Int(BufferIndexDrawUniforms.rawValue))
        s.setFragmentBuffer(rec.material.buffer, offset: rec.material.offset, index: Int(BufferIndexMaterial.rawValue))
    }

    /// The material's textures, by its kind. They depend only on its kind and
    /// handles (the frame resolves each handle the same way all frame long),
    /// so a material with the same set as the last one bound binds nothing.
    private func bindTextures(_ s: EncoderState, _ m: MaterialState, frame: RenderFrame) {
        let set = m.textureSet
        if s.skips, s.boundTextureSet == set { return }
        s.boundTextureSet = set
        let white = resources.whiteTexture, black = resources.blackTexture
        if m.uniforms.kind == UInt32(MaterialKindSky.rawValue) {
            // sky_fragment samples only the cube (ST-A11 map sky). prepare drops a
            // sky draw whose cube does not resolve, so index 19 always holds a cube here.
            if let cube = frame.texture(m.cubemap, resources: resources) {
                s.setFragmentTexture(cube, index: Int(TextureIndexSkyCube.rawValue))
            }
            return
        }
        s.setFragmentTexture(frame.texture(m.base, resources: resources) ?? white, index: Int(TextureIndexBase.rawValue))
        if m.uniforms.kind == UInt32(MaterialKindMap.rawValue) {
            // map_fragment samples only these four (ST-A11 source maps).
            s.setFragmentTexture(frame.texture(m.lightmap, resources: resources) ?? black, index: Int(TextureIndexLightmap.rawValue))
            s.setFragmentTexture(frame.texture(m.lightmapDirection, resources: resources) ?? black,
                                 index: Int(TextureIndexLightmapDirection.rawValue))
            // Unity's _EmissionMap default is white; map_fragment reads it only when emissive.a > 0.
            s.setFragmentTexture(frame.texture(m.emission, resources: resources) ?? white, index: Int(TextureIndexEmission.rawValue))
            return
        }
        s.setFragmentTexture(frame.texture(m.colorMask, resources: resources) ?? black, index: Int(TextureIndexColorMask.rawValue))
        let isEye = m.uniforms.kind == UInt32(MaterialKindEye.rawValue)
        s.setFragmentTexture(frame.texture(m.detail, resources: resources) ?? (isEye ? black : white), index: Int(TextureIndexDetail.rawValue))
        s.setFragmentTexture(frame.texture(m.line, resources: resources) ?? black, index: Int(TextureIndexLine.rawValue))
        s.setFragmentTexture(frame.texture(m.normal, resources: resources) ?? resources.flatNormalTexture, index: Int(TextureIndexNormal.rawValue))
        s.setFragmentTexture(frame.texture(m.overlay0, resources: resources) ?? black, index: Int(TextureIndexOverlay0.rawValue))
        s.setFragmentTexture(frame.texture(m.overlay1, resources: resources) ?? black, index: Int(TextureIndexOverlay1.rawValue))
        s.setFragmentTexture(frame.texture(m.overlay2, resources: resources) ?? black, index: Int(TextureIndexOverlay2.rawValue))
        s.setFragmentTexture(frame.texture(m.hairGloss, resources: resources) ?? white, index: Int(TextureIndexHairGloss.rawValue))
        s.setFragmentTexture(frame.texture(m.pattern, resources: resources) ?? white, index: Int(TextureIndexPattern.rawValue))
        s.setFragmentTexture(frame.texture(m.bodyMask, resources: resources) ?? black, index: Int(TextureIndexBodyMask.rawValue))
    }

    /// The base and body-mask textures, all the shadow and pick fragment functions read.
    private func bindMaskTextures(_ s: EncoderState, _ m: MaterialState, frame: RenderFrame, base: Bool) {
        if base { s.setFragmentTexture(frame.texture(m.base, resources: resources) ?? resources.whiteTexture, index: Int(TextureIndexBase.rawValue)) }
        s.setFragmentTexture(frame.texture(m.bodyMask, resources: resources) ?? resources.blackTexture, index: Int(TextureIndexBodyMask.rawValue))
    }

    private func drawIndexed(_ s: EncoderState, _ mesh: GPUMesh) {
        s.encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
    }

    /// `records[stretch]`, all of one instanced draw, after `bindDraw` of a
    /// record of its run: the instances are the table's elements from the
    /// first record's on, in order. Another draw's material element moves the
    /// bound material offset, vertex and fragment, on the allocation its run bound.
    private func drawInstanced(_ s: EncoderState, _ stretch: Range<Int>, of records: [DrawRecord]) {
        let first = records[stretch.lowerBound]
        s.setBufferOffsets(first.material.offset, index: Int(BufferIndexMaterial.rawValue))
        s.encoder.drawIndexedPrimitives(type: .triangle, indexCount: first.mesh.indexCount, indexType: .uint32, indexBuffer: first.mesh.indices,
                                        indexBufferOffset: 0, instanceCount: stretch.count, baseVertex: 0, baseInstance: first.instance)
    }

    /// One run after `bindDraw` of its first record: the record's own draw, or
    /// each of the run's instanced draws in order.
    private func drawRun(_ s: EncoderState, _ run: Range<Int>, of records: [DrawRecord]) {
        guard records[run.lowerBound].instanced else { drawIndexed(s, records[run.lowerBound].mesh); return }
        Self.forEachDraw(run, of: records) { drawInstanced(s, $0, of: records) }
    }

    private func encodeShadow(_ ctx: FrameContext, _ cb: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = shadowMap
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Shadow"
        let s = EncoderState(enc, skips: skipRedundantState)
        if ctx.frame.mainLight.castsShadow {
            s.setPipeline(pipelines.shadow)
            s.setDepthStencil(pipelines.depthWrite)
            s.setCull(.none)
            enc.setDepthBias(1.0, slopeScale: 1.5, clamp: 0.01)
            bindCommon(s, ctx)
            for rec in ctx.shadowCasters {
                bindDraw(s, rec)
                bindMaskTextures(s, rec.item.material, frame: ctx.frame, base: true)
                drawIndexed(s, rec.mesh)
            }
            // Instanced static items (ST-T04), through the same pipeline: its
            // vertex function reads DrawUniforms by instance (B0). A depth-only
            // pass keeps the nearest depth whatever the order, so drawing these
            // after the other casters stores what drawing each record in turn
            // stores. A run is bound once; its next stretch changes only the material.
            var boundRun = -1
            for stretch in ctx.instancedShadowCasters {
                let rec = ctx.opaque[stretch.lowerBound]
                if rec.run != boundRun {
                    bindDraw(s, rec)
                    bindMaskTextures(s, rec.item.material, frame: ctx.frame, base: true)
                    boundRun = rec.run
                }
                drawInstanced(s, stretch, of: ctx.opaque)
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
        if targets.pixelCentreSamples {
            // Every sample at the centre: coverage and depth are all or nothing per pixel, so the
            // resolve equals a single-sample render (captureSceneHDR(pixelCentreSamples:)). The positions
            // belong to this pass's own descriptor, so no later pass or frame inherits them.
            let centre = [MTLSamplePosition](repeating: MTLSamplePosition(x: 0.5, y: 0.5), count: Pipelines.sampleCount)
            pass.setSamplePositions(centre)
        }
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
        let s = EncoderState(enc, skips: skipRedundantState)
        bindCommon(s, ctx)

        if !fx.transparentBackground, let background = ctx.background {
            enc.pushDebugGroup("Background")
            s.setPipeline(main.background)
            s.setDepthStencil(pipelines.depthNone)
            s.setCull(.none)
            s.setFragmentBuffer(background.buffer, offset: background.offset, index: Int(BufferIndexFrameUniforms.rawValue))
            s.setFragmentBuffer(ctx.post.buffer, offset: ctx.post.offset, index: Int(BufferIndexPostParams.rawValue))
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            s.setFragmentBuffer(ctx.frameUniforms.buffer, offset: ctx.frameUniforms.offset, index: Int(BufferIndexFrameUniforms.rawValue))
            enc.popDebugGroup()
        }
        if !ctx.sky.isEmpty {
            // Unity draws Background-queue geometry first, ZWrite Off; the sphere
            // lies far inside the infinite reverse-Z frustum, so nothing clips it.
            enc.pushDebugGroup("Sky")
            s.setPipeline(main.sky)
            s.setDepthStencil(pipelines.depthNone)
            s.setCull(.none)
            for rec in ctx.sky {
                bindDraw(s, rec)
                bindTextures(s, rec.item.material, frame: ctx.frame)
                drawIndexed(s, rec.mesh)
            }
            enc.popDebugGroup()
        }
        if fx.showGrid {
            enc.pushDebugGroup("Grid")
            s.setPipeline(main.grid)
            s.setDepthStencil(pipelines.depthTest)
            s.setCull(.none)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.popDebugGroup()
        }

        enc.pushDebugGroup("Opaque")
        let outlinesOn = fx.outlineWidth > 0.001
        // An instanced run draws its members' outlines, then their surfaces;
        // one record at a time interleaves them. With the strict depth test and
        // opaque writes the nearest fragment wins either way; only a sample where
        // a member's outline and an earlier member's surface have exactly equal
        // depth keeps the other one (renderer.md, "Instanced static items").
        for run in ctx.opaqueRuns {
            let rec = ctx.opaque[run.lowerBound]
            let m = rec.item.material
            bindDraw(s, rec)
            bindTextures(s, m, frame: ctx.frame)
            if outlinesOn && rec.item.outline && (m.uniforms.flags & MaterialFlagNoOutline.rawValue) == 0 {
                s.setPipeline(main.outline)
                s.setDepthStencil(pipelines.depthWrite)
                s.setCull(.front)
                drawRun(s, run, of: ctx.opaque)
            }
            let nativeEye = m.uniforms.kind == UInt32(MaterialKindEye.rawValue) && (m.uniforms.flags & MaterialFlagSourceIrisHighlights.rawValue) == 0
            let isMap = m.uniforms.kind == UInt32(MaterialKindMap.rawValue)
            // Instanced runs take the per-draw pipelines: their vertex functions
            // read DrawUniforms by instance (B0), so a run renders like its records.
            s.setPipeline(isMap ? main.map : nativeEye ? main.eye : main.toonOpaque)
            s.setDepthStencil(pipelines.depthWrite)
            s.setCull((m.uniforms.flags & MaterialFlagDoubleSided.rawValue) != 0 ? .none : .back)
            drawRun(s, run, of: ctx.opaque)
        }
        enc.popDebugGroup()

        if !ctx.live.isEmpty, ctx.liveMainPass != nil {
            enc.pushDebugGroup("SourceShaderLive")
            encodeLiveDraws(enc, ctx, target: TranslatedSourceTarget(color: Pipelines.hdrFormat, depthStencil: Pipelines.depthStencilFormat, sampleCount: Pipelines.sampleCount))
            // Translated programs bind buffers 0 and 8…, textures 0… and their
            // own pipeline, depth, cull and winding state directly: forget what
            // the encoder held, and restore the native frame bindings for the
            // passes that follow.
            s.forget()
            bindCommon(s, ctx)
            enc.popDebugGroup()
        }

        if !ctx.transparent.isEmpty {
            enc.pushDebugGroup("Transparent")
            s.setDepthStencil(pipelines.depthTest)
            for run in ctx.transparentRuns {
                let rec = ctx.transparent[run.lowerBound]
                let material = rec.item.material.uniforms
                let nativeEye = material.kind == UInt32(MaterialKindEye.rawValue) && (material.flags & MaterialFlagSourceIrisHighlights.rawValue) == 0
                let isMap = material.kind == UInt32(MaterialKindMap.rawValue)
                bindDraw(s, rec)
                bindTextures(s, rec.item.material, frame: ctx.frame)
                s.setCull((rec.item.material.uniforms.flags & MaterialFlagDoubleSided.rawValue) != 0 ? .none : .back)
                if isMap, (material.flags & MaterialFlagMapSilhouette.rawValue) != 0 {
                    // Custom/Silhouette, per renderer as Unity draws it: pass 1 writes
                    // depth only (ColorMask 0, ZWrite On, ZTest LEqual), pass 2 blends
                    // the colour where pass 1 left the nearest depth (ZWrite Off,
                    // ZTest LEqual), so a renderer's overlapping faces blend once.
                    s.setPipeline(main.mapDepthOnly)
                    s.setDepthStencil(pipelines.depthWriteLEqual)
                    drawIndexed(s, rec.mesh)
                    s.setPipeline(main.mapBlend)
                    s.setDepthStencil(pipelines.depthTestLEqual)
                    drawIndexed(s, rec.mesh)
                    s.setDepthStencil(pipelines.depthTest)
                    continue
                }
                s.setPipeline(isMap ? main.mapBlend : nativeEye ? main.eyeBlend : main.toonBlend)
                drawRun(s, run, of: ctx.transparent)
            }
            enc.popDebugGroup()
        }

        let depthGizmos = ctx.gizmos.filter { $0.batch.depthTest }
        if !depthGizmos.isEmpty {
            enc.pushDebugGroup("GizmosDepth")
            s.setPipeline(main.gizmoHDR)
            s.setDepthStencil(pipelines.depthTest)
            s.setCull(.none)
            encodeGizmos(s, depthGizmos)
            enc.popDebugGroup()
        }
        enc.endEncoding()
    }

    private func encodeGizmos(_ s: EncoderState, _ records: [GizmoRecord]) {
        for g in records {
            s.setVertexBuffer(g.vertices.buffer, offset: g.vertices.offset, index: Int(BufferIndexGizmoVertices.rawValue))
            s.setVertexBuffer(g.draw.buffer, offset: g.draw.offset, index: Int(BufferIndexDrawUniforms.rawValue))
            s.setFragmentBuffer(g.draw.buffer, offset: g.draw.offset, index: Int(BufferIndexDrawUniforms.rawValue))
            s.encoder.drawPrimitives(type: g.batch.primitive == .lines ? .line : .triangle, vertexStart: 0, vertexCount: g.batch.vertices.count)
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
        let s = EncoderState(enc, skips: skipRedundantState)
        s.setPipeline(pipelines.gizmoLDR)
        s.setDepthStencil(pipelines.depthWrite)
        s.setCull(.none)
        s.setVertexBuffer(ctx.frameUniforms.buffer, offset: ctx.frameUniforms.offset, index: Int(BufferIndexFrameUniforms.rawValue))
        encodeGizmos(s, overlays)
        enc.endEncoding()
    }

    /// The pick pass. `scissor` limits it to the pixels the caller reads; the
    /// fragment shader reads only the body mask, so only that texture is bound.
    private func encodePick(_ ctx: FrameContext, targets: RenderTargets, scissor: MTLScissorRect?, _ cb: any MTLCommandBuffer) {
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
        let s = EncoderState(enc, skips: skipRedundantState)
        if let scissor { enc.setScissorRect(scissor) }
        s.setFrontFacing(.counterClockwise)
        s.setVertexBuffer(ctx.frameUniforms.buffer, offset: ctx.frameUniforms.offset, index: Int(BufferIndexFrameUniforms.rawValue))
        s.setPipeline(pipelines.pick)
        s.setDepthStencil(pipelines.depthWrite)
        s.setCull(.none)
        func pickable(_ rec: DrawRecord) -> Bool { rec.item.objectID != 0 || rec.item.pickOccluder }
        // Opaque, transparent, then live records, in order. An instanced run
        // draws its pickable stretches, so ids at equal depth resolve as they do
        // one record at a time: the first drawn keeps the sample.
        for (records, runs) in [(ctx.opaque, ctx.opaqueRuns), (ctx.transparent, ctx.transparentRuns)] {
            for run in runs {
                let first = records[run.lowerBound]
                if !first.instanced {
                    guard pickable(first) else { continue }
                    s.setPipeline(pipelines.pick)
                    bindDraw(s, first)
                    bindMaskTextures(s, first.item.material, frame: ctx.frame, base: false)
                    drawIndexed(s, first.mesh)
                    continue
                }
                // The run is bound once, at its first pickable record.
                var bound = false
                Self.forEachDraw(run, of: records) { draw in
                    for stretch in Self.stretches(draw, of: records, where: pickable) {
                        s.setPipeline(pipelines.pickInstanced)
                        if !bound {
                            let rec = records[stretch.lowerBound]
                            bindDraw(s, rec)
                            bindMaskTextures(s, rec.item.material, frame: ctx.frame, base: false)
                            bound = true
                        }
                        drawInstanced(s, stretch, of: records)
                    }
                }
            }
        }
        s.setPipeline(pipelines.pick)
        for rec in ctx.live.map(\.record) where pickable(rec) {
            bindDraw(s, rec)
            bindMaskTextures(s, rec.item.material, frame: ctx.frame, base: false)
            drawIndexed(s, rec.mesh)
        }
        // Pickable gizmos draw on top (depth cleared so handles always win).
        let pickable = ctx.gizmos.filter { $0.batch.objectID != 0 }
        if !pickable.isEmpty {
            s.setPipeline(pipelines.pickGizmo)
            s.setDepthStencil(pipelines.depthNone)
            encodeGizmos(s, pickable)
        }
        enc.endEncoding()
    }
}
