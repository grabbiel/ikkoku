import simd
import CoreMath
import Scene

/// Carries one EyeLookCalc across Studio preview frames: the solver state
/// (per-eye angleH / angleV / dirUp plus the frame rates), the fixed Init
/// reference the original computes once per eye, and the last predicted eye
/// local rotations. The caller — the Studio preview — evaluates the rig and
/// builds the frame's `SourceStudioEyeLookGeometry`; this type is the boundary
/// that lets the runtime be tested without a rig at all.
public final class SourceStudioEyeLookRuntime {
    /// One eye's Init input, in eyeObjs (L, R) order: the world rotation of
    /// its cf_J_Eye_tx parent and the eye target's own local rotation.
    public struct EyeParent {
        public let rotation: simd_quatd
        public let localRotation: simd_quatd
        public init(rotation: simd_quatd, localRotation: simd_quatd) {
            self.rotation = rotation; self.localRotation = localRotation
        }
    }

    private var solver: SourceStudioEyeLookSolver
    private let settings: SourceStudioEyeLookSettings
    /// The per-eye Init reference (lookDir, upDir, origRotation) in L/R order,
    /// exactly as `initialState` built it; the solver steps keep their own
    /// carried dirUp, this is the fixed frame Init recorded.
    public let reference: [(lookDir: SIMD3<Double>, upDir: SIMD3<Double>, origRotation: simd_quatd)]
    /// The last rotations pair `step` returned, or nil until a non-zero
    /// deltaTime frame has run. The iris writeback of the next slice mirrors
    /// these onto the eye bones; nothing writes bones yet.
    public private(set) var lastRotations: (left: simd_quatd?, right: simd_quatd?)?

    /// The last frame's angleHRate pair (L, R) and angleVRate in [-1, 1] —
    /// what EyeLookMaterialControll would shift the iris textures by.
    public var angleHRates: [Double] { solver.angleHRates }
    public var angleVRate: Double { solver.angleVRate }
    /// The solver's carried per-eye state (angleH / angleV degrees, dirUp).
    public var eyes: [SourceStudioEyeState] { solver.eyes }

    /// Inits the calculator the way a loaded scene finds it: the Init pass
    /// against the root node's current world rotation, then the saved eye
    /// angles (the scene's angleH / angleV pairs, absent before scene version
    /// 0.0.8) replace the Init zeros while dirUp keeps the Init frame, which
    /// is the only reading the fix bytes support.
    public init(settings: SourceStudioEyeLookSettings,
                rootRotation: simd_quatd,
                eyeParents: [EyeParent],
                savedAngles: (horizontal: [Double], vertical: [Double])? = nil) throws {
        guard eyeParents.count == 2 else {
            throw RigError.invalid("The eye look runtime needs exactly two eye parents (L, R).")
        }
        guard let headLookVector = settings.headLookVector, let headUpVector = settings.headUpVector else {
            throw RigError.invalid("The eye look settings carry no headLookVector / headUpVector to Init from.")
        }
        if let savedAngles {
            guard savedAngles.horizontal.count == 2, savedAngles.vertical.count == 2,
                  savedAngles.horizontal.allSatisfy(\.isFinite), savedAngles.vertical.allSatisfy(\.isFinite) else {
                throw RigError.invalid("Saved eye angles need two finite angleH and two finite angleV values.")
            }
        }
        let (reference, states) = try SourceStudioEyeLookSolver.initialState(
            rootNodeRotation: rootRotation,
            eyes: eyeParents.enumerated().map { (index, parent) in
                (parentRotation: parent.rotation, localRotation: parent.localRotation, eyeLR: index)
            },
            headLookVector: headLookVector, headUpVector: headUpVector)
        var solver = try SourceStudioEyeLookSolver(settings: settings, eyes: states)
        if let savedAngles {
            solver.eyes = states.enumerated().map { (index, state) in
                var state = state
                state.angleH = savedAngles.horizontal[index]
                state.angleV = savedAngles.vertical[index]
                return state
            }
        }
        self.settings = settings
        self.reference = reference
        self.solver = solver
    }

    /// One EyeUpdate frame for pattern `pattern`, aiming at `target`, over the
    /// frame's Unity-basis geometry. A zero deltaTime leaves the angles
    /// unchanged and reports no rotations, as the reference early-return
    /// does, but still refreshes the frame rates from the carried angles; the
    /// `settings` must be the document the runtime was built with. NO_LOOK
    /// throws — its fixAngle write is not recorded by the look trace — so the
    /// caller reports it and keeps the animated eyes.
    public func update(deltaTime: Double, target: SIMD3<Double>,
                       geometry: SourceStudioEyeLookGeometry, pattern: Int) throws {
        let state = try settings.state(for: pattern)
        guard deltaTime.isFinite, deltaTime >= 0 else {
            throw RigError.invalid("Eye look runtime needs a non-negative finite deltaTime.")
        }
        let rotations = try solver.step(deltaTime: deltaTime, target: target,
                                        geometry: geometry, pattern: pattern)
        if state.lookType != .noLook, rotations.left != nil, rotations.right != nil {
            lastRotations = rotations
        }
    }
}
