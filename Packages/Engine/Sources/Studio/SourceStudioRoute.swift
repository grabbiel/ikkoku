import Foundation
import simd
import CoreMath
import Scene

/// Native evaluator for authored CharaStudio routes, ported from the recovered
/// `OCIRoute.Play`/`SetPath` segment chain and the `StudioTween` MoveTo-path
/// math. Arithmetic runs in Double like `Tools/reverse/analysis/
/// studio_route_reference.py`; neither side claims bit-exact Unity float32
/// equality. This is evaluation only: there is no playback clock, UI or
/// rendering here, and the visible `LookUpdate` SmoothDamp rotation pass is
/// not simulated — orientation exposes the instantaneous aim at the recovered
/// lookahead sample instead.
public struct SourceStudioRoute: Sendable, Equatable {
    /// `OIRoutePointInfo.Connection` (Line = 0, Curve = 1).
    public enum Connection: Int32, Sendable, Equatable, CaseIterable {
        case line = 0, curve = 1
    }

    /// `OIRouteInfo.Orient` (None = 0, XY = 1, Y = 2).
    public enum Orientation: Int32, Sendable, Equatable, CaseIterable {
        case none = 0, xy = 1, y = 2
    }

    /// `StudioTween.EaseType` at StudioTween.cs line 17; route point records
    /// store the ordinal and default to `linear`.
    public enum EaseType: Int32, Sendable, Equatable, CaseIterable {
        case easeInQuad = 0, easeOutQuad, easeInOutQuad
        case easeInCubic, easeOutCubic, easeInOutCubic
        case easeInQuart, easeOutQuart, easeInOutQuart
        case easeInQuint, easeOutQuint, easeInOutQuint
        case easeInSine, easeOutSine, easeInOutSine
        case easeInExpo, easeOutExpo, easeInOutExpo
        case easeInCirc, easeOutCirc, easeInOutCirc
        case linear, spring
        case easeInBounce, easeOutBounce, easeInOutBounce
        case easeInBack, easeOutBack, easeInOutBack
        case easeInElastic, easeOutElastic, easeInOutElastic
    }

    /// One authored route point. Curve connections require an aid control
    /// target. Original records serialize an aid object for Line points too;
    /// that value has no effect on their straight path and is ignored.
    public struct Point: Sendable, Equatable {
        public let position: SIMD3<Double>
        public let aid: SIMD3<Double>?
        public let connection: Connection
        /// `OIRoutePointInfo.link`: chains this point into the previous
        /// curve segment when the connection is Curve (`isLink`).
        public let linked: Bool
        public let speed: Double
        public let easeType: EaseType

        public init(position: SIMD3<Double>, aid: SIMD3<Double>? = nil, connection: Connection = .line,
                    linked: Bool = false, speed: Double = 2, easeType: EaseType = .linear) {
            self.position = position; self.aid = connection == .curve ? aid : nil; self.connection = connection
            self.linked = linked; self.speed = speed; self.easeType = easeType
        }
    }

    /// One MoveTo segment: the control path (route positions with the
    /// segment's aid points interleaved), plus the speed/ease authored on its
    /// first point (`OCIRoute.SetPath`, StudioTween `MoveTo(Hashtable)`).
    public struct Segment: Sendable, Equatable {
        public let startIndex: Int
        public let path: [SIMD3<Double>]
        public let speed: Double
        public let easeType: EaseType

        /// The padded control array the recovered tween stores on its
        /// `CRSpline` (`GenerateMoveToPathTargets`).
        public let controlPoints: [SIMD3<Double>]

        /// `time = PathLength(vector3s) / speed` — PathLength re-runs
        /// PathControlPointGenerator over the already-padded array, so a
        /// straight two-point segment times at three times its geometric
        /// length. That quirk is source behavior, kept verbatim.
        public let duration: Double

        init(startIndex: Int, path: [SIMD3<Double>], speed: Double, easeType: EaseType) {
            self.startIndex = startIndex; self.path = path
            self.speed = speed; self.easeType = easeType
            let controlPoints = SourceStudioRoute.pathControlPointGenerator(path)
            self.controlPoints = controlPoints
            self.duration = SourceStudioRoute.pathLength(controlPoints) / speed
        }
    }

    /// Orient-to-path result for one sample: the lookahead target plus the
    /// instantaneous aim rotation facing it (`nil` when the aim direction is
    /// degenerate). The source's axis-"y" post-pass keeps the root's own x/z
    /// Euler around this yaw; the stateful frame smoothing is out of scope.
    public struct Aim: Sendable, Equatable {
        public let axis: Orientation
        public let lookTarget: SIMD3<Double>
        public let rotation: simd_quatf?
    }

