import Foundation
import simd
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

/// One channel `name` with `rotations` (x per sample; y and z 0) and
/// positions/scales 0, 1, 2… along x, in a one-slot domain whose slot writes
/// the axes `mask` selects (all by default) of position, rotation and scale.
private func extendedDomain(name: String, rotations: [Float], mask: [Bool] = [true, true, true]) throws -> SourceShapeDomain {
    let samples: [[String: Any]] = rotations.enumerated().map { index, x in
        ["key": index, "position": [Float(index), 0, 0], "rotationDegrees": [x, 0, 0], "scale": [1 + Float(index), 1, 1]]
    }
    let binding: [String: Any] = ["sourceName": name, "sourceIndex": 0, "positionMask": mask,
                                  "rotationMask": mask, "scaleMask": mask]
    let domain: [String: Any] = [
        "id": "extended", "valueCount": 1, "defaultValues": [0.5], "sourceNames": [name], "destinationNames": ["bone"],
        "slots": [["index": 0, "label": "X", "bindings": [binding]]], "channels": [["name": name, "samples": samples]],
        "directTargets": [["sourceName": name, "destinationName": "bone", "positionMask": [true, true, true],
                           "rotationMask": [true, true, true], "scaleMask": [true, true, true]]],
        "unportedDestinationNames": [],
    ]
    return try JSONDecoder().decode(SourceShapeDomain.self, from: JSONSerialization.data(withJSONObject: domain))
}

