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

TBD-SETUP

## Baseline

TBD-BASELINE

## Ranked costs

TBD-RANKED

## Quick wins in this change

TBD-QUICK

## Optimization inventory

TBD-INVENTORY

## Phase 2 plan

TBD-PLAN

## Limits of these numbers

TBD-LIMITS
