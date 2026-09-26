# Studio full-body IK and original guide editing

Reviewed 2026-09-25 against the working tree. The [Studio audit](../../component-audit/studio.md) is the feature-status and actionable-backlog index; this page records the narrower source contract and its evidence.

Schema-2 `SourceStudioIK` bindings execute the recovered five-chain biped solver
in Swift. The implementation includes proximal/body coupling, iterative child
constraints, effector planes, spine mapping, clavicle swing and head rotation
preservation. The numerical reference compiles unchanged recovered C# with an
independent Unity math/Transform host; it is not an original Unity-player test.

## Source recovery

`Tools/reverse/analysis/studio_ik_bindings.py` extracts the original
FullBodyBipedIK component from `oo_base.unity3d`. It records the bundle SHA-256,
component PathID, exact transform identities, five chains, nine effectors, four
cross-body constraints, pelvis/spine/neck mapping, head mapping and limb parents.
The actual prefab has four solver iterations and three spine-mapping iterations.
Names are checked alongside source IDs; ambiguous bindings are rejected.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/studio_ik_bindings.py \
  .local/reverse/rigs/source/abdata/chara/oo_base.unity3d \
  --output .local/reverse/studio-pose/ik-bindings.json
```

Original Studio target numbers remain distinct from saved object dictionary keys:

| Target numbers | Role | Activation group |
| --- | --- | --- |
| 0 | Body | Body |
| 1, 2, 3 | Shoulder, elbow/pole, hand | Left arm |
| 4, 5, 6 | Shoulder, elbow/pole, hand | Right arm |
| 7, 8, 9 | Thigh, knee/pole, foot | Left leg |
| 10, 11, 12 | Thigh, knee/pole, foot | Right leg |

Only hands and feet accept rotation. Source `IKCtrl.InitTargetCoroutine` calls
`IKInfo.CopyBone`: missing guide values initialize from pelvis/limb transforms,
not the zeroed prefab guide placeholders. The adapter captures its supplied
initialization pose and keeps those fallback targets fixed relative to the
character across animation samples. It does not simulate the coroutine's frame
wait; the host supplies the intended pose at initialization.

## Solve and mapping order

Each evaluation starts from explicit poses rather than accumulating prior preview
writes. `SourceStudioIK(rig:bindings:initializationPose:)` takes the customization
pose used for initial bend directions and shoulder swing axes. `apply` receives
the current animated/FK baseline plus saved targets, active groups and overrides.
Scene integration samples animation first, reconstructs source activation/FK with
the edited state, then solves IK and evaluates attachments from the resulting pose.

The translated stages are:

1. SetToTarget, sequential left/right hand PullBody and source spine stiffness.
2. Bend-plane limiting, effector offsets/child positions, frame bone lengths and
   mapping-plane reads.
3. End effector updates, Push, Reach, proximal/body effector updates,
   trigonometric solve, Stage1 forward reach, proximal/body updates, Stage2
   backward reach and cross-body/root distance constraints per iteration.
4. Final end effector/bend goal solve, including relative plane rotation offsets
   and the original zero-iteration body-offset branch.
5. Spine FABRIK, twist and plane mapping; head maintain-rotation; clavicle swing;
   limb plane mapping, distal maintain-rotation and effector rotation.

Positive nonuniform local scales are supported. World positions use hierarchical
TRS matrices; world rotations compose quaternions separately from affine scale.
Signed solver-parent scales, authored local shear and zero-length segments are
rejected. Unrelated mirrored accessory transforms are retained unchanged.
Schema-1 contracts retain the old bounded limb fallback and its explicit coverage
diagnostics; regenerate bindings to enable full-body stages.

## Studio editing and serialization

The viewport selection and source pose-inspector implementation cover all thirteen
guides, separate from prototype IK chain IDs. The gate that previously intercepted
source Pose, Face and Clothes tabs (`ST-B01` in the audit) was removed 2026-09-25;
the `IKKOKU_CAPTURE_UI_REPORT` JSON records the inspector view that SwiftUI actually
rendered (`inspectorView` from each rendered branch's `onAppear`, cleared on
`onDisappear`; a gated or blank view reports `none`), and re-inserting the gate makes
that report differ — the PNGs omit most SwiftUI content, so they are not visual
evidence. Real mouse-driven guide editing, undo/redo, save/reload and original-scene
export remain unverified (`ST-T01` pending).

The implemented drag callback translates world deltas through the complete
character parent frame, including attachment transforms. Distal rotation uses the
composed parent quaternion. `sourceIKOverrides` stores raw Unity-local position and
Euler degrees; `sourceKinematics` preserves both enable flags and the original
seven-FK/five-IK group order. Native scene save/load retains both fields.

Original-scene export patches existing `characterIK` destinations and kinematic
flags. It preserves source target dictionary keys, disabled guide rotation,
scale, card bytes, plug-in trailers and unedited records. Missing target records
cannot be inserted through the bounded writer. Rejected edits do not mutate the
original file. Viewport selection, numeric editing and deterministic capture edits
feed the same override representation.

## Verification

`studio_fullbody_oracle.py` copies fourteen recovered source files without edits
into ignored local output, compiles them against `FinalIKOracle/UnityShim.cs`, and
records every source/host hash plus per-case input/output hashes. It covers the
original prefab hierarchy, active body and proximal targets, nonuniform
customization followed by animation, iterations 0/1/4/8, relative effectors,
partial global weight, asymmetric chain pull/reach/push, and inactive groups.
The installed firstpass DLL failed to load directly under macOS .NET; the oracle
therefore executes recovered C# instead of claiming original binary execution.

```sh
# Supply the locally recovered project directory; it is never checked in.
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/studio_fullbody_oracle.py \
  --bundle .local/reverse/rigs/source/abdata/chara/oo_base.unity3d \
  --recovered-project /path/to/private/recovered/project \
  --output .local/reverse/studio-fullbody
IKKOKU_FULLBODY_REFERENCE="$PWD/.local/reverse/studio-fullbody/reference.json" \
IKKOKU_FULLBODY_REPORT="$PWD/.local/reverse/studio-fullbody/native-parity.json" \
swift test --package-path Packages/Engine --filter 'sourceFullBody|sourceIK|sourceStudioIK'
```

The retained twelve-case run measured maximum world-position error `9.36e-6`, solver-node
error `1.17e-5`, and quaternion-dot error `1.20e-7`. Unconditional tests cover body
and clavicle coupling, head rotation, zero-iteration behavior, nonuniform scale,
repeatability, guide coordinate callbacks, native persistence and all-target
original-scene byte reversal. The supplied clothed head-200/bone-1 character test
edits all thirteen guides and reloads the exported original scene: all local
matrices and **40,490 deformed vertices match exactly**. Card bytes and the scene
plug-in trailer are unchanged. Evidence is in
`.local/reverse/studio-expansion/ik-roundtrip-audit.json`.

Remaining tasks are to unblock and regression-test source pose editing (`ST-T01`),
then capture numeric full-body solves in the actual Unity player (`ST-T05`). The
current comparison uses recovered C# in an independent math host. Runtime
mutation of FinalIK component configuration, arbitrary plug-in solver callbacks/iteration
hooks, signed/sheared solver transforms, and non-biped FinalIK solver families
also remain unvalidated by this adapter. The preview is deterministic from its
explicit initialization pose; it does not reproduce every stateful Unity execution history.
