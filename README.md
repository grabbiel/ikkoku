# Ikkoku

A native macOS (Swift 6 + Metal) character maker, posing studio and cel-shaded
renderer in the spirit of Koikatsu's Character Maker and CharaStudio. Everything
is original: CC0 MakeHuman-derived base meshes restyled to anime proportions,
procedurally generated textures, hair, clothes and props, and a Metal toon
pipeline (two-tone shading, inverted-hull outlines, anisotropic hair band,
layered eyes, PCF shadows, bloom/FXAA).

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

## Licences

Code: MIT. Generated assets derive from CC0 MakeHuman Community assets (see
`Tools/assets/README.md`); the generated files in `Assets/` are CC0.
