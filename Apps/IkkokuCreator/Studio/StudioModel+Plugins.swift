import Foundation
import AppKit
import AVFAudio
import Studio
import Gameplay
import Character

extension StudioModel {
    /// Installation keeps the candidate world isolated until all callbacks and
    /// configurations validate. Reading a source attachment can lazily construct
    /// live previews, so it is permitted only after this candidate commits.
    final class PluginAttachmentAccess { var committed = false }
    struct PreparedSourcePlugins {
        let document: StudioDocument
        let session: SourceStudioPluginSession?
        let native: PreparedNativePlugins
        let attachmentAccess: PluginAttachmentAccess?
    }
    struct PreparedNativePlugins {
        let muteEnabled: Bool?
        let accessoryNames: Bool
        var hideStudioUI = false
    }

    func loadSourcePlugins(profileURL: URL) throws {
        var candidate = doc
        candidate.sourcePluginLibrary = nil; candidate.sourcePluginLibraryConfiguration = nil
        candidate.sourcePluginState = nil
        let attachments = PluginAttachmentPreparation(studio: self)
        defer { attachments.abort() }
        let session = try SourceStudioPluginSession(profileURL: profileURL, document: candidate,
            attachment: { child, parent in
                try MainActor.assumeIsolated { try attachments.frame(child: child, parent: parent) }
            })
        let next = try session.savedDocument()
        cancelSourcePluginLibraryMount()
        attachments.commit(document: next)
        sourcePluginSession = session; doc = next; sourcePluginsRunning = true
        status = "Loaded \(session.library.packages.count) converted plugin packages"
    }

    func pluginAttachmentResolver(access: PluginAttachmentAccess? = nil) -> SourceStudioPluginWorld.AttachmentResolver {
        { [weak self] child, parent in
            try MainActor.assumeIsolated {
                guard let self else { throw SourcePluginError.runtime("Studio closed during a plugin callback.") }
                if let access, !access.committed {
                    throw SourcePluginError.invalid("Source-character attachment reads during plugin installation are unsupported; no live preview was changed.")
                }
                return try self.pluginAttachmentFrame(child: child, parent: parent)
            }
        }
    }

    func prepareSourcePlugins(document: StudioDocument, restoreNativeAdapters: Bool = true) throws -> PreparedSourcePlugins {
        if let selection = document.sourcePluginLibrary {
            guard let configuration = document.sourcePluginLibraryConfiguration else {
                throw SourcePluginError.invalid("Saved plugin library has no scene binding configuration.")
            }
            return try prepareSourcePluginLibrary(selection: selection, resolution: selection.resolve(),
                configuration: configuration, document: document, restoring: true)
        }
        guard document.sourcePluginLibraryConfiguration == nil else { throw SourcePluginError.invalid("Saved plugin bindings have no library selection.") }
        let native = restoreNativeAdapters ? try prepareSourceNativePlugins(document.sourceNativePlugins ?? [])
            : PreparedNativePlugins(muteEnabled: nil, accessoryNames: false)
        let session: SourceStudioPluginSession?
        let access = PluginAttachmentAccess()
        if let saved = document.sourcePluginState {
            guard let path = saved.profileFile, saved.libraryConfigurationSHA256 == nil else {
                throw SourcePluginError.invalid("Saved converted plugin state has no profile or library selection.")
            }
            session = try SourceStudioPluginSession(profileURL: URL(fileURLWithPath: path), document: document,
                restoring: saved, attachment: pluginAttachmentResolver(access: access))
        } else { session = nil }
        return .init(document: document, session: session, native: native, attachmentAccess: access)
    }

    func restoreSourcePlugins(restoreNativeAdapters: Bool = true) throws {
        let prepared = try prepareSourcePlugins(document: doc, restoreNativeAdapters: restoreNativeAdapters)
        commitSourcePlugins(prepared, running: false, mountNative: restoreNativeAdapters, replaceDocument: false)
    }

