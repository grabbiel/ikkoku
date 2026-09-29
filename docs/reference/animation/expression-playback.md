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
| Controller/clip assets | Runtime-loaded controllers/parameter data, Avatar bindings and generic Transform curves | Action Idle/Locomotion clips are converted; all 288 base normal Studio rows convert after `m_Lewd_00_01`'s cycle offset and `loopBlend` flag were recorded — every loop-pose correction candidate failed verification within tolerance and is reported (best 0.0296 vs 0.0001). Exact binding is required; catalog breadth is not full controller semantics or installed-mod coverage. |
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
the original controllers produce at runtime; replaying the eye modes in the
preview remains part of the wider `ST-T07` controller integration (the neck
TARGET/AWAY gaze is wired by the final gaze-wiring slice below).

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
row. A tsv the probe itself cannot parse (for example a camera coordinate
Python's `float` accepts but .NET does not, such as `1_0`) ends the run
before any capture with `status.json` error `Probe input rejected: …` and
no `look-trace.json`.

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

**Geometry capture and the `GetAngleToTarget` formula (2026-09-28, geometry
slice):** `RecordLook` now also records a per-frame `geometry` object — world
position, rotation and lossyScale of the neck calculator's `transformAim`
(`aim`), the bone's `boneCalcAngle` (`NeckRef`) and the last bone's
`referenceCalc` (`HeadRef`), `cf_j_neck`, `cf_j_head`, `cf_j_spine03`, each
`EyeLookCalc.eyeObjs[i].eyeTransform` (`EyeTargetL`/`EyeTargetR`) and the eye
calculator's public `rootNode` plus private `trfCenter` — together with
reflection-read private members: the neck calculator's `changeTypeTimer`,
`backupPos` and `lookType`, the live state's `isLimitBreakBackup` for the
frame's `ptnNo`, and per eye `origRotation`, `referenceLookDir`,
`referenceUpDir` and `dirUp`. Without the tsv every output stays
byte-identical. The 2026-09-28 capture `.local/stt07m/run1` (8 phases, 570
frames, `status.error` null) re-runs phases 0–3 of the table above and adds
phase 4 neck 1 eyes 1 at target `(0, 1.3, −1.5)` — directly behind the
character — phase 5 neck 1 eyes 1 at `(3.0, 1.3, 0.2)` — far to one side —
and phases 6/7 (FIX, ANIMATION) at `(−1.0, 1.2, 1.4)`:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_character_probe.py \
  --output .local/stt07m/run1 --look-patterns .local/stt07m/look-patterns.tsv
# after the player reports done:
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_character_probe.py \
  --output .local/stt07m/run1 --collect
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/neck_target_angle.py \
  .local/stt07m/run1 --settings .local/stt07h/studio-look-settings.json
```

`Tools/reverse/analysis/neck_target_angle.py` reconstructs the recovered
`GetAngleToTarget` and its pre-check limit test as pure functions over that
geometry (Unity-semantics `project`/`angle_degrees`/`angle_around_axis`/
`from_to_rotation`/`angle_axis`/quaternion product; the formula's `x` is the
pitch about `Cross(ref.up, q3·forward)` and `y` the yaw about `ref.up`, the
roles the recorded `nowAngle` confirms), and `Tools/reverse/analysis/`
`test_neck_target_angle.py` pins the helpers on synthetic vectors. The
captured `nowAngle` is each frame's end-of-frame value and `LateUpdate` runs
`UpdateCall` then `NeckUpdateCalc` in the same frame, so the formula's head
input is that frame's own recorded head rotation; the previously assumed
frame-k−1 head (the head rotation a LateUpdate earlier left on the bone) is
decisively refuted by the capture. Maximum |predicted − recorded| degrees per
phase (held = frames whose recorded `nowAngle` is byte-identical to their
previous frame, the solver having not recomputed it):

| phase | lookType | TARGET frames | held | x ° (k−1 head) | y ° (k−1 head) | x ° (k head) | y ° (k head) |
|---|---|---|---|---|---|---|---|
| 0 | TARGET | 90 | 84 | 0.893971 | 0.000000 | 0.081834 | 0.000000 |
| 1 | TARGET | 90 | 0 | 0.381035 | 1.670771 | 0.003343 | 0.016529 |
| 4 | TARGET | 60 | 59 | 0.000000 | 0.000000 | 0.000000 | 0.000000 |
| 5 | TARGET | 60 | 0 | 0.020436 | 4.090108 | 0.000186 | 0.002820 |

The frame-k head reproduces all 300 TARGET frames within 0.082°/0.017°,
every changed frame except one within 0.0033°/0.0165° and steady frames to
~5e-5° — the recorded ~7-significant-digit float serialization floor. The
phase-0 x maximum is a single unexplained recorded step at frame 328
(2.174659 → 2.092841, then held for the remaining 32 frames) that the
end-of-frame geometry does not reproduce (it predicts 2.1747 on both sides of
the step); what geometry the solver read on the frame it recomputed is not
recoverable from this trace. Limit break was exercised and hit: the behind
target of phase 4 breaks the limit test on all 60 frames (limit angles up to
180°/178.7° against `hAngleLimit`/`vAngleLimit` 90 + correction 0 — the
solver had set `isLimitBreakBackup` on the live state for the whole phase),
and the recorded `nowAngle` is `[0, 0]` on every one of those frames, exactly
the broken-limit zeroing the reconstruction applies; the far-side target of
phase 5 stays inside the limits (worst yaw 85.89° against 90 + 10). The 90
AWAY frames of phase 2 never break (worst limit angles 44.63°/20.96° against
80 + 10 / 90 + 10); their raw formula output sits at ≈[−11.30, +44.62] while
the recorded `nowAngle` is all-frame-held at x ≈ 11.30 and y exactly −60:
recorded x is the raw x negated to ≤0.0037°, and −60 is the `aParam`
minimum-bending sum −40 + −20 (not `hAngleLimit` 80 − `limitAway` 10, which
is 70) that the AWAY adjustment — the four-branch rule in the Neck look
modes TARGET / AWAY subsection below — collapses the vertical angle onto.
The verifier now applies that adjustment (`away_adjust` with the previous
frame's recorded bone angleH sum): across all 90 AWAY frames the adjusted
prediction matches the recorded `nowAngle` within 0.003664° x / 0.000000° y,
so AWAY is modeled here, not just reported. `backupPos` equals the
phase's recorded target position on all 570 frames; `changeTypeTimer` rises
from ~0.017 to 1 during every phase — each phase enters through a type
change — and sits at exactly 1 throughout the continuous TARGET phases 1 and
5, which follow a phase of the same lookType.

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
  TARGET and AWAY are covered in the next subsection; they take the frame's
  `nowAngle` from the geometric solver as an input rather than approximating
  that solver.

`Tools/reverse/analysis/neck_look_reference.py` is the pure Python oracle
(`evaluate_curve`, `slerp`, `neck_step`, `neck_target_step`, 21 unittest
cases), and `Tools/reverse/compare_neck_look.py` replays capture phases 3
(FORWARD), 4 (FIX) and 5 (ANIMATION) of
`.local/stt07i/run1/look-trace.json` frame by frame, seeding each phase from
the frame before it. Measured maximum local-rotation angle error per phase,
60 frames each:

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
frame for frame. `stepSolver(deltaTime:lookType:pattern:nowAngle:)`, described
in the next subsection, steps TARGET/AWAY. `SourceStudioNeckLookTests` replays
the 7-step FORWARD/FIX sequence, the 6-step TARGET/AWAY sequence and curve
samples from
`Packages/Engine/Tests/EngineTests/Fixtures/neck-look-reference.json`
(written by `compare_neck_look.py --fixture`) matching every quaternion and
timer to ≤1e-5, checks the "saved FIX returns the saved angle from the
first frame" case exactly, and confirms calcLerp ≠ 1, `step`'s TARGET/AWAY
(no angle input), a `stepSolver` type/pattern/nowAngle violation and other
degenerate inputs throw.

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
override is skipped and "FK owns the neck" is reported once. TARGET/AWAY
were then reported "neck gaze solver pending; animated pose kept" (wired by
the later gaze-wiring slice below) and ANIMATION keeps the
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

### Neck look modes TARGET / AWAY

TARGET and AWAY drive the neck from a solver angle rather than a target
rotation. `neck_target_step` (Swift
`stepSolver(deltaTime:lookType:pattern:nowAngle:)`) takes `nowAngle` as its
input, so the distribution/smoothing replay below is verified downstream of
that geometry; the geometry itself — `GetAngleToTarget` and its pre-check
limit test, which turn the look target's position into the frame's
`nowAngle`, plus AWAY's own `nowAngle` adjustment — is recovered in Python
(`analysis/neck_target_angle.py`, under Original look capture) and ported in
`SourceStudioNeckTargetAngle.swift`, pitted against that capture's frames
and a seeded fixture as described at the end of this subsection.

- **Distribution** (`NeckUpdateCalc`, bones last → first, so the head —
  index 1 — claims first): `nowAngle` is a residual the two bones take
  turns carving up. Each bone claims `h = clamp(residual.y,
  minBendingAngle, maxBendingAngle)` horizontally and `v = clamp(residual.x,
  upBendingAngle, downBendingAngle)` vertically — `nowAngle[1]` is the
  horizontal, `nowAngle[0]` the vertical component — and passes the exact
  leftover `residual − (v, h)` on. The head's `aParam` may be narrower than
  the neck's (TARGET: ±40°/±25° on both bones; AWAY: ±40°/±25° neck but
  only ±20° horizontal on the head), so a saturated head spills its excess
  onto the neck.
- **Smoothing**: per bone `angleH += (h − angleH) · t`, `angleV += (v −
  angleV) · t` with `t = clamp01(deltaTime · leapSpeed)` (captured leapSpeed
  2.0: 0.0166 s moves 3.3% of the way per frame, and a big deltaTime
  saturates at 1). At `deltaTime == 0` `NeckUpdateCalc` early-outs — no
  distribution, no timer advance, and nothing written back over the
  animated pose (the reference returns two `None`s, Swift `[nil, nil]`).
- **`fixAngle`** becomes `AngleAxis(angleH, Y) · AngleAxis(angleV, X)` per
  bone, the full Hamilton product `[cos(h/2)sin(v/2), sin(h/2)cos(v/2),
  −sin(h/2)sin(v/2), cos(h/2)cos(v/2)]`. The x/z cross terms are real: the
  recorded head `fixAngle` at frame 535 (angleH −17.26851, angleV 10.31902)
  holds x 0.08890961 where the half-angle product predicts 0.08890960 and z
  0.0135007 where it predicts 0.013500689; a yaw-plus-pitch-only
  reconstruction misses both.
- **Type change** does not clear `angleH`/`angleV` for TARGET/AWAY — only
  FORWARD's own `UpdateCall` branch clears them — so the TARGET → AWAY
  switch carries the smoothed angles over, and the replay matches recorded
  `fixAngle` through that switch to 1.3e-5°.
- **Output**: `localRotation = Slerp(fixAngleBackup, fixAngle, num)`, the
  same clamped timer and curve as FORWARD/FIX.

`compare_neck_look.py` replays capture phases 0 and 1 (TARGET) and 2
(AWAY) as one continuous run — 90 frames each, seeded at the first TARGET
frame with lookType FORWARD, identity `fixAngle` and zero angles (that
frame's implied blend fraction pins the pattern switch onto the frame
itself with the neck still unrotated), state carried untouched across the
phase 0 → 1 boundary, every frame feeding its recorded `nowAngle`.
Maximum errors (degrees):

| phase | lookType | bone | angleH/angleV | `fixAngle` | localRotation (frame) |
| --- | --- | --- | --- | --- | --- |
| 0 | TARGET | cf_j_neck | 0.000000 | 0.000000 | 0.000000 |
| 0 | TARGET | cf_j_head | 0.000001 | 0.000002 | 0.000007 (274) |
| 1 | TARGET | cf_j_neck | 0.000001 | 0.000002 | 0.000002 (366) |
| 1 | TARGET | cf_j_head | 0.000013 | 0.000016 | 0.000016 (411) |
| 2 | AWAY | cf_j_neck | 0.000010 | 0.000010 | 0.033771 (481) |
| 2 | AWAY | cf_j_head | 0.000013 | 0.000013 | 0.053021 (471) |

`angleH`/`angleV` and `fixAngle` match to ≤1.3e-5° / ≤1.6e-5° everywhere
against targets 1e-4° and 0.05°. Two local facts:

- An earlier ≈0.04° `fixAngle` "residual" was a comparator phantom, not a
  model difference: the probe serializes float32 components at ~7
  significant digits, and the raw check took `2·acos|dot|` without
  normalizing either side. With the normalized comparator every other
  rotation in this document uses (`compare_hand_patterns.angle_degrees`),
  the worst is 1.6e-5°.
- The AWAY rotation maxima (head 0.053021° at frame 471, neck 0.033771° at
  481) sit inside a transition-schedule artifact: for frames 462–471 the
  implied blend fraction runs up to 0.00133 s ahead of the summed
  deltaTime, then tracks it to 1e-6 s again. The blend formula is ruled
  out — every other transition frame of this and the FORWARD capture
  matches, angles and `fixAngle` match throughout, and the head matches
  exactly from frame 472 on — and the trace records no timer field to
  identify what advanced it, so `compare_neck_look.py` gives this run1
  feature a documented ceiling
  (`AWAY_BLEND_ANOMALY_CEILING_DEGREES` 0.06) instead of the 0.05° TARGET
  rotation target; TARGET rotations stay at 1.6e-5°.

Recovered, ported and capture-verified since (the angle-geometry slice and
its port are described after the fixture paragraph below); what remained at
that slice, all wired since (gaze-wiring paragraph after the fixture):

- `GetAngleToTarget`'s geometry (target transform → `nowAngle`) was ported
  (`SourceStudioNeckTargetAngle.angleToTarget`) with no caller feeding it a
  live target.
- **AWAY's own `nowAngle` adjustment** — the run1 AWAY phase holds `nowAngle`
  y at a constant −60 on all 90 frames (x drifts 11.299–11.360) while the
  neck turns — is `away_adjust` (Python) /
  `SourceStudioNeckTargetAngle.awayAdjust`, applied to the raw angle only
  when the limit check is intact: with `num4` the bones' pre-smoothing
  `angleH` sum, if raw y ≤ `num4` it becomes the `aParam` maximum-bending
  sum (here +40 + 20 = +60) when raw y ≤ that sum − `limitAway` or raw y < 0,
  otherwise the minimum-bending sum; if raw y > `num4` it becomes the
  minimum-bending sum (−40 − 20 = −60) when raw y ≥ that sum + `limitAway`
  or raw y > 0, otherwise the maximum-bending sum; then x is negated. The
  −60 the capture holds is that minimum-bending sum — the earlier
  "`hAngleLimit` 80 − `limitAway` 10" reading gives 70 and was wrong. All
  90 AWAY frames read raw y ≈ +44.62 above the previous recorded frame's
  `angleH` sum and above 0, take that branch, and the adjusted prediction
  then matches the recorded `nowAngle` to 0.003664° x / 0.000000° y. The
  replay above still feeds the recorded `nowAngle` unchanged and matches
  downstream of that adjustment.
- **Limit-break handling**: the limit test (|signed angle about NeckRef's up
  or right axis| > limit + correction, correction 0 while the live state is
  `isLimitBreakBackup`) and its `nowAngle` `[0, 0]` zeroing are ported as
  `SourceStudioNeckTargetAngle.limitCheck`, matching the geometry capture's
  behind-target phase (broken on all 60 frames, recorded `[0, 0]` on every
  one), and AWAY's adjustment runs only on intact frames.
  At that slice `SourceStudioNeckLookSettings` decoded only `aParam`/
  `leapSpeed` per state and the limit fields were plain per-call arguments;
  the gaze-wiring slice below moved them into the loader as per-state
  `hAngleLimit`/`vAngleLimit`/`limitBreakCorrectionValue`/`limitAway` arrays.
- No live `nowAngle` source was wired then, so the preview override reported
  TARGET/AWAY as "Neck gaze solver pending; animated pose kept."; the
  gaze-wiring slice below feeds the live camera target, the frame's own head
  rotation and the bones' `angleH` through a new `SourceStudioNeckLookRuntime`.

`SourceStudioNeckLook.stepSolver` ports the distribution, smoothing, basis
and blend above; its settings loader decodes each type state's `aParam`
bending limits and `leapSpeed`, and `SourceStudioNeckLookTests` replays the
fixture's 6-step `solverSequence` (two TARGET frames, a zero-delta frame
where both rotations come back nil, the TARGET → AWAY switch, a
saturated-factor frame where the head's ±20° share spills onto the neck, and
a steady AWAY frame) to ≤1e-5, asserting the spill lands the head exactly on
its own `minBendingAngle`.

`Packages/Engine/Sources/Studio/SourceStudioNeckTargetAngle.swift` ports the
angle geometry itself, in double precision over plain positions and Unity
x,y,z,w quaternions with no rig access: `angleAroundAxis`, `fromToRotation`
(shortest arc; antiparallel pairs rotate 180° about `Cross(RIGHT, from)`,
`Cross(UP, from)` when that degenerates), `limitCheck`, `angleToTarget`
(the frame-k-head formula of the capture slice) and `awayAdjust` (Float
widens to Double exactly, so the bending sums match the oracle bit for
bit). `neck_target_angle.py --fixture` writes 28 seeded SYNTHETIC cases (no
original-game data) to
`Packages/Engine/Tests/EngineTests/Fixtures/neck-target-angle.json` — four
randomized aim/NeckRef/head transform sets × seven target azimuths, 10
TARGET / 18 AWAY, 17 breaking the limit (4 under `isLimitBreakBackup`,
where correction 0 still leaves them broken) and the 7 intact AWAY cases
splitting 2 raw-y-above / 5 at-or-below the bone `angleH` sum — each with
the oracle's limit angles, raw and adjusted angles.
`SourceStudioNeckTargetAngleTests` re-runs every case natively and matches
to ≤1e-6°, asserts broken cases zero the adjusted angle and TARGET cases
pass the raw angle through, and checks degenerate inputs (target on the aim
origin, zero-length direction, empty bone list, non-finite angle) throw.
What the port did not yet have was preview wiring; the gaze-wiring slice
below feeds a live camera target, the frame's own head rotation and the
bones' current `angleH` and writes the result onto the pose.

### TARGET / AWAY gaze wiring in the Studio preview

`Packages/Engine/Sources/Studio/SourceStudioNeckLookRuntime.swift` carries
the TARGET/AWAY half of `NeckLookCalcVer2` across frames: a
`SourceStudioNeckLook` solver plus the per-state `isLimitBreakBackup` flag,
seeded the way a loaded scene finds it (lookType ANIMATION, `fixAngle` = the
saved angle, so the first frame runs the same `UpdateCall` type-change
transition FIX/FORWARD use). `update(deltaTime:lookType:pattern:settings:
geometry:)` runs the original LateUpdate order per frame: the type-change
transition (a zero deltaTime stops there, as `NeckUpdateCalc` early-outs),
then `limitCheck` on the `NeckRef` Transform with the pattern's
`hAngleLimit`/`vAngleLimit` and correction 0 while `isLimitBreakBackup` is
set. That lifecycle is the recovered one: `NeckUpdateCalc` uses
`isLimitBreakBackup ? 0 : limitBreakCorrectionValue` and stores the frame's
broken result back into the flag. It matches the recorded broken frame's
zeroing and the intact frame's restore in phase 4. Otherwise `angleToTarget`, plus
AWAY's `awayAdjust` on intact frames only with the bones' pre-smoothing
`angleH` sum (the same end-of-frame semantics as the capture's
previous-recorded-frame reading), then `stepSolver` with the angle pair
narrowed to Float at that seam. The geometry arrives as a
`SourceStudioNeckLookGeometry` in the Unity basis — `aim` position/rotation,
`NeckRef` position/rotation, the head's current world rotation (the last
configured bone's own Transform: the probe records `headBone` as
`RequiredTransform(lastBone, "neckBone")`) and the target position — so the
runtime is testable with hand-made geometry and no rig.

The settings loader gained the four captured limit fields per state
(`hAngleLimit`/`vAngleLimit`/`limitBreakCorrectionValue`/`limitAway`) and
`SourceStudioCharacterPreview` keeps one runtime per character when the
effective pattern is TARGET or AWAY with `neckTargetType` 0 (the main
camera; any other target type has no recovered meaning and keeps the
animated pose with a diagnostic). `updateNeckLook(deltaTime:
cameraModelPosition:…)` builds the geometry from the cached
*pre-override* pose — the FK/IK-solved pose before the look override wrote
anything, the pose the original `LateUpdate` reads, since Unity's animation
update overwrites the bones each frame before `LateUpdate` and the solver
never reads its own last write — with `UpdateCall`'s TARGET write-back
applied first: each bone's previous `fixAngle` goes back onto
`cf_j_neck`/`cf_j_head` before the head rotation is read, which is what
reconciles the capture's same-frame head rotation (≤0.082° x / ≤0.017° y
over all 300 TARGET frames). The camera enters rig model space as
`UnityCoordinates.position(world.inverse.transformPoint(camera.position))`
against the character's object world matrix; the Z reflection commutes with
that mapping exactly for rigid world matrices, the same rigidity assumption
the engine's placement already makes (non-uniform or sheared object scales
would break it — not exercised anywhere in the Studio preview). The Studio
tick calls `updateNeckLook` (1/30 s) per live-gaze character *before*
`setDynamicsStep` and `refresh`, so the pose the solver samples integrates
no hair particles and `refresh` integrates them exactly once;
`editedPose` then writes `lastLocalRotations` onto the two bones for
TARGET/AWAY exactly like FIX/FORWARD (translation and matrix-derived scale
kept, FK-owned neck skipped with the same once-per-lookType report).
A malformed pair is dropped after one diagnostic — a partial write rolls
back to the pre-override pose, so the animated neck keeps rendering instead
of failing every later frame. `resetNeckLook` rebuilds the runtime from the
saved `fixAngle` on every `resetAnimationPlayback` (seek, scene load), and
the first step of an episode at elapsed 0 runs with the documented 1e-5
first-frame delta, mirroring `applied(pose:)`.

`SourceStudioNeckLookRuntimeTests` (5 tests, hand-derived numbers cross-
checked against the `neck_target_angle.py` oracle, no rig): a straight-ahead
target solves to identity everywhere; a level 30° side target distributes
head-first and smooths 1/15 per frame (first frame's written yaw is exactly
2 × the hand-evaluated curve value 0.07424433815920793; 400 frames converge
the head onto 30° with the neck's share pinned at 0); a behind target
breaks, relaxes 30·14/15° in one frame, and the `isLimitBreakBackup` →
correction-0 → restore lifecycle tracks the check across break → intact →
break; AWAY holds the −60 demand split −40/−20 and ten broken frames relax
the neck to −40·(14/15)^10; and foreign settings, non-solver types, a
pattern outside the seven states, a negative deltaTime and a target on the
aim origin throw without mutating the carried state (a zero-delta frame
still leaves a written pair untouched). The Studio tick, the camera mapping
and the write-back geometry have no rig-level test and no rendered
comparison against the original preview — the wiring is verified by the two
app/Engine builds and the runtime tests alone.

### Eye look solver

The eyes have their own calculator, `EyeLookCalc.EyeUpdateCalc`, whose rules
the look capture pinned down and `analysis/eye_look_reference.py` reproduces
in Python (the Swift port arrived with the following slice; see the port
paragraph at the end of this section). One frame, in execution order:

- `deltaTime == 0` returns the carried state untouched — no rotation, no
  `num5` (the reference returns `None` rotation fields) — but the frame's two
  angle rates are still recomputed, from the carried angles (below).
- The target resolution runs once per frame for both eyes: non-TARGET types
  first push a closer-than-`nearDis` target out to `normalize(v) · nearDis`;
  the horizontal check `Angle((v.x, root.forward.y, v.z), forward)` and the
  vertical check `Angle((root.forward.x, v.y, v.z), forward)` against
  `hAngleLimit`/`vAngleLimit` (both strict `>`) switch the frame to FORWARD,
  whose aim is the point `forntTagDis` ahead of the `frontCorrect` node (the
  rootNode child at local position 0, local euler (5,0,0) — 5° pitched
  down).
- With `correct == 1` and a TARGET/FORWARD frame, the aim goes through the
  `trfCenter` eye-target frame: `InverseTransformPoint(target)` with z
  clamped to ≥0.5, then a frame at the center facing the clamped point
  (`LookRotation` of the normalized direction, up rebuilt as
  `Cross(Cross(up, n), n)`) places the per-eye targets at
  `±centerEyeLength` (0.05) along its x — left eye −, right eye +. The
  offsets therefore ride the frame's tilt, and the two eyes read unequal
  azimuths to a dead-ahead target.
- Per eye the direction `normalize(aim − eyePos)` into the parent's frame
  gives `angleH` = signed angle of `referenceLookDir` to it about
  `referenceUpDir`, and `angleV` = the angle between the direction and its
  own projection with `referenceUpDir` dropped, measured about
  `Cross(referenceUpDir, direction)` — a target below the reference plane
  reads positive, so "up" on this axis is upBendingAngle (−30 captured) and
  "down" is downBendingAngle (10).
- Bending per axis: dead-band past `thresholdAngleDifference`, then
  `max(|excess| · |bendingMultiplier|, |angle| − maxAngleDifference) ·
  sign(angle) · sign(multiplier)` (captured 0.4 and 10: the branches cross
  at |angle| = 16.667, so `h = 15 → 6`, `h = 40 → 30`); clamps then
  `minBendingAngle..maxBendingAngle` (−36..23) on the left eye's horizontal
  and its mirror −`maxBendingAngle`..−`minBendingAngle` (−23..36) on the
  right — asymmetric ranges, which the capture's opposite-sign eye pairs
  confirm — while both eyes share `upBendingAngle..downBendingAngle`.
- AWAY replaces the horizontal through the sorasi branch: with `num5` at
  its frame-local −1, the previous and measured angles' coordinates
  `a = Lerp(−1, 1, InverseLerp(−maxBending, −minBending, angle))` are
  compared; within `sorasiRate` (1.0) of each other f is remapped from a
  coordinate pushed `sorasiRate` off the measured one (so a demand close to
  the current angle overshoots to ±1 coordinate past it), farther apart f
  keeps the previous angle; either way `num5` arms to the clamped
  coordinate and then determines f alone through
  `Lerp(−maxBending, −minBending, num5)` — a sticky saturated end that only
  the frame-local reset releases. The left eye arms, the right eye reads.
  AWAY also negates the bent vertical angle.
- Smoothing `angleH += (f − angleH) · clamp01(dt · leapSpeed)` per axis;
  the look direction is `AngleAxis(angleH, referenceUpDir) ·
  AngleAxis(angleV, Cross(referenceUpDir, referenceLookDir))` applied to
  `referenceLookDir`; `OrthoNormalize` against `referenceUpDir` yields the
  tangent that `Vector3.Slerp(dirUp, tangent, dt · 5)` eases the carried
  `dirUp` toward, and a second `OrthoNormalize(look, dirUp)` yields the
  normal. The writeback is
  `local = LookRotation(normal, dirUp) · inv(LookRotation(referenceLookDir,
  referenceUpDir)) · origRotation`, world = parent · local.

`compare_eye_look.py` replays all eight phases of the run1 look capture
(570 frames, phases 0-based, patterns [1,1,3,0,1,1,2,1]) one frame at a
time from the recorded state of the frame before (angleH/angleV from its
`eyes.eyes[i]`, dirUp from its `geometry.eyes[i].dirUp`) with the replayed
frame's own geometry, target and deltaTime; frame 0 starts warm and is
reported seed-only (0.247°). Maxima per phase and eye (degrees, frames of
the maximum):

| phase | lookType | eye | \|ΔangleH\| | \|ΔangleV\| | localRotation | dirUp |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | TARGET | L | 0.000472 (2) | 0.000208 (56) | 0.000473 (2) | 0.000208 (56) |
| 0 | TARGET | R | 0.000188 (1) | 0.000180 (51) | 0.000218 (51) | 0.000180 (51) |
| 1 | TARGET | L | 0.000021 (175) | 0.000208 (175) | 0.000210 (175) | 0.000208 (175) |
| 1 | TARGET | R | 0.000020 (94) | 0.000203 (178) | 0.000205 (178) | 0.000203 (178) |
| 2 | AWAY | L | 1.427047 (189) | 0.217204 (203) | 1.429340 (189) | 0.217164 (203) |
| 2 | AWAY | R | 1.422877 (189) | 0.224451 (203) | 1.425252 (189) | 0.224406 (203) |
| 3 | FORWARD | L | 0.000017 (328) | 0.000008 (288) | 0.000017 (328) | 0.000008 (288) |
| 3 | FORWARD | R | 0.000150 (328) | 0.000009 (310) | 0.000150 (328) | 0.000009 (310) |
| 4 | TARGET | L | 0.001063 (367) | 0.000003 (341) | 0.001062 (367) | 0.000011 (330) |
| 4 | TARGET | R | 0.001059 (367) | 0.000003 (341) | 0.001059 (367) | 0.000011 (330) |
| 5 | TARGET | L | 0.000013 (442) | 0.000184 (442) | 0.000185 (442) | 0.000184 (442) |
| 5 | TARGET | R | 0.000024 (421) | 0.000104 (449) | 0.000104 (449) | 0.000103 (449) |
| 6 | CONTROL | L | 40.360349 (450) | 3.158244 (450) | 40.473714 (450) | 3.265856 (450) |
| 6 | CONTROL | R | 27.987746 (450) | 2.998246 (450) | 28.141165 (450) | 3.060185 (450) |
| 7 | TARGET | L | 0.000006 (516) | 0.000014 (541) | 0.000126 (527) | 0.000126 (527) |
| 7 | TARGET | R | 0.000005 (515) | 0.000020 (541) | 0.000082 (526) | 0.000081 (526) |

Five of the eight phases (all TARGET ones except phase 4, and FORWARD)
match at ≤4.7e-4° against a 1e-3° angle target, and the rotation error
tracks the angle error to <1e-6 wherever the angles match — the writeback
adds nothing measurable. Two facts came out of the replay itself:

- The replay is sensitive to the recorded state chain: replaying from a
  frame's own recorded state (instead of the frame before) pins the state
  inputs but hides upstream errors; the frame-before chain is what makes
  the horizontal offset in phase 0 — the R eye a sustained +1.8e-4° from
  its very first frame, the L eye alternating +2.8e-4° with −4.7e-4°
  across its opening frames, both settling to +1…3e-4° — a live-model
  difference, not noise.
- Phase 4 sits a hair over target (0.001063°): the predicted `|angleH|`
  exceeds the recorded one by ≈7e-4° at the phase start (7.7e-4° at frame
  330, both eyes, the sign following each eye's own angle sign) and the
  gap widens as the angle settles — by frame 367 both eyes record exactly
  0.000000 where the prediction still holds ±0.001063, so the recorded
  angle reaches zero a touch earlier than this chain does. The bend-chain
  multiplier 0.4 (float32 0.40000000596…) against the |angle| − 10 branch
  near the capture's operating azimuth is the suspected rule line; per the
  slice's stop-tuning rule the comparator reports it as a miss with its
  first frames instead of the offset being absorbed.

Not ported or not verified, and kept out of the claims:

- **NO_LOOK** (and the `fixAngle` it would write) is never exercised by the
  capture; the reference and the Swift port both raise a diagnostic error
  there.
- **AWAY (phase 2)** misses at 1.43° horizontal / 0.22° vertical: the
  recorded per-eye internals are completely frozen for all 90 frames —
  identical `angleH` (0.9121025 / 0.8422239), `angleV` (−0.1336779 /
  −0.1425089), `localRotation` and `dirUp` on every frame despite
  `deltaTime` varying 0.0040–0.0314 s and the head yawing 97.5° (frame
  269's `eyeCalc.rootNode` vs frame 180's) — while the predicted chain
  moves every frame. Tuning stopped
  per the rule; the suspected rule lines are AWAY's writeback or
  the capture's recording of the eye internals in this phase, not the
  sorasi branch (its armed `num5` 0.8921611 reproduces frame-for-frame
  under this geometry).
- **CONTROL (phase 6)** misses at 40.4°: both recorded channels follow a
  slow exponential toward a fixed hold instead of the front point — every
  frame-to-frame step of the whole phase is reproduced by blending toward
  angleH = 0.0000 / angleV = +2.0356 at rate 2.5 (the implied horizontal
  target is 0.0000 with worst |implied target| 0.00003° over all 60 frame
  pairs and both eyes; the implied vertical is constant to 1e-4;
  `deltaTime` 0.0042–0.0314 s), and 2.5 is AWAY's captured leapSpeed, not
  CONTROL's own 42.5. The prediction instead aims at the front point at
  42.5: the horizontal swings negative (−33.891 / −21.531 at frame 450)
  where the record decays +6.469 → +0.532, and the vertical front-point
  elevation oscillates +1.78…+3.70 where the record creeps +0.374 →
  +1.899. Suspected rule lines: whose leapSpeed and which hold target the
  original actually applied in this phase (the record reads as a stale
  AWAY-rate blend toward a fixed angle pair); unresolved, reported by the
  comparator.
- **Not wired into the preview**: the solver has its Swift engine and fixture
  (port paragraph below) but no preview caller yet — the Studio preview
  still shows the animated pose for the eyes. What remains is the gaze
  wiring: feed the Studio camera position as the eye target each frame
  (with the `trfCenter`/`rootNode` geometry of the character being
  previewed), plus the two documented capture-rule misses above (AWAY
  1.43°, CONTROL 40.4°) and the unexercised NO_LOOK `fixAngle` write.

`Packages/Engine/Sources/Studio/SourceStudioEyeLook.swift` ports the solver
in Swift (`SourceStudioEyeLookSolver.step(deltaTime:target:geometry:pattern:)`
returning the two Unity-basis `localRotation` quaternions, with the carried
`angleH`/`angleV`/`dirUp` and the frame's `num5` on the solver; the decodable
`SourceStudioEyeLookSettings` reads the `studio_look_settings.py` eyes JSON
— `correct`, `centerEyeLength`, `sorasiRate` and the 12 numeric fields of
each `eyeTypeStates` entry plus its lookType, which may arrive as a bare
string or the capture's `{name, value}` record). Unity math missing from the neck port —
`Mathf.Lerp`/`InverseLerp` clamping, `Vector3.Angle`-style helpers,
`Project`, `Slerp`, `OrthoNormalize`, left-handed `LookRotation`, inverse
quaternion, `TransformPoint`/`InverseTransformPoint` with `lossyScale` —
lives as internal helpers there, reusing the neck port's
`SourceStudioNeckTargetAngle` rotate/angleAxis. `deltaTime == 0` returns
`nil` rotations and leaves the angles and `dirUp` untouched while recomputing
the frame's rates from them, mirroring the reference — the consequence of
resolving the pattern before that early return is that an unknown pattern now
throws on a zero-delta frame too, as it already did in the reference.
`eye_look_reference.py --fixture` writes
`Packages/Engine/Tests/EngineTests/Fixtures/eye-look-reference.json` — 25
SYNTHETIC sequences (hand-picked numbers, no capture data; the reference
replays its own written fixture byte-exactly, so regeneration is stable to
the SHA) — with 59 frames covering TARGET/FORWARD/AWAY/CONTROL effective
types, both limit switches and the nearDis push-out at 1.0/1.99/2.0, all
four sorasi routes (keep / push-negative / push-positive / exactly-equal,
plus armed-`num5` reads on both eyes), a zero-delta frame, tilted eye
references, a moving root, non-uniform `lossyScale` and a target sitting on
an eye pivot, every frame recording its `angleHRate` pair and single
`angleVRate`. `SourceStudioEyeLookTests` replays it to ≤1e-5° on angles,
1e-6 on quaternion/direction components and 1e-6 on both rates, pins the bend
dead-band, the L/R mirror clamps and the four sorasi routes against
hand-computed reference values, checks the rate formula and the
initialization composition against hand-computed values (next subsection),
and checks non-finite inputs, out-of-range patterns, NO_LOOK,
wrong eye counts, zero forward/up directions (`lookRotation`, `project` and
the correct frame's "parallel to the up axis" error) throw.

### Angle rates and initialization

Two numbers per frame leave the calculator besides the angles, and
`EyeLookMaterialControll` is their consumer: it shifts the iris textures by
them (the horizontal pair per eye, one vertical for both). They are read
straight off the calculator, so a preview that wants the iris motion needs
them and the initialized reference frame the solver measures against.

`EyeUpdateCalc` recomputes them at the very end of every frame, from the
frame's NEW `angleH`/`angleV` and the pattern's type state — including the
`deltaTime == 0` frame, where nothing stepped and the angles are the carried
ones:

- `angleHRate` per eye: `Lerp(−1, 1, ratio)` over the bending range, with the
  left eye reading `InverseLerp(minBendingAngle, maxBendingAngle, angleH)`
  and the right eye the mirror `InverseLerp(−maxBendingAngle,
  −minBendingAngle, angleH)` — the same pair of ranges the angle clamps use.
  The rate's `InverseLerp` is `Mathf.InverseLerp`'s clamped 0…1 readout except
  that an empty range (`a == b`) reads 0 rather than 1, so a degenerate type
  state gives `Lerp(−1, 1, 0) = −1` instead of saturating.
- One `angleVRate`, from **eye 0's** `angleV` only: if
  `downBendingAngle <= upBendingAngle` a non-negative angle reads
  `−InverseLerp(0, upBendingAngle, v)` and a negative one
  `InverseLerp(0, downBendingAngle, v)`; otherwise the two divisors swap. The
  shipped pair (`upBendingAngle` −30, `downBendingAngle` 10) has 10 > −30 and
  takes the swapped branch: a non-negative angleV — a target below the
  reference plane in this axis's convention — divides by `downBendingAngle`
  10 and is negated, a negative one by `upBendingAngle` −30. Because the
  final `Lerp` keeps the value in [−1, 1] and the `InverseLerp` clamps, an
  angle past its range saturates.

`angle_rates` (Python) and `angleRates` (Swift, the rate `InverseLerp` its
own `rateInverseLerp`) implement this, and the capture pins the arithmetic:
phase 0 frame 5 has L `angleH` 0.04187133 → `angleHRate` 0.2217584, R
−0.04111683 → −0.2217328, and eye 0 `angleV` 0.472471 → `angleVRate`
−0.0472471 (0.472471 / 10 negated). Both are recomputed by `step` and read
back as `angleHRates` (L, R order) and `angleVRate`, zero before the first
frame — the original's field default.

`compare_eye_look.py` now replays the rates against every frame's recorded
`calculators[0].angleHRate` / `angleVRate` (a two-entry `angleHRate` and a
finite `angleVRate` are required per frame). Maxima, in rate units:

| phase | lookType | \|ΔangleHRate\| L / R | \|ΔangleVRate\| |
| --- | --- | --- | --- |
| 0 | TARGET | 0.000016 (2) / 0.000006 (1) | 0.000021 (56) |
| 1 | TARGET | 0.000001 (175) / 0.000001 (96) | 0.000007 (175) |
| 2 | AWAY | 0.048374 (189) / 0.048233 (189) | 0.012809 (203) |
| 3 | FORWARD | 0.000001 (328) / 0.000005 (328) | 0.000001 (288) |
| 4 | TARGET | 0.000036 (367) / 0.000036 (367) | 0.000000 (367) |
| 5 | TARGET | 0.000001 (442) / 0.000001 (421) | 0.000018 (442) |
| 6 | CONTROL | 1.368147 (450) / 0.948737 (450) | 0.315824 (450) |
| 7 | TARGET | 0.000000 (510) / 0.000000 (522) | 0.000001 (541) |

The five phases whose angles match (0/1/3/5/7) reproduce the rates to
≤0.000016 horizontal and ≤0.000021 vertical, and the phase that sits a hair
past the angle target (4) to 0.000036 horizontal. The two real misses carry
through as
far as their angles do (AWAY 0.048 of rate against 1.43° of angle, CONTROL
1.368 / 0.949 against 40.4° / 28.0°, the saturated-looking magnitudes being
what `Lerp(−1, 1, ·)` of an out-of-range `InverseLerp` looks like). Rates are
therefore **reported, not gated** by the comparator — they inherit the
documented AWAY and CONTROL angle misses, and the comparator still exits 1
on those. The worst measured pair is `angleHRate` 1.368147 and `angleVRate`
0.315824, both phase 6 frame 450; frame 0 stays seed-only.

`initial_eye_state` (Python) / `SourceStudioEyeLookSolver.initialState`
reproduce the calculator's `Init`, which builds the frame every later angle
is measured in. Per eye, with `q = inverse(eyeTransform.parent.rotation)`:
`referenceLookDir = q · rootNode.rotation · normalize(headLookVector)`,
likewise `referenceUpDir` from `headUpVector`, `angleH = angleV = 0`,
`dirUp = referenceUpDir` and `origRotation = eyeTransform.localRotation`.
The settings give `headLookVector` (0, 0, 1), `headUpVector` (0, 1, 0),
`rootNode` `p_cf_head_bone`, `trfCenter` `cf_J_Eye_tz` and the two eyes as
`eyeLR` 0 → `EyeTargetL`, 1 → `EyeTargetR`; outputs come back in `eyeLR`
order whichever order the eyes arrive in, and the Swift helper throws unless
there is exactly one eye per `eyeLR`, a non-finite input or a zero head
vector. The head vectors are normalized, so a longer `(0, 0, 2)` reads
identically. A scene load then restores over the initialized state: the
saved eye bytes (`SourceStudioEyeLookData`: two `fixAngle` quaternions, plus
`angleH[0..1]`/`angleV[0..1]` when the scene data version is ≥ 0.0.8)
replace the two zero angles, while `dirUp` keeps the Init value — nothing in
the saved bytes carries it.

Verified by 9 new unittest cases (`AngleRatesTests`, `InitialEyeStateTests`,
41 in the module) and 1 new Swift test (5 in the file, `swift test` 478
passing): the check values above at 1e-6 / 1e-9, ±13/59 for both eyes at
angle 0, saturation at ±100, the empty-range 0 readout, both vertical branch
orders, rates on both `step` paths, and an Init whose root is rotated 90°
about x under an eye parent rotated 90° about z — base 180° about
(−1, 0, 0)/√2, head forward (0, 0, 1) → (−1, 0, 0) and head up (0, 1, 0) →
(0, 0, 1) — at 1e-9. The rates are also in the regenerated
`eye-look-reference.json`, which stays byte-stable across regenerations.

### Eye look in the Studio preview

The preview now runs the calculator itself and reports its rates; what it
does not yet do is render them. `SourceStudioEyeLookRuntime` (Engine
`Studio`) carries one `EyeLookCalc` across frames — the solver, the fixed
Init reference and the last predicted eye rotations — and
`SourceStudioCharacterPreview` keeps one per character when the effective
pattern resolves: the card `eyesLookPtn` wins over the prefab's
`eyeController.ptnNo` (the `AddObjectAssist` order, `LoadAngle` first and
`ChangeLookEyesPtn` last), `eyesTargetType` 0 or absent selects the main
camera while any other target keeps the animated eyes with a diagnostic, and
NO_LOOK is refused there too because its `fixAngle` write is not recorded by
the look trace. The saved `angleH`/`angleV` pairs (scene version ≥ 0.0.8,
`SourceStudioEyeLookData`) replace the Init zeros through the runtime's
`savedAngles`; before that version the calculator Inits flat instead.

The rig names come from the capture, not from the settings verbatim: the
settings' `rootNode` `p_cf_head_bone` is not a merged-rig node, but the
capture reports it sharing `cf_j_head`'s world position and rotation in
every frame, so `updateEyeLook` uses `cf_j_head` as the root; `trfCenter` is
`cf_J_Eye_tz` (the settings name, with that literal as fallback) and the two
eyes are the `cf_J_Eye_tx_L`/`cf_J_Eye_tx_R` parents. The Maker skeleton
authors the EyeTargets at translation 0 on those parents and the capture
recorded their local rotation as the identity, so the parents' world
positions are the eye positions and `origRotation` is identity. That is
consistent with the eye strip's shape: the capture's EyeTargetL sits about
(−0.0460, +0.0035, +0.0001) m from trfCenter in frame 5 (head nearly
unrotated). The geometry is built exactly like the neck's — the
*pre-override* pose (`evaluatedCache?.preOverride`),
`rig.evaluate(...).worldMatrices`, `UnityCoordinates.matrix` — and the
camera enters rig model space through the same
`UnityCoordinates.position(world.inverse.transformPoint(camera.position))`
mapping as `updateNeckLook`, in its own tick loop so a failing eye frame
never disturbs the neck. The runtime Inits lazily from the first evaluated
frame (Init needs live rig rotations), and `resetEyeLook` — called from
every `resetAnimationPlayback`, the way a scene reload re-runs EyeLookCalc's
`Init` — drops it so a seek re-Inits and restarts the convergence instead of
carrying stale smoothing.

What the slice publishes is the rate pair `EyeLookMaterialControll` would
shift the iris textures by: `eyeLookRates` gives the pattern's lookType with
`angleHRates` (L, R) and `angleVRate`, and the Studio inspector shows
`Eye look: TARGET · H L/R +0.22/−0.22 · V −0.05` for the selected source
character (2 decimals, signed), or `Eye look: animated (<reason>)` when a
resolved pattern was refused. **No eye bone is written**: the predicted
rotations are carried in `lastRotations` but not applied (the eye-bone write
stays open); the iris rendering — the `angleHRate`/`angleVRate` offset onto the
iris textures — arrived in the iris rendering slice below.
`SourceStudioEyeLookRuntimeTests` (3 tests, synthetic eye strip at
the captured ±0.046 m spread, no rig, no capture data): a straight-ahead
camera gives mirror-symmetric eye angles and exactly opposite horizontal
rates (neither zero, in [−1, 1]); a zero-delta frame keeps angles, rates and
the last written rotations bit-identical while still recomputing the rates
from the carried angles; and saved angles override the Init zeros with the
dirUp frame kept, while a malformed saved pair or settings without head
vectors throw without half-applying. The Studio tick, the camera mapping and
the node-name choices have no rig-level test and no rendered comparison —
verified by the Engine test run (489 passing) and the app build alone.

Simplification resolved by the iris-offset slice: the solver step used to
treat the root node's rotation as every eye's parent frame (the reference's
`v2 = parent^-1 * dir`), which held in the capture only because the fixture's
`cf_J_Eye_tx_L/R` share the head rotation — the original uses each eye's own
`eyeTransform.parent.rotation` in both Init and the step, and a face shape
that tilts the eyes (the eye-angle slider rotates `cf_J_Eye_rz_L/R`) makes
the two disagree. `SourceStudioEyeLookGeometry.Eye` now carries an optional
`parentRotation`; when present the step reads that eye's angles through its
inverse and its writeback composes through that parent, when absent the root
inverse the fixtures measured against is kept. No existing fixture eye
carries one, so the 25-sequence replay is byte-identical — the Python
`eye_update` mirrors this through each eye geometry's optional `parent`, and
`test_per_eye_parent_tilts_only_its_eye` shows a 20° tilt on eye 0's parent
moving eye 0 alone (>1° of `angleH`; eye 1 identical to 1e-12), the writeback
equal to the parent composed with the returned `localRotation`, and an
identity parent matching the root-only result to 1e-12. `updateEyeLook`
supplies the live `cf_J_Eye_tx_L/R` world rotations — the same ones the Init
path already reads. The inspector readout is not observed per tick: it
refreshes when the inspector redraws for another reason.

### Iris offsets

`EyeLookMaterialControll` is the rates' consumer: each frame it shifts the
iris textures on the eye's materials. Its settings are serialized in the
head prefab, and `Tools/reverse/studio_look_settings.py` now exports them —
every `bo_head_*.unity3d` under the chara bundle dir is provenance-sha
checked and every `EyeLookMaterialControll` MonoBehaviour written into a
top-level `eyeMaterial` array (per eye: `eyeLR`, every serialized field, the
renderer's GameObject name and material names), bundles without the
component skipped and anything but exactly one L and one R a diagnostic.
Only `bo_head_00.unity3d` carries it, on `cf_Ohitomi_L02` (eyeLR 0) and
`cf_Ohitomi_R02` (eyeLR 1); the component's `_renderer` PPtr is null in the
prefab, so the material names (`cf_m_hitomi_00`) come from the eye's own
SkinnedMeshRenderer. Rerunning the exporter produced a document identical to
the previous settings JSON except the added `eyeMaterial` block and its two
evidence entries (`test_studio_look_settings` 11 cases: a synthetic typetree
keeps every field, and dropping `power`, `texStates` or `YureTime` throws).

Both exported eyes carry `InsideWait` −100 / `OutsideWait` 100, `UpWait`
−100 / `DownWait` 100, limits −100/+100 horizontal and `UpLimit` −80 /
`DownLimit` 80, power 0.0010000000474974513, `offset` L (−0.2, −0.2) /
R (+0.2, −0.2) (float32 0.20000000298023224), `scale` (0, 0), both highlight
offsets 0, texStates `_MainTex`/`_overtex1`/`_overtex2` (texID −1 sentinels,
none Yure), Yure 4/−4/4/−4 at `YureTime` 0.30000001192092896.
`Packages/Engine/Sources/Studio/SourceStudioIrisOffset.swift` decodes the
block (`SourceStudioEyeMaterialSettings`, a sibling document decoder so the
solver's minimal fixtures keep parsing) and `textureTransforms` replays
`EyeLookMaterialControll.Update`:

- `v = (rateH + offset.x, rateV + offset.y)`, re-normalized onto the unit
  circle only when |v| > 1 (strict — |v| = 1 stays as authored);
- `num = Lerp(InsideWait, OutsideWait, InverseLerp(−1, 1, v.x))` and
  `num2 = Lerp(DownWait, UpWait, InverseLerp(−1, 1, v.y))` — **Down first**,
  so with the exported waits v.y +1 reads `UpWait` −100 and v.y −1 reads
  `DownWait` 100;
- `num3`/`num4` = `Lerp(1, 5, scale.x)`/`Lerp(1, 5, scale.y)`;
- per texState the offset is `(Clamp(num·power·num3, InsideLimit,
  OutsideLimit), Clamp(num2·power·num4, UpLimit, DownLimit))` with power
  stepped by (0.8, 0.5) on a Yure texture, and `hlUpOffsetY`/`hlDownOffsetY`
  added to texStates 1/2's y **after** the clamp (never to x, never to
  texState 0);
- a non-Yure entry then subtracts `scale/2` from its offset and writes
  texture scale `1 + scale`; a Yure entry writes neither.

`SourceStudioIrisOffsetTests` (9 tests) pins every branch at 1e-15 relative
against hand-computed double values: the exported block decodes field by
field and malformed vectors/texStates throw; rates (0, 0) with the exported
Reset-default snapshot rest the main tex at (−0.020000001247972264,
+0.020000001247972264) L / (+0.020000001247972264, +0.020000001247972264) R
with texture scale (1, 1) on all three textures; (3, 4) and (0.6, 0.8) read
the identical shift (the normalization gate and the waits' signs); tightened
`OutsideLimit`/`DownLimit` stop a full deflection while an inverted clamp
range throws; the highlight offsets touch only textures 1 and 2; a non-Yure
scale (2, 4) gives offset −0.75/−2 and texture scale (3, 5).

Not done here: the random `YureAddScale`/`YureAddVec` jitter a Yure texture
re-rolls every `YureTime` is unmodeled (the entry returns its unjittered
offset and identity texture scale with `yure` set, so callers can tell); the
card fields that drive `offset`/`scale`/`hlUpOffsetY`/`hlDownOffsetY` at run
time were unrecovered then, so `textureTransforms` takes them as per-call
arguments and the export carries the prefab's serialized snapshot (the card
pupil slice below recovers the driving fields and applies them). Writing
the transforms onto the iris materials arrived in the iris rendering slice
below; the predicted rotations onto the eye bones are still not applied.
Engine `swift test` 498 pass (the 9 new tests), the `eye_look_reference`
module is 42 with the per-eye-parent case.

### Iris rendering

The transforms now reach the GPU. `MaterialUniforms` gained three
`vector_float4` iris `_ST` vectors — `irisST0` (`_MainTex`), `irisST1`
(`_overtex1`), `irisST2` (`_overtex2`) — in the Unity layout
`(scaleU, scaleV, offsetU, offsetV)` that is exactly what `textureTransforms`
already returns, and `MaterialUniforms.make` defaults each to the identity
`(1, 1, 0, 0)`; the stride went 288 → 336 and moved `sourceAlphaA`/
`sourceAlphaB` from 280/284 to 328/332 (both layout assertions updated).
`Toon.metal` applies `uv' = uv * irisST.xy + irisST.zw` to the base sample and
to the two highlight overlays, each only under
`MaterialFlagSourceIrisHighlights`, so every non-iris material keeps its
previous sampling untouched and an identity `_ST` reads the identical texel.
The sampler question settled with the uniforms: `cw_t_hitomi_012`,
`cw_t_hitomi_hi_u_002` and `cw_t_hitomi_hi_d_002` all serialize the legacy
`m_WrapMode` 1 (Clamp; the read was validated against a known-Repeat texture
in the same bundle), so the three iris samples use a linear clamp-to-edge
sampler and the old "authored repeat" expectation for out-of-range iris UVs
became a clamp expectation — uv1 1.375 and uv2 −0.375 now read the edge
texels (composition (0.140625, 0.2265625, 0.33203125, 0.125)).

`SourceStudioCharacterPreview` loads the `eyeMaterial` block from the same
`IKKOKU_STUDIO_LOOK_SETTINGS` document with the iris-offsets decoder (a
malformed block reports one message at init and leaves the irises at
identity), and `frame(camera:...)` rewrites the iris items' uniforms after the
world multiply on every frame. An item is an iris when its material carries
`MaterialFlagSourceIrisHighlights` and its mesh name resolves to an exported
eye through `SourceStudioIrisRendering.eye(ofMeshNamed:)` — the loaded
`cf_Ohitomi_L02/0` carries the GLTF primitive suffix the export's `gameObject`
does not, so the match strips a trailing `/digits` component. The rates come
from the published `eyeLookRates` — `angleHRates[eyeLR]` per eye and the
shared `angleVRate` — and (0, 0) when the look is not live, which is not "no
offset": the original's `Update` runs its resting readout too, on whichever
`offset`/`scale`/`hl` values the load carries — the card-driven ones since
the pupil slice below, the prefab snapshot only while the card's face record
lacks the fields. A refused transform — only an inverted exported clamp
range can throw — appends one diagnostics line per eye instead of repeating
per frame. `StudioModel`'s
tick calls `refresh()` unconditionally after stepping eye look and
`frame(camera:)` recomputes the rates per call, so a rate change reaches the
next render; that is verified by inspection, not by an automated redraw test.

At character load CharaStudio overrides the prefab's serialized values on both
eyes' `EyeLookMaterialControll` from the card's face record, in six
`ChangeSettingEye*` calls: `hlUpOffsetY = Mathf.Lerp(0.1, -0.1, face.hlUpY)`,
`hlDownOffsetY = Mathf.Lerp(0.1, -0.1, face.hlDownY)`,
`offset.x = Mathf.Lerp(0.2, -0.6, face.pupilX)` handed to both eyes'
`SetEyeTexOffsetX` — which stores the negation for the right eye —
`offset.y = Mathf.Lerp(-0.5, 0.5, face.pupilY)`, and
`scale = (Mathf.Lerp(1.8, -0.2, face.pupilWidth), Mathf.Lerp(1.8, -0.2,
face.pupilHeight))`. `Mathf.Lerp` clamps `t` to 0…1. Every one of the six
returns early, applying nothing and keeping the prefab values, when
`sex == 0 && exType == 1` (the special male assembly).
`SourceStudioIrisRendering.cardOverrides` replays these once per character
from the face record's `face.pupilX/pupilY/pupilWidth/pupilHeight/`
`face.hlUpY/face.hlDownY` (the `ChaFileFace` defaults 0.5, 0.5, 0.9, 0.9,
0.5, 0.5 are what an untouched card carries, and `ComplementWithVersion`
fills them with 0.5 for face versions below 0.0.2), returns nil under
the skip condition, and `transforms(rateH:rateV:settings:card:)` substitutes
the values for the snapshot — negating `offset.x` per eye where
`SetEyeTexOffsetX` does. At the defaults the resting write is
(−0.02/+0.02, 0): the horizontal coincides with the prefab snapshot's
±0.020000001247972264 but the vertical grounds from its +0.020000001247972264
to 0. A face record without all six fields keeps the whole snapshot with a
diagnostic — the original's decoded records always carry the fields, so a
per-field fallback is not recovered. Eye tilt (`ChangeSettingEyeTilt`: shape
value index 33 sets the eye material float `_rotation` to
`Mathf.Lerp(0.02, -0.02, v)` for L and `Mathf.Lerp(-0.02, 0.02, v)` for R) is
not implemented: its shader meaning is not recovered.

`SourceIrisHighlightTests` adds five Metal expectations to the existing 1×1
harness: `irisST0` offset 0.25 moves uv0 0.125 onto base texel 1's center and
scale 2 onto the 0/1 midpoint, `irisST1`/`irisST2` offset 0.25 move the
highlights onto texels whose alpha wins the component maximum (texel 3's
alpha 1 taking the alpha channel), and an explicit identity `_ST` triple
reproduces the pre-existing composition value bit-for-bit.
`SourceStudioIrisRenderingTests` (9 tests, no Metal, the exported JSON fixture)
pins the mesh-name match (L/R resolve, a material name and a body mesh resolve
to no eye), the resting write of the pinned ±0.02 doubles — narrowed to the
Float the shader reads — into all three `_ST` vectors with scale (1, 1), and
that a live rateH +1 moves the u write to 0.08000000350177286 while a vertical
−1 (normalized onto the unit circle) moves both components. Six card tests
add the ChaFileFace defaults (offset −0.2/0, scale (0, 0), hl 0), the Lerp
endpoints, out-of-range clamping, the `sex == 0 && exType == 1` nil with the
prefab snapshot kept, the right-eye-only negation (+0.03/−0.03 for `offsetX`
0.3) and the default card's end-to-end resting (−0.02/+0.02, 0). Engine
`swift test` 509 pass; the app builds for macOS arm64. Unchanged from the
previous slice: no rendered comparison against the original game's iris motion
exists, the Yure jitter stays unmodeled, the eye tilt `_rotation` float is not
applied, and the predicted eye rotations still never reach the eye bones.

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
