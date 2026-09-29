import Foundation
import simd
import Testing
import Scene
@testable import Studio

// Fixture written by Tools/reverse/analysis/eye_look_reference.py --fixture
// from its pure EyeUpdateCalc reference; all inputs and outputs are SYNTHETIC
// (hand-picked numbers, no original-game capture data), every quaternion is
// Unity x,y,z,w, and each expectation matches within 1e-5 degrees for angles
// and 1e-6 for quaternion / direction components.

private let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures/eye-look-reference.json")

private func fixtureJSON() throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
}

private func settingsData(_ fixture: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: try #require(fixture["settings"] as? [String: Any]))
}

private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? .nan }

private func components(_ value: Any?) -> [Double]? {
    guard let rows = value as? [Any] else { return nil }
    let values = rows.map { ($0 as? NSNumber)?.doubleValue }
    return values.contains(where: { $0 == nil }) ? nil : values.compactMap { $0 }
}

private func vector3(_ value: Any?, _ what: String) throws -> SIMD3<Double> {
    guard let values = components(value), values.count == 3 else {
        throw RigError.invalid("Fixture \(what) must be an xyz triple.")
    }
    return SIMD3<Double>(values[0], values[1], values[2])
}

private func quaternion(_ value: Any?, _ what: String) throws -> simd_quatd {
    guard let values = components(value), values.count == 4 else {
        throw RigError.invalid("Fixture \(what) must be an xyzw quaternion.")
    }
    return simd_quatd(ix: values[0], iy: values[1], iz: values[2], r: values[3])
}

private func expectClose(_ a: Double, _ b: Double, tolerance: Double, _ context: String) {
    #expect(abs(a - b) <= tolerance, "\(context): \(a) vs \(b)")
}

private func expectClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tolerance: Double, _ context: String) {
    for (x, y) in zip([a.x, a.y, a.z], [b.x, b.y, b.z]) {
        #expect(abs(x - y) <= tolerance, "\(context): \(a) vs \(b)")
    }
}

private func expectClose(_ a: simd_quatd, _ b: simd_quatd, tolerance: Double, _ context: String) {
    for (x, y) in zip([a.imag.x, a.imag.y, a.imag.z, a.real], [b.imag.x, b.imag.y, b.imag.z, b.real]) {
        #expect(abs(x - y) <= tolerance, "\(context): \(a) vs \(b)")
    }
}

private func eyeStates(_ value: Any?, _ context: String) throws -> [SourceStudioEyeState] {
    let rows = try #require((value as? [String: Any])?["eyes"] as? [Any], "\(context) eyes")
    return try rows.map { row in
        let entry = try #require(row as? [String: Any], "\(context) eye row")
        return SourceStudioEyeState(angleH: number(entry["angleH"]), angleV: number(entry["angleV"]),
                                    dirUp: try vector3(entry["dirUp"], "start dirUp"))
    }
}

private func eyeGeometry(_ value: Any?, _ context: String) throws -> SourceStudioEyeLookGeometry {
    let record = try #require(value as? [String: Any], "\(context)")
    func node(_ key: String) throws -> SourceStudioEyeLookGeometry.Node {
        let row = try #require(record[key] as? [String: Any], "\(context) \(key)")
        return SourceStudioEyeLookGeometry.Node(position: try vector3(row["position"], "\(key) position"),
                                                rotation: try quaternion(row["rotation"], "\(key) rotation"),
                                                lossyScale: try vector3(row["lossyScale"], "\(key) lossyScale"))
    }
    let rows = try #require(record["eyes"] as? [Any], "\(context) eyes")
    let eyes = try rows.map { row -> SourceStudioEyeLookGeometry.Eye in
        let entry = try #require(row as? [String: Any], "\(context) eye row")
        return SourceStudioEyeLookGeometry.Eye(worldPosition: try vector3(entry["worldPosition"], "eye position"),
                                               origRotation: try quaternion(entry["origRotation"], "eye orig"),
                                               referenceLookDir: try vector3(entry["referenceLookDir"], "eye look"),
                                               referenceUpDir: try vector3(entry["referenceUpDir"], "eye up"))
    }
    return SourceStudioEyeLookGeometry(rootNode: try node("rootNode"), trfCenter: try node("trfCenter"), eyes: eyes)
}

