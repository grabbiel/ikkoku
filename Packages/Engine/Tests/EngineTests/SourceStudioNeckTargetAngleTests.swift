import Foundation
import simd
import Testing
import Scene
@testable import Studio

// Fixture written by Tools/reverse/analysis/neck_target_angle.py --fixture:
// seeded SYNTHETIC geometry (no original-game data) with the Python oracle's
// limit check, raw GetAngleToTarget and AWAY-adjusted angles as expectations.
// Quaternions are Unity x,y,z,w; every angle matches within 1e-6 deg.
private let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures/neck-target-angle.json")

private func fixtureJSON() throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
}

private func vector3(_ value: Any?) throws -> SIMD3<Double> {
    guard let values = value as? [Any], values.count == 3,
          let components = values as? [NSNumber] else {
        throw RigError.invalid("Fixture vector must have three numbers.")
    }
    return SIMD3<Double>(components.map { $0.doubleValue })
}

private func quaternion(_ value: Any?) throws -> simd_quatd {
    guard let values = value as? [Any], values.count == 4,
          let components = values as? [NSNumber] else {
        throw RigError.invalid("Fixture quaternion must have four numbers.")
    }
    return simd_quatd(ix: components[0].doubleValue, iy: components[1].doubleValue,
                      iz: components[2].doubleValue, r: components[3].doubleValue)
}

private func pair(_ value: Any?) throws -> (x: Double, y: Double) {
    guard let values = value as? [NSNumber], values.count == 2 else {
        throw RigError.invalid("Fixture angle must be an xy pair.")
    }
    return (values[0].doubleValue, values[1].doubleValue)
}

private func transform(_ value: Any?) throws -> SourceStudioNeckTargetAngle.Transform {
    guard let row = value as? [String: Any] else { throw RigError.invalid("Fixture transform missing.") }
    return try .init(position: vector3(row["position"]), rotation: quaternion(row["rotation"]))
}

private func bendingLimits(_ value: Any?) throws -> [SourceStudioNeckLookSettings.BendingLimits] {
    guard let rows = value as? [[String: Any]] else { throw RigError.invalid("Fixture aParam missing.") }
    return try rows.map { row in
        guard let minimum = row["minBendingAngle"] as? NSNumber, let maximum = row["maxBendingAngle"] as? NSNumber
        else { throw RigError.invalid("Fixture aParam entry has no bending limits.") }
        return .init(minBendingAngle: Float(truncating: minimum), maxBendingAngle: Float(truncating: maximum),
                     upBendingAngle: 0, downBendingAngle: 0)
    }
}

private func expectClose(_ a: Double, _ b: Double, tolerance: Double = 1e-6, _ label: String = "") {
    #expect(abs(a - b) <= tolerance, "\(label) \(a) vs \(b)")
}

