import Foundation
import AppKit
import Gameplay
import Character
import Studio
import Renderer
import Scene
import ShaderTypes
import CoreMath
import CryptoKit
import simd

/// Deterministic app-level checks entered through the existing Studio scenario
/// mode. The barrier wraps the real immutable preparation; no result is faked.
struct PluginLibraryScenario: Decodable {
    let requestFile: String
    /// Diagnostic only: actual async initial installation versus fresh profiles.
    let libraryAttachmentInstall: LibraryAttachmentInstall?
    /// Diagnostic only: saved pending roots plus attachment-reading restoration.
    let pendingAttachmentRestore: PendingAttachmentRestore?
    /// Separate supported saved-root matrix; leaves the historical diagnostic intact.
    let pendingAttachmentAcceptance: PendingAttachmentAcceptance?
    /// Supported initial-mount transaction and real native save/fresh reopen.
    let initialLibraryAttachments: InitialLibraryAttachments?
    /// Reproduction only: real library save/reopen across the attachment-read gate.
    let libraryAttachmentRestore: LibraryAttachmentRestore?
    /// Separate supported-path matrix; preserves the original policy reproduction.
    let libraryAttachmentAcceptance: LibraryAttachmentAcceptance?
    /// Reproduction only: direct profile/native loads versus the mixed graph.
    let directPluginGraph: DirectPluginGraph?
    /// Regression only: saved mixed graph identity across native open/history.
    let nativeGraphRestore: NativeGraphRestore?
    /// Regression only: actual NotificationCenter registration/removal delivery.
    let focusObserverLifecycle: FocusObserverLifecycle?
    /// Reproduction only: exact observer-token lifetime after model disposal.
    let focusOwnerLifetime: FocusOwnerLifetime?
    /// Regression only: real preview/Animator rollback after a failed frame.
    let frameRollback: FrameRollback?
    /// Regression only: route-child placement across a rejected plugin frame.
    let routeRollback: RouteRollback?
    /// Optional diagnostics only; no timing work in ordinary plugin frames.
    let routeCheckpointCost: RouteCheckpointCost?
    /// Source-backed fresh-profile callback and failure-isolation checks.
    let reproduceFreshProfileFailure: Bool?
    /// Reproduction only: save and reopen run in separate owned processes.
    let nativeProfileRestore: NativeProfileRestore?
    /// Regression only: attachment-free constructor replay across native save/open.
    let initializerProfileRestore: NativeProfileRestore?
    /// Queued Awake destruction across paused native save/open.
    let pendingDestructionRestore: NativeProfileRestore?
    /// Separate malformed-state/history checks; leaves the original pair intact.
    let validatePendingDestructionPolicy: Bool?
    struct NativeProfileRestore: Decodable {
        enum Phase: String, Decodable { case save, reopen }
        let phase: Phase
        let directory: String
    }
    /// Stops only the dedicated CPU worker; the main actor remains responsive.
    private final class Barrier: @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false, released = false
        private var entry: CheckedContinuation<Void, Never>?
        func hold() {
            condition.lock()
            entered = true; entry?.resume(); entry = nil
            while !released { condition.wait() }
            condition.unlock()
        }
        func wait() async {
            await withCheckedContinuation { continuation in
                condition.lock(); defer { condition.unlock() }
                if entered { continuation.resume() } else { entry = continuation }
            }
        }
        func finish() {
            condition.lock(); released = true; condition.broadcast(); condition.unlock()
        }
    }

    @MainActor func run(app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        if let pendingAttachmentAcceptance { return await verifyPendingAttachmentAcceptance(pendingAttachmentAcceptance, app: app, studio: studio) }
        if let pendingAttachmentRestore { return await reproducePendingAttachmentRestore(pendingAttachmentRestore, app: app, studio: studio) }
        if let initialLibraryAttachments { return await verifyInitialLibraryAttachments(initialLibraryAttachments, app: app, studio: studio) }
        if let libraryAttachmentInstall { return await reproduceLibraryAttachmentInstall(libraryAttachmentInstall, app: app, studio: studio) }
        if let libraryAttachmentAcceptance { return await verifyLibraryAttachmentRestore(libraryAttachmentAcceptance, app: app, studio: studio) }
        if let libraryAttachmentRestore { return await reproduceLibraryAttachmentRestore(libraryAttachmentRestore, app: app, studio: studio) }
        if let nativeGraphRestore { return reproduceNativeGraphRestore(nativeGraphRestore, app: app, studio: studio) }
        if let directPluginGraph { return reproduceDirectPluginGraph(directPluginGraph, app: app, studio: studio) }
        if let focusObserverLifecycle { return verifyFocusObserverLifecycle(focusObserverLifecycle, app: app, studio: studio) }
        if let focusOwnerLifetime { return reproduceFocusOwnerLifetime(focusOwnerLifetime, app: app, studio: studio) }
        if let routeCheckpointCost { return measureRouteCheckpointCost(routeCheckpointCost, app: app, studio: studio) }
        if let routeRollback { return await reproduceRouteRollback(routeRollback, app: app, studio: studio) }
        if let frameRollback { return await reproduceFrameRollback(frameRollback, app: app, studio: studio) }
        if let pendingDestructionRestore {
            return await reproduceInitializerRestore(pendingDestructionRestore, app: app, studio: studio, pendingDestruction: true)
        }
        if let initializerProfileRestore { return await reproduceInitializerRestore(initializerProfileRestore, app: app, studio: studio) }
        if let nativeProfileRestore { return await reproduceNativeRestore(nativeProfileRestore, app: app, studio: studio) }
        if reproduceFreshProfileFailure == true { return await reproduceFreshLoad(app: app, studio: studio) }
        var rows: [StudioScenario.Report.StepResult] = []
        func check(_ name: String, _ condition: Bool, _ detail: String = "") throws {
            rows.append(.init(op: name, ok: condition, detail: detail))
            if !condition { throw SourcePluginError.runtime("Plugin scenario assertion failed: \(name)") }
        }
        func resourceCounts() -> [Int] {
            let value = studio.host.renderer.resources.statistics()
            return [value.meshes, value.textures, value.deformBuffers, value.hiddenBuffers,
                value.meshBufferBytes, value.deformBufferBytes, value.hiddenBufferBytes, value.retiring]
        }
        func sameFrame(_ a: RenderFrame, _ b: RenderFrame) -> Bool {
            a.camera == b.camera && a.mainLight == b.mainLight && a.effects == b.effects && a.lights == b.lights
                && a.sceneBounds == b.sceneBounds && a.time == b.time && a.skinSets == b.skinSets
                && a.gizmos.count == b.gizmos.count && a.items.count == b.items.count
                && zip(a.items, b.items).allSatisfy { $0.mesh == $1.mesh && $0.model == $1.model && $0.objectID == $1.objectID }
        }
        let commandScratch = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-plugin-commands-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: commandScratch) }
        let absentProfile = commandScratch.appendingPathComponent("absent.json")
        // The missing path distinguishes a pre-I/O ownership rejection from a
        // normal loader error. Compare the real runtime snapshot, not just doc.
        func rejectProfile(_ name: String, generation: UInt64, toggle: Bool) throws {
            let document = studio.doc, session = studio.sourcePluginSession
            let runtime = try session?.savedDocument(), adapter = studio.sourceFocus.adapter
            let frame = studio.host.renderer.currentFrame(), resources = resourceCounts()
            let status = studio.status, running = studio.sourcePluginsRunning
            let pending = studio.sourcePluginLibraryPending, currentGeneration = studio.sourcePluginMountGeneration
            let time = studio.sourceAnimationTime, gain = studio.sourceAudioBus.masterVolume
            var cancelled = false
            do { try studio.loadSourcePluginProfileInteractively(profileURL: absentProfile, expectedGeneration: generation) }
            catch is CancellationError { cancelled = true }
            if toggle { studio.toggleSourcePluginPlayback(); studio.unloadSourcePluginsInteractively() }
            let afterRuntime = try studio.sourcePluginSession?.savedDocument()
            try check(name, cancelled && (!toggle || !studio.canToggleSourcePluginPlayback)
                && studio.doc == document && studio.sourcePluginSession === session && afterRuntime == runtime
                && studio.sourceFocus.adapter === adapter && studio.sourceAudioBus.masterVolume == gain
                && studio.status == status && studio.sourcePluginsRunning == running
                && studio.sourcePluginLibraryPending == pending && studio.sourcePluginMountGeneration == currentGeneration
                && studio.sourceAnimationTime == time && resources == resourceCounts()
                && sameFrame(frame, studio.host.renderer.currentFrame()),
                "Cancellation before absent-file I/O; document, runtime fields/clocks, session, focus adapter/gain, status, pending request, sampled frame and resources unchanged")
        }
        func checkMount(_ name: String, _ expected: [PluginMountSummary.Section]) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let actual = try encoder.encode(studio.sourcePluginMountSummary?.sections ?? [])
            try check(name, actual == (try encoder.encode(expected)), String(decoding: actual, as: UTF8.self))
        }
        do {
            let request = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: requestFile))
            let initial = request.configuration
            guard initial.bindings.count == 1 else { throw SourcePluginError.invalid("Plugin scenario needs one controlled converted binding.") }
            var target = StudioObject(name: "Plugin target", kind: .folder); target.sourceObjectKey = 10
            var other = StudioObject(name: "Replacement target", kind: .folder); other.sourceObjectKey = 11
            var doc = StudioDocument(); doc.sourceSceneSHA256 = String(repeating: "a", count: 64); doc.objects = [target, other]
            studio.liveAnimation = false; studio.doc = doc; app.mode = .studio
            let binding = initial.bindings[0]
            func configuration(_ key: Int32) -> SourceStudioPluginConfiguration {
                .init(fixedDeltaTime: initial.fixedDeltaTime, bindings: [.init(guid: binding.guid, type: binding.type, sourceObjectKey: key)])
            }
            let mountStart = ProcessInfo.processInfo.systemUptime
            try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(10))
            try check("mount", studio.doc.sourcePluginLibrary == request.selection && studio.sourceAccessoryNamesEnabled
                && studio.sourceFocus.adapter != nil && studio.sourcePluginSession != nil,
                "Initial UI-path mount wall \((ProcessInfo.processInfo.systemUptime - mountStart) * 1000) ms; preparation, scheduling and commit combined")
            try checkMount("libraryMountSummary", [.init(origin: .library, generation: request.selection.generation,
                plugins: request.selection.revisions.map { .init(guid: $0.guid, version: $0.version, manifestSHA256: $0.manifestSHA256) })])
            try studio.stepSourcePlugins(deltaTime: 0.02)
            let firstSession = studio.sourcePluginSession, firstState = try firstSession?.savedDocument()
            try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(10))
            try check("sameSelectionNoop", firstSession === studio.sourcePluginSession && firstState == studio.doc)

            // Old runtime ticks may continue during immutable package preparation.
            let runningBarrier = Barrier()
            defer { runningBarrier.finish() }
            studio.sourcePluginPreparationHook = { runningBarrier.hold() }
            let replacement = Task { try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(11)) }
            await runningBarrier.wait()
            try rejectProfile("pendingLegacyCommands", generation: studio.sourcePluginMountGeneration, toggle: true)
            try studio.stepSourcePlugins(deltaTime: 0.02)
            runningBarrier.finish(); try await replacement.value
            studio.sourcePluginPreparationHook = nil
            try check("runningReplacement", studio.doc.sourcePluginLibraryConfiguration == configuration(11)
                && firstSession !== studio.sourcePluginSession)

            // Static ownership assertions must not race either editor's normal
            // 30 Hz timer. Running replacement above advances the old runtime
            // explicitly through the same production step path.
            studio.sourcePluginsRunning = false
            app.maker?.liveAnimation = false

            for boundary in ["modeExit", "modeExitAndReturn", "documentEditAndReturn", "callerCancel"] {
                let before = studio.doc, session = studio.sourcePluginSession, adapter = studio.sourceFocus.adapter
                let resources = resourceCounts()
                let barrier = Barrier()
                defer { barrier.finish() }
                studio.sourcePluginPreparationHook = { barrier.hold() }
                let pending = Task { try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(10)) }
                await barrier.wait()
                let cancellationStart = ProcessInfo.processInfo.systemUptime
                if boundary.hasPrefix("mode") {
                    app.mode = .maker
                    if boundary == "modeExitAndReturn" { app.mode = .studio }
                } else if boundary == "documentEditAndReturn" {
                    studio.doc.name = "Changed during preparation"; studio.doc = before
                } else {
                    // This does not call the model cancellation method: exercise
                    // the queue's cancellation handler from another executor.
                    await Task.detached { pending.cancel() }.value
                }
                let frame = studio.host.renderer.currentFrame()
                let boundaryResources = resourceCounts()
                var cancelled = false
                do { try await pending.value } catch is CancellationError { cancelled = true }
                try check(boundary + "CallerBeforeWorkerRelease", cancelled && !studio.sourcePluginLibraryPending
                    && studio.sourcePluginLibraryPreparationQueue.isRunning
                    && !studio.sourcePluginLibraryPreparationQueue.hasPending,
                    "Caller returned in \((ProcessInfo.processInfo.systemUptime - cancellationStart) * 1000) ms with resolver still held; functional diagnostic, including context change")
                barrier.finish()
                await studio.sourcePluginLibraryPreparationQueue.drain()
                studio.sourcePluginPreparationHook = nil
                let invariants = ["cancelled": cancelled, "document": studio.doc == before,
                    "session": studio.sourcePluginSession === session, "adapter": studio.sourceFocus.adapter === adapter,
                    "notPending": !studio.sourcePluginLibraryPending, "resources": resources == resourceCounts(),
                    "frame": sameFrame(frame, studio.host.renderer.currentFrame())]
                let detail = invariants.keys.sorted().map { "\($0)=\(invariants[$0]!)" }.joined(separator: ", ")
                    + "; resources before=\(resources), boundary=\(boundaryResources), after=\(resourceCounts())"
                    + "; Maker live=\(app.maker?.liveAnimation ?? false), skinSets equal=\(frame.skinSets == studio.host.renderer.currentFrame().skinSets)"
                try check(boundary, invariants.values.allSatisfy { $0 }, detail)
                app.mode = .studio
            }

            // Supersession is an enqueue witness, distinct from context/caller
            // cancellation above. The sentinel must never execute: awaiting its
            // cancellation proves the real retry replaced it in the same queue.
            let beforeRetry = studio.doc, retrySession = studio.sourcePluginSession
            let retryAdapter = studio.sourceFocus.adapter, retryResources = resourceCounts()
            let retryFrame = studio.host.renderer.currentFrame()
            let heldBarrier = Barrier(), retryBarrier = Barrier()
            defer { heldBarrier.finish(); retryBarrier.finish() }
            studio.sourcePluginPreparationHook = { heldBarrier.hold() }
            let held = Task { try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(10)) }
            await heldBarrier.wait()
            let sentinel = Task {
                try await studio.sourcePluginLibraryPreparationQueue.prepare {
                    throw SourcePluginError.runtime("Superseded enqueue witness unexpectedly executed")
                }
            }
            var heldCancelled = false
            do { try await held.value } catch is CancellationError { heldCancelled = true }
            try check("enqueueWitnessReady", heldCancelled && !studio.sourcePluginLibraryPending
                && studio.sourcePluginLibraryPreparationQueue.isRunning
                && studio.sourcePluginLibraryPreparationQueue.hasPending)
            studio.sourcePluginPreparationHook = { retryBarrier.hold() }
            let retry = Task { try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(10)) }
            var sentinelCancelled = false
            do { _ = try await sentinel.value } catch is CancellationError { sentinelCancelled = true }
            try check("retryQueuedBehindDiscardedWorker", sentinelCancelled && studio.sourcePluginLibraryPending
                && studio.sourcePluginLibraryPreparationQueue.isRunning
                && studio.sourcePluginLibraryPreparationQueue.hasPending
                && studio.doc == beforeRetry && studio.sourcePluginSession === retrySession
                && studio.sourceFocus.adapter === retryAdapter && resourceCounts() == retryResources
                && sameFrame(retryFrame, studio.host.renderer.currentFrame()))
            heldBarrier.finish()
            await retryBarrier.wait()
            try check("discardedCompletionRetainsRetry", studio.sourcePluginLibraryPending
                && studio.sourcePluginLibraryPreparationQueue.isRunning
                && !studio.sourcePluginLibraryPreparationQueue.hasPending
                && studio.doc == beforeRetry && studio.sourcePluginSession === retrySession
                && studio.sourceFocus.adapter === retryAdapter && resourceCounts() == retryResources
                && sameFrame(retryFrame, studio.host.renderer.currentFrame()))
            retryBarrier.finish(); try await retry.value
            await studio.sourcePluginLibraryPreparationQueue.drain()
            studio.sourcePluginPreparationHook = nil
            studio.sourcePluginsRunning = false
            try check("onlyRetryCommits", studio.doc.sourcePluginLibraryConfiguration == configuration(10)
                && studio.sourcePluginSession !== retrySession && !studio.sourcePluginLibraryPending)

            // The panel uses this same state for both read and mount tasks. No
            // actor suspension occurs until after cancelling the successor, so
            // its task can deterministically observe whether its handle survived.
            let panel = PluginLibraryOperation()
            var oldTaskCancelled = false, newTaskCancelled = false
            let oldOperation = panel.begin()
            let oldTask = Task { @MainActor in oldTaskCancelled = Task.isCancelled }
            panel.attach(oldTask, to: oldOperation)
            let newOperation = panel.begin(loading: true)
            panel.message = "Current library read"
            let newTask = Task { @MainActor in newTaskCancelled = Task.isCancelled }
            panel.attach(newTask, to: newOperation)
            panel.finish(oldOperation, message: "Stale mount failure")
            try check("panelStaleCompletion", panel.isCurrent(newOperation) && panel.loading
                && panel.message == "Current library read")
            panel.cancel(message: "Cancelled current read")
            await oldTask.value; await newTask.value
            try check("panelSuccessorTaskRetained", oldTaskCancelled && newTaskCancelled
                && !panel.isCurrent(newOperation) && !panel.loading && panel.message == "Cancelled current read")

            // A UI Task queued before removal must reject entry before scheduling
            // preparation, changing status, or touching the shared Maker frame.
            let beforeQueue = studio.doc, queuedSession = studio.sourcePluginSession
            let dialogGeneration = studio.sourcePluginMountGeneration
            let queued = Task { try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(10)) }
            app.mode = .maker
            let makerFrame = studio.host.renderer.currentFrame()
            var rejected = false
            do { try await queued.value } catch is CancellationError { rejected = true }
            try check("inactiveQueuedEntry", rejected && studio.doc == beforeQueue && queuedSession === studio.sourcePluginSession
                && sameFrame(makerFrame, studio.host.renderer.currentFrame()) && !studio.sourcePluginLibraryPending)
            try rejectProfile("inactiveLegacyCommands", generation: studio.sourcePluginMountGeneration, toggle: true)
            studio.unloadSourcePluginLibrary()
            try check("inactiveUnload", studio.doc == beforeQueue && queuedSession === studio.sourcePluginSession
                && sameFrame(makerFrame, studio.host.renderer.currentFrame()))
            app.mode = .studio
            try rejectProfile("staleLegacyDialogAfterModeReturn", generation: dialogGeneration, toggle: false)

            let beforeFailure = studio.doc, session = studio.sourcePluginSession, adapter = studio.sourceFocus.adapter
            let resources = resourceCounts(), gain = studio.sourceAudioBus.masterVolume
            var failure = ""
            do { try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(999)) }
            catch { failure = String(describing: error) }
            try check("invalidBindingRollback", failure.contains("does not bind uniquely") && beforeFailure == studio.doc
                && session === studio.sourcePluginSession && adapter === studio.sourceFocus.adapter
                && gain == studio.sourceAudioBus.masterVolume && resources == resourceCounts(), failure)

            // The invalid history entry is constructed from a valid snapshot;
            // no package bytes or library publications are changed by this check.
            var unavailable = beforeFailure
            let pinned = request.selection
            unavailable.sourcePluginLibrary = .init(libraryFile: pinned.libraryFile + ".absent", generation: pinned.generation,
                generationSHA256: pinned.generationSHA256, process: pinned.process, revisions: pinned.revisions)
            studio.doc = unavailable; studio.pushUndo(force: true); studio.doc = beforeFailure
            studio.undo()
            try check("unavailableUndoRollback", studio.doc == beforeFailure && session === studio.sourcePluginSession
                && adapter === studio.sourceFocus.adapter && studio.status.contains("Plugin restore:"), studio.status)

            // Restore runs field initializers before saved fields are installed.
            // The candidate shares object UUIDs with the current scene, but its
            // attached transform must never consult current live preview state.
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-plugin-restore-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let legacy = try legacyAttachmentSnapshot(document: beforeFailure, directory: scratch)
            studio.doc = legacy; studio.pushUndo(force: true); studio.doc = beforeFailure
            let previews = Set(studio.renderedSourceCharacterPreviews.map { ObjectIdentifier($0) })
            let legacyFrame = studio.host.renderer.currentFrame()
            studio.undo()
            // The rejected legacy entry must remain above the unavailable one;
            // rejection must not create a redo entry for the unchanged scene.
            studio.undo()
            studio.redo()
            try check("legacyAttachmentUndoRollback", studio.status.contains("Source plugin attachment has no converted character parent.")
                && studio.doc == beforeFailure && session === studio.sourcePluginSession && adapter === studio.sourceFocus.adapter
                && gain == studio.sourceAudioBus.masterVolume && resources == resourceCounts()
                && previews == Set(studio.renderedSourceCharacterPreviews.map { ObjectIdentifier($0) })
                && sameFrame(legacyFrame, studio.host.renderer.currentFrame()), studio.status)

            // A successful retry after cancellation still mounts through the UI path.
            try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(11))
            try check("retry", studio.doc.sourcePluginLibraryConfiguration == configuration(11))
            var stepTime = 0.0, snapshotTime = 0.0
            for _ in 0..<120 {
                var time = ProcessInfo.processInfo.systemUptime
                try studio.stepSourcePlugins(deltaTime: 1 / 60)
                stepTime += ProcessInfo.processInfo.systemUptime - time
                time = ProcessInfo.processInfo.systemUptime
                _ = try studio.sourcePluginSession?.savedDocument()
                snapshotTime += ProcessInfo.processInfo.systemUptime - time
            }
            try check("cachedStepSnapshot", true, "120 synthetic two-folder samples; step mean \(stepTime * 1000 / 120) ms; snapshot mean \(snapshotTime * 1000 / 120) ms")

            // Both UI Run/Pause sites use this same guarded method. Neither
            // action advances the runtime or rebuilds the shared frame itself.
            studio.sourcePluginsRunning = false
            let commandDocument = studio.doc, commandSession = studio.sourcePluginSession
            let commandState = try commandSession?.savedDocument(), commandFrame = studio.host.renderer.currentFrame()
            let commandResources = resourceCounts(), commandAdapter = studio.sourceFocus.adapter
            func unchangedPlayback() throws -> Bool {
                let state = try studio.sourcePluginSession?.savedDocument()
                return studio.doc == commandDocument && studio.sourcePluginSession === commandSession
                    && state == commandState && studio.sourceFocus.adapter === commandAdapter
                    && resourceCounts() == commandResources && sameFrame(commandFrame, studio.host.renderer.currentFrame())
            }
            studio.toggleSourcePluginPlayback()
            try check("activeLegacyRun", studio.canToggleSourcePluginPlayback && studio.sourcePluginsRunning && (try unchangedPlayback()))
            studio.toggleSourcePluginPlayback()
            try check("activeLegacyPause", studio.canToggleSourcePluginPlayback && !studio.sourcePluginsRunning && (try unchangedPlayback()))
            var activeLoadError = ""
            do { try studio.loadSourcePluginProfileInteractively(profileURL: absentProfile, expectedGeneration: studio.sourcePluginMountGeneration) }
            catch is CancellationError { throw SourcePluginError.runtime("Active legacy profile load was incorrectly cancelled") }
            catch { activeLoadError = String(describing: error) }
            try check("activeLegacyLoadFailure", !activeLoadError.isEmpty && !studio.sourcePluginsRunning && (try unchangedPlayback()), activeLoadError)

            // Reuse the exact immutable converted package already mounted by
            // this checklist; no second IR program or fake session is introduced.
            guard let package = commandSession?.library.packages.first,
                  commandSession?.library.packages.count == 1,
                  package.manifest.identity.guid.utf8.elementsEqual(binding.guid.utf8) else {
                throw SourcePluginError.invalid("Legacy command check needs the controlled single-package fixture.")
            }
            try FileManager.default.createDirectory(at: commandScratch, withIntermediateDirectories: true)
            let profileURL = commandScratch.appendingPathComponent("profile.json")
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixedDeltaTime": initial.fixedDeltaTime,
                "packages": [["manifest": package.manifestURL.path,
                    "bindings": [["type": binding.type, "sourceObjectKey": 10]]]]]).write(to: profileURL)
            try studio.loadSourcePluginProfileInteractively(profileURL: profileURL, expectedGeneration: studio.sourcePluginMountGeneration)
            try check("activeLegacyProfileLoad", studio.sourcePluginSession !== commandSession && studio.sourcePluginsRunning
                && studio.doc.sourcePluginLibrary == nil && studio.doc.sourcePluginLibraryConfiguration == nil
                && studio.doc.sourcePluginState?.profileFile == profileURL.resolvingSymlinksInPath().path
                && studio.doc.sourcePluginState?.packages == commandDocument.sourcePluginState?.packages
                && studio.doc.sourceNativePlugins == commandDocument.sourceNativePlugins
                && studio.sourceFocus.adapter === commandAdapter && commandResources == resourceCounts())
            let profileIdentity = PluginMountSummary.Identity(guid: package.manifest.identity.guid,
                version: package.manifest.identity.version, manifestSHA256: commandDocument.sourcePluginState?.packages.first?.manifestSHA256)
            let nativeIdentities = (commandDocument.sourceNativePlugins ?? []).map {
                PluginMountSummary.Identity(guid: $0.guid, version: $0.version, manifestSHA256: $0.manifestSHA256, enabled: $0.enabled)
            }
            try checkMount("mixedProfileNativeSummary", [.init(origin: .profile, generation: nil, plugins: [profileIdentity]),
                .init(origin: .native, generation: nil, plugins: nativeIdentities)])

            // Startup/capture still uses the programmatic loader outside visible
            // Studio. This deliberately does not assert inactive UI submission:
            // only interactive entry owns that restriction.
            studio.sourcePluginsRunning = false
            let interactiveSession = studio.sourcePluginSession
            app.mode = .maker
            try studio.loadSourcePlugins(profileURL: profileURL)
            try check("inactiveProgrammaticProfileLoad", !studio.isActiveMode && studio.sourcePluginsRunning
                && studio.sourcePluginSession !== interactiveSession
                && studio.doc.sourcePluginState?.profileFile == profileURL.resolvingSymlinksInPath().path
                && studio.doc.sourcePluginState?.packages == commandDocument.sourcePluginState?.packages)
            app.mode = .studio
            let unloadGeneration = studio.sourcePluginMountGeneration
            studio.unloadSourcePluginLibrary()
            try rejectProfile("staleLegacyDialogAfterUnload", generation: unloadGeneration, toggle: false)
            let emptyDocument = studio.doc, emptyFrame = studio.host.renderer.currentFrame(), emptyResources = resourceCounts()
            studio.toggleSourcePluginPlayback()
            try check("noSessionLegacyPlayback", studio.sourcePluginCommandsAvailable && !studio.canToggleSourcePluginPlayback
                && !studio.sourcePluginsRunning && studio.sourcePluginSession == nil && studio.doc == emptyDocument
                && emptyResources == resourceCounts() && sameFrame(emptyFrame, studio.host.renderer.currentFrame()))
            try checkMount("unloadedMountSummary", [])

            try studio.loadSourcePluginProfileInteractively(profileURL: profileURL, expectedGeneration: studio.sourcePluginMountGeneration)
            try checkMount("profileOnlySummary", [.init(origin: .profile, generation: nil, plugins: [profileIdentity])])
            let emptyProfile = commandScratch.appendingPathComponent("empty-profile.json")
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixedDeltaTime": 0.02, "packages": []]).write(to: emptyProfile)
            let profileDocument = studio.doc, profileSession = studio.sourcePluginSession
            let profileRuntime = try profileSession?.savedDocument(), profileFrame = studio.host.renderer.currentFrame()
            let profileResources = resourceCounts(), profileStatus = studio.status
            let profileGeneration = studio.sourcePluginMountGeneration, profileRunning = studio.sourcePluginsRunning
            var emptyRejected = false
            do { try studio.loadSourcePluginProfileInteractively(profileURL: emptyProfile, expectedGeneration: profileGeneration) }
            catch SourcePluginError.invalid(let reason) { emptyRejected = reason == "Plugin bindings are empty." }
            let profileAfterRuntime = try studio.sourcePluginSession?.savedDocument()
            try check("emptyProfileRejected", emptyRejected && studio.doc == profileDocument
                && studio.sourcePluginSession === profileSession && profileAfterRuntime == profileRuntime
                && studio.sourcePluginMountGeneration == profileGeneration && studio.sourcePluginsRunning == profileRunning
                && studio.status == profileStatus && profileResources == resourceCounts()
                && sameFrame(profileFrame, studio.host.renderer.currentFrame()),
                "Plugin bindings are empty; current document, runtime, session, status, generation, frame and resources retained")
            try checkMount("rejectedProfileRetainsSummary", [.init(origin: .profile, generation: nil, plugins: [profileIdentity])])
            let beforeUnload = studio.doc.objects
            studio.unloadSourcePluginsInteractively()
            try check("interactiveUnloadTearsDown", studio.sourcePluginMountSummary == nil && studio.sourcePluginSession == nil
                && studio.doc.sourcePluginState == nil && studio.doc.sourceNativePlugins == nil
                && studio.sourceFocus.adapter == nil && studio.sourceFocusObservers.isEmpty && studio.sourceLaunchObserver == nil
                && !studio.sourceAccessoryNamesEnabled && !studio.sourcePluginsRunning && studio.doc.objects == beforeUnload)

            // Pure presentation inputs can exercise byte-distinct identities
            // without fabricating a registered executable native adapter.
            let composed = "\u{00e9}", decomposed = "e\u{0301}"
            let a = PluginMountSummary.Identity(guid: composed, version: "1", manifestSHA256: String(repeating: "a", count: 64))
            let b = PluginMountSummary.Identity(guid: decomposed, version: "1", manifestSHA256: String(repeating: "b", count: 64))
            let syntheticRef = try JSONDecoder().decode(SourceNativePluginReference.self, from: JSONSerialization.data(withJSONObject:
                ["guid": composed, "version": "1", "manifestSHA256": String(repeating: "c", count: 64),
                 "manifestFile": "not-read.json", "adapterID": "presentation-only", "enabled": false]))
            let ordinal = PluginMountSummary(library: nil, profile: [a, b], native: [syntheticRef])!
            let emptyPresentation = PluginMountSummary(library: nil, profile: [], native: [])
            try check("summaryPreservesOrdinalOrigins", ordinal.sections.map(\.origin) == [.profile, .native]
                && ordinal.sections.allSatisfy { $0.generation == nil }
                && ordinal.sections[0].plugins.map { Data($0.guid.utf8) } == [Data(composed.utf8), Data(decomposed.utf8)]
                && ordinal.sections[1].plugins[0].guid.utf8.elementsEqual(composed.utf8)
                && ordinal.sections[1].plugins[0].enabled == false && ordinal.sections[1].plugins[0].label.hasSuffix("(disabled)")
                && emptyPresentation?.sections.count == 1 && emptyPresentation?.sections[0].plugins.isEmpty == true
                && PluginMountSummary(library: nil, profile: nil, native: []) == nil)
        } catch {
            rows.append(.init(op: "failure", ok: false, detail: String(describing: error)))
        }
        studio.cancelSourcePluginLibraryMount()
        studio.sourcePluginPreparationHook = nil
        await studio.sourcePluginLibraryPreparationQueue.drain()
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }

    /// A public synthetic profile whose initializer reads an attached world
    /// position. Its valid saved state is produced with an isolated identity
    /// resolver, then restored through Studio's real history path.
    private func legacyAttachmentSnapshot(document: StudioDocument, directory: URL) throws -> StudioDocument {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = String(repeating: "a", count: 64), guid = "Ikkoku.Validation.AttachmentRestore"
        let transform: [String: Any] = ["kind": "api", "type": "Transform", "name": "transform", "children": []]
        let program: [String: Any] = ["schemaVersion": 1, "status": "ready", "mode": "component", "type": "AttachmentRestore",
            "source": ["sha256": hash], "identity": ["sourceSHA256": hash, "type": "AttachmentRestore",
                "symbols": ["M:AttachmentRestore.Awake"], "pluginGUID": guid],
            "semanticSurfaceSHA256": hash, "bridgeSHA256": hash, "emitterSHA256": hash,
            "fields": [["name": "position", "type": "Vector3", "serialized": true,
                "initializer": ["kind": "api", "type": "Vector3", "name": "position", "children": [transform]]]],
            "methods": [["name": "Awake", "symbol": "M:AttachmentRestore.Awake", "static": false,
                "returnType": "Void", "parameters": [], "body": ["kind": "block", "children": []], "lifecycle": "Awake"]]]
        let bytes = try JSONSerialization.data(withJSONObject: program)
        try bytes.write(to: directory.appendingPathComponent("program.json"))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "ikkoku-translated-plugin",
            "identity": ["guid": guid, "version": "1.0", "name": "Attachment restore fixture"],
            "processes": ["CharaStudio"], "dependencies": [], "incompatibilities": [],
            "components": [["type": "AttachmentRestore", "program": ["file": "program.json", "sha256": digest]]]]
        let manifestURL = directory.appendingPathComponent("manifest.json"), profile = directory.appendingPathComponent("profile.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixedDeltaTime": 0.02,
            "packages": [["manifest": manifestURL.path, "bindings": [["type": "AttachmentRestore", "sourceObjectKey": 10]]]]]).write(to: profile)
        var candidate = document
        candidate.sourcePluginLibrary = nil; candidate.sourcePluginLibraryConfiguration = nil; candidate.sourcePluginState = nil
        candidate.objects[0].parent = candidate.objects[1].id; candidate.objects[0].sourceAttachmentPoint = 17
        let session = try SourceStudioPluginSession(profileURL: profile, document: candidate,
            attachment: { _, _ in (matrix_identity_float4x4, simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))) })
        return try session.savedDocument()
    }
}

extension PluginLibraryScenario {
    struct InitialLibraryAttachments: Decodable {
        let phase: NativeProfileRestore.Phase
        let directory: String, outputDirectory: String
        let requests: [String: String], profiles: [String: String]
    }

    @MainActor private func verifyInitialLibraryAttachments(_ configuration: InitialLibraryAttachments,
                                                            app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        let output = URL(fileURLWithPath: configuration.outputDirectory)
        let directory = URL(fileURLWithPath: configuration.directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let gate = "Source-character attachment reads during plugin installation are unsupported; no live preview was changed."
        let arithmetic = "Unsupported arithmetic operator or Int32 arithmetic."
        var rows: [StudioScenario.Report.StepResult] = []
        func check(_ name: String, _ condition: Bool, _ detail: String = "") throws {
            rows.append(.init(op: name, ok: condition, detail: detail))
            if !condition { throw SourcePluginError.runtime("Initial attachment acceptance failed: " + name) }
        }
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: output.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func snapshot() throws -> NativeGraphObservation {
            .init(graph: try directGraphSnapshot(studio: studio),
                previewOwners: studio.renderedSourceCharacterPreviews.map { String(describing: ObjectIdentifier($0)) }.sorted())
        }
        func generation(_ value: NativeGraphObservation, _ expected: UInt64) -> NativeGraphObservation {
            let g = value.graph, s = g.state
            let state = InitializerObservation(document: s.document, world: s.world, runtimeDocument: s.runtimeDocument,
                pending: s.pending, callbacks: s.callbacks, resources: s.resources, undo: s.undo, redo: s.redo,
                status: s.status, sceneURL: s.sceneURL, generation: expected, animationTime: s.animationTime,
                blocked: s.blocked, diagnostics: s.diagnostics)
            return .init(graph: .init(state: state, focus: g.focus, hideAdapterVisible: g.hideAdapterVisible,
                interfaceVisible: g.interfaceVisible, accessoryNames: g.accessoryNames, showGizmos: g.showGizmos,
                effectiveShowGizmos: g.effectiveShowGizmos, showTimeline: g.showTimeline, pending: g.pending, request: g.request),
                previewOwners: value.previewOwners)
        }
        func capture(_ name: String) throws -> (state: NativeGraphObservation, frame: Data) {
            let state = try snapshot(), frame = try directGraphFrameBytes(studio.host.renderer.currentFrame())
            try persist(state, name)
            try frame.write(to: output.appendingPathComponent(name + "-frame.json"), options: .withoutOverwriting)
            return (state, frame)
        }
        func warmObservation(_ preview: SourceStudioCharacterPreview?) throws -> InstallWarmObservation? {
            guard let preview else { return nil }
            let body = preview.sourceBodyValues, face = preview.sourceFaceValues, diagnostics = preview.diagnostics
            let pose = try preview.editedPose(faceValues: face, bodyValues: body, animationElapsed: 0.7)
            let matrices = pose.localMatrices.map { m in (0..<4).flatMap { c in (0..<4).map { r in m[c][r].bitPattern } } }
            return .init(body: body, face: face, diagnostics: diagnostics, matrices: matrices)
        }
        func reject(_ name: String, expected: String, mount: Bool, operation: () async throws -> Void) async throws {
            let before = try capture(name + "-before")
            var reason: String?
            do { try await operation() }
            catch SourcePluginError.invalid(let error) { reason = error }
            catch SourcePluginError.runtime(let error) { reason = error }
            catch { reason = "UNEXPECTED: \(error)" }
            let after = try capture(name + "-after")
            try check(name + "Error", reason == expected, reason ?? "No rejection")
            try check(name + "State", after.state == (mount ? generation(before.state, before.state.graph.state.generation &+ 1) : before.state))
            try check(name + "Frame", after.frame == before.frame)
        }
        func scene(_ name: String) -> URL { directory.appendingPathComponent(name + ".png") }
        func decoded(_ name: String) throws -> StudioDocument {
            try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: Data(contentsOf: scene(name)))
        }
        do {
            guard !FileManager.default.fileExists(atPath: output.path) else { throw SourcePluginError.invalid("Initial attachment acceptance requires fresh output.") }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            studio.stopBenchmarkTimer(); studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false; studio.showGizmos = false; studio.showTimeline = false
            let names = ["reader", "poison", "plain"]
            guard Set(configuration.requests.keys) == Set(names), Set(configuration.profiles.keys) == Set(names),
                  let template = studio.doc.objects.first(where: { $0.sourceCharacter != nil }),
                  template.sourceCharacter?.attachmentCatalogFile != nil else { throw SourcePluginError.invalid("Missing initial attachment acceptance inputs.") }
            try check("sourceFixture", !studio.host.renderer.currentFrame().items.isEmpty
                && studio.host.renderer.currentFrame().items.allSatisfy { $0.sourceShader == nil })
            var requests: [String: StudioPluginLibraryRequest] = [:], profiles: [String: URL] = [:]
            for name in names {
                let request = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: configuration.requests[name]!))
                let resolution = try request.selection.resolve(), profile = URL(fileURLWithPath: configuration.profiles[name]!)
                let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: profile)) as? [String: Any]
                guard let packages = raw?["packages"] as? [[String: Any]], packages.count == 1,
                      let path = packages[0]["manifest"] as? String, path.hasPrefix("/"),
                      resolution.translated.count == 1, resolution.nativeAdapters.isEmpty else { throw SourcePluginError.invalid("Expected paired immutable IR package.") }
                let source = try SourcePluginPackage.load(url: URL(fileURLWithPath: path)), selected = resolution.translated[0]
                guard source.manifest.components.count == 1, selected.manifest.components.count == 1 else { throw SourcePluginError.invalid("Expected paired IR program.") }
                let sourceProgram = source.manifestURL.deletingLastPathComponent().appendingPathComponent(source.manifest.components[0].program.file)
                let selectedProgram = selected.manifestURL.deletingLastPathComponent().appendingPathComponent(selected.manifest.components[0].program.file)
                let bytesEqual = try Data(contentsOf: sourceProgram) == Data(contentsOf: selectedProgram)
                try check(name + "ExactPackage", source.manifestData == selected.manifestData && bytesEqual
                    && request.configuration.bindings.count == 1 && request.configuration.bindings[0].sourceObjectKey == 12)
                requests[name] = request; profiles[name] = profile
            }
            let reader = requests["reader"]!, poison = requests["poison"]!, plain = requests["plain"]!
            var parent = template; parent.id = UUID(); parent.parent = nil; parent.transform = StudioTransform()
            var child = StudioObject(name: "Initial library attachment", kind: .folder)
            child.sourceObjectKey = 12; child.parent = parent.id; child.sourceAttachmentPoint = 17
            var target = StudioObject(name: "Retained plugin target", kind: .folder); target.sourceObjectKey = 11
            var base = StudioDocument(); base.sourceSceneFile = studio.doc.sourceSceneFile; base.sourceSceneSHA256 = studio.doc.sourceSceneSHA256
            base.objects = [parent, child, target]
            let retained = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: requestFile))
            guard let binding = retained.configuration.bindings.first, retained.configuration.bindings.count == 1 else { throw SourcePluginError.invalid("Missing retained mixed binding.") }
            func seed(_ warm: Bool) async throws {
                studio.newScene(); var document = base; document.objects[0].visible = warm; studio.doc = document
                try await studio.mountSourcePluginLibrary(selection: retained.selection, configuration: .init(fixedDeltaTime: retained.configuration.fixedDeltaTime,
                    bindings: [.init(guid: binding.guid, type: binding.type, sourceObjectKey: 11)]))
                studio.sourcePluginsRunning = false; studio.receiveSourceApplicationFocus(true)
                try studio.stepSourcePlugins(deltaTime: 0.04); try studio.setSourceAnimationTime(0.7); studio.refresh()
                if warm, let preview = studio.sourceShapePreview(for: parent.id) {
                    var body = preview.savedBodyValues, face = preview.savedFaceValues
                    body[0] = body[0] < 0.5 ? 0.8 : 0.2; face[33] = face[33] < 0.5 ? 0.8 : 0.2
                    _ = try preview.editedPose(faceValues: face, bodyValues: body, animationElapsed: 0.7)
                }
            }
            switch configuration.phase {
            case .save:
                guard !FileManager.default.fileExists(atPath: directory.path) else { throw SourcePluginError.invalid("Initial attachment save needs fresh scene directory.") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try String(ProcessInfo.processInfo.processIdentifier).write(to: directory.appendingPathComponent("save-pid.txt"), atomically: false, encoding: .utf8)
                for isWarm in [false, true] {
                    let mode = isWarm ? "warm" : "cold"
                    try await seed(isWarm)
                    let initial = studio.sourceShapePreview(for: parent.id)
                    try check(mode + "Retained", studio.sourcePluginSession != nil && studio.sourceFocus.adapter != nil
                        && studio.sourceAccessoryNamesEnabled && (initial != nil) == isWarm && !studio.sourcePluginsRunning)
                    let warmBefore = try warmObservation(initial); try persist(warmBefore, mode + "-warm-before")
                    for suffix in ["Poison", "PoisonRepeat"] {
                        try await reject(mode + suffix, expected: arithmetic, mount: true) {
                            try await studio.mountSourcePluginLibrary(selection: poison.selection, configuration: poison.configuration)
                        }
                    }
                    let warmAfter = try warmObservation(studio.sourceShapePreview(for: parent.id)); try persist(warmAfter, mode + "-warm-after")
                    try check(mode + "WarmRollback", warmBefore == warmAfter && studio.sourceShapePreview(for: parent.id) === initial)
                    // The generic preparation entry still needs an explicit
                    // initial context; callers do not gain reads by accident.
                    try await reject(mode + "Detached", expected: gate, mount: false) {
                        let prepared = try studio.prepareSourcePluginLibrary(selection: reader.selection, resolution: reader.selection.resolve(),
                            configuration: reader.configuration, document: studio.doc)
                        prepared.abort()
                    }
                    try studio.loadSourcePluginProfileInteractively(profileURL: profiles["reader"]!, expectedGeneration: studio.sourcePluginMountGeneration)
                    studio.sourcePluginsRunning = false
                    let legacy = try studio.sourcePluginSession!.savedDocument()
                    try persist(legacy, mode + "-legacy-reader")
                    let legacyFields = legacy.sourcePluginState!.bindings[0].fields
                    try check(mode + "LegacyControl", legacyFields["position"] == legacyFields["positionAgain"] && legacyFields["position"] != .vector([0, 0, 0]))
                    try await seed(isWarm)
                    let current = studio.sourceShapePreview(for: parent.id), previousSession = studio.sourcePluginSession
                    let mounted = Task { try await studio.mountSourcePluginLibrary(selection: reader.selection, configuration: reader.configuration) }
                    try await mounted.value; studio.sourcePluginsRunning = false
                    let preview = studio.sourceShapePreview(for: parent.id), saved = try studio.sourcePluginSession!.savedDocument()
                    try persist(saved, mode + "-mounted")
                    try check(mode + "ReaderMounted", studio.sourcePluginSession !== previousSession && studio.doc.sourcePluginLibrary == reader.selection
                        && preview != nil && (!isWarm || preview === current) && studio.sourceFocus.adapter == nil)
                    try check(mode + "ReaderFields", saved.sourcePluginState?.bindings[0].fields == legacyFields)
                    let committed = try capture(mode + "-committed")
                    mounted.cancel(); try await mounted.value
                    let afterCancel = try capture(mode + "-postcommit-cancel")
                    try check(mode + "PostCommitCancellation", afterCancel.state == committed.state && afterCancel.frame == committed.frame)
                    let counts = try snapshot().graph.state.resources
                    try studio.stepSourcePlugins(deltaTime: 0.04)
                    try check(mode + "FirstStepReuse", studio.sourceShapePreview(for: parent.id) === preview && snapshot().graph.state.resources == counts)
                    try studio.saveScene(to: scene(mode))
                    let actual = try decoded(mode), runtime = try studio.sourcePluginSession!.savedDocument()
                    try persist(actual, mode + "-saved")
                    try check(mode + "ActualNativeSave", actual.sourcePluginLibrary == reader.selection && actual.sourcePluginState == runtime.sourcePluginState
                        && actual.sourcePluginState?.clock.elapsedTime == Double(Float(0.04)))
                    let noOp = studio.sourcePluginSession, noOpGeneration = studio.sourcePluginMountGeneration, noOpCounts = try snapshot().graph.state.resources
                    try await studio.mountSourcePluginLibrary(selection: reader.selection, configuration: reader.configuration)
                    try check(mode + "ReaderNoop", studio.sourcePluginSession === noOp && studio.sourcePluginMountGeneration == noOpGeneration
                        && studio.sourceShapePreview(for: parent.id) === preview && snapshot().graph.state.resources == noOpCounts)
                    try await seed(isWarm)
                    let plainPreview = studio.sourceShapePreview(for: parent.id), plainCounts = try snapshot().graph.state.resources
                    try await studio.mountSourcePluginLibrary(selection: plain.selection, configuration: plain.configuration)
                    studio.sourcePluginsRunning = false
                    try check(mode + "PlainMounted", studio.doc.sourcePluginLibrary == plain.selection
                        && studio.doc.sourcePluginState?.bindings[0].fields["position"] == .vector([0, 0, 0])
                        && studio.doc.sourcePluginState?.bindings[0].fields["positionAgain"] == .vector([0, 0, 0]))
                    try check(mode + "PlainNoPreviewWork", studio.sourceShapePreview(for: parent.id) === plainPreview && snapshot().graph.state.resources == plainCounts)
                    try await seed(isWarm)
                    let entryBefore = try capture(mode + "-entry-before")
                    let cancelledEntry = Task { try await studio.mountSourcePluginLibrary(selection: reader.selection, configuration: reader.configuration) }
                    cancelledEntry.cancel(); var entryCancelled = false
                    do { try await cancelledEntry.value } catch is CancellationError { entryCancelled = true }
                    let entryAfter = try capture(mode + "-entry-after")
                    try check(mode + "EntryCancelled", entryCancelled && entryAfter.state == entryBefore.state && entryAfter.frame == entryBefore.frame)
                    // This real worker hook precedes resolution. Returned-result
                    // validation through commit has no suspension or test seam;
                    // post-commit cancellation is checked separately above.
                    for boundary in ["Caller", "Mode", "Document"] {
                        try await seed(isWarm)
                        let prefix = mode + boundary
                        let before = try capture(prefix + "-before")
                        let barrier = Barrier(); studio.sourcePluginPreparationHook = { barrier.hold() }
                        let pending = Task { try await studio.mountSourcePluginLibrary(selection: reader.selection, configuration: reader.configuration) }
                        defer { pending.cancel(); barrier.finish(); studio.sourcePluginPreparationHook = nil }
                        await barrier.wait()
                        let held = try capture(prefix + "-held")
                        try check(prefix + "Held", held.state.graph.pending && held.state.graph.request != nil && studio.sourcePluginLibraryPreparationQueue.isRunning)
                        if boundary == "Mode" { app.mode = .maker }
                        if boundary == "Document" { studio.newScene() }
                        let transition = try capture(prefix + "-transition")
                        pending.cancel(); var cancelled = false
                        do { try await pending.value } catch is CancellationError { cancelled = true }
                        let after = try capture(prefix + "-cancelled")
                        try check(prefix + "CancelledBeforeRelease", cancelled && studio.sourcePluginLibraryPreparationQueue.isRunning)
                        if boundary == "Caller" {
                            try check(prefix + "Retained", after.state == generation(before.state, before.state.graph.state.generation &+ 1)
                                && after.frame == before.frame)
                        } else { try check(prefix + "Retained", after.state == transition.state && after.frame == transition.frame) }
                        barrier.finish(); studio.sourcePluginPreparationHook = nil
                        await studio.sourcePluginLibraryPreparationQueue.drain()
                        let drained = try capture(prefix + "-drained")
                        try check(prefix + "Drained", drained.state == after.state && drained.frame == after.frame)
                        app.mode = .studio
                        try await seed(isWarm)
                        try await studio.mountSourcePluginLibrary(selection: reader.selection, configuration: reader.configuration)
                        studio.sourcePluginsRunning = false
                        try check(prefix + "RetryMounted", studio.doc.sourcePluginLibrary == reader.selection
                            && studio.sourceShapePreview(for: parent.id) != nil && !studio.sourcePluginLibraryPending)
                    }
                }
            case .reopen:
                for mode in ["cold", "warm"] {
                    let saved = try decoded(mode)
                    guard let object = saved.objects.first(where: { $0.sourceCharacter != nil }) else { throw SourcePluginError.invalid("Saved initial reader lacks source parent.") }
                    try check(mode + "SavedReader", saved.sourcePluginLibrary == reader.selection && saved.sourcePluginState?.profileFile == nil
                        && saved.sourcePluginState?.clock.elapsedTime == Double(Float(0.04)))
                    try await seed(false)
                    try await reject(mode + "DetachedRestore", expected: gate, mount: false) {
                        let prepared = try studio.prepareSourcePlugins(document: saved)
                        prepared.abort()
                    }
                    try studio.loadScene(from: scene(mode))
                    let restored = try studio.sourcePluginSession!.savedDocument(), preview = studio.sourceShapePreview(for: object.id)
                    try persist(restored, mode + "-reopened")
                    try check(mode + "FreshReopen", restored.sourcePluginState == saved.sourcePluginState && restored.sourcePluginLibrary == reader.selection
                        && preview != nil && !studio.sourcePluginsRunning)
                    try check(mode + "SavedVisibility", studio.doc.object(object.id)?.visible == object.visible && object.visible == (mode == "warm"))
                    let counts = try snapshot().graph.state.resources
                    try studio.stepSourcePlugins(deltaTime: 0.02)
                    try check(mode + "RestoredFirstStepReuse", studio.sourceShapePreview(for: object.id) === preview && snapshot().graph.state.resources == counts)
                    let continued = try studio.sourcePluginSession!.savedDocument()
                    try persist(continued, mode + "-continued")
                    try check(mode + "ContinuedFieldsClock", continued.sourcePluginState?.bindings[0].fields == saved.sourcePluginState?.bindings[0].fields
                        && continued.sourcePluginState?.clock.elapsedTime == Double(Float(0.04)) + Double(Float(0.02)))
                    _ = try capture(mode + "-reopened-final")
                }
            }
        } catch { rows.append(.init(op: "initialLibraryAttachmentsFailure", ok: false, detail: String(describing: error))) }
        studio.sourcePluginPreparationHook = nil; studio.cancelSourcePluginLibraryMount()
        await studio.sourcePluginLibraryPreparationQueue.drain()
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}

extension PluginLibraryScenario {
    struct LibraryAttachmentInstall: Decodable {
        let outputDirectory: String
        let requests: [String: String]
        let profiles: [String: String]
    }
    private struct InstallWarmObservation: Codable, Equatable {
        let body: [Float]?, face: [Float]?, diagnostics: [String], matrices: [[UInt32]]
    }

    @MainActor private func reproduceLibraryAttachmentInstall(_ configuration: LibraryAttachmentInstall,
                                                               app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        let output = URL(fileURLWithPath: configuration.outputDirectory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let gate = "Source-character attachment reads during plugin installation are unsupported; no live preview was changed."
        let arithmetic = "Unsupported arithmetic operator or Int32 arithmetic."
        var rows: [StudioScenario.Report.StepResult] = []
        func check(_ name: String, _ value: Bool, _ detail: String = "") throws {
            rows.append(.init(op: name, ok: value, detail: detail))
            if !value { throw SourcePluginError.runtime("Initial library attachment diagnostic failed: " + name) }
        }
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: output.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func snapshot() throws -> NativeGraphObservation {
            .init(graph: try directGraphSnapshot(studio: studio),
                previewOwners: studio.renderedSourceCharacterPreviews.map { String(describing: ObjectIdentifier($0)) }.sorted())
        }
        // A real async attempt advances its generation once even on rejection.
        // Project only that verified lifecycle delta; retain every other field.
        func generation(_ value: NativeGraphObservation, _ expected: UInt64) -> NativeGraphObservation {
            let g = value.graph, s = g.state
            let state = InitializerObservation(document: s.document, world: s.world, runtimeDocument: s.runtimeDocument,
                pending: s.pending, callbacks: s.callbacks, resources: s.resources, undo: s.undo, redo: s.redo,
                status: s.status, sceneURL: s.sceneURL, generation: expected, animationTime: s.animationTime,
                blocked: s.blocked, diagnostics: s.diagnostics)
            return .init(graph: .init(state: state, focus: g.focus, hideAdapterVisible: g.hideAdapterVisible,
                interfaceVisible: g.interfaceVisible, accessoryNames: g.accessoryNames, showGizmos: g.showGizmos,
                effectiveShowGizmos: g.effectiveShowGizmos, showTimeline: g.showTimeline, pending: g.pending, request: g.request),
                previewOwners: value.previewOwners)
        }
        func frame(_ name: String) throws -> Data {
            let data = try directGraphFrameBytes(studio.host.renderer.currentFrame())
            try data.write(to: output.appendingPathComponent(name + "-frame.json"), options: .withoutOverwriting)
            return data
        }
        func warmObservation(_ preview: SourceStudioCharacterPreview?) throws -> InstallWarmObservation? {
            guard let preview else { return nil }
            let body = preview.sourceBodyValues, face = preview.sourceFaceValues, diagnostics = preview.diagnostics
            let pose = try preview.editedPose(faceValues: face, bodyValues: body, animationElapsed: 0.7)
            let matrices = pose.localMatrices.map { m in (0..<4).flatMap { c in (0..<4).map { r in m[c][r].bitPattern } } }
            return .init(body: body, face: face, diagnostics: diagnostics, matrices: matrices)
        }
        func reject(_ name: String, expected: String, asyncAttempt: Bool,
                    operation: () async throws -> Void) async throws {
            let before = try snapshot(), beforeFrame = try frame(name + "-before")
            try persist(before, name + "-before")
            var error: String?
            do { try await operation() }
            catch SourcePluginError.invalid(let reason) { error = reason }
            catch SourcePluginError.runtime(let reason) { error = reason }
            catch let other { error = "UNEXPECTED: \(other)" }
            let after = try snapshot(), afterFrame = try frame(name + "-after")
            try persist(after, name + "-after")
            try check(name + "Error", error == expected, error ?? "No rejection")
            let wanted = asyncAttempt ? generation(before, before.graph.state.generation &+ 1) : before
            try check(name + "State", after == wanted)
            try check(name + "Frame", beforeFrame == afterFrame)
        }
        do {
            guard !FileManager.default.fileExists(atPath: output.path) else { throw SourcePluginError.invalid("Initial-install diagnostic requires fresh output.") }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            studio.stopBenchmarkTimer(); studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false; studio.showGizmos = false; studio.showTimeline = false
            let names = ["reader", "poison", "plain"]
            guard Set(configuration.requests.keys) == Set(names), Set(configuration.profiles.keys) == Set(names),
                  let template = studio.doc.objects.first(where: { $0.sourceCharacter != nil }),
                  template.sourceCharacter?.attachmentCatalogFile != nil else { throw SourcePluginError.invalid("Missing initial-install inputs.") }
            let sourceFile = studio.doc.sourceSceneFile, sourceSHA = studio.doc.sourceSceneSHA256
            try check("sourceFixture", !studio.host.renderer.currentFrame().items.isEmpty
                && studio.host.renderer.currentFrame().items.allSatisfy { $0.sourceShader == nil })
            var requests: [String: StudioPluginLibraryRequest] = [:]
            var resolutions: [String: SourcePluginLibraryResolution] = [:]
            var profiles: [String: URL] = [:]
            var parent = template; parent.id = UUID(); parent.parent = nil; parent.visible = false; parent.transform = StudioTransform()
            var child = StudioObject(name: "Initial attachment diagnostic", kind: .folder)
            child.sourceObjectKey = 12; child.parent = parent.id; child.sourceAttachmentPoint = 17
            var target = StudioObject(name: "Retained plugin target", kind: .folder); target.sourceObjectKey = 11
            var oracleDocument = StudioDocument(); oracleDocument.sourceSceneFile = sourceFile; oracleDocument.sourceSceneSHA256 = sourceSHA
            oracleDocument.objects = [parent, child, target]
            let marker = SIMD3<Float>(1.25, 2.5, 3.75)
            for name in names {
                let request = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: configuration.requests[name]!))
                let resolution = try request.selection.resolve(), profile = URL(fileURLWithPath: configuration.profiles[name]!)
                let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: profile)) as? [String: Any]
                guard let packages = raw?["packages"] as? [[String: Any]], packages.count == 1,
                      let manifestPath = packages[0]["manifest"] as? String, manifestPath.hasPrefix("/"),
                      let bindings = packages[0]["bindings"] as? [[String: Any]], bindings.count == 1,
                      resolution.translated.count == 1, resolution.nativeAdapters.isEmpty else { throw SourcePluginError.invalid("Expected one paired IR package.") }
                let package = try SourcePluginPackage.load(url: URL(fileURLWithPath: manifestPath)), selected = resolution.translated[0]
                guard package.manifest.components.count == 1, selected.manifest.components.count == 1 else { throw SourcePluginError.invalid("Expected one paired program.") }
                let sourceProgram = package.manifestURL.deletingLastPathComponent().appendingPathComponent(package.manifest.components[0].program.file)
                let selectedProgram = selected.manifestURL.deletingLastPathComponent().appendingPathComponent(selected.manifest.components[0].program.file)
                let programBytesMatch = try Data(contentsOf: sourceProgram) == Data(contentsOf: selectedProgram)
                let bindingMatches = request.configuration.bindings.count == 1
                    && request.configuration.bindings[0].sourceObjectKey == 12
                    && request.configuration.bindings[0].guid.utf8.elementsEqual(package.manifest.identity.guid.utf8)
                    && request.configuration.bindings[0].type == (bindings[0]["type"] as? String)
                    && (bindings[0]["sourceObjectKey"] as? NSNumber)?.int32Value == 12
                let clockMatches = (raw?["fixedDeltaTime"] as? NSNumber)?.floatValue == request.configuration.fixedDeltaTime
                try check(name + "ExactIdentity", package.manifestData == selected.manifestData && programBytesMatch && bindingMatches && clockMatches)
                requests[name] = request; resolutions[name] = resolution; profiles[name] = profile
                for origin in ["profile", "library", "gate"] {
                    var calls: [[String: String]] = [], error: String?, session: SourceStudioPluginSession?
                    let resolver: SourceStudioPluginWorld.AttachmentResolver = { child, parent in
                        calls.append(["child": child.id.uuidString, "parent": parent.id.uuidString])
                        if origin == "gate" { throw SourcePluginError.invalid(gate) }
                        var matrix = matrix_identity_float4x4; matrix.columns.3 = SIMD4<Float>(marker, 1)
                        return (matrix, simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
                    }
                    do {
                        if origin == "profile" { session = try SourceStudioPluginSession(profileURL: profile, document: oracleDocument, attachment: resolver) }
                        else { session = try SourceStudioPluginSession(selection: request.selection, resolution: resolution,
                            configuration: request.configuration, document: oracleDocument, attachment: resolver) }
                    } catch SourcePluginError.invalid(let reason) { error = reason }
                    catch SourcePluginError.runtime(let reason) { error = reason }
                    let prefix = name + origin.capitalized + "Oracle"
                    try persist(calls, prefix + "-calls")
                    let count = name == "plain" ? 0 : origin == "gate" ? 1 : 2
                    try check(prefix + "ReadOrder", calls == Array(repeating: ["child": child.id.uuidString, "parent": parent.id.uuidString], count: count))
                    let wantedError: String? = name == "plain" ? nil : origin == "gate" ? gate : name == "poison" ? arithmetic : nil
                    let fields = try session?.savedDocument().sourcePluginState?.bindings.first?.fields
                    // The resolver returns native-basis matrices; the public
                    // source position API reflects Z back into Unity's basis.
                    let value: SourceIRStoredValue = .vector(name == "plain" ? [0, 0, 0] : [Float(1.25).bitPattern, Float(2.5).bitPattern, Float(-3.75).bitPattern])
                    if let session { try persist(try session.savedDocument(), prefix + "-document") }
                    try check(prefix + "Outcome", error == wantedError && (wantedError != nil || (fields?["position"] == value && fields?["positionAgain"] == value)), error ?? "Success")
                }
            }
            try persist(requests.mapValues(\.selection), "exact-selections")
            let retained = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: requestFile))
            guard let binding = retained.configuration.bindings.first, retained.configuration.bindings.count == 1 else { throw SourcePluginError.invalid("Missing retained mixed binding.") }
            func seed(_ warm: Bool) async throws {
                studio.newScene()
                var document = oracleDocument; document.objects[0].visible = warm
                studio.doc = document
                try await studio.mountSourcePluginLibrary(selection: retained.selection, configuration: .init(fixedDeltaTime: retained.configuration.fixedDeltaTime,
                    bindings: [.init(guid: binding.guid, type: binding.type, sourceObjectKey: 11)]))
                studio.sourcePluginsRunning = false; studio.receiveSourceApplicationFocus(true)
                try studio.stepSourcePlugins(deltaTime: 0.04); try studio.setSourceAnimationTime(0.7); studio.refresh()
                if warm, let preview = studio.sourceShapePreview(for: parent.id) {
                    var body = preview.savedBodyValues, face = preview.savedFaceValues
                    body[0] = body[0] < 0.5 ? 0.8 : 0.2; face[33] = face[33] < 0.5 ? 0.8 : 0.2
                    _ = try preview.editedPose(faceValues: face, bodyValues: body, animationElapsed: 0.7)
                }
            }
            for isWarm in [false, true] {
                let mode = isWarm ? "warm" : "cold"
                try await seed(isWarm)
                let initialPreview = studio.sourceShapePreview(for: parent.id)
                try check(mode + "RetainedPrecondition", studio.sourcePluginSession != nil && studio.sourceFocus.adapter != nil
                    && studio.sourceAccessoryNamesEnabled && (initialPreview != nil) == isWarm && !studio.sourcePluginsRunning)
                for name in ["reader", "poison"] {
                    let request = requests[name]!
                    try check(mode + name + "NoopPrecondition", studio.doc.sourcePluginLibrary != request.selection)
                    try await reject(mode + name, expected: gate, asyncAttempt: true) {
                        try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: request.configuration)
                    }
                }
                let beforeWarm = try warmObservation(initialPreview)
                try persist(beforeWarm, mode + "-warm-before")
                try await reject(mode + "LegacyPoison", expected: arithmetic, asyncAttempt: false) {
                    try studio.loadSourcePluginProfileInteractively(profileURL: profiles["poison"]!, expectedGeneration: studio.sourcePluginMountGeneration)
                }
                let afterWarm = try warmObservation(studio.sourceShapePreview(for: parent.id))
                try persist(afterWarm, mode + "-warm-after")
                try check(mode + "LegacyWarmRollback", beforeWarm == afterWarm && studio.sourceShapePreview(for: parent.id) === initialPreview)
                try await reject(mode + "LegacyPoisonRepeat", expected: arithmetic, asyncAttempt: false) {
                    try studio.loadSourcePluginProfileInteractively(profileURL: profiles["poison"]!, expectedGeneration: studio.sourcePluginMountGeneration)
                }
                try studio.loadSourcePluginProfileInteractively(profileURL: profiles["reader"]!, expectedGeneration: studio.sourcePluginMountGeneration)
                studio.sourcePluginsRunning = false
                let committed = studio.sourceShapePreview(for: parent.id), document = try studio.sourcePluginSession!.savedDocument()
                try persist(document, mode + "-legacy-reader")
                try check(mode + "LegacyReaderMounted", committed != nil && (!isWarm || committed === initialPreview)
                    && studio.doc.sourcePluginLibrary == nil && studio.sourceFocus.adapter != nil)
                let fields = document.sourcePluginState!.bindings[0].fields
                try check(mode + "LegacyReaderFields", fields["position"] == fields["positionAgain"] && fields["position"] != .vector([0, 0, 0]))
                let committedCounts = try snapshot().graph.state.resources
                try studio.stepSourcePlugins(deltaTime: 0.02)
                try check(mode + "LegacyReaderFirstStepReuse", studio.sourceShapePreview(for: parent.id) === committed
                    && snapshot().graph.state.resources == committedCounts)

                try await seed(isWarm)
                let plainPreview = studio.sourceShapePreview(for: parent.id), plainCounts = try snapshot().graph.state.resources
                try studio.loadSourcePluginProfileInteractively(profileURL: profiles["plain"]!, expectedGeneration: studio.sourcePluginMountGeneration)
                studio.sourcePluginsRunning = false
                try check(mode + "PlainLegacyMounted", studio.doc.sourcePluginLibrary == nil
                    && studio.doc.sourcePluginState?.bindings.first?.fields["position"] == .vector([0, 0, 0]))
                try check(mode + "PlainLegacyPreviewResources", studio.sourceShapePreview(for: parent.id) === plainPreview
                    && snapshot().graph.state.resources == plainCounts)
                let plain = requests["plain"]!
                try await studio.mountSourcePluginLibrary(selection: plain.selection, configuration: plain.configuration)
                studio.sourcePluginsRunning = false
                try check(mode + "PlainLibraryMounted", studio.doc.sourcePluginLibrary == plain.selection
                    && studio.doc.sourcePluginState?.bindings.first?.fields["position"] == .vector([0, 0, 0]) && studio.sourceFocus.adapter == nil)
                try check(mode + "PlainLibraryPreviewResources", studio.sourceShapePreview(for: parent.id) === plainPreview
                    && snapshot().graph.state.resources == plainCounts)
                let plainSession = studio.sourcePluginSession, plainGeneration = studio.sourcePluginMountGeneration
                try await studio.mountSourcePluginLibrary(selection: plain.selection, configuration: plain.configuration)
                try check(mode + "PlainNoop", studio.sourcePluginSession === plainSession
                    && studio.sourcePluginMountGeneration == plainGeneration && studio.status == "This plugin selection is already mounted")

                try await seed(isWarm)
                let before = try snapshot(), beforeFrame = try frame(mode + "Pending-before")
                try persist(before, mode + "Pending-before")
                let barrier = Barrier(); studio.sourcePluginPreparationHook = { barrier.hold() }
                let reader = requests["reader"]!
                let pending = Task { try await studio.mountSourcePluginLibrary(selection: reader.selection, configuration: reader.configuration) }
                defer { pending.cancel(); barrier.finish(); studio.sourcePluginPreparationHook = nil }
                await barrier.wait()
                let held = try snapshot(); try persist(held, mode + "Pending-held")
                try check(mode + "PendingEntered", held.graph.pending && held.graph.request != nil
                    && held.graph.state.generation == before.graph.state.generation &+ 1
                    && studio.sourcePluginLibraryPreparationQueue.isRunning)
                pending.cancel(); var cancelled = false
                do { try await pending.value } catch is CancellationError { cancelled = true }
                let after = try snapshot(), afterFrame = try frame(mode + "Pending-cancelled")
                try persist(after, mode + "Pending-cancelled")
                try check(mode + "CallerCancelledBeforeRelease", cancelled && studio.sourcePluginLibraryPreparationQueue.isRunning)
                try check(mode + "CancelledState", after == generation(before, before.graph.state.generation &+ 1) && afterFrame == beforeFrame)
                barrier.finish(); studio.sourcePluginPreparationHook = nil
                await studio.sourcePluginLibraryPreparationQueue.drain()
                let drained = try snapshot(), drainedFrame = try frame(mode + "Pending-drained")
                try persist(drained, mode + "Pending-drained")
                try check(mode + "DrainExact", drained == after && drainedFrame == afterFrame)
            }
            for name in names {
                let again = try requests[name]!.selection.resolve()
                try check(name + "RevisionUnchanged", again.translated.map(\.manifestData) == resolutions[name]!.translated.map(\.manifestData))
            }
        } catch { rows.append(.init(op: "libraryAttachmentInstallFailure", ok: false, detail: String(describing: error))) }
        studio.sourcePluginPreparationHook = nil; studio.cancelSourcePluginLibraryMount()
        await studio.sourcePluginLibraryPreparationQueue.drain()
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}

// Reproduction only: the exact native declaration is the graph oracle; the
// opposing GUID belongs to an explicitly synthetic empty-Awake component.
extension PluginLibraryScenario {
    struct DirectPluginGraph: Decodable {
        enum Phase: String, Decodable { case control, profileFirst, nativeFirst }
        let phase: Phase
        let directory: String, nativeManifest: String
        let conflictManifest: String, conflictProfile: String
        let compatibleManifest: String, compatibleProfile: String
    }
    private struct DirectGraphObservation: Codable, Equatable {
        let state: InitializerObservation
        let focus: FocusObservation
        let hideAdapterVisible: Bool?, interfaceVisible: Bool, accessoryNames: Bool
        let showGizmos: Bool, effectiveShowGizmos: Bool, showTimeline: Bool
        let pending: Bool, request: UUID?
    }

    @MainActor private func directGraphSnapshot(studio: StudioModel, expectedStatus: String? = nil) throws -> DirectGraphObservation {
        func identity(_ value: AnyObject?) -> String? { value.map { String(describing: ObjectIdentifier($0)) } }
        let session = studio.sourcePluginSession, r = studio.host.renderer.resources.statistics()
        let state = InitializerObservation(document: studio.doc, world: session?.world.document,
            runtimeDocument: try session?.savedDocument(), pending: session?.world.pendingSourceDestruction().map(\.sourceIdentity).sorted() ?? [],
            callbacks: session?.runtime.callbackTrace ?? [], resources: [r.meshes, r.textures, r.deformBuffers,
                r.hiddenBuffers, r.meshBufferBytes, r.deformBufferBytes, r.hiddenBufferBytes, r.retiring],
            undo: studio.undoStack, redo: studio.redoStack, status: expectedStatus ?? studio.status, sceneURL: studio.sceneURL,
            generation: studio.sourcePluginMountGeneration, animationTime: studio.sourceAnimationTime,
            blocked: studio.resourceBlockedObjects, diagnostics: studio.resourceDiagnostics)
        let focus = FocusObservation(adapter: identity(studio.sourceFocus.adapter), enabled: studio.sourceFocus.adapter?.enabled,
            originalVolume: studio.sourceFocus.adapter?.originalVolume?.bitPattern,
            masterVolume: studio.sourceAudioBus.masterVolume.bitPattern, voiceVolume: studio.sourceAudioBus.voiceVolume.bitPattern,
            observers: studio.sourceFocusObservers.map { identity($0 as AnyObject)! },
            launchObserver: identity(studio.sourceLaunchObserver.map { $0 as AnyObject }), awaitingInitialFocus: studio.sourceFocus.awaitingInitialFocus,
            session: identity(session), running: studio.sourcePluginsRunning)
        return .init(state: state, focus: focus, hideAdapterVisible: studio.sourceHideStudioUI?.visible,
            interfaceVisible: studio.sourceInterfaceVisible, accessoryNames: studio.sourceAccessoryNamesEnabled,
            showGizmos: studio.showGizmos, effectiveShowGizmos: studio.effectiveShowGizmos, showTimeline: studio.showTimeline,
            pending: studio.sourcePluginLibraryPending, request: studio.sourcePluginMountRequest)
    }

    // Public toon-frame values only. Numeric draw data uses float bits;
    // private renderer retirement stamps and texture objects are excluded.
    private func directGraphFrameBytes(_ frame: RenderFrame) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
        }
        func matrix(_ m: float4x4) -> [UInt32] { (0..<4).flatMap { c in (0..<4).map { m[c][$0].bitPattern } } }
        var items: [[String: Any]] = []
        for item in frame.items {
            let m = item.material, u = m.uniforms
            // Do not serialize C alignment padding after irisRotation.
            let vectors: [String: SIMD4<Float>] = ["baseColor": u.baseColor, "shadowColor": u.shadowColor,
                "specular": u.specular, "rim": u.rim, "outline": u.outline, "tint1": u.tint1, "tint2": u.tint2,
                "tint3": u.tint3, "overlayColor0": u.overlayColor0, "overlayColor1": u.overlayColor1,
                "overlayColor2": u.overlayColor2, "patternColor": u.patternColor, "hairGloss": u.hairGloss,
                "params": u.params, "eye": u.eye, "emissive": u.emissive, "uvTransform": u.uvTransform,
                "irisST0": u.irisST0, "irisST1": u.irisST1, "irisST2": u.irisST2]
            let uniformFields: [String: Any] = ["vectors": vectors.mapValues { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern, $0.w.bitPattern] },
                "kind": u.kind, "flags": u.flags, "sourceAlphaABits": u.sourceAlphaA.bitPattern,
                "sourceAlphaBBits": u.sourceAlphaB.bitPattern, "irisRotationBits": u.irisRotation.bitPattern]
            let textures = [m.base, m.colorMask, m.detail, m.line, m.normal, m.overlay0, m.overlay1,
                m.overlay2, m.pattern, m.hairGloss, m.bodyMask].map { $0?.id }
            var value: [String: Any] = ["mesh": item.mesh.id, "objectID": item.objectID, "model": matrix(item.model),
                "materialUniforms": uniformFields, "textures": try json(textures),
                "transparent": m.transparent, "depthBias": m.depthBias.bitPattern,
                "castsShadow": item.castsShadow, "outline": item.outline, "outlineScale": item.outlineScale.bitPattern,
                "visible": item.visible, "hiddenRegions": item.hiddenRegions, "order": item.order,
                "morphIndices": item.morphWeights.map(\.index), "morphWeightBits": item.morphWeights.map { $0.weight.bitPattern }]
            value["deformKey"] = try json(item.deformKey); value["skinSet"] = try json(item.skinSet)
            value["hiddenKey"] = try json(item.hiddenKey); items.append(value)
        }
        let gizmos: [[String: Any]] = frame.gizmos.map { g in
            ["primitive": g.primitive == .lines ? "lines" : "triangles", "model": matrix(g.model),
             "depthTest": g.depthTest, "objectID": g.objectID,
             "vertices": g.vertices.map { v in [v.position.x.bitPattern, v.position.y.bitPattern, v.position.z.bitPattern,
                v.color.x.bitPattern, v.color.y.bitPattern, v.color.z.bitPattern, v.color.w.bitPattern] }]
        }
        let skins: [[String: Any]] = frame.skinSets.keys.sorted().map { ["key": $0, "matrices": frame.skinSets[$0]!.map(matrix)] }
        let bounds = [frame.sceneBounds.min.x, frame.sceneBounds.min.y, frame.sceneBounds.min.z,
            frame.sceneBounds.max.x, frame.sceneBounds.max.y, frame.sceneBounds.max.z].map(\.bitPattern)
        return try JSONSerialization.data(withJSONObject: ["camera": json(frame.camera), "mainLight": json(frame.mainLight),
            "lights": json(frame.lights), "effects": json(frame.effects), "bounds": bounds,
            "timeBits": frame.time.bitPattern, "items": items, "gizmos": gizmos, "skinSets": skins], options: [.sortedKeys])
    }

    @MainActor private func reproduceDirectPluginGraph(_ configuration: DirectPluginGraph,
                                                       app: AppState, studio: StudioModel) -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = []
        let directory = URL(fileURLWithPath: configuration.directory, isDirectory: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func record(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append(.init(op: name, ok: ok, detail: detail))
        }
        func require(_ name: String, _ ok: Bool, _ detail: String = "") throws {
            record(name, ok, detail)
            if !ok { throw SourcePluginError.runtime("Direct graph precondition failed: \(name)") }
        }
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: directory.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func snapshot() throws -> DirectGraphObservation { try directGraphSnapshot(studio: studio) }
        func frame(_ name: String) throws -> Data {
            let bytes = try directGraphFrameBytes(studio.host.renderer.currentFrame())
            try bytes.write(to: directory.appendingPathComponent(name + "-frame.json"), options: .withoutOverwriting)
            return bytes
        }
        func content(_ input: StudioDocument) -> StudioDocument {
            var value = input; value.sourcePluginState = nil; value.sourceNativePlugins = nil
            value.sourcePluginLibrary = nil; value.sourcePluginLibraryConfiguration = nil
            return value
        }
        func loadProfile(_ path: String) throws {
            try studio.loadSourcePluginProfileInteractively(profileURL: URL(fileURLWithPath: path),
                expectedGeneration: studio.sourcePluginMountGeneration)
        }
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw SourcePluginError.invalid("Direct graph output already exists.") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false; studio.showGizmos = false; studio.showTimeline = false
            try require("directFixture", studio.doc.objects.contains { $0.sourceObjectKey == 10 && $0.sourceCharacter != nil }
                && !studio.host.renderer.currentFrame().items.isEmpty && studio.host.renderer.currentFrame().items.allSatisfy { $0.sourceShader == nil }
                && studio.sourcePluginSession == nil && studio.doc.sourceNativePlugins == nil && studio.sourceHideStudioUI == nil)
            let native = try SourceNativePluginPackage.load(url: URL(fileURLWithPath: configuration.nativeManifest))
            let conflict = try SourcePluginPackage.load(url: URL(fileURLWithPath: configuration.conflictManifest))
            let compatible = try SourcePluginPackage.load(url: URL(fileURLWithPath: configuration.compatibleManifest))
            func isExactNoOp(_ package: SourcePluginPackage) -> Bool {
                guard package.programs.count == 1 else { return false }
                let program = package.programs[0]
                guard program.type == "DirectGraphNoOp", program.fields.isEmpty,
                      program.methods.count == 1 else { return false }
                let method = program.methods[0]
                return method.lifecycle == "Awake" && method.body.kind == "block"
                    && method.body.children?.isEmpty == true
            }
            let exactNative = native.manifestSHA256 == "32b46f07df8841801080c54145c147b9722319fab538f61d6a9fbb79b0a3a496"
                && native.manifest.incompatibilities == ["HideStudioUI", "HideHInterface"]
            let exactConflict = conflict.manifest.identity.guid.utf8.elementsEqual("HideStudioUI".utf8)
            let exactCompatible = compatible.manifest.identity.guid.utf8.elementsEqual("Ikkoku.Validation.DirectGraphControl".utf8)
            try require("exactGraphInputs", exactNative && exactConflict && exactCompatible
                && [conflict, compatible].allSatisfy(isExactNoOp))
            for nativeFirst in [false, true] {
                let nodes = [SourcePluginGraph.Node(package: conflict), .init(nativeAdapter: native)]
                var actual: SourcePluginLibraryError?
                do { _ = try SourcePluginGraph.order(nativeFirst ? Array(nodes.reversed()) : nodes, process: "CharaStudio") }
                catch let error as SourcePluginLibraryError { actual = error }
                try require("mixedConflict\(nativeFirst ? "NativeFirst" : "ProfileFirst")",
                    actual == .incompatible(guid: "keelhauled.hideallui", other: "HideStudioUI"), actual?.description ?? "No rejection")
                let control = [SourcePluginGraph.Node(package: compatible), .init(nativeAdapter: native)]
                try require("mixedCompatible\(nativeFirst ? "NativeFirst" : "ProfileFirst")",
                    try SourcePluginGraph.order(nativeFirst ? Array(control.reversed()) : control, process: "CharaStudio") == [0, 1])
            }
            let baseline = try snapshot(); try persist(baseline, "baseline")
            let nativeURL = URL(fileURLWithPath: configuration.nativeManifest)
            if configuration.phase == .control {
                for nativeFirst in [false, true] {
                    let name = nativeFirst ? "nativeFirst" : "profileFirst"
                    if nativeFirst { try studio.loadSourceNativePlugin(url: nativeURL) }
                    try loadProfile(configuration.compatibleProfile)
                    if !nativeFirst { try studio.loadSourceNativePlugin(url: nativeURL) }
                    studio.sourcePluginsRunning = false
                    let mounted = try snapshot(); try persist(mounted, name + "-mounted")
                    guard let session = studio.sourcePluginSession, let object = studio.doc.objects.first(where: { $0.sourceObjectKey == 10 }),
                          let sourceIdentity = session.world.identities[object.id] else { throw SourcePluginError.invalid("Control has no bound session.") }
                    try require(name + "CompatibleMounted", studio.sourceHideStudioUI != nil && studio.doc.sourceNativePlugins == [SourceNativePluginReference(package: native)]
                        && session.library.packages.count == 1 && session.library.packages[0].manifestData == compatible.manifestData
                        && mounted.state.callbacks == ["Ikkoku.Validation.DirectGraphControl/DirectGraphNoOp/\(sourceIdentity):Awake"])
                    try require(name + "NoWorldMutation", content(studio.doc) == content(baseline.state.document)
                        && content(session.world.document) == content(studio.doc) && mounted.state.resources == baseline.state.resources
                        && mounted.state.animationTime == baseline.state.animationTime)
                    let beforeFrame = try frame(name + "-visible")
                    studio.toggleSourceInterface()
                    let hidden = try snapshot()
                    try require(name + "Hide", !studio.sourceInterfaceVisible && !studio.effectiveShowGizmos
                        && !studio.showGizmos && !studio.showTimeline && hidden.state == mounted.state)
                    studio.toggleSourceInterface()
                    let shown = try snapshot(), shownFrame = try frame(name + "-shown")
                    try require(name + "Show", studio.sourceInterfaceVisible && !studio.showGizmos && !studio.showTimeline
                        && shown == mounted && shownFrame == beforeFrame)
                    studio.unloadSourcePluginsInteractively()
                    try require(name + "Unload", studio.sourcePluginSession == nil && studio.sourceHideStudioUI == nil
                        && studio.doc.sourceNativePlugins == nil && studio.doc.sourcePluginState == nil
                        && content(studio.doc) == content(baseline.state.document))
                }
            } else {
                let nativeFirst = configuration.phase == .nativeFirst
                if nativeFirst {
                    try studio.loadSourceNativePlugin(url: nativeURL); studio.toggleSourceInterface()
                    try require("firstMount", studio.sourceHideStudioUI?.visible == false && studio.sourcePluginSession == nil)
                } else {
                    try loadProfile(configuration.conflictProfile); studio.sourcePluginsRunning = false
                    try require("firstMount", studio.sourcePluginSession?.library.packages.first?.manifestData == conflict.manifestData
                        && studio.sourceHideStudioUI == nil && studio.doc.sourceNativePlugins == nil)
                }
                // The first load is a successful precondition, not the rejected
                // transaction. Preserve only the attempted second-load boundary.
                let before = try snapshot(), owner = studio.sourcePluginSession, focusOwner = studio.sourceFocus.adapter
                let tokens = studio.sourceFocusObservers, launch = studio.sourceLaunchObserver
                try persist(before, "attempt-before"); let beforeFrame = try frame("attempt-before")
                var errorText: String?
                do {
                    if nativeFirst { try loadProfile(configuration.conflictProfile) }
                    else { try studio.loadSourceNativePlugin(url: nativeURL) }
                } catch { errorText = String(describing: error) }
                let after = try snapshot(); try persist(after, "attempt-after"); let afterFrame = try frame("attempt-after")
                try persist(["outcome": errorText ?? "NO REJECTION"], "attempt-result")
                let graphError = SourcePluginLibraryError.incompatible(guid: "keelhauled.hideallui", other: "HideStudioUI").description
                record("secondLoadRejected", errorText == graphError || errorText == SourcePluginError.invalid(graphError).description,
                    errorText ?? "The direct loader admitted the declared incompatibility")
                record("secondLoadStateRetained", before == after, "Full document/runtime/history/clock/resources and host state")
                record("secondLoadOwnersRetained", studio.sourcePluginSession === owner && studio.sourceFocus.adapter === focusOwner
                    && studio.sourceLaunchObserver === launch && tokens.count == studio.sourceFocusObservers.count
                    && zip(tokens, studio.sourceFocusObservers).allSatisfy { $0 === $1 })
                record("secondLoadFrameRetained", beforeFrame == afterFrame, "All public toon-frame fields; private retirement stamps excluded")
                // Diagnostic observations do not replace the rejection/retention
                // invariants above, and no retry changes this recorded state.
                try persist(["translated": studio.sourcePluginSession?.library.packages.map { $0.manifest.identity.guid } ?? [],
                    "native": studio.doc.sourceNativePlugins?.map(\.guid) ?? []], "mounted-identities")
            }
        } catch { record("directGraphReproductionFailure", false, String(describing: error)) }
        studio.sourcePluginsRunning = false
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}

// Reproduction only: direct-load admission and saved candidate restoration are
// distinct entry points. The conflicting cards below are synthetic historical
// documents, not successful saves through the now-guarded direct loader.
extension PluginLibraryScenario {
    struct NativeGraphRestore: Decodable {
        let phase: NativeProfileRestore.Phase
        let directory: String, outputDirectory: String, nativeManifest: String
        let conflictManifest: String, conflictProfile: String
        let compatibleManifest: String, compatibleProfile: String
    }
    private struct NativeGraphObservation: Codable, Equatable {
        let graph: DirectGraphObservation
        let previewOwners: [String]
    }

    @MainActor private func reproduceNativeGraphRestore(_ configuration: NativeGraphRestore,
                                                         app: AppState, studio: StudioModel) -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = []
        let directory = URL(fileURLWithPath: configuration.directory, isDirectory: true)
        let output = URL(fileURLWithPath: configuration.outputDirectory, isDirectory: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func record(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append(.init(op: name, ok: ok, detail: detail))
        }
        func require(_ name: String, _ ok: Bool, _ detail: String = "") throws {
            record(name, ok, detail)
            if !ok { throw SourcePluginError.runtime("Native graph control failed: \(name)") }
        }
        func scene(_ name: String) -> URL { directory.appendingPathComponent(name + ".png") }
        func decoded(_ name: String) throws -> StudioDocument {
            try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: Data(contentsOf: scene(name)))
        }
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: output.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func snapshot(status: String? = nil) throws -> NativeGraphObservation {
            .init(graph: try directGraphSnapshot(studio: studio, expectedStatus: status),
                previewOwners: studio.renderedSourceCharacterPreviews.map { String(describing: ObjectIdentifier($0)) }.sorted())
        }
        func frame(_ name: String) throws -> Data {
            let bytes = try directGraphFrameBytes(studio.host.renderer.currentFrame())
            try bytes.write(to: output.appendingPathComponent(name + "-frame.json"), options: .withoutOverwriting)
            return bytes
        }
        func writeScene(_ value: StudioDocument, _ name: String) throws {
            try CardIO.encode(value, keyword: CardIO.sceneKeyword, thumbnail: nil)
                .write(to: scene(name), options: .withoutOverwriting)
        }
        func sameObjects(_ a: StudioDocument, _ b: StudioDocument) -> Bool {
            a.objects.map(\.id) == b.objects.map(\.id) && a.sourceSceneSHA256 == b.sourceSceneSHA256
        }
        do {
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw SourcePluginError.invalid("Native graph observation output already exists.")
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false; studio.showGizmos = false; studio.showTimeline = false
            try require("sourceFixture", studio.doc.objects.contains { $0.sourceObjectKey == 10 && $0.sourceCharacter != nil }
                && !studio.host.renderer.currentFrame().items.isEmpty
                && studio.host.renderer.currentFrame().items.allSatisfy { $0.sourceShader == nil }
                && studio.sourcePluginSession == nil && studio.doc.sourceNativePlugins == nil)
            let native = try SourceNativePluginPackage.load(url: URL(fileURLWithPath: configuration.nativeManifest))
            let conflict = try SourcePluginPackage.load(url: URL(fileURLWithPath: configuration.conflictManifest))
            let compatible = try SourcePluginPackage.load(url: URL(fileURLWithPath: configuration.compatibleManifest))
            func isExactNoOp(_ package: SourcePluginPackage) -> Bool {
                guard package.programs.count == 1 else { return false }
                let program = package.programs[0]
                guard program.type == "DirectGraphNoOp", program.fields.isEmpty,
                      program.methods.count == 1 else { return false }
                let method = program.methods[0]
                return method.lifecycle == "Awake" && method.body.kind == "block"
                    && method.body.children?.isEmpty == true
            }
            let exactNative = native.manifestSHA256 == "32b46f07df8841801080c54145c147b9722319fab538f61d6a9fbb79b0a3a496"
                && native.manifest.incompatibilities == ["HideStudioUI", "HideHInterface"]
            let exactConflict = conflict.manifest.identity.guid.utf8.elementsEqual("HideStudioUI".utf8)
            let exactCompatible = compatible.manifest.identity.guid.utf8.elementsEqual("Ikkoku.Validation.DirectGraphControl".utf8)
            try require("exactGraphInputs", exactNative && exactConflict && exactCompatible
                && [conflict, compatible].allSatisfy(isExactNoOp))
            let graphError = SourcePluginLibraryError.incompatible(guid: "keelhauled.hideallui", other: "HideStudioUI")
            var actual: SourcePluginLibraryError?
            do { _ = try SourcePluginGraph.order([.init(package: conflict), .init(nativeAdapter: native)], process: "CharaStudio") }
            catch let error as SourcePluginLibraryError { actual = error }
            try require("independentConflictOracle", actual == graphError, actual?.description ?? "No rejection")
            try require("independentCompatibleOracle", try SourcePluginGraph.order(
                [.init(package: compatible), .init(nativeAdapter: native)], process: "CharaStudio") == [0, 1])

            switch configuration.phase {
            case .save:
                guard !FileManager.default.fileExists(atPath: directory.path) else {
                    throw SourcePluginError.invalid("Native graph save requires a fresh fixture directory.")
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try studio.loadSourcePluginProfileInteractively(profileURL: URL(fileURLWithPath: configuration.compatibleProfile),
                    expectedGeneration: studio.sourcePluginMountGeneration)
                try studio.loadSourceNativePlugin(url: native.manifestURL)
                studio.sourcePluginsRunning = false
                try studio.stepSourcePlugins(deltaTime: 0.04)
                let expected = try studio.sourcePluginSession!.savedDocument().sourcePluginState
                try require("compatibleMounted", studio.sourceHideStudioUI != nil
                    && studio.doc.sourceNativePlugins == [SourceNativePluginReference(package: native)]
                    && expected?.clock.elapsedTime == Double(Float(0.04)))
                try studio.saveScene(to: scene("compatible"))
                let saved = try decoded("compatible")
                try persist(saved, "compatible-saved")
                try require("compatibleActualNativeSave", saved.sourcePluginState == expected
                    && saved.sourceNativePlugins == studio.doc.sourceNativePlugins && sameObjects(saved, studio.doc))

                var base = saved
                base.sourcePluginState = nil; base.sourceNativePlugins = nil
                base.sourcePluginLibrary = nil; base.sourcePluginLibraryConfiguration = nil
                func historical(_ profile: URL) throws -> StudioDocument {
                    // No native host is installed. Build a valid saved IR state
                    // with the existing session API, then encode historical refs.
                    let session = try SourceStudioPluginSession(profileURL: profile, document: base)
                    return try session.step(document: base, deltaTime: 0.04)
                }
                let plain = try historical(URL(fileURLWithPath: configuration.conflictProfile))
                try writeScene(plain, "opposing-only")
                try require("opposingOnlyFixture", sameObjects(plain, saved) && plain.sourceNativePlugins == nil
                    && plain.sourcePluginState?.packages.map(\.guid) == ["HideStudioUI"])
                var conflicting = plain; conflicting.sourceNativePlugins = [SourceNativePluginReference(package: native)]
                try writeScene(conflicting, "conflicting")
                try require("conflictingHistoricalFixture", try decoded("conflicting") == conflicting
                    && conflicting.sourcePluginState?.clock == saved.sourcePluginState?.clock
                    && sameObjects(conflicting, saved), "Synthetic CardIO scene; not a successful direct mixed mount")
                var disabled = conflicting; disabled.sourceNativePlugins![0].enabled = false
                try writeScene(disabled, "disabled")
                try require("disabledSelectedFixture", try decoded("disabled") == disabled
                    && disabled.sourcePluginState == conflicting.sourcePluginState,
                    "Only enabled changes; selected package identity and its incompatibility remain")

                let changedProfile = directory.appendingPathComponent("changed-profile.json")
                let originalProfileBytes = try Data(contentsOf: URL(fileURLWithPath: configuration.conflictProfile))
                try originalProfileBytes.write(to: changedProfile, options: .withoutOverwriting)
                var changed = try historical(changedProfile); changed.sourceNativePlugins = conflicting.sourceNativePlugins
                try writeScene(changed, "changed-profile")
                var changedBytes = originalProfileBytes; changedBytes.append(contentsOf: [0x20, 0x0a])
                _ = try JSONSerialization.jsonObject(with: changedBytes)
                try changedBytes.write(to: changedProfile)
                let changedSHA = SHA256.hash(data: changedBytes).map { String(format: "%02x", $0) }.joined()
                try require("changedValidProfileIdentity", changedSHA != changed.sourcePluginState?.profileSHA256
                    && changed.sourceNativePlugins == conflicting.sourceNativePlugins && sameObjects(changed, saved))

                // Copy only the exact verified manifest and its declared files;
                // never modify installed/shared source or configuration bytes.
                guard let config = native.manifest.configuration else { throw SourcePluginError.invalid("Expected native configuration fixture.") }
                let copy = directory.appendingPathComponent("changed-native", isDirectory: true)
                try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                let manifest = copy.appendingPathComponent("manifest.json")
                try Data(contentsOf: native.manifestURL).write(to: manifest, options: .withoutOverwriting)
                for file in [native.manifest.source, config] {
                    let target = copy.appendingPathComponent(file.file)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(contentsOf: native.manifestURL.deletingLastPathComponent().appendingPathComponent(file.file))
                        .write(to: target, options: .withoutOverwriting)
                }
                let copied = try SourceNativePluginPackage.load(url: manifest)
                var changedNative = conflicting; changedNative.sourceNativePlugins = [SourceNativePluginReference(package: copied)]
                try writeScene(changedNative, "changed-native")
                let configURL = copy.appendingPathComponent(config.file)
                var bytes = try Data(contentsOf: configURL); bytes.append(0x0a); try bytes.write(to: configURL)
                var nativeError: String?
                do { _ = try changedNative.sourceNativePlugins![0].load() } catch { nativeError = String(describing: error) }
                try require("changedNativeConfigIdentity", nativeError == SourcePluginError.invalid("Native adapter source or configuration hash changed.").description
                    && changedNative.sourcePluginState == conflicting.sourcePluginState, nativeError ?? "No rejection")
                try String(ProcessInfo.processInfo.processIdentifier).write(to: directory.appendingPathComponent("save-pid.txt"), atomically: true, encoding: .utf8)
                try persist(["compatible": "Actual StudioModel.saveScene",
                    "others": "Synthetic historical CardIO documents; same UUIDs and validated saved IR state",
                    "changed-profile": "Copied profile with valid JSON whitespace change after snapshot",
                    "changed-native": "Copied verified native configuration changed after snapshot"], "fixture-construction")
            case .reopen:
                let savedPID = try String(contentsOf: directory.appendingPathComponent("save-pid.txt"), encoding: .utf8)
                try require("freshProcessBoundary", savedPID != String(ProcessInfo.processInfo.processIdentifier),
                    "save PID=\(savedPID), reopen PID=\(ProcessInfo.processInfo.processIdentifier)")
                let saved = try decoded("compatible"), opposing = try decoded("opposing-only")
                try require("sameUUIDCandidateContexts", sameObjects(saved, opposing)
                    && saved.sourcePluginState?.packages.map(\.guid) == ["Ikkoku.Validation.DirectGraphControl"]
                    && opposing.sourcePluginState?.packages.map(\.guid) == ["HideStudioUI"]
                    && saved.sourceNativePlugins?.count == 1 && opposing.sourceNativePlugins == nil)

                // Drive real history operations. Fixture assignment seeds an
                // existing document snapshot; no stack or generation is written.
                func seedHistory(_ action: String, target: StudioDocument) throws {
                    let prior = studio.doc
                    if action == "undo" {
                        studio.doc = target; studio.pushUndo(force: true); studio.doc = prior
                    } else if action == "redo" {
                        studio.pushUndo(force: true); studio.doc = target; studio.undo()
                        guard studio.doc.objects == prior.objects && studio.doc.sourcePluginState == prior.sourcePluginState,
                              studio.redoStack.last == target, studio.sourcePluginSession != nil else {
                            throw SourcePluginError.runtime("Unable to seed the real redo candidate.")
                        }
                    }
                }
                func controlRestored() throws -> Bool {
                    guard let session = studio.sourcePluginSession else { return false }
                    let state = try session.savedDocument().sourcePluginState
                    return studio.doc.objects == saved.objects && studio.doc.sourcePluginState == saved.sourcePluginState
                        && studio.doc.sourceNativePlugins == saved.sourceNativePlugins && studio.sourceHideStudioUI != nil
                        && session.library.packages.first?.manifestData == compatible.manifestData
                        && session.world.document.objects == saved.objects
                        && state == saved.sourcePluginState
                        && session.runtime.callbackTrace.isEmpty && !studio.sourcePluginsRunning
                        && !studio.host.renderer.currentFrame().items.isEmpty
                }
                for action in ["open", "undo", "redo"] {
                    try studio.loadScene(from: scene("opposing-only"))
                    try seedHistory(action, target: saved)
                    try require("compatible\(action)PriorContext", studio.sourcePluginSession?.library.packages.first?.manifestData == conflict.manifestData
                        && studio.doc.sourceNativePlugins == nil && sameObjects(studio.doc, saved)
                        && (action != "undo" || studio.undoStack.last == saved)
                        && (action != "redo" || studio.redoStack.last == saved))
                    try persist(snapshot(), "compatible-\(action)-before")
                    if action == "open" { try studio.loadScene(from: scene("compatible")) }
                    else if action == "undo" { studio.undo() } else { studio.redo() }
                    try persist(snapshot(), "compatible-\(action)-after")
                    try require("compatible\(action)CandidateRestored", try controlRestored(), studio.status)
                }

                let incompatible = [graphError.description, SourcePluginError.invalid(graphError.description).description]
                let changedProfile = [SourcePluginError.invalid("Saved plugin profile or library bindings changed; explicit reinstallation is required.").description]
                let changedNative = [SourcePluginError.invalid("Native adapter source or configuration hash changed.").description]
                let cases: [(String, String, [String])] = [
                    ("conflicting", "open", incompatible), ("conflicting", "undo", incompatible), ("conflicting", "redo", incompatible),
                    ("disabled", "open", incompatible), ("changed-profile", "open", changedProfile),
                    ("changed-profile", "undo", changedProfile), ("changed-profile", "redo", changedProfile),
                    ("changed-native", "open", changedNative)]
                for (fixture, action, errors) in cases {
                    let name = fixture + "-" + action, candidate = try decoded(fixture)
                    try studio.loadScene(from: scene("compatible")); try studio.stepSourcePlugins(deltaTime: 0.02)
                    studio.sourcePluginsRunning = false
                    try seedHistory(action, target: candidate)
                    if studio.sourceInterfaceVisible { studio.toggleSourceInterface() }
                    try require(name + "Prior", studio.sourcePluginSession?.library.packages.first?.manifestData == compatible.manifestData
                        && studio.doc.sourceNativePlugins == saved.sourceNativePlugins && studio.sourceHideStudioUI?.visible == false
                        && sameObjects(studio.doc, candidate) && !studio.renderedSourceCharacterPreviews.isEmpty
                        && (action != "undo" || studio.undoStack.last == candidate)
                        && (action != "redo" || studio.redoStack.last == candidate))
                    let before = try snapshot(), session = studio.sourcePluginSession, focus = studio.sourceFocus.adapter
                    let previews = studio.renderedSourceCharacterPreviews, tokens = studio.sourceFocusObservers, launch = studio.sourceLaunchObserver
                    try persist(candidate, name + "-candidate"); try persist(before, name + "-before")
                    let beforeFrame = try frame(name + "-before")
                    var result = "NO REJECTION"
                    if action == "open" {
                        do { try studio.loadScene(from: scene(fixture)) } catch { result = String(describing: error) }
                    } else {
                        if action == "undo" { studio.undo() } else { studio.redo() }
                        result = studio.status
                    }
                    let after = try snapshot(); try persist(after, name + "-after")
                    let afterFrame = try frame(name + "-after")
                    try persist(["outcome": result], name + "-result")
                    let expected = action == "open" ? errors : errors.map { "Plugin restore: " + $0 }
                    let rejected = expected.contains(result)
                    // Only an independently matched history error permits its
                    // documented status update. Raw snapshots keep that status.
                    let comparison: NativeGraphObservation
                    if rejected && action != "open" { comparison = try snapshot(status: before.graph.state.status) }
                    else { comparison = after }
                    record(name + "Rejected", rejected, result)
                    record(name + "StateRetained", comparison == before, "Exact document/runtime/history/clocks/resources/host state; only matched history error status is normalized")
                    record(name + "OwnersRetained", studio.sourcePluginSession === session && studio.sourceFocus.adapter === focus
                        && studio.sourceLaunchObserver === launch && studio.sourceFocusObservers.count == tokens.count
                        && zip(tokens, studio.sourceFocusObservers).allSatisfy { $0 === $1 })
                    record(name + "PreviewOwnersRetained", Set(previews.map(ObjectIdentifier.init))
                        == Set(studio.renderedSourceCharacterPreviews.map(ObjectIdentifier.init)))
                    record(name + "FrameRetained", beforeFrame == afterFrame, "All public toon-frame fields; no padding/private renderer stamps")
                }
            }
        } catch { record("nativeGraphReproductionFailure", false, String(describing: error)) }
        studio.sourcePluginsRunning = false
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}

// Synthetic constructor-replay reproduction. These snapshots intentionally
// retain both documents: native open may commit the input while the reconstructed
// runtime has a different world. No production restore policy is changed here.
extension PluginLibraryScenario {
    private struct InitializerObservation: Codable, Equatable {
        let document: StudioDocument
        let world: StudioDocument?
        let runtimeDocument: StudioDocument?
        let pending: [String], callbacks: [String], resources: [Int]
        let undo: [StudioDocument], redo: [StudioDocument]
        let status: String, sceneURL: URL?
        let generation: UInt64, animationTime: Float
        let blocked: Set<UUID>, diagnostics: [String]
    }

    @MainActor private func reproduceInitializerRestore(_ configuration: NativeProfileRestore,
                                                        app: AppState, studio: StudioModel,
                                                        pendingDestruction: Bool = false) async -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = []
        func record(_ name: String, _ okay: Bool, _ detail: String = "") {
            rows.append(.init(op: name, ok: okay, detail: detail))
        }
        func require(_ name: String, _ okay: Bool, _ detail: String = "") throws {
            record(name, okay, detail)
            if !okay { throw SourcePluginError.runtime("Initializer reproduction precondition failed: \(name)") }
        }
        func snapshot(expectedStatus: String? = nil) throws -> InitializerObservation {
            let session = studio.sourcePluginSession, r = studio.host.renderer.resources.statistics()
            return .init(document: studio.doc, world: session?.world.document,
                runtimeDocument: try session?.savedDocument(),
                pending: session?.world.pendingSourceDestruction().map(\.sourceIdentity).sorted() ?? [],
                callbacks: session?.runtime.callbackTrace ?? [],
                resources: [r.meshes, r.textures, r.deformBuffers, r.hiddenBuffers,
                    r.meshBufferBytes, r.deformBufferBytes, r.hiddenBufferBytes, r.retiring],
                undo: studio.undoStack, redo: studio.redoStack, status: expectedStatus ?? studio.status, sceneURL: studio.sceneURL,
                generation: studio.sourcePluginMountGeneration, animationTime: studio.sourceAnimationTime,
                blocked: studio.resourceBlockedObjects, diagnostics: studio.resourceDiagnostics)
        }
        func sameFrame(_ a: RenderFrame, _ b: RenderFrame) -> Bool {
            a.camera == b.camera && a.mainLight == b.mainLight && a.effects == b.effects && a.lights == b.lights
                && a.sceneBounds == b.sceneBounds && a.time == b.time && a.skinSets == b.skinSets
                && a.gizmos.count == b.gizmos.count && a.items.count == b.items.count
                && zip(a.items, b.items).allSatisfy { $0.mesh == $1.mesh && $0.model == $1.model && $0.objectID == $1.objectID }
        }
        let directory = URL(fileURLWithPath: configuration.directory, isDirectory: true)
        func path(_ name: String, _ suffix: String) -> URL { directory.appendingPathComponent(name + suffix) }
        func persist(_ value: InitializerObservation, _ name: String) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: path(name, ".json"))
        }
        func card(_ name: String) throws -> StudioDocument {
            try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: Data(contentsOf: path(name, ".png")))
        }
        func outcome(_ error: any Error) -> String {
            switch error {
            case SourcePluginError.invalid(let reason): return "invalid: " + reason
            case SourcePluginError.runtime(let reason): return "runtime: " + reason
            default: return String(describing: error)
            }
        }
        func summary(_ value: InitializerObservation) -> String {
            let ids = value.document.objects.map { $0.id.uuidString }.sorted()
            let worldIDs = value.world?.objects.map { $0.id.uuidString }.sorted() ?? []
            return "documentIDs=\(ids); worldIDs=\(worldIDs); cloneSerial=\(value.runtimeDocument?.sourcePluginState?.cloneSerial ?? 0); pending=\(value.pending); callbacks=\(value.callbacks)"
        }
        let topologyError = "Restoring plugin initialization changed scene object topology, identities, or clone state."
        func checkHistoryRejection(_ name: String, expectedError: String? = nil, action: () -> Void) throws {
            let before = try snapshot(), session = studio.sourcePluginSession
            let frame = studio.host.renderer.currentFrame(), adapter = studio.sourceFocus.adapter
            let gain = studio.sourceAudioBus.masterVolume, observers = studio.sourceFocusObservers.count
            let launchObserver = studio.sourceLaunchObserver != nil
            try persist(before, name + "-before")
            action()
            try persist(snapshot(), name + "-after")
            record(name + "ExactError", studio.status == "Plugin restore: Invalid translated plugin: " + (expectedError ?? topologyError), studio.status)
            record(name + "RetainsPrior", try snapshot(expectedStatus: before.status) == before
                && studio.sourcePluginSession === session && studio.sourceFocus.adapter === adapter
                && studio.sourceAudioBus.masterVolume == gain && studio.sourceFocusObservers.count == observers
                && (studio.sourceLaunchObserver != nil) == launchObserver && !studio.sourcePluginsRunning
                && sameFrame(frame, studio.host.renderer.currentFrame()),
                "Only the explicit history error status changes; target stack, scene, session, clocks, resources and frame stay intact")
        }
        let names = pendingDestruction ? ["noop", "Destroy", "AwakeDestroy"] : ["noop", "Instantiate", "SetActive", "Destroy", "changed"]
        do {
            studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            switch configuration.phase {
            case .save:
                guard !FileManager.default.fileExists(atPath: directory.path) else {
                    throw SourcePluginError.invalid("Initializer reproduction requires a fresh output directory.")
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for name in names {
                    studio.newScene()
                    var target = StudioObject(name: "Synthetic initializer target", kind: .folder)
                    target.sourceObjectKey = 12
                    var document = StudioDocument(); document.objects = [target]
                    document.sourceSceneSHA256 = String(repeating: "c", count: 64); studio.doc = document
                    let mutation = ["Instantiate", "SetActive", "Destroy"].contains(name) ? name : nil
                    let profile = try freshProfileFixture(directory: directory.appendingPathComponent(name),
                        phase: name == "AwakeDestroy" ? "Awake" : "initializer", fail: false, attachmentRead: false,
                        mutation: mutation, destroyOnAwake: name == "AwakeDestroy")
                    try studio.loadSourcePluginProfileInteractively(profileURL: profile,
                        expectedGeneration: studio.sourcePluginMountGeneration)
                    studio.sourcePluginsRunning = false
                    let mounted = try snapshot(); try persist(mounted, name + "-mounted")
                    try require(name + "FreshInstall", mounted.document.objects.count == (name == "Instantiate" ? 2 : 1)
                        && mounted.document.objects == mounted.world?.objects
                        && mounted.runtimeDocument?.sourcePluginState?.cloneSerial == (name == "Instantiate" ? 1 : 0), summary(mounted))
                    if name == "SetActive" {
                        try require("SetActiveFreshHidden", studio.doc.object(target.id)?.visible == false)
                        // A genuine user edit, after the constructor, makes the
                        // saved input differ from replayed SetActive(false).
                        studio.update(target.id) { $0.visible = true }
                    }
                    if name == "Destroy" || name == "AwakeDestroy" {
                        try require(name + "PendingBeforeSave", mounted.pending.count == 1
                            && mounted.document.object(target.id) != nil,
                            "Save before any runtime step; pending destruction is still live")
                    }
                    if name == "AwakeDestroy" {
                        let binding = mounted.runtimeDocument?.sourcePluginState?.bindings.first
                        try require("AwakeDestroyLifecycleBeforeSave", binding?.awake == true && binding?.started == false
                            && binding?.destroyed == false && mounted.callbacks.map { $0.components(separatedBy: ":").last! } == ["Awake"],
                            "Awake ran once; destruction remains queued before any frame barrier")
                    }
                    // No runtime step here: it would erase the pending-Destroy
                    // case and change initializer/Start ordering under study.
                    try studio.saveScene(to: path(name, ".png"))
                    let saved = try card(name), afterSave = try snapshot()
                    try persist(afterSave, name + "-saved")
                    try require(name + "NativeSave", saved.objects == afterSave.document.objects
                        && saved.sourcePluginState == afterSave.runtimeDocument?.sourcePluginState
                        && saved.sourcePluginState?.clock.elapsedTime == 0, summary(afterSave))
                    // The original, freshly installed session supplies an
                    // independent continuation oracle after the same save point.
                    // Destroy is stepped only after its pending state is saved.
                    try studio.stepSourcePlugins(deltaTime: 0.02)
                    let continued = try snapshot(); try persist(continued, name + "-fresh-stepped")
                    try require(name + "FreshFirstStepSucceeds", continued.runtimeDocument?.sourcePluginState?.clock.elapsedTime
                        == Double(Float(0.02)), summary(continued))
                    if pendingDestruction {
                        let destroyed = name != "noop"
                        try require(name + "OriginalContinuation", continued.document.objects.count == (destroyed ? 0 : 1)
                            && continued.pending.isEmpty && continued.runtimeDocument?.sourcePluginState?.bindings.first?.destroyed == destroyed,
                            summary(continued))
                    }
                    if name == "changed" {
                        var bytes = try Data(contentsOf: profile); bytes.append(contentsOf: [0x20, 0x0a])
                        _ = try JSONSerialization.jsonObject(with: bytes); try bytes.write(to: profile)
                        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                        try require("ChangedValidJSONIdentity", digest != saved.sourcePluginState?.profileSHA256)
                    }
                }
                try String(ProcessInfo.processInfo.processIdentifier).write(to: path("save-pid", ".txt"), atomically: true, encoding: .utf8)
            case .reopen:
                let savePID = try String(contentsOf: path("save-pid", ".txt"), encoding: .utf8)
                try require("FreshProcessBoundary", savePID != String(ProcessInfo.processInfo.processIdentifier),
                    "save PID=\(savePID), reopen PID=\(ProcessInfo.processInfo.processIdentifier)")
                // Seed a real retained session before every candidate, including
                // changed-identity rejection. No source-character cache exists.
                let reopenNames = pendingDestruction && validatePendingDestructionPolicy == true ? []
                    : pendingDestruction ? names : ["changed", "noop", "Instantiate", "SetActive", "Destroy"]
                for name in reopenNames {
                    try studio.loadScene(from: path("noop", ".png"))
                    try studio.stepSourcePlugins(deltaTime: 0.06)
                    let before = try snapshot(), oldSession = studio.sourcePluginSession
                    let beforeFrame = studio.host.renderer.currentFrame(), adapter = studio.sourceFocus.adapter
                    let gain = studio.sourceAudioBus.masterVolume, observers = studio.sourceFocusObservers.count
                    let launchObserver = studio.sourceLaunchObserver != nil
                    try persist(before, name + "-before-reopen")
                    let saved = try card(name)
                    var loadError: String?
                    do { try studio.loadScene(from: path(name, ".png")) }
                    catch { loadError = outcome(error) }
                    let loaded = try snapshot(); try persist(loaded, name + "-reopened")
                    let expectedLoadError = name == "changed"
                        ? "invalid: Saved plugin profile or library bindings changed; explicit reinstallation is required."
                        : name == "Instantiate" ? "invalid: " + topologyError : nil
                    if let loadError {
                        record(name + "LoadOutcome", loadError == expectedLoadError, loadError)
                        record(name + "LoadFailureRetainsPrior", loaded == before && studio.sourcePluginSession === oldSession
                            && studio.sourceFocus.adapter === adapter && studio.sourceAudioBus.masterVolume == gain
                            && studio.sourceFocusObservers.count == observers && (studio.sourceLaunchObserver != nil) == launchObserver
                            && !studio.sourcePluginsRunning && sameFrame(beforeFrame, studio.host.renderer.currentFrame()))
                        if name == "Instantiate" && loadError == expectedLoadError {
                            // Seed the original saved target using ordinary history
                            // capture, never replacing the stacks or invalidation token.
                            studio.doc = saved; studio.pushUndo(force: true); studio.doc = before.document
                            try checkHistoryRejection("InstantiateUndo", action: { studio.undo() })
                            // A successful undo records the rejected target as redo.
                            studio.pushUndo(force: true); studio.doc = saved; studio.undo()
                            try require("InstantiateRedoTargetPrepared", studio.doc.objects == before.document.objects
                                && studio.redoStack.last == saved && studio.sourcePluginSession != nil, studio.status)
                            try checkHistoryRejection("InstantiateRedo", action: { studio.redo() })
                        }
                        continue
                    }
                    record(name + "LoadOutcome", expectedLoadError == nil, "Loaded; " + summary(loaded))
                    record(name + "InputSceneCommitted", studio.doc.objects == saved.objects
                        && studio.doc.sourcePluginState == saved.sourcePluginState)
                    if pendingDestruction {
                        let original = try JSONDecoder().decode(InitializerObservation.self, from: Data(contentsOf: path(name + "-saved", ".json")))
                        record(name + "PendingQueueRestored", loaded.pending == original.pending,
                            "original pending=\(original.pending); restored pending=\(loaded.pending)")
                    }
                    let stepFrame = studio.host.renderer.currentFrame(), stepSession = studio.sourcePluginSession
                    var stepError: String?
                    do { try studio.stepSourcePlugins(deltaTime: 0.02) }
                    catch { stepError = outcome(error) }
                    let stepped = try snapshot(); try persist(stepped, name + "-stepped")
                    // Keep a real failed invariant if a freshly installable
                    // profile cannot step after reopen. Do not relabel it as a
                    // passing observation merely because the error was predicted.
                    record(name + "FirstStepSucceeds", stepError == nil, stepError ?? summary(stepped))
                    if stepError != nil {
                        record(name + "FailedStepRetainsLoadedState", stepped == loaded
                            && studio.sourcePluginSession === stepSession && sameFrame(stepFrame, studio.host.renderer.currentFrame()))
                    } else {
                        record(name + "ClockAdvanced", stepped.runtimeDocument?.sourcePluginState?.clock.elapsedTime
                            == (saved.sourcePluginState?.clock.elapsedTime ?? 0) + Double(Float(0.02)))
                        let freshSaved = try JSONDecoder().decode(InitializerObservation.self, from: Data(contentsOf: path(name + "-saved", ".json")))
                        let freshStepped = try JSONDecoder().decode(InitializerObservation.self, from: Data(contentsOf: path(name + "-fresh-stepped", ".json")))
                        if pendingDestruction {
                            record(name + "ObjectsMatchFresh", stepped.document.objects == freshStepped.document.objects,
                                "original objects=\(freshStepped.document.objects.map(\.id)); reopened objects=\(stepped.document.objects.map(\.id))")
                            record(name + "StateMatchesFresh", stepped.runtimeDocument?.sourcePluginState == freshStepped.runtimeDocument?.sourcePluginState,
                                "Exact saved fields, lifecycle flags, clocks, identities and clone serial")
                            record(name + "PendingMatchesFresh", stepped.pending == freshStepped.pending,
                                "original pending=\(freshStepped.pending); reopened pending=\(stepped.pending)")
                            let expected = Array(freshStepped.callbacks.dropFirst(freshSaved.callbacks.count))
                            let actual = Array(stepped.callbacks.dropFirst(loaded.callbacks.count))
                            record(name + "CallbacksMatchFresh", actual == expected,
                                "original callback suffix=\(expected); reopened suffix=\(actual)")
                        } else {
                            record(name + "MatchesFreshContinuation", stepped.document.objects == freshStepped.document.objects
                                && stepped.runtimeDocument?.sourcePluginState == freshStepped.runtimeDocument?.sourcePluginState
                                && stepped.pending == freshStepped.pending
                                && Array(stepped.callbacks.dropFirst(loaded.callbacks.count))
                                    == Array(freshStepped.callbacks.dropFirst(freshSaved.callbacks.count)),
                                "Compare original-session continuation after the same saved clock/state; callback suffixes exclude earlier installation events")
                        }
                    }
                    if name == "noop" {
                        record("NoopExactRestoredState", loaded.runtimeDocument?.sourcePluginState == saved.sourcePluginState
                            && loaded.world?.objects == saved.objects)
                    }
                    // Full snapshots retain SetActive visibility, pending Destroy
                    // and callback order as observations, without imposing a new
                    // restore policy on those existing semantics.
                }
                if pendingDestruction && validatePendingDestructionPolicy == true {
                    let source = try card("AwakeDestroy"), id = source.objects[0].id
                    let error = "Invalid saved pending destruction roots."
                    for (name, roots) in [("DuplicatePending", [id.uuidString, id.uuidString.lowercased()]),
                                          ("UnknownPending", [UUID().uuidString])] {
                        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
                        var state = json["sourcePluginState"] as! [String: Any]; state["pendingDestructionRoots"] = roots
                        json["sourcePluginState"] = state
                        let rejected = try JSONDecoder().decode(StudioDocument.self, from: JSONSerialization.data(withJSONObject: json))
                        let url = path(name, ".png")
                        guard !FileManager.default.fileExists(atPath: url.path) else {
                            throw SourcePluginError.invalid("Pending-root validation needs fresh artifacts.")
                        }
                        try CardIO.encode(rejected, keyword: CardIO.sceneKeyword, thumbnail: nil).write(to: url)
                        try studio.loadScene(from: path("noop", ".png")); try studio.stepSourcePlugins(deltaTime: 0.06)
                        let before = try snapshot(), session = studio.sourcePluginSession
                        let frame = studio.host.renderer.currentFrame(), adapter = studio.sourceFocus.adapter
                        let gain = studio.sourceAudioBus.masterVolume, observers = studio.sourceFocusObservers.count
                        let launchObserver = studio.sourceLaunchObserver != nil
                        try persist(before, name + "-before")
                        var reason = ""
                        do { try studio.loadScene(from: url) } catch { reason = outcome(error) }
                        try persist(snapshot(), name + "-after")
                        record(name + "ExactError", reason == "invalid: " + error, reason)
                        record(name + "RetainsPrior", try snapshot() == before && studio.sourcePluginSession === session
                            && studio.sourceFocus.adapter === adapter && studio.sourceAudioBus.masterVolume == gain
                            && studio.sourceFocusObservers.count == observers && (studio.sourceLaunchObserver != nil) == launchObserver
                            && !studio.sourcePluginsRunning && sameFrame(frame, studio.host.renderer.currentFrame()))
                        studio.doc = rejected; studio.pushUndo(force: true); studio.doc = before.document
                        try checkHistoryRejection(name + "Undo", expectedError: error, action: { studio.undo() })
                        studio.pushUndo(force: true); studio.doc = rejected; studio.undo()
                        try require(name + "RedoTargetPrepared", studio.doc.objects == before.document.objects
                            && studio.redoStack.last == rejected && studio.sourcePluginSession != nil, studio.status)
                        try checkHistoryRejection(name + "Redo", expectedError: error, action: { studio.redo() })
                    }
                }
            }
        } catch { record("initializerRestoreReproductionFailure", false, String(describing: error)) }
        studio.cancelSourcePluginLibraryMount(); await studio.sourcePluginLibraryPreparationQueue.drain()
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}

// Source-backed installation regression; the original failing report is retained
// separately. Both supported callbacks and rejected candidates use the real loader.
extension PluginLibraryScenario {
    /// Native restore acceptance; the original policy-rejection reports remain
    /// recorded separately. Durable profiles survive the save process; a second
    /// process invokes the ordinary native loader against a retained live scene.
    @MainActor private func reproduceNativeRestore(_ configuration: NativeProfileRestore,
                                                    app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = []
        func check(_ name: String, _ okay: Bool, _ detail: String = "") throws {
            rows.append(.init(op: name, ok: okay, detail: detail))
            if !okay { throw SourcePluginError.runtime("Native restore reproduction assertion failed: \(name)") }
        }
        func resources() -> [Int] {
            let s = studio.host.renderer.resources.statistics()
            return [s.meshes, s.textures, s.deformBuffers, s.hiddenBuffers,
                    s.meshBufferBytes, s.deformBufferBytes, s.hiddenBufferBytes, s.retiring]
        }
        func previews() -> Set<ObjectIdentifier> { Set(studio.renderedSourceCharacterPreviews.map(ObjectIdentifier.init)) }
        func sameFrame(_ a: RenderFrame, _ b: RenderFrame) -> Bool {
            a.camera == b.camera && a.mainLight == b.mainLight && a.effects == b.effects && a.lights == b.lights
                && a.sceneBounds == b.sceneBounds && a.time == b.time && a.skinSets == b.skinSets
                && a.gizmos.count == b.gizmos.count && a.items.count == b.items.count
                && zip(a.items, b.items).allSatisfy { $0.mesh == $1.mesh && $0.model == $1.model && $0.objectID == $1.objectID }
        }
        let directory = URL(fileURLWithPath: configuration.directory, isDirectory: true)
        func scene(_ name: String) -> URL { directory.appendingPathComponent(name + ".png") }
        func decoded(_ name: String) throws -> StudioDocument {
            try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: Data(contentsOf: scene(name)))
        }
        do {
            studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            switch configuration.phase {
            case .save:
                // Refuse stale fixture reuse: profile paths themselves are part
                // of the saved identity, so every pair owns one fresh directory.
                guard !FileManager.default.fileExists(atPath: directory.path),
                      let template = studio.doc.objects.first(where: { $0.sourceCharacter != nil }),
                      template.sourceCharacter?.attachmentCatalogFile != nil else {
                    throw SourcePluginError.invalid("Native restore save needs a fresh output directory and source character with attachments.")
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let sourceFile = studio.doc.sourceSceneFile, sourceSHA = studio.doc.sourceSceneSHA256
                for name in ["attachment", "plain", "changed"] {
                    studio.newScene()
                    var parent = template; parent.id = UUID(); parent.parent = nil; parent.visible = false
                    var child = StudioObject(name: "Saved attachment target", kind: .folder)
                    child.sourceObjectKey = 12; child.parent = parent.id; child.sourceAttachmentPoint = 17
                    var candidate = studio.doc
                    candidate.sourceSceneFile = sourceFile; candidate.sourceSceneSHA256 = sourceSHA
                    candidate.objects = [parent, child]; studio.doc = candidate
                    let profile = try freshProfileFixture(directory: directory.appendingPathComponent(name),
                        phase: "initializer", fail: false, attachmentRead: name == "attachment")
                    try check(name + "ColdBeforeMount", studio.sourceShapePreview(for: parent.id) == nil)
                    try studio.loadSourcePluginProfileInteractively(profileURL: profile,
                        expectedGeneration: studio.sourcePluginMountGeneration)
                    studio.sourcePluginsRunning = false
                    let state = studio.doc.sourcePluginState
                    try check(name + "FreshMount", state?.bindings.count == 1
                        && state?.bindings.first?.fields["position"] != nil
                        && state?.bindings.first?.fields["position"] == state?.bindings.first?.fields["positionAgain"]
                        && (studio.sourceShapePreview(for: parent.id) != nil) == (name == "attachment"),
                        "Real interactive fresh load; hidden initializer reads create one cached preview only for attachment profile")
                    try studio.stepSourcePlugins(deltaTime: 0.04)
                    let expected = try studio.sourcePluginSession!.savedDocument().sourcePluginState
                    try studio.saveScene(to: scene(name))
                    let saved = try decoded(name)
                    try check(name + "NativeSave", saved.sourcePluginState == expected
                        && saved.sourcePluginState?.clock.elapsedTime == Double(Float(0.04))
                        && saved.object(child.id)?.parent == parent.id
                        && saved.object(child.id)?.sourceAttachmentPoint == 17
                        && saved.object(parent.id)?.sourceCharacter == parent.sourceCharacter,
                        "Native card retains exact profile/package identities, fields, clock, bindings and source attachment")
                    if name == "changed" {
                        var bytes = try Data(contentsOf: profile); bytes.append(contentsOf: [0x20, 0x0a])
                        _ = try JSONSerialization.jsonObject(with: bytes)
                        try bytes.write(to: profile)
                        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                        try check("ChangedValidJSONIdentity", hash != saved.sourcePluginState?.profileSHA256,
                            "Only this dedicated control profile receives valid trailing JSON whitespace after native save")
                    }
                }
                try String(ProcessInfo.processInfo.processIdentifier).write(to: directory.appendingPathComponent("save-pid.txt"),
                    atomically: true, encoding: .utf8)
            case .reopen:
                let savePID = try String(contentsOf: directory.appendingPathComponent("save-pid.txt"), encoding: .utf8)
                try check("FreshProcessBoundary", savePID != String(ProcessInfo.processInfo.processIdentifier),
                    "save PID=\(savePID), reopen PID=\(ProcessInfo.processInfo.processIdentifier)")
                let request = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: requestFile))
                guard let binding = request.configuration.bindings.first, request.configuration.bindings.count == 1 else {
                    throw SourcePluginError.invalid("Native restore requires one unrelated retained library binding.")
                }
                // Keep the independently imported visible source scene so a
                // failed candidate must preserve real cached previews/resources.
                var target = StudioObject(name: "Retained unrelated plugin target", kind: .folder)
                target.sourceObjectKey = 987654
                studio.add(target)
                try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: .init(
                    fixedDeltaTime: request.configuration.fixedDeltaTime,
                    bindings: [.init(guid: binding.guid, type: binding.type, sourceObjectKey: 987654)]))
                studio.sourcePluginsRunning = false
                try studio.stepSourcePlugins(deltaTime: 0.06)
                try check("RetainedSessionPrecondition", studio.sourcePluginSession != nil && studio.sourceFocus.adapter != nil
                    && !previews().isEmpty && !studio.undoStack.isEmpty)
                for (name, expected) in [
                    ("changed", "Saved plugin profile or library bindings changed; explicit reinstallation is required.")] {
                    let document = studio.doc, session = studio.sourcePluginSession
                    let runtime = try session?.savedDocument(), adapter = studio.sourceFocus.adapter
                    let frame = studio.host.renderer.currentFrame(), beforeResources = resources(), beforePreviews = previews()
                    let undo = studio.undoStack, redo = studio.redoStack, status = studio.status, sceneURL = studio.sceneURL
                    let generation = studio.sourcePluginMountGeneration, time = studio.sourceAnimationTime
                    let gain = studio.sourceAudioBus.masterVolume, observers = studio.sourceFocusObservers.count
                    let launchObserver = studio.sourceLaunchObserver != nil, blocked = studio.resourceBlockedObjects
                    let diagnostics = studio.resourceDiagnostics
                    var rejection: String?
                    do { try studio.loadScene(from: scene(name)) }
                    catch SourcePluginError.invalid(let reason) { rejection = reason }
                    catch { rejection = "UNEXPECTED: \(error)" }
                    try check(name + "NativeReopenPolicy", rejection == expected, rejection ?? "Unexpectedly accepted")
                    let afterRuntime = try studio.sourcePluginSession?.savedDocument()
                    try check(name + "RejectedStateRetained", studio.doc == document && studio.sourcePluginSession === session
                        && afterRuntime == runtime && studio.sourceFocus.adapter === adapter
                        && studio.undoStack == undo && studio.redoStack == redo && studio.status == status && studio.sceneURL == sceneURL
                        && studio.sourcePluginMountGeneration == generation && studio.sourceAnimationTime == time
                        && studio.sourceAudioBus.masterVolume == gain && studio.sourceFocusObservers.count == observers
                        && (studio.sourceLaunchObserver != nil) == launchObserver && !studio.sourcePluginsRunning
                        && studio.resourceBlockedObjects == blocked && studio.resourceDiagnostics == diagnostics
                        && sameFrame(frame, studio.host.renderer.currentFrame()),
                        "Document/session/fields/clocks/adapters/history/status/scene URL/resource policy/frame unchanged")
                    try check(name + "RejectedResourcesRetained", resources() == beforeResources && previews() == beforePreviews,
                        "Resources before=\(beforeResources), after=\(resources()); observable cached preview identities unchanged")
                }
                let attached = try decoded("attachment")
                let parent = attached.objects.first { $0.sourceCharacter != nil }!
                try studio.loadScene(from: scene("attachment"))
                let restoredAttachment = try studio.sourcePluginSession?.savedDocument()
                let committedPreview = studio.sourceShapePreview(for: parent.id)
                try check("AttachmentNativeReopen", studio.doc.sourcePluginState == attached.sourcePluginState
                    && restoredAttachment?.sourcePluginState == attached.sourcePluginState
                    && committedPreview?.reference == parent.sourceCharacter && !studio.sourcePluginsRunning
                    && studio.sourceAnimationTime == 0,
                    "Fresh-process native restore preserves profile/package/field/clock/binding identities and transfers hidden preview")
                try studio.stepSourcePlugins(deltaTime: 0.02)
                try check("AttachmentNextStepReusesPreview", studio.sourceShapePreview(for: parent.id) === committedPreview
                    && studio.doc.sourcePluginState?.bindings == attached.sourcePluginState?.bindings
                    && studio.doc.sourcePluginState?.clock.elapsedTime == (attached.sourcePluginState?.clock.elapsedTime ?? 0) + Double(Float(0.02)))
                try verifyRestoreOwnership(studio: studio, saved: attached, directory: directory, record: check)
                let saved = try decoded("plain")
                try studio.loadScene(from: scene("plain"))
                let restored = try studio.sourcePluginSession?.savedDocument()
                try check("AttachmentFreeReopen", studio.doc.sourcePluginState == saved.sourcePluginState
                    && restored?.sourcePluginState == saved.sourcePluginState && !studio.sourcePluginsRunning,
                    "Existing attachment-free native restore succeeds with exact profile/package/field/clock/binding identities")
                try studio.stepSourcePlugins(deltaTime: 0.02)
                try check("AttachmentFreeNextStep", studio.doc.sourcePluginState?.clock.elapsedTime
                    == (saved.sourcePluginState?.clock.elapsedTime ?? 0) + Double(Float(0.02))
                    && studio.doc.sourcePluginState?.bindings == saved.sourcePluginState?.bindings,
                    "First resumed step advances clock while hidden target fields and lifecycle flags remain saved")
            }
        } catch { rows.append(.init(op: "nativeRestoreReproductionFailure", ok: false, detail: String(describing: error))) }
        studio.cancelSourcePluginLibraryMount(); await studio.sourcePluginLibraryPreparationQueue.drain()
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }

    /// Exercises the same context used by native open, with an independent
    /// matrix oracle: persisted fields alone cannot reveal a wrong initializer
    /// read because restoration replaces them after the initializer runs.
    @MainActor private func verifyRestoreOwnership(studio: StudioModel, saved: StudioDocument,
                                                   directory: URL, record: (String, Bool, String) throws -> Void) throws {
        func check(_ name: String, _ okay: Bool, _ detail: String = "") throws { try record(name, okay, detail) }
        func resources() -> [Int] {
            let s = studio.host.renderer.resources.statistics()
            return [s.meshes, s.textures, s.deformBuffers, s.hiddenBuffers,
                    s.meshBufferBytes, s.deformBufferBytes, s.hiddenBufferBytes, s.retiring]
        }
        func previews() -> Set<ObjectIdentifier> { Set(studio.renderedSourceCharacterPreviews.map(ObjectIdentifier.init)) }
        func frameData(_ frame: RenderFrame) -> [SIMD4<Float>] {
            frame.items.flatMap { [$0.model.columns.0, $0.model.columns.1, $0.model.columns.2, $0.model.columns.3] }
        }
        func difference(_ a: float4x4, _ b: float4x4) -> Float {
            (0..<4).flatMap { i in (0..<4).map { j in abs(a[i][j] - b[i][j]) } }.max() ?? 0
        }
        let parentIndex = saved.objects.firstIndex { $0.sourceCharacter != nil }!
        let original = saved.objects[parentIndex], reference = original.sourceCharacter!
        let child = saved.objects.first { $0.parent == original.id && $0.sourceAttachmentPoint != nil }!
        func changedReference(attachment: String? = nil, animation: String? = nil) -> SourceStudioCharacterReference {
            .init(sceneFile: reference.sceneFile, sceneSHA256: reference.sceneSHA256, rigFile: reference.rigFile,
                boneCatalogFile: reference.boneCatalogFile, objectKey: reference.objectKey, makerLibraryFile: reference.makerLibraryFile,
                attachmentCatalogFile: attachment ?? reference.attachmentCatalogFile,
                animationCatalogFile: animation ?? reference.animationCatalogFile, dynamicsFile: reference.dynamicsFile,
                handPatternsFile: reference.handPatternsFile, lookSettingsFile: reference.lookSettingsFile)
        }
        let alternateAttachment = directory.appendingPathComponent("same-bytes-attachments.json")
        try Data(contentsOf: URL(fileURLWithPath: reference.attachmentCatalogFile!)).write(to: alternateAttachment)
        let baseline = studio.sourceShapePreview(for: original.id)!
        try check("MultipleOutfitsPrecondition", baseline.outfitCount > 1)
        var candidate = saved, old = saved
        var body = baseline.savedBodyValues; body[0] = 0.85
        candidate.objects[parentIndex].sourceBodyValues = body
        let parent = candidate.objects[parentIndex]
        old.objects[parentIndex].sourceCharacter = changedReference(attachment: alternateAttachment.path)
        old.objects[parentIndex].sourceOutfit = (baseline.coordinate + 1) % baseline.outfitCount
        body[0] = 0.15; old.objects[parentIndex].sourceBodyValues = body; old.objects[parentIndex].visible = true
        studio.doc = old; try studio.setSourceAnimationTime(0.7)
        let warm = studio.sourceShapePreview(for: original.id)!
        let warmPose = try warm.editedPose(bodyValues: body, animationElapsed: 0.7), warmInputs = warm.sourceBodyValues
        let oracle = try SourceStudioCharacterPreview(reference: reference, resources: studio.host.renderer.resources, coordinate: parent.sourceOutfit)
        let point = child.sourceAttachmentPoint!
        func attachment(_ preview: SourceStudioCharacterPreview, _ object: StudioObject, _ time: Float) throws -> SourceStudioPluginWorld.AttachmentFrame {
            try (preview.attachmentMatrix(pointID: point, fkRotations: object.sourceFKRotations ?? [:],
                faceValues: object.sourceFaceValues, bodyValues: object.sourceBodyValues, ikTargets: object.sourceIKOverrides ?? [:],
                kinematics: object.sourceKinematics, animationState: object.sourceAnimation, animationElapsed: time),
                preview.attachmentRotation(pointID: point, fkRotations: object.sourceFKRotations ?? [:],
                faceValues: object.sourceFaceValues, bodyValues: object.sourceBodyValues, ikTargets: object.sourceIKOverrides ?? [:],
                kinematics: object.sourceKinematics, animationState: object.sourceAnimation, animationElapsed: time))
        }
        let expected = try attachment(oracle, parent, 0), oldFrame = try attachment(warm, old.objects[parentIndex], 0.7)
        try check("SameUUIDInputsDistinguish", difference(expected.matrix, oldFrame.matrix) > 0.0001
            && warm.reference != reference && warm.coordinate != oracle.coordinate,
            "One UUID, different reference/outfit/shape/clock; independent candidate and current matrices must differ")
        let counts = resources()
        let context = try StudioModel.PluginAttachmentRestorePreparation(studio: studio, document: candidate, blockedObjects: [], animationElapsed: 0)
        defer { context.abort() }
        let actual = try context.frame(child: child, parent: parent), afterFirst = resources()
        let again = try context.frame(child: child, parent: parent)
        try check("CandidateMatrixAndRepeat", difference(actual.matrix, expected.matrix) < 0.000001
            && actual.rotation.vector == expected.rotation.vector && actual.matrix == again.matrix && resources() == afterFirst
            && studio.sourceShapePreview(for: parent.id) === warm,
            "Production restore context uses candidate matrix/rotation; repeated reads reuse its private preview")
        var altered = parent; altered.sourceOutfit = warm.coordinate
        var mismatch = ""
        do { _ = try context.frame(child: child, parent: altered) }
        catch SourcePluginError.invalid(let reason) { mismatch = reason }
        try check("CandidateCoordinateGuard", mismatch == "Plugin attachment parent differs from the candidate reference or outfit.")
        context.abort()
        try check("CandidateAbortRetainsWarm", resources() == counts && studio.sourceShapePreview(for: parent.id) === warm
            && warm.sourceBodyValues == warmInputs
            && (try warm.editedPose(bodyValues: body, animationElapsed: 0.7)).localMatrices == warmPose.localMatrices,
            "Only candidate meshes/texture leases drop; old warm pose and resources remain")
        let blocked = try StudioModel.PluginAttachmentRestorePreparation(studio: studio, document: candidate,
            blockedObjects: [parent.id], animationElapsed: 0)
        defer { blocked.abort() }
        var blockedError = ""
        do { _ = try blocked.frame(child: child, parent: parent) }
        catch RigError.invalid(let reason) { blockedError = reason }
        blocked.abort()
        try check("CandidateBlockedOverridesWarm", blockedError.contains("unresolved resource reference")
            && resources() == counts && studio.sourceShapePreview(for: parent.id) === warm)

        func write(_ document: StudioDocument, _ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name + ".png")
            try CardIO.encode(document, keyword: CardIO.sceneKeyword, thumbnail: nil).write(to: url)
            return url
        }
        // A fixture with a later failing initializer still carries matching
        // profile/package pins. Its first position initializer must execute
        // through the real candidate resolver before the named Int32 error.
        let poisonProfile = try freshProfileFixture(directory: directory.appendingPathComponent("restore-poison"), phase: "initializer", fail: true)
        func pinnedFailure(_ profile: URL) throws -> StudioDocument {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as! [String: Any]
            var state = json["sourcePluginState"] as! [String: Any]
            let package = try SourcePluginPackage.load(url: profile.deletingLastPathComponent().appendingPathComponent("manifest.json"))
            state["profileFile"] = profile.path
            state["profileSHA256"] = SHA256.hash(data: try Data(contentsOf: profile)).map { String(format: "%02x", $0) }.joined()
            state["packages"] = [["guid": package.manifest.identity.guid,
                "manifestSHA256": SHA256.hash(data: package.manifestData).map { String(format: "%02x", $0) }.joined()]]
            json["sourcePluginState"] = state
            return try JSONDecoder().decode(StudioDocument.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let poison = try pinnedFailure(poisonProfile)
        let invalidCatalog = directory.appendingPathComponent("restore-invalid-animation.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "kind": "ikkoku-studio-animation-catalog",
            "catalogSHA256": String(repeating: "0", count: 64), "entries": []]).write(to: invalidCatalog)
        var partial = candidate; partial.objects[parentIndex].sourceCharacter = changedReference(animation: invalidCatalog.path)
        var missing = candidate; missing.objects[parentIndex].sourceCharacter = changedReference(attachment: directory.appendingPathComponent("absent-attachments.json").path)
        var failures: [(String, StudioDocument, String)] = [
            ("LateInitializer", poison, "Unsupported arithmetic operator or Int32 arithmetic."),
            ("PartialConstructor", partial, "Invalid or ambiguous Studio animation catalog."),
            ("MissingCandidateAsset", missing, "Character '\(parent.name)' has an unresolved resource reference; see the source compatibility details.")]
        // Preserving pending roots must not silently broaden #215's actual
        // attachment-read gate. This initializer reads successfully before the
        // existing policy rejects the live child's previously saved request.
        var queuedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as! [String: Any]
        var queuedState = queuedJSON["sourcePluginState"] as! [String: Any]
        queuedState["pendingDestructionRoots"] = [child.id.uuidString]; queuedJSON["sourcePluginState"] = queuedState
        let queued = try JSONDecoder().decode(StudioDocument.self, from: JSONSerialization.data(withJSONObject: queuedJSON))
        failures.append(("PendingAttachmentRead", queued,
            "Attachment-reading restoration cannot mutate the candidate scene, clone objects, or schedule destruction during initialization."))
        for mutation in ["Instantiate", "SetActive", "Destroy"] {
            let profile = try freshProfileFixture(directory: directory.appendingPathComponent("restore-" + mutation),
                phase: "initializer", fail: false, mutation: mutation)
            failures.append((mutation, try pinnedFailure(profile), mutation == "Instantiate"
                ? "Restoring plugin initialization changed scene object topology, identities, or clone state."
                : "Attachment-reading restoration cannot mutate the candidate scene, clone objects, or schedule destruction during initialization."))
        }
        for (name, rejected, expectedError) in failures {
            let url = try write(rejected, "reject-" + name)
            for attempt in 1...2 {
                let before = studio.doc, session = studio.sourcePluginSession, runtime = try session?.savedDocument()
                let undo = studio.undoStack, redo = studio.redoStack, beforeCounts = resources(), beforePreviews = previews()
                let frame = studio.host.renderer.currentFrame(), status = studio.status, clock = studio.sourceAnimationTime
                let adapter = studio.sourceFocus.adapter, gain = studio.sourceAudioBus.masterVolume
                var reason = ""
                do { try studio.loadScene(from: url) }
                catch SourcePluginError.runtime(let value) { reason = value }
                catch SourcePluginError.invalid(let value) { reason = value }
                catch RigError.invalid(let value) { reason = value }
                let afterRuntime = try studio.sourcePluginSession?.savedDocument()
                let afterFrame = studio.host.renderer.currentFrame()
                try check(name + "Rollback\(attempt)", reason == expectedError && studio.doc == before
                    && studio.sourcePluginSession === session && afterRuntime == runtime && studio.undoStack == undo && studio.redoStack == redo
                    && resources() == beforeCounts && previews() == beforePreviews && studio.sourceAnimationTime == clock
                    && studio.status == status && studio.sourceFocus.adapter === adapter && studio.sourceAudioBus.masterVolume == gain
                    && frame.camera == afterFrame.camera && frame.sceneBounds == afterFrame.sceneBounds && frame.time == afterFrame.time
                    && frame.skinSets == afterFrame.skinSets && frameData(frame) == frameData(afterFrame), reason)
            }
        }
        // Real history failures must leave their target at the top of the stack.
        studio.doc = poison; studio.pushUndo(force: true); studio.doc = old
        let historySession = studio.sourcePluginSession, historyResources = resources(), historyPreviews = previews()
        let undo = studio.undoStack, redo = studio.redoStack
        studio.undo(); studio.undo(); studio.redo()
        try check("FailedHistoryRetainsStacks", studio.doc == old && studio.sourcePluginSession === historySession
            && studio.undoStack == undo && studio.redoStack == redo && resources() == historyResources && previews() == historyPreviews
            && studio.status.contains("Unsupported arithmetic operator or Int32 arithmetic."), studio.status)
        // Put the valid target above the retained failing entry. Both directions
        // go through real candidate preparation; the held history clock survives.
        studio.doc = candidate; studio.pushUndo(force: true); studio.doc = old
        studio.undo()
        let historyPreview = studio.sourceShapePreview(for: parent.id)
        try check("HistoryCandidateSuccess", studio.doc.objects == candidate.objects && studio.sourceAnimationTime == 0.7
            && historyPreview?.reference == reference && historyPreview?.coordinate == oracle.coordinate && historyPreview !== warm
            && studio.doc.sourcePluginState == candidate.sourcePluginState, studio.status)
        studio.redo()
        try check("HistoryRedoSuccess", studio.doc.objects == old.objects && studio.sourceAnimationTime == 0.7
            && studio.sourceShapePreview(for: parent.id)?.reference == old.objects[parentIndex].sourceCharacter, studio.status)

        // A non-plugin native load establishes a blocked old UUID. A valid
        // candidate with that same UUID must use its own resolution and succeed.
        var blockedOld = missing; blockedOld.sourcePluginState = nil
        try studio.loadScene(from: write(blockedOld, "blocked-old"))
        try check("OldBlockedUUIDPrecondition", studio.resourceBlockedObjects.contains(parent.id))
        try studio.loadScene(from: write(candidate, "candidate-valid"))
        let committed = studio.sourceShapePreview(for: parent.id)
        try check("ValidCandidateOverridesOldBlock", !studio.resourceBlockedObjects.contains(parent.id)
            && committed?.reference == reference && committed?.coordinate == oracle.coordinate && studio.sourceAnimationTime == 0)
        studio.update(parent.id) { $0.visible = true }
        try studio.stepSourcePlugins(deltaTime: 0.02)
        try check("TransferredPreviewSurvivesShowAndStep", studio.sourceShapePreview(for: parent.id) === committed
            && studio.doc.sourcePluginState?.bindings.first?.awake == true && studio.doc.sourcePluginState?.bindings.first?.started == true)
    }

    @MainActor private func reproduceFreshLoad(app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = []
        func record(_ name: String, _ okay: Bool, _ detail: String = "") {
            rows.append(.init(op: name, ok: okay, detail: detail))
        }
        func resources() -> [Int] {
            let s = studio.host.renderer.resources.statistics()
            return [s.meshes, s.textures, s.deformBuffers, s.hiddenBuffers,
                    s.meshBufferBytes, s.deformBufferBytes, s.hiddenBufferBytes, s.retiring]
        }
        func previews() -> Set<ObjectIdentifier> { Set(studio.renderedSourceCharacterPreviews.map(ObjectIdentifier.init)) }
        func sameFrame(_ a: RenderFrame, _ b: RenderFrame) -> Bool {
            a.camera == b.camera && a.mainLight == b.mainLight && a.effects == b.effects && a.lights == b.lights
                && a.sceneBounds == b.sceneBounds && a.time == b.time && a.skinSets == b.skinSets
                && a.gizmos.count == b.gizmos.count && a.items.count == b.items.count
                && zip(a.items, b.items).allSatisfy { $0.mesh == $1.mesh && $0.model == $1.model && $0.objectID == $1.objectID }
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-fresh-profile-repro-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let request = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: requestFile))
            guard let template = studio.doc.objects.first(where: { $0.sourceCharacter != nil }),
                  let reference = template.sourceCharacter, reference.attachmentCatalogFile != nil,
                  let binding = request.configuration.bindings.first, request.configuration.bindings.count == 1 else {
                throw SourcePluginError.invalid("Fresh-profile reproduction requires one source character with attachment catalog and one old-session binding.")
            }
            let sourceFile = studio.doc.sourceSceneFile, sourceSHA = studio.doc.sourceSceneSHA256
            studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let brokenAnimation = scratch.appendingPathComponent("invalid-animation-catalog.json")
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "kind": "ikkoku-studio-animation-catalog",
                "catalogSHA256": String(repeating: "0", count: 64), "entries": []]).write(to: brokenAnimation)
            // Start is deferred until step(), not session construction. The
            // failure controls target initializers and active Awake instead.
            for (name, phase, hidden, fail) in [
                ("hiddenInitializerControl", "initializer", true, false),
                ("hiddenInitializerFailure", "initializer", true, true),
                ("activeAwakeFailure", "Awake", false, true),
                ("activeStartControl", "Start", false, false),
                ("warmShapeClockFailure", "Awake", false, true),
                ("hiddenPartialConstructorFailure", "initializer", true, true)] {
                studio.newScene()
                var parent = template; parent.id = UUID(); parent.parent = nil; parent.visible = !hidden
                let partial = name == "hiddenPartialConstructorFailure"
                if partial {
                    parent.sourceCharacter = .init(sceneFile: reference.sceneFile, sceneSHA256: reference.sceneSHA256,
                        rigFile: reference.rigFile, boneCatalogFile: reference.boneCatalogFile, objectKey: reference.objectKey,
                        makerLibraryFile: reference.makerLibraryFile, attachmentCatalogFile: reference.attachmentCatalogFile,
                        animationCatalogFile: brokenAnimation.path, dynamicsFile: reference.dynamicsFile,
                        handPatternsFile: reference.handPatternsFile, lookSettingsFile: reference.lookSettingsFile)
                }
                var child = StudioObject(name: "Attachment probe", kind: .folder)
                child.sourceObjectKey = 12; child.parent = parent.id; child.sourceAttachmentPoint = 17
                var target = StudioObject(name: "Retained session target", kind: .folder); target.sourceObjectKey = 11
                var scene = studio.doc
                scene.sourceSceneFile = sourceFile; scene.sourceSceneSHA256 = sourceSHA
                scene.objects = [parent, child, target]; studio.doc = scene
                let configuration = SourceStudioPluginConfiguration(fixedDeltaTime: request.configuration.fixedDeltaTime,
                    bindings: [.init(guid: binding.guid, type: binding.type, sourceObjectKey: 11)])
                try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration)
                studio.sourcePluginsRunning = false
                var warmPose: RigPose?, warmBody: [Float]?, warmFace: [Float]?, warmDiagnostics: [String]?
                let warmPreview = studio.sourceShapePreview(for: parent.id)
                if name == "warmShapeClockFailure", let preview = warmPreview {
                    var body = preview.savedBodyValues, face = preview.savedFaceValues
                    body[0] = body[0] < 0.5 ? 0.8 : 0.2; face[33] = face[33] < 0.5 ? 0.8 : 0.2
                    warmPose = try preview.editedPose(faceValues: face, bodyValues: body, animationElapsed: 0.7)
                    warmBody = body; warmFace = face; warmDiagnostics = preview.diagnostics
                }
                let beforeDoc = studio.doc, beforeSession = studio.sourcePluginSession
                let beforeRuntime = try beforeSession?.savedDocument(), beforeAdapter = studio.sourceFocus.adapter
                let beforeResources = resources(), beforePreviews = previews(), beforeFrame = studio.host.renderer.currentFrame()
                let beforeStatus = studio.status, beforeGeneration = studio.sourcePluginMountGeneration
                let beforeGain = studio.sourceAudioBus.masterVolume, beforeAnimation = studio.sourceAnimationTime
                let beforeObservers = studio.sourceFocusObservers.count, beforeLaunchObserver = studio.sourceLaunchObserver != nil
                record(name + "Precondition", beforeSession != nil && beforeAdapter != nil
                    && (studio.sourceShapePreview(for: parent.id) == nil) == hidden,
                    "hidden=\(hidden), cached previews=\(beforePreviews.count), resources=\(beforeResources)")
                let profile = try freshProfileFixture(directory: scratch.appendingPathComponent(name), phase: phase, fail: fail && !partial)
                var rejection: String?
                do { try studio.loadSourcePluginProfileInteractively(profileURL: profile, expectedGeneration: beforeGeneration) }
                catch SourcePluginError.runtime(let message) { rejection = message }
                catch RigError.invalid(let message) where partial { rejection = message }
                catch { rejection = "UNEXPECTED: \(error)" }
                if fail {
                    let expected = partial ? "Invalid or ambiguous Studio animation catalog." : "Unsupported arithmetic operator or Int32 arithmetic."
                    record(name + "NamedError", rejection == expected, rejection ?? "No error")
                    let afterRuntime = try studio.sourcePluginSession?.savedDocument()
                    record(name + "MountRetained", studio.doc == beforeDoc && studio.sourcePluginSession === beforeSession
                        && afterRuntime == beforeRuntime && studio.sourceFocus.adapter === beforeAdapter
                        && studio.status == beforeStatus && studio.sourcePluginMountGeneration == beforeGeneration
                        && !studio.sourcePluginsRunning && studio.sourceAudioBus.masterVolume == beforeGain
                        && studio.sourceAnimationTime == beforeAnimation && studio.sourceFocusObservers.count == beforeObservers
                        && (studio.sourceLaunchObserver != nil) == beforeLaunchObserver
                        && sameFrame(beforeFrame, studio.host.renderer.currentFrame()),
                        "Document/session/runtime fields+clocks/adapter/gain/status/generation/observers/frame retained")
                    let afterPreviews = previews(), afterResources = resources()
                    record(name + "HostRollback", beforePreviews == afterPreviews && beforeResources == afterResources,
                        "previews before=\(beforePreviews), after=\(afterPreviews); parent cached after=\(studio.sourceShapePreview(for: parent.id) != nil); resources before=\(beforeResources), after=\(afterResources)")
                    if hidden {
                        for attempt in 1...2 {
                            var repeatError: String?
                            do { try studio.loadSourcePluginProfileInteractively(profileURL: profile, expectedGeneration: beforeGeneration) }
                            catch SourcePluginError.runtime(let message) { repeatError = message }
                            catch RigError.invalid(let message) where partial { repeatError = message }
                            catch { repeatError = "UNEXPECTED: \(error)" }
                            let repeatRuntime = try studio.sourcePluginSession?.savedDocument()
                            record(name + "Repeat\(attempt)", repeatError == expected && resources() == beforeResources && previews() == beforePreviews
                                && studio.doc == beforeDoc && studio.sourcePluginSession === beforeSession
                                && repeatRuntime == beforeRuntime
                                && studio.status == beforeStatus && studio.sourcePluginMountGeneration == beforeGeneration
                                && sameFrame(beforeFrame, studio.host.renderer.currentFrame()), repeatError ?? "No error")
                        }
                    }
                    if let warmPose, let preview = warmPreview {
                        let inputsRestored = preview.sourceBodyValues == warmBody && preview.sourceFaceValues == warmFace
                            && preview.diagnostics == warmDiagnostics && studio.sourceShapePreview(for: parent.id) === preview
                        let resumed = try preview.editedPose(faceValues: warmFace, bodyValues: warmBody, animationElapsed: 0.7)
                        record("warmShapeClockRestored", inputsRestored && resumed.localMatrices == warmPose.localMatrices
                            && resources() == beforeResources, "Warm shape inputs, held-clock pose, identity and resources restored without rebuilding")
                    }
                } else {
                    record(name + "Mounted", rejection == nil && studio.sourcePluginSession !== beforeSession
                        && studio.sourceShapePreview(for: parent.id) != nil
                        && studio.doc.sourcePluginState?.bindings.first?.fields["position"] != nil,
                        rejection ?? "Supported attachment profile committed; reference point17 resolved")
                    let committedPreview = studio.sourceShapePreview(for: parent.id), committedResources = resources()
                    if phase == "Start" {
                        record("startDeferredUntilStep", studio.doc.sourcePluginState?.bindings.first?.started == false)
                        try studio.stepSourcePlugins(deltaTime: 0.02)
                        record("startAttachmentExecuted", studio.doc.sourcePluginState?.bindings.first?.started == true,
                               "Supported Start attachment read executed on first real step, after installation")
                    } else {
                        record("initializerRepeatedReadMatches", studio.doc.sourcePluginState?.bindings.first?.fields["position"]
                            == studio.doc.sourcePluginState?.bindings.first?.fields["positionAgain"])
                        try studio.stepSourcePlugins(deltaTime: 0.02)
                    }
                    record(name + "CommittedPreviewReused", studio.sourceShapePreview(for: parent.id) === committedPreview
                        && resources() == committedResources, "First real step retains the committed preview and resource vector")
                }
            }
            // The current IR marks Destroy pending until its step barrier, so
            // pruning before commit is a direct preparation-context control,
            // not a claim that installation runs the destruction barrier.
            studio.newScene()
            var parent = template; parent.id = UUID(); parent.parent = nil; parent.visible = false
            var child = StudioObject(name: "Pruned attachment probe", kind: .folder)
            child.parent = parent.id; child.sourceAttachmentPoint = 17
            let beforePrune = resources(), beforePrunePreviews = previews()
            let staged = StudioModel.PluginAttachmentPreparation(studio: studio)
            defer { staged.abort() }
            _ = try staged.frame(child: child, parent: parent)
            let afterFirstRead = resources()
            _ = try staged.frame(child: child, parent: parent)
            record("privateRepeatedRead", previews() == beforePrunePreviews && resources() == afterFirstRead,
                   "Two reads share a private preview without publishing it to the live cache")
            staged.commit(document: studio.doc) // Empty document excludes the candidate parent.
            let afterPrune = resources()
            record("prunedPreviewNotPublished", previews() == beforePrunePreviews
                && afterPrune[0] == beforePrune[0] && afterPrune[2] == beforePrune[2]
                && afterPrune[4] == beforePrune[4] && afterPrune[5] == beforePrune[5],
                "Mesh/deform ownership returned; successful base texture cache publication follows the appearance transaction contract")
        } catch { record("reproductionFailure", false, String(describing: error)) }
        studio.cancelSourcePluginLibraryMount(); await studio.sourcePluginLibraryPreparationQueue.drain()
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }

    private func freshProfileFixture(directory: URL, phase: String, fail: Bool, attachmentRead: Bool = true,
                                     mutation: String? = nil, destroyOnAwake: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let type = "FreshAttachmentProbe", guid = "Ikkoku.Validation.FreshAttachmentProbe"
        let hash = String(repeating: "a", count: 64)
        let read: [String: Any] = ["kind": "api", "type": "Vector3", "name": "position", "children": [
            ["kind": "api", "type": "Transform", "name": "transform", "children": []]]]
        let poison: [String: Any] = ["kind": "binary", "type": "Int32", "name": "+", "children": [
            ["kind": "literal", "type": "Int32", "value": 1], ["kind": "literal", "type": "Int32", "value": 1]]]
        let zero: [String: Any] = ["kind": "api", "type": "Vector3", "name": "vector.zero", "children": []]
        var fields: [[String: Any]] = [["name": "position", "type": "Vector3", "serialized": true,
                                       "initializer": phase == "initializer" && attachmentRead ? read : zero]]
        var body: [[String: Any]] = []
        if phase == "initializer" {
            fields.append(["name": "positionAgain", "type": "Vector3", "serialized": true, "initializer": attachmentRead ? read : zero])
            if fail { fields.append(["name": "trip", "type": "Int32", "serialized": false, "initializer": poison]) }
        } else {
            if attachmentRead {
                body.append(["kind": "assign", "name": "=", "children": [["kind": "field", "type": "Vector3", "name": "position"], read]])
            }
            if destroyOnAwake {
                precondition(phase == "Awake" && !fail && mutation == nil && !attachmentRead)
                body.append(["kind": "expression", "children": [["kind": "api", "type": "Void", "name": "world.Destroy", "children": [
                    ["kind": "api", "type": "Object", "name": "gameObject", "children": []]]]]])
            }
            if fail { body.append(["kind": "expression", "children": [poison]]) }
        }
        let lifecycle = phase == "initializer" ? "Awake" : phase
        var methods: [[String: Any]] = [["name": lifecycle, "symbol": "M:\(type).\(lifecycle)", "static": false,
            "returnType": "Void", "parameters": [], "body": ["kind": "block", "children": body], "lifecycle": lifecycle]]
        var symbols = ["M:\(type).\(lifecycle)"]
        if destroyOnAwake {
            symbols.append("M:\(type).OnDestroy")
            methods.append(["name": "OnDestroy", "symbol": "M:\(type).OnDestroy", "static": false,
                "returnType": "Void", "parameters": [], "body": ["kind": "block", "children": []], "lifecycle": "OnDestroy"])
        }
        if let mutation {
            precondition(phase == "initializer" && !fail)
            let object: [String: Any] = ["kind": "api", "type": "Object", "name": "gameObject", "children": []]
            let operation: [String: Any]
            switch mutation {
            case "Instantiate": operation = ["kind": "api", "type": "Object", "name": "world.Instantiate", "children": [object]]
            case "SetActive": operation = ["kind": "api", "type": "Void", "name": "setActive", "children": [object,
                ["kind": "literal", "type": "Bool", "value": false]]]
            case "Destroy": operation = ["kind": "api", "type": "Void", "name": "world.Destroy", "children": [object]]
            default: preconditionFailure("Unknown fixture mutation")
            }
            // With attachmentRead enabled, the first field has already read
            // an attachment. This second initializer mutates the candidate and
            // returns a serializable value so restoration can reach its policy.
            fields[1]["initializer"] = ["kind": "call", "type": "Vector3", "name": "Mutate", "children": []]
            symbols.append("M:\(type).Mutate")
            methods.append(["name": "Mutate", "symbol": "M:\(type).Mutate", "static": false,
                "returnType": "Vector3", "parameters": [], "body": ["kind": "block", "children": [
                    ["kind": "expression", "children": [operation]], ["kind": "return", "children": [zero]]]]])
        }
        let program: [String: Any] = ["schemaVersion": 1, "status": "ready", "mode": "component", "type": type,
            "source": ["sha256": hash], "identity": ["sourceSHA256": hash, "type": type,
                "symbols": symbols, "pluginGUID": guid],
            "semanticSurfaceSHA256": hash, "bridgeSHA256": hash, "emitterSHA256": hash,
            "fields": fields, "methods": methods]
        let bytes = try JSONSerialization.data(withJSONObject: program)
        _ = try SourceIRProgram.decode(bytes) // Structural rejection is not the intended failure.
        try bytes.write(to: directory.appendingPathComponent("program.json"))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "ikkoku-translated-plugin",
            "identity": ["guid": guid, "version": "1.0", "name": "Fresh profile failure reproduction"],
            "processes": ["CharaStudio"], "dependencies": [], "incompatibilities": [],
            "components": [["type": type, "program": ["file": "program.json", "sha256": digest]]]]
        let manifestURL = directory.appendingPathComponent("manifest.json"), profile = directory.appendingPathComponent("profile.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixedDeltaTime": 0.02,
            "packages": [["manifest": manifestURL.path, "bindings": [["type": type, "sourceObjectKey": 12]]]]]).write(to: profile)
        return profile
    }
}

// Same-owner notification lifetime checks. These run only in the optional
// scenario; ordinary mounts and frame processing have no new instrumentation.
extension PluginLibraryScenario {
    struct FocusObserverLifecycle: Decodable {
        let directory: String, profileFile: String, nativeManifest: String
        let enabledConfig: String, disabledConfig: String, invalidConfig: String, invalidManifest: String
        let cycles: Int
    }
    private struct FocusObservation: Codable, Equatable {
        let adapter: String?, enabled: Bool?, originalVolume: UInt32?
        let masterVolume: UInt32, voiceVolume: UInt32
        let observers: [String], launchObserver: String?, awaitingInitialFocus: Bool
        let session: String?, running: Bool
    }
    private struct FocusEvent: Codable {
        let name: String, focused: Bool?
        let state: FocusObservation
    }

    @MainActor private func verifyFocusObserverLifecycle(_ configuration: FocusObserverLifecycle,
                                                         app: AppState, studio: StudioModel) -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = [], events: [FocusEvent] = []
        let directory = URL(fileURLWithPath: configuration.directory, isDirectory: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Keep removed tokens alive: replacement identity cannot pass because
        // an allocator reused an address, and removal must work before deinit.
        var retiredTokens: [NSObjectProtocol] = []
        var retiredAdapters: [(SourceMuteInBackgroundPlugin, Bool)] = []
        func require(_ name: String, _ ok: Bool, _ detail: String = "") throws {
            rows.append(.init(op: name, ok: ok, detail: detail))
            if !ok { throw SourcePluginError.runtime("Focus observer assertion failed: \(name)") }
        }
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: directory.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func identity(_ value: AnyObject?) -> String? { value.map { String(describing: ObjectIdentifier($0)) } }
        func focus() -> FocusObservation {
            .init(adapter: identity(studio.sourceFocus.adapter), enabled: studio.sourceFocus.adapter?.enabled,
                originalVolume: studio.sourceFocus.adapter?.originalVolume?.bitPattern,
                masterVolume: studio.sourceAudioBus.masterVolume.bitPattern, voiceVolume: studio.sourceAudioBus.voiceVolume.bitPattern,
                observers: studio.sourceFocusObservers.map { identity($0 as AnyObject)! },
                launchObserver: identity(studio.sourceLaunchObserver.map { $0 as AnyObject }), awaitingInitialFocus: studio.sourceFocus.awaitingInitialFocus,
                session: identity(studio.sourcePluginSession), running: studio.sourcePluginsRunning)
        }
        func snapshot() throws -> InitializerObservation {
            let session = studio.sourcePluginSession, r = studio.host.renderer.resources.statistics()
            return .init(document: studio.doc, world: session?.world.document, runtimeDocument: try session?.savedDocument(),
                pending: session?.world.pendingSourceDestruction().map(\.sourceIdentity).sorted() ?? [],
                callbacks: session?.runtime.callbackTrace ?? [], resources: [r.meshes, r.textures, r.deformBuffers,
                    r.hiddenBuffers, r.meshBufferBytes, r.deformBufferBytes, r.hiddenBufferBytes, r.retiring],
                undo: studio.undoStack, redo: studio.redoStack, status: studio.status, sceneURL: studio.sceneURL,
                generation: studio.sourcePluginMountGeneration, animationTime: studio.sourceAnimationTime,
                blocked: studio.resourceBlockedObjects, diagnostics: studio.resourceDiagnostics)
        }
        func sameFrame(_ a: RenderFrame, _ b: RenderFrame) -> Bool {
            a.camera == b.camera && a.mainLight == b.mainLight && a.effects == b.effects && a.lights == b.lights
                && a.sceneBounds == b.sceneBounds && a.time == b.time && a.skinSets == b.skinSets
                && a.gizmos.count == b.gizmos.count && zip(a.gizmos, b.gizmos).allSatisfy { x, y in
                    x.primitive == y.primitive && x.model == y.model && x.depthTest == y.depthTest && x.objectID == y.objectID
                        && x.vertices.count == y.vertices.count
                        && zip(x.vertices, y.vertices).allSatisfy { $0.position == $1.position && $0.color == $1.color }
                }
                && a.items.count == b.items.count && zip(a.items, b.items).allSatisfy { x, y in
                    x.mesh == y.mesh && x.material == y.material && x.model == y.model && x.objectID == y.objectID
                        && x.deformKey == y.deformKey && x.skinSet == y.skinSet && x.castsShadow == y.castsShadow
                        && x.outline == y.outline && x.outlineScale == y.outlineScale && x.visible == y.visible
                        && x.hiddenRegions == y.hiddenRegions && x.hiddenKey == y.hiddenKey && x.order == y.order
                        && x.sourceShader == nil && y.sourceShader == nil && x.morphWeights.count == y.morphWeights.count
                        && zip(x.morphWeights, y.morphWeights).allSatisfy { $0.index == $1.index && $0.weight == $1.weight }
                }
        }
        let volume: Float = 0.75, voice: Float = 0.5
        func post(_ name: String, _ focused: Bool, master: Float, original: Float?) throws {
            let before = try snapshot(), owner = studio.sourceFocus.adapter, session = studio.sourcePluginSession
            let tokens = studio.sourceFocusObservers, frame = studio.host.renderer.currentFrame()
            NotificationCenter.default.post(name: focused ? NSApplication.didBecomeActiveNotification
                : NSApplication.didResignActiveNotification, object: nil)
            let after = try snapshot(), current = focus()
            events.append(.init(name: name, focused: focused, state: current))
            try require(name, before == after && studio.sourceFocus.adapter === owner && studio.sourcePluginSession === session
                && tokens.count == studio.sourceFocusObservers.count
                && zip(tokens, studio.sourceFocusObservers).allSatisfy { $0 === $1 }
                && current.masterVolume == master.bitPattern && current.voiceVolume == voice.bitPattern
                && current.originalVolume == original?.bitPattern && !current.awaitingInitialFocus && current.launchObserver == nil
                && retiredAdapters.allSatisfy { $0.0.originalVolume == nil && $0.0.enabled == $0.1 }
                && sameFrame(frame, studio.host.renderer.currentFrame()),
                "Actual AppKit notification post; exact document/runtime/history/clock/resources, owner/tokens and public toon-frame fields retained")
        }
        func replace(_ name: String, config: String, enabled: Bool) throws {
            let before = try snapshot(), frame = studio.host.renderer.currentFrame()
            guard let old = studio.sourceFocus.adapter else { throw SourcePluginError.invalid("Replacement needs a current focus owner.") }
            let tokens = studio.sourceFocusObservers
            try studio.configureSourceMutePlugin(configURL: URL(fileURLWithPath: config))
            retiredAdapters.append((old, old.enabled)); retiredTokens += tokens
            // Success may perform the legitimate initial focus sample immediately.
            // Record it, then settle via actual gain without overwriting bus gain.
            events.append(.init(name: name + "Mounted", focused: nil, state: focus()))
            try post(name + "Settled", true, master: volume, original: nil)
            // configure changes only the status outside focus/audio ownership.
            let expected = InitializerObservation(document: before.document, world: before.world, runtimeDocument: before.runtimeDocument,
                pending: before.pending, callbacks: before.callbacks, resources: before.resources,
                undo: before.undo, redo: before.redo, status: "Loaded \(SourceMuteInBackgroundPlugin.guid) \(SourceMuteInBackgroundPlugin.version)",
                sceneURL: before.sceneURL, generation: before.generation, animationTime: before.animationTime,
                blocked: before.blocked, diagnostics: before.diagnostics)
            let after = try snapshot()
            try require(name + "Ownership", after == expected && studio.sourceFocus.adapter !== old
                && studio.sourceFocus.adapter?.enabled == enabled && studio.sourceFocusObservers.count == 2
                && studio.sourceFocusObservers.allSatisfy { token in !retiredTokens.contains { $0 === token } }
                && old.originalVolume == nil && sameFrame(frame, studio.host.renderer.currentFrame()),
                "Removed token objects retained by regression; new pair distinct; old adapter restored before replacement")
        }
        func reject(_ name: String, expectedError: String, operation: () throws -> Void) throws {
            let before = try snapshot(), focusBefore = focus(), frame = studio.host.renderer.currentFrame()
            // Retain the objects, not only their printable addresses.
            let adapter = studio.sourceFocus.adapter, tokens = studio.sourceFocusObservers, launch = studio.sourceLaunchObserver
            let session = studio.sourcePluginSession
            try persist(before, name + "-before"); try persist(focusBefore, name + "-focus-before")
            var rejection: String?
            do { try operation() }
            catch SourcePluginError.invalid(let reason) { rejection = reason }
            catch { rejection = "UNEXPECTED: \(error)" }
            let after = try snapshot(), focusAfter = focus()
            try persist(after, name + "-after"); try persist(focusAfter, name + "-focus-after")
            try require(name + "Error", rejection == expectedError, rejection ?? "No rejection")
            try require(name + "Retained", before == after && focusBefore == focusAfter
                && studio.sourceFocus.adapter === adapter && studio.sourcePluginSession === session
                && studio.sourceLaunchObserver === launch && tokens.count == studio.sourceFocusObservers.count
                && zip(tokens, studio.sourceFocusObservers).allSatisfy { $0 === $1 }
                && sameFrame(frame, studio.host.renderer.currentFrame()),
                "Muted current owner, saved volume, token identities, session, full state and frame survive rejected replacement")
        }
        func unload(_ name: String) throws {
            let before = try snapshot(), frame = studio.host.renderer.currentFrame()
            guard let old = studio.sourceFocus.adapter else { throw SourcePluginError.invalid("Unload needs a current focus owner.") }
            retiredAdapters.append((old, old.enabled)); retiredTokens += studio.sourceFocusObservers
            var expectedDocument = before.document
            expectedDocument.sourcePluginLibrary = nil; expectedDocument.sourcePluginLibraryConfiguration = nil
            expectedDocument.sourcePluginState = nil; expectedDocument.sourceNativePlugins = nil
            studio.unloadSourcePluginsInteractively()
            let after = try snapshot(); events.append(.init(name: name, focused: nil, state: focus()))
            try require(name, studio.doc == expectedDocument && studio.sourcePluginSession == nil && !studio.sourcePluginsRunning
                && studio.sourceFocus.adapter == nil && studio.sourceFocusObservers.isEmpty && studio.sourceLaunchObserver == nil
                && !studio.sourceFocus.awaitingInitialFocus && old.originalVolume == nil
                && studio.sourceAudioBus.masterVolume == volume && studio.sourceAudioBus.voiceVolume == voice
                && after.resources == before.resources && after.animationTime == before.animationTime
                && after.undo == Array((before.undo + [before.document]).suffix(60)) && after.redo.isEmpty
                && after.blocked == before.blocked && after.diagnostics == before.diagnostics
                && sameFrame(frame, studio.host.renderer.currentFrame()),
                "Interactive unload clears only plugin metadata/session, records undo and restores the muted owner's gain")
            try post(name + "InertLoss", false, master: volume, original: nil)
            try post(name + "InertGain", true, master: volume, original: nil)
        }
        do {
            guard (1...16).contains(configuration.cycles), !FileManager.default.fileExists(atPath: directory.path) else {
                throw SourcePluginError.invalid("Focus lifecycle needs 1...16 cycles and a fresh output directory.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false
            try require("focusFixture", studio.doc.objects.contains { $0.sourceObjectKey == 10 && $0.sourceCharacter != nil }
                && !studio.host.renderer.currentFrame().items.isEmpty
                && studio.host.renderer.currentFrame().items.allSatisfy { $0.sourceShader == nil }
                && studio.sourceFocus.adapter == nil && studio.sourceFocusObservers.isEmpty && studio.sourceLaunchObserver == nil)
            try studio.loadSourcePluginProfileInteractively(profileURL: URL(fileURLWithPath: configuration.profileFile),
                expectedGeneration: studio.sourcePluginMountGeneration)
            try studio.loadSourceNativePlugin(url: URL(fileURLWithPath: configuration.nativeManifest))
            for _ in 0..<3 { try studio.stepSourcePlugins(deltaTime: 0.02) }
            studio.sourcePluginsRunning = false
            studio.sourceAudioBus.masterVolume = volume; studio.sourceAudioBus.voiceVolume = voice
            try require("disabledPackageMounted", studio.sourcePluginSession != nil && studio.doc.sourcePluginState != nil
                && studio.doc.sourceNativePlugins?.count == 1 && studio.sourceFocus.adapter?.enabled == false
                && studio.sourceFocusObservers.count == 2, "Exact package's installed setting is independently pinned false")
            try persist(snapshot(), "installed"); events.append(.init(name: "installed", focused: nil, state: focus()))
            try post("disabledLoss", false, master: volume, original: nil)
            try post("disabledGain", true, master: volume, original: nil)
            try replace("enabled", config: configuration.enabledConfig, enabled: true)
            try post("singleLoss", false, master: 0, original: volume)
            try post("singleGain", true, master: volume, original: nil)
            try post("repeatLossFirst", false, master: 0, original: volume)
            try post("repeatLossSecond", false, master: 0, original: 0)
            try post("repeatLossGain", true, master: 0, original: nil)
            // Explicit source-quirk control ended at zero. Reset only this control's input.
            studio.sourceAudioBus.masterVolume = volume
            for cycle in 1...configuration.cycles {
                try post("replace\(cycle)Loss", false, master: 0, original: volume)
                try replace("replace\(cycle)", config: configuration.enabledConfig, enabled: true)
                try post("replace\(cycle)CanaryLoss", false, master: 0, original: volume)
                try post("replace\(cycle)CanaryGain", true, master: volume, original: nil)
            }
            try post("disableOldLoss", false, master: 0, original: volume)
            try replace("disabled", config: configuration.disabledConfig, enabled: false)
            try post("disabledReplacementLoss", false, master: volume, original: nil)
            try post("disabledReplacementGain", true, master: volume, original: nil)
            try replace("reenabled", config: configuration.enabledConfig, enabled: true)
            try post("failureLoss", false, master: 0, original: volume)
            try reject("invalidConfig", expectedError: "Invalid BepInEx configuration section or key.") {
                try studio.configureSourceMutePlugin(configURL: URL(fileURLWithPath: configuration.invalidConfig))
            }
            try reject("invalidPackage", expectedError: "Native adapter source or configuration hash changed.") {
                try studio.loadSourceNativePlugin(url: URL(fileURLWithPath: configuration.invalidManifest))
            }
            try post("failedReplacementGain", true, master: volume, original: nil)
            for cycle in 1...configuration.cycles {
                try post("unload\(cycle)Loss", false, master: 0, original: volume)
                try unload("unload\(cycle)")
                try studio.loadSourceNativePlugin(url: URL(fileURLWithPath: configuration.nativeManifest))
                try replace("remount\(cycle)", config: configuration.enabledConfig, enabled: true)
                try post("remount\(cycle)CanaryLoss", false, master: 0, original: volume)
                try post("remount\(cycle)CanaryGain", true, master: volume, original: nil)
            }
            try post("finalLoss", false, master: 0, original: volume)
            try unload("finalUnload")
            try persist(snapshot(), "finished")
        } catch { rows.append(.init(op: "focusLifecycleFailure", ok: false, detail: String(describing: error))) }
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try persist(events, "notification-events") }
            catch { rows.append(.init(op: "focusEvidenceFailure", ok: false, detail: String(describing: error))) }
        }
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}

// Reproduction only: disposal is deliberately distinct from explicit unload.
// Weak probes cannot keep the model, adapter or observer tokens alive.
extension PluginLibraryScenario {
    struct FocusOwnerLifetime: Decodable {
        let directory: String, nativeManifest: String, enabledConfig: String, disabledConfig: String
        let cycles: Int
    }
    private final class FocusWeakObject {
        weak var value: AnyObject?
        let identity: String
        init(_ value: AnyObject) {
            self.value = value; identity = String(describing: ObjectIdentifier(value))
        }
    }
    private struct FocusOwnerProbes {
        let owner: FocusWeakObject, focusHost: FocusWeakObject, audioBus: FocusWeakObject
        let adapter: FocusWeakObject?
        let tokens: [FocusWeakObject]
        let events: [FocusOwnerEvent]
    }
    private struct FocusOwnerEvent: Codable {
        let phase: String
        let state: DirectGraphObservation
    }
    private struct FocusOwnerLiveness: Codable {
        let owner: String, focusHost: String, audioBus: String, adapter: String?
        let tokens: [String]
        let ownerAlive: Bool, focusHostAlive: Bool, audioBusAlive: Bool, adapterAlive: Bool
        let tokensAlive: [Bool]
        var ownersReleased: Bool { !ownerAlive && !focusHostAlive && !audioBusAlive && !adapterAlive }
        var tokensReleased: Bool { !tokensAlive.contains(true) }
    }
    private struct FocusDisposalObservation: Codable {
        let phase: String
        let explicitUnload: Bool, enabled: Bool
        let liveness: FocusOwnerLiveness
        let retainedTokensAcrossDisposedOwners: Int
    }

    @MainActor private func focusOwnerProbes(_ owner: StudioModel, events: [FocusOwnerEvent] = []) -> FocusOwnerProbes {
        .init(owner: .init(owner), focusHost: .init(owner.sourceFocus), audioBus: .init(owner.sourceAudioBus),
              adapter: owner.sourceFocus.adapter.map { .init($0) },
              tokens: owner.sourceFocusObservers.map { .init($0 as AnyObject) }, events: events)
    }

    // Returning only values prevents a weak read's temporary strong reference
    // from crossing the observation boundary into later exact-token cleanup.
    @inline(never) @MainActor private func focusOwnerLiveness(_ probes: FocusOwnerProbes) -> FocusOwnerLiveness {
        autoreleasepool {
            .init(owner: probes.owner.identity, focusHost: probes.focusHost.identity, audioBus: probes.audioBus.identity,
                  adapter: probes.adapter?.identity, tokens: probes.tokens.map(\.identity),
                  ownerAlive: probes.owner.value != nil, focusHostAlive: probes.focusHost.value != nil,
                  audioBusAlive: probes.audioBus.value != nil, adapterAlive: probes.adapter?.value != nil,
                  tokensAlive: probes.tokens.map { $0.value != nil })
        }
    }

    @inline(never) @MainActor private func removeFocusOwnerTokens(_ probes: [FocusOwnerProbes]) {
        autoreleasepool {
            for probe in probes {
                for weakToken in probe.tokens {
                    if let token = weakToken.value { NotificationCenter.default.removeObserver(token) }
                }
            }
        }
    }

    @inline(never) @MainActor private func makeDisposedFocusOwner(
        host: EngineHost, configuration: FocusOwnerLifetime, mount: Bool, enabled: Bool, explicitUnload: Bool
    ) throws -> FocusOwnerProbes {
        try autoreleasepool {
            let owner = StudioModel(host: host)
            owner.stopBenchmarkTimer(); owner.liveAnimation = false; owner.isActiveMode = true
            var completed = false
            // Infrastructure failures must not strand a partially mounted owner.
            // A completed disposal experiment intentionally keeps the registration.
            defer { if !completed { owner.mountSourceFocusAdapter(nil) } }
            guard mount else { completed = true; return focusOwnerProbes(owner) }
            try owner.loadSourceNativePlugin(url: URL(fileURLWithPath: configuration.nativeManifest))
            try owner.configureSourceMutePlugin(configURL: URL(fileURLWithPath:
                enabled ? configuration.enabledConfig : configuration.disabledConfig))
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            guard owner.sourceFocus.adapter?.enabled == enabled, owner.sourceFocusObservers.count == 2,
                  owner.sourceLaunchObserver == nil, !owner.sourceFocus.awaitingInitialFocus else {
                throw SourcePluginError.runtime("Owner lifetime requires a settled actual focus observer pair.")
            }
            owner.sourceAudioBus.masterVolume = 0.75; owner.sourceAudioBus.voiceVolume = 0.5
            let before = try directGraphSnapshot(studio: owner)
            let beforeFrame = try directGraphFrameBytes(host.renderer.currentFrame())
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
            let loss = try directGraphSnapshot(studio: owner)
            let expectedGain: Float = enabled ? 0 : 0.75
            let expectedOriginal: UInt32? = enabled ? Float(0.75).bitPattern : nil
            guard loss.state == before.state, loss.focus.masterVolume == expectedGain.bitPattern,
                  loss.focus.originalVolume == expectedOriginal, loss.focus.voiceVolume == Float(0.5).bitPattern else {
                throw SourcePluginError.runtime("Owner lifetime focus-loss control did not match the requested setting.")
            }
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            let gain = try directGraphSnapshot(studio: owner)
            guard gain == before, try directGraphFrameBytes(host.renderer.currentFrame()) == beforeFrame else {
                throw SourcePluginError.runtime("Owner lifetime single-delivery focus control changed state or frame.")
            }
            var events = [FocusOwnerEvent(phase: "settled", state: before),
                          .init(phase: "loss", state: loss), .init(phase: "gain", state: gain)]
            let weakOwner = focusOwnerProbes(owner)
            if explicitUnload {
                owner.unloadSourcePluginsInteractively()
                guard owner.sourceFocus.adapter == nil, owner.sourceFocusObservers.isEmpty,
                      owner.sourceLaunchObserver == nil, owner.doc.sourceNativePlugins == nil else {
                    throw SourcePluginError.runtime("Owner lifetime explicit unload did not remove its mounted state.")
                }
                events.append(.init(phase: "unloaded", state: try directGraphSnapshot(studio: owner)))
            }
            completed = true
            return .init(owner: weakOwner.owner, focusHost: weakOwner.focusHost, audioBus: weakOwner.audioBus,
                         adapter: weakOwner.adapter, tokens: weakOwner.tokens, events: events)
        }
    }

    @MainActor private func reproduceFocusOwnerLifetime(_ configuration: FocusOwnerLifetime,
                                                        app: AppState, studio: StudioModel) -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = [], observations: [FocusDisposalObservation] = []
        var probes: [FocusOwnerProbes] = []
        var control: StudioModel?
        let directory = URL(fileURLWithPath: configuration.directory, isDirectory: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func record(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append(.init(op: name, ok: ok, detail: detail))
        }
        func require(_ name: String, _ ok: Bool, _ detail: String = "") throws {
            record(name, ok, detail)
            if !ok { throw SourcePluginError.runtime("Owner lifetime control is inconclusive: \(name)") }
        }
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: directory.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func retainedTokens() -> Int {
            probes.reduce(0) { $0 + focusOwnerLiveness($1).tokensAlive.filter { $0 }.count }
        }
        defer {
            // Only exact tokens created by this diagnostic; never a global removal.
            removeFocusOwnerTokens(probes)
            control?.unloadSourcePluginsInteractively(); control?.stopBenchmarkTimer(); control = nil
            studio.refresh()
        }
        do {
            guard (1...8).contains(configuration.cycles), !FileManager.default.fileExists(atPath: directory.path) else {
                throw SourcePluginError.invalid("Owner lifetime needs 1...8 cycles and a fresh output directory.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false; studio.showGizmos = false; studio.showTimeline = false
            try studio.setSourceAnimationTime(0.25)
            try require("ownerFixture", studio.doc.objects.contains { $0.sourceObjectKey == 10 && $0.sourceCharacter != nil }
                && !studio.host.renderer.currentFrame().items.isEmpty
                && studio.host.renderer.currentFrame().items.allSatisfy { $0.sourceShader == nil }
                && studio.sourceFocus.adapter == nil && studio.sourceFocusObservers.isEmpty && studio.sourceLaunchObserver == nil)
            let package = try SourceNativePluginPackage.load(url: URL(fileURLWithPath: configuration.nativeManifest))
            let enabled = try SourceMuteInBackgroundPlugin.readConfiguration(Data(contentsOf: URL(fileURLWithPath: configuration.enabledConfig)))
            let disabled = try SourceMuteInBackgroundPlugin.readConfiguration(Data(contentsOf: URL(fileURLWithPath: configuration.disabledConfig)))
            try require("ownerExactInputs", package.manifest.adapterID == SourceNativePluginPackage.muteAdapter
                && package.manifest.identity.guid == SourceMuteInBackgroundPlugin.guid
                && package.manifest.identity.version == SourceMuteInBackgroundPlugin.version && enabled && !disabled)
            let original = try directGraphSnapshot(studio: studio)
            let originalFrame = try directGraphFrameBytes(studio.host.renderer.currentFrame())
            try persist(original, "original-state")
            try originalFrame.write(to: directory.appendingPathComponent("original-frame.json"), options: .withoutOverwriting)
            let plain = try makeDisposedFocusOwner(host: studio.host, configuration: configuration,
                mount: false, enabled: false, explicitUnload: false)
            let plainLiveness = focusOwnerLiveness(plain)
            try persist(plainLiveness, "plain-owner")
            try require("plainOwnerReleased", plainLiveness.ownersReleased)
            try require("plainOwnerHasNoTokens", plainLiveness.tokens.isEmpty)

            control = StudioModel(host: studio.host)
            control!.stopBenchmarkTimer(); control!.liveAnimation = false; control!.isActiveMode = true
            try control!.loadSourceNativePlugin(url: URL(fileURLWithPath: configuration.nativeManifest))
            try control!.configureSourceMutePlugin(configURL: URL(fileURLWithPath: configuration.enabledConfig))
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            control!.sourceAudioBus.masterVolume = 0.75; control!.sourceAudioBus.voiceVolume = 0.5
            try require("liveControlMounted", control!.sourceFocusObservers.count == 2
                && control!.sourceFocus.adapter?.enabled == true && control!.sourceLaunchObserver == nil)
            let liveBaseline = try directGraphSnapshot(studio: control!)
            let controlProbes = focusOwnerProbes(control!)
            for explicitUnload in [true, false] {
                for cycle in 1...configuration.cycles {
                    let name = "\(explicitUnload ? "unload" : "dispose")\(cycle)"
                    let expectedEnabled = cycle % 2 == 1
                    let probe = try makeDisposedFocusOwner(host: studio.host, configuration: configuration,
                        mount: true, enabled: expectedEnabled, explicitUnload: explicitUnload)
                    probes.append(probe)
                    let liveness = focusOwnerLiveness(probe)
                    let observation = FocusDisposalObservation(phase: name, explicitUnload: explicitUnload,
                        enabled: expectedEnabled, liveness: liveness, retainedTokensAcrossDisposedOwners: retainedTokens())
                    observations.append(observation)
                    try persist(probe.events, name + "-events"); try persist(observation, name + "-released")
                    try require(name + "OwnerReleased", liveness.ownersReleased,
                        "No token-retention inference until the weak owner, focus host, adapter and bus have released")
                    if explicitUnload {
                        try require(name + "TokensReleased", liveness.tokensReleased,
                            "Explicit unload is the independent token-release control")
                    } else {
                        record(name + "TokensReleased", liveness.tokensReleased,
                            "Observed after owner release and before later notifications or exact-token cleanup")
                    }
                    try require(name + "LiveOwnerUnchanged", try directGraphSnapshot(studio: control!) == liveBaseline)
                }
            }
            // Preserve all red disposal observations before the differential cleanup.
            try persist(observations, "before-cleanup")
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
            let controlLoss = try directGraphSnapshot(studio: control!)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            let controlGain = try directGraphSnapshot(studio: control!)
            try persist([FocusOwnerEvent(phase: "loss", state: controlLoss), .init(phase: "gain", state: controlGain)],
                        "after-disposal-notifications")
            try persist(probes.map { focusOwnerLiveness($0) }, "after-notifications-liveness")
            try require("disposedNotificationsLiveControl", controlLoss.state == liveBaseline.state
                && controlLoss.focus.masterVolume == Float(0).bitPattern
                && controlLoss.focus.originalVolume == Float(0.75).bitPattern && controlGain == liveBaseline)
            removeFocusOwnerTokens(probes)
            let cleaned = probes.map { focusOwnerLiveness($0) }
            try persist(cleaned, "after-exact-token-removal")
            try require("exactTokenRemovalReleasedTokens", cleaned.allSatisfy(\.tokensReleased))
            try require("exactTokenRemovalOwnersStillReleased", cleaned.allSatisfy(\.ownersReleased))
            control!.unloadSourcePluginsInteractively(); control!.stopBenchmarkTimer(); control = nil
            let controlReleased = focusOwnerLiveness(controlProbes)
            try persist(controlReleased, "live-control-disposed")
            try require("liveControlReleased", controlReleased.ownersReleased && controlReleased.tokensReleased)
            studio.refresh()
            let final = try directGraphSnapshot(studio: studio)
            let finalFrame = try directGraphFrameBytes(studio.host.renderer.currentFrame())
            try persist(final, "final-state")
            try finalFrame.write(to: directory.appendingPathComponent("final-frame.json"), options: .withoutOverwriting)
            try require("originalOwnerStateRetained", final == original)
            try require("originalOwnerFrameRestored", finalFrame == originalFrame)
        } catch { record("ownerLifetimeFailure", false, String(describing: error)) }
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}

// Optional model-boundary diagnostics. Timers and consumers never run in the
// ordinary frame path; Release call-site inspection is a separate acceptance gate.
extension PluginLibraryScenario {
    struct RouteCheckpointCost: Decodable {
        let directory: String
        let routeKey: Int32, childKey: Int32
        let captureFirst: Bool
        let batches: Int, iterations: Int, frames: Int
    }
    private struct RouteCostBatch: Encodable {
        let captureSeconds: Double, consumerSeconds: Double
        let captureChecksum: UInt64, consumerChecksum: UInt64
        let captureFirst: Bool
    }
    private struct RouteCostHistory: Encodable {
        let prefixSteps: Int, prefixTime: Float
        let ordinaryCharacterCheckpoints: Int, routeClocks: Int
        let sourceCharacterRecords: Int, renderedCharacterObjects: Int, drawItems: Int
        let routePoints: Int, routeSegments: Int
        let routeAction: String
        let batches: [RouteCostBatch]
        let frameSeconds: [Double], frameBatchSecondsIncludingSampling: Double
    }
    private struct RouteCostReport: Encodable {
        let scope: String, pid: Int32, sourceSceneSHA256: String
        let iterations: Int, histories: [RouteCostHistory]
    }

    // Keep capture and consumption as distinct calls. The salt makes each
    // consumer result observable; the accepted Release disassembly must also
    // show capture inside the loop, rather than assuming attributes suffice.
    @inline(never) @MainActor private func routeCostCapture(_ studio: StudioModel) -> StudioModel.PluginDynamicsCheckpoint {
        studio.capturePluginDynamics()
    }
    @inline(never) @MainActor private func routeCostConsume(_ value: StudioModel.PluginDynamicsCheckpoint, salt: UInt64) -> UInt64 {
        var result = salt &* 0x9e3779b97f4a7c15
        result &+= UInt64(value.characters.count) &* 17
        result &+= UInt64(value.routeFallbackReported.count) &* 31
        result &+= UInt64(value.routes.count) &* 47
        // Order-independent: mapValues may give snapshots different hash-table
        // iteration orders. Owner hashes are only compared within this process.
        for entry in value.routes.values {
            result &+= UInt64(bitPattern: Int64(ObjectIdentifier(entry.clock).hashValue))
                ^ UInt64(entry.clock.reachedTime.bitPattern)
                ^ (UInt64(entry.clock.playStart.bitPattern) << 32)
                ^ (entry.clock.playing ? 1 : 0)
        }
        return result
    }
    @inline(never) @MainActor private func routeCostCaptureBatch(_ studio: StudioModel, iterations: Int) -> (Double, UInt64) {
        var checksum: UInt64 = 0
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<iterations {
            let value = routeCostCapture(studio)
            checksum &+= routeCostConsume(value, salt: UInt64(index))
        }
        return (ProcessInfo.processInfo.systemUptime - start, checksum)
    }
    @inline(never) @MainActor private func routeCostConsumerBatch(_ value: StudioModel.PluginDynamicsCheckpoint,
                                                                iterations: Int) -> (Double, UInt64) {
        var checksum: UInt64 = 0
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<iterations { checksum &+= routeCostConsume(value, salt: UInt64(index)) }
        return (ProcessInfo.processInfo.systemUptime - start, checksum)
    }

    @MainActor private func measureRouteCheckpointCost(_ configuration: RouteCheckpointCost,
                                                       app: AppState, studio: StudioModel) -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = []
        func require(_ name: String, _ okay: Bool, _ detail: String = "") throws {
            rows.append(.init(op: name, ok: okay, detail: detail))
            if !okay { throw SourcePluginError.runtime("Route checkpoint cost assertion failed: " + name) }
        }
        let directory = URL(fileURLWithPath: configuration.directory, isDirectory: true)
        let seed = directory.appendingPathComponent("route-seed.png")
        let fixture = directory.appendingPathComponent("fixture", isDirectory: true)
        let profile = fixture.appendingPathComponent("profile.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: directory.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func matrixBits(_ matrix: float4x4) -> [UInt32] {
            (0..<4).flatMap { c in (0..<4).map { matrix[c][$0].bitPattern } }
        }
        func routeStates() -> [UUID: RoutePlayObservation] {
            studio.sourceRoutePlayState.mapValues { .init(playing: $0.playing, start: $0.start) }
        }
        func snapshot() throws -> InitializerObservation {
            let session = studio.sourcePluginSession, r = studio.host.renderer.resources.statistics()
            return .init(document: studio.doc, world: session?.world.document,
                runtimeDocument: try session?.savedDocument(),
                pending: session?.world.pendingSourceDestruction().map(\.sourceIdentity).sorted() ?? [],
                callbacks: session?.runtime.callbackTrace ?? [],
                resources: [r.meshes, r.textures, r.deformBuffers, r.hiddenBuffers,
                    r.meshBufferBytes, r.deformBufferBytes, r.hiddenBufferBytes, r.retiring],
                undo: studio.undoStack, redo: studio.redoStack, status: studio.status, sceneURL: studio.sceneURL,
                generation: studio.sourcePluginMountGeneration, animationTime: studio.sourceAnimationTime,
                blocked: studio.resourceBlockedObjects, diagnostics: studio.resourceDiagnostics)
        }
        func continuation(child: UUID) throws -> RouteContinuation {
            guard let session = studio.sourcePluginSession else { throw SourcePluginError.invalid("Route cost session is absent.") }
            return .init(document: studio.doc, world: session.world.document, callbacks: session.runtime.callbackTrace,
                animationTime: studio.sourceAnimationTime, routes: routeStates(),
                childWorld: matrixBits(try studio.sourceObjectWorldMatrix(child)),
                renderItems: studio.host.renderer.currentFrame().items.map { .init(objectID: $0.objectID, model: matrixBits($0.model)) })
        }
        func sameFrame(_ a: RenderFrame, _ b: RenderFrame) -> Bool {
            a.camera == b.camera && a.mainLight == b.mainLight && a.effects == b.effects && a.lights == b.lights
                && a.sceneBounds == b.sceneBounds && a.time == b.time && a.skinSets == b.skinSets
                && a.gizmos.count == b.gizmos.count && a.items.count == b.items.count
                && zip(a.items, b.items).allSatisfy { $0.mesh == $1.mesh && $0.model == $1.model && $0.objectID == $1.objectID }
        }
        func prepare(prefix: Int) throws -> (UUID, UUID, [UInt32]) {
            try studio.loadScene(from: seed)
            guard let route = studio.doc.objects.first(where: { $0.sourceObjectKey == configuration.routeKey }),
                  let child = studio.doc.objects.first(where: { $0.sourceObjectKey == configuration.childKey }),
                  child.parent == route.id else { throw SourcePluginError.invalid("Route cost seed lost its route/child binding.") }
            try studio.setSourceAnimationTime(0)
            studio.selection = route.id
            if !studio.selectedRoutePlaying { studio.toggleSourceRoute(route.id) }
            try studio.loadSourcePluginProfileInteractively(profileURL: profile, expectedGeneration: studio.sourcePluginMountGeneration)
            studio.sourcePluginsRunning = false
            let initial = matrixBits(try studio.sourceObjectWorldMatrix(child.id))
            for _ in 0..<prefix { try studio.stepSourcePlugins(deltaTime: 0.02, advanceAnimation: true) }
            return (route.id, child.id, initial)
        }
        do {
            try require("CostBounds", (1...20).contains(configuration.batches)
                && (1...20_000).contains(configuration.iterations) && (1...100).contains(configuration.frames))
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw SourcePluginError.invalid("Route checkpoint cost needs a fresh directory.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false
            guard let sceneFile = studio.doc.sourceSceneFile, let sceneHash = studio.doc.sourceSceneSHA256 else {
                throw SourcePluginError.invalid("Route checkpoint cost needs an imported original scene.")
            }
            // Decode once outside every timed region, to report actual input
            // geometry rather than an assumed route/character count.
            let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: sceneFile))
            defer { try? input.close() }
            let bytes = try input.read(upToCount: 256 * 1024 * 1024 + 1) ?? Data()
            try require("CostSourceHash", bytes.count <= 256 * 1024 * 1024
                && SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == sceneHash)
            var records = try KoikatsuSceneReader.decodeDocument(bytes).snapshot.roots
            var sourceRoute: KoikatsuRouteRecord?
            while let record = records.popLast() {
                if record.sourceKey == configuration.routeKey { sourceRoute = record.route }
                records += record.children
            }
            guard let sourceRoute else { throw SourcePluginError.invalid("Route checkpoint cost input has no requested route record.") }
            let segments = try SourceStudioRoute(record: sourceRoute).segments().count
            try require("CostInput", studio.hasSourceRoutes && sourceRoute.active && sourceRoute.points.count >= 2 && segments > 0)
            try studio.setSourceAnimationTime(0)
            try studio.saveScene(to: seed)
            try routeRollbackFixture(directory: fixture, sourceObjectKey: configuration.childKey)
            var histories: [RouteCostHistory] = []
            for prefix in [3, 300] {
                let name = "prefix\(prefix)"
                let (route, child, initial) = try prepare(prefix: prefix)
                guard let session = studio.sourcePluginSession else { throw SourcePluginError.invalid("Route cost fixture failed to install.") }
                let pose = matrixBits(try studio.sourceObjectWorldMatrix(child))
                let routeOwners = studio.capturePluginDynamics().routes.mapValues(\.clock)
                let previewOwners = Set(studio.renderedSourceCharacterPreviews.map(ObjectIdentifier.init))
                guard let clock = routeOwners[route] else { throw SourcePluginError.invalid("Route cost placement has no clock.") }
                try require(name + "RealClock", routeOwners.count == 1 && clock.playing && clock.frame != nil
                    && clock.reachedTime == studio.sourceAnimationTime && pose != initial && clock.lastAction == .stepped)
                let before = try snapshot(), beforeRoutes = routeStates(), frame = studio.host.renderer.currentFrame()
                let reached = clock.reachedTime, clockFrame = clock.frame, action = clock.lastAction
                let playStart = clock.playStart, playing = clock.playing
                try persist(before, name + "-before")
                var batches: [RouteCostBatch] = []
                let characterCount: Int
                do {
                    // The reused snapshot is only a loop/consumer control. Its
                    // retained lifetime is deliberately excluded from frame timing.
                    let reused = routeCostCapture(studio)
                    characterCount = reused.characters.count
                    let warmCapture = routeCostCaptureBatch(studio, iterations: 100)
                    let warmConsumer = routeCostConsumerBatch(reused, iterations: 100)
                    try require(name + "WarmChecksum", warmCapture.1 == warmConsumer.1)
                    PerfTrace.mark("RouteCheckpointBatches-\(prefix)")
                    for batch in 0..<configuration.batches {
                        let first = configuration.captureFirst != (batch % 2 == 1)
                        let captured: (Double, UInt64), consumed: (Double, UInt64)
                        if first {
                            captured = routeCostCaptureBatch(studio, iterations: configuration.iterations)
                            consumed = routeCostConsumerBatch(reused, iterations: configuration.iterations)
                        } else {
                            consumed = routeCostConsumerBatch(reused, iterations: configuration.iterations)
                            captured = routeCostCaptureBatch(studio, iterations: configuration.iterations)
                        }
                        batches.append(.init(captureSeconds: captured.0, consumerSeconds: consumed.0,
                            captureChecksum: captured.1, consumerChecksum: consumed.1, captureFirst: first))
                    }
                    PerfTrace.mark("RouteCheckpointBatchesEnd-\(prefix)")
                }
                let afterCapture = try snapshot(), afterOwners = studio.capturePluginDynamics().routes.mapValues(\.clock)
                try persist(batches, name + "-batches")
                try persist(afterCapture, name + "-after-capture")
                try require(name + "BatchChecksums", batches.allSatisfy { $0.captureChecksum == $0.consumerChecksum
                    && $0.captureSeconds.isFinite && $0.captureSeconds > 0 && $0.consumerSeconds.isFinite && $0.consumerSeconds > 0 })
                try require(name + "CaptureState", before == afterCapture && beforeRoutes == routeStates()
                    && sameFrame(frame, studio.host.renderer.currentFrame()) && pose == matrixBits(try studio.sourceObjectWorldMatrix(child)))
                try require(name + "CaptureOwners", studio.sourcePluginSession === session
                    && afterOwners.count == routeOwners.count && routeOwners.allSatisfy { afterOwners[$0.key] === $0.value }
                    && previewOwners == Set(studio.renderedSourceCharacterPreviews.map(ObjectIdentifier.init))
                    && clock.reachedTime == reached && clock.frame == clockFrame && clock.lastAction == action
                    && clock.playStart == playStart && clock.playing == playing)
                var times: [Double] = []; times.reserveCapacity(configuration.frames)
                var expectedTime = before.animationTime
                for _ in 0..<configuration.frames { expectedTime += 0.02 }
                PerfTrace.mark("RouteSuccessfulFrames-\(prefix)")
                let frameStart = ProcessInfo.processInfo.systemUptime
                do {
                    for _ in 0..<configuration.frames {
                        let start = ProcessInfo.processInfo.systemUptime
                        try studio.stepSourcePlugins(deltaTime: 0.02, advanceAnimation: true)
                        times.append(ProcessInfo.processInfo.systemUptime - start)
                    }
                } catch {
                    try persist(times, name + "-partial-frame-seconds")
                    throw error
                }
                let frameSeconds = ProcessInfo.processInfo.systemUptime - frameStart
                PerfTrace.mark("RouteSuccessfulFramesEnd-\(prefix)")
                try persist(times, name + "-frame-seconds")
                let afterFrames = try snapshot(), success = try continuation(child: child)
                try persist(afterFrames, name + "-after-frames")
                try persist(success, name + "-success")
                try require(name + "SuccessfulClocksAndCallbacks", studio.sourceAnimationTime.bitPattern == expectedTime.bitPattern
                    && clock.reachedTime.bitPattern == expectedTime.bitPattern
                    && session.runtime.callbackTrace.count == before.callbacks.count + configuration.frames
                    && session.runtime.callbackTrace.suffix(configuration.frames).allSatisfy { $0.hasSuffix(":LateUpdate") }
                    && times.allSatisfy { $0.isFinite && $0 > 0 })
                try require(name + "SuccessfulOwnersAndResources", studio.sourcePluginSession === session
                    && studio.capturePluginDynamics().routes[route]?.clock === clock
                    && previewOwners == Set(studio.renderedSourceCharacterPreviews.map(ObjectIdentifier.init))
                    && afterFrames.resources == before.resources && studio.doc.objects == before.document.objects
                    && beforeRoutes == routeStates() && !studio.sourcePluginsRunning)
                let renderedIDs = Set(frame.items.map(\.objectID))
                let characterRecords = studio.doc.objects.enumerated().filter { $0.element.sourceRecordKind == .character }
                histories.append(.init(prefixSteps: prefix, prefixTime: before.animationTime,
                    ordinaryCharacterCheckpoints: characterCount, routeClocks: routeOwners.count,
                    sourceCharacterRecords: characterRecords.count,
                    renderedCharacterObjects: characterRecords.filter { renderedIDs.contains(UInt32($0.offset + 1)) }.count,
                    drawItems: frame.items.count, routePoints: sourceRoute.points.count, routeSegments: segments,
                    routeAction: String(describing: action), batches: batches, frameSeconds: times,
                    frameBatchSecondsIncludingSampling: frameSeconds))
                // Independently replay from the same native seed with no capture
                // benchmark and no per-frame timers. Compare typed documents so
                // UUID-keyed dictionary encoding order is not mistaken for state.
                let (_, cleanChild, _) = try prepare(prefix: prefix)
                for _ in 0..<configuration.frames { try studio.stepSourcePlugins(deltaTime: 0.02, advanceAnimation: true) }
                let clean = try continuation(child: cleanChild)
                try persist(clean, name + "-control")
                try require(name + "UntimedContinuation", success == clean,
                    "Exact documents, fields, bindings, clocks, callbacks, route child and ordered render-item matrices")
            }
            try persist(RouteCostReport(scope: "Synchronous model events; excludes deferred SwiftUI layout/display and GPU completion. Allocation traffic is not measured.",
                pid: ProcessInfo.processInfo.processIdentifier, sourceSceneSHA256: sceneHash,
                iterations: configuration.iterations, histories: histories), "cost")
        } catch { rows.append(.init(op: "routeCheckpointCostFailure", ok: false, detail: String(describing: error))) }
        studio.sourcePluginsRunning = false
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}

// Route rollback reproduction uses real app clocks; no production state is injected.
extension PluginLibraryScenario {
    struct RouteRollback: Decodable {
        enum Phase: String, Decodable { case control, injected, ownership }
        let phase: Phase
        let directory: String
        let routeKey: Int32, childKey: Int32
    }
    private struct RoutePlayObservation: Codable, Equatable {
        let playing: Bool, start: Float
    }
    private struct RouteRenderItemObservation: Codable, Equatable {
        let objectID: UInt32
        let model: [UInt32]
    }
    private struct RouteContinuation: Codable, Equatable {
        let document: StudioDocument, world: StudioDocument
        let callbacks: [String]
        let animationTime: Float
        let routes: [UUID: RoutePlayObservation]
        let childWorld: [UInt32], renderItems: [RouteRenderItemObservation]
    }

    @MainActor private func reproduceRouteRollback(_ configuration: RouteRollback,
                                                   app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = []
        func record(_ name: String, _ okay: Bool, _ detail: String = "") {
            rows.append(.init(op: name, ok: okay, detail: detail))
        }
        func require(_ name: String, _ okay: Bool, _ detail: String = "") throws {
            record(name, okay, detail)
            if !okay { throw SourcePluginError.runtime("Route rollback precondition failed: " + name) }
        }
        let directory = URL(fileURLWithPath: configuration.directory, isDirectory: true)
        let output = directory.appendingPathComponent(configuration.phase.rawValue, isDirectory: true)
        let seed = directory.appendingPathComponent("route-seed.png")
        let fixture = directory.appendingPathComponent("fixture", isDirectory: true)
        let profile = fixture.appendingPathComponent("profile.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: output.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func matrixBits(_ matrix: float4x4) -> [UInt32] {
            (0..<4).flatMap { c in (0..<4).map { matrix[c][$0].bitPattern } }
        }
        func routeStates() -> [UUID: RoutePlayObservation] {
            studio.sourceRoutePlayState.mapValues { .init(playing: $0.playing, start: $0.start) }
        }
        func renderItems() -> [RouteRenderItemObservation] {
            studio.host.renderer.currentFrame().items.map { .init(objectID: $0.objectID, model: matrixBits($0.model)) }
        }
        func snapshot() throws -> InitializerObservation {
            let session = studio.sourcePluginSession, r = studio.host.renderer.resources.statistics()
            return .init(document: studio.doc, world: session?.world.document,
                runtimeDocument: try session?.savedDocument(),
                pending: session?.world.pendingSourceDestruction().map(\.sourceIdentity).sorted() ?? [],
                callbacks: session?.runtime.callbackTrace ?? [],
                resources: [r.meshes, r.textures, r.deformBuffers, r.hiddenBuffers,
                    r.meshBufferBytes, r.deformBufferBytes, r.hiddenBufferBytes, r.retiring],
                undo: studio.undoStack, redo: studio.redoStack, status: studio.status, sceneURL: studio.sceneURL,
                generation: studio.sourcePluginMountGeneration, animationTime: studio.sourceAnimationTime,
                blocked: studio.resourceBlockedObjects, diagnostics: studio.resourceDiagnostics)
        }
        func sameFrame(_ a: RenderFrame, _ b: RenderFrame) -> Bool {
            a.camera == b.camera && a.mainLight == b.mainLight && a.effects == b.effects && a.lights == b.lights
                && a.sceneBounds == b.sceneBounds && a.time == b.time && a.skinSets == b.skinSets
                && a.gizmos.count == b.gizmos.count && a.items.count == b.items.count
                && zip(a.items, b.items).allSatisfy { $0.mesh == $1.mesh && $0.model == $1.model && $0.objectID == $1.objectID }
        }
        do {
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw SourcePluginError.invalid("Route rollback needs a fresh phase directory.")
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try persist(["pid": ProcessInfo.processInfo.processIdentifier], "process")
            studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false
            try require("RouteInput", studio.hasSourceRoutes
                && studio.doc.objects.contains(where: { $0.sourceObjectKey == configuration.routeKey })
                && studio.doc.objects.contains(where: { $0.sourceObjectKey == configuration.childKey }),
                "Use the retained moving route and child; no synthetic placement substitute")
            if configuration.phase == .control {
                guard !FileManager.default.fileExists(atPath: seed.path) else {
                    throw SourcePluginError.invalid("Route rollback native seed already exists.")
                }
                try studio.setSourceAnimationTime(0)
                try studio.saveScene(to: seed)
                try routeRollbackFixture(directory: fixture, sourceObjectKey: configuration.childKey)
            } else {
                let producer = try JSONDecoder().decode([String: Int32].self,
                    from: Data(contentsOf: directory.appendingPathComponent("control/process.json")))
                try require("IndependentRouteControlProcess", producer["pid"] != nil
                    && producer["pid"] != ProcessInfo.processInfo.processIdentifier)
            }
            if configuration.phase == .ownership {
                try studio.loadScene(from: seed)
                let document = studio.doc
                guard let route = document.objects.first(where: { $0.sourceObjectKey == configuration.routeKey }),
                      let child = document.objects.first(where: { $0.sourceObjectKey == configuration.childKey }) else {
                    throw SourcePluginError.invalid("Native route seed lost a required source object.")
                }
                // Exercise the real rehydration boundary before its caller's
                // first refresh. No cache field or clock state is injected.
                studio.newScene()
                studio.doc = document
                studio.rehydrateSourceRuntime()
                let lazy = studio.capturePluginDynamics(), time = studio.sourceAnimationTime
                let before = try snapshot(), frame = studio.host.renderer.currentFrame()
                try require("LazyRouteClockAbsent", studio.hasSourceRoutes && lazy.routes.isEmpty)
                let initial = matrixBits(try studio.sourceObjectWorldMatrix(child.id))
                let materialized = studio.capturePluginDynamics()
                try require("LazyQueryCreatesClock", materialized.routes[route.id] != nil)
                guard let first = materialized.routes[route.id]?.clock else {
                    throw SourcePluginError.invalid("Route placement did not create its clock.")
                }
                record("LazyQueryHasNoExternalMutation", before == (try snapshot())
                    && sameFrame(frame, studio.host.renderer.currentFrame()))
                try studio.restorePluginDynamics(time: time, checkpoints: lazy)
                record("DiscardNewClock", studio.capturePluginDynamics().routes.isEmpty)
                record("DiscardNewClockState", before == (try snapshot())
                    && sameFrame(frame, studio.host.renderer.currentFrame()))
                let retry = matrixBits(try studio.sourceObjectWorldMatrix(child.id))
                guard let owner = studio.capturePluginDynamics().routes[route.id]?.clock else {
                    throw SourcePluginError.invalid("Route retry did not create its clock.")
                }
                record("LazyRetryNewOwner", owner !== first)
                record("LazyRetrySamePose", retry == initial)
                for _ in 0..<3 { try studio.advancePluginAnimation(by: 0.02) }
                let prefix = matrixBits(try studio.sourceObjectWorldMatrix(child.id))
                try require("WarmPrefixMoved", prefix != initial)
                let warm = studio.capturePluginDynamics(), warmTime = studio.sourceAnimationTime
                let warmState = try snapshot(), warmFrame = studio.host.renderer.currentFrame()
                try studio.advancePluginAnimation(by: 0.02)
                let continuation = matrixBits(try studio.sourceObjectWorldMatrix(child.id))
                try require("WarmAdvanceMoved", continuation != prefix)
                try studio.restorePluginDynamics(time: warmTime, checkpoints: warm)
                record("WarmOwner", studio.capturePluginDynamics().routes[route.id]?.clock === owner)
                record("WarmExactState", warmState == (try snapshot())
                    && sameFrame(warmFrame, studio.host.renderer.currentFrame()))
                record("WarmPose", matrixBits(try studio.sourceObjectWorldMatrix(child.id)) == prefix)
                try studio.advancePluginAnimation(by: 0.02)
                record("WarmRetryMatches", matrixBits(try studio.sourceObjectWorldMatrix(child.id)) == continuation)
                // An old request retains its original owner even if a later
                // lazy placement has temporarily populated the same UUID key.
                try studio.restorePluginDynamics(time: time, checkpoints: lazy)
                _ = try studio.sourceObjectWorldMatrix(child.id)
                let replacement = studio.capturePluginDynamics().routes[route.id]?.clock
                try studio.restorePluginDynamics(time: warmTime, checkpoints: warm)
                let restoredPose = matrixBits(try studio.sourceObjectWorldMatrix(child.id))
                record("CapturedOwnerRestoredAfterReplacement", replacement !== owner
                    && studio.capturePluginDynamics().routes[route.id]?.clock === owner
                    && restoredPose == prefix)
                studio.sourcePluginsRunning = false
                return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
            }
            let cases: [(String, Float, Bool)] = [("regular", SourceStudioRouteClock.frameDelta, true), ("irregular", 0.02, true), ("stopped", 0.02, false)]
            for (name, delta, playing) in cases {
                // Both processes reopen the same native seed, preserving UUIDs.
                // No remapping or normalization is needed for this comparison.
                try studio.loadScene(from: seed)
                guard let route = studio.doc.objects.first(where: { $0.sourceObjectKey == configuration.routeKey }),
                      let child = studio.doc.objects.first(where: { $0.sourceObjectKey == configuration.childKey }) else {
                    throw SourcePluginError.invalid("Native route seed lost a required source object.")
                }
                try studio.setSourceAnimationTime(0)
                studio.selection = route.id
                if studio.selectedRoutePlaying != playing { studio.toggleSourceRoute(route.id) }
                try require(name + "RouteMode", studio.selectedRouteIsSource && studio.selectedRoutePlaying == playing
                    && child.parent == route.id, "The observed child must remain directly under the verified source route")
                try studio.loadSourcePluginProfileInteractively(profileURL: profile, expectedGeneration: studio.sourcePluginMountGeneration)
                studio.sourcePluginsRunning = false
                guard let session = studio.sourcePluginSession else { throw SourcePluginError.invalid("Route fixture failed to install.") }
                let component = try session.runtime.component(at: 0)
                let initialMatrix = matrixBits(try studio.sourceObjectWorldMatrix(child.id))
                for _ in 0..<3 { try studio.stepSourcePlugins(deltaTime: delta, advanceAnimation: true) }
                let baselineMatrix = matrixBits(try studio.sourceObjectWorldMatrix(child.id))
                try require(name + "PrefixPlacement", playing ? baselineMatrix != initialMatrix : baselineMatrix == initialMatrix,
                    "Three real successful frames at delta \(delta); moving control must change, stopped control must hold")
                try session.world.replaceDocument(studio.doc)
                try persist(baselineMatrix, name + "-prefix-matrix")
                if configuration.phase == .injected {
                    var fields = try component.savedFields(); fields["trip"] = .bool(true); try component.restoreFields(fields)
                    for attempt in 1...2 {
                        studio.sourcePluginsRunning = true
                        let before = try snapshot(), routes = routeStates(), frame = studio.host.renderer.currentFrame()
                        let previews = Set(studio.renderedSourceCharacterPreviews.map(ObjectIdentifier.init))
                        let adapter = studio.sourceFocus.adapter, gain = studio.sourceAudioBus.masterVolume
                        let observers = studio.sourceFocusObservers.count
                        try persist(before, name + "-before-\(attempt)")
                        var rejection: String?
                        do { try studio.stepSourcePlugins(deltaTime: delta, advanceAnimation: true) }
                        catch SourcePluginError.runtime(let reason) { rejection = reason }
                        catch { rejection = "UNEXPECTED: \(error)" }
                        let after = try snapshot()
                        let afterMatrix = matrixBits(try studio.sourceObjectWorldMatrix(child.id))
                        try persist(after, name + "-after-\(attempt)")
                        try persist(afterMatrix, name + "-after-matrix-\(attempt)")
                        record(name + "Failure\(attempt)ExactError", rejection == "Unsupported arithmetic operator or Int32 arithmetic.", rejection ?? "No failure")
                        record(name + "Failure\(attempt)ExactState", before == after && routeStates() == routes,
                            "Complete document/runtime/clock/history/resource snapshot and route play state")
                        record(name + "Failure\(attempt)RoutePose", afterMatrix == baselineMatrix,
                            "Exact pre-failure route child matrix; no fixed-step reconstruction tolerance")
                        record(name + "Failure\(attempt)OwnersAndFrame", studio.sourcePluginSession === session
                            && Set(studio.renderedSourceCharacterPreviews.map(ObjectIdentifier.init)) == previews
                            && sameFrame(frame, studio.host.renderer.currentFrame()) && studio.sourceFocus.adapter === adapter
                            && studio.sourceAudioBus.masterVolume == gain && studio.sourceFocusObservers.count == observers
                            && !studio.sourcePluginsRunning)
                        studio.refresh()
                        let refreshedMatrix = matrixBits(try studio.sourceObjectWorldMatrix(child.id))
                        try persist(refreshedMatrix, name + "-refreshed-matrix-\(attempt)")
                        try persist(renderItems(), name + "-refreshed-items-\(attempt)")
                        record(name + "Failure\(attempt)RefreshedPose", refreshedMatrix == baselineMatrix,
                            "A real refresh must not expose a changed route cache behind an unchanged submitted frame")
                        record(name + "Failure\(attempt)RefreshedFrame", sameFrame(frame, studio.host.renderer.currentFrame()))
                    }
                    var retryFields = try component.savedFields(); retryFields["trip"] = .bool(false); try component.restoreFields(retryFields)
                }
                let clock = studio.sourceAnimationTime
                try studio.stepSourcePlugins(deltaTime: delta, advanceAnimation: true)
                studio.refresh()
                let finalMatrix = matrixBits(try studio.sourceObjectWorldMatrix(child.id))
                let success = RouteContinuation(document: studio.doc, world: session.world.document,
                    callbacks: session.runtime.callbackTrace, animationTime: studio.sourceAnimationTime,
                    routes: routeStates(), childWorld: finalMatrix, renderItems: renderItems())
                try persist(success, name + "-success")
                record(name + "SuccessClock", studio.sourceAnimationTime.bitPattern == (clock + delta).bitPattern)
                record(name + "SuccessCallback", session.runtime.callbackTrace.last?.hasSuffix(":LateUpdate") == true)
                record(name + "SuccessPlacement", playing ? finalMatrix != baselineMatrix : finalMatrix == baselineMatrix)
                if configuration.phase == .injected {
                    let clean = try JSONDecoder().decode(RouteContinuation.self,
                        from: Data(contentsOf: directory.appendingPathComponent("control/" + name + "-success.json")))
                    record(name + "RetryMatchesIndependentControl", success == clean,
                        "Same native UUIDs; full documents/fields/bindings/callbacks/clocks plus bit-exact route and ordered render-item matrices")
                }
            }
        } catch { record("routeReproductionFailure", false, String(describing: error)) }
        studio.sourcePluginsRunning = false
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }

    private func routeRollbackFixture(directory: URL, sourceObjectKey: Int32) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw SourcePluginError.invalid("Route rollback fixture already exists.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        typealias Node = [String: Any]
        let type = "RouteFrame", guid = "Ikkoku.Validation.RouteRollback", hash = String(repeating: "c", count: 64)
        let poison: Node = ["kind": "binary", "type": "Int32", "name": "+", "children": [
            ["kind": "literal", "type": "Int32", "value": 1], ["kind": "literal", "type": "Int32", "value": 1]]]
        let body: Node = ["kind": "block", "children": [["kind": "if", "children": [
            ["kind": "field", "type": "Bool", "name": "trip"],
            ["kind": "block", "children": [["kind": "expression", "children": [poison]]]],
            ["kind": "block", "children": []]]]]]
        let program: Node = ["schemaVersion": 1, "status": "ready", "mode": "component", "type": type,
            "source": ["sha256": hash], "identity": ["sourceSHA256": hash, "type": type, "pluginGUID": guid,
                "symbols": ["M:\(type).LateUpdate"]], "semanticSurfaceSHA256": hash, "bridgeSHA256": hash, "emitterSHA256": hash,
            "fields": [["name": "trip", "type": "Bool", "serialized": true,
                "initializer": ["kind": "literal", "type": "Bool", "value": false]]],
            "methods": [["name": "LateUpdate", "symbol": "M:\(type).LateUpdate", "static": false,
                "returnType": "Void", "parameters": [], "body": body, "lifecycle": "LateUpdate"]]]
        let bytes = try JSONSerialization.data(withJSONObject: program, options: [.sortedKeys])
        _ = try SourceIRProgram.decode(bytes)
        try bytes.write(to: directory.appendingPathComponent("program.json"), options: .withoutOverwriting)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest: Node = ["schemaVersion": 1, "kind": "ikkoku-translated-plugin",
            "identity": ["guid": guid, "version": "1.0", "name": "Route rollback reproduction"],
            "processes": ["CharaStudio"], "dependencies": [], "incompatibilities": [],
            "components": [["type": type, "program": ["file": "program.json", "sha256": digest]]]]
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .withoutOverwriting)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixedDeltaTime": 0.02,
            "packages": [["manifest": manifestURL.path, "bindings": [["type": type, "sourceObjectKey": sourceObjectKey]]]]], options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("profile.json"), options: .withoutOverwriting)
    }
}

// App-host frame rollback reproduction. Production stepping/ownership is unchanged.
extension PluginLibraryScenario {
    struct FrameRollback: Decodable {
        enum Phase: String, Decodable { case control, warm, cold }
        let phase: Phase
        let directory: String
        let sourceObjectKey: Int32
    }
    private struct FrameContinuation: Codable, Equatable {
        let document: StudioDocument, world: StudioDocument
        let callbacks: [String]
        let animationTime: Float
        let poses: [String: [UInt32]]
    }

    @MainActor private func reproduceFrameRollback(_ configuration: FrameRollback,
                                                   app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = []
        func record(_ name: String, _ okay: Bool, _ detail: String = "") {
            rows.append(.init(op: name, ok: okay, detail: detail))
        }
        func require(_ name: String, _ okay: Bool, _ detail: String = "") throws {
            record(name, okay, detail)
            if !okay { throw SourcePluginError.runtime("Frame rollback precondition failed: " + name) }
        }
        let directory = URL(fileURLWithPath: configuration.directory, isDirectory: true)
        let output = directory.appendingPathComponent(configuration.phase.rawValue, isDirectory: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: output.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func snapshot() throws -> InitializerObservation {
            let session = studio.sourcePluginSession, r = studio.host.renderer.resources.statistics()
            return .init(document: studio.doc, world: session?.world.document,
                runtimeDocument: try session?.savedDocument(),
                pending: session?.world.pendingSourceDestruction().map(\.sourceIdentity).sorted() ?? [],
                callbacks: session?.runtime.callbackTrace ?? [],
                resources: [r.meshes, r.textures, r.deformBuffers, r.hiddenBuffers,
                    r.meshBufferBytes, r.deformBufferBytes, r.hiddenBufferBytes, r.retiring],
                undo: studio.undoStack, redo: studio.redoStack, status: studio.status, sceneURL: studio.sceneURL,
                generation: studio.sourcePluginMountGeneration, animationTime: studio.sourceAnimationTime,
                blocked: studio.resourceBlockedObjects, diagnostics: studio.resourceDiagnostics)
        }
        func sameFrame(_ a: RenderFrame, _ b: RenderFrame) -> Bool {
            a.camera == b.camera && a.mainLight == b.mainLight && a.effects == b.effects && a.lights == b.lights
                && a.sceneBounds == b.sceneBounds && a.time == b.time && a.skinSets == b.skinSets
                && a.gizmos.count == b.gizmos.count && a.items.count == b.items.count
                && zip(a.items, b.items).allSatisfy { $0.mesh == $1.mesh && $0.model == $1.model && $0.objectID == $1.objectID }
        }
        func pose(_ object: StudioObject) throws -> [UInt32] {
            guard let preview = studio.sourceShapePreview(for: object.id) else {
                throw SourcePluginError.invalid("Frame rollback preview is absent.")
            }
            let value = try preview.editedPose(fkRotations: object.sourceFKRotations ?? [:],
                faceValues: object.sourceFaceValues, bodyValues: object.sourceBodyValues,
                ikTargets: object.sourceIKOverrides ?? [:], kinematics: object.sourceKinematics,
                animationState: object.sourceAnimation, animationElapsed: studio.sourceAnimationTime)
            return value.localMatrices.flatMap { matrix in (0..<4).flatMap { c in (0..<4).map { matrix[c][$0].bitPattern } } }
        }
        // Only successful independent runs normalize random clone UUIDs. Keep
        // every document/state field and array order; require a bijective exact
        // identity map, and reject missing references rather than dropping them.
        func continuation() throws -> FrameContinuation {
            guard let session = studio.sourcePluginSession else { throw SourcePluginError.invalid("Frame rollback session is absent.") }
            let identities = session.world.identities
            guard identities.count <= 10000, Set(identities.values.map { Data($0.utf8) }).count == identities.count else {
                throw SourcePluginError.invalid("Ambiguous frame control identity map.")
            }
            let ordered = identities.sorted { $0.value.utf8.lexicographicallyPrecedes($1.value.utf8) }
            let remap = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, entry in
                (entry.key, UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!)
            })
            func mapped(_ id: UUID) throws -> UUID {
                guard let value = remap[id] else { throw SourcePluginError.invalid("Frame control reference has no identity.") }
                return value
            }
            func normalized(_ original: StudioDocument) throws -> StudioDocument {
                guard original.timeline.keyframes.isEmpty, original.sourcePluginLibraryConfiguration == nil else {
                    throw SourcePluginError.invalid("Frame control supports only its fixed profile fixture.")
                }
                var value = original
                value.objects = try original.objects.map { object in
                    var copy = object; copy.id = try mapped(object.id); copy.parent = try object.parent.map(mapped); return copy
                }
                if let state = original.sourcePluginState {
                    guard var raw = try JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any] else {
                        throw SourcePluginError.invalid("Frame control state is not a JSON object.")
                    }
                    let pairs = try state.objectIdentities.map { (try mapped($0.key), $0.value) }
                    raw["objectIdentities"] = try JSONSerialization.jsonObject(with: encoder.encode(Dictionary(uniqueKeysWithValues: pairs)))
                    if let roots = state.pendingDestructionRoots {
                        raw["pendingDestructionRoots"] = try roots.map { try mapped($0).uuidString }.sorted()
                    }
                    value.sourcePluginState = try JSONDecoder().decode(SourceStudioPluginState.self,
                        from: JSONSerialization.data(withJSONObject: raw))
                }
                return value
            }
            var poses: [String: [UInt32]] = [:]
            for object in studio.doc.objects where object.sourceCharacter != nil {
                guard let identity = identities[object.id] else { throw SourcePluginError.invalid("Frame pose identity is absent.") }
                poses[identity] = try pose(object)
            }
            return try .init(document: normalized(studio.doc), world: normalized(session.world.document),
                callbacks: session.runtime.callbackTrace, animationTime: studio.sourceAnimationTime, poses: poses)
        }
        do {
            guard !FileManager.default.fileExists(atPath: output.path),
                  let template = studio.doc.objects.first(where: { $0.sourceObjectKey == configuration.sourceObjectKey && $0.sourceCharacter != nil }) else {
                throw SourcePluginError.invalid("Frame rollback needs a fresh phase directory and the configured source character.")
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try persist(["pid": ProcessInfo.processInfo.processIdentifier], "process")
            if configuration.phase != .control {
                let producer = try JSONDecoder().decode([String: Int32].self,
                    from: Data(contentsOf: directory.appendingPathComponent("control/process.json")))
                try require("IndependentControlProcess", producer["pid"] != nil
                    && producer["pid"] != ProcessInfo.processInfo.processIdentifier)
            }
            studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false
            let sourceFile = studio.doc.sourceSceneFile, sourceHash = studio.doc.sourceSceneSHA256
            let names = configuration.phase == .control ? ["warm", "cold"] : [configuration.phase.rawValue]
            for name in names {
                let cold = name == "cold", injected = configuration.phase != .control
                studio.newScene()
                var parent = template; parent.id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
                parent.parent = nil; parent.sourceObjectKey = 11; parent.visible = true
                var child = StudioObject(name: "Frame attachment probe", kind: .folder)
                child.id = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
                child.sourceObjectKey = 12; child.parent = parent.id; child.sourceAttachmentPoint = 17
                var document = StudioDocument(); document.sourceSceneFile = sourceFile; document.sourceSceneSHA256 = sourceHash
                document.objects = [parent, child]; studio.doc = document
                guard let preview = studio.sourceShapePreview(for: parent.id) else { throw SourcePluginError.invalid("Frame fixture character did not render.") }
                try require(name + "AnimationInput", preview.hasSavedAnimation, "Retained source animation must be executable; no static substitute")
                studio.selection = parent.id
                studio.setSourceFKEnabled(false); studio.setSourceIKEnabled(false)
                var body = preview.savedBodyValues; body[0] = body[0] < 0.5 ? 0.8 : 0.2
                try studio.setSourceShapeValues(parent.id, face: nil, body: body)
                try studio.setSourceAnimationSpeed(parent.id, 1)
                try studio.setSourceAnimationTime(0.7)
                let fixture = directory.appendingPathComponent("fixture-" + name, isDirectory: true)
                let profile = fixture.appendingPathComponent("profile.json")
                if !injected { try frameRollbackFixture(directory: fixture, cold: cold) }
                try studio.loadSourcePluginProfileInteractively(profileURL: profile, expectedGeneration: studio.sourcePluginMountGeneration)
                studio.sourcePluginsRunning = false
                guard let session = studio.sourcePluginSession, let currentParent = studio.doc.object(parent.id) else {
                    throw SourcePluginError.invalid("Frame fixture failed to install.")
                }
                let component = try session.runtime.component(at: 0)
                // Session.step synchronizes the owner's input before its runtime
                // transaction. Establish that input once before observing the
                // failure, so this test isolates callback/host rollback.
                try session.world.replaceDocument(studio.doc)
                let baselinePose = try pose(currentParent)
                try require(name + "Installed", session.runtime.savedBindings().count == 2
                    && session.world.cloneSerial == 0 && studio.renderedSourceCharacterPreviews.count == 1,
                    "Child binding first; real point17 read; source parent preview warm; cloned parent absent")
                if injected {
                    var fields = try component.savedFields(); fields["trip"] = .bool(true); try component.restoreFields(fields)
                    for attempt in 1...2 {
                        studio.sourcePluginsRunning = true
                        let before = try snapshot(), frame = studio.host.renderer.currentFrame()
                        let previews = Set(studio.renderedSourceCharacterPreviews.map(ObjectIdentifier.init))
                        let diagnostics = preview.diagnostics, adapter = studio.sourceFocus.adapter
                        let gain = studio.sourceAudioBus.masterVolume, observers = studio.sourceFocusObservers.count
                        try persist(before, name + "-before-\(attempt)")
                        var rejection: String?
                        let start = ProcessInfo.processInfo.systemUptime
                        do { try studio.stepSourcePlugins(deltaTime: 0.02, advanceAnimation: true) }
                        catch SourcePluginError.runtime(let reason) { rejection = reason }
                        catch { rejection = "UNEXPECTED: \(error)" }
                        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        let after = try snapshot(); try persist(after, name + "-after-\(attempt)")
                        record(name + "Failure\(attempt)ExactError", rejection == "Unsupported arithmetic operator or Int32 arithmetic.", rejection ?? "No failure")
                        record(name + "Failure\(attempt)ExactState", before == after,
                            "No normalization; complete document/runtime/clock/history/resource snapshot; synchronous step \(elapsed) ms (functional diagnostic)")
                        record(name + "Failure\(attempt)OwnersAndFrame", studio.sourcePluginSession === session
                            && studio.sourceShapePreview(for: parent.id) === preview
                            && Set(studio.renderedSourceCharacterPreviews.map(ObjectIdentifier.init)) == previews
                            && preview.diagnostics == diagnostics && sameFrame(frame, studio.host.renderer.currentFrame())
                            && studio.sourceFocus.adapter === adapter && studio.sourceAudioBus.masterVolume == gain
                            && studio.sourceFocusObservers.count == observers && !studio.sourcePluginsRunning)
                        record(name + "Failure\(attempt)Pose", try pose(currentParent) == baselinePose,
                            "Warm edited pose resumes at exact prior clock")
                    }
                    var retryFields = try component.savedFields(); retryFields["trip"] = .bool(false); try component.restoreFields(retryFields)
                }
                let clock = studio.sourceAnimationTime, start = ProcessInfo.processInfo.systemUptime
                try studio.stepSourcePlugins(deltaTime: 0.02, advanceAnimation: true)
                let stepMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let success = try continuation(); try persist(success, name + "-success")
                record(name + "SuccessTopology", studio.doc.objects.count == (cold ? 4 : 2)
                    && session.world.cloneSerial == (cold ? 1 : 0)
                    && studio.renderedSourceCharacterPreviews.count == (cold ? 2 : 1),
                    "Cold control proves a real cloned source-parent preview was constructed by the child initializer")
                record(name + "SuccessClock", studio.sourceAnimationTime.bitPattern == (clock + 0.02).bitPattern,
                    "Production afterUpdate clock; synchronous step \(stepMS) ms (functional diagnostic)")
                let lastChild = cold ? studio.doc.objects.last(where: { $0.sourceAttachmentPoint == 17 && $0.id != child.id }) : child
                let finalIdentity = lastChild.flatMap { session.world.identities[$0.id] }
                record(name + "SuccessCallbacks", finalIdentity.map { session.runtime.callbackTrace.last?.hasSuffix("FrameChild/" + $0 + ":LateUpdate") == true } == true,
                    session.runtime.callbackTrace.joined(separator: "; "))
                record(name + "SuccessAnimatedPose", try pose(studio.doc.object(parent.id)!) != baselinePose,
                    "Real source animation/dynamics changed the edited pose")
                if injected {
                    let url = directory.appendingPathComponent("control/" + name + "-success.json")
                    let clean = try JSONDecoder().decode(FrameContinuation.self, from: Data(contentsOf: url))
                    record(name + "RetryMatchesIndependentControl", success == clean,
                        "Full typed scene/runtime fields, binding order, clocks, trace and bit-exact pose; only random successful clone UUIDs normalized")
                }
            }
        } catch { record("frameReproductionFailure", false, String(describing: error)) }
        studio.sourcePluginsRunning = false
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }

    private func frameRollbackFixture(directory: URL, cold: Bool) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw SourcePluginError.invalid("Frame fixture directory already exists.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        typealias Node = [String: Any]
        let guid = "Ikkoku.Validation.FrameRollback", hash = String(repeating: "b", count: 64)
        func field(_ name: String, _ type: String) -> Node { ["kind": "field", "name": name, "type": type] }
        func boolean(_ value: Bool) -> Node { ["kind": "literal", "type": "Bool", "value": value] }
        func block(_ nodes: [Node]) -> Node { ["kind": "block", "children": nodes] }
        func assign(_ name: String, _ type: String, _ value: Node) -> Node {
            ["kind": "assign", "name": "=", "children": [field(name, type), value]]
        }
        let read: Node = ["kind": "api", "type": "Vector3", "name": "position", "children": [
            ["kind": "api", "type": "Transform", "name": "transform", "children": []]]]
        let zero: Node = ["kind": "api", "type": "Vector3", "name": "vector.zero", "children": []]
        let poison: Node = ["kind": "binary", "type": "Int32", "name": "+", "children": [
            ["kind": "literal", "type": "Int32", "value": 1], ["kind": "literal", "type": "Int32", "value": 1]]]
        let clone: Node = ["kind": "api", "type": "Object", "name": "world.Instantiate", "children": [
            ["kind": "api", "type": "Object", "name": "gameObject", "children": []]]]
        let childFields: [Node] = [
            ["name": "position", "type": "Vector3", "serialized": true, "initializer": zero],
            ["name": "constructionPosition", "type": "Vector3", "serialized": false, "initializer": cold ? read : zero],
            ["name": "trip", "type": "Bool", "serialized": true, "initializer": boolean(false)]]
        let childBody: [Node] = [assign("position", "Vector3", read),
            ["kind": "if", "children": [field("trip", "Bool"), block([["kind": "expression", "children": [poison]]]), block([])]]]
        let parentFields: [Node] = [["name": "cloneOnce", "type": "Bool", "serialized": true, "initializer": boolean(cold)]]
        let parentBody: [Node] = [["kind": "if", "children": [field("cloneOnce", "Bool"),
            block([assign("cloneOnce", "Bool", boolean(false)), ["kind": "expression", "children": [clone]]]), block([])]]]
        var components: [Node] = []
        for (type, fields, callback, body) in [("FrameChild", childFields, "LateUpdate", childBody), ("FrameParent", parentFields, "Update", parentBody)] {
            let program: Node = ["schemaVersion": 1, "status": "ready", "mode": "component", "type": type,
                "source": ["sha256": hash], "identity": ["sourceSHA256": hash, "type": type, "pluginGUID": guid,
                    "symbols": ["M:\(type).\(callback)"]], "semanticSurfaceSHA256": hash, "bridgeSHA256": hash, "emitterSHA256": hash,
                "fields": fields, "methods": [["name": callback, "symbol": "M:\(type).\(callback)", "static": false,
                    "returnType": "Void", "parameters": [], "body": block(body), "lifecycle": callback]]]
            let bytes = try JSONSerialization.data(withJSONObject: program, options: [.sortedKeys])
            _ = try SourceIRProgram.decode(bytes)
            let file = type + ".json"; try bytes.write(to: directory.appendingPathComponent(file))
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            components.append(["type": type, "program": ["file": file, "sha256": digest]])
        }
        let manifest: Node = ["schemaVersion": 1, "kind": "ikkoku-translated-plugin",
            "identity": ["guid": guid, "version": "1.0", "name": "Frame rollback reproduction"],
            "processes": ["CharaStudio"], "dependencies": [], "incompatibilities": [], "components": components]
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixedDeltaTime": 0.02,
            "packages": [["manifest": manifestURL.path, "bindings": [["type": "FrameChild", "sourceObjectKey": 12],
                ["type": "FrameParent", "sourceObjectKey": 11]]]]], options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("profile.json"))
    }
}

// This diagnostic observes a documented library installation policy. It does
// not enable source attachment reads or change package/runtime behavior.
extension PluginLibraryScenario {
    struct LibraryAttachmentRestore: Decodable {
        let phase: NativeProfileRestore.Phase
        let directory: String
        let outputDirectory: String
        let requests: [String: String]
    }

    @MainActor private func reproduceLibraryAttachmentRestore(_ configuration: LibraryAttachmentRestore,
                                                               app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        let directory = URL(fileURLWithPath: configuration.directory)
        let output = URL(fileURLWithPath: configuration.outputDirectory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let gate = "Source-character attachment reads during plugin installation are unsupported; no live preview was changed."
        let arithmetic = "Unsupported arithmetic operator or Int32 arithmetic."
        let topology = "Restoring plugin initialization changed scene object topology, identities, or clone state."
        var rows: [StudioScenario.Report.StepResult] = []
        func check(_ name: String, _ okay: Bool, _ detail: String = "") throws {
            rows.append(.init(op: name, ok: okay, detail: detail))
            if !okay { throw SourcePluginError.runtime("Library attachment reproduction failed: " + name) }
        }
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: output.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func scene(_ name: String) -> URL { directory.appendingPathComponent(name + ".png") }
        func decoded(_ name: String) throws -> StudioDocument {
            try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: Data(contentsOf: scene(name)))
        }
        func snapshot(status: String? = nil) throws -> NativeGraphObservation {
            .init(graph: try directGraphSnapshot(studio: studio, expectedStatus: status),
                previewOwners: studio.renderedSourceCharacterPreviews.map { String(describing: ObjectIdentifier($0)) }.sorted())
        }
        func frame(_ name: String) throws -> Data {
            let bytes = try directGraphFrameBytes(studio.host.renderer.currentFrame())
            try bytes.write(to: output.appendingPathComponent(name + "-frame.json"), options: .withoutOverwriting)
            return bytes
        }
        func rejection(_ name: String, expected: String, history: Bool = false, operation: () throws -> Void) throws {
            let before = try snapshot(), beforeFrame = try frame(name + "-before")
            try persist(before, name + "-before")
            var error: String?
            do { try operation() }
            catch SourcePluginError.invalid(let reason) { error = reason }
            catch SourcePluginError.runtime(let reason) { error = reason }
            catch let unexpected { error = "UNEXPECTED: \(unexpected)" }
            if history { error = studio.status }
            try persist(try snapshot(), name + "-after")
            let afterFrame = try frame(name + "-after")
            let wanted = history ? "Plugin restore: \(SourcePluginError.invalid(expected))" : expected
            try check(name + "Error", error == wanted, error ?? "No rejection")
            let after = try snapshot(status: history ? before.graph.state.status : nil)
            try check(name + "State", after == before, "Only the verified history error status is normalized")
            try check(name + "Frame", afterFrame == beforeFrame)
        }
        do {
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw SourcePluginError.invalid("Library attachment observations require a fresh output directory.")
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            studio.stopBenchmarkTimer(); studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false; studio.showGizmos = false; studio.showTimeline = false
            guard let template = studio.doc.objects.first(where: { $0.sourceObjectKey == 10 && $0.sourceCharacter != nil }),
                  template.sourceCharacter?.attachmentCatalogFile != nil else {
                throw SourcePluginError.invalid("Library attachment fixture needs source character10 and an attachment catalog.")
            }
            try check("sourceFixture", !studio.host.renderer.currentFrame().items.isEmpty
                && studio.host.renderer.currentFrame().items.allSatisfy { $0.sourceShader == nil })
            let names = ["attachment", "plain", "poison", "topology"]
            guard Set(configuration.requests.keys) == Set(names) else { throw SourcePluginError.invalid("Library attachment fixture requests differ.") }
            var requests: [String: StudioPluginLibraryRequest] = [:]
            var resolutions: [String: SourcePluginLibraryResolution] = [:]
            for name in names {
                let request = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: configuration.requests[name]!))
                let resolution = try request.selection.resolve()
                guard request.configuration.bindings.count == 1, resolution.translated.count == 1,
                      resolution.nativeAdapters.isEmpty else { throw SourcePluginError.invalid("Expected one controlled IR package per fixture.") }
                requests[name] = request; resolutions[name] = resolution
            }
            try persist(requests.mapValues(\.selection), "exact-selections")
            try check("immutableInputs", Set(requests.values.flatMap { $0.selection.revisions.map(\.manifestSHA256) }).count == 4)
            switch configuration.phase {
            case .save:
                guard !FileManager.default.fileExists(atPath: directory.path) else {
                    throw SourcePluginError.invalid("Library attachment save requires a fresh scene directory.")
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let sourceFile = studio.doc.sourceSceneFile, sourceSHA = studio.doc.sourceSceneSHA256
                var parent = template; parent.id = UUID(); parent.parent = nil; parent.visible = false
                var child = StudioObject(name: "Controlled library attachment", kind: .folder)
                child.sourceObjectKey = 12; child.parent = parent.id; child.sourceAttachmentPoint = 17
                var target = StudioObject(name: "Unattached topology control", kind: .folder); target.sourceObjectKey = 13
                for name in names {
                    studio.newScene()
                    var document = studio.doc; document.sourceSceneFile = sourceFile; document.sourceSceneSHA256 = sourceSHA
                    document.objects = [parent, child, target]; studio.doc = document
                    let request = requests[name]!
                    try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: request.configuration)
                    studio.sourcePluginsRunning = false
                    let zero = try studio.sourcePluginSession!.savedDocument().sourcePluginState
                    try check(name + "RealMount", zero?.clock.deltaTime == 0 && zero?.clock.elapsedTime == 0
                        && studio.doc.sourcePluginLibrary == request.selection
                        && studio.sourceShapePreview(for: parent.id) == nil)
                    if name == "attachment" {
                        try studio.saveScene(to: scene("zero"))
                        try check("zeroRealSave", try decoded("zero").sourcePluginState == zero)
                    }
                    try studio.stepSourcePlugins(deltaTime: 0.04)
                    let state = try studio.sourcePluginSession!.savedDocument().sourcePluginState
                    try check(name + "RealStep", state?.clock.deltaTime == Float(0.04)
                        && state?.clock.elapsedTime == Double(Float(0.04)) && studio.sourceShapePreview(for: parent.id) == nil)
                    try studio.saveScene(to: scene(name))
                    let saved = try decoded(name)
                    try persist(saved, name + "-saved")
                    try check(name + "RealSave", saved.sourcePluginState == state
                        && saved.sourcePluginLibrary == request.selection
                        && saved.sourcePluginLibraryConfiguration == request.configuration
                        && saved.object(child.id)?.parent == parent.id && saved.object(child.id)?.sourceAttachmentPoint == 17)
                }
                try String(ProcessInfo.processInfo.processIdentifier).write(to: directory.appendingPathComponent("save-pid.txt"), atomically: true, encoding: .utf8)
            case .reopen:
                let savePID = try String(contentsOf: directory.appendingPathComponent("save-pid.txt"), encoding: .utf8)
                try check("freshProcess", savePID != String(ProcessInfo.processInfo.processIdentifier))
                // A fixed independent host matrix proves reads occurred before
                // *all* saved fields overwrite initializer results. It creates
                // no source preview and is not an original-geometry oracle.
                for name in ["zero", "attachment", "plain", "poison"] {
                    let saved = try decoded(name), kind = name == "zero" ? "attachment" : name
                    let request = requests[kind]!, resolution = resolutions[kind]!
                    var calls: [[String: String]] = []
                    var matrix = matrix_identity_float4x4; matrix.columns.3 = SIMD4<Float>(7, 11, 13, 1)
                    let resolver: SourceStudioPluginWorld.AttachmentResolver = { child, parent in
                        calls.append(["child": child.id.uuidString, "parent": parent.id.uuidString])
                        return (matrix, simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
                    }
                    var restored: SourceStudioPluginState?, error: String?
                    do {
                        let session = try SourceStudioPluginSession(selection: request.selection, resolution: resolution,
                            configuration: request.configuration, document: saved, restoring: saved.sourcePluginState, attachment: resolver)
                        restored = try session.savedDocument().sourcePluginState
                    } catch SourcePluginError.runtime(let reason) { error = reason }
                    try persist(calls, name + "-oracle-calls")
                    let expectedReads = name == "attachment" || name == "poison" ? 2 : 0
                    let child = saved.objects.first { $0.sourceObjectKey == 12 }!
                    try check(name + "ReadOracle", calls.count == expectedReads && calls.allSatisfy {
                        $0["child"] == child.id.uuidString && $0["parent"] == child.parent?.uuidString
                    })
                    try check(name + "RestoreOracle", name == "poison" ? error == arithmetic : error == nil && restored == saved.sourcePluginState)
                }
                for name in ["zero", "plain"] {
                    let saved = try decoded(name)
                    try studio.loadScene(from: scene(name))
                    try check(name + "OpenControl", studio.doc.sourcePluginState == saved.sourcePluginState
                        && studio.doc.sourcePluginLibrary == saved.sourcePluginLibrary
                        && studio.doc.sourcePluginLibraryConfiguration == saved.sourcePluginLibraryConfiguration
                        && !studio.sourcePluginsRunning && studio.sourceAnimationTime == 0)
                }
                let candidate = try decoded("attachment")
                var live = candidate
                live.sourcePluginState = nil; live.sourcePluginLibrary = nil; live.sourcePluginLibraryConfiguration = nil
                live.sourceNativePlugins = nil
                let parentID = live.objects.first { $0.sourceCharacter != nil }!.id
                let targetID = live.objects.first { $0.sourceObjectKey == 13 }!.id
                live.objects[live.index(of: parentID)!].visible = true
                studio.newScene(); studio.doc = live
                let retained = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: requestFile))
                guard let binding = retained.configuration.bindings.first, retained.configuration.bindings.count == 1 else {
                    throw SourcePluginError.invalid("Retained library needs one controlled component binding.")
                }
                let retainedConfiguration = SourceStudioPluginConfiguration(fixedDeltaTime: retained.configuration.fixedDeltaTime,
                    bindings: [.init(guid: binding.guid, type: binding.type, objectID: targetID)])
                try await studio.mountSourcePluginLibrary(selection: retained.selection, configuration: retainedConfiguration)
                studio.sourcePluginsRunning = false; studio.receiveSourceApplicationFocus(true)
                try studio.stepSourcePlugins(deltaTime: 0.06); try studio.advancePluginAnimation(by: 0.25); studio.refresh()
                try check("retainedLiveOwner", studio.sourceFocus.adapter != nil && studio.sourcePluginSession != nil
                    && studio.sourceShapePreview(for: parentID) != nil && !studio.host.renderer.currentFrame().items.isEmpty)
                try rejection("nativeAttachment", expected: gate) { try studio.loadScene(from: scene("attachment")) }
                try rejection("nativeAttachmentRepeat", expected: gate) { try studio.loadScene(from: scene("attachment")) }
                // Seed through ordinary document/history operations, as the
                // other native restore diagnostics do; never write the stacks.
                let prior = studio.doc
                studio.doc = candidate; studio.pushUndo(force: true); studio.doc = prior
                guard studio.undoStack.last == candidate else {
                    throw SourcePluginError.runtime("Unable to seed the real undo candidate.")
                }
                try rejection("undoAttachment", expected: gate, history: true) { studio.undo() }
                studio.pushUndo(force: true); studio.doc = candidate; studio.undo()
                guard studio.doc.objects == prior.objects && studio.doc.sourcePluginState == prior.sourcePluginState,
                      studio.redoStack.last == candidate, studio.sourcePluginSession != nil,
                      studio.sourceFocus.adapter != nil, studio.sourceShapePreview(for: parentID) != nil,
                      !studio.host.renderer.currentFrame().items.isEmpty else {
                    throw SourcePluginError.runtime("Unable to seed the real redo candidate.")
                }
                try rejection("redoAttachment", expected: gate, history: true) { studio.redo() }
                try rejection("nativePoison", expected: gate) { try studio.loadScene(from: scene("poison")) }
                try rejection("nativeTopology", expected: topology) { try studio.loadScene(from: scene("topology")) }

                // Failed open must not steal or cancel another current request.
                // Caller cancellation releases its waiter while the real worker
                // is held; release/drain then proves no stale commit follows.
                let barrier = Barrier()
                studio.sourcePluginPreparationHook = { barrier.hold() }
                defer { barrier.finish(); studio.sourcePluginPreparationHook = nil }
                let pending = Task { try await studio.mountSourcePluginLibrary(selection: requests["plain"]!.selection,
                    configuration: requests["plain"]!.configuration) }
                await barrier.wait()
                try check("pendingEntered", studio.sourcePluginLibraryPending && studio.sourcePluginMountRequest != nil)
                try rejection("pendingNativeAttachment", expected: gate) { try studio.loadScene(from: scene("attachment")) }
                let held = try snapshot(), heldFrame = try frame("pending-held")
                pending.cancel()
                var cancelled = false
                do { try await pending.value } catch is CancellationError { cancelled = true }
                let released = try snapshot()
                let h = held.graph
                let expected = DirectGraphObservation(state: h.state, focus: h.focus,
                    hideAdapterVisible: h.hideAdapterVisible, interfaceVisible: h.interfaceVisible, accessoryNames: h.accessoryNames,
                    showGizmos: h.showGizmos, effectiveShowGizmos: h.effectiveShowGizmos, showTimeline: h.showTimeline,
                    pending: false, request: nil)
                try persist(held, "pending-held"); try persist(released, "pending-cancelled")
                let cancelledFrame = try frame("pending-cancelled")
                try check("callerCancelledBeforeWorkerRelease", cancelled && released.graph == expected
                    && released.previewOwners == held.previewOwners && cancelledFrame == heldFrame)
                barrier.finish(); studio.sourcePluginPreparationHook = nil
                await studio.sourcePluginLibraryPreparationQueue.drain()
                let drained = try snapshot(), drainedFrame = try frame("pending-drained")
                try persist(drained, "pending-drained")
                try check("noStaleCommitAfterDrain", drained == released && drainedFrame == heldFrame)
            }
            // Verify the originally selected revision bytes remain resolvable.
            for name in names {
                let again = try requests[name]!.selection.resolve()
                try check(name + "PinnedRevisionRetained", again.translated.map(\.manifestData) == resolutions[name]!.translated.map(\.manifestData))
            }
        } catch {
            rows.append(.init(op: "libraryAttachmentReproductionFailure", ok: false, detail: String(describing: error)))
        }
        studio.sourcePluginPreparationHook = nil; studio.cancelSourcePluginLibraryMount()
        await studio.sourcePluginLibraryPreparationQueue.drain()
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}

extension PluginLibraryScenario {
    struct LibraryAttachmentAcceptance: Decodable {
        let phase: NativeProfileRestore.Phase
        let originalDirectory: String
        let directory: String
        let outputDirectory: String
        let requests: [String: String]
    }

    @MainActor private func verifyLibraryAttachmentRestore(_ configuration: LibraryAttachmentAcceptance,
                                                            app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        let original = URL(fileURLWithPath: configuration.originalDirectory)
        let directory = URL(fileURLWithPath: configuration.directory)
        let output = URL(fileURLWithPath: configuration.outputDirectory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let gate = "Source-character attachment reads during plugin installation are unsupported; no live preview was changed."
        let arithmetic = "Unsupported arithmetic operator or Int32 arithmetic."
        let readOnly = "Attachment-reading restoration cannot mutate the candidate scene, clone objects, or schedule destruction during initialization."
        let topology = "Restoring plugin initialization changed scene object topology, identities, or clone state."
        let identity = "Saved plugin profile or library bindings changed; explicit reinstallation is required."
        var rows: [StudioScenario.Report.StepResult] = []
        func check(_ name: String, _ okay: Bool, _ detail: String = "") throws {
            rows.append(.init(op: name, ok: okay, detail: detail))
            if !okay { throw SourcePluginError.runtime("Library restoration acceptance failed: " + name) }
        }
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: output.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func read(_ name: String, at root: URL) throws -> StudioDocument {
            try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword,
                from: Data(contentsOf: root.appendingPathComponent(name + ".png")))
        }
        func write(_ document: StudioDocument, _ name: String) throws -> URL {
            let url = output.appendingPathComponent(name + ".png")
            try CardIO.encode(document, keyword: CardIO.sceneKeyword, thumbnail: nil).write(to: url, options: .withoutOverwriting)
            return url
        }
        func snapshot(status: String? = nil) throws -> NativeGraphObservation {
            .init(graph: try directGraphSnapshot(studio: studio, expectedStatus: status),
                previewOwners: studio.renderedSourceCharacterPreviews.map { String(describing: ObjectIdentifier($0)) }.sorted())
        }
        func frame(_ name: String) throws -> Data {
            let bytes = try directGraphFrameBytes(studio.host.renderer.currentFrame())
            try bytes.write(to: output.appendingPathComponent(name + "-frame.json"), options: .withoutOverwriting)
            return bytes
        }
        func rejection(_ name: String, expected: String, history: Bool = false, operation: () throws -> Void) throws {
            let before = try snapshot(), beforeFrame = try frame(name + "-before")
            try persist(before, name + "-before")
            var error: String?
            do { try operation() }
            catch SourcePluginError.invalid(let reason) { error = reason }
            catch SourcePluginError.runtime(let reason) { error = reason }
            catch RigError.invalid(let reason) { error = reason }
            catch let unexpected { error = "UNEXPECTED: \(unexpected)" }
            if history { error = studio.status }
            try persist(try snapshot(), name + "-after")
            let afterFrame = try frame(name + "-after")
            let wanted = history ? "Plugin restore: \(SourcePluginError.runtime(expected))" : expected
            try check(name + "Error", error == wanted, error ?? "No rejection")
            try check(name + "State", try snapshot(status: history ? before.graph.state.status : nil) == before)
            try check(name + "Frame", afterFrame == beforeFrame)
        }
        func resourceCounts() -> [Int] {
            let s = studio.host.renderer.resources.statistics()
            return [s.meshes, s.textures, s.deformBuffers, s.hiddenBuffers, s.meshBufferBytes, s.deformBufferBytes, s.hiddenBufferBytes, s.retiring]
        }
        do {
            guard !FileManager.default.fileExists(atPath: output.path) else { throw SourcePluginError.invalid("Acceptance requires a fresh output directory.") }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            studio.stopBenchmarkTimer(); studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false; studio.showGizmos = false; studio.showTimeline = false
            let names = ["attachment", "plain", "poison", "topology", "setActive", "destroy", "unconditional"]
            guard Set(configuration.requests.keys) == Set(names) else { throw SourcePluginError.invalid("Acceptance requests differ.") }
            var requests: [String: StudioPluginLibraryRequest] = [:]
            var resolutions: [String: SourcePluginLibraryResolution] = [:]
            for name in names {
                let request = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: configuration.requests[name]!))
                let resolution = try request.selection.resolve()
                guard resolution.translated.count == 1, resolution.nativeAdapters.isEmpty else { throw SourcePluginError.invalid("Expected one IR revision.") }
                requests[name] = request; resolutions[name] = resolution
            }
            try persist(requests.mapValues(\.selection), "exact-selections")
            let attached = try read("attachment", at: original)
            let parentIndex = attached.objects.firstIndex { $0.sourceCharacter != nil }!
            let parent = attached.objects[parentIndex], parentID = parent.id, reference = parent.sourceCharacter!
            let child = attached.objects.first { $0.sourceObjectKey == 12 }!
            try check("oldSteppedScene", attached.sourcePluginLibrary == requests["attachment"]!.selection
                && attached.sourcePluginState?.clock.deltaTime == Float(0.04) && child.sourceAttachmentPoint == 17 && !parent.visible)
            try check("sourceFixture", !studio.host.renderer.currentFrame().items.isEmpty
                && studio.host.renderer.currentFrame().items.allSatisfy { $0.sourceShader == nil })
            switch configuration.phase {
            case .save:
                guard !FileManager.default.fileExists(atPath: directory.path) else { throw SourcePluginError.invalid("Mutation scenes require a fresh directory.") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for name in ["setActive", "destroy"] {
                    studio.newScene()
                    var document = attached
                    document.sourcePluginState = nil; document.sourcePluginLibrary = nil
                    document.sourcePluginLibraryConfiguration = nil; document.sourceNativePlugins = nil
                    studio.doc = document
                    let request = requests[name]!
                    try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: request.configuration)
                    studio.sourcePluginsRunning = false
                    try check(name + "Mount", studio.doc.sourcePluginState?.clock.elapsedTime == 0
                        && studio.sourceShapePreview(for: parentID) == nil && studio.doc.object(child.id)?.visible == true)
                    try studio.stepSourcePlugins(deltaTime: 0.04)
                    let state = try studio.sourcePluginSession!.savedDocument().sourcePluginState
                    try check(name + "Step", state?.clock.deltaTime == Float(0.04) && state?.pendingDestructionRoots == [])
                    try studio.saveScene(to: directory.appendingPathComponent(name + ".png"))
                    let saved = try read(name, at: directory)
                    try persist(saved, name + "-saved")
                    try check(name + "Save", saved.sourcePluginState == state && saved.sourcePluginLibrary == request.selection)
                }
                try String(ProcessInfo.processInfo.processIdentifier).write(to: directory.appendingPathComponent("save-pid.txt"), atomically: true, encoding: .utf8)
            case .reopen:
                let savePID = try String(contentsOf: directory.appendingPathComponent("save-pid.txt"), encoding: .utf8)
                let oldPID = try String(contentsOf: original.appendingPathComponent("save-pid.txt"), encoding: .utf8)
                let currentPID = String(ProcessInfo.processInfo.processIdentifier)
                try check("freshProcesses", savePID != currentPID && oldPID != currentPID)
                // A separate public-session resolver records actual initializer
                // order. Saved fields cannot expose these reads after restore.
                for name in ["poison", "setActive", "destroy"] {
                    let saved = try read(name, at: name == "poison" ? original : directory)
                    let request = requests[name]!
                    var calls: [[String: String]] = [], error: String?
                    var observed: SourceStudioPluginSession?
                    do {
                        observed = try SourceStudioPluginSession(selection: request.selection, resolution: resolutions[name]!,
                            configuration: request.configuration, document: saved, restoring: saved.sourcePluginState,
                            attachment: { child, parent in
                                calls.append(["child": child.id.uuidString, "parent": parent.id.uuidString])
                                return (matrix_identity_float4x4, simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
                            })
                    } catch SourcePluginError.runtime(let reason) { error = reason }
                    try persist(calls, name + "-oracle-calls")
                    try check(name + "TwoReadOracle", calls == Array(repeating: ["child": child.id.uuidString, "parent": parentID.uuidString], count: 2))
                    let expectedEffect: Bool
                    if name == "poison" { expectedEffect = error == arithmetic }
                    else if name == "setActive" { expectedEffect = error == nil && observed?.world.document.object(child.id)?.visible == false }
                    else { expectedEffect = error == nil && observed?.world.pendingSourceDestructionRoots() == [child.id] }
                    try check(name + "PostReadEffectOracle", expectedEffect, error ?? name)
                    if let observed { try persist(try observed.savedDocument(), name + "-oracle-document") }
                }
                for name in ["zero", "plain", "attachment"] {
                    let saved = try read(name, at: original)
                    try studio.loadScene(from: original.appendingPathComponent(name + ".png"))
                    let actual = try studio.sourcePluginSession!.savedDocument()
                    try check(name + "OldSceneOpen", studio.doc.sourcePluginState == saved.sourcePluginState
                        && actual.sourcePluginState == saved.sourcePluginState && studio.doc.sourcePluginLibrary == saved.sourcePluginLibrary
                        && !studio.sourcePluginsRunning && studio.sourceAnimationTime == 0)
                    let preview = studio.sourceShapePreview(for: parentID)
                    try check(name + "PreviewPolicy", name == "attachment" ? preview?.reference == reference : preview == nil)
                    if name == "attachment" {
                        try studio.stepSourcePlugins(deltaTime: 0.02)
                        try check("nextStepKeepsTransferredPreview", studio.sourceShapePreview(for: parentID) === preview
                            && studio.doc.sourcePluginState?.bindings == saved.sourcePluginState?.bindings)
                    }
                }
                // Nil and empty saved native arrays denote the same empty pinned
                // selection, but the read-only check uses the normalized input.
                var nilNative = attached; nilNative.sourceNativePlugins = nil
                try studio.loadScene(from: write(nilNative, "nil-native"))
                try check("nilNativeNormalization", studio.doc.sourceNativePlugins == nil
                    && studio.sourcePluginSession?.world.document.sourceNativePlugins == []
                    && studio.doc.sourcePluginState == attached.sourcePluginState && studio.sourceShapePreview(for: parentID) != nil)

                let baseline = studio.sourceShapePreview(for: parentID)!
                try check("multipleOutfits", baseline.outfitCount > 1)
                let alternate = output.appendingPathComponent("same-bytes-attachments.json")
                try Data(contentsOf: URL(fileURLWithPath: reference.attachmentCatalogFile!)).write(to: alternate, options: .withoutOverwriting)
                func changedReference(attachment: String) -> SourceStudioCharacterReference {
                    .init(sceneFile: reference.sceneFile, sceneSHA256: reference.sceneSHA256, rigFile: reference.rigFile,
                        boneCatalogFile: reference.boneCatalogFile, objectKey: reference.objectKey, makerLibraryFile: reference.makerLibraryFile,
                        attachmentCatalogFile: attachment, animationCatalogFile: reference.animationCatalogFile,
                        dynamicsFile: reference.dynamicsFile, handPatternsFile: reference.handPatternsFile, lookSettingsFile: reference.lookSettingsFile)
                }
                var candidate = attached, old = attached
                var candidateBody = baseline.savedBodyValues; candidateBody[0] = 0.85
                var oldBody = baseline.savedBodyValues; oldBody[0] = 0.15
                candidate.objects[parentIndex].sourceBodyValues = candidateBody
                old.objects[parentIndex].sourceCharacter = changedReference(attachment: alternate.path)
                old.objects[parentIndex].sourceOutfit = (baseline.coordinate + 1) % baseline.outfitCount
                old.objects[parentIndex].sourceBodyValues = oldBody; old.objects[parentIndex].visible = true
                old.sourcePluginState = nil; old.sourcePluginLibrary = nil; old.sourcePluginLibraryConfiguration = nil; old.sourceNativePlugins = nil
                studio.newScene(); studio.doc = old
                let retained = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: requestFile))
                guard let binding = retained.configuration.bindings.first, retained.configuration.bindings.count == 1,
                      let target = old.objects.first(where: { $0.sourceObjectKey == 13 }) else { throw SourcePluginError.invalid("Missing retained binding.") }
                try await studio.mountSourcePluginLibrary(selection: retained.selection, configuration: .init(fixedDeltaTime: retained.configuration.fixedDeltaTime,
                    bindings: [.init(guid: binding.guid, type: binding.type, objectID: target.id)]))
                studio.sourcePluginsRunning = false; studio.receiveSourceApplicationFocus(true)
                try studio.stepSourcePlugins(deltaTime: 0.06); try studio.setSourceAnimationTime(0.7); studio.refresh()
                let warm = studio.sourceShapePreview(for: parentID)!
                let warmPose = try warm.editedPose(bodyValues: oldBody, animationElapsed: 0.7)
                try check("retainedWarmOwner", studio.sourceFocus.adapter != nil && !studio.host.renderer.currentFrame().items.isEmpty
                    && warm.reference != reference && warm.coordinate != baseline.coordinate)
                let oracle = try SourceStudioCharacterPreview(reference: reference, resources: studio.host.renderer.resources, coordinate: parent.sourceOutfit)
                func attachment(_ preview: SourceStudioCharacterPreview, _ object: StudioObject, _ time: Float) throws -> SourceStudioPluginWorld.AttachmentFrame {
                    (try preview.attachmentMatrix(pointID: 17, fkRotations: object.sourceFKRotations ?? [:],
                        faceValues: object.sourceFaceValues, bodyValues: object.sourceBodyValues, ikTargets: object.sourceIKOverrides ?? [:],
                        kinematics: object.sourceKinematics, animationState: object.sourceAnimation, animationElapsed: time),
                     try preview.attachmentRotation(pointID: 17, fkRotations: object.sourceFKRotations ?? [:],
                        faceValues: object.sourceFaceValues, bodyValues: object.sourceBodyValues, ikTargets: object.sourceIKOverrides ?? [:],
                        kinematics: object.sourceKinematics, animationState: object.sourceAnimation, animationElapsed: time))
                }
                func matrixValues(_ m: float4x4) -> [Float] { (0..<4).flatMap { i in (0..<4).map { j in m[i][j] } } }
                let candidateParent = candidate.objects[parentIndex]
                let expected = try attachment(oracle, candidateParent, 0), oldFrame = try attachment(warm, studio.doc.objects[parentIndex], 0.7)
                try persist(matrixValues(expected.matrix), "candidate-matrix"); try persist(matrixValues(oldFrame.matrix), "warm-matrix")
                try check("sameUUIDInputsDiffer", zip(matrixValues(expected.matrix), matrixValues(oldFrame.matrix)).contains { abs($0 - $1) > 0.0001 })
                let beforePreparation = try snapshot(), beforePreparationFrame = try frame("candidate-prepare-before")
                try persist(beforePreparation, "candidate-prepare-before")
                let prepared = try studio.prepareSourcePlugins(document: candidate, attachmentRestore: .init(blockedObjects: [], animationElapsed: 0))
                defer { prepared.abort() }
                guard let context = prepared.restoredAttachments else { throw SourcePluginError.runtime("No library candidate context.") }
                let afterPreparation = resourceCounts()
                let actual = try context.frame(child: child, parent: candidateParent), again = try context.frame(child: child, parent: candidateParent)
                try persist(matrixValues(actual.matrix), "prepared-matrix")
                try persist(["before": beforePreparation.graph.state.resources,
                    "afterPreparation": afterPreparation, "afterRepeatedReads": resourceCounts()], "candidate-resource-counts")
                try check("candidateReadsSharePrivatePreview", actual.matrix == expected.matrix && actual.rotation.vector == expected.rotation.vector
                    && again.matrix == actual.matrix && resourceCounts() == afterPreparation && studio.sourceShapePreview(for: parentID) === warm)
                try check("preparedSavedStateExact", prepared.session?.world.document.sourcePluginLibrary == candidate.sourcePluginLibrary
                    && prepared.document.sourcePluginState == candidate.sourcePluginState && context.didReadAttachment)
                var alteredParent = candidateParent; alteredParent.sourceOutfit = warm.coordinate
                var mismatch = ""
                do { _ = try context.frame(child: child, parent: alteredParent) }
                catch SourcePluginError.invalid(let reason) { mismatch = reason }
                try check("candidateCoordinateGuard", mismatch == "Plugin attachment parent differs from the candidate reference or outfit."
                    && resourceCounts() == afterPreparation)
                prepared.abort()
                let afterAbort = try snapshot(), afterAbortFrame = try frame("candidate-prepare-after")
                let afterWarmPose = try warm.editedPose(bodyValues: oldBody, animationElapsed: 0.7)
                try persist(afterAbort, "candidate-prepare-after")
                try check("candidateAbortRetainsWarm", afterAbort == beforePreparation && afterAbortFrame == beforePreparationFrame
                    && afterWarmPose.localMatrices == warmPose.localMatrices)

                try rejection("detachedRestore", expected: gate) { let value = try studio.prepareSourcePlugins(document: candidate); value.abort() }
                let install = requests["unconditional"]!
                try rejection("initialInstall", expected: gate) {
                    let value = try studio.prepareSourcePluginLibrary(selection: install.selection, resolution: resolutions["unconditional"]!,
                        configuration: install.configuration, document: candidate,
                        attachmentRestore: .init(blockedObjects: [], animationElapsed: 0))
                    value.abort()
                }
                var blocked = candidate
                blocked.objects[parentIndex].sourceCharacter = changedReference(attachment: output.appendingPathComponent("absent-attachment.json").path)
                let blockedError = "Character '\(parent.name)' has an unresolved resource reference; see the source compatibility details."
                var changedIdentity = blocked
                changedIdentity.sourcePluginLibraryConfiguration = .init(fixedDeltaTime: 0.03, bindings: candidate.sourcePluginLibraryConfiguration!.bindings)
                var packageJSON = try JSONSerialization.jsonObject(with: encoder.encode(blocked)) as! [String: Any]
                var packageState = packageJSON["sourcePluginState"] as! [String: Any]
                var packagePins = packageState["packages"] as! [[String: Any]]
                packagePins[0]["manifestSHA256"] = String(repeating: "0", count: 64)
                packageState["packages"] = packagePins; packageJSON["sourcePluginState"] = packageState
                let changedPackage = try JSONDecoder().decode(StudioDocument.self, from: JSONSerialization.data(withJSONObject: packageJSON))
                var queuedJSON = try JSONSerialization.jsonObject(with: encoder.encode(candidate)) as! [String: Any]
                var queuedState = queuedJSON["sourcePluginState"] as! [String: Any]
                queuedState["pendingDestructionRoots"] = [child.id.uuidString]; queuedJSON["sourcePluginState"] = queuedState
                let queued = try JSONDecoder().decode(StudioDocument.self, from: JSONSerialization.data(withJSONObject: queuedJSON))
                let poison = try read("poison", at: original)
                let failures: [(String, StudioDocument, String)] = [
                    ("latePoison", poison, arithmetic), ("latePoisonRepeat", poison, arithmetic),
                    ("setActive", try read("setActive", at: directory), readOnly),
                    ("destroy", try read("destroy", at: directory), readOnly), ("savedPending", queued, readOnly),
                    ("topology", try read("topology", at: original), topology),
                    ("blockedCandidate", blocked, blockedError), ("identityBeforeBlockedRead", changedIdentity, identity),
                    ("packageBeforeBlockedRead", changedPackage, "Saved plugin package identity or version changed.")]
                for (name, rejected, error) in failures {
                    let url = try write(rejected, "reject-" + name)
                    try rejection(name, expected: error) { try studio.loadScene(from: url) }
                }
                let retainedDocument = studio.doc
                studio.doc = poison; studio.pushUndo(force: true); studio.doc = retainedDocument
                try rejection("undoPoison", expected: arithmetic, history: true) { studio.undo() }
                studio.pushUndo(force: true); studio.doc = poison; studio.undo()
                guard studio.doc.objects == retainedDocument.objects, studio.redoStack.last == poison else { throw SourcePluginError.runtime("Unable to seed redo poison.") }
                try rejection("redoPoison", expected: arithmetic, history: true) { studio.redo() }
                for name in ["zero", "plain", "attachment"] {
                    let saved = name == "attachment" ? candidate : try read(name, at: original)
                    let prior = studio.doc
                    studio.doc = saved; studio.pushUndo(force: true); studio.doc = prior
                    studio.undo()
                    let stateMatches = studio.doc.sourcePluginState == saved.sourcePluginState && studio.doc.sourcePluginLibrary == saved.sourcePluginLibrary
                    try check(name + "HistoryUndo", studio.doc.objects == saved.objects && stateMatches && studio.sourceAnimationTime == 0.7, studio.status)
                    if name != "attachment" {
                        try check(name + "HistoryPreviewPolicy", studio.sourceShapePreview(for: parentID) == nil)
                    }
                    if name == "attachment" {
                        let preview = studio.sourceShapePreview(for: parentID)!
                        let expectedHistory = try attachment(oracle, candidateParent, 0.7), actualHistory = try attachment(preview, candidateParent, 0.7)
                        try persist(matrixValues(expectedHistory.matrix), "expected-history-matrix")
                        try persist(matrixValues(actualHistory.matrix), "history-matrix")
                        try check("historyCandidateClockAndOwner", preview !== warm && preview.reference == reference
                            && actualHistory.matrix == expectedHistory.matrix && actualHistory.rotation.vector == expectedHistory.rotation.vector)
                    }
                    studio.redo()
                    try check(name + "HistoryRedo", studio.doc.objects == prior.objects && studio.doc.sourcePluginState == prior.sourcePluginState
                        && studio.doc.sourcePluginLibrary == prior.sourcePluginLibrary && studio.sourceAnimationTime == 0.7, studio.status)
                }

                let barrier = Barrier(); studio.sourcePluginPreparationHook = { barrier.hold() }
                defer { barrier.finish(); studio.sourcePluginPreparationHook = nil }
                let pending = Task { try await studio.mountSourcePluginLibrary(selection: requests["plain"]!.selection, configuration: requests["plain"]!.configuration) }
                await barrier.wait()
                try check("pendingEntered", studio.sourcePluginLibraryPending && studio.sourcePluginMountRequest != nil)
                try rejection("pendingLatePoison", expected: arithmetic) { try studio.loadScene(from: original.appendingPathComponent("poison.png")) }
                let held = try snapshot(), heldFrame = try frame("pending-held")
                pending.cancel(); var cancelled = false
                do { try await pending.value } catch is CancellationError { cancelled = true }
                let cancelledState = try snapshot(), h = held.graph
                let expectedCancelled = DirectGraphObservation(state: h.state, focus: h.focus, hideAdapterVisible: h.hideAdapterVisible,
                    interfaceVisible: h.interfaceVisible, accessoryNames: h.accessoryNames, showGizmos: h.showGizmos,
                    effectiveShowGizmos: h.effectiveShowGizmos, showTimeline: h.showTimeline, pending: false, request: nil)
                try persist(held, "pending-held"); try persist(cancelledState, "pending-cancelled")
                try check("callerCancelsBeforeRelease", cancelled && cancelledState.graph == expectedCancelled
                    && cancelledState.previewOwners == held.previewOwners && frame("pending-cancelled") == heldFrame)
                barrier.finish(); studio.sourcePluginPreparationHook = nil
                await studio.sourcePluginLibraryPreparationQueue.drain()
                try persist(try snapshot(), "pending-drained")
                try check("cancelledDrainExact", try snapshot() == cancelledState && frame("pending-drained") == heldFrame)

                let replacement = Barrier(); studio.sourcePluginPreparationHook = { replacement.hold() }
                defer { replacement.finish(); studio.sourcePluginPreparationHook = nil }
                let superseded = Task { try await studio.mountSourcePluginLibrary(selection: requests["plain"]!.selection, configuration: requests["plain"]!.configuration) }
                await replacement.wait()
                let candidateURL = try write(candidate, "valid-candidate")
                try studio.loadScene(from: candidateURL)
                var invalidated = false
                do { try await superseded.value } catch is CancellationError { invalidated = true }
                let committed = studio.sourceShapePreview(for: parentID)
                let accepted = try snapshot(), acceptedFrame = try frame("replacement-accepted")
                try persist(accepted, "replacement-accepted")
                try check("nativeOpenInvalidatesPending", invalidated && !studio.sourcePluginLibraryPending && studio.sourcePluginMountRequest == nil
                    && studio.doc.sourcePluginState == candidate.sourcePluginState && committed?.reference == reference && studio.sourceAnimationTime == 0)
                replacement.finish(); studio.sourcePluginPreparationHook = nil
                await studio.sourcePluginLibraryPreparationQueue.drain()
                try persist(try snapshot(), "replacement-drained")
                try check("supersededDrainExact", try snapshot() == accepted && frame("replacement-drained") == acceptedFrame)
                var blockedOld = blocked
                blockedOld.sourcePluginState = nil; blockedOld.sourcePluginLibrary = nil
                blockedOld.sourcePluginLibraryConfiguration = nil; blockedOld.sourceNativePlugins = nil
                try studio.loadScene(from: write(blockedOld, "blocked-old"))
                try check("oldBlockedPrecondition", studio.resourceBlockedObjects.contains(parentID))
                try studio.loadScene(from: candidateURL)
                let transferred = studio.sourceShapePreview(for: parentID)
                try check("candidateOverridesOldBlock", !studio.resourceBlockedObjects.contains(parentID) && transferred?.reference == reference)
                studio.update(parentID) { $0.visible = true }
                try studio.stepSourcePlugins(deltaTime: 0.02)
                try check("showAndStepReuse", studio.sourceShapePreview(for: parentID) === transferred
                    && studio.doc.sourcePluginState?.bindings.first?.awake == true && studio.doc.sourcePluginState?.bindings.first?.started == true)
            }
            for name in names {
                let again = try requests[name]!.selection.resolve()
                try check(name + "RevisionUnchanged", again.translated.map(\.manifestData) == resolutions[name]!.translated.map(\.manifestData))
            }
        } catch { rows.append(.init(op: "libraryAttachmentAcceptanceFailure", ok: false, detail: String(describing: error))) }
        studio.sourcePluginPreparationHook = nil; studio.cancelSourcePluginLibraryMount()
        await studio.sourcePluginLibraryPreparationQueue.drain()
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}

extension PluginLibraryScenario {
    struct PendingAttachmentRestore: Decodable {
        let phase: NativeProfileRestore.Phase
        let directory: String, outputDirectory: String
        let requests: [String: String], profiles: [String: String]
    }
    private struct PendingAttachmentContinuation: Codable {
        let document: StudioDocument
        let callbacks: [String]
    }

    /// Observe the documented pending-root/read-only-restore boundary using
    /// genuine paused snapshots. No saved pending roots or fields are fabricated.
    @MainActor private func reproducePendingAttachmentRestore(_ configuration: PendingAttachmentRestore,
                                                               app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        let output = URL(fileURLWithPath: configuration.outputDirectory)
        let directory = URL(fileURLWithPath: configuration.directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let policy = SourcePluginError.invalid("Attachment-reading restoration cannot mutate the candidate scene, clone objects, or schedule destruction during initialization.").description
        let names = ["readerPending", "plainPending", "readerNoPending"]
        var rows: [StudioScenario.Report.StepResult] = []
        func check(_ name: String, _ okay: Bool, _ detail: String = "") throws {
            rows.append(.init(op: name, ok: okay, detail: detail))
            if !okay { throw SourcePluginError.runtime("Pending attachment diagnostic failed: " + name) }
        }
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: output.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func scene(_ name: String) -> URL { directory.appendingPathComponent(name + ".png") }
        func decoded(_ name: String) throws -> StudioDocument {
            try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: Data(contentsOf: scene(name)))
        }
        func snapshot(status: String? = nil) throws -> NativeGraphObservation {
            .init(graph: try directGraphSnapshot(studio: studio, expectedStatus: status),
                previewOwners: studio.renderedSourceCharacterPreviews.map { String(describing: ObjectIdentifier($0)) }.sorted())
        }
        func capture(_ name: String) throws -> (state: NativeGraphObservation, frame: Data) {
            let value = try snapshot(), frame = try directGraphFrameBytes(studio.host.renderer.currentFrame())
            try persist(value, name)
            try frame.write(to: output.appendingPathComponent(name + "-frame.json"), options: .withoutOverwriting)
            return (value, frame)
        }
        func warmObservation(_ preview: SourceStudioCharacterPreview?) throws -> InstallWarmObservation? {
            guard let preview else { return nil }
            let body = preview.sourceBodyValues, face = preview.sourceFaceValues, diagnostics = preview.diagnostics
            let pose = try preview.editedPose(faceValues: face, bodyValues: body, animationElapsed: 0.7)
            let matrices = pose.localMatrices.map { m in (0..<4).flatMap { c in (0..<4).map { r in m[c][r].bitPattern } } }
            return .init(body: body, face: face, diagnostics: diagnostics, matrices: matrices)
        }
        func seedHistory(_ action: String, candidate: StudioDocument) throws {
            let prior = studio.doc
            if action == "undo" {
                studio.doc = candidate; studio.pushUndo(force: true); studio.doc = prior
            } else if action == "redo" {
                studio.pushUndo(force: true); studio.doc = candidate; studio.undo()
                guard studio.doc.objects == prior.objects, studio.doc.sourcePluginState == prior.sourcePluginState,
                      studio.redoStack.last == candidate else { throw SourcePluginError.runtime("Unable to seed real pending-attachment redo.") }
            }
        }
        do {
            guard !FileManager.default.fileExists(atPath: output.path) else { throw SourcePluginError.invalid("Pending attachment output already exists.") }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            studio.stopBenchmarkTimer(); studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false; studio.showGizmos = false; studio.showTimeline = false
            guard Set(configuration.requests.keys) == Set(names), Set(configuration.profiles.keys) == Set(names),
                  let template = studio.doc.objects.first(where: { $0.sourceCharacter != nil }),
                  template.sourceCharacter?.attachmentCatalogFile != nil else { throw SourcePluginError.invalid("Missing pending attachment inputs.") }
            let sourceFile = studio.doc.sourceSceneFile, sourceSHA = studio.doc.sourceSceneSHA256
            try check("sourceFixture", !studio.host.renderer.currentFrame().items.isEmpty
                && studio.host.renderer.currentFrame().items.allSatisfy { $0.sourceShader == nil })
            var requests: [String: StudioPluginLibraryRequest] = [:], profiles: [String: URL] = [:]
            for name in names {
                let request = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: configuration.requests[name]!))
                let resolution = try request.selection.resolve(), profile = URL(fileURLWithPath: configuration.profiles[name]!)
                let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: profile)) as? [String: Any]
                guard let packages = raw?["packages"] as? [[String: Any]], packages.count == 1,
                      let manifest = packages[0]["manifest"] as? String, manifest.hasPrefix("/"),
                      let bindings = packages[0]["bindings"] as? [[String: Any]],
                      resolution.translated.count == 1, resolution.nativeAdapters.isEmpty else { throw SourcePluginError.invalid("Expected paired pending IR package.") }
                let original = try SourcePluginPackage.load(url: URL(fileURLWithPath: manifest)), selected = resolution.translated[0]
                var equal = original.manifestData == selected.manifestData
                for component in original.manifest.components {
                    equal = try equal && (Data(contentsOf: original.manifestURL.deletingLastPathComponent().appendingPathComponent(component.program.file))
                        == Data(contentsOf: selected.manifestURL.deletingLastPathComponent().appendingPathComponent(component.program.file)))
                }
                let expectedBindings: [[String: Any]] = [["type": "PendingReader", "sourceObjectKey": 12], ["type": "PendingTarget", "sourceObjectKey": 11]]
                let pairedBindings = try JSONSerialization.data(withJSONObject: bindings, options: [.sortedKeys])
                    == JSONSerialization.data(withJSONObject: expectedBindings, options: [.sortedKeys])
                try check(name + "ExactPackage", equal && pairedBindings && request.configuration.bindings.map(\.type) == ["PendingReader", "PendingTarget"]
                    && request.configuration.bindings.map(\.sourceObjectKey) == [12, 11]
                    && request.configuration.bindings.allSatisfy { $0.guid.utf8.elementsEqual(original.manifest.identity.guid.utf8) }
                    && request.configuration.fixedDeltaTime == Float(0.02)
                    && (raw?["fixedDeltaTime"] as? NSNumber)?.floatValue == Float(0.02))
                requests[name] = request; profiles[name] = profile
            }
            let retained = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: requestFile))
            guard let binding = retained.configuration.bindings.first, retained.configuration.bindings.count == 1 else { throw SourcePluginError.invalid("Missing retained mixed plugin binding.") }
            func seed(_ candidate: StudioDocument, warm: Bool) async throws {
                studio.newScene(); var base = candidate
                base.sourcePluginState = nil; base.sourcePluginLibrary = nil; base.sourcePluginLibraryConfiguration = nil; base.sourceNativePlugins = nil
                base.objects[0].visible = warm; studio.doc = base
                try await studio.mountSourcePluginLibrary(selection: retained.selection, configuration: .init(fixedDeltaTime: retained.configuration.fixedDeltaTime,
                    bindings: [.init(guid: binding.guid, type: binding.type, sourceObjectKey: 11)]))
                studio.sourcePluginsRunning = false; studio.receiveSourceApplicationFocus(true)
                try studio.stepSourcePlugins(deltaTime: 0.04); try studio.setSourceAnimationTime(0.7); studio.refresh()
            }
            switch configuration.phase {
            case .save:
                guard !FileManager.default.fileExists(atPath: directory.path) else { throw SourcePluginError.invalid("Pending attachment scenes require fresh output.") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try String(ProcessInfo.processInfo.processIdentifier).write(to: directory.appendingPathComponent("save-pid.txt"), atomically: false, encoding: .utf8)
                for origin in ["profile", "library"] { for variant in names {
                    let name = origin + "-" + variant, request = requests[variant]!, pending = variant != "readerNoPending"
                    studio.newScene()
                    var parent = template; parent.id = UUID(); parent.parent = nil; parent.visible = false; parent.transform = StudioTransform()
                    var reader = StudioObject(name: "Pending attachment reader", kind: .folder)
                    reader.sourceObjectKey = 12; reader.parent = parent.id; reader.sourceAttachmentPoint = 17
                    var target = StudioObject(name: "Unrelated Awake target", kind: .folder); target.sourceObjectKey = 11
                    var descendant = StudioObject(name: "Unbound pending descendant", kind: .folder); descendant.parent = target.id
                    var base = StudioDocument(); base.sourceSceneFile = sourceFile; base.sourceSceneSHA256 = sourceSHA
                    base.objects = [parent, reader, target, descendant]; studio.doc = base
                    if origin == "profile" {
                        try studio.loadSourcePluginProfileInteractively(profileURL: profiles[variant]!, expectedGeneration: studio.sourcePluginMountGeneration)
                    } else { try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: request.configuration) }
                    studio.sourcePluginsRunning = false
                    guard let session = studio.sourcePluginSession else { throw SourcePluginError.runtime("Missing mounted pending session.") }
                    let mounted = try session.savedDocument(), state = mounted.sourcePluginState!
                    try persist(mounted, name + "-mounted"); try persist(session.runtime.callbackTrace, name + "-mounted-callbacks")
                    try check(name + "ActualMount", state.bindings.count == 2 && state.clock.elapsedTime == 0 && state.clock.deltaTime == 0
                        && state.cloneSerial == 0 && (studio.sourceShapePreview(for: parent.id) != nil) == (variant != "plainPending")
                        && (origin == "library" ? mounted.sourcePluginLibrary == request.selection : mounted.sourcePluginLibrary == nil))
                    let targetBinding = state.bindings.first { $0.type == "PendingTarget" }
                    let roots = pending ? [target.id] : []
                    let expanded = pending ? Set([target.id, descendant.id].compactMap { state.objectIdentities[$0] }) : Set<String>()
                    try check(name + "PausedRoots", state.pendingDestructionRoots == roots
                        && Set(session.world.pendingSourceDestruction().map(\.sourceIdentity)) == expanded
                        && state.objectIdentities.count == base.objects.count
                        && targetBinding?.awake == true && targetBinding?.started == false && targetBinding?.destroyed == false
                        && !roots.contains(parent.id) && !base.isDescendant(reader.id, of: target.id))
                    let beforeTrace = session.runtime.callbackTrace
                    try check(name + "InitialCallbacks", beforeTrace.map { $0.components(separatedBy: ":").last! }
                        == (pending ? ["Awake"] : ["Awake", "OnEnable"]))
                    // Saving cannot drain the queue. The original session is
                    // stepped only after the actual native bytes are retained.
                    try studio.saveScene(to: scene(name)); let saved = try decoded(name)
                    try persist(saved, name + "-saved")
                    try check(name + "ActualSave", saved.sourcePluginState == state && saved.objects == mounted.objects
                        && session.runtime.callbackTrace == beforeTrace && session.world.pendingSourceDestructionRoots() == roots)
                    try studio.stepSourcePlugins(deltaTime: 0.02)
                    let continued = try session.savedDocument()
                    let callbacks = Array(session.runtime.callbackTrace.dropFirst(beforeTrace.count))
                    let oracle = PendingAttachmentContinuation(document: continued, callbacks: callbacks)
                    try encoder.encode(oracle).write(to: directory.appendingPathComponent(name + "-continuation.json"), options: .withoutOverwriting)
                    try persist(oracle, name + "-continuation")
                    try check(name + "OriginalContinuation", continued.sourcePluginState?.clock.elapsedTime == Double(Float(0.02))
                        && continued.sourcePluginState?.pendingDestructionRoots == []
                        && (continued.object(target.id) == nil) == pending && (continued.object(descendant.id) == nil) == pending
                        && continued.sourcePluginState?.objectIdentities == state.objectIdentities
                        && continued.sourcePluginState?.bindings.first(where: { $0.type == "PendingTarget" })?.destroyed == pending
                        && callbacks.map { $0.components(separatedBy: ":").last! } == (pending ? ["OnDestroy"] : ["Start"]))
                } }
            case .reopen:
                let savedPID = try String(contentsOf: directory.appendingPathComponent("save-pid.txt"), encoding: .utf8)
                try check("freshProcessBoundary", savedPID != String(ProcessInfo.processInfo.processIdentifier))
                for origin in ["profile", "library"] { for variant in names {
                    let name = origin + "-" + variant, saved = try decoded(name), state = saved.sourcePluginState!
                    let expected = try JSONDecoder().decode(PendingAttachmentContinuation.self,
                        from: Data(contentsOf: directory.appendingPathComponent(name + "-continuation.json")))
                    let parentID = saved.objects[0].id, childID = saved.objects[1].id
                    // A counted public session is independent of the app policy.
                    // It restores the same genuine roots and replays two reads
                    // before restoring all saved fields; no app preview is used.
                    var calls: [[String: String]] = []
                    let resolver: SourceStudioPluginWorld.AttachmentResolver = { child, parent in
                        calls.append(["child": child.id.uuidString, "parent": parent.id.uuidString])
                        var matrix = matrix_identity_float4x4; matrix.columns.3 = SIMD4<Float>(7, 11, 13, 1)
                        return (matrix, simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
                    }
                    let independent: SourceStudioPluginSession
                    if origin == "profile" { independent = try SourceStudioPluginSession(profileURL: profiles[variant]!, document: saved, restoring: state, attachment: resolver) }
                    else {
                        let request = requests[variant]!
                        independent = try SourceStudioPluginSession(selection: request.selection, resolution: request.selection.resolve(),
                            configuration: request.configuration, document: saved, restoring: state, attachment: resolver)
                    }
                    try persist(calls, name + "-oracle-calls")
                    try persist(try independent.savedDocument(), name + "-oracle-restored")
                    try check(name + "CountedRestore", calls == Array(repeating: ["child": childID.uuidString, "parent": parentID.uuidString], count: variant == "plainPending" ? 0 : 2)
                        && independent.world.pendingSourceDestructionRoots() == state.pendingDestructionRoots
                        && independent.runtime.callbackTrace.isEmpty && (try independent.savedDocument().sourcePluginState) == state)
                    let continuation = try independent.step(document: saved, deltaTime: 0.02)
                    try persist(PendingAttachmentContinuation(document: continuation, callbacks: independent.runtime.callbackTrace), name + "-oracle-continuation")
                    try check(name + "CountedContinuation", continuation.objects == expected.document.objects
                        && continuation.sourcePluginState == expected.document.sourcePluginState && independent.runtime.callbackTrace == expected.callbacks)
                    if variant != "readerPending" {
                        for action in ["open", "undo", "redo"] {
                            let prefix = name + "-" + action
                            try await seed(saved, warm: false); try seedHistory(action, candidate: saved)
                            if action == "open" { try studio.loadScene(from: scene(name)) }
                            else if action == "undo" { studio.undo() } else { studio.redo() }
                            let restored = try studio.sourcePluginSession?.savedDocument()
                            try persist(restored, prefix + "-restored")
                            try check(prefix + "ControlRestored", restored?.objects == saved.objects && restored?.sourcePluginState == state
                                && studio.sourcePluginSession?.runtime.callbackTrace == []
                                && (studio.sourceShapePreview(for: parentID) != nil) == (variant != "plainPending") && !studio.sourcePluginsRunning)
                            try studio.stepSourcePlugins(deltaTime: 0.02)
                            let actual = try studio.sourcePluginSession?.savedDocument()
                            try persist(actual, prefix + "-continued")
                            try persist(studio.sourcePluginSession?.runtime.callbackTrace, prefix + "-callbacks")
                            try check(prefix + "ControlContinuation", actual?.objects == expected.document.objects
                                && actual?.sourcePluginState == expected.document.sourcePluginState
                                && studio.sourcePluginSession?.runtime.callbackTrace == expected.callbacks)
                        }
                    } else {
                        for warm in [false, true] { for action in ["open", "undo", "redo"] {
                            let prefix = name + (warm ? "-warm-" : "-cold-") + action
                            try await seed(saved, warm: warm); try seedHistory(action, candidate: saved)
                            let preview = studio.sourceShapePreview(for: parentID)
                            if warm, let preview {
                                var body = preview.savedBodyValues, face = preview.savedFaceValues
                                body[0] = body[0] < 0.5 ? 0.8 : 0.2; face[33] = face[33] < 0.5 ? 0.8 : 0.2
                                _ = try preview.editedPose(faceValues: face, bodyValues: body, animationElapsed: 0.7)
                            }
                            try check(prefix + "Prior", (preview != nil) == warm && studio.sourcePluginSession != nil
                                && studio.sourceFocus.adapter != nil && studio.sourceAccessoryNamesEnabled && !studio.sourcePluginsRunning
                                && (action != "undo" || studio.undoStack.last == saved) && (action != "redo" || studio.redoStack.last == saved))
                            let warmBefore = try warmObservation(preview); try persist(warmBefore, prefix + "-warm-before")
                            let before = try capture(prefix + "-before"), oldSession = studio.sourcePluginSession, oldFocus = studio.sourceFocus.adapter
                            var error = "NO REJECTION"
                            if action == "open" { do { try studio.loadScene(from: scene(name)) } catch let caught { error = String(describing: caught) } }
                            else { if action == "undo" { studio.undo() } else { studio.redo() }; error = studio.status }
                            let warmAfter = try warmObservation(studio.sourceShapePreview(for: parentID)); try persist(warmAfter, prefix + "-warm-after")
                            let after = try capture(prefix + "-after"); try persist(["error": error], prefix + "-outcome")
                            try check(prefix + "PolicyRejected", error == (action == "open" ? policy : "Plugin restore: " + policy), error)
                            let comparable = action == "open" ? after.state : try snapshot(status: before.state.graph.state.status)
                            try check(prefix + "StateRetained", comparable == before.state
                                && studio.sourcePluginSession === oldSession && studio.sourceFocus.adapter === oldFocus
                                && studio.sourceShapePreview(for: parentID) === preview)
                            try check(prefix + "WarmRetained", warmAfter == warmBefore)
                            try check(prefix + "FrameRetained", after.frame == before.frame)
                        } }
                    }
                } }
            }
        } catch { rows.append(.init(op: "pendingAttachmentReproductionFailure", ok: false, detail: String(describing: error))) }
        studio.sourcePluginsRunning = false
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}

extension PluginLibraryScenario {
    struct PendingAttachmentAcceptance: Decodable {
        enum Phase: String, Decodable { case save, reopen, policy }
        let phase: Phase
        let directory: String, outputDirectory: String
        let requests: [String: String], profiles: [String: String]
    }

    @MainActor private func verifyPendingAttachmentAcceptance(_ configuration: PendingAttachmentAcceptance,
                                                              app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        let names = ["readerPending", "plainPending", "readerNoPending"]
        // Keep the actual paused-save/original-continuation producer identical
        // to the independently accepted diagnostic. Only the consumer changes.
        if configuration.phase == .save {
            return await reproducePendingAttachmentRestore(.init(phase: .save, directory: configuration.directory,
                outputDirectory: configuration.outputDirectory,
                requests: configuration.requests.filter { names.contains($0.key) },
                profiles: configuration.profiles.filter { names.contains($0.key) }), app: app, studio: studio)
        }
        let directory = URL(fileURLWithPath: configuration.directory), output = URL(fileURLWithPath: configuration.outputDirectory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var rows: [StudioScenario.Report.StepResult] = []
        func check(_ name: String, _ okay: Bool, _ detail: String = "") throws {
            rows.append(.init(op: name, ok: okay, detail: detail))
            if !okay { throw SourcePluginError.runtime("Pending attachment acceptance failed: " + name) }
        }
        func persist<T: Encodable>(_ value: T, _ name: String) throws {
            try encoder.encode(value).write(to: output.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
        }
        func resourceCounts() -> [Int] {
            let s = studio.host.renderer.resources.statistics()
            return [s.meshes, s.textures, s.deformBuffers, s.hiddenBuffers, s.meshBufferBytes, s.deformBufferBytes, s.hiddenBufferBytes, s.retiring]
        }
        func decoded(_ name: String) throws -> StudioDocument {
            try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword,
                from: Data(contentsOf: directory.appendingPathComponent(name + ".png")))
        }
        func snapshot(status: String? = nil) throws -> NativeGraphObservation {
            .init(graph: try directGraphSnapshot(studio: studio, expectedStatus: status),
                  previewOwners: studio.renderedSourceCharacterPreviews.map { String(describing: ObjectIdentifier($0)) }.sorted())
        }
        func capture(_ name: String) throws -> (state: NativeGraphObservation, frame: Data) {
            let state = try snapshot(), frame = try directGraphFrameBytes(studio.host.renderer.currentFrame())
            try persist(state, name); try frame.write(to: output.appendingPathComponent(name + "-frame.json"), options: .withoutOverwriting)
            return (state, frame)
        }
        func warmObservation(_ preview: SourceStudioCharacterPreview?) throws -> InstallWarmObservation? {
            guard let preview else { return nil }
            let body = preview.sourceBodyValues, face = preview.sourceFaceValues, diagnostics = preview.diagnostics
            let pose = try preview.editedPose(faceValues: face, bodyValues: body, animationElapsed: 0.7)
            let matrices = pose.localMatrices.map { m in (0..<4).flatMap { c in (0..<4).map { r in m[c][r].bitPattern } } }
            return .init(body: body, face: face, diagnostics: diagnostics, matrices: matrices)
        }
        func withRoots(_ document: StudioDocument, _ roots: [UUID], invalidIdentities: Bool = false) throws -> StudioDocument {
            var raw = try JSONSerialization.jsonObject(with: encoder.encode(document)) as! [String: Any]
            var state = raw["sourcePluginState"] as! [String: Any]; state["pendingDestructionRoots"] = roots.map(\.uuidString)
            if invalidIdentities {
                var identities = state["objectIdentities"] as! [String]; identities[1] = identities[3]; state["objectIdentities"] = identities
            }
            raw["sourcePluginState"] = state
            return try JSONDecoder().decode(StudioDocument.self, from: JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]))
        }
        func seedHistory(_ action: String, candidate: StudioDocument) throws {
            let prior = studio.doc
            if action == "undo" { studio.doc = candidate; studio.pushUndo(force: true); studio.doc = prior }
            else if action == "redo" {
                studio.pushUndo(force: true); studio.doc = candidate; studio.undo()
                guard studio.doc.objects == prior.objects, studio.doc.sourcePluginState == prior.sourcePluginState,
                      studio.redoStack.last == candidate else { throw SourcePluginError.runtime("Unable to seed pending acceptance redo.") }
            }
        }
        do {
            guard !FileManager.default.fileExists(atPath: output.path) else { throw SourcePluginError.invalid("Pending acceptance output already exists.") }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            studio.stopBenchmarkTimer(); studio.liveAnimation = false; app.maker?.liveAnimation = false; app.mode = .studio
            studio.sourceAutomaticBlink = false; studio.showGizmos = false; studio.showTimeline = false
            let writer = try String(contentsOf: directory.appendingPathComponent("save-pid.txt"), encoding: .utf8)
            try check("freshProcessBoundary", writer != String(ProcessInfo.processInfo.processIdentifier))
            let retained = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: requestFile))
            guard let binding = retained.configuration.bindings.first, retained.configuration.bindings.count == 1 else {
                throw SourcePluginError.invalid("Missing retained mixed plugin binding.")
            }
            func seed(_ candidate: StudioDocument, warm: Bool) async throws {
                studio.newScene(); var base = candidate
                base.sourcePluginState = nil; base.sourcePluginLibrary = nil; base.sourcePluginLibraryConfiguration = nil; base.sourceNativePlugins = nil
                base.objects[0].visible = warm; studio.doc = base
                try await studio.mountSourcePluginLibrary(selection: retained.selection, configuration: .init(fixedDeltaTime: retained.configuration.fixedDeltaTime,
                    bindings: [.init(guid: binding.guid, type: binding.type, sourceObjectKey: 11)]))
                studio.sourcePluginsRunning = false; studio.receiveSourceApplicationFocus(true)
                try studio.stepSourcePlugins(deltaTime: 0.04); try studio.setSourceAnimationTime(0.7); studio.refresh()
            }
            if configuration.phase == .reopen {
                for origin in ["profile", "library"] { for variant in names {
                    let name = origin + "-" + variant, saved = try decoded(name), state = saved.sourcePluginState!
                    let oracle = try JSONDecoder().decode(PendingAttachmentContinuation.self,
                        from: Data(contentsOf: directory.appendingPathComponent(name + "-continuation.json")))
                    let parent = saved.objects[0].id
                    // Test exact saved overlapping roots separately: ordinary
                    // native saves above preserve their genuine Awake queue.
                    for warm in (variant == "readerPending" ? [false, true] : [false]) {
                        for action in ["open", "undo", "redo"] {
                            let prefix = name + (warm ? "-warm-" : "-cold-") + action
                            try await seed(saved, warm: warm); try seedHistory(action, candidate: saved)
                            let oldPreview = studio.sourceShapePreview(for: parent).map(ObjectIdentifier.init)
                            if action == "open" { try studio.loadScene(from: directory.appendingPathComponent(name + ".png")) }
                            else if action == "undo" { studio.undo() } else { studio.redo() }
                            guard let session = studio.sourcePluginSession else { throw SourcePluginError.runtime("Missing restored pending session.") }
                            let restored = try session.savedDocument(), preview = studio.sourceShapePreview(for: parent)
                            try persist(restored, prefix + "-restored")
                            try check(prefix + "Restored", restored.objects == saved.objects && restored.sourcePluginState == state
                                && session.runtime.callbackTrace.isEmpty && !session.initializationRequestedDestruction && !studio.sourcePluginsRunning)
                            try check(prefix + "CandidatePreview", (preview != nil) == (variant != "plainPending")
                                && (!warm || preview.map(ObjectIdentifier.init) != oldPreview)
                                && preview?.reference == (variant == "plainPending" ? nil : saved.objects[0].sourceCharacter))
                            let beforeResources = resourceCounts()
                            try studio.stepSourcePlugins(deltaTime: 0.02)
                            let continued = try session.savedDocument(); try persist(continued, prefix + "-continued")
                            try persist(session.runtime.callbackTrace, prefix + "-callbacks")
                            try check(prefix + "Continuation", continued.objects == oracle.document.objects
                                && continued.sourcePluginState == oracle.document.sourcePluginState && session.runtime.callbackTrace == oracle.callbacks)
                            try check(prefix + "PreviewReused", studio.sourceShapePreview(for: parent) === preview
                                && resourceCounts() == beforeResources)
                        }
                    }
                    if variant == "readerPending" {
                        let target = saved.objects[2].id, descendant = saved.objects[3].id
                        let overlapping = try withRoots(saved, [descendant, target])
                        try await seed(overlapping, warm: false)
                        let path = output.appendingPathComponent(name + "-overlapping.png")
                        try CardIO.encode(overlapping, keyword: CardIO.sceneKeyword, thumbnail: nil).write(to: path, options: .withoutOverwriting)
                        try studio.loadScene(from: path)
                        let before = try studio.sourcePluginSession!.savedDocument(); try persist(before, name + "-overlapping-restored")
                        try check(name + "OverlappingRoots", Set(before.sourcePluginState!.pendingDestructionRoots!) == Set([target, descendant])
                            && !studio.sourcePluginSession!.initializationRequestedDestruction)
                        try studio.stepSourcePlugins(deltaTime: 0.02)
                        let after = try studio.sourcePluginSession!.savedDocument(); try persist(after, name + "-overlapping-continued")
                        try check(name + "OverlappingContinuation", after.objects == oracle.document.objects
                            && after.sourcePluginState == oracle.document.sourcePluginState && studio.sourcePluginSession!.runtime.callbackTrace == oracle.callbacks)
                    }
                } }
            } else {
                let mutationError = SourcePluginError.invalid("Attachment-reading restoration cannot mutate the candidate scene, clone objects, or schedule destruction during initialization.").description
                let overlapError = SourcePluginError.invalid("Saved pending destruction overlaps the plugin attachment parent or reader subtree.").description
                let malformedError = SourcePluginError.invalid("Invalid saved pending destruction roots.").description
                let detachedError = SourcePluginError.invalid("Source-character attachment reads during plugin installation are unsupported; no live preview was changed.").description
                var bounded = try decoded("profile-readerPending")
                var chain: [StudioObject] = []
                for index in 0..<512 {
                    var object = StudioObject(name: "Pending membership \(index)", kind: .folder)
                    object.parent = chain.last?.id; chain.append(object)
                }
                bounded.objects += chain; bounded = try withRoots(bounded, chain.map(\.id))
                // Shared validation precedes the exact helper used by the real
                // resolver. Visit counts demonstrate a linear bounded build,
                // independently of wall time and without original assets.
                _ = try SourceStudioPluginWorld(document: bounded, identities: bounded.sourcePluginState!.objectIdentities,
                    pendingDestructionRoots: bounded.sourcePluginState!.pendingDestructionRoots!)
                let membership = StudioModel.PluginAttachmentRestorePreparation.PendingMembership(document: bounded)
                try check("MembershipIndex", membership.blocked == Set(chain.map(\.id))
                    && membership.indexedObjects == bounded.objects.count && membership.descendantEdges == 511
                    && membership.ancestorEdges <= bounded.objects.count + chain.count)
                let empty = StudioModel.PluginAttachmentRestorePreparation.PendingMembership(document: try withRoots(bounded, []))
                try check("MembershipNoPending", empty.blocked.isEmpty && empty.indexedObjects == 0
                    && empty.descendantEdges == 0 && empty.ancestorEdges == 0)
                for origin in ["profile", "library"] {
                    let saved = try decoded(origin + "-readerPending"), parent = saved.objects[0].id
                    // Actual fresh install and native save for the requeue fixture:
                    // the target's initializer always calls Destroy on itself.
                    studio.newScene(); var base = saved
                    base.sourcePluginState = nil; base.sourcePluginLibrary = nil; base.sourcePluginLibraryConfiguration = nil; base.sourceNativePlugins = nil
                    studio.doc = base
                    if origin == "profile" {
                        try studio.loadSourcePlugins(profileURL: URL(fileURLWithPath: configuration.profiles["requeue"]!))
                    } else {
                        let request = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: configuration.requests["requeue"]!))
                        try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: request.configuration)
                    }
                    studio.sourcePluginsRunning = false
                    let actualPath = output.appendingPathComponent(origin + "-requeue-actual.png")
                    try studio.saveScene(to: actualPath)
                    let requeue = try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: Data(contentsOf: actualPath))
                    try persist(requeue, origin + "-requeue-actual")
                    try check(origin + "RequeueActualSave", requeue.sourcePluginState?.pendingDestructionRoots == [saved.objects[2].id]
                        && studio.sourcePluginSession?.initializationRequestedDestruction == false)
                    for kind in ["sameRoot", "newRoot", "parent", "reader", "ancestor", "descendant", "duplicate", "unknown", "tombstone", "bound", "identity", "detached"] {
                        var candidate = kind == "sameRoot" || kind == "newRoot" ? requeue : saved
                        var roots = candidate.sourcePluginState!.pendingDestructionRoots!
                        let expected: String
                        switch kind {
                        case "sameRoot": expected = mutationError
                        case "newRoot": roots = []; expected = mutationError
                        case "parent": roots = [parent]; expected = overlapError
                        case "reader": roots = [saved.objects[1].id]; expected = overlapError
                        case "ancestor":
                            let ancestor = StudioObject(name: "Pending ancestor", kind: .folder)
                            candidate.objects[0].parent = ancestor.id; candidate.objects.append(ancestor); roots = [ancestor.id]; expected = overlapError
                        case "descendant":
                            var descendant = StudioObject(name: "Pending reader descendant", kind: .folder)
                            descendant.parent = saved.objects[1].id; candidate.objects.append(descendant); roots = [descendant.id]; expected = overlapError
                        case "duplicate": roots += roots; expected = malformedError
                        case "unknown": roots = [UUID()]; expected = malformedError
                        case "tombstone":
                            roots = [saved.objects[3].id]; candidate.objects.removeAll { $0.id == roots[0] }; expected = malformedError
                        case "bound": roots = Array(repeating: roots[0], count: 10001); expected = malformedError
                        case "identity": expected = SourcePluginError.invalid("Invalid plugin world identity map.").description
                        default: expected = detachedError
                        }
                        candidate = try withRoots(candidate, roots, invalidIdentities: kind == "identity")
                        if kind == "sameRoot" || kind == "newRoot" {
                            var calls: [[String: String]] = []
                            let resolver: SourceStudioPluginWorld.AttachmentResolver = { child, parent in
                                calls.append(["child": child.id.uuidString, "parent": parent.id.uuidString])
                                return (matrix_identity_float4x4, simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
                            }
                            let oracle: SourceStudioPluginSession
                            if origin == "profile" {
                                oracle = try SourceStudioPluginSession(profileURL: URL(fileURLWithPath: configuration.profiles["requeue"]!),
                                    document: candidate, restoring: candidate.sourcePluginState, attachment: resolver)
                            } else {
                                let request = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: configuration.requests["requeue"]!))
                                oracle = try SourceStudioPluginSession(selection: request.selection, resolution: request.selection.resolve(),
                                    configuration: request.configuration, document: candidate, restoring: candidate.sourcePluginState, attachment: resolver)
                            }
                            try persist(calls, origin + "-" + kind + "-oracle-calls")
                            try persist(try oracle.savedDocument(), origin + "-" + kind + "-oracle-restored")
                            try check(origin + "-" + kind + "RequestOracle", calls == Array(repeating:
                                ["child": saved.objects[1].id.uuidString, "parent": parent.uuidString], count: 2)
                                && oracle.initializationRequestedDestruction && oracle.world.pendingSourceDestructionRoots() == [saved.objects[2].id])
                        }
                        let path = output.appendingPathComponent(origin + "-" + kind + ".png")
                        try CardIO.encode(candidate, keyword: CardIO.sceneKeyword, thumbnail: nil).write(to: path, options: .withoutOverwriting)
                        let actions = kind == "sameRoot" || kind == "newRoot" ? ["open", "undo", "redo"] : [kind == "detached" ? "detached" : "open"]
                        let temperatures = kind == "sameRoot" || kind == "newRoot" ? [false, true] : [kind == "reader" || kind == "descendant" || kind == "identity"]
                        for warm in temperatures { for action in actions {
                            let prefix = origin + "-" + kind + (warm ? "-warm-" : "-cold-") + action
                            try await seed(candidate, warm: warm); try seedHistory(action, candidate: candidate)
                            let preview = studio.sourceShapePreview(for: parent)
                            if warm, let preview {
                                var body = preview.savedBodyValues, face = preview.savedFaceValues
                                body[0] = body[0] < 0.5 ? 0.8 : 0.2; face[33] = face[33] < 0.5 ? 0.8 : 0.2
                                _ = try preview.editedPose(faceValues: face, bodyValues: body, animationElapsed: 0.7)
                            }
                            let oldSession = studio.sourcePluginSession, oldFocus = studio.sourceFocus.adapter
                            let before = try capture(prefix + "-before"), warmBefore = try warmObservation(preview)
                            try persist(warmBefore, prefix + "-warm-before")
                            var error = "NO REJECTION"
                            if action == "open" { do { try studio.loadScene(from: path) } catch let caught { error = String(describing: caught) } }
                            else if action == "detached" { do { _ = try studio.prepareSourcePlugins(document: candidate) } catch let caught { error = String(describing: caught) } }
                            else { if action == "undo" { studio.undo() } else { studio.redo() }; error = studio.status }
                            let after = try capture(prefix + "-after"), warmAfter = try warmObservation(studio.sourceShapePreview(for: parent))
                            try persist(warmAfter, prefix + "-warm-after"); try persist(["error": error], prefix + "-outcome")
                            let history = action == "undo" || action == "redo"
                            try check(prefix + "Rejected", error == (history ? "Plugin restore: " + expected : expected), error)
                            let comparable = history ? try snapshot(status: before.state.graph.state.status) : after.state
                            try check(prefix + "StateRetained", comparable == before.state && studio.sourcePluginSession === oldSession
                                && studio.sourceFocus.adapter === oldFocus && studio.sourceShapePreview(for: parent) === preview)
                            try check(prefix + "WarmRetained", warmAfter == warmBefore)
                            try check(prefix + "FrameRetained", after.frame == before.frame)
                        } }
                    }
                }
            }
        } catch { rows.append(.init(op: "pendingAttachmentAcceptanceFailure", ok: false, detail: String(describing: error))) }
        studio.sourcePluginsRunning = false
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}
