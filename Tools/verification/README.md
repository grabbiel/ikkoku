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

The app checks the capture variables it receives before any work and exits 1 on an invalid combination (A06; see [capture request validation](../../docs/guides/build-and-test.md#capture-request-validation)). `test_run.py` keeps the lanes within those rules: each `app-smoke` check selects at most one capture mode, and `IKKOKU_NATIVE_PLUGIN_REPORT` or `IKKOKU_APPLICATION_FOCUS` appears only with `IKKOKU_AUTOCAPTURE`. It also requires the app's `CaptureRequest` inventory to name exactly the `IKKOKU_*` variables the app reads.

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
| `app-smoke.json` | Debug `xcodebuild` build (built binary hashed as artifact), headless Mute-startup app capture (its plugin report and Maker PNG hashed as artifacts; the app accepts the adapter report only with `IKKOKU_AUTOCAPTURE`, A06), then two ordered checks: `studio-inspector-capture` runs the Debug app expecting the source-pose report and hashes both the UI PNG and that report, so an exit-0 run that leaves either missing or empty fails (A-T05); `studio-inspector-validate` runs `Tools/verification/checks/studio_inspector_report.py` against that JSON. Three Release guards follow (R6, 2026-10-23): `build-release-app` builds the Release app with the CI release-package flags, but signed. `release-startup-capture` then renders one bundled Maker frame with that build, with `IKKOKU_SOURCE_TREE_FALLBACKS=0` and no fixtures, and hashes the PNG. `engine-release-frame-ring` runs the FrameRing Engine tests with `swift test -c release` | Debug build passes; `startup-mute-capture` skips (3 plugin fixtures absent locally); `studio-inspector-capture` and `studio-inspector-validate` pass when PR #5 UI report hooks are merged (report confirms `SourcePoseInspector observed == expected`), but fail with a clear missing-report result on this branch without PR #5, as stated in their tolerance text. The lane has not been rerun since A-T05 (2026-10-23) added the PNG and Mute-report artifacts, or since A06 added the Mute check's `IKKOKU_AUTOCAPTURE` (without it the app never exited, so the check could only time out). Release guards, 2026-10-23 (Xcode 27.0 / Swift 6.4), run outside the full lane: with the fix, `build-release-app` and `release-startup-capture` passed 2/2 under `--strict`. The PNG sha256 was `1cf309e14a1e…` and the capture took 1.0 s. `engine-release-frame-ring` passed 4/4 tests in 195.6 s, including the cold optimized build. Negative controls: the smoke check run on the unfixed Release binary of main `87cf261` exited −11 (SIGSEGV). The optimized test run with the unfixed `FrameRing.swift` ended with signal 10 inside `frameRingArrayAllocationReachesAThrowingCallerWithoutAnError`. |
| `studio-scenarios.json` | Thirty-nine `app-smoke` checks, each running the Debug app binary with `IKKOKU_STUDIO_SCENARIO` pointed at one scenario JSON under `Tools/verification/scenarios/` (see below) | 2026-10-22: the full 39-check run passed 39/39 with `--strict` (0 failed, 0 skipped; clean merge commit `e650c5a`, 1,321.5 s), including the two new CharaStudio-authored fixture checks `route-children-motion` (`IKKOKU_ROUTE_CHILDREN_SCENE`) and `neck-target-orbit` (`IKKOKU_NECK_TARGET_SCENE`). The lane was rerun after each later merge of main. Clean merges `12af3cc` and `4b39282` passed 39/39. Clean merges `a1e591c` and `a44e6c2` (main `4263de3`) passed 37/39. In each of those runs, two checks were killed by an outside SIGTERM: exit −15 with empty logs. The cause was another session running `pkill -x Ikkoku` while its own app runs were in progress. The killed checks were `route-children-motion` and `neck-look-orbit`, then `neck-look-orbit` and `color-visual-reset`. Both pairs passed a 2/2 `--strict` rerun on the same commit. Earlier, 2026-10-17: the full 34-check run passed 31 and failed three synthetic imports (0 skipped); pinning their optional Maker library off resolved all three in a 3/3 strict rerun, with fixtures unchanged. The shape/color visual checks passed 45/45 and 31/31 steps. Historical: 32/32 checks passed 2026-10-01 (including the four `charastudio-*` export checks whose PNGs the CharaStudio reload probe loads) with `IKKOKU_SOURCE_AVATAR` (+`IKKOKU_STUDIO_ITEM_CATALOG` for props, +`IKKOKU_STUDIO_ANIMATION_CATALOG` for the animation/FK scenarios, +`IKKOKU_STUDIO_LOOK_SETTINGS` for the eye/neck look scenarios, +`IKKOKU_STUDIO_HAND_PATTERNS` for `hand-patterns`) supplied; every save/import-side check fills `IKKOKU_SOURCE_SCENE` through the fixture `from` key: the seven character scenarios (including `undo-props` and the catalog-less `undo-no-catalog`) and the two look scenarios (`eye-look-orbit`, `neck-look-orbit`) from `IKKOKU_STUDIO_SCENARIO_SCENE` (`koikatu_cs0002591.png`), the camera scenarios (`camera-*`, `undo-camera`, `reload-save-camera`) alias `IKKOKU_SOURCE_SCENE` from `IKKOKU_CAMERA_OBJECT_PROBE_SCENE` (scene-x), the route scenarios (`route-play-state`, `undo-route`, `reload-save-route`) from `IKKOKU_ROUTE_PROBE_SCENE` and the live-clock scenarios (`blink-toggle`, `hand-patterns`, `hand-patterns-kept` — a single character with saved hand patterns [5, 6]) from `IKKOKU_STUDIO_SCENARIO_SYNTHETIC_SCENE` (`synthetic-current.png`); the three `reload-load-*` checks declare no scene fixture on purpose (see below); every scenario report and exported scene hashed as an artifact. Earlier run: 12/12 passed 2026-09-29 before the reload pairs were added. |
| `maker-scenarios.json` | Four `app-smoke` checks, each running the Debug app binary with `IKKOKU_MAKER_SCENARIO` pointed at one `maker-*.json` scenario under `Tools/verification/scenarios/` (see below) | 4/4 checks passed 2026-09-29 under `--strict` with `IKKOKU_MAKER_SCENARIO_CARD` (the 7-coordinate `synthetic-appearance-card.png`) and `IKKOKU_SOURCE_AVATAR` in the environment file; every check fills `IKKOKU_SOURCE_CARD` through the fixture `from` key; every scenario report and exported card hashed as an artifact. |
| `gameplay-scenarios.json` | One `app-smoke` check running the Debug app binary with `IKKOKU_GAMEPLAY_SCENARIO` pointed at `scenarios/gameplay-controlled-event.json` (A-T01; see below); no fixtures, synthetic catalog; the report and the three host snapshots are hashed artifacts | Not run yet (2026-10-23). The Engine test `sourceGameplayHostShippedScenarioPersistsReloadsAndResumesIdentically` runs the same scenario in CI; the app path is only compiled there. |

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
rig frame under a label for a later `fk`/`from` compare), `captureObject`
`{key,name}` (memorizes one object's world position under a label for a later
`position` compare; it reads `StudioModel.sourceObjectWorldMatrix`, the same
placement walk `refresh()` renders with, so a route child follows its route's
`childRoot`),
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
matched to a number), `position` `{key,from,within?}` (the object's world
displacement from a `captureObject` label: by default it must have MOVED
further than the tolerance; with `within` it must still sit within that bound,
and the failure names the distance and the current position), `eyeLook`
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
pair pins). The two CharaStudio-authored fixture scenes (see "Route children and
neck TARGET/AWAY" below) arrive the same way: `route-children-motion` aliases
`IKKOKU_SOURCE_SCENE` from `IKKOKU_ROUTE_CHILDREN_SCENE` and
`neck-target-orbit` from `IKKOKU_NECK_TARGET_SCENE`.

```sh
# Build Debug first, then (needs the 13 private fixture paths — scenario
# scene, avatar, item catalog, animation catalog, look settings, hand patterns,
# Maker library, camera probe scene, route probe scene, synthetic scene, the
# CharaStudio FK scene and the route-children / neck-target scenes — in
# .local/verification/environment.json):
python3 Tools/verification/run.py \
  --manifest Tools/verification/lanes/studio-scenarios.json \
  --environment .local/verification/environment.json --strict
```

A declared `artifacts` entry is hashed only AFTER the run — an artifact
the check never produced (or an empty or oversized one) FAILS the check, e.g.
`studio-inspector-capture` while the PR #5 hooks are absent, or
`build-debug-app` if the build itself fails.

### Route children and neck TARGET/AWAY (ST-T11, ST-T07)

Neither claim had a scene to run against until the original CharaStudio
authored two from the synthetic fixture card (`original_scene_reload_probe.py
--author-character … --author-scenes route-children,neck-target`; see
[the fixture-scene section](../../docs/reference/studio/scene-editing.md#charastudio-authored-route-children-and-neck-targetaway-fixtures)).
Their private paths go in the environment file as
`IKKOKU_ROUTE_CHILDREN_SCENE` and `IKKOKU_NECK_TARGET_SCENE`.

`route-children-motion.json` (lane check `studio-scenario-route-children-motion`,
24 steps; scene plus `IKKOKU_SOURCE_AVATAR`) runs on route key 0, which is saved
playing and looping over four points. Its children are folder key 9 and the
fixture female key 10; the female renders on the route, but its document entry
is a placeholder. The scenario asserts the route plays and the route-character
diagnostic. It captures both children with `captureObject` and advances 2 s.
Both must have moved, and each `assertRejected` "held within 0.5" control must
fail. The folder must move more than 0.1 m in a further 0.5 s. `toggleRoute`
then stops the route, and both children must sit within 1e-5 of their start
(point 0) and stay there through a 2 s advance. After export → reimport the
route reads back stopped, and the children still hold within 1e-5 after another
2 s.

`neck-target-orbit.json` (lane check `studio-scenario-neck-target-orbit`, 28
steps; scene plus `IKKOKU_SOURCE_AVATAR` and `IKKOKU_STUDIO_LOOK_SETTINGS`)
asserts the "Neck look override live: TARGET|AWAY" diagnostics and that both
characters' eyes are TARGET-type. After a 3 s advance it captures hair-front
bone 100 (`cf_J_hairF_00`) on key 0 (neck TARGET) and key 147 (neck AWAY), the
bone a yaw visibly moves. It orbits +60° (`dx` 1.0471976 rad), advances 3 s,
then orbits to −60° and advances 3 s. Every movement claim is an
`assertRejected` "held within" control:

- TARGET moves more than 0.05 m from front to +60° and more than 0.1 m from +60°
  to −60°.
- AWAY moves more than 0.15 m on each leg, and at −60° it is back within 0.01 m
  of its front pose.
- At both sides, AWAY's bone sits more than 0.15 m from TARGET's in the rig
  frame.

After export → reimport the live diagnostics return. A further 3 s advance holds
both bones within 0.01 m of their pre-export poses, with the document camera
still at −60°. Without `IKKOKU_STUDIO_LOOK_SETTINGS` the scenario fails 12 of
28 steps. The four live-diagnostic asserts, both eye-look asserts and all six
movement controls fail, and bone 100 stays inside every "held within" bound.
The check therefore cannot pass on the animated pose alone (evidence:
`.local/vm-fixture-scenes/controls/neck-target-nolook-report.json`). Speed and gaze magnitudes against the
original are recorded in the reference section, not asserted here.

Recorded 2026-10-18: a two-check manifest cut from the lane ran `--strict` on the
Debug build of this change and passed 2/2. The route scenario passed 24/24
steps. After 2 s both children sat 1.2051 m from their starts, at (1.2, y,
−0.1111). The folder then moved 0.3333 m in the next 0.5 s, and every hold was
within 1e-5. The neck scenario passed 28/28. Front to +60°, TARGET's bone moved
0.0877 m and AWAY's 0.2380 m. From +60° to −60° they moved 0.1575 m and
0.2364 m. At +60° and −60° the AWAY–TARGET separations were 0.2084 m and
0.1940 m. Recorded 2026-10-22, after merging main (`a596fcf`): the complete
39-check lane passed 39/39 with `--strict` and 0 skipped on the clean merge
commit `e650c5a`. Both new checks reproduced every number above, with 24/24 and
28/28 steps. They did so again in every later full run, through merge
`a44e6c2` (main `4263de3`). The external SIGTERM kills in two of those runs are
recorded in the lane row above. After the later main merges `29a3bfb`,
`9ee757a` and `735105f`, the two new checks were rerun on their own and reproduced
the same numbers. Attempts cut short by the same outside kill were retried. These are headless model and live-tick checks. The visible route
buttons, the rendered pixels and the FK-owned neck case remain separate gates.

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

## Gameplay scenario hook (A-T01)

When the app starts with `IKKOKU_GAMEPLAY_SCENARIO` set, `AppState` runs the
named `SourceGameplayHostScenario` (`Tools/verification/scenarios/gameplay-*.json`,
resolved against the repo root) through the native gameplay host right after
capture-request validation, before the engine and the editors exist, and exits
itself (0 when every step passed, 1 otherwise). `IKKOKU_GAMEPLAY_SCENARIO_REPORT`
is required and names the JSON report (`steps`, `reloads`, `trace`, `finalState`,
`passed`, `failed`, `saveFormat`). The scenario holds a synthetic `catalog`
(fixed-event table, ADV programs, map names), a `start` (weekday, opening flag,
map, heroines, frame duration) and `steps`. Ops: `perform` (`operation`:
`nextPeriod`, `changePeriod` + `period`, `changeWeek` + `week`, `nextWeek` +
`plus`, …), `run` (`until`: `idle`, `eventRunning`, `mapLoading`, `barrier`),
`reload` (optional `path` under `.local/verification/`: the snapshot is written
there through the checked writer and the host resumes from the file read
back) and `assert` (`period`, `week`, `savedWeek`, `activeMap`,
`completedEvents`, `runningEvent`, `idle`). The first failing step stops the
run; later steps are reported as not run. Snapshots are native host state
(`ikkoku.native-gameplay-host`), not original saves.

```sh
# Build Debug first; no environment file or private fixture is needed.
python3 Tools/verification/run.py \
  --manifest Tools/verification/lanes/gameplay-scenarios.json --strict
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

## Release bundle inspector (T-T02)

```sh
python3 Tools/verification/inspect_app_bundle.py \
  .local/build-release/Build/Products/Release/Ikkoku.app \
  --report .local/verification/reports/release-bundle.json
```

`inspect_app_bundle.py` is stdlib-only and checks a built `.app` against
`app-bundle-rules.json`, the reviewed list of what a Release bundle must and
must not contain. Each rule states its reason. It reads the bundle, and runs
`git ls-files`, `rev-parse` and `status` in `--checkout` (default: this
repository). It never launches the app. Any error finding gives exit 1; no
error gives 0, and invalid arguments or rules give 2.

| Check | Fails when |
| --- | --- |
| Required resources | `IkkokuShaders.metallib` (with its `MTLB` signature), `catalog.json` or `Assets.car` is missing or empty, or a model, mask or texture that `catalog.json` references is not under `Contents/Resources` (bare texture names resolve under `Textures/`, as in `AssetLibrary.texture`) |
| Identity and architecture | Info.plist's executable, identifier or package type differ from the rules, or any Mach-O file lacks an `arm64` slice (`arm64e` alone does not count) |
| Provenance | A file is neither a declared build product nor a git-tracked `Assets/` file at the path Xcode copies it to (an `explicitFolders` subfolder keeps its path; anything else lands directly in `Resources`), a membership-exception fixture ships, a tracked asset is absent, or a symlink leaves the bundle. A tracked asset whose bytes differ from the checkout is only a warning |
| Private content | A `.local`, build/cache or original-installation path component (`abdata`, `BepInEx`, `Managed`, `UserData`, `decompiled`, `reverse` and others); repository source (`.swift`, `.c`, `.h`, `.metal`, `.py` and others; the first CI Release build found the whole Engine package, tests and fixtures included, under `Contents/Resources/Engine/`); recovered source (`.cs`, `.il`, `.csproj`, `.shader`); a managed assembly by name or PE header; a Unity asset bundle by name or `UnityFS`-style signature; a mod archive; Python bytecode; a PNG with bytes after `IEND`; or a card/scene keyword |
| Build-machine paths | `/Users/`, `/home/`, `/private/var/folders/`, `/Volumes/`, `.local/` or the checkout root appear in Info.plist, a text resource, a PNG text chunk or a GLB JSON chunk |

Compiled build products (the executable, metallib and `Assets.car`) are not
failed for path strings. Their counts are recorded under `pathReferences`. The
Swift 5 app target's `#file`/`#filePath` strings embed the checkout path in the
executable. Image data and GLB binary chunks are not scanned, because random
bytes can contain any short sequence.

The report records the tool and rules hashes, the checkout revision and dirty
flag, a bundle tree hash, Info.plist version keys (including
`LSMinimumSystemVersion`), executable architectures, each required file's
hash, catalog reference counts, every file with its size, hash and class
(`build-product`, `tracked-asset`, `excluded-asset`, `unexpected` or `symlink`),
and the findings. The rules target the Release product. A Debug build fails as
`unexpected-file` on its `Ikkoku.debug.dylib` and preview dylibs.

`test_inspect_app_bundle.py` runs in the `runner-self-tests` check with synthetic
bundles only. It also checks that `explicitFolders`, the excluded fixtures,
the product name and the bundle identifier match `Ikkoku.xcodeproj`, and that
every reference in the checked-in `Assets/catalog.json` is a tracked asset.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request to `main`, every push to
`main` and on manual dispatch. It runs four jobs on GitHub-hosted `macos-26`
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
- `release-package` (T-T02) runs `doctor.py --require app-build`, then builds
  `IkkokuCreator` in the Release configuration, unsigned and `ARCHS=arm64`,
  from the clean checkout. It zips the app with `ditto` and extracts it into
  `$RUNNER_TEMP`, outside the checkout. It then runs the
  [release bundle inspector](#release-bundle-inspector-t-t02) on that copy and
  uploads the JSON report as the `release-bundle-report` artifact. The job
  never launches the app. Its first dispatched run (2026-10-23) found the whole
  Engine package under `Contents/Resources/Engine/`, 247 files. Once the app
  target stopped synchronizing `Packages/`, runs 39888875495 and 39889709790
  passed with 207 files, 0 errors and 0 warnings.
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
