# Source head expression contract

`Tools/reverse/analysis/expression_contract.py` recovers the installed head-00's
eyebrow, eye, and mouth blend-shape mappings. The output is a data contract for
native expression evaluation, plus an independent NumPy float32 reference. It
does not recover animation clips, voice analysis, gaze tracking, or special
expression textures.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/expression_contract.py
```

The helper requires UnityPy, NumPy, and msgpack. It reads the existing local
source bundle and narrowly decompiled controllers. It writes:

- `.local/reverse/rigs/source-expression-contract.json`
- `.local/reverse/rigs/source-expression-expected-weights.json`

The original tables, channel names, prefab data, and decompiled source remain
under ignored `.local/`. The helper rejects output locations outside that tree.

## Evidence and scope

The source is `abdata/chara/bo_head_00.unity3d`, SHA-256
`e6ded0a39b1ca521648597d31d9f868fe354963279a8ccf4140212598289cf7e`.
The `FaceBlendShape` component has path ID `6276390747262352963` in serialized
file `CAB-b45f3dc6094104fda1eb384293a73f74`. The helper rejects an unreviewed
head bundle hash.

The behavior comes from the local `Koikatu_Data/Managed/Assembly-CSharp.dll`,
SHA-256 `0038281caf8df48a7903c55dc389642eeeb3f2a9114bd9d68ac11c8ac0396bc5`.
The focused source files and their hashes are in
`.local/reverse/decompiled/Expressions/manifest.json`: `FaceBlendShape`,
`FBSBase`, `FBSTargetInfo`, `FBSCtrlEyebrow`, `FBSCtrlEyes`, `FBSCtrlMouth`,
`FBSBlinkControl`, the two `FBSAssist.TimeProgressCtrl` classes, `MathfEx`, and
`ChaFileStatus`. Existing local `ChaControl` and `ChaReference` recover the
character-level defaults, catalog mapping, and indirect mouth-width target.
Their hashes are included in the contract.

There are 15 controller-to-renderer assignments across 13 unique meshes and
484 close/open pattern pairs. Every channel on these meshes has one frame with
source frame weight 100. All pattern sets are retained, although the selected
presets use ordinary neutral, blink, and smile expressions.

| Controller | Pattern count | Targets |
| --- | ---: | --- |
| Eyebrow | 17 | Eyebrow mesh |
| Eyes | 28 | Face, nose line, two eye surfaces, upper/lower eyeline, three tear meshes |
| Mouth | 43 | Face, nose line, teeth, canine teeth, tongue |

The pupil meshes `cf_Ohitomi_L02` and `cf_Ohitomi_R02` are not FBS targets.
The eyelid and surrounding geometry close over them. The three tear meshes are
FBS targets even when omitted from a native neutral preview. All 13 target
GameObjects and renderers are enabled in this source prefab; later character
state controls their visibility. `FBSBase` itself does not check target enabled
or active flags before writing weights.

## Data interface

The contract uses `schemaVersion: 1`, `weightUnit: "percent"`,
`sourceFrameWeight: 100`, `transitionSeconds: 0.15`, and
`updateOrder: ["eyebrow", "eyes", "mouth"]`.

Each `controllers` entry has `id`, serialized `openMin`, `openMax`, `fixedRate`,
`syncBlink`, `sourcePatternCount`, and `targets`. Each target records its node
and mesh names, source IDs, channel count, active/renderer flags, initial weights,
the exact `controlledChannelIndices`, and all `patterns`. A pattern contains its
`index` and `close`/`open` channel objects, each with `index`, `name`,
`frameIndex`, and `frameWeight`. Source IDs are serialized-file name and path ID
joined by a colon; path IDs are strings to avoid JSON integer precision loss.

`defaults` and every `presets[].inputs` are complete flat states with these keys:

```text
eyebrowPattern, eyesPattern, mouthPattern
eyebrowOpenRate, eyesOpenRate, mouthOpenRate
eyebrowOpenMax, eyesOpenMax, mouthOpenMax
blinkRate, mouthFixedRate
```

Pattern numbers refer to the FBS patterns. For ordinary eye catalog IDs 0–6,
the catalog number equals the FBS pattern, but this is not a universal rule.
`eyeCatalog.ordinaryRows` retains the actual `ChaListData` mapping and visibility
fields. A nonnegative `blinkRate` replaces the stored eye rate and, when
`syncBlink` is true, the eyebrow rate. A negative value retains their explicit
open rates. `mouthOpenRate` is the value supplied to the mouth controller from
voice analysis in the original; a preview may supply it directly.

## Weight calculation

For each controller, let `r` be its current open rate, `lo` its minimum, and
`hi` its corrected maximum when that correction is nonnegative, otherwise its
ordinary maximum. First calculate:

```text
openness = lo + (hi - lo) * clamp(r, 0, 1)
if fixedRate >= 0: openness = fixedRate
N = truncateTowardZero(clamp(openness * 100, 0, 100))
```

The original operations use single-precision floats. This quantizes the open
percentage to an integer before pattern or transition weights are applied.
For example, mouth rates `.009`, `.01`, and `.999` produce open percentages
`0`, `1`, and `99`. A nonnegative fixed rate overrides the interpolated
openness, rather than scaling it.

Before evaluation, each target resets every channel referenced by any of its
patterns. It then adds `(100 - N) * patternWeight` to the close channel and
`N * patternWeight` to the open channel. When both indices are equal, both
contributions accumulate into the same channel. Index `-1` is the source's
no-write sentinel. Reset only the controller's referenced channels; the face
and nose meshes receive eye and mouth updates independently. Some channels are
not controlled at all: nose channel 3, tooth channel 3, canine channels 3 and 35.

The resulting channel weights are percentages, not normalized coefficients.
For the single frame at weight 100, its geometric coefficient is weight/100.
The source helper does not clamp accumulated weights after pattern blending.
The exported presets select one unit-weight pattern per controller.

`maxActiveChannelsPerMesh` gives an exhaustive upper bound over the recovered
patterns. The face and nose can need four simultaneous channels for one pattern
per controller, or eight for a transition between two patterns per controller.
Other targets need two or four respectively. A fixed two-channel GPU limit
would therefore lose simultaneous eye and mouth deformation on the face.

## Baseline and ordinary expressions

`ChaFileStatus.MemberInit` selects pattern 0 for all three controllers and sets
all open maxima to 1. It enables blinking and mouth-width adjustment, and
disables fixed-mouth mode. `ChaControl.ChangeEyesOpenMax` preserves the status
value 1 but caps the controller value at **0.92**. This cap is separate from
the prefab's serialized `OpenMax: 1`.

With no voice input, the mouth open rate is 0. Normal unblinking eyes have rate
1; the eyebrow controller follows that rate. At neutral gaze the native default
state is therefore eye open percentage 92, eyebrow percentage 100, and mouth
percentage 0. Neutral is an active morph pose, not the mesh with all weights 0.

| Pose | Face eye channels and weights | Face mouth channels and weights |
| --- | --- | --- |
| Default | Close 0: 8; open 1: 92 | Close 28: 100 |
| Blink fully closed | Close 0: 100 | Close 28: 100 |
| Blink halfway | Close 0: 54; open 1: 46 | Close 28: 100 |
| Smile | Close 2: 8; open 3: 92 | Smile close 31: 100 |
| Smile, mouth open | Close 2: 8; open 3: 92 | Smile open 30: 100 |

The closed-eye catalog pattern (ID 1) and an actual blink differ. Pattern 1
uses eye close/open index 0 for both endpoints; the eye is fully closed even
at open rate 1, while eyebrows remain at their open endpoint. A blink drives
the rate to 0 and closes both eyes and synchronized brows. Likewise the smile
closed-eye pattern (ID 3) repeats its close index. The reference includes this
same-channel accumulation case explicitly.

Ordinary eye catalog rows are default (0), closed (1), smile (2), closed smile
(3), soft smile (4), left wink (5), and right wink (6). The full contract
retains each target's actual mapping: for example the nose's smile pattern 2
uses close channel 2 and open channel 1, whereas the face uses 2 and 3.
Assuming identical indices across meshes would be incorrect.

## Update order, gaze, and transitions

`FaceBlendShape.LateUpdate` first advances its blink controller, chooses an
external blink controller when supplied, calculates gaze correction, and then
evaluates eyebrow, eyes, and mouth in that order. Fixed blink flags make the
supplied blink rate negative, leaving the controllers' stored rates unchanged.
`ChaControl.ChangeEyesBlinkFlag(false)` also forces the eye and eyebrow stored
rates to 1, so disabling blinking does not leave an accidentally closed pose.

The actual prefab gaze corrections are up 0, down approximately .33, and side
approximately .17. These differ from the C# field initializer defaults. With
horizontal/vertical gaze rates `h` and `v`, controller maximum `M`, and prefab
corrections `U`, `D`, `S`, the recovered correction is:

```text
base = min(1 - U, M)
vertical = v > 0 ? U * clamp(sqrt(v), 0, 1)
                   : -D * clamp(sqrt(-v), 0, 1)
