import Foundation
import simd
import CoreMath
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

    /// The first-frame clock advance. NeckUpdateCalc early-outs on a zero
    /// deltaTime, which would pass the animated pose through even for FIX, so
    /// a fresh preview showing elapsed 0 uses this tiny positive step instead
    /// and FIX already lands on the saved rotation. FORWARD is unaffected: at
    /// this size the transition curve is still at its clamped first key.
    static let firstFrameDelta: Float = 1e-5

    /// Applies one NeckLookCalcVer2 override to a posed character: seeds the
    /// calculator with the saved `fixAngle` and an ANIMATION entry type (what
    /// ChaControl init leaves behind), steps once by `elapsed`, and writes the
    /// two resulting local rotations onto `settings.boneNames`, converting each
    /// to the engine basis exactly once and keeping each bone's current
    /// translation and scale. The animated input is never read for FIX or
    /// FORWARD (calcLerp 1 lands the slerp on fixAngle), so it is not passed in.
    /// ANIMATION, TARGET and AWAY leave the pose untouched (the animated pose is
    /// already there / the gaze solver is unwired), and an active Studio FK
    /// neck group owns the neck, so both return without writing.
    @discardableResult
    public static func applied(pose: inout RigPose, rig: RigDefinition, settings: SourceStudioNeckLookSettings,
                               fixAngle: [simd_quatf], lookType: SourceStudioNeckLookType, elapsed: Float,
                               neckFKActive: Bool) throws -> SourceStudioNeckLookOverride.Applied {
        guard lookType == .fix || lookType == .forward else { return .none }
        guard !neckFKActive else { return .none }
        guard elapsed.isFinite, elapsed >= 0 else { throw RigError.invalid("Neck look override needs a finite non-negative clock time.") }
        var state = try SourceStudioNeckLook(settings: settings, lookType: .animation, fixAngle: fixAngle)
        let deltaTime = elapsed == 0 ? firstFrameDelta : elapsed
        let identity = Self.identity
        let rotations = try state.step(deltaTime: deltaTime, lookType: lookType, animated: [identity, identity])
        for (bone, name) in settings.boneNames.enumerated() {
            let node = try rig.uniqueNode(named: name)
            let matrix = pose.localMatrices[node]
            let x = Float3(matrix[0].x, matrix[0].y, matrix[0].z)
            let y = Float3(matrix[1].x, matrix[1].y, matrix[1].z)
            let z = Float3(matrix[2].x, matrix[2].y, matrix[2].z)
            let scale = Float3(simd_length(x), simd_length(y), simd_length(z))
            guard (0..<3).allSatisfy({ scale[$0].isFinite && scale[$0] > 1e-8 }) else {
                throw RigError.invalid("Neck look override cannot read a singular local scale for '\(name)'.")
            }
            pose.localMatrices[node] = Transform.trs(Float3(matrix[3].x, matrix[3].y, matrix[3].z),
                                                     UnityCoordinates.rotation(rotations[bone]), scale)
        }
        return lookType == .fix ? .fix : .forward
    }
}

/// The single resolution of the effective neck pattern to the preview override
/// the look controller can actually apply, shared by the Studio preview
/// (SourceStudioCharacterPreview) and `ikkoku-inspect look-data` so both report
/// one source of truth. Data only: it runs no solver, evaluates no curve and
/// reads no clock; it maps the pattern to its lookType and explains, in one
/// reason string, why the override applies or is deferred to the animated pose.
public enum SourceStudioNeckLookOverride {
    public enum Applied: String, Codable, Sendable, Equatable {
        case fix = "FIX", forward = "FORWARD", none = "none"
    }
    public struct Resolution: Sendable, Equatable {
        /// The pattern's lookType, or nil when no single pattern resolves (no
        /// settings, no saved pattern, a pattern outside the prefab's states,
        /// or unreadable saved neck bytes).
        public let lookType: SourceStudioNeckLookType?
        public let applied: Applied
        public let reason: String
    }

    /// Resolves `effectivePattern` (the card neckLookPtn wins over the saved
    /// neck bytes' ptnNo - see SourceStudioLookData.effectiveNeckPattern)
    /// against the prefab settings. `savedBoneCount` is the number of
    /// quaternions in the decoded saved neck bytes, or nil when those bytes did
    /// not decode. The calculator reads exactly two bones.
    public static func resolve(effectivePattern: Int32?, settings: SourceStudioNeckLookSettings?, savedBoneCount: Int?) -> Resolution {
        guard let settings else {
            return Resolution(lookType: nil, applied: .none, reason: "Neck look settings are not configured; the neck look override is disabled and the animated pose is kept.")
        }
        guard let pattern = effectivePattern else {
            return Resolution(lookType: nil, applied: .none, reason: "No saved neck pattern is present; the animated pose is kept.")
        }
        guard settings.lookTypes.indices.contains(Int(pattern)) else {
            return Resolution(lookType: nil, applied: .none, reason: "Effective neck pattern \(pattern) is outside the prefab's \(settings.lookTypes.count) neck states; the animated pose is kept.")
        }
        let lookType = settings.lookTypes[Int(pattern)]
        guard savedBoneCount == settings.boneNames.count else {
            let count = savedBoneCount.map(String.init) ?? "unreadable"
            return Resolution(lookType: lookType, applied: .none, reason: "Saved neck bytes hold \(count) bones but the calculator reads \(settings.boneNames.count); the animated pose is kept.")
        }
        switch lookType {
        case .fix:
            return Resolution(lookType: lookType, applied: .fix, reason: "FIX holds the saved neck rotation.")
        case .forward:
            return Resolution(lookType: lookType, applied: .forward, reason: "FORWARD returns the neck toward the camera along the transition curve.")
        case .target, .away:
            return Resolution(lookType: lookType, applied: .none, reason: "Neck gaze solver pending; animated pose kept.")
        case .animation:
            return Resolution(lookType: lookType, applied: .none, reason: "ANIMATION keeps the animated neck pose.")
        }
    }
}
