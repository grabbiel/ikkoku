# Maker catalog asset library

Reviewed 2026-09-25 against `SourceMakerLibrary` and the current local registry.
This is a working, partial selection loader. See [bounded coverage](maker-coverage.md)
for denominators and the [component audit](../../component-audit/character-and-mods.md)
(CM-16–19; CMT-01–03, CMT-07 and CMT-09) for remaining work. Commands run from
the repository root; reported audits below are recorded evidence.

`Tools/reverse/maker_asset_library.py` exports an explicit selection from the
installed original Maker catalogs into an ignored local library. The native
loader resolves each card selection by category, ID and optional mod GUID. An
unresolved selection must remain visible as a diagnostic and must not change the
card's saved identity.

The current generated library is
`.local/reverse/maker-library/library.json`. It contains 15 drawable entries:

| Category | Original IDs | Recovered selection |
| --- | --- | --- |
| 101, back hair | 0, 2, 9 | Three original hairstyles, including the normal male preset |
| 102, front hair | 1, 2, 5 | Three original front styles |
| 105, top | 3, 13, 38, 39 | Original T-shirt variants and normal male T-shirt |
| 106, bottom | 3, 25 | Original long trousers and loose long trousers |
| 112, shoes | 1, 3 | Loafers and trainers |
| 123, face accessory | 0 | Square glasses, including their separate lens mesh |

Eleven additional entries represent source `p_dummy` catalog rows. Zero is not
treated as a universal removal marker: back-hair ID 0 and glasses ID 0 are actual
assets. Empty side/front/option hair and clothing entries are accepted only when
the original catalog explicitly names `p_dummy`. Additional head assemblies are
registered separately by `Tools/reverse/maker_assembly_variants.py`.

That registry adds heads 200 and 201 for each normal sex, alongside the separately
located head-00 base avatars. Each alternate head carries its own shape curves,
expression table, face and eyeline inputs. `SourceMakerAssemblyOptions` applies
the original correction table for nonzero Int32 body-bone types on the shared
skeleton. Special `exType` assemblies and resolver-backed mod heads fail explicitly.

Maker invokes the library when importing an original card, committing a converted
vanilla hair/clothing selection, and when changing its
saved outfit. Four hair slots, supported clothes and up to 20 accessory slots are
resolved from preserved source IDs and exact resolver properties. A missing entry
can retain reference hair/clothes with a diagnostic; an unresolved accessory is
omitted. Import and outfit viewing retain the card's selected IDs and plugin bytes.
The selection editor below changes only explicitly chosen vanilla destinations.

## Reproducible extraction

Use the pinned UnityPy environment and the hash-verified source files previously
copied read-only from the local Windows installation:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/maker_asset_library.py
```

An explicit bounded subset can be selected by repeating `--select CATEGORY:ID`.
The tool rejects missing or ambiguous rows, unsafe source paths, changed bundle
hashes, incomplete geometry and unsupported accessory parenting. It never reads
or decodes character-card thumbnails. Outputs must remain under ignored `.local/`.

Each drawable entry retains the exact source bundle, prefab, catalog table,
catalog hash and bundle hash. Rig and material-evidence files have their own
SHA-256 values. Per-entry appearance and card-binding sidecars are produced by
the material conversion stage; they do not replace original card identities.
The geometry stage preserves node names, source IDs, local transforms, inverse
bind matrices, morph targets and all mesh attributes in Unity coordinates.
The native boundary performs the existing single handedness conversion.

## Clothing state

The exporter selects fully dressed state 0. Original shirt prefabs serialize
both `n_top_a` and `n_top_b` as active, so active flags alone are insufficient.
Recovered `ChaReference.CreateReferenceInfo` maps `n_top_a` to `S_CTOP_T_DEF` and
`n_top_b` to `S_CTOP_T_NUGE`; `ChaControl.UpdateVisible` enables them for states 0
and 1 respectively. The exporter excludes the latter and the analogous known
bottom switches. This avoids superimposing two distinct clothing states.

This selection does not implement the game's clothes-state transitions, linked
top/bottom state rules, skirt dynamics, component options or hide-category rules.
The catalog's body-coverage mask is retained for material conversion. Validation
renders use complete shirts, long trousers and shoes.

The current native preparation skips indoor-shoe slot 7 and uses the outdoor
selection. A converted top can replace the body's coverage mask; an explicit
empty top clears it. These operations do not implement all source wear modes.

## Accessory attachment

The recovered original behavior is:

1. Accessory `type` is the catalog category (121–130); 120 means no accessory.
2. An empty `parentKey` uses the catalog's `Parent`. Otherwise the card's explicit
   parent is resolved through `ChaReference`.
3. The original uses `SetParent(parent, worldPositionStays: false)`, preserving
   the prefab's local transform under that attachment point.
4. `N_move` and `N_move2`, when present, receive the two correction transforms.
   `addMove[c,0] * 0.01` is local position, `addMove[c,1]` is Unity Euler degrees,
   and `addMove[c,2]` is local scale. Unity Euler composition is Z, then X, then Y.
5. `HideHair == 1` resets those corrections to identity instead. Those assets and
   weighted `Parent == "null"` accessories are outside the exported selection.

The source `Vector3[2,3]` MessagePack encoding is `[2, 3, vectors]`, where
`vectors` contains six three-number arrays in row-major order: position,
rotation, scale for the first correction, then the same for the second. This
shape was independently checked against installed card metadata without
decoding its image.

The selected glasses use the source `a_n_megane` attachment and a single
`N_move`. Their original `MeshRenderer` meshes are represented in the rig format
by one identity joint at each mesh's own node with weight one. This gives the
same world transform as an unskinned mesh, including nonuniform parent scale;
no original vertices or transforms are baked or altered. The frame and lens
remain separate material slots. Exact original accessory lighting, transparency,
hide rules and dynamics require further behavior recovery.

## Verification

```sh
IKKOKU_MAKER_LIBRARY="$PWD/.local/reverse/maker-library/library.json" \
  .local/reverse/unitypy-venv/bin/python Tools/reverse/test_maker_asset_library.py -v

