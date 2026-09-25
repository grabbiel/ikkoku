# Recovered CharaStudio pose behavior

Reviewed 2026-09-25 against the working tree. The [Studio audit](../../component-audit/studio.md) is the feature-status and actionable-backlog index; this page records the narrower source contract and its evidence.

The native `SourceStudioPose` module translates the installed Studio FK target
binding, kinematic activation state, and per-frame local-rotation application.
It also reports the side effects needed by adjacent Studio systems. This module
alone does not run FinalIK, DynamicBone, Unity Animator, look-at solvers or Studio
guides. The assembled Studio preview now has separate native Animator, full-body
IK, selected hair dynamics and guide adapters; their coverage is documented below.

This is a bounded behavioral translation, not a complete Studio character port.
The authored native pose presets and prototype IK remain separate systems; their
behavior is not evidence of compatibility with the recovered solvers.

## Source evidence

The installed CharaStudio `Assembly-CSharp.dll` is 5,385,216 bytes with SHA-256
`902b9a237337b17a64514bdb0d857b460ece4fb6a57c658375dd32c5fa504c45`.
Additional types were decompiled with local `ilspycmd 11.1.0.9782`; recovered C#,
catalog content, and generated fixtures remain under ignored `.local/reverse`.

Run the following from the repository root to regenerate the evidence document:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/studio_pose_contract.py
```

It reads the explicitly selected local `studio/info/00.unity3d` and the recovered
types, verifies the assembly hash, and writes
`.local/reverse/studio-pose/contract.json`. The document contains 21 source-file
hashes, 233 effective bone rows from `Bone_00`, source group mappings, seven
independent rotation-matrix cases, and twelve activation traces. It does not
claim that this one info bundle is the installation's complete, mod-patched
catalog. The original loads sorted info bundle paths and overwrites bone IDs as
later tables are read; this extraction covers one explicit bundle.

Primary methods used:

| Type | Recovered behavior |
| --- | --- |
| `Info.LoadBoneInfo` | Bone ID/name/category/level parsing and replacement by ID |
| `AddObjectAssist.InitBone`, `InitHairBone` | Guide creation, female level-2 filter, body/hair search roots |
| `TransformFindEx.FindLoop` | Root-inclusive, depth-first, first matching transform; inactive objects included |
| `FKCtrl.InitBones`, `TargetInfo`, `LateUpdate` | FK classification, target enable state, disable reset, ordered absolute Euler writes |
| `UniRx.ReactiveProperty<T>`, `BoolReactiveProperty` | Initial subscription and equality-suppressed value notifications; recovered from the installed `Assembly-CSharp-firstpass.dll`, whose hash is also recorded |
| `OCIChar.ActiveFK`, `ActiveIK`, `ActiveKinematicMode` | Preference updates, force semantics, mode exclusion, side-effect order |
| `OIBoneInfo`, `OICharInfo`, `ChangeAmount` | Group flags, initial preferences, stored Euler representation |
| `GuideObject`, `IKCtrl`, `Preparation`, `CharAnimeCtrl` | Adjacent update responsibilities and explicit compatibility gaps |
| `AddObjectFemale`, `AddObjectMale`, `SceneInfo`, `OCIRoute`, `AddObjectRoute`, `VoiceCtrl` | Remaining character, scene, route, animation and voice dependencies |

## Native contract

`SourceStudioPose.Bone` uses `{id, name, group, level}` with the source catalog's
integer category, **not** the final bit mask. Pass rows in original dictionary
iteration order, explicit character/body/hair roots, character sex, and saved
rotations keyed by the original catalog ID. Missing bones are skipped. Binding
uses transform names and source hierarchy traversal; it never guesses native
equivalents from approximate names.

The original guide search for non-hair entries begins at `objBodyBone`; FK search
begins at the character root. `bodyRoot` defaults to `characterRoot` for isolated
test rigs and must be supplied for an actual assembled character. Hair entries
search only under the original `HairParent` reference. The assembled female
preview uses `p_cf_body_bone` and `cf_J_FaceUp_ty` for those roots. The native
hierarchy must preserve sibling order; matching uses exact UTF-8 bytes. The
installed catalog uses ASCII transform names. Culture-sensitive .NET string
aliases from arbitrary third-party catalogs are not implemented.

Female characters omit new level-2 guide/record creation. If a saved record
already exists, `FKCtrl.InitBones` can still bind it: its loop has no level filter.
Guide flags and FK flags also differ:

| Catalog category | FK target group | Guide group |
| --- | --- | --- |
| 0 through 4 | Body = 1 | Body OR `(1 << category)` |
| 5 | RightHand = 32 | Same |
| 6 | LeftHand = 64 | Same |
| 7 through 9 | Hair = 128 | Same |
| 10 | Neck = 256 | Same |
| 11, 12 | Breast = 512 | Same |
| 13 | Skirt = 1024 | Same |

FK part order is Hair, Neck, Breast, Body, RightHand, LeftHand, Skirt. Preferences
initially equal `[false, true, false, true, false, false, false]`. IK part order is
Body, RightLeg, LeftLeg, RightArm, LeftArm, initially all enabled. Both whole
components begin disabled, but each internal FK target starts enabled. That
distinction affects the first disable transition.

The public activation methods preserve these source details:

- Ordinary FK activation updates its saved preference even with FK disabled,
  then skips effects when the component is disabled. An unchanged preference
  also skips effects.
- Forced activation leaves saved preferences unchanged and repeats effects.
  Forcing Neck on twice captures pattern 4 as the second previous pattern;
  disabling subsequently restores 4. The native implementation preserves this
  source behavior rather than retaining an invented initial pattern.
- Ordinary IK activation updates weights even if the whole IK component is off.
  Its guide visibility still depends on the component's enabled state.
- Enabling FK disables IK and vice versa. Recursive calls preserve source
  order, including repeated pole-vector-copy events. Switching modes preserves
  the user's per-group preferences.
- Hair, Body, and Skirt reset local rotation to identity only when their target
  changes from enabled to disabled. Repeating a forced disable does not repeat
  the reactive reset. Neck, Breast, and Hands do not perform this reset.

Activation returns a `Transition`: immediate identity-reset node indices plus
ordered `Effect` values. Effects include neck pattern, hair/skirt dynamics,
left/right breast dynamics, guide state, IK weights, and four pole-vector-copy
flags. Source Body IK weights control spine twist and the body effector; limb
weights control the limb mapping and corresponding proximal/distal effector
position and rotation weights. The Studio preview consumes IK and selected hair
dynamics state. Neck look-at, breast/cloth dynamics and every original guide side
effect do not yet have consumers; returning an effect alone does not execute it.

Apply activation resets immediately with `applying(_:rig:pose:)`. On each
subsequent frame, call `applyingLateUpdate(rig:pose:)` on the upstream frame pose.
Enabled FK targets **replace local rotation** with `Quaternion.Euler(rot)`, using
Unity's Z-then-X-then-Y order and the engine's Z-reflected coordinate system.
Current local translation and scale survive unchanged. FK rotation is not a
rest-relative delta, and repeated frames do not accumulate rotation. If multiple
catalog records bind one transform, the last enabled entry in catalog order
wins. There is no numeric angle clamping to a slider range.

The managed code places FK writes in `LateUpdate`; it does not establish the
complete cross-component execution order of Animator, FinalIK, DynamicBone,
look-at, and other plug-ins. The module therefore exposes a frame operation
instead of asserting an unrecovered global scheduler order.

## Integration and failure handling

Activation changes controller state before pose validation. Callers must stage a
copy of the controller and pose, apply the returned resets and frame operation,
then commit both together after successful validation. This prevents a rejected
pose from leaving the UI's activation state ahead of the rendered character.
Effect consumers should likewise run only after the staged native update is
accepted. Do not reuse a transition for a different controller or hierarchy.

The current matrix-based pose representation does not retain signed TRS
components. Rotation replacement therefore accepts positive, finite, orthogonal
local TRS and rejects signed authored scales, authored matrices, singular axes,
reflections, and shear. Upstream pose writers must preserve positive scale; two
negative axes cannot be distinguished from a different rotation using a matrix
alone. This is a stated native representation limit, not a source restriction.
Disabled FK does not decompose or rewrite the upstream pose. All produced poses
are validated through rig evaluation before returning them.

`setRotation` edits the controller's stored Euler value. It does not emulate
`ChangeAmount`/`GuideObject` change callbacks, which can write a visible guide's
transform immediately. `FKCtrl.CopyBone` and `GuideObject.Rotation` require
Unity's quaternion-to-canonical-Euler conversion and interactive guide handling;
these are not implemented by this module. `SourceStudioGuide` and
`SourceStudioIKEditing` provide separate callback conversion and persistence paths.
The app source-inspector gate still prevents normal access to those controls
(`ST-B01`); the module API and headless captures do not remove that UI defect.

## Validation

```sh
.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse -p test_studio_pose_contract.py
IKKOKU_STUDIO_POSE_CONTRACT="$PWD/.local/reverse/studio-pose/contract.json" \
  swift test --package-path Packages/Engine --filter sourceStudioPose
