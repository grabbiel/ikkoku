# Source mod catalog and resolver contract

The installed Sideloader `21.1.2.1` injects character catalogs by category, rewrites row IDs into temporary runtime slots, and retains the original mod GUID/category/slot in resolver metadata. Asset references are separate bundle/name/type requests; their provider cannot be inferred from the catalog mod's GUID.

`Tools/reverse/analysis/mod_catalog_contract.py` derives an independent reference from selected recovered C# types and preserved catalog bytes. It reads neither native Swift code nor plugin entry points. Its ignored output, `.local/reverse/mods/catalog-contract.json`, contains original-binary hashes, recovered-source hashes and line anchors, 107 ordered `KeyType` names, 71 categories and their property identities, 39 explicit reference rules, five indexed base assets, the original sample rows, and independent parser/lookup/version fixtures.

```sh
python3 Tools/reverse/analysis/mod_catalog_contract.py
```

The script needs the ignored local source evidence produced during this investigation. Recovered code and original data remain outside version control. Its assertions verify reference fixtures and hashes; it does not launch the original game or compare a running source UI.

## CSV ingestion and row metadata

`ZipmodInfo.LoadAllLists` recognizes `.csv` entries starting with `abdata/list/characustom`, using ordinal case-insensitive tests. `Lists.LoadCSV` uses `StreamReader(stream, Encoding.UTF8)` and these operations:

| Input | Source interpretation |
| --- | --- |
| Line 1 | First comma-separated token, trimmed and parsed as `categoryNo` |
| Line 2 | First token, trimmed and parsed as `distributionNo` |
| Line 3 | First token, trimmed and stored as `filePath` |
| Line 4 | Trim the whole line, then split on literal commas into header names |
| Later lines | Trim the whole line, then split on literal commas; stop entirely at the first line without a comma |

Individual header and data cells are not trimmed. Quotes have no escaping or grouping function. Blank lines terminate reading instead of being skipped. The second line is distribution metadata, not an archive priority or asset-root selector. The third line is retained but is not used by `Lists.LoadList` to route injection: that method selects an already-existing dictionary by category number.

The source stream reader detects BOMs and uses decoder replacement for malformed byte sequences; it does not guess CP932. The initial package importer's RFC CSV/CP932 interpretation is analytical metadata, so the native source catalog path must reparse the preserved raw bytes. An unsupported encoding can be reported without altering those bytes.

After parsing, `ZipmodInfo.SetPossessNew` changes the first header named exactly `Possess` to `"1"` in every row. `ListInfoBase.Set` initializes `Category` and `DistributionNo`, then assigns columns in header order. Known duplicate headers overwrite earlier values. Unknown enum names map to the shared integer key `-1` through `ValueExtensions.Check` and `Utils.Value.Check`. Extra row cells are ignored by `Set`; too few cells cause an index error. These quirks are evidence, not a recommendation to silently accept malformed catalogs.

`ListInfoBase.GetInfo` returns `"0"` for a missing key and the exact stored string for a present key. An explicit empty cell remains empty. `GetInfoInt` returns `-1` on parse failure. There is no universal rule that both empty and `"0"` mean absent.

## Original slots, runtime slots and duplicates

`GenerateResolutionInfo` consumes the original integer in row column zero as `Slot`. It allocates a new `LocalSlot` using `Interlocked.Increment`, creates a resolver record for every applicable category/property mapping, then replaces row column zero with that runtime slot. The source counter depends on startup state and has an enabled-by-default randomization setting. The oracle uses an explicit synthetic starting counter of `100000000`; these fixture numbers do not predict the installed game's runtime IDs.

Resolver records use GUID, original `Slot`, `LocalSlot`, property, and category. GUID setters and query arguments trim surrounding whitespace. Character resolver comparisons are case-sensitive. Lookup groups by original or local slot and returns the first record matching the supplied category/property/GUID constraints. Two rows with the same GUID/category/original slot receive separate runtime slots; an original-slot query returns the first matching record. A local-slot query can still address the second record. Catalog injection itself keeps the first existing runtime-ID dictionary entry.

