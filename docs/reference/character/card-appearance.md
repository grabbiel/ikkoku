# Source card appearance recipes

Reviewed 2026-09-25. This page describes base selected-assembly recipes and their
current Maker integration. [Catalog-selected assets](maker-assets.md) and
[material expansion](material-expansion.md) add per-component recipes, patterns,
face layers and active coordinate/base makeup. The
[component audit](../../component-audit/character-and-mods.md) (CM-25, CM-29–32;
CMT-04) lists unimplemented appearance layers. Commands run from the repository
root; fixture measurements below are recorded evidence.

`Tools/reverse/card_appearance_bindings.py` connects selected original card colors
to the recovered native preview materials. It emits explicit bindings for the
known clothed female and normal male avatars. It does not infer that an arbitrary
card's selected asset exists merely because its numeric ID can be decoded.

The base generator's two sidecars each contain 16 recipes covering 25 editable color fields:

- Head base and secondary skin colors, plus the clothed body's flat skin tint.
- Left/right iris colors and their blend values, eye whites and shadow color.
- Eyebrow and eyeline tint; the upper eyeline's second pass uses skin color, as
  recovered from `ChaControl.UpdateEyelineShadowColor`.
- Upper/lower iris highlight colors.
- Three color channels for the selected shirt, trousers and outdoor shoes.
- Base, root and tip colors for the two selected hair pieces.

The color equations are the previously recovered `create_head`, `create_eye`,
`create_eyewhite`, `create_topN` and `main_hair`/`main_hair_front` formulas.
Generation verifies the original shader bytecode hashes and revision allowlist,
then verifies every source PNG hash before decoding its pixels. Upright PNG rows
become tightly packed RGBA bytes without another vertical flip. Each texture has
an explicit width, height and SHA-256; inputs are limited to 4096 per dimension
and four million pixels. The Swift loader verifies byte counts, hashes, folder
containment and a total resource bound before uploading generated textures.

Recipes require exact recovered catalog selections. The initial base head recipe
guards head 00 and the recovered skin/detail selections. The expansion stage
adds explicit supported makeup, paint, mole and lip-line inputs; alternate-head
generation replaces face/eyeline resources and the head identity guard with the
selected head's own data. Iris recipes require the recovered pupil and constant-white
gradient IDs. Eye white, brow, eyeline and highlight recipes guard their own IDs.
Initial clothing recipes required the selected garment ID and absent patterns
and emblems. Expanded recipes accept the converted patterns in their three
supported color channels; extra channels and emblems remain unsupported. Hair
recipes require each converted piece's exact selection.
Exact UniversalAutoResolver property names are also guarded, including outfit
prefixes for clothing. A mod that reuses a numeric slot therefore cannot silently
receive an unrelated original texture recipe.

A failed identity or missing color leaves the reference material in place and
produces a diagnostic. Original card data remains preserved. This supports color
changes for known assets. Geometry comes from the separate Maker library, while
expanded recipes load only their converted pattern/makeup inputs. Detail normals,
complete accessory recoloring and arbitrary shader replacements are not provided
by this path.
The body's flat tint is only for the explicitly clothed preview. Original lighting,
stencil, filtering and project color-space parity remain incomplete.

## Local output and fixtures

