# Original hair dynamics

Reviewed 2026-09-25 against the working tree. See the [Character audit](../../component-audit/character-and-mods.md) for Maker integration and the [Studio audit](../../component-audit/studio.md) for animation consumers and pending tasks. Evidence counts below describe retained focused runs, not a fresh full-suite result.

The selected original female avatar runs the recovered `DynamicBone` update
in Swift after its original Idle clip, body/face customization and static ABMX
modifiers. Maker exposes separate **Original idle animation** and **Original hair
motion** toggles when their converted data is present. This is the observed hair
component variant, not support for every DynamicBone/FinalIK system in the game.

## Recovered data and source behavior

`Tools/reverse/dynamics_contract.py` reads the selected body and hair bundles,
verifies their transfer hashes, and emits `.local/reverse/rigs/source-dynamics.json`.
The initial reference selection has no active DynamicBone component on its back
hair; its front hair has five components containing twenty real transform
particles. This is selection-specific: the expanded back-0/front-1/2/5 library
below has fifteen components and sixty-two particles in total. The source character
loader replaces their prefab collider slots with the body's twenty-four colliders;
the converter preserves original hierarchy and component order.

Each particle and collider uses an explicit source transform ID in the assembled
avatar. Positions, gravity, force and collider centers cross the native Z-reflection
boundary once. Distribution curves are baked at normalized cumulative rest bone
lengths. The initial selected front-hair curves have zero tangents; the exporter now also
accepts finite nonzero cubic Hermite tangents and clamps endpoint values. Weighted
keys are rejected.
An independent assembly of the actual body/head/hair hierarchy reproduces all
twenty exported length ratios. Recomputing distributions after arbitrary custom
nonuniform scaling is not implemented.

The native `SourceDynamicBone` follows recovered `DynamicBone.cs`,
`DynamicBoneCollider.cs` and the character loader's collider rebinding. Their
hashes and input bundle/rig hashes accompany the converted document. Relevant
source details include:

- Fixed-rate accumulation performs at most three steps, then clears the remainder.
  A zero update rate performs one step even when the supplied delta is zero.
- Forces apply per simulation step, without multiplying by delta time. Rest gravity's
  positive projection is removed before adding external force.
- Owner movement inertia applies on the first simulated step. Skipped frames move
  both current and previous particles with the owner, then enforce constraints.
- Elasticity, stiffness, ordered collider tests, freeze-plane projection and bone
  length constraints retain the source order. World rotations compose local
  quaternions separately from potentially sheared ancestor matrices.
- A parent rotates toward its particle only when its actual transform has at most
  one child. Particle world positions then become local translations.
- Collider radius uses the absolute world Z scale. Capsule endpoints use
  `(height - radius) / 2`. Both inside and outside bounds add particle radius.
  Exact-axis particles retain the source zero-offset behavior; algebraically
  reassociating the capsule calculation introduced a tested numerical error.
- Particle resets retain the accumulated clock. Disabling weight resets initial
  local positions/rotations while retaining scales; re-enabling resets particles.

## Native API

```swift
let document = try SourceDynamicsDocument.load(url: dynamicsURL)
var states = try document.components.map {
    try SourceDynamicBone(rig: rig, pose: upstreamPose, definition: $0)
}
var pose = upstreamPose
for index in states.indices {
    pose = try states[index].step(deltaTime: deltaTime, rig: rig, pose: pose)
}
```

Supply a clean upstream animation/customization pose each frame. Maker does this
and invalidates particle state when relevant customization changes. Simulation
commits only after validating the resulting particles and pose. Missing identities,
invalid parents, duplicate particles, nonfinite configuration, local reflection,
singular scale and local shear on required transforms fail explicitly. A failed frame does not partially
commit simulation state.

The current exporter/runtime supports direct real-transform particle trees with
positive local TRS. Virtual end particles, exclusions, `notRolls`, distance disabling,
signed local scales and the separate `DynamicBone_Ver01`/`Ver02` systems are
unimplemented. Full-body and motion IK are separate from this hair simulation. Actual-player
parameter/curve comparisons now exist, but exact running-Unity particle trajectory
parity and source frame-time parity are not established.

