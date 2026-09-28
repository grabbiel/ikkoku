import Foundation
import simd
import Scene

/// The recovered NeckLookCalcVer2 look modes FORWARD / FIX / ANIMATION with
/// the type-change transition. Every LateUpdate runs UpdateCall(ptnNo) and
/// then NeckUpdateCalc: a lookType change zeroes the transition timer and
/// copies fixAngle into fixAngleBackup, and the per-bone local rotation is
/// then Slerp(fixAngleBackup, target, curve(timer / changeTypeLeapTime)).
/// FORWARD and FIX never read the entry pose because the captured settings
/// keep calcLerp at 1.0, so the slerp lands on fixAngle; ANIMATION writes
/// the animated pose through after MaxRotateToAngle, whose geometric clamp
/// this slice does not model. TARGET and AWAY use the geometric solver and
/// are reported as unsupported here. Quaternions are Unity x,y,z,w with no
/// basis change applied; callers that want the engine basis pass each
/// returned rotation through `UnityCoordinates.rotation` themselves, exactly
/// once. The Python oracle is Tools/reverse/analysis/neck_look_reference.py.
public enum SourceStudioNeckLookType: String, Codable, Sendable, CaseIterable {
    case animation = "ANIMATION"
    case target = "TARGET"
    case away = "AWAY"
    case forward = "FORWARD"
    case fix = "FIX"
}

/// The serialized changeTypeLerpCurve (pre/post infinity 2, clamp to ends)
/// evaluated like Unity AnimationCurve.Evaluate: cubic Hermite on the
/// normalized key segment with tangents outSlope*dt and inSlope*dt.
public struct SourceStudioNeckLookCurve: Decodable, Sendable {
    public struct Key: Decodable, Sendable, Equatable {
        public let time, value, inSlope, outSlope: Float
    }
    public let keys: [Key]

    enum CodingKeys: String, CodingKey { case keys, preInfinity, postInfinity }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keys = try container.decode([Key].self, forKey: .keys)
        let pre = try container.decode(Int.self, forKey: .preInfinity)
        let post = try container.decode(Int.self, forKey: .postInfinity)
        guard keys.count >= 2, keys.sorted(by: { $0.time < $1.time }) == keys,
              pre == 2, post == 2 else {
            throw RigError.invalid("Neck look transition curve needs sorted keys with clamp infinities.")
        }
    }

    /// Unity AnimationCurve.Evaluate; outside the key range the clamp
    /// infinities return the end key values.
    public func evaluate(_ t: Float) throws -> Float {
        guard t.isFinite else { throw RigError.invalid("Neck look curve time must be finite.") }
        if t <= keys[0].time { return keys[0].value }
        if t >= keys[keys.count - 1].time { return keys[keys.count - 1].value }
        for (left, right) in zip(keys, keys.dropFirst()) where left.time <= t && t <= right.time {
            let dt = right.time - left.time
            if dt <= 0 { return right.value }
            let u = (t - left.time) / dt
            let uu = u * u, uuu = uu * u
            let h00 = 2 * uuu - 3 * uu + 1, h10 = uuu - 2 * uu + u
            let h01 = -2 * uuu + 3 * uu, h11 = uuu - uu
            return h00 * left.value + h10 * left.outSlope * dt
                 + h01 * right.value + h11 * right.inSlope * dt
        }
        throw RigError.invalid("Neck look curve time fell outside the sorted keys.")
    }
}

/// The settings JSON subset the look modes need: the neck states' lookType,
/// changeTypeLeapTime, calcLerp, changeTypeLerpCurve and the bone names.
public struct SourceStudioNeckLookSettings: Decodable, Sendable {
    private struct LookType: Decodable { let name: String }
    private struct TypeState: Decodable { let lookType: LookType }
    private struct Bone: Decodable { let neckBone: String }
    private struct Neck: Decodable {
        let neckTypeStates: [TypeState]
        let aBones: [Bone]
        let calcLerp: Float
        let changeTypeLeapTime: Float
        let changeTypeLerpCurve: SourceStudioNeckLookCurve
    }
    private struct Document: Decodable { let neck: Neck }

    /// One lookType per neck state, in saved pattern order.
    public let lookTypes: [SourceStudioNeckLookType]
    /// cf_j_neck and cf_j_head, in the order the calculator reads them.
    public let boneNames: [String]
    public let changeTypeLeapTime: Float
    public let changeTypeLerpCurve: SourceStudioNeckLookCurve

    public init(json data: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: data)
        let neck = document.neck
        // calcLerp 1.0 is what makes FORWARD/FIX ignore the entry pose; a
        // different value would need the entry pose, which this slice does
        // not wire up, so it is a boundary error rather than a silent guess.
        guard neck.calcLerp == 1, neck.changeTypeLeapTime.isFinite, neck.changeTypeLeapTime > 0 else {
            throw RigError.invalid("Neck look settings need calcLerp 1 and a positive changeTypeLeapTime.")
        }
        lookTypes = try neck.neckTypeStates.map { state in
            guard let lookType = SourceStudioNeckLookType(rawValue: state.lookType.name) else {
                throw RigError.invalid("Unknown neck look type '\(state.lookType.name)'.")
            }
            return lookType
        }
        boneNames = neck.aBones.map(\.neckBone)
        guard boneNames.count == 2 else {
            throw RigError.invalid("The neck calculator reads exactly two bones.")
        }
        changeTypeLeapTime = neck.changeTypeLeapTime
        changeTypeLerpCurve = neck.changeTypeLerpCurve
    }
}

