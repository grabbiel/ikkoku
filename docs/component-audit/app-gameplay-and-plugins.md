# App, gameplay and translated plugins

Audit date: 2026-09-25. Read the [status definitions and scope](README.md) before
using a completion label. This reviews the current working tree, including
uncommitted implementation. A runnable editor is not a playable port of the game.

## A. Application shell and integration

Sources: [IkkokuApp.swift](../../Apps/IkkokuCreator/IkkokuApp.swift),
[ContentView.swift](../../Apps/IkkokuCreator/ContentView.swift),
[AppState.swift](../../Apps/IkkokuCreator/AppState.swift),
[EngineHost.swift](../../Apps/IkkokuCreator/EngineHost.swift),
[ViewportView.swift](../../Apps/IkkokuCreator/ViewportView.swift),
[AppState+PluginExecution.swift](../../Apps/IkkokuCreator/AppState+PluginExecution.swift),
[AppState+OriginalFrameProbe.swift](../../Apps/IkkokuCreator/AppState+OriginalFrameProbe.swift).

| ID / feature | Status | Specific review comments | Remaining work / acceptance |
| --- | --- | --- | --- |
| A01 · SwiftUI shell, Maker/Studio switching and shared engine | Mid-stage | Both editors share one `EngineHost` and renderer. Mode changes activate one model and refresh its frame. There is no ActionGame/title/gameplay mode. | A-T01: add an actual game session host; retain editor isolation. |
| A02 · Metal startup and asset discovery | Mid-stage | Explicit `IKKOKU_ASSETS`, bundle assets, then source-tree assets. Optional original male/female manifests and Maker library are separate private inputs. Explicit invalid source overrides fail instead of silently selecting another source. Development defaults depend on build-machine paths. | A-T02: install/import workflow, portable paths and actionable missing-resource UI; test a moved release app. |
| A03 · Viewport display and input | Mid-stage | `CAMetalDisplayLink` drives drawable presentation; Retina pixel conversion, orbit/pan/zoom, trackpad magnification, mouse and key delegation exist. Simulation uses editor timers, not this presentation timestamp. | A-T03: instrument displayed frames and simulation cadence together; validate resize, focus loss, mode switching and more than one window. |
| A04 · File commands and error presentation | Mid-stage | Native cards/scenes, original-card fallback, static model import, original layout/scene preview and edited-original export are separate commands. Errors usually become an alert/status. These commands do not imply format-complete interoperability. | Verify all source/native branches, cancellation and failed import state preservation through UI tests; format details belong to the Character/Studio audits. |
| A05 · Source Maker → Studio transfer | Pending | `Send to Studio` is explicitly disabled while a source rig is active. The enabled command sends the bundled `CharacterCard`. Original cards can instead enter through source scene preview. | Preserve edited source card bytes, selection, outfit, resolver GUIDs and source rig references when adding a source character; compare Maker and Studio posed appearance. |
| A06 · Headless capture orchestration | Mid-stage | Environment switches cover rigs, models, source/native cards/scenes, shape/color edits, fixed animation time, scripted plugin steps, focus events, adapter reports, screenshots and benchmarks. Startup calls capture paths synchronously and exits before `NSApplication` finishes launching. Native adapter mounts no longer read `NSApp` there. Input errors are generally explicit. | A-T04: verify the adapter fix through the release probe. Then cover the remaining startup phases, output errors and invalid combinations. |
| A07 · Window UI capture and thumbnail generation | Infancy | UI capture runs after a fixed 2.5-second delay and uses `try?` for PNG writing; it can exit successfully without a valid output. Thumbnail generation similarly ignores individual write failures. | A-T05: wait for explicit readiness, propagate errors and verify expected nonempty image files before exit 0. |
| A08 · Original-frame probe entry point | Mid-stage | Produces generic-renderer, geometry/depth-normal and optional translated-shader diagnostic captures. Its own report correctly says frozen original geometry does not validate native rigs or scene loading. | Keep probe evidence separate from actual Maker/Studio frames; see renderer tasks R1/R2. |
| A09 · Mod library commands/UI | Mid-stage | Explicit load/reload with dependency reporting. Scanning/conversion happens in CLI tools; the app does not automatically discover newly installed Windows mods. | Connect conversion job status, compatibility results and explicit version selection to app workflow; see Character/mod audit. |
| A10 · Translated plugin commands | Mid-stage | Profile load plus run/pause are available in Mods. Converted original adapters have a separate manifest picker. Typed IR profiles require externally prepared object bindings. | Add inspectable package/binding/error UI, unload, replacement rules and original-plugin startup tests; P-T02/P-T03. |
| A11 · Multiwindow/document lifecycle | Infancy | `WindowGroup` is backed by one `@State AppState`; `sharedStudio` and `uiCaptureState` are process-global unsafe statics used for captures. This is not an independent document-per-window design. | A-T03: define whether multiple windows share or own documents, then test renderer ownership, timers, saves, focus and teardown accordingly. |
| A12 · Distribution readiness | Infancy | Local Xcode builds exist; bundle contents, private original-data discovery and CLI dependencies are development-oriented. No installer, first-run conversion flow, signing/notarization release workflow or clean-machine proof is present. | See toolchain T-T01/T-T02. |

