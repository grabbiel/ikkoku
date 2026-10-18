# Fixed-event selection and bounded ADV execution

Reviewed 2026-10-17 against the working tree (G-T03 coverage slice). The [Gameplay audit](../../component-audit/app-gameplay-and-plugins.md#g-gameplay-cycle-event-selection-and-adv) tracks completion and follow-up tasks. This is an engine/CLI contract; the app still has no gameplay session host.

The native `Gameplay` module can select original fixed-character events and
execute a bounded subset of the original ADV scalar commands. This extends the
day/period state model with actual event eligibility, variables, arithmetic,
branches, command batching, and timed waits. NPC navigation, character-state
bindings, presentation commands, and complete ADV execution remain unported.
These kernels run in tests and CLI traces. The app has Maker and Studio only; no
NPC entity, campaign save or asynchronous presentation host consumes them yet.

## Source recovery and original data

The converter reads `.local/reverse/managed-recovery/index.json`, chooses the main
game's selected recovered assembly project, and honors `manifest.json` per-type
compatibility overrides. It rejects selected files containing decompiler error
stubs. The generated contract hashes 22 selected source files, including
`FixEventScheduler`, `Cycle`, `ScenarioData`, `CommandList`, `TextScenario`,
`ValData`, and each implemented command handler. Previously generated incomplete
decompilations are not used.

Three small bundles were fetched read-only from the local Windows installation
and verified against the VM's SHA-256:

| Bundle | Bytes | SHA-256 |
|---|---:|---|
| `action/list/classschedule.unity3d` | 2,047 | `3d9e6f932127df44255a0a2eb3aeaa67a262f36b0228681136fdff6dc45abdb7` |
| `action/list/fixevent/00.unity3d` | 2,954 | `77459b59dec128acd7a9aed4448e05cc8b563ab3385a3127624a5c4f18f090d4` |
| `adv/scenario/common_param/20.unity3d` | 4,358 | `744411234524f2f8f03cd3944cd5217b9336dc29c3373a79404aef332a0514f4` |

UnityPy reads the actual `ClassSchedule`, `FixEventSchedule`, and `ScenarioData`
MonoBehaviour type trees. The first two bundles supply four class schedules
(20 weekday records) and four fixed-character schedules containing 48 events.
The converter retains source event order, asset strings, bundle paths, visibility,
coordinates, filters, layer names, and source path IDs. Blank class lessons are
normalized to the original generic classroom label. Fixed-event bundles are
processed in the explicit command-line order; no unverified package-order
inference is performed.

Only an explicitly selected parameter scenario is exported with arguments. The
remaining scenario assets are inventoried by name, path ID, command count, and
command IDs. Source bundles, converted tables, scenario arguments, decompilation
output, and evidence remain under ignored `.local/`.

## Fixed-event scheduler

`SourceFixedEventTable` reads the converted versioned table.
`SourceFixedEventScheduler.select(entries:context:)` implements the recovered
selection sequence:

1. A taken character cannot select an event.
2. Completed event IDs are skipped in source order. Only the **first unfinished
   event** is considered; an ineligible first event prevents later events from
   running.
3. The elapsed-day threshold must be met.
4. A weekday marker means Monday through Friday, taking precedence over explicit
   weekday entries in the same row. An empty week filter permits every day.
5. The current period's original localized label must appear in the row.
6. The map name is resolved by the supplied source map-name mapping; a missing
   map retains the source `-1` result.
7. During action periods, a nonempty layer name requires the first matching
   wait-point layer in source order. Otherwise, lesson periods require the
   relevant class lesson to occur as a substring of the event's map name.

The result includes the original row, source asset ID, row index, map number,
wait-point identity, and layer index. It does not spawn a character, consume an
event, advance daily counters, or open the scenario. Wait-point contexts currently
assume each point's map number agrees with its source dictionary bucket.

## ADV interpreter

`SourceADVProgram` preserves source command IDs, hash/version fields, `Multi`, and
the already-converted argument arrays stored in `ScenarioData`. It is not a parser
for the original authoring spreadsheet syntax.

`SourceADVInterpreter.start()` executes one source command batch.
`tick(deltaTime:requestNext:)` advances active waits and starts the next batch
when eligible. Variables retain distinct Int32, Single, Boolean, and String types.

| ID | Command | Implemented behavior |
|---:|---|---|
| 0 | None | No command object; continue the batch. |
| 1 | VAR | Typed assignment, source cast defaults, and bounded `*` indirection; random alternatives are unsupported. |
| 3 | Calc | Converted operators, left-to-right expression evaluation, source Int32 wrapping, float32 arithmetic, Boolean operations, and supported string arithmetic. |
| 4 | Clamp | Source float parsing, value substitution, and clamp ordering, while retaining the original destination variable name. |
| 12 | Tag | Local label definition and first-match lookup. |
| 14 | IF | Source comparer ordinals, typed equality, numeric/Boolean ordering, variable existence, and local branching. |
| 15 | Switch | Source case/default parsing, typed value string selection, and local branching. |
| 22 | Close | Close the interpreter; native scene release/unload is not dispatched. |
| 23 | Jump | Local tag lookup; a missing local tag continues normally. External file jumps report unsupported. |
| 25 | Wait | Float32 timer, default-zero parse behavior, batching, and cancellation by explicit Next input. |

Several recovered details matter for compatibility:

- `ConvertBeforeArgsProc` runs before whole-argument variable substitution.
  VAR, Calc, IF operands, Switch cases, and Clamp's destination retain their
  captured arguments. Jump targets, IF destination tags, and Wait durations use
  the substitutions appropriate to their handlers.
- Searching for a tag also substitutes the tag's own label. The first matching
  tag wins. Local jumps restart source batching and clear the previous command
  list's pending waits.
- `Multi=true` batches commands. More than one Wait may be active in a batch.
  Ordinary Wait is not in the source hard-block command list and explicit Next
  can cancel it; unsupported Choice/Task behavior is not fabricated.
- Calc has no mathematical operator precedence: `2 + 3 * 4` in the converted
  argument stream produces 20. Integer operations wrap except division errors.
  Boolean multiplication uses OR and Boolean division uses AND in the source.
- Existing variable equality is type-sensitive: Int32 `1` and Single `1` are
  unequal. Relational comparisons with differing operand types report a cast
  failure. String ordering is culture-sensitive and explicitly unsupported.
- The recovered `ValData.Cast` boxed-Single-to-Int32/Boolean path attempts an
  incompatible unbox. The native adapter reports that failure rather than
  quietly replacing it with a numeric conversion.
- Source float-to-string conversions use seven significant digits with the
  decimal-point locale used by these fixtures. The JSON interchange separately
  preserves float32 values for round trips.

The state reports `ready`, `frameBoundary`, `waiting`, `closed`, `exhausted`, or
`faulted`, plus the next command index and active waits. `exhausted` means that
the program's command records have been consumed; it does not mean the original
ADV scene has closed. A fault records the exact executing command index, command
ID, and reason. Previously executed scalar effects are retained for inspection.

Unsupported commands stop when encountered, including character/player bindings,
NPC actions, dialogue/choice presentation, audio, cameras, animation, task/background
execution, external-file opens, and arbitrary plug-in behavior. Extended literal
types, scientific IF literals, culture-sensitive string ordering, nonfinite
numbers, and random VAR alternatives also stop explicitly. The implemented
command subset is not a complete ADV VM. Native bounds limit recursion,
instructions, argument sizes, variables, input files, and trace output workload.

## Concrete original-source execution

The original parameter asset `301` contains Calc → Clamp → HeroineParam. Native
execution now runs the first two records, producing the expected scalar value.
The next frame stops at **pc 2, command ID 165** because its saved-character
binding is unported. This is a real original data path through the native
interpreter, with a visible compatibility boundary. It is not a reconstructed
dialogue or a playable NPC interaction.

## Original scenario command coverage (G-T03 first slice)

`Tools/reverse/analysis/adv_command_coverage.py` measures every `ScenarioData`
asset of the installed `abdata/adv/scenario` tree against the native kernel. It
reuses the contract tool's recovered-source selection and UnityPy extraction,
names ordinals from the recovered `ADV.Command` enum, and resolves the handler
class each `CommandList.CommandGet` arm constructs (enclosing `ADV` namespace
first, then exactly one `using` namespace, as C# does). Outputs contain original
arguments and stay in ignored `.local/gt03-adv-coverage/`; this page records
aggregate counts only.

**Corpus.** The VM listing found 225 scenario bundles (5,761,559 bytes; 274 `._*`
AppleDouble files were ignored). All 225 were fetched read-only with
`vm_source.py fetch`, each verified against the VM's length and SHA-256 and given
a provenance sidecar. The sorted `path sha256` list hashes to
`055492a2a67ba320fff66e1c27f47a2e8d96d7f2e4338f3bc72b44d092f3ceb7`. The bundles
hold **10,463 `ScenarioData` assets** (74 empty) and **294,393 command records**
using **120 distinct ordinals**; every `_version` is 0.

| Bundle directory | Bundles | Assets | Commands |
|---|---:|---:|---:|
| `c00`–`c38` | 212 | 10,130 | 272,353 |
| `c-1`, `c-2`, `c-4`, `c-5`, `c-8`, `c-9`, `c-10` | 9 | 161 | 20,766 |
| `common` | 1 | 14 | 227 |
| `common_param` | 2 | 150 | 236 |
| `op` | 1 | 8 | 811 |

**Implemented subset in real data.** Eight implemented ordinals occur (None and
Switch never do): Tag 6,949, Close 6,853, VAR 4,722, Jump 3,848, Calc 3,368,
IF 1,922, Wait 826 and Clamp 76 records, 28,564 in total (9.7%). The other 112
ordinals (265,829 records) are unsupported natively. Every used ordinal has an
original `CommandGet` handler, so no original no-op is mistaken for a fault.
Inside implemented commands, 101 VAR records carry random alternatives (native
fault whenever executed) and 299 IF records name an external `file:tag` branch
(native fault only when that branch is taken). All 3,848 Jump targets are local.

**Static first unsupported command** (program order, ignoring values):

| First unsupported index | Assets |
|---|---:|
| 0 | 9,569 |
| 1 | 436 |
| 2–4 | 366 |
| 10–19 | 4 |
| none | 88 |

Only 1,360 of 294,393 records (0.46%) precede their asset's first unsupported
command. **88 assets contain no unsupported ordinal**: 74 empty assets, 13
assets consisting of one Close, and one 11-command asset in `common` whose VAR
dereferences a host variable. No asset with dialogue, presentation or
character commands executes end to end today.

**Which command blocks first.** Ranked by the number of assets whose first
unsupported command it is (the full 27-row ranking is in `coverage.json`).
"Sole" counts assets for which it is the only unsupported ordinal.

| Rank | ID | Command | Recovered handler | Uses | Assets | First blocker | Sole |
|---:|---:|---|---|---:|---:|---:|---:|
| 1 | 128 | CharaLookNeck | `ADV.Commands.Chara.LookNeck` | 16,529 | 8,525 | 2,977 | 0 |
| 2 | 88 | BGMPlay | `ADV.Commands.Sound.BGM.Play` | 3,205 | 3,008 | 2,588 | 0 |
| 3 | 169 | MapChange | `ADV.Commands.Game.MapChange` | 2,415 | 2,219 | 1,262 | 0 |
| 4 | 43 | Fade | `ADV.Commands.Effect.Fade` | 6,827 | 2,833 | 1,112 | 0 |
| 5 | 38 | BGLoad | `ADV.Commands.Base.BackGroundLoad` | 2,383 | 1,938 | 784 | 0 |
| 6 | 112 | CharaExpression | `ADV.Commands.Chara.Expression` | 9,586 | 6,458 | 462 | 136 |
| 7 | 17 | Voice | `ADV.Commands.Base.Voice` | 31,165 | 8,907 | 450 | 0 |
| 8 | 19 | Expression | `ADV.Commands.Base.Expression` | 19,901 | 6,314 | 178 | 0 |
| 9 | 45 | SceneFadeRegulate | `ADV.Commands.Effect.SceneFadeRegulate` | 5,687 | 5,174 | 78 | 0 |
| 9 | 106 | CharaMotion | `ADV.Commands.Chara.Motion` | 8,407 | 6,748 | 78 | 0 |
| 9 | 201 | ParameterFile | `ADV.Commands.Game.ParameterFile` | 6,243 | 5,810 | 78 | 0 |
| 12 | 165 | HeroineParam | `ADV.Commands.Game.HeroineParam` | 3,365 | 1,318 | 76 | 76 |

The most used command, Text (`ADV.Commands.Base.Text`, 63,122 records in 8,956
assets), is the first blocker of only 46 assets because character look, audio,
map and fade setup precede it. Grouped by handler namespace:

| Namespace (`ADV.Commands.*`) | Used IDs | Unsupported IDs | Uses | Assets | First blocker |
|---|---:|---:|---:|---:|---:|
| `Chara` | 35 | 35 | 65,303 | 9,268 | 3,558 |
| `Sound.BGM` | 2 | 2 | 3,220 | 3,008 | 2,589 |
| `Base` | 31 | 23 | 173,922 | 10,004 | 1,544 |
| `Game` | 17 | 17 | 17,547 | 7,246 | 1,471 |
| `Effect` | 7 | 7 | 26,261 | 6,108 | 1,194 |
| `Camera` | 10 | 10 | 1,115 | 351 | 19 |
| `EventCG` | 3 | 3 | 3,673 | 970 | 0 |
| `CameraEffect` | 3 | 3 | 1,936 | 852 | 0 |
| `H` | 7 | 7 | 837 | 378 | 0 |
| `Sound.SE2D` | 2 | 2 | 484 | 268 | 0 |
| `Object` | 3 | 3 | 95 | 4 | 0 |

Implementing one blocker mostly moves halts forward; it rarely completes an
asset. A greedy order that repeatedly implements the current most frequent
first blocker (static, by ordinal only) reaches:

| After implementing | Assets with no unsupported ordinal | Records before first unsupported |
|---|---:|---:|
| CharaLookNeck, CharaLookEyes, BGMPlay | 88 | 13,021 |
| + CharaExpression | 224 | 15,507 |
| + CharaMotion, Expression, Motion, Voice | 476 | 25,500 |
| + Text | 2,124 | 47,294 |
| + MapChange, NullLoad, NullSet, SceneFade, SceneFadeRegulate, ParameterFile | 4,352 | 84,728 |

"No unsupported ordinal" is a static ceiling, not playback: those commands
still need character, audio, map and presentation hosts, and value-dependent
faults (below) remain possible.

### Observed native halts

Every asset was run through `ikkoku-inspect adv-trace` with **default inputs**:
no host variables, a 1,000-second frame per batch (completing any source Wait),
no explicit Next input, `commandCount + 4` frames. The comparison step checks
each observed fault position, command ID and reason against the static
prediction, detects batches whose observed next pc cannot be sequential (a
taken local jump), and checks the outcome against a static reachable-outcome
set that forks every IF branch and treats reachable Calc/Clamp/IF/Switch and VAR
dereferences as possible value faults.

| Observed outcome | Assets |
|---|---:|
| Fault at the predicted index with the predicted ID and reason | 10,369 (10,360 unsupported ordinals, 9 VAR random alternatives) |
| Close or exhaustion where no halt was predicted | 87 (74 empty, 13 Close-only) |
| Value-dependent fault before the predicted index | 7 |
| Unexplained mismatch / outcome outside the reachable set | 0 / 0 |

Of 176 assets with IF/Jump/Close before their predicted halt, 170 halt exactly
as predicted (40 after an observed taken jump). The 7 value-dependent faults are
six IFs at pc 0 whose left operand names a host variable that default inputs do
not supply, which native rejects as an extended IF literal (the recovered
`VAR.CheckLiterals` cannot parse that name either; the game supplies the
variable), and one VAR dereferencing an absent host variable. These are
default-input outcomes, not game behavior: with real host variables, IF branches
can select other paths.

**Sample regression.** `sample.json` is a deterministic stratified sample chosen
from static properties only: 32 assets (first-command 6, scalar prefix 5,
value-dependent prefix 3, taken-branch-possible prefix 6, other control flow 4,
argument limit 3, executable 4, empty 1; no corpus asset has a Wait-only or
Close-before prefix). The gated Engine test
`sourceADVCoverageSampleHaltsAtPredictedSourceIndex` runs each with the same
default inputs, requires every outcome to be statically reachable, requires the
exact predicted pc, ID and `ADV command ID <id> at pc <pc>` reason for the 17
straight-line cases, and runs 10 mutation controls that replace the halting
record with None and require the halt to move to the next predicted record. A
deliberately corrupted sample fails the test with 3 issues.

```sh
python3 Tools/reverse/vm_source.py --vm 'Windows 11' --output .local/reverse \
  fetch abdata/adv/scenario/<dir>/<bundle>.unity3d   # all 225 listed bundles
swift build --package-path Packages/Engine --product ikkoku-inspect
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/adv_command_coverage.py scan \
  --recovery-index .local/reverse/managed-recovery/index.json \
  --scenario-root .local/reverse/source/abdata/adv/scenario --output .local/gt03-adv-coverage
for f in .local/gt03-adv-coverage/traces/trace-[0-9][0-9][0-9].json; do
  "$(swift build --package-path Packages/Engine --show-bin-path)/ikkoku-inspect" adv-trace "$PWD/$f" \
    > "${f%.json}.report.json"
done
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/adv_command_coverage.py compare \
  --output .local/gt03-adv-coverage
IKKOKU_ADV_COVERAGE_SAMPLE="$PWD/.local/gt03-adv-coverage/sample.json" \
  swift test --package-path Packages/Engine --filter sourceADVCoverage
```

Base and namespace asset counts overlap; they are not additive. Exclusions: the
static prediction ignores values and host state; the dynamic
run starts every asset at pc 0 although the game can open a file at a tag; the
corpus is this installation's `abdata/adv/scenario` only (no mod or other
scenario roots), and no original game run was captured for comparison.

## Verification and reproduction

The retained focused run contains twelve native tests covering scheduler behavior, command batching, waits, arithmetic,
type-sensitive comparisons, fault positions, loop budgets, float interchange,
and the original parameter scenario. Twelve Python tests cover the converter,
source-selection rules, and independent expected outcomes.

The fixed-event oracle evaluates original uppercase-field Unity records directly,
not the converted native rows. It generates **4,032 synthetic contexts** covering
each of the 48 original events across every weekday and period. The ADV corpus
contains **12 hand-derived cases** with expected states, independently authored
from the recovered handlers. Neither corpus invokes native code to manufacture
its expected results.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/gameplay_execution_contract.py \
  --recovery-index .local/reverse/managed-recovery/index.json \
  --class-bundle .local/reverse/source/abdata/action/list/classschedule.unity3d \
  --fixed-bundle .local/reverse/source/abdata/action/list/fixevent/00.unity3d \
  --scenario-bundle .local/reverse/source/abdata/adv/scenario/common_param/20.unity3d \
  --output .local/reverse/gameplay-execution
.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse -p test_gameplay_execution_contract.py
IKKOKU_GAMEPLAY_EXECUTION_REFERENCE="$PWD/.local/reverse/gameplay-execution" \
  swift test --package-path Packages/Engine --filter 'sourceFixedEvent|sourceADV'
```

The CLI helpers accept the generated `fixed-event-trace.json`, `adv-reference.json`,
and `original-parameter-trace.json`. A fixed-event request supplies a table path
and contexts. An ADV request supplies a program, optional typed variables, and
explicit frame durations/Next inputs. Reports show computed selections or state
snapshots, not the reference expectations embedded in the input file.

## Pending integration

1. Implement a session and deferred-effect dispatcher with acknowledged scene/task
   barriers and saveable in-flight state (`G-T01`). A cycle transition must wait
   for actual completion rather than test-injected flags.
2. Bind source player/heroine data and implement `HeroineParam` (`G-T02`). Accept
   when original scenario 301 completes with source-verified values and a fixed
   event runs once across save/reload with its original ID.
3. Expand the VM by command family in the measured order above (`G-T03`); the
   inventory and halting check are done. Add cross-file resolution,
   dialogue/choices, tasks and audio/camera/animation consumers with typed host
   effects. Test cancellation, skip, interruption and save/reload at every wait.
4. Recover one neutral map/NPC route and its action/navigation/behavior-tree data
   (`G-T04`). Compare numeric decisions/positions with source traces, including
   interaction interruption and resumed movement.

The installed source corpus is broader than this implemented scalar subset.
Report discovered, decoded, executed and host-integrated command coverage
separately; stopping at an explicit unsupported command is not scenario completion.
