# Ikkoku — Research notes on Koikatsu (コイカツ)

Ikkoku is an original, clean-room, SFW re-creation of the *tooling* half of
Illusion's Koikatsu (2018, Unity): the **Character Maker**, the **CharaStudio**
scene/posing tool, and the **cel-shaded anime renderer**. No Illusion assets,
code, or data formats are used. Everything here was reconstructed from public
guides, modding-community documentation, and general toon-shading literature.

## 1. Character Maker (キャラメイク)

The maker is a tabbed editor over a single character "card". Tabs and the
kind of control each one exposes:

| Tab | Sub-groups | Control type |
|-----|-----------|--------------|
| Face | Overall (head width/height/depth, face presets), Jaw/Chin, Cheeks, Eyebrows (shape preset, height, spacing, angle, color), Eyes (shape preset, height, spacing, depth, width, angle, inner/outer corner, eyelid), Iris (preset, size, color L/R, highlight preset + color, pupil), Eyelashes (preset, color), Nose (height, depth, size, angle, bridge, wings, tip), Mouth (height, width, depth, lip thickness, corner), Ears (size, angle, upper/lower shape), Makeup (eyeshadow, blush, lipstick, paint with color/position/size), Mole | Blend-shape sliders (−100…100), preset pickers, color pickers |
| Body | Overall (height, head size, neck thickness/length), Chest (size, height, direction, spacing, shape, softness, weight), Upper body (shoulder width, waist width/depth, back), Lower body (hip width/depth, butt size/angle, belly), Arms (upper/lower thickness, hand size), Legs (thigh, knee, calf, ankle, foot size), Skin (type, tone, gloss, sunburn), Nails, Tattoos/paint | Mixed: **blend shapes** for shape sliders, **bone scaling** for size/length sliders (KK uses `cf_s_*` scale bones; the ABMX mod extends this idea to any bone) |
| Hair | Back, Front (bangs), Side, Extensions (Extra) | Style pickers per part; base/highlight/shadow/outline colors; gloss preset; accessory colors |
| Clothes | 7 outfits (School in/out, Gym, Swimsuit, Club, Casual, Nightwear). Slots: Top, Bottom, Bra, Underwear, Gloves, Pantyhose, Socks, Indoor shoes, Outdoor shoes | Item picker per slot; up to 3 tint colors driven by a **ColorMask** texture; pattern overlay + pattern color; gloss/metallic |
| Accessories | 20 slots | Type category, parent bone attach point, position/rotation/scale offset, colors |
| Parameters | Name, nickname, personality/voice, club, birthday, blood type, traits, hobbies, answers | Profile fields; used by the game half, kept as a "profile" block in Ikkoku |
| Other | Pose preview, eye/mouth expression preview, camera FOV, background | Preview only |

Cards are saved as **PNG files with the character data embedded** in the file
(the thumbnail *is* the card). Studio scenes use the same trick.

## 2. CharaStudio

A scene editor over the same character system:

* **Add**: characters (from cards), items (props grouped by category, and
  "maps" = environments), lights (directional / point / spot), cameras,
  folders, routes.
* **Workspace** tree: parent/child, visibility, lock, multi-select.
* **Object manipulation**: translate/rotate/scale gizmos with axis handles;
  guide objects can be hidden for captures.
* **Character**:
  * Anim: preset animations/poses with speed; "Refer to animation" bakes an
    animation frame into the FK pose.
  * **FK**: rotate joints (grouped: Body, Hair, Neck, Chest, Skirt, Hands/fingers).
  * **IK**: hand/elbow, foot/knee, hip targets; FK and IK can be mixed.
  * Face: eyebrows / eyes / mouth patterns, eye open %, mouth open %, blink
    toggle, gaze modes (front / follow camera / avert / fixed target), tears,
    blush, sweat.
  * Hand gesture presets (open, relaxed, fist, peace, point …).
  * Clothing state per slot (on / half / off) and accessory toggles.
* **Lights**: character light (horizontal/vertical rotation, intensity, color),
  shadow density/color/type, self-shadow toggles, plus scene lights.
* **System > Scene effects**: bloom, depth of field, vignette, fog, color
  grading/ACES, ambient occlusion, sun shafts, shadow type.
