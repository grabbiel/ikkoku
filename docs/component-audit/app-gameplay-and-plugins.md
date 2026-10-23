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
[AppState+OriginalFrameProbe.swift](../../Apps/IkkokuCreator/AppState+OriginalFrameProbe.swift),
[AppState+GameplayScenario.swift](../../Apps/IkkokuCreator/AppState+GameplayScenario.swift),
[CaptureOutput.swift](../../Packages/Engine/Sources/Renderer/CaptureOutput.swift),
[CaptureRequest.swift](../../Packages/Engine/Sources/Renderer/CaptureRequest.swift).

| ID / feature | Status | Specific review comments | Remaining work / acceptance |
| --- | --- | --- | --- |
| A01 · SwiftUI shell, Maker/Studio switching and shared engine | Mid-stage | Both editors share one `EngineHost` and renderer. Mode changes activate one model and refresh its frame. There is no interactive ActionGame/title/gameplay mode. Since A-T01's first slice, `IKKOKU_GAMEPLAY_SCENARIO` runs the native gameplay host headlessly and exits before the engine and both editors are created, so it shares no editor state; CI compiles this path but has not run it. | A-T01: run the `gameplay-scenarios` lane on the Mac; then an interactive gameplay mode with presentation on the same host, keeping editor isolation. |
| A02 · Metal startup and asset discovery | Mid-stage | Explicit `IKKOKU_ASSETS`, bundle assets, then source-tree assets. Optional original male/female manifests and Maker library are separate private inputs. Explicit invalid source overrides fail instead of silently selecting another source. Development defaults depend on build-machine paths. Since 2026-10-23 (T-T02), each used source-tree default prints a `[ikkoku] source-tree fallback:` line, and `IKKOKU_SOURCE_TREE_FALLBACKS=0` disables all three (assets root, Maker library, original bases); without it the defaults are unchanged. Compiled by CI only; no launch has exercised the switch. Since 2026-10-23 (A-T02 first slice), File → Choose Converted Library… saves a versioned `ResourceLibraryLocation`. It identifies each library by its manifest's SHA-256 and format version, and the Maker library and base lookups read it after their explicit variables and before those fallbacks. Saved Studio scenes record a resource binding. On load, a reference into a moved library relocates only to the file with the recorded digest, inside the library with the recorded content and under R5 containment. Every other reference is reported unresolved by identity, and its object is not loaded ([contract](../reference/native-assets.md#library-location-and-relocation-a-t02)). Synthetic Engine tests cover the resolver; the app path is compiled by CI only. | A-T02 (partial): run the moved-library acceptance in the [build guide](../guides/build-and-test.md#use-a-converted-library-outside-the-checkout) on a Release app outside the checkout. Still missing: a first-run conversion flow, selection of the source-scene conversion inputs that still come from environment variables, and checks for native card catalog IDs and plugin paths. |
| A03 · Viewport display and input | Mid-stage | `CAMetalDisplayLink` drives drawable presentation; Retina pixel conversion, orbit/pan/zoom, trackpad magnification, mouse and key delegation exist. Simulation uses editor timers, not this presentation timestamp. | A-T03: instrument displayed frames and simulation cadence together; validate resize, focus loss, mode switching and more than one window. |
| A04 · File commands and error presentation | Mid-stage | Native cards/scenes, original-card fallback, static model import, original layout/scene preview and edited-original export are separate commands. Errors usually become an alert/status. These commands do not imply format-complete interoperability. | Verify all source/native branches, cancellation and failed import state preservation through UI tests; format details belong to the Character/Studio audits. |
| A05 · Source Maker → Studio transfer | Pending | `Send to Studio` is explicitly disabled while a source rig is active. The enabled command sends the bundled `CharacterCard`. Original cards can instead enter through source scene preview. | Preserve edited source card bytes, selection, outfit, resolver GUIDs and source rig references when adding a source character; compare Maker and Studio posed appearance. |
| A06 · Headless capture orchestration | Mid-stage — request validated up front; app runs not yet accepted | Environment switches cover rigs, models, source/native cards/scenes, shape/color edits, fixed animation time, scripted plugin steps, focus events, adapter reports, screenshots and benchmarks. Startup calls capture paths synchronously and exits before `NSApplication` finishes launching. Native adapter mounts no longer read `NSApp` there (A-T04, accepted in PR #2). Before any work, the engine `CaptureRequest` check classifies every `IKKOKU_*` variable the app reads. It exits 1, naming each offending variable in one message, for two modes, a mode without its output, a capture option no requested mode reads or one missing the option it acts with, a combination that captures other content, an empty value, a misspelled capture name or an ignored value (A-T06). `IKKOKU_NATIVE_PLUGIN_REPORT` and `IKKOKU_APPLICATION_FOCUS` need `IKKOKU_AUTOCAPTURE`. In every automated run a failed startup or capture input exits 1 naming the variable, value and error; `IKKOKU_CARD` and `IKKOKU_LOAD_SCENE` are no longer skipped. Startup inputs and data sources are not rejected by mode. CI runs the validator tests and an inventory drift check; the app path is only compiled there. | A-T06: run the [validation commands](../guides/build-and-test.md#capture-request-validation) and the `app-smoke` lane on the Mac and record the results. |
| A07 · Window UI capture and thumbnail generation | Mid-stage — checked outputs; app runs not yet accepted | Capture outputs go through the engine `CaptureOutput` writer: the `IKKOKU_CAPTURE_UI` PNG and report, every `IKKOKU_RENDER_THUMBS` thumbnail, offscreen and original-frame PNGs, and benchmark, scenario and plugin reports. It throws on a failed write and reads the file back; the file must be nonempty and byte-identical, and a PNG must be complete and decode at the captured size. A failure names the path and exits nonzero, and "written" prints only after verification. UI capture no longer sleeps 2.5 s. It polls until `onAppear` has run and a visible window's laid-out bounds are nonzero and stable for five 0.1 s polls, failing after `IKKOKU_CAPTURE_UI_TIMEOUT` (default 30 s). Thumbnails attempt every entry, report each failed load, render or write, and exit nonzero. `cacheDisplay` still omits most SwiftUI content (ST-D07). CI runs the engine tests; the app path is only compiled there. | A-T05: run the [local acceptance commands](../guides/build-and-test.md#offscreen-and-ui-captures) and the `app-smoke` lane on the Mac and record the results. |
| A08 · Original-frame probe entry point | Mid-stage | Produces generic-renderer, geometry/depth-normal and optional translated-shader diagnostic captures. Its own report correctly says frozen original geometry does not validate native rigs or scene loading. | Keep probe evidence separate from actual Maker/Studio frames; see renderer tasks R1/R2. |
| A09 · Mod library commands/UI | Mid-stage | Explicit load/reload with dependency reporting. Scanning/conversion happens in CLI tools; the app does not automatically discover newly installed Windows mods. | Connect conversion job status, compatibility results and explicit version selection to app workflow; see Character/mod audit. |
| A10 · Translated plugin commands | Mid-stage | Profile load plus run/pause are available in Mods. Converted original adapters have a separate manifest picker. Typed IR profiles require externally prepared object bindings. | Add inspectable package/binding/error UI, unload, replacement rules and original-plugin startup tests; P-T02/P-T03. |
| A11 · Multiwindow/document lifecycle | Infancy | `WindowGroup` is backed by one `@State AppState`; `sharedStudio` and `uiCaptureState` are process-global unsafe statics used for captures. This is not an independent document-per-window design. | A-T03: define whether multiple windows share or own documents, then test renderer ownership, timers, saves, focus and teardown accordingly. |
| A12 · Distribution readiness | Infancy | Local Xcode builds exist; bundle contents, private original-data discovery and CLI dependencies are development-oriented. No installer, first-run conversion flow, signing/notarization release workflow or clean-machine proof is present. | See toolchain T-T01/T-T02. |

### Actionable app tasks

- **A-T01 — Gameplay host (P1, after G-T01; first slice implemented 2026-10-23,
  app run pending).** Add a session model owning saved
  player/NPC state, period, active map and ADV barriers. Accept when a controlled
  non-media event can run from period selection to completion through the app,
  persist, reload and resume without caller-injected fake completion effects.
  First slice ([gameplay host](../reference/gameplay/cycle.md#gameplay-host-a-t01)):
  `SourceGameplayHost` in the Gameplay module owns one `SourceGameplaySession`,
  a versioned native state (`SourceGameplayNativeState`: saved and shown weekday,
  clock zone, sunlight, minimap/camera flag, active map, player and heroine
  placeholders, completed fixed events) and at most one running fixed event with
  its `SourceADVInterpreter`. The caller only stages cycle operations and steps
  the host; `session` is read-only, so it cannot acknowledge a barrier. The host
  performs every effect of `changePeriod`, `nextPeriod`, `changeWeek`, `nextWeek`
  and `reloadNightMenuWeek` on that state and completes their two barriers from
  its own state: the `_Next` scene barrier once no map loads and no event runs,
  and the ADV-gated period-routine replacement once the event has ended. The new
  period routine selects a fixed event with `SourceFixedEventScheduler`. The
  event's ADV program runs one fixed frame per step. A MapChange without a fade
  loads a catalog map and then acknowledges the request, and Close persists the
  completion flag. Operations that would release an effect the host cannot
  perform (MapMove, the night-menu tail) and presentation requests (text, voice,
  BGM, fades, characters) are rejected by name, never skipped. The whole host is
  one `Codable` snapshot (format `ikkoku.native-gameplay-host`, schema 1). Decoding
  rejects another format, version or catalog and any state no operation can
  produce (G12: native, not original `SaveData`). `IKKOKU_GAMEPLAY_SCENARIO` with
  `IKKOKU_GAMEPLAY_SCENARIO_REPORT` runs a JSON `SourceGameplayHostScenario`
  headlessly before the engine and editors start. Reload steps write the snapshot
  through the checked `CaptureOutput` writer and resume from the bytes read back.
  The report goes through the same writer, and the run exits 0 only when every
  step passed. `CaptureRequest` classifies both variables.
  `Tools/verification/scenarios/gameplay-controlled-event.json` (synthetic catalog,
  one heroine, event 9001: VAR/Calc/IF/Wait/MapChange/Close) selects Morning,
  reloads mid-map-load, requests HR1 during the event, reloads while that ADV
  barrier is held and after completion, and checks that the next day's Morning
  does not rerun the event. Verification: `SourceGameplayHostTests.swift` (8 tests;
  they pass in the CI Engine suite, the only place they were compiled or run)
  checks the exact trace from period selection to completion and both barrier
  holds. It reloads through JSON before
  each of the 25 steps of a four-operation trace, covering every barrier kind, the
  held ADV barrier, the map load and the ADV Wait, and requires an identical
  trace and final host. It also covers period/week/map state changes,
  rejected operations and requests, corrupted, mismatched and inconsistent
  snapshots rejected by name, and the shipped scenario, whose three reloads
  match its reload-free run. A corrupted reload stops the scenario with a named
  error. The app path is compiled by CI only. Acceptance still needs the
  `gameplay-scenarios` lane run on the Mac
  (`python3 Tools/verification/run.py --manifest Tools/verification/lanes/gameplay-scenarios.json`).
  Not covered: original save data (G12), NPC population and navigation (G11),
  MapMove, the night menu, presentation, `Cycle.ADVVariables` (not recovered;
  MapChange acknowledgements carry none), cancellation during a barrier, and an
  interactive gameplay UI.
- **A-T02 — Portable resource installation (P1, partial; first slice 2026-10-23,
  app acceptance pending).** Replace reliance on `#filePath`
  development defaults with a user-selected, versioned conversion library and
  relocation resolver. Accept when a release app launched outside this checkout
  opens a saved scene after relocating its library, or reports each unresolved
  identity without substituting another asset.
  The first slice is engine-first. In the Assets module, a `ResourceLibraryRecord`
  names a library by kind, root, manifest path, manifest SHA-256 and the
  manifest's format version. The kinds are the asset catalog, the Maker library
  and the female and male bases. `ResourceLibraryLocation` (version 1) is the
  persisted selection and the set of libraries in effect.
  `ResourceBinding`, saved in a Studio document as `resourceBinding`, records the
  SHA-256 of each referenced file. When the file lay inside a library, it also
  records that library's realpath root and the file's relative path.
  `ResourceRelocation.resolve` reports each reference as resolved, relocated or
  unresolved, with a named failure. A file resolves only inside the one library
  in effect that has the recorded content, under R5's realpath containment, and
  only when its bytes have the recorded digest. Otherwise it is checked in place
  against the same digest. A changed, missing, escaping or ambiguous file is
  never replaced, and a re-save keeps its saved identity.
  `StudioResourceReferences.swift` maps the document's paths onto it: scene,
  voice catalog, `assetFile`, catalog `itemID` and every source character path.
  In the app, File → Choose/Forget Converted Library writes the selection to user
  defaults, and `EngineHost` reads it before the source-tree fallbacks. Saving
  records the binding. Opening a scene relocates its references and blocks
  objects with unresolved ones from rendering, previews, item captures and voice
  playback. The unresolved references are listed in the status line, under
  Source compatibility details and in `[ikkoku]` lines. Import Scene refuses
  unresolved objects. No new `IKKOKU_*` variable.
  `ResourceRelocationTests` (8 Swift Testing cases) build synthetic libraries in a
  temp directory, save and reload a scene card, and move the library. They check
  that every reference relocates with matching digests and that a re-save
  records the new root. Edited and replaced files must be reported and not used,
  and must keep their saved identity on re-save. Missing files and unselected
  libraries must be reported with their recorded SHA-256 and library. Symlinks
  out of the root, crafted `..` paths and escaping catalog entries must be
  rejected. Further cases cover ambiguous roots, format versions and documents
  saved before A-T02. Neither the Engine nor the app was compiled locally (no
  Swift toolchain in the authoring container). CI is the first compile and the
  only test run. Still open: the moved-library launch in the
  [build guide](../guides/build-and-test.md#use-a-converted-library-outside-the-checkout),
  relocation for documents saved before A-T02 (they lack library roots), the
  source-scene import's environment-variable conversion inputs, native card
  catalog IDs, plugin paths and derived sibling files. See the
  [contract](../reference/native-assets.md#library-location-and-relocation-a-t02).
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
- **A-T05 — Capture result integrity (P2; implemented 2026-10-23, local app
  acceptance pending).** Make UI/thumbnail output failures
  observable and return nonzero on any required missing output. Test a destination
  that cannot be written and readiness timeout; no false “written” message.
  `CaptureOutput`, `CaptureOutputBatch` and `UICaptureReadiness` in the Renderer
  module hold the checked write, the per-item thumbnail accounting and the
  readiness/timeout policy. `CaptureOutputTests` cover a missing parent directory,
  a directory at the destination, missing, empty, garbage and truncated files,
  a pixel-size mismatch, PNG/JSON round trips, batch failures and timeout parsing
  and expiry; CI runs them. Requested autocapture card/scene saves and exports
  now also exit nonzero when they fail or leave an empty file. The verification
  runner fails a 0-byte artifact, and `app-smoke` declares the UI PNG, UI report
  and Mute report as artifacts. Acceptance still needs the app run on the Mac:
  unwritable destination, forced timeout, normal capture and thumbnails, as
  listed in the [build guide](../guides/build-and-test.md#offscreen-and-ui-captures).
  The swallowed autocapture input errors (`IKKOKU_CARD`, `IKKOKU_LOAD_SCENE`) noted
  here are handled by A-T06.
- **A-T06 — Capture request validation (P2; implemented 2026-10-23, local app
  acceptance pending).** Reject invalid capture combinations before any work and
  stop an automated run on a failed input. `CaptureRequest.validate` in the
  Renderer module is pure (an environment dictionary in, a mode or a
  `CaptureRequestError` out). It lives in the engine so Swift Testing covers it in
  CI; it imports only Foundation and holds the variable names, as
  `UICaptureReadiness` already does. Its inventory classifies all 88 variables the
  app reads: 9 mode selectors including `IKKOKU_AUTOCAPTURE`, 45 mode-scoped options,
  the window capture and its 5 options, 12 startup inputs and 16 data sources
  (T-T02 added `IKKOKU_SOURCE_TREE_FALLBACKS`; A-T01 added
  `IKKOKU_GAMEPLAY_SCENARIO` and its report).
  `AppState.init` runs it first and prints the error and exits 1. The
  [build guide](../guides/build-and-test.md#capture-request-validation) lists the
  rules and every newly rejected combination; no documented recipe or lane uses one.
  The adapter report and focus events are capture-only, so they are rejected
  without `IKKOKU_AUTOCAPTURE`. The `app-smoke` Mute check, which had no capture and
  would have stayed open, now writes a Maker PNG and declares it. In an automated
  run (any mode or `IKKOKU_CAPTURE_UI`) a failed startup input exits 1 as
  `IKKOKU_X=value: error` instead of becoming an alert. This covers source scene,
  mod library, rig, bone modifiers, source card, Studio execution, an explicit
  `IKKOKU_SOURCE_AVATAR`/`_MALE_AVATAR` that falls back to the bundled character,
  and an engine that fails to start. Failed capture inputs that were skipped or
  clamped now exit too: `IKKOKU_CARD`, `IKKOKU_LOAD_SCENE` (including its item
  assets), source body/face without a source contract, unknown slider, hair, pose,
  item and Maker tab IDs, an out-of-range outfit, an explicit missing
  `IKKOKU_SHAPE_CONTRACT`, the rig face preset without a face part and missing
  per-family probe inputs. `CaptureRequestTests` (13 tests) keeps 31 documented and
  lane recipes valid and covers each rule; `test_run.py` checks that the inventory matches the
  app's reads, that app-smoke checks select one mode, and that adapter evidence
  runs inside a capture. Neither was compiled locally. Acceptance: run the build
  guide's A-T06 commands and the `app-smoke` lane on the Mac. Not covered:
  `IKKOKU_ASSETS` still falls back silently when its path is missing (A02), and
  an automatically discovered avatar still falls back without an override.

## G. Gameplay cycle, event selection and ADV

Sources: [SourceGameplayCycle.swift](../../Packages/Engine/Sources/Gameplay/SourceGameplayCycle.swift),
[SourceGameplaySession.swift](../../Packages/Engine/Sources/Gameplay/SourceGameplaySession.swift),
[SourceGameplayHost.swift](../../Packages/Engine/Sources/Gameplay/SourceGameplayHost.swift),
[SourceGameplayHostScenario.swift](../../Packages/Engine/Sources/Gameplay/SourceGameplayHostScenario.swift),
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
| G02 · MapMove timing/gates | Fully ported — bounded timer kernel | Cursor/game regulation controls advancement; ADV/talk/interaction flags control visibility separately. Frame increments may overshoot 500; finish forces display fraction 1 without clamping stored timer. | Supply real source flags from the gameplay host; current caller-supplied flags are not gameplay integration. The A-T01 host rejects `beginMapMove`/`finishMapMove` because NPC loading, the tutorial and MapMove camera/cut-in have no native host yet. |
| G03 · Deferred scene/menu/NPC effects | Mid-stage — 9 of 19 effects performed by the A-T01 host | `SourceGameplaySession` classifies all 19 `SourceGameplayDeferredEffect` cases in an exhaustive switch: 11 synchronous, 8 completion barriers, of which `loadNPCs`, `prepareMapMoveCharactersAndCamera` and `startTimeZoneCutIn` are conservative because their source completion is not recovered. It releases effects in source order, requires an ID-and-effect acknowledgement per barrier, rejects unknown, duplicate, out-of-order and mismatched acknowledgements without mutation, and commits the cycle only after the operation's last barrier. Version-1 snapshots reload deterministically mid-barrier and reject other versions and inconsistent state. The session executes none of the effects itself. `SourceGameplayHost` (A-T01) performs the 7 synchronous period/week effects on native state and completes the 2 recorded barriers of period changes from its own state: `prepareNextPeriodSceneBarrier` once no map loads and no event runs, `replacePeriodAfterADVBarrier` once the running ADV event ends. It rejects operations that would release any of the other 10 effects. Verification is the synthetic Engine suite in CI ([session host](../reference/gameplay/cycle.md#session-host-and-effect-inventory-g-t01), [gameplay host](../reference/gameplay/cycle.md#gameplay-host-a-t01)). | Host the remaining effects (NPC loading, tutorial, MapMove camera/cut-in and exit, night-menu tail) from real scene/NPC completion, including cancellation. Replace a conservative barrier only with recovered completion evidence. |
| G04 · Fixed-event table decode and eligibility | Fully ported — inspected selection rules | First unfinished event only; weekday/period/day/lesson conditions, map lookup and wait-point layer match. Failed eligibility does not search later unfinished events. Tested against 4,032 independent contexts for 48 source entries. | Extend catalog coverage independently; selected event still needs G-T02 dispatch. |
| G05 · Fixed-event placement and execution | Infancy — synthetic event runs once in the native host | `Selection` contains asset, map and optional wait-point/layer identity. The A-T01 host checks fixed events on every period entry (native policy: heroines in saved order, first selection runs), runs the selected event's ADV program from a controlled catalog and persists its asset ID as completed, so the scheduler skips it afterwards, including across reload. No NPC entity spawn, movement or encounter dispatch exists, and which source period bodies check events is not translated. | G-T02: bind selection to recovered player/heroine data and a recovered scenario with exact completion flags. |
| G06 · ADV program decoding and batch/wait execution | Mid-stage | Bounded program/argument/variable sizes; `multi` batching, local jump recursion budget, cancelable Wait. Since G-T03b the frame follows `MessageWindowProc`: `UpdateRegulate` gates (pending MapChange, or SceneFade under `isSceneFadeRegulate`) suspend input, Waits and commands; a Text batch waits for Next; `ProcessEnd`/`CurrentCharaData.Clear` run where the source runs them. States: ready/frameBoundary/waiting/awaitingHost/awaitingNext/closed/exhausted/faulted. The whole interpreter is `Codable` and resumes identically mid-wait, mid-acknowledgement and mid-Next (validated on decode). A fault preserves earlier effects; this VM is not a transaction. | The A-T01 host now drives it one fixed frame per step and persists it inside the native host snapshot, accepting only MapChange without a fade. Next: a presentation host for the other requests, skip/auto and choice input, and the original campaign save (G12). |
| G07 · ADV scalar and presentation commands | Mid-stage | Scalar IDs 0/1/3/4/12/14/15/22/23/25 (None, VAR, Calc, Clamp, Tag, IF, Switch, Close, local Jump, Wait): Int32 wrapping and source boxed conversion failures are deliberate; Calc is left-to-right. Presentation IDs 16–19, 35, 37, 44, 45, 88, 106, 112, 125, 128, 169 (Text, Voice, Motion, Expression, NullLoad, NullSet, SceneFade, SceneFadeRegulate, BGMPlay, CharaMotion, CharaExpression, CharaLookEyes, CharaLookNeck, MapChange) decode arguments exactly as the recovered `Do()` (defaults, `ReplaceVars`, Unity Mono `int`/`float`/`bool` parsing, swallowed vs uncaught exceptions) into typed host requests with per-handler blocking (none / acknowledge / Next); unmodelled culture or Unicode forms fault instead of guessing. 22 of these IDs occur in 239,612 of 294,393 installed records; 101 VAR random alternatives and 299 external IF branches still fault. | Expand RNG alternatives, unsupported literals and culture-sensitive comparisons only with source oracles. Add the next request families (Fade, BGLoad/BGRelease, Filter, CharaCoordinate, CharaMotionDefault, CharaVoicePlay/Wait) the same way; rerun `adv_command_coverage.py` after each change. |
| G08 · ADV source data exercised | Infancy | All 10,463 `ScenarioData` assets in the 225 installed `adv/scenario` bundles were run with default inputs and a scripted host (auto-acknowledge, auto-Next): **2,633 run to completion** (2,559 non-empty, 25,892 records; before G-T03b: 87, 13 non-empty), 7,582 halt at the statically predicted index, ID and reason, 248 fault earlier on absent host variables, 0 unexplained. 51,953 host requests were issued and all match an independent Python decoding of the recovered handlers; 9,926 straight-line assets match the predicted request sequence exactly. 27.5% of records now precede a first unsupported command (was 0.46%). Scenario 301 still halts at pc 2 / 165 (`HeroineParam`). Nothing is presented: no host consumes the requests. | G-T02: `HeroineParam`/`ParameterFile` (now the top first blocker, 2,030 assets). G-T03: next families in the measured order ([ADV coverage](../reference/gameplay/adv.md#original-scenario-command-coverage-g-t03)). |
| G09 · Dialogue, choices and UI flow | Infancy | Text (63,122 records) now issues `text` requests carrying the batch's voice/expression/motion bindings and blocks until Next; Voice/Expression/Motion records decode into those bindings. 15,692 Text requests were issued in the corpus run, all matching the independent model. No renderer, name-tag `ReplaceText`, backlog, display-completion click, skip/auto or choice exists; `requestNext` is supplied by tests/CLI. Choice (466 records) is unsupported. | A-T01/G-T01: a host that displays text and plays voices from the requests; G-T03: choices, skip/auto and save/load during dialogue. |
| G10 · Cross-file ADV, tasks, animation/camera/audio actions | Pending | Character look/expression/motion, BGM, map change, ADV null positions and scene fades are typed requests (none executed natively: no host). External `file:tag` jumps and unknown commands fault with command index/reason, checked across the installed corpus. Top first blockers now: ParameterFile 2,030 assets, Fade 1,648, BGLoad 1,235, CharaVoicePlay 589, Filter 452, CharaMotionDefault 386, CharaCoordinate 296, Open 253. Open has 2,869 records; Task/TaskEnd 156/117. | G-T03: further request families in that order, an identity-preserving scenario resolver for Open/external branches, and cancellation barriers; a host must consume the requests. |
| G11 · NPC population, navigation and decisions | Pending | No native NPC behavior-tree runner, source action/navigation tables, map topology, pathfinding or encounter loop is connected. | G-T04: recover one map and one neutral NPC route; implement decisions, movement and save-state continuity against numeric traces. |
| G12 · Original game save/session state | Pending | Character cards and Studio documents are separate formats; neither supplies original player/heroine campaign save state. The G-T01 session snapshot persists only native cycle control state and pending barriers. The A-T01 host snapshot (`ikkoku.native-gameplay-host`, schema 1) adds explicit native placeholders: saved/displayed weekday, clock zone, sunlight, minimap/camera flag, active map, a player next flag, heroine IDs and day counters, completed fixed events and the running ADV interpreter. It is native state only and is not compatible with, or derived from, original saves. | G-T02: recover original load/save adapters and extend the native schema (with a version bump) before treating scalar variables as campaign state. |
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
  original-host evidence. The A-T01 host consumes it and saves the running
  `SourceADVInterpreter` beside it in its own snapshot. Remaining: the session
  itself neither owns nor persists an interpreter, whose request
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

Sources: `Packages/Engine/Sources/Gameplay/Source{TranslatedBehaviour,IRProgram,PluginPackage,PluginLibraryIndex,PluginRuntime,NativePluginPackage,MuteInBackgroundPlugin}.swift`;
`Tools/translation/{translate,plugin,plugin_library,native_adapters,studio_execution_probe}.py`;
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
| P09 · BepInEx metadata/dependencies/process filters | Mid-stage | GUID/name/version, hard/soft dependencies, incompatibilities and process names are retained. Ordinal UTF-8 identity avoids Swift canonical equivalence. P-T02 first slice (synthetic; Swift checked only by CI): `SourcePluginGraph` is one graph for profiles and for library selections of IR and native-adapter packages. Duplicate GUIDs (also across kinds), missing hard dependencies, unmet hard minimums, incompatibilities (also with itself) and cycles (also through soft edges) fail with named errors. Every package version and declared minimum must be a strict 2–4 part numeric .NET version, even when nothing compares it. Edge tests cover `.exe`/case process filters, ordinal case/Unicode dependency GUIDs, unenforced soft minimums and 1.0 < 1.0.0. Duplicate GUIDs need an explicit manifest choice. Process matching uses a Foundation case-insensitive approximation. | Recover the installed Chainloader's duplicate-GUID preference and full `System.Version` parsing (whitespace/sign) from private evidence; the native policy rejects those cases. Record adapter dependency metadata when a registered plugin declares any. |
| P10 · Immutable packaging and static DLL recovery | Mid-stage | `.cs` or bounded `.dll` input; DLLs are statically decompiled, not loaded. New generations preserve source/program hashes. Rejected conversion has diagnostics but no loadable manifest. Exact two-DLL registry selects verified Swift adapters. P-T02 first slice: `plugin_library.py` copies published IR and adapter packages into `revisions/<manifestSHA256>/` and publishes numbered generations (stage + rename, hard-linked index, one atomic `library.json` commit). Revisions record GUID, version, kind, manifest/package SHA-256, converter hashes and sources. Changed source yields a new generation; unchanged rescans publish none; revisions and generations are never rewritten; identical interrupted output is adopted. `plugin.py` rejections are triaged with their diagnostics. 15 synthetic Python tests pass locally. | Batch DLL discovery that recovers each entry type, assembly dependencies, multiple types per package and an installed-directory compatibility report; converter migrations bound to saved selections. No installed plugin directory has been scanned. |
| P11 · IR plugin execution in Studio | Mid-stage | Explicit profile binds original source keys or native UUIDs. Local/world transforms, attachment frames, subtree clones and identity preservation work. Native save/reload persists clocks/fields without replaying Start. | App controls for bindings/unload and source-object topology changes; no implicit source BepInEx manager exists. |
| P12 · Original MuteInBackground 1.1 behavior | Fully ported — bounded initial config/focus callback | Exact installed GUID/hash registry; original config parsing oracle covers 23 cases and seven focus traces, including the repeat-focus-loss quirk. Audio bus mixer endpoint tested with a generated tone. A-T04 Release startup, persistence and focus/gain acceptance passed in PR #2. | Live config-file watching and multiple static copies are unsupported. |
| P13 · Original StudioAccessoryNames 1.1.0 behavior | Fully ported — bounded label pass | Recovered coroutine result matches three source-host cases, including UTF-16 digit detection and missing slots. Mount enables the native label model; source identities are unchanged. | Actual inspector integration is blocked by the source-character UI gate; Studio audit records that defect. General Unity UI/coroutine execution is not provided. |
| P14 · Native adapter package/persistence validation | Mid-stage | Exact assembly/type/GUID/version/process/config hashes required. Saved scene references reject changed packages. Three native package tests and one Python packaging test pass with original fixtures. The execution probe now compares mounted references with each phase's adapter report. P-T02: the library accepts an adapter revision only for a registered assembly digest with identical metadata; library selections reverify it through `SourceNativePluginPackage` (stand-in bytes fail by name, synthetic). | P-T03/A-T04: actual-app mount/save/reload passed in PR #2; wider plugin integration remains pending. The earlier `native-adapter-capture-01` startup trap is historical and superseded by the accepted run. P-T02: the app does not yet restore adapters from a library selection. |
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
  First slice done 2026-10-23 with synthetic fixtures. Swift was not compiled
  locally; the CI Engine suite is its verification. The format and policy are in
  [plugin library](../reference/mods/plugin-execution.md#plugin-library).
  `Tools/translation/plugin_library.py` is the scanner. `SourcePluginLibraryIndex`,
  `SourcePluginLibrarySelection` and `SourcePluginGraph` are the Gameplay reader,
  selection and shared graph. `StudioDocument.sourcePluginLibrary` is a new
  optional field; older documents decode it as nil and keep their profile and
  adapter formats. `test_plugin_library.py` (15 tests) and
  `SourcePluginLibraryTests.swift` cover generations, immutability, interrupted
  publication, conflicts, versions, adapter registry checks and saved-selection
  resolution after a newer generation. Remaining: app wiring
  (select/restore/upgrade UI, adapter mounts from a selection), batch DLL triage,
  multi-type packages, assembly dependencies, converter migrations, and the
  installed Chainloader's duplicate and version rules from private evidence.
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
  `SourceGameplaySessionTests.swift`, `SourceGameplayHostTests.swift`,
  `SourceGameplayExecutionTests.swift`, `test_gameplay_contract.py`,
  `test_gameplay_execution_contract.py`, `test_adv_command_coverage.py`. Their references are independent
  calculations/recovered-source fixtures, **not a complete running game**.
- Plugin tests: `SourcePluginRuntimeTests.swift`,
  `SourceNativePluginPackageTests.swift`, `SourceMuteInBackgroundTests.swift`,
  `SourcePluginLibraryTests.swift`,
  `Tools/translation/tests/test_translation.py`, `test_native_adapters.py`,
  `test_plugin_library.py` and
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
