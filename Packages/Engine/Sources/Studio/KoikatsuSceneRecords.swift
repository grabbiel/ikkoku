import Foundation
import simd
import CoreMath
import Scene
import Character
import Assets

public struct KoikatsuAnimationRecord: Sendable, Equatable {
    public let group: Int32, category: Int32, no: Int32
}

public struct KoikatsuCharacterRecord: Sendable, Equatable {
    public let sex: Int32
    /// Exact embedded no-PNG card including recognized legacy extension bytes.
    public let cardData: Data
    public let bones: [Int32: KoikatsuBoneRecord]
    public let ikTargets: [Int32: KoikatsuBoneRecord]
    public let accessoryChildren: [Int32: [KoikatsuObjectRecord]]
    public let kinematicMode: Int32
    public let animation: KoikatsuAnimationRecord
    public let handPatterns: [Int32]
    public let nipple: Float, fluidLevels: Data, mouthOpen: Float, lipSync: Bool
    public let lookAtTarget: KoikatsuBoneRecord
    public let enableIK: Bool, activeIK: [Bool], enableFK: Bool, activeFK: [Bool], expressions: [Bool]
    public let animationSpeed: Float, animationPattern: Float, animationOptionVisible: Bool, forceLoop: Bool
    public let voices: [KoikatsuAnimationRecord], voiceRepeat: Int32
    public let visibleSon: Bool, sonLength: Float, visibleSimple: Bool, simpleColor: SIMD4<Float>
    public let animationOptionParameters: SIMD2<Float>
    public let neckData: Data, eyesData: Data, animationNormalizedTime: Float
    public let accessoryGroupStates: [Int32: Int32], accessoryStates: [Int32: Int32]

    public func card() throws -> SourceCharacterCard { try SourceCharacterCard.decode(cardData) }

    public struct PoseResult: Sendable {
        public let controller: SourceStudioPose
        public let pose: RigPose
        public let deferredEffects: [SourceStudioPose.Effect]
        public let diagnostics: [String]
    }

    /// What `makePose` derives before it touches a pose: the FK controller
    /// bound to the rig and catalog after the saved activation commands, the
    /// two mode transitions it applies, its deferred effects and diagnostics.
    /// It depends only on the rig, the catalog, the roots, the record, the
    /// neck pattern, the kinematic state and the FK overrides, so one binding
    /// serves every baseline while those stay the same (R7 phase 2, item 3,
    /// C3: the Studio tick used to rebind it for every pose).
    public struct PoseBinding: Sendable {
        public let controller: SourceStudioPose
        fileprivate let ik: SourceStudioPose.Transition, fk: SourceStudioPose.Transition
        fileprivate let effects: [SourceStudioPose.Effect]
        fileprivate let diagnostics: [String]
    }

    /// Replays source AddObjectFemale/Male's flag restoration order. The input
    /// pose must already include card customization and the sampled animation.
    /// This does not replace missing character geometry with a guessed model.
    public func makePose(rig: RigDefinition, catalog: [SourceStudioPose.Bone], baseline: RigPose,
                         characterRoot: Int, bodyRoot: Int? = nil, hairRoot: Int? = nil,
                         neckLookPattern: Int = 0, kinematics: SourceStudioKinematicState? = nil,
                         fkOverrides: [Int: SIMD3<Float>] = [:]) throws -> PoseResult {
        try makePose(binding: bindPose(rig: rig, catalog: catalog, characterRoot: characterRoot, bodyRoot: bodyRoot, hairRoot: hairRoot,
                                       neckLookPattern: neckLookPattern, kinematics: kinematics, fkOverrides: fkOverrides),
                     rig: rig, baseline: baseline)
    }

