import Foundation
import simd

/// A route edit CharaStudio would not make, with the reason the UI shows.
public enum SourceStudioRouteEditError: Error, LocalizedError, Equatable, Sendable {
    case refused(String)
    public var errorDescription: String? {
        switch self { case .refused(let reason): return reason }
    }
}

/// ST-T11 / ST-T03: an imported route's editable state — its points with
/// their aids and settings, and the route settings the `MPRouteCtrl` panel
/// changes — following the recovered CharaStudio 1.0.4.2 operations
/// (docs/reference/studio/scene-records.md, "Route editing"):
///
/// - `OCIRoute.AddPoint` -> `AddObjectRoute.AddPoint`: refused once the
///   route has more than ten points (`routePointLimit`, on by default), so a
///   route holds at most eleven; the new point is appended after the last
///   one (never inserted), at the last point's local position, with the
///   `OIRoutePointInfo` constructor values (speed 2, linear, line, no link)
///   and an uninitialised aid at the `p_RoutePoint` prefab's aid position.
/// - `OCIRoute.DeletePoint`: `Stop()` first, then the point leaves the list;
///   the start point (`スタート`, index 0) has no delete (`enableDelete`).
/// - Guides (`AddObjectRoute.LoadPoint`/`InitAid`): the start point rotates
///   only, every other point moves only, an aid moves only (its guide is
///   active for a curve connection only); nothing scales.
/// - `MPRoutePointCtrl`: speed, the six-entry ease list, connection
///   (`Curve` initialises an aid that was never placed at the point-local
///   midpoint to the next point, `InitAidPos`) and link.
/// - `MPRouteCtrl`: loop, line visibility, orient and the line colour (RGB
///   only, `_useAlpha: false`).
///
/// Values are Unity route-local (points) and Point-local (aids) change
/// amounts, exactly as the record stores them.
public struct SourceStudioRouteState: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable {
        /// The record point this one is (it keeps that point's and aid's
        /// keys); nil for a point `AddPoint` added. For a copy of a route the
        /// index names the copy's point at the same index.
        public var sourceIndex: Int?
        public var position: SIMD3<Float>
        public var rotationDegrees: SIMD3<Float>
        public var scale: SIMD3<Float>
        public var speed: Float
        public var easeType: Int32
        public var connection: Int32
        public var aidPosition: SIMD3<Float>
        public var aidRotationDegrees: SIMD3<Float>
        public var aidScale: SIMD3<Float>
        public var aidInitialized: Bool
        public var linked: Bool

