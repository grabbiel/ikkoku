import Foundation
import Testing
import simd
import CoreMath
import Scene
import Character

private let defaultClip = #"{"id":"source:100","name":"Goo","loop":true,"startTime":0,"stopTime":0.1666667}"#

private func handJSON(bones: String, clip: String = defaultClip,
                       time: String = #"{"requested":0.107,"clipTime":0.107}"#) -> String {
    #"{"state":"goo","stateIndex":0,"clip":"# + clip
        + #","sampleTime":"# + time
        + #","bones":"# + bones + #"}"#
}

private let defaultHands = """
    {"L":\(handJSON(bones: #"{"palm":{"rotation":[0,0.70710678,0,0.70710678],"position":[1,2,3],"scale":[2,3,4]}}"#)),
     "R":\(handJSON(bones: #"{"finger":{"rotation":[0,0,0,1]}}"#))}
    """

/// Builds a document shaped exactly like `Tools/reverse/studio_hand_animation.py`
/// output so `SourceStudioHandPose.decode` sees the converter's real JSON keys.
private func studioHandDocument(hands: String = defaultHands,
                                kind: String = "ikkoku-studio-hands",
                                scope: String = "default-state-single-clip-generic-transforms",
                                coordinateSpace: String = "unity-left-handed-y-up",
                                schemaVersion: Int = 1,
                                bundleHash: String = String(repeating: "a", count: 64)) -> Data {
    Data("""
    {"schemaVersion":\(schemaVersion),"converterVersion":"1.0.0","kind":"\(kind)",
     "coordinateSpace":"\(coordinateSpace)","scope":"\(scope)",
     "source":{"bundleSHA256":"\(bundleHash)","bundle":"/original/00.unity3d"},
     "hands":\(hands),
     "diagnostics":["Only the default state is projected."]}
    """.utf8)
}

private func studioHandRig(renamed: Bool = false, duplicated: Bool = false) throws -> RigDefinition {
    var nodes: [RigDefinition.Node] = [
        .init(name: "root", sourceID: "root", parent: nil, translation: Float3(0.2, -0.3, 0.4), scale: Float3(2, 1, 3)),
        .init(name: renamed ? "other" : "palm", sourceID: "palm-1", parent: 0),
        .init(name: "finger", sourceID: "finger-1", parent: 1, translation: Float3(0.1, 0.2, -0.3)),
    ]
    if duplicated { nodes.append(.init(name: "palm", sourceID: "palm-2", parent: 0)) }
    return try RigDefinition(nodes: nodes, skins: [])
}

private func studioHandNear(_ actual: float4x4, _ expected: float4x4, tolerance: Float = 0.00001) {
    for column in 0..<4 { for row in 0..<4 { #expect(abs(actual[column][row] - expected[column][row]) < tolerance) } }
}

@Test func studioHandAppliesFrozenPoseAndKeepsBaseValues() throws {
    let rig = try studioHandRig()
    let document = try SourceStudioHandPose.decode(studioHandDocument())
    #expect(document.hands.count == 2 && document.hands["L"]?.state == "goo" && document.hands["R"]?.clip.name == "Goo")
    #expect(document.hands["L"]?.sampleTime.clipTime == 0.107 && document.diagnostics.count == 1)
    let posed = try document.applying(to: rig)
    // Independently derived: the source xyzw (0,√0.5,0,√0.5) is +90° about Unity Y,
    // which the reflection turns into -90° about native Y, and position (1,2,3)
    // flips to (1,2,-3) while scale 4 stays unconverted.
    studioHandNear(posed.localMatrices[1], Transform.trs(Float3(1, 2, -3),
        simd_quatf(angle: -.pi / 2, axis: Float3(0, 1, 0)), Float3(2, 3, 4)))
    // `finger` only records the identity rotation, so its local matrix keeps the
    // authored translation and scale and merely loses its authored rotation.
    studioHandNear(posed.localMatrices[2], Transform.trs(Float3(0.1, 0.2, -0.3), .identity, Float3(1, 1, 1)))
    #expect(posed.localMatrices[0] == rig.restPose.localMatrices[0])
    var basePose = rig.restPose
    let shapedTranslation = Float3(0.4, -0.5, 0.6)
    let shapedScale = Float3(1.2, 0.8, 1.5)
    basePose.localMatrices[2] = Transform.trs(shapedTranslation,
        simd_quatf(angle: .pi / 4, axis: Float3(1, 0, 0)), shapedScale)
    let shaped = try document.applying(to: rig, basePose: basePose)
    studioHandNear(shaped.localMatrices[2], Transform.trs(shapedTranslation, .identity, shapedScale))
    let repeated = try document.applying(to: rig)
    #expect(repeated.localMatrices == posed.localMatrices)
}

@Test func studioHandDocumentValidationRejectsMismatchedDocuments() throws {
    let documents: [(String, Data)] = [
        ("kind", studioHandDocument(kind: "other-kind")),
        ("scope", studioHandDocument(scope: "other")),
        ("space", studioHandDocument(coordinateSpace: "native-right-handed-y-up")),
        ("hands", studioHandDocument(hands:
            #"{"X":"# + handJSON(bones: #"{"palm":{"rotation":[0,0,0,1]}}"#) + #"}"#)),
        ("empty", studioHandDocument(hands: "{}")),
        ("hash", studioHandDocument(bundleHash: String(repeating: "a", count: 63))),
        ("noLoop", studioHandDocument(hands:
            #"{"L":"# + handJSON(bones: #"{"palm":{"rotation":[0,0,0,1]}}"#,
            clip: #"{"id":"source:100","name":"Goo","loop":false,"startTime":0,"stopTime":0.1666667}"#) + #"}"#)),
        ("stopTime", studioHandDocument(hands:
            #"{"L":"# + handJSON(bones: #"{"palm":{"rotation":[0,0,0,1]}}"#,
            time: #"{"requested":0.2,"clipTime":0.2}"#) + #"}"#)),
        ("rotationLength", studioHandDocument(hands:
            #"{"L":"# + handJSON(bones: #"{"palm":{"rotation":[0,0,0,1,0]}}"#) + #"}"#)),
        ("infiniteRotation", studioHandDocument(hands:
            #"{"L":"# + handJSON(bones: #"{"palm":{"rotation":[1e999,0,0,1]}"#) + #"}"#)),
        ("schemaVersion", studioHandDocument(schemaVersion: 2)),
    ]
    for (name, json) in documents {
        #expect(throws: (any Error).self, "\(name) must be rejected") {
            try SourceStudioHandPose.decode(json)
        }
    }
}

@Test func studioHandApplyRejectsMissingAndDuplicateBones() throws {
    let document = try SourceStudioHandPose.decode(studioHandDocument())
    // `palm` appears twice in this rig and `finger` is absent, so neither hand
    // resolves to exactly one node.
    #expect(throws: (any Error).self) { try document.applying(to: studioHandRig(duplicated: true)) }
    #expect(throws: (any Error).self) { try document.applying(to: studioHandRig(renamed: true)) }
}
