import Foundation
import simd
import CoreMath
import Scene

/// Clock bookkeeping for driving one route's `SourceStudioRouteStepper` from
/// a Studio preview clock, the route counterpart of the hair dynamics
/// "step on tick, clear on jump" pattern. The app clock stays the authority it
/// always was; this type only mirrors its additions, keeps the stepper, and
/// answers "which frame does `childRoot` hold at this instant", so the
/// bookkeeping is testable without an app run.
///
/// The contract:
/// - A live `step` advances the stepper by the same delta the clock advanced,
///   and `reached` mirrors the clock by consuming the identical `Float` delta
///   — a clock mirrored from the same start with the same additions matches
///   bit for bit, so the caller's tolerance only absorbs the rebuild's
///   rounding, never live drift.
/// - `frame` answers only when the last frame belongs to the queried instant
///   (`|time - reached| <= tolerance`); a frame frozen by a non-looping
///   route's `onComplete` keeps answering (`active == false`, end position and
///   last damped rotation), which is what the original leaves on `childRoot`.
///   A record-inactive route never builds a stepper, so `frame` never answers
///   and the caller keeps its `Stop` pin.
/// - `play(at:routeWorld:)` marks the instant the route's tween starts: the
///   stepper's tween time is `clockTime - playStart`, so a jump before
///   `playStart` — or a stopped or never-played clock — has no frame and the
///   caller's pin (or point-0 `Play` start) answers; `stop()` drops the
///   stepper, which is the model-level `Stop` on top of the builder's refusal
///   and the completion hold.
/// - A jump (`jump`, or a `frame(at:routeWorld:)` whose route world changed
///   since the build, including a never-built clock at a clock position
///   already past zero) rebuilds a fresh `Play` and fast-forwards in fixed
///   `1/30` frames
///   to the nearest frame to the new time, so the placement matches
///   what repeated `1/30` live steps produce. The rebuild sets `reached` to
///   the requested time exactly: the stepper itself stands at the nearest
///   frame, and the caller's next live tick — the only place its state moves
///   on — lands one frame further while the mirrored clock does the same, so
///   the two stay bit-identical.
/// - A rebuild that would need more than `maxRebuildSteps` frames (10
///   minutes) drops the stepper (`lastAction == .rebuiltWithFallback`) and
///   the caller keeps the continuous evaluator for this route until the next
///   rebuild re-arms it; a route whose builder refuses to play at all has no
///   frame ever, so `childRoot` keeps its `Stop` pin.
public final class SourceStudioRouteClock {
    /// One frame the stepper produced: the `Time.deltaTime` it consumed and
    /// the placement it wrote (source-space position and `LookUpdate` Euler,
    /// as documented on `SourceStudioRouteStepper.Sample`; `deltaTime` is 0
    /// for `Play`'s percentage-0 state right after a rebuild).
    public struct Frame: Sendable, Equatable {
        public let deltaTime: Double
        public let placement: SourceStudioRouteStepper.Sample
    }

    /// What the clock did for the last request, so the app can report the
    /// rebuild cap exactly once per rebuild that hit it.
    public enum Action: Equatable {
        /// A live tick stepped the stepper by the delta, or there was nothing
        /// to step (no playable stepper).
        case stepped
        /// A jump or route-world change rebuilt `Play` and fast-forwarded
        /// `steps` fixed frames.
        case rebuilt(steps: Int)
        /// A rebuild would have needed more than `maxRebuildSteps` frames: the
        /// stepper is dropped and the caller must use the continuous
        /// evaluator for this route.
        case rebuiltWithFallback(steps: Int)
        /// A jump before `playStart`: the route is not playing yet at the
        /// requested instant, so no frame exists and the caller's fallback
        /// answers; `builtWorld` is kept and a later jump at or past
        /// `playStart` re-arms the stepper.
        case notPlayingYet
        /// A `stop()` dropped the stepper.
        case stopped
    }

    /// The preview's fixed frame delta: live ticks should pass it and jump
    /// fast-forwards always use it, matching the Studio clock's `1 / 30`.
    public static let frameDelta: Float = 1 / 30
    /// The fast-forward budget for one rebuild: 10 minutes at `1/30`.
    public static let maxRebuildSteps = 18_000
    /// The default `placement` tolerance: one microsecond, which the
    /// bit-identical live mirror never approaches and which only a rebuild's
    /// rounding of an off-lattice time has to absorb.
    public static let defaultTolerance: Float = 1e-6

