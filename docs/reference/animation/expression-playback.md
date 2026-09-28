# Original animation playback: temporal expressions and dependency map

Reviewed 2026-09-25 against the working tree. See the [Character audit](../../component-audit/character-and-mods.md) for Maker integration and the [Studio audit](../../component-audit/studio.md) for animation consumers and pending tasks. Evidence counts below describe retained focused runs, not a fresh full-suite result.

This workstream translates the original blink state machine and expression
timers into Swift. It also identifies the remaining runtime animation systems
from the installed Mono assembly. Recovering their C# is not equivalent to
implementing Mecanim, clip sampling, navigation, IK, voice playback or dynamics.

## Recovered source and native implementation

The installed `Assembly-CSharp.dll` has SHA-256
`0038281caf8df48a7903c55dc389642eeeb3f2a9114bd9d68ac11c8ac0396bc5`.
The ignored `.local/reverse/decompiled/Expressions/manifest.json` records the
individual decompilation hashes. `animation_playback_contract.py` verifies the
assembly and eight expression source files before producing local evidence.
No original DLL is executed.

`Packages/Engine/Sources/Character/SourceExpressionPlayback.swift` implements:

| Source type | Native type | Behavior preserved |
| --- | --- | --- |
| `FBSBlinkControl` | `SourceBlinkPlayback` | Absolute float32 clock, random call ranges/order, phase order, flags, frequency and speed setters |
| `FBSAssist.TimeProgressCtrl` | `SourceExpressionProgress` | Delta-time accumulation, start/end, duration changes without resetting elapsed time |
| `FBSAssist.TimeProgressCtrlRandom` | `SourceExpressionRandomProgress` | Random duration initialization and restarting after returning the completion event |

The blink evaluator accepts explicit integer and floating-point random callbacks.
Integers use the source half-open interval, with equal endpoints returning that
endpoint. Floats use a closed interval. Production defaults use Swift random
draws; **Unity's PRNG sequence has not been reproduced**. Deterministic traces
inject exact draws to verify the controller independently of the PRNG.

Important source details retained:

- A new controller starts open and idle, with deadline zero, frequency 30 and
  base speed 0.15 seconds. An update at zero does not start a blink; the first
  positive-time update does.
- Each update computes openness **before** changing phase. A phase changes only
  when `time > deadline`, including at a frame where openness has already reached
  its endpoint.
- Closing duration is base speed plus a random float in 0...0.05. After closing,
  a random 1...3 **expired update calls**, not seconds, pass before opening.
  Repeated calls at the same expired time still decrement this count.
- Large time jumps advance at most one phase per call. Skipped blinks are not
  replayed in a catch-up loop.
- Idle scheduling retains the original float32 divide, multiply and 0.2 scaling.
  Replacing the divide/multiply pair with its algebraically equivalent integer
  draw changes rounding for some frequencies.
- Any nonzero fixed flag freezes the output and phase. Explicit force-open or
  force-close setters still schedule while fixed. The original expression caller
  passes `-1` when fixed, causing eye controllers to retain their own openness.
- The original speed setter clamps with `max(1, value)`, despite the constructor
  default of 0.15 and the inspector's 0...0.5 range. The native setter preserves
  this unusual behavior.
- A force-open or force-close call schedules the new phase but does not immediately
  update the stored openness. Forcing a new phase can therefore jump at the next
  calculation; it does not interpolate from the previous openness.
- `TimeProgressCtrl` initially has elapsed count zero and rate one. Its source
  caller explicitly calls `End()` during initialization. Changing duration
  preserves both current count and rate until the next calculation.
- A completing random timer returns one to its caller even though its internal
  timer has already restarted at rate zero with a new duration.

Native boundaries reject nonfinite/negative times, nonfinite speeds, invalid
random draws, unordered/negative duration intervals and overflowing deadlines.
These checks protect the native interface; they are not claims about the original
inspector's validation. Failed operations leave controller state unchanged.
Externally supplied RNG state remains the caller's responsibility.

## Expression invocation order and Maker integration

