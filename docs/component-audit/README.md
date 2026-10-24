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
| GPU/Metal renderer | Mid-stage | Live source shader integration, resource limits, original effects and representative performance |
| Source shader translation/matched frames | Mid-stage | Garment diagnostic passes; full-character color fails; independent live app comparison pending |
| Native Studio editor/timeline | Mid-stage | Source controls and tracks differ from native prototype controls; source UI gate is a defect |
| Original Studio scenes | Mid-stage | Broad parsing/preservation; mixed object/map/light/route/effect consumers and edit topology incomplete |
| Full-body IK/guides | Mid-stage | Recovered solver tests exist; editor reachability and actual original-player full-body comparison remain |
| Animator/dynamics | Mid-stage | Selected normal states and hair chains; remaining controllers, loop correction, cloth and full sequence parity |
| Voice/audio | Mid-stage | Scheduler/mixer subset; original waveform coverage, spatial/lip-sync and scene sound consumers |
| Gameplay as a playable game | Infancy | A headless native host runs one synthetic fixed event across save/reload; NPC, scene, presentation, original save state and an interactive mode are missing |
| General managed plugin compatibility | Infancy | Strict bounded AST subset plus two exact native adapters; no general Harmony/coroutine/Unity host |
| Recovery/build/test infrastructure | Mid-stage | Reproducibility, explicit fixture skips, automatic orchestration and release gating |

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

The completed normal male/head-0 task [#179](https://github.com/grabbiel/ikkoku/issues/179)
adds three passing source/native comparisons over 35,573 selected vertices and
773 skin bindings / 226 joints. The independent neutral repeat preserves 817
transform records, all 20 geometry streams and saved card bytes. Its sole source
coercion, height to Float32 0.6, is reported separately. Fifty-eight focused
Python checks and the retained gates pass; all 472 new capture files remain
unchanged, and root verifies the 29 hashed summary descriptors. This completes
neutral and one coupled-shape acceptance for the six converted normal
female/male head 0/200/201 assemblies. No runtime formula, per-frame work or
performance benchmark changes. Broader shapes, corrected male types, animation,
full hierarchy and appearance remain open. Final CI and merge are pending.

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
