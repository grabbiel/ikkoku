# Original Animator assets and generic clip playback

The native engine can now sample selected original idle, walking and running
clips from the installed game's action controller. It preserves their serialized
transform bindings and evaluates constant, dense and streamed scalar curves.
The first fully bound path is the original female **Idle** state on the assembled,
clothed female avatar. This is a bounded Animator implementation, not complete
Unity Mecanim compatibility.

## Recovered installation evidence

The explicitly fetched bundle is `abdata/action/animator/00.unity3d`, 43,995,719
bytes, SHA-256 `6be3503f0fc25535ed5c40cb77dd107f8f8263f03514ee325dc3d5221a4e5c3e`.
Its verified local copy and provenance are under
`.local/reverse/animation-assets/source/`. It contains 374 clips, two controller
graphs and 37 override controllers. The converter reads only explicitly requested
states and their referenced clips; it does not execute bundle behaviours.

Recovered managed `ActionGame.Chara.Player.LoadAnimator` selects the bundle's
`player` controller. `NPC.LoadAnimator` uses the personality table's motion bundle
and asset. The `base` controller supplies the female state graph inspected here.
These call sites are in the complete managed recovery. `ActionGame.Chara.Base`
has a clean whole-type override recorded in that recovery's manifest; the primary
failed C# file must not be treated as authoritative.

The selected base-layer graph has these motions:

| State / motion | Original clip | Duration | Transform bindings | Scalar curves | Unbound paths |
| --- | --- | ---: | ---: | ---: | ---: |
| Idle | `f_stand_00_00` | 4.7333336 s | 581 | 1,936 | 0 |
| Locomotion, Speed=0 | `f_aruki_00_00_01` | 2.0666668 s | 702 | 2,340 | 12 |
| Locomotion, Speed=1 | `f_hasiru_00_00_01` | 0.73333335 s | 702 | 2,340 | 12 |

Idle uses state speed approximately 0.7 multiplied by `MotionSpeed`, whose default
is 1. Locomotion's flat one-dimensional blend tree uses the `Speed` parameter at
thresholds 0 and 1. These selected states have no outgoing state transitions.
The full controller has other states, layers, masks and AnyState behavior which
the native projection deliberately does not execute.

## Clip conversion and bindings

`Tools/reverse/animation_assets.py` emits schema version 1, converter 1.0.0:

- `animation.json`: native clip curves, explicit target identities, selected
  state/motion data, parameter defaults and limitations.
- `controller-source.json` and `clip-*-source.json`: preserved serialized evidence
  under ignored `.local`, including controller fields outside the native subset.
- `sample-reference.json`: independently evaluated scalar values at six times
  per clip for comparison with Swift.

The source stores these clips in `m_MuscleClip`, but that container name does not
make them Humanoid muscle animations. Every selected binding is a generic
Transform (`typeID=4`), with attributes 1/2/3 representing local position,
quaternion and scale. The converter rejects Humanoid/other component attributes,
object-reference curves, clip events, legacy/compressed rotation representations,
mirroring and loop-pose correction instead of approximating them.

Bindings retain their original 32-bit path hash and scalar-curve offset. CRC32 of
the exact root-relative hierarchy resolves them against the chosen skeleton;
the original Avatar's 579 path entries independently matched the same CRC32
calculation. Resolved targets carry explicit stable IDs such as
`body-master/<original source ID>`. Native playback uses these IDs and verifies
the target label; it never guesses from a leaf name shared by multiple nodes.

All 196 Idle paths resolve. Walking and running each contain twelve additional
paths absent from this selected skeleton. Their tracks are constant auxiliary
TRS data; all time-varying channels resolve. Their hashes and original curve data
remain in the document. Strict playback rejects these clips unless the caller
explicitly enables partial playback, which skips only the reported unbound tracks.
This is a visible compatibility limitation, not proof that those transforms are
unnecessary in every original character hierarchy.

Source coordinate data remains left-handed/Y-up until application. Local positions
and quaternions cross the existing `UnityCoordinates` Z-reflection boundary once;
scale does not change basis. Quaternion components are sampled and normalized
before constructing local matrices. The rig's existing inverse bind matrices and
skin-palette order remain authoritative.

## Native API and supported behavior

