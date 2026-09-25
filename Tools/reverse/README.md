# Local source-data pipeline

Reviewed 2026-09-25. Commands run from the repository root. This runbook covers
inventory, selected transfer and initial conversion recipes. The
[documentation index](../../docs/README.md) links every current technical contract;
the [component audit](../../docs/component-audit/README.md) owns feature completion,
known defects and actionable implementation tasks.

Inventory/extraction reads the installed files without launching or changing the
game. Separate original-player shader, character, animation, dynamics and lifecycle
probes launch isolated temporary copies for controlled captures. Original binaries,
recovered code, assets, logs and evidence remain in ignored `.local/reverse/`.
The Swift + Metal app uses converted data, bounded translated IR and native
adapters; it does not execute original managed DLLs or require Unity at runtime.

## Choose a workstream

| Work | Current reference |
| --- | --- |
| Complete selected managed exports and fallback decompilation | [Managed recovery](../../docs/reference/managed-recovery.md) |
| Character rigs, 52 face/44 body shape slots, male/female assembly | [Shape contracts](../../docs/reference/character/contracts.md), [rigs](../../docs/reference/character/rigs.md), [male assembly](../../docs/reference/character/male.md) |
| Original cards, selected assets, makeup and identity-preserving export | [Cards](../../docs/reference/character/cards.md), [Maker assets](../../docs/reference/character/maker-assets.md), [materials](../../docs/reference/character/material-expansion.md) |
| Studio scene records and bounded editing | [Scene records](../../docs/reference/studio/scene-records.md), [scene editing](../../docs/reference/studio/scene-editing.md) |
| Animator, full-body IK, dynamics and voice | [Animator](../../docs/reference/animation/animator.md), [Studio animation](../../docs/reference/studio/animation.md), [full-body IK](../../docs/reference/studio/full-body-ik.md), [dynamics](../../docs/reference/animation/dynamics-parity.md), [voice](../../docs/reference/studio/voice.md) |
| Gameplay and ADV | [Cycle](../../docs/reference/gameplay/cycle.md), [ADV execution](../../docs/reference/gameplay/adv.md) |
| Mods, C# substitution and native plugin adapters | [Mod guide](../../docs/guides/mod-library.md), [API substitution](../../docs/reference/mods/api-substitution.md), [plugin execution](../../docs/reference/mods/plugin-execution.md) |
| Source shader translation, matched frames and performance | [Renderer](../../docs/reference/renderer.md), [material probes](../../docs/reference/character/material-expansion.md) |

Recovery success, parsed records, preserved bytes, native execution and original
parity are separate milestones. Use the owning reference's fixture requirements;
there is no one-command whole-game converter or all-mod compatibility layer.

## Inventory and bounded transfer

`prlctl` and a running Parallels VM with guest tools are required. This installation
was observed at `C:\Illusion\Koikatsu`; use explicit VM and source arguments for a
different installation. Commands use encoded PowerShell to preserve Windows paths.

```sh
python3 Tools/reverse/vm_source.py --vm 'Windows 11' inventory
python3 Tools/reverse/vm_source.py --vm 'Windows 11' fetch \
  abdata/studio/00.unity3d abdata/studio/mat/00.unity3d \
  abdata/studio/info/00.unity3d
```

Inventory records player backends/Unity versions, managed DLL hashes, and bundle
names and sizes. Fetch accepts only explicit relative installation paths, bounds
each file transfer (256 MiB default), and verifies its length and SHA-256 against
the VM. Every copied source file gets a provenance sidecar. The retained
installation inventory contains 1,665 bundles; a selected export
fetches only its declared inputs.

## Targeted Mono recovery

The observed main and Studio players use Mono, Unity 5.6.2f1. VR is separately
5.6.3f1. No IL2CPP metadata/native reverse-engineering route is needed here.