/// Slider Unlocker's extended rates (`SourceShapeRateRange.extended`):
/// position and scale on the first-to-last line, rotation by the
/// first-to-last turn taken the way the first step turns, held at the end for
/// the channels it names; `.vanilla` draws the clamped rate. In 0...1 nothing
/// changes.
@Test func sourceShapeExtendsRatesAsSliderUnlockerDraws() throws {
    let domain = try #require(fixtureContract().domain("test"))
    // First-to-last line, not the last segment: positions 0 → 10 → 20 on x.
    let above = try domain.sample(channelName: "controller", rate: 1.5)
    #expect(above.position == SIMD3<Float>(30, 80, 90) && above.scale == SIMD3<Float>(4, 4, 4))
    let below = try domain.sample(channelName: "controller", rate: -0.5)
    #expect(below.position == SIMD3<Float>(-10, 0, 10) && below.scale == SIMD3<Float>(0, 0, 0))
    // x and z: 350 → 10 is a step of -340 (decreasing), the turn 170 - 350 =
    // -180 agrees; y: the step 0 → 180 increases and the turn is 0.
    #expect(above.rotationDegrees == SIMD3<Float>(170 - 90, 0, 170 - 90))
    #expect(below.rotationDegrees == SIMD3<Float>(350 + 90, 0, 350 + 90))
    // A turn against the first step gains or loses 360°.
    let rising = try extendedDomain(name: "riser", rotations: [350, 355, 10])      // step +5, turn -340 → +20
    #expect(try rising.sample(channelName: "riser", rate: 2).rotationDegrees.x == 30)
    #expect(try rising.sample(channelName: "riser", rate: -1).rotationDegrees.x == 330)
    let falling = try extendedDomain(name: "faller", rotations: [10, 5, 350])      // step -5, turn +340 → -20
    #expect(try falling.sample(channelName: "faller", rate: 2).rotationDegrees.x == 330)
    #expect(try falling.sample(channelName: "faller", rate: -1).rotationDegrees.x == 30)
    // Not wrapped afterwards.
    #expect(try rising.sample(channelName: "riser", rate: 20).rotationDegrees.x == 10 + 20 * 19)
    // The named channels hold their rotation at the nearest end; position and scale still extend.
    for name in ["cf_a_bust01_size", "cf_a_thigh01_L", "cf_a_sk_thigh01_sx", "cf_s_Mune00", "cf_s_MayuTip_L"] {
        #expect(SourceShapeDomain.holdsRotationWhenExtended(name), "\(name)")
        let held = try extendedDomain(name: name, rotations: [350, 355, 10])
        let high = try held.sample(channelName: name, rate: 2), low = try held.sample(channelName: name, rate: -1)
        #expect(high.rotationDegrees.x == 10 && low.rotationDegrees.x == 350, "\(name)")
        #expect(high.position.x == 4 && low.position.x == -2 && high.scale.x == 5, "\(name)")
    }
    for name in ["cf_a_bust01_shape1", "cf_a_thigh02_L", "cf_J_MayuTip_s_L", "cf_a_height"] {
        #expect(!SourceShapeDomain.holdsRotationWhenExtended(name), "\(name)")
    }
    // A slot value outside 0...1: extended or drawn clamped, never rejected.
    let extended = try domain.makeState(values: [1.5, -0.25], range: .extended)
    #expect(extended["controller"]?.position == SIMD3<Float>(30, 10, 0))
    #expect(try domain.makeState(values: [1.5, -0.25], range: .vanilla) == domain.makeState(values: [1, 0], range: .extended))
    // In 0...1 both ranges are the existing interpolation.
    for rate: Float in [0, 0.25, 0.5, 0.75, 1] {
        #expect(try domain.makeState(values: [rate, rate], range: .extended) == domain.makeState(values: [rate, rate], range: .vanilla))
    }
    #expect(SourceShapeRateRange.extended.drawn(1.5) == 1.5 && SourceShapeRateRange.vanilla.drawn(1.5) == 1)
    #expect(SourceShapeRateRange.vanilla.drawn(-2) == 0 && SourceShapeRateRange.vanilla.drawn(0.3) == 0.3)
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
    for value: Float in [.nan, .infinity, -.infinity] {
        #expect(throws: SourceShapeError.invalidRate) { try domain.apply(slot: 0, value: value, to: &state) }
        #expect(throws: SourceShapeError.invalidRate) { try domain.sample(channelName: "controller", rate: value) }
        #expect(state == before)
    }
    #expect(throws: SourceShapeError.invalidSlot(-1)) { try domain.apply(slot: -1, value: 0, to: &state) }
    #expect(throws: SourceShapeError.missingChannel("missing")) { try domain.sample(channelName: "missing", rate: 0.5) }
    #expect(throws: SourceShapeError.self) { try domain.makeState(values: [0.5]) }
    state.removeValue(forKey: "controller")
    #expect(throws: SourceShapeError.incompleteState("controller")) { try domain.apply(slot: 0, value: 0.5, to: &state) }
    #expect(state.isEmpty)
    // A finite rate so large that the extended shape overflows is invalid
    // too, but only through the axes the slot writes (x here; y and z are
    // constant, so they stay finite).
    let wide = try extendedDomain(name: "riser", rotations: [350, 355, 10])
    var wideState = try wide.makeState()
    let wideBefore = wideState
    #expect(throws: SourceShapeError.invalidRate) { try wide.sample(channelName: "riser", rate: 3e38) }
    #expect(throws: SourceShapeError.invalidRate) { try wide.apply(slot: 0, value: -3e38, to: &wideState, range: .extended) }
    #expect(wideState == wideBefore)
    let narrow = try extendedDomain(name: "riser", rotations: [350, 355, 10], mask: [false, true, true])
    var narrowState = try narrow.makeState()
    try narrow.apply(slot: 0, value: 3e38, to: &narrowState, range: .extended)
    #expect(narrowState == (try narrow.makeState()), "y and z are the same at every rate")
    // Vanilla draws the clamped rate, so the same value is fine there.
    try wide.apply(slot: 0, value: 3e38, to: &wideState, range: .vanilla)
    #expect(wideState == (try wide.makeState(values: [1], range: .extended)))
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
    // Extended rates meet the slider's ends: just past 0 or 1 every channel is
    // within float noise of the end, and the named channels hold rotation.
    for domain in contract.domains {
        for channel in domain.channels {
            for (end, past) in [(Float(0), Float(-1e-4)), (1, 1 + 1e-4)] {
                let a = try domain.sample(channelName: channel.name, rate: end), b = try domain.sample(channelName: channel.name, rate: past)
                let worst = [simd_abs(a.position - b.position).max(), simd_abs(a.scale - b.scale).max(),
                             simd_abs(a.rotationDegrees - b.rotationDegrees).max()].max()!
                #expect(worst < 0.05, "\(domain.id) \(channel.name) at \(past): \(worst)")
                if SourceShapeDomain.holdsRotationWhenExtended(channel.name) { #expect(a.rotationDegrees == b.rotationDegrees) }
            }
        }
    }
    #expect(body.channels.filter { SourceShapeDomain.holdsRotationWhenExtended($0.name) }.count == 11)
    #expect(!face.channels.contains { SourceShapeDomain.holdsRotationWhenExtended($0.name) })
    // A tall card (body rate 0 at 1.5) is taller than rate 1, not clamped.
    #expect(try body.sample(channelName: "cf_a_height", rate: 1.5).scale.y > high.scale.y)
}

/// What every slot of both recovered domains writes at an extended rate (2.0,
/// as the Maker scenarios commit, and -1.0) is the Slider Unlocker rule, read
/// again here independently: from the raw contract JSON, in Double, with the
/// held-rotation names restated.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SHAPE_CONTRACT"]),
               "Requires IKKOKU_SHAPE_CONTRACT"))
