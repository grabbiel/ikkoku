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

The head candidate prepares selected card-appearance bindings and validated raw
RGBA inputs on the worker (see #192 below). Base/component appearance JSON and
image decoding, texture composition/upload, preview creation and pose/frame
validation remain on the owner. Candidate base textures use
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
The isolation change passed hosted run `40135675480`: all five public checks
passed, with Engine taking 42.722 s, and Debug, Release packaging and reverse
checks passed too. No captured stack proves worker starvation, so that cause
remains a hypothesis. This is test isolation, with no production runtime or
performance claim.


### Prepared head appearance inputs (#192)

`SourceMakerHeadPreparation` also prepares immutable `SourceAppearanceInputs` for
the selected base assembly and material components. Preparation and realization
share the same recipe resolver: requirements, resolver identity, color fields,
selected patterns and face layers choose the same inputs. The worker reads only
those chosen RGBA files, validates containment, dimensions, exact size and SHA-256,
and snapshots their bytes. It does not decode an entire pattern catalog or create
Metal resources. Existing synchronous appearance callers keep their default path.

Snapshots bind the exact manifest values, base URL and component list, including
accessory slots and indoor-shoe context. Realization uses the latest owner-side
colors and validates material targets before composition. Changed context or a
newly required input missing from the snapshot fails explicitly, without falling
back to owner-side file reads. Files modified after preparation do not change the
candidate's already validated bytes. The head transaction's card, coordinate,
mode and cancellation guards still precede its non-suspending final replacement.

Each input call keeps its existing 128 MiB bound; all input calls in one head
candidate now also share a 128 MiB retained-byte cap, checked before each read.
Repeated paths share storage within a call. Per-call and aggregate raw byte counts
are recorded with the selection timings. These counts exclude metadata, transient
read buffers, GPU images and other candidates; they are not peak process memory.
The preparation result owns the immutable arrays until commit or discard. Rendered
appearances retain the existing GPU texture leases, not these raw snapshots.

The focused Engine checks exercise real aggregate-cap failure, exact component
and base-context rejection, selected-only pattern reads, malformed dimensions and
hashes, path/symlink containment, and absent prepared inputs. Deleting source RGBA
files after preparation still permits CPU and Metal realization with later color
edits; the default caller then fails its file read. The expanded independent
image oracle checks both prepared and default input paths on CPU and Metal at its
unchanged one-byte tolerance. Existing queue cancellation, partial-load rollback,
cache collision and lease-lifetime checks remain in the focused set.


The 2026-10-24 local #192 acceptance passed all 33 selected Engine checks across
the initial 32 passes and one focused retry: the initial run's only failure was
an unset `IKKOKU_APPEARANCE_REFERENCE_ROOT`, then supplied explicitly for the
existing female/male pixel oracle. The Release build passed on clean `ec69b5f`.
Both sexes passed 55 selection checks plus seven fresh-process reload checks
(four processes, 41.701 seconds). All four corresponding exported cards match
the earlier baseline bytes, including the late failure, cancellation, latest-edit
and resource-retention scenarios. Logs retain the initial fixture failure.

A separate quiet comparison passed eight interleaved fresh processes in 59.954
seconds: female baseline/prepared/prepared/baseline, then male
prepared/baseline/baseline/prepared. Both binaries used the same 19-step cold,
warm and no-op scenario and fixtures. Baseline `096bd3e` (binary SHA-256
`bb1b5ddab59dad6fcf1dbbe7abf2cfcfce0089c8a276cdeda57d8f13088b2973`)
and prepared `ec69b5f` (`ced2ea660a6d1a63b970a1aa1950a22ba961510b058764125c96a671838de181`)
share the fine attribution instrumentation. The following ranges have **two
samples per sex and binary** for the same 200→201 transition. Cold means first
head-201 appearance in the process, not a cold filesystem cache.

| Input / state | Baseline owner ms | Prepared owner ms | Baseline total API ms | Prepared total API ms |
| --- | ---: | ---: | ---: | ---: |
| Female, cold | 155.473–165.162 | 128.566–143.899 | 736.932–773.583 | 766.141–804.481 |
| Female, warm | 118.813–122.943 | 91.865–110.547 | 702.642–711.137 | 718.084–754.269 |
| Male, cold | 159.823–166.154 | 129.178–130.848 | 782.312–800.665 | 797.755–809.439 |
| Male, warm | 115.438–124.333 | 90.119–91.458 | 730.253–748.508 | 741.062–746.863 |

This is a **responsiveness tradeoff, not a total selection speedup**. Mean owner
commit fell by 19.672–32.976 ms across those four groups, while async preparation
rose by 33.618–54.032 ms and total API time rose by 4.582–30.054 ms (about
0.6–4.2%). These small samples do not establish percentile behavior. Moving
validated input work is useful for interactive selection, but 90–144 ms owner
stalls remain. The owner pixel-read/hash phase fell from 29.817–31.205 ms to
0.011–0.019 ms (prepared lookup), and binding preparation from 2.409–2.966 ms to
0.005–0.012 ms. The remaining composition phase measured 60.551–80.091 ms; it
includes texture allocation/upload, encoding and synchronous completion, so it
is not a measurement of GPU execution alone. Cold base appearance loading still
cost 37.849–44.652 ms; warm loading cost 0.889–1.342 ms.

Every prepared transition retained **32,506,112 raw input bytes** (approximately
31 MiB) across seven input calls, below the 128 MiB candidate cap. Head-201
resource counts and byte totals exactly matched baseline: 43 meshes, 98 female
or 115 male textures, 12 retiring resources, one 14,517-byte hidden buffer, and
no deformation buffers; mesh buffers were 28,189,528 bytes female and 28,138,208
bytes male. No-op API times across both binaries were 0.220–0.408 ms and retained
resource identities. All four exports per sex match byte-for-byte across the
paired binaries and repeats. The 48 timing records, 24 artifacts, source/input
hashes and phase analysis are retained under
`.local/codex-continue-2026-10-24/rolling/maker-head-owner-commit/`. This does not
claim reduced peak memory, frame-rate improvement or wider source appearance
parity.

### Compositor fallback input reuse (#202)

Each Metal material recipe has 21 input slots. An absent main image uses opaque
white; other absent inputs use transparent zero. The compositor now creates each
needed 1×1 fallback lazily and reuses it across its recipes. These textures retain
the existing `rgba8Unorm`, shared-storage, shader-read-only, no-mipmap contract.
They are uploaded once and retained only for that compositor's lifetime. Real
images and composed outputs remain independently allocated; output leases,
transaction rollback and the synchronous completion wait are unchanged.

The optional appearance diagnostics keep the existing aggregate compose interval
and add nested allocation/upload, encode/submit and wait/view intervals inside it.
Instrumentation and return cleanup can remain outside those nested intervals; do
not add them to the aggregate again. Counters distinguish actual real-input and
fallback texture allocations from fallback slot bindings. These transient textures
are not registered in `ResourceStore`, so unchanged store counts do not establish
unchanged total Metal allocations. Default callers without diagnostics skip the
additional clock reads and counters.

Eight focused Engine checks passed with strict fixtures and no skips. The new
synthetic production-path test covers mask-only, main-only and combined recipes,
CPU/Metal pixels, lazy white allocation, reuse across recipes, independent output
leases and cleanup. It observes four real input allocations and two fallback
allocations for 59 absent bindings, then a new pair of fallback allocations for a
separate compositor. The independent female/male raw-RGBA and expanded material
image oracles still pass at the existing one-byte tolerance, including prepared
and ordinary input paths; this is material-kernel evidence, not full appearance
parity. Existing failure cleanup and derived-lease checks also pass.

The 2026-10-24 Release acceptance used a fresh control at `8b79915`
(binary `0b378e84f8f1126c03e29afa1abb62f4f6e4f60c0f367e2d1f27e6b2c569fc3f`)
and candidate `4e7b46c`
(`bbcf8bbedf9053dee90a7e4f173ad0118bbe16c34d073f289488e5c66a0a368f`).
The 557-file source manifests differ only in the three implementation files and
one focused test. Four functional processes passed the 55-step selection and
7-step fresh reload scenarios for both sexes; all four exports are byte-identical
to their matching previous accepted outputs. The separate quiet comparison passed
eight 19-step processes in 59.754 seconds, female A/B/B/A then male B/A/A/B, with
fixed shapes/colors and clock. All four exports per sex match across both binaries.

The selected head-201 cold/warm intervals have two samples per binary and sex:

| Input / state | Control owner ms | Reuse owner ms | Control API ms | Reuse API ms |
| --- | --- | --- | --- | --- |
| Female cold | 126.558–128.345 | 118.943–123.036 | 749.231–757.564 | 734.364–746.195 |
| Female warm | 85.388–87.203 | 85.766–90.509 | 709.024–740.329 | 696.962–715.991 |
| Male cold | 126.809–132.315 | 125.911–137.606 | 790.972–796.072 | 788.531–804.500 |
| Male warm | 91.216–97.228 | 85.341–92.294 | 759.165–770.798 | 750.165–754.609 |

These mixed directions and small sample counts establish **no consistent latency
speedup**. The accepted benefit is bounded allocation reduction: each measured
selection has 20 actual-image inputs and 316 absent bindings across 16 recipes in
six compositors. The candidate records eight fallback allocations, versus 316
allocations from the control's one-allocation-per-absent-slot loop. Outputs and
completion semantics are unchanged. Candidate-only nested intervals measured
7.426–8.563 ms allocation/upload, 0.182–0.282 ms encode/submit and
51.152–55.855 ms wait/view. The last interval includes scheduling, synchronous
completion and view creation, and is not pure GPU kernel time. Overall composition
was 59.235–64.672 ms; these observations do not justify moving completion outside
the transaction without separate validation.

All selected head-201 samples retain the same 43 meshes, 98 female or 115 male
registered textures, 12 retiring resources, one hidden buffer (14,517 bytes), and
zero deformation buffers. Mesh bytes remain 28,189,528 female / 28,138,208 male.
Prepared raw inputs remain 32,506,112 bytes under the existing 128 MiB per-call and
aggregate caps. The 16 no-op checks retain their resource identities and take
0.238–0.383 ms. Neither store statistics nor retained raw bytes measure peak RSS
or total Metal allocation bytes; there is no FPS or percentile claim. Immutable
binaries, inputs, logs and 24 paired artifacts are retained privately under
`.local/codex-continue-2026-10-24/rolling/maker-compositor-fallbacks/`.

### Bounded synchronous composition batches (#208)

The Metal path now prepares all recipes in one `SourcePreviewAppearance.applying`
call, encodes them into one command buffer and waits once before publishing their
outputs. Input textures, output textures and parameters remain retained through
completion. All output views must succeed before resource registration and material
changes replay in their original order. A later invalid recipe, allocation failure,
failed command or missing view leaves the prior appearance and its shared leases
usable. CPU composition and callers without optional timing diagnostics retain
their existing behavior; completion remains synchronous on the owner.

Batching retains inputs longer. A separate **128 MiB logical input-pixel storage
limit per Metal application** bounds this retention, with checked arithmetic before
allocation. Repeated image uploads count separately, while each actually allocated
1×1 fallback contributes four bytes once per compositor. The existing 128 MiB
output limit and prepared-input limits remain separate. Extreme inputs exceeding
the new limit fail explicitly; there is no immediate-mode fallback. This budget
describes logical pixel storage, not measured Metal heap usage or peak RSS.

Eleven focused Engine checks passed with no failures or skips. They include
multiple-recipe pixels and material ordering, rejection of a later invalid recipe
without publication or dispatch, exact 12/20-byte repeated-upload boundaries,
fallback rejection before allocation, prior shared-lease lifetime, nil diagnostics
and CPU independence from the Metal-only limit. The independent female/male
raw-RGBA and expanded material oracles retain their one-byte tolerance. Four
functional processes passed both sexes' 55-step selection and 7-step fresh reload
scenarios in 42.257 seconds; all four exported cards match their previously
accepted counterparts byte-for-byte.

The 2026-10-24 quiet comparison used freshly built parent `45f355f`
(binary `be3e952d43ca953ead0c378af1c38ac90a1123ddaba878207ebf39a9e8023f56`)
and candidate `825e631`
(`2db016b849ade8cae4c9042eb2c2b13f9a2df067ba7a6404e473f1cd623142ae`).
The 557-file source manifests differ only in three implementation files and one
focused test. Eight interleaved 19-step processes passed in 60.109 seconds, with
fixed shapes, colors and clock. All four exports per sex are identical across
binaries and repeats. The selected head-201 intervals have two samples per binary,
sex and cold/warm state:

| Input / state | Control owner ms | Batch owner ms | Control API ms | Batch API ms |
| --- | --- | --- | --- | --- |
| Female cold | 118.122–121.322 | 118.633–118.779 | 753.904–757.062 | 746.329–749.101 |
| Female warm | 83.261–87.056 | 79.475–80.704 | 703.814–716.869 | 697.219–702.274 |
| Male cold | 126.634–127.779 | 120.734–123.373 | 799.052–802.630 | 789.459–796.318 |
| Male warm | 80.792–82.367 | 81.924–84.511 | 739.640–756.742 | 737.546–739.550 |

The candidate has lower API times in these small samples, but owner and composition
costs remain mixed: male warm owner time increased, and composition changed from
57.632–57.973 ms to 57.386–59.138 ms. Worker preparation remains substantial
(control 619.123–674.277 ms; candidate 616.196–671.366 ms), while snapshot costs
were 0.278–0.320 ms and 0.263–0.400 ms respectively. These observations do not
establish a consistent latency speedup or remove the remaining owner stalls;
the broader responsiveness work in #192 remains open.

The bounded change is fewer synchronous completions: each measured selection
still has 16 recipe dispatches across six appearance applications, but now records
six completions instead of the control's per-recipe 16 waits. The candidate retains
20 actual-image allocations, eight fallback allocations and 316 absent bindings.
Its nested allocation/upload interval was 7.332–8.727 ms, encode/submit
0.182–0.235 ms and wait/view 47.356–50.149 ms; aggregate composition was
55.131–59.138 ms. Nested intervals sit inside the aggregate and are not an exact
partition. Wait/view includes scheduling, synchronous completion and view creation,
so it is not pure GPU kernel time. Transient input textures are not registered in
`ResourceStore`; unchanged store counts do not measure their retention cost.

Selected head-201 resource totals match the control: 43 meshes, 98 female or 115
male registered textures, 12 retiring resources, one 14,517-byte hidden buffer and
no deformation buffers. Mesh buffers remain 28,189,528 bytes female and
28,138,208 bytes male. Prepared raw inputs remain 32,506,112 bytes; that is a
separate quantity from the new per-batch logical storage limit. All 16 no-op checks
retain resource identities and take 0.236–0.438 ms. There is no FPS, percentile,
peak-RSS or wider source-appearance parity claim.

The first offline retainer confused `-batch` with the candidate `-b1`/`-b2` suffix,
and the first analysis script contained accidentally renamed fallback counter
keys. Preserved v2 scripts correct the classification and keys against the same
app reports; no app, shader, scenario input or timing record changed, and no app
rerun was needed. Both binaries, 24 artifacts and 48 stage records were independently
verified. Frozen sources, inputs, original postprocessing attempts and corrected
results are retained privately under
`.local/codex-continue-2026-10-24/rolling/maker-compositor-batch/`.

### Cold base-appearance attribution (#192)

The normal-head selection caller records `baseAppearanceStages` on each successful
selection; ordinary loader callers omit diagnostics by default. There is no new
environment toggle. The sample subdivides the existing inclusive
`baseAppearanceMilliseconds` interval. It records appearance-document
reads and JSON decoding, contained-path resolution, mod-package loading and
library creation, mod-texture resolution, encoded texture-file reads and private
transaction lookups. The nested `textureLoads` sample distinguishes the existing
data-cache and image-cache checks, ImageIO image creation, `MTKTextureLoader`
loading and resource registration. Private transaction reuse is separate from a
shared-cache hit; two cache misses on the data-to-image path do not mean two
textures were created.

The image-creation interval covers `CGImageSourceCreateWithData` and
`CGImageSourceCreateImageAtIndex`. These APIs can defer decoding, so this is not a
measurement of complete CPU image decoding. The MetalKit interval includes its
existing loading work with sRGB, mipmap generation, shader-read usage and private
storage unchanged; it is not isolated GPU execution time. Registration excludes
the subsequent ownership callback. Named intervals omit surrounding validation,
material construction and instrumentation overhead; they must not be added to
the inclusive parent interval again.

Calls and failures record each attempted API interval, including throws. A failed
load increments `loadFailures` and retains only partial diagnostic observations;
head selection publishes its sample alongside a successful state commit. Encoded
file-byte counters count successful reads, including repeated references. The
resource-level `encodedBytesPresented` instead counts supplied `Data`, including
shared-cache hits; neither quantity measures decoded pixels, retained allocation
bytes or RSS. Actual registrations are counted independently from lookup misses.
Collectors belong to the synchronous caller, are not retained by `ResourceStore`
and introduce no extra clock reads or counters when omitted. These diagnostics
change no cache keys, publication, leases, image options, shader math or completion
scheduling, and alone establish no responsiveness improvement.

Seven focused Engine checks passed at `a54b44e` without failures or skips: four
existing transaction rollback, lease, cache-publication and collision checks,
plus three new diagnostic regressions. The latter verify one live private handle
for repeated references, shared-cache bypass of deliberately invalid image bytes,
and failed image/file loads that retain partial observations while releasing only
private candidates. They use public synthetic inputs on dedicated threads and
assert identities, counts and cleanup rather than elapsed-time thresholds.

Acceptance used fresh Release builds of parent `35e70e9` and candidate `a54b44e`.
Their complete 557-file build manifests differ only in the three instrumented
production files and the focused test file. The older `825e631` binary predates
unrelated integration changes and was not used as an overhead control. Four
candidate functional processes passed the 55-step selection and seven-step fresh
reload scenarios for both sexes; all four card exports match the prior accepted
batch outputs exactly.

The subsequent quiet comparison passed eight interleaved processes in 56.5 seconds
(56.694 seconds including the watchdog), retaining 24 artifacts and 48 successful
selection observations. Four exports per sex are byte-identical across the two
arms. The 16 no-op checks retain their resources and took 0.210–0.330 ms. The
selected head-201 cold/warm comparisons below have only two samples per arm and
cell; they observe combined instrumentation and run variation and cannot isolate
overhead or establish a speedup.

| Selection | Parent owner commit (ms) | Instrumented owner commit (ms) | Parent base load (ms) | Instrumented base load (ms) |
| --- | ---: | ---: | ---: | ---: |
| Female cold | 115.208–116.164 | 114.146–124.712 | 35.453–36.664 | 34.151–41.108 |
| Female warm | 79.858–81.241 | 79.332–81.322 | 0.905–0.971 | 1.000–1.042 |
| Male cold | 115.452–123.501 | 116.695–117.875 | 38.264–43.007 | 38.918–40.820 |
| Male warm | 74.640–83.998 | 77.221–78.151 | 0.873–0.949 | 0.929–1.031 |

The new cold-load breakdown attributes 32.006–38.064 ms in female and
36.470–38.533 ms in male to 17 synchronous MetalKit texture loads per selection.
Image creation accounts for 0.641–0.940 ms, encoded texture-file reads for
0.494–0.718 ms, and appearance-document read plus JSON decoding for
0.155–0.203 ms across those cold samples. Each cold load registers 17 private
textures. Female requests 24 textures with seven private reuses; male requests 22
with five reuses. The second lookup for each miss creates no additional texture.
Warm loads make 24 female or 22 male shared-cache hits, with no image creation,
MetalKit load or registration. All observed API/load failure counters are zero.
This identifies the existing synchronous MetalKit loading boundary as the next
candidate for investigation; it does not isolate its CPU and GPU costs or prove
that moving it to another executor is safe or beneficial.

Each female load reads a 5,754-byte document and 417,477 encoded texture bytes;
male reads 5,718 and 456,762 bytes respectively. Cold resource-level presentation
counts are 336,761 female and 389,942 male bytes after private reuse; warm counts
equal the full encoded-read totals because each request reaches the shared cache.
For these selected-head samples, both arms retain exactly 43 meshes, 98 female or
115 male textures, 12 retiring resources and one 14,517-byte hidden buffer. Mesh
buffers are 28,189,528 female or 28,138,208 male bytes; deformation-buffer counts
remain zero. The separate card-composition input snapshot remains 32,506,112 raw
bytes in both arms. These are observed store counts and logical input bytes, not
total Metal allocations or RSS.

Owner-commit differences have mixed signs. Mean total API differences are
+13.335 ms female cold, +15.877 ms female warm, −3.723 ms male cold and +6.810 ms
male warm, including worker variation outside the new diagnostic intervals.
The sample cannot establish zero overhead, a consistent latency change or an FPS
benefit. Candidate worker preparation takes 589.903–634.034 ms versus
77.221–124.712 ms on the owner. Further work must weigh the longer preparation
path against the user-visible owner stalls; both keep #192 open.

The original functional inputs and proof remain retained separately. Before the
quiet launch, a v2 lane changed only the eight process timeouts from 600 to 30
seconds and added a 120-second owned-process-group watchdog. Its first disposable
termination self-test exposed a Darwin liveness-query error after both synthetic
processes had exited; that attempt was preserved, and a corrected group-inventory
test passed. No application rerun was needed. The one quiet collection exited
normally with no timeout, signals or surviving group members.

Final integration at `bc32a083` merges accepted main `8153f14`. Its fresh Release
binary (`55b5bf0d…`) passes four further processes: 55 selection and seven fresh
reload checks for each sex, with all four exports matching their accepted
counterparts. Only three accepted plugin app files differ from the measured
candidate across the 557-file source inventory; the attribution code and tests
remain byte-identical. These are functional checks, with no repeated quiet run
or relabeling of the original measurement producers.
