# Maker catalog asset library

Reviewed 2026-09-25 against `SourceMakerLibrary` and the current local registry.
This is a working, partial selection loader. See [bounded coverage](maker-coverage.md)
for denominators and the [component audit](../../component-audit/character-and-mods.md)
(CM-16–19; CMT-01–03, CMT-07 and CMT-09) for remaining work. Commands run from
the repository root; reported audits below are recorded evidence.

`Tools/reverse/maker_asset_library.py` exports an explicit selection from the
installed original Maker catalogs into an ignored local library. The native
loader resolves each card selection by category, ID and optional mod GUID. An
unresolved selection must remain visible as a diagnostic and must not change the
card's saved identity.

The current generated library is
`.local/reverse/maker-library/library.json`. It contains 15 drawable entries:

| Category | Original IDs | Recovered selection |
| --- | --- | --- |
| 101, back hair | 0, 2, 9 | Three original hairstyles, including the normal male preset |
| 102, front hair | 1, 2, 5 | Three original front styles |
| 105, top | 3, 13, 38, 39 | Original T-shirt variants and normal male T-shirt |
| 106, bottom | 3, 25 | Original long trousers and loose long trousers |
| 112, shoes | 1, 3 | Loafers and trainers |
| 123, face accessory | 0 | Square glasses, including their separate lens mesh |

Eleven additional entries represent source `p_dummy` catalog rows. Zero is not
treated as a universal removal marker: back-hair ID 0 and glasses ID 0 are actual
assets. Empty side/front/option hair and clothing entries are accepted only when
the original catalog explicitly names `p_dummy`. Additional head assemblies are
registered separately by `Tools/reverse/maker_assembly_variants.py`.

That registry adds heads 200 and 201 for each normal sex, alongside the separately
located head-00 base avatars. Each alternate head carries its own shape curves,
expression table, face and eyeline inputs. `SourceMakerAssemblyOptions` applies
the original correction table for nonzero Int32 body-bone types on the shared
skeleton. Special `exType` assemblies and resolver-backed mod heads fail explicitly.

Maker invokes the library when importing an original card, committing a converted
vanilla head/hair/clothing selection, and when changing its
saved outfit. Four hair slots, supported clothes and up to 20 accessory slots are
resolved from preserved source IDs and exact resolver properties. A missing entry
can retain reference hair/clothes with a diagnostic; an unresolved accessory is
omitted. Import and outfit viewing retain the card's selected IDs and plugin bytes.
The selection editor below changes only explicitly chosen vanilla destinations.

## Reproducible extraction

