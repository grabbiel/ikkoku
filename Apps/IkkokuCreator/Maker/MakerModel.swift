import SwiftUI
import AppKit
import simd
import CoreMath
import Scene
import Renderer
import Character
import ShaderTypes
import Assets
import ImageIO
import UniformTypeIdentifiers

enum MakerTab: String, CaseIterable, Identifiable {
    case face = "Face", body = "Body", hair = "Hair", clothes = "Clothes", accessories = "Accessories", profile = "Profile"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .face: return "face.smiling"; case .body: return "figure.stand"; case .hair: return "comb"
        case .clothes: return "tshirt"; case .accessories: return "sparkles"; case .profile: return "person.text.rectangle"
        }
    }
}

enum CameraPreset: String, CaseIterable, Identifiable {
    case full = "Full", upper = "Upper", face = "Face"
    var id: String { rawValue }
}

/// Character Maker state: one character, an orbit camera, and the card being edited.
@MainActor @Observable
final class MakerModel: ViewportInputHandler {
    let host: EngineHost
    @ObservationIgnored let character: CharacterInstance
    var card: CharacterCard { didSet { character.card = card; refresh() } }
    var camera = OrbitCamera() { didSet { refresh() } }
    var effects = SceneEffects() { didSet { refresh() } }
    var mainLight = MainLight() { didSet { refresh() } }
    var tab: MakerTab = .face
    var showBones = false { didSet { refresh() } }
    var showGrid = true { didSet { effects.showGrid = showGrid } }
    var selectedAccessory = 0
    var viewportSize = SIMD2<Float>(1600, 1200)
    var lastLoadedURL: URL?
    var status = ""
    var sourceRigPreview: SourceRigPreview?
    @ObservationIgnored private(set) var sourceRigURL: URL?
    @ObservationIgnored private var sourceMakerLibrary: SourceMakerLibrary?
    @ObservationIgnored private var sourcePreparedAssets: SourceMakerLibrary.Prepared?
    var sourceAssetSelections: [SourceMakerLibrary.Selection] = []
    @ObservationIgnored private var sourceModLibrary: SourceModLibrary?
    @ObservationIgnored private var sourceModCatalog: SourceModCatalog?
    @ObservationIgnored private var sourceModCatalogContract: SourceModCatalogContract?
    var sourceBodyValues: [Float] = [] { didSet { invalidateSourceSimulation(); refresh() } }
    var sourceFaceValues: [Float] = [] { didSet { invalidateSourceSimulation(); refresh() } }
    var sourceExpressionInputs: SourceExpressionInputs? { didSet { refresh() } }
    var sourceAutomaticBlink = true { didSet { refresh() } }
    @ObservationIgnored private var sourceBlink = SourceBlinkPlayback()
    @ObservationIgnored private var sourceBlinkStart = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var sourceAnimationLibrary: SourceAnimationLibrary?
    @ObservationIgnored private var sourceIdleClipID: String?
    @ObservationIgnored private var sourceIdleStateID: String?
    @ObservationIgnored private var sourceDynamicsDocument: SourceDynamicsDocument?
    @ObservationIgnored private var sourceDynamicsStates: [SourceDynamicBone] = []
    @ObservationIgnored private var sourceSimulationPose: RigPose?
    @ObservationIgnored private var sourceAnimationTime: Float = 0
    @ObservationIgnored private var sourceLastTick = ProcessInfo.processInfo.systemUptime
    var hasSourceIdle = false
    var hasSourceHairDynamics = false
    var sourceIdleAnimation = true { didSet { sourceAnimationTime = 0; invalidateSourceSimulation(); refresh() } }
    var sourceHairDynamics = true { didSet { invalidateSourceSimulation(); refresh() } }
    var sourceBoneModifiers: SourceBoneModifiers? { didSet { invalidateSourceSimulation() } }
    private(set) var importedSourceCard: SourceCharacterCard?
    @ObservationIgnored private var importedSourceCardURL: URL?
    private struct ColorEditKey: Hashable {
        let record: SourceCharacterCard.Record, path: [SourceCharacterCard.Field]
    }
    @ObservationIgnored private var sourceColorEdits: [ColorEditKey: SourceCharacterCard.ColorEdit] = [:]
    @ObservationIgnored private var updatingSource = false
    var sourceAppearanceDraft: SourceCardAppearance?
    @ObservationIgnored private var sourceAppliedColors: [String: Float4] = [:]
    var sourceAppearanceAppliedFields: Set<String> = []
    var sourceAppearanceDiagnostics: [String] = []
    var sourceCoordinateCount = 1
    var sourceSex = 1
    var sourceHeadID = 0
    var sourceBoneType = 0
    var sourceCardDiagnostics: [String] = []
    var sourceCardModReport: SourceCardModReferences.Report?
    var sourceCardModDiagnostics: [String] = []
    var applySourceBoneModifiers = true { didSet { invalidateSourceSimulation(); refresh() } }
    var sourceBoneModifierCoordinate = 0 { didSet { invalidateSourceSimulation(); refresh() } }
    var applySourceCustomization = false { didSet { invalidateSourceSimulation(); refresh() } }
    var liveAnimation = true { didSet { refresh() } }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startTime = CFAbsoluteTimeGetCurrent()

