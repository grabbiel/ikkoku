# Build, test and capture

Reviewed 2026-09-25. Commands run from the repository root unless stated otherwise.
See the [documentation index](../README.md) and
[verification audit](../component-audit/toolchain-and-verification.md) for scope.

## Native prerequisites

The application target declares macOS 14.6, the engine package declares macOS 14
and Swift tools version 6.0, and `IkkokuShaders` declares macOS 26.0. These settings
do not establish a verified minimum macOS version for the combined product.
Resolve the shader deployment mismatch and test older systems in T-T01. The
recorded development setup uses Xcode 26 with the Metal Toolchain component. If `xcrun -sdk macosx metal --version` cannot find the
compiler, install that Xcode component:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Bundled assets are already in `Assets/`; Blender and the original game are not
required to build the native app. Asset regeneration has separate prerequisites
in the [asset pipeline runbook](../../Tools/assets/README.md).

## Build and launch

```sh
xcodebuild -project Ikkoku.xcodeproj -scheme IkkokuCreator \
  -configuration Debug -derivedDataPath .local/build \
  -destination 'platform=macOS,arch=arm64' build
open .local/build/Build/Products/Debug/Ikkoku.app
```

Alternatively open `Ikkoku.xcodeproj` and run the `IkkokuCreator` scheme. The product
is `Ikkoku.app`. `IKKOKU_ASSETS=/absolute/path/to/Assets` overrides the bundled native
asset root when launching the executable directly. Build with `-configuration
Release` for measurements and use the corresponding `Products/Release` executable.

## Test layers

```sh
swift test --package-path Packages/Engine
python3 -m unittest discover -s Tools/mods -p 'test_*.py'
python3 -m unittest discover -s Tools/translation/tests -p 'test_*.py'
```

The Swift suite includes synthetic contracts and optional source fixtures. Tests
that guard an absent `IKKOKU_*` path can return early; a green suite alone does not
prove source-data coverage. Metal-specific checks need a Metal device. Record
fixture environment variables, executed case counts and input hashes with results.
The [component reports](../component-audit/README.md) map features to their tests.

For the reverse tools, create the pinned Python environment before running their
unit tests or exporters. The recorded compatible interpreter is Python 3.12:

```sh
python3.12 -m venv .local/reverse/unitypy-venv
.local/reverse/unitypy-venv/bin/python -m pip install -r Tools/reverse/requirements.txt
.local/reverse/unitypy-venv/bin/python -m unittest discover -s Tools/reverse -p 'test_*.py'
.local/reverse/unitypy-venv/bin/python -m unittest discover -s Tools/reverse/analysis -p 'test_*.py'
```

Some reverse scripts named `test_*` are fixture-driven command-line programs, not
unittest cases. Run the commands in the owning reference page to exercise those
checks; discovery does not replace them. Managed recovery uses local ILSpy tools;
the Roslyn translation frontend uses .NET 10 SDK assemblies. See
[managed recovery](../reference/managed-recovery.md) and
[API substitution](../reference/mods/api-substitution.md) for setup and invocations.

## Offscreen and UI captures

These examples use an existing converted static model or native scene. Replace
input paths before running:

```sh
IKKOKU_CAPTURE_MODEL=/absolute/path/to/model.gltf \
IKKOKU_AUTOCAPTURE="$PWD/.local/model.png" \
  .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku

IKKOKU_CAPTURE_SCENE=/absolute/path/to/native-scene.png \
IKKOKU_AUTOCAPTURE="$PWD/.local/scene.png" \
  .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
```

`IKKOKU_CAPTURE_W`, `IKKOKU_CAPTURE_H` and `IKKOKU_CAPTURE_YAW` control dimensions
and framing where supported. `IKKOKU_CAPTURE_MIRROR=1` exercises mirrored static
model rendering. The static-model/native-scene capture paths report nonzero status
on handled import/render failures. A static-model capture isolates
asset loading and rendering from Maker assembly.

```sh
IKKOKU_CAPTURE_UI="$PWD/.local/studio-ui.png" IKKOKU_CAPTURE_UI_MODE=studio \
  .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
```

UI capture opens the application window; it is distinct from offscreen rendering.
It currently ignores PNG-write failures, so inspect the output file rather than
relying on its exit status (A-T05).
Source-rig, card, scene, plugin and matched-player capture recipes live with their
[technical references](../README.md#technical-references). Headless captures exit
before `NSApplication` finishes launching. The Mute native adapter therefore defers
its initial focus sample instead of reading `NSApp`; this fixes the recorded
startup trap. `IKKOKU_APPLICATION_FOCUS` and `IKKOKU_NATIVE_PLUGIN_REPORT` supply
and record focus for captures. The release adapter capture that closes A-T04 and
ST-T02 has not been rerun yet; see
[native adapters](../reference/mods/native-adapters.md#startup-and-acceptance).

## Inspect without the GUI

```sh
swift run --package-path Packages/Engine ikkoku-inspect model /absolute/path/to/model.gltf
swift run --package-path Packages/Engine ikkoku-inspect scene /absolute/path/to/source-scene.png
swift run --package-path Packages/Engine ikkoku-inspect scene-document /absolute/path/to/source-scene.png
swift run --package-path Packages/Engine ikkoku-inspect rig /absolute/path/to/rig.json
```

`scene` reads the object section; `scene-document` includes the supported scene
settings tail and retained extension data. Decoding success is not scene rendering
coverage. Keep original content, generated fixtures, captures and build output in
ignored `.local/`. Performance comparisons must record configuration, machine,
resolution, scene contents, simulation work and renderer path; do not extrapolate
a static fixture to full-game frame time.