@Test func neckTargetAngleFixtureMatchesPythonOracle() throws {
    let cases = try #require(try fixtureJSON()["cases"] as? [[String: Any]])
    #expect(cases.count >= 24)
    var awayAbove = 0, awayBelow = 0
    for caseRow in cases {
        let id = (caseRow["id"] as? String) ?? "?"
        let target = try vector3(caseRow["target"])
        let aim = try transform(caseRow["aim"])
        let reference = try transform(caseRow["neckRef"])
        let headRotation = try quaternion(caseRow["headRotation"])
        let limits = try #require(caseRow["limits"] as? [String: Any])
        func number(_ key: String) throws -> Double {
            guard let value = limits[key] as? NSNumber else { throw RigError.invalid("Fixture limit \(key) missing.") }
            return value.doubleValue
        }
        let check = try #require(caseRow["limit"] as? [String: Any])
        let reported = try limitOf(check)
        let broken = try SourceStudioNeckTargetAngle
            .limitCheck(target: target, reference: reference,
                        horizontalLimit: number("hAngleLimit"), verticalLimit: number("vAngleLimit"),
                        correction: number("correction"))
        #expect(broken.broken == reported.broken, "\(id): limit broken mismatch")
        expectClose(broken.horizontal, reported.horizontal, "\(id): horizontal limit angle")
        expectClose(broken.vertical, reported.vertical, "\(id): vertical limit angle")

        let raw = try pair(caseRow["raw"])
        let angle = try SourceStudioNeckTargetAngle.angleToTarget(target: target, aim: aim,
                                                                  headRotation: headRotation, reference: reference)
        expectClose(angle.x, raw.x, "\(id): raw x")
        expectClose(angle.y, raw.y, "\(id): raw y")

        let adjusted = try pair(caseRow["adjusted"])
        if broken.broken {
            #expect(adjusted.x == 0 && adjusted.y == 0, "\(id): broken frames must zero the adjusted angle")
            continue
        }
        guard let away = caseRow["away"] as? [String: Any] else {
            expectClose(raw.x, adjusted.x, "\(id): TARGET adjusted angle is the raw angle")
            expectClose(raw.y, adjusted.y, "\(id): TARGET adjusted angle is the raw angle")
            continue
        }
        guard let boneAngleH = away["boneAngleH"] as? [NSNumber] else {
            throw RigError.invalid("Fixture AWAY case has no boneAngleH.")
        }
        let limitAway = try #require(away["limitAway"] as? NSNumber).doubleValue
        let prediction = try SourceStudioNeckTargetAngle
            .awayAdjust(nowAngle: raw, boneAngleH: boneAngleH.map { $0.doubleValue },
                        aParam: try bendingLimits(away["aParam"]), limitAway: limitAway)
        expectClose(prediction.x, adjusted.x, "\(id): adjusted x")
        expectClose(prediction.y, adjusted.y, "\(id): adjusted y")
        if raw.y > boneAngleH.reduce(0, { $0 + $1.doubleValue }) { awayAbove += 1 } else { awayBelow += 1 }
    }
    // The intact AWAY cases must exercise both outer branches of the AWAY
    // adjustment (raw y above / at-or-below the bone angleH sum), and the
    // broken ones already ran the zeroing path above.
    #expect(awayAbove >= 2 && awayBelow >= 2, "the fixture lost AWAY branch coverage: \(awayAbove)/\(awayBelow)")
}

/// The fixture's recorded limit-check row.
private func limitOf(_ row: [String: Any]) throws -> (broken: Bool, horizontal: Double, vertical: Double) {
    guard let broken = row["broken"] as? Bool,
          let horizontal = row["horizontal"] as? NSNumber, let vertical = row["vertical"] as? NSNumber else {
        throw RigError.invalid("Fixture limit row is incomplete.")
    }
    return (broken, horizontal.doubleValue, vertical.doubleValue)
}

@Test func neckTargetAngleRejectsDegenerateInput() throws {
    let aligned = SourceStudioNeckTargetAngle.Transform(position: [0, 1.4, 0],
                                                        rotation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1))
    // A target on the aim origin has no defined angle.
    #expect(throws: (any Error).self) {
        _ = try SourceStudioNeckTargetAngle.angleToTarget(target: [0, 1.4, 0], aim: aligned,
                                                          headRotation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                                                          reference: aligned)
    }
    // Zero-length directions cannot define a shortest arc.
    #expect(throws: (any Error).self) {
        _ = try SourceStudioNeckTargetAngle.fromToRotation(from: [0, 0, 0], to: [0, 0, 1])
    }
    // A zero operand reads angle 0, and the antiparallel fallback still flips.
    let zeroAngle = try SourceStudioNeckTargetAngle.angleAroundAxis([0, 0, 0], [1, 0, 0], axis: [0, 1, 0])
    expectClose(zeroAngle, 0, "zero operand angle")
    let flipped = try SourceStudioNeckTargetAngle.fromToRotation(from: [0, 0, 1], to: [0, 0, -1])
    let rotated = try SourceStudioNeckTargetAngle.rotate(flipped, [0, 0, 1])
    for (component, expected) in zip([rotated.x, rotated.y, rotated.z], [0.0, 0.0, -1.0]) {
        expectClose(component, expected, "antiparallel fallback")
    }
    // away-adjust rejects missing bones and non-finite angles at the boundary.
    let aParam = [SourceStudioNeckLookSettings.BendingLimits(minBendingAngle: -40, maxBendingAngle: 40,
                                                             upBendingAngle: 0, downBendingAngle: 0)]
    #expect(throws: (any Error).self) {
        _ = try SourceStudioNeckTargetAngle.awayAdjust(nowAngle: (0, 45), boneAngleH: [], aParam: aParam,
                                                       limitAway: 10)
    }
    #expect(throws: (any Error).self) {
        _ = try SourceStudioNeckTargetAngle.awayAdjust(nowAngle: (0, .nan), boneAngleH: [1], aParam: aParam,
                                                       limitAway: 10)
    }
}
