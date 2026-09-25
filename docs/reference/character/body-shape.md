# Body shape destinations

Reviewed 2026-09-25. The bounded local-transform controller is fully ported;
assembly, physics and UI limits remain separate in the
[component audit](../../component-audit/character-and-mods.md) (CM-11, CM-13,
CMT-01 and CMT-08). Commands run from the repository root. Recorded fixture
results below describe the saved evidence, not a new test run.

`SourceBodyShapePose` implements the complete recovered body controller's local-transform writes in Swift: 85 `ShapeBodyInfoFemale.Update` destinations and the three `UpdateAlways` setters. The controller is shared by the normal male and female skeletons. All 44 body shape slots feed their original 111 intermediate channels, using the recovered slot order and enabled component masks.

The static pass preserves source ordering: mask 4 writes 57 general body, limb, collision and clothing destinations, mask 1 writes 14 left-side destinations, and mask 2 writes 14 right-side destinations. `UpdateAlways` then writes `cf_d_kokan` Z and the two `cf_d_shoulder_L/R` X components. These are local-position setters, not a physics simulation. They overwrite those components each time this pass follows animation. The other animated components remain intact.

The source formulas include height-aid multiplication, independent left/right offsets, the 0.91 male head/neck factor, additive bone-type corrections, reciprocal scales, source-specific cross-axis factors, and the skirt inputs' signed-angle conversion before angle addition. These operations use the masked intermediate controller state; disabled source axes retain their initial zero position/rotation or unit scale. Source Z and rotations are reflected exactly once at the Unity-to-native boundary. Unity Euler rotations use Z, X, then Y composition.

## API and coverage

```swift
let options = SourceBodyShapePose.Options(
    sex: .female, boneType: .standard, updateMask: 7, applyAlways: true)
let coverage = try SourceBodyShapePose.coverage(rig: rig, domain: body, options: options)
let pose = try SourceBodyShapePose.make(
    rig: rig, domain: body, values: rates, options: options, basePose: animatedPose)
```

`make` also accepts intermediate `state: [String: SourceShapeTransform]`. The default update mask is 7. A caller can execute only the always pass with `updateMask: 0, applyAlways: true`, or disable it explicitly. Call the body pass after Animator sampling and before later ABMX/dynamics adjustments; face customization remains a separate pass.

The source skips absent destination transforms. The native implementation follows that behavior and rejects ambiguous duplicate names. `coverage` exposes bound and missing destinations plus each slot's affected destinations. `boundSlots` means at least one affected destination exists; `completeSlots` means all affected destinations exist. A five-node height/head/neck rig has four bound slots but only slots 1–3 are complete because height aid also drives absent limb, torso and collider transforms. The assembled original female rig binds all 88 setters and all 44 slots completely. A binding report measures transform support, not whether every transform influences a visible selected mesh.

`Options.boneType` is `.standard` or `.corrected(table)`, corresponding to zero and nonzero source `typeBone`. `SourceBodyShapeCorrectionTable.decode` reads the original 1,156-byte `shapecorrect.bytes`: an Int32 count of 32, followed by 32 records of nine Float32 values (position XYZ, rotation XYZ degrees, scale XYZ). Corrections remain additive; only the axes used by each source setter are consumed. The table decoder rejects wrong counts, truncation, trailing bytes and nonfinite values.

Incoming local TRS components not written by a destination remain unchanged. An omitted `basePose` uses authored rest components. Reapplying an unchanged shape does not compound scales. Incoming matrix decomposition supports finite positive orthogonal local TRS; local reflection, shear, perspective and singular scale are rejected. Matrix-only authored destinations are rejected. Unbound source channels need not be supplied to the state overload. Bound channel values and output matrices must be finite, including reciprocal-scale divisions. Options reject mask bits outside 0–7. Domain-based entry points validate the entire recovered name, slot and component-mask schema.

## Independent verification

`Tools/reverse/analysis/body_shape_contract.py` selects the main Mono assembly from the recovery index, verifies its SHA-256, and compiles verbatim recovered `AnimationKeyInfo.GetInfo`, `ShapeInfoBase.ChangeValue`, `ShapeBodyInfoFemale.Update` and `UpdateAlways` under .NET. Its explicit Transform shim uses System.Numerics Hamilton quaternion products for Unity Euler order. This proof is independent of the Swift formulas and does not execute Unity or establish rendered parity.

The recorded fixture has 844 cases and 88 destination records per case: **74,272 independently computed transform matrices**, checked against Swift with a maximum allowed component difference of 0.000004. Cases include each of the 44 slots at four endpoint/interior rates, randomized combinations, both sex factors, the original standard/corrected modes, all eight update masks with always enabled/disabled, and independent intermediate states plus synthetic correction tables to exercise axes that are zero in the original default data. The original rig's authored transforms supply untouched components.

Focused Swift tests cover baseline preservation, absolute reapplication, independent masks, always-pass constants, skirt angle wrapping, failed reciprocal scales, omitted destinations, duplicate names, invalid matrices, correction decoding and complete/reduced coverage. A source-fixture test also changes every body slot on the assembled avatar, checks a bound transform changes, validates world transforms, and checks finite skinned bounds at all-zero, midpoint and all-one values. It does not render unclothed geometry.

Run the proof from the repository root:

```sh
python3 Tools/reverse/analysis/body_shape_contract.py \
  --output .local/reverse/body-completion/reference
IKKOKU_BODY_SHAPE_REFERENCE="$PWD/.local/reverse/body-completion/reference/reference.json" \
IKKOKU_SHAPE_CONTRACT="$PWD/.local/reverse/rigs/character-shape-contract.json" \
IKKOKU_SOURCE_AVATAR="$PWD/.local/reverse/rigs/source-avatar.json" \
  swift test --package-path Packages/Engine --filter sourceBody
```

The generator also accepts `--rig` and `--contract` to verify another original skeleton/default-card combination. Generated C#, original data, numeric results and SHA-256 provenance remain inside ignored `.local/`.

## Boundary

Destination coverage is complete for the recovered controller's `Update` and `UpdateAlways` methods. These functions do not implement caller-side low-detail rate remapping, downstream body dynamics, clothing physics, or arbitrary modded destination schemas. Maker separately enforces the original normal-male height value of 0.6 and selects sex, bone type and correction table explicitly. Other controller types and modified source code require their own recovered contract. No visual similarity or complete physics compatibility is inferred from numeric local-transform parity.
