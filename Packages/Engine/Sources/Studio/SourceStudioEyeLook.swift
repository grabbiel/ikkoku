import Foundation
import simd
import Scene

/// The recovered EyeLookCalc.EyeUpdateCalc per-frame eye look solver, in
/// Unity world space and double precision: the target resolution (nearDis
/// push-out for non-TARGET types, the hAngleLimit / vAngleLimit checks that
/// fall over to FORWARD, the forntTagDis point along the frontCorrect's
/// euler-(5,0,0)-rolled forward axis), the trfCenter correct-frame eye target
/// pair, and the per-eye threshold / bendingMultiplier / maxAngleDifference
/// chain with the L/R bending clamp mirroring and the AWAY sorasi branch.
/// Every formula mirrors Tools/reverse/analysis/eye_look_reference.py step
/// for step (the Python oracle, matched by the seeded fixture to 1e-5 deg on
/// angles and 1e-6 on quaternion components), including the Unity Mathf.Lerp
/// / InverseLerp clamping, Vector3.Slerp magnitude behavior and zero-operand
/// collapse, left-handed Quaternion.LookRotation and Math.Sign.  Quaternions
/// are Unity x,y,z,w; `step` returns the eye *local* rotations exactly as the
/// reference predicts them (the writeback `eye.rotation = q2 * eye.rotation`
/// cancels the parent, which only selects the measured direction), so callers
/// that want world orientations multiply by the frame's parent rotation
/// themselves.  AWAY / CONTROL follow the recovered rules, capture misses
/// included — the documented AWAY and CONTROL capture discrepancies are the
/// oracle's behavior, not bugs to fix here.
public enum SourceStudioEyeLookType: String, Codable, Sendable, CaseIterable {
    case noLook = "NO_LOOK"
    case target = "TARGET"
    case away = "AWAY"
    case forward = "FORWARD"
    case control = "CONTROL"
}

/// The settings JSON eyes block the solver reads: the eye type states
/// (threshold / bending / bending-clamp / leap / distance / limit fields and
/// lookType) plus the three frame scalars (correct, centerEyeLength,
/// sorasiRate).  The captured settings keep correct == 1, which selects the
/// trfCenter eye target pair for TARGET / FORWARD; correct == 0 is decoded and
/// solved like the reference does (both eyes aim at the one resolved target).
public struct SourceStudioEyeLookSettings: Decodable, Sendable, Equatable {
    /// The per-eye-type state the frame's pattern selects.  Equatable so a
    /// runtime can pin the document it was built with, like the neck
    /// settings; every field is a Double because the oracle computes the
    /// whole chain in double precision.
    public struct TypeState: Decodable, Sendable, Equatable {
        public let lookType: SourceStudioEyeLookType
        public let thresholdAngleDifference, bendingMultiplier, maxAngleDifference: Double
        public let upBendingAngle, downBendingAngle, minBendingAngle, maxBendingAngle: Double
        public let leapSpeed, forntTagDis, nearDis, hAngleLimit, vAngleLimit: Double

        private enum CodingKeys: String, CodingKey { case lookType }
        private struct LookTypeRecord: Decodable { let name: String }
        private enum LookTypeValue: Decodable {
            case name(String)
            case record(LookTypeRecord)
            init(from decoder: Decoder) throws {
                if let name = try? decoder.singleValueContainer().decode(String.self) {
                    self = .name(name)
                } else {
                    self = .record(try LookTypeRecord(from: decoder))
                }
            }
        }
        private enum NumberKey: String, CodingKey {
            case thresholdAngleDifference, bendingMultiplier, maxAngleDifference
            case upBendingAngle, downBendingAngle, minBendingAngle, maxBendingAngle
            case leapSpeed, forntTagDis, nearDis, hAngleLimit, vAngleLimit
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // The export stores lookType as a {value, name} record; the
            // reference also accepts a bare name, so both decode.
            let name: String
            switch try container.decode(LookTypeValue.self, forKey: .lookType) {
            case .name(let raw): name = raw
            case .record(let record): name = record.name
            }
            guard let lookType = SourceStudioEyeLookType(rawValue: name) else {
                throw RigError.invalid("Unknown eye look type '\(name)'.")
            }
            self.lookType = lookType
            let numbers = try decoder.container(keyedBy: NumberKey.self)
            func value(_ key: NumberKey) throws -> Double {
                let parsed = try numbers.decode(Double.self, forKey: key)
                guard parsed.isFinite else {
                    throw RigError.invalid("Eye type state \(key.rawValue) is not finite.")
                }
                return parsed
            }
            thresholdAngleDifference = try value(.thresholdAngleDifference)
            bendingMultiplier = try value(.bendingMultiplier)
            maxAngleDifference = try value(.maxAngleDifference)
            upBendingAngle = try value(.upBendingAngle)
            downBendingAngle = try value(.downBendingAngle)
            minBendingAngle = try value(.minBendingAngle)
            maxBendingAngle = try value(.maxBendingAngle)
            leapSpeed = try value(.leapSpeed)
            forntTagDis = try value(.forntTagDis)
            nearDis = try value(.nearDis)
            hAngleLimit = try value(.hAngleLimit)
            vAngleLimit = try value(.vAngleLimit)
        }
    }

    /// One `eyeObjs` record: the eyeLR discriminator (0 = L, 1 = R) and the
    /// EyeTarget Transform the calculator walks under that eye.
    public struct EyeObject: Decodable, Sendable, Equatable {
        public let eyeLR: Int
        public let eyeTransform: String
    }

