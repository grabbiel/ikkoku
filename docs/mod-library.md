# Incremental local mod library

`Tools/mods/library.py` discovers `.zipmod` files recursively beneath explicitly
selected local directories and calls the existing bounded `zipmod.py` importer.
It does not copy the Windows installation or search other machine directories.
The result is a native resource index and profile, not whole-mod compatibility.
Raw source files, catalogs and diagnostics remain in each imported package.
Texture2D conversion is optional and retains the existing importer's limits.

## Commands

First scan with the workspace's optional UnityPy environment:

```sh
.local/reverse/unitypy-venv/bin/python Tools/mods/library.py scan \
  --library .local/reverse/mods/library \
  --root .local/reverse/mods/source/mods --textures
```

Repeat `--root` to supply multiple directories. Later scans reuse saved roots and
the texture-conversion setting, so one command imports newly added archives:

```sh
.local/reverse/unitypy-venv/bin/python Tools/mods/library.py scan \
  --library .local/reverse/mods/library
```

The base `python3` interpreter works for raw preservation and catalog parsing.
`--no-textures` disables optional conversion. If texture conversion is requested
without UnityPy, a dependency diagnostic is emitted; the archive can still be
preserved. Installing or updating UnityPy changes the conversion configuration
identity and creates a new generation on the next scan.

To resolve a duplicate GUID, choose an exact archive SHA-256 listed in
`library.json`, rather than guessing which version string is newer:

```sh
python3 Tools/mods/library.py scan --library /path/to/library \
  --choose 'example.guid=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
```

`--clear-choice example.guid` removes that explicit selection. `--profile name`
selects a separate profile; names allow letters, digits, underscores and hyphens.
Repeat `--order GUID` in the desired order to replace the complete mount order.
An explicit order must list every currently selectable GUID exactly once.

## Selection and ordering

Inventory records are sorted by relative path, root ID and archive hash. Root IDs
are hashes of their canonical absolute paths, so reversing `--root` arguments
does not alter the result. File and directory symlinks are not followed. The
output library is excluded when it lies beneath an input directory.

A GUID with one distinct ready archive is automatically selectable. Identical
archive bytes in several locations produce one generation and one mount. Two
different archive hashes with the same GUID remain unresolved, even if their
version strings match. A profile's explicit hash must still be present and ready;
an unavailable choice is not replaced with another archive. Other GUIDs remain
mountable while a conflict is unresolved.

Existing selectable GUIDs retain their saved order. Newly selectable GUIDs append
in deterministic discovery order. Removed or unavailable GUIDs leave the active
mount list; a later return appends them again. This is a documented **native
default order**, not a reconstruction of Sideloader's archive-registration
priority. The exact resulting order is always persisted in the profile.

## Versioned manifests

The library writes `library.json` with:

```json
{
  "schemaVersion": 1,
  "kind": "ikkoku-mod-library",
  "converter": {"id": "ikkoku.zipmod", "version": "1.1.0", "sourceSHA256": "..."},
  "options": {"textures": true, "limits": {}, "dependencies": {"UnityPy": "1.23.0"}},
  "configurationSHA256": "...",
  "roots": [{"id": "...", "path": "/explicit/local/directory"}],
  "archives": [],
  "generations": [],
  "conflicts": [],
  "diagnostics": []
}
```

`options.limits` contains all numeric `zipmod.Limits` fields, not an empty object
in real output. The configuration hash covers this converter/options object,
including the converter file hash and installed UnityPy version when requested.

Each archive has `rootID`, `relativePath`, `status`, and `diagnostics`. Once its
bytes are read, it also has `archiveSHA256`, `bytes`, and `generationID`. A ready
entry adds `guid`, `version`, `packageManifest`, and `packageManifestSHA256`.
`ready` means the preserved package is valid; inspect package diagnostics to learn
which behaviors and asset types remain unsupported. Failed archives retain an
`invalid` entry without an active mount and do not abort unrelated imports.

`generations` retains package identities across removals and configuration
changes. `generationID` is exactly `archiveSHA256:configurationSHA256`. A package
manifest lives at this library-relative path:

```text
generations/<archiveSHA256>/<configurationSHA256>/manifest.json
```

The selected profile is `profiles/<name>.json`:

```json
{
  "schemaVersion": 1,
  "kind": "ikkoku-mod-profile",
  "name": "default",
  "configurationSHA256": "...",
  "choices": {"example.guid": "<archiveSHA256>"},
  "mountOrder": ["example.guid"],
  "mounts": [{
    "guid": "example.guid",
    "version": "1",
    "archiveSHA256": "...",
    "generationID": "<archiveSHA256>:<configurationSHA256>",
    "packageManifest": "generations/.../.../manifest.json",
    "packageManifestSHA256": "..."
  }],
  "unresolvedConflicts": [],
  "diagnostics": []
}
```

Conflicts contain `guid` and sorted `archiveSHA256s`. Diagnostics use
`code`, `severity`, and `message`. Profile mount paths resolve relative to the
library directory, not the profile directory. Native readers must check path
containment, configuration, manifest hash, GUID, version and archive identity
before accepting mounted resources.

## Cache and failure behavior

Every scan reads and hashes archive bytes. Modification time and length never
substitute for content identity. Conversion reads a temporary snapshot of the
same bytes that established the archive hash. Each completed package is validated
and renamed into its final generation directory atomically; existing generations
are never overwritten. Temporary snapshots and failed imports are cleaned up.

Before reuse, the scanner compares the manifest against its recorded hash and
checks every referenced raw file, catalog, bundle and converted texture hash.
Changed archive bytes or conversion settings create a distinct generation.
Removed archives stop mounting, while previous generations remain on disk. There
is no automatic garbage collection.

A tampered, missing or unindexed generation is reported as invalid and is never
silently reused or overwritten. Recovery is explicit: retain the diagnostic,
then use a fresh library directory to reimport the original archive. This also
avoids trusting an orphaned generation left by a process or machine interruption.

One scanner holds an advisory lock per library. Each index/profile JSON file is
replaced atomically, but the two files are not one filesystem transaction; native
readers must perform the identity checks above. An invalid profile edit leaves
the prior profile in place and records completed imports in the library index,
allowing a corrected rescan to reuse them. CLI setup/profile errors exit nonzero;
per-archive failures are reported in the successful scan's summary and index.

## Limits and verification

`SourceModProfile.load(libraryURL:profile:)` performs these identity checks and
mounts the selected packages. Maker's **Mods** menu opens, reloads and unloads a
library. Set `IKKOKU_MOD_LIBRARY` and optionally `IKKOKU_MOD_PROFILE` for startup
or headless captures. `IKKOKU_MOD_CATALOG_CONTRACT` selects a recovered catalog
contract; otherwise the app checks beside the library directory for
`catalog-contract.json`. An explicitly configured unreadable contract is an error.
Catalog entries and dependency statuses appear in the library view. Loading a
profile replaces appearance-sidecar package selection while preserving current
shape, expression and bone-modifier settings.

```sh
swift run --package-path Packages/Engine ikkoku-inspect mod-library /path/to/library/library.json
swift run --package-path Packages/Engine ikkoku-inspect mod-catalog /path/to/library/library.json /path/to/catalog-contract.json
```

This layer does not resolve original mod dependencies, catalog slot migrations,
Extended Save records, ABMX changes, arbitrary BepInEx plugins, or source conflict
priority. It does not run original DLLs. Unsupported data and conversion behavior
remain explicit package diagnostics. Native catalog interpretation is a separate
contract; indexing a preserved catalog does not prove its behavior is implemented.

Run synthetic tests without game content or UnityPy:

```sh
python3 -m unittest discover -s Tools/mods -p test_library.py -v
```

The tests cover addition/change/removal, unchanged size/mtime with changed bytes,
cache reuse and tampering, duplicate GUID choices, duplicate archive copies,
configuration/dependency changes, failing-import cleanup, deterministic persisted
order, unsafe symlinks, unavailable roots, profile-error recovery, and a real CLI
rescan. The existing `test_zipmod.py` suite remains the archive-format boundary.