    public struct Evaluation: Sendable, Equatable {
        public let position: SIMD3<Double>
        public let segmentIndex: Int
        public let finished: Bool
        public let aim: Aim?
    }

    public let points: [Point]
    /// `OIRouteInfo.loop`, default true.
    public let loop: Bool
    public let orientation: Orientation
    private enum Preparation: Sendable, Equatable {
        case ready(segments: [Segment], total: Double)
        case invalid(String)
    }
    private let preparation: Preparation

    private static let maximumPoints = 1_024
    private static let maximumControlPolygonPoints = 2_048

    /// `Defaults.lookAhead` (StudioTween.cs 98), used when the route does not
    /// override the lookahead.
    public static let lookAhead = 0.05

    public init(points: [Point], loop: Bool = true, orientation: Orientation = .none) {
        self.points = points; self.loop = loop; self.orientation = orientation
        self.preparation = Self.prepare(points: points, loop: loop)
    }

    /// Boundary from the decoded scene record. Nonzero enum ordinals that are
    /// not a known enum value, and curve points whose aid target was never
    /// initialised, become diagnostics instead of guesses.
    public init(record: KoikatsuRouteRecord) throws {
        guard record.points.count <= Self.maximumPoints else {
            throw RigError.invalid("Route has \(record.points.count) points; maximum is \(Self.maximumPoints).")
        }
        var points: [Point] = []
        for (index, point) in record.points.enumerated() {
            guard let connection = Connection(rawValue: point.connection) else {
                throw RigError.invalid("Route point \(index) has unknown connection \(point.connection).")
            }
            guard let easeType = EaseType(rawValue: point.easeType) else {
                throw RigError.invalid("Route point \(index) has unknown ease type \(point.easeType).")
            }
            let aid = point.aidInitialized ? SIMD3<Double>(point.aid.transform.position) : nil
            points.append(Point(position: SIMD3<Double>(point.bone.transform.position), aid: aid,
                                connection: connection, linked: point.linked,
                                speed: Double(point.speed), easeType: easeType))
        }
        guard let orientation = Orientation(rawValue: record.orientation) else {
            throw RigError.invalid("Route has unknown orientation \(record.orientation).")
        }
        self.init(points: points, loop: record.loop, orientation: orientation)
    }

    /// `OCIRoute.Play` refuses a route with fewer than two points; every
    /// other precondition is checked here so an unplayable route reports
    /// which point or segment fails.
    public func segments() throws -> [Segment] {
        switch preparation {
        case .ready(let segments, _): return segments
        case .invalid(let message): throw RigError.invalid(message)
        }
    }

    private static func prepare(points: [Point], loop: Bool) -> Preparation {
        guard points.count <= maximumPoints else {
            return .invalid("Route has \(points.count) points; maximum is \(maximumPoints).")
        }
        guard points.count >= 2 else {
            return .invalid("Route has \(points.count) points; at least 2 are needed.")
        }
        for (index, point) in points.enumerated() {
            guard point.speed.isFinite, point.speed > 0 else {
                return .invalid("Route point \(index) speed \(point.speed) must be finite and positive.")
            }
            guard point.position.x.isFinite, point.position.y.isFinite, point.position.z.isFinite else {
                return .invalid("Route point \(index) has a nonfinite position.")
            }
            if point.connection == .curve {
                guard let aid = point.aid else {
                    return .invalid("Route point \(index) has a curve connection with no aid target.")
                }
                guard aid.x.isFinite, aid.y.isFinite, aid.z.isFinite else {
                    return .invalid("Route point \(index) has a nonfinite aid target.")
                }
            }
        }

        var segments: [Segment] = []
        var index = 0
        while index < points.count {
            // A non-looping route never leaves the last point (Play breaks
            // the SetPath chain there).
            guard loop || index != points.count - 1 else { break }
            let first = points[index]
            var path: [SIMD3<Double>]
            switch first.connection {
            case .line:
                if index != points.count - 1 {
                    path = [points[index].position, points[index + 1].position]
                } else {
                    path = [points[index].position, points[0].position]
                }
            case .curve:
                path = [first.position, first.aid!]
                var following = index + 1
                // Linked curve points join this segment (isLink).
                while following < points.count, (loop || following != points.count - 1),
                      points[following].linked, points[following].connection == .curve {
                    guard path.count + 2 <= maximumControlPolygonPoints else {
                        return .invalid("Route segment starting at point \(index) exceeds \(maximumControlPolygonPoints) control polygon points.")
                    }
                    path.append(contentsOf: [points[following].position, points[following].aid!])
                    following += 1
                }
                guard path.count + 1 <= maximumControlPolygonPoints else {
                    return .invalid("Route segment starting at point \(index) exceeds \(maximumControlPolygonPoints) control polygon points.")
                }
                path.append(following >= points.count ? points[0].position : points[following].position)
            }
            let segment = Segment(startIndex: index, path: path, speed: first.speed, easeType: first.easeType)
            guard segment.duration.isFinite, segment.duration > 0 else {
                return .invalid("Route segment starting at point \(index) has no playable duration.")
            }
            segments.append(segment)
            // SetPath advances past every point the segment consumed, so the
            // next segment starts at the segment's closing point.
            index += path.count / 2
        }
        guard !segments.isEmpty else {
            return .invalid("Route cannot play: no segments were built.")
        }
        return .ready(segments: segments, total: segments.reduce(0) { $0 + $1.duration })
    }

