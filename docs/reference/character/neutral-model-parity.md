# Neutral original-player model comparison (R2)

Issue #136 adds an independent original-player geometry gate for the normal
female/head00 control, female/head200, and male/head200. It also corrects the
source high-detail female hand scales in the production pose path. This is a
bounded selected-model comparison, not whole-character or whole-game parity.

## Reference and capture context

`Tools/reverse/original_character_probe.py --model-variant female00|female200|male200`
creates a new fully clothed card in an isolated CharaStudio player. It waits for
the Studio scene, loads the requested normal model, drives exactly one original
`Studio.HandAnimeCtrl` per side with `Init(actualSex)` and pattern 0, disables
subsequent component updates, calls the original character update methods, and
invokes the original `FaceBlendShape.LateUpdate` with blink disabled. It records
Animator states/playheads and measured eye angle rates. No fitted hand clock or
native-evaluated transforms/weights seed the reference.

The original assembly is CharaStudio `Assembly-CSharp.dll`, SHA-256
`902b9a237337b17a64514bdb0d857b460ece4fb6a57c658375dd32c5fa504c45`, Unity
5.6.2f1, linear color space, Direct3D 11 under Parallels. The generated `run.json`
binds the probe source hash and private player root/PID; its logs identify the
single validation plug-in. Requested and actual sex/head/bone type, loaded head
catalog ID, requested/actual shape arrays, detail level, correction flags and
hand-controller readback counts are retained. A source fallback is an error.

The normal male load changes requested height 0.5 to actual saved height 0.6.
The native inspector uses that saved value and the normal-male head/neck factor
0.91; it does not impose a separate Maker-only clamp. Eye openness is evaluated
by the original complete face step: head00 yields 92%, head200 90% at zero gaze.
An early development probe that forced 92% for every head was rejected, not
used to change the expression implementation or relax tolerances.

Zero post-load frames alone do not prove determinism. Two independent female00
captures must compare exact transform records, Animator states, rest identities,
morph identities/weights and all source geometry streams. These repeats cover
this quiescent fixture, not arbitrary asynchronous or animated loading.
The repeat gate rejects the same resolved folder and copied producer records;
it requires distinct recorded VM/root/PID identities with the same probe source
hash, and includes both `run.json` hashes. A changed frame hash alone is not
evidence of a separate run.

## Source correction and runtime order

Recovered `ChaControl.LateUpdateForce` applies, after body/hand shape updates,
only for `hiPoly && sex == 1`:

| Destination | Flag on | Flag off |
| --- | --- | --- |
| `cf_j_forearm01_L/R` | `(0.92, 1, 1)` | `(1, 1, 1)` |
| `cf_j_hand_L/R` | `(1, 0.9, 0.9)` | `(1, 1, 1)` |

These are absolute local scale setters. `Manager.Character.Start` enables the
hand flag; the arm flag defaults off. Both the exact Studio DLL and retained
Maker source show the rule. Male and low-detail bodies receive no setter.
The missing female hand scale caused up to 0.007331 source-unit vertex error;
matching the original late rule removes that discrepancy without fitting.

`SourceBodyLateCorrection` binds up to four exact destination indices once per
assembly. Duplicate targets fail; reduced/head-only rigs may omit targets.
Each pose applies only those cached indices, in place. Shape-only APIs and the
low-level `SourceRigPreview` default keep the late pass disabled. Application
callers explicitly select source high-detail options. Maker samples animation
before `preview.pose`, then applies this late pass before supported static ABMX.
Studio caches the final four scales from its shape/static-ABMX baseline and
restores them after body and hand animation, before FK/IK. Shape edits rebuild
that cache transactionally; a new outfit constructs a new preview. Appearance
replacement preserves its options. This avoids multiplying static modifiers on
each frame. Imported static ABMX handling remains separate from execution of
an original ABMX plug-in; animated ABMX runtime parity is not established here.

The retained converted motion library contains 411 clips with 1,640 arm/hand
scale bindings, so a baseline-only correction is insufficient. A regression
covers animated scale replacement, repeated application, shape-cache rebuild,
flag states, male/low-detail no-op, reduced rigs, and the actual Metal deform
kernel. The neutral source captures do not independently verify the full
animated/FK/IK pipeline; those runtime-order checks are native regressions.