Run after generating the original head/clothes material contracts and male avatar:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/card_appearance_bindings.py
```

The generated files are:

- `.local/reverse/rigs/source-avatar.card-appearance.json`
- `.local/reverse/male/source-male-avatar.card-appearance.json`
- `card-appearance-inputs/*.rgba` in each corresponding folder.
- `synthetic-appearance-card.png` and `synthetic-appearance-oracle.json` in each
  folder.

Both synthetic cards have a generated one-pixel thumbnail and no face thumbnail.
They contain valid original-format face/body/hair and seven coordinate records,
matching explicit shirt/trousers/shoes IDs, test colors, and an opaque unknown
block. No original thumbnail is copied or decoded. The female fixture uses hair
IDs 2/1; the male fixture uses 9/5 and the recovered original male shape defaults.
The fixtures are technical tests, not original character cards.

The oracle lists every expected applied field and recipe index, and stores nine
independently composed RGBA images using the recovered Python shader formulas.
Native GPU texture comparisons allow a one-byte channel difference for Float32
rounding. Tests cover raw row order, alpha retention, changed PNG/shader rejection,
texture bounds, card framing, sex/shape preservation and explicit clothing IDs.

## Maker controls and edited export

Use **File → Import Source Card…** to select an original character PNG. The app
loads the matching local normal female or male reference rig after checking
sex, selected head and body-bone identity. Registered heads 0, 200 and 201 and
nonzero Int32 bone types with the original correction table are supported.
Unavailable heads, resolver-backed mod heads and special `exType` models are
rejected for preview. All 44 body slots have destination coverage;
normal male height is fixed according to the recovered caller behavior. All 52
face values remain available.

Open **Card appearance**, choose an **Outfit**, edit the available color pickers,
then press **Apply colors**. Only fields successfully bound to the selected
original material recipes appear as editable colors. A seven-coordinate card
has seven choices; the selected coordinate supplies its saved clothing colors
and supported outfit-specific ABMX. When the Maker library is available, changing
outfit rebuilds converted clothing/accessory selections before replacing the
preview. Missing conversions retain reference clothing or omit unavailable
accessories with diagnostics. **Appearance compatibility** lists unmatched
selections and other preserved settings. This is selection import, not a source
asset picker or an identity editor.

**File → Export Edited Source Card…** writes a new original-format card with the
shape/color edits and fresh clothed thumbnails. The thumbnails depict the
supported reference preview, so they are not a claim that every original selected
asset has been restored. The imported file remains unchanged; choose a new
filename. Untouched coordinates, unknown fields, asset identities and opaque
plug-in/Extended Save payloads are preserved. Imported plug-in code is not run.

Headless verification uses these environment variables:

| Variable | Value |
| --- | --- |
| `IKKOKU_SOURCE_CARD` | Original-format input card path |
| `IKKOKU_SOURCE_COORDINATE` | Zero-based saved coordinate index, normally 0–6 |
| `IKKOKU_SOURCE_COLOR_EDITS` | Path to a JSON object mapping supported color IDs to four Float RGBA components in 0–1 |
| `IKKOKU_EXPORT_SOURCE_CARD` | New output source-card path |
| `IKKOKU_AUTOCAPTURE` | Preview PNG path; enables the headless run |

For example, the color-edit file can contain:

```json
{
  "body.skinMainColor": [0.95, 0.76, 0.65, 1.0],
  "clothes.parts.0.colorInfo.0.baseColor": [0.15, 0.35, 0.65, 1.0]
}
```

With that file saved as `.local/reverse/rigs/color-edits.json`, use the generated
matching fixture to exercise the complete import/color/export path:

```sh
IKKOKU_SOURCE_CARD="$PWD/.local/reverse/rigs/synthetic-appearance-card.png" \
IKKOKU_SOURCE_COORDINATE=0 \
IKKOKU_SOURCE_COLOR_EDITS="$PWD/.local/reverse/rigs/color-edits.json" \
IKKOKU_EXPORT_SOURCE_CARD="$PWD/.local/reverse/rigs/edited-appearance-card.png" \
IKKOKU_AUTOCAPTURE="$PWD/.local/reverse/rigs/edited-appearance-preview.png" \
  .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
```

An unbound color ID fails this headless edit path rather than implying that its
appearance was changed. Ordinary export edits supported values while retaining
unsupported source data.

The edited copy has a 504×704 full-body thumbnail and a separately rendered
256×256 face thumbnail. Both show the current clothed reference preview.
Export preserves the imported ABMX payload; disabled, cleared or externally
replaced modifiers must be restored before export so the thumbnail and retained
card modifiers agree. Color editing recomposes only when values have changed.