```sh
python3 Tools/reverse/vm_source.py --vm 'Windows 11' fetch \
  CharaStudio_Data/Managed/Assembly-CSharp.dll \
  CharaStudio_Data/Managed/Assembly-CSharp-firstpass.dll \
  CharaStudio_Data/Managed/UnityEngine.dll \
  CharaStudio_Data/Managed/mscorlib.dll \
  CharaStudio_Data/Managed/System.dll \
  CharaStudio_Data/Managed/System.Core.dll
dotnet tool install ilspycmd --version 11.1.0.9782 --tool-path .local/reverse/tools
python3 Tools/reverse/analysis/decompile_studio.py \
  --managed .local/reverse/source/CharaStudio_Data/Managed
```

The initial recovery used `.local/reverse/managed/CharaStudio`, still the wrapper's
default. The wrapper recovers 17 named Studio contracts and writes a manifest of
input/output hashes and decompiler version. `--type Studio.OIItemInfo` narrows it
to one contract. See [binary format notes](../../docs/reference/studio/binary-contracts.md).

## Convert the verified chair

Use Python 3.12 for the pinned extraction environment (the available 3.14 runtime
could not build this dependency version on this machine):

```sh
python3.12 -m venv .local/reverse/unitypy-venv
.local/reverse/unitypy-venv/bin/python -m pip install -r Tools/reverse/requirements.txt
.local/reverse/unitypy-venv/bin/python Tools/reverse/catalog.py \
  --prefab p_koi_stu_isu01_00 --output .local/reverse/catalog/chair.json
.local/reverse/unitypy-venv/bin/python Tools/reverse/export_prefab.py \
  --bundle .local/reverse/source/abdata/studio/00.unity3d \
  --bundle .local/reverse/source/abdata/studio/mat/00.unity3d \
  --prefab p_koi_stu_isu01_00 --name chair \
  --catalog-lookup .local/reverse/catalog/chair.json \
  --output .local/reverse/exports/chair
.local/reverse/unitypy-venv/bin/python Tools/reverse/test_export_prefab.py \
  --export .local/reverse/exports/chair
```

The original lookup resolves `(group: 2, category: 13, no: 73)`; see
[catalog evidence](../../docs/reference/studio/item-catalog.md). The output includes glTF, binary
geometry, PNG base texture, raw local mesh/material/transform metadata, provenance,
and `catalog.json` binding the source item ID to `chair.gltf`. No display-name or
filename-number guessing is used.

The exporter handles explicit active static triangle prefabs with the observed
`Shader Forge/main_StandardMDK_studio` base-color, cutout and normal-packing contract. It rejects skinned or
morph meshes, unsupported topologies/shader families, disabled nodes/renderers,
nonidentity texture transforms and mismatched renderer/material counts. Colliders
and MonoBehaviours are recorded as unsupported components, not translated.

Positions/normals reflect Z; quaternions become `(-x,-y,z,w)`; winding reverses.
The exported upright PNG and `v = 1-v` pair keep texture orientation, and tangent W
accounts for both basis and V flips. The audit checks every exported vertex,
normal, tangent, UV, index and local transform against raw input and verifies
bundle hashes and triangle/normal agreement. Both source forward pixel variants
were disassembled: texture alpha clips against `_Cutoff`, material alpha is ignored,
and output alpha is one. The exporter uses MASK and the source cutoff accordingly.
The observed normal A/G channels are unpacked, scaled by `_BumpScale`, adjusted for
flipped V and encoded as normalized RGB for the native normal-map path. This adds
8-bit quantization; source lighting, parallax, metallic/gloss textures and original
material customization remain unimplemented.

## Native verification and rendering

```sh
swift test --package-path Packages/Engine
swift run --package-path Packages/Engine ikkoku-inspect model \
  .local/reverse/exports/chair/chair.gltf
xcodebuild -project Ikkoku.xcodeproj -scheme IkkokuCreator \
  -configuration Debug -derivedDataPath .local/build \
  -destination 'platform=macOS,arch=arm64' build
IKKOKU_CAPTURE_MODEL="$PWD/.local/reverse/exports/chair/chair.gltf" \
IKKOKU_AUTOCAPTURE="$PWD/.local/reverse/exports/chair/native-render.png" \
  .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
```

