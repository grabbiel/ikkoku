import Foundation
import AppKit
import CryptoKit
import simd
import Character
import GPU
import Scene
import Studio

/// Drives one `IKKOKU_PERF_WORKLOAD` in the real editor window and writes the
/// `PerfTrace` report (R7). Every action calls the method the UI calls: the
/// viewport's `ViewportInputHandler` methods for mouse input, the Maker slider
/// row binding's slot setter for shape sliders, and the Studio model's own
/// selection, pose-mode and scene commands. Nothing is re-implemented.
///
/// Timeline: the window is sized to `IKKOKU_PERF_WINDOW_W`×`_H` points (default
/// 1600×1000, never saved as the user's window frame) and floats above other
/// apps' windows so it is never occluded (`configureWindow`), the workload is set up,
/// `IKKOKU_PERF_WARMUP_SECONDS` (default 3) pass so pipeline creation and
/// first-use uploads settle, then `IKKOKU_PERF_SECONDS` (default 10) are
/// recorded while input, if any, is injected at `IKKOKU_PERF_INPUT_HZ`
/// (default 120, one event per refresh on a 120 Hz display). With
/// `IKKOKU_PERF_MAIN_LOAD_MS` > 0 a main-thread timer also busy-waits that long
/// `IKKOKU_PERF_MAIN_LOAD_HZ` (default 30) times per second while recording,
/// a stand-in for main-thread work that should not delay presentation. The
/// app then writes the report and exits 0, or 1 when the workload cannot run.
@MainActor
final class PerfWorkloadDriver {
    private static var shared: PerfWorkloadDriver?

    private let app: AppState
    private let trace: PerfTrace
    private var inputTimer: Timer?
    private var loadTimer: Timer?
    /// Timed window and viewport actions of `viewport-lifecycle`.
    private var lifecycle: [(seconds: Double, name: String, action: () -> Void)] = []
    private var lifecycleLog: [[String: Any]] = []
    private var restoredAt: CFTimeInterval?
    private var recordingStart: CFTimeInterval = 0
    /// Called once per injected input tick with the seconds since recording began.
    private var inject: ((Double) -> Void)?
    /// Ends whatever gesture the workload holds (mouse up).
    private var finishGesture: (() -> Void)?
    /// Keeps App Nap off for the measurement (see `configureWindow`).
    private var activity: (any NSObjectProtocol)?

    private init(app: AppState, trace: PerfTrace) {
        self.app = app
        self.trace = trace
    }

    /// Called from `ContentView.onAppear`, once the editor window exists.
    static func startIfRequested(app: AppState) {
        guard shared == nil, let trace = PerfTrace.active else { return }
        let driver = PerfWorkloadDriver(app: app, trace: trace)
        shared = driver
        PerfTrace.mark("contentAppeared")
        // Let the first layout pass finish before resizing the window.
        DispatchQueue.main.async { driver.begin() }
    }

    private var configuration: PerfTrace.Configuration { trace.configuration }

    private func fail(_ message: String) -> Never {
        print("[ikkoku] perf trace failed: \(message)")
        exit(1)
    }