The historical R1 `original-character-probe/frame.json` actually records
`cf_j_hand_L/R.localScale == (1,1,1)` from its earlier startup context. Its legacy
`card-pose` and shader/live-fixture diagnostics remain explicitly uncorrected;
new settled-player captures must use `card-model`. Do not silently reinterpret
that historical reference with settled-player defaults.

## Numerical gate and exclusions

```
ikkoku-inspect card-model <avatar.json> <fixture-card.png> <maker-library.json>
python Tools/reverse/compare_original_model.py <probe-folder> <native.json> \
  --repeat <independent-same-model-probe> --visual-output <silhouette.png>
```

`card-model … --studio-wear` assembles the Studio wear set (half-state meshes
and indoor shoes) and selects only the renderers the card's saved clothes state
and `shoesType` draw, through `SourceStudioWearLayout.saved`; its report adds a
`studioWear` block (saved and loaded state, body mask, drawn and switched-off
parts). It is for settled-player captures that keep a saved wear state
([half-state meshes](../studio/scene-editing.md#half-state-meshes-and-indoor-shoes-st-c03-third-slice)).

Use the female `source-avatar.json` or male `source-male-avatar.json` from the
matching converted head directory. The inspector requires exact selected
assembly identity and all selected catalog entries to be converted. It records
input hashes and evaluates native shape, neutral expression and full skinned
vertices independently of the original capture.

The comparator binds each selected mesh by its original rest-position SHA-256,
name, triangle order, ordered skin-joint names and inverse-bind matrices. It
gates every selected skin-joint **world matrix** and every selected vertex at
`2e-5` absolute source units/matrix elements; morph percentages at `1e-4`.
It keeps three separate vertex comparisons: native versus original runtime
matrix skinning; native versus actual `SkinnedMeshRenderer.BakeMesh`; and
BakeMesh versus original matrix skinning. Raw Unity 5.6 BakeMesh positions
retain embedded renderer scale; only its recorded renderer scale/matrix are
used to express them in world coordinates. No alignment or fitted phase is used.

The full hierarchy matching is diagnostic only. Local transforms, unskinned
helpers/colliders and ambiguous duplicate camera paths are not promoted to
parity by this gate. The report gives total native/source node counts, selected
skin binding counts and unique native skin joints. The male body has one extra
source `bones` tail entry (`cf_d_bust00`) beyond its 100 inverse binds; it cannot
participate in that skin palette and is reported separately.

Each model selects 19 of 20 assembled drawable parts: normal body, face,
eyebrows, nose line, teeth, upper/lower eyelines, four iris/highlight meshes,
tongue, top, bottom, outdoor shoes and four hair meshes. The inspector explicitly
excludes canine geometry because this card has `doubleTooth == false`.
The ordinary Maker/Studio preview now applies that saved flag as described
below; these historical geometry comparisons still use the inspector. The source-only female
`o_shadowcaster` and male `o_shadowcaster_cm` meshes (1,360 vertices each) are
excluded using exact rest hashes. Any other missing visible source mesh fails.
Unity Cloth, nonzero hand patterns, dynamics, nonzero gaze, other outfits/body
bone types, low detail, special male, initial/multiframe morph variants and
material/color rendering are outside this fixture.

The optional PNG compares selected original BakeMesh and independently posed
native vertices with the same recorded camera and CPU triangle-union rasterizer.
It is a controlled geometric diagnostic, not a Metal or source-color claim.

## Validation and performance

Private captures, native reports, comparisons, logs and controlled images are
retained under `.local/codex-renderer-maker-models-2026-10-23/base-model/`.
The final three original-player gates pass with 19 selected parts each:

| Model | Vertex entries | Skin bindings / unique joints | Max world matrix error | Max native/source vertex error |
| --- | ---: | ---: | ---: | ---: |
| Female / head00 | 37,052 | 773 / 226 | 7.30e-7 | 7.16e-7 |
| Female / head200 | 38,594 | 976 / 224 | 7.30e-7 | 7.16e-7 |
| Normal male / head200 | 37,115 | 976 / 224 | 6.19e-7 | 5.63e-7 |

Native versus raw BakeMesh maximum vertex error is below 6.20e-7 in all three.
The independent female00 repeat has exactly equal 814 transform records and
20 complete geometry/BakeMesh streams. Each controlled CPU silhouette has
IoU 1.0 and zero differing pixels at the recorded 768×1024 camera.

Five focused Release Swift tests pass, including the actual Metal deform kernel
and supplied Studio animation/shape-cache regression. All 25 public Python
probe/comparator tests pass. These synthetic tests cover corrupted identities,
missing meshes, shadow exclusions, shape/flag mismatch,
last-vertex errors, independent bone/morph/BakeMesh failures, malformed buffers,
path traversal, same/copied run rejection and repeat drift.

`card-model ... --benchmark 10000` reports Release p50/p95 nanoseconds for the
bound late pass against a disabled pass, after 32 warmups. It mutates a uniquely
owned full-rig pose, includes clock overhead, and makes no frame-rate claim.
Names, asset parsing and binding are outside the measured/frame path. Run this
only during a coordinated quiet window with original players stopped.

The coordinated 2026-10-23 Release run measured female/head00 at 125/125 ns
p50/p95 and female/head200 at 125/167 ns over 10,000 iterations. The male no-op
and disabled controls both measured 0/42 ns; these small timings include clock
quantization and overhead. Full commands, hardware/compiler identity and the
executable hash are in `late-correction-benchmark.json`. This measures the
cached four-bone pass only, not assembly/loading, whole-pose time or app FPS.


## Production canine visibility (2026-10-24, #156)

The recovered `ChaReference` binds `ObjDoubleTooth` to the exact GameObject
`cf_O_canine`. `ChaControl.VisibleDoubleTooth` sets that object's activity to
`fileFace.doubleTooth`, without a sex-specific branch; the Maker mouth toggle
writes the Boolean and invokes that method. This is recovered-code evidence
from the Studio assembly hash above, not a new original-player run.

`SourceRigPreview` now reads the saved Boolean once during Maker/Studio card
preparation. It binds the exact target and affected descendant part indices
once, then changes only cached part activity. A true flag can activate an
authored-inactive target; inactive ancestors, inactive descendant objects and
disabled renderers still prevent drawing. Duplicate target names fail. A missing
target is a no-op, and a missing legacy/synthetic card field preserves authored
activity; a present non-Boolean field is rejected. Cardless preview callers keep
that unspecified behavior. Appearance/asset replacement preserves the option.

Ordinary production frames combine this activity with the existing hidden-part
filter and omit every material pass of a hidden canine. Both live conservative
bounds and exact framing include the potentially visible geometry, so changing
the flag does not rebuild resources or change camera framing. There is no
per-frame card decoding, name search or hierarchy traversal. The native API
supports changing the flag in place; a new Maker UI toggle and export editor are
outside this slice.

The three retained neutral player cards independently decode to false and their
visible mesh lists omit the canine. No retained true-state player capture was
found in this bounded review. Both states are covered by native production-frame
regressions, including inactive hierarchy controls, multi-pass materials,
unchanged mesh identity/resource generation and six converted normal male/female
head variants (0, 200, 201). Those selection-only fixture cards omit the Boolean;
their initial authored activity and explicit on/off states are tested separately
from complete synthetic Boolean-card decoding. The targeted preview/live-bounds/
installed-library lane passes 11 tests. This fixes a production visibility gap;
it does not establish new source-color, animated-face or true-state player parity.

## Coupled body and face shape input (#160)

`--model-shapes Tools/reverse/fixtures/model-shapes-coupled.tsv` adds a bounded
non-neutral shape case to the same quiescent pose protocol. The public synthetic
TSV changes only these saved rates before `CreateFemale`/`CreateMale` and
`LoadAsync`; it leaves all other source defaults intact:

| Domain | Slots and requested rates | Coverage |
| --- | --- | --- |
| Body | `0=.25, 1=.75, 2=.25, 3=.75, 37=.25, 43=.75` | Height, head size, neck width/depth, shoulder width and forearm size |
| Face | `0=.25, 3=.75, 21=.25, 38=.75, 48=.25` | Overall width, upper face size, eyebrow rotation, nose-tip height and ear rotation |

The case exercises the existing 44-body/52-face kernels together. In particular,
the face-base scale reads the body-derived parent world scale; the source applies
body shape before face shape and then its late arm/hand correction. This is a
shape case with neutral expression/gaze and disabled hand animation, not a new
animated-pose or expression variant. Normal male still coerces requested height
`.25` to actual saved `.6`; that coercion is reported separately rather than
counted as a native mismatch or imposed as a new Maker clamp.

The host validates and canonicalizes finite Float32 rates in `0...1`, unique
domain/index pairs and exact domain bounds before touching the player. The guest
validates again, retains the exact input file and hash, and records every requested
and actual body/face value. The comparator normalizes JSON number representations
to Float32 so a source `Single` written as `0.1` compares with its exact promoted
host value. Malformed types, duplicate rows and unrequested changes fail.

```
python Tools/reverse/original_character_probe.py --model-variant female00 \
  --model-shapes Tools/reverse/fixtures/model-shapes-coupled.tsv --output <private-folder>
# Collect this owned player, then evaluate its saved card with card-model as above.
python Tools/reverse/compare_original_model.py <private-folder> <native.json> \
  --shape-baseline <independent-neutral-female00-capture> \
  --repeat <independent-same-shapes-female00-capture> \
  --visual-output <silhouette.png>
```

A shaped capture requires an independent, unmodified same-model neutral baseline.
The gate binds the exact source assembly, player/fixture versions, sex/head/bone
identity, shape context, Animator state, detail/correction flags and selected
original rest identities. Requested arrays must equal the baseline arrays plus
only the listed overrides; actual arrays allow only the documented male-height
coercion, and native arrays must equal the saved actual values. Distinct owned
producer records and all input/card/frame hashes remain in the report.

The independent card parser compares original raw tokens, not a card reconstructed
by undoing edits. Every non-`Custom` block, the complete hair record, all face/body
bytes outside the shape-array spans, header and trailing payload must remain
unchanged. Array framing and every unrequested shape scalar token must also
remain byte-identical; only the listed scalar tokens may differ. Saved array
values must match the original-player readback. Rendered
card thumbnails are excluded because the shapes intentionally change the image.
Unknown fields and plugin payloads are covered by corruption tests. The existing
joint-world, all-selected-vertex, topology, BakeMesh and source-only repeat gates
retain their tolerances and omissions above.

The 2026-10-24 original-player run passes for all three normal assemblies:

| Model | Selected vertices | Skin bindings / unique joints | Max world matrix error | Max native/source vertex error | Max native/BakeMesh vertex error |
| --- | ---: | ---: | ---: | ---: | ---: |
| Female / head00 | 37,052 | 773 / 226 | 6.20e-7 | 7.16e-7 | 5.07e-7 |
| Female / head200 | 38,594 | 976 / 224 | 7.11e-7 | 7.16e-7 | 5.07e-7 |
| Normal male / head200 | 37,115 | 976 / 224 | 6.46e-7 | 9.54e-7 | 8.65e-7 |

Each still selects 19 of 20 prepared parts, with the same canine/shadow exclusions.
The independent female00 repeat has exactly equal 814 transform records, all 20
original geometry/BakeMesh streams, and saved card bytes. All three controlled
CPU silhouettes have IoU 1.0 and zero differing pixels; this does not test
production Metal shading or color. The full input/card gate also passes on the
repeat. Only the expected male-height coercion occurs.

The four fresh player runs compiled the same probe source SHA-256
`7a8d740a4d707e8067f25e48d9b2602984dab56aaf33114410ddcde2b926ce17` and used
input SHA-256 `5dcb282cc04654c9b3f5d5da238328756d192d5d754c10e0838dffce84e34c92`.
Each owned player was stopped after collection. The Release inspector built from
the unchanged native source at `b2dde03` has SHA-256
`15fd5e8e4b707cab625e18ac444f1abe336d490188c3a1ed19c6353f1a621ff4`.
Private captures, exact baseline identities, input/build hashes, full comparisons,
controlled images and logs are retained under
`.local/codex-continue-2026-10-24/mixed-shapes/`, with `summary.json` as the entry point.

All 36 focused Python tests pass, including malformed input, Float32 JSON
representation, changed identities/context, copied producer records, geometry
corruption and preservation of unknown/plugin/unedited shape tokens. The three
retained neutral comparisons remain compatible. No runtime discrepancy was
found for this bounded case, so no native pose formula or per-frame work changed.
Prepared part counts remain 20; no new assembly allocation, pose-cost or FPS
measurement is claimed. Other shape combinations, animation, non-neutral
expression/gaze, alternate bone types and material appearance remain separate
acceptance work.