    func prepareSourcePluginLibrary(selection: SourcePluginLibrarySelection, resolution: SourcePluginLibraryResolution,
                                    configuration: SourceStudioPluginConfiguration, document: StudioDocument,
                                    restoring: Bool = false) throws -> PreparedSourcePlugins {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard SourcePluginGraph.targets([selection.process], process: "CharaStudio") else {
            throw SourcePluginError.invalid("The selected plugin process is not Studio.")
        }
        guard try encoder.encode(selection) == encoder.encode(resolution.selection), !selection.revisions.isEmpty else {
            throw SourcePluginError.invalid("The verified packages differ from the requested plugin selection.")
        }
        let refs = resolution.nativeAdapters.map { SourceNativePluginReference(package: $0) }
        if restoring {
            guard try encoder.encode(document.sourceNativePlugins ?? []) == encoder.encode(refs) else {
                throw SourcePluginError.invalid("Saved native adapters differ from the pinned library selection.")
            }
        }
        let native = try prepareSourceNativePlugins(refs, packages: resolution.nativeAdapters)
        var candidate = document
        candidate.sourcePluginLibrary = selection; candidate.sourcePluginLibraryConfiguration = configuration
        candidate.sourceNativePlugins = refs
        if !restoring { candidate.sourcePluginState = nil }
        let session: SourceStudioPluginSession?
        let access = PluginAttachmentAccess()
        if resolution.translated.isEmpty {
            guard configuration.bindings.isEmpty, candidate.sourcePluginState == nil,
                  configuration.fixedDeltaTime.isFinite, configuration.fixedDeltaTime > 0 else {
                throw SourcePluginError.invalid("An adapter-only library selection cannot contain converted-plugin state or bindings.")
            }
            session = nil
        } else {
            guard !restoring || candidate.sourcePluginState != nil else {
                throw SourcePluginError.invalid("Saved library selection is missing its converted-plugin state.")
            }
            session = try SourceStudioPluginSession(selection: selection, resolution: resolution, configuration: configuration,
                document: candidate, restoring: restoring ? candidate.sourcePluginState : nil,
                attachment: pluginAttachmentResolver(access: access))
            candidate = try session!.savedDocument()
        }
        return .init(document: candidate, session: session, native: native, attachmentAccess: access)
    }