`FaceBlendShape.LateUpdate` advances its **internal** blink controller, selects an
external controller if present, derives the fixed-flag sentinel, computes gaze
correction, and evaluates eyebrow, eye and mouth controllers in that order. It
does not advance the selected external blink controller itself. `FBSBase` advances
its blend timer before writing morph weights. `FBSCtrlMouth` evaluates mouth
morphs before its optional random width adjustment.

Maker now feeds the recovered temporal blink rate into the existing original-head
expression evaluator. **Automatic blinking** can be disabled to inspect static
eye openness; choosing the closed-eye preset disables it. The current Maker
timer runs at 30 Hz, so the source's frame-counted closed hold lasts one through
three native timer ticks. This cadence is an application integration choice,
not parity with every original frame rate. Pausing Maker's animation stops update
calls; its absolute clock continues, like disabling a behaviour rather than
setting Unity's global time scale to zero.

Existing expression morph mapping is described in
[head materials](../character/head-materials.md) and [character contracts](../character/contracts.md). This addition does not implement gaze-dependent eyelid
correction, the full dictionary of overlapping expression-pattern transitions,
audio-driven lip sync or random mouth-width bone scaling. Studio applies saved
expression choices and mouth openness at preview construction; it does not yet
consume this temporal blink controller or expose a working source Face inspector.
`ST-T07` tracks that separate integration.

## Remaining animation dependencies

Selected source is recovered under `.local/reverse/decompiled/Animation/` with a
separate SHA-256 manifest. The main character wrapper is also available under
`.local/reverse/decompiled/Character/Koikatu/ChaControl.cs`.

| System | Recovered entry points and data dependencies | Native status |
| --- | --- | --- |
| Controller loading and state playback | `ChaControl.LoadAnimation`, `AnimPlay`, `syncPlay`, `setAnimPtnCrossFade`, parameter/layer setters; `EasyLoader.Motion` | Generic Transform clips and flat 1D states execute. Studio adds exact normal catalog identity, height/speed/time/force-loop handling. Transitions, masks/layers, overrides, callbacks and broad Mecanim compatibility remain pending. |
| Controller/clip assets | Runtime-loaded controllers/parameter data, Avatar bindings and generic Transform curves | Action Idle/Locomotion clips are converted; the base normal Studio catalog has 287/288 executable rows. The remaining row needs loop-pose correction. Exact binding is required; catalog breadth is not full controller semantics or installed-mod coverage. |
| Player locomotion | `ActionGame.Chara.Mover.PlayerMover`: `Idle`, `Locomotion`, `squat_walk`, `squat_loop`, `MotionSpeed`, mover/reactive/NavMesh dependencies | Selected Idle/walk/run clips sample natively. The player state-selection, movement/navigation and gameplay host do not execute; animation sampling is not locomotion integration. |
| NPC locomotion | `NPCMover`: idle/talking handling, escape action 20, anger locomotion and random alternative locomotion; arrival state controls updates. | Source recovered; dependent AI/navigation and animator behavior remain unported. |
| Lip sync | `ChaControl.UpdateBlendShapeVoice` selects `WavInfoData` or `FBSAssist.AudioAssist` (1024 channel-zero samples, RMS, gain clamp and asymmetric smoothing) | Studio voice playlist/repeat/gain/pitch scheduling exists, but original files are not converted in the retained catalog. No source audio-output sampler, precomputed mouth timeline or lip-sync driver is integrated. |
| Eye gaze | `EyeLookController` and `EyeLookCalc`, eye type states, reference directions, transform hierarchy, fixed angles and current target; zero delta-time and enable flags affect evaluation. | Detailed source recovered and the saved record bytes plus card Status look fields now decode natively ("Saved look data" below). Existing neutral expression rendering does not implement these controllers. |
| Neck gaze | `NeckLookControllerVer2`, `NeckLookCalcVer2`, per-bone settings, look-mode changes, previous rotations, target history and an `AnimationCurve`. | Detailed source recovered and the saved neck record bytes plus card Status look fields now decode natively ("Saved look data" below). Solver, curve evaluation and composition order still needed. |
| Motion IK | `MotionIK`, `MotionIKData`, state/frame mappings, partner targets and FinalIK's full-body biped solver | A schema-2 Studio biped solver is implemented and independently compared with recovered C#. MotionIK state/frame/partner data and its runtime callbacks remain separate pending consumers. |
| Secondary motion | `DynamicBone` particles, distributions, collider rebinding and scheduling; separate Ver01/Ver02 families | Selected source hair components execute in Maker and Studio; offline motion-oracle evidence and actual-player parameter/curve evidence are separate. Other variants/topologies, Studio world-object inertia and full player trajectory comparison remain pending. |

