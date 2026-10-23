import Foundation
import Renderer
import Character
import Studio
import Scene

extension AppState {
    /// `IKKOKU_LIVE_SOURCE_PROBE=<capture frame.json>` (R1/CMT-04 measurement):
    /// renders the card on the LIVE native rig with the opt-in live
    /// source-shader path under the capture's camera, light, effects and
    /// `_Time` (`SourceShaderLiveFixtureProbe`), and writes the
    /// `compare_original_frame.py` inputs to `IKKOKU_LIVE_SOURCE_OUTPUT`.
    /// Unlike `IKKOKU_ORIGINAL_FRAME_PROBE` no frozen capture geometry is drawn.
    ///
    /// Inputs: `IKKOKU_SOURCE_AVATAR`, `IKKOKU_SOURCE_CARD`, optional
    /// `IKKOKU_STUDIO_HAND_POSE`, `IKKOKU_SOURCE_EXPRESSION` (`defaults` or a
    /// preset ID), `IKKOKU_STUDIO_LOOK_SETTINGS` (resting iris transforms), the
    /// live-path variables of `SourceShaderLiveConfiguration`, and
    /// `IKKOKU_LIVE_SOURCE_TEXTURE_PROVIDER` = `store` (default, native texture
    /// store) or `capture` (VALIDATION only: capture pixels matched by native
    /// identity). Exits 0 after writing, 1 on error.
    static func captureLiveSourceShaderProbe(host: EngineHost, path: String) {
        let env = ProcessInfo.processInfo.environment
        do {
            guard let outputPath = env["IKKOKU_LIVE_SOURCE_OUTPUT"] else { throw RigError.invalid("IKKOKU_LIVE_SOURCE_PROBE needs IKKOKU_LIVE_SOURCE_OUTPUT.") }
            guard let avatarPath = env["IKKOKU_SOURCE_AVATAR"], let cardPath = env["IKKOKU_SOURCE_CARD"] else {
                throw RigError.invalid("IKKOKU_LIVE_SOURCE_PROBE needs IKKOKU_SOURCE_AVATAR and IKKOKU_SOURCE_CARD.")
            }
            let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let avatar = URL(fileURLWithPath: avatarPath)
            let request = SourceShaderLiveFixtureProbe.Request(
                frame: URL(fileURLWithPath: path), avatar: avatar, card: URL(fileURLWithPath: cardPath),
                handPose: env["IKKOKU_STUDIO_HAND_POSE"].map { URL(fileURLWithPath: $0) }, expression: env["IKKOKU_SOURCE_EXPRESSION"],
                lookSettings: env["IKKOKU_STUDIO_LOOK_SETTINGS"].map { URL(fileURLWithPath: $0) },
                configuration: SourceShaderLiveConfiguration.environment(env, sourceAvatar: avatar),
                makerLibrary: try EngineHost.locateMakerLibrary()?.sourceURL,
                textureProvider: env["IKKOKU_LIVE_SOURCE_TEXTURE_PROVIDER"] ?? "store")
            let renderer = host.renderer
            let probe = try SourceShaderLiveFixtureProbe(request, renderer: renderer)
            let width = probe.width, height = probe.height

            // Production render (live draws plus their toon fallbacks), then the
            // validation renders the comparator gates.
            guard let color = renderer.capture(frame: probe.frame, width: width, height: height) else {
                throw RigError.invalid("Live capture failed: \(renderer.lastFrameError.map { "\($0)" } ?? "") \(renderer.lastDeformationErrors)")
            }
            let rendererReport = renderer.lastSourceShaderLive
            try CaptureOutput.writePNG(color, to: output.appendingPathComponent("native-color.png"))
            if let toon = renderer.capture(frame: probe.toonFrame, width: width, height: height) {
                try CaptureOutput.writePNG(toon, to: output.appendingPathComponent("native-color-toon.png"))
            }
            for (name, depthNormals) in [("native-geometry.png", false), ("native-depth-normals.png", true)] {
                try CaptureOutput.writePNG(renderer.captureSourceGeometry(frame: probe.frame, width: width, height: height, depthNormals: depthNormals, far: probe.sourceFar),
                                           to: output.appendingPathComponent(name))
            }
            for (name, image) in try probe.translatedImages(renderer: renderer) {
                try CaptureOutput.writePNG(image, to: output.appendingPathComponent(name))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try CaptureOutput.writeJSON(encoder.encode(renderer.benchmark(frame: probe.frame, width: width, height: height)),
                                        to: output.appendingPathComponent("native-benchmark.json"))
            try CaptureOutput.writeJSON(encoder.encode(renderer.benchmark(frame: probe.toonFrame, width: width, height: height)),
                                        to: output.appendingPathComponent("native-benchmark-toon.json"))
            for (name, document) in [("native-report.json", probe.nativeReport(renderer: rendererReport)), ("live-report.json", probe.liveReport(renderer: rendererReport))] {
                try CaptureOutput.writeJSON(JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]), to: output.appendingPathComponent(name))
            }
            let attach = probe.attach
            print("[ikkoku] live source-shader probe: \(attach.live.count) live, \(attach.fallbacks.count) toon, \(attach.hidden.count) hidden, \(attach.unmatched.count) unmatched; written to \(output.path)")
            exit(0)
        } catch { print("[ikkoku] live source-shader probe failed: \(error)"); exit(1) }
    }
}
