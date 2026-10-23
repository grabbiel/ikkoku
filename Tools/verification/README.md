# Manifest-driven verification lanes

Reviewed 2026-09-26 (T-T04 / E-T03 / CMT-11). Run every command from the
repository root. `Tools/verification/run.py` is a stdlib-only Python runner:
it executes the checks declared in a lane manifest, parses per-test results,
and writes one JSON report under the git-ignored `.local/` tree. It never
starts a CI job, downloads anything, or runs commands through a shell.

## Usage

```sh
# Public lane — safe without any private data:
python3 Tools/verification/run.py --manifest Tools/verification/lanes/public.json

# Private-source lane — the one Engine-suite check declares 51 fixture
# variables, all `"optional": true`, so it runs whatever is supplied.
# Without an environment file it runs with none supplied and lists
# everything under `missingFixtures` (a supplied-but-unreadable path
# still fails the check):
python3 Tools/verification/run.py --manifest Tools/verification/lanes/private-source.json

# With --strict, any missing declared fixture — optional or not — fails
# the check instead of merely recording it as missing:
python3 Tools/verification/run.py --manifest Tools/verification/lanes/private-source.json --strict

# With real fixtures supplied (paths only; keep the file in .local/):
python3 Tools/verification/run.py --manifest Tools/verification/lanes/maker.json \
  --environment .local/verification/environment.json
```

Options: `--environment PATH` (JSON file providing declared fixture paths; must stay in `.local/`), `--report PATH` (must stay under `.local/verification/`; an existing file is never overwritten), `--strict` (fails a check if any declared fixture is missing), and `--timeout SECONDS` (default 240 per check, overridable per check via `timeout`).

Swift Testing reports sum the `Test run with N …` totals from each test
executable in the check's process log. Those totals include skipped tests;
`executed` and passed/failed/skipped counts come from named per-test results
when available. Repeated issue/failure lines for one test retain its worst
status without counting it twice. Reports created before the 2026-10-17
accounting fix kept only the last executable's total: the Engine run with
511 + 12 tests incorrectly reported `total: 12`, while its per-test counts
remained correct. Historical reports are retained as recorded; re-parsing
their logs corrects accounting but does not constitute a new test execution.

## Environment isolation

Each check inherits the shell environment with every `IKKOKU_*` variable removed, then receives only its declared fixtures supplied by the environment file, followed by its own `env` settings; `--strict` also sets `IKKOKU_REQUIRE_SOURCE_FIXTURES=1`. The environment file holds fixture paths only; capture and UI settings belong in the check's `env`.

## Manifest schema (schemaVersion 2)

Each manifest is `{"schemaVersion": 2, "checks": [...]}` and every check needs:

| Key | Meaning |
| --- | --- |
| `id` | Unique check name; used as the log file name. |
| `argv` | Executed directly (no shell). A missing program fails the check. |
| `fixtures` | `{"env": "IKKOKU_*", "kind": "file"\|"directory", "optional"?: bool, "from"?: "IKKOKU_*"}` — paths come **only** from the `--environment` JSON map (default `{}`), never from the shell. A MISSING **required** fixture skips the whole check (`FAILED` under `--strict`); a missing `optional` one is recorded in `missingFixtures` and the check runs anyway, so a suite runs with whatever fixtures exist. A supplied-but-unreadable path always FAILS. Directory fixtures are hashed as a bounded tree (≤4096 entries, ≤512 MiB). `from` selects the environment-file KEY whose value fills `env`, so one check can supply a different scene file under the same variable the program reads (the aliased value is what gets hashed into `suppliedFixtures`, recorded with its `from`); a missing alias skips/fails the check naming `env`. |
| `env` | Fixed non-secret settings merged over the environment map. Only `IKKOKU_*` keys; `PATH`, `LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH` and `PYTHONPATH` are rejected. |
| `minimumTests` / `maximumSkipped` | Bounds on the parsed results. `minimumTests` counts EXECUTED tests (passed + failed). PR #4 supplies named per-test fixture skips, which the lanes report; earlier `guard let env … else { return }` tests appeared as executed passes without their data. Read per-test names and skips before claiming source-data coverage. |
| `referenceTier` | One of `synthetic`, `recovered-code-oracle`, `original-managed-dll`, `original-player-probe`, `app-smoke`; any other value rejects the manifest. A tier is declared metadata; the runner never infers it. |
| `tolerance` | Optional free text telling readers what the check does **not** prove. |
| `artifacts` | Files hashed AFTER the run (built binaries, generated reports). A missing or empty (0-byte) artifact fails the check, even after exit 0. Paths must stay inside the repository. `test_run.py` requires every `app-smoke` check to declare each output path it passes to the app (captures, UI PNG/report, scenario/plugin reports) as an artifact. |
| `timeout` | Per-check override of `--timeout`, in seconds. |

