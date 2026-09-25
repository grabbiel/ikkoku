import Foundation
import Testing
import simd
import CoreMath
import Scene
import Studio

@Test func sourceAnimatorMatchesOriginalUnityLocalPoseAndClockWhenSupplied() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["IKKOKU_ORIGINAL_ANIMATOR_REFERENCE"], let catalogFile = env["IKKOKU_STUDIO_ANIMATION_CATALOG"] else { return }
    struct Pose: Decodable {
        let position: [Float], rotation: [Float], scale: [Float]
        var p: Float3 { UnityCoordinates.position(Float3(position[0], position[1], position[2])) }
        var q: simd_quatf { UnityCoordinates.rotation(simd_quatf(vector: Float4(rotation[0],rotation[1],rotation[2],rotation[3]))) }
        var s: Float3 { Float3(scale[0],scale[1],scale[2]) }
        var matrix: float4x4 { Transform.trs(p,q,s) }
    }
    struct Node: Decodable { let sourceID: String, name: String, sourcePath: String, baseline: Pose, expected: Pose }
    struct Case: Decodable { let group: Int32, category: Int32, no: Int32; let height: Float, inputNormalizedTime: Float, speed: Float, deltaTime: Float, normalizedTime: Float; let nodes: [Node] }
    struct Oracle: Decodable { let schemaVersion: Int, cases: [Case] }
    let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let url = URL(fileURLWithPath: catalogFile), catalog = try SourceStudioAnimationCatalog.load(url: url)
    let scene = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    let original = try #require(scene.snapshot.roots[0].character)
    #expect(oracle.schemaVersion == 1 && oracle.cases.count >= 108)
    var maximumMatrixError: Float = 0, maximumClockError: Float = 0, comparisons = 0
    for sample in oracle.cases {
        var state = SourceStudioAnimationState(record: original)
        state.group=sample.group; state.category=sample.category; state.no=sample.no
        state.normalizedTime=sample.inputNormalizedTime; state.speed=sample.speed; state.forceLoop=false
        let animation = try catalog.resolve(state, directory: url.deletingLastPathComponent())
        let rig = try RigDefinition(nodes: sample.nodes.map {
            .init(name: $0.name, sourceID: $0.sourceID, parent: nil, translation: $0.baseline.p, rotation: $0.baseline.q, scale: $0.baseline.s)
        }, skins: [])
        let clock = try animation.clock(state: state, elapsed: sample.deltaTime, height: sample.height)
        maximumClockError = max(maximumClockError, abs(clock.normalizedTime - sample.normalizedTime))
        // Use Unity's reported normalized time to isolate curve application
        // from clock rounding, then check the clock independently above.
        let pose = try animation.library.applying(stateID: animation.stateID, normalizedTime: sample.normalizedTime,
            floatParameters: animation.parameters(height: sample.height), to: rig, baseline: rig.restPose, allowingUnbound: true)
        for (i, node) in sample.nodes.enumerated() {
            let expected = node.expected.matrix, actual = pose.localMatrices[i]
            for column in 0..<4 { for row in 0..<4 { maximumMatrixError = max(maximumMatrixError, abs(actual[column][row] - expected[column][row])) } }
            comparisons += 1
        }
    }
    #expect(comparisons > 1000)
    #expect(maximumClockError < 0.000002, "Unity clock error \(maximumClockError)")
    #expect(maximumMatrixError < 0.0001, "Unity local-matrix error \(maximumMatrixError)")
    if let output = env["IKKOKU_ORIGINAL_ANIMATOR_RESULT"] {
        try JSONSerialization.data(withJSONObject: ["cases": oracle.cases.count,"nodes":comparisons,"maximumClockError":maximumClockError,"maximumMatrixError":maximumMatrixError], options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