    private struct Eyes: Decodable {
        let correct: Double
        let centerEyeLength: Double
        let sorasiRate: Double
        let eyeTypeStates: [TypeState]
        var rootNode: String?
        var trfCenter: String?
        var headLookVector: SIMD3<Double>?
        var headUpVector: SIMD3<Double>?
        var eyeObjs: [EyeObject]?

        private enum CodingKeys: String, CodingKey {
            case correct, centerEyeLength, sorasiRate, eyeTypeStates
            case rootNode, trfCenter, headLookVector, headUpVector, eyeObjs
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            correct = try container.decode(Double.self, forKey: .correct)
            centerEyeLength = try container.decode(Double.self, forKey: .centerEyeLength)
            sorasiRate = try container.decode(Double.self, forKey: .sorasiRate)
            eyeTypeStates = try container.decode([TypeState].self, forKey: .eyeTypeStates)
            // The Init and per-frame geometry need the node names and the two
            // head vectors, but they stay nil here when a document only
            // carries the solver numbers (the reference's minimal fixture),
            // so their absence is the caller's diagnostic instead of a
            // guessed name or vector.
            rootNode = try container.decodeIfPresent(String.self, forKey: .rootNode)
            trfCenter = try container.decodeIfPresent(String.self, forKey: .trfCenter)
            func vector(_ key: CodingKeys) throws -> SIMD3<Double>? {
                guard let raw = try container.decodeIfPresent([Double].self, forKey: key) else { return nil }
                guard raw.count == 3, raw.allSatisfy(\.isFinite) else {
                    throw RigError.invalid("Eye look settings \(key.rawValue) is not a finite three-component vector.")
                }
                return SIMD3<Double>(raw[0], raw[1], raw[2])
            }
            headLookVector = try vector(.headLookVector)
            headUpVector = try vector(.headUpVector)
            eyeObjs = try container.decodeIfPresent([EyeObject].self, forKey: .eyeObjs)
        }
    }
    private struct Controller: Decodable { let ptnNo: Int32? }
    private struct Document: Decodable {
        let eyes: Eyes
        var eyeController: Controller?
    }

    /// Nonzero selects the trfCenter correct frame for TARGET / FORWARD.
    public let correct: Double
    /// Half-distance of the correct frame's +-x eye target offsets.
    public let centerEyeLength: Double
    /// AWAY sorasi coordinate dead-band.
    public let sorasiRate: Double
    /// One state per eye pattern, in saved order.
    public let eyeTypeStates: [TypeState]
    /// The calculator's rootNode Transform name; the captured prefab keeps
    /// `p_cf_head_bone`, whose world transform equals the head bone's.
    public let rootNode: String?
    /// The correct frame's center Transform name (`cf_J_Eye_tz` in the
    /// capture).
    public let trfCenter: String?
    /// The head-local look/up vectors Init normalizes into each eye's
    /// reference frame.
    public let headLookVector: SIMD3<Double>?
    public let headUpVector: SIMD3<Double>?
    /// The per-eye EyeTarget records, in saved order; the capture walks
    /// EyeTargetL (eyeLR 0) and EyeTargetR (eyeLR 1).
    public let eyeObjs: [EyeObject]?
    /// The sibling prefab EyeLookController.ptnNo, the pattern fallback when
    /// the card Status has no eyesLookPtn.
    public let eyeControllerPattern: Int32?

    private init(eyes: Eyes, eyeControllerPattern: Int32?) throws {
        guard eyes.correct.isFinite, eyes.centerEyeLength.isFinite, eyes.sorasiRate.isFinite else {
            throw RigError.invalid("Eye look settings need finite correct, centerEyeLength and sorasiRate.")
        }
        guard !eyes.eyeTypeStates.isEmpty else {
            throw RigError.invalid("Eye look settings need at least one eyeTypeStates entry.")
        }
        if let eyeObjs = eyes.eyeObjs, Set(eyeObjs.map(\.eyeLR)) != [0, 1] {
            throw RigError.invalid("Eye look settings eyeObjs need exactly one eyeLR 0 and one eyeLR 1.")
        }
        correct = eyes.correct
        centerEyeLength = eyes.centerEyeLength
        sorasiRate = eyes.sorasiRate
        eyeTypeStates = eyes.eyeTypeStates
        rootNode = eyes.rootNode
        trfCenter = eyes.trfCenter
        headLookVector = eyes.headLookVector
        headUpVector = eyes.headUpVector
        eyeObjs = eyes.eyeObjs
        self.eyeControllerPattern = eyeControllerPattern
    }

    public init(json data: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: data)
        try self.init(eyes: document.eyes, eyeControllerPattern: document.eyeController?.ptnNo)
    }

    /// The frame's state for a pattern index.
    public func state(for pattern: Int) throws -> TypeState {
        guard eyeTypeStates.indices.contains(pattern) else {
            throw RigError.invalid("Eye pattern \(pattern) has no eyeTypeStates entry.")
        }
        return eyeTypeStates[pattern]
    }
}

/// The end-of-frame world geometry `step` consumes: the look solver's rootNode
/// and trfCenter transforms (position, Unity x,y,z,w rotation and recorded
/// lossyScale — TransformPoint / InverseTransformPoint go through the scale),
/// plus the two eyes in L/R order with the fixed per-eye reference frame the
/// capture reports.
public struct SourceStudioEyeLookGeometry: Sendable {
    /// A recorded Transform: world position, rotation and lossyScale triple.
    public struct Node: Sendable {
        public let position: SIMD3<Double>
        public let rotation: simd_quatd
        public let lossyScale: SIMD3<Double>