    /// Sample the route at `elapsedSeconds`: which segment, the eased
    /// position on it, whether the route finished, and the orient-to-path aim.
    public func evaluate(at elapsedSeconds: Double) throws -> Evaluation {
        guard elapsedSeconds.isFinite, elapsedSeconds >= 0 else {
            throw RigError.invalid("Elapsed time \(elapsedSeconds) must be finite and non-negative.")
        }
        let segments: [Segment]
        let total: Double
        switch preparation {
        case .ready(let preparedSegments, let preparedTotal):
            segments = preparedSegments
            total = preparedTotal
        case .invalid(let message): throw RigError.invalid(message)
        }
        guard total.isFinite, total > 0 else {
            throw RigError.invalid("Route duration \(total) is not playable.")
        }
        var elapsed = elapsedSeconds
        if loop {
            // LoopType.loop restarts the whole segment list from the start.
            elapsed = elapsed.truncatingRemainder(dividingBy: total)
        }
        let finished = !loop && elapsed >= total

        var index = 0
        var start = 0.0
        while index + 1 < segments.count, elapsed >= start + segments[index].duration {
            start += segments[index].duration
            index += 1
        }
        let segment = segments[index]
        let percentage = min(max((elapsed - start) / segment.duration, 0), 1)
        let eased = Self.ease(segment.easeType, 0, 1, percentage)
        let position = Self.interp(segment.controlPoints, min(max(eased, 0), 1))

        var aim: Aim?
        if orientation != .none {
            let aheadPercentage = min(1, percentage + Self.lookAhead)
            let aheadEased = Self.ease(segment.easeType, 0, 1, aheadPercentage)
            let lookTarget = Self.interp(segment.controlPoints, min(max(aheadEased, 0), 1))
            aim = Aim(axis: orientation, lookTarget: lookTarget,
                      rotation: Self.lookRotation(from: position, target: lookTarget, axis: orientation))
        }
        return Evaluation(position: position, segmentIndex: index, finished: finished, aim: aim)
    }

    // MARK: - Recovered spline math (StudioTween.cs)

    static func interp(_ points: [SIMD3<Double>], _ t: Double) -> SIMD3<Double> {
        let spans = points.count - 3
        precondition(spans >= 1, "control point array too short to interpolate")
        let segment = min(Int((t * Double(spans)).rounded(.down)), spans - 1)
        let u = t * Double(spans) - Double(segment)
        let p0 = points[segment], p1 = points[segment + 1], p2 = points[segment + 2], p3 = points[segment + 3]
        func component(_ v: (SIMD3<Double>) -> Double) -> Double {
            0.5 * ((-v(p0) + 3 * v(p1) - 3 * v(p2) + v(p3)) * u * u * u
                   + (2 * v(p0) - 5 * v(p1) + 4 * v(p2) - v(p3)) * u * u
                   + (-v(p0) + v(p2)) * u + 2 * v(p1))
        }
        return SIMD3(component(\.x), component(\.y), component(\.z))
    }

    static func pathControlPointGenerator(_ path: [SIMD3<Double>]) -> [SIMD3<Double>] {
        func reflect(_ reference: SIMD3<Double>, _ following: SIMD3<Double>) -> SIMD3<Double> {
            reference + (reference - following)
        }
        var array = [reflect(path[0], path[1])] + path + [reflect(path[path.count - 1], path[path.count - 2])]
        // A closed path (first point == last point) wraps to the opposite
        // side instead of reflecting.
        if array[1] == array[array.count - 2] {
            var wrapped = array
            wrapped[0] = wrapped[wrapped.count - 3]
            wrapped[wrapped.count - 1] = wrapped[2]
            array = wrapped
        }
        return array
    }

