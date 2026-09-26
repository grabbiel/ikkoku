import Foundation
import CryptoKit
import Testing
import simd
import Assets
import CoreMath
import Scene
import Character

private func boneModifierValues(scale: [Float] = [1, 1, 1], length: Float = 1,
                                position: [Float] = [0, 0, 0], rotation: [Float] = [0, 0, 0]) -> [String: Any] {
    ["scaleModifier": scale, "lengthModifier": length, "positionModifier": position, "rotationModifier": rotation]
}

private func boneModifierDocument(_ coordinates: [[String: Any]], name: String = "bone", location: Int = 1) -> [String: Any] {
    ["schemaVersion": 1, "kind": "ikkoku-source-bone-modifiers", "coordinateSpace": "unity-left-handed-y-up",
     "angleUnit": "degrees", "mode": "staticBaseline",
     "source": ["pluginGUID": "KKABMX.Core", "dataGUID": "KKABMPlugin.ABMData", "pluginVersion": "5.4",
                "dataKind": "card", "dataVersion": 2, "assemblySHA256": String(repeating: "a", count: 64),
                "payloadSHA256": String(repeating: "b", count: 64)],
     "modifiers": [["boneName": name, "boneLocation": location, "coordinateModifiers": coordinates]]]
}

private func boneModifiers(_ document: [String: Any]) throws -> SourceBoneModifiers {
    try SourceBoneModifiers.decode(JSONSerialization.data(withJSONObject: document))
}

private func boneModifierRig(name: String = "bone", duplicate: Bool = false, boneScale: Float3 = .one) throws -> RigDefinition {
    var nodes: [RigDefinition.Node] = [
        .init(name: "root", sourceID: "root", parent: nil, translation: Float3(0.2, -0.3, 0.4), scale: Float3(2, 1, 3)),
        .init(name: name, sourceID: "bone-1", parent: 0, scale: boneScale),
        .init(name: "child", sourceID: "child", parent: 1, translation: Float3(0.1, 0.2, -0.3)),
    ]
    if duplicate { nodes.append(.init(name: name, sourceID: "bone-2", parent: 0)) }
    return try RigDefinition(nodes: nodes, skins: [])
}