        public init(position: SIMD3<Double>, rotation: simd_quatd, lossyScale: SIMD3<Double>) {
            self.position = position
            self.rotation = rotation
            self.lossyScale = lossyScale
        }
    }
    /// One eye's frame geometry: its world position (the eye's own Transform)
    /// and the fixed origRotation / referenceLookDir / referenceUpDir the
    /// calculator keeps per eye.  Eye order is the writeback order; index 0
    /// is the L eye whose bending clamps apply unmirrored.
    public struct Eye: Sendable {
        public let worldPosition: SIMD3<Double>
        public let origRotation: simd_quatd
        public let referenceLookDir: SIMD3<Double>
        public let referenceUpDir: SIMD3<Double>

        public init(worldPosition: SIMD3<Double>, origRotation: simd_quatd,
                    referenceLookDir: SIMD3<Double>, referenceUpDir: SIMD3<Double>) {
            self.worldPosition = worldPosition
            self.origRotation = origRotation
            self.referenceLookDir = referenceLookDir
            self.referenceUpDir = referenceUpDir
        }
    }

    public let rootNode: Node
    public let trfCenter: Node
    public let eyes: [Eye]

    public init(rootNode: Node, trfCenter: Node, eyes: [Eye]) {
        self.rootNode = rootNode
        self.trfCenter = trfCenter
        self.eyes = eyes
    }
}

/// The per-eye values the solver carries between frames: the smoothed
/// angleH / angleV in degrees and the carried dirUp.
public struct SourceStudioEyeState: Sendable, Equatable {
    public var angleH: Double
    public var angleV: Double
    public var dirUp: SIMD3<Double>

    public init(angleH: Double = 0, angleV: Double = 0, dirUp: SIMD3<Double> = SIMD3<Double>(0, 1, 0)) {
        self.angleH = angleH
        self.angleV = angleV
        self.dirUp = dirUp
    }
}

/// The two-eye solver runtime: carries the per-eye state, advances it one
/// frame with `step`, and exposes the frame's final sorasi coordinate `num5`
/// (frame-local like the transcription: reset to -1 each frame; the AWAY
/// branch arms it on the L eye and the R eye reads it).
public struct SourceStudioEyeLookSolver: Sendable {
    private let settings: SourceStudioEyeLookSettings
    /// The L / R per-eye state, index 0 = left.
    public var eyes: [SourceStudioEyeState]
    /// The frame's final sorasi num5; -1 unless the AWAY branch armed it.
    public private(set) var num5 = -1.0
    /// The last frame's angleHRate pair (L, R) and single angleVRate, each
    /// in [-1, 1] — the values EyeLookMaterialControll shifts the iris
    /// textures by, recomputed by `step` from the frame's new angles (on the
    /// zero-deltaTime frame from the carried ones).  Zero before the first
    /// frame, the original's field default.
    public private(set) var angleHRates: [Double] = [0, 0]
    public private(set) var angleVRate = 0.0

    public init(settings: SourceStudioEyeLookSettings,
                eyes: [SourceStudioEyeState] = [.init(), .init()]) throws {
        guard eyes.count == 2 else {
            throw RigError.invalid("The eye solver needs exactly two eye states.")
        }
        self.settings = settings
        self.eyes = eyes
        _ = try stateValues()
    }

    /// One frame of the recovered EyeUpdateCalc.  `pattern` selects the
    /// eyeTypeStates entry (the original's ptnNo) and `deltaTime == 0` leaves
    /// the angles unchanged and returns nil rotations, as the reference does;
    /// both paths end by recomputing `angleHRates` / `angleVRate` from the
    /// frame's angles and the pattern's type state.  Returns the predicted eye
    /// local rotations (Unity x,y,z,w); the world rotation is the frame's
    /// parent rotation times these, which the caller applies like the
    /// original's writeback.
    public mutating func step(deltaTime: Double, target: SIMD3<Double>,
                              geometry: SourceStudioEyeLookGeometry, pattern: Int) throws
        -> (left: simd_quatd?, right: simd_quatd?) {
        let deltaTime = try Self.checked(deltaTime, "eye deltaTime")
        let previous = try stateValues()
        let state = try settings.state(for: pattern)
        guard deltaTime != 0 else {
            // The original's early return without stepping: the frame-end
            // rates are still recomputed, from the carried angles.
            let rates = try Self.angleRates(eyes: previous, state: state)
            angleHRates = rates.horizontal
            angleVRate = rates.vertical
            return (left: nil, right: nil)
        }
        guard state.lookType != .noLook else {
            throw RigError.invalid("NO_LOOK writes the fixAngle the look trace does not record.")
        }
        guard geometry.eyes.count == 2 else {
            throw RigError.invalid("The eye solver needs exactly two eyes.")
        }
        let root = geometry.rootNode
        _ = try Self.checked(root.position, "eye root position")
        let parent = try Self.checked(root.rotation, "eye parent rotation")
        let (effective, resolved) = try Self.resolveTarget(target: try Self.checked(target, "eye target"),
                                                           root: root, state: state)
        let targets: [SIMD3<Double>]
        if settings.correct != 0, effective == .target || effective == .forward {
            targets = try Self.correctEyeTargets(target: resolved, trfCenter: geometry.trfCenter,
                                                 centerEyeLength: settings.centerEyeLength)
        } else {
            targets = [resolved, resolved]
        }
        let parentInverse = try Self.inverseQuaternion(parent)
        num5 = -1
        var rotations: [simd_quatd?] = [nil, nil]
        for index in geometry.eyes.indices {
            let result = try Self.stepEye(index: index, eye: geometry.eyes[index],
                                          aim: targets[index], effective: effective,
                                          resolved: resolved, previous: previous[index],
                                          state: state, parentInverse: parentInverse,
                                          sorasiRate: settings.sorasiRate,
                                          deltaTime: deltaTime, num5: &num5)
            rotations[index] = result.localRotation
            eyes[index] = SourceStudioEyeState(angleH: result.angleH, angleV: result.angleV,
                                               dirUp: result.dirUp)
        }
        let rates = try Self.angleRates(eyes: eyes, state: state)
        angleHRates = rates.horizontal
        angleVRate = rates.vertical
        return (left: rotations[0], right: rotations[1])
    }

