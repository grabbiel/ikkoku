# Ikkoku asset contract (v1)

Everything the engine loads is produced by scripts under `Tools/assets/`
(Blender 5.1 headless + numpy + Pillow). Sources: the CC0 MakeHuman-derived
GLBs in `~/Downloads/eight-human-models/models` (copy the ones you use into
`Tools/assets/source/` — they are git-ignored). Never use the paid
"Customisable Basemesh" addon meshes.

## Conventions
* glTF 2.0 binary (`.glb`), **meters, Y up, character faces +Z**, origin on the
  floor between the feet. Triangles only. One skin per file.
* Blender export settings: `export_format='GLB'`, `export_yup=True`,
  `export_skins=True`, `export_morph=True`, `export_morph_normal=False`,
  `export_try_sparse_sk=True`, `export_apply=True`, `export_image_format='AUTO'`,
  `export_texcoords=True`, `export_normals=True`, `export_tangents=True`,
  vertex colors exported when present (`export_vertex_color='ACTIVE'` or
  equivalent for the running exporter).
* Mesh/material/bone names are stable identifiers; the engine matches them
  by name. Keep them exactly as below.
* Textures are PNG (or JPEG for photo-like maps) ≤ 2048², sRGB for colour,
  linear for masks. Colour that is meant to be tinted at runtime is stored
  near white in the texture; the tint is a material factor.

## Skeleton (all body/hair/cloth files share it)
Bone names (left side shown, mirror with `_R`). Rest pose = A-pose as in the
source mesh. Bone +Y points from head to tail (Blender convention).

```
root
└ hips
  ├ spine01 ─ spine02 ─ spine03(chest)
  │   ├ neck ─ head ─ head_top(end)
  │   │        ├ eye_L / eye_R          (gaze; parented to head, origin at eyeball centre)
  │   │        └ jaw                    (optional)
  │   ├ bust_L / bust_R                 (child of spine03; origin at breast centre)
  │   └ shoulder_L ─ upperarm_L ─ forearm_L ─ hand_L
  │                                     ├ thumb01_L ─ thumb02_L ─ thumb03_L
  │                                     ├ index01_L ─ index02_L ─ index03_L
  │                                     ├ middle01_L ─ middle02_L ─ middle03_L
  │                                     ├ ring01_L ─ ring02_L ─ ring03_L
  │                                     └ pinky01_L ─ pinky02_L ─ pinky03_L
  └ thigh_L ─ calf_L ─ foot_L ─ toes_L
```
Weights: max 4 influences per vertex, normalised. Bone placement is derived
from the mesh (slice centroids), verified by a render with bones drawn.

## Body files: `Assets/Characters/body_f.glb`, `body_m.glb`
Meshes (separate glTF meshes, all skinned to the skeleton above):

| Mesh name | Material name | Notes |
|-----------|---------------|-------|
| `body` | `ik_skin_body` | Whole body incl. head; ~20–30k tris; UV from source |
| `eye_L`, `eye_R` | `ik_eye` | Eyeball spheres; iris UV centred; weighted 100% to `eye_L`/`eye_R` |
| `eyewhite_L`, `eyewhite_R` | `ik_eyewhite` | Optional if the eyeball mesh has separate sclera UVs; otherwise omit |
| `eyelash` | `ik_eyelash` | Textured strips, alpha-tested |
| `eyebrow` | `ik_eyebrow` | Textured strips, drawn over hair (engine handles) |
| `teeth`, `tongue` | `ik_mouth` | Optional |

Morph targets live on `body` (`extras.targetNames`). Range −1…1 means the
engine applies `weight = slider/100`; negative values use the same delta
mirrored, so author each target for the +1 direction only. Prefix groups:

