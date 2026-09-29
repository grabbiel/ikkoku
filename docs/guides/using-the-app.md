# Using Maker and Studio

Reviewed 2026-09-25. Ikkoku has a bundled native prototype and an incomplete
original-data path. Their card formats, controls and coverage differ. See the
[feature audit](../component-audit/README.md) for exact completion status and the
[build guide](build-and-test.md) to launch the app.

## Bundled Maker

Maker (⌘1) exposes Face, Body, Hair, Clothes, Accessories and Profile tabs. Its
sliders combine native morphs and bone adjustments; these are not the original
96 source controls. Use Full/Upper/Face camera presets (B/U/F), left-drag to orbit,
right-drag or ⇧-drag to pan, and scroll to zoom. Native characters support idle
motion, expressions, gaze and hair spring motion.

⌘S saves a native character PNG card; ⌘O opens one. The PNG thumbnail carries
Ikkoku JSON in an `iTXt` chunk. ⇧⌘T sends a bundled character to Studio. Choose
**Use bundled prototype** when Maker has automatically opened local original data.

## Original Maker and cards

Maker discovers `.local/reverse/rigs/source-avatar.json` and its appearance
sidecar. `IKKOKU_SOURCE_AVATAR` overrides the path; missing default content falls
back to bundled assets, while malformed content reports an error. **File → Open
Source Rig…** opens an explicit converted rig. The
[character references](../README.md#character-and-maker) document conversion inputs.

**File → Import Source Card…** reads an original character PNG and rebuilds supported
normal male/female assemblies. Converted coverage includes heads 0/200/201, normal
body correction tables, 52 face and 44 body controls, saved expressions and
static ABMX. Normal male height follows the source fixed value. Special assemblies
and arbitrary mod heads remain unsupported.

Card-selected hair, clothes and accessories require entries in the converted Maker
library. `IKKOKU_MAKER_LIBRARY` selects another `library.json`; `none` disables the
library. Missing entries produce diagnostics. The reviewed fixture covers 15
drawable selections and 11 empty entries, not the whole installed catalog. See
[coverage](../reference/character/maker-coverage.md).

In **Card appearance**, select an outfit, change supported colors and use **Apply
colors**. Pattern/makeup recipes apply supported saved selections; there is no
complete original asset-selection editor. **File → Export Edited Source Card…**
writes a new original-format PNG with refreshed thumbnails, supported shape/color
edits, preserved unknown fields, original asset/mod identities and untouched
outfits. See [card appearance and export](../reference/character/card-appearance.md).

Source expression controls include presets, eye/mouth openness and automatic
blinking. Converted data can enable original idle/hair-motion controls; selected
asset replacement currently disables Maker dynamics. Full source expression/voice
integration and sending this source preview directly to Studio remain unfinished.

## Native Studio

Studio (⌘2) provides an object tree, transforms (T/R/S, Local/World), native FK/IK,
pose presets, expressions, clothing states, lights, camera slots and screen effects.
Keys 1–0 load camera slots; ⇧1–0 save them. The timeline supports playback/scrubbing
and native key storage (K); saved native scenes retain these keys. These prototype
features do not establish equivalent support on original scene objects.

Save native scene PNG cards with ⌥⌘S, open with ⇧⌘O and capture with ⇧⌘P.
**File → Import Model…** loads supported external glTF/GLB models. Native scenes
retain external file references, so referenced files must remain available.

## Original Studio scenes

**File → Preview CharaStudio Scene…** parses supported source scenes, reconstructs
selected character appearances, applies supported shape/static ABMX/expression/FK
state and restores current/saved cameras. Original attachment and animation/IK
kernels exist, but scene loading is incomplete: routes and their descendants and
many original items, lights and scene effects remain unrendered or unapplied.

The current UI gates all source Pose/Face/Clothes inspectors, including implemented
source guide controls and accessory labels. Full-body IK and guide editing can be
exercised through engine/capture paths; do not expect those inspectors to be
interactive yet. Some prototype controls also write fields unused by source
characters. Follow ST-T01 in the [Studio audit](../component-audit/studio.md).

**File → Export Edited Original Scene…** writes supported edits to a new source
scene while preserving untouched records, embedded cards, mod identities and
plugin trailers. Unsupported structural changes fail explicitly. This preserves
source bytes; it does not make every retained feature visible or editable. See
[scene editing](../reference/studio/scene-editing.md) for the exact writable fields.

**File → Import CharaStudio Object Layout…** is a separate props/folders-only
conversion using an explicit converted-item catalog. It does not load a full
original scene. See [item conversion](../reference/studio/item-catalog.md).

## Mods and plugins

**Mods → Open Mod Library…** opens a generated `library.json` and selects its
default profile (or `IKKOKU_MOD_PROFILE`); Reload refreshes it after scanning. **Mods → Load Bone Modifiers…** loads a converted ABMX document.
Start with the [mod library guide](mod-library.md). Archive discovery, ID resolution,
converted assets, preserved plugin data and executable native behavior are separate
capabilities.

Bounded translated plugins and two exact native adapters exist. Arbitrary managed
DLLs do not execute in the app. The Mute adapter's headless startup crash is fixed
and passed Release mount/save/reload and focus-gain acceptance. The source inspector gate
hides accessory-name controls. See
[plugin execution](../reference/mods/plugin-execution.md) for supported callbacks,
installation paths and the remaining integration work.
