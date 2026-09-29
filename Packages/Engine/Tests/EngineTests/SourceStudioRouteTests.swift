import Foundation
import Testing
import simd
import CoreMath
import Scene
@testable import Studio

/// Compares `SourceStudioRoute` against `Tools/reverse/analysis/
/// studio_route_reference.py` sampled into Fixtures/route-reference.json.
/// The expected values are a ported reference, not an original CharaStudio
/// run; tolerance is the fixture's own (1e-5).
private struct FixtureRoute: Decodable {
    struct Point: Decodable {
        let position: [Double], aid: [Double]?, connection: String, link: Bool
        let speed: Double, easeType: String
    }
    struct Aim: Decodable { let axis: String, lookTarget: [Double], rotation: [Double]? }
    struct Sample: Decodable {
        let position: [Double], segmentIndex: Int, finished: Bool, orientation: Aim?
    }
    let points: [Point], loop: Bool, orient: String
    let samples: [String: Sample]
}

private struct Fixture: Decodable {
    let note: String, tolerance: Double
    let routes: [String: FixtureRoute]
}

private func loadFixture() throws -> Fixture {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/route-reference.json")
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
}

private func vector3(_ values: [Double]) throws -> SIMD3<Double> {
    try #require(values.count == 3)
    return SIMD3(values[0], values[1], values[2])
}

private func easeType(_ name: String) throws -> SourceStudioRoute.EaseType {
    let all = Dictionary(uniqueKeysWithValues: SourceStudioRoute.EaseType.allCases.map { (String(describing: $0), $0) })
    return try #require(all[name])
}

private func studioRoute(_ fixture: FixtureRoute) throws -> SourceStudioRoute {
    var points: [SourceStudioRoute.Point] = []
    for point in fixture.points {
        let connection: SourceStudioRoute.Connection = switch point.connection {
        case "line": .line
        case "curve": .curve
        default: throw FixtureProblem(message: "unknown fixture connection \(point.connection)")
        }
        points.append(.init(position: try vector3(point.position), aid: try point.aid.map(vector3),
                            connection: connection, linked: point.link, speed: point.speed,
                            easeType: try easeType(point.easeType)))
    }
    let orientation: SourceStudioRoute.Orientation = switch fixture.orient {
    case "none": .none
    case "xy": .xy
    case "y": .y
    default: throw FixtureProblem(message: "unknown fixture orient \(fixture.orient)")
    }
    return SourceStudioRoute(points: points, loop: fixture.loop, orientation: orientation)
}

private struct FixtureProblem: Error { let message: String }

@Test("every fixture route sample matches the Swift evaluator")
func sourceStudioRouteMatchesTheReferenceFixture() throws {
    let fixture = try loadFixture()
    try #require(fixture.routes.count == 41)
    let tolerance = fixture.tolerance
    for (name, fixtureRoute) in fixture.routes.sorted(by: { $0.key < $1.key }) {
        let route = try studioRoute(fixtureRoute)
        let segments = try route.segments()
        try #require(!segments.isEmpty)
        for (stamp, expected) in fixtureRoute.samples.sorted(by: { Double($0.key)! < Double($1.key)! }) {
            let sample = try route.evaluate(at: Double(stamp)!)
            let context: Comment = "\(name)@\(stamp)"
            for (got, want) in zip([sample.position.x, sample.position.y, sample.position.z], expected.position) {
                #expect(abs(got - want) < tolerance, context)
            }
            #expect(sample.segmentIndex == expected.segmentIndex, context)
            #expect(sample.finished == expected.finished, context)
            if let aim = expected.orientation {
                let gotAim = try #require(sample.aim, context)
                #expect(String(describing: gotAim.axis) == aim.axis, context)
                for (got, want) in zip([gotAim.lookTarget.x, gotAim.lookTarget.y, gotAim.lookTarget.z], aim.lookTarget) {
                    #expect(abs(got - want) < tolerance, context)
                }
                if let rotation = aim.rotation {
                    let quaternion = try #require(gotAim.rotation, context)
                    let components = [quaternion.vector.w, quaternion.vector.x,
                                      quaternion.vector.y, quaternion.vector.z]
                    for (got, want) in zip(components, rotation) {
                        #expect(abs(Double(got) - want) < tolerance, context)
                    }
                } else {
                    #expect(gotAim.rotation == nil, context)
                }
            } else {
                #expect(sample.aim == nil, context)
            }
        }
    }
}

