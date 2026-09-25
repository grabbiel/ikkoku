import Foundation
import Testing
import Character

private func shapeFixture() -> [String: Any] {
    let first: [String: Any] = ["sourceName": "controller", "sourceIndex": 0,
                               "positionMask": [true, false, false], "rotationMask": [false, false, true],
                               "scaleMask": [true, false, false]]
    let second: [String: Any] = ["sourceName": "controller", "sourceIndex": 0,
                                "positionMask": [false, true, false], "rotationMask": [false, false, false],
                                "scaleMask": [false, false, false]]
    let samples: [[String: Any]] = [
        ["key": 7, "position": [0, 20, 30], "rotationDegrees": [350, 0, 350], "scale": [1, 1, 1]],
        ["key": 50, "position": [10, 40, 50], "rotationDegrees": [10, 180, 10], "scale": [2, 2, 2]],
        ["key": 999, "position": [20, 60, 70], "rotationDegrees": [170, 0, 170], "scale": [3, 3, 3]],
    ]
    let target: [String: Any] = ["sourceName": "controller", "destinationName": "actual_bone",
                                "positionMask": [true, true, false], "rotationMask": [false, false, true],
                                "scaleMask": [true, false, false]]
    let domain: [String: Any] = [
        "id": "test", "valueCount": 2, "defaultValues": [0.5, 0.25],
        "sourceNames": ["controller"], "destinationNames": ["actual_bone", "unported_bone"],
        "slots": [["index": 0, "label": "X", "bindings": [first]], ["index": 1, "label": "Y", "bindings": [second]]],
        "channels": [["name": "controller", "samples": samples]],
        "directTargets": [target], "unportedDestinationNames": ["unported_bone"],
    ]
    return ["schemaVersion": 1, "coordinateSystem": "UnityLeftHandedYUp", "rotationUnit": "degrees",
            "valueRange": [0, 1], "domains": [domain]]
}

private func fixtureContract() throws -> SourceShapeContract {
    try SourceShapeContract.decode(JSONSerialization.data(withJSONObject: shapeFixture()))
}

@Test func sourceShapeSamplesArrayIndicesAndShortestEulerArc() throws {
    let domain = try #require(fixtureContract().domain("test"))
    let low = try domain.sample(channelName: "controller", rate: 0)
    #expect(low.rotationDegrees.x == 350)
    let quarter = try domain.sample(channelName: "controller", rate: 0.25)
    #expect(quarter.position == SIMD3<Float>(5, 30, 40))
    #expect(quarter.scale == SIMD3<Float>(1.5, 1.5, 1.5))
    #expect(quarter.rotationDegrees == SIMD3<Float>(360, 90, 360))
    let high = try domain.sample(channelName: "controller", rate: 0.75)
    #expect(high.rotationDegrees == SIMD3<Float>(90, 270, 90)) // Exactly 180° follows positive arc.
    #expect(try domain.sample(channelName: "controller", rate: 1).rotationDegrees.x == 170)
}

@Test func sourceShapeMasksPreserveOtherSlotsAndUntouchedAxes() throws {
    let domain = try #require(fixtureContract().domain("test"))
    var state = try domain.makeState()
    #expect(state["controller"]?.position == SIMD3<Float>(10, 30, 0))
    #expect(state["controller"]?.scale == SIMD3<Float>(2, 1, 1))
    try domain.apply(slot: 0, value: 1, to: &state)
    #expect(state["controller"]?.position == SIMD3<Float>(20, 30, 0))
    #expect(state["controller"]?.scale == SIMD3<Float>(3, 1, 1))
    let updates = try domain.destinationUpdates(from: state)
    #expect(updates.count == 1)
    #expect(updates[0].destinationName == "actual_bone")
    #expect(updates[0].positionMask == [true, true, false])
    #expect(domain.unportedDestinationNames == ["unported_bone"])
}

