# Source head rig and clothed assembly

Reviewed 2026-09-25. This reference retains the head-00 attachment investigation
and its recorded numerical comparisons. Additional supported heads and
card-selected parts are described in [Maker assets](maker-assets.md) and
[coverage](maker-coverage.md). Feature status and remaining work are in the
[component audit](../../component-audit/character-and-mods.md). Commands run from
the repository root.

The assembly described here uses the locally installed `p_cf_head_00` geometry and its source
customization data. Extracted geometry, source code, images and reports remain
under the ignored `.local/reverse/` directory.

## Head geometry

`head-rig.json` comes from `chara/bo_head_00.unity3d`, exact container key
`assets/illusion/assetbundle/chara/head/00/bo_head_00/p_cf_head_00.prefab`.
It contains 113 transform nodes, 18 skinned meshes, 19 submeshes, 6,795 vertices,
11,944 triangles and 491 expression morph channels. The largest palette has
54 joints. Every joint resolves inside the source prefab, node names are unique,
and every serialized initial morph-weight array is empty. All local scales are
positive. Three special eye mesh nodes are inactive; all other mesh nodes and
renderers are serialized as active. Runtime expression visibility is separate.

Independent source-space matrix evaluation finds most authored rest palettes
within `2.94e-7` of identity. The canine and tooth palettes instead have a maximum
residual of `0.0040000002`; the three tear palettes have `0.0147618293`. These are
source rest adjustments, not a reason to replace the original inverse binds.
The source matrices and adjustments are preserved. The local
`head-bind-report.json` records every mesh and its residual.

The head skeleton is a separate source prefab, `p_cf_head_bone`, in
`chara/oo_base.unity3d`. It has 97 nodes and is exported as
`head-bone-skeleton.json`. The 113-node `face-skeleton.json` is the hierarchy
inside the head mesh prefab and must not be mistaken for the separate skeleton.

## Source attachment behavior

The recovered main-game `ChaControl.Load` and `ChangeHeadAsync` establish this
assembly order:

1. Instantiate `p_cf_body_bone`. Its `cf_j_root` subtree supplies the body bone
   dictionary. The `cf_t_root` sibling and other support nodes stay present.
2. Instantiate `p_cf_head_bone` under `cf_s_head` using `SetParent(false)`.
   `ChaReference` identifies `cf_s_head` as `HeadParent`.
3. Load the selected head mesh prefab. `CommonLib.CopySameNameTransform` copies
   local position, rotation and scale **from the mesh prefab to the separate head
   skeleton** for matching names.
4. Parent the head mesh under the head skeleton using `SetParent(false)`. Rebind
   every mesh bone by its exact name to the head skeleton, then remove the mesh
   prefab's original `cf_J_N_FaceRoot` subtree.
5. Parent body and clothing prefabs under the character's `objTop`. Rebind their
   skin palettes to the body dictionary by exact bone name, then remove their
   original `cf_j_root` subtrees. `AssignedAnotherWeights` leaves mesh inverse
   binds unchanged. Missing names produce null source references; the native
   implementation rejects a missing mapping rather than inventing one.
6. Hair uses its own skeleton and `copyWeights=0`. Parent each hair prefab under
   `cf_J_FaceUp_ty`, which `ChaReference` identifies as `HairParent`.

The body mesh and selected clothes have identity prefab roots. Their separate
`cf_o_root` geometry branches have local Y `1.1434999704360962`; preserve this
offset. All selected body/clothing joint names resolve in the 580-node body
skeleton, and every head joint name resolves in the 97-node head skeleton.

## Fully clothed source selection

The local MessagePack catalog `abdata/list/characustom/00.unity3d` supplies exact
IDs and bundle names. Only the selected bundles were transferred and verified
against source SHA-256 hashes. `clothed-catalog.json` and
`clothed-export-summary.json` retain the catalog and export evidence.

| Part | Category / ID | Source prefab | Local neutral export |
| --- | --- | --- | --- |
| Plain T-shirt | 105 / 38 | `p_o_top_tsyatu02` | `top-rig.json` |
| Long pants | 106 / 3 | `p_o_bot_pants03` | `bottom-rig.json` |
| Running shoes | 112 / 3 | `p_o_shoes_run01` | `shoes-rig.json` |
| Bob back hair | 101 / 2 | `p_cf_hair_b_03` | `hair-back-rig.json` |
| Straight front hair | 102 / 1 | `p_cf_hair_f_01` | `hair-front-rig.json` |