@Test("unplayable routes return a diagnostic instead of a guess")
func sourceStudioRouteValidation() throws {
    func point(_ position: SIMD3<Double>, aid: SIMD3<Double>? = nil,
               connection: SourceStudioRoute.Connection = .line, linked: Bool = false,
               speed: Double = 2) -> SourceStudioRoute.Point {
        .init(position: position, aid: aid, connection: connection, linked: linked, speed: speed)
    }
    func fails(_ points: [SourceStudioRoute.Point], loop: Bool = true) {
        #expect(throws: RigError.self) { try SourceStudioRoute(points: points, loop: loop).segments() }
    }
    fails([])
    fails([point([0, 0, 0])])
    fails([point([0, 0, 0], speed: 0), point([2, 0, 0])])
    fails([point([0, 0, 0], speed: -1), point([2, 0, 0])])
    fails([point([0, 0, 0], speed: .infinity), point([2, 0, 0])])
    fails([point([.nan, 0, 0]), point([2, 0, 0])])
    fails([point([0, 0, 0], connection: .curve), point([2, 0, 0])])
    fails([point([0, 0, 0], aid: [0, .infinity, 0], connection: .curve), point([2, 0, 0])])
    // A zero-length path has no playable duration.
    fails([point([1, 1, 1]), point([1, 1, 1])], loop: false)

    let playable = SourceStudioRoute(points: [point([0, 0, 0]), point([2, 0, 0])])
    #expect(throws: RigError.self) { try playable.evaluate(at: -0.5) }
    #expect(throws: RigError.self) { try playable.evaluate(at: .nan) }
    #expect(throws: RigError.self) { try playable.evaluate(at: .infinity) }

    // Unknown enum ordinals from a decoded record become diagnostics.
    #expect(SourceStudioRoute.Connection(rawValue: 5) == nil)
    #expect(SourceStudioRoute.EaseType(rawValue: 99) == nil)
    #expect(SourceStudioRoute.Orientation(rawValue: 3) == nil)
}

@Test("oversized routes and control polygons return diagnostics before path sampling")
func sourceStudioRouteBounds() throws {
    func diagnostic(_ route: SourceStudioRoute) -> String {
        do {
            _ = try route.segments()
            return "no diagnostic"
        } catch let error as RigError {
            return error.description
        } catch {
            return String(describing: error)
        }
    }
    let line = SourceStudioRoute.Point(position: [0, 0, 0])
    let oversized = SourceStudioRoute(points: Array(repeating: line, count: 1_025))
    #expect(diagnostic(oversized).contains("maximum is 1024"))
    #expect(throws: RigError.self) { try oversized.evaluate(at: 0) }

    // 1,024 linked Curve points need 2,049 path points once the closing
    // position is added, exceeding the per-segment limit.
    let curve = SourceStudioRoute.Point(position: [0, 0, 0], aid: [1, 0, 0],
                                        connection: .curve, linked: true)
    let longCurve = SourceStudioRoute(points: Array(repeating: curve, count: 1_024))
    #expect(diagnostic(longCurve).contains("exceeds 2048 control polygon points"))
}