/// Replay every synthetic sequence frame by frame through the solver: the
/// predicted eye local rotations, the carried per-eye state and the
/// frame-local sorasi num5 must match the reference to 1e-5 deg / 1e-6.
@Test func studioEyeLookSequencesReplayReferenceFixture() throws {
    let fixture = try fixtureJSON()
    let settings = try SourceStudioEyeLookSettings(json: try settingsData(fixture))
    let rows = try #require(fixture["sequences"] as? [Any])
    #expect(rows.count >= 20)
    var zeroDtRows = 0, awayRows = 0
    for row in rows {
        let sequence = try #require(row as? [String: Any])
        let name = (sequence["name"] as? String) ?? "?"
        let pattern = Int(number(sequence["pattern"]))
        var solver = try SourceStudioEyeLookSolver(settings: settings,
                                                   eyes: try eyeStates(sequence["start"], "\(name) start"))
        let frameRows = try #require(sequence["frames"] as? [Any], "\(name) frames")
        for frameRow in frameRows {
            let frame = try #require(frameRow as? [String: Any], "\(name) frame")
            let geometry = try eyeGeometry(frame["geometry"], name)
            let deltaTime = number(frame["deltaTime"])
            let target = try vector3(frame["target"], "\(name) target")
            let state = try settings.state(for: pattern)
            let effective = try SourceStudioEyeLookSolver.resolveTarget(target: target, root: geometry.rootNode,
                                                                        state: state).effective
            #expect(effective.rawValue == (frame["effectiveLookType"] as? String), "sequence \(name)")
            let previousEyes = solver.eyes
            let stepResult = try solver.step(deltaTime: deltaTime, target: target,
                                             geometry: geometry, pattern: pattern)
            let rotations = [stepResult.left, stepResult.right]
            let outputs = try #require(frame["outputs"] as? [Any], "\(name) outputs")
            for index in 0..<2 {
                let output = try #require(outputs[index] as? [String: Any], "\(name) output \(index)")
                let context = "\(name) frame eye \(index)"
                if output["localRotation"] is NSNull {
                    // deltaTime 0: the reference returns the previous state
                    // with null rotations; the solver must do the same.
                    zeroDtRows += 1
                    #expect(rotations[index] == nil, "\(context) expected null rotation")
                    #expect(solver.eyes == previousEyes, "\(context) state changed on zero deltaTime")
                    continue
                }
                #expect(rotations[index] != nil, "\(context) expected a rotation")
                if let rotation = rotations[index] {
                    expectClose(rotation, try quaternion(output["localRotation"], "expected rotation"),
                                tolerance: 1e-6, context)
                }
                let carried = solver.eyes[index]
                expectClose(carried.angleH, number(output["angleH"]), tolerance: 1e-5, "\(context) angleH")
                expectClose(carried.angleV, number(output["angleV"]), tolerance: 1e-5, "\(context) angleV")
                expectClose(carried.dirUp, try vector3(output["dirUp"], "expected dirUp"),
                            tolerance: 1e-6, "\(context) dirUp")
                if pattern == 2 { awayRows += 1 }
            }
            if deltaTime != 0 {
                let rightRow = try #require(outputs[1] as? [String: Any])
                expectClose(solver.num5, number(rightRow["num5"]), tolerance: 1e-6, "\(name) num5")
            }
        }
    }
    #expect(zeroDtRows >= 2, "fixture lost its zero-deltaTime coverage")
    #expect(awayRows >= 20, "fixture lost its AWAY sorasi coverage")
}

