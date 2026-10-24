import Foundation
import Gameplay
import Character
import Studio
import Renderer
import Scene
import CryptoKit
import simd

/// Deterministic app-level checks entered through the existing Studio scenario
/// mode. The barrier wraps the real immutable preparation; no result is faked.
struct PluginLibraryScenario: Decodable {
    let requestFile: String
    /// Source-backed fresh-profile callback and failure-isolation checks.
    let reproduceFreshProfileFailure: Bool?
    /// Reproduction only: save and reopen run in separate owned processes.
    let nativeProfileRestore: NativeProfileRestore?
    /// Regression only: attachment-free constructor replay across native save/open.
    let initializerProfileRestore: NativeProfileRestore?
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
                                                        app: AppState, studio: StudioModel) async -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = []
        func record(_ name: String, _ okay: Bool, _ detail: String = "") {
            rows.append(.init(op: name, ok: okay, detail: detail))
        }
        func require(_ name: String, _ okay: Bool, _ detail: String = "") throws {
            record(name, okay, detail)
            if !okay { throw SourcePluginError.runtime("Initializer reproduction precondition failed: \(name)") }
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
        let names = ["noop", "Instantiate", "SetActive", "Destroy", "changed"]
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
                        phase: "initializer", fail: false, attachmentRead: false, mutation: mutation)
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
                    if name == "Destroy" {
                        try require("DestroyPendingBeforeSave", mounted.pending.count == 1
                            && mounted.document.object(target.id) != nil,
                            "Save before any runtime step; pending destruction is still live")
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
                for name in ["changed", "noop", "Instantiate", "SetActive", "Destroy"] {
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
                    if let loadError {
                        record(name + "LoadOutcome", name == "changed"
                            && loadError == "invalid: Saved plugin profile or library bindings changed; explicit reinstallation is required.", loadError)
                        record(name + "LoadFailureRetainsPrior", loaded == before && studio.sourcePluginSession === oldSession
                            && studio.sourceFocus.adapter === adapter && studio.sourceAudioBus.masterVolume == gain
                            && studio.sourceFocusObservers.count == observers && (studio.sourceLaunchObserver != nil) == launchObserver
                            && !studio.sourcePluginsRunning && sameFrame(beforeFrame, studio.host.renderer.currentFrame()))
                        continue
                    }
                    record(name + "LoadOutcome", name != "changed", "Loaded; " + summary(loaded))
                    record(name + "InputSceneCommitted", studio.doc.objects == saved.objects
                        && studio.doc.sourcePluginState == saved.sourcePluginState)
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
                        record(name + "MatchesFreshContinuation", stepped.document.objects == freshStepped.document.objects
                            && stepped.runtimeDocument?.sourcePluginState == freshStepped.runtimeDocument?.sourcePluginState
                            && stepped.pending == freshStepped.pending
                            && Array(stepped.callbacks.dropFirst(loaded.callbacks.count))
                                == Array(freshStepped.callbacks.dropFirst(freshSaved.callbacks.count)),
                            "Compare original-session continuation after the same saved clock/state; callback suffixes exclude earlier installation events")
                    }
                    if name == "noop" {
                        record("NoopExactRestoredState", loaded.runtimeDocument?.sourcePluginState == saved.sourcePluginState
                            && loaded.world?.objects == saved.objects)
                    }
                    // Full snapshots retain SetActive visibility, pending Destroy
                    // and callback order as observations, without imposing a new
                    // restore policy on those existing semantics.
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
        for mutation in ["Instantiate", "SetActive", "Destroy"] {
            let profile = try freshProfileFixture(directory: directory.appendingPathComponent("restore-" + mutation),
                phase: "initializer", fail: false, mutation: mutation)
            failures.append((mutation, try pinnedFailure(profile),
                "Attachment-reading restoration cannot mutate the candidate scene, clone objects, or schedule destruction during initialization."))
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
                                     mutation: String? = nil) throws -> URL {
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
            body.append(["kind": "assign", "name": "=", "children": [["kind": "field", "type": "Vector3", "name": "position"], read]])
            if fail { body.append(["kind": "expression", "children": [poison]]) }
        }
        let lifecycle = phase == "initializer" ? "Awake" : phase
        var methods: [[String: Any]] = [["name": lifecycle, "symbol": "M:\(type).\(lifecycle)", "static": false,
            "returnType": "Void", "parameters": [], "body": ["kind": "block", "children": body], "lifecycle": lifecycle]]
        var symbols = ["M:\(type).\(lifecycle)"]
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
            // The first field has already performed a successful attachment
            // read. This second initializer mutates the candidate, then returns
            // a serializable value so restore reaches its explicit policy gate.
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
