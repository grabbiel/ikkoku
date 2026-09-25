# Character Maker rig recovery

Reviewed 2026-09-25. This reference covers the neutral rig format and the first
inspected prefabs. Current assembly and conversion coverage is maintained in
[Maker assets](maker-assets.md), [coverage](maker-coverage.md) and the
[component audit](../../component-audit/character-and-mods.md). Commands run from
the repository root; counts below describe the named source inputs.

The local installation uses Mono and Unity 5.6.2f1 for Character Maker and
CharaStudio. This pipeline reads the original Unity serialization; it does not
run game code or treat managed object layout as a native memory ABI. The native
runtime remains Swift and Metal.

## Recovered inputs

Source bundles and all generated data stay in the ignored `.local/reverse/rigs/`
directory. Every transfer has a SHA-256 sidecar. The sources inspected are:

| Bundle | Observed content |
| --- | --- |
| `chara/oo_base.unity3d` | Maker body skeleton, body and low-detail prefabs, head skeleton, body customization animation data |
| `chara/bo_head_00.unity3d` | Face assembly, separate eye/brow/line meshes, face customization animation data |
| `chara/mm_base.unity3d` | Base material templates |
| `chara/bo_hair_f_06.unity3d` | One front-hair assembly and low-detail variant |
| `chara/co_top_10.unity3d` | Representative clothing assembly and low-detail variant |
| `list/customshape.unity3d` | Body/head customization category tables |
| `list/shapecorrect/shapecorrect.unity3d` | Shape correction table |

The main game's recovered `ChaControl.Load` selects `chara/oo_base.unity3d`.
The Studio assembly instead selects `studio/base/00.unity3d` for its rig.
These are separate inputs; a Studio skeleton should not silently replace the
Maker skeleton.

## Observed rig structure

The high-detail Maker skeleton `p_cf_body_bone` has **580 transform nodes**.
Its standalone head skeleton has 97. The body mesh prefab separately contains
565 nodes. The primary body mesh has 8,302 vertices and a 100-joint skin.
Support nodes, adjustment nodes, and nodes without weights must be preserved;
the complete transform hierarchy and a mesh's skin palette are different arrays.

The representative `p_o_top_suspend_t08` clothing prefab has **539 nodes and two
skinned meshes**, with 2,169 and 1,049 vertices. Each skin has 100 joint references
and 100 inverse bind matrices. All joints resolve inside that prefab, and its node
names are unique. Both skins reference the same ordered joint palette but have
different inverse bind matrices. Their bind-pose check
`inverse(meshWorld) * jointWorld * inverseBind` differs from identity by at most
`9.01e-7` in the recovered rest pose. Both renderers and every ancestor are
serialized as active; clothing-state behavior may subsequently change visibility.

The face prefab has 113 nodes and 18 separate renderers. Its primary face mesh
has 2,695 vertices and 81 blend-shape channels. The eyebrow mesh has 34 channels,
the nose line 73, and the upper eye line 27. These expression blend shapes are
distinct from the category-driven bone adjustment curves used by Maker sliders.
The clothing and sampled front-hair meshes have no blend-shape channels.

The selected normal male body renderer has **101 bone references but 100 inverse
bind matrices**. The strict exporter rejects unequal counts by default. Its
subsequent [male assembly investigation](male.md) established that no vertex
lane indexes the trailing reference; the explicit opt-in below preserves the
original palette audit while retaining only the bind-sized runtime palette.

The default remains strict. An explicit `--allow-unused-trailing-bones` option
now accepts surplus references only when every vertex lane, including zero-weight
lanes, indexes an existing inverse bind. It records the complete original palette
and the omission decision. This was required by the selected T-shirt's unused
state-1 variant (148 references, 100 binds, maximum lane index 58); its normal
state-0 mesh has 148 references and 148 binds. It also supports the verified
normal male body described above. See
[the source avatar report](head-rig.md).

## Neutral rig contract

`Tools/reverse/rig_inventory.py` produces metadata without decoding any image.
An explicitly selected prefab can additionally be exported as a version 1 neutral
JSON document. It contains:

