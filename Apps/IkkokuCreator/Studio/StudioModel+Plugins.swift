import Foundation
import AppKit
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
        let adapter = SourceMuteInBackgroundPlugin(enabled: enabled,
            readVolume: { [weak self] in MainActor.assumeIsolated { self?.sourceAudioBus.masterVolume ?? 0 } },
            writeVolume: { [weak self] value in MainActor.assumeIsolated { self?.sourceAudioBus.masterVolume = value } })
        for token in sourceFocusObservers { NotificationCenter.default.removeObserver(token) }
        sourceFocusObservers = []
        sourceMutePlugin?.onApplicationFocus(true)
        sourceMutePlugin = adapter
        for (name, focused) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            sourceFocusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sourceMutePlugin?.onApplicationFocus(focused) }
            })
        }
        adapter.onApplicationFocus(NSApp.isActive)
        status = "Loaded \(SourceMuteInBackgroundPlugin.guid) \(SourceMuteInBackgroundPlugin.version)"
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
        sourceMutePlugin?.onApplicationFocus(true); sourceMutePlugin = nil
        for token in sourceFocusObservers { NotificationCenter.default.removeObserver(token) }
        sourceFocusObservers = []
        if let configuration = muteConfiguration { try configureSourceMutePlugin(configuration: configuration) }
        sourceAccessoryNamesEnabled = accessoryNames
    }

    func openSourceNativePlugin() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try loadSourceNativePlugin(url: url) } catch { status = "Native plugin load: \(error)" }
    }
}