## Verification and reproduction

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/dynamics_contract.py
.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse -p test_dynamics_contract.py
IKKOKU_SOURCE_AVATAR="$PWD/.local/reverse/rigs/source-avatar.json" \
IKKOKU_SOURCE_DYNAMICS="$PWD/.local/reverse/rigs/source-dynamics.json" \
IKKOKU_SOURCE_DYNAMICS_REFERENCE="$PWD/.local/reverse/dynamics/reference.json" \
  swift test --package-path Packages/Engine --filter sourceDynamics
```

Unit checks exercise catch-up/skipped steps, force, gravity, freeze planes, weight
resets, collider branches, invalid input and twenty frames on the actual assembled
avatar. A separate float32 Python oracle covers synthetic motion, all five original
hair chains and 252 collider cases; see [the parity report](dynamics-parity.md).
These compare independent offline/native implementations of recovered source logic.

The arm64 app's headless capture can advance the real Maker path deterministically:

```sh
IKKOKU_SOURCE_PLAYBACK_SECONDS=1 IKKOKU_CAPTURE_PRESET=full \
IKKOKU_AUTOCAPTURE="$PWD/.local/reverse/animation-assets/native-idle-1s.png" \
  .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
```

The retained one-second capture uses the original clothed avatar, original Idle at its
authored state speed, source morphs, separate skin palettes and five hair chains.
All extracted content and capture evidence remain under ignored `.local/`.

## Studio frame execution and selected hair

Studio now consumes converted `DynamicBone` metadata after normal source animation,
Maker shape/ABMX, saved FK activation and the full-body IK solve. The
`SourceStudioDynamics` session runs components in their exported hierarchy/component
order and returns one cached result to render, guide and attachment consumers.
`SourceStudioCharacterPreview.setDynamicsStep(elapsed:deltaTime:)` explicitly marks
a host frame. Sampling an arbitrary animation pose does not advance transient
particles. Live and plug-in clocks provide their actual delta rather than deriving
it from an accumulated binary32 animation time.

Hair FK disables the corresponding components using original FK group index 0;
skirt bindings use group index 6. Re-enabling resets particles to the new upstream
pose. Backwards seeks and edits at a paused frame discard particle history. A
failed component frame commits no component state. Preview checkpoints include
particles, the pending dynamics tick, evaluated pose and animation clock so a
failed plug-in callback can roll back the whole pose consumer state.

Binding uses exact source CAB/path identities; only the assembled hair namespace
may change when empty slots compact the assembly. It never matches a different
asset by bone name or catalog number. Components belonging to other selected hair
assets remain unattached with diagnostics. Signed/matrix-authored transforms in
unrelated accessories are preserved; particle, owner and collider ancestors still
require positive local TRS.

The strict exporter can now enumerate all converted original Maker hair assets:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/dynamics_contract.py \
  --maker-library .local/reverse/maker-library/library.json \
  --output .local/reverse/studio-dynamics/maker-dynamics.json
```

This library contains back hair 0 and front hair 1/2/5: fifteen components,
sixty-two real particles and twenty-four body colliders. Each selected assembly
binds only its own components. Front hair catalog ID 0 is empty; it is never
aliased to the similarly named source bundle. The back-hair radius distribution
has a finite nonzero tangent. The converter evaluates finite cubic Hermite keys
and rejects weighted keys and unsupported topology. Zero-tangent curves retain
the prior float32 operation order. Library file hashes and original bundle hashes
must match before extraction, and generated contracts include per-asset coverage.

