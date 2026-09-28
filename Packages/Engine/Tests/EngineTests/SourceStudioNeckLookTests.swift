import Foundation
import simd
import Testing
import CoreMath
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

/// Three nodes with distinct authored translation, rotation and non-uniform
/// scale on both neck bones, so applied(to:rig:) tests can see exactly which
/// channels survive the override write.
private func neckLookRig() throws -> RigDefinition {
    try RigDefinition(nodes: [
        .init(name: "root", sourceID: "root", parent: nil),
        .init(name: "cf_j_neck", sourceID: "neck", parent: 0, translation: Float3(0, 0.4, 0.02),
              rotation: simd_quatf(angle: 0.2, axis: Float3(0, 1, 0)), scale: Float3(1, 1.2, 0.8)),
        .init(name: "cf_j_head", sourceID: "head", parent: 1, translation: Float3(0, 0.1, -0.03),
              rotation: simd_quatf(angle: -0.3, axis: Float3(1, 0, 0)), scale: Float3(1.1, 1, 1)),
    ], skins: [])
}

/// The fixture's loaded-FIX seed: fixAngle == fixAngleBackup, both saved.
private func savedFixSeed(_ fixture: [String: Any]) throws -> [simd_quatf] {
    let savedFix = try #require(fixture["savedFix"] as? [String: Any])
    let start = try #require(savedFix["start"] as? [String: Any])
    return try quaternions(start["fixAngle"])
}

private func expectPoseMatrix(_ pose: RigPose, _ node: Int, _ expected: float4x4, tolerance: Float = 1e-5) {
    for column in 0..<4 { for row in 0..<4 {
        #expect(abs(pose.localMatrices[node][column][row] - expected[column][row]) <= tolerance, "matrix \(node)")
    } }
}

@Test func studioNeckLookAppliedFixWritesSavedQuaternionsFromTheFirstFrame() throws {
    let fixture = try fixtureJSON()
    let settings = try SourceStudioNeckLookSettings(json: settingsJSON(fixture))
    let saved = try savedFixSeed(fixture)
    let rig = try neckLookRig()
    var pose = RigPose(rig: rig)
    // Elapsed 0 steps with the documented tiny first-frame delta, so FIX must
    // already show the saved rotation; each bone keeps its own TRS channels.
    #expect(try SourceStudioNeckLook.applied(pose: &pose, rig: rig, settings: settings, fixAngle: saved,
        lookType: .fix, elapsed: 0, neckFKActive: false) == .fix)
    expectPoseMatrix(pose, 1, Transform.trs(Float3(0, 0.4, 0.02), UnityCoordinates.rotation(saved[0]), Float3(1, 1.2, 0.8)))
    expectPoseMatrix(pose, 2, Transform.trs(Float3(0, 0.1, -0.03), UnityCoordinates.rotation(saved[1]), Float3(1.1, 1, 1)))
    #expect(pose.localMatrices[0] == rig.restPose.localMatrices[0])
}

@Test func studioNeckLookAppliedForwardAtHalfASecondMatchesTheReference() throws {
    let fixture = try fixtureJSON()
    let settings = try SourceStudioNeckLookSettings(json: settingsJSON(fixture))
    let saved = try savedFixSeed(fixture)
    // The transition fraction comes from the Python-provided curve sample at
    // t 0.5, not from the Swift curve. Both saved bones rotate about Y only,
    // so the slerp toward identity is the analytic angle lerp (1 - num) * theta.
    let samples = try #require(fixture["curveSamples"] as? [Any])
    let sample = try #require(samples.compactMap { $0 as? [String: Any] }.first { number($0["t"]) == 0.5 })
    let num = Float(number(sample["value"]))
    #expect(abs(try settings.changeTypeLerpCurve.evaluate(0.5) - num) < 1e-5)
    let rig = try neckLookRig()
    var pose = RigPose(rig: rig)
    #expect(try SourceStudioNeckLook.applied(pose: &pose, rig: rig, settings: settings, fixAngle: saved,
        lookType: .forward, elapsed: 0.5, neckFKActive: false) == .forward)
    for (node, bone) in [(1, 0), (2, 1)] {
        let theta = 2 * atan2(saved[bone].imag.y, saved[bone].real)
        let expected = Transform.trs(rig.nodes[node].translation,
            UnityCoordinates.rotation(simd_quatf(angle: (1 - num) * theta, axis: Float3(0, 1, 0))),
            rig.nodes[node].scale)
        expectPoseMatrix(pose, node, expected, tolerance: 2e-5)
    }
}

@Test func studioNeckLookAppliedLeavesThePoseToFKAndToAnimation() throws {
    let settings = try SourceStudioNeckLookSettings(json: settingsJSON(try fixtureJSON()))
    let saved = try savedFixSeed(fixtureJSON())
    // An active Studio FK neck group owns the neck, so nothing may be written.
    let rig = try neckLookRig()
    var posed = RigPose(rig: rig)
    #expect(try SourceStudioNeckLook.applied(pose: &posed, rig: rig, settings: settings, fixAngle: saved,
        lookType: .fix, elapsed: 0.5, neckFKActive: true) == .none)
    #expect(posed.localMatrices == rig.restPose.localMatrices)
    // ANIMATION keeps the incoming (animated) pose; there is nothing to write.
    #expect(try SourceStudioNeckLook.applied(pose: &posed, rig: rig, settings: settings, fixAngle: saved,
        lookType: .animation, elapsed: 0.5, neckFKActive: false) == .none)
    #expect(posed.localMatrices == rig.restPose.localMatrices)
    #expect(throws: (any Error).self) {
        var pose = RigPose(rig: rig)
        try SourceStudioNeckLook.applied(pose: &pose, rig: rig, settings: settings, fixAngle: saved,
            lookType: .fix, elapsed: -1, neckFKActive: false)
    }
}

@Test func studioNeckLookOverrideResolutionCoversEveryBranch() throws {
    // The test settings keep the captured order, so the lookTypes are
    // FORWARD, TARGET, AWAY, ANIMATION, FIX, TARGET, AWAY.
    let settings = try SourceStudioNeckLookSettings(json: settingsJSON(try fixtureJSON()))
    func resolve(_ pattern: Int32?, bones: Int? = 2, configured: SourceStudioNeckLookSettings? = settings)
        -> SourceStudioNeckLookOverride.Resolution { SourceStudioNeckLookOverride.resolve(effectivePattern: pattern, settings: configured, savedBoneCount: bones) }
    #expect(resolve(4).applied == .fix && resolve(4).lookType == .fix)
    #expect(resolve(0).applied == .forward && resolve(0).lookType == .forward)
    let away = resolve(2)
    #expect(away.applied == .none && away.lookType == .away && away.reason == "Neck gaze solver pending; animated pose kept.")
    #expect(resolve(3).applied == .none && resolve(3).lookType == .animation)
    let outside = resolve(7)
    #expect(outside.applied == .none && outside.lookType == nil && outside.reason.contains("outside the prefab's 7 neck states"))
    let wrongCount = resolve(4, bones: 3)
    #expect(wrongCount.applied == .none && wrongCount.lookType == .fix && wrongCount.reason.contains("3 bones but the calculator reads 2"))
    let unreadable = resolve(nil, bones: nil)
    #expect(unreadable.applied == .none && unreadable.lookType == nil)
    let missing = resolve(4, configured: nil)
    #expect(missing.applied == .none && missing.lookType == nil && missing.reason.contains("not configured"))
}
