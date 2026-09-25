import Foundation
import Scene

/// Caller-side assembly choices from ChaControl. A nonzero typeBone changes
/// correction setters on the shared skeleton; it is not a replacement skeleton.
public enum SourceMakerAssemblyOptions {
    public static func body(sex: Int, exType: Int = 0, boneType: Int,
                            correctionData: Data? = nil) throws -> SourceBodyShapePose.Options {
        guard let sourceSex = SourceBodyShapePose.Sex(rawValue: sex), exType == 0,
              Int32(exactly: boneType) != nil else {
            throw RigError.invalid("Unsupported source character assembly identity.")
        }
        guard boneType != 0 else { return .init(sex: sourceSex) }
        guard let correctionData else {
            throw RigError.invalid("A nonzero source body bone type requires its original correction table.")
        }
        let table = try SourceBodyShapeCorrectionTable.decode(correctionData)
        let correction = 1 + table.head.scale.y
        guard correction.isFinite, correction > 0 else {
            throw RigError.invalid("Body correction table has a nonpositive head scale.")
        }
        return .init(sex: sourceSex, boneType: .corrected(table))
    }

    /// ChaControl.UpdateShapeFace writes this to CORRECT_HEAD_DBCOL. This is
    /// independent of the inverse head correction used by face shape setters.
    public static func headColliderScale(boneType: Int) -> Float { boneType == 0 ? 1.2 : 1.08 }
}