@Test func sourceShapeRejectsInvalidInputWithoutMutatingState() throws {
    let domain = try #require(fixtureContract().domain("test"))
    var state = try domain.makeState()
    let before = state
    for value: Float in [-0.1, 1.1, .nan, .infinity] {
        #expect(throws: SourceShapeError.invalidRate) { try domain.apply(slot: 0, value: value, to: &state) }
        #expect(state == before)
    }
    #expect(throws: SourceShapeError.invalidSlot(-1)) { try domain.apply(slot: -1, value: 0, to: &state) }
    #expect(throws: SourceShapeError.missingChannel("missing")) { try domain.sample(channelName: "missing", rate: 0.5) }
    #expect(throws: SourceShapeError.self) { try domain.makeState(values: [0.5]) }
    state.removeValue(forKey: "controller")
    #expect(throws: SourceShapeError.incompleteState("controller")) { try domain.apply(slot: 0, value: 0.5, to: &state) }
    #expect(state.isEmpty)
}

@Test func sourceShapeContractValidatesDimensionsReferencesAndCoverage() throws {
    let fixture = shapeFixture()
    let original = try #require((fixture["domains"] as? [[String: Any]])?.first)
    var invalidDomains: [[String: Any]] = []
    var invalid = original; invalid["defaultValues"] = [0.5]; invalidDomains.append(invalid)
    invalid = original; invalid["sourceNames"] = ["different"]; invalidDomains.append(invalid)
    invalid = original; invalid["unportedDestinationNames"] = []; invalidDomains.append(invalid)
    invalid = original; invalid["unportedDestinationNames"] = ["actual_bone", "unported_bone"]; invalidDomains.append(invalid)
    invalid = original; invalid["channels"] = [["name": "controller", "samples": []]]; invalidDomains.append(invalid)
    invalid = original
    invalid["channels"] = [["name": "controller", "samples": [["key": 0, "position": [0, 0], "rotationDegrees": [0, 0, 0], "scale": [1, 1, 1]]]]]
    invalidDomains.append(invalid)
    for domain in invalidDomains {
        var data = fixture; data["domains"] = [domain]
        let bytes = try JSONSerialization.data(withJSONObject: data)
        #expect(throws: SourceShapeError.self) { try SourceShapeContract.decode(bytes) }
        // Domain decoding itself is validated; callers cannot bypass root validation.
        #expect(throws: SourceShapeError.self) { try JSONDecoder().decode(SourceShapeDomain.self, from: JSONSerialization.data(withJSONObject: domain)) }
    }
    var wrongVersion = fixture; wrongVersion["schemaVersion"] = 2
    #expect(throws: SourceShapeError.self) { try SourceShapeContract.decode(JSONSerialization.data(withJSONObject: wrongVersion)) }
}

@Test func sourceShapeContractCodableRoundTrip() throws {
    let contract = try fixtureContract()
    let restored = try SourceShapeContract.decode(JSONEncoder().encode(contract))
    #expect(try restored.domain("test")?.makeState() == contract.domain("test")?.makeState())
}

@Test func sourceShapeLoadsLocalRecoveredContractWhenRequested() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_SHAPE_CONTRACT"] else { return }
    let contract = try SourceShapeContract.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    let body = try #require(contract.domain("body")), face = try #require(contract.domain("face"))
    #expect(body.valueCount == 44 && face.valueCount == 52)
    #expect(body.channels.count == 119 && face.channels.count == 89)
    #expect(body.channels.allSatisfy { $0.samples.count == 25 })
    #expect(face.channels.allSatisfy { $0.samples.count == 25 })
    for domain in contract.domains {
        for value: Float in [0, 0.5, 1] {
            let state = try domain.makeState(values: Array(repeating: value, count: domain.valueCount))
            #expect(try domain.destinationUpdates(from: state).count == domain.directTargets.count)
        }
    }
    let low = try body.sample(channelName: "cf_a_height", rate: 0)
    let high = try body.sample(channelName: "cf_a_height", rate: 1)
    #expect(low.scale.y != high.scale.y)
}
