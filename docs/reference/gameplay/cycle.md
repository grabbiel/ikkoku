# Source gameplay control-state recovery

Reviewed 2026-10-23 against the working tree (G-T01 session host, A-T01 gameplay host first slice, G-T02 character bindings and host schema 2). The [Gameplay audit](../../component-audit/app-gameplay-and-plugins.md#g-gameplay-cycle-event-selection-and-adv) tracks completion and follow-up tasks. This is an engine/CLI contract. The [native gameplay host](#gameplay-host-a-t01) drives the [session](#session-host-and-effect-inventory-g-t01) and one fixed event, and the app runs it only as a headless scenario (`IKKOKU_GAMEPLAY_SCENARIO`). There is no interactive gameplay mode.

The native `Gameplay` module translates the day/period and action-clock control
state recovered from this installation's `ActionGame.Cycle`. It is an executable
state model, not a playable port of the original action scene. NPC navigation,
menus, scene loading and campaign-save serialization remain pending. Separate
[fixed-event and scalar ADV kernels](adv.md) now execute in tests/CLI traces, but
are not connected to an app gameplay host.

## Evidence

Targeted decompilation output is kept under the ignored directory
`.local/reverse/decompiled/Gameplay/`. The input is the local
`Koikatu_Data/Managed/Assembly-CSharp.dll`. The generated
`.local/reverse/gameplay/contract.json` records input/output SHA-256 hashes, source
file sizes, structural checks, and an independent Python fixture corpus. No
original game source, executable, scenario script, dialogue, or asset is included
in the tracked implementation or fixtures.

The targeted recovery includes:

- `ActionGame.Cycle` and `CycleExtensions`: period order, weekday order, direct
  changes, next-period behavior, timer loop, menus, and period coroutine dispatch.
- `SaveData`: default weekday/opening flag, character daily counters, and game
  save/load entry points.
- `Manager.Game`: regulation gates, new-game/reset behavior, save/load delegation,
  and parameter correction.
- `ActionScene`, `ActionGame.ActionControl`, `ActionGame.FixEventScheduler`,
  `ActionGame.Chara.NPC`, `ActionGame.Chara.AI`, `Manager.PlayerAction`, and
  `ADV.Program`: source dependency and side-effect boundaries.

The initial ILSpy 11.1 targeted outputs contain four method decompilation failures
in `ActionScene` and two in `ADV.Program`. Those outputs are retained as evidence
of that attempt; these failures do not occur in the translated cycle methods.
The broader managed-assembly recovery uses a compatibility decompiler fallback
and separately records the selected successful output and unresolved errors.
An error in an older attempt must not be interpreted as permanently lost logic.

## Translated behavior

`SourceGameplayPeriod` preserves the original integer sequence:

| ID | Source period | Clock zone | Action period |
|---:|---|---:|---|
| 0 | WakeUp | 0 | No |
| 1 | Morning | 0 | No |
| 2 | GotoSchool | 0 | No |
| 3 | HR1 | 0 | No |
| 4 | Lesson1 | 0 | No |
| 5 | LunchTime | 1 | Yes |
| 6 | Lesson2 | 1 | No |
| 7 | HR2 | 1 | No |
| 8 | StaffTime | 2 | Yes |
| 9 | AfterSchool | 3 | Yes |
| 10 | GotoMyHouse | 3 | No |
| 11 | MyHouse | 4 | No |

Weekdays are Monday=0 through Saturday=5 and Holiday=6. New source `SaveData`
starts at Holiday with `isOpening=true`. Cycle initialization therefore chooses
WakeUp; loading a non-opening save initializes MyHouse.

The distinction between two period changes is significant:

- An explicit backward `Change(Type)` advances the weekday once. Forward and
  equal changes do not.
- `_Next` advances modulo twelve and suppresses that backward-change rule.
  Consequently MyHouse → WakeUp through `Next` alone does **not** change the day.
- The MyHouse coroutine explicitly invokes `NextWeek` after closing the night
  menu and resetting the player's action count to five, then calls `Next`.
- Loading a save from the night menu assigns the saved weekday directly. It
  does not run the daily character effects of `Change(Week)`.

`Change(Week)` walks forward to the requested weekday. An equal weekday means
seven elapsed days. `NextWeek(0)`, `NextWeek(7)`, and `NextWeek(14)` therefore all
produce seven daily updates, not zero, seven, and fourteen. The native code
preserves unchecked Int32 addition and signed remainder. A resulting negative
weekday is rejected: the source's enum arithmetic could otherwise enter a
nonterminating search for an invalid weekday.

The deferred `advanceCharacterDays(n)` effect has a precise source obligation:
call the daily counter increment `n` times for every saved heroine; additionally
call `EventAfterDayAdd(n)` when `fixCharaID <= -5`. These mutations are reported,
not applied to a fabricated native character-save model.

The action timer uses single-precision floats, a 500-second limit, and an event
limit constant of 499. `ActionEnd` sets 500. `AddTimer(fraction)` adds
`500 * fraction` and clamps to [0, 500]. Neither method refreshes the clock UI by
itself. MapMove resets the timer/display, loads NPCs, handles the one-time opening
tutorial, and then enters the timed loop.

In that loop, time advances only while the cursor is locked and
`Game.IsRegulate(true)` is false. The latter checks the scene's loading fade,
presence of an additive scene, and map loading. Clock visibility separately
depends on ADV, Talk, and interaction-scene activity. The source frame increment
can overshoot 500; completion forces the displayed fraction to one without
clamping the stored timer. The native model preserves this distinction.

LunchTime, StaffTime, and AfterSchool are marked action periods even on Holiday,
but their Holiday coroutines skip MapMove. `beginMapMove` consequently rejects
Holiday while `isAction` remains true. Source NPC shuffling happens on the first
MapMove entry and is reset at the end of MyHouse.

## Native boundary

`Packages/Engine/Sources/Gameplay/SourceGameplayCycle.swift` contains the public
state model. Mutations return typed `SourceGameplayDeferredEffect` records.
These identify work the host still owes to source systems: scene/fade barriers,
ADV completion, period coroutine replacement, map sunlight, NPC loading,
tutorials, camera/character setup, parameter correction, and saved-character
daily changes.

The API is a control-state projection. `nextPeriod`, `completeNightMenu`,
`beginMapMove`, and `finishMapMove` commit at the corresponding source completion
boundary; a gameplay host must perform asynchronous waits and cancellation
before committing them. `SourceGameplaySession` (next section) enforces that
order for a host, but returned effects still do not constitute an asynchronous
coroutine implementation. Map sunlight updates also require a valid current map;
the native scalar model does not claim to have loaded one.

Native guards reject invalid phases and nonfinite clock values. Negative frame
deltas are rejected because the source uses Unity's nonnegative frame duration.
These are explicit native safety constraints, not purported behavior of arbitrary
invalid original inputs. General period/name localization, campaign script integration and the
event-dependent period coroutine branches remain untranslated. Separate table
conversion now decodes selected class schedules/fixed events, and the bounded
ADV interpreter handles selected scalar commands; this cycle model does not
invoke those kernels or complete their host work.

The model initially hides its inactive clock and sets its display fraction to
zero. Those are native host defaults, not recovered serialized Canvas/TimeUI
prefab values. Source-equivalent display updates are established by MapMove
entry/ticks/completion; WakeUp and MyHouse UI visibility still belongs to their
untranslated period coroutine bodies.

## Session host and effect inventory (G-T01)

`Packages/Engine/Sources/Gameplay/SourceGameplaySession.swift` wraps the cycle
so that a platform-neutral host can drive it. It executes no scene, NPC, ADV,
menu or save work itself; it orders what the host owes and refuses to commit
early. The [gameplay host](#gameplay-host-a-t01) (A-T01) consumes it.

- `perform(_:)` takes one effect-producing operation (`SourceGameplayCycleOperation`
  mirrors the cycle methods) and stages it on a copy of the committed cycle. A
  rejected source operation throws its `SourceGameplayCycleError` and stages
  nothing.
- The returned effects are released strictly in source order. Synchronous work
  is appended to `synchronousWork`, which the host drains with
  `takeSynchronousWork()` and performs immediately. Release stops at the first
  completion barrier, which becomes `outstandingBarrier` with a session-unique,
  increasing ID. Later effects of the same operation stay unreleased until it is
  acknowledged.
- `acknowledge(_:)` accepts only the outstanding barrier's ID together with its
  exact effect (`barrier.acknowledgement`). An unissued ID, an already
  acknowledged ID, a later barrier of the same operation, a mismatched effect or
  untaken synchronous work released before the barrier is rejected with a
  `SourceGameplaySessionError` and leaves the whole session unchanged.
- `cycle` is replaced by the staged target only after the operation's last
  barrier. No period or weekday advance is committed while one of its
  dependencies is outstanding, and every other cycle operation, including
  `actionEnd`, `addTimer` and `tickMapMove`, is rejected meanwhile. The host can
  read the staged target (`transition.target`) for presentation, for example the
  forced display fraction during the MapMove exit barrier.
- The whole session is `Codable` with `schemaVersion` 1; other versions are
  rejected. Decoding replays the in-flight operation on the committed cycle and
  rejects a snapshot whose effects, target, barrier IDs, release position or
  queued work disagree with that replay. Cycle decoding rejects nonfinite or
  negative clock values and an active MapMove outside an action period.

Effect timing is an exhaustive `switch` (`SourceGameplayDeferredEffect.timing`):
a new effect does not compile until it is classified. A step is synchronous only
when the recovered contract places it inline with no wait. Only the four
operations listed in [Native boundary](#native-boundary) commit at a coroutine
completion boundary; the recovered `Change(Week)` and `Change(Type)` bodies are
translated as plain calls, so their effects are inline unless named as a wait.
Where completion of a source step has not been recovered, the effect is
conservatively a barrier: an unneeded acknowledgement costs the host one round
trip, while a missing wait would release later work before the source would.

| Effect | Emitted by | Timing | Source basis |
| --- | --- | --- | --- |
| `persistWeek(week)` | `changeWeek` (also via backward `changePeriod`, `nextWeek`, `completeNightMenu`) | Synchronous | Inline in direct `Change(Week)`, which saves the weekday (the night-menu load path does not). |
| `updateWeekDisplay(week)` | `changeWeek` paths; `reloadNightMenuWeek` | Synchronous | Inline in `Change(Week)` and in the NightMenu load callback. |
| `advanceCharacterDays(n)` | `changeWeek` paths | Synchronous | Inline in `Change(Week)`: the per-heroine daily increment `n` times, plus `EventAfterDayAdd(n)` when `fixCharaID <= -5`. |
| `updateTimeZone(zone)` | `changePeriod`, `nextPeriod`, `completeNightMenu` | Synchronous | Inline in direct `Change(Type)`. |
| `updateMapSunlight(period)` | same | Synchronous | Inline in `Change(Type)`; the host must have a loaded current map. |
| `replacePeriodAfterADVBarrier(period)` | same | Barrier (recorded) | `Change(Type)` replaces the running period coroutine only after ADV processing ends. Whether the source runs the following minimap/camera switch before that wait ends is not recorded; the session conservatively holds it. |
| `setMiniMapAndCameraActive(isAction)` | same | Synchronous | Inline in `Change(Type)`. |
| `prepareNextPeriodSceneBarrier` | `nextPeriod`, `completeNightMenu` | Barrier (recorded) | `_Next` waits for additive scenes, map loading and fade before its `Change(Type)`. |
| `clearPlayerNextFlag` | same | Synchronous | Follows `Change(Type)` in `_Next`; no further wait is recorded. |
| `loadNPCs(shuffle:)` | `beginMapMove` | Barrier (conservative) | NPC loading precedes the timed loop; its completion rule is not recovered. |
| `openingTutorial` | `beginMapMove` while `isOpening` | Barrier (recorded) | The first MapMove iteration runs after the tutorial wait. |
| `prepareMapMoveCharactersAndCamera` | `beginMapMove` | Barrier (conservative) | Completion rule not recovered. |
| `startTimeZoneCutIn(period)` | `beginMapMove` | Barrier (conservative) | Completion rule not recovered. The first iteration also follows a fade wait that no effect is recorded as; barriers on every entry effect keep ticks from starting early. |
| `finishMapMoveAndWaitForSceneBarrier` | `finishMapMove` | Barrier (recorded) | The loop exit waits for its scene barrier. |
| `correctGameParameters` | `completeNightMenu` | Synchronous | MyHouse tail; its only recorded waits are the night menu (before the request) and player initialization. |
| `clearCachedCompanions` | `completeNightMenu` | Synchronous | Same MyHouse tail. |
| `ensurePlayerCreatedAndInitialized` | `completeNightMenu` | Barrier (recorded) | The player-initialization wait. |
| `resetPlayerActionCount(5)` | `completeNightMenu` | Synchronous | Same MyHouse tail, before `NextWeek`. |
| `clearSaturdayTeachers` | `completeNightMenu` | Synchronous | Same MyHouse tail, before `Next`. |

That is 11 synchronous effects and 8 barriers, 3 of them conservative. A
`nextPeriod` therefore needs two acknowledgements (scene, then ADV), a
`completeNightMenu` three (player initialization, scene, ADV), a `changePeriod`
one, a `beginMapMove` four while `isOpening` (tutorial) and three otherwise, and
a `finishMapMove` one; `changeWeek`, `nextWeek` and `reloadNightMenuWeek` commit
immediately.

Native policies, not recovered behavior: the source assigns the new weekday and
period partway through these sequences (`NextWeek` before `_Next`'s waits, the
period before the ADV-gated coroutine replacement), while the session commits
them only after the last barrier. Timer operations during an outstanding barrier
are rejected because which side of the pending source wait they would apply to
is not modelled. Cancellation (returning to title or ending the game during a
barrier), executing the NPC/scene work and supplying real regulation flags
remain host work; the A-T01 host performs only the period/week effects. This snapshot is native session state, not
original campaign `SaveData` (G12).

ADV commands have a separate acknowledgement layer: a running
`SourceADVInterpreter` issues its own host requests and accepts acknowledgements
by request ID ([ADV](adv.md)). Those are not session barriers. The session neither
owns nor persists an interpreter. The A-T01 host saves both in one snapshot and
acknowledges `replacePeriodAfterADVBarrier` only after its ADV run has ended.

## Gameplay dependency map

| System | Recovered owner and data | Required native work |
|---|---|---|
| Session orchestration | `ActionScene.Start`, `_SceneEvent*`, `NPCLoadAll`, `NextCycle`; `Manager.Game` | Scene services, lifecycle/cancellation, UI transitions, player/NPC creation, input and regulation gates. |
| NPC decisions | `ActionGame.ActionControl` desire and priority tables, personality corrections, action/map/club lists | Convert source data tables and implement deterministic selection with injectable randomness; retain source IDs. |
| NPC movement | `ActionGame.Chara.AI`, `NPC`, NodeCanvas behavior-tree access, Unity NavMesh agents | Recover serialized behavior trees, navigation topology, arrival/wait logic, sensing, animation-state handoffs. |
| Scheduled events | `FixEventScheduler`, `FixEventSchedule`, class schedules | Selection rules and selected table conversion are implemented; bind the resulting identity/map/wait-point to an NPC/scenario and persist completion. |
| Player actions | `Manager.PlayerAction`, action-point tables and transform backups | Port source action eligibility, action counts, point selection, scene transitions, and cancellation/restoration. |
| ADV execution | `ADV.Program.Transfer`, `TextScenario`, `MainScenario`, command handlers and scenario assets | A bounded scalar VM supports typed variables, arithmetic, local branches, batching and waits. Implement player/heroine bindings, dialogue/choices, external-file/tasks and presentation consumers with save/cancellation semantics. |
| Persistence | `SaveData` (version 1.0.1), `Manager.Game.Save/Load`, `ActionControl.Save/Load` | Decode full saves, preserve extension/unknown data, translate mutable player/character state, and validate round trips. |
| Animation | NPC/AI motion requests and character animation controllers | Generic clips and flat 1D states execute in Maker/Studio. Bind gameplay state requests and navigation/root-motion timing; current visual playback is not an NPC controller. |
| Mod integration | Runtime patches and extended save hooks around the above | Define supported extension points and adapters from recovered behavior; arbitrary Harmony/BepInEx plug-ins do not run natively. |

Source period bodies are recovered for analysis, but the model does not silently
skip their content to pretend a whole day is playable. For example, WakeUp may
redirect the cycle based on event results; GotoSchool selects eligible encounters;
lesson and homeroom periods test scheduled events; active periods load maps and
NPCs; GotoMyHouse preserves/restores its period around event execution; MyHouse
opens the night menu and coordinates save loading and player initialization.
These remain source coroutine translations to implement behind the deferred
interfaces.

## Verification

The Python oracle deliberately does not call the native implementation. Its
weekday calculation uses forward traversal while Swift uses modular arithmetic;
its signed Int32 wrapping and float32 operations are explicit. Generated coverage
contains **264 cases / 454 steps**, including all 144 period pairs, all 49 weekday
pairs, same-day/full-week advances, integer overflow/remainder boundaries, night
menu day rollover, load synchronization, timer regulation, visibility, overshoot,
and native rejection cases.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/gameplay_contract.py \
  --source-root .local/reverse/decompiled/Gameplay \
  --assembly .local/reverse/source/Koikatu_Data/Managed/Assembly-CSharp.dll \
  --output .local/reverse/gameplay/contract.json
.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse -p test_gameplay_contract.py
IKKOKU_GAMEPLAY_REFERENCE="$PWD/.local/reverse/gameplay/contract.json" \
  swift test --package-path Packages/Engine --filter sourceGameplay
Packages/Engine/.build/debug/ikkoku-inspect gameplay-trace \
  .local/reverse/gameplay/contract.json
```

The trace CLI accepts the same `cases` / `initial` / `steps[].command` shape as
the oracle file and ignores expected states. Its JSON report contains computed
states, deferred effects, elapsed-character-day counts, and native guard errors.
It limits inputs to a 16 MiB regular file, 10,000 scenarios, and 100,000 actions;
unknown operations, invalid enum values, and malformed command arguments fail
the request. Domain errors in otherwise valid commands are recorded per step so
the following commands can still be inspected.

Integer command arguments are decoded separately through Foundation `Decimal`,
checked against Int32 bounds, and compared exactly with the candidate integer.
This rejects fractions such as `1.00000000000000001` that binary64 decoding would
round to a whole number. Foundation Decimal supports up to 38 significant decimal
digits; longer number literals may already have been rounded by that decoder.
The CLI does not promise lexical arbitrary-precision JSON-number validation.
Timer-fraction arguments still use binary64-to-float32 conversion, matching their
native floating-point domain.

The retained focused evidence run contains eight native tests, nine Python oracle
tests and five optional CLI regression tests; this is not a current suite-total claim. Set `IKKOKU_INSPECTOR` to the absolute path of the
built `ikkoku-inspect` executable to run the latter, including fractional-number
rounding, Int32 bounds, initial-week/period validation, and timer-fraction checks.
Native oracle comparison checks every generated state field and daily-effect count,
including error outcomes. This evidence verifies the translated control logic;
it does not establish end-to-end game, NPC, ADV, save, or mod compatibility.

`SourceGameplaySessionTests.swift` covers the session host with synthetic
traces only; it needs no fixture and runs in the public CI lane (Engine
`swift test`). It pins the timing inventory above, the release order and
commit point of `nextPeriod`, `completeNightMenu`, `changePeriod` and both
MapMove gates, and each rejected acknowledgement and blocked operation with a
full before/after session comparison. A Friday-to-Wednesday host trace (37
operations including rejected ones, 52 barriers covering scene, ADV, NPC,
tutorial and player-initialization waits) is rerun with a JSON reload at each
of the 52 barriers; every rerun must reproduce the uninterrupted observation
log and final session exactly. Tampered snapshots (unknown version, moved
position, wrong IDs, queued barrier, altered target or operation, invalid clock
or MapMove flag) must be rejected. These tests check the native ordering
contract; there is no recorded original host trace to compare against, and the
conservative barriers above remain unverified against the source.

The engine slice of the session host (`G-T01`) is above, and the first slice
of the gameplay host (`A-T01`) [below](#gameplay-host-a-t01). Next, host the
remaining effects (NPC loading, tutorial, MapMove, night menu) from real scene
and NPC completion, including cancellation. Then bind fixed events and
scenario 301 to real source player/heroine data (`G-T02`), expand ADV
presentation/task families (`G-T03`) and build a measured neutral NPC navigation
slice (`G-T04`). The audit supplies acceptance criteria.

## Gameplay host (A-T01)

`Packages/Engine/Sources/Gameplay/SourceGameplayHost.swift` is the native host
that the session section above anticipates. It owns:

- one `SourceGameplaySession`;
- `SourceGameplayNativeState`, a versioned native save state. It holds the saved
  and shown weekday, the clock zone, the last sunlight map and period, the
  minimap/camera flag, the active map number, the player (a next flag and,
  since G-T02, optional `SourcePlayerParameters`), the heroines (`id`,
  `classIndex`, a count of applied daily increments and, since G-T02,
  `SourceHeroineParameters`, the typed `SaveData.Heroine` members the ADV
  bindings read and write; the scheduler reads `fixCharaID`, `isTaked` and
  `eventAfterDay` from it) and the completed fixed-event asset IDs;
- at most one running fixed event (heroine, scheduler selection and its
  `SourceADVInterpreter`) and at most one map load;
- an immutable `SourceGameplayEventCatalog` (fixed-event table, ADV program per
  event asset, map names and numbers, wait points and, optionally, the
  `ParameterFile` library and the character tables the bindings read; see
  [character bindings](adv.md#character-bindings-g-t02)). Every scheduled asset
  must have exactly one program.

None of the state is loaded from or written to original campaign data (G12).
The heroine and player parameters have the source members' names, types and
new-game values, but they start from the scenario's values, not from a save.
The other fields are native placeholders that change only when the host
performs the matching effect, and the original counters behind
`advanceCharacterDays` are not modelled.

**Commands and steps.** A caller stages one cycle operation with `perform(_:)`
and advances the host with `step()`, one unit of host work at a time; `run()`
steps until idle or a stop condition holds. The caller cannot acknowledge
anything, because `session` is read-only outside the host. `perform` is accepted
only when no released work, staged operation or period entry is pending. A
running event may continue meanwhile, which is how a period change requested
during an event reaches its ADV barrier. Each step does the first applicable item:

1. Take the released synchronous work and apply it to the native state in source
   order. Report the staged operation's commit in the same step once its last
   barrier and work are done.
2. Report a commit that has no work left.
3. Complete the outstanding barrier when the host has finished what it waits
   for, then acknowledge it:
   - `prepareNextPeriodSceneBarrier` once no map is loading and no event runs. The
     host presents no fades and treats a running ADV event as an additive scene;
     whether the source does is not recovered, and waiting is the conservative
     choice.
   - `replacePeriodAfterADVBarrier` once no ADV event runs. This replaces the
     period routine, so the new period's fixed-event check is due.
4. Advance the running event. That is also what a blocked barrier waits for:
   - drain its requests. A MapChange without a fade starts a load to a catalog
     map. Any other request, a fade or an unknown map throws `unsupportedRequest`
     or `unknownMap`;
   - finish a started load: set the active map, then acknowledge the request with
     no ADV variables, because `Cycle.ADVVariables` is not recovered;
   - complete the event on Close or exhaustion, appending its asset ID to
     `completedEvents` and setting the heroine's `eventAfterDay` to 0 (the
     source's `Cycle.FixCharaEventStart` does this after the ADV);
   - otherwise tick the interpreter one `frameDelta` frame without Next. With
     character tables in the catalog, the interpreter's heroine and player are
     then written back to the saved state, because the source binds the saved
     `SaveData.Heroine` itself.
5. Run the period routine's fixed-event check. Native policy: every period
   checks, heroines in saved order, and the first `SourceFixedEventScheduler`
   selection starts its program. Which source period bodies check events is not
   translated (see the dependency map above). Completed events, and assets in
   the heroine's `talkEvent` (which `FixEventScheduler.Check` also skips), are
   skipped, so an event runs once. With character tables the new interpreter is
   bound to the heroine, the player and the catalog's library, and its
   `SetADVParam(scenario)` seed (whose getters can clamp `lewdness` or cache
   `voiceNo`) is written back at once.

A barrier that waits while no event runs throws `barrierBlocked`. Every throwing
command or step leaves the host unchanged, so a failed step is repeated
identically.

**Supported effects.** `SourceGameplayHost.supports` is an exhaustive switch.
The host performs `persistWeek`, `updateWeekDisplay`, `advanceCharacterDays`
(the daily increment per heroine, plus `eventAfterDay` when
`fixCharaID <= -5`), `updateTimeZone`, `updateMapSunlight` (on the active map),
`setMiniMapAndCameraActive`, `clearPlayerNextFlag` and the two barriers above.
Those are 9 of the 19 effects, enough for `changePeriod`, `nextPeriod`,
`changeWeek`, `nextWeek` and `reloadNightMenuWeek`. `perform` replays the
operation on a copy of the cycle and rejects it with
`unsupportedOperation(operation, effect)` when it would release any of the other
10. These are NPC loading, the tutorial, MapMove camera/cut-in and exit, game
parameters, companions, player creation, the action count and the Saturday
teachers, so `beginMapMove`, `finishMapMove` and `completeNightMenu` are rejected.

**Persistence.** The whole host is `Codable`: format marker
`ikkoku.native-gameplay-host`, `schemaVersion` 2 (G-T02), canonical sorted-key
JSON from `snapshot()`, at most 16 MiB. Schema 2 stores each heroine's
`parameters` and the player's `parameters`, the catalog's optional
`parameterLibrary` and `characterTables`, and a bound interpreter's
`character`, `insertions`, `replaces` and `parameterLibrary`.
`SourceGameplayHost.resume(_:catalog:)` reads schemas 1 and 2. A schema-1
snapshot migrates on decode: each placeholder heroine becomes the new-game
`SourceHeroineParameters` with its `fixCharaID`, `isTaked` and `eventAfterDay`
copied, and the next `snapshot()` writes schema 2. `resume` rejects data by name:

- `unrecognizedSnapshot` for a missing or other format, including a bare session
  snapshot;
- `unsupportedSchemaVersion` (other than 1 or 2) and `snapshotTooLarge`;
- `inconsistentState` for a schema-1 snapshot that carries schema-2 data
  (player parameters, catalog tables or library, a bound interpreter), a
  schema-2 snapshot with placeholder heroines, or a heroine with both shapes;
- `catalogMismatch` when the snapshot carries other content than the caller's
  catalog;
- `invalidCatalog`;
- `inconsistentState` for a state no operation can produce. Examples are an
  active, sunlight or load map outside the catalog, duplicate heroines or
  completed events, a running event that is not its heroine's catalog entry or
  whose program differs from the catalog, an already completed or faulted running
  event, a pending MapChange that is neither queued nor loading, a period entry
  during an event, a staged operation that differs from the session's in-flight
  one, a released effect the host does not support, or a frame duration that is
  not positive.

The nested session and interpreter reject their own corruption with their own
errors.

**Headless app mode.** `SourceGameplayHostScenario` runs a JSON scenario: a
catalog, a start (weekday, opening flag, map, heroines, frame duration) and
steps.

- `perform` stages a named operation.
- `run` steps until `idle`, `eventRunning`, `mapLoading` or `barrier` holds.
- `reload` snapshots the host, stores the bytes and resumes from what the store
  returns. The result must equal the persisted host and re-encode to the same
  bytes.
- `assert` checks period, weekday, saved weekday, active map, completed events,
  running event or idle and, since G-T02, a saved heroine's parameters by
  original key (read through the key's getter on a copy, as
  `"System.Int32:4"`), the running event's ADV variables and its ParameterFile
  insertion count. `run` also stops at `parameterInserted`.

The report lists each step, every reload, the full trace and the final state. The
app runs it behind `IKKOKU_GAMEPLAY_SCENARIO` with the required
`IKKOKU_GAMEPLAY_SCENARIO_REPORT`, before the engine and editors start. A reload
with a `path` writes the snapshot through `CaptureOutput.writeJSON` and reads it
back from disk; the report goes through the same checked writer. The process
exits 0 only when every step passed.

**Verification.** `SourceGameplayHostTests.swift` (9 tests) runs in the Engine
suite (locally and in the public CI lane) over the synthetic catalog in
`Tools/verification/scenarios/gameplay-controlled-event.json`. Event 9001 runs
VAR, Calc, IF to a local tag, a 0.5 s Wait and MapChange to a second map. Since
G-T02 it continues with a ParameterFile that inserts a synthetic Calc → Clamp →
HeroineParam program, a ParameterFile naming a missing asset, a HeroineParam
`H_callID` (CallNameChange), a VAR and Close. The heroine is bound to synthetic
character tables. The tests check:

- the exact trace from WakeUp → Morning period selection to completion (21
  entries, two barriers);
- that a Change(Type) requested during the map load keeps Morning committed and
  its ADV barrier outstanding until the event completes, and that a `_Next`
  during the event applies its sunlight only after the map load;
- a JSON reload before each of the 30 steps of a four-operation trace (period
  selection, a mid-event HR1 change, a backward day change, `_Next`), covering
  both barrier kinds, the held ADV barrier, the map load and the ADV Wait, each
  reproducing the uninterrupted trace and final host exactly;
- weekday, heroine counter, clock-zone, sunlight and minimap changes, and the
  rejected MapMove and night-menu operations and busy commands without mutation;
- text, unknown-map, faded MapChange and unported-command failures without
  mutation;
- each named snapshot rejection above;
- the shipped scenario, whose four reloads (steps 5, 8, 12 and 15: mid map
  load, mid barrier, right after the insertion, after completion) leave its
  trace and final state identical to a reload-free run, and whose corrupted
  reload stops it with a named error;
- a schema-1 snapshot taken mid map load, migrated to the new-game heroine with
  its three fields copied, equal to the schema-2 host and running on
  identically; mixed or mislabelled shapes are rejected.

The `gameplay-scenarios` verification lane runs that scenario through the built
Debug app. On 2026-10-23 (G-T02 branch, strict, under the app lock) it
**passed**: 20 of 20 steps, four snapshots of 10,427, 10,907, 10,824 and 3,954
bytes, final state Tuesday Morning, map 2, `completedEvents` `[9001]`. The
event ran once: Tuesday's Morning selected nothing. Its resumed heroine had
`H_intimacy` 4, `H_callID` 3 with the special call name, `H_eventAfterDay` 0,
then 1 after the day change. A copy of the scenario expecting `H_intimacy` 5
failed that one step (19 passed, 1 failed, exit 1). No original data or host
trace is compared: this verifies the native ordering and persistence contract,
not source parity.