    /// Rebuilds a fresh `Play` stepper for the route at `routeWorld`
    /// (`SourceStudioRoutePlayback.stepper`'s product, which folds the route
    /// world placement into the points and aids), or `nil` when the route
    /// cannot play at all — the original's `Play` refusal, leaving
    /// `childRoot` on its pin.
    private let buildStepper: (float4x4) -> SourceStudioRouteStepper?
    private let maxRebuildSteps: Int
    private var stepper: SourceStudioRouteStepper?
    /// The route world the current stepper's points were composed from; a
    /// mismatch means the route object moved since, and its child objects
    /// moved the whole path with it.
    private var builtWorld: float4x4?
    /// The mirrored clock time (see the type comment).
    private var reached: Float = 0
    private var lastFrame: Frame?
    /// Whether the clock is currently answering from its stepper (`play`) or
    /// pinning (`stop`, or never played). A stopped clock has no frame even
    /// at its mirrored time, like the original's `Stop` pin.
    public private(set) var playing = false
    /// The clock instant the stepper's tween time 0 maps to: the route's
    /// tween time is `clockTime - playStart` (see the type comment).
    public private(set) var playStart: Float = 0

    /// `playing`/`playStart` mirror a play state created alongside the clock:
    /// a record-active route imported at play start 0 is armed from the
    /// first query, while a clock built for a stopped route answers nothing
    /// until `play` or `rewind`.
    public init(maxRebuildSteps: Int = SourceStudioRouteClock.maxRebuildSteps,
                playing: Bool = false, playStart: Float = 0,
                stepper buildStepper: @escaping (float4x4) -> SourceStudioRouteStepper?) {
        self.maxRebuildSteps = maxRebuildSteps
        self.playing = playing
        self.playStart = playStart
        self.buildStepper = buildStepper
    }

    /// The frame the stepper last wrote, if any (`deltaTime` 0 right after a
    /// rebuild: `Play`'s percentage-0 application).
    public var frame: Frame? { lastFrame }

    /// The clock time the stepper has reached.
    public var reachedTime: Float { reached }

    /// What the last `rewind`, `step`, `jump` or rebuilding `placement` did.
    public private(set) var lastAction: Action = .stepped

    /// The frame to render when the clock is at `time` with the route at
    /// `routeWorld`, or `nil` when the caller's continuous evaluator answers:
    /// the clock is stopped (never played or `stop`ed), no playable stepper,
    /// the frame belongs to another instant under `tolerance`, the route
    /// finished (see the type comment), or the last rebuild hit the
    /// fast-forward budget. A route world that is not the one
    /// the stepper was built from — an edit to the route object itself moves
    /// its child objects and the whole path — first rebuilds and
    /// fast-forwards, like a jump. A playing clock whose stepper was dropped
    /// (a jump before `playStart`, or the fast-forward budget) re-arms the
    /// same way once a query reaches `playStart`, like a live crossing of the
    /// press instant would.
    public func frame(at time: Float, routeWorld: float4x4,
                      tolerance: Float = SourceStudioRouteClock.defaultTolerance) -> Frame? {
        guard time.isFinite, time >= 0, playing else { return nil }
        if builtWorld != routeWorld {
            _ = jump(to: time, routeWorld: routeWorld)
        } else if lastFrame == nil, stepper == nil, time >= playStart {
            // The route became steppable again at this instant: the clock
            // lived past `playStart` across a jump that fell outside the
            // fast-forward budget, or crossed the press instant after a jump
            // to before it. Re-arm exactly as the live crossing of the press
            // would; a route whose builder still refuses just drops the frame
            // again each query (the refusal is a guard check, not a walk).
            _ = jump(to: time)
        }
        // Both are validated finite and non-negative, so the difference is exact-free.
        guard abs(time - reached) <= tolerance else { return nil }
        return lastFrame
    }

    /// The press-time `Play` at clock time 0 (the stepper's tween time starts
    /// here; see `play(at:routeWorld:)`). An unplayable route clears the
    /// stepper, like the original's `Play` refusal leaving `childRoot` on its
    /// pin.
    public func rewind(routeWorld: float4x4) {
        playing = true
        playStart = 0
        lastAction = rebuild(to: 0, routeWorld: routeWorld, playStart: 0, exactTime: false)
    }

    /// The press-time `Play` at `time` (the `RouteControl` button pressing
    /// `OCIRoute.Play`): the tween's time 0 maps to this clock instant, the
    /// stepper is a fresh `Play` (point 0's placement, `deltaTime` 0 frame),
    /// and `reached` mirrors `time` so the press frame answers. A later jump
    /// evaluates the tween at `time - playStart`, so the placement matches a
    /// fresh stepper stepped by the elapsed live frames. Replaying a playing
    /// route resets `playStart` and restarts the tween from point 0, like the
    /// original restarting its segment queue.
    @discardableResult
    public func play(at time: Float, routeWorld: float4x4) -> Action {
        guard time.isFinite, time >= 0 else { return lastAction }
        playing = true
        playStart = time
        lastAction = rebuild(to: time, routeWorld: routeWorld, playStart: time, exactTime: true)
        return lastAction
    }

