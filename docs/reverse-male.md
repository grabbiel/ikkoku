# Original normal male assembly

The native Maker can use the installed game's normal male body with the same
observed assembly rules as the female body. The recovered `ChaControl.LoadAsync`
selects `p_cf_body_bone` and `p_cf_head_bone` for both sexes. For `sex=0`,
`exType=0`, the body geometry comes from `p_cm_body_00`. The normal head still
uses category 100 and the selected head ID; the recovered preset uses head 00.
Special male models (`exType=1`) take different loading paths and are excluded.

`Tools/reverse/male_avatar.py` creates the local male manifest and appearance
sidecar from hash-verified bundles and the existing shared head/clothing exports.
It reads the installed `UserData/chara/male/ill_male_01.png` as binary card records
only. It does not decode either of that card's thumbnails. The original 44 body
values and 52 face values become the male shape-contract defaults. The original
card remains available as `default-male-card.png`, referenced by `defaultCard` in
the avatar manifest. Its source bytes remain unchanged.

The selected preview is explicitly clothed:

| Component | Source identity |
| --- | --- |
| Main male body | `p_cm_body_00`, only `o_body_a` |
| Head | Shared `p_cf_head_00`, neutral-expression mesh selection |
| Very short back hair | Category 101 / ID 9, `p_cf_hair_b_33` |
| Front hair | Category 102 / ID 5, `p_cf_hair_f_05` |
| T-shirt | Category 105 / ID 38, `p_o_top_tsyatu02` |
| Long trousers | Category 106 / ID 3, `p_o_bot_pants03` |
| Running shoes | Category 112 / ID 3, `p_o_shoes_run01` |

The male body contains 6,823 vertices. Its renderer has 101 serialized bone
references and 100 inverse binds; every original four-lane mesh joint index is
at most 97. The exporter explicitly permits only the verified unindexed trailing
reference and records all 101 original references in `sourcePaletteAudit`.
Neither vertex indices nor original inverse-bind matrices are changed. Alternative,
private, silhouette and shadow-caster source meshes are not selected for preview.

The assembled avatar has 761 retained nodes, 18 mesh parts and 31,278 vertex
entries. The upper eyeline's second material pass produces 19 native render items.
Male body evaluation uses the original sex-dependent correction, including the
0.91 head/neck size factor, rather than treating the male mesh as a female preset.

The original male card supplies the shape and hair preset. Its full outfit and
face material selections differ from the explicit reference selection above.
Those original selections remain in the source card; unsupported appearance IDs
produce compatibility diagnostics. This is not complete reconstruction of that
card's appearance. Hair albedo uses the verified original shader formula and
original card colors; original hair lighting and dynamic simulation remain
separate work.

## Reproduction and verification

All recovered assets, original cards, generated presets and evidence stay in
ignored `.local/reverse/male/`.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/male_avatar.py
.local/reverse/unitypy-venv/bin/python Tools/reverse/test_avatar_parity.py \
  --avatar .local/reverse/male/source-male-avatar.json \
  --contract .local/reverse/male/character-shape-contract.json \
  --output .local/reverse/male/avatar-parity-report.json
python3 Tools/reverse/analysis/body_shape_contract.py \
  --rig .local/reverse/male/body-skeleton.json \
  --contract .local/reverse/male/character-shape-contract.json \
  --output .local/reverse/male/body-reference
.local/reverse/unitypy-venv/bin/python Tools/reverse/test_male_body_parity.py
```

Six rest/face cases independently rebuild the source hierarchy, copy head locals,
rebind exact bone names, preserve inverse binds and skin in source coordinates.
All passed, with maximum absolute error `5.44e-7` in matrices and `5.78e-7` in
vertices. These checks compare every retained node and selected vertex, not just
finite values.

The complete recovered C# body oracle also passes all 844 cases with the male
preset/skeleton, including each body slot, corrections, update masks and
`UpdateAlways`. `test_male_body_parity.py` extends this to assembled mesh vertices
for the original male preset, all 44 individual body slots at both extrema and
two mixed cases. All 91 cases passed, with maximum matrix error `2.13e-6` and
vertex error `5.96e-7`. The private reports record the exact inputs and native executable.

Set `IKKOKU_SOURCE_MALE_AVATAR` to the absolute local manifest path when running
`SourceMaleAvatarTests`. These two optional tests check original preset identity,
clothed mesh selection, all finite deformed vertices and a complete native Metal
frame. Four extractor tests cover normal/special identity checks, catalog ambiguity
and source bundle integrity. See [card appearance](reverse-card-appearance.md)
for original-card color recipe generation.
