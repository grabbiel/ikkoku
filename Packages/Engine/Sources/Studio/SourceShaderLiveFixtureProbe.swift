import Foundation
import CryptoKit
import CoreGraphics
import Metal
import Renderer
import Character
import Scene

/// The R1/CMT-04 live measurement (`IKKOKU_LIVE_SOURCE_PROBE` and the gated
/// Engine check): the fixture card on the LIVE native rig (source avatar, card
/// shape and bone modifiers, optional frozen CharaStudio hand pose and source
/// expression), drawn with the opt-in live source-shader path under an
/// original capture's camera, light, effects and `_Time`. The capture supplies
/// only the view; its frozen meshes are not drawn. Scene globals are the
/// capture harness constants, which the original set for that frame.
public struct SourceShaderLiveFixtureProbe {
    public struct Request: Sendable {
        /// The original capture `frame.json` (camera, light, effects, `_Time`).
        public var frame: URL
        public var avatar: URL
        public var card: URL
        /// Frozen CharaStudio hand pose (`SourceStudioHandPose`), applied over the card pose.
        public var handPose: URL?
        /// nil (base mesh), `defaults`, or a source expression preset ID.
        public var expression: String?
        /// Studio eye-look settings for the resting iris transforms.
        public var lookSettings: URL?
        public var configuration: SourceShaderLiveConfiguration
        public var makerLibrary: URL?
        /// `store` (native texture store) or `capture` (VALIDATION only:
        /// capture pixels matched by native identity).
        public var textureProvider: String
        public init(frame: URL, avatar: URL, card: URL, handPose: URL? = nil, expression: String? = nil, lookSettings: URL? = nil,
                    configuration: SourceShaderLiveConfiguration, makerLibrary: URL? = nil, textureProvider: String = "store") {
            self.frame = frame; self.avatar = avatar; self.card = card; self.handPose = handPose; self.expression = expression
            self.lookSettings = lookSettings; self.configuration = configuration; self.makerLibrary = makerLibrary; self.textureProvider = textureProvider
        }
    }

    public let request: Request
    /// The live character. It owns the frame's GPU meshes, so the probe keeps
    /// it alive for as long as its frames are rendered.
    public let preview: SourceRigPreview
    /// The live-marked frame and the same frame without live draws.
    public let frame: RenderFrame, toonFrame: RenderFrame
    public let width: Int, height: Int
    public let sourceFar: Float
    /// The capture background as a linear clear colour (alpha kept for the comparator's silhouette).
    public let clear: MTLClearColor
    public let assembly: SourceShaderLiveAssembly
    public let attach: SourceShaderLiveAssembly.AttachReport
    public let bindings: SourceShaderBindingSet
    public let liveFamilies: [String]
    /// Families the capture draws that this frame does not draw live.
    public let captureFamiliesNotLive: [String]
    public let frameSHA256: String
    /// Every input, as recorded in `live-report.json`.
    public let inputs: [String: String]
    public let notes: [String]

