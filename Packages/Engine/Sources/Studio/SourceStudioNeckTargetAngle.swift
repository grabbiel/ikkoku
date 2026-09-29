import Foundation
import simd
import Scene

/// The recovered NeckLookCalcVer2 geometric target angle, in Unity world
/// space and double precision: GetAngleToTarget's (x, y) degrees from the
/// world target, the aim and NeckRef transforms, the head bone's rotation at
/// the start of the frame and NeckRef's limit axes, plus the limit check that
/// zeroes the angle and the AWAY adjustment that collapses the vertical angle
/// onto one of the aParam bending-limit sums and negates the horizontal one.
/// Pure functions over plain positions and Unity x,y,z,w quaternions — no rig
/// access, no per-frame state; the caller wires the live camera target, the
/// per-frame head rotation and the bones' pre-smoothing angleH themselves.
/// Every formula mirrors Tools/reverse/analysis/neck_target_angle.py (the
/// Python oracle, matched by the seeded fixture to 1e-6 deg), including
/// Unity's clamped-acos Vector3.Angle and shortest-arc Quaternion.
/// FromToRotation, whose antiparallel fallback rotates 180 deg about
/// Cross(RIGHT, from) (Cross(UP, from) when that degenerates).
public enum SourceStudioNeckTargetAngle {
    /// A Unity world transform: NeckRef / aim position plus x,y,z,w rotation.
    public struct Transform: Sendable {
        public let position: SIMD3<Double>
        public let rotation: simd_quatd

        public init(position: SIMD3<Double>, rotation: simd_quatd) {
            self.position = position
            self.rotation = rotation
        }
    }

    static let forward = SIMD3<Double>(0, 0, 1)
    static let up = SIMD3<Double>(0, 1, 0)
    static let right = SIMD3<Double>(1, 0, 0)

    // MARK: - Boundary validation

    private static func checked(_ vector: SIMD3<Double>, _ what: String) throws -> SIMD3<Double> {
        guard [vector.x, vector.y, vector.z].allSatisfy(\.isFinite) else {
            throw RigError.invalid("\(what) is not a finite xyz vector: \(vector)")
        }
        return vector
    }

    private static func checked(_ quaternion: simd_quatd, _ what: String) throws -> simd_quatd {
        guard [quaternion.imag.x, quaternion.imag.y, quaternion.imag.z, quaternion.real]
            .allSatisfy(\.isFinite) else {
            throw RigError.invalid("\(what) is not a finite xyzw quaternion: \(quaternion)")
        }
        return quaternion
    }

    // MARK: - Vector / quaternion arithmetic

    /// Unity Quaternion.RotateVector on a unit-normalized quaternion (q * v).
    static func rotate(_ quaternion: simd_quatd, _ vector: SIMD3<Double>) throws -> SIMD3<Double> {
        let q = try checked(quaternion, "rotate quaternion")
        let v = try checked(vector, "rotate vector")
        let size = (q.imag.x * q.imag.x + q.imag.y * q.imag.y + q.imag.z * q.imag.z + q.real * q.real).squareRoot()
        guard size > 0 else { throw RigError.invalid("cannot rotate by a zero quaternion.") }
        let x = q.imag.x / size, y = q.imag.y / size, z = q.imag.z / size, w = q.real / size
        // v + w * t + Cross(q.xyz, t), t = 2 * Cross(q.xyz, v).
        let t = 2 * simd_cross(SIMD3<Double>(x, y, z), v)
        return v + w * t + simd_cross(SIMD3<Double>(x, y, z), t)
    }

    /// Unity Quaternion operator * (left * right): apply right first, then left.
    static func multiplyQuaternions(_ left: simd_quatd, _ right: simd_quatd) throws -> simd_quatd {
        let a = try checked(left, "quaternion left"), b = try checked(right, "quaternion right")
        return simd_quatd(
            ix: a.real * b.imag.x + a.imag.x * b.real + a.imag.y * b.imag.z - a.imag.z * b.imag.y,
            iy: a.real * b.imag.y - a.imag.x * b.imag.z + a.imag.y * b.real + a.imag.z * b.imag.x,
            iz: a.real * b.imag.z + a.imag.x * b.imag.y - a.imag.y * b.imag.x + a.imag.z * b.real,
            r: a.real * b.real - a.imag.x * b.imag.x - a.imag.y * b.imag.y - a.imag.z * b.imag.z)
    }