* **Camera**: orbit/pan/zoom, FOV, 10 quick-save camera slots (number keys),
  camera objects with look-at targets.
* **Capture**: F11 screenshot (1600×900 default; presets to 4K), optional
  transparent background. Ctrl+S saves the scene as a PNG card.
* Undo/redo.

## 3. Renderer and art style

Koikatsu uses Unity with Shader-Forge–built toon shaders. The properties
modders see (via MaterialEditor / KKBP) tell us how the look is composed:

* **Textures** per material: `MainTex` (albedo), `ColorMask` (RGB = three
  tint zones for clothes), `DetailMask` (R = specular strength, G = shading
  detail / darkening, B = extra line), `LineMask` (drawn inner lines),
  `AlphaMask`, `NormalMap` (subtle), `overtex` overlays (blush, makeup,
  tan lines), hair `HairGloss` band texture.
* **Shading**: 2-tone with a soft terminator. Dark side = base colour ×
  per-material **ShadowColor** (skin shadow is slightly pink/purple, hair
  shadow is hue-shifted). A `ShadowExtend`-style threshold moves the
  terminator. Cast shadows reuse the same dark colour.
* **Specular**: broad soft highlight on skin (`SpecularPower`,
  `SpecularHeight`), stepped highlight on cloth, anisotropic "angel ring"
  highlight band on hair.
* **Rim**: `rimpower`, `rimV`, `rimS` — a fresnel rim masked toward the light.
* **Outline**: inverted-hull outline with `OutlineWidth` and `OutlineColor`
  (dark, hue-related to base), width modulated per vertex.
* **Eyes**: separate meshes for eye white (with a shadow gradient from the
  upper lid), iris (`MainTex`, expression/pupil overlays), highlights
  (`hitomi`), eyeline up/down and eyelashes as textured strips, eyebrows as
  a separate textured mesh drawn on top.
* **Post**: bloom, DoF, vignette, colour grading; soft ambient; the palette is
  pastel with high-key lighting.
* Character rig naming for reference: `cf_j_*` joint bones, `cf_d_*` dynamic
  (breasts `cf_j_siri_L/R` etc.), `cf_s_*` scale bones; face bones are used
  for structure sliders rather than posing.

## 4. What Ikkoku keeps, changes, and drops

* Keeps: tabbed maker with slider/preset/color model; PNG cards; studio with
  tree, gizmos, FK/IK, expressions, lights, camera slots, capture, PNG scenes;
  the two-tone toon look with outlines, rim, hair band, eye system.
* Changes: original CC0-derived base meshes (MakeHuman hm08 lineage, restyled
  to anime proportions), original textures generated procedurally, readable
  bone names, JSON-in-PNG cards, native macOS UI (SwiftUI + Metal).
* Drops: all adult content, the dating-sim game, voice/personality audio.

## Sources

* [Koikatsu CharaStudio Quickstart Guide (RenaiKatsudou)](https://www.deviantart.com/renaikatsudou/art/Koikatsu-CharaStudio-Quickstart-Guide-1310243203)
* [Getting to know Koikatsu's Chara Studio (Rice Digital)](https://ricedigital.co.uk/koikatsu-chara-studio/)
* [Making a mascot in Koikatsu Party (Rice Digital)](https://ricedigital.co.uk/make-a-mascot-in-sex-game-koikatsu/)
* [KKABMX / ABMX bone slider mod](https://github.com/ManlyMarco/ABMX)
* [KK_Plugins (MaterialEditor, shader names)](https://github.com/IllusionMods/KK_Plugins)
* [KK Blender Porter Pack (shader reconstruction, mask naming)](https://github.com/FlailingFog/KK-Blender-Porter-Pack)
* [Porting Koikatsu to SFM (bone prefixes)](https://open3dlab.com/tutorials/view/109/)
* [Illusion.SceneEffectExtended (scene effects list)](https://github.com/krypto5863/Illusion.SceneEffectExtended)
* [Unity Toon Shader docs (rim/shade layers)](https://docs.unity3d.com/Packages/com.unity.toonshader@0.8/manual/Rimlight.html)
* [MakeHuman CC0 assets](https://github.com/makehumancommunity/makehuman)
