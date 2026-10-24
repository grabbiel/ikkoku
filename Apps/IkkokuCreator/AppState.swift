import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Character
import CoreMath
import simd
import Scene
import Studio
import Renderer
import Assets

enum AppMode: String, CaseIterable, Identifiable {
    case maker = "Maker", studio = "Studio"
    var id: String { rawValue }
}

/// Top-level app state: the engine, the two editors and document commands.
@MainActor @Observable
final class AppState {
    var mode: AppMode = .maker {
        didSet {
            maker?.isActiveMode = mode == .maker
            studio?.isActiveMode = mode == .studio
            if mode == .maker { maker?.refresh() } else { studio?.refresh() }
        }
    }
    let host: EngineHost?
    /// The async Maker checklist outlives init. Keep its former headless
    /// behavior: no interactive views retaining previews or starting a viewport.
    let runsHeadlessMakerScenario: Bool
    var maker: MakerModel?
    var studio: StudioModel?
    var errorMessage: String?
    var modProfile: SourceModProfile?
    var modCatalog: SourceModCatalog?
    var modCatalogContract: SourceModCatalogContract?
    var modDependencies: [SourceModCatalog.Dependency] = []
    var showModLibrary = false
    nonisolated(unsafe) static var sharedStudio: StudioModel?
    /// `IKKOKU_CAPTURE_UI` readiness state (A-T05): set once the content's `onAppear` ran,
    /// and the poll tracker while a capture is armed.
    @ObservationIgnored private var uiCaptureContentAppeared = false
    @ObservationIgnored private var uiCaptureTracker: UICaptureReadiness.Tracker?

    init() {
        let env = ProcessInfo.processInfo.environment
        // A06: classify the whole capture request before any work. Conflicting
        // modes, options no requested mode reads and values a mode would ignore
        // exit 1 here with one message naming every offending variable.
        let request: CaptureRequest
        do { request = try CaptureRequest.validate(env) }
        catch { print("[ikkoku] \(error)"); exit(1) }
        runsHeadlessMakerScenario = request.mode == .makerScenario
        // R7: the performance trace records startup marks from here on.
        PerfTrace.startIfRequested(env)
        // A-T01: the gameplay host scenario is its own headless mode. It needs
        // no renderer, so it runs and exits before the engine and editors exist.
        if let scenarioPath = env["IKKOKU_GAMEPLAY_SCENARIO"] {
            AppState.runGameplayScenario(path: scenarioPath, reportPath: env["IKKOKU_GAMEPLAY_SCENARIO_REPORT"])
        }
        // In an automated run (any capture mode or IKKOKU_CAPTURE_UI) a startup
        // input that fails exits 1 naming it, instead of capturing other content.
        let automated = request.isAutomated
        do {
            let host = try EngineHost()
            self.host = host
            PerfTrace.mark("engineReady")
            if let probePath = env["IKKOKU_ORIGINAL_FRAME_PROBE"] {
                AppState.captureOriginalFrameProbe(host: host, path: probePath)
            }
            if let probePath = env["IKKOKU_LIVE_SOURCE_PROBE"] {
                AppState.captureLiveSourceShaderProbe(host: host, path: probePath)
            }
            if let rigPath = env["IKKOKU_CAPTURE_RIG"] {
                AppState.captureRig(host: host, path: rigPath)
            }
            if env["IKKOKU_CAPTURE_MODEL"] != nil {
                AppState.captureModelIfRequested(host: host)
            }
            if let scenePath = env["IKKOKU_CAPTURE_SCENE"] {
                AppState.captureScene(host: host, path: scenePath)
            }
            self.maker = MakerModel(host: host)
            PerfTrace.mark("makerReady")
            // The Maker falls back to the bundled character when the original base does not
            // open; with an explicit IKKOKU_SOURCE_AVATAR an automated run must not capture that.
            if automated, let avatar = env["IKKOKU_SOURCE_AVATAR"], let failure = maker?.sourceAvatarFailure {
                AppState.failCaptureInput("IKKOKU_SOURCE_AVATAR", avatar, failure)
            }
            self.studio = StudioModel(host: host)
            PerfTrace.mark("studioReady")
            if let path = env["IKKOKU_SOURCE_SCENE"] {
                do { try PerfTrace.step("sourceSceneImport") { try importSourceScenePreview(url: URL(fileURLWithPath: path)) } }
                catch { startupInputFailed("IKKOKU_SOURCE_SCENE", path, "Could not preview source scene", error, automated: automated) }
                // A-T02: an automated run must not capture or script a scene whose
                // characters all failed to build (for example a converted library
                // copied without its companion files).
                if automated, let outcome = studio?.sourcePreviewCharacterOutcome(), outcome.built == 0, let first = outcome.retained.first {
                    AppState.failCaptureInput("IKKOKU_SOURCE_SCENE", path,
                        "none of the scene's characters was built (\(outcome.retained.count) retained without rendering); first: \(first)")
                }
            }
            if let libraryPath = env["IKKOKU_MOD_LIBRARY"] {
                do { try loadModLibrary(url: URL(fileURLWithPath: libraryPath)) }
                catch { startupInputFailed("IKKOKU_MOD_LIBRARY", libraryPath, "Could not load mod library", error, automated: automated) }
            }
            maker?.refresh()
            if let path = env["IKKOKU_OPEN_RIG"] {
                do { try maker?.openSourceRig(url: URL(fileURLWithPath: path)) }
                catch { startupInputFailed("IKKOKU_OPEN_RIG", path, "Could not open source rig", error, automated: automated) }
            }
            if let path = env["IKKOKU_BONE_MODIFIERS"] {
                do { try maker?.loadBoneModifiers(url: URL(fileURLWithPath: path)) }
                catch { startupInputFailed("IKKOKU_BONE_MODIFIERS", path, "Could not load bone modifiers", error, automated: automated) }
            }
            if let path = env["IKKOKU_SOURCE_CARD"] {
                do { try PerfTrace.step("sourceCardImport") { try maker?.importSourceCardSettings(url: URL(fileURLWithPath: path)) } }
                catch {
                    startupInputFailed("IKKOKU_SOURCE_CARD", path, "Could not import source card settings", error, automated: automated)
                }
            }
            // The Maker scenario hook is its own headless mode (the mirror of
            // IKKOKU_STUDIO_SCENARIO below): it runs the JSON checklist
            // scenario over the imported source card, writes the report to
            // the required IKKOKU_MAKER_SCENARIO_REPORT and exits (0 when
            // every step passed, 1 otherwise) even when IKKOKU_AUTOCAPTURE is
            // unset — no capture is requested.
            if let scenarioPath = env["IKKOKU_MAKER_SCENARIO"] {
                Task { @MainActor in
                    do {
                        guard let maker, let reportPath = env["IKKOKU_MAKER_SCENARIO_REPORT"] else {
                            throw RigError.invalid("IKKOKU_MAKER_SCENARIO needs the Maker and IKKOKU_MAKER_SCENARIO_REPORT.")
                        }
                        let scenario = try JSONDecoder().decode(MakerScenario.self, from: try Data(contentsOf: URL(fileURLWithPath: scenarioPath)))
                        let report = await MakerScenario.run(scenario, maker: maker, app: self)
                        let reportURL = URL(fileURLWithPath: reportPath)
                        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try CaptureOutput.writeJSON(report.json(), to: reportURL)
                        print("[ikkoku] maker scenario: \(report.passed) passed, \(report.failed) failed")
                        exit(report.failed == 0 ? 0 : 1)
                    } catch { print("[ikkoku] maker scenario failed: \(error)"); exit(1) }
                }
                return
            }
            // Plugin mounts, deterministic steps and focus evidence. The adapter
            // report (IKKOKU_NATIVE_PLUGIN_REPORT) and focus events are capture-only:
            // validation accepts them only with IKKOKU_AUTOCAPTURE, so a failure here
            // always exits 1 instead of leaving the app open after a missing report.
            if let studio {
                do { try AppState.configureStudioExecution(studio) }
                catch {
                    if automated { print("[ikkoku] studio execution failed: \(error)"); exit(1) }
                    self.errorMessage = "Studio execution: \(error)"
                }
            }
            // The scenario hook is its own headless mode: it runs the JSON
            // checklist scenario over the imported source scene, writes the
            // report to the required IKKOKU_STUDIO_SCENARIO_REPORT and exits
            // (0 when every step passed, 1 otherwise) even when
            // IKKOKU_AUTOCAPTURE is unset — no capture is requested.
            if let scenarioPath = env["IKKOKU_STUDIO_SCENARIO"] {
                do {
                    guard let studio, let reportPath = env["IKKOKU_STUDIO_SCENARIO_REPORT"] else {
                        throw RigError.invalid("IKKOKU_STUDIO_SCENARIO needs the Studio and IKKOKU_STUDIO_SCENARIO_REPORT.")
                    }
                    let scenario = try JSONDecoder().decode(StudioScenario.self, from: try Data(contentsOf: URL(fileURLWithPath: scenarioPath)))
                    let report = StudioScenario.run(scenario, studio: studio)
                    let reportURL = URL(fileURLWithPath: reportPath)
                    try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try CaptureOutput.writeJSON(report.json(), to: reportURL)
                    print("[ikkoku] studio scenario: \(report.passed) passed, \(report.failed) failed")
                    exit(report.failed == 0 ? 0 : 1)
                } catch { print("[ikkoku] studio scenario failed: \(error)"); exit(1) }
            }
            AppState.sharedStudio = studio
            AppState.uiCaptureState = self
            PerfTrace.mark("appStateReady")
            AppState.runAutoCapture(host: host, maker: maker)
        } catch {
            self.host = nil
            self.errorMessage = "\(error)"
            // Without an engine no capture can run; do not snapshot the error window.
            if automated { print("[ikkoku] startup failed: \(error)"); exit(1) }
        }
        startUICaptureIfRequested()
    }