/// The added Unity math: Mathf.Lerp / InverseLerp clamping, Vector3.Project,
/// Quaternion.LookRotation, Vector3.OrthoNormalize and Vector3.Slerp.
@Test func studioEyeLookUnityMathHelpers() throws {
    // Mathf.Lerp clamps t to [0, 1]; Mathf.InverseLerp clamps to [0, 1] and
    // returns 1 when the interval is empty.
    #expect(try SourceStudioEyeLookSolver.lerp(2, 4, t: -1) == 2)
    #expect(try SourceStudioEyeLookSolver.lerp(2, 4, t: 2) == 4)
    #expect(try SourceStudioEyeLookSolver.inverseLerp(0, 10, -5) == 0)
    #expect(try SourceStudioEyeLookSolver.inverseLerp(0, 10, 50) == 1)
    #expect(try SourceStudioEyeLookSolver.inverseLerp(3, 3, 3) == 1)
    #expect(try SourceStudioEyeLookSolver.inverseLerp(3, 3, 7) == 1)
    // Vector3.Project(a, n) = n * Dot(a, n) / Dot(n, n), unnormalized n.
    expectClose(try SourceStudioEyeLookSolver.project(SIMD3<Double>(3, 4, 0), onto: SIMD3<Double>(1, 0, 0)),
                SIMD3<Double>(3, 0, 0), tolerance: 1e-12, "project x")
    expectClose(try SourceStudioEyeLookSolver.project(SIMD3<Double>(3, 4, 0), onto: SIMD3<Double>(0, 2, 0)),
                SIMD3<Double>(0, 4, 0), tolerance: 1e-12, "project scaled normal")
    // Quaternion.LookRotation maps +z onto the normalized forward and +y
    // onto the up direction orthogonalized against it (Unity left-handed).
    let identity = try SourceStudioEyeLookSolver.lookRotation(forward: SIMD3<Double>(0, 0, 1),
                                                              up: SIMD3<Double>(0, 1, 0))
    expectClose(identity, simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), tolerance: 1e-12, "look-rotation identity")
    let flipped = try SourceStudioEyeLookSolver.lookRotation(forward: SIMD3<Double>(0, 0, -1),
                                                             up: SIMD3<Double>(0.5, 1, 0))
    expectClose(try SourceStudioNeckTargetAngle.rotate(flipped, SIMD3<Double>(0, 0, 1)),
                SIMD3<Double>(0, 0, -1), tolerance: 1e-12, "look-rotation forward")
    expectClose(try SourceStudioNeckTargetAngle.rotate(flipped, SIMD3<Double>(0, 1, 0)),
                SIMD3<Double>(0.44721359549995793, 0.89442719099991588, 0),
                tolerance: 1e-12, "look-rotation orthogonalized up")
    // Vector3.OrthoNormalize orthogonalizes the tangent; a parallel tangent
    // falls back to the least-aligned basis vector (right, then up, forward).
    let (normal, tangent) = try SourceStudioEyeLookSolver.orthoNormalize(normal: SIMD3<Double>(0, 1, 0),
                                                                         tangent: SIMD3<Double>(0, 3, 0))
    expectClose(normal, SIMD3<Double>(0, 1, 0), tolerance: 1e-12, "ortho-normalize normal")
    expectClose(tangent, SIMD3<Double>(1, 0, 0), tolerance: 1e-12, "ortho-normalize fallback")
    let tilted = try SourceStudioEyeLookSolver.orthoNormalize(normal: SIMD3<Double>(1, 1, 0),
                                                              tangent: SIMD3<Double>(0, 1, 0))
    expectClose(simd_dot(tilted.normal, tilted.tangent), 0, tolerance: 1e-12, "ortho-normalize orthogonal")
    // Vector3.Slerp: endpoint arcs, clamped t with lerped magnitude,
    // (1-t)*a on a zero operand and a basis-axis arc for exact antiparallels.
    expectClose(try SourceStudioEyeLookSolver.slerpVector(SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 0, 1), t: 0),
                SIMD3<Double>(1, 0, 0), tolerance: 1e-12, "slerp t=0")
    expectClose(try SourceStudioEyeLookSolver.slerpVector(SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 0, 2), t: 5),
                SIMD3<Double>(0, 0, 2), tolerance: 1e-12, "slerp clamped t keeps magnitude")
    expectClose(try SourceStudioEyeLookSolver.slerpVector(SIMD3<Double>(2, 0, 0), .zero, t: 0.5),
                SIMD3<Double>(1, 0, 0), tolerance: 1e-12, "slerp zero operand")
    expectClose(try SourceStudioEyeLookSolver.slerpVector(SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, -1, 0), t: 1),
                SIMD3<Double>(0, -1, 0), tolerance: 1e-12, "slerp antiparallel")
    expectClose(try SourceStudioEyeLookSolver.slerpVector(SIMD3<Double>(1, 0, 0), SIMD3<Double>(-3, 0, 0), t: 1),
                SIMD3<Double>(-3, 0, 0), tolerance: 1e-12, "slerp antiparallel along x")
    // Quaternion.Inverse: conjugate over the squared length.
    let yaw90 = simd_quatd(ix: 0, iy: sin(.pi / 4), iz: 0, r: cos(.pi / 4))
    expectClose(try SourceStudioEyeLookSolver.inverseQuaternion(yaw90),
                simd_quatd(ix: 0, iy: -sin(.pi / 4), iz: 0, r: cos(.pi / 4)),
                tolerance: 1e-12, "inverse quaternion")
    // The solver's zero-direction route: normalizeOrZero keeps the zero
    // vector and the angle helpers read it as angle 0, like Unity's
    // normalize + Vector3.Angle on the same input.
    expectClose(SourceStudioEyeLookSolver.normalizeOrZero(.zero), .zero, tolerance: 0, "normalize zero")
}

