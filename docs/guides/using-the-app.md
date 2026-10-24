# Using Maker and Studio

Commands and source controls refreshed 2026-10-24. Ikkoku has a bundled native
prototype and an incomplete original-data path. Their card formats, controls and coverage differ. See the
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

Use **File → Choose Converted Library…** to select a prepared local library;
the [build guide](build-and-test.md) documents its manifest and precedence.
Original data must be converted separately and is not included in the app.

Maker discovers `.local/reverse/rigs/source-avatar.json` and its appearance
sidecar. `IKKOKU_SOURCE_AVATAR` overrides the path; missing default content falls
back to bundled assets, while malformed content reports an error. That default is
inside the checkout the app was built from; `IKKOKU_SOURCE_TREE_FALLBACKS=0`
turns it off (see [Release packaging](build-and-test.md#package-and-inspect-a-release-build)). **File → Open
Source Rig…** opens an explicit converted rig. The
[character references](../README.md#character-and-maker) document conversion inputs.

**File → Import Source Card…** reads an original character PNG and rebuilds supported
normal male/female assemblies. Converted coverage includes heads 0/200/201, normal
body correction tables, 52 face and 44 body controls, saved expressions and
static ABMX. Normal male height follows the source fixed value. Special assemblies
and arbitrary mod heads remain unsupported.

Card-selected hair, clothes and accessories require entries in the converted Maker
library. `IKKOKU_MAKER_LIBRARY` selects another `library.json`; `none` disables the
library. Missing entries produce diagnostics. Converted entries are a bounded
subset of the installed catalog, with fixture-specific counts in
[coverage](../reference/character/maker-coverage.md).

Under **Head, hair and clothing**, **Normal head** selects a converted head
0/200/201 while retaining current shape and color edits. Available hair and
clothing rows select converted entries for the current outfit. Preparation is
asynchronous and cancellable; the displayed character stays editable. Export
cancels a pending choice and saves the displayed selections and edits. These
controls do not implement the original head preset's reset behavior or arbitrary
mod-head selection. See the [selection contract](../reference/character/maker-assets.md).

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
kernels exist, but scene loading is incomplete: routes, their non-character
descendants and many original items, lights and scene effects remain unrendered
or unapplied. A character riding a route renders and moves with it but keeps an
unrendered placeholder entry, so its edits are rejected on original export.

With `IKKOKU_STUDIO_ANIMATION_CATALOG` configured, a selected source character
also gets a Source Animation inspector under the Pose tab: pick a catalog entry
via group → category → entry (rows without a converted file are disabled),
adjust speed (0…3) or force-loop, and press Restart to start the selected
character at phase 0. Selecting an animation also starts that character at
phase 0; speed and force-loop changes keep its current phase. Other characters
keep their phase while the shared clock is rebased by baking each character's
evaluated time.

With a converted source character selected, the source inspectors expose:

- **Pose:** supported FK/IK guides and converted animation choices.
- **Face:** source expression patterns, openness, blink/look settings, shape
  controls and supported color edits. Diagnostics identify saved settings whose
  visual/runtime behavior is incomplete; an editable field alone is not full
  expression, lip-sync or material parity.
- **Clothes:** saved outfits, allowed clothing states, indoor/outdoor shoes and
  visibility toggles for loaded accessory slots. The native accessory-name
  adapter supplies labels when mounted; fallback labels remain usable.

These edits use source-specific paths. Prototype-only timeline keyframes and
other unsupported operations remain gated. Selected editing, persistence and GUI
workflows have acceptance evidence; broader mouse-driven regression coverage
remains open in the [Studio audit](../component-audit/studio.md).

**File → Export Edited Original Scene…** writes supported edits to a new source
scene while preserving untouched records, embedded cards, mod identities and
plugin trailers. Unsupported structural changes fail explicitly. This preserves
source bytes; it does not make every retained feature visible or editable. See
[scene editing](../reference/studio/scene-editing.md) for the exact writable fields.

**File → Import CharaStudio Object Layout…** is a separate props/folders-only
conversion using an explicit converted-item catalog. It does not load a full
original scene. See [item conversion](../reference/studio/item-catalog.md).

Previewed original scenes gain route playback controls: selecting a route
object shows a Route Play/Stop button, and a toolbar menu offers Play all
routes (starts the stopped routes), Replay all routes (restarts every route
from its first point at the current time) and Stop all routes. A route that
starts the scene stopped can therefore be played, and a running one stopped,
while scrubbing shows the tween relative to the press instant. These controls
are runtime only: the original export keeps the saved route state, so the
scene's serialized playing/stopped flag never changes.

## Mods and plugins

**Mods → Open Mod Library…** opens a generated `library.json` and selects its
default profile (or `IKKOKU_MOD_PROFILE`); Reload refreshes it after scanning. **Mods → Load Bone Modifiers…** loads a converted ABMX document.
Start with the [mod library guide](mod-library.md). Archive discovery, ID resolution,
converted assets, preserved plugin data and executable native behavior are separate
capabilities.

**Mods → Show Mod Library** includes a **Studio plugins** panel for the mounted
session, whether loaded from a library, direct native package or translated
profile. Use its Run/Pause and Unload controls in Studio. They are disabled in
Maker; **Switch to Studio** returns to the owning mode without discarding the
mounted session. Fresh translated profiles also load through
**Mods → Load Translated Studio Plugins…**; direct native packages use
**Mods → Load Converted Original Plugin…**.

Three exact native adapters are supported: Mute In Background,
StudioAccessoryNames and HideAllUI. HideAllUI's Space shortcut belongs to the
viewport, so typing in a text field does not hide the interface.
**View → Show Studio Interface** provides a recovery command. Adapter support is
pinned to the documented original revisions; arbitrary managed DLLs do not run
in the app. See [native adapters](../reference/mods/native-adapters.md) and
[plugin execution](../reference/mods/plugin-execution.md) for callback, persistence
and acceptance boundaries. A profile that reads a source attachment in its
initializer can load fresh but is still rejected by saved-profile restoration.

## Experimental source rendering

In Studio, **View → Live Source Shaders (Experimental)** enables the translated
source shader path when its converted inputs are available. Toon rendering is
the default. The Studio status lists unsupported materials and their toon
fallbacks; enabling the option does not provide complete character appearance
or scene-effect parity. Material coverage and same-input sampling repeatability
remain active work. See the [renderer reference](../reference/renderer.md) for
required local inputs, supported fixtures and diagnostic versus live evidence.
