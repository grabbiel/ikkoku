# Installed native plugin adapters

Reviewed 2026-09-25. Two exact installed revisions have verified **bounded Swift
behavior adapters** and immutable package tests. Actual app integration is
incomplete: Mute can trap during startup before `NSApp` exists, and the source
character inspector gate prevents reaching accessory labels. The successful
IR-only release capture does not validate either workflow. See
[A-T04 / P-T03](../../component-audit/app-gameplay-and-plugins.md) and
[ST-T01/02](../../component-audit/studio.md) for confirmed defects and acceptance.

## Conversion and identity

The conversion CLI recognizes two installed DLLs by their complete SHA-256 hashes
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
This menu wiring is not a completed mount/save/reload verification; the known
startup failure is described below. The package retains original assembly and
configuration bytes, GUID, version, type and process restrictions. The DLL is identity evidence; the Swift adapter
implements the recovered behavior. A different DLL revision requires its own
verified adapter, or passes through the strict C# translator. Rejected conversion
never publishes a loadable manifest. Existing package directories are immutable.

The persistence model stores enabled mounts and package hashes in native scene
cards. Its restore code validates the entire package, including original config
bytes, before applying it; package tests cover the saved references. The actual
release mount/save/reload/continue test has not passed. New-scene and
original-scene-import code retain current global mount references. The accessory
label consumer is enabled only by its mount, but its inspector remains unreachable.
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
actual app startup and UI verification.

The registry requires these exact assembly identities:

| Adapter | Original DLL SHA-256 |
| --- | --- |
| `bepinex-mute-in-background-v1` | `e494f24b73fed491d056c3c6a00ee73baf257409877ce8e5b44da1b0494ca96d` |
| `kk-studio-accessory-names-v1` | `c60d740ee1037040e97bcb0ae8037f8f7a1e4350322bc7ed44699fd0dc9662bd` |

The retained 2026-09-25 evidence reports three native package tests and one
original-fixture Python packaging test passing. This documentation revision did
not rerun them. Missing fixture variables skip the original-assembly comparison.

## App integration defects

`StudioModel.configureSourceMutePlugin(configuration:)` calls `NSApp.isActive`
from a path reachable during `AppState` initialization. The private
`.local/reverse/plugin-execution/native-adapter-capture-01` run terminated with
SIGTRAP before capture; `Ikkoku-2026-09-25-071053.ips` identifies that method.
Initialize focus after AppKit exists, or supply headless focus explicitly, then
rerun `studio_execution_probe.py` with both original manifests and the IR fixture.
Acceptance requires unchanged package hashes/IDs, resumed fields and pixel-identical
reload, followed by focus gain/loss checks with generated audio.

`StudioView` also intercepts source-character pose/face/clothes inspectors with a
stale placeholder. Remove that gate and verify the mounted accessory-name labels
through the actual UI. Label-model tests alone do not establish UI integration.

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

The oracle compiles the **unchanged recovered plug-in C#** against small component/audio endpoint stubs and executes configuration parsing from the **actual installed BepInEx.dll**. It records hashes and checks 23 configurations plus seven callback traces. Separate Swift tests compare every resulting state, exercise the native mixer and render a generated tone offline. These checks verify the bounded behavior and native audio mixer endpoint. They do not verify the currently broken startup mount, arbitrary Harmony patch execution or original Unity audio output.

Original binaries, recovered source, configuration and trace results remain ignored in `.local/reverse/plugin-execution`. Only the host, generator, native adapter and tests belong in the repository.

## KK_StudioAccessoryNames 1.1.0

`SourceStudioAccessoryNamesPlugin` adapts the installed Studio plug-in's label pass. Slot counting advances only for text containing a UTF-16 decimal digit, missing/inactive accessories keep the original Japanese slot fallback, and resolved names retain their Unicode spelling. Source button positions 100/130 become 160/190 and text width becomes 150 in the label model; native UI uses SwiftUI layout. Labels use the exact resolved accessory entry name and never alter source/mod IDs or card bytes.

`Tools/reverse/analysis/accessory_names_oracle.py` compiles the unchanged recovered plug-in class against a small queried-UI host and runs its coroutine through the initial one-frame yield. Three cases cover named/missing/inactive accessories, non-slot widgets, shifted numbering and Unicode digit behavior. `SourceStudioAccessoryNamesTests` compares the entire resulting label/layout model against those traces when `IKKOKU_ACCESSORY_NAMES_ORACLE` points to the private `reference.json`. This adapter implements the original callback's label/layout result. App UI reachability is still blocked as described above; no arbitrary Harmony or Unity coroutine host is provided.