/// The recovered bending chain and the four sorasi routes, exercised on the
/// AWAY fixture state (minBending -36, maxBending 23, upBending -30,
/// downBending 10, threshold 0, multiplier 0.4, maxAngleDifference 10) so the
/// L/R mirror and the (-maxBending, -minBending) remap are pinned.
@Test func studioEyeLookBendingAndSorasiBranches() throws {
    let settings = try SourceStudioEyeLookSettings(json: try settingsData(try fixtureJSON()))
    let away = try settings.state(for: 2)
    #expect(away.lookType == .away)
    // bend: the dead-band excess * |multiplier| vs. |angle| -
    // maxAngleDifference, carrying sign(angle) * sign(multiplier).
    // The literal is the reference's own float64 result (max(7 * 0.4,
    // 8 - 10) with the sign product), not a rounded 2.8.
    #expect(SourceStudioEyeLookSolver.bend(angle: 8, threshold: 1, multiplier: 0.4, maximumDifference: 10)
            == 2.8000000000000003)
    #expect(SourceStudioEyeLookSolver.bend(angle: 20, threshold: 1, multiplier: 0.4, maximumDifference: 10) == 10)
    #expect(SourceStudioEyeLookSolver.bend(angle: -20, threshold: 1, multiplier: -0.4, maximumDifference: 10) == 10)
    #expect(SourceStudioEyeLookSolver.bend(angle: 5, threshold: 10, multiplier: 0.4, maximumDifference: 10) == 0)
    // The L eye uses (minBending, maxBending), the R eye mirrors to
    // (-maxBending, -minBending) -- with this state (23, -36) that is
    // (-23, 36): both eyes can look out, each toward its own side.
    #expect(try SourceStudioEyeLookSolver.eyeBending(horizontal: 40, vertical: 0, state: away,
                                                     leftEye: true).horizontal == 23)
    #expect(try SourceStudioEyeLookSolver.eyeBending(horizontal: -40, vertical: 0, state: away,
                                                     leftEye: true).horizontal == -30)
    #expect(try SourceStudioEyeLookSolver.eyeBending(horizontal: 40, vertical: 0, state: away,
                                                     leftEye: false).horizontal == 30)
    #expect(try SourceStudioEyeLookSolver.eyeBending(horizontal: -40, vertical: 0, state: away,
                                                     leftEye: false).horizontal == -23)
    #expect(try SourceStudioEyeLookSolver.eyeBending(horizontal: 0, vertical: -50, state: away,
                                                     leftEye: true).vertical == -30)
    // keep-previous: coords farther apart than sorasiRate.
    var branch = try SourceStudioEyeLookSolver.sorasiHorizontal(previousAngle: 30, measured: -36,
                                                                state: away, sorasiRate: 1, num5: -1)
    #expect(branch.angle == 30)
    expectClose(branch.num5, 0.8983050847457628, tolerance: 1e-12, "sorasi keep arms a6's coordinate")
    // push away from a7 on a negative difference (a7 - rate here, clamped).
    branch = try SourceStudioEyeLookSolver.sorasiHorizontal(previousAngle: 0, measured: 5,
                                                            state: away, sorasiRate: 1, num5: -1)
    expectClose(branch.angle, -23, tolerance: 1e-12, "sorasi push-negative angle")
    expectClose(branch.num5, 0, tolerance: 1e-12, "sorasi push-negative arms")
    // ... and on a positive one.
    branch = try SourceStudioEyeLookSolver.sorasiHorizontal(previousAngle: 0, measured: -5,
                                                            state: away, sorasiRate: 1, num5: -1)
    #expect(branch.num5 > 0)
    expectClose(branch.num5, 0.8050847457627119, tolerance: 1e-12, "sorasi push-positive arms")
    // exactly equal coordinates add +sorasiRate.
    branch = try SourceStudioEyeLookSolver.sorasiHorizontal(previousAngle: 0, measured: 0,
                                                            state: away, sorasiRate: 1, num5: -1)
    expectClose(branch.num5, 0.8898305084745763, tolerance: 1e-12, "sorasi equal pushes +rate")
    // once armed, num5 alone remaps through (-maxBending, -minBending).
    branch = try SourceStudioEyeLookSolver.sorasiHorizontal(previousAngle: 30, measured: -36,
                                                            state: away, sorasiRate: 1, num5: 0.5)
    expectClose(branch.angle, 6.5, tolerance: 1e-12, "sorasi armed remap")
    #expect(branch.num5 == 0.5)
    // resolveTarget: the nearDis push-out on non-TARGET states, none on
    // TARGET, and the limit switch to the FORWARD front point (root rotated
    // 5 deg about RIGHT, so the front point dips by forntTagDis * sin 5 deg).
    let root = SourceStudioEyeLookGeometry.Node(position: SIMD3<Double>(0, 1.5, 0),
                                                rotation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                                                lossyScale: SIMD3<Double>(1, 1, 1))
    let near = try SourceStudioEyeLookSolver.resolveTarget(target: SIMD3<Double>(0, 1.5, 1),
                                                           root: root, state: away)
    #expect(near.effective == .away)
    expectClose(near.target - SIMD3<Double>(0, 1.5, 0), SIMD3<Double>(0, 0, away.nearDis),
                tolerance: 1e-12, "nearDis push-out")
    let target = try settings.state(for: 1)
    let inside = try SourceStudioEyeLookSolver.resolveTarget(target: SIMD3<Double>(0, 1.5, 1),
                                                             root: root, state: target)
    expectClose(inside.target, SIMD3<Double>(0, 1.5, 1), tolerance: 1e-12, "TARGET has no nearDis push-out")
    let behind = try SourceStudioEyeLookSolver.resolveTarget(target: SIMD3<Double>(0, 1.5, -3),
                                                             root: root, state: away)
    #expect(behind.effective == .forward)
    expectClose(behind.target, SIMD3<Double>(0, -2.8577871373829087, 49.809734904587276),
                tolerance: 1e-9, "FORWARD front point")
}

