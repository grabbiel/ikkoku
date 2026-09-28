import Foundation
import Testing
import simd
import Assets
import Character
@testable import Studio

private func i(_ value: Int32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func f(_ value: Float) -> Data { i(Int32(bitPattern: value.bitPattern)) }
private func quat(_ x: Float, _ y: Float, _ z: Float, _ w: Float) -> Data { f(x) + f(y) + f(z) + f(w) }

@Test func studioNeckLookBytesRoundTripSavedPatternAndFixAngles() throws {
    let bytes = i(3) + i(2) + quat(0, 0, 0.7071068, 0.7071068) + quat(0.1, 0.2, 0.3, 0.9)
    let data = try SourceStudioNeckLookData(bytes: bytes)
    #expect(data.patternNumber == 3)
    #expect(data.fixAngles.count == 2)
    #expect(data.fixAngles[0].vector == SIMD4<Float>(0, 0, 0.7071068, 0.7071068))
    #expect(data.fixAngles[1].vector == SIMD4<Float>(0.1, 0.2, 0.3, 0.9))
    // Saved Unity component order is kept verbatim, not axis-swapped.
    #expect(data.fixAngles[0].vector.x == 0 && data.fixAngles[0].vector.y == 0)
    let zero = try SourceStudioNeckLookData(bytes: i(0) + i(0))
    #expect(zero.patternNumber == 0 && zero.fixAngles.isEmpty)
    // ptnNo is stored verbatim; only the collection count is range-checked.
    let negative = try SourceStudioNeckLookData(bytes: i(-1) + i(0))
    #expect(negative.patternNumber == -1)
    #expect(throws: (any Error).self) { _ = try SourceStudioNeckLookData(bytes: Data()) }
    #expect(throws: (any Error).self) { _ = try SourceStudioNeckLookData(bytes: i(3)) } // missing count
    #expect(throws: (any Error).self) { _ = try SourceStudioNeckLookData(bytes: i(1) + i(-2)) } // negative count
    #expect(throws: (any Error).self) { _ = try SourceStudioNeckLookData(bytes: i(1) + i(1) + quat(0, 0, 0, 1).dropLast()) }
    #expect(throws: (any Error).self) { _ = try SourceStudioNeckLookData(bytes: i(1) + i(0) + f(1)) } // trailing bytes
}

@Test func studioNeckLookRejectsNonfiniteSavedFloats() {
    #expect(throws: (any Error).self) {
        _ = try SourceStudioNeckLookData(bytes: i(1) + i(1) + quat(Float.nan, 0, 0, 1))
    }
    #expect(throws: (any Error).self) {
        _ = try SourceStudioNeckLookData(bytes: i(1) + i(1) + quat(0, 0, 0, Float.infinity))
    }
}

@Test func studioEyeLookAnglesAppearOnlyFromSceneVersion008() throws {
    let body = quat(0, 0.25, 0, 0.9682458) + quat(0, -0.25, 0, 0.9682458)
    let angles = f(11) + f(-12) + f(3) + f(-4)
    let current = try SourceStudioEyeLookData(bytes: body + angles, sceneVersion: "1.0.4.2")
    #expect(current.fixAngles[0].vector == SIMD4<Float>(0, 0.25, 0, 0.9682458))
    #expect(current.fixAngles[1].vector == SIMD4<Float>(0, -0.25, 0, 0.9682458))
    #expect(current.angleH == [11, -12] && current.angleV == [3, -4])
    let old = try SourceStudioEyeLookData(bytes: body, sceneVersion: "0.0.7")
    #expect(old.fixAngles.count == 2 && old.angleH == nil && old.angleV == nil)
    #expect(throws: (any Error).self) { _ = try SourceStudioEyeLookData(bytes: body + angles.dropLast(), sceneVersion: "1.0.4.2") }
    #expect(throws: (any Error).self) { _ = try SourceStudioEyeLookData(bytes: body.dropLast(), sceneVersion: "0.0.7") }
    #expect(throws: (any Error).self) { _ = try SourceStudioEyeLookData(bytes: body + angles + f(1), sceneVersion: "1.0.4.2") }
}

@Test func studioEyeLookVersionGateComparesMajorMinorPatch() throws {
    #expect(try SourceStudioLookData.readsSavedEyeAngles(sceneVersion: "0.0.8"))
    #expect(try SourceStudioLookData.readsSavedEyeAngles(sceneVersion: "0.1.0"))
    #expect(try SourceStudioLookData.readsSavedEyeAngles(sceneVersion: "1.0.0"))
    #expect(try !SourceStudioLookData.readsSavedEyeAngles(sceneVersion: "0.0.7"))
    #expect(try !SourceStudioLookData.readsSavedEyeAngles(sceneVersion: "0.0"))
    #expect(throws: (any Error).self) { _ = try SourceStudioLookData.readsSavedEyeAngles(sceneVersion: "0.0.x") }
    #expect(throws: (any Error).self) { _ = try SourceStudioLookData.readsSavedEyeAngles(sceneVersion: "") }
}

