import CoreMath
import Scene
import simd

/// The Studio `GuideObject.LateUpdate` scale rule for source-scene hierarchies
/// (ST-A06, captured in `camera-object-reference.json`): every guide rescales
/// its transform so its world scale equals its own `changeAmount.scale` when
/// it is scalable and `(1, 1, 1)` when it is not, so scale never compounds
/// down the chain and a folder's authored scale is never applied. A child's
/// world position still composes through the parent's actual world matrix, so
/// a scalable parent does move its children.
public enum SourceStudioWorldTransform {
    /// Characters and items carry `enableScale`; folders, cameras, lights and
    /// routes do not. Items always count as scalable: the original also
    /// consults the catalog's `isScale` flag, which the importer has no form
    /// of, and the UI cannot give a non-scalable item a scale other than 1.
    public static func isScalable(_ kind: KoikatsuObjectKind) -> Bool {
        kind == .character || kind == .item
    }

    /// The world matrix of one source object from its parent's world matrix
    /// and its own authored local transform, already converted to the engine
    /// basis. Position and rotation compose through `parentFrame` (the
    /// rotation scale-free, so non-uniform parent scale cannot shear the
    /// child); only the world scale is the object's own.
    public static func world(parentFrame: float4x4, localPosition: Float3, localRotation: simd_quatf,
                             localScale: Float3, scalable: Bool) throws -> float4x4 {
        let columns = [parentFrame.columns.0, parentFrame.columns.1, parentFrame.columns.2, parentFrame.columns.3]
        guard columns.allSatisfy({ column in (0..<4).allSatisfy({ column[$0].isFinite }) }),
              (0..<3).allSatisfy({ localPosition[$0].isFinite && localScale[$0].isFinite }),
              (0..<4).allSatisfy({ localRotation.vector[$0].isFinite }),
              [parentFrame.columns.0, parentFrame.columns.1, parentFrame.columns.2]
                .allSatisfy({ length(Float3($0.x, $0.y, $0.z)) >= 1e-6 }) else {
            throw RigError.invalid("Source world transform has non-finite or degenerate input.")
        }
        let position = parentFrame.transformPoint(localPosition)
        let rotation = parentFrame.rotationQuaternion * localRotation
        let scale = scalable ? localScale : Float3(repeating: 1)
        return Transform.trs(position, rotation, scale)
    }

    /// The exact inverse of `world` for position and rotation: the authored
    /// local values a source object must carry so its current Studio-rule
    /// world pose survives a move under `parentFrame`. Position undoes the
    /// full frame (its scale still moves the child); rotation undoes only the
    /// scale-free parent rotation, so a non-uniformly scaled parent cannot
    /// shear or scale-compound the result the native TRS walk would.
    public static func local(world: (position: Float3, rotation: simd_quatf), parentFrame: float4x4) throws
        -> (position: Float3, rotation: simd_quatf) {
        let columns = [parentFrame.columns.0, parentFrame.columns.1, parentFrame.columns.2, parentFrame.columns.3]
        guard columns.allSatisfy({ column in (0..<4).allSatisfy({ column[$0].isFinite }) }),
              (0..<3).allSatisfy({ world.position[$0].isFinite }),
              (0..<4).allSatisfy({ world.rotation.vector[$0].isFinite }),
              [parentFrame.columns.0, parentFrame.columns.1, parentFrame.columns.2]
                .allSatisfy({ length(Float3($0.x, $0.y, $0.z)) >= 1e-6 }) else {
            throw RigError.invalid("Source local transform has non-finite or degenerate input.")
        }
        let position = parentFrame.inverse.transformPoint(world.position)
        let rotation = parentFrame.rotationQuaternion.inverse * world.rotation
        return (position, rotation)
    }

    /// The editor reparenting rule (ST-T15): a source object moved under a new
    /// parent keeps its Studio-rule world pose by re-authoring position and
    /// quaternion under `parentFrame` — the exact inverse of `world`, so the
    /// imported quaternion survives as an exact `rotationOverride` instead of
    /// an Euler decomposition — while its own authored scale is kept (world
    /// scale is the object's own under the rule) and a former attachment point
    /// is dropped: the new parent is not an attachment and leaving the point
    /// set would make `sourceWorldMatrix` reject the object outright.
    public static func reparented(_ object: StudioObject, world: float4x4, parentFrame: float4x4) throws
        -> StudioObject {
        let local = try self.local(world: (world.translation, world.rotationQuaternion), parentFrame: parentFrame)
        var reparented = object
        reparented.transform.position = local.position
        reparented.transform.rotation = local.rotation.eulerXYZ.radiansToDegrees
        reparented.transform.rotationOverride = local.rotation.vector
        reparented.sourceAttachmentPoint = nil
        return reparented
    }
}
