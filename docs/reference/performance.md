# App performance: harness, baseline and ranked costs (R7)

Reviewed 2026-10-23. Owning task: the representative performance gap (R7) in
the [renderer audit](../component-audit/renderer-and-foundation.md). This page
records how the app is measured, where its time goes on the reference machine,
the fixes that landed with the measurement, and every further optimization
found, each marked **measured** or **hypothesis**. Private inputs, reports and
Instruments traces stay under `.local/app-perf/`. Commands run from the
repository root.

## Summary

TBD

## Harness

`IKKOKU_PERF_TRACE=<report.json>` is a capture mode
([CaptureRequest.swift](../../Packages/Engine/Sources/Renderer/CaptureRequest.swift)):
the app opens its normal editor window, sets up one workload, waits
`IKKOKU_PERF_WARMUP_SECONDS` (default 3), records for `IKKOKU_PERF_SECONDS`
(default 10), writes the report and exits 0 (1 when the workload cannot run).
Every action calls the method the UI calls
([PerfWorkload.swift](../../Apps/IkkokuCreator/PerfWorkload.swift)): mouse
input goes through the viewport's `ViewportInputHandler` methods, Maker sliders
through the slider binding's array element, Studio selection, pose mode and
scene commands through `StudioModel`. Nothing is re-implemented, so the draw,
the model and SwiftUI run as they do for a user. The measured window floats
above other apps' windows (a script-launched app may not take focus, and an
occluded window is paced differently) and the process opts out of App Nap for
the run.

