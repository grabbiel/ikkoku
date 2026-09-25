# Independent DynamicBone verification

Reviewed 2026-09-25 against the working tree. See the [Character audit](../../component-audit/character-and-mods.md) for Maker integration and the [Studio audit](../../component-audit/studio.md) for animation consumers and pending tasks. Evidence counts below describe retained focused runs, not a fresh full-suite result.

The native solver is checked against a separate NumPy float32 implementation of
the recovered `DynamicBone.UpdateDynamicBones`, `UpdateParticles1`,
`UpdateParticles2`, `SkipUpdateParticles`, and `DynamicBoneCollider` methods.
The oracle does not import the native solver or the prefab converter and never
executes the Windows DLL. Original assembly, bundle, hierarchy, and configuration
hashes remain in the local reference artifact and are checked by the original
data test before comparison, so a stale reference fails explicitly.

`Tools/reverse/analysis/dynamics_reference.py` generates the numerical reference.
The checked-in `Tools/reverse/fixtures/dynamics-reference.json` contains synthetic
data only: five four-particle branched chains over 20 frames each, plus 252
sphere/capsule queries. Scenarios cover moving owners, inertia, zero/one/two/three
steps, catch-up truncation, zero update rate, changing nonzero weight, rotated
gravity, nonuniform scale, two freeze axes, and ordered collisions. Collider
queries cover all three axes, both bounds, endpoints/interiors, radius addition,
Z scale, and near-axis inputs.

The optional original-data reference independently attaches the source body,
head, and two hair hierarchies using recovered assembly rules. It applies the
head mesh prefab's matching local transforms to the head skeleton and attaches
hair beneath `cf_J_FaceUp_ty`. It then evaluates all five selected source hair
components, comprising 20 particles and the same 24 ordered body colliders,
over 20 moving-owner frames each. No native hierarchy snapshot constructs this
reference. The source particle length ratios after attachment match the
converter's exported ratios exactly for this selection.

`SourceDynamicBoneParityTests.swift` compares positions, previous positions,
clock remainder, step count, and applied native world positions with the oracle.
It also checks the static collider queries and a dedicated exact-axis
regression. The tests use component tolerances of `1e-5` for synthetic particles,
`4e-5` for the original assembled hierarchy, and vector distance `2e-6` for
collisions. Float math order and native quaternion/matrix construction prevent
a claim of bitwise Unity runtime parity.

The retained focused run passed all three Swift tests: maximum synthetic particle-state
error `3.58e-7`, applied world-position error `4.77e-7`, and collider distance
error `1.36e-6`. All original particle positions and previous positions matched
the float32 reference exactly in these 100 frames; original applied world
positions differed by at most `2.38e-7`. These are measurements of the selected
inputs, not a general bitwise-parity guarantee. Eight Python tests additionally
check reference invariants and require the checked-in fixture to match its
generator.

## Reproduce

```sh
.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse/analysis -p test_dynamics_reference.py -v

.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/dynamics_reference.py \
  --output Tools/reverse/fixtures/dynamics-reference.json

.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/dynamics_reference.py \
  --original-rigs .local/reverse/rigs \
  --output .local/reverse/dynamics/reference.json

IKKOKU_SOURCE_DYNAMICS_REFERENCE="$PWD/.local/reverse/dynamics/reference.json" \
  swift test --package-path Packages/Engine \
  --scratch-path .local/build/animation-tests --filter 'sourceDynamics.*(Oracle|CapsuleAxis)'
```

The original reference requires the existing local source avatar and
`source-dynamics.json`. Without its environment variable, the optional original
test returns without loading proprietary files. The synthetic tests always run. A green run without the local environment
variable does not establish original-data comparison coverage.

## Arithmetic regression found by the audit

Replacing the source capsule interior calculation with a generic closest-point
projection changes behavior at zero radial distance. With identity transform,
center `(0, 0.1, 0)`, radius `0.35`, height `1.6`, and Y direction, a particle at
the center has exactly zero radial offset in the source subtraction order. It
must remain still. Reconstructing a closest point first introduces a float32
epsilon; normalizing that epsilon moves the particle by the full radius to
approximately `(0, -0.25, 0)`. The dedicated regression preserves the source's
endpoint/interior branches and `position += radialOffset * factor` order.

Rotated points exactly on an axis are also sensitive to quaternion/matrix
rounding before collision detection. The broad fixture uses nearby off-axis
positions; the separate identity-matrix regression isolates collider arithmetic
without depending on Unity's unavailable native Transform implementation.

## Limits

This verifies the selected real-node, positive local TRS solver. It does not
establish parity for virtual end particles, exclusions, notRoll topology,
distance disabling, signed scale, other DynamicBone versions, collider paths
not selected by the current exporter, or Unity's native `FromToRotation`
implementation. The output checks world positions; they do not independently
compare applied quaternion components or skinned hair vertices. Each original
component is evaluated independently against the animated baseline; the
existing integration tests additionally run all five components in sequence.

Later [Studio dynamics integration](dynamics.md#studio-frame-execution-and-selected-hair)
adds selected front/back assets, animation/FK/IK ordering and checkpoint/replay.
A distinct actual Unity 5.6.2f1 probe validates seven components/33 particles/165
parameters and 1,235 curve samples; it does not capture particle trajectories.
Keep that setup evidence separate from this independent motion oracle. Pending
`ST-T08` work is a matched original-player motion trace, broader topology/variant
support and world-object inertia integration, with maximum errors and supported
asset identities reported for each case.