The inspected `DynamicBone` caps its accumulated fixed-rate catch-up at three
steps and clears excess time. That policy differs from the blink controller's
single-state update, so a universal timer or catch-up strategy would lose source
behavior. Likewise, Unity Animator transitions cannot be recovered from C# wrapper
methods alone: serialized controller graphs, blend trees, clip curves, masks,
avatars and bindings supply essential behavior.

Next expression work is to bind this timing kernel to mutable Studio source
expression state, then add neck/eye look-at and source mouth consumers with
explicit evaluation order. Acceptance should compare numeric morph/bone outputs
and saved field roundtrips, including interrupted transitions and paused/seek
behavior (`ST-T07`), rather than only demonstrating a visibly blinking prototype.

## Saved look data

`ST-T07` extracted (data only; no solver runs) the look-at data a scene stores.

Saved bytes per character record, decoded by `SourceStudioNeckLookData` and
`SourceStudioEyeLookData`:

- Neck bytes (`NeckLookControllerVer2.SaveNeckLookCtrl` payload): Int32
  `ptnNo`, Int32 count, then count `(x, y, z, w)` float quaternions in Unity
  source component order — one `aBones[i].fixAngle` each. Short input,
  trailing bytes, a negative/oversized count or a non-finite float is rejected.
- Eyes bytes (`EyeLookCalc.SaveAngle` payload): `fixAngle[0]` (x, y, z, w),
  `fixAngle[1]` (x, y, z, w), then `angleH[0]`, `angleH[1]`, `angleV[0]`,
  `angleV[1]`. The four angle floats exist only from scene data version
  0.0.8 on (`LoadAngle` gates on it); older versions leave them nil.

Card `Status` look fields decoded by `SourceStudioLookStatus` from the card's
MessagePack `Status` block: `eyesLookPtn`, `neckLookPtn`, `eyesTargetType`,
`neckTargetType`, `eyesTargetRate`, `neckTargetRate`, `eyesTargetAngle`,
`neckTargetAngle`, `eyesTargetRange` and `neckTargetRange`. A missing field
stays nil; a wrong type is reported as a diagnostic and also stays nil.

Studio's `AddObjectAssist.UpdateState` restores these in the order
`ChangeLookEyesPtn` → eyes `LoadAngle` → neck `LoadNeckLookCtrl` →
`ChangeLookNeckPtn`. `ChangeLookNeckPtn` runs last, so the card's
`neckLookPtn` overrides the `ptnNo` just restored from the saved neck bytes;
`SourceStudioLookData.effectiveNeckPattern` applies exactly that precedence.

The prefab settings in `chara/oo_base.unity3d` (sha256
`2bb9017d29b12352a859f54623728e4dea587392d3677a0a7158a7f9784fba67`, exported by
`Tools/reverse/studio_look_settings.py`) are `NeckLookCalcVer2` on `cf_j_neck`
under root `p_cf_body_bone` with seven neck states, and `EyeLookCalc` on
`p_cf_head_bone` with eight eye states. Default patterns:
`NeckLookControllerVer2.ptnNo = 0` (rate 1.0), `EyeLookController.ptnNo = 1`.
The low-poly `NeckLookCalcVer2`/`NeckLookControllerVer2` under
`p_cf_body_bone_low` (only five neck states) are excluded because CharaStudio
loads the `p_cf_body_bone` prefab. Neck lookType values are 0 ANIMATION,
1 TARGET, 2 AWAY, 3 FORWARD, 4 FIX, 5 CONTROL; eye lookType values are
0 NO_LOOK, 1 TARGET, 2 AWAY, 3 FORWARD, 4 CONTROL.

