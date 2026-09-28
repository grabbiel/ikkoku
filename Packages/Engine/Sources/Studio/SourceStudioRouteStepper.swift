import Foundation
import simd
import CoreMath
import Scene

/// Per-frame `childRoot` stepping of a playing route: the stateful counterpart
/// of the continuous `SourceStudioRoute.evaluate(at:)`, mirroring
/// `Tools/reverse/analysis/studio_route_reference.simulate_frames` frame for
/// frame. The recovered `OCIRoute.Play` starts segment 0 and queues the rest
/// behind a single `StudioTween`; each frame the tween applies the *current*
/// percentage to `childRoot` *before* advancing `runningTime` by
/// `Time.deltaTime` (so the written position lags the clock by one frame), and
/// when the percentage has passed 1 the next queued segment starts in the
/// same frame at percentage 0 — the overshoot past the boundary is dropped,
/// never carried into the next segment's time. A looping queue restarts at
/// segment 0 the same way; a non-looping route fires `onComplete`, after which
/// the tween stops and `childRoot` keeps its end position and last aim
/// rotation (never point 0's). The rotation `childRoot` actually holds is the
/// stateful `LookUpdate` `SmoothDampAngle` state, not the instantaneous aim:
/// each frame's `LateUpdate` damps the previous frame's Euler (fresh zero
/// velocity, `Defaults.updateTime` smoothTime — route tweens pass `speed`,
/// never `looktime`/`time`) one step toward the looktarget the *previous*
/// write established, advancing with that previous write's `deltaTime`
/// (`Play`'s own frame delta seeds the first damp), and the frame after
/// `onComplete` freezes it.
///
/// Nothing here is wired into the app; the clock source and integration are
/// deliberately outside this type.
public struct SourceStudioRouteStepper: Sendable, Equatable {
    /// What `childRoot` holds after one frame's tween update and `LateUpdate`:
    /// the applied position, the last valid instantaneous aim (`nil` while the
    /// route is non-oriented or never aimed), the `LookUpdate`-smoothed Z-X-Y
    /// Euler in Unity degrees — one damp behind the `aim` column, because the
    /// frame's `LateUpdate` aims at the target the previous write established
    /// — and whether the route is still playing.
    public struct Sample: Sendable, Equatable {
        public let position: SIMD3<Double>
        public let aim: SourceStudioRoute.Aim?
        public let rotation: SIMD3<Double>
        public let active: Bool
    }

    /// `Defaults.updateTime` — the `LookUpdate` smoothTime a route tween
    /// resolves, because it carries neither `looktime` nor `time`. The ST-T11h
    /// capture rejects the `segmentDuration * 0.0075` alternative (85.1 degrees
    /// of residual against 0.051 at the float32 serialisation floor).
    public static let lookUpdateTime = 0.05

    private let segments: [SourceStudioRoute.Segment]
    private let loop: Bool
    private let orientation: SourceStudioRoute.Orientation
    private var segmentIndex = 0
    private var runningTime = 0.0
    private var percentage = 0.0
    private var finished = false
    private var position: SIMD3<Double>
    private var aim: SourceStudioRoute.Aim?
    /// The `LookUpdate` Euler state (Unity degrees, canonicalised through the
    /// quaternion store as `transform.eulerAngles` read-back does), seeded
    /// from `Play`'s `childRoot` rotation.
    private var rotation: SIMD3<Double>
    /// The `deltaTime` the previous write consumed; `LookUpdate` advances its
    /// damp with it (the trace's `deltaTime` field is one frame old for its
    /// row), seeded with the `Play` frame's own delta.
    private var previousDelta: Double?

    /// `Play`: build the segment queue and apply segment 0 at percentage 0,
    /// exactly as `OCIRoute.Play`/`TweenStart` does before any frame runs.
    /// An unplayable route (fewer than two points, nonfinite or nonpositive
    /// speed, curve without aid, no segments) throws instead of guessing.
    /// `initialRotation` is the rotation `Play` leaves on `childRoot` (route
    /// point 0's world rotation) and `initialDelta` the `Play` frame's own
    /// `Time.deltaTime`, which that frame's `LateUpdate` spends on the first
    /// damp; an oriented route given one without the other throws rather
    /// than guessing the seed.
    public init(points: [SourceStudioRoute.Point], loop: Bool = true,
                orientation: SourceStudioRoute.Orientation = .none,
                initialRotation: simd_quatf? = nil, initialDelta: Double? = nil) throws {
        if let initialDelta, !initialDelta.isFinite || initialDelta < 0 {
            throw RigError.invalid("initialDelta \(initialDelta) must be finite and non-negative.")
        }
        if let vector = initialRotation?.vector,
           !(vector.x.isFinite && vector.y.isFinite && vector.z.isFinite && vector.w.isFinite) {
            throw RigError.invalid("initialRotation \(vector) must be finite.")
        }
        if orientation != .none, initialRotation != nil, initialDelta == nil {
            throw RigError.invalid("initialDelta (the Play frame's deltaTime) must accompany initialRotation.")
        }
        let route = SourceStudioRoute(points: points, loop: loop, orientation: orientation)
        self.segments = try route.segments()
        self.loop = loop
        self.orientation = orientation
        self.position = segments[0].path[0]
        self.aim = nil
        self.rotation = initialRotation.map(Self.toEuler) ?? .zero
        self.previousDelta = initialDelta
        apply(0, 0.0)
    }

