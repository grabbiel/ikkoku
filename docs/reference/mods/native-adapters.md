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
launching the app. The acceptance below closes ST-T02/A-T04 for this revision.
The probe currently trusts the report's effective enabled setting; independently
compare it with the requested config until the non-blocking expected-setting
assertion from PR #2's review is implemented.

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
and exposes each of its twenty rows as `studio.source.accessory.<slot>`. Loaded
slots use the existing visibility toggles; unavailable slots show a disabled
label. Mounting the adapter selects the recovered label pass, using resolved
source names without changing source identities. The earlier placeholder no
longer blocks this inspector.

The accepted library-panel GUI run verifies selecting and mounting the accessory
adapter, not the values displayed in the Clothes inspector. A visible mounted /
unmounted label comparison, including outfit changes and unavailable slots, is
still a separate P-T03 acceptance gate. Label-model tests alone do not close it.

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

`SourceStudioAccessoryNamesPlugin` adapts the installed Studio plug-in's label pass. Slot counting advances only for text containing a UTF-16 decimal digit, missing/inactive accessories keep the original Japanese slot fallback, and resolved names retain their Unicode spelling. Source button positions 100/130 become 160/190 and text width becomes 150 in the label model; native UI uses SwiftUI layout. Labels use the exact resolved accessory entry name and never alter source/mod IDs or card bytes.

`Tools/reverse/analysis/accessory_names_oracle.py` compiles the unchanged recovered plug-in class against a small queried-UI host and runs its coroutine through the initial one-frame yield. Three cases cover named/missing/inactive accessories, non-slot widgets, shifted numbering and Unicode digit behavior. `SourceStudioAccessoryNamesTests` compares the entire resulting label/layout model against those traces when `IKKOKU_ACCESSORY_NAMES_ORACLE` points to the private `reference.json`. This adapter implements the original callback's label/layout result. The current source Clothes inspector consumes this model as described above; the visible label-value comparison remains separate. No arbitrary Harmony or Unity coroutine host is provided.


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

Four public synthetic trace-contract tests, sixteen package-library tests and two
original-fixture packaging tests pass locally, with no skips in these runs. The
probe compiles against retained original metadata; its exact JSON serializer also
passes a standalone nested/escaping check. Native app and visible UI gates remain
in progress on this branch. Private evidence is retained in
`.local/codex-continue-2026-10-24/wave-three/plugins/hide-studio-ui/`.
