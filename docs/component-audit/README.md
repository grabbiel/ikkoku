# Component audit and implementation backlog

**Baseline review: 2026-09-25 · commit `2cfb859` and that review's working tree.
Scoped acceptance updates through 2026-10-24 appear below.** Later entries update
only their named behavior and evidence; the original audit was not rerun in full. The
[documentation index](../README.md) links maintained guides and technical contracts. Older rebuild/checkpoint
documents remain useful evidence of individual milestones, but their completion
statements may no longer match the code.

The native app is a **partially reconstructed Maker and Studio**, with several
well-tested original numerical/serialization kernels. It is not yet a complete
Koikatsu gameplay port. Source card/scene preservation is considerably broader
than source appearance, behavior, editor access and full-frame visual parity.

## Read the audit

| Report | Components covered |
| --- | --- |
| [Character, Maker, cards and asset mods](character-and-mods.md) | Native prototype, original male/female assemblies, shape destinations, card-selected assets, expressions/materials/dynamics, edited cards, ABMX, resolver identities, zipmod packages and profiles |
| [Studio](studio.md) | Native scene editor, original scene reader/writer, source character loading, attachments, FK/full-body IK/guides, Animator, hair dynamics, camera/audio/routes/effects, timeline and plugin host |
| [Renderer and foundation](renderer-and-foundation.md) | CoreMath, glTF import, source rigs/avatars/bounds, GPU resources, Metal passes/shaders, original shader translation, matched frames, procedural/bundled assets and performance |
| [App, gameplay and plugins](app-gameplay-and-plugins.md) | App lifecycle, commands/capture, day/period cycle, fixed events, ADV, NPC gaps, C# semantic translation, IR runtime, lifecycle/transactions, plugin packages and installed adapters |
| [Toolchain and verification](toolchain-and-verification.md) | VM access, backend detection, managed recovery, converters/oracles, inspector CLI, Xcode/SwiftPM/distribution, tests, provenance and verification gaps |
| [File coverage index](file-index.md) | Every non-ignored repository file outside this audit folder, assigned to a report; includes tests, configuration, documentation and binary asset inventory |

Each report gives feature-level status, specific code comments/findings, relevant
evidence, and actionable remaining work with acceptance criteria. The file index
maps files to the responsible report; it is not a substitute for those feature
tables. Binary art is inventoried by asset family and loader/converter coverage,
not reviewed as executable code. Private `.local/` contents are reference evidence,
not part of the checked-in application inventory.

## Status definitions

| Status | Meaning |
| --- | --- |
| **Pending** | No executable native consumer for the named behavior. Parsing, decompilation or preserving its bytes does not change this rating. |
| **Infancy** | A scaffold, small executable prefix or native approximation exists; the original behavior or app integration is largely missing. |
| **Mid-stage** | A useful implementation exists, with meaningful gaps in coverage, integration, source semantics or verification. |
| **Fully ported** | Only the explicitly bounded behavior in that row has implementation and relevant source evidence. It never implies that the containing component, every asset/version, or the full game is complete. Native utility completion is explicitly identified and is not source-game parity. |

Qualifiers after a status define its scope. For example, an original binary field
writer can be fully ported for known existing records while original scene
creation/deletion is still pending. A native shader can work correctly while
original lighting is still approximate. Preserved plugin payloads are not executed
plugins. A matched frame using original baked vertices does not validate native
animation or scene reconstruction.

There is deliberately no whole-game completion percentage: a complete original
feature inventory and a common denominator across installed assets, DLC and mods
have not been established. Current catalog counts state their actual denominators.

## Component-level assessment

| Component | Overall stage | Main remaining boundary |
| --- | --- | --- |
| App shell and document commands | Mid-stage | Startup/lifecycle defects, portable data setup, source-aware controls and UI regression coverage |
| Native bundled character/Maker prototype | Mid-stage | Native generated assets and behaviors differ from original content |
| Original character shape/assembly | Mid-stage | Many bounded shape kernels verified; special/modded assemblies and broad asset coverage incomplete |
| Original card preservation/edit/export | Mid-stage | Strong bounded byte-preserving edits; selection/plugin mutations and version coverage incomplete |
| Materials and source appearance | Mid-stage | Selected recipes applied; missing layers/states and complete draw-shader parity |
| Asset mods/resolver/ABMX | Mid-stage | Immutable identities and static subset; migrations, dynamic callbacks and general mod geometry missing |
| CoreMath/Scene rig foundation | Mid-stage | Verified basis/rig kernels; broader geometry/deformation and degenerate input contracts |
| GPU/Metal renderer | Mid-stage | Default toon and opt-in live source paths exist; remaining material dispatch, resource limits, original effects and representative performance |
| Source shader translation/matched frames | Mid-stage | Bounded diagnostic and independent live gates exist; complete character silhouette/color parity and same-input sampling repeatability remain open |
| Native Studio editor/timeline | Mid-stage | Source Pose/Face/Clothes controls are reachable; broader interactive regression coverage and source timeline tracks remain incomplete |
| Original Studio scenes | Mid-stage | Broad parsing/preservation; mixed object/map/light/route/effect consumers and edit topology incomplete |
| Full-body IK/guides | Mid-stage | Recovered solver tests and source guide editing exist; broad GUI acceptance and actual original-player full-body comparison remain |
| Animator/dynamics | Mid-stage | Selected normal states and hair chains; remaining controllers, loop correction, cloth and full sequence parity |
| Voice/audio | Mid-stage | Scheduler/mixer subset; original waveform coverage, spatial/lip-sync and scene sound consumers |
| Gameplay as a playable game | Infancy | A headless native host runs one synthetic fixed event across save/reload; NPC, scene, presentation, original save state and an interactive mode are missing |
| General managed plugin compatibility | Infancy | Strict bounded AST subset and exact-revision native adapters; no general Harmony/coroutine/Unity host |
| Recovery/build/test infrastructure | Mid-stage | Reproducibility, explicit fixture skips, automatic orchestration and release gating |

## Current work and evidence