`Packages/Engine/Sources/Character/SourceAnimation.swift` provides:

```swift
let library = try SourceAnimationLibrary.load(url: animationURL)
let clip = try library.clip(id: clipID)
let scalarValues = try clip.sample(time: seconds, looping: true)
let pose = try library.applying(
    clipID: clipID, time: seconds, looping: true,
    to: rig, baseline: rig.restPose, allowingUnbound: false
)
let motions = try library.motions(stateID: stateID, floatParameters: ["Speed": 0.25])
let speed = try library.stateSpeed(stateID: stateID)
```

Sampling uses seconds within the original clip interval. Nonlooping sampling
clamps to the endpoints; an exact loop boundary wraps to the first sample.
Streamed curves preserve their cubic coefficient polynomials. Initial negative
time and final infinity sentinels are consumed only as framing. Dense values are
linearly interpolated at the serialized sample rate and constants remain exact.
This representation was cross-checked against the primary implementations in
[AssetStudio's AnimationClip reader](https://github.com/Perfare/AssetStudio/blob/master/AssetStudio/Classes/AnimationClip.cs)
and [its animation converter](https://github.com/Perfare/AssetStudio/blob/master/AssetStudioUtility/ModelConverter.cs).

The state projection returns motion weights for a flat 1D tree and the authored
speed multiplier. It does not yet compose two different clips into a blended pose,
infer their synchronized time, perform transitions, dispatch events, execute
behaviours, extract/apply root motion or evaluate additional layers. Selecting and
sampling a walking clip is therefore distinct from running the original entire
locomotion controller. Single-clip Idle has a direct source-backed time path.

Maker now uses that Idle path when the adjacent converted animation library is
available. Its monotonic frame delta advances the clip at the recovered state
speed (approximately 0.7), followed by source customization, static ABMX and the
[recovered hair dynamics](reverse-dynamics.md). Pausing/resuming does not accumulate
a large catch-up delta. Separate motion toggles expose availability. The headless
`IKKOKU_SOURCE_PLAYBACK_SECONDS` option advances this same path in 1/60-second steps;
the original clothed avatar was captured after one second of playback.

Animation applies before character shape customization, source bone modifiers,
Studio posing and dynamics. Applying from a clean baseline each frame prevents
accumulation. Unanimated components retain the baseline. Rotation/scale updates
require a positive orthogonal TRS baseline; reflected, singular or sheared baselines
fail explicitly because their component decomposition is ambiguous.

`IkkokuInspect/SourceAnimationReport.swift` exposes metadata and optional rig-sample
reports for the command-line frontend. The report includes changed node count,
skin count, evaluated bounds, sampled scalar values and partial-playback status.

## Verification and reproduction

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/animation_assets.py \
  --bundle .local/reverse/animation-assets/source/abdata/action/animator/00.unity3d \
  --rig .local/reverse/rigs/body-skeleton.json \
  --state Idle --state Locomotion \
  --output .local/reverse/animation-assets/female-base

.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse -p test_animation_assets.py

IKKOKU_ANIMATION_LIBRARY="$PWD/.local/reverse/animation-assets/female-base/animation.json" \
IKKOKU_ANIMATION_REFERENCE="$PWD/.local/reverse/animation-assets/female-base/sample-reference.json" \
IKKOKU_SOURCE_AVATAR="$PWD/.local/reverse/rigs/source-avatar.json" \
  swift test --package-path Packages/Engine --filter sourceAnimation
```

The six initial Swift tests cover sampling, exact binding, coordinate conversion,
loop boundaries, explicit unbound-track handling, state parameter projection and
malformed documents. Nine Python tests cover streamed framing, scalar sampling,
hierarchy identity, unsupported channels/events, clip dimensions and controller
projection failure cases. Eighteen original clip/time combinations compare 39,696
scalar results against the independent Python sampler, then evaluate original
avatar poses and skin palettes. Numeric tolerance is 2e-5 absolute/relative;
these comparisons validate the two native/offline implementations, not bit-for-bit
agreement with a running Unity player.

Remaining work includes complete pose blending, controller transitions and
interruptions, override-controller application, masks and additive layers,
root-motion/navigation coupling, humanoid retargeting, events/behaviours and broader
clip coverage. Blink timing is separately documented in `reverse-animation-playback.md`.
