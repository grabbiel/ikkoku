# Source gameplay control-state recovery

Reviewed 2026-09-25 against the working tree. The [Gameplay audit](../../component-audit/app-gameplay-and-plugins.md#g-gameplay-cycle-event-selection-and-adv) tracks completion and follow-up tasks. This is an engine/CLI contract; the app still has no gameplay session host.

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
boundary; a future gameplay host must perform asynchronous waits and cancellation
before committing them. Returned effects do not constitute an asynchronous
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

The next implementation is the session/deferred-effect host (`G-T01`), not another
period enum. Inventory each effect, classify immediate work versus completion
barriers, persist pending state and require acknowledgements before advancing.
Then bind fixed events and scenario 301 to real source player/heroine data
(`G-T02`), expand ADV presentation/task families (`G-T03`) and build a measured
neutral NPC navigation slice (`G-T04`). The audit supplies acceptance criteria.
