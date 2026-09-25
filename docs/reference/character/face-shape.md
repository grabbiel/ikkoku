# Source face shape destinations

Reviewed 2026-09-25. The 59 recovered setters are shared by the supported normal
male/female assemblies with head IDs 0, 200 and 201. The numerical evidence below
was recorded for head 00; it is not a fresh run or proof of every assembly.
See the [component audit](../../component-audit/character-and-mods.md)
(CM-12, CM-17 and CMT-08). Commands run from the repository root.

`SourceFaceShapePose` implements the 59 destination operations in the installed
game's `ShapeHeadInfoFemale` updater, which the normal male assembly also uses.
It consumes the raw Unity channel state from `SourceShapeDomain`, which samples
the 52 face sliders from the selected head's curve contract. The head-00
investigation added destination mapping for the 48 operations that
the initial generic direct-target contract deliberately marked unported. That
generic contract remains conservative; the dedicated face implementation owns
the complete mapping.

## Evidence and boundary

The recovered inputs remain in ignored `.local/reverse/`:

| Input | Evidence |
| --- | --- |
| Koikatu managed assembly | SHA-256 `0038281caf8df48a7903c55dc389642eeeb3f2a9114bd9d68ac11c8ac0396bc5` |
| `Character/Koikatu/ShapeHeadInfoFemale.cs` | SHA-256 `118ba16917f3e70a56037322c5f65b6c4fab4683ac050fc0d9df94bbb42f98d5`; all 59 destination blocks inspected |
| `Character/Koikatu/TransformRotationEx.cs` | Additional bounded ILSpy recovery from the same assembly confirms full local rotation setters assign `Quaternion.Euler` |
| Managed recovery `IllusionUtility.SetUtility/TransformPositionEx.cs` | Partial local position setters read the transform's current untouched axes |
| `Character/Koikatu/ChaControl.cs` | `UpdateShapeFace` supplies the body-derived correction and performs the optional mouth-mask overrides before the updater |
| `rigs/head-rig.json` | Actual head-00 hierarchy and each renderer's original ordered joints/inverse binds |
| `rigs/character-shape-contract.json` | Original head-00 samples, slider masks, and Maker defaults |

The native implementation is a declarative table of component operations plus
one parent-scale calculation. It does not execute recovered C# or ship original
assets. The source state remains in Unity coordinates; destination positions
reflect Z once, and absolute Euler rotations use Unity's Z-X-Y order before basis
conversion. Left and right channels are independent. No mirror formula is added.

Position setters replace only the requested local axes. Whole rotation and scale
setters replace all axes, including explicit zeros and ones. Each evaluation
starts from the incoming `basePose`, or authored local TRS when it is omitted.
Untouched axes, rotations, and scales retain their incoming values, including
upstream clip animation. Assigned channels use absolute values, so repeated
application does not accumulate slider changes. For example, the nose-tip
operation changes Z while preserving incoming X/Y, rotation, and scale;
FaceBase changes scale while preserving incoming translation and rotation.
Other nodes also retain `basePose`, so animated body/neck ancestors feed the
head correction. The preview composes clip animation, body and face shape, bone
modifiers, Studio pose overrides, and dynamics in that order; expression weights
are applied separately to the resulting skinned geometry.

The face-base scale uses the current parent's world scale: with parent scale
`(sx, sy, sz)`, channel X scale `x`, and correction `c`, its local scale is
`(sy*c/sx + (x-1), sy*c/sy, sy*c/sz)`. The correction is 1 for bone type 0.
For nonzero bone type, the caller must supply the original body-derived value
`1 / (1 + bodyCorrection[2].scale.y)`; it is not inferred from head geometry.

## API and verification

```swift
let pose = try SourceFaceShapePose.make(
    rig: source.rig,
    domain: faceDomain,
    values: values,       // nil uses recovered Maker defaults
    basePose: bodyPose,   // optional; includes upstream animation
    boneType: 0,
    headCorrection: 1
)
let evaluation = try source.rig.evaluate(pose)
```

The original focused tests cover rest axes, explicit unit axes, distinct left/right
channels, absolute rotations, body-parent correction, preservation of incoming
unassigned channels, repeatability, invalid inputs, and an optional local
fixture. Run the actual fixture with:

```sh
IKKOKU_HEAD_RIG="$PWD/.local/reverse/rigs/head-rig.json" \
IKKOKU_SHAPE_CONTRACT="$PWD/.local/reverse/rigs/character-shape-contract.json" \
swift test --package-path Packages/Engine --filter sourceFace
```

The local fixture test evaluates every slider at 0, 0.5, and 1, as well as the
original defaults, against all original head skin palettes. It checks structural
and finite-pose validity. This test alone does not establish numerical parity
with Unity; independent source-space comparison is a separate verification.

## Deliberate limits

- The updater supports the registered normal male/female heads 0, 200 and 201
  through their separate curve contracts. It does not select or load a head;
  `SourceMakerLibrary` and the assembly manifests own that step. Special
  `exType` assemblies and resolver-backed mod heads remain unsupported.
- Expression blend shapes, blink playback, materials and clip sampling have
  separate implementations. Source gaze, mouth-width integration and complete
  expression/voice coupling remain pending; they are not face-shape setters.
- All 59 destination names must resolve uniquely. Missing or duplicate nodes
  fail instead of silently omitting a slider effect.
- Destination nodes require authored TRS, and incoming target matrices require
  finite positive orthogonal local TRS. Reflected, singular, or sheared
  composed parent scales also fail because Unity's signed/sheared `lossyScale`
  behavior has not been independently verified. The recovered standalone
  head-00 hierarchy has positive local scales.
- Nonpositive resulting face scales and nonfinite input values fail explicitly.
- The caller owns optional mouth-shape masking, body correction inputs, and head
  collision-volume scaling from `ChaControl.UpdateShapeFace`. Those surrounding
  behaviors are not part of this stage.
- Original inverse binds are preserved, including nonidentity rest palettes on
  accessory face meshes. This implementation does not replace them with a new
  bind pose or claim full game visual parity.
