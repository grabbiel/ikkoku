import Foundation
import AppKit
import QuartzCore
import Metal
import os
import GPU
import Renderer

/// Frame-phase signposts and the opt-in `IKKOKU_PERF_TRACE` recorder (R7).
///
/// Signposts go to the Points of Interest category of the
/// `com.grabbiel.IkkokuCreator` subsystem, so Instruments' Time Profiler,
/// Metal System Trace, SwiftUI and Animation Hitches templates show the
/// app's own phases (display-link draw, input handlers, Maker tick/refresh,
/// startup steps) beside their samples. Emitting them costs a few
/// nanoseconds when no tool records.
enum PerfSignpost {
    nonisolated static let signposter = OSSignposter(subsystem: "com.grabbiel.IkkokuCreator", category: .pointsOfInterest)

    /// Runs `body` inside a named signpost interval.
    @inline(__always)
    nonisolated static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}

/// Per-frame recorder for `IKKOKU_PERF_TRACE=<report.json>` (see
/// `docs/reference/performance.md`). Nil unless that variable is set, so the
/// hooks below cost one optional check in a normal launch.
///
/// It records:
/// - every `CAMetalDisplayLink` callback, on the thread that runs it
///   (`PerfDrawLog`): when it ran, the frame it targeted, how long
///   `Renderer.draw` took (preparation + encoding + any wait for a frame
///   slot), the renderer's most recent GPU time (`gpuEndTime - gpuStartTime`
///   of the last completed command buffer) and whether it ran on the main
///   thread;
/// - when each drawable was actually presented (`addPresentedHandler`), which
///   yields presented-frame intervals and hitches;
/// - on the main thread, each main run-loop busy period (after-waiting to
///   before-waiting), so main-thread time not spent drawing, in the model or
///   in the optional synthetic load (`IKKOKU_PERF_MAIN_LOAD_MS`) is visible
///   as "other" (SwiftUI updates, layout, AppKit event handling);
/// - model work: Maker and Studio ticks and refreshes, the Studio's camera-only
///   frame rebuilds (explicit hooks in `MakerModel` and `StudioModel`) and
///   every input handler call;
/// - model events: Studio document changes and camera-only changes;
/// - SwiftUI body evaluations of the Studio and Maker panels (`ViewBody`), so a
///   report shows which views an edit re-evaluated;
/// - process footprint, Metal allocation and CPU time.
@MainActor
final class PerfTrace {
    static private(set) var active: PerfTrace?

    /// Phases with their own sample lists.
    enum Phase: String, CaseIterable {
        case draw, studioTick, studioRefresh, studioCameraRefresh, makerTick, makerRefresh, input
        /// Applying finished hover picks on the main actor (R7 phase 2, item 5),
        /// including the refresh when the highlight changes.
        case studioHoverPick
        /// The synthetic main-thread load (`IKKOKU_PERF_MAIN_LOAD_MS`); not model time.
        case mainLoad

        /// Model phases: ticks, refreshes and input calls (they nest).
        var isModel: Bool { self != .draw && self != .mainLoad }
    }

    /// Model events counted per recording (no duration).
    enum Event: String, CaseIterable {
        /// A write to the Studio document other than through the camera
        /// accessor; each one re-evaluates every view that reads the document.
        case studioDocChange
        /// A write through the Studio's camera accessor (orbit, pan, dolly,
        /// camera slots), which only the camera's readers observe.
        case studioCameraChange
        /// A hover pick started (a mouse move with none in flight, or a stale
        /// result picked again; R7 phase 2, item 5).
        case hoverPickStarted
        /// A mouse move that waited because a hover pick was in flight.
        case hoverPickCoalesced
    }