A controlled original-hair session test compares 100 frames to the independent
recovered float32 reference, with maximum applied world-position error `2.42e-7`.
An actual clothed head-200/bone-1 fixture feeds normal animation and full-body IK
into five original front-hair chains for twelve frames; explicit sequential
particle execution and Studio execution produce identical matrices, including
checkpoint/replay. The expanded hair cases exercise 8, 7 and 6 active components
for front IDs 1, 2 and 5 respectively with back ID 0, retaining card bytes.
Evidence and authored fixtures are under `.local/reverse/studio-dynamics/`.

The expanded contract is consumed by Studio. Maker currently enables its legacy
hair document only for the unchanged `source-avatar.json` assembly; selecting
geometry through the expanded Maker library can disable that path. The expanded
export is therefore not evidence of Maker dynamics coverage for every hair choice.

The Studio session currently simulates in character space. Movement of the entire
scene object does not yet contribute world-space owner inertia. Transient particle
state is not serialized into original scenes, whose source format has no such
particle snapshot. Other clothing/accessory variants, virtual ends, exclusion and
notRoll topology, dynamic distribution rebaking under arbitrary customization,
and the separate DynamicBone_Ver01/Ver02 systems remain outside this path.

A separate private original-player probe now checks setup directly in Unity
5.6.2f1. It creates fresh clothed back-0/front-2 hair selections, exports numeric
particle parameters and curve samples, and exits without exporting images. All
seven components, thirty-three particles and 165 baked scalar parameters match
the converted contract to `1.21e-7`; 1,235 `AnimationCurve.Evaluate` samples match
to `3.29e-7`. The `1e-6` check accommodates the source probe's decimal float
serialization. This validates parameter setup and interpolation; dynamic
trajectories remain checked against the independent recovered float32 oracle.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_dynamics_probe.py
# After the private player exits:
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_dynamics_probe.py --collect
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_dynamics_probe.py \
  --probe .local/reverse/original-dynamics-probe/dynamics.json \
  --contract .local/reverse/studio-dynamics/maker-dynamics.json \
  --output .local/reverse/studio-dynamics/original-setup-parity.json
