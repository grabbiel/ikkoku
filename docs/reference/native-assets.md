# Ikkoku asset contract (v1)

Reviewed 2026-09-25. This contract describes the **bundled generated prototype**,
produced by `Tools/assets/` from locally staged MakeHuman inputs and procedural
content. It is not the original Koikatsu asset format or a universal loader
contract. Source avatars use the separate [rig interchange](character/rigs.md),
[Maker library](character/maker-assets.md) and [Unity conversion](renderer.md).

See the [generation runbook](../../Tools/assets/README.md) for source locations,
prerequisites and commands. Bone/material/morph names below define the native
pipeline conventions; optional entries and the example JSON are not a complete
inventory. The current catalog has 2 bodies, 16 hair styles, 24 garments,
8 accessories and 15 items. The [renderer audit](../component-audit/renderer-and-foundation.md)
tracks packaging and native-loader limitations (R3/R5/R8). How the app finds this
library and the converted ones, and how saved scenes follow a moved library, is in
[Library location and relocation](#library-location-and-relocation-a-t02).

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
Joint names must be unique within a skin. The engine's `Skeleton.from` rejects
duplicate names and sheared Armature or intermediate-node transforms with a
named error; see the
[import contract](renderer.md#checked-math-legacy-skeletons-and-cameras-r4).

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

The restyle is baked into each base mesh. `build_body.py` sets the female
head/eyes/nose/mouth/neck factors to 1.15/1.5/0.65/0.85/0.85, legs to 1.06
and limbs to 0.92. Male factors are 1.12/1.35/0.65/0.9/0.95, legs 1.05 and
limbs 0.95. `deform.py` applies the configured smoothing. Sliders move from
these generated bases; the proportions are not recovered source-game values.

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
vertex attribute `_REGION` with region IDs listed in `catalog.json`. The authoring
attribute is integer; the exported accessor may be FLOAT. The generator can also
write uint8 `.regions.bin` sidecars, but none were present in the audited bundled
assets despite catalog references. Do not assume those optional files are packaged;
R8 tracks regeneration and embedded/sidecar validation.

## Accessories: `Assets/Accessories/acc_<name>.glb`
Static mesh, material `ik_item`, origin at the attach point, +Y up.
`extras.defaultParent = "head"` etc. Provide: `ribbon`, `glasses`, `hat_beret`,
`hairpin`, `headband`, `necklace`, `cat_ears`, `bag`.

## Items (studio props): `Assets/Items/item_<name>.glb`
Static, material `ik_item`; primitives (cube, sphere, cylinder, plane, torus,
stairs), furniture (chair, desk, bed, sofa, table), room shells (classroom,
bedroom, street — simple boxes with windows/doors), sky dome.

## `Assets/catalog.json`

This abbreviated schema illustrates native IDs and paths. The checked-in catalog
and `Catalog.swift` define the implemented optional fields.

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

## Runtime consumption notes

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
* **Catalog metadata and runtime consumers.** Body skin/detail textures, garment
  color/body masks and hide regions, accessory parent/offset and supported texture
  selections have runtime consumers. `hair[].strandUV/chainBones` and
  `textures.eyeWhite` are decoded fields, but current hair material uses mesh/node
  extras, chain discovery inspects the skeleton and eye material uses the fixed
  `eye_white.png` path. Do not treat every decoded field as applied behavior.
* **glTF loader subset.** `GLBLoader` implements no glTF extensions. Any
  `extensionsRequired` entry fails the load; `extensionsUsed` entries are reported.
  It decodes POSITION, NORMAL, TANGENT, TEXCOORD_0–2, COLOR_0, paired
  JOINTS_n/WEIGHTS_n and `_REGION`. Other vertex attributes and morph attributes
  other than POSITION/NORMAL are reported, not decoded. Native materials sample
  base-color/normal textures on UV0 with trilinear REPEAT. `LoadedAsset` rejects a
  drawn texture that selects TEXCOORD_1/2. Other sampler modes,
  metallic-roughness/occlusion/emissive textures and nonzero initial morph weights
  are reported but not applied; `GLTFAsset.initialMorphWeights(ofNode:)` keeps the
  weights. More than four influences are folded to the largest four, with a report.
  Reports are `GLTFAsset.diagnostics` and are appended to `AssetLibrary.log`. The
  app prints that log only at startup and after autocapture; there is no
  interactive view. Bundled assets currently report nothing except the influence
  fold in the two `Assets/fixtures` rigs.
* **Package containment.** Catalog entries are package loads:
  `AssetLibrary.asset(_:)` loads a relative catalog path with
  `GLBLoader.load(url:packageRoot:)` under the asset root (`IKKOKU_ASSETS`, the app
  bundle's resources or the source tree's `Assets/`; `IKKOKU_SOURCE_TREE_FALLBACKS=0`
  disables the source-tree root, see
  [Release packaging](../guides/build-and-test.md#package-and-inspect-a-release-build)). The asset file must resolve inside
  that root after symlinks. Each external buffer/image URI must be a canonical
  relative path after percent-decoding (no scheme or drive, absolute path,
  backslash, NUL, or empty, `.` or `..` segment), and its `realpath` must stay inside
  the root. All references are checked before any external bytes are read; an
  escape fails with `GLTFError.escapesPackageRoot`. `data:` URIs and the GLB `BIN`
  chunk are always allowed. Keep any symlink in the asset tree pointing inside it.
  An absolute path, as recorded in a native scene's `assetFile` after File → Import
  Model, is an explicit user choice and loads through the separately named
  `GLBLoader.loadTrustedFile(url:)`/`AssetLibrary.importTrustedStaticAsset(url:)`
  without containment. The library's PNG texture, sidecar and body-mask reads are
  not glTF references and are not part of this check.

## Library location and relocation (A-T02)

Added 2026-10-23; compiled and unit-tested by CI only, never run in the app.
Code: `ResourceLibrary.swift` and `ResourceRelocation.swift` in the Assets module,
`StudioResourceReferences.swift` in Studio, `EngineHost.swift` and `StudioModel.swift`
in the app; tests: `ResourceRelocationTests.swift`.

**Libraries and their identity.** A `ResourceLibraryRecord` names one library by
kind, absolute root, root-relative manifest, the manifest's SHA-256 and the
manifest's own format version. Two records describe the same content when kind,
manifest path, digest and version agree; the root may differ. The kinds and their
conventional manifests are:

| Kind | Manifest | Accepted format |
| --- | --- | --- |
| `assets` | `catalog.json` in the asset root | integer `version` |
| `makerLibrary` | `maker-library/library.json` | `schemaVersion` 1 |
| `femaleBase` | `rigs/source-avatar.json` | `schemaVersion` 1, kind `koikatsu-female-avatar` |
| `maleBase` | `male/source-male-avatar.json` | `schemaVersion` 1, kind `koikatsu-male-avatar` |

The converted paths are the layout the `Tools/reverse` exporters write under
`.local/reverse/`. Recording a library reads at most 16 MiB (Maker library) or
64 MiB, and the manifest must resolve inside the root after symlinks. A
`ResourceLibraryLocation` is a versioned (`version` 1) set of at most one record per
kind. Another version is refused, not reinterpreted.

**Which libraries are in effect.** File → Choose Converted Library… records every
converted manifest found in the chosen folder. It fails when a manifest present
there is invalid, or when the folder holds none of them. The selection is saved
in user defaults under `ConvertedLibraryLocation`, as a JSON string. Each converted
lookup reads, in order: its explicit variable (`IKKOKU_MAKER_LIBRARY`,
`IKKOKU_SOURCE_AVATAR`, `IKKOKU_SOURCE_MALE_AVATAR`), then the selection, then
the source-tree default under the checkout's `.local/reverse/` (see
[Release packaging](../guides/build-and-test.md#package-and-inspect-a-release-build)).
A selected library that fails to load is an error, not a fallback. The asset root
keeps its own order: `IKKOKU_ASSETS`, then the bundle, then the source tree; the
selection does not change it. At startup the app prints the selection and any
selected manifest whose bytes changed since it was chosen. File → Forget
Converted Library removes the selection.

**What a saved scene records.** On save, `recordingResourceBinding` writes a
`resourceBinding` into the Studio document card. The binding lists, for every
file the document names, the SHA-256 of the file's bytes. For the source scene,
the document's own `sourceSceneSHA256` is used. When the file's realpath lies
inside a library in effect, the binding also records that library's realpath root
and the file's path relative to it. The longest containing root wins. The
binding also keeps the records of the libraries that hold a recorded file. The
file references are `sourceSceneFile`, `sourceVoiceCatalogFile`, an object's
`assetFile`, and every path of a source character reference: scene, rig, bone
catalog, Maker library, attachment, animation, dynamics, hand-pattern and
look-setting files. When a file is missing, unreadable or changed at save time,
the binding keeps the identity it was loaded with, so a save never adopts a
changed file. A document with no file reference gets no binding and saves as
before. Older documents decode it as nil.

**What a load does.** `StudioModel.loadScene` resolves every reference before it
reads anything (`resolvingResources`). A file the binding places in a library
resolves only inside the one library in effect with the recorded content. It
resolves at the recorded relative path, after R5's realpath containment check,
and only when its bytes have the recorded digest. If a different root holds that
library now, the reference is **relocated**: the document's path is replaced
with the verified file. If no library in effect has that content, the file is
checked at its saved path against the same digest. Other file references are
checked at their saved paths, against a digest when one exists. A catalog item
(`itemID` without `assetFile`) must have an entry in the current asset catalog
whose file is inside the asset root. Its catalog ID is its identity, because the
catalog records no digest.

Everything else is **unresolved**, with a named reason:

- a missing file;
- a digest mismatch, naming the expected and actual SHA-256;
- a non-canonical relative path, or a file that resolves outside its root
  through a symlink (even with the right bytes);
- the same content in effect at two roots;
- no asset library in effect, or a catalog with no entry for the ID;
- a binding version this build does not read.

An unresolved reference keeps its saved path, and nothing else is substituted.
Its object is blocked: `refresh()` skips the character or item, plugin attachment
frames and the rehydration rig inputs ignore it, and an `IKKOKU_LOAD_SCENE` or
`IKKOKU_CAPTURE_SCENE` item capture fails naming it. The source scene file keeps
its own hash check in rehydration and export. A blocked voice catalog refuses
playback. The status line shows the summary. One line per unresolved
reference, naming the reference, its recorded SHA-256 and the library it was
saved in, is listed under the inspector's "Source compatibility details" and
printed as `[ikkoku] <scene>: …`. Import Scene… (merge) takes relocated paths and
refuses a scene with an unresolved object reference, because the merge does not
carry its binding.

**Not covered.** Native character card catalog IDs and plugin profile and plugin
library paths ([P-T02](mods/plugin-execution.md)) are not checked. Files a
loader derives from a recorded path are not recorded separately: `ik-bindings.json`
beside the bone catalog, `source-dynamics.json` and the appearance sidecar beside
the rig, and Maker library entries (`SourceMakerLibrary` verifies those against
their own SHA-256s). External glTF buffers and images of an `assetFile` are not
hashed either. A document saved before A-T02 cannot be relocated, because it does
not record which part of a path was its library root. Its paths are checked in
place, unverified apart from the scene digest. The source-scene import still
reads its item catalog and the other conversion inputs from environment
variables. No moved library has been opened in the app yet.