/// Invalid inputs: non-finite values throw, zero-length directions throw
/// where the original's normalize would divide by zero, and the solver
/// refuses malformed state, patterns and geometry.
@Test func studioEyeLookInvalidInputsThrow() throws {
    let settings = try SourceStudioEyeLookSettings(json: try settingsData(try fixtureJSON()))
    var solver = try SourceStudioEyeLookSolver(settings: settings)
    let geometry = SourceStudioEyeLookGeometry(
        rootNode: .init(position: .zero, rotation: .init(), lossyScale: .one),
        trfCenter: .init(position: .zero, rotation: .init(), lossyScale: .one),
        eyes: [.init(worldPosition: SIMD3<Double>(-0.032, 0, 0.05), origRotation: .init(),
                     referenceLookDir: SIMD3<Double>(0, 0, 1), referenceUpDir: SIMD3<Double>(0, 1, 0)),
               .init(worldPosition: SIMD3<Double>(0.032, 0, 0.05), origRotation: .init(),
                     referenceLookDir: SIMD3<Double>(0, 0, 1), referenceUpDir: SIMD3<Double>(0, 1, 0))])
    #expect(throws: (any Error).self) {
        _ = try solver.step(deltaTime: .nan, target: .zero, geometry: geometry, pattern: 1)
    }
    #expect(throws: (any Error).self) {
        _ = try solver.step(deltaTime: 0.1, target: SIMD3<Double>(Double.infinity, 0, 0),
                            geometry: geometry, pattern: 1)
    }
    #expect(throws: (any Error).self) {
        _ = try solver.step(deltaTime: 0.1, target: .zero, geometry: geometry, pattern: 7)
    }
    #expect(throws: (any Error).self) {
        _ = try solver.step(deltaTime: 0.1, target: .zero, geometry: geometry, pattern: 0)
    }
    solver.eyes[0].angleV = .nan
    #expect(throws: (any Error).self) {
        _ = try solver.step(deltaTime: 0.1, target: .zero, geometry: geometry, pattern: 1)
    }
    #expect(throws: (any Error).self) {
        _ = try solver.step(deltaTime: 0.1, target: .zero, geometry: SourceStudioEyeLookGeometry(
            rootNode: geometry.rootNode, trfCenter: geometry.trfCenter, eyes: [geometry.eyes[0]]), pattern: 1)
    }
    #expect(throws: (any Error).self) {
        _ = try SourceStudioEyeLookSolver(settings: settings, eyes: [.init(), .init(), .init()])
    }
    // Zero-length directions: LookRotation and Project throw where Unity
    // would divide by zero, and the correct frame refuses a target whose
    // clamped direction is parallel to the up axis (the recovered message).
    #expect(throws: (any Error).self) {
        _ = try SourceStudioEyeLookSolver.lookRotation(forward: .zero, up: SIMD3<Double>(0, 1, 0))
    }
    #expect(throws: (any Error).self) {
        _ = try SourceStudioEyeLookSolver.lookRotation(forward: SIMD3<Double>(0, 1, 0), up: SIMD3<Double>(0, 5, 0))
    }
    #expect(throws: (any Error).self) {
        _ = try SourceStudioEyeLookSolver.project(SIMD3<Double>(1, 0, 0), onto: .zero)
    }
    // The 120-degree rotation about (1,1,1) is exact in binary floating
    // point (all components are powers of two) and maps the clamped local
    // (0, 0, 0.5) onto exactly +Y, so the normal is exactly parallel to up.
    let exactAxisSwap = simd_quatd(ix: -0.5, iy: -0.5, iz: -0.5, r: 0.5)
    var parallelUp = false
    do {
        _ = try SourceStudioEyeLookSolver.correctEyeTargets(
            target: SIMD3<Double>(0, 1.5, 0.2),
            trfCenter: .init(position: SIMD3<Double>(0, 1.5, 0.2), rotation: exactAxisSwap, lossyScale: .one),
            centerEyeLength: 0.05)
    } catch {
        parallelUp = String(describing: error).contains("parallel to the up axis")
    }
    #expect(parallelUp, "the correct frame must report the recovered error")
    // Settings decode boundary: a document without eyeTypeStates throws.
    #expect(throws: (any Error).self) {
        _ = try SourceStudioEyeLookSettings(
            json: Data(#"{"eyes":{"correct":1,"centerEyeLength":0.05,"sorasiRate":1,"eyeTypeStates":[]}}"#.utf8))
    }
}
