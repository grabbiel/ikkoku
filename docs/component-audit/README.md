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

**Merged 2026-09-28 (PRs #3–#39):** first slices of orders 1–3 and a large part of
order 4 (Studio source animation selection, hand patterns, blink, neck look-at,
routes). Every slice records its own evidence in the linked reports. The merged
`main` passes the Engine suite (458 tests), the app `xcodebuild` Debug build and the
`Tools/reverse` and `Tools/reverse/analysis` unittests. That evidence is
kernel-, capture- and build-level: **the merged wave has not been exercised
interactively in the running app yet.** Before these features count as verified
through the app, run this checklist against an original Studio scene (for
example `koikatu_cs0002591.png`) with the converted-asset environment variables
set:

- [ ] ST-T01: select a source character; the Pose, Face and Clothes tabs are reachable,
      FK/IK guide edits move bones, and prototype-only controls stay blocked (PR #5)
      (automated in part: `scenarios/fk-edit.json` — an FK bone rotation on character
      key 65 holds its exact degrees and moves the left-hand guide, and the pose
      survives export → reimport; passed 2026-09-30; also `scenarios/fk-mouse-drag.json`
      — mouse-driven FK guide drag automated through the real input handlers and GPU
      pick (headless; no physical mouse or window): the z rotate ring is grabbed and
      dragged 60,40 px, holds a non-zero FK rotation, moves the hand, pushes exactly
      one undo snapshot and survives export → reimport; passed 2026-09-30).
- [ ] ST-T10: the animation selection inspector changes the playing clip and speed, and
      original export keeps the new catalog IDs (PRs #12, #16, #17)
      (automated in part: `scenarios/animation-select.json` — selecting catalog clip
      [0,2,0] at speed 1.5 with forceLoop on reads back live and after export →
      reimport; passed 2026-09-30).
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
      reimport; no TARGET/AWAY-neck character exists in any scene under the fixture
      root, so the follow/avoid half and the FK-untouched half stay unautomated;
      passed 2026-09-30).
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
- [ ] ST-T06 shape values: change a source character's face shape slider: the face
      updates; export and reload keep the new value. Body shape and Reset to card
      behave the same way, and a value edited back to the card's saved rate exports
      byte-identical bytes (first slice, PR #64). (automated in part:
      `Tools/verification/scenarios/face-shape.json` covers a face and a body slot
      edit → export → reimport read-back; the live visual update, Reset to card and
      the back-to-saved-rate byte-identical case are not automated; passed 2026-09-29)
- [ ] ST-T06 colors: change a source character's hair or skin color: the preview
      updates; export and reload keep it. Reset to card restores the saved colors,
      and a color edited back to the saved rgba exports byte-identical bytes
      (second slice; no PR number yet). (automated in part:
      `Tools/verification/scenarios/color-edit.json` covers a skin color edit →
      export → reimport read-back; the hair color is not automated because
      `hair.parts.0.baseColor` binds no material on the imported assembly and export
      skips its writeback; the preview update, Reset to card and the back-to-saved
      byte-identical case are not automated; passed 2026-09-29)
- [ ] ST-T11 routes: route children and route characters move along their routes, and the
      Play/Stop, Play all, Replay all and Stop all controls behave as documented (runtime
      only; the route's saved `active` byte is exported only when its play state deviates
      from the record) (PRs #19–#39).
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
- [ ] VM: compile the merged `Tools/reverse/fixtures/OriginalCharacterProbe.cs` once with
      settings, hand-pattern and look-pattern modes together (merged textually from three
      branches).

| Order | Tasks | Concrete result required |
| --- | --- | --- |
| 1 | **ST-T01** | Remove the stale source-character inspector gate, connect the implemented source pose/label controls, and prevent prototype controls from writing unused fields on source characters. Verify through the actual app. **Status 2026-09-25:** gate removed and prototype-only inspector/Timeline writes blocked for source characters; headless `IKKOKU_CAPTURE_UI_REPORT` records the rendered inspector (mutation-checked). Remaining: live mouse-driven guide edits, undo/redo, save/reload and original export through the UI. |
| 2 | **T-T04, E-T03, CMT-11** | Make source-fixture execution explicit and reproducible. Preserve original/native input hashes, distinguish skips from executed checks, and add app workflows alongside kernel tests. **Status 2026-09-26:** named per-test fixture skips and strict mode (PR #4); stdlib verification runner with public/private-source/maker/app-smoke lanes, per-test counts, evidence manifests and isolated check environments. **2026-09-29:** `.github/workflows/ci.yml` runs the public lane (skip-tolerant) and an unsigned Debug app build on pull requests and pushes to `main`; the private lanes stay local. Maker session scenarios exist: `Tools/verification/lanes/maker-scenarios.json` runs the Debug app binary through `IKKOKU_MAKER_SCENARIO` over four JSON scenarios covering import, outfit switch, shape/color edits, export and reimport (4/4 under `--strict`, asserted from `MakerModel` state). Remaining: the mouse-driven Maker UI and its rendered result, the Studio/inspector UI checks, and original-player/managed-DLL tier checks. |
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
