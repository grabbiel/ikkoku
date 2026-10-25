# Installed native plugin adapters

Reviewed 2026-10-24. The registry contains three exact installed revisions with
bounded Swift behavior adapters. The two earlier adapters have accepted startup,
native scene restoration and mixed-library app coverage. The HideAllUI section
below distinguishes its original-player evidence from its native acceptance
status. Source accessory labels are wired into the reachable Clothes inspector;
that wiring is distinct from a visible comparison of the displayed labels.
See [library app acceptance](plugin-execution.md#saved-scenes-and-migration) and
[A-T04 / P-T03](../../component-audit/app-gameplay-and-plugins.md) for the bounded
checks and remaining work. No general installed-plugin compatibility is implied.

## Conversion and identity

The conversion CLI recognizes three exact installed DLLs by their complete SHA-256 hashes
and publishes native adapter packages automatically. Run from the repository root:

```sh
python3 Tools/translation/plugin.py path/to/BepInEx.MuteInBackground.dll \
  --type BepInEx.MuteInBackground --config path/to/BepInEx.MuteInBackground.cfg \
  --output .local/plugins/mute-original
python3 Tools/translation/plugin.py path/to/KK_StudioAccessoryNames.dll \
  --type KK_StudioAccessoryNames.KK_StudioAccessoryNames \
  --output .local/plugins/accessory-names-original
```

The app exposes **Mods → Load Converted Original Plugin…** for each `manifest.json`.
Environment mounts and saved-scene restores passed Release verification below.
The Studio Plugins library panel also has visible selection, mount, pause and
unload acceptance; this does not establish the separate legacy manifest dialog
workflow. The package retains original assembly and
configuration bytes, GUID, version, type and process restrictions. The DLL is identity evidence; the Swift adapter
implements the recovered behavior. A different DLL revision requires its own
verified adapter, or passes through the strict C# translator. Rejected conversion
never publishes a loadable manifest. Existing package directories are immutable.

The persistence model stores enabled mounts and package hashes in native scene
cards. Its restore code validates the entire package, including original config
bytes, before applying it; package tests cover the saved references. The actual
release mount/save/reload/continue test passed for both exact adapter packages. New-scene and
original-scene-import code retain current global mount references. The accessory
label consumer is enabled only by its mount and is used by the source Clothes
inspector.
Adapter mounts do not alter card/mod GUIDs, source object keys, source KKEx payloads or original config files. These global
plugin/config references belong to native scene metadata; original scene export
does not inject them into an unrelated KKEx field.

`IKKOKU_NATIVE_PLUGIN_MANIFEST` requests one package mount for capture;
`IKKOKU_NATIVE_PLUGIN_MANIFESTS` accepts a JSON array of manifest paths. The native
package tests check real installed assemblies, identity persistence and rejection
of changed assembly/config/manifest bytes. `test_native_adapters.py` verifies the
automatic CLI route against the same originals without invoking a decompiler or
executing the assemblies. Set `IKKOKU_NATIVE_PLUGIN_PACKAGES` to the private fixture
package directory to enable those source-backed checks. They are separate from
actual app startup and UI verification. The capture-only focus variables are
described under [startup and acceptance](#startup-and-acceptance).

The registry requires these exact assembly identities:

| Adapter | Original DLL SHA-256 |
| --- | --- |
| `bepinex-mute-in-background-v1` | `e494f24b73fed491d056c3c6a00ee73baf257409877ce8e5b44da1b0494ca96d` |
| `kk-studio-accessory-names-v1` | `c60d740ee1037040e97bcb0ae8037f8f7a1e4350322bc7ed44699fd0dc9662bd` |
| `kk-hide-studio-ui-v1` | `ec11d03060502b60bf15742ef8e56b6bc804c10067e5a78ba368c7b62e3b117e` |

The retained 2026-09-25 evidence reports three native package tests and one
original-fixture Python packaging test passing. This documentation revision did
not rerun them. Missing fixture variables skip the original-assembly comparison.

The [plugin library](plugin-execution.md#plugin-library) indexes adapter packages
as `ikkoku-native-plugin-adapter` revisions. Its initial synthetic coverage has
since been extended with mixed-library app mount/save/fresh-process restoration
and visible panel acceptance. Its scanner accepts an adapter manifest only when the
source digest is in this registry and the adapter ID, type, identity and process
list are identical. The scanner never runs the assembly.

The original two adapter manifests declare no BepInEx dependencies or
incompatibilities. HideAllUI retains its exact `HideStudioUI` and `HideHInterface`
incompatibilities in both the manifest and mixed plugin graph. All three declare
no BepInEx dependencies. A translated package may depend on an adapter GUID with
a minimum version, but these adapters themselves require nothing. If a registered plugin declares
dependencies, the registry must record them first.

Library selections verify adapter packages through `SourceNativePluginPackage.load`.
Stand-in assembly bytes fail with a `revisionInvalid` error that names the
revision. The app supports individual manifest mounts with `sourceNativePlugins`
references and pinned mixed-library selections with their exact revision hashes.
The accepted two-adapter/IR fixture restores an older library generation with a
newer generation available, without upgrading the saved selection. See
[plugin library](plugin-execution.md#plugin-library) for staged replacement,
rollback and cancellation guarantees.

## Startup and acceptance

SwiftUI constructs `AppState` before launching finishes. Environment and
capture mounts, and saved-scene restores in `captureScene`, all run inside that
initializer. On macOS 26 `NSApplication` did not exist yet. On macOS 27.0.1
(Swift 6.4) it already exists there and reports `isRunning`, but `isActive` is
false and `NSRunningApplication.current.isFinishedLaunching` is false until
`didFinishLaunching` (checked 2026-10-23 with a minimal SwiftUI app). The Mute mount used to read `NSApp.isActive` there, so the private
`.local/reverse/plugin-execution/native-adapter-capture-01` run terminated with
SIGTRAP before capture; `Ikkoku-2026-09-25-071053.ips` identifies that method.

`StudioModel.mountSourceFocusAdapter` now owns the adapter and its single pair of
become/resign-active observers. Every remount replaces the pair and unmounting
removes it. `SourceApplicationFocusHost` restores the replaced adapter's saved
volume first, as before. It then delivers the initial focus sample immediately
when `NSApp` exists and launching has finished
(`NSRunningApplication.current.isFinishedLaunching`). Otherwise it delivers the
sample once, at `NSApplication.didFinishLaunchingNotification`. Until
2026-10-23 the test was only `NSApp != nil`. On macOS 27 that sampled the
not-yet-active app during `AppState.init`, so an enabled Mute stored and zeroed
the gain before any real focus event (see the rerun below). A real focus change supersedes a
pending sample, so a duplicate startup loss cannot store zero through the
repeated-loss quirk. `sourceMuteFocusHostDefersInitialFocusOnceAndRestoresReplacedAdapter`
covers this state machine.

Headless captures exit before launch finishes, so two capture-only variables
provide focus evidence. `IKKOKU_APPLICATION_FOCUS=0,1` delivers up to 64 focus
losses (`0`) and gains (`1`) through the same method as the AppKit observers; it
requires a mounted Mute adapter. `IKKOKU_NATIVE_PLUGIN_REPORT=/path/report.json`
records the mounted package references, whether `NSApplication` existed and
whether launching had finished (`launchFinished`), the observer count and the
pending initial sample. After each event it also records
master and voice gain plus the RMS of a generated 440 Hz tone rendered offline
through the app's voice and master mixers. Tone capture refuses running audio
output and returns the bus to realtime mode with its gains unchanged. Startup
rejects either variable without `IKKOKU_AUTOCAPTURE` (an app or native-scene
capture), so a run that requests the report always exits, nonzero if the report
fails (A06; see [capture request validation](../../guides/build-and-test.md#capture-request-validation)).

ST-T02/A-T04 acceptance is the release probe with both packages and the IR fixture:

```sh
python3 Tools/translation/studio_execution_probe.py \
  --executable .local/build/Build/Products/Release/Ikkoku.app/Contents/MacOS/Ikkoku \
  --scene /absolute/path/to/controlled-clothed-scene.png \
  --environment /absolute/path/to/capture-environment.json \
  --manifest /absolute/path/to/StudioMotionFixture/manifest.json \
  --native-manifest .local/plugins/mute-original/manifest.json \
  --native-manifest .local/plugins/accessory-names-original/manifest.json \
  --mute-oracle .local/reverse/plugin-execution/mute-oracle/reference.json \
  --mute-oracle-sha256 96f53bdc11af45619c32bbd25b4eececfd98d02154e3413015fbf337f2b8ab41 \
  --output .local/reverse/plugin-execution/native-adapter-capture-02
```

The run phase mounts both packages; reload and continue restore them from the
saved native scene. Each phase must exit zero and delivers `--focus-events`
(default `0,1`). The probe fails in each of these cases:

- manifest hashes, identities or the Mute setting change between phases;
- a phase has anything other than one observer pair;
- the initial sample was taken before launching finished (`launchFinished`
  false while no sample is pending; until 2026-10-23 the probe checked only
  that `NSApplication` existed, which macOS 27 always satisfies);
- master, voice or tone gain differs from Mute 1.1;
- reload pixels change.

The installed configuration is disabled, so focus loss must leave gain unchanged.
Add `--mute-config` with an enabled copy of the configuration to check audible
muting through the app bus. The probe passes it as `IKKOKU_MUTE_BACKGROUND_CONFIG`,
which remounts the adapter with that configuration after the package mounts.
Saved package references keep the original configuration. `test_studio_execution_probe.py` tests these report rules without
launching the app. The acceptance below closes ST-T02/A-T04 for its recorded revision.

Mute probe runs now require an independently reviewed config-reader oracle and
its exact SHA-256 before launching any process. The effective configuration bytes
come from `--mute-config`, otherwise the hash-verified package configuration,
otherwise the absent-config default represented by empty bytes. An override in
the environment map must instead be supplied explicitly through `--mute-config`.
The bytes must match exactly one input/result pair in the pinned original
BepInEx reader record. Missing/ambiguous inputs, reader errors, malformed results
and changed hashes reject; the tool does not implement another config parser.
The retained oracle above covers 23 original-reader cases. An enabled override
must use an exact covered input, or a separately reviewed oracle must first be
produced for its different bytes. Original binaries and input bytes stay private.

Each phase's mount and final setting must equal that independent Boolean, and
focus/gain expectations use it rather than the app's reported value. The final
report records the expected setting, configuration origin/hash and oracle
case/hash. Package references remain distinct from capture-only overrides.
Manifest/config/oracle pins are checked around every process; this detects
observed input changes but does not lock files against concurrent writers.
IR-only and other-adapter probes need no Mute oracle. It adds no app or frame-path
work, and does not extend live config watching, observer lifetime or Unity audio
coverage.

The 2026-10-24 acceptance at tool commit `a3533d5` passed 19/19 focused Python
tests, with no skipped cases. Six separate controlled observations demonstrate
that the prior checker accepted a self-consistent opposite setting and the new
checker rejects it: both Boolean directions in run, reload and continue. Two
additional offline checks match the exact installed and enabled input bytes to
the retained original-reader results. No original code was re-executed for this
acceptance.

Two run/save/fresh-reload/continue sequences then passed on the unchanged Release
executable `a36b625b…`, built from `2a257b9`. All six app processes exited zero.
The installed package config (`12e0ef12…`, expected false) kept master volume at
1 and tone RMS at 0.125052124 in every phase. The exact oracle `true` input
(`bd633b07…`, capture override) produced master volume 1 → 0 → 1 and tone RMS
0.125052124 → 0 → 0.125052124 in every phase. Voice gain stayed at 1; each phase
retained one focus-observer pair. Both sequences preserved the original package
references and source key/native UUID across save/reload, had identical reload
pixels, kept Start at 1 and continued the IR clock to approximately 2 seconds.
The source animation clock was held at 0 throughout; this does not establish
general animation-clock persistence. The override was reapplied in every phase;
saved package references still point to the original disabled configuration.

Root independently verified 38 retained artifact hashes, all six raw adapter
reports and both byte-identical reload PNG pairs. This closes the requested-setting
checker gap noted during PR #2 review. Raw
logs, pinned inputs, six-process cleanup, reports and old/new checker controls
remain private under `mute-config-oracle/python-1` and `mute-config-oracle/app-1`.
No GUI interaction, physical audio output, new adapter behavior or comparative
performance claim is added.

## Verified Release acceptance

On 2026-09-25, [PR #2](https://github.com/grabbiel/ikkoku/pull/2) head `93e6b06`
was built and reviewed in an isolated Apple Silicon checkout (Xcode 26.0.1).
Merge `aa4bcb9` has the identical source tree. Private evidence is retained at
`.local/reverse/plugin-execution/accepted-pr-2/`:

- `installed-config/report.json` and `enabled-config/report.json`: both original
  packages plus the IR motion fixture complete run/save/reload/continue; original
  manifests/settings and object identity remain intact, reload frames are identical,
  Start stays 1, continuation reaches approximately 2 seconds and each mount has
  two focus observers while `NSApp` is absent.
- Disabled gain remains 1. Independently checked enabled master gain is 1 → 0 → 1,
  tone RMS 0.125052124 → 0 → 0.125052124, and voice gain is unchanged in all phases.
- Seven Swift checks passed with original Mute/package fixtures explicitly set;
  six new Python report checks and the original-package Python check passed.
- `gui-smoke.json`: actual Release GUI launch with enabled Mute and both packages
  survives five OS activation changes and exits normally. This measures launch/
  focus stability; audio gains were measured by the separate headless tone probes.

That historical run did not establish accessory-label UI integration or live
config watching. The current Clothes inspector wiring is described below; live
config watching and broader observer/timer lifetime work remain separate. No
complete plugin or original Studio parity is implied.

## Local rerun on macOS 27 (2026-10-23)

The handoff's L3 task reran the probe above on the reference Mac (macOS 27.0.1
`26A434`, Xcode 27.0 `27A266a`, Swift 6.4), with the Release app built
`ARCHS=arm64` and signed, both original adapter manifests from
`.local/reverse/plugin-execution/packages/` and the IR motion fixture. The
private `capture-environment.json` held no capture option, so it was not edited.
The enabled run used `mute-enabled.cfg`, the installed configuration with
`Mute In Background = true` (SHA-256 `ec34c90c…`). PR #2's enabled copy was not
retained.

`native-adapter-capture-03`, `claude/local-wave-verify` at `0501cf1` (main
`b0b8cb6`), executable SHA-256 `3c578d90…`, **failed**:

- installed-config: probe exit 0;
- enabled-config: probe exit 1, `run: generated tone is silent before focus
  events`. Every phase reported `applicationCreated: true` (PR #2: false). The
  mount showed no pending initial sample, and master gain and tone RMS were 0
  before the first scripted event, after the loss and after the gain.

The cause is the startup order described under
[Startup and acceptance](#startup-and-acceptance). A minimal SwiftUI app on this
Mac printed `NSApp=true isRunning=true isActive=false finishedLaunching=false`
from a `@State` initializer and `finishedLaunching=true` at
`didFinishLaunching`. The mount therefore delivered the initial sample during
`AppState.init`, as an inactive app. With Mute enabled that zeroed the gain, the
first scripted loss stored zero through the 1.1 repeated-loss quirk, and the
gain restored zero. The installed (disabled) configuration hides this, because
a disabled Mute never changes the gain. The old probe rule, "sampled before
`NSApplication` existed", cannot fail on macOS 27. The probe now checks
`launchFinished`. Its unit test adds a report shaped like capture-03's
(`applicationCreated` true, no pending sample, launching not finished): the new
probe rejects it, and the old probe accepted it.

`native-adapter-capture-04`, `claude/a-t04-launch-focus` at `a031b50` (main
`d9684e8`), executable SHA-256 `13d1799a…`, with the fix:

- installed-config: probe exit 0. In every phase the mount reports
  `applicationCreated: true`, `launchFinished: false`, and the initial sample
  pending behind the launch observer, the same mount and final states as PR #2.
  Master and voice gain stay 1, and the tone RMS stays 0.125052124 through the
  loss and the gain.
- enabled-config: probe exit 0, with the same mount states. In each of run,
  reload and continue, master gain went 1 → 0 → 1 and tone RMS 0.125052124 → 0 →
  0.125052124 across the loss and the gain, voice gain stayed 1, and the
  report's `muteConfigSHA256` is the configuration passed. Reload pixels were
  identical, Start stayed 1 and continuation reached 1.9999994 s, as in PR #2.
  The first enabled attempt was terminated (exit 143) when app launches were
  paused for an interactive session; the rerun at 12:18 is the result.

A separate comparison against `accepted-pr-2/` derives the requested Mute
setting from the bytes of each configuration file, because the probe trusts the
report's effective setting. It compares each phase's mount and final
`enabled`, gains, tone RMS and focus trace with the accepted reports. It also
checks pixel identity, Start count, elapsed time, object key, scene and package
hashes, and adapter identities. PR #2's `applicationCreated: false` is a macOS 26
fact, so in its place the comparison requires the deferred sample at mount. For
capture-04 it passed all 89 checks across the two configurations. Evidence:
`.local/reverse/plugin-execution/native-adapter-capture-03` and `-04`, with
the commands and the comparison in `.local/local-wave-verify/l3/`.

## Accessory label UI integration

The source Clothes inspector now calls `StudioModel.sourceAccessoryLabels(for:)`
and exposes each of its twenty rows as `studio.source.accessory.<slot>`. Saved
nonempty slots use the existing visibility toggles; empty slots show a
noninteractive label. A saved slot with a missing conversion retains its toggle
and numbered fallback label, even though it has no rendered accessory mesh. Mounting the adapter selects the recovered label pass, using resolved
source names without changing source identities. The earlier placeholder no
longer blocks this inspector.

The 2026-10-24 visible check on the Release executable below used the actual
converted-manifest command: slot 0 changed from `スロット01` to `01 スクエア`.
Hiding that accessory retained its label, and choosing outfit 2 retained the label
and hidden flag. File → Save Scene wrote a new native scene; a fresh process with
no startup mount used File → Open Scene and restored outfit 2, the mounted label
and hidden flag. Slots 1–19 displayed `スロット02` through `スロット20` as
noninteractive text. Both owned processes exited normally.

This fixture uses the same glasses in every outfit, so it does not establish
distinct-name outfit switching. Missing-conversion fallback is covered by the
automated phase below, not by this GUI run. A direct converted-manifest mount saves
`sourceNativePlugins` without `sourcePluginLibrary`; that GUI build's Studio
Plugins panel therefore omitted its mounted summary and Unload control. Visible
unload is not claimed for that run. The mounted-panel follow-up now presents
individual references separately from library generations and delegates its
guarded Unload to the existing model method. Its clean Release `71e1309` passed
42 plugin/session checks and the extended 18-step save/9-step fresh-load pair,
including exact native identity and fallback labels after unloading. Visible
acceptance on that binary opened the retained GUI-save scene, showed its exact
individual-plugin identity without a generation, disabled Run for the native-only
mount and enabled Unload. Maker disabled both actions; switching back to Studio
and unloading restored `スロット01`, visibility off and outfit 2. The same run also
checked profile-only Pause/Run and Unload. Mixed origins and pending ownership
remain automated coverage; this does not relabel the earlier GUI run as having
an Unload control.
Unicode edge cases remain recovered-code oracle
coverage rather than displayed fixture observations.

The `studio-scenarios` lane has a bounded accessory-label checklist:
`reload-save-accessory-labels`, `reload-load-accessory-labels` and
`accessory-labels-missing`. The save phase uses the real mount/unload methods,
checks all twenty labels as UTF-8 bytes, retains the label when a converted accessory
is hidden, changes outfit, and saves a native scene. The fresh process has no
source import or startup adapter mount; it restores the saved package reference,
labels, outfit and visibility state. The missing-selection phase restores its
original outfit and requires byte-identical original export before reimport.
The lane maps `IKKOKU_ACCESSORY_NAMES_MANIFEST` to the exact adapter package's
`manifest.json`; its missing-file check is distinct from the package identity
validation performed by the app. Release verification at `6ddb1ea` passes
17 save/mount checks and seven fresh-process checks. The corrected missing-slot
scenario passes ten checks on the same executable (SHA-256
`3885d66f5452b0111735e2e804fbd68942cae7f24289dcc059997f0ffebada29`).
All twenty rows match exactly, saved and restored package references are identical,
and the original export is byte-identical. The initial missing-slot run passed
8/10: its expectation confused saved slot metadata with converted geometry.
The corrected check requires saved slot 0, zero rendered accessories and the same
fallback label; no runtime behavior or comparison was weakened. The first report
is retained. A private report-summary parser failure after the passing app exit
was corrected offline; no app rerun was attributed to that parser correction.
Both focused Engine tests executed, including the recovered-code oracle, with
zero skips; 83 runner tests passed. The displayed-label check above used the same
executable; no runtime label-generation change or cache was added.

`measureAccessoryLabels` records the first timed call and repeated warm calls to
`sourceAccessoryLabels(for:)`, with a fixed 100–2,000-call bound. Every returned
label is consumed and checked outside the timed interval. The measurement also
checks document bytes, preview identity, resource counts, animation time and
selected frame fields for unintended changes. It measures synchronous label
construction, excluding package load, frame refresh, SwiftUI layout/display and
GPU completion. The first sample is not a cold asset-load measurement. No cache
or runtime behavior change is inferred from the presence of this checklist.
Functional runs observed warm call medians around 0.052–0.074 ms; these were not a
quiet performance comparison and do not establish UI latency. No caching change
was justified by this bounded diagnostic.

## BepInEx.MuteInBackground 1.1

`SourceMuteInBackgroundPlugin` preserves the installed GUID/version, configuration section/key and recovered focus callback behavior. The native host connects `AudioListener.volume` to `SourceStudioAudioBus.masterVolume`, leaving PCM and personality/per-voice gains intact. Repeated focus loss deliberately preserves the original 1.1 quirk: the second loss replaces the stored volume with zero. Focus gain restores the stored value even if the setting was disabled while unfocused.

Initial configuration import matches the installed BepInEx reader: ordinal section/key matching, last unbound duplicate wins, malformed final boolean falls back to the default `false`, invalid section/key syntax rejects, and Unicode BOMs are recognized. This adapter imports configuration without rewriting it. Live BepInEx config-file watching and multiple copies of the static plug-in instance are outside this adapter's scope; the app hosts one instance and reloads it explicitly.

The reproducible oracle command is:

```sh
python3 Tools/reverse/analysis/mute_plugin_oracle.py \
  --source .local/reverse/plugin-execution/MuteInBackground.cs \
  --bepinex .local/reverse/plugin-execution/source/BepInEx/core/BepInEx.dll \
  --plugin .local/reverse/plugin-execution/source/BepInEx/plugins/BepInEx.MuteInBackground.dll \
  --installed-config .local/reverse/plugin-execution/source/BepInEx/config/BepInEx.MuteInBackground.cfg \
  --output .local/reverse/plugin-execution/mute-oracle
IKKOKU_MUTE_PLUGIN_ORACLE="$PWD/.local/reverse/plugin-execution/mute-oracle/reference.json" \
  swift test --package-path Packages/Engine --filter sourceMute
```

The oracle compiles the **unchanged recovered plug-in C#** against small component/audio endpoint stubs and executes configuration parsing from the **actual installed BepInEx.dll**. It records hashes and checks 23 configurations plus seven callback traces. Separate Swift tests compare every resulting state, exercise the native mixer and render a generated tone offline. These checks verify the bounded behavior and native audio mixer endpoint. They do not by themselves verify app startup, arbitrary Harmony patch execution or original Unity audio output. App startup and focus handling have the separate accepted checks above.

Original binaries, recovered source, configuration and trace results remain ignored in `.local/reverse/plugin-execution`. Only the host, generator, native adapter and tests belong in the repository.

## KK_StudioAccessoryNames 1.1.0

`SourceStudioAccessoryNamesPlugin` adapts the installed Studio plug-in's label pass. Slot counting advances only for text containing a UTF-16 decimal digit, missing names or inactive UI rows keep the original Japanese slot fallback, and resolved names retain their Unicode spelling. Source button positions 100/130 become 160/190 and text width becomes 150 in the label model; native UI uses SwiftUI layout. Labels use the exact resolved accessory entry name and never alter source/mod IDs or card bytes.

`Tools/reverse/analysis/accessory_names_oracle.py` compiles the unchanged recovered plug-in class against a small queried-UI host and runs its coroutine through the initial one-frame yield. Three cases cover named/missing accessories and inactive UI rows, non-slot widgets, shifted numbering and Unicode digit behavior. UI-row activity is distinct from the character’s accessory visibility flag: hiding a loaded accessory does not discard its resolved label. `SourceStudioAccessoryNamesTests` compares the entire resulting label/layout model against those traces when `IKKOKU_ACCESSORY_NAMES_ORACLE` points to the private `reference.json`. This adapter implements the original callback's label/layout result. The current source Clothes inspector consumes this model as described above; the visible label-value comparison remains separate. No arbitrary Harmony or Unity coroutine host is provided.


## HideAllUI 2.3.2 Studio adapter

This bounded adapter pins `HideAllUI.HideAllUI`, GUID `keelhauled.hideallui`,
version `2.3.2`, to the exact DLL digest above. It accepts the absent/default
configuration or UTF-8 `[Keyboard shortcuts]` → `Hide UI = Space`. Other shortcuts
fail explicitly before replacing a mounted session. The immutable package retains
all configuration bytes. The original manifest has no process restriction; this
adapter's supported host is Studio only.

```sh
python3 Tools/translation/plugin.py path/to/HideAllUI.Koikatu.dll \
  --type HideAllUI.HideAllUI --config path/to/keelhauled.hideallui.cfg \
  --output .local/plugins/hide-studio-ui
```

The recovered source captures an array of active GameObject Canvas components
at handler construction, then filters their names lazily on each toggle. It changes
those GameObjects' active state. Optional plugin canvases are found by path on
each toggle and change `Canvas.enabled`; inactive GameObjects are not found.
The optional main-camera manipulator changes GameObject active state. Initialization
sets the handler's internal visibility to true without changing existing surface
states. New game canvases are absent from the captured array, while renamed
captured objects can enter the deferred name filter. The name predicate runs before
the later Unity truthiness predicate. In the retained Unity 5.6.2f1 player, a
destroyed captured Canvas produces `System.NullReferenceException` after the
internal flag flips but before dynamic canvases update. A fresh handler drops
those stale references; it does not reveal surfaces during initialization.

The native mapping is an explicit Ikkoku host contract, not a general Canvas API:

| Native role | Visibility layer |
| --- | --- |
| Workspace, inspector, viewport toolbar and authored timeline | Transparent, disabled and inaccessible while hidden; layout and viewport identity retained |
| Object, bone, IK and light guides | Omitted from the frame and hover picking; active guide gestures cancelled when hiding |
| Viewport orbit/pan | Remains available |
| View menu | Remains available; **Show Studio Interface** removes the adapter's hiding |

Only unmodified Space delivered to the active Studio viewport toggles the layer.
Repeat events are consumed without toggling playback or visibility. Text editing
owns its own input, and modified Space does not fall through to playback while the
adapter is mounted. Without the adapter, existing viewport shortcuts are unchanged.
The layer never changes `showGizmos` or `showTimeline`: recovery, unload, mode exit
and a fresh scene restore preserve those host preferences. Visibility itself is
session-local; native scenes save the exact package/config reference and reload a
fresh visible handler. Original-game visibility persistence is not claimed.

Updates are event-driven. No filesystem checks, Canvas lookup, frame-tick callback
or per-frame UI invalidation was added. A visibility event rebuilds the existing
frame so hidden guides cannot remain pickable. Native scenario coverage uses the
same package loader, key/mouse handlers, mode path, save/reload and unload methods.
The real-Unity oracle is separate from the native host and public synthetic tests.

The original-player trace records ten phases and sixteen retained targets from
an isolated player with the exact plugin DLL. Its first producer used Unity 5.6
`JsonUtility`, which omitted nested observations; that run was rejected. The
corrected producer emitted all fields. Its initial validator expected a
`MissingReferenceException`; the retained trace instead establishes the exact
`NullReferenceException` described above. A corrected independent validation pins
that observed type and passes the same unchanged trace, with both initial failures
retained. This is not described as a passing first validation or a fresh rerun.

Four public synthetic trace-contract tests, sixteen Python package-library tests,
two original-fixture packaging tests and sixteen focused Engine tests pass locally,
with no skips in these runs. The probe compiles against retained original metadata;
its exact JSON serializer also passes a standalone nested/escaping check.

The clean Release build at `e652954` (executable SHA-256
`53162923fed56e4ea5c080aa3a7796f508afd1c6eb6034c14efae50e6f1c87c8`)
passes 21 native interaction checks and four fresh-process restoration checks.
These cover unchanged authored preferences, configuration-failure rollback, exact
saved package references, mode/input ownership, repeated resource/content stability,
and a real rendered-guide grab followed by hiding and an attempted invisible drag.
The guide gesture ends without changing the document; hidden orbit remains usable.
The initial guide-pick harness failure is retained: it projected untransformed
unit vertices. The corrected check projects transformed triangle centers and keeps
the same interaction assertions. Earlier app/test compile failures are also retained,
separately from the successful build and test records.

Visible checks on the same `53162923…` executable cover normal Space playback
without the adapter, actual package mount and native scene reopen, text input
receiving a literal Space, Shift+Space leaving the panels unchanged, a held Space
hiding once and the next Space restoring them. Hidden panels leave the AX tree;
the old Add-button location is noninteractive. Gizmo/timeline preferences set off
stay off through hide/show and mode exit/return. Maker retains its controls and
disables the converted-plugin load command. **Show Studio Interface** is enabled
while hidden, but activating that custom View menu remained tool-limited: the
automation connection returned invalid accessibility elements while the process
remained alive. Visible menu recovery and visible unload are not claimed as passed;
their native model paths pass the automated checks above. Owned GUI processes were
stopped. A rejected unsupported scene-load environment input is retained separately
from the successful real File → Open Scene workflow.

A scenario-only Release build at `a6dcd8c` (executable SHA-256
`b11d8ad689bc9befd470b05e3ca17885fe14e47d514f4f1eaeb38216d8cba616`)
retains identical production model, panel and Engine runtime sources. Three quiet
processes each pass both loaded-scene checks with seven rendered characters,
141 draw items and identical resource counts. Animation time is held at zero,
live animation/blink are off, and each process records its first visibility pair,
three warmup pairs and twenty measured pairs through the actual key handler.
Per-process hide medians are 0.409–0.428 ms; show medians are 0.425–0.440 ms;
the largest measured event is 0.610 ms. These are synchronous key-handler/model
refresh costs, excluding asset loading, deferred SwiftUI layout/display and GPU
completion. They do not establish an FPS improvement or complete UI latency.
The first cost attempt used the wrong single-character synthetic scene and exited
before its scenario; its inputs/log are retained separately from the corrected
seven-character runs. Camera-only timings remain functional diagnostics.

Private evidence is retained in
`.local/codex-continue-2026-10-24/wave-three/plugins/hide-studio-ui/`.