    /// One CPU preparation at a time. The UI retains its current mounted session
    /// while immutable files are checked. Scene or mode changes invalidate the
    /// result even if the user returns to the same document before it finishes.
    func mountSourcePluginLibrary(selection: SourcePluginLibrarySelection,
                                  configuration: SourceStudioPluginConfiguration) async throws {
        try Task.checkCancellation()
        guard isActiveMode else { throw CancellationError() }
        guard !sourcePluginLibraryPending else { throw SourcePluginError.invalid("A plugin selection is already being prepared.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let mounted = doc.sourcePluginLibrary, let bindings = doc.sourcePluginLibraryConfiguration,
           try encoder.encode(mounted) == encoder.encode(selection),
           try encoder.encode(bindings) == encoder.encode(configuration) {
            status = "This plugin selection is already mounted"; return
        }
        let request = UUID()
        sourcePluginMountGeneration &+= 1
        let generation = sourcePluginMountGeneration, hook = sourcePluginPreparationHook
        sourcePluginMountRequest = request; sourcePluginLibraryPending = true
        defer {
            if sourcePluginMountRequest == request {
                sourcePluginMountRequest = nil; sourcePluginLibraryPending = false
            }
        }
        let resolution = try await sourcePluginLibraryPreparationQueue.prepare {
            hook?()
            return try selection.resolve()
        }
        try Task.checkCancellation()
        guard isActiveMode, generation == sourcePluginMountGeneration,
              sourcePluginMountRequest == request else { throw CancellationError() }
        let prepared = try prepareSourcePluginLibrary(selection: selection, resolution: resolution,
            configuration: configuration, document: doc)
        // No suspension follows validation. Our own document setter must not
        // interpret this successful commit as an external preparation edit.
        sourcePluginMountRequest = nil; sourcePluginLibraryPending = false
        pushUndo(force: true)
        commitSourcePlugins(prepared, running: true)
        status = "Mounted \(selection.revisions.count) plugins · library generation \(selection.generation)"
    }

    func cancelSourcePluginLibraryMount() {
        sourcePluginMountGeneration &+= 1
        sourcePluginMountRequest = nil; sourcePluginLibraryPending = false
        sourcePluginLibraryPreparationQueue.cancel()
    }

    func commitSourcePlugins(_ prepared: PreparedSourcePlugins, running: Bool,
                             mountNative: Bool = true, replaceDocument: Bool = true) {
        prepared.attachmentAccess?.committed = true
        if mountNative { commitSourceNativePlugins(prepared.native) }
        sourcePluginSession = prepared.session
        sourcePluginsRunning = running && prepared.session != nil
        if replaceDocument { doc = prepared.document }
    }

    func unloadSourcePluginLibrary() {
        guard isActiveMode else { return }
        cancelSourcePluginLibraryMount(); pushUndo(force: true)
        sourcePluginSession = nil; sourcePluginsRunning = false
        commitSourceNativePlugins(.init(muteEnabled: nil, accessoryNames: false))
        var next = doc; next.sourcePluginLibrary = nil; next.sourcePluginLibraryConfiguration = nil
        next.sourcePluginState = nil; next.sourceNativePlugins = nil; doc = next
        status = "Unloaded Studio plugins"
    }

    func stepSourcePlugins(deltaTime: Float, advanceAnimation: Bool = false) throws {
        guard let session = sourcePluginSession else { throw SourcePluginError.invalid("Load a translated plugin profile first.") }
        let oldTime = sourceAnimationTime
        let dynamics = capturePluginDynamics()
        do {
            let next = try session.step(document: doc, deltaTime: deltaTime, afterUpdate: {
                if advanceAnimation { try self.advancePluginAnimation(by: deltaTime) }
            })
            sourcePluginTickInProgress = true
            doc = next
            sourcePluginTickInProgress = false
        } catch {
            try restorePluginDynamics(time: oldTime, checkpoints: dynamics)
            sourcePluginsRunning = false
            throw error
        }
    }

    /// Interactive commands read only mode, pending state and session presence.
    /// Startup configuration keeps using loadSourcePlugins without these UI gates.
    var sourcePluginCommandsAvailable: Bool { isActiveMode && !sourcePluginLibraryPending }
    var canToggleSourcePluginPlayback: Bool { sourcePluginCommandsAvailable && hasSourcePluginSession }

    var sourcePluginMountSummary: PluginMountSummary? {
        let document = doc
        if let library = document.sourcePluginLibrary {
            return .init(library: library, profile: nil, native: [])
        }
        // No manifest reads, digest computation or runtime snapshots in the
        // panel. GUID keys use UTF-8 so canonically equivalent pins stay distinct.
        var pins: [Data: String] = [:]
        for pin in document.sourcePluginState?.packages ?? [] { pins[Data(pin.guid.utf8)] = pin.manifestSHA256 }
        let profile = sourcePluginSession.map { session in
            session.library.packages.map { package in
                PluginMountSummary.Identity(guid: package.manifest.identity.guid, version: package.manifest.identity.version,
                    manifestSHA256: pins[package.ordinalGUID])
            }
        }
        return .init(library: nil, profile: profile, native: document.sourceNativePlugins ?? [])
    }

    func toggleSourcePluginPlayback() {
        guard canToggleSourcePluginPlayback else { return }
        sourcePluginsRunning.toggle()
    }

    func unloadSourcePluginsInteractively() {
        guard sourcePluginCommandsAvailable else { return }
        unloadSourcePluginLibrary()
    }

    /// The modal owns the generation captured before presentation. Leaving and
    /// returning to Studio must not turn its old selection into a fresh command.
    func loadSourcePluginProfileInteractively(profileURL: URL, expectedGeneration: UInt64) throws {
        guard sourcePluginCommandsAvailable, expectedGeneration == sourcePluginMountGeneration else {
            throw CancellationError()
        }
        try loadSourcePlugins(profileURL: profileURL)
    }

    func openSourcePluginProfile() {
        guard sourcePluginCommandsAvailable else { return }
        let generation = sourcePluginMountGeneration
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try loadSourcePluginProfileInteractively(profileURL: url, expectedGeneration: generation) }
        catch is CancellationError { /* Ownership changed while the dialog was open. */ }
        catch { status = "Plugin load: \(error)" }
    }

    func configureSourceMutePlugin(configURL: URL) throws {
        let handle = try FileHandle(forReadingFrom: configURL); defer { try? handle.close() }
        try configureSourceMutePlugin(configuration: handle.read(upToCount: 1024 * 1024 + 1) ?? Data())
    }

    func configureSourceMutePlugin(configuration: Data) throws {
        let enabled = try SourceMuteInBackgroundPlugin.readConfiguration(configuration)
        mountSourceFocusAdapter(SourceMuteInBackgroundPlugin(enabled: enabled,
            readVolume: { [weak self] in MainActor.assumeIsolated { self?.sourceAudioBus.masterVolume ?? 0 } },
            writeVolume: { [weak self] value in MainActor.assumeIsolated { self?.sourceAudioBus.masterVolume = value } }))
        status = "Loaded \(SourceMuteInBackgroundPlugin.guid) \(SourceMuteInBackgroundPlugin.version)"
    }

    /// Replaces the adapter and its single observer set. SwiftUI builds AppState
    /// before launching finishes, so capture/env mounts sample the initial focus at
    /// `didFinishLaunching`. On macOS 27 NSApplication already exists (and reports
    /// `isRunning`) at that point, but `isActive` is still false, so the existence
    /// of `NSApp` alone no longer means the sample is valid (A-T04).
    func mountSourceFocusAdapter(_ adapter: SourceMuteInBackgroundPlugin?) {
        for token in sourceFocusObservers { NotificationCenter.default.removeObserver(token) }
        sourceFocusObservers = []; removeSourceLaunchObserver()
        sourceFocus.mount(adapter)
        guard adapter != nil else { return }
        for (name, focused) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            sourceFocusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.receiveSourceApplicationFocus(focused) }
            })
        }
        if let app = NSApp, NSRunningApplication.current.isFinishedLaunching { deliverInitialSourceFocus(app.isActive); return }
        sourceLaunchObserver = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deliverInitialSourceFocus(NSApp?.isActive ?? false) }
        }
    }

    /// AppKit focus notifications and headless capture focus events share this path.
    func receiveSourceApplicationFocus(_ focused: Bool) {
        removeSourceLaunchObserver()
        sourceFocus.focusChanged(focused)
    }

    private func deliverInitialSourceFocus(_ focused: Bool) {
        removeSourceLaunchObserver()
        sourceFocus.deliverInitialFocus(focused)
    }

    private func removeSourceLaunchObserver() {
        if let token = sourceLaunchObserver { NotificationCenter.default.removeObserver(token) }
        sourceLaunchObserver = nil
    }

    func sourceFocusState() -> [String: Any] {
        var state: [String: Any] = ["mounted": sourceFocus.adapter != nil, "awaitingInitialFocus": sourceFocus.awaitingInitialFocus,
            "focusObservers": sourceFocusObservers.count, "launchObserver": sourceLaunchObserver != nil]
        if let adapter = sourceFocus.adapter { state["enabled"] = adapter.enabled }
        return state
    }

    /// Capture-only gain evidence: renders a generated 440 Hz tone offline through
    /// the live bus's voice and master mixers, then returns the bus to realtime.
    /// Running output would be disturbed, so it is rejected instead.
    func measureGeneratedToneRMS() throws -> Float {
        let engine = sourceAudioBus.engine
        guard !engine.isRunning, !engine.isInManualRenderingMode else {
            throw SourcePluginError.invalid("Generated-tone gain capture requires stopped realtime Studio audio.")
        }
        let master = sourceAudioBus.masterVolume, voice = sourceAudioBus.voiceVolume
        try sourceAudioBus.enableOfflineRendering()
        defer { engine.disableManualRenderingMode(); sourceAudioBus.masterVolume = master; sourceAudioBus.voiceVolume = voice }
        guard sourceAudioBus.masterVolume == master, sourceAudioBus.voiceVolume == voice else {
            throw SourcePluginError.runtime("Offline rendering changed the Studio gains being measured.")
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000),
              let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else {
            throw SourcePluginError.runtime("Generated-tone buffers are unavailable.")
        }
        tone.frameLength = 48_000
        let samples = tone.floatChannelData![0]
        for i in 0..<48_000 { samples[i] = 0.25 * sin(2 * .pi * 440 * Float(i) / 48_000) }
        let node = AVAudioPlayerNode()
        engine.attach(node); engine.connect(node, to: sourceAudioBus.voiceMixer, format: format)
        defer { node.stop(); engine.stop(); engine.detach(node) }
        node.scheduleBuffer(tone, at: nil, options: [], completionHandler: nil)
        try engine.start(); node.play()
        var sum: Float = 0, count = 0
        for pass in 0..<4 {
            guard try engine.renderOffline(4096, to: output) == .success else { throw SourcePluginError.runtime("Generated-tone render failed.") }
            if pass > 0 { for i in 0..<Int(output.frameLength) { let x = output.floatChannelData![0][i]; sum += x * x; count += 1 } }
        }
        return sqrt(sum / Float(count))
    }

    func loadSourceNativePlugin(url: URL) throws {
        guard doc.sourcePluginLibrary == nil else { throw SourcePluginError.invalid("Unload the Studio plugin library before mounting a separate adapter.") }
        let package = try SourceNativePluginPackage.load(url: url)
        var refs = doc.sourceNativePlugins ?? []
        refs.removeAll { $0.guid.utf8.elementsEqual(package.manifest.identity.guid.utf8) }
        refs.append(.init(package: package))
        try applySourceNativePlugins(refs)
        doc.sourceNativePlugins = refs
        status = "Loaded \(package.manifest.identity.name) \(package.manifest.identity.version)"
    }

    func applySourceNativePlugins(_ refs: [SourceNativePluginReference]) throws {
        commitSourceNativePlugins(try prepareSourceNativePlugins(refs))
    }

    func prepareSourceNativePlugins(_ refs: [SourceNativePluginReference],
                                    packages verified: [SourceNativePluginPackage]? = nil) throws -> PreparedNativePlugins {
        guard refs.count <= 32, Set(refs.map { Data($0.guid.utf8) }).count == refs.count else {
            throw SourcePluginError.invalid("Duplicate or excessive native adapter mounts.")
        }
        let packages = try verified ?? refs.map { try $0.load() }
        guard packages.count == refs.count else { throw SourcePluginError.invalid("Native adapter preparation is incomplete.") }
        var muteEnabled: Bool?, accessoryNames = false, hideStudioUI = false
        for (reference, package) in zip(refs, packages) where reference.enabled {
            if package.manifest.adapterID == SourceNativePluginPackage.muteAdapter {
                muteEnabled = try SourceMuteInBackgroundPlugin.readConfiguration(package.configuration ?? Data())
            } else if package.manifest.adapterID == SourceNativePluginPackage.accessoryAdapter { accessoryNames = true }
            else if package.manifest.adapterID == SourceNativePluginPackage.hideStudioUIAdapter {
                try SourceHideStudioUIPlugin.validateConfiguration(package.configuration ?? Data())
                hideStudioUI = true
            }
        }
        return .init(muteEnabled: muteEnabled, accessoryNames: accessoryNames, hideStudioUI: hideStudioUI)
    }

    func commitSourceNativePlugins(_ prepared: PreparedNativePlugins) {
        let adapter = prepared.muteEnabled.map { enabled in
            SourceMuteInBackgroundPlugin(enabled: enabled,
                readVolume: { [weak self] in MainActor.assumeIsolated { self?.sourceAudioBus.masterVolume ?? 0 } },
                writeVolume: { [weak self] value in MainActor.assumeIsolated { self?.sourceAudioBus.masterVolume = value } })
        }
        mountSourceFocusAdapter(adapter)
        sourceAccessoryNamesEnabled = prepared.accessoryNames
        sourceHideStudioUI = prepared.hideStudioUI ? SourceHideStudioUIPlugin() : nil
    }

    func openSourceNativePlugin() {
        // Interactive mounts belong to Studio. The underlying loader remains
        // available to startup/capture and validated native-scene restoration.
        guard isActiveMode else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, isActiveMode, let url = panel.url else { return }
        do { try loadSourceNativePlugin(url: url) } catch { status = "Native plugin load: \(error)" }
    }
}
