import Foundation
import simd
import CoreMath
import Scene

/// Runtime placement of a route's `childRoot` transform, the node route child
/// objects are parented under (`AddObjectRoute.cs` parents them there;
/// `OCIRoute.cs` `Play`/`Stop` move it). The path spline, easing and aim come
/// from `SourceStudioRoute`; this layer only applies the recovered world
/// placement rules:
///
/// - An inactive route pins `childRoot` to point 0's world position and
///   rotation every frame (`Stop`).
/// - An active route starts at point 0's world position and rotation and
///   translates along the segments; its rotation changes only while the
///   orientation is XY or Y (orient-to-path), otherwise it keeps the rotation
///   point 0 had at `Play` time. A non-looping route that finishes stays at
///   its end position holding its last aim rotation, and reports inactive
///   (`isFinished`; `samples` folds that into `active`).
/// The recovered assignments write position and rotation only; the inherited
/// route scale is kept.
///
/// Route points are child objects of the route, so their world transform is
/// the route object's world matrix times their local transform; the caller
/// supplies those locals. `routeWorld` and the returned matrix are engine
/// (right-handed) world matrices; the `SourceStudioRoute` evaluator still runs
/// in the source (Unity) numeric convention and its position and aim are
/// converted here, exactly as imported characters convert saved FK Euler.
/// The continuous evaluator reports the instantaneous aim; the stateful
/// `LookUpdate` `SmoothDampAngle` smoothing — what `childRoot`'s rotation
/// actually holds frame by frame — is carried by `SourceStudioRouteStepper`
/// and reported through `steppedRoutes`.
public enum SourceStudioRoutePlayback {
    /// Engine-space local matrices for a route record's point bones, in point
    /// order. These are the authored values; callers that edit point objects
    /// pass their edited locals instead.
    public static func pointLocals(from route: KoikatsuRouteRecord) -> [float4x4] {
        route.points.map { local in
            Transform.trs(UnityCoordinates.position(local.bone.transform.position),
                          UnityCoordinates.eulerDegrees(local.bone.transform.rotationDegrees),
                          local.bone.transform.scale)
        }
    }

    /// `childRoot` world matrix for `route` at `elapsed` seconds.
    ///
    /// `pointLocals` must align with `route.points`; a mismatch is reported
    /// and the authored locals from the record are used instead. A negative
    /// or non-finite `elapsed` is reported and treated as 0. A route that
    /// cannot build playable segments (fewer than two points, coincident or
    /// nonfinite positions, curve without aid, unknown enum ordinal) is
    /// reported and leaves `childRoot` pinned to point 0, like the `Stop`
    /// pin. The recovered assignments write position and rotation only; the
    /// inherited route scale is kept for every placement.
    public static func childRootWorld(route: KoikatsuRouteRecord, routeWorld: float4x4,
                                      pointLocals: [float4x4], elapsed: Double)
        -> (matrix: float4x4, diagnostics: [String]) {
        var diagnostics: [String] = []
        var locals = pointLocals
        if locals.count != route.points.count {
            diagnostics.append("Route playback received \(locals.count) point locals for \(route.points.count) route points; authored record transforms are used.")
            locals = Self.pointLocals(from: route)
        }
        // Point 0's world placement: `Stop` pins to it and `Play` starts from it.
        let point0World = routeWorld * (locals.first ?? matrix_identity_float4x4)
        let routeScale = routeWorld.scaleFactors
        let pinned = Transform.trs(point0World.translation, point0World.rotationQuaternion, routeScale)
        guard route.active else { return (pinned, diagnostics) }
        guard !route.points.isEmpty else {
            diagnostics.append("Route has no points; childRoot remains at the route transform.")
            return (routeWorld, diagnostics)
        }
        var time = elapsed
        if !time.isFinite || time < 0 {
            diagnostics.append("Route elapsed time \(elapsed) is not finite and non-negative; treated as 0.")
            time = 0
        }

        let evaluator: SourceStudioRoute
        do {
            evaluator = try Self.makeEvaluator(route: route, routeWorld: routeWorld, locals: locals)
        } catch {
            diagnostics.append("Route playback unavailable: \(error) childRoot remains pinned to point 0.")
            return (pinned, diagnostics)
        }
        let evaluation: SourceStudioRoute.Evaluation
        do {
            evaluation = try evaluator.evaluate(at: time)
        } catch {
            diagnostics.append("Route playback unavailable: \(error) childRoot remains pinned to point 0.")
            return (pinned, diagnostics)
        }

        var rotation = point0World.rotationQuaternion
        var aim = evaluation.aim
        if evaluation.finished, let finishedAim = aim {
            // `onComplete` deactivates the route and `childRoot` keeps its last
            // aim. The lookahead clamps onto the finished position at
            // percentage 1, so the held rotation is the last non-degenerate
            // one: the aim with the percentage clamped to `1 - lookAhead` on
            // the final segment, like the per-frame stepper's hold frames.
            aim = Self.heldAim(evaluator: evaluator, aim: finishedAim)
        }
        if let aim {
            if let rotation3D = aim.rotation {
                rotation = UnityCoordinates.rotation(rotation3D)
            } else {
                // The instantaneous aim direction is degenerate here; the
                // original would keep its last smoothed rotation.
                diagnostics.append("Route aim at point \(evaluation.segmentIndex) is degenerate; point 0 rotation is kept.")
            }
        }
        let position = UnityCoordinates.position(Float3(Float(evaluation.position.x),
                                                         Float(evaluation.position.y),
                                                         Float(evaluation.position.z)))
        return (Transform.trs(position, rotation, routeScale), diagnostics)
    }

