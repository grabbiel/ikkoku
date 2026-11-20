import Foundation
import AppKit
import CryptoKit
import simd
import Character
import GPU
import Scene
import Studio
import Renderer

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
    private var minimizedAt: CFTimeInterval?
    private var recordingStart: CFTimeInterval = 0
    /// Called once per injected input tick with the seconds since recording began.
    private var inject: ((Double) -> Void)?
    /// Ends whatever gesture the workload holds (mouse up).
    private var finishGesture: (() -> Void)?
    /// Keeps App Nap off for the measurement (see `configureWindow`).
    private var activity: (any NSObjectProtocol)?
    /// The action workloads (`studio-duplicate`, `studio-undo-delete`,
    /// `studio-redo`, `studio-outfit`, `studio-export`, `studio-load`; R7
    /// phase 2, item 6): the actions repeated in order while recording, the
    /// one waiting for its background work, and the finished ones with the
    /// status line and any error alert they left.
    private var actionSteps: [(name: String, measured: Bool, run: () -> Void)] = []
    private var actionIndex = 0
    private var pendingAction: (name: String, measured: Bool, start: CFTimeInterval, end: CFTimeInterval, bodies: [Int],
                                cpuMs: Double, live: LiveCall?)?
    private var finishedActions: [(name: String, measured: Bool, start: CFTimeInterval, end: CFTimeInterval, ready: CFTimeInterval,
                                   status: String, error: String?, footprint: UInt64, metal: Int, objects: Int,
                                   bodies: [Int], workspaceRows: Int,
                                   history: (undo: Int, redo: Int, storage: StudioObjectStorageCensus.Count)?,
                                   cpuMs: Double, live: LiveCall?)] = []
    /// #410: the workspace bodies counted per action, from its call to the
    /// next action's (`workspaceBodies`), in this order.
    private static let workspaceBodyViews: [PerfTrace.ViewBody] = [.studioWorkspaceRow, .studioWorkspacePlaceholder]
    /// `studio-edit-steps` (#409): the actions run once, not repeated, and
    /// the run stops after the last; each finished action records the undo
    /// and redo depth and the `objects` buffers they and the document hold.
    private var stopAfterActions = false
    private var countHistoryStorage = false
    /// A pause step's hold: no action starts before this media time (0: none).
    private var holdUntil: CFTimeInterval = 0
    /// `IKKOKU_PERF_EDIT_PHASES=alternate` (#409, #446): per action, by its
    /// index in `actionSteps`, the live-step phase its call is placed at, or
    /// nil (the call runs when the action starts). Empty for every other run.
    private var actionPhases: [StudioModel.LivePhase?] = []
    /// Whether each call records the live-step settles in it (`LiveCall`).
    private var countLiveSettles = false
    /// The placed call waiting for its phase (`place`): its number, the
    /// action, the phase, when the hook was armed and the serial live steps
    /// counted by then.
    private var placements = 0
    private var waitingPlacement: (token: Int, step: (name: String, measured: Bool, run: () -> Void),
                                   phase: StudioModel.LivePhase, armed: CFTimeInterval, serialSteps: Int)?
    private var stopped = false
    /// #440: the last park handled and each park's record (`details.parks`).
    private var lastPark = 0
    private var parks: [[String: Any]] = []
    /// The temporary folder `studio-export` and `studio-load` write scene
    /// files to, removed when the run stops.
    private var scratchFolder: URL?
    /// #445 (`studio-voice-play`): true while the action's own background
    /// work runs, so its `readyMs` and busy time reach the end of that work.
    /// Nil for every other workload.
    private var actionPending: (() -> Bool)?
    /// Whether the pending action waited for `actionPending`: it is then
    /// ready when the wait ended.
    private var actionWaited = false

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
        // R7 phase 2, item 4 measurement control (default on).
        app.host?.renderer.reusesDeformedVertices = configuration.deformReuse
        app.host?.renderer.skipsUnchangedFrames = configuration.frameSkip
        configureWindow()
        whenSourceSceneReady {
            self.preselect {
                do { try self.prepare() } catch { self.fail("\(self.configuration.workload): \(error)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.configuration.warmupSeconds) { self.record() }
            }
        }
    }

    /// `IKKOKU_PERF_SELECT_KEYS` for a workload other than `studio-select`
    /// (R7 phase 2, item 7): those objects are selected in turn, 0.3 s apart,
    /// before the workload prepares, so the inspector has built what they
    /// show (its kept sections, for example) when the workload's own
    /// selection replaces them.
    private func preselect(then body: @escaping () -> Void) {
        guard configuration.workload != "studio-select", let keys = configuration.selectKeys, !keys.isEmpty,
              let studio = app.studio else { body(); return }
        app.mode = .studio
        let tree = studio.doc.flattened().map(\.object)
        var ids: [UUID] = []
        for key in keys {
            guard let object = tree.first(where: { $0.sourceObjectKey == key }) else {
                fail("IKKOKU_PERF_SELECT_KEYS: no source object with key \(key)")
            }
            ids.append(object.id)
        }
        trace.details["preselectedSourceKeys"] = keys.map { Int($0) }
        func step(_ index: Int) {
            guard index < ids.count else { body(); return }
            studio.selection = ids[index]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { step(index + 1) }
        }
        step(0)
    }

    /// Runs `body` once the Studio's source scene import has installed its
    /// characters (R7 phase 2, item 6): the window may appear while the
    /// import still builds them. Polls every 10 ms; the launch's own timeout
    /// bounds the wait.
    private func whenSourceSceneReady(_ body: @escaping () -> Void) {
        guard app.studio?.isLoadingSourceScene == true else { body(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { self.whenSourceSceneReady(body) }
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
        if !actionSteps.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runNextAction() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.seconds) { self.stop() }
    }

    /// Spins (rather than sleeps) so the load is CPU work on the main thread.
    private static func busyWait(_ seconds: Double) {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {}
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        if waitingPlacement != nil { app.studio?.livePhaseHook = nil; waitingPlacement = nil }
        inputTimer?.invalidate(); inputTimer = nil
        loadTimer?.invalidate(); loadTimer = nil
        if !lifecycle.isEmpty { finishLifecycle() }
        if !actionSteps.isEmpty { finishActions() }
        if let folder = scratchFolder { try? FileManager.default.removeItem(at: folder) }
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
        case "maker-tabs": try prepareMakerTabs()
        case "studio-native": try prepareStudioNative()
        case "studio-timeline": try prepareStudioTimeline()
        case "studio-static": try prepareStudioSource(selectKey: nil, liveAnimation: false)
        case "studio-orbit-bursts": try prepareStudioOrbitBursts()
        case "viewport-lifecycle": try prepareViewportLifecycle()
        case "startup": break
        case "studio-duplicate", "studio-undo-delete", "studio-redo": try prepareStudioHistory(workload)
        case "studio-outfit": try prepareStudioOutfit()
        case "studio-export": try prepareStudioExport()
        case "studio-load": try prepareStudioLoad()
        case "studio-select": try prepareStudioSelect()
        case "studio-export-import": try prepareStudioExportImport()
        case "studio-show-hidden": try prepareStudioShowHidden()
        case "studio-clock-first": try prepareStudioClockFirst()
        case "studio-edit-steps": try prepareStudioEditSteps()
        case "studio-voice-play": try prepareStudioVoicePlay()
        default: throw RigError.invalid("unknown workload \(workload)")
        }
    }

    private func studio() throws -> StudioModel {
        guard let studio = app.studio else { throw RigError.invalid("the Studio is unavailable") }
        return studio
    }

    private func viewportCenter(_ studio: StudioModel) -> SIMD2<Float> { studio.viewportSize * 0.5 }

    /// The source scene from `IKKOKU_SOURCE_SCENE`, live animation on (off for
    /// the static workloads), a fixed selection, recorded with the scene file's SHA-256.
    @discardableResult
    private func prepareStudioSource(selectKey: Int32?, liveAnimation: Bool = true) throws -> StudioModel {
        let studio = try studio()
        let characters = studio.doc.objects.filter { $0.kind == .character && $0.sourceCharacter != nil }
        // A character riding a route renders behind a folder-kind placeholder,
        // so a scene whose only characters ride routes also qualifies (ST-T11).
        let routeCharacters = studio.sourceRouteCharacterPreviews.count
        // A scene of converted source items alone (ST-T04, the item catalog)
        // also qualifies.
        let sourceItems = studio.sourceRuntimeCounts().items
        guard !characters.isEmpty || routeCharacters > 0 || sourceItems > 0 else {
            throw RigError.invalid("needs IKKOKU_SOURCE_SCENE with converted source characters or items")
        }
        app.mode = .studio
        studio.liveAnimation = liveAnimation
        trace.details["liveAnimation"] = liveAnimation
        studio.selection = selectKey.flatMap { key in studio.doc.objects.first { $0.sourceObjectKey == key }?.id }
        trace.details["sourceCharacters"] = characters.count
        trace.details["sourceRouteCharacters"] = routeCharacters
        trace.details["sourceItems"] = sourceItems
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

    /// The source scene with live animation off, so nothing changes between
    /// gestures: `IKKOKU_PERF_BURST_IDLE_MS` (default 1000) without input, then a 0.5 s right-button
    /// orbit drag (mouseDown, one horizontal mouseDragged per input tick,
    /// mouseUp), alternating direction. The quiet second lets an adaptive
    /// display link slow down (R7 phase 2, item 4, P2), so each burst's first
    /// drag measures how quickly it returns to full rate. `details.burstInputEnds`
    /// lists when each burst's first mouseDragged handler returned, in seconds
    /// since recording began.
    ///
    /// `IKKOKU_PERF_BURST_LIVE=on` plays the live animation instead (R7 phase
    /// 2, live pacing), measuring a drag's start while steps are running.
    private func prepareStudioOrbitBursts() throws {
        let studio = try prepareStudioSource(selectKey: nil, liveAnimation: configuration.burstLive)
        let trace = self.trace
        var last = viewportCenter(studio)
        var dragging = false
        var bursts = 0
        var inputEnds: [Double] = []
        let start = { [unowned self] in self.recordingStart }
        let idle = Double(configuration.burstIdleMilliseconds) / 1000
        inject = { t in
            guard t.truncatingRemainder(dividingBy: idle + 0.5) >= idle else {
                if dragging {
                    dragging = false
                    PerfTrace.input("mouseUp") { studio.mouseUp(at: last, button: 1, modifiers: []) }
                }
                return
            }
            let first = !dragging
            if first {
                dragging = true; bursts += 1
                PerfTrace.input("mouseDown") { studio.mouseDown(at: last, button: 1, modifiers: []) }
            }
            let delta = SIMD2<Float>(bursts.isMultiple(of: 2) ? -4 : 4, 0)
            let point = last + delta
            PerfTrace.input("mouseDragged") { studio.mouseDragged(to: point, delta: delta, button: 1, modifiers: []) }
            last = point
            if first {
                inputEnds.append(PerfTrace.round(CACurrentMediaTime() - start()))
                trace.details["burstInputEnds"] = inputEnds
            }
        }
        finishGesture = { if dragging { PerfTrace.input("mouseUp") { studio.mouseUp(at: last, button: 1, modifiers: []) } } }
        trace.details["gesture"] = "repeated: \(configuration.burstIdleMilliseconds) ms without input, then a 0.5 s right-button orbit drag, live animation \(configuration.burstLive ? "on" : "off")"
    }

    /// The `fk-mouse-drag` scenario's grab (source key 65, bone 19, z ring),
    /// then a continuous circular drag of the ring for the whole recording.
    private func prepareStudioFKDrag() throws {
        let key: Int32 = configuration.actionKey ?? 65, boneID = 19
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
        let undoDepth = studio.undoDepth
        PerfTrace.input("mouseDown") { studio.mouseDown(at: start, button: 0, modifiers: []) }
        guard studio.undoDepth == undoDepth + 1 else {
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
        guard let maker = app.ensureMaker() else { throw RigError.invalid("the Maker is unavailable") }
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

    /// `maker-tabs` (#440): the bundled character's Maker, the tabbed panel
    /// (not the source rig panel), its tabs selected in turn as the segmented
    /// control selects them (`MakerModel.tab`), repeated. Each switch builds
    /// the tab's panel again, the tag and thumbnail grids included. The Maker
    /// opens the original base when it finds one, so the workload first uses
    /// the source rig panel's "Use bundled prototype" (`closeSourceRig()`).
    private func prepareMakerTabs() throws {
        let maker = try prepareMaker()
        trace.details["usedBundledPrototype"] = maker.sourceRigPreview != nil
        if maker.sourceRigPreview != nil { maker.closeSourceRig() }
        guard maker.sourceRigPreview == nil else { throw RigError.invalid("maker-tabs: the tabbed Maker panel did not show") }
        actionSteps = MakerTab.allCases.map { tab in ("tab \(tab.rawValue.lowercased())", true, { maker.tab = tab }) }
        trace.details["gesture"] = "the Maker's tabs selected in turn (\(MakerTab.allCases.map(\.rawValue).joined(separator: ", "))), repeated; live animation on"
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

    /// `studio-timeline` (R7 phase 2, live pacing): the `studio-native` scene
    /// with a timeline on its first character, keyed at 0 s and, 1 m along x,
    /// at 2.5 s, playing in a loop for the whole run. Each step advances the
    /// timeline by 1/30 s.
    private func prepareStudioTimeline() throws {
        try prepareStudioNative()
        let studio = try studio()
        guard let first = studio.doc.objects.first(where: { $0.kind == .character }) else {
            throw RigError.invalid("studio-timeline needs a native character")
        }
        studio.selection = first.id
        studio.timelineTime = 0
        studio.addKeyframe()
        studio.timelineTime = 2.5
        studio.updateSelected { $0.transform.position.x += 1 }
        studio.addKeyframe()
        studio.selection = nil
        studio.timelineTime = 0
        studio.timelinePlaying = true
        trace.details["timelineKeyframes"] = studio.doc.timeline.keyframes.count
        trace.details["timelineDuration"] = Double(studio.doc.timeline.duration)
    }

    /// The object the action workloads act on: `IKKOKU_PERF_ACTION_KEY`'s
    /// source object (any kind, such as a route with its children), else
    /// source key 963 (the one the ST-T03 duplicate timing used), or the first
    /// source character when the scene has no key 963.
    private func actionTarget(_ studio: StudioModel) throws -> StudioObject {
        if let key = configuration.actionKey {
            guard let object = studio.doc.objects.first(where: { $0.sourceObjectKey == key }) else {
                throw RigError.invalid("IKKOKU_PERF_ACTION_KEY: no source object with key \(key)")
            }
            return object
        }
        let characters = studio.doc.objects.filter { $0.kind == .character && $0.sourceCharacter != nil }
        guard let character = characters.first(where: { $0.sourceObjectKey == 963 }) ?? characters.first else {
            throw RigError.invalid("needs a source character")
        }
        return character
    }

    /// `studio-duplicate`: the workspace Duplicate button's call on one source
    /// character, then Undo, repeated. `studio-undo-delete`: Delete, then Undo
    /// (which restores the character), repeated. `studio-redo`: Duplicate,
    /// Undo, Redo and Undo, repeated; the Redo of a route's Duplicate
    /// rehydrates the scene's route runtime with its route characters. Live
    /// animation stays on. The object is `actionTarget`'s. It is selected
    /// before each cycle, outside the timed actions. Each action is timed from
    /// its call until no background work is pending and every preview it
    /// started is installed; `finishActions` adds the main-thread busy time
    /// and longest busy period in that span.
    private func prepareStudioHistory(_ workload: String) throws {
        let studio = try prepareStudioSource(selectKey: nil)
        let target = try actionTarget(studio)
        let id = target.id
        let select = ("select", false, { studio.selection = id })
        let gesture: String
        switch workload {
        case "studio-duplicate":
            actionSteps = [select, ("duplicate", true, { studio.duplicateSelection() }), ("undo", true, { studio.undo() })]
            gesture = "select, Duplicate, Undo"
        case "studio-redo":
            actionSteps = [select, ("duplicate", true, { studio.duplicateSelection() }), ("undo", true, { studio.undo() }),
                           ("redo", true, { studio.redo() }), ("undo of the redo", true, { studio.undo() })]
            gesture = "select, Duplicate, Undo, Redo, Undo"
        default:
            actionSteps = [select, ("delete", true, { studio.deleteSelection() }), ("undo", true, { studio.undo() })]
            gesture = "select, Delete, Undo"
        }
        trace.details["actionSourceKey"] = Int(target.sourceObjectKey ?? -1)
        trace.details["actionObjectKind"] = "\(target.kind)"
        trace.details["gesture"] = "\(gesture) on source key \(target.sourceObjectKey ?? -1), repeated; live animation on"
    }

    /// `studio-outfit`: the Clothes tab's outfit picker
    /// (`StudioModel.selectSourceOutfit`) on `actionTarget`'s character:
    /// another outfit the card saves (`IKKOKU_PERF_OUTFIT`, else the first
    /// other one), then the shown outfit back, repeated. Live animation stays
    /// on. A selection borrows the assembly the previous one kept, so only
    /// the first selection of the other outfit reads and decodes its files;
    /// with `IKKOKU_PERF_DONATIONS=off` every selection does.
    private func prepareStudioOutfit() throws {
        let studio = try prepareStudioSource(selectKey: nil)
        let target = try actionTarget(studio)
        guard target.kind == .character, let preview = studio.sourceShapePreview(for: target.id) else {
            throw RigError.invalid("studio-outfit needs a built source character")
        }
        let count = min(preview.outfitCount, SourceStudioCharacterPreview.outfitNames.count), shown = preview.coordinate
        let other: Int
        if let outfit = configuration.outfit {
            guard outfit < count, outfit != shown else {
                throw RigError.invalid("IKKOKU_PERF_OUTFIT \(outfit): the card saves \(count) outfits and shows \(shown)")
            }
            other = outfit
        } else {
            guard let first = (0..<count).first(where: { $0 != shown }) else { throw RigError.invalid("the card saves no other outfit") }
            other = first
        }
        let id = target.id
        actionSteps = [("select", false, { studio.selection = id }),
                       ("outfit", true, { studio.selectSourceOutfit(id, coordinate: other) }),
                       ("outfit back", true, { studio.selectSourceOutfit(id, coordinate: shown) })]
        trace.details["actionSourceKey"] = Int(target.sourceObjectKey ?? -1)
        trace.details["outfits"] = [shown, other]
        trace.details["gesture"] = "select, outfit \(other), outfit \(shown) on source key \(target.sourceObjectKey ?? -1), repeated; live animation on"
    }

    /// A new temporary folder for the run's scene files (`scratchFolder`).
    private func makeScratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-perf-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scratchFolder = folder
        return folder
    }

    /// `studio-export`: File ▸ Export Edited Original Scene
    /// (`AppState.exportSourceScene(to:)`), repeated, of a scene whose hidden
    /// character has a face-state edit and no preview, so each export builds
    /// that character's validation baseline. The setup uses the UI's calls:
    /// a cheek edit on `actionTarget`'s character (`setSourceExpression`),
    /// Visible off (`update`), then File ▸ Save Scene and File ▸ Open of that
    /// file, after which only the visible characters build. Each export
    /// writes a new file and removes the previous one.
    private func prepareStudioExport() throws {
        let studio = try prepareStudioSource(selectKey: nil)
        let target = try actionTarget(studio)
        guard target.kind == .character, let preview = studio.sourceShapePreview(for: target.id) else {
            throw RigError.invalid("studio-export needs a built source character")
        }
        var face = preview.expressionState
        face.cheek = face.cheek < 0.5 ? 1 : 0
        try studio.setSourceExpression(target.id, face)
        studio.update(target.id) { $0.visible = false }
        let folder = try makeScratchFolder(), scene = folder.appendingPathComponent("hidden-face.png")
        try studio.saveScene(to: scene)
        app.openScene(at: scene, importing: false)
        if let error = app.errorMessage { throw RigError.invalid(error) }
        guard studio.sourceShapePreview(for: target.id) == nil else {
            throw RigError.invalid("the hidden character was built by the load, so an export would not build its baseline")
        }
        var count = 0
        var previous: URL?
        actionSteps = [("export", true, { [weak self] in
            if let previous { try? FileManager.default.removeItem(at: previous) }
            count += 1
            let url = folder.appendingPathComponent("export-\(count).png")
            previous = url
            self?.app.exportSourceScene(to: url)
        })]
        trace.details["actionSourceKey"] = Int(target.sourceObjectKey ?? -1)
        trace.details["gesture"] = "File ▸ Export Edited Original Scene with source key \(target.sourceObjectKey ?? -1) hidden, a cheek edit and no preview, repeated; live animation on"
    }

    /// `studio-export-import` (lazy hidden characters): File ▸ Export Edited
    /// Original Scene (`AppState.exportSourceScene(to:)`) of the startup
    /// scene as imported, unedited, repeated, with live animation on. A
    /// hidden character the import left unbuilt has no edit, so the export
    /// builds no baseline for it. Each export writes a new file and removes
    /// the previous one.
    private func prepareStudioExportImport() throws {
        try prepareStudioSource(selectKey: nil)
        let folder = try makeScratchFolder()
        var count = 0
        var previous: URL?
        actionSteps = [("export", true, { [weak self] in
            if let previous { try? FileManager.default.removeItem(at: previous) }
            count += 1
            let url = folder.appendingPathComponent("export-\(count).png")
            previous = url
            self?.app.exportSourceScene(to: url)
        })]
        trace.details["gesture"] = "File ▸ Export Edited Original Scene of the imported startup scene, unedited, repeated; live animation on"
    }

    /// `studio-show-hidden` (lazy hidden characters): Visible on (the
    /// inspector's toggle, `update`) for each hidden object of the startup
    /// scene that holds source characters (its own flag off, its ancestors
    /// shown), in workspace order, each followed by Visible off again
    /// (unmeasured), repeated, with live animation on. An action's first run
    /// shows characters the import left unbuilt, so its ready time holds
    /// their build; later runs find them built. Each action is named
    /// "show <source key> (<n> characters)".
    private func prepareStudioShowHidden() throws {
        let studio = try prepareStudioSource(selectKey: nil)
        let doc = studio.doc
        let characters = doc.objects.filter { $0.kind == .character && $0.sourceCharacter != nil }
        func holds(_ root: UUID) -> Int {
            characters.filter { character in
                var current: UUID? = character.id, steps = 0
                while let id = current, steps <= doc.objects.count {
                    if id == root { return true }
                    current = doc.object(id)?.parent; steps += 1
                }
                return false
            }.count
        }
        let roots = doc.flattened().map(\.object).filter { object in
            !object.visible && (object.parent.map { doc.isVisible($0) } ?? true) && holds(object.id) > 0
        }
        guard !roots.isEmpty else { throw RigError.invalid("studio-show-hidden needs a hidden object holding source characters") }
        var steps: [(name: String, measured: Bool, run: () -> Void)] = []
        for root in roots {
            let id = root.id
            steps.append(("show \(root.sourceObjectKey ?? -1) (\(holds(id)) characters)", true, { studio.update(id) { $0.visible = true } }))
            steps.append(("hide", false, { studio.update(id) { $0.visible = false } }))
        }
        actionSteps = steps
        trace.details["hiddenRoots"] = roots.map { ["sourceKey": Int($0.sourceObjectKey ?? -1), "characters": holds($0.id)] }
        trace.details["gesture"] = "Visible on, then off, for each of \(roots.count) hidden objects holding source characters, repeated; live animation on"
    }

    /// `studio-clock-first` (lazy hidden characters): the first clock rebase
    /// and the first native save after the import, then repeated. "rebase"
    /// sets the first drawn character with a converted saved clip to its own
    /// animation speed (`setSourceAnimationSpeed`, which bakes every
    /// character's clock and restarts it); "save" is File ▸ Save
    /// (`saveScene(to:)`) to a scratch file, removed before the next one.
    /// Live animation on, so each runs on an advanced clock.
    private func prepareStudioClockFirst() throws {
        let studio = try prepareStudioSource(selectKey: nil)
        let doc = studio.doc
        guard let target = doc.objects.first(where: { object in
            object.kind == .character && doc.isVisible(object.id) && studio.sourceShapePreview(for: object.id)?.hasSavedAnimation == true
        }) else { throw RigError.invalid("studio-clock-first needs a drawn character with a converted saved clip") }
        let folder = try makeScratchFolder()
        var count = 0
        var previous: URL?
        let id = target.id
        actionSteps = [
            ("rebase", true, { [weak self] in
                guard let preview = studio.sourceShapePreview(for: id), let i = studio.doc.index(of: id) else {
                    self?.app.errorMessage = "studio-clock-first: the target character has no preview"; return
                }
                let speed = (studio.doc.objects[i].sourceAnimation ?? SourceStudioAnimationState(record: preview.record)).speed
                do { try studio.setSourceAnimationSpeed(id, speed) } catch { self?.app.errorMessage = "\(error)" }
            }),
            ("save", true, { [weak self] in
                if let previous { try? FileManager.default.removeItem(at: previous) }
                count += 1
                let url = folder.appendingPathComponent("save-\(count).png")
                previous = url
                do { try studio.saveScene(to: url) } catch { self?.app.errorMessage = "\(error)" }
            }),
        ]
        trace.details["clockTarget"] = Int(target.sourceObjectKey ?? -1)
        trace.details["gesture"] = "Animation speed set to its own value (a clock rebase), then File ▸ Save, repeated; live animation on"
    }

    /// `studio-load`: File ▸ Open (`AppState.openScene(at:importing:)`) of the
    /// source scene saved as an Ikkoku scene, after File ▸ New Scene
    /// (unmeasured), repeated. Each load replaces the empty document, so its
    /// characters build again, and the scene's route runtime with its route
    /// characters is rehydrated from the scene file. (A load over the same
    /// scene keeps the runtime its ids already have, and rehydrates nothing.)
    /// Live animation stays on.
    ///
    /// #410: with `IKKOKU_PERF_LOAD_SMALL_OBJECTS=<n>` it alternates the source
    /// scene with a small scene of `n` folders instead of New Scene, so the
    /// workspace keeps the big scene's rows as slots while the small one shows,
    /// and scrolls the workspace to its end and back in the small scene:
    /// "load" (the source scene), "load small", "scroll workspace to end"
    /// (measured) and "scroll workspace to top" (not measured), repeated.
    /// `details.workspaceScrolls` records the first scrolls' document heights.
    private func prepareStudioLoad() throws {
        let studio = try prepareStudioSource(selectKey: nil)
        let folder = try makeScratchFolder()
        let scene = folder.appendingPathComponent("scene.png")
        try studio.saveScene(to: scene)
        if let text = ProcessInfo.processInfo.environment["IKKOKU_PERF_LOAD_SMALL_OBJECTS"] {
            guard let count = Int(text), count > 0 else { throw RigError.invalid("IKKOKU_PERF_LOAD_SMALL_OBJECTS: \(text)") }
            studio.newScene()
            // Unselected, so each folder lands at the root (`add` nests a new
            // object in a selected folder): a flat list of `count` rows.
            for index in 0..<count { studio.add(StudioObject(name: "Folder \(index + 1)", kind: .folder), select: false) }
            let small = folder.appendingPathComponent("small.png")
            try studio.saveScene(to: small)
            actionSteps = [("load", true, { [weak self] in self?.app.openScene(at: scene, importing: false) }),
                           ("load small", true, { [weak self] in self?.app.openScene(at: small, importing: false) }),
                           ("scroll workspace to end", true, { [weak self] in self?.scrollWorkspace(toEnd: true) }),
                           ("scroll workspace to top", false, { [weak self] in self?.scrollWorkspace(toEnd: false) })]
            trace.details["smallSceneObjects"] = count
            trace.details["workspaceSlotCap"] = StudioWorkspaceState.slotCap
            trace.details["workspaceSlotCapOverride"] = StudioWorkspaceState.slotCapOverride.map { $0 as Any } ?? NSNull()
            // The most rows any window could show at once: the tallest
            // screen's visible height over a one-line row and its 1 pt gap.
            // The slots (`workspaceSlotCap`) must stay above it.
            if let entry = studio.shownWorkspaceState.entries.first {
                let rowHeight = Double(WorkspaceRow.fittingHeight(entry, width: 242))
                let screen = Double(NSScreen.screens.map(\.visibleFrame.height).max() ?? 0)
                trace.details["workspaceRowHeight"] = PerfTrace.round(rowHeight)
                trace.details["tallestScreenVisibleHeight"] = screen
                trace.details["workspaceMaxVisibleRows"] = rowHeight > 0 ? Int((screen / (rowHeight + 1)).rounded(.up)) : -1
            }
            trace.details["gesture"] = "File ▸ Open of the source scene saved as an Ikkoku scene, then of a scene of \(count) folders, "
                + "then the workspace scrolled to its end and back, repeated; live animation on"
            return
        }
        actionSteps = [("new scene", false, { studio.newScene() }),
                       ("load", true, { [weak self] in self?.app.openScene(at: scene, importing: false) })]
        trace.details["gesture"] = "File ▸ New Scene, then File ▸ Open of the source scene saved as an Ikkoku scene, repeated; live animation on"
    }

    /// #410: scrolls the workspace's scroll view to the end of its document or
    /// back to the top, as dragging the scroller would. The first 16 scrolls
    /// record, before scrolling, the document and visible heights and how far
    /// the view is from the document's end, so a scroll to the top shows
    /// whether the scroll before it reached the end once the stack had laid
    /// out the rows there; and the rows and slots shown
    /// (`details.workspaceScrolls`).
    private func scrollWorkspace(toEnd: Bool) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let scroll = InspectorUIScenario.workspaceScrollView(window), let document = scroll.documentView else {
            app.errorMessage = "no workspace scroll view"
            return
        }
        var scrolls = trace.details["workspaceScrolls"] as? [[String: Any]] ?? []
        if scrolls.count < 16 {
            let state = app.studio?.shownWorkspaceState
            scrolls.append(["toEnd": toEnd, "documentHeight": Double(document.frame.height),
                            "visibleHeight": Double(scroll.contentView.bounds.height),
                            "endGapBefore": PerfTrace.round(Double(InspectorUIScenario.workspaceEndGap(scroll))),
                            "flipped": document.isFlipped, "rows": state?.entries.count ?? -1])
            trace.details["workspaceScrolls"] = scrolls
        }
        InspectorUIScenario.scrollWorkspace(scroll, toEnd: toEnd)
    }

    /// `studio-voice-play` (#445, information only): the inspector's Play
    /// playlist call (`StudioModel.playSourceVoice`) on `actionTarget`'s
    /// character. Its playlist is first set, through the UI's write
    /// (`update`), to the first three rows of the scene's voice catalog
    /// (`IKKOKU_STUDIO_VOICE_CATALOG`) that have converted audio. A cycle:
    /// Stop all (`stopSourceVoices`, the call New Scene and Open make;
    /// unmeasured), then playlist index 0 (the cycle's first play), 0 again,
    /// 1, 2 and 1 again, repeated, live animation off. The voice bus renders
    /// offline (manual rendering): nothing reaches the output device and
    /// nothing pulls the graph, so a clip never ends or advances. An action is
    /// ready when its voice started or failed: the status no longer reads
    /// "Loading voice".
    private func prepareStudioVoicePlay() throws {
        let studio = try prepareStudioSource(selectKey: nil, liveAnimation: false)
        let target = try actionTarget(studio)
        guard target.kind == .character, target.sourceCharacter != nil else {
            throw RigError.invalid("studio-voice-play needs a source character")
        }
        guard let path = studio.doc.sourceVoiceCatalogFile ?? ProcessInfo.processInfo.environment["IKKOKU_STUDIO_VOICE_CATALOG"] else {
            throw RigError.invalid("studio-voice-play needs IKKOKU_STUDIO_VOICE_CATALOG")
        }
        let url = URL(fileURLWithPath: path), catalog = try SourceStudioVoiceCatalog.load(url: url)
        let rows = Array(catalog.entries.filter { $0.file != nil && $0.sha256 != nil }.prefix(3))
        guard rows.count == 3 else { throw RigError.invalid("studio-voice-play needs 3 catalog rows with converted audio") }
        let id = target.id
        studio.update(id) { $0.sourceVoice = SourceStudioVoiceState(playlist: rows.map(\.selection), repeatMode: 0) }
        try studio.sourceAudioBus.enableOfflineRendering()
        actionPending = { [weak studio] in studio?.status.hasPrefix("Loading voice") == true }
        actionSteps = [("stop all", false, { studio.stopSourceVoices() }),
                       ("play 0 first", true, { studio.playSourceVoice(id, index: 0) }),
                       ("play 0 again", true, { studio.playSourceVoice(id, index: 0) }),
                       ("play 1", true, { studio.playSourceVoice(id, index: 1) }),
                       ("play 2", true, { studio.playSourceVoice(id, index: 2) }),
                       ("play 1 again", true, { studio.playSourceVoice(id, index: 1) })]
        let directory = url.deletingLastPathComponent()
        trace.details["actionSourceKey"] = Int(target.sourceObjectKey ?? -1)
        trace.details["voiceCatalog"] = ["file": url.lastPathComponent, "bytes": (try? Data(contentsOf: url).count) ?? -1,
                                         "rows": catalog.entries.count] as [String: Any]
        trace.details["voiceClips"] = rows.enumerated().map { index, row -> [String: Any] in
            let bytes = (try? directory.appendingPathComponent(row.file ?? "").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            return ["index": index, "sha256": String((row.sha256 ?? "").prefix(12)), "bytes": bytes]
        }
        trace.details["voiceOutput"] = "offline manual rendering"
        trace.details["gesture"] = "stop all, play 0, 0, 1, 2, 1 on source key \(target.sourceObjectKey ?? -1), repeated; live animation off"
    }

    /// `studio-edit-steps` (#409): `IKKOKU_PERF_EDITS` single-object edits
    /// of `actionTarget`'s object through the inspector's call
    /// (`StudioModel.update`), each its own undo step (`endUndoCoalescing`
    /// first, as the scenario runner does per step): its x position moves
    /// 0.001, or with `IKKOKU_PERF_EDIT_FIELD=pose` its neck rotation in the
    /// pose delta turns 0.5 degrees. Each edit is followed by a same-value
    /// write, `update` with the value it has, which takes no undo step (#390):
    /// the control on the same path. Every action records the undo and redo
    /// depth and the distinct `objects` buffers the document and both stacks
    /// hold (`StudioObjectStorageCensus`), and the live-step settles in its
    /// call (`LiveCall`). With `IKKOKU_PERF_EDIT_PHASES=alternate` each call
    /// runs at the next live step's completion: odd edits after the step's
    /// commit (no step pending), even edits before it (the edit commits the
    /// finished step), each write in its edit's phase (`place`). After the
    /// edits `IKKOKU_PERF_PAUSE_AT` lists (0: before the first) a pause step
    /// holds the run for an outside reader (`pause(after:)`). The actions run
    /// once, and the run stops after the last.
    private func prepareStudioEditSteps() throws {
        let studio = try prepareStudioSource(selectKey: nil)
        let target = try actionTarget(studio)
        let id = target.id
        if !configuration.pauseAt.isEmpty {
            guard let marker = configuration.pauseMarker, marker.split(separator: "/").contains(".local") else {
                throw RigError.invalid("IKKOKU_PERF_PAUSE_AT needs IKKOKU_PERF_PAUSE_MARKER, a folder under a .local folder")
            }
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: marker), withIntermediateDirectories: true)
        }
        let edit: (inout StudioObject) -> Void, control: (inout StudioObject) -> Void
        if configuration.editField == "pose" {
            edit = { $0.poseDelta.rotations["cf_j_neck", default: .zero].x += 0.5 }
            control = { $0.poseDelta = $0.poseDelta }
        } else {
            edit = { $0.transform.position.x += 0.001 }
            control = { $0.transform.position.x = $0.transform.position.x }
        }
        let alternate = configuration.editPhases == "alternate"
        var steps: [(name: String, measured: Bool, run: () -> Void)] = []
        var phases: [StudioModel.LivePhase?] = []
        func pauseStep(_ edits: Int) {
            guard configuration.pauseAt.contains(edits) else { return }
            steps.append(("pause \(edits)", false, { [weak self] in self?.pause(after: edits) }))
            phases.append(nil)
        }
        pauseStep(0)
        for n in 1...configuration.edits {
            let phase: StudioModel.LivePhase? = alternate ? (n % 2 == 1 ? .afterCommit : .beforeCommit) : nil
            steps.append(("edit \(n)", true, {
                studio.endUndoCoalescing()
                studio.update(id, edit)
            }))
            steps.append(("same-value write \(n)", true, {
                studio.endUndoCoalescing()
                studio.update(id, control)
            }))
            phases += [phase, phase]
            pauseStep(n)
        }
        actionSteps = steps
        actionPhases = alternate ? phases : []
        stopAfterActions = true
        countHistoryStorage = true
        countLiveSettles = true
        trace.details["actionSourceKey"] = Int(target.sourceObjectKey ?? -1)
        trace.details["actionObjectKind"] = "\(target.kind)"
        trace.details["edits"] = configuration.edits
        trace.details["pauseAt"] = configuration.pauseAt.sorted()
        trace.details["studioObjectStride"] = MemoryLayout<StudioObject>.stride
        trace.details["undoLimit"] = StudioUndoHistory<StudioDocument>.limit
        trace.details["editField"] = configuration.editField
        trace.details["editPhases"] = configuration.editPhases
        let change = configuration.editField == "pose" ? "neck rotation + 0.5 in the pose delta" : "x + 0.001"
        let placed = alternate ? ", each at a live step's completion, odd edits after its commit and even edits before" : ""
        trace.details["gesture"] = "\(configuration.edits) single-object edits (\(change), each its own undo step) on source key "
            + "\(target.sourceObjectKey ?? -1), each followed by a same-value write\(placed); live animation on; run once"
    }

    /// Writes this process's id to `pause-<n>.pid` in `IKKOKU_PERF_PAUSE_MARKER`
    /// and holds the next action for `IKKOKU_PERF_PAUSE_SECONDS`. The hold is a
    /// timer, not a block, so the main run loop sleeps while an outside tool
    /// (footprint, vmmap, heap) reads this process by that id.
    private func pause(after edits: Int) {
        guard let marker = configuration.pauseMarker else { return }
        let file = URL(fileURLWithPath: marker).appendingPathComponent("pause-\(edits).pid")
        do { try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: file, options: .atomic) }
        catch { print("[ikkoku] perf pause \(edits): marker not written: \(error)") }
        holdUntil = CACurrentMediaTime() + configuration.pauseSeconds
    }

    /// `studio-select` (R7 phase 2, item 7): the selection a click makes
    /// (`selection = id`, the call of a workspace row's tap and of a viewport
    /// click on an object; a click on empty space sets nil) through a fixed
    /// list of objects, repeated, with live animation on: nothing selected,
    /// then each object of the list in order. The list is the source keys of
    /// `IKKOKU_PERF_SELECT_KEYS`, else the first object of each kind the
    /// Object tab shows differently, in workspace order (`selectKind`). The
    /// inspector shows `IKKOKU_PERF_INSPECTOR_TAB` (default Object). Each
    /// action is named for what it selects ("select route", "select
    /// character from nothing", "deselect"), and its main-thread time is the
    /// busy period it ran in, which holds SwiftUI's update of the panels.
    private func prepareStudioSelect() throws {
        let studio = try prepareStudioSource(selectKey: nil)
        let tree = studio.doc.flattened().map(\.object)
        let objects: [StudioObject]
        if let keys = configuration.selectKeys {
            objects = try keys.map { key in
                guard let object = tree.first(where: { $0.sourceObjectKey == key }) else {
                    throw RigError.invalid("IKKOKU_PERF_SELECT_KEYS: no source object with key \(key)")
                }
                return object
            }
        } else {
            var kinds = Set<String>()
            objects = tree.filter { kinds.insert(selectKind(studio, $0)).inserted }
        }
        guard !objects.isEmpty else { throw RigError.invalid("studio-select needs an object to select") }
        if let tabName = configuration.inspectorTab {
            guard let tab = StudioModel.InspectorTab.allCases.first(where: { $0.rawValue.lowercased() == tabName }) else {
                throw RigError.invalid("IKKOKU_PERF_INSPECTOR_TAB: no tab \(tabName)")
            }
            studio.inspectorTab = tab
        }
        var steps: [(name: String, measured: Bool, run: () -> Void)] = [("deselect", true, { studio.selection = nil })]
        for (index, object) in objects.enumerated() {
            let id = object.id, kind = selectKind(studio, object)
            steps.append((index == 0 ? "select \(kind) from nothing" : "select \(kind)", true, { studio.selection = id }))
        }
        actionSteps = steps
        trace.details["inspectorTab"] = studio.inspectorTab.rawValue
        trace.details["selectObjects"] = objects.map { object -> [String: Any] in
            ["sourceKey": Int(object.sourceObjectKey ?? -1), "kind": selectKind(studio, object), "name": object.name]
        }
        trace.details["gesture"] = "nothing selected, then \(objects.count) objects selected in turn as a click selects them, repeated; live animation on"
    }

    /// What the Object tab shows for `object`: its kind, or a source
    /// character, route or source camera, whose sections differ.
    private func selectKind(_ studio: StudioModel, _ object: StudioObject) -> String {
        if studio.sourceRouteRuntime(id: object.id, document: studio.doc) != nil { return "route" }
        if studio.workspaceLabel(of: object, sceneSHA256: studio.doc.sourceSceneSHA256).sourceCamera { return "source camera" }
        if object.kind == .character, object.sourceCharacter != nil { return "source character" }
        return "\(object.kind)"
    }

    private func runNextAction() {
        guard trace.recording, pendingAction == nil else { return }
        // Work a setup left (a load's builds) finishes before the first action.
        if (app.studio?.pendingSourceActionWork ?? 0) > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { self.runNextAction() }
            return
        }
        if holdUntil > 0 {
            let wait = holdUntil - CACurrentMediaTime()
            if wait > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.runNextAction() }; return }
            holdUntil = 0
        }
        if stopAfterActions, actionIndex >= actionSteps.count { stop(); return }
        if parkIfRequested() { return }
        let index = actionIndex % actionSteps.count
        actionIndex += 1
        if index < actionPhases.count, let phase = actionPhases[index], let studio = app.studio {
            place(actionSteps[index], at: phase, in: studio)
            return
        }
        call(actionSteps[index], placement: nil)
    }

    /// Where a placed call ran: its phase, whether a live step offered it in
    /// time, when the hook was armed, and the serial steps counted by then.
    private struct Placement {
        let phase: StudioModel.LivePhase
        let placed: Bool
        let armed: CFTimeInterval
        let serialSteps: Int
    }

    /// What a `studio-edit-steps` call found of the live step (#409): the
    /// settles in it that found a step pending, and of those the ones that
    /// waited for running workers. A placed call adds its `Placement`, the
    /// serial live steps from arming to the call's end, and the build work
    /// pending at the call.
    private struct LiveCall {
        let pendingSettles: Int
        let unfinishedWaits: Int
        let placement: Placement?
        let serialSteps: Int
        let pendingWork: Int
        /// #446: the call's `update` writes, and those that copied the
        /// document's object list (0 when nothing else holds it).
        let updateWrites: Int
        let updateWritesMoved: Int
        /// Copies a whole-document step owed (it shared the list).
        let updateWritesOwed: Int
        /// Copies a pending export held (it keeps the document it was chosen for).
        let updateWritesExportHeld: Int
        /// #446: the model's `undoPatchConversions` at the call's start; a
        /// row records the conversions from it to the next action's call.
        let patchConversionsAtCall: Int
    }

    /// Arms the Studio's `livePhaseHook` so the action's call runs at the next
    /// live step's completion that offers `phase`. Half a second without one
    /// (about 15 steps) runs the call unplaced, recorded as such.
    private func place(_ step: (name: String, measured: Bool, run: () -> Void), at phase: StudioModel.LivePhase,
                       in studio: StudioModel) {
        placements += 1
        let token = placements
        waitingPlacement = (token, step, phase, CACurrentMediaTime(), PerfTrace.eventCount(.studioLiveTickSerial))
        studio.livePhaseHook = (phase, { [weak self] in self?.placedCall(token, placed: true) })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.placedCall(token, placed: false) }
    }

    /// The waiting call `token`, at its phase (`placed`) or after the timeout.
    private func placedCall(_ token: Int, placed: Bool) {
        guard let waiting = waitingPlacement, waiting.token == token else { return }
        waitingPlacement = nil
        if !placed { app.studio?.livePhaseHook = nil }
        guard trace.recording else { return }
        call(waiting.step, placement: Placement(phase: waiting.phase, placed: placed, armed: waiting.armed,
                                                serialSteps: waiting.serialSteps))
    }

    /// Runs one action's call, timed by the media clock (`callMs`) and by the
    /// main thread's CPU time (`callCpuMs`, read right before the start and
    /// right after the end), then waits for its builds.
    private func call(_ step: (name: String, measured: Bool, run: () -> Void), placement: Placement?) {
        let studio = countLiveSettles ? app.studio : nil
        let settles = studio?.livePendingSettles ?? 0, waits = studio?.liveUnfinishedWaits ?? 0
        let pendingWork = studio?.pendingSourceActionWork ?? 0
        let writes = studio?.updateWrites ?? 0, moved = studio?.updateWritesMoved ?? 0, owed = studio?.updateWritesOwed ?? 0
        let exportHeld = studio?.updateWritesExportHeld ?? 0
        let conversions = studio?.undoPatchConversions ?? 0
        let bodies = Self.workspaceBodyViews.map(PerfTrace.bodyCount)
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let start = CACurrentMediaTime()
        step.run()
        let end = CACurrentMediaTime()
        let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpu) / 1e6
        let live = studio.map { studio in
            LiveCall(pendingSettles: studio.livePendingSettles &- settles, unfinishedWaits: studio.liveUnfinishedWaits &- waits,
                     placement: placement,
                     serialSteps: placement.map { PerfTrace.eventCount(.studioLiveTickSerial) - $0.serialSteps } ?? 0,
                     pendingWork: pendingWork,
                     updateWrites: studio.updateWrites &- writes, updateWritesMoved: studio.updateWritesMoved &- moved,
                     updateWritesOwed: studio.updateWritesOwed &- owed,
                     updateWritesExportHeld: studio.updateWritesExportHeld &- exportHeld,
                     patchConversionsAtCall: conversions)
        }
        pendingAction = (step.name, step.measured, start, end, bodies, cpuMs, live)
        waitForAction()
    }

    /// #440 (`IKKOKU_PERF_PARK_FILE`, measurement only): at the start of every
    /// action cycle but the first, a park file that reads `park <n>`, with `n`
    /// newer than the last park, stops the actions. The driver writes
    /// `<file>.parked` (`parked <n> <measured actions finished> <next action's
    /// index> <cycle length>`) and waits until the file reads `resume <n>`, so
    /// both of the growth check's heap snapshots see the state a full cycle
    /// leaves. Both files are written in place; nothing is deleted. Returns
    /// true when it parked: the wait starts the next action.
    private func parkIfRequested() -> Bool {
        guard let file = configuration.parkFile, actionIndex > 0, actionIndex % actionSteps.count == 0,
              let request = Self.parkFileNumber(file, after: "park"), request > lastPark else { return false }
        let measured = finishedActions.reduce(0) { $0 + ($1.measured ? 1 : 0) }
        do {
            try "parked \(request) \(measured) \(actionIndex) \(actionSteps.count)\n"
                .write(toFile: file + ".parked", atomically: false, encoding: .utf8)
        } catch { fail("IKKOKU_PERF_PARK_FILE: \(error)") }
        parks.append(["park": request, "measured": measured, "index": actionIndex,
                      "startSeconds": PerfTrace.round(CACurrentMediaTime() - recordingStart)])
        trace.details["parks"] = parks
        waitForResume(file, request)
        return true
    }

    private func waitForResume(_ file: String, _ request: Int) {
        guard trace.recording else { return }
        if Self.parkFileNumber(file, after: "resume") == request {
            lastPark = request
            runNextAction()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitForResume(file, request) }
        }
    }

    /// The number after `word` when the park file reads `<word> <n>`, else nil.
    private static func parkFileNumber(_ file: String, after word: String) -> Int? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, parts[0] == word else { return nil }
        return Int(parts[1])
    }

    /// Polls every millisecond until the pending action's builds are installed,
    /// then starts the next action half a second later.
    private func waitForAction() {
        guard let action = pendingAction else { return }
        guard trace.recording else { pendingAction = nil; return }
        if (app.studio?.pendingSourceActionWork ?? 0) > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { self.waitForAction() }
            return
        }
        // #445: a workload's own background work (a voice still loading).
        if actionPending?() == true {
            actionWaited = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { self.waitForAction() }
            return
        }
        let installed = PerfTrace.lastCharacterInstall
        var ready = installed >= action.start ? max(action.end, installed) : action.end
        if actionWaited { ready = max(ready, CACurrentMediaTime()); actionWaited = false }
        let error = app.errorMessage
        app.errorMessage = nil
        // The process footprint and Metal allocation when the action is ready:
        // flat across repeated loads means nothing accumulates per cycle. The
        // document's object count (read after the timed span) shows what an
        // edit added or an undo restored.
        let history = countHistoryStorage ? app.studio.map { studio in
            (studio.undoDepth, studio.redoDepth,
             StudioObjectStorageCensus.count(current: studio.doc, history: studio.undoHistory))
        } : nil
        finishedActions.append((action.name, action.measured, action.start, action.end, ready, app.studio?.status ?? "", error,
                                PerfTrace.footprint(), trace.device?.currentAllocatedSize ?? 0, app.studio?.doc.objects.count ?? -1,
                                action.bodies, app.studio?.shownWorkspaceState.entries.count ?? -1, history,
                                action.cpuMs, action.live))
        pendingAction = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + (action.measured ? 0.5 : 0.2)) { self.runNextAction() }
    }

    /// `details.actions`: per finished action, its name, start (seconds since
    /// recording began), the call's own duration, the time until its builds
    /// were installed, and the main thread's busy time and longest busy
    /// period (a stall) from the call until then. A busy period that began
    /// before the call counts from the call; one that is still running when
    /// the action is ready counts whole. `busyOwnMs` is the same busy time
    /// clipped at the next action's call: a busy period lasts until the run
    /// loop sleeps, and when an action's SwiftUI update outlasts the gap to
    /// the next action, `busyMs` of both counts the shared period.
    private func finishActions() {
        // The period still running (the stop timer may fire in the same
        // run-loop pass as a long action) counts until now.
        let busy = trace.busyIntervals + (trace.openBusyStart.map { [($0, CACurrentMediaTime())] } ?? [])
        let bodiesNow = Self.workspaceBodyViews.map(PerfTrace.bodyCount)
        let conversionsNow = app.studio?.undoPatchConversions ?? 0
        trace.details["actions"] = finishedActions.indices.map { index -> [String: Any] in
            let action = finishedActions[index]
            let next = index + 1 < finishedActions.count ? finishedActions[index + 1].start : .infinity
            // #410: bodies from this call to the next action's call (or until now).
            let bodiesEnd = index + 1 < finishedActions.count ? finishedActions[index + 1].bodies : bodiesNow
            let bodies = Dictionary(uniqueKeysWithValues: Self.workspaceBodyViews.indices.map {
                (Self.workspaceBodyViews[$0].name, bodiesEnd[$0] - action.bodies[$0])
            })
            let overlapping = busy.filter { $0.end > action.start && $0.start <= action.ready }
            let lengths = overlapping.map { ($0.end - max($0.start, action.start)) * 1000 }
            let own = overlapping.map { max(0, min($0.end, next) - max($0.start, action.start)) * 1000 }
            var row: [String: Any] = ["name": action.name, "measured": action.measured,
                    "startSeconds": PerfTrace.round(action.start - recordingStart),
                    "callMs": PerfTrace.round((action.end - action.start) * 1000),
                    "readyMs": PerfTrace.round((action.ready - action.start) * 1000),
                    "busyMs": PerfTrace.round(lengths.reduce(0, +)),
                    "busyOwnMs": PerfTrace.round(own.reduce(0, +)),
                    "longestStallMs": PerfTrace.round(lengths.max() ?? 0),
                    "status": action.status, "error": action.error.map { $0 as Any } ?? NSNull(),
                    "footprintBytes": action.footprint, "metalAllocatedBytes": action.metal,
                    "documentObjects": action.objects,
                    "workspaceBodies": bodies, "workspaceRows": action.workspaceRows]
            row["callCpuMs"] = PerfTrace.round(action.cpuMs)
            if let history = action.history {
                row["undoSteps"] = history.undo; row["redoSteps"] = history.redo
                row["objectBuffers"] = history.storage.buffers; row["objectBufferCapacity"] = history.storage.capacity
                row["objectBufferBytes"] = history.storage.bytes
            }
            if let live = action.live {
                row["livePendingSettles"] = live.pendingSettles; row["liveUnfinishedWaits"] = live.unfinishedWaits
                row["updateWrites"] = live.updateWrites; row["updateWritesMoved"] = live.updateWritesMoved
                row["updateWritesOwed"] = live.updateWritesOwed; row["updateWritesExportHeld"] = live.updateWritesExportHeld
                // #446: patch steps turned into whole documents from this call
                // to the next action's (or until now), each at most once: 1
                // per edit where plug-ins or animation write every frame, 0
                // where nothing writes between edits.
                let conversionsEnd = index + 1 < finishedActions.count
                    ? finishedActions[index + 1].live?.patchConversionsAtCall ?? conversionsNow : conversionsNow
                row["patchConversions"] = conversionsEnd &- live.patchConversionsAtCall
                if let placement = live.placement {
                    row["livePhase"] = placement.phase.rawValue; row["placed"] = placement.placed
                    row["placementWaitMs"] = PerfTrace.round((action.start - placement.armed) * 1000)
                    row["liveSerialSteps"] = live.serialSteps; row["pendingWorkAtCall"] = live.pendingWork
                }
            }
            return row
        }
    }

    /// Tears the viewport down and builds it again (Maker and Studio each own
    /// one, so a mode switch replaces it), resizes the window, minimizes and
    /// restores it, all while the display link draws, then quits through
    /// `NSApp.terminate`. The report's `details.lifecycle` records, before
    /// each step and at the end, the viewport render threads alive and the
    /// live-pacing hand-over: the mode, the viewports that render, which
    /// models have live steps, which models a display link paces, and how
    /// many paced steps each has run.
    /// It also records the frames drawn and presented after the restore. The
    /// Studio holds `studio-native`'s scene, and both models' live animation
    /// is on.
    private func prepareViewportLifecycle() throws {
        guard app.ensureMaker() != nil, app.studio != nil else { throw RigError.invalid("needs the Maker and the Studio") }
        // Both models have live steps, so the hand-over is checked both ways.
        try prepareStudioNative()
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
        add("miniaturize", settle: 1.5) { window.miniaturize(nil); self.minimizedAt = CACurrentMediaTime() }
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
        var entry = pacingState()
        entry["step"] = name
        entry["seconds"] = PerfTrace.round(CACurrentMediaTime() - recordingStart)
        entry["renderThreadsBefore"] = Self.renderThreadCount()
        lifecycleLog.append(entry)
        action()
    }

    /// The live-pacing hand-over (R7 phase 2): the active mode, the models
    /// whose viewports render (a switch replaces the viewport once SwiftUI
    /// updates), which models have live steps to run when active,
    /// which models a display link paces, and the paced steps each has run.
    private func pacingState() -> [String: Any] {
        ["mode": app.mode == .maker ? "maker" : "studio",
         "viewports": viewportModels(),
         "live": ["maker": app.maker?.liveAnimation ?? false, "studio": app.studio?.hasLiveStepWork ?? false],
         "livePaced": ["maker": app.maker?.isLivePaced ?? false, "studio": app.studio?.isLivePaced ?? false],
         "pacedSteps": ["maker": app.maker?.pacedSteps ?? 0, "studio": app.studio?.pacedSteps ?? 0]]
    }

    /// The models of the viewports that render now, sorted. A dismantled
    /// viewport can stay in the window until SwiftUI removes it; it is not
    /// counted.
    private func viewportModels() -> [String] {
        var models: [String] = []
        func visit(_ view: NSView) {
            if let viewport = view as? ViewportNSView, viewport.isRendering {
                let handler = viewport.handler
                models.append(handler === app.maker ? "maker" : handler === app.studio ? "studio" : "other")
            }
            view.subviews.forEach(visit)
        }
        for window in NSApp.windows { if let content = window.contentView { visit(content) } }
        return models.sorted()
    }

    private func finishLifecycle() {
        var result: [String: Any] = ["steps": lifecycleLog, "renderThreadsAtEnd": Self.renderThreadCount(),
                                     "windowMiniaturized": NSApp.windows.contains { $0.isMiniaturized },
                                     "end": pacingState()]
        if let restoredAt {
            // Drawables presented more than half a second after the restore:
            // the display link kept running across minimize and restore.
            let presented = trace.drawLog.presentLog.snapshot()
            result["presentedAfterRestore"] = presented.filter { $0 > restoredAt + 0.5 }.count
            result["drawsAfterRestore"] = trace.drawLog.snapshot().samples.filter { $0.callback > restoredAt + 0.5 }.count
            if let minimizedAt {
                // From half a second after minimizing (the occlusion change
                // has arrived) to the restore: the viewport shows nothing, so
                // no keep-alive refresh may present (R7 phase 2, item 4).
                let hidden = trace.drawLog.snapshot().samples.filter { $0.callback > minimizedAt + 0.5 && $0.callback < restoredAt }
                result["callbacksWhileMinimized"] = hidden.count
                result["refreshesWhileMinimized"] = hidden.filter { $0.outcome == .refreshed }.count
            }
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