.local/reverse/unitypy-venv/bin/python Tools/reverse/test_maker_asset_library.py \
  --audit .local/reverse/maker-library/library.json \
  --output .local/reverse/maker-library/geometry-audit.json
```

The extractor tests cover identity ambiguity, exact empty selections, path/hash rejection,
inactive and alternate-state filtering, and installed geometry. The independent
audit reads original Unity meshes directly and verifies 65,225 selected vertices
across all 15 drawable entries, original topology, normals, tangents, UVs,
inverse binds and every local transform. Attribute and matrix differences were
zero in the recorded audit. The 2,654 static glasses vertices also matched direct original MeshRenderer
transforms under three attachment transforms within `1.12e-16` using float64.
These checks validate extraction and the static representation; native assembled
pose, rendered appearance and edited-card identity preservation have separate
integration tests.

The library is deliberately partial. It is not an exhaustive catalog export,
automatic Unity shader translation, arbitrary plugin execution or an assurance
that every original/modded card can yet be displayed without diagnostics.

Selected-hair dynamics extraction is available, but Maker currently disables the
base dynamics document when prepared geometry changes instead of rebinding it.
Studio has a separate selected-component binding path. Recovering more geometry
therefore does not, by itself, enable its Maker animation or physics.


## Source selection editor (CMT-02 first slice)

The source panel's **Hair and clothing** pickers use the loaded library's exact
vanilla category/ID entries. Four hair slots and eight clothing slots are editable;
inner shoes are excluded because `prepare` assembles only outer shoes. Explicit
empty entries work through the same identity checks. Unavailable or modded current
identities are displayed as unavailable; a supported vanilla replacement removes
only that destination's saved UAR records. Malformed resolver metadata disables
replacement. Missing assembly appearance data or an unreadable appearance draft
also disables the pickers with a reason. Other saved part fields and their resolver
records are retained; original Maker default-reset semantics are not claimed.
No native prototype catalog IDs or display names are written.

The app prepares the candidate assembly once per actual selection and commits it
only after appearance and pose validation. Picker rows are cached on import,
outfit switch and selection commit; no menu rebuilding or resource loading is
added to animation ticks. No-op selections preserve the preview. Current selected
hair remains static in Maker, consistent with the existing dynamics limitation.
See the [card transaction contract](cards.md#transactional-vanilla-maker-selections-cmt-02-2026-10-23)
for serialization, preservation and failure behavior.

Recorded Release evidence on 2026-10-23: three interleaved runs of the final
implementation and three control runs each passed all 46 scenario checks. The
control retained the redundant exact CPU bounds scan and repeated immediate pose
solve. Changed-selection medians (15 changes per run) were 873.45/874.78/873.92 ms
for the control and 870.24/868.88/863.47 ms for the final implementation. Individual
selection ranges overlapped; this small difference does not establish a material
speedup. No-op requests took 0.063–0.069 ms. Synchronous file/asset preparation and
validation still take roughly 0.83–0.90 seconds per changed selection and remain a
performance limitation. No per-frame work is added by the selection controls.

Warmed back-hair 2 → 9 → 2 cycles settled at 36 store-owned meshes and 55 textures;
warmed top 39 → 38 → 39 cycles settled at 34 meshes and 56 textures. Both retained
mesh bytes and deform counts. Repeated candidate previews rejected by an invalid
pending shape preserved all counted resources (34 meshes/57 textures/0 deform
buffers), including on the first rejection. A separate deliberately mismatched
asset hash passed 4/4 failure checks with 36 meshes/35 textures unchanged. Store
counts include reported retired resources and exclude render targets/pipelines
and resources owned only by submitted frames.

All six exported cards were byte-identical, including thumbnails. Build/input
hashes, per-step resource/timing records, controlled source variants and independent
byte audits are retained in the private
`.local/codex-renderer-maker-models-2026-10-23/` evidence directory. The earlier
34-step Debug scenario also passed, but its 1.75–1.89 second selection timings were
not a quiet Release measurement and are not used for the comparison above.