    /// The Init pass the original runs per eye before the first frame: with
    /// q = inverse(eye parent world rotation), referenceLookDir /
    /// referenceUpDir are q * root node rotation applied to the normalized
    /// headLookVector / headUpVector; angleH / angleV start at 0, dirUp takes
    /// the reference up and origRotation the eye's own local rotation.
    /// `eyeLR` (0 = L, 1 = R) is the settings' eyeObjs discriminator and only
    /// slots the outputs, which come back in eyeLR order whatever order the
    /// eyeObjs were walked in.
    public static func initialState(
        rootNodeRotation: simd_quatd,
        eyes: [(parentRotation: simd_quatd, localRotation: simd_quatd, eyeLR: Int)],
        headLookVector: SIMD3<Double>, headUpVector: SIMD3<Double>) throws
        -> (reference: [(lookDir: SIMD3<Double>, upDir: SIMD3<Double>, origRotation: simd_quatd)],
            states: [SourceStudioEyeState]) {
        guard eyes.count == 2, Set(eyes.map(\.eyeLR)) == [0, 1] else {
            throw RigError.invalid("The eye Init needs one eye per eyeLR (0 and 1).")
        }
        let root = try checked(rootNodeRotation, "eye root node rotation")
        var built: [(eyeLR: Int, lookDir: SIMD3<Double>, upDir: SIMD3<Double>,
                     origRotation: simd_quatd)] = []
        for eye in eyes {
            let parentInverse = try inverseQuaternion(
                checked(eye.parentRotation, "eye parent rotation"))
            let base = try multiplyQuaternions(parentInverse, root)
            let lookDir = try rotate(base, normalizeStrict(headLookVector, "headLookVector"))
            let upDir = try rotate(base, normalizeStrict(headUpVector, "headUpVector"))
            built.append((eye.eyeLR, lookDir, upDir,
                          try checked(eye.localRotation, "eye local rotation")))
        }
        built.sort { $0.eyeLR < $1.eyeLR }
        return (reference: built.map { ($0.lookDir, $0.upDir, $0.origRotation) },
                states: built.map { SourceStudioEyeState(angleH: 0, angleV: 0, dirUp: $0.upDir) })
    }

    /// The state the solver validates before a frame: two finite entries.
    private func stateValues() throws -> [SourceStudioEyeState] {
        guard eyes.count == 2,
              eyes.allSatisfy({ state in
                  [state.angleH, state.angleV, state.dirUp.x, state.dirUp.y, state.dirUp.z]
                      .allSatisfy(\.isFinite) }) else {
            throw RigError.invalid("The solver state needs a two-eye finite eyes list.")
        }
        return eyes
    }

    private struct EyeResult {
        let angleH, angleV: Double
        let dirUp: SIMD3<Double>
        let localRotation: simd_quatd
    }

    private static func stepEye(index: Int, eye: SourceStudioEyeLookGeometry.Eye,
                                aim: SIMD3<Double>, effective: SourceStudioEyeLookType,
                                resolved: SIMD3<Double>, previous: SourceStudioEyeState,
                                state: SourceStudioEyeLookSettings.TypeState,
                                parentInverse: simd_quatd, sorasiRate: Double,
                                deltaTime: Double, num5: inout Double) throws -> EyeResult {
        let lookDir = try checked(eye.referenceLookDir, "eye referenceLookDir")
        let upDir = try checked(eye.referenceUpDir, "eye referenceUpDir")
        let orig = try checked(eye.origRotation, "eye origRotation")
        let eyePosition = try checked(eye.worldPosition, "eye world position")
        let aim = effective == .target || effective == .forward ? aim : resolved
        // Unity normalize of a zero difference stays zero and the angle
        // helpers map a zero operand to 0, exactly what the original does
        // when the correct frame places an eye target on the eye pivot.
        let localDirection = try rotate(parentInverse, normalizeOrZero(aim - eyePosition))
        let previousAngle = previous.angleH
        var horizontal = try SourceStudioNeckTargetAngle.angleAroundAxis(lookDir, localDirection, axis: upDir)
        // The vertical measurement is the elevation of the direction out of
        // the plane spanned by refLook and refUp, measured around the axis
        // perpendicular to the direction's own horizontal part (Cross(refUp,
        // dir)), so it reads the sign of the direction's refUp component
        // rather than its azimuth around refLook.
        let verticalMeasurementAxis = simd_cross(upDir, localDirection)
        let verticalAxis = simd_cross(upDir, lookDir)
        let verticalMeasurement = try SourceStudioNeckTargetAngle
            .angleAroundAxis(localDirection - (try project(localDirection, onto: upDir)),
                             localDirection, axis: verticalMeasurementAxis)
        var vertical: Double
        (horizontal, vertical) = try eyeBending(horizontal: horizontal, vertical: verticalMeasurement,
                                                state: state, leftEye: index == 0)
        if effective == .away {
            let sorasi = try sorasiHorizontal(previousAngle: previousAngle, measured: horizontal,
                                              state: state, sorasiRate: sorasiRate, num5: num5)
            horizontal = sorasi.angle
            num5 = sorasi.num5
            vertical = -vertical
        }
        let blend = deltaTime * state.leapSpeed
        let angleH = try lerp(previousAngle, horizontal, t: blend)
        let angleV = try lerp(previous.angleV, vertical, t: blend)
        let look = try rotate(try multiplyQuaternions(angleAxis(angleH, axis: upDir),
                                                     angleAxis(angleV, axis: verticalAxis)), lookDir)
        let tangent = try orthoNormalize(normal: look, tangent: upDir).tangent
        let slerped = try slerpVector(previous.dirUp, tangent, t: deltaTime * 5.0)
        let (normal, carriedUp) = try orthoNormalize(normal: look, tangent: slerped)
        let localRotation = try multiplyQuaternions(
            lookRotation(forward: normal, up: carriedUp),
            try multiplyQuaternions(inverseQuaternion(lookRotation(forward: lookDir, up: upDir)), orig))
        return EyeResult(angleH: angleH, angleV: angleV, dirUp: carriedUp, localRotation: localRotation)
    }