| `IKKOKU_PERF_WORKLOAD` | Fixtures | What it does |
| --- | --- | --- |
| `studio-idle` (default) | `IKKOKU_SOURCE_SCENE` | Studio, live animation on, nothing selected; blink, neck/eye look, hair dynamics and route clocks tick at 30 Hz |
| `studio-orbit` | same | `studio-idle` plus a right-button orbit drag: one `mouseDragged` per input tick |
| `studio-fk-drag` | same | selects source key 65, FK mode, bone 19 (the `fk-mouse-drag` scenario's grab), grabs the z ring found by `pickID` and drags it around a 40 px circle, one turn per 2 s; checks that the grab pushed exactly one undo snapshot |
| `studio-hover` | same | character selected, mouse moves over the viewport (`mouseMoved`, gizmo hover pick) |
| `maker-idle` | `IKKOKU_SOURCE_CARD` | Maker with the source card, idle animation, blink and hair |
| `maker-slider` | same | source customization on, the first bound body slider oscillates ±0.3 (one binding write per input tick) |
| `studio-native` | avatar, Maker library | New Scene, `IKKOKU_PERF_CHARACTERS` (default 6) native characters added with the Add menu's command, live animation |
| `startup` | as `studio-idle` | no workload; the report's `startupSeconds` marks are the result |

Other options: `IKKOKU_PERF_WINDOW_W`/`_H` (default 1600×1000 points; the size
is applied with the window's autosave name cleared, so the user's saved frame
is untouched) and `IKKOKU_PERF_INPUT_HZ` (default 120).

### What the report records

[PerfTrace.swift](../../Apps/IkkokuCreator/PerfTrace.swift), all on the main thread:

- every `CAMetalDisplayLink` callback: callback time, target presentation time,
  `Renderer.draw` duration (frame preparation, deformation and pass encoding,
  plus any wait for one of the three frame slots) and the last completed
  command buffer's GPU time (`gpuEndTime - gpuStartTime`);
- when each drawable was really presented (`addPresentedHandler`), giving
  presented FPS, presented-interval percentiles and hitches (an interval longer
  than 1.5 refresh periods; `skippedRefreshes` counts the periods it lost);
- main run-loop busy time (after-waiting to before-waiting observers), split
  into draw, model (ticks, refreshes and input handlers, nested intervals
  counted once) and other (SwiftUI updates, layout, AppKit event handling);
- Maker ticks and refreshes (explicit hooks in `MakerModel`), Studio live ticks
  and `refresh()` calls (inferred from properties they assign; explicit hooks
  wait until `StudioModel.swift` is free, see `PerfTrace.observeStudio`) and
  every viewport input call;
- process CPU, main-thread CPU, peak `phys_footprint` and peak Metal
  allocation, window occlusion samples and the machine's load average;
- startup marks in seconds since process start: `appStateInit`, `engineReady`,
  `sourceSceneImport.begin/.end`, `sourceCardImport.begin/.end`, `makerReady`,
  `studioReady`, `appStateReady`, `contentAppeared`, `firstDraw`;
- the build: Debug/Release, the app's and the Engine package's own assert
  configuration (`EngineBuild.assertConfiguration`, so an Engine compiled `-O`
  inside a Debug app is visible).

A Studio tick includes the `refresh()` it ends with; the tick column below is
the whole live step and the refresh column the frame rebuild inside it.

The same phases are `os_signpost` intervals in the Points of Interest category
of the `com.grabbiel.IkkokuCreator` subsystem (`Draw`, `Input`, `MakerTick`,
`MakerRefresh`, `Startup`, and `Mark` events), so every Instruments template
shows them next to its own tracks.

### Running it

```sh
python3 Tools/verification/perf_trace.py run \
  --app .local/build-release/Build/Products/Release/Ikkoku.app/Contents/MacOS/Ikkoku \
  --environment .local/verification/environment.json --out .local/app-perf/release
python3 Tools/verification/perf_trace.py summarize .local/app-perf/release .local/app-perf/debug
# Instruments: one .trace per workload next to its report.
python3 Tools/verification/perf_trace.py run --app … --environment … --out .local/app-perf/tp \
  --workloads studio-orbit --xctrace "Time Profiler"
python3 Tools/verification/perf_trace.py profile .local/app-perf/tp/studio-orbit.time-profiler.trace \
  --thread "Main Thread" --binary Ikkoku [--focus 'StudioView.body']
```

[perf_trace.py](../../Tools/verification/perf_trace.py) `run` launches one app
at a time (`--wrap` runs each launch under a lock script), bounds each launch
with its own timeout and maps the private fixture file the way the scenario
lanes do (`IKKOKU_STUDIO_SCENARIO_SCENE` becomes `IKKOKU_SOURCE_SCENE`,
`IKKOKU_MAKER_SCENARIO_CARD` becomes `IKKOKU_SOURCE_CARD`). `--xctrace
TEMPLATE` records the launch with `xcrun xctrace record`. `profile` keeps only
Time Profiler samples between the app's `recordingBegin` and `recordingEnd`
marks and prints time per thread and binary, the heaviest functions by self
and inclusive time and, with `--focus REGEX`, what the outermost matching frame
spends its time calling. [test_perf_trace.py](../../Tools/verification/test_perf_trace.py)
covers the launch environments, the summary row, the export reader and the
launch guard with synthetic data (it runs in the `runner-self-tests` check of
the public lane).

## Measurement setup

Reference machine: Mac Studio `Mac14,14`, Apple M2 Ultra (24 CPU cores
reported active, 76-core GPU), 192 GB, macOS 27.0.1, Xcode 27.0, a 1920×1080
point display at 120 Hz and backing scale 2. The measured window has a
1600×946 point content area, so the viewport drawable is 1996×1824 pixels.
Every run records the load average, thermal state and Low Power Mode with its
numbers; other agents shared the machine, so the load average was 4–10 during
these runs. All app launches ran one at a time under the machine-wide app
lock.

Scene: the private `IKKOKU_STUDIO_SCENARIO_SCENE` fixture
(`koikatu_cs0002591.png`, SHA-256 `029f0b1d…a8bea04`, 32 document objects, 6
source characters). Maker workloads use `IKKOKU_MAKER_SCENARIO_CARD`.

Builds, all arm64 from the same commit except where noted:

| Label | How it was built | Engine code |
| --- | --- | --- |
| Debug | `xcodebuild … -configuration Debug -derivedDataPath .local/build` | `-Onone` |
| Engine -O | the Debug app with a temporary, uncommitted `.unsafeFlags(["-O"])` on every Engine target in `Packages/Engine/Package.swift` | `-O` |
| Release | `xcodebuild … -configuration Release -derivedDataPath .local/build-release ARCHS=arm64` | `-O` (whole module) |
| … + quick wins | the same three recipes on the quick-win commit (`.local/build-qw`, `.local/build-qw-release`) | as above |

Debug numbers are reported for completeness only: the Engine is unoptimized
Swift there, so its costs are 10–50× the optimized ones and they rank costs
differently. The ranking and every percentage below use Release.

Frame budgets: 8.33 ms at 120 Hz, 16.7 ms at 60 Hz. A main-thread cost that
recurs N times per second uses N × cost ms of every second; a single cost above
8.33 ms always drops at least one 120 Hz frame because the display link, the
30 Hz Studio timer, input and SwiftUI share the main run loop.

## Baseline

TBD-BASELINE

## Ranked costs

TBD-RANKED

## Quick wins in this change

TBD-QUICK

## Optimization inventory

Status: **measured** means the cost was observed in this run (app harness,
Instruments or the Release probe described under [quick wins](#quick-wins-in-this-change));
**hypothesis** means the item follows from reading the code or from platform
knowledge and still needs a measurement before it is worth a change. Expected
gains are for the reference machine unless stated; the M1 column of the
[phase 2 plan](#phase-2-plan) scales them.

### Main thread and SwiftUI

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| M1 | All character work runs on the main thread inside the 30 Hz Studio timer, so any tick over 8.3 ms drops 120 Hz frames and a tick over 33 ms halves the timer rate | `StudioModel.advanceLiveFrame` | measured | baseline tick 43.4 ms at 15 ticks/s; the animation clock advances 1/30 s per tick, so live animation played at half speed | evaluate the source previews off the main thread and in parallel (each `SourceStudioCharacterPreview` is independent), double-buffer the resulting `RenderFrame` pieces; main thread keeps only the merge. After the quick wins the remaining ~9 ms/tick for 6 characters would drop to ~1.5–3 ms wall | High: previews are classes with caches and dynamics state; needs ownership rules and a deterministic join so captures stay byte-identical |
| M2 | Every document change re-evaluates all of `StudioView` | `StudioView.body` reads `model.doc` (workspace list, toolbar, inspector) | measured | TBD-SWIFTUI-ORBIT | TBD | Low–medium |
| M3 | Camera orbit, pan and dolly mutate `doc.camera`; the `doc` didSet then runs a full `refresh()` and invalidates every view that reads `doc` | `StudioModel` (`doc` didSet, `mouseDragged` `.orbit`) | measured | orbit: `refresh()` 0.89 ms × 76/s plus the SwiftUI cost of M2 per event | keep the view camera outside the observed document (or in its own observed property) and send camera-only changes straight to the renderer's frame uniforms without rebuilding items | Medium: the camera is saved with the document and undo must keep working |
| M4 | Maker slider writes invalidate the whole source rig panel | `SourceRigPanel.body` reads `sourceBodyValues`/`sourceFaceValues` for every slider | measured | TBD-SWIFTUI-SLIDER | TBD | Low |
| M5 | Hover pick is a synchronous GPU round trip per `mouseMoved` | `StudioModel.mouseMoved` → `Renderer.pick` (`waitUntilCompleted`) | measured | 2.02 ms p50 per event at 46 events/s with a selection | pick asynchronously (completion handler, apply the hover on the next frame) and only for the latest mouse position; a 1×1 scissor on the pick pass cuts its GPU work | Low; renderer file, after #127 |
| M6 | The Studio timer is a default-mode `Timer`; ticks skip while the timer handler is late and it does not fire during AppKit event tracking | `StudioModel.init` | hypothesis | the 15 Hz tick rate above is the late-handler case | drive the live step from the display link's target time with a fixed 1/30 s accumulator so animation speed never depends on main-thread load | Medium: the scenario lanes rely on fixed 1/30 s steps, which an accumulator keeps |
| M7 | Status-line churn | `StudioModel.tick` → `RenderStatusReporter.status` | measured (negative) | assigns only when the text changes | none needed | — |
| M8 | Native characters step hair dynamics once per `refresh()`, not per tick, so an orbit (one refresh per mouse event) runs their hair simulation faster than real time | `StudioModel.refresh` (`inst.stepHairDynamics(dt: 1/30)`) | measured (code path) | `studio-native` refreshes at 30/s idle; any extra refresh adds a 1/30 s step | step native hair only from the live tick | Behavior change; a correctness fix more than a performance one |

### Per-frame CPU work (Engine)

Numbers are from the Release probe after the two quick wins: 6 characters,
600 ticks, Time Profiler, ms per tick for all characters together (total
8.96 ms).

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | Animation sampling rebuilds a source-ID→node dictionary (~1,000 strings) per clip call and per state call and fills nested `[Int: [Int: [Float]]]` channel dictionaries | `SourceAnimationLibrary.applying(stateID:…)`, `applying(clipID:…)` | measured | 3.2 ms/tick, of which ~2.8 ms is dictionary building, lookups, string hashing and their allocations; curve sampling itself is 0.1 ms | resolve each clip's bindings to node indices once per (clip, rig) and reuse a flat channel table; ~2.5 ms/tick | Low: same arithmetic, same validation on first use |
| C2 | Hair dynamics rebuilds a full-rig transform state (all nodes, children lists, world matrices) per DynamicBone component per step and validates its output with a full `rig.evaluate` | `SourceDynamicBone.advance`, `DynamicsTransforms` | measured | 3.25 ms/tick: `DynamicsTransforms.init` 1.84, `pose(rig:)` 0.66 (`rig.evaluate` 0.48, `restPose` 0.13), teardown 0.32 | cache the topology per rig, transform only the required chains, validate only the changed nodes; ~2.5 ms/tick | Medium: must keep the float results bit-identical (same operation order) |
| C3 | `SourceStudioPose` is rebuilt for every pose evaluation | `KoikatsuCharacterRecord.makePose` | measured | 1.4 ms/tick (init 0.58, apply 0.51, late update 0.23) | cache the bound pose per (rig, record, kinematics) | Low |
| C4 | Eye look evaluates the whole rig to read four nodes | `SourceStudioCharacterPreview.updateEyeLook` | measured | ~0.1 ms/tick | evaluate the ancestor chains only | Low |
| C5 | Source expression weights are recomputed and revalidated per frame | `SourceRigPreview.expressionWeights` | measured | 0.45 ms/tick | cache per expression input | Low |
| C6 | `refresh()` rebuilds every character's `RenderFrame` (items, skin sets, bounds) for camera-only changes | `StudioModel.refresh` | measured | 0.89 ms per orbit event | see M3 | Medium |
| C7 | Maker's live step evaluates the rig only to validate the pose, then the refresh evaluates it again | `MakerModel.advanceSourceMotion` | hypothesis | `makerTick` 2.0 ms p50 in `maker-idle` | reuse the validated evaluation in the refresh | Low |
| C8 | Studio scene/character load decodes the same rig JSON once per character and component | `SourceMakerLibrary.prepare` → `SourceRig.load` | measured | probe load 6.1 s for 6 characters, 74% in `SourceRig.decode` (JSONDecoder) | cache decoded rigs by path, size and modification time; or a binary rig format | Low for the cache |

### Metal

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| G1 | GPU time is not the bottleneck on the reference machine | whole frame graph | measured | 1.3–1.9 ms GPU per frame at 1996×1824, 6 characters; draw encoding 0.6–0.9 ms CPU | — | — |
| G2 | MSAA color/depth, overlay depth and pick depth are already memoryless | `RenderTargets` | measured (code) | `storageMode = .memoryless` | — | — |
| G3 | Unchanged frames are fully re-rendered at the display rate, including the deform compute pass and the 2048² shadow map | `Renderer.draw`, `ViewportNSView` | measured | 120 draws/s while Studio content changes 30 times/s and the camera is still | skip prepare/encode/present when the frame and drawable size did not change (frame version counter); or lower `preferredFrameRateRange` when idle. ~3/4 of GPU and draw CPU at idle | Low |
| G4 | Skin matrices are copied into a new `MTLBuffer` per skin set per frame and validated element by element | `Renderer.buildContext` | hypothesis | allocation per draw; not separated in the profile | write skin matrices into the frame ring | Low; renderer file, after #127 |
| G5 | Shadow map re-rendered every frame | `Renderer` shadow pass | hypothesis | — | re-render only when casters or the light moved | Low |
| G6 | No pipeline binary archive | `Pipelines` | hypothesis | pipeline creation happens during startup | `MTLBinaryArchive` for the production pipelines; measure first-launch versus warm | Low |
| G7 | Textures are uncompressed RGBA with runtime mip generation | `ResourceStore` (`MTKTextureLoader`, `.generateMipmaps`) | hypothesis | Metal allocation 470 MB peak for 6 characters | ASTC/BC compression at conversion time, cached mips; mostly memory and bandwidth (M1) | Medium: image quality must be checked |
| G8 | Argument buffers / Metal 4 argument tables, indirect command buffers, residency sets, heaps, parallel encoding | renderer | hypothesis | draw encoding is ≤ 0.9 ms CPU per frame | low value until item counts grow (many-prop scenes) | — |

### Frame pacing

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| P1 | The display link runs on the main run loop, so every model or SwiftUI hitch is a presentation hitch | `ViewportNSView.viewDidMoveToWindow` | measured | idle baseline: 44.7 presented FPS, 150 hitches in 10 s while GPU and draw take < 3 ms | run the display link on a dedicated render thread; `Renderer` already snapshots the frame under `frameLock` | Medium: renderer state touched from two threads (errors, statistics, pick) |
| P2 | No `preferredFrameRateRange`; the link runs at 120 Hz while content changes at 30 Hz | `ViewportNSView` | measured | 120 callbacks/s when the main thread is free (`studio-native`, `maker-idle`) | with G3; 120 Hz only while the user drags | Low |
| P3 | Drawable size is the full backing size (1996×1824 here; ~3.8 K × 2.1 K full-screen on a 4K display) | `ViewportNSView.updateDrawableSize` | hypothesis | — | an opt-in render scale for low-end machines | Quality trade-off, opt-in only |
| P4 | Three frame slots with `preferredFrameLatency = 2` | `GPUContext`, `ViewportNSView` | measured (code) | no frame-slot waits in the draw timings | — | — |

### Startup and scene load

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | Source scene import is synchronous on the main thread | `AppState.importSourceScenePreview` → `StudioModel.importSourceScenePreview` | measured | Release: 4.7 s import, first frame at 6.3 s; Debug 11.7 s / 20.0 s | load the characters concurrently off the main thread with a progress state; ~1–1.5 s on the reference machine | Medium: model mutations must stay on the main actor |
| S2 | Repeated rig JSON decoding | see C8 | measured | 74% of the probe load | cache; ~3 s of the 4.7 s | Low |
| S3 | Texture loading through `MTKTextureLoader` with runtime mips | `ResourceStore.texture` | hypothesis | (another task investigates a loader stall) | asynchronous loading with placeholder textures | Medium |
| S4 | Maker library preparation at startup | `makerReady` mark | measured | ~0.9 s Release, ~4.1 s Debug | defer until first Maker use or load in the background | Low |

### Build configuration

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| B1 | Debug builds compile the Engine package `-Onone`; the Studio scene is unusable in a Debug app | `Packages/Engine/Package.swift` | measured | Debug tick 1.75 s (0 presented frames in 10 s) versus 42.9 ms with the Engine at `-O` inside the same Debug app | an opt-in optimized-Engine Debug configuration for app work (Engine stays debuggable by default) | TBD-B1 |

### Memory

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| R1 | Peak footprint ~0.94 GB with 6 source characters (Metal 470 MB) | whole app | measured | `studio-idle` Release | texture compression (G7); release staging data after upload; matters on 8 GB machines | Medium |

## Phase 2 plan

TBD-PLAN

## Limits of these numbers

TBD-LIMITS
