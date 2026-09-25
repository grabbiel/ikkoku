# Ikkoku

A native macOS (Swift 6 + Metal) character maker, posing studio and cel-shaded
renderer in the spirit of Koikatsu's Character Maker and CharaStudio. Bundled content
is original: CC0 MakeHuman-derived base meshes restyled to anime proportions,
procedurally generated textures, hair, clothes and props, and a Metal toon
pipeline (two-tone shading, inverted-hull outlines, anisotropic hair band,
layered eyes, PCF shadows, bloom/FXAA).

The native rebuild now includes a local Koikatsu interoperability pipeline. It can
inventory a Parallels installation, recover main-game and Studio managed code, convert a
verified static prop, read complete current-format CharaStudio records, and assemble the
original normal female/male head/body/hair and clothing. The local Maker uses these
recovered bases when available, with 52 face controls, all 44 body slots mapped to
the recovered destinations, and recovered
neutral/blink/smile expressions, source-timed blinking, original Idle and recovered
hair dynamics. Day/period progression, fixed-event selection, a bounded ADV interpreter,
source two-bone IK and Studio FK have independently verified native implementations.
Studio can preview supported original character shapes/FK on the clothed reference
avatar; complete scene appearance and the playable gameplay lifecycle remain unfinished. An incremental `.zipmod` library now discovers
local archives, preserves source identities, converts supported textures and
reports catalog dependencies. Static ABMX bone modifiers also apply to the recovered
rig; see
[mod compatibility](docs/reverse-mods.md) for its current limits. It is **not
yet a complete game recreation**. See [rebuild status](docs/REBUILD.md) and the
[extraction runbook](Tools/reverse/README.md) for exact scope and reproducible steps.

## Build and run

Requirements: macOS 14.6+, Xcode 26 with the Metal Toolchain component
(`xcodebuild -downloadComponent MetalToolchain` if `metal` is missing).

```bash
xcodebuild -project Ikkoku.xcodeproj -scheme IkkokuCreator -configuration Debug build
```

Or open `Ikkoku.xcodeproj` and run the `IkkokuCreator` scheme (the product is
`Ikkoku.app`). Assets are copied into the app bundle from `Assets/`; set
`IKKOKU_ASSETS=/path/to/Assets` to point the app at another asset root.

Engine unit tests: `cd Packages/Engine && swift test`.

## Using it

With the recovered local avatar present, Maker opens the original model preview:
52 face sliders, all 44 body slots with explicit destination coverage, reset, skeleton
display and Full/Upper/Face views, expression presets, automatic blinking and manual
eye/mouth openness. **New Male Character** uses the recovered normal male when its
local assets are present; normal male height follows the original fixed value.
When converted animation/dynamics data is present, separate **Original idle animation**
and **Original hair motion** toggles control source playback.
Disable **Automatic blinking** to inspect static eye openness; choosing a closed-eye
preset does this automatically. Original card import, guarded color editing and
edited source-card export are available as described below. Full expression
transitions, voice playback, arbitrary outfit geometry and Send to Studio remain
unfinished in this path. The controls described below apply to bundled characters,
available through **Use bundled prototype**. Original extracted content stays in
`.local/` and is not copied into the application bundle.

**Mods → Open Mod Library…** mounts a profile produced by the
[incremental scanner](docs/mod-library.md). Reload refreshes the native profile
after a scan; the library view reports selected versions, conflicts and dependency
coverage. **Mods → Load Bone Modifiers…** opens a converted
[ABMX document](docs/reverse-abmx.md), with enable/disable and modifier outfit-index
controls. Source-card export preserves the imported ABMX and other plug-in data;
dynamic/accessory ABMX behavior and arbitrary managed plug-ins remain unsupported.

**File → Import Source Card…** reads original character PNGs, including current or
legacy Extended Save data and compressed ABMX modifiers, and selects the matching
normal male/female reference rig. Supported head-00, standard-body cards supply
all 96 shape values and static bone modifiers. In **Card appearance**, select one
of the card’s seven outfits, edit available colors, then use **Apply colors**.
The selected assets have guarded recipes for up to 25 color fields. Other hair,
outfit, accessory and material selections remain preserved with compatibility
diagnostics; the outfit selector does not load arbitrary garment geometry.

**File → Export Edited Source Card…** saves a new original-format PNG containing
shape/color edits and a fresh clothed thumbnail. Unknown fields, asset identities,
untouched outfit records and plug-in data are preserved. Choose a new filename;
the imported file remains unchanged. Other head/bone types and special male
models are rejected for preview. See the [card format notes](docs/reverse-card.md)
and [appearance recipes](docs/reverse-card-appearance.md).

Imported cards also show their saved mod references, matching catalog entries and
asset dependencies in the selected mod library. The report refreshes when the
library changes and preserves unresolved references. These checks do not load
arbitrary card-selected assets or execute plug-ins. Known original appearance
recipes are guarded against conflicting mod identities. See the [card mod reference notes](docs/reverse-card-mods.md).

