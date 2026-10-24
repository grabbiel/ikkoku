import Foundation
import os
import simd
import CoreMath
import Scene
import Renderer

/// The Studio live tick of the source characters, off the main thread and in
/// parallel (R7 phase 2, item 3).
///
/// `StudioModel.advanceLiveFrame` used to step every source character on the
/// main thread: the blink clocks, the TARGET/AWAY neck and eye gaze, the
/// dynamics clock and then, in the refresh, each character's wear, face state
/// and frame. Characters never read each other there: each step reads only
/// its own preview and the inputs the main actor captured at the tick's start.
/// So the main actor snapshots those inputs (`Input`), hands each preview to
/// exactly one worker for the tick (`SourceStudioLiveTickLease`), and the
/// workers run `step` in parallel (`SourceStudioLiveTickJob`). The join keeps
/// the lease order, and the main actor merges the frames in document order in
/// its refresh, so every output is the one the serial tick computed: per
/// preview, `step` makes the same calls in the same order with the same
/// arguments.
public enum SourceStudioLiveTick {
    /// The document edits a character is posed with: the arguments
    /// `SourceStudioCharacterPreview.editedPose` takes besides the clock.
    public struct Edits: Sendable, Equatable {
        public var fkRotations: [Int: Float3]
        public var faceValues: [Float]?
        public var bodyValues: [Float]?
        public var ikTargets: [Int32: SourceStudioIKEdit]
        public var kinematics: SourceStudioKinematicState?
        public var animationState: SourceStudioAnimationState?

        public init(fkRotations: [Int: Float3] = [:], faceValues: [Float]? = nil, bodyValues: [Float]? = nil,
                    ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil,
                    animationState: SourceStudioAnimationState? = nil) {
            self.fkRotations = fkRotations; self.faceValues = faceValues; self.bodyValues = bodyValues
            self.ikTargets = ikTargets; self.kinematics = kinematics; self.animationState = animationState
        }
    }

    /// One neck or eye gaze step: the view camera in the rig's model space and
    /// the edits the gaze reads the shown pose with.
    public struct Gaze: Sendable {
        public var cameraModelPosition: Float3
        public var edits: Edits

        public init(cameraModelPosition: Float3, edits: Edits) {
            self.cameraModelPosition = cameraModelPosition; self.edits = edits
        }
    }

    /// The frame the Studio refresh merges for one character, with the wear
    /// and face state it applies first. The frame's camera, main light and
    /// effects are not part of it: a source preview only copies them into its
    /// own frame's fields, which the merge drops (it keeps items, skin
    /// palettes and bounds).
    public struct FrameRequest: Sendable {
        public var world: float4x4
        public var objectID: UInt32
        public var edits: Edits
        public var clothesState: [UInt8]?
        public var showAccessory: [Bool]?
        /// The document's shoesType edit (ST-C03); nil keeps the saved one.
        public var shoesType: Int?
        public var expression: SourceStudioExpressionState?

        public init(world: float4x4, objectID: UInt32, edits: Edits, clothesState: [UInt8]?, showAccessory: [Bool]?,
                    shoesType: Int? = nil, expression: SourceStudioExpressionState?) {
            self.world = world; self.objectID = objectID; self.edits = edits
            self.clothesState = clothesState; self.showAccessory = showAccessory; self.shoesType = shoesType; self.expression = expression
        }

        /// Whether `other` asks the preview for the same frame: the world
        /// matrix bit for bit (the frame multiplies it in), and edits, wear and
        /// face state equal under the comparisons the preview itself makes
        /// before reusing its cached pose and state. A second `frame` call with
        /// a matching request returns the frame the first one did.
        public func matches(_ other: FrameRequest) -> Bool {
            objectID == other.objectID && (0..<4).allSatisfy { column in
                (0..<4).allSatisfy { world[column][$0].bitPattern == other.world[column][$0].bitPattern }
            } && edits == other.edits && clothesState == other.clothesState && showAccessory == other.showAccessory
                && shoesType == other.shoesType && expression == other.expression
        }
    }

    /// Everything one character's step reads, captured on the main actor at
    /// the tick's start. Nil gaze or frame: that part of the serial tick does
    /// not run for the character (no live look, hidden, not in the document).
    public struct Input: Sendable {
        /// The Studio animation clock after this tick's advance, and its step.
        public var elapsed: Float
        public var deltaTime: Float
        /// Whether the blink clock steps (the Studio's automatic blink).
        public var blink: Bool
        public var neck: Gaze?
        public var eye: Gaze?
        public var frame: FrameRequest?

