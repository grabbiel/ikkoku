# Original hair dynamics

The selected original female avatar now runs the recovered `DynamicBone` update
in Swift after its original Idle clip, body/face customization and static ABMX
modifiers. Maker exposes separate **Original idle animation** and **Original hair
motion** toggles when their converted data is present. This is the observed hair
component variant, not support for every DynamicBone/FinalIK system in the game.

## Recovered data and source behavior

`Tools/reverse/dynamics_contract.py` reads the selected body and hair bundles,
verifies their transfer hashes, and emits `.local/reverse/rigs/source-dynamics.json`.
The selected back hair has no active DynamicBone component. The front hair has
five components containing twenty real transform particles. The source character
loader replaces their prefab collider slots with the body's twenty-four colliders;
the converter preserves original hierarchy and component order.

Each particle and collider uses an explicit source transform ID in the assembled
avatar. Positions, gravity, force and collider centers cross the native Z-reflection
boundary once. Distribution curves are baked at normalized cumulative rest bone
lengths. The observed nonconstant curves have zero tangents, so the exporter uses
float32 Hermite interpolation and endpoint clamps. Nonzero tangents are rejected.
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
singular scale and local shear fail explicitly. A failed frame does not partially
commit simulation state.

The current exporter/runtime supports direct real-transform particle trees with
positive local TRS. Virtual end particles, exclusions, `notRolls`, distance disabling,
signed local scales and the separate `DynamicBone_Ver01`/`Ver02` systems are
unimplemented. Full-body and motion IK are separate from this hair simulation.
No claim of source frame-time or exact running-Unity parity is made.

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
hair chains and 252 collider cases; see [the parity report](reverse-dynamics-parity.md).
These compare independent offline/native implementations of recovered source logic.

The arm64 app's headless capture can advance the real Maker path deterministically:

```sh
IKKOKU_SOURCE_PLAYBACK_SECONDS=1 IKKOKU_CAPTURE_PRESET=full \
IKKOKU_AUTOCAPTURE="$PWD/.local/reverse/animation-assets/native-idle-1s.png" \
  .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
```

The one-second capture uses the original clothed avatar, original Idle at its
authored state speed, source morphs, separate skin palettes and five hair chains.
All extracted content and capture evidence remain under ignored `.local/`.