The property mappings come from `StructReference`, including its four clothing pattern indices, the installed game's verified `emblemeId2` property, and the accessory `ChaFileAccessory.PartsInfo.id` mapping for every source category enum. Category `432` is the resolver's special `Ramp` case. Category `122` (`ao_head`) has the accessory property alone.

Character-save hooks write the original `Slot` and attach resolver metadata through Extended Save; after saving/loading, resolution restores the appropriate runtime `LocalSlot`. Preserving only a temporary runtime integer therefore loses identity. Full Extended Save framing and migration execution remain separate work.

## Asset references and sentinel values

The contract uses explicit source consumers, never a rule inferred merely from a column ending in `AB` or `Tex`. Each reference rule carries applicable categories, bundle and asset fields, optional manifest/fallback fields, disabled tokens, and the expected Unity object type.

| Consumer | Reference | Observed special handling |
| --- | --- | --- |
| Character prefab loader | `MainAB`, `MainData`, `MainManifest`; `GameObject` | Empty `MainData` skips loading; literal `"0"` is not that empty guard. Low-detail variants append `_low`. Extended body loading has a separate direct call. |
| Accessory thumbnail list | `ThumbAB`, `ThumbTex`; `Texture2D` | Passed directly with an empty manifest; no empty/zero guard at this call. |
| Normal head material | `MatAB`, `MatData`, `MatManifest`; `Material` | Preserved as a material dependency; a matching texture is not a converted material. |
| Clothing diffuse/masks | Six explicit `MainTex*AB`/`MainTex*` and `ColorMask*AB`/`ColorMask*Tex` pairs | Exact bundle token `"0"` falls back to `MainAB`. Exact `"0"` after fallback, or in the asset field, disables the texture. Empty strings do not trigger this fallback. |
| Face/body texture calls | The 24 category/field combinations found in `SetCreateTexture` and `ChangeTexture` call sites | Require both bundle and asset to differ from exact `"0"`. They use the default manifest. |
| Patterns, emblems, expression overlays | Explicit `MainTexAB`/`MainTex` or `EpsTexAB`/`EpsTex` pairs at their source call sites | Same exact-zero guard; separate expected type `Texture2D`. |

`CommonLib.LoadAsset` passes an empty manifest as null; `AssetBundleManager.LoadAsset` selects `abdata` for null/empty manifests. Literal `"0"` is not converted into that default. Normal head diffuse/color-mask calls, clothing fallbacks, and generic texture helpers differ; the contract keeps separate rules. The dependency rules describe high-detail identities; a complete low-detail caller must apply the particular source consumer's suffix behavior. Shape animation, additional mask contexts, category-specific rendering conditions and all other reference families are not implicitly supported by this bounded table.

Archive bundle registration removes everything through the first slash from the original ZIP entry name: both `abdata/chara/X.unity3d` and `other/chara/X.unity3d` become `chara/X.unity3d`. A name without a slash stays unchanged. It does not lowercase the remainder. Converter 1.1.0 retains original ZIP bundle order alongside full paths. The native catalog bridge uses these aliases and that order, then explicit profile order across packages. Legacy packages with competing aliases fail resolution until reimported; sorted resource IDs cannot recover source order. Asset names retain their original case. The source `BundleManager` stores multiple loaders per bundle key and chooses the first containing the requested asset.

## NoHairAccs sample

The explicitly fetched archive `[DokEnkephalin]NoHairAccs.zipmod` is 2,097 bytes, SHA-256 `a5497c46e99b843e08ae43093c7dd2f8cef875468b42e3f6c0186908a1e70108`. It was imported to `.local/reverse/mods/packages/no-hair-accessories/manifest.json` using the existing importer without changes to that tool.

Its GUID is `enk.acc.bald`; its one CSV declares category `122`, distribution `0`, and source list path `Assets/Illusion/assetbundle/chara/list/characustom/00/ao_head_00.bytes`. The four original slots are `1080`–`1083`. All use `MainManifest=abdata`, `Parent=a_n_headside`, and `HideHair=1`.