    // MARK: - The recovered target resolution

    /// The nearDis push-out for non-TARGET types, the horizontal / vertical
    /// limit checks over hAngleLimit / vAngleLimit that select FORWARD, and
    /// FORWARD's forntTagDis point along the frontCorrect's forward axis
    /// (rootNode rotation rolled 5 deg about RIGHT).  Returns the effective
    /// type and the resolved target, exactly like the reference.
    static func resolveTarget(target: SIMD3<Double>, root: SourceStudioEyeLookGeometry.Node,
                              state: SourceStudioEyeLookSettings.TypeState) throws
        -> (effective: SourceStudioEyeLookType, target: SIMD3<Double>) {
        let rootPosition = try checked(root.position, "eye root position")
        let rootRotation = try checked(root.rotation, "eye root rotation")
        var resolved = target
        if state.lookType != .target {
            let offset = try checked(resolved - rootPosition, "eye target offset")
            if simd_length(offset) < state.nearDis {
                resolved = rootPosition + normalizeOrZero(offset) * state.nearDis
            }
        }
        let offset = try checked(resolved - rootPosition, "eye target offset")
        let forward = try rotate(rootRotation, SourceStudioNeckTargetAngle.forward)
        let horizontal = try SourceStudioNeckTargetAngle
            .angleDegrees(SIMD3<Double>(offset.x, forward.y, offset.z), forward)
        let vertical = try SourceStudioNeckTargetAngle
            .angleDegrees(SIMD3<Double>(forward.x, offset.y, offset.z), forward)
        var effective = state.lookType
        if horizontal > state.hAngleLimit || vertical > state.vAngleLimit {
            effective = .forward
        }
        if effective == .forward {
            let frontRotation = try multiplyQuaternions(rootRotation,
                                                        angleAxis(5, axis: SourceStudioNeckTargetAngle.right))
            let frontOffset = try rotate(frontRotation, SourceStudioNeckTargetAngle.forward)
            resolved = rootPosition + frontOffset * state.forntTagDis
        }
        return (effective, resolved)
    }

    /// The trfCenter correct frame: the target with its center-space z
    /// clamped to >= 0.5, the front node at that point with rotation
    /// LookRotation(n3, up) for n = normalize(p - center), n2 = normalize
    /// (Cross(up, n)), n3 = normalize(Cross(n2, up)), and its
    /// +-centerEyeLength eye target pair as TransformPoint offsets (the
    /// recorded lossyScale shrinks them, as in the capture).
    static func correctEyeTargets(target: SIMD3<Double>, trfCenter: SourceStudioEyeLookGeometry.Node,
                                  centerEyeLength: Double) throws -> [SIMD3<Double>] {
        let centerEyeLength = try checked(centerEyeLength, "centerEyeLength")
        let position = try checked(trfCenter.position, "correct center position")
        let rotation = try checked(trfCenter.rotation, "correct rotation")
        var local = try worldToLocal(target, node: trfCenter)
        local.z = max(local.z, 0.5)
        let point = try localToWorld(local, position: position, rotation: rotation,
                                     lossyScale: trfCenter.lossyScale)
        let normal = normalizeOrZero(point - position)
        let side = normalizeOrZero(simd_cross(SourceStudioNeckTargetAngle.up, normal))
        guard simd_length(side) > 0 else {
            throw RigError.invalid("the correct target is parallel to the up axis.")
        }
        let plane = normalizeOrZero(simd_cross(side, SourceStudioNeckTargetAngle.up))
        let frameRotation = try lookRotation(forward: plane, up: SourceStudioNeckTargetAngle.up)
        let left = try localToWorld(SIMD3<Double>(-centerEyeLength, 0, 0), position: point,
                                    rotation: frameRotation, lossyScale: trfCenter.lossyScale)
        let right = try localToWorld(SIMD3<Double>(centerEyeLength, 0, 0), position: point,
                                     rotation: frameRotation, lossyScale: trfCenter.lossyScale)
        return [left, right]
    }

    /// Transform.InverseTransformPoint: inverse-rotate the offset, then
    /// divide it by the node's lossyScale.
    static func worldToLocal(_ point: SIMD3<Double>, node: SourceStudioEyeLookGeometry.Node) throws
        -> SIMD3<Double> {
        let origin = try checked(node.position, "world-to-local origin")
        let offset = try checked(point, "world-to-local point") - origin
        let inverse = try inverseQuaternion(try checked(node.rotation, "world-to-local rotation"))
        let factors = try lossyScale(node)
        let rotated = try rotate(inverse, offset)
        return SIMD3<Double>(rotated.x / factors.x, rotated.y / factors.y, rotated.z / factors.z)
    }

