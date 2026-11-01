import Testing
import Foundation
import simd
import Assets
import CoreMath
import Character
import Studio

// ST-A11 PR B: `Studio.CameraControl`'s vanish list, the capsule's overlap
// test and `VanishProc`'s state.

private typealias P = SIMD3<Double>

private func cube(_ half: P = P(1, 1, 1)) -> [P] {
    [-1.0, 1].flatMap { x in [-1.0, 1].flatMap { y in [-1.0, 1].map { z in P(x, y, z) * half } } }
}

@Test func convexDistanceMatchesBoxDistancesInClosedForm() {
    let box = cube()
    // Beside a face, an edge and a corner; through the box; a point.
    #expect(abs(SourceStudioConvexDistance.distance([P(3, 0, 0), P(3, 1, 0)], box) - 2) < 1e-9)
    #expect(abs(SourceStudioConvexDistance.distance([P(2, 2, -5), P(2, 2, 5)], box) - 2.0.squareRoot()) < 1e-9)
    #expect(abs(SourceStudioConvexDistance.distance([P(2, 3, 4), P(5, 5, 5)], box) - (1.0 + 4 + 9).squareRoot()) < 1e-9)
    #expect(SourceStudioConvexDistance.distance([P(-5, 0.2, 0.1), P(5, -0.3, 0.4)], box) == 0)
    #expect(abs(SourceStudioConvexDistance.distance([P(2, 3, 0)], box) - 5.0.squareRoot()) < 1e-9)
    #expect(SourceStudioConvexDistance.distance([P(0.5, 0.5, 0.5)], box) == 0)
    #expect(abs(SourceStudioConvexDistance.pointSegment(P(0, 1, 0), P(-1, 0, 0), P(1, 0, 0)) - 1) < 1e-12)
    // A hull that is not a box: the octahedron |x| + |y| + |z| <= 1 (its face x + y + z = 1 is 2 / sqrt 3 from (1, 1, 1)),
    // with an interior point that changes nothing.
    let octahedron = [P(1, 0, 0), P(-1, 0, 0), P(0, 1, 0), P(0, -1, 0), P(0, 0, 1), P(0, 0, -1), P(0.1, 0.1, 0.1)]
    #expect(abs(SourceStudioConvexDistance.distance([P(1, 1, 1), P(2, 2, 2)], octahedron) - 2 / 3.0.squareRoot()) < 1e-9)
    #expect(abs(SourceStudioConvexDistance.distance([P(2, 2, 0), P(2, 2, 3)], octahedron) - 3 / 2.0.squareRoot()) < 1e-9)
}

@Test func convexDistanceAgreesWithSampledDistancesToRotatedBoxes() {
    var generator = SystemRandomNumberGenerator()
    func random(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &generator) }
    for _ in 0..<200 {
        let half = P(random(0.05...2), random(0.05...2), random(0.05...2))
        let rotation = simd_quatd(angle: random(0...(2 * .pi)), axis: simd_normalize(P(random(-1...1), random(-1...1), random(-1...1)) + P(0, 0, 1e-3)))
        let offset = P(random(-2...2), random(-2...2), random(-2...2))
        let points = cube(half).map { rotation.act($0) + offset }
        let a = P(random(-4...4), random(-4...4), random(-4...4)), b = P(random(-4...4), random(-4...4), random(-4...4))
        // The exact point-to-box distance in the box's frame, sampled along the segment.
        func pointBox(_ p: P) -> Double {
            let local = rotation.inverse.act(p - offset)
            return simd_length(simd_max(simd_abs(local) - half, P.zero))
        }
        let samples = 4000
        let sampled = (0...samples).map { pointBox(a + (b - a) * (Double($0) / Double(samples))) }.min()!
        let gjk = SourceStudioConvexDistance.distance([a, b], points)
        #expect(gjk <= sampled + 1e-9)
        #expect(sampled - gjk <= simd_distance(a, b) / Double(samples) + 1e-9, "gjk \(gjk) sampled \(sampled)")
    }
}