    /// Whether the original's `onComplete` has already fired for `route` at
    /// `elapsed`: a record-active, non-looping route whose whole segment queue
    /// has run goes inactive when it finishes (`OCIRoute`'s `onComplete`
    /// handler sets `routeInfo.active = false` while `childRoot` keeps its end
    /// placement). Routes the record pins inactive, looping routes and routes
    /// that cannot build a segment queue never report a finish beyond what
    /// the record itself says.
    public static func isFinished(route: KoikatsuRouteRecord, routeWorld: float4x4,
                                  pointLocals: [float4x4], elapsed: Double) -> Bool {
        guard route.active, !route.loop else { return false }
        var locals = pointLocals
        if locals.count != route.points.count { locals = Self.pointLocals(from: route) }
        var time = elapsed
        if !time.isFinite || time < 0 { time = 0 }
        guard let evaluator = try? Self.makeEvaluator(route: route, routeWorld: routeWorld, locals: locals)
        else { return false }
        return (try? evaluator.evaluate(at: time).finished) ?? false
    }

    /// Per-frame stepping (`Play` plus one tween update per `deltaTime`) of
    /// `route`'s `childRoot`, in the same source world space as
    /// `childRootWorld`: route points and aids compose through `routeWorld`
    /// and their locals. A mismatched local count falls back to the record's
    /// authored transforms like `childRootWorld`; a route that cannot play
    /// yields `nil` and a diagnostic — the original's `Play` refuses it and
    /// `childRoot` stays at its pin. `playRotation` is the rotation `Play`
    /// leaves on `childRoot` (point 0's world rotation, in the same engine
    /// basis as `childRootWorld`'s result) and `playDeltaTime` the `Play`
    /// frame's own `Time.deltaTime`; together they seed the `LookUpdate`
    /// state the first frame's `LateUpdate` damps from. Without them the
    /// stepper still plays but its rotation state starts at zero, which only
    /// matches a route whose point 0 is unrotated.
    public static func stepper(route: KoikatsuRouteRecord, routeWorld: float4x4, pointLocals: [float4x4],
                               playRotation: simd_quatf? = nil, playDeltaTime: Double? = nil)
        -> (stepper: SourceStudioRouteStepper?, diagnostics: [String]) {
        var diagnostics: [String] = []
        var locals = pointLocals
        if locals.count != route.points.count {
            diagnostics.append("Route stepping received \(locals.count) point locals for \(route.points.count) route points; authored record transforms are used.")
            locals = Self.pointLocals(from: route)
        }
        do {
            let evaluator = try Self.makeEvaluator(route: route, routeWorld: routeWorld, locals: locals)
            // The evaluator runs in source (Unity) numeric space, so the
            // engine-basis seed converts back through the same involutive
            // basis change `samples` uses for its output.
            return (try SourceStudioRouteStepper(points: evaluator.points, loop: evaluator.loop,
                                                 orientation: evaluator.orientation,
                                                 initialRotation: playRotation.map(UnityCoordinates.rotation),
                                                 initialDelta: playDeltaTime), diagnostics)
        } catch {
            diagnostics.append("Route stepping unavailable: \(error) childRoot remains pinned to point 0.")
            return (nil, diagnostics)
        }
    }

