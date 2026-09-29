import Foundation
import Testing
import simd
import CoreMath
import Scene
@testable import Studio

/// Compares `SourceStudioRouteStepper` against `Tools/reverse/analysis/
/// studio_route_reference.py`'s `simulate_frames` (record-after-update order)
/// stepped over the fixture's own irregular frame deltas, in
/// Fixtures/route-stepping.json. The expected values are a ported reference,
/// not an original CharaStudio run; tolerance is the fixture's own (1e-5).
/// Fixture frame `k` is what frame `k`'s tween update left on `childRoot`, so
/// it matches the `Sample` returned by the `k`-th `step(deltaTime:)`.
private struct FixtureRoute: Decodable {
    struct Point: Decodable {
        let position: [Double], aid: [Double]?, connection: String, link: Bool
        let speed: Double, easeType: String
    }
    struct Aim: Decodable { let axis: String, lookTarget: [Double], rotation: [Double]? }
    struct Frame: Decodable { let position: [Double], active: Bool, aim: Aim? }
    let points: [Point], loop: Bool, orient: String
    let deltas: [Double], frames: [Frame]
}

private struct Fixture: Decodable {
    let note: String, tolerance: Double
    let routes: [String: FixtureRoute]
}

private struct FixtureProblem: Error { let message: String }

private func loadFixture() throws -> Fixture {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/route-stepping.json")
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

private func stepper(_ fixture: FixtureRoute) throws -> SourceStudioRouteStepper {
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
    return try SourceStudioRouteStepper(points: points, loop: fixture.loop, orientation: orientation)
}

private func approximately(_ lhs: SIMD3<Double>, _ rhs: [Double], _ tolerance: Double) -> Bool {
    rhs.count == 3 && abs(lhs.x - rhs[0]) < tolerance
        && abs(lhs.y - rhs[1]) < tolerance && abs(lhs.z - rhs[2]) < tolerance
}

@Test("every fixture route steps frame for frame with the reference simulator")
func stepperMatchesTheSteppingFixture() throws {
    let fixture = try loadFixture()
    try #require(fixture.routes.count == 2)
    let tolerance = fixture.tolerance
    for (name, fixtureRoute) in fixture.routes.sorted(by: { $0.key < $1.key }) {
        try #require(fixtureRoute.frames.count == fixtureRoute.deltas.count)
        var stepper = try stepper(fixtureRoute)
        // `Play` places childRoot at point 0 and aims (when oriented) before
        // any frame runs; the fixture's first frame re-applies percentage 0.
        let play = stepper.current()
        #expect(approximately(play.position, fixtureRoute.frames[0].position, tolerance))
        #expect(play.active)
        for (index, frame) in fixtureRoute.frames.enumerated() {
            let context: Comment = "\(name)@frame\(index)"
            let stepped = try stepper.step(deltaTime: fixtureRoute.deltas[index])
            for (got, want) in zip([stepped.position.x, stepped.position.y, stepped.position.z], frame.position) {
                #expect(abs(got - want) < tolerance, context)
            }
            #expect(stepped.active == frame.active, context)
            if let aim = frame.aim {
                let gotAim = try #require(stepped.aim, context)
                #expect(String(describing: gotAim.axis) == aim.axis, context)
                for (got, want) in zip([gotAim.lookTarget.x, gotAim.lookTarget.y, gotAim.lookTarget.z], aim.lookTarget) {
                    #expect(abs(got - want) < tolerance, context)
                }
                if let rotation = aim.rotation {
                    let quaternion = try #require(gotAim.rotation, context)
                    // The fixture stores the reference quaternion as (w, x, y, z).
                    let components = [quaternion.vector.w, quaternion.vector.x,
                                      quaternion.vector.y, quaternion.vector.z]
                    for (got, want) in zip(components, rotation) {
                        #expect(abs(Double(got) - want) < tolerance, context)
                    }
                } else {
                    #expect(gotAim.rotation == nil, context)
                }
            } else {
                #expect(stepped.aim == nil, context)
            }
        }
    }
}

@Test("the last fixture frame of the completing route holds its end placement")
func completionHoldPersistsAcrossFurtherSteps() throws {
    let fixture = try loadFixture()
    let fixtureRoute = try #require(fixture.routes["stepping-curves-no-loop"])
    let tolerance = fixture.tolerance
    var stepper = try stepper(fixtureRoute)
    for delta in fixtureRoute.deltas { _ = try stepper.step(deltaTime: delta) }
    let held = stepper.current()
    let lastFrame = try #require(fixtureRoute.frames.last)
    #expect(approximately(held.position, lastFrame.position, tolerance))
    #expect(!held.active)
    // The tween stopped: further frames change nothing, not even after a
    // zero-length frame or a huge one.
    for delta in [0.0, 10.0, fixtureRoute.deltas.first ?? 0.1] {
        let after = try stepper.step(deltaTime: delta)
        #expect(after == held, "delta \(delta)")
    }
}

@Test("stepping reports invalid deltaTimes without changing the state")
func invalidDeltaTimesAreReported() throws {
    let fixture = try loadFixture()
    var stepper = try stepper(try #require(fixture.routes["stepping-line-loop"]))
    let before = stepper.current()
    for delta in [-0.1, .nan, .infinity] {
        #expect(throws: (any Error).self) {
            _ = try stepper.step(deltaTime: delta)
        }
        #expect(stepper.current() == before)
    }
    // A zero-length frame is valid and replays the current percentage.
    _ = try stepper.step(deltaTime: 0)
    #expect(stepper.current() == before)
}
