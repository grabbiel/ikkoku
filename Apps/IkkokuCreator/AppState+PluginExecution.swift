import Foundation
import AppKit
import Studio
import Gameplay

extension AppState {
    static func configureStudioExecution(_ studio: StudioModel) throws {
        let env = ProcessInfo.processInfo.environment
        if let value = env["IKKOKU_STUDIO_ANIMATION_TIME"] {
            guard let seconds = Float(value) else { throw SourcePluginError.invalid("Invalid source animation capture time.") }
            studio.liveAnimation = false
            try studio.setSourceAnimationTime(seconds)
        }
        if let path = env["IKKOKU_SOURCE_PLUGIN_PROFILE"] { try studio.loadSourcePlugins(profileURL: URL(fileURLWithPath: path)) }
        if let path = env["IKKOKU_NATIVE_PLUGIN_MANIFEST"] { try studio.loadSourceNativePlugin(url: URL(fileURLWithPath: path)) }
        if let json = env["IKKOKU_NATIVE_PLUGIN_MANIFESTS"] {
            let paths = try JSONDecoder().decode([String].self, from: Data(json.utf8))
            guard paths.count <= 32 else { throw SourcePluginError.invalid("Excessive native plugin capture mounts.") }
            for path in paths { try studio.loadSourceNativePlugin(url: URL(fileURLWithPath: path)) }
        }
        if let path = env["IKKOKU_MUTE_BACKGROUND_CONFIG"] { try studio.configureSourceMutePlugin(configURL: URL(fileURLWithPath: path)) }
        if let value = env["IKKOKU_SOURCE_PLUGIN_STEPS"] {
            guard let steps = Int(value), (0...10_000).contains(steps),
                  let delta = Float(env["IKKOKU_SOURCE_PLUGIN_DELTA"] ?? "0.0333333333"), delta.isFinite, delta >= 0 else {
                throw SourcePluginError.invalid("Invalid deterministic plugin capture steps.")
            }
            for _ in 0..<steps { try studio.stepSourcePlugins(deltaTime: delta, advanceAnimation: studio.liveAnimation) }
            studio.sourcePluginsRunning = false; studio.liveAnimation = false
        }
        try captureSourceFocus(studio, env: env)
    }

    /// `IKKOKU_APPLICATION_FOCUS=0,1` delivers focus loss/gain through the AppKit
    /// notification path; `IKKOKU_NATIVE_PLUGIN_REPORT` records mounts, observers
    /// and generated-tone gain after each event. Headless captures never create
    /// NSApplication, so they also record the deferred initial-focus state.
    private static func captureSourceFocus(_ studio: StudioModel, env: [String: String]) throws {
        let events: [Bool] = try env["IKKOKU_APPLICATION_FOCUS"].map { value in
            try value.split(separator: ",", omittingEmptySubsequences: false).map { text -> Bool in
                guard text == "0" || text == "1" else { throw SourcePluginError.invalid("Application focus events must be comma-separated 0 or 1.") }
                return text == "1"
            }
        } ?? []
        guard events.count <= 64, events.isEmpty || studio.sourceFocus.adapter != nil else {
            throw SourcePluginError.invalid("Application focus events require a mounted Mute adapter and at most 64 events.")
        }
        guard let path = env["IKKOKU_NATIVE_PLUGIN_REPORT"] else {
            for focused in events { studio.receiveSourceApplicationFocus(focused) }
            return
        }
        func sample(_ focus: Bool?) throws -> [String: Any] {
            let rms = try studio.measureGeneratedToneRMS()
            var row: [String: Any] = ["masterVolume": studio.sourceAudioBus.masterVolume, "voiceVolume": studio.sourceAudioBus.voiceVolume, "toneRMS": rms]
            if let focus { row["focus"] = focus }
            if let original = studio.sourceFocus.adapter?.originalVolume { row["originalVolume"] = original }
            return row
        }
        let mount = studio.sourceFocusState(), initial = try sample(nil)
        var trace = [initial]
        for focused in events { studio.receiveSourceApplicationFocus(focused); trace.append(try sample(focused)) }
        let references = try (studio.doc.sourceNativePlugins ?? []).map { reference -> Any in
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference))
        }
        let report: [String: Any] = ["schemaVersion": 1, "applicationCreated": NSApp != nil, "nativePlugins": references,
            "accessoryNamesEnabled": studio.sourceAccessoryNamesEnabled, "mount": mount, "focusTrace": trace, "final": studio.sourceFocusState()]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
        print("[ikkoku] native plugin report written to \(path)")
    }
}