    /// `Stop`: drop the stepper and its frame, so `frame` never answers again
    /// until a `play` or `rewind`; the caller pins `childRoot` through its
    /// fallback (`activeOverride == false`). `builtWorld` and the mirrored
    /// clock are kept, so `step` still mirrors and a later `play` rebuilds.
    @discardableResult
    public func stop() -> Action {
        playing = false
        stepper = nil
        lastFrame = nil
        lastAction = .stopped
        return lastAction
    }

    /// A live tick: advance the stepper by the same delta the clock advanced.
    /// The stepper's own validation already refuses non-finite or negative
    /// deltas without changing state; the mirror still consumes the delta,
    /// because a clock the caller advanced moves even when a route cannot. A
    /// non-looping route's `onComplete` freezes the frame at its end placement
    /// (`Sample.active == false`), which `frame` keeps reporting — the
    /// original's `childRoot` hold.
    @discardableResult
    public func step(delta: Float) -> Action {
        lastAction = .stepped
        if var running = stepper, delta.isFinite, delta >= 0 {
            // The stepper only throws on the invalid delta guarded above.
            let placement = (try? running.step(deltaTime: Double(delta))) ?? running.current()
            stepper = running
            lastFrame = Frame(deltaTime: Double(delta), placement: placement)
        }
        reached += delta
        return lastAction
    }

    /// A jump (`setSourceAnimationTime`, a checkpoint restore, a rewind):
    /// rebuild `Play` and fast-forward fixed `1/30` frames from `playStart`
    /// to the nearest frame to the new time, so the placement matches what
    /// live `1/30` stepping produces there. A jump to a time before
    /// `playStart` — while the route was not playing yet — drops the frame
    /// and stepper (`notPlayingYet`) and leaves the mirrored clock alone, so
    /// placement falls back to the caller until a jump at or past
    /// `playStart` re-arms it. Rebuilds against the last route world this
    /// clock was built at; the caller's next `frame(at:routeWorld:)` notices
    /// a route that moved in the meantime and rebuilds again.
    @discardableResult
    public func jump(to time: Float) -> Action {
        guard let routeWorld = builtWorld, time.isFinite, time >= 0 else { return lastAction }
        return jumpPrepared(to: time, routeWorld: routeWorld)
    }

    /// A jump whose route world is already known (a route-object edit moves
    /// its whole path, so the stepper must be re-pointed at the new world).
    @discardableResult
    public func jump(to time: Float, routeWorld: float4x4) -> Action {
        guard time.isFinite, time >= 0 else { return lastAction }
        return jumpPrepared(to: time, routeWorld: routeWorld)
    }

    private func jumpPrepared(to time: Float, routeWorld: float4x4) -> Action {
        guard playing, time >= playStart else {
            stepper = nil
            lastFrame = nil
            lastAction = .notPlayingYet
            return lastAction
        }
        lastAction = rebuild(to: time, routeWorld: routeWorld, playStart: playStart, exactTime: true)
        return lastAction
    }

    /// `Play` plus `steps` fixed frames (the tween frames elapsed between
    /// `playStart` and `time`, never negative — callers guard), with
    /// `reached` ending at `time` exactly when `exactTime` (a jump or press)
    /// or at 0 (a rewind). A dropped or unplayable stepper leaves no frame,
    /// so placement stays on the continuous evaluator; the caller's next live
    /// tick still mirrors the clock because `reached` keeps advancing.
    private func rebuild(to time: Float, routeWorld: float4x4,
                         playStart: Float, exactTime: Bool) -> Action {
        let steps = Int(((Double(time) - Double(playStart)) / Double(Self.frameDelta))
            .rounded(.toNearestOrAwayFromZero))
        guard steps <= maxRebuildSteps, let built = buildStepper(routeWorld) else {
            stepper = nil
            // `builtWorld` is kept so a later jump back inside the budget (or
            // a caller-side world mismatch) can re-arm the stepper; without a
            // built world a fallback route re-arms through the caller's
            // `frame(at:routeWorld:)` rebuild instead.
            lastFrame = nil
            reached = exactTime ? time : 0
            return steps > maxRebuildSteps ? .rebuiltWithFallback(steps: steps) : .stepped
        }
        stepper = built
        builtWorld = routeWorld
        reached = 0
        lastFrame = Frame(deltaTime: 0, placement: built.current())
        for _ in 0..<steps { step(delta: Self.frameDelta) }
        if exactTime { reached = time }
        return .rebuilt(steps: steps)
    }
}
