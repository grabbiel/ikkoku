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

    /// Replays source AddObjectFemale/Male's flag restoration order. The input
    /// pose must already include card customization and the sampled animation.
    /// This does not replace missing character geometry with a guessed model.
    public func makePose(rig: RigDefinition, catalog: [SourceStudioPose.Bone], baseline: RigPose,
                         characterRoot: Int, bodyRoot: Int? = nil, hairRoot: Int? = nil,
                         neckLookPattern: Int = 0, kinematics: SourceStudioKinematicState? = nil,
                         fkOverrides: [Int: SIMD3<Float>] = [:]) throws -> PoseResult {
        let state = kinematics ?? SourceStudioKinematicState(record: self)
        try state.validate()
        let activeFK = state.activeFK, activeIK = state.activeIK, enableFK = state.enableFK, enableIK = state.enableIK
        var rotations = Dictionary(uniqueKeysWithValues: bones.map { (Int($0.key), $0.value.transform.rotationDegrees) })
        rotations.merge(fkOverrides) { _, edit in edit }
        var controller = try SourceStudioPose(rig: rig, bones: catalog,
            rotations: rotations,
            characterRoot: characterRoot, bodyRoot: bodyRoot, hairRoot: hairRoot, sex: Int(sex), neckLookPattern: neckLookPattern)
        var pose = baseline, effects: [SourceStudioPose.Effect] = []
        // Stage preferences while FK is off. Forced mode changes must not replace them.
        for (index, group) in SourceStudioPose.Group.fkParts.enumerated() {
            _ = controller.activateFK(mask: group, active: activeFK[index])
        }
        for (index, group) in SourceStudioPose.Group.ikParts.enumerated() {
            effects += controller.activateIK(mask: group, active: activeIK[index]).effects
        }
        let ik = controller.activateMode(.ik, active: enableIK, force: true)
        pose = try controller.applying(ik, rig: rig, pose: pose); effects += ik.effects
        // OCIChar and _info refer to the same object: enabling IK clears the
        // later-read _info.enableFK, even if the serialized flags were both true.
        let fk = controller.activateMode(.fk, active: enableFK && !enableIK, force: true)
        pose = try controller.applying(fk, rig: rig, pose: pose); effects += fk.effects
        pose = try controller.applyingLateUpdate(rig: rig, pose: pose)
        let bound = Set(controller.targets.map { Int32($0.bone.id) })
        var diagnostics = ["Character appearance, animation sampling, IK, dynamics, look-at, hands, expression selection, voice and accessory attachment require separate native consumers."]
        let unbound = bones.keys.filter { !bound.contains($0) }.sorted()
        if !unbound.isEmpty { diagnostics.append("Saved FK bone IDs without a bound catalog transform: \(unbound.map(String.init).joined(separator: ", ")).") }
        if enableIK { diagnostics.append("Source IK is enabled; targets and weights are retained but the original solver is not executed.") }
        if enableFK && enableIK { diagnostics.append("Both persisted modes were enabled; original load order resolves this to IK.") }
        return PoseResult(controller: controller, pose: pose, deferredEffects: effects, diagnostics: diagnostics)
    }
}

public struct KoikatsuRoutePointRecord: Sendable, Equatable {
    public let bone: KoikatsuBoneRecord
    public let speed: Float, easeType: Int32, connection: Int32
    public let aid: KoikatsuBoneRecord, aidInitialized: Bool, linked: Bool
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