    /// The aim `childRoot` holds after a non-looping route's `onComplete`:
    /// at percentage 1 the lookahead clamps onto the finished position and the
    /// instantaneous aim is degenerate, so the held rotation is the last
    /// non-degenerate one — the aim at `1 - lookAhead` on the final segment.
    /// Identical at every `elapsed` past the end, which is what "holds" means;
    /// a route whose held aim is itself degenerate keeps `nil` there and
    /// `childRootWorld` falls back to point 0's rotation with its diagnostic.
    private static func heldAim(evaluator: SourceStudioRoute, aim: SourceStudioRoute.Aim) -> SourceStudioRoute.Aim {
        let hold = min(max(1 - SourceStudioRoute.lookAhead, 0), 1)
        guard let segment = (try? evaluator.segments())?.last else { return aim }
        let position = SourceStudioRoute.interp(segment.controlPoints,
                                                min(max(SourceStudioRoute.ease(segment.easeType, 0, 1, hold), 0), 1))
        let aheadEased = SourceStudioRoute.ease(segment.easeType, 0, 1,
                                               min(1, hold + SourceStudioRoute.lookAhead))
        let lookTarget = SourceStudioRoute.interp(segment.controlPoints, min(max(aheadEased, 0), 1))
        return .init(axis: aim.axis, lookTarget: lookTarget,
                     rotation: SourceStudioRoute.lookRotation(from: position, target: lookTarget, axis: aim.axis))
    }

    /// The evaluator over the record's points in source world space: route
    /// points and their aid targets are child objects of the route, so moving
    /// the route moves the whole path. The evaluator runs in the source
    /// numeric convention, hence the conversion of world positions.
    private static func makeEvaluator(route: KoikatsuRouteRecord, routeWorld: float4x4,
                                      locals: [float4x4]) throws -> SourceStudioRoute {
        guard let orientation = SourceStudioRoute.Orientation(rawValue: route.orientation) else {
            throw RigError.invalid("Route has unknown orientation \(route.orientation).")
        }
        var points: [SourceStudioRoute.Point] = []
        for (index, point) in route.points.enumerated() {
            guard let connection = SourceStudioRoute.Connection(rawValue: point.connection) else {
                throw RigError.invalid("Route point \(index) has unknown connection \(point.connection).")
            }
            guard let easeType = SourceStudioRoute.EaseType(rawValue: point.easeType) else {
                throw RigError.invalid("Route point \(index) has unknown ease type \(point.easeType).")
            }
            let position = unityWorldPosition(routeWorld * locals[index])
            // The aid transform is Point-local (its localPosition under the
            // route point), so it composes through the point's local matrix.
            let aid = point.aidInitialized
                ? unityWorldPosition(routeWorld * locals[index] * localMatrix(point.aid.transform)) : nil
            points.append(.init(position: position, aid: aid, connection: connection,
                                linked: point.linked, speed: Double(point.speed), easeType: easeType))
        }
        return SourceStudioRoute(points: points, loop: route.loop, orientation: orientation)
    }

    /// One route of a decoded snapshot sampled at one clock position.
    /// `childRootPosition` and `childRootRotationEulerZXY` are Unity-space
    /// values (position reflected, rotation re-expressed in the source's
    /// Z-X-Y Euler order) so they read like the scene record that produced
    /// them.
    public struct Sample: Sendable, Equatable {
        public let sourceKey: Int32
        public let name: String?
        /// The record's flag with the playback completion applied: `false`
        /// when the record pins the route inactive or a playing non-looping
        /// route has already run out its segments (`onComplete`).
        public let active: Bool
        public let loop: Bool, visibleLine: Bool
        public let orientation: Int32
        public let pointCount: Int
        public let childRootPosition: SIMD3<Float>
        public let childRootRotationEulerZXY: SIMD3<Float>
        public let diagnostics: [String]
    }

