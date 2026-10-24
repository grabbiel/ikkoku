# Offline plugin DLL inventory

`Tools/translation/plugin_inventory.py` discovers directly declared BepInEx plugin
metadata in DLLs beneath one directory. It reads bounded PE/CLI metadata snapshots;
it does not load assemblies, run attribute constructors or module initializers,
decompile methods, create packages, or mount plugins. This is the first P-T01
inventory slice, not an installed-plugin compatibility result.

Run from the repository root with the installed .NET 10 SDK:

```sh
python3 Tools/translation/plugin_inventory.py /path/to/BepInEx/plugins \
  --output .local/plugin-inventory/installed.json
python3 -m unittest discover -s Tools/translation/tests -p test_plugin_inventory.py -v
```

The first command builds the existing translation frontend in an ignored local
cache if its inputs changed. It then invokes the metadata reader sequentially for
each DLL. No NuGet package or assembly dependency resolution is needed. Original
metadata reports must remain beneath the checkout's ignored `.local/`; reports
can contain installed names and paths. Public tests compile synthetic fixture
assemblies locally and never execute them.

## Identity and report contract

The versioned JSON report records each relative file path, complete SHA-256 and
snapshot byte length, assembly name/version/culture/key/flags, assembly references,
referenced types, and member names/signature bytes. Member references are metadata
evidence, not proof that a call is reachable, supported, or required at runtime.
Generic member parents retain their metadata token/kind; this slice does not
expand TypeSpec signatures into API owners.

Each directly declared `BepInEx.BepInPlugin` attribute becomes a separate entry,
with its type and attribute metadata tokens. Multiple entries in one assembly,
duplicate GUIDs, and duplicate DLL copies remain separate. Nested type names use
metadata `Outer+Inner` spelling. GUIDs, names, versions, process filters and their
order remain exact; case and Unicode normalization are not applied. Discovery
requires the full attribute type name and a `BepInEx` assembly scope. This scope
check is not an authenticity check; only complete source hashes identify a
registered adapter revision.

The reader supports the known constructor forms for:

- `BepInPlugin(string guid, string name, string version)`.
- `BepInProcess(string process)` and `BepInIncompatibility(string guid)`.
- `BepInDependency(string guid, DependencyFlags flags)` and
  `BepInDependency(string guid, string minimumVersion)`; the latter implies a
  hard dependency. Known flag values are 1 and 2.

Unknown flags, overloads, named arguments, malformed blobs and invalid UTF-8
produce diagnostics. A malformed recognized plugin declaration remains a
candidate with its token and diagnostic; independently decoded declarations stay
visible. Parsed values alongside diagnostics must not be treated as accepted
runtime configuration. Malformed assembly-level metadata or a resource bound can
leave a partial report marked `invalid-metadata` or `unsupported-metadata`.

An entry whose complete DLL hash is in `native_adapters.py` receives an
`exact-source-sha256` adapter label with the existing registry identity. Other
files receive no adapter label. The report explicitly marks source recovery and
translation as not attempted, and host integration and original behavior
verification as not assessed. The scanner does not select duplicate GUID winners,
apply process filters, inherit attributes, validate base-class loadability, or
claim a file is loadable by the original Chainloader. Assemblies with no direct
plugin declarations remain visible as managed libraries.

## Bounds and failure behavior

Defaults are 1,024 DLLs, 32 MiB per DLL, 512 MiB of charged input bytes, 20,000
visited directory entries, and 16 directory levels. CLI `--max-files`,
`--max-file-bytes`, `--max-total-bytes`, `--max-entries` and `--max-depth` can lower
these or raise them within fixed ceilings. Directory entry and DLL count limits
abort the scan explicitly; size/depth exclusions are reported. Symlink files and
directories are skipped. The scanner assumes a stable offline tree and is not a
sandbox for a concurrently hostile filesystem.

Every attempted read consumes its reserved input budget, including malformed or
timed-out files. The helper rejects growth beyond the observed file size; it may
read one extra sentinel byte per attempted DLL. Hashing and metadata parsing use
the same snapshot. Each helper has a 30-second timeout, 100,000-row type/attribute
limits, 20,000-row reference limits, a 32-level nested-type limit, 256 attributes
per type, 64 KiB blob limits, a cumulative decoded-text budget, and a 16 MiB output
limit. The combined report is also limited to 16 MiB. No DLL-level parallel work
or runtime frame work is added.

A report is published only after the complete scan and report-size validation,
using a same-directory temporary file and atomic replacement. A failed scan does
not replace the prior report. It does not modify the scanned directory.

## Bounded acceptance, 2026-10-24

