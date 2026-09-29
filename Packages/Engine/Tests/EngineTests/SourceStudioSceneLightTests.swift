import Foundation
import Testing
import simd
import CoreMath
import Scene
import Renderer
@testable import Studio

/// The four rot pairs, their captured world forwards and the fixture metadata
/// (one default startup scene, the installed CharaStudio 1.0.4.2) live in
/// `docs/reference/studio/scene-records.md` "Character light": the world
/// forward column, reflected to the engine basis (Z negated once) the way the
/// importer reflects every raw Unity direction.
@Test func sourceStudioSceneLightMatchesCapturedWorldForwards() throws {
    let captured: [(rot: SIMD2<Float>, forward: Float3)] = [
        ([0, 0], [0.0000, -0.6428, 0.7660]),
        ([30, -45], [0.6964, -0.1736, 0.6964]),
        ([-20, 90], [-0.5000, -0.8660, 0.0000]),
        ([10, 180], [0.0000, -0.5000, -0.8660]),
    ]
    for case let (rot, expected) in captured {
        let light = try SourceStudioSceneLight.mainLight(from:
            KoikatsuSceneLighting(color: SIMD4(1, 1, 1, 1), intensity: 1, rotation: rot, shadow: true, type: nil))
        #expect(light.cameraRelative == false)
        #expect(length(light.direction - expected) < 1e-4, "rot \(rot)")
    }
}

@Test func sourceStudioSceneLightDefaultsMapToTheFixedChainForward() throws {
    let light = try SourceStudioSceneLight.mainLight(from:
        KoikatsuSceneLighting(color: SIMD4(1, 1, 1, 1), intensity: 1, rotation: [0, 0], shadow: true, type: nil))
    // rot (0, 0) leaves only the light's fixed local Euler(40, 180, 0): the
    // analytic Unity world forward (0, -sin 40°, -cos 40°), reflected to the engine basis.
    let radians = Float(40).degreesToRadians
    #expect(length(light.direction - Float3(0, -sin(radians), cos(radians))) < 1e-6)
    #expect(light.color == Float3(1, 1, 1) && light.intensity == 1 && light.castsShadow)
}

@Test func sourceStudioSceneLightCopiesColorIntensityAndShadowFlag() throws {
    let light = try SourceStudioSceneLight.mainLight(from:
        KoikatsuSceneLighting(color: SIMD4(0.9, 0.7, 0.5, 1), intensity: 1.3, rotation: [30, -45], shadow: false, type: nil))
    #expect(light.color == Float3(0.9, 0.7, 0.5) && light.intensity == 1.3 && !light.castsShadow)
}

@Test func sourceStudioSceneLightRejectsNonFiniteFields() {
    let good = KoikatsuSceneLighting(color: SIMD4(1, 1, 1, 1), intensity: 1, rotation: [0, 0], shadow: true, type: nil)
    for color in [SIMD4<Float>(.nan, 1, 1, 1), SIMD4(1, 1, 1, .nan)] {
        #expect(throws: RigError.self) {
            try SourceStudioSceneLight.mainLight(from: KoikatsuSceneLighting(color: color, intensity: 1, rotation: [0, 0], shadow: true, type: nil))
        }
    }
    for intensity in [Float.nan, Float.infinity] {
        #expect(throws: RigError.self) {
            try SourceStudioSceneLight.mainLight(from: KoikatsuSceneLighting(color: good.color, intensity: intensity, rotation: [0, 0], shadow: true, type: nil))
        }
    }
    for rot in [SIMD2<Float>(.nan, 0), SIMD2(0, .nan)] {
        #expect(throws: RigError.self) {
            try SourceStudioSceneLight.mainLight(from: KoikatsuSceneLighting(color: good.color, intensity: 1, rotation: rot, shadow: true, type: nil))
        }
    }
}