    /// SwiftUI bodies counted per recording. A count is one evaluation of that
    /// view's body (or, for the panels a parent builds inline, of the parent's
    /// builder for it), so a per-event rate says what one edit re-evaluated.
    /// The names stay stable across view restructuring so reports compare.
    enum ViewBody: Int, CaseIterable {
        case appCommands, contentView
        case studioWindow, studioWorkspace, studioWorkspaceRow, studioToolbar, studioTimeline, studioInspector, studioStatus
        case objectInspector, poseInspector, sourcePoseInspector, sourceAnimationInspector, faceInspector, clothesInspector, sceneInspector
        case makerWindow, makerRigPanel, makerShapeRow

        var name: String { String(describing: self) }
    }

    struct Configuration {
        let output: URL
        let workload: String
        let seconds: Double
        let warmupSeconds: Double
        let windowPoints: CGSize
        let inputHz: Double
        let nativeCharacters: Int
        /// Busy-waits this long on the main thread `mainLoadHz` times per
        /// second while recording (0: no load). It stands for main-thread work
        /// such as a slow tick or layout pass, so a report can show whether
        /// presentation still keeps pace when the main thread is busy.
        let mainLoadMilliseconds: Double
        let mainLoadHz: Double

        /// Reads `IKKOKU_PERF_*`; `CaptureRequest.validate` already checked the values.
        static func from(_ env: [String: String]) -> Configuration? {
            guard let path = env["IKKOKU_PERF_TRACE"] else { return nil }
            func int(_ name: String, _ fallback: Int) -> Int { env[name].flatMap { Int($0) } ?? fallback }
            return Configuration(
                output: URL(fileURLWithPath: path),
                workload: env["IKKOKU_PERF_WORKLOAD"] ?? "studio-idle",
                seconds: Double(int("IKKOKU_PERF_SECONDS", 10)),
                warmupSeconds: Double(int("IKKOKU_PERF_WARMUP_SECONDS", 3)),
                windowPoints: CGSize(width: int("IKKOKU_PERF_WINDOW_W", 1600), height: int("IKKOKU_PERF_WINDOW_H", 1000)),
                inputHz: Double(int("IKKOKU_PERF_INPUT_HZ", 120)),
                nativeCharacters: int("IKKOKU_PERF_CHARACTERS", 6),
                mainLoadMilliseconds: Double(int("IKKOKU_PERF_MAIN_LOAD_MS", 0)),
                mainLoadHz: Double(int("IKKOKU_PERF_MAIN_LOAD_HZ", 30)))
        }
    }

    let configuration: Configuration
    /// Wall-clock process start (`kinfo_proc.p_starttime`) and the media-time
    /// origin that startup marks are measured from.
    private let processStartWall: Double
    private let originMedia: CFTimeInterval
    private let originWall: Double

    private(set) var marks: [(name: String, seconds: Double)] = []
    private(set) var recording = false
    private var recordStart: CFTimeInterval = 0
    private var recordEnd: CFTimeInterval = 0

    private var intervals: [Phase: [(start: CFTimeInterval, end: CFTimeInterval)]] = [:]
    private var inputNames: [String: Int] = [:]
    private var eventCounts: [Event: Int] = [:]
    /// Finished hover picks: applied or stale, start-to-main-actor latency and GPU time (ms).
    private var hoverPicks: [(applied: Bool, latency: Double, gpu: Double)] = []
    private var bodyCounts = [Int](repeating: 0, count: ViewBody.allCases.count)
    private var busy: [(start: CFTimeInterval, end: CFTimeInterval)] = []
    private var busyStart: CFTimeInterval?
    private var observers: [CFRunLoopObserver] = []
    private var memoryTimer: Timer?
    private var peakFootprint: UInt64 = 0
    private var peakMetal: Int = 0
    private var cpuAtStart: (process: Double, main: Double) = (0, 0)
    private var cpuAtEnd: (process: Double, main: Double) = (0, 0)
    private var occludedSamples = 0
    private var memorySamples = 0
    /// Display-link draws, recorded by the thread that runs the callback.
    nonisolated let drawLog = PerfDrawLog()
    var device: (any MTLDevice)?
    /// Free-form facts the workload driver adds (inputs, selections, hashes).
    var details: [String: Any] = [:]