    /// A startup input failed (A06). An automated run exits 1 naming the variable, its
    /// value and the error; an interactive launch shows the alert and keeps running.
    private func startupInputFailed(_ variable: String, _ value: String, _ summary: String, _ error: Error, automated: Bool) {
        if automated { AppState.failCaptureInput(variable, value, "\(summary): \(error)") }
        errorMessage = "\(summary): \(error)"
    }

    /// Ends an automated run whose capture input could not be used, naming the
    /// variable, its value and why (A06), instead of capturing other content.
    static func failCaptureInput(_ variable: String, _ value: String, _ reason: String) -> Never {
        print("[ikkoku] capture input failed: \(CaptureInputError(variable: variable, value: value, reason: reason))")
        exit(1)
    }

    static func captureRig(host: EngineHost, path: String) {
        let env = ProcessInfo.processInfo.environment
        do {
            guard let output = env["IKKOKU_AUTOCAPTURE"] else { throw RigError.invalid("Rig capture requires IKKOKU_AUTOCAPTURE.") }
            let sourceURL = URL(fileURLWithPath: path)
            let source = try SourceRig.loadModel(url: sourceURL)
            let explicitContract = env["IKKOKU_SHAPE_CONTRACT"]
            let contractURL = explicitContract.map { URL(fileURLWithPath: $0) }
                ?? sourceURL.deletingLastPathComponent().appendingPathComponent("character-shape-contract.json")
            // An explicit contract must load (A06); only the sidecar beside the rig is optional.
            let contract = explicitContract != nil || FileManager.default.fileExists(atPath: contractURL.path)
                ? try SourceShapeContract.decode(Data(contentsOf: contractURL)) : nil
            let appearanceURL = sourceURL.deletingPathExtension().appendingPathExtension("appearance.json")
            let modLibrary = try env["IKKOKU_MOD_LIBRARY"].map {
                try SourceModProfile.load(libraryURL: URL(fileURLWithPath: $0), profile: env["IKKOKU_MOD_PROFILE"] ?? "default").library
            }
            let appearance = FileManager.default.fileExists(atPath: appearanceURL.path)
                ? try SourcePreviewAppearance.load(url: appearanceURL, resources: host.renderer.resources, modLibrary: modLibrary) : nil
            let expressionURL = sourceURL.deletingLastPathComponent().appendingPathComponent("source-expression-contract.json")
            let expressionContract = FileManager.default.fileExists(atPath: expressionURL.path)
                ? try SourceExpressionContract.decode(Data(contentsOf: expressionURL)) : nil
            let preview = try SourceRigPreview(source: source, contract: contract, resources: host.renderer.resources,
                                              appearance: appearance, expressionContract: expressionContract)
            let expression: SourceExpressionInputs?
            if let selection = env["IKKOKU_SOURCE_EXPRESSION"] {
                guard let expressionContract else { throw RigError.invalid("No source expression contract.") }
                if selection == "defaults" { expression = expressionContract.defaults }
                else if let preset = expressionContract.presets.first(where: { $0.id == selection }) { expression = preset.inputs }
                else { throw RigError.invalid("Unknown source expression preset '\(selection)'.") }
            } else { expression = nil }
            let cardSettings: SourceCharacterCard.PreviewSettings?
            if let cardPath = env["IKKOKU_SOURCE_CARD"] {
                guard let contract, preview.supportsBodyCustomization, preview.supportsFaceCustomization else {
                    throw RigError.invalid("Source card capture requires the recovered female shape contract.")
                }
                guard ["IKKOKU_SOURCE_BODY", "IKKOKU_SOURCE_FACE", "IKKOKU_SOURCE_HEIGHT", "IKKOKU_BONE_MODIFIERS"].allSatisfy({ env[$0] == nil }) else {
                    throw RigError.invalid("Source card capture cannot also specify separate shape or bone-modifier overrides.")
                }
                cardSettings = try SourceCharacterCard.load(url: URL(fileURLWithPath: cardPath)).previewSettings(contract: contract)
                for message in cardSettings?.diagnostics ?? [] { print("[ikkoku] card: \(message)") }
            } else { cardSettings = nil }
            let boneModifiers = try cardSettings?.boneModifiers ?? env["IKKOKU_BONE_MODIFIERS"].map { try SourceBoneModifiers.decode(Data(contentsOf: URL(fileURLWithPath: $0))) }
            func shapeValues(_ key: String, domain id: String, supported: Bool) throws -> [Float]? {
                guard let expression = env[key], expression != "rest" else { return nil }
                guard supported, let domain = contract?.domain(id) else { throw RigError.invalid("Unsupported \(id) customization.") }
                return try domain.values(overrides: expression)
            }
            let bodyValues = try cardSettings?.bodyValues ?? shapeValues("IKKOKU_SOURCE_BODY", domain: "body", supported: preview.supportsBodyCustomization)
            let faceValues = try cardSettings?.faceValues ?? shapeValues("IKKOKU_SOURCE_FACE", domain: "face", supported: preview.supportsFaceCustomization)
            let heightScale: Float?
            if let value = env["IKKOKU_SOURCE_HEIGHT"] {
                guard let rate = Float(value), rate.isFinite, (0...1).contains(rate) else { throw RigError.invalid("Source height must be between 0 and 1.") }
                heightScale = rate
            } else { heightScale = nil }
            // Keep the rest-pose camera fixed between height captures so deformation stays visible.
            let bounds = try preview.bounds(bodyValues: bodyValues, faceValues: faceValues, expression: expression, boneModifiers: boneModifiers)
            var camera = OrbitCamera()
            camera.target = bounds.center
            camera.yaw = (Float(env["IKKOKU_CAPTURE_YAW"] ?? "") ?? 180).degreesToRadians
            camera.pitch = 0.05
            camera.distance = max(bounds.radius, 0.1) / sin(camera.fovDegrees.degreesToRadians * 0.5) * 1.15
            if env["IKKOKU_CAPTURE_PRESET"] == "face" {
                guard let face = source.parts.first(where: { $0.mesh.name == "cf_O_face/0" }) else {
                    throw RigError.invalid("IKKOKU_CAPTURE_PRESET=face needs the rig's cf_O_face/0 part; this rig has none.")
                }
                let pose = try preview.evaluation(heightScale: heightScale, bodyValues: bodyValues, faceValues: faceValues, boneModifiers: boneModifiers)
                let faceBounds = AABB.of(points: try source.deformedPositions(part: face, evaluation: pose,
                    morphWeights: preview.expressionWeights(expression)[face.mesh.name] ?? []))
                camera.target = faceBounds.center
                camera.distance = max(faceBounds.radius, 0.02) / sin(camera.fovDegrees.degreesToRadians * 0.5) * 1.5
            }
            var effects = SceneEffects(); effects.showGrid = false
            var light = MainLight()
            if env["IKKOKU_CAPTURE_SHADOWS"] == "0" { light.castsShadow = false }
            let frame = try preview.frame(camera: camera, mainLight: light, effects: effects, heightScale: heightScale, bodyValues: bodyValues, faceValues: faceValues,
                                          expression: expression, boneModifiers: boneModifiers, showBones: env["IKKOKU_RIG_BONES"] == "1")
            let width = Int(env["IKKOKU_CAPTURE_W"] ?? "") ?? 960, height = Int(env["IKKOKU_CAPTURE_H"] ?? "") ?? 960
            guard width > 0, height > 0, width <= 8192, height <= 8192,
                  let image = host.renderer.capture(frame: frame, width: width, height: height) else {
                throw RigError.invalid("Rig capture failed or dimensions are outside 1...8192: \(host.renderer.lastDeformationErrors)")
            }
            try CaptureOutput.writePNG(image, to: URL(fileURLWithPath: output))
            print("[ikkoku] captured source rig with \(frame.items.count) parts and \(frame.skinSets.count) separate skin palettes to \(output)")
            exit(0)
        } catch { print("[ikkoku] rig capture failed: \(error)"); exit(1) }
    }