    init(host: EngineHost) {
        self.host = host
        let card = CharacterCard.defaultFemale()
        self.card = card
        self.character = CharacterInstance(instanceID: 1, library: host.library, card: card)
        self.effects.showGrid = true
        status = host.library.catalog.bodies.isEmpty ? "No catalog found at \(host.assetsRoot.path)" : "Bundled female character"
        resetCamera()
        refresh()
        loadDefaultSourceAvatar()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Idle animation tick (blink + breathing). Cheap: only rebuilds the frame when something moves.
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = Float(now - sourceLastTick); sourceLastTick = now
        guard liveAnimation, isActiveMode else { return }
        if let preview = sourceRigPreview {
            do {
                let previous = sourceBlink.expressionBlinkRate
                if preview.supportsExpressions && sourceAutomaticBlink {
                    try sourceBlink.update(time: Float(now - sourceBlinkStart))
                }
                let moving = (sourceIdleAnimation && hasSourceIdle) || (sourceHairDynamics && hasSourceHairDynamics)
                if moving { try advanceSourceMotion(deltaTime: delta) }
                if moving || sourceBlink.expressionBlinkRate != previous { refresh() }
            } catch { status = "Source playback: \(error)" }
            return
        }
        let t = CFAbsoluteTimeGetCurrent() - startTime
        let blink = card.expression.blink ? LiveAnimation.blinkWeight(time: t, seed: 1) : 0
        character.extraMorphs = ["exp.blink_L": blink, "exp.blink_R": blink]
        character.poseDelta = LiveAnimation.breathing(time: t, seed: 1)
        character.stepHairDynamics(dt: 1.0 / 30.0)
        refresh()
    }
    /// Set by the app when the maker is the visible mode, so the timer is idle otherwise.
    var isActiveMode = true

    var library: AssetLibrary { host.library }

    private var effectiveSourceExpressionInputs: SourceExpressionInputs? {
        guard var inputs = sourceExpressionInputs else { return nil }
        if sourceAutomaticBlink { inputs.blinkRate = sourceBlink.expressionBlinkRate }
        return inputs
    }

    private func invalidateSourceSimulation() {
        sourceSimulationPose = nil; sourceDynamicsStates = []
    }

    private func sourceUpstreamPose(preview: SourceRigPreview, at time: Float) throws -> RigPose {
        let animated: RigPose?
        if sourceIdleAnimation, let animation = sourceAnimationLibrary, let clipID = sourceIdleClipID {
            animated = try animation.applying(clipID: clipID, time: time, looping: true, to: preview.source.rig)
        } else { animated = nil }
        return try preview.pose(
            bodyValues: applySourceCustomization && preview.supportsBodyCustomization ? sourceBodyValues : nil,
            faceValues: applySourceCustomization && preview.supportsFaceCustomization ? sourceFaceValues : nil,
            boneModifiers: applySourceBoneModifiers ? sourceBoneModifiers : nil,
            coordinate: sourceBoneModifierCoordinate, basePose: animated)
    }

    /// Also used by deterministic offscreen capture; each call is one native frame.
    func advanceSourceMotion(deltaTime: Float) throws {
        guard let preview = sourceRigPreview else { return }
        guard deltaTime.isFinite, deltaTime >= 0 else { throw RigError.invalid("Invalid source playback duration.") }
        let speed = try sourceIdleStateID.flatMap { id in try sourceAnimationLibrary?.stateSpeed(stateID: id) } ?? 1
        let nextTime = sourceAnimationTime + (sourceIdleAnimation ? deltaTime * speed : 0)
        guard nextTime.isFinite else { throw RigError.invalid("Source playback clock overflow.") }
        var pose = try sourceUpstreamPose(preview: preview, at: nextTime)
        var states = sourceDynamicsStates
        if sourceHairDynamics, let document = sourceDynamicsDocument {
            if states.isEmpty { states = try document.components.map { try SourceDynamicBone(rig: preview.source.rig, pose: pose, definition: $0) } }
            for i in states.indices { pose = try states[i].step(deltaTime: deltaTime, rig: preview.source.rig, pose: pose) }
        }
        _ = try preview.source.rig.evaluate(pose)
        sourceAnimationTime = nextTime; sourceDynamicsStates = states; sourceSimulationPose = pose
    }

    // MARK: Frame

    func refresh() {
        guard !updatingSource else { return }
        if let preview = sourceRigPreview {
            do {
                let frame = try preview.frame(camera: camera, mainLight: mainLight, effects: effects,
                    expression: effectiveSourceExpressionInputs,
                    showBones: showBones,
                    poseOverride: sourceSimulationPose ?? sourceUpstreamPose(preview: preview, at: sourceAnimationTime))
                host.renderer.submit(frame)
            } catch { status = "Rig preview: \(error)" }
            return
        }
        switch card.expression.gazeMode {
        case 1: character.gazeTarget = camera.position
        case 2: character.gazeTarget = camera.position + Float3(0.9, 0.35, 0)
        case 3: character.gazeTarget = card.expression.gazeTarget
        default: character.gazeTarget = nil
        }
        let r = character.build(objectID: 1)
        var frame = RenderFrame(camera: camera, mainLight: mainLight, lights: [], items: r.items,
                                gizmos: showBones ? boneGizmos(r) : [], effects: effects, sceneBounds: r.bounds)
        frame.skinSets = [character.instanceID: r.skinSet]
        host.renderer.submit(frame)
    }

