# Manifest-driven verification lanes

Reviewed 2026-09-26 (T-T04 / E-T03 / CMT-11). Run every command from the
repository root. `Tools/verification/run.py` is a stdlib-only Python runner:
it executes the checks declared in a lane manifest, parses per-test results,
and writes one JSON report under the git-ignored `.local/` tree. It never
starts a CI job, downloads anything, or runs commands through a shell.

## Standalone Metal derivative diagnostic

`metal_derivative_repro.swift` is an asset-free numerical investigation for
[#188](https://github.com/grabbiel/ikkoku/issues/188), separate from the lane
runner and application. It requires macOS, the Swift SDK and a Metal device;
it reads no original assets or environment fixtures. Build and run its CPU
layout, literal mip-texel and floating-point classification checks first:

```sh
mkdir -p .local/metal-derivative-repro
swiftc -O Tools/verification/metal_derivative_repro.swift \
  -o .local/metal-derivative-repro/probe
.local/metal-derivative-repro/probe --self-check
# Run only with exclusive access to shared app/GPU validation resources:
.local/metal-derivative-repro/probe \
  --output .local/metal-derivative-repro/run-1 --repeats 4
```

The output directory must not exist, and its parent must exist. Collection
creates seven 128×128 cases: a large continuous quad, the same region split
into 2-pixel triangles with continuous UVs, and identical small-triangle
geometry with discontinuous per-triangle UVs, followed by translated and
sheared copies of the discontinuous grid. Both copies shift by (5/16, 3/16)
screen pixels; the sheared copy additionally applies `x += (y - 64) * 3/16`
using the original screen position. UVs, primitive order, depth and clip `w`
remain unchanged. Two further copies of the sheared grid multiply the complete
clip position by factors 0.5/1/2: a common factor per triangle in one case and
a different factor at each vertex in the other. Projected geometry, NDC depth
and ordered UVs stay fixed while the latter adds perspective interpolation.
Eight CPU-authored sRGB8 mips
are uploaded once and checked unchanged after all draws. Every draw preserves
color0 and records UV, derivatives, sampled RGBA and primitive ID in three
additional float32 attachments. Compilation uses the default Metal language
version and disables fast math, matching the options of the investigated
translated path; the effective version and device are reported.

`report.json` identifies the executable, shader, vertices, mips and raw outputs
by SHA-256. Full-plane raw files use tightly packed rows: color0 is RGBA8 sRGB;
color1 is float32 `(u, v, dU/dx, dV/dx)`; color2 is float32
`(dU/dy, dV/dy, primitiveID + 1, valid)`; color3 is sampled float32 RGBA.
All float words are native little-endian on supported Apple hardware.
Attachments clear to zero. A CPU union of the generated triangles at pixel
centers determines each draw's expected coverage; GPU validity and alpha must
match it at every pixel. Each `*-coverage.raw` stores that union as one 0/1 byte
per pixel. The original large quad has a literal 4,096-pixel check. Inclusive
edge tests suffice for these opaque fixtures, whose external boundaries avoid
pixel centers; they do not implement Metal's general edge-ownership rules.
Per-case repeats compare bit changes and finite numerical differences
separately, retain unchanged nonfinite values as errors, and report overlap
with color changes. Analytic affine-gradient errors are diagnostics with no
new tolerance or parity gate.

The UV reference independently projects in Double, computes screen
barycentrics and evaluates `sum(lambda * UV / w) / sum(lambda / w)`. Triangle
coefficients are cached once. `maximumAbsRationalUVError` reports the difference
at pixel centers, conditioned on the GPU-reported primitive ID, without a new
tolerance. Literal fractions, endpoint values and unchanged geometry/depth
checks validate the reference. `maximumAbsAnalyticGradientError` is JSON null
when vertex `w` varies inside a triangle; the tool does not equate an analytic
local derivative to Metal's hardware derivative operation. Raw derivative
repeat comparisons remain available for every case.

Exit zero means collection completed; inspect `renderingStable` in the report
for the numerical result. Nonfinite visible values retain the report and
produce exit one. A stable synthetic case does not prove the recovered shader
stable, and extra MRT outputs can perturb compilation. This tool measures no
performance and changes no production sampler, source gate or rendering path.
Keep invocation/source/compiler provenance alongside each retained report.

## Standalone Metal quad-merge reproducer

`metal_quad_merge_repro.swift` is the asset-free reproducer for the cause of
[#188](https://github.com/grabbiel/ikkoku/issues/188) (see
[renderer.md](../../docs/reference/renderer.md#cause-and-correction-cross-primitive-derivative-quads-2026-10-25)).
It reads no original assets, fixtures or environment variables and writes
nothing; the JSON report goes to standard output.

```sh
mkdir -p .local/metal-quad-merge
swiftc -O Tools/verification/metal_quad_merge_repro.swift -o .local/metal-quad-merge/probe
.local/metal-quad-merge/probe --self-check
.local/metal-quad-merge/probe --repeats 6 > .local/metal-quad-merge/report.json
```

Two 128×128 grids share their vertices: 16×16 cells of 6 px (512 triangles)
and 96×96 cells of 0.75 px (18,432 triangles). Clip `w` is 1 and every
position is a multiple of 1/256 px, so `u` is affine inside each triangle;
`u` is hashed per vertex (`k/64`), so neighbouring triangles have different
gradients. Each grid is drawn indexed (shared vertices) and non-indexed
(expanded per triangle), with blending off and on (one/zero, as every
translated pipeline enables blending), with no discard, a discard on an
interpolated attribute, or a discard on a texture sample taken after the
derivatives, and with or without a vertex-stage device store guarded by
`vid == 0xffffffff`. No discard is taken and the store never runs. The
fragment writes `dfdx(u)`, `dfdy(u)` and the primitive ID to one float32
target.

Per case, `pixelsWithAnotherTrianglesDerivatives` counts covered pixels whose
derivatives differ from their own triangle's analytic window-space gradient
(tolerance 1e-4, relative above 1), and `repeatChangedPixels` counts pixels
that change from the first draw in each repeat. `--self-check` verifies the
grid literals and layouts without creating a Metal device. Exit zero means
collection completed; whether a GPU forms derivative quads across primitives is
driver behaviour, not a Metal contract. The tool measures no performance.

## Usage

```sh
# Public lane — safe without any private data:
python3 Tools/verification/run.py --manifest Tools/verification/lanes/public.json

# Private-source lane — the one Engine-suite check declares 61 fixture
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
| `private-source.json` | One `engine-source-suite` check declaring every `IKKOKU_*` variable gated in `Packages/Engine/Tests` except `…_OUTPUT/_REPORT/_RESULT`, `IKKOKU_SAVE_SCENE` and `IKKOKU_EXPORT_SOURCE_SCENE` — all marked `optional` so the suite runs with whatever exists | 2026-10-23 (local-wave-verify; macOS 27.0.1, Xcode 27.0 / Swift 6.4; `.local/verification/environment.json`, 80 keys): on `66852dd` (main `134936c` merged), the non-strict run passed 1/1. Engine reported 711 tests: 709 executed and passed, 0 failed, and 2 named skips (`IKKOKU_APPEARANCE_REFERENCE_ROOT` with a Metal device, and the optional `IKKOKU_CARD_EDIT_OUTPUT` evidence). Under `--strict` it fails 0/1 before running, because `IKKOKU_APPEARANCE_REFERENCE_ROOT` is unset. With that variable set to `.local/reverse`, it still fails 0/1 with "fixture malformed or unreadable" ("fixture tree exceeds entry bound"). The test reads `rigs/` and `male/` under that root, which hold 528 MiB and 156 MiB, more than the runner's tree bounds of 4,096 entries and 512 MiB allow (open finding). On `2e732b9` (main `5e86b57`) the non-strict run reported 692 tests: 690 passed and the same 2 skips. Earlier: Runs with or without an environment file; unsupplied fixtures are recorded per check and only fail under `--strict`. With 32 local fixtures supplied on the integrated tree, Engine runs 379 tests: 359 passed, 20 named skips (via PR #4), 0 failed. |
| `maker.json` | Seven Swift `--filter` checks over converted Maker/card/material data plus `card_roundtrip.py` / `maker_roundtrip.py` audits | 2026-10-23 (local-wave-verify; macOS 27.0.1, Xcode 27.0 / Swift 6.4; `.local/verification/environment.json`, 80 keys): on `2e732b9`, `--strict` gave 6/9. The 6 Swift checks passed with 47 executed tests. Three checks failed, all open findings: `source-card-appearance` (`IKKOKU_APPEARANCE_REFERENCE_ROOT` unset, see `private-source`); `card-roundtrip-audit` (`IKKOKU_MANAGED_RECOVERY_EXPORT` is unset, because no managed recovery export was found to point it at); and `maker-roundtrip-audit`, which exits 1 with "Evidence output must remain under ignored .local". That last one has two causes: its argv passes neither `--inputs` nor `--output`, so the declared `IKKOKU_MAKER_COMPLETION_INPUTS` fixture is unused; and in a worktree whose `.local/reverse` is a symlink, the default output resolves outside `.local`. Run by hand from the main checkout with `--output` under `.local/local-wave-verify/`, it succeeded on the same inputs (SHA-256 `e9ccf7b4…`). Earlier: 6 checks pass (47 executed tests) and 3 skip: one Swift check skips because `IKKOKU_APPEARANCE_REFERENCE_ROOT` exceeds the 512 MiB hash bound when supplied; both roundtrip audits declare their real prerequisites (`IKKOKU_MANAGED_RECOVERY_EXPORT`, `IKKOKU_MAKER_COMPLETION_INPUTS`) as fixtures and skip with named reasons while absent — nothing shipped here fails on the reference machine. |
| `app-smoke.json` | Debug `xcodebuild` build (built binary hashed as artifact), headless Mute-startup app capture (its plugin report and Maker PNG hashed as artifacts; the app accepts the adapter report only with `IKKOKU_AUTOCAPTURE`, A06), then two ordered checks: `studio-inspector-capture` runs the Debug app expecting the source-pose report and hashes both the UI PNG and that report, so an exit-0 run that leaves either missing or empty fails (A-T05); `studio-inspector-validate` runs `Tools/verification/checks/studio_inspector_report.py` against that JSON. Three Release guards follow (R6, 2026-10-23): `build-release-app` builds the Release app with the CI release-package flags, but signed. `release-startup-capture` then renders one bundled Maker frame with that build, with `IKKOKU_SOURCE_TREE_FALLBACKS=0` and no fixtures, and hashes the PNG. `engine-release-frame-ring` runs the FrameRing Engine tests with `swift test -c release` | 2026-10-23 (local-wave-verify; macOS 27.0.1, Xcode 27.0 / Swift 6.4; `.local/verification/environment.json`, 80 keys): `--strict` gave 6/7 on `2e732b9` and again on `3f58ff8` (main `f5587f5` merged, with the A-T04 fix). The passing checks: `build-debug-app`, `studio-inspector-capture`, `studio-inspector-validate`, and the three Release guards, `engine-release-frame-ring` taking 237.6 s. `startup-mute-capture` exits 1 before it captures, with `studio execution failed: IKKOKU_SOURCE_PLUGIN_PROFILE=…/native-adapter-capture-01/profile.json: Invalid translated plugin: Original plugin target does not bind uniquely.` The profile `environment.example.json` names binds `StudioMotionFixture` to source object key 10, and the check loads no source scene, so nothing can bind (open finding; the Mute behavior itself is checked by the A-T04 probe). Earlier: Debug build passes; `startup-mute-capture` skips (3 plugin fixtures absent locally); `studio-inspector-capture` and `studio-inspector-validate` pass when PR #5 UI report hooks are merged (report confirms `SourcePoseInspector observed == expected`), but fail with a clear missing-report result on this branch without PR #5, as stated in their tolerance text. The lane has not been rerun since A-T05 (2026-10-23) added the PNG and Mute-report artifacts, or since A06 added the Mute check's `IKKOKU_AUTOCAPTURE` (without it the app never exited, so the check could only time out). Release guards, 2026-10-23 (Xcode 27.0 / Swift 6.4), run outside the full lane: with the fix, `build-release-app` and `release-startup-capture` passed 2/2 under `--strict`. The PNG sha256 was `1cf309e14a1e…` and the capture took 1.0 s. `engine-release-frame-ring` passed 4/4 tests in 195.6 s, including the cold optimized build. Negative controls: the smoke check run on the unfixed Release binary of main `87cf261` exited −11 (SIGSEGV). The optimized test run with the unfixed `FrameRing.swift` ended with signal 10 inside `frameRingArrayAllocationReachesAThrowingCallerWithoutAnError`. |
| `studio-scenarios.json` | Eighty-four `app-smoke` checks, each running the Debug app binary with `IKKOKU_STUDIO_SCENARIO` pointed at one scenario JSON under `Tools/verification/scenarios/` (see below) | 2026-10-26 (r7k-swiftui-select, R7 phase 2, item 7): the two kept-view checks, `inspector-kept-views` and `inspector-kept-route`, brought the lane to 84 checks. Before them, the three [inspector UI checks](#inspector-ui-checks-r7-phase-2-item-7), `inspector-edit-deselect`, `inspector-hidden-route` and `inspector-hide-cycles`, brought the lane to 82 checks. 2026-10-26 (sta11c-map34, ST-A11 slice 3): `studio-scenario-source-map34` (`source-map34.json`, see [source maps](#source-maps-st-a11)) brought the lane to 79 checks (78 on `main` `4d60b73`). On the Debug build of `e7ac998` (`main` `4d60b73` merged), with the slice-3 export and `IKKOKU_STUDIO_MAP34_SCENE`, the full lane passed 79/79 under `--strict` under the app lock (0 skipped, 1,251.8 s), and `maker-scenarios` passed 10/10 (199.8 s). 2026-10-25 (sta11a-maps, ST-A11/ST-B03/ST-T04): the four [source map](#source-maps-st-a11) checks, `source-map`, `reload-save-source-map`, `reload-load-source-map` and `source-map-none`, brought the lane to 77 checks. On the Debug build of `ceccafa` (main `74cee1c`), the full lane passed 77/77 under `--strict` under the app lock (0 skipped, 1,228.3 s), and `maker-scenarios` passed 10/10 (204.6 s). On the merged head `c094f92` (main `6502803`, #275 live pacing), it passed 77/77 (0 skipped, 1,254.5 s), and `maker-scenarios` passed 10/10 (238.7 s). 2026-10-25 (stt11k-route-edit, ST-T11/ST-T03): four route-editing checks, `route-edit-export`, `route-children-edit`, `route-children-edit-load` and `route-move-playing` (see [route points and settings](../../docs/reference/studio/scene-editing.md#route-points-and-settings-st-t11-st-t03)), brought the lane to 72 checks; with main's `background-build` (R7 phase 2, item 6) it has 73. On the Debug build of `565040d` (main `2dc317f`), the full lane passed 72/72 under `--strict` under the app lock (0 skipped, 1,706.2 s), and `maker-scenarios` passed 10/10 (198.1 s). On the merged head `bfd6dd5` (main `ca17d8a`), it passed 73/73 (0 skipped, 1,193.2 s), and `maker-scenarios` passed 10/10 (204.5 s). 2026-10-24 (r7d-live-tick, R7 phase 2, item 3): `studio-scenario-live-step-edit` (`live-step-edit.json`, see [Edits during an off-main live step](#edits-during-an-off-main-live-step-r7-phase-2-item-3)) brought the lane to 53 checks. On the Debug build of `e69a3c0` (main `b23383b` merged), the full lane passed 53/53 under `--strict` under the app lock (0 skipped, 1,284.2 s), and `maker-scenarios` passed 5/5 (84.3 s). 2026-10-23 (local-wave-verify; macOS 27.0.1, Xcode 27.0 / Swift 6.4; `.local/verification/environment.json`, 80 keys): the full 47-check lane passed 47/47 under `--strict` (0 skipped, 1,571.7 s) on the Debug build of `2e732b9` (main `5e86b57` merged), including `reload-save-ik` and `reload-load-ik`. 2026-10-23 (local-wave-verify): the native IK reload pair `reload-save-ik`/`reload-load-ik` brought the lane to 47 checks (see [Native IK re-solve and unsolved status](#native-ik-re-solve-and-unsolved-status-r4-115-and-110)); a two-check cut passed 2/2 `--strict`. Before that, 2026-10-23: the mirrored-camera slice added `mirrored-camera` (`IKKOKU_MIRRORED_CAMERA_SCENE`), giving 45 after merging main. Before that merge its branch had 40 checks, and the full strict run on the Debug build of `6270e82` passed 40/40 (1,368 s; see [Mirrored camera parent](#mirrored-camera-parent-r4-st-a06)). On the merge with main `8d83f01` (`aa3c1cd`, 45 checks) the full strict run under the app lock passed 45/45 (0 skipped, 1,567.6 s), with `mirrored-camera` at 17/17. Earlier, 2026-10-23: merging the two CharaStudio-authored fixture checks from #111 brought the lane to 44. 2026-10-22: the five clothes-state/accessory checks were added, giving 42 checks before that merge (see [Clothes state and accessory visibility](#clothes-state-and-accessory-visibility-st-c03-second-slice)). On the Debug build of this change the complete lane passed 42/42 with `--strict` (0 skipped) and `maker-scenarios` passed 4/4. On the final merged head (with main at 9caa3f3), the full strict run passed 41/42. The one failure, `face-shape`, was terminated from outside the runner (SIGTERM: exit −15 after 0.6 s). A strict rerun passed 1/1, and `maker-scenarios` again passed 4/4. Earlier post-merge runs lost `blink-toggle`, `eye-look-orbit`, `neck-look-orbit` and `reload-save-clothes` the same way, and each passed when rerun. On the fixture-scenes branch (39 checks before this slice): 2026-10-22: the full 39-check run passed 39/39 with `--strict` (0 failed, 0 skipped; clean merge commit `e650c5a`, 1,321.5 s), including the two new CharaStudio-authored fixture checks `route-children-motion` (`IKKOKU_ROUTE_CHILDREN_SCENE`) and `neck-target-orbit` (`IKKOKU_NECK_TARGET_SCENE`). The lane was rerun after each later merge of main. Clean merges `12af3cc` and `4b39282` passed 39/39. Clean merges `a1e591c` and `a44e6c2` (main `4263de3`) passed 37/39. In each of those runs, two checks were killed by an outside SIGTERM: exit −15 with empty logs. The cause was another session running `pkill -x Ikkoku` while its own app runs were in progress. The killed checks were `route-children-motion` and `neck-look-orbit`, then `neck-look-orbit` and `color-visual-reset`. Both pairs passed a 2/2 `--strict` rerun on the same commit. 2026-10-17, before the outfit slice brought the lane to 37 checks: the full 34-check run passed 31 and failed three synthetic imports (0 skipped); pinning their optional Maker library off resolved all three in a 3/3 strict rerun, with fixtures unchanged. The shape/color visual checks passed 45/45 and 31/31 steps. Historical: 32/32 checks passed 2026-10-01 (including the four `charastudio-*` export checks whose PNGs the CharaStudio reload probe loads) with `IKKOKU_SOURCE_AVATAR` (+`IKKOKU_STUDIO_ITEM_CATALOG` for props, +`IKKOKU_STUDIO_ANIMATION_CATALOG` for the animation/FK scenarios, +`IKKOKU_STUDIO_LOOK_SETTINGS` for the eye/neck look scenarios, +`IKKOKU_STUDIO_HAND_PATTERNS` for `hand-patterns`) supplied; every save/import-side check fills `IKKOKU_SOURCE_SCENE` through the fixture `from` key: the seven character scenarios (including `undo-props` and the catalog-less `undo-no-catalog`) and the two look scenarios (`eye-look-orbit`, `neck-look-orbit`) from `IKKOKU_STUDIO_SCENARIO_SCENE` (`koikatu_cs0002591.png`), the camera scenarios (`camera-*`, `undo-camera`, `reload-save-camera`) alias `IKKOKU_SOURCE_SCENE` from `IKKOKU_CAMERA_OBJECT_PROBE_SCENE` (scene-x), the route scenarios (`route-play-state`, `undo-route`, `reload-save-route`) from `IKKOKU_ROUTE_PROBE_SCENE` and the live-clock scenarios (`blink-toggle`, `hand-patterns`, `hand-patterns-kept` — a single character with saved hand patterns [5, 6]) from `IKKOKU_STUDIO_SCENARIO_SYNTHETIC_SCENE` (`synthetic-current.png`); the three `reload-load-*` checks declare no scene fixture on purpose (see below); every scenario report and exported scene hashed as an artifact. Earlier run: 12/12 passed 2026-09-29 before the reload pairs were added. |
| `maker-scenarios.json` | Four `app-smoke` checks, each running the Debug app binary with `IKKOKU_MAKER_SCENARIO` pointed at one `maker-*.json` scenario under `Tools/verification/scenarios/` (see below) | 2026-10-23 (local-wave-verify; macOS 27.0.1, Xcode 27.0 / Swift 6.4; `.local/verification/environment.json`, 80 keys): 4/4 under `--strict` (52.0 s) on `2e732b9`. Earlier: 4/4 checks passed 2026-09-29 under `--strict` with `IKKOKU_MAKER_SCENARIO_CARD` (the 7-coordinate `synthetic-appearance-card.png`) and `IKKOKU_SOURCE_AVATAR` in the environment file; every check fills `IKKOKU_SOURCE_CARD` through the fixture `from` key; every scenario report and exported card hashed as an artifact. |
| `gameplay-scenarios.json` | One `app-smoke` check running the Debug app binary with `IKKOKU_GAMEPLAY_SCENARIO` pointed at `scenarios/gameplay-controlled-event.json` (A-T01; see below); no fixtures, synthetic catalog; the report and the three host snapshots are hashed artifacts | 2026-10-23 (local-wave-verify; macOS 27.0.1, Xcode 27.0 / Swift 6.4; `.local/verification/environment.json`, 80 keys): 1/1 under `--strict` on `2e732b9` (main `5e86b57`, 17 steps). Then 1/1 on `66852dd` (main `134936c`, with the G-T02 scenario): 20 of 20 steps, 4 reloads, `completedEvents` `[9001]`. The Engine test `sourceGameplayHostShippedScenarioPersistsReloadsAndResumesIdentically` runs the same scenario in CI, where the app path is only compiled. |

## Combined local continuation (2026-10-23)

The performance, expression and skirt work is integrated on
`codex/continue-claude-2026-10-23`. Measurement runtime `dffc9df` builds in Debug and
Release. Later `83cb84b` changes skirt setup only, and `c5822a8` adds a fixture
assertion. Results below supersede the historical lane counts above for this
branch; they do not close unrelated missing-fixture findings.

- The full private Release Engine/CoreMath suite reports 739 tests: **736
  executed and passed, 0 failed, 3 named skips** (opt-in expression timing,
  opt-in card-edit output, absent appearance reference root). Timing then ran
  separately three times. The lane remains non-strict because the appearance
  reference root is absent; no required fixture test silently passes.
- The full Release Studio lane gives **51/52**, followed by **2/2** for the
  corrected skirt save/load pair. Thus all **52 unique scenarios** pass across
  the two runs, with no tolerance changes. The first failure used an unavailable
  saved animation; the corrected setup selects and freezes available T-pose
  `[0,0,0]` and declares the catalog in both checks.
- Maker app scenarios pass **4/4**, gameplay **1/1**. App-smoke is **6/7** across
  the original run and an isolated successful Release-build retry. The retry
  resolves concurrent DerivedData access; the remaining failure is the known
  startup-Mute profile binding source object 10 without loading its scene.
- Verification Python tests pass **180/180**. Focused exporter, dynamics oracle
  and original-reload tooling pass **56/56** using
  `.local/reverse/unitypy-venv/bin/python` (the older `venv/` path lacks NumPy).

Reports under `.local/verification/reports/` are
`codex-integrated-{engine-release,studio-release,skirt-corrected,other-apps}.json`
and `codex-release-build-retry.json`. App checks use private manifest copies
that select Release and hold the shared app lock. Initial skirt failure output
is retained separately under `.local/codex-resume-2026-10-23/integration/skirt-initial/`.
See [performance acceptance](../../docs/reference/performance.md#combined-integration-acceptance-2026-10-23)
for executable hashes, equivalent-output controls and unresolved orbit pacing.

## Source Expression controls (ST-C04)

Three additional Studio checks cover the Face tab's shared model entry point:
`expression-edit`, `reload-save-expression` and `reload-load-expression`. They
require the existing scenario scene, source avatar, Maker library and Studio look
settings fixtures. Native reload runs in a fresh process without a source scene
environment variable. The lane now contains 56 checks, including the two skirt save/load checks, `live-step-edit` and the three half-state checks.

The fixed 512×512 scene framing shows key 65's eyebrow/eye area but crops its
mouth, so the mouth-only pattern and openness checks use fully visible key 0.
Pixel assertions retain the >2/255 visible-change threshold and exact RGBA8
restore checks. The composite edit/export uses all 11 fields on key 65. Tears,
cheek and lip-sync have explicit unsupported-render diagnostics; blink uses the
existing clock observation and an FK-owned neck edit must be refused unchanged.
See the [contract and evidence](../../docs/reference/studio/scene-editing.md#source-face-state-editing-st-c04).

The combined Release run passes 83/83 edit, 6/6 save and 8/8 load steps. Actual
Face-inspector editing, Undo, Redo and Reset were checked separately. The
original-player comparison accepts all 308 serialized-field claims; the final
export's scene body matches that input exactly, with only its thumbnail changed.
These results do not claim unsupported tears, cheek, gag-eye or voice-lip-sync
visual parity. PR #135 adds a cross-format regression: save an edited character
hidden, load in a fresh app process, export/reimport the original format, then
reload native state for the existing Reset/Undo assertions. The old Release
binary fails at export; the export-local preview fix passes without introducing
hidden-character work into live frames. The runner requires this specific load
check to verify both format boundaries, preserving native-only rules for every
other reload pair. The final save/load pair passes **7/7 and 16/16** steps,
and the edit scenario again passes **83/83**.

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
`hoverGizmo` `{key,bone,axis}` (the asynchronous gizmo hover, R7 phase 2,
item 5: finds that rotate ring's pixel like `dragGizmo` and a pixel off the
gizmo, calls the REAL `mouseMoved` in three sequences (on, off, on; off; on,
off), settles the hover picks in flight after each with the call a click
makes, and checks that the highlighted axis is that of the last position, as
the synchronous pick reads it, both in the model and in the frame's
highlighted gizmo batches; the pick counters must show the coalesced moves
and the dropped stale results),
`backgroundBuild` `{build:"import"|"importTwice"|"importThenNewScene"|"importWhileHidden"|"loadRoute"}`
or `{build:"duplicate"|"duplicateWhileHidden"|"duplicateRoute"|"duplicateRouteWhileHidden"|"outfit"|"outfitWhileHidden"|"export",key}`
(`export` and `loadRoute` also take a `path` under `.local/verification/scenario-exports/`) (R7 phase 2, item 6: interactive runs build source
characters off the main thread, while scenarios build them synchronously. The
op runs the operation synchronously first, then with background builds through
the app's own methods, pumps the main run loop until no import or character
build is pending, and requires the document summary — tree labels, kinds,
names, parents, visibility, diagnostics, status, character outcome and source
runtime counts — and a 512² render to be byte-identical. `import` checks the
single completion; `importTwice` starts a second import before the first
commits and accepts only the second's completion; `importThenNewScene` cancels
with New Scene and requires no completion and an empty document; `duplicate`
duplicates the keyed object, then undoes, and each side must have built at
least one character in the background. `duplicateRoute` duplicates the keyed
route with its character: the synchronous Duplicate, Undo and Redo are the
reference for the background ones, the Duplicate must build no route
character preview on the main thread, and a Duplicate undone before its copy's
build lands must leave nothing pending and match the synchronous Undo; the
Redo must build no route character preview on the main thread either.
`outfit` (third part) selects the keyed character's next outfit through the
Clothes tab's picker (`selectSourceOutfit`; the card must save three): until
the build lands the character keeps its outfit and the picker shows the one
chosen; then it must match the synchronous selection with one undo step, and
its Undo the synchronous Undo. Superseded selections must install once,
choosing the shown outfit again must drop the build, and an Undo during a
build must drop it. `export` saves and reloads the scene as a native
document, so the keyed character (hidden, with a face edit, by the steps
before) has no preview; the background export must start in the background,
leave the document and render unchanged and write the synchronous export's
bytes; an edit while its baselines build must fail it with a scene-changed
error, and a load must cancel it with a replacement error, each writing
nothing (the op removes every file it wrote).
`loadRoute` saves the scene as a native document to `path` and loads it over
New Scene: the synchronous Load, Undo and Redo are the reference, the Load
and Redo must build no route character preview on the main thread, and an
Undo, or a second Load, before the route characters land must match too with
nothing left pending. The `WhileHidden` builds hide the
Studio while the builds land, as a switch to the Maker does, with an empty
frame standing in for the Maker's on the shared renderer: that frame must
still be current when the Studio shows again and refreshes. Live animation is
paused for the op, and the build progress line must be gone afterwards),
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
toggle's property; its didSet forwards to every rendered preview),
`addCharacter` `{sex:"female"|"male"}` (the toolbar's Add ▸ Character button),
`setIKEnabled` `{character,chain,on}` and `setIKTarget`
`{character,chain,axis,delta|value}` (the Pose tab's IK toggle and Target row:
`delta` is one Stepper click, `advanced(by:)`, and `value` types the component;
both call the same `StudioModel` setter as the row), `captureIKPose`
`{character,chain,name}` (memorizes the rendered chain under a label),
`setShowSourceMap` `{on}` (View ▸ Show Source Map, ST-A11; runtime only). The
native IK ops address a NATIVE character by its object name, because an added
character has no source key; `chain` is an `IKChain` raw value such as
`hand_L`. `export`/`reimport`
`{path}`, `saveDocument`/`loadDocument` `{path}` (native save/load of a
Studio document card) and `assert` with any of `name`, `visible`,
`face`/`body`
`{index,value}`, `color` `{id,rgba}`, `activeCamera` (key or null),
`routePlaying` `{key,playing}`, `view` `{saved:true}` or `{key}` (the camera
`StudioModel.viewCamera` hands the renderer: exactly the saved `doc.camera`,
or looking through that camera object — position within the tolerance of its
world placement from `sourceObjectWorldMatrix`, forward within 0.01°, and not
the saved camera; a pass records the view's position and forward),
`ik` `{character,chain,enabled?,target?,solved?,reachesTarget?,from?,within?}`
(one native chain: the document target the Target row shows, with `null` to
skip a component; whether the frame builder's `ikFailures()` solves it; the
end's root-space distance to the target; and, against a `captureIKPose` label,
the largest quaternion-component difference of its three bones and largest
joint displacement — moved beyond the tolerance by default, or within `within`;
the pose read is `CharacterInstance.currentPose()` of the rendered instance),
`statusContains` (a substring of the app's status line, read after the step's
`view` check so a rejected look-through has reported itself),
`indicatorContains` (a substring of the view indicator under the status line,
`StudioModel.activeSourceCameraView`; with no source camera active it is empty
and contains nothing), `treeLabel` with `key` (the object's workspace tree
label, `StudioModel.workspaceLabel`, which the tree rows display), `animation`
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
absent hands are not asserted), `sourceMap`
`{none?,map?,draws?,lightmappedDraws?,loading?,lineContains?,lineAbsent?,pickNothingAt?,pickSomethingAt?}`
(ST-A11: the imported scene's map as the render path sees it,
`StudioModel.sourceMapCensus()`; `none` asserts no map request, draws or
line; `lightmappedDraws` counts draws with the baked-lightmap material; each `pickNothingAt`/`pickSomethingAt` point is two viewport
fractions, origin top-left, and must pick id 0 / a nonzero id — see
[source maps](#source-maps-st-a11)),
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

### Clothes state and accessory visibility (ST-C03 second slice)

`setClothesState` `{key,index,state,errorContains?}` calls
`StudioModel.setSourceClothesState`, the method behind the Clothes inspector's
per-row state pickers. `index` is CharaStudio's row: 0 top … 6 socks, 7 shoes
(kind 7, which the rule mirrors to kind 8). `state` is 0 on, 1 half, 2 half 2
or 3 off; a state the garment does not allow advances the way
`ChaControl.SetClothesState` does. `setAccessoryVisible`
`{key,index,on,errorContains?}` calls `StudioModel.setSourceAccessoryVisible`
for accessory slot `index`. `setShoesType` `{key,state,errorContains?}` calls
`StudioModel.setSourceShoesType` (the Clothes tab's Indoor/Outdoor picker;
`state` 0 indoor, 1 outdoor). With `errorContains` each op must be refused
with that fragment, and the document's
`sourceClothesState`/`sourceShowAccessory`/`sourceShoesType`, the preview
instance and its wear must stay unchanged.

`assert`/`assertRejected` accept
`clothes: {key,state?,saved?,rendered?,accessories?,accessoriesOff?,edited?,fallbacks?,diagnosticContains?,shoesType?,savedShoesType?,drawn?,bodyAlpha?}`,
read from the live preview:

- `state` is the applied nine-kind state, and `saved` is the card's
  `Status.clothesState`.
- `rendered` lists the clothing kinds with at least one drawn renderer.
- `accessories` / `accessoriesOff` list the saved accessory slots drawn and
  hidden.
- `edited` says whether the document carries a wear override.
- `shoesType` / `savedShoesType` are the applied and the card's saved shoes
  type.
- `drawn` lists exactly the drawn clothing renderers by source mesh name
  (`o_top_tsyats_b/0`), without the assembly's `clothes-<kind>/` prefix.
- `bodyAlpha` is the `ChangeAlphaMask` pair the body renders with.
- `fallbacks` is the number of undrawable-state diagnostics.
- `diagnosticContains` must match one wear diagnostic.

Each report line also gives the loaded state, `shoesType` and the body-mask
pair.

The checks:

- `clothes-saved-off.json` (24 steps) is the import-defect control.
  - Key 0 (saved all off) must draw none of its assembled garments, and key
    65 must draw all three. Forcing key 0's top, bottom and shoes rows on must
    change at least 10,000 pixels, and three undos must restore the
    saved-state render exactly.
  - The saved-state export must equal the initial source SHA before and after
    reimport.
  - The top-on export must differ, and after reimport key 0 must read and
    render `[0,3,3,3,3,3,3,3,3]` as its saved state.
- `clothes-toggle.json` (31 steps) works on key 65.
  - Out-of-range state and row requests must be refused unchanged.
  - Top off must change at least 5,000 pixels; unchanged-render controls must
    fail through `assertRejected`. Undo and redo must be exact.
  - Half on the unconverted reference top must render the dressed frame
    exactly and report that the half state cannot be rendered.
  - Back to saved, the export must equal the source SHA before and after
    reimport. The top-off export must reimport as saved state
    `[3,0,0,0,0,0,0,0,0]` and reproduce the top-off render exactly.
- `accessory-toggle.json` (34 steps) needs `IKKOKU_STUDIO_ACCESSORY_SCENE`, a
  scene whose key 10 wears a converted accessory in slot 0 (glasses) and
  converted top and bottom. It is aliased into `IKKOKU_SOURCE_SCENE` through
  `from`.
  - Toggling an empty slot must be refused. Hiding slot 0 must change at least
    100 pixels, with undo and redo exact.
  - On the converted garments, a `StateType` 1 bottom's half request must
    advance to off. Since the third slice the top's half draws the converted
    `o_top_tsyats_b` with body mask (0,1) and no fallback, changing at least
    2,000 pixels from the bottom-off capture. The shoes row must mirror to
    kind 8, and the gloves row (not a state kind there) must be refused.
  - After restoring, the export must equal the source SHA before and after
    reimport. The glasses-off export must reimport with slot 0 hidden as the
    card's saved state.
- `reload-save-clothes` / `reload-load-clothes` are the usual native save/load
  pair; the load side declares no scene fixture. The fresh process must load
  key 65 top off and key 0 top on beside the cards' unchanged saved bytes. An
  edit there must change the render, and undo must restore the loaded frame
  exactly.

All five declare `IKKOKU_SOURCE_AVATAR` and `IKKOKU_MAKER_LIBRARY`. Their
garment lists and pixel counts depend on the selected assembly: the converted
library supplies the catalog rows (`StateType`, `Coordinate`, `NotBra`,
`HideShorts`) that decide each kind's states.

Recorded 2026-10-22, on the Debug build of this change, the five checks passed
24/24, 31/31, 34/34, 7/7 and 8/8 steps:

- Key 0 forced on changed 17,024 pixels (maximum delta 140).
- Key 65 top off changed 10,762 pixels (maximum delta 125).
- The glasses toggle changed 239 pixels (maximum delta 96).
- The converted bottom going off changed 10,562 pixels.
- Every exact comparison had 0 differing pixels and channel delta 0.
- Restored exports kept SHA-256 `029f0b1d…` (character scene) and `a7366df3…`
  (accessory scene).

These are headless model calls and production renders. The visible pickers,
toggles and CharaStudio reload remain separate gates.

### Half-state meshes and indoor shoes (ST-C03 third slice)

Three checks follow `reload-load-clothes`. They need
`IKKOKU_STUDIO_HALF_STATE_SCENE`, a Studio scene built from the
original-player wear probe's fixture card
(`Tools/reverse/studio_selection_fixture.py --card`; key 10 wears top
105-38, bottom 106-1, pantyhose 110-1, indoor shoes 112-2 and outdoor shoes
112-3 in saved state `1,1,0,0,0,1,0,0,0` with `shoesType` 0), aliased into
`IKKOKU_SOURCE_SCENE`, plus `IKKOKU_SOURCE_AVATAR` and an
`IKKOKU_MAKER_LIBRARY` that converts the half-state set:

- `half-state.json` (42 steps): the saved half states must draw exactly
  `o_top_tsyats_b`, `o_bot_pants01_b`, `o_panst_00_b` and the uwabaki with
  body mask (0,1) and no fallback. Top, bottom and pantyhose on must change at
  least 2,000, 100 and 3,000 pixels and draw the `_a` meshes; `shoesType` 1
  must swap in the outdoor shoes (at least 300 pixels). Undo and redo are
  exact. Editing back to the half states and indoor shoes must clear the edit
  and export the source SHA; the changed export must differ and reimport
  with clothes state all on and `shoesType` 1 saved.
- `reload-save-half-state` / `reload-load-half-state`: a top-on,
  outdoor-shoes edit (at least 2,000 pixels) survives a native save and a
  fresh process; turning the top back to half there changes at least 2,000
  pixels, and undo restores the loaded frame exactly.

Recorded 2026-10-24 on the Debug build of this change: 42/42, 8/8 and 7/7
steps. Top on changed 3,499 pixels, bottom on 134, pantyhose on 5,844 and
`shoesType` 1 604; the save-side edit changed 4,107; every exact comparison
had 0 differing pixels and channel delta 0. The restored export kept SHA-256
`510e6af7…fa1e`, and the changed export differs from the source body in four
bytes (three `clothesState` bytes and `shoesType`).

No `studio-scenarios` check reads the environment file's own `IKKOKU_SOURCE_SCENE`
(the `app-smoke` and `private-source` lanes use it for a different
scene). Each check aliases it through the fixture `from` key instead.
The seventeen character scenarios (`visibility-folder`, `rename-folder`,
`face-shape`, `color-edit`, `item-props`, `undo-props`, `undo-no-catalog`,
`animation-select`, `fk-edit`, `fk-mouse-drag`, `shape-visual-reset`,
`color-visual-reset`, `outfit-select`, `reload-save-outfit`,
`clothes-saved-off`, `clothes-toggle`, `reload-save-clothes`) take
`IKKOKU_STUDIO_SCENARIO_SCENE`, which must be the scene whose object
keys they address (`koikatu_cs0002591.png`: keys 0, 65 and 622);
`animation-select`, `fk-edit` and `fk-mouse-drag` additionally require
`IKKOKU_STUDIO_ANIMATION_CATALOG` (set at import, it lets
`setAnimation` validate and resolve the selected clip; `fk-mouse-drag`
needs it only to import the same scene state `fk-edit` edits). The two visual
reset scenarios, the three outfit checks and the five clothes/accessory checks
additionally require `IKKOKU_MAKER_LIBRARY`; their pixel and color results
depend on the selected assembly. `accessory-toggle` takes its scene from
`IKKOKU_STUDIO_ACCESSORY_SCENE` instead (see above). The synthetic `blink-toggle`,
`hand-patterns` and `hand-patterns-kept` checks explicitly set
`IKKOKU_MAKER_LIBRARY=none`: their minimal cards exercise playback, not converted
hair/clothes, and must not inherit a developer’s optional assembly library.

`koikatu_cs0002591.png` has neither a camera nor a route-bearing object, so the six
camera/route scenarios take a probe scene: `camera-load-winner`,
`camera-deactivate`, `camera-rename` and `undo-camera` run against the
two-active-camera scene-x (`IKKOKU_CAMERA_OBJECT_PROBE_SCENE`),
`route-play-state` and `undo-route` against the scene with two
saved-active routes (`IKKOKU_ROUTE_PROBE_SCENE`). The `reload-*`
scenarios run as ordered save→load pairs (`test_run.py` pins the
adjacency): `reload-save-props`/`reload-save-camera`/`reload-save-route`/`reload-save-outfit`/`reload-save-clothes`/`reload-save-half-state`
take the same scene as their character/camera/route/outfit/clothes/half-state counterparts and
`saveDocument` a native card under `.local/verification/scenario-exports/`,
and the `reload-load-*` check immediately after each one loads that card
back. The load-side checks deliberately declare NO scene fixture: with
`IKKOKU_SOURCE_SCENE` set, startup's own import would reseed the runtime
caches and the load asserts would pass vacuously; without it the process
starts on the empty document and only `loadDocument` + rehydration can
produce the asserted cache entries (that is exactly the ST-T01 defect the
pair pins). The three CharaStudio-authored fixture scenes (see "Route children and
neck TARGET/AWAY" and "Mirrored camera parent" below) arrive the same way:
`route-children-motion` aliases `IKKOKU_SOURCE_SCENE` from
`IKKOKU_ROUTE_CHILDREN_SCENE`, `neck-target-orbit` from
`IKKOKU_NECK_TARGET_SCENE` and `mirrored-camera` from
`IKKOKU_MIRRORED_CAMERA_SCENE`.

```sh
# Build Debug first, then (needs the 15 private fixture paths — scenario
# scene, avatar, item catalog, animation catalog, look settings, hand patterns,
# Maker library, camera probe scene, route probe scene, synthetic scene,
# accessory scene, the CharaStudio FK scene and the route-children /
# neck-target / mirrored-camera scenes — in .local/verification/environment.json):
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

### Native IK re-solve and unsolved status (R4, #115 and #110)

The R4 checklist items for native characters were mouse-only: a dragged IK
handle re-solves (#115), and a degenerate target names the unsolved chain in
the status line and keeps the pose (#110). The scenario hook now reaches the
same `StudioModel` methods the Pose tab calls: `addCharacter(sex:)`,
`enableIK(_:on:)`, and `setIKTarget(_:_:position:)`, which the Target row's
binding now calls too. It reads the rendered instance, `selectedInstance`'s
`currentPose()` and `ikFailures()`, which `refresh()` hands the document's
targets on every edit.

`reload-save-ik.json` (lane check `studio-scenario-reload-save-ik`, 36 steps)
imports `koikatu_cs0002591.png`, runs `newScene` and adds a native female
("Hana"). It captures her Left hand chain before IK (`fk`), turns Left hand
IK on, which places the target at the hand, and captures the solved chain
(`solved`). Then:

- The end reaches the target within 1 mm.
- One Stepper click (+0.02 on X) moves the chain (an `assertRejected` control
  shows it no longer matches `solved` within 1e-6). One click back must
  reproduce `solved` within 1e-6, both in quaternion components and in joint
  metres. The bound allows the Float32 round trip `x + 0.02 − 0.02` to land one
  ulp off; the solve is a pure function of the pre-IK pose and the target.
- Typing X = 1e20 must leave the chain unsolved. The status line must contain
  "Left hand IK left unsolved: ", and the chain must match its pre-IK capture
  `fk` within 1e-6: `solveIK` keeps a failed chain's rotations. Before the edit,
  an `assertRejected` control shows the status did not already say so; after
  it, one shows `solved: true` is rejected.
- Typing X = 0.3 must solve again within 1 mm, and the result must differ from
  `solved` (control). The status line must no longer contain "IK left
  unsolved" (`assertRejected`) and must read "Left hand IK solved again."
- `saveDocument` writes `.local/verification/scenario-exports/reload-save-ik.png`.

The steps after the save leave the saved card alone. They check that two
chains are reported and cleared independently, and that the report clears
only its own message:

- Right hand IK is turned on, then both hands' X are typed as 1e20. The status
  line must read "Left hand IK left unsolved: IK reach is not finite. · Right
  hand IK left unsolved: IK reach is not finite.", and the right hand must be
  unsolved.
- Typing the left hand's X as 0.3 solves it within 1 mm. The status line must
  contain "Right hand IK left unsolved: IK reach is not finite." but not "Left
  hand IK left unsolved" (`assertRejected`), and the right hand must still be
  unsolved (`assertRejected` on `solved: true`).
- `addCharacter` adds the default male ("Kai"), which writes "Added Kai". One
  Stepper click on the left hand's X rebuilds the frame with the right hand
  still unsolved; the status must still contain "Added Kai". Before this
  change the frame builder re-wrote the IK message on every rebuild.
- Typing the right hand's X as −0.3 solves it within 1 mm. The status must
  still contain "Added Kai", since the report no longer owns the line, and
  must not contain "IK left unsolved" (`assertRejected`).

Status ownership (`StudioIKStatusReport` in
[StudioStatusText.swift](../../Packages/Engine/Sources/Studio/StudioStatusText.swift)).
`refresh()` collects every native character's unsolved chains, in document
order and then `IKChain` order, and hands them to the report with the current
status. The report writes the status line only when a chain fails that was not
failing before, or fails for a new reason. An unchanged set of failures writes
nothing, so a status written since is not overwritten on the next rebuild.
When chains solve again, the report narrows its message to the chains still
unsolved, or writes "<chains> IK solved again.", but only while the status line
still shows the report's own message. If none of the recovered chains is still
enabled (IK turned off, character deleted), it writes "Ready". The character
is named ("… left unsolved on Hana: …") only when the unsolved chains belong to
more than one character. `swift test --package-path Packages/Engine --filter
StudioStatusTextTests` covers these rules, including two characters.

Why a failed chain shows its pre-IK pose. `CharacterInstance` solves IK from
the FK pose on every rebuild, and `solveIK` keeps a refused chain's FK
rotations. That pose is a function of the document alone: the FK pose, the
targets and the card. The alternative, keeping the last solved pose, would
depend on edit history. It would differ between a chain typed straight to an
unreachable target and one dragged there through reachable targets. It would
also not survive save/load, because the document stores targets, not solved
rotations: a loaded card has no last solved pose to keep. So the failed chain
keeps the pre-IK pose, and the status line says why.

`reload-load-ik.json` (`studio-scenario-reload-load-ik`, 7 steps) loads that
card in a fresh process with no import. Left hand IK must be on with target X
0.3, solve within 1 mm, and show no unsolved status (control). Turning IK off
must leave the hand away from the target (control), and undo must restore the
reach.

Recorded 2026-10-23 on the Debug build of the change (`f402483` plus the
scenario edits, committed as `ddcbb2e`; app SHA-256 `23398e37…`), a two-check
manifest cut from the lane ran `--strict` and passed 2/2 (20/20 and 7/7 steps,
23.1 s):

- Enabling IK put the target at the hand, (0.42610925, 1.0355155, 0.16130337)
  in root space, and the end within 1.4e-7 m of it. The default pole moved the
  elbow by about 2.3 cm, from (0.31489, 1.15254, 0.02271) to
  (0.29778, 1.13831, 0.02626).
- +0.02 moved the chain by 0.0968 (quaternion) and 0.0242 m. −0.02 returned
  the target to the same float, 0.42610925, and the chain matched `solved`
  bit for bit (difference 0.0).
- At 1e20 the status read "Left hand IK left unsolved: IK reach is not
  finite." The arm matched the pre-IK `fk` capture bit for bit. That is the
  arm before IK, not the last solved arm, which had the elbow 2.3 cm away.
- At X = 0.3 the end sat 9.4e-8 m from the target. The status line still read
  "Left hand IK left unsolved: IK reach is not finite.", because the frame
  builder set the message on a failure and nothing cleared it after a later
  success. That finding is fixed and asserted; see the st-ux-ik-camera record
  below.
- The loaded card gave the same end position, 9.4e-8 m from the target. With
  IK off the hand sat 0.126 m away.

Mutation control: the pre-#115 update, which reads the lower bone's world
rotation after writing the upper bone, applied to `IK.swift` and rebuilt,
failed 4 of the save check's 20 steps. Those were the four reach asserts,
missing by 0.0161, 0.0220, 0.0742 and 0.0742 m. The round trip, unsolved and
pre-IK asserts still passed, because they do not depend on the lower-bone
formula. Evidence: `.local/local-wave-verify/ik-scenario/` (`run1/`,
`mutation/`). This is a headless model check. The handle drag and the visible
status bar stay manual, and only the Left hand chain of the default native
female is exercised.

Recorded 2026-10-23 (st-ux-ik-camera, Debug build of `34e3e4e`, app SHA-256
`149d8b0b…`): the full studio lane ran `--strict` and passed 52/52 (1,650.9 s),
with `reload-save-ik` at 36/36 and `reload-load-ik` at 7/7. Every number above
reproduced: the end within 1.37e-7 m of the target, the bit-identical round
trip, and at 1e20 the arm bit-identical to `fk`. At X = 0.3 the status line
read "Left hand IK solved again." With both hands at 1e20 it named both chains;
after the left hand's 0.3 it read "Right hand IK left unsolved: IK reach is not
finite." The right hand at −0.3 sat 1.44e-7 m from its target, and the status
line kept "Added Kai". Negative control: the same scenario on the Debug build
of the base, main `c3e83fa` (app SHA-256 `26c58b05…`), failed 6 of 36 steps.
These were the cleared-status pair after X = 0.3 (steps 18–19), the two-chain
message (26; the base names only the first unsolved chain), both "Added Kai"
asserts (33 and 36; the base re-wrote "Right hand IK left unsolved" over it),
and the last cleared-status control (35). Evidence: `.local/st-ux-ik-camera/lanes/` (`head-cut/`,
`base-control/`).

### Mirrored camera parent (R4, ST-A06)

The R4 app path "a source camera under a mirrored parent falls back to the
saved camera with a `reflectedFrame` message" had no scene to run against. The
original CharaStudio authored one without a card
(`original_scene_reload_probe.py --author-scenes mirrored-camera`; see
[Mirrored camera parent](../../docs/reference/studio/scene-records.md#mirrored-camera-parent-original-capture-r4)).
Its private path goes in the environment file as
`IKKOKU_MIRRORED_CAMERA_SCENE`.

`mirrored-camera.json` (lane check `studio-scenario-mirrored-camera`, 25
steps since st-ux-ik-camera, 17 before; scene plus `IKKOKU_SOURCE_AVATAR`)
runs on camera key 2 `IKKOKU-MIRROR` under item key 0 (scale (−1, 1, 1)),
saved active, and control camera key 3 `IKKOKU-CONTROL` under item key 1
(scale (1, 1, 1)). It asserts that camera 2 is the load winner, that `view`
is exactly the saved camera and that the status line contains "Source camera
"IKKOKU-MIRROR" (camera 2) view unresolved: Source camera object parent frame
is mirrored". An `assertRejected` control shows the view is not looking
through camera 2. `toggleCamera` 3 must look through camera 3, with
`assertRejected` controls that the view is no longer the saved camera and that
the status no longer names a mirrored frame. `toggleCamera` 2 falls back
again. After export → reimport camera 2 is still the winner and falls back,
and camera 3 still looks through. The label asserts are listed under "Source
camera labels" below.

Recorded 2026-10-23: a one-check manifest cut from the lane ran `--strict` on
the Debug build of this change (`31d4508`) and passed 17/17 steps. The saved
camera view was (1.1910985, 1.8764572, −3.0230198) looking
(−0.33037, −0.25882, 0.90767); camera 3 looked through from
(0.124513626, 0.95720124, 0.17588627), 1.2e-7 m and 2.2e-6° from its
placement. Mutation control: the same check against a copy of the scene whose
item 0 scale x was patched from −1 to +1 (byte offset 883,
`.local/vm-mirrored-camera/controls/`) failed 4 of 17 steps — the three
fallback/status asserts and the "not looking through camera 2" control —
because camera 2 then looks through from (−1.0754863, 0.95720124, 0.17588627).
The full studio lane (`studio-scenarios.json`, 40 checks, `--strict`) then
ran on the Debug build of `6270e82` and passed 40/40 in 1,368 s, with
`studio-scenario-mirrored-camera` at 17/17. After the merge with main
`8d83f01` (`aa3c1cd`, 45 checks) it passed 45/45 in 1,567.6 s, again with
17/17 here.
Evidence: `.local/vm-mirrored-camera/runs/`. This is a headless model check:
the visible status line and rendered pixels are not asserted, and the
original's own mirrored look-through pose is recorded, not reproduced.

#### Source camera labels (st-ux-ik-camera)

User finding, 2026-10-23: on this scene the tree named the cameras
`IKKOKU-MIRROR` and `IKKOKU-CONTROL`, the status line named camera 2 by its
key ("Source camera 2 view unresolved: …"), and the indicator under the status
line said "Viewing through source camera "IKKOKU-MIRROR"" while the view showed
the saved camera. The labels now come from one place,
`SourceStudioCameraLabel` in
[StudioStatusText.swift](../../Packages/Engine/Sources/Studio/StudioStatusText.swift),
and use the object's current name with the source key:

| Where | Before | After |
| --- | --- | --- |
| Tree row | `IKKOKU-MIRROR` | `IKKOKU-MIRROR` over a smaller `camera 2` line, so the 250 pt panel truncates a long name but never the key (one line read `IKKOKU-MIRROR (c…`). The active camera's line reads `camera 2 · active`, and its icon becomes `video.fill` while the view looks through it, or an orange `video.slash.fill` while it falls back (the tooltip says why). The row's title, which `treeLabel` asserts, is `IKKOKU-MIRROR (camera 2)` |
| Status line, fallback | `Source camera 2 view unresolved: …; using the saved camera.` | `Source camera "IKKOKU-MIRROR" (camera 2) view unresolved: …; using the saved camera.` |
| Status line, toggle | `Looking through source camera "IKKOKU-CONTROL".`, `Source camera "…" deactivated; …` | the same with ` (camera 3)` after the name |
| Indicator, looking through | `Viewing through source camera "IKKOKU-CONTROL" (runtime only)` | `Viewing through source camera "IKKOKU-CONTROL" (camera 3) (runtime only)` |
| Indicator, fallback | `Viewing through source camera "IKKOKU-MIRROR" (runtime only)` | `Saved camera shown: source camera "IKKOKU-MIRROR" (camera 2) has a mirrored parent` |
| Object tab, Camera section | `Source camera: IKKOKU-MIRROR`, `Active` | `Source camera: IKKOKU-MIRROR (camera 2)`; `Active: the view looks through this camera`, or `Active, but the saved camera is shown: this camera has a mirrored parent` with a `Deactivate` button |
| Orbit refused, fallback | `Viewing through source camera "IKKOKU-MIRROR"; deactivate it …` | `Source camera "IKKOKU-MIRROR" (camera 2) is active and the saved camera is shown; deactivate it …` |

A record without a name keeps the importer's "Source camera N", which already
carries the key, so its status line reads "Source camera N view unresolved" as
before. The three status asserts changed with the wording in the same commit.
New asserts: the indicator contains the "Saved camera shown" line at load,
after toggling back and after reimport, and an `assertRejected` control shows
it does not contain "Viewing through". With camera 3 the indicator contains
"Viewing through source camera "IKKOKU-CONTROL" (camera 3)", and a control
shows it does not contain "Saved camera shown". `treeLabel` asserts the tree
rows `IKKOKU-MIRROR (camera 2)` and `IKKOKU-CONTROL (camera 3)`. A last toggle
deactivates camera 3: a control shows the indicator is then empty, and the
last step asserts no active camera, the saved view and the status "Source
camera "IKKOKU-CONTROL" (camera 3) deactivated; orbit controls restored.".

Unrendered items: the importer still names an item record it cannot render
"Unrendered source item N". Where the converted catalog
(`IKKOKU_STUDIO_ITEM_CATALOG`) maps the item's key but its asset does not load,
the row now reads "<catalog name> (unrendered source item N)". Item records
carry no name of their own. The two items in this scene are catalog key
0/0/0, which the converted catalog does not map, so they keep "Unrendered
source item 0/1". Naming them would need the Studio item list extracted from
the game's info bundles (`Tools/reverse/catalog.py`), which this slice did not
do.

Recorded 2026-10-23 (Debug build of `c5b563c`): a private 8-step scenario
(`.local/st-ux-ik-camera/item-label/`, not a lane check because it needs a
synthetic catalog) ran this scene with a one-entry catalog that maps 0/0/0 to
"Test cube" in a missing package, and passed 8/8. Both item rows read "Test
cube (unrendered source item 0)" and "… 1)" before and after export →
reimport, and renaming camera 2 to "Renamed camera" changes both its tree
label, `Renamed camera (camera 2)`, and the indicator. Without the catalog,
the same scenario fails exactly the 3 item-label steps.

Recorded 2026-10-23 (Debug build of `34e3e4e`, app SHA-256 `149d8b0b…`):
the full studio lane passed 52/52 `--strict`, with `mirrored-camera` at 25/25
and the five camera checks (`camera-load-winner`, `camera-deactivate`,
`camera-rename`, `charastudio-camera-switch`, `undo-camera`) passing
unchanged; `maker-scenarios.json --strict` passed 5/5. The view positions
above reproduced exactly. The same scenario on the base build (`c3e83fa`)
failed 7 of 25 steps: the three fallback status asserts and the deactivate
status (old wording), and the three indicator `assertRejected` controls. The
base runner ignores the new keys, so the positive indicator and tree-label
asserts pass there trivially; the controls are what fail. Evidence:
`.local/st-ux-ik-camera/lanes/` (`head-full/`, `base-control/`).

Window captures (`IKKOKU_CAPTURE_UI` and `IKKOKU_AUTOCAPTURE`, 15 per build:
the source, native and mirrored Studio windows, two Maker windows and four
renders) of the base and the same HEAD build, taken back to back: all four
renders, all 15 UI reports and 9 of the 11 UI windows without a source
camera are byte-identical. The two mirrored-scene windows differ on purpose,
in the tree rows and the status area only. The native Object tab differed in
the Transform fields' text baselines: the base build draws those both ways,
and two more base runs matched HEAD's capture byte for byte. Crops:
`.local/st-ux-ik-camera/crops/` (`tree-before.png`, `tree-after.png`,
`status-before.png`, `status-after.png`); hashes in
`.local/st-ux-ik-camera/captures/{before2,after3,base-rerun1,base-rerun2}/summary.json`.

### Edits during an off-main live step (R7 phase 2, item 3)

`live-step-edit` (`IKKOKU_STUDIO_SCENARIO_SCENE`, the 7-character scenario
scene) covers what happens when an edit lands while the live step runs off
the main thread ([threading contract](../../docs/reference/renderer.md#studio-live-step-threads-r7-phase-2-item-3)).
Its `editDuringAdvance` op takes `edit`, one of:

- `none`;
- `move` with `key`: moves that character by 0.25 m in x through
  `StudioModel.update`;
- `setFK` with `key`, `bone` and `rotation`: the Pose tab's FK setter
  (`setSourceFKRotation`);
- `undo` or `redo`: the editor's own undo and redo.

The op runs these steps:

1. It starts one live step the way the timer does
   (`StudioModel.startLiveFrameAsTimer`). If that step ran serially on the
   main thread, the op fails.
2. It applies the edit while the step is in flight.
3. It completes the step the way its completion handler does
   (`completeLiveFrame`).
4. It captures the presented 512×512 render, rebuilds the same document at
   the same clock with `refresh()` on the main thread, and captures again.

The op passes when all of these hold:

- the clock advanced by exactly one 1/30 s step, compared bit for bit;
- the two renders are byte-identical;
- the presenting refresh reused exactly the step frames the contract
  allows: all of them without an edit, all but the moved character's after
  `move`, and none after `setFK`, `undo` or `redo`, which reach a preview.

The interleaving inside one step, meaning which worker finishes first, is
not controlled here. The Engine test
`sourceStudioEditDuringAParallelTickMatchesTheSerialOrder` compares the
parallel and serial call orders bit for bit. As a mutation control,
`FrameRequest.matches` was changed to ignore the world matrix. The `move` step
then failed: 39,828 pixels differed (max channel delta 182), and the refresh
reused 7 of 7 frames instead of 6.

### Source maps (ST-A11)

Five checks cover the map an imported scene names
([maps](../../docs/reference/studio/maps.md)). Each declares
`IKKOKU_STUDIO_MAP_CATALOG`, the converted map catalog; no other check
declares it, so the runner gives no other check a map.

- `source-map` (`IKKOKU_SOURCE_SCENE` from `IKKOKU_STUDIO_MAP_SHOWOFF_SCENE`,
  the showoff characters with Map 33 added by the original player; 15 steps).
  It runs these steps in order:
  1. Before the first step the map is already drawn: 8 draws, all 8 with the
     baked-lightmap material (`lightmappedDraws`, since ST-A11 slice 2), all 8
     images uploaded as BC blocks (`blockImages`, since slice 3), not
     loading. The status line holds the exact label `Map 33 空き部室 (bushitu):
     baked lightmaps; approximated: no realtime sun or its shadows, no specular
     or reflections, no normal, metallic or detail maps, no fog, no camera
     effects`. Two map-only points pick nothing, and a character in front of
     the wall picks.
  2. `setShowSourceMap` off draws 0 parts, and the line says `hidden (View ▸
     Show Source Map)`.
  3. With the map hidden, the original-format export is byte-identical to the
     source.
  4. On restores 8 draws. The export is byte-identical again.
  5. Reimporting that export, New Scene (no map, no line) and undo restore the
     map. A map pixel still picks nothing and the character still picks.
- `reload-save-source-map` (same fixtures) saves the scene natively. The map
  stays drawn with its lightmaps, and the save needs no scene-file
  rehydration.
- `reload-load-source-map` (only the avatar and the catalog) runs next. It
  loads that save in a fresh process. One rehydration rebuilds the map request,
  and the map draws again with its lightmaps, the same line and picks.
- `source-map34` (`IKKOKU_SOURCE_SCENE` from `IKKOKU_STUDIO_MAP34_SCENE`,
  Map 34 alone, moved, with the day sun, saved by the original player; 15
  steps) runs the same steps on map 34. The map is drawn before the first step:
  54 draws (30 lightmapped, 1 particle, 1 sky; `particleDraws`, `skyDraws`),
  54 images as BC blocks, and the exact label, `Map 34 空き教室 (akikyoushitu):
  baked lightmaps on 30 of 57 draws (the rest as items), cubemap sky,
  particles (no soft-particle fade or per-renderer sorting); approximated: …`.
  Two map points pick nothing. The View toggle hides and restores all 54
  draws, sky included. The exports are byte-identical, and reimport, New Scene
  and undo restore the map.
- `source-map-none` (`IKKOKU_STUDIO_SCENARIO_SCENE`, `koikatu_cs0002591.png`,
  which names no map) supplies the catalog. It asserts there is no map request
  or line before and after an original-format round trip, and that the export
  is byte-identical.

The first three need the slice-2 export of Map 33 (with lightmaps) behind
`IKKOKU_STUDIO_MAP_CATALOG`. With the first slice's export they fail on the
label and `lightmappedDraws`, which is the point: they pin the lightmapped
path. [Installing the slice-2 export](../../docs/reference/studio/maps.md#installing-the-slice-2-export)
gives the commands. Since slice 3, `source-map` and `source-map34` need the
slice-3 export (block images, and map 34), and `source-map34` needs
`IKKOKU_STUDIO_MAP34_SCENE` in the environment ([installing the slice-3
export](../../docs/reference/studio/maps.md#installing-the-slice-3-export)).

`sourceMap` asserts take `particleDraws`, `skyDraws` and `blockImages`, and
the report's detail line prints them with the sky cube bytes.

**Measurement switch.** `IKKOKU_SOURCE_MAP_DECODED_TEXTURES=1` makes a map
load decode its PNGs to RGBA8 (MetalKit mips) instead of uploading the
`ikkokuBlockImages` BC blocks. The load reads it once, and the default is
BC. It exists to measure the BC upload against the decoded path (memory,
load time, the map probe gates). No check sets it, and the census shows it
as `decodedImages` and `source decoded`.

### Inspector UI checks (R7 phase 2, item 7)

The checklist ops above call `StudioModel` with no window. A scenario whose
`steps` is empty and that has an `inspectorUI` object runs in the window
instead (`InspectorUIScenario`). Startup goes on, the editor is drawn, and
the steps run once the inspector is up. Every step starts a new undo
gesture, and SwiftUI commits it (0.3 s) before the next step. The ops are:

- `select` (`key`) and `deselect`;
- `focus` (`field`: `name`, or `vectorN`, the N-th Transform number field:
  position x, y, z, then rotation and scale) makes that visible text field
  the first responder;
- `type` (`text`, `replace`) inserts text through the field editor, as
  keystrokes do;
- `delete` (`key`) selects the object and deletes the selection, as the
  workspace's Delete does;
- `undo`, `redo`;
- `cycle` (`keys`, `count`) selects each key in turn; -1 clears the
  selection;
- `snapshot` keeps the document and the undo depths;
- `keyLoop` walks the Tab key-view loop and names each view. It checks
  `keyViews` (the loop's length) and `hiddenKeyViews` (views outside the
  visible window). Tabbing out of a Transform field can commit its rounded
  value, so a loop can push undo steps;
- `assert`: `name` and `positionX` of `key`'s object, `exists`, `undoCount`,
  `redoCount`, `unchanged` (since the snapshot), `editing` (a field editor is
  the first responder), `inspectorView`, and `axContains` and `axAbsent`.
  These two search the label, title and value of every accessibility element
  in the window. Each assert's detail also records what it saw, including
  the number and hash of those strings.

Added with the kept views, for the two checks below:

- `probe` (`field`) remembers a shown field and its centre;
- `press` (`label`) presses the accessibility element with that label or
  title, such as a section's disclosure triangle;
- `activateWell` activates the inspector's first visible colour well, and
  `closeColorPanel` closes the colour panel;
- `routePoint` (`index`) selects that point of the selected route;
- `assert` also takes `fieldText` (with `field`: the text that field shows),
  `activeWells` (active colour wells in the window), `probeHit` (a click at
  the probed centre reaches the probed field) and `probeFocusable` (the
  probed field can become the first responder; an accepted attempt is undone).

The three `studio-scenarios` checks pin what the inspector did before item 7
kept the Object tab mounted:

- `inspector-edit-deselect` (`IKKOKU_STUDIO_SCENARIO_SCENE`) covers Name and
  position x edits that are still in flight when the selection is cleared
  or the object deleted. Typing applies at once (`name 'Source character 0
  X'`, position x 1.5). Focusing a Transform field commits its displayed
  value: 0.13868962 becomes 0.139, one undo step. When the selection clears,
  the field leaves the window without the end-of-editing commit: 1.23456
  typed into a three-decimal field stays 1.23456 and adds no undo step. The
  window becomes the first responder, and later typing reaches nothing. The
  undo and redo depths and values are pinned through three undos.
- `inspector-hidden-route` (`IKKOKU_STUDIO_HALF_STATE_SCENE`: route 20,
  character 10, folder 11). Three selection cycles leave the document and
  the undo depths unchanged. The route section ("Add point", "Delete point",
  "Show line") is absent from the accessibility tree while the character is
  selected. Deleting the route, then undo, redo and undo, keeps it absent;
  selecting the route again shows it.
- `inspector-hide-cycles` (`IKKOKU_STUDIO_SCENARIO_SCENE`). Five cycles over
  keys 0, nothing, 963 and 622 leave the document and the undo depths
  unchanged. With a character, nothing, and folder 622 selected, the
  accessibility tree shows only that state's controls. The key-view loop
  has 12, 2 and 12 views, none outside the visible window.

On the Debug build of the capture-option commit (before any item 7 change),
all three passed (42/42, 24/24 and 15/15 steps).

Item 7 keeps the Object tab mounted while nothing is selected
(`ObjectInspector`, `StudioInspectorMounting`). On its Debug build the three
checks pass with the same values, undo and redo depths and key-view loops.
Their accessibility strings match the base too. The one exception is the
toolbar's "Mode" radio group, which shows up in some runs and not in
others, on either build. Two more checks cover what only kept views could
get wrong:

- `inspector-kept-views` (`IKKOKU_STUDIO_SCENARIO_SCENE`). While nothing is
  selected, the hidden Name field takes no click and refuses focus, later
  typing reaches nothing, the Tab loop has 2 views, and the accessibility
  tree has the placeholder but none of the tab's controls (not "Parent").
  When it is shown again, a field shows the document's value: "Source
  character 0 K" as typed, and "2.250" for position x 2.25 typed as "2.25",
  as a field built anew does. A collapsed Transform section stays collapsed
  from character 0 to character 963. Once nothing has been selected, it is
  expanded again. Folder 622 and character 0 have 12-view Tab loops, and five
  selection cycles leave the document and undo depths unchanged.
- `inspector-kept-route` (`IKKOKU_STUDIO_HALF_STATE_SCENE`). The route's
  "Line colour" well, active when the selection clears, is no longer active.
  A route point's position x, still being edited when the selection
  clears, is dropped without the end-of-editing commit. In both cases, the
  document and undo depths are unchanged and later typing reaches nothing.
  The route's labels ("Orient", "Ease", "Connection", "Parent") are absent
  from the accessibility tree while it is hidden.

`IKKOKU_PERF_KEEP_MOUNTED` (`off`, `tab` or `on`, default `on`) is a
measurement control only. The app reads it once at launch, `CaptureRequest`
accepts it only with `IKKOKU_PERF_TRACE`, and no lane sets it. `off` builds
and drops the inspector's views as before item 7. `tab` keeps the Object
tab, and `on` also keeps each kind's section.

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

### Composite colour-capture fixture

`IKKOKU_COMPOSITE_COLOUR_PROBE` (a directory, optional in `private-source.json`)
names a second controlled original capture for the native eye-white and iris
composites: its saved `fixture-card.png`, `frame.json`, the eye-white and iris
readbacks (`texture-20/21/24.rgba16f`), the card's own `supplement.json` and a
native store at `textures/manifest.json`. With it, together with
`IKKOKU_SHADER_BINDING_PROBE`, `IKKOKU_MAKER_LIBRARY` and
`IKKOKU_HEAD_MATERIAL_CONTRACT`, the gated
`liveSourceCompositesMatchTheDistinctColourCapture` composes the four eye
targets from the card alone and compares them with the readbacks. How the folder
is captured and rebuilt: [native eye-white composites](../../docs/reference/renderer.md#native-eye-white-composites-r1-2026-10-23).

`IKKOKU_GARMENT_COMPOSITE_PROBE` similarly names a distinct-colour original
normal-top capture containing `fixture-card.png`, `frame.json`, its readbacks
and `character-settings.tsv`. With the base probe, library, head contract,
supplement and native texture store,
`liveSourceNormalTopCompositeMatchesBaseAndDistinctOriginalColours` checks both
base and edited top targets, identity hashes, unchanged cache hits, recolour/revert
and released-target resource bounds. See [normal-top evidence](../../docs/reference/renderer.md#native-normal-top-composite-r1cmt-04-159-2026-10-24).

`IKKOKU_BOTTOM_COMPOSITE_PROBE` supplies the equivalent distinct-colour capture
for the normal bottom in clothing slot 1. Its three `bottomBaseColor` settings
leave the top unchanged; `captureBottomCompositeInputs` also records the catalog
main/mask inputs in `frame.json`. The gated
`liveSourceNormalBottomCompositeMatchesBaseAndDistinctOriginalColours` checks
the base and edited 512×1024 targets, exact input/program identities, unchanged
hits, recolour/revert and released-target bounds. The native store must contain
both bottom inputs; retained capture pixels are comparison data only.

`IKKOKU_INNER_SHOE_COMPOSITE_PROBE` names the distinct-colour inner-shoe
capture. Its three `innerShoeBaseColor` settings edit slot 7 only; Status and
outer slot 8 remain unchanged. `captureInnerShoeCompositeInputs` records the
active `ct_shoes_inner` catalog and direct `rendNormal01` target identity as well
as the BC7 main/RGB24 mask input readbacks. The gated
`liveSourceNormalInnerShoeCompositeMatchesBaseAndDistinctOriginalColours`
checks base and edited 512×512 targets, exact input/program identities, visible
slot selection, unchanged hits, recolour/revert and released-target bounds.
Only the base level has independent GPU readback evidence; ten generated
output mips and the single authored mip of each input remain separate checks.
Outer-shoe composition remains unsupported.

`IKKOKU_FACE_COMPOSITE_BASE_PROBE` and `IKKOKU_FACE_COMPOSITE_PROBE`
name a fresh original base/distinct skin-colour pair for female head 0,
exType 0, high detail. Each folder contains `fixture-card.png`, `frame.json`,
input readbacks and two independently read target files, before and after
the original `ReleaseFaceCustomTexture`. The probe temporarily retains creator
inputs before loading, checks catalog texture identity and the paint mask's
exported-material dependency, then restores the original retention flag.
This observation mode does not establish normal input lifetime or source cost.
Only the two decoded body skin RGB triples may change; the shared values also
affect body and eyeline shading. Other Custom fields, Coordinate and Status
remain unchanged. The gated
`liveSourceHeadZeroFaceCompositeMatchesBaseAndDistinctOriginalColours`
requires both target base levels to match within one byte after colour-space
conversion, exact program/input identity, unchanged hits, recolour/revert and
released-target resource bounds. Its 11 authored input mips and 11 output
levels are structural checks; independent original GPU readback covers level 0.
The native store must include the three face inputs and `create_head` program;
original readback pixels are comparison data only. Native live-slot coverage,
Release costs and default-off output are separate acceptance checks.

`IKKOKU_BODY_COMPOSITE_BASE_PROBE` and `IKKOKU_BODY_COMPOSITE_PROBE`
name a fresh original base/distinct pair for the ordinary female body,
exType 0, high detail, with no body paint or sunburn. Each folder contains
`fixture-card.png`, `frame.json`, three input readbacks and separate target
readbacks before/after `ReleaseBodyCustomTexture`. The source probe temporarily
retains creator inputs before loading and restores the flag afterward; this
observation mode does not establish default input lifetime or source costs.
Only nine decoded body RGB scalars (main skin, sub skin and nail) may change,
with alpha 1 and other Custom/Coordinate/Status data preserved. Shared skin
values also affect face/eyeline; this new target oracle covers body composition.
The gated `liveSourceOrdinaryBodyCompositeMatchesBaseAndDistinctOriginalColours`
requires both target base levels within one byte after colour-space conversion,
exact ordinary-body creator/input identities, the white sunburn default,
unchanged hits, recolour/revert and released-target resource bounds. The source
`ForceEnable` policy is retained. Main/mask inputs have one authored level;
the sRGB BC1 paint mask has 11. Only level 0 has an independent GPU oracle;
remaining authored levels and the 12 generated target levels are structural
checks. Input decode differences remain separate from the target tolerance.
The isolated native store needs the three body inputs and `create_body` program;
original readback pixels are comparison data only. Live-slot resolution,
Release costs and default-off output remain separate acceptance checks.

`IKKOKU_CHEEK_COMPOSITE_BASE_PROBE` and `IKKOKU_CHEEK_COMPOSITE_PROBE`
name the two fresh original stock cheek 402/1 cases for female head 0,
exType 0, high detail, with all other makeup layers absent. The first case
selects base makeup; the second selects coordinate makeup with distinct RGBA.
Each folder contains `fixture-card.png`, `cheek-inactive-card.png`, `frame.json`,
four input readbacks, and separate target readbacks before/after an inactive
record edit with a forced original rebuild, then after original input release.
The probe's temporary input retention does not establish default input lifetime
or original cost. Exact requested card bits and exact bound-before/after bits
are separate invariants; the existing observed-colour tolerance is 1e-6, because
the source colour API does not promise bit-preserving readback.

The gated `liveSourceHeadZeroCheekCompositeMatchesOriginalAndInactiveControls`
requires both target base levels within one byte after colour-space conversion,
alpha 255, exact creator/input identities, unchanged no-op and inactive-edit
cache hits, recolour/revert, and bounded released-target residency. It preserves
the observed `ForceEnable` policy. The sRGB RGBA32 cheek is 832 by 312 with one
authored mip; the other three inputs retain their existing 11-level identities.
Only level 0 has an independent original GPU oracle; 11 generated target levels
have structural coverage. Bound-input decode differences remain separate from
the target gate. The isolated native store adds the exact cheek asset using the
existing `create_head` program; original pixels are comparison data only. This
does not add a live material slot: live resolution, default-off output and
Release costs remain separate acceptance checks.

`IKKOKU_LIPLINE_COMPOSITE_BASE_PROBE` and `IKKOKU_LIPLINE_COMPOSITE_PROBE`
name the two fresh original lipline 404/1 cases for ordinary female head 0,
high detail. Lipline selection and colour are face-owned. Each case starts with
cheek 0, then rebuilds with exact stock cheek 402/1 using the original setter.
Folders contain `fixture-card.png`, `lipline-cheek-card.png`, `frame.json`,
fresh initial/combined input and target readbacks, and a separate release
readback equal to the combined target. Requested card colour bits and exact
bound-before/after bits are separate invariants; source input retention remains
a diagnostic lifecycle, not a default-lifetime or cost measurement.

The gated `liveSourceHeadZeroLiplineCompositeMatchesFourOriginalTargets`
requires all four target base levels within one byte after colour-space
conversion, alpha 255, exact lipline source identity, no-op/revert cache reuse,
and bounded released-target residency over 15 edits. The authored lipline is
80 by 36 sRGB RGBA32 with one mip. Only target level 0 has an independent
original oracle; generated mip readbacks are diagnostics. The 64-entry native
store adds one lipline asset to the accepted 63-entry cheek store and reuses
the same five create programs. Keep older count-pinned fixture gates on their
own stores. Original readbacks are comparison data only; bound-input decode
differences do not alter the output tolerance. Live resolution, default-off
images and comparative Release costs require separate acceptance.

`IKKOKU_LIPLINE_COMPOSITE_NONE_PROBE` names the no-layer control: the distinct
card with only `face.lipLineId` set to 0, from the producer and session that
reproduced every base/distinct face target and input readback. The folder holds
the same 15 files as the lipline cases (frame, both cards, inputs 55–61, targets
5, 62 and release 63). The original binds catalog row 0 (no `_Texture5`) but
still binds the distinct `_Color5`. The gated
`liveSourceHeadZeroLiplineNoLayerControlMatchesOriginalTargets` requires both
targets within one byte, a recipe without a lipline input, the original lipline
footprint (174 pixels inside bottom-up `[493,266,529,270]` at cheek 0 and 1),
native lipline targets byte-identical to the no-layer targets outside that
footprint, and pixel-identical output for a lipline recolour without a layer.
It reads `IKKOKU_LIPLINE_COMPOSITE_PROBE` for the distinct lipline targets.

### Live-frame gate inputs

`liveSourceShadersMeetTheControlledOriginalFrameGates` pins one exact native
store: 62 entries, five creator programs, no unavailable entries, and canonical
content `b9ae136b…`. It reads that store from
`IKKOKU_LIVE_SOURCE_GATE_TEXTURES` and its paired head contract from
`IKKOKU_LIVE_SOURCE_GATE_HEAD_CONTRACT` (both files, optional in
`private-source.json`). The live path's own `IKKOKU_LIVE_SOURCE_TEXTURES` and
`IKKOKU_HEAD_MATERIAL_CONTRACT` stay free to name newer stores: the cheek gate
needs the cheek asset from the 63-entry store, which this gate's pinned count
and hash reject. Both gate keys name the retained ordinary-body inputs (`textures/manifest.json`
and `head-materials/contract.json` under the body slice's
`retained-native-inputs/`); see [the #188 correction](../../docs/reference/renderer.md#cause-and-correction-cross-primitive-derivative-quads-2026-10-25).
The gate's bounds, counts and hash are unchanged.

### Selected skirt dynamics fixtures

The private Engine suite additionally accepts `IKKOKU_SKIRT_DYNAMICS_FIXTURE`,
`IKKOKU_SKIRT_DYNAMICS`, `IKKOKU_SKIRT_MAKER_LIBRARY` and
`IKKOKU_SKIRT_DYNAMICS_REFERENCE`. These exercise the schema-2 garment path,
independent 960-frame collider-on/off oracle and the native preview's FK, wear,
outfit and rollback lifecycle. See [the dynamics reference](../../docs/reference/animation/dynamics.md#selected-skirt-and-garment-root-dynamics-st-t08e)
for fixture generation and opt-in Release p50/p95 timing. This adds Engine checks;
`studio-scenarios.json` adds the `reload-save-skirt-dynamics` and
`reload-load-skirt-dynamics` checks (52 checks after integration with the three
expression scenarios). It aliases the source scene, Maker library and Studio
dynamics contract from those explicit skirt fixture keys, leaving other checks'
inputs unchanged. The pair drives live ticks, FK and garment-off controls, outfit
switches and native save/load in a fresh process, records skirt bone displacement and captures
rendered pixel differences. The combined Release pair passes 31/31 and 6/6 steps
after explicitly selecting/fixing the available T-pose clip and declaring its
animation catalog. The full-lane and corrected-rerun counts are recorded above;
numerical oracle, app rendering and original-player evidence remain separate.
