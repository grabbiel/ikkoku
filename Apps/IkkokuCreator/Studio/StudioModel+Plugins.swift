import Foundation
import AppKit
import AVFAudio
import Studio
import Gameplay

extension StudioModel {
    func loadSourcePlugins(profileURL: URL) throws {
        let session = try SourceStudioPluginSession(profileURL: profileURL, document: doc,
            attachment: { [weak self] child, parent in
                try MainActor.assumeIsolated {
                    guard let self else { throw SourcePluginError.runtime("Studio closed during a plugin callback.") }
                    return try self.pluginAttachmentFrame(child: child, parent: parent)
                }
            })
        let next = try session.savedDocument()
        sourcePluginSession = session; doc = next; sourcePluginsRunning = true
        status = "Loaded \(session.library.packages.count) translated plugin packages"
    }

    func restoreSourcePlugins(restoreNativeAdapters: Bool = true) throws {
        sourcePluginSession = nil; sourcePluginsRunning = false
        if restoreNativeAdapters { try applySourceNativePlugins(doc.sourceNativePlugins ?? []) }
        guard let saved = doc.sourcePluginState else { return }
        sourcePluginSession = try SourceStudioPluginSession(profileURL: URL(fileURLWithPath: saved.profileFile),
            document: doc, restoring: saved, attachment: { [weak self] child, parent in
                try MainActor.assumeIsolated {
                    guard let self else { throw SourcePluginError.runtime("Studio closed during a plugin callback.") }
                    return try self.pluginAttachmentFrame(child: child, parent: parent)
                }
            })
        // Reload remains paused until playback or explicit deterministic steps.
        // Stored clocks/fields are already at the saved frame.
    }

    func stepSourcePlugins(deltaTime: Float, advanceAnimation: Bool = false) throws {
        guard let session = sourcePluginSession else { throw SourcePluginError.invalid("Load a translated plugin profile first.") }
        let oldTime = sourceAnimationTime
        let dynamics = capturePluginDynamics()
        do {
            let next = try session.step(document: doc, deltaTime: deltaTime, afterUpdate: {
                if advanceAnimation { try self.advancePluginAnimation(by: deltaTime) }
            })
            doc = next
        } catch {
            try restorePluginDynamics(time: oldTime, checkpoints: dynamics)
            sourcePluginsRunning = false
            throw error
        }
    }

    func openSourcePluginProfile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try loadSourcePlugins(profileURL: url) } catch { status = "Plugin load: \(error)" }
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
    /// before NSApplication exists, so capture/env mounts sample the initial focus
    /// at launch instead of reading a nil NSApp.
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
        if let app = NSApp { deliverInitialSourceFocus(app.isActive); return }
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
        let package = try SourceNativePluginPackage.load(url: url)
        var refs = doc.sourceNativePlugins ?? []
        refs.removeAll { $0.guid.utf8.elementsEqual(package.manifest.identity.guid.utf8) }
        refs.append(.init(package: package))
        try applySourceNativePlugins(refs)
        doc.sourceNativePlugins = refs
        status = "Loaded \(package.manifest.identity.name) \(package.manifest.identity.version)"
    }

    func applySourceNativePlugins(_ refs: [SourceNativePluginReference]) throws {
        guard refs.count <= 32, Set(refs.map { Data($0.guid.utf8) }).count == refs.count else {
            throw SourcePluginError.invalid("Duplicate or excessive native adapter mounts.")
        }
        let packages = try refs.map { try $0.load() }
        var muteConfiguration: Data?
        var accessoryNames = false
        for (reference, package) in zip(refs, packages) where reference.enabled {
            if package.manifest.adapterID == SourceNativePluginPackage.muteAdapter {
                let data = package.configuration ?? Data()
                _ = try SourceMuteInBackgroundPlugin.readConfiguration(data)
                muteConfiguration = data
            } else if package.manifest.adapterID == SourceNativePluginPackage.accessoryAdapter { accessoryNames = true }
        }
        // Validate every package before replacing any active adapter.
        if let configuration = muteConfiguration { try configureSourceMutePlugin(configuration: configuration) }
        else { mountSourceFocusAdapter(nil) }
        sourceAccessoryNamesEnabled = accessoryNames
    }

    func openSourceNativePlugin() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try loadSourceNativePlugin(url: url) } catch { status = "Native plugin load: \(error)" }
    }
}
