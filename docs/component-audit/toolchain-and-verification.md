# Extraction, build, inspection and verification

Audit date: 2026-09-25. [Status definitions](README.md).
This document covers the infrastructure around the native app. Source export,
native implementation, host integration and original-game parity are separate
milestones; a successful extractor does not complete a gameplay feature.

## T. Build and distribution

| ID / feature | Status | Specific review comments | Pending action |
| --- | --- | --- | --- |
| T01 · Swift package module graph | Mid-stage | `Packages/Engine/Package.swift` exposes nine library targets plus `IkkokuInspect`, with CoreMathTests/EngineTests. Gameplay has no Unity dependency; Studio depends on Gameplay. Character depends on Renderer for preview construction, so it is not a pure data/logic layer. | T-T01: document dependency boundaries and test pure logic separately from Metal-backed consumers. |
| T02 · Native macOS build | Mid-stage | Current arm64 Release app built successfully before this documentation audit. Xcode app target declares macOS 14.6 and Swift 5 language mode; SwiftPM uses Swift tools 6 / macOS 14. They are distinct settings. The `IkkokuShaders` target declares macOS 26.0 in Debug and Release; do not describe app 14.6 as a verified product-wide minimum. | T-T01 (partial): toolchain versions are now recorded and checked (T06). Still establish the supported deployment/architecture matrix and align intentional settings. CI has built the app and run the package tests since 2026-09-29 (T07). |
| T03 · Shader compilation and bundled resources | Mid-stage | Xcode builds Metal resources for the app; the runtime also has local/development shader and asset discovery paths. Package tests alone are not proof that an archived app contains its assets/metallib. Since 2026-10-23 (T-T02), `Tools/verification/inspect_app_bundle.py` checks a built bundle for `IkkokuShaders.metallib` and its `MTLB` signature, `catalog.json`, and every model, mask and texture the catalog references (137 in the checked-in catalog). CI's `release-package` job runs it on an unsigned arm64 Release build, after a zip round trip outside the checkout. The metallib is loaded from `Bundle.main` only. The asset root and the two `.local/reverse/` defaults have `#filePath` source-tree fallbacks; `IKKOKU_SOURCE_TREE_FALLBACKS=0` now disables them, and each use is logged. | T-T02 (partial): the job passed in dispatched run 39888875495 (2026-10-23; 207 files, 0 findings) after its first run found the Engine package in the bundle (see T-T02). Still to do: launch the packaged app outside the checkout with the fallbacks disabled (the [documented thumbnail run](../guides/build-and-test.md#package-and-inspect-a-release-build); not run, and CI never launches the app). `xcodebuild archive` is not exercised. |
| T04 · App signing, packaging and installation | Infancy | Automatic signing/hardened runtime settings are present; there is no installer, notarization procedure or converted-library setup UI. App sandbox is disabled. Since 2026-10-23 (T-T02), the [build guide](../guides/build-and-test.md#package-and-inspect-a-release-build) documents a clean-checkout Release build and bundle inspection, and CI builds an unsigned arm64 Release app and inspects it. That covers private-content exclusion and required resources only: the app is not signed, notarized, installed or launched. | T-T02 (partial): signing and notarization procedure, installer, a launch on a clean user profile, and user-owned converted-library selection/relocation (A-T02). |
| T05 · Private extraction/build isolation | Mid-stage | `.gitignore` excludes `.local/`, `.build/`, build output, Python caches and decompiled/extracted local data. Public assets are generated prototypes. Scripts vary in whether they enforce `.local/` output or only use it as a default. The app target copies its synchronized `Assets/` folder from disk, ignored files included. Since 2026-10-23 (T-T02), the bundle inspector therefore accepts a file only as a declared build product or a tracked `Assets/` file at its copied path. It fails `.local`/original-installation path components, repository and recovered source, PE assemblies, Unity asset bundles, mod archives, PNG card/scene payloads and build-machine paths in Info.plist or resources. The rules are reviewable in `Tools/verification/app-bundle-rules.json`. Its first CI run found the whole Engine package, including test fixtures, copied into the app's resources through a `Packages/` synchronized group; the T-T02 branch removes that group from the app target. | T-T03: unify converter output policy and provenance checks. The app bundle's contents are now checked by T-T02's inspector rather than by Git ignore alone. |
| T06 · Dependency reproducibility | Mid-stage | Reverse tools pin UnityPy 1.23.0, NumPy 2.2.6 and msgpack 1.1.2. Roslyn frontend targets .NET 10 and references the installed SDK parser without NuGet. Since 2026-10-23 (T-T01), `Tools/verification/prerequisites.json` records each documented version once: Xcode ≥26, Swift ≥6.0, .NET SDK ≥10.0, a Python 3.12 venv with the `requirements.txt` pins, ilspycmd 11.1.0.9782 and 9.1.0.7988, and Blender 5.1. The Metal compiler, public `python3`, asset numpy/Pillow, Parallels `prlctl` and the host macOS version are *unrecorded*, so only their presence is checked. `doctor.py` reports every capability; only `--require`d ones can fail. | T-T01 (partial): record versions for the unrecorded entries from a reference-Mac run; pin the asset Python packages; certify Blender reproducibility across versions. |
| T07 · Continuous integration and release gating | Partial | T-T04's lane machinery now exists: the stdlib runner `Tools/verification/run.py` plus lane manifests `public.json`, `private-source.json`, `maker.json` and `app-smoke.json` under `Tools/verification/lanes/`, each run on 2026-09-26 with reports under git-ignored `.local/verification/reports/`. A check whose declared required fixture is not in the environment file skips (fails under `--strict`); missing optional fixtures are recorded in `missingFixtures` and the check runs anyway (also failing under `--strict`). No lane runs a managed-DLL or original-player probe. Since 2026-09-29 `.github/workflows/ci.yml` runs the `public.json` lane skip-tolerant (no `--strict`) and an unsigned Debug app build on `macos-26` runners for pull requests and pushes to `main`; since 2026-10-23 a `release-package` job also builds an unsigned arm64 Release app and runs the T-T02 bundle inspector on it. CI is not a required status check, and the private lanes stay local because they need `.local/` fixtures or the VM. | T-T04 (partial): Maker import/outfit-switch/edit/export/reimport session scenarios now run headlessly in `maker-scenarios.json` (4/4 `--strict`, 2026-09-29); source-inspector hooks are merged (PR #5), while full interaction through visible Maker/Studio controls remains an acceptance boundary. |

## E. Original installation access and recovery

Sources: [vm_source.py](../../Tools/reverse/vm_source.py),
[inventory.ps1](../../Tools/reverse/inventory.ps1),
[recover_managed.py](../../Tools/reverse/analysis/recover_managed.py),
[decompile_studio.py](../../Tools/reverse/analysis/decompile_studio.py),
[catalog.py](../../Tools/reverse/catalog.py). Specialized converters are documented
in the Character, Studio and Renderer component reports and individually listed
in [the file index](file-index.md).

| ID / feature | Status | Specific review comments | Pending action |
| --- | --- | --- | --- |
| E01 · Backend/version inventory | Fully ported — inspected installation triage | Checks `Managed` and `il2cpp_data`, reads Unity version header, records assemblies/bundles/tools. Actual inventory identifies Koikatu and CharaStudio as Mono Unity 5.6.2f1; VR is Mono 5.6.3f1. This is not an IL2CPP title. | Retain hash/version identity on future rescans; a new install must not reuse incompatible contracts silently. |
| E02 · Explicit VM file transfer | Mid-stage | `prlctl exec` runs quoted/encoded PowerShell; relative source paths, byte cap, base64 transfer, source/native SHA-256 and provenance sidecars. It reads the installed file, not the running game's memory. | E-T01: timeout/cancellation, atomic fetch writes and resumable transport; test VM offline/partial transfer and destination reuse. |
| E03 · Managed source/IL/metadata recovery | Mid-stage | Immutable generation key includes assembly/reference/tool identities. Dumps TypeDef/MethodDef/AssemblyRef/TypeRef, full C# project and IL, and detects decompiler stubs. Per-type compatibility overrides are preserved rather than silently replacing evidence. Every generator that reads these exports now resolves through [`recovered_source.py`](../reference/managed-recovery.md#consuming-recovered-source): the indexed selected project, clean per-type fallbacks only, and named refusals otherwise. `translate.py` refuses stub-marked input. | E-T02 (partial): move the generators that still read older narrow `.local/reverse/decompiled/` trees after a private rerun confirms identical contracts. Produce unresolved recovery coverage by subsystem. |
| E04 · Inspected managed exports | Fully ported — artifact recovery only | Private index reports five selected assemblies recovered, with 2,026 main-game, 2,026 Studio, 929 firstpass and two 3-file UnityScript project exports. Nine overrides each for main/Studio and two for firstpass resolve recorded decompiler diagnostics. The [2026-10-17 REA check](../reference/managed-recovery.md#independent-rea-check--2026-10-17) independently confirms all five source identities and four metadata table counts, 5,097 retained artifact hashes, 26 reference DLL hashes, and 294 selected method tokens/names/RVAs. The 17 recovery regressions pass. | Static recovery is corroborated; these checks prove neither C# recompilation nor semantic/runtime equivalence. Remaining game/plugin/VR assemblies and native feature verification are separate work. |
| E05 · IL2CPP/AOT/Ghidra pipeline | Pending — conditional, not needed for this install | Detection exists, but no Il2CppDumper/GameAssembly/global-metadata recovery or Ghidra automation implementation is checked in. | Only activate this branch if a future inspected installation actually uses IL2CPP; do not spend current Mono-port work on struct-padding parity. |
| E06 · Unity asset conversion | Mid-stage | UnityPy-based catalog/prefab/rig/material/animation tools export selected typed data. This is an explicit conversion pipeline, not a bulk AssetRipper project import with automatic feature parity. | Coverage inventory must distinguish catalog-known, fetched, decoded, converted, drawable and behavior-verified entries. |
| E07 · Contract/oracle generators | Partial | The four verification lanes keep their separate evidentiary strengths: `public.json` declares `synthetic`-tier checks only, `private-source.json` and `maker.json` declare `recovered-code-oracle` checks with per-fixture gates (`private-source.json` runs with missing optional fixtures recorded; checks needing absent required fixtures skip), and `app-smoke.json` declares `app-smoke` checks. `Tools/verification/run.py` now records manifest/runner hashes, git revision + dirty diff hash and tool versions per report (E-T03's standardization); no check executes a recovered managed DLL or the original player, so `original-managed-dll` and `original-player-probe` remain unexercised tiers. | E-T03 (partial): wire the lanes into CI and route the existing `Tools/reverse` oracle generators through a lane so their outputs get manifest binding; keep tiers that cannot run excluded from green counts. |
| E08 · Original-player probes | Partial | The copied-player probes still run ad hoc; none of the four lane manifests schedules them, so no lane proof exists for a reproduced probe run. The runner does record git revision/diff hash, tool versions, per-check exit code, elapsed time and log path/hash — the manifest fields E-T03 asked for — but player settings, camera/light and selection state remain per-probe convention, not manifest-declared fixtures. | E-T03 (partial): add an `original-player-probe`-tier check that runs the existing lifecycle/dynamics probes through the runner with recorded settings; current probes cannot reproduce a session inside a lane run. |
| E09 · Whole-install conversion orchestration | Infancy | Numerous targeted CLIs and local manifests exist; no single dependency-aware job graph runs inventory → recovery → assets → native coverage → parity → app installation. | E-T04: add resumable dependency graph and explicit per-stage diagnostics; avoid overwriting selected generations. |

## I. `ikkoku-inspect`

Sources: `Packages/Engine/Sources/IkkokuInspect/`.
These commands are useful diagnostic consumers, not gameplay/UI implementations.

| Component / commands | Status | Specific review comments and next task |
| --- | --- | --- |
| `main.swift`: `model`, `rig`, `scene`, `camera`, `change-amount`, `layout` | Mid-stage | Inspects converted geometry, source rig/binary records and bounded prop/folder layout conversion. Add machine-readable error codes and consistent command schemas; inspect capability is not complete native scene restoration. |
| `main.swift`: `card`, `mod`, `mod-library`, `mod-catalog`, `card-mods` | Mid-stage | Emits hashes, identities, dependencies, preserved bytes and diagnostics. Some `scope` strings are stale: `card` still says edited-card serialization remains unfinished despite a bounded writer. T-T05 must update summaries from current capabilities. |
| `main.swift`: `rig-snapshot`, `face-snapshot`, `body-snapshot`, `expression-snapshot`, `bone-modifier-snapshot` | Mid-stage | Numerical snapshots exercise runtime math without UI. Add explicit fixture/contract versions to outputs and systematic malformed-input tests; one snapshot is not visual/temporal parity. |
| `BlinkTrace.swift`: `blink-trace` | Mid-stage | Runs recovered blink state against supplied actions/randomness. RNG supplied by a caller does not establish original global RNG sequence or frame ordering. |
| `GameplayTrace.swift`: `gameplay-trace` | Mid-stage | Reports cycle transitions/deferred effects. Does not load NPCs, execute scenes or apply effects. |
| `GameplayExecutionInspection.swift`: `fixed-event-trace`, `adv-trace` | Mid-stage | Evaluates selections and ADV snapshots from supplied trace inputs, with unsupported faults. No actual player/heroine state host. |
| `SourceAnimationReport.swift`: `animation-library`, `animation-pose` | Mid-stage | Catalog/clip metadata and selected rig samples. Whole Animator graph transitions/layers are not inferred from clip sampling. |
| `StudioPoseInspection.swift`: `studio-fk` | Mid-stage | Applies supported original FK requests and reports pose data. Add dedicated full-body/guide/dynamics command surfaces only where needed; existing tests currently exercise those directly. |
| `StudioSceneInspection.swift`: `scene-document` | Mid-stage | Reports parsed original scene structure including data not consumed by rendering. Keep “parsed”, “rendered” and “editable/exportable” counts separate. |

## V. Verification coverage and how to interpret it

| Feature | Status | Specific review comments | Next task |
| --- | --- | --- | --- |
| Public synthetic unit tests | Mid-stage | The `public.json` lane runs five checks with no private data: Engine `swift test` plus the mod-tools, translation, runner-self and Studio-inspector `unittest` suites. The earlier 369-test Engine count belongs to the September baseline. On 2026-10-17 at base `d671aee`, the direct Engine suite discovered 523 tests: 458 passed, 65 explicit fixture skips, zero failures. The runner preserves per-test execution and skip reasons. | T-T04 (partial): CI runs the public lane since PR #70; private fixture and original-player coverage remain local. Keep per-suite command, revision and result recorded per run. |
| Original fixture tests | Mid-stage | Lane gating is per check: `private-source.json` declares all 47 fixture variables gated in `Packages/Engine/Tests` (except the output/report/result paths and `IKKOKU_SAVE_SCENE`/`IKKOKU_EXPORT_SOURCE_SCENE`) as `"optional"`, so its one check runs with or without an environment file and merely lists unsupplied fixtures in `missingFixtures` — `--strict` turns any of those into a failure. On the integrated tree with PR #4 and 32 fixtures supplied, 379 tests are reported: 359 passed, 20 named skips, 0 failed. | T-T04: add a strict private-fixture suite that fails if prerequisites are absent. |
| Numerical source parity | Mid-stage | Separate evidence exists for shapes, rigs, material composition, ADV kernels, IK, dynamic bones and Animator samples. Each validates only its stated source/input domain; the `recovered-code-oracle` tier and `tolerance` notes in the lane manifests keep that scoped. | E-T03 (partial): retain expected-value independence and replay metadata; broaden domains according to component tasks. The checks still need a complete private fixture set before they run end-to-end. |
| Actual app integration | Mid-stage — bounded headless workflows | `app-smoke.json` declares a Debug build, Mute-startup capture and a source-inspector capture/report validation. PR #5 merged the inspector hooks and removed the source-character gate. By merged `main` `d671aee`, the Studio lane contains 32 checks, including source edits/export/reimport, runtime retention and a guide drag through real mouse handlers/GPU picking. The Maker lane has four import/outfit/edit/export/reimport scenarios. These are application/model-level checks; historical failures and missing-fixture skips are not current reachability verdicts. See the [maintained handoff](README.md#highest-priority-handoff) for dated acceptance and exclusions. | T-T04 plus A-T04 and Studio UI task: complete visible menu/inspector, file-operation and persistence workflows. Headless scenario success does not certify all mouse-driven controls or original-player visual parity. |
| Matched original frames | Mid-stage | Frozen-geometry diagnostic and translated shader comparisons exist. Whole native source scene/animation/appearance parity is not established. | Renderer audit describes geometry/garment passes and full-color failure; keep those gates separate. |
| Performance and memory | Mid-stage | GPU reused-target timings, CPU scene evaluation and RSS/Metal allocations measured for specific release fixtures. Offscreen microbench excludes scheduling/readback and may exclude dynamics when no chain matches. | T-T06: end-to-end displayed frame profiling with multiple characters, dynamic chains, asset streaming and long-lived resource use. |
| Whole asset/plugin coverage | Infancy | Selected Maker/catalog counts and installed mod inventory exist. Installed directory counts are not compatible-content counts; support DLLs are not independent plugins. | E-T04/P-T01: report denominators and per-stage reasons, then expand bounded fixtures. |

### Evidence available at this audit

**2026-10-17 verification accounting correction (T-T04 / E-T03):** SwiftPM
emits separate Swift Testing summaries for the Engine package's two test
executables. The runner now sums those totals instead of retaining only the
last one. Re-parsing the dated public-input Engine log gives 523 total,
458 passed, 65 skipped and zero failed; re-parsing the private-source lane
log gives 523 total, 503 passed, 20 skipped and zero failed, with 32 fixture
paths supplied and 15 optional fixtures unavailable. The old `total: 12`
did not affect named per-test counts or executed-test bounds. Two regression
tests cover combined executable logs (including skips, failures and repeated
issue lines) and summary-only output. These are accounting checks on retained
logs, not new source-parity runs; the original reports remain unchanged.

The following are **retained local results**, not a new claim that every test was
executed during the documentation pass:

- `/tmp/ikkoku-native-adapter-build.log`: arm64 Release build completed before
  the audit; one known `MaterialKind` nil-coalescing warning.
- `/tmp/ikkoku-plugin-translation-tests.log`: ten frontend/translation tests
  passed before the new adapter test was added. The additional actual-assembly
  packaging test was subsequently run separately and passed.
- `/tmp/ikkoku-native-plugin-package-tests.log`: three native package tests
  passed with `IKKOKU_NATIVE_PLUGIN_PACKAGES` set.
- `.local/reverse/plugin-execution/release-capture-01/report.json`: successful
  IR plugin run/reload/continue. `native-adapter-capture-01` is a **failed** later
  attempt from before the A-T04 fix, not equivalent evidence.
- `.local/reverse/original-animation-probe/native-comparison.json`: 180 source
  player samples, 60,804 bone matrices; see Studio audit for errors and scope.
- `.local/reverse/studio-dynamics/final-targeted-tests.log`: 36 combined targeted
  Swift checks with original dynamics/full-body/animation fixtures.
- `.local/reverse/original-character-probe/frame-comparison.json`: renderer
  diagnostic results; see Renderer audit for current passing/failing gates.

The component reports name corresponding test files and fixture variables. Local
data is deliberately not copied into the documentation or distribution.

## Actionable infrastructure tasks

- **T-T01 — Reproducible developer environment (P1, partial).** Record Xcode, Swift, .NET,
  ILSpy, Python packages and Blender versions; add prerequisite checks and one
  documented setup path. Accept when a clean checkout builds public tools/app
  without depending on a previous agent's shell environment. Implemented
  2026-10-23: `Tools/verification/prerequisites.json` is the single record of
  versions, and the [build guide](../guides/build-and-test.md#prerequisites)
  table is generated from it. Versions the repository does not document are
  recorded as *unrecorded*. `Tools/verification/doctor.py` (stdlib) reports per
  capability which tools are present and whether they meet the record. Its
  public capabilities are the app build, Metal shaders, Engine tests, Python
  suites and translation frontend; the optional ones are reverse tools, asset
  regeneration, managed recovery and VM probes. It exits 1 only for an unmet
  `--require`d capability and never reads `.local/` data. The build guide's
  [clean-checkout setup](../guides/build-and-test.md#set-up-a-clean-checkout)
  is the one documented path. CI's public-lane job now runs `--require public`
  before the build. A dispatched CI run of the branch (run 39884395421,
  2026-10-23, `macos-26-arm64` image 20261013.0424.1) met all five public
  capabilities in 10 s: macOS 26.6.2 arm64, Xcode 26.6, Metal 32023.883,
  Swift 6.3.3, Python 3.15.0 and .NET SDK 10.0.401. The public lane (5/5),
  unsigned app build and reverse-tools jobs passed in the same run.
  `test_doctor.py` (29 tests in `runner-self-tests`) covers parsing of the
  recorded CI outputs and labelled format samples, absent tools, the generated
  table and restated versions. It passed on Python 3.10–3.13 in a Linux
  container, where every Apple/.NET tool is reported absent and the checker
  exits 0 without `--require`. Real reverse-tools detection (Python 3.12 with
  all three pins `ok`) was checked against a scratch venv. Still open:
  following the setup path on a fresh contributor Mac (CI uses a
  preprovisioned image), launching an unsigned build, the deployment matrix
  (T02) and versions for the unrecorded entries (T06).
- **T-T02 — Release packaging (P1, partial).** Inspect archived contents, provide library
  selection/relocation, and verify all app resources on a clean user profile.
  Accept when the app works outside the checkout and no private recovered files
  are embedded unintentionally. First slice implemented 2026-10-23.
  `Tools/verification/inspect_app_bundle.py` (stdlib) checks a built `.app`
  against `Tools/verification/app-bundle-rules.json`, a reviewable list of
  required and forbidden contents, and writes a JSON report. Required are the
  metallib with its signature, `catalog.json`, `Assets.car`, every
  catalog-referenced asset, the expected Info.plist identity and an `arm64`
  slice in every Mach-O file. Every other file must be a declared build
  product or a tracked `Assets/` file at the path the synchronized group
  copies it to. Private and original-game content fails, as listed under T05,
  and so do absolute build-machine paths in Info.plist, text resources, PNG
  text chunks and GLB JSON chunks. Compiled products only record their path
  strings: the Swift 5 target's `#file`/`#filePath` strings embed the checkout
  path in the executable. CI's `release-package` job builds Release unsigned
  with `ARCHS=arm64` from the clean checkout. It round-trips the app through a
  `ditto` zip into `$RUNNER_TEMP`, inspects that copy and uploads the
  `release-bundle-report` artifact. The runtime's three `#filePath` source-tree
  fallbacks print a `[ikkoku] source-tree fallback:` line when used, and
  `IKKOKU_SOURCE_TREE_FALLBACKS=0` disables them. The fallbacks are the asset
  root when the bundle has no `catalog.json`, and the `.local/reverse/` Maker
  library and original bases. Defaults are unchanged in both configurations,
  so the local lanes behave as before. The first dispatched CI run (run
  39887901874, 2026-10-23) compiled the `EngineHost.swift` change and built
  the Release app in 6 minutes. The inspector then failed it with 247 errors,
  one for each file under `Packages/`: the app target listed `Packages/` as a
  synchronized group, so the whole Engine package was copied into
  `Contents/Resources/Engine/`. That covered `Package.swift`, every source and
  test file, and the six test fixtures under `Tests/EngineTests/Fixtures/`.
  Debug builds of the same target have the same membership. Nothing reads these
  files at runtime; the app links Engine through its local package reference.
  The branch removes `Packages` from the IkkokuCreator target's
  `fileSystemSynchronizedGroups`, keeping it in the project navigator. A
  `source-code` rule now names such files, and a test checks the target's group
  list. Everything else in that run passed: 6 build products, all 201 shipped
  tracked assets byte-identical to the checkout, an arm64 executable, all 137
  catalog references, and no private-content or build-path finding. With the
  fix, dispatched run 39888875495 (2026-10-23, head `802b351`) passed all four
  jobs. The Release job built in 5.5 minutes and produced a 26 MB zip. The
  inspector found 207 files (45.7 MB): 6 build products and 201 tracked assets,
  an arm64 executable, and 0 errors and 0 warnings. Other evidence: 61
  synthetic-bundle tests in `test_inspect_app_bundle.py` (`runner-self-tests`)
  on Python 3.10–3.13 in a Linux container, and a clean pass on a simulated
  bundle copied from the 205 tracked assets. The tests include consistency
  checks against `Ikkoku.xcodeproj` and the checked-in catalog. Still open: the
  documented launch outside the checkout with fallbacks disabled (CI never
  launches the app), a clean user profile, `xcodebuild archive`, signing,
  notarization, an installer and library selection/relocation (A-T02).
- **T-T03 — Unified provenance/output policy (P2).** Standardize source hashes,
  converter versions, immutable outputs and atomic publication for converters.
  Accept when interrupted or changed inputs cannot be presented as complete,
  current converted generations.
- **T-T04 — Explicit verification lanes (P1, partial).** Add public unit,
  private-source parity, actual-app smoke and release-packaging jobs. Replace
  silent fixture returns with reported skips; a strict private lane requires all
  declared inputs. Accept when the report separates executed/passed/failed/skipped
  coverage and catches both the current startup trap and unreachable source
  inspectors. Implemented and locally verified on 2026-09-26: four lane
  manifests under `Tools/verification/lanes/` plus the stdlib runner
  `Tools/verification/run.py`. All 47 private-source fixtures are declared
  `optional`, so the Engine suite runs with or without an environment file and
  records supplied/missing fixtures per check; `--strict` fails any check with
  a missing fixture. PR #4 supplies named per-test fixture skips, so the lane
  reports missing source cases explicitly. CI wiring (2026-09-29):
  `.github/workflows/ci.yml` runs the public lane skip-tolerant and an unsigned
  Debug app build on pull requests and pushes to `main`; the private lanes stay
  local. Maker session scenarios (2026-09-29): `maker-scenarios.json` runs four
  JSON-driven scenarios headlessly through the app's `IKKOKU_MAKER_SCENARIO`
  hook — source-card import, outfit switch, shape/color edits, export and
  reimport with asserts — and passes 4/4 under `--strict`. Still remaining: the
  mouse-driven Maker UI itself (sliders, outfit dropdown and buttons are never
  clicked), rendered-pixel checks, and reloading an exported card in the
  original player.
- **T-T05 — Capability-driven diagnostics/docs (P2, partial).** The 2026-09-25
  documentation revision organized maintained guides/references and archived
  historical checkpoints with links to this audit. Remaining work: replace stale
  CLI/app scope strings with versioned capability summaries and keep those outputs
  synchronized with the documents. Accept when CLI, app diagnostics and docs agree
  on supported, preserved-only and rejected features.
- **T-T06 — Representative performance (P2).** Capture end-to-end app CPU/GPU,
  presentation latency, asset load/cache churn and memory trends for selected
  multi-character scenes. Record build mode, device, fixture hashes and enabled
  behaviors. Accept against explicitly chosen budgets; do not sum RSS and Metal
  unified-memory allocations or infer game FPS from static GPU timing.
- **E-T01 — Robust VM transport (P2).** Add bounded process timeout/cancellation
  and atomic file/provenance publication. Accept with offline VM, interrupted
  transfer, wrong hash and oversized input tests.
- **E-T02 — Recovery consumer consistency (P1, partial).** Require every contract generator
  to resolve selected project and per-type fallback via the recovery manifest.
  Accept when a primary error stub cannot accidentally become translation input.
  Implemented 2026-10-23 with synthetic fixtures only. The shared resolver
  `Tools/reverse/analysis/recovered_source.py` selects a generation from
  `index.json`. It returns the manifest-selected project file, or a type's
  fallback only where that fallback is recorded clean, and checks each file
  against its manifest hash. It refuses error stubs, missing types, hash
  mismatches, ambiguous matches and unusable manifests by named exception.
  Stub markers are `recover_managed.py`'s single `ERROR_STUB` definition. Six
  generators that read the managed-recovery tree now use the resolver:
  gameplay/ADV coverage, trigonometric IK, body shape, card round-trip, the
  full-body oracle and dynamics. Their output is unchanged for valid inputs. The
  body-shape `--source` and full-body `--recovered-project` directory options
  are replaced by `--recovery-index`. `Tools/translation/translate.py` refuses
  stub-marked sources before building or writing anything. Fifteen resolver and
  consumer tests in `analysis/test_recovered_source.py`, plus the updated
  gameplay helper tests, cover these paths. Three of the tests run real
  generators against stub trees. Remaining: the consumers listed under
  [consumers not moved](../reference/managed-recovery.md#consuming-recovered-source)
  read older narrow decompilations or an explicit directory. They can still
  ingest a stub if pointed at one. No private five-assembly generation has
  been rerun through the moved consumers.
- **E-T03 — Reproducible evidence manifests (P1, partial).** Standardize source
  hash, native executable/tool hash, input data, configuration, reference tier and
  tolerance/gate output. Accept when a new run can reproduce each claimed parity
  result without inferring settings from shell history. Implemented in
  `Tools/verification/run.py`: reports record the git revision, dirty flag and
  sha256 of `git diff HEAD`, runner/manifest hashes, tool versions (absent tools
  tolerated), per-check argv/cwd, sorted `IKKOKU_*` variable names passed from
  the environment file (`passedEnvironment`), values only for the check's own
  settings (`env`), `suppliedFixtures`/`missingFixtures` with paths and hashes,
  declared reference tier, tolerance text, and artifacts hashed **after** the
  run — a missing or (since A-T05) empty artifact fails the check. Still remaining (CI now runs the
  public lane, see T-T04): the
  `original-managed-dll` / `original-player-probe` tiers have no checks that
  execute them yet — no claim of source parity is made from resemblance.
- **E-T04 — Conversion orchestration and coverage (P2).** Build a resumable job
  graph over catalogs/assets/behavior adapters and preserve saved generation
  identities. Accept when each unconverted dependency has a concrete reason and
  next job, rather than an undifferentiated missing-asset count.
