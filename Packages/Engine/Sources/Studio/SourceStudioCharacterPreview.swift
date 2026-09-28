import Foundation
import Assets
import CryptoKit
import simd
import CoreMath
import Scene
import Character
import Renderer

/// Native scene cards retain a verified reference to the original scene. This
/// preview resolves converted card selections with the same identity rules as Maker.
/// Missing conversions remain explicit diagnostics and never rewrite the card.
public struct SourceStudioCharacterReference: Codable, Sendable, Equatable {
    public let sceneFile: String, sceneSHA256: String, rigFile: String, boneCatalogFile: String
    public let objectKey: Int32
    public let makerLibraryFile: String?
    public let attachmentCatalogFile: String?
    public let animationCatalogFile: String?
    public let dynamicsFile: String?
    public let handPatternsFile: String?
    public let lookSettingsFile: String?
    public init(sceneFile: String, sceneSHA256: String, rigFile: String, boneCatalogFile: String, objectKey: Int32, makerLibraryFile: String? = nil, attachmentCatalogFile: String? = nil, animationCatalogFile: String? = nil, dynamicsFile: String? = nil, handPatternsFile: String? = nil, lookSettingsFile: String? = nil) {
        self.sceneFile = sceneFile; self.sceneSHA256 = sceneSHA256; self.rigFile = rigFile
        self.boneCatalogFile = boneCatalogFile; self.objectKey = objectKey; self.makerLibraryFile = makerLibraryFile
        self.attachmentCatalogFile = attachmentCatalogFile
        self.animationCatalogFile = animationCatalogFile; self.dynamicsFile = dynamicsFile
        self.handPatternsFile = handPatternsFile; self.lookSettingsFile = lookSettingsFile
    }
}