private func vanishJSON(option: Bool = false) -> JSONValue {
    // Row 0 names two boxes (one active for sun type 0 only), row 1 one box in
    // scene space, row 2 an option box; every box is 1 m wide around its matrix's origin.
    let unit = "[[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[-0.5,0.5,-0.5],[0.5,0.5,-0.5],[-0.5,-0.5,0.5],[0.5,-0.5,0.5],[-0.5,0.5,0.5],[0.5,0.5,0.5]]"
    func matrix(_ x: Double, _ y: Double, _ z: Double) -> String { "[1,0,0,0,0,1,0,0,0,0,1,0,\(x),\(y),\(z),1]" }
    let text = """
    {"ikkokuVanish": {"kind": "ikkoku.studioMapVanish", "version": 1, "radius": 0.05, "delaySeconds": 0.3, "mapLayer": 11,
     "rows": [{"collider": "wall", "colliders": [0, 1]}, {"collider": "desk", "colliders": [2]}, {"collider": "extra", "colliders": [3]},
              {"collider": "none", "colliders": []}],
     "colliders": [
      {"name": "wall", "role": "mapRoot", "visibleFor": [0, 1], "option": false, "shape": 0, "matrix": \(matrix(0, 0, 5))},
      {"name": "wall", "role": "mapRoot", "visibleFor": [0], "option": false, "shape": 0, "matrix": \(matrix(3, 0, 5))},
      {"name": "desk", "role": "scene", "visibleFor": [0, 1], "option": false, "shape": 0, "matrix": \(matrix(0, 0, 2))},
      {"name": "extra", "role": "mapRoot", "visibleFor": [0, 1], "option": \(option), "shape": 0, "matrix": \(matrix(-3, 0, 5))}],
     "shapes": [{"type": "box", "points": \(unit)}]}}
    """
    return try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Test func vanishRowsAreTouchedByTheCapsuleBetweenCameraAndPivot() throws {
    let vanish = try #require(try SourceStudioMapVanish.parse(vanishJSON(option: true), label: "map.gltf"))
    #expect(vanish.rows.map(\.collider) == ["wall", "desk", "extra", "none"] && vanish.colliders.count == 4)
    #expect(vanish.radius == 0.05 && vanish.delaySeconds == 0.3)
    func touched(_ camera: P, _ pivot: P, sun: Int32 = 0, option: Bool = true, root: simd_double4x4 = matrix_identity_double4x4,
                 model: SourceStudioMapVanish.CapsuleModel = .segment) -> [Bool] {
        vanish.touchedRows(camera: camera, pivot: pivot, mapRoot: root, sunTypeKey: sun, mapOption: option, model: model)
    }
    // The view from z = 10 to the pivot at the origin passes the wall (z 4.5...5.5) and the desk (z 1.5...2.5).
    #expect(touched(P(0, 0, 10), .zero) == [true, true, false, false])
    // A pivot short of the desk: only the wall; a camera inside the desk box touches it.
    #expect(touched(P(0, 0, 10), P(0, 0, 3)) == [true, false, false, false])
    #expect(touched(P(0, 0, 2), P(0, 0, 0)) == [false, true, false, false])
    // The second wall box is active for sun type 0 only; the option box only with mapOption.
    #expect(touched(P(3, 0, 10), P(3, 0, 0), sun: 0) == [true, false, false, false])
    #expect(touched(P(3, 0, 10), P(3, 0, 0), sun: 1) == [false, false, false, false])
    #expect(touched(P(-3, 0, 10), P(-3, 0, 0), option: true) == [false, false, true, false])
    #expect(touched(P(-3, 0, 10), P(-3, 0, 0), option: false) == [false, false, false, false])
    // The radius reaches 0.05 past a face; the capsule's caps end at the camera and the pivot.
    #expect(touched(P(0.54, 0, 10), P(0.54, 0, 0)) == [true, true, false, false])
    #expect(touched(P(0.56, 0, 10), P(0.56, 0, 0)) == [false, false, false, false])
    #expect(touched(P(0, 0, 10), P(0, 0, 5.46)) == [true, false, false, false])
    #expect(touched(P(0, 0, 10), P(0, 0, 5.54)) == [false, false, false, false])
    // The midpoint sphere: only what holds the point halfway (z 5 here).
    #expect(touched(P(0, 0, 10), .zero, model: .midpointSphere) == [true, false, false, false])
    #expect(touched(P(0, 0, 8), P(0, 0, -4), model: .midpointSphere) == [false, true, false, false])
    // The map transform moves mapRoot colliders, not scene ones: shifted by x = 3, the view at x = 3 meets
    // the first wall (the second one, now at x = 6, is missed), and the view at x = 0 the desk and the
    // option box, now there.
    let shifted = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(3, 0, 0, 1)))
    #expect(touched(P(3, 0, 10), P(3, 0, 0), root: shifted) == [true, false, false, false])
    #expect(touched(P(0, 0, 10), .zero, root: shifted) == [false, true, true, false])
}