    private func boneGizmos(_ r: CharacterInstance.BuildResult) -> [GizmoBatch] {
        guard let skel = character.skeleton else { return [] }
        let root = character.rootMatrix
        var verts: [GizmoVertex] = []
        for (i, b) in skel.bones.enumerated() where i < r.worldMatrices.count {
            let p = (root * r.worldMatrices[i]).translation
            let color = SIMD4<Float>(0.2, 0.9, 1.0, 1)
            if let pi = b.parent {
                let pp = (root * r.worldMatrices[pi]).translation
                verts.append(GizmoVertex(position: pp, color: color))
                verts.append(GizmoVertex(position: p, color: color))
            }
        }
        return [GizmoBatch(primitive: .lines, vertices: verts, depthTest: false)]
    }

    // MARK: Commands

    func newCharacter(sex: Sex) {
        importedSourceCard = nil; importedSourceCardURL = nil
        sourceRigPreview = nil
        card = sex == .female ? .defaultFemale() : .defaultMale()
        status = sex == .female ? "Bundled female character" : "Bundled male character"
        resetCamera()
        loadDefaultSourceAvatar(sex: sex)
    }

    private func loadDefaultSourceAvatar(sex: Sex = .female) {
        do {
            guard let url = try EngineHost.locateSourceAvatar(sex: sex) else { return }
            try openSourceRig(url: url)
        } catch {
            status = "Could not load original base: \(error). Loaded bundled character."
            print("[ikkoku] \(status)")
        }
    }

    func load(card: CharacterCard) { importedSourceCard = nil; importedSourceCardURL = nil; sourceRigPreview = nil; self.card = card }

    func openSourceRig(url: URL) throws { try openSourceRig(url: url, importing: nil, cardURL: nil) }

