# Mod compatibility: source evidence and initial native pipeline

The inspected installation uses Sideloader data archives and BepInEx managed plugins. These require separate compatibility work in the Swift/Metal engine. The survey below records formats and dependencies. The initial importer now preserves bounded archives and converts supported textures into native-readable packages; it does not establish compatibility with the installed collection.

The read-only source was `C:\Illusion\Koikatsu` in the local Parallels Windows VM, surveyed on 2026-09-24. The ignored local evidence file is `.local/reverse/mods/inventory.json`. It contains directory and extension counts, all plugin-directory DLL paths and sizes, three archive manifests and entry tables, three plugin metadata records, selected SHA-256 hashes, and the inspection scope. No plugins were executed and no archives were bulk-extracted.

## Installed files

| Directory | Files | Selected extension counts |
| --- | ---: | --- |
| `mods` | 4,203 | 4,202 `.zipmod`; one `.2` suffix |
| `BepInEx` including descendants | 470 | 269 DLL, 110 CFG, 19 XML, 14 ZIP, 6 EXE |
| `BepInEx/plugins` | 289 | 243 DLL, 11 XML, 9 MD, 5 EXE |
| `BepInEx/core` | 19 | 13 DLL, 6 XML |
| `BepInEx/patchers` | 7 | 3 DLL, 1 EXE |
| `BepInEx/config` | 114 | 110 CFG, 2 XML, 1 INI, 1 DATA |

The `.zipmod` files occupy 38,180,113,589 bytes. The directory counts overlap; they must not be added together. DLL counts include support libraries and are not counts of independently loadable plugins. The single non-`.zipmod` file is `mods/Sideloader Modpack/Evaan/[Evaan] DisneyGurls_mod v1.2`; its contents and whether Sideloader discovers it were not inspected.

The top-level mod directories include the general Sideloader pack and separate animation, map, Studio, fix, and material-editor packs. The full directory names remain in the local inventory; no content from those packs was broadly extracted.

## Three bounded archive samples

| Installed archive | Manifest identity | Observed contents |
| --- | --- | --- |
| `[DokEnkephalin]NoHairAccs.zipmod` | `enk.acc.bald`, version `1` | A 656-byte `abdata/list/characustom/NoHairAccs.csv`; no bundled geometry |
| `[DeathWeasel][KK]Smaller Heart Pupil v1.1.zipmod` | `com.DeathWeasel.SmallerHeartPupil`, version `1.1` | `abdata/chara/mt_eye_00.unity3d`; its first 64 bytes identify UnityFS and Unity `5.6.2f1` |
| `KK_QuickAccessBox_Thumbs_Mods_02.zipmod` | `KK_QuickAccessBox.Mods.02`, version `1` | Root manifest plus empty `abdata/` and `abdata/thb_mods02/` directory entries; this installed sample contains no thumbnails |

All three have a root `manifest.xml` with `schema-ver="1"`, GUID, name, version, author, description, and website fields. The pupil sample also declares `game` as `Koikatsu`. None of these three manifests declares a mod dependency. This does not prove that their assets have no dependencies: the catalog-only sample references external bundle paths through `MainAB` and `ThumbAB`.

The CSV starts with category `122`, a second preamble value of `0`, and a target source list path ending in `ao_head_00.bytes`. Its header includes `ID`, `Kind`, `Possess`, `Name`, `MainManifest`, `MainAB`, `MainData`, `Parent`, `HideHair`, `ThumbAB`, and `ThumbTex`. Its four rows reference existing or externally supplied assets. Thus a data-mod importer needs source catalog semantics and bundle/asset resolution as well as ZIP support.

The pupil archive uses an existing base bundle path. The initial header survey established its container format; the subsequent importer verification described below converted its two textures. Whole-mod appearance parity is not established by that conversion.

## Managed plugin metadata

The installed core assembly identifies itself as `BepInEx, Version=5.4.23.5`. Three plugin DLLs were inspected with .NET Framework reflection-only APIs, including assembly references and custom-attribute metadata. All three inspections completed without unresolved type errors. Attribute constructors, plugin entry points, and static initializers were not invoked.

| Plugin | Installed assembly version | Declared plugin dependencies |
| --- | --- | --- |
| Sideloader (`com.bepis.bepinex.sideloader`) | `21.1.2.1` | Extended Save `21.1.2.1`; `gravydevsupreme.xunity.resourceredirector` `1.1.0` |
| Extended Save (`com.bepis.bepinex.extendedsave`) | `21.1.2.1` | No `BepInDependency` attributes observed on its plugin type |
| ABMX (`KKABMX.Core`) | `5.4.0.0` | Extended Save with dependency flag value `1`; `marco.kkapi` `1.34` |