    /// Transform.TransformPoint: scale the local offset, rotate it, add the
    /// position.
    static func localToWorld(_ point: SIMD3<Double>, position: SIMD3<Double>, rotation: simd_quatd,
                             lossyScale: SIMD3<Double>) throws -> SIMD3<Double> {
        let factors = [try checked(lossyScale.x, "local-to-world scale"),
                       try checked(lossyScale.y, "local-to-world scale"),
                       try checked(lossyScale.z, "local-to-world scale")]
        let checkedPoint = try checked(point, "local-to-world point")
        let scaled = SIMD3<Double>(checkedPoint.x * factors[0],
                                   checkedPoint.y * factors[1],
                                   checkedPoint.z * factors[2])
        return try rotate(rotation, scaled) + position
    }

    private static func lossyScale(_ node: SourceStudioEyeLookGeometry.Node) throws -> SIMD3<Double> {
        try SIMD3<Double>(checked(node.lossyScale.x, "node lossyScale"),
                          checked(node.lossyScale.y, "node lossyScale"),
                          checked(node.lossyScale.z, "node lossyScale"))
    }

    // MARK: - The recovered per-eye chain

    /// One axis of the recovered chain: the dead-band excess past the
    /// threshold, then max(|excess| * |multiplier|, |angle| -
    /// maxAngleDifference), carrying sign(angle) * sign(multiplier).
    static func bend(angle: Double, threshold: Double, multiplier: Double,
                     maximumDifference: Double) -> Double {
        let excess = max(abs(angle) - threshold, 0)
        return max(excess * abs(multiplier), abs(angle) - maximumDifference)
            * sign(angle) * sign(multiplier)
    }

    /// The recovered per-eye chain: threshold dead-band and bending /
    /// maxAngleDifference on both angles, then the bending clamps — the L eye
    /// uses (minBending, maxBending) directly, the R eye mirrors the
    /// horizontal range to (-maxBending, -minBending); both use
    /// (upBending, downBending) vertically.
    static func eyeBending(horizontal: Double, vertical: Double,
                           state: SourceStudioEyeLookSettings.TypeState, leftEye: Bool) throws
        -> (horizontal: Double, vertical: Double) {
        let horizontal = bend(angle: horizontal, threshold: state.thresholdAngleDifference,
                              multiplier: state.bendingMultiplier,
                              maximumDifference: state.maxAngleDifference)
        let vertical = bend(angle: vertical, threshold: state.thresholdAngleDifference,
                            multiplier: state.bendingMultiplier,
                            maximumDifference: state.maxAngleDifference)
        let horizontalBending = leftEye
            ? try clamp(horizontal, state.minBendingAngle, state.maxBendingAngle)
            : try clamp(horizontal, -state.maxBendingAngle, -state.minBendingAngle)
        let verticalBending = try clamp(vertical, state.upBendingAngle, state.downBendingAngle)
        return (horizontalBending, verticalBending)
    }

    /// The recovered AWAY sorasi branch.  While num5 is the initial -1 the
    /// measured angle's -1..1 sorasi coordinate a7 is compared with the
    /// previous angleH's coordinate a6: within sorasiRate of each other f is
    /// mapped back from a coordinate pushed sorasiRate off a7 (away from it
    /// by the sign of their difference, +sorasiRate when equal), farther
    /// apart f keeps the previous angleH; either way num5 arms to a6's
    /// clamped -1..1 coordinate.  Once armed num5 alone determines f through
    /// the (-maxBending, -minBending) remap.
    static func sorasiHorizontal(previousAngle: Double, measured: Double,
                                 state: SourceStudioEyeLookSettings.TypeState,
                                 sorasiRate: Double, num5: Double) throws
        -> (angle: Double, num5: Double) {
        let previousAngle = try checked(previousAngle, "sorasi angleH")
        let measured = try checked(measured, "sorasi f")
        let num5 = try checked(num5, "sorasi num5")
        let sorasiRate = try checked(sorasiRate, "sorasiRate")
        if num5 != -1 {
            return (try lerp(-state.maxBendingAngle, -state.minBendingAngle, t: num5), num5)
        }
        let a6 = try lerp(-1, 1, t: inverseLerp(-state.maxBendingAngle, -state.minBendingAngle, previousAngle))
        let a7 = try lerp(-1, 1, t: inverseLerp(-state.maxBendingAngle, -state.minBendingAngle, measured))
        let difference = a6 - a7
        if abs(difference) < sorasiRate {
            var pushed: Double
            if difference < 0 {
                pushed = a7 < -sorasiRate ? a7 + sorasiRate : a7 - sorasiRate
            } else if difference > 0 {
                pushed = a7 > sorasiRate ? a7 - sorasiRate : a7 + sorasiRate
            } else {
                pushed = a7 + sorasiRate
            }
            let armed = try inverseLerp(-1, 1, pushed)
            return (try lerp(-state.maxBendingAngle, -state.minBendingAngle, t: armed), armed)
        }
        let armed = try inverseLerp(-1, 1, a6)
        return (previousAngle, armed)
    }