public final class SourceStudioCharacterPreview {
    public let reference: SourceStudioCharacterReference
    public let preview: SourceRigPreview
    public let pose: RigPose
    /// Import-time messages plus one-shot runtime notices (for example the FK
    /// neck conflict reported by editedPose); never grows per frame.
    public private(set) var diagnostics: [String]
    public let record: KoikatsuCharacterRecord
    public let selections: [SourceMakerLibrary.Selection]
    public let coordinate: Int
    public let expressionInputs: SourceExpressionInputs?
    /// Saved ChaFileStatus.eyesBlink. The Studio card loader applies this flag
    /// on load, so a card that does not blink keeps fixed blink flags.
    public let eyesBlink: Bool
    /// Studio-side lever over the blink clock (mirrors the Maker's automatic
    /// blinking toggle): when off, rendering keeps the saved expression inputs
    /// instead of the clock's current openness.
    public var automaticBlink = true
    public let controller: SourceStudioPose
    private let baseline: RigPose
    private let attachments: SourceStudioAttachments?
    public let ikGuides: [SourceStudioIK.Guide]
    private let animationCatalog: SourceStudioAnimationCatalog?
    private let animationDirectory: URL?
    private let handPatternLibrary: SourceStudioHandPatterns?
    private var animationCache: [String: SourceStudioAnimation] = [:]
    private var animationPlayback = SourceStudioAnimation.Playback()
    private var blink: SourceStudioBlink
    private let animationHeight: Float
    private let characterRoot: Int
    private let poseCatalog: [SourceStudioPose.Bone]
    private var ikSolver: SourceStudioIK?
    private var dynamics: SourceStudioDynamics?
    private var dynamicsStep: (elapsed: Float, delta: Float)?
    /// Resolved FIX/FORWARD neck look override: the prefab settings, the saved
    /// fixAngle quaternions and the pattern's lookType. Nil when the look
    /// settings are not configured or the pattern resolves to a kept pose.
    private let neckLook: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf], lookType: SourceStudioNeckLookType)?
    /// One-shot per lookType so a repeated FK neck edit does not repeat the notice.
    private var reportedNeckLookFK: Set<SourceStudioNeckLookType> = []
    public var dynamicsComponentCount: Int { dynamics?.bindings.count ?? 0 }
    fileprivate typealias EvaluatedPose = (state: SourceStudioAnimationState, elapsed: Float, fk: [Int: Float3], ik: [Int32: SourceStudioIKEdit], kinematics: SourceStudioKinematicState?, pose: RigPose, guides: [SourceStudioIK.Guide])
    private var evaluatedCache: EvaluatedPose?
    public struct DynamicsCheckpoint {
        fileprivate let owner: ObjectIdentifier
        fileprivate let simulation: SourceStudioDynamics?
        fileprivate let step: (elapsed: Float, delta: Float)?
        fileprivate let evaluated: EvaluatedPose?
        fileprivate let animationPlayback: SourceStudioAnimation.Playback
    }
    public func captureDynamicsCheckpoint() -> DynamicsCheckpoint {
        .init(owner: ObjectIdentifier(self), simulation: dynamics, step: dynamicsStep, evaluated: evaluatedCache, animationPlayback: animationPlayback)
    }
    public func restoreDynamicsCheckpoint(_ checkpoint: DynamicsCheckpoint) throws {
        guard checkpoint.owner == ObjectIdentifier(self) else { throw RigError.invalid("Dynamics checkpoint belongs to another character instance.") }
        dynamics = checkpoint.simulation; dynamicsStep = checkpoint.step; evaluatedCache = checkpoint.evaluated
        animationPlayback = checkpoint.animationPlayback
    }
    public func clearDynamicsStep() { dynamicsStep = nil; evaluatedCache = nil; dynamics?.resetHistory() }

    public init(reference: SourceStudioCharacterReference, resources: ResourceStore) throws {
        self.reference = reference
        attachments = try reference.attachmentCatalogFile.map { try SourceStudioAttachments.load(url: URL(fileURLWithPath: $0)) }
        let data = try Self.read(URL(fileURLWithPath: reference.sceneFile), maximum: 256 * 1024 * 1024)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == reference.sceneSHA256 else {
            throw RigError.invalid("The referenced source scene changed; import it again to update this preview.")
        }
        let scene = try KoikatsuSceneReader.decodeDocument(data)
        var stack = scene.snapshot.roots, match: KoikatsuCharacterRecord?
        while let object = stack.popLast() {
            if object.sourceKey == reference.objectKey { match = object.character; break }
            stack += object.children
            if let character = object.character { stack += character.accessoryChildren.values.flatMap { $0 } }
        }
        guard let record = match else { throw RigError.invalid("Source character record is missing.") }
        self.record = record
        let card = try record.card(), identity = try card.customization()
        guard identity.sex == Int(record.sex) else { throw RigError.invalid("Scene character/card sex identities differ.") }
        try SourceMakerLibrary.validateAssemblyIdentity(card: card)
        let status = try card.block(named: "Status").map { try SourceMessagePack.decode($0.data).stringKeyedMap() } ?? [:]
        let coordinate = status["coordinateType"]?.integerValue ?? 0
        guard (0..<7).contains(coordinate) else { throw RigError.invalid("Unsupported saved Studio outfit index.") }
        self.coordinate = coordinate
        let (eyesBlink, blinkDiagnostic) = SourceStudioBlink.decode(status)
        self.eyesBlink = eyesBlink
        // OCIChar.ChangeBlink applies the saved card flag right after the load.
        self.blink = SourceStudioBlink(eyesBlink: eyesBlink)
        let library = try reference.makerLibraryFile.map { try SourceMakerLibrary.load(url: URL(fileURLWithPath: $0)) }
        var rigURL = URL(fileURLWithPath: reference.rigFile)
        let manifest = try JSONDecoder().decode(SourceAvatarManifest.self, from: Self.read(rigURL, maximum: 1024 * 1024))
        if (manifest.headID ?? 0) != identity.headID || (manifest.sex ?? (manifest.kind == "koikatsu-male-avatar" ? 0 : 1)) != identity.sex {
            guard let selected = try library?.assemblyURL(for: identity) else { throw RigError.invalid("Studio card assembly conversion is missing.") }
            rigURL = selected
        }
        let selectedManifest = try JSONDecoder().decode(SourceAvatarManifest.self, from: Self.read(rigURL, maximum: 1024 * 1024))
        let directory = rigURL.deletingLastPathComponent().resolvingSymlinksInPath()
        var correctionData: Data?
        if identity.boneType != 0 {
            let correction = directory.appendingPathComponent(selectedManifest.bodyCorrection ?? "shapecorrect.bytes").resolvingSymlinksInPath()
            guard correction.path.hasPrefix(directory.path + "/") else { throw RigError.invalid("Studio body correction escapes its folder.") }
            correctionData = try Self.read(correction, maximum: 1024 * 1024)
        }
        let options = try SourceMakerAssemblyOptions.body(sex: identity.sex, exType: identity.exType, boneType: identity.boneType, correctionData: correctionData)
        let prepared = try library?.prepare(card: card, coordinate: coordinate, baseURL: rigURL)
        selections = prepared?.selections ?? []
        let source = try prepared?.source ?? SourceRig.loadModel(url: rigURL)
        let contract = try SourceShapeContract.decode(Self.read(directory.appendingPathComponent("character-shape-contract.json"), maximum: 32 * 1024 * 1024))
        var appearance = try SourcePreviewAppearance.load(url: rigURL.deletingPathExtension().appendingPathExtension("appearance.json"), resources: resources)
        var messages: [String] = []
        if let blinkDiagnostic { messages.append(blinkDiagnostic) }
        let draft: SourceCardAppearance?
        do { draft = try SourceCardAppearance(card: card, coordinate: coordinate) }
        catch {
            if library != nil { throw error }
            draft = nil; messages.append("Card appearance records are incomplete; reference materials retained: \(error)")
        }
        let bindingsURL = rigURL.deletingPathExtension().appendingPathExtension("card-appearance.json")
        if let draft, FileManager.default.fileExists(atPath: bindingsURL.path) {
            var bindings = try SourceAppearanceBindings.load(url: bindingsURL)
            if let prepared { bindings = bindings.restricted(to: Set(prepared.source.parts.map { $0.mesh.name })) }
            let applied = try appearance.applying(draft, bindings: bindings, directory: directory, resources: resources)
            appearance = applied.appearance; messages += applied.diagnostics
        }
        if let draft, let applied = try prepared?.appearance(base: appearance, card: draft, resources: resources, modLibrary: nil) {
            appearance = applied.appearance; messages += applied.diagnostics
        }
        if library == nil { messages.append("No converted Maker library selected; reference hair/clothes geometry retained.") }
        let expression = try SourceExpressionContract.decode(Self.read(directory.appendingPathComponent("source-expression-contract.json"), maximum: 32 * 1024 * 1024))
        var inputs = expression.defaults
        inputs.eyebrowPattern = status["eyebrowPtn"]?.integerValue ?? inputs.eyebrowPattern
        inputs.eyesPattern = status["eyesPtn"]?.integerValue ?? inputs.eyesPattern
        inputs.mouthPattern = status["mouthPtn"]?.integerValue ?? inputs.mouthPattern
        func rate(_ name: String, fallback: Float) throws -> Float {
            guard let value = status[name] else { return fallback }
            let number: Float
            switch value { case .float(let v): number = Float(v); case .integer(let v): number = Float(v); default: throw RigError.invalid("Invalid Studio expression rate.") }
            guard number.isFinite, (0...1).contains(number) else { throw RigError.invalid("Studio expression rate is outside 0...1.") }
            return number
        }
        inputs.eyebrowOpenMax = try rate("eyebrowOpenMax", fallback: inputs.eyebrowOpenMax)
        inputs.eyesOpenMax = try rate("eyesOpenMax", fallback: inputs.eyesOpenMax)
        inputs.mouthOpenMax = try rate("mouthOpenMax", fallback: inputs.mouthOpenMax)
        inputs.mouthOpenRate = record.mouthOpen
        _ = try expression.weights(source: source, inputs: inputs)
        expressionInputs = inputs
        preview = try SourceRigPreview(source: source, contract: contract, resources: resources, appearance: appearance, expressionContract: expression, bodyOptions: options)
        let settings = try card.previewSettings(contract: contract, sex: identity.sex, headID: identity.headID, boneType: identity.boneType)
        let baseline = try preview.pose(bodyValues: settings.bodyValues, faceValues: settings.faceValues, boneModifiers: settings.boneModifiers, coordinate: coordinate)
        self.baseline = baseline
        struct Catalog: Decodable { let bones: [SourceStudioPose.Bone] }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Self.read(URL(fileURLWithPath: reference.boneCatalogFile), maximum: 16 * 1024 * 1024))
        poseCatalog = catalog.bones
        let roots = source.rig.nodes.indices.filter { source.rig.nodes[$0].parent == nil }
        guard roots.count == 1 else { throw RigError.invalid("Source scene preview requires a single assembled root.") }
        characterRoot = roots[0]; animationHeight = identity.bodyValues.first ?? 0.5
        animationDirectory = reference.animationCatalogFile.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        animationCatalog = try reference.animationCatalogFile.map { try SourceStudioAnimationCatalog.load(url: URL(fileURLWithPath: $0)) }
        handPatternLibrary = try reference.handPatternsFile.map { try SourceStudioHandPatterns.load(url: URL(fileURLWithPath: $0)) }
        var animationBaseline = baseline
        if let animationCatalog, let animationDirectory {
            do {
                let state = SourceStudioAnimationState(record: record)
                let animation = try animationCatalog.resolve(state, directory: animationDirectory)
                animationCache["\(state.group)/\(state.category)/\(state.no)"] = animation
                animationBaseline = try animation.pose(state: state, elapsed: 0, height: animationHeight, rig: source.rig, baseline: baseline)
                let low = Set(animation.entry.lowDetailOnlyPaths ?? [])
                let missing = Set(animation.entry.unboundPaths ?? []).subtracting(low)
                if !missing.isEmpty { messages.append("Animation retains \(missing.count) unmapped source transform paths.") }
                if !low.isEmpty { messages.append("\(low.count) animation tracks belong only to original low-detail bones; the high-detail source character also omits them.") }
                if animation.entry.optionItems { messages.append("Animation option-item assets are not yet instantiated.") }
            } catch { messages.append("Saved Studio animation unavailable: \(error)") }
        } else { messages.append("Studio animation catalog is not configured.") }
        let savedPatterns = record.handPatterns
        if savedPatterns.contains(where: { $0 != 0 }) {
            if let handPatternLibrary {
                messages.append("Saved Studio hand patterns replay converted looping clips; the original capture phase is not recorded, so elapsed 0 restarts the loop at frame 0.")
                do {
                    for (index, hand) in ["L", "R"].enumerated() where savedPatterns.indices.contains(index) && savedPatterns[index] != 0 {
                        if case let .unknown(diagnostic) = try handPatternLibrary.pose(hand: hand, pattern: Int(savedPatterns[index]), elapsed: 0) {
                            messages.append(diagnostic)
                        }
                    }
                } catch { messages.append("Studio hand pattern check unavailable: \(error)") }
            } else {
                messages.append("Saved Studio hand patterns \(savedPatterns) have no converted pattern library, so both hands keep the incoming pose; the pattern is never guessed.")
            }
        }
        // The scene load restores the saved neck bytes and applies the effective
        // look pattern (card neckLookPtn wins over the saved ptnNo); only FIX
        // and FORWARD resolve to an override here, each deferred case explains
        // itself once at import instead of per frame.
        var neckLook: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf], lookType: SourceStudioNeckLookType)?
        if let lookSettingsFile = reference.lookSettingsFile {
            do {
                let lookSettings = try SourceStudioNeckLookSettings(json: Self.read(URL(fileURLWithPath: lookSettingsFile), maximum: 4 * 1024 * 1024))
                let savedNeck = try SourceStudioNeckLookData(bytes: record.neckData)
                let lookStatus = SourceStudioLookStatus(status: status)
                let pattern = SourceStudioLookData.effectiveNeckPattern(status: lookStatus, savedNeckPatternNumber: savedNeck.patternNumber)
                let resolution = SourceStudioNeckLookOverride.resolve(effectivePattern: pattern, settings: lookSettings, savedBoneCount: savedNeck.fixAngles.count)
                messages.append("Neck look override \(resolution.applied.rawValue): \(resolution.reason)")
                if let lookType = resolution.lookType, resolution.applied != .none {
                    neckLook = (lookSettings, savedNeck.fixAngles, lookType)
                }
            } catch { messages.append("Studio neck look override unavailable: \(error); the animated pose is kept.") }
        } else if let savedNeck = try? SourceStudioNeckLookData(bytes: record.neckData), savedNeck.patternNumber != 0 || !savedNeck.fixAngles.isEmpty {
            messages.append("Neck look settings are not configured; the saved neck pattern \(savedNeck.patternNumber) is not applied and the animated pose is kept.")
        }
        self.neckLook = neckLook
        let restored = try record.makePose(rig: source.rig, catalog: catalog.bones, baseline: animationBaseline,
            characterRoot: roots[0], bodyRoot: source.rig.uniqueNode(named: "p_cf_body_bone"),
            hairRoot: source.rig.uniqueNode(named: "cf_J_FaceUp_ty"))
        controller = restored.controller
        let ikURL = URL(fileURLWithPath: reference.boneCatalogFile).deletingLastPathComponent().appendingPathComponent("ik-bindings.json")
        if FileManager.default.fileExists(atPath: ikURL.path) {
            do {
                let bindings = try JSONDecoder().decode(SourceStudioIK.Bindings.self, from: Self.read(ikURL, maximum: 1024 * 1024))
                let solver = try SourceStudioIK(rig: source.rig, bindings: bindings, initializationPose: baseline)
                ikSolver = solver
                let result = try solver.apply(rig: source.rig, baseline: restored.pose, savedTargets: record.ikTargets,
                    enabled: controller.enableIK, activeGroups: controller.activeIK, characterRoot: roots[0])
                pose = result.pose; ikGuides = result.guides
                messages += result.diagnostics
            } catch {
                pose = restored.pose; ikGuides = []
                messages.append("Source IK binding unavailable: \(error)")
            }
        } else {
            pose = restored.pose; ikGuides = []
            if record.enableIK { messages.append("Recovered IK prefab bindings are missing.") }
        }
        let dynamicsURL = reference.dynamicsFile.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: reference.rigFile).deletingLastPathComponent().appendingPathComponent("source-dynamics.json")
        if FileManager.default.fileExists(atPath: dynamicsURL.path) {
            do {
                let bound = try SourceStudioDynamics.bindHair(SourceDynamicsDocument.load(url: dynamicsURL), rig: source.rig)
                dynamics = try SourceStudioDynamics(rig: source.rig, initializationPose: baseline, bindings: bound.bindings)
                messages += bound.diagnostics
                messages.append("\(bound.bindings.count) source hair DynamicBone components run after animation/FK/IK in character space; unrelated cloth/accessory dynamics and object-motion inertia are not restored.")
            } catch { messages.append("Source hair dynamics unavailable: \(error)") }
        } else { messages.append("Converted source hair dynamics are not configured.") }
        let hasNativeIK = ikSolver != nil
        diagnostics = ["Converted card assets, shape, static ABMX, expression settings and saved kinematics restored. Catalog-selected animation is evaluated before FK/IK and available source hair dynamics."]
            + messages + settings.diagnostics + restored.diagnostics.filter { !$0.hasPrefix("Character appearance,") && !(hasNativeIK && $0.hasPrefix("Source IK is enabled;")) }
    }

    public func frame(camera: OrbitCamera, mainLight: MainLight, effects: SceneEffects,
                      world: float4x4, objectID: UInt32, fkRotations: [Int: Float3] = [:], ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil,
                      animationElapsed: Float = 0) throws -> RenderFrame {
        var frame = try preview.frame(camera: camera, mainLight: mainLight, effects: effects,
            expression: effectiveExpressionInputs(), poseOverride: editedPose(fkRotations: fkRotations, ikTargets: ikTargets, kinematics: kinematics, animationState: animationState, animationElapsed: animationElapsed))
        for i in frame.items.indices { frame.items[i].model = world * frame.items[i].model; frame.items[i].objectID = objectID }
        frame.sceneBounds = frame.sceneBounds.transformed(by: world)
        return frame
    }

    public func editedPose(fkRotations: [Int: Float3] = [:], ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil,
                           animationElapsed: Float = 0) throws -> RigPose {
        let state = animationState ?? SourceStudioAnimationState(record: record)
        if let cache = evaluatedCache, cache.state == state, cache.elapsed == animationElapsed, cache.fk == fkRotations, cache.ik == ikTargets, cache.kinematics == kinematics { return cache.pose }
        try SourceStudioIKEditing.validate(ikTargets); try kinematics?.validate()
        var result: RigPose
        if let animation = try resolvedAnimation(state, required: animationState != nil) {
            result = try animation.pose(state: state, elapsed: animationElapsed, height: animationHeight, rig: preview.source.rig, baseline: baseline, playback: &animationPlayback)
        } else { result = baseline }
        // The hand Animator is independent of the body animation, so saved
        // patterns replay at their own loop phase after the body pose exists
        // and before FK/IK edits the bones. A saved ID without a clip left its
        // hand untouched and was already reported at initialization, because
        // that report does not depend on the clock.
        if let handPatternLibrary {
            try handPatternLibrary.applySaved(record.handPatterns, to: preview.source.rig, on: &result, elapsed: animationElapsed)
        }
        var effective = kinematics ?? SourceStudioKinematicState(record: record)
        for (id, angles) in fkRotations {
            guard let target = controller.targets.first(where: { $0.bone.id == id && $0.hasGuide }),
                  angles.x.isFinite, angles.y.isFinite, angles.z.isFinite else { throw RigError.invalid("Source FK edit has no original guide or finite rotation.") }
            if kinematics == nil {
                for (index, group) in SourceStudioPose.Group.fkParts.enumerated() where !group.intersection(target.bone.fkGroup).isEmpty { effective.activeFK[index] = true }
            }
        }
        if kinematics == nil, !fkRotations.isEmpty { effective.enableFK = true; effective.enableIK = false }
        if kinematics == nil, !ikTargets.isEmpty {
            effective.enableFK = false; effective.enableIK = true
            for id in ikTargets.keys { effective.activeIK[try SourceStudioIKEditing.groupIndex(target: id)] = true }
        }
        let restored = try record.makePose(rig: preview.source.rig, catalog: poseCatalog, baseline: result,
            characterRoot: characterRoot, bodyRoot: preview.source.rig.uniqueNode(named: "p_cf_body_bone"),
            hairRoot: preview.source.rig.uniqueNode(named: "cf_J_FaceUp_ty"), kinematics: effective, fkOverrides: fkRotations)
        let edited = restored.controller
        result = restored.pose
        var guides: [SourceStudioIK.Guide] = []
        if let ikSolver {
            let solved = try ikSolver.apply(rig: preview.source.rig, baseline: result, savedTargets: record.ikTargets,
                enabled: edited.enableIK, activeGroups: edited.activeIK, characterRoot: characterRoot, guideOverrides: ikTargets.mapValues(\.transform))
            result = solved.pose; guides = solved.guides
        } else if !ikTargets.isEmpty { throw RigError.invalid("Source IK bindings are unavailable for guide editing.") }
        // The NeckLookCalcVer2 override runs on the FK/IK-restored pose and
        // before hair dynamics, so dynamics sees the solved neck. The override
        // result depends on animationElapsed, which is already in the cache key.
        // Studio forces pattern 4 while the FK neck group is active; the
        // relative order of Studio FK and the look controller is not recovered,
        // so FK wins there and the conflict is reported once.
        if let neckLook {
            if effective.enableFK, effective.activeFK.count > 1, effective.activeFK[1] {
                if reportedNeckLookFK.insert(neckLook.lookType).inserted {
                    diagnostics.append("Neck look override skipped: FK owns the neck.")
                }
            } else {
                try SourceStudioNeckLook.applied(pose: &result, rig: preview.source.rig, settings: neckLook.settings,
                    fixAngle: neckLook.fixAngle, lookType: neckLook.lookType, elapsed: animationElapsed, neckFKActive: false)
            }
        }
        if var simulation = dynamics, dynamicsStep?.elapsed == animationElapsed {
            result = try simulation.evaluate(time: animationElapsed, rig: preview.source.rig, upstream: result,
                enableFK: effective.enableFK, activeFK: effective.activeFK,
                deltaTime: dynamicsStep?.elapsed == animationElapsed ? dynamicsStep?.delta : nil)
            dynamics = simulation
        }
        evaluatedCache = (state, animationElapsed, fkRotations, ikTargets, kinematics, result, guides)
        return result
    }

    /// Supply the actual source frame delta before requesting this elapsed pose.
    /// Pure pose samples do not integrate particles. Repeated consumers of a tick
    /// reuse its result; backwards seeks and paused edits reset the session.
    public func setDynamicsStep(elapsed: Float, deltaTime: Float) throws {
        guard elapsed.isFinite, elapsed >= 0, deltaTime.isFinite, deltaTime >= 0 else { throw RigError.invalid("Invalid Studio dynamics frame clock.") }
        dynamicsStep = (elapsed, deltaTime)
        evaluatedCache = nil
    }

    public func editedIKGuides(fkRotations: [Int: Float3] = [:], ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil,
                               animationState: SourceStudioAnimationState? = nil, animationElapsed: Float = 0) throws -> [SourceStudioIK.Guide] {
        _ = try editedPose(fkRotations: fkRotations, ikTargets: ikTargets, kinematics: kinematics, animationState: animationState, animationElapsed: animationElapsed)
        return evaluatedCache?.guides ?? []
    }

    public func ikCharacterFrame(pose: RigPose) throws -> (matrix: float4x4, rotation: simd_quatf) {
        (try preview.source.rig.evaluate(pose).worldMatrices[characterRoot],
         try SourceStudioGuide.rotation(node: characterRoot, rig: preview.source.rig, pose: pose))
    }

    public func savedAnimationState(animationState: SourceStudioAnimationState? = nil, animationElapsed: Float = 0) throws -> SourceStudioAnimationState {
        var state = animationState ?? SourceStudioAnimationState(record: record)
        if let animation = try resolvedAnimation(state, required: animationState != nil) {
            state.normalizedTime = try animation.clock(state: state, elapsed: animationElapsed, height: animationHeight, playback: &animationPlayback).normalizedTime
        }
        return state
    }

    public func resetAnimationPlayback() {
        animationPlayback.reset(); evaluatedCache = nil
    }

    /// The saved expression inputs with the blink clock applied. While the card
    /// blinks, the recovered rate drives eye and synced brow openness; with the
    /// flag off the fixed sentinel leaves room for ChangeEyesBlinkFlag's
    /// forced-open rates, which stay at 1. Automatic blinking off renders the
    /// saved openness instead, like the Maker preview holding its manual rate.
    public func effectiveExpressionInputs() -> SourceExpressionInputs? {
        guard var inputs = expressionInputs else { return nil }
        if automaticBlink {
            inputs.blinkRate = blink.rate
            if !eyesBlink { inputs.eyesOpenRate = 1; inputs.eyebrowOpenRate = 1 }
        }
        return inputs
    }

    /// Advances this card's recovered blink control with the monotonic Studio
    /// animation clock (see SourceStudioBlink). Returns true only when the
    /// rendered blink rate changed. The draw hooks mirror
    /// SourceBlinkPlayback.update for deterministic replay.
    @discardableResult public func updateBlink(elapsed: Float,
        randomInteger: (Int, Int) throws -> Int = { lower, upper in lower == upper ? lower : Int.random(in: lower..<upper) },
        randomFloat: (Float, Float) throws -> Float = { Float.random(in: $0...$1) }
    ) throws -> Bool {
        try blink.update(elapsed: elapsed, randomInteger: randomInteger, randomFloat: randomFloat)
    }

    public var hasSavedAnimation: Bool {
        animationCache["\(record.animation.group)/\(record.animation.category)/\(record.animation.no)"] != nil
    }

    private func resolvedAnimation(_ state: SourceStudioAnimationState, required: Bool) throws -> SourceStudioAnimation? {
        let key = "\(state.group)/\(state.category)/\(state.no)"
        if let cached = animationCache[key] { return cached }
        guard let animationCatalog, let animationDirectory else {
            if required { throw RigError.invalid("Studio animation catalog is not configured.") }
            return nil
        }
        do {
            let value = try animationCatalog.resolve(state, directory: animationDirectory)
            animationCache[key] = value
            return value
        } catch { if required { throw error }; return nil }
    }

    public func attachmentMatrix(pointID: Int32, fkRotations: [Int: Float3] = [:], ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil, animationElapsed: Float = 0) throws -> float4x4 {
        guard let attachments else { throw RigError.invalid("Source Studio attachment catalog is missing.") }
        return try attachments.matrix(pointID: pointID, rig: preview.source.rig, pose: editedPose(fkRotations: fkRotations, ikTargets: ikTargets, kinematics: kinematics, animationState: animationState, animationElapsed: animationElapsed))
    }

    public func attachmentRotation(pointID: Int32, fkRotations: [Int: Float3] = [:], ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil, animationElapsed: Float = 0) throws -> simd_quatf {
        guard let point = attachments?.points.first(where: { $0.id == pointID }) else { throw RigError.invalid("Source Studio attachment is unavailable.") }
        return try SourceStudioGuide.rotation(node: preview.source.rig.uniqueNode(named: point.nodeName),
            rig: preview.source.rig, pose: editedPose(fkRotations: fkRotations, ikTargets: ikTargets, kinematics: kinematics, animationState: animationState, animationElapsed: animationElapsed))
    }

    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximum else { throw RigError.invalid("Source preview input is not a bounded regular file.") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw RigError.invalid("Source preview input grew beyond its limit.") }
        return data
    }
}