Sideloader and Extended Save declare process filters for Koikatu, Koikatsu Party, both corresponding VR process names, and CharaStudio. Sideloader also declares an incompatibility with `com.bepis.bepinex.resourceredirector`. These are source loader metadata, not native-engine features.

All three reference `UnityEngine`, `Assembly-CSharp`, `Assembly-CSharp-firstpass`, BepInEx, and `0Harmony`. Sideloader additionally references SharpZipLib, XUnity.ResourceRedirector, Extended Save, and UnityEngine.UI; ABMX references KKAPI and Extended Save. The source assembly-reference versions differ from some installed versions: for example, ABMX references BepInEx `5.4.19.0` and Extended Save `1.0.0.0`. Assembly references and plugin GUID/version constraints therefore need to remain distinct in any compatibility report.

These managed binaries expect the original Unity/game API and patching environment. A Swift/Metal executable cannot treat them as native Swift plugins merely by loading their files. Supporting their saved data and reproducing their behavior are distinct implementation targets.

## Resolver evidence from the installed Sideloader

Only the 172,032-byte Sideloader DLL was copied, with transfer SHA-256 verification. ILSpy recovered three selected types into ignored local files. This was static inspection, with no source plugin execution.

- `Sideloader.Manifest` requires root `manifest.xml`, schema version exactly `1`, and a non-null GUID. It trims metadata, reads multiple `game` elements, and parses optional `migrationInfo/info` records, including old/new GUIDs, categories, and old/new IDs. None of the three sampled manifests exercises migration.
- `Sideloader.BundleManager` indexes a bundle path to an ordered list of lazy bundle loaders. `TryGetObjectFromName` scans that list and selects the first bundle containing the requested asset name; its debug path reports additional matches. This is asset-level selection within a shared bundle path. The later [catalog investigation](reverse-mod-catalog.md) recovered ZIP registration and duplicate-GUID selection rules; filesystem enumeration alone does not establish their order.
- `Sideloader.AutoResolver.ResolveInfo` is a MessagePack object with string keys `ModID`, `Slot`, `LocalSlot`, `Property`, `CategoryNo`, `Author`, `Website`, and `Name`. Its GUID setter trims input. The distinction between source and resolved IDs must be preserved; a plain integer slot cannot capture this record's identity information. The enclosing character/coordinate/scene Extended Save framing was not inspected here.

The local inventory records each recovered type's file hash and the source assembly hash `dc3b1c3d4e63941a6bbf83fde9783fc46fcdbd7715f2f7602067a5fed80a7a9b`. Recovered source and original archives/binaries are not tracked in the repository.

## Native compatibility work implied by this evidence

The initial data path is an archive index that preserves manifest GUID/version/game metadata, original entry paths, catalog records, and bundle/asset identity. Resolver records and unknown Extended Save payloads need lossless preservation before character-card round trips can be considered compatible. Source conflict priority and migration behavior require dedicated recovery and fixtures before implementation.

Asset conversion also needs mod-provided mesh, texture, material, shader, and skeleton contracts. ABMX-like customization requires a separate recovered data model and bone-operation implementation. Arbitrary managed plugin behavior, patchers, Studio additions, and native helper executables remain unimplemented. No installed-mod runtime compatibility is claimed by this survey.

## Initial archive importer

`Tools/mods/zipmod.py` produces a new package directory atomically. The standard-library path preserves and indexes files; `--textures` uses the existing UnityPy environment for optional Texture2D conversion. Existing output directories are rejected, so regeneration uses a new destination rather than replacing a package in use.

```sh
python3 Tools/mods/zipmod.py selected.zipmod /chosen/new-package
.local/reverse/unitypy-venv/bin/python Tools/mods/zipmod.py selected.zipmod /chosen/new-package-with-textures --textures
python3 -m unittest discover -s Tools/mods -p 'test_*.py' -v
```

The importer requires a single root UTF-8 `manifest.xml`, `schema-ver="1"`, and a nonempty GUID. It preserves the original manifest bytes, including unknown elements, and records migration attributes plus XML representations without applying migrations. Missing optional name/version fields become empty strings. Version 1.1.0 records the observed bundle registration order within each archive; native package mount order remains explicitly selected.

The versioned `manifest.json` contract is:

