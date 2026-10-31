# Character Maker: recovered shape and persistence contracts

Reviewed 2026-09-25 against the current source. This reference explains the
channel format and the initial direct-setter contract. The dedicated
[body](body-shape.md) and [face](face-shape.md) solvers own destination coverage;
the [component audit](../../component-audit/character-and-mods.md) owns feature
status and follow-up tasks. Commands run from the repository root.

This investigation recovers data contracts from the installed Mono assemblies and
local Unity TextAssets. It provides a native evaluator for the original slider
**source channels** and the initial direct bone setters. Dedicated runtime solvers
now implement the recovered body/head destination formulas and selected original
normal female/male assemblies. Original card import, converted card-selected
parts, bounded appearance edits and edited-card export are available. Arbitrary
asset conversion, full material parity and complete character animation remain
incomplete; [Maker assets](maker-assets.md) describes the usable selection path.

## Inputs and reproducibility

The Character Maker assembly is `Koikatu_Data/Managed/Assembly-CSharp.dll`,
5,386,240 bytes, SHA-256
`0038281caf8df48a7903c55dc389642eeeb3f2a9114bd9d68ac11c8ac0396bc5`.
The observed player is Unity 5.6.2f1 with Mono. This assembly differs from
CharaStudio's assembly; do not substitute one silently for the other.

Targeted ILSpy outputs for `ChaFile`, `ChaFileCustom`, `ChaFileBody`, `ChaFileFace`,
`ChaFileHair`, `ChaFileDefine`, `ShapeInfoBase`, `AnimationKeyInfo`,
`ShapeBodyInfoFemale`, `ShapeHeadInfoFemale`, and `BlockHeader` were identical
between the two assemblies. `ChaControl` differs: Maker loads body/head bone
prefabs from `chara/oo_base.unity3d`; Studio loads them from
`studio/base/00.unity3d`. The relevant names are `p_cf_body_bone`,
`p_cf_body_bone_low`, and `p_cf_head_bone`. Body shape initialization uses the
`cf_j_root` subtree. These names are observed asset references, not native aliases.

| TextAsset | Bundle under `abdata` | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| `cf_anmShapeBody` | `chara/oo_base.unity3d` | 121,513 | `8118434ea30fe94ea3be5fcb8b2afe7221fd31023361e7c02e1b0700497945c2` |
| `cf_anmShapeHead_00` | `chara/bo_head_00.unity3d` | 90,698 | `eb010900f2daa6822202c912eff5498a133423749c9bf6d466e949ec9178e029` |
| `cf_custombody` | `list/customshape.unity3d` | 6,086 | `044346038e552507a7e0cb34d48bc547608254fd9bdea4a475a50520ebffacd4` |
| `cf_customhead` | `list/customshape.unity3d` | 3,313 | `f0efd3610de9eaef01e11e2d609b6a4752d902bbd7acd275af9063a7b4c7c314` |
| `shapecorrect` | `list/shapecorrect/shapecorrect.unity3d` | 1,156 | `a4c048d96181991c3696ab508ed176a751af0447fb5cbeeacdaef2b3191c1ace` |

Binary inputs, decompiled code, labels, and generated data stay ignored under
`.local/reverse`. `rigs/inventory.json` and `rigs/shapes-inventory.json` provide
asset provenance. `decompiled/Character/Koikatu/manifest.json` records assembly and
decompiler output hashes. This repository contains the decoder and documentation,
not the original assets or recovered game implementation.

After fetching the assembly and extracting the TextAssets:

```sh
python3 Tools/reverse/analysis/character_contracts.py --recover
```

The result is `.local/reverse/rigs/character-shape-contract.json`. Omitting
`--recover` regenerates the JSON from existing recovered type metadata. The tool
uses narrowly matched array/enum declarations; it is not a general C# AST
translator. Unexpected array sizes, enum syntax, missing channels, corrupt
records, nonfinite samples, or unresolved categories cause errors.

## Original customization pipeline

`ChaFileDefine` identifies 44 body values and 52 face values by array index.
`ChaFileBody.MemberInit` initializes each body value to 0.5; face defaults come
from the explicit `cf_faceInitValue` array. Many face defaults differ from 0.5.
Maker controls send normalized values in the 0–1 range to
`ChaControl.SetShapeBodyValue` and `SetShapeFaceValue`; source indices and values
must be retained separately from Ikkoku's existing named -100–100 sliders.

The observed data flows as follows:

1. `ChaControl.InitShapeBody/InitShapeFace` selects the animation and category
   TextAssets. Body uses `cf_anmShapeBody` and `cf_custombody`. Face uses
   `cf_customhead` and a `ShapeAnime` name from the selected head's catalog entry;
   this dataset covers head 00's `cf_anmShapeHead_00` only.
