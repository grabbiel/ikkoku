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
    /// The assembled preview. setColorEdits swaps this instance exactly like the
    /// Maker's replaceSourceAppearance: geometry, contract, expression contract
    /// and body options stay identical and no pose input changes.
    public private(set) var preview: SourceRigPreview
    public private(set) var pose: RigPose
    private var latePoseCorrection: SourceBodyLateCorrection
    /// Import-time messages plus one-shot runtime notices (for example the FK
    /// neck conflict reported by editedPose); never grows per frame.
    public private(set) var diagnostics: [String]
    public let record: KoikatsuCharacterRecord
    public let selections: [SourceMakerLibrary.Selection]
    /// The outfit this preview assembled: the `coordinate` init argument when
    /// one was given, the card's saved Status.coordinateType otherwise.
    public let coordinate: Int
    /// The embedded card's saved Status.coordinateType — the import baseline.
    /// Export writes an outfit edit back only when it differs from this.
    public let savedCoordinate: Int
    /// How many outfits the embedded card saves (ChaFile.coordinate entries;
    /// seven on an original card, 0 when the Coordinate list is unreadable).
    public let outfitCount: Int
    /// ChaFileDefine.CoordinateType order, the seven CharaStudio outfit buttons.
    public static let outfitNames = ["School uniform", "After school", "Gym", "Swimsuit", "Club", "Casual", "Pajamas"]
    /// ST-C03 wear: the embedded card's saved Status.clothesState, shoesType
    /// and showAccessory as imported (the ChaFileStatus.MemberInit default
    /// for a field the card does not save).
    public let savedWear: SourceCharacterCard.StatusWear
    /// The recovered ChaControl clothes-state rules of the assembled
    /// outfit's garments (dictStateType and the linked-garment flags).
    public let wearRules: SourceStudioWear
    /// Which assembled renderers belong to which garment, accessory and hair.
    public let wearLayout: SourceStudioWearLayout
    /// The clothes state a scene load leaves for the saved bytes: Reload's
    /// UpdateClothesStateAll, then AddObjectAssist.UpdateState's
    /// SetClothesState loop.
    public let loadedClothesState: [UInt8]
    /// Accessory slots this outfit saves (type 121...130); CharaStudio's
    /// accessory toggles are interactable only for loaded accessories.
    public let savedAccessorySlots: [Int]
    /// The rendered clothes state: `loadedClothesState` until `setWear`.
    public private(set) var clothesState: [UInt8]
    /// The rendered accessory flags: the saved flags until `setWear`.
    public private(set) var showAccessory: [Bool]
    /// The rendered ChaFileStatus.shoesType (0 indoor, 1 outdoor): the saved
    /// value until `setWear`.
    public private(set) var shoesType: Int
    /// The renderers the current wear hides, and its fallback report.
    public private(set) var wearEvaluation: SourceStudioWearLayout.Evaluation
    private let hideHairSlots: Set<Int>
    /// The expression controller inputs the current face state renders
    /// (`SourceStudioExpressionControls.inputs`); the blink clock is applied
    /// per frame by `effectiveExpressionInputs`.
    public private(set) var expressionInputs: SourceExpressionInputs?
    /// The current ChaFileStatus.eyesBlink: the saved flag, which the Studio
    /// card loader applies on load, until a State-panel edit changes it.
    public var eyesBlink: Bool { expressionState.blink }
    /// ST-C04: the face state the scene load leaves (card Status fields, the
    /// record's mouthOpen/lipSync and the look patterns the preview resolves),
    /// the import baseline export diffs against.
    public let savedExpression: SourceStudioExpressionState
    /// The rendered face state: `savedExpression` until setExpressionState.
    public private(set) var expressionState: SourceStudioExpressionState
    /// The State panel's option lists for this assembly.
    public let expressionControls: SourceStudioExpressionControls
    /// What the current face state saves but does not draw, plus the look
    /// resolution of an edited look pattern; replaced per edit, never grown.
    public private(set) var expressionDiagnostics: [String]
    /// Contract defaults with the card's eyebrow/mouth OpenMax: the inputs
    /// every face state is mapped onto.
    private let expressionBase: SourceExpressionInputs
    /// The saved look-at guide (OICharInfo.lookAtTarget changeAmount.pos,
    /// Unity basis). OCIChar.ChangeLookEyesPtn(4) points the eye controller
    /// at this guide instead of the main camera.
    public let lookAtGuidePosition: Float3
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
    /// The card's saved draft colors keyed by draft color ID — the import
    /// baseline. Export writes back only edited colors that differ from these.
    public let savedColors: [String: Float4]
    /// The draft's supported colors (ID, label and saved rgba) in card order;
    /// empty when the card's appearance records are unavailable.
    public let draftColors: [SourceCardAppearance.Color]
    /// The draft color IDs whose card colors actually bound on this assembly;
    /// color editing is unsupported while this is empty.
    public private(set) var appliedColorFields: Set<String>
    /// The current edited card colors; nil keeps the card's saved colors.
    /// setColorEdits rebuilds the preview appearance once per accepted edit.
    public private(set) var sourceColorEdits: [String: Float4]?
    /// The latest color rebuild's appearance diagnostics; replaced, never
    /// accumulated, and nil while the card's saved colors are in effect.
    public private(set) var colorEditDiagnostics: [String]?
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
    private var dynamicsActiveClothes: UInt16 = 0x1ff
    private var dynamics: SourceStudioDynamics?
    private var dynamicsStep: (elapsed: Float, delta: Float)?
    /// Resolved FIX/FORWARD neck look override: the prefab settings, the saved
    /// fixAngle quaternions and the pattern's lookType. Nil when the look
    /// settings are not configured or the pattern resolves to a kept pose.
    private var neckLook: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf], lookType: SourceStudioNeckLookType)?
    /// The prefab settings and saved fixAngle when the effective pattern is
    /// TARGET or AWAY; the live runtime steps from them every Studio tick.
    private var liveNeckLook: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf], pattern: Int)?
    /// The look settings and saved neck bytes every neck pattern resolves
    /// from; nil when the settings are not configured or unreadable.
    private let neckLookSource: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf])?
    /// The look settings' eyes block and the saved angles every eye pattern
    /// resolves from; nil when the settings are not configured or unreadable.
    private let eyeLookSource: (settings: SourceStudioEyeLookSettings, savedAngles: (horizontal: [Double], vertical: [Double])?)?
    /// The resolution notes of an edited look pattern (empty for the saved
    /// pattern, whose notes are part of the import diagnostics).
    private var neckLookNotes: [String] = [], eyeLookNotes: [String] = []
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
    private var liveEyeLook: (settings: SourceStudioEyeLookSettings, pattern: Int,
                              savedAngles: (horizontal: [Double], vertical: [Double])?)?
    /// Why the eyes are not live, for the inspector's kept-pose readout; nil
    /// while the gaze runs or when the character never had an eye pattern.
    private var eyeLookNote: String?
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
    /// Eye-tilt _rotation per eyeLR (0 = L, 1 = R), in turns: ChaControl's
    /// ChangeSettingEyeTilt lerps card face shape value 33 from +0.02 (L) and
    /// -0.02 (R), so R is exactly -L; toon_eye_lod0 multiplies it by 2*pi
    /// (asm L61), so the value is stored unnormalized.
    private var irisRotations: [Double]
    public var dynamicsComponentCount: Int { dynamics?.bindings.count ?? 0 }
    /// preOverride is the FK/IK-solved pose before the neck look override
    /// wrote anything: the pose the TARGET/AWAY gaze solver reads its Transforms
    /// from, the way the original LateUpdate runs NeckUpdateCalc after
    /// Animator/FK/IK and before its own rotation write.
    fileprivate typealias EvaluatedPose = (state: SourceStudioAnimationState, required: Bool, elapsed: Float, fk: [Int: Float3], ik: [Int32: SourceStudioIKEdit], kinematics: SourceStudioKinematicState?, pose: RigPose, preOverride: RigPose, guides: [SourceStudioIK.Guide])
    private var evaluatedCache: EvaluatedPose?
    /// The animated, FK/IK-solved pose (`preOverride`) with the kinematic
    /// state and guides it was solved with, for the same key as
    /// `evaluatedCache` plus whether the animation was required. A Studio tick
    /// asks for one elapsed time several times: the neck and eye gaze sample
    /// it, then `setDynamicsStep` and `updateNeckLook` drop `evaluatedCache`
    /// so the rendered pose gets that tick's neck rotations and hair
    /// integration. Neither changes this stage, which depends only on the key,
    /// the shape baseline and the solver (`setShapeValues` and the other
    /// resets clear it), so it is solved once per tick (R7). The animation
    /// clock returns the same time for a repeated elapsed value, and every
    /// other step is a pure function of its inputs.
    fileprivate typealias SolvedPose = (state: SourceStudioAnimationState, required: Bool, elapsed: Float, fk: [Int: Float3], ik: [Int32: SourceStudioIKEdit], kinematics: SourceStudioKinematicState?, pose: RigPose, effective: SourceStudioKinematicState, guides: [SourceStudioIK.Guide])
    private var solvedCache: SolvedPose?
    /// The bound Studio pose (`KoikatsuCharacterRecord.bindPose`) of the last
    /// solve, with what it was bound from: the rig, the effective kinematic
    /// state and the FK overrides. The record, catalog and roots are fixed
    /// for a preview. The overrides are compared bit for bit, since a signed
    /// zero angle can reach the matrices (R7 phase 2, item 3, C3).
    private var poseBinding: (rig: RigDefinition.Identity, kinematics: SourceStudioKinematicState, fk: [Int: Float3],
                              binding: KoikatsuCharacterRecord.PoseBinding)?
    /// Checkpoints rewind dynamics/animation, not edits or gaze. Revisions
    /// avoid comparing rig-sized state when deciding whether their cached
    /// evaluated pose and shape-bound simulation are still compatible.
    private var shapeRevision: UInt64 = 0
    private var neckPoseRevision: UInt64 = 0
    /// The import-time shape/binding inputs setShapeValues replays when the
    /// edited arrays replace the card's saved shape values.
    private let shapeBoneModifiers: SourceBoneModifiers?
    private let shapeIKBindings: SourceStudioIK.Bindings?
    private let shapeDynamicsBindings: [SourceStudioDynamics.Binding]?
    /// The import-time appearance inputs setColorEdits replays: a fresh draft
    /// off the same card, the same assembly preparation and the same converted
    /// appearance/bindings documents, so a rebuild matches the import exactly.
    private let appearanceCard: SourceCharacterCard
    private let appearancePrepared: SourceMakerLibrary.Prepared?
    private let appearanceRigURL: URL
    private let appearanceDirectory: URL
    private let appearanceBindingsURL: URL
    public struct DynamicsCheckpoint {
        fileprivate let owner: ObjectIdentifier
        fileprivate let shapeRevision: UInt64
        fileprivate let neckPoseRevision: UInt64
        fileprivate let activeClothes: UInt16
        fileprivate let simulation: SourceStudioDynamics?
        fileprivate let step: (elapsed: Float, delta: Float)?
        fileprivate let evaluated: EvaluatedPose?
        fileprivate let animationPlayback: SourceStudioAnimation.Playback
    }
    public func captureDynamicsCheckpoint() -> DynamicsCheckpoint {
        .init(owner: ObjectIdentifier(self), shapeRevision: shapeRevision, neckPoseRevision: neckPoseRevision,
            activeClothes: dynamicsActiveClothes, simulation: dynamics, step: dynamicsStep, evaluated: evaluatedCache, animationPlayback: animationPlayback)
    }
    public func restoreDynamicsCheckpoint(_ checkpoint: DynamicsCheckpoint) throws {
        guard checkpoint.owner == ObjectIdentifier(self) else { throw RigError.invalid("Dynamics checkpoint belongs to another character instance.") }
        // A shape edit rebuilt the solver and simulation's rest geometry; an
        // earlier simulation cannot be installed over it. Reject atomically.
        guard checkpoint.shapeRevision == shapeRevision else { throw RigError.invalid("Dynamics checkpoint predates the current character shape.") }
        dynamics = checkpoint.simulation; dynamicsStep = checkpoint.step
        evaluatedCache = checkpoint.activeClothes == dynamicsActiveClothes && checkpoint.neckPoseRevision == neckPoseRevision
            ? checkpoint.evaluated : nil
        animationPlayback = checkpoint.animationPlayback; solvedCache = nil
    }
    public func clearDynamicsStep() { dynamicsStep = nil; evaluatedCache = nil; solvedCache = nil; dynamics?.resetHistory() }

    /// Only for a synchronous candidate's attachment reads. Unlike a dynamics
    /// checkpoint this retains shape/solve inputs and gaze references too, so
    /// rejecting installation restores the existing instance without rebuilding
    /// geometry, allocating resources, resetting clocks or losing warm history.
    public struct AttachmentReadCheckpoint {
        fileprivate let owner: ObjectIdentifier
        fileprivate let shapeRevision: UInt64, neckPoseRevision: UInt64
        fileprivate let baseline: RigPose, pose: RigPose
        fileprivate let latePoseCorrection: SourceBodyLateCorrection
        fileprivate let controller: SourceStudioPose
        fileprivate let ikGuides: [SourceStudioIK.Guide], ikSolver: SourceStudioIK?
        fileprivate let face: [Float]?, body: [Float]?, irisRotations: [Double]
        fileprivate let dynamics: SourceStudioDynamics?, dynamicsStep: (elapsed: Float, delta: Float)?
        fileprivate let evaluated: EvaluatedPose?, solved: SolvedPose?
        fileprivate let poseBinding: (rig: RigDefinition.Identity, kinematics: SourceStudioKinematicState, fk: [Int: Float3], binding: KoikatsuCharacterRecord.PoseBinding)?
        fileprivate let animationCache: [String: SourceStudioAnimation], animationPlayback: SourceStudioAnimation.Playback
        fileprivate let neckRuntime: SourceStudioNeckLookRuntime?, neckRotations: [simd_quatf]?
        fileprivate let hasSteppedNeckLook: Bool, eyeRuntime: SourceStudioEyeLookRuntime?, eyeFailure: String?
        fileprivate let reportedNeckLookFK: Set<SourceStudioNeckLookType>, diagnostics: [String]
    }

    public func captureAttachmentReadCheckpoint() -> AttachmentReadCheckpoint {
        .init(owner: ObjectIdentifier(self), shapeRevision: shapeRevision, neckPoseRevision: neckPoseRevision,
            baseline: baseline, pose: pose, latePoseCorrection: latePoseCorrection, controller: controller,
            ikGuides: ikGuides, ikSolver: ikSolver, face: sourceFaceValues, body: sourceBodyValues, irisRotations: irisRotations,
            dynamics: dynamics, dynamicsStep: dynamicsStep, evaluated: evaluatedCache, solved: solvedCache, poseBinding: poseBinding,
            animationCache: animationCache, animationPlayback: animationPlayback, neckRuntime: neckLookRuntime,
            neckRotations: neckLookRuntime?.lastLocalRotations, hasSteppedNeckLook: hasSteppedNeckLook,
            eyeRuntime: eyeLookRuntime, eyeFailure: eyeLookFailure, reportedNeckLookFK: reportedNeckLookFK, diagnostics: diagnostics)
    }

    public func restoreAttachmentReadCheckpoint(_ checkpoint: AttachmentReadCheckpoint) {
        precondition(checkpoint.owner == ObjectIdentifier(self), "Attachment checkpoint belongs to another character instance.")
        shapeRevision = checkpoint.shapeRevision; neckPoseRevision = checkpoint.neckPoseRevision
        baseline = checkpoint.baseline; pose = checkpoint.pose; latePoseCorrection = checkpoint.latePoseCorrection
        controller = checkpoint.controller; ikGuides = checkpoint.ikGuides; ikSolver = checkpoint.ikSolver
        sourceFaceValues = checkpoint.face; sourceBodyValues = checkpoint.body; irisRotations = checkpoint.irisRotations
        dynamics = checkpoint.dynamics; dynamicsStep = checkpoint.dynamicsStep
        evaluatedCache = checkpoint.evaluated; solvedCache = checkpoint.solved; poseBinding = checkpoint.poseBinding
        animationCache = checkpoint.animationCache; animationPlayback = checkpoint.animationPlayback
        // editedPose may clear this one property on the existing runtime after a
        // malformed neck write. Shape resets replace the runtime instead; keep
        // its original reference and value, without cloning an untouched solver.
        checkpoint.neckRuntime?.lastLocalRotations = checkpoint.neckRotations
        neckLookRuntime = checkpoint.neckRuntime; hasSteppedNeckLook = checkpoint.hasSteppedNeckLook
        eyeLookRuntime = checkpoint.eyeRuntime; eyeLookFailure = checkpoint.eyeFailure
        reportedNeckLookFK = checkpoint.reportedNeckLookFK; diagnostics = checkpoint.diagnostics
    }

    /// `coordinate` selects a saved outfit other than the card's
    /// Status.coordinateType (ST-C03): CharaStudio's OCIChar.SetCoordinateInfo
    /// reloads the clothes from chaFile.coordinate[type], so the whole
    /// assembly — converted clothes/accessories, card materials, shape
    /// baseline, IK and dynamics bindings — is built for that outfit exactly
    /// as an import of a card saved with it. nil keeps the saved outfit; an
    /// index outside 0...6 or one the card does not save is rejected.
    public init(reference: SourceStudioCharacterReference, resources: ResourceStore, coordinate selectedCoordinate: Int? = nil,
                appearanceTransaction: SourceAppearanceLoadTransaction? = nil) throws {
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
        let savedCoordinate = status["coordinateType"]?.integerValue ?? 0
        guard (0..<7).contains(savedCoordinate) else { throw RigError.invalid("Unsupported saved Studio outfit index.") }
        let outfitCount = (try? card.coordinateCount()) ?? 0
        if let selectedCoordinate {
            guard (0..<7).contains(selectedCoordinate) else { throw RigError.invalid("Studio outfit index must be in 0...6.") }
            guard selectedCoordinate < outfitCount else { throw RigError.invalid("This card saves no outfit \(selectedCoordinate).") }
        }
        let coordinate = selectedCoordinate ?? savedCoordinate
        self.coordinate = coordinate
        self.savedCoordinate = savedCoordinate
        self.outfitCount = outfitCount
        let (eyesBlink, blinkDiagnostic) = SourceStudioBlink.decode(status)
        // ST-C04: the saved face-state Status fields, read per field so one
        // unreadable token keeps its MemberInit default and is reported.
        var (savedFace, faceDiagnostics) = SourceStudioExpressionState.savedFace(status: status)
        savedFace.eyesBlink = eyesBlink
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
        let prepared = try library?.prepare(card: card, coordinate: coordinate, baseURL: rigURL, wear: true)
        selections = prepared?.selections ?? []
        let source = try prepared?.source ?? SourceRig.loadModel(url: rigURL)
        // ST-C03: the saved wear, the outfit's catalog rows and the assembled
        // garment structure give the clothes state the load leaves and the
        // renderers UpdateVisible switches off.
        var wearMessages: [String] = []
        var savedWear = SourceCharacterCard.StatusWear.memberInit
        do { savedWear = try SourceCharacterCard.StatusWear(status: status) }
        catch { wearMessages.append("Saved clothes state or accessory visibility is unreadable (\(error)); the ChaFileStatus defaults (all on, every accessory shown) render instead.") }
        let wearCatalog: SourceMakerLibrary.WearCatalog
        do {
            guard let library else { throw RigError.invalid("no converted Maker library is selected") }
            wearCatalog = try library.wearCatalog(card: card, coordinate: coordinate)
        } catch {
            let parts = (try? card.recordFields(.clothes(coordinate: coordinate)))?["parts"]?.arrayValue ?? []
            let ids = (0..<9).map { slot in parts.indices.contains(slot) ? ((try? parts[slot].stringKeyedMap())?["id"]?.integerValue ?? 0) : 0 }
            wearCatalog = .init(clothes: Array(repeating: .unknown("no catalog"), count: 9), clothesIDs: ids,
                            clothesModded: Array(repeating: false, count: 9), accessories: [:])
            wearMessages.append("Clothes catalog rows are unavailable (\(error)); every clothes state is selectable and the saved bytes are kept.")
        }
        let clothingSlots = prepared?.clothingSlots
            ?? selectedManifest.clothes.enumerated().map { $0.element.slot ?? ([0, 1, 8].indices.contains($0.offset) ? [0, 1, 8][$0.offset] : -1) }
        let wearLayout = SourceStudioWearLayout(source: source, clothingSlots: clothingSlots, indoorShoes: prepared?.indoorShoes ?? .unconverted)
        let wearRules = SourceStudioWear(catalog: wearCatalog, layout: wearLayout)
        let loadedClothesState = wearRules.loaded(savedWear.clothesState)
        var hideHairSlots = Set<Int>(), unknownHair: [Int] = []
        for (slot, row) in wearCatalog.accessories {
            switch row {
            case .row(let fields): if (Int(fields["HideHair"] ?? "0") ?? -1) != 0 { hideHairSlots.insert(slot) } // GetInfoInt != 0
            case .none: break
            case .unknown: unknownHair.append(slot)
            }
        }
        self.savedWear = savedWear
        self.wearRules = wearRules
        self.wearLayout = wearLayout
        self.loadedClothesState = loadedClothesState
        self.savedAccessorySlots = wearCatalog.accessories.keys.sorted()
        self.hideHairSlots = hideHairSlots
        clothesState = loadedClothesState
        shoesType = savedWear.shoesType
        dynamicsActiveClothes = (0..<9).reduce(UInt16(0)) { mask, kind in
            wearRules.visible(kind: kind, states: loadedClothesState, shoesType: savedWear.shoesType) ? mask | (1 << kind) : mask
        }
        showAccessory = savedWear.showAccessory
        let wearEvaluation = wearLayout.evaluate(rules: wearRules, states: loadedClothesState, shoesType: savedWear.shoesType,
                                                 showAccessory: savedWear.showAccessory, hideHairSlots: hideHairSlots)
        self.wearEvaluation = wearEvaluation
        func names(_ kinds: [Int]) -> String { kinds.isEmpty ? "none" : kinds.map { SourceStudioWear.kindNames[$0] }.joined(separator: ", ") }
        wearMessages.append("Saved clothes state \(savedWear.clothesState.map(String.init).joined(separator: ",")) (shoesType \(savedWear.shoesType)) loads as \(loadedClothesState.map(String.init).joined(separator: ",")); assembled garments rendered: \(names(wearEvaluation.renderedClothing)), hidden: \(names(wearLayout.clothingKinds.filter { !wearEvaluation.renderedClothing.contains($0) })).")
        let hiddenSlots = savedWear.showAccessory.indices.filter { !savedWear.showAccessory[$0] }
        if !hiddenSlots.isEmpty { wearMessages.append("Saved showAccessory hides accessory slots \(hiddenSlots.map(String.init).joined(separator: ", ")).") }
        let unknownKinds = wearRules.unknownKinds.filter { if case .unknown = wearCatalog.clothes[$0] { return true }; return [0, 1, 2, 3].contains($0) }
        if !unknownKinds.isEmpty {
            wearMessages.append("Clothes-state rules for \(names(unknownKinds)) are unknown (no converted catalog row): every state is selectable, the saved bytes are kept, and their one-piece links read false.")
        }
        if wearRules.compositeTop {
            wearMessages.append("The top is a sailor/jacket composite whose unconverted sub-parts (ChaControl.ChangeClothesTopParts) can set notBra, so the bra and shorts clothes-state rules are unknown: every state is selectable and the saved bytes are kept.")
        }
        // An outdoor-shoe stand-in for unconverted indoor shoes is one of
        // wearEvaluation.fallbacks, appended below.
        if !(0...1).contains(savedWear.shoesType), !Set(wearLayout.clothingKinds).isDisjoint(with: [7, 8]) {
            wearMessages.append("shoesType \(savedWear.shoesType) shows neither shoe; the shoe geometry stays hidden.")
        }
        for (field, standard) in [("visibleSimple", false), ("visibleHeadAlways", true), ("visibleBodyAlways", true)] {
            if case .bool(let value) = status[field], value != standard {
                wearMessages.append("Saved Status.\(field) \(value) is not applied; the preview renders with the default \(standard).")
            }
        }
        if !unknownHair.isEmpty {
            wearMessages.append("Accessory slots \(unknownHair.sorted().map(String.init).joined(separator: ", ")) have no converted catalog row; their HideHair flags are unknown and never hide the hair.")
        }
        wearMessages += wearEvaluation.fallbacks
        let contract = try SourceShapeContract.decode(Self.read(directory.appendingPathComponent("character-shape-contract.json"), maximum: 32 * 1024 * 1024))
        var appearance = try SourcePreviewAppearance.load(url: rigURL.deletingPathExtension().appendingPathExtension("appearance.json"), resources: resources, transaction: appearanceTransaction)
        var messages: [String] = []
        if let blinkDiagnostic { messages.append(blinkDiagnostic) }
        messages += faceDiagnostics
        messages += wearMessages
        if coordinate != savedCoordinate {
            messages.append("Outfit \(coordinate) (\(Self.outfitNames[coordinate])) replaces the card's saved outfit \(savedCoordinate); original-scene export writes it to Status.coordinateType.")
        }
        let draft: SourceCardAppearance?
        do { draft = try SourceCardAppearance(card: card, coordinate: coordinate) }
        catch {
            if library != nil { throw error }
            draft = nil; messages.append("Card appearance records are incomplete; reference materials retained: \(error)")
        }
        var appearanceAppliedFields: Set<String> = []
        let bindingsURL = rigURL.deletingPathExtension().appendingPathExtension("card-appearance.json")
        if let draft, FileManager.default.fileExists(atPath: bindingsURL.path) {
            var bindings = try SourceAppearanceBindings.load(url: bindingsURL)
            if let prepared { bindings = bindings.restricted(to: Set(prepared.source.parts.map { $0.mesh.name })) }
            let applied = try appearance.applying(draft, bindings: bindings, directory: directory, resources: resources)
            appearance = applied.appearance; messages += applied.diagnostics; appearanceAppliedFields.formUnion(applied.appliedFields)
        }
        if let draft, let applied = try prepared?.appearance(base: appearance, card: draft, resources: resources, modLibrary: nil, transaction: appearanceTransaction) {
            appearance = applied.appearance; messages += applied.diagnostics; appearanceAppliedFields.formUnion(applied.appliedFields)
        }
        appearanceCard = card
        appearancePrepared = prepared
        appearanceRigURL = rigURL
        appearanceDirectory = directory
        appearanceBindingsURL = bindingsURL
        if library == nil { messages.append("No converted Maker library selected; reference hair/clothes geometry retained.") }
        let expression = try SourceExpressionContract.decode(Self.read(directory.appendingPathComponent("source-expression-contract.json"), maximum: 32 * 1024 * 1024))
        var base = expression.defaults
        func rate(_ name: String, fallback: Float) throws -> Float {
            guard let value = status[name] else { return fallback }
            let number: Float
            switch value { case .float(let v): number = Float(v); case .integer(let v): number = Float(v); default: throw RigError.invalid("Invalid Studio expression rate.") }
            guard number.isFinite, (0...1).contains(number) else { throw RigError.invalid("Studio expression rate is outside 0...1.") }
            return number
        }
        // ChangeEyebrowOpenMax/ChangeMouthOpenMax run at head load and are not
        // State-panel controls, so they stay card values.
        base.eyebrowOpenMax = try rate("eyebrowOpenMax", fallback: base.eyebrowOpenMax)
        base.mouthOpenMax = try rate("mouthOpenMax", fallback: base.mouthOpenMax)
        expressionBase = base
        let controls = try SourceStudioExpressionControls(contract: expression)
        expressionControls = controls
        preview = try SourceRigPreview(source: source, contract: contract, resources: resources, appearance: appearance, expressionContract: expression, bodyOptions: options, lateCorrectionOptions: .init(),
            doubleTooth: try SourceRigPreview.savedDoubleTooth(in: card))
        let settings = try card.previewSettings(contract: contract, sex: identity.sex, headID: identity.headID, boneType: identity.boneType)
        let baseline = try preview.pose(bodyValues: settings.bodyValues, faceValues: settings.faceValues, boneModifiers: settings.boneModifiers, coordinate: coordinate)
        self.baseline = baseline
        latePoseCorrection = try preview.lateCorrection(restoring: baseline)
        savedFaceValues = settings.faceValues
        savedBodyValues = settings.bodyValues
        savedColors = Dictionary(uniqueKeysWithValues: draft?.colors.map { ($0.id, $0.rgba) } ?? [])
        draftColors = draft?.colors ?? []
        // Only colors whose material actually changed count as editable here.
        appliedColorFields = appearanceAppliedFields.intersection(Set(draftColors.map(\.id)))
        shapeBoneModifiers = settings.boneModifiers
        // ChangeSettingEyeTilt lerps face shape value 33 unclamped (Mathf.Lerp),
        // L from +0.02 toward -0.02 and R as its negation (SetEyeRot negates the
        // shared value for the R eye).
        let eyeTilt = 0.02 - 0.04 * Double(settings.faceValues[33])
        irisRotations = [eyeTilt, -eyeTilt]
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
        let lookStatus = SourceStudioLookStatus(status: status)
        var neckLookSource: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf])?
        let savedNeck = try? SourceStudioNeckLookData(bytes: record.neckData)
        let savedNeckPattern = savedNeck.map { SourceStudioLookData.effectiveNeckPattern(status: lookStatus, savedNeckPatternNumber: $0.patternNumber) }
            ?? lookStatus.neckLookPtn ?? Int32(savedFace.neckLookPtn)
        let neckTargetType = lookStatus.neckTargetType
        if let lookSettingsFile = reference.lookSettingsFile {
            do {
                let lookSettings = try SourceStudioNeckLookSettings(json: Self.read(URL(fileURLWithPath: lookSettingsFile), maximum: 4 * 1024 * 1024))
                let savedNeck = try SourceStudioNeckLookData(bytes: record.neckData)
                neckLookSource = (lookSettings, savedNeck.fixAngles)
            } catch { messages.append("Studio neck look override unavailable: \(error); the animated pose is kept.") }
        } else if let savedNeck, savedNeck.patternNumber != 0 || !savedNeck.fixAngles.isEmpty {
            messages.append("Neck look settings are not configured; the saved neck pattern \(savedNeck.patternNumber) is not applied and the animated pose is kept.")
        }
        let neck = Self.resolveNeckLook(source: neckLookSource, pattern: savedNeckPattern, targetType: neckTargetType)
        messages += neck.messages
        self.neckLookSource = neckLookSource
        self.neckLook = neck.override
        self.liveNeckLook = neck.live
        self.neckTargetType = neckTargetType
        neckLookRuntime = neck.runtime
        // The same settings document's eyes block drives the eye calculator.
        // AddObjectAssist restores LoadAngle first and ChangeLookEyesPtn last,
        // so the card eyesLookPtn wins over the prefab's eyeController.ptnNo,
        // and EyeLookCalc reads the main camera when eyesTargetType is 0 or
        // absent (the look-at guide for pattern 4). NO_LOOK is reported and
        // skipped: its fixAngle write is not recorded by the look trace, so
        // the animated eyes are kept.
        var eyeLookSource: (settings: SourceStudioEyeLookSettings, savedAngles: (horizontal: [Double], vertical: [Double])?)?
        let eyesTargetType = lookStatus.eyesTargetType
        var irisEyes: [SourceStudioEyeMaterialSettings] = []
        if let lookSettingsFile = reference.lookSettingsFile {
            do {
                let lookData = try Self.read(URL(fileURLWithPath: lookSettingsFile), maximum: 4 * 1024 * 1024)
                let eyeSettings = try SourceStudioEyeLookSettings(json: lookData)
                let savedEyes = try SourceStudioEyeLookData(bytes: record.eyesData, sceneVersion: scene.snapshot.version)
                let angles: (horizontal: [Double], vertical: [Double])?
                if let angleH = savedEyes.angleH, let angleV = savedEyes.angleV {
                    angles = (horizontal: angleH.map(Double.init), vertical: angleV.map(Double.init))
                } else { angles = nil }
                eyeLookSource = (eyeSettings, angles)
                do { irisEyes = try SourceStudioEyeMaterialSettings.document(json: lookData) }
                catch { messages.append("Studio eye material settings unavailable: \(error); the irises keep their resting offset.") }
            } catch { messages.append("Studio eye look override unavailable: \(error); the animated eyes are kept.") }
        }
        let savedEyesPattern = lookStatus.eyesLookPtn ?? eyeLookSource?.settings.eyeControllerPattern ?? Int32(savedFace.eyesLookPtn)
        let eye = Self.resolveEyeLook(source: eyeLookSource, pattern: savedEyesPattern, targetType: eyesTargetType)
        if eye.live != nil, eyeLookSource?.savedAngles == nil {
            messages.append("Scene version \(scene.snapshot.version) saves no eye angles; the calculator Inits flat instead.")
        }
        messages += eye.messages
        self.eyeLookSource = eyeLookSource
        self.liveEyeLook = eye.live
        self.eyeLookNote = eye.note
        self.eyesTargetType = eyesTargetType
        self.irisEyes = irisEyes
        lookAtGuidePosition = record.lookAtTarget.transform.position
        // ST-C04 saved face state: the load leaves these values and the
        // inputs below are exactly what a scene load renders for them.
        let saved = SourceStudioExpressionState(eyebrowPattern: savedFace.eyebrowPtn, eyesPattern: savedFace.eyesPtn,
            mouthPattern: savedFace.mouthPtn, eyesOpen: savedFace.eyesOpenMax, blink: eyesBlink,
            mouthOpen: record.mouthOpen, lipSync: record.lipSync, eyesLookPattern: Int(savedEyesPattern),
            neckLookPattern: Int(savedNeckPattern), tears: savedFace.tearsLv, cheek: savedFace.hohoAkaRate)
        savedExpression = saved
        expressionState = saved
        let inputs = controls.inputs(saved, base: base)
        _ = try expression.weights(source: source, inputs: inputs)
        expressionInputs = inputs
        expressionDiagnostics = controls.diagnostics(saved) + Self.guideNote(saved, guide: record.lookAtTarget.transform.position)
        // The ChangeSettingEye* calls run once at load off the face record's
        // six fields; a field the card does not carry keeps the whole prefab
        // snapshot (the original's decoded fields always exist, so a per-field
        // fallback is not recovered) instead of inventing a constructor default.
        var irisCardValues: SourceStudioIrisRendering.CardValues?
        if !irisEyes.isEmpty {
            let (values, missing) = SourceStudioIrisRendering.cardValues(appearance: draft, sex: identity.sex, exType: identity.exType)
            if missing.isEmpty {
                irisCardValues = values
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
        try latePoseCorrection.apply(to: &animationBaseline)
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
                let bound = try SourceStudioDynamics.bind(SourceDynamicsDocument.load(url: dynamicsURL), rig: source.rig, clothingSlots: clothingSlots)
                dynamics = try SourceStudioDynamics(rig: source.rig, initializationPose: baseline, bindings: bound.bindings)
                shapeDynamics = bound.bindings
                messages += bound.diagnostics
                messages.append("\(bound.bindings.count) source hair/clothes DynamicBone components run after animation/FK/IK in character space; unsupported variants and object-motion inertia are not restored.")
            } catch { messages.append("Source dynamics unavailable: \(error)") }
        } else { messages.append("Converted source dynamics are not configured.") }
        shapeDynamicsBindings = shapeDynamics
        let hasNativeIK = ikSolver != nil
        diagnostics = ["Converted card assets, shape, static ABMX, expression settings and saved kinematics restored. Catalog-selected animation is evaluated before FK/IK and available source hair/clothes dynamics."]
            + messages + settings.diagnostics + restored.diagnostics.filter { !$0.hasPrefix("Character appearance,") && !(hasNativeIK && $0.hasPrefix("Source IK is enabled;")) }
    }

    public func frame(camera: OrbitCamera, mainLight: MainLight, effects: SceneEffects,
                      world: float4x4, objectID: UInt32, fkRotations: [Int: Float3] = [:], faceValues: [Float]? = nil, bodyValues: [Float]? = nil, ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil,
                      animationElapsed: Float = 0) throws -> RenderFrame {
        var frame = try preview.frame(camera: camera, mainLight: mainLight, effects: effects,
            expression: effectiveExpressionInputs(), poseOverride: editedPose(fkRotations: fkRotations, faceValues: faceValues, bodyValues: bodyValues, ikTargets: ikTargets, kinematics: kinematics, animationState: animationState, animationElapsed: animationElapsed),
            hiddenParts: wearEvaluation.hiddenParts, sourceBodyAlpha: wearEvaluation.bodyAlpha)
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
            // The eye-tilt _rotation is a card value, independent of the live
            // rates, so it survives a refused _ST transform below.
            frame.items[i].material.uniforms.irisRotation = Float(irisRotations[settings.eyeLR])
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

    /// The iris transforms as the shader binding set's eye-look input
    /// (R1/CMT-04 live source shaders): the resting (0, 0) rates, or with
    /// `current` the live eye look's rates when it runs. Nil without the
    /// Studio eye material settings (the iris `_ST` then stay unresolved).
    public func shaderBindingEyeLook(current: Bool = false) throws -> SourceShaderBindingDerivation.EyeLook? {
        guard !irisEyes.isEmpty else { return nil }
        let live = current ? eyeLookRates : nil
        let rates = live.map { (horizontal: $0.horizontal, vertical: $0.vertical) }
        let rateText = live.map { "rates L \($0.horizontal.first ?? 0) R \($0.horizontal.last ?? 0) V \($0.vertical)" } ?? "resting rates (0, 0)"
        return try SourceStudioIrisRendering.bindingEyeLook(eyes: irisEyes, card: irisCardValues, rates: rates,
            source: "Studio eye look \((reference.lookSettingsFile as NSString?)?.lastPathComponent ?? "settings"), \(rateText), "
                + (irisCardValues != nil ? "card pupil/highlight values" : "prefab snapshot"))
    }

    /// This frame's iris `_ST` values for the live source-shader draws, by
    /// source renderer name (`cf_Ohitomi_L02` → `_MainTex_ST` …), Unity
    /// layout `[scale.x, scale.y, offset.x, offset.y]`. Yure states are left
    /// out (their binding stays unresolved, so that material is toon).
    public func liveIrisOverrides() -> [String: [String: [Float]]] {
        guard let look = try? shaderBindingEyeLook(current: true) else { return [:] }
        var result: [String: [String: [Float]]] = [:]
        for (node, properties) in look.transforms {
            for (name, transform) in properties where !transform.yure && transform.scale.count == 2 && transform.offset.count == 2 {
                result[node, default: [:]][name + "_ST"] = transform.scale + transform.offset
            }
        }
        return result
    }

    /// Applies the document's wear (ST-C03). `clothesState` nil renders the
    /// loaded state of the card's saved bytes, `showAccessory` nil the saved
    /// flags and `shoesType` nil the saved shoesType. Values render as given
    /// — the Studio model produces them with `wearRules.setting`, the
    /// CharaStudio button path — so only their shape is checked, and a
    /// rejected value leaves the rendered wear as it was. Nothing is rebuilt:
    /// the next `frame` hides or shows the assembled renderers (dressed,
    /// half-state and both shoe slots) and sets the body cut-out, and
    /// `wearDiagnostics` reports any state drawn with the dressed meshes
    /// instead.
    public func setWear(clothesState: [UInt8]?, showAccessory: [Bool]?, shoesType: Int?) throws {
        let clothes = clothesState ?? loadedClothesState, accessories = showAccessory ?? savedWear.showAccessory
        let shoes = shoesType ?? savedWear.shoesType
        guard clothes.count == 9, clothes.allSatisfy({ $0 <= 3 }) else {
            throw RigError.invalid("Clothes state must be nine ClothesKind values, each in 0...3.")
        }
        guard accessories.count == 20 else { throw RigError.invalid("Accessory visibility must contain exactly 20 slot flags.") }
        guard (0...255).contains(shoes) else { throw RigError.invalid("shoesType must be a byte.") }
        guard clothes != self.clothesState || accessories != self.showAccessory || shoes != self.shoesType else { return }
        wearEvaluation = wearLayout.evaluate(rules: wearRules, states: clothes, shoesType: shoes,
                                             showAccessory: accessories, hideHairSlots: hideHairSlots)
        if clothes != self.clothesState || shoes != self.shoesType {
            dynamicsActiveClothes = (0..<9).reduce(UInt16(0)) { mask, kind in
                wearRules.visible(kind: kind, states: clothes, shoesType: shoes) ? mask | (1 << kind) : mask
            }
            // A wear edit can change garment-root activity at the same clock.
            // Keep particle history for unchanged components; evaluate handles
            // OnEnable resets when a garment becomes active again.
            evaluatedCache = nil
        }
        self.clothesState = clothes
        self.showAccessory = accessories
        self.shoesType = shoes
    }

    /// The clothing renderers the current wear draws, by source mesh name
    /// without the assembly's "clothes-<kind>/" prefix, sorted (readback
    /// for the scenario lane; not used per frame).
    public var drawnClothingMeshes: [String] {
        let parts = preview.source.parts
        return wearLayout.parts.indices.compactMap { index -> String? in
            guard case .clothing = wearLayout.parts[index], !wearEvaluation.hiddenParts.contains(index),
                  parts[index].rendererEnabled, preview.source.rig.activeNodes[parts[index].node] else { return nil }
            let name = parts[index].mesh.name
            return name.firstIndex(of: "/").map { String(name[name.index(after: $0)...]) } ?? name
        }.sorted()
    }

    /// The current wear's fallback lines (empty when every state renders
    /// natively), plus the hair hidden by a HideHair accessory.
    public var wearDiagnostics: [String] {
        wearEvaluation.fallbacks + (wearEvaluation.hairHidden ? ["A shown HideHair accessory hides the hair (ChaControl.CheckHideHair)."] : [])
    }

    /// Applies a face state (ST-C04): nil renders `savedExpression`. Every
    /// field is validated against `expressionControls` before anything
    /// changes, so a rejected state keeps rendering the previous one. Nothing
    /// is rebuilt — no geometry, appearance or pose baseline: the expression
    /// inputs are replaced and the next `frame` uses them. A changed blink
    /// flag only sets the blink control's fixed flags (ChangeEyesBlinkFlag);
    /// a changed neck pattern re-resolves the neck look and rebuilds only
    /// the neck gaze runtime from the saved fixAngle, as a scene load of that
    /// pattern does (the original's in-place NeckLookCalcVer2 type-change
    /// transition is not reproduced); a changed eye pattern keeps a running
    /// eye runtime (OCIChar.ChangeLookEyesPtn only swaps the controller's
    /// ptnNo and target) and Inits one when the eyes were not live. Callers
    /// apply `SourceStudioExpressionState.settled(from:)` for an interactive
    /// edit; rehydration (load, undo, redo, reset) passes the stored state.
    public func setExpressionState(_ requested: SourceStudioExpressionState?) throws {
        let state = requested ?? savedExpression
        guard state != expressionState else { return }
        try expressionControls.validate(state, saved: savedExpression)
        let previous = expressionState
        let inputs = expressionControls.inputs(state, base: expressionBase)
        if state.neckLookPattern != previous.neckLookPattern {
            let neck = Self.resolveNeckLook(source: neckLookSource, pattern: Int32(state.neckLookPattern), targetType: neckTargetType)
            neckLook = neck.override; liveNeckLook = neck.live; neckLookRuntime = neck.runtime
            hasSteppedNeckLook = false; reportedNeckLookFK = []
            invalidateNeckPose()
            neckLookNotes = state.neckLookPattern == savedExpression.neckLookPattern ? []
                : neckLookSource == nil ? ["Neck look settings are not configured; neck pattern \(state.neckLookPattern) is saved and exported but not rendered."]
                : neck.messages
        }
        if state.eyesLookPattern != previous.eyesLookPattern {
            let eye = Self.resolveEyeLook(source: eyeLookSource, pattern: Int32(state.eyesLookPattern), targetType: eyesTargetType)
            if eye.live == nil || liveEyeLook == nil || eyeLookFailure != nil { eyeLookRuntime = nil; eyeLookFailure = nil }
            liveEyeLook = eye.live; eyeLookNote = eye.note
            eyeLookNotes = state.eyesLookPattern == savedExpression.eyesLookPattern ? []
                : eyeLookSource == nil ? ["Eye look settings are not configured; eye look pattern \(state.eyesLookPattern) is saved and exported but not rendered."]
                : eye.messages
        }
        if state.blink != previous.blink { blink.setEyesBlink(state.blink) }
        expressionState = state
        expressionInputs = inputs
        expressionDiagnostics = expressionControls.diagnostics(state) + Self.guideNote(state, guide: lookAtGuidePosition)
            + neckLookNotes + eyeLookNotes
    }

    /// True while the eye controller follows the look-at guide (pattern 4,
    /// OCIChar.ChangeLookEyesPtn) instead of the Studio camera.
    public var eyeLookFollowsGuide: Bool { expressionState.eyesLookPattern == 4 }

    private static func guideNote(_ state: SourceStudioExpressionState, guide: Float3) -> [String] {
        guard state.eyesLookPattern == 4 else { return [] }
        return ["Eye look pattern 4 targets the saved look-at guide at (\(guide.x), \(guide.y), \(guide.z)), read as a position in the character's own space (the guide's prefab parent is not converted)."]
    }

    private static func resolveNeckLook(source: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf])?, pattern: Int32, targetType: Int32?)
        -> (override: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf], lookType: SourceStudioNeckLookType)?,
            live: (settings: SourceStudioNeckLookSettings, fixAngle: [simd_quatf], pattern: Int)?,
            runtime: SourceStudioNeckLookRuntime?, messages: [String]) {
        guard let source else { return (nil, nil, nil, []) }
        var messages: [String] = []
        let resolution = SourceStudioNeckLookOverride.resolve(effectivePattern: pattern, settings: source.settings, savedBoneCount: source.fixAngle.count)
        if let lookType = resolution.lookType, resolution.applied != .none {
            messages.append("Neck look override \(resolution.applied.rawValue): \(resolution.reason)")
            return ((source.settings, source.fixAngle, lookType), nil, nil, messages)
        }
        if let lookType = resolution.lookType, lookType == .target || lookType == .away, source.fixAngle.count == 2 {
            // NeckLookControllerVer2.target drives the gaze and its rate is 1;
            // type 0 reads the main camera, any other type has no recovered
            // meaning, so the animated pose is kept.
            if let targetType, targetType != 0 {
                messages.append("Neck look target type \(targetType) is not the main camera (0); the animated pose is kept.")
                return (nil, nil, nil, messages)
            }
            messages.append("Neck look override live: \(lookType.rawValue) follows the Studio camera from the saved fixAngle.")
            do {
                let runtime = try SourceStudioNeckLookRuntime(settings: source.settings, fixAngle: source.fixAngle)
                return (nil, (source.settings, source.fixAngle, Int(pattern)), runtime, messages)
            } catch {
                messages.append("Studio neck look runtime unavailable: \(error); the animated pose is kept.")
                return (nil, (source.settings, source.fixAngle, Int(pattern)), nil, messages)
            }
        }
        messages.append("Neck look override \(resolution.applied.rawValue): \(resolution.reason)")
        return (nil, nil, nil, messages)
    }

    private static func resolveEyeLook(source: (settings: SourceStudioEyeLookSettings, savedAngles: (horizontal: [Double], vertical: [Double])?)?,
                                       pattern: Int32?, targetType: Int32?)
        -> (live: (settings: SourceStudioEyeLookSettings, pattern: Int, savedAngles: (horizontal: [Double], vertical: [Double])?)?,
            note: String?, messages: [String]) {
        guard let source else { return (nil, nil, []) }
        guard let pattern, pattern >= 0, source.settings.eyeTypeStates.indices.contains(Int(pattern)) else {
            let shown = pattern.map(String.init) ?? "unset"
            return (nil, "pattern \(shown) has no eyeTypeStates entry",
                    ["Eye look pattern is unset or outside the prefab's \(source.settings.eyeTypeStates.count) states; the animated eyes are kept."])
        }
        let lookType = source.settings.eyeTypeStates[Int(pattern)].lookType
        if let targetType, targetType != 0 {
            return (nil, "target type \(targetType) is not the main camera",
                    ["Eye look target type \(targetType) is not the main camera (0); the animated eyes are kept."])
        }
        if lookType == .noLook {
            return (nil, "pattern \(pattern) is NO_LOOK",
                    ["Eye look pattern \(pattern) is NO_LOOK; its fixAngle write is not recorded, so the animated eyes are kept."])
        }
        let target = pattern == 4 ? "the look-at guide" : "the Studio camera"
        return ((source.settings, Int(pattern), source.savedAngles), nil,
                ["Eye look live: \(lookType.rawValue) pattern \(pattern) follows \(target)."])
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
        let shapeCorrection = try preview.lateCorrection(restoring: shapeBaseline)
        var animationBaseline = shapeBaseline
        let savedState = SourceStudioAnimationState(record: record)
        if let animation = animationCache["\(savedState.group)/\(savedState.category)/\(savedState.no)"] {
            animationBaseline = try animation.pose(state: savedState, elapsed: 0,
                height: (body ?? savedBodyValues).first ?? animationHeight, rig: preview.source.rig, baseline: shapeBaseline)
        }
        try shapeCorrection.apply(to: &animationBaseline)
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
        shapeRevision &+= 1
        baseline = shapeBaseline
        latePoseCorrection = shapeCorrection
        controller = restored.controller
        self.pose = pose
        ikGuides = guides
        ikSolver = solver
        clearDynamicsStep()
        dynamics = simulation
        sourceFaceValues = face
        sourceBodyValues = body
        // The eye tilt reads face shape value 33 (ChangeSettingEyeTilt), so an
        // edited face array re-derives it exactly as the import did.
        let tilt = 0.02 - 0.04 * Double((face ?? savedFaceValues)[33])
        irisRotations = [tilt, -tilt]
        // The look runtimes and the animation clock carry the replaced
        // baseline's geometry; restart them the way a scene reload does. Init
        // reported every record-derived restored/solver diagnostic once, so a
        // per-edit rebuild never appends them again.
        animationPlayback.reset()
        hasSteppedNeckLook = false
        resetNeckLook(); resetEyeLook()
    }

    /// Validates edited card colors and rebuilds the preview appearance when
    /// they replace the card's saved colors, mirroring the Maker's
    /// replaceSourceAppearance: a fresh draft off the same card, every edited
    /// color set on it, then the same two appearance passes the import ran.
    /// Colors that never bound a material on this assembly (the ones the
    /// Maker only shows after Apply) stay reference materials, so an edit of
    /// one is reported and the draft keeps it for a later assembly. An empty
    /// or nil dictionary restores the card's saved colors. Poses, dynamics and
    /// the look runtimes read no colors, so unlike a shape edit nothing else
    /// is rebuilt; only the rendered `preview` instance is swapped and the
    /// next `frame` reflects it. Export diffs the document's colors against
    /// `savedColors` for the embedded-card writeback.
    public func setColorEdits(_ edits: [String: Float4]?, appearanceTransaction: SourceAppearanceLoadTransaction? = nil) throws {
        let edits = edits?.isEmpty == true ? nil : edits
        guard edits != sourceColorEdits else { return }
        guard !appliedColorFields.isEmpty else {
            throw RigError.invalid("This assembly has no card appearance bindings, so color editing is unsupported.")
        }
        var draft = try SourceCardAppearance(card: appearanceCard, coordinate: coordinate)
        let supported = Set(draft.colors.map(\.id))
        for (id, rgba) in edits.map({ $0.sorted { $0.key < $1.key } }) ?? [] {
            guard supported.contains(id) else { throw RigError.invalid("Unsupported color field \(id).") }
            // setColor validates finiteness and the 0...1 range; rethrow with
            // the field named so the inspector reports which color was rejected.
            do { try draft.setColor(id, rgba: rgba) }
            catch { throw RigError.invalid("Color \(id) must be finite and between 0 and 1.") }
        }
        var appearance = try SourcePreviewAppearance.load(url: appearanceRigURL.deletingPathExtension().appendingPathExtension("appearance.json"), resources: resources, transaction: appearanceTransaction)
        var messages: [String] = []
        var fields: Set<String> = []
        if FileManager.default.fileExists(atPath: appearanceBindingsURL.path) {
            var bindings = try SourceAppearanceBindings.load(url: appearanceBindingsURL)
            if let appearancePrepared { bindings = bindings.restricted(to: Set(appearancePrepared.source.parts.map { $0.mesh.name })) }
            let applied = try appearance.applying(draft, bindings: bindings, directory: appearanceDirectory, resources: resources)
            appearance = applied.appearance; messages += applied.diagnostics; fields.formUnion(applied.appliedFields)
        }
        if let applied = try appearancePrepared?.appearance(base: appearance, card: draft, resources: resources, modLibrary: nil, transaction: appearanceTransaction) {
            appearance = applied.appearance; messages += applied.diagnostics; fields.formUnion(applied.appliedFields)
        }
        // The Maker's Apply gate keeps unbound colors as reference materials;
        // here the edit is explicit, so an unbound color is reported instead.
        let unbound = (edits?.keys.sorted() ?? []).filter { !fields.contains($0) && draft.color($0) != nil }
        for id in unbound.sorted() {
            messages.append("\(id) binds no material on this assembly; the edited color is retained in the native document but not rendered and is skipped by original-scene export.")
        }
        // Every fallible stage ran; the swap itself cannot fail, so the old
        // preview (unregistered in its deinit) survives a rejected edit.
        preview = try SourceRigPreview(source: appearancePrepared?.source ?? preview.source, contract: preview.contract,
            resources: resources, appearance: appearance, expressionContract: preview.expressionContract,
            bodyOptions: preview.bodyOptions, lateCorrectionOptions: preview.lateCorrectionOptions, doubleTooth: preview.doubleTooth)
        sourceColorEdits = edits
        appliedColorFields = fields.intersection(supported)
        colorEditDiagnostics = edits == nil ? nil : messages
    }

    /// The FK/IK state a frame evaluates with: the document's explicit state,
    /// else the saved record's, switched to FK (groups of the edited bones) or
    /// IK (groups of the edited targets) by edits the document holds.
    public func effectiveKinematics(fkRotations: [Int: Float3], ikTargets: [Int32: SourceStudioIKEdit],
                                    kinematics: SourceStudioKinematicState?) throws -> SourceStudioKinematicState {
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
        return effective
    }

    public func editedPose(fkRotations: [Int: Float3] = [:], faceValues: [Float]? = nil, bodyValues: [Float]? = nil, ikTargets: [Int32: SourceStudioIKEdit] = [:], kinematics: SourceStudioKinematicState? = nil, animationState: SourceStudioAnimationState? = nil,
                           animationElapsed: Float = 0) throws -> RigPose {
        try setShapeValues(face: faceValues, body: bodyValues)
        let state = animationState ?? SourceStudioAnimationState(record: record)
        // Saved, unconverted motion may fall back, but an explicit edit must
        // still resolve or throw even when its numeric state is unchanged.
        let required = animationState != nil
        if let cache = evaluatedCache, cache.state == state, cache.required == required, cache.elapsed == animationElapsed, cache.fk == fkRotations, cache.ik == ikTargets, cache.kinematics == kinematics { return cache.pose }
        try SourceStudioIKEditing.validate(ikTargets); try kinematics?.validate()
        var result: RigPose
        let effective: SourceStudioKinematicState
        let guides: [SourceStudioIK.Guide]
        if let solved = solvedCache, solved.state == state, solved.required == required, solved.elapsed == animationElapsed,
           solved.fk == fkRotations, solved.ik == ikTargets, solved.kinematics == kinematics {
            result = solved.pose; effective = solved.effective; guides = solved.guides
        } else {
            (result, effective, guides) = try solvedPose(state: state, required: required, fkRotations: fkRotations, ikTargets: ikTargets,
                                                        kinematics: kinematics, animationElapsed: animationElapsed)
            solvedCache = (state, required, animationElapsed, fkRotations, ikTargets, kinematics, result, effective, guides)
        }
        let preOverride = result
        try applyLookAndDynamics(to: &result, preOverride: preOverride, effective: effective, animationElapsed: animationElapsed)
        evaluatedCache = (state, required, animationElapsed, fkRotations, ikTargets, kinematics, result, preOverride, guides)
        return result
    }

    /// The animation, saved hand patterns, FK/IK restore and IK solve of
    /// `editedPose`: the pose before any look override, the effective
    /// kinematic state and the IK guides.
    private func solvedPose(state: SourceStudioAnimationState, required: Bool, fkRotations: [Int: Float3], ikTargets: [Int32: SourceStudioIKEdit],
                            kinematics: SourceStudioKinematicState?, animationElapsed: Float) throws -> (RigPose, SourceStudioKinematicState, [SourceStudioIK.Guide]) {
        var result: RigPose
        if let animation = try resolvedAnimation(state, required: required) {
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
        // Original ChaControl late setters run after the Animators. Keep the
        // supported static ABMX scale from the shape baseline; FK/IK follows.
        try latePoseCorrection.apply(to: &result)
        let effective = try effectiveKinematics(fkRotations: fkRotations, ikTargets: ikTargets, kinematics: kinematics)
        let rig = preview.source.rig, binding: KoikatsuCharacterRecord.PoseBinding
        if let cached = poseBinding, cached.rig === rig.identity, cached.kinematics == effective, Self.sameBits(cached.fk, fkRotations) {
            binding = cached.binding
        } else {
            binding = try record.bindPose(rig: rig, catalog: poseCatalog,
                characterRoot: characterRoot, bodyRoot: rig.uniqueNode(named: "p_cf_body_bone"),
                hairRoot: rig.uniqueNode(named: "cf_J_FaceUp_ty"), kinematics: effective, fkOverrides: fkRotations)
            poseBinding = (rig.identity, effective, fkRotations, binding)
        }
        let restored = try record.makePose(binding: binding, rig: rig, baseline: result)
        let edited = restored.controller
        result = restored.pose
        var guides: [SourceStudioIK.Guide] = []
        if let ikSolver {
            let solved = try ikSolver.apply(rig: preview.source.rig, baseline: result, savedTargets: record.ikTargets,
                enabled: edited.enableIK, activeGroups: edited.activeIK, characterRoot: characterRoot, guideOverrides: ikTargets.mapValues(\.transform))
            result = solved.pose; guides = solved.guides
        } else if !ikTargets.isEmpty { throw RigError.invalid("Source IK bindings are unavailable for guide editing.") }
        return (result, effective, guides)
    }

    /// Equal keys whose angles have equal bit patterns.
    private static func sameBits(_ a: [Int: Float3], _ b: [Int: Float3]) -> Bool {
        a.count == b.count && a.allSatisfy { key, value in
            b[key].map { $0.x.bitPattern == value.x.bitPattern && $0.y.bitPattern == value.y.bitPattern && $0.z.bitPattern == value.z.bitPattern } ?? false
        }
    }

    /// The neck look override and hair dynamics `editedPose` applies to the
    /// solved pose for this tick's neck rotations and dynamics step.
    private func applyLookAndDynamics(to result: inout RigPose, preOverride: RigPose, effective: SourceStudioKinematicState,
                                      animationElapsed: Float) throws {
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
                    invalidateNeckPose()
                    if reportedNeckLookFK.insert(lookType).inserted {
                        diagnostics.append("Neck look override skipped: \(error); the animated pose is kept.")
                    }
                }
            }
        }
        if var simulation = dynamics, dynamicsStep?.elapsed == animationElapsed {
            result = try simulation.evaluate(time: animationElapsed, rig: preview.source.rig, upstream: result,
                enableFK: effective.enableFK, activeFK: effective.activeFK,
                deltaTime: dynamicsStep?.elapsed == animationElapsed ? dynamicsStep?.delta : nil, activeClothes: dynamicsActiveClothes)
            dynamics = simulation
        }
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
        animationPlayback.reset(); evaluatedCache = nil; solvedCache = nil; hasSteppedNeckLook = false; resetNeckLook(); resetEyeLook()
    }

    /// True when the effective neck pattern is TARGET or AWAY and the gaze
    /// runtime exists: the Studio tick then steps updateNeckLook per frame.
    public var hasLiveNeckLook: Bool { neckLookRuntime != nil }

    private func invalidateNeckPose() {
        neckPoseRevision &+= 1
        evaluatedCache = nil
        // The animation/FK/IK solve precedes gaze and remains reusable.
    }

    /// Rebuilds the TARGET/AWAY gaze runtime from the saved fixAngle, the way
    /// a scene load restores the calculator, so a seek or clock jump restarts
    /// the transition instead of carrying stale smoothing across the jump.
    public func resetNeckLook() {
        guard let live = liveNeckLook else { return }
        do { neckLookRuntime = try SourceStudioNeckLookRuntime(settings: live.settings, fixAngle: live.fixAngle) }
        catch { diagnostics.append("Studio neck look runtime reset failed: \(error); the animated pose is kept.") }
        hasSteppedNeckLook = false
        invalidateNeckPose()
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
        invalidateNeckPose()
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
              (0..<3).allSatisfy({ cameraModelPosition[$0].isFinite && lookAtGuidePosition[$0].isFinite }) else {
            throw RigError.invalid("Eye look gaze needs a finite deltaTime up to 10 s and a finite camera and guide position.")
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
        // OCIChar.ChangeLookEyesPtn(4) points eyeLookCtrl.target at the
        // look-at guide; every other pattern reads the main camera.
        let aim = eyeLookFollowsGuide ? lookAtGuidePosition : cameraModelPosition
        let target = SIMD3(Double(aim.x), Double(aim.y), Double(aim.z))
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

    /// The face state's expression inputs with the blink clock applied. While
    /// blinking is on, the recovered rate drives eye and synced brow openness;
    /// with the flag off the fixed sentinel leaves the held open rates the
    /// state carries (ChangeEyesBlinkFlag/ChangeEyesOpenMax: the eyes at the
    /// held or replayed openness, the eyebrows at 1). Automatic blinking off
    /// renders the contract's blink rate instead, like the Maker preview
    /// holding its manual rate. Per frame this only copies the clock's rate.
    public func effectiveExpressionInputs() -> SourceExpressionInputs? {
        guard var inputs = expressionInputs else { return nil }
        if automaticBlink { inputs.blinkRate = blink.rate }
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

    /// True once this card's blink control rendered an openness below fully
    /// open since the last `resetBlinkObservation()`. A card whose saved
    /// `eyesBlink` flag is off renders the fixed sentinel instead and can
    /// never set it. The Studio scenario's `blink {key, happening}` asserts
    /// this; the clock itself stays private.
    public var didBlink: Bool { blink.observedBlink }

    /// Starts a new blink observation window; the scenario's `advance` op
    /// calls this before driving the app's own live step.
    public func resetBlinkObservation() { blink.resetObservation() }

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
