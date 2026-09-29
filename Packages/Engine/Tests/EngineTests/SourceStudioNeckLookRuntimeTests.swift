import Foundation
import simd
import Testing
import CoreMath
import Scene
@testable import Studio

// Hand-made-geometry tests for SourceStudioNeckLookRuntime: no rig, every
// expected number derived by hand from the ported pieces and cross-checked
// against the Python oracle (Tools/reverse/analysis/neck_target_angle.py) —
// the level side target below solves to nowAngle (0, yaw), the behind target
// reports horizontal 180 (broken), and AWAY's adjustment maps (0, 30) onto
// y -60. The oracle also shows |vertical| passes 90 together with any
// |horizontal| beyond 90 (a target past the side plane is behind NeckRef for
// both axes), so no target makes the 10-degree correction flip the verdict
// and the correction only matters through the isLimitBreakBackup flag.

/// The captured prefab's seven states (FORWARD, TARGET, AWAY, ANIMATION, FIX,
/// TARGET, AWAY) with their limit-check fields; patterns 1 and 2 carry the
/// TARGET/AWAY values this runtime exercises. The curve is the fixture's real
/// two-key curve, so the transition fraction at t 1/30 is 0.07424433815920793
/// and it clamps to 1 at t 1 (hand-evaluated Hermite, same as the oracle).
private func runtimeSettingsJSON() -> String {
    func aParam(_ h: Float, _ v: Float) -> String {
        "{\"minBendingAngle\":\(-h),\"maxBendingAngle\":\(h),\"upBendingAngle\":\(-v),\"downBendingAngle\":\(v)}"
    }
    func state(_ name: String, _ hLim: Float, _ vLim: Float, _ lbv: Float, _ away: Float,
               _ neckH: Float, _ headH: Float) -> String {
        let a = aParam(neckH, 25) + "," + aParam(headH, 25)
        return "{\"lookType\":{\"name\":\"\(name)\"},\"aParam\":[\(a)],\"leapSpeed\":2,"
            + "\"hAngleLimit\":\(hLim),\"vAngleLimit\":\(vLim),"
            + "\"limitBreakCorrectionValue\":\(lbv),\"limitAway\":\(away)}"
    }
    let states = [
        state("FORWARD", 0, 0, 0, 0, 0, 0),
        state("TARGET", 90, 90, 10, 0, 40, 40),
        state("AWAY", 80, 90, 10, 10, 40, 20),
        state("ANIMATION", 90, 90, 10, 0, 0, 0),
        state("FIX", 90, 90, 10, 0, 0, 0),
        state("TARGET", 180, 180, 10, 0, 40, 40),
        state("AWAY", 180, 180, 10, 0, 40, 20),
    ].joined(separator: ",")
    return """
    {"neck":{"calcLerp":1,"changeTypeLeapTime":1,
    "changeTypeLerpCurve":{"preInfinity":2,"postInfinity":2,"keys":[
      {"inSlope":2.2096142768859863,"outSlope":2.2096142768859863,"time":0,"value":0.002166748046875},
      {"inSlope":0,"outSlope":0,"time":1,"value":1}]},
    "aBones":[{"neckBone":"cf_j_neck"},{"neckBone":"cf_j_head"}],
    "neckTypeStates":[\(states)]}}
    """
}

private func runtimeSettings() throws -> SourceStudioNeckLookSettings {
    try SourceStudioNeckLookSettings(json: Data(runtimeSettingsJSON().utf8))
}

private let identityQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
private let identityD = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

/// Unity-space layout: NeckRef at the chest with identity rotation, its
/// +Z forward; the aim 0.2 above it and 0.1 forward; the camera at distance 5
/// from the aim in the direction yawed `yaw` degrees off +Z, level with the
/// aim. The oracle reports the vertical angle between -10.3 deg (straight
/// ahead) and -36.2 deg (yaw 80), inside the 90 + 10 limits for every yaw
/// this file uses.
private func geometry(yaw: Double) -> SourceStudioNeckLookGeometry {
    let aim = SIMD3<Double>(0, 1.6, 0.1)
    let target = aim + SIMD3<Double>(sin(yaw * .pi / 180), 0, cos(yaw * .pi / 180)) * 5
    return SourceStudioNeckLookGeometry(
        aimPosition: aim, aimRotation: identityD,
        neckRefPosition: SIMD3<Double>(0, 1.4, 0), neckRefRotation: identityD,
        headRotation: identityD, target: target)
}

private func yawOf(_ q: simd_quatf) -> Float { 2 * atan2(q.imag.y, q.real) * 180 / .pi }

