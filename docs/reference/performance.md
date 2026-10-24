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
   scene to 120.0 FPS with no hitches. Phase 2, item 3 then took the step
   off the main thread: the characters run in parallel on workers, and the
   main thread keeps about 0.6 ms of snapshot and refresh per step
   ([phase 2, item 3](#phase-2-item-3-live-tick-off-the-main-thread)).
2. **SwiftUI work on every interactive edit.** Each orbit event, Maker
   slider write or FK drag event costs 7–25 ms of SwiftUI graph update and
   layout, because the Studio and Maker views observe whole documents and
   arrays. The main thread then stays about 1000 ms/s busy. This is the main
   lag left after the quick wins. Its fix restructures `StudioModel.swift`
   and the views, so it is phase 2. Phase 2, item 1 has since done this, so
   those edits present at 119–120 FPS ([phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation)).
3. **The display link shares the main run loop**, so any cost above turns
   into a presentation hitch. Phase 2, item 2 moved it to its own render
   thread. With the main thread loaded on purpose, the Studio now presents
   120 FPS with a p95 interval of 8.33 ms, against 30–60 FPS and 25–33 ms
   before ([phase 2, item 2](#phase-2-item-2-render-thread-and-frame-ring-skin-palettes)).
4. **The hover pick waited for the GPU on the main thread**, 2.3 ms for every
   mouse move. Phase 2, item 5 made it asynchronous, for the latest position
   only: hover's main-thread time fell from 518–531 to 239–242 ms/s, with
   identical pick ids ([phase 2, item 5](#phase-2-item-5-asynchronous-hover-pick)).

These headline numbers are the original phase-1 measurements. The
[resumed review](#resumed-phase-1-review-2026-10-23) retained near-120 FPS idle
on the current merged code but found substantial orbit pacing variation; it
does not establish an interactive speedup.

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
through the slider row binding's slot setter (`MakerModel[shapeSlot:]`), Studio
selection, pose mode and scene commands through `StudioModel`. Nothing is re-implemented, so the draw,
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
| `viewport-lifecycle` | avatar, Maker library | `studio-native`'s scene, then every 0.5 s: three Studio/Maker switches (each replaces the viewport), a window resize to 0.7× and back, minimize for 1.5 s, restore, Studio, Maker. Before each step it counts the threads named `com.grabbiel.Ikkoku.viewport-render`. After the report it quits through `NSApp.terminate` while the link draws, instead of `exit` |
| `startup` | as `studio-idle` | no workload; the report's `startupSeconds` marks are the result |

Other options:

- `IKKOKU_PERF_WINDOW_W`/`_H` (default 1600×1000 points). The size is applied
  with the window's autosave name cleared, so the user's saved frame is
  untouched.
- `IKKOKU_PERF_INPUT_HZ` (default 120).
- `IKKOKU_PERF_MAIN_LOAD_MS` (0–1000, default 0) and `IKKOKU_PERF_MAIN_LOAD_HZ`
  (1–240, default 30). While recording, a main-run-loop timer busy-waits that
  many milliseconds that many times a second. It stands in for main-thread
  work the app does not control (a slow SwiftUI update, a modal panel), so
  the report shows whether presentation depends on the main thread. The time
  is reported as the `mainLoad` phase and `mainThread.loadMsPerSecond`.
  `perf_trace.py run --main-load-ms N [--main-load-hz H]` sets both and names
  the report `<workload>+loadN.json`.

### What the report records

[PerfTrace.swift](../../Apps/IkkokuCreator/PerfTrace.swift). The draw
samples are recorded on the thread that runs the display link, through a
locked `PerfDrawLog`. Everything else is recorded on the main thread.

- every `CAMetalDisplayLink` callback: callback time, target presentation time,
  `Renderer.draw` duration (frame preparation, deformation and pass encoding,
  plus any wait for one of the three frame slots), the last completed
  command buffer's GPU time (`gpuEndTime - gpuStartTime`), and whether it ran
  on the main thread. `drawThread` is `main`, `render` or `mixed`. Only
  main-thread callbacks count as main-thread draw time; render-thread draws
  are summed in `renderThread` (callbacks, draw ms/s);
- the frame ring's counters after each draw (`frameRing`): skin palettes and
  palette KiB per draw, palette buffers created while recording (0 once the
  ring is warm), and draws that used overflow buffers;
- when each drawable was really presented (`addPresentedHandler`), giving
  presented FPS, presented-interval percentiles and hitches (an interval longer
  than 1.5 refresh periods; `skippedRefreshes` counts the periods it lost);
- main run-loop busy time (after-waiting to before-waiting observers), split
  into draw, model (ticks, refreshes and input handlers, nested intervals
  counted once) and other (SwiftUI updates, layout, AppKit event handling);
- Maker ticks and refreshes (explicit hooks in `MakerModel`), Studio live
  ticks (`studioTick`, the timer's step outside a drag), `refresh()` calls
  (`studioRefresh`) and camera-drag frame reuses (`studioCameraRefresh`, see
  [phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation)), all explicit
  hooks in `StudioModel.swift` (phase 2, item 9), and every viewport input call;
- model events without a duration (`events`): `studioDocChange` counts writes
  to the Studio document, each of which notifies every view that reads it, and
  `studioCameraChange` counts writes through the camera accessor, which only
  the camera's readers observe. `hoverPickStarted` counts hover picks started
  (a move with no pick in flight, or a stale result picked again), and
  `hoverPickCoalesced` counts moves that waited for the pick in flight;
- the asynchronous hover picks (`hoverPick`, [phase 2, item 5](#phase-2-item-5-asynchronous-hover-pick)):
  picks finished on the main actor, how many applied and how many were stale,
  their latency from start to the main actor and their command buffers' GPU
  time. Applying them is the `studioHoverPick` model phase, including the
  refresh when the highlight changes;
- SwiftUI body evaluations (`viewBodies`, count and rate per second) for the
  app's commands, the content view, the Studio window and each of its panels
  and inspectors, and the Maker window, source rig panel and shape slider rows.
  A count is one evaluation of that body, so dividing its rate by the input
  rate says what one edit re-evaluated. `perf_trace.py summarize` prints them
  per input event in a second table. SwiftUI's own graph update and layout are
  not split by view; Time Profiler attributes those;
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
of the `com.grabbiel.IkkokuCreator` subsystem (`Draw`, `Input`, `StudioTick`,
`StudioRefresh`, `StudioCameraRefresh`, `StudioHoverPick`, `MakerTick`,
`MakerRefresh`, `Startup`, and `Mark` events), so every Instruments template
shows them next to its own tracks. The report's `schemaVersion` is 2 since the
Studio hooks, events and view bodies were added, 3 since the draw log moved
off the main actor (`drawThread`, `renderThread`, `frameRing`, the `mainLoad`
phase and `configuration.mainLoadMs`/`mainLoadHz`), and 4 since the hover
pick became asynchronous (`hoverPick`, the `studioHoverPick` phase and the two
hover events). `perf_trace.py summarize` prints a hover line for a report with
hover picks.

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
  `studio-native`, `viewport-lifecycle`, `startup`) sends no input. Any input
  calls in its report came from someone's mouse over the window, so the run
  is checked against a rerun.
- **Viewport lifecycle.** `viewport-lifecycle` is exempt from the drawable
  check, since it minimizes the window on purpose. Instead `summarize` warns
  when any of these holds:
  - the steps did not run;
  - more render threads run at the end than before the first step, or more
    than one (or than at the start, if more) before any step;
  - no frame was presented more than 0.5 s after the restore;
  - the window is still minimized.

  It prints the per-step render-thread counts. For reports with frame-ring
  counters, it also prints one line of per-draw skin palettes and palette
  buffers created.

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
| 1 | Studio live tick, 6 source characters | 43.4 | 521% / 260% | 651 ms/s at 15 ticks/s (target 30) | `StudioModel.tick` → `SourceStudioCharacterPreview.frame`/`editedPose` | repeated work per tick (quick wins 1–3) and all character work serial on the main thread (M1) | quick wins 1–3 (this change), then C2, C3, M1; **done** in [phase 2, item 3](#phase-2-item-3-live-tick-off-the-main-thread) | 43.4 → 6.34 ms measured in the app; 30 ticks/s restored. Since item 3, 7 characters: 8.0 ms on the main thread → 0.6 ms, the characters on workers in 0.93–0.97 ms wall (2.75–5.8 ms CPU) | low for 1–3 (byte-identical); high for M1 |
| 2 | SwiftUI update and layout per FK drag event | 24.5 | 294% / 147% | 673 ms/s at 27.5 drag events/s | `GraphHost.flushTransactions` for `StudioView`; `StudioModel.doc` didSet | an FK edit mutates `doc`; `StudioView.body` and its inspector read `model.doc`, so the whole window's view graph is re-evaluated and laid out again; each drag event also triggers two `refresh()` calls (55/s) | M2 + M3: per-panel observation, FK and camera state outside the observed document; **done** in [phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation) | measured: `GraphHost.flushTransactions` 23.8 → 0.91 ms per drag event, one `refresh()` per event instead of two, 26.7 → 119.9 presented FPS | medium |
| 3 | SwiftUI update and layout per Maker slider write | 11.7 | 140% / 70% | 775 ms/s at 66 writes/s | `SourceRigPanel.body`; `NSHostingView.layout` 591 ms/s | each write replaces `sourceBodyValues`. The whole panel and every slider row (52 face sliders plus the bound body sliders) are rebuilt and re-laid out: `Slider.body` 53 ms/s, binding location compares 52 ms/s, material effect updates 111 ms/s | M4: slider rows as separate views over value inputs, the slider list outside the panel's other state; **done** in [phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation) | measured: 1 slider row evaluated per write instead of 44; `GraphHost.flushTransactions` 11.8 → 2.5 ms and `NSHostingView.layout` 8.3 → 3.9 ms per write; 43.4 → 119.8 presented FPS. The rest is layout of the long panel | low |
| 4 | SwiftUI update and layout per orbit event | 7.4 | 89% / 44% | 733 ms/s at 100 events/s | same as rank 2 | `orbit` writes `doc.camera`; the view graph work is as in rank 2. Of 997 ms/s busy, Ikkoku's own `body` code is ~25 ms/s; the rest is framework diffing (`ViewBodyAccessor.updateBody` 194 ms/s), `NSHostingView.layout` (148 ms/s) and AppKit control layout (`NSSegmentedCell` 87 ms/s, the toolbar and inspector segmented pickers) | M3 (camera outside `doc`), then M2; **done** in [phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation) | measured: no view body and no sampled SwiftUI pass per orbit event (8.9 ms before); 41.0 → 119.4 presented FPS | medium |
| 5 | Studio `refresh()` in an FK drag | 4.12 per refresh, 2 per drag event | 99% / 49% per event | 235 ms/s | `StudioModel.refresh` → character frames | each frame rebuild re-runs the pose pipeline (C1–C3) | quick wins 1–3; C2, C3, C5 in [phase 2, item 3](#phase-2-item-3-live-tick-off-the-main-thread) | 4.12 → 1.64 ms per refresh (quick wins 1 and 2, measured); 1.83–1.97 → 1.27–1.29 ms with C2, C3 and C5 | low |
| 6 | Hover pick, synchronous GPU round trip | 2.02 | 24% / 12% | 93 ms/s at 46 events/s | `StudioModel.mouseMoved` → `Renderer.pick` | `waitUntilCompleted` on the main thread for every mouse move. Since [phase 2, item 2](#phase-2-item-2-render-thread-and-frame-ring-skin-palettes) it no longer delays presentation; at 120 moves/s it takes 2.6 ms each (316 ms/s), the largest main-thread cost in hover after the tick | M5; **done** in [phase 2, item 5](#phase-2-item-5-asynchronous-hover-pick) | measured: 2.29–2.41 → 0.01 ms per move on the main thread; the pick (0.47 ms CPU, 0.94 ms GPU) runs on the renderer's pick queue | low; renderer file |
| 7 | Full redraw of unchanged frames | 0.7 CPU + 2.1 GPU | 8% / 4% CPU; 25% of a 120 Hz frame on the GPU | 107 ms/s draw CPU in `studio-native`; 101 ms/s GPU in `studio-idle` at 49 frames/s | `ViewportNSView` display link → `Renderer.draw` | every display-link callback re-encodes and re-renders the frame, shadow map and deform pass included, even when nothing changed. Since [phase 2, item 2](#phase-2-item-2-render-thread-and-frame-ring-skin-palettes) the draw runs on the render thread, so this costs no main-thread time, and G4 cut its CPU encode from 0.74 to 0.44 ms per frame (offscreen) | G3 + P2 | ~3/4 of idle draw and GPU (hypothesis); now render-thread CPU and GPU only | low |
| 8 | Studio `refresh()` per orbit event | 0.89 | 11% / 5% | 68 ms/s | `StudioModel.refresh` | a camera-only change rebuilds every item (C6) | M3; **done** for orbit and pan drags in [phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation) | measured: 1.00 ms full refresh → 0.04 ms camera rebuild per drag event | medium |
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
- **GPU** (Metal System Trace, approximate window, see [limits](#limits-of-the-historical-profiling-campaign)).
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
     checkpoint restore, and animation playback reset. Both pose caches include
     the required-animation flag, so an optional saved-animation fallback
     cannot conceal an error from a later explicit animation request. The neck override and
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

Control note (2026-10-24): with a Maker library present, the synthetic
scene's capture (`IKKOKU_SOURCE_SCENE` set to
`.local/reverse/studio-scenes/synthetic-current.png`, with
`IKKOKU_AUTOCAPTURE`) now exits 1. A Maker library is present when
`IKKOKU_MAKER_LIBRARY` names one, a converted library is selected, or the
source-tree fallback finds `.local/reverse/maker-library`. The scene's only
character (`Character 10`) has no hair `parts` array that
`SourceMakerLibrary` supports ("Unsupported hair part array."), so the
character is always retained without rendering. Since #133, an automated
scene capture whose characters all fail exits 1. For a native-scene byte
control, run it with `IKKOKU_MAKER_LIBRARY=none`, so that the character
renders through the bundled native body. On 2026-10-24, `main` `0c51ca1` and
the phase 2, item 2 head both gave `6837cd63…` that way.

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
  Maker slider 48.1 FPS, native 119.7 FPS, firstDraw 6.19 s.

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
| M1 | All character work runs on the main thread inside the 30 Hz Studio timer, so any tick over 8.3 ms drops 120 Hz frames and a tick over 33 ms halves the timer rate | `StudioModel.advanceLiveFrame` | measured; **done** | baseline tick 43.4 ms at 15 ticks/s; the animation clock advances 1/30 s per tick, so live animation played at half speed | evaluate the source previews off the main thread and in parallel (each `SourceStudioCharacterPreview` is independent), double-buffer the resulting `RenderFrame` pieces; main thread keeps only the merge. After the quick wins the remaining ~9 ms/tick for 6 characters would drop to ~1.5–3 ms wall. **Done** in [phase 2, item 3](#phase-2-item-3-live-tick-off-the-main-thread): one lease per preview, a deterministic join, and the main thread keeps the snapshot, commit and merge. Idle main thread 237–251 → 22 ms/s; the 7 characters take 0.93–0.97 ms of wall time on workers | High: previews are classes with caches and dynamics state; needs ownership rules and a deterministic join so captures stay byte-identical |
| M2 | Every document change re-evaluates all of `StudioView` | `StudioView.body` reads `model.doc` (workspace list, toolbar, inspector) | measured | orbit: `GraphHost.flushTransactions` 733 ms/s, inside it `ViewBodyAccessor.updateBody` 194 ms/s and `NSHostingView.layout` 148 ms/s, against 19 ms/s in `StudioView.body` itself ([rank 4](#ranked-costs)) | split `StudioView` into child views that each read only what they show (workspace list, toolbar, timeline, inspector), with per-event state (camera, an FK drag in progress) outside what they read. **Done** ([phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation)): an FK drag event re-evaluates 4 outer views whose content is skipped, and an orbit event none | Low–medium: UI captures (`IKKOKU_CAPTURE_UI` lanes) must stay identical |
| M3 | Camera orbit, pan and dolly mutate `doc.camera`; the `doc` didSet then runs a full `refresh()` and invalidates every view that reads `doc` | `StudioModel` (`doc` didSet, `mouseDragged` `.orbit`) | measured | orbit: `refresh()` 0.89 ms × 76/s plus the SwiftUI cost of M2 per event | keep the view camera outside the observed document (or in its own observed property) and send camera-only changes straight to the renderer's frame uniforms without rebuilding items. **Done** ([phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation)): `documentCamera` has its own observation, and orbit and pan drags reuse the frame's camera-independent content | Medium: the camera is saved with the document and undo must keep working |
| M4 | Maker slider writes invalidate the whole source rig panel | `SourceRigPanel.body` reads `sourceBodyValues`/`sourceFaceValues` for every slider | measured | `maker-slider`: `NSHostingView.layout` 591 ms/s, `Slider.body` 53 ms/s, material effect updates 111 ms/s at 66 writes/s ([rank 3](#ranked-costs)) | one row view per slider taking its value and a setter, the slider list in a child view, and per-slot observation so only the dragged row re-evaluates. **Done** ([phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation)): 11.8 → 2.5 ms of graph update per write; the panel's layout remains | Low |
| M5 | Hover pick is a synchronous GPU round trip per `mouseMoved` | `StudioModel.mouseMoved` → `Renderer.pick` (`waitUntilCompleted`) | measured; **done** | 2.02 ms p50 per event at 46 events/s with a selection | pick asynchronously (completion handler, apply the hover on the next frame) and only for the latest mouse position; a 1×1 scissor on the pick pass cuts its GPU work. **Done** ([phase 2, item 5](#phase-2-item-5-asynchronous-hover-pick)): 2.29–2.41 → 0.01 ms per move on the main thread; the pick pass's GPU time 0.13 → 0.06 ms, its 0.85 ms deform pass remains | Low; renderer file |
| M6 | The Studio timer is a default-mode `Timer`; ticks skip while the timer handler is late and it does not fire during AppKit event tracking | `StudioModel.init` | hypothesis | the 15 Hz tick rate above is the late-handler case | drive the live step from the display link's target time with a fixed 1/30 s accumulator so animation speed never depends on main-thread load | Medium: the scenario lanes rely on fixed 1/30 s steps, which an accumulator keeps |
| M7 | Status-line churn | `StudioModel.tick` → `RenderStatusReporter.status` | measured (negative) | assigns only when the text changes | none needed | — |
| M8 | Native characters step hair dynamics once per `refresh()`, not per tick, so an orbit (one refresh per mouse event) runs their hair simulation faster than real time | `StudioModel.refresh` (`inst.stepHairDynamics(dt: 1/30)`) | measured (code path) | `studio-native` refreshes at 30/s idle; any extra refresh adds a 1/30 s step | step native hair only from the live tick. Since [phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation), an FK drag event refreshes once instead of twice, and orbit and pan with native characters still refresh fully | Behavior change; a correctness fix more than a performance one |

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
| C2 | Hair dynamics rebuilds a full-rig transform state (all nodes, children lists, world matrices) per DynamicBone component per step and validates its output with a full `rig.evaluate` | `SourceDynamicBone.advance`, `DynamicsTransforms` | measured; **done** | 3.25 ms/tick: `DynamicsTransforms.init` 1.84, `pose(rig:)` 0.66 (`rig.evaluate` 0.48, `restPose` 0.13), teardown 0.32 | cache the topology per rig, transform only the required chains, validate only the changed nodes; ~2.5 ms/tick. **Done** in [phase 2, item 3](#phase-2-item-3-live-tick-off-the-main-thread): `SourceStudioDynamics.evaluate` 358 → 75 ms and `DynamicsTransforms.init` 181 → 16 ms over the 180-tick digest run, digest unchanged | Medium: must keep the float results bit-identical (same operation order) |
| C3 | `SourceStudioPose` is rebuilt for every pose evaluation | `KoikatsuCharacterRecord.makePose` | measured; **done** | 1.4 ms/tick (init 0.58, apply 0.51, late update 0.23) | cache the bound pose per (rig, record, kinematics). **Done** in [phase 2, item 3](#phase-2-item-3-live-tick-off-the-main-thread): `makePose` 263 → 46 ms over the digest run (only the application of the cached binding remains) | Low |
| C4 | Eye look evaluates the whole rig to read four nodes | `SourceStudioCharacterPreview.updateEyeLook` | measured | ~0.1 ms/tick | evaluate the ancestor chains only | Low |
| C5 | Source expression weights are recomputed and revalidated per frame | `SourceRigPreview.expressionWeights` | measured; **done** | 0.45 ms/tick | cache per expression input. **Done** in [phase 2, item 3](#phase-2-item-3-live-tick-off-the-main-thread): `expressionWeights` 95 ms → no sample over the digest run | Low |
| C6 | `refresh()` rebuilds every character's `RenderFrame` (items, skin sets, bounds) for camera-only changes | `StudioModel.refresh` | measured; **done** for drags | 0.89 ms per orbit event | see M3; orbit and pan drags now take 0.04 ms (`refreshCamera`, [phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation)); scroll and pinch dolly still rebuild | Medium |
| C7 | Maker's live step evaluates the rig only to validate the pose, then the refresh evaluates it again | `MakerModel.advanceSourceMotion` | hypothesis | `makerTick` 2.0 ms p50 in `maker-idle` | reuse the validated evaluation in the refresh | Low |
| C8 | Studio scene/character load decodes the same rig JSON once per character and component | `SourceMakerLibrary.prepare` → `SourceRig.load` | measured | probe load 6.1 s for 6 characters, 74% in `SourceRig.decode` (JSONDecoder) | cache decoded rigs by path, size and modification time; or a binary rig format | Low for the cache |
| L1 | With the live source-shader opt-in ON, every `refresh()` maps each frame item back to its source renderer again (mesh-name parsing, a filter over all binding-set renderers per item, shader-name splits, report strings); the materials themselves are cached | `StudioModel+SourceShaderLive.swift` → `SourceShaderLiveAssembly.attach` | measured | 0.39 ms per refresh (11.6 ms/s at 30 Hz), 39% in `SourceShaderLiveMaterial.family(of:)` ([live opt-in](#the-live-source-shader-opt-in-127)) | cache the item-to-slot mapping per character while its meshes, visibility and wear are unchanged, and index the renderers by (mesh, submesh); most of the 0.39 ms (hypothesis until measured) | Low; the opt-in is OFF by default and its report must stay the same |

### Metal

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| G1 | GPU time is not the bottleneck on the reference machine | whole frame graph | measured | 1.3–1.9 ms GPU per frame at 1996×1824, 6 characters; draw encoding 0.6–0.9 ms CPU | — | — |
| G2 | MSAA color/depth, overlay depth and pick depth are already memoryless | `RenderTargets` | measured (code) | `storageMode = .memoryless` | — | — |
| G3 | Unchanged frames are fully re-rendered at the display rate, including the deform compute pass and the 2048² shadow map | `Renderer.draw`, `ViewportNSView` | measured | 120 draws/s while Studio content changes 30 times/s and the camera is still | skip prepare/encode/present when the frame and drawable size did not change (frame version counter); or lower `preferredFrameRateRange` when idle. ~3/4 of GPU and draw CPU at idle | Low |
| G4 | Skin matrices are copied into a new `MTLBuffer` per skin set per frame and validated element by element | `Renderer.buildContext` | measured; **done** | 0.70 ms per draw in orbit, 122 buffers per draw in the source scene ([phase 2, item 1](#what-remains-on-the-main-thread)) | write skin matrices into the frame ring. **Done** in [phase 2, item 2](#phase-2-item-2-render-thread-and-frame-ring-skin-palettes): no palette buffer is created once the ring is warm, and the offscreen CPU encode fell from 0.74 to 0.44 ms per frame | Low; renderer file |
| G5 | Shadow map re-rendered every frame | `Renderer` shadow pass | hypothesis | — | re-render only when casters or the light moved | Low |
| G6 | No pipeline binary archive | `Pipelines` | hypothesis | pipeline creation happens during startup | `MTLBinaryArchive` for the production pipelines; measure first-launch versus warm | Low |
| G7 | Textures are uncompressed RGBA with runtime mip generation | `ResourceStore` (`MTKTextureLoader`, `.generateMipmaps`) | hypothesis | Metal allocation 470 MB peak for 6 characters | ASTC/BC compression at conversion time, cached mips; mostly memory and bandwidth (M1) | Medium: image quality must be checked |
| G8 | Argument buffers / Metal 4 argument tables, indirect command buffers, residency sets, heaps, parallel encoding | renderer | hypothesis | draw encoding is ≤ 0.9 ms CPU per frame | low value until item counts grow (many-prop scenes) | — |

### Frame pacing

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| P1 | The display link runs on the main run loop, so every model or SwiftUI hitch is a presentation hitch | `ViewportNSView.viewDidMoveToWindow` | measured; **done** | idle baseline: 44.7 presented FPS, 150 hitches in 10 s while GPU and draw take < 3 ms | run the display link on a dedicated render thread; `Renderer` already snapshots the frame under `frameLock`. **Done** in [phase 2, item 2](#phase-2-item-2-render-thread-and-frame-ring-skin-palettes) (`ViewportRenderThread`) | Medium: renderer state touched from two threads (errors, statistics, pick); the [threading contract](renderer.md#renderer-threads-r7-phase-2-item-2) covers it |
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
| 1 | **Done** ([phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation)). Narrow SwiftUI invalidation. Move the camera out of the observed `doc`, or into its own observed value. Split `StudioView` into child views that read only their own state. Make the Maker slider rows value-driven views with per-slot observation | M2, M3, M4, C6 | orbit, FK drag and slider edits go from 7–25 ms per event to a few ms; the main thread is no longer saturated during interaction; presented FPS for those workloads rises from 24–53 toward 120 | the same edits drop from ~10–30 ms to a few ms; the difference between usable and laggy | `IKKOKU_CAPTURE_UI` window captures identical; undo/redo scenarios (`undo-camera`) pass |
| 2 | **Done** ([phase 2, item 2](#phase-2-item-2-render-thread-and-frame-ring-skin-palettes)), with G4. Run the display link on its own thread. `Renderer` already snapshots the frame under `frameLock`; pick, statistics and error reporting need the same treatment. Measured: with the main thread busy 600 ms/s, 120 FPS and an 8.33 ms p95 interval, against 30–60 FPS and 25–33 ms | P1, G4 | main-thread work no longer delays presentation; hitches/s fall to the GPU's own rate | larger: more of the main-thread cost is hidden | presented-interval p95 at 8.3 ms with a busy main thread (harness) |
| 3 | **Done** ([phase 2, item 3](#phase-2-item-3-live-tick-off-the-main-thread)), with C2, C3 and C5. Take the live tick off the main thread and evaluate the characters in parallel. Cache the dynamics topology per rig (C2) and the bound Studio pose (C3). Hair dynamics is now the largest part of the tick: `SourceDynamicBone.step` took 48% of `advanceLiveFrame` in the in-app Time Profiler run of the live opt-in (122 of 255 ms/s). Measured: idle main busy 237–251 → 22 ms/s, the step 8.0 ms on the main thread → 0.6 ms (snapshot and refresh) plus 0.93–0.97 ms of worker wall time; digest and captures identical | M1, C2, C3, C5 | the 6-character tick goes from ~6 ms on the main thread to < 2 ms wall-clock; more characters scale with cores | M1 has 4 performance cores, so ~4× on the tick | probe digest identical; scenario renders identical; deterministic join order |
| 4 | Skip unchanged frames and run the display link at 30–60 Hz when nothing moves; leave the shadow map alone until casters or the light move | G3, G5, P2 | ~3/4 of idle draw CPU and GPU | the biggest GPU item on M1: idle GPU at ~10 ms/frame becomes ~2.5 ms of every 8.3 ms | captures identical (nothing renders differently, frames are only skipped) |
| 5 | **Done** ([phase 2, item 5](#phase-2-item-5-asynchronous-hover-pick)). Asynchronous hover pick for the latest mouse position only, and a scissored pick pass. Measured: 2.29–2.41 → 0.01 ms per move on the main thread, hover's main busy time 518–531 → 239–242 ms/s, pick ids identical | M5 | 2 ms per mouse move off the main thread; fixes the hover hitch rise | same | gizmo hover scenarios |
| 6 | Startup: cache decoded rigs and load source characters concurrently off the main thread, with a progress state | C8, S1, S2, S4 | source scene ready in ~1.5 s instead of 4.7 s; first frame earlier | larger, since there is less memory bandwidth for repeated decoding | `startup` workload; scene import results identical |
| 7 | An opt-in optimized-Engine Debug build for app work | B1 | a Debug app at Release speed for Engine code | same | captures identical Debug and Release (already true) |
| 8 | Texture compression at conversion time; release staging data after upload | G7, R1 | smaller footprint and bandwidth | main memory-pressure relief on 8 GB | image comparison; this is a quality trade-off, so it stays opt-in until compared |
| 9 | **Done** ([phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation)). Instrument `StudioModel` directly: explicit tick, refresh and doc-change hooks in place of the inferred ones | harness | exact Studio attribution (the inferred hooks cannot separate a SwiftUI pass caused by a doc change from one caused by layout) | — | `test_perf_trace.py`, harness report schema |
| 10 | With the live source-shader opt-in ON, cache the item-to-slot mapping between refreshes | L1 | ~0.3 ms of each 0.39 ms refresh attach, only with the opt-in ON | same share | the live report and ON captures identical |

## Phase 2, item 1: narrow SwiftUI invalidation

Done 2026-10-23, together with item 9 (explicit Studio hooks). Interactive
edits no longer re-evaluate the whole window. Orbit, FK drag and Maker slider
edits now present at 119–120 FPS with at most one hitch in 10 s. Before, they
presented 27–43 FPS with about 30 hitches/s. Rendered frames are
byte-identical. Window captures are too, except one toolbar picker whose
layout already depended on its update history (see [correctness](#correctness)).

### What changed

- **Camera.** `StudioModel.doc` is a computed property over unobserved
  storage. Its accessors mirror the `@Observable` macro: a whole-value set
  notifies only when the value differs, an in-place mutation always notifies,
  and every write still prunes voices and refreshes. Camera writes go through
  `documentCamera`, which notifies only camera readers. That covers orbit,
  pan, dolly, the camera slots, reset, focus and look-through. No view reads
  the camera; the renderer gets it through the frame. A document write that
  changes the camera, such as a scene load or undo, also notifies camera
  readers. Saving, undo and export still read `doc.camera`.
- **Menu commands.** `documentSourceSceneFile` and `hasSourcePluginSession`
  are observed on their own, so the app's commands no longer read the whole
  document.
- **Studio window.** `StudioView` is split into panels: workspace tree,
  toolbar, timeline, inspector tab picker, compatibility details,
  live-shader details, inspector tab and status line. The workspace,
  toolbar, timeline and Object inspector compute their displayed values in a
  small outer view and pass them to an `Equatable` content view, which
  SwiftUI skips while the values are unchanged. The controls' bindings read
  those values and write through the same model members as before. Workspace
  rows are `Equatable` too. The other inspectors are unchanged apart from
  their counters.
- **FK and IK drags.** `setSourceFKRotation` and `setSourceIKValue` edit a
  copy of the object and write the document once, so each drag event rebuilds
  the frame once instead of twice. The grab still pushes exactly one undo
  snapshot; the `studio-fk-drag` workload checks this.
- **Camera-only frames (C6).** During an orbit or pan drag, a camera write
  reuses the last full frame's camera-independent content: items, skin sets,
  lights, bounds and effects. Source previews take the camera only for their
  frame's camera field. `refreshCamera` rebuilds only what depends on the
  camera: the camera, the main light, the selected source character's FK/IK
  guides and the selection gizmo. The light and camera glyph batch is reused.
  The reuse is dropped by any new drag or full refresh. It is not kept for a
  frame with native characters, whose gaze reads the camera and whose hair
  steps per rebuild (M8), or with live source shaders, or for a rebuild that
  wrote a status. The timer does not step the scene during a drag. A reused
  frame keeps its creation stamp, so resource retirement treats it like the
  frame it came from (R6). Scroll and pinch dolly, and the scenario runner's
  `orbit` step (no drag), still do a full refresh.
- **Maker sliders (M4).** `sourceBodyValues` and `sourceFaceValues` notify
  per slot (`MakerModel[shapeSlot:]`) and per count (`shapeValueCount(face:)`).
  Each body and face slider is a `SourceShapeSliderRow` that observes its own
  slot, and its binding writes through the arrays as before. A write still
  invalidates the simulation and refreshes, also for an unchanged value.
  Failure handling and the cached selection rows of the Maker handoff are
  untouched.
- **Instrumentation (item 9).** See [what the report records](#what-the-report-records).

### Measurement

The commands follow [measuring a change](#measuring-a-change). Release builds,
arm64:

| Label | Commit | Executable SHA-256 |
| --- | --- | --- |
| base | `88d8447` (`main` before this change) | `47f5c780…a07b21` |
| instrumented | `e6ba33d`: base plus the item 9 hooks and counters, no narrowing | `d195e598…557cbd` |
| after | `4d34863`: this change | `e114c8a7…a26b92` |

All runs used the 4K display at 120 Hz with a 1996×1824 drawable, during a
quiet window that the orchestrator granted. No build ran, which was checked
before and after every launch, and every launch took the app lock. The load
average was 3.2–7.6. Base and instrumented ran all six workloads, then after
ran all six, then base and instrumented repeated idle and hover. Each run had
a 3 s warmup and 10 s of recording. No run was flagged invalid. Reports are
in `.local/r7b-swiftui-invalidation/perf/{w2-base,w2-instrumented,w3-after,w3-base,w3-instrumented}`.

| Workload | Build | Presented FPS | Hitches/s | Main busy ms/s (draw / model / other) | Model phases, p50 ms × rate | Input p50 ms × rate |
| --- | --- | ---: | ---: | --- | --- | --- |
| studio-orbit | base | 41.0 | 30.4 | 996 (38 / 79 / 879) | refresh 1.00 × 72 | 1.08 × 72 |
| studio-orbit | after | 119.4 | 0.6 | 268 (245 / 10 / 13) | camera refresh 0.04 × 120 | 0.07 × 120 |
| studio-fk-drag | base | 26.7 | 27.7 | 998 (27 / 93 / 877) | refresh 1.49 × 63 (2 per event) | 2.94 × 31 |
| studio-fk-drag | after | 119.9 | 0.1 | 497 (120 / 231 / 146) | refresh 1.88 × 120 (1 per event) | 1.92 × 120 |
| maker-slider | base | 43.4 | 30.7 | 998 (13 / 53 / 932) | refresh 0.48 × 95 | 0.57 × 65 |
| maker-slider | after | 119.8 | 0.1 | 608 (34 / 87 / 488) | refresh 0.53 × 150 | 0.58 × 120 |
| studio-hover | base | 105.8, 90.0 | 14.4, 30.6 | 583, 633 | tick 7.38 × 30, 7.40 × 30 | 2.47 × 95, 2.59 × 120 |
| studio-hover | after | 90.1 | 30.5 | 611 (88 / 517 / 6) | tick 7.48 × 30 | 2.58 × 106 |
| studio-idle | base | 90.0, 119.3 | 30.8, 0.7 | 342, 362 | tick 8.03 × 30, 7.71 × 30 | – |
| studio-idle | after | 119.9 | 0.1 | 362 (125 / 232 / 5) | tick 7.75 × 30 | – |
| maker-idle | base | 119.8 | 0.2 | 157 (94 / 51 / 12) | tick 1.63 × 30 | – |
| maker-idle | after | 120.0 | 0 | 182 (111 / 56 / 15) | tick 1.69 × 30 | – |

Notes on the table:

- **Rates went up.** The saturated workloads' input timer now gets its
  120 Hz, so after handles about 1.7–3.9 times more events per second. Read
  "ms per event × rate", not the busy totals.
- **Hover and idle are unchanged by this work, and their frame rate is
  bimodal.** The 30 Hz tick takes 7.4–8.0 ms, just under the 8.33 ms frame.
  Whether each tick also drops a frame depends on its phase against the
  display link. Each build showed both modes: base hover at 105.8 and 90.0
  FPS, instrumented at 117.8 and 90.1, base idle at 90.0 and 119.3. The
  model and draw costs match across builds within run-to-run variation.
- **The instrumented build costs nothing measurable.** Its rows (in the same
  reports) match base within run-to-run variation: for example idle tick
  7.97 against 8.03 ms and orbit refresh 1.02 against 1.00 ms. Its explicit
  hooks agree with the inferred hooks of base within about 10% (FK drag
  refresh 1.34 against 1.49 ms in the same window).

View bodies evaluated per input event, from the item 9 counters
(instrumented against after; base has no counters):

| Workload | Instrumented (base structure) | After |
| --- | --- | --- |
| studio-orbit | 1 document change; window, workspace, toolbar, timeline, inspector, status line 1 each; app commands 0.87; workspace rows 27.4 | 1 camera change; no view body |
| studio-fk-drag | 2 document changes; window, workspace, toolbar, timeline, inspector, status line, Object inspector, app commands 1 each; workspace rows 27.9 | 1 document change; workspace, toolbar, timeline and Object inspector outer views 1 each (their content views are skipped) |
| maker-slider | 44 slider rows | 1 slider row |

Attribution with Time Profiler, 5 s per workload. Base was recorded in the
baseline window (`.local/r7b-swiftui-invalidation/perf/base-tp`) and after
in this window (`perf/after-tp`). Main thread, per input event:

| Workload | `GraphHost.flushTransactions` base → after | `NSHostingView.layout` base → after | Main thread busy base → after |
| --- | --- | --- | --- |
| studio-orbit | 8.9 ms (726 ms/s at 81.5/s) → none sampled | 1.96 ms → none sampled | 996 → 250 ms/s |
| studio-fk-drag | 23.8 ms (724 ms/s at 30.4/s) → 0.91 ms | 4.4 → 1.06 ms | 997 → 537 ms/s |
| maker-slider | 11.8 ms (787 ms/s at 66.9/s) → 2.5 ms | 8.3 → 3.9 ms | 995 → 622 ms/s |

### What remains on the main thread

- **Orbit: the draw.** About 94% of the remaining 250 ms/s is the display link's
  `Renderer.draw` at 120 Hz. Its CPU time per draw is 1.83 ms p50 (3.86 p95),
  against 0.89 ms at 41 FPS before and 0.99 ms in FK drag at the same draw
  rate. `Renderer.buildContext` takes 1.18 ms per draw. Of that, 0.70 ms
  creates one shared `MTLBuffer` per skin palette (`newBufferWithBytes`,
  mostly `IOGPUResourceCreate` kernel calls, G4), against 0.31 ms per draw
  in FK drag. Why orbit takes the slower allocation path more often is not
  established.
- **FK drag: the frame rebuild.** `StudioModel.refreshFrame` takes 1.95 ms
  per event (234 ms/s). `SourceStudioCharacterPreview.frame` is 190 ms/s of
  that, and its expression weights (C5) are 93 ms/s. SwiftUI takes about
  1.1 ms per event for the four outer views and their skipped content. The
  draw takes 129 ms/s.
- **Maker slider: SwiftUI layout of the long panel.** One row is evaluated
  per write, but the panel is still re-laid out: `NSHostingView.layout` takes
  3.9 ms per write. That splits into graph update 2.5 ms (dirty propagation
  from the slot's observation 0.66 ms, body updates 0.34 ms, root geometry
  0.32 ms) and the display-list render, about 1.4 ms. Making the rows'
  layout independent of their value text would change pixels, so it was
  left out.
- **Hover and idle: the 30 Hz tick** (7.4–8.0 ms) and the synchronous hover
  pick (2.5 ms per move) are unchanged.

### Behavior notes

- **FK drags in mixed scenes.** A scene with both native and source
  characters now steps native hair once per FK drag event instead of twice
  (M8 applies per refresh). Orbit and pan with native characters keep the
  full refresh, so M8 is unchanged there.
- **The menu commands** re-evaluate only when the scene file or plugin
  session presence changes, not on every document edit.

### Correctness

- **Captures, base against after.** 12 captures were taken with each build
  under the app lock (`.local/r7b-swiftui-invalidation/captures`). Five were
  `IKKOKU_CAPTURE_UI` window captures of the source scene, one per Studio
  inspector tab (object, pose, face, clothes, scene). Two were window
  captures of the native scene added from the Maker card (object, pose). Two
  were window captures of the Maker: the source card's rig panel and the
  native Body tab. Three were `IKKOKU_AUTOCAPTURE` renders: the source scene,
  `IKKOKU_CAPTURE_STUDIO` and the Maker source card. Two base runs were
  byte-identical to each other in all 12 PNGs and all 9 UI reports.
  - After matched base byte for byte in all 9 UI reports, all three
    renders, the source object tab, both native-scene tabs and both Maker
    captures.
  - The source pose, face, clothes and scene tab captures differ in 4,700
    pixels, all inside one 330×40 px box: the toolbar's pose-mode picker
    (Object/FK/IK). In those four base captures, the picker's segments are
    laid out at equal widths and the control overflows its 150 pt frame.
    After draws it fitted, exactly as base draws the same picker state in its
    object-tab capture: that region is byte-identical between base's object
    tab and after's pose tab.
  - The likely cause: a source scene opens the app in Studio, so the
    capture sets the inspector tab after the Studio window first appeared.
    Base's window body read the tab, so the toolbar was rebuilt. After's
    toolbar does not depend on the tab. The native scene opens in the Maker,
    so its tab is set before the Studio window first appears, and base's
    native pose tab matches after.
  - The picker's look thus depends on whether SwiftUI updated it after its
    first layout, and it did so before this change too. It is not new
    content.
- **Lanes on the merged head** (`23db124`, `main` `9baebcb`, Debug):
  `studio-scenarios` 52/52 (1,726 s) and `maker-scenarios` 5/5, both
  `--strict` with 0 skipped. They include the undo/redo, reload and
  camera scenarios.
- **Suites on the merged head.** The Engine `swift test`, run through
  `public.json` without `--strict`, reported 763 tests: 681 passed, 82 named
  skips without fixtures, 0 failed. The runner self-tests passed 181/181,
  including `test_perf_trace.py`. The studio-inspector validator passed
  11/11 and the mod tools 40/40.
  - In `translation-tests`, one test fails in a worktree whose `.local/reverse`
    is a symlink: `plugin.package` resolves the test's output outside the
    worktree's `.local` and refuses it. That test is
    `test_plugin_py_native_route_output_is_indexed_without_running_a_decompiler`.
    This change touches no file under `Tools/translation` and no Engine
    source.

### Limits

- **One run per build and workload** in this window, plus the idle and hover
  repeats. The saturated base runs vary by tens of percent (see
  [baseline](#baseline)). The after runs are not saturated, so their numbers
  are steadier.
- **Per-event SwiftUI numbers come from Time Profiler samples**, 5 s each.
  Base was recorded in the earlier window on the same build.
- **No M1 run.**

### Recommended next

Item 2: run the display link on its own thread. After this change, the
remaining hitches come from main-thread work landing on a frame: the 7.5–8 ms
live tick (idle and hover alternate between 90 and 120 FPS), the hover pick,
and in orbit the draw itself (245 ms/s). Item 2 removes all of these from
presentation at once. G4, writing skin palettes into the frame ring instead
of new buffers, is a small renderer change that would roughly halve orbit's
per-draw CPU. Item 3 (the tick off the main thread) comes next.

## Phase 2, item 2: render thread and frame-ring skin palettes

Done 2026-10-23, together with G4. Each viewport's display link now runs on
its own render thread, so main-thread work no longer delays presentation, and
skin palettes are written into the frame ring instead of a new `MTLBuffer` per
skin set per prepared frame. Rendered frames and window captures are
byte-identical.

With the main thread loaded 600 ms/s on purpose, presentation is
unaffected. The Studio presents 119.8–120.0 FPS with a p95 interval of
8.33 ms, against 30–60 FPS and 25–33 ms with the display link on the main
thread. Without load, item 1 had already brought every workload to about
120 FPS. Hover no longer drops to 90 FPS, and the draw's 94–215 ms/s left
the main thread. G4 cut the renderer's CPU encode from 0.74 to 0.44 ms per
frame, offscreen. Orbit's slow allocation path turned out to be the CPU
running slower when the process is nearly idle (see [G4](#why-orbit-took-the-slow-allocation-path-g4)).

### What changed

- **Render thread (P1).** `ViewportNSView` gives each viewport a
  `ViewportRenderThread`: a `Thread` named `com.grabbiel.Ikkoku.viewport-render`
  (QoS user-interactive) whose run loop drives the viewport's
  `CAMetalDisplayLink`. The link keeps `preferredFrameLatency` 2. Its callback
  calls `Renderer.draw`, which presents from that thread. The models still
  build frames and call `submit`, `pick` and `capture` on the main thread; the
  `StudioModel` and `MakerModel` APIs are unchanged. The thread starts when the
  view enters a window and stops when it leaves it, is dismantled or
  deinitializes. On quit, the view waits up to 0.5 s for a draw in progress.
- **Renderer threading.** `Renderer` state that both threads touch is guarded
  explicitly. `renderLock` covers everything a frame's preparation touches;
  the draw now takes the pending frame under it, so frame retirement (R6)
  stays ordered. `statusLock` covers the published diagnostics, including the
  GPU time that the completion handler writes. The live captures check their
  deformation errors under the render lock. The contract, lock order and the
  reasoning about command buffers committed from two threads are in
  [renderer threads](renderer.md#renderer-threads-r7-phase-2-item-2).
- **Skin palettes (G4).** `FrameRing.allocatePalettes` copies all of a frame's
  palettes into one shared buffer per ring region, each at a 256-byte aligned
  offset; the native and live deform passes bind that buffer and offset. The
  buffer follows the region's in-flight rule and grows by doubling from 64 KiB.
  Once each region has seen the largest frame, no palette buffer is created.
  The finiteness check is now four lanes at a time per column
  (`Renderer.allFinite`), with the same result as the per-element check.
- **Harness (schema 3).** The draw log is recorded on whichever thread runs
  the link. Reports gain `drawThread`, `renderThread`, `frameRing`, the
  main-thread load knob and the `viewport-lifecycle` workload (see
  [what the report records](#what-the-report-records)).

### Measurement

The commands follow [measuring a change](#measuring-a-change). Release builds,
arm64:

| Label | Commit | Executable SHA-256 |
| --- | --- | --- |
| base | `0c51ca1` (`main` before this change) | `3d4aeb00…dc864c` |
| harness | `8a2b7ed`: base plus the schema 3 harness (draw log off the main actor, main-thread load knob, lifecycle workload), renderer unchanged | `a3bd4e04…522fd0` |
| after | `7a265f6`: this change with `main` `c3e83fa` merged | `23b1d10e…a4a26c` |

The PR head `008085c` also merges `main` `ad50c43` (#146), which arrived after
the measured window. #146 changes `StudioModel.swift` (the IK status report,
and publishing the source camera view in `refreshFrame`), `StudioView.swift`
and `StudioScenario.swift`, and it adds an Engine status-text file. It touches no renderer, GPU, viewport or harness
file. The threading and presentation numbers below therefore still describe
the PR. Model-phase costs such as the Studio refresh were measured without
#146.

All runs used the 4K display (M32UC) at 120 Hz and 2×, with a 1996×1824
drawable, in a quiet window that the orchestrator granted on 2026-10-24.
Every launch took the app lock, and the load average was 3.0–4.6. Base and
after alternated per workload, and idle and hover ran twice. Each run had a
3 s warmup and 10 s of recording. `summarize` flagged no run. Reports are in
`.local/r7c-render-thread/perf/{base,after,harness}`.

"Draw ms" is `Renderer.draw` CPU time per frame, p50, on the main thread for
base and on the render thread for after.

| Workload | Build | Presented FPS | Hitches/s | Presented interval p50 / p95 ms | Main busy ms/s | Draw ms p50 |
| --- | --- | ---: | ---: | --- | ---: | ---: |
| studio-orbit | base | 119.9 | 0.1 | 8.33 / 8.33 | 234 | 1.74 |
| studio-orbit | after | 119.6 | 0.4 | 8.33 / 8.33 | 20 | 1.44 |
| studio-fk-drag | base | 120.0 | 0 | 8.33 / 8.33 | 514 | 1.06 |
| studio-fk-drag | after | 120.0 | 0 | 8.33 / 8.33 | 363 | 0.71 |
| studio-hover | base | 119.6, 89.9 | 0.4, 30.0 | 8.33 / 8.33, 8.33 / 16.67 | 654, 675 | 0.96, 0.94 |
| studio-hover | after | 119.7, 119.7 | 0.3, 0.3 | 8.33 / 8.33 | 545, 545 | 0.69, 0.69 |
| studio-idle | base | 119.9, 120.0 | 0.1, 0 | 8.33 / 8.33 | 359, 357 | 1.02, 1.00 |
| studio-idle | after | 119.9, 120.0 | 0.1, 0 | 8.33 / 8.33 | 249, 238 | 0.74, 0.71 |
| maker-slider | base | 119.5 | 0.1 | 8.33 / 8.33 | 607 | 0.27 |
| maker-slider | after | 120.0 | 0 | 8.33 / 8.33 | 566 | 0.22 |
| maker-idle | base | 119.9 | 0.1 | 8.33 / 8.33 | 161 | 0.76 |
| maker-idle | after | 119.9 | 0.1 | 8.33 / 8.33 | 51 | 0.59 |
| studio-native | base | 119.8 | 0.2 | 8.33 / 8.33 | 191 | 1.03 |
| studio-native | after | 119.6 | 0.4 | 8.33 / 8.33 | 57 | 0.96 |

**Busy main thread (the item 2 acceptance case).** `--main-load-ms 20`
busy-waits 20 ms on the main run loop 30 times a second, about 600 ms/s.
Base has no load knob, so these rows compare the harness build (base
renderer) with after:

| Workload + 20 ms × 30/s | Build | Presented FPS | Hitches/s | Presented interval p50 / p95 ms | Draw ms p50 |
| --- | --- | ---: | ---: | --- | ---: |
| studio-idle | harness | 58.4 | 29.9 | 25.00 / 25.00 | 0.82 |
| studio-idle | after | 119.8 | 0.2 | 8.33 / 8.33 | 0.55 |
| studio-native | harness | 60.1 | 29.8 | 8.33 / 25.00 | 0.36 |
| studio-native | after | 119.9 | 0.1 | 8.33 / 8.33 | 0.29 |
| studio-orbit | harness | 60.2 | 29.9 | 8.33 / 25.00 | 0.81 |
| studio-orbit | after | 120.0 | 0 | 8.33 / 8.33 | 0.53 |
| studio-fk-drag | harness | 30.1 | 29.9 | 33.33 / 33.33 | 0.84 |
| studio-fk-drag | after | 119.9 | 0.1 | 8.33 / 8.33 | 0.59 |

Notes on the tables:

- **Presentation no longer waits for the main thread.** With a busy main
  thread, base presents at 30–60 FPS, with one hitch per load period and a
  p95 interval of 25–33 ms. After presents at 120 FPS with a p95 of 8.33 ms,
  the acceptance target. Without load, item 1 had already brought every
  workload to about 120 FPS, so FPS changes little there. The exception is
  hover, whose 7.7 ms tick made base alternate between 120 and 90 FPS
  (bimodal, as in item 1); after presented 119.7 FPS in both runs.
- **Main-thread time.** The draw left the main thread: 215 ms/s in orbit,
  123 ms/s in native and 94 ms/s in maker-idle. Input and the FK and camera
  refreshes cost the same per event (FK drag refresh 1.88 → 1.80 ms).
- **The source-scene live tick is 3–7% slower.** Hover: 7.18 and 7.23 ms
  in base, 7.61 and 7.69 ms in after. Idle: 7.75 and 7.76 ms in base, 7.89
  and 8.27 ms in after. Idle with load: 5.49 ms in the harness build, 5.82 ms
  in after. The native scene's tick is unchanged (1.74 → 1.71 ms). The cause
  is not established. A candidate is that the draw now overlaps the tick on
  another core. They share caches, and they touch the reference counts of
  the same frame objects. The tick still fits a 30 Hz period, but it is the
  largest main-thread cost left (item 3).
- **Draw CPU per frame** fell 17–33% in the source-scene workloads and 7%
  in the native scene, which has 6 palettes per draw instead of 122. These
  numbers combine G4 with a CPU-clock effect, which the next section
  separates.
- **Busy-main FK drag also handles more input**: 86 against 69 events/s,
  because the drag no longer shares the main thread with the draw.
- **The harness build costs nothing measurable** against base: orbit 119.4
  FPS and 1.78 ms draw (base 119.9 and 1.74), idle 119.8 FPS and 1.01 ms
  (base 1.00–1.02), native 1.08 ms (base 1.03). Main busy time in orbit was
  264 against 234 ms/s; base's own Time Profiler run of orbit had 262.
- **Every after run drew on the render thread** (`drawThread: render`), and
  the frame ring created no palette buffer while recording, with no overflow:
  122 palettes (226.5 KiB) per draw in the source scene, 20 (51 KiB) in the
  Maker and 6 (22.5 KiB) in the native scene.

**Offscreen encode (G4 alone).** `IKKOKU_AUTOCAPTURE` with
`IKKOKU_BENCHMARK_OUTPUT`, the source scene at 1200×1600 and 60 frames, three
alternating runs per build. This path has no display link, so it isolates
the renderer change:

| Build | CPU encode p50 ms | GPU p50 ms | Completion p50 ms |
| --- | --- | --- | --- |
| base | 0.739, 0.742, 0.741 | 1.368, 1.369, 1.370 | 2.535, 2.517, 2.556 |
| after | 0.437, 0.453, 0.423 | 1.364, 1.362, 1.363 | 2.195, 2.259, 2.169 |

CPU encode fell by 0.30 ms per frame (41%), and the GPU time is unchanged.
All six PNGs are byte-identical (`26f712b8…`).

### Why orbit took the slow allocation path (G4)

Item 1 found orbit's draw at 1.83 ms p50 against 0.99 ms in FK drag at the
same draw rate. Of that, the per-palette `newBufferWithBytes` calls took
0.70 ms per draw in orbit against 0.31 ms in FK drag. The two workloads draw
the same scene, with 122 skin palettes per draw. The Time Profiler traces
of item 1 (`.local/r7c-render-thread/g4`, focused on `Renderer.draw`) show
the same calls in both workloads: `IOGPUResourceCreate` and its
`mach_msg2_trap` dominate either way. Orbit's calls just took about 2.2
times longer each, and the rest of its draw was about 1.6 times slower too.

The runs above show why. The draw is slow when the process is otherwise
idle, and fast when the CPU is kept busy:

| Draw ms p50 (idle without load: mean of two runs) | Orbit | FK drag | Idle | Native |
| --- | ---: | ---: | ---: | ---: |
| base renderer, no load (base build) | 1.74 | 1.06 | 1.01 | 1.03 |
| base renderer, main thread loaded (harness build) | 0.81 | 0.84 | 0.82 | 0.36 |
| after, no load | 1.44 | 0.71 | 0.73 | 0.96 |
| after, main thread loaded | 0.53 | 0.59 | 0.55 | 0.29 |

- In orbit, the draw is nearly all the process does: 234 ms/s of main-thread
  time in base, 215 of them the draw. FK drag keeps the main thread about
  half busy with its frame rebuilds.
- The busy-wait load adds no work to the draw. Even so, it makes orbit's
  draw 2.1 times faster in base (2.7 times in after), and native's 2.9 and
  3.3 times.
- With load, orbit and FK drag cost the same per draw, in both builds.

So orbit did not take a slower path. The same work ran on a less busy CPU,
most likely at lower clock speeds; the harness cannot read the clocks, so
that part is inferred. Kernel calls such as buffer creation were hit
hardest. This comes from the machine's power management, not from the
renderer.

Two consequences:

- Per-draw CPU times from lightly loaded workloads overstate the work. The
  offscreen benchmark, which renders frames back to back, is the steadier
  measure of encode cost (0.44 ms after, against 0.74 ms in base).
- G4 still matters for orbit, because the buffer creation it removed was
  the part most hurt by the low clocks. Orbit's draw fell from 1.74 to
  1.44 ms with no load, and from 0.81 to 0.53 ms with load.

### What remains

Time Profiler, 5 s per workload, after build. The traces are archived in
`/Volumes/My Book/ikkoku-archive/local/r7c-render-thread/perf/{after-tp,base-tp}`,
and symlinked from `.local/r7c-render-thread/perf`.

- **The render thread: the draw.** Orbit takes 180 ms/s at 120 draws/s,
  1.5 ms per draw. `Renderer.buildContext` takes 0.58 ms of that, and no
  single cost dominates it: item appends, the transparent and opaque sorts,
  the finiteness check, deformation-buffer lookups and the ring copies.
  The palette copy into the ring (`FrameRing.allocatePalettes`) is 2 ms/s.
  Base spent 0.70 ms per draw creating palette buffers; after creates none.
  The main pass takes 0.37 ms per draw. The deform, shadow and post passes
  take 0.53 ms together in orbit but 0.03 ms in FK drag, which encodes the
  same passes. That is mostly driver encoder setup, and it is the part the
  light CPU load inflates most (see [G4](#why-orbit-took-the-slow-allocation-path-g4)).
- **The main thread: the live tick and the hover pick.** In hover, the main
  thread is busy 545 ms/s:
  - The 30 Hz tick takes 7.6 ms (226 ms/s). Its largest parts are the
    edited pose (186 ms/s, including the dynamic bones at 78 ms/s), the eye
    look (107 ms/s) and the frame rebuild (126 ms/s). These overlap, since
    each is nested in the tick.
  - The synchronous hover pick takes 2.6 ms per move (316 ms/s at 120 moves
    per second). Most of it is a wait for the GPU: the main thread's sampled
    CPU time was only 304 ms/s in all. Item 5 has since taken the pick off
    the main thread ([phase 2, item 5](#phase-2-item-5-asynchronous-hover-pick)).
- **FK drag.** The frame rebuild takes 1.80 ms per event (219 ms/s), and
  SwiftUI about 145 ms/s.
- **Maker slider.** The panel's layout takes about 480 ms/s, as in item 1.

None of these delay presentation any more. They set how quickly the scene
reacts: the model rate and the input latency.

### Correctness

- **Captures.** 13 captures per build, each its own launch under the app
  lock, with the shared fixture map (`.local/r7c-render-thread/captures`,
  a symlink into the archive volume):
  - three `IKKOKU_AUTOCAPTURE` renders, live opt-in OFF: the source scene,
    the native scene (`IKKOKU_CAPTURE_STUDIO`) and the Maker source card;
  - one render of the source scene with the live opt-in ON (7 live draws, 0
    fallbacks), and its live report;
  - nine `IKKOKU_CAPTURE_UI` window captures: five Studio inspector tabs of
    the source scene (object, pose, face, clothes, scene), two of the native
    scene (object, pose), the Maker source card's rig panel and the native
    Body tab.

  Base `0c51ca1` (Release executable `3d4aeb00…dc864c`) against this change
  at `4ce5b3d` (`190d3525…c289bd`): all 13 PNGs and all 10 reports
  byte-identical, on the 4K display at 2×. The merged head `7a265f6`
  (`23b1d10e…a4a26c`) was compared after the display had become a 1080p
  virtual display at 1×, which changes the window captures' size, so base's
  window captures were taken again on it. The four renders and all 10
  reports match base byte for byte, and so do eight of the nine window
  captures. The source pose tab varies in both builds: its "Eye look" readout
  appears only when the inspector is re-evaluated after the preview first
  computed the eye rates. Three alternating launches per build gave both
  variants for each build (base: without, with, without; this change: with,
  with, without), so it is not a difference between them.

  Once the 4K display was back, base and the merged head were captured
  again at 2× (`captures/base-2x`, `captures/final-2x-b`). Eight of the nine
  window captures match each other and the first base set byte for byte,
  and the pose tab matches one of base's two variants. A first 2× set of the
  merged head, taken right after the display came back, differed in all nine
  windows only in control accent colors. The window was drawn as active
  there and inactive in every other set, and all nine reports matched.

  After `main` moved to `ad50c43` (#146), all 13 captures were taken with a
  Release build of `ad50c43` and of the PR head `008085c`, which merges it
  (`captures/main-ad50c43`, `captures/head-008085c`). All 13 reports and 12
  PNGs are identical. The pose tab again shows the two known variants, one
  per build. The `ad50c43` captures also match base `0c51ca1`.
- **Native-scene byte control.** `synthetic-current.png` with
  `IKKOKU_MAKER_LIBRARY=none` (see the control note under
  [quick wins](#quick-wins-in-this-change)): base and the merged head both
  give `6837cd63…`.
- **Thread lifetime.** `viewport-lifecycle` (three Studio/Maker switches,
  resize, minimize and restore, quit through `NSApp.terminate` while the link
  draws) ran three times on the Release build: one render thread before every
  step and at the end, all callbacks on the render thread, a clean exit.
  Those runs were on the virtual display, which presents nothing. In the
  measured window on the 4K display, after drew 411 frames and presented
  406 of them after the restore, all 1,046 callbacks were on the render
  thread, and the quit through `NSApp.terminate` exited cleanly. The harness
  build (main-thread link) presented 318 of 327 after the restore.
- **ThreadSanitizer.**
  - Engine: `swift test --sanitize=thread` with the renderer, frame-ring,
    capture-request, resource-store and character-lifetime tests (33 tests),
    on `7a265f6`: all pass, 0 warnings. #146, merged afterwards, changes no
    renderer or GPU file. The whole suite under
    ThreadSanitizer took more than 8 minutes on one thread and was stopped.
  - As a control, the new render-thread test caught a deliberately unlocked
    `publish(gpuTime:)`. It did not catch an unlocked `currentFrame()`,
    because the frame's array storage is retained and released atomically by
    both threads, which ThreadSanitizer counts as synchronization; the lock
    order is documented instead.
  - App: a Debug build with `-enableThreadSanitizer YES`, through the
    harness, ran `studio-native` and `viewport-lifecycle` once each. Three
    more `viewport-lifecycle` runs used a variant that created the link on the
    render thread. All had 0 ThreadSanitizer warnings, one render thread at
    the end and a clean quit. 2 of about 2,000 display-link callbacks arrived
    on the main thread, one with each variant, each shortly after the layer
    changed size (see
    [renderer threads](renderer.md#renderer-threads-r7-phase-2-item-2)). The
    harness counts them, and they are safe.
- **Engine suite** with every fixture of the shared map exported, on the
  PR head `008085c`: 756 tests passed (749 on `7a265f6`, before #146 added
  its tests), including 2 named skips
  (`sourceStudioExpressionPerformanceProbe`, opt-in, and
  `sourceCardAppearanceFemaleAndMalePixelsMatchIndependentRawRGBAOracle`,
  no `IKKOKU_APPEARANCE_REFERENCE_ROOT`), plus 21 in the second target.
- **Python.** Runner self-tests 185/185 (15 in `test_perf_trace.py`) and the
  studio-inspector validator tests pass.
- **Lanes**, Debug, `--strict` under the app lock, 0 skipped: on the PR head
  `008085c`, `studio-scenarios` 52/52 (1,699 s) and `maker-scenarios` 5/5;
  on `7a265f6`, the same (52/52 in 1,631 s, and 5/5).

### Limits

- **One run per build and workload**, plus the idle and hover repeats and
  three offscreen runs per build.
- **The load is synthetic.** A busy-wait on the main run loop stands in for
  slow SwiftUI updates and modal work. Presentation does not care what the
  main thread does, but the CPU-clock effect depends on how busy the
  machine is, so loaded draw times are not a prediction for real work.
- **CPU clocks are inferred**, not read: the harness has no frequency
  counters.
- **ThreadSanitizer** covered a filtered Engine set (33 tests) and Debug app
  sessions, not the whole Engine suite, which took more than 8 minutes
  single-threaded and was stopped. A missing lock around `currentFrame()` is
  not detectable by it (see [correctness](#correctness-1)).
- **One window.** The app replaces File → New, so a second window with a
  second render thread could not be tested.
- **No M1 run.**

### Recommended next

Item 3: take the live tick off the main thread and evaluate the characters
in parallel. Main-thread work no longer costs frames, but it still sets the
model rate and input latency. The 7.6–8.3 ms source-scene tick is the
largest main-thread cost left in idle and hover, and it is now slightly
slower while the draw runs beside it. Item 5, the asynchronous hover pick,
is the smaller follow-up: hover's pick takes about 2.6 ms per mouse move on
the main thread. Item 5 is now done
([phase 2, item 5](#phase-2-item-5-asynchronous-hover-pick)). Item 4 (skip unchanged frames) would now mostly save GPU
time and render-thread CPU, not main-thread time.

## Phase 2, item 3: live tick off the main thread

Done 2026-10-24, together with C2, C3 and C5 (inventory M1, C2, C3, C5).
The Studio's 30 Hz live step no longer evaluates the source characters on
the main thread. The main actor snapshots the step's inputs. Workers
evaluate the characters in parallel, one owner per preview. The main actor
then commits the result in the serial order and merges the frames. Inside
each character, three per-tick rebuilds became caches: the dynamics
topology, the bound pose and the expression weights. Every output is
bit-identical. The live-tick digest is unchanged over 180 ticks of 7
characters, both serial and parallel. Rendered frames and reports are
byte-identical. So are 8 of 9 window captures; the ninth differs only in a
readout that depends on startup timing in `main` too. The strict lanes
pass.

In the idle source scene, the main thread is busy 22 ms/s instead of
237–251 ms/s. A step costs the main thread 0.17–0.19 ms for the snapshot
plus 0.41–0.42 ms for the refresh that merges and submits, against an
8.0–8.3 ms tick before. The 7 characters run on workers in 0.93–0.97 ms of
wall time (p50). They take 5.6–5.8 ms of worker CPU per step when the
process is otherwise idle, and 2.75 ms with the main thread loaded (see
[CPU clocks](#why-orbit-took-the-slow-allocation-path-g4)). Presentation
stays at 120 FPS with an 8.33 ms p95 interval in every workload. FK drag's
refresh, which still evaluates on the main thread, fell from 1.83–1.97 to
1.27–1.29 ms per event through C2, C3 and C5.

### What changed

- **C2: dynamics topology per rig.** Before, each `SourceDynamicBone` step
  built a transform state for the whole rig: every node, the children lists
  and the world matrices. It then checked its output with a full
  `rig.evaluate`, and `SourceStudioDynamics` evaluated the rig once per
  component. Now:
  - Each component resolves its topology once per rig
    (`RigDefinition.identity`): the required slots in hierarchy order, the
    root particle's subtree, and the palette entries it moves.
  - A step transforms only those slots and skips `restPose`.
  - A step whose input is known to be valid checks only the nodes it
    changed. It uses the same checks, in the same order and with the same
    messages, as `rig.evaluate`.
  - `SourceStudioDynamics` evaluates the whole rig once per character.

  The float operations and their order are unchanged.
- **C3: the bound pose per (rig, record, kinematics).** `makePose` is split
  into `bindPose` (the controller, activations and transitions) and the
  application of that binding. The preview reuses the binding while three
  things stay the same: the rig, the effective kinematics, and the FK
  overrides, compared bit for bit. `applyingActivations` evaluates each
  distinct pose once.
- **C5: expression weights per input.** `SourceRigPreview.expressionWeights`
  keeps the last input's weights, keyed by the input's bit patterns. The
  weights are a pure function of the input for a preview's fixed source and
  contract, and a live tick asks for the same input until a blink or an
  edit changes it.
- **M1: the live step off the main thread.** `SourceStudioLiveTick.swift`
  (Engine) and `StudioModel`:
  - The timer's step snapshots its inputs on the main actor.
  - It evaluates every source character's blink, gaze, dynamics, wear, face
    state and frame in parallel, one worker per preview.
  - It joins in lease order. The refresh merges the frames in document
    order and submits them.

  The ownership rules, the settle points, the edit order and the behavior
  under load are in the
  [threading contract](renderer.md#studio-live-step-threads-r7-phase-2-item-3).
- **Harness.** New phases and events:
  - `studioLiveJob`: the job's wall time, from start to its last worker.
  - `studioLiveCPU`: the summed worker CPU time
    (`CLOCK_THREAD_CPUTIME_ID`).
  - `studioLiveWait`: main-thread time blocked on unfinished workers.
  - Events `studioLiveTickSkipped`, `studioLiveTickSerial` and
    `studioLiveTickDiscarded`.

  `summarize` prints a `live step` line from them. `studioTick` now covers
  only the timer's part: the snapshot and the job start. The completion's
  refresh is recorded as `studioRefresh`, as before.
- **Scenario.** The new `editDuringAdvance` op and the
  `studio-scenario-live-step-edit` check (studio lane, now 53 checks).

### Measurement

The commands follow [measuring a change](#measuring-a-change). Release builds,
arm64:

| Label | Commit | Executable SHA-256 |
| --- | --- | --- |
| base | `3dec1b2` (`main` with #147, before this change) | `d1813359…80d94490` |
| after | `ccf8858`: base plus C2, C3, C5 and the off-main step | `37f0c325…038102c81e2` |

Both builds predate #148 (item 5, the asynchronous hover pick), which `main`
merged after the measured window. The PR merges it. Base and after both pick
the hover synchronously, so the comparison stays valid. The two changes have
not been measured together.

All runs used the 4K display (M32UC) at 120 Hz and 2×, with a 1996×1824
drawable. Each run had a 3 s warmup and 10 s of recording, and every launch
took the app lock. The base runs ("before") were in a quiet window granted
earlier on 2026-10-24, at a load average of 3.0–4.7. The after runs were in
a second window, at 3.6–6.4. That window alternated after, base and after
per workload, so each workload has a base control run in the same window.
`summarize` flagged one run: the loaded idle run of after had 4 stray mouse
events. It was rerun, and only the rerun is cited. Reports are in
`.local/r7d-live-tick/{before,before-ctl,after-perf}`.

"Main tick" is `studioTick`, p50. For base it is the whole step, refresh
included. For after it is only the timer's part: the snapshot and the job
start. The step's own refresh is the "refresh" column.

| Workload | Build | Presented FPS | Hitches/s | Presented interval p95 ms | Main busy ms/s | Main tick ms p50 | Refresh ms p50 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| studio-idle | before | 119.8, 119.8 | 0.2, 0.2 | 8.33 | 240, 251 | 7.99, 8.34 | 4.48, 4.62 (inside the tick) |
| studio-idle | base, after's window | 119.8 | 0.2 | 8.33 | 237 | 8.03 | 4.41 (inside) |
| studio-idle | after | 119.9, 120.0 | 0.1, 0 | 8.33 | 22, 22 | 0.19, 0.17 | 0.41, 0.42 |
| studio-hover | before | 119.8, 119.9 | 0.2, 0.1 | 8.33 | 463, 508 | 7.90, 7.79 | 4.46, 4.30 (inside) |
| studio-hover | base, after's window | 120.0 | 0 | 8.33 | 563 | 6.50 (28 ticks/s) | 3.58 (inside) |
| studio-hover | after | 119.9, 119.9 | 0.1, 0.1 | 8.33 | 373, 412 | 0.16, 0.16 | 0.40, 0.41 |
| studio-fk-drag | before | 119.8, 120.0 | 0.2, 0 | 8.33 | 396, 384 | — | 1.97, 1.89 per event |
| studio-fk-drag | base, after's window | 120.0 | 0 | 8.33 | 379 | — | 1.83 |
| studio-fk-drag | after | 120.0, 120.0 | 0, 0 | 8.33 | 325, 325 | — | 1.27, 1.29 |
| studio-orbit | before | 119.6, 119.7 | 0.4, 0.3 | 8.33 | 20, 17 | — | camera 0.05 |
| studio-orbit | base, after's window | 119.3 | 0.7 | 8.33 | 22 | — | camera 0.05 |
| studio-orbit | after | 119.6, 119.9 | 0.4, 0.1 | 8.33 | 19, 15 | — | camera 0.05 |
| studio-native | before | 119.8, 119.6 | 0.2, 0.4 | 8.33 | 64, 57 | 1.79, 1.68 | inside |
| studio-native | base, after's window | 120.0 | 0 | 8.33 | 62 | 1.99 | inside |
| studio-native | after | 119.9, 119.8 | 0.1, 0.2 | 8.33 | 61, 60 | 1.98, 1.88 | inside (serial) |

The off-main step itself (`summarize`'s `live step` line):

| Workload | Job wall ms p50 / p95 | Worker CPU ms per step | Worker CPU ms/s | Main waits | Skipped, serial, re-evaluated |
| --- | --- | ---: | ---: | --- | --- |
| studio-idle | 0.97 / 1.69, 0.93 / 1.67 | 5.83, 5.58 | 175, 167 | 0 | 0, 0, 0 per s |
| studio-hover | 0.80 / 1.22, 0.80 / 0.93 | 4.90, 4.53 | 147, 136 | 0 | 0, 0, 0 per s |
| studio-native | — | — | — | — | 0, 30, 0 per s (no source previews: serial) |

**Busy main thread.** With `--main-load-ms 20` (about 600 ms/s of
busy-wait on the main run loop), in the second window:

| studio-idle + 20 ms × 30/s | Main busy ms/s (model) | Main tick ms p50 | Refresh ms p50 | Job wall ms p50 | Worker CPU ms per step | Draw ms p50 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| base | 773 (174) | 5.80 | 3.25 (inside) | — | — | 0.55 |
| after | 608 (9) | 0.10 | 0.20 | 0.48 | 2.75 | 0.52 |

Notes on the tables:

- **Main-thread time per step.** Idle: 8.0 ms → about 0.73 ms in all
  (22 ms/s at 30 steps/s: the snapshot, the commit, the refresh and the
  timer). That is 9% of a 120 Hz frame instead of 96%. Hover keeps 0.6 ms of
  step per tick; the rest of its 373–412 ms/s is the synchronous hover pick
  of these pre-#148 builds (2.8–3.4 ms per move at 120 moves/s), which
  item 5 removed.
- **Total CPU per step** (main plus workers): idle 8.0 ms → 6.3–6.6 ms
  (−20%). With the main thread loaded: 5.8 → 3.05 ms (−47%). The workers'
  CPU time depends on how busy the machine is: 5.6–5.8 ms per step when the
  process is otherwise idle, and 2.75 ms when the main thread is kept busy.
  That is the clock effect found in item 2 (see [G4](#why-orbit-took-the-slow-allocation-path-g4)).
  The 2.75 ms is close to the serial Engine test, which needs about 2.2 ms
  of non-hashing work per 7-character tick after C2, C3 and C5.
- **Wall time.** The 7 characters finish 0.93–0.97 ms (p50) after the
  timer fires, against 8.0 ms of serial tick. No step was skipped, no
  settle waited for a worker, and no step was re-evaluated in any run.
- **Draw CPU rose with idle clocks.** The render thread's draw took
  1.12–1.21 ms per frame in idle after, against 0.73 ms in base (151–168
  against 87 ms/s). With the main thread loaded, both builds draw in
  0.52–0.55 ms. The draw is unchanged code; the process simply became idle
  enough for the clock effect of item 2. GPU time is unchanged
  (2.08 ms p50 in both).
- **Native scene.** It has no source previews, so it keeps the serial step
  (30 serial events/s) and its numbers are unchanged.
- **FK drag** has no live step (the timer skips while a drag is active). Its
  gain is C2, C3 and C5 in the main-thread refresh: 1.83–1.97 → 1.27–1.29 ms
  per event (about −30 to −35%), and main busy time fell from 379–396 to
  325 ms/s.
- **Memory.** Peak footprint in idle: 755–756 MiB against 777–802 MiB.

**Per stage (C2, C3, C5).** The live-tick digest test
(`SourceStudioLiveTickTests.swift`) steps the 7-character scenario scene 180
times, serially on one thread, in the Studio's call order. Its blink draws
come from a fixed generator. The run also has a camera circling each
character, an FK edit on the first character from tick 40 to 99, a TARGET
neck pattern on two characters, and a seek at tick 120. It hashes the following into one SHA-256:

- every frame: items, model matrices, morph weights, material uniforms,
  skin palettes and bounds;
- the edited pose's local matrices;
- the eye-look rates and the blink flag.

`IKKOKU_LIVE_TICK_DIGEST` pins the result. It ran as
`swift test -c release`, with Time Profiler focused on its per-character
step (`liveTickStep`). The step is 1,260 character steps, and the times
below are summed over them. Both runs come from the same test binary, and
the hashing (`libcorecrypto`, 360 and 385 ms self time) is part of
`liveTickStep` in both:

| Stage | Before (ms) | After (ms) | Change |
| --- | ---: | ---: | --- |
| `liveTickStep`, whole step | 1,330 | 774 | −42% (hashing included) |
| `editedPose` | 739 | 227 | −69% |
| `SourceStudioDynamics.evaluate` (C2) | 358 | 75 | −79% |
| `SourceDynamicBone.step` (C2) | 322 | 72 | −78% |
| `DynamicsTransforms.init` (C2) | 181 | 16 | −91% |
| `DynamicsTransforms.pose` (C2) | 108 | 28 | −74% |
| `KoikatsuCharacterRecord.makePose` (C3) | 263 | 46 | −83% (now only the application of the cached binding) |
| `SourceStudioCharacterPreview.frame` | 504 | 143 | −72% |
| `SourceRigPreview.frame` | 141 | 63 | −55% |
| `SourceRigPreview.expressionWeights` (C5) | 95 | 0 (no sample) | −100% |

Without the hashing, the step went from about 970 to about 390 ms: 0.77 to
0.31 ms per character step. The test's own clock gave 7.41 → 5.84 ms per
tick with C2 alone, and 4.22 ms with C2, C3 and C5. Each of these steps is
for all 7 characters, hashing included. The digest stayed `1c3504a1…3e800f6f`
at every stage (`.local/r7d-live-tick/digest/digests.txt`).

### What remains

Time Profiler, 10 s per workload, after build (`.local/r7d-live-tick/after-tp`,
profile text only; the traces were deleted).

- **The workers: 186–194 ms/s in idle**, 6.2–6.5 ms per step under the
  profiler. Inside `SourceStudioLiveTick.step`:
  - The edited pose is 73% of the step (142 ms/s). The eye look's pose
    solve is most of that: `updateEyeLook` takes 115 ms/s, and the frame
    then reuses its pose.
  - `RigDefinition.evaluate` is 85 ms/s. Of that, 43 ms/s is building the
    skin palettes, and 37 ms/s is `isFiniteAffine`, the per-matrix
    validation.
  - The rest: the application of the bound pose (`makePose(binding:)`,
    41 ms/s), dynamics (39 ms/s, of which `SourceDynamicBone.step` is 37),
    `SourceStudioIK.apply` (30 ms/s), animation sampling (24 ms/s) and
    `SourceRigPreview.frame` (35 ms/s).

  None of this delays the main thread or presentation any more. It sets
  the CPU cost and how many characters a core budget fits.
- **The main thread in idle: 26 ms/s.**
  - The step's refresh is 15 ms/s: the merge, gizmos and `submit`.
  - The snapshot is 6.2 ms/s, of which 4.6 ms/s is `sourceWorldMatrix`
    for the frame requests and gazes.
- **FK drag: 161 ms/s of refresh on the main thread.** A drag event
  rebuilds every character's frame on the main actor (`frame` 95 ms/s,
  `SourceRigPreview.frame` 52 ms/s, `RigDefinition.evaluate` 44 ms/s), plus
  about 165 ms/s of SwiftUI. Only the dragged character's pose changes. The
  others hit their pose cache, but `SourceStudioCharacterPreview.frame`
  has no frame cache. Their rig evaluation, palettes and validation run
  again on every event.
- **The render thread: the draw at 120 Hz.** It takes 151–168 ms/s in idle
  at the idle clock speed. The frame content changes 30 times a second,
  and the draw runs 120 times (G3, P2: item 4).

### Behavior notes

- **Under load**, a timer fire is skipped while the previous step is still
  running or not yet refreshed. The clock then does not move, so the live
  animation slows instead of jumping, as with the serial step. No run
  skipped a step: the job's p95 wall time is 1.7 ms against a 33 ms period.
- **Native-only scenes**, and scenes whose gaze characters hang on
  attachment points or routes, keep the serial step. So does a scene
  looked through a camera on such a chain. A character whose frame hangs
  on such a chain is built on the main thread after the step.
- **Edits during a step** land after it ("step, then edit"). The rule is in
  the [threading contract](renderer.md#studio-live-step-threads-r7-phase-2-item-3).
- **The status line** reports gaze, wear, face and frame errors in the
  order the serial step wrote them.

### Correctness

- **Bit-identical output.** The live-tick digest (see "Per stage" under
  [Measurement](#measurement-2)) stayed `1c3504a1…3e800f6f` in Release in
  these runs: base `3dec1b2`, C2 alone, C2, C3 and C5, the parallel job, and
  the merged head `e69a3c0`.
  `sourceStudioParallelLiveTickMatchesTheSerialDigest` runs the same 180
  ticks through `SourceStudioLiveTickJob`, 7 leases per tick, and gives the
  serial digest. It also checks that a job refuses two leases of one
  preview. Floats differ between build configurations, so each
  configuration is compared with itself:
  - Debug: `e1c631e9…` on base `3dec1b2` and on the merged head, serial and
    parallel;
  - ThreadSanitizer: `c55c93aa…`, serial and parallel.

  Two mutation controls failed as expected:
  - without the `.normalized` on a world rotation in
    `DynamicsTransforms.updateNode`, the digest became `762f4989…`;
  - skipping the palette loop of the incremental check failed
    `sourceDynamicsValidatedStepThrowsExactlyWhenEvaluateWould`.
- **Edits during a step.**
  `sourceStudioEditDuringAParallelTickMatchesTheSerialOrder` runs 45 ticks
  with an FK edit after every third one. The parallel and serial orders
  give the same digest in every configuration (Release `911ea163…`, Debug
  `2431c6b9…`, ThreadSanitizer `6eeb7fae…`). An unchanged frame request gets
  the step's own frame back. In the app, `studio-scenario-live-step-edit`
  lands `move`, `setFK`, `undo` and `redo` while a step is in flight
  ([scenario](../../Tools/verification/README.md#edits-during-an-off-main-live-step-r7-phase-2-item-3)).
  Its mutation control is described there: when `FrameRequest.matches`
  ignored the world, 39,828 pixels differed and the refresh reused 7 of 7
  frames instead of 6.
- **Captures.** 15 captures per build, each its own launch under the app
  lock, with the shared fixture map:
  - the 13 of [item 2](#correctness-1);
  - two more `IKKOKU_AUTOCAPTURE` renders with the live opt-in ON: the
    native scene and the Maker source card. The opt-in is enabled in both,
    but neither has a source character to draw live. Their reports list 0
    characters and 0 live draws.

  `main` `b23383b` (Release `b0f6d47b…4fe2f0`) was compared with the merged
  head `e69a3c0` (`6b32224f…d59c9`). All 6 renders, all 12 reports and 8 of
  the 9 window captures are byte-identical (`.local/r7d-live-tick/captures`).

  The ninth window, the source pose tab, differs only in its "Eye look"
  section. That is the known variant of [item 2](#correctness-1). `main`
  showed the section in 3 of 3 launches, and this change in 0 of 3; the
  tab's report was identical in all six. Live steps never re-evaluate that
  readout, in either build. Diagnostic builds of both added timestamped
  prints and `Self._printChanges()`, and ran 2 launches each. Every launch
  showed the same order:
  - the inspector evaluated once, within 8 ms of appearing, before any eye
    rates existed;
  - the first live step came 0.17–0.20 s later;
  - nothing re-evaluated the inspector during the 11–13 steps before the
    capture.

  With the prints, `main` also captured the tab without the section. So
  the section shows only if the inspector's first evaluation comes after
  the first step: a race between the first timer fire and SwiftUI's first
  update. Item 2 saw both variants from both of its builds, and `main`
  `ad50c43` without the section. One diagnostic launch also drew the window
  as active, the accent-color variant of item 2.
- **ThreadSanitizer.**
  - Engine: `swift test --sanitize=thread --filter SourceStudioLiveTick`
    runs the 4 live-tick tests. Two of them run the 7 characters in
    parallel, for 180 and 45 ticks. All pass with 0 warnings, in 536.5 s on the final tests.
  - Engine control: the job's duplicate-preview guard was removed, and a
    temporary test ran two leases of one preview for 3 steps. That produced
    5 ThreadSanitizer reports, in the blink update and the eye-look solver.
  - App: a Debug build with `-enableThreadSanitizer YES` ran
    `studio-scenario-live-step-edit` through the runner. All 12 steps
    passed in 158.9 s, including 5 edits landed during off-main steps, with
    0 ThreadSanitizer reports.
- **Engine suite** with every fixture of the shared map exported, on the
  merged head. Two default parallel runs each passed 767 tests (266.3 and
  249.2 s), including the 2 named skips of item 2, plus 21 in the second
  target.
  Earlier, while the new fixture tests ran on the test pool, two parallel
  runs hung:
  - All 24 pool threads were blocked in MetalKit's synchronous texture load
    (`MTKTextureLoader newTextureWithCGImage` in `ResourceStore.texture`,
    which generates mipmaps into private storage). No thread was running
    anything else.
  - Three of the blocked threads were the new tests in the first run. In
    the second run, after they became a serialized suite, one was.
  - The same build passed with those tests skipped (764 in 100.5 s) and
    with `--no-parallel` (767 in 360.6 s).

  Each fixture test now loads and steps on a thread of its own, and the
  test awaits it, so it holds no pool thread. `ResourceStore` is unchanged.
  Other tests that build previews still block pool threads while they
  load, so more such tests could hang a parallel run the same way. The
  cause inside MetalKit was not established.
- **Python.** Runner self-tests 187/187 (16 in `test_perf_trace.py`), the
  studio-inspector validator tests (11), mod tools (40), translation (33,
  2 skipped), reverse tools (424, 6 skipped) and analysis (279) pass.
- **Lanes**, Debug, `--strict` under the app lock, 0 skipped, on the merged
  head `e69a3c0`: `studio-scenarios` 53/53 (1,284.2 s), with the new
  `studio-scenario-live-step-edit`, and `maker-scenarios` 5/5 (84.3 s).

### Limits

- **The measured builds predate #148.** The merged head was checked for
  correctness (digests, captures, lanes, ThreadSanitizer), not measured.
- **C2, C3 and C5 were not measured apart from the off-main step in the
  app.** Their separate effect is the per-stage profile of the Engine test
  and FK drag's refresh, which still runs on the main thread.
- **One or two runs per build and workload**, in two windows with load
  averages of 3.0–4.7 and 3.6–6.4. Each workload has a base control run in
  the after window.
- **Worker CPU time depends on the clock**, which the harness infers and
  does not read. Per-step CPU is 5.6–5.8 ms with the process idle and
  2.75 ms with the main thread loaded.
- **Not controlled:** which worker finishes first inside a step. The join
  is in lease order, and the Engine test compares the orders bit for bit.
- **ThreadSanitizer** covered the live-tick Engine tests and one Debug app
  session, not the whole Engine suite.
- **The live opt-in** draws live only in the source scene. The native and
  Maker renders with it ON have no live draws.
- **The parallel Engine suite** passed twice with the final tests.
  The pool-exhaustion hang it hit is not fixed at its source.
- **No M1 run.** On 8 cores, 7 characters fill the worker pool.

### Recommended next

Item 4: skip unchanged frames and lower the link rate (G3, G5, P2). The
render thread now draws 151–168 ms/s in idle, and the GPU renders 2.08 ms
frames 120 times a second, while the content changes 30 times a second.
That is now the largest per-frame cost in idle and hover. Smaller Engine
follow-ups:

- a frame cache for characters whose inputs did not change, for FK drag's
  161 ms/s of main-thread refresh;
- a cheaper `isFiniteAffine` (37 ms/s on the workers);
- C4, the eye-look pose solve (115 ms/s on the workers);
- in the Pose tab, the "Eye look" readout, which live steps do not refresh
  (in `main` too; see [correctness](#correctness-2)).

## Phase 2, item 5: asynchronous hover pick

Done 2026-10-24 (inventory M5). The Studio's gizmo hover no longer waits for
the GPU on the main thread. It picks asynchronously, only for the latest
mouse position, and drops results that no longer apply. Clicks, drag starts
and the scenario runner still pick synchronously. Both picks are now
scissored to the one pixel they read. Pick ids, rendered frames and window
captures are byte-identical.

In the `studio-hover` workload (120 mouse moves a second over the source
scene, with a character selected), the main thread was busy 239–242 ms/s,
against 518–531 ms/s before. The hover pick took 2.29–2.41 ms of the main
thread per move (279–296 ms/s). Now a move takes 0.01 ms to request a pick,
and applying a result takes under 0.01 ms (about 1.3 ms/s together). The
pick itself, 0.47 ms of CPU and 0.94 ms of GPU, runs on the renderer's pick
queue. Nearly all of what remains on the main thread in hover is the 30 Hz
live tick (7.8 ms, 234 ms/s), which item 3 addresses. Presentation was
already at 120 FPS since item 2, and it is unchanged. The scissor cut the
pick pass's GPU time from 0.13 to 0.06 ms per pick. The pick's deform pass
(0.85 ms) is now nearly all of its GPU time.

### What changed

- **Asynchronous hover pick.** `Renderer.pick(frame:pixel:size:completion:)`
  runs the pick on a serial pick queue (`com.grabbiel.Ikkoku.pick`) and calls
  back there with the id and the command buffer's GPU time.
  `StudioModel.mouseMoved` hands the position to a `LatestPickQueue`, which
  keeps at most one pick in flight. A move while one is in flight only
  waits, and a later move replaces it. A result applies only if it answers
  the latest move against the current frame and viewport size. Otherwise it
  is dropped, and the latest move is picked again against the current frame.
  `mouseDown` first settles the pick in flight, so a click sees the highlight
  of its last move. The contract, lock order and R6 rules are in
  [renderer threads](renderer.md#picks-r7-phase-2-item-5).
- **Scissored pick pass.** The pick pass is scissored to the pixel it reads,
  and only that pixel is copied back. It binds only the body mask texture,
  the one texture `pick_fragment` reads. The deform pass a pick runs first is
  unchanged.
- **Harness (schema 4).** Reports gain a `hoverPick` block (picks finished,
  applied and stale, their latency from start to the main actor and their
  GPU time), the `studioHoverPick` phase and two events (see
  [what the report records](#what-the-report-records)). `summarize` prints a
  hover line per report.
- **Scenario op.** `hoverGizmo` (in `fk-mouse-drag.json`) drives the real
  `mouseMoved` across the z ring of bone 19 and off it, settles the picks and
  checks the highlighted axis against the synchronous pick
  ([README](../../Tools/verification/README.md)).

### Measurement

The commands follow [measuring a change](#measuring-a-change). Release builds,
arm64:

| Label | Commit | Executable SHA-256 |
| --- | --- | --- |
| base | `3dec1b2` (`main` before this change) | `2733396e…569aebb` |
| after | `c905d8d` (this change; later commits change only a test and docs) | `9dad4909…942c4adb` |

All runs used the 120 Hz display at 2×, with a 1996×1824 drawable, in two
quiet windows the orchestrator granted on 2026-10-24 (base 07:14–07:18,
after 08:04–08:07). Every launch took the app lock, and the load average
was 3.7–5.3. Each run had a 3 s warmup and 10 s of recording, and hover ran
twice. One 5 s Time Profiler run and one 5 s Metal System Trace run of
hover were taken per build. `summarize` flagged no run. Reports are in
`.local/r7e-async-pick/perf/{base,after}`; the traces are archived in
`/Volumes/My Book/ikkoku-archive/local/r7e-async-pick/perf/` and symlinked
from `.local/r7e-async-pick/perf`.

| Workload | Build | Presented FPS | Hitches/s | Presented interval p95 ms | Main busy ms/s | Input events/s | Hover pick on the main thread, ms per move p50 (ms/s) |
| --- | --- | ---: | ---: | --- | ---: | ---: | --- |
| studio-hover | base | 120.0, 119.9 | 0, 0.1 | 8.33 | 518, 531 | 120, 119 | 2.29, 2.41 (279, 296) |
| studio-hover | after | 119.8, 120.0 | 0.2, 0 | 8.33 | 239, 242 | 120, 100 | 0.01 to request, < 0.01 to apply (1.4, 1.2) |
| studio-idle | base | 119.9 | 0.1 | 8.33 | 250 | 0 | — |
| studio-idle | after | 120.0 | 0 | 8.33 | 251 | 0 | — |
| studio-orbit | base | 119.3 | 0.7 | 8.33 | 18 | 120 | — |
| studio-orbit | after | 119.3 | 0.7 | 8.33 | 20 | 120 | — |

One pick, before and after (hover):

| | Base | After |
| --- | --- | --- |
| Main thread per move | 2.29–2.41 ms p50, the pick's CPU work and the wait for the GPU | 0.01 ms to request; applying a result takes < 0.01 ms p95 |
| CPU per pick (Time Profiler) | 0.57 ms, on the main thread (54.7 ms/s at 95 moves/s) | 0.47 ms, on the pick queue (56.1 ms/s at 120 picks/s) |
| GPU per pick (Metal System Trace, p50) | deform 0.848, pick pass 0.130 (vertex 0.053, fragment 0.077), copy 0.005 ms | deform 0.847, pick pass 0.062 (vertex 0.045, fragment 0.017), copy 0.005 ms |
| GPU per pick command buffer (harness, p50) | — | 0.94 ms |
| Picks per second | one per move | 100–147, re-picks included |
| From the start of a pick to its applied highlight | inside the move's handler | 1.86–2.16 ms p50, 2.07–9.66 ms p95 |

Notes on the tables:

- **The main thread no longer picks.** Hover's main busy time fell by
  279–289 ms/s, the pick's whole cost on the main thread. The live tick is
  unchanged (7.73–7.84 ms mean in base, 7.77–7.86 ms in after), and so are
  idle and orbit. Presentation was already decoupled from the main thread by
  item 2, so FPS, hitches and the presented-interval p95 do not change.
- **Stale results.** Run 1 dropped 532 of 1,466 results (36%), and run 2
  dropped 97 of 1,000. A result is stale when a newer move waited for it or
  when the frame changed while it was in flight. Each coalesced move makes
  at most one result stale (266 and 97), so at least 266 results in run 1
  (27 a second, about one per live tick) were dropped because the frame
  changed, and none in run 2. The workload's input timer and the 30 Hz tick
  timer both run on the main run loop, so their phase stays fixed within a
  launch. A likely explanation is that in run 1 the tick fired while a pick
  was in flight, and in run 2 it did not. Real mouse events have no fixed
  phase. Each stale result costs one more pick off the main thread: run 1
  ran 147 picks a second for 120 moves.
- **GPU.** The pick command buffers took 0.94 ms each, so 94–138 ms/s at
  100–147 picks a second, against about 118 ms/s in base (120 picks of
  0.98 ms). The frame's own GPU time stayed at 2.0 ms, and the GPU is not
  the limit on the reference machine ([G1](#metal)).
- **Input rate.** After's second hover run received 100 input events a
  second instead of 120: the workload's input timer missed fires. The base
  Time Profiler run also received only 95 a second, so this is not specific
  to this change; its cause was not established.
- **Latency.** A result waits for the main actor, so the 9.66 ms p95 of run
  1 is a result that arrived during a 7.8 ms tick. The synchronous pick
  blocked the handler instead, for 2.3 ms per move.

### What remains

Time Profiler, 5 s of hover, after build:

- **The main thread: the live tick.** 227 of the 232 ms/s of sampled
  main-thread CPU are in `StudioModel.stepLive`. The hover pick no longer
  shows on the main thread. Item 3 (in progress separately) moves the tick.
- **The pick queue: 56 ms/s of CPU** at 120 picks a second. Preparing the
  frame (`buildContext`) takes 0.30 ms of each 0.47 ms. Sorting the
  transparent items takes 0.06 ms of that, and the pick does not need the
  sort order except between equal depths. Encoding the pick pass and the
  deform pass takes the rest. A pick-only preparation is a **hypothesis**
  worth about 0.1–0.2 ms of pick-queue CPU per pick.
- **The pick's deform pass: 0.85 ms of GPU per pick.** Each pick deforms
  every character again, although the draw deformed the same frame. Reusing
  the draw's deformed vertex buffers would need the pick to prove that the
  frame it picks is the frame the draw deformed, and that those buffers
  have not been reused since. That is a **hypothesis** worth about 0.85 ms of
  GPU per pick, off the main thread.
- **Re-picks after a frame change** repeat that work. With real mouse input
  they should be rarer than in run 1 above (not measured).

### Behavior notes

- The highlight follows the last mouse position, as before. A result applies
  1.9–2.2 ms (p50) after its pick started, in a later turn of the main actor,
  instead of inside the move's handler. The next drawn frame shows it, as before.
- A click first waits for the hover pick in flight (at most one round trip,
  about 2 ms; two if the result is stale and the latest move is picked
  again), so a click or drag never starts with a highlight that is about to
  change.
- If the selection is cleared while a pick is in flight, the highlight keeps
  its axis. That gizmo is no longer drawn, so nothing shows it.
- A move that already has its answer is not picked again when the frame
  changes. The synchronous hover did not pick it again either, because it
  only picked on a move.

### Correctness

- **Pick ids.** `scissoredPickMatchesTheWholePickPassAtEveryTestedPixel`
  compares the scissored pick, synchronous and asynchronous, with the whole
  unscissored pass at 4,386 of 27,648 pixels. Those include every pixel where
  the id changes, and they show 11 distinct ids: the background, a skinned
  character, a quad masked through a mipmapped body mask, a transparent quad,
  translate-gizmo axes and plane handles, rotate rings and a bone handle
  ([tests](renderer.md#picks-r7-phase-2-item-5)). Moving the scissor one row
  down made the test fail. In the real scene, `fk-mouse-drag` scans pixels
  with the synchronous pick and found the same z-ring pixel `(227.63,
  393.38)`, id `4278190083`, and the same 58.066128° drag as a report from an
  earlier `main` build of 2026-10-23
  (`.local/r7e-async-pick/fk-mouse-drag-*.json`).
- **Stale results.** `staleAsynchronousPicksAreDroppedAndTheLatestMoveApplies`
  runs real asynchronous picks. A result for an axis pixel that arrives
  after the pointer moved to the background is dropped, and a result taken
  against an older frame leads to a re-pick against the new frame. Four pure
  tests cover the queue and the mailbox.
- **Scenario.** `hoverGizmo` in `fk-mouse-drag` drives the real `mouseMoved`
  with the source scene: 6 moves, 3 coalesced, 5 picks issued, 3 applied and
  2 stale. After each sequence, the highlighted axis (in the model and in the
  frame's highlighted gizmo batches) is the one the synchronous pick reads at
  the last position: z on the ring, none off it.
- **Captures.** The 13 captures of [item 2](#correctness-1) (four
  `IKKOKU_AUTOCAPTURE` renders, including the live opt-in, and nine
  `IKKOKU_CAPTURE_UI` windows), each its own launch under the app lock with
  the shared fixture map: all 13 PNGs and all 10 reports are byte-identical
  between base and after (`.local/r7e-async-pick/captures`, PNG hashes in
  `summary.json`).
- **Engine suite** with every fixture of the shared map exported: 762 tests
  passed, including the 2 named skips of item 2, plus 21 in the second
  target. In the first full run, the mailbox test timed out: it delivered
  through a global dispatch queue, which the parallel suite starved for
  about a minute. It now delivers from its own thread.
- **ThreadSanitizer.** `swift test --sanitize=thread --filter
  'PickTests|latestPickQueue|pickMailbox|renderThreadDraws'`: 7 tests pass
  with 0 warnings. The render-thread test now also requests 16 asynchronous
  picks. As a control, an unlocked write to `frameIndex` in the asynchronous
  pick produced 4 ThreadSanitizer warnings.
- **Python.** Runner self-tests 186/186 (16 in `test_perf_trace.py`), the
  studio-inspector validator tests (11), mod tools (40) and translation
  (33, 2 skipped) pass.
- **Lanes**, Debug, `--strict` under the app lock, 0 skipped:
  `studio-scenarios` 52/52 (1,730 s) and `maker-scenarios` 5/5.

### Limits

- **One run per build and workload**, plus the hover repeat.
- **No physical mouse.** The harness and the scenario drive `mouseMoved`
  from timers; the stale rate with real, unphased mouse events was not
  measured.
- **ThreadSanitizer** covered the pick and render-thread tests, not the
  whole Engine suite or an app session.
- **No M1 run.**

### Recommended next

This change does not start item 4. Item 3, the live tick off the main
thread, is in progress separately, and the tick is now nearly all of the
main thread's time in idle and hover. Item 3 is now done
([phase 2, item 3](#phase-2-item-3-live-tick-off-the-main-thread)). After it, item 4 (skip unchanged
frames) is the largest per-frame cost left: the render thread
draws 85–91 ms/s and the GPU renders 2.0 ms frames 120 times a second,
while the content changes 30 times a second. A smaller follow-up is to let
the pick reuse the draw's deformed buffers (0.85 ms of GPU per pick), which
item 4's frame identity would also make easier.

## Validation of this change

The historical suites and lanes below ran on the merged head `b20ccd7`
(`main` at `f5587f5` merged) unless stated. They are retained evidence from
the initial phase-1 work, not fresh runs from the resumed review. Reports are
under `.local/verification/app-perf` in the worktree and `.local/app-perf/lanes`.

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
- **App lanes**, each `--strict` under the app lock, using Debug for
  Studio, Maker and gameplay scenarios; app-smoke also includes Release checks:
  - `studio-scenarios`: 45 of 45 passed.
  - `app-smoke`: 5 of 7 passed. The two failures are `startup-mute-capture`
    ("Original plugin target does not bind uniquely") and
    `studio-inspector-validate` (nothing selected). They come from the
    fixture map, which gained `IKKOKU_SOURCE_PLUGIN_PROFILE` on 2026-10-23.
    That profile's target object does not bind in the map's
    `IKKOKU_SOURCE_SCENE`, so Studio plugin execution fails at startup.
    `main` `f5587f5`, built and run the same way, fails both checks
    identically (`.local/app-perf/lanes/main-f5587f5`).
  - `maker-scenarios`: 4 of 4 passed.
  - `gameplay-scenarios`: 1 of 1 passed. These last two results are
    recorded in `.local/app-perf/phase-c.log`. Its subsequent idle harness
    rerun had 67 stray input calls and remains excluded from frame-rate claims.

### Resumed phase-1 review (2026-10-23)

Merged `main` at `2f29e27` and reviewed each optimization's cache keys and
invalidation. The evaluated-pose cache now includes the explicit-animation
requirement, matching the solved-pose cache: a cached optional fallback cannot
hide a missing-animation error from a later explicit edit. Playback reset clears
both pose caches. The harness runner also removes an earlier report before each
launch, so exit zero without a new report cannot pass using stale measurements.

Integration with editable expressions also guards checkpoint restoration with
constant-time shape and neck revisions. Restoring dynamics retains the current
neck pattern and live gaze; shape changes reject checkpoints bound to the old
rest geometry before mutating state. Neck revision updates leave `solvedCache`
intact, preserving the once-per-tick animation/FK/IK solve.

Fresh validation, separate from the historical runs above:

- `swift test --package-path Packages/Engine --filter
  'sourceAnimation|sourceStudioPose|sourceStudioCharacterPreview|sourceStudioDynamics'`
  with private fixture variables exported: **33 passed, no skips**. Coverage
  includes shared clip bindings across reordered, smaller, missing and renamed
  rig nodes; current baselines and translation-only shear; blended sampling;
  duplicate-name depth-first lookup and Unicode byte equality; shape replacement
  at an unchanged elapsed time; explicit-animation errors through both caches;
  and pre-sampling before dynamics with checkpoint replay. The independent
  100-frame dynamics oracle's maximum world error was `2.4102368e-7`.
- Integration checkpoint review: **15 focused tests passed, no skips**, using
  the private expression, shape, hair and skirt fixtures. The new regressions
  failed before the fix and now verify retained neck edits/gaze at unchanged
  elapsed time and atomic refusal of a checkpoint from an earlier shape
  baseline; unchanged dynamics checkpoint replay still passes. The independent
  100-frame oracle remains at `2.4102368e-7` maximum world error. Command:
  `swift test --package-path Packages/Engine --filter
  'sourceStudioExpression(Checkpoint|EditRenders|PortsBlink)|sourceStudioCharacterPreview(Caches|ShapeChanges)|sourceStudioDynamics'`.
- `python3 -m unittest discover -s Tools/verification -p test_perf_trace.py`:
  **10 passed**, including refusal of stale output.
- `xcodebuild -project Ikkoku.xcodeproj -scheme IkkokuCreator
  -configuration Release -derivedDataPath .local/build-release
  -destination 'platform=macOS,arch=arm64' build`: **succeeded**.
- Fresh Release source-scene, rig-plus-card and native-scene PNGs, plus four
  live/orbit/FK scenario PNGs: **7 of 7 byte-identical** to the retained
  `main` `5e86b57` baseline in `.local/app-perf/captures-3`. All four launches
  exited zero under the app lock. These are fresh captures compared with
  historical baseline bytes; the fresh current-main comparison belongs to
  combined-branch integration validation.
- A full fixture-backed suite started during this review was stopped to avoid
  concurrent writes with another task's fixture suite; it is not counted as a
  passing run. Combined-branch validation is recorded below; the Studio lane
  had 47 checks at this phase-1 review point.

Fresh Release window measurements used the same six-character source scene
(SHA-256 `029f0b1d…`), 120 Hz display and 1996×1824 drawable as the original
baseline. Each standard workload recorded 10 seconds after a three-second
warmup (startup: two seconds without warmup). App launches held the shared
lock; other task builds/tests were paused. Load averages were recorded in each
report. None of the eight runs triggered the compositing or stray-input checks.
These are fresh samples, not replacements for the historical table.

| Workload | Presented FPS | Hitches/s | Tick ms p50/p95 × rate/s | Main busy ms/s |
| --- | ---: | ---: | --- | ---: |
| studio-idle | 119.7 | 0.3 | 8.06/8.46 ×30 | 349 |
| studio-orbit | 7.0 | 4.0 | — | 924 |
| studio-fk-drag | 25.3 | 25.2 | — | 995 |
| studio-hover | 117.5 | 2.5 | 7.71/8.07 ×30 | 614 |
| maker-idle | 119.4 | 0.6 | 1.98/2.63 ×30 | 177 |
| maker-slider | 43.7 | 28.6 | 0.45/0.53 ×30 | 999 |
| studio-native | 119.6 | 0.4 | 1.51/2.04 ×30 | 184 |

Startup imported the scene in 4.62 s and drew its first frame at 6.16 s.
The source idle tick remained at 30/s, with draw CPU 0.86/0.93 ms and GPU
1.89/2.04 ms (p50/p95). This preserves the phase-1 idle improvement; the
interactive cases still spend most main-thread time outside model work.

The unusually slow first orbit run prompted a bounded control using the retained
prior phase-1 Release executable (SHA-256 `6577f481…`), without rebuilding it.
All runs had identical scene hash, object count, window, drawable and configured
120 Hz input. Current runs presented **7.0, 22.0 and 35.3 FPS**; prior-binary
controls presented **44.7 and 34.1 FPS**. The final interleaved pair delivered
119.6 inputs/s in both builds; current model/other time was 103/868 ms/s versus
106/827 ms/s for the prior build. The earlier prior run delivered 113 inputs/s.
In the first slow run, refresh cost stayed 0.76–0.86 ms across one-second bins
while display callbacks had multi-second gaps; there was no growing model
phase cost in those samples. This small control does not isolate a consistent
code regression or its cause, and it does not establish an interactive
improvement. Keep the severe presentation stalls visible when evaluating the
phase-2 main-thread and SwiftUI work.

Private logs and executable/source provenance are in
`.local/codex-resume-2026-10-23/performance/` in the primary checkout.

## Combined integration acceptance (2026-10-23)

The performance, source-expression and selected-skirt branches are integrated
on `codex/continue-claude-2026-10-23`. The measured runtime is `dffc9df`; `83cb84b`
corrects only the skirt scenario's animation setup, and `c5822a8` adds a fixture
assertion without changing runtime code. Debug and Release app builds succeed.

### Fresh offscreen control

Fresh Release runs compare untouched `main` `2f29e27`, the retained
performance-only `a6b2016` executable, and the integrated app. These used the
same source scene (`029f0b1d…`), explicit fixture map, 512×512 render target,
60 render frames and 120 simulation samples per Studio launch on the M2 Ultra,
macOS 27.0.1, Xcode 27.0 / Swift 6.4. Other task builds, tests, apps and VM work
were paused, and launches held the shared app lock. This is a quiet task window,
not an otherwise idle operating system; each report retains load averages.

| Build | Studio characters / triangles | Runs | Simulation p50 / p95, ms |
| --- | --- | ---: | ---: |
| Main `2f29e27` | 6 / 285,016 | 3 | 22.502 / 23.240 |
| Performance-only `a6b2016` | 6 / 285,016 | 1 | 5.353 / 5.668 |
| Integrated `dffc9df` | 7 / 330,851 | 3 | 5.123 / 5.627 |

For three-run rows, the table gives the median of the per-run percentiles.
Baseline p50s were 22.505, 22.383 and 22.502 ms; integrated p50s were 4.874,
5.123 and 5.265 ms. The equal-output performance-only control reduces p50 by
**76.2% (4.2×)**, and all three native, Maker and Studio PNGs are byte-identical
to the fresh baseline. This control has only one repeat; it establishes the
large optimization without claiming a precise distribution or an interactive
frame-rate improvement.

The integrated native and Maker PNGs also match exactly. Its Studio image
changes because key 1299 now renders: the saved eye catalog row 30 maps to FBS
pattern 21. The old importer treated 30 as an FBS index and rejected the whole
character against a 28-pattern controller. The original-player reload preserves
row 30, and the new fixture assertion checks the mapping and unchanged reset.
The 29,689 changed Studio pixels therefore reflect additional character
coverage, not an equal-output comparison. Gag-eye objects/visibility remain
explicitly unsupported; this does not establish original eye appearance parity.
The integrated result is 77.2% below baseline despite rendering seven characters,
but use the six-character control to attribute the optimization.

Executable SHA-256 values:

- Main: `254525037c3420313e749d12b14776e57f9ac3d4dd77457fa68e647ba3a3ca03`
- Performance-only: `4b04f5744156869cb7ce9ef4613a8f1d9506aa6bd765d018587aefa453a04820`
- Integrated: `2f12010fca621804c2bb517660d51d1ae76fec051913155e954481ea69bbaf7e`

### New-feature cost and window behavior

Three quiet Release expression probes give steady frame medians
96.416/94.500/100.167 µs and edited frame medians 97.250/94.333/98.167 µs.
Expression edits take 1.458/1.416/1.459 µs; neck-pattern edits take
2.250/2.042/2.250 µs. These small samples show no material steady-frame penalty.
They measure the fixture preview, not UI event processing.

Selected skirt dynamics add measurable simulation work: on complete rigs with
FK disabled, all garment roots active, static upstream poses and 1/60 delta,
one character's hair-only p50/p95 is 0.453/0.508 ms versus 0.904/0.978 ms with
clothes. Seven characters give 2.000/2.201 ms versus 4.962/5.214 ms. Each mode
uses 20 warmups and 120 samples. These are isolated dynamics probes, distinct
from the scene benchmark above, whose default fixture map remains hair-only.

Final live-window runs use the seven-character integrated scene, a 120 Hz
display and 1996×1824 drawable, requesting 10 measurement seconds after three
warmup seconds (actual recorded durations: idle 10.425 s, orbit 10.053 s). The
reports pass the harness compositing/input validity checks.

| Workload | Presented FPS | Hitches/s | Tick p50/p95 × rate/s | Main busy ms/s |
| --- | ---: | ---: | --- | ---: |
| studio-idle | 119.8 | 0.2 | 7.45/7.88 ms ×30 | 342 |
| studio-orbit | 48.1 | 30.4 | No studio tick recorded | 991 |

Idle draw CPU is 0.95/1.06 ms and GPU is 2.06/2.18 ms. Orbit spends 866 ms/s
outside the measured model and draw work, with 1.08/1.24 ms input handlers at
74 events/s and GPU 1.50/1.96 ms. Main-thread/SwiftUI interaction remains the
phase-2 priority; neither this single orbit run nor the earlier variable controls
establish a resolved interaction bottleneck.

### Combined correctness evidence

- Full Release Engine/CoreMath suite: **736 executed and passed**, 0 failed,
  3 named skips (opt-in expression timing, opt-in card-edit output and absent
  appearance reference root). Expression timing subsequently passed separately.
- Python verification: **180 passed**; focused exporter, numerical oracle and
  original-reload tooling: **56 passed** with the private NumPy environment.
- Studio: the full Release lane passed **51/52**, exposing an unavailable
  animation in the new skirt fixture setup. Selecting converted T-pose
  `[0,0,0]`, explicitly declaring its catalog and freezing speed to zero fixes
  setup without relaxing assertions. The corrected save/load pair passed
  **2/2** (31 and 6 steps), so all **52 unique scenarios** have passing evidence.
- Source-expression scenarios pass **83/83**, **6/6** and **8/8** steps. The
  visible Face inspector also passes edit, Undo, Redo and Reset checks. Fresh
  original-export body bytes match the VM-accepted export; all **308/308**
  original-player serialized-field claims remain applicable.
- Maker app scenarios pass **4/4** and gameplay **1/1**. App-smoke retains the
  known startup-Mute fixture binding failure (target 10, no loaded scene).
  A concurrent DerivedData build collision was rerun alone successfully;
  it is not an unresolved build failure.

Post-review export correction for PR #135: expression-edited characters can now
export after a hidden native reload. Export prepares a temporary validation
preview when needed, honors blocked resources and source/outfit identity, and
never inserts it into the live cache. This changes only the explicit export
path; the timing and executable hashes above remain those of the measured
`dffc9df` runtime. The old app fails the regression at export; Debug and Release
builds of the fix pass, as do the expression scenarios. The final paired scenario
saves the character hidden and exports from a fresh process before checking both
original and native reloaded values (7/7 save, 16/16 load; edit rerun 83/83).
Evidence is in `integration/expression-hidden-*`
and `codex-expression-hidden-*.json` reports.

Private evidence is under `.local/codex-resume-2026-10-23/`: `baseline/captures/`,
`integration/{captures,performance-only-control,window-performance}/`,
`integration/{baseline-comparison,skirt-performance,microbenchmarks}.json` and
`expression/default-render-diagnosis.json`. The capture driver's `revision`
field records the orchestrating checkout; `label`, executable hash and the
provenance above identify retained binaries. Verification reports are
`.local/verification/reports/codex-integrated-{engine-release,studio-release,skirt-corrected,other-apps}.json`
and `codex-release-build-retry.json`. Initial failed skirt output remains in
`integration/skirt-initial/`. No private assets are committed.

## Limits of the historical profiling campaign

The following qualifications apply to the original campaign above. Fresh
combined runs have their own conditions and repeat counts in the preceding
section.

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
- **The Studio tick and refresh were inferred** from observed `StudioModel`
  properties in these runs, because `StudioModel.swift` was frozen for most
  of this work. Phase 2, item 9 replaced them with explicit hooks. In the
  same window, the two kinds of hook agree within about 10% (see
  [phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation)).
- **No M1 run.** The low-end column is an estimate from core counts,
  bandwidth and drawable size.
- **The drawable is not a full 4K frame.** It is 1996×1824 pixels, the
  window's viewport on a 4K display at scale 2. A full-screen viewport on
  that display has about 2.2× the pixels, which matters for GPU time only.