```

The Python oracle constructs row-major rotation matrices directly and models
activation traces independently. Native tests exercise original group mappings,
disabled preference writes, force semantics, neck recapture, FK/IK exclusion,
one-time identity resets, source Euler ordering, translation/scale preservation,
first depth-first match, hair scoping, inactive transforms, saved female level-2
records, duplicate target precedence, unsupported matrices, and optional
source-evidence comparisons. The fixtures are synthetic behavior inputs; they
are not complete imported original Studio scenes.

The `studio-fk` inspector also evaluates a selected original rig:

```sh
Packages/Engine/.build/debug/ikkoku-inspect studio-fk \
  .local/reverse/rigs/source-avatar.json \
  .local/reverse/studio-pose/avatar-head-turn.json
```

The local proof request uses `schemaVersion: 1`, character/body/hair node indices
0/1/587, `sex: 1`, selected source bone rows 1 (`cf_j_head`) and 2 (`cf_j_neck`),
saved rotations `[0, 15, 0]` and `[0, 0, 0]`, and
`commands: [{"operation": "fk", "active": true}]`. These node indices apply only
to this particular assembled manifest. Other rigs require their own root indices.

Requests contain `bones: [{id, name, group, level}]`,
`rotations: [{boneID, degrees}]` and an ordered `commands` array. Supported commands
are `fk`/`ik` with `active` and optional `force`, `fkGroup`/`ikGroup` with an
additional source bit `mask`, and `rotation` with `boneID` and three `degrees`.
Each command commits one static FK evaluation; no upstream animation advances or
immediate guide callbacks run. The CLI reports mode state, ordered deferred
effects, unbound catalog/saved IDs, and local/world matrices explicitly labeled
as column-major native right-handed Y-up coordinates.

The retained initial real-avatar proof binds both targets, evaluates 774 world
matrices and preserves finite geometry bounds. Its head rotation matches a
separate NumPy calculation with maximum error `5.9605e-8`. Subsequent
[scene integration](scene-records.md) loads complete original character records
into a selective Studio preview, and [full-body IK verification](full-body-ik.md)
roundtrips thirteen edited guides and 40,490 deformed vertices. These are distinct
evidence sets with broader integration than the initial two-bone FK proof.

## Remaining Studio dependency inventory

| Area | Recovered dependencies and remaining work |
| --- | --- |
| Character loading | Source previews select converted Maker assemblies by sex/head/bone type and outfit, apply card shapes/static ABMX/materials and saved expressions. Expand converted asset coverage, live appearance controls, hand/option-item lifecycle and missing scene consumers (`ST-T06`, `ST-T07`). |
| Scene character records | `decodeDocument` reads complete 1.0.4.2 character records; preview restores supported character consumers and bounded edited export exists. Integrate mixed item/character graphs, scene topology changes and source-key remapping (`ST-T03`, `ST-T04`). |
| IK | Schema-2 five-chain full-body solve, mappings, thirteen guide IDs and source target copying execute. Unblock the editor, compare against actual Unity-player numeric output and recover runtime hooks/configuration beyond the fixed adapter (`ST-T01`, `ST-T05`). Schema-1 remains a bounded limb fallback. |
| Animation | Normal catalog state/height/speed/forced-loop playback and flat 1D blend poses execute before FK/IK; 180 actual Unity-player samples validate the selected states. Implement missing loop-pose correction, layers/overrides/transitions, option items and source selection UI (`ST-T10`). |
| Guides and look-at | Attachment-aware FK/IK guide conversions and callbacks exist but the source inspector is blocked. Implement neck/eye look controllers and prove visible editor selection/drag behavior (`ST-T01`, `ST-T07`); saved look-at fields alone do not execute those solvers. |
| Dynamics | Selected source hair particles run after animation, customization/ABMX and FK/IK with checkpoints and FK disable state. Add cloth/accessory/body variants, world-object inertia and broader source motion comparisons (`ST-T08`). |
| Routes | `OCIRoute`, `AddObjectRoute`, `OIRouteInfo`, route points, `StudioTween`, curve/line construction, orientation, loops, speed/time, child transforms and completion state form the route runtime. Recovered route records alone do not reproduce it. |
| Voice | Ordered playlists, repeat, card pitch/personality gain and bounded list export execute. Original audio files are not converted in the retained catalog; add selected conversion, spatial behavior and mouth driving before claiming source voice playback parity (`ST-T12`). |
| Serialization/mod hooks | Existing source transforms/FK/IK/animation/voice/cameras can roundtrip while opaque data is retained. Native plugin state has its own persistence; original export rejects unsupported live IR state. Add topology edits and GUID-specific source-save adapters (`ST-T03`, `ST-T13`). |

The integrated order now samples the supported Animator state, reconstructs
source activation and FK, solves configured IK and then advances configured hair
dynamics. Next work should first unblock the existing source inspector, then
connect the still-deferred consumers above. Compatibility reporting must continue
to distinguish recovered records, executed adapters and user-visible controls.
