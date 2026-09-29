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

    public init(maxRebuildSteps: Int = SourceStudioRouteClock.maxRebuildSteps,
                stepper buildStepper: @escaping (float4x4) -> SourceStudioRouteStepper?) {
        self.maxRebuildSteps = maxRebuildSteps
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
    /// no playable stepper, the frame belongs to another instant under
    /// `tolerance`, the route finished (see the type comment), or the last
    /// rebuild hit the fast-forward budget. A route world that is not the one
    /// the stepper was built from — an edit to the route object itself moves
    /// its child objects and the whole path — first rebuilds and
    /// fast-forwards, like a jump.
    public func frame(at time: Float, routeWorld: float4x4,
                      tolerance: Float = SourceStudioRouteClock.defaultTolerance) -> Frame? {
        guard time.isFinite, time >= 0 else { return nil }
        if builtWorld != routeWorld { _ = jump(to: time, routeWorld: routeWorld) }
        // Both are validated finite and non-negative, so the difference is exact-free.
        guard abs(time - reached) <= tolerance else { return nil }
        return lastFrame
    }

    /// A fresh `Play` at clock time 0: what an import installs. An unplayable
    /// route clears the state, like the original's `Play` refusal leaving
    /// `childRoot` on its pin.
    public func rewind(routeWorld: float4x4) {
        lastAction = rebuild(to: 0, routeWorld: routeWorld, exactTime: false)
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
    /// rebuild `Play` and fast-forward fixed `1/30` frames to the nearest
    /// frame to the new time, so the placement matches what live
    /// `1/30` stepping produces there. Rebuilds against the last route world
    /// this clock was built at; the caller's next `frame(at:routeWorld:)`
    /// notices a route that moved in the meantime and rebuilds again.
    @discardableResult
    public func jump(to time: Float) -> Action {
        guard let routeWorld = builtWorld, time.isFinite, time >= 0 else { return lastAction }
        lastAction = rebuild(to: time, routeWorld: routeWorld, exactTime: true)
        return lastAction
    }

    /// A jump whose route world is already known (a route-object edit moves
    /// its whole path, so the stepper must be re-pointed at the new world).
    @discardableResult
    public func jump(to time: Float, routeWorld: float4x4) -> Action {
        guard time.isFinite, time >= 0 else { return lastAction }
        lastAction = rebuild(to: time, routeWorld: routeWorld, exactTime: true)
        return lastAction
    }

    /// `Play` plus `steps` fixed frames, with `reached` ending at `time`
    /// exactly when `exactTime` (a jump) or at 0 (a rewind). A dropped or
    /// unplayable stepper leaves no frame, so placement stays on the
    /// continuous evaluator; the caller's next live tick still mirrors the
    /// clock because `reached` keeps advancing.
    private func rebuild(to time: Float, routeWorld: float4x4, exactTime: Bool) -> Action {
        let steps = Int((Double(time) / Double(Self.frameDelta)).rounded(.toNearestOrAwayFromZero))
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