Use the pinned UnityPy environment and the hash-verified source files previously
copied read-only from the local Windows installation:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/maker_asset_library.py
```

An explicit bounded subset can be selected by repeating `--select CATEGORY:ID`.
The tool rejects missing or ambiguous rows, unsafe source paths, changed bundle
hashes, incomplete geometry and unsupported accessory parenting. It never reads
or decodes character-card thumbnails. Outputs must remain under ignored `.local/`.

Each drawable entry retains the exact source bundle, prefab, catalog table,
catalog hash and bundle hash. Rig and material-evidence files have their own
SHA-256 values. Per-entry appearance and card-binding sidecars are produced by
the material conversion stage; they do not replace original card identities.
The geometry stage preserves node names, source IDs, local transforms, inverse
bind matrices, morph targets and all mesh attributes in Unity coordinates.
The native boundary performs the existing single handedness conversion.

## Clothing state

The exporter selects fully dressed state 0. Original shirt prefabs serialize
both `n_top_a` and `n_top_b` as active, so active flags alone are insufficient.
Recovered `ChaReference.CreateReferenceInfo` maps `n_top_a` to `S_CTOP_T_DEF` and
`n_top_b` to `S_CTOP_T_NUGE`; `ChaControl.UpdateVisible` enables them for states 0
and 1 respectively. The exporter excludes the latter and the analogous known
bottom switches. This avoids superimposing two distinct clothing states.

This selection does not implement the game's clothes-state transitions, linked
top/bottom state rules, skirt dynamics, component options or hide-category rules.
The catalog's body-coverage mask is retained for material conversion. Validation
renders use complete shirts, long trousers and shoes.

The current native preparation skips indoor-shoe slot 7 and uses the outdoor
selection. A converted top can replace the body's coverage mask; an explicit
empty top clears it. These operations do not implement all source wear modes.

## Accessory attachment

The recovered original behavior is:

1. Accessory `type` is the catalog category (121–130); 120 means no accessory.
2. An empty `parentKey` uses the catalog's `Parent`. Otherwise the card's explicit
   parent is resolved through `ChaReference`.
3. The original uses `SetParent(parent, worldPositionStays: false)`, preserving
   the prefab's local transform under that attachment point.
4. `N_move` and `N_move2`, when present, receive the two correction transforms.
   `addMove[c,0] * 0.01` is local position, `addMove[c,1]` is Unity Euler degrees,
   and `addMove[c,2]` is local scale. Unity Euler composition is Z, then X, then Y.
5. `HideHair == 1` resets those corrections to identity instead. Those assets and
   weighted `Parent == "null"` accessories are outside the exported selection.

The source `Vector3[2,3]` MessagePack encoding is `[2, 3, vectors]`, where
`vectors` contains six three-number arrays in row-major order: position,
rotation, scale for the first correction, then the same for the second. This
shape was independently checked against installed card metadata without
decoding its image.

The selected glasses use the source `a_n_megane` attachment and a single
`N_move`. Their original `MeshRenderer` meshes are represented in the rig format
by one identity joint at each mesh's own node with weight one. This gives the
same world transform as an unskinned mesh, including nonuniform parent scale;
no original vertices or transforms are baked or altered. The frame and lens
remain separate material slots. Exact original accessory lighting, transparency,
hide rules and dynamics require further behavior recovery.

## Verification

```sh
IKKOKU_MAKER_LIBRARY="$PWD/.local/reverse/maker-library/library.json" \
  .local/reverse/unitypy-venv/bin/python Tools/reverse/test_maker_asset_library.py -v

.local/reverse/unitypy-venv/bin/python Tools/reverse/test_maker_asset_library.py \
  --audit .local/reverse/maker-library/library.json \
  --output .local/reverse/maker-library/geometry-audit.json
