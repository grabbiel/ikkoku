# Extraction, build, inspection and verification

Audit date: 2026-09-25. [Status definitions](README.md).
This document covers the infrastructure around the native app. Source export,
native implementation, host integration and original-game parity are separate
milestones; a successful extractor does not complete a gameplay feature.

## T. Build and distribution

| ID / feature | Status | Specific review comments | Pending action |
| --- | --- | --- | --- |
| T01 · Swift package module graph | Mid-stage | `Packages/Engine/Package.swift` exposes nine library targets plus `IkkokuInspect`, with CoreMathTests/EngineTests. Gameplay has no Unity dependency; Studio depends on Gameplay. Character depends on Renderer for preview construction, so it is not a pure data/logic layer. | T-T01: document dependency boundaries and test pure logic separately from Metal-backed consumers. |
| T02 · Native macOS build | Mid-stage | Current arm64 Release app built successfully before this documentation audit. Xcode app target declares macOS 14.6 and Swift 5 language mode; SwiftPM uses Swift tools 6 / macOS 14. They are distinct settings. The `IkkokuShaders` target declares macOS 26.0 in Debug and Release; do not describe app 14.6 as a verified product-wide minimum. | T-T01: establish supported deployment/architecture matrix, align intentional settings, run app and package checks in CI. |
| T03 · Shader compilation and bundled resources | Mid-stage | Xcode builds Metal resources for the app; the runtime also has local/development shader and asset discovery paths. Package tests alone are not proof that an archived app contains its assets/metallib. | T-T02: build/archive from a clean checkout and validate resource lookup without source-tree fallbacks. |
| T04 · App signing, packaging and installation | Infancy | Automatic signing/hardened runtime settings are present; there is no checked-in release automation, installer, notarization procedure or converted-library setup UI. App sandbox is disabled. | T-T02: write and exercise a release process, including private-content exclusion and user-owned external library access. |
| T05 · Private extraction/build isolation | Mid-stage | `.gitignore` excludes `.local/`, `.build/`, build output, Python caches and decompiled/extracted local data. Public assets are generated prototypes. Scripts vary in whether they enforce `.local/` output or only use it as a default. | T-T03: unify output policy and provenance checks; verify distributable artifact contents rather than relying only on Git ignore. |
| T06 · Dependency reproducibility | Mid-stage | Reverse tools pin UnityPy 1.23.0, NumPy 2.2.6 and msgpack 1.1.2. Roslyn frontend targets .NET 10 and references the installed SDK parser without NuGet. Blender and local ILSpy/oracle tools are still environment prerequisites. | T-T01: record supported tool versions/install checks, lock a reproducible tool environment, fail helpfully when optional tools are absent. |
| T07 · Continuous integration and release gating | Pending | No CI workflow is present in the reviewed file inventory. Xcode's scheme has a TestAction, but private fixture tests and actual headless app probes need explicit orchestration. | T-T04: separate public synthetic checks from opt-in private-source parity and actual-app tests; report all omitted fixtures. |

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
| E03 · Managed source/IL/metadata recovery | Mid-stage | Immutable generation key includes assembly/reference/tool identities. Dumps TypeDef/MethodDef/AssemblyRef/TypeRef, full C# project and IL, and detects decompiler stubs. Per-type compatibility overrides are preserved rather than silently replacing evidence. | E-T02: enforce selected-source override handling in all consumers and produce unresolved recovery coverage by subsystem. |
| E04 · Inspected managed exports | Fully ported — artifact recovery only | Private index reports five selected assemblies recovered, with 2,026 main-game, 2,026 Studio, 929 firstpass and two 3-file UnityScript project exports. Nine overrides each for main/Studio and two for firstpass resolve recorded decompiler diagnostics. Hash verification covers exported artifacts. | These counts prove neither recompilation nor native behavior; remaining game/plugin/VR assemblies and semantic translation are separate work. |
| E05 · IL2CPP/AOT/Ghidra pipeline | Pending — conditional, not needed for this install | Detection exists, but no Il2CppDumper/GameAssembly/global-metadata recovery or Ghidra automation implementation is checked in. | Only activate this branch if a future inspected installation actually uses IL2CPP; do not spend current Mono-port work on struct-padding parity. |
| E06 · Unity asset conversion | Mid-stage | UnityPy-based catalog/prefab/rig/material/animation tools export selected typed data. This is an explicit conversion pipeline, not a bulk AssetRipper project import with automatic feature parity. | Coverage inventory must distinguish catalog-known, fetched, decoded, converted, drawable and behavior-verified entries. |
| E07 · Contract/oracle generators | Mid-stage | Separate Python calculations, recovered C# hosts, original managed-DLL calls and original Unity player probes all exist. These have different evidentiary strength and different scopes. | E-T03: bind each result to input/source/native executable hashes and identify exactly which tier produced expectations. |
| E08 · Original-player probes | Mid-stage | Controlled copied-player fixtures capture lifecycle, animation, dynamics or frozen character/shader data. Numeric probes avoid requiring visual comparison; frame probes use controlled clothed fixtures. | E-T03: source revision, player settings, camera/light, time, selection, exit status and stopped process should be part of every reproducible result manifest. |
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
| Public synthetic unit tests | Mid-stage | Swift CoreMath/Engine, Python reverse/mod/translation tests cover many boundaries and formulas. No latest all-project count is asserted here because this audit did not rerun every suite. | T-T04: publish per-suite command, revision and result rather than copy an older green count. |
| Original fixture tests | Mid-stage | Many Swift tests use `guard let env ... else { return }`; others use explicit conditional enablement. An apparently passed test can mean the source fixture never ran. | T-T04: make omitted source cases explicit skips and add a strict private-fixture suite that fails if prerequisites are absent. |
| Numerical source parity | Mid-stage | Separate evidence exists for shapes, rigs, material composition, ADV kernels, IK, dynamic bones and Animator samples. Each validates only its stated source/input domain. | E-T03: retain expected-value independence and replay metadata; broaden domains according to component tasks. |
| Actual app integration | Infancy | Headless release IR save/reload succeeded; two-original-adapter Release startup/save/reload and enabled/disabled gain checks passed in PR #2 after the A-T04 fix. Source inspector controls can be unreachable even when engine tests pass. There is no broad UI automation suite. | T-T04 plus A-T04 and Studio UI task: test menu/inspector reachability, file operations, startup and persistence through the application. |
| Matched original frames | Mid-stage | Frozen-geometry diagnostic and translated shader comparisons exist. Whole native source scene/animation/appearance parity is not established. | Renderer audit describes geometry/garment passes and full-color failure; keep those gates separate. |
| Performance and memory | Mid-stage | GPU reused-target timings, CPU scene evaluation and RSS/Metal allocations measured for specific release fixtures. Offscreen microbench excludes scheduling/readback and may exclude dynamics when no chain matches. | T-T06: end-to-end displayed frame profiling with multiple characters, dynamic chains, asset streaming and long-lived resource use. |
| Whole asset/plugin coverage | Infancy | Selected Maker/catalog counts and installed mod inventory exist. Installed directory counts are not compatible-content counts; support DLLs are not independent plugins. | E-T04/P-T01: report denominators and per-stage reasons, then expand bounded fixtures. |