private func boneModifierNear(_ actual: float4x4, _ expected: float4x4, tolerance: Float = 0.00001) {
    for column in 0..<4 { for row in 0..<4 { #expect(abs(actual[column][row] - expected[column][row]) < tolerance) } }
}

@Test func sourceBoneModifierUsesProvidedBaselineSourceEulerOrderAndLocalLength() throws {
    let rig = try boneModifierRig()
    var baseline = rig.restPose
    // Source Z90 is unchanged by the Z reflection; source translation Z3 becomes -3.
    baseline.localMatrices[1] = Transform.trs(Float3(1, 2, -3),
        simd_quatf(angle: .pi / 2, axis: Float3(0, 0, 1)), Float3(2, 3, 4))
    let modifier = try boneModifiers(boneModifierDocument([
        boneModifierValues(scale: [0.5, 2, 1.5], length: 2, position: [0.1, 0.2, 0.3], rotation: [90, 0, 0]),
    ]))
    let result = try modifier.applying(to: rig, baseline: baseline)
    // Independently derived: Rz90 * Rx90, then source->native reflection.
    let expected = float4x4(columns: (Float4(0, 1, 0, 0), Float4(0, 0, -6, 0),
                                     Float4(-6, 0, 0, 0), Float4(2.1, 4.2, -6.3, 1)))
    boneModifierNear(result.localMatrices[1], expected)
    #expect(result.localMatrices[0] == baseline.localMatrices[0])
    #expect(result.localMatrices[2] == baseline.localMatrices[2])
    let world = try rig.evaluate(result).worldMatrices
    boneModifierNear(world[2], baseline.localMatrices[0] * expected * baseline.localMatrices[2])
    let repeated = try modifier.applying(to: rig, baseline: baseline)
    #expect(repeated.localMatrices == result.localMatrices)
    let reset = try boneModifiers(boneModifierDocument([boneModifierValues()])).applying(to: rig, baseline: baseline)
    #expect(reset.localMatrices == baseline.localMatrices)
    #expect(modifier.count == 1 && modifier.coordinateCounts == [1])
    #expect(modifier.source.dataVersion == 2 && modifier.source.dataGUID == "KKABMPlugin.ABMData")
}

@Test func sourceBoneModifierSelectsCoordinatesAndPreservesUnrotatedSignedAxes() throws {
    let rig = try boneModifierRig()
    var baseline = rig.restPose
    baseline.localMatrices[1] = Transform.trs(Float3(1, 2, -3), .identity, Float3(-2, 3, 4))
    let value = boneModifierValues(scale: [-1, 0, 2], length: 1.5, position: [0, 0, 0.5])
    let shared = try boneModifiers(boneModifierDocument([value]))
    let global = try shared.applying(to: rig, baseline: baseline, coordinate: 8)
    boneModifierNear(global.localMatrices[1], Transform.trs(Float3(1.5, 3, -5), .identity, Float3(2, 0, 8)))
    let specific = try boneModifiers(boneModifierDocument([boneModifierValues(), value]))
    #expect(specific.coordinateCounts == [2])
    #expect(try specific.applying(to: rig, baseline: baseline, coordinate: 0).localMatrices == baseline.localMatrices)
    #expect(try specific.applying(to: rig, baseline: baseline, coordinate: 1).localMatrices == global.localMatrices)
    #expect(try specific.applying(to: rig, baseline: baseline, coordinate: 2).localMatrices == baseline.localMatrices)
    #expect(specific.modifiers[0].values(for: 2) == nil)
    #expect(throws: RigError.self) { try shared.applying(to: rig, baseline: baseline, coordinate: -1) }
}

@Test func sourceBoneModifierReportsUnsupportedScopesDynamicsAndAmbiguousRotations() throws {
    let rig = try boneModifierRig(), value = boneModifierValues(position: [0.1, 0, 0])
    for (name, location) in [("bone", 10), ("missing", 1)] {
        let modifier = try boneModifiers(boneModifierDocument([value], name: name, location: location))
        #expect(throws: RigError.self) { try modifier.applying(to: rig, baseline: rig.restPose) }
    }
    let dynamicRig = try boneModifierRig(name: "cf_d_sk_probe")
    let dynamicModifier = try boneModifiers(boneModifierDocument([value], name: "cf_d_sk_probe"))
    #expect(throws: RigError.self) { try dynamicModifier.applying(to: dynamicRig, baseline: dynamicRig.restPose) }
    let duplicate = try boneModifierRig(duplicate: true)
    let ordinary = try boneModifiers(boneModifierDocument([value]))
    #expect(throws: RigError.self) { try ordinary.applying(to: duplicate, baseline: duplicate.restPose) }
    let scoped = try RigDefinition(nodes: [
        .init(name: "avatar", sourceID: "avatar", parent: nil),
        .init(name: "p_cf_body_bone", sourceID: "body-root", parent: 0),
        .init(name: "bone", sourceID: "actual-body-bone", parent: 1),
        .init(name: "bone", sourceID: "outside-body", parent: 0),
    ], skins: [])
    let scopedResult = try ordinary.applying(to: scoped, baseline: scoped.restPose)
    #expect(scopedResult.localMatrices[2] != scoped.restPose.localMatrices[2])
    #expect(scopedResult.localMatrices[3] == scoped.restPose.localMatrices[3])
    let rotation = try boneModifiers(boneModifierDocument([boneModifierValues(rotation: [10, 20, 30])]))
    // Two negative authored scale axes still have a positive determinant. They
    // must not be silently reinterpreted as an extra baseline rotation.
    let signed = try boneModifierRig(boneScale: Float3(-1, -1, 1))
    #expect(throws: RigError.self) { try rotation.applying(to: signed, baseline: signed.restPose) }
    for scale in [Float3(-1, 1, 1), Float3(0, 1, 1)] {
        var baseline = rig.restPose
        baseline.localMatrices[1] = Transform.scale(scale)
        #expect(throws: RigError.self) { try rotation.applying(to: rig, baseline: baseline) }
    }
    var shear = rig.restPose
    shear.localMatrices[1][1].x = 0.2
    #expect(throws: RigError.self) { try rotation.applying(to: rig, baseline: shear) }
}

@Test func sourceBoneModifierRejectsInvalidSchemaVectorsAndOverlappingRecords() throws {
    let rig = try boneModifierRig()
    var repaired = boneModifierDocument([boneModifierValues()])
    repaired["diagnostics"] = [["code": "repaired-null-coordinate", "severity": "warning",
                                "message": "Synthetic coordinate #1 repaired to identity."]]
    let repair = try #require(try boneModifiers(repaired).diagnostics?.first)
    #expect(repair.code == "repaired-null-coordinate" && repair.severity == "warning")
    #expect(repair.message.contains("identity"))
    #expect(throws: RigError.self) { try boneModifiers(boneModifierDocument([])) }
    var invalid = boneModifierDocument([boneModifierValues(scale: [1, 2])])
    #expect(throws: RigError.self) { try boneModifiers(invalid) }
    invalid = boneModifierDocument([boneModifierValues()])
    invalid["angleUnit"] = "radians"
    #expect(throws: RigError.self) { try boneModifiers(invalid) }
    invalid = boneModifierDocument([boneModifierValues()])
    invalid["mode"] = "animated"
    #expect(throws: RigError.self) { try boneModifiers(invalid) }
    invalid = boneModifierDocument([boneModifierValues(position: [1, 0, 0])])
    var records = try #require(invalid["modifiers"] as? [[String: Any]])
    records.append(records[0])
    invalid["modifiers"] = records
    #expect(throws: RigError.self) { try boneModifiers(invalid) }
    // Unknown and BodyTop may resolve to the same transform; report the overlap.
    records[1]["boneLocation"] = 0
    invalid["modifiers"] = records
    let overlapping = try boneModifiers(invalid)
    #expect(throws: RigError.self) { try overlapping.applying(to: rig, baseline: rig.restPose) }
}

private struct BoneModifierReference: Decodable {
    struct Node: Decodable {
        let name: String, parent: Int?
        let translation: [Float], rotation: [Float], scale: [Float]
    }
    struct Case: Decodable {
        let id: String, coordinate: Int, document: SourceBoneModifiers
        let baselineNodes: [Node], expectedLocalMatrices: [[Float]], expectedWorldMatrices: [[Float]]
    }
    let schemaVersion: Int, cases: [Case]
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_ABMX_REFERENCE"]),
               "Requires IKKOKU_ABMX_REFERENCE"))
func sourceBoneModifierMatchesIndependentLocalNumPyMatrices() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_ABMX_REFERENCE")
    let reference = try JSONDecoder().decode(BoneModifierReference.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(reference.schemaVersion == 1 && reference.cases.count == 8)
    func matrix(_ values: [Float]) throws -> float4x4 {
        try #require(values.count == 16)
        return float4x4(columns: (Float4(Array(values[0..<4])), Float4(Array(values[4..<8])),
                                 Float4(Array(values[8..<12])), Float4(Array(values[12..<16]))))
    }
    for example in reference.cases {
        let nodes = example.baselineNodes.enumerated().map { index, node in
            RigDefinition.Node(name: node.name, sourceID: "synthetic-\(index)", parent: node.parent,
                translation: UnityCoordinates.position(Float3(node.translation)),
                rotation: UnityCoordinates.rotation(simd_quatf(vector: Float4(node.rotation))), scale: Float3(node.scale))
        }
        let rig = try RigDefinition(nodes: nodes, skins: [])
        let actual = try example.document.applying(to: rig, baseline: rig.restPose, coordinate: example.coordinate)
        let world = try rig.evaluate(actual).worldMatrices
        #expect(actual.localMatrices.count == example.expectedLocalMatrices.count)
        for index in actual.localMatrices.indices {
            boneModifierNear(actual.localMatrices[index], try matrix(example.expectedLocalMatrices[index]))
            boneModifierNear(world[index], try matrix(example.expectedWorldMatrices[index]), tolerance: 0.00003)
        }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_ABMX_MODIFIERS", "IKKOKU_SOURCE_AVATAR"]),
               "Requires IKKOKU_ABMX_MODIFIERS, IKKOKU_SOURCE_AVATAR"))
func sourceBoneModifierLoadsLocalClothedAvatarExample() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_ABMX_MODIFIERS")
    let modifiers = try SourceBoneModifiers.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    let avatarPath = try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR")
    let source = try SourceRig.loadModel(url: URL(fileURLWithPath: avatarPath))
    let pose = try modifiers.applying(to: source.rig, baseline: source.rig.restPose)
    #expect(modifiers.count == 3)
    let changed = source.rig.nodes.indices.filter { pose.localMatrices[$0] != source.rig.restPose.localMatrices[$0] }
    #expect(Set(changed.map { source.rig.nodes[$0].name }) == ["cf_J_FaceRoot", "cf_j_forearm01_L", "cf_j_forearm01_R"])
    #expect(try source.rig.evaluate(pose).palettes.count == source.rig.skins.count)
}