    public init(_ request: Request, renderer: Renderer) throws {
        func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        self.request = request
        let frameData = try Data(contentsOf: request.frame)
        guard let original = try JSONSerialization.jsonObject(with: frameData) as? [String: Any] else { throw RigError.invalid("Capture frame is not a JSON object.") }
        let probe = try OriginalFrameProbe.load(url: request.frame, resources: renderer.resources)
        let captureTime = ((original["globals"] as? [String: Any])?["_Time"] as? [NSNumber]).flatMap { $0.count == 4 ? $0[1].doubleValue : nil }
        let anisotropicFiltering = original["anisotropicFiltering"] as? String

        // The same character path as IKKOKU_CAPTURE_RIG + IKKOKU_SOURCE_CARD and
        // `ikkoku-inspect card-pose --studio-hands`.
        let folder = request.avatar.deletingLastPathComponent()
        let source = try SourceRig.loadModel(url: request.avatar)
        let contract = try SourceShapeContract.decode(Data(contentsOf: folder.appendingPathComponent("character-shape-contract.json")))
        let appearanceURL = request.avatar.deletingPathExtension().appendingPathExtension("appearance.json")
        let appearance = FileManager.default.fileExists(atPath: appearanceURL.path)
            ? try SourcePreviewAppearance.load(url: appearanceURL, resources: renderer.resources, modLibrary: nil) : nil
        let expressionURL = folder.appendingPathComponent("source-expression-contract.json")
        let expressionContract = FileManager.default.fileExists(atPath: expressionURL.path)
            ? try SourceExpressionContract.decode(Data(contentsOf: expressionURL)) : nil
        let preview = try SourceRigPreview(source: source, contract: contract, resources: renderer.resources,
                                          appearance: appearance, expressionContract: expressionContract)
        self.preview = preview
        guard preview.supportsBodyCustomization, preview.supportsFaceCustomization else {
            throw RigError.invalid("The live probe requires the recovered female shape contract.")
        }
        let card = try SourceCharacterCard.load(url: request.card)
        let settings = try card.previewSettings(contract: contract)
        var pose = try preview.pose(bodyValues: settings.bodyValues, faceValues: settings.faceValues, boneModifiers: settings.boneModifiers)
        var handNote = "not applied"
        if let handPose = request.handPose {
            let hands = try SourceStudioHandPose.load(url: handPose)
            pose = try hands.applying(to: source.rig, basePose: pose)
            handNote = "\(handPose.path) (\(sha256(try Data(contentsOf: handPose)).prefix(12)))"
        }
        let expression: SourceExpressionInputs?
        switch request.expression {
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
        toonFrame = frame

        // The live path, configured as in the app, with the harness scene globals.
        let configuration = request.configuration
        let inputs = try configuration.inputs(makerLibrary: request.makerLibrary)
        let eyeLook = try request.lookSettings.map { try SourceStudioIrisRendering.bindingEyeLook(card: card, settings: $0) }
        bindings = try inputs.derive(card: card, scene: .originalCharacterProbeHarness, sceneReason: "", eyeLook: eyeLook)
        guard ["store", "capture"].contains(request.textureProvider) else { throw RigError.invalid("The live texture provider is store or capture.") }
        let shared = try configuration.loadShared(device: renderer.gpu.device,
            textures: request.textureProvider == "capture" ? try SourceShaderCaptureTextureProvider(frameURL: request.frame) : nil)
        assembly = SourceShaderLiveAssembly(bindings: bindings, programs: inputs.programs, resources: renderer.resources,
                                            textures: shared.textures, streams: shared.streams, anisotropicFiltering: anisotropicFiltering)
        attach = assembly.attach(to: &frame, resources: renderer.resources)
        self.frame = frame
        width = probe.width; height = probe.height; sourceFar = probe.sourceFar

        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let background = (original["background"] as? [NSNumber])?.map(\.doubleValue) ?? []
        clear = background.count == 4 ? MTLClearColorMake(linear(background[0]), linear(background[1]), linear(background[2]), background[3])
            : MTLClearColorMake(0, 0, 0, 0)
        let live = Set(frame.items.compactMap { $0.sourceShader?.material.family })
        liveFamilies = live.sorted()
        captureFamiliesNotLive = Set(((original["meshes"] as? [[String: Any]]) ?? []).flatMap { $0["materials"] as? [[String: Any]] ?? [] }
            .compactMap { ($0["shader"] as? String)?.components(separatedBy: "/").last }.filter { $0 != "shadowcast" }).subtracting(live).sorted()
        frameSHA256 = sha256(frameData)
        notes = shared.notes + settings.diagnostics
        self.inputs = [
            "captureFrame": request.frame.path, "captureFrameSHA256": frameSHA256, "avatar": request.avatar.path, "card": request.card.path,
            "cardSHA256": card.sourceSHA256, "handPose": handNote, "expression": request.expression ?? "none (base mesh)",
            "eyeLook": eyeLook?.source ?? "none (iris transforms unresolved)", "time": captureTime.map { "\($0) (capture _Time.y)" } ?? "frame default",
            "camera": "capture camera (\(probe.width)x\(probe.height), far \(probe.sourceFar))", "light": "capture light",
            "anisotropicFiltering": anisotropicFiltering ?? "per-texture",
            "sceneGlobals": SourceShaderBindingDerivation.SceneGlobals.originalCharacterProbeHarness.source,
            "textureProvider": shared.textures.label, "programs": inputs.programs.path, "headContract": inputs.headContract.path,
            "makerLibrary": inputs.makerLibrary.path, "supplement": inputs.supplement?.path ?? "none",
            "textures": configuration.textures?.path ?? "none", "streams": configuration.streams?.path ?? "none",
        ]
    }

    /// The validation renders `compare_original_frame.py` gates, by file name:
    /// `native-translated.png` (every live draw), `native-translated-<family>.png`
    /// per live family and `native-main_opaque.png` (garments) when drawn.
    public func translatedImages(renderer: Renderer) throws -> [(name: String, image: CGImage)] {
        var images = [(name: "native-translated.png", image: try renderer.captureSourceShaderLive(frame: frame, width: width, height: height, clear: clear))]
        for family in liveFamilies {
            images.append(("native-translated-\(family).png", try renderer.captureSourceShaderLive(frame: frame, width: width, height: height, families: [family])))
        }
        if liveFamilies.contains("main_opaque") {
            images.append(("native-main_opaque.png", try renderer.captureSourceShaderLive(frame: frame, width: width, height: height, families: ["main_opaque"])))
        }
        return images
    }

    /// `live-report.json`: every input, the binding provenance, resolution and
    /// attach lines, and the renderer's own fallbacks for the last frame.
    public func liveReport(renderer: SourceShaderLiveFrameReport) -> [String: Any] {
        ["schemaVersion": 1, "inputs": inputs, "notes": notes, "bindingProvenance": bindings.provenance, "resolution": assembly.resolution,
         "attach": ["live": attach.live, "fallbacks": attach.fallbacks, "hidden": attach.hidden, "unmatched": attach.unmatched],
         "renderer": ["draws": renderer.draws, "fallbacks": renderer.fallbacks],
         "liveFamilies": liveFamilies, "captureFamiliesNotLive": captureFamiliesNotLive]
    }

    /// `native-report.json` for the comparator (source frame identity and the
    /// per-material diagnostics).
    public func nativeReport(renderer: SourceShaderLiveFrameReport) -> [String: Any] {
        var diagnostics = assembly.resolution
        diagnostics += attach.fallbacks.map { "toon: \($0)" } + attach.hidden.map { "hidden: \($0)" } + attach.unmatched.map { "unmatched: \($0)" }
        diagnostics += renderer.fallbacks.map { "renderer: \($0)" }
        return ["schemaVersion": 1, "sourceFrameFile": request.frame.lastPathComponent, "sourceFrameSHA256": frameSHA256,
                "scope": "LIVE native rig (card shape, static ABMX, frozen Studio hand pose) drawn with the opt-in live source-shader path under the capture camera, light and _Time. Native rig evaluation is included; the capture's frozen geometry is not drawn. Not a production-parity claim.",
                "materialDiagnostics": diagnostics, "drawItems": frame.items.count]
    }
}
