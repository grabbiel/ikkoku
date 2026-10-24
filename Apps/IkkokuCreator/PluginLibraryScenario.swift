import Foundation
import Gameplay
import Character
import Studio
import Renderer
import CryptoKit
import simd

/// Deterministic app-level checks entered through the existing Studio scenario
/// mode. The barrier wraps the real immutable preparation; no result is faked.
struct PluginLibraryScenario: Decodable {
    let requestFile: String
    /// Reproduction only: retains the fresh loader's existing callback behavior.
    let reproduceFreshProfileFailure: Bool?
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
            try check("legacyAttachmentUndoRollback", studio.status.contains("attachment reads during plugin installation are unsupported")
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

// Diagnostic fixture only. No change to loadSourcePlugins or its callback policy.
extension PluginLibraryScenario {
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
            // Start is deferred until step(), not session construction. The
            // failure controls target initializers and active Awake instead.
            for (name, phase, hidden, fail) in [
                ("hiddenInitializerControl", "initializer", true, false),
                ("hiddenInitializerFailure", "initializer", true, true),
                ("activeAwakeFailure", "Awake", false, true),
                ("activeStartControl", "Start", false, false)] {
                studio.newScene()
                var parent = template; parent.id = UUID(); parent.parent = nil; parent.visible = !hidden
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
                let beforeDoc = studio.doc, beforeSession = studio.sourcePluginSession
                let beforeRuntime = try beforeSession?.savedDocument(), beforeAdapter = studio.sourceFocus.adapter
                let beforeResources = resources(), beforePreviews = previews(), beforeFrame = studio.host.renderer.currentFrame()
                let beforeStatus = studio.status, beforeGeneration = studio.sourcePluginMountGeneration
                let beforeGain = studio.sourceAudioBus.masterVolume, beforeAnimation = studio.sourceAnimationTime
                let beforeObservers = studio.sourceFocusObservers.count, beforeLaunchObserver = studio.sourceLaunchObserver != nil
                record(name + "Precondition", beforeSession != nil && beforeAdapter != nil
                    && (studio.sourceShapePreview(for: parent.id) == nil) == hidden,
                    "hidden=\(hidden), cached previews=\(beforePreviews.count), resources=\(beforeResources)")
                let profile = try freshProfileFixture(directory: scratch.appendingPathComponent(name), phase: phase, fail: fail)
                var rejection: String?
                do { try studio.loadSourcePluginProfileInteractively(profileURL: profile, expectedGeneration: beforeGeneration) }
                catch SourcePluginError.runtime(let message) { rejection = message }
                catch { rejection = "UNEXPECTED: \(error)" }
                if fail {
                    record(name + "NamedError", rejection == "Unsupported arithmetic operator or Int32 arithmetic.", rejection ?? "No error")
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
                } else {
                    record(name + "Mounted", rejection == nil && studio.sourcePluginSession !== beforeSession
                        && studio.sourceShapePreview(for: parent.id) != nil
                        && studio.doc.sourcePluginState?.bindings.first?.fields["position"] != nil,
                        rejection ?? "Supported attachment profile committed; reference point17 resolved")
                    if phase == "Start" {
                        record("startDeferredUntilStep", studio.doc.sourcePluginState?.bindings.first?.started == false)
                        try studio.stepSourcePlugins(deltaTime: 0.02)
                        record("startAttachmentExecuted", studio.doc.sourcePluginState?.bindings.first?.started == true,
                               "Supported Start attachment read executed on first real step, after installation")
                    }
                }
            }
        } catch { record("reproductionFailure", false, String(describing: error)) }
        studio.cancelSourcePluginLibraryMount(); await studio.sourcePluginLibraryPreparationQueue.drain()
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }

    private func freshProfileFixture(directory: URL, phase: String, fail: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let type = "FreshAttachmentProbe", guid = "Ikkoku.Validation.FreshAttachmentProbe"
        let hash = String(repeating: "a", count: 64)
        let read: [String: Any] = ["kind": "api", "type": "Vector3", "name": "position", "children": [
            ["kind": "api", "type": "Transform", "name": "transform", "children": []]]]
        let poison: [String: Any] = ["kind": "binary", "type": "Int32", "name": "+", "children": [
            ["kind": "literal", "type": "Int32", "value": 1], ["kind": "literal", "type": "Int32", "value": 1]]]
        let zero: [String: Any] = ["kind": "api", "type": "Vector3", "name": "vector.zero", "children": []]
        var fields: [[String: Any]] = [["name": "position", "type": "Vector3", "serialized": true,
                                       "initializer": phase == "initializer" ? read : zero]]
        var body: [[String: Any]] = []
        if phase == "initializer" {
            if fail { fields.append(["name": "trip", "type": "Int32", "serialized": false, "initializer": poison]) }
        } else {
            body.append(["kind": "assign", "name": "=", "children": [["kind": "field", "type": "Vector3", "name": "position"], read]])
            if fail { body.append(["kind": "expression", "children": [poison]]) }
        }
        let lifecycle = phase == "initializer" ? "Awake" : phase
        let program: [String: Any] = ["schemaVersion": 1, "status": "ready", "mode": "component", "type": type,
            "source": ["sha256": hash], "identity": ["sourceSHA256": hash, "type": type,
                "symbols": ["M:\(type).\(lifecycle)"], "pluginGUID": guid],
            "semanticSurfaceSHA256": hash, "bridgeSHA256": hash, "emitterSHA256": hash,
            "fields": fields, "methods": [["name": lifecycle, "symbol": "M:\(type).\(lifecycle)", "static": false,
                "returnType": "Void", "parameters": [], "body": ["kind": "block", "children": body], "lifecycle": lifecycle]]]
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