2. `ShapeInfoBase.LoadCategoryInfoList` parses tab-separated rows: slot index,
   source channel name, position XYZ flags, rotation XYZ flags, and scale XYZ
   flags. Every flag except the string `0` is enabled. A slot can update several
   channels; different slots can update different axes of the same channel.
3. `AnimationKeyInfo.GetInfo` samples each selected channel at the slider value.
   Position/scale interpolate linearly. Rotation interpolates each Euler degree
   component with Unity's shortest-angle `LerpAngle`. The interval is determined
   by `(sampleCount - 1) * value`, not by the stored sample-number field.
4. `ShapeInfoBase.ChangeValue` overwrites only the enabled axes in intermediate
   source state. Initial source position/rotation are zero and scale is one.
5. `ShapeBodyInfoFemale.Update` and `ShapeHeadInfoFemale.Update` apply specific
   formulas and component setters to actual destination bones. Many formulas
   combine source channels, mirror sides, or apply correction values. These are
   not generic blend-shape weights and cannot be replaced by matching names.

| Domain | Slider slots | Animation channels | Samples/channel | Category bindings | Source enum entries | Destination enum entries |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Body | 44 | 119 | 25 | 157 | 111 | 86 |
| Face, head 00 | 52 | 89 | 25 | 89 | 59 | 59 |

The additional animation channels are preserved even when the category table
does not reference them. Every referenced category channel resolves in the
extracted animation data.

Selected verified nonsexual slot meanings and bindings:

| Domain/index | Meaning | Source channels |
| --- | --- | --- |
| Body 0 | Height | `cf_a_height`, `cf_a_height_aid` |
| Body 1 | Head size | `cf_a_head` |
| Body 2 / 3 | Neck width / depth | `cf_a_neck`, on different component masks |
| Body 37 / 38 | Shoulder width / depth | `cf_a_shoulder` plus associated collision/aid channels |
| Body 39 / 40 | Upper arm width / depth | `cf_a_arm02`, blend/aid channels |
| Body 41 / 42 | Elbow width / depth | `cf_a_farm01`, blend/aid channels |
| Face 1 | Upper face forward/back | `cf_J_FaceUp_tz`, `cf_J_NoseBridge_ty` |
| Face 2 | Upper face up/down | `cf_J_FaceUp_ty`, `cf_J_NoseBridge_ty` |
| Face 3 | Upper face size | `cf_J_FaceUp_ty` scale |
| Face 4 | Lower face forward/back | `cf_J_FaceLow_tz` |
| Face 6 | Lower chin up/down | `cf_J_ChinLow` |
| Face 16 / 17 | Cheek width / depth | `cf_J_CheekUp_s_L`, `cf_J_CheekUp_s_R` |
| Face 18 | Cheek height | `cf_J_CheekUpBase` |
| Face 38 / 39 / 40 | Nose tip / nose height / bridge height | `cf_J_Nose_tip`, `cf_J_NoseBase_rx`, `cf_J_NoseBridge_rx`, respectively |

For example, extracted `cf_a_height` scale XYZ is approximately 0.84 at value 0,
0.92 at value 0.5, and 1 at value 1. `cf_J_FaceUp_tz` position Z is 0, 0.0025,
and 0.005 at those values. These are raw Unity local values; apply coordinate
conversion only when writing the destination pose.

## Binary layouts

`AnimationKeyInfo.LoadInfo(Stream)` reads little-endian i32 channel count; then
for each channel a .NET length-prefixed UTF-8 name and i32 sample count; then for
each sample an i32 number followed by nine float32 values: position XYZ, rotation
XYZ, scale XYZ. The native metadata generator checks the complete file boundary.

`shapecorrect` contains i32 count followed by that many nine-float transforms.
The observed file therefore holds 32 correction records. Their indices are named
by `ShapeBodyInfoFemale.CorrectKeyName`. The initial direct-target evaluator does
not consume them; the complete `SourceBodyShapePose` solver applies their original
additive component corrections when the caller requests corrected bones.
`SourceMakerAssemblyOptions` accepts standard type 0 and every nonzero Int32
type when the assembly supplies that table. Nonzero types change corrections
on the shared skeleton; they do not select newly recovered body meshes.

`ChaFile.SaveFile` uses a different format from the Studio scene:

1. Optional PNG thumbnail, i32 product number 100, .NET string `【KoiKatuChara】`,
   .NET version string `0.0.0`, i32 face-thumbnail length, and face-thumbnail bytes.
2. i32 serialized block-header length and a MessagePack block header.
3. i64 total block-payload length, then block bytes. Block header records contain
   `name`, `version`, `pos`, and `size`; positions are relative to block payload.
