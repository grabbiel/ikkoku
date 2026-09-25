# Architecture and data boundaries

Reviewed against the 2026-09-25 working tree. Feature completion and actionable
work belong in the [component audit](component-audit/README.md); this page maps
responsibilities and contracts.

## Native modules

| Component | Responsibility and main dependencies |
| --- | --- |
| `Apps/IkkokuCreator` | SwiftUI lifecycle, Maker/Studio models, commands, document dialogs and capture/benchmark hosts |
| `CoreMath` / `ShaderTypes` | Column-vector transforms, projection and explicit Unity basis conversion; shared CPU/Metal layout declarations |
| `Assets` | glTF, catalogs, MessagePack and source/mod data contracts; depends on math/shared types |
| `GPU` | Metal device/resources and frame storage; depends on math/shared types |
| `Scene` | Cameras, meshes, rigs, transforms and standalone IK; depends on assets/math |
| `Renderer` | Deformation, frame encoding, resource registration, native shading and diagnostics; depends on GPU/assets/scene |
| `Character` | Native/original character cards, bundled assembly and source rigs, Maker selections, shape/material/expression/dynamics evaluation; depends on renderer/scene/assets |
| `Gameplay` | Foundation-level source gameplay kernels, bounded IR and plugin lifecycle/runtime; no playable game host |
| `Studio` | Scene documents, source records, editing, character preview, FK/IK, animation, voice and plugin world; depends on character/renderer/gameplay |
| `IkkokuInspect` | Command-line decoding, numerical evaluation and conversion inspection |

The package manifest is [Package.swift](../Packages/Engine/Package.swift).
Production Metal programs are in `Shaders/`; the app build creates
`IkkokuShaders.metallib`. Source shader diagnostics compile a separate translated
path and do not replace production material dispatch.

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
