import Foundation
import simd
import Testing
import Scene
@testable import Studio

// Fixture written by Tools/reverse/compare_neck_look.py --fixture from the
// Python reference (Tools/reverse/analysis/neck_look_reference.py); all
// quaternions are Unity x,y,z,w and every expectation matches within 1e-5.
private let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures/neck-look-reference.json")

private func fixtureJSON() throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
}

private func quaternion(_ components: [Any]) throws -> simd_quatf {
    let values = components.compactMap { ($0 as? NSNumber)?.doubleValue }
    guard values.count == 4 else { throw RigError.invalid("Fixture quaternion must have four components.") }
    return simd_quatf(ix: Float(values[0]), iy: Float(values[1]), iz: Float(values[2]), r: Float(values[3]))
}

private func quaternions(_ value: Any?) throws -> [simd_quatf] {
    guard let rows = value as? [Any] else { throw RigError.invalid("Fixture quaternion list missing.") }
    return try rows.map { try quaternion(($0 as? [Any]) ?? []) }
}

private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? .nan }

private func lookType(_ name: Any?) throws -> SourceStudioNeckLookType {
    guard let name = name as? String, let lookType = SourceStudioNeckLookType(rawValue: name) else {
        throw RigError.invalid("Fixture look type is unknown.")
    }
    return lookType
}

private func expectClose(_ a: simd_quatf, _ b: simd_quatf, tolerance: Float = 1e-5) {
    let left = [a.imag.x, a.imag.y, a.imag.z, a.real]
    let right = [b.imag.x, b.imag.y, b.imag.z, b.real]
    for (x, y) in zip(left, right) { #expect(abs(x - y) <= tolerance, "quaternion \(left) vs \(right)") }
}

/// The settings document shape the loader boundary-checks, with the fixture's
/// curve and the captured seven neck states.
private func settingsJSON(_ fixture: [String: Any]) throws -> Data {
    let curve = try JSONSerialization.data(withJSONObject: fixture["changeTypeLerpCurve"] as Any)
    let states = ["FORWARD", "TARGET", "AWAY", "ANIMATION", "FIX", "TARGET", "AWAY"]
        .map { "{\"lookType\":{\"name\":\"\($0)\"}}" }.joined(separator: ",")
    return Data("""
    {"neck":{"calcLerp":1,"changeTypeLeapTime":1,"changeTypeLerpCurve":\(String(decoding: curve, as: UTF8.self)),\
    "aBones":[{"neckBone":"cf_j_neck"},{"neckBone":"cf_j_head"}],"neckTypeStates":[\(states)]}}
    """.utf8)
}

@Test func studioNeckLookCurveMatchesReferenceSamples() throws {
    let curve = try SourceStudioNeckLookSettings(json: settingsJSON(try fixtureJSON())).changeTypeLerpCurve
    let samples = try #require(try fixtureJSON()["curveSamples"] as? [Any])
    for sample in samples {
        let row = try #require(sample as? [String: Any])
        #expect(abs(try curve.evaluate(Float(number(row["t"]))) - Float(number(row["value"]))) < 1e-5)
    }
    // Clamp infinities: outside the key range the end values hold.
    #expect(try curve.evaluate(-1) == 0.002166748046875)
    #expect(try curve.evaluate(2) == 1)
}

@Test func studioNeckLookSequenceMatchesReferenceFixture() throws {
    let fixture = try fixtureJSON()
    let settings = try SourceStudioNeckLookSettings(json: settingsJSON(fixture))
    let start = try #require(fixture["start"] as? [String: Any])
    var state = try SourceStudioNeckLook(settings: settings, lookType: lookType(start["lookType"]),
        fixAngle: try quaternions(start["fixAngle"]), fixAngleBackup: try quaternions(start["fixAngleBackup"]))
    for step in try #require(fixture["sequence"] as? [Any]) {
        let row = try #require(step as? [String: Any])
        let rotations = try state.step(deltaTime: Float(number(row["deltaTime"])),
            lookType: lookType(row["lookType"]), animated: try quaternions(row["animated"]))
        for (returned, expected) in zip(rotations, try quaternions(row["localRotations"])) { expectClose(returned, expected) }
        for (kept, expected) in zip(state.fixAngle, try quaternions(row["fixAngle"])) { expectClose(kept, expected) }
        for (kept, expected) in zip(state.fixAngleBackup, try quaternions(row["fixAngleBackup"])) { expectClose(kept, expected) }
        #expect(abs(state.changeTypeTimer - Float(number(row["timer"]))) < 1e-5)
    }
}

@Test func studioNeckLookSavedFixReturnsTheSavedAngleFromTheFirstFrame() throws {
    let fixture = try fixtureJSON()
    let savedFix = try #require(fixture["savedFix"] as? [String: Any])
    let start = try #require(savedFix["start"] as? [String: Any])
    let settings = try SourceStudioNeckLookSettings(json: settingsJSON(fixture))
    let saved = try quaternions(start["fixAngle"])
    // A loaded FIX state (fixAngleBackup already equals fixAngle) must return
    // the saved quaternion from the very first frame, whatever the Animator
    // posed, because the transition is a zero arc onto the same rotation.
    var state = try SourceStudioNeckLook(settings: settings, lookType: lookType(start["lookType"]), fixAngle: saved)
    let rotations = try state.step(deltaTime: Float(number(savedFix["deltaTime"])),
        lookType: lookType(savedFix["lookType"]), animated: try quaternions(savedFix["animated"]))
    for (returned, kept) in zip(rotations, saved) { expectClose(returned, kept) }
}

@Test func studioNeckLookSettingsAndStepRejectUnsupportedInputs() throws {
    let fixture = try fixtureJSON()
    let settingsText = String(decoding: try settingsJSON(fixture), as: UTF8.self)
    #expect(throws: (any Error).self) { try SourceStudioNeckLookSettings(json: Data(settingsText.replacingOccurrences(of: "\"calcLerp\":1", with: "\"calcLerp\":0.5").utf8)) }
    var state = try SourceStudioNeckLook(settings: try SourceStudioNeckLookSettings(json: settingsJSON(fixture)),
        lookType: .animation, fixAngle: [SourceStudioNeckLook.identity, SourceStudioNeckLook.identity])
    // TARGET/AWAY step is reported, not silently solved.
    #expect(throws: (any Error).self) {
        try state.step(deltaTime: 0.016, lookType: .away, animated: [SourceStudioNeckLook.identity, SourceStudioNeckLook.identity])
    }
    // A zero deltaTime passes the animated pose through untouched.
    let pose = try quaternion([0, 0.2, 0, 0.98])
    expectClose(try state.step(deltaTime: 0, lookType: .animation, animated: [pose, pose])[0], pose, tolerance: 0)
}
