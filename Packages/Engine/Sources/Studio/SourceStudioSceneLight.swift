import Foundation
import simd
import CoreMath
import Scene
import Renderer

/// CharaStudio `CameraLightCtrl.LightCalc` applies the scene record's
/// `charaLight` to the scene-static "Directional Chara" light, not a
/// camera-relative one: `transRoot.localRotation` becomes
/// `Quaternion.Euler(rot[0], rot[1], 0)` above the light's own fixed local
/// `Euler(40, 180, 0)` under an identity `StudioScene`, so the world rotation is
/// `Euler(rot[0], rot[1], 0) * Euler(40, 180, 0)` (Unity's Z-X-Y Euler order;
/// captured on the installed player to a 9.7e-06° maximum, see
/// `docs/reference/studio/scene-records.md`). A Unity directional light emits
/// along `rotation * (0, 0, 1)`, and the engine `MainLight` travels along
/// `rotation * (0, 0, -1)`, so converting the world rotation into the engine
/// basis already puts the travel direction on the captured world forward.
public enum SourceStudioSceneLight {
    /// The light's fixed local rotation in the `Light Chara` chain, Unity degrees.
    static let lightLocalEulerDegrees = Float3(40, 180, 0)

    /// The record's color, intensity, shadow flag and `rot` pair as a native
    /// scene-static key light. Color alpha and `shadowStrength` keep the native
    /// defaults; shadow softness and the map light have no native counterpart yet.
    public static func mainLight(from record: KoikatsuSceneLighting) throws -> MainLight {
        var problems: [String] = []
        for index in 0..<4 where !record.color[index].isFinite { problems.append("color[\(index)]") }
        if !record.intensity.isFinite { problems.append("intensity") }
        for index in 0..<2 where !record.rotation[index].isFinite { problems.append("rot[\(index)]") }
        guard problems.isEmpty else {
            throw RigError.invalid("Source character light has non-finite \(problems.joined(separator: ", ")).")
        }
        let rotation = UnityCoordinates.eulerDegrees(Float3(record.rotation.x, record.rotation.y, 0))
            * UnityCoordinates.eulerDegrees(lightLocalEulerDegrees)
        var light = MainLight()
        light.cameraRelative = false
        light.rotation = rotation.eulerXYZ.radiansToDegrees
        light.color = Float3(record.color.x, record.color.y, record.color.z)
        light.intensity = record.intensity
        light.castsShadow = record.shadow
        return light
    }
}
