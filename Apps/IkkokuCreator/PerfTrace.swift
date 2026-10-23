import Foundation
import AppKit
import QuartzCore
import Metal
import Observation
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
/// It records, on the main thread:
/// - every `CAMetalDisplayLink` callback: when it ran, the frame it targeted,
///   how long `Renderer.draw` took (preparation + encoding + any wait for a
///   frame slot) and the renderer's most recent GPU time
///   (`gpuEndTime - gpuStartTime` of the last completed command buffer);
/// - when each drawable was actually presented (`addPresentedHandler`), which
///   yields presented-frame intervals and hitches;
/// - each main run-loop busy period (after-waiting to before-waiting), so
///   main-thread time not spent drawing or in the model is visible as "other"
///   (SwiftUI updates, layout, AppKit event handling);
/// - model work: Maker ticks/refreshes (explicit hooks), Studio live ticks and
///   `refresh()` calls (observed through `StudioModel`'s observable
///   properties, see `observeStudio`) and every input handler call;
/// - process footprint, Metal allocation and CPU time.
@MainActor
final class PerfTrace {
    static private(set) var active: PerfTrace?

    /// Phases with their own sample lists.
    enum Phase: String, CaseIterable {
        case draw, studioTick, studioRefresh, makerTick, makerRefresh, input
    }

    struct Configuration {
        let output: URL
        let workload: String
        let seconds: Double
        let warmupSeconds: Double
        let windowPoints: CGSize
        let inputHz: Double
        let nativeCharacters: Int

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
                nativeCharacters: int("IKKOKU_PERF_CHARACTERS", 6))
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

    struct FrameSample {
        var callback: CFTimeInterval
        var targetPresentation: CFTimeInterval
        var drawMilliseconds: Double
        var gpuMilliseconds: Double
        var presentLogIndex: Int
    }
    private(set) var frames: [FrameSample] = []
    private var intervals: [Phase: [(start: CFTimeInterval, end: CFTimeInterval)]] = [:]
    private var inputNames: [String: Int] = [:]
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
    private var firstDrawMarked = false
    let presentLog = PresentLog()
    var device: (any MTLDevice)?
    var drawableSize: CGSize = .zero
    /// Free-form facts the workload driver adds (inputs, selections, hashes).
    var details: [String: Any] = [:]

    // Studio observation probes (see `observeStudio`).
    private var studioTickStart: CFTimeInterval?
    private var studioRefreshStart: CFTimeInterval?

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
        let wall = originWall + (CACurrentMediaTime() - originMedia)
        marks.append((name, wall - processStartWall))
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

    /// Called by `ViewportNSView` around `Renderer.draw`.
    func didDraw(callback: CFTimeInterval, end: CFTimeInterval, targetPresentation: CFTimeInterval,
                 gpuSeconds: Double, presentIndex: Int, drawable: CGSize) {
        if !firstDrawMarked { firstDrawMarked = true; mark("firstDraw") }
        drawableSize = drawable
        guard recording else { return }
        frames.append(FrameSample(callback: callback, targetPresentation: targetPresentation,
                                  drawMilliseconds: (end - callback) * 1000, gpuMilliseconds: gpuSeconds * 1000,
                                  presentLogIndex: presentIndex))
    }