    /// The frame-end angle rates EyeLookCalc computes from the new per-eye
    /// angles and the current pattern's type state (the values
    /// EyeLookMaterialControll shifts the iris textures by).  The L eye reads
    /// (minBending, maxBending) and the R eye mirrors to (-maxBending,
    /// -minBending), each mapped through the rate InverseLerp onto [-1, 1];
    /// the single vertical rate comes from eye 0's angleV: upBending and
    /// downBending swap when down exceeds up (the shipped -30/10 pair takes
    /// that branch), the readout is negated for a non-negative angle.
    static func angleRates(eyes: [SourceStudioEyeState],
                           state: SourceStudioEyeLookSettings.TypeState) throws
        -> (horizontal: [Double], vertical: Double) {
        guard eyes.count == 2 else {
            throw RigError.invalid("The angle rates need a two-eye state list.")
        }
        var horizontal: [Double] = []
        for (index, eye) in eyes.enumerated() {
            let angleH = try checked(eye.angleH, "rate eye \(index) angleH")
            let ratio = index == 1
                ? try rateInverseLerp(-state.maxBendingAngle, -state.minBendingAngle, angleH)
                : try rateInverseLerp(state.minBendingAngle, state.maxBendingAngle, angleH)
            horizontal.append(try lerp(-1, 1, t: ratio))
        }
        let angleV = try checked(eyes[0].angleV, "rate eye 0 angleV")
        let low = min(state.upBendingAngle, state.downBendingAngle)
        let high = max(state.upBendingAngle, state.downBendingAngle)
        let vertical = angleV >= 0
            ? try -rateInverseLerp(0, high, angleV)
            : try rateInverseLerp(0, low, angleV)
        return (horizontal: horizontal, vertical: vertical)
    }

    // MARK: - Unity semantics (the additions the Neck port lacks)

    static func checked(_ value: Double, _ what: String) throws -> Double {
        guard value.isFinite else { throw RigError.invalid("\(what) is not a finite number: \(value).") }
        return value
    }

    static func checked(_ vector: SIMD3<Double>, _ what: String) throws -> SIMD3<Double> {
        guard [vector.x, vector.y, vector.z].allSatisfy(\.isFinite) else {
            throw RigError.invalid("\(what) is not a finite xyz vector: \(vector).")
        }
        return vector
    }

    static func checked(_ quaternion: simd_quatd, _ what: String) throws -> simd_quatd {
        guard [quaternion.imag.x, quaternion.imag.y, quaternion.imag.z, quaternion.real]
            .allSatisfy(\.isFinite) else {
            throw RigError.invalid("\(what) is not a finite xyzw quaternion: \(quaternion).")
        }
        return quaternion
    }

    /// C# Math.Sign: 0 for exactly 0, +-1 otherwise.
    static func sign(_ value: Double) -> Double {
        value > 0 ? 1 : (value < 0 ? -1 : 0)
    }

    static func clamp(_ value: Double, _ low: Double, _ high: Double) throws -> Double {
        guard low <= high else { throw RigError.invalid("clamp range \(low)...\(high) is inverted.") }
        return min(max(value, low), high)
    }

    /// Mathf.Lerp: clamps t to [0, 1].
    static func lerp(_ a: Double, _ b: Double, t: Double) throws -> Double {
        a + (b - a) * (try clamp(checked(t, "lerp t"), 0, 1))
    }

    /// Mathf.InverseLerp: clamps to [0, 1], returns 1 when a == b.
    static func inverseLerp(_ a: Double, _ b: Double, _ value: Double) throws -> Double {
        let a = try checked(a, "inverse-lerp a"), b = try checked(b, "inverse-lerp b")
        let value = try checked(value, "inverse-lerp value")
        if a == b { return 1 }
        return try clamp((value - a) / (b - a), 0, 1)
    }

    /// The rate helper's InverseLerp: Mathf.InverseLerp's clamped 0...1
    /// readout except an empty range (a == b) reads 0, not 1.
    static func rateInverseLerp(_ a: Double, _ b: Double, _ value: Double) throws -> Double {
        let a = try checked(a, "rate inverse-lerp a"), b = try checked(b, "rate inverse-lerp b")
        let value = try checked(value, "rate inverse-lerp value")
        if a == b { return 0 }
        return try clamp((value - a) / (b - a), 0, 1)
    }

    /// Unity Vector3.normalized: the zero vector maps to zero, not an error.
    static func normalizeOrZero(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        let size = simd_length(vector)
        guard size > 0 else { return .zero }
        return vector / size
    }

    private static func normalizeStrict(_ vector: SIMD3<Double>, _ what: String) throws -> SIMD3<Double> {
        let unit = normalizeOrZero(try checked(vector, what))
        guard simd_length(unit) > 0 else {
            throw RigError.invalid("cannot normalize the zero-length \(what).")
        }
        return unit
    }

    /// Unity Vector3.Project(a, normal) = normal * Dot(a, normal) / Dot(normal, normal).
    static func project(_ vector: SIMD3<Double>, onto normal: SIMD3<Double>) throws -> SIMD3<Double> {
        let vector = try checked(vector, "project vector")
        let normal = try checked(normal, "project normal")
        let squared = simd_dot(normal, normal)
        guard squared > 0 else { throw RigError.invalid("cannot project onto a zero-length normal.") }
        return (simd_dot(vector, normal) / squared) * normal
    }

    /// Unity Quaternion.Inverse: conjugate over the squared length.
    static func inverseQuaternion(_ quaternion: simd_quatd) throws -> simd_quatd {
        let q = try checked(quaternion, "inverse quaternion")
        let squared = q.imag.x * q.imag.x + q.imag.y * q.imag.y + q.imag.z * q.imag.z + q.real * q.real
        guard squared > 0 else { throw RigError.invalid("cannot invert a zero quaternion.") }
        return simd_quatd(ix: -q.imag.x / squared, iy: -q.imag.y / squared,
                          iz: -q.imag.z / squared, r: q.real / squared)
    }