/// One NeckLookCalcVer2's state plus the per-frame step. The animated input
/// is the pose the Animator (and Studio FK) left on each bone for that frame;
/// the returned local rotations replace it, in Unity x,y,z,w order.
public struct SourceStudioNeckLook: Sendable {
    /// Unity Quaternion.identity; FORWARD lands on it and the fixture seeds use it.
    static let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    public private(set) var lookType: SourceStudioNeckLookType
    /// changeTypeTimer, reset by UpdateCall on a type change.
    public private(set) var changeTypeTimer: Float
    public private(set) var fixAngle: [simd_quatf]
    public private(set) var fixAngleBackup: [simd_quatf]
    private let settings: SourceStudioNeckLookSettings

    public init(settings: SourceStudioNeckLookSettings, lookType: SourceStudioNeckLookType,
                fixAngle: [simd_quatf], fixAngleBackup: [simd_quatf]? = nil, changeTypeTimer: Float = 0) throws {
        guard fixAngle.count == 2, (fixAngleBackup ?? fixAngle).count == 2,
              changeTypeTimer.isFinite, changeTypeTimer >= 0 else {
            throw RigError.invalid("Neck look state needs two unit bones and a non-negative timer.")
        }
        self.settings = settings
        self.lookType = lookType
        self.changeTypeTimer = changeTypeTimer
        self.fixAngle = fixAngle
        self.fixAngleBackup = fixAngleBackup ?? fixAngle
    }

    /// Unity Quaternion.Slerp: normalized inputs, shortest arc, parameter
    /// clamped to [0, 1], and a normalize-lerp fallback once the arc is too
    /// small for the trigonometric form. Matches the Python reference.
    static func slerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) throws -> simd_quatf {
        guard t.isFinite else { throw RigError.invalid("Neck look slerp parameter must be finite.") }
        func unit(_ q: simd_quatf) throws -> simd_quatf {
            let vector = [q.vector.x, q.vector.y, q.vector.z, q.vector.w]
            guard q.length > 0, vector.allSatisfy(\.isFinite) else {
                throw RigError.invalid("Neck look slerp got a zero or non-finite quaternion.")
            }
            return q.normalized
        }
        let left = try unit(a)
        var right = try unit(b)
        let weight = min(max(t, 0), 1)
        var dot: Float = simd_dot(left.vector, right.vector)
        if dot < 0 { dot = -dot; right = -right }
        let theta0 = acos(min(dot, 1))
        // Float32 cannot represent 1 - 1e-8 (it rounds to 1.0, which would
        // disable this check), so the arc size decides: from 1e-4 rad
        // (about 0.006°) up the trigonometric form is safe, below it
        // sin(theta0) loses too much precision and normalize(lerp) takes
        // over, as in Unity's fallback.
        if theta0 < 1e-4 { return try unit((left * (1 - weight)) + (right * weight)) }
        let sin0 = sin(theta0)
        let sin1 = sin(theta0 * weight)
        let s0: Float = cos(theta0 * weight) - dot * sin1 / sin0
        let s1: Float = sin1 / sin0
        return try unit(left * s0 + right * s1)
    }

    /// UpdateCall(ptnNo) followed by NeckUpdateCalc for one frame. A deltaTime
    /// of 0 skips NeckUpdateCalc entirely, so the animated pose passes
    /// through untouched. TARGET and AWAY throw: the geometric solver is not
    /// simulated. MaxRotateToAngle is out of scope; the animated pose must
    /// already be within its limits.
    public mutating func step(deltaTime: Float, lookType: SourceStudioNeckLookType,
                              animated: [simd_quatf]) throws -> [simd_quatf] {
        guard animated.count == 2, animated.allSatisfy({ $0.length > 0 }) else {
            throw RigError.invalid("Neck look step needs two finite animated rotations.")
        }
        guard deltaTime.isFinite, deltaTime >= 0 else {
            throw RigError.invalid("Neck look step needs a non-negative finite deltaTime.")
        }
        // TARGET/AWAY raise like the reference, before any visible mutation:
        // its raise discards the mutated copy, so the caller's state must
        // stay untouched for a non-zero deltaTime.
        if deltaTime != 0, lookType == .target || lookType == .away {
            throw RigError.invalid("TARGET and AWAY use the geometric solver and are not simulated.")
        }
        if self.lookType != lookType {  // UpdateCall type-change branch
            self.lookType = lookType
            changeTypeTimer = 0
            fixAngleBackup = fixAngle
            // FORWARD also clears angleH/angleV here; only the TARGET/AWAY
            // solver reads them and it is out of scope, so nothing to clear.
        }
        if deltaTime == 0 { return animated }  // NeckUpdateCalc early-out
        changeTypeTimer = min(max(changeTypeTimer + deltaTime, 0), settings.changeTypeLeapTime)
        let num = try settings.changeTypeLerpCurve.evaluate(changeTypeTimer / settings.changeTypeLeapTime)
        var rotations: [simd_quatf] = []
        for bone in 0..<2 {
            let target: simd_quatf
            switch lookType {
            case .forward:
                fixAngle[bone] = Self.identity
                target = fixAngle[bone]
            case .fix:
                target = fixAngle[bone]
            case .animation:
                fixAngle[bone] = animated[bone].normalized
                target = fixAngle[bone]
            case .target, .away:
                target = Self.identity  // unreachable: rejected before any mutation
            }
            // calcLerp 1.0 (boundary-checked in the loader) makes
            // Slerp(animated, fixAngle, calcLerp) land on fixAngle itself.
            rotations.append(try Self.slerp(fixAngleBackup[bone], target, num))
        }
        return rotations
    }
}
