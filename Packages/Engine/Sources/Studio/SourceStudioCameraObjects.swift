import Foundation
import CoreMath
import Scene
import simd

/// Camera objects (`KoikatsuObjectKind.camera`) in a source scene. The scene
/// camera itself is `source.settings.camera`; these are extra in-scene objects
/// that `ChangeCamera` switches the render camera through.
public enum SourceStudioCameraObjects {
    /// `ChangeCamera(camera, record.active)` runs for every camera record in
    /// CharaStudio's load order (depth-first in file order, same pre-order the
    /// importer walks), and each call with `active == true` deactivates the
    /// previously active camera first, so after the load the active camera
    /// object is the last active record in that order.
    public static func activeAtLoad(_ snapshot: KoikatsuSceneSnapshot) -> Int32? {
        var active: Int32?
        for root in snapshot.roots { walk(root, active: &active) }
        return active
    }

    private static func walk(_ record: KoikatsuObjectRecord, active: inout Int32?) {
        if record.kind == .camera, record.cameraActive == true { active = record.sourceKey }
        for child in record.children { walk(child, active: &active) }
        if let character = record.character {
            for key in character.accessoryChildren.keys.sorted() {
                for child in character.accessoryChildren[key] ?? [] { walk(child, active: &active) }
            }
        }
    }

    /// The preview camera looking through a source camera object: `world` is
    /// the object's native world matrix, whose translation and rotation the
    /// active `OCICamera`'s LateUpdate subscription copies onto the render
    /// camera every frame (scale is ignored and the field of view stays the
    /// scene camera's).
    ///
    /// R4: a mirrored `world` (negative determinant) throws
    /// `SourceStudioCameraObjectError.reflectedFrame("world frame")`. A
    /// singular basis, and a result that fails `OrbitCamera.validate()` (for
    /// example a world rotation that is not a unit quaternion, or an invalid
    /// `base` lens), throw `RigError`. Accepted input gives exactly the former
    /// result.
    public static func viewCamera(world: float4x4, base: OrbitCamera) throws -> OrbitCamera {
        let columns = [world.columns.0, world.columns.1, world.columns.2]
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy({ world[c][$0].isFinite }) }),
              columns.allSatisfy({ length(Float3($0.x, $0.y, $0.z)) >= 1e-6 }) else {
            throw RigError.invalid("Source camera object has a non-finite or degenerate world matrix.")
        }
        // `rotationQuaternion` divides by unsigned column lengths, so a mirrored
        // basis would become a nonunit quaternion that is no rotation at all.
        let determinant = simd_determinant(world.upperLeft3x3)
        guard determinant.isFinite, determinant != 0 else {
            throw RigError.invalid("Source camera object has a singular world matrix.")
        }
        guard determinant > 0 else { throw SourceStudioCameraObjectError.reflectedFrame("world frame") }
        let position = world.translation
        let orientation = world.rotationQuaternion
        let forward = orientation.act(Float3(0, 0, -1))
        var camera = OrbitCamera()
        camera.distance = max(base.distance, 0.001)
        camera.target = position + forward * camera.distance
        // `yaw`/`pitch` must be set before `orientationOverride`, whose
        // `didSet` would clear it (as in `nativeCamera()`).
        camera.yaw = atan2(-forward.x, -forward.z)
        camera.pitch = asin(min(max(-forward.y, -1), 1))
        camera.fovDegrees = base.fovDegrees
        camera.near = base.near
        camera.orientationOverride = orientation.vector
        try camera.validate()
        return camera
    }

    /// The look-through camera of a source camera object from the frame its
    /// own transform composes under (`parentFrame`: identity for a root, a
    /// route's `childRoot`, or the parent's world matrix times an attachment
    /// frame) and its authored local position and rotation in the engine
    /// basis. Cameras are not scalable, so this is `viewCamera(world:base:)`
    /// of `SourceStudioWorldTransform.world(parentFrame:…, scalable: false)`.
    ///
    /// R4: a mirrored `parentFrame` (negative determinant) throws
    /// `SourceStudioCameraObjectError.reflectedFrame("parent frame")`. The
    /// Studio walk composes a child's rotation with the parent frame's
    /// `rotationQuaternion`, which a mirrored frame turns into a nonunit
    /// quaternion, so the composed camera world matrix no longer shows the
    /// mirror; checking the parent frame catches it before that composition.
    public static func viewCamera(parentFrame: float4x4, localPosition: Float3, localRotation: simd_quatf,
                                  base: OrbitCamera) throws -> OrbitCamera {
        let entries = (0..<4).allSatisfy { c in (0..<4).allSatisfy { parentFrame[c][$0].isFinite } }
        if entries, simd_determinant(parentFrame.upperLeft3x3) < 0 {
            throw SourceStudioCameraObjectError.reflectedFrame("parent frame")
        }
        let world = try SourceStudioWorldTransform.world(parentFrame: parentFrame, localPosition: localPosition,
                                                         localRotation: localRotation, localScale: Float3(repeating: 1),
                                                         scalable: false)
        return try viewCamera(world: world, base: base)
    }
}

/// Defined failures of source camera-object look-through (R4).
public enum SourceStudioCameraObjectError: Error, Equatable, CustomStringConvertible {
    /// The camera's world frame, or the parent frame it composes under, is
    /// mirrored (negative determinant). The original copies the camera's
    /// `transform.rotation`, which the capture shows is unaffected by a
    /// non-uniform parent scale. A mirrored matrix does not say which axis
    /// carries the mirror, so it does not determine that rotation, and no
    /// original capture covers a mirrored parent.
    case reflectedFrame(String)

    public var description: String {
        switch self {
        case .reflectedFrame(let frame):
            return "Source camera object \(frame) is mirrored, so its look-through rotation is undefined."
        }
    }
}
