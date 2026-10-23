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
- **A-T04 — Startup-safe native adapters (Completed P0, verified at `93e6b06`).**
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
  its adapter-report checks and produces identical reload pixels. Both installed-disabled and explicit-enabled runs passed; evidence is in
  `.local/reverse/plugin-execution/accepted-pr-2/`. See
  [native adapters](../reference/mods/native-adapters.md#startup-and-acceptance).
- **A-T05 — Capture result integrity (P2).** Make UI/thumbnail output failures
  observable and return nonzero on any required missing output. Test a destination
  that cannot be written and readiness timeout; no false “written” message.

## G. Gameplay cycle, event selection and ADV

Sources: [SourceGameplayCycle.swift](../../Packages/Engine/Sources/Gameplay/SourceGameplayCycle.swift),
[SourceGameplaySession.swift](../../Packages/Engine/Sources/Gameplay/SourceGameplaySession.swift),
[SourceFixedEventScheduler.swift](../../Packages/Engine/Sources/Gameplay/SourceFixedEventScheduler.swift),
[SourceADVInterpreter.swift](../../Packages/Engine/Sources/Gameplay/SourceADVInterpreter.swift),
[SourceADVHostRequest.swift](../../Packages/Engine/Sources/Gameplay/SourceADVHostRequest.swift),
[SourceADVArgumentParsing.swift](../../Packages/Engine/Sources/Gameplay/SourceADVArgumentParsing.swift).
Recovery: `Tools/reverse/analysis/gameplay_contract.py`,
`gameplay_execution_contract.py`, `adv_command_coverage.py` and `adv_host_requests.py`; CLI: `GameplayTrace.swift` and
`GameplayExecutionInspection.swift`.

| ID / feature | Status | Specific review comments | Remaining work / acceptance |
| --- | --- | --- | --- |
| G01 · Period/week values and pure transitions | Fully ported — bounded control kernel | Twelve saved period ordinals, seven weekdays, backward-period day advance, same-week seven-day advance and night-menu completion rules are explicit. Negative invalid weekday arithmetic is deliberately rejected instead of reproducing a source nonterminating search. | Keep this scope distinct from scenes/menus; add regressions when more host callbacks are connected. |
| G02 · MapMove timing/gates | Fully ported — bounded timer kernel | Cursor/game regulation controls advancement; ADV/talk/interaction flags control visibility separately. Frame increments may overshoot 500; finish forces display fraction 1 without clamping stored timer. | Supply real source flags from the gameplay host (A-T01, over the G-T01 session); current caller-supplied flags are not gameplay integration. |
| G03 · Deferred scene/menu/NPC effects | Mid-stage — engine host, no app consumer | `SourceGameplaySession` classifies all 19 `SourceGameplayDeferredEffect` cases in an exhaustive switch: 11 synchronous, 8 completion barriers, of which `loadNPCs`, `prepareMapMoveCharactersAndCamera` and `startTimeZoneCutIn` are conservative because their source completion is not recovered. It releases effects in source order, requires an ID-and-effect acknowledgement per barrier, rejects unknown, duplicate, out-of-order and mismatched acknowledgements without mutation, and commits the cycle only after the operation's last barrier. Version-1 snapshots reload deterministically mid-barrier and reject other versions and inconsistent state. It still executes none of the effects; verification is the synthetic Engine suite in CI ([session host](../reference/gameplay/cycle.md#session-host-and-effect-inventory-g-t01)). | A-T01: an app host executes each effect and acknowledges barriers from real scene/ADV/NPC completion, including cancellation. Replace a conservative barrier only with recovered completion evidence. |
| G04 · Fixed-event table decode and eligibility | Fully ported — inspected selection rules | First unfinished event only; weekday/period/day/lesson conditions, map lookup and wait-point layer match. Failed eligibility does not search later unfinished events. Tested against 4,032 independent contexts for 48 source entries. | Extend catalog coverage independently; selected event still needs G-T02 dispatch. |
| G05 · Fixed-event placement and execution | Pending | `Selection` contains asset, map and optional wait-point/layer identity. No NPC entity spawn, movement, encounter dispatch or completion persistence consumes it in the app. | G-T02: bind selection to native state and a recovered scenario with exact completion flags. |
| G06 · ADV program decoding and batch/wait execution | Mid-stage | Bounded program/argument/variable sizes; `multi` batching, local jump recursion budget, cancelable Wait. Since G-T03b the frame follows `MessageWindowProc`: `UpdateRegulate` gates (pending MapChange, or SceneFade under `isSceneFadeRegulate`) suspend input, Waits and commands; a Text batch waits for Next; `ProcessEnd`/`CurrentCharaData.Clear` run where the source runs them. States: ready/frameBoundary/waiting/awaitingHost/awaitingNext/closed/exhausted/faulted. The whole interpreter is `Codable` and resumes identically mid-wait, mid-acknowledgement and mid-Next (validated on decode). A fault preserves earlier effects; this VM is not a transaction. | G-T01: drive it from a real frame/session host that persists it inside the campaign save; add skip/auto and choice input. |
| G07 · ADV scalar and presentation commands | Mid-stage | Scalar IDs 0/1/3/4/12/14/15/22/23/25 (None, VAR, Calc, Clamp, Tag, IF, Switch, Close, local Jump, Wait): Int32 wrapping and source boxed conversion failures are deliberate; Calc is left-to-right. Presentation IDs 16–19, 35, 37, 44, 45, 88, 106, 112, 125, 128, 169 (Text, Voice, Motion, Expression, NullLoad, NullSet, SceneFade, SceneFadeRegulate, BGMPlay, CharaMotion, CharaExpression, CharaLookEyes, CharaLookNeck, MapChange) decode arguments exactly as the recovered `Do()` (defaults, `ReplaceVars`, Unity Mono `int`/`float`/`bool` parsing, swallowed vs uncaught exceptions) into typed host requests with per-handler blocking (none / acknowledge / Next); unmodelled culture or Unicode forms fault instead of guessing. 22 of these IDs occur in 239,612 of 294,393 installed records; 101 VAR random alternatives and 299 external IF branches still fault. | Expand RNG alternatives, unsupported literals and culture-sensitive comparisons only with source oracles. Add the next request families (Fade, BGLoad/BGRelease, Filter, CharaCoordinate, CharaMotionDefault, CharaVoicePlay/Wait) the same way; rerun `adv_command_coverage.py` after each change. |
| G08 · ADV source data exercised | Infancy | All 10,463 `ScenarioData` assets in the 225 installed `adv/scenario` bundles were run with default inputs and a scripted host (auto-acknowledge, auto-Next): **2,633 run to completion** (2,559 non-empty, 25,892 records; before G-T03b: 87, 13 non-empty), 7,582 halt at the statically predicted index, ID and reason, 248 fault earlier on absent host variables, 0 unexplained. 51,953 host requests were issued and all match an independent Python decoding of the recovered handlers; 9,926 straight-line assets match the predicted request sequence exactly. 27.5% of records now precede a first unsupported command (was 0.46%). Scenario 301 still halts at pc 2 / 165 (`HeroineParam`). Nothing is presented: no host consumes the requests. | G-T02: `HeroineParam`/`ParameterFile` (now the top first blocker, 2,030 assets). G-T03: next families in the measured order ([ADV coverage](../reference/gameplay/adv.md#original-scenario-command-coverage-g-t03)). |
| G09 · Dialogue, choices and UI flow | Infancy | Text (63,122 records) now issues `text` requests carrying the batch's voice/expression/motion bindings and blocks until Next; Voice/Expression/Motion records decode into those bindings. 15,692 Text requests were issued in the corpus run, all matching the independent model. No renderer, name-tag `ReplaceText`, backlog, display-completion click, skip/auto or choice exists; `requestNext` is supplied by tests/CLI. Choice (466 records) is unsupported. | A-T01/G-T01: a host that displays text and plays voices from the requests; G-T03: choices, skip/auto and save/load during dialogue. |
| G10 · Cross-file ADV, tasks, animation/camera/audio actions | Pending | Character look/expression/motion, BGM, map change, ADV null positions and scene fades are typed requests (none executed natively: no host). External `file:tag` jumps and unknown commands fault with command index/reason, checked across the installed corpus. Top first blockers now: ParameterFile 2,030 assets, Fade 1,648, BGLoad 1,235, CharaVoicePlay 589, Filter 452, CharaMotionDefault 386, CharaCoordinate 296, Open 253. Open has 2,869 records; Task/TaskEnd 156/117. | G-T03: further request families in that order, an identity-preserving scenario resolver for Open/external branches, and cancellation barriers; a host must consume the requests. |
| G11 · NPC population, navigation and decisions | Pending | No native NPC behavior-tree runner, source action/navigation tables, map topology, pathfinding or encounter loop is connected. | G-T04: recover one map and one neutral NPC route; implement decisions, movement and save-state continuity against numeric traces. |
| G12 · Original game save/session state | Pending | Character cards and Studio documents are separate formats; neither supplies original player/heroine campaign save state. The G-T01 session snapshot persists only native cycle control state and pending barriers. | G-T02: recover original load/save adapters and extend the native session schema before treating scalar variables as campaign state. |
| G13 · Full original game screens/modes | Pending | The app has Maker and Studio only. Original title/start/load, school/map interaction, menus and the remaining game modes are absent. | Build an explicit recovered mode inventory with dependencies and one vertical slice per mode; no overall completion percentage is defensible yet. |

### Actionable gameplay tasks

- **G-T01 — Session and deferred-effect host (P1).** Inventory every
  `SourceGameplayDeferredEffect`, classify synchronous work vs completion barrier,
  implement acknowledgements, and persist in-flight state. Acceptance: no period
  advance before its dependencies complete; reload during a barrier is deterministic.
  Engine slice implemented: `SourceGameplaySession` classifies every effect
  ([inventory and source basis](../reference/gameplay/cycle.md#session-host-and-effect-inventory-g-t01)),
  requires typed acknowledgements, commits no period/day advance before its
  operation's last barrier and persists in-flight state as a versioned snapshot.
  `SourceGameplaySessionTests.swift` checks both acceptance criteria on synthetic
  traces, including a JSON reload at each of the 52 barriers of a
  Friday-to-Wednesday trace; this is the synthetic Engine suite in CI, not
  original-host evidence. Remaining: no app host consumes it (A-T01); it
  neither owns nor persists a running `SourceADVInterpreter`, whose request
  acknowledgements stay separate (G06); cancellation during a barrier is not
  modelled; the three conservative barriers need recovered completion rules; and
  timer operations are rejected while a barrier is outstanding.
- **G-T02 — Character bindings and event completion (P1).** Recover original
  player/heroine data access, event flags and `HeroineParam`; implement typed
  bindings without renaming original IDs. Acceptance: the existing original
  scenario 301 finishes with source-verified values and a fixed event executes
  once across save/reload.
- **G-T03 — Expand ADV by command family (P1/P2).** First slice done:
  `adv_command_coverage.py` inventories all 225 installed scenario bundles
  (10,463 assets, 294,393 records, 120 ordinals) with recovered handler classes
  and checks native halts. Second slice done: CharaLookNeck/LookEyes, BGMPlay,
  CharaExpression/CharaMotion, Expression/Motion/Voice, Text, MapChange,
  NullLoad/NullSet and SceneFade/SceneFadeRegulate execute as typed, saveable host
  requests with source argument parsing and blocking; with a scripted host 2,633
  assets run to completion and every other asset halts at its predicted index or
  on an absent host variable (0 unexplained), and all 51,953 issued requests
  match an independent Python model. The gated sample test
  (`IKKOKU_ADV_COVERAGE_SAMPLE`, 36 assets) checks halts and request sequences.
  ParameterFile is deferred to G-T02 (it inserts library scenarios that use
  HeroineParam). Next: Fade, BGLoad/BGRelease, Filter, CharaCoordinate,
  CharaMotionDefault, CharaVoicePlay/Wait as requests; then file resolution
  (Open, external IF branches), choices and async tasks with cancellation/save
  rules. Acceptance per family: its records execute through a typed host
  request, a rerun moves the affected halts to the next predicted index with 0
  unexplained mismatches and 0 request mismatches, and dialogue/choice slices
  test skip, choice and save/reload against a real host.
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
| P05 · Runtime IR validation/interpreter | Mid-stage | Runtime validates operations/arity/type surface, field state and lifecycle shapes. Instructions, AST nesting, recursive invocation and component counts are bounded. Float/double bit patterns are stored. Unsupported serialized object fields fail. P-T04 Swift slice (`SourcePluginFaultInjectionTests.swift`, synthetic): 256 seeded IR mutations and 80 manifest mutations must either load and run identically twice or fail with a defined error, and 256 random typed expressions must match an independent Swift evaluation bit for bit (NaN/infinity included). Fuel, evaluation depth, recursion and fixed-step exhaustion must raise the budget error. Verification is the CI Engine suite only. | P-T04 remainder: the original-C#/generated-Swift leg (`test_translation.py`, needs .NET and swiftc) and mutation seeds taken from real translated plugins. |
| P06 · Eight Unity lifecycle callbacks | Fully ported — controlled supported-component cases | Awake, OnEnable, Start, FixedUpdate, Update, LateUpdate, OnDisable and OnDestroy ordering is tested against a controlled original Unity 5.6.2f1 player. Clone-created Start/LateUpdate behavior and deferred destruction are represented. | Additional Unity messages, scene persistence, arbitrary component ordering, coroutines and physics callbacks remain outside this claim. |
| P07 · Clone serialization/activation/destruction | Fully ported — supported fields and objects | Public/SerializeField copied; private/NonSerialized reset to initializers. Clone Awake/Enable runs before Instantiate returns. Destroy deactivates immediately and finalizes at a frame barrier. Tombstones retain saved identity. | Extend only when object references/component graphs have a defined source-preserving representation. |
| P08 · Failure rollback and clocks | Mid-stage | Callback/whole-frame failures restore world snapshots, fields, lifecycle flags, clock, trace and new entries. Studio also checkpoints Animator/dynamics for an afterUpdate failure. Default fixed-step catch-up is capped at 64; failure is deliberate, not source time truncation. P-T04 fixed a defect: a field initializer that cloned or deactivated an object ran the clone/activation callbacks of other components outside any runtime transaction, so a later initializer failure left their fields, flags and trace. `attach` is now one transaction. Synthetic tests inject failures into all eight callbacks, Instantiate/Destroy/SetEnabled, every attachment-resolver call of a frame and `afterUpdate`, compare full snapshots, and check that retried runs match a clean run in the documented order. | Test additional host consumers before including them in transactions; the app-side Animator/dynamics checkpoint (`StudioModel`) has no Engine test; profiler must account for snapshot cost. |
| P09 · BepInEx metadata/dependencies/process filters | Mid-stage | GUID/name/version, hard/soft dependencies, incompatibilities and process names are retained. Ordinal UTF-8 identity avoids Swift canonical equivalence. Missing dependencies/cycles/conflicts fail. Process matching uses a Foundation case-insensitive approximation. | P-T02: test source loader corner cases, validate standalone versions, define global native-adapter/IR dependency graph and permitted duplicate/version policy. |
| P10 · Immutable packaging and static DLL recovery | Mid-stage | `.cs` or bounded `.dll` input; DLLs are statically decompiled, not loaded. New generations preserve source/program hashes. Rejected conversion has diagnostics but no loadable manifest. Exact two-DLL registry selects verified Swift adapters. | P-T02: batch discovery/triage, assembly dependencies, multiple types and compatibility report; bind converter version and migrations to saved profiles. |
| P11 · IR plugin execution in Studio | Mid-stage | Explicit profile binds original source keys or native UUIDs. Local/world transforms, attachment frames, subtree clones and identity preservation work. Native save/reload persists clocks/fields without replaying Start. | App controls for bindings/unload and source-object topology changes; no implicit source BepInEx manager exists. |
| P12 · Original MuteInBackground 1.1 behavior | Fully ported — bounded initial config/focus callback | Exact installed GUID/hash registry; original config parsing oracle covers 23 cases and seven focus traces, including the repeat-focus-loss quirk. Audio bus mixer endpoint tested with a generated tone. A-T04 Release startup, persistence and focus/gain acceptance passed in PR #2. | Live config-file watching and multiple static copies are unsupported. |
| P13 · Original StudioAccessoryNames 1.1.0 behavior | Fully ported — bounded label pass | Recovered coroutine result matches three source-host cases, including UTF-16 digit detection and missing slots. Mount enables the native label model; source identities are unchanged. | Actual inspector integration is blocked by the source-character UI gate; Studio audit records that defect. General Unity UI/coroutine execution is not provided. |
| P14 · Native adapter package/persistence validation | Mid-stage | Exact assembly/type/GUID/version/process/config hashes required. Saved scene references reject changed packages. Three native package tests and one Python packaging test pass with original fixtures. The execution probe now compares mounted references with each phase's adapter report. | P-T03/A-T04: actual-app mount/save/reload passed in PR #2; wider plugin integration remains pending. The earlier `native-adapter-capture-01` startup trap is historical and superseded by the accepted run. |
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
  world/field mutation after rejected callbacks. Swift slice done in
  `SourcePluginFaultInjectionTests.swift` (synthetic fixtures; verified only by
  the CI Engine suite, not compiled locally). Fixed-seed SplitMix64 mutation of IR
  structure, kinds, names, arity, operand types, nesting, constants, oversized
  collections, duplicated/truncated statements, lifecycle shapes, headers and raw
  bytes, plus manifest fields, paths, hashes and sizes. Every operation either
  commits with finite host transforms and declared field types or throws a defined
  error and restores the full snapshot (document, identities, clone serial,
  pending destruction, fault, bindings, clock, trace). A second run must match the
  first. An independent Swift evaluation of random typed expressions acts as an
  oracle for the interpreter's arithmetic. Budget, lifecycle and host failure
  injection tests cover fuel, nesting, recursion, activation ping-pong, fixed-step
  catch-up, clone/destroy callbacks, attachment-resolver calls and `afterUpdate`,
  including through `SourceStudioPluginSession`. The rejected-attach rollback
  defect was fixed (P08). Remaining: the original-C# and generated-Swift legs via
  `Tools/translation/tests/test_translation.py` (.NET/swiftc), mutation corpora
  from real translated plugins, and app-level host consumers.
- **P-T05 — Original save adapters (P2).** Recover one real plugin's scene/card
  writer and update only its known KKEx fields. Acceptance: edited original opens
  in the source game, stable GUID/version survives, unknown siblings remain byte
  identical and unsupported translated fields still block lossy export.

## Evidence and specific cautions

- Gameplay tests: `SourceGameplayCycleTests.swift`,
  `SourceGameplaySessionTests.swift`,
  `SourceGameplayExecutionTests.swift`, `test_gameplay_contract.py`,
  `test_gameplay_execution_contract.py`, `test_adv_command_coverage.py`. Their references are independent
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
