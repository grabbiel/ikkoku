import Foundation
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
    }
}