    /// The pose-independent half of `makePose`.
    public func bindPose(rig: RigDefinition, catalog: [SourceStudioPose.Bone],
                         characterRoot: Int, bodyRoot: Int? = nil, hairRoot: Int? = nil,
                         neckLookPattern: Int = 0, kinematics: SourceStudioKinematicState? = nil,
                         fkOverrides: [Int: SIMD3<Float>] = [:]) throws -> PoseBinding {
        let state = kinematics ?? SourceStudioKinematicState(record: self)
        try state.validate()
        let activeFK = state.activeFK, activeIK = state.activeIK, enableFK = state.enableFK, enableIK = state.enableIK
        var rotations = Dictionary(uniqueKeysWithValues: bones.map { (Int($0.key), $0.value.transform.rotationDegrees) })
        rotations.merge(fkOverrides) { _, edit in edit }
        var controller = try SourceStudioPose(rig: rig, bones: catalog,
            rotations: rotations,
            characterRoot: characterRoot, bodyRoot: bodyRoot, hairRoot: hairRoot, sex: Int(sex), neckLookPattern: neckLookPattern)
        var effects: [SourceStudioPose.Effect] = []
        // Stage preferences while FK is off. Forced mode changes must not replace them.
        for (index, group) in SourceStudioPose.Group.fkParts.enumerated() {
            _ = controller.activateFK(mask: group, active: activeFK[index])
        }
        for (index, group) in SourceStudioPose.Group.ikParts.enumerated() {
            effects += controller.activateIK(mask: group, active: activeIK[index]).effects
        }
        let ik = controller.activateMode(.ik, active: enableIK, force: true)
        // OCIChar and _info refer to the same object: enabling IK clears the
        // later-read _info.enableFK, even if the serialized flags were both true.
        // Applying a transition reads only the bound hierarchy, never the
        // activation state, so both modes are activated before either applies.
        let fk = controller.activateMode(.fk, active: enableFK && !enableIK, force: true)
        effects += ik.effects; effects += fk.effects
        let bound = Set(controller.targets.map { Int32($0.bone.id) })
        var diagnostics = ["Character appearance, animation sampling, IK, dynamics, look-at, hands, expression selection, voice and accessory attachment require separate native consumers."]
        let unbound = bones.keys.filter { !bound.contains($0) }.sorted()
        if !unbound.isEmpty { diagnostics.append("Saved FK bone IDs without a bound catalog transform: \(unbound.map(String.init).joined(separator: ", ")).") }
        if enableIK { diagnostics.append("Source IK is enabled; targets and weights are retained but the original solver is not executed.") }
        if enableFK && enableIK { diagnostics.append("Both persisted modes were enabled; original load order resolves this to IK.") }
        return PoseBinding(controller: controller, ik: ik, fk: fk, effects: effects, diagnostics: diagnostics)
    }

    /// The pose half of `makePose`: the IK transition, the FK transition and
    /// the FK late update on `baseline`. `rig` is the rig `binding` was made
    /// with.
    public func makePose(binding: PoseBinding, rig: RigDefinition, baseline: RigPose) throws -> PoseResult {
        let pose = try binding.controller.applyingActivations(ik: binding.ik, fk: binding.fk, rig: rig, pose: baseline)
        return PoseResult(controller: binding.controller, pose: pose, deferredEffects: binding.effects, diagnostics: binding.diagnostics)
    }
}

public struct KoikatsuRoutePointRecord: Sendable, Equatable {
    public let bone: KoikatsuBoneRecord
    public let speed: Float, easeType: Int32, connection: Int32
    /// The aid's object key, or nil when the scene saves no aid (versions
    /// before 1.0.4.1): CharaStudio then creates one at load
    /// (`AddObjectRoute.InitAid`) under a key `GetNewIndex` allocates from
    /// runtime state, and the aid has not been allocated in this record.
    public let aidKey: Int32?
    /// The aid's transform: the saved one, or for an unsaved aid the
    /// `p_RoutePoint` prefab's that `InitAid` gives it ((1, 1, 1), zero, one).
    public let aidTransform: KoikatsuChangeAmount
    public let aidInitialized: Bool, linked: Bool

    /// The saved aid record; nil when the scene saves none (`aidKey`).
    public var aid: KoikatsuBoneRecord? { aidKey.map { KoikatsuBoneRecord(sourceKey: $0, transform: aidTransform) } }

