import Foundation
import simd
import CoreMath
import Scene

/// Native workspace edits keyed by original Studio target number. The saved
/// dictionary key and disabled scale destination are retained by the exporter.
public struct SourceStudioIKEdit: Codable, Sendable, Equatable {
    public var position: Float3, rotationDegrees: Float3
    public init(position: Float3, rotationDegrees: Float3 = .zero) { self.position = position; self.rotationDegrees = rotationDegrees }
    public init(_ transform: KoikatsuChangeAmount) { position = transform.position; rotationDegrees = transform.rotationDegrees }
    public var transform: KoikatsuChangeAmount { .init(position: position, rotationDegrees: rotationDegrees, scale: .one) }
}

public struct SourceStudioKinematicState: Codable, Sendable, Equatable {
    public var enableFK: Bool, enableIK: Bool, activeFK: [Bool], activeIK: [Bool]
    public init(record: KoikatsuCharacterRecord) {
        enableFK = record.enableFK; enableIK = record.enableIK; activeFK = record.activeFK; activeIK = record.activeIK
    }
    public init(enableFK: Bool, enableIK: Bool, activeFK: [Bool], activeIK: [Bool]) {
        self.enableFK = enableFK; self.enableIK = enableIK; self.activeFK = activeFK; self.activeIK = activeIK
    }
    public func validate() throws {
        guard activeFK.count == 7, activeIK.count == 5 else { throw RigError.invalid("Source kinematics require seven FK and five IK groups.") }
    }
    public var edit: SourceSceneEdits.KinematicEdit { .init(enableFK: enableFK, enableIK: enableIK, activeFK: activeFK, activeIK: activeIK) }
}

public enum SourceStudioIKEditing {
    public static let labels = ["Body", "Left shoulder", "Left elbow", "Left hand", "Right shoulder", "Right elbow", "Right hand", "Left thigh", "Left knee", "Left foot", "Right thigh", "Right knee", "Right foot"]
    public static let groupLabels = ["Body", "Right leg", "Left leg", "Right arm", "Left arm"]
    public static func groupIndex(target: Int32) throws -> Int {
        guard (0...12).contains(target) else { throw RigError.invalid("Unknown original Studio IK target number.") }
        return [0,4,4,4,3,3,3,2,2,2,1,1,1][Int(target)]
    }
    public static func allowsRotation(_ target: Int32) -> Bool { [3,6,9,12].contains(target) }
    public static func validate(_ edits: [Int32: SourceStudioIKEdit]) throws {
        for (id, edit) in edits {
            _ = try groupIndex(target: id)
            guard [edit.position,edit.rotationDegrees].allSatisfy({ v in v.x.isFinite && v.y.isFinite && v.z.isFinite }) else {
                throw RigError.invalid("Source IK guide edit contains a nonfinite component.")
            }
        }
    }
    /// GuideObject work transforms are character-local. Invert affine position
    /// separately from composed rotation so scaled/attached characters edit correctly.
    public static func fromWorld(target: Int32, position: Float3, rotation: simd_quatf?, characterWorld: float4x4,
                                 characterRotation: simd_quatf, preserving: SourceStudioIKEdit) throws -> SourceStudioIKEdit {
        _ = try groupIndex(target: target)
        guard characterWorld.determinant.isFinite, abs(characterWorld.determinant)>1e-8,
              position.x.isFinite,position.y.isFinite,position.z.isFinite else { throw RigError.invalid("Source IK guide has an invalid character frame.") }
        let local=characterWorld.inverse*Float4(position,1)
        var result=preserving
        result.position=UnityCoordinates.position(Float3(local.x,local.y,local.z))
        if let rotation {
            guard allowsRotation(target), rotation.vector.x.isFinite,rotation.vector.y.isFinite,rotation.vector.z.isFinite,rotation.vector.w.isFinite,
                  simd_length_squared(rotation.vector)>1e-8,simd_length_squared(characterRotation.vector)>1e-8 else {
                throw RigError.invalid("This source IK target does not accept a finite rotation.")
            }
            result.rotationDegrees=UnityCoordinates.sourceEulerDegrees((characterRotation.inverse*rotation).normalized)
        }
        try validate([target:result]);return result
    }
    /// Merge with existing FK edits, retaining all saved IDs and untouched data.
    public static func appendEdits(objectKey: Int32, record: KoikatsuCharacterRecord,
                                   overrides: [Int32: SourceStudioIKEdit], state: SourceStudioKinematicState?,
                                   to edits: inout SourceSceneEdits) throws {
        try validate(overrides);try state?.validate()
        for (id, override) in overrides.sorted(by:{$0.key<$1.key}) {
            guard let saved=record.ikTargets[id] else { throw RigError.invalid("Export cannot add a previously absent source IK target record.") }
            let rotation=allowsRotation(id) ? override.rotationDegrees:saved.transform.rotationDegrees
            edits.transforms.append(.init(.characterIK(object:objectKey,target:id),transform:.init(position:override.position,rotationDegrees:rotation,scale:saved.transform.scale)))
        }
        if let state { edits.kinematics[objectKey]=state.edit }
        else if !overrides.isEmpty {
            var groups=record.activeIK
            for id in overrides.keys { groups[try groupIndex(target:id)]=true }
            var k=edits.kinematics[objectKey] ?? .init()
            k.enableFK=false;k.enableIK=true;k.activeIK=groups;edits.kinematics[objectKey]=k
        }
    }
    /// A distinct pick namespace; these are 13 original guide IDs, not prototype chains.
    public static func pickID(_ target: Int32) -> UInt32 { 0xFC00_0000 | UInt32(bitPattern:target) }
    public static func targetID(fromPick id: UInt32) -> Int32? {
        guard id & 0xFF00_0000 == 0xFC00_0000, id & 0x00FF_FFFF <= 12 else { return nil }
        return Int32(id & 0x00FF_FFFF)
    }
}