    private init(configuration: Configuration) {
        self.configuration = configuration
        originMedia = CACurrentMediaTime()
        originWall = Date().timeIntervalSince1970
        processStartWall = PerfTrace.processStartTime() ?? originWall
    }

    /// Creates the recorder when `IKKOKU_PERF_TRACE` is set. Called first thing in `AppState.init`.
    static func startIfRequested(_ env: [String: String]) {
        guard active == nil, let configuration = Configuration.from(env) else { return }
        let trace = PerfTrace(configuration: configuration)
        active = trace
        trace.mark("appStateInit")
        trace.installRunLoopObservers()
    }

    // MARK: Startup marks

    /// Seconds since process start (wall clock) of a startup step.
    static func mark(_ name: String) {
        PerfSignpost.signposter.emitEvent("Mark", "\(name, privacy: .public)")
        active?.mark(name)
    }
    private func mark(_ name: String) {
        marks.append((name, secondsSinceProcessStart(media: CACurrentMediaTime())))
    }

    private func secondsSinceProcessStart(media: CFTimeInterval) -> Double {
        originWall + (media - originMedia) - processStartWall
    }

    /// Times one startup step as a mark pair and a signpost interval.
    static func step<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        mark("\(name).begin")
        let state = PerfSignpost.signposter.beginInterval("Startup", id: PerfSignpost.signposter.makeSignpostID(), "\(name, privacy: .public)")
        defer { PerfSignpost.signposter.endInterval("Startup", state); mark("\(name).end") }
        return try body()
    }

    // MARK: Hooks

    /// Records a model or input phase that ran between `start` and `end`.
    func record(_ phase: Phase, start: CFTimeInterval, end: CFTimeInterval, name: String? = nil) {
        guard recording else { return }
        intervals[phase, default: []].append((start, end))
        if let name { inputNames[name, default: 0] += 1 }
    }

    /// Wraps a model phase in a signpost and, while recording, a sample.
    static func measure<T>(_ phase: Phase, _ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = PerfSignpost.signposter.beginInterval(name, id: PerfSignpost.signposter.makeSignpostID())
        guard let trace = active, trace.recording else {
            defer { PerfSignpost.signposter.endInterval(name, state) }
            return try body()
        }
        let start = CACurrentMediaTime()
        defer {
            PerfSignpost.signposter.endInterval(name, state)
            trace.record(phase, start: start, end: CACurrentMediaTime())
        }
        return try body()
    }

    /// One viewport input handler call (real events and injected workload input alike).
    static func input(_ name: StaticString, _ body: () -> Void) {
        let state = PerfSignpost.signposter.beginInterval("Input", id: PerfSignpost.signposter.makeSignpostID(), "\(name)")
        let start = CACurrentMediaTime()
        body()
        PerfSignpost.signposter.endInterval("Input", state)
        active?.record(.input, start: start, end: CACurrentMediaTime(), name: "\(name)")
    }

    /// Counts one model event while recording.
    static func event(_ event: Event) {
        guard let trace = active, trace.recording else { return }
        trace.eventCounts[event, default: 0] += 1
    }

    /// One finished hover pick taken on the main actor while recording:
    /// whether it applied, seconds since it started, its GPU time in seconds.
    static func hoverPick(applied: Bool, latency: Double, gpuTime: Double) {
        guard let trace = active, trace.recording else { return }
        trace.hoverPicks.append((applied, latency * 1000, gpuTime * 1000))
    }

    /// Counts one SwiftUI body evaluation while recording; called as
    /// `let _ = PerfTrace.body(.name)` at the top of the body. Costs one
    /// optional check when no trace runs.
    @inline(__always)
    static func body(_ view: ViewBody) {
        guard let trace = active, trace.recording else { return }
        trace.bodyCounts[view.rawValue] += 1
    }

    // MARK: Recording window

    func beginRecording() {
        drawLog.setRecording(true)
        intervals = [:]; inputNames = [:]; busy = []
        eventCounts = [:]; hoverPicks = []; bodyCounts = [Int](repeating: 0, count: ViewBody.allCases.count)
        peakFootprint = PerfTrace.footprint(); peakMetal = device?.currentAllocatedSize ?? 0
        cpuAtStart = PerfTrace.cpuSeconds()
        recordStart = CACurrentMediaTime()
        recording = true
        // The static `mark` also emits the signpost xctrace windows on.
        PerfTrace.mark("recordingBegin")
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { PerfTrace.active?.sampleMemory() }
        }
        RunLoop.main.add(timer, forMode: .common)
        memoryTimer = timer
    }

    func endRecording() {
        guard recording else { return }
        recording = false
        drawLog.setRecording(false)
        recordEnd = CACurrentMediaTime()
        cpuAtEnd = PerfTrace.cpuSeconds()
        sampleMemory()
        memoryTimer?.invalidate(); memoryTimer = nil
        PerfTrace.mark("recordingEnd")
    }

    private func sampleMemory() {
        peakFootprint = max(peakFootprint, PerfTrace.footprint())
        peakMetal = max(peakMetal, device?.currentAllocatedSize ?? 0)
        memorySamples += 1
        if let window = NSApp.windows.first(where: { $0.isVisible }), !window.occlusionState.contains(.visible) { occludedSamples += 1 }
    }

    private func installRunLoopObservers() {
        let main = CFRunLoopGetMain()
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { PerfTrace.active?.busyStart = CACurrentMediaTime() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                guard let trace = PerfTrace.active, let start = trace.busyStart else { return }
                trace.busyStart = nil
                if trace.recording { trace.busy.append((start, CACurrentMediaTime())) }
            }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(main, observer, .commonModes)
            observers.append(observer)
        }
    }

    // MARK: Report

    /// Writes the JSON report and returns its path.
    func writeReport() throws -> URL {
        let report = makeReport()
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: configuration.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configuration.output)
        return configuration.output
    }

    private func makeReport() -> [String: Any] {
        let window = max(recordEnd - recordStart, 1e-9)
        let screen = NSApp.windows.first(where: { $0.isVisible })?.screen ?? NSScreen.main
        let refreshHz = Double(screen?.maximumFramesPerSecond ?? 60)
        let period = 1 / refreshHz
        let drawn = drawLog.snapshot()
        let frames = drawn.samples
        let presented = drawLog.presentLog.snapshot()
        var presentedTimes: [Double] = []
        var dropped = 0
        for frame in frames {
            guard frame.presentLogIndex >= 0, frame.presentLogIndex < presented.count else { continue }
            let t = presented[frame.presentLogIndex]
            if t > 0 { presentedTimes.append(t) } else { dropped += 1 }
        }
        presentedTimes.sort()
        let presentedIntervals = zip(presentedTimes.dropFirst(), presentedTimes).map { ($0 - $1) * 1000 }
        // A hitch is a presented interval longer than 1.5 refresh periods; the
        // frames it skipped are its length in periods minus one.
        let hitchIntervals = presentedIntervals.filter { $0 > 1.5 * period * 1000 }
        let skippedRefreshes = hitchIntervals.reduce(0) { $0 + max(0, Int(($1 / (period * 1000)).rounded()) - 1) }
        let callbackIntervals = zip(frames.dropFirst(), frames).map { ($0.callback - $1.callback) * 1000 }
        let targetSkips = zip(frames.dropFirst(), frames).reduce(0) { total, pair in
            total + max(0, Int(((pair.0.targetPresentation - pair.1.targetPresentation) / period).rounded()) - 1)
        }

        func durations(_ phase: Phase) -> [Double] { (intervals[phase] ?? []).map { ($0.end - $0.start) * 1000 } }
        let draw = frames.map(\.drawMilliseconds)
        let gpu = frames.map(\.gpuMilliseconds).filter { $0 > 0 }
        let busyTotal = busy.reduce(0) { $0 + ($1.end - $1.start) } * 1000
        // Only callbacks that ran on the main thread take main run-loop time;
        // a render thread's draws are reported on their own.
        let mainDrawTotal = frames.filter(\.onMainThread).reduce(0) { $0 + $1.drawMilliseconds }
        let renderDraws = frames.filter { !$0.onMainThread }
        let renderDrawTotal = renderDraws.reduce(0) { $0 + $1.drawMilliseconds }
        // Model time: the union of every model phase (ticks, refreshes and
        // input calls nest), so nothing counts twice.
        let modelTotal = PerfTrace.unionSeconds(Phase.allCases.filter(\.isModel).flatMap { intervals[$0] ?? [] }) * 1000
        let loadTotal = durations(.mainLoad).reduce(0, +)
        let other = max(0, busyTotal - mainDrawTotal - modelTotal - loadTotal)

        var phases: [String: Any] = [:]
        for phase in Phase.allCases {
            let samples = phase == .draw ? draw : durations(phase)
            guard !samples.isEmpty else { continue }
            var entry = PerfTrace.statistics(samples)
            entry["perSecond"] = Double(samples.count) / window
            entry["msPerSecond"] = samples.reduce(0, +) / window
            phases[phase.rawValue] = entry
        }
        if !gpu.isEmpty { phases["gpu"] = PerfTrace.statistics(gpu) }

        let summary: [String: Any] = [
            "recordedSeconds": window,
            "displayRefreshHz": refreshHz,
            "displayLinkCallbacks": frames.count,
            "displayLinkIntervalMs": PerfTrace.statistics(callbackIntervals),
            "displayLinkTargetSkips": targetSkips,
            "presentedFrames": presentedTimes.count,
            "presentedFPS": Double(max(presentedTimes.count - 1, 0)) / max((presentedTimes.last ?? 0) - (presentedTimes.first ?? 0), 1e-9),
            "presentedIntervalMs": PerfTrace.statistics(presentedIntervals),
            "droppedDrawables": dropped,
            "hitches": hitchIntervals.count,
            "skippedRefreshes": skippedRefreshes,
            "hitchMsPerSecond": hitchIntervals.reduce(0) { $0 + ($1 - period * 1000) } / window,
            "phases": phases,
            "mainThread": [
                "busyRatio": busyTotal / 1000 / window,
                "busyMsPerSecond": busyTotal / window,
                "drawMsPerSecond": mainDrawTotal / window,
                "modelMsPerSecond": modelTotal / window,
                "loadMsPerSecond": loadTotal / window,
                "otherMsPerSecond": other / window,
                "cpuRatio": (cpuAtEnd.main - cpuAtStart.main) / window,
            ] as [String: Any],
            // Display-link callbacks that ran off the main thread (the
            // viewport's render thread): their draw time per second.
            "renderThread": [
                "callbacks": renderDraws.count,
                "drawMsPerSecond": renderDrawTotal / window,
            ] as [String: Any],
            "drawThread": renderDraws.isEmpty ? "main" : (renderDraws.count == frames.count ? "render" : "mixed"),
            // Per-draw frame-ring use (G4): skin palettes written, and the
            // buffers created while recording (none once the ring is warm).
            "frameRing": [
                "skinPalettesPerDraw": PerfTrace.statistics(frames.map { Double($0.skinPalettes) }),
                "paletteKiBPerDraw": PerfTrace.statistics(frames.map { Double($0.ring.paletteBytes) / 1024 }),
                "paletteBuffersCreated": frames.reduce(0) { $0 + $1.ring.paletteBuffersCreated },
                "drawsWithOverflow": frames.filter { $0.ring.overflowBuffers > 0 }.count,
            ] as [String: Any],
            "processCPUCores": (cpuAtEnd.process - cpuAtStart.process) / window,
            "inputCalls": inputNames,
            "events": Dictionary(uniqueKeysWithValues: Event.allCases.compactMap { event -> (String, Any)? in
                guard let count = eventCounts[event] else { return nil }
                return (event.rawValue, ["count": count, "perSecond": PerfTrace.round(Double(count) / window)] as [String: Any])
            }),
            // Asynchronous hover picks (R7 phase 2, item 5): finished picks
            // the main actor took, how many applied, their latency from start
            // to the main actor and their command buffers' GPU time.
            "hoverPick": [
                "finished": hoverPicks.count,
                "applied": hoverPicks.filter(\.applied).count,
                "stale": hoverPicks.filter { !$0.applied }.count,
                "latencyMs": PerfTrace.statistics(hoverPicks.map(\.latency)),
                "gpuMs": PerfTrace.statistics(hoverPicks.map(\.gpu).filter { $0 > 0 }),
            ] as [String: Any],
            "viewBodies": Dictionary(uniqueKeysWithValues: ViewBody.allCases.compactMap { view -> (String, Any)? in
                let count = bodyCounts[view.rawValue]
                guard count > 0 else { return nil }
                return (view.name, ["count": count, "perSecond": PerfTrace.round(Double(count) / window)] as [String: Any])
            }),
            "memory": [
                "peakFootprintBytes": peakFootprint,
                "peakMetalAllocatedBytes": peakMetal,
                "endFootprintBytes": PerfTrace.footprint(),
                "maxResidentBytes": PerfTrace.maxResident(),
            ] as [String: Any],
            "windowOccludedSamples": occludedSamples,
            "windowSamples": memorySamples,
        ]
        let frameRows = frames.map { frame -> [Double] in
            let presentedAt = frame.presentLogIndex < presented.count ? presented[frame.presentLogIndex] : 0
            return [PerfTrace.round(frame.callback - recordStart), PerfTrace.round(frame.drawMilliseconds),
                    PerfTrace.round(frame.gpuMilliseconds), presentedAt > 0 ? PerfTrace.round(presentedAt - recordStart) : -1,
                    frame.onMainThread ? 1 : 0]
        }
        var samples: [String: Any] = ["frames": ["columns": ["callbackSeconds", "drawMs", "gpuMs", "presentedSeconds", "onMainThread"], "rows": frameRows]]
        for phase in Phase.allCases where phase != .draw {
            guard let list = intervals[phase], !list.isEmpty else { continue }
            samples[phase.rawValue] = list.map { [PerfTrace.round($0.start - recordStart), PerfTrace.round(($0.end - $0.start) * 1000)] }
        }
        samples["mainBusy"] = busy.map { [PerfTrace.round($0.start - recordStart), PerfTrace.round(($0.end - $0.start) * 1000)] }

        let window0 = NSApp.windows.first(where: { $0.isVisible })
        var startup = marks
        if let first = drawn.firstDraw { startup.append(("firstDraw", secondsSinceProcessStart(media: first))) }
        return [
            "schemaVersion": 4,
            "workload": configuration.workload,
            "configuration": [
                "seconds": configuration.seconds, "warmupSeconds": configuration.warmupSeconds,
                "inputHz": configuration.inputHz, "nativeCharacters": configuration.nativeCharacters,
                "mainLoadMs": configuration.mainLoadMilliseconds, "mainLoadHz": configuration.mainLoadHz,
            ] as [String: Any],
            "build": PerfTrace.buildDescription(),
            "machine": PerfTrace.machineDescription(device: device),
            "display": [
                "maximumFramesPerSecond": screen?.maximumFramesPerSecond ?? 0,
                "backingScaleFactor": screen?.backingScaleFactor ?? 0,
                "screenPoints": [screen?.frame.width ?? 0, screen?.frame.height ?? 0],
                "windowContentPoints": [window0?.contentLayoutRect.width ?? 0, window0?.contentLayoutRect.height ?? 0],
                "drawablePixels": [drawn.drawable.width, drawn.drawable.height],
            ] as [String: Any],
            "startupSeconds": Dictionary(startup.map { ($0.name, PerfTrace.round($0.seconds)) }, uniquingKeysWith: { first, _ in first }),
            "details": details,
            "summary": summary,
            "samples": samples,
        ]
    }

    // MARK: Helpers

    static func statistics(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return ["count": 0] }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))] }
        return ["count": sorted.count, "mean": round(sorted.reduce(0, +) / Double(sorted.count)), "p50": round(percentile(0.5)),
                "p95": round(percentile(0.95)), "p99": round(percentile(0.99)), "max": round(sorted.last!), "min": round(sorted.first!)]
    }

    static func round(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }

    /// Total length of the union of `intervals`, in their unit.
    static func unionSeconds(_ intervals: [(start: CFTimeInterval, end: CFTimeInterval)]) -> Double {
        var total = 0.0
        var current: (start: CFTimeInterval, end: CFTimeInterval)?
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let open = current, interval.start <= open.end {
                current = (open.start, max(open.end, interval.end))
            } else {
                if let open = current { total += open.end - open.start }
                current = interval
            }
        }
        if let open = current { total += open.end - open.start }
        return total
    }

    private static func buildDescription() -> [String: Any] {
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let app = _isDebugAssertConfiguration() ? "debug" : (_isFastAssertConfiguration() ? "unchecked" : "release")
        let info = Bundle.main.infoDictionary ?? [:]
        return ["configuration": configuration, "appAssertConfiguration": app,
                "engineAssertConfiguration": EngineBuild.assertConfiguration,
                "bundleVersion": info["CFBundleVersion"] as? String ?? "",
                "executable": Bundle.main.executableURL?.path ?? ""]
    }

    private static func machineDescription(device: (any MTLDevice)?) -> [String: Any] {
        func sysctlString(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
            return String(cString: buffer)
        }
        let info = ProcessInfo.processInfo
        // Other processes share the machine (builds, other agents' lanes); the
        // 1/5/15-minute load average at report time says how busy it was.
        var load = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&load, 3)
        return ["model": sysctlString("hw.model"), "cpu": sysctlString("machdep.cpu.brand_string"),
                "gpu": device?.name ?? "", "os": info.operatingSystemVersionString,
                "physicalMemoryBytes": info.physicalMemory, "activeProcessors": info.activeProcessorCount,
                "thermalState": info.thermalState.rawValue, "lowPowerMode": info.isLowPowerModeEnabled,
                "loadAverage": loadCount == 3 ? load.map { PerfTrace.round($0) } : []]
    }

    private static func processStartTime() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    /// Names of the process's threads (`pthread_setname_np`; unnamed threads
    /// give ""). The viewport lifecycle workload counts render threads with it.
    static func threadNames() -> [String] {
        let pid = getpid()
        var handles = [UInt64](repeating: 0, count: 1024)
        let bytes = handles.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        return handles.prefix(Int(bytes) / MemoryLayout<UInt64>.stride).compactMap { handle -> String? in
            var info = proc_threadinfo()
            let size = Int32(MemoryLayout<proc_threadinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTHREADINFO, handle, &info, size) == size else { return nil }
            return withUnsafeBytes(of: info.pth_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
    }

    /// `phys_footprint`: the number Activity Monitor and jetsam use.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func maxResident() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss)
    }

    /// Process CPU seconds (user + system) and the main thread's.
    private static func cpuSeconds() -> (process: Double, main: Double) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let process = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = pthread_mach_thread_np(pthread_self())
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (process, 0) }
        let main = Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
        return (process, main)
    }
}