```text
schemaVersion: 1
kind: "ikkoku-mod-package"
converter: { id: "ikkoku.zipmod", version: "1.1.0" }
source: { guid, version, name, archiveSHA256, games: [String] }
bundleRegistrationOrder: [String]
resources: [{
  id, kind: "texture2D", status: "converted",
  bundlePath, assetName, sourcePathID: Int64, sourceSHA256,
  path, sha256, width, height
}]
catalogs: [{
  sourcePath, path, sha256, status: "preserved",
  encoding?, preamble?: [String], columns?: [String], rows?: [[String]],
  parseStatus?: "unsupported"
}]
diagnostics: [{ code, severity, message }]
sourceManifest: { sourcePath, path, sha256, migrations: [{ attributes, xml }] }
archiveEntries: [{ sourcePath, kind, status, path?, sha256?, size? }]
bundles: [{
  bundlePath, path, sha256, status: "preserved", objectInspection,
  signature?, formatVersion?, playerVersion?, unityVersion?, decodedBytes?,
  objects: [{ serializedFile, sourcePathID, type, assetName?, status, resourceID? }]
}]
```

`resources` contains only successfully converted Texture2D objects. `bundlePath` retains the exact original archive path, including its first component, and asset names retain their original case. `sourceSHA256` hashes the original bundle bytes; `sha256` hashes the referenced PNG or raw file. Unity path IDs require signed 64-bit integers and must not pass through a floating-point JSON representation.

`bundleRegistrationOrder` is optional for legacy 1.0.0 packages and always emitted by 1.1.0, including an empty array when the archive contains no registered bundles. It follows the validated ZIP central-directory entry order, independently of the sorted `archiveEntries`, `bundles`, and `resources` indexes. The recovered `ZipmodInfo.LoadAllLists` registers names ending in `.unity3d` with ordinal case-insensitive comparison; it does not require an `abdata/` prefix or Unity payload magic. Thus `other/chara/x.unity3d` and `abdata/chara/x.unity3d` remain distinct original paths, while the source derives the same `chara/x.unity3d` alias by removing the first component. Recording order makes this distinction available to the native resolver without changing stable resource IDs. This field does not reconstruct ordering between different archives; see [the recovered catalog contract](reverse-mod-catalog.md).

Resource IDs are `zipmod:` followed by SHA-256 of UTF-8 compact JSON `[GUID, bundlePath, assetName]`. They exclude archive enumeration order, version, content hashes, and Unity path ID. Duplicate texture names within a bundle are reported as unsupported instead of choosing one by order. Exact byte-identical PNGs share a hash-addressed cache path while retaining separate asset IDs. The native reader permits shared cache paths only when their declared hashes agree.

Every source file is preserved in a hash-addressed `source/*.bin` file; the index retains its original path. Directories have no file payload. Catalogs under `abdata/list/` retain their raw bytes and, when recognized, their three preamble lines, header, and ordered rows. UTF-8 and CP932 decoding are supported. An unsupported catalog layout has `parseStatus: "unsupported"`, preserved raw bytes, and a diagnostic; the native reader accepts that preservation state without inventing parsed rows.

Registered bundles retain their raw bytes regardless of conversion, including unsupported `.unity3d` payloads. A UnityFS, UnityRaw, or UnityWeb payload under another extension is preserved as `archiveEntries.kind: "unregisteredUnityBundle"`, receives a `bundle_not_registered` diagnostic, and is excluded from bundle registration and texture conversion. Other ordinary files remain preserved. Optional object inspection currently handles UnityFS format 6 from Unity 5.x, with bounded uncompressed/LZ4 block metadata and payloads. Other bundle formats, compression modes, streamed textures, and non-Texture2D objects receive unsupported diagnostics. Original DLL/EXE files are preserved with unsupported behavior status and never executed. Bundle `status: "preserved"` does not imply that its objects are converted.

The importer rejects absolute, drive-qualified, traversal, backslash, control-character, and ambiguous paths; duplicate entries; Unicode/case-folding collisions including directory prefixes; file/directory ancestor conflicts; symlinks and special files; encrypted ZIPs; and unsupported ZIP compression. Default limits are 256 MiB archive bytes, 128 MiB per file, 512 MiB expanded ZIP bytes, 10,000 entries, expansion ratio 200, 1 MiB manifest XML, 8 MiB parsed CSV, and 16 MiB generated package JSON. XML DTD/entity declarations are rejected. Internal UnityFS expansion has a separate 256 MiB bound. Texture dimensions are at most 16,384 per axis and 16,777,216 pixels per texture, with a 67,108,864-pixel conversion budget across the package. Conversion does not alter the source archives.

## Importer verification

The 26 synthetic importer tests cover metadata/catalog preservation, migrations, deterministic output, order-independent IDs, source ZIP bundle order, non-`abdata` prefixes, extension-based registration, traversal and collision rejection, special-file rejection, bounds, atomic cleanup, existing-output protection, unsupported content, duplicate asset identities, shared PNG paths, and native dimension limits. The optional texture orchestration tests use a decoder stub; the following original sample separately exercises the actual UnityPy decoder.