@Test func vanishListsThatCannotBeReadAreRefusedByName() throws {
    #expect(try SourceStudioMapVanish.parse(nil, label: "m") == nil)
    func refusal(_ text: String) -> String? {
        do { _ = try SourceStudioMapVanish.parse(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), label: "m.gltf"); return nil }
        catch { return "\(error)" }
    }
    let head = #"{"ikkokuVanish": {"kind": "ikkoku.studioMapVanish", "version": 1, "radius": 0.05, "delaySeconds": 0.3, "#
    #expect(refusal(#"{"ikkokuVanish": {"kind": "other", "version": 1}}"#)?.contains("not a version 1") == true)
    #expect(refusal(head + #""shapes": [{"type": "sphere", "points": [[0,0,0]]}]}}"#)?.contains("not a box or convex mesh") == true)
    #expect(refusal(head + #""shapes": [{"type": "box", "points": [[0,0]]}]}}"#)?.contains("has no points") == true)
    #expect(refusal(head + #""shapes": [{"type": "box", "points": [[0,0,0]]}], "colliders": [{"name": "a", "role": "mapRoot", "shape": 1, "matrix": [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}]}}"#)?
        .contains("collider 0 has no name, role, shape or matrix") == true)
    #expect(refusal(head + #""shapes": [{"type": "box", "points": [[0,0,0]]}], "colliders": [{"name": "a", "role": "scene", "shape": 0, "matrix": [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}], "rows": [{"collider": "b", "colliders": [0]}]}}"#)?
        .contains("row 0 names a collider that is not one of b") == true)
}

@Test func vanishStateFollowsVanishProcRowByRow() {
    // Sets: 0 = row 0 only, 1 = rows 0 and 1 (a renderer both rows hide), 2 = row 1 only.
    var state = SourceStudioMapVanishState(rows: 2, sets: [[0], [0, 1], [1]], delaySeconds: 0.3)
    #expect(state.setEnabled == [true, true, true] && state.secondsToNextShow == nil)
    // Touched: hidden at once.
    let step1 = state.update(touched: [true, false], time: 0)
    #expect(step1)
    #expect(state.setEnabled == [false, false, true] && state.rowVisible == [false, true])
    // Untouched for 0.2 s: still hidden, 0.1 s to go.
    let step2 = state.update(touched: [false, false], time: 1)
    #expect(!step2)
    let step3 = state.update(touched: [false, false], time: 1.2)
    #expect(!step3)
    #expect(abs(state.secondsToNextShow! - 0.1) < 1e-9)
    // Touched again: a hidden row does not act, and its delay is not reset (only a hide resets it).
    let step4 = state.update(touched: [true, false], time: 1.25)
    #expect(!step4)
    let step5 = state.update(touched: [false, false], time: 2)
    #expect(!step5)
    #expect(state.setEnabled == [false, false, true] && abs(state.secondsToNextShow! - 0.05) < 1e-9)
    let step6 = state.update(touched: [false, false], time: 2.1)
    #expect(step6)
    #expect(state.setEnabled == [true, true, true] && state.secondsToNextShow == nil)

    // Order: row 1 hides the shared renderer while row 0 is hidden too; row 0's show
    // re-enables it although row 1 still touches (VanishProc does not look at other rows).
    var shared = SourceStudioMapVanishState(rows: 2, sets: [[0], [0, 1], [1]], delaySeconds: 0.3)
    shared.update(touched: [true, false], time: 0)
    shared.update(touched: [true, true], time: 0.1)
    #expect(shared.setEnabled == [false, false, false])
    shared.update(touched: [false, true], time: 0.2)
    shared.update(touched: [false, true], time: 0.6)
    #expect(shared.setEnabled == [true, true, false] && shared.rowVisible == [true, false])
    // A frame's own step: VanishProc adds the frame time before comparing.
    var frames = SourceStudioMapVanishState(rows: 1, sets: [[0]], delaySeconds: 0.3)
    frames.frame(touched: [true], deltaTime: 0.035)
    for _ in 0..<8 { frames.frame(touched: [false], deltaTime: 0.035) }
    #expect(frames.setEnabled == [false])
    frames.frame(touched: [false], deltaTime: 0.035)
    #expect(frames.setEnabled == [true])
}
