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
prepared at a time on the same bounded serial queue used by Maker preparation.
Cancelling the caller, leaving Studio or editing the scene releases the pending
mount promptly while an already-running synchronous decoder retains its CPU slot
until it finishes. A retry waits behind that discarded work; no second resolver
runs concurrently. Request-owned model and panel state prevent an old completion
from clearing the retry's pending indicator, loading state, task or message.
The existing runtime may keep stepping; owner-thread binding
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
this slice does not move scene loading off the UI thread. Plugin-library
restoration retains its installation attachment-read gate. Legacy-profile native
open and history restoration use the candidate-owned read-only preparation
described below; fresh profile loading uses its separate installation transaction. Plugin-library
root relocation is not supported by the asset-library relocation system; keep
the recorded root or explicitly mount a selection from its new location.

Fresh-profile field initializers and active Awake/OnEnable callbacks may read a
source-character attachment. A candidate owns any cold preview it constructs and
uses an appearance transaction for new base textures; existing shared textures
remain borrowed. Warm previews are checkpointed on first attachment read, retaining
their shape, animation, dynamics and gaze history. If a later callback or saved-state
validation fails, assignment-only rollback restores those touched previews and
releases candidate meshes/textures without evicting another consumer's resources.
Successful installation transfers surviving previews to the live cache; Start is
still deferred until the first real runtime step. No checkpoint or resource scan
is added to normal frame ticks. Successful base textures use the existing cache
publication contract, including validated but unused inputs; failed candidates
publish none. Resource generation and handle counters are not rewound.

The retained #203 reproduction at `cdfc29e` passed 13 checks and failed one: a
rejected cold hidden-parent initializer retained one preview, 29 meshes, 18
textures and 12,505,092 mesh bytes after the later named Int32 arithmetic error.
The old document/session, runtime fields/clocks, adapters and sampled frame were
unchanged; this was a host-cache ownership failure. Successful hidden-initializer
and first-step Start controls passed separately. Release acceptance at `b6740b0`
(binary SHA-256 `b9e0a6f29808d3512160e6f7add72f6cb32f4512865b89b17a4e5b1da117c0f4`)
passed all six focused Engine tests with strict fixtures and no skips, all 32
source-backed isolation checks, and the 42 existing plugin checks. The cold
failure now retains no preview and exactly preserves active resource counts;
repeated partial constructors reach the named late animation-catalog error and
release their textures/meshes. Warm shape/clock rollback and subsequent pose
continuation preserve the existing rig and resources. The pre-commit pruned-object
check directly exercises the production preparation context; it does not claim
installation flushes the runtime's Destroy barrier. The malformed-neck-write
alias branch is source-reviewed, not independently fixture-executed. These are
functional results, with no quiet timing or speedup claim. The original failed
report and binary remain retained separately.