    /// Boundary from the decoded scene record; validation mirrors
    /// `SourceStudioRoute.init(record:)`.
    public init(record: KoikatsuRouteRecord) throws {
        let route = try SourceStudioRoute(record: record)
        try self.init(points: route.points, loop: route.loop, orientation: route.orientation)
    }

    /// The placement `childRoot` holds right now (`Play`'s application before
    /// the first `step`, the last write after it).
    public func current() -> Sample {
        Sample(position: position, aim: aim, rotation: rotation, active: !finished)
    }

    /// Advance one frame by `deltaTime` seconds and return the placement the
    /// tween wrote this frame and the `LateUpdate` rotation it smoothed —
    /// the state a capture recording after the tween's Update would observe.
    /// A non-finite or negative `deltaTime` is reported and changes nothing.
    public mutating func step(deltaTime: Double) throws -> Sample {
        guard deltaTime.isFinite, deltaTime >= 0 else {
            throw RigError.invalid("deltaTime \(deltaTime) must be finite and non-negative.")
        }
        let running = !finished
        // The looktarget the previous write established (`Play`'s on the
        // first frame); this frame's LateUpdate damps toward it, one aim
        // behind the position column.
        let previousAimEuler = aim?.rotation.map(Self.toEuler)
        if !finished {
            if percentage < 1 {
                // TweenUpdate: apply the current percentage, then advance.
                apply(segmentIndex, percentage)
                runningTime += deltaTime
                percentage = runningTime / segments[segmentIndex].duration
            } else {
                // TweenComplete: write the end point, then the queued segment
                // (or the loop restart) begins at percentage 0 this same
                // frame, discarding the overshoot time.
                apply(segmentIndex, 1.0)
                if segmentIndex + 1 < segments.count {
                    segmentIndex += 1
                    apply(segmentIndex, 0.0)
                    runningTime = 0
                    percentage = 0
                } else if loop {
                    segmentIndex = 0
                    apply(0, 0.0)
                    runningTime = 0
                    percentage = 0
                } else {
                    // onComplete: the route deactivates; childRoot keeps the
                    // end position and last aim rotation.
                    finished = true
                }
            }
        }
        // LookUpdate runs in LateUpdate while the tween was running this
        // frame — the completion frame smooths for the last time, and every
        // later frame freezes — with the deltaTime that previous write
        // consumed.
        if running, orientation != .none, let aimEuler = previousAimEuler,
           let dampDelta = previousDelta {
            rotation = Self.lookUpdate(euler: rotation, aim: aimEuler,
                                       smoothTime: Self.lookUpdateTime,
                                       deltaTime: dampDelta, axis: orientation)
        }
        previousDelta = deltaTime
        return current()
    }

    /// One `TweenUpdate`/`TweenStart` application: `position =
    /// path.Interp(clamp01(ease(percentage)))` and, when oriented, the aim at
    /// `min(1, percentage + lookAhead)`. A degenerate aim direction leaves the
    /// previous rotation in place, as in the original.
    private mutating func apply(_ segment: Int, _ percentage: Double) {
        let segmentValue = segments[segment]
        let eased = SourceStudioRoute.ease(segmentValue.easeType, 0, 1, percentage)
        position = SourceStudioRoute.interp(segmentValue.controlPoints, min(max(eased, 0), 1))
        guard orientation != .none else { return }
        let ahead = min(1, percentage + SourceStudioRoute.lookAhead)
        let aheadEased = SourceStudioRoute.ease(segmentValue.easeType, 0, 1, ahead)
        let lookTarget = SourceStudioRoute.interp(segmentValue.controlPoints, min(max(aheadEased, 0), 1))
        if let rotation = SourceStudioRoute.lookRotation(from: position, target: lookTarget, axis: orientation) {
            aim = .init(axis: orientation, lookTarget: lookTarget, rotation: rotation)
        }
    }