        public init(elapsed: Float, deltaTime: Float, blink: Bool, neck: Gaze? = nil, eye: Gaze? = nil, frame: FrameRequest? = nil) {
            self.elapsed = elapsed; self.deltaTime = deltaTime; self.blink = blink
            self.neck = neck; self.eye = eye; self.frame = frame
        }
    }

    /// What one character's step produced. The errors are the ones the serial
    /// tick wrote to the status line; the main actor reports them in the
    /// serial order (gaze errors in its own preview order, wear, face and
    /// frame errors in document order during the merge).
    public struct Output: Sendable {
        public var neckError: (any Error)?
        public var eyeError: (any Error)?
        public var wearError: (any Error)?
        public var faceError: (any Error)?
        /// The character's frame, or the error its `frame` call threw; nil
        /// without a frame request.
        public var frame: Result<RenderFrame, any Error>?
        /// The blink draws after this step, so a caller can carry a
        /// deterministic generator into the next tick.
        public var random: any SourceStudioBlinkRandom
        /// The worker thread's CPU time for this step, in seconds.
        public var cpuSeconds: Double = 0

        init(random: any SourceStudioBlinkRandom) { self.random = random }
    }

    /// One character's live step, in the serial tick's order: the blink clock,
    /// the neck gaze, the eye gaze, the dynamics clock, then the refresh's wear,
    /// face state and frame. Blink and dynamics clock errors are dropped, as
    /// the serial tick dropped them (`try?`).
    public static func step(_ preview: SourceStudioCharacterPreview, _ input: Input,
                            random: inout some SourceStudioBlinkRandom) -> Output {
        var output = Output(random: random)
        if input.blink {
            _ = try? preview.updateBlink(elapsed: input.elapsed,
                randomInteger: { random.integer($0, $1) }, randomFloat: { random.float($0, $1) })
        }
        if let gaze = input.neck {
            do {
                _ = try preview.updateNeckLook(deltaTime: input.deltaTime, cameraModelPosition: gaze.cameraModelPosition,
                    fkRotations: gaze.edits.fkRotations, faceValues: gaze.edits.faceValues, bodyValues: gaze.edits.bodyValues,
                    ikTargets: gaze.edits.ikTargets, kinematics: gaze.edits.kinematics, animationState: gaze.edits.animationState,
                    animationElapsed: input.elapsed)
            } catch { output.neckError = error }
        }
        if let gaze = input.eye {
            do {
                _ = try preview.updateEyeLook(deltaTime: input.deltaTime, cameraModelPosition: gaze.cameraModelPosition,
                    fkRotations: gaze.edits.fkRotations, faceValues: gaze.edits.faceValues, bodyValues: gaze.edits.bodyValues,
                    ikTargets: gaze.edits.ikTargets, kinematics: gaze.edits.kinematics, animationState: gaze.edits.animationState,
                    animationElapsed: input.elapsed)
            } catch { output.eyeError = error }
        }
        try? preview.setDynamicsStep(elapsed: input.elapsed, deltaTime: input.deltaTime)
        if let request = input.frame {
            do { try preview.setWear(clothesState: request.clothesState, showAccessory: request.showAccessory, shoesType: request.shoesType) }
            catch { output.wearError = error }
            do { try preview.setExpressionState(request.expression) }
            catch { output.faceError = error }
            let edits = request.edits
            output.frame = Result {
                try preview.frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(),
                    world: request.world, objectID: request.objectID, fkRotations: edits.fkRotations,
                    faceValues: edits.faceValues, bodyValues: edits.bodyValues, ikTargets: edits.ikTargets,
                    kinematics: edits.kinematics, animationState: edits.animationState, animationElapsed: input.elapsed)
            }
        }
        output.random = random
        return output
    }
}

/// The blink clock's random draws (`SourceStudioCharacterPreview.updateBlink`):
/// a value type, so a lease carries it to its worker and back.
public protocol SourceStudioBlinkRandom: Sendable {
    /// A draw in `lower..<upper`, or `lower` when they are equal.
    mutating func integer(_ lower: Int, _ upper: Int) -> Int
    /// A draw in `lower...upper`.
    mutating func float(_ lower: Float, _ upper: Float) -> Float
}

