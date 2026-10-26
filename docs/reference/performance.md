# App performance: harness, baseline and ranked costs (R7)

Reviewed 2026-10-24. Owning task: the representative performance gap (R7) in
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
5. **Unchanged frames were rendered again at 120 Hz.** Phase 2, item 4 skips
   them (G3), lowers the display link to 30 and then 15 Hz while nothing
   changes (P2), and reuses deformed vertices that did not change. An idle
   keep-alive stops drag starts after a pause from dropping frames
   ([phase 2, item 4](#phase-2-item-4-adaptive-link-rate-idle-keep-alive-and-deformed-vertex-reuse)).
6. **Source characters were built on the main thread.** Importing the
   showoff scene stopped it for 4.6 s at startup, and so did an undo; a
   duplicate stopped it for 0.67 s. Phase 2, item 6 builds the characters in
   parallel off the main thread and decodes each rig file once per
   operation. The scene is ready 1.41 s after launch instead of 5.65 s, the
   first frame shows at 0.43 s, and a duplicate costs 45 ms of main-thread
   time ([phase 2, item 6](#phase-2-item-6-source-character-builds-off-the-main-thread)).
7. **A free-running timer started the live step.** The Studio's 30 Hz
   `Timer` kept whatever phase it had against the display. A step whose
   frame was submitted near a callback went to that callback or the next,
   so frames due 4 vsyncs apart came 3 and 5 apart, 0–15 times a second
   depending on the run. Live pacing starts each step from the Studio
   viewport's display link. Every step's frame now targets the callback
   it was paced for, and with a steady compositor the frames presented
   4 vsyncs apart except 0–0.3 times a second. CPU, GPU, idle cost and
   the app's part of a drag start stayed at parity
   ([live pacing](#phase-2-live-pacing)). The Maker's idle step is paced
   the same way ([Maker pacing](#maker-pacing)).

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
| `studio-idle` (default) | `IKKOKU_SOURCE_SCENE` | Studio, live animation on, nothing selected; blink, neck/eye look, hair dynamics and route clocks tick at 30 Hz. The scene needs one converted source character; a character riding a route counts (`details.sourceRouteCharacters`), so a route scene such as the route-children fixture measures a playing route |
| `studio-orbit` | same | `studio-idle` plus a right-button orbit drag: one `mouseDragged` per input tick |
| `studio-fk-drag` | same | selects source key 65, FK mode, bone 19 (the `fk-mouse-drag` scenario's grab), grabs the z ring found by `pickID` and drags it around a 40 px circle, one turn per 2 s; checks that the grab pushed exactly one undo snapshot |
| `studio-hover` | same | character selected, mouse moves over the viewport (`mouseMoved`, gizmo hover pick) |
| `maker-idle` | `IKKOKU_SOURCE_CARD` | Maker with the source card, idle animation, blink and hair |
| `maker-slider` | same | source customization on, the first bound body slider oscillates ±0.3 (one binding write per input tick) |
| `studio-native` | avatar, Maker library | New Scene, `IKKOKU_PERF_CHARACTERS` (default 6) native characters added with the Add menu's command, live animation |
| `viewport-lifecycle` | avatar, Maker library | `studio-native`'s scene, then every 0.5 s: three Studio/Maker switches (each replaces the viewport), a window resize to 0.7× and back, minimize for 1.5 s, restore, Studio, Maker. Before each step it counts the threads named `com.grabbiel.Ikkoku.viewport-render`. Before each step and at the end it also records the live-pacing hand-over: the mode, the viewports that render, which models have live work, which a display link paces, and each model's paced steps ([Maker pacing](#maker-pacing)). After the report it quits through `NSApp.terminate` while the link draws, instead of `exit` |
| `startup` | as `studio-idle` | no workload; the report's `startupSeconds` marks are the result |
| `studio-static` | as `studio-idle` | the source scene with live animation off and no input: nothing changes, so it measures what an idle viewport costs ([phase 2, item 4](#phase-2-item-4-adaptive-link-rate-idle-keep-alive-and-deformed-vertex-reuse)) |
| `studio-orbit-bursts` | as `studio-idle` | live animation off (on with `IKKOKU_PERF_BURST_LIVE=on`, so each drag starts during playback); repeatedly `IKKOKU_PERF_BURST_IDLE_MS` (default 1000) without input, then a 0.5 s right-button orbit drag. `details.burstInputEnds` records when each burst's first `mouseDragged` returned, so the summary measures every drag start after a pause |
| `studio-duplicate` | as `studio-idle` | live animation on; selects the source object `IKKOKU_PERF_ACTION_KEY` names (any kind, such as a route with its children), else source key 963 (or the first source character), then repeats Duplicate and Undo. Each action starts 0.5 s after the previous one was ready, and is timed from its call until no character build is pending and every preview it started is installed (`details.actions`, [phase 2, item 6](#phase-2-item-6-source-character-builds-off-the-main-thread)). Its frame rates are not cited: a build on the main thread stalls it for seconds |
| `studio-undo-delete` | as `studio-idle` | the same with Delete and Undo; the undo restores the character |
| `studio-timeline` | avatar, Maker library | `studio-native`'s scene with live animation on. The first character is keyed at 0 s and, moved 1 unit along x, at 2.5 s; then nothing is selected and the timeline plays from 0. It measures the timeline's step, which runs on the main thread ([live pacing](#phase-2-live-pacing)) |
| `studio-redo` | as `studio-idle` | as `studio-duplicate`, with Duplicate, Undo, Redo and Undo; the Redo of a route's Duplicate (`IKKOKU_PERF_ACTION_KEY`) rehydrates the scene's route runtime with its route characters |
| `studio-outfit` | as `studio-idle` | the Clothes tab's outfit picker (`StudioModel.selectSourceOutfit`) on the `studio-duplicate` character: another saved outfit (`IKKOKU_PERF_OUTFIT`, else the first other one), then the shown one back, repeated, live animation on. After the first selection each one borrows the outfit's kept assembly; `IKKOKU_PERF_DONATIONS=off` builds every one from its files |
| `studio-export` | as `studio-idle` | File ▸ Export Edited Original Scene (`AppState.exportSourceScene(to:)`), repeated, after a setup through the UI's calls: a cheek edit on the `studio-duplicate` character, Visible off, then Save Scene and Open of that file, so the hidden character has no preview and each export builds its validation baseline. Exports go to a temporary folder, removed at the end |
| `studio-load` | as `studio-idle` | File ▸ New Scene (unmeasured), then File ▸ Open (`AppState.openScene(at:importing:)`) of the source scene saved as an Ikkoku scene, repeated; each load builds the characters again and rehydrates the route characters (a load over the same scene would keep its runtime and rehydrate nothing) |

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
- Measurement controls for [phase 2, item 4](#phase-2-item-4-adaptive-link-rate-idle-keep-alive-and-deformed-vertex-reuse),
  all defaulting to the shipped behavior. Pass them with `perf_trace.py run --set NAME=VALUE`:
  - `IKKOKU_PERF_LINK_RATE=fixed` keeps the display link at full rate.
  - `IKKOKU_PERF_KEEPALIVE_MS` sets the idle keep-alive interval; 0 turns it off.
  - `IKKOKU_PERF_FRAME_SKIP=off` draws every callback, as before G3.
  - `IKKOKU_PERF_DEFORM_REUSE=off` dispatches every deformation in every frame and pick.
- `IKKOKU_PERF_LIVE_PACING=timer` starts the Studio's step from its 30 Hz
  timer instead of the display link, a measurement control for
  [live pacing](#phase-2-live-pacing); the default is `display`.
- `IKKOKU_PERF_ACTION_KEY` (a source key, 0 or more): the object
  action workloads (`studio-duplicate`, `studio-undo-delete`, `studio-redo`,
  `studio-outfit`, `studio-export`) act on, for example route 0 of
  `scene-route-children.png` with its folder and character. Without it they
  use source key 963 or the first source character.
- `IKKOKU_PERF_OUTFIT` (0–6): the saved outfit `studio-outfit` selects.
- Measurement controls for the
  [item 6 follow-up](#phase-2-item-6-follow-up-route-copies-prefetch-and-kept-donations),
  all defaulting to the shipped behavior:
  - `IKKOKU_PERF_RIG_PREFETCH=off` leaves each rig decode where its
    preparation asks for it, with no prefetch.
  - `IKKOKU_PERF_DONATIONS=off` keeps no donation of a dropped preview, so
    the undo of a delete builds from scratch.
  - `IKKOKU_PERF_INSTALL_REFRESH=each` refreshes the frame at every
    background install, as before, instead of leaving it to the next live
    step (`step`, the default).

### What the report records

[PerfTrace.swift](../../Apps/IkkokuCreator/PerfTrace.swift). The draw
samples are recorded on the thread that runs the display link, through a
locked `PerfDrawLog`. Everything else is recorded on the main thread.

- every `CAMetalDisplayLink` callback: callback time, target presentation time,
  `Renderer.draw` duration (frame preparation, deformation and pass encoding,
  plus any wait for one of the three frame slots), whether it rendered,
  intentionally kept the previous image, or failed, and whether it ran on the
  main thread. Since schema 5, GPU time (`gpuEndTime - gpuStartTime`) belongs
  to that exact draw's asynchronous completion; skipped callbacks do not repeat
  an older GPU sample. `drawThread` is `main`, `render` or `mixed`. Only
  main-thread callbacks count as main-thread draw time; render-thread draws
  are summed in `renderThread` (callbacks, draw ms/s);
- the frame ring's counters captured under the render lock for each encoded
  draw (`frameRing`), excluding unchanged callbacks: skin palettes and
  palette KiB per draw, palette buffers created while recording (0 once the
  ring is warm), and draws that used overflow buffers;
- when each drawable was really presented (`addPresentedHandler`), giving
  actual presented FPS and raw presented-interval percentiles. Schema 5 also
  reports `activePresentedIntervalMs`: adjacent presentation intervals minus
  only callbacks explicitly skipped as unchanged. Hitches use this adjusted
  cadence (longer than 1.5 refresh periods), with `skippedRefreshes` counting
  its lost periods. Adjustment is not actual FPS or latency: an earlier late
  presentation can shorten the next interval. `presentationLatenessMs` separately
  reports nonnegative target-to-present delay p50/p95/max. Out-of-target-order
  presentation pairs get no intentional-skip allowance;
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
  `studioReady`, `appStateReady`, `contentAppeared`, `firstDraw`,
  `sourceSceneReady`, when the startup scene's import committed (after the
  import call, or at a background import's commit), and `sourceMapReady`,
  when the scene's original map was first placed ([ST-A11](#st-a11-original-studio-maps));
- the main thread until the startup scene is ready (`startupMainThread`,
  [phase 2, item 6](#phase-2-item-6-source-character-builds-off-the-main-thread)):
  every busy period from `appStateInit` that began by `sourceSceneReady`,
  counted whole, with the launch before the run loop first waits as one
  period. The block holds their total, the longest, and how many exceeded 50
  and 100 ms. `summarize` prints it as a startup line;
- for the action workloads (`studio-duplicate`, `studio-undo-delete`,
  `studio-redo`, `studio-outfit`, `studio-export`, `studio-load`), each
  action (`details.actions`): its call time, the time until its builds were
  installed or its other background work finished
  (`PerfTrace.characterInstalled`, `backgroundWorkFinished`), the main
  thread's busy time and longest busy period from the call until then, and
  the status line and any error alert it left. `summarize` prints the
  medians per action and warns about an action that left an error;
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
hover events). Schema 5 adds rendered/unchanged/failed callback counts, exact
GPU completion counts and GPU ms/s, adjusted presentation cadence, absolute
presentation lateness and a successful-presentation count before recording.
`perf_trace.py summarize` prints actual draw rate and completed GPU work separately
from callback rate. Failed or pending GPU work is a warning. A completely static
recording is valid only if the last rendered warmup drawable presented by the
recording end, display callbacks continued and no sampled window occlusion was
recorded; a presentation from an earlier viewport is insufficient. Older schema
GPU values are sampled last-completion values; they cannot establish an exact
sum of command-buffer work.

Schema 6 (phase 2, item 4) adds:

- each callback's requested link rate (the frame rows' `linkHz` column) and a
  `linkRate` block: callbacks by requested rate, seconds at a lowered rate,
  lowerings and restores;
- keep-alive refreshes: `refreshedCallbacks`, `refreshedPresented` and the
  `refresh` and `refreshGpu` phases. The frame rows' `rendered` column is 2
  for a refresh;
- `deform.dispatches` and `deform.reuses` over the rendered callbacks;
- the measurement controls in `configuration`.

A refresh presents the same bytes again, so it is not a rendered frame:

- `renderedDraws`, the draw-time and `gpu` statistics and the frame-ring
  counters exclude it;
- `presentedFrames`, the presented-interval percentiles and
  `droppedDrawables` count only rendered callbacks' drawables, as before;
- for the skip-adjusted cadence and the hitch count, a refresh is a
  deliberate skip like an unchanged callback;
- at a lowered rate, an unchanged or refreshed callback's allowance is the gap
  to the next callback, up to one period of that rate, instead of one display
  period. `displayLinkTargetSkips` likewise leaves out the periods a lowered
  rate skips on purpose (`displayLinkDeliberateTargetSkips`).

So a refresh is never a hitch or a frame. Its cost is reported on its own.
A static recording may also prove composition with a presented refresh.

Schema 7 ([live pacing](#phase-2-live-pacing)) adds:

- each callback's deadline and the GPU's start and end times (the frame rows'
  `deadlineSeconds`, `gpuStartSeconds` and `gpuEndSeconds` columns);
- `samples.paces`, one row per paced step request: when it was asked and
  started, the target of the callback that asked, and the answer;
- a `pacing` summary: the policy, requests by answer (`ran`, `busy`,
  `idle`) and the request-to-start time;
- a `cadence` summary: histograms of presented intervals, target intervals
  and target-to-present lateness among rendered frames, in display periods.
  `perf_trace.py` prints them with the hitch rate and the request counts.
  The hitch count does not see a 3-vsync interval next to a 5, and these
  histograms do.

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
  - the window is still minimized;
  - a keep-alive refresh presented while the window was minimized
    (schema 6; there should be none).

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
| 7 | Full redraw of unchanged frames | 0.7 CPU + 2.1 GPU | 8% / 4% CPU; 25% of a 120 Hz frame on the GPU | 107 ms/s draw CPU in `studio-native`; 101 ms/s GPU in `studio-idle` at 49 frames/s | `ViewportNSView` display link → `Renderer.draw` | every display-link callback re-encodes and re-renders the frame, shadow map and deform pass included, even when nothing changed. Since [phase 2, item 2](#phase-2-item-2-render-thread-and-frame-ring-skin-palettes) the draw runs on the render thread, so this costs no main-thread time, and G4 cut its CPU encode from 0.74 to 0.44 ms per frame (offscreen) | G3 + P2; **done** in [phase 2, item 4](#phase-2-item-4-unchanged-interactive-frames-g3) and its [second part](#phase-2-item-4-adaptive-link-rate-idle-keep-alive-and-deformed-vertex-reuse) | G3: Studio idle draw CPU 117.7–143.1 → 42.4–46.4 ms/s, about 30 rendered frames/s instead of 120. Item 4: a static scene idles at 15 callbacks/s with a 1/15 s keep-alive (2.05 ms/s CPU, 0.72 ms/s GPU), and Studio idle GPU fell 57.9 → 36.5 ms/s with deformed-vertex reuse | low |
| 8 | Studio `refresh()` per orbit event | 0.89 | 11% / 5% | 68 ms/s | `StudioModel.refresh` | a camera-only change rebuilds every item (C6) | M3; **done** for orbit and pan drags in [phase 2, item 1](#phase-2-item-1-narrow-swiftui-invalidation) | measured: 1.00 ms full refresh → 0.04 ms camera rebuild per drag event | medium |
| 9 | Source scene load at startup | 4,710 (once) | — | — | `AppState.importSourceScenePreview` | synchronous on the main thread; in the probe, 74% of the load is rig JSON decoding, repeated per character (C8) | S1, S2, C8, S4; **done** in [phase 2, item 6](#phase-2-item-6-source-character-builds-off-the-main-thread) | measured: scene ready 5.65 → 1.41 s and first draw 5.93 → 0.43 s after launch; the main thread's import call 4,566 → 9.5 ms; the import's CPU 4.53 → 2.43 s (rig decodes 3.62 → 0.54 s) | low to medium |
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
  frames), deformed-vertex reuse (G9) and G7 (texture compression) worth more
  on the M1 than on the reference machine. G3 and G9 are done. G5 (shadow
  re-render) was dropped: it saves at most 0.14 ms per frame here, about 1 ms
  on an M1 by the same scaling, and nothing in a yaw orbit.
- **Startup and character builds ([phase 2, item 6](#phase-2-item-6-source-character-builds-off-the-main-thread)).** On the
  reference machine, the import's path is about 0.55 s of rig decodes in
  sequence, 0.15 s of parallel loads and 0.53 s of second halves one at a
  time. The estimate scales the sequential parts by 1.25× and spreads the
  0.76 s of parallel CPU over an M1's 6 workers (4 performance and 4
  efficiency cores). That gives:
  - the scene ready about 2 s after launch, with the window and first frame
    at about 0.5 s;
  - a duplicate appearing after about 0.15 s, and the undo after it after
    about 0.65 s.

  Base would stall the main thread for about 7 s at startup (0.9 s of Maker
  and 4.6 s of import), about 0.85 s for a duplicate and about 5.7 s for the
  undo. The GPU work inside the second halves (texture loads and mips) may
  scale worse on an M1's GPU; it was not measured. Until the Maker is first
  used, the startup footprint is about 130 MB lower, which helps on 8 GB.
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
| M6 | The Studio timer is a default-mode `Timer`; ticks skip while the timer handler is late and it does not fire during AppKit event tracking. Its phase against the display is arbitrary, so a step's frame lands on the callback before or after the one it is due for | `StudioModel.init`, `MakerModel` | measured; **done** | with the timer, frames due 4 vsyncs apart came 3 and 5 apart at 0–15/s, decided by the timer's phase ([attribution](#attribution)) | drive the live step from the display link. **Done** in [live pacing](#phase-2-live-pacing). The Studio viewport's link asks for each step (`LiveStepPacer`; every 4th callback at 120 Hz). Steps stay exactly 1/30 s, a busy step is still skipped, and steps still never run during event tracking. Every target interval was 4 vsyncs, at CPU, GPU and idle-cost parity. Lowering the link to 30 Hz during playback was measured and dropped. The Maker's idle step is paced the same way since R7h2. In its window every target interval of the eight idle runs was 4 vsyncs; with the timer, 0–2.2 a second were not ([Maker pacing](#maker-pacing)) | Medium: the scenario lanes rely on fixed 1/30 s steps; `advance` does not go through the link |
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
| C8 | Studio scene/character load decodes the same rig JSON once per character and component | `SourceMakerLibrary.prepare` → `SourceRig.load` | measured; **done** | probe load 6.1 s for 6 characters, 74% in `SourceRig.decode` (JSONDecoder) | cache decoded rigs by path, size and modification time; or a binary rig format. **Done** in [phase 2, item 6](#phase-2-item-6-source-character-builds-off-the-main-thread): `SourceRigDecodeShare` decodes each distinct file once per operation, keyed by its content (SHA-256 and byte count); the startup import's decodes went from 3.62 to 0.54 s of CPU. The [follow-up](#phase-2-item-6-follow-up-route-copies-prefetch-and-kept-donations) starts a batch's distinct decodes at once from the cards (first halves 690–726 → 464–515 ms, the showoff scene ready 0.23 s sooner) | Low for the cache |
| L1 | With the live source-shader opt-in ON, every `refresh()` maps each frame item back to its source renderer again (mesh-name parsing, a filter over all binding-set renderers per item, shader-name splits, report strings); the materials themselves are cached | `StudioModel+SourceShaderLive.swift` → `SourceShaderLiveAssembly.attach` | measured | 0.39 ms per refresh (11.6 ms/s at 30 Hz), 39% in `SourceShaderLiveMaterial.family(of:)` ([live opt-in](#the-live-source-shader-opt-in-127)) | cache the item-to-slot mapping per character while its meshes, visibility and wear are unchanged, and index the renderers by (mesh, submesh); most of the 0.39 ms (hypothesis until measured) | Low; the opt-in is OFF by default and its report must stay the same |

### Metal

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| G1 | GPU time is not the bottleneck on the reference machine | whole frame graph | measured | 1.3–1.9 ms GPU per frame at 1996×1824, 6 characters; draw encoding 0.6–0.9 ms CPU | — | — |
| G2 | MSAA color/depth, overlay depth and pick depth are already memoryless | `RenderTargets` | measured (code) | `storageMode = .memoryless` | — | — |
| G3 | Unchanged frames were fully re-rendered at the display rate, including deform and the 2048² shadow map | `Renderer.draw`, `ViewportRenderThread` | measured; **done** for interactive frames without visible live source materials | fresh Release source idle: about 120 → 30 actual draws/s; draw CPU 117.7–143.1 → 42.4–46.4 ms/s | skip complete interactive submissions using frame/resource/layer/size identity. [G3 evidence and limits](#phase-2-item-4-unchanged-interactive-frames-g3). Live source programs remain continuous. P2 is done and G5 dropped in the [rest of item 4](#phase-2-item-4-adaptive-link-rate-idle-keep-alive-and-deformed-vertex-reuse) | Low |
| G4 | Skin matrices are copied into a new `MTLBuffer` per skin set per frame and validated element by element | `Renderer.buildContext` | measured; **done** | 0.70 ms per draw in orbit, 122 buffers per draw in the source scene ([phase 2, item 1](#what-remains-on-the-main-thread)) | write skin matrices into the frame ring. **Done** in [phase 2, item 2](#phase-2-item-2-render-thread-and-frame-ring-skin-palettes): no palette buffer is created once the ring is warm, and the offscreen CPU encode fell from 0.74 to 0.44 ms per frame | Low; renderer file |
| G5 | Shadow map re-rendered every frame | `Renderer` shadow pass | measured; **dropped** | Metal System Trace of `studio-orbit` (base `aee4287`): shadow 17 ms/s, 0.14 ms per frame, against deform 102 ms/s, 0.85 ms per frame. The main light follows the camera's yaw (`MainLight.direction(camera:)`), so a yaw orbit changes the shadow, and FK drags and Maker edits move the casters | at most 0.14 ms per rendered frame, only for pan, zoom, hover or selection on a static pose. Dropped in [item 4](#phase-2-item-4-adaptive-link-rate-idle-keep-alive-and-deformed-vertex-reuse) for deformed-vertex reuse (G9) | Low |
| G9 | Every frame and pick re-dispatched the deform pass, even when the vertices were unchanged | `Renderer.encodeDeform` | measured; **done** | deform 102 ms/s in orbit (0.85 ms per frame), the largest GPU pass | skip a deformation whose buffer already holds the frame's inputs; **done** in [item 4](#phase-2-item-4-adaptive-link-rate-idle-keep-alive-and-deformed-vertex-reuse). Orbit GPU 1.40–1.52 → 0.65–0.66 ms per frame (0 dispatches), FK drag 1.95–1.99 → 1.19, Studio idle 1.98 → 1.21, hover pick 0.90–0.99 → 0.08 ms | Medium: buffers are read across command buffers; the [renderer contract](renderer.md#renderer-threads-r7-phase-2-item-2) orders them |
| G6 | No pipeline binary archive | `Pipelines` | hypothesis | pipeline creation happens during startup | `MTLBinaryArchive` for the production pipelines; measure first-launch versus warm | Low |
| G7 | Textures are uncompressed RGBA with runtime mip generation | `ResourceStore` (`MTKTextureLoader`, `.generateMipmaps`) | hypothesis; measured for maps | Metal allocation 470 MB peak for 6 characters. Original maps ship DXT1/DXT5 textures that the converter decodes: Map 33 takes 51.7 MB as RGBA8 with mips against 7.2 MB as BC (+52.5 MB of Metal measured), Map 34 would take 265.3 MB against 39.8 MB ([ST-A11](#st-a11-original-studio-maps)) | ASTC/BC compression at conversion time, cached mips; mostly memory and bandwidth (M1). For maps, keep the bundle's blocks and upload BC1/BC3 natively, which Map 34 needs first | Medium: image quality must be checked |
| G8 | Argument buffers / Metal 4 argument tables, indirect command buffers, residency sets, heaps, parallel encoding | renderer | hypothesis | draw encoding is ≤ 0.9 ms CPU per frame | low value until item counts grow (many-prop scenes) | — |

### Frame pacing

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| P1 | The display link runs on the main run loop, so every model or SwiftUI hitch is a presentation hitch | `ViewportNSView.viewDidMoveToWindow` | measured; **done** | idle baseline: 44.7 presented FPS, 150 hitches in 10 s while GPU and draw take < 3 ms | run the display link on a dedicated render thread; `Renderer` already snapshots the frame under `frameLock`. **Done** in [phase 2, item 2](#phase-2-item-2-render-thread-and-frame-ring-skin-palettes) (`ViewportRenderThread`) | Medium: renderer state touched from two threads (errors, statistics, pick); the [threading contract](renderer.md#renderer-threads-r7-phase-2-item-2) covers it |
| P2 | No `preferredFrameRateRange`; the link runs at 120 Hz while content changes at 30 Hz | `ViewportNSView` | measured; **done** | 120 callbacks/s when the main thread is free (`studio-native`, `maker-idle`) | 30 Hz after 0.5 s without change, 15 Hz after 3 s, full rate at once on input, a resize or a submit; with an idle keep-alive that fixes G3's drag-start drops. **Done** in [item 4](#phase-2-item-4-adaptive-link-rate-idle-keep-alive-and-deformed-vertex-reuse). Static idle: 15 callbacks/s, 2.05 ms/s CPU and 0.72 ms/s GPU (main: 120, 1.61 and 0); drag starts after 1 s and 3.5 s pauses drop nothing and show in 29.5 ms (main: 3–4 dropped, 56.3 and 63.1 ms) | Low |
| P3 | Drawable size is the full backing size (1996×1824 here; ~3.8 K × 2.1 K full-screen on a 4K display) | `ViewportNSView.updateDrawableSize` | hypothesis | — | an opt-in render scale for low-end machines | Quality trade-off, opt-in only |
| P4 | Three frame slots with `preferredFrameLatency = 2` | `GPUContext`, `ViewportNSView` | measured (code) | no frame-slot waits in the draw timings | — | — |

### Startup and scene load

| # | Item | Where | Status | Evidence | Fix and expected gain | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | Source scene import is synchronous on the main thread | `AppState.importSourceScenePreview` → `StudioModel.importSourceScenePreview` | measured; **done** | Release: 4.7 s import, first frame at 6.3 s; Debug 11.7 s / 20.0 s | load the characters concurrently off the main thread with a progress state; ~1–1.5 s on the reference machine. **Done** in [phase 2, item 6](#phase-2-item-6-source-character-builds-off-the-main-thread): first halves on workers, second halves in order on a build queue, one commit on the main actor; scene ready 5.65 → 1.41 s, first draw 5.93 → 0.43 s. Duplicates and undo/redo rebuild in the background too. The [follow-up](#phase-2-item-6-follow-up-route-copies-prefetch-and-kept-donations) adds route character copies (159 ms on the main thread → 2.4 ms call, 41 ms of main-thread work) and kept donations for the undo of a delete (992 → 351 ms); the showoff scene is ready at 1.04 s. The [third part](#phase-2-item-6-third-part-single-purpose-builds-rehydration-and-launch) builds an outfit selection, the export baselines and a rehydration's route characters in the background: their calls return in 0.4–17 ms instead of 85–463 ms. It also creates the audio bus on first use, so the first draw comes 0.10–0.12 s sooner | Medium: model mutations must stay on the main actor |
| S2 | Repeated rig JSON decoding | see C8 | measured; **done** | 74% of the probe load | cache; ~3 s of the 4.7 s. **Done** with C8: 3.62 → 0.54 s of decode CPU in the startup import | Low |
| S3 | Texture loading through `MTKTextureLoader` with runtime mips | `ResourceStore.texture` | measured; **GPU wait done**, uploads open | 7-character import, second halves (on the build queue): 51 ms over 19 texture loads; the material compositors' new command queues waited 173 ms for 1.6 ms of GPU work | asynchronous loading with placeholder textures. **The larger wait is done** in the [item 6 follow-up](#phase-2-item-6-follow-up-route-copies-prefetch-and-kept-donations): one compositor queue per device, 173 → 12 ms, second halves 520 → 342 ms, the showoff scene ready about 0.15 s sooner. The uploads stay synchronous; making them asynchronous saves at most 51 ms there and needs `ResourceStore` API changes. The [third part](#phase-2-item-6-third-part-single-purpose-builds-rehydration-and-launch) left them, since loading them concurrently would change the order in which the cache fills and needs new `ResourceStore` entry points | Medium |
| S4 | Maker library preparation at startup | `makerReady` mark | measured; **done** | ~0.9 s Release, ~4.1 s Debug | defer until first Maker use or load in the background. **Done** in [phase 2, item 6](#phase-2-item-6-source-character-builds-off-the-main-thread): a launch straight into a source scene creates the Maker on first use; `studioReady` 1.09 → 0.19 s | Low |
| S5 | An imported scene's original map loads with the scene (ST-A11) | `SourceStudioMapLoad` (`Packages/Engine/Sources/Studio/SourceStudioMap.swift`) | measured; **done** | Map 33: 73–83 ms of glTF reads, PNG decodes and MetalKit loads with mips; 0.01 ms placement and a 24 KB catalog read on the main thread | loaded on a GCD worker beside the character builds from the start, with private textures retired through `retire(textures:)`. Scene ready 1.47 → 1.45 s and main-thread time until ready unchanged ([ST-A11](#st-a11-original-studio-maps)) | Low |

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
| 4 | **Done.** G3 ([evidence](#phase-2-item-4-unchanged-interactive-frames-g3)) skips unchanged interactive submissions. The [second part](#phase-2-item-4-adaptive-link-rate-idle-keep-alive-and-deformed-vertex-reuse) adds P2 (30 Hz after 0.5 s, 15 Hz after 3 s), an idle keep-alive that removes G3's drag-start drops, and deformed-vertex reuse for draws and picks (G9). G5 was dropped | G3, G5, G9, P2 | ~3/4 of idle draw CPU and GPU | the biggest GPU item on M1: idle GPU at ~10 ms/frame becomes ~2.5 ms of every 8.3 ms | captures identical (nothing renders differently, frames are only skipped) |
| 5 | **Done** ([phase 2, item 5](#phase-2-item-5-asynchronous-hover-pick)). Asynchronous hover pick for the latest mouse position only, and a scissored pick pass. Measured: 2.29–2.41 → 0.01 ms per move on the main thread, hover's main busy time 518–531 → 239–242 ms/s, pick ids identical | M5 | 2 ms per mouse move off the main thread; fixes the hover hitch rise | same | gizmo hover scenarios |
| 6 | **Done** ([phase 2, item 6](#phase-2-item-6-source-character-builds-off-the-main-thread)). Startup: cache decoded rigs and load source characters concurrently off the main thread, with a progress state. Duplicates and undo/redo also build in the background. Measured: scene ready 5.65 → 1.41 s, first draw 5.93 → 0.43 s, a duplicate's 671 ms stall → 45 ms of main-thread work, and an undo's 4.58 s stall → 91 ms. The [follow-up](#phase-2-item-6-follow-up-route-copies-prefetch-and-kept-donations) and the [third part](#phase-2-item-6-third-part-single-purpose-builds-rehydration-and-launch) move route copies, outfit selections, export baselines and rehydrated route characters off the main thread; only a plugin attachment's parent still builds there | C8, S1, S2, S4 | source scene ready in ~1.5 s instead of 4.7 s; first frame earlier | larger, since there is less memory bandwidth for repeated decoding; estimated ready at ~2 s instead of ~7 s ([M1](#scaling-to-the-low-end-base-m1-8-gb)) | `startup` workload; scene import results identical |
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

At this stage, item 4 was next: skip unchanged frames and lower the link rate
(G3, G5, P2). G3 is now implemented [below](#phase-2-item-4-unchanged-interactive-frames-g3);
P2 and G5 remain. The historical render thread drew 151–168 ms/s in idle, and the GPU renders 2.08 ms
frames 120 times a second, while the content changes 30 times a second.
That is now the largest per-frame cost in idle and hover. Smaller Engine
follow-ups:

- a frame cache for characters whose inputs did not change, for FK drag's
  161 ms/s of main-thread refresh;
- a cheaper `isFiniteAffine` (37 ms/s on the workers);
- C4, the eye-look pose solve (115 ms/s on the workers);
- in the Pose tab, the "Eye look" readout, which live steps do not refresh
  (in `main` too; see [correctness](#correctness-2)).

## Phase 2, item 4: unchanged interactive frames (G3)

The G3 slice is implemented (2026-10-24, #150). In this slice the display link
still ran at 120 Hz. The [rest of item 4](#phase-2-item-4-adaptive-link-rate-idle-keep-alive-and-deformed-vertex-reuse) has since added the adaptive link
rate (P2), an idle keep-alive and deformed-vertex reuse for draws and picks, and
dropped cross-frame shadow reuse (G5). A submitted frame still runs
the complete pass graph. The renderer skips an interactive callback only when
its last encoded image has the same submission revision, resource generation,
drawable size and layer. Submission revisions are separate from `createdAt`,
which keeps its resource-retirement meaning. A new viewport thread, a layer
replacement, a size change or a callback gap over 250 ms forces rendering.

Resource registration/replacement/removal, hidden-mask changes and completed
retirements invalidate the image. Resources exposed by the store remain immutable
between those APIs. Failed preparation is never cached; a failed GPU completion
invalidates only its own cached submission. Captures, benchmarks and picks still
encode full graphs and do not establish an interactive cached image. Any visible
live source-shader material opts the whole frame out, preserving time-driven
programs without guessing which inputs a program uses. See the
[renderer contract](renderer.md#renderer-threads-r7-phase-2-item-2).

### Release comparison

Fresh clean `main` `72e7af6` and renderer code `0e201b1` were built in Release.
Their executable SHA-256 values are respectively
`5e4d1d9cd4143dd71eaba4df14cfdd8b4f26fed2a871b087c3d27ee5f7502fd2` and
`677aeb363f2700a8f851b23113a10866641a2c43b074e4abe0cc2cef7dd8b704`.
Private evidence is under `.local/codex-continue-2026-10-24/{baseline,renderer}`.
The shared Apple M2 Ultra was reserved for each measurement window: other owned
builds, tests and apps were stopped, and every app invocation held the app lock.
Each workload recorded 10 s after 3 s warmup, twice per build, at 120 Hz and
1996×1824 drawable pixels. The source scene has **7 characters**, 32 document
objects, and SHA-256
`029f0b1d248ba71158b08b8d237be14810819d411d62f529f77f3a612a8bea04`;
the native workload has 6 characters. Live source shaders were OFF for this table.

A fresh clean-baseline idle/orbit control was interleaved between candidate
repetitions. The baseline ranges below include those controls where available.
CPU totals include every callback, including the early-return checks. GPU baseline
values are **estimates from schema 4's sampled last completion**, while candidate
values sum each command buffer's actual asynchronous completion exactly once.
They are not an exact before/after GPU-total comparison.

| Workload | Draw CPU ms/s, baseline | Draw CPU ms/s, G3 | Actual G3 draws/s | Baseline GPU ms/s estimate | G3 completed GPU ms/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Studio idle | 117.7–143.1 | 42.4–46.4 | 30.0–30.1 | 248.2–256.1 | 62.0–62.3 |
| Native idle | 93.2–115.2 | 24.9–33.9 | 29.9 | 157.2–158.9 | 38.1–38.7 |
| Maker idle | 69.5–84.9 | 18.0–18.1 | 30.0 | 75.6–76.5 | 18.8–20.5 |
| Studio hover | 118.5–118.8 | 30.1–39.5 | 30.0 | 240.6–245.3 | 54.7–58.2 |
| Studio orbit | 134.0–184.9 | 118.1–130.4 | 118.9–119.2 | 188.2–195.5 | 192.2–192.4 |
| Studio FK drag | 92.6–95.1 | 91.3–93.3 | 119.5–119.9 | 245.9–249.1 | 244.0–253.7 |
| Maker slider | 26.2–26.4 | 26.2–26.4 | 119.7–119.8 | 73.9–74.2 | 74.0–74.3 |

All accepted reports continued at about 120 callbacks/s. Idle and hover now
render about 30 fresh images/s; the raw presented rate is therefore about 30,
not 120 FPS. Studio idle draw CPU fell by about 61–70% across the observed ranges.
FK drag and Maker slider stay effectively unchanged. Orbit's earlier baseline
was substantially slower than its interleaved control, so its full apparent CPU
difference cannot be attributed to G3. These measurements do not establish a
pacing or latency improvement.

The accepted Studio idle runs produced 300 and 301 model updates. Their model
interval p95 was 33.9–34.2 ms (max 34.3–56.4 ms), raw presentation interval p95
33.33–41.67 ms, skip-adjusted cadence p95 8.33–16.67 ms, and target-to-present
lateness p95 about 8.38 ms (max 8.40 ms). Dragging's raw and adjusted interval
p95 stayed at 8.33 ms. Across all accepted candidate workloads, lateness p95
ranged from 0.062 to 8.392 ms; its largest individual sample was 16.692 ms in
the native retry. Raw intervals and absolute lateness remain available alongside
adjusted cadence, which must not be interpreted as actual FPS.

All 14 accepted candidate reports and both interleaved controls pass the
presentation and stray-input checks. Candidate reports have no failed callbacks,
failed/pending GPU completions, sampled occlusion, palette-buffer creation or
frame-ring overflow. Two initial reports are retained but excluded: a native run
received 93 stray input events; a Studio idle run had a 1.23 s producer pause,
265 model updates and 265 rendered frames despite 1,201 callbacks. The latter
passed composition checks but changed the produced workload, so it was replaced
once and excluded from the table. Its cause is not established. A separate
live-source ON control rendered all 1,201 callbacks, with zero skips and 1,201
successful GPU completions; no G3 saving is claimed for that opt-in.

### Correctness and limits

Six controlled 960×880 Release PNG pairs are byte-identical against the exact
clean-baseline executable: source Studio, native Studio and imported-card Maker,
with the live-source opt-in OFF and ON. The ON Studio report records 7 live
draws; the native and Maker paths have no live draws, so those pairs do not
extend live-program coverage. The captures exercise complete offscreen graphs;
the interactive skip path is covered separately below. The private
`capture-summary.json` records input, executable and PNG hashes for all 12
launches.

- The real `CAMetalLayer` tests prove an unchanged callback leaves a fresh
  drawable untouched and a forced interactive redraw is byte-identical. They
  exercise same-timestamp resubmission, camera/light/morph edits, resource and
  mask mutations, resize, layer replacement, resume gaps, completed retirement,
  capture/pick/benchmark interleaving, live-material opt-out, and failed-prepare
  retry. The latter intentionally fails preparation, then proves the same
  submission renders successfully instead of being mistaken for unchanged.
- The final focused ThreadSanitizer run passed **8 tests**, including concurrent
  submit/draw/pick/capture/retirement and late/out-of-target-order presentation
  samples, with no race warnings. The fixture-backed Engine suite reported **773 tests, 2 skips**, plus **21 CoreMath tests**, with
  no failures. That broad run preceded the small internal failure-injection
  wrapper; the final focused TSan run covers the wrapper. The named skips were
  the optional independent appearance-reference root and opt-in expression
  performance probe. `IKKOKU_REQUIRE_SOURCE_FIXTURES` was not enabled.
- All **189 verification Python tests** pass, including actual-submission versus
  callback accounting, pending/failed GPU work, and static-report validity.
  The final Release build passes.
- Integrated app scenarios, visible UI and lifecycle acceptance are recorded
  separately on the combined PR. These branch measurements do not cover P2,
  cross-frame shadows/deform reuse, full-screen 4K, low-end M1 hardware,
  many-prop scaling or long-running memory growth.

## Phase 2, item 4: adaptive link rate, idle keep-alive and deformed-vertex reuse

The second part of item 4 (2026-10-25) completes it. The contract is in the
renderer reference: [adaptive link rate, idle keep-alive and deformed-vertex
reuse](renderer.md#renderer-threads-r7-phase-2-item-2).

- **Adaptive link rate (P2).** A viewport's display link asks for 30 Hz after
  0.5 s in which nothing changed, and for 15 Hz after 3 s. Input, a resize or
  a submit returns it to full rate at once.
- **Idle keep-alive.** G3 left an idle viewport presenting nothing, and the
  first frames of a drag after a pause then never reached the screen. An idle
  viewport whose window is visible now presents its last image again every
  1/15 s, with one blit and no frame encoded. While the window is occluded,
  minimizing or minimized, nothing is refreshed and the link idles at 15 Hz.
- **Deformed-vertex reuse (G9).** Interactive draws and both picks skip the
  deform dispatch for a deformation whose buffer already holds the frame's
  inputs. Captures, benchmarks and the live captures still dispatch every one.
- **G5 is dropped** ([below](#why-g5-was-dropped)).

Captures stay byte-identical. The harness's measurement controls
(`IKKOKU_PERF_LINK_RATE=fixed`, `IKKOKU_PERF_KEEPALIVE_MS=0`,
`IKKOKU_PERF_FRAME_SKIP=off`, `IKKOKU_PERF_DEFORM_REUSE=off`) bring back the
earlier behavior in the same binary.

### Drag starts after a pause

G3 changed what a drag after a pause looks like. `studio-orbit-bursts` turns
live animation off, so nothing changes between drags. Each burst is a pause
without input, then a 0.5 s orbit drag. The latency of a drag start runs from
the return of its first `mouseDragged` handler to the first rendered frame
that is presented. A dropped frame is a rendered frame of the new drag, before
that one, whose drawable was never shown.

These runs used this branch's Release build with main's behavior: a fixed
120 Hz link and no keep-alive. Each recording took 8 s and left out its first
drag, which follows the warmup.

| Pause | Time since the last present, ms | Drag starts | Dropped frames per start | First presented frame, ms: median (range) |
| ---: | --- | ---: | --- | --- |
| 33 ms | 1–10 | 14 | 0 | 32.2 (32.1–32.3) |
| 66 ms | 34–43 | 14 | 0 | 32.2 (32.1–32.7) |
| 100 ms | 76 | 13 | 0 | 32.1 (31.9–32.2) |
| 150 ms | 118–127 | 12 | 0 | 32.1 (31.8–32.4) |
| 200 ms | 168–176 | 11 | 2–3 | 57.2 (31.8–57.3) |
| 300 ms | 268–276 | 9 | 2–3 | 32.2 (32.2–57.2) |
| 500 ms | 468–477 | 7 | 2–3 | 32.1 (31.8–57.1) |
| 1 s | 972–981 | 4 | 3–4 | 52.9 (52.4–61.3) |
| 3 s | 2,970 | 1 | 4 | 71.8 |
| 3 s, every callback drawn (`IKKOKU_PERF_FRAME_SKIP=off`) | 6 | 1 | 0 | 27.7 |

- Up to 127 ms without a present, a drag start dropped nothing and showed
  after 32 ms.
- From 168 ms without a present, it dropped the first 2–4 rendered frames
  every time: those drawables were never shown. The first image came after
  32–72 ms, and after 52–72 ms from a 1 s pause on.
- The threshold lies between 127 and 168 ms. Its cause is outside the app
  and is not established.
- Drawing every callback, as before G3, has no idle gap and drops nothing.

The keep-alive keeps that gap short without rendering. Its interval was
chosen from the same workload with 3 s pauses and an adaptive link whose
slowest tier was then 10 Hz. One drag start per recording:

| Keep-alive interval | Time since the last present, ms | Dropped frames | First presented frame, ms |
| --- | ---: | ---: | ---: |
| 50 ms (100 ms at the 10 Hz tier) | 61 | 0 | 30.5 |
| 100 ms | 62 | 0 | 30.0 |
| 150 ms | 29 | 0 | 38.1 |
| 200 ms | 163 | 1 | 45.6 |
| off | 2,970 | 4 | 63.0 |

The interval is 1/15 s. A refresh is sometimes not shown either. In the second window's burst runs,
6 of 225 and 8 of 313 refreshes were not presented. 10 of those 14 came 8 ms
before the first rendered frame of a drag, which replaced them. All 151
refreshes of each static run were presented.
After one of those, the gap is 133 ms, still under the threshold. The slowest
tier became 15 Hz, so a callback comes once per interval at every rate (a
test pins this).

### Before and after

The machine was reserved for each window, and every launch held the app lock.
All builds were Release, with the fixtures, warmup and recording length of the
`before` set: 10 s after 3 s, or 24 s for the burst runs.

- **Base** is `aee4287` (executable SHA-256 `e1e21fd4…`). The `before` set
  was recorded in its own window, and the later windows ran base again as a
  control.
- **Second window** (06:59–07:11) measured `6e28cb6` (`abce3eae…`), the keyed,
  strongly held tracker. It ran the standard set twice, the burst and static
  runs, and reuse off in the same binary. It also had controls of base and of
  the first, weakly held tracker (`2e84b52a…`).
- **Third window** (07:55–07:57) measured the final change `d940390`, with
  `main` `d6b61a2` merged (`5f302118…`). It ran against base in ABBA order on
  Maker slider and FK drag.

#### Idle cost

`studio-static` is the source scene with live animation off, so nothing
changes. Second window:

| Policy | Callbacks/s | Render-thread CPU ms/s | GPU ms/s | Keep-alive refreshes/s |
| --- | ---: | ---: | --- | --- |
| This change: adaptive link and keep-alive | 15.1 | 2.05 | 0.72 (refreshes only) | 15.0, all 151 presented |
| `main`: 120 Hz, no keep-alive | 120.0 | 1.61 | 0 | 0 |
| Adaptive link without the keep-alive | 15.2 | 0.20 | 0 | 0 |
| Every callback drawn, as before G3 | 120.0 | 200.52 | 242.13 | 0 |

- **CPU.** The new idle costs 0.44 ms/s more render-thread CPU than `main`.
  A refresh takes 0.125 ms of CPU at p50, against 0.012 ms for an unchanged
  callback, and there are 15 a second instead of 120.
- **GPU.** A refresh's blit costs 0.035 ms of GPU at p50, 0.72 ms/s in all.
  `main` used none.
- **First window.** It measured the same idle at 2.52 ms/s CPU and 0.84 ms/s
  GPU, against 1.94 ms/s and 0 for `main`.
- **Not visible.** While the window is occluded or minimized, the keep-alive
  is off and the link stays at 15 Hz. That idle is the
  without-keep-alive row: 0.20 ms/s.

#### Drag starts after a pause

`studio-orbit-bursts` in the second window, leaving out the first drag of each
recording:

| Policy | Pause | Drag starts | Dropped frames per start | First presented frame, ms: median (range) | Time since the last present, ms | Render-thread CPU ms/s | GPU ms/s, rendered + refresh |
| --- | ---: | ---: | --- | --- | --- | ---: | --- |
| This change | 1 s | 15 | 0 | 29.5 (28.8–37.9) | 61–63 | 70.5 | 33.2 + 0.40 |
| `main` | 1 s | 15 | 3–4 (49 in all) | 56.3 (51.3–74.4) | 968–984 | 57.9 | 67.2 |
| Every callback drawn | 1 s | 15 | 0 | 29.0 (27.8–37.5) | 3–6 | 191.3 | 206.2 |
| This change | 3.5 s | 5 | 0 | 29.5 (28.6–30.1) | 54–63 | 26.5 | 12.2 + 0.72 |
| `main` | 3.5 s | 5 | 4 (20 in all) | 63.1 (62.5–72.7) | 3,469–3,479 | 25.4 | 25.8 |
| Every callback drawn | 3.5 s | 5 | 0 | 30.0 (29.5–37.7) | 3–5 | 211.1 | 208.9 |

- No drag start dropped a frame. The first image of a drag now shows about
  29 ms after the input, as when every callback was drawn. With `main`'s
  behavior it showed 51–74 ms after the input.
- The first window gave the same result: 0 drops, with the first image at
  29.4 ms (1 s pauses) and 29.2 ms (3.5 s pauses). With `main`'s behavior it
  dropped 50 and 20 frames, and the first image came at 55.2 and 62.9 ms.
- **Render-thread CPU per rendered frame was higher in the 1 s bursts.** It
  was 70.5 against 57.9 ms/s for about the same number of frames.
  - The difference lies in the first 15 frames of each drag. Their median
    draw times, position by position, were 1.3–2.8 ms, against 1.4–1.7 ms
    with `main`'s behavior. Later frames of the same
    drags took 1.46–1.53 ms, against 1.42–1.43 ms.
  - Steady drags show no such cost: in the standard set, orbit frames take
    the same time as base, below.
  - The likely cause is the CPU clock after a pause at 30 or 15 callbacks a
    second instead of 120. The harness infers clocks and does not read them,
    so this is not established.
  - Presentation did not suffer: the first image came at the same time as
    with every callback drawn, and the presented interval p95 stayed
    8.33 ms.

#### Standard set

`before` window against the second window, two runs each:

| Workload | Rendered frames/s | Render-thread CPU ms/s, before → after | GPU ms/s, before → after | GPU ms per frame, p50 | Deform dispatches/s, after (before: 115 or 20 per rendered frame) |
| --- | ---: | --- | --- | --- | ---: |
| Studio idle | 30 | 59.3–61.9 → 54.5–57.7 | 57.9 → 36.5–36.6 | 1.98–1.99 → 1.21 | 70 |
| Studio hover | 30 | 45.3–51.5 → 44.6–45.8 | 54.4–56.5 → 34.4–35.3 | 1.82–1.83 → 1.14–1.19 | 1–52 |
| Studio orbit | 120 | see below | 173.5–186.8 → 86.1–87.5 | 1.40–1.52 → 0.65–0.66 | 0 |
| Studio FK drag | 120 | 96.9–97.5 → 94.2–95.7 | 235.8–237.2 → 143.2–143.8 | 1.95–1.99 → 1.19 | 481 |
| Native Studio idle | 30 | 36.4–37.1 → 35.1–36.0 | 36.8–37.1 → 38.1 | 1.26 → 1.27 | 1,889 |
| Maker idle | 30 | 25.8–26.3 → 25.8–26.4 | 18.5–18.6 → 18.8–19.1 | 0.62 → 0.62–0.63 | 600 |
| Maker slider | 120 | see below | 70.0–71.4 → 70.7–70.9 | 0.58–0.60 → 0.59 | 2,398 |

- **Callbacks and frame rate.** Every workload still called back 120 times a
  second and rendered at the same rate. Its frames change at least every
  33 ms, so the link stayed at full rate.
- **Studio idle and hover.** Their frames reuse 113 of 115 deformations,
  because the live tick moves few of them. Their GPU time fell by 37–38%.
- **Hover picks.** The pick's GPU time fell from 0.90–0.99 ms to
  0.075–0.079 ms at p50 (126–150 picks a second). It used to be nearly all
  deform pass.
- **Native Studio, Maker idle and the slider.** These change every
  deformation in every frame, so they reuse nothing and are unchanged.
- **Deform passes.** On base, every rendered frame and every pick runs a
  deform pass with every deformation. The counts below are from the final
  build `d940390`: unmeasured 10 s runs outside the windows, and the third
  window for FK drag and the slider. Picks are not in them; the pick's GPU
  time above shows that it reuses.

| Workload | Rendered frames | Frames with a deform pass | Dispatches | Reused | Untracked dispatches |
| --- | ---: | ---: | ---: | ---: | ---: |
| Studio orbit | 1,193 | 1 | 3 | 137,192 | 0 |
| Studio FK drag | 1,197–1,199 | 1,197–1,199 | 4,803–4,811 | 132,852–133,074 | 0 |
| Studio hover | 300 | 27 | 71 | 34,429 | 0 |
| Studio idle | 300 | 300 | 700 | 33,800 | 0 |
| Native Studio idle | 300 | 300 | 18,900 | 0 | 17,136 |
| Maker idle | 300 | 300 | 6,000 | 0 | 5,400 |
| Maker slider | 1,199–1,200 | 1,199–1,200 | 23,980–24,000 | 0 | 21,700–21,720 |

Per second, deform passes went from 120 to 0.1 in orbit (the first frame
only), from 30 plus 126–150 picks to 2.7 in hover, and stayed at 30 in idle
and 120 in FK drag, with 2.3 and 4 dispatches per pass instead of 115. The
native scene, Maker idle and the slider still dispatch every deformation;
about 90% of those dispatches ran untracked.

#### Render-thread CPU per frame, in one window

The coordinator required the per-frame CPU result to come from one window.

Second window, with the first, weakly held tracker as a control. Each cell
gives render-thread CPU in ms/s, draw ms at p50 and GPU ms per frame at p50:

| Workload | Base `aee4287` | Weak tracker | Keyed tracker `6e28cb6` | `6e28cb6`, reuse off |
| --- | --- | --- | --- | --- |
| Studio orbit | 191.8 / 1.40 / 1.49 | 221.5 / 1.74 / 0.70 | 190.0–190.8 / 1.36–1.41 / 0.65–0.66 | 224.1 / 1.63 / 1.52 |
| Studio FK drag | 98.1 / 0.81 / 1.92 | 109.6 / 0.93 / 1.18 | 94.2–95.7 / 0.79 / 1.19 | 102.3 / 0.85 / 1.89 |
| Maker slider | 25.9 / 0.211 / 0.59 | 29.6 / 0.242 / 0.58 | 27.2–28.1 / 0.223–0.227 / 0.59 | 26.9 / 0.220 / 0.60 |

Third window, final change against base, in ABBA order. Each cell gives
render-thread CPU in ms/s, draw ms at p50 and GPU ms/s:

| Workload | Base | Final | Final | Base |
| --- | --- | --- | --- | --- |
| Maker slider | 30.0 / 0.243 / 71.9 | 30.2 / 0.247 / 71.5 | 28.8 / 0.236 / 72.2 | 28.5 / 0.234 / 71.7 |
| Studio FK drag | 99.5 / 0.834 / 236.5 | 95.2 / 0.798 / 145.4 | 98.5 / 0.817 / 145.7 | 96.0 / 0.792 / 237.9 |

- **Weak tracker.** It cost 0.03–0.34 ms of CPU per frame: weak-reference
  side tables, record copies and their retains.
- **Keyed tracker.** It brought orbit and FK drag back to base or below,
  since every reused deformation also saves its encoding. The slider reuses
  nothing, and still paid 0.012–0.016 ms per frame.
- **Final change.** It records values in place and stops tracking while
  every deformation changes. 90% of the slider's dispatches were untracked.
  - Slider means: 29.5 against 29.25 ms/s, and 0.242 against 0.239 ms at
    p50. That is within the 0.009 ms between the two base runs, and its p95
    (0.285 and 0.282 ms) was not higher than base's (0.305 and 0.273 ms).
  - FK drag: CPU unchanged, GPU down 39%.
- **Absolute numbers.** The third window's are higher than the second's
  for both builds alike: 0.234–0.243 against 0.211 ms for the base slider.

### How the harness counts keep-alive refreshes

A refresh presents the same bytes again, so it is neither a rendered frame
nor a hitch ([schema 6](#what-the-report-records)):

- `renderedDraws`, `presentedFrames`, `droppedDrawables`, the draw and GPU
  statistics and the frame-ring counters exclude refreshes. They are counted
  in `refreshedCallbacks` and `refreshedPresented`, with their own `refresh`
  and `refreshGpu` costs.
- The skip-adjusted cadence and the hitch count treat a refresh like an
  unchanged callback: a deliberate skip.
- At a lowered rate, an unchanged or refreshed callback accounts for the gap
  to the next callback, up to one period of that rate. A 15 Hz idle is
  therefore not 7 skipped refreshes per callback.
  `displayLinkDeliberateTargetSkips` counts those periods.
- A static recording can prove that the window was composited with a
  presented refresh.
- `viewport-lifecycle` warns about any refresh while the window was minimized.

### Why G5 was dropped

A Metal System Trace of `studio-orbit` on base `aee4287` measured the GPU
time of each pass over 8 s at about 120 frames/s:

| Pass | ms/s | ms per frame |
| --- | ---: | ---: |
| Deform (compute) | 102 | 0.85 |
| Main | 50 | 0.42 |
| Composite, FXAA and bloom | about 37 | about 0.31 |
| Shadow | 17 | 0.14 |

Studio idle, at 30 rendered frames/s, measured deform 26.4, main 24.8 and
shadow 4.4 ms/s.

- Reusing the shadow map saves at most 0.14 ms per rendered frame.
- The main light follows the camera by default (`MainLight.cameraRelative`):
  `direction(camera:)` turns it by the yaw of the camera's forward vector. A
  yaw orbit, the default drag, changes the light and the shadow's
  view-projection, so the shadow must render again.
- FK drags and Maker edits move the casters.
- Only pan, zoom, hover and selection changes on a static pose would gain.

Deformed-vertex reuse targets the largest pass instead. A camera-only frame
reuses every deformation.

### Correctness

- **Captures.** The six `IKKOKU_AUTOCAPTURE` renders of
  [G3](#phase-2-item-4-unchanged-interactive-frames-g3) (source Studio,
  native Studio and Maker, each with the live opt-in off and on), each its
  own launch under the app lock with the shared fixture map. All 6 PNGs and
  the 3 live reports of the final Release build are byte-identical to base
  `aee4287` (`.local/r7f-frame-skip/captures`, hashes in `summary.json`).
  Captures dispatch every deformation, so they are the references.
- **Reuse.** `InteractiveFrameTests` compares every reused draw byte for byte
  with a draw that dispatched
  ([tests](renderer.md#renderer-threads-r7-phase-2-item-2)):
  - the palette: a moved bone, one bit of one matrix, and back;
  - the morphs: a weight, entries below the threshold, and none;
  - the mesh: another mesh on the key, and back;
  - released, regrown and transient buffers, and keys a frame doesn't use;
  - captures, benchmarks, and synchronous and asynchronous picks between
    draws, in queue order;
  - live source-shader draws, which read the reused vertices;
  - the bypass: 2 tracked and 29 untracked draws with exact pixels, a pick
    in between, no stale record afterwards, and the end of a bypass after a
    0.1 s pause.

  `swift test --package-path Packages/Engine --filter
  'InteractiveFrameTests|DisplayLinkRatePolicy|PickTests|renderThreadDraws|presentationCadence|presentationLateness|CharacterLifetime'`:
  32 tests pass.
- **ThreadSanitizer.** The same filter with `--sanitize=thread`: 32 tests
  pass with 0 warnings.
- **Lifecycle.** `perf_trace.py run --workloads viewport-lifecycle` on the
  final Release build passed with no warning: 0 keep-alive refreshes while
  the window was minimized (6 callbacks), one render thread before every
  step and at the end, and 82 presented frames after the restore.
- **Engine suite** on `802fa4d` with every fixture of the shared map
  exported: 930 tests, 15 named skips and 2 failures, plus 21 in the second
  target. Both failures are environmental:
  - `liveSourceShadersMeetTheControlledOriginalFrameGates` expects 62 store
    entries and finds 52. It fails on `main` `d6b61a2` too: pre-existing.
  - `sourceDynamicsOriginalHairMatchesIndependentOracleWhenRequested`
    resolves `body-skeleton.json` relative to the worktree, which has no
    `.local/reverse`.
- **Python.** `test_perf_trace.py` (21), `test_run.py` (85),
  `test_doctor.py` (29) and `test_inspect_app_bundle.py` (61) pass.
- **Lanes**, Debug, `--strict` under the app lock, 0 skipped:
  `studio-scenarios` 64/64 (1,515 s), including the three accessory-label
  checks, and `maker-scenarios` 10/10 (190 s).

### Limits

- The threshold and the latencies come from one machine and display (M2
  Ultra, 120 Hz). The keep-alive interval leaves room for one dropped
  refresh, not for a different threshold elsewhere.
- The keep-alive keeps a small GPU cost while a visible viewport is idle.
- The standard set, burst and static runs measured `6e28cb6`. The final
  change (`d940390`, values in place and the bypass) was measured only for
  the slider and FK drag. It changes CPU work only. The exception is up to
  29 draws after a run of draws that changed every deformation: those
  dispatch even where they could reuse, unless a 0.1 s pause comes first.
- The bypass thresholds (2 draws, 30 draws, 0.1 s) were chosen, not swept.
- The harness calls the input handlers, not the view, so its drags wake the
  link through the frame they submit. A real event wakes it before its
  handler runs, slightly earlier.
- A frame with a visible live source-shader material renders every callback,
  so its link stays at full rate.
- The 4K full-screen drawable, an M1, many props and long-running memory
  growth are not measured here.

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
item 4's frame identity would also make easier. The bounded G3 slice is now
implemented [above](#phase-2-item-4-unchanged-interactive-frames-g3); it does not
reuse the deform pass for picks.

## Phase 2, item 6: source character builds off the main thread

Done 2026-10-25 (inventory C8, S1, S2 and S4). Source characters now build
off the main thread, in parallel, and the builds of one operation decode
each converted rig file once. A scene import, a duplicate and the rebuilds
after undo or redo no longer stop the main thread for the length of the
build. A launch straight into a source scene also creates the Maker only
when it is first used. Captures, scenarios and reports are byte-identical;
only time and threads change.

On the reference machine, the showoff scene (`koikatu_cs0002591`) is ready
1.41 s after launch instead of 5.65 s, and the first frame shows at 0.43 s
instead of 5.93 s. The main thread used to stall once for 5.6–6.0 s; it is
now busy 620–672 ms in total until the scene is ready. Its longest busy
period, 270–449 ms, is the launch itself, up to the window's first frame.
A duplicate is drawn 112 ms after the command, with 45 ms of main-thread
work, against a 671 ms stall. The undo after it is ready in 525 ms, with
91 ms of main-thread work, against a 4.58 s stall. The import's CPU fell
from 4.53 to 2.43 s, mostly because the 70 rig decodes became 10.

### What changed

The contract, the threads and the cancellation rules are in
[source character builds](renderer.md#source-character-builds-r7-phase-2-item-6).
In short:

- **Two halves.** `SourceStudioCharacterPreview.assemble` reads the files,
  decodes the rigs and prepares the Maker assembly. It registers nothing and
  can run on any thread. `init(assembly:resources:)` registers the meshes
  and textures and evaluates the preview, as the rest of the old
  initializer did.
- **Shared rig decodes (C8, S2).** `SourceRigDecodeShare` decodes each
  distinct converted rig file once per operation. Its key is the Maker reuse
  boundary's content key: the SHA-256 and byte count of the bytes read.
  Concurrent requests for one file wait for the one decode. The 7-character
  test batch runs 10 decodes instead of 70. `SourceMakerLibrary.prepare`
  gained an internal overload that takes the share; the Maker's own calls
  and its reuse worker are unchanged.
- **Borrowed assemblies.** Some builds borrow the immutable assembly of a
  loaded preview with the same character, outfit and store, and skip its
  file reads and decodes:
  - a duplicate;
  - an undo or redo that rebuilds previews;
  - a re-import of the loaded scene;
  - a route character.
- **Background builds (S1).** `SourceStudioCharacterBatch` runs the first
  halves on GCD workers, as many as the active processor count less two. It
  runs the second halves one at a time, in request order. Interactive and
  performance-trace runs use it in the background:
  - **A scene import** (`beginSourceSceneImport`) prepares on the main
    actor, builds on the workers and the `source-builds` queue, and commits
    on the main actor in one step, in the synchronous import's order.
    Meanwhile, the Studio shows the current document and "Importing
    <scene>: N of M".
  - **A refresh that finds previews missing** (after a duplicate, an undo or
    redo, or a scene load) starts one batch. Each preview installs on the
    main actor when it is built; until then, the frame leaves that character
    out.

  Captures and scenarios build the same batches synchronously, in the
  original order on the main thread, so their registrations and mesh IDs
  are unchanged.
- **Cancellation.** A new import, New Scene and a scene load cancel every
  batch in flight. Nothing a cancelled import built reaches the document,
  and its previews release their resources through R6 retirement.
- **The Maker on first use (S4).** This applies to an interactive or
  performance-trace launch straight into a source scene, with no Maker
  input. That launch creates the Maker when it is first needed: switching to
  it, a Maker menu command, or a Studio button that reads the Maker's card.
  Until then, the Maker menu items are enabled as for the Maker it becomes.
  Captures, scenarios and every other launch create the Maker at startup, as
  before.
- **Builds that land while the Maker is shown.** A commit or an install
  then leaves the Maker's frame on the shared renderer. Switching back to
  the Studio refreshes it.
- **Harness.** The `startup` report gains `sourceSceneReady` and the main
  thread's busy periods until then (`startupMainThread`), so a launch whose
  scene arrives after the window is not read as idle. Two workloads,
  `studio-duplicate` and `studio-undo-delete`, time an action until its
  builds are installed ([what the report records](#what-the-report-records)).
  The base build carries the same harness.
- **Scenario op.** `backgroundBuild` (in `background-build.json`) runs each
  of these synchronously, then with background builds, in the strict Studio
  lane:
  - an import;
  - two overlapping imports;
  - an import cancelled by New Scene;
  - a duplicate with its undo;
  - an import and a duplicate with the Studio hidden.

### Measurement

The commands follow [measuring a change](#measuring-a-change). Release builds,
arm64:

| Label | Commit | Executable SHA-256 |
| --- | --- | --- |
| base | `d3bf65c`: `main` `2dc317f` (#272) with this change's harness commits, before any build change | `978360f6…4f995717` |
| after | `aa5593d` (this change; later commits change only docs) | `028c03df…548e7659` |

Conditions:

- **Window.** All runs were in one quiet window the orchestrator granted on
  2026-10-25 (11:13–11:19), with base and after alternating, every launch
  under the app lock, and a load average of 3.2–5.1.
- **Display.** A 120 Hz display at 2×, with a 1996×1824 drawable. A
  `studio-idle` smoke run confirmed 120 Hz first.
- **Runs.** `startup` ran three times per build, for the showoff scene and
  for the 2-character fixture scene (`IKKOKU_STUDIO_HALF_STATE_SCENE`).
  `studio-duplicate` and `studio-undo-delete` recorded 30 s each, with a 3 s
  warmup. Their action is on source key 963, with live animation on.
  `studio-idle` recorded 10 s.
- **CPU.** One more startup per build measured the CPU. An external sampler
  read the process's CPU time every 20 ms, and a system-wide Time Profiler
  recording was started before the launch, so it holds the whole import with
  its worker threads.
- **Flags.** `summarize` flagged no run, and no run received stray input.
- **Evidence.** Reports and analysis are in `.local/r7g-startup/window`.

Startup, seconds since process start, median (range) of three runs:

| Scene | Build | Scene ready | Import call on the main thread | First draw | Main thread until ready: busy of window ms | Longest busy period ms | Periods over 100 ms | Peak footprint MB |
| --- | --- | --- | --- | --- | --- | --- | ---: | --- |
| showoff | base | 5.65 (5.63–5.66) | 4,566 ms (4,533–4,582) | 5.93 | 5,980 of 5,980 (5,629–6,033) | 5,980 | 1 | 1,052 (1,046–1,058) |
| showoff | after | 1.41 (1.39–1.41) | 9.5 ms (9.0–9.6) | 0.43 (0.39–0.44) | 664 of 1,449 (620–672 of 1,432–1,474) | 441 (270–449) | 2–3 | 920 (916–932) |
| fixture | base | 1.88 (1.86–1.88) | 790 ms (789–793) | 2.12 (2.08–2.15) | 1,854 of 1,854 (1,836–2,222) | 1,854 | 1 | 751 (751–765) |
| fixture | after | 1.07 (1.07–1.08) | 5.2 ms (5.1–5.7) | 0.43 (0.41–0.46) | 597 of 1,110 (591–605) | 276 (268–446) | 2–3 | 570 (570–572) |

The base launch spends 0.9 s creating the Maker (`makerReady` at 0.99 s)
before the Studio. The after launch reaches `studioReady` at 0.19 s.

Actions, in ms: medians, with the range for the time until ready. In base,
the build runs inside the call, so the call is the time until ready.

| Action | Base: call and ready | Base: main busy | After: call | After: ready | After: main busy | After: longest busy period |
| --- | --- | ---: | ---: | --- | ---: | --- |
| Duplicate (5 and 16 actions) | 671 (666–673) | 693 | 3.1 | 112 (107–117) | 45 | 38 (max 41) |
| Undo of the duplicate (5 and 16) | 4,583 (4,578–4,607) | 4,613 | 13.7 | 525 (503–534) | 91 | 59 (max 65) |
| Delete (6 and 14) | 4.5 | 41 | 4.3 | 4.3 | 42 | 42 (max 47) |
| Undo of the delete (5 and 13) | 4,582 (4,573–4,587) | 4,594 | 9.9 | 976 (954–988) | 70 | 34 (max 45) |

Over each 30 s run, the main thread was busy 698 → 141 ms/s in
`studio-duplicate` and 800 → 112 ms/s in `studio-undo-delete`. The after
runs fit about three times as many actions, because an action no longer
blocks. Idle is unchanged: 30.0 rendered frames per second in both builds,
and 36 against 31 ms/s of main-thread time. The idle footprint is 1,042
against 902 MB, because the Maker is not created.

Where the startup import's CPU goes. Each build's system-wide Time Profiler
recording was cut from `studioReady` to `sourceSceneReady` with the app's
own signposts:

| | Base | After |
| --- | --- | --- |
| Window (wall) | 4.54 s | 1.23 s |
| Ikkoku CPU in the window | 4.53 s (1.0 core) | 2.43 s (2.0 cores on average) |
| Main thread | 4.37 s | 0.36 s, nearly all in the first 0.4 s (window setup) |
| Workers and the build queue | 0.16 s | 2.06 s |
| `SourceRig.decode` | 3.62 s (80%) | 0.54 s |
| Rest of the first halves (shape contract, animation and hand patterns) | inside the 4.34 s initializer | 0.76 s, on about 6 workers at once |
| Second halves | inside the 4.34 s initializer | 0.27 s, one at a time |
| Import prepare and commit on the main thread | — | 9 ms and 7 ms |

The external sampler agrees: 4.55 s of process CPU during base's import,
and 2.45 s during after's 1.22 s.

### What remains

The after import's 1.23 s, read from the same trace in 100 ms buckets:

- **0–0.55 s: the shared rig decodes, on about one core.** Each character
  prepares its rigs in the same order (base, head, clothes), so all
  characters wait on the same in-flight decode, and the 10 distinct decodes
  run one after another. Starting every distinct decode of a batch at once,
  from the cards, before the preparations ask for them, is a **hypothesis**
  worth about 0.4 s here.
- **0.55–0.7 s: the rest of the first halves**, 0.76 s of CPU across about
  6 workers.
- **0.7–1.23 s: the second halves, one at a time.** They use 0.27 s of CPU
  over 0.53 s of wall time. The rest is likely waiting on texture loads,
  through MetalKit and the GPU (not measured). Asynchronous texture loading
  (S3) is the next step there.

Other costs:

- **Undo of a delete takes 976 ms, against 525 ms for the undo of a
  duplicate.** A deleted preview's assembly is not kept, so its character
  builds from scratch. Keeping it in the history step, as the previews an
  undo drops are kept, is a **hypothesis** worth about 0.45 s.
- **Each installed preview refreshes the frame once**, seven times for an
  undo that rebuilds seven characters. That is part of the 70–91 ms of
  main-thread time per undo; coalescing the installs is a small
  **hypothesis**.
- **Single-character builds still run whole on the main thread:**
  - an outfit selection;
  - a plugin attachment's parent;
  - the export validation baseline;
  - the route characters of a rehydration. These use shared decodes and
    borrowed assemblies.
- **The launch itself** keeps the main thread busy about 0.44 s until the
  window's first frame: AppKit and SwiftUI window setup. This item does not
  address it.

The [follow-up](#phase-2-item-6-follow-up-route-copies-prefetch-and-kept-donations)
measured these hypotheses:

- the prefetch of distinct decodes saves 0.23 s, not 0.4 s;
- kept donations save 0.31 s of the undo of a delete, not 0.45 s;
- the shared install refresh saves 11 ms of main-thread work per undo.

It also moved route character copies off the main thread.

### Behavior notes

- **The Studio shows before its characters.** On a launch into a source
  scene, the window opens with an empty Studio and the progress line, and
  the whole scene appears when the import commits. Before, the window
  appeared after the import.
- **A menu import** shows the Studio and its progress line at once. If the
  import fails, the app returns to the previous mode and shows the error, as
  a failed synchronous import never left it. Until the commit, the current
  scene stays editable; the commit replaces it, and Undo restores it.
- **Builds that finish while the Maker is shown** leave the Maker's frame on
  the shared renderer; the Studio shows them when it is shown again. An
  import that commits then does not switch back to the Studio.
- **A duplicated or restored character appears a moment after the rest.**
  The copy's object is in the tree at once; its character is drawn when its
  build installs, 0.1–1 s later on the reference machine.
- **The first switch to the Maker** after a deferred launch takes the
  Maker's creation time, about 0.9 s on the main thread, which the launch no
  longer spends. The Maker then starts with the converted library selected
  at that moment, and with its own status line. A converted-library message
  shown while it was deferred appears only on the Studio's line.
- **Draw order.** In a background build, a character's meshes can register
  between main-thread registrations made meanwhile, which changes relative
  mesh IDs across objects. That matters only for draws tied on every other
  sort key. Captures and scenarios are unaffected.

### Correctness

- **Captures.** All captures used the final after build and the shared
  fixture map, one launch each under the app lock:
  - six `IKKOKU_AUTOCAPTURE` renders: Studio source, fixture and native,
    Maker source, and Studio and Maker source with the live opt-in ON;
  - two `IKKOKU_CAPTURE_UI` windows, Studio and Maker;
  - five scenario reports: `topology-duplicate`, `undo-props`, `undo-route`,
    `reload-save-route` and `reload-save-duplicate`.

  All 8 PNGs and all 9 reports (2 live, 2 UI and the 5 scenario reports) are
  byte-identical to base. The two windows were captured with base again in
  the same session, because the window height had changed with the display
  arrangement since the first base capture, in both builds alike
  (`.local/r7g-startup/captures`).
- **Engine tests** (`SourceStudioCharacterBatchTests`, 6 tests): the decode
  share, a 7-character batch against 7 sequential builds, cancellation, and
  borrowed assemblies, as listed in the
  [renderer reference](renderer.md#source-character-builds-r7-phase-2-item-6).
  They also pass under ThreadSanitizer, with 0 warnings, both before and
  after the fixture tests moved off the test pool.
- **App under ThreadSanitizer.** A Release+TSan session ran `startup`,
  `studio-duplicate` and `studio-undo-delete` for 15 s each, with 0
  warnings. It ran at an earlier commit of this change, before the Maker
  call-site and hidden-Studio fixes.
- **Scenario.** `studio-scenario-background-build` passes all 9 steps. The
  synchronous and background builds give the same document summary (tree,
  names, parents, visibility, diagnostics, status, character outcome and
  runtime counts) and a byte-identical 512² render. It also checks:
  - New Scene leaves no completion and an empty document;
  - two overlapping imports commit only the second;
  - the duplicate built 1 character and the undo rebuilt 7 in the
    background.

  Two controls failed as they should. Skipping the wait for the builds
  failed 3 of the 4 original steps. Letting builds refresh the hidden Studio
  failed both hidden steps.
- **Lanes**, Debug, `--strict` under the app lock, 0 skipped:
  - `maker-scenarios` 10/10 (185.2 s) at `ddb4130`;
  - `studio-scenarios` 69/69 (1,220.2 s) at `ddb4130`, with the new
    `studio-scenario-background-build`.

  The `app-smoke` and `maker` lanes have failures this change does not
  reach. `startup-mute-capture` passes no `IKKOKU_SOURCE_AVATAR`, and a
  worktree has no `.local/reverse` fallback, so it throws before any
  changed code. Two `maker` checks need fixtures that the map lacks, and
  `maker_roundtrip.py` reads the checkout's own `.local`. The other
  `app-smoke` checks pass (6/7), including the Release build and the Release
  startup capture.
- **Engine suite** with the fixture map, in parallel, at `ddb4130`: 948
  tests in 340 s, with 934 passed, 12 named skips and 2 failures. The 21
  tests of the second target pass. The failures:
  - `liveSourceShadersMeetTheControlledOriginalFrameGates`, the known one;
  - `sourceDynamicsOriginalHairMatchesIndependentOracleWhenRequested`. It
    reads `.local/reverse` relative to the checkout, which a worktree does
    not have. It passed alone once that folder was reachable.

  The first full run hung with every one of the 24 test-pool threads
  blocked in MetalKit's synchronous texture load. That is the hang found in
  [item 3](#phase-2-item-3-live-tick-off-the-main-thread). Three of the
  blocked threads were this change's fixture tests. Those tests now run one
  at a time, each on a thread of its own, as the live-tick fixture tests
  do.
- **Python.** Runner self-tests 198 (`test_run.py` 85), `Tools/reverse` 518
  (7 skipped), `Tools/reverse/analysis` 279 and the site check pass.
- **`viewport-lifecycle`** (after build) is clean. There was one render
  thread before every step and at the end, 202 frames were presented after
  the restore, and there were no keep-alive refreshes while minimized.

### Limits

- **Few runs.** Three startup runs per build and scene, and one run per
  build of each action workload and of idle.
- **One CPU attribution per build:** one system-wide Time Profiler
  recording, and the external sampler (10 ms resolution, about 20 ms
  alignment to the app's marks).
- **The quit is not exercised.** Nothing reaches the document or the disk
  before a commit, so a quit during an import leaves nothing behind. No run
  quits during one.
- **The equality proof uses one scene**, the 7-character scenario scene,
  through the scenario op and the Engine batch test. The draw-order
  difference for exact sort-key ties in background builds is by design and
  not tested.
- **The Maker's creation on first use** after a deferred launch was not
  timed separately.
- **No M1 run** ([estimate](#scaling-to-the-low-end-base-m1-8-gb)).

## Phase 2: live pacing

The Studio's live animation, timeline playback, route playback and plugin
session advance in steps of exactly 1/30 s. A 30 Hz `Timer` on the main run
loop started them (M6). Live pacing (2026-10-25) starts them from the Studio
viewport's display link instead, so every step starts at the same point of
the display's vsync grid. The contract is in the renderer reference:
[live pacing](renderer.md#live-pacing-r7-phase-2).

### Attribution

At 120 Hz a 30 Hz step's frame should present every 4 vsyncs. With the
timer, presented intervals of 3 and 5 vsyncs came in pairs, 0–15 times a
second depending on the run. These are from the first window, in Release,
with 10 s runs:

| Build | Workload | Runs | Intervals not 4 vsyncs, per second |
| --- | --- | ---: | --- |
| `main` `42fc588` | `studio-idle` (7 source characters) | 2 | 6.6, 13.1 |
| `main` `42fc588` | `studio-native` (6 native characters) | 2 | 0.0, 11.3 |
| this change, timer control | `studio-idle` | 5 | 12.4, 7.4, 2.4, 15.4, 0.1 |
| this change, timer control | `studio-native` | 5 | 10.6, 12.9, 0.4, 5.4, 6.1 |
| this change, timer control | `studio-timeline` | 2 | 0.8, 0.0 |

- **The app causes them, not the compositor.** The callbacks' own target
  times show the same 3- and 5-vsync gaps as the presented frames, one for
  one: the frame went to a different callback.
- **The timer's phase against the vsync grid decides the rate.** The timer
  keeps the phase it was created with, give or take 1–3 ms over a 10 s run.
  - In the 15.4/s run, every step started 4 ms after a callback. Each step
    then submitted its frame 0–2 ms before or after the next callback, so the
    step's own jitter chose between two callbacks. Its workers take 1.5–3 ms.
  - In the 0.1/s run, the steps started within 1 ms of a callback and
    submitted 3–5 ms before the next one.
- **A short step rarely straddles a callback.** The timeline's step takes
  about 1 ms on the main thread, so it straddled less often: 0.8/s and 0/s.
- **The harness's hitch count misses this jitter.** It counts active frames
  presented later than expected, and a 5-vsync gap next to a 3 averages out.
  The `cadence` histograms of schema 7 count it.

### What changed

- **The display link starts the step.** `LiveStepPacer` picks the callback
  nearest each step's due time: at 120 Hz, every 4th. That callback asks the
  main run loop for a step before it draws.
  - The step starts 0.02–0.05 ms after the request (p50).
  - It always starts at the same phase.
  - It submits 3–7 ms before the callback that draws it.
- **Busy and idle.** A step still running when the next is due is skipped,
  as the timer skipped it, so a slow scene slows down as before. With
  nothing to step, the pacer parks. The Studio timer, which still polls the
  status line, resumes it when there is something to step.
- **The Maker** kept its own timer in this change. A follow-up (R7h2) paces
  it the same way ([Maker pacing](#maker-pacing)).
- **Measurement.** `IKKOKU_PERF_LIVE_PACING=timer` brings the timer back in
  the same binary.
  - Schema 7 reports add per-request samples, a `pacing` summary, and a
    `cadence` histogram of presented intervals, target intervals and
    lateness.
  - `studio-timeline` plays a keyed timeline.
  - `IKKOKU_PERF_BURST_LIVE=on` plays the live animation during
    `studio-orbit-bursts`.

### Before and after

Both windows were reserved, every launch held the app lock, and the M32UC
ran at 120 Hz. All builds were Release, with 10 s recordings after a 3 s
warmup (12 s for the bursts).

- **First window** (13:58–14:11). It ran `main` `42fc588` and `ece3281`, a
  WIP commit of this change. `ece3281`'s display pacing at full link rate
  takes the same request path as the final change. Its runs had no busy or
  idle answers, so the later changes to those answers did not apply. Its
  rounds ran in the same order: timer, then display.
- **Second window** (15:10–15:19). It ran the final change, `8428647`,
  against its timer control in ABBA order: `T D D T T D D T` for idle and
  native, and `T D D T` for the rest. One display run saw stray input; it
  was discarded and run again inside the window.

**Cadence**, as intervals other than 4 vsyncs per second:

| Workload | Window | Timer: target | Display: target | Timer: presented | Display: presented |
| --- | --- | --- | --- | --- | --- |
| `studio-idle` | first, 5 runs each | 12.4, 7.0, 2.3, 15.4, 0 | 0 (all 5) | 12.4, 7.4, 2.4, 15.4, 0.1 | 0.2, 0.2, 0, 0, 0 |
| `studio-native` | first, 5 runs each | 10.6, 13.0, 0, 5.4, 5.8 | 0 (all 5) | 10.6, 12.9, 0.4, 5.4, 6.1 | 0.3, 0, 0.3, 0.1, 0 |
| `studio-timeline` | first, 2 runs each | 0.8, 0 | 0, 0 | 0.8, 0 | 0.1, 0 |
| `studio-idle` | second, 4 runs each | 0, 0.2, 9.7, 10.1 | 0 (all 4) | 1.7, 13.2, 14.9, 18.9 | 0, 8.6, 13.2, 14.2 |
| `studio-native` | second, 4 runs each | 0, 0.6, 0, 10.7 | 0 (all 4) | 0.7, 12.6, 11.8, 16.0 | 2.4, 7.8, 12.3, 13.0 |
| `studio-timeline` | second, 2 runs each | 0, 0 | 0, 0 | 5.2, 4.5 | 5.0, 3.7 |

- **Targets.** With display pacing no target interval in either window was
  other than 4 vsyncs: every step went to the callback it was paced for.
  With the timer, the rate depended on the run, as in the attribution.
- **Presented frames, first window.** The display-paced frames presented
  4 vsyncs apart except 0–0.3 times a second.
- **Presented frames, second window.** The compositor presented frames 0, 1
  or 2 vsyncs after their targets and switched between them within runs,
  in both modes alike. Each switch makes a 3/5 or 2/6 pair although the
  targets are 4 apart. 9–100% of each run's frames were late, with no
  difference between the modes: 30–91% with the timer and 27–100% with
  display pacing in idle and native, and 9–24% and 15–19% in the timeline.
  A run whose frames were all late by the same amount had no jitter (one
  display run of `studio-idle`). This lateness is outside the app: it does
  not follow the GPU's finish against the frame's deadline.
- **FPS** was 30.0 in every run of both modes, with 0 skipped steps and no
  busy answer.

**Cost**, second window, medians:

| Workload | Process CPU ms/s: timer → display | Main busy ms/s | Worker CPU ms/s | GPU ms/s | Step on the main thread, p50 ms |
| --- | --- | --- | --- | --- | --- |
| `studio-idle` | 509 → 516 | 33.2 → 32.2 | 341 → 346 | 38.6 → 40.0 | 0.34 → 0.26 |
| `studio-native` | 174 → 171 | 75.1 → 68.0 | — | 38.2 → 38.3 | 2.34 → 1.92 |
| `studio-timeline` | 266 → 264 | 218 → 215 | — | 24.7 → 24.7 | 1.45 → 1.34 |
| `studio-orbit-bursts`, live on | 483 → 493 | 31.6 → 32.8 | 245 → 250 | 57.5 → 57.2 | 0.31 → 0.27 |

- **Main thread.** The main-thread part of a step is smaller with display
  pacing in every workload. Main busy time is lower in idle, native and the
  timeline. In the live-on bursts it is 1.2 ms/s higher.
- **Worker CPU.** In the four `studio-idle` ABBA pairs, the workers' CPU was
  higher with display pacing in three pairs (+20, +29 and +31 ms/s) and
  lower in one (−20). The per-step p50 was at parity: 15.08 against 14.94,
  10.45 against 12.18, 10.76 against 10.36, and 10.43 against 10.32 ms.
  - The mean was 0.5 ms higher per step, from a longer upper tail.
  - The job's wall time was at most 0.04 ms longer, and shorter in three
    pairs: p50 1.83–2.56 against 1.95–2.52 ms.
  - The cause is not established; the CPU clock and core placement are
    likely, and the harness reads neither. It lies within the timer's own
    run-to-run range of 315–397 ms/s.

### The link rate during playback

The brief asked to lower the display link to 30 Hz while only paced steps
change the frame, with input returning it to full rate at once. This was
built and measured in the first window, then dropped: it was not measurably
better.

- **CPU and GPU.** CPU and GPU ms/s stayed within run-to-run noise of
  full-rate pacing, in rounds that ran before the full-rate ones.
- **Draws and steps.** Each draw and step took longer at 30 callbacks a
  second. In `studio-timeline`, the p50 step took 1.17–1.18 ms instead of
  1.05–1.08 ms, and the p50 draw 0.57 ms instead of 0.48–0.49 ms.
  Render-thread draw time per second went up, from 64.8 to 72.0 ms/s in
  `studio-idle`.
- **Latency.** A frame's target moved from 25 ms to 75 ms after its
  callback.
- **Cadence** was the same.

The link keeps the full rate during playback, and its adaptive tiers
(phase 2, item 4) apply as before when nothing changes.

### Drag starts

`studio-orbit-bursts` runs 0.5 s orbit drags with 1 s pauses, eight drag
starts per run, the first after the warmup. "Live on" plays the live
animation throughout, so a drag starts during playback. "Live off" is a drag
after a pause, as in item 4. No run dropped a frame.

| Live animation | Window | Pacing | Input to first rendered callback, ms (median) | Input to first presented frame, ms (median) | Frames presented late |
| --- | --- | --- | --- | --- | --- |
| on | second | timer | 5.4, 5.4 | 30.7, 32.0 | 38%, 44% |
| on | second | display | 4.7, 4.9 | 30.5, 37.9 | 51%, 85% |
| on | first | timer | 2.3 | 27.1 | 1% |
| on | first | display | 5.3 | 38.6 | 88% |
| off | second | timer | 5.8 | 31.1 | 43% |
| off | second | display | 5.5 | 30.9 | 35% |

- **The app's part is the same.** From the input to the first rendered
  callback took 4.7–5.5 ms with display pacing and 5.4–5.8 ms with the
  timer in the second window.
- **The first image comes one vsync later in a late-presenting run.** It
  shows after 29–31 ms when the compositor presents on target, and after
  38–40 ms when it presents one vsync late. A run's median depends on how
  many of its eight starts fall into the late state.
- **Not settled for live-on drags.** In the three live-on burst runs with
  display pacing, 51%, 85% and 88% of frames were late, against 38%, 44% and
  1% with the timer. The cadence runs show no such difference, and live off
  is at parity. Whether pacing makes the late state more likely during live
  drags is not established with three runs a side.

### Idle cost

`studio-static`, the source scene with live animation off, after an 8 s
warmup, second window, two runs each:

| Pacing | Callbacks/s | Paced requests | Process CPU ms/s | Main busy ms/s | Render-thread draw ms/s | GPU ms/s |
| --- | ---: | ---: | --- | --- | --- | --- |
| timer | 15.0 | — | 19.8, 17.8 | 2.0, 1.7 | 2.2, 2.0 | 0.8, 0.8 |
| display | 15.0 | 0 | 19.7, 20.0 | 1.5, 1.7 | 2.4, 2.3 | 0.9, 0.9 |

- **Parked.** An idle Studio sends no requests. Before parking was added,
  the link asked 15 times a second, once per callback at the slowest tier,
  and each answer was `.idle`. In the live-on bursts, each drag start
  parked the pacer once (8 `.idle` answers per run), and the timer resumed
  it after the drag. A drag after a pause with live animation off sent no
  request.
- **Wakeups.** The main thread wakes 34 times a second in both modes (the
  median second): 30 for the timer, plus the rest.
- **Bursts.** Both modes showed 1–3 s bursts of about 600 main-thread
  wakeups a second at random times in shorter runs after a 3 s warmup. The
  longer warmup keeps them out of these runs; their source is not
  established.

### Maker pacing

R7h2 (2026-10-25) paces the Maker's idle step from the Maker viewport's
display link, as the Studio's. Before it, the Maker stepped from its own
30 Hz timer and kept the jitter. One `maker-idle` run of the first window
above had 13.6 off-grid intervals a second, and `main`'s run had 0.5, where
the phase happened to fall well.

- **What changed.** `MakerModel` is a `LivePacedHandler`, and its
  `displayStep` runs what the timer's tick did, minus the status line:
  - with an original preview, the blink, the idle clip and the hair
    dynamics;
  - with the bundled character, blink, breathing and
    `stepHairDynamics(dt: 1/30)`.

  It answers `.ran` while the live animation is on in Maker mode, and
  `.idle` otherwise; the step is synchronous, so never `.busy`. The timer
  polls the status line and resumes a parked pacer while there is work, with
  the same predicate as the answer. The steps still advance by the time
  since the previous step. While the window is hidden, nothing steps; the
  timer used to keep stepping. The contract is in the renderer reference:
  [live pacing](renderer.md#live-pacing-r7-phase-2).
- **Hand-over.** Each mode owns its viewport, so a Studio/Maker switch
  replaces the viewport and its link. The old viewport detaches its model,
  and the new one attaches the other model; one link paces at a time.
  `viewport-lifecycle` now gives the Studio `studio-native`'s scene, as the
  workload table always said, so both models have live steps. Before each
  of its steps and at the end it records:
  - the mode;
  - the viewports that render;
  - which models have live work;
  - which models a link paces;
  - each model's paced steps.

  `perf_trace` warns in these cases:
  - two models are paced at once, or one without a rendering viewport is;
  - after the viewport switched, a model other than the active one is paced;
  - an inactive model ran paced steps;
  - a model with live work ran no paced step after the switch to it.

  Under the timer control, no model may be paced
  ([contract](renderer.md#live-pacing-r7-phase-2)).
- **Workloads.** `maker-idle` is the source card (idle clip, blink and
  source hair), and `maker-slider` adds slider writes at 120 a second. The
  bundled character's hair (`stepHairDynamics`) runs only without the
  original card and avatars. The runs below reach it with `maker-idle` and
  a `--wrap` script that unsets `IKKOKU_SOURCE_CARD`,
  `IKKOKU_SOURCE_AVATAR` and `IKKOKU_SOURCE_MALE_AVATAR` before taking the
  app lock.

**Before and after.** The window ran 19:26–19:33 on the M32UC at 120 Hz.
The build was Release `517b2fb`: this change on `main` `6502803`, before
`main`'s later maps and sampling merges, which do not touch the Maker. Every
launch held the app lock. Each run recorded 10 s after a 3 s warmup, and the
timer control (T) ran against display pacing (D) in ABBA order:
- `T D D T T D D T` for `maker-idle`;
- `T D D T` for `maker-slider`;
- `T D D T` twice for the bundled character.

No run was retried or saw stray input.

Cadence, as intervals other than 4 vsyncs per second:

| Workload | Timer: target | Display: target | Timer: presented | Display: presented |
| --- | --- | --- | --- | --- |
| `maker-idle`, original card | 0 (all 4) | 0 (all 4) | 9.5, 9.5, 7.7, 9.3 | 9.1, 7.0, 8.9, 10.1 |
| `maker-idle`, bundled character | 0.6, 2.2, 0, 0 | 0 (all 4) | 6.4, 6.1, 7.1, 4.6 | 4.8, 6.6, 6.2, 5.5 |

- **Targets.** With display pacing, every target interval in the eight idle
  runs was 4 vsyncs. With the timer, two bundled runs had 0.6 and 2.2 a
  second. The original card's four timer runs had none in this window: their
  phases fell well, as `main`'s did in the first live-pacing window. That
  window's other timer run had 13.4 a second.
- **Presented frames.** The compositor presented 8–34% of each run's frames
  one vsync late, in both modes alike. Each switch between late and on time
  makes a 3/5 pair, as in the second live-pacing window.
- **`maker-slider`** redraws every vsync, because its slider writes come 120
  times a second. Its intervals are 1 vsync in both modes, and the paced
  step still ran 30 times a second.
- **Requests.** Every request ran: 300 per run, none busy or idle. The step
  started 0.01–0.04 ms after its request (p50), and 0.02–0.08 ms at p95.

Cost, medians (8 bundled runs, 4 a side):

| Workload | Process CPU ms/s: timer → display | Main busy ms/s | Step ms/s | Step p50 ms | GPU ms/s |
| --- | --- | --- | --- | --- | --- |
| `maker-idle`, original card | 137.8 → 134.6 | 53.9 → 49.8 | 51.4 → 46.6 | 1.61 → 1.46 | 19.3 → 19.5 |
| `maker-idle`, bundled character | 99.5 → 106.4 | 19.7 → 20.6 | 17.1 → 17.1 | 0.51 → 0.50 | 20.0 → 19.9 |
| `maker-slider` | 643 → 652 | 564 → 571 | 15.1 → 15.7 | 0.49 → 0.50 | 71.6 → 71.0 |

- **Original card.** The step is shorter with display pacing, as the
  Studio's was: 1.46 against 1.61 ms (p50). Main busy time was lower in 3 of
  4 pairs.
- **Bundled character.** Process CPU was higher with display pacing in 3 of
  4 pairs: +9.3, +8.6, −0.5 and +5.9 ms/s, a median of +6.8 ms/s.
  - The step itself is at parity: 0.50 against 0.51 ms (p50).
  - The main thread's share is +1.2 ms/s of CPU. Off the main thread it is
    +5.2 ms/s. The render thread's draws account for +1.0 ms/s of that, and
    the harness does not break down the rest.
  - The cause is not established. Paced, the main thread wakes twice per
    step: once for the timer's status poll, once for the request. The timer
    wakes it once.
- **Slider.** Process CPU was 7.5–9.2 ms/s higher with display pacing in
  both pairs, about 1.3%. The two modes' ranges overlap: 637–650 ms/s with
  the timer, 646–657 ms/s with display pacing. Main busy time differed by
  +0.1 and +13.1 ms/s.

**Correctness.**

- **Captures** at `517b2fb`, Release, with the shared fixture map, one
  launch each under the app lock. The set is live pacing's: six
  `IKKOKU_AUTOCAPTURE` renders, two `IKKOKU_CAPTURE_UI` windows and the
  `advance` scenario. The renders include the Maker source with the live
  opt-in OFF and ON. The Maker's live animation is on in all of them. All
  12 PNGs and 5 reports are byte-identical to `main` `74cee1c`; #275 changed
  none of them, so that base holds for `6502803`.
- **Lanes.** Debug, `--strict` under the app lock, 0 skipped, at
  `8586f9d` after merging `main` `3bfcc37`:
  - `maker-scenarios` 10/10 (also at `517b2fb`, before the merges);
  - `studio-scenarios` 78/78.
- **Engine tests.** `LiveStepPacerTests` (11, two of them new) and
  `DisplayLinkRatePolicyTests` (4) pass, also under ThreadSanitizer with 0
  warnings. At `8586f9d`, after merging `main` `3bfcc37`, the suite with the
  fixture map ran 988 tests. The 6 failures and 14 issues are the same
  fixture-environment ones as live pacing's.
- **App under ThreadSanitizer** (Debug, at `8586f9d`): 12 s each of
  `viewport-lifecycle`, `maker-idle`, `maker-slider`, `studio-timeline` and
  `studio-idle`, and `maker-idle` with the bundled character, with 0
  warnings.
  - The original card's step took about 115 ms under ThreadSanitizer, so 98
    steps ran in 12 s, each answered `.ran`.
  - `viewport-lifecycle` passed its hand-over check. Before one of its 12
    steps SwiftUI had not yet replaced the viewport, which the check allows.
- **`viewport-lifecycle`** (Release, at `8586f9d`) is clean in both modes:
  - one render thread before every step and at the end;
  - 86 frames presented after the restore;
  - no keep-alive refresh while minimized.

  With display pacing, the link paced exactly the active mode's model
  before every step. The Maker ran 230 paced steps and the Studio 47. Under
  the timer control no model was paced.
- **Python.** All pass:
  - runner self-tests (200), with the hand-over check;
  - `Tools/reverse` 573, with 7 skipped;
  - `Tools/reverse/analysis` 279;
  - the site check.

### What remains after live pacing

- **Compositor lateness.** The remaining presented jitter comes from the
  compositor switching between presenting on target and one or two vsyncs
  late. When it switched little (first window), display-paced frames
  presented 4 vsyncs apart except 0–0.3 times a second.
- **Drag starts during playback** need more runs in a calm compositor, to
  settle whether pacing changes how often frames present late.
- **Two main-thread wakeups per step.** During playback the main thread
  wakes once for the timer, which polls the status line, and once for the
  step. Folding the status poll into the step would save one wakeup per
  step, which is not measured. The paced Maker does the same, and with the
  bundled character its process CPU was a median 6.8 ms/s higher, mostly
  off the main thread ([Maker pacing](#maker-pacing)). Whether the second
  wakeup causes it is the first thing to test.
- **A step near one vsync long.** Pacing fixes where a step starts. If a
  step takes about one vsync from request to submit (8.3 ms at 120 Hz), its
  submit straddles a callback again. That is far from the 3–5 ms here, but
  possible on a slower machine with more characters.

### Correctness of live pacing

- **Captures** at `8428647`, Release, with the shared fixture map, one
  launch each under the app lock:
  - six `IKKOKU_AUTOCAPTURE` renders: Studio source, fixture and native,
    Maker source, and Studio and Maker source with the live opt-in ON
    (7 live draws);
  - two `IKKOKU_CAPTURE_UI` windows, Studio and Maker;
  - a scenario that steps the live animation with `advance`, orbits and sets
    an FK rotation, with four renders and its report.

  All 12 PNGs and 5 reports are byte-identical to `main` `74cee1c`.
- **Lanes.** Debug, `--strict` under the app lock, 0 skipped, at `8428647`:
  - `studio-scenarios` 73/73 (1,300 s);
  - `maker-scenarios` 10/10 (246 s).
- **Engine tests.** `LiveStepPacerTests` (9) and `DisplayLinkRatePolicyTests`
  (4) pass, also under ThreadSanitizer with 0 warnings.
- **Engine suite** with the fixture map, at `8428647`: 970 tests, 964
  passed. The 6 failures are the same with the same 14 issues on `main`
  `74cee1c`, so they come from the fixture environment:
  - `liveSourceShadersMeetTheControlledOriginalFrameGates`, the known one;
  - `liveSourceIrisCompositesMatchTheRetainedOriginalComposites` and
    `liveSourceEyeWhiteCompositesMatchTheRetainedOriginalComposite`: a
    composite program is missing from the native texture store;
  - `sourceShaderBindingsFollowTheSavedHalfStateOverAlternateRenderers` and
    `sourceStudioWearLibraryAlternatesMatchUpdateVisibleAndKeepTheDressedParts`:
    the fixture map's Maker library lacks the alternates and parts they
    expect;
  - `sourceDynamicsOriginalHairMatchesIndependentOracleWhenRequested`, which
    reads `.local/reverse` relative to the checkout.

  The 21 tests of the second target pass.
- **App under ThreadSanitizer.** A Debug build with ThreadSanitizer ran
  `studio-timeline`, `studio-idle`, `studio-static`, `viewport-lifecycle`
  and `studio-orbit-bursts` with live on, 12 s each, with 0 warnings.
  - Its steps took longer than 1/30 s, so 333 of `studio-idle`'s 355
    requests were busy and skipped, as the timer skipped them.
  - The timeline presented every frame 4 vsyncs apart.
  - The static scene sent no request.
- **`viewport-lifecycle`** (Release) is clean:
  - one render thread before every step and at the end;
  - 84 frames presented after the restore;
  - no keep-alive refreshes while minimized.
- **Python.** All pass:
  - runner self-tests (199);
  - `test_perf_trace.py`, with the schema 7 cadence line;
  - `Tools/reverse` 528, with 7 skipped;
  - `Tools/reverse/analysis` 279;
  - the site check.

### Limits

- **One display.** All runs used one 120 Hz display. 60, 144 and 240 Hz,
  119.88 and 59.94 Hz, ProMotion and a rate change are covered by
  `LiveStepPacerTests`, not by hardware runs. No other display or
  refresh-rate setting was available without changing system settings.
- **Few runs.** Two to five runs per workload and mode per window, and one
  run each for drag starts after a pause.
- **Compositor state.** The second window's compositor switched lateness
  often, so its presented cadence does not separate the modes. The first
  window's does.
- **No M1 run** ([estimate](#scaling-to-the-low-end-base-m1-8-gb)).

## ST-A11: original Studio maps

Added 2026-10-25 with the first maps slice ([maps](studio/maps.md)). An imported
CharaStudio scene that names Map 33 now draws it: 8 draws, 1,492 triangles and
7 base textures that take 52.2 MB of Metal memory as RGBA8 with mips. The map
loads on a GCD worker beside the import's characters. The main thread only
reads the 24 KB catalog when the import starts and places the 8 draws at the
commit. The measurements show:

- **No added import time.** The scene is ready at the same time, and the main
  thread does no more work until then.
- **About 52 MB more GPU memory.**
- **A small steady-state cost** that depends on how much of the room is in view.

### Measurement

Release builds, arm64, the commands of [measuring a change](#measuring-a-change):

| Label | Commit | What it draws |
| --- | --- | --- |
| base | `74cee1c` (`main`, #274) | no map: base ignores `IKKOKU_STUDIO_MAP_CATALOG` |
| no map | `ceccafa` (this change) without the catalog | no map: the line says the catalog is missing |
| map | `ceccafa` with `IKKOKU_STUDIO_MAP_CATALOG` | Map 33 |

Conditions:

- **Window.** One quiet window the orchestrator granted (2026-10-25,
  16:20–16:26). Base, no map and map alternated in each round, every launch
  ran under the app lock, and the load average was 4.0–6.5.
- **Display.** A 120 Hz display at 2×, with a 1996×1824 drawable.
- **Scene.** `scene-map33-showoff.png`: `koikatu_cs0002591.png` with Map 33
  added in the original player. It has 32 objects and 7 source characters.
- **Runs.** `startup` ran three times per configuration. `studio-idle` and
  `studio-orbit-bursts` ran twice, each recording 10 s after a 3 s warmup.
  No run was flagged, occluded or given stray input.
- **Evidence.** The reports are in `.local/sta11a-maps/perf/{base,nomap,map}/r{1,2,3}`.
- **The props hide most of the room.** The scene's own props stand around the
  characters, so from the scene camera they hide most of the room. In a
  1200×1600 capture the map changes no pixel. In the 1996×1824 window, as the
  orbit turns, parts of the room can show.
- **The offscreen benchmark** therefore also renders the room fully in view.
  It uses `IKKOKU_BENCHMARK_OUTPUT` at 1996×1824 with 60 measured frames,
  three runs each. Its two scenes are:
  - `scene-map33.png`, with no characters and the camera inside the room;
  - the showoff scene without the item catalog, so the room shows behind the
    7 characters.

  The reports are in `.local/sta11a-maps/perf/benchmark`.

Startup, seconds since process start, median (range) of three runs:

| Build | Scene ready | Import call on the main thread | First draw | Main thread until ready: busy of window ms | Longest busy period ms | Peak footprint MB | Peak Metal MB |
| --- | --- | --- | --- | --- | --- | --- | --- |
| base | 1.47 (1.47–1.48) | 9.5 ms (9.5–9.8) | 0.46 (0.45–0.48) | 717 of 1,522 (667–728) | 452 (251–472) | 909 (908–919) | 356.0 |
| no map | 1.47 (1.46–1.48) | 9.1 ms (9.0–10.2) | 0.46 (0.45–0.49) | 708 of 1,515 (702–729) | 286 (272–435) | 918 (916–921) | 356.0 |
| map | 1.45 (1.44–1.46) | 10.1 ms (9.4–10.2) | 0.45 (0.44–0.45) | 674 of 1,466 (671–689) | 311 (302–450) | 980 (972–982) | 408.5 |

- **The load.** It takes 73–83 ms on the worker: reading the glTF, decoding 7
  PNGs and the MetalKit texture loads with mips. The value is from the
  `[ikkoku] source map:` line of 12 Release capture and benchmark launches,
  because the measured build printed it only when a load finished after the
  commit.
- **Placement.** Placing the 8 draws takes 0.00–0.01 ms on the main thread.
- **When the map draws.** The load ends long before the 1.2 s character
  builds, so the map is placed at the import's commit and drawn in the first
  frame after `sourceSceneReady`.
- **The `sourceMapReady` mark.** The measured build set it only when the load
  finished after the commit, so these runs did not record it. The fix, made
  after the window (`9735d01`), sets it whenever the map is placed. One
  startup outside the window confirmed it: `sourceMapReady` at 1.654 s, 3 ms
  before `sourceSceneReady`, inside the same commit.
- **No import time added.** Scene ready, first draw and the main thread's
  busy time until ready are within run-to-run variation. The import call's
  extra ~1 ms is the catalog read, and its range overlaps.
- **Memory.** Metal grows by 52.5 MB: the 52,248,576 texture bytes plus the
  vertex and index buffers. The peak footprint grows by 50–62 MB.

Steady state, median (range) of two runs:

| Workload | Build | Main busy ms/s | Process CPU cores | Render-thread draw ms/s | GPU ms/s | GPU ms per frame p50 / p95 | Rendered draws/s | Peak footprint MB | Peak Metal MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| studio-idle | base | 26.2 (23.6–28.7) | 0.40 | 45.4 | 39.3 | 1.26 / 1.64 | 30.0 | 911 | 356.0 |
| studio-idle | no map | 26.0 (23.3–28.8) | 0.40 | 44.6 | 39.2 | 1.27 / 1.61 | 30.0 | 912 | 356.0 |
| studio-idle | map | 30.9 (29.2–32.6) | 0.45 | 45.7 | 42.7 | 1.37 / 1.74 | 30.0 | 962 | 408.5 |
| studio-orbit-bursts | base | 9.8 (9.6–9.9) | 0.12 | 50.7 | 30.1 | 0.82 / 1.29 | 34.8 | 911 | 356.0 |
| studio-orbit-bursts | no map | 9.4 (9.0–9.9) | 0.11 | 49.4 | 29.7 | 0.82 / 1.29 | 34.7 | 908 | 356.0 |
| studio-orbit-bursts | map | 9.2 (8.9–9.5) | 0.11 | 49.4 | 28.3 | 0.66 / 1.31 | 35.1 | 966 | 408.5 |

- **Idle main thread.** It was 4–6 ms/s higher with the map in the paired
  rounds (28.8 → 32.6 and 23.3 → 29.2), with `refresh()` p50 0.47–0.53 →
  0.55–0.59 ms at 30 refreshes per second. A micro-benchmark attributes it
  (see [refresh attribution](#refresh-attribution)): the map adds at most a
  few microseconds per refresh. The difference is these runs' variation: in
  the same map runs, the off-main live evaluation's CPU rose by 8–29% (310 →
  337 and 227 → 294 ms/s), although the map does not touch it.
- **Idle GPU:** +0.10 ms per frame (+3.5 ms/s at 30 frames per second).
- **Orbit bursts.** The main thread and draw CPU are unchanged. GPU time per
  frame fell by 0.15 ms p50 (**not explained**; see the benchmark below).
- **Drag starts after a pause** are unchanged: 30.8–30.9 ms to the first
  presented frame, against 31.0–37.9 (no map) and 30.8–31.8 ms (base).

Offscreen benchmark at 1996×1824, median (range) of three runs of 60 frames:

| Scene | Map | Items | CPU encode ms | GPU ms p50 | Completion ms | Metal MB |
| --- | --- | ---: | --- | --- | --- | ---: |
| `scene-map33.png`, no characters | no | 0 | 0.076 | 0.535 (0.532–0.545) | 0.994 | 317.1 |
| `scene-map33.png`, no characters | yes | 8 | 0.091 | 0.398 (0.391–0.414) | 0.868 | 369.5 |
| showoff without props | no | 122 | 0.453 | 1.357 (1.339–1.358) | 2.232 | 454.1 |
| showoff without props | yes | 130 | 0.445 | 1.425 (1.418–1.427) | 2.298 | 506.6 |

- **With the room behind the 7 characters**, the map costs 0.07 ms of GPU per
  frame. Encoding its 8 draws costs about 0.015 ms of CPU in the empty room,
  and nothing measurable behind the characters.
- **The room alone renders faster than the empty Studio.** It takes 0.40 ms
  against 0.54 ms, which draws only the background gradient and the grid.
  The likely cause (**hypothesis**) is the GPU's hidden-surface removal: the
  room's opaque walls cover the whole frame, so the background and grid
  fragments under them are never shaded. The same effect would explain the
  lower orbit GPU time when parts of the room come into view.

### Refresh attribution

Afterwards, outside a quiet window, a temporary hook (not committed) timed
`refresh()` in one Release process on the showoff scene with the map loaded.
It ran 400 refreshes per configuration, interleaved over 9 rounds (live
animation off, a load average of 13–26), and reports the median of the
rounds. A 4 s `sample` of the map configuration found
`publishSourceMapLine` in 12 and the rest of the map's code in 2 of about
4,000 main-thread samples.

| Build | No map µs | Map µs | Map hidden µs | `publishSourceMapLine` µs (built / unchanged inputs) | `currentSourceMapItems` µs |
| --- | ---: | ---: | ---: | --- | ---: |
| before | 451.7 | 455.3 | 453.2 | 1.36 / – | 0.38 |
| after, run 1 | 461.7 | 467.1 | 465.7 | 1.47 / 0.24 | 0.35 |
| after, run 2 | 455.5 | 455.2 | 451.2 | 1.50 / 0.23 | 0.36 |

- **The map's per-refresh cost is at most a few microseconds,** within the
  benchmark's variation: +3.6 µs before, then +5.5 and −0.2 µs. The target
  of 10–20 µs holds.
- **The steady-state runs' 0.08 ms gap** was therefore not the map.
- **The change anyway** keeps per-frame work flat:
  - `refresh()` rebuilds the map line only when one of its inputs changed
    (`SourceMapLineKey`: the document's and the request's scene, the map,
    the asset's identity, placed, failed, shown). Unchanged inputs cost
    0.24 µs instead of the 1.4 µs string build.
  - The frame's item array is reserved at the last frame's size, so the
    characters' and the map's appends no longer regrow it.

The reports are in `.local/sta11a-maps/refresh-bench`. With the change
(`58d0998`), the four map checks passed 4/4 under `--strict`, and the 14
Release captures were byte-identical to the merged head's
(`.local/sta11a-maps/captures-fix`).

### Scaling to a base M1 (estimate)

This uses the method of [scaling to the low end](#scaling-to-the-low-end-base-m1-8-gb):
CPU × 1.25, and GPU × 76/8 cores × the 1.8 / 3.6 Mpx window ratio, about 4.75.

- **Load.** About 0.1 s on a worker. The scene's ~2 s character builds hide
  it, and the main thread still does almost nothing for the map. The GPU's
  mip generation for the 7 textures was not measured; it is part of the
  worker's load and does not block the main thread.
- **GPU.** With the room filling the frame, the room costs about 1.9 ms per
  frame on its own. Behind characters it adds about 0.35 ms per frame, and
  0.5 ms per frame in the showoff scene's idle (+14 ms/s at 30 frames per
  second).
- **Main thread.** A few microseconds per refresh at most.
- **Memory.** +52 MB of Metal memory and 50–62 MB more footprint fit in
  8 GB. That memory is the reason for native BC upload (G7) before larger
  maps: Map 34 would take 265.3 MB as RGBA8 against 39.8 MB as BC.

### Correctness

Release captures from `74cee1c` and `ceccafa` (`.local/sta11a-maps/captures/{base,branch}/captures.json`):

- **Byte-identical on base and branch,** with the live source-shader opt-in
  OFF and ON:
  - the no-map scenario scene (`koikatu_cs0002591.png`) with the catalog
    supplied;
  - the 2-character half-state fixture;
  - the native Studio capture;
  - the map scene without the catalog.

  The live opt-in's reports are byte-identical too.
- **With the catalog,** the emptied map 33 scene draws the room, identically
  with the opt-in OFF and ON. The showoff scene without props draws the room
  behind the characters, with the opt-in ON as well.
- **After the merge.** The same set was repeated on the merged head `c094f92`
  against `main` at `6502803` (#275 live pacing,
  `.local/sta11a-maps/captures-merged/`). Every no-map capture was again
  byte-identical, and every branch capture matched its pre-merge hash.

The Studio lane (77/77), the Maker lane (10/10), the Engine suite and the
negative controls are listed in [maps](studio/maps.md#evidence).

### Limits

- **Few runs.** Two steady-state runs and three startups per configuration.
- **The room is mostly hidden in the in-app runs,** so the benchmark stands
  in for the visible-room cost.
- **The GPU reductions are not attributed;** no Metal System Trace was
  recorded.
- **The runs predate the merge of #275 (live pacing).** The map's costs are
  per `refresh()` and per draw. Live pacing changes when the 30 Hz step
  starts, not those costs, so the runs were not repeated.
- **No M1 run.**

### Slice 2: baked lightmaps

Added 2026-10-25 with the second maps slice
([maps: baked lightmaps](studio/maps.md#baked-lightmaps-slice-2)). Map 33's
8 draws now use `map_fragment`. Each samples its base texture, two BC3
lightmaps on UV1 and, for two materials, an emission map. The lightmap
blocks upload as BC3 on the load's worker.

**Measurement.** Release builds, in one quiet window the orchestrator
granted (2026-10-25, 20:43:38–20:44:42). Every launch ran under the app
lock with the other agents paused, at 120 Hz (`maximumFramesPerSecond` 120,
1996×1824 drawable). The load average was 2.8–3.7. There were 24 launches:

- `startup` 3 times per build, alternating;
- the offscreen benchmark (`IKKOKU_BENCHMARK_OUTPUT`, 1996×1824, 60
  measured frames) 3 times per case, alternating.

`perf_trace.py summarize` printed no warning. Each startup took about 4 s
and each benchmark launch about 2 s, which is why the window was short. The
reports are in `.local/sta11b-lightmaps/perf/`.

| Label | Commit | Export |
| --- | --- | --- |
| base | `b4c59e7` (`main`, #277) | the first slice's (Map 33 with the item material) |
| lightmap | `2eefcdc` (this change, before it merged #280) | the slice-2 export (Map 33 lightmapped) |

Startup on `scene-map33-showoff.png`, seconds since process start, median
(range) of three runs:

| Build | Scene ready | Import call on the main thread | First draw | Main thread until ready: busy of window ms | Longest busy period ms | Peak footprint MB | Peak Metal MB | Map load on the worker ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| base | 1.39 (1.38–1.42) | 9.7 ms (9.0–9.8) | 0.41 (0.41–0.47) | 662 of 1,436 (651–664) | 465 (246–481) | 966 (963–978) | 408.5 | 91.1 (90.7–91.3) |
| lightmap | 1.41 (1.37–1.41) | 9.4 ms (9.1–10.1) | 0.41 (0.40–0.42) | 679 of 1,477 (663–700) | 420 (291–431) | 975 (974–981) | 412.8 | 94.4 (93.6–95.0) |

Offscreen benchmark at 1996×1824, median (range) of three runs of 60 frames:

| Scene | Build | Items | CPU encode ms | GPU ms p50 | Completion ms | Metal MB | Map load on the worker ms |
| --- | --- | ---: | --- | --- | --- | ---: | --- |
| `scene-map33.png`, no characters | base | 8 | 0.080 | 0.422 (0.416–0.426) | 0.850 | 369.5 | 71.1 |
| `scene-map33.png`, no characters | lightmap | 8 | 0.081 | 0.509 (0.505–0.538) | 0.947 | 373.7 | 75.4 |
| showoff without props | base | 130 | 0.425 | 1.381 (1.370–1.386) | 2.197 | 506.6 | 75.0 |
| showoff without props | lightmap | 130 | 0.437 | 1.334 (1.333–1.346) | 2.178 | 510.9 | 77.7 |
| showoff without props or catalog | base | 122 | 0.414 | 1.320 (1.312–1.330) | 2.186 | 454.1 | – |
| showoff without props or catalog | lightmap | 122 | 0.420 | 1.325 (1.315–1.328) | 2.195 | 454.1 | – |

- **GPU, room alone:** +0.087 ms per frame (0.422 → 0.509). Each fragment
  takes two trilinear BC3 samples and the RGBM `pow`, in place of the item
  material's lighting.
- **GPU, room behind the 7 characters:** −0.047 ms per frame (1.381 →
  1.334), consistent over the three runs. This is **not explained**. The
  hypothesis is the shadow map: the item material lights every room
  fragment with the scene light and samples the character shadow map, and
  `map_fragment` does neither. In the empty map33 scene there are no
  character shadows to sample. No Metal System Trace was recorded.
- **No map:** unchanged. GPU is within 0.005 ms, and Metal memory is
  identical.
- **CPU:** the encode time is unchanged (three more texture bindings per
  map draw, 8 draws), and so is the main thread.
- **Import:**
  - The scene is ready at the same time, and the first draw and the import
    call are unchanged.
  - The main thread's busy time until ready overlaps between the builds. The
    map's main-thread work is the same catalog read and a 0.00–0.01 ms
    placement.
  - The worker's load takes 2.7–4.3 ms longer: reading and hashing the
    2.8 MB of lightmap blocks, 22 `replace` calls (11 mips × 2), and the
    emission PNG.
- **Memory:** Metal grows by exactly 4,243,456 bytes:
  - the two BC3 lightmaps take 2,818,048;
  - the emission map takes 1,425,408 (RGBA8 with mips through
    `ResourceStore`).

  Decoded to RGBA8 with mips, the lightmaps would take about 11.2 MB
  instead of 2.8 MB. The peak footprint is +9 MB by median, and its ranges
  touch.

**Scaling to a base M1 (estimate),** with the method above (GPU × about
4.75, CPU × 1.25):

- the room filling the window takes about 2.4 ms per frame, against 2.0 ms
  with the item material (+0.4 ms);
- behind characters there is no measurable increase;
- the worker's load takes about 4–5 ms longer;
- Metal memory grows by 4.2 MB.

**Limits.** These are three runs per case. No `studio-idle` or orbit runs
were made: in the showoff scene the props hide the room, so the draws
change no pixel there. No Metal System Trace was recorded, and no M1 run.

### Slice 3: map 34, the sky and block images

Added 2026-10-26 with the third maps slice
([maps: slice 3](studio/maps.md#map-34-the-sky-and-block-images-slice-3)).
Three changes affect cost:

- map textures upload as the bundle's BC1/BC3 blocks instead of PNGs
  decoded to RGBA8 with MetalKit's mips;
- map 34 draws, with its cube sky and particles;
- map draws sample with anisotropy 9, the original player's forced
  setting.

**Measurement.** Release builds, in one quiet window the orchestrator
granted (2026-10-26, 06:18:16–06:20:04):

- every launch ran under the app lock, one at a time, with the other agents
  paused;
- the display ran at 120 Hz (1996×1824 drawable), and the load average was
  1.4–3.7;
- a watcher sampled every 2 s for `swift-build`, `swift-frontend`,
  `swiftpm-testing-helper` and `xcodebuild` and saw none in any round.

There were 54 launches, in three alternating rounds: `startup` once per
scene and build per round, and the offscreen benchmark
(`IKKOKU_BENCHMARK_OUTPUT`, 1996×1824, 60 measured frames) once per case per
round. `perf_trace.py summarize` printed no warning. The reports are in
`.local/sta11c-map34/perf/`.

| Label | Commit | Export |
| --- | --- | --- |
| base | `4d60b73` (`main`, #285) | slice 2 for map 33; slice 3 for map 34 (`main`'s binary decodes its PNGs and has no sky or particle code) |
| head | this change (its code is `147bd19`'s) | slice 3 |
| tri | head with the two map samplers trilinear (no anisotropy), built for this window only | slice 3 |
| decoded | head with `IKKOKU_SOURCE_MAP_DECODED_TEXTURES=1` (the PNGs, RGBA8 with mips) | slice 3 |

Startup, seconds since process start, median (range) of three runs. The
showoff scene has 7 characters and draws map 33. The map 34 day scene has
no characters and draws only the map:

| Scene | Build | Scene ready | Import call on the main thread | First draw | Map ready | Main thread until ready: busy of window ms | Longest busy period ms | Peak footprint MB | Peak Metal MB | Map load on the worker ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| showoff | base | 0.93 (0.91–0.93) | 9.2 ms (9.2–9.4) | 0.37 (0.33–0.38) | 0.93 (0.91–0.93) | 604 of 978 (593–605) | 394 (392–401) | 1,013 (1,013–1,019) | 412.8 | 97.7 (96.8–100.4) |
| showoff | head | 0.91 (0.91–0.94) | 9.4 ms (9.4–9.5) | 0.33 (0.33–0.33) | 0.91 (0.90–0.94) | 582 of 972 (557–590) | 375 (357–379) | 969 (969–986) | 366.5 | 12.7 (12.5–13.3) |
| map 34 day | base | 0.16 (0.16–0.17) | 4.8 ms (4.4–5.0) | 0.32 (0.30–0.34) | 0.51 (0.50–0.52) | 357 of 357 (351–360) | 357 (351–360) | 544 (529–545) | 449.4 | 401.0 (396.2–410.6) |
| map 34 day | head | 0.16 (0.16–0.17) | 4.6 ms (4.5–4.7) | 0.31 (0.31–0.32) | 0.43 (0.43–0.43) | 359 of 359 (356–359) | 359 (356–359) | 327 (326–328) | 221.6 | 66.4 (65.1–69.7) |

- **Import is unchanged.** Scene ready, the import call, the first draw and
  the main thread's busy time are within run-to-run variation, or lower. The
  map's main-thread work is still the catalog read and a 0.00–0.04 ms
  placement.
- **The worker's load is 6–8 times faster.** In the showoff scene it falls
  from 97.7 to 12.7 ms. Map 34 falls from 401 ms, decoding 54 PNGs and
  generating their mips, to 66 ms. The load copies the blocks and hashes
  them; the 1.7–2.9 ms eager PNG read, measured outside the window, is part
  of it.
- **Map 34 is placed 80 ms sooner,** at 0.43 s against 0.51 s. That is
  less than the 335 ms its load saves. When the load starts, and how long its
  completion waits for the main thread during the first frames, were not
  traced.
- **Memory.**
  - The showoff scene's peak Metal falls by 46.3 MB (412.8 → 366.5), map 33's
    texture bytes exactly (56,492,032 → 10,207,232). Its peak footprint
    falls by 44 MB.
  - Map 34's scene peaks at 221.6 MB of Metal against 449.4 MB with `main`'s
    decoded PNGs, and 327 MB of footprint against 544 MB.

Offscreen benchmark at 1996×1824, median (range) of three runs of 60 frames:

| Scene | Build | Items | CPU encode ms | GPU ms p50 | Completion ms | Metal bytes | Map load on the worker ms |
| --- | --- | ---: | --- | --- | --- | ---: | --- |
| `scene-map33.png`, no characters | base | 8 | 0.078 | 0.542 (0.494–0.551) | 0.926 | 373,719,040 | 74.0 (73.3–74.8) |
| `scene-map33.png`, no characters | head | 8 | 0.080 | 0.498 (0.482–0.535) | 0.926 | 327,434,240 | 9.6 (9.5–9.7) |
| `scene-map33.png`, no characters | tri | 8 | 0.080 | 0.534 (0.505–0.547) | 0.929 | 327,434,240 | 9.7 (9.4–9.7) |
| map 34 day | base | 54 | 0.139 | 0.552 (0.552–0.555) | 1.005 | 591,659,008 | 374.5 (372.4–379.9) |
| map 34 day | decoded | 54 | 0.140 | 0.494 (0.493–0.524) | 0.966 | 607,387,648 | 385.2 (373.4–389.2) |
| map 34 day | head | 54 | 0.137 | 0.483 (0.481–0.535) | 0.941 | 378,978,304 | 58.1 (58.0–58.3) |
| map 34 day | tri | 54 | 0.135 | 0.476 (0.476–0.521) | 0.933 | 378,978,304 | 59.5 (57.6–59.5) |
| map 34 evening | base | 53 | 0.134 | 0.559 (0.554–0.560) | 1.005 | 591,659,008 | 366.9 (364.3–375.7) |
| map 34 evening | head | 53 | 0.133 | 0.483 (0.479–0.527) | 0.954 | 378,978,304 | 58.0 (57.1–58.9) |
| map 34 evening | tri | 53 | 0.137 | 0.478 (0.476–0.521) | 0.940 | 378,978,304 | 59.0 (54.8–59.6) |
| showoff without props | base | 130 | 0.426 | 1.339 (1.332–1.341) | 2.109 | 510,853,120 | 81.1 (80.8–81.2) |
| showoff without props | head | 130 | 0.428 | 1.349 (1.348–1.352) | 2.166 | 464,568,320 | 11.6 (11.5–11.9) |
| showoff without props or catalog | base | 122 | 0.422 | 1.324 (1.320–1.325) | 2.157 | 454,131,712 | – |
| showoff without props or catalog | head | 122 | 0.422 | 1.324 (1.316–1.328) | 2.175 | 454,131,712 | – |

- **Map 34 with its sky:** 0.483 ms of GPU per frame at 1996×1824, from both
  the day and the evening camera. The sky pass draws first, right after the
  background and without a depth test, like Unity's Background queue. The
  room then covers most of it. Its share of the 0.483 ms was not isolated.
- **Anisotropy 9 costs less than this benchmark resolves.** Against `tri`,
  map 34 differs by +0.007 and +0.005 ms, and map 33 by −0.036 ms, inside
  every range.
- **BC against RGBA8:** −0.011 ms on map 34 (0.494 → 0.483), also inside the
  ranges.
- **`main`'s binary on the slice-3 export** takes 0.552–0.559 ms for map 34.
  It draws the sky sphere and the particle mesh with the item material,
  which lights every fragment and samples the shadow map (**hypothesis**,
  as in slice 2; no Metal System Trace was recorded).
- **Behind the 7 characters,** map 33 costs +0.010 ms (1.339 → 1.349; the
  ranges do not overlap), 0.1% of an 8.33 ms frame. No `tri` run was made
  for this scene, so the cost is not split between anisotropy and BC.
- **No map:** GPU time and Metal bytes are identical.
- **CPU encode is unchanged** between the builds. Map 34's 54 draws encode
  in 0.133–0.140 ms, against 0.076 ms for the empty Studio in slice 1.
- **Memory.** Metal falls by exactly the texture bytes:
  - map 33: 46,284,800 bytes;
  - map 34: 228,409,344 bytes against the decoded PNGs. That is 196,608
    bytes (0.09%) short of the texture bytes' 228,605,952, a difference not
    attributed (Metal's per-allocation sizes are not the textures' byte
    counts).

**Scaling to a base M1 (estimate),** with the method above (GPU × about
4.75, CPU × 1.25):

- **GPU.** Map 34 with its sky, filling the window, takes about 2.3 ms per
  frame. Behind characters, map 33 adds under 0.05 ms. The anisotropy cost
  was below the benchmark's resolution here (under about 0.01 ms), so under
  about 0.05 ms per frame on the M1. Anisotropic filtering spends texture
  bandwidth, and the M1's bandwidth is about a twelfth of this machine's
  (68 against 800 GB/s), against the 9.5× core ratio the method uses. So
  this is the least certain of the estimates.
- **Load.** The worker's load takes about 12–16 ms for map 33 and 75–85 ms for
  map 34, against about 0.5 s decoding map 34's PNGs.
- **Memory.** Map 34 needs about 60 MB of textures instead of 288 MB, so
  its scene's peak Metal is about 220 MB instead of 450 MB. On 8 GB of
  shared memory, that difference matters.

**Limits.**

- These are three runs per case.
- No `studio-idle` or orbit runs were made: the showoff scene's props hide
  the room, and the map 34 scenes have no characters to move.
- No Metal System Trace was recorded, so the GPU differences under 0.05 ms
  are not attributed.
- No M1 run.

## ST-T03i: scene plug-in data rewrites

Added 2026-10-26 with the second plug-in data change ([plug-in data](studio/scene-editing.md#plug-in-data-st-t03i)).
An export that deletes, copies or moves objects in a scene with KKPE,
MaterialEditor or NodesConstraints data now rewrites that data inside
`editedData`. Nothing in the app or on the main thread changed. The change's
timing probe found two costs, and both were fixed:

- **The card hash (commit `2b4cc156`).** `SourceCharacterCard.decode`
  computed the card's SHA-256, plus a `String(format:)` per digest byte, for
  every card it decoded. Several decodes read every embedded card:
  - each scene decode (`KoikatsuSceneRecordReader`, line 45);
  - the decode of the written scene that verifies each export;
  - the KKPE step's reads of the cards that carry its data.

  Only a few readers use the hash, each once: the Maker save, binding
  provenance, the inspection CLI and the probes. `sourceSHA256` is now
  computed when read. On the largest scene, 42 cards of 1.9 MB on average,
  hashing took about 30 ms per pass over the cards.
- **The KKPE used-ID scan.** Each KKPE plan searched the whole scene with
  `memmem` for the two ID attributes, about 50 ms per pass on the largest
  scene (a standalone `-O` benchmark, not in a quiet window). The scan now
  runs only when a plan needs a fresh ID. It makes one `memchr` pass for the
  quote and tests the attribute name that ends there, about 5.6 ms. Both
  measured builds include this fix. Its corpus output is byte-identical.

### Measurement

The Release timing probe, `swift test -c release -Xswiftc -enable-testing
--filter SourceScenePluginDataPerformance`, runs with `IKKOKU_PLUGIN_SCENE_PERF=1`
and `IKKOKU_PLUGIN_SCENE_LARGEST`. Each case is the median of 60 calls after
10 warmups.

- **Window.** One quiet window the orchestrator granted (2026-10-26,
  07:19–07:21), with load average 2.6 falling to 2.3. A watcher polled the
  process list every second and saw no other build, test or app process.
- **Builds.** Before is `43f6a577` (the eager hash) and after is `2b4cc156`
  (the lazy hash). The runs went before, after, after, before, one process
  each, and each cell lists the two runs.
- **Scenes:**
  - showoff (`koikatu_cs0002591`): 595,127 B, 7 characters, no plug-in data;
  - the fixtures of the original-player phases A, B and C;
  - the largest KKPE scene of the install: 80,535,331 B, 173 objects, 42
    characters, 36,553 B of plug-in data. It is private, and its SHA-256
    begins `c4825f76`.
- **Evidence.** `.local/stt03j-plugin-rewrites/logs/window/`.

Import, Engine side: `decodeDocument`, then `card()` for every character:

| Scene | Step | Before ms | After ms |
| --- | --- | --- | --- |
| showoff | `decodeDocument` | 2.61, 2.66 | 2.43, 2.47 |
| showoff | every `card()` (7) | 0.41, 0.41 | 0.09, 0.10 |
| largest | `decodeDocument` | 55.2, 55.0 | 24.2, 25.0 |
| largest | every `card()` (42) | 35.3, 34.5 | 4.34, 4.40 |

Export: `editedData`, and the plug-in step within it:

| Scene and edit | `editedData` before ms | after ms | Plug-in step before ms | after ms |
| --- | --- | --- | --- | --- |
| showoff, one transform | 5.41, 5.61 | 4.95, 4.98 | 0.049, 0.056 | 0.049, 0.049 |
| showoff, subtree deletion | 5.17, 5.46 | 4.83, 4.77 | 0.043, 0.043 | 0.044, 0.043 |
| phase C, delete item (three rewrites) | 1.41, 1.41 | 1.31, 1.31 | 0.215, 0.215 | 0.213, 0.205 |
| phase C, duplicate item | 1.52, 1.55 | 1.48, 1.37 | 0.297, 0.278 | 0.285, 0.295 |
| phase C, duplicate character (card patch) | 2.56, 2.70 | 2.34, 2.34 | 1.12, 1.14 | 0.94, 0.87 |
| phase C, move | 1.29, 1.33 | 1.21, 1.21 | 0.086, 0.080 | 0.087, 0.085 |
| largest, delete item | 174.0, 170.0 | 81.7, 83.6 | 50.8, 51.2 | 21.0, 21.0 |
| largest, duplicate item | 185.4, 187.8 | 96.2, 98.7 | 57.0, 57.6 | 26.8, 27.4 |
| largest, move item to the root | 125.0, 125.5 | 61.6, 65.1 | 0.77, 0.70 | 0.71, 0.71 |

The phase A and B fixtures hold no characters, so the hash change cannot
reach them. Their exports took 0.61–0.71 ms with a plug-in step of
0.024–0.075 ms in both builds, within 0.07 ms of each other.

What the numbers show:

- **No cost without plug-in data.** On showoff the plug-in step is
  0.043–0.056 ms in both builds. It searches the written bytes once for
  KKAnimationController card data, then returns.
- **The hash was most of the largest scene's time.** Without it, a decode of
  that scene takes 24.6 ms instead of 55.1 ms. Reading all 42 cards takes
  4.4 ms instead of 34.9 ms. A delete exports in 83 ms instead of 172 ms, a
  duplicate in 97 ms instead of 187 ms, and a move in 63 ms instead of
  125 ms. The move's plug-in step was 0.7 ms in both builds, so its 62 ms
  came from the scene decodes alone.
- **Small scenes gain a little.** Showoff reads its 7 cards in 0.09 ms
  instead of 0.41 ms, and its exports are about 0.5 ms faster.
- **What remains on the largest scene.** The plug-in step of a delete or
  duplicate still takes 21–27 ms. A sample of the whole "before" test
  process ranked the hash first (`AccelerateCrypto_SHA256_compress`, 2,478
  samples), then memory copies (`_platform_memmove`, 1,066) and Foundation's
  Boyer–Moore byte search (184). Card bytes are copied out of the scene with
  `subdata` and searched with `Data.range(of:)`. Reading them in place is a
  follow-up, not measured here.

### Correctness

- **The lazy hash has the same value.** `sourceCharacterCardHashIsTheSHA256OfItsPreservedBytes`
  compares it with CommonCrypto's SHA-256 on the source card fixture and on
  every card of phase C's scene, and two reads are equal. The commit lists
  every reader. None reads the hash in a loop or per frame.
- **The ID scan change writes the same bytes.** The 175-scene rule corpus is
  byte-identical before and after it.
- **Lanes and the Engine suite.** On `256147d` (Debug, `--strict`, 0
  skipped): `studio-scenarios` passed 81/81, `maker-scenarios` 10/10, and the
  Engine suite 1,052 tests ([plug-in data](studio/scene-editing.md#plug-in-data-st-t03i)).

### Scaling to a base M1 (estimate)

This uses the CPU factor of [scaling to the low end](#scaling-to-the-low-end-base-m1-8-gb),
× 1.25. Everything measured here is single-threaded CPU work.

- **The largest scene:**
  - a decode in about 31 ms;
  - a delete export in about 103 ms, a duplicate in about 122 ms and a move
    in about 79 ms.

  Before this change they were about 69, 215, 233 and 157 ms.
- **Showoff and the fixtures:** under 7 ms per export.

### Limits

- Two runs per build in one window.
- Engine timing only. The app's import and export were not timed.
- The `memmem` figure comes from a standalone benchmark, not from this
  window.
- No M1 run.

## Phase 2, item 6 follow-up: route copies, prefetch and kept donations

Done 2026-10-25 (the follow-ups of inventory C8, S1 and S3, and ST-T11's
route-copy build). The changes:

- route character copies build in the background;
- the rig decodes of a batch start at once;
- the material compositors share one command queue;
- dropped previews lend their assemblies to the builds that bring them
  back;
- the installs of one action share a frame refresh.

On the reference machine, the showoff scene is ready 1.04 s after launch
instead of 1.42 s, and the 2-character fixture scene 0.78 s instead of
1.08 s. A Duplicate of route 0 with its character no longer holds the main
thread for 159 ms. Its command returns in 2.4 ms, and the copy's character
is drawn 97 ms later, with 41 ms of main-thread work. The undo of a delete
is ready in 351 ms instead of 992 ms, next to the 341 ms of the undo of a
duplicate (531 ms before). Captures, scenario reports and the order of
registrations are unchanged; only time, threads and memory change.

### What changed

The contract is in
[source character builds](renderer.md#source-character-builds-r7-phase-2-item-6).
In short:

- **Route character copies in the background (ST-T11).** A Duplicate of a
  route with its character built the copy's route preview inside the
  command, on the main thread, in every mode. With background builds, the
  copy now builds through `SourceStudioCharacterBatch` like a duplicated
  character: it borrows the original's assembly, its second half runs on the
  build queue, and it installs on the main actor while its placeholder still
  shows the same record. An undo before it lands drops the build. Captures
  and scenarios build it in the command, as before.
- **Rig decode prefetch.** A first half without a donation names every rig
  file its card selects and starts all their decodes at once on workers, as
  soon as the card is read (`SourceRigDecodeShare.prefetch`). The decodes of
  a batch no longer queue behind each other in the order every preparation
  asks for them.
- **One command queue for the material compositors.** A compositor is made
  per composition, and each made its own Metal command queue. The first
  command buffer on a new queue waited about 8 ms before the GPU started it,
  so the second halves of the 7-character scene waited 173 ms for 1.6 ms of
  GPU work. All compositors of a device now share one queue.
- **Kept donations.** The assemblies of previews the Studio dropped with no
  rebuild waiting (a deleted character, a replaced outfit or scene, the copy
  an undone Duplicate removed) stay borrowable in `SourceStudioDonationCache`,
  bounded at 8 entries and 128 MiB of charge and emptied on memory pressure.
  The undo of a delete borrows its character's assembly instead of reading
  and decoding its files again.
- **The frame after an install.** While the live step runs, an install
  leaves the frame to the next step's refresh (within one 30 Hz period, 0.1 s
  at most), so the installs of one undo share a refresh, and the new
  character's pose is evaluated on the step's workers. Without live steps, or
  in a drag, it refreshes at once, as before.
- **Single-character builds.** An outfit selection and a plugin attachment's
  parent borrow a loaded or kept assembly of that outfit when one exists, and
  otherwise decode with the prefetch, still on the main thread. The export
  validation baseline decodes with the prefetch and borrows nothing, since it
  drops its preview after the export.
- **History fix.** An undo or redo that rehydrates the source runtime now
  refreshes once more after the rehydration. Before, the redo of a route
  Duplicate drew the copy without its character until something else
  refreshed (30,501 differing pixels in the hidden step of the new scenario).
- **Harness and scenario.** Three measurement controls,
  `IKKOKU_PERF_RIG_PREFETCH=off`, `IKKOKU_PERF_DONATIONS=off` and
  `IKKOKU_PERF_INSTALL_REFRESH=each`
  ([harness](#harness)), and the `studioInstallRefreshDeferred` event.
  `IKKOKU_PERF_ACTION_KEY` points `studio-duplicate` at route 0. The strict
  Studio lane's new `studio-scenario-background-build-route` check runs the
  `duplicateRoute` builds of the `backgroundBuild` op.

### Measurement

The commands follow [measuring a change](#measuring-a-change). Release builds,
arm64:

| Label | Commit | Executable SHA-256 |
| --- | --- | --- |
| base | `3baee04`: `main` `6502803` (#275) with this change's harness commit | `d082b8c4…e5a7d944` |
| after | `cd1c5a8` (this change before merging `main` `b4c59e7`, which adds the map and translated-vertex code these workloads never reach) | `aa6ce6d9…0696104f` |

Conditions:

- **Window.** All runs were in one quiet window the orchestrator granted on
  2026-10-25 (19:13–19:21). Base and after alternated, every launch was
  under the app lock, and the load average was 3.0–6.0.
- **Display.** A 120 Hz display; a `studio-idle` smoke run per build
  confirmed 120 Hz first.
- **Runs.** Each build ran `startup` three times, for the showoff scene and
  for the fixture scene (`IKKOKU_STUDIO_HALF_STATE_SCENE`). The action
  workloads recorded 30 s each, with live animation on:
  - `studio-duplicate` and `studio-undo-delete` on source key 963;
  - `studio-duplicate` on route 0 of `scene-route-children.png`
    (`IKKOKU_PERF_ACTION_KEY=0`).
- **Controls.** These ran on the after build with one change turned off:
  - `IKKOKU_PERF_RIG_PREFETCH=off`: showoff twice, fixture once;
  - `IKKOKU_PERF_DONATIONS=off`: `studio-undo-delete`;
  - `IKKOKU_PERF_INSTALL_REFRESH=each`: both `studio-duplicate` runs.
- **Single builds.** One character's synchronous build was timed in a
  release `swift test` probe in the same window, with no app running: 3
  characters of the scenario scene, 4 rounds, alternating order.
- **Flags.** `summarize` flagged no run.
- **Evidence.** Reports and analysis are in `.local/r7i-builds/window2`.

Startup, seconds since process start, median (range) of three runs:

| Scene | Build | Scene ready | First draw | Main thread until ready: busy of window ms | Longest busy period ms | Peak footprint MB |
| --- | --- | --- | --- | --- | --- | --- |
| showoff | base | 1.42 (1.41–1.42) | 0.42 (0.41–0.45) | 704 of 1,482 | 470 | 870 |
| showoff | after | 1.04 (1.04–1.05) | 0.47 (0.42–0.47) | 685 of 1,097 | 472 | 920 |
| showoff | after, prefetch off (2 runs) | 1.27 (1.26–1.27) | 0.42 | 683 of 1,329 | 458 | 870 |
| fixture | base | 1.08 (1.07–1.09) | 0.42 (0.40–0.44) | 618 of 1,125 | 457 | 544 |
| fixture | after | 0.78 (0.74–0.78) | 0.44 (0.43–0.48) | 623 of 814 | 283 (283–474) | 597 |
| fixture | after, prefetch off (1 run) | 1.00 | 0.41 | 557 of 989 | 441 | 543 |

- **Where the startup time went.** Of the showoff scene's 0.38 s, the
  prefetch gives 0.23 s (1.27 → 1.04 s with it off). The rest, about
  0.15 s, is the shared compositor queue. A release probe of the
  7-character batch agrees:
  - with the prefetch, the first halves took 464–515 ms instead of
    690–726 ms;
  - with the shared queue, the second halves took 342 ms instead of
    520 ms, and their compositor wait fell from 173 ms to 12 ms.
- **The main thread** does the same work until the scene is ready (about
  0.6–0.7 s, most of it the launch's window setup). It is busy for a larger
  share of a shorter window.
- **Peak footprint** grows by about 50 MB at startup, from the prefetch
  (870 MB with it off). More decodes are in flight at once, and their
  transient allocations overlap. Peak Metal memory is unchanged.

Actions, in ms: medians, with the range for the time until ready. In base,
the route copy's build runs inside the call, so its call is its time until
ready.

| Action (base and after counts) | Base: ready | Base: main busy | After: call | After: ready | After: main busy | After: longest busy period |
| --- | --- | ---: | ---: | --- | ---: | ---: |
| Duplicate (16 and 18) | 111 (101–115) | 44 | 3.1 | 84 (75–88) | 43 | 38 |
| Undo of the duplicate (16 and 18) | 531 (513–540) | 93 | 14.0 | 341 (329–362) | 80 | 59 |
| Duplicate of route 0 with its character (22 and 23) | 159 (153–165) | 182 | 2.4 | 97 (88–101) | 41 | 34 |
| Undo of the route duplicate (21 and 22) | 1.6 | 47 | 1.9 | 1.9 | 48 | 48 |
| Delete (14 and 19) | 4.2 | 42 | 3.7 | 3.7 | 43 | 43 |
| Undo of the delete (13 and 19) | 992 (977–1,014) | 78 | 13.5 | 351 (328–363) | 60 | 36 |

Controls on the after build:

| Control | Action | Ready | Main busy | Against after |
| --- | --- | --- | ---: | --- |
| `IKKOKU_PERF_DONATIONS=off` | undo of the delete | 663 (640–682) | 64 | kept donations save 312 ms |
| `IKKOKU_PERF_INSTALL_REFRESH=each` | undo of the duplicate | 345 (329–362) | 91 (83–95) | the deferred refresh saves 11 ms of main-thread work per undo, at the same ready time |
| `IKKOKU_PERF_INSTALL_REFRESH=each` | duplicate | 84 (80–91) | 45 | 2 ms |
| `IKKOKU_PERF_INSTALL_REFRESH=each` | route duplicate | 101 (91–105) | 43 | 2 ms |

With the refresh deferred, all 144 installs of the `studio-duplicate` run
(18 duplicates of one character, 18 undos of 7) left their frame to the
next live step (`studioInstallRefreshDeferred`).

Peak footprint over the action runs: duplicate 960 → 1,013 MB, route
592 → 641 MB, undo of delete 898 → 983 MB (956 MB with donations off). The
kept donations' charge is 13.0 MB per character.

One character's synchronous build, as an outfit selection, a plugin
attachment's parent or the export baseline runs it on the main thread (12
builds each):

| Build | Median ms | Range |
| --- | ---: | --- |
| From the files, without a share (base) | 627 | 612–635 |
| From the files, with the prefetching share (after, no donation) | 414 | 388–439 |
| From a donation (an outfit selected back, or a parent another preview shows) | 72 | 62–74 |

### What remains

- **Texture uploads (S3).** The second halves still load their textures
  synchronously, through `ResourceStore` and `MTKTextureLoader`: 51 ms over
  19 loads for the 7-character scene. They run on the build queue, not the
  main thread, one character at a time. An asynchronous load would save at
  most those 51 ms of the import's wall time and needs `ResourceStore` API
  changes, which this change does not make. The rest of the second halves'
  342 ms is CPU:
  - card bindings, about 113 ms;
  - the prepared appearance, about 180 ms;
  - the rig preview, about 80 ms;
  - 154 mesh registrations, about 66 ms.

  These overlap, since they are nested phases.
- **The launch's window setup** keeps the main thread busy for 457–475 ms
  until the window's first frame, in every build. This change does not
  address it. See [the launch window](#the-launch-window-setup) for its
  profile.
- **The first draw** came 0.02–0.05 s later with the prefetch in two of
  three runs per scene. The ranges overlap; the decodes running on workers
  during the window setup are the likely cause. Lowering the prefetch's QoS
  during the launch is a **hypothesis**.
- **Single-character builds still run on the main thread:**
  - an outfit selection: 414 ms, or 72 ms when the outfit was shown before
    and its assembly was kept;
  - a plugin attachment's parent: 414 ms, or 72 ms with a donation;
  - the export validation baseline of a hidden character with face edits:
    414 ms.

  Moving them off the main thread needs asynchronous callers: the outfit
  selection is a synchronous, throwing model call, and the baseline runs
  inside the export. The [third part](#phase-2-item-6-third-part-single-purpose-builds-rehydration-and-launch) gave the outfit selection and the
  export asynchronous callers and builds them in the background. The
  attachment's parent stays on the main thread.
- **Route characters of a rehydration** (a scene load, or the redo of a
  route Duplicate) still build in one batch on the main thread. The
  [third part](#phase-2-item-6-third-part-single-purpose-builds-rehydration-and-launch) builds them in the background.

### The launch window setup

Each build's system-wide Time Profiler recording was started before the
launch. It was cut from the process's first main-thread sample to the
app's `firstDraw` signpost, 0.42 s (base) and 0.43 s (after). The main
thread holds 277 and 270 ms of samples in that span; for the rest it was
not running (blocked in a call or waiting). The split is the same in both
builds:

| Inside | Base ms | After ms |
| --- | ---: | ---: |
| SwiftUI's attribute graph updates (`AG::Graph::UpdateStack::update`), the first view tree | 155 | 158 |
| `NSWindow` work, including its layout | 119 | 89 |
| `NSHostingView` | 55 | 51 |
| `AppState.init` | 34 | 35 |
| — `StudioModel.init` | 14 | 14 |
| — `SourceStudioAudioBus.init` | 13 | 12 |
| — `EngineHost.init` | 9 | 12 |
| — `GPUContext.init` | 6 | 9 |
| dyld (loading and binding) | 23 | 25 |
| `NSImage` | 11 | 11 |
| The import's prepare (`beginSourceSceneImport`) | 9 | 9 |

These overlap, since they are nested frames. Most of the window setup is
SwiftUI building and laying out the first view tree. The app's own
initializers take 35 ms, and the audio bus could be created on first use
(about 12 ms, a **hypothesis**). The [third part](#phase-2-item-6-third-part-single-purpose-builds-rehydration-and-launch) creates it on first
use. Its creation also waited about 63 ms for the audio system, so the
first draw came 0.10–0.12 s sooner. Reducing the rest means building less of
the view tree before the first frame, which is UI work outside this item.

### Correctness

After merging `main` `b4c59e7` (#276 maps, #277 translated vertex store),
on the merged head:

- **Captures.** Release builds of `main` `b4c59e7` and the merged head, each
  capture its own launch under the app lock, run from the same working
  directory (`.local/r7i-builds/captures`):
  - eight `IKKOKU_AUTOCAPTURE` renders: the Studio scenario scene, the
    fixture scene and the route-children scene, the native Studio, and the
    Maker. The scenario scene, the fixture and the Maker are also captured
    with the live source-shader opt-in ON;
  - two `IKKOKU_CAPTURE_UI` windows, Studio and Maker;
  - seven scenario reports: `topology-duplicate`, `undo-props`,
    `undo-route`, `reload-save-route`, `reload-save-duplicate`,
    `route-children-edit` and `reload-save-outfit`.

  All 10 PNGs and the 3 live opt-in reports are byte-identical. Six of the
  seven scenario reports are byte-identical. In `route-children-edit`, only
  one step's detail differs: the drag events' median and max time (1.37
  against 1.33 ms).
- **Engine tests.** These are new:
  - the prefetch without fixtures;
  - the prefetch's decode count in the 7-character batch;
  - the kept donation of a deleted character, rendered against a fresh
    build;
  - the donation cache's budget and eviction;
  - `rigFiles` against the decodes a preparation runs;
  - the shared compositor queue's bytes.

  See the [renderer reference](renderer.md#source-character-builds-r7-phase-2-item-6).
  The 12 tests of the decode share, the batch, the donation cache, the
  compositor queue and `rigFiles` pass under ThreadSanitizer with 0
  warnings, before and after the merge. No app TSan session was run: the
  app's new code runs only on the main actor, and its new concurrency is in
  these Engine types.
- **Scenario.** `studio-scenario-background-build-route` passes. Before the
  history fix, its hidden Redo differed from the synchronous one by 30,501
  pixels.
- **Lanes**, Debug, `--strict` under the app lock, 0 skipped:
  - `studio-scenarios` 78/78 (1,183.3 s), with the new check;
  - `maker-scenarios` 10/10 (196.7 s).
- **Engine suite** with the fixture map, in parallel: 986 tests. The only
  failure is the known `liveSourceShadersMeetTheControlledOriginalFrameGates`,
  with 13 named skips. The 21 tests of the second target pass.
- **Python.** All pass:
  - runner self-tests, 199;
  - `Tools/reverse`, 573 (6 skipped);
  - `Tools/reverse/analysis`, 279;
  - the site check and `doctor.py --require public`.
- **`viewport-lifecycle`** (after build) is clean. There was one render
  thread before each of the 12 steps and at the end, 85 frames were
  presented after the restore, and there were no keep-alive refreshes while
  minimized.

### Limits

- **Few runs.** Three startup runs per build and scene, one run per build
  of each action workload, and one to two runs per control.
- **The deferred refresh is not in the equality checks.** Scenarios pause
  live animation for byte-identical renders, so the deferral never applies
  there. It changes only when the frame is refreshed, never what is
  drawn, and a timer refreshes after 0.1 s at most.
- **The memory-pressure eviction** was not triggered in a run.
- **No M1 run** (estimate below).

### Scaling to a base M1 (estimate)

This uses the method of [scaling to the low end](#scaling-to-the-low-end-base-m1-8-gb):
serial CPU × 1.25, and parallel CPU spread over an M1's 6 workers (4
performance and 4 efficiency cores, less two).

- **Startup.** The prefetch runs the 10 distinct decodes across those 6
  workers instead of nearly in sequence, so it should save about as much
  as here, about 0.25–0.3 s. The shared queue's 0.16 s of start latency
  per batch does not depend on the CPU. The showoff scene should be ready
  about 1.5 s after launch, against the earlier estimate of 2 s.
- **Actions.** The estimates are:
  - a route Duplicate holds the main thread about 0.05 s instead of 0.2 s;
  - the undo of a delete is ready after about 0.45 s instead of 1.25 s;
  - an outfit selection takes about 0.55 s instead of 0.8 s.
- **Memory.** The kept donations hold at most 8 entries and 128 MiB of
  charge, about 104 MB for the reference scene's characters, and the
  memory-pressure warning empties them. The prefetch adds about 50 MB of
  transient peak at startup. Both fit in 8 GB, beside the scene's 0.9 GB.

## Phase 2, item 6, third part: single-purpose builds, rehydration and launch

Done 2026-10-26. This part moves the last source character builds a user
waits for off the main thread, except one:

- an outfit selection;
- the export validation baselines of hidden characters;
- the route characters of a rehydration (a scene load, or the redo of a
  route Duplicate).

The plugin attachment's parent stays on the main thread (see
[what remains](#what-remains-after-the-third-part)). The launch also no
longer creates the voices' audio graph.

On the reference machine:

- An outfit selection's call returns in 0.4 ms instead of holding the main
  thread for 91 ms with a kept assembly, or 439 ms from the files.
- An export with a hidden edited character returns in 1.3 ms instead of
  463 ms.
- The redo of a route Duplicate returns in 17 ms instead of 178 ms.
- A scene load returns in 13 ms instead of 463 ms.

In every case the result is drawn about as soon as before. The main
thread's work per action falls from 88–487 ms to 25–59 ms, or 128 ms for
the redo, most of which is SwiftUI. The first frame of the
window comes 0.10–0.12 s sooner, and the scenes are ready 0.07–0.09 s
sooner.

Once a build lands, the user sees the same characters, poses and pixels as
before. Captures and exports are byte-identical, and so are the scenario
reports apart from two drag timings (Correctness, below); only time,
threads and memory change.

### What changed

The contract is in
[source character builds](renderer.md#source-character-builds-r7-phase-2-item-6)
("Single-purpose builds in the background").

- **Outfit selection.** `selectSourceOutfit` makes the synchronous call's
  checks, then builds the outfit with both halves on the build queue. It
  borrows a kept assembly when one matches. The build runs in
  `SourceStudioBackgroundBuilds`, a new main-actor registry of keyed
  builds. `finishSourceOutfit` applies it on the main actor with one undo
  step, as `setSourceOutfit` does.
- **Export validation baselines.** `beginSourceSceneExport` builds the
  baselines of the hidden characters in one batch, in document order, then
  runs the unchanged `exportSourceScene(to:baselines:)` on the main actor.
  The job keeps a snapshot of the inputs it exports: the document, the
  camera looked through, and the routes' play flags. If any of them changes
  before the baselines land, the export fails and writes nothing.
- **Route characters of a rehydration.** The rehydration's walk lists the
  route characters instead of building them. It installs the runtime, then
  starts their builds like a Duplicate's route copies.
  - A route copy cancelled before its preview landed now leaves the runtime
    coverage, so the next rehydration builds it.
- **The launch's audio bus.** `StudioModel.sourceAudioBus` is created on
  first use: a voice played, a plugin that reads or writes the master
  volume, or a tone check.
- **Harness and scenario.**
  - Four action workloads: `studio-redo`, `studio-outfit`, `studio-export`
    and `studio-load`.
  - `IKKOKU_PERF_OUTFIT`, and `PerfTrace.backgroundWorkFinished` for work
    other than an install.
  - The `backgroundBuild` scenario op gains the builds `outfit`,
    `outfitWhileHidden`, `export` and `loadRoute`.
  - `duplicateRoute` now checks that the Redo builds no route preview on the
    main thread.
  - The strict Studio lane's two `background-build` checks run these steps
    ([harness](#harness)).

**What the user sees while each build runs, and why it matches the
contract.** The contract is that the commit runs on the main actor in the
original order, that cancellation leaves no half-built state, that errors
keep their diagnostics, and that captures and scenarios build inside the
command.

| Build | While it runs | When it lands | Why that matches |
| --- | --- | --- | --- |
| Outfit selection | The character keeps its outfit, is drawn and stays editable. The picker shows the outfit chosen; the status area shows "Building 1 source character". | The new outfit is drawn with the document's edits as they are then, as one undo step. A failure keeps the outfit and shows the synchronous message ("Outfit: …"). | The install and the undo step run on the main actor, only while the character still shows the preview the build was made on. A newer selection supersedes it, choosing the shown outfit cancels it, and an undo or redo, import, load, New Scene or deletion drops it, so nothing half-built reaches the document. A landing while the Maker is shown keeps the Maker's frame. Captures and scenarios call `setSourceOutfit` in the command. |
| Export baselines | The scene stays editable, and the status area shows "Exporting <file>". | The file is written with the scene as it was when the export was chosen. If the document, camera or route play state changed, it fails with "the scene changed while the hidden characters of <file> were built; export it again". An import, load or New Scene fails it with "the scene was replaced before …". | The export itself runs unchanged on the main actor, from the snapshot it was chosen with, so its bytes match the synchronous export's. A changed or replaced scene writes nothing, and the error goes to the alert the synchronous export used. While plugins run, it exports synchronously, since their steps write the document. |
| Route characters of a rehydration | A route character already shown for the same record keeps its preview until its rebuild lands. One not shown yet (after New Scene, a load, the redo of a route Duplicate) draws nothing, and objects attached to it wait without a message, as for a Duplicate's copy. | Each character installs in walk order on the main actor. A failure leaves the placeholder drawing nothing without a message, as the synchronous rehydration did. | It installs only while the placeholder shows the same record of the same scene. An undo, import, load or New Scene cancels it, and a cancelled character leaves the runtime coverage so the next rehydration builds it. Captures and scenarios build in the walk. |

### Measurement

The commands follow [measuring a change](#measuring-a-change). Release builds,
arm64:

| Label | Commit | Executable SHA-256 |
| --- | --- | --- |
| base | `15ba445`: `main` `3bfcc37` (#280) with this change's harness commits | `4280119e…6f36da6` |
| after | `e21a915` (this change before merging `main` `e7085c3`, #281 Maker pacing, which these workloads do not reach) | `1b5b7baa…827a3a7` |

Conditions:

- **Window.** One quiet window the orchestrator granted on 2026-10-26
  (00:02–00:10). Base and after alternated within each phase, every launch
  was under the app lock, and the load average was 2.6–4.0.
- **Display.** A 120 Hz display; a `studio-idle` smoke run per build
  confirmed 120 Hz first.
- **Runs.** `startup` ran three times per build for the showoff scene and
  for the fixture scene (`IKKOKU_STUDIO_HALF_STATE_SCENE`). The action
  workloads recorded 30 s each with live animation on:
  - `studio-outfit` on source key 963 (outfit 2 "After school", then 1
    "School uniform" back), with and without kept donations
    (`IKKOKU_PERF_DONATIONS=off`);
  - `studio-export`;
  - `studio-redo` and `studio-load` on `scene-route-children.png`, route 0
    (`IKKOKU_PERF_ACTION_KEY=0`).
- **Time Profiler.** System-wide recordings (`--all-processes`, a time
  limit, started before the launch, never `--launch`). One startup per
  build, and 15 s of `studio-redo` on the after build.
- **Evidence.** Reports, traces and analysis are in
  `.local/r7j-main-builds/window1`.

Actions, in ms: medians, with each run's action count. In base, every build
here runs inside the call, so its call is its time until ready.

| Action (base and after counts) | Base: call = ready | Base: main busy | After: call | After: ready | After: main busy | After: longest busy period |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Outfit, kept assembly (21 and 21) | 91 | 94 | 0.4 | 105 | 25 | 16 |
| Outfit back, kept assembly (21 and 20) | 85 | 88 | 0.2 | 104 | 25 | 14 |
| Outfit from the files, donations off (15 and 14) | 439 | 442 | 0.4 | 450 | 31 | 17 |
| Outfit back from the files (14 and 14) | 436 | 439 | 0.4 | 452 | 31 | 15 |
| Export with a hidden edited character (31 and 30) | 463 | 465 | 1.3 | 475 | 50 | 29 |
| Redo of a route Duplicate (12 and 12) | 178 | 255 | 16.9 | 173 | 128 | 119 |
| Scene load over New Scene (25 and 25) | 463 | 487 | 12.7 | 466 | 59 | 51 |

- **Ready times.** The selected outfit is drawn 11–19 ms later than the
  synchronous one. That is the queue hop and the install's turn on the main
  actor; meanwhile the main thread stays free. The export is written 12 ms
  later. The redo is ready 5 ms sooner and the load 4 ms later.
- **Unchanged actions.** The redo workload's other actions did not change:
  - Select: 101 → 104 ms busy;
  - Duplicate: 41 → 42 ms;
  - Undo: 51 → 53 ms;
  - Undo of the redo: 49 → 49 ms.
- **Peak footprint**, base → after:
  - outfit: 1,009 → 993 MB, or 1,042 → 1,064 MB without donations;
  - export: 907 → 888 MB;
  - redo: 747 → 717 MB;
  - load: 648 → 642 MB.

Startup, seconds since process start, median (range) of three runs:

| Scene | Build | Scene ready | First draw | `appStateReady` | Main thread until ready: busy of window ms | Longest busy period ms | Peak footprint MB |
| --- | --- | --- | --- | --- | --- | --- | --- |
| showoff | base | 1.03 (0.98–1.08) | 0.43 (0.40–0.47) | 0.22 | 668 of 1,084 | 473 | 970 |
| showoff | after | 0.94 (0.91–0.98) | 0.31 (0.30–0.33) | 0.11 | 583 of 1,000 | 375 | 959 |
| fixture | base | 0.74 (0.73–0.78) | 0.47 (0.39–0.47) | 0.20 | 620 of 784 | 467 | 624 |
| fixture | after | 0.67 (0.66–0.67) | 0.37 (0.34–0.37) | 0.10 | 542 of 720 | 300 | 626 |

**The launch.** The startup recordings were cut from the process's first
main-thread sample to `firstDraw`:

| Inside | Base ms | After ms |
| --- | ---: | ---: |
| Main-thread samples until the first draw (span) | 283 (0.45 s) | 249 (0.32 s) |
| SwiftUI's attribute graph updates | 162 | 140 |
| `NSWindow` work, including its layout | 104 | 90 |
| `NSHostingView` | 58 | 52 |
| `AppState.init` | 37 | 21 |
| — `StudioModel.init` | 16 | 1 |
| — `SourceStudioAudioBus.init` | 15 | — |
| dyld | 19 | 21 |

The bus cost more than its samples show. In base, `SourceStudioAudioBus.init`
spans 102 ms of wall time but holds 15 ms of samples. Most of the rest is
one 63 ms wait in `mach_msg`, the audio system's reply. With it created on
first use, `appStateReady` moves from about 0.21 s to 0.11 s and the first
draw 0.10–0.12 s earlier. The other window setup is unchanged: SwiftUI's
first view tree, `NSWindow` layout and `NSHostingView`. Under SwiftUI's
graph updates the app's view bodies take about 1 ms. The rest is framework
work (layout, preferences, and the key-view loop at about 57 ms) that this
change does not trim.

### What remains after the third part

- **A plugin attachment's parent** still builds on the main thread: 414 ms,
  or 72 ms when it borrows a kept assembly (the
  [follow-up](#phase-2-item-6-follow-up-route-copies-prefetch-and-kept-donations)'s
  numbers). The synchronous plugin callbacks need the result in the call:
  `pluginAttachmentFrame` answers with the parent's bone frame, and
  `PluginAttachmentRestorePreparation` restores an attachment inside a load.
  Moving it needs an asynchronous plugin attachment API.
- **Texture uploads (S3)** stay synchronous on the build queue: 51 ms over
  19 loads for the 7-character scene, off the main thread. Loading them
  concurrently would move `MTKTextureLoader` work into the first halves.
  That changes the order in which `ResourceStore`'s cache is filled and
  needs new `ResourceStore` entry points, which another lane depends on.
  This change makes no `ResourceStore` change.
- **The redo's remaining main-thread time.** The redo of a route Duplicate
  still holds the main thread for about 119 ms after its 17 ms call. The
  15 s recording of `studio-redo` (after build, 6 redos) attributes it:
  - about 15 ms of app work per redo: `refresh` about 9 ms, and the
    rehydration's runtime build about 7.5 ms. That build includes route
    preparation, clock rebuilds and `EngineHost.locateMakerLibrary` (about
    3.7 ms, which could be cached);
  - about 105 ms of SwiftUI, which creates and lays out the inspector's
    Object tab again, because the redone duplicate is still the selection.
    The selection's SwiftUI update below has the same parts.
- **Selection's SwiftUI update.** Select spends the same kind of time: 101
  and 104 ms busy per select in base and after. In this workload, Select
  replaces the inspector's "Nothing selected" placeholder with route 0's
  Object tab. The Undo before it leaves the selection on the removed
  duplicate, so `ObjectInspector` shows the placeholder. That tab has the
  name field, the transform's three `VectorRow`s (a rounded `TextField` and
  a `Stepper` per axis), the route's point picker and point controls, and
  caption text. The recording's 4 selects take 442 ms of the main thread.
  Per select (these overlap, since they are nested frames):
  - **Layout: about 82 ms.** It is mostly `sizeThatFits` (about 38 ms)
    under `ScrollView` layout (about 34 ms), Text measurement (about
    22 ms), and the `TextField`s and `Stepper`s (about 12 and 11 ms).
  - **Creating the views: about 18–20 ms.** `makeView` and the view lists,
    with Swift generic-metadata instantiation. The `TextField`s'
    `NSTextField` creation and update (`PlatformTextFieldAdaptor`) take
    about 7.5 ms.
  - **The display list update: about 25 ms.**
  - **Observation: about 4.5 ms.** The selection setter and `selectedBone`'s
    `didSet` take about 1.3 ms, and the frame refresh about 1.8 ms.
  - **App view bodies: under 1 ms.** No body getter stands out
    (`ObjectInspectorContent`, `VectorRow`, `StudioTimelineControls`).

  So no view body and no observation path dominates. The cost is SwiftUI
  creating the Object tab's subtree and laying out its AppKit-backed fields
  in the inspector's `ScrollView`. The fix is UI work for a later slice.
  Two candidates:
  - keep the Object tab's structure mounted across selections, including
    from the placeholder;
  - give the inspector's rows fixed sizes, so layout does not measure every
    field and text.

  A selection between two objects, without the placeholder, was not
  measured.
- **The launch's window setup** above.

### Correctness

After merging `main` `4512842` (#279 lightmaps, #282 and #283 material
gates and lipline, #284 plugin data), on the merged head `2231888`. The base
is a Release build of `main` `4512842`. Both sides used one snapshot of the
fixture map (113 keys), taken after #283 changed it.

- **Captures.** Release builds of the base and the merged head, each
  capture its own launch under the app lock
  (`.local/r7j-main-builds/captures`):
  - eight `IKKOKU_AUTOCAPTURE` renders: the Studio scenario scene, the
    fixture scene and the route-children scene, the native Studio, and the
    Maker. The scenario scene, the fixture and the Maker are also captured
    with the live source-shader opt-in ON;
  - two `IKKOKU_CAPTURE_UI` windows, Studio and Maker;
  - ten scenario reports: `topology-duplicate`, `undo-props`,
    `undo-route`, `reload-save-route`, `reload-save-duplicate`,
    `route-children-edit`, `reload-save-outfit`, `route-edit-export`,
    `reload-save-expression` and `reload-load-expression`;
  - the six scene files those scenarios export. One of them is
    `reload-load-expression`'s, whose export builds the validation
    baseline of a hidden edited character inside the command.

  All 10 PNGs, the 3 live opt-in reports and the 6 exported scene files
  are byte-identical. Eight of the ten scenario reports are byte-identical.
  In `route-children-edit` and `route-edit-export`, only the drag events'
  median and max times differ.

  Two things made a base and an after differ although neither change was
  involved:
  - **The source-tree fallback.** Scenario launches keep the fallback on,
    which reads the Maker library from the compiling checkout's
    `.local/reverse`. A base built in a worktree without it exported a
    different `topology-duplicate` thumbnail. Both worktrees link
    `.local/reverse`.
  - **The window state.** `viewport-lifecycle` changes the saved window
    frame, so a window captured after it is 52 pt shorter and looks
    inactive. The window captures of both builds run before it.
- **Engine tests.** These are new:
  - the registry completes only the newest build of a key and runs no
    completion after a cancel;
  - with the fixtures, a second outfit selection supersedes the first, and
    only the second lands. Its diagnostics and a render match a synchronous
    build of that outfit. An export's baselines land at once, in request
    order, and match sequential builds;
  - with the fixtures, a build cancelled while its delivery waits for the
    main actor completes nothing, and the store holds what it held before;
  - `IKKOKU_PERF_OUTFIT` parsing.

  The 14 tests of the registry, the batch and the donation cache pass under
  ThreadSanitizer with 0 warnings, before and after the merge. No app TSan
  session was run: the app's new code runs only on the main actor, and its
  new concurrency is in these Engine types.
- **Scenario.** These checks pass:
  - `studio-scenario-background-build`, with the outfit, hidden-outfit and
    export steps;
  - `studio-scenario-background-build-route`, with the Redo and `loadRoute`
    steps, which require that no route character preview is built on the
    main thread.

  Each compares the background build with the synchronous one: the
  document summary and a 512×512 render are byte-identical, and the export
  writes the synchronous export's bytes.
- **Lanes**, Debug, `--strict` under the app lock, 0 skipped:
  - `studio-scenarios` 78/78 (1,247.7 s), with both background-build
    checks;
  - `maker-scenarios` 10/10 (202.6 s).
- **Engine suite** with the fixture map, in parallel, at a parallelization
  width of 8 (`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=8`, while
  wider runs can stall in `MTKTextureLoader`). 1,022 tests pass, with 7
  named skips and no stall, and the 21 tests of the second target pass. The
  usually failing `liveSourceShadersMeetTheControlledOriginalFrameGates`
  passed in this run.
- **Python.** All pass:
  - runner self-tests, 201;
  - `Tools/reverse`, 601 (6 skipped);
  - `Tools/reverse/analysis`, 280;
  - the site check and `doctor.py --require public`.
- **`viewport-lifecycle`** (after build) is clean, run after the window
  captures. There was one render thread before each of the 12 steps and at
  the end, 87 frames were presented after the restore, and there were no
  keep-alive refreshes while minimized.

### Limits

- **Few runs.** One run per build of each action workload, and three
  startup runs per build and scene.
- **Only one form of each action was measured.** The outfit workload selects
  between two outfits of one character, and the export has one hidden
  character to build. The redo and load use the route-children scene.
- **Edits during a build are not measured.** The scenario checks their
  results but not their timing.
- **No M1 run** (estimate below).

### Scaling to a base M1 (estimate)

This uses the method of [scaling to the low end](#scaling-to-the-low-end-base-m1-8-gb):
serial CPU × 1.25.

- **Main thread.** The main-thread work per action is 25–59 ms here, about
  0.03–0.07 s on an M1, instead of 0.1–0.6 s:
  - an outfit selection from the files no longer holds it for about 0.55 s;
  - an export, about 0.58 s;
  - a scene load, about 0.6 s.

  The redo still holds it for about 0.16 s, mostly SwiftUI, as does a
  selection that builds the Object tab (about 0.13 s).
- **Ready times.** These follow the single builds, which now run on the
  build queue: about 0.55 s for an outfit from the files, and 0.13 s with a
  kept assembly.
- **Launch.** The audio bus's wait is the audio system's reply, not CPU, so
  the first draw should come about 0.1 s sooner there too.
- **Memory.** Unchanged: the builds hold what the synchronous builds held,
  for the same time.

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