| Neck pattern | Name | lookType | | Eye pattern | Name | lookType |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 正面 | FORWARD | | 0 | 正面 | FORWARD |
| 1 | こっち | TARGET | | 1 | こっち | TARGET |
| 2 | あっち | AWAY | | 2 | 制御 | CONTROL |
| 3 | アニメ依存 | ANIMATION | | 3 | そらす | AWAY |
| 4 | 固定？ | FIX | | 4 | H正面 | FORWARD |
| 5 | Hこっち | TARGET | | 5 | Hこっち | TARGET |
| 6 | Hあっち | AWAY | | 6 | H制御 | CONTROL |
| | | | | 7 | Hそらす | AWAY |

`ikkoku-inspect look-data <scene.png> [studio-look-settings.json]` reports all
of the above per character, including the effective pattern's state name.
Not done here: no gaze solver (the TARGET/AWAY geometric solver, `CONTROL`
and the eye calculator included). `AnimationCurve` evaluation and the neck
FORWARD / FIX / ANIMATION look modes with the type-change transition are
ported by the later slice documented below. The capture below records what
the original controllers produce at runtime; replaying it in the preview
remains part of the wider `ST-T07` controller integration.

### Original look capture

`Tools/reverse/fixtures/OriginalCharacterProbe.cs` gained an optional look
mode. With a `look-patterns.tsv` in the plugin folder — one row per phase as
`neckPtn<TAB>eyesPtn<TAB>frames<TAB>x,y,z` — it calls
`ChangeLookNeckPtn`/`ChangeLookEyesPtn` and records at each frame's
`WaitForEndOfFrame` the phase index, `Time.frameCount`, `deltaTime`, the
camera position (information only), the target position, per neck bone
(`cf_j_neck`, `cf_j_head`) the internal `angleH`/`angleV`/`fixAngle` plus the
bone's local/world rotation and the calculator `nowAngle`/`calcLerp`/
`lookType`, and per eye the resolved transform name with its local rotation
and `angleH`/`angleV` plus the calculator `angleHRate`/`angleVRate`, into
`look-trace.json`. Without the tsv every existing output stays
byte-identical. `original_character_probe.py --look-patterns` uploads the tsv
after the compile step and accepts neck 0–4, eyes 0–3 and 1–600 frames per
row.

Two capture conditions are load-bearing. The fixture is created only after
CharaStudio's own scene load finishes — look mode first waits up to 3600
frames for `Camera.main` to appear, then 60 settled frames — because that
scene load destroys every non-persistent object, and a fixture created
earlier is gone before look mode runs. Each phase then moves one dedicated
probe GameObject `IkkokuLookTarget` through
`ChangeLookNeckTarget(0, trf)`/`ChangeLookEyesTarget(0, trf)`; `Camera.main`
is never moved, because Studio's camera controller owns it and overwrites
its transform. In this build the resolved eye transforms are runtime objects
named `EyeTargetL`/`EyeTargetR` under `cf_J_Eye_tx_L/R`, not the
`cf_J_Eye_rz_L/R` bones.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_character_probe.py \
  --output .local/stt07i/run1 --look-patterns .local/stt07i/look-patterns.tsv
# after the player reports done:
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_character_probe.py \
  --output .local/stt07i/run1 --collect
.local/reverse/unitypy-venv/bin/python Tools/reverse/summarize_look_trace.py \
  .local/stt07i/run1