    /// Quaternion.LookRotation (Unity left-handed): +z maps to the normalized
    /// forward, +y to the up orthogonalized against it, +x = Cross(y, z);
    /// standard trace-based quaternion extraction of the basis matrix.
    static func lookRotation(forward: SIMD3<Double>, up: SIMD3<Double>) throws -> simd_quatd {
        let z = try normalizeStrict(forward, "look-rotation forward")
        let y = try normalizeStrict(up - (simd_dot(up, z)) * z, "look-rotation up")
        let x = try normalizeStrict(simd_cross(y, z), "look-rotation basis")
        let y2 = simd_cross(z, x)
        // Column-major rotation matrix (x, y, z are its axes), matrix
        // element m[row][col] = axis_col[row].
        let trace = x.x + y2.y + z.z
        let components: (Double, Double, Double, Double)  // x, y, z, w
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            components = ((y2.z - z.y) / s, (z.x - x.z) / s, (x.y - y2.x) / s, 0.25 * s)
        } else if x.x > y2.y && x.x > z.z {
            let s = (1 + x.x - y2.y - z.z).squareRoot() * 2
            components = (0.25 * s, (x.y + y2.x) / s, (z.x + x.z) / s, (y2.z - z.y) / s)
        } else if y2.y > z.z {
            let s = (1 + y2.y - x.x - z.z).squareRoot() * 2
            components = ((x.y + y2.x) / s, 0.25 * s, (y2.z + z.y) / s, (z.x - x.z) / s)
        } else {
            let s = (1 + z.z - x.x - y2.y).squareRoot() * 2
            components = ((z.x + x.z) / s, (y2.z + z.y) / s, 0.25 * s, (x.y - y2.x) / s)
        }
        let size = (components.0 * components.0 + components.1 * components.1
            + components.2 * components.2 + components.3 * components.3).squareRoot()
        guard size > 0 else { throw RigError.invalid("look-rotation produced a zero quaternion.") }
        return simd_quatd(ix: components.0 / size, iy: components.1 / size,
                          iz: components.2 / size, r: components.3 / size)
    }

    /// Vector3.OrthoNormalize (two-vector form): the normal normalized, the
    /// tangent orthogonalized against it and normalized; a parallel tangent
    /// falls back to the least-aligned unit basis vector like Unity.
    static func orthoNormalize(normal: SIMD3<Double>, tangent: SIMD3<Double>) throws
        -> (normal: SIMD3<Double>, tangent: SIMD3<Double>) {
        let unit = try normalizeStrict(normal, "ortho-normalize normal")
        let tangent = try checked(tangent, "ortho-normalize tangent")
        var perpendicular = normalizeOrZero(tangent - (try project(tangent, onto: unit)))
        if simd_length(perpendicular) <= 0 {
            let basis = [SourceStudioNeckTargetAngle.right, SourceStudioNeckTargetAngle.up,
                         SourceStudioNeckTargetAngle.forward]
                .min { abs(simd_dot(unit, $0)) < abs(simd_dot(unit, $1)) }!
            perpendicular = try normalizeStrict(basis - (simd_dot(basis, unit)) * unit,
                                                "ortho-normalize fallback")
        }
        return (unit, perpendicular)
    }

    /// Vector3.Slerp (two-vector overload): the normalized arc scaled by
    /// t*theta with the magnitude lerped; a zero operand collapses to
    /// (1-t)*a; an exact antiparallel pair rotates about a perpendicular
    /// basis axis the way Unity's implementation does.
    static func slerpVector(_ a: SIMD3<Double>, _ b: SIMD3<Double>, t: Double) throws -> SIMD3<Double> {
        let a = try checked(a, "slerp left"), b = try checked(b, "slerp right")
        let t = try clamp(checked(t, "slerp t"), 0, 1)
        let magnitude = simd_length(a), magnitudeB = simd_length(b)
        if magnitude <= 0 || magnitudeB <= 0 {
            return (1 - t) * a
        }
        let unitA = a / magnitude, unitB = b / magnitudeB
        let cosine = try clamp(simd_dot(unitA, unitB), -1, 1)
        let sine = max(0, 1 - cosine * cosine).squareRoot()
        let theta = acos(cosine)
        let unit: SIMD3<Double>
        if sine < 1e-7 {
            if cosine > 0 {
                unit = normalizeOrZero(unitA + t * (unitB - unitA))
            } else {
                var axis = simd_cross(SourceStudioNeckTargetAngle.right, unitA)
                if simd_length(axis) <= 1e-5 { axis = simd_cross(SourceStudioNeckTargetAngle.up, unitA) }
                let rotated = try rotate(try angleAxis(theta * 180 / .pi * t, axis: axis), unitA)
                unit = normalizeOrZero(rotated)
            }
        } else {
            let scaleA = sin((1 - t) * theta) / sine, scaleB = sin(t * theta) / sine
            unit = normalizeOrZero(scaleA * unitA + scaleB * unitB)
        }
        return (magnitude + t * (magnitudeB - magnitude)) * unit
    }

    // The Neck port's quaternion rotate / multiplyQuaternions / angleAxis
    // reuse their internal helpers verbatim (same Unity formulas, double
    // precision); these wrappers exist so the eye solver reads as one file.
    private static func rotate(_ quaternion: simd_quatd, _ vector: SIMD3<Double>) throws -> SIMD3<Double> {
        try SourceStudioNeckTargetAngle.rotate(quaternion, vector)
    }

    private static func multiplyQuaternions(_ left: simd_quatd, _ right: simd_quatd) throws -> simd_quatd {
        try SourceStudioNeckTargetAngle.multiplyQuaternions(left, right)
    }

    private static func angleAxis(_ angle: Double, axis: SIMD3<Double>) throws -> simd_quatd {
        try SourceStudioNeckTargetAngle.angleAxis(angle, axis: axis)
    }
}
