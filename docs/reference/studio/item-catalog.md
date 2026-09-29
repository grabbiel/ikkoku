# Original CharaStudio item lookup

Reviewed 2026-09-25 against the working tree. The [Studio audit](../../component-audit/studio.md) is the feature-status and actionable-backlog index; this page records the narrower source contract and its evidence.

The verified original catalog key for the rendered chair is **(group: 2,
category: 13, no: 73)**. Its prefab is `p_koi_stu_isu01_00`, its name is
`パイプ椅子1`, and its catalog labels are group `家具` and category `椅子`.
The source record points to manifest `studio00` and bundle `studio/00.unity3d`.

## Evidence

Only the original base info bundle was fetched for this lookup:

| Field | Observed value |
| --- | --- |
| Installation path | `C:\Illusion\Koikatsu\abdata\studio\info\00.unity3d` |
| Bytes | 205010 |
| SHA-256 | `2420913aa4d914ee079dd140bbee835a65918c963667788d2c4d12a1f7f5eca4` |
| ExcelData asset | `ItemList_00_02_13` |
| Unity path ID | `-6449893327296535900` |
| Row index | 7, zero-based including the header |
| First seven cells | `73`, `2`, `13`, `パイプ椅子1`, `studio00`, `studio/00.unity3d`, `p_koi_stu_isu01_00` |

The row marks the item scalable, without animation, color slots, pattern slots or
emission. Its optional glass column is absent, so the original loader defaults it
to false. The labels are independently present in `ItemGroup_00`, row 3, and
`ItemCategory_00_02`, row 3.

The recovered `Studio.Info` type establishes the column interpretation:
`LoadItemLoadInfo` reads no/group/category from cells 0/1/2 and assigns the entry
to the nested group/category/no dictionary. The `ItemLoadInfo` constructor reads
name, manifest, bundle and prefab from cells 3–6. `OIItemInfo.Save` and `Load`
serialize the same three integer keys in group/category/no order. The asset
name's suffix is not itself the item ID.

Local evidence is retained under the ignored `.local/reverse/catalog/` directory:

- `Studio.Info.cs`: bounded ILSpy recovery of the original catalog loader.
- `chair-row.json`: the one matching raw row and its column header.
- `chair.json`: lookup by exact prefab, with source hash and interpreted fields.
- `chair-by-key.json`: reverse lookup by the serialized scene key.
- `key-0-0-1.json` / `key-0-1-11.json`: the same reverse lookup for the two
  basic-shape props (see below).
- `studio-items.json`: a local `KoikatsuAssetCatalog` version 1 mapping the
  chair, cube and cylinder exact keys to their converted glTF files.

