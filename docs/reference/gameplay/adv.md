# Fixed-event selection and bounded ADV execution

Reviewed 2026-10-23 against the working tree (G-T02 character bindings; G-T03 host-request slice; A-T01 gameplay host first slice). The [Gameplay audit](../../component-audit/app-gameplay-and-plugins.md#g-gameplay-cycle-event-selection-and-adv) tracks completion and follow-up tasks. This is an engine/CLI contract. The native [gameplay host](cycle.md#gameplay-host-a-t01) runs one selected fixed event's program with its heroine bound and consumes only MapChange requests; the app runs it headlessly only.

The native `Gameplay` module can select original fixed-character events and
execute a bounded subset of the original ADV commands: the scalar commands
(variables, arithmetic, branches, batching, timed waits), fourteen
presentation commands whose effects are issued as typed, saveable host
requests (G-T03), and, since G-T02, the saved-heroine bindings: `HeroineParam`
writes the bound heroine's parameters and `ParameterFile` inserts programs from
the original parameter library. NPC navigation, the player and other character
commands, the remaining presentation commands and complete ADV execution remain
unported.
These kernels run in tests, CLI traces and the headless gameplay host. The app
has Maker and Studio only. No NPC entity, campaign save or presentation host
consumes the requests, so nothing is displayed or played. The gameplay host's
MapChange only changes its native active-map number; no map asset loads.

## Source recovery and original data

The converter reads `.local/reverse/managed-recovery/index.json`, chooses the main
game's selected recovered assembly project, and honors `manifest.json` per-type
compatibility overrides. It rejects selected files containing decompiler error
stubs. The generated contract hashes 40 selected source files, including
`FixEventScheduler`, `Cycle`, `ScenarioData`, `CommandList`, `TextScenario`,
`MainScenario`, `ValData`, `NullCheck`, `StringExtensions`, the `BGM` enum and each
implemented command handler, and checks the 24 implemented ordinals against the
recovered `ADV.Command` enum. Previously generated incomplete
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
| 165 | HeroineParam | `Heroine.SetADVParam(scenario, key, value)` on the bound heroine: captured key, replaced value, conversion to the key's current type, field write, `Vars`/`Replaces` refresh and the `H_callID` call-name path ([character bindings](#character-bindings-g-t02)). |
| 201 | ParameterFile | Inserts the named `scenarioParameterDic` program after its own line (`CurrentLine + 1`); an unknown name does nothing. |

IDs 16–19, 35, 37, 44, 45, 88, 106, 112, 125, 128 and 169 are presentation
commands executed as host requests; see the next section.

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

The state reports `ready`, `frameBoundary`, `waiting`, `awaitingHost`,
`awaitingNext`, `closed`, `exhausted`, or `faulted`, plus the next command index,
active waits, pending host requests and the batch counter. `exhausted` means that
the program's command records have been consumed; it does not mean the original
ADV scene has closed. A fault records the exact executing command index, command
ID, and reason. Previously executed scalar effects are retained for inspection.

Unsupported commands stop when encountered, including the player and other
character commands (`PlayerParam`, `CharaChange`, `CharaEvent`, …), NPC actions, choices, voice/SE playback commands,
cameras, backgrounds, Fade/Filter effects, animation other than CharaMotion,
task/background execution, external-file opens, and arbitrary plug-in behavior. Extended literal
types, scientific IF literals, culture-sensitive string ordering, nonfinite
numbers, and random VAR alternatives also stop explicitly. The implemented
command subset is not a complete ADV VM. Native bounds limit recursion,
instructions, argument sizes, variables, input files, and trace output workload.

## Host requests for presentation commands (G-T03 second slice)

Sources: [SourceADVHostRequest.swift](../../../Packages/Engine/Sources/Gameplay/SourceADVHostRequest.swift),
[SourceADVArgumentParsing.swift](../../../Packages/Engine/Sources/Gameplay/SourceADVArgumentParsing.swift),
[SourceADVInterpreter.swift](../../../Packages/Engine/Sources/Gameplay/SourceADVInterpreter.swift);
independent model [adv_host_requests.py](../../../Tools/reverse/analysis/adv_host_requests.py).

**Request model.** A presentation command does not present anything natively.
Its handler arguments are decoded exactly as the recovered `Do()` decodes them
and queued as a `SourceADVHostRequest`: `requestID` (sequential per
interpreter), `pc` (source command index), `commandID`, `batch` (the
`RequestNextLine` count when it ran), a `blocking` policy and a typed `command`
payload (`{"kind": …, "arguments": …}` in JSON, nil fields omitted). The host
calls `drainRequests()` to receive them in source execution order, then
`acknowledge(_:variables:)` for blocking ones, or `hostFailure(_:reason:)` when it
cannot perform one (for example a missing character, which would throw inside the
source handler); that faults at the request's pc. Character numbers keep the
source convention: `2147483647` (`int.MaxValue`, the handlers' default) means
the current character. The whole interpreter (program, variables, waits, queued
and pending requests, Next state, batch counter, Text bindings) is `Codable`; a
decoded state is validated and resumes identically, including mid-wait,
mid-acknowledgement and mid-Next.

**Frame model.** `tick` follows `TextScenario.MessageWindowProc`:

1. `UpdateRegulate` gates come first. While a MapChange request is pending
   (`advScene.Map.isMapLoading`), or a SceneFade request is pending and
   `isSceneFadeRegulate` is set (`sceneFade.IsFadeNow`), nothing runs: no Next,
   no Wait timer, no command. The flag defaults to true (`TextScenario.MemberInit`)
   and SceneFadeRegulate changes it.
2. Otherwise Wait timers advance. The next batch starts on explicit Next, or
   when no Text waits for Next and no Wait or SceneFade is still processing.
   `RequestNextLine` runs `CommandList.ProcessEnd` (ends Waits and a non-gating
   SceneFade) and `textHash.Clear()`; only this advance path also runs
   `CurrentCharaData.Clear()`. Local jumps re-enter `RequestNextLine` without it.
3. A Text batch waits for Next. The source's first click on incomplete text only
   completes the display; the host forwards Next once its display is complete.

**Commands.** Arguments are `CommandBase.Initialize` (non-empty arguments
override `ArgsDefault`, extras append) followed by `TextScenario.ReplaceVars` on
every argument (whole-argument substitution; none of these handlers overrides
`ConvertBeforeArgsProc`). "Fault" means an uncaught exception in `Do()`, which
stops the source coroutine; the native kernel faults at that pc.

| ID | Command | Recovered handler | Request / effect | Blocking | Argument decoding |
|---:|---|---|---|---|---|
| 128 | CharaLookNeck | `ADV.Commands.Chara.LookNeck.Do` | `charaLookNeck {chara, pattern, rate}` → `ChangeLookNeckPtn` | none | Defaults `[int.MaxValue, 0, 1]`; `int.Parse` No and Ptn, `float.Parse` Rate; any exception faults. |
| 125 | CharaLookEyes | `ADV.Commands.Chara.LookEyes.Do` | `charaLookEyes {chara, pattern}` → `ChangeLookEyesPtn` | none | Defaults `[int.MaxValue, 0]`; `int.Parse` No and Ptn. |
| 88 | BGMPlay | `ADV.Commands.Sound.BGM.Play.Do` | `bgmPlay` with `number` (+`enumName`) or `bundle`, `asset?`, `delay`, `fade?`, `isAsync`, `pitch?`, `panStereo?`, `time?`, `volume?` | none | Nine defaults (`Delay` 0, `isAsync` True). Bundle: `int.TryParse`, else `Utils.Enum<Illusion.Game.BGM>.FindIndex(ignoreCase)` (28 names checked against the recovered enum), else a bundle path. Asset/Fade/Pitch/PanStereo/Time/Volume via `SafeProc`; `float.Parse`, `bool.Parse`. |
| 112 | CharaExpression | `ADV.Commands.Chara.Expression.Do` → `Base.Expression.Convert` | `charaExpression [entry]` (`chara`, `lookupKey?`, `expression?`) | none | Default `[int.MaxValue]`. Per entry: with a second argument, `int.Parse(No)` outside any try (faults), then the ExpLoad table (always empty: ExpLoad is unsupported) and the personality table (`Manager.Game.GetExpression`, host). A key that is not a valid `Expression.Pattern` yields a lookup-only entry (the fallback parse consumes the same two arguments and changes nothing). Otherwise `Expression.Data` parses No and 11 fields (`Expression.Initialize` order) with exceptions swallowed; when both a key and fields are present the host must reject a table hit (`requiresLookupMiss`). |
| 106 | CharaMotion | `ADV.Commands.Chara.Motion.Do` → `Base.Motion.Convert`, `Motion.Data` | `charaMotion [motion]`; the host starts `CrossFadeStart` when the list is non-empty | none | Default `[int.MaxValue]`. MotionLoad table always empty. `Data`: No, State, eight `SafeGet` names, LayerNo (`Split(',')` + `int.Parse`); exceptions swallowed, leaving later fields nil (`chara` 0). |
| 19 | Expression | `ADV.Commands.Base.Expression.Do` | Appends one entry list to the Text bindings (`expressions`) | — | As 112. |
| 18 | Motion | `ADV.Commands.Base.Motion.Do` | Appends to `motions` | — | As 106. |
| 17 | Voice | `ADV.Commands.Base.Voice.Do`, `Voice.Data` | Appends to `voices` | — | Default `[int.MaxValue]`; No `int.Parse`, Bundle/Asset `SafeGet`, Personality `int.Parse` and Pitch `float.Parse` via `SafeProc`; exceptions swallowed. Nil personality/pitch and an empty bundle are resolved by the host (character `voiceNo`/`voicePitch`, `bundleVoices` memory). |
| 16 | Text | `ADV.Commands.Base.Text.Do` | `text {name, text, voices?, expressions?, motions?}`: the `CurrentCharaData` lists since the last advance, which `Text.Next` plays in step with the voices | next | No defaults; `Text.Data`: name = argument 0, text = argument 1 (`@br` was converted at import). `ReplaceText` name tags and the backlog are host work. |
| 169 | MapChange | `ADV.Commands.Game.MapChange.Do` | `mapChange {mapNumber? / mapName?, fade}`; the acknowledgement carries `Cycle.ADVVariables`, stored as String variables | acknowledge (map-loading gate; survives ProcessEnd) | Defaults `["0", "1"]`. `int.TryParse` No, else the host's `Map.ConvertMapNo(name)`. Fade: `Scene.Data.FadeType` `Check(ignoreCase)`, else `bool.TryParse` (false → None), else `int.TryParse`, whose success clamps the unchanged default, so InOut stays. The source writes ADV variables synchronously after `Map.Change`; that is equivalent to writing them at acknowledgement only because MapChange ends its batch, so `Multi=true` faults (no installed record uses it). The host must evaluate them right after starting the change. |
| 35 | NullLoad | `ADV.Commands.Base.NullLoad.Do` | `nullLoad {version, map?}` → bundle `map/advpos/<version:00>/<name>.unity3d` | none | Defaults `["0", ""]`; `int.Parse` Version; the handler's default-map literal maps to nil (`default`), other names go through the host's `Map.GetParam(name).AssetName`. |
| 37 | NullSet | `ADV.Commands.Base.NullSet.Do` | `nullSet {name, target?}` (`Base`/`Camera`/`Chara`; nil does nothing) | none | Defaults `["", "Base"]`; `Check(ignoreCase, Enum<Type>.Names)`. |
| 44 | SceneFade | `ADV.Commands.Effect.SceneFade.Do`/`Process`/`Result` | `sceneFade {fadeIn, time?, textureBundle?, textureAsset?}` | acknowledge (`Process` returns `fade.IsEnd`; with `isSceneFadeRegulate` also the UpdateRegulate gate; ProcessEnd → `ForceEnd`) | Defaults `["in", "", "", "", "none"]`; `Compare("in", ignoreCase)`, Time `SafeProc` `float.Parse`. A non-empty Color faults as unsupported (`GetColor` is not modelled; no installed record sets it). |
| 45 | SceneFadeRegulate | `ADV.Commands.Effect.SceneFadeRegulate.Do` | Interpreter state `sceneFadeRegulate` (saved) | — | Default `["True"]`; `bool.Parse`. |

**Parsing.** `SourceCLR` reproduces Unity Mono's `mscorlib` (decompiled from the
installed `Managed/mscorlib.dll`): `int.Parse`/`TryParse` (invariant fast path:
white space, one sign, ASCII digits, NUL terminates, overflow throws),
`float.Parse` (`(float)double.Parse(s, Float | AllowThousands)` state machine plus
Mono's positive-overflow check, so `3.4028235e38` throws), `bool.Parse` (`Trim`
then ignore-case comparison). Results the kernel cannot reproduce exactly fault
as unsupported instead of guessing, even where the source would swallow an
exception: non-ASCII digits or white space, `,` (culture group/decimal
separator), culture NaN/Infinity symbols, non-canonical digit strings for the
native `Double.ParseImpl`, Unicode-version-dependent white space (U+180E, U+200B,
U+FEFF), and culture-sensitive string comparisons (`Check`, `Enum.FindIndex`,
`Compare`) that differ only in punctuation, spaces or non-ASCII characters. The
current culture is assumed to be non-Turkic with `.` as decimal separator (as in
the game's Japanese environment).

**Not covered.** Rendering, audio, map loading, character lookup and personality
tables are host work, and no host exists yet. A BGMPlay whose Pitch, PanStereo,
Time or Volume throws faults before its request is issued, whereas the source
has already started playback (no installed record does this). Expression and
motion definitions loaded by ExpLoad/MotionLoad, choices, skip and auto modes,
backlog, and expression icons (`ExpressionIcon` is unsupported) are excluded.

## Character bindings (G-T02)

Sources: [SourceADVCharacterParameters.swift](../../../Packages/Engine/Sources/Gameplay/SourceADVCharacterParameters.swift),
[SourceADVCharacterBinding.swift](../../../Packages/Engine/Sources/Gameplay/SourceADVCharacterBinding.swift),
[SourceADVInterpreter.swift](../../../Packages/Engine/Sources/Gameplay/SourceADVInterpreter.swift);
independent model [adv_character_tables.py](../../../Tools/reverse/analysis/adv_character_tables.py)
(keys from the recovered `SaveData` source, table extraction, parameter-program
effects) and the bound path of
[adv_command_coverage.py](../../../Tools/reverse/analysis/adv_command_coverage.py);
original-runtime probe [OriginalADVBindingProbe.cs](../../../Tools/reverse/fixtures/OriginalADVBindingProbe.cs),
driven by [original_adv_binding_probe.py](../../../Tools/reverse/original_adv_binding_probe.py).

**Binding.** `SourceADVInterpreter(program:variables:sceneFadeRegulate:character:parameterLibrary:)`
optionally takes a `SourceADVCharacterBinding` (`TextScenario.currentHeroine`,
an optional `Manager.Game.Player`, and the character tables its getters read)
and a `SourceADVParameterLibrary` (`Manager.Game.scenarioParameterDic`). With a
heroine, initialization seeds it as `Heroine.SetADVParam(scenario)` does (the
call `CharaChange` makes), after the supplied variables. Without a heroine,
HeroineParam faults as the source's null `currentHeroine` would; without a
library, ParameterFile faults as unsupported. A nil player models no
`Manager.Game` instance, so `callMyID` falls back to `SaveData.callDefaultID`.

**Data model.** `SourceHeroineParameters` and `SourcePlayerParameters` are
`Codable` and hold every field a key reads or writes, plus the members the
getters depend on: the `ChaFileParameter` subset (`lastname`, `firstname`,
`nickname`, `personality`, `bloodType`, `birthMonth`, `birthDay`,
`clubActivities`, `weakPoint`), `hAreaExps`, `countKokanH`, `countAnalH`,
`talkEvent` (`m_TalkEvent`, kept sorted), the runtime `coordinates`/`isDresses`
(null until the action scene sets them) and `cachedVoiceNo`. JSON member names
are the C# field names. Defaults are the new-game objects: `new
SaveData.Heroine(false)` (field initializers, `CharaData` defaults,
`ChaFileParameter.MemberInit`) and `new SaveData.Player(false)` with
`Player.Initialize` (`schoolClass` 1, `schoolClassIndex` 20, `callID =
SaveData.callDefaultID`, which `Manager.Game.Awake` sets in `InitializeCall`
before `NewGame`). Decoding is lenient (a missing member keeps its default),
except that the player's `callID` is required.

### Character parameters

`SaveData.CharaData.Params` builds one `Params.Data` (`command`, `key`, getter,
optional setter) per public instance field, then per public instance property,
of the concrete class whose type is `int`, `bool` or `string`
(`Utils.Type.GetPublicFields`/`GetPublicProperties`, `Data.Cast(Type)`),
prefixed `H_` or `P_`. `Heroine.Params` and `Player.Params` then append the
Replace keys and the heroine's `HExperience` keys. Only fields get a setter
(`FieldInfo.SetValue(chara, Convert.ChangeType(o, FieldType))`); a property's
`Pointer.value` setter is the null-safe `set.Call`, so writing a property key
changes `Vars` only. Float, enum, `uint` and array members are not keys
(`countKokanH`, `nameType`, `playTime`, `isDresses`, …).

The heroine has **58 keys (29 writable)** and the player **31 (13 writable)**.
Key names are the original ones, never renamed. The order is Mono's reflection
order, which the original runtime reports identically (probe below). No value
depends on it: the only side effect among reflected getters is the idempotent
`voiceNo` cache, and the `HExperience` keys, whose getter clamps `lewdness`,
are always appended after `H_lewdness`.

| Key suffix | Type | Source member | `H_` | `P_` | Writable | New-game value or getter |
|---|---|---|:-:|:-:|:-:|---|
| `favor` | Int | `SaveData.Heroine.favor` | ✓ | | ✓ | 0 |
| `lewdness` | Int | `SaveData.Heroine.lewdness` | ✓ | | ✓ | 0 |
| `hCount` | Int | `SaveData.Heroine.hCount` | ✓ | | ✓ | 0 |
| `isStaff` | BOOL | `SaveData.Heroine.isStaff` | ✓ | | ✓ | False |
| `isGirlfriend` | BOOL | `SaveData.Heroine.isGirlfriend` | ✓ | | ✓ | False |
| `isAnger` | BOOL | `SaveData.Heroine.isAnger` | ✓ | | ✓ | False |
| `anger` | Int | `SaveData.Heroine.anger` | ✓ | | ✓ | 0 |
| `fixCharaID` | Int | `SaveData.Heroine.fixCharaID` | ✓ | | ✓ | 0 |
| `isTaked` | BOOL | `SaveData.Heroine.isTaked` | ✓ | | ✓ | False |
| `isDate` | BOOL | `SaveData.Heroine.isDate` | ✓ | | ✓ | False |
| `nickNameTalkCount` | Int | `SaveData.Heroine.nickNameTalkCount` | ✓ | | ✓ | 0 |
| `myRoomCount` | Int | `SaveData.Heroine.myRoomCount` | ✓ | | ✓ | 0 |
| `confessed` | BOOL | `SaveData.Heroine.confessed` | ✓ | | ✓ | False |
| `isVirgin` | BOOL | `SaveData.Heroine.isVirgin` | ✓ | | ✓ | True |
| `isAnalVirgin` | BOOL | `SaveData.Heroine.isAnalVirgin` | ✓ | | ✓ | True |
| `isKiss` | BOOL | `SaveData.Heroine.isKiss` | ✓ | | ✓ | False |
| `countNamaInsert` | Int | `SaveData.Heroine.countNamaInsert` | ✓ | | ✓ | 0 |
| `countHoushi` | Int | `SaveData.Heroine.countHoushi` | ✓ | | ✓ | 0 |
| `eventAfterDay` | Int | `SaveData.Heroine.eventAfterDay` | ✓ | | ✓ | 0 |
| `isFirstGirlfriend` | BOOL | `SaveData.Heroine.isFirstGirlfriend` | ✓ | | ✓ | False |
| `intimacy` | Int | `SaveData.Heroine.intimacy` | ✓ | | ✓ | 0 |
| `talkTimeMax` | Int | `SaveData.Heroine.talkTimeMax` | ✓ | | ✓ | 4 |
| `talkTime` | Int | `SaveData.Heroine.talkTime` | ✓ | | ✓ | 4 |
| `isTalkPoint` | BOOL | `SaveData.Heroine.isTalkPoint` | ✓ | | ✓ | False |
| `isLunch` | BOOL | `SaveData.Heroine.isLunch` | ✓ | | ✓ | False |
| `intellect` | Int | `SaveData.Player.intellect` | | ✓ | ✓ | 0 |
| `physical` | Int | `SaveData.Player.physical` | | ✓ | ✓ | 0 |
| `hentai` | Int | `SaveData.Player.hentai` | | ✓ | ✓ | 0 |
| `actionCount` | Int | `SaveData.Player.actionCount` | | ✓ | ✓ | 5 |
| `girlfriendedCnt` | Int | `SaveData.Player.girlfriendedCnt` | | ✓ | ✓ | 0 |
| `hcount` | Int | `SaveData.Player.hcount` | | ✓ | ✓ | 0 |
| `hPeopleCount` | Int | `SaveData.Player.hPeopleCount` | | ✓ | ✓ | 0 |
| `orgCount` | Int | `SaveData.Player.orgCount` | | ✓ | ✓ | 0 |
| `changeClothesType` | Int | `SaveData.Player.changeClothesType` | | ✓ | ✓ | 0 |
| `callID` | Int | `SaveData.CharaData.callID` | ✓ | ✓ | ✓ | Heroine -1; player `SaveData.callDefaultID` |
| `callName` | String | `SaveData.CharaData.callName` | ✓ | ✓ | ✓ | Empty |
| `schoolClass` | Int | `SaveData.CharaData.schoolClass` | ✓ | ✓ | ✓ | Heroine -1; player 1 |
| `schoolClassIndex` | Int | `SaveData.CharaData.schoolClassIndex` | ✓ | ✓ | ✓ | Heroine -1; player 20 |
| `isTeacher` | BOOL | `SaveData.Heroine.isTeacher` | ✓ | | | `fixCharaID` in -4…-1 |
| `FixCharaIDOrPersonality` | Int | `SaveData.Heroine.FixCharaIDOrPersonality` | ✓ | | | `fixCharaID`, or `personality` when it is 0 |
| `ChaName` | String | `SaveData.Heroine.ChaName` | ✓ | | | `"c"` + `FixCharaIDOrPersonality.MinusThroughToString("00")` |
| `ChaVoice` | String | `SaveData.Heroine.ChaVoice` | ✓ | | | `"c"` + `voiceNo.MinusThroughToString("00")` |
| `voiceNo` | Int | `SaveData.Heroine.voiceNo`, `SaveData.Player.voiceNo` | ✓ | ✓ | | Cached on first read. Heroine: `FixCharaIDOrPersonality` when `voiceInfoDic` has it, else `personality`; player: -100 when present, else `personality` (config table) |
| `relation` | Int | `SaveData.Heroine.relation` | ✓ | | | 2 for a girlfriend, else 1 with talk event 2, else 0 with talk event 0 or 1, else -1 |
| `isNickNameEvent` | BOOL | `SaveData.Heroine.isNickNameEvent` | ✓ | | | Talk event 89 or 90 |
| `NowCoordinate` | Int | `SaveData.Heroine.NowCoordinate` | ✓ | | | With `isDresses`, the coordinate at its first false entry (else the last); otherwise `coordinates.SafeGet(0)`, 0 when unset |
| `isNickNameNormal` | BOOL | `SaveData.CharaData.isNickNameNormal` | ✓ | ✓ | | `!GetCallName(personality, callMyID).isSpecial` (nickname table; a missing ID throws) |
| `callMyID` | Int | `SaveData.CharaData.callMyID` | ✓ | ✓ | | `callID`, else (heroine) `Manager.Game.Player.callID`, else `SaveData.callDefaultID` |
| `Name` | String | `SaveData.CharaData.Name` | ✓ | ✓ | | `lastname + " " + firstname` |
| `lastname`, `firstname`, `nickname` | String | `SaveData.CharaData.<member>` (`charFile.parameter`) | ✓ | ✓ | | Empty |
| `personality`, `bloodType`, `clubActivities` | Int | `SaveData.CharaData.<member>` | ✓ | ✓ | | 0 (byte members widen) |
| `birthMonth`, `birthDay` | Int | `SaveData.CharaData.<member>` | ✓ | ✓ | | 1 |
| `weakPoint` | Int | `SaveData.CharaData.weakPoint` | ✓ | ✓ | | -1 |
| `charFileInitialized` | BOOL | `SaveData.CharaData.charFileInitialized` | ✓ | ✓ | | False (`Load` sets it) |
| `HExperience` | String | `SaveData.Heroine.HExperience.ToString()` | ✓ | | | The `HExperienceKind` member name |
| `HExperienceIndex` | Int | `(int)SaveData.Heroine.HExperience` | ✓ | | | Clamps the `lewdness` field to 0…100, then 0 when `hCount` < 1, 1 until `countKokanH`, `countAnalH` and `hAreaExps[1…]` all reach 100, 2 while `lewdness` < 100, else 3 |

The Replace keys (`Replaces`, the host's `ReplaceText` tags; read-only) are the
bare prefix `H`/`P` (`string.Empty`), then `<prefix>` + each
`SaveData.CharaData.Names` suffix: 姓 (`lastname`), 名 (`firstname`), 名前
(`Name`), and for the heroine only あだ名 (`nickname`). The heroine also
appends `Pあだ名`, its own `callName`.

### Commands, tables and persistence

**Seed.** `Heroine.SetADVParam(scenario)` writes every Int, BOOL and String
key's getter value to `Vars` in key order (the conversion to the value's own
type is the identity), then every Replace key to `Replaces`. A getter that
needs a table the binding lacks faults with a named reason (for example
`ADV character table not bound: Manager.Voice.voiceInfoDic (etcetra/list/config)`).

**HeroineParam (165).** `ADV.Commands.Game.HeroineParam` has no `ArgsDefault`.
Its `ConvertBeforeArgsProc` captures `args[0]`, the key, before
`ReplaceVars`; `Do` reads `args[1]` after it. A missing argument is a definite
`IndexOutOfRangeException`. `Heroine.SetADVParam(scenario, key, o)` then:

1. finds the key (`FirstOrDefault`); an unknown key returns without effect;
2. runs the getter, with its side effects, for `data.value.GetType()`;
3. converts `o` with `ValData.Convert` (`Convert.ChangeType`): Int32 uses
   `Int32.Parse(NumberStyles.Integer, invariant)`, so `" +12 "` parses and
   `"6.5"` throws `FormatException`; Boolean uses `bool.Parse`; String is the
   identity;
4. writes a field (a property is unchanged) and sets `Vars[key]`;
5. for `H_callID`, runs `CallNameChange`;
6. refreshes every Replace key.

Effects before a throw are kept, as in the source. `Player.SetADVParam` has no
call-name path and no Replace refresh. No installed scenario uses PlayerParam,
so that command is not implemented; the model exists for tests.

**CallNameChange.** It reads `callMyID`; -1 returns. Otherwise
`SaveData.FindCallFileData(personality, id)` gives the call-name bundle,
display name and voice file names
`namelist_[sp_]<personality:00>_<n:00>_<number:000>` for n = 0…2, where a
special name's number is offset by the list's smallest special ID. The source
sets `Vars` `callBundle` and `callName0`…`callName2`, the `callName` field,
`Vars["H_callName"]` and `Replaces["Pあだ名"]`.

**ParameterFile (201).** `ADV.Commands.Game.ParameterFile` has default `[""]`
and applies `ReplaceVars`. A known `scenarioParameterDic` name has its list
inserted at `CurrentLine + 1` (`CommandPacks.InsertRange`), so the inserted
commands run next and in order. A ParameterFile inside an inserted list
inserts after its own line, and an unknown name does nothing.
`commands` (`TextScenario.CommandPacks`) is the loaded program plus the
recorded `insertions` (pc, asset, count, request counter, batch); every pc in
states, requests and faults indexes `commands`.

**Tables and library.** `adv_character_tables.py` reads the private bundles
with UnityPy and the recovered `SaveData`, `NickName`, `VoiceInfo`,
`Manager.Voice`, `Manager.Game` and `CommonLib` sources. It reads 7
`etcetra/list/nickname` bundles (40 call-name lists, 8,200 names, 200 of them
special), 7 `etcetra/list/config` bundles (44 voice numbers) and the 2
`adv/scenario/common_param` bundles: **150 parameter programs, 236 commands**
(76 Calc → Clamp → HeroineParam, 72 empty, 2 others) and 0 duplicate names.
Bundles load in `Manager.Game.Awake`'s sorted order (`List.Sort`; these names
are ASCII digits), skipping `._*` AppleDouble files as the probe's mirror does.
`callDefaultID` is 203. It also derives `source-keys.json`, the key table
above, from the recovered source. Outputs stay in `.local/gt02-heroine-param/`:
`character-tables.json` SHA-256
`e78a0bae900752e31b16526fdfaa01dac878806f476b5c1fca1519bc826f81ce`,
`parameter-library.json`
`982a47ed0500fed0b51ed5ae1499c2fbc118d6d7c5e7124082b7bef214ba5e4d`,
`source-keys.json`
`2604858bebcd7890882c250ca96737743e46f67043c2186e5727b70b6bcb04f8`.

**Faults.** No bound heroine: `ADV command ID 165 at pc N: HeroineParam has no
bound current heroine (the source throws NullReferenceException)`. No library:
`ParameterFile has no bound Manager.Game.scenarioParameterDic`. Missing table:
`ADV character table not bound: …`. A definite source exception (missing
argument, missing call name, `NowCoordinate` index, conversion): `ADV character
source exception: …` or `Source ADV argument parse throws in
SaveData.Heroine.SetADVParam(<key>) …`.

**Persistence.** The interpreter encodes `insertions`, `replaces`, `character`
and `parameterLibrary`. `commands` is not stored; decoding replays each
insertion against the stored library and rejects any that do not match.
States saved before the bindings existed decode with no binding, library or
insertions. The gameplay host's snapshot schema is 2 and reads schema 1
([cycle.md](cycle.md#gameplay-host-a-t01)).

### Original-runtime probe (VM, read-only)

The VM install has no game save: `UserData\save\game` is empty, and the only
files under `UserData\save` are `checkitem.dat`, `checkitem.xml` and
`itemblacklist.xml`. A save-parse comparison is therefore impossible, and the
probe constructs the original new-game heroine instead.

`original_adv_binding_probe.py run` works in a fresh private root
`C:\Temp\IkkokuADVBindingProbe-<32 hex>`, one batched script per phase, and
checks the Parallels errno-24 count before each phase. The root is set up as
follows:

- copies of `Koikatu.exe`, `winhttp.dll`, `doorstop_config.ini` and
  `BepInEx\core`, with the console disabled and no `UserData` or other plug-ins;
- a junction to `Koikatu_Data`;
- an `abdata` mirror (4 directory junctions, 2,022 file symlinks, 440
  directories).

The mirror is needed because the installed `abdata` holds 2,465 AppleDouble
`._*` files in 439 directories. `CommonLib.GetAssetBundleNameListFromPath`
lists them, `AssetBundleManager` cannot open them, and the resulting
`NullReferenceException` aborts `Manager.Game.Awake`. An earlier run that used
the install's `abdata` directly reached the player but never saw a ready Game
(status `timeout`). The private roots remain in `C:\Temp`; deleting a tree that
holds junctions into the install was not risked.

Next, it compiles the probe against the install's managed DLLs and BepInEx
5.4.23.5, and checks the source hash first. It then starts the player in the
signed-in session (Unity 5.6.2f1, windowed, d3d11) and waits at most 600 s for
it to exit. Nothing in `C:\Illusion\Koikatsu` is written.

The plugin waits for `Manager.Game`/`Manager.Voice`. For each case it then:

1. builds `new SaveData.Heroine(false)`, an inactive `TextScenario`, and an
   `ADV.CharaData` whose `data` is that heroine;
2. calls `heroine.SetADVParam(scenario)`;
3. runs the program through `CommandList.Add` in the main loop's order
   (`currentLine++`, then `CurrentLine`);
4. dumps `Vars`, `Replaces`, the heroine's public int/bool/string fields and
   the final `CommandPacks` IDs.

It writes a TSV, sets `isGameEndCheck = false` and quits.

The run finished with status `ok`. The process exited with code 0xC0000005
during shutdown, after its outputs were written, and no Koikatu or CharaStudio
process remained (`tasklist`). The errno-24 count was 5 before every phase and
afterwards.

| Probe input | Count |
|---|---:|
| Named synthetic cases (seed, ParameterFile order and clamp, call-name normal/special/reset, unknown key, property key, Boolean/String fields, Int32 styles, bad Int32, replaced value, captured key) | 14 |
| `[VAR, ParameterFile]` prefixes of installed assets, loaded through `AssetBundleManager` | 78 |
| Library programs made only of VAR/Calc/Clamp/HeroineParam, run directly | 148 |
| The same programs run through one ParameterFile line | 148 |

The runtime facts equal the extracted inputs: `SaveData.callDefaultID` 203,
`Player.callID` 203, 44 `voiceInfoDic` entries, and 150
`scenarioParameterDic` programs whose count and command digest each equal
`parameter-library.json`. The runtime's heroine (58) and player (31) key
orders and commands equal `source-keys.json`.

`compare` runs every case natively through `ikkoku-inspect adv-trace`, with
the new-game heroine and the player at `callDefaultID`. It found **0
differences** in 388 cases: 20,268 variables (type and value; Single as
float32), 2,328 Replaces, 11,252 heroine fields (147 changed from the seed),
229 insertions with the final command lists, and the one exception (`bad-int`:
the original throws `FormatException` at line 0 and native faults at pc 0).
Five tampered copies of the probe output each produced exactly one issue: a
variable value, the key order, a removed exception, a field value and a
command list.

Hashes:

| Item | SHA-256 |
|---|---|
| Committed probe source | `30d5ef27380ece90dde51c222c8fd628c31f2919d857f665a5e9b0a43a209e76` |
| Uploaded probe source (comment-stripped) | `e4f5c4ad76d0662b1a240aed1e837f51e4017e95f6efebf34cf28e906e98e9f4` |
| `cases.tsv` | `807f3d4a2a3f09f0f50018e6a0cb384448bc98140fc6f0382a9a1a047c2a2f0c` |
| `adv-binding.tsv` | `58a82d9acc822debfe3ae17c303171a1ff91e81536a79693369ee9782e7c8db2` |
| Native report (`native-trace.report.json`, kept gzipped) | `54fa01f48a7029b1d116b80453419eb6e56ac02c32dea012a23cb16c5320dd92` |

Outputs stay in `.local/gt02-heroine-param/probe/`.

Limits:

- Only the new-game heroine is covered; no save exists.
- The probe calls `CommandList.Add` directly on an inactive scenario: there is
  no ADV scene, coroutine, frame timing or presentation.
- The asset prefixes stop after their first ParameterFile, whose library
  programs are empty in this install.
- The player's own Params are compared by key order only.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/adv_character_tables.py \
  --recovery-index .local/reverse/managed-recovery/index.json \
  --source-root .local/reverse/source/abdata --output .local/gt02-heroine-param
python3 Tools/reverse/original_adv_binding_probe.py run --vm 'Windows 11' --errno-baseline <count> \
  --output .local/gt02-heroine-param/probe --coverage .local/gt02-heroine-param/coverage
python3 Tools/reverse/original_adv_binding_probe.py compare --output .local/gt02-heroine-param/probe \
  --coverage .local/gt02-heroine-param/coverage \
  --inspect "$(swift build --package-path Packages/Engine --show-bin-path)/ikkoku-inspect"
```

## Concrete original-source execution

The original parameter asset `301` contains Calc → Clamp → HeroineParam on
`H_intimacy`. Before G-T02 native execution ran the first two records and
stopped at **pc 2, command ID 165**. With the new-game heroine bound (G-T02)
it runs to exhaustion. Calc adds the asset's amount to the seeded
`H_intimacy`, Clamp keeps the result in 0…100, and HeroineParam writes the
heroine's `intimacy` field and `Vars["H_intimacy"]`.

The final value is verified against two independent sources:

- the Python model (`adv_character_tables.library_effect`, written from the
  recovered Calc, Clamp and conversion code);
- the original runtime (probe cases `library:301` and `library-pf:301`, the
  second reaching it through ParameterFile), whose value, field and final
  command list equal native execution.

The gated sample's library check keeps the model comparison as a regression
test.

The value derives from an original argument and is not recorded here. Applying
the program twice through ParameterFile doubles the amount, and starting at 99
clamps to 100, in the original runtime and natively alike. The unbound
reference test (`IKKOKU_GAMEPLAY_EXECUTION_REFERENCE`) still expects the pc 2 /
165 fault with no character bound. This is a real original data path, not a
reconstructed dialogue or a playable NPC interaction.

## Original scenario command coverage (G-T03)

`Tools/reverse/analysis/adv_command_coverage.py` measures every `ScenarioData`
asset of the installed `abdata/adv/scenario` tree against the native kernel. It
reuses the contract tool's recovered-source selection and UnityPy extraction,
names ordinals from the recovered `ADV.Command` enum, and resolves the handler
class each `CommandList.CommandGet` arm constructs (enclosing `ADV` namespace
first, then exactly one `using` namespace, as C# does). It also checks that the
presentation model's handler classes and its `BGM`, `FadeType` and `NullSet.Type`
name tables match the recovered source. Outputs contain original arguments and
stay in ignored `.local/gt03-adv-coverage/` (scalar slice),
`.local/gt03b-adv-host-requests/` (host-request slice) and
`.local/gt02-heroine-param/coverage/` (bound rerun: `scan --character-tables
--parameter-library` binds the new-game heroine, the player at
`callDefaultID` and the parameter library); this page records aggregate counts
only.

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

**Implemented subset in real data.** With the host-request slice, 22
implemented ordinals occur in **239,612 of 294,393 records (81.4%)**; the scalar
slice alone covered 8 ordinals and 28,564 records (9.7%; None and Switch never
occur). The fourteen presentation ordinals account for 211,048 records: Text
63,122, Voice 31,165, Expression 19,901, CharaLookNeck 16,529, CharaLookEyes
15,907, Motion 14,535, SceneFade 12,106, CharaExpression 9,586, CharaMotion 8,407,
SceneFadeRegulate 5,687, NullSet 5,501, BGMPlay 3,205, NullLoad 2,982 and
MapChange 2,415. The other 98 ordinals (54,781 records) are unsupported natively.
Every used ordinal has an original `CommandGet` handler, so no original no-op is
mistaken for a fault. Inside implemented commands, 101 VAR records carry random
alternatives (native fault whenever executed) and 299 IF records name an external
`file:tag` branch (native fault only when that branch is taken); all 3,848 Jump
targets are local. Under default inputs, 312 presentation records (156
CharaExpression, 156 Expression) pass a character number that names an absent
host variable, a definite `int.Parse` exception in `Expression.Convert`; all lie
after an earlier halt. Another 1,072 presentation records name a variable that
their own asset assigns, so their outcome is value-dependent.

**Bound expansion (G-T02).** With the library bound, the static model inserts
each named library program after its ParameterFile line, recursively, as the
source does: 6,231 insertions in 5,798 assets add 9,159 records (**303,552
expanded records**), and no static halt lies inside an inserted record. On
that basis the 24 implemented ordinals cover **258,106 records (85.0%)**;
HeroineParam has 6,288 uses (3,365 written in the assets themselves) and
ParameterFile 6,243. The G-T02 columns below count expanded records.

**Static first unsupported command** (program order, ignoring values):

| First unsupported index | Scalar slice | Host-request slice | G-T02 (expanded) |
|---|---:|---:|---:|
| 0 | 9,569 | 1,724 | 1,724 |
| 1 | 436 | 848 | 770 |
| 2–4 | 366 | 1,844 | 1,846 |
| 5–9 | 0 | 1,255 | 752 |
| 10–19 | 4 | 1,347 | 321 |
| 20+ | 0 | 799 | 622 |
| none | 88 | 2,646 | 4,428 |

Records preceding their asset's first unsupported command rose from 1,360 (0.46%)
to **80,992 (27.5%)**. 2,646 assets contain no unsupported ordinal (the first
slice's greedy prediction for these fourteen commands was 2,646 and 80,992,
matched exactly by the rescan); 2,640 of them (2,566 non-empty) also have no
certain argument halt, the other 6 contain a VAR random alternative. With G-T02,
**88,363 expanded records (29.1%)** precede the first unsupported command and
**4,428 assets** (4,354 non-empty) contain no unsupported ordinal, 4,422 (4,348
non-empty) of them with no certain argument halt. The host-request slice's
greedy order predicted 4,352 assets for ParameterFile alone; HeroineParam's 76
sole-blocker assets make up the difference. Its 84,728-record prediction
counted unexpanded records and is not comparable. These are static ceilings:
value-dependent faults remain possible and every request still needs a host.

**Which command blocks first now (after G-T02).** Ranked by the number of
assets whose first unsupported command it is (the full ranking is in
`coverage.json`; expanded records). "Sole" counts assets for which it is the
only unsupported ordinal. In the host-request slice ParameterFile ranked first
(2,030 assets) and HeroineParam twelfth (92); both now have none.

| Rank | ID | Command | Recovered handler | Uses | Assets | First blocker | Sole |
|---:|---:|---|---|---:|---:|---:|---:|
| 1 | 43 | Fade | `ADV.Commands.Effect.Fade` | 6,827 | 2,833 | 1,649 | 405 |
| 2 | 38 | BGLoad | `ADV.Commands.Base.BackGroundLoad` | 2,383 | 1,938 | 1,235 | 30 |
| 3 | 120 | CharaVoicePlay | `ADV.Commands.Chara.VoicePlay` | 1,790 | 957 | 589 | 0 |
| 4 | 21 | Open | `ADV.Commands.Base.Open` | 2,869 | 2,197 | 464 | 464 |
| 5 | 51 | Filter | `ADV.Commands.Effect.Filter` | 457 | 455 | 452 | 0 |
| 6 | 107 | CharaMotionDefault | `ADV.Commands.Chara.MotionDefault` | 909 | 771 | 387 | 234 |
| 7 | 117 | CharaCoordinate | `ADV.Commands.Chara.Coordinate` | 1,354 | 1,309 | 296 | 139 |
| 8 | 162 | CharaEvent | `ADV.Commands.Game.CharaEvent` | 1,665 | 1,465 | 200 | 183 |
| 9 | 156 | CharaActive | `ADV.Commands.Game.CharaActive` | 1,842 | 481 | 117 | 73 |
| 10 | 39 | BGRelease | `ADV.Commands.Base.BackGroundRelease` | 1,594 | 1,588 | 105 | 0 |
| 11 | 193 | Prob | `ADV.Commands.Base.Prob` | 118 | 118 | 78 | 78 |
| 12 | 78 | CameraDefault | `ADV.Commands.Camera.SetDefault` | 119 | 117 | 76 | 0 |

Grouped by handler namespace (`Sound.BGM` still holds one unsupported ordinal):

| Namespace (`ADV.Commands.*`) | Used IDs | Unsupported IDs | Uses | Assets | First blocker |
|---|---:|---:|---:|---:|---:|
| `Effect` | 7 | 5 | 26,300 | 6,108 | 2,101 |
| `Base` | 31 | 17 | 179,924 | 10,004 | 1,956 |
| `Chara` | 35 | 31 | 65,381 | 9,268 | 1,432 |
| `Game` | 17 | 14 | 20,548 | 7,246 | 430 |
| `Camera` | 10 | 10 | 1,115 | 351 | 95 |
| `Sound.SE2D` | 2 | 2 | 523 | 268 | 9 |
| `CameraEffect` | 3 | 3 | 1,936 | 852 | 7 |
| `EventCG` | 3 | 3 | 3,673 | 970 | 4 |
| `Sound.BGM` | 2 | 1 | 3,220 | 3,008 | 1 |
| `H` | 7 | 7 | 837 | 378 | 0 |
| `Object` | 3 | 3 | 95 | 4 | 0 |

A greedy order that repeatedly implements the current most frequent first
blocker (static, by ordinal only, expanded records) reaches:

| After implementing | Assets with no unsupported ordinal | Records before first unsupported |
|---|---:|---:|
| (G-T02) | 4,428 | 88,363 |
| + Fade | 4,833 | 117,447 |
| + BGLoad | 4,863 | 130,878 |
| + CharaCoordinate, BGRelease | 5,904 | 155,742 |
| + Open | 6,706 | 157,167 |
| + CharaMotionDefault, CharaVoicePlay, CharaVoiceWait | 7,792 | 176,921 |
| + CharaEvent | 8,275 | 179,752 |

### Observed native halts and host requests

Every asset was run through `ikkoku-inspect adv-trace` with **default inputs**
(no host variables, a 1,000-second frame per batch completing any source Wait,
`commandCount + 4` frames) and a **scripted host**: every blocking request is
acknowledged after the frame that issued it (MapChange with no ADV variables),
and Next is pressed whenever a Text batch waits for it; `isSceneFadeRegulate`
starts true. The comparison checks each observed fault position, command ID and
reason against the static prediction (including argument halts), detects frames
that re-entered `RequestNextLine` through a local jump or ended at a
non-sequential pc, and checks the outcome against a static reachable-outcome set
that forks every IF branch and treats reachable Calc/Clamp/IF/Switch, VAR
dereferences and value-dependent presentation arguments as possible faults.

| Observed outcome | Scalar slice (no host) | Host-request slice (scripted host) | G-T02 (scripted host, bound heroine) |
|---|---:|---:|---:|
| Fault at the predicted index with the predicted ID and reason | 10,369 | 7,582 (7,573 unsupported ordinals, 9 VAR random alternatives) | 5,839 (5,830 unsupported ordinals, 9 VAR random alternatives) |
| Close or exhaustion where no halt was predicted | 87 (13 non-empty) | 2,594 (2,520 non-empty) | 4,331 (4,257 non-empty) |
| Exhaustion after an observed jump past the predicted halt | 0 | 39 | 39 |
| Value-dependent fault before the predicted index | 7 | 248 | 1 |
| A different unsupported halt after an observed jump | 0 | 0 | 161 |
| An IF/Switch that selected an external `file:tag` branch | 0 | 0 | 92 |
| Unexplained mismatch / outcome outside the reachable set | 0 / 0 | 0 / 0 | 0 / 0 |

**2,633 assets now run to completion** (2,559 non-empty, 25,892 records): 1,586
end at Close and 1,047 exhaust their records (74 of them empty). The 39
jump-past cases are one asset in each `c00`–`c38` directory whose local Jump
skips the predicted halting record. The 248 value-dependent faults are 247 IFs
whose left operand names a host variable that default inputs do not supply
(native rejects it as an extended IF literal; the game supplies the variable) and
one VAR dereferencing an absent host variable; 46 of them are in assets with no
static halt. Observed halts by unsupported command: ParameterFile 1,971, Fade
1,648, BGLoad 1,235, CharaVoicePlay 511, Filter 452, CharaMotionDefault 386,
CharaCoordinate 296, CharaEvent 155, Open 152, CharaActive 117, BGRelease 95,
HeroineParam 92, others 463.

**Requests.** The run issued **51,953 host requests in 8,134 assets** (text
15,692, charaLookNeck 8,668, charaLookEyes 8,599, sceneFade 3,850, charaMotion
3,433, charaExpression 3,317, nullSet 2,882, bgmPlay 2,594, nullLoad 1,496,
mapChange 1,422). Every request names the command at its pc and has the model's
kind and blocking policy, and **all 51,953 argument payloads equal the independent
Python decoding** (`adv_host_requests.py`, written from the recovered handlers and
Mono parsers; none was skipped as value-dependent). The 15,692 Text requests
carry 10,022 voice, 6,210 expression and 5,100 motion binding lists, each equal to
the model's `CurrentCharaData` reconstruction for its batch. For 9,926
straight-line assets (7,725 with at least one request, 48,898 requests) the
complete request sequence (IDs, pcs, batch numbers, policies and arguments)
equals the model's prediction. Native execution totalled 87,366 instructions.

**Bound rerun (G-T02).** The same run with the new-game heroine, the player
at `callDefaultID`, the extracted tables and the parameter library (`traces`
carry a per-case `character`; report schema 3 adds `replaces` and `heroine`):

- **4,370 assets run to completion** (4,296 non-empty; 3,247 end at Close and
  1,123 exhaust their records), up from 2,633.
- ParameterFile ran **2,030 times and inserted 3,351 commands**, with 0 replay
  failures from saved states. For the 9,881 straight-line assets that end as
  predicted, the observed insertions equal the static expansion (9,881/9,881,
  1,913 non-empty). The final heroine fields equal the Python
  parameter-program model (9,881/9,881, 852 changed).
- With the seeded `H_` variables, IFs that faulted on an absent host variable
  now evaluate, and value-dependent faults fall from 248 to 1, a VAR
  dereferencing an absent host variable. Instead, 161 assets reach a different
  unsupported halt after an observed jump and 92 select an external
  `file:tag` branch, which native execution faults on as unsupported. All are
  statically reachable outcomes.
- **52,146 host requests in 8,136 assets** (text 15,762, charaLookNeck 8,672,
  charaLookEyes 8,603, sceneFade 3,868, charaMotion 3,436, charaExpression
  3,403, nullSet 2,886, bgmPlay 2,594, nullLoad 1,498, mapChange 1,424). All
  argument payloads equal the Python decoding. 9,881 complete request
  sequences (7,680 non-empty, 48,224 requests) equal the prediction, with 0
  request mismatches.
- Native execution totalled 93,517 instructions.
- Observed halts by unsupported command: Fade 1,649, BGLoad 1,239,
  CharaVoicePlay 589, Filter 452, Open 422, CharaMotionDefault 387,
  CharaCoordinate 296, CharaEvent 194, CharaActive 117, BGRelease 105,
  others 541.

Two tampered traces each produce the expected single issue: an altered
insertion is unexplained, and an altered heroine field is a heroine mismatch.

**Sample regression.** `sample.json` is a deterministic stratified sample chosen
from static properties only: 36 assets (first-command 6, scalar prefix 5,
value-dependent prefix 3, taken-branch-possible prefix 6, other control flow 3,
argument limit 5, executable 4, request sequence 3, empty 1). The gated Engine
test `sourceADVCoverageSampleHaltsAtPredictedSourceIndex` runs each with the same
default inputs and scripted host, requires every outcome to be statically
reachable, requires the exact predicted pc, ID and reason for the 22
straight-line cases and their native request sequences (91 requests in 12
sequences) to equal the Python prediction, and runs 11 mutation controls that
replace the halting record with None. Three fully executed request-sequence
assets issue 10–14 requests each across 11–15 batches (Text, SceneFade, look,
expression and motion requests in all three; one also MapChange, NullLoad and
NullSet). A deliberately
corrupted sample (one argument, one blocking policy, one halt reason) fails the
test with exactly 3 issues.

The G-T02 sample (`.local/gt02-heroine-param/coverage/sample.json`, SHA-256
`dfaaa33496eae54218b682e05d504f7230595f60d561a82df1ee8bb2f83b5e5a`, schema 3)
has 44 assets: parameter-file 8, first-command 6, branch-before 6, scalar
prefix 5, argument limit 5, executable 4, value-dependent prefix 3, control
flow before 3, request sequence 3, empty 1. The gated test
`sourceADVCharacterSampleRunsBoundOriginalScenarios`
(`IKKOKU_ADV_CHARACTER_SAMPLE`) checks:

- the native key table against `source-keys.json` (names, commands,
  writability, members) and every writable heroine key's new-game value;
- for the 30 exact cases, their halts, 9 predicted insertions, 4 expected
  heroine changes and 184 requests in 20 sequences, plus 30 None-mutation
  controls;
- all 76 Calc/Clamp/HeroineParam library programs, each run directly and
  through one ParameterFile line, against the Python model.

The host-request sample still passes unchanged. A copy of the G-T02 sample
with three corruptions (an insertion count, one expected heroine value, one
library value) fails with 7 issues.

```sh
python3 Tools/reverse/vm_source.py --vm 'Windows 11' --output .local/reverse \
  fetch abdata/adv/scenario/<dir>/<bundle>.unity3d   # all 225 listed bundles
swift build --package-path Packages/Engine --product ikkoku-inspect
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/adv_command_coverage.py scan \
  --recovery-index .local/reverse/managed-recovery/index.json \
  --scenario-root .local/reverse/source/abdata/adv/scenario --output .local/gt03b-adv-host-requests
for f in .local/gt03b-adv-host-requests/traces/trace-[0-9][0-9][0-9].json; do
  "$(swift build --package-path Packages/Engine --show-bin-path)/ikkoku-inspect" adv-trace "$PWD/$f" \
    > "${f%.json}.report.json"
done
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/adv_command_coverage.py compare \
  --output .local/gt03b-adv-host-requests
IKKOKU_ADV_COVERAGE_SAMPLE="$PWD/.local/gt03b-adv-host-requests/sample.json" \
  swift test --package-path Packages/Engine --filter sourceADVCoverage
# G-T02 bound rerun (tables from adv_character_tables.py, see Character bindings)
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/adv_command_coverage.py scan \
  --recovery-index .local/reverse/managed-recovery/index.json \
  --scenario-root .local/reverse/source/abdata/adv/scenario --output .local/gt02-heroine-param/coverage \
  --character-tables .local/gt02-heroine-param/character-tables.json \
  --parameter-library .local/gt02-heroine-param/parameter-library.json
for f in .local/gt02-heroine-param/coverage/traces/trace-[0-9][0-9][0-9].json; do
  "$(swift build --package-path Packages/Engine --show-bin-path)/ikkoku-inspect" adv-trace "$PWD/$f" \
    > "${f%.json}.report.json"
done
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/adv_command_coverage.py compare \
  --output .local/gt02-heroine-param/coverage
IKKOKU_ADV_CHARACTER_SAMPLE="$PWD/.local/gt02-heroine-param/coverage/sample.json" \
  swift test --package-path Packages/Engine --filter sourceADVCharacterSample
```

Base and namespace asset counts overlap; they are not additive. Exclusions: the
static prediction ignores values and host state; the scripted host never fails a
request, supplies no MapChange variables and presses Next as soon as it is
accepted, so these runs exercise the interpreter, not presentation; the dynamic
run starts every asset at pc 0 although the game can open a file at a tag; the
corpus is this installation's `abdata/adv/scenario` only (no mod or other
scenario roots). The bound rerun uses only the new-game heroine. Apart from the
[binding probe](#original-runtime-probe-vm-read-only), no original game run was
captured for comparison.

## Verification and reproduction

The focused native run (`swift test --filter 'sourceFixedEvent|sourceADV|sourceCLR'`)
has 30 tests, including the G-T02 gated sample test. Thirteen cover scheduler
behavior, command batching, waits, arithmetic, type-sensitive comparisons, fault positions, loop budgets, float
interchange, the original parameter scenario and the coverage sample; sixteen in
`SourceADVHostRequestTests.swift` cover the Mono parsers, every presentation
command's defaults and argument forms, invalid and unmodelled forms, blocking
(Text/Next, the MapChange gate freezing Waits and ignoring Next, SceneFade with
and without `isSceneFadeRegulate`), request order inside `Multi` batches, Text
bindings across advances and jumps, host failure, JSON round trips and
save/restore mid-wait, mid-acknowledgement and mid-Next.

G-T02 adds 18 tests in `SourceADVCharacterBindingTests.swift` (filter
`'sourceCharacterKeyTables|sourceCharacterDefaults|sourceConvertToInt32|sourceHeroine|sourcePlayerSetADVParam|sourceParameterFile|sourceOriginalParameterShape|sourceBoundInterpreter|sourceInterpreterStateFromBefore|sourceADVCharacter'`):

- the key tables (58/29 and 31/13, Replace keys, members) and the new-game
  defaults;
- Mono-styled Int32 conversion;
- the seed against `SetADVParam(scenario)`, getter side effects and branches,
  and named missing-table faults;
- every key's HeroineParam read, convert and write path (fields change,
  properties change only `Vars`);
- the captured key with the replaced value, the unknown-key no-op, the
  source faults and the `H_callID` → CallNameChange path (normal, special and
  reset IDs);
- the PlayerParam model;
- ParameterFile insertion order, nesting and the unknown asset, and its
  unsupported fault without a library;
- the original 301 shape with a synthetic amount;
- save and restore mid-scenario (after an insertion, mid-wait) and
  pre-binding state decoding;
- the gated `IKKOKU_ADV_CHARACTER_SAMPLE` test.

Python: twelve contract tests, twelve `test_adv_host_requests.py` tests
(parsers, handlers, request prediction), 35 `test_adv_command_coverage.py`
tests (static halts, argument limits, reachability, request checks, sample
selection, and since G-T02 static ParameterFile expansion, the bound
comparison and its tampered controls), five `test_adv_character_tables.py`
tests (key derivation from a hand-written `SaveData` shape, Int32 styles,
parameter-program effects, table extraction order) and twelve
`test_original_adv_binding_probe.py` tests (case encoding, exec splitting and
limits, retry and errno guards, the fresh-root rule, TSV parsing and value
comparison). All expected values in these tests are derived by hand from the
recovered source; all strings are synthetic.

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
and contexts. An ADV request supplies a program, optional typed variables,
explicit frame durations/Next inputs and per-frame `acknowledge` lists, or the
scripted host options (`autoAcknowledge`, `autoNext`, `mapVariables`,
`sceneFadeRegulate`, `requestDetail`). Since G-T02 a case may add a
`character` (`heroine`, optional `player`; missing members keep the new-game
defaults) and the collection a `characterTablesPath` and
`parameterLibraryPath` (relative to the input file), and `variableDetail`
`changes` reports only variables that changed since the previous frame.
Report schema 2 added per-frame `batch`, `awaitingNext`, `pending`, the
requests drained in that frame and the IDs acknowledged after it. Schema 3
adds per-frame `commandCount` and new `insertions`, and per-case `replaces`
and `heroine` for bound cases. Reports show computed selections or state snapshots, not
the reference expectations embedded in the input file.

## Pending integration

1. The engine session host (`G-T01`, [effect inventory](cycle.md#session-host-and-effect-inventory-g-t01))
   holds cycle transitions on acknowledged barriers and persists in-flight
   cycle state. The first slice of the [gameplay host](cycle.md#gameplay-host-a-t01)
   (`A-T01`) acknowledges period barriers from its own state, runs the selected
   fixed event's `SourceADVInterpreter` one frame per step and saves it with the
   session in one snapshot. It performs MapChange without a fade (a catalog map
   load, acknowledged with no `Cycle.ADVVariables`) and rejects every other
   request, because nothing is presented. A presentation host for the other
   requests remains.
2. Source player/heroine bindings (`G-T02`) are done for the new-game heroine:
   [character bindings](#character-bindings-g-t02), `HeroineParam`,
   `ParameterFile`, original scenario 301 with source-verified values, and the
   A-T01 scenario's fixed event run once across four reloads with its own
   asset ID. Remaining:
   - the ADV start's transfer list (`Program.SetParam` →
     `Heroine.SetADVParam(list)`, which also queues a `HeroineCallNameChange`
     command);
   - `PlayerParam`, `CharaChange` and `CharaEvent` (talk events);
   - an original fixed-event asset in the host;
   - real save data (none exists in the VM install).
3. Expand the VM by command family in the measured order above (`G-T03`); the
   inventory, halting check and the first fourteen presentation commands as host
   requests are done. Next: Fade, BGLoad/BGRelease, Filter, CharaCoordinate,
   CharaMotionDefault and CharaVoicePlay/Wait as further requests; then
   cross-file resolution (Open, external IF branches), choices and tasks. A real
   host must consume the requests (G-T01/A-T01) before any of this is visible;
   test cancellation, skip, interruption and save/reload at every wait.
4. Recover one neutral map/NPC route and its action/navigation/behavior-tree data
   (`G-T04`). Compare numeric decisions/positions with source traces, including
   interaction interruption and resumed movement.

The installed source corpus is broader than this implemented subset. Report
discovered, decoded, executed and host-integrated command coverage separately:
an asset that runs to completion against the scripted host has had its requests
decoded and sequenced, not presented, and stopping at an explicit unsupported
command is not scenario completion.