/// The draws `updateBlink` makes by default, from the system generator.
public struct SourceStudioSystemBlinkRandom: SourceStudioBlinkRandom {
    public init() {}
    public func integer(_ lower: Int, _ upper: Int) -> Int { lower == upper ? lower : Int.random(in: lower..<upper) }
    public func float(_ lower: Float, _ upper: Float) -> Float { Float.random(in: lower...upper) }
}

/// One character handed to a live-tick worker: its preview, its inputs and its
/// blink draws.
///
/// Why `@unchecked Sendable` is sound: a `SourceStudioCharacterPreview` is a
/// mutable class with caches, clocks and dynamics state and is not
/// `Sendable`. A lease moves it to one worker for one tick, under these rules:
/// - The creator owns the preview before the lease and gives it up for the
///   job's lifetime: from `SourceStudioLiveTickJob.start` until its `wait()`
///   returns, it neither calls the preview nor reads its mutable state.
///   `StudioModel` enforces this by settling the job (waiting for it) before
///   any access to its previews.
/// - The job runs each lease on exactly one worker, and rejects two leases of
///   one preview, so every preview has exactly one owner per tick.
/// - The dispatch that starts the workers happens before a worker's first
///   access, and a worker's last access happens before the job's `wait()` or
///   completion returns (the dispatch group's enter/leave), so the creator
///   sees every write the worker made.
public struct SourceStudioLiveTickLease: @unchecked Sendable {
    fileprivate let preview: SourceStudioCharacterPreview
    public let input: SourceStudioLiveTick.Input
    fileprivate var random: any SourceStudioBlinkRandom

    public init(preview: SourceStudioCharacterPreview, input: SourceStudioLiveTick.Input,
                random: any SourceStudioBlinkRandom = SourceStudioSystemBlinkRandom()) {
        self.preview = preview; self.input = input; self.random = random
    }
}

/// One live tick's workers: every lease's `SourceStudioLiveTick.step` in
/// parallel on a background queue, joined in lease order.
public final class SourceStudioLiveTickJob: Sendable {
    /// What `wait()` returns: the outputs in lease order, the job's wall
    /// time from `start` to its last worker, and the summed worker CPU time.
    public struct Result: Sendable {
        public let outputs: [SourceStudioLiveTick.Output]
        public let startSeconds: Double
        public let endSeconds: Double
        public var wallSeconds: Double { endSeconds - startSeconds }
        public var cpuSeconds: Double { outputs.reduce(0) { $0 + $1.cpuSeconds } }
    }

    private struct State: Sendable {
        var leases: [SourceStudioLiveTickLease]
        var outputs: [SourceStudioLiveTick.Output?]
        var start: UInt64 = 0
        var end: UInt64 = 0
    }

    private let count: Int
    private let group = DispatchGroup()
    private let state: OSAllocatedUnfairLock<State>

    /// Nil when two leases hand over the same preview.
    public init?(leases: [SourceStudioLiveTickLease]) {
        guard Set(leases.map { ObjectIdentifier($0.preview) }).count == leases.count else { return nil }
        count = leases.count
        state = OSAllocatedUnfairLock(initialState: State(leases: leases, outputs: Array(repeating: nil, count: leases.count)))
    }

    /// Starts the workers once; `completion` runs on `queue` after the last
    /// one finished.
    public func start(qos: DispatchQoS.QoSClass = .userInteractive, queue: DispatchQueue = .main,
                      completion: (@Sendable () -> Void)? = nil) {
        group.enter()
        let begin = DispatchTime.now().uptimeNanoseconds
        state.withLock { $0.start = begin }
        DispatchQueue.global(qos: qos).async { [self] in
            DispatchQueue.concurrentPerform(iterations: count) { index in
                var lease = state.withLock { $0.leases[index] }
                let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                var output = SourceStudioLiveTick.step(lease.preview, lease.input, random: &lease.random)
                output.cpuSeconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpu) / 1e9
                let finished = output
                state.withLock { $0.outputs[index] = finished }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            state.withLock { $0.end = end }
            group.leave()
        }
        if let completion { group.notify(queue: queue, execute: completion) }
    }

    /// Whether every worker finished, without waiting.
    public var isFinished: Bool { group.wait(timeout: .now()) == .success }

    /// Waits for every worker, then returns the outputs in lease order and
    /// drops the job's references to the previews, so the caller holds the
    /// only ones again.
    public func wait() -> Result {
        group.wait()
        return state.withLock { state in
            state.leases = []
            return Result(outputs: state.outputs.map { $0! }, startSeconds: Double(state.start) / 1e9,
                          endSeconds: Double(state.end) / 1e9)
        }
    }
}