**File → Preview CharaStudio Scene…** reads original character, route and scene
records, then applies supported female/head-00 shapes, static ABMX and saved FK to
the local clothed reference avatar. Unsupported appearance, attachments and runtime
features are listed in **Source compatibility details**. Other source objects remain
named unrendered tree entries in this preview. Native scene cards preserve hash-checked
references to the original file. See [Studio scene scope](docs/reverse-studio-scenes.md).

**Maker** (⌘1): tabs for Face, Body, Hair, Clothes, Accessories, Profile.
Sliders go from −100 to 100; every slider is a morph target, a bone scale, a
bone offset or a combination. Colours use the system colour picker plus quick
swatches. `Random` rolls a character; camera presets Full/Upper/Face (keys
B/U/F); left-drag orbits, right-drag or ⇧-drag pans, scroll zooms.
⌘S saves a **character card**: a PNG whose pixels are the thumbnail and whose
`iTXt` chunk holds the character JSON. ⌘O opens a card. ⇧⌘T sends the
character to the studio.

Characters idle like in Koikatsu: they blink and breathe, their eyes (and
optionally the head) follow the camera, and long hair swings on its chain
bones. The wind button in either toolbar pauses the idle animation.

**Studio** (⌘2): a workspace tree (characters, items, lights, cameras,
folders), gizmos (T/R/S keys, Local/World), FK posing (click a joint, drag the
ring), IK for hands and feet, pose presets and hand gestures, expressions and
gaze, clothing states (on/half/off), scene lights, the Koikatsu-style
camera-relative character light, screen effects (bloom, vignette, grading,
fog, outline width), 10 camera slots (1–0 to load, ⇧1–0 to save), undo/redo,
and captures (⇧⌘P) up to 4K with optional transparent background. Scenes save
as PNG cards too (⌥⌘S / ⇧⌘O), and can be imported into the current scene.
The **timeline** bar under the viewport animates objects: scrub or play
(Space), press K (or the Key button) to store the selected object's transform,
FK/IK pose, gestures and expression at the current time; playback
interpolates between keys and loops. Keys are saved with the scene.

## Layout

```
Apps/IkkokuCreator   SwiftUI app: maker, studio, viewport, document commands
Packages/Engine      CoreMath · Assets (glTF) · Scene (skeleton, IK, camera) ·
                     GPU · Renderer (Metal frame graph) · Character (cards,
                     sliders, materials) · Studio (scene document, gizmos)
Shaders              Metal shaders compiled into IkkokuShaders.metallib
Assets               generated assets + catalog.json (never hand-edited)
Tools/assets         Blender/numpy pipeline that generates Assets/
docs                 RESEARCH.md · PLAN.md · ASSET_SPEC.md
```

## Headless checks

The app can render without a window, which is how the look is verified:

```bash
IKKOKU_AUTOCAPTURE=/tmp/face.png IKKOKU_CAPTURE_PRESET=face IKKOKU_CAPTURE_YAW=20 ./Ikkoku.app/Contents/MacOS/Ikkoku
IKKOKU_AUTOCAPTURE=/tmp/studio.png IKKOKU_CAPTURE_STUDIO=1 ./Ikkoku.app/Contents/MacOS/Ikkoku
IKKOKU_CAPTURE_UI=/tmp/ui.png IKKOKU_CAPTURE_UI_MODE=studio ./Ikkoku.app/Contents/MacOS/Ikkoku
```

Converted static glTF/GLB files can be added with **File → Import Model…**.
**File → Import CharaStudio Object Layout…** imports supported prop/folder
transforms using a converted asset catalog; source material overrides, animation,
cameras and scene settings are not applied. Unmapped items and unsupported object
kinds fail before the document changes. Imported model files remain external
references and must stay available when reopening the native scene.

Inspect an extracted model or original supported scene object section:

```sh
swift run --package-path Packages/Engine ikkoku-inspect model /path/to/model.gltf
swift run --package-path Packages/Engine ikkoku-inspect scene /path/to/source-scene.png
```

**File → Open Source Rig…** opens the neutral rig JSON from the extraction tools.
The Maker preview preserves the full hierarchy and each renderer's skin binding.
Keep `character-shape-contract.json` beside the rig to enable its supported shape
controls, the appearance sidecar for source textures, and
`source-expression-contract.json` for supported expression morphs. Source height
destinations, normal female/male assembly, guarded card colors and edited-card
round trips are implemented. Full animation and arbitrary card-selected asset
reconstruction remain unfinished.
**Use bundled prototype** restores the bundled Maker path. See the
[rig notes](docs/reverse-rigs.md) and [shape contracts](docs/reverse-character.md).

## Licences

Code: MIT. Generated assets derive from CC0 MakeHuman Community assets (see
`Tools/assets/README.md`); the generated files in `Assets/` are CC0.
Locally extracted game files and recovered source in `.local/` are excluded from
version control and from those code/generated-asset license statements.