- `coordinateSpace: "unity-left-handed-y-up"`, raw source units and UVs; no basis,
  unit, image-origin, winding, or quaternion conversion has been applied.
- `nodes`: all transforms in parent-before-child order, each with `name`, nullable
  `parent`, `translation`, XYZW `rotation`, `scale`, `active`, and stable source ID.
- `skins`: per-renderer `meshNode`, ordered node indices in `joints`, nullable
  `rootJoint`, and `inverseBindMatrices`, each a flat array of 16 column-major values.
- `meshes`: owning `node` and `skin` indices, `rendererEnabled`, local `positions`,
  `normals`, `tangents`, `uv0` and optional `uv1`/`uv2`, four-slot `joints` and `weights`, submesh indices,
  original morph channels, sparse morph frames, initial blend-shape weights, and
  `hasCloth` so assembly can distinguish Unity Cloth renderers.
- `sources`: input paths, byte lengths, and SHA-256 hashes.

Joint indices in vertex data index the skin's `joints` palette, not the full node
array. Skinning uses each renderer's mesh space. The native coordinate conversion
must apply exactly once to node transforms, geometry, morph deltas, winding,
tangents, and inverse bind matrices. For a Z reflection `C`, matrices become
`C * M * C`. Source body-local Y bounds extend below zero; preserve root transforms
instead of guessing a global centering or centimetre conversion.

The exporter rejects missing/external joints, unapproved mismatched bind counts, invalid
active joint indices, non-unit/negative/nonfinite weights, missing four-slot
influences, malformed triangle indices, and malformed morph ranges. The full
metadata manifest still records unresolved dependencies and mismatches to support
further analysis.

Current local artifacts are `inventory.json`, `shapes-inventory.json`,
`neutral-rig.json` (clothing geometry), `body-skeleton.json` (580 nodes, no mesh),
and `face-skeleton.json` (113 nodes, no mesh), under `.local/reverse/rigs/`.
Customization inputs are under its `textassets/` directory. No recovered asset
belongs in the distributed application or committed asset directory.

## Reproduction

Use the configured Python 3.12 environment with the pinned UnityPy dependency;
the original setup attempt with Python 3.14 could not compile UnityPy 1.23.0.
This is a recorded environment result, not a claim about every Python 3.14 build.
See the [pipeline README](../../../Tools/reverse/README.md)
for VM inventory and fetch setup. Fetch only explicit inputs, for example:

```sh
python3 Tools/reverse/vm_source.py --vm "$IKKOKU_SOURCE_VM" \
  --output .local/reverse/rigs fetch \
  abdata/chara/oo_base.unity3d abdata/chara/mm_base.unity3d \
  abdata/chara/bo_head_00.unity3d abdata/chara/bo_hair_f_06.unity3d \
  abdata/chara/co_top_10.unity3d --max-mib 10

.local/reverse/unitypy-venv/bin/python Tools/reverse/rig_inventory.py \
  .local/reverse/rigs/source/abdata/chara/oo_base.unity3d \
  .local/reverse/rigs/source/abdata/chara/mm_base.unity3d \
  .local/reverse/rigs/source/abdata/chara/bo_head_00.unity3d \
  .local/reverse/rigs/source/abdata/chara/bo_hair_f_06.unity3d \
  .local/reverse/rigs/source/abdata/chara/co_top_10.unity3d \
  --output .local/reverse/rigs/inventory.json \
  --prefab assets/illusion/assetbundle/chara/body/10/co_top_10/p_o_top_suspend_t08.prefab \
  --neutral-output .local/reverse/rigs/neutral-rig.json \
  --extract-shape-textassets .local/reverse/rigs/textassets
```

Use `--skeleton-only` with the exact body or face prefab key to export transforms
without geometry. `--extract-shape-textassets` exports only the known customization
inputs, never textures or unrelated text assets. Source appearance, exact-name
assembly rebinding and bounded hair dynamics now have separate implementations.
This exporter establishes their rig/morph inputs; it does not reconstruct all
Unity components, clothing states or complete Maker behavior.