delta = vertical - S * clamp(sqrt(abs(h)), 0, 1)
delta = clamp(delta, -max(D, S), U)
correctedMaximum = base + delta * M
```

The source multiplies by `1 - (1 - M)` in float32; the expression above is its
mathematical simplification. `MathfEx.LerpAccel` supplies the square root.
The prefab's direct EyeLookController reference is null; `ChaControl` assigns
the runtime controller. At neutral gaze, the correction preserves the .92 cap.
The independent reference cases use neutral gaze only.

`ChangeFace` stores the previous **target** pattern dictionary and starts a
linear .15-second transition. `TimeProgressCtrl.Calculate` adds the frame delta
before calculating progress; `blend: false` ends the timer immediately. For
progress `t`, evaluate the previous dictionary with factor `(1 - t)` and the
new dictionary with factor `t`, using the same current quantized openness for
both. Source initialization ends the timer and sets both dictionaries to
pattern 0 at weight 1. Interrupting a transition uses its previous destination
as the new start, rather than capturing the currently interpolated pose.

## Timing and width features outside the stateless reference

The blink controller starts open. It closes and opens over independently
sampled durations of prefab base speed .15 seconds plus a random 0–.05 seconds.
Its idle interval is an integer sampled from 0 through 29, converted by the
source inverse-lerp/lerp round trip and multiplied by .2 seconds. A random
counter of 1–3 delays reopening for that many closing-complete update calls;
this part depends on update frequency. A zero initial deadline triggers closing
on the first eligible update. The recovered `SetSpeed` method clamps its
argument to at least 1 despite the serialized .15 default. The native
`SourceBlinkPlayback` preserves this behavior, with deterministic timing fixtures
and Maker integration described in [temporal playback](reverse-animation-playback.md).

The mouth prefab enables random width adjustment, with interval .5–.7 seconds,
scale endpoints .9–1, and `openRefValue: .2`. It interpolates between randomly
selected scale endpoints, subtracts `.2 * mouthOpenRate`, and floors the result
at zero. Only an open rate greater than .2 exposes the resulting width; at or
below .2 the returned adjustment is 1. This calculation uses the supplied
mouth open rate, even when a fixed morph rate overrides the expression weights.

Although `objAdjustWidthScale` is null in the prefab, the feature is not
inactive: `ChaControl.UpdateBlendShapeVoice` reads the stored adjustment and
writes `cf_J_MouthBase_rx.localScale.x` through
`ChaReference.RefObjKey.F_ADJUSTWIDTHSCALE`, when mouth-width adjustment is
enabled and a head exists. The contract records both the null direct reference
and this indirect target. The stateless fixtures intentionally do not evaluate
random width, voice audio, external blink controllers, or dynamic gaze.

## Independent verification

The helper evaluates the original serialized `PtnSet` directly with NumPy
float32 operations, independently of the emitted contract and Swift evaluator.
Each reference case contains its full inputs, quantized open percentages,
per-mesh full weight arrays, sparse nonzero weights, and active-channel count.
The 12 cases cover defaults, closed/half blink, smile, open-mouth smile, soft
smile, `.009/.01/.999` mouth-rate boundaries, a fixed half-open mouth, a half
neutral-to-smile transition, and the same-channel closed-eye pattern.

The fixture arrays start at source default zero weights and then apply the
three controllers' exact reset sets in source order. All source initial renderer
weight arrays are empty. The generator verifies every channel/frame reference,
the single-frame weight-100 assumption, source and decompiler hashes, expected
pattern/target counts, and the default and truncation boundary percentages.
Passing these cases establishes scalar channel-weight parity for those inputs;
it does not by itself establish render, random timing, or gameplay parity.

`Packages/Engine/Tests/EngineTests/SourceExpressionTests.swift` includes public
synthetic cases for quantization, blink synchronization, simultaneous controller
writes, same-channel accumulation, transitions, fixed openness, and invalid
source identities. Its private-data comparison runs only when all three paths
are explicitly provided:

```sh
IKKOKU_EXPRESSION_CONTRACT="$PWD/.local/reverse/rigs/source-expression-contract.json" \
IKKOKU_EXPRESSION_REFERENCE="$PWD/.local/reverse/rigs/source-expression-expected-weights.json" \
IKKOKU_SOURCE_AVATAR="$PWD/.local/reverse/rigs/source-avatar.json" \
swift test --package-path Packages/Engine --filter sourceExpression
```

The comparison checks every channel of every imported target part for all 12
cases, including repeated material passes. It permits the assembled preview's
intentional omission of the three tear targets; other missing target meshes
fail the check. A full exported head can also be supplied as the source rig.