@Test("the record bridge ignores Line aid data and rejects unknown ordinals")
func sourceStudioRouteRecordBridge() throws {
    func amount(_ position: SIMD3<Float>) -> KoikatsuChangeAmount {
        .init(position: position, rotationDegrees: .zero, scale: .one)
    }
    func routePoint(_ position: SIMD3<Float>, speed: Float = 2, easeType: Int32 = 21,
                    connection: Int32 = 0, aid: KoikatsuBoneRecord? = nil,
                    aidInitialized: Bool = false, linked: Bool = false) -> KoikatsuRoutePointRecord {
        .init(bone: .init(sourceKey: 1, transform: amount(position)), speed: speed, easeType: easeType,
              connection: connection, aid: aid ?? .init(sourceKey: 0, transform: amount(.zero)),
              aidInitialized: aidInitialized, linked: linked)
    }
    let record = KoikatsuRouteRecord(points: [routePoint([0, 0, 0]), routePoint([2, 0, 0])],
                                     active: true, loop: false, visibleLine: true, orientation: 1,
                                     color: .one)
    let route = try SourceStudioRoute(record: record)
    #expect(route.points.count == 2)
    #expect(route.points[0].position == [0, 0, 0])
    #expect(route.points[1].speed == 2)
    #expect(route.points[0].easeType == .linear)
    #expect(route.loop == false)
    #expect(route.orientation == .xy)

    // Records carry an aid object for Line points; it must not bend or
    // invalidate the straight segment, even when marked initialized.
    let lineWithAid = KoikatsuRouteRecord(
        points: [routePoint([0, 0, 0], aid: .init(sourceKey: 2, transform: amount([100, 50, 0])),
                            aidInitialized: true), routePoint([2, 0, 0])],
        active: true, loop: false, visibleLine: true, orientation: 0, color: .one)
    let straight = try SourceStudioRoute(record: lineWithAid)
    #expect(straight.points[0].aid == nil)
    #expect(try straight.evaluate(at: 1.5).position == [1, 0, 0])

    func recordFails(_ points: [KoikatsuRoutePointRecord], orientation: Int32 = 0) {
        #expect(throws: RigError.self) {
            try SourceStudioRoute(record: .init(points: points, active: true, loop: true,
                                                visibleLine: false, orientation: orientation, color: .one)).segments()
        }
    }
    recordFails([routePoint([0, 0, 0], connection: 5), routePoint([2, 0, 0])])
    recordFails([routePoint([0, 0, 0], easeType: 99), routePoint([2, 0, 0])])
    recordFails([routePoint([0, 0, 0]), routePoint([2, 0, 0])], orientation: 7)
    recordFails(Array(repeating: routePoint([0, 0, 0]), count: 1_025))
    // A curve point whose aid target was never initialised is unplayable.
    recordFails([routePoint([0, 0, 0], connection: 1, aidInitialized: false), routePoint([2, 0, 0])])
}

@Test("the record bridge composes curve aids through the point's local transform")
func sourceStudioRouteRecordAidFrame() throws {
    func curvePoint(_ position: SIMD3<Float>, rotationDegrees: SIMD3<Float>, aid: SIMD3<Float>,
                    sourceKey: Int32) -> KoikatsuRoutePointRecord {
        .init(bone: .init(sourceKey: 1,
                          transform: .init(position: position, rotationDegrees: rotationDegrees, scale: .one)),
              speed: 2, easeType: 21, connection: 1,
              aid: .init(sourceKey: sourceKey,
                         transform: .init(position: aid, rotationDegrees: .zero, scale: .one)),
              aidInitialized: true, linked: false)
    }
    func maxDifference(_ actual: SIMD3<Double>?, _ expected: SIMD3<Double>) throws -> Double {
        let aid = try #require(actual)
        return max(max(abs(aid.x - expected.x), abs(aid.y - expected.y)), abs(aid.z - expected.z))
    }
    // Route IKKOKU-B points dicKey 8 and 12 as captured from the original:
    // the serialized aid is Point-local under a point rotated -15° about Y,
    // and the original's route-local aid is the point composed with that
    // rotated local offset (verified against the captured playback).
    let record = KoikatsuRouteRecord(
        points: [curvePoint([0.8, 0.2, 0.6], rotationDegrees: [0, -15, 0],
                            aid: [-0.2683783, 0.675, -0.3895974], sourceKey: 8),
                 curvePoint([-0.4, 0.55, 0.3], rotationDegrees: [0, -15, 0],
                            aid: [-0.3001803, -0.02500004, -0.5407326], sourceKey: 12),
                 // An unrotated point keeps the plain point + aid sum.
                 curvePoint([1, 2, 3], rotationDegrees: [0, 0, 0],
                            aid: [0.5, -0.25, 2], sourceKey: 16)],
        active: true, loop: true, visibleLine: true, orientation: 0, color: .one)
    let route = try SourceStudioRoute(record: record)
    #expect(try maxDifference(route.points[0].aid, [0.6416017, 0.875, 0.1542164]) < 1e-6)
    #expect(try maxDifference(route.points[1].aid, [-0.55, 0.525, -0.2999999]) < 1e-6)
    #expect(try maxDifference(route.points[2].aid, [1.5, 1.75, 5]) < 1e-12)
}