/// Presentation times reported by `CAMetalDrawable.addPresentedHandler`, which
/// runs on a Metal thread. Index = order of `register()` calls; 0 = not
/// presented (dropped) or not reported yet.
///
/// Sendable invariant: `times` is only read or written while `lock` is held.
nonisolated final class PresentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []

    /// Reserves a slot for the next drawable and returns its index.
    func register() -> Int {
        lock.lock(); defer { lock.unlock() }
        times.append(0)
        return times.count - 1
    }

    func presented(_ index: Int, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        if times.indices.contains(index) { times[index] = time }
    }

    func snapshot() -> [Double] {
        lock.lock(); defer { lock.unlock() }
        return times
    }
}

/// The display-link draws of one run, recorded by whichever thread runs the
/// callback: the viewport's render thread, or the main thread in builds
/// before R7 phase 2, item 2. All of its state sits behind its own lock, so
/// it is Sendable without an unchecked conformance.
nonisolated final class PerfDrawLog: Sendable {
    struct Sample: Sendable {
        var callback: CFTimeInterval
        var end: CFTimeInterval
        var targetPresentation: CFTimeInterval
        var gpuMilliseconds: Double
        var presentLogIndex: Int
        var onMainThread: Bool
        /// The frame ring's counters for this draw (`lastFrameStatistics`,
        /// read right after it; a pick or capture in between replaces them).
        var ring = FrameRing.Statistics()
        var skinPalettes = 0
        /// `Renderer.draw` plus the recorder's own bookkeeping, in ms.
        var drawMilliseconds: Double { (end - callback) * 1000 }
    }

    struct Snapshot: Sendable {
        /// Draws made while recording.
        var samples: [Sample] = []
        /// Media time of the end of the first draw of the process.
        var firstDraw: CFTimeInterval?
        /// The most recent drawable's size in pixels.
        var drawable: CGSize = .zero
    }

    private struct State: Sendable {
        var recording = false
        var snapshot = Snapshot()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let presentLog = PresentLog()

    /// Records one callback around `Renderer.draw`. Returns true for the
    /// process's first draw, which the caller marks.
    @discardableResult
    func didDraw(callback: CFTimeInterval, end: CFTimeInterval, targetPresentation: CFTimeInterval,
                 gpuSeconds: Double, presentIndex: Int, drawable: CGSize, statistics: RenderFrameStatistics) -> Bool {
        let sample = Sample(callback: callback, end: end, targetPresentation: targetPresentation,
                            gpuMilliseconds: gpuSeconds * 1000, presentLogIndex: presentIndex,
                            onMainThread: pthread_main_np() != 0, ring: statistics.uniforms,
                            skinPalettes: statistics.skinPalettes)
        return state.withLock { state in
            let first = state.snapshot.firstDraw == nil
            if first { state.snapshot.firstDraw = end }
            state.snapshot.drawable = drawable
            if state.recording { state.snapshot.samples.append(sample) }
            return first
        }
    }

    /// Starts (clearing earlier samples) or stops keeping samples.
    func setRecording(_ on: Bool) {
        state.withLock { state in
            if on { state.snapshot.samples = [] }
            state.recording = on
        }
    }

    func snapshot() -> Snapshot { state.withLock { $0.snapshot } }
}

/// One display-link frame: `Renderer.draw` for the update's drawable inside a
/// `Draw` signpost and, while a performance trace runs, its sample. Runs on
/// the thread that runs the display link.
nonisolated enum ViewportFrame {
    /// Name of the thread that runs a viewport's display link
    /// (`pthread_setname_np`); the `viewport-lifecycle` workload counts them.
    static let renderThreadName = "com.grabbiel.Ikkoku.viewport-render"

    static func draw(_ update: CAMetalDisplayLink.Update, renderer: Renderer, log: PerfDrawLog?) {
        let drawable = update.drawable
        var presentIndex = -1
        if let log {
            let presents = log.presentLog
            let index = presents.register()
            presentIndex = index
            drawable.addPresentedHandler { shown in presents.presented(index, at: shown.presentedTime) }
        }
        let start = CACurrentMediaTime()
        PerfSignpost.interval("Draw") {
            renderer.draw(to: drawable, timestamp: update.targetPresentationTimestamp)
        }
        guard let log else { return }
        let end = CACurrentMediaTime()
        let texture = drawable.texture
        if log.didDraw(callback: start, end: end, targetPresentation: update.targetPresentationTimestamp,
                       gpuSeconds: renderer.lastFrameGPUTime, presentIndex: presentIndex,
                       drawable: CGSize(width: texture.width, height: texture.height),
                       statistics: renderer.lastFrameStatistics) {
            PerfSignpost.signposter.emitEvent("Mark", "firstDraw")
        }
    }
}