    /// Sample every route object in a decoded snapshot, in depth-first record
    /// order, at `elapsed` seconds using the authored point transforms. This
    /// covers record decoding and playback only: original capture animation,
    /// `LookUpdate` smoothing and edited point objects are out of scope.
    public static func samples(in snapshot: KoikatsuSceneSnapshot, elapsed: Double) -> [Sample] {
        var samples: [Sample] = []
        func visit(_ record: KoikatsuObjectRecord, parentWorld: float4x4) {
            let world = parentWorld * localMatrix(record.transform)
            if let route = record.route {
                let locals = pointLocals(from: route)
                let (matrix, diagnostics) = childRootWorld(route: route, routeWorld: world,
                                                           pointLocals: locals, elapsed: elapsed)
                let finished = Self.isFinished(route: route, routeWorld: world,
                                               pointLocals: locals, elapsed: elapsed)
                samples.append(Sample(sourceKey: record.sourceKey, name: record.name,
                                      active: route.active && !finished, loop: route.loop, visibleLine: route.visibleLine,
                                      orientation: route.orientation, pointCount: route.points.count,
                                      childRootPosition: UnityCoordinates.position(matrix.translation),
                                      childRootRotationEulerZXY: UnityCoordinates.sourceEulerDegrees(matrix.rotationQuaternion),
                                      diagnostics: diagnostics))
            }
            for child in record.children { visit(child, parentWorld: world) }
        }
        for root in snapshot.roots { visit(root, parentWorld: matrix_identity_float4x4) }
        return samples
    }

    /// One frame of per-frame stepping: what `childRoot` holds after that
    /// frame's tween update wrote its placement (the rules are documented on
    /// `SourceStudioRouteStepper`). Position and rotation are Unity-space
    /// values like `Sample`'s, so they read like the scene record that
    /// produced them.
    public struct SteppedFrame: Sendable, Equatable {
        /// The `Time.deltaTime` this frame consumed.
        public let deltaTime: Double
        public let childRootPosition: SIMD3<Float>
        public let childRootRotationEulerZXY: SIMD3<Float>
        /// `false` from the frame a non-looping route's `onComplete` fired on
        /// onward (`OCIRoute`'s handler sets `routeInfo.active = false` while
        /// `childRoot` keeps its last written placement).
        public let active: Bool
        /// `false` while `childRoot` still holds point 0's `Play` rotation —
        /// before the first frame's `LateUpdate` has damped anything, or
        /// forever when the orientation is none (`LookUpdate` never runs, so
        /// the rotation is never even an aim). `true` once the `LookUpdate`
        /// state has started moving: `childRootRotationEulerZXY` is then the
        /// damped Euler, one `SmoothDampAngle` step behind the instantaneous
        /// aim, not the aim itself.
        public let rotationFromAim: Bool
    }

    /// One route of a decoded snapshot stepped frame by frame, in depth-first
    /// record order.
    public struct SteppedRoute: Sendable {
        public let sourceKey: Int32
        public let name: String?
        /// The record's own flag; an inactive route is never stepped — its
        /// pin (`Stop`) repeats every frame.
        public let recordActive: Bool
        public let loop: Bool, visibleLine: Bool
        public let orientation: Int32
        public let pointCount: Int
        /// Setup diagnostics; a route that cannot play reports them and has
        /// no frames.
        public let diagnostics: [String]
        public let frames: [SteppedFrame]
    }