    private func openSourceRig(url: URL, importing imported: SourceCharacterCard?, cardURL: URL?) throws {
        let manifest = try? JSONDecoder().decode(SourceAvatarManifest.self, from: Data(contentsOf: url))
        let sex = manifest?.sex ?? (manifest?.kind == "koikatsu-male-avatar" ? 0 : 1)
        let identity = try imported?.customization()
        let head = manifest?.headID ?? 0, boneType = identity?.boneType ?? manifest?.boneType ?? 0
        let correctionData: Data?
        if boneType != 0 {
            let folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
            let correction = folder.appendingPathComponent(manifest?.bodyCorrection ?? "shapecorrect.bytes").resolvingSymlinksInPath()
            guard correction.path.hasPrefix(folder.path + "/") else { throw RigError.invalid("Body correction path escapes the assembly folder.") }
            correctionData = try Data(contentsOf: correction)
        } else { correctionData = nil }
        let options = try SourceMakerAssemblyOptions.body(sex: sex, exType: identity?.exType ?? 0, boneType: boneType, correctionData: correctionData)
        var source = try SourceRig.loadModel(url: url)
        let makerLibrary = try EngineHost.locateMakerLibrary()
        var prepared: SourceMakerLibrary.Prepared?, selectionDiagnostics: [String] = []
        if let imported, let makerLibrary {
            do {
                prepared = try makerLibrary.prepare(card: imported, coordinate: 0, baseURL: url)
                source = prepared!.source
            } catch { selectionDiagnostics.append("Card asset selection retained the reference assembly: \(error)") }
        }
        let contractURL = url.deletingLastPathComponent().appendingPathComponent("character-shape-contract.json")
        let contract = FileManager.default.fileExists(atPath: contractURL.path)
            ? try SourceShapeContract.decode(Data(contentsOf: contractURL)) : nil
        let appearanceURL = url.deletingPathExtension().appendingPathExtension("appearance.json")
        var appearance = FileManager.default.fileExists(atPath: appearanceURL.path)
            ? try SourcePreviewAppearance.load(url: appearanceURL, resources: host.renderer.resources, modLibrary: sourceModLibrary) : nil
        let expressionURL = url.deletingLastPathComponent().appendingPathComponent("source-expression-contract.json")
        let expressions = FileManager.default.fileExists(atPath: expressionURL.path)
            ? try SourceExpressionContract.decode(Data(contentsOf: expressionURL)) : nil
        let settings = try imported.map { card in
            guard let contract else { throw RigError.invalid("This source model has no shape contract.") }
            return try card.previewSettings(contract: contract, sex: sex, headID: head, boneType: boneType)
        }
        var draft: SourceCardAppearance?, application: SourcePreviewAppearance.CardApplication?
        var appearanceDiagnostics = selectionDiagnostics
        if let imported {
            do {
                draft = try SourceCardAppearance(card: imported)
                if let base = appearance, let draft {
                    application = try applyCardAppearance(draft, base: base, url: url, prepared: prepared, modLibrary: sourceModLibrary)
                    appearance = application?.appearance ?? base
                }
            } catch { appearanceDiagnostics.append("Appearance retained as reference: \(error)") }
        }
        let preview = try SourceRigPreview(source: source, contract: contract, resources: host.renderer.resources,
            appearance: appearance, expressionContract: expressions, bodyOptions: options)
        if imported != nil {
            guard preview.supportsFaceCustomization, preview.bodyCoverage?.completeSlots.count == 44 else {
                throw RigError.invalid("Card import requires an assembled avatar with complete face and body bindings.")
            }
        }
        var bodyValues = settings?.bodyValues ?? contract?.domain("body")?.defaultValues ?? []
        if sex == 0, !bodyValues.isEmpty { bodyValues[0] = 0.6 }
        let faceValues = settings?.faceValues ?? contract?.domain("face")?.defaultValues ?? []
        _ = try preview.bounds(bodyValues: preview.supportsBodyCustomization ? bodyValues : nil,
            faceValues: preview.supportsFaceCustomization ? faceValues : nil, boneModifiers: settings?.boneModifiers)

        let env = ProcessInfo.processInfo.environment
        let defaultAnimation = url.deletingLastPathComponent().appendingPathComponent("../animation-assets/female-base/animation.json").standardizedFileURL
        let animationURL = env["IKKOKU_SOURCE_ANIMATION"].map { URL(fileURLWithPath: $0) }
            ?? (url.lastPathComponent == "source-avatar.json" ? defaultAnimation : nil)
        let animation = try animationURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? try SourceAnimationLibrary.load(url: $0) : nil }
        let idle = animation?.states.first { $0.name == "Idle" && $0.motions.count == 1 }
        if let animation, let idle {
            _ = try animation.applying(clipID: idle.motions[0].clipID, time: 0, looping: true, to: source.rig)
        }
        let dynamicsURL = url.deletingLastPathComponent().appendingPathComponent("source-dynamics.json")
        let dynamics = prepared?.geometryChanged != true && url.lastPathComponent == "source-avatar.json" && FileManager.default.fileExists(atPath: dynamicsURL.path)
            ? try SourceDynamicsDocument.load(url: dynamicsURL) : nil
        if let dynamics { _ = try dynamics.components.map { try SourceDynamicBone(rig: source.rig, definition: $0) } }
        updatingSource = true
        defer { updatingSource = false; frameSourceRig(); refresh() }
        applySourceCustomization = false
        sourceBoneModifiers = nil
        importedSourceCard = imported
        sourceMakerLibrary = makerLibrary; sourcePreparedAssets = prepared
        sourceAssetSelections = prepared?.selections ?? []
        importedSourceCardURL = cardURL
        sourceColorEdits = [:]
        sourceAppearanceDraft = draft
        sourceAppliedColors = Dictionary(uniqueKeysWithValues: (draft?.colors ?? []).map { ($0.id, $0.rgba) })
        sourceAppearanceAppliedFields = application?.appliedFields ?? []
        sourceAppearanceDiagnostics = appearanceDiagnostics + (application?.diagnostics ?? [])
        sourceCoordinateCount = imported.map { card in (0..<7).prefix { (try? card.recordData(.clothes(coordinate: $0))) != nil }.count } ?? 1
        sourceBoneModifierCoordinate = 0
        sourceSex = sex; sourceHeadID = head; sourceBoneType = boneType
        sourceCardDiagnostics = settings?.diagnostics ?? []
        if sex == 0 { sourceCardDiagnostics.append("Normal male Maker height is fixed at 0.6 by the original game.") }
        sourceCardModReport = nil
        sourceCardModDiagnostics = []
        sourceExpressionInputs = nil
        sourceBlink = SourceBlinkPlayback()
        sourceBlinkStart = ProcessInfo.processInfo.systemUptime
        sourceAnimationLibrary = animation; sourceIdleClipID = idle?.motions.first?.clipID; sourceIdleStateID = idle?.id
        sourceDynamicsDocument = dynamics
        hasSourceIdle = idle != nil; hasSourceHairDynamics = dynamics?.components.isEmpty == false
        sourceAnimationTime = 0; sourceLastTick = ProcessInfo.processInfo.systemUptime; invalidateSourceSimulation()
        sourceRigPreview = preview
        sourceRigURL = url
        sourceBodyValues = bodyValues
        sourceFaceValues = faceValues
        sourceBoneModifiers = settings?.boneModifiers
        applySourceBoneModifiers = true
        refreshSourceCardModReport()
        sourceExpressionInputs = preview.supportsExpressions ? expressions?.defaults : nil
        applySourceCustomization = preview.supportsBodyCustomization || preview.supportsFaceCustomization
        status = "\(source.rig.nodes.count) nodes · \(source.rig.skins.count) skin bindings · \(preview.hasSourceAppearance ? "texture preview" : "neutral material")"
        frameSourceRig()
    }

    func closeSourceRig() { importedSourceCard = nil; importedSourceCardURL = nil; sourceRigPreview = nil; resetCamera(); refresh(); status = "Character Maker" }

    func setModLibrary(_ library: SourceModLibrary?, catalog: SourceModCatalog? = nil,
                       contract: SourceModCatalogContract? = nil) throws {
        let replacement: SourceRigPreview?
        var cardApplication: SourcePreviewAppearance.CardApplication?
        if let current = sourceRigPreview, let url = sourceRigURL {
            let appearanceURL = url.deletingPathExtension().appendingPathExtension("appearance.json")
            var appearance = FileManager.default.fileExists(atPath: appearanceURL.path)
                ? try SourcePreviewAppearance.load(url: appearanceURL, resources: host.renderer.resources, modLibrary: library) : nil
            if let base = appearance, let draft = sourceAppearanceDraft {
                cardApplication = try applyCardAppearance(draft, base: base, url: url, prepared: sourcePreparedAssets, modLibrary: library)
                appearance = cardApplication?.appearance ?? base
            }
            let preview = try SourceRigPreview(source: current.source, contract: current.contract,
                resources: host.renderer.resources, appearance: appearance, expressionContract: current.expressionContract, bodyOptions: current.bodyOptions)
            let candidate = try preview.frame(camera: camera, mainLight: mainLight, effects: effects,
                bodyValues: applySourceCustomization && preview.supportsBodyCustomization ? sourceBodyValues : nil,
                faceValues: applySourceCustomization && preview.supportsFaceCustomization ? sourceFaceValues : nil,
                expression: effectiveSourceExpressionInputs,
                boneModifiers: applySourceBoneModifiers ? sourceBoneModifiers : nil,
                coordinate: sourceBoneModifierCoordinate, showBones: showBones)
            guard !candidate.sceneBounds.isEmpty, candidate.sceneBounds.radius.isFinite else {
                throw RigError.invalid("The mod library produces invalid rendered bounds.")
            }
            replacement = preview
        } else { replacement = nil }
        if let replacement {
            sourceRigPreview = replacement
            if let cardApplication {
                sourceAppearanceAppliedFields = cardApplication.appliedFields
                sourceAppearanceDiagnostics = cardApplication.diagnostics
                sourceAppliedColors = Dictionary(uniqueKeysWithValues: (sourceAppearanceDraft?.colors ?? []).map { ($0.id, $0.rgba) })
            }
        }
        sourceModLibrary = library
        sourceModCatalog = catalog
        sourceModCatalogContract = contract
        refreshSourceCardModReport()
        refresh()
    }

    /// Availability is independent from applying the card's shape settings.
    /// Malformed resolver data is retained in the card and reported separately.
    private func refreshSourceCardModReport() {
        sourceCardModReport = nil
        sourceCardModDiagnostics = []
        guard let card = importedSourceCard else { return }
        do {
            let report = try card.modReferenceReport(library: sourceModLibrary,
                catalog: sourceModCatalog, contract: sourceModCatalogContract)
            sourceCardModReport = report
            sourceCardModDiagnostics = report.diagnostics
            if report.pluginID != nil {
                if sourceModLibrary == nil {
                    sourceCardModDiagnostics.append("Load a mod library to check the card's saved mod references.")
                } else if sourceModCatalog == nil || sourceModCatalogContract == nil {
                    sourceCardModDiagnostics.append("The loaded mod library has no source catalog contract. Saved mod references are shown as metadata only.")
                }
            }
        } catch {
            sourceCardModDiagnostics = ["Could not read the card's mod references: \(error). Original card bytes remain preserved; supported shape settings are still imported."]
        }
    }

    func loadBoneModifiers(url: URL) throws {
        guard let preview = sourceRigPreview else { throw RigError.invalid("Open an original source model before loading bone modifiers.") }
        let modifiers = try SourceBoneModifiers.decode(Data(contentsOf: url))
        let coordinate = sourceAppearanceDraft?.coordinate ?? 0
        _ = try preview.evaluation(
            bodyValues: applySourceCustomization && preview.supportsBodyCustomization ? sourceBodyValues : nil,
            faceValues: applySourceCustomization && preview.supportsFaceCustomization ? sourceFaceValues : nil,
            boneModifiers: modifiers, coordinate: coordinate)
        sourceBoneModifiers = modifiers
        sourceBoneModifierCoordinate = coordinate
        applySourceBoneModifiers = true
        status = "Loaded \(modifiers.count) ABMX bone modifiers"
        refresh()
    }

    func clearBoneModifiers() { sourceBoneModifiers = nil; refresh(); status = "Bone modifiers cleared" }

    func importSourceCardSettings(url: URL) throws {
        let imported = try SourceCharacterCard.load(url: url)
        try SourceMakerLibrary.validateAssemblyIdentity(card: imported)
        let identity = try imported.customization()
        let urlForRig: URL
        if sourceRigPreview != nil, sourceSex == identity.sex, sourceHeadID == identity.headID,
           let current = sourceRigURL { urlForRig = current }
        else if let library = try EngineHost.locateMakerLibrary(), let variant = try library.assemblyURL(for: identity) {
            urlForRig = variant
        } else {
            guard let selected = try EngineHost.locateSourceAvatar(sex: identity.sex == 0 ? .male : .female) else {
                throw RigError.invalid("The original avatar for this card is not available locally.")
            }
            urlForRig = selected
        }
        // Asset loading, identity checks, material recipes and pose evaluation all
        // happen before replacing the current Maker state.
        try openSourceRig(url: urlForRig, importing: imported, cardURL: url)
        status = "Imported card · \(sourceAppearanceAppliedFields.count) appearance fields · \(sourceBoneModifiers?.count ?? 0) bone modifiers"
    }

    private func applyCardAppearance(_ draft: SourceCardAppearance, base: SourcePreviewAppearance, url: URL,
                                     prepared: SourceMakerLibrary.Prepared? = nil, modLibrary: SourceModLibrary?) throws -> SourcePreviewAppearance.CardApplication? {
        let bindingsURL = url.deletingPathExtension().appendingPathExtension("card-appearance.json")
        var current = base, fields = Set<String>(), diagnostics: [String] = []
        if FileManager.default.fileExists(atPath: bindingsURL.path) {
            var bindings = try SourceAppearanceBindings.load(url: bindingsURL)
            if let prepared { bindings = bindings.restricted(to: Set(prepared.source.parts.map { $0.mesh.name })) }
            let applied = try current.applying(draft, bindings: bindings, directory: url.deletingLastPathComponent(), resources: host.renderer.resources)
            current = applied.appearance; fields.formUnion(applied.appliedFields); diagnostics += applied.diagnostics
        }
        if let prepared, let applied = try prepared.appearance(base: current, card: draft, resources: host.renderer.resources, modLibrary: modLibrary) {
            current = applied.appearance; fields.formUnion(applied.appliedFields); diagnostics += applied.diagnostics
        }
        return .init(appearance: current, appliedFields: fields, diagnostics: diagnostics)
    }

    private func colorEditKey(_ color: SourceCardAppearance.Color) -> ColorEditKey {
        ColorEditKey(record: color.record, path: color.path)
    }

    func setSourceColor(_ id: String, rgba: Float4) {
        do { try sourceAppearanceDraft?.setColor(id, rgba: rgba) }
        catch { status = "Color edit: \(error)" }
    }

    func applySourceAppearance() throws {
        guard let draft = sourceAppearanceDraft, let importedSourceCard else { return }
        if draft.colors.contains(where: { sourceAppliedColors[$0.id] != $0.rgba }) {
            try replaceSourceAppearance(draft)
        }
        let original = try SourceCardAppearance(card: importedSourceCard, coordinate: draft.coordinate)
        for color in draft.colors where sourceAppearanceAppliedFields.contains(color.id) {
            let key = colorEditKey(color)
            sourceColorEdits[key] = original.color(color.id) == color.rgba ? nil : color.edit
        }
        status = "Applied \(sourceAppearanceAppliedFields.count) supported appearance fields"
    }

    func selectSourceCoordinate(_ coordinate: Int) throws {
        guard let importedSourceCard, (0..<sourceCoordinateCount).contains(coordinate) else {
            throw RigError.invalid("This card does not contain the selected supported outfit.")
        }
        guard coordinate != sourceBoneModifierCoordinate else { return }
        // Commit pending supported color edits before changing outfits.
        try applySourceAppearance()
        var draft = try SourceCardAppearance(card: importedSourceCard, coordinate: coordinate)
        for color in draft.colors {
            if let edit = sourceColorEdits[colorEditKey(color)] {
                try draft.setColor(color.id, rgba: Float4(edit.rgba))
            }
        }
        try replaceSourceAppearance(draft)
        sourceAppearanceDraft = draft
        sourceBoneModifierCoordinate = coordinate
    }

    private func replaceSourceAppearance(_ draft: SourceCardAppearance) throws {
        guard let current = sourceRigPreview, let url = sourceRigURL else { return }
        let base = try SourcePreviewAppearance.load(url: url.deletingPathExtension().appendingPathExtension("appearance.json"),
            resources: host.renderer.resources, modLibrary: sourceModLibrary)
        let prepared: SourceMakerLibrary.Prepared?
        if let sourceMakerLibrary, let importedSourceCard, draft.coordinate != sourceAppearanceDraft?.coordinate {
            prepared = try sourceMakerLibrary.prepare(card: importedSourceCard, coordinate: draft.coordinate, baseURL: url)
        } else { prepared = sourcePreparedAssets }
        let application = try applyCardAppearance(draft, base: base, url: url, prepared: prepared, modLibrary: sourceModLibrary)
        let preview = try SourceRigPreview(source: prepared?.source ?? current.source, contract: current.contract, resources: host.renderer.resources,
            appearance: application?.appearance ?? base, expressionContract: current.expressionContract, bodyOptions: current.bodyOptions)
        _ = try preview.bounds(bodyValues: applySourceCustomization ? sourceBodyValues : nil,
            faceValues: applySourceCustomization ? sourceFaceValues : nil,
            boneModifiers: applySourceBoneModifiers ? sourceBoneModifiers : nil, coordinate: draft.coordinate)
        sourceRigPreview = preview
        sourcePreparedAssets = prepared; sourceAssetSelections = prepared?.selections ?? []
        invalidateSourceSimulation()
        sourceAppliedColors = Dictionary(uniqueKeysWithValues: draft.colors.map { ($0.id, $0.rgba) })
        sourceAppearanceAppliedFields = application?.appliedFields ?? []
        sourceAppearanceDiagnostics = application?.diagnostics ?? ["This assembly has no card appearance bindings."]
        refresh()
    }

    func exportSourceCard(to url: URL) throws {
        guard let importedSourceCard, let preview = sourceRigPreview, applySourceCustomization else {
            throw RigError.invalid("Import an original card and enable customization before exporting an edited copy.")
        }
        guard url.resolvingSymlinksInPath() != importedSourceCardURL?.resolvingSymlinksInPath() else {
            throw RigError.invalid("Choose a new filename to preserve the imported source card.")
        }
        let originalModifiers = try importedSourceCard.boneModifiers()
        guard sourceBoneModifiers?.source.payloadSHA256 == originalModifiers?.source.payloadSHA256,
              originalModifiers == nil || applySourceBoneModifiers else {
            throw RigError.invalid("Source-card export preserves the imported ABMX data. Restore the imported bone modifiers and enable them before exporting; native-only modifier edits cannot be saved yet.")
        }
        try applySourceAppearance()
        // Export a static current customization pose; animation does not become card data.
        func thumbnail(preset: CameraPreset, width: Int, height: Int) throws -> Data {
            let oldSize = viewportSize
            viewportSize = SIMD2<Float>(Float(width), Float(height))
            defer { viewportSize = oldSize }
            var frame = try (sourceRigPreview ?? preview).frame(camera: previewCamera(preset: preset), mainLight: mainLight,
                effects: effects, bodyValues: sourceBodyValues, faceValues: sourceFaceValues,
                expression: sourceExpressionInputs, boneModifiers: originalModifiers, coordinate: sourceBoneModifierCoordinate)
            frame.effects.showGrid = false
            guard let image = host.renderer.capture(frame: frame, width: width, height: height) else {
                throw RigError.invalid("Could not render the edited card thumbnail.")
            }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
                throw RigError.invalid("Could not encode the edited card thumbnail.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw RigError.invalid("Could not finish card thumbnail encoding.") }
            return png as Data
        }
        let png = try thumbnail(preset: .full, width: 504, height: 704)
        let facePNG = try thumbnail(preset: .face, width: 256, height: 256)
        let data = try importedSourceCard.editedData(.init(faceValues: sourceFaceValues, bodyValues: sourceBodyValues,
            colors: Array(sourceColorEdits.values), thumbnailData: png, faceThumbnailData: facePNG))
        try data.write(to: url, options: .atomic)
        status = "Exported edited copy: \(url.lastPathComponent). Other fields and plugin data preserved."
    }

    func resetSourceShapes() {
        guard let preview = sourceRigPreview else { return }
        sourceBodyValues = preview.contract?.domain("body")?.defaultValues ?? []
        if sourceSex == 0, !sourceBodyValues.isEmpty { sourceBodyValues[0] = 0.6 }
        sourceFaceValues = preview.contract?.domain("face")?.defaultValues ?? []
    }

    func frameSourceRig() {
        guard sourceRigPreview != nil else { return }
        do {
            camera = try previewCamera(preset: .full)
        } catch { status = "Could not frame source rig: \(error)" }
    }

    /// Frame the evaluated source geometry, including its current Maker values.
    /// Source +Z is forward; the native Z reflection puts the face toward -Z.
    func previewCamera(preset: CameraPreset) throws -> OrbitCamera {
        guard let preview = sourceRigPreview else { throw RigError.invalid("No source rig is open.") }
        let evaluation = try preview.evaluation(
            bodyValues: applySourceCustomization && preview.supportsBodyCustomization ? sourceBodyValues : nil,
            faceValues: applySourceCustomization && preview.supportsFaceCustomization ? sourceFaceValues : nil,
            boneModifiers: applySourceBoneModifiers ? sourceBoneModifiers : nil, coordinate: sourceBoneModifierCoordinate)
        let source = preview.source
        let weights = try preview.expressionWeights(effectiveSourceExpressionInputs)
        var fullBounds = try source.bounds(evaluation: evaluation, morphWeights: weights)
        if fullBounds.isEmpty {
            fullBounds = AABB.of(points: source.rig.order.filter { source.rig.activeNodes[$0] }
                .map { evaluation.worldMatrices[$0].translation })
        }
        guard !fullBounds.isEmpty, fullBounds.radius.isFinite else { throw RigError.invalid("Source rig has no finite framing bounds.") }
        var faceBounds = AABB.empty
        for part in source.parts where part.rendererEnabled && source.rig.activeNodes[part.node]
            && source.rig.skins[part.skin].name == "cf_O_face" {
            faceBounds.expand(AABB.of(points: try source.deformedPositions(part: part, evaluation: evaluation,
                morphWeights: weights[part.mesh.name] ?? [])))
        }
        if faceBounds.isEmpty { faceBounds = fullBounds }
        var bounds = fullBounds
        var cam = camera
        let padding: Float
        switch preset {
        case .full:
            cam.fovDegrees = 30
            padding = 1.12
        case .upper:
            // A waist-up portrait intentionally crops outstretched hands while
            // retaining shoulders and the head rather than refitting the T pose.
            let halfWidth = min(fullBounds.extent.x * 0.5,
                                max(faceBounds.extent.x * 1.4, fullBounds.extent.y * 0.24))
            bounds.min.x = faceBounds.center.x - halfWidth
            bounds.max.x = faceBounds.center.x + halfWidth
            bounds.min.y = max(fullBounds.min.y, faceBounds.min.y - fullBounds.extent.y * 0.36)
            cam.fovDegrees = 28
            padding = 1.14
        case .face:
            bounds = faceBounds
            cam.fovDegrees = 26
            padding = 1.25
        }
        cam.target = bounds.center
        cam.yaw = .pi
        cam.pitch = 0.03
        let aspect = max(viewportSize.x / max(viewportSize.y, 1), 0.1)
        let verticalTangent = tan(cam.fovDegrees.degreesToRadians * 0.5)
        let horizontalTangent = verticalTangent * aspect
        let back = Float3(sin(cam.yaw) * cos(cam.pitch), sin(cam.pitch), cos(cam.yaw) * cos(cam.pitch))
        let right = normalize(cross(Float3(0, 1, 0), back))
        let up = cross(back, right)
        var fitDistance: Float = 0.15
        for index in 0..<8 {
            let corner = Float3(index & 1 == 0 ? bounds.min.x : bounds.max.x,
                                index & 2 == 0 ? bounds.min.y : bounds.max.y,
                                index & 4 == 0 ? bounds.min.z : bounds.max.z) - cam.target
            let depth = dot(corner, back)
            let horizontalFit = depth + abs(dot(corner, right)) / horizontalTangent
            let verticalFit = depth + abs(dot(corner, up)) / verticalTangent
            fitDistance = max(fitDistance, max(horizontalFit, max(verticalFit, depth + cam.near * 2)))
        }
        cam.distance = fitDistance * padding
        return cam
    }

    func saveCard(to url: URL) throws {
        guard sourceRigPreview == nil else { throw RigError.invalid("Source rig previews are not yet native character cards.") }
        var frame = host.renderer.currentFrame()
        frame.effects.showGrid = false
        // Card thumbnails frame the face and upper body, like Koikatsu cards.
        var cam = camera
        cam.fovDegrees = 26
        cam.target = Float3(0, character.eyeHeight - 0.27, 0)
        cam.distance = character.height * 0.86
        cam.pitch = 0.04
        frame.camera = cam
        let thumb = host.renderer.capture(frame: frame, width: 504, height: 704)
        let data = try CardIO.encode(card, keyword: CardIO.cardKeyword, thumbnail: thumb)
        try data.write(to: url)
        lastLoadedURL = url
        status = "Saved \(url.lastPathComponent)"
    }

    func apply(preset: SliderPreset) {
        var c = card
        if preset.tab == .face { c.face.sliders = preset.values } else { c.body.sliders = preset.values }
        card = c
    }

    func resetSliders(tab: SliderTab) {
        if tab == .face { card.face.sliders = [:] } else { card.body.sliders = [:] }
    }

    func randomize() {
        guard sourceRigPreview == nil else { return }
        var c = card
        var rng = SystemRandomNumberGenerator()
        for def in SliderRegistry.shared.sliders {
            let v = Float.random(in: -55...55, using: &rng)
            if def.tab == .face { c.face.sliders[def.id] = v } else { c.body.sliders[def.id] = v }
        }
        let hairs = library.catalog.hair(for: c.sex)
        if let h = hairs.randomElement(using: &rng) { c.hair.parts[.back] = HairPart(styleID: h.id) }
        let palette: [RGB] = [RGB(hex: 0x3B2A2A), RGB(hex: 0x6A4A3F), RGB(hex: 0xC48A5A), RGB(hex: 0xE8C9A0), RGB(hex: 0x2E2E48),
                              RGB(hex: 0x7A3E5C), RGB(hex: 0xB5485A), RGB(hex: 0x4C7A9D), RGB(hex: 0x5D8C6E), RGB(hex: 0xF2E6D8)]
        let base = palette.randomElement(using: &rng)!
        c.hair.baseColor = base
        c.hair.shadeColor = base.scaled(0.6)
        c.hair.highlightColor = base.mixed(.white, 0.7)
        c.hair.outlineColor = base.scaled(0.35)
        let eyes: [RGB] = [RGB(hex: 0x4E8FD9), RGB(hex: 0x5C4A3C), RGB(hex: 0x3E9A6B), RGB(hex: 0xC85A7A), RGB(hex: 0x8D6BC7), RGB(hex: 0xD9A34E)]
        let e = eyes.randomElement(using: &rng)!
        c.face.irisColorLeft = e; c.face.irisColorRight = e
        for slot in [ClothSlot.top, .bottom, .socks, .shoesIn] {
            let opts = library.catalog.clothes(slot: slot.rawValue, sex: c.sex)
            if let o = opts.randomElement(using: &rng) {
                var item = c.outfit.items[slot] ?? ClothItem()
                item.itemID = o.id
                c.outfit.items[slot] = item
            }
        }
        card = c
    }

    // MARK: Camera

    func resetCamera() { apply(preset: .full) }

    func apply(preset: CameraPreset) {
        if sourceRigPreview != nil {
            do { camera = try previewCamera(preset: preset) }
            catch { status = "Could not frame source rig: \(error)" }
            return
        }
        var cam = camera
        let h = character.height, eye = character.eyeHeight
        switch preset {
        case .full: cam.target = Float3(0, h * 0.53, 0); cam.distance = h * 1.85; cam.fovDegrees = 30
        case .upper: cam.target = Float3(0, eye - h * 0.17, 0); cam.distance = h * 0.95; cam.fovDegrees = 28
        case .face: cam.target = Float3(0, eye - 0.03, 0.03); cam.distance = h * 0.42; cam.fovDegrees = 24
        }
        cam.yaw = 0; cam.pitch = 0.03
        camera = cam
    }

    // MARK: ViewportInputHandler

    private var dragButton = -1
    func mouseDown(at p: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags) { dragButton = button }
    func mouseDragged(to p: SIMD2<Float>, delta: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags) {
        var cam = camera
        if button == 0 && !modifiers.contains(.shift) && !modifiers.contains(.option) {
            cam.orbit(dx: delta.x * 0.005, dy: delta.y * 0.005)
        } else {
            cam.pan(dx: delta.x, dy: delta.y)
        }
        camera = cam
    }
    func mouseUp(at p: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags) { dragButton = -1 }
    func mouseMoved(to p: SIMD2<Float>) {}
    func scrolled(delta: SIMD2<Float>, modifiers: NSEvent.ModifierFlags) {
        var cam = camera
        if modifiers.contains(.shift) { cam.pan(dx: -delta.x * 4, dy: delta.y * 4) } else { cam.dolly(delta.y * 0.5) }
        camera = cam
    }
    func magnified(by amount: Float) { var cam = camera; cam.dolly(amount * 10); camera = cam }
    func keyDown(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers {
        case "f": apply(preset: .face); return true
        case "b": apply(preset: .full); return true
        case "u": apply(preset: .upper); return true
        default: return false
        }
    }
}
