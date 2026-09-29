import Foundation
import simd
import Testing
import CoreMath
import Scene
@testable import Studio

// Hand-made-geometry tests for SourceStudioEyeLookRuntime: no rig, inputs are
// SYNTHETIC (no original-game capture data). The layout is the captured scene
// simplified to the eye strip — a head at the origin, trfCenter on it and the
// two EyeTarget parents at the EyeTargetL offset the capture reports
// (about +-0.046 m on x) — and the pattern is the shipped TARGET state 1's
// numbers. The rate expectation leans on the rates pinned in
// SourceStudioEyeLookTests: at angleH 0 they are exactly +-13/59 and linear
// in angleH with the R eye mirrored, so a symmetric eye-angle pair gives
// exactly opposite rates.

/// The shipped TARGET eyeTypeStates numbers (pattern 1 of the captured
/// prefab), plus the Init-time node names and head vectors the runtime reads;
/// the eyeObjs order (eyeLR 0 = L) is the runtime's eye order.
private func runtimeSettingsJSON() -> String {
    """
    {"eyes":{"correct":1,"centerEyeLength":0.05,"sorasiRate":1,
    "rootNode":"cf_j_head","trfCenter":"cf_J_Eye_tz",
    "headLookVector":[0,0,1],"headUpVector":[0,1,0],
    "eyeObjs":[{"eyeLR":0,"eyeTransform":"EyeTargetL"},{"eyeLR":1,"eyeTransform":"EyeTargetR"}],
    "eyeTypeStates":[{"lookType":{"name":"TARGET"},"thresholdAngleDifference":0,
      "bendingMultiplier":0.4,"maxAngleDifference":10,"upBendingAngle":-30,"downBendingAngle":10,
      "minBendingAngle":-36,"maxBendingAngle":23,"leapSpeed":38,"forntTagDis":50,"nearDis":2,
      "hAngleLimit":110,"vAngleLimit":80}]}}
    """
}

private func runtimeSettings() throws -> SourceStudioEyeLookSettings {
    try SourceStudioEyeLookSettings(json: Data(runtimeSettingsJSON().utf8))
}

private let identityD = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

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

private func expectClose(_ a: [Double], _ b: [Double], tolerance: Double, _ context: String) {
    #expect(a.count == b.count, "\(context): \(a) vs \(b)")
    for (x, y) in zip(a, b) {
        #expect(abs(x - y) <= tolerance, "\(context): \(a) vs \(b)")
    }
}

private let eyeOffsetY = 0.0035

/// Unity-basis frame: head and trfCenter at `head`, identity, unit scale; the
/// two eye positions at x = -0.046 / +0.046 and both +0.0035 in y (the
/// captured EyeTargetL - trfCenter distance; the dam offsets mirror x only),
/// each looking +Z with +Y up.
private func geometry(head: SIMD3<Double> = SIMD3<Double>(0, 1.4, 0),
                      distance: Double = 2) -> SourceStudioEyeLookGeometry {
    let eye = SIMD3<Double>(0.046, eyeOffsetY, 0)
    return SourceStudioEyeLookGeometry(
        rootNode: .init(position: head, rotation: identityD, lossyScale: SIMD3<Double>(1, 1, 1)),
        trfCenter: .init(position: head, rotation: identityD, lossyScale: SIMD3<Double>(1, 1, 1)),
        eyes: [
            .init(worldPosition: head - SIMD3<Double>(eye.x, -eye.y, 0), origRotation: identityD,
                  referenceLookDir: SIMD3<Double>(0, 0, 1), referenceUpDir: SIMD3<Double>(0, 1, 0)),
            .init(worldPosition: head + eye, origRotation: identityD,
                  referenceLookDir: SIMD3<Double>(0, 0, 1), referenceUpDir: SIMD3<Double>(0, 1, 0)),
        ])
}

private func eyeParents() -> [SourceStudioEyeLookRuntime.EyeParent] {
    [SourceStudioEyeLookRuntime.EyeParent(rotation: identityD, localRotation: identityD),
     SourceStudioEyeLookRuntime.EyeParent(rotation: identityD, localRotation: identityD)]
}

@Test func studioEyeLookRuntimeStraightAheadGivesOppositeHorizontalRates() throws {
    let settings = try runtimeSettings()
    let runtime = try SourceStudioEyeLookRuntime(settings: settings, rootRotation: identityD,
                                                 eyeParents: eyeParents())
    #expect(runtime.lastRotations == nil)
    #expect(runtime.angleHRates == [0, 0], "rates are the field default before the first frame")
    // Camera straight ahead: the correct frame's +-centerEyeLength pair puts
    // each target 0.004 m outboard of its eye, a mirror-symmetric demand, so
    // the frame's angleH pair is symmetric and the R-mirrored rate formula
    // gives exactly opposite horizontal rates — neither zero.  The camera
    // sits at the eyes' height (head y + 0.0035) so the vertical demand is 0.
    try runtime.update(deltaTime: 1 / 30, target: SIMD3<Double>(0, 1.4035, 2),
                       geometry: geometry(), pattern: 0)
    let rates = runtime.angleHRates
    #expect(rates[0] * rates[1] < 0, "opposite signs: \(rates)")
    expectClose(rates[0], -rates[1], tolerance: 1e-12, "symmetric layout mirrors the rates")
    #expect(abs(rates[0]) > 1e-9, "the off-center eyes converge, L rate \(rates[0])")
    #expect(abs(rates[0]) <= 1 && abs(runtime.angleVRate) <= 1, "rates stay in [-1, 1]")
    // One frame at leapSpeed 38 covers the whole 0.11 deg demand (38/30 > 1)
    // and the level camera leaves no vertical angle.
    let angles = runtime.eyes.map(\.angleH)
    #expect(angles[0] * angles[1] < 0, "opposite eye angles: \(angles)")
    expectClose(runtime.eyes[0].angleV, 0, tolerance: 1e-12, "level camera, no vertical angle")
    // The predicted local rotations come back for both eyes.
    let rotations = try #require(runtime.lastRotations)
    #expect(rotations.left != nil && rotations.right != nil)
}

