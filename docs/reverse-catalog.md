# Original CharaStudio item lookup

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

Both queries were executed and produced the same single result after examining
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