All 13 synthetic tests executed and passed with zero skips. The suite covers repeated/nested declarations, ordinal Unicode and
case, exact hashes, dependency forms and process order, wrong assembly scope,
unsupported overloads/flags/named arguments, malformed attributes and UTF-8,
managed/native/truncated files, absent dependencies, module-initializer
non-execution, byte/count/depth/symlink bounds, aggregate charging on failure,
repeat output, exact adapter matching, and the pre-existing translation command.

The private gate uses six already-retained original DLLs, totaling 416,256 bytes.
It finds six declarations and the two exact existing adapter revisions without
metadata diagnostics. Three entries are compared field by field with the
previous independent metadata survey (hash, type, identity, ordered processes,
dependencies and incompatibilities); both adapter entries match registry type and
identity. This does not scan or validate all 243 DLL paths in the historical
installed-directory listing. Repeated inventory reports must be byte-identical.
The private comparator passed 51 assertions, including assembly identity and
ordered assembly references. Two sequential six-file scans took 0.890 and 0.846
seconds, with a maximum child peak RSS of 94,273,536 bytes (about 89.9 MiB).
These are offline diagnostics collected with other compilation permitted, not a
quiet benchmark or an application frame-performance claim. The unchanged runtime
has no new inventory work in frame ticks. The 700,824-byte reports have the same
SHA-256 (`0efb1b16144b10b1cf13b11e9a2358bb64ff55201a61c97d3259cc71d9cb7016`).
Private inputs, reports, comparison assertions, helper provenance and timing live
under `.local/codex-continue-2026-10-24/wave-three/plugins/inventory/`.

## Complete installed snapshot, 2026-10-24

A separate read-only collection of the original
`C:\Illusion\Koikatsu\BepInEx\plugins` retained all 243 DLL paths and
26,759,208 bytes. This is the original installed corpus, not the isolated probe
player's injected plugin directory. Collection visited 310 entries with zero
exclusions, under limits of 1,024 DLLs, 32 MiB per file, 64 MiB total, 20,000
visited entries and 16 directory levels. Before/after manifests match canonical
root, exact paths, sizes, SHA-256 values and file timestamps; every transferred
snapshot matches its manifest. This establishes observed stability across reads,
not an atomic filesystem snapshot or publisher authenticity. Original names map
to ASCII snapshot filenames to avoid host filesystem case/Unicode collisions.
No original player or assembly was executed, and the source directory was not
modified.

The historical September 24 listing has the same 243 paths and sizes: no added,
missing or size-changed entries. Six previously retained content hashes match.
Historical hashes are unavailable for the other 237 files, so equal sizes do not
establish that their content is unchanged. The private manifest comparator's
seven tests passed with zero skips.

The unchanged scanner's first aggregate attempt explicitly failed its 16 MiB
report bound after inspecting 224 files. That failure remains separate from
acceptance. Eight fixed shards of at most 32 DLLs were then scanned twice, still
using the existing 16 MiB per-report limit and a 64 MiB budget across both sets.
The 16 reports total 42,301,142 bytes. Every one of the 243 unique original
path/hash/size identities maps one-to-one into both complete sets, and all eight
report pairs are byte-identical. An independent verification rehashed every
snapshot and checked report hashes, bounds, row mappings and declaration
identities. No scanner limit or implementation was changed for this collection.

The snapshot contains 212 DLLs with direct plugin entries, 30 managed libraries
without direct plugin entries, and one native/no-managed-metadata DLL. It has
218 direct declarations and 218 distinct GUID strings. Three DLLs declare
multiple entries (2, 3 and 4 respectively); all declarations remain separate.
There are no duplicate GUID groups or traversal/assembly/entry diagnostics in
this snapshot. Only the two existing registered native adapters match exact
source hashes. These counts describe metadata, not loadability, execution or
compatibility. Direct dependency references do not establish version or
load-order satisfaction, and member references do not establish reachability.

The two sequential scans took 32.096 and 32.360 seconds with other work allowed;
these are functional diagnostics, not quiet performance measurements. Private
manifests, the retained initial transfer failure, aggregate report-bound failure,
shards, complete coverage index, independent verification and reviewed
Cursor/DeepSeek support are under
`.local/codex-continue-2026-10-24/wave-three/plugins/installed-inventory/`.

Six small Studio candidates were subsequently recovered as hash-bound C#/IL for
static comparison. Their output manifests retain missing external references
and unknown-type annotations; no recovered project was compiled, executed or
packaged. The next proposed executable slice is the exact HideAllUI 2.3.2 Studio
path, whose recovered callback toggles game-canvas active state, optional plugin
canvas enabled state and an optional gizmo. Acceptance still requires a real
original Unity canvas/Find/lifecycle oracle, explicit native visibility roles,
mode/unload recovery and event-only updates. General Harmony/input compatibility,
Maker and H-scene behavior remain outside that proposed slice. The inventory
itself adds no new plugin execution support.