The explicitly fetched 7,429-byte pupil archive has SHA-256 `a752961aaa15ba4b2eb836c3b6761210b55fdb55e5c69a42a4bf323450151c56`. Its package is `.local/reverse/mods/packages/smaller-heart-pupil/manifest.json`:

| Bundle | Converted asset | Dimensions | Source path ID |
| --- | --- | --- | --- |
| `abdata/chara/mt_eye_00.unity3d` | `cf_t_expression_00` | 256 × 256 | `5352768172534064575` |
| same | `cf_t_expression_00_low` | 128 × 128 | `6762769742024394720` |

Both PNGs decode and match their declared dimensions. A second import to a separate directory produced byte-identical manifests and payload files. The bundle also contains one AssetBundle metadata object, recorded as unsupported; no mesh, material, shader, or plugin behavior is silently marked converted. The native package reader validates hashes and images, and the native library searches an explicitly supplied package order by exact bundle path and asset name. That caller-selected order is not a reconstruction of source archive registration priority.

The two-archive local library was rescanned through `Tools/mods/library.py scan` with converter 1.1.0. It created two new immutable generations, retained both 1.0.0 generations, and preserved the selected mount order; neither archive was invalid. The NoHairAccs archive records no registered bundles, while the pupil archive records `abdata/chara/mt_eye_00.unity3d`. Both new file indexes and converted resource records exactly match their older generations. Hash verification and the observed order are recorded locally in `.local/reverse/mods/importer-1.1-rescan.json`; proprietary archives and generated packages remain ignored.

## Swift loading and native texture bindings

`Assets.SourceModPackage.load(url:)` validates the supported converter/schema,
relative paths, hashes, complete PNG decoding and dimensions. It keeps the entire
manifest, including unknown fields. A changed cache fails its hash check on the
next access. `SourceModLibrary` rejects duplicate mounted GUIDs so callers must
choose a version explicitly, and searches each package for an individual asset
in the supplied order. Different assets in the same bundle can come from
different packages. Missing assets return nil; source DLLs are never loaded.

The command-line inspector exercises the same native reader:

```sh
swift run --package-path Packages/Engine ikkoku-inspect mod /chosen/new-package/manifest.json
```

An appearance sidecar can mount converted packages and bind a texture key to its
source identity. This illustrative fragment requires an actual converted package
under the appearance folder; a material's `texture`, `bodyMask` or iris-highlight
texture field can then reference `convertedTexture`:

```json
{
  "modPackages": ["mods/example/manifest.json"],
  "textureBindings": {
    "convertedTexture": {
      "bundlePath": "abdata/chara/example.unity3d",
      "assetName": "example_texture"
    }
  }
}
```

The texture cache identity includes the mod GUID, stable asset ID, archive hash
and converted content hash. A binding with no matching mounted asset throws a
visible error, even if a loose fallback PNG happens to exist. No binding is
automatically inferred from a texture filename: source material composition and
catalog semantics need specific adapters before arbitrary content can be placed
correctly in Maker or Studio.

Native tests cover actual PNG loading through an appearance binding, no-fallback
failure, per-asset mount order, duplicate identities, shared content, unknown and
unsupported catalog metadata, stale caches, path/symlink escapes and malformed
PNGs. The real pupil package passes the native reader and resolver tests; its
report is `.local/reverse/mods/native-package-report.json`.

The full Swift suite passes 152 tests at this checkpoint. Python runs pass 55
reverse-pipeline tests and 40 mod-import/library tests. The
[incremental scanner](mod-library.md) discovers new local archives on rescan,
validates unchanged generations and persists explicit selections. Maker loads
and reloads those profiles, displaying conflicts and catalog dependency reports.
This scan is an explicit command; no background watcher is installed.

The [native catalog adapter](reverse-mod-catalog.md) preserves original identities
and the recovered CSV rules. Converter 1.1.0 records ZIP bundle registration order;
native source-key lookup strips any first path component and resolves each asset
in that order. Converter 1.0.0 packages remain loadable, but competing aliases need
reimport before source-key resolution. Exact archive-path appearance bindings
remain supported independently of aliases.

The [static ABMX adapter](reverse-abmx.md) now converts current `boneData` payloads
and applies supported modifiers after native body/face shaping. The
[native character-card reader](reverse-card.md) recovers those bytes directly
from current or legacy Extended Save data, while retaining the complete source
card and reporting unsupported settings. Original automatic
version priority, complete catalog behavior, additional assets/materials,
Extended Save round trips, migrations, dynamic/accessory ABMX paths and general
managed-code rewriting remain unfinished. No source DLLs execute in the native app.
