# App performance: harness, baseline and ranked costs (R7)

Reviewed 2026-10-23. Owning task: the representative performance gap (R7) in
the [renderer audit](../component-audit/renderer-and-foundation.md). This page
records how the app is measured, where its time goes on the reference machine,
the fixes that landed with the measurement, and every further optimization
found, each marked **measured** or **hypothesis**. Private inputs, reports and
Instruments traces stay under `.local/app-perf/`. Commands run from the
repository root.

## Summary

On the reference machine (M2 Ultra, 120 Hz display), the Release app showed
the 6-character source scene at 44.7 presented FPS while idle and at 24–53 FPS
while orbiting, dragging an FK ring or dragging a Maker slider. A native
6-character scene and Maker idle held 118–119 FPS. The GPU is not the limit
there: a frame takes 1.3–2.1 ms of GPU time. The main thread is the limit.

1. **The 30 Hz Studio live tick.** It took 43.4 ms for six source
   characters, so the timer fell to 15 Hz. Because every tick advances the
   clock by 1/30 s, live animation also ran at half speed. Three Engine fixes
   in this change remove repeated work without changing a single output byte
   (a rig name walk per catalog bone, a pose solved several times per tick,
   and the animation bindings resolved through dictionaries on every call).
   They bring the tick to 6.34 ms at 30 ticks per second, and the idle
   scene to 120.0 FPS with no hitches.
2. **SwiftUI work on every interactive edit.** Each orbit event, Maker
   slider write or FK drag event costs 7–25 ms of SwiftUI graph update and
   layout, because the Studio and Maker views observe whole documents and
   arrays. The main thread then stays about 1000 ms/s busy. This is the main
   lag left after the quick wins. Its fix restructures `StudioModel.swift`
   and the views, so it is phase 2.
3. **The display link shares the main run loop**, so any cost above turns
   into a presentation hitch.