| Original slot | Main bundle / GameObject | Thumbnail bundle / Texture2D |
| --- | --- | --- |
| 1080 | `chara/etc.unity3d` / `p_dummy` | `chara/etc.unity3d` / `thumb_none` |
| 1081 | `chara/ymd/mf_haircap.unity3d` / `mf_haircap` | `chara/thumb/ymd/mf_haircap_thumb.unity3d` / `thumb1` |
| 1082 | same / `mf_haircap2` | same / `thumb2` |
| 1083 | same / `mf_haircap3` | same / `thumb3` |

The archive contains no bundles. The installed base `chara/etc.unity3d` was separately inspected (7,390 bytes, SHA-256 `9dabf8c831be981430a20bcfe253fe1fe3a90eb49dc253e31400568c350aff2a`), confirming `p_dummy`, `p_dummy_low`, and the Texture2D `thumb_none`. The two `ymd` bundle files are absent from base `abdata`. Another installed mod may supply them; the archive collection was not searched broadly. Consequently, unindexed dependencies are unresolved, not proven absent from the installation, and no provider GUID is invented.

## Registration and version selection

The recovered loader scans `.zip` and `.zipmod` extensions, groups by trimmed manifest GUID using a case-sensitive dictionary, then processes groups ordered by GUID with the default .NET string comparer. This means source culture can matter; it is not evidence for a universal bytewise ordering.

For duplicate GUIDs, if every candidate has a nonempty version, the loader sorts by its custom `ManifestVersionComparer` descending, then by filename length descending. If any version is missing, it uses modification time descending instead. A sorting exception falls back to the group's prior order. The selected archive's lists and bundles follow ZIP entry order. Equal ties can retain discovery/cache/parallel-loading order. The initial importer sorts its index paths and does not claim to reconstruct those remaining ties.

The custom version comparer strips leading `v`, `V`, `r`, `R`, and spaces; splits on dots, spaces, hyphens, commas and underscores; divides digit/non-digit runs; compares Int32 tokens numerically; and fills missing tokens with zero. String comparisons may use current culture, while mixed-type fallback uses special zero handling and ordinal comparison. It is not SemVer: the recovered rules place `1.0-beta` above `1.0`. The oracle includes six culture-independent comparison cases and three duplicate-selection cases. It explicitly refuses to substitute Python collation for two distinct source string tokens.

## Contract and fixture verification

The native-facing fields are `schemaVersion: 1`, ordered `keyTypes: [String]`, `categories: [{number, name, properties}]`, `referenceRules`, and optional `sourceAssets`. `disabledBundleValues` is evaluated after an exact-zero bundle fallback. `sourceAssets` records manifest, source bundle key, asset name, expected type, path ID and source bundle hash; source availability does not imply native conversion.

The report also contains five independent fixture groups for plain splitting/termination, duplicate original-slot lookup, duplicate/untrimmed headers, exact-zero fallback, and bundle-key registration. `catalogs[0].generated` contains the four sample rows and resolver records from a synthetic counter; `dependencies` contains the eight typed references above. Input source bytes and hashes are retained. Native tests can compare these expected records without sharing implementation with the oracle.

## Native implementation

`SourceModCatalog` reparses hashed raw CSV bytes, retains original GUID/category/slot
keys and exposes first-match property lookup. It preserves missing-versus-empty
values, first-Possess rewriting and known-column overwrite order. Distribution
comes from the final `DistributionNo` field, including `-1` for failed integer
parsing. Malformed Unicode, unknown columns and unsupported rows produce
diagnostics; this bounded adapter does not reproduce decoder replacement.

Dependency reports distinguish converted textures, indexed source assets awaiting
conversion, type mismatches, unresolved providers and ambiguous legacy bundle
order. A source inventory lookup checks the requested type even when a Sprite and
Texture2D share a name. The real sample yields four entries and eight dependencies:
two source-only assets and six unresolved references. These are coverage reports;
the adapter does not instantiate arbitrary prefabs or prove all catalog categories
usable in Maker. Source version selection, migrations and card resolver records
remain unfinished.