@Test func studioLookStatusKeepsMissingFieldsNilAndReportsWrongTypes() throws {
    let packed: [String: SourceMessagePackValue] = [
        "eyesLookPtn": .integer(4), "neckLookPtn": .unsigned(2), "eyesTargetType": .integer(1),
        "neckTargetRate": .float(0.5), "eyesTargetAngle": .integer(30),
        "neckTargetType": .string("target"), "eyesTargetRange": .float(20),
    ]
    let status = SourceStudioLookStatus(status: packed)
    #expect(status.eyesLookPtn == 4 && status.neckLookPtn == 2 && status.eyesTargetType == 1)
    #expect(status.eyesTargetRate == nil && status.neckTargetRate == 0.5 && status.eyesTargetAngle == 30)
    #expect(status.eyesTargetRange == 20)
    // Wrong type is reported and left nil; missing fields are silently nil.
    #expect(status.neckTargetType == nil)
    #expect(status.diagnostics.count == 1)
    #expect(status.diagnostics[0].contains("neckTargetType"))
    let empty = SourceStudioLookStatus(status: [:])
    #expect(empty.eyesLookPtn == nil && empty.neckLookPtn == nil && empty.diagnostics.isEmpty)
    let outOfRange = SourceStudioLookStatus(status: ["neckLookPtn": .integer(Int64(Int32.max) + 1)])
    #expect(outOfRange.neckLookPtn == nil)
    #expect(outOfRange.diagnostics.count == 1)
    let nonfinite = SourceStudioLookStatus(status: ["eyesTargetRate": .float(.nan)])
    #expect(nonfinite.eyesTargetRate == nil && nonfinite.diagnostics.count == 1)
}

@Test func studioEffectiveNeckPatternPrefersCardStatusOverSavedBytes() throws {
    let status = SourceStudioLookStatus(status: ["neckLookPtn": .integer(1)])
    #expect(SourceStudioLookData.effectiveNeckPattern(status: status, savedNeckPatternNumber: 4) == 1)
    let missing = SourceStudioLookStatus(status: [:])
    #expect(SourceStudioLookData.effectiveNeckPattern(status: missing, savedNeckPatternNumber: 4) == 4)
}

@Test func koikatsuSceneCarriesLookBytesAndCardStatusDecidesTheEffectiveNeckPattern() throws {
    let status = OriginalCardFixture.pack(OriginalCardFixture.map([
        ("eyesLookPtn", .integer(2)), ("neckLookPtn", .integer(1)), ("neckTargetRate", .float(0.5))]))
    let card = OriginalCardFixture.card(blocks: OriginalCardFixture.blocks()
        + [.init(name: "Status", version: "0.0.5", data: status)])
    let neck = i(4) + i(1) + quat(0, 0, 0.7071068, 0.7071068)
    let eyes = quat(0, 0.25, 0, 0.9682458) + quat(0, -0.25, 0, 0.9682458) + f(11) + f(-12) + f(3) + f(-4)
    let document = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene(card: card, neck: neck, eyes: eyes).data)
    let record = try #require(document.snapshot.roots[0].character)
    #expect(record.neckData == neck && record.eyesData == eyes)
    // The synthetic scene is saved as version 1.0.4.2, so the eye angles are readable.
    let savedEyes = try SourceStudioEyeLookData(bytes: record.eyesData, sceneVersion: document.snapshot.version)
    #expect(savedEyes.angleH == [11, -12] && savedEyes.angleV == [3, -4])
    let savedNeck = try SourceStudioNeckLookData(bytes: record.neckData)
    #expect(savedNeck.patternNumber == 4)
    let statusBlock = try #require(record.card().block(named: "Status"))
    let look = SourceStudioLookStatus(status: try SourceMessagePack.decode(statusBlock.data).stringKeyedMap())
    #expect(look.eyesLookPtn == 2 && look.neckLookPtn == 1 && look.neckTargetRate == 0.5 && look.diagnostics.isEmpty)
    // ChangeLookNeckPtn runs last on load, so the card pattern 1 wins over the saved ptnNo 4.
    #expect(SourceStudioLookData.effectiveNeckPattern(status: look, savedNeckPatternNumber: savedNeck.patternNumber) == 1)
}