```
face.head_width face.head_height face.upper_depth face.lower_depth
face.jaw_width face.jaw_height face.jaw_depth face.chin_height face.chin_width face.chin_depth
face.cheek_width face.cheek_height face.cheek_depth
eye.size eye.height eye.spacing eye.depth eye.angle eye.width eye.outer_height eye.inner_height
eye.lid_upper eye.lid_lower
nose.height nose.depth nose.size nose.angle nose.bridge_height nose.bridge_width nose.wing_width nose.tip_height
mouth.height mouth.width mouth.depth mouth.lip_upper mouth.lip_lower mouth.corner_height
ear.size ear.angle ear.upper ear.lower
body.bust_size body.bust_height body.bust_spacing body.bust_softness
body.waist_width body.waist_depth body.belly body.back
body.hip_width body.hip_depth body.butt_size
body.shoulder_width body.neck_thickness
body.upperarm_thickness body.forearm_thickness body.thigh_thickness body.calf_thickness
exp.blink_L exp.blink_R exp.eye_wide exp.eye_smile exp.squint
exp.brow_up exp.brow_angry exp.brow_sad
exp.mouth_a exp.mouth_i exp.mouth_u exp.mouth_e exp.mouth_o exp.smile exp.frown exp.mouth_open
```
Eye meshes carry `eye.size` and `eye.spacing`/`eye.height`/`eye.depth` too
(or rely on the `eye_*` bones: the engine translates/scales those bones for
these four sliders — pipeline must place `eye_L/R` bone origins at the
eyeball centres so that works). Bone-driven sliders (no morph needed):
height, head size, neck length, torso length, arm/leg length, hand/foot
size, bust size (bust bones scale, in addition to the morph).

Default "anime" restyle is baked into the base mesh: head ×1.15, eyes ×1.5
(sockets + eyeballs), nose ×0.6, mouth ×0.85, neck ×0.85 thickness,
legs +6% length, smoothed face (2 iterations Laplacian on face region),
limbs slimmed 8%. Sliders then move away from that base.

### Textures (in `Assets/Textures/`)
* `skin_f_base.png` / `skin_m_base.png` (2048²): near-white skin with soft
  baked shading (AO-like), navel, knees, subtle collarbone; tinted at runtime.
* `skin_f_detail.png`: R = specular mask, G = shading detail (1 = normal, <1 darkens), B = line mask (drawn lines: under-bust, collarbones, ankles).
* `face_overlay_blush.png`, `face_overlay_eyeshadow.png`, `face_overlay_lip.png`
  (1024²): alpha masks in body UV space at the cheek / eyelid / lip regions.
* `eye_iris_<n>.png` (512²): anime iris variants (gradient, pupil, ring).
  `eye_highlight_<n>.png`: highlight shapes (alpha). `eye_white.png`: sclera with
  upper shadow gradient. `eyelash_<n>.png`, `eyebrow_<n>.png`: alpha strips.
* Cloth: `pattern_<name>.png` (tiling, 512²): plain, stripes, plaid, dots, lace.

## Hair: `Assets/Hair/hair_<style>.glb`
Mesh `hair`, material `ik_hair`. Skinned: all vertices to `head` (bangs/side)
and optionally a chain `hair_back_01…n` under `head` for long back hair.
UVs: **u across the strand, v from root (0) to tip (1)** so the engine can
draw the highlight band. Vertex colour alpha = outline width multiplier
(1 default; 0 at tips). Provide at least: `bob`, `long_straight`, `ponytail`,
`twintails`, `short_m`, `messy_m`. Each style is one file; parts may be
split into `hair_front`, `hair_back`, `hair_side` meshes inside it.

