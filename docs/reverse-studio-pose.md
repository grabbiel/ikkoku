# Recovered CharaStudio pose behavior

The native `SourceStudioPose` module translates the installed Studio FK target
binding, kinematic activation state, and per-frame local-rotation application.
It also reports the side effects needed by the remaining Studio systems. It does
not run FinalIK, DynamicBone, Unity Animator, look-at solvers, or Studio guides.

This is a bounded behavioral translation, not a complete Studio character port.
The existing native pose presets and IK implementation are separate systems and
are not evidence of compatibility with the original solvers.

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
position and rotation weights. Reporting these events is not equivalent to
executing the missing solver or component.

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
these are not implemented by this module. This distinction matters when building
the eventual Studio editor, even though late-frame FK evaluation is available.

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

The real-avatar proof binds both targets, evaluates 774 world matrices and
preserves finite geometry bounds. Its head rotation matches a separate NumPy
calculation with maximum error `5.9605e-8`. This is a rig-evaluation proof; the
source character has not yet been loaded into the Studio editor or restored
from a complete original Studio character record.

## Remaining Studio dependency inventory

| Area | Recovered dependencies and remaining work |
| --- | --- |
| Character loading | `AddObjectFemale/Male` builds `ChaControl`, Studio preparation components, dynamic-bone lists, guides, tree nodes, hand animation and option items; it initializes FinalIK, loads source animation, restores IK/FK flags, expressions, and character status. Native source-avatar assembly covers only part of this object lifecycle. |
| Scene character records | `OICharInfo` includes embedded character data, bone and IK target dictionaries, accessory points, children, expression flags, animation identity/time/speed, voice lists and additional status. The existing layout importer does not recreate this full character graph or its reference remapping. |
| IK | `AddObjectAssist.InitIKTarget` wires 13 source effectors/bend goals; `IKCtrl.InitTarget` waits one frame and then `WaitForEndOfFrame` before copying targets. FullBodyBipedIK, solver initiation/mappings, target space conversion, and source pose-copy operations remain. |
| Animation | `OCIChar.LoadAnime` chooses controller overrides, clips, parameters, layer weights, dynamics, pole-vector flags, option items and auxiliary motion data. `CharAnimeCtrl` seeks layer 0 and implements a LateUpdate forced-loop restart for nonlooping clips after normalized time reaches 1. Full asset/controller evaluation and these coordinated effects remain separate from FK. |
| Guides and look-at | `GuideObject` handles connected/local and nonconnected/world transforms, event callbacks, scale compensation, selection and visible gizmos. `ChangeLookNeckPtn` needs the source neck-look controller. The emitted neck/guide events have no full native consumer yet. |
| Dynamics | Hair/skirt DynamicBone and source breast controllers are toggled by FK and animation metadata. These simulations and interactions with ABMX baselines remain missing. |
| Routes | `OCIRoute`, `AddObjectRoute`, `OIRouteInfo`, route points, `StudioTween`, curve/line construction, orientation, loops, speed/time, child transforms and completion state form the route runtime. Recovered route records alone do not reproduce it. |
| Voice | `VoiceCtrl` resolves catalog identity/personality/head attachment, controls playback and auto-advance, and reads/writes voice-list records. Native audio scheduling and source-compatible list handling remain. |
| Serialization/mod hooks | Full SceneInfo save/load/import/reference lifetimes, embedded character appearance, ExtendedSave scene data and plug-in lifecycle hooks remain. FK state must eventually round-trip with those original records. |

Next integration should import actual `OICharInfo` bone records, bind their
original catalog IDs to the assembled character, and place this FK stage after
the recovered animation stage. It must keep missing solver and dynamics effects
visible in compatibility reporting until their native consumers exist.
