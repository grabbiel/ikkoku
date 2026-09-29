import Foundation
import Assets
import CryptoKit
import simd
import CoreMath
import Scene
import Character
import Renderer
import ShaderTypes

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
    public private(set) var pose: RigPose
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
    public private(set) var controller: SourceStudioPose
    private var baseline: RigPose
    private let attachments: SourceStudioAttachments?
    public private(set) var ikGuides: [SourceStudioIK.Guide]
    /// The card's saved shape slot rates in contract order — the import
    /// baseline. Export writes back only edited arrays that differ from these.
    public let savedFaceValues: [Float]
    public let savedBodyValues: [Float]
    /// The current edited face/body slot rates; nil keeps the card's saved
    /// arrays. setShapeValues rebuilds the baseline once per accepted edit.
    public private(set) var sourceFaceValues: [Float]?
    public private(set) var sourceBodyValues: [Float]?
    private let animationCatalog: SourceStudioAnimationCatalog?
    private let animationDirectory: URL?
    private let handPatternLibrary: SourceStudioHandPatterns?
    private var animationCache: [String: SourceStudioAnimation] = [:]
    private var animationPlayback = SourceStudioAnimation.Playback()
    private var blink: SourceStudioBlink
    private let animationHeight: Float
    /// The animation clip's height parameter follows the effective body height
    /// slot, the way rebuilding an original character recomputes the load-time
    /// height after a shape edit.
    private var effectiveAnimationHeight: Float { sourceBodyValues?.first ?? animationHeight }
    private let characterRoot: Int
    private let poseCatalog: [SourceStudioPose.Bone]
    private var ikSolver: SourceStudioIK?
    private var dynamics: SourceStudioDynamics?
    private var dynamicsStep: (elapsed: Float, delta: Float)?
    /// Resolved FIX/FORWARD neck look override: the prefab settings, the saved
    /// fixAngle quaternions and the pattern's lookType. Nil when the look
    /// settings are not configured or the pattern resolves to a kept pose.
    private let neckLook: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf], lookType: SourceStudioNeckLookType)?
    /// The prefab settings and saved fixAngle when the effective pattern is
    /// TARGET or AWAY; the live runtime steps from them every Studio tick.
    private let liveNeckLook: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf], pattern: Int)?
    /// The TARGET/AWAY gaze runtime, or nil when the pattern is not one of
    /// those modes. Reset with the animation clock so a seek restarts the
    /// transition from the saved fixAngle, like a scene reload.
    private var neckLookRuntime: SourceStudioNeckLookRuntime?
    /// False again after every resetNeckLook; the first step of an episode at
    /// elapsed 0 then runs with firstFrameDelta, like applied(pose:) does.
    private var hasSteppedNeckLook = false
    /// Card neckTargetType; 0 (or absent) is the main camera, any other target
    /// has no recovered meaning, so the animated pose is kept and reported.
    private let neckTargetType: Int32?
    /// One-shot per lookType so a repeated FK neck edit does not repeat the notice.
    private var reportedNeckLookFK: Set<SourceStudioNeckLookType> = []
    /// Resolved live eye look: the same settings document's eyes block, the
    /// effective pattern and the saved angles (nil before scene version
    /// 0.0.8). Nil when the pattern resolves to kept animated eyes.
    private let liveEyeLook: (settings: SourceStudioEyeLookSettings, pattern: Int,
                              savedAngles: (horizontal: [Double], vertical: [Double])?)?
    /// Why the eyes are not live, for the inspector's kept-pose readout; nil
    /// while the gaze runs or when the character never had an eye pattern.
    private let eyeLookNote: String?
    /// The EyeLookCalc runtime, Init'ed from the first evaluated frame after
    /// every resetEyeLook; the step runs for the rates only, nothing writes
    /// eye bones yet (the iris writeback is the next slice).
    private var eyeLookRuntime: SourceStudioEyeLookRuntime?
    /// Card eyesTargetType; 0 (or absent) is the main camera, any other target
    /// has no recovered meaning, so the animated eyes are kept and reported.
    private let eyesTargetType: Int32?
    /// Set when the Init from a live pattern failed: the pattern retires until
    /// resetEyeLook (diagnosed once) so the tick does not knock per frame.
    private var eyeLookFailure: String?
    /// The store backing the preview's meshes, so a render item's MeshHandle
    /// resolves back to its source mesh name when the iris overrides apply.
    private let resources: ResourceStore
    /// The same settings document's eyeMaterial block: the per-eye
    /// EyeLookMaterialControll snapshot whose _ST values the renderer applies
    /// every frame. Empty when the block is missing or malformed (reported at
    /// init), and the irises then keep their identity uniforms.
    private let irisEyes: [SourceStudioEyeMaterialSettings]
    /// The load-time ChangeSettingEye* values read once off the card's face
    /// record, substituted for each eye's prefab offset/scale/hl snapshot in
    /// every frame's _ST math.  Nil while the fields are unreadable (the
    /// prefab snapshot stays; reported at init) or under the special-male skip.
    private let irisCardValues: SourceStudioIrisRendering.CardValues?
    /// Eyes whose _ST math threw once (inverted exported limits); the notice
    /// must not repeat per frame.
    private var reportedIrisTransform: Set<Int> = []
    public var dynamicsComponentCount: Int { dynamics?.bindings.count ?? 0 }
    /// preOverride is the FK/IK-solved pose before the neck look override
    /// wrote anything: the pose the TARGET/AWAY gaze solver reads its Transforms
    /// from, the way the original LateUpdate runs NeckUpdateCalc after
    /// Animator/FK/IK and before its own rotation write.
    fileprivate typealias EvaluatedPose = (state: SourceStudioAnimationState, elapsed: Float, fk: [Int: Float3], ik: [Int32: SourceStudioIKEdit], kinematics: SourceStudioKinematicState?, pose: RigPose, preOverride: RigPose, guides: [SourceStudioIK.Guide])
    private var evaluatedCache: EvaluatedPose?
    /// The import-time shape/binding inputs setShapeValues replays when the
    /// edited arrays replace the card's saved shape values.
    private let shapeBoneModifiers: SourceBoneModifiers?
    private let shapeIKBindings: SourceStudioIK.Bindings?
    private let shapeDynamicsBindings: [SourceStudioDynamics.Binding]?
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
        self.resources = resources
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
        savedFaceValues = settings.faceValues
        savedBodyValues = settings.bodyValues
        shapeBoneModifiers = settings.boneModifiers
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
        // look pattern (card neckLookPtn wins over the saved ptnNo); FIX and
        // FORWARD resolve to the deferred override above, TARGET and AWAY get
        // the live gaze runtime the Studio tick steps, and each remaining
        // deferred case explains itself once at import instead of per frame.
        var neckLook: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf], lookType: SourceStudioNeckLookType)?
        var liveNeckLook: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf], pattern: Int)?
        var neckTargetType: Int32?
        if let lookSettingsFile = reference.lookSettingsFile {
            do {
                let lookSettings = try SourceStudioNeckLookSettings(json: Self.read(URL(fileURLWithPath: lookSettingsFile), maximum: 4 * 1024 * 1024))
                let savedNeck = try SourceStudioNeckLookData(bytes: record.neckData)
                let lookStatus = SourceStudioLookStatus(status: status)
                neckTargetType = lookStatus.neckTargetType
                let pattern = SourceStudioLookData.effectiveNeckPattern(status: lookStatus, savedNeckPatternNumber: savedNeck.patternNumber)
                let resolution = SourceStudioNeckLookOverride.resolve(effectivePattern: pattern, settings: lookSettings, savedBoneCount: savedNeck.fixAngles.count)
                if let lookType = resolution.lookType, resolution.applied != .none {
                    neckLook = (lookSettings, savedNeck.fixAngles, lookType)
                    messages.append("Neck look override \(resolution.applied.rawValue): \(resolution.reason)")
                } else if let lookType = resolution.lookType, lookType == .target || lookType == .away,
                          savedNeck.fixAngles.count == 2 {
                    // NeckLookControllerVer2.target drives the gaze and its
                    // rate is 1; type 0 reads the main camera, any other type
                    // has no recovered meaning, so the animated pose is kept.
                    if let target = neckTargetType, target != 0 {
                        messages.append("Neck look target type \(target) is not the main camera (0); the animated pose is kept.")
                    } else {
                        liveNeckLook = (lookSettings, savedNeck.fixAngles, Int(pattern))
                        messages.append("Neck look override live: \(lookType.rawValue) follows the Studio camera from the saved fixAngle.")
                    }
                } else {
                    messages.append("Neck look override \(resolution.applied.rawValue): \(resolution.reason)")
                }
            } catch { messages.append("Studio neck look override unavailable: \(error); the animated pose is kept.") }
        } else if let savedNeck = try? SourceStudioNeckLookData(bytes: record.neckData), savedNeck.patternNumber != 0 || !savedNeck.fixAngles.isEmpty {
            messages.append("Neck look settings are not configured; the saved neck pattern \(savedNeck.patternNumber) is not applied and the animated pose is kept.")
        }
        self.neckLook = neckLook
        self.liveNeckLook = liveNeckLook
        self.neckTargetType = neckTargetType
        if let live = liveNeckLook {
            do { neckLookRuntime = try SourceStudioNeckLookRuntime(settings: live.settings, fixAngle: live.fixAngle) }
            catch { messages.append("Studio neck look runtime unavailable: \(error); the animated pose is kept.") }
        }
        // The same settings document's eyes block drives the eye calculator.
        // AddObjectAssist restores LoadAngle first and ChangeLookEyesPtn last,
        // so the card eyesLookPtn wins over the prefab's eyeController.ptnNo,
        // and EyeLookCalc reads the main camera when eyesTargetType is 0 or
        // absent. NO_LOOK is reported and skipped: its fixAngle write is not
        // recorded by the look trace, so the animated eyes are kept.
        var liveEyeLook: (settings: SourceStudioEyeLookSettings, pattern: Int,
                          savedAngles: (horizontal: [Double], vertical: [Double])?)?
        var eyeLookNote: String?
        var eyesTargetType: Int32?
        var irisEyes: [SourceStudioEyeMaterialSettings] = []
        if let lookSettingsFile = reference.lookSettingsFile {
            do {
                let lookData = try Self.read(URL(fileURLWithPath: lookSettingsFile), maximum: 4 * 1024 * 1024)
                let eyeSettings = try SourceStudioEyeLookSettings(json: lookData)
                let lookStatus = SourceStudioLookStatus(status: status)
                eyesTargetType = lookStatus.eyesTargetType
                let savedEyes = try SourceStudioEyeLookData(bytes: record.eyesData, sceneVersion: scene.snapshot.version)
                if let pattern = lookStatus.eyesLookPtn ?? eyeSettings.eyeControllerPattern,
                   pattern >= 0, eyeSettings.eyeTypeStates.indices.contains(Int(pattern)) {
                    let lookType = eyeSettings.eyeTypeStates[Int(pattern)].lookType
                    if let target = eyesTargetType, target != 0 {
                        eyeLookNote = "target type \(target) is not the main camera"
                        messages.append("Eye look target type \(target) is not the main camera (0); the animated eyes are kept.")
                    } else if lookType == .noLook {
                        eyeLookNote = "pattern \(pattern) is NO_LOOK"
                        messages.append("Eye look pattern \(pattern) is NO_LOOK; its fixAngle write is not recorded, so the animated eyes are kept.")
                    } else {
                        let angles: (horizontal: [Double], vertical: [Double])?
                        if let angleH = savedEyes.angleH, let angleV = savedEyes.angleV {
                            angles = (horizontal: angleH.map(Double.init), vertical: angleV.map(Double.init))
                        } else {
                            angles = nil
                            messages.append("Scene version \(scene.snapshot.version) saves no eye angles; the calculator Inits flat instead.")
                        }
                        liveEyeLook = (eyeSettings, Int(pattern), angles)
                        messages.append("Eye look live: \(lookType.rawValue) pattern \(pattern) follows the Studio camera.")
                    }
                } else {
                    let shown = (lookStatus.eyesLookPtn ?? eyeSettings.eyeControllerPattern).map(String.init) ?? "unset"
                    eyeLookNote = "pattern \(shown) has no eyeTypeStates entry"
                    messages.append("Eye look pattern is unset or outside the prefab's \(eyeSettings.eyeTypeStates.count) states; the animated eyes are kept.")
                }
                do { irisEyes = try SourceStudioEyeMaterialSettings.document(json: lookData) }
                catch { messages.append("Studio eye material settings unavailable: \(error); the irises keep their resting offset.") }
            } catch { messages.append("Studio eye look override unavailable: \(error); the animated eyes are kept.") }
        }
        self.liveEyeLook = liveEyeLook
        self.eyeLookNote = eyeLookNote
        self.eyesTargetType = eyesTargetType
        self.irisEyes = irisEyes
        // The ChangeSettingEye* calls run once at load off the face record's
        // six fields; a field the card does not carry keeps the whole prefab
        // snapshot (the original's decoded fields always exist, so a per-field
        // fallback is not recovered) instead of inventing a constructor default.
        var irisCardValues: SourceStudioIrisRendering.CardValues?
        if !irisEyes.isEmpty {
            let paths = ["face.pupilX", "face.pupilY", "face.pupilWidth", "face.pupilHeight",
                         "face.hlUpY", "face.hlDownY"]
            let unprefixed = ["pupil X", "pupil Y", "pupil width", "pupil height", "highlight up Y", "highlight down Y"]
            var fields: [Double] = [], missing: [String] = []
            for (path, label) in zip(paths, unprefixed) {
                guard let value = draft?.number(path) else { missing.append(label); continue }
                fields.append(Double(value))
            }
            if fields.count == paths.count {
                irisCardValues = SourceStudioIrisRendering.cardOverrides(
                    pupilX: fields[0], pupilY: fields[1], pupilWidth: fields[2], pupilHeight: fields[3],
                    hlUpY: fields[4], hlDownY: fields[5], sex: identity.sex, exType: identity.exType)
                if irisCardValues != nil {
                    messages.append("Iris rendering applies the card pupil offset/scale and highlight offsets over the bo_head_00 prefab snapshot.")
                } else {
                    messages.append("Iris rendering keeps the bo_head_00 prefab offset/scale snapshot: the special-male ChangeSettingEye skip applies to this card.")
                }
            } else {
                messages.append("Iris card fields \(missing.joined(separator: ", ")) are missing from the card record; the bo_head_00 prefab offset/scale snapshot is kept.")
            }
        }
        self.irisCardValues = irisCardValues
        let restored = try record.makePose(rig: source.rig, catalog: catalog.bones, baseline: animationBaseline,
            characterRoot: roots[0], bodyRoot: source.rig.uniqueNode(named: "p_cf_body_bone"),
            hairRoot: source.rig.uniqueNode(named: "cf_J_FaceUp_ty"))
        controller = restored.controller
        let ikURL = URL(fileURLWithPath: reference.boneCatalogFile).deletingLastPathComponent().appendingPathComponent("ik-bindings.json")
        var shapeIK: SourceStudioIK.Bindings?
        if FileManager.default.fileExists(atPath: ikURL.path) {
            do {
                let bindings = try JSONDecoder().decode(SourceStudioIK.Bindings.self, from: Self.read(ikURL, maximum: 1024 * 1024))
                let solver = try SourceStudioIK(rig: source.rig, bindings: bindings, initializationPose: baseline)
                shapeIK = bindings
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
        shapeIKBindings = shapeIK
        let dynamicsURL = reference.dynamicsFile.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: reference.rigFile).deletingLastPathComponent().appendingPathComponent("source-dynamics.json")
        var shapeDynamics: [SourceStudioDynamics.Binding]?
        if FileManager.default.fileExists(atPath: dynamicsURL.path) {
            do {
                let bound = try SourceStudioDynamics.bindHair(SourceDynamicsDocument.load(url: dynamicsURL), rig: source.rig)
                dynamics = try SourceStudioDynamics(rig: source.rig, initializationPose: baseline, bindings: bound.bindings)
                shapeDynamics = bound.bindings
                messages += bound.diagnostics
                messages.append("\(bound.bindings.count) source hair DynamicBone components run after animation/FK/IK in character space; unrelated cloth/accessory dynamics and object-motion inertia are not restored.")
            } catch { messages.append("Source hair dynamics unavailable: \(error)") }
        } else { messages.append("Converted source hair dynamics are not configured.") }
        shapeDynamicsBindings = shapeDynamics
        let hasNativeIK = ikSolver != nil
        diagnostics = ["Converted card assets, shape, static ABMX, expression settings and saved kinematics restored. Catalog-selected animation is evaluated before FK/IK and available source hair dynamics."]
            + messages + settings.diagnostics + restored.diagnostics.filter { !$0.hasPrefix("Character appearance,") && !(hasNativeIK && $0.hasPrefix("Source IK is enabled;")) }
    }

    public func frame(camera: OrbitCamera, mainLight: MainLight, effects: SceneEffects,
                      world: float4x4, objectID: UInt32, fkRotations: [Int: Float3] = [:], faceValues: [Float]? = nil, bodyValues: [Float]? = nil, ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil,
                      animationElapsed: Float = 0) throws -> RenderFrame {
        var frame = try preview.frame(camera: camera, mainLight: mainLight, effects: effects,
            expression: effectiveExpressionInputs(), poseOverride: editedPose(fkRotations: fkRotations, faceValues: faceValues, bodyValues: bodyValues, ikTargets: ikTargets, kinematics: kinematics, animationState: animationState, animationElapsed: animationElapsed))
        for i in frame.items.indices { frame.items[i].model = world * frame.items[i].model; frame.items[i].objectID = objectID }
        applyIrisTransforms(to: &frame)
        frame.sceneBounds = frame.sceneBounds.transformed(by: world)
        return frame
    }

    /// The renderer-side half of EyeLookMaterialControll.Update: the frame's
    /// iris-shift rates become the two iris materials' _ST uniforms, matched by
    /// source mesh name against the eyeMaterial block's gameObject. Rates
    /// (0, 0) when the eye look is not live — the resting offset the original
    /// still applies. Iris materials are exactly the ones carrying
    /// MaterialFlagSourceIrisHighlights; a refused transform (inverted limits)
    /// keeps the identity uniforms and is diagnosed once per eye.
    private func applyIrisTransforms(to frame: inout RenderFrame) {
        guard !irisEyes.isEmpty else { return }
        let rates = eyeLookRates
        for i in frame.items.indices where (frame.items[i].material.uniforms.flags & MaterialFlagSourceIrisHighlights.rawValue) != 0 {
            guard let name = resources.mesh(frame.items[i].mesh)?.name,
                  let eye = SourceStudioIrisRendering.eye(ofMeshNamed: name, in: irisEyes) else { continue }
            let settings = irisEyes[eye]
            var rateH = 0.0, rateV = 0.0
            if let live = rates, live.horizontal.indices.contains(settings.eyeLR) {
                rateH = live.horizontal[settings.eyeLR]; rateV = live.vertical
            }
            guard let st = try? SourceStudioIrisRendering.transforms(rateH: rateH, rateV: rateV, settings: settings,
                                                                     card: irisCardValues),
                  st.count == 3 else {
                if reportedIrisTransform.insert(settings.eyeLR).inserted {
                    diagnostics.append("Iris texture transform refused the eye \(settings.eyeLR) rates; its irises keep the identity transform.")
                }
                continue
            }
            frame.items[i].material.uniforms.irisST0 = st[0]
            frame.items[i].material.uniforms.irisST1 = st[1]
            frame.items[i].material.uniforms.irisST2 = st[2]
        }
    }

    /// Validates edited face/body slot rates and rebuilds the shape baseline
    /// when they replace the card's saved arrays. The arguments are the
    /// effective values on every entry point (nil keeps the card's saved
    /// shape), so the rebuild runs once per accepted edit and a per-frame
    /// repeat of the same arrays only pays the comparison; a rejected edit
    /// throws before any state is mutated. Export diffs the document's arrays
    /// against `savedFaceValues`/`savedBodyValues` for the card writeback.
    public func setShapeValues(face: [Float]?, body: [Float]?) throws {
        guard face != sourceFaceValues || body != sourceBodyValues else { return }
        func validate(_ values: [Float]?, _ id: String) throws {
            guard let values else { return }
            guard let domain = preview.contract?.domain(id) else {
                throw RigError.invalid("This rig has no \(id) shape contract, so \(id) shape editing is unsupported.")
            }
            guard values.count == domain.valueCount else {
                throw RigError.invalid("Edited \(id) shape values must contain exactly \(domain.valueCount) rates in contract order.")
            }
            guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw RigError.invalid("Edited \(id) shape values must be finite and between 0 and 1.")
            }
        }
        try validate(face, "face")
        try validate(body, "body")
        // Build the whole replacement chain into locals first; a throw in any
        // stage leaves the previous baseline, controller, solver and dynamics
        // untouched and the rejected edit keeps rendering the old shape.
        let shapeBaseline = try preview.pose(bodyValues: body ?? savedBodyValues, faceValues: face ?? savedFaceValues,
            boneModifiers: shapeBoneModifiers, coordinate: coordinate)
        var animationBaseline = shapeBaseline
        let savedState = SourceStudioAnimationState(record: record)
        if let animation = animationCache["\(savedState.group)/\(savedState.category)/\(savedState.no)"] {
            animationBaseline = try animation.pose(state: savedState, elapsed: 0,
                height: (body ?? savedBodyValues).first ?? animationHeight, rig: preview.source.rig, baseline: shapeBaseline)
        }
        let restored = try record.makePose(rig: preview.source.rig, catalog: poseCatalog, baseline: animationBaseline,
            characterRoot: characterRoot, bodyRoot: preview.source.rig.uniqueNode(named: "p_cf_body_bone"),
            hairRoot: preview.source.rig.uniqueNode(named: "cf_J_FaceUp_ty"))
        var pose = restored.pose
        var guides: [SourceStudioIK.Guide] = []
        var solver = ikSolver
        if let ikBindings = shapeIKBindings {
            let rebuilt = try SourceStudioIK(rig: preview.source.rig, bindings: ikBindings, initializationPose: shapeBaseline)
            let solved = try rebuilt.apply(rig: preview.source.rig, baseline: restored.pose, savedTargets: record.ikTargets,
                enabled: restored.controller.enableIK, activeGroups: restored.controller.activeIK, characterRoot: characterRoot)
            pose = solved.pose; guides = solved.guides; solver = rebuilt
        }
        var simulation: SourceStudioDynamics?
        if let dynamicsBindings = shapeDynamicsBindings {
            simulation = try SourceStudioDynamics(rig: preview.source.rig, initializationPose: shapeBaseline, bindings: dynamicsBindings)
        }
        baseline = shapeBaseline
        controller = restored.controller
        self.pose = pose
        ikGuides = guides
        ikSolver = solver
        clearDynamicsStep()
        dynamics = simulation
        sourceFaceValues = face
        sourceBodyValues = body
        // The look runtimes and the animation clock carry the replaced
        // baseline's geometry; restart them the way a scene reload does. Init
        // reported every record-derived restored/solver diagnostic once, so a
        // per-edit rebuild never appends them again.
        animationPlayback.reset()
        hasSteppedNeckLook = false
        resetNeckLook(); resetEyeLook()
    }

    public func editedPose(fkRotations: [Int: Float3] = [:], faceValues: [Float]? = nil, bodyValues: [Float]? = nil, ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil,
                           animationElapsed: Float = 0) throws -> RigPose {
        try setShapeValues(face: faceValues, body: bodyValues)
        let state = animationState ?? SourceStudioAnimationState(record: record)
        if let cache = evaluatedCache, cache.state == state, cache.elapsed == animationElapsed, cache.fk == fkRotations, cache.ik == ikTargets, cache.kinematics == kinematics { return cache.pose }
        try SourceStudioIKEditing.validate(ikTargets); try kinematics?.validate()
        var result: RigPose
        if let animation = try resolvedAnimation(state, required: animationState != nil) {
            result = try animation.pose(state: state, elapsed: animationElapsed, height: effectiveAnimationHeight, rig: preview.source.rig, baseline: baseline, playback: &animationPlayback)
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
        let preOverride = result
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
        } else if let runtime = neckLookRuntime, let live = liveNeckLook {
            // The TARGET/AWAY gaze runtime is stepped once per Studio tick by
            // updateNeckLook; this only writes its newest local rotations,
            // with the same FK ownership rule and the same one-basis-conversion
            // write as applied(pose:).
            let lookType = live.settings.lookTypes[live.pattern]
            if effective.enableFK, effective.activeFK.count > 1, effective.activeFK[1] {
                if reportedNeckLookFK.insert(lookType).inserted {
                    diagnostics.append("Neck look override skipped: FK owns the neck.")
                }
            } else if let rotations = runtime.lastLocalRotations {
                do {
                    for (bone, name) in live.settings.boneNames.enumerated() {
                        let node = try preview.source.rig.uniqueNode(named: name)
                        let matrix = result.localMatrices[node]
                        let x = Float3(matrix[0].x, matrix[0].y, matrix[0].z)
                        let y = Float3(matrix[1].x, matrix[1].y, matrix[1].z)
                        let z = Float3(matrix[2].x, matrix[2].y, matrix[2].z)
                        let scale = Float3(simd_length(x), simd_length(y), simd_length(z))
                        guard (0..<3).allSatisfy({ scale[$0].isFinite && scale[$0] > 1e-8 }) else {
                            throw RigError.invalid("Neck look override cannot read a singular local scale for '\(name)'.")
                        }
                        result.localMatrices[node] = Transform.trs(Float3(matrix[3].x, matrix[3].y, matrix[3].z),
                            UnityCoordinates.rotation(rotations[bone]), scale)
                    }
                } catch {
                    // A malformed saved pair (degenerate bones are rare, but a
                    // broken rig is possible) must not kill the whole pose:
                    // roll back any partial write, keep the animated neck,
                    // report once and stop retrying.
                    result = preOverride
                    runtime.lastLocalRotations = nil
                    if reportedNeckLookFK.insert(lookType).inserted {
                        diagnostics.append("Neck look override skipped: \(error); the animated pose is kept.")
                    }
                }
            }
        }
        if var simulation = dynamics, dynamicsStep?.elapsed == animationElapsed {
            result = try simulation.evaluate(time: animationElapsed, rig: preview.source.rig, upstream: result,
                enableFK: effective.enableFK, activeFK: effective.activeFK,
                deltaTime: dynamicsStep?.elapsed == animationElapsed ? dynamicsStep?.delta : nil)
            dynamics = simulation
        }
        evaluatedCache = (state, animationElapsed, fkRotations, ikTargets, kinematics, result, preOverride, guides)
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

    public func editedIKGuides(fkRotations: [Int: Float3] = [:], faceValues: [Float]? = nil, bodyValues: [Float]? = nil, ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil,
                               animationState: SourceStudioAnimationState? = nil, animationElapsed: Float = 0) throws -> [SourceStudioIK.Guide] {
        _ = try editedPose(fkRotations: fkRotations, faceValues: faceValues, bodyValues: bodyValues, ikTargets: ikTargets, kinematics: kinematics, animationState: animationState, animationElapsed: animationElapsed)
        return evaluatedCache?.guides ?? []
    }

    public func ikCharacterFrame(pose: RigPose) throws -> (matrix: float4x4, rotation: simd_quatf) {
        (try preview.source.rig.evaluate(pose).worldMatrices[characterRoot],
         try SourceStudioGuide.rotation(node: characterRoot, rig: preview.source.rig, pose: pose))
    }

    public func savedAnimationState(animationState: SourceStudioAnimationState? = nil, animationElapsed: Float = 0) throws -> SourceStudioAnimationState {
        var state = animationState ?? SourceStudioAnimationState(record: record)
        if let animation = try resolvedAnimation(state, required: animationState != nil) {
            state.normalizedTime = try animation.clock(state: state, elapsed: animationElapsed, height: effectiveAnimationHeight, playback: &animationPlayback).normalizedTime
        }
        return state
    }

    public func resetAnimationPlayback() {
        animationPlayback.reset(); hasSteppedNeckLook = false; resetNeckLook(); resetEyeLook()
    }

    /// True when the effective neck pattern is TARGET or AWAY and the gaze
    /// runtime exists: the Studio tick then steps updateNeckLook per frame.
    public var hasLiveNeckLook: Bool { neckLookRuntime != nil }

    /// Rebuilds the TARGET/AWAY gaze runtime from the saved fixAngle, the way
    /// a scene load restores the calculator, so a seek or clock jump restarts
    /// the transition instead of carrying stale smoothing across the jump.
    public func resetNeckLook() {
        guard let live = liveNeckLook else { return }
        do { neckLookRuntime = try SourceStudioNeckLookRuntime(settings: live.settings, fixAngle: live.fixAngle) }
        catch { diagnostics.append("Studio neck look runtime reset failed: \(error); the animated pose is kept.") }
        hasSteppedNeckLook = false
        evaluatedCache = nil
    }

    /// True when the effective eye pattern is live: the Studio tick then steps
    /// updateEyeLook per frame. Unlike the neck the runtime Inits from the
    /// first evaluated frame, so the flag reads the resolved pattern.
    public var hasLiveEyeLook: Bool { liveEyeLook != nil }

    /// The inspector readout: the pattern's lookType with the last frame's
    /// iris-shift rates, or nil while the eyes are animated (then
    /// `eyeLookKeptReason` explains why).
    public var eyeLookRates: (lookType: SourceStudioEyeLookType, horizontal: [Double], vertical: Double)? {
        guard let live = liveEyeLook, eyeLookFailure == nil, let runtime = eyeLookRuntime else { return nil }
        return (live.settings.eyeTypeStates[live.pattern].lookType, runtime.angleHRates, runtime.angleVRate)
    }
    /// Why the eye gaze is not running for an imported source character with a
    /// resolved-but-refused pattern; nil while live or never configured.
    public var eyeLookKeptReason: String? {
        if let failure = eyeLookFailure { return "pattern \(liveEyeLook!.pattern) Init failed: \(failure)" }
        return eyeLookNote
    }

    /// Drops the eye runtime so the next updateEyeLook Inits it from that
    /// frame's pose, the way a scene reload re-runs EyeLookCalc's Init; a seek
    /// therefore restarts the convergence instead of carrying stale smoothing.
    public func resetEyeLook() { eyeLookRuntime = nil; eyeLookFailure = nil }

    /// The Studio tick step for the TARGET/AWAY gaze: runs one LateUpdate of
    /// NeckLookCalcVer2 — UpdateCall's write-back of the previous frame's
    /// fixAngle for TARGET, then the limit check, angleToTarget and AWAY
    /// adjustment read on the FK/IK-solved pose before any look override
    /// wrote to it — and stores the frame's local rotations for editedPose to
    /// write onto the rendered pose. `cameraModelPosition` is the Studio
    /// camera in the same rig model space the geometry is evaluated in, in
    /// Unity basis (the caller maps its world position with inverse(object
    /// world) and UnityCoordinates.position; the Z reflection commutes with
    /// the rigid part of that mapping, so the solver sees the original
    /// world-space vectors mirrored into its own basis). The edit arguments
    /// mirror editedPose so the gaze reads the pose the renderer actually
    /// shows. Returns whether the stored gaze changed, which is what tells a
    /// caller to re-render; a zero deltaTime only runs the type-change
    /// transition, as NeckUpdateCalc early-outs then, and the tiny
    /// firstFrameDelta replaces the delta on the first step at elapsed 0,
    /// mirroring applied(pose:) for FIX/FORWARD.
    @discardableResult public func updateNeckLook(deltaTime: Float, cameraModelPosition: Float3,
        fkRotations: [Int: Float3] = [:], faceValues: [Float]? = nil, bodyValues: [Float]? = nil, ikTargets: [Int32: SourceStudioIKEdit] = [:],
        kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil,
        animationElapsed: Float = 0) throws -> Bool {
        guard let runtime = neckLookRuntime, let live = liveNeckLook else { return false }
        guard deltaTime.isFinite, deltaTime >= 0, deltaTime <= 10,
              (0..<3).allSatisfy({ cameraModelPosition[$0].isFinite }) else {
            throw RigError.invalid("Neck look gaze needs a finite deltaTime up to 10 s and a finite camera position.")
        }
        let lookType = live.settings.lookTypes[live.pattern]
        guard lookType == .target || lookType == .away else { return false }
        let frameDelta = !hasSteppedNeckLook && animationElapsed == 0 ? SourceStudioNeckLook.firstFrameDelta : deltaTime
        let pose = try editedPose(fkRotations: fkRotations, faceValues: faceValues, bodyValues: bodyValues, ikTargets: ikTargets, kinematics: kinematics,
            animationState: animationState, animationElapsed: animationElapsed)
        let rotationsBefore = runtime.lastLocalRotations
        let fixBefore = runtime.fixAngle
        // The solver reads the Animator's pose, not its own last write (Unity's
        // animation update overwrites the bone each frame before LateUpdate),
        // so the geometry comes from the cached pre-override pose.
        var geometryPose = evaluatedCache?.preOverride ?? pose
        if lookType == .target {
            // UpdateCall: the TARGET calculator puts each bone's previous
            // fixAngle back as its localRotation before the head rotation is
            // read, which is what reconciles the capture's same-frame head
            // rotation (within 0.082 deg). RigPose is a value type, so this
            // write stays out of the cache entry.
            for (bone, name) in live.settings.boneNames.enumerated() {
                let node = try preview.source.rig.uniqueNode(named: name)
                let matrix = geometryPose.localMatrices[node]
                geometryPose.localMatrices[node] = Transform.trs(matrix.translation,
                    UnityCoordinates.rotation(runtime.fixAngle[bone]), matrix.scaleFactors)
            }
        }
        let world = try preview.source.rig.evaluate(geometryPose).worldMatrices
        func converted(_ node: Int) -> (position: SIMD3<Double>, rotation: simd_quatd) {
            let matrix = UnityCoordinates.matrix(world[node])
            let q = matrix.rotationQuaternion
            return (SIMD3(Double(matrix.translation.x), Double(matrix.translation.y), Double(matrix.translation.z)),
                    simd_quatd(ix: Double(q.imag.x), iy: Double(q.imag.y), iz: Double(q.imag.z), r: Double(q.real)))
        }
        let aim = converted(try preview.source.rig.uniqueNode(named: "aim"))
        let neckRef = converted(try preview.source.rig.uniqueNode(named: "NeckRef"))
        let head = converted(try preview.source.rig.uniqueNode(
            named: live.settings.boneNames.last ?? "cf_j_head"))
        let target = SIMD3(Double(cameraModelPosition.x), Double(cameraModelPosition.y), Double(cameraModelPosition.z))
        try runtime.update(deltaTime: frameDelta, lookType: lookType, pattern: live.pattern,
            settings: live.settings,
            geometry: SourceStudioNeckLookGeometry(aimPosition: aim.position, aimRotation: aim.rotation,
                neckRefPosition: neckRef.position, neckRefRotation: neckRef.rotation,
                headRotation: head.rotation, target: target))
        hasSteppedNeckLook = true
        evaluatedCache = nil
        return runtime.lastLocalRotations != rotationsBefore || runtime.fixAngle != fixBefore
    }

    /// The Studio tick step for the eye gaze: one EyeLookCalc frame over the
    /// FK/IK-solved pose before any look override wrote to it, kept fully
    /// independent of the neck runtime. The settings' rootNode name is
    /// `p_cf_head_bone`, which is not a merged-rig node; the capture reports
    /// it sharing cf_j_head's world transform in every frame, so that bone is
    /// the root here, and trfCenter / the eye parents are cf_J_Eye_tz /
    /// cf_J_Eye_tx_L+R. The EyeTargets sit on their parent pivots (the Maker
    /// skeleton authors them at translation 0), so the parents' world
    /// positions are the eye positions, and their origRotation is the identity
    /// the capture recorded. This slice reads the rates out of the frame and
    /// writes no bones; the iris writeback is the next slice. Returns whether
    /// the frame's iris-shift rates changed, the signal a caller will use to
    /// re-render once the iris offset reads them.
    @discardableResult public func updateEyeLook(deltaTime: Float, cameraModelPosition: Float3,
        fkRotations: [Int: Float3] = [:], faceValues: [Float]? = nil, bodyValues: [Float]? = nil, ikTargets: [Int32: SourceStudioIKEdit] = [:],
        kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil,
        animationElapsed: Float = 0) throws -> Bool {
        guard let live = liveEyeLook, eyeLookFailure == nil else { return false }
        guard deltaTime.isFinite, deltaTime >= 0, deltaTime <= 10,
              (0..<3).allSatisfy({ cameraModelPosition[$0].isFinite }) else {
            throw RigError.invalid("Eye look gaze needs a finite deltaTime up to 10 s and a finite camera position.")
        }
        let pose = try editedPose(fkRotations: fkRotations, faceValues: faceValues, bodyValues: bodyValues, ikTargets: ikTargets, kinematics: kinematics,
            animationState: animationState, animationElapsed: animationElapsed)
        // Same pre-override read as the neck: EyeLookCalc runs after
        // Animator/FK/IK and before its own writeback, and the eye runtime
        // Inits from this frame's head and eye-parent rotations.
        let geometryPose = evaluatedCache?.preOverride ?? pose
        let world = try preview.source.rig.evaluate(geometryPose).worldMatrices
        func node(_ name: String) throws -> SourceStudioEyeLookGeometry.Node {
            let matrix = UnityCoordinates.matrix(world[try preview.source.rig.uniqueNode(named: name)])
            let q = matrix.rotationQuaternion
            let scale = matrix.scaleFactors
            return .init(position: SIMD3(Double(matrix.translation.x), Double(matrix.translation.y), Double(matrix.translation.z)),
                         rotation: simd_quatd(ix: Double(q.imag.x), iy: Double(q.imag.y), iz: Double(q.imag.z), r: Double(q.real)),
                         lossyScale: SIMD3(Double(scale.x), Double(scale.y), Double(scale.z)))
        }
        func position(_ name: String) throws -> SIMD3<Double> { try node(name).position }
        let root = try node("cf_j_head")
        let center = try node(live.settings.trfCenter ?? "cf_J_Eye_tz")
        let parentNames = ["cf_J_Eye_tx_L", "cf_J_Eye_tx_R"]
        let parentPositions = try parentNames.map { try position($0) }
        let parentRotations = try parentNames.map { try node($0).rotation }
        let identityQ = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        if eyeLookRuntime == nil {
            do {
                eyeLookRuntime = try SourceStudioEyeLookRuntime(settings: live.settings,
                    rootRotation: root.rotation,
                    eyeParents: parentRotations.map { .init(rotation: $0, localRotation: identityQ) },
                    savedAngles: live.savedAngles)
            } catch {
                // Retire the pattern until resetEyeLook: the inspector readout
                // reports the kept animated eyes instead of knocking per frame.
                eyeLookFailure = "\(error)"
                diagnostics.append("Studio eye look runtime unavailable: \(error); the animated eyes are kept.")
                return false
            }
        }
        guard let runtime = eyeLookRuntime else { return false }
        let reference = runtime.reference
        let target = SIMD3(Double(cameraModelPosition.x), Double(cameraModelPosition.y), Double(cameraModelPosition.z))
        let ratesBefore = (runtime.angleHRates, runtime.angleVRate)
        try runtime.update(deltaTime: Double(deltaTime), target: target,
            geometry: SourceStudioEyeLookGeometry(rootNode: root, trfCenter: center,
                eyes: [
                    .init(worldPosition: parentPositions[0], origRotation: identityQ,
                          referenceLookDir: reference[0].lookDir, referenceUpDir: reference[0].upDir,
                          parentRotation: parentRotations[0]),
                    .init(worldPosition: parentPositions[1], origRotation: identityQ,
                          referenceLookDir: reference[1].lookDir, referenceUpDir: reference[1].upDir,
                          parentRotation: parentRotations[1]),
                ]),
            pattern: live.pattern)
        return runtime.angleHRates != ratesBefore.0 || runtime.angleVRate != ratesBefore.1
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

    public func attachmentMatrix(pointID: Int32, fkRotations: [Int: Float3] = [:], faceValues: [Float]? = nil, bodyValues: [Float]? = nil, ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil, animationElapsed: Float = 0) throws -> float4x4 {
        guard let attachments else { throw RigError.invalid("Source Studio attachment catalog is missing.") }
        return try attachments.matrix(pointID: pointID, rig: preview.source.rig, pose: editedPose(fkRotations: fkRotations, faceValues: faceValues, bodyValues: bodyValues, ikTargets: ikTargets, kinematics: kinematics, animationState: animationState, animationElapsed: animationElapsed))
    }

    public func attachmentRotation(pointID: Int32, fkRotations: [Int: Float3] = [:], faceValues: [Float]? = nil, bodyValues: [Float]? = nil, ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil, animationElapsed: Float = 0) throws -> simd_quatf {
        guard let point = attachments?.points.first(where: { $0.id == pointID }) else { throw RigError.invalid("Source Studio attachment is unavailable.") }
        return try SourceStudioGuide.rotation(node: preview.source.rig.uniqueNode(named: point.nodeName),
            rig: preview.source.rig, pose: editedPose(fkRotations: fkRotations, faceValues: faceValues, bodyValues: bodyValues, ikTargets: ikTargets, kinematics: kinematics, animationState: animationState, animationElapsed: animationElapsed))
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