    private func begin() {
        trace.device = app.host?.gpu.device
        configureWindow()
        do { try prepare() } catch { fail("\(configuration.workload): \(error)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.warmupSeconds) { self.record() }
    }

    private func configureWindow() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            fail("no visible editor window")
        }
        // A measurement window size must not become the user's saved frame.
        window.setFrameAutosaveName("")
        var size = configuration.windowPoints
        if let visible = window.screen?.visibleFrame {
            let chrome = window.frame.height - window.contentLayoutRect.height
            size.width = min(size.width, visible.width)
            size.height = min(size.height, visible.height - chrome)
        }
        window.setContentSize(size)
        window.center()
        // A launch from a script is not allowed to take focus, so its window
        // would open behind the frontmost app. A fully occluded window is
        // composited and paced differently (its drawables may never be
        // presented), so the measured window floats above other apps' windows
        // for the run. The process also opts out of App Nap, which a visible
        // foreground window would not get either.
        window.level = .floating
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "IKKOKU_PERF_TRACE measurement")
        trace.details["windowContentPointsRequested"] = [configuration.windowPoints.width, configuration.windowPoints.height]
        trace.details["windowLevel"] = "floating"
    }

    private func record() {
        trace.beginRecording()
        recordingStart = CACurrentMediaTime()
        if inject != nil {
            let timer = Timer(timeInterval: 1 / configuration.inputHz, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let inject = self.inject else { return }
                    inject(CACurrentMediaTime() - self.recordingStart)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            inputTimer = timer
        }
        if configuration.mainLoadMilliseconds > 0 {
            let seconds = configuration.mainLoadMilliseconds / 1000
            let timer = Timer(timeInterval: 1 / configuration.mainLoadHz, repeats: true) { _ in
                MainActor.assumeIsolated { PerfTrace.measure(.mainLoad, "MainLoad") { Self.busyWait(seconds) } }
            }
            RunLoop.main.add(timer, forMode: .common)
            loadTimer = timer
            trace.details["mainLoad"] = "busy-wait \(configuration.mainLoadMilliseconds) ms on the main thread \(configuration.mainLoadHz) times per second"
        }
        for step in lifecycle {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.seconds) { self.runLifecycleStep(step.name, step.action) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.seconds) { self.stop() }
    }

    /// Spins (rather than sleeps) so the load is CPU work on the main thread.
    private static func busyWait(_ seconds: Double) {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {}
    }

    private func stop() {
        inputTimer?.invalidate(); inputTimer = nil
        loadTimer?.invalidate(); loadTimer = nil
        if !lifecycle.isEmpty { finishLifecycle() }
        trace.endRecording()
        finishGesture?()
        // Presented handlers of the last frames arrive after their vsync.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            do {
                let url = try self.trace.writeReport()
                print("[ikkoku] perf trace written to \(url.path)")
                if self.lifecycle.isEmpty { exit(0) }
                // Quit the way the menu does while the display link is still
                // drawing; the process must exit 0 without a crash.
                print("[ikkoku] perf trace: quitting through NSApp.terminate")
                NSApp.terminate(nil)
            } catch { self.fail("could not write the report: \(error)") }
        }
    }

    // MARK: Workloads

    private func prepare() throws {
        let workload = configuration.workload
        trace.details["workload"] = workload
        switch workload {
        case "studio-idle": try prepareStudioSource(selectKey: nil)
        case "studio-orbit": try prepareStudioOrbit()
        case "studio-fk-drag": try prepareStudioFKDrag()
        case "studio-hover": try prepareStudioHover()
        case "maker-slider": try prepareMakerSlider()
        case "maker-idle": try prepareMaker()
        case "studio-native": try prepareStudioNative()
        case "viewport-lifecycle": try prepareViewportLifecycle()
        case "startup": break
        default: throw RigError.invalid("unknown workload \(workload)")
        }
    }

    private func studio() throws -> StudioModel {
        guard let studio = app.studio else { throw RigError.invalid("the Studio is unavailable") }
        return studio
    }

    private func viewportCenter(_ studio: StudioModel) -> SIMD2<Float> { studio.viewportSize * 0.5 }

    /// The source scene from `IKKOKU_SOURCE_SCENE`, live animation on, a fixed
    /// selection, recorded with the scene file's SHA-256.
    @discardableResult
    private func prepareStudioSource(selectKey: Int32?) throws -> StudioModel {
        let studio = try studio()
        let characters = studio.doc.objects.filter { $0.kind == .character && $0.sourceCharacter != nil }
        guard !characters.isEmpty else { throw RigError.invalid("needs IKKOKU_SOURCE_SCENE with converted source characters") }
        app.mode = .studio
        studio.liveAnimation = true
        studio.selection = selectKey.flatMap { key in studio.doc.objects.first { $0.sourceObjectKey == key }?.id }
        trace.details["sourceCharacters"] = characters.count
        trace.details["documentObjects"] = studio.doc.objects.count
        trace.details["selectedSourceKey"] = selectKey.map { Int($0) } ?? -1
        if let path = ProcessInfo.processInfo.environment["IKKOKU_SOURCE_SCENE"],
           let data = FileManager.default.contents(atPath: path) {
            trace.details["sourceScene"] = URL(fileURLWithPath: path).lastPathComponent
            trace.details["sourceSceneSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return studio
    }

    /// Right-button drag (the view's orbit gesture, no pick) around the scene.
    private func prepareStudioOrbit() throws {
        let studio = try prepareStudioSource(selectKey: nil)
        var last = viewportCenter(studio)
        var started = false
        inject = { t in
            if !started {
                started = true
                PerfTrace.input("mouseDown") { studio.mouseDown(at: last, button: 1, modifiers: []) }
            }
            // About one turn per 8 s with a slow pitch wobble; 4–5 px per event.
            let delta = SIMD2<Float>(Float(4 * cos(t * 0.5)), Float(3 * sin(t * 1.7)))
            let point = last + delta
            PerfTrace.input("mouseDragged") { studio.mouseDragged(to: point, delta: delta, button: 1, modifiers: []) }
            last = point
        }
        finishGesture = { PerfTrace.input("mouseUp") { studio.mouseUp(at: last, button: 1, modifiers: []) } }
        trace.details["gesture"] = "right-button orbit drag, one mouseDragged per input tick"
    }

    /// The `fk-mouse-drag` scenario's grab (source key 65, bone 19, z ring),
    /// then a continuous circular drag of the ring for the whole recording.
    private func prepareStudioFKDrag() throws {
        let key: Int32 = 65, boneID = 19
        let studio = try prepareStudioSource(selectKey: key)
        guard let id = studio.selection, let preview = studio.sourceShapePreview(for: id),
              let target = preview.controller.targets.first(where: { $0.bone.id == boneID && $0.hasGuide }) else {
            throw RigError.invalid("source key \(key) has no FK guide for bone \(boneID)")
        }
        studio.poseMode = .fk
        studio.selectedBone = target.node
        guard let anchor = studio.sourceGuidePixel(of: boneID) else { throw RigError.invalid("bone \(boneID) does not project into the view") }
        guard let start = Self.findAxis(.z, around: anchor, pick: studio.pickID(at:)) else {
            throw RigError.invalid("no pixel near bone \(boneID) picks its z rotate ring")
        }
        let undoDepth = studio.undoStack.count
        PerfTrace.input("mouseDown") { studio.mouseDown(at: start, button: 0, modifiers: []) }
        guard studio.undoStack.count == undoDepth + 1 else {
            throw RigError.invalid("mouseDown on the z ring grabbed no guide")
        }
        var last = start
        inject = { t in
            // A 40 px circle through the grab point, one turn per 2 s.
            let angle = Float(t) * .pi
            let point = start + SIMD2<Float>(40 * sin(angle), 40 * (1 - cos(angle)))
            let delta = point - last
            PerfTrace.input("mouseDragged") { studio.mouseDragged(to: point, delta: delta, button: 0, modifiers: []) }
            last = point
        }
        finishGesture = { PerfTrace.input("mouseUp") { studio.mouseUp(at: last, button: 0, modifiers: []) } }
        trace.details["gesture"] = "FK z-ring drag of source key \(key) bone \(boneID) from pixel (\(start.x), \(start.y))"
    }

    /// Mouse moves over the viewport while a source character is selected:
    /// each `mouseMoved` runs the gizmo hover pick.
    private func prepareStudioHover() throws {
        let studio = try prepareStudioSource(selectKey: 65)
        inject = { t in
            let size = studio.viewportSize
            let point = size * 0.5 + SIMD2<Float>(Float(sin(t * 1.3)) * size.x * 0.3, Float(sin(t * 0.9)) * size.y * 0.3)
            PerfTrace.input("mouseMoved") { studio.mouseMoved(to: point) }
        }
        trace.details["gesture"] = "mouseMoved over the viewport with source key 65 selected"
    }

    @discardableResult
    private func prepareMaker() throws -> MakerModel {
        guard let maker = app.maker else { throw RigError.invalid("the Maker is unavailable") }
        app.mode = .maker
        maker.liveAnimation = true
        trace.details["makerSourcePreview"] = maker.sourceRigPreview != nil
        trace.details["makerImportedCard"] = maker.importedSourceCard != nil
        if let path = ProcessInfo.processInfo.environment["IKKOKU_SOURCE_CARD"],
           let data = FileManager.default.contents(atPath: path) {
            trace.details["sourceCard"] = URL(fileURLWithPath: path).lastPathComponent
            trace.details["sourceCardSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return maker
    }

    /// Writes one body slider the way its row binding does
    /// (`model[shapeSlot:]`, which writes `sourceBodyValues[slot.index]`),
    /// sweeping it with a sine.
    private func prepareMakerSlider() throws {
        let maker = try prepareMaker()
        guard let preview = maker.sourceRigPreview, preview.supportsBodyCustomization,
              let slot = preview.contract?.domain("body")?.slots.first(where: { slot in
                  slot.index != 0 && preview.bodyCoverage?.boundSlots.contains(slot.index) == true
                      && maker.sourceBodyValues.indices.contains(slot.index)
              }) else {
            throw RigError.invalid("needs an original Maker preview with body customization (IKKOKU_SOURCE_CARD)")
        }
        maker.applySourceCustomization = true
        let index = slot.index
        let base = maker.sourceBodyValues[index]
        inject = { t in
            let value = Float(min(1, max(0, Double(base) + 0.3 * sin(t * 3))))
            PerfTrace.input("bodySlider") { maker[shapeSlot: .init(face: false, index: index)] = value }
        }
        trace.details["gesture"] = "body slider '\(slot.label)' (slot \(index)) swept around \(base)"
    }

    /// `IKKOKU_PERF_CHARACTERS` bundled characters (alternating female/male)
    /// added with the Studio's Add menu commands, live animation on.
    private func prepareStudioNative() throws {
        let studio = try studio()
        app.mode = .studio
        studio.newScene()
        for index in 0..<configuration.nativeCharacters { studio.addCharacter(sex: index.isMultiple(of: 2) ? .female : .male) }
        studio.selection = nil
        studio.liveAnimation = true
        studio.resetCamera()
        trace.details["nativeCharacters"] = configuration.nativeCharacters
        trace.details["documentObjects"] = studio.doc.objects.count
    }

    /// Tears the viewport down and builds it again (Maker and Studio each own
    /// one, so a mode switch replaces it), resizes the window, minimizes and
    /// restores it, all while the display link draws, then quits through
    /// `NSApp.terminate`. The report's `details.lifecycle` records the
    /// viewport render threads alive before each step and at the end, and the
    /// frames drawn and presented after the restore.
    private func prepareViewportLifecycle() throws {
        guard app.maker != nil, app.studio != nil else { throw RigError.invalid("needs the Maker and the Studio") }
        app.mode = .maker
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            throw RigError.invalid("no visible editor window")
        }
        let size = window.contentLayoutRect.size
        var time = 0.5
        func add(_ name: String, settle: Double = 0.5, _ action: @escaping () -> Void) {
            lifecycle.append((time, name, action)); time += settle
        }
        for _ in 0..<3 {
            add("studio") { self.app.mode = .studio }
            add("maker") { self.app.mode = .maker }
        }
        add("resize-small") { window.setContentSize(NSSize(width: max(800, size.width * 0.7), height: max(560, size.height * 0.7))) }
        add("resize-back") { window.setContentSize(size) }
        add("miniaturize", settle: 1.5) { window.miniaturize(nil) }
        add("deminiaturize", settle: 1.5) { window.deminiaturize(nil); self.restoredAt = CACurrentMediaTime() }
        add("studio") { self.app.mode = .studio }
        add("maker") { self.app.mode = .maker }
        guard time + 0.5 <= configuration.seconds else {
            throw RigError.invalid("viewport-lifecycle needs IKKOKU_PERF_SECONDS >= \(Int((time + 0.5).rounded(.up)))")
        }
        trace.details["gesture"] = "viewport teardown and rebuild (mode switches), resize, minimize and restore, then NSApp.terminate"
    }

    /// Viewport render threads alive now (none before R7 phase 2, item 2).
    private static func renderThreadCount() -> Int {
        PerfTrace.threadNames().filter { $0 == ViewportFrame.renderThreadName }.count
    }

    private func runLifecycleStep(_ name: String, _ action: () -> Void) {
        guard trace.recording else { return }
        // Counted before acting: the previous step has had its settle time.
        lifecycleLog.append(["step": name, "seconds": PerfTrace.round(CACurrentMediaTime() - recordingStart),
                             "renderThreadsBefore": Self.renderThreadCount()])
        action()
    }

    private func finishLifecycle() {
        var result: [String: Any] = ["steps": lifecycleLog, "renderThreadsAtEnd": Self.renderThreadCount(),
                                     "windowMiniaturized": NSApp.windows.contains { $0.isMiniaturized }]
        if let restoredAt {
            // Drawables presented more than half a second after the restore:
            // the display link kept running across minimize and restore.
            let presented = trace.drawLog.presentLog.snapshot()
            result["presentedAfterRestore"] = presented.filter { $0 > restoredAt + 0.5 }.count
            result["drawsAfterRestore"] = trace.drawLog.snapshot().samples.filter { $0.callback > restoredAt + 0.5 }.count
        }
        trace.details["lifecycle"] = result
    }

    /// The scenario runner's ring search: a coarse 10 px scan of ±120 px, then a
    /// 4 px scan of ±20 px around the first hit of the wanted axis.
    private static func findAxis(_ axis: GizmoAxis, around anchor: SIMD2<Float>, pick: (SIMD2<Float>) -> UInt32) -> SIMD2<Float>? {
        func scan(_ radius: Float, by step: Float, centeredAt center: SIMD2<Float>) -> SIMD2<Float>? {
            var y = center.y - radius
            while y <= center.y + radius {
                var x = center.x - radius
                while x <= center.x + radius {
                    let p = SIMD2<Float>(x, y)
                    if PickIDs.axis(from: pick(p)) == axis { return p }
                    x += step
                }
                y += step
            }
            return nil
        }
        guard let coarse = scan(120, by: 10, centeredAt: anchor) else { return nil }
        return scan(20, by: 4, centeredAt: coarse) ?? coarse
    }
}