    func openSourceRig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Open a converted source rig. Optional character-shape-contract.json is loaded from the same folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try maker?.openSourceRig(url: url); mode = .maker }
        catch { errorMessage = "Could not open source rig: \(error)" }
    }

    private func importSourceScenePreview(url: URL) throws {
        guard let rig = try EngineHost.locateSourceAvatar() else { throw RigError.invalid("Export the original clothed avatar before previewing source scenes.") }
        let catalog = EngineHost.studioPoseContract(forRig: rig)
        try studio?.importSourceScenePreview(sceneURL: url, rigURL: rig, boneCatalogURL: catalog)
        // A-T02: an object the preview could not build is otherwise only listed
        // under Source compatibility details.
        for line in (studio?.doc.sourcePreviewDiagnostics ?? []) where line.contains(" retained without rendering") {
            print("[ikkoku] \(url.lastPathComponent): \(line)")
        }
        mode = .studio
    }

    func openSourceScenePreview() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png]; panel.allowsMultipleSelection = false
        panel.message = "Load converted card selections, source camera and saved poses. Missing conversions are listed in the compatibility report."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try importSourceScenePreview(url: url) }
        catch { errorMessage = "Could not preview source scene: \(error)" }
    }

    func exportSourceScene() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "edited-original-scene.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try studio?.exportSourceScene(to: url) }
        catch { errorMessage = "Could not export original scene: \(error)" }
    }

    func loadModLibrary(url: URL) throws {
        let profile = try SourceModProfile.load(libraryURL: url, profile: ProcessInfo.processInfo.environment["IKKOKU_MOD_PROFILE"] ?? "default")
        let explicitContract = ProcessInfo.processInfo.environment["IKKOKU_MOD_CATALOG_CONTRACT"]
        let contractURL = explicitContract.map { URL(fileURLWithPath: $0) }
            ?? url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("catalog-contract.json")
        let catalog: SourceModCatalog?
        let contract: SourceModCatalogContract?
        let dependencies: [SourceModCatalog.Dependency]
        if explicitContract != nil || FileManager.default.fileExists(atPath: contractURL.path) {
            let decoded = try SourceModCatalogContract.decode(Data(contentsOf: contractURL))
            contract = decoded
            catalog = try SourceModCatalog(library: profile.library, contract: decoded)
            dependencies = try catalog?.dependencies(library: profile.library, sourceAssets: decoded.sourceAssets ?? []) ?? []
        } else { catalog = nil; contract = nil; dependencies = [] }
        try maker?.setModLibrary(profile.library, catalog: catalog, contract: contract)
        modProfile = profile
        modCatalog = catalog
        modCatalogContract = contract
        modDependencies = dependencies
    }

    func openModLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose the library.json created by the mod importer."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try loadModLibrary(url: url); showModLibrary = true }
        catch { errorMessage = "Could not load mod library: \(error)" }
    }

    func openBoneModifiers() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose bone modifiers converted from ABMX data."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try maker?.loadBoneModifiers(url: url) }
        catch { errorMessage = "Could not load bone modifiers: \(error)" }
    }

    func importSourceCardSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.message = "Import original card shapes, ABMX settings and supported appearance colors. The matching female or male base is selected automatically."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try maker?.importSourceCardSettings(url: url) }
        catch { errorMessage = "Could not import source card settings: \(error)" }
    }

    func exportSourceCard() {
        guard let maker else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "character-edited.png"
        panel.message = "Export an edited original-format card as a new copy. Unknown fields and mod data are preserved."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try maker.exportSourceCard(to: url) }
        catch { errorMessage = "Could not export edited source card: \(error)" }
    }

    func reloadModLibrary() {
        guard let url = modProfile?.libraryURL else { return }
        do { try loadModLibrary(url: url) }
        catch { errorMessage = "Could not reload mod library: \(error)" }
    }

    func unloadModLibrary() {
        do { try maker?.setModLibrary(nil); modProfile = nil; modCatalog = nil; modCatalogContract = nil; modDependencies = [] }
        catch { errorMessage = "Could not restore the default appearance: \(error)" }
    }

    static func captureScene(host: EngineHost, path: String) {
        let env = ProcessInfo.processInfo.environment
        do {
            guard let output = env["IKKOKU_AUTOCAPTURE"] else { throw GLTFError.io("Scene capture requires IKKOKU_AUTOCAPTURE.") }
            let studio = StudioModel(host: host)
            studio.liveAnimation = false
            studio.showGizmos = false
            try studio.loadScene(from: URL(fileURLWithPath: path))
            try configureStudioExecution(studio)
            if let save = env["IKKOKU_SAVE_SCENE"] { try studio.saveScene(to: URL(fileURLWithPath: save)) }
            try loadSceneItemAssets(studio, host: host)
            studio.doc.effects.showGrid = false
            let width = Int(env["IKKOKU_CAPTURE_W"] ?? "") ?? 960
            let height = Int(env["IKKOKU_CAPTURE_H"] ?? "") ?? 720
            guard width > 0, height > 0, width <= 8192, height <= 8192,
                  let image = host.renderer.capture(frame: studio.frame, width: width, height: height) else {
                throw GLTFError.io("Scene capture failed or dimensions are outside 1...8192.")
            }
            try CaptureOutput.writePNG(image, to: URL(fileURLWithPath: output))
            print("[ikkoku] captured native scene \(path) to \(output)")
            exit(0)
        } catch {
            print("[ikkoku] scene capture failed: \(error)")
            exit(1)
        }
    }

    /// Loads the asset of every visible item in a native scene, so a capture fails naming
    /// the item instead of rendering without it (`IKKOKU_CAPTURE_SCENE`, `IKKOKU_LOAD_SCENE`).
    static func loadSceneItemAssets(_ studio: StudioModel, host: EngineHost) throws {
        for object in studio.doc.objects where object.kind == .item && studio.doc.isVisible(object.id) {
            // A-T02: a reference the scene's resource check left unresolved is never read.
            guard !studio.resourceBlockedObjects.contains(object.id) else {
                throw GLTFError.io("Scene item '\(object.name)' has an unresolved resource reference (see the scene's Unresolved lines).")
            }
            guard let file = object.assetFile ?? object.itemID.flatMap({ host.library.catalog.item($0)?.file }) else {
                throw GLTFError.io("Scene item '\(object.name)' has no resolvable asset reference.")
            }
            // A catalog item is a library package load; an absolute `assetFile` was
            // recorded from an explicit user import and keeps the trusted-file policy.
            if file.hasPrefix("/") {
                _ = try host.library.importTrustedStaticAsset(url: URL(fileURLWithPath: file))
            } else {
                _ = try host.library.importStaticAsset(url: host.library.url(file), packageRoot: host.library.root)
            }
        }
    }

    /// Isolated asset verification: does not construct a Maker character or alter a Studio document.
    static func captureModelIfRequested(host: EngineHost) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["IKKOKU_CAPTURE_MODEL"], let output = env["IKKOKU_AUTOCAPTURE"] else {
            print("[ikkoku] IKKOKU_CAPTURE_MODEL requires IKKOKU_AUTOCAPTURE.")
            exit(1)
        }
        do {
            let asset = try host.library.importTrustedStaticAsset(url: URL(fileURLWithPath: path))
            let mirror = env["IKKOKU_CAPTURE_MIRROR"] == "1" ? Transform.scale(Float3(-1, 1, 1)) : matrix_identity_float4x4
            var items: [RenderItem] = []
            var bounds = AABB.empty
            for part in asset.parts {
                let model = mirror * part.worldMatrix
                items.append(RenderItem(mesh: part.mesh, material: MaterialBuilder.itemMaterial(for: part, asset: asset, tint: nil),
                                        model: model, objectID: 1))
                bounds.expand(part.bounds.transformed(by: model))
            }
            let width = Int(env["IKKOKU_CAPTURE_W"] ?? "") ?? 960
            let height = Int(env["IKKOKU_CAPTURE_H"] ?? "") ?? 720
            guard width > 0, height > 0, width <= 8192, height <= 8192 else {
                throw GLTFError.io("Capture dimensions must be between 1 and 8192.")
            }
            var camera = OrbitCamera()
            camera.target = bounds.center
            camera.yaw = (Float(env["IKKOKU_CAPTURE_YAW"] ?? "") ?? 30).degreesToRadians
            camera.pitch = 15 * .pi / 180
            let halfY = camera.fovDegrees.degreesToRadians * 0.5
            let halfX = atan(tan(halfY) * Float(width) / Float(height))
            camera.distance = max(bounds.radius, 0.1) / sin(min(halfX, halfY)) * 1.1
            var effects = SceneEffects()
            effects.showGrid = false
            let frame = RenderFrame(camera: camera, items: items, effects: effects, sceneBounds: bounds)
            guard let image = host.renderer.capture(frame: frame, width: width, height: height) else {
                throw GLTFError.io("Metal capture failed.")
            }
            try CaptureOutput.writePNG(image, to: URL(fileURLWithPath: output))
            print("[ikkoku] captured \(asset.parts.count) parts from \(path) to \(output)")
            exit(0)
        } catch {
            print("[ikkoku] model capture failed: \(error)")
            exit(1)
        }
    }

    /// Development aid: IKKOKU_AUTOCAPTURE=<png path> renders the maker scene offscreen and exits.
    /// IKKOKU_CAPTURE_PRESET=face|upper|full picks the camera; IKKOKU_CARD=<png> loads a card first.
    /// `CaptureRequest.validate` has already checked the option combination and value syntax
    /// (A06); here an input that cannot be applied exits 1 naming it instead of being skipped.
    static func runAutoCapture(host: EngineHost, maker: MakerModel?) {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["IKKOKU_RENDER_THUMBS"], let maker {
            exit(renderThumbnails(host: host, maker: maker, dir: URL(fileURLWithPath: dir)) ? 0 : 1)
        }
        guard let out = env["IKKOKU_AUTOCAPTURE"], let maker else { return }
        if let cardPath = env["IKKOKU_CARD"] {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: cardPath))
                let card = try CardIO.decode(CharacterCard.self, keyword: CardIO.cardKeyword, from: data)
                maker.load(card: card)
            } catch { failCaptureInput("IKKOKU_CARD", cardPath, "not a readable Ikkoku card: \(error)") }
        }
        if env["IKKOKU_CAPTURE_SEX"] == "m", maker.importedSourceCard == nil {
            maker.newCharacter(sex: .male)
            if let avatar = env["IKKOKU_SOURCE_MALE_AVATAR"], let failure = maker.sourceAvatarFailure {
                failCaptureInput("IKKOKU_SOURCE_MALE_AVATAR", avatar, failure)
            }
        }
        do {
            if let expression = env["IKKOKU_SOURCE_BODY"] {
                guard let domain = maker.sourceRigPreview?.contract?.domain("body") else {
                    throw RigError.invalid("IKKOKU_SOURCE_BODY needs a source rig preview with the recovered body shape contract.")
                }
                maker.sourceBodyValues = try domain.values(overrides: expression)
                if maker.sourceSex == 0 { maker.sourceBodyValues[0] = 0.6 }
            }
            if let expression = env["IKKOKU_SOURCE_FACE"] {
                guard let domain = maker.sourceRigPreview?.contract?.domain("face") else {
                    throw RigError.invalid("IKKOKU_SOURCE_FACE needs a source rig preview with the recovered face shape contract.")
                }
                maker.sourceFaceValues = try domain.values(overrides: expression)
            }
            if let text = env["IKKOKU_SOURCE_COORDINATE"] {
                guard let outfit = Int(text) else { throw RigError.invalid("IKKOKU_SOURCE_COORDINATE must be an integer.") }
                try maker.selectSourceCoordinate(outfit)
            }
            if let path = env["IKKOKU_SOURCE_COLOR_EDITS"] {
                let edits = try JSONDecoder().decode([String: [Float]].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                for (id, rgba) in edits {
                    guard rgba.count == 4, rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }), maker.sourceAppearanceAppliedFields.contains(id) else { throw RigError.invalid("Capture color edit is not supported: \(id).") }
                    maker.setSourceColor(id, rgba: Float4(rgba))
                }
                try maker.applySourceAppearance()
            }
        } catch { print("[ikkoku] source appearance input failed: \(error)"); exit(1) }
        if let sl = env["IKKOKU_CAPTURE_SLIDERS"] {          // "eye.size=80,body.height=-50"
            var c = maker.card
            for pair in sl.split(separator: ",") {
                let kv = pair.split(separator: "=")
                guard kv.count == 2, let v = Float(kv[1]), SliderRegistry.shared.slider(String(kv[0])) != nil else {
                    failCaptureInput("IKKOKU_CAPTURE_SLIDERS", sl, "'\(pair)' does not name a registered slider and a value")
                }
                c.setSlider(String(kv[0]), v)
            }
            maker.card = c
        }
        if let ex = env["IKKOKU_CAPTURE_EXPR"] {              // "eyes=1,mouth=3,brows=2"
            var c = maker.card
            for pair in ex.split(separator: ",") {
                let kv = pair.split(separator: "="); guard kv.count == 2, let v = Int(kv[1]) else { continue }
                switch kv[0] { case "eyes": c.expression.eyes = v; case "mouth": c.expression.mouth = v; case "brows": c.expression.eyebrows = v
                case "head": c.expression.headLook = v != 0; case "gaze": c.expression.gazeMode = v; default: break }
            }
            maker.card = c
        }
        if let o = env["IKKOKU_CAPTURE_OUTFIT"] {
            // The card clamps an out-of-range outfit to another one; refuse it instead.
            guard let i = Int(o), maker.card.outfits.indices.contains(i) else {
                failCaptureInput("IKKOKU_CAPTURE_OUTFIT", o, "the card has \(maker.card.outfits.count) outfits")
            }
            maker.card.currentOutfit = i
        }
        if let hair = env["IKKOKU_CAPTURE_HAIR"] {
            guard host.library.catalog.hair.contains(where: { $0.id == hair }) else {
                failCaptureInput("IKKOKU_CAPTURE_HAIR", hair, "no hair style with this ID in the asset catalog")
            }
            maker.card.hair.parts[.back] = HairPart(styleID: hair)
        }
        if let duration = env["IKKOKU_SOURCE_PLAYBACK_SECONDS"] {
            do {
                guard let seconds = Float(duration), seconds.isFinite, (0...30).contains(seconds) else {
                    throw RigError.invalid("Source capture playback must be 0...30 seconds.")
                }
                let ticks = Int(ceil(seconds * 60))
                for i in 0..<ticks {
                    try maker.advanceSourceMotion(deltaTime: min(1 / 60, seconds - Float(i) / 60))
                }
                maker.refresh()
            } catch { fputs("Source playback capture failed: \(error)\n", stderr); exit(1) }
        }
        if let preset = env["IKKOKU_CAPTURE_PRESET"].flatMap({ CameraPreset(rawValue: $0.capitalized) }) { maker.apply(preset: preset) }
        if let yaw = env["IKKOKU_CAPTURE_YAW"].flatMap({ Float($0) }) { var c = maker.camera; c.yaw = yaw * .pi / 180; maker.camera = c }
        if let ticks = Int(env["IKKOKU_CAPTURE_TICKS"] ?? "") {      // advance idle/hair simulation
            for i in 0..<ticks {
                // nudge the head sideways for a few ticks so hair chains get a push
                var c = maker.camera; c.target.x = i < ticks / 2 ? 0.05 : -0.05; maker.camera = c
                maker.character.transform = Transform.translation(Float3(sin(Float(i) * 0.4) * 0.15, 0, 0))
                maker.character.stepHairDynamics(dt: 1.0 / 30.0)
            }
            maker.character.transform = matrix_identity_float4x4
            maker.refresh()
        }
        if maker.importedSourceCard != nil {
            print("[ikkoku] source card sex=\(maker.sourceSex), outfit=\(maker.sourceBoneModifierCoordinate), body=\(maker.sourceRigPreview?.bodyCoverage?.completeSlots.count ?? 0), appearance=\(maker.sourceAppearanceAppliedFields.count)")
            for message in maker.sourceAppearanceDiagnostics { print("[ikkoku] appearance: \(message)") }
        }
        let w = Int(env["IKKOKU_CAPTURE_W"] ?? "") ?? 1200, h = Int(env["IKKOKU_CAPTURE_H"] ?? "") ?? 1600
        var frame = host.renderer.currentFrame()
        if env["IKKOKU_SOURCE_SCENE"] != nil, let studio = AppState.sharedStudio {
            if let path = env["IKKOKU_SOURCE_SCENE_EDITS"] {
                do { try studio.applySourceCaptureEdits(Data(contentsOf: URL(fileURLWithPath: path))) }
                catch { print("[ikkoku] source scene capture edits failed: \(error)"); exit(1) }
            }
            studio.refresh(); frame = studio.frame
        }
        if env["IKKOKU_CAPTURE_STUDIO"] != nil, let studio = AppState.sharedStudio {
            studio.addCharacter(maker.card)
            if let pose = env["IKKOKU_CAPTURE_POSE"] {
                guard PosePresets.preset(pose) != nil else {
                    failCaptureInput("IKKOKU_CAPTURE_POSE", pose, "no built-in pose preset with this ID")
                }
                if let id = studio.selection { studio.update(id) { $0.animationPreset = pose; $0.handGestureL = 4; $0.handGestureR = 2 } }
            }
            if let items = env["IKKOKU_CAPTURE_ITEMS"] {           // "chair,room_classroom"
                for (k, id) in items.split(separator: ",").enumerated() {
                    // `addItem` skips an unknown ID silently; a capture must not.
                    guard host.library.catalog.item(String(id)) != nil else {
                        failCaptureInput("IKKOKU_CAPTURE_ITEMS", items, "no catalog item '\(id)'")
                    }
                    studio.addItem(id: String(id))
                    if let sel = studio.selection, !String(id).hasPrefix("room"), !String(id).hasPrefix("sky") {
                        studio.update(sel) { $0.transform.position = Float3(0.9 + Float(k) * 0.8, 0, -0.3) }
                    }
                }
                if let first = studio.doc.objects.first { studio.selection = first.id }
            }
            if env["IKKOKU_CAPTURE_TIMELINE"] != nil, let id = studio.selection {
                studio.update(id) { $0.animationPreset = "apose"; $0.transform.position = Float3(-0.4, 0, 0) }
                studio.timelineTime = 0; studio.addKeyframe()
                studio.update(id) { $0.animationPreset = "wave"; $0.transform.position = Float3(0.4, 0, 0); $0.transform.rotation = Float3(0, 40, 0) }
                studio.timelineTime = 2; studio.addKeyframe()
                studio.timelineTime = Float(env["IKKOKU_CAPTURE_TIMELINE"] ?? "1") ?? 1
            }
            studio.addLight(.point)
            if let id = studio.doc.objects.first?.id { studio.selection = id; studio.poseMode = .fk; studio.selectedBone = studio.selectedInstance?.skeleton?["upperarm_L"] }
            studio.doc.camera.yaw = 0.4; studio.doc.camera.pitch = 0.15
            studio.refresh()
            frame = studio.frame
        }
        // Requested document outputs are required: a failed or empty save quits nonzero (A-T05).
        if let savePath = env["IKKOKU_EXPORT_SOURCE_CARD"] {
            do {
                try maker.exportSourceCard(to: URL(fileURLWithPath: savePath))
                try CaptureOutput.verifyNonempty(at: URL(fileURLWithPath: savePath))
                frame = host.renderer.currentFrame(); print("[ikkoku] edited source card exported to \(savePath)")
            } catch { print("[ikkoku] edited source card export failed: \(error)"); exit(1) }
        }
        if let savePath = env["IKKOKU_SAVE_CARD"] {                 // exercise the real card writer (thumbnail + JSON)
            do {
                try maker.saveCard(to: URL(fileURLWithPath: savePath))
                try CaptureOutput.verifyNonempty(at: URL(fileURLWithPath: savePath))
                print("[ikkoku] card saved to \(savePath)")
            } catch { print("[ikkoku] card save failed: \(error)"); exit(1) }
        }
        if let scenePath = env["IKKOKU_SAVE_SCENE"], let studio = AppState.sharedStudio {
            do {
                try studio.saveScene(to: URL(fileURLWithPath: scenePath))
                try CaptureOutput.verifyNonempty(at: URL(fileURLWithPath: scenePath))
                print("[ikkoku] scene saved to \(scenePath)")
            } catch { print("[ikkoku] scene save failed: \(error)"); exit(1) }
        }
        if let scenePath = env["IKKOKU_LOAD_SCENE"], let studio = AppState.sharedStudio {
            // A06: a scene that does not load, or whose items do not, ends the run
            // instead of capturing the previous frame.
            do {
                try studio.loadScene(from: URL(fileURLWithPath: scenePath))
                try loadSceneItemAssets(studio, host: host)
                frame = studio.frame
                print("[ikkoku] scene loaded: \(studio.doc.objects.count) objects")
            } catch { failCaptureInput("IKKOKU_LOAD_SCENE", scenePath, "\(error)") }
        }
        if let path = env["IKKOKU_EXPORT_SOURCE_SCENE"], let studio = AppState.sharedStudio {
            do {
                try studio.exportSourceScene(to: URL(fileURLWithPath: path))
                try CaptureOutput.verifyNonempty(at: URL(fileURLWithPath: path))
                print("[ikkoku] edited original scene exported to \(path)")
            } catch { print("[ikkoku] original scene export failed: \(error)"); exit(1) }
        }
        if env["IKKOKU_CAPTURE_GRID"] == "0" { frame.effects.showGrid = false }
        if env["IKKOKU_CAPTURE_GIZMOS"] == "0" { frame.gizmos = [] }
        if let output = env["IKKOKU_BENCHMARK_OUTPUT"] {
            do {
                let report = try host.renderer.benchmark(frame: frame, width: w, height: h,
                    measuredFrames: Int(env["IKKOKU_BENCHMARK_FRAMES"] ?? "20") ?? 20)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                var document = try JSONSerialization.jsonObject(with: encoder.encode(report)) as! [String: Any]
                document["sourceCardSHA256"] = maker.importedSourceCard?.sourceSHA256
                document["assembly"] = maker.sourceRigURL?.path
                document["coordinate"] = maker.sourceBoneModifierCoordinate
                document["appearanceFieldCount"] = maker.sourceAppearanceAppliedFields.count
                document["assetSelections"] = maker.sourceAssetSelections.map { selected -> [String: Any] in
                    var row: [String: Any] = ["property": selected.property, "category": selected.category,
                        "savedID": selected.savedID, "sourceID": selected.sourceID, "status": selected.status]
                    row["modGUID"] = selected.modGUID
                    return row
                }
                document["coverageScope"] = "Selected converted assets for this card; not whole-game catalog coverage."
                document["diagnostics"] = maker.sourceAppearanceDiagnostics
                if env["IKKOKU_SOURCE_SCENE"] != nil, let studio = AppState.sharedStudio {
                    for key in ["sourceCardSHA256", "assembly", "coordinate", "appearanceFieldCount", "assetSelections", "diagnostics"] { document.removeValue(forKey: key) }
                    document["studio"] = studio.sourceBenchmarkMetadata()
                    if studio.liveSourceShaders { document["liveSourceShaders"] = studio.liveSourceShaderReport() }
                    if let text = env["IKKOKU_BENCHMARK_SIMULATION_FRAMES"] {
                        guard let frames = Int(text) else { throw GLTFError.io("Invalid Studio simulation benchmark frame count.") }
                        document["simulation"] = try studio.benchmarkSourceEvaluation(measuredFrames: frames)
                    }
                }
                try CaptureOutput.writeJSON(JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
                                            to: URL(fileURLWithPath: output))
                print("[ikkoku] benchmark written to \(output)")
            } catch { print("[ikkoku] benchmark failed: \(error)"); exit(1) }
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        if let img = host.renderer.capture(frame: frame, width: w, height: h) {
            do { try CaptureOutput.writePNG(img, to: URL(fileURLWithPath: out)) }
            catch { print("[ikkoku] autocapture write failed: \(error)"); exit(1) }
            print("[ikkoku] autocapture written to \(out) (\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms, \(frame.items.count) items)")
        } else { print("[ikkoku] autocapture failed: the renderer returned no image for \(out)"); exit(1) }
        // The live source-shader status of the captured frame (R1/CMT-04): a required output.
        if let reportPath = env["IKKOKU_LIVE_SOURCE_REPORT"] {
            guard let studio = AppState.sharedStudio else { print("[ikkoku] IKKOKU_LIVE_SOURCE_REPORT needs the Studio"); exit(1) }
            do {
                try CaptureOutput.writeJSON(JSONSerialization.data(withJSONObject: studio.liveSourceShaderReport(), options: [.prettyPrinted, .sortedKeys]),
                                            to: URL(fileURLWithPath: reportPath))
                print("[ikkoku] live source-shader report written to \(reportPath)")
            } catch { print("[ikkoku] live source-shader report failed: \(error)"); exit(1) }
        }
        if env["IKKOKU_CAPTURE_UI"] != nil {
            // Real window snapshot once the window is ready; handled by the readiness poll
            // that `startUICaptureIfRequested` arms at the end of `init`.
            for line in host.library.log { print("[ikkoku] \(line)") }
            return
        }
        for line in host.library.log { print("[ikkoku] \(line)") }
        exit(0)
    }
    nonisolated(unsafe) static var uiCaptureState: AppState?

    /// `IKKOKU_RENDER_THUMBS=<dir>`: renders one 256×256 preview per catalog entry (hair, clothes, accessories, items).
    /// Every entry is attempted and written through the checked PNG path (A-T05). Each entry that
    /// could not be loaded, rendered or written is reported by path, and the result is false — the
    /// run exits nonzero — when any entry failed or nothing was written.
    static func renderThumbnails(host: EngineHost, maker: MakerModel, dir: URL) -> Bool {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { print("[ikkoku] thumbnails failed: could not create \(dir.path): \(error.localizedDescription)"); return false }
        var batch = CaptureOutputBatch()
        func writeThumbnail(_ name: String, _ image: CGImage?) {
            let url = dir.appendingPathComponent(name)
            batch.attempt(url) {
                guard let image else { throw CaptureOutputError(path: url.path, reason: .imageUnavailable("the renderer returned no image")) }
                try CaptureOutput.writePNG(image, to: url)
            }
        }
        let cat = host.library.catalog
        let base = CharacterCard.defaultFemale()
        var plain = base
        plain.hair.parts = [:]
        for i in plain.outfits.indices { plain.outfits[i].items = [:] }
        plain.outfits[0].items[.bra] = ClothItem(itemID: "bra_plain"); plain.outfits[0].items[.underwear] = ClothItem(itemID: "underwear_plain")
        plain.accessories = (0..<20).map { _ in AccessoryDefinition() }
        // Hair
        for h in cat.hair {
            var c = plain
            c.sex = (h.sex == "m") ? .male : .female; c.body.bodyID = c.sex == .male ? "body_m" : "body_f"
            c.hair.parts = [.back: HairPart(styleID: h.id)]
            maker.card = c
            maker.apply(preset: .face)
            var cam = maker.camera; cam.yaw = 22 * .pi / 180; cam.pitch = 0.08; cam.target = Float3(0, maker.character.eyeHeight - 0.02, 0); cam.distance *= 1.9; maker.camera = cam
            var f = host.renderer.currentFrame(); f.effects.showGrid = false
            writeThumbnail("hair_\(h.id).png", host.renderer.capture(frame: f, width: 256, height: 256))
        }
        // Clothes
        for cl in cat.clothes {
            var c = plain
            c.sex = (cl.sex == "m") ? .male : .female; c.body.bodyID = c.sex == .male ? "body_m" : "body_f"
            if let slot = ClothSlot(rawValue: cl.slot) { c.outfits[0].items[slot] = ClothItem(itemID: cl.id) }
            maker.card = c
            let lower = ["bottom", "socks", "shoes_in", "shoes_out", "pantyhose", "underwear"].contains(cl.slot)
            let hands = cl.slot == "gloves"
            maker.apply(preset: .full)
            var cam = maker.camera
            cam.yaw = 18 * .pi / 180
            if lower { cam.target = Float3(0, 0.5, 0); cam.distance *= 0.55 } else if hands { cam.target = Float3(0.38, 0.95, 0); cam.distance *= 0.32 } else { cam.target = Float3(0, 1.15, 0); cam.distance *= 0.6 }
            maker.camera = cam
            var f = host.renderer.currentFrame(); f.effects.showGrid = false
            writeThumbnail("cloth_\(cl.id).png", host.renderer.capture(frame: f, width: 256, height: 256))
        }
        // Accessories
        for a in cat.accessories {
            var c = plain
            c.hair.parts = [.back: HairPart(styleID: "bob")]
            c.accessories[0] = AccessoryDefinition(itemID: a.id)
            if let p = a.parent { c.accessories[0].parent = p }
            maker.card = c
            maker.apply(preset: .face)
            var cam = maker.camera; cam.yaw = 28 * .pi / 180; cam.pitch = 0.12; cam.target = Float3(0, maker.character.eyeHeight, 0); cam.distance *= 1.7; maker.camera = cam
            var f = host.renderer.currentFrame(); f.effects.showGrid = false
            writeThumbnail("acc_\(a.id).png", host.renderer.capture(frame: f, width: 256, height: 256))
        }
        // Items: a static prop alone in the frame
        for it in cat.items {
            guard let asset = host.library.asset(it.file) else {
                batch.record(CaptureOutputError(path: dir.appendingPathComponent("item_\(it.id).png").path,
                                                reason: .imageUnavailable("asset \(it.file) could not be loaded")))
                continue
            }
            var items: [RenderItem] = []
            var bounds = AABB.empty
            for part in asset.parts {
                items.append(RenderItem(mesh: part.mesh, material: MaterialBuilder.itemMaterial(for: part, asset: asset, tint: nil), model: part.worldMatrix, objectID: 1))
                bounds.expand(part.bounds.transformed(by: part.worldMatrix))
            }
            var cam = OrbitCamera()
            cam.target = bounds.center; cam.distance = max(bounds.radius, 0.2) * 2.6; cam.yaw = 0.6; cam.pitch = 0.35
            var fx = SceneEffects(); fx.showGrid = it.category != "Rooms" && it.category != "Sky"
            var f = RenderFrame(camera: cam, items: items, effects: fx, sceneBounds: bounds)
            if it.category == "Sky" || it.category == "Rooms" { cam.distance = max(bounds.radius, 0.2) * 0.9; f.camera = cam }
            writeThumbnail("item_\(it.id).png", host.renderer.capture(frame: f, width: 256, height: 256))
        }
        for failure in batch.failures { print("[ikkoku] thumbnail failed: \(failure)") }
        guard batch.isComplete else {
            print("[ikkoku] thumbnails incomplete in \(dir.path): \(batch.written.count) written, \(batch.failures.count) failed")
            return false
        }
        print("[ikkoku] \(batch.written.count) thumbnails written to \(dir.path)")
        return true
    }

    /// `IKKOKU_CAPTURE_UI=<png>`: snapshot the main window's AppKit/SwiftUI content
    /// (no screen-recording permission needed), then quit. `IKKOKU_CAPTURE_UI_MODE=studio`
    /// selects the first source character (falling back to the Maker card) and
    /// `IKKOKU_CAPTURE_UI_STUDIO_TAB` picks the inspector tab. `IKKOKU_CAPTURE_UI_REPORT=<json>`
    /// also writes a report of the inspector actually shown — even when the PNG fails or
    /// readiness times out — and the process quits nonzero if either output is missing.
    /// Called from `ContentView.onAppear`: applies the requested UI state once and marks the
    /// content as appeared for the readiness poll armed by `startUICaptureIfRequested`.
    func snapshotWindowIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["IKKOKU_CAPTURE_UI"] != nil, !uiCaptureContentAppeared else { return }
        if let tabText = env["IKKOKU_CAPTURE_UI_TAB"] {
            guard let tab = MakerTab(rawValue: tabText.capitalized) else {
                print("[ikkoku] unknown IKKOKU_CAPTURE_UI_TAB '\(tabText)'")
                exit(1)
            }
            maker?.tab = tab
        }
        if env["IKKOKU_CAPTURE_UI_MODE"] == "studio" {
            mode = .studio
            if let studio {
                // With IKKOKU_SOURCE_SCENE the first source character is already selected;
                // otherwise select the first original object, else add a Maker card.
                if let source = studio.doc.objects.first(where: { $0.sourceCharacter != nil }) {
                    studio.selection = source.id
                } else if studio.doc.objects.isEmpty, let card = maker?.card {
                    studio.addCharacter(card); studio.inspectorTab = .pose
                }
                if let tabText = env["IKKOKU_CAPTURE_UI_STUDIO_TAB"] {
                    guard let tab = StudioModel.InspectorTab.allCases.first(where: { $0.rawValue.lowercased() == tabText.lowercased() }) else {
                        print("[ikkoku] unknown IKKOKU_CAPTURE_UI_STUDIO_TAB '\(tabText)'")
                        exit(1)
                    }
                    studio.inspectorTab = tab
                }
            }
        }
        uiCaptureContentAppeared = true
    }

    /// Arms the `IKKOKU_CAPTURE_UI` readiness poll at the end of startup (A-T05). Instead of a
    /// fixed delay, a main-run-loop timer observes the window every
    /// `UICaptureReadiness.pollInterval` seconds and captures once the content has appeared in a
    /// visible window whose laid-out bounds are nonzero and unchanged for `stableObservations`
    /// polls. After `IKKOKU_CAPTURE_UI_TIMEOUT` seconds (default 30) without readiness it writes
    /// the report and quits nonzero, naming what was not ready. Arming here rather than in
    /// `onAppear` bounds the wait even when no window ever appears.
    private func startUICaptureIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["IKKOKU_CAPTURE_UI"] != nil, uiCaptureTracker == nil else { return }
        let policy: UICaptureReadiness
        do { policy = try UICaptureReadiness.fromEnvironment(env) }
        catch { print("[ikkoku] ui snapshot failed: \(error)"); exit(1) }
        uiCaptureTracker = UICaptureReadiness.Tracker(policy: policy)
        let armed = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: policy.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollUICapture(elapsed: ProcessInfo.processInfo.systemUptime - armed) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// One readiness poll. Forces layout, observes the window and, once ready, writes the PNG
    /// through the checked path; "written" is printed only after that file verified.
    private func pollUICapture(elapsed: Double) {
        let env = ProcessInfo.processInfo.environment
        guard var tracker = uiCaptureTracker, let out = env["IKKOKU_CAPTURE_UI"] else { return }
        let window = NSApp?.windows.first(where: { $0.isVisible && $0.contentView != nil })
        let view = window?.contentView
        view?.layoutSubtreeIfNeeded()
        let bounds = view?.bounds ?? .zero
        let decision = tracker.observe(UICaptureReadiness.Observation(
            contentAppeared: uiCaptureContentAppeared, windowVisible: window != nil,
            width: Double(bounds.width), height: Double(bounds.height)), elapsed: elapsed)
        uiCaptureTracker = tracker
        switch decision {
        case .wait:
            return
        case .timedOut(let reason):
            uiCaptureTracker = nil
            print("[ikkoku] ui snapshot failed: \(out): \(reason)")
            writeUICaptureReport(to: env["IKKOKU_CAPTURE_UI_REPORT"])
            exit(1)
        case .capture:
            uiCaptureTracker = nil
            var failed = false
            do {
                guard let view else {
                    throw CaptureOutputError(path: out, reason: .imageUnavailable("the window closed before capture"))
                }
                let size = try writeWindowSnapshot(view, to: URL(fileURLWithPath: out))
                print("[ikkoku] ui snapshot written to \(out) (\(size.width)x\(size.height) px, ready after \(String(format: "%.2f", elapsed)) s)")
            } catch {
                print("[ikkoku] ui snapshot failed: \(error)")
                failed = true
            }
            // Write the report even if the PNG failed; quit nonzero if either output is missing.
            writeUICaptureReport(to: env["IKKOKU_CAPTURE_UI_REPORT"])
            exit(failed ? 1 : 0)
        }
    }

    /// Draws the window content into a bitmap and writes it as a verified PNG.
    private func writeWindowSnapshot(_ view: NSView, to url: URL) throws -> (width: Int, height: Int) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CaptureOutputError(path: url.path, reason: .imageUnavailable("no bitmap for the window content"))
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else {
            throw CaptureOutputError(path: url.path, reason: .imageUnavailable("the cached window display has no image"))
        }
        try CaptureOutput.writePNG(image, to: url)
        return (image.width, image.height)
    }

    /// Writes the headless UI-capture report describing the inspector actually shown.
    private func writeUICaptureReport(to path: String?) {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        var kindName = "none"
        if let o = studio?.selectedObject { kindName = String(describing: o.kind) }
        let labelCount = studio.flatMap { model -> Int? in model.selectedObject.map { model.sourceAccessoryLabels(for: $0.id).count } } ?? 0
        let expected = studio?.inspectorViewName ?? "none"
        let displayed = studio?.displayedInspectorView ?? "none"
        if displayed != expected {
            print("[ikkoku] ui report: inspector mismatch expected=\(expected) displayed=\(displayed)")
        }
        let animationSelection: Any
        if let state = studio?.selectedSourceAnimationState {
            animationSelection = ["group": state.group, "category": state.category, "no": state.no,
                "speed": state.speed, "forceLoop": state.forceLoop, "normalizedTime": state.normalizedTime]
        } else {
            animationSelection = NSNull()
        }
        let report: [String: Any] = [
            "mode": mode.rawValue.lowercased(),
            "inspectorTab": studio?.inspectorTab.rawValue.lowercased() ?? "none",
            "selectedObjectKind": kindName,
            "selectedIsSourceCharacter": studio?.selectedIsSourceCharacter ?? false,
            "inspectorView": displayed,
            "expectedInspectorView": expected,
            "sourceIKAvailable": studio?.sourceIKAvailable ?? false,
            "sourceAccessoryLabelCount": labelCount,
            "sourceAnimationInspectorShown": studio?.sourceAnimationInspectorShown ?? false,
            "sourceAnimationCatalogEntries": studio?.sourceAnimationCatalog?.entries.count ?? 0,
            "sourceAnimationExecutableEntries": studio?.sourceAnimationCatalog?.entries.filter { $0.file != nil }.count ?? 0,
            "sourceAnimationSelection": animationSelection,
        ]
        do {
            try CaptureOutput.writeJSON(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), to: url)
            print("[ikkoku] ui report written to \(path)")
        } catch {
            print("[ikkoku] ui report failed: \(error)")
            exit(1)
        }
    }

    // MARK: Document commands

    func importModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "glb"), UTType(filenameExtension: "gltf")].compactMap { $0 }
        panel.message = "Import a converted static model into Studio"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try studio?.importModel(from: url); mode = .studio }
        catch { errorMessage = "Could not import model: \(error)" }
    }

    func importKoikatsuLayout() {
        let scenePanel = NSOpenPanel()
        scenePanel.allowedContentTypes = [.png]
        scenePanel.message = "Import a CharaStudio prop/folder layout. Characters, lights and cameras are not yet supported."
        guard scenePanel.runModal() == .OK, let source = scenePanel.url else { return }
        let catalogPanel = NSOpenPanel()
        catalogPanel.allowedContentTypes = [.json]
        catalogPanel.message = "Select the converted asset catalog for this layout"
        guard catalogPanel.runModal() == .OK, let catalog = catalogPanel.url else { return }
        do { try studio?.importKoikatsuLayout(sceneURL: source, catalogURL: catalog); mode = .studio }
        catch { errorMessage = "Could not import CharaStudio layout: \(error)" }
    }

    func openCard() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.message = "Open an Ikkoku or original character card (PNG)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            if let card = try? CardIO.decode(CharacterCard.self, keyword: CardIO.cardKeyword, from: data) {
                if mode == .studio { studio?.addCharacter(card) } else { maker?.load(card: card) }
            } else {
                try maker?.importSourceCardSettings(url: url)
                mode = .maker
            }
        } catch { errorMessage = "Could not open card: \(error)" }
    }

    func saveCard() {
        guard let maker else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(maker.card.profile.name).png"
        panel.message = "Save character card (PNG with embedded data)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try maker.saveCard(to: url) } catch { errorMessage = "Could not save card: \(error)" }
    }

    func openScene(importing: Bool) {
        guard let studio else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.message = importing ? "Import an Ikkoku scene (PNG) into the current scene" : "Open an Ikkoku scene (PNG)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { if importing { try studio.importScene(from: url) } else { try studio.loadScene(from: url) }; mode = .studio }
        catch { errorMessage = "Could not open scene: \(error)" }
    }

    func saveScene() {
        guard let studio else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(studio.doc.name).png"
        panel.message = "Save scene (PNG with embedded data)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try studio.saveScene(to: url) } catch { errorMessage = "Could not save scene: \(error)" }
    }

    func captureScreenshot() {
        guard let host else { return }
        let frame = mode == .studio ? (studio?.frame ?? host.renderer.currentFrame()) : host.renderer.currentFrame()
        let size = mode == .studio ? (studio?.captureSize ?? (1920, 1080)) : (1600, 1600)
        guard let image = host.renderer.capture(frame: frame, width: size.0, height: size.1) else {
            errorMessage = "Could not capture a screenshot: the renderer returned no image."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "ikkoku_capture.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try CaptureOutput.writePNG(image, to: url) }
        catch { errorMessage = "Could not save screenshot: \(error)" }
    }

    func resetCamera() {
        if mode == .studio { studio?.resetCamera() } else { maker?.resetCamera() }
    }

    // MARK: Converted library (A-T02)

    /// Choose the folder holding the converted Maker library and original bases, in
    /// the layout the exporters write under `.local/reverse/`. The selection records
    /// each manifest's identity and is read before the source-tree defaults; explicit
    /// variables still win. Scenes opened afterwards relocate their references into it.
    func chooseConvertedLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the converted library folder: the one holding maker-library/, rigs/ or male/, as written under .local/reverse/."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let location = try EngineHost.selectConvertedLibrary(root: url)
            let kinds = location.libraries.map(\.kind.rawValue).joined(separator: ", ")
            // A-T02: a layout copied without the companion files beside its bases
            // (studio-pose/, animation-assets/) is selected, but says what it lacks
            // instead of reporting success.
            let problems = location.companionProblems()
            for problem in problems { print("[ikkoku] converted library: \(problem)") }
            let message = problems.isEmpty
                ? "Converted library \(url.path) (\(kinds)). Scenes opened from now on relocate into it."
                : "Converted library \(url.path) (\(kinds)) selected incomplete: \(problems.count) companion file\(problems.count == 1 ? "" : "s") missing or changed."
            studio?.status = message
            maker?.status = message
            if !problems.isEmpty {
                errorMessage = (["The converted library \(url.path) was selected, but it is incomplete:"]
                    + problems.map { "• \($0)" }
                    + ["Copy the missing folders from .local/reverse/ next to rigs/ and choose the library again."]).joined(separator: "\n")
            }
        } catch { errorMessage = "Could not choose the converted library: \(error)" }
    }

    func forgetConvertedLibrary() {
        EngineHost.forgetConvertedLibrary()
        let message = "Converted library selection removed; the default lookups apply."
        studio?.status = message
        maker?.status = message
    }
}
