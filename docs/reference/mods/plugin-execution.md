# Translated plugin execution in Studio

Reviewed 2026-09-25. Accepted components execute and persist through the explicit
Studio IR host; the current port is **mid-stage for that subset** and **in its
infancy for arbitrary installed plugins**. The [plugin audit](../../component-audit/app-gameplay-and-plugins.md)
(P01–17, P-T01–05) tracks API coverage, immutable library integration and original
save adapters. Native adapter startup/UI defects are documented separately in
[installed adapters](native-adapters.md); they are not covered by the successful
IR-only fixture below.

Accepted C# components run in the Swift Studio host. A Roslyn frontend
resolves the original symbols, emits typed JSON IR and generated Swift, and
`SourcePluginRuntime` interprets that IR through `SourceStudioPluginWorld`.
Windows assemblies are statically decompiled, never loaded as native executable
code. Unsupported members reject the entire component with source locations.

## Package and identity

```sh
python3 Tools/translation/plugin.py path/to/Plugin.cs \
  --type Author.Plugin \
  --output .local/plugins/author-plugin
```

Run conversion commands from the repository root. Unrecognized DLL input uses
the local ILSpy CLI with `--references` available for its assembly directory.
Two exact registered original DLL hashes select [native adapters](native-adapters.md)
before decompilation; their packages contain original evidence/configuration,
rather than executable IR. Recovered sources and resulting packages stay in
ignored `.local/`. A translated package contains `manifest.json`,
`program/translation.json`, generated Swift and a conversion report. Rejection publishes diagnostics but no loadable manifest.
Existing output directories cannot be overwritten.

The manifest preserves BepInPlugin GUID, name, version, process filters,
dependencies and incompatibilities. Plain MonoBehaviours require explicit
`--guid`, `--name` and `--version`. A supplied identity cannot override recovered
metadata. Program hashes, source hashes, C# type/method names and GUID UTF-8 bytes
are retained; canonically equivalent Unicode GUIDs remain distinct.

Studio's **Mods → Load Translated Studio Plugins…** menu accepts a profile:

```json
{
  "schemaVersion": 1,
  "fixedDeltaTime": 0.02,
  "packages": [{
    "manifest": "../author-plugin/manifest.json",
    "bindings": [{"type": "Author.Plugin", "sourceObjectKey": 10}]
  }]
}
```

