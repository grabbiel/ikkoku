import Foundation
import CryptoKit
import Testing
import Metal
import simd
import Assets
import CoreMath
import Scene
import Studio
import Character
@testable import Renderer

/// ST-C04 expression slice timing probe (opt-in: IKKOKU_EXPRESSION_PERF=1 plus
/// the Studio scenario fixtures). Prints the median CPU cost of one steady
/// `SourceStudioCharacterPreview.frame` call and, once the preview has the
/// face-state entry point, of one accepted expression edit. Run it with
/// `swift test -c release --filter SourceStudioExpressionPerformance`.
private let expressionPerfVariables = ["IKKOKU_EXPRESSION_PERF", "IKKOKU_STUDIO_SCENARIO_SCENE", "IKKOKU_SOURCE_AVATAR",
                                       "IKKOKU_STUDIO_POSE_CONTRACT", "IKKOKU_MAKER_LIBRARY", "IKKOKU_STUDIO_LOOK_SETTINGS"]

private func expressionPerfMedian(_ samples: [UInt64]) -> Double {
    let sorted = samples.sorted()
    return Double(sorted[sorted.count / 2]) / 1000
}

@Test(.enabled(if: (ProcessInfo.processInfo.environment["IKKOKU_EXPRESSION_PERF"] ?? "") == "1"
               && expressionPerfVariables.allSatisfy { (ProcessInfo.processInfo.environment[$0] ?? "").isEmpty == false }
               && MTLCreateSystemDefaultDevice() != nil,
               "Opt-in timing probe: IKKOKU_EXPRESSION_PERF=1 plus the Studio scenario fixtures and a Metal device"))
func sourceStudioExpressionPerformanceProbe() throws {
    let environment = ProcessInfo.processInfo.environment
    let scene = URL(fileURLWithPath: environment["IKKOKU_STUDIO_SCENARIO_SCENE"]!)
    let data = try Data(contentsOf: scene)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let reference = SourceStudioCharacterReference(sceneFile: scene.path, sceneSHA256: hash,
        rigFile: environment["IKKOKU_SOURCE_AVATAR"]!, boneCatalogFile: environment["IKKOKU_STUDIO_POSE_CONTRACT"]!,
        objectKey: 65, makerLibraryFile: environment["IKKOKU_MAKER_LIBRARY"]!,
        animationCatalogFile: environment["IKKOKU_STUDIO_ANIMATION_CATALOG"],
        lookSettingsFile: environment["IKKOKU_STUDIO_LOOK_SETTINGS"]!)
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let preview = try SourceStudioCharacterPreview(reference: reference, resources: resources)
    let camera = OrbitCamera(), light = MainLight(), effects = SceneEffects()
    for _ in 0..<20 { _ = try preview.frame(camera: camera, mainLight: light, effects: effects, world: matrix_identity_float4x4, objectID: 1) }
    var frames: [UInt64] = []
    for _ in 0..<300 {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try preview.frame(camera: camera, mainLight: light, effects: effects, world: matrix_identity_float4x4, objectID: 1)
        frames.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    print("[expression-perf] steady frame median \(expressionPerfMedian(frames)) us over \(frames.count) calls")
    // One accepted State-panel edit (alternating mouth pattern + openness),
    // the call the inspector and the scenario make; then the same steady
    // frame with the edited state.
    let saved = preview.savedExpression
    var edited = saved; edited.mouthPattern = saved.mouthPattern == 6 ? 7 : 6; edited.mouthOpen = 0.5
    var edits: [UInt64] = []
    for index in 0..<400 {
        let state = index % 2 == 0 ? edited.settled(from: saved) : saved
        let start = DispatchTime.now().uptimeNanoseconds
        try preview.setExpressionState(state)
        edits.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    // A neck pattern edit, which also re-resolves the neck look.
    var necks: [UInt64] = []
    for index in 0..<200 {
        let state = preview.expressionState
        let next = state.neckLookPattern == 4 ? 1 : 4
        var changed = state; changed.neckLookPattern = next
        let start = DispatchTime.now().uptimeNanoseconds
        try preview.setExpressionState(changed)
        necks.append(DispatchTime.now().uptimeNanoseconds - start)
        _ = index
    }
    try preview.setExpressionState(edited)
    var editedFrames: [UInt64] = []
    for _ in 0..<300 {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try preview.frame(camera: camera, mainLight: light, effects: effects, world: matrix_identity_float4x4, objectID: 1)
        editedFrames.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    print("[expression-perf] expression edit median \(expressionPerfMedian(edits)) us, neck-pattern edit median \(expressionPerfMedian(necks)) us, edited steady frame median \(expressionPerfMedian(editedFrames)) us")
}
