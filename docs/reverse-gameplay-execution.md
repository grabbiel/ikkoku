# Fixed-event selection and bounded ADV execution

The native `Gameplay` module can now select original fixed-character events and
execute a bounded subset of the original ADV scalar commands. This extends the
day/period state model with actual event eligibility, variables, arithmetic,
branches, command batching, and timed waits. NPC navigation, character-state
bindings, presentation commands, and complete ADV execution remain unported.

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

## Verification and reproduction

Twelve native tests cover scheduler behavior, command batching, waits, arithmetic,
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

The next gameplay integration boundary is source save-state binding: apply
selected events to native character/player records and route supported ADV state
commands into those records. Navigation still requires converted source action
tables, behavior-tree decisions, map topology, and a native movement solver.