@Test func studioEyeLookRuntimeZeroDeltaKeepsAngles() throws {
    let settings = try runtimeSettings()
    let runtime = try SourceStudioEyeLookRuntime(settings: settings, rootRotation: identityD,
                                                 eyeParents: eyeParents())
    // Orbit partway off axis first so the angles are clearly nonzero, then a
    // zero-deltaTime frame: the solver's early return leaves angleH / angleV
    // and the written rotations untouched but still recomputes the frame's
    // rates from the carried angles, so they repeat.
    try runtime.update(deltaTime: 1 / 30, target: SIMD3<Double>(0.5, 1.4, 2),
                       geometry: geometry(), pattern: 0)
    let anglesBefore = runtime.eyes.map { [$0.angleH, $0.angleV] }
    let ratesBefore = runtime.angleHRates
    let rotationsBefore = try #require(runtime.lastRotations)
    #expect(abs(anglesBefore[0][0]) > 1e-6, "off-axis camera moved the L angle")
    try runtime.update(deltaTime: 0, target: SIMD3<Double>(0.5, 1.4, 2),
                       geometry: geometry(), pattern: 0)
    expectClose(runtime.eyes.map(\.angleH), anglesBefore.map { $0[0] }, tolerance: 1e-12, "zero dt keeps angleH")
    expectClose(runtime.eyes.map(\.angleV), anglesBefore.map { $0[1] }, tolerance: 1e-12, "zero dt keeps angleV")
    expectClose(runtime.angleHRates, ratesBefore, tolerance: 1e-12, "rates recomputed from carried angles")
    #expect(runtime.lastRotations?.left != nil, "the last written pair is kept")
    let left = try #require(rotationsBefore.left)
    let leftNow = try #require(runtime.lastRotations?.left)
    expectClose(leftNow, left, tolerance: 0, "zero dt wrote nothing new")
}

@Test func studioEyeLookRuntimeSavedAnglesOverrideInit() throws {
    let settings = try runtimeSettings()
    // Without saved bytes the Init pass starts both eyes flat at the
    // reference frame, exactly what SourceStudioEyeLookSolver.initialState
    // returns for the same inputs.
    let plain = try SourceStudioEyeLookRuntime(settings: settings, rootRotation: identityD,
                                               eyeParents: eyeParents())
    #expect(plain.eyes.map(\.angleH) == [0, 0] && plain.eyes.map(\.angleV) == [0, 0],
            "Init angles start flat")
    let direct = try SourceStudioEyeLookSolver.initialState(
        rootNodeRotation: identityD,
        eyes: [(parentRotation: identityD, localRotation: identityD, eyeLR: 0),
               (parentRotation: identityD, localRotation: identityD, eyeLR: 1)],
        headLookVector: SIMD3<Double>(0, 0, 1), headUpVector: SIMD3<Double>(0, 1, 0))
    #expect(plain.reference.count == 2)
    expectClose(plain.reference[0].lookDir, direct.reference[0].lookDir, tolerance: 1e-12, "Init lookDir")
    expectClose(plain.reference[1].upDir, direct.reference[1].upDir, tolerance: 1e-12, "Init upDir")
    expectClose(plain.reference[0].origRotation, direct.reference[0].origRotation, tolerance: 0, "Init origRotation")
    // The scene's saved eye angles replace the Init zeros (the dirUp frame
    // stays the Init one — the fix bytes carry no up vector), and a saved
    // pair with the wrong shape is refused at init instead of half-applied.
    let restored = try SourceStudioEyeLookRuntime(settings: settings, rootRotation: identityD,
                                                  eyeParents: eyeParents(),
                                                  savedAngles: (horizontal: [5, -7], vertical: [2, -3]))
    #expect(restored.eyes.map(\.angleH) == [5, -7], "saved angleH overrides Init")
    #expect(restored.eyes.map(\.angleV) == [2, -3], "saved angleV overrides Init")
    expectClose(restored.eyes[0].dirUp, SIMD3<Double>(0, 1, 0), tolerance: 1e-12, "saved angles keep the Init dirUp")
    #expect(throws: (any Error).self) {
        _ = try SourceStudioEyeLookRuntime(settings: settings, rootRotation: identityD,
                                           eyeParents: eyeParents(),
                                           savedAngles: (horizontal: [5], vertical: [2, -3]))
    }
    // A settings document without head vectors cannot Init.
    let bare = try SourceStudioEyeLookSettings(json: Data(
        #"{"eyes":{"correct":1,"centerEyeLength":0.05,"sorasiRate":1,"eyeTypeStates":[{"lookType":"TARGET","thresholdAngleDifference":0,"bendingMultiplier":0.4,"maxAngleDifference":10,"upBendingAngle":-30,"downBendingAngle":10,"minBendingAngle":-36,"maxBendingAngle":23,"leapSpeed":38,"forntTagDis":50,"nearDis":2,"hAngleLimit":110,"vAngleLimit":80}]}}"#
            .utf8))
    #expect(throws: (any Error).self) {
        _ = try SourceStudioEyeLookRuntime(settings: bare, rootRotation: identityD,
                                           eyeParents: eyeParents())
    }
}
