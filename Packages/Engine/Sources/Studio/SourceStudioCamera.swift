import Foundation
import CoreMath
import Scene
import simd

extension KoikatsuCameraRecord {
    /// CameraControl.LateUpdate: rotation = Euler(rotate), position =
    /// rotation * distance + pos. Keep the full distance vector and camera roll.
    public func nativeCamera() throws -> OrbitCamera {
        guard (0..<3).allSatisfy({ position[$0].isFinite && rotationDegrees[$0].isFinite && distance[$0].isFinite }),
              fieldOfView.isFinite, fieldOfView > 0, fieldOfView < 180 else {
            throw RigError.invalid("Source camera has invalid finite vectors or field of view.")
        }
        let orientation = UnityCoordinates.eulerDegrees(rotationDegrees)
        let eye = UnityCoordinates.position(position) + orientation.act(UnityCoordinates.position(distance))
        let forward = orientation.act(Float3(0, 0, -1))
        var camera = OrbitCamera()
        camera.distance = max(length(distance), 0.001)
        camera.target = eye + forward * camera.distance
        camera.yaw = atan2(-forward.x, -forward.z)
        camera.pitch = asin(min(max(-forward.y, -1), 1))
        camera.fovDegrees = fieldOfView
        camera.orientationOverride = orientation.vector
        return camera
    }
}

extension OrbitCamera {
    /// Use only for an edited camera. Unedited source records retain their
    /// original pivot, full distance vector and Euler representation verbatim.
    public func sourceCameraRecord() -> KoikatsuCameraRecord {
        KoikatsuCameraRecord(position: UnityCoordinates.position(target),
            rotationDegrees: UnityCoordinates.sourceEulerDegrees(viewMatrix().inverse.rotationQuaternion),
            distance: Float3(0, 0, -distance), fieldOfView: fovDegrees)
    }
}
