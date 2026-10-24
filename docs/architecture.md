# Architecture and data boundaries

Updated from the merged code on **2026-10-24**, including the head-preparation
boundary in #200. This page maps responsibilities and data ownership. Feature
status and measured acceptance belong in the
[component audit](component-audit/README.md).

## Native modules

| Component | Responsibility and main dependencies |
| --- | --- |
| `Apps/IkkokuCreator` | SwiftUI lifecycle, Maker/Studio models, commands, document dialogs and capture/benchmark hosts |
| `CoreMath` / `ShaderTypes` | Column-vector transforms, projection and explicit Unity basis conversion; shared CPU/Metal layout declarations |
| `Assets` | glTF, catalogs, MessagePack and source/mod data contracts; depends on math/shared types |
| `GPU` | Metal device/resources and frame storage; depends on math/shared types |
| `Scene` | Cameras, meshes, rigs, transforms and standalone IK; depends on assets/math |
| `Renderer` | Deformation, frame encoding, resource registration, native toon shading, live source-shader dispatch and diagnostics; depends on GPU/assets/scene |
| `Character` | Native/original character cards, bundled assembly and source rigs, Maker selections, shape/material/expression/dynamics evaluation; depends on renderer/scene/assets |
| `Gameplay` | Foundation-level source gameplay kernels, bounded IR and plugin lifecycle/runtime; no playable game host |
| `Studio` | Scene documents, source records, editing, character preview, FK/IK, animation, voice and plugin world; depends on character/renderer/gameplay |
| `IkkokuInspect` | Command-line decoding, numerical evaluation and conversion inspection |

The package manifest is [Package.swift](../Packages/Engine/Package.swift).
Production Metal programs are in `Shaders/`; the app build creates
`IkkokuShaders.metallib`. Native toon shading is the default. Studio can opt into
live translated source programs using converted shader/material inputs; unsupported
materials retain explicit toon fallbacks. Separate diagnostic hosts can freeze
geometry, replace texture providers or instrument shader output. Results from
those hosts must identify their differences from the live app path.

## Content paths

1. **Bundled content:** `Tools/assets/` generates `Assets/` from locally staged
   MakeHuman inputs and procedural data. Native catalog IDs and skeleton/morph
   conventions follow the [native asset contract](reference/native-assets.md).
2. **Original content:** `Tools/reverse/` inventories the Parallels installation,
   copies explicitly selected files, recovers managed contracts and converts
   assets into ignored `.local/reverse/`. Swift source consumers load neutral
   rig/appearance/library documents and original card/scene records.
3. **Mods:** `Tools/mods/` indexes archives by identity and dependency; supported
   conversion produces local profiles. Saved resolver IDs and unknown plugin data
   remain attached to cards/scenes. `Tools/translation/` emits generated Swift and/or supported typed IR, and packages
   exact native adapters. Each path has its own bounded supported behavior.

Original and bundled cards both use PNG containers but different payload formats.
Native JSON cards, original MessagePack character cards and original Studio binary
scenes must use their matching reader/writer. Original edited export patches
supported fields while retaining unknown bytes and identities. Preserving those
bytes is not executing their behavior.

## Spatial and evaluation contracts

Native world space is right-handed, Y up; the camera looks down view-space −Z.
Raw Unity conversion reflects Z with `C * M * C`, reverses triangle winding and
converts quaternions/tangents consistently. Already converted glTF must not be
reflected again. Follow the [renderer contract](reference/renderer.md).

Source character evaluation combines assembly selection, shape destinations,
static ABMX, expression and animation state, then Studio FK/IK/attachments and
supported dynamics in the owning runtime's defined order. These stages do not
share the bundled prototype's skeleton or slider semantics. The exact ordering and
unsupported cases are documented in the [character](reference/character/contracts.md),
[animation](reference/animation/animator.md) and [Studio pose](reference/studio/pose.md)
references; do not infer full scene support from an isolated solver test.

## Preparation, commit and runtime ownership

Maker's bounded selection worker prepares immutable assembly and appearance
inputs. The owning app model validates the current request and commits selected
resources while preserving later edits to the displayed character. Normal-head
preparation includes selected raw pixel snapshots with per-call and aggregate
limits; GPU composition and synchronous completion still occur during commit.
Cancellation, stale results and failed candidates must retain the displayed
character and release candidate-owned resources. Texture transactions publish
cache entries at commit and retain existing collision/lifetime rules. The
[Maker reference](reference/character/maker-assets.md) records the latency tradeoff.

Studio owns source preview instances, animation clocks, document edits and plugin
sessions. Cached evaluation avoids repeated solves within a tick; views should
observe edit/session state rather than recomputing from the frame clock. A preview
cache entry also owns geometry and runtime history, so rollback must account for
that state in addition to serialized document fields.

Mod libraries identify immutable package revisions and saved source identities.
Plugin library preparation uses bounded work, cancellation and generation checks;
the owner publishes an accepted session and its panel summary. Direct packages,
translated profiles and library mounts have distinct loading/restore policies.
Fresh-profile callbacks stage cold previews and checkpoint touched warm state;
failed candidates release private inputs and restore prior state. Library mounts
and legacy saved-profile restoration retain their distinct attachment-read gates;
fresh-load support does not establish saved-restore support. See the
[plugin execution contract](reference/mods/plugin-execution.md).

Measure changes at their actual boundary: background preparation, owner commit,
frame encoding, GPU completion and retained/transient resources are separate costs.
Use serialized quiet runs for timing comparisons and retain functional-only runs
as such. The [performance reference](reference/performance.md) defines the harness.

## Evidence and extension points

Recovered C#, serialized inputs, independent numerical references, original-player
probes and native renders are different evidence classes. Contract documents name
which one supports a claim. The audit distinguishes decoded/preserved data,
native execution, app/UI reachability and measured parity. Local reports should
retain hashes, converter versions, fixture dimensions and skipped/unsupported work.

Add coverage through the existing boundaries: a source data contract plus converter,
a native consumer, an app entry point where required and an acceptance check against
the intended evidence. Unknown source identities must remain explicit rather than
silently selecting similarly named bundled assets. See the audit's task IDs for
concrete acceptance criteria before expanding a subsystem.