## Reference tiers

Tiers bound what a check can support: `synthetic` (generated fixtures only),
`recovered-code-oracle` (a checked-in independent oracle over recovered
logic), `original-managed-dll` (a recovered managed assembly is executed),
`original-player-probe` (a controlled copy of the original player was run),
and `app-smoke` (the built app binary was executed headlessly). None of
them claims whole-game parity; read each `tolerance`.

## Lanes

| Lane | Checks | Status 2026-09-26 |
| --- | --- | --- |
| `public.json` | Engine `swift test`, mod-tools / translation / runner-self / studio-validator `unittest` suites | 5/5 checks pass (Engine `swift test` runs 369 tests, plus Python suites). Gated Swift tests use PR #4 named skips; without PR #4, early returns would report as executed passes. |
| `private-source.json` | One `engine-source-suite` check declaring every `IKKOKU_*` variable gated in `Packages/Engine/Tests` except `…_OUTPUT/_REPORT/_RESULT`, `IKKOKU_SAVE_SCENE` and `IKKOKU_EXPORT_SOURCE_SCENE` — all marked `optional` so the suite runs with whatever exists | Runs with or without an environment file; unsupplied fixtures are recorded per check and only fail under `--strict`. With 32 local fixtures supplied on the integrated tree, Engine runs 379 tests: 359 passed, 20 named skips (via PR #4), 0 failed. |
| `maker.json` | Seven Swift `--filter` checks over converted Maker/card/material data plus `card_roundtrip.py` / `maker_roundtrip.py` audits | 6 checks pass (47 executed tests) and 3 skip: one Swift check skips because `IKKOKU_APPEARANCE_REFERENCE_ROOT` exceeds the 512 MiB hash bound when supplied; both roundtrip audits declare their real prerequisites (`IKKOKU_MANAGED_RECOVERY_EXPORT`, `IKKOKU_MAKER_COMPLETION_INPUTS`) as fixtures and skip with named reasons while absent — nothing shipped here fails on the reference machine. |
| `app-smoke.json` | Debug `xcodebuild` build (built binary hashed as artifact), headless Mute-startup run (its plugin report hashed as artifact), then two ordered checks: `studio-inspector-capture` runs the Debug app expecting the source-pose report and hashes both the UI PNG and that report, so an exit-0 run that leaves either missing or empty fails (A-T05); `studio-inspector-validate` runs `Tools/verification/checks/studio_inspector_report.py` against that JSON | Debug build passes; `startup-mute-capture` skips (3 plugin fixtures absent locally); `studio-inspector-capture` and `studio-inspector-validate` pass when PR #5 UI report hooks are merged (report confirms `SourcePoseInspector observed == expected`), but fail with a clear missing-report result on this branch without PR #5, as stated in their tolerance text. The lane has not been rerun since A-T05 (2026-10-23) added the PNG and Mute-report artifacts. |
| `studio-scenarios.json` | Thirty-four `app-smoke` checks, each running the Debug app binary with `IKKOKU_STUDIO_SCENARIO` pointed at one scenario JSON under `Tools/verification/scenarios/` (see below) | 2026-10-17: the full 34-check run passed 31 and failed three synthetic imports (0 skipped); pinning their optional Maker library off resolved all three in a 3/3 strict rerun, with fixtures unchanged. The shape/color visual checks passed 45/45 and 31/31 steps. Historical: 32/32 checks passed 2026-10-01 (including the four `charastudio-*` export checks whose PNGs the CharaStudio reload probe loads) with `IKKOKU_SOURCE_AVATAR` (+`IKKOKU_STUDIO_ITEM_CATALOG` for props, +`IKKOKU_STUDIO_ANIMATION_CATALOG` for the animation/FK scenarios, +`IKKOKU_STUDIO_LOOK_SETTINGS` for the eye/neck look scenarios, +`IKKOKU_STUDIO_HAND_PATTERNS` for `hand-patterns`) supplied; every save/import-side check fills `IKKOKU_SOURCE_SCENE` through the fixture `from` key: the seven character scenarios (including `undo-props` and the catalog-less `undo-no-catalog`) and the two look scenarios (`eye-look-orbit`, `neck-look-orbit`) from `IKKOKU_STUDIO_SCENARIO_SCENE` (`koikatu_cs0002591.png`), the camera scenarios (`camera-*`, `undo-camera`, `reload-save-camera`) alias `IKKOKU_SOURCE_SCENE` from `IKKOKU_CAMERA_OBJECT_PROBE_SCENE` (scene-x), the route scenarios (`route-play-state`, `undo-route`, `reload-save-route`) from `IKKOKU_ROUTE_PROBE_SCENE` and the live-clock scenarios (`blink-toggle`, `hand-patterns`, `hand-patterns-kept` — a single character with saved hand patterns [5, 6]) from `IKKOKU_STUDIO_SCENARIO_SYNTHETIC_SCENE` (`synthetic-current.png`); the three `reload-load-*` checks declare no scene fixture on purpose (see below); every scenario report and exported scene hashed as an artifact. Earlier run: 12/12 passed 2026-09-29 before the reload pairs were added. |
| `maker-scenarios.json` | Four `app-smoke` checks, each running the Debug app binary with `IKKOKU_MAKER_SCENARIO` pointed at one `maker-*.json` scenario under `Tools/verification/scenarios/` (see below) | 4/4 checks passed 2026-09-29 under `--strict` with `IKKOKU_MAKER_SCENARIO_CARD` (the 7-coordinate `synthetic-appearance-card.png`) and `IKKOKU_SOURCE_AVATAR` in the environment file; every check fills `IKKOKU_SOURCE_CARD` through the fixture `from` key; every scenario report and exported card hashed as an artifact. |

## Studio scenario hook (T-T04)

When the app starts with `IKKOKU_STUDIO_SCENARIO` set, `AppState` runs a
headless scenario instead of the auto-capture path and exits itself
(0 when every step passed, 1 otherwise) — `IKKOKU_AUTOCAPTURE` is not
needed in that mode. The variable names a JSON file (`Tools/verification/
scenarios/*.json`, resolved against the check's cwd, the repo root)
holding `{"steps": [...]}`; `IKKOKU_STUDIO_SCENARIO_REPORT` is required
and names the JSON report to write (`{"steps":[{"op","ok","detail"}],
"passed","failed"}`). Objects are addressed by SOURCE KEY
(`sourceObjectKey`), never by runtime UUIDs; numeric compares use a 1e-5
tolerance. A failing `assert`/edit step is recorded and the run
continues; a failing `export`/`reimport` stops it. Both write only under
`.local/`. Ops: `select`, `setVisible`, `rename`, `toggleCamera`,
`toggleRoute`, `undo`, `redo`, `newScene`, `setFace`, `setBody`
`{key,index,value}`, `setColor` `{key,id,rgba[4]}`, `resetShape`
`{key,face:true|false}` (shared with the inspector; clears only the selected
shape domain), `resetColors` `{key}` (clears color edits, preserving shapes), `setAnimation`
`{key,group,category,no}` (a clip must exist in the
`IKKOKU_STUDIO_ANIMATION_CATALOG` or the op fails before mutating),
`setAnimationSpeed` `{key,speed}`, `setForceLoop` `{key,on}`,
`setFKEnabled` `{key,on}`, `setFK` `{key,bone,rotation[3]}` (degrees, the
inspector's guide drag: also turns FK on, like the drag), `setPoseMode`
`{mode:"object"|"fk"|"ik"}` (the inspector's mode picker), `selectBone`
`{key,bone}` (selects the object and that guide bone, the same two setters
the UI list and inspector use), `dragGizmo` `{key,bone,axis:"x"|"y"|"z",
pixels:[dx,dy]}` (drives the REAL input handlers: projects the bone's world
origin with the view camera, scans ±120 px for a pixel whose GPU pick id is
that rotate ring, and calls `mouseDown` / eight `mouseDragged` / `mouseUp`
there — a ring turned edge-on to the camera projects to a sub-pixel sliver
nothing picks, and then the failure names the rings the camera does see),
`captureBone`
`{key,bone,name}` (memorizes that guide bone's position in the character's
rig frame under a label for a later `fk`/`from` compare),
`advance` `{seconds}` (walks the app's own live step at its 1/30 s cadence —
the blink clocks, the neck/eye gaze solvers, dynamics and the route/animation
clocks all run, exactly like the editor's timer tick — and starts a new blink
observation window first), `orbit` `{dx,dy}` (the viewport drag: `yaw -= dx`,
`pitch += dy` clamped to ±1.55; refused while a source camera object is looked
through, like the view's gesture), `setAutomaticBlink` `{on}` (the Studio
toggle's property; its didSet forwards to every rendered preview), `export`/`reimport`
`{path}`, `saveDocument`/`loadDocument` `{path}` (native save/load of a
Studio document card) and `assert` with any of `name`, `visible`,
`face`/`body`
`{index,value}`, `color` `{id,rgba}`, `activeCamera` (key or null),
`routePlaying` `{key,playing}`, `animation`
`{key,group?,category?,no?,speed?,forceLoop?}` (the live animation state the
preview plays for that character — the document's saved-clip override or the
scene record's own — an absent sub-key is not asserted), `fk`
`{key,bone,rotation?,from?,within?,nonZero?}` (`rotation` checks the
document's FK edit in degrees; `from` names a `captureBone` label and asserts
the bone MOVED further than the tolerance from it, or stayed within `within`
of it; `nonZero` asserts the held rotation has a component past the
tolerance — a drag's angle comes out of the ring geometry and cannot be
matched to a number), `eyeLook`
`{key,lookType?,horizontalSign?,verticalAbove?,verticalBelow?}` (the live gaze
solver's last-frame iris-shift rates: `lookType` names the pattern's type,
`horizontalSign` asserts both eyes' rates are non-zero and share that sign — a
camera dead ahead converges to equal-but-opposite rates, so a shared sign
means a genuine side-crossing — and the vertical bounds are strict; a
character whose eyes are animated has no live solver and the failure says
why), `blink` `{key,happening}` (whether the recovered blink control rendered
a closing since the last `advance`; a toggle-off leg pairs a `true` window
with a following `false` one, and a card whose saved `eyesBlink` flag is off
renders the fixed sentinel and can never set it), `handPattern`
`{key,left?,right?}` (the saved `handPatterns` pair the loader replays;
absent hands are not asserted),
`sourceRuntime`
`{cameras,items,routes,sceneLight,rehydrations}` (each sub-key optional;
`rehydrations` is how many times the scene file was re-read; the others count the
live entries of the SHA-gated source runtime caches — a step's
`assert`/`sourceRuntime` was added for ST-T15 to pin that undo/redo/New
Scene keep a source scene's props, cameras, routes and light — and that a
`loadDocument` in a fresh process rebuilds them (ST-T01) —
`diagnosticContains`. The runner closes the editor's 0.4 s
edit-coalescing window (`StudioModel.endUndoCoalescing()`) before every
step, so each step takes its own undo snapshot however fast the steps run;
without it, startup's forced import `pushUndo` made the first edit's
snapshot load-dependent. The `saveDocument`/`loadDocument` pair (added for
ST-T01) round-trips through the app's native `saveScene`/`loadScene` — a
Studio document card under `.local/`, not the exported original-format scene
`export` writes — and rehydration failures on load surface as a
`diagnosticContains` assert on the appended "Source scene rehydration:"
diagnostic. The scenarios cover the
automatable halves of the Studio checklist in
`docs/component-audit/README.md`; each check's `tolerance` says exactly
which checklist claims (live visuals, CharaStudio reload, unbound hair
color writeback) stay unchecked.

### Shape/color visual and reset acceptance (ST-T06c)

`captureRender` `{name,path?}` renders the current production frame at 512×512,
with grid and gizmos omitted. Pixels are retained under `name`; an optional
`.local/` PNG output can be listed as a hashed lane artifact. Capture and export
outputs must differ from both the initially imported and currently imported
source paths; these guards run before any output is removed or written. An `assert` may
include `render: {from,changedPixelsAtLeast?,changedPixelsAtMost?,maxChannelDeltaAtMost?}`.
A changed pixel has at least one RGBA8 channel differing by more than 2/255.
At least one pixel-count bound is required; both must lie in 0…262144 and minimum
must not exceed maximum. The optional maximum channel delta is 0…255; zero
requires exact byte restoration. Successful reports include the measured count,
exactly changed pixel count, maximum channel delta, dimensions and bounds.
`changedPixelsAtMost: 0` alone allows differences of up to two channel units.

`exportIdenticalToSource: ".local/…png"` compares the exported SHA-256 with the
source SHA captured **at scenario start**, even after reimport; the initial
source path itself is refused. `assertRejected` accepts the same assertion
fields plus a nonempty `errorContains`: exactly one assertion must fail with
that diagnostic fragment. The shape/color scenarios use it to reject a changed
export after reimport, preventing output-versus-itself comparisons. The shape
scenario also checks that unchanged pixels cannot satisfy a visible-change
claim and rejects missing, negative, inverted and oversized render bounds.

`shape-visual-reset.json` edits face slot 20 on key 0 and body slot 0 on keys 0
and 65, checks each shape reset preserves the other domain, and restores values
explicitly before export. `color-visual-reset.json` edits `body.skinMainColor`
on key 0, checks reset isolation from shape edits in both directions, and
restores the saved rgba explicitly before export. Both assert their fixture's
starting values, require at least 50 visibly changed pixels, and require exact
RGBA8 restoration after reset. They declare the scene, rig and Maker-library
file fixtures (including hashes) and never advance the clock or move the camera, so unrelated animation cannot
satisfy the change check or alter export bytes. The original `face-shape` and
`color-edit` checks continue to cover edited-value export/reimport. Recorded 2026-10-17: the two new scenarios passed 45/45 and 31/31 steps;
face/body/skin edits changed 76, 40,270 / 38,581 and 10,251 pixels respectively,
and every reset comparison had zero exact pixel differences and maximum channel
delta 0. Restored exports matched the initial source SHA. These are
headless model calls and production-render checks; mouse-driven slider/button
interaction and original-player appearance comparison remain separate gates.
The attempted visible-window check on 2026-10-17 was blocked by the native UI
tool reporting that Computer Use permissions were not granted; no interactive
acceptance is claimed from that attempt.

The 2026-10-17 full lane initially passed 31/34 checks (0 skipped). The existing
synthetic blink/hand checks discovered a local Maker library and could not render
their minimal card (`Unsupported hair part array`). After explicitly disabling
that unrelated catalog for those three checks, their strict rerun passed 3/3
(11, 13 and 11 steps). The private input bytes and all assertions stayed unchanged;
this is playback coverage without assembled hair/clothes. The first failure
reports remain retained as evidence; these counts describe the full run plus the
corrected subset, not a second complete lane run.
Additional local negative probes confirmed that `assert face:true` fails decoding
and that capture/export refuse both the initial and current source paths after
reimport; the copied synthetic inputs remained byte-identical.

### Outfit selection (ST-C03 first slice)

`setOutfit` `{key,index,errorContains?}` calls `StudioModel.setSourceOutfit`,
the same method as the Clothes inspector's Outfit picker. With
`errorContains`, the selection must be refused with that fragment, and the
document's `sourceOutfit` and the rendered preview instance must stay unchanged.
`assert`/`assertRejected` accept
`outfit: {key,coordinate?,saved?,resolved?,missing?}`. It reads the live
preview: `coordinate` is the assembled outfit and `saved` is the embedded card's
`Status.coordinateType`. `resolved` names a selection property, such as
`outfit3.ChaFileClothes.ClothesTop`, that must have resolved to a library entry
with the card's source ID. `missing` names one that must be `conversionMissing`,
with no entry and a matching preview diagnostic.

`outfit-select.json` (28 steps) uses source character key 65. It begins on the
saved outfit 0 and checks that outfit 7 is refused without changing the render.
Outfit 3 must change at least 10,000 pixels, resolve `ClothesTop` and report
`ClothesBra` as `conversionMissing`. Unchanged-render and wrong-outfit controls
must fail through `assertRejected`. Undo, redo and the switch back to outfit 0
must reproduce the captured renders exactly. The restored export must equal the
initial source SHA before and after reimport. The outfit 3 export must differ;
after reimport, saved and rendered outfit 3 must reproduce the earlier render
exactly. Key 0 must keep its outfit 0, and outfit 2's converted outer shoes must
resolve. `reload-save-outfit` and `reload-load-outfit` form the usual native
save/load pair, and the load side declares no scene fixture. After the fresh
process loads the document, outfit 3 must be selected over the card's saved 0.
Switching to 0 must change the render, and undo must restore the loaded frame
exactly. All three checks declare the scene, rig and Maker-library fixtures; the
load side omits the scene. Their pixel results depend on that library.
Recorded 2026-10-17, on the Debug build of this change: the complete lane passed
37/37 with `--strict` and 0 skipped. The three outfit checks passed 28/28, 6/6
and 8/8 steps. Outfit 3 changed 19,155 pixels by more than 2/255; 33,204 pixels
differed at all, with a maximum channel delta of 146. Every exact comparison had
0 differing pixels and channel delta 0. The restored export kept SHA-256
`029f0b1d…` before and after reimport, while the outfit 3 export had
`35087745…`. In the fresh load process, switching to outfit 0 produced the same
19,155 / 33,204 / 146 difference. These checks call model methods headlessly; the
visible picker and CharaStudio reload remain separate gates.

No `studio-scenarios` check reads the environment file's own `IKKOKU_SOURCE_SCENE`
(the `app-smoke` and `private-source` lanes use it for a different
scene). Each check aliases it through the fixture `from` key instead.
The fourteen character scenarios (`visibility-folder`, `rename-folder`,
`face-shape`, `color-edit`, `item-props`, `undo-props`, `undo-no-catalog`,
`animation-select`, `fk-edit`, `fk-mouse-drag`, `shape-visual-reset`,
`color-visual-reset`, `outfit-select`, `reload-save-outfit`) take
`IKKOKU_STUDIO_SCENARIO_SCENE`, which must be the scene whose object
keys they address (`koikatu_cs0002591.png`: keys 0, 65 and 622);
`animation-select`, `fk-edit` and `fk-mouse-drag` additionally require
`IKKOKU_STUDIO_ANIMATION_CATALOG` (set at import, it lets
`setAnimation` validate and resolve the selected clip; `fk-mouse-drag`
needs it only to import the same scene state `fk-edit` edits). The two visual
reset scenarios and the three outfit checks additionally require
`IKKOKU_MAKER_LIBRARY`; their pixel and color results depend on the selected
assembly. The synthetic `blink-toggle`,
`hand-patterns` and `hand-patterns-kept` checks explicitly set
`IKKOKU_MAKER_LIBRARY=none`: their minimal cards exercise playback, not converted
hair/clothes, and must not inherit a developer’s optional assembly library.

`koikatu_cs0002591.png` has neither a camera nor a route-bearing object, so the six
camera/route scenarios take a probe scene: `camera-load-winner`,
`camera-deactivate`, `camera-rename` and `undo-camera` run against the
two-active-camera scene-x (`IKKOKU_CAMERA_OBJECT_PROBE_SCENE`),
`route-play-state` and `undo-route` against the scene with two
saved-active routes (`IKKOKU_ROUTE_PROBE_SCENE`). The eight `reload-*`
scenarios run as ordered save→load pairs (`test_run.py` pins the
adjacency): `reload-save-props`/`reload-save-camera`/`reload-save-route`/`reload-save-outfit`
take the same scene as their character/camera/route/outfit counterparts and
`saveDocument` a native card under `.local/verification/scenario-exports/`,
and the `reload-load-*` check immediately after each one loads that card
back. The load-side checks deliberately declare NO scene fixture: with
`IKKOKU_SOURCE_SCENE` set, startup's own import would reseed the runtime
caches and the load asserts would pass vacuously; without it the process
starts on the empty document and only `loadDocument` + rehydration can
produce the asserted cache entries (that is exactly the ST-T01 defect the
pair pins).

```sh
# Build Debug first, then (needs the six private fixture paths — scenario
# scene, avatar, item catalog, animation catalog, camera probe scene, route
# probe scene — in .local/verification/environment.json):
python3 Tools/verification/run.py \
  --manifest Tools/verification/lanes/studio-scenarios.json \
  --environment .local/verification/environment.json --strict
```

A declared `artifacts` entry is hashed only AFTER the run — an artifact
the check never produced (or an empty or oversized one) FAILS the check, e.g.
`studio-inspector-capture` while the PR #5 hooks are absent, or
`build-debug-app` if the build itself fails.

## Maker scenario hook (T-T04)

When the app starts with `IKKOKU_MAKER_SCENARIO` set, `AppState` runs it
immediately after the `IKKOKU_SOURCE_CARD` Maker import: a headless Maker
scenario instead of the auto-capture path, exiting itself (0 when every
step passed, 1 otherwise) — `IKKOKU_AUTOCAPTURE` is not needed in that
mode and `IKKOKU_MAKER_SCENARIO_REPORT` is required and names the JSON
report to write (`{"steps":[{"op","ok","detail"}],"passed","failed"}`).
The variable names a JSON file (`Tools/verification/scenarios/maker-*.json`,
resolved against the check's cwd, the repo root) holding `{"steps": [...]}`.
Shape slots are plain indices into `sourceFaceValues`/`sourceBodyValues`;
numeric compares use a 1e-5 tolerance and color components 1/255 (the card
stores colors as bytes). A failing `assert`/edit step is recorded and the
run continues; a failing `export`/`reimport` stops it. Both write only
under `.local/`. Ops: `customization` `{on}` (the export precondition),
`selectCoordinate` `{index}`, `setFace`/`setBody` `{index,value}`,
`setColor` `{id,rgba[4]}` (draft edit plus `applySourceAppearance`),
`resetShapes`, `export`/`reimport` `{path}`, and `assert` with any of
`coordinate` (a draft view state; after a reimport it is the importer's
default outfit, not a round-tripped value),
`face`/`body` `{index,value}`, `color` `{id,rgba}`, `colorApplied` (a color
id in `sourceAppearanceAppliedFields`), `diagnosticContains`. The scenario
asserts only what `exportSourceCard` actually writes — face values, body
values and the saved color edits — never the selected outfit, which is a
view choice the export does not store. Color edits are saved per outfit
(keyed by record and path): `maker-outfit-colors` edits the same clothes
color id in outfits 0 and 1, checks that each outfit shows only its own
edit, and reads both back after export and reimport. The scenarios cover the
automatable halves of the Maker checklist in
`docs/component-audit/README.md`; each check's `tolerance` says exactly
which checklist claims (rendered visuals, UI controls, plug-in data) stay
unchecked.

The environment file has no plain `IKKOKU_SOURCE_CARD` key (the existing
`IKKOKU_SOURCE_CARD_FIXTURE`/`_ORACLE` keys belong to the `maker` lane),
so each check fills `IKKOKU_SOURCE_CARD` through the fixture `from` key
from `IKKOKU_MAKER_SCENARIO_CARD`. That must be a card with coordinates and
bound colors: `synthetic-appearance-card.png` imports with seven
coordinates and applied fields including `body.skinMainColor` and
`clothes.parts.0.colorInfo.0.baseColor`; `cards/synthetic-current.png`
imports with zero coordinates and no applied fields and cannot drive
these scenarios.

```sh
# Build Debug first, then (needs the two private fixture paths — the
# scenario card and the avatar rig — in .local/verification/environment.json):
python3 Tools/verification/run.py \
  --manifest Tools/verification/lanes/maker-scenarios.json \
  --environment .local/verification/environment.json --strict
```

## Prerequisite checker (T-T01)

```sh
python3 Tools/verification/doctor.py                    # report only; exit 0
python3 Tools/verification/doctor.py --require public   # exit 1 if a public capability is unmet
python3 Tools/verification/doctor.py --require reverse-tools --tool reverse-python=python3.12
python3 Tools/verification/doctor.py --json             # machine-readable report
python3 Tools/verification/doctor.py --markdown         # regenerate the build-guide table
```

`doctor.py` is stdlib-only. `prerequisites.json` is the single record of tool
versions, and the [build guide's table](../../docs/guides/build-and-test.md#prerequisites)
is generated from it. Each tool is probed once with a `--version`-style
command, or `importlib.metadata` in the documented interpreter, at its
documented path. Those paths include the `.local/reverse/` venv and ILSpy
shims. The checker never reads `.local/` data or fixtures, installs nothing and
writes nothing. Every capability is reported. Only those selected by
`--require` (`public`, `optional`, `all` or capability ids) affect the exit
status: 1 when one is unmet, 2 for invalid arguments or an invalid
prerequisites file. `--tool ID=PATH` substitutes an executable. A set `$PY` or
`$BLENDER` is used exclusively, as `Tools/assets/run_all.sh` does.
`--verbose` prints each probe and its raw output.

Requirements are `>=V`, `V.*`, `==V` or `unrecorded`: presence only, because
the repository documents no version. Reverse-tool pins are read from
`Tools/reverse/requirements.txt` rather than restated. A tool is `ok` or
`present` (satisfied), or `mismatch`, `unparsed`, `error` or `absent`.
`test_doctor.py` runs in the `runner-self-tests` check. It evaluates every
sample in `doctor-samples.json`, each marked `recorded` (captured from a named
run) or `format sample` (layout only, illustrative numbers). It also fails
when the generated table, a restated version (`statedIn`) or the public tier
drifts from the prerequisites file.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request to `main`, every push to
`main` and on manual dispatch. It runs three jobs on GitHub-hosted `macos-26`
runners (the app's deployment target is macOS 26, so it needs Xcode 26):

- `public-lane` first runs `doctor.py --require public --verbose`, so a missing
  Xcode, Metal compiler, Swift, `python3` or .NET SDK fails with the fix named
  (10 s and 5/5 public capabilities met in the first dispatched run,
  2026-10-23). It then builds the Engine tests (`swift build --build-tests`, so the
  lane's 600 s `swift test` timeout does not include a cold build), then runs
  `public.json` **without `--strict`**. Fixture-gated Swift tests report named
  skips instead of failing; the report and per-check logs are uploaded as the
  `public-lane-report` artifact.
- `app-build` builds `IkkokuCreator` Debug with code signing disabled
  (`CODE_SIGNING_ALLOWED=NO`), because the runner has no development-team
  identity. It checks that the app compiles and links, and nothing more.
- `reverse-tools` (`macos-26`, Python 3.12) installs only the pinned
  `Tools/reverse/requirements.txt` and runs the `Tools/reverse` and
  `Tools/reverse/analysis` unittest suites. Without `.local/` they skip or
  early-return their fixture-gated cases, exactly as on a fresh checkout (a
  clean requirements-only venv gave 342 tests with 7 skipped, plus the analysis
  suite, on 2026-10-01). It runs on macOS arm64 rather than Linux because
  the checked-in float32 fixtures (for example the dynamics reference) are
  generated there and compared exactly: on `ubuntu-latest` the generator's
  numpy float32 output differed in the last bits and
  `test_checked_in_fixture_matches_generator` failed (first hosted run of
  this job, 2026-10-01).

The `private-source`, `maker`, `app-smoke`, `studio-scenarios` and
`maker-scenarios` lanes stay local: they need the original installation,
`.local/` fixtures or the Parallels VM. A green CI run therefore says nothing about source-data parity or
app behavior; record the local lane results in the pull request as before. The
workflow does not gate merges (no required status check).

The jobs use the runner image's default Xcode, which can be newer than the
reference machine's (Xcode 26.6 on the `macos-26-arm64` 20260907 image
against 26.0.1 locally on 2026-09-29). CI therefore also catches compiler
differences: its first run found a heterogeneous array literal in
`SourceStudioWorldTransformTests.swift` that Xcode 26.6 no longer infers as
`[SIMD3<Float>]`.

## Report fields

A report records `git.revision`, the dirty flag and the sha256 of
`git diff HEAD` when dirty; the runner path+sha256; the manifest path and
sha256; `swift`/`xcodebuild`/`python3` versions (absent tools report
`null`); and per check: argv, cwd, `passedEnvironment` with the sorted
`IKKOKU_*` names actually passed, `env` with values only for the check's own
settings, `suppliedFixtures`/`missingFixtures` with paths and hashes,
`referenceTier`, `tolerance`, artifact hashes taken **after** the run (a
missing or empty artifact fails the check), exit code, elapsed seconds, and the log
path plus its hash.
Reports and logs live under the git-ignored `.local/verification/`.
`Tools/verification/environment.example.json` carries placeholder paths
only; real values belong in your git-ignored `.local/verification/environment.json`.
The `IKKOKU_IK_APP_ENVIRONMENT` fixture points to a JSON file path containing an object mapping `IKKOKU_SOURCE_SCENE`, `IKKOKU_EXPORT_SOURCE_SCENE`, and `IKKOKU_SAVE_SCENE` to files written by an earlier headless IK app capture, rather than to game data.