// Independent synthetic wire writer: deliberately emits wide integer/float
// encodings as well as source-shaped arrays, with no production encoder involved.
private func boneModifierWire(_ value: SourceMessagePackValue) -> Data {
    func word(_ value: UInt64, _ size: Int) -> Data {
        Data((0..<size).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    switch value {
    case .null: return Data([0xc0])
    case .bool(let value): return Data([value ? 0xc3 : 0xc2])
    case .integer(let value): return Data([0xd3]) + word(UInt64(bitPattern: value), 8)
    case .unsigned(let value): return Data([0xcf]) + word(value, 8)
    case .float(let value): return Data([0xcb]) + word(value.bitPattern, 8)
    case .string(let value):
        let bytes = Data(value.utf8)
        return Data([0xdb]) + word(UInt64(bytes.count), 4) + bytes
    case .binary(let value): return Data([0xc6]) + word(UInt64(value.count), 4) + value
    case .array(let values):
        var result = Data([0xdd]) + word(UInt64(values.count), 4)
        for value in values { result.append(boneModifierWire(value)) }
        return result
    case .map(let values):
        var result = Data([0xdf]) + word(UInt64(values.count), 4)
        for value in values { result.append(boneModifierWire(value.key)); result.append(boneModifierWire(value.value)) }
        return result
    case .ext(let type, let bytes):
        return Data([0xc9]) + word(UInt64(bytes.count), 4) + Data([UInt8(bitPattern: type)]) + bytes
    }
}

private func boneModifierLZ4(_ plain: Data) -> Data {
    // A valid raw LZ4 final literal sequence, wrapped like MessagePack v1's
    // ext32 + int32 serializer. Match-copy paths have generic decoder tests.
    var block = Data([UInt8(min(plain.count, 15) << 4)])
    if plain.count >= 15 {
        var additional = plain.count - 15
        while additional >= 255 { block.append(255); additional -= 255 }
        block.append(UInt8(additional))
    }
    block.append(plain)
    let size = UInt32(plain.count)
    let header = Data([0xd2, UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                       UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
    return boneModifierWire(.ext(99, header + block))
}

private func boneModifierWireValues(scale: [Double] = [1, 1, 1], length: Double = 1,
                                    position: [Double] = [0, 0, 0], rotation: [Double] = [0, 0, 0]) -> SourceMessagePackValue {
    .array([.array(scale.map { .float($0) }), .float(length),
            .array(position.map { .float($0) }), .array(rotation.map { .float($0) })])
}

private func boneModifierWireRecord(_ coordinates: SourceMessagePackValue, name: String = "bone",
                                    location: SourceMessagePackValue = .integer(1)) -> SourceMessagePackValue {
    .array([.string(name), coordinates, location])
}

private func decodeBoneModifierWire(_ value: SourceMessagePackValue) throws -> SourceBoneModifiers {
    try SourceBoneModifiers.decodeBoneData(boneModifierWire(value), dataKind: "card", dataVersion: 2)
}

@Test func sourceBoneModifierNativeWireMatchesJSONAndHashesOriginalCompressedBytes() throws {
    let values = boneModifierWireValues(scale: [0.5, -2, 1.25], length: 1.1,
                                        position: [0.1, -0.2, 0.3], rotation: [10, 25, -5])
    let bytes = boneModifierWire(.array([boneModifierWireRecord(.array([values]))]))
    let compressed = boneModifierLZ4(bytes)
    let plain = try SourceBoneModifiers.decodeBoneData(bytes, dataKind: "card", dataVersion: 2)
    let packed = try SourceBoneModifiers.decodeBoneData(compressed, dataKind: "coordinate", dataVersion: 3)
    let json = try boneModifiers(boneModifierDocument([
        boneModifierValues(scale: [0.5, -2, 1.25], length: 1.1,
                           position: [0.1, -0.2, 0.3], rotation: [10, 25, -5]),
    ]))
    #expect(plain.modifiers[0].coordinateModifiers == json.modifiers[0].coordinateModifiers)
    #expect(packed.modifiers[0].coordinateModifiers == plain.modifiers[0].coordinateModifiers)
    #expect(packed.source.dataKind == "coordinate" && packed.source.dataVersion == 3)
    #expect(plain.source.dataKind == "card" && plain.source.dataVersion == 2)
    #expect(plain.source.assemblySHA256 == "f3e2d9877b08b2b25187cbc101478ea0d484bcfe4856244050ba3119578e9f68")
    #expect(plain.source.payloadSHA256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    #expect(packed.source.payloadSHA256 == SHA256.hash(data: compressed).map { String(format: "%02x", $0) }.joined())
    #expect(plain.source.payloadSHA256 != packed.source.payloadSHA256)
    #expect(plain.diagnostics?.isEmpty == true)
    let provenance = String(repeating: "c", count: 64)
    #expect(try SourceBoneModifiers.decodeBoneData(bytes, dataKind: "card", dataVersion: 2,
                                                  assemblySHA256: provenance).source.assemblySHA256 == provenance)
    let rig = try boneModifierRig()
    var baseline = rig.restPose
    baseline.localMatrices[1] = Transform.trs(Float3(1, 2, -3), .identity, Float3(2, 3, 4))
    for coordinate in [0, 1, 9] {
        #expect(try plain.applying(to: rig, baseline: baseline, coordinate: coordinate).localMatrices ==
            json.applying(to: rig, baseline: baseline, coordinate: coordinate).localMatrices)
    }
    // An empty outer collection means no modifiers. Only empty coordinate
    // collections are forbidden by the source serialization constructor.
    #expect(try decodeBoneModifierWire(.array([])).count == 0)
}

@Test func sourceBoneModifierNativeWireRepairsNullEntriesAndRetainsUnsupportedDiagnostics() throws {
    let active = boneModifierWireValues(position: [0.1, 0, 0])
    let records: [SourceMessagePackValue] = [
        boneModifierWireRecord(.array([.null, active])),
        boneModifierWireRecord(.array([active]), name: "accessory", location: .integer(10)),
        boneModifierWireRecord(.array([active]), name: "cf_d_sk_probe"),
    ]
    let decoded = try decodeBoneModifierWire(.array(records))
    #expect(decoded.coordinateCounts == [2, 1, 1])
    #expect(decoded.modifiers[0].coordinateModifiers[0].isIdentity)
    #expect(!decoded.modifiers[0].coordinateModifiers[1].isIdentity)
    #expect(decoded.modifiers[0].values(for: 2) == nil)
    #expect(decoded.modifiers[1].boneLocation == 10)
    let diagnostics = try #require(decoded.diagnostics)
    #expect(diagnostics.map(\.code) == ["repaired-null-coordinate", "unsupported-bone-location", "unsupported-dynamic-bone"])
    #expect(diagnostics.allSatisfy { $0.severity == "warning" })
    #expect(diagnostics[0].message == "ABMX repaired null coordinate #1 for 'bone' to identity; the converted document preserves this repair.")
    #expect(diagnostics[1].message == "ABMX bone 'accessory' uses location 10; the native static evaluator rejects active accessory/unknown-scope modifiers.")
    #expect(diagnostics[2].message == "ABMX bone 'cf_d_sk_probe' uses the source dynamic-baseline/gravity path; the native static evaluator rejects active modifiers on this target.")
    for record in records.dropFirst() {
        let modifier = try decodeBoneModifierWire(.array([record]))
        let rig = try boneModifierRig(name: modifier.modifiers[0].boneName)
        #expect(throws: RigError.self) { try modifier.applying(to: rig, baseline: rig.restPose) }
    }
    let identityUnsupported = try decodeBoneModifierWire(.array([
        boneModifierWireRecord(.array([.null]), name: "unimported", location: .integer(10)),
    ]))
    let rig = try boneModifierRig()
    #expect(identityUnsupported.diagnostics?.map(\.code) == ["repaired-null-coordinate", "unsupported-bone-location"])
    #expect(try identityUnsupported.applying(to: rig, baseline: rig.restPose).localMatrices == rig.restPose.localMatrices)
}

@Test func sourceBoneModifierNativeWireRejectsMalformedShapesTypesAndVersions() throws {
    let values = boneModifierWireValues()
    let valid = boneModifierWireRecord(.array([values]))
    let malformed: [SourceMessagePackValue] = [
        .null, .map([]), .binary(Data()), .ext(98, Data()),
        .array([.null]), .array([.array([])]), .array([.array([.string("bone"), .array([values])])]),
        .array([.array([.string("bone"), .array([values]), .integer(1), .null])]),
        .array([boneModifierWireRecord(.null)]), .array([boneModifierWireRecord(.array([]))]),
        .array([boneModifierWireRecord(.array([.array([])]))]),
        .array([boneModifierWireRecord(.array([.array([.array([]), .float(1), .array([])])]))]),
        .array([boneModifierWireRecord(.array([values]), name: "")]),
        .array([boneModifierWireRecord(.array([values]), name: "bo\0ne")]),
        .array([boneModifierWireRecord(.array([values]), location: .integer(-1))]),
        .array([boneModifierWireRecord(.array([values]), location: .bool(true))]),
        .array([boneModifierWireRecord(.array([values]), location: .float(1))]),
        .array([boneModifierWireRecord(.array([values]), location: .unsigned(UInt64.max))]),
        .array([valid, valid]),
    ]
    for value in malformed {
        #expect(throws: RigError.self) { try decodeBoneModifierWire(value) }
    }
    let bytes = boneModifierWire(.array([valid]))
    for (kind, version) in [("card", 1), ("card", 3), ("coordinate", 2), ("coordinate", 4), ("scene", 2)] {
        #expect(throws: RigError.self) { try SourceBoneModifiers.decodeBoneData(bytes, dataKind: kind, dataVersion: version) }
    }
    #expect(throws: RigError.self) {
        try SourceBoneModifiers.decodeBoneData(bytes, dataKind: "card", dataVersion: 2, assemblySHA256: "invalid")
    }
    for payload in [Data(), Data(bytes.dropLast()), bytes + Data([0]), Data(repeating: 0, count: 16 * 1024 * 1024 + 1)] {
        #expect(throws: RigError.self) { try SourceBoneModifiers.decodeBoneData(payload, dataKind: "card", dataVersion: 2) }
    }
    // Enormous advertised expansion is rejected before allocation.
    let oversized = boneModifierWire(.ext(99, Data([0xd2, 0x04, 0x00, 0x00, 0x01, 0])))
    #expect(throws: RigError.self) { try SourceBoneModifiers.decodeBoneData(oversized, dataKind: "card", dataVersion: 2) }
}

