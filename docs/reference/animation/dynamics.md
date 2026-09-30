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

Caveats and non-coverage: an external CharaStudio scene script relocates the
character root every frame (the recorded root path follows the scripted
sinusoid in x to the jitter but not in y/z), so the comparison is valid only
through the recorded transforms, and the recorded owner positions — not the
script — feed the oracle's owner-inertia channel; the seeded `objectMove` was
zero at reset. Whether any collider was actually contacted is unrecorded (the
oracle models the collision branches but the capture writes no contact
events), applied particle rotations are context only
(`ApplyParticlesToTransforms` is not ported), and per-collider lossy scales
are assumed equal to `objectScale`.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_dynamics_probe.py --motion
# After the private player exits:
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_dynamics_probe.py --collect
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_dynamics_motion.py \
  --capture .local/reverse/original-dynamics-probe-stt08a/motion.json \
  --contract .local/reverse/studio-dynamics/maker-dynamics.json \
  --maker-library .local/reverse/maker-library \
  --output .local/reverse/dynamics-motion/stt08a-compare.json
```

Next tasks (`ST-T08`) are to capture actual-player particle trajectories and
rendered/bone results for the same controlled tick history, then add world-object
motion inertia and additional topologies/variants. Extend Maker rebinding to
selected converted hair without changing card identities. Preserve exact source
component/collider order and test rollback, seek and FK-disable behavior for every
new binding; a parameter match alone cannot validate a simulated trajectory.
