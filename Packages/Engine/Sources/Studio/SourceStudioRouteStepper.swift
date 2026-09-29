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
/// rotation (never point 0's). The stateful `LookUpdate` `SmoothDampAngle`
/// smoothing is still not simulated: the aim is instantaneous.
///
/// Nothing here is wired into the app; the clock source and integration are
/// deliberately outside this type.
public struct SourceStudioRouteStepper: Sendable, Equatable {
    /// What `childRoot` holds after one frame's tween update: the applied
    /// position, the last valid instantaneous aim (`nil` while the route is
    /// non-oriented or never aimed), and whether the route is still playing.
    public struct Sample: Sendable, Equatable {
        public let position: SIMD3<Double>
        public let aim: SourceStudioRoute.Aim?
        public let active: Bool
    }

    private let segments: [SourceStudioRoute.Segment]
    private let loop: Bool
    private let orientation: SourceStudioRoute.Orientation
    private var segmentIndex = 0
    private var runningTime = 0.0
    private var percentage = 0.0
    private var finished = false
    private var position: SIMD3<Double>
    private var aim: SourceStudioRoute.Aim?

    /// `Play`: build the segment queue and apply segment 0 at percentage 0,
    /// exactly as `OCIRoute.Play`/`TweenStart` does before any frame runs.
    /// An unplayable route (fewer than two points, nonfinite or nonpositive
    /// speed, curve without aid, no segments) throws instead of guessing.
    public init(points: [SourceStudioRoute.Point], loop: Bool = true,
                orientation: SourceStudioRoute.Orientation = .none) throws {
        let route = SourceStudioRoute(points: points, loop: loop, orientation: orientation)
        self.segments = try route.segments()
        self.loop = loop
        self.orientation = orientation
        self.position = segments[0].path[0]
        self.aim = nil
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
        Sample(position: position, aim: aim, active: !finished)
    }

    /// Advance one frame by `deltaTime` seconds and return the placement the
    /// tween wrote this frame — the state a capture recording after the
    /// tween's Update would observe. A non-finite or negative `deltaTime` is
    /// reported and changes nothing.
    public mutating func step(deltaTime: Double) throws -> Sample {
        guard deltaTime.isFinite, deltaTime >= 0 else {
            throw RigError.invalid("deltaTime \(deltaTime) must be finite and non-negative.")
        }
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
}