    /// Studio's live tick and `refresh()` live in StudioModel.swift, which other
    /// work owns at the moment; until it carries explicit hooks the trace infers
    /// both from properties each of them assigns: a live tick begins with
    /// `sourceAnimationTime += deltaTime`, `refresh()` assigns
    /// `sourceRoutePlayState` near its start and `frame` just before it submits.
    /// The resulting intervals omit only the route prune before the first
    /// assignment and the submit after the last. Every Observation callback runs
    /// synchronously in the setter on the main thread.
    func observeStudio(_ studio: StudioModel) {
        func watch<Value>(_ read: @escaping () -> Value, _ changed: @escaping () -> Void) {
            withObservationTracking({ _ = read() }, onChange: {
                changed()
                MainActor.assumeIsolated { watch(read, changed) }
            })
        }
        watch({ studio.sourceAnimationTime }) { [weak self] in
            MainActor.assumeIsolated { self?.studioTickStart = CACurrentMediaTime() }
        }
        watch({ studio.sourceRoutePlayState.count }) { [weak self] in
            MainActor.assumeIsolated { self?.studioRefreshStart = CACurrentMediaTime() }
        }
        watch({ studio.frame.items.count }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if let start = self.studioRefreshStart { self.record(.studioRefresh, start: start, end: now) }
                if let start = self.studioTickStart { self.record(.studioTick, start: start, end: now) }
                self.studioRefreshStart = nil; self.studioTickStart = nil
            }
        }
    }

    // MARK: Recording window

    func beginRecording() {
        frames = []; intervals = [:]; inputNames = [:]; busy = []
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
        let presented = presentLog.snapshot()
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
        let drawTotal = draw.reduce(0, +)
        // Model time: ticks and input calls (each includes the refreshes it
        // triggered) plus the refreshes outside any of them, so nothing counts twice.
        let containers = (intervals[.studioTick] ?? []) + (intervals[.makerTick] ?? []) + (intervals[.input] ?? [])
        let looseRefreshes = ((intervals[.studioRefresh] ?? []) + (intervals[.makerRefresh] ?? [])).filter { refresh in
            !containers.contains { $0.start <= refresh.start && refresh.end <= $0.end }
        }
        let modelTotal = (containers + looseRefreshes).reduce(0) { $0 + ($1.end - $1.start) } * 1000
        let other = max(0, busyTotal - drawTotal - modelTotal)

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
                "drawMsPerSecond": drawTotal / window,
                "modelMsPerSecond": modelTotal / window,
                "otherMsPerSecond": other / window,
                "cpuRatio": (cpuAtEnd.main - cpuAtStart.main) / window,
            ] as [String: Any],
            "processCPUCores": (cpuAtEnd.process - cpuAtStart.process) / window,
            "inputCalls": inputNames,
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
                    PerfTrace.round(frame.gpuMilliseconds), presentedAt > 0 ? PerfTrace.round(presentedAt - recordStart) : -1]
        }
        var samples: [String: Any] = ["frames": ["columns": ["callbackSeconds", "drawMs", "gpuMs", "presentedSeconds"], "rows": frameRows]]
        for phase in Phase.allCases where phase != .draw {
            guard let list = intervals[phase], !list.isEmpty else { continue }
            samples[phase.rawValue] = list.map { [PerfTrace.round($0.start - recordStart), PerfTrace.round(($0.end - $0.start) * 1000)] }
        }
        samples["mainBusy"] = busy.map { [PerfTrace.round($0.start - recordStart), PerfTrace.round(($0.end - $0.start) * 1000)] }

        let window0 = NSApp.windows.first(where: { $0.isVisible })
        return [
            "schemaVersion": 1,
            "workload": configuration.workload,
            "configuration": [
                "seconds": configuration.seconds, "warmupSeconds": configuration.warmupSeconds,
                "inputHz": configuration.inputHz, "nativeCharacters": configuration.nativeCharacters,
            ] as [String: Any],
            "build": PerfTrace.buildDescription(),
            "machine": PerfTrace.machineDescription(device: device),
            "display": [
                "maximumFramesPerSecond": screen?.maximumFramesPerSecond ?? 0,
                "backingScaleFactor": screen?.backingScaleFactor ?? 0,
                "screenPoints": [screen?.frame.width ?? 0, screen?.frame.height ?? 0],
                "windowContentPoints": [window0?.contentLayoutRect.width ?? 0, window0?.contentLayoutRect.height ?? 0],
                "drawablePixels": [drawableSize.width, drawableSize.height],
            ] as [String: Any],
            "startupSeconds": Dictionary(marks.map { ($0.name, PerfTrace.round($0.seconds)) }, uniquingKeysWith: { first, _ in first }),
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
final class PresentLog: @unchecked Sendable {
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
