import Foundation
import Gameplay
import Studio
import Renderer
import CryptoKit
import simd

/// Deterministic app-level checks entered through the existing Studio scenario
/// mode. The barrier wraps the real immutable preparation; no result is faked.
struct PluginLibraryScenario: Decodable {
    let requestFile: String
    private actor Barrier {
        var entered = false
        var entry: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true; entry?.resume(); entry = nil
            await withCheckedContinuation { release = $0 }
        }
        func wait() async {
            if !entered { await withCheckedContinuation { entry = $0 } }
        }
        func finish() { release?.resume(); release = nil }
    }

    @MainActor func run(app: AppState, studio: StudioModel) async -> StudioScenario.Report {
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
            try studio.stepSourcePlugins(deltaTime: 0.02)
            let firstSession = studio.sourcePluginSession, firstState = try firstSession?.savedDocument()
            try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(10))
            try check("sameSelectionNoop", firstSession === studio.sourcePluginSession && firstState == studio.doc)

            // Old runtime ticks may continue during immutable package preparation.
            let runningBarrier = Barrier()
            studio.sourcePluginPreparationHook = { await runningBarrier.hold() }
            let replacement = Task { try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(11)) }
            await runningBarrier.wait()
            try studio.stepSourcePlugins(deltaTime: 0.02)
            await runningBarrier.finish(); try await replacement.value
            studio.sourcePluginPreparationHook = nil
            try check("runningReplacement", studio.doc.sourcePluginLibraryConfiguration == configuration(11)
                && firstSession !== studio.sourcePluginSession)

            // Static ownership assertions must not race either editor's normal
            // 30 Hz timer. Running replacement above advances the old runtime
            // explicitly through the same production step path.
            studio.sourcePluginsRunning = false
            app.maker?.liveAnimation = false

            for boundary in ["modeExit", "modeExitAndReturn", "documentEditAndReturn"] {
                let before = studio.doc, session = studio.sourcePluginSession, adapter = studio.sourceFocus.adapter
                let resources = resourceCounts()
                let barrier = Barrier()
                studio.sourcePluginPreparationHook = { await barrier.hold() }
                let pending = Task { try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(10)) }
                await barrier.wait()
                if boundary.hasPrefix("mode") {
                    app.mode = .maker
                    if boundary == "modeExitAndReturn" { app.mode = .studio }
                } else {
                    studio.doc.name = "Changed during preparation"; studio.doc = before
                }
                let frame = studio.host.renderer.currentFrame()
                let boundaryResources = resourceCounts()
                await barrier.finish()
                var cancelled = false
                do { try await pending.value } catch is CancellationError { cancelled = true }
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

            // A UI Task queued before removal must reject entry before scheduling
            // preparation, changing status, or touching the shared Maker frame.
            let beforeQueue = studio.doc, queuedSession = studio.sourcePluginSession
            let queued = Task { try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(10)) }
            app.mode = .maker
            let makerFrame = studio.host.renderer.currentFrame()
            var rejected = false
            do { try await queued.value } catch is CancellationError { rejected = true }
            try check("inactiveQueuedEntry", rejected && studio.doc == beforeQueue && queuedSession === studio.sourcePluginSession
                && sameFrame(makerFrame, studio.host.renderer.currentFrame()) && !studio.sourcePluginLibraryPending)
            studio.unloadSourcePluginLibrary()
            try check("inactiveUnload", studio.doc == beforeQueue && queuedSession === studio.sourcePluginSession
                && sameFrame(makerFrame, studio.host.renderer.currentFrame()))
            app.mode = .studio

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
            try await studio.mountSourcePluginLibrary(selection: request.selection, configuration: configuration(10))
            try check("retry", studio.doc.sourcePluginLibraryConfiguration == configuration(10))
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
        } catch {
            rows.append(.init(op: "failure", ok: false, detail: String(describing: error)))
        }
        studio.sourcePluginPreparationHook = nil
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
