import Foundation
import CryptoKit
import Metal
import Renderer
import Character
import Studio
import Scene
import CoreMath
import GPU

extension AppState {
    /// `IKKOKU_LIVE_SOURCE_PROBE=<capture frame.json>` (R1/CMT-04 measurement):
    /// renders the card on the LIVE native rig (source avatar, card shape and
    /// bone modifiers, optional frozen CharaStudio hand pose) with the opt-in
    /// live source-shader path, under the capture's camera, light, effects and
    /// `_Time`, and writes the `compare_original_frame.py` inputs to
    /// `IKKOKU_LIVE_SOURCE_OUTPUT`. Unlike `IKKOKU_ORIGINAL_FRAME_PROBE` no
    /// frozen capture geometry is drawn: the capture supplies only the view.
    ///
    /// Inputs: `IKKOKU_SOURCE_AVATAR`, `IKKOKU_SOURCE_CARD`, optional
    /// `IKKOKU_STUDIO_HAND_POSE`, `IKKOKU_SOURCE_EXPRESSION` (`defaults` or a
    /// preset ID), `IKKOKU_STUDIO_LOOK_SETTINGS` (resting iris transforms), the
    /// live-path variables of `SourceShaderLiveConfiguration`, and
    /// `IKKOKU_LIVE_SOURCE_TEXTURE_PROVIDER` = `store` (default, native texture
    /// store) or `capture` (VALIDATION only: capture pixels matched by native
    /// identity). Scene globals are the capture harness constants, which is
    /// what the original set for this frame. Exits 0 after writing, 1 on error.
    static func captureLiveSourceShaderProbe(host: EngineHost, path: String) {
        let env = ProcessInfo.processInfo.environment
        func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        do {
            guard let outputPath = env["IKKOKU_LIVE_SOURCE_OUTPUT"] else { throw RigError.invalid("IKKOKU_LIVE_SOURCE_PROBE needs IKKOKU_LIVE_SOURCE_OUTPUT.") }
            guard let avatarPath = env["IKKOKU_SOURCE_AVATAR"], let cardPath = env["IKKOKU_SOURCE_CARD"] else {
                throw RigError.invalid("IKKOKU_LIVE_SOURCE_PROBE needs IKKOKU_SOURCE_AVATAR and IKKOKU_SOURCE_CARD.")
            }
            let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let frameURL = URL(fileURLWithPath: path)
            let frameData = try Data(contentsOf: frameURL)
            guard let original = try JSONSerialization.jsonObject(with: frameData) as? [String: Any] else { throw RigError.invalid("Capture frame is not a JSON object.") }
            // The capture's camera, light and effects (its frozen meshes are not drawn).
            let probe = try OriginalFrameProbe.load(url: frameURL, resources: host.renderer.resources)
            let captureTime = ((original["globals"] as? [String: Any])?["_Time"] as? [NSNumber]).flatMap { $0.count == 4 ? $0[1].doubleValue : nil }
            let anisotropicFiltering = original["anisotropicFiltering"] as? String

            // The live character: the same path as IKKOKU_CAPTURE_RIG + IKKOKU_SOURCE_CARD
            // and `ikkoku-inspect card-pose --studio-hands`.
            let avatarURL = URL(fileURLWithPath: avatarPath)
            let source = try SourceRig.loadModel(url: avatarURL)
            let contractURL = avatarURL.deletingLastPathComponent().appendingPathComponent("character-shape-contract.json")
            let contract = try SourceShapeContract.decode(Data(contentsOf: contractURL))
            let appearanceURL = avatarURL.deletingPathExtension().appendingPathExtension("appearance.json")
            let appearance = FileManager.default.fileExists(atPath: appearanceURL.path)
                ? try SourcePreviewAppearance.load(url: appearanceURL, resources: host.renderer.resources, modLibrary: nil) : nil
            let expressionURL = avatarURL.deletingLastPathComponent().appendingPathComponent("source-expression-contract.json")
            let expressionContract = FileManager.default.fileExists(atPath: expressionURL.path)
                ? try SourceExpressionContract.decode(Data(contentsOf: expressionURL)) : nil
            let preview = try SourceRigPreview(source: source, contract: contract, resources: host.renderer.resources,
                                              appearance: appearance, expressionContract: expressionContract)
            guard preview.supportsBodyCustomization, preview.supportsFaceCustomization else {
                throw RigError.invalid("The live probe requires the recovered female shape contract.")
            }
            let cardURL = URL(fileURLWithPath: cardPath)
            let card = try SourceCharacterCard.load(url: cardURL)
            let settings = try card.previewSettings(contract: contract)
            var pose = try preview.pose(bodyValues: settings.bodyValues, faceValues: settings.faceValues, boneModifiers: settings.boneModifiers)
            var handNote = "not applied"
            if let handPath = env["IKKOKU_STUDIO_HAND_POSE"] {
                let hands = try SourceStudioHandPose.load(url: URL(fileURLWithPath: handPath))
                pose = try hands.applying(to: source.rig, basePose: pose)
                handNote = "\(handPath) (\(sha256(try Data(contentsOf: URL(fileURLWithPath: handPath))).prefix(12)))"
            }
            let expression: SourceExpressionInputs?
            switch env["IKKOKU_SOURCE_EXPRESSION"] {
            case nil: expression = nil
            case "defaults"?:
                guard let expressionContract else { throw RigError.invalid("No source expression contract.") }
                expression = expressionContract.defaults
            case let id?:
                guard let preset = expressionContract?.presets.first(where: { $0.id == id }) else { throw RigError.invalid("Unknown source expression preset '\(id)'.") }
                expression = preset.inputs
            }
            var frame = try preview.frame(camera: probe.frame.camera, mainLight: probe.frame.mainLight, effects: probe.frame.effects,
                                          expression: expression, poseOverride: pose)
            if let captureTime { frame.time = captureTime }
            frame.lights = probe.frame.lights
            let toonFrame = frame

            // The live path, configured as in the app, with the harness scene globals.
            let configuration = SourceShaderLiveConfiguration.environment(env, sourceAvatar: avatarURL)
            let inputs = try configuration.inputs(makerLibrary: try EngineHost.locateMakerLibrary()?.sourceURL)
            let eyeLook = try env["IKKOKU_STUDIO_LOOK_SETTINGS"].map { try SourceStudioIrisRendering.bindingEyeLook(card: card, settings: URL(fileURLWithPath: $0)) }
            let bindings = try inputs.derive(card: card, scene: .originalCharacterProbeHarness, sceneReason: "", eyeLook: eyeLook)
            let providerName = env["IKKOKU_LIVE_SOURCE_TEXTURE_PROVIDER"] ?? "store"
            guard ["store", "capture"].contains(providerName) else { throw RigError.invalid("IKKOKU_LIVE_SOURCE_TEXTURE_PROVIDER is store or capture.") }
            let shared = try configuration.loadShared(device: host.renderer.gpu.device,
                textures: providerName == "capture" ? try SourceShaderCaptureTextureProvider(frameURL: frameURL) : nil)
            let assembly = SourceShaderLiveAssembly(bindings: bindings, programs: inputs.programs, resources: host.renderer.resources,
                                                    textures: shared.textures, streams: shared.streams, anisotropicFiltering: anisotropicFiltering)
            let attach = assembly.attach(to: &frame, resources: host.renderer.resources)

            // Production render (live draws plus their toon fallbacks), then the
            // validation renders the comparator gates.
            let width = probe.width, height = probe.height
            guard let color = host.renderer.capture(frame: frame, width: width, height: height) else {
                throw RigError.invalid("Live capture failed: \(host.renderer.lastFrameError.map { "\($0)" } ?? "") \(host.renderer.lastDeformationErrors)")
            }
            let rendererReport = host.renderer.lastSourceShaderLive
            try CaptureOutput.writePNG(color, to: output.appendingPathComponent("native-color.png"))
            if let toon = host.renderer.capture(frame: toonFrame, width: width, height: height) {
                try CaptureOutput.writePNG(toon, to: output.appendingPathComponent("native-color-toon.png"))
            }
            for (name, depthNormals) in [("native-geometry.png", false), ("native-depth-normals.png", true)] {
                try CaptureOutput.writePNG(host.renderer.captureSourceGeometry(frame: frame, width: width, height: height, depthNormals: depthNormals, far: probe.sourceFar),
                                           to: output.appendingPathComponent(name))
            }
            func linearBackground(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            let background = (original["background"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0, 0]
            let clear = background.count == 4 ? MTLClearColorMake(linearBackground(background[0]), linearBackground(background[1]), linearBackground(background[2]), background[3])
                : MTLClearColorMake(0, 0, 0, 0)
            try CaptureOutput.writePNG(host.renderer.captureSourceShaderLive(frame: frame, width: width, height: height, clear: clear),
                                       to: output.appendingPathComponent("native-translated.png"))
            let liveFamilies = Set(frame.items.compactMap { $0.sourceShader?.material.family })
            for family in liveFamilies.sorted() {
                try CaptureOutput.writePNG(host.renderer.captureSourceShaderLive(frame: frame, width: width, height: height, families: [family]),
                                           to: output.appendingPathComponent("native-translated-\(family).png"))
            }
            if liveFamilies.contains("main_opaque") {
                try CaptureOutput.writePNG(host.renderer.captureSourceShaderLive(frame: frame, width: width, height: height, families: ["main_opaque"]),
                                           to: output.appendingPathComponent("native-main_opaque.png"))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try CaptureOutput.writeJSON(encoder.encode(host.renderer.benchmark(frame: frame, width: width, height: height)),
                                        to: output.appendingPathComponent("native-benchmark.json"))
            try CaptureOutput.writeJSON(encoder.encode(host.renderer.benchmark(frame: toonFrame, width: width, height: height)),
                                        to: output.appendingPathComponent("native-benchmark-toon.json"))
            let captureFamilies = Set(((original["meshes"] as? [[String: Any]]) ?? []).flatMap { $0["materials"] as? [[String: Any]] ?? [] }
                .compactMap { ($0["shader"] as? String)?.components(separatedBy: "/").last }.filter { $0 != "shadowcast" })
            var diagnostics = assembly.resolution
            diagnostics += attach.fallbacks.map { "toon: \($0)" } + attach.hidden.map { "hidden: \($0)" } + attach.unmatched.map { "unmatched: \($0)" }
            diagnostics += rendererReport.fallbacks.map { "renderer: \($0)" }
            let report: [String: Any] = [
                "schemaVersion": 1, "sourceFrameFile": frameURL.lastPathComponent, "sourceFrameSHA256": sha256(frameData),
                "scope": "LIVE native rig (card shape, static ABMX, frozen Studio hand pose) drawn with the opt-in live source-shader path under the capture camera, light and _Time. Native rig evaluation is included; the capture's frozen geometry is not drawn. Not a production-parity claim.",
                "materialDiagnostics": diagnostics, "drawItems": frame.items.count,
            ]
            try CaptureOutput.writeJSON(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), to: output.appendingPathComponent("native-report.json"))
            let live: [String: Any] = [
                "schemaVersion": 1,
                "inputs": ["captureFrame": frameURL.path, "captureFrameSHA256": sha256(frameData), "avatar": avatarURL.path, "card": cardURL.path,
                           "cardSHA256": card.sourceSHA256, "handPose": handNote, "expression": env["IKKOKU_SOURCE_EXPRESSION"] ?? "none (base mesh)",
                           "eyeLook": eyeLook?.source ?? "none (iris transforms unresolved)", "time": captureTime.map { "\($0) (capture _Time.y)" } ?? "frame default",
                           "camera": "capture camera (\(width)x\(height), far \(probe.sourceFar))", "light": "capture light", "anisotropicFiltering": anisotropicFiltering ?? "per-texture",
                           "sceneGlobals": SourceShaderBindingDerivation.SceneGlobals.originalCharacterProbeHarness.source,
                           "textureProvider": shared.textures.label, "programs": inputs.programs.path, "headContract": inputs.headContract.path,
                           "makerLibrary": inputs.makerLibrary.path, "supplement": inputs.supplement?.path ?? "none",
                           "textures": configuration.textures?.path ?? "none", "streams": configuration.streams?.path ?? "none"] as [String: Any],
                "notes": shared.notes + settings.diagnostics,
                "bindingProvenance": bindings.provenance,
                "resolution": assembly.resolution,
                "attach": ["live": attach.live, "fallbacks": attach.fallbacks, "hidden": attach.hidden, "unmatched": attach.unmatched],
                "renderer": ["draws": rendererReport.draws, "fallbacks": rendererReport.fallbacks],
                "liveFamilies": liveFamilies.sorted(), "captureFamiliesNotLive": captureFamilies.subtracting(liveFamilies).sorted(),
            ]
            try CaptureOutput.writeJSON(JSONSerialization.data(withJSONObject: live, options: [.prettyPrinted, .sortedKeys]), to: output.appendingPathComponent("live-report.json"))
            print("[ikkoku] live source-shader probe: \(attach.live.count) live, \(attach.fallbacks.count) toon, \(attach.hidden.count) hidden, \(attach.unmatched.count) unmatched; written to \(output.path)")
            exit(0)
        } catch { print("[ikkoku] live source-shader probe failed: \(error)"); exit(1) }
    }
}