        public var isCurve: Bool { connection == SourceStudioRoute.Connection.curve.rawValue }
        /// `OCIRoutePoint.isLink`: a link only joins curve points.
        public var isLink: Bool { linked && isCurve }
    }

    public var points: [Point]
    public var loop: Bool
    public var visibleLine: Bool
    public var orientation: Int32
    public var color: SIMD4<Float>

    /// `OCIRoute.limitNum` with `OptionSystem.routePointLimit` (default
    /// true): `AddPoint` returns null once the route has more than ten.
    public static let pointLimit = 11
    /// `OIRoutePointInfo(int)`: speed 2, `EaseType.linear`, `Connection.Line`.
    public static let newPointSpeed: Float = 2
    public static let newPointEase = SourceStudioRoute.EaseType.linear.rawValue
    /// The `p_RoutePoint` prefab's `objAid.localPosition` that `InitAid`
    /// copies into a new aid (read back from points authored with
    /// `AddObjectRoute.AddPoint` in the route fixtures: every uninitialised
    /// aid there is (1, 1, 1)).
    public static let newAidPosition = SIMD3<Float>(1, 1, 1)
    /// `MPRoutePointCtrl.Awake`'s ease dropdown, in its order.
    public static let easeChoices: [(name: String, ease: SourceStudioRoute.EaseType)] = [
        ("Linear", .linear), ("Gradually faster", .easeInQuad), ("Gradually slower", .easeOutQuad),
        ("Suddenly faster", .easeInQuart), ("Suddenly slower", .easeOutQuart), ("Bounce", .easeOutBounce)]
    /// The speed slider's range, a prefab value the recovered code only
    /// reads (`OnEndEditSpeed` clamps typed values to `inputSpeed.min/max`):
    /// 0.1 to 30, not whole numbers, read from the original player's
    /// `MPRoutePointCtrl.inputSpeed` slider by the ST-T11 reload probe
    /// (docs/reference/studio/scene-editing.md, route points and settings).
    public static let speedRange: ClosedRange<Float> = 0.1...30

    public init(points: [Point], loop: Bool, visibleLine: Bool, orientation: Int32, color: SIMD4<Float>) {
        self.points = points; self.loop = loop; self.visibleLine = visibleLine
        self.orientation = orientation; self.color = color
    }

    /// The record's own state: every point keeps its index.
    public init(record: KoikatsuRouteRecord) {
        points = record.points.enumerated().map { index, point in
            Point(sourceIndex: index, position: point.bone.transform.position,
                  rotationDegrees: point.bone.transform.rotationDegrees, scale: point.bone.transform.scale,
                  speed: point.speed, easeType: point.easeType, connection: point.connection,
                  aidPosition: point.aidTransform.position, aidRotationDegrees: point.aidTransform.rotationDegrees,
                  aidScale: point.aidTransform.scale, aidInitialized: point.aidInitialized, linked: point.linked)
        }
        loop = record.loop; visibleLine = record.visibleLine; orientation = record.orientation; color = record.color
    }

    /// The route record this state describes, for playback and the preview:
    /// sourced points keep `authored`'s keys, added points get placeholder
    /// keys (negative, runtime only; export allocates real ones). `active`
    /// stays the authored play state.
    public func record(authored: KoikatsuRouteRecord) -> KoikatsuRouteRecord {
        var added: Int32 = -1
        let points = points.map { point -> KoikatsuRoutePointRecord in
            // A legacy point's unsaved aid stays unallocated (nil).
            let keys: (Int32, Int32?)
            if let index = point.sourceIndex, authored.points.indices.contains(index) {
                keys = (authored.points[index].bone.sourceKey, authored.points[index].aidKey)
            } else {
                keys = (added, added - 1); added -= 2
            }
            return point.record(pointKey: keys.0, aidKey: keys.1)
        }
        return KoikatsuRouteRecord(points: points, active: authored.active, loop: loop, visibleLine: visibleLine,
                                   orientation: orientation, color: color)
    }

    // MARK: Rules

    /// What the route panel greys out while the route plays
    /// (`MPRouteCtrl.UpdateInteractable`: add point, orient, loop;
    /// `MPRoutePointCtrl.UpdateInteractable`: speed, ease, connection, link).
    /// Moving a point, its aid and the start rotation stay available, and so
    /// do the line toggle and colour; deleting a point stops the route.
    public enum Setting: Sendable, Equatable {
        case addPoint, orientation, loop, speed, ease, connection, link, visibleLine, color, move, delete
        public var lockedWhilePlaying: Bool {
            switch self {
            case .addPoint, .orientation, .loop, .speed, .ease, .connection, .link: return true
            case .visibleLine, .color, .move, .delete: return false
            }
        }
    }

    /// `MPRoutePointCtrl.UpdateInteractable`: a linked curve point that
    /// follows a curve point is part of that point's segment, so its own
    /// speed and ease are greyed out.
    public func speedAndEaseLocked(at index: Int) -> Bool {
        guard points.indices.contains(index), points[index].isCurve, points[index].linked, index > 0 else { return false }
        return points[index - 1].isCurve
    }

    private func refuse(_ reason: String) -> SourceStudioRouteEditError { .refused(reason) }
    private func check(_ index: Int) throws {
        guard points.indices.contains(index) else { throw refuse("The route has no point \(index).") }
    }

    /// `OCIRoute.AddPoint`: appends a point at the last point's position and
    /// returns its index.
    @discardableResult
    public mutating func addPoint() throws -> Int {
        guard points.count < Self.pointLimit else {
            throw refuse("CharaStudio adds no point to a route that already has \(Self.pointLimit) (OCIRoute.AddPoint, the route point limit option).")
        }
        guard let last = points.last else { throw refuse("A route without points cannot add one.") }
        points.append(Point(sourceIndex: nil, position: last.position, rotationDegrees: .zero, scale: .one,
                            speed: Self.newPointSpeed, easeType: Self.newPointEase,
                            connection: SourceStudioRoute.Connection.line.rawValue,
                            aidPosition: Self.newAidPosition, aidRotationDegrees: .zero, aidScale: .one,
                            aidInitialized: false, linked: false))
        return points.count - 1
    }

    /// `OCIRoute.DeletePoint` (the caller stops the route first, as it does).
    public mutating func deletePoint(_ index: Int) throws {
        try check(index)
        guard index > 0 else { throw refuse("The start point cannot be deleted (CharaStudio gives it no delete).") }
        points.remove(at: index)
    }

    /// The point guide's move. The start point only rotates.
    public mutating func movePoint(_ index: Int, to position: SIMD3<Float>) throws {
        try check(index)
        guard index > 0 else { throw refuse("The start point only rotates (its guide has no move).") }
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            throw refuse("A route point position must be finite.")
        }
        points[index].position = position
    }

    /// The start point guide's rotation (Unity Euler degrees).
    public mutating func rotateStart(to degrees: SIMD3<Float>) throws {
        guard !points.isEmpty else { throw refuse("The route has no start point.") }
        guard degrees.x.isFinite, degrees.y.isFinite, degrees.z.isFinite else { throw refuse("A rotation must be finite.") }
        points[0].rotationDegrees = degrees
    }

    /// The aid guide's move (Point-local). An aid's guide is active only
    /// for a curve connection.
    public mutating func moveAid(_ index: Int, to position: SIMD3<Float>) throws {
        try check(index)
        guard points[index].isCurve else { throw refuse("Only a curve point shows its aid (connection Curve).") }
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { throw refuse("An aid position must be finite.") }
        points[index].aidPosition = position
        points[index].aidInitialized = true
    }

    public mutating func setSpeed(_ index: Int, _ value: Float) throws {
        try check(index)
        guard value.isFinite else { throw refuse("A route point speed must be finite.") }
        points[index].speed = min(max(value, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    public mutating func setEase(_ index: Int, _ ease: SourceStudioRoute.EaseType) throws {
        try check(index)
        guard Self.easeChoices.contains(where: { $0.ease == ease }) else {
            throw refuse("CharaStudio's ease list offers linear, ease-in/out quad, ease-in/out quart and ease-out bounce only.")
        }
        points[index].easeType = ease.rawValue
    }

    /// `OCIRoutePoint.connection`: switching to `Curve` runs `InitAidPos`.
    public mutating func setConnection(_ index: Int, _ connection: SourceStudioRoute.Connection) throws {
        try check(index)
        points[index].connection = connection.rawValue
        guard connection == .curve, !points[index].aidInitialized else { return }
        let point = points[index]
        let next = index + 1 < points.count ? points[index + 1].position : points[0].position
        // Vector3.Lerp(position, b, 0.5f), then the point transform's
        // InverseTransformPoint (both in the route object's space).
        let middle = point.position + (next - point.position) * 0.5
        points[index].aidPosition = Self.inversePointTransform(point, middle)
        points[index].aidInitialized = true
    }

    public mutating func setLink(_ index: Int, _ linked: Bool) throws {
        try check(index)
        points[index].linked = linked
    }

    public mutating func setOrientation(_ orientation: SourceStudioRoute.Orientation) { self.orientation = orientation.rawValue }

    /// The colour palette keeps the line colour's alpha (`_useAlpha: false`).
    public mutating func setColor(red: Float, green: Float, blue: Float) throws {
        guard [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw refuse("A line colour component must be between 0 and 1.")
        }
        color = SIMD4(red, green, blue, color.w)
    }

    /// The point-local position of a route-local point: the inverse of the
    /// point's TRS with Unity's Z, X, Y Euler order (`InverseTransformPoint`).
    static func inversePointTransform(_ point: Point, _ routeLocal: SIMD3<Float>) -> SIMD3<Float> {
        var v = SIMD3<Double>(routeLocal) - SIMD3<Double>(point.position)
        let e = SIMD3<Double>(point.rotationDegrees) * .pi / 180
        // R = Ry · Rx · Rz, so R⁻¹ = Rz⁻¹ · Rx⁻¹ · Ry⁻¹ (undo Y first).
        var (c, s) = (cos(-e.y), sin(-e.y))
        v = SIMD3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z)
        (c, s) = (cos(-e.x), sin(-e.x))
        v = SIMD3(v.x, c * v.y - s * v.z, s * v.y + c * v.z)
        (c, s) = (cos(-e.z), sin(-e.z))
        v = SIMD3(c * v.x - s * v.y, s * v.x + c * v.y, v.z)
        return SIMD3<Float>(v / SIMD3<Double>(point.scale))
    }

    // MARK: Export validation

    /// Checks this state against the record it edits (the staged record: a
    /// copy's points are its template's) for edits CharaStudio cannot make,
    /// throwing the reason. Unchanged values always pass.
    public func validate(against record: KoikatsuRouteRecord) throws {
        func fail(_ reason: String) -> SourceSceneTopologyError { .unsupported(reason) }
        guard !record.points.isEmpty else { throw fail("Original-scene export does not edit a route record without points.") }
        guard let first = points.first, first.sourceIndex == 0 else {
            throw fail("A route keeps its start point first: CharaStudio cannot delete or replace it.")
        }
        var last = -1, sawAdded = false
        for (index, point) in points.enumerated() {
            if let source = point.sourceIndex {
                guard !sawAdded, source > last, record.points.indices.contains(source) else {
                    throw fail("Route points keep their saved order and every added point follows them: CharaStudio only appends points (route point \(index)).")
                }
                last = source
            } else {
                sawAdded = true
            }
        }
        if sawAdded, points.count > Self.pointLimit {
            throw fail("CharaStudio adds no point past \(Self.pointLimit) (the route point limit option); this route has \(points.count).")
        }
        for (index, point) in points.enumerated() {
            let saved = point.sourceIndex.map { record.points[$0] }
            let values = [point.position, point.rotationDegrees, point.scale, point.aidPosition, point.aidRotationDegrees, point.aidScale]
            guard values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }), point.speed.isFinite else {
                throw fail("Route point \(index) has a nonfinite value.")
            }
            let rotation = saved?.bone.transform.rotationDegrees ?? .zero, scale = saved?.bone.transform.scale ?? .one
            if index == 0 {
                guard bitEqual(point.position, saved!.bone.transform.position) else {
                    throw fail("The route's start point only rotates in CharaStudio (its guide has no move).")
                }
            } else if !bitEqual(point.rotationDegrees, rotation) {
                throw fail("Route point \(index) only moves in CharaStudio (its guide has no rotation).")
            }
            guard bitEqual(point.scale, scale) else { throw fail("Route points do not scale in CharaStudio (route point \(index)).") }
            guard bitEqual(point.aidRotationDegrees, saved?.aidTransform.rotationDegrees ?? .zero),
                  bitEqual(point.aidScale, saved?.aidTransform.scale ?? .one) else {
                throw fail("A route point aid only moves in CharaStudio (route point \(index)).")
            }
            if saved == nil, !point.aidInitialized, !bitEqual(point.aidPosition, Self.newAidPosition) {
                throw fail("An added point's aid starts at the prefab position until it is placed (route point \(index)).")
            }
            if saved?.aidInitialized == true, !point.aidInitialized {
                throw fail("CharaStudio never resets a placed aid (route point \(index)).")
            }
            if !point.aidInitialized, let saved, !bitEqual(point.aidPosition, saved.aidTransform.position) {
                throw fail("An aid that was never placed keeps its saved position (route point \(index)).")
            }
            guard let connection = SourceStudioRoute.Connection(rawValue: point.connection) else {
                throw fail("Route point \(index) has unknown connection \(point.connection).")
            }
            if connection == .curve, !point.aidInitialized {
                throw fail("A curve route point needs its aid placed (InitAidPos) (route point \(index)).")
            }
            if point.speed != saved?.speed ?? Self.newPointSpeed,
               !(point.speed > 0 && Self.speedRange.contains(point.speed)) {
                throw fail("Route point \(index) speed \(point.speed) is outside the speed control's \(Self.speedRange.lowerBound)...\(Self.speedRange.upperBound).")
            }
            if point.easeType != saved?.easeType ?? Self.newPointEase,
               !Self.easeChoices.contains(where: { $0.ease.rawValue == point.easeType }) {
                throw fail("Route point \(index) ease \(point.easeType) is not in CharaStudio's ease list.")
            }
        }
        guard SourceStudioRoute.Orientation(rawValue: orientation) != nil else {
            throw fail("Route orientation \(orientation) is not None, XY or Y.")
        }
        if !bitEqual(color, record.color) {
            guard (0..<3).allSatisfy({ color[$0].isFinite && (0...1).contains(color[$0]) }) else {
                throw fail("A route line colour component must be between 0 and 1.")
            }
            guard color.w.bitPattern == record.color.w.bitPattern else {
                throw fail("CharaStudio's line colour palette keeps the alpha (_useAlpha: false).")
            }
        }
    }
}

