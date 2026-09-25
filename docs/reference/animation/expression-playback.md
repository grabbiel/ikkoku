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
| Eye gaze | `EyeLookController` and `EyeLookCalc`, eye type states, reference directions, transform hierarchy, fixed angles and current target; zero delta-time and enable flags affect evaluation. | Detailed source recovered. Existing neutral expression rendering does not implement these controllers. |
| Neck gaze | `NeckLookControllerVer2`, `NeckLookCalcVer2`, per-bone settings, look-mode changes, previous rotations, target history and an `AnimationCurve`. | Detailed source and saved quaternion framing recovered. Solver, curve evaluation and composition order still needed. |
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