Overview reconciled **2026-10-24**; the task entries below name their acceptance
scope and distinguish local checkpoints from merged work. The
[README's eight-component table](../../README.md#current-scope) is the concise
support summary. The dated handoffs below retain each producer, fixture and
acceptance boundary; their old “next” steps are historical, not a live queue.

- **Models / Maker / Shapes:** six normal male/female head 0/200/201 assemblies
  have bounded original-player gates, plus head-0 bone-type-1 checks for both
  sexes. Asynchronous normal-head selection is merged. Prepared inputs reduce
  owner-thread stalls at a total-latency cost. Fallback reuse is merged with a
  verified allocation reduction, without consistent latency improvement.
  Bounded composition batching is merged in [#213](https://github.com/grabbiel/ikkoku/pull/213)
  and reduces the selected case from 16 waits to six;
  its small timing comparison retains mixed owner-thread results. See
  [#208](https://github.com/grabbiel/ikkoku/issues/208); remaining stalls stay
  tracked in [#192](https://github.com/grabbiel/ikkoku/issues/192).
- **Materials / Renderer / Visual Fidelity:** the controlled inner-shoe fixture
  reaches 18 live slots with two explicit body/face fallbacks. Same-input sampling
  variation remains open in [#188](https://github.com/grabbiel/ikkoku/issues/188).
  The [sampling investigation](../reference/renderer.md#translated-sampling-repeatability-investigation-188)
  distinguishes diagnostic controls from production behavior; reductions are
  evidence, not fixes or added material coverage. The latest controlled split
  associates variation with a discard statement in the instrumented program;
  source alpha testing remains required.
- **Mods / Plugins:** immutable library selection, bounded translated profiles
  and three exact native adapters have selected app/save/restore acceptance.
  Mounted-session controls and fresh-profile preview rollback are merged in
  [#206](https://github.com/grabbiel/ikkoku/pull/206). Legacy saved-profile native
  open and history restoration support candidate-owned attachment reads when
  initialization leaves the candidate scene unchanged; library installation
  retains its separate attachment-read gate.
  General plugin compatibility remains outside the supported subset.

Use the linked issue/PR state for work in review, and the owning reference for
exact commands, commits, costs, failed attempts and exclusions. Public CI checks
compilation and public fixtures; private original-player, app and GPU acceptance
remain separate. A later integration build does not replace a recorded runtime
measurement. Update this section only when the project-level boundary changes.

## Highest-priority handoff

Priorities are local to this project: **P0** is a confirmed broken current
workflow, **P1** closes a principal porting/integration gap, **P2** expands coverage
or hardens the implementation. Task IDs in the reports are stable references.

### Accepted Models, Materials and Plugins updates — 2026-10-24

| Component | Completed scope and evidence | Remaining boundary |
| --- | --- | --- |
| Models / CM14 | [#163](https://github.com/grabbiel/ikkoku/pull/163) verifies neutral/mixed shapes for female heads 0/200 and male head 200; [#164](https://github.com/grabbiel/ikkoku/pull/164) rejects malformed morph metadata. [#170](https://github.com/grabbiel/ikkoku/pull/170) adds normal female head 201: three fresh source/native comparisons cover 37,124 selected vertices and 994 skin bindings, with zero morph-weight error and an exact neutral repeat. Forty-eight focused Python tests pass; all 1,266 retained and 472 new capture inputs remain unchanged. [#174](https://github.com/grabbiel/ikkoku/pull/174) independently verifies normal male head 201: three captures cover 35,645 selected vertices and 994 bindings, with an exact 817-transform neutral repeat. Fifty focused tests and the retained gates pass; requested/actual model identity and the sole normal-male height coercion are explicit. | The head 201 matcher combines the already-required exact rest hash and renderer name; duplicate identities still fail and tolerances remain unchanged. No runtime formula or per-frame work changed. The completed normal male head 0 gate is recorded below. Broader shape/expression/animation coverage, special model types and complete production appearance require separate acceptance. [Model evidence and tolerances](../reference/character/neutral-model-parity.md). |
| Materials / R1, CMT-04 | [#162](https://github.com/grabbiel/ikkoku/pull/162) adds one normal-top GPU composite: independent base output is byte-exact and distinct colors differ by at most one byte. The controlled live fixture reaches 16/20 slots; three default-off capture pairs stay identical. [#165](https://github.com/grabbiel/ikkoku/pull/165) reduces sampler descriptor constructions from 48 to 4 in the measured cache workload. Each focused Debug/Release run executes nine passing tests with one named fixture skip; strict private Release separately passes all five gates, including that skipped case. [#173](https://github.com/grabbiel/ikkoku/pull/173) adds the normal-bottom composite: independent base/distinct targets meet the unchanged one-byte gate and controlled coverage reaches 17/20. All six strict private gates, five Debug/Release tests (six cases each), and three byte-identical default-off PNG pairs pass. | Body, face and shoes remain fallbacks in that fixture. Adding the top increased GPU work and memory. The sampler change establishes fewer allocations, with no demonstrated timing speedup: warm-hit median of run medians is 0.107 → 0.116 ms with overlapping ranges. [Renderer evidence and costs](../reference/renderer.md#native-normal-top-composite-r1cmt-04-159-2026-10-24). |
| Plugins / P-T02, P-T03 | [#161](https://github.com/grabbiel/ikkoku/pull/161) connects exact library revisions and scene targets, with pinned native save/fresh-process restore and identical same-clock PNGs. [#166](https://github.com/grabbiel/ikkoku/pull/166) adds prompt mount cancellation and request-owned panel state: four queue tests and 24 production app checks pass with no skips. A separate diagnostic GUI run verifies Cancel before worker release, queued retry, no stale mount, then successful retry, Pause and Unload for two adapters plus one translated fixture. [#172](https://github.com/grabbiel/ikkoku/pull/172) adds bounded offline DLL metadata inventory: all 13 synthetic tests and 51 private assertions pass; six retained originals yield six declarations and the two existing exact-hash adapters, with byte-identical repeat reports. | Inventory reads metadata without assembly execution, dependency resolution or mounting. The later complete installed snapshot below extends discovery only. Its timings are offline diagnostics, not a runtime speedup. [Inventory contract](../reference/mods/plugin-inventory.md). GUI cancellation used a temporary worker gate, separately hashed from production; it establishes behavior, not latency. Scene-open restoration still resolves files synchronously. General DLL/Harmony/API compatibility and GUID-specific original save adapters remain open. [Execution and app evidence](../reference/mods/plugin-execution.md#saved-scenes-and-migration). |

The completed corrected-model task [#178](https://github.com/grabbiel/ikkoku/pull/178)
adds independent neutral, neutral-repeat and coupled-shape acceptance for normal
female/head 0 with `boneType=1`. All three comparisons cover 37,052 selected
vertices and 773 skin bindings / 226 joints at the existing tolerances. The active
1,156-byte correction table matches exactly, the unique `cf_hit_head` local scale
matches 1.08, and the neutral repeat preserves all 814 transform records, 20
geometry streams and card bytes. Fifty-six focused Python checks pass; root
review also verifies all 32 hashed evidence descriptors in the summary. The
inspector hashes its correction input once; no runtime pose formula or per-frame
work changes, and no timing speedup is claimed. Original-player coverage for
other corrected types, broader shapes, full hierarchy and appearance remains
open. The measured producer and separately compiled merged
producer retain distinct provenance. All four CI jobs pass at the reviewed head
`78fcf76`; the change is merged. [Detailed scope and measurements](../reference/character/neutral-model-parity.md#corrected-female-head00-skeleton-176).

The completed normal male/head-0 task [#181](https://github.com/grabbiel/ikkoku/pull/181)
adds three passing source/native comparisons over 35,573 selected vertices and
773 skin bindings / 226 joints. The independent neutral repeat preserves 817
transform records, all 20 geometry streams and saved card bytes. Its sole source
coercion, height to Float32 0.6, is reported separately. Fifty-eight focused
Python checks and the retained gates pass; all 472 new capture files remain
unchanged, and root verifies the 29 hashed summary descriptors. This completes
neutral and one coupled-shape acceptance for the six converted normal
female/male head 0/200/201 assemblies. No runtime formula, per-frame work or
performance benchmark changes. Broader shapes, corrected male types, animation,
full hierarchy and appearance remain open. All four CI jobs pass at the reviewed
head `4d7bb46`; the change is merged. [Detailed scope and measurements](../reference/character/neutral-model-parity.md#normal-male-head00-179).

A later read-only snapshot covers all 243 installed DLLs (26,759,208 bytes),
with identical before/after source manifests. Eight bounded shards per scan give
byte-identical repeat reports: 212 files declare 218 plugin entries, 30 are managed
libraries and one has no managed metadata. All 486 source-to-report mappings
across both scans were checked. The single-report attempt exceeded its 16 MiB
limit and remains a recorded failure; the complete shard sets retain that per-report
limit and fit within a separate 64 MiB aggregate budget. Historical paths/sizes
match, but only six prior hashes establish unchanged content; the other 237 lack
historical hashes. These counts establish neither loadability nor executable
compatibility. Evidence is indexed privately under
`wave-three/plugins/installed-inventory/coverage-index.json`.

#170, #172, #173 and #174 passed all four CI jobs at their reviewed heads and
merged. The #173 test-fixture type-check repair also passes focused Debug and
Release locally. Capture/inventory validation adds no native frame work; the
material path has the measured costs below.

The bottom path increases registered textures from 76 to 81 and measured Metal
allocation by 18,366,464 bytes. Paired run medians overlap: GPU time changes from
0.631 to 0.655 ms and synchronous completion from 1.324 to 1.309 ms, establishing
no speedup. Same-input live repeats still differ at a few pixels, including two
old-store full-frame pixels with a maximum channel difference of 14 on the 0–255 scale. This remains
a separate repeatability gap; source-composite tolerances are unchanged. See the
[bottom scope and measurements](../reference/renderer.md#native-normal-bottom-composite-r1cmt-04-168-2026-10-24).

The combined Release runtime for #161–#163 passed all six Maker and 56 Studio
scenario checks with no skips; final merged runtime sources matched the tested
integration. #164 changes offline validation only. #165 and #166 each passed all
four CI jobs at their merged heads and the separate local checks above; the
earlier combined run is not evidence for those later changes. Each completed row
retains its exact scope: these results do not mark an entire component fully ported.

A later combined Release build of #165/#166 passes all 24 plugin checks and
retains 16 live material slots with unchanged composite keys. Toon, geometry,
top and eye outputs remain byte-identical in the controlled replay. Small hair
image differences also occur between runs of the same pre-change executable;
strict whole-live-image repeatability remains open. The
[renderer reference](../reference/renderer.md#composite-sampler-allocation-r1cmt-04-2026-10-24)
records the measured scope and limitations.

A subsequent combined Release build containing #173 and the accepted plugin
runtime passes all 24 plugin checks and retains 17 live / three fallback slots,
with unchanged attachment reports and composite keys. Ten stable diagnostic
PNGs are byte-identical to the measured material build; the full-frame PNG also
matches in this pair. Five hair pixels (maximum channel difference 2) and one
front-hair pixel (maximum 1) still vary. This bounded integration check adds no
source-parity or performance claim.

**Local acceptance — HideAllUI, [#185](https://github.com/grabbiel/ikkoku/pull/185):**
The third exact-revision native adapter implements Studio interface visibility
with session-local state, viewport-owned Space, and recovery that preserves host
preferences. Sixteen focused Engine tests and 21 native app checks plus four
fresh-process restore checks pass without skips. The independent original-player
trace covers ten phases and sixteen retained targets; its corrected validator
pins the observed exception while preserving the initial failed validations.
Root GUI checks verify library mounting, text-field Space ownership, modified
and held Space, hidden panels leaving the accessibility tree, noninteractive
hidden controls, preference preservation, and Studio/Maker mode recovery.
The custom View menu still produces stale UI-tool element errors, so actual
menu recovery and visible unload remain unverified; automated native recovery
and unload checks pass. All four CI jobs pass at `a6dcd8c`. Three isolated seven-character runs
with 141 draw items pass six loaded-event checks with unchanged resources.
Hide/show median synchronous event costs span 0.409–0.440 ms, with a 0.610 ms
maximum; this excludes deferred layout, display and GPU completion. The initial
wrong-fixture launch failed before the scenario and remains separately retained. No per-frame callback was
added; the native panel mapping does not establish general Unity Canvas, input
or Harmony compatibility. Private evidence is retained under
`wave-three/plugins/hide-studio-ui/`; the visible menu and unload checks remain open.

**Local acceptance — normal head selection, [#187](https://github.com/grabbiel/ikkoku/pull/187):**
Character Maker can prepare normal heads 0, 200 and 201 on the shared selection
queue and atomically replace the card identity, geometry and shape/expression
contracts while preserving current edits. Exact candidate texture ownership
keeps failed loads from publishing partial cache entries. The checkpoint passes
26 focused Engine/Metal checks, female and male 55-check selection plus seven-check
fresh reload scenarios, and six existing Maker scenarios without skips. An initial
female/male export-path collision is retained in the evidence history; the female
pair passes again with distinct retained outputs. Root verifies the actual female
0→200→201→0 picker sequence, success status and dressed viewport. Two isolated
interleaved rounds pass eight further selection/reload checks. Measured owner
commit cost remains 109–155 ms; no-op calls take 0.285–0.396 ms and warmed resource
counts stay fixed. Appearance reads/uploads still run on the owner, so UI-owner
latency remains a performance task. This is neither full original Maker preset
behavior nor source appearance parity.
The [transaction contract](../reference/character/maker-assets.md#normal-head-selection-182)
records the exact scope, resource counts and remaining limits.

**Local acceptance — inner-shoe composition, [#183](https://github.com/grabbiel/ikkoku/pull/183):**
The normal inner-shoe slot 7 now has an independently captured GPU composite
recipe. Seven strict GPU checks pass, live material coverage rises from 17 to 18
of 20 slots, and three default-off app image pairs remain byte-identical. The
additional work raises median run-p50 GPU time from 0.617 to 0.662 ms and allocated
Metal bytes by 8,814,592 in the measured fixture; no speedup is claimed. All ten
native target mip levels remain deterministic under repeated draws and fresh
owners. Separate shoe-local translated-draw variation also occurs in the
pre-change executable, but current and historical magnitudes differ; whole-frame
repeat equality and source-color parity remain open. Final combined source-probe
compilation passes without launching a player or relabeling captured evidence.
The [renderer evidence](../reference/renderer.md#native-normal-inner-shoe-composite-r1cmt-04-177-2026-10-24)
retains the costs, source gates and diagnostic limits; sampling repeatability is
the owner's next bounded task.

**Local acceptance — corrected male head00, [#191](https://github.com/grabbiel/ikkoku/pull/191):**
The Models handoff adds an independent source gate for normal male/head00 with
bone type 1. Three original-player captures pass the unchanged geometry,
matrix, morph, correction-table and head-collider tolerances; 61 focused Python
checks and all earlier retained comparisons pass. Root independently verifies
all 33 indexed evidence descriptors against their retained hashes and sizes.
The neutral repeat preserves all 817 transform records and saved card bytes;
maximum native/source vertex error is 8.35e-7. This changes offline capture and
validation only, with no native runtime or per-frame cost. CPU silhouette equality
does not establish GPU color parity, other corrected heads, arbitrary shape
combinations or animation. The
[corrected male evidence](../reference/character/neutral-model-parity.md#corrected-male-head00-skeleton-189)
retains the exact identity, source routing and remaining limits. The owner moves
next to measuring and reducing normal-head selection's owner-thread commit cost.

**Local acceptance — accessory labels, [#193](https://github.com/grabbiel/ikkoku/pull/193):**
The Plugins handoff adds 34 passing app checks for the existing exact-revision
accessory-name adapter, plus 83 runner checks and two strict oracle checks.
Root verifies the actual Clothes inspector changes slot 1 from `スロット01` to
`01 スクエア` after mounting, retains that name while hidden and after an outfit
change, and restores the label, selected outfit and hidden state through an
actual save and fresh-process open. Unavailable rows remain noninteractive
fallback text. The fixture uses the same glasses in every outfit; distinct-name
outfit coverage is not established. Missing-conversion fallback and unload pass
automated checks, but GUI inspection finds that a directly loaded converted
manifest has no mounted-session or Unload controls in the library panel. That
UI gap is queued separately after legacy Studio command ownership. Label
construction diagnostics are below 0.1 ms, without isolated timing; no cache,
runtime labeling change or per-frame work was added. The original fixture
expectation and summary-parser failures remain retained alongside corrected
passes. See the [adapter acceptance](../reference/mods/native-adapters.md).

**Diagnostic handoff — translated sampling, [#188](https://github.com/grabbiel/ikkoku/issues/188):**
The Materials owner completed controlled sampler, primitive-ID and simultaneous
color/float-output experiments. All ten composite mip levels remain stable.
In the instrumented draw, visible UVs and all 2,948 primitive/pass IDs stay equal,
while first-texture-sample derivatives and returned values vary across repeats.
This narrows the observed gap without identifying a compiler/driver cause;
extra shader outputs can perturb execution, and later texture samples remain
outside that measurement. The [renderer investigation](../reference/renderer.md#translated-sampling-repeatability-investigation-188)
records the primary-source semantics, immutable private artifacts and numerical
limits. No production sampling, source tolerance or per-frame work changed,
and no speedup or source-color parity is claimed. The owner proceeds to an
asset-free small-triangle reproducer; the repeatability issue remains open.

**Local acceptance — Studio command ownership, [#196](https://github.com/grabbiel/ikkoku/pull/196):**
Interactive translated-profile load and Run/Pause now require active Studio and
no pending replacement. The load dialog retains its original mount generation,
so a stale completion cannot claim a newer session. All 34 app checks pass,
including inactive, pending and stale-generation rejection with unchanged
session, clock, document, resources and sampled frame state. Root verifies the
actual Mods menu disables these commands in Maker, restores them in Studio,
retains pause through the mode round trip, toggles Run/Pause, and loads the
retained translated profile through its real file dialog. The owned GUI process
exits normally. These are event-only guards with no new frame work or throughput
claim; programmatic startup loading keeps its existing behavior. Stale-dialog
concurrency is automated-method evidence, not interactive modal evidence.
The owner moves next to mounted-session summaries and Unload access for direct
native and translated-profile origins in the existing library panel.

**Diagnostic handoff — standalone sampling control, [#197](https://github.com/grabbiel/ikkoku/pull/197):**
The Materials owner completed an asset-free Metal tool with authored mip levels,
a large continuous quad, and identical tiny-triangle grids with continuous or
discontinuous UVs. Four held draws per case are bit-identical across color,
UV, derivatives, returned samples and primitive IDs; every case covers 4,096
pixels with finite values and zero affine-gradient error. The continuous cases
also produce identical color images, while the discontinuous case differs.
CPU literal/layout checks pass and root independently verifies all 60 retained
artifact hashes. The measured executable is `8aaf5ab9…8255` on M2 Ultra,
macOS 27.0.1, default MSL 4.1 and fast math disabled. These regular-grid controls
do not reproduce the recovered-shader variation and establish no production
fix, source parity or timing improvement. [The renderer reference](../reference/renderer.md#translated-sampling-repeatability-investigation-188)
retains the numerical scope; #188 remains open. The next bounded experiment
changes subpixel placement and edge direction while retaining these controls.

**Local acceptance — mounted plugin sessions, [#198](https://github.com/grabbiel/ikkoku/pull/198):**
The library panel now identifies resident native plugins and translated profiles
alongside library-mounted generations, with guarded Run/Pause and Unload access.
All 42 plugin checks, 18 native-save checks, nine fresh-process checks and 84
runner checks pass. Initial empty-profile and scenario-mode expectation failures
remain retained; the corrected harness preserves the loader's empty-profile
rejection and activates ordinary Studio scenarios through the real app mode.
Root verifies the actual panel for all three origins, Maker-disabled commands,
Switch to Studio, profile Pause/Run, and Unload. After native unload, outfit 2
and slot 1's hidden state remain selected while its label returns to the fallback.
The accepted executable is `1c516693…fc9` from runtime `71e1309`; its GUI process
exits normally. Presentation reads resident metadata without file I/O or new
frame work. Mixed-origin and concurrent pending/stale-dialog GUI cases remain
outside this acceptance, and these overlapping functional runs support no
timing claim. The [adapter reference](../reference/mods/native-adapters.md)
retains exact fixtures and limits. The owner next investigates fresh-profile
initialization failure isolation, beginning with a reproduction before changing
supported callback behavior.

**Diagnostic handoff — subpixel sampling controls, [#199](https://github.com/grabbiel/ikkoku/pull/199):**
The standalone tool adds a translated discontinuous grid and a sheared copy,
retaining its original three meshes, shader and eight authored mip levels.
All five cases remain bit-identical over four draws across color, UV,
derivatives, returned samples and primitive IDs. CPU triangle-union coverage
matches all 4,096 visible pixels per case; values are finite and affine-gradient
error is zero. Root verifies all 99 retained artifact hashes and byte equality
of the earlier control's 60 artifacts. The measured executable is
`66d8dbd6…45a2`; the retained report is `bfd362c1…f232`. These placement and edge
direction controls still do not reproduce #188, establish a production fix or
support a performance or source-parity claim. The
[renderer investigation](../reference/renderer.md#translated-sampling-repeatability-investigation-188)
retains the exact mesh and coverage bounds. The owner next compares constant
and varying clip-space w while preserving projected geometry and the controls.

**Local acceptance — prepared head appearance inputs, [#200](https://github.com/grabbiel/ikkoku/pull/200):**
Selected RGBA reads and hashes now run in the bounded preparation job, with
immutable inputs checked against the exact base/component context and a 128 MiB
aggregate candidate cap. Latest owner colors still drive composition; missing
prepared inputs reject without owner-side file fallback. All 33 focused Engine
checks pass across the initial 32-pass run and one fixture-configured rerun;
the initial missing-environment failure is retained. Both sexes pass 55 selection
and seven fresh-reload checks. Eight quiet interleaved launches preserve exported
card bytes and GPU resource counts; root verifies both binaries and all 24
retained artifacts. Mean owner commit falls by 19.672–32.976 ms, while total API
latency rises by 4.582–30.054 ms. The candidate retains 32,506,112 raw input bytes
until completion. This is a responsiveness tradeoff, with 90–144 ms owner stalls
still present, rather than a total speedup, peak-memory or FPS result. The
[Maker reference](../reference/character/maker-assets.md#normal-head-selection-182)
records the two-sample-per-sex/binary limits and remaining synchronous GPU wait.
All four CI checks pass at `4aab6c78`; #200 is merged. #192 remains open for
the remaining stalls; the final integration build is separate from the measured pair.
The owner proceeds to measuring and reusing immutable fallback textures within
each compositor, preserving its completion and failure semantics.

**Diagnostic handoff — perspective sampling controls, [#201](https://github.com/grabbiel/ikkoku/pull/201):**
The standalone tool adds constant-per-triangle and varying-per-vertex clip-space
w while retaining projected geometry, depth, ordered UVs, shader and mip inputs.
All seven cases remain bit-identical over four draws across the measured outputs.
An independent reciprocal-w UV reference differs by at most 1.4997892061607843e-7
in the varying case; its affine-gradient comparison is explicitly absent because
no hardware quad-derivative rule was established. Root verifies all 135 artifact
hashes and byte equality of the previous 99 control artifacts. These finite,
coverage-matched results still do not reproduce #188 or establish source parity,
a production fix or a performance improvement. The
[renderer investigation](../reference/renderer.md#translated-sampling-repeatability-investigation-188)
retains the exact numerical scope. The owner moves next to a reduction of the
recovered shader while preserving the existing varying-output baseline.

**Reproduced gap — profile initialization rollback, [#203](https://github.com/grabbiel/ikkoku/issues/203):**
A source-backed fresh-profile initializer reads a hidden character's attachment
before a later named Int32 error rejects installation. The failed candidate
leaves one new preview cached: meshes rise 37→66, textures 64→82 and mesh-buffer
bytes rise by 12,505,092. The document, prior session, fields/clocks, adapters,
status, generation, observers and sampled frame remain unchanged. Thirteen of
14 reproduction checks pass; the sole failure is the intended cold-preview
rollback assertion. Successful hidden-initializer and first-step Start controls
pass, as does a cached active-parent Awake failure's resource/identity check.
Start is first-step work, not an installation callback. Runtime `cdfc29e` changes
only the scenario harness; the owned process exits 1 and its failure artifacts
are retained. This establishes a native ownership gap, not a source-parity or
performance result. The next task evaluates candidate staging or precise cleanup
while preserving successful attachment callbacks; no production fix is claimed.

**Diagnostic handoff — recovered shader prefix, [#204](https://github.com/grabbiel/ikkoku/pull/204):**
A fresh full-shader control and a reduction retaining the original vertex path
and exact fragment prefix through alpha discard both reproduce derivative/sample
variation with store and captured texture providers. Later shading is therefore
not required for this particular reduced draw; shader compilation perturbation
remains a limit. Sixteen draws retain equal UVs, primitive/pass IDs, coverage and
alpha, with finite outputs. Reduced color is deliberately the first texture
sample and is not a full-color equivalence gate. Root verifies all 64 attachment
hashes, reconstructing the zero-cleared full float buffers from retained ROIs;
the report retains equal before/after hashes for 148 mip instances, 20 matching
provider/property chains and ten matching constant-buffer pairs. The harness
records MSL 4.0 (`262144`), separately from the standalone controls' MSL 4.1;
the earlier separate options query did not prove runtime compiler equivalence.
No production shader, tolerance or performance claim changes. The
[renderer investigation](../reference/renderer.md#translated-sampling-repeatability-investigation-188)
retains the exact scope. Next, the owner isolates the independent MainTex sample
on the same geometry, reporting any coverage changes from removing alpha discard.

**Local acceptance — fresh-profile preview isolation, [#206](https://github.com/grabbiel/ikkoku/pull/206):**
The #203 fix stages cold attachment previews and newly loaded appearance inputs
until initialization and saved-state validation succeed. A lazy checkpoint
restores a touched warm preview's exact state on rejection; supported initializer
and first-step Start reads remain available. At runtime `b6740b0`, six focused
Engine checks, 32 isolation checks and the existing 42 plugin checks pass without
skips. Cold rejection now preserves the complete active-resource vector and
leaves no cached preview. Repeated failure after mesh/appearance construction
reaches the named invalid-animation-catalog error and also releases its resources.
Warm shape/clock restoration, later continuation and successful preview reuse
pass. Root verifies all seven retained report/log hashes and the accepted
`b9e0a6f2…c0f4` executable; the earlier 13/14 failure and binary remain retained.
These are functional checks, not timing or GUI measurements. Resource generation
and handle counters do not rewind; the malformed-neck alias branch is reviewed
but not independently exercised. The pruning control directly uses the production
preparation context, without claiming an installation-time Destroy barrier.
Library installation and legacy restore retain their prior attachment policy.
The [execution reference](../reference/mods/plugin-execution.md) records the
scope. All four CI checks pass at `e73f121`; #206 is merged. The next bounded
task reproduces the existing legacy-profile reopen limitation before choosing a fix.

**Local acceptance — compositor fallback reuse, [#207](https://github.com/grabbiel/ikkoku/pull/207):**
Each compositor now lazily reuses immutable white/zero input textures. The
measured selection uses eight fallback allocations for 316 absent bindings,
plus 20 real input allocations across 16 recipes: 308 fewer fallback allocations
than the old loop. These transient inputs are separate from registered
ResourceStore counts. Eight focused checks pass; both sexes pass 55 selection
and seven fresh-reload checks. Eight quiet interleaved processes pass with all
four exports per sex byte-identical across binaries. Root verifies both binaries,
all 24 retained artifacts and the 48 stage records. Runtime `4e7b46c` is measured
against control `8b799157`; the later integration head retains separate provenance.
Timing directions are mixed, so no consistent latency improvement is established.
Candidate child intervals attribute 7.426–8.563 ms to allocation/upload,
0.182–0.282 ms to encode/submit and 51.152–55.855 ms to wait/view in the selected
head-201 cases. The last interval includes scheduling/completion/view creation,
not pure kernel time. Registered resources and 32,506,112 retained raw-input
bytes match the control. All four CI checks pass at `45f355f`; #207 is merged.
The [Maker reference](../reference/character/maker-assets.md)
retains exact cases and limits. The next task evaluates bounded batching within
one applying call while preserving synchronous completion and private failure
cleanup; no batching improvement is claimed here.

**Merged acceptance — bounded composition batches, [#213](https://github.com/grabbiel/ikkoku/pull/213):**
The Metal path prepares private inputs/outputs, encodes all recipes and completes
once per non-empty applying call, then registers the validated texture views and
replays material entries in source order. A separate 128 MiB logical input-pixel
limit counts repeated real uploads and each allocated fallback before allocation;
it leaves the existing output/raw-input caps intact. Larger repeated-input cases
now fail explicitly. CPU behavior and nil-diagnostic callers remain supported.
Eleven focused tests pass without skips, including independent material pixels,
late-failure atomicity, exact budget boundaries, ordering and shared leases.
Four app processes pass both sexes' 55 selection and seven reload checks in
42.257 seconds, with four byte-identical prior exports.

The quiet comparison uses fresh parent `45f355f` and candidate `825e631` binaries
whose 557-file source manifests differ only in the four scoped files. All eight
processes pass in 60.109 seconds; root verifies both binaries, 24 artifacts,
48 stage records and four identical exports per sex. The selected head-201 cases
retain 16 dispatches, 20 real uploads, eight fallback allocations and 316 absent
bindings, while completions fall from 16 to six. Registered resources and
32,506,112 retained raw-input bytes match. With two samples per sex/state/binary,
API means improve by 7.769–10.595 ms, but male-warm owner time increases by
1.638 ms; this does not establish a general latency, FPS or peak-memory benefit.
The [Maker reference](../reference/character/maker-assets.md#bounded-synchronous-composition-batches-208)
records full timing ranges, transient retention limits and the preserved offline
analysis corrections. The remaining responsiveness work stays in #192.

**Diagnostic handoff — MainTex-only sampling, [#209](https://github.com/grabbiel/ikkoku/pull/209):**
Merged after all four CI checks pass at `0bcd33c`. Removing the AlphaMask/combine
and predicate/discard blocks together makes the
retained MainTex-only program repeat exactly, while the fresh prefix control
still varies with both providers. All 16 draws keep the same 2,948 visible pixels,
primitive/pass identities, alpha and UVs. Root verifies all 64 complete attachment
hashes, exact MainTex-only repeated outputs and the recorded unchanged mip inputs.
The actual pipelines retain MSL 4.0 with fast math and preserve-invariance disabled.
An initial launch rejected a private card symlink before drawing; its failure is
retained, and the same binary succeeds with byte-identical regular card copies.
The [renderer investigation](../reference/renderer.md#translated-sampling-repeatability-investigation-188)
records the two-block scope, full-plane/common-mask checks and compiler-perturbation
limit. This neither identifies the responsible operation nor authorizes removing
production alpha testing. The next diagnostic keeps mask/predicate work observable
and removes only discard, requiring a fresh varying baseline before interpretation.

**Diagnostic handoff — observed discard-only sampling, [#188](https://github.com/grabbiel/ikkoku/issues/188):**
Both private variants retain the same mask/comparison work and record its combined
mask and original predicate bits. They differ by one discard statement. The fresh
observed-prefix control varies with both texture providers; no-discard repeats
all five attachments exactly. All 16 draws retain 2,948 visible pixels, matching
primitive/pass IDs, alpha and UVs. Root independently decodes and verifies all
80 attachment hashes and unchanged inputs. Visible mask values remain 1 and
predicates 0; this does not observe helper invocations. Actual MSL 4.0 pipelines
accept the five-attachment, 60-byte logical color payload with fast math and
preserve-invariance disabled. The [renderer reference](../reference/renderer.md#translated-sampling-repeatability-investigation-188)
records counts, parser checks and the restored private harness. The result narrows
the compiled-program association, without identifying a compiler/driver defect
or changing production shaders, coverage, source tolerances or performance claims.
The next bounded comparison keeps the source alpha test and changes only the
explicit language version; #188 remains open.

**Reproduced limitation — saved attachment profiles, [#210](https://github.com/grabbiel/ikkoku/issues/210):**
A supported hidden attachment initializer loads fresh and saves successfully,
but native reopen rejects it under the existing installation-read policy.
The local regression-only checkpoint `6f999ea` passes ten save checks and ten
reopen checks in distinct processes. Rejection preserves the prior scene,
session, fields/clocks, adapters, undo/redo history, frame, preview identities
and complete active-resource vector. A valid-JSON changed-profile control still
rejects by identity; an attachment-free control restores and advances its next
step. Root runs both processes against the frozen `7654f79b…1d6e` Release binary
and retains seven hashed report/log/build records. This is a documented-policy
gap, not a #206 regression, source parity or GUI acceptance. The scenario remains
on the local `codex/plugin-profile-native-restore` branch for the bounded fix;
it is not merged restore support. Candidate previews must use the new scene's
references and resource policy, including when old and new UUIDs coincide.

**Local acceptance — candidate-owned saved-profile restore, [#210](https://github.com/grabbiel/ikkoku/issues/210):**
Native open and undo/redo prepare cold attachment previews from the target scene's
resolved references, outfit, shapes and resource policy, including matching old/new
UUIDs. Native open uses animation time zero; history uses its held clock. All
fallible preparation finishes before history, adapters or cache state changes.
Successful candidates transfer matching previews before document refresh; failure
releases only candidate-owned resources. Newly permitted attachment-reading
initialization rejects scene mutations, cloning and pending destruction, preserving
the existing input-scene commit semantics.

The frozen `af6007a` Release binary passes all 117 checks in four processes:
ten saves, 33 fresh reopen/ownership/history checks, 32 existing fresh-profile
isolation checks and 42 library/command checks. Root verifies all four reports.
Six repeated mutation cases reach the exact policy error and retain the old
document, session, history, previews, resources and frame. The original policy
reproduction stays retained separately. The [plugin reference](../reference/mods/plugin-execution.md#saved-scenes-and-migration)
records exact scope, hashes and integration requirements. This does not establish
GUI acceptance, general plugin compatibility, source parity or a timing benefit.

**Completed before this wave:** ST-T02/A-T04 passed local acceptance at PR #2
(head `93e6b06`, merge `aa4bcb9`). Both configurations retained identities and
identical reload frames; enabled tone gain muted/restored. See
[recorded acceptance](../reference/mods/native-adapters.md#verified-release-acceptance).
On 2026-10-23 the enabled configuration regressed on macOS 27 and was fixed and
reverified headlessly (`native-adapter-capture-04`; see
[Local rerun on macOS 27](../reference/mods/native-adapters.md#local-rerun-on-macos-27-2026-10-23)).

**Merged 2026-09-28 (PRs #3–#39):** first slices of orders 1–3 and a large part of
order 4 (Studio source animation selection, hand patterns, blink, neck look-at,
routes). Every slice records its own evidence in the linked reports. The merged
`main` passes the Engine suite (458 tests), the app `xcodebuild` Debug build and the
`Tools/reverse` and `Tools/reverse/analysis` unittests. That evidence is
kernel-, capture- and build-level: **the merged wave has not been exercised
interactively in the running app yet.** Before these features count as verified
through the app, run this checklist against an original Studio scene (for
example `koikatu_cs0002591.png`) with the converted-asset environment variables
set.

**Merged 2026-09-28 – 2026-10-01 (PRs #40–#84):** source camera objects and the
Studio scale rule; eye look and iris texture transforms (verified against the
original to 5e-7); source props from the converted item catalog with record
colors; card shape and color edits; original-scene export of visibility, names,
camera/route active flags and card edits; undo/redo and native save/reload that
keep a source scene's props, cameras, routes and light. Two app-level lanes now
exercise much of the checklist below **headlessly**, through `StudioModel` /
`MakerModel` calls and, for the FK guide, the real mouse handlers and GPU pick:
`Tools/verification/lanes/studio-scenarios.json` (39 checks) and
`maker-scenarios.json` (4 checks); run them with
`python3 Tools/verification/run.py --manifest <lane> --environment
.local/verification/environment.json --strict`. GitHub Actions (PR #70) runs only
the public lane, an unsigned Debug build and the `Tools/reverse` Python suites. Scenario-lane evidence is not
interactive UI acceptance: items stay unticked unless every claim they make has
passed, and ticked items say how they were checked. The ST-T03 items are ticked
because the exported scenes were also reloaded in the real CharaStudio (PRs #78,
#80, #81).

**Merged 2026-10-23 (PRs #104–#110, #112, #114–#116, #118–#122):** a CI-verified wave of synthetic-fixture
slices, written without a local Swift toolchain. The macOS Actions jobs were each
PR's first compile and its only Swift test run: Engine `swift test`, the unsigned
Debug app build, the `Tools/reverse` suites and, since #120, a Release bundle
inspection. Each slice's report row names its evidence.
- R5 ([#104](https://github.com/grabbiel/ikkoku/pull/104), [#108](https://github.com/grabbiel/ikkoku/pull/108)):
  secondary glTF UV sets and load diagnostics; unsupported required extensions are
  rejected; packaged glTF loads are confined to their verified package root.
- G-T01 ([#105](https://github.com/grabbiel/ikkoku/pull/105)): engine
  `SourceGameplaySession` with classified, acknowledged completion barriers and a
  deterministic mid-barrier reload. A-T01's first slice
  ([#121](https://github.com/grabbiel/ikkoku/pull/121)) adds the native
  `SourceGameplayHost` that consumes it and a headless app mode
  (`IKKOKU_GAMEPLAY_SCENARIO`); the app run is pending.
- R4 ([#106](https://github.com/grabbiel/ikkoku/pull/106), [#110](https://github.com/grabbiel/ikkoku/pull/110)):
  degenerate math, legacy skeletons, cameras, IK, gaze, rays, poses and mirrored
  camera-object parents now produce named errors.
- P-T04 ([#107](https://github.com/grabbiel/ikkoku/pull/107)): seeded IR and
  manifest fuzzing, budget, lifecycle and host-failure rollback tests. It fixed an
  `attach` partial-commit defect.
- A-T05 ([#109](https://github.com/grabbiel/ikkoku/pull/109)): every capture output
  is verified after writing, and UI capture waits for readiness.
- P-T02 ([#112](https://github.com/grabbiel/ikkoku/pull/112)): an immutable plugin
  library with generations and one IR/native-adapter dependency graph; saved
  selections never remap.
- E-T02 ([#114](https://github.com/grabbiel/ikkoku/pull/114)): contract generators
  that read recovered C# resolve it through `recovered_source.py`, which uses the
  indexed project and clean per-type fallbacks and refuses the rest by name.
  Generators that still read older narrow trees wait on a private rerun.
- R4 ([#115](https://github.com/grabbiel/ikkoku/pull/115)): legacy two-bone IK no
  longer applies the upper-bone delta twice to the lower bone. Synthetic tests now
  assert that reachable targets are reached.
- T-T01 ([#116](https://github.com/grabbiel/ikkoku/pull/116)): prerequisite versions
  are recorded once in `Tools/verification/prerequisites.json`. `doctor.py` checks
  them, and CI runs it with `--require public`. Unrecorded tools are only checked
  for presence.
- A06 ([#118](https://github.com/grabbiel/ikkoku/pull/118)): startup validates the
  whole `IKKOKU_*` capture request before any work. Conflicting modes, options that
  no requested mode reads, and ignored values exit 1, naming every offending
  variable. In an automated run, a capture input that fails exits 1 naming its
  variable, instead of capturing other content.
- R6 ([#119](https://github.com/grabbiel/ikkoku/pull/119)): the uniform ring spills
  into overflow buffers instead of terminating, and never reuses a region still in
  flight. A failed frame encodes nothing and reports `Renderer.lastFrameError`. More
  than 64 active morph targets accumulate instead of being truncated, and lights
  beyond 8 are counted.
- T-T02 ([#120](https://github.com/grabbiel/ikkoku/pull/120)): CI builds the Release
  app and inspects the bundle against reviewed rules. The first run found the whole
  Engine package (sources, tests, fixtures) copied into every app build; that is
  fixed. `IKKOKU_SOURCE_TREE_FALLBACKS=0` turns off the checkout-relative defaults.
- A-T02 ([#122](https://github.com/grabbiel/ikkoku/pull/122)): saved scenes record
  each referenced file's SHA-256 and library-relative path. On open, references
  relocate into a user-selected converted library when the identity matches.
  Missing, changed and escaping files are reported and their objects are not
  loaded. Automated runs ignore the saved selection.

None of this wave has been run in the app; the seven app items below are still open.
The local-environment work they need (these app checks, the private lanes and
reruns, and branch cleanup) is handed off in
[HANDOFF-2026-10-23-local-environment.md](../../HANDOFF-2026-10-23-local-environment.md).

- [ ] ST-T01: select a source character; the Pose, Face and Clothes tabs are reachable,
      FK/IK guide edits move bones, and prototype-only controls stay blocked (PR #5)
      (automated in part: `scenarios/fk-edit.json` — an FK bone rotation on character
      key 65 holds its exact degrees and moves the left-hand guide, and the pose
      survives export → reimport; passed 2026-09-30; also `scenarios/fk-mouse-drag.json`
      — mouse-driven FK guide drag automated through the real input handlers and GPU
      pick (headless; no physical mouse or window): the z rotate ring is grabbed and
      dragged 60,40 px, holds a non-zero FK rotation, moves the hand, pushes exactly
      one undo snapshot and survives export → reimport; passed 2026-09-30).
      `scenarios/charastudio-fk-edit.json` — the same FK edit reloaded in the
      original CharaStudio player: an export of the edit loaded beside the
      unedited source scene shows the saved bone rotation `[0,35,0]` and the
      hand 0.288 m from its unedited position; passed `--strict` 2026-10-01
      (capture `.local/stt01c/`; that player copy needs the probe's
      empty-voice-table repair to load any character scene).
- [ ] ST-T10: the animation selection inspector changes the playing clip and speed, and
      original export keeps the new catalog IDs (PRs #12, #16, #17)
      (automated in part: `scenarios/animation-select.json` — selecting catalog clip
      [0,2,0] at speed 1.5 with forceLoop on reads back live and after export →
      reimport; passed 2026-09-30).
- [ ] ST-C04: source Face Expression controls edit through the shared model and restore
      through undo/redo/reset/native reload; check the visible controls and diagnostics.
      Headless scenarios: `expression-edit`, `reload-save-expression`,
      `reload-load-expression`; see [bounded contract](../reference/studio/scene-editing.md#source-face-state-editing-st-c04).
- [ ] ST-T07 hands and blink: saved hand patterns replay on both hands; cards with
      `eyesBlink` blink automatically and the Studio toggle stops it (PRs #18–#23).
      (automated in part: `scenarios/blink-toggle.json` — a live 7 s advance renders a
      blink closing, `setAutomaticBlink` off holds the eyes open for the next 7 s and
      back on blinks again; `scenarios/hand-patterns.json` — the saved [5, 6] pair
      replays converted looping clips and a finger bone moves off its frame-0 position
      within the loop, `scenarios/hand-patterns-kept.json` — without a library the pair
      is reported and never guessed; both round-trip export → reimport; the drawn
      blink timing itself is random per window, so the assert is "a closing rendered
      in 7 s", not a schedule; passed 2026-09-30).
- [ ] ST-T07 neck look: with `IKKOKU_STUDIO_LOOK_SETTINGS` set, FIX/FORWARD characters
      hold their saved neck/head, TARGET/AWAY characters follow or avoid the Studio
      camera as it orbits, and FK-neck characters are untouched (PRs #26–#38).
      (automated in part: `scenarios/neck-look-orbit.json` — character 65's FIX override
      ("FIX holds the saved neck rotation.") holds head and neck bone positions exactly
      still across orbiting the camera to both sides, and the state survives export →
      reimport; passed 2026-09-30; `scenarios/neck-target-orbit.json` — on
      `scene-neck-target.png`, which the original CharaStudio authored from the synthetic
      fixture card (key 0 neck TARGET, key 147 neck AWAY, both eyes TARGET), the live
      TARGET/AWAY diagnostics are asserted and each character's hair-front bone 100 is
      captured under the saved camera. TARGET's bone moves more than 0.05 m when the camera
      orbits +60° and 0.1 m when it orbits back to −60°. AWAY's bone moves more than 0.15 m
      from each earlier pose and returns within 0.01 m of its front pose at −60°. At both
      orbit sides, AWAY's bone sits more than 0.15 m from TARGET's in the rig frame. After
      export → reimport, with the view still at −60°, both bones hold within 0.01 m of
      their pre-export poses. Under the saved camera, the
      bearings are TARGET 6.698° and AWAY 59.879°; the original's settled head yaws are
      6.699° and 59.862°. TARGET turns toward the camera's side and AWAY to the opposite
      side, as in the original
      ([fixture scenes](../reference/studio/scene-editing.md#charastudio-authored-route-children-and-neck-targetaway-fixtures)).
      The FK-untouched half, rendered pixels and orbit-phase magnitudes stay unchecked;
      passed 2026-10-22).
- [ ] ST-T07 eye look: with `IKKOKU_STUDIO_LOOK_SETTINGS` set, select a source character
      with eyes pattern こっち; orbit the camera: the Eye look readout's H rates change
      sign across the face, raising the camera moves the V rate, and no eye bone moves
      yet.
      (automated in part: `scenarios/eye-look-orbit.json` — character 65's TARGET solver
      reads (+1, +1) one side of the face and (-1, -1) the other (the rate lines are
      saturated at ±1), raising/lowering the camera moves the V rate past ±0.5, and the
      head and neck bone positions stay exactly still (this contract has no eye bones,
      so "no eye bone moves" is proven as "no skeleton bone moves"); passed 2026-09-30).
- [ ] ST-T07 iris rendering: with `IKKOKU_STUDIO_LOOK_SETTINGS` set, orbit around a source
      character with eyes pattern こっち: the irises follow the camera (their textures
      shift with the look rates; eyes without the live pattern keep the resting offset
      the prefab snapshot gives). No eye bone rotates and no original-pixel comparison
      exists.
      (automated in part: `scenarios/eye-look-orbit.json` asserts the look rates the
      iris textures are shifted by — they flip sign across the face and the V rate
      moves — but no rendered iris pixel is compared; the pixel half stays
      unautomated; passed 2026-09-30).
- [x] ST-T03 visibility: hide a source object, export the original scene, reload it: the
      object is hidden; reloading in CharaStudio shows it hidden. (automated headlessly: the edits go
      through the Studio scenario runner's `StudioModel` calls, not the mouse-driven inspector;
      `Tools/verification/scenarios/visibility-folder.json` covers hide → export →
      reimport in our app (passed 2026-09-29); CharaStudio reload checked 2026-09-30:
      `scenarios/charastudio-hide-rename.json` exports the hidden folder and
      `Tools/reverse/original_scene_reload_probe.py` loads that exact PNG into the
      original player, where folder key 1 reads back `objectInfo.visible=false` and
      `treeNodeObject.visible=false` (`Tools/reverse/compare_scene_reload.py` passed;
      the hidden folder's camera child keeps its own saved `visible=true` flags, which
      matches our own-flag-only writer; recorded in
      [scene-editing](../reference/studio/scene-editing.md#charastudio-reload-acceptance);
      on the synthetic scene-x, not `koikatu_cs0002591.png`; passed 2026-09-30)
- [x] ST-T03 rename: rename a source folder, camera or route, export the original scene,
      reload it: the new name shows; renaming a character (whose name lives in its card)
      stays rejected at the inspector export. (automated headlessly: the edits go
      through the Studio scenario runner's `StudioModel` calls, not the mouse-driven inspector;
      `Tools/verification/scenarios/rename-folder.json` covers the folder rename → export →
      reimport and `Tools/verification/scenarios/camera-rename.json` the camera rename →
      export → reimport on scene-x; `Tools/verification/scenarios/charastudio-route-rename.json`
      covers the route rename → export → reimport on the stt11c route scene — after the
      reimport our importer keeps the route playing and shows the renamed record name
      (a route imports unrendered but under its saved name), so the rename reads back in
      our own document as well as in the exported bytes and the original player's readback
      below; the character-rename rejection is an Engine-suite unit test; passed 2026-09-29.
      CharaStudio reload checked 2026-09-30 for the folder and camera kinds: the same
      exported `charastudio-hide-rename.png` reads back camera key 0 as `IKKOKU-A2`
      and folder key 1 as `IKKOKU-F2` in the original player
      (`Tools/reverse/compare_scene_reload.py` passed;
      [scene-editing](../reference/studio/scene-editing.md#charastudio-reload-acceptance)),
      and 2026-09-30 for the route kind: the exported `charastudio-route-rename.png`
      reads back route key 3 as `IKKOKU-R3` while route key 0 keeps its saved `IKKOKU-A`
      (second one-run capture; `Tools/reverse/compare_scene_reload.py` passed all four
      cases; our reimport side of the same scenario passed `--strict` in the
      `studio-scenarios` lane; passed 2026-09-30). Closed on our side 2026-09-30:
      the importer now names a route record by its saved CharaStudio name (only an
      unnamed route record falls back to the `Unrendered source <kind> <key>`
      placeholder; every other unresolved kind keeps it and the route stays
      unrendered), and both export baselines measure a route against
      `original.name ?? "Source object <key>"` like a folder — an untouched route
      writes no name edit, a renamed one exactly one, and an old document that
      saved the placeholder as its `sourcePreviewName` still writes nothing
      (the preview wins over the fallback). The scenario's post-reimport assert
      now reads `name: "IKKOKU-R3"`, so the new name shows in our app too,
      pinned by the Engine tests
      `sourceSceneEditingRouteNameEditsWriteNothingUnchangedAndExactlyTheNewName`
      and `sourceSceneExportValidationBaselinesRoutesOnRecordNameAndKeepsLegacyPreviewsSafe`;
      the full `studio-scenarios` lane passed `--strict` after the change
      (passed=30 failed=0, 2026-09-30).
- [x] ST-T03 active flags: switch the source camera / stop a playing route, export the
      original scene, reload: the new camera is active and the route stays stopped.
      (automated headlessly: the edits go through the Studio scenario runner's
      `StudioModel` calls, not the mouse-driven inspector;
      `Tools/verification/scenarios/camera-load-winner.json` and
      `camera-deactivate.json` cover camera switch/deactivation → export → reimport on
      scene-x, and `Tools/verification/scenarios/route-play-state.json` covers stopping
      one route while another keeps its saved state on the stt11c route scene (passed
      2026-09-29); CharaStudio reload checked 2026-09-30:
      `scenarios/charastudio-camera-switch.json` and `charastudio-route-stop.json`
      export the edited scenes and `Tools/reverse/original_scene_reload_probe.py` loads
      those exact PNGs into the original player, where after the camera switch
      `studio.ociCamera` is camera key 0 (`cameraInfo.active=true`, key 2 reads back
      false — the same winner our importer picks) and after stopping route key 0 it
      reads back `isPlay=false` while route key 3 keeps `isPlay=true`
      (`Tools/reverse/compare_scene_reload.py` passed;
      [scene-editing](../reference/studio/scene-editing.md#charastudio-reload-acceptance);
      playing is read from the `active` flag, not from motion; passed 2026-09-30)
- [x] ST-T06 shape values: face/body edits change the production preview, export and
      reload retain the values, Reset to card restores the saved values, and editing
      back to saved rates exports byte-identical bytes. Verified headlessly through
      `StudioModel` and the production renderer on 2026-10-17: `face-shape.json`
      covers edited export/reimport; `shape-visual-reset.json` adds fixed-camera,
      fixed-clock 512x512 comparisons (face: 76 pixels, body: 40,270 / 38,581 pixels
      differ by >2/255), exact RGBA8 reset restoration, isolation of the opposite
      shape domain, and initial-source SHA checks before and after reimport. A
      changed export after reimport must fail that SHA check. The inspector and
      runner share `resetSourceShape`; mouse-driven slider/button acceptance remains
      separate from these headless checks.
- [x] ST-T06 colors: bound skin-color edits change the production preview, export and
      reload retain the rgba, Reset to card restores saved colors, and editing back
      to the saved rgba exports byte-identical bytes. Verified headlessly on
      2026-10-17: `color-edit.json` covers edited export/reimport;
      `color-visual-reset.json` measures 10,251 pixels differing by >2/255 at
      512x512, exact RGBA8 restoration, shape/color reset isolation, and restored
      export identity against the initial source SHA. Changed exports remain
      distinguishable after reimport. Hair color is outside this acceptance:
      `hair.parts.0.baseColor` binds no material on this fixture and export skips
      its writeback. Mouse-driven controls and original-player shader parity remain
      separate gates.
- [ ] ST-C03 outfit selection: the Clothes tab's Outfit picker switches a source
      character to another saved outfit, which renders, undoes and survives native
      save/reload. Export writes `Status.coordinateType`; selecting the saved outfit
      again exports byte-identical bytes. Unconverted parts are diagnosed and never
      substituted. (Automated in part, headlessly on 2026-10-17: `outfit-select.json`
      measures 19,155 pixels differing by >2/255 for outfit 3 at 512x512, exact undo,
      redo and return restoration, restored-export SHA identity before and after
      reimport and outfit read-back after reimport; `reload-save-outfit.json` and
      `reload-load-outfit.json` cover native save/load. The visible picker,
      CharaStudio reload of the changed export, clothes state and accessory
      visibility remain unchecked;
      [outfit selection](../reference/studio/scene-editing.md#source-outfit-selection-st-c03-first-slice).)
- [ ] ST-T11 routes: route children and route characters move along their routes, and the
      Play/Stop, Play all, Replay all and Stop all controls behave as documented (runtime
      only; the route's saved `active` byte is exported only when its play state deviates
      from the record) (PRs #19–#39).
      (automated in part: `scenarios/route-children-motion.json` — on
      `scene-route-children.png`, which the original CharaStudio authored (route key 0
      saved playing and looping over four points; children folder key 9 and the fixture
      female key 10), both children's world positions move 1.205 m in a 2 s advance. The
      positions are read through the placement walk `refresh()` renders with, and in the
      original the route's `childRoot` moved 1.032 m in 1.56 s. The folder moves another
      0.333 m in the next 0.5 s. Stopping the route pins both children back to point 0
      within 1e-5, and they hold there through 2 s and export → reimport. Play all /
      Replay all / Stop all, speed parity with the original tween and rendered pixels
      stay unchecked; passed 2026-10-22.)
- [ ] ST-A06 camera objects: loading a scene with an active camera object starts the view
      through it (reported in the source compatibility diagnostics); orbit/pan/zoom are
      refused with an explanation while it is active, and Look through / Stop looking
      through on a camera placeholder switches between the camera object and the saved
      scene camera (runtime only; export rewrites every camera's `active` byte only after
      a switch). (automated in part: `Tools/verification/scenarios/camera-load-winner.json`
      asserts the load winner is the last active camera in depth-first order on scene-x and
      that a switch survives export → reimport via the written flags, and
      `Tools/verification/scenarios/camera-deactivate.json` asserts deactivating the winner
      leaves the orbit view through export → reimport; the diagnostics line, the
      orbit/pan/zoom refusal messages and the Look through UI itself stay unautomated;
      passed 2026-09-29)
- [ ] ST-T04 source props: with `IKKOKU_STUDIO_ITEM_CATALOG` set, import
      koikatu_cs0002591: the 19 basic cubes render at their saved transforms and show
      their saved colors (all 19 record the same `color[0]`, a 0.875 grey at alpha 1)
      (diagnostics report `Items rendered from the converted catalog: 19; unmapped keys:
      none.`); the placeholders stay exportable and export still succeeds (runtime only).
      (automated in part: `Tools/verification/scenarios/item-props.json` asserts that
      diagnostics line at import and again after an export → reimport of all 19
      placeholders; the rendered transforms and saved colors — the visual half —
      are not asserted; passed 2026-09-29)
- [ ] CMT-04 and R1/R2: source draw-material overlays render in the live preview as in
      the matched captures (PRs #6–#13).
- [x] VM: compile the merged `Tools/reverse/fixtures/OriginalCharacterProbe.cs` once with
      settings, hand-pattern and look-pattern modes together (merged textually from three
      branches). (compiled and run in one capture 2026-09-30 — `.local/stt07y` settings,
      hands `L5`/`R9` and the `.local/stt07i` look patterns; every mode wrote its output
      with `status.json` error `null` and matched its single-mode reference: the
      `irisCard` header repeats the settings tsv verbatim, `compare_iris.py` replayed all
      450 look frames with a worst iris texture-transform difference of 0.000000444
      (tolerance 0.000001, same six phases as `.local/stt07y/run1`), and
      `compare_hand_patterns.py` passed at 0.000011° (tolerance 0.01°) with the same
      15+15 frame.json bone maxima as `.local/stt07f/r5-9` down to the last digit;
      `.local/vm-merged-probe`, see
      [material-expansion](../reference/character/material-expansion.md))
- [ ] A-T05 capture integrity (PR #109): on a Debug build, run the acceptance
      commands in [build and test](../guides/build-and-test.md). The checks: an
      unwritable or directory `IKKOKU_CAPTURE_UI` path and a tiny
      `IKKOKU_CAPTURE_UI_TIMEOUT` exit 1 without a "written" line; a normal UI capture
      and `IKKOKU_RENDER_THUMBS` exit 0; and the `app-smoke` lane passes.
      (2026-10-23, local-wave-verify, Debug build of `2e732b9`, main `5e86b57`
      merged. Every command behaved as listed: the three bad captures exited 1
      with `ui snapshot failed` and no "written" line, and the normal capture and
      63 thumbnails exited 0. Not ticked: `app-smoke --strict` passed 6/7.
      `startup-mute-capture` fails with "Original plugin target does not bind
      uniquely": its profile binds source object key 10, and the check loads no
      source scene. See A-T05 in
      [app-gameplay-and-plugins](app-gameplay-and-plugins.md).)
- [x] R4 app paths (PR #110): give a native character a degenerate IK target. The
      status line names the unsolved chain and the pose is kept. A source camera
      under a mirrored parent falls back to the saved camera with a
      `reflectedFrame` message.
      (automated in part: `scenarios/mirrored-camera.json` — on
      `scene-mirrored-camera.png`, which the original CharaStudio authored (camera
      key 2 under an item scaled (−1, 1, 1), saved active; control camera key 3 under
      an unmirrored copy), `StudioModel.viewCamera` renders from exactly the saved
      camera while camera 2 is active and the status line reads "Source camera
      "IKKOKU-MIRROR" (camera 2) view unresolved: Source camera object parent frame
      is mirrored …; using the saved camera." ("Source camera 2 view unresolved"
      before st-ux-ik-camera); the control camera looks through, and both hold
      after export → reimport. The original itself looks through the mirrored camera (scene-records.md
      "Mirrored camera parent"). Passed 2026-10-23.
      The degenerate-IK half is automated too, in `scenarios/reload-save-ik.json`
      (2026-10-23, 20/20 steps on the Debug build). A native female's Left hand
      target at X = 1e20 sets the status line to "Left hand IK left unsolved: IK
      reach is not finite.", and the arm stays bit-identical to its pre-IK pose.
      "Kept" means the pose before IK, not the last solved pose, whose elbow sat
      2.3 cm away; the pre-IK pose follows from the document alone, while the last
      solved pose would depend on edit history and is not saved. The stale status
      is fixed (st-ux-ik-camera, 2026-10-23): after the target returns to X = 0.3
      the status line reads "Left hand IK solved again.", two chains failing at
      once are both named and clear independently, and a status written since
      ("Added Kai") survives (`reload-save-ik` 36/36 in the full strict studio
      lane, 52/52, on the Debug build of `34e3e4e`; 6 of those 36 steps fail on
      main `c3e83fa`).
      [Native IK](../../Tools/verification/README.md#native-ik-re-solve-and-unsolved-status-r4-115-and-110).
      The visible status bar is not asserted headlessly.
      User, 2026-10-23, Debug build of main `c9df5df`: typing X =
      100000000000000000000 on a native female's Left hand target showed the
      unsolved status line and returned the arm to its pre-IK pose. Typing 0.3
      solved it again, while the status line kept the unsolved message (fixed,
      above). On `scene-mirrored-camera.png`, camera 2 was active with the
      saved-camera fallback message. Look through on camera 3 switched the view,
      and Look through on camera 2 restored the fallback. UI finding: the tree
      names the cameras (`IKKOKU-MIRROR`, `IKKOKU-CONTROL`) under folders labelled
      "Unrendered source item 0/1", while the status line names camera 2 by its
      source key and adds "Viewing through source camera "IKKOKU-MIRROR"" during
      the fallback, so it is hard to tell which camera is which and which view is
      shown. Addressed by st-ux-ik-camera (2026-10-23): the tree, status line,
      view indicator and Object tab all name the camera `IKKOKU-MIRROR (camera 2)`
      (in sentences `source camera "IKKOKU-MIRROR" (camera 2)`; the tree row
      puts "camera 2" on a second line so the narrow panel never cuts the key),
      the tree marks the active camera ("camera 2 · active" and a camera icon
      that is orange and struck through during a fallback), and during the
      fallback the indicator reads "Saved
      camera shown: source camera "IKKOKU-MIRROR" (camera 2) has a mirrored
      parent" instead of "Viewing through". `mirrored-camera` asserts the
      indicator and the tree labels (25/25; 7 of the 25 fail on main
      `c3e83fa`). The two item folders keep "Unrendered source item 0/1":
      their catalog key 0/0/0 is not in the converted catalog and item records
      carry no name. An item whose key the
      catalog maps but whose asset does not load now shows the catalog name with
      "(unrendered source item N)". See
      [Source camera labels](../../Tools/verification/README.md#source-camera-labels-st-ux-ik-camera).
      Not yet re-checked by hand.)
- [x] R4 IK fix (PR #115): drag a native character's IK handle. The hand or foot
      follows it, and re-solving the same target leaves the pose unchanged.
      (User, 2026-10-23: the hand follows the handle. Automated re-solve half:
      `scenarios/reload-save-ik.json`, 20/20 steps on the Debug build. A
      +0.02/−0.02 Stepper round trip on the Left hand target's X returns the same
      target float, and the arm is bit-identical to the solved capture. Each target
      is reached within 1.5e-7 m, and the targets survive a native document
      save/load (`reload-load-ik.json`, 7/7). With the pre-#115 update patched back
      in, the reach asserts fail by 16–74 mm.
      [Native IK](../../Tools/verification/README.md#native-ik-re-solve-and-unsolved-status-r4-115-and-110).
      User, 2026-10-23, Debug build of main `c9df5df`: dragging the Left hand
      handle in the viewport moved the hand with it, and one up and one down click
      on the Target row's X stepper returned the arm to the same pose.)
- [ ] A06 capture validation (PR #118): on a Debug build, run the commands in the
      build guide's "Capture request validation" section. Each of these exits 1
      naming its variables: two modes, an adapter report without a capture, and a
      capture option without a mode. A missing `IKKOKU_CARD` or `IKKOKU_LOAD_SCENE`
      exits 1 and writes no PNG. A plain Maker capture exits 0, and the `app-smoke`
      lane passes.
      (2026-10-23, local-wave-verify, Debug build of `2e732b9`. Each command
      behaved as listed. The three invalid requests named
      `IKKOKU_CAPTURE_RIG, IKKOKU_CAPTURE_SCENE`, `IKKOKU_NATIVE_PLUGIN_REPORT` and
      `IKKOKU_CAPTURE_W`. The missing card and scene exited 1 with no PNG, and the
      Maker capture exited 0. Not ticked: `app-smoke` passed 6/7, with the same
      `startup-mute-capture` failure as A-T05.)
- [x] T-T02 packaged app (PR #120): copy the Release app outside the checkout and run
      the build guide's thumbnail recipe with `IKKOKU_SOURCE_TREE_FALLBACKS=0`. It
      renders from the bundle alone and prints no `source-tree fallback` line. Also
      open the project in Xcode once: the navigator shows `Packages/` and the Engine
      package resolves.
      (2026-10-23. The Release app of main `87cf261` segfaulted on its first
      frame, which #128 (R6) fixed. Local-wave-verify then cloned the Release app
      of `2e732b9` outside the checkout. Run from there with
      `IKKOKU_SOURCE_TREE_FALLBACKS=0`, it wrote 63 thumbnails, exited 0 and
      printed no `source-tree fallback` line. `inspect_app_bundle.py` passed with
      208 files, arm64, 0 errors and 0 warnings. The user confirmed interactively
      that the fixed Release app no longer crashes. In Xcode, package resolution
      finished with no missing-package error and the project built. Its four
      warnings are fixed in `ea5c791`. User, 2026-10-23, main checkout at `5e86b57`:
      the navigator shows `Packages/`, and package resolution finished with no
      error.)
- [x] A-T01 gameplay lane (PR #121): on a Debug build,
      `python3 Tools/verification/run.py --manifest Tools/verification/lanes/gameplay-scenarios.json --strict`
      passes.
      (2026-10-23, local-wave-verify: 1/1 with 0 skipped on the Debug build of
      `2e732b9`, main `5e86b57` merged, Xcode 27.0, and earlier at `0501cf1`.
      The direct launch reported `gameplay scenario: 17 passed, 0 failed`.)
- [x] A-T02 relocation (PR #122): follow the build guide's moved-library acceptance.
      Every reference relocates, or one `Unresolved` line is printed per missing or
      changed identity, and nothing is loaded in its place.
      (2026-10-23, local-wave-verify. Automated variant: Release app of `f402483`
      copied outside the checkout, `IKKOKU_SOURCE_TREE_FALLBACKS=0`, explicit
      variables, since automated runs ignore the selection. A scene saved against
      `.local/reverse/` relocated 31/31 references into an APFS clone holding
      the libraries, `studio-pose/`, `animation-assets/` and the source scene.
      The capture was byte-identical to the original location's. Without the
      source scene, 7 references were unresolved, with one `Unresolved` line each
      and nothing drawn. Without `studio-pose/`, two `converted layout gap:`
      lines were printed, 19 references were unresolved, and the preview exited 1.
      The user's interactive run showed all 6 characters with no `Unresolved` or
      fallback line, but the scene was saved after the copy was chosen, so it
      tested the selection, not relocation. It first found the missing
      `studio-pose/` companion, fixed in `f402483`. Relocation, user,
      2026-10-23, main `c9df5df`: in the Debug app, Choose Converted Library… →
      `.local/reverse/`, preview of `koikatu_cs0002591.png` from inside it, and
      Save Scene…. Then Choose Converted Library… → the moved copy (the three
      libraries plus `studio-pose/`, `animation-assets/female-base/` and the scene
      at the same relative path), with no incomplete alert. The Release app, copied
      outside the checkout and run with `IKKOKU_SOURCE_TREE_FALLBACKS=0`, printed
      three `converted library:` lines and `Resource check: 31 references: 0
      resolved, 31 relocated, 0 unresolved.`, and showed all 6 characters with no
      `Unresolved` or fallback line. See the
      [build guide](../guides/build-and-test.md#use-a-converted-library-outside-the-checkout).)

| Order | Tasks | Concrete result required |
| --- | --- | --- |
| 1 | **ST-T01** | Remove the stale source-character inspector gate, connect the implemented source pose/label controls, and prevent prototype controls from writing unused fields on source characters. Verify through the actual app. **Status 2026-09-25:** gate removed and prototype-only inspector/Timeline writes blocked for source characters; headless `IKKOKU_CAPTURE_UI_REPORT` records the rendered inspector (mutation-checked). Remaining: live mouse-driven guide edits, undo/redo, save/reload and original export through the UI. |
| 2 | **T-T04, E-T03, CMT-11** | Make source-fixture execution explicit and reproducible. Preserve original/native input hashes, distinguish skips from executed checks, and add app workflows alongside kernel tests. **Status 2026-09-26:** named per-test fixture skips and strict mode (PR #4); stdlib verification runner with public/private-source/maker/app-smoke lanes, per-test counts, evidence manifests and isolated check environments. **2026-09-29:** `.github/workflows/ci.yml` runs the public lane (skip-tolerant) and an unsigned Debug app build on pull requests and pushes to `main`; the private lanes stay local. Maker session scenarios exist: `Tools/verification/lanes/maker-scenarios.json` runs the Debug app binary through `IKKOKU_MAKER_SCENARIO` over four JSON scenarios covering import, outfit switch, shape/color edits, export and reimport (4/4 under `--strict`, asserted from `MakerModel` state). Remaining: the mouse-driven Maker UI and its rendered result, the Studio/inspector UI checks, and original-player/managed-DLL tier checks. |
| 3 | **R1, R2, CMT-04** | Close full-character shader/appearance mismatch, integrate verified source materials into live rendering, then compare independently loaded original/native scenes at matched time/camera/light. |
| 4 | **ST-T04/05/06/07/08/10/11** | Complete the source Studio path: mixed objects, full-body player reference, editable cards, expression/look-at, dynamics, remaining Animator behavior and routes/cameras/effects. |
| 5 | **CMT-01/02/03/05/09/10** | Expand Maker asset/state coverage, source selection edits, dynamic ABMX and mod resolution while preserving original IDs and unknown payloads. |
| 6 | **G-T01/02/03/04** | Build real gameplay session/state bindings, complete a fixed event and ADV scenario, then add NPC/navigation and presentation commands. **2026-10-23:** G-T01's engine slice (`SourceGameplaySession`, #105) is merged. A-T01's first slice (`SourceGameplayHost` and the headless `IKKOKU_GAMEPLAY_SCENARIO` mode) is merged. G-T02 (character bindings) is done on its branch: the typed new-game heroine/player with original keys, `HeroineParam`, `ParameterFile` and host snapshot schema 2. Original scenario 301 finishes with values equal to the Python model and the original runtime (VM probe, 388 cases, 0 differences). The bound corpus rerun completes 4,370 of 10,463 assets with 0 unexplained. The Mac `gameplay-scenarios` lane runs the fixed event once across four reloads. Next: the transfer-list seed and `CharaChange`/`CharaEvent`, then G-T03 command families. |
| 7 | **P-T01/02/03/05** | Measure plugin API coverage, unify immutable adapter/IR libraries, verify installed adapter UI behavior and add real original save callbacks. **2026-10-24:** P-T02's library generations/dependency graph (#112) and bounded app selection/save/restore wiring (#161) are merged; the accepted row above records the actual GUI and fixture scope. Batch DLL triage, broader P-T01/03 coverage and P-T05 source save adapters remain. P-T04's Swift slice (#107) is also merged. |
| 8 | **R6/R7, T-T01/02/06, E-T04** | Enforce recoverable runtime limits, measure representative displayed scenes, provide a clean release/setup path and resumable conversion orchestration. **2026-10-23:** first slices merged: T-T01 (#116: recorded prerequisites, `doctor.py`, a CI check); R6 (#119: recoverable uniform ring, frame errors, morph and light limits); T-T02 (#120: Release bundle inspection in CI, source-tree fallback switch); A-T02 (#122: a selected converted library and identity-checked relocation of saved scenes). Remaining: versions for the unrecorded tools, the deployment matrix, an app run outside the checkout, character resource release, R7 budgets and E-T04. |

Do not resume these as one undifferentiated “finish the port” task. Each linked
task states entry points and a measurable acceptance condition; preserve the
existing uncommitted work and source/mod identity guarantees when implementing it.

## What was verified for this audit

This pass reviewed source, tests, conversion tools and retained local evidence;
it did not rerun every original-player or full application test. The renderer
review additionally ran 31 targeted Python tests successfully. Link/coverage and
whitespace checks validate the documentation itself. Existing test counts in
historical reports are dated results, not a fresh all-project test certification.

Two important confirmed defects were recorded: the unreachable source Studio
inspectors (gate removed 2026-09-25; live UI acceptance still open, ST-T01) and the native Mute adapter's headless startup trap (fixed in
code and verified in the PR #2 acceptance follow-up, ST-T02/A-T04). Existing successful
IR-plugin tests do not invalidate either finding. The audit also records incomplete or unverified areas without
presenting them as discovered runtime bugs.

## Keeping this current

When a task is implemented, update its feature row, add the exact verification
command/fixture and source/native hashes, record remaining exclusions, and then
change its status. Add new files to the coverage index. Promote a feature to
Fully ported only for the behavior actually verified, and check UI access and
save/reload independently where those are part of the feature.