```

The extractor tests cover identity ambiguity, exact empty selections, path/hash rejection,
inactive and alternate-state filtering, and installed geometry. The independent
audit reads original Unity meshes directly and verifies 65,225 selected vertices
across all 15 drawable entries, original topology, normals, tangents, UVs,
inverse binds and every local transform. Attribute and matrix differences were
zero in the recorded audit. The 2,654 static glasses vertices also matched direct original MeshRenderer
transforms under three attachment transforms within `1.12e-16` using float64.
These checks validate extraction and the static representation; native assembled
pose, rendered appearance and edited-card identity preservation have separate
integration tests.

The library is deliberately partial. It is not an exhaustive catalog export,
automatic Unity shader translation, arbitrary plugin execution or an assurance
that every original/modded card can yet be displayed without diagnostics.

Selected-hair dynamics extraction is available, but Maker currently disables the
base dynamics document when prepared geometry changes instead of rebinding it.
Studio has a separate selected-component binding path. Recovering more geometry
therefore does not, by itself, enable its Maker animation or physics.


## Source selection editor (CMT-02 first slice)

The source panel's **Head, hair and clothing** pickers use the loaded library's exact
vanilla category/ID entries. Four hair slots and eight clothing slots are editable;
inner shoes are excluded because `prepare` assembles only outer shoes. Explicit
empty entries work through the same identity checks. Unavailable or modded current
identities are displayed as unavailable; a supported vanilla replacement removes
only that destination's saved UAR records. Malformed resolver metadata disables
replacement. Missing assembly appearance data or an unreadable appearance draft
also disables the pickers with a reason. Other saved part fields and their resolver
records are retained; original Maker default-reset semantics are not claimed.
No native prototype catalog IDs or display names are written.

The app prepares the candidate assembly once per actual selection and commits it
only after appearance and pose validation. Picker rows are cached on import,
outfit switch and selection commit; no menu rebuilding or resource loading is
added to animation ticks. No-op selections preserve the preview. Current selected
hair remains static in Maker, consistent with the existing dynamics limitation.
See the [card transaction contract](cards.md#transactional-vanilla-maker-selections-cmt-02-2026-10-23)
for serialization, preservation and failure behavior.

Release stage profiling on 2026-10-23 attributed about 748 ms of a changed
selection to library preparation and 107 ms to card appearance; card editing,
pose validation and immediate refresh were each below 2 ms. Preparation now
validates all reference hair/clothing paths and slots but parses their geometry
only when an unresolved selection needs that fallback. Converted and explicit-empty
selections skip reference rigs they replace. Every selected asset still passes
its path, size and hash checks on every preparation; there is no asset cache.

A quiet Release comparison on Mac14,14 with Xcode 27.0 (27A266a) used three
interleaved runs per implementation, each with 15 actual changed selections.
Eager-reference run medians were 841.13/845.83/847.45 ms; deferred-reference medians
were 646.05/645.93/648.42 ms. The median of run medians fell from 845.83 to 646.05 ms,
a 23.62% reduction. Individual ranges were 802.78–873.80 ms and 610.36–672.43 ms,
respectively; no-op requests took 0.058–0.070 ms. These measurements include
synchronous file/asset preparation and validation, not UI throughput or frame
rate. At that revision, changed selection still blocked for roughly 0.61–0.67
seconds. No per-frame work was added by the selection controls.

All six runs passed 46/46 scenario checks. Warmed back-hair 2 → 9 → 2 cycles
settled at 36 store-owned meshes and 55 textures; warmed top 39 → 38 → 39 cycles
settled at 34 meshes and 56 textures. Mesh bytes and deform counts stayed equal.
Repeated candidate previews rejected by an invalid pending shape preserved all
counted resources (34 meshes/57 textures/0 deform buffers), including on the first
rejection. A deliberately mismatched selected-asset hash passed 4/4 failure checks
with 36 meshes/35 textures unchanged. Store counts include reported retired
resources and exclude render targets/pipelines and resources owned only by
submitted frames.

All six exported cards were byte-identical to each other and to the earlier eager
implementation, including thumbnails. Seven focused Maker-library tests executed
with strict private fixtures, covering exact assembled geometry/palette/identity
preservation, unused malformed-path rejection, selected-asset hash rejection,
and required hair/clothing fallback failures. Build/input hashes, per-step
resource/timing records, controlled source variants and independent byte audits
are retained in the private `.local/codex-renderer-maker-models-2026-10-23/`
evidence directory. The earlier 34-step Debug run and the smaller bounds/pose
optimization comparison also passed; their timings are not used for the deferred
reference-loading result above.

### Asynchronous selection preparation (CMT-02, 2026-10-24)

Source asset selection sends immutable card/library inputs to a dedicated serial
CPU queue. One assembly may be decoding and at most one newer request may wait;
newer requests cancel older callers promptly and discard their results. Existing
path, size, hash, identity and assembly validation remains in `prepare`. The queue
never receives a preview or GPU resources. Appearance construction, pose/frame
validation and the final replacement still run without suspension on the main
actor, so this change does not eliminate every selection pause.

The previous character remains visible while decoding. Hair/clothing pickers are
disabled until completion or Cancel, preventing independent choices from being
silently replaced by a request based on the same old card. Shapes, expressions,
colors and customization/ABMX toggles remain editable. At commit the transaction
reads and validates those current edits; it does not restore a pre-decode copy.
An import, rig/library replacement, outfit change, source close, mode exit or
explicit Cancel invalidates the request. Switching back to Maker does not revive
an old request. A picker task first entering after leaving Maker rejects before
starting preparation; inactive results cannot submit a Maker frame over Studio.
Export cancels pending selection and saves the displayed,
committed card and its supported edits; the pending UI states that behavior.
Resolved no-ops do no preparation and preserve preview/GPU identity.

`maker-async-selection.json` holds the actual worker at deterministic barriers to
exercise these interleavings. It never substitutes a fabricated assembly or skips
validation. The existing selection round trip retains numeric and resource gates;
its report also records snapshot/preparation/commit wall times (including the
final refresh in commit) and main-actor heartbeat gaps. The async scenario runs
after app initialization, while the older synchronous scenario ran inside
initialization. Its validated capture mode keeps
the interactive Maker view and viewport absent, preserving the headless harness:
SwiftUI preview lifetimes and display-link resource allocations must not enter
its strict resource checks. Main-actor timers can now advance while preparation
runs, so elapsed timings still include a scheduling difference and must not be
presented as a pure decoder speedup. Separate visible UI verification is needed
for pending controls and interactive editing responsiveness.

Validation on 2026-10-24 passed 39 focused Engine tests with no skips (including
four deterministic queue tests), 81 runner tests, and the 55-step async scenario.
The scenario covers current shape/color/mode edits, precise late pose rejection,
explicit cancellation, supersession, export, outfit/library/import replacement
and source close. Its state and resource comparisons remain strict. The existing
46-step selection scenario also passed; its original-format export is byte-equal
to the baseline. An independent audit of the async export found exactly seven
intended scalar leaves changed (face/body rates, two selection IDs and three color
components), with unrelated records/tokens, other outfits and trailer preserved.

The quiet Release comparison, before the later mode-exit guard, alternated
baseline `72e7af6` and candidate `a987e4f`
three times, using the same synthetic card and preserved pre-half-state library.
All six runs passed 46/46 steps, with 15 successful changed selections per run;
the initial seed no-op, explicit no-op and rejected selections are excluded from
these timing distributions. The library SHA-256 was
`d898fea155e53abd30226d0633c832649a60570cffbcbbf1f47dc4c474cbb609`.
The fixture map was promoted during this window, but both launcher snapshots and
the preserved input files had identical hashes; all six runs used that same old
library. This comparison does not measure half-state assembly performance.

| Metric (ms) | Baseline | Async candidate |
| --- | --- | --- |
| Total selection, median of three run medians | 658.36 | 653.60 |
| Total selection, individual run medians | 646.91 / 672.64 / 658.36 | 637.35 / 653.60 / 656.24 |
| Snapshot, median of run medians | not instrumented | 0.28 |
| CPU preparation wait, median of run medians | not instrumented | 543.86 |
| Owner-thread commit including refresh, median of run medians | not instrumented | 110.47 |
| Maximum main-actor heartbeat gap per selection, median of run medians | not instrumented | 112.42 |

The baseline's entire selection call ran synchronously on the main actor. The
candidate's longest individual heartbeat gap was 131.90 ms; heartbeats advanced
during CPU preparation. Total completion time remained similar, and the candidate
has different scheduling and heartbeat instrumentation, so this is evidence for
a shorter main-thread stall, not a decoder or whole-selection throughput gain.
The roughly 110 ms synchronous commit remains a responsiveness limit. Every
per-step resource snapshot and all six exported cards matched exactly. Baseline
and candidate executable SHA-256 hashes were
`5e4d1d9cd4143dd71eaba4df14cfdd8b4f26fed2a871b087c3d27ee5f7502fd2`
and `19e37c16884738345244b4b9311bc65f0099f952569adf30c56c76afe9d5b62b`.
Reports, input hashes and byte audits remain private under
`.local/codex-continue-2026-10-24/maker/`.

Integrated visible UI verification changed back hair 2 → 0 → 9, edited height to
0.63 and checked hide/show recovery. The transient pending panel completed before
the UI capture could observe it. Editing/cancelling while pending is therefore
verified through deterministic production-path scenarios, not yet by a captured
interactive workflow; no whole-character or original-player parity is claimed.


### Normal head selection (#182)

The **Normal head** picker selects converted normal heads 0, 200 and 201 for the
current sex and `exType=0`. It uses a dedicated transaction because each head owns
its shape curves, expression targets and source manifest. The four hair and
clothing slot APIs cannot substitute for a head replacement. Head choices are
cached when the card is opened; the picker adds no animation-tick catalog scans.

`selectingVanillaHead` patches only the `Custom.face.headId` token and removes
exact `ChaFileFace.headId` resolver entries in both supported Extended Save
locations. Equal numeric IDs with a resolver still require cleanup. A vanilla
no-op validates the face version and resolver metadata, then preserves all bytes
and GPU identities. Unknown fields, unrelated resolver records and other record
payloads remain intact. Special `exType` values, unconverted heads and incomplete
contracts fail explicitly; head selection never substitutes reference geometry.

`SourceMakerHeadPreparation` resolves and hash-checks the selected assembly and
loads geometry, shape/expression contracts and correction data on the existing
bounded serial preparation queue. Head, hair and clothing requests share its
cancellation generation. Before commit, the owner checks the active mode, saved
card, coordinate and requested assembly identity, then uses the latest draft
shapes, colors, ABMX settings, expression and animation clock. The replacement
preview, contracts, manifest URL and saved head ID commit together without a
suspension. The selected head keeps the current edits; this does not implement the
original Maker's head-preset/default-reset behavior.

Appearance JSON and texture reads, texture composition/upload, preview creation
and pose/frame validation remain on the owner. Candidate base textures use
`SourceAppearanceLoadTransaction`: existing cache hits stay shared, new handles
remain unpublished until validation succeeds, and abandoned loads release only
those new handles. If another consumer publishes the same key before commit, its
cache entry stays unchanged and the candidate keeps an appearance-owned lease.
Successful uncontended loads retain the existing persistent cache behavior.
Composed texture leases and preview mesh cleanup continue to own their respective
resources. This boundary avoids treating resource-count changes as ownership.

The Maker lane includes paired selection/fresh-process reload checks for female
and male head-0 inputs. It requires `IKKOKU_MAKER_HEAD_FEMALE_CARD`,
`IKKOKU_MAKER_HEAD_MALE_CARD`, `IKKOKU_MAKER_HEAD_SELECTED_FEMALE_CARD` and
`IKKOKU_MAKER_HEAD_SELECTED_MALE_CARD`. The selected-card aliases point to
`.local/verification/maker-scenario-exports/maker-head-female-selected.png` and
`maker-head-male-selected.png` respectively in the checkout running the lane.
Each sex's reload follows its export immediately, with distinct output artifacts.
The scenarios use controlled API calls, with background animation paused for
failure-frame comparisons; they do not establish original-player UI or rendered
appearance parity. Existing independent geometry gates remain the source-model
reference, at their unchanged tolerances.


Local Release acceptance for this bounded transaction passed 26 focused Engine
checks without skips, including 18 fixture assembly preparations, exact card-token
and resolver checks, queue cancellation, and synthetic partial-load, cache-collision
and texture-lifetime controls. Both normal sexes pass 55 scripted selection checks
and seven fresh-process reload checks; the six existing Maker lane checks also
pass. The cold head-200 pose rejection retains 43 meshes and 64 textures for the
female input, and 43 meshes and 81 textures for the male input. Warm 200→201→0
cycles retain the same head-0 resource counts (98/115 cached textures respectively)
with no growth. Counts include store-owned retired resources; they are not process
footprint or frame-rate measurements. Runtime/script/input provenance and distinct
per-sex exported artifacts are retained privately under
`.local/codex-continue-2026-10-24/rolling/maker-head-selection/`. The initial female
artifact paths collided with the subsequent male run; that report is retained
unchanged, and the female pair was rerun successfully to distinct paths. Source
shape/player tolerances and production rendering algorithms are unchanged.


A quiet Release acceptance on 2026-10-24 passed eight checks in 79.201 seconds:
two interleaved fresh-process selection/reload pairs per sex, on clean runtime
checkpoint `441ee33`. The launcher verified all 551 Apps/Packages/Shaders/Assets
inputs against binary SHA-256
`b2ccfe006b273b3e5c0f56524fc3fa6027e40f75a1a47efda6c7a4ba2b1c9a73`.
The following ranges contain two samples each for the same 200→201 transition.
Cold means the first head-201 appearance in that process, not a cold filesystem
cache; warm repeats it after both head 201 and head 0 have loaded.

| Input / state | Snapshot ms | Async preparation ms | Owner commit ms | Total API ms |
| --- | ---: | ---: | ---: | ---: |
| Female, cold 201 | 0.293–0.319 | 557.670–574.642 | 146.977–155.037 | 706.065–731.122 |
| Female, warm 201 | 0.262–0.274 | 558.551–565.891 | 111.486–112.381 | 671.536–679.718 |
| Male, cold 201 | 0.288–0.308 | 588.796–589.642 | 151.810–152.685 | 742.098–743.762 |
| Male, warm 201 | 0.263–0.293 | 587.579–592.581 | 108.777–112.908 | 701.936–702.800 |

Preparation is wall time including queue and scheduling. Owner commit includes
the appearance I/O, decoding, composition/upload and candidate validation described
above, final replacement and refresh. Cold main-actor heartbeat gaps were
148.948–157.000 ms for female and 153.015–154.810 ms for male; warm gaps were
113.212–115.506 ms and 111.462–115.822 ms respectively. Thus off-owner assembly
preparation does not yet make selection smooth: approximately 109–155 ms remains
on the owner, a measured responsiveness limitation. No-op selection bypassed
preparation/commit, taking 0.318–0.396 ms female and 0.285–0.294 ms male while
retaining all resource counts and identities.

Cold 201 cached 17 additional textures in each sex (81→98 female, 98→115 male).
Warm transitions retained 98/115 textures, 43 store-owned meshes, 12 retiring
resources, one 14,517-byte hidden buffer and zero deform buffers. Head-201 mesh
buffers totalled 28,189,528 bytes female and 28,138,208 bytes male; returning to
head 0 restored its prior mesh-byte count. Failure and cancellation retained the
old counts/frame/context, and all eight distinct exported-card artifacts are
hash-verified in `quiet-retained/`. These measurements do not establish frame rate,
process footprint, wider source UI behavior or rendering parity.


The same Release binary also passed a visible native GUI check on the normal
female head-0 fixture: the popup listed exactly 0, 200 and 201, actual 0→200→201→0
selections committed the expected value and success status, and the dressed
viewport remained visible with the picker enabled. This verifies that bounded
female control flow; the two-sex API checks above separately cover persistence,
latest edits and rollback. It does not establish male GUI or whole-Maker/source
appearance parity. The parent-owned review is retained as `root-gui-review.json`.

The four new synthetic appearance-transaction tests run each complete load and
lifetime sequence on a dedicated thread, returning their 22 observations to the
calling Swift Testing task for assertion. This follows the existing live-tick
fixture helper and keeps synchronous MetalKit texture work off cooperative test
workers without changing test selection, parallelism, assertions or the public
lane's 600-second limit. The local full Engine suite passes with this arrangement
in 15.333 s; the unmodified local baseline also passed, including with a strict
cooperative pool. Hosted runs of the original tests repeatedly timed out while
their appearance tests were outstanding. The first hosted diagnostic identified
`swiftpm-testing-helper` as the test process but missed its stack because it
only matched older executable names; the sampler now includes that helper.
Worker starvation remains a hypothesis pending hosted evidence. This is test
isolation, with no production runtime or performance claim.