    init(bone: KoikatsuBoneRecord, speed: Float, easeType: Int32, connection: Int32,
         aid: KoikatsuBoneRecord, aidInitialized: Bool, linked: Bool) {
        self.init(bone: bone, speed: speed, easeType: easeType, connection: connection, aidKey: aid.sourceKey,
                  aidTransform: aid.transform, aidInitialized: aidInitialized, linked: linked)
    }
    init(bone: KoikatsuBoneRecord, speed: Float, easeType: Int32, connection: Int32, aidKey: Int32?,
         aidTransform: KoikatsuChangeAmount, aidInitialized: Bool, linked: Bool) {
        self.bone = bone; self.speed = speed; self.easeType = easeType; self.connection = connection
        self.aidKey = aidKey; self.aidTransform = aidTransform; self.aidInitialized = aidInitialized; self.linked = linked
    }
}

public struct KoikatsuRouteRecord: Sendable, Equatable {
    public let points: [KoikatsuRoutePointRecord]
    public let active: Bool, loop: Bool, visibleLine: Bool, orientation: Int32, color: SIMD4<Float>
}

public struct KoikatsuSceneLighting: Sendable, Equatable {
    public let color: SIMD4<Float>, intensity: Float, rotation: SIMD2<Float>, shadow: Bool
    public let type: Int32?
}
public struct KoikatsuSceneSound: Sendable, Equatable {
    public let repeatMode: Int32, catalogNumber: Int32?, fileName: String?, play: Bool
}
public struct KoikatsuSceneSettings: Sendable, Equatable {
    public let map: Int32, mapTransform: KoikatsuChangeAmount, sunLightType: Int32, mapOption: Bool, colorCorrection: Int32
    public let floatSettings: [String: Float], boolSettings: [String: Bool], colorSettings: [String: SIMD4<Float>]
    public let sunCaster: Int32, ramp: Int32
    public let camera: KoikatsuCameraRecord, cameraSlots: [KoikatsuCameraRecord]
    public let characterLight: KoikatsuSceneLighting, mapLight: KoikatsuSceneLighting
    public let backgroundMusic: KoikatsuSceneSound, environmentSound: KoikatsuSceneSound, outsideSound: KoikatsuSceneSound
    public let background: String, frame: String
}

public struct KoikatsuSceneDocument: Sendable, Equatable {
    public let snapshot: KoikatsuSceneSnapshot
    public let settings: KoikatsuSceneSettings
    public let baseSceneEndOffset: Int
    public let trailingData: Data
    public let preservedData: Data

    public struct Extensions: Sendable {
        public let version: Int32?
        public let payload: SourceMessagePackValue?
        public let diagnostics: [String]
    }
    /// The installed scene hook ignores the version field. Keep it visible and
    /// preserve the raw string-keyed PluginData map without executing callbacks.
    public func extensions() -> Extensions {
        guard !trailingData.isEmpty else { return Extensions(version: nil, payload: nil, diagnostics: []) }
        do {
            var reader = try KoikatsuBinaryReader(trailingData)
            guard try reader.string() == "KKEx" else {
                return Extensions(version: nil, payload: nil, diagnostics: ["Unknown scene trailer retained verbatim."])
            }
            let version = try reader.int32(), length = try reader.byteCount(maximum: 64 * 1024 * 1024)
            guard length > 0 else { throw reader.invalid("empty ExtendedSave scene payload") }
            let payload = try SourceMessagePack.decode(reader.take(min(length, reader.data.count - reader.offset)))
            if payload != .null { _ = try payload.stringKeyedMap() }
            var diagnostics = ["ExtendedSave scene data is decoded and retained; plug-in load/import callbacks are not executed."]
            if reader.offset < reader.data.count { diagnostics.append("Additional bytes after the ExtendedSave payload are retained.") }
            return Extensions(version: version, payload: payload, diagnostics: diagnostics)
        } catch {
            return Extensions(version: nil, payload: nil, diagnostics: ["Invalid or unsupported scene extension retained: \(error)"])
        }
    }
}