The top's source default clothing state enables `n_top_a` and disables
`n_top_b`. Both are serialized active in the prefab, so runtime state must be
applied. `ChaReference` maps these to `S_CTOP_T_DEF` and `S_CTOP_T_NUGE`, and
`ChaControl` enables them for clothing states 0 and 1 respectively. The fully
clothed preview uses state 0. The top catalog identifies body alpha mask
`cf_tsyatu01_body_mab` in `chara/mt_mask_body_00.unity3d`.

`body-rig.json` retains the technical source prefab. That prefab also contains
alternative and anatomy-specific renderers which the game controls at runtime.
The clothed preview selects only `o_body_a`, its main 8,302-vertex body mesh, and
uses the complete top, long pants and shoes. Raw prefab active flags alone do
not define a suitable assembled preview.

`source-avatar.json` selects these components explicitly. Its head selection
also applies the neutral expression state: `ChaFileStatus` initializes
`tearsLv=0`, and the recovered `ChaControl` tear table disables all three tear
objects for that value. The three serialized inactive special eye meshes are
excluded. All 34 renderers inspected across the source components have no
Unity `Cloth` component. The source non-Cloth root-bone rule therefore applies.

Eight exact source textures are available under `clothed-materials/`: three
catalog-selected diffuse images, their three color masks, and two hair color
masks. The accompanying manifest records bundle and PNG hashes, dimensions,
source IDs, image origin and original clothing component colors. These are
raw inputs at this extraction stage; [card appearance](card-appearance.md) and
[material expansion](material-expansion.md) subsequently compose supported
colors and layers. The source
materials have null `_MainTex` values because the game composes them at runtime.
The selected shirt body mask is separate, `top-body-alpha-mask.png`; its red and
green channels vary while blue is zero and alpha is opaque. Source clothing
state 0 sets both `_alpha_a` and `_alpha_b` to one.

The top's normal mesh has 148 joints and 148 binds. Its unused state-1 mesh has
148 renderer references but only 100 binds. Every one of its four joint lanes
is within `[0, 99]`, with maximum 58. Exporter option
`--allow-unused-trailing-bones` permits only this explicitly verified condition:
it keeps the bind-sized native palette and preserves every original reference,
the original and retained counts, and the maximum lane index in
`sourcePaletteAudit`. It never pads missing binds or omits an indexed reference.
The default exporter still rejects unequal counts. Five boundary tests cover
the opt-in, default rejection, missing binds and all-lane validation.

## Independent face verification

`Tools/reverse/test_face_rig_parity.py` parses all 59 setter blocks directly from
the locally recovered `ShapeHeadInfoFemale.Update` C# source. It does not read
the Swift face implementation or its generated operation list. It evaluates
all 52 category slots using source sample order, masked assignment and angular
interpolation, then builds Unity ZXY rotation matrices in float64. Skinning is
evaluated directly in source world space before the native Z reflection.

The comparison covers all 113 node matrices and every imported head vertex,
including source-inactive parts. Cases include authored rest, source defaults,
all slots at 0, 0.37, 0.5 and 1, mixed rates, and each individual slot at both
extremes: 111 cases total. This verifies standalone `boneType=0` geometry and
transform behavior. It does not claim material, GPU, expression morph or
complete character animation parity.

In the recorded head-00 run, all 111 cases passed. Maximum absolute error was `5.44e-7` in node matrices and
`4.24e-8` in head vertex coordinates. The local `face-parity-report.json`
records each case and the exact native executable and input hashes.

`test_avatar_parity.py` additionally reconstructs the original separate body,
head and hair hierarchy transforms, applies the observed source attachment and
bone-name rebinding, and skins directly from those source worlds and inverse
binds. The recorded six assembled rest/face cases passed across 774 retained nodes, 21 parts
and 37,414 vertex entries. Maximum absolute errors were `5.44e-7` for matrices
and `6.14e-7` for vertices. `avatar-parity-report.json` records the executable,
input and recovered attachment-helper hashes. Appearance and GPU behavior are
outside this numerical check.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/test_rig_inventory.py
.local/reverse/unitypy-venv/bin/python Tools/reverse/test_face_rig_parity.py
.local/reverse/unitypy-venv/bin/python Tools/reverse/test_avatar_parity.py
```

For source bind inspection before a native executable is available:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/test_face_rig_parity.py \
  --reference-only --output .local/reverse/rigs/head-bind-report.json
```