### Evidence available at this audit

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

- **T-T01 — Reproducible developer environment (P1).** Record Xcode, Swift, .NET,
  ILSpy, Python packages and Blender versions; add prerequisite checks and one
  documented setup path. Accept when a clean checkout builds public tools/app
  without depending on a previous agent's shell environment.
- **T-T02 — Release packaging (P1).** Inspect archived contents, provide library
  selection/relocation, and verify all app resources on a clean user profile.
  Accept when the app works outside the checkout and no private recovered files
  are embedded unintentionally.
- **T-T03 — Unified provenance/output policy (P2).** Standardize source hashes,
  converter versions, immutable outputs and atomic publication for converters.
  Accept when interrupted or changed inputs cannot be presented as complete,
  current converted generations.
- **T-T04 — Explicit verification lanes (P1).** Add public unit, private-source
  parity, actual-app smoke and release-packaging jobs. Replace silent fixture
  returns with reported skips; a strict private lane requires all declared inputs.
  Accept when the report separates executed/passed/failed/skipped coverage and
  catches both the current startup trap and unreachable source inspectors.
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
- **E-T02 — Recovery consumer consistency (P1).** Require every contract generator
  to resolve selected project and per-type fallback via the recovery manifest.
  Accept when a primary error stub cannot accidentally become translation input.
- **E-T03 — Reproducible evidence manifests (P1).** Standardize source hash,
  native executable/tool hash, input data, configuration, reference tier and
  tolerance/gate output. Accept when a new run can reproduce each claimed parity
  result without inferring settings from shell history.
- **E-T04 — Conversion orchestration and coverage (P2).** Build a resumable job
  graph over catalogs/assets/behavior adapters and preserve saved generation
  identities. Accept when each unconverted dependency has a concrete reason and
  next job, rather than an undifferentiated missing-asset count.