4. The `Custom` block contains i32 face-data length plus face MessagePack data,
   i32 body-data length plus body MessagePack data, and i32 hair-data length plus
   hair MessagePack data.

`ChaFileFace`, `ChaFileBody`, and `ChaFileHair` use MessagePack property-name maps
(`MessagePackObject(true)`). The relevant shape arrays are `shapeValueFace` and
`shapeValueBody`; current nested versions are face/body 0.0.2 and hair 0.0.4.
The header also describes `Coordinate`, `Parameter`, and `Status` blocks. The
initial investigation recorded their framing. The current native
`SourceCharacterCard` implementation reads shape/parameter, appearance and
coordinate records plus Extended Save while retaining the original bytes. Edited
export patches only supported shape/color values and selected thumbnails, updates
framing, and preserves untouched records, unknown fields and plug-in data. The
Maker imports supported normal male/female cards using head IDs 0, 200 or 201
and standard or corrected body-bone options, when their local assembly data is
available. It exports a new original-format copy. Unknown nested MessagePack values are not coerced
through JSON; preservation does not imply native plug-in execution.

## Native scope and limits

### Validate decoded domains once

`SourceShapeDomain.init(from:)` validates each complete, immutable domain before
returning it. The containing `SourceShapeContract` retains its schema, coordinate,
range, domain-count and duplicate-ID checks without traversing every domain a
second time. Direct domain decoding and embedded contract decoding retain the
same typed errors, error order, coding paths, sampled states and destination masks.

Acceptance on 2026-10-31 used candidate `51bb3073` against runtime control
`890b1468` with matching toolchains and pinned inputs. All 28 focused tests passed
without skips, including the recovered shape/body/face checks. Fresh Release
Maker collections passed 248 functional checks: female/male selected and reloaded
exports matched between arms, all 12 corresponding resource/work records matched,
and four reloads consumed their own newly exported cards. The build runners first
recorded exit 126 for lingering owned compiler children; the observed children released
naturally, and supplemental full-bundle verification accepted the products without
rebuilding or rewriting those raw results.

A separate quiet collection ran female ABBA and male BAAB, with two processes per
arm/sex and six head transitions per process. Its 152 checks, 48 stage records,
16 no-op checks and eight exports passed with matching non-timing work and bytes.
The following medians pool 12 observations per arm/sex; those observations are
clustered within two processes and are not 12 independent launches.

| Sex | Shape decode, control → candidate | Selection, control → candidate |
| --- | --- | --- |
| Female | 22.55 → 22.49 ms | 217.70 → 215.73 ms |
| Male | 22.43 → 22.59 ms | 214.63 → 217.52 ms |

