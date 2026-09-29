# Component audit and implementation backlog

**Reviewed 2026-09-25 · base commit `2cfb859` plus the current uncommitted working
tree.** This is the current implementation assessment. The
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
| Gameplay as a playable game | Infancy | Isolated cycle/event/ADV kernels lack session, NPC, scene and presentation host |
| General managed plugin compatibility | Infancy | Strict bounded AST subset plus two exact native adapters; no general Harmony/coroutine/Unity host |
| Recovery/build/test infrastructure | Mid-stage | Reproducibility, explicit fixture skips, automatic orchestration and release gating |

## Highest-priority handoff

Priorities are local to this project: **P0** is a confirmed broken current
workflow, **P1** closes a principal porting/integration gap, **P2** expands coverage
or hardens the implementation. Task IDs in the reports are stable references.

**Completed before this wave:** ST-T02/A-T04 passed local acceptance at PR #2
(head `93e6b06`, merge `aa4bcb9`). Both configurations retained identities and
identical reload frames; enabled tone gain muted/restored. See
[recorded acceptance](../reference/mods/native-adapters.md#verified-release-acceptance).

| Order | Tasks | Concrete result required |
| --- | --- | --- |
| 1 | **ST-T01** | Remove the stale source-character inspector gate, connect the implemented source pose/label controls, and prevent prototype controls from writing unused fields on source characters. Verify through the actual app. |
| 2 | **T-T04, E-T03, CMT-11** | Make source-fixture execution explicit and reproducible. Preserve original/native input hashes, distinguish skips from executed checks, and add app workflows alongside kernel tests. |
| 3 | **R1, R2, CMT-04** | Close full-character shader/appearance mismatch, integrate verified source materials into live rendering, then compare independently loaded original/native scenes at matched time/camera/light. |
| 4 | **ST-T04/05/06/07/08/10/11** | Complete the source Studio path: mixed objects, full-body player reference, editable cards, expression/look-at, dynamics, remaining Animator behavior and routes/cameras/effects. |
| 5 | **CMT-01/02/03/05/09/10** | Expand Maker asset/state coverage, source selection edits, dynamic ABMX and mod resolution while preserving original IDs and unknown payloads. |
| 6 | **G-T01/02/03/04** | Build real gameplay session/state bindings, complete a fixed event and ADV scenario, then add NPC/navigation and presentation commands. |
| 7 | **P-T01/02/03/05** | Measure plugin API coverage, unify immutable adapter/IR libraries, verify installed adapter UI behavior and add real original save callbacks. |
| 8 | **R6/R7, T-T01/02/06, E-T04** | Enforce recoverable runtime limits, measure representative displayed scenes, provide a clean release/setup path and resumable conversion orchestration. |

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
inspectors (open) and the native Mute adapter's headless startup trap (fixed in
code and verified in the PR #2 acceptance follow-up, ST-T02/A-T04). Existing successful
IR-plugin tests do not invalidate either finding. The audit also records incomplete or unverified areas without
presenting them as discovered runtime bugs.

## Keeping this current

When a task is implemented, update its feature row, add the exact verification
command/fixture and source/native hashes, record remaining exclusions, and then
change its status. Add new files to the coverage index. Promote a feature to
Fully ported only for the behavior actually verified, and check UI access and
save/reload independently where those are part of the feature.