The saved-profile restriction is independently reproduced in
[#210](https://github.com/grabbiel/ikkoku/issues/210). A local regression-only
checkpoint at `6f999ea` mounts a supported hidden attachment initializer, saves a
native scene and reopens it in a separate process. All ten save checks and ten
reopen checks pass: the attachment profile hits the exact existing installation
gate, preserving the prior document/session, fields/clocks, adapters, history,
frame, preview identities and active resources. A valid-JSON profile whose bytes
changed still hits the saved-identity gate. An attachment-free control restores
exact saved state and advances its next step. This records an unsupported-policy
gap, not implemented restore support or a new regression. The accepted local
Release binary is `7654f79beeed754ff46c718668dc171522c0015cd5621ad5b039b908a63d1d6e`;
private evidence is under the existing `profile-native-restore` directory. No GUI,
performance or source-game parity claim follows.

The #210 implementation prepares ordinary attachment previews exclusively from
that native/history candidate's resolved references, coordinate and resource
policy. A matching UUID never borrows the previous scene's preview. Native open
uses animation time zero; history restoration uses the held history clock.
Successful preparation transfers surviving previews before the document refresh;
failure drops only candidate-owned preview and appearance leases. This uses the
ordinary preview cache, independently of route-child runtime bundles.

The newly supported restore path permits attachment reads only when initialization
leaves the candidate scene, clone serial and pending destruction unchanged. After
an actual successful attachment read, Instantiate, a visibility-changing SetActive,
or pending Destroy produces the explicit unsupported-restoration error before
history, cache or adapter commit. Saved fields/clocks keep their existing restore
order, and the input candidate remains the committed scene. Attachment-free
restoration and fresh-profile callback semantics are unchanged.

Release acceptance at `af6007a` (binary SHA-256
`bb383b496dba79e0755116fd9e6c054336434e30acb378d91809fd5abf249cf6`)
passes all 117 functional checks: ten native-save checks, 33 in a separate reopen
process, 32 existing fresh-profile isolation checks and 42 existing library/command
checks. Restore covers distinct same-UUID references/outfits/shapes/clocks,
candidate resource policy, repeated reads, transfer and subsequent step, undo/redo,
late initializer and partial-constructor failures. Each of the three mutation
rejections runs twice and reaches the exact policy error while retaining the old
session, document, history, previews, frame and active resources. Changed-identity
rejection and attachment-free restore remain separate passing controls. The
original unsupported-policy reports and binary remain preserved independently.
These are bounded functional results; no GUI, source-game parity or performance
claim follows. After integrating the prepared/fallback/batched appearance changes,
Release `baa32ea` (binary SHA-256
`ae11e3eb4cdba4d197859d18ab8aa4dbe95f46c6874d8aed6938973a2bbbca18`)
also passes the same 117 checks in four fresh processes, with zero failures or
skips. Its reports and input/build hashes are separate from the first acceptance.

A subsequent attachment-free reproduction at `b085ffab` exposed a different
restore inconsistency. All 18 save-process checks passed; a fresh reopen process
passed 22 checks and retained one failed first-step invariant. Replaying an
Instantiate field initializer left the committed scene with two saved objects
but the reconstructed runtime with three and an incremented clone serial. The
first step rejected that mismatch. The original red report, snapshots and Release
binary remain preserved under private `attachment-free-restore` evidence.

The shared restoring session constructor now snapshots the input object UUIDs,
normalized identity map (including tombstones) and clone serial before component
construction, then validates them after activation callbacks. Changed topology,
ordinal identity bytes or clone state produces a named preparation error before
native open or history can replace the old scene/session. Missing identities for
unbound input objects are normalized before the snapshot. Fresh installation
still adopts constructor-created objects; the new check runs only for restore,
with no frame-path work. This does not implement persistence for non-idempotent
cloning initializers. Same-topology SetActive and pending Destroy keep the existing
input-wins/first-step semantics demonstrated against the original session's
continuation. Attachment-reading restoration retains its stricter read-only
boundary; cloning now reaches the shared topology error first.

Release `4ebdd727` (binary SHA-256
`b39d288ce18bb511081ea6de86ba68b8a44a9949568753132871fa2886d4bbae`)
passes all 161 checks in six fresh processes: 18 synthetic save checks, 26
synthetic reopen/history checks and the existing 117 attachment/fresh-profile/
library checks. The cloning case now verifies exact rejection and retention of
the prior scene, session, history, frame and active resources through native open,
undo and redo. SetActive/pending-Destroy results still match the original session's
continuation. All 30 focused Engine tests pass with zero skips, including four new
parameterized tests through both profile and immutable-library constructors,
clone-then-Destroy, activation-time cloning and normalized unbound identities.
The first strict Engine attempt's missing HideUI fixture failure remains recorded;
the corrected run supplies the pinned original package. This is functional
acceptance without a GUI, original-player parity or measured performance claim.

Deferred lifecycle destruction has a separate native persistence boundary
([#221](https://github.com/grabbiel/ikkoku/issues/221)). At `5447fc20`, a synthetic
profile called Destroy from Awake and saved while paused before its first step.
The save process passed 15 checks; fresh reopen passed 25 and retained four real
failures: the pending request disappeared, the object survived the first step,
its lifecycle state differed, and OnDestroy did not run. The original session's
continuation removed the object and emitted OnDestroy at the same clock. No-op
and constructor-Destroy controls passed. The original reports, snapshots and
binary remain separate under private `pending-destruction-restore` evidence.

Native plugin snapshots now include optional `pendingDestructionRoots`: exact
root UUIDs in deterministic order, including independently queued descendants.
They do not serialize expanded descendant handles. New snapshots write an
explicit empty array when there are no requests. Missing/null state retains the
legacy empty seed; it cannot recover a request that an older writer omitted and
does not rerun completed Awake callbacks. Explicit empty also seeds no requests,
while existing constructor callbacks can still schedule new destruction.

The shared profile/library session constructor validates roots against the live,
normalized candidate world before creating the runtime or components. Duplicate
decoded UUIDs, unknown roots, identity tombstones and more than 10,000 roots
reject before callbacks. Pending subtrees are therefore inactive when saved
binding flags are restored. Destruction still occurs at the ordinary next frame
barrier; save/open never forces a tick. Snapshotting only sorts the pending root
set, with no scene/descendant traversal, file work or new tick scheduling.

The topology/identity/clone guard remains unchanged. The candidate-owned
attachment-read guard also remains unchanged: a restore that actually reads an
attachment and has pending destruction rejects explicitly before commit, even
when those roots came from saved state. This combination remains unsupported.
Older readers that ignore the new field do not gain queue persistence.

Release `e9e6198` (binary SHA-256
`31fa829571ecc2eb18461e40f6777e6526725dcd62944f3495b7bac893fb1ff7`)
passes all 222 checks across nine fresh processes: the unchanged 15+29 save/reopen
assertions, 15 malformed-root native/undo/redo checks, the prior 18+26 topology
controls and 119 attachment/fresh/library checks. The two new attachment-policy
checks reach the exact unsupported error after a successful read and retain the
prior scene, session, history, previews, frame and active resources. All 34
focused Engine tests pass with zero skips, including four new parameterized tests
through profile and immutable-library constructors. They cover exact overlapping
roots/unbound identity normalization, missing/null/empty state, malformed roots
and failed-step rollback/retry without duplicate destruction. The original red
binary/reports remain separate; no assertions were relaxed and no corrective
rerun was needed. These are native functional results, without a GUI,
original-player parity or comparative performance claim.

For automated captures, `IKKOKU_STUDIO_PLUGIN_SELECTION` names a JSON object with
`selection` and `configuration`, the same typed values the UI passes to Studio.
It cannot be combined with a legacy profile or separate adapter manifests. This
request file is an input convenience, not a new persistence dependency: the
native scene stores both values directly. A Studio scenario may run the bounded
`pluginLibrary` checks with a `requestFile` and no ordinary steps. Its barrier
holds the real background preparation for mode/document-change and rollback
checks; normal Studio scenarios keep their synchronous execution. The cancellation
follow-up also awaits cancelled callers before releasing the worker, distinguishes
mode/document/caller cancellation from queue supersession, and uses a never-executed
sentinel to prove a retry is queued without scheduler sleeps or yield loops. The
production queue itself is unchanged.

The cancellation follow-up at `fdf9fad` passed a Release build, all four existing
queue tests and 24 app-scenario checks on 2026-10-24. Cancelled callers returned
before worker release for mode exit, mode exit/return, document edit/return and
cancellation from another executor. The old document, session, adapters, exact
frame and resource counts remained unchanged. The queued retry alone committed;
stale panel completions retained the current loading state, task and message.
Observed caller return times were 0.059–5.501 ms, including the context change;
these are functional diagnostics with a held resolver, not a quiet latency
benchmark or decoder throughput claim.

Visible Cancel/retry acceptance also passed on 2026-10-24, using a separate
Release diagnostic build from PR #166 head `7f2c8b1`. A temporary worker-only
gate held the real resolver before package reads. Cancel restored the controls
and displayed the cancellation message while that worker was still held. A
retry remained queued until the old worker drained; its completion neither
mounted the old selection nor cleared the retry's pending UI. Releasing the
second worker mounted only the retry's three generation-2 revisions, bound to
Source character 10. Pause and Unload then worked. Screenshots, accessibility
states and gate-entry/release records are retained privately.

The diagnostic executable SHA-256 is
`4008a21f30cb7eff6d6c6d32f944d72d06e5ae5fc9bb6fa95170479ab5ff17e8`;
the uninstrumented production executable used for the 24 checks is
`3738410b6d6ca327ac3391b9552fd55e439c11c2e7002c4303c7cbc2a5a7f00b`.
Only diagnostic setup was patched; the production model, panel, scenario and
queue source hashes were verified unchanged. The exact patch was reversed and
the tracked tree checked clean before continuing development. This GUI run
proves cancellation/serialization behavior, not latency or decoder throughput.
The older acceptance below describes the preceding build.

Interactive legacy commands use the same Studio ownership boundary as library
mounts. “Load Translated Studio Plugins…” is unavailable outside Studio or during
a pending library mount. Its model entry checks that boundary before opening the
dialog and before reading the selected profile; the completion also requires the
generation captured before the dialog. Leaving and returning to Studio, or
unloading plugins, invalidates an older selection without changing the current
status. Both menu and library-panel Run/Pause actions use one guarded method that
also requires an existing session. These are event-only checks of narrow state;
they add no work to frame ticks and do not read the scene document for menu
availability. The programmatic startup loader and fresh-profile callback behavior
remain unchanged.

The bounded `pluginLibrary` scenario now includes held-preparation, inactive,
leave/return and unload rejection checks through those production methods,
comparing runtime snapshots, document/session identity, sampled shared-frame
fields and resource counts. It separately exercises active Run/Pause, successful
profile load, a normal missing-file failure and the inactive programmatic startup
path. Release build `14579b8` passed, and all 34 checks executed successfully
(24 retained plus ten new ownership checks), with zero failures or skips. The
executable SHA-256 is
`64bc93179a7f81454733c6645d8c677c086c2645d6c9112050a623e01839653f`.
This uses a synthetic two-folder Studio fixture; it is not a loaded-scene pixel or
latency measurement. A separate visible check on this same executable confirmed
active translated-profile Load and Pause, Pause → Run, disabled plugin commands
in Maker with its original inspector still visible, and restored enabled commands
in Studio without resuming the paused session. Run and Pause both remained usable.
The actual translated-profile dialog loaded the controlled profile and reported
one converted package; the owned process exited normally. These are accessibility
menu/action observations, not pixels or UI latency. Pending replacement and stale
dialog concurrency remain deterministic model checks. The mounted summary/Unload
for direct native or profile routes is a separate UI follow-up.

The mounted-panel follow-up displays all existing origins. A library selection
retains its exact generation and revision list. A translated profile has its own
section; individual native plugins have a
separate section with saved GUID, version and enabled state. Mixed profile/native
mounts retain both sections, without deduplication across origins or an invented
generation. The summary uses resident document pins and loaded session metadata,
with no manifest reads, digest computation or runtime snapshots. Its text area is
height-limited so Unload remains reachable for a larger package list.

Every mounted origin exposes the same Run/Pause and Unload controls. Run/Pause
still requires an executable session, while adapter-only mounts can unload.
An interactive Unload guard rejects inactive/pending actions before delegating to
the existing teardown; the programmatic method is unchanged. The deterministic
checklist compares the presentation value used by SwiftUI, including ordinal
identity, direct native save/fresh reload and fallback labels after unloading.
An empty-binding profile remains an explicit loader error; its rejected load
must retain the current session and summary. Optional empty presentation inputs
are checked separately without claiming that the loader accepts such a profile.
These assertions do not substitute for an AX check of visible controls.

The 2026-10-24 clean Release build at `71e1309` passed 42 plugin/session checks,
18 native-save steps and 9 fresh-process load steps, with no failures or skips;
the runner's 84 Python tests also passed. The saved native reference and exact
presentation identity survived reload; interactive unload restored all 20 fallback
labels while preserving the selected outfit and saved accessory visibility.
The first attempt retained two harness failures: an invalid assumption that an
empty-binding profile could load, and an ordinary fresh-load checklist still in
Maker mode. The corrected checklist selects Studio through `AppState` before
ordinary steps and preserves the loader and inactive-action guards. Special
mode/cancellation scenarios retain their own activation paths.

Visible acceptance on the same binary confirmed generation 1 with its three
identities, then opened the retained native scene through the actual File dialog.
Its individual-plugin summary had Run disabled and Unload enabled, without an
invented generation. Maker disabled both controls; the panel's Switch to Studio
button reenabled Unload. Actual unload restored `スロット01` with visibility off
and outfit 2 retained. The translated-profile dialog then loaded the controlled
profile; its separate summary, Pause → Run → Pause and Unload worked. Mixed-origin
and concurrent pending/stale cases remain automated coverage. The visible run
checked AX values/actions and readable layout; its screenshot was inspected but
not retained. No throughput or UI-latency claim follows from these functional runs.

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
tombstones. Reload restores lifecycle flags so completed Awake/Start callbacks
are not repeated; activation may run callbacks for a previously inactive binding.
Execution remains paused. A changed installed profile fails restoration instead
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

The `PluginLibraryScenario.frameRollback` reproduction extends this boundary to
the app's real source previews. Its independent control process writes successful
warm and subtree-clone continuations; separate warm and cold processes inject a
named `LateUpdate` failure after `advanceAnimation: true`, repeat it, then retry.
The cloned child's initializer reads its new parent's attachment through the
ordinary resolver. Failed-step comparisons retain exact documents, runtime state,
clocks, preview ownership, resources and current frame. Successful cross-process
comparisons remap only UUIDs through validated source identities and retain all
typed document/state fields, callback order and bit-exact pose matrices.

The retained 2026-10-24 Release run at `e984432` passed **44/44 checks** in three
fresh processes: 12 clean controls, 16 warm checks and 16 cold checks. Both
injected failures repeated the intended arithmetic error, restored exact state
and matched the independent control on retry. The input was the retained clothed
animation fixture (SHA-256 `b180727854178212f988b2c010044a14233c1dca379f9d279d03be01ed435d95`),
whose saved `0/4/0` animation resolves through the configured catalog. The earlier
compile failure, missing outer scenario `steps` startup failure and 0/2 control
failure on an unconverted saved `2/3/4` animation remain separate evidence;
neither failed app attempt ran injections. No rollback defect was reproduced and
no production behavior changed. The cold clone shares the original converted
assets, so this does not establish cleanup of every distinct cold texture input.
Functional step timings are diagnostics; they do not establish checkpoint cost,
source parity or a performance improvement.

The separate `PluginLibraryScenario.routeRollback` reproduction covers a route
child, which the character-preview case above deliberately omits. Both processes
reopen the same native seed to retain exact UUIDs. A clean process records three
successful-prefix continuations: moving at `1/30`, moving at `0.02`, and stopped
at `0.02`. The second process repeats the prefix, rejects two `LateUpdate`
callbacks after animation advancement, and retries. It compares exact route-child
matrices before and after a real refresh as well as document/runtime state,
resources, ownership and submitted frames. At `2d9dfc4`, the 2026-10-24 Release
control passed 16/16; the injected process passed 50/56. All six failures belong
to the moving `0.02` case: both rejected attempts changed only the child matrix's
x translation from `0.02666666545` to `0.02222222276`, including after refresh,
and retry reached `0.04444444552` instead of the clean `0.03999999911` at the same
`0.08` clock. Exact document/runtime/history/resource and ownership checks passed;
the `1/30` and stopped-route controls passed. This records the route-cache
reconstruction defect in [#226](https://github.com/grabbiel/ikkoku/issues/226).
The original red reports and binary remain retained. It establishes neither a
general callback failure nor an original-player parity or performance result.

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
