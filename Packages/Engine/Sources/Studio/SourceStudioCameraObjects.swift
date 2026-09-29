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
    public static func viewCamera(world: float4x4, base: OrbitCamera) throws -> OrbitCamera {
        let columns = [world.columns.0, world.columns.1, world.columns.2]
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy({ world[c][$0].isFinite }) }),
              columns.allSatisfy({ length(Float3($0.x, $0.y, $0.z)) >= 1e-6 }) else {
            throw RigError.invalid("Source camera object has a non-finite or degenerate world matrix.")
        }
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
        return camera
    }
}