@Test("the PathLength double-padding quirk drives durations and endpoints")
func sourceStudioRouteDurationQuirkAndEndpoints() throws {
    func point(_ position: SIMD3<Double>, speed: Double = 2) -> SourceStudioRoute.Point {
        .init(position: position, speed: speed)
    }
    let loopRoute = SourceStudioRoute(points: [point([0, 0, 0]), point([2, 0, 0]), point([2, 2, 0])])
    let durations = try loopRoute.segments().map(\.duration)
    // A 2-unit straight segment times at 3x its geometric length at speed 2.
    #expect(abs(durations[0] - 3.0) < 1e-5)
    #expect(abs(durations[1] - 3.0) < 1e-5)
    let total = durations.reduce(0, +)
    #expect(abs(total - (6.0 + 3.0 * 2.0.squareRoot())) < 1e-5)
    // Loop wrap: the same phase after a full cycle (within float noise).
    let wrapped = try loopRoute.evaluate(at: 8.0 + total)
    let direct = try loopRoute.evaluate(at: 8.0)
    #expect(abs(wrapped.position.x - direct.position.x) < 1e-5)
    #expect(!wrapped.finished)

    // Speed 4 makes each straight segment 1.5 s: boundaries at 1.5 and 3.0.
    let route = SourceStudioRoute(points: [point([0, 0, 0], speed: 4), point([2, 0, 0], speed: 4),
                                           point([2, 2, 0], speed: 4)], loop: false)
    let third = try route.evaluate(at: 2.0)
    #expect(third.segmentIndex == 1)
    #expect(abs(third.position.y - 2.0 / 3.0) < 1e-5)
    let middle = try route.evaluate(at: 2.25)
    #expect(abs(middle.position.y - 1.0) < 1e-5)
    #expect(!middle.finished)
    let end = try route.evaluate(at: 3.0)
    #expect(end.finished)
    #expect(end.position == [2, 2, 0])
    let past = try route.evaluate(at: 9.0)
    #expect(past.position == end.position)
    #expect(past.segmentIndex == end.segmentIndex)
}

@Test("each easing reaches its end at the segment time, expo short by design")
func sourceStudioRouteEaseEndpoints() throws {
    let shortAtEnd: [SourceStudioRoute.EaseType: Double] = [
        .easeOutExpo: pow(2.0, -10), .easeInOutExpo: pow(2.0, -11),
    ]
    for ease in SourceStudioRoute.EaseType.allCases {
        // Speed 6 on a two-point segment runs the padded 6-unit path in 1.0 s.
        let route = SourceStudioRoute(points: [
            .init(position: [0, 0, 0], speed: 6, easeType: ease),
            .init(position: [2, 0, 0], speed: 6, easeType: ease),
        ], loop: false)
        let segments = try route.segments()
        let segment = try #require(segments.first)
        #expect(abs(segment.duration - 1.0) < 1e-5, "\(ease)")
        let evaluation = try route.evaluate(at: segment.duration)
        #expect(evaluation.segmentIndex == 0, "\(ease)")
        let expected = 2.0 * (1.0 - (shortAtEnd[ease] ?? 0.0))
        #expect(abs(evaluation.position.x - expected) < 1e-5, "\(ease)")
    }
}

@Test("orient-to-path aims at the lookahead sample")
func sourceStudioRouteOrientation() throws {
    let route = SourceStudioRoute(
        points: [.init(position: [0, 0, 0]), .init(position: [2, 1, 2])],
        orientation: .y)
    let sample = try route.evaluate(at: 0.5)
    // The (2,1,2) straight segment times at 3x its 3-unit length at speed 2:
    // 4.5 s. Lookahead adds Defaults.lookAhead 0.05 to the percentage.
    let fraction = min(1.0, 0.5 / 4.5 + SourceStudioRoute.lookAhead)
    let aim = try #require(sample.aim)
    #expect(aim.axis == .y)
    #expect(abs(aim.lookTarget.x - 2.0 * fraction) < 1e-5)
    #expect(abs(aim.lookTarget.y - 1.0 * fraction) < 1e-5)
    // Horizontal aim along (1, 0, 1): +45 degrees about Y, w = cos(22.5 deg).
    let quaternion = try #require(aim.rotation)
    #expect(abs(quaternion.vector.w - Float(0.9238795325112867)) < 1e-5)
    #expect(abs(quaternion.vector.y - Float(0.3826834323650897)) < 1e-5)
    #expect(abs(quaternion.vector.x) < 1e-5)
    #expect(abs(quaternion.vector.z) < 1e-5)

    // axis "y" zeroes x/z; a straight-up lookahead target gives no yaw.
    let straightUp = SourceStudioRoute(points: [.init(position: [0, 0, 0]), .init(position: [0, 2, 0])],
                                       orientation: .y)
    let up = try straightUp.evaluate(at: 0.5)
    #expect(try #require(up.aim).rotation == nil)

    let silent = SourceStudioRoute(points: [.init(position: [0, 0, 0]), .init(position: [2, 1, 2])])
    #expect(try silent.evaluate(at: 0.5).aim == nil)
}
