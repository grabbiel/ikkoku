# Source trigonometric IK kernel

`Scene/SourceTrigonometricIK.swift` translates the standalone two-bone position
and rotation solve from the installed `RootMotion.FinalIK.IKSolverTrigonometric`.
It is a source-backed limb kernel with independent numerical verification. It
is not a port of FullBodyBipedIK, the full FinalIK component graph, or CharaStudio's
complete IK behavior.

## Evidence

The authoritative source is selected from
`.local/reverse/managed-recovery/index.json` and its per-type overrides:

- `Assembly-CSharp-firstpass.dll`, SHA-256
  `ca572fff8740bbcd58d549723c80b0088d6676611eae2ab91624f460739aea10`.
- `RootMotion.FinalIK.IKSolverTrigonometric`: initialization, cached bone
  calibration, current bend plane, bend goals, position solve, and rotation solve.
- `RootMotion.QuaTools.RotationToLocalSpace`: rotation-offset multiplication order.
- The installed `UnityEngine.Vector3.op_Equality` member: near-zero comparisons
  use squared distance below `9.9999994E-11f`.

The generated `.local/reverse/ik/trigonometric-reference.json` records selected
solver source hashes and 60 synthetic numerical cases. The separately captured
`vector-equality-evidence.json` hashes the Unity assembly and the narrowly
decompiled equality member. All original source and binary evidence remains in
ignored `.local/`; tracked files contain the native translation and synthetic
oracle generator only.

## Preserved operations

Initialization calibrates each of the first two bones' target-to-local rotation
against the initial bone direction and bend normal. It stores each bone's default
local bend normal, then updates the working bend plane from the current pose
when the two segment directions have a nonzero cross product. Calibration is
retained across subsequent animated poses for a direct chain.

The position update clamps the source position weight to [0, 1], computes current
segment lengths, interpolates the endpoint toward its target, blends the bend
normal, and solves the triangular bend direction using the law of cosines. The
source then interpolates the first-bone direction by the position weight again;
the native implementation preserves these two distinct weight applications.

Assigning the root bone's world rotation propagates through both descendants.
The middle bone is then rotated toward the weighted target using its updated
bend normal, propagating its rotation to the endpoint. Finally, endpoint rotation
is slerped independently toward the requested rotation using the separately
clamped rotation weight. Link lengths remain rigid; targets outside the reachable
region do not stretch the chain.

`setBendGoalPosition` and `setBendPlaneToCurrent` preserve the source's cross-product
ordering, unnormalized bend normals, weight behavior, and zero-vector handling.

## API and assumptions

The API accepts a `Pose` containing root, middle, and endpoint world positions and
unit world rotations. `solve` returns the resulting pose without editing a scene.
The caller provides target position, target rotation, and separate position and
rotation weights.

Inputs and outputs use the native right-handed, Y-up basis. A bend normal is an
**axial vector**: use `UnityCoordinates.axialVector` when importing it from Unity,
rather than the surface-normal or direction conversion. The kernel evaluates
the source equations in the source basis internally and converts the result
back, preventing a second reflection at the caller boundary.

The represented hierarchy consists of three directly linked rigid transforms.
There are no intermediate transforms, nonuniform scales, shears, rotation limits,
muscle constraints, or collision constraints in this kernel's input model. A
source-rig adapter must validate those assumptions before applying it. It must
also turn solved world rotations into local rotations using the actual parent
hierarchy and schedule the solve after animation/customization as appropriate.

The implementation rejects nonfinite inputs, nonunit rotations, zero-length
segments, and LookRotation inputs with no unique orientation. In particular, it
does not invent Unity's native-engine fallback for zero or collinear forward/up
vectors. These are explicit unsupported singular cases, not claimed source
fallback parity. Default-state storage, transform restoration, and the source
solver's indirect-hierarchy reinitialization branch are also outside this API.

## Verification

Five native tests and six Python tests pass. The independent oracle uses world
rotation **matrices**, Rodrigues rotation interpolation, and an eigenvector
matrix-to-quaternion conversion for fixture inputs. It does not invoke the Swift
solver or manufacture expected outputs from its result.

The 60 cases exercise cached calibration under animation, partial/negative/large
weights, reachable and unreachable targets, target-at-root handling, bend goals,
current-plane updates, endpoint rotations, and basis reflection. Native positions
and every rotation-matrix element agree with the oracle within `1e-4`.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/trigonometric_ik_contract.py \
  --recovery-index .local/reverse/managed-recovery/index.json \
  --output .local/reverse/ik/trigonometric-reference.json
.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse -p test_trigonometric_ik_contract.py
IKKOKU_TRIGONOMETRIC_IK_REFERENCE="$PWD/.local/reverse/ik/trigonometric-reference.json" \
  swift test --package-path Packages/Engine --filter sourceTrigonometricIK
```

The remaining full-body work includes the source effector/chain coupling,
spine/body pull and push, mapping constraints, iterative solve order, bend
constraints, and integration with original character rigs and Studio effectors.
Passing this kernel's tests does not establish those systems' compatibility.
