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

Use an Apple Silicon development host with Xcode 26, Swift 6 tooling and the
Metal compiler. Deployment settings currently differ: app 14.6, engine package 14,
shader target 26.0. Older-macOS runtime support still needs verification. Run commands from the repository root:

```sh
xcodebuild -project Ikkoku.xcodeproj -scheme IkkokuCreator \
  -configuration Debug -derivedDataPath .local/build \
  -destination 'platform=macOS,arch=arm64' build
open .local/build/Build/Products/Debug/Ikkoku.app
swift test --package-path Packages/Engine
```

The bundled prototype can run without the original installation. Source-based
features require separately converted local data; see the
[extraction runbook](Tools/reverse/README.md). Some tests require explicit private
fixtures and otherwise return without exercising source behavior.

## Current scope

Reviewed against the working tree on 2026-09-25:

- **Maker:** original normal male/female assemblies, heads 0/200/201, 52 face and
  44 body controls, bounded card-selected hair/clothes/accessories, material
  recipes, static ABMX and identity-preserving edited-card export. Catalog coverage
  is limited; special assemblies and arbitrary mod assets remain unsupported.
- **Studio:** source record decoding, selected character reconstruction, cameras,
  FK/IK kernels, animation and bounded original-scene editing. Full-body IK has a
  recovered-source oracle; source Pose/Face/Clothes inspectors are still blocked
  by a UI gate. Many decoded scene objects and settings lack runtime consumers.
- **Renderer:** native toon rendering and a separate source-shader diagnostic
  pipeline. Frozen geometry and selected garment comparisons pass; full-character
  color parity fails. Diagnostic translations are not the production renderer.
- **Gameplay and mods:** cycle and fixed-event eligibility kernels, bounded ADV and translated
  plugin execution, archive/catalog resolution and two exact native plugin
  adapters. No complete playable game host or general managed-plugin compatibility.
  The Mute adapter has a known headless startup crash.

A parsed record, preserved plugin payload or successful decompilation does not mean
that its behavior is rendered, interactive or ported. See the audit for those
separate boundaries and the next implementation tasks.

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