    // MARK: - LookUpdate (StudioTween LateUpdate pass, double precision)

    /// One `LookUpdate`: per-axis `SmoothDampAngle` (fresh zero velocity every
    /// call) from the current Euler toward the instantaneous aim; the axis-"y"
    /// orientation keeps the root's own x/z. The result is written back as
    /// `transform.eulerAngles` — Unity stores a quaternion, so the Z-X-Y
    /// read-back canonicalises into `toEuler`'s ranges and that read-back, not
    /// the raw damped angles, is what the next frame damps from.
    private static func lookUpdate(euler: SIMD3<Double>, aim: SIMD3<Double>,
                                   smoothTime: Double, deltaTime: Double,
                                   axis: SourceStudioRoute.Orientation) -> SIMD3<Double> {
        var smoothed = SIMD3<Double>(smoothDampAngle(current: euler.x, target: aim.x, smoothTime, deltaTime),
                                     smoothDampAngle(current: euler.y, target: aim.y, smoothTime, deltaTime),
                                     smoothDampAngle(current: euler.z, target: aim.z, smoothTime, deltaTime))
        if axis == .y {
            smoothed = SIMD3(euler.x, smoothed.y, euler.z)
        }
        return toEuler(fromEuler(smoothed))
    }

    /// `Mathf.SmoothDampAngle` with a fresh zero velocity (the velocity a
    /// `LookUpdate` call allocates is never carried across frames). A
    /// smoothTime of 0 or less teleports to the wrapped target, and output
    /// that jumps past the target lands on it exactly.
    private static func smoothDampAngle(current: Double, target: Double,
                                        _ smoothTime: Double, _ deltaTime: Double) -> Double {
        guard smoothTime > 0 else { return target }
        let clampedTarget = current + deltaAngle(current, target)
        let omega = 2 / smoothTime
        let x = omega * deltaTime
        let exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        let change = current - clampedTarget
        let temp = omega * change * deltaTime // velocity term only: it starts at zero
        var output = clampedTarget + (change + temp) * exp
        if (clampedTarget - current > 0) == (output > clampedTarget) {
            output = clampedTarget
        }
        return output
    }

    /// `Mathf.DeltaAngle`: the shortest signed turn in degrees, (-180, 180].
    private static func deltaAngle(_ current: Double, _ target: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        if delta > 180 { delta -= 360 }
        return delta
    }

    /// `Quaternion.eulerAngles` of a source-space rotation in degrees: pitch
    /// via `asin` ([-90, 90]), yaw and roll via `atan2` ((-180, 180]) — the
    /// Z-X-Y application form, matching the reference port exactly so both
    /// sides canonicalise each frame identically.
    private static func toEuler(_ quaternion: simd_quatf) -> SIMD3<Double> {
        // `SIMD4(_:_:_:_:)` fills x, y, z, w in order; the core wants (w, x, y, z).
        let q = quaternion.vector
        return toEuler(SIMD4<Double>(Double(q.x), Double(q.y), Double(q.z), Double(q.w)))
    }

    /// The same decode of a `simd_quatd`, which stores the scalar in `real`.
    private static func toEuler(_ quaternion: simd_quatd) -> SIMD3<Double> {
        let q = quaternion.vector
        return toEuler(SIMD4(q.x, q.y, q.z, q.w))
    }

    /// `Quaternion.eulerAngles` core over a `(w, x, y, z)` Hamilton product.
    static func toEuler(_ quaternion: SIMD4<Double>) -> SIMD3<Double> {
        let (w, x, y, z) = (quaternion.w, quaternion.x, quaternion.y, quaternion.z)
        let pitch = max(-1, min(1, 2 * (w * x - y * z)))
        let toDegrees = 180 / Double.pi
        return SIMD3(asin(pitch) * toDegrees,
                     atan2(2 * (x * z + w * y), 1 - 2 * (x * x + y * y)) * toDegrees,
                     atan2(2 * (x * y + w * z), 1 - 2 * (x * x + z * z)) * toDegrees)
    }

    /// `Quaternion.Euler`: Z first, then X, then Y — `Ry * Rx * Rz` as a
    /// Hamilton product, inverse of `toEuler`'s decode.
    private static func fromEuler(_ euler: SIMD3<Double>) -> simd_quatd {
        let toRadians = Double.pi / 180
        let x = simd_quatd(angle: euler.x * toRadians, axis: SIMD3(1, 0, 0))
        let y = simd_quatd(angle: euler.y * toRadians, axis: SIMD3(0, 1, 0))
        let z = simd_quatd(angle: euler.z * toRadians, axis: SIMD3(0, 0, 1))
        return y * x * z
    }
}
