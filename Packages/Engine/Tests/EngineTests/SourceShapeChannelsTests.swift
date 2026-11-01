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

@Test func sourceShapeContractPreservesDomainAndRootErrorOrder() throws {
    let fixture = shapeFixture()
    let valid = try #require((fixture["domains"] as? [[String: Any]])?.first)
    var badDefaults = valid; badDefaults["defaultValues"] = [0.5]
    var badSamples = valid; badSamples["id"] = "later"
    badSamples["channels"] = [["name": "controller", "samples": []]]
    let defaultsError = SourceShapeError.invalidContract("test: invalid defaults")
    let samplesError = SourceShapeError.invalidContract("later: invalid sample count")
    let headerError = SourceShapeError.invalidContract("unsupported schema or coordinate convention")
    let domainsError = SourceShapeError.invalidContract("invalid or duplicate domains")
    let tooMany = (0..<17).map { index in
        var domain = valid; domain["id"] = "domain-\(index)"; return domain
    }
    let cases: [(domains: [[String: Any]], version: Int, error: SourceShapeError)] = [
        ([badDefaults], 2, defaultsError),
        ([badDefaults, badSamples], 1, defaultsError),
        ([badSamples, badDefaults], 1, samplesError),
        ([valid, valid, badSamples], 2, samplesError),
        ([valid, valid], 2, headerError),
        ([valid, valid], 1, domainsError),
        ([], 2, headerError),
        ([], 1, domainsError),
        (tooMany, 1, domainsError),
    ]
    for item in cases {
        var input = fixture; input["domains"] = item.domains; input["schemaVersion"] = item.version
        let bytes = try JSONSerialization.data(withJSONObject: input)
        let expected = item.error
        #expect(throws: expected) { try SourceShapeContract.decode(bytes) }
    }
    for (domain, expected) in [(badDefaults, defaultsError), (badSamples, samplesError)] {
        let bytes = try JSONSerialization.data(withJSONObject: domain)
        #expect(throws: expected) { try JSONDecoder().decode(SourceShapeDomain.self, from: bytes) }
    }
}

@Test func sourceShapeContractPreservesMalformedFieldPathsBeforeRootValidation() throws {
    let fixture = shapeFixture()
    let valid = try #require((fixture["domains"] as? [[String: Any]])?.first)
    var invalid = valid; invalid["defaultValues"] = [0.5]
    var malformedHeader = fixture
    malformedHeader["schemaVersion"] = "not-an-integer"
    malformedHeader["domains"] = [invalid]
    let headerBytes = try JSONSerialization.data(withJSONObject: malformedHeader)
    do {
        _ = try SourceShapeContract.decode(headerBytes)
        Issue.record("Expected the malformed schemaVersion before domain validation.")
    } catch DecodingError.typeMismatch(let type, let context) {
        let isInteger = type == Int.self
        let path = context.codingPath.map(\.stringValue)
        #expect(isInteger)
        #expect(path == ["schemaVersion"])
    } catch { throw error }

    var missingSamples = valid; missingSamples["channels"] = [["name": "controller"]]
    var malformedDomain = fixture
    malformedDomain["schemaVersion"] = 2
    malformedDomain["domains"] = [valid, missingSamples]
    let domainBytes = try JSONSerialization.data(withJSONObject: malformedDomain)
    do {
        _ = try SourceShapeContract.decode(domainBytes)
        Issue.record("Expected the missing samples before unsupported-header or duplicate-domain checks.")
    } catch DecodingError.keyNotFound(let key, let context) {
        let path = context.codingPath.map(\.stringValue)
        let indices = context.codingPath.compactMap(\.intValue)
        #expect(key.stringValue == "samples")
        #expect(path == ["domains", "Index 1", "channels", "Index 0"])
        #expect(indices == [1, 0])
    } catch { throw error }
}

@Test func sourceShapeDirectAndEmbeddedDomainsPreserveRoundTripStatesAndDestinations() throws {
    var fixture = shapeFixture()
    let first = try #require((fixture["domains"] as? [[String: Any]])?.first)
    var second = first; second["id"] = "second"; second["defaultValues"] = [0.25, 0.75]
    fixture["domains"] = [first, second]
    let bytes = try JSONSerialization.data(withJSONObject: fixture)
    let contract = try SourceShapeContract.decode(bytes)
    let encoded = try JSONEncoder().encode(contract)
    let restored = try SourceShapeContract.decode(encoded)
    for (index, input) in [first, second].enumerated() {
        let domainBytes = try JSONSerialization.data(withJSONObject: input)
        let direct = try JSONDecoder().decode(SourceShapeDomain.self, from: domainBytes)
        let embedded = contract.domains[index], roundTrip = restored.domains[index]
        let directDefaults = try direct.makeState()
        let embeddedDefaults = try embedded.makeState()
        let restoredDefaults = try roundTrip.makeState()
        #expect(directDefaults == embeddedDefaults)
        #expect(restoredDefaults == embeddedDefaults)
        for rate: Float in [0, 0.25, 0.5, 0.75, 1] {
            let values = [rate, rate]
            let expected = try direct.makeState(values: values)
            // Independent fixture values also guard against equal-but-wrong routes.
            #expect(expected["controller"]?.position == SIMD3<Float>(20 * rate, 20 + 40 * rate, 0))
            #expect(expected["controller"]?.scale == SIMD3<Float>(1 + 2 * rate, 1, 1))
            let expectedUpdates = try direct.destinationUpdates(from: expected)
            for domain in [embedded, roundTrip] {
                let state = try domain.makeState(values: values)
                #expect(state == expected)
                let updates = try domain.destinationUpdates(from: state)
                try #require(updates.count == expectedUpdates.count)
                for (actual, reference) in zip(updates, expectedUpdates) {
                    #expect(actual.destinationName == reference.destinationName)
                    #expect(actual.transform == reference.transform)
                    #expect(actual.positionMask == reference.positionMask)
                    #expect(actual.rotationMask == reference.rotationMask)
                    #expect(actual.scaleMask == reference.scaleMask)
                }
            }
        }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SHAPE_CONTRACT"]),
               "Requires IKKOKU_SHAPE_CONTRACT"))
func sourceShapeLoadsLocalRecoveredContractWhenRequested() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_SHAPE_CONTRACT")
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