```

## Original motion capture

The same private probe gained a motion mode (`--motion`): it uploads a fixed
request (90 frames at the locked 60 Hz step, which the fixture rechecks),
re-enables only the seven hair components and their 24 colliders, and drives a
deterministic scripted root path — `x + 0.34·sin(0.11i)`, `z + 0.55·sin(0.165i)`
and yaw `32·sin(0.14i) + 4·sin(0.43i)` degrees plus a sub-millimetre LCG jitter
— while the original `DynamicBone.LateUpdate` integrates the real particles on
top of it. Every frame after `WaitForEndOfFrame` records `deltaTime` (locked at
0.01666667 s on all 90 frames), the character and avatar world transforms, each
component root and owner world transform, every particle world position and
applied rotation, and every collider world transform. Before the first step it
also records the `OnEnable` reset state: each particle's `m_Position`/
`m_PrevPosition`, the weight, accumulator time, object move and object scale
(0.8683459 on this fixture).

`Tools/reverse/compare_dynamics_motion.py` replays the capture (evidence
`.local/reverse/original-dynamics-probe-stt08a/motion.json`, copy in
`/Users/rumpology/code-repo/ikkoku/.local/stt08a/`) through the float32 oracle
under two models at a 1e-4 m gate.

The **bind-hierarchy diagnostic** rebuilds the rig bind chain under the
recorded avatar world transform, the input model the earlier synthetic
scenarios use. The capture refutes it as a parity model: the predicted
component root deviates from the recorded root by 0.129–0.143 m (worst
0.14307 m, `cf_J_hairF_00` frame 18), the owner by a constant 0.12603 m and
every collider by 0.11468 m; the offset is frame-constant in the character
frame, so the live assembled scene reposes or re-scales bones the rig mirror
does not carry. The diagnostic keeps reporting those deviations per component;
they are model evidence, not parity claims.

The **recorded-input model** is the parity gate: the integrator receives only
recorded transforms — the root's world transform, the owner world position,
each collider's recorded world transform (with the seed `objectScale` as its
lossy scale, because the capture records no per-collider scale — a documented
assumption) — and bind-local translations below the root scaled uniformly by
`objectScale`, mirroring `InitTransforms`. The recorded rest offset of
particle 1 from the root divides by the scaled bind local to
0.9999852–1.0000030, so that uniform scale assumption holds to float32 noise.
Fixed-rate accumulation ran once per frame (step counts all 1) with the seeded
accumulator remainder. The gate **fails**: per-component maxima are 0.12694
(`cf_J_hairBR_00` frame 59 tip), 0.12580 (`cf_J_hairBL_00` frame 82), 0.14199
(`cf_J_hairB_00` frame 22), 0.04993 (`cf_J_hairFR_02_00` frame 58), 0.04017
(`cf_J_hairFL_02_00` frame 80), 0.07107 (`cf_J_hairF_00` frame 13) and 0.05402
(`cf_J_hairFR_00` frame 43) metres. Every component first exceeds the gate on
frame 0 at its second particle (0.00746–0.03089 m), so the divergence begins
in the very first integrated step; per-frame particle sway amplitudes in the
recorded capture are only 1–4 cm, so the residual is a model/input gap in the
first-step integration, not chaotic drift. This is reported, per the capture
protocol, and no Swift solver was changed on its account.

The **one-step model** (`compare_dynamics_motion.py --mode one-step`, capture
evidence `.local/reverse/original-dynamics-probe-stt08b/motion.json`) isolates
that first step: the probe now also records DynamicBone's integrator-internal
state — per-particle `m_Position`/`m_PrevPosition`
(`internalPosition`/`internalPrevPosition`), per-component
`m_ObjectPrevPosition`/`m_Time`/`m_Weight`/`m_ObjectScale` and per-collider
`lossyScale` plus serialized `m_Radius`/`m_Height`/`m_Center`/`m_Direction`/
`m_Bound` — and every frame is predicted from frame k−1's own recorded state
with a freshly seeded solver, so an error cannot be accumulated drift. Frame-0
serialized parameters are validated against the contract before any error is
reported. The gate still fails at frame 0 (per-component one-step maxima
0.12691/0.12579/0.14196/0.04991/0.04014/0.06197/0.03811 m, worst frames
59/82/22/57/80/60/43), but the seed check pins where the divergence is *not*:
`rootPreviousDelta` and `timeDelta` are exactly 0 with step counts 1/1, so the
recorded `OnEnable` seed is the state the original actually integrated from —
hypothesis (a), a wrong seed, is refuted (`childPreviousDelta` 329.01 and
`ownerPrevDelta` 470.02 m reflect the external CharaStudio relocation between
the seed read and frame 0, not integrator history). The stage-by-stage
reconstruction names the first differing term as the `UpdateParticles2`
elasticity restore: at frames 1/2/59 of `cf_J_hairBR_00` the original recorded
`m_Position` of the second particle sits at the oracle-predicted `desired`
position within 1.7e-5–1.2e-4 m, while the oracle — using the serialized
per-particle `m_Elasticity` 0.1735 — leaves it on the stiffness limit sphere
0.016–0.025 m short. Re-running the replay with elasticity forced to 1 drops
the per-particle medians on `cf_J_hairBR_00` from
0.0296/0.0548/0.0799/0.1047 to 6e-5/0.0123/0.0292/0.0479 m and the component
maxima to 0.0167–0.0627 m, and elasticity 1 with stiffness 0 is bit-identical
to elasticity 1, so the original's stiffness phase is inactive on these
particles. The oracle itself reproduces the recorded single-step identities it
can see, so hypothesis (c), an oracle defect, is refuted; what remains is
hypothesis (b) in parameter semantics: the serialized per-particle
`m_Elasticity` is not the effective restore coefficient of the original's
integration (effective ≈ 1.0 at the first child), not a wrong collider scale,
owner-inertia `m_ObjectMove` or accumulator. Remaining chain error after the
fix at particle 1 persists at particles 2–4 (medians 0.012–0.048 m), so their
restore/history chain still differs and is the open part of `ST-T08`. The
frame-0 owner jump itself is unrecoverable from this capture:
`ownerPrevDelta` 470.02 m shows the seed-to-frame-0 owner gap, so `m_ObjectMove`
at frame 0 is not reconstructible and the frame-0 second-particle error is not
fully attributable.

The **manual-step intermediates** (capture evidence
`.local/reverse/original-dynamics-probe-stt08c/motion.json`) settle which stage
the one-step residual belongs to. The fixture gained a manual-step sub-mode for
frames 10/11/12: it rolls the frame back to its frame-start snapshot, re-runs
the private chain by reflection in exactly the source order —
`InitTransforms`, the `UpdateDynamicBones` prologue (recomputing
`m_ObjectScale = |lossyScale.x|` 0.8683459, `m_ObjectMove` and
`m_ObjectPrevPosition`), the same accumulator loop (one step per frame),
`UpdateParticles1` → record every `m_Position` → record each bone's live
`localToWorldMatrix` (whose column 3 `UpdateParticles2` overwrites with the
parent particle's current `m_Position`) plus each child's `localPosition` and
live bone length → `UpdateParticles2` → record every `m_Position` →
`ApplyParticlesToTransforms` — then writes the official frame-end
`m_Position`/`m_PrevPosition` back, so the dry run leaves the integrator state
untouched. The capture also records each particle's RUNTIME
`m_Damping`/`m_Elasticity`/`m_Stiffness`/`m_Inert`/`m_Radius` plus `m_Weight` at
the seed and again at frames 0/1/45, and per manual frame every collider's
world position/rotation/lossyScale plus serialized radius/height/center/
direction/bound.

`Tools/reverse/analysis/dynamics_manual_steps.py` re-predicts
`UpdateParticles2` from exactly those recorded inputs — elasticity pull toward
`desired`, the double-rounded stiffness limit, every collider at particle
radius `m_Radius · m_ObjectScale` through the oracle's `collide()`, and the
final bone-length projection, applying each particle's result as the next
particle's parent position (the chain-wise write-back `UpdateParticles2`
itself performs) — entirely in the capture's own space, no mirroring. Of the
four candidate explanations for the one-step residual: hypothesis 1, runtime
elasticity differing from the Maker contract, is **refuted** — the maximum
relative delta per key against the contract is elasticity 1.60e-06, stiffness
1.50e-06, radius 1.15e-06, damping and inert exactly 0 (the 14 rows over the
1e-6 flag differ only in the fixture's 7-significant-digit serialization, and
the values repeat identically at frames 0/1/45). Hypothesis 2, a runtime
`m_Stiffness` of 1 zeroing the limit radius, is **refuted** — the maximum
runtime stiffness is 0.10000000149. Hypothesis 3, parent rotations differing
from the rest rotations the oracle assumes, is **not a defect**: the
`localToWorldMatrix` 3×3 blocks read inside each frame (26 rows over the 7
components; 33 particle positions are recorded per step) are identical (spread
exactly 0.0) and match the recorded
avatar rotation times `m_ObjectScale` entrywise to at most 2.09e-07 — the live
root basis; `ST-T08D` below showed the replay itself was feeding a different
rotation. Hypothesis 4, collider pushes, is
**confirmed**: with the recorded collider rows the re-prediction matches the
recorded post-`UpdateParticles2` positions to at most 8.56e-04 m — the float32
ulp at these ~500 m capture coordinates is 3.05e-05–1.2e-04 m, so the residual
sits in the round-trip band (all 7 components × 3 frames at a 1e-3 gate) — and
the recorded post-`UpdateParticles2` positions equal the official frame-end
`m_Position` exactly (maxOfficialDelta 0.0 everywhere), proving both that the
dry run was non-destructive and that the intermediate is the real integrator
output. Ablating the collider rows drops the prediction to 2.5e-03…3.49e-02 m
errors — exactly the scale the one-step gate blames on the formula. The pushes
are real and load-bearing: the head collider pushes each back-hair root
particle off its post-`UpdateParticles1` position by ~1.1 cm on all three
frames, and in `cf_J_hairF_00` the push fires on `cf_J_hairF_01` only *after*
the elasticity pull (5.3 mm, invisible to the post-`UpdateParticles1` overlap
diagnostic) where the bone-length projection amplifies it along the chain to
1.2 cm at particle 2 and 3.5 cm at particle 3; the residual at those frames
comes back to 3.8e-05/6.4e-05 m once the recorded collider rows are applied.
At these frames the recorded positions therefore follow from the serialized
runtime elasticity plus the collider interaction with no forcing, so the
previous section's "effective restore coefficient ≈ 1" reading does not
reproduce where intermediates exist, and the python oracle's
`UpdateParticles2` formula is **not** wrong: given its recorded inputs the
oracle reproduces the original's step, so the one-step gate's remaining
0.038–0.142 m failure lives in stages upstream of `UpdateParticles2` (the
`UpdateParticles1` result and the owner-motion/accumulator inputs that produce
it), not in the step's arithmetic. Rerunning `--mode one-step` on the stt08c
capture gives maxima 0.12691113/0.12578946/0.14196220/0.04991316/
0.04014261/0.06196827/0.03810673 m on
`cf_J_hairBR_00/BL_00/B_00/FR_02_00/FL_02_00/F_00/FR_00` (worst `cf_J_hairB_00`
frame 22) — identical to the stt08b numbers, as expected: with maxOfficialDelta
0.0 the fixture edit leaves every recorded trajectory bit-identical. Seven
synthetic `dynamics_manual_steps` tests (oracle-generated intermediates only)
pin the matrix plumbing, the chain-wise write-back (shifting one post-
`UpdateParticles1` root position by 2 cm moves every descendant's prediction
by more than 1 mm) and the collider ablation, and a capture without manual-step
rows is refused.

`ST-T08D` found the differing replay-side input. Diffing the one-step model's
reconstructed `UpdateParticles2` inputs against the recorded manual-step inputs
for frames 10–12 first cleared `UpdateParticles1`: replicating it from the
seeded internal state gives the recorded `afterParticles1` positions within
1.38e-3 m on every component (particle 0 exact; the move the model derives from
the two recorded owner positions differs from the recorded
`UpdateDynamicBones` prologue `m_ObjectMove` by ~1e-4 m in Z, and velocity and
move quantize through float32 at different points than the original's
registers). The named defect was the **root node's live basis rotation** in
`one_step_inputs`: it pinned the recorded end-of-frame `root.rotation`, but
`ApplyParticlesToTransforms` rotates parent transforms in place and never
writes particle 0's own position, so that recording is the *applied* pose —
41–85 degrees away from the live basis — while `UpdateParticles2` reads the
live `localToWorldMatrix`, which is `InitTransforms`' restored bind locals
(ancestor bind local rotations are all identity) under the animated ancestor
chain: the recorded avatar rotation times `m_ObjectScale`, matching the manual
`parentMatrix` rows to 2.09e-07 entrywise. The Python fix feeds the frame's
`avatar` rotation as the root basis (and `compare` now passes the avatar row
into the one-step frames); the recorded root *position* pin stays, it is the
live origin. After the fix the `--mode one-step --tolerance 1e-5` gate on both
the stt08b and stt08c captures (bit-identical trajectories) drops per component
from 0.12691/0.12579/0.14196/0.04991/0.04014/0.06197/0.03811 m to
0.014026/0.014058/0.009238/0.006891/0.004669/0.030650/0.031381 m on
`cf_J_hairBR_00/BL_00/B_00/FR_02_00/FL_02_00/F_00/FR_00` (worst overall
0.141962 → 0.031381 m, `cf_J_hairFR_00` frame 89). The gate still fails at
1e-5, and no wrong input is known to remain: re-running the full
`UpdateParticles2` chain on replay-reconstructed inputs (bind locals, rest
lengths, radii, stiffness/elasticity, collider world matrices with the
`[lx, ly, -lz]` lossy-scale mirror) against the *recorded* post-`UpdateParticles1`
positions reproduces the recorded post-`UpdateParticles2` positions to ≤8.6e-4 m
on all seven components × frames 10–12. The remaining residual is consistent
with the replay's ≤1.38e-3 m `UpdateParticles1` difference being amplified along
the chain (on `cf_J_hairF_00` frame 10, 3.7e-4 m at particle 1 becomes 2.9e-2 m
at particle 3 through the elasticity pull, bone projection and collider pushes,
which switch on and off at contact). That attribution is an inference, not a
per-frame measurement: neither float32 operation order nor near-threshold
collider contacts are individually ruled in or out. Two synthetic regression tests pin the input:
overwriting every recorded root rotation with an unrelated 60-degree roll
leaves the one-step frame errors bit-identical, while a 45-degree yaw of one
frame's avatar rotation moves that frame's children past the gate.

Caveats and non-coverage: an external CharaStudio scene script relocates the
character root every frame (the recorded root path follows the scripted
sinusoid in x to the jitter but not in y/z), so the comparison is valid only
through the recorded transforms, and the recorded owner positions — not the
script — feed the oracle's owner-inertia channel; the seeded `objectMove` was
zero at reset. Whether any collider was actually contacted is unrecorded (the
oracle models the collision branches but the capture writes no contact
events; the stt08c manual frames 10–12 show from the residuals that pushes did
fire on the recorded particles, but only for those frames), applied particle
rotations are context only
(`ApplyParticlesToTransforms` is not ported), and in the stt08a full-model runs
per-collider lossy scales are assumed equal to `objectScale` (the stt08b
capture records them per collider).

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_dynamics_probe.py --motion
# After the private player exits:
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_dynamics_probe.py --collect
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_dynamics_motion.py \
  --capture .local/reverse/original-dynamics-probe-stt08a/motion.json \
  --contract .local/reverse/studio-dynamics/maker-dynamics.json \
  --maker-library .local/reverse/maker-library \
  --output .local/reverse/dynamics-motion/stt08a-compare.json
# Isolation model, needs the stt08b capture with the internal integrator state:
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_dynamics_motion.py \
  --capture .local/reverse/original-dynamics-probe-stt08b/motion.json \
  --contract .local/reverse/studio-dynamics/maker-dynamics.json \
  --maker-library .local/reverse/maker-library \
  --output .local/stt08b/one-step-report.json --mode one-step --tolerance 1e-5
# Manual-step intermediates, stt08c capture: rerun the one-step gate, then
# re-predict UpdateParticles2 from the recorded intermediates:
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_dynamics_motion.py \
  --capture .local/reverse/original-dynamics-probe-stt08c/motion.json \
  --contract .local/reverse/studio-dynamics/maker-dynamics.json \
  --maker-library .local/reverse/maker-library \
  --output .local/stt08c/one-step-report.json --mode one-step --tolerance 1e-5
.local/reverse/unitypy-venv/bin/python -c 'import json,sys; \
  sys.path[:0]=["Tools/reverse/analysis","Tools/reverse"]; \
  from dynamics_manual_steps import manual_step_report; \
  json.dump(manual_step_report(json.load(open(".local/reverse/original-dynamics-probe-stt08c/motion.json")), \
  json.load(open(".local/reverse/studio-dynamics/maker-dynamics.json")),1e-3), \
  open(".local/stt08c/manual-step-report.json","w"),indent=1)'
```

Next tasks (`ST-T08`) are to capture actual-player particle trajectories and
rendered/bone results for the same controlled tick history, then add world-object
motion inertia and additional topologies/variants. Extend Maker rebinding to
selected converted hair without changing card identities. Preserve exact source
component/collider order and test rollback, seek and FK-disable behavior for every
new binding; a parameter match alone cannot validate a simulated trajectory.
