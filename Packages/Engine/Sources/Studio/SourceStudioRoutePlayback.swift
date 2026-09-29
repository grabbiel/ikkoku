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
///   its end position.
/// The recovered assignments write position and rotation only; the inherited
/// route scale is kept.
///
/// Route points are child objects of the route, so their world transform is
/// the route object's world matrix times their local transform; the caller
/// supplies those locals. `routeWorld` and the returned matrix are engine
/// (right-handed) world matrices; the `SourceStudioRoute` evaluator still runs
/// in the source (Unity) numeric convention and its position and aim are
/// converted here, exactly as imported characters convert saved FK Euler.
/// The stateful `LookUpdate` `SmoothDampAngle` smoothing is not simulated:
/// the aim is instantaneous.
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

        let orientation: SourceStudioRoute.Orientation
        do {
            guard let valid = SourceStudioRoute.Orientation(rawValue: route.orientation) else {
                throw RigError.invalid("Route has unknown orientation \(route.orientation).")
            }
            orientation = valid
        } catch {
            diagnostics.append("Route playback unavailable: \(error) childRoot remains pinned to point 0.")
            return (pinned, diagnostics)
        }
        // Route points and their aid targets are child objects of the route,
        // so moving the route moves the whole path. The evaluator runs in the
        // source numeric convention, hence the conversion of world positions.
        var points: [SourceStudioRoute.Point] = []
        do {
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
        } catch {
            diagnostics.append("Route playback unavailable: \(error) childRoot remains pinned to point 0.")
            return (pinned, diagnostics)
        }
        let evaluator = SourceStudioRoute(points: points, loop: route.loop, orientation: orientation)
        let evaluation: SourceStudioRoute.Evaluation
        do {
            evaluation = try evaluator.evaluate(at: time)
        } catch {
            diagnostics.append("Route playback unavailable: \(error) childRoot remains pinned to point 0.")
            return (pinned, diagnostics)
        }

        var rotation = point0World.rotationQuaternion
        if let aim = evaluation.aim {
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

    /// One route of a decoded snapshot sampled at one clock position.
    /// `childRootPosition` and `childRootRotationEulerZXY` are Unity-space
    /// values (position reflected, rotation re-expressed in the source's
    /// Z-X-Y Euler order) so they read like the scene record that produced
    /// them.
    public struct Sample: Sendable, Equatable {
        public let sourceKey: Int32
        public let name: String?
        public let active: Bool, loop: Bool, visibleLine: Bool
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
                let (matrix, diagnostics) = childRootWorld(route: route, routeWorld: world,
                                                           pointLocals: pointLocals(from: route), elapsed: elapsed)
                samples.append(Sample(sourceKey: record.sourceKey, name: record.name,
                                      active: route.active, loop: route.loop, visibleLine: route.visibleLine,
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

    private static func localMatrix(_ value: KoikatsuChangeAmount) -> float4x4 {
        Transform.trs(UnityCoordinates.position(value.position),
                      UnityCoordinates.eulerDegrees(value.rotationDegrees), value.scale)
    }

    private static func unityWorldPosition(_ world: float4x4) -> SIMD3<Double> {
        let position = UnityCoordinates.position(world.translation)
        return SIMD3(Double(position.x), Double(position.y), Double(position.z))
    }
}