@Test func studioNeckLookRuntimeStraightAheadStaysOnIdentity() throws {
    let settings = try runtimeSettings()
    let runtime = try SourceStudioNeckLookRuntime(settings: settings, fixAngle: [identityQ, identityQ])
    #expect(runtime.lastLocalRotations == nil)
    // The first update runs UpdateCall's ANIMATION -> TARGET transition and
    // the solver frame; a straight-ahead target solves to (0, 0) degrees, so
    // the fixAngle pair is identity and the local rotations — slerped from
    // the identity backup toward identity — are identity too.
    try runtime.update(deltaTime: 1 / 30, lookType: .target, pattern: 1,
                       settings: settings, geometry: geometry(yaw: 0))
    #expect(runtime.lookType == .target)
    #expect(!runtime.isLimitBreakBackup)
    let rotations = try #require(runtime.lastLocalRotations)
    #expect(rotations.count == 2)
    for rotation in rotations + runtime.fixAngle {
        #expect(abs(rotation.imag.x) < 1e-6 && abs(rotation.imag.z) < 1e-6)
        #expect(abs(yawOf(rotation)) < 1e-5)
    }
}

@Test func studioNeckLookRuntimeSideTargetDistributesAndSmooths() throws {
    let settings = try runtimeSettings()
    let runtime = try SourceStudioNeckLookRuntime(settings: settings, fixAngle: [identityQ, identityQ])
    try runtime.update(deltaTime: 1 / 30, lookType: .target, pattern: 1,
                       settings: settings, geometry: geometry(yaw: 30))
    // nowAngle is the oracle's (0, 30); the head (bone 1) takes the demand
    // first (pattern 1 bends each bone +-40 deg, so nothing spills) and each
    // bone moves 1/15 of the way (deltaTime 1/30 * leapSpeed 2), so the
    // head's carried yaw is 2 deg and the neck's still 0.
    #expect(abs(yawOf(runtime.fixAngle[1]) - 2) < 1e-4)
    #expect(abs(yawOf(runtime.fixAngle[0])) < 1e-5)
    // The written local rotation still rides the type-change transition:
    // Slerp(identity, yaw 2, num), and slerping from identity adds num of the
    // arc: 2 * 0.07424433815920793 = 0.14849 deg (the hand-evaluated curve).
    let rotations = try #require(runtime.lastLocalRotations)
    #expect(abs(yawOf(rotations[1]) - 2 * 0.07424433815920793) < 1e-4)
    // 400 frames (num clamps to 1 after 30) converge the head's carried yaw
    // onto the whole demand, geometric ratio 14/15 per frame; the neck's
    // share of a 30 deg demand is exactly 0 forever.
    for _ in 0..<400 {
        try runtime.update(deltaTime: 1 / 30, lookType: .target, pattern: 1,
                           settings: settings, geometry: geometry(yaw: 30))
    }
    #expect(abs(yawOf(runtime.fixAngle[1]) - 30) < 1e-3)
    #expect(abs(yawOf(runtime.fixAngle[0])) < 1e-5)
    let written = try #require(runtime.lastLocalRotations)
    #expect(abs(yawOf(written[1]) - 30) < 1e-3)
}

@Test func studioNeckLookRuntimeLimitBreakBackupTracksTheCheck() throws {
    let settings = try runtimeSettings()
    let runtime = try SourceStudioNeckLookRuntime(settings: settings, fixAngle: [identityQ, identityQ])
    for _ in 0..<400 {
        try runtime.update(deltaTime: 1 / 30, lookType: .target, pattern: 1,
                           settings: settings, geometry: geometry(yaw: 30))
    }
    #expect(abs(yawOf(runtime.fixAngle[1]) - 30) < 1e-3)
    // Behind: the oracle reports horizontal 180, broken even with correction
    // 10. nowAngle collapses to (0, 0) and the carried yaw relaxes 1/15 of
    // the way toward 0; the flag is set for the next frame.
    try runtime.update(deltaTime: 1 / 30, lookType: .target, pattern: 1,
                       settings: settings, geometry: geometry(yaw: 180))
    #expect(runtime.isLimitBreakBackup)
    #expect(abs(yawOf(runtime.fixAngle[1]) - 30 * 14 / 15) < 1e-3)
    // An intact frame clears the backup and the demand returns.
    try runtime.update(deltaTime: 1 / 30, lookType: .target, pattern: 1,
                       settings: settings, geometry: geometry(yaw: 30))
    #expect(!runtime.isLimitBreakBackup)
    #expect(abs(yawOf(runtime.fixAngle[1]) - (30 * 14 / 15 * 14 / 15 + 30 / 15)) < 1e-3)
    // Breaking again works the same the second time.
    try runtime.update(deltaTime: 1 / 30, lookType: .target, pattern: 1,
                       settings: settings, geometry: geometry(yaw: 180))
    #expect(runtime.isLimitBreakBackup)
}

