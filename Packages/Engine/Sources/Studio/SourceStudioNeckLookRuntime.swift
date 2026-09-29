import simd
import CoreMath
import Scene

/// One frame's neck geometry for the TARGET/AWAY solver, in the Unity basis
/// (right-handed, +Z forward, centimetres) and in double precision, exactly as
/// the decompiled NeckLookCalcVer2 reads its Transforms in world space. The
/// caller — the Studio preview — evaluates the rig and converts; this type is
/// the boundary that lets the runtime be tested without a rig at all.
public struct SourceStudioNeckLookGeometry: Sendable {
    /// transformAim: the `aim` node under cf_s_head.
    public let aimPosition: SIMD3<Double>
    public let aimRotation: simd_quatd
    /// boneCalcAngle: the `NeckRef` node under cf_s_spine03.
    public let neckRefPosition: SIMD3<Double>
    public let neckRefRotation: simd_quatd
    /// The head's current world rotation, read after the previous frame's
    /// fixAngle write-back (see the capture note in docs/reference/animation/
    /// expression-playback.md: the frame's own head rotation reproduces all
    /// 300 recorded TARGET frames within 0.082 deg).
    public let headRotation: simd_quatd
    /// NeckLookControllerVer2.target with rate 1: the main camera position.
    public let target: SIMD3<Double>

    public init(aimPosition: SIMD3<Double>, aimRotation: simd_quatd,
                neckRefPosition: SIMD3<Double>, neckRefRotation: simd_quatd,
                headRotation: simd_quatd, target: SIMD3<Double>) {
        self.aimPosition = aimPosition; self.aimRotation = aimRotation
        self.neckRefPosition = neckRefPosition; self.neckRefRotation = neckRefRotation
        self.headRotation = headRotation; self.target = target
    }
}

/// Carries the TARGET/AWAY half of NeckLookCalcVer2 across frames: the
/// SourceStudioNeckLook solver state plus the isLimitBreakBackup flag, and
/// runs the per-frame order the original LateUpdate uses — limitCheck on
/// NeckRef, nowAngle 0 when broken otherwise angleToTarget, AWAY's own
/// awayAdjust on intact frames only, then the smoothing step. The rotations
/// stepSolver returns are the local rotations; the last complete pair is kept
/// so the preview can write it onto the pose like FIX/FORWARD does.
public final class SourceStudioNeckLookRuntime {
    private var solver: SourceStudioNeckLook
    private let settings: SourceStudioNeckLookSettings
    /// While set, the limit-check correction reads 0 (the captured broken →
    /// intact phase sequence in expression-playback.md; interpretation, the
    /// decompiled line itself is unrecovered).
    public private(set) var isLimitBreakBackup = false

    /// The solver's carried fixAngle pair (Unity basis): what UpdateCall's
    /// TARGET write-back puts back onto cf_j_neck/cf_j_head before the head
    /// rotation is read.
    public var fixAngle: [simd_quatf] { solver.fixAngle }
    /// The last complete local-rotation pair stepSolver produced, or nil until
    /// a non-zero-deltaTime frame has run (or after a lookType change before
    /// its first written frame). The preview drops a pair it cannot mirror
    /// onto the pose so one malformed write does not fail every later render.
    public internal(set) var lastLocalRotations: [simd_quatf]?
    public var lookType: SourceStudioNeckLookType { solver.lookType }

    /// Seeds the calculator the way a loaded Studio scene finds it: ANIMATION
    /// lookType with the saved fixAngle, so the first update runs the same
    /// UpdateCall type-change transition `applied` uses for FIX/FORWARD.
    public init(settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf]) throws {
        self.settings = settings
        self.solver = try SourceStudioNeckLook(settings: settings, lookType: .animation, fixAngle: fixAngle)
    }

    /// One LateUpdate for the TARGET/AWAY pattern `pattern`, given the frame's
    /// Unity-space geometry. Nothing mutates unless every stage succeeds; a
    /// zero deltaTime still runs the type-change transition but neither the
    /// limit check nor the distribution, as NeckUpdateCalc early-outs then and
    /// the caller keeps the last written rotations. The `settings` must be the
    /// document the runtime was built with; the solver reads its own copy for
    /// aParam and leapSpeed, so a foreign document would split the frame's
    /// limits from its smoothing and is rejected.
    public func update(deltaTime: Float, lookType: SourceStudioNeckLookType,
                       pattern: Int, settings: SourceStudioNeckLookSettings,
                       geometry: SourceStudioNeckLookGeometry) throws {
        guard settings == self.settings else {
            throw RigError.invalid("Neck look runtime needs the settings document it was built with.")
        }
        guard lookType == .target || lookType == .away else {
            throw RigError.invalid("The neck look runtime only drives TARGET and AWAY, not \(lookType.rawValue).")
        }
        guard settings.lookTypes.indices.contains(pattern) else {
            throw RigError.invalid("Neck solver pattern \(pattern) is outside the prefab's \(settings.lookTypes.count) neck states.")
        }
        guard deltaTime.isFinite, deltaTime >= 0 else {
            throw RigError.invalid("Neck look runtime needs a non-negative finite deltaTime.")
        }
        // deltaTime 0: UpdateCall still ran in the original (the type change
        // above), NeckUpdateCalc then returned before reading any Transform.
        if deltaTime == 0 {
            _ = try solver.stepSolver(deltaTime: 0, lookType: lookType, pattern: pattern, nowAngle: (0, 0))
            return
        }
        let correction = isLimitBreakBackup ? 0.0 : Double(settings.limitBreakCorrectionValues[pattern])
        let reference = SourceStudioNeckTargetAngle.Transform(
            position: geometry.neckRefPosition, rotation: geometry.neckRefRotation)
        let check = try SourceStudioNeckTargetAngle.limitCheck(
            target: geometry.target, reference: reference,
            horizontalLimit: Double(settings.hAngleLimits[pattern]),
            verticalLimit: Double(settings.vAngleLimits[pattern]), correction: correction)
        var nowAngle = (x: Double(0), y: Double(0))
        if !check.broken {
            nowAngle = try SourceStudioNeckTargetAngle.angleToTarget(
                target: geometry.target,
                aim: .init(position: geometry.aimPosition, rotation: geometry.aimRotation),
                headRotation: geometry.headRotation, reference: reference)
            if lookType == .away {
                // The bones' angleH before this frame's smoothing, as the
                // original sums them for the AWAY correction.
                nowAngle = try SourceStudioNeckTargetAngle.awayAdjust(
                    nowAngle: nowAngle, boneAngleH: solver.angles.map { Double($0.h) },
                    aParam: settings.bendingLimits[pattern],
                    limitAway: Double(settings.limitAways[pattern]))
            }
        }
        // The angle functions keep double through to here; stepSolver and the
        // original calculator are float, so the pair narrows at this seam.
        let rotations = try solver.stepSolver(deltaTime: deltaTime, lookType: lookType, pattern: pattern,
                                              nowAngle: (Float(nowAngle.x), Float(nowAngle.y)))
        isLimitBreakBackup = check.broken
        if let pair = rotations.allSatisfy({ $0 != nil }) ? rotations.compactMap({ $0 }) : nil { lastLocalRotations = pair }
    }
}