### Actionable app tasks

- **A-T01 — Gameplay host (P1, after G-T01).** Add a session model owning saved
  player/NPC state, period, active map and ADV barriers. Accept when a controlled
  non-media event can run from period selection to completion through the app,
  persist, reload and resume without caller-injected fake completion effects.
- **A-T02 — Portable resource installation (P1).** Replace reliance on `#filePath`
  development defaults with a user-selected, versioned conversion library and
  relocation resolver. Accept when a release app launched outside this checkout
  opens a saved scene after relocating its library, or reports each unresolved
  identity without substituting another asset.
- **A-T03 — App lifecycle and scheduling (P2).** Define one owner for active
  simulation and display scheduling, cancel timers/observers on teardown, and
  specify multiwindow behavior. Accept with mode/focus/resize/window-close tests
  and measured displayed frame latency, including source animation and plugins.
- **A-T04 — Startup-safe native adapters (P0, fixed in code; acceptance pending).**
  `StudioModel.configureSourceMutePlugin(configuration:)` read `NSApp.isActive`
  while `AppState.init` can call it before `NSApp` exists, so the release app
  trapped instead of reporting an error. Evidence: private
  `native-adapter-capture-01/run.log` is empty because of SIGTRAP; macOS report
  `Ikkoku-2026-09-25-071053.ips` identifies that method. Focus initialization now
  happens at a valid lifecycle point: immediately when `NSApp` exists, otherwise
  at `didFinishLaunching` (ST-T02). Headless execution injects focus with
  `IKKOKU_APPLICATION_FOCUS` and reports it with `IKKOKU_NATIVE_PLUGIN_REPORT`.
  Accept when `studio_execution_probe.py` with **both** original adapter
  manifests completes run/reload/continue, retains exact manifest hashes, passes
  its adapter-report checks and produces identical reload pixels. That run has
  not been made; see
  [native adapters](../reference/mods/native-adapters.md#startup-and-acceptance).
- **A-T05 — Capture result integrity (P2).** Make UI/thumbnail output failures
  observable and return nonzero on any required missing output. Test a destination
  that cannot be written and readiness timeout; no false “written” message.

## G. Gameplay cycle, event selection and ADV

Sources: [SourceGameplayCycle.swift](../../Packages/Engine/Sources/Gameplay/SourceGameplayCycle.swift),
[SourceFixedEventScheduler.swift](../../Packages/Engine/Sources/Gameplay/SourceFixedEventScheduler.swift),
[SourceADVInterpreter.swift](../../Packages/Engine/Sources/Gameplay/SourceADVInterpreter.swift).
Recovery: `Tools/reverse/analysis/gameplay_contract.py` and
`gameplay_execution_contract.py`; CLI: `GameplayTrace.swift` and
`GameplayExecutionInspection.swift`.

| ID / feature | Status | Specific review comments | Remaining work / acceptance |
| --- | --- | --- | --- |
| G01 · Period/week values and pure transitions | Fully ported — bounded control kernel | Twelve saved period ordinals, seven weekdays, backward-period day advance, same-week seven-day advance and night-menu completion rules are explicit. Negative invalid weekday arithmetic is deliberately rejected instead of reproducing a source nonterminating search. | Keep this scope distinct from scenes/menus; add regressions when more host callbacks are connected. |
| G02 · MapMove timing/gates | Fully ported — bounded timer kernel | Cursor/game regulation controls advancement; ADV/talk/interaction flags control visibility separately. Frame increments may overshoot 500; finish forces display fraction 1 without clamping stored timer. | Supply real source flags through G-T01; current caller-supplied flags are not gameplay integration. |
| G03 · Deferred scene/menu/NPC effects | Infancy | The cycle returns `SourceGameplayDeferredEffect` values such as `loadNPCs`, `prepareNextPeriodSceneBarrier`, tutorial and sunlight changes. Returning an enum does not execute any of these operations. | G-T01: implement a host dispatcher with acknowledged completion/barriers. |
| G04 · Fixed-event table decode and eligibility | Fully ported — inspected selection rules | First unfinished event only; weekday/period/day/lesson conditions, map lookup and wait-point layer match. Failed eligibility does not search later unfinished events. Tested against 4,032 independent contexts for 48 source entries. | Extend catalog coverage independently; selected event still needs G-T02 dispatch. |
| G05 · Fixed-event placement and execution | Pending | `Selection` contains asset, map and optional wait-point/layer identity. No NPC entity spawn, movement, encounter dispatch or completion persistence consumes it in the app. | G-T02: bind selection to native state and a recovered scenario with exact completion flags. |
| G06 · ADV program decoding and batch/wait execution | Mid-stage | Bounded program/argument/variable sizes; `multi` batching, local jump recursion budget, cancelable Wait and explicit ready/waiting/faulted/exhausted states. A fault preserves already-executed scalar effects for inspection; this VM is not a transaction. | G-T03: implement frame/task/scene host integration and saveable running-state model. |
| G07 · ADV scalar commands | Mid-stage | IDs 0/1/3/4/12/14/15/22/23/25 implement None, VAR, Calc, Clamp, Tag, IF, Switch, Close, local Jump and Wait. Int32 wrapping and source boxed conversion failures are deliberate. Calc is left-to-right. | Expand unsupported numeric literals, source RNG alternatives and culture-sensitive comparisons only with source oracles; keep unsupported cases explicit. |
| G08 · ADV source data exercised | Infancy | Original scenario 301 executes Calc/Clamp then halts at pc 2 / command 165 (`HeroineParam`). The executable prefix is evidence, not scenario completion. | G-T02: implement player/heroine parameter binding first and reproduce the complete numeric scenario. |
| G09 · Dialogue, choices and UI flow | Pending | No text/choice renderer, input state, localization flow or dialogue backlog is driven by ADV. `requestNext` is supplied by tests/CLI. | G-T03: recover blocking semantics, implement display/input actions and test skip/choice/save/load. |
| G10 · Cross-file ADV, tasks, animation/camera/audio actions | Pending | External `file:tag` jumps and unknown commands fault with command index/reason. Studio animation/audio consumers are not wired to ADV. | G-T03: identity-preserving scenario resolver plus typed presentation commands and cancellation barriers. |
| G11 · NPC population, navigation and decisions | Pending | No native NPC behavior-tree runner, source action/navigation tables, map topology, pathfinding or encounter loop is connected. | G-T04: recover one map and one neutral NPC route; implement decisions, movement and save-state continuity against numeric traces. |
| G12 · Original game save/session state | Pending | Character cards and Studio documents are separate formats; neither supplies original player/heroine campaign save state. | G-T01/G-T02: recover native session schema and original load/save adapters before treating scalar variables as campaign state. |
| G13 · Full original game screens/modes | Pending | The app has Maker and Studio only. Original title/start/load, school/map interaction, menus and the remaining game modes are absent. | Build an explicit recovered mode inventory with dependencies and one vertical slice per mode; no overall completion percentage is defensible yet. |

### Actionable gameplay tasks

- **G-T01 — Session and deferred-effect host (P1).** Inventory every
  `SourceGameplayDeferredEffect`, classify synchronous work vs completion barrier,
  implement acknowledgements, and persist in-flight state. Acceptance: no period
  advance before its dependencies complete; reload during a barrier is deterministic.
- **G-T02 — Character bindings and event completion (P1).** Recover original
  player/heroine data access, event flags and `HeroineParam`; implement typed
  bindings without renaming original IDs. Acceptance: the existing original
  scenario 301 finishes with source-verified values and a fixed event executes
  once across save/reload.
- **G-T03 — Expand ADV by command family (P1/P2).** Export an inventory of every
  command used by selected scenarios, including counts and unsupported reasons.
  Implement file resolution, dialogue/choices, async tasks and presentation
  consumers with cancellation/save rules. Acceptance: scenario command coverage
  is measured and unsupported commands halt at the correct source index.
- **G-T04 — NPC vertical slice (P2).** Extract wait points/navigation/action data
  for one map; implement decisions and movement separately from render animation.
  Acceptance: captured source numeric positions/decisions match over a fixed
  trace, including map transitions, interaction interruption and resumed state.

## P. C# translation, plugin runtime and native adapters

Sources: `Packages/Engine/Sources/Gameplay/Source{TranslatedBehaviour,IRProgram,PluginPackage,PluginRuntime,NativePluginPackage,MuteInBackgroundPlugin}.swift`;
`Tools/translation/{translate,plugin,native_adapters,studio_execution_probe}.py`;
`Tools/translation/frontend/{Program.cs,UnitySurface.txt,Translation.csproj}`.
Concrete Studio integration is covered in [Studio](studio.md).

| ID / feature | Status | Specific review comments | Remaining work / acceptance |
| --- | --- | --- | --- |
| P01 · Semantic C# frontend | Mid-stage | Roslyn resolves symbols against a declaration-only Unity/BepInEx surface. Same-named user methods are not blindly replaced. Selected utilities must be static; components directly inherit the supported base. | P-T01: expand from real rejected source demand, preserving semantic resolution. |
| P02 · Supported expressions/control flow | Mid-stage | Typed locals/fields, blocks, assignments, if/return, ternary, selected float/vector operations, comparisons and short circuit are implemented. Integer arithmetic, loops, properties, exceptions, arbitrary inheritance/generics/overloads are rejected. Supported type names do not imply all operations on that type. | Add each construct with an original C# differential oracle, particularly overflow/evaluation order before loops or collections. |
| P03 · Unity API substitution | Mid-stage | `Mathf.Clamp01/Lerp/Sqrt`, clock reads, object/transform access, position/localPosition/localScale, Translate, Instantiate, Destroy and SetActive have explicit mappings. Rotations, Animator, renderer/material, input, scene APIs and most Unity components do not. | P-T01: expose real engine consumers behind typed source APIs; never replace an unrecognized API with a no-op. |
| P04 · Generated Swift utilities | Mid-stage | IR can emit compilable Swift plus provenance. `SourceBehaviourDriver` is a small utility harness, not the scene-wide lifecycle scheduler. Two recovered `MathfEx` methods match 4,002 original-DLL evaluations. | Broaden differential tests per newly accepted family; do not extrapolate two methods to complete gameplay recovery. |
| P05 · Runtime IR validation/interpreter | Mid-stage | Runtime validates operations/arity/type surface, field state and lifecycle shapes. Instructions, AST nesting, recursive invocation and component counts are bounded. Float/double bit patterns are stored. Unsupported serialized object fields fail. | P-T04: fuzz manifests/IR and cross-check interpreter vs generated Swift/original C#; include malformed nested IR and budget rollback. |
| P06 · Eight Unity lifecycle callbacks | Fully ported — controlled supported-component cases | Awake, OnEnable, Start, FixedUpdate, Update, LateUpdate, OnDisable and OnDestroy ordering is tested against a controlled original Unity 5.6.2f1 player. Clone-created Start/LateUpdate behavior and deferred destruction are represented. | Additional Unity messages, scene persistence, arbitrary component ordering, coroutines and physics callbacks remain outside this claim. |
| P07 · Clone serialization/activation/destruction | Fully ported — supported fields and objects | Public/SerializeField copied; private/NonSerialized reset to initializers. Clone Awake/Enable runs before Instantiate returns. Destroy deactivates immediately and finalizes at a frame barrier. Tombstones retain saved identity. | Extend only when object references/component graphs have a defined source-preserving representation. |
| P08 · Failure rollback and clocks | Mid-stage | Callback/whole-frame failures restore world snapshots, fields, lifecycle flags, clock, trace and new entries. Studio also checkpoints Animator/dynamics for an afterUpdate failure. Default fixed-step catch-up is capped at 64; failure is deliberate, not source time truncation. | Test additional host consumers before including them in transactions; profiler must account for snapshot cost. |
| P09 · BepInEx metadata/dependencies/process filters | Mid-stage | GUID/name/version, hard/soft dependencies, incompatibilities and process names are retained. Ordinal UTF-8 identity avoids Swift canonical equivalence. Missing dependencies/cycles/conflicts fail. Process matching uses a Foundation case-insensitive approximation. | P-T02: test source loader corner cases, validate standalone versions, define global native-adapter/IR dependency graph and permitted duplicate/version policy. |
| P10 · Immutable packaging and static DLL recovery | Mid-stage | `.cs` or bounded `.dll` input; DLLs are statically decompiled, not loaded. New generations preserve source/program hashes. Rejected conversion has diagnostics but no loadable manifest. Exact two-DLL registry selects verified Swift adapters. | P-T02: batch discovery/triage, assembly dependencies, multiple types and compatibility report; bind converter version and migrations to saved profiles. |
| P11 · IR plugin execution in Studio | Mid-stage | Explicit profile binds original source keys or native UUIDs. Local/world transforms, attachment frames, subtree clones and identity preservation work. Native save/reload persists clocks/fields without replaying Start. | App controls for bindings/unload and source-object topology changes; no implicit source BepInEx manager exists. |
| P12 · Original MuteInBackground 1.1 behavior | Fully ported — bounded initial config/focus callback | Exact installed GUID/hash registry; original config parsing oracle covers 23 cases and seven focus traces, including the repeat-focus-loss quirk. Audio bus mixer endpoint tested with a generated tone. | Live config-file watching and multiple static copies are unsupported. The app startup trap is fixed in code, but the app mount still needs the A-T04 release run. |
| P13 · Original StudioAccessoryNames 1.1.0 behavior | Fully ported — bounded label pass | Recovered coroutine result matches three source-host cases, including UTF-16 digit detection and missing slots. Mount enables the native label model; source identities are unchanged. | Actual inspector integration is blocked by the source-character UI gate; Studio audit records that defect. General Unity UI/coroutine execution is not provided. |
| P14 · Native adapter package/persistence validation | Mid-stage | Exact assembly/type/GUID/version/process/config hashes required. Saved scene references reject changed packages. Three native package tests and one Python packaging test pass with original fixtures. The execution probe now compares mounted references with each phase's adapter report. | P-T03/A-T04: successful actual-app mount/save/reload has not passed. The latest recorded run trapped before capture and predates the startup fix. |
| P15 · Arbitrary installed managed plugin compatibility | Infancy | Automatic rewriting works only for the explicit AST/API subset; native adapters cover two exact installed revisions. There is no proof of compatibility with 243 DLLs in the surveyed plugin directory (which includes libraries). | P-T01/P-T02: inventory loadable types, prioritize common APIs and measure supported/rejected behavior by exact revision. |
| P16 · Harmony, coroutines, reflection, extended Unity API | Pending | No generic Harmony patch host, coroutine scheduler, reflection/unsafe execution or arbitrary Windows helper runtime. Unsupported code is rejected rather than partially run. | Define supported patch/event seams, state-machine translation and isolation boundaries; validate actual recovered plugin logic one family at a time. |
| P17 · Unknown plugin data / edited-original export | Mid-stage | Card/scene bytes retain unknown plugin payloads. Native translated runtime state is saved in native metadata; edited original scene export rejects live IR state without a KKEx adapter. | P-T05: implement GUID-specific source serialization; byte-preservation does not establish plugin execution. |

### Actionable plugin tasks

- **P-T01 — Measured API coverage (P1).** Statically enumerate installed plugin
  entry types and referenced APIs, record assembly hashes and source diagnostics,
  then rank missing APIs by concrete plugins they unblock. Add one bounded family
  at a time with original behavior evidence. Acceptance: reports distinguish
  package discovered, source recovered, translation accepted, host integrated and
  original behavior verified; none is reported simply as “compatible”.
- **P-T02 — Unified immutable plugin library (P1).** Add scanner/generations for
  IR and native adapters, exact revision selection, dependency resolution across
  both kinds, standalone version validation and original loader edge tests.
  Acceptance: changed source creates a new generation, an old saved scene retains
  its selection, conflicts/missing versions never silently remap identities.
- **P-T03 — Actual app regression (P1, depends on A-T04 and Studio inspector fix).**
  Run the existing three-stage capture probe with both installed adapters and the
  IR motion fixture. Then exercise focus gain/loss with generated audio and verify
  accessory labels through the reachable UI. Acceptance includes manifest hashes,
  fields/clocks/source keys, identical reload pixels and no startup trap.
- **P-T04 — Interpreter/host differential testing (P2).** Compare identical
  programs in original C#, generated Swift and interpreted IR; add invalid input,
  nesting/fuel, activation callbacks and host failure injection. Acceptance:
  deterministic outputs or explicit unsupported diagnostics, with no partial
  world/field mutation after rejected callbacks.
- **P-T05 — Original save adapters (P2).** Recover one real plugin's scene/card
  writer and update only its known KKEx fields. Acceptance: edited original opens
  in the source game, stable GUID/version survives, unknown siblings remain byte
  identical and unsupported translated fields still block lossy export.

## Evidence and specific cautions

- Gameplay tests: `SourceGameplayCycleTests.swift`,
  `SourceGameplayExecutionTests.swift`, `test_gameplay_contract.py`,
  `test_gameplay_execution_contract.py`. Their references are independent
  calculations/recovered-source fixtures, **not a complete running game**.
- Plugin tests: `SourcePluginRuntimeTests.swift`,
  `SourceNativePluginPackageTests.swift`, `SourceMuteInBackgroundTests.swift`,
  `Tools/translation/tests/test_translation.py`, `test_native_adapters.py` and
  `test_studio_execution_probe.py` (probe report rules only; no app launch).
  Original fixtures are gated by environment/local files; see the toolchain audit
  before interpreting a green run with absent fixtures.
- Private `release-capture-01/report.json` proves an IR-only release app
  run/save/reload/continue with pixel-identical reload, Start count 1 and unchanged
  identity. It does **not** prove original-adapter mounting. The later
  `native-adapter-capture-01` failed with the AppKit initialization trap; rerun
  it after the A-T04 fix.
- Existing [plugin execution](../reference/mods/plugin-execution.md), [API substitution](../reference/mods/api-substitution.md) and
  [native adapters](../reference/mods/native-adapters.md) describe narrower contracts. Historical
  “remaining work” prose elsewhere can be stale; this audit separates recovered
  kernels, host wiring and user-visible functionality.