extension SourceStudioRouteState.Point {
    func record(pointKey: Int32, aidKey: Int32?) -> KoikatsuRoutePointRecord {
        KoikatsuRoutePointRecord(
            bone: KoikatsuBoneRecord(sourceKey: pointKey, transform: .init(position: position, rotationDegrees: rotationDegrees, scale: scale)),
            speed: speed, easeType: easeType, connection: connection, aidKey: aidKey,
            aidTransform: .init(position: aidPosition, rotationDegrees: aidRotationDegrees, scale: aidScale),
            aidInitialized: aidInitialized, linked: linked)
    }
}

private func bitEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
    a.x.bitPattern == b.x.bitPattern && a.y.bitPattern == b.y.bitPattern && a.z.bitPattern == b.z.bitPattern
}
private func bitEqual(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
    (0..<4).allSatisfy { a[$0].bitPattern == b[$0].bitPattern }
}

public extension SourceStudioRoute {
    /// The route's path as route-local Unity-space polyline vertices, for
    /// the editor's line: each line segment's two points and each curve
    /// segment sampled on its control polygon (`samples` per span) — the
    /// path the playback follows, not VectorLine's own spline. Empty for a
    /// route that cannot play.
    func polyline(samples: Int = 12) -> [SIMD3<Double>] {
        guard let segments = try? segments() else { return [] }
        var result: [SIMD3<Double>] = []
        for segment in segments {
            if segment.path.count == 2 {
                result += [segment.path[0], segment.path[1]]
                continue
            }
            let spans = max(1, (segment.path.count - 1) * samples)
            var previous = Self.interp(segment.controlPoints, 0)
            for step in 1...spans {
                let next = Self.interp(segment.controlPoints, Double(step) / Double(spans))
                result += [previous, next]; previous = next
            }
        }
        return result
    }
}