Two basic-shape keys were looked up the same way (same base info bundle, 964
rows examined): **(0, 0, 1)** is `p_koi_stu_cube01_02` `キューブ(通常）`
(ExcelData `ItemList_00_00_00`, path ID 6475314763989511810, row 2) and
**(0, 1, 11)** is `p_koi_stu_cylinder00_02` `シリンダー(キャラ）`
(`ItemList_00_00_01`, path ID 1452425205573710344, row 5). Both mark the item
scalable, without animation, one color slot and one pattern slot, no emission
and no glass, manifest `studio00`, bundle `studio/00.unity3d`. Both were
converted with `Tools/reverse/export_prefab.py` under the verified Studio item
shader contract (see [renderer reference](../renderer.md#studio-item-shader-evidence-added-2026-09-29-st-t04))
to `.local/reverse/exports/cube01/` and `.local/reverse/exports/cylinder00/`,
each with `catalog.json`, `provenance.json` and a `test_export_prefab.py
--export` byte-level conversion audit. `studio-items.json` is the
`KoikatsuAssetCatalog` file (version 1, absolute `.gltf` paths, no `://`) that
`KoikatsuLayoutImporter` rules accept for these three keys.

`Studio.Info.cs` SHA-256:
`fa734011b0443c049a97d2f527e6fc52b8799ecf40829cb1fc2a35c9f1bc95a8`.
Its source `CharaStudio_Data/Managed/Assembly-CSharp.dll` SHA-256:
`902b9a237337b17a64514bdb0d857b460ece4fb6a57c658375dd32c5fa504c45`.
Recovered source and game data remain local; the repository contains the lookup
tool and this factual contract.

## Repeat the lookup

The script uses the UnityPy environment established by the extraction tools.
It accepts one exact prefab or one three-integer key and writes only selected
records. It does not export all catalog tables or modify the installation.

~~~sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/catalog.py \
  --prefab p_koi_stu_isu01_00 \
  --output .local/reverse/catalog/chair.json

.local/reverse/unitypy-venv/bin/python Tools/reverse/catalog.py \
  --key 2 13 73 \
  --output .local/reverse/catalog/chair-by-key.json
~~~

The retained lookup run executed both queries and produced the same single result after examining
964 item rows in the selected base bundle. No match returns exit status 2.
Malformed selected source data fails instead of inventing catalog keys.
Additional local info bundles can be supplied with repeated `--bundle` arguments;
the tool sorts bundle paths and item table revisions and applies later item rows
over earlier rows with the same key.

This verifies the original **base catalog** mapping. Other installed info bundles
and runtime mod patches were not evaluated, so it is not proof of the final
modded runtime dictionary. A scene importer should preserve the source
group/category/no triple and its installation/catalog provenance, then resolve
that key before selecting a native converted asset. A native asset identifier
must not be guessed from a display name or numeric suffix.

The separate `KoikatsuLayoutImporter` resolves explicit catalog mappings to local
glTF/GLB props (its key and path rules are the `KoikatsuAssetResolver`). The
chair lookup and the two converted basic-shape props do not establish arbitrary
item restoration. Test a mixed character/item hierarchy and retain unresolved
source keys explicitly.

## Preview item rendering (added 2026-09-29, ST-T04 second slice)

`StudioModel.importSourceScenePreview` now draws source item props in the mixed
preview when `IKKOKU_STUDIO_ITEM_CATALOG` names a `KoikatsuAssetCatalog` version
1 file. The catalog is resolved once with `KoikatsuAssetResolver` (the same key
and path rules as `KoikatsuLayoutImporter`); a catalog error becomes one
diagnostic and the import continues with unrendered placeholders. For each
`.item` record the key is resolved and `library.importStaticAsset(url:)` runs at
import time, so a load failure is a per-item diagnostic and an unresolved or
unloadable key stays an unrendered named node.

This is **runtime-only**, exactly like source cameras: the placeholder entry
stays kind `.folder` with no `assetFile`/`itemID` and its saved
`sourcePreviewName`/`sourceRecordKind`, so `SourceSceneExportValidation` keeps
passing and original export is unaffected. The resolved asset path is held in a
`sourceItemAssets` map carrying the scene SHA-256, cleared wherever
`sourceCameras` is cleared. In the frame builder a guarded `.folder` placeholder
emits the asset's parts like a native `.item` (same `order`, bounds and
`objectID` so picking selects the placeholder) at the placeholder's world
matrix, which follows the Studio scale rule (items keep their own saved scale).

The import summary reports `Items rendered from the converted catalog: N;
unmapped keys: …`. A headless run importing `koikatu_cs0002591.png` with the
private catalog renders its 19 cube (0/0/1) props at their saved transforms and
saved record colors (every one of the 19 records `color[0]` as the same
0.875 grey at alpha 1) with no unmapped keys, and original-scene export of that
preview still succeeds.

Not applied yet: patterns, line, emission, light cancel, animation, FK and
dynamics. An item's `childRoot` sub-transform, where its children attach, is
not modeled — children attach to the item root. `ST-T04` continues to track
item materials/patterns, animation, FK/dynamics and accessory attachment frames.

## Record colors and alpha (added 2026-09-29, ST-T04 third slice)

The exported basic-shape materials carry two new `extras` entries,
`itemColorSlot` and `itemAlphaProperty` (see the
[renderer reference](../renderer.md)): the fully selected `_ColorMask` channel
(0 = `_Color`, 1 = `_Color2`, 2 = `_Color3`, null when no channel is fully
selected) and, for the alpha shader only, `_alpha`. `SourceStudioItemColor.tint`
maps those extras and the item record to a tint — `record.colors[slot]` and
`record.alpha` — and the frame builder applies them to the imported part.

The record color REPLACES the exported base factor (the serialized `_Color`)
and the record alpha REPLACES the exported base alpha (the serialized `_alpha`),
as `UpdateColor` overwrites both material properties at runtime. The color takes
the same `RGB.linear` conversion as any native color: CharaStudio is a
gamma-space project, so the saved Unity `Color` components are already in the
space the serialized `_Color` factor was exported in. `Toon.metal` scales the
base alpha by the sampled texture alpha exactly as the source
`_MainTex.a · _alpha` contract does. (The basic shapes serialize white and
alpha 1, so replacing and multiplying agree for them; replacing is the recovered
behavior for any other value.) The record's colors and alpha ride along in `sourceItemAssets`,
so the frame builder never re-reads the scene file.

A part whose material exports no color slot — a partial or multi-channel
`_ColorMask` selection, where no single record color can be the tint — keeps
its exported material untouched rather than guessing. In `koikatu_cs0002591.png`
that path is provably harmless: both exported basic shapes mask pure red, so
the exported factor is white and only the record color changes pixels. A
headless A/B of the same scene with and without those extras (captures are
otherwise bit-identical run to run) changes 103517 sampled pixels: 102917
inside the cube footprint (pixels a cube-free capture also changes) and 600
edge pixels within 6 px of it, none isolated, with the tinted/plain ratio
sitting on 0.88 — the sRGB round trip of the saved 0.875 grey.
