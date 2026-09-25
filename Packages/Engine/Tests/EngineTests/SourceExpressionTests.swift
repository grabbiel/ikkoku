import Foundation
import Testing
import simd
import Assets
import CoreMath
@testable import Character
@testable import Scene

private func expressionDocument() -> [String: Any] {
    let inputs: [String: Any] = [
        "eyebrowPattern": 0, "eyesPattern": 0, "mouthPattern": 0,
        "eyebrowOpenRate": 1, "eyesOpenRate": 1, "mouthOpenRate": 0,
        "eyebrowOpenMax": 1, "eyesOpenMax": 0.92, "mouthOpenMax": 1,
        "blinkRate": 1, "mouthFixedRate": -1,
    ]
    let controllers: [[String: Any]] = ["eyebrow", "eyes", "mouth"].enumerated().map { offset, id in
        let close = offset * 2, open = close + 1
        func channel(_ index: Int) -> [String: Any] {
            ["index": index, "name": "channel-\(index)", "frameIndex": index, "frameWeight": 100]
        }
        return ["id": id, "openMin": 0, "openMax": 1, "fixedRate": -0.1,
                "syncBlink": id == "eyebrow", "sourcePatternCount": 2,
                "targets": [["nodeName": "face-node", "meshName": "face", "meshSourceID": "synthetic:1",
                             "channelCount": 7, "controlledChannelIndices": [close, open],
                             "patterns": [["index": 0, "close": channel(close), "open": channel(open)],
                                          ["index": 1, "close": channel(close), "open": channel(close)]]]]]
    }
    return ["schemaVersion": 1, "weightUnit": "percent", "transitionSeconds": 0.15,
            "updateOrder": ["eyebrow", "eyes", "mouth"], "controllers": controllers,
            "defaults": inputs, "presets": []]
}

private func expressionContract(_ document: [String: Any] = expressionDocument()) throws -> SourceExpressionContract {
    try SourceExpressionContract.decode(JSONSerialization.data(withJSONObject: document))
}

private func expressionSource(wrongChannelName: Bool = false) throws -> SourceRig {
    let rig = try RigDefinition(nodes: [
        .init(name: "root", sourceID: "root", parent: nil),
        .init(name: "face-node", sourceID: "face-node", parent: 0),
    ], skins: [.init(name: "face", meshNode: 1, joints: [0], inverseBindMatrices: [matrix_identity_float4x4])])
    let targets: [MeshData.MorphTarget] = (0..<7).map { index in
        .init(name: wrongChannelName && index == 2 ? "wrong-channel" : "channel-\(index)",
              positionDeltas: [.zero], normalDeltas: [.zero])
    }
    // Two draw parts share a skin, as an eyeline material overlay does in the real head.
    let parts = (0..<2).map { index in
        SourceRig.Part(mesh: .init(name: "face/\(index)", positions: [.zero], normals: [Float3(0, 1, 0)],
            joints: [.zero], weights: [Float4(1, 0, 0, 0)], indices: [0, 0, 0], morphTargets: targets),
            node: 1, skin: 0, rendererEnabled: true)
    }
    return SourceRig(sourcePrefab: "synthetic", rig: rig, parts: parts, morphChannelCount: 7)
}

private func expressionDense(_ weights: [(index: Int, weight: Float)], count: Int = 7) -> [Float] {
    var result = Array(repeating: Float.zero, count: count)
    for entry in weights { result[entry.index] = entry.weight }
    return result
}