@Test func sourceBoneModifierNativeWireEnforcesFloat32AndSourceArrayLimits() throws {
    let valid = try #require(boneModifierWireValues().arrayValue)
    for invalid in [SourceMessagePackValue.bool(true), .string("1"), .null, .float(.infinity),
                    .float(-.infinity), .float(.nan), .float(Double(Float.greatestFiniteMagnitude).nextUp)] {
        for index in 0..<4 {
            var fields = valid
            fields[index] = index == 1 ? invalid : .array([.float(1), invalid, .float(1)])
            #expect(throws: RigError.self) {
                try decodeBoneModifierWire(.array([boneModifierWireRecord(.array([.array(fields)]))]))
            }
        }
    }
    for index in [0, 2, 3] {
        var fields = valid
        fields[index] = .array([.float(1), .float(2)])
        #expect(throws: RigError.self) {
            try decodeBoneModifierWire(.array([boneModifierWireRecord(.array([.array(fields)]))]))
        }
    }
    var integerFields = valid
    integerFields[0] = .array([.integer(-2), .unsigned(16_777_217), .float(-0.0)])
    integerFields[1] = .unsigned(UInt64.max)
    integerFields[2] = .array([.float(Double(Float.greatestFiniteMagnitude)), .float(1e-300), .integer(0)])
    let numeric = try decodeBoneModifierWire(.array([boneModifierWireRecord(.array([.array(integerFields)]))]))
    let values = numeric.modifiers[0].coordinateModifiers[0]
    #expect(values.scaleModifier[0] == -2 && values.scaleModifier[1] == 16_777_216)
    #expect(values.scaleModifier[2].sign == .minus)
    #expect(values.lengthModifier == Float(Double(UInt64.max)))
    #expect(values.positionModifier == [Float.greatestFiniteMagnitude, 0, 0])
    let coordinates = try decodeBoneModifierWire(.array([boneModifierWireRecord(.array(Array(repeating: .null, count: 1024)))]))
    #expect(coordinates.coordinateCounts == [1024] && coordinates.diagnostics?.count == 1024)
    #expect(throws: RigError.self) {
        try decodeBoneModifierWire(.array([boneModifierWireRecord(.array(Array(repeating: .null, count: 1025)))]))
    }
    let records = (0..<10_001).map { boneModifierWireRecord(.array([.null]), name: "b\($0)") }
    #expect(try decodeBoneModifierWire(.array(Array(records.prefix(10_000)))).count == 10_000)
    #expect(throws: RigError.self) { try decodeBoneModifierWire(.array(records)) }
    // Python's source adapter counts Unicode code points, not grapheme clusters.
    let scalarLimit = String(repeating: "e\u{301}", count: 512)
    #expect(try decodeBoneModifierWire(.array([boneModifierWireRecord(.array([.null]), name: scalarLimit)])).count == 1)
    #expect(throws: RigError.self) {
        try decodeBoneModifierWire(.array([boneModifierWireRecord(.array([.null]), name: scalarLimit + "x")]))
    }
    let distinctNames = try decodeBoneModifierWire(.array([
        boneModifierWireRecord(.array([.null]), name: "\u{e9}"),
        boneModifierWireRecord(.array([.null]), name: "e\u{301}"),
    ]))
    #expect(distinctNames.count == 2)
    #expect(Data(distinctNames.modifiers[0].boneName.utf8) != Data(distinctNames.modifiers[1].boneName.utf8))
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_ABMX_BONE_DATA", "IKKOKU_ABMX_MODIFIERS"]),
               "Requires IKKOKU_ABMX_BONE_DATA, IKKOKU_ABMX_MODIFIERS"))