This removes a redundant validation traversal but establishes no consistent
latency improvement. `shapeDecode` includes decoding and validation; it does not
isolate the removed traversal. The change adds no asset coverage or source-game
parity claim, and the broader owner-thread work in [#192](https://github.com/grabbiel/ikkoku/issues/192)
remains open.

### Bounded decoded-contract reuse (local integration)

Local integration `4ad74a45`, reviewed on 2026-10-31, connects immutable shape
contracts to optional normal-head preparation. Every preparation still performs
the original contained, size-checked file read. Reuse keys combine SHA-256 of
those actual bytes, their length and the decoder version; a hit skips only
decoding. The default nil input preserves the original preparation path without
cache hashing, admission or new timing work. Later expression, rig and appearance
validation retains its original order.

The ledger bounds live holders to six entries, 8 MiB of logical entry charge and
four snapshots, including values retained by canceled workers and delayed
deliveries across resets. Charges use checked native element strides and UTF-8
lengths; they exclude spare capacity, allocator headers, temporary decode storage
and native value copies outside the cache. This is not an RSS bound.

The worker stages a candidate only after successful CPU preparation. Maker
publishes it beside rig reuse after the selection-generation and active-mode
checks and all fallible preview, appearance and frame preparation. Failed or
canceled selections retain the previous cache. Reset epochs reject stale
delivery; a full ledger requests a clear only on successful owner commit, while
an intrinsically oversized contract bypasses admission without evicting entries.

All 20 focused tests passed without skips, including the 12 foundation checks
at `48885ea4`. They cover Unicode accounting, overflow, immutable copies,
concurrent admission, foreign/stale publication, cancellation, reset, delivery
retention and release outside locks. Integration regressions preserve typed
errors and read/size/validation order, including changed bytes at the same path,
length and timestamp. Eighteen normal-head combinations preserve decoded
contracts and evaluated body/face states; six warm observations each reuse one
contract without decoding and retain three entries totaling 1,217,103 logical
bytes.

The six pinned female/male head 0/200/201 contracts total 2,434,206 logical entry
bytes on the tested arm64 host; a six-entry snapshot adds 96 reference bytes.
The complete 88-entry build-product archive remained unchanged before and after
the focused run, and every observed process released.

Fresh unsigned arm64 Release apps at candidate `4ad74a45` and control `ab1aae04`
passed bundle inspection. Both build wrappers originally reported surviving
Interface Builder children after compilation; those failures are retained.
The children exited naturally, and separate archive/inspection receipts accepted
the artifacts without rebuilding. The candidate binary SHA-256 begins
`88143c65`; the control begins `a2722f30`.

The two apps passed 248 functional scenario checks covering female/male heads
0/200/201, failure recovery, cancellation, edits and save/reload. Four matching
export roles produced byte-identical cards across the apps. Resource counts and
non-shape work matched at all 12 compared selection stages. The candidate still
read and hashed each selected contract; failed preparations did not warm reuse.
These checks establish state and persistence behavior. Separate rendered-frame
comparisons remain pending before integration acceptance.

A quiet female ABBA / male BAAB sequence passed 152 additional checks across
eight fresh processes, retaining all 48 selection observations. Each process
selected heads 200, 201 and 0 twice. The table reports arithmetic means of six
selections per cell, with only two independent processes per arm and sex:

| Sex | First-use selection, control → candidate | Repeated selection, control → candidate |
| --- | --- | --- |
| Female | 480.07 → 482.69 ms | 102.97 → 80.85 ms |
| Male | 493.65 → 496.09 ms | 102.70 → 80.89 ms |

Repeated selections skip about 22 ms of shape decoding while adding about
0.55 ms of hashing. First use adds hashing and an approximately 0.08 ms admission
traversal; its measured total selection time increases by 2.4–2.6 ms. Every
repeated sex/head cell improves in this cohort. Inclusive phase durations are
not added together. First use means first occurrence in that process, not a
cold disk cache. Ordinary desktop activity and an idle VM remained, and head
observations within a process are correlated. No selections were excluded.
This supports a bounded repeated-selection benefit, not an FPS, RSS or general
source-fidelity claim. Owner-thread changes are mixed; [#192](https://github.com/grabbiel/ikkoku/issues/192)
remains open.

### Shape evaluation boundary

`SourceShapeChannels.swift` strictly loads the generated schema, reconstructs
default source state, samples channels, applies masked slider values, and emits
verified direct destination updates. It validates dimensions, finite numbers,
indices, duplicate names, slot order, value range, and explicit destination
coverage. It rejects out-of-range modded slider values; support for extended
ranges requires a separately verified contract.

The initial direct destination metadata contains one body target and eleven face
targets. Body `cf_a_height` directly sets `cf_n_height` scale XYZ. The face set
covers straightforward component setters for upper/lower face translations,
upper-face and lower-chin scale, selected nose translations, and cheek positions.
Each update includes masks so the caller preserves untouched destination axes.

The direct-setter metadata still lists 85 body and 48 face destinations outside
this initial evaluator. The dedicated `SourceBodyShapePose` and
`SourceFaceShapePose` solvers now implement all 85 body `Update` destinations,
the three body `UpdateAlways` setters and all 59 face destinations. The normal
head 0, 200 and 201 assemblies supply their own curves to that updater. This includes
masked left/right updates, bone corrections, height compensation, reciprocal
scales, face-base parent scale and composed rotations. Their linked reports above
contain current formula coverage and independent checks. Destination coverage is
reported against the loaded rig; normal male Maker height follows the original
fixed-height policy. Low-poly caller remapping, full body dynamics and expression
coupling remain incomplete. Direct-setter metadata alone is not the runtime
coverage map.

`SourceShapeDomain.destinationUpdates` returns raw Unity absolute local values;
it does not find bones, alter a skin, or assume source channels are destinations.
The consumer must retain the original hierarchy, apply masks to the correct
destination's local pose, and convert basis/rotation with the engine's Unity
coordinate adapter.

The initial channel investigation recorded six native tests, including interpolation across the 360° boundary,
the 180° tie, sample-number independence, mixed-slot component preservation,
invalid-contract rejection, failed updates leaving state unchanged, and Codable
round trips. The optional local-data test parsed the extracted contract and
evaluated every domain at 0, 0.5, and 1 with no missing channels.

```sh
IKKOKU_SHAPE_CONTRACT="$PWD/.local/reverse/rigs/character-shape-contract.json" \
  swift test --package-path Packages/Engine --filter sourceShape
```

The initial channel investigation did not render an original image or compare
character screenshots. Subsequent selected clothed assembly captures and numeric
body/head proofs are documented separately; complete visual parity remains unverified.
