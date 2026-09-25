# Bounded Maker asset coverage

Inventory reviewed 2026-09-25. These are the local conversion counts from the
named manifests, not a test run or a percentage of the complete game. Feature
status and expansion tasks are in the
[component audit](../../component-audit/character-and-mods.md) (CMT-01, CMT-04,
CMT-07 and CMT-09). Run commands from the repository root.

`Tools/reverse/maker_coverage.py` compares the converted Maker library with the two hash-verified source catalog bundles available locally: `list/characustom/00.unity3d` and `50.unity3d`. These counts are not a denominator for every installed catalog, DLC bundle or zipmod.

| Asset group | Catalog drawable entries | Converted drawable entries | Catalog `p_dummy` entries | Converted `p_dummy` entries |
| --- | ---: | ---: | ---: | ---: |
| Hair | 100 | 6 | 3 | 3 |
| Clothes | 213 | 8 | 10 | 8 |
| Accessories, including none category | 190 | 1 | 1 | 0 |
| Heads | 3 | 3 | 0 | 0 |

Head IDs 0, 200 and 201 produce six normal male/female assemblies. Every nonzero body bone type uses the recovered source correction table on the shared skeleton; this does not represent additional body meshes. Special male `exType=1` is outside this coverage.

All 15 converted drawable hair/clothing/accessory entries have appearance sidecars and card bindings. Six normal assemblies also have bindings. These count albedo and card-field recipes, not complete equivalence of the original Unity shaders. Fixed materials may have no editable card recipe. Full source lighting/stencil/mip behavior, complete physics coverage and alternate clothing states remain incomplete; bounded shader probes and hair dynamics are tracked separately in the component audits.

The same two catalogs contain 40 non-null pattern IDs, 7 cheek IDs, 6 lip-line IDs, 26 face-paint IDs and 3 mole IDs. The current converted texture sets cover 38, 7, 6, 23 and 3 IDs respectively. Lip makeup and eyeshadow overlays are not covered by these recipes.

The local Maker geometry registry currently contains no converted entries with mod GUIDs. Its exact GUID/source-slot resolution path preserves imported mod identity, but this is not a claim that installed mods are converted. The separate existing mod texture library and adapters are outside this count.

Recompute the ignored evidence after each extraction pass:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/maker_coverage.py
```

The report at `.local/reverse/maker-expansion/asset-coverage.json` records source catalog hashes, exact converted catalog identities, material recipe counts by asset, missing drawable counts and scope limitations. It reads catalog metadata and converted manifests; it does not decode original card thumbnails.