    /// Unity Vector3.Angle: unsigned angle in degrees, 0 for a zero operand.
    static func angleDegrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) throws -> Double {
        let left = try checked(a, "angle left"), right = try checked(b, "angle right")
        let leftLength = simd_length(left), rightLength = simd_length(right)
        if leftLength <= 1e-5 || rightLength <= 1e-5 { return 0 }
        let cosine = simd_dot(left, right) / (leftLength * rightLength)
        return acos(min(1, max(-1, cosine))) * 180 / .pi
    }

    /// The recovered AngleAroundAxis: the projected vectors' unsigned angle,
    /// negated when Dot(axis, Cross(a, b)) is negative (Unity Vector3.
    /// SignedAngle handedness, left-handed Unity space).
    public static func angleAroundAxis(_ a: SIMD3<Double>, _ b: SIMD3<Double>, axis: SIMD3<Double>) throws -> Double {
        func project(_ vector: SIMD3<Double>, onto normal: SIMD3<Double>) throws -> SIMD3<Double> {
            let squared = simd_dot(normal, normal)
            guard squared > 0 else { throw RigError.invalid("cannot project onto a zero-length normal.") }
            return (simd_dot(vector, normal) / squared) * normal
        }
        let axis = try checked(axis, "angle-around axis")
        let left = try checked(a, "angle-around left")
        let right = try checked(b, "angle-around right")
        let projectedLeft = left - (try project(left, onto: axis))
        let projectedRight = right - (try project(right, onto: axis))
        let signed = simd_dot(axis, simd_cross(projectedLeft, projectedRight)) < 0 ? -1.0 : 1.0
        return try angleDegrees(projectedLeft, projectedRight) * signed
    }

    /// Unity Quaternion.AngleAxis: right-hand rule about the axis, in degrees.
    static func angleAxis(_ angle: Double, axis: SIMD3<Double>) throws -> simd_quatd {
        let unit = try normalize(checked(axis, "angle-axis axis"), what: "angle-axis axis")
        let half = angle * .pi / 360
        return simd_quatd(ix: unit.x * sin(half), iy: unit.y * sin(half), iz: unit.z * sin(half), r: cos(half))
    }

    private static func normalize(_ vector: SIMD3<Double>, what: String) throws -> SIMD3<Double> {
        let size = simd_length(vector)
        guard size > 0 else { throw RigError.invalid("cannot normalize the zero-length \(what).") }
        return vector / size
    }

    /// Unity Quaternion.FromToRotation: shortest arc taking one direction to
    /// another; antiparallel pairs rotate 180 deg about Cross(RIGHT, from),
    /// falling back to Cross(UP, from) when the source points along RIGHT.
    public static func fromToRotation(from: SIMD3<Double>, to: SIMD3<Double>) throws -> simd_quatd {
        let a = try normalize(try checked(from, "from-to source"), what: "from-to source")
        let b = try normalize(try checked(to, "from-to target"), what: "from-to target")
        let alignment = simd_dot(a, b)
        if alignment > 1 - 1e-6 { return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) }
        if alignment < -1 + 1e-6 {
            var axis = simd_cross(right, a)
            if simd_length(axis) <= 1e-5 { axis = simd_cross(up, a) }
            return try angleAxis(180, axis: axis)
        }
        let perpendicular = simd_cross(a, b)
        return simd_quatd(ix: perpendicular.x, iy: perpendicular.y, iz: perpendicular.z, r: 1 + alignment).normalized
    }

    // MARK: - The target angle

    /// The recovered limit check before GetAngleToTarget's angle is kept:
    /// `broken` is true when the signed target angle about NeckRef's up or
    /// right axis exceeds its limit plus the correction (the caller passes
    /// correction 0 while the state is limit-break backup).  Returns the two
    /// signed angles alongside, exactly as the probe reported them.
    public static func limitCheck(target: SIMD3<Double>, reference: Transform,
                                  horizontalLimit: Double, verticalLimit: Double,
                                  correction: Double) throws
        -> (broken: Bool, horizontal: Double, vertical: Double) {
        let target = try checked(target, "limit target")
        let referencePosition = try checked(reference.position, "limit reference position")
        let rotation = try checked(reference.rotation, "limit reference rotation")
        guard [horizontalLimit, verticalLimit, correction].allSatisfy(\.isFinite) else {
            throw RigError.invalid("limit check needs finite limits and correction.")
        }
        let offset = target - referencePosition
        let upAxis = try rotate(rotation, up)
        let rightAxis = try rotate(rotation, right)
        let forwardAxis = try rotate(rotation, forward)
        let horizontal = try angleAroundAxis(forwardAxis, offset, axis: upAxis)
        let vertical = try angleAroundAxis(forwardAxis, offset, axis: rightAxis)
        let broken = abs(horizontal) > horizontalLimit + correction || abs(vertical) > verticalLimit + correction
        return (broken, horizontal, vertical)
    }

    /// The recovered GetAngleToTarget, as (x, y) degrees: swing rotates the
    /// aim's forward onto the target offset, the head rotation rides along
    /// under that swing (q2 = swing * headRotation), y is NeckRef-up-referenced
    /// and x the pitch-like angle about Cross(up, rolled-forward) after
    /// rolling NeckRef forward by y.  A target sitting on the aim origin has
    /// no defined angle and is a boundary error, as in the oracle.
    public static func angleToTarget(target: SIMD3<Double>, aim: Transform,
                                     headRotation: simd_quatd, reference: Transform) throws
        -> (x: Double, y: Double) {
        let headRotation = try checked(headRotation, "head rotation")
        let aimPosition = try checked(aim.position, "aim position")
        _ = try checked(aim.rotation, "aim rotation")  // rotate() re-reads it as a boundary check
        let offset = try checked(target, "target position") - aimPosition
        _ = try checked(reference.position, "reference position")  // validated, the angle reads only axes
        guard simd_length(offset) > 1e-5 else {
            throw RigError.invalid("the target sits on the aim origin, the angle is undefined.")
        }
        let swing = try fromToRotation(from: rotate(aim.rotation, forward), to: offset)
        let swungHead = try multiplyQuaternions(swing, headRotation)
        let upAxis = try rotate(reference.rotation, up)
        let forwardAxis = try rotate(reference.rotation, forward)
        let y = try angleAroundAxis(forwardAxis, rotate(swungHead, forward), axis: upAxis)
        let rolled = try multiplyQuaternions(angleAxis(y, axis: upAxis), reference.rotation)
        let axis = simd_cross(upAxis, try rotate(rolled, forward))
        let x = try angleAroundAxis(rotate(rolled, forward), rotate(swungHead, forward), axis: axis)
        return (x, y)
    }

    /// The recovered AWAY adjustment applied to the raw (unlimited) nowAngle,
    /// only when the limit check is intact.  `boneAngleH` are the bones'
    /// angleH before this frame's smoothing; the vertical angle collapses
    /// onto the minimum-bending sum when the target looks past it (or the raw
    /// angle already bends the other way on the other side of the bones) and
    /// onto the maximum-bending sum otherwise, and the horizontal angle is
    /// negated.  The bending limits are the state's aParam; Float widens to
    /// Double exactly, so the sums match the oracle bit for bit.
    public static func awayAdjust(nowAngle: (x: Double, y: Double), boneAngleH: [Double],
                                  aParam: [SourceStudioNeckLookSettings.BendingLimits],
                                  limitAway: Double) throws -> (x: Double, y: Double) {
        guard [nowAngle.x, nowAngle.y].allSatisfy(\.isFinite) else {
            throw RigError.invalid("away-adjust nowAngle needs two finite degrees.")
        }
        guard !boneAngleH.isEmpty, boneAngleH.allSatisfy(\.isFinite) else {
            throw RigError.invalid("away-adjust needs finite per-bone angleH values.")
        }
        guard !aParam.isEmpty,
              aParam.allSatisfy({ Double($0.minBendingAngle).isFinite && Double($0.maxBendingAngle).isFinite })
        else {
            throw RigError.invalid("away-adjust needs the aParam bending limits.")
        }
        guard limitAway.isFinite else { throw RigError.invalid("away-adjust limitAway is not finite.") }
        let limitAway = Double(limitAway)
        let horizontalBones = boneAngleH.reduce(0, +)
        let maximumBending = aParam.reduce(0) { $0 + Double($1.maxBendingAngle) }
        let minimumBending = aParam.reduce(0) { $0 + Double($1.minBendingAngle) }
        var y = nowAngle.y
        if y <= horizontalBones {
            y = y <= maximumBending - limitAway || y < 0 ? maximumBending : minimumBending
        } else {
            y = y >= minimumBending + limitAway || y > 0 ? minimumBending : maximumBending
        }
        return (-nowAngle.x, y)
    }
}