`IKKOKU_CAPTURE_MIRROR=1` verifies negative-scale culling/tangent handling. Width,
height and camera yaw use `IKKOKU_CAPTURE_W`, `IKKOKU_CAPTURE_H`, and
`IKKOKU_CAPTURE_YAW`. The isolated model path never constructs a Maker character.
It returns a nonzero status on import or Metal capture failure.

## Scene object records and layout conversion

```sh
swift run --package-path Packages/Engine ikkoku-inspect scene /path/to/source.png
swift run --package-path Packages/Engine ikkoku-inspect layout \
  /path/to/source.png .local/reverse/exports/chair/catalog.json /path/to/native.png
```

The object reader accepts all six recovered 1.0.4.2 object kinds, including
characters and routes, and reports the end of their object section. The
`scene-document /path/to/source.png` command additionally parses the complete
known scene-settings tail and reports retained extension data. Other versions
fail explicitly. `camera` and `change-amount` inspector modes
accept isolated 44-byte CameraData v2 and 36-byte ChangeAmount records.

Layout conversion accepts **props and folders only**, resolving every item from
the supplied local catalog before writing a native PNG card. It imports hierarchy,
visibility and exact quaternion transforms. Source material overrides, animation,
physics, lights, cameras and the scene settings tail are not applied. The app's
matching File command validates model files before changing the document.

A converted asset catalog is version 1 with an `items` array; each item contains
`group`, `category`, `no`, `name`, and a local `file`. Relative files resolve beside
the catalog. The original game's scene PNG and Ikkoku's JSON-in-PNG card remain
different formats. Ikkoku scene cards store external paths; they are not asset
packages and moving the referenced model files breaks those links.

**File → Preview CharaStudio Scene…** separately rebuilds supported normal
male/female card selections, applies shape/static ABMX/expression/FK state and
restores current/saved cameras. It retains unsupported objects as tree entries.
The source Pose/Face/Clothes inspector gate still blocks implemented guide controls;
routes/descendants and many mixed scene objects/settings have no rendering consumer.
For the verified synthetic fullscene fixture, use
`IKKOKU_SOURCE_SCENE=$PWD/.local/reverse/studio-scenes/synthetic-current.png`
with `IKKOKU_AUTOCAPTURE`. This does not recreate arbitrary original scene appearance.

Capture a converted native scene with `IKKOKU_CAPTURE_SCENE=/path/to/native.png`
and `IKKOKU_AUTOCAPTURE=/path/to/render.png`. The local two-chair verification scene
was constructed from a **synthetic object-section fixture**, using the real chair
asset. It is not a full original-game scene or evidence of complete scene parity.

## Character Maker rigs and source curves

See [rig recovery](../../docs/reference/character/rigs.md) for exact source bundles and export
commands, and [shape recovery](../../docs/reference/character/contracts.md) for the original
category/sample contracts. Generated files remain under `.local/reverse/rigs/`.

```sh
python3 Tools/reverse/analysis/character_contracts.py --recover
IKKOKU_SHAPE_CONTRACT="$PWD/.local/reverse/rigs/character-shape-contract.json" \
  swift test --package-path Packages/Engine
swift run --package-path Packages/Engine ikkoku-inspect rig \
  .local/reverse/rigs/neutral-rig.json
.local/reverse/unitypy-venv/bin/python Tools/reverse/test_rig_parity.py
```

The independent NumPy check runs the compiled inspector and compares every node
matrix and skinned vertex against raw source-space calculations at five settings,
including an interpolated rate. Install pinned requirements before running it.
The JSON report records source hashes and the exact inspector executable hash.