Debug builds cannot use a source scene: a tick takes 1.75 s because the
Engine is compiled `-Onone`. Every capture in this change was byte-identical
between Debug and Release. That supports an opt-in optimized-Engine Debug
build (B1).

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
  and `refresh()` calls (inferred from properties they assign, see
  `PerfTrace.observeStudio`; explicit hooks in `StudioModel.swift` are left to
  phase 2, which changes that file anyway) and every viewport input call;
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
TEMPLATE` starts the app itself and attaches `xcrun xctrace record --attach
<pid>` to it: `xctrace --launch` resolves an executable inside an `.app` through
Launch Services by bundle identifier and can start another checkout's build of
the same app, which happened during this work (those traces were discarded),
so `profile` also prints the traced process path. `profile` keeps only Time
Profiler samples between the app's `recordingBegin` and `recordingEnd`
signposts; for a trace without them it shifts the report's marks onto trace
time through a startup mark both contain (`--report`, default: the report
beside the trace). It prints time per thread and binary, the heaviest functions by self
and inclusive time and, with `--focus REGEX`, what the outermost matching frame
spends its time calling.

`summarize` also checks that each run is valid:

- **Drawables never shown.** A drawable whose presented time is 0 was never
  shown on screen. The window was not being composited when either of these
  holds:
  - more than a tenth of a run's drawables were never shown while its main
    thread had time to spare (under 900 ms/s busy);
  - more than a quarter of at least 100 drawables were never shown, even
    with the main thread saturated.

  This happens, for example, while someone switches desktops or full-screen
  apps during the run. A Debug source scene, whose frames take seconds, can
  lose its few drawables legitimately, so a run with fewer than 100
  drawables is not flagged on a saturated main thread.
- **Stray input.** An idle workload (`studio-idle`, `maker-idle`,
  `studio-native`, `startup`) sends no input. Any input calls in its report
  came from someone's mouse over the window, so the run is checked against a
  rerun.

`summarize` prints a `WARNING` for each flagged run. `run` repeats a launch
whose window was not composited (`--retries`, default 2) before giving up.

The check was added after the baseline. Of the runs cited for frame rates,
only the Engine -O `studio-idle` baseline trips it (82 of 460 drawables never
shown). Its presented FPS and hitches are marked in the table; its
model-side numbers are unaffected. Every other frame rate on this page comes
from runs without the warning.

[test_perf_trace.py](../../Tools/verification/test_perf_trace.py)
covers the launch environments, the summary row, the validity checks, the
retry of a hidden run, the export reader and the launch guard with synthetic
data (it runs in the `runner-self-tests` check of the public lane).

### Measuring a change

Any task that may change the app's speed measures it this way:

1. **Build Release** for the commit before the change and for the change,
   each with its own derived data path (`xcodebuild -project Ikkoku.xcodeproj
   -scheme IkkokuCreator -configuration Release -derivedDataPath <dir>
   -destination platform=macOS,arch=arm64 build`). Debug numbers do not rank
   costs (B1). Delete the builds when the runs are done.
2. **Run the workloads that exercise the change** on both builds with
   `perf_trace.py run --wrap <app lock script>`, so every launch takes the
   machine-wide app lock and is bounded by its own timeout. Keep the
   defaults (3 s warmup, 10 s recording) unless the change needs longer.
   Write reports to the task's private `.local/<task>/` folder.
3. **Check validity.** `run` repeats a launch whose window was not composited
   (`--retries`, default 2), and `summarize` prints a `WARNING` for any run it
   still distrusts. Never cite a warned run. Compare runs only from the same
   machine, display and refresh rate (the report's `display` and `machine`
   blocks), with no build or other heavy job running.
4. **Report** the cost as ms per occurrence × rate per second, and as a share
   of the 8.33 ms (120 Hz) and 16.7 ms (60 Hz) frame. Use the main busy time
   and the model phases rather than presented FPS for saturated workloads,
   whose FPS varies from run to run.
5. **Attribute** a cost with one short Time Profiler run (`--xctrace "Time
   Profiler" --seconds 5`) and `profile --thread "Main Thread" --focus
   REGEX`. Traces are large: delete each one unless it is cited, and archive
   cited ones outside the repository.
6. **Renderer cost without the window**: `IKKOKU_AUTOCAPTURE` with
   `IKKOKU_BENCHMARK_OUTPUT`, `IKKOKU_CAPTURE_W`/`_H` and
   `IKKOKU_BENCHMARK_FRAMES` renders the frame offscreen and records CPU
   encode, GPU and completion times.
7. **Speed never changes output silently.** A change that should not alter
   pixels keeps byte-identical captures. A quality trade-off is opt-in and
   reported separately.

A new workload is added in three places: `PerfWorkload.swift`, the
`perfWorkloads` values in `CaptureRequest.swift` and `WORKLOADS` in
`perf_trace.py`.

## Measurement setup

Reference machine: Mac Studio `Mac14,14`, Apple M2 Ultra (24 CPU cores
reported active, 76-core GPU), 192 GB, macOS 27.0.1, Xcode 27.0, a 4K display
at 120 Hz (1920×1080 points at backing scale 2). The measured window has a
1600×946 point content area, so the viewport drawable is 1996×1824 pixels.
Every run records the load average, thermal state and Low Power Mode with its
numbers; other agents shared the machine, so the load average was 4–10 during
these runs. All app launches ran one at a time under the machine-wide app
lock.

Scene: the private `IKKOKU_STUDIO_SCENARIO_SCENE` fixture
(`koikatu_cs0002591.png`, SHA-256 `029f0b1d…a8bea04`, 32 document objects, 6
source characters). Maker workloads use `IKKOKU_MAKER_SCENARIO_CARD`.

Builds, all arm64. The baseline builds are from `9e02a62`: the harness on top
of `7af03d6`, which merged `main` at `7c0b884`, with no quick win.

| Label | How it was built | Engine code |
| --- | --- | --- |
| Debug | `xcodebuild … -configuration Debug -derivedDataPath .local/build` | `-Onone` |
| Engine -O | the Debug app with a temporary, uncommitted `.unsafeFlags(["-O"])` on every Engine target in `Packages/Engine/Package.swift` | `-O` |
| Release | `xcodebuild … -configuration Release -derivedDataPath .local/build-release ARCHS=arm64` | `-O` (whole module) |
| … + quick wins 1–2 | Debug and Release on `5b01c92` | as above |
| … + quick wins 1–3 | Debug and Release on `0a19718` | as above |
| merged head | Debug and Release on `0d4548a`: quick wins 1–3 with `main` at `5e86b57` (#127) merged | as above |
| `main` | Debug and Release on `5e86b57`, without the harness, for the byte-identity captures | as above |

The quick-win builds were deleted after their runs; every build here can be
rebuilt from its commit.

Debug numbers are reported for completeness only: the Engine is unoptimized
Swift there, so its costs are 10–50× the optimized ones and they rank costs
differently. The ranking and every percentage below use Release.

Frame budgets: 8.33 ms at 120 Hz, 16.7 ms at 60 Hz. A main-thread cost that
recurs N times per second uses N × cost ms of every second; a single cost above
8.33 ms always drops at least one 120 Hz frame because the display link, the
30 Hz Studio timer, input and SwiftUI share the main run loop.

## Baseline

These runs come from the baseline builds (`9e02a62`, no quick win). Each workload had one 10 s
recording after a 3 s warmup (private reports in
`.local/app-perf/baseline-3/{release,engine-o,debug}`).

How to read the table:

- Busy is main run-loop time per second, split as draw / model / other.
- Tick and refresh are p50 ms × the rate per second.
- Draw is `Renderer.draw` CPU time p50 and GPU is command-buffer GPU time p50,
  both per frame.

| Workload | Build | Presented FPS | Hitches/s | Presented interval p50 / p95 ms | Main busy ms/s (draw / model / other) | Tick | Refresh | Input p50 ms | Draw ms | GPU ms | Peak MiB |
| --- | --- | ---: | ---: | --- | --- | --- | --- | ---: | ---: | ---: | ---: |
| studio-idle | Release | 44.7 | 14.9 | 8.3 / 50.0 | 680 (31 / 651 / 0) | 43.38 × 15 | 23.25 × 15 | – | 0.67 | 1.90 | 935 |
| studio-idle | Engine -O | 37.4 (window partly off screen) | 14.9 (same) | | 673 (31 / 644 / 0) | 42.87 × 15 | 23.28 × 15 | – | 0.68 | 1.90 | 941 |
| studio-idle | Debug | 0.0 | 0.0 | | 997 (13 / 986 / 0) | 1753 × 1 | 1015 × 1 | – | 10.38 | 3.54 | 900 |
| studio-orbit | Release | 40.0 | 32.2 | 25.0 / 41.7 | 996 (33 / 74 / 889) | – | 0.89 × 76 | 0.97 | 0.81 | 1.37 | 945 |
| studio-orbit | Engine -O | 50.3 | 19.3 | | 987 (41 / 133 / 813) | – | 1.02 × 114 | 1.16 | 0.80 | 1.39 | 950 |
| studio-orbit | Debug | 14.2 | 11.6 | | 1172 (120 / 782 / 270) | – | 51.51 × 12 | 51.85 | 10.09 | 1.83 | 917 |
| studio-fk-drag | Release | 24.6 | 24.1 | 41.7 / 66.7 | 991 (22 / 160 / 808) | – | 4.12 × 57 | 5.62 | 0.89 | 1.87 | 962 |
| studio-fk-drag | Engine -O | 38.0 | 37.7 | | 989 (34 / 259 / 696) | – | 4.17 × 85 | 6.06 | 0.87 | 1.87 | 966 |
| studio-fk-drag | Debug | 0.0 | 0.0 | | 1000 (40 / 897 / 63) | – | 172.96 × 8 | 232.84 | 10.28 | 1.88 | 948 |
| studio-hover | Release | 44.9 | 15.0 | 8.3 / 50.0 | 758 (29 / 726 / 3) | 41.77 × 15 | 22.69 × 15 | 2.02 | 0.63 | 1.76 | 975 |
| studio-hover | Engine -O | 49.8 | 13.5 | | 782 (38 / 716 / 28) | 43.56 × 13 | 23.69 × 13 | 2.51 | 0.75 | 1.75 | 984 |
| studio-hover | Debug | 0.0 | 0.0 | | 1001 (7 / 992 / 2) | 1730 × 1 | 999.69 × 1 | 14.39 | 10.14 | 2.48 | 936 |
| maker-idle | Release | 118.4 | 1.6 | 8.3 / 8.3 | 136 (70 / 57 / 9) | 2.02 × 30 | 0.36 × 30 | – | 0.55 | 0.60 | 762 |
| maker-idle | Engine -O | 119.4 | 0.6 | | 137 (69 / 59 / 9) | 2.12 × 30 | 0.37 × 30 | – | 0.56 | 0.60 | 764 |
| maker-idle | Debug | 58.5 | 15.0 | | 664 (145 / 518 / 1) | 33.89 × 15 | 8.40 × 15 | – | 2.42 | 0.61 | 767 |
| maker-slider | Release | 53.1 | 34.7 | 16.7 / 33.3 | 997 (16 / 72 / 909) | 0.73 × 30 | 0.71 × 93 | 0.78 | 0.30 | 0.60 | 761 |
| maker-slider | Engine -O | 52.1 | 35.2 | | 997 (16 / 72 / 909) | 0.70 × 30 | 0.73 × 93 | 0.80 | 0.30 | 0.60 | 761 |
| maker-slider | Debug | 13.3 | 13.2 | | 993 (35 / 772 / 186) | 33.30 × 12 | 26.01 × 25 | 26.57 | 2.61 | 0.60 | 763 |
| studio-native | Release | 118.6 | 1.4 | 8.3 / 8.3 | 172 (107 / 53 / 12) | 1.81 × 30 | 1.77 × 30 | – | 0.88 | 1.26 | 722 |
| studio-native | Engine -O | 118.9 | 1.1 | | 162 (96 / 55 / 11) | 1.89 × 30 | 1.78 × 30 | – | 0.80 | 1.27 | 721 |
| studio-native | Debug | 119.2 | 0.8 | | 403 (295 / 98 / 9) | 3.31 × 30 | 3.26 × 30 | – | 2.48 | 1.29 | 737 |

Startup, seconds since process start (`startup` workload):

| Build | appStateInit | engineReady | makerReady | Source scene import (duration) | appStateReady | firstDraw | Peak MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Release | 0.08 | 0.09 | 1.01 | 4.71 | 5.81 | 6.29 | 936 |
| Engine -O | 0.07 | 0.09 | 1.00 | 4.67 | 5.76 | 6.21 | 937 |
| Debug | 0.08 | 0.09 | 4.20 | 11.71 | 16.03 | 19.97 | 889 |

How to read these numbers:

- **Saturated workloads vary from run to run.** When the main thread is
  saturated (orbit, FK drag, slider), the input timer and the display link
  compete for the same run loop. So the input rate and the presented FPS of
  those workloads changed between otherwise equivalent builds: Engine -O
  presented 50 FPS against Release's 40 for orbit, with 114 against 76 input
  refreshes per second. Read them as "saturated", not as a ranking of the two
  builds.
- **Engine -O matches Release** wherever Engine code dominates (idle tick 42.9
  against 43.4 ms; startup within 0.1 s). In those cases the gap between Debug
  and Release is the Engine's optimization level, not the app target's.
- **The Instruments traces** behind the ranking are in
  `.local/app-perf/baseline-3/xctrace-2`. They were recorded on the same
  commit with Release builds: Time Profiler for six workloads, Metal System
  Trace for idle and native, Animation Hitches for orbit, SwiftUI for FK drag
  and Allocations for idle.

## Ranked costs

The ranking uses the Release baseline, ordered by how much main-thread or
frame time each cost takes in the workload where it appears. The two budget
columns give the cost of one occurrence as a share of one frame. A cost above
100% at 120 Hz drops at least one frame every time it runs. A cost that runs
many times per second also crowds out everything else on the main thread,
which the "per second" column shows.

| Rank | Cost | ms per occurrence | % of 120 Hz / 60 Hz frame | Per second | Location | Root cause | Fix | Gain | Risk |
| ---: | --- | ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | Studio live tick, 6 source characters | 43.4 | 521% / 260% | 651 ms/s at 15 ticks/s (target 30) | `StudioModel.tick` → `SourceStudioCharacterPreview.frame`/`editedPose` | repeated work per tick (quick wins 1–3) and all character work serial on the main thread (M1) | quick wins 1–3 (this change), then C2, C3, M1 | 43.4 → 6.34 ms measured in the app; 30 ticks/s restored | low for 1–3 (byte-identical); high for M1 |
| 2 | SwiftUI update and layout per FK drag event | 24.5 | 294% / 147% | 673 ms/s at 27.5 drag events/s | `GraphHost.flushTransactions` for `StudioView`; `StudioModel.doc` didSet | an FK edit mutates `doc`; `StudioView.body` and its inspector read `model.doc`, so the whole window's view graph is re-evaluated and laid out again; each drag event also triggers two `refresh()` calls (55/s) | M2 + M3: per-panel observation, FK and camera state outside the observed document | most of 673 ms/s; target < 2 ms per event (hypothesis) | medium |
| 3 | SwiftUI update and layout per Maker slider write | 11.7 | 140% / 70% | 775 ms/s at 66 writes/s | `SourceRigPanel.body`; `NSHostingView.layout` 591 ms/s | each write replaces `sourceBodyValues`. The whole panel and every slider row (52 face sliders plus the bound body sliders) are rebuilt and re-laid out: `Slider.body` 53 ms/s, binding location compares 52 ms/s, material effect updates 111 ms/s | M4: slider rows as separate views over value inputs, the slider list outside the panel's other state | most of 775 ms/s (hypothesis) | low |
| 4 | SwiftUI update and layout per orbit event | 7.4 | 89% / 44% | 733 ms/s at 100 events/s | same as rank 2 | `orbit` writes `doc.camera`; the view graph work is as in rank 2. Of 997 ms/s busy, Ikkoku's own `body` code is ~25 ms/s; the rest is framework diffing (`ViewBodyAccessor.updateBody` 194 ms/s), `NSHostingView.layout` (148 ms/s) and AppKit control layout (`NSSegmentedCell` 87 ms/s, the toolbar and inspector segmented pickers) | M3 (camera outside `doc`), then M2 | as rank 2 | medium |
| 5 | Studio `refresh()` in an FK drag | 4.12 per refresh, 2 per drag event | 99% / 49% per event | 235 ms/s | `StudioModel.refresh` → character frames | each frame rebuild re-runs the pose pipeline (C1–C3) | quick wins 1–3 | 4.12 → 1.64 ms per refresh (quick wins 1 and 2, measured) | low |
| 6 | Hover pick, synchronous GPU round trip | 2.02 | 24% / 12% | 93 ms/s at 46 events/s | `StudioModel.mouseMoved` → `Renderer.pick` | `waitUntilCompleted` on the main thread for every mouse move | M5 | ~2 ms per move | low; renderer file |
| 7 | Full redraw of unchanged frames | 0.7 CPU + 2.1 GPU | 8% / 4% CPU; 25% of a 120 Hz frame on the GPU | 107 ms/s draw CPU in `studio-native`; 101 ms/s GPU in `studio-idle` at 49 frames/s | `ViewportNSView` display link → `Renderer.draw` | every display-link callback re-encodes and re-renders the frame, shadow map and deform pass included, even when nothing changed | G3 + P2 | ~3/4 of idle draw and GPU (hypothesis) | low |
| 8 | Studio `refresh()` per orbit event | 0.89 | 11% / 5% | 68 ms/s | `StudioModel.refresh` | a camera-only change rebuilds every item (C6) | M3 | 0.9 ms per event | medium |
| 9 | Source scene load at startup | 4,710 (once) | — | — | `AppState.importSourceScenePreview` | synchronous on the main thread; in the probe, 74% of the load is rig JSON decoding, repeated per character (C8) | S1, S2 | ~3 s of 4.7 s (hypothesis from the probe split) | low to medium |
| 10 | Engine compiled `-Onone` in Debug | 1,753 per tick | — | 0 presented frames | `Packages/Engine` build settings | an unoptimized generic-heavy Engine | B1 | Debug idle tick 1,753 → ~43 ms (measured with Engine -O) | see B1 |

The ranking is backed by this evidence (base Release traces):

- **Main thread in orbit and FK drag** (Time Profiler, 8.35 s and 8.11 s
  windows; that run's reports give 99.6 orbit events/s and 27.5 FK drag
  events/s). The main thread was busy 997 and 998 ms/s. `GraphHost.flushTransactions`
  accounted for 733 and 673 ms/s and `CA::Transaction::commit` for 321 and
  269 ms/s; the two overlap. `StudioModel.refresh()` took 87 and 148 ms/s, and
  `Renderer.draw` 26 and 21 ms/s. The Ikkoku view `body` getters together
  stayed under 30 ms/s; `StudioView.body` was the largest at 19 ms/s.
- **Hitches in orbit** (Animation Hitches). The trace had 27.9 hitches/s in
  the recording window: 195 of one frame, 32 of two and 7 of three. Of the 234,
  121 were labelled "Potentially expensive app update(s)"; the rest carried no
  label.
- **Main thread in Maker slider** (Time Profiler, 8.38 s window, 66.4 slider
  writes/s). The main thread was busy 998 ms/s. `GraphHost.flushTransactions` took 775 ms/s and
  `NSHostingView.layout` 591 ms/s. `MakerModel.refresh` took 51 ms/s and
  `Renderer.draw` 14 ms/s.
- **Main thread idle and hover.** `StudioModel.tick` took 632 ms/s, with its
  `refresh` at 342 ms/s. `Renderer.pick` took 27 ms/s in hover.
- **GPU** (Metal System Trace, approximate window, see [limits](#limits-of-these-numbers)).
  - Idle: the GPU was busy 101 ms/s for 49 frames/s, 2.06 ms per frame
    (fragment 1.06, compute 0.79, vertex 0.22).
  - Native: 172 ms/s for 119 frames/s, 1.45 ms per frame.
  - WindowServer's compositing added 16–50 ms/s of GPU time.
- **Allocations** (whole idle run including startup; the Allocations
  instrument slowed the tick to 103 ms). The run made 36.8 M heap allocations
  and churned 7.4 GB of transient heap.
  - The heaviest named types were `_ContiguousArrayStorage<Float>` (3.3 M
    allocations), `_ContiguousArrayStorage<Int>` (3.3 M) and
    `_DictionaryStorage<Int, [Float]>` (0.67 M, the animation channel tables
    that quick win 3 removes from the per-call path).
  - `_ContiguousArrayStorage<simd_float4x4>` accounted for 2.3 GB in 285 K
    matrix arrays.

### Scaling to the low end (base M1, 8 GB)

No run was made on an M1. These are estimates from the reference numbers
(**hypothesis**):

- **CPU.** One M1 performance core is roughly 0.8× an M2 Ultra performance
  core, so every main-thread cost above grows by ~1.25×. After the quick wins,
  that puts the 6-character tick at ~8 ms, which still fits the 33 ms timer
  period, and a SwiftUI edit at 10–15 ms.
- **The M1's other cores do not help today**, because everything ranked is
  serial on the main thread.
- **GPU.** A base M1 has 8 GPU cores against 76 and about 1/12 of the memory
  bandwidth. The idle frame takes 2.1 ms of GPU time at a 3.6 Mpx drawable. At
  a 13-inch M1's ~1.8 Mpx window, scaling with cores and pixels gives roughly
  10 ms per frame. So the GPU, not only the main thread, would cap the source
  scene below 120 Hz and near 60 Hz there. That makes G3 (skip unchanged
  frames), G5 (shadow re-render) and G7 (texture compression) worth more on
  the M1 than on the reference machine.
- **Memory.** A 0.94 GB peak footprint, with 470 MB of Metal allocations,
  fits in 8 GB. Still, with other apps open it is the item most likely to
  cause memory-pressure stalls (R1, G7).

### The live source-shader opt-in (#127)

The [live path](renderer.md#live-source-shader-path-r1cmt-04-opt-in-2026-10-22)
recorded one ON run of `koikatu_cs0002591` with a CPU encode time of 9.59 ms.
That figure is the Debug encode time, and the live path adds almost nothing
to it (**measured** on the merged-head builds, `.local/app-perf/live-on`).
`IKKOKU_BENCHMARK_OUTPUT` renders the scene offscreen at 1200×1600, with 60
measured frames, p50 per frame:

| Build | Opt-in | Visible items | CPU encode ms | GPU ms | Completion ms |
| --- | --- | ---: | ---: | ---: | ---: |
| Release | OFF | 130 | 0.63 | 1.228 | 2.22 |
| Release | ON (6 live draws) | 124 | 0.67 | 1.274 | 2.32 |
| Debug | OFF | 130 | 9.97 | 1.524 | 12.21 |
| Debug | ON (6 live draws) | 124 | 10.00 | 1.586 | 12.42 |

The opt-in adds about 0.04 ms of CPU and 0.05 ms of GPU time per frame in
both builds. The 9.4 ms gap between Debug and Release is the Engine compiled
`-Onone` (B1).

In the app, a 5 s Time Profiler run of `studio-idle` with the opt-in ON
(Release) splits the cost as follows:

- **`SourceShaderLiveAssembly.attach` runs in every Studio `refresh()`.** It
  takes 11.6 ms/s at 30 refreshes per second, about 0.39 ms each. The
  materials themselves are resolved once per character and cached. `attach`
  maps every frame item back to its source renderer again: it parses mesh
  names, filters the binding set's renderers for each item, splits shader
  names (`SourceShaderLiveMaterial.family(of:)`, 39% of it) and builds the
  report strings. That is the inventory item L1.
- **`Renderer.encodeLiveDraws`** takes 3.6 ms/s, about 0.06 ms per frame.

That run's window was not composited, so its frame rate is not used. The
trace is `.local/app-perf/live-on/release-tp/studio-idle.time-profiler.trace`.

## Quick wins in this change

All three are in Engine files. The renderer files and `StudioModel.swift`
were frozen while #127 was in review, so nothing here touches them. None
changes arithmetic: each skips work whose result is already known.

1. **The catalog bone lookup in `SourceStudioPose.init`.**
   - What it did before: for every catalog bone it walked the character's
     subtree, twice per bone, comparing node names byte by byte.
   - What it does now
     ([SourceStudioPose.swift](../../Packages/Engine/Sources/Studio/SourceStudioPose.swift)):
     it looks the name up in the rig's name index and keeps the first match
     inside the subtree, found by walking parents. It falls back to the
     original depth-first walk when several byte-equal names lie under one
     root, so the walk's "first in depth-first order" rule still decides.
2. **The solved pose is computed once per tick.**
   - What it did before: within one Studio tick, `editedPose` ran animation
     sampling, the saved hand patterns, FK/IK restore and the IK solve for the
     same elapsed time three times. The gaze sample, `setDynamicsStep` and
     `updateNeckLook` each drop `evaluatedCache`, so that each of them gets
     the tick's neck rotation and hair step.
   - What it does now
     ([SourceStudioCharacterPreview.swift](../../Packages/Engine/Sources/Studio/SourceStudioCharacterPreview.swift)):
     that stage is cached separately (`solvedCache`). The key is the
     animation state, whether the animation is required, the elapsed time,
     the FK and IK edits and the kinematic state. The cache is cleared
     wherever its inputs can change: shape values, dynamics reset and
     checkpoint restore, and animation playback reset. The neck override and
     dynamics still run every time, so they see the same pose as before.
3. **Animation clip bindings are resolved once per clip and rig.**
   - What it did before: `SourceAnimationLibrary.applying(clipID:…)` and
     `applying(stateID:…)` built a dictionary from source ID to node over
     ~1,000 strings on every call. They then routed every curve through
     nested `[Int: [Int: [Float]]]` tables.
   - What it does now
     ([SourceAnimation.swift](../../Packages/Engine/Sources/Character/SourceAnimation.swift)):
     a clip's bindings are resolved once into node indices and per-node
     channel offsets. The resolution is reused only while every binding
     still names the same node source ID and transform name in the rig
     passed in, and it is rebuilt otherwise.
   - When the original path still runs: any binding that does not resolve
     (missing, an unknown attribute or an out-of-range offset) sends the call
     to the original dictionary path. That path keeps every validation and
     error message.
   - What stays the same: the per-channel arithmetic, its order and the
     baseline checks.

How each fix was checked:

- **Probe.** A CPU-only Release replica of the Studio tick, built against the
  worktree's Engine. It loads the six source characters, runs 600 ticks and
  hashes every frame's model matrices, morph weights, skin palettes and
  bounds. Each fix was checked before and after with it (private, in the
  session scratchpad; logs under `.local/app-perf/probe`). The quick-win 3
  timings below are three interleaved 600-tick runs of each build at a load
  average of 9–13 (`ab-qw2-*.log`, `ab-qw3-*.log`). The 60-tick numbers come
  from single runs.
- **Captures.** IKKOKU_AUTOCAPTURE of the source scene, a source rig with the
  scenario card, a native scene, and a Studio scenario capturing after live
  frames, an orbit, an FK edit and more live frames. Each was taken with the
  base and the quick-win builds, in Debug and Release.
- **Lanes and the Engine suite**, listed under
  [validation](#validation-of-this-change).

| Step | Probe ms/tick (6 characters) | Probe frame digest (600 ticks) | Captures against the base build |
| --- | ---: | --- | --- |
| baseline (`9e02a62`) | 40.0 (60 ticks) | — | — |
| + quick win 1 | 13.3 (60 ticks) | checked together with quick win 2 | — |
| + quick win 2 (`5b01c92`; `3cd44b7` with `main` merged) | 8.4 (60 ticks); 8.63, 8.70, 8.73 (600 ticks) | `dc789a7f…` | identical: source scene `d5575bfb…`, rig + card `045884f0…`, native scene `d1ade80a…`, scenario renders `1fcd2488…`/`c1ad5327…`/`4b23ea6e…` (Debug and Release, `.local/app-perf/captures-1`) |
| + quick win 3 (`decf961`) | 5.66, 5.69, 5.72 (600 ticks) | `dc789a7f…` (unchanged) | identical, now against `main` `5e86b57`: the merged head `0d4548a` gives the same hashes as above (Debug and Release, `.local/app-perf/captures-3`) |

The `main` builds for the last row have no harness, since they predate it.
Three more cases match between `main` `5e86b57` and the merged head in Debug:
the source scene with only the avatar (`d5be9858…`), the rig with the R1
fixture card (`9d973e21…`) and the synthetic scene (`4b0fe94e…`).
Every capture compared is also identical between the Debug and Release
builds.

In-app harness results, Release, before → after:

| Workload | Presented FPS | Hitches/s | Tick ms × rate/s | Refresh ms | Main busy ms/s |
| --- | --- | --- | --- | --- | --- |
| studio-idle | 44.7 → 117.4 → 120.0 | 14.9 → 2.5 → 0.0 | 43.38 × 15 → 8.94 × 30 → 6.34 × 30 | 23.25 → 3.87 → 4.06 | 680 → 356 → 286 |
| studio-hover | 44.9 → 87.5 → 93.3 | 15.0 → 29.9 → 26.6 | 41.77 × 15 → 9.15 × 30 → 6.45 × 30 | 22.69 → 4.07 → 4.16 | 758 → 657 → 518 |
| studio-fk-drag | 24.6 → 25.1 → 23.1 | 24.1 → 24.9 → 22.9 | – | 4.12 → 1.64 → 1.19 | 991 → 999 → 992 |
| studio-orbit | 40.0 → 37.6 → 32.2 | 32.2 → 28.2 → 24.8 | – | 0.89 → 0.91 → 0.92 | 996 → 998 → 997 |
| maker-idle | 118.4 → 118.1 → 118.2 | 1.6 → 1.9 → 0.4 | 2.02 × 30 → 2.32 × 30 → 1.20 × 29 | 0.36 → 0.37 → 0.30 | 136 → 184 → 124 |
| maker-slider | 53.1 → 47.3 → 54.0 | 34.7 → 32.7 → 37.4 | 0.73 × 30 → 0.71 × 30 → 0.49 × 30 | 0.71 → 0.68 → 0.53 | 997 → 998 → 997 |
| studio-native | 118.6 → 118.0 → 119.6 | 1.4 → 2.0 → 0.4 | 1.81 × 30 → 1.82 × 30 → 1.56 × 30 | 1.77 → 1.75 → 1.51 | 172 → 191 → 147 |
| startup (scene import duration / firstDraw, s) | 4.71 / 6.29 → 4.55 / 6.07 → 4.66 / 6.27 | | | | |

The columns read baseline → quick wins 1–2 (`.local/app-perf/after-1`) →
quick wins 1–3 (`.local/app-perf/after-2`). Five quick-win-3 runs were
repeated because the first attempt overlapped a build or its window was not
composited; the rejected reports are kept in `after-2/qw3-release/invalid`.

- **Idle tick.** The Studio idle tick fits the 30 Hz timer again, so live
  animation plays at its real speed, and the idle scene presents every
  120 Hz frame.
- **Quick win 3 also helps Maker and native scenes**, because they sample the
  same animation clips: the Maker idle tick went from 2.02 to 1.20 ms, the
  Maker slider tick from 0.73 to 0.49 ms and the native 6-character tick
  from 1.81 to 1.56 ms.
- **Hover hitches did not improve.** They rose from 15 to 27–30 per second.
  With the tick at 30/s instead of 15/s, the hover's synchronous pick and the
  tick share the main thread twice as often (M5).
- **FK drag and orbit do not change**, because they are bound by SwiftUI
  (ranks 2 and 4). The FK refresh itself fell from 4.12 to 1.19 ms. Their
  frame rates move between 32 and 41 FPS from run to run because the main
  thread is saturated (see the baseline notes).
- **Startup does not change.** The scene import stays at about 4.6 s.
- **Debug.** The Debug idle tick went from 1,753 ms to 662 ms with quick wins
  1–2 and 667 ms with 1–3. The source scene import went from 11.71 s to
  10.15 s and 10.36 s. Debug remains unusable for source scenes without B1.
- **The merged head.** The PR head merges `main` at `5e86b57` and later
  (`.local/app-perf/after-3`, Release on `0d4548a`). Its valid runs match quick
  wins 1–3 within run-to-run variation: hover tick 6.39 ms × 30, orbit 41.2 FPS,
  Maker slider 48.1 FPS, native 119.7 FPS, firstDraw 6.19 s. TBD-MERGED-RERUNS

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
| M2 | Every document change re-evaluates all of `StudioView` | `StudioView.body` reads `model.doc` (workspace list, toolbar, inspector) | measured | orbit: `GraphHost.flushTransactions` 733 ms/s, inside it `ViewBodyAccessor.updateBody` 194 ms/s and `NSHostingView.layout` 148 ms/s, against 19 ms/s in `StudioView.body` itself ([rank 4](#ranked-costs)) | split `StudioView` into child views that each read only what they show (workspace list, toolbar, timeline, inspector), with per-event state (camera, an FK drag in progress) outside what they read; most of the 7–25 ms per event (hypothesis until measured) | Low–medium: UI captures (`IKKOKU_CAPTURE_UI` lanes) must stay identical |
| M3 | Camera orbit, pan and dolly mutate `doc.camera`; the `doc` didSet then runs a full `refresh()` and invalidates every view that reads `doc` | `StudioModel` (`doc` didSet, `mouseDragged` `.orbit`) | measured | orbit: `refresh()` 0.89 ms × 76/s plus the SwiftUI cost of M2 per event | keep the view camera outside the observed document (or in its own observed property) and send camera-only changes straight to the renderer's frame uniforms without rebuilding items | Medium: the camera is saved with the document and undo must keep working |
| M4 | Maker slider writes invalidate the whole source rig panel | `SourceRigPanel.body` reads `sourceBodyValues`/`sourceFaceValues` for every slider | measured | `maker-slider`: `NSHostingView.layout` 591 ms/s, `Slider.body` 53 ms/s, material effect updates 111 ms/s at 66 writes/s ([rank 3](#ranked-costs)) | one row view per slider taking its value and a setter, the slider list in a child view, and per-slot observation so only the dragged row re-evaluates; ~10 ms per write (hypothesis) | Low |
| M5 | Hover pick is a synchronous GPU round trip per `mouseMoved` | `StudioModel.mouseMoved` → `Renderer.pick` (`waitUntilCompleted`) | measured | 2.02 ms p50 per event at 46 events/s with a selection | pick asynchronously (completion handler, apply the hover on the next frame) and only for the latest mouse position; a 1×1 scissor on the pick pass cuts its GPU work | Low; renderer file |
| M6 | The Studio timer is a default-mode `Timer`; ticks skip while the timer handler is late and it does not fire during AppKit event tracking | `StudioModel.init` | hypothesis | the 15 Hz tick rate above is the late-handler case | drive the live step from the display link's target time with a fixed 1/30 s accumulator so animation speed never depends on main-thread load | Medium: the scenario lanes rely on fixed 1/30 s steps, which an accumulator keeps |
| M7 | Status-line churn | `StudioModel.tick` → `RenderStatusReporter.status` | measured (negative) | assigns only when the text changes | none needed | — |
| M8 | Native characters step hair dynamics once per `refresh()`, not per tick, so an orbit (one refresh per mouse event) runs their hair simulation faster than real time | `StudioModel.refresh` (`inst.stepHairDynamics(dt: 1/30)`) | measured (code path) | `studio-native` refreshes at 30/s idle; any extra refresh adds a 1/30 s step | step native hair only from the live tick | Behavior change; a correctness fix more than a performance one |

### Per-frame CPU work (Engine)

Numbers are from the Release probe after quick wins 1 and 2: 6 characters,
600 ticks, Time Profiler, ms per tick for all characters together (total
8.96 ms). With quick win 3 the probe's remaining tick splits as dynamics
(`applyLookAndDynamics`) 51%, the solved pose 32% (`makePose` 22%, animation
sampling 5%) and `SourceRigPreview.frame` 11% (`probe6`, Time Profiler on a
loaded machine, so only the shares are used).

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | Animation sampling rebuilds a source-ID→node dictionary (~1,000 strings) per clip call and per state call and fills nested `[Int: [Int: [Float]]]` channel dictionaries | `SourceAnimationLibrary.applying(stateID:…)`, `applying(clipID:…)` | measured; **done** (quick win 3) | 3.2 ms/tick, of which ~2.8 ms is dictionary building, lookups, string hashing and their allocations; curve sampling itself is 0.1 ms | resolve each clip's bindings to node indices once per (clip, rig) and reuse a flat channel table: probe 8.63–8.73 → 5.66–5.72 ms/tick | Low: same arithmetic; a resolution is reused only while every binding still names the same node |
| C2 | Hair dynamics rebuilds a full-rig transform state (all nodes, children lists, world matrices) per DynamicBone component per step and validates its output with a full `rig.evaluate` | `SourceDynamicBone.advance`, `DynamicsTransforms` | measured | 3.25 ms/tick: `DynamicsTransforms.init` 1.84, `pose(rig:)` 0.66 (`rig.evaluate` 0.48, `restPose` 0.13), teardown 0.32 | cache the topology per rig, transform only the required chains, validate only the changed nodes; ~2.5 ms/tick | Medium: must keep the float results bit-identical (same operation order) |
| C3 | `SourceStudioPose` is rebuilt for every pose evaluation | `KoikatsuCharacterRecord.makePose` | measured | 1.4 ms/tick (init 0.58, apply 0.51, late update 0.23) | cache the bound pose per (rig, record, kinematics) | Low |
| C4 | Eye look evaluates the whole rig to read four nodes | `SourceStudioCharacterPreview.updateEyeLook` | measured | ~0.1 ms/tick | evaluate the ancestor chains only | Low |
| C5 | Source expression weights are recomputed and revalidated per frame | `SourceRigPreview.expressionWeights` | measured | 0.45 ms/tick | cache per expression input | Low |
| C6 | `refresh()` rebuilds every character's `RenderFrame` (items, skin sets, bounds) for camera-only changes | `StudioModel.refresh` | measured | 0.89 ms per orbit event | see M3 | Medium |
| C7 | Maker's live step evaluates the rig only to validate the pose, then the refresh evaluates it again | `MakerModel.advanceSourceMotion` | hypothesis | `makerTick` 2.0 ms p50 in `maker-idle` | reuse the validated evaluation in the refresh | Low |
| C8 | Studio scene/character load decodes the same rig JSON once per character and component | `SourceMakerLibrary.prepare` → `SourceRig.load` | measured | probe load 6.1 s for 6 characters, 74% in `SourceRig.decode` (JSONDecoder) | cache decoded rigs by path, size and modification time; or a binary rig format | Low for the cache |
| L1 | With the live source-shader opt-in ON, every `refresh()` maps each frame item back to its source renderer again (mesh-name parsing, a filter over all binding-set renderers per item, shader-name splits, report strings); the materials themselves are cached | `StudioModel+SourceShaderLive.swift` → `SourceShaderLiveAssembly.attach` | measured | 0.39 ms per refresh (11.6 ms/s at 30 Hz), 39% in `SourceShaderLiveMaterial.family(of:)` ([live opt-in](#the-live-source-shader-opt-in-127)) | cache the item-to-slot mapping per character while its meshes, visibility and wear are unchanged, and index the renderers by (mesh, submesh); most of the 0.39 ms (hypothesis until measured) | Low; the opt-in is OFF by default and its report must stay the same |

### Metal

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| G1 | GPU time is not the bottleneck on the reference machine | whole frame graph | measured | 1.3–1.9 ms GPU per frame at 1996×1824, 6 characters; draw encoding 0.6–0.9 ms CPU | — | — |
| G2 | MSAA color/depth, overlay depth and pick depth are already memoryless | `RenderTargets` | measured (code) | `storageMode = .memoryless` | — | — |
| G3 | Unchanged frames are fully re-rendered at the display rate, including the deform compute pass and the 2048² shadow map | `Renderer.draw`, `ViewportNSView` | measured | 120 draws/s while Studio content changes 30 times/s and the camera is still | skip prepare/encode/present when the frame and drawable size did not change (frame version counter); or lower `preferredFrameRateRange` when idle. ~3/4 of GPU and draw CPU at idle | Low |
| G4 | Skin matrices are copied into a new `MTLBuffer` per skin set per frame and validated element by element | `Renderer.buildContext` | hypothesis | allocation per draw; not separated in the profile | write skin matrices into the frame ring | Low; renderer file |
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
| B1 | Debug builds compile the Engine package `-Onone`; the Studio scene is unusable in a Debug app | `Packages/Engine/Package.swift` | measured | Debug tick 1.75 s (0 presented frames in 10 s) versus 42.9 ms with the Engine at `-O` inside the same Debug app | an opt-in optimized-Engine Debug configuration for app work (Engine stays debuggable by default); every capture in this change was byte-identical between Debug and Release | Medium: `-O` drops the Engine's `assert` checks in that build (preconditions stay), lldb loses optimized-out locals, and `.unsafeFlags` is only acceptable while the Engine stays a local package; `swift test` and the default Debug build must keep the checked Engine |

### Memory

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| R1 | Peak footprint ~0.94 GB with 6 source characters (Metal 470 MB) | whole app | measured | `studio-idle` Release | texture compression (G7); release staging data after upload; matters on 8 GB machines | Medium |

## Phase 2 plan

The plan is ordered by expected effect on what a user feels, then by risk.
Each step keeps the rules of this change: rendered output stays
byte-identical, the harness numbers are recorded before and after, and the
lanes and the Engine suite pass. Items 1–5 and 9 touch `StudioModel.swift`
or renderer files. Those were frozen while #127 was in review; #127 merged
(`main` `5e86b57`), so phase 2 can start after the phase-1 review.

How to read the expected gain column:

- "Expected on the reference machine" assumes the item works as described.
- "M1" is the [scaling estimate](#scaling-to-the-low-end-base-m1-8-gb).
- All gains are hypotheses until measured.

| # | Work | Inventory items | Expected on the reference machine | M1 | Verification beyond the standard set |
| ---: | --- | --- | --- | --- | --- |
| 1 | Narrow SwiftUI invalidation. Move the camera out of the observed `doc`, or into its own observed value. Split `StudioView` into child views that read only their own state. Make the Maker slider rows value-driven views with per-slot observation | M2, M3, M4, C6 | orbit, FK drag and slider edits go from 7–25 ms per event to a few ms; the main thread is no longer saturated during interaction; presented FPS for those workloads rises from 24–53 toward 120 | the same edits drop from ~10–30 ms to a few ms; the difference between usable and laggy | `IKKOKU_CAPTURE_UI` window captures identical; undo/redo scenarios (`undo-camera`) pass |
| 2 | Run the display link on its own thread. `Renderer` already snapshots the frame under `frameLock`; pick, statistics and error reporting need the same treatment | P1 | main-thread work no longer delays presentation; hitches/s fall to the GPU's own rate | larger: more of the main-thread cost is hidden | presented-interval p95 at 8.3 ms with a busy main thread (harness) |
| 3 | Take the live tick off the main thread and evaluate the characters in parallel. Cache the dynamics topology per rig (C2) and the bound Studio pose (C3). Hair dynamics is now the largest part of the tick: `SourceDynamicBone.step` took 48% of `advanceLiveFrame` in the in-app Time Profiler run of the live opt-in (122 of 255 ms/s) | M1, C2, C3, C5 | the 6-character tick goes from ~6 ms on the main thread to < 2 ms wall-clock; more characters scale with cores | M1 has 4 performance cores, so ~4× on the tick | probe digest identical; scenario renders identical; deterministic join order |
| 4 | Skip unchanged frames and run the display link at 30–60 Hz when nothing moves; leave the shadow map alone until casters or the light move | G3, G5, P2 | ~3/4 of idle draw CPU and GPU | the biggest GPU item on M1: idle GPU at ~10 ms/frame becomes ~2.5 ms of every 8.3 ms | captures identical (nothing renders differently, frames are only skipped) |
| 5 | Asynchronous hover pick for the latest mouse position only | M5 | 2 ms per mouse move off the main thread; fixes the hover hitch rise | same | gizmo hover scenarios |
| 6 | Startup: cache decoded rigs and load source characters concurrently off the main thread, with a progress state | C8, S1, S2, S4 | source scene ready in ~1.5 s instead of 4.7 s; first frame earlier | larger, since there is less memory bandwidth for repeated decoding | `startup` workload; scene import results identical |
| 7 | An opt-in optimized-Engine Debug build for app work | B1 | a Debug app at Release speed for Engine code | same | captures identical Debug and Release (already true) |
| 8 | Texture compression at conversion time; release staging data after upload | G7, R1 | smaller footprint and bandwidth | main memory-pressure relief on 8 GB | image comparison; this is a quality trade-off, so it stays opt-in until compared |
| 9 | Instrument `StudioModel` directly: explicit tick, refresh and doc-change hooks in place of the inferred ones | harness | exact Studio attribution (the inferred hooks cannot separate a SwiftUI pass caused by a doc change from one caused by layout) | — | `test_perf_trace.py`, harness report schema |
| 10 | With the live source-shader opt-in ON, cache the item-to-slot mapping between refreshes | L1 | ~0.3 ms of each 0.39 ms refresh attach, only with the opt-in ON | same share | the live report and ON captures identical |

## Validation of this change

The suites and lanes ran on the merged head `b20ccd7` (`main` at `f5587f5`
merged) unless stated. The reports are under `.local/verification/app-perf`
in the worktree and `.local/app-perf/lanes`.

- **Engine suite.** Plain `swift test --package-path Packages/Engine`: 690
  tests passed, plus 21 in the second test target. With every private
  fixture exported (`IKKOKU_*` from the fixture map), all 690 passed, one of
  them skipped for the optional `IKKOKU_APPEARANCE_REFERENCE_ROOT`. The
  private hair-dynamics oracle test failed on `0a19718` and on `origin/main`
  `d9684e8`. It passes now that the fixture map points at a new
  `IKKOKU_SOURCE_DYNAMICS_REFERENCE`.
- **Lane `public`** (default mode):
  - Passed: runner self-tests (178, including the 9 in
    `test_perf_trace.py`), Engine unit tests, mod tools and the inspector
    validator tests.
  - One translation test errors in a worktree checkout ("Recovered original
    source and translations must remain under ignored .local"). It errors
    the same way on `origin/main`.
  - Under `--strict` the lane also fails `engine-unit-tests`, because strict
    mode sets `IKKOKU_REQUIRE_SOURCE_FIXTURES=1`. The public lane supplies no
    fixtures, so its fixture-gated tests fail by design (69 issues).
- **Lane `maker`.**
  - Default mode: 6 passed and 2 skipped, both for missing optional fixtures
    (`IKKOKU_APPEARANCE_REFERENCE_ROOT`, `IKKOKU_MANAGED_RECOVERY_EXPORT`).
  - One failure: `maker-roundtrip-audit` refuses its output path ("Evidence
    output must remain under ignored .local"), because a worktree's
    `.local/reverse` is a symlink outside the worktree's `.local`. It fails
    the same way on `origin/main`.
  - Under `--strict` the two skips become failures.
- **Lane `private-source`.**
  - Default mode: its suite passed (690 tests, 2 skipped).
  - Under `--strict` it stops before running, on the optional
    `IKKOKU_APPEARANCE_REFERENCE_ROOT` that the fixture map does not supply.
- **App lanes**, each `--strict` under the app lock: TBD-APP-LANES.

## Limits of these numbers

- **The machine was shared.** Other agents ran builds, tests and app lanes
  during the work. Every report records the load average: 4–10 during the
  harness runs. The probe re-measurements were interleaved at the load given
  next to them. All app launches were serialized by the app lock, so the
  window being measured was the only Ikkoku window. Even so, a busy machine
  slows the CPU-heavy workloads.
- **One valid run per workload and build.** Runs were repeated only when
  they were invalid. The saturated workloads (orbit, FK drag, slider) vary
  by tens of percent between runs (see [baseline](#baseline)). The idle,
  hover, native and Maker idle numbers repeated within a few percent between
  the baseline, Engine -O and the traced runs.
- **The desktop was in use.** A harness window is only measured while it is
  composited. Several runs lost most of their drawables while someone used
  the desktop, and some idle runs received mouse events. The validity check
  under [running it](#running-it) was added for this, and every flagged run
  was repeated or left out. Two Instruments-attached runs also trip it
  (Metal System Trace and Allocations on `studio-idle`, 14% and 13% of
  drawables never shown); they are cited only for GPU timings and
  allocation counts, not frame rates.
- **The display changed during the last runs.** At 13:04 on 2026-10-23 the
  main display changed from the 4K panel at 120 Hz and scale 2 to
  1920×1080 at 60 Hz and scale 1. The merged-head idle, FK drag and Maker
  idle reruns and the live-ON harness runs fell after that change and were
  not used for frame rates. The offscreen benchmarks and the Time Profiler
  attribution do not depend on the display.
- **Attached recording starts late.** xctrace attaches 1.35–1.36 s after the
  app starts (measured from the shared startup marks in the Time Profiler
  traces), so no trace covers early startup. The `startup` workload's own
  marks do.
- **Some traces have no app marks.** The Metal System Trace and Animation
  Hitches templates do not record the app's Points of Interest. Their
  windows above were placed with the report's marks minus a fixed 1.355 s
  offset, so they are approximate to a frame or two.
- **The SwiftUI template recorded no update rows** in attach mode. The
  SwiftUI attribution above comes from Time Profiler call stacks, which
  name framework phases (graph update, layout, body accessors) but not the
  view types inside SwiftUI.
- **Allocations slows the app about 2.4×** (idle tick 103 ms against 43 ms),
  and its statistics cover the whole run. Allocation counts are therefore
  given for the whole run, not per tick.
- **The Studio tick and refresh are inferred** from observed `StudioModel`
  properties, because `StudioModel.swift` was frozen for most of this work.
  Explicit hooks are phase 2, item 9.
- **No M1 run.** The low-end column is an estimate from core counts,
  bandwidth and drawable size.
- **The drawable is not a full 4K frame.** It is 1996×1824 pixels, the
  window's viewport on a 4K display at scale 2. A full-screen viewport on
  that display has about 2.2× the pixels, which matters for GPU time only.