    /// Step every route object in a decoded snapshot frame by frame over
    /// `deltaTimes` (one `Time.deltaTime` per frame) using the authored point
    /// transforms. Frame `k` reports the placement `childRoot` holds after
    /// frame `k`'s tween update — the state a capture recording after the
    /// tween's `Update` would observe; `Play`'s own percentage-0 application
    /// is frame 0's starting state and is not a frame of its own. A
    /// non-finite or negative `deltaTime` is reported before any route runs.
    /// `playDeltaTime` — the `Play` frame's own `deltaTime`, which row 0's
    /// `LateUpdate` damp consumed but the tween never advanced with — seeds
    /// the `LookUpdate` rotation state alongside point 0's world rotation;
    /// omitting it falls back to the first supplied frame delta, which only
    /// matches a capture whose `Play` frame ran at that delta.
    public static func steppedRoutes(in snapshot: KoikatsuSceneSnapshot, deltaTimes: [Double],
                                     playDeltaTime: Double? = nil) throws -> [SteppedRoute] {
        for (index, delta) in deltaTimes.enumerated() {
            guard delta.isFinite, delta >= 0 else {
                throw RigError.invalid("Route stepping deltaTime \(delta) at frame \(index) must be finite and non-negative.")
            }
        }
        if let playDeltaTime, !playDeltaTime.isFinite || playDeltaTime < 0 {
            throw RigError.invalid("Route stepping playDeltaTime \(playDeltaTime) must be finite and non-negative.")
        }
        var routes: [SteppedRoute] = []
        func visit(_ record: KoikatsuObjectRecord, parentWorld: float4x4) {
            let world = parentWorld * localMatrix(record.transform)
            if let route = record.route {
                let locals = pointLocals(from: route)
                // `Stop` pins to point 0's world placement; `Play` starts from it.
                let point0World = world * (locals.first ?? matrix_identity_float4x4)
                let point0Rotation = point0World.rotationQuaternion
                var diagnostics: [String] = []
                var built: SourceStudioRouteStepper?
                // Seed the LookUpdate state with what `Play` actually left:
                // point 0's world rotation and the Play frame's own delta
                // (falling back to the first supplied frame delta, since a
                // capture that seeds a Play frame ran one).
                let initialDelta = playDeltaTime ?? deltaTimes.first
                if route.active, let initialDelta {
                    let setup = stepper(route: route, routeWorld: world, pointLocals: locals,
                                        playRotation: point0Rotation, playDeltaTime: initialDelta)
                    built = setup.stepper
                    diagnostics = setup.diagnostics
                }
                var frames: [SteppedFrame] = []
                var rotationFromLookUpdate = false
                if var running = built {
                    // Mirror of the stepper's LateUpdate condition, frame by
                    // frame: the tween ran this frame (it was not finished at
                    // the frame's start), the orientation is set, a previous
                    // write left a valid looktarget, and a previous write's
                    // deltaTime seeded the damp (`Play`'s own at frame 0,
                    // guaranteed non-nil because `built` exists).
                    var wasRunning = true
                    var previousAimRotation = running.current().aim?.rotation != nil
                    for delta in deltaTimes {
                        let aimWasValid = previousAimRotation
                        // Validated above, so stepping cannot throw here.
                        let written = (try? running.step(deltaTime: delta)) ?? running.current()
                        previousAimRotation = written.aim?.rotation != nil
                        if wasRunning, route.orientation != 0, aimWasValid {
                            rotationFromLookUpdate = true
                        }
                        wasRunning = written.active
                        // The stepper runs on the evaluator's source-space
                        // (Unity) points, so neither its position nor its
                        // LookUpdate Euler needs a coordinate flip — unlike
                        // the engine-space matrix `samples` converts. The
                        // rotation is the damped Euler, not the instantaneous
                        // aim.
                        frames.append(SteppedFrame(
                            deltaTime: delta,
                            childRootPosition: Float3(Float(written.position.x),
                                                      Float(written.position.y),
                                                      Float(written.position.z)),
                            childRootRotationEulerZXY: Float3(Float(written.rotation.x),
                                                             Float(written.rotation.y),
                                                             Float(written.rotation.z)),
                            active: written.active, rotationFromAim: rotationFromLookUpdate))
                    }
                } else if !route.active {
                    // `Stop` pins every frame; an unplayable active route
                    // reported its diagnostic above and has no frames.
                    frames = deltaTimes.map {
                        SteppedFrame(deltaTime: $0,
                                     childRootPosition: UnityCoordinates.position(point0World.translation),
                                     childRootRotationEulerZXY: UnityCoordinates.sourceEulerDegrees(point0Rotation),
                                     active: false, rotationFromAim: false)
                    }
                }
                routes.append(SteppedRoute(sourceKey: record.sourceKey, name: record.name,
                                           recordActive: route.active,
                                           loop: route.loop, visibleLine: route.visibleLine,
                                           orientation: route.orientation, pointCount: route.points.count,
                                           diagnostics: diagnostics, frames: frames))
            }
            for child in record.children { visit(child, parentWorld: world) }
        }
        for root in snapshot.roots { visit(root, parentWorld: matrix_identity_float4x4) }
        return routes
    }

    private static func localMatrix(_ value: KoikatsuChangeAmount) -> float4x4 {
        Transform.trs(UnityCoordinates.position(value.position),
                      UnityCoordinates.eulerDegrees(value.rotationDegrees), value.scale)
    }

    private static func unityWorldPosition(_ world: float4x4) -> SIMD3<Double> {
        let position = UnityCoordinates.position(world.translation)
        return SIMD3(Double(position.x), Double(position.y), Double(position.z))
    }
}
