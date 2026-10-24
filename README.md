# Ikkoku

Ikkoku is a native Swift + Metal character maker, posing studio and renderer for
Apple Silicon. It includes bundled generated content and a local pipeline for
reconstructing Koikatsu and CharaStudio behavior from an installed copy of the game.
The original-game port is incomplete.

Start with the [documentation index](docs/README.md),
[build and test guide](docs/guides/build-and-test.md), or
[app usage guide](docs/guides/using-the-app.md). The
[component audit](docs/component-audit/README.md) records current feature status,
specific code findings, evidence limits and actionable implementation tasks.

To contribute through GitHub, follow the [contribution guide](CONTRIBUTING.md)
for issues, branches, pull requests, collaboration and validation requirements.

## Build

Use an Apple Silicon development host with Xcode 26 or newer, Swift 6 tooling and
the Metal compiler. The public test lane also needs Python 3 and .NET SDK 10 or
newer. Deployment settings currently differ: app 14.6, engine package 14,
shader target 26.0. Older-macOS runtime support still needs verification. Run commands from the repository root:

```sh
python3 Tools/verification/doctor.py --require public
python3 Tools/verification/run.py --manifest Tools/verification/lanes/public.json
xcodebuild -project Ikkoku.xcodeproj -scheme IkkokuCreator \
  -configuration Debug -derivedDataPath .local/build \
  -destination 'platform=macOS,arch=arm64' build
open .local/build/Build/Products/Debug/Ikkoku.app
```

The checker reports which recorded prerequisites are present. The
[clean-checkout setup](docs/guides/build-and-test.md#set-up-a-clean-checkout)
and its prerequisite table list every recorded tool and version, including the
.NET SDK that the public test lane needs.
The bundled prototype can run without the original installation. Source-based
features require separately converted local data; see the
[extraction runbook](Tools/reverse/README.md). Some tests require explicit private
fixtures and otherwise return without exercising source behavior.

## Current scope

Overview refreshed **2026-10-24**, including merged work through
[#200](https://github.com/grabbiel/ikkoku/pull/200). Each linked reference retains
its own measured commit, inputs and exclusions; this refresh is not a new
all-project acceptance run. All eight priority components remain incomplete.

| Component | Implemented and verified scope | Remaining work |
| --- | --- | --- |
| **Character Maker** | Normal male/female cards, asynchronous head 0/200/201 and converted asset selection, shape/color editing, static ABMX and identity-preserving edited export. [Maker contract](docs/reference/character/maker-assets.md). | Wider catalogs, special/modded assemblies, remaining owner-thread selection stalls and complete original editing workflows. |
| **Base Models** | All six converted normal sex/head assemblies have independent original-player neutral and one coupled-shape comparisons; head 0 also has bounded bone-type-1 checks for both sexes. [Model evidence](docs/reference/character/neutral-model-parity.md). | Other corrected types, arbitrary shapes, complete hierarchy, animation and appearance parity. |
| **Base Shapes** | 52 face and 44 body controls with recovered destination/order rules and bounded numerical gates; normal male Maker height follows the source fixed value. [Shape contracts](docs/reference/character/contracts.md). | Broader model/shape combinations and unsupported transform cases; control count alone does not establish universal parity. |
| **Renderer** | Native toon rendering plus opt-in live translated source shaders in Studio, with explicit toon fallbacks and resource ownership/caching. [Renderer contract](docs/reference/renderer.md). | Remaining material dispatch, source scene effects, resource limits and representative performance acceptance. |
| **Materials** | Selected native GPU composites and strict independent image gates. The controlled inner-shoe fixture reaches 18 of 20 live slots, with body and face fallbacks. [Material evidence](docs/reference/renderer.md#native-normal-inner-shoe-composite-r1cmt-04-177-2026-10-24). | Body/face composites, broader layers/patterns/states and whole-character shading. Coverage is fixture-specific. |
| **Visual Fidelity** | Bounded geometry, pose, material and matched-frame gates; independent live comparisons and sampling diagnostics. [Fidelity audit](docs/component-audit/renderer-and-foundation.md). | Full-character silhouette/color parity and same-input live sampling repeatability ([#188](https://github.com/grabbiel/ikkoku/issues/188)). |
| **Mods** | Incremental immutable archive/profile indexing, saved-ID resolution, converted selections, static ABMX and unknown-payload preservation. [Mod guide](docs/guides/mod-library.md). | General mod geometry, dynamic callbacks, migrations and installation-wide compatibility. |
| **Plugins** | Bounded translated execution and three exact-revision native adapters: Mute, StudioAccessoryNames and HideAllUI. Mounted-session controls, cancellation, fresh-profile failure isolation and selected save/restore workflows are exercised. [Execution contract](docs/reference/mods/plugin-execution.md). | General DLL/Harmony/coroutine/Unity compatibility and saved-profile restoration with initializer attachment reads. |

Studio supports selected original characters, cameras, FK/IK, animation,
expression/shape/outfit/accessory edits and bounded scene export. Its source
Pose, Face and Clothes inspectors are reachable; broader interactive acceptance,
mixed scene objects, maps, lights and effects remain open. Gameplay has bounded
cycle, event and ADV kernels and a headless host, with no complete playable mode.

Performance is part of every component's acceptance. Record responsiveness, total
latency, memory and GPU work separately. Prepared head-selection inputs reduce
owner-thread stalls at a total-latency and retained-input cost. Fallback reuse and
[bounded composition batches](docs/reference/character/maker-assets.md#bounded-synchronous-composition-batches-208)
reduce allocations and waits; measured owner-thread timing remains mixed. Peak
memory was not measured. Functional success alone does not establish a speedup.

The [current work and evidence](docs/component-audit/README.md#current-work-and-evidence)
section distinguishes merged support, active investigations and historical
checkpoints. Parsing, preserving a payload or recovering source code does not
establish native execution, UI support or source-game parity.

## Repository map

| Path | Purpose |
| --- | --- |
| `Apps/IkkokuCreator/` | SwiftUI Maker, Studio, document commands and capture hosts |
| `Packages/Engine/` | Native engine modules, inspector CLI and tests |
| `Shaders/` | Production Metal shaders |
| `Assets/` | Generated bundled assets and catalog |
| `Tools/assets/` | Bundled asset generation |
| `Tools/reverse/` | Original-data recovery, conversion, probes and oracles |
| `Tools/mods/`, `Tools/translation/` | Incremental mod library and bounded C# translation |
| `docs/` | Guides, architecture, current audit, technical references and archives |
| `.local/` | Ignored original data, recovered code, generated evidence and builds |

The [architecture guide](docs/architecture.md) explains module responsibilities and
data flow. Historical milestones are retained in [the archive](docs/archive/README.md).

## Asset provenance

The bundled pipeline documents its MakeHuman-derived inputs and generated content
in [Tools/assets](Tools/assets/README.md). Original game files, recovered source and
local mods stay outside version control and are not bundled with the application.
The repository currently has no standalone code license file; earlier README
license declarations should be resolved before distribution.