## Clothes: `Assets/Clothes/<slot>_<name>.glb`
Slots: `top`, `bottom`, `bra`, `underwear`, `gloves`, `pantyhose`, `socks`,
`shoes_in`, `shoes_out`. Mesh `<slot>`, material `ik_cloth`. Skinned to the
body skeleton (copy weights from the body by nearest surface point).
`ColorMask` texture named `<file>_cm.png`: R/G/B = tint zones 1/2/3.
Vertex colour alpha = outline width multiplier. Provide v1 set:
`top_sailor`, `top_blazer`, `top_tshirt`, `top_shirt_m`, `bottom_skirt_pleated`,
`bottom_shorts`, `bottom_trousers_m`, `socks_knee`, `socks_ankle`,
`shoes_in_loafers`, `shoes_out_sneakers`, `gloves_short`, `pantyhose_black`,
`bra_plain`, `underwear_plain`. A garment that hides body skin declares
`extras.hideBody = [region names]` from: `torso_upper, torso_lower, upperarm_L/R,
forearm_L/R, hand_L/R, thigh_L/R, calf_L/R, foot_L/R`. The body mesh has a
vertex attribute `_REGION` (uint8) with region ids listed in `catalog.json`.

## Accessories: `Assets/Accessories/acc_<name>.glb`
Static mesh, material `ik_item`, origin at the attach point, +Y up.
`extras.defaultParent = "head"` etc. Provide: `ribbon`, `glasses`, `hat_beret`,
`hairpin`, `headband`, `necklace`, `cat_ears`, `bag`.

## Items (studio props): `Assets/Items/item_<name>.glb`
Static, material `ik_item`; primitives (cube, sphere, cylinder, plane, torus,
stairs), furniture (chair, desk, bed, sofa, table), room shells (classroom,
bedroom, street — simple boxes with windows/doors), sky dome.

## `Assets/catalog.json`
```json
{ "version": 1,
  "regions": {"torso_upper":1, "...":2},
  "bodies":  [{"id":"body_f","sex":"f","file":"Characters/body_f.glb"}],
  "hair":    [{"id":"bob","file":"Hair/hair_bob.glb","sex":"any","name":"Bob"}],
  "clothes": [{"id":"top_sailor","slot":"top","file":"Clothes/top_sailor.glb","sex":"f","name":"Sailor top","colors":["Main","Collar","Ribbon"]}],
  "accessories":[{"id":"ribbon","file":"Accessories/acc_ribbon.glb","parent":"head","name":"Ribbon"}],
  "items":   [{"id":"chair","file":"Items/item_chair.glb","category":"Furniture","name":"Chair"}],
  "textures":{"iris":["eye_iris_0.png","..."],"highlight":[],"eyebrow":[],"eyelash":[],"patterns":[]}
}
```

## Verification
`Tools/assets/verify.py` renders each body (front/side, with bones), each hair
and garment on the body, and a morph-target contact sheet to
`Tools/assets/out/verify/*.png`. Review these before handing assets over.

## Addenda (2026-09-09)

* **Body coverage.** The engine hides body vertices under worn garments by
  itself (`BodyCoverage.swift`: a body vertex is hidden when it lies just behind
  a garment surface with a similar normal and more than ~3 cm from any open
  garment edge). Optional pipeline masks `Clothes/<file>_bm.png` (body UV
  space, white = hidden) are read when `CharacterInstance.preferPipelineMasks`
  is on; `hideBody` regions remain a coarse fallback.
* **Hair chains.** Extra bones in a hair file (any bone not in the body
  skeleton, e.g. `hair_back_01…n`) are appended to the character skeleton at
  runtime under the slot prefix `back/`, `front/`, `side/`, `extra/` and driven
  by a spring simulation. Each chain must hang from `head` (or another body
  bone) and use +Y as the bone axis.
* **Mouth parts.** `teeth`/`tongue` are drawn only when a mouth-opening morph
  is active and are pinned to `head`.
* **Catalog fields the engine reads.** `bodies[].textures.skinBase/skinDetail`,
  `hair[].strandUV/chainBones`, `clothes[].colorMask/bodyMask/hideBody/colors`,
  `accessories[].parent/offset`, `textures.iris/highlight/eyeWhite/eyebrow/
  eyelash/patterns/faceOverlays/hairStrand`.