    static func pathLength(_ path: [SIMD3<Double>]) -> Double {
        let pts = pathControlPointGenerator(path)
        var cursor = interp(pts, 0)
        var total = 0.0
        let samples = path.count * 20
        for i in 1...samples {
            let next = interp(pts, Double(i) / Double(samples))
            let d = next - cursor
            total += (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
            cursor = next
        }
        return total
    }

    // MARK: - Easing (GetEasingFunction dispatch over the 32 EaseType bodies)

    static func ease(_ type: EaseType, _ start: Double, _ end: Double, _ value: Double) -> Double {
        switch type {
        case .linear: return start + (end - start) * value
        case .spring:
            let v = min(max(value, 0), 1)
            let shaped = (sin(v * Double.pi * (0.2 + 2.5 * v * v * v)) * pow(1 - v, 2.2) + v) * (1 + 1.2 * (1 - v))
            return start + (end - start) * shaped
        case .easeInQuad: return end * value * value + start
        case .easeOutQuad: return -end * value * (value - 2) + start
        case .easeInOutQuad:
            var v = value / 0.5
            if v < 1 { return end / 2 * v * v + start }
            v -= 1
            return -end / 2 * (v * (v - 2) - 1) + start
        case .easeInCubic: return end * value * value * value + start
        case .easeOutCubic: return end * pow(value - 1, 3) + end + start
        case .easeInOutCubic:
            var v = value / 0.5
            if v < 1 { return end / 2 * v * v * v + start }
            v -= 2
            return end / 2 * (v * v * v + 2) + start
        case .easeInQuart: return end * pow(value, 4) + start
        case .easeOutQuart: return -end * (pow(value - 1, 4) - 1) + start
        case .easeInOutQuart:
            var v = value / 0.5
            if v < 1 { return end / 2 * pow(v, 4) + start }
            v -= 2
            return -end / 2 * (pow(v, 4) - 2) + start
        case .easeInQuint: return end * pow(value, 5) + start
        case .easeOutQuint: return end * (pow(value - 1, 5) + 1) + start
        case .easeInOutQuint:
            var v = value / 0.5
            if v < 1 { return end / 2 * pow(v, 5) + start }
            v -= 2
            return end / 2 * (pow(v, 5) + 2) + start
        case .easeInSine: return -end * cos(value * Double.pi / 2) + end + start
        case .easeOutSine: return end * sin(value * Double.pi / 2) + start
        case .easeInOutSine: return -end / 2 * (cos(value * Double.pi) - 1) + start
        case .easeInExpo: return end * pow(2, 10 * (value - 1)) + start
        case .easeOutExpo: return end * (-pow(2, -10 * value) + 1) + start
        case .easeInOutExpo:
            var v = value / 0.5
            if v < 1 { return end / 2 * pow(2, 10 * (v - 1)) + start }
            v -= 1
            return end / 2 * (2 - pow(2, -10 * v)) + start
        case .easeInCirc: return -end * (max(0, 1 - value * value).squareRoot() - 1) + start
        case .easeOutCirc: return end * max(0, 1 - (value - 1) * (value - 1)).squareRoot() + start
        case .easeInOutCirc:
            var v = value / 0.5
            if v < 1 { return -end / 2 * (max(0, 1 - v * v).squareRoot() - 1) + start }
            v -= 2
            return end / 2 * (max(0, 1 - v * v).squareRoot() + 1) + start
        case .easeInBounce: return end - ease(.easeOutBounce, 0, end, 1 - value) + start
        case .easeOutBounce:
            if value < 372.0 / 1023.0 { return end * (7.5625 * value * value) + start }
            if value < 744.0 / 1023.0 {
                let v = value - 558.0 / 1023.0
                return end * (7.5625 * v * v + 0.75) + start
            }
            if value < 930.0 / 1023.0 {
                let v = value - 837.0 / 1023.0
                return end * (7.5625 * v * v + 0.9375) + start
            }
            let v = value - 21.0 / 22.0
            return end * (7.5625 * v * v + 63.0 / 64.0) + start
        case .easeInOutBounce:
            if value < 0.5 { return ease(.easeInBounce, 0, end, value * 2) * 0.5 + start }
            return ease(.easeOutBounce, 0, end, value * 2 - 1) * 0.5 + end * 0.5 + start
        case .easeInBack:
            let c = 1.70158
            return end * value * value * ((c + 1) * value - c) + start
        case .easeOutBack:
            let c = 1.70158
            let v = value - 1
            return end * (v * v * ((c + 1) * v + c) + 1) + start
        case .easeInOutBack:
            let c = 1.70158
            var v = value / 0.5
            if v < 1 { return end / 2 * (v * v * ((c * 1.525 + 1) * v - c * 1.525)) + start }
            v -= 2
            return end / 2 * (v * v * ((c * 1.525 + 1) * v + c * 1.525) + 2) + start
        case .easeInElastic:
            if value == 0 { return start }
            if value == 1 { return start + end }
            // Amplitude starts at 0, so the source always takes the
            // amplitude = end, s = period / 4 branch (period = 0.3).
            return -end * pow(2, 10 * (value - 1)) * sin((value - 0.3 / 4) * Double.pi * 2 / 0.3) + start
        case .easeOutElastic:
            if value == 0 { return start }
            if value == 1 { return start + end }
            return end * pow(2, -10 * value) * sin((value - 0.3 / 4) * Double.pi * 2 / 0.3) + end + start
        case .easeInOutElastic:
            if value == 0 { return start }
            let v = value / 0.5
            if v == 2 { return start + end }
            if v < 1 {
                return -0.5 * (end * pow(2, 10 * (v - 1)) * sin((v - 0.3 / 4) * Double.pi * 2 / 0.3)) + start
            }
            return end * pow(2, -10 * (v - 1)) * sin((v - 0.3 / 4) * Double.pi * 2 / 0.3) * 0.5 + end + start
        }
    }

    // MARK: - Orient to path (ApplyMoveToPathTargets aim; LookUpdate not simulated)

    static func lookRotation(from position: SIMD3<Double>, target: SIMD3<Double>,
                             axis: Orientation) -> simd_quatf? {
        var direction = target - position
        if axis == .y {
            // Face only the horizontal component; the axis-"y" post-pass
            // keeps the root's own x/z Euler around the resulting yaw.
            direction.y = 0
        }
        guard max(abs(direction.x), abs(direction.y), abs(direction.z)) >= 1e-9 else { return nil }
        return lookAt(direction)
    }

    /// Same construction as `simd_quatf.lookRotation` / Unity
    /// `Quaternion.LookRotation`: basis columns are right, up, forward.
    private static func lookAt(_ direction: SIMD3<Double>) -> simd_quatf {
        func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
            v / (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        }
        func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        let forward = unit(direction)
        var up = SIMD3<Double>(0, 1, 0)
        if abs(forward.y) > 0.999 { up = SIMD3(1, 0, 0) }
        let right = unit(cross(up, forward))
        up = cross(forward, right)
        // Column-major basis [right, up, forward]; Sheppards' conversion,
        // mirroring the reference port so both sides pick the same branch.
        let m = [[right.x, up.x, forward.x], [right.y, up.y, forward.y], [right.z, up.z, forward.z]]
        let trace = m[0][0] + m[1][1] + m[2][2]
        var w, x, y, z: Double
        if trace > 0 {
            let s = (trace + 1).squareRoot() / 2
            w = s
            x = (m[2][1] - m[1][2]) / (4 * s)
            y = (m[0][2] - m[2][0]) / (4 * s)
            z = (m[1][0] - m[0][1]) / (4 * s)
        } else if m[0][0] >= m[1][1], m[0][0] >= m[2][2] {
            let s = (1 + m[0][0] - m[1][1] - m[2][2]).squareRoot() / 2
            w = (m[2][1] - m[1][2]) / (4 * s)
            x = s
            y = (m[0][1] + m[1][0]) / (4 * s)
            z = (m[0][2] + m[2][0]) / (4 * s)
        } else if m[1][1] >= m[2][2] {
            let s = (1 + m[1][1] - m[0][0] - m[2][2]).squareRoot() / 2
            w = (m[0][2] - m[2][0]) / (4 * s)
            x = (m[0][1] + m[1][0]) / (4 * s)
            y = s
            z = (m[1][2] + m[2][1]) / (4 * s)
        } else {
            let s = (1 + m[2][2] - m[0][0] - m[1][1]).squareRoot() / 2
            w = (m[1][0] + m[0][1]) / (4 * s)
            x = (m[2][0] + m[0][2]) / (4 * s)
            y = (m[2][1] + m[1][2]) / (4 * s)
            z = s
        }
        let magnitude = (w * w + x * x + y * y + z * z).squareRoot()
        return simd_quatf(ix: Float(x / magnitude), iy: Float(y / magnitude),
                          iz: Float(z / magnitude), r: Float(w / magnitude))
    }
}
