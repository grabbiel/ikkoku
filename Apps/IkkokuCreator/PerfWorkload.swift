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
    private var pendingAction: (name: String, measured: Bool, start: CFTimeInterval, end: CFTimeInterval)?
    private var finishedActions: [(name: String, measured: Bool, start: CFTimeInterval, end: CFTimeInterval, ready: CFTimeInterval,
                                   status: String, error: String?)] = []
    /// The temporary folder `studio-export` and `studio-load` write scene
    /// files to, removed when the run stops.
    private var scratchFolder: URL?

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
            do { try self.prepare() } catch { self.fail("\(self.configuration.workload): \(error)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.configuration.warmupSeconds) { self.record() }
        }
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
        guard !characters.isEmpty || routeCharacters > 0 else { throw RigError.invalid("needs IKKOKU_SOURCE_SCENE with converted source characters") }
        app.mode = .studio
        studio.liveAnimation = liveAnimation
        trace.details["liveAnimation"] = liveAnimation
        studio.selection = selectKey.flatMap { key in studio.doc.objects.first { $0.sourceObjectKey == key }?.id }
        trace.details["sourceCharacters"] = characters.count
        trace.details["sourceRouteCharacters"] = routeCharacters
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

    /// `studio-load`: File ▸ Open (`AppState.openScene(at:importing:)`) of the
    /// source scene saved as an Ikkoku scene, after File ▸ New Scene
    /// (unmeasured), repeated. Each load replaces the empty document, so its
    /// characters build again, and the scene's route runtime with its route
    /// characters is rehydrated from the scene file. (A load over the same
    /// scene keeps the runtime its ids already have, and rehydrates nothing.)
    /// Live animation stays on.
    private func prepareStudioLoad() throws {
        let studio = try prepareStudioSource(selectKey: nil)
        let scene = try makeScratchFolder().appendingPathComponent("scene.png")
        try studio.saveScene(to: scene)
        actionSteps = [("new scene", false, { studio.newScene() }),
                       ("load", true, { [weak self] in self?.app.openScene(at: scene, importing: false) })]
        trace.details["gesture"] = "File ▸ New Scene, then File ▸ Open of the source scene saved as an Ikkoku scene, repeated; live animation on"
    }

    private func runNextAction() {
        guard trace.recording, pendingAction == nil else { return }
        // Work a setup left (a load's builds) finishes before the first action.
        if (app.studio?.pendingSourceActionWork ?? 0) > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { self.runNextAction() }
            return
        }
        let step = actionSteps[actionIndex % actionSteps.count]
        actionIndex += 1
        let start = CACurrentMediaTime()
        step.run()
        pendingAction = (step.name, step.measured, start, CACurrentMediaTime())
        waitForAction()
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
        let installed = PerfTrace.lastCharacterInstall
        let ready = installed >= action.start ? max(action.end, installed) : action.end
        let error = app.errorMessage
        app.errorMessage = nil
        finishedActions.append((action.name, action.measured, action.start, action.end, ready, app.studio?.status ?? "", error))
        pendingAction = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + (action.measured ? 0.5 : 0.2)) { self.runNextAction() }
    }

    /// `details.actions`: per finished action, its name, start (seconds since
    /// recording began), the call's own duration, the time until its builds
    /// were installed, and the main thread's busy time and longest busy
    /// period (a stall) from the call until then. A busy period that began
    /// before the call counts from the call; one that is still running when
    /// the action is ready counts whole.
    private func finishActions() {
        // The period still running (the stop timer may fire in the same
        // run-loop pass as a long action) counts until now.
        let busy = trace.busyIntervals + (trace.openBusyStart.map { [($0, CACurrentMediaTime())] } ?? [])
        trace.details["actions"] = finishedActions.map { action -> [String: Any] in
            let overlapping = busy.filter { $0.end > action.start && $0.start <= action.ready }
            let lengths = overlapping.map { ($0.end - max($0.start, action.start)) * 1000 }
            return ["name": action.name, "measured": action.measured,
                    "startSeconds": PerfTrace.round(action.start - recordingStart),
                    "callMs": PerfTrace.round((action.end - action.start) * 1000),
                    "readyMs": PerfTrace.round((action.ready - action.start) * 1000),
                    "busyMs": PerfTrace.round(lengths.reduce(0, +)),
                    "longestStallMs": PerfTrace.round(lengths.max() ?? 0),
                    "status": action.status, "error": action.error.map { $0 as Any } ?? NSNull()]
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