Each binding supplies exactly one original source key or native `objectID` UUID.
Dependency order is deterministic. Missing hard dependencies, incompatible
packages, duplicate identities, hard dependency version mismatches, cyclic
dependencies, process filter mismatches, changed program hashes and paths escaping a package fail load.
Installed Chainloader recovery also confirms that an outdated soft dependency
does not prevent loading, and process filters remove literal `.exe` before
case-insensitive comparison. Native process matching currently uses Foundation's
case-insensitive comparison; full non-ASCII source collation parity is not proven.
These rules live in `SourcePluginGraph`, which profiles, IR packages and native
adapters share. It also validates every declared version on its own; see
[dependency policy](#selection-and-dependency-policy). The fixed step is explicit:
the controlled original Unity player measured 0.02 s.

## Plugin library

Added 2026-10-23 as the P-T02 first slice and tested with synthetic fixtures
only. `Tools/translation/plugin_library.py` indexes packages already published
by `plugin.py`, translated and native-adapter alike, into immutable numbered
generations. `SourcePluginLibraryIndex` (Gameplay) reads them and resolves exact
selections. The Python tests run locally and in the public CI lane. The Swift
reader was not compiled locally; the CI Engine suite verifies it. No installed
plugin directory has been scanned.

```sh
python3 Tools/translation/plugin_library.py scan \
  --library .local/plugins/library --root .local/plugins/packages
python3 Tools/translation/plugin_library.py show --library .local/plugins/library
```

Repeat `--root` for several directories; later scans reuse the saved roots.
`show --generation N` prints an older generation. Revisions copy recovered
sources and original assemblies, so the scanner refuses a library inside the
repository unless it is under ignored `.local/`. It never loads or runs a DLL.

### Format

```text
library.json                    commit point: every published generation and its index hash
generations/000001.json         immutable generation index, one per number
revisions/<manifestSHA256>/     immutable copy of every file of one package
.staging/, .scan.lock           scratch and the advisory scan lock; never library content
```

`library.json` has `schemaVersion: 1`, `kind: "ikkoku-plugin-library"`,
`scanner` (`{"id": "ikkoku.plugin-library", "version": "1.0.0"}`), `roots`
(`id` is the SHA-256 of the absolute `path`), `current` and `generations`.
Each generation record is `{number, index, indexSHA256}`, numbered strictly
upward, and `current` is the last number. Each generation index has
`schemaVersion: 1`, `kind: "ikkoku-plugin-generation"`, `number`, `previous`
(`{number, indexSHA256}` or null), `scanner`, `roots`, `revisions`,
`conflicts`, `packages` and `diagnostics`. A revision record is:

```json
{
  "kind": "ikkoku-translated-plugin",
  "guid": "Creator.Mixed_é", "version": "1.2.3", "name": "Original name",
  "manifest": "revisions/<manifestSHA256>/manifest.json",
  "manifestSHA256": "...", "packageSHA256": "...",
  "processes": ["CharaStudio"],
  "dependencies": [{"guid": "Hard.ID", "minimumVersion": "1.2", "required": true}],
  "incompatibilities": ["Other.ID"], "types": ["Author.Plugin"],
  "converter": {"id": "ikkoku.translation", "irSchemaVersion": "1",
                "emitterSHA256": "...", "bridgeSHA256": "...", "semanticSurfaceSHA256": "..."},
  "sources": [{"rootID": "...", "relativePath": "author-plugin"}]
}
```

A revision's exact identity is its GUID, version and `manifestSHA256`. The
manifest pins the program hashes of an IR package and the original assembly and
configuration hashes of an adapter, so it also binds converter output. For an
IR package, `converter` repeats the program's emitter, bridge and semantic-surface
hashes; components from different converter revisions are rejected. An adapter
revision has kind `ikkoku-native-plugin-adapter` and converter
`{"id": "ikkoku.native-adapter", "adapterID", "sourceSHA256"}`. Its manifest
declares no dependencies or incompatibilities. `packageSHA256` is the SHA-256 of
the compact sorted-key JSON array of `{bytes, path, sha256}` for every package
file, ordered by UTF-8 path. Evidence files such as `conversion.json` and
`Translated.swift` are covered too.

`conflicts` lists each GUID with several revisions, with sorted
`manifestSHA256s`. GUIDs group by UTF-8 bytes, so `Creator.é` and its decomposed
spelling are two GUIDs. `packages` records every discovered directory with its
`rootID`, `relativePath`, `status` (`ready`, `rejected` or `invalid`) and
diagnostics. A `plugin.py` rejection (a `conversion.json` without a manifest) is
`rejected`, with `source_<CODE>` diagnostics. Generation `diagnostics` include
skipped `.plugin-stage-*` and symlinked directories. They also warn about missing
hard dependencies, unmet minimum versions and incompatibilities present in the
same generation.

### Generations and immutability

Every scan hashes and copies each regular package file into staging. Symlinks,
special files and non-canonical names reject the package, as do more than 256
files, 32 MiB per file or 96 MiB per package. The scanner then validates the
staged copy:

- strict UTF-8 JSON, without duplicate keys, non-finite numbers or unknown
  manifest fields;
- a bounded identity and a [standalone version](#selection-and-dependency-policy);
- program hashes, plus a ready component whose type and plugin GUID match;
- for adapters, a registered original-assembly digest whose adapter ID, type,
  identity and process list are identical (only Mute may keep a configuration).

A valid copy is renamed to `revisions/<manifestSHA256>/`. A new generation,
numbered one higher, is published only when its content differs from the
current generation's (every field except `number` and `previous`). An unchanged
rescan publishes nothing. The generation file is written beside its final name
and hard-linked into place, so it never replaces a file. The atomic replacement
of `library.json` is the commit point. Until then, readers keep seeing the
previous generation.

An interrupted scan leaves no staging files. A revision directory that was
already renamed is adopted on the next scan only if its bytes are identical.
Likewise, an unpublished generation file is adopted only when identical. A
differing one is skipped, which leaves a gap in the numbering.

Published generation files and revision directories are never rewritten. A
changed indexed revision reports `revision_changed`, and a deleted one
`revision_missing`. The same manifest with different files reports
`manifest_reused`, and an unindexed differing directory `revision_unindexed`.
Such a package is left out of the new generation, while older generations still
list it and fail to resolve it by name. A changed published generation file
blocks every later scan. Recovery is explicit: reimport into a fresh library.
There is no garbage collection.

### Selection and dependency policy

`SourcePluginLibraryIndex.load(libraryURL:generation:)` checks the generation
numbering, the index hash and record shapes, then recomputes the duplicate-GUID
conflicts. `select(guids:choosing:process:)` picks exact revisions. A GUID with
one revision in the generation is selected directly. A GUID with several needs
an explicit manifest SHA-256; neither a higher version nor discovery order
decides. The installed Chainloader's own duplicate rule has not been re-derived
for this policy.

A `SourcePluginLibrarySelection` records the library file, generation,
generation SHA-256, process and each revision's kind, GUID, version and manifest
hash. It always resolves against its recorded generation:

- another generation fails with `selectionMismatch`;
- a revision absent there fails with `revisionUnavailable`, naming the GUID,
  version, hash and generation;
- a rewritten generation index fails with `generationChanged`.

Upgrading is a new explicit `select` against the current generation.
`load(_:)` then verifies every selected package. IR revisions go through
`SourcePluginPackage.load` and must match the record's manifest hash, identity,
processes, dependencies, incompatibilities, types and converter hashes. Adapter
revisions go through `SourceNativePluginPackage.load`, which needs the exact
original assembly. Failures name the revision (`revisionInvalid`,
`revisionChanged`).

`SourcePluginGraph.order` is the one dependency graph for profiles and library
selections of both kinds:

- GUIDs compare as ordinal UTF-8 bytes. Case and canonical equivalence never
  match, and a duplicate GUID fails, including across kinds.
- Process filters apply as described above.
- Every package version and every declared minimum, including soft ones, must
  be 2–4 dot-separated ASCII decimal parts within Int32. Whitespace, signs,
  prefixes and suffixes are rejected even where .NET might parse them. Profiles
  now also reject a package whose own version is not numeric, even when nothing
  depends on it.
- A hard dependency must be present and meet its minimum under .NET ordering:
  an absent component is -1, so 1.0 is older than 1.0.0. An outdated soft
  dependency is not enforced, but a present soft dependency is ordered first.
- An incompatibility with a present GUID fails, including with itself. A cycle,
  including through soft edges, fails with its GUID path.

### Saved scenes and migration

`StudioDocument.sourcePluginLibrary` records the exact generation and revisions;
`sourcePluginLibraryConfiguration` records each converted component's source-key
or native-UUID target and fixed timestep. The Mods → Show Mod Library → Studio
Plugins tab inspects a published library, chooses exact versions and targets,
and mounts or unloads that selection. Reading the latest generation only changes
the available choices. Mount is the explicit replacement operation; it starts a
new selected runtime. Mounting the identical selection and bindings is a no-op.

For a UI mount, package bytes, hashes and IR decode are prepared off the UI thread. One mount is
prepared at a time. The existing runtime may keep stepping; owner-thread binding
and commit use the current document after verifying that the user has not edited
the scene or left Studio. Cancellation, invalid bindings, missing revisions and
failed installation leave the previous session, document and native adapters
intact. Unload is disabled outside Studio. Installation callbacks operate on an
isolated document; source-character attachment reads during installation are
explicitly unsupported because their live resolver can allocate previews. Those
reads use the existing resolver after commit. No package resolution, filesystem
reads or hashing occur in frame ticks or runtime snapshots.

Library-backed `SourceStudioPluginState` stores `libraryConfigurationSHA256` and
omits the external-profile fields. Its exact package identities, runtime fields,
clocks, source/native object identities, clone serial and tombstones retain their
existing representation. Legacy state keeps `profileFile`/`profileSHA256`; those
fields are now optional so both origins are explicit, and older documents still
decode. Profiles and individual native manifests remain supported separately.
A library selection must be unloaded before mounting an individual adapter.
Native save/reload resolves the recorded generation; a new publication never
upgrades it. Load and undo/redo stage restoration before replacing the live
session or history. Missing/changed files produce named errors. Plugin-library
restoration during native open or undo/redo still resolves files synchronously;
this slice does not move scene loading off the UI thread. Staged legacy-profile
restoration uses the same attachment-read gate, while a fresh legacy profile load
keeps its existing live resolver behavior. Plugin-library
root relocation is not supported by the asset-library relocation system; keep
the recorded root or explicitly mount a selection from its new location.

For automated captures, `IKKOKU_STUDIO_PLUGIN_SELECTION` names a JSON object with
`selection` and `configuration`, the same typed values the UI passes to Studio.
It cannot be combined with a legacy profile or separate adapter manifests. This
request file is an input convenience, not a new persistence dependency: the
native scene stores both values directly. A Studio scenario may run the bounded
`pluginLibrary` checks with a `requestFile` and no ordinary steps. Its barrier
holds the real background preparation for mode/document-change and rollback
checks; normal Studio scenarios keep their synchronous execution.

The 2026-10-24 Release acceptance at `8cb6d0a` passed 13 deterministic checks,
including a rejected legacy restore whose field initializer tries to read an
attached world transform. Repeating undo and trying redo preserve the old
document, session, adapters, rendered-preview identities and exact frame/resource
state. That rollback fixture uses two folders and no character previews. Normal
editor timers are paused for static cancellation assertions; a separate running
replacement check advances the old session during preparation.

The three-process mixed-library probe retained generation 1 with generation 2
available, exact fields/clocks/object bindings, and both registered adapters.
Run/reload pixels are identical with `--animation-time 0`, explicitly held in
every phase. This verifies plugin persistence under a controlled source-hand
clock, not general source-animation clock persistence. The historical probe
default remains import-only 0.5 seconds; the unequal-clock failure is retained
as evidence. The legacy startup capture also passes after declaring its required
source scene instead of attempting to bind object 10 in an empty document.

Visible UI acceptance on the same build opened the actual library, selected its
three generation-2 revisions, bound Source character 10, mounted, paused,
and unloaded. Reading the latest generation reset the browsing choices while
retaining the mounted selection. The new panel's Run/Unload controls were
disabled in Maker and enabled again in Studio; the legacy menubar Run command
was outside that control check. Generation 2 offered its current motion revision,
not the older generation-1 revision; old-selection restoration is the separate
automated proof. GUI save/reopen was not tested in this pass.

Functional timing diagnostics on that Release build: one initial mount took
112.88 ms end to end (preparation, scheduling and commit combined); 120 synthetic
two-folder steps averaged 0.01855 ms and snapshots 0.000642 ms. Whole-process
run/reload/continue took 3.268/1.149/1.205 seconds, including startup, assets,
rendering and PNG I/O. These ran alongside other development work and are not a
quiet performance comparison, isolated main-thread commit cost, or scene-open
responsiveness claim. No library/hash I/O occurs in the measured tick/snapshot
path; native open and history restoration still resolve synchronously.

Remaining work:

- Batch DLL triage that recovers each entry type, assembly-level dependencies,
  packages with several types, and converter migrations.
- Adapter dependency metadata in the registry, for when a registered plugin
  declares one.
- Recovery of the installed Chainloader's duplicate and `System.Version` rules
  from private evidence.
- A joint cross-language test. Each side's tests check the documented schema.

## Execution and persistence

The runtime handles Awake, OnEnable, Start, FixedUpdate, Update, LateUpdate,
OnDisable and OnDestroy. Its scene adapter converts Unity coordinates once,
resolves source character attachment frames, and excludes scale from self-space
Translate. A failed frame restores document changes, component fields, lifecycle
flags, clocks, pending destruction and trace together. A rejected attachment
also rolls back as one transaction. This matters because a field initializer can
reach Instantiate or SetActive, whose clone and activation callbacks run other
components before a later initializer fails.

These limits bound execution:

- 20,000 instructions per component for each top-level callback. A nested
  callback of the same component draws on the same fuel.
- 16 evaluation levels at run time; validation rejects nesting deeper than 24.
- Call depth 8, nested invocation depth 8 and nested activation depth 8.
- 64 nested Studio world transactions and, by default, 64 fixed steps per frame.
- 1,024 components; a further attachment is rejected as invalid.

Run-time limits raise the budget error, so recursive methods fail before
exhausting a native thread stack.

The original Unity 5.6.2f1 lifecycle probe establishes:

- Awake/OnEnable happen synchronously when an inactive object becomes active.
- Instantiate copies public and SerializeField state; private and NonSerialized
  fields use their initializers. Clone Awake/OnEnable happen before Instantiate
  returns.
- A clone made during Update receives Start/LateUpdate that frame; its first
  Update is deferred until the next frame.
- SetActive(false) invokes OnDisable synchronously.
- Destroy invokes OnDisable synchronously, skips the pending object's LateUpdate,
  and invokes OnDestroy at the frame barrier.

The source probe is `Tools/reverse/fixtures/OriginalLifecycleProbe.cs`; the private
trace and its hashes are under `.local/reverse/plugin-execution/lifecycle/`.
It runs inert components in a separate copied player with no installed saves or
plugins. It does not capture images or play audio.

Native scene cards retain immutable profile/package hashes, component fields,
clocks, original object identities, clone identities and destroyed-object
tombstones. Reload resumes the saved state without replaying Awake/Start and
leaves execution paused. A changed installed profile fails restoration instead
of remapping saved state. Original scene export rejects live native plugin state
because no original KKEx field adapter has yet been established for arbitrary
translated state. Native saves preserve it completely.

## Deterministic verification

`IKKOKU_SOURCE_PLUGIN_PROFILE`, `IKKOKU_SOURCE_PLUGIN_STEPS` and
`IKKOKU_SOURCE_PLUGIN_DELTA` execute a chosen number of frames before capture.
`IKKOKU_STUDIO_ANIMATION_TIME` fixes the initial animation time.
`IKKOKU_CAPTURE_GRID=0` and `IKKOKU_CAPTURE_GIZMOS=0` remove comparison-only
viewport overlays.

The retained 2026-09-25 logs record seven native runtime/package tests and ten
frontend/translation tests. This documentation revision did not rerun them.
The native tests cover coordinate and attachment semantics, malformed IR, rollback, identity/dependency handling, changed files and escaping
symlinks. With `IKKOKU_PLUGIN_FIXTURE` pointing to the packaged authored
`LifecycleFixture`, the end-to-end test executes Roslyn output, clones it,
destroys the clone, and round-trips native scene JSON with tombstones and exact
field/clock values. Frontend tests also compile generated Swift and, with original
fixtures available, compare 4,002 recovered numeric method evaluations against
unmodified original DLLs. Check executed fixture cases separately from a default
test run whose private-fixture checks may be skipped.

`SourcePluginFaultInjectionTests.swift` (P-T04 Swift slice, added 2026-10-23,
synthetic fixtures) checks the interpreter and Studio host without the .NET or
swiftc legs. Its verification is the CI Engine `swift test` run. It was not
compiled locally. The suite covers:

- Fixed-seed SplitMix64 mutation of IR and manifests. Each operation either
  commits with finite host transforms and declared field types, or throws a
  defined error and leaves the full snapshot unchanged. A second run must match
  the first.
- Random typed expressions checked bit for bit against an independent Swift
  evaluation, including NaN and infinity.
- Fuel, nesting, recursion, activation ping-pong and fixed-step budgets.
- Failures injected into each lifecycle callback and into
  Instantiate/Destroy/SetEnabled; retried runs must match a clean run in the
  order listed above.
- Attachment-resolver failures at every call of a frame, and an `afterUpdate`
  failure, through both the runtime and `SourceStudioPluginSession`.

IEEE results such as infinity remain bit-exact field values. Float literals
outside Float range and nonfinite transform writes are rejected.

This implements an explicit Unity/BepInEx subset. Coroutines, Harmony interception,
arbitrary engine components, reflection, serialized object fields and unrecognized
APIs still require recovery and adapters. Sheared/reflected unparented clone
transforms fail explicitly. Native behavior adapters for installed plugins are
reported separately from automatic AST conversion; see
[installed adapter import and persistence](native-adapters.md).

`Tools/translation/studio_execution_probe.py` exercises the actual release app:
load a controlled clothed original scene, execute 30 translated callbacks, save,
reload, compare pixels, execute another 30 callbacks, and verify unchanged source
keys/native UUIDs/GUIDs plus resumed fields without replaying Start. The private
`.local/reverse/plugin-execution/release-capture-01/report.json`, retained on
2026-09-25, passed for the **IR motion fixture only**, with identical reload pixels.

The probe also accepts repeated `--native-manifest` arguments. The later
`native-adapter-capture-01` run failed with the Mute `NSApp` initialization trap
before producing captures. That trap is now fixed in code (A-T04). With native
manifests, each phase also delivers `--focus-events`. It writes an adapter report
covering mounts, observers and generated-tone gain, which the probe checks; see
[native adapters](native-adapters.md#startup-and-acceptance). Both installed-disabled and explicit-enabled Release runs passed during PR #2
review; the reference records exact scope and private evidence. Wider plugin/UI
compatibility remains outside those controlled fixtures.

The successful IR-only capture supplied the following bounded performance sample.
That 600×800 scene contains 28 visible items and 60,761 drawn triangles. On the
M2 Ultra, 60 isolated scene-evaluation frames measured 4.684 ms p50 / 4.964 ms p95;
20 static GPU frames measured 0.529 ms p50 / 0.537 ms p95. The former includes
Animator/FK/IK, transforms, skin palettes and translated callbacks. These samples
had no matching dynamic hair chains. GPU timing excludes scene simulation,
readback and display scheduling. RSS was 379 MB and Metal allocation 416 MB;
these overlap on unified memory and must not be added. They are fixture timings,
not whole-game coverage or an end-to-end displayed frame-rate claim.