```

`Tools/reverse/summarize_look_trace.py` reports per phase and track the
first frame whose onward per-frame rotation change stays below 0.01°
(`never` = still moving in the last recorded frame), the largest
single-frame step, the angle between the first and last recorded rotation,
and each neck bone's angular deviation from its own `fixAngle`. The
2026-09-28 capture under `.local/stt07i/run1` ran six phases over 450
frames — phases 0–1 neck 1 eyes 1 (こっち/TARGET) at targets `(0, 1.4, 1.5)`
and `(1.2, 1.8, 1.2)`, phase 2 neck 2 eyes 3 (あっち/そらす, both AWAY),
phase 3 neck 0 eyes 0 (正面/FORWARD), phase 4 neck 4 eyes 2 (固定？/制御,
FIX/CONTROL) and phase 5 neck 3 eyes 1 (アニメ依存/こっち):

| phase | neck/eyes ptn | track | settle frame | max step ° | settled angle ° | fixAngle dev ° |
|---|---|---|---|---|---|---|
| 0 | 1 / 1 | cf_j_neck | 0 | 0.000 | 0.000 | 0.000 |
| 0 | 1 / 1 | cf_j_head | 30 | 0.907 | 2.089 | 0.000 |
| 0 | 1 / 1 | EyeTargetL | 20 | 0.174 | 0.664 | — |
| 0 | 1 / 1 | EyeTargetR | 20 | 0.174 | 0.664 | — |
| 1 | 1 / 1 | cf_j_neck | 86 | 0.178 | 4.228 | 0.000 |
| 1 | 1 / 1 | cf_j_head | never | 1.617 | 38.708 | 0.000 |
| 1 | 1 / 1 | EyeTargetL | never | 4.937 | 14.115 | — |
| 1 | 1 / 1 | EyeTargetR | never | 6.628 | 21.807 | — |
| 2 | 2 / 3 | cf_j_neck | never | 1.329 | 42.074 | 0.000 |
| 2 | 2 / 3 | cf_j_head | never | 1.861 | 58.620 | 0.000 |
| 2 | 2 / 3 | EyeTargetL | 0 | 0.000 | 0.000 | — |
| 2 | 2 / 3 | EyeTargetR | 0 | 0.000 | 0.000 | — |
| 3 | 0 / 0 | cf_j_neck | 58 | 1.569 | 36.480 | 0.000 |
| 3 | 0 / 0 | cf_j_head | 58 | 0.833 | 19.340 | 0.000 |
| 3 | 0 / 0 | EyeTargetL | 10 | 0.894 | 2.569 | — |
| 3 | 0 / 0 | EyeTargetR | 10 | 0.900 | 2.581 | — |
| 4 | 4 / 2 | cf_j_neck | 0 | 0.000 | 0.000 | 0.000 |
| 4 | 4 / 2 | cf_j_head | 0 | 0.000 | 0.000 | 0.000 |
| 4 | 4 / 2 | EyeTargetL | never | 0.468 | 8.575 | — |
| 4 | 4 / 2 | EyeTargetR | never | 0.468 | 8.587 | — |
| 5 | 3 / 1 | cf_j_neck | 0 | 0.000 | 0.000 | 0.000 |
| 5 | 3 / 1 | cf_j_head | 0 | 0.000 | 0.000 | 0.000 |
| 5 | 3 / 1 | EyeTargetL | 33 | 1.354 | 2.995 | — |
| 5 | 3 / 1 | EyeTargetR | 28 | 1.210 | 2.668 | — |

Notable readings: the near-center `TARGET` phase settles the head by frame
30 and both eyes by frame 20, while tracking the off-center target never
quite stops; `FIX` keeps computing `nowAngle` `[11.36, -60]` while both
neck bones hold identity rotation and `fixAngle` never changes (deviation
0.000 on every frame); eyes `AWAY` freezes `angleH`/`angleV` at their
carried-over values instead of animating away; eyes `CONTROL` never settles,
drifting about 8.6° over its 60 recorded frames (biggest single-frame step
0.468°); and neck `ANIMATION` moves no neck bone at all — its pose comes
from the body animation, which this trace does not record independently.

Limits: the capture runs on a plain `ChaControl` fixture created through
`Manager.Character.CreateFemale`, not an `OCIChar` under Studio management;
only direct transform targets are driven, so the card `eyesTargetType` and
target-rate fields and Studio's eyes pattern 4 target guide are not
exercised; neck pattern 5 and eyes patterns 4–7 stay outside the driver's
accepted ranges. This is recorded ground truth, not a ported solver.

### Neck look modes FORWARD / FIX / ANIMATION

The next `ST-T07` slice ports the neck half of the runtime behavior against
that capture. Every LateUpdate runs `UpdateCall(ptnNo)` and then
`NeckUpdateCalc`, and the ported transition keeps four values per
calculator: `lookType`, `changeTypeTimer`, and per bone (`cf_j_neck`,
`cf_j_head`) `fixAngle` and `fixAngleBackup`.

- **Type change** (`UpdateCall`): a new `lookType` zeroes `changeTypeTimer`
  and copies `fixAngle` into `fixAngleBackup` per bone. FORWARD also clears
  the calculator's `angleH`/`angleV`, which only the TARGET/AWAY solver
  reads, so the port has nothing to clear.
- **`deltaTime == 0`**: `NeckUpdateCalc` is skipped entirely — the animated
  pose passes through untouched and the timer does not advance (a lookType
  change still resets the timer and takes the backup).
- **Timer and curve**: `changeTypeTimer = clamp(timer + dt, 0,
  changeTypeLeapTime)` (settings 1.0) and `num =
  changeTypeLerpCurve.Evaluate(timer / changeTypeLeapTime)`. The serialized
  curve is two keys, `(0, 0.00216675, slopes 2.2096143)` and `(1, 1, slopes
  0)`, and pre/post infinity 2 — Unity evaluates the normalized segment as
  the cubic Hermite with tangents `outSlope*dt` / `inSlope*dt`, and the
  clamp infinities hold the end values outside `[0, 1]`. The curve bulges
  slightly above linear mid-segment.
- **FORWARD**: `fixAngle` becomes identity per bone; the frame's local
  rotation is `Slerp(fixAngleBackup, identity, num)`.
- **FIX**: `fixAngle` keeps its value (the saved angle for a loaded state),
  and the local rotation is `Slerp(fixAngleBackup, fixAngle, num)` — the
  first frame of a loaded FIX state already returns the saved angle because
  the backup equals it.
- **ANIMATION**: `fixAngle` becomes the frame's animated local rotation and
  the local rotation is `Slerp(fixAngleBackup, fixAngle, num)`; the animated
  pose is assumed already inside `MaxRotateToAngle`, whose geometric clamp
  this slice does not model.
- At the captured `calcLerp` of 1.0, FORWARD and FIX never read the entry
  pose: `Slerp(animated, fixAngle, calcLerp)` lands on `fixAngle` exactly.
  TARGET and AWAY are the geometric solver and are reported as unsupported,
  not approximated.

`Tools/reverse/analysis/neck_look_reference.py` is the pure Python oracle
(`evaluate_curve`, `slerp`, `neck_step`, 14 unittest cases), and
`Tools/reverse/compare_neck_look.py` replays capture phases 3 (FORWARD), 4
(FIX) and 5 (ANIMATION) of `.local/stt07i/run1/look-trace.json` frame by
frame, seeding each phase from the frame before it. Measured maximum
local-rotation angle error per phase, 60 frames each:

| phase | lookType | cf_j_neck | cf_j_head |
| --- | --- | --- | --- |
| 3 | FORWARD | 0.000007° | 0.009926° |
| 4 | FIX | 0.000000° | 0.000000° |
| 5 | ANIMATION | 0.000000° | 0.000000° |

All within the 0.01° target. `fixAngle` itself matches to 0.000000° on every
frame of every phase. The head FORWARD residual sits just inside the target:
the recording pipeline is internally consistent (recorded head localRotation
equals the world-rotation reconstruction to ~6e-6°), so the gap is a Unity
float32/native Slerp artifact on the head's ~17.2° backup arc — equivalent
to a timer-fit offset of about −8e-5 s — not a model difference. The
ANIMATION check only proves the no-change consequence: the trace holds no
independent animated pose and that phase never moves the neck bones, so the
comparator feeds the same frame's recorded pose; the moving-pose blend
formula is covered by the Python unit tests instead.

`Packages/Engine/Sources/Studio/SourceStudioNeckLook.swift` ports this in
Swift (`SourceStudioNeckLook`, `SourceStudioNeckLookSettings`,
`SourceStudioNeckLookCurve`). Its `step(deltaTime:lookType:animated:)`
returns the two Unity-basis local rotations; callers wanting the engine
basis apply `UnityCoordinates.rotation` themselves, exactly once. Its
float32 slerp dispatches the normalize-lerp fallback on the arc size
(theta < 1e-4 rad) because float32 cannot represent the float `1 - 1e-8`
threshold; within the fixture tolerance it reproduces the Python oracle
frame for frame. `SourceStudioNeckLookTests` replays a 7-step FORWARD/FIX
sequence plus curve samples from
`Packages/Engine/Tests/EngineTests/Fixtures/neck-look-reference.json`
(written by `compare_neck_look.py --fixture`) matching every quaternion and
timer to ≤1e-5, checks the "saved FIX returns the saved angle from the
first frame" case exactly, and confirms calcLerp ≠ 1, TARGET/AWAY stepping
and degenerate inputs throw.

Preview integration (next slice): with `IKKOKU_STUDIO_LOOK_SETTINGS` pointing
at the `studio_look_settings.py` JSON, `SourceStudioCharacterPreview` decodes
the saved neck bytes and the card look `Status`, resolves the effective pattern
through `SourceStudioNeckLookOverride.resolve` (the same resolution
`ikkoku-inspect look-data` reports as `neckOverride`) and, for FIX and FORWARD,
runs the calculator inside `editedPose` — after the FK/IK restore and before
hair dynamics. Because the scene load leaves a fresh `SourceStudioNeckLook`
seeded with lookType ANIMATION and `fixAngle` = the saved angle, and FORWARD
and FIX targets do not depend on history, ONE `step(deltaTime: elapsed, ...)`
reproduces any clock position; `elapsed == 0` steps with a documented tiny
positive delta (1e-5 s) because `NeckUpdateCalc` early-outs on zero, so FIX
already shows the saved rotation on the first frame. When the effective FK
state has the neck group active Studio forces pattern 4 instead, but the
relative order of Studio FK and the look controller is not recovered, so the
override is skipped and "FK owns the neck" is reported once. TARGET/AWAY are
reported "neck gaze solver pending; animated pose kept" and ANIMATION keeps the
animated pose. Verified only in the pure helper on a synthetic three-node rig
(FIX writes the saved quaternions with each bone's translation/scale kept,
FORWARD at elapsed 0.5 matches the analytic angle lerp from the Python curve
sample, FK-animated and ANIMATION leave the pose untouched); no full-character
rendered capture compares the override against the original preview. In the
real showcase scene every character resolves to FIX with identity saved
quaternions. Six of the seven have saved FK with the neck group active, so FK
owns their neck and the override is skipped. Character 65 has FK disabled, so
the override sets its `cf_j_neck`/`cf_j_head` to identity local rotation over
the animated pose. `ikkoku-inspect look-data` reports the same outcome per
character.

## Reproducible verification

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/animation_playback_contract.py
.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse/analysis -p test_animation_playback_contract.py
IKKOKU_ANIMATION_PLAYBACK_REFERENCE="$PWD/.local/reverse/animation-playback/reference.json" \
  swift test --package-path Packages/Engine --filter 'sourceBlink|sourceExpressionProgress|sourceExpressionRandomProgress'
Packages/Engine/.build/debug/ikkoku-inspect blink-trace \
  .local/reverse/animation-playback/reference.json
```

The independent Python oracle uses explicit IEEE754 binary32 operations. It
contains eight blink scenarios with 48 actions, ten progress-timer actions and
eight random-timer actions. Swift compares every blink state field and random
request exactly, plus both timers' duration/count/rate and completion events.
Additional synthetic tests exercise invalid-input atomicity and native bounds.

`blink-trace` ignores the oracle's expected-output fields and computes native
snapshots from actions and draws. Its limits are 16 MiB input, 1,000 scenarios and
100,000 total actions. Missing, unused or invalid draws fail explicitly; there is
no implicit random fallback in this verification path.