func sourceShapeExtendedSlotsFollowTheRuleOnTheRecoveredContract() throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: SourceFixtureSupport.require("IKKOKU_SHAPE_CONTRACT")))
    let contract = try SourceShapeContract.decode(data)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    typealias Key = (position: [Double], rotation: [Double], scale: [Double])
    func held(_ name: String) -> Bool {
        name.contains("cf_s_Mune") || name.contains("cf_s_Mouth") || name.contains("cf_s_LegLow") || name.contains("cf_s_MayuTip")
            || (name.contains("thigh") && name.contains("01")) || (name.hasPrefix("cf_a_bust") && name.hasSuffix("_size"))
    }
    var checked = 0
    for raw in try #require(json["domains"] as? [[String: Any]]) {
        let domain = try #require(contract.domain(raw["id"] as! String))
        var keys: [String: [Key]] = [:]
        for channel in raw["channels"] as! [[String: Any]] {
            keys[channel["name"] as! String] = (channel["samples"] as! [[String: Any]]).map {
                ($0["position"] as! [Double], $0["rotationDegrees"] as! [Double], $0["scale"] as! [Double])
            }
        }
        func rule(_ name: String, _ rate: Double) -> Key {
            let k = keys[name]!, first = k[0], last = k[k.count - 1], second = k[1]
            func line(_ a: [Double], _ b: [Double]) -> [Double] { (0..<3).map { a[$0] + (b[$0] - a[$0]) * rate } }
            let rotation: [Double] = (0..<3).map { axis in
                if held(name) { return rate < 0 ? first.rotation[axis] : last.rotation[axis] }
                var turn = last.rotation[axis] - first.rotation[axis]
                if second.rotation[axis] - first.rotation[axis] >= 0 { if turn < 0 { turn += 360 } } else if turn > 0 { turn -= 360 }
                return rate < 0 ? first.rotation[axis] + turn * rate : last.rotation[axis] + turn * (rate - 1)
            }
            return (line(first.position, last.position), rotation, line(first.scale, last.scale))
        }
        func near(_ a: Float, _ b: Double) -> Bool { abs(Double(a) - b) <= 1e-4 * max(1, abs(b)) }
        for slot in raw["slots"] as! [[String: Any]] {
            let index = slot["index"] as! Int
            for rate in [2.0, -1.0] {
                var state = try domain.makeState(range: .extended)
                try domain.apply(slot: index, value: Float(rate), to: &state, range: .extended)
                for binding in slot["bindings"] as! [[String: Any]] {
                    let name = binding["sourceName"] as! String
                    let got = try #require(state[name]), want = rule(name, rate)
                    let masks = (binding["positionMask"] as! [Bool], binding["rotationMask"] as! [Bool], binding["scaleMask"] as! [Bool])
                    for axis in 0..<3 {
                        if masks.0[axis] { #expect(near(got.position[axis], want.position[axis]), "\(domain.id)[\(index)] \(name) p\(axis) at \(rate)") }
                        if masks.1[axis] { #expect(near(got.rotationDegrees[axis], want.rotation[axis]), "\(domain.id)[\(index)] \(name) r\(axis) at \(rate)") }
                        if masks.2[axis] { #expect(near(got.scale[axis], want.scale[axis]), "\(domain.id)[\(index)] \(name) s\(axis) at \(rate)") }
                    }
                }
                checked += 1
            }
        }
    }
    #expect(checked == (44 + 52) * 2)
}