private func expressionNear(_ actual: [Float], _ expected: [Float]) {
    #expect(actual.count == expected.count)
    for (a, b) in zip(actual, expected) { #expect(abs(a - b) < 0.000001) }
}

@Test func sourceExpressionQuantizesBeforeNormalizationAndSynchronizesBlink() throws {
    let contract = try expressionContract(), source = try expressionSource()
    let quantizationCases: [(Float, Float)] = [(0.009, 0), (0.01, 1), (0.999, 99)]
    for (rate, percent) in quantizationCases {
        var inputs = contract.defaults
        inputs.mouthOpenRate = rate
        let weights = try contract.weights(source: source, inputs: inputs)
        #expect(weights.count == 2)
        for part in source.parts {
            expressionNear(expressionDense(try #require(weights[part.mesh.name])),
                           [0, 1, 0.08, 0.92, (100 - percent) / 100, percent / 100, 0])
        }
    }
    var inputs = contract.defaults
    inputs.eyesOpenRate = 0
    inputs.eyebrowOpenRate = 0
    inputs.blinkRate = 0.5
    let half = try contract.weights(source: source, inputs: inputs)
    expressionNear(expressionDense(try #require(half["face/0"])), [0.5, 0.5, 0.54, 0.46, 1, 0, 0])
    inputs.blinkRate = -1
    inputs.eyebrowOpenRate = 1
    let retained = try contract.weights(source: source, inputs: inputs)
    expressionNear(expressionDense(try #require(retained["face/0"])), [0, 1, 1, 0, 1, 0, 0])
}

@Test func sourceExpressionCombinesControllersAndAccumulatesSharedEndpointsDuringTransition() throws {
    let contract = try expressionContract(), source = try expressionSource()
    var inputs = contract.defaults
    inputs.eyesPattern = 1
    inputs.mouthOpenRate = 1
    let closed = try contract.weights(source: source, inputs: inputs)
    expressionNear(expressionDense(try #require(closed["face/0"])), [0, 1, 1, 0, 0, 1, 0])
    let transition = try contract.weights(source: source, inputs: inputs, previous: contract.defaults, transition: 0.5)
    // Current openness applies to both old and new patterns. Mouth is open on both
    // sides of this transition, even though the previous input's voice rate was zero.
    expressionNear(expressionDense(try #require(transition["face/0"])), [0, 1, 0.54, 0.46, 0, 1, 0])
    inputs.mouthFixedRate = 0.5
    inputs.mouthOpenRate = 0
    let fixed = try contract.weights(source: source, inputs: inputs)
    expressionNear(expressionDense(try #require(fixed["face/0"])), [0, 1, 1, 0, 0.5, 0.5, 0])
    #expect(try #require(fixed["face/0"]).allSatisfy { $0.index != 6 }) // Uncontrolled channel remains untouched.
}

@Test func sourceExpressionUsesTheSelectedHeadsSerializedEyeLimit() throws {
    var document = expressionDocument()
    document["eyesOpenMaxCap"] = Float(0.9)
    let contract = try expressionContract(document)
    let weights = try contract.weights(source: expressionSource(), inputs: contract.defaults)
    expressionNear(expressionDense(try #require(weights["face/0"])), [0, 1, 0.1, 0.9, 1, 0, 0])
    for invalid in [Float(-0.1), Float(1.1)] {
        document["eyesOpenMaxCap"] = invalid
        #expect(throws: RigError.self) { try expressionContract(document) }
    }
}

@Test func sourceExpressionRejectsChangedChannelIdentityAndInvalidInputs() throws {
    let contract = try expressionContract(), source = try expressionSource()
    #expect(throws: RigError.self) { try contract.weights(source: expressionSource(wrongChannelName: true), inputs: contract.defaults) }
    var invalid = contract.defaults
    invalid.eyesPattern = 2
    #expect(throws: RigError.self) { try contract.weights(source: source, inputs: invalid) }
    invalid = contract.defaults
    invalid.mouthOpenRate = .nan
    #expect(throws: RigError.self) { try contract.weights(source: source, inputs: invalid) }
    #expect(throws: RigError.self) { try contract.weights(source: source, inputs: contract.defaults, transition: -.infinity) }
    var document = expressionDocument()
    document["updateOrder"] = ["eyes", "eyebrow", "mouth"]
    #expect(throws: RigError.self) { try expressionContract(document) }
    document = expressionDocument()
    var controllers = try #require(document["controllers"] as? [[String: Any]])
    var targets = try #require(controllers[0]["targets"] as? [[String: Any]])
    targets[0]["controlledChannelIndices"] = [0]
    controllers[0]["targets"] = targets
    document["controllers"] = controllers
    #expect(throws: RigError.self) { try expressionContract(document) }
}

private struct ExpressionReference: Decodable {
    struct Mesh: Decodable {
        let nodeName: String, meshName: String
        let weights: [Float]
        let activeChannelCount: Int
    }
    struct Case: Decodable {
        let id: String, inputs: SourceExpressionInputs
        let previousInputs: SourceExpressionInputs?
        let transitionProgress: Float?
        let meshes: [Mesh]
    }
    let schemaVersion: Int, weightUnit: String
    let cases: [Case]
}

@Test(.enabled(if: ["IKKOKU_EXPRESSION_CONTRACT", "IKKOKU_EXPRESSION_REFERENCE", "IKKOKU_SOURCE_AVATAR"]
    .allSatisfy { ProcessInfo.processInfo.environment[$0] != nil }))
func sourceExpressionMatchesIndependentLocalOracleForEveryImportedPart() throws {
    let environment = ProcessInfo.processInfo.environment
    func data(_ key: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #require(environment[key])))
    }
    let contract = try SourceExpressionContract.decode(data("IKKOKU_EXPRESSION_CONTRACT"))
    let source = try SourceRig.loadModel(url: URL(fileURLWithPath: #require(environment["IKKOKU_SOURCE_AVATAR"])))
    let reference = try JSONDecoder().decode(ExpressionReference.self, from: data("IKKOKU_EXPRESSION_REFERENCE"))
    #expect(reference.schemaVersion == 1 && reference.weightUnit == "percent")
    #expect(Set(reference.cases.map(\.id)) == ["defaults", "blinkClosed", "blinkHalf", "smile", "smileMouthOpen",
        "softSmile", "mouthQuantization009", "mouthQuantization01", "mouthQuantization999", "fixedMouthHalf",
        "smileTransitionHalf", "explicitClosedEyesSameChannel"])
    for example in reference.cases {
        #expect(example.meshes.count == 13)
        let actual = try contract.weights(source: source, inputs: example.inputs,
            previous: example.previousInputs, transition: example.transitionProgress ?? 1)
        var matchedParts = Set<String>(), missingMeshes = Set<String>()
        for expected in example.meshes {
            let parts = source.parts.filter { source.rig.skins[$0.skin].name == expected.meshName }
            if parts.isEmpty { missingMeshes.insert(expected.meshName) }
            #expect(expected.activeChannelCount == expected.weights.filter { $0 != 0 }.count)
            for part in parts {
                matchedParts.insert(part.mesh.name)
                #expect(source.rig.nodes[part.node].name == expected.nodeName)
                #expect(part.mesh.morphTargets.count == expected.weights.count)
                let entries = try #require(actual[part.mesh.name])
                #expect(entries.count == expected.activeChannelCount)
                let dense = expressionDense(entries, count: expected.weights.count)
                for index in expected.weights.indices {
                    #expect(abs(dense[index] - expected.weights[index] / 100) < 0.000001,
                            "\(example.id), \(part.mesh.name), channel \(index)")
                }
            }
        }
        // The assembled ordinary preview omits tears; a full head fixture keeps them.
        #expect(missingMeshes.isSubset(of: ["cf_O_namida_L", "cf_O_namida_M", "cf_O_namida_S"]))
        #expect(!matchedParts.isEmpty && Set(actual.keys) == matchedParts)
    }
}