@Test func studioNeckLookRuntimeAwayAdjustsOnlyIntactFrames() throws {
    let settings = try runtimeSettings()
    let runtime = try SourceStudioNeckLookRuntime(settings: settings, fixAngle: [identityQ, identityQ])
    // AWAY pattern 2: the oracle maps raw (0, 30) onto y -60 (the minimum
    // bending sum of the aParam pair -40 + -20, and the same -60 whichever
    // angleH the bones carry); head first takes its -20 share, the neck the
    // remaining -40, and x stays 0.
    for _ in 0..<400 {
        try runtime.update(deltaTime: 1 / 30, lookType: .away, pattern: 2,
                           settings: settings, geometry: geometry(yaw: 30))
    }
    #expect(!runtime.isLimitBreakBackup)
    #expect(abs(yawOf(runtime.fixAngle[0]) + 40) < 1e-3)
    #expect(abs(yawOf(runtime.fixAngle[1]) + 20) < 1e-3)
    // Broken (horizontal 180 past 80 + 10): nowAngle collapses to (0, 0) and
    // AWAY's adjustment is skipped along with angleToTarget, so the pair
    // relaxes toward 0 instead of holding -60: the neck's carried yaw is
    // -40 * (14/15)^10 after ten frames.
    for _ in 0..<10 {
        try runtime.update(deltaTime: 1 / 30, lookType: .away, pattern: 2,
                           settings: settings, geometry: geometry(yaw: 180))
    }
    #expect(runtime.isLimitBreakBackup)
    #expect(abs(yawOf(runtime.fixAngle[0]) + 40 * pow(14.0 / 15.0, 10)) < 1e-3)
}

@Test func studioNeckLookRuntimeRejectsForeignInputsAndKeepsState() throws {
    let settings = try runtimeSettings()
    let runtime = try SourceStudioNeckLookRuntime(settings: settings, fixAngle: [identityQ, identityQ])
    // A deltaTime of 0 runs the transition but nothing else: no rotations.
    try runtime.update(deltaTime: 0, lookType: .target, pattern: 1, settings: settings,
                       geometry: geometry(yaw: 30))
    #expect(runtime.lookType == .target)
    #expect(runtime.lastLocalRotations == nil)
    // Non-solver types, patterns outside the document, a negative deltaTime
    // and a foreign settings document (here one state with leapSpeed 1) are
    // rejected.
    #expect(throws: (any Error).self) {
        try runtime.update(deltaTime: 1 / 30, lookType: .fix, pattern: 4, settings: settings,
                           geometry: geometry(yaw: 30))
    }
    #expect(throws: (any Error).self) {
        try runtime.update(deltaTime: 1 / 30, lookType: .target, pattern: 7, settings: settings,
                           geometry: geometry(yaw: 30))
    }
    #expect(throws: (any Error).self) {
        try runtime.update(deltaTime: -1, lookType: .target, pattern: 1, settings: settings,
                           geometry: geometry(yaw: 30))
    }
    let foreign = try SourceStudioNeckLookSettings(json: Data(
        runtimeSettingsJSON().replacingOccurrences(of: "\"leapSpeed\":2", with: "\"leapSpeed\":1").utf8))
    #expect(throws: (any Error).self) {
        try runtime.update(deltaTime: 1 / 30, lookType: .target, pattern: 1, settings: foreign,
                           geometry: geometry(yaw: 30))
    }
    // A written frame survives a later zero-delta frame unchanged.
    try runtime.update(deltaTime: 1 / 30, lookType: .target, pattern: 1, settings: settings,
                       geometry: geometry(yaw: 30))
    let written = try #require(runtime.lastLocalRotations)
    try runtime.update(deltaTime: 0, lookType: .target, pattern: 1, settings: settings,
                       geometry: geometry(yaw: 30))
    #expect(runtime.lastLocalRotations == written)
    // The target sitting on the aim has no angle (the oracle raises too); a
    // broken check short-circuits before angleToTarget, so only the intact
    // frame may raise.
    #expect(throws: (any Error).self) {
        let onAim = SourceStudioNeckLookGeometry(
            aimPosition: SIMD3<Double>(0, 1.6, 0.1), aimRotation: identityD,
            neckRefPosition: SIMD3<Double>(0, 1.4, 0), neckRefRotation: identityD,
            headRotation: identityD, target: SIMD3<Double>(0, 1.6, 0.1))
        try runtime.update(deltaTime: 1 / 30, lookType: .target, pattern: 1, settings: settings, geometry: onAim)
    }
}