```sh
IKKOKU_CAPTURE_RIG="$PWD/.local/reverse/rigs/neutral-rig.json" \
IKKOKU_SHAPE_CONTRACT="$PWD/.local/reverse/rigs/character-shape-contract.json" \
IKKOKU_SOURCE_HEIGHT=0.5 \
IKKOKU_AUTOCAPTURE="$PWD/.local/reverse/rigs/native-clothing-height-0.5.png" \
  .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
```

Omit `IKKOKU_SOURCE_HEIGHT` for authored rest pose; use 0–1 for the recovered direct
height scale. `IKKOKU_RIG_BONES=1` overlays the complete hierarchy. This path renders
neutral materials unless an appearance sidecar is present, and fails on invalid
skin bindings. This legacy height probe holds its rest camera fixed. The assembled
avatar below also supports head/hand compensation and original clothing coverage.

To inspect interactively, use **File → Open Source Rig…** or launch with
`IKKOKU_OPEN_RIG=/absolute/path/to/neutral-rig.json`. Keep the shape contract beside
the rig to enable height controls. A raw rig preview is not a complete native character card and cannot be sent
directly to Studio. Original-card edited export is a separate supported path;
see [card appearance](../../docs/reference/character/card-appearance.md).

## Original clothed base: initial capture recipe

See [assembly](../../docs/reference/character/head-rig.md),
[body formulas](../../docs/reference/character/body-shape.md),
[face formulas](../../docs/reference/character/face-shape.md), and
[head materials](../../docs/reference/character/head-materials.md) for source evidence.
The recipe below captures the initial female base. Male, heads 0/200/201,
correction tables and card-selected assets use the additional conversion steps
in [Maker assets](../../docs/reference/character/maker-assets.md). With the selected
local bundles/rigs already exported:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/head_material_contract.py
.local/reverse/unitypy-venv/bin/python Tools/reverse/clothed_material_contract.py
python3 Tools/reverse/build_preview_appearance.py .local/reverse/rigs
IKKOKU_CAPTURE_RIG="$PWD/.local/reverse/rigs/source-avatar.json" \
IKKOKU_SOURCE_BODY=defaults IKKOKU_SOURCE_FACE=defaults \
IKKOKU_AUTOCAPTURE="$PWD/.local/reverse/rigs/native-avatar-front.png" \
  .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
```

`IKKOKU_SOURCE_BODY` and `IKKOKU_SOURCE_FACE` accept `defaults`, `rest`, `all=rate`,
or comma-separated `index=rate` pairs in 0–1. All 44 body and 52 face shape slots have recovered setter coverage on supported
normal assemblies. These slots fan out to more transform destinations; they do
not imply support for every special/modded rig. `IKKOKU_CAPTURE_PRESET=face` frames the
posed face. `IKKOKU_CAPTURE_SHADOWS=0` is a diagnostic comparison. The source front
is native −Z; capture yaw defaults to 180 degrees.

Maker automatically discovers `.local/reverse/rigs/source-avatar.json` with its
`source-avatar.appearance.json` sidecar. `IKKOKU_SOURCE_AVATAR` overrides that path.
Missing local content uses bundled characters; malformed content reports its error.
The source preview uses original geometry and bounded shader base-color recovery
with approximate native lighting. Clothing outlines are disabled because the current
inverted-hull implementation introduces an internal patch. Source expressions and automatic blinking are available. Normal male assembly,
bounded original-card import/edit/export and selected Studio character reconstruction
are now implemented. Full catalog/appearance coverage, general plugin behavior
and source-aware Studio controls remain incomplete; see the linked audit.

Shader bakes are gated by recovered DXBC program hashes and source-input hashes.
`clothed-materials/composition.json` records the no-pattern catalog selection,
original component/hair colors, render-target blending and the unresolved color-space
assumption. Use the resulting PNGs with white tint to avoid applying colors twice.
