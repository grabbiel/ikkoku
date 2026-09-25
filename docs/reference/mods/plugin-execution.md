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
Standalone version validation and a shared IR/native-adapter dependency graph
remain pending. The fixed step is explicit: the controlled original Unity player
measured 0.02 s.

## Execution and persistence

The runtime handles Awake, OnEnable, Start, FixedUpdate, Update, LateUpdate,
OnDisable and OnDestroy. Its scene adapter converts Unity coordinates once,
resolves source character attachment frames, and excludes scale from self-space
Translate. A failed frame restores document changes, component fields, lifecycle
flags, clocks, pending destruction and trace together. Fuel, nesting, component
count and fixed-step limits bound execution. Recursive methods fail before
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

The probe also accepts repeated `--native-manifest` arguments, but the later
`native-adapter-capture-01` run failed with the Mute `NSApp` initialization trap
before producing captures. Adding those arguments is a regression target, not an
established passing workflow. Fix A-T04 before claiming combined adapter/IR
save-and-reload support.

The successful IR-only capture supplied the following bounded performance sample.
That 600×800 scene contains 28 visible items and 60,761 drawn triangles. On the
M2 Ultra, 60 isolated scene-evaluation frames measured 4.684 ms p50 / 4.964 ms p95;
20 static GPU frames measured 0.529 ms p50 / 0.537 ms p95. The former includes
Animator/FK/IK, transforms, skin palettes and translated callbacks. These samples
had no matching dynamic hair chains. GPU timing excludes scene simulation,
readback and display scheduling. RSS was 379 MB and Metal allocation 416 MB;
these overlap on unified memory and must not be added. They are fixture timings,
not whole-game coverage or an end-to-end displayed frame-rate claim.