func sourceBoneModifierNativeWireMatchesLocalPythonConversion() throws {
    let payloadPath = try SourceFixtureSupport.require("IKKOKU_ABMX_BONE_DATA")
    let jsonPath = try SourceFixtureSupport.require("IKKOKU_ABMX_MODIFIERS")
    let converted = try SourceBoneModifiers.decode(Data(contentsOf: URL(fileURLWithPath: jsonPath)))
    let payload = try Data(contentsOf: URL(fileURLWithPath: payloadPath))
    let native = try SourceBoneModifiers.decodeBoneData(payload, dataKind: converted.source.dataKind,
        dataVersion: converted.source.dataVersion, assemblySHA256: converted.source.assemblySHA256)
    #expect(native.source.pluginGUID == converted.source.pluginGUID)
    #expect(native.source.dataGUID == converted.source.dataGUID)
    #expect(native.source.pluginVersion == converted.source.pluginVersion)
    #expect(native.source.payloadSHA256 == converted.source.payloadSHA256)
    #expect(native.coordinateCounts == converted.coordinateCounts)
    #expect(native.modifiers.map(\.boneName) == converted.modifiers.map(\.boneName))
    #expect(native.modifiers.map(\.boneLocation) == converted.modifiers.map(\.boneLocation))
    #expect(native.modifiers.map(\.coordinateModifiers) == converted.modifiers.map(\.coordinateModifiers))
    #expect(native.diagnostics?.map(\.code) == converted.diagnostics?.map(\.code))
    #expect(native.diagnostics?.map(\.severity) == converted.diagnostics?.map(\.severity))
    #expect(native.diagnostics?.map(\.message) == converted.diagnostics?.map(\.message))
    if let avatarPath = ProcessInfo.processInfo.environment["IKKOKU_SOURCE_AVATAR"] {
        let model = try SourceRig.loadModel(url: URL(fileURLWithPath: avatarPath))
        let baseline = model.rig.restPose
        #expect(try native.applying(to: model.rig, baseline: baseline).localMatrices ==
            converted.applying(to: model.rig, baseline: baseline).localMatrices)
    }
}
