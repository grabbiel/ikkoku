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

/// A minimal expression contract with the original controller pattern counts
/// (eyebrow 17, eyes 28, mouth 43) and a cha_eyeset catalog whose rows mix
/// ordinary rows, an expression-texture row and a gag-eye row.
private func expressionStateContract(rows: Bool = true) throws -> SourceExpressionContract {
    let inputs: [String: Any] = [
        "eyebrowPattern": 0, "eyesPattern": 0, "mouthPattern": 0,
        "eyebrowOpenRate": 1, "eyesOpenRate": 1, "mouthOpenRate": 0,
        "eyebrowOpenMax": 1, "eyesOpenMax": 0.92, "mouthOpenMax": 1,
        "blinkRate": 1, "mouthFixedRate": -1,
    ]
    let controllers: [[String: Any]] = [("eyebrow", 17), ("eyes", 28), ("mouth", 43)].map { id, count in
        func channel(_ index: Int) -> [String: Any] { ["index": index, "name": "channel-\(index)", "frameIndex": index, "frameWeight": 100] }
        return ["id": id, "openMin": 0, "openMax": 1, "fixedRate": -0.1, "syncBlink": id == "eyebrow", "sourcePatternCount": count,
                "targets": [["nodeName": "face-node", "meshName": id, "meshSourceID": "synthetic:\(id)", "channelCount": 2,
                             "controlledChannelIndices": [0, 1],
                             "patterns": (0..<count).map { ["index": $0, "close": channel(0), "open": channel(1)] }]]]
    }
    func row(_ id: Int, _ pattern: Int, base: Int = 1, gag: Int = 0, eps: String = "0") -> [String: Any] {
        ["id": id, "name": "row \(id)", "pattern": pattern, "eyeBase": base, "eyeHitomi": base, "eyeObjectNumber": gag,
         "mainTexture": gag == 0 ? "0" : "cf_t_gageye_00", "expressionTexture": eps]
    }
    var catalog: [String: Any] = ["table": "cha_eyeset_00", "ordinaryRows": (0..<7).map { row($0, $0) }]
    if rows { catalog["rows"] = (0..<21).map { row($0, $0) } + [row(21, 21, base: 0, gag: 1), row(24, 2, eps: "cf_t_expression_01"), row(33, 22)] }
    let document: [String: Any] = ["schemaVersion": 1, "weightUnit": "percent", "transitionSeconds": 0.15,
        "updateOrder": ["eyebrow", "eyes", "mouth"], "controllers": controllers, "defaults": inputs, "presets": [],
        "eyeCatalog": catalog]
    return try SourceExpressionContract.decode(JSONSerialization.data(withJSONObject: document))
}

private let savedFace = SourceStudioExpressionState(eyebrowPattern: 0, eyesPattern: 0, mouthPattern: 0, eyesOpen: 0.75, blink: true,
    mouthOpen: 0.25, lipSync: false, eyesLookPattern: 1, neckLookPattern: 2, tears: 0, cheek: 0)

@Test func sourceStudioExpressionSettledPortsTheBlinkAndOpennessSetters() throws {
    // ChangeEyesBlinkFlag(false) forces the eyes open rate to 1 although the
    // openness slider says 0.75 ...
    var off = savedFace; off.blink = false
    let blinkOff = off.settled(from: savedFace)
    #expect(blinkOff.heldEyesOpenRate == 1 && blinkOff.eyesOpenRate == 1)
    // ... a following slider move (ChangeEyesOpenMax while not blinking)
    // forces the clamped openness, which equals the load replay, so nil.
    var slider = blinkOff; slider.eyesOpen = 0.5
    let moved = slider.settled(from: blinkOff)
    #expect(moved.heldEyesOpenRate == nil && moved.eyesOpenRate == 0.5)
    // Another unrelated edit keeps the held rate.
    var mouth = blinkOff; mouth.mouthPattern = 3
    #expect(mouth.settled(from: blinkOff).heldEyesOpenRate == 1)
    // Blinking back on drops it; the incoming held value is ignored.
    var on = blinkOff; on.blink = true; on.heldEyesOpenRate = 0.3
    #expect(on.settled(from: blinkOff).heldEyesOpenRate == nil)
    // A multi-field edit applies ChangeBlink before ChangeEyesOpen.
    var both = savedFace; both.blink = false; both.eyesOpen = 0.4
    #expect(both.settled(from: savedFace).heldEyesOpenRate == nil && both.settled(from: savedFace).eyesOpenRate == 0.4)
    // With openness 1 the forced 1 equals the replay and is stored as nil.
    var open = savedFace; open.eyesOpen = 1
    var openOff = open; openOff.blink = false
    #expect(openOff.settled(from: open).heldEyesOpenRate == nil)
}

@Test func sourceStudioExpressionControlsValidateEveryFieldAndAcceptSavedValues() throws {
    let controls = try SourceStudioExpressionControls(contract: expressionStateContract())
    #expect(controls.eyebrowPatternCount == 17 && controls.mouthPatternCount == 43 && controls.eyesPatternCount == 28)
    #expect(controls.eyeCatalogComplete && controls.eyeRows.map(\.id).contains(33) && controls.eyeRow(24)?.pattern == 2)
    try controls.validate(savedFace, saved: savedFace)
    let valid: [(String, (inout SourceStudioExpressionState) -> Void)] = [
        ("eyebrow 16", { $0.eyebrowPattern = 16 }), ("eyes 33", { $0.eyesPattern = 33 }), ("mouth 42", { $0.mouthPattern = 42 }),
        ("eyes open 0", { $0.eyesOpen = 0 }), ("mouth open 1", { $0.mouthOpen = 1 }), ("cheek 1", { $0.cheek = 1 }),
        ("blink", { $0.blink = false; $0.heldEyesOpenRate = 1 }), ("lip sync", { $0.lipSync = true }),
        ("eye look 4", { $0.eyesLookPattern = 4 }), ("neck 4", { $0.neckLookPattern = 4 }), ("tears 3", { $0.tears = 3 }),
    ]
    for (name, change) in valid {
        var state = savedFace; change(&state)
        #expect(throws: Never.self, Comment(rawValue: name)) { try controls.validate(state, saved: savedFace) }
    }
    let invalid: [(String, (inout SourceStudioExpressionState) -> Void)] = [
        ("eyebrow 17", { $0.eyebrowPattern = 17 }), ("eyebrow -1", { $0.eyebrowPattern = -1 }),
        ("eyes 22 (no row)", { $0.eyesPattern = 22 }), ("eyes 39", { $0.eyesPattern = 39 }), ("mouth 43", { $0.mouthPattern = 43 }),
        ("eyes open 1.01", { $0.eyesOpen = 1.01 }), ("eyes open nan", { $0.eyesOpen = .nan }), ("mouth open -0.1", { $0.mouthOpen = -0.1 }),
        ("cheek inf", { $0.cheek = .infinity }), ("eye look 5", { $0.eyesLookPattern = 5 }), ("neck 5", { $0.neckLookPattern = 5 }),
        ("tears 4", { $0.tears = 4 }), ("held while blinking", { $0.heldEyesOpenRate = 1 }),
        ("held out of range", { $0.blink = false; $0.heldEyesOpenRate = 2 }),
    ]
    for (name, change) in invalid {
        var state = savedFace; change(&state)
        #expect(throws: (any Error).self, Comment(rawValue: name)) { try controls.validate(state, saved: savedFace) }
    }
    // A saved value the panel cannot select (neck AWAY 2 here, an unknown
    // eyes row, a wide rate) stays acceptable so Reset never fails.
    var odd = savedFace; odd.eyesPattern = 77; odd.eyesOpen = 1.5; odd.tears = 9
    try controls.validate(odd, saved: odd)
    var fromOdd = odd; fromOdd.mouthPattern = 4
    try controls.validate(fromOdd, saved: odd)
    // A value that is neither saved nor a panel button is refused: neck
    // AWAY (2) has no NeckInfo button.
    let forward = savedFace.with { $0.neckLookPattern = 0 }
    #expect(throws: (any Error).self) { try controls.validate(forward.with { $0.neckLookPattern = 2 }, saved: forward) }
}

@Test func sourceStudioExpressionInputsMapRowsMouthFixedRateAndBlinkOffRates() throws {
    let contract = try expressionStateContract(), controls = try SourceStudioExpressionControls(contract: contract)
    let base = contract.defaults
    var state = savedFace
    state.eyesPattern = 24; state.eyebrowPattern = 9; state.mouthPattern = 21
    var inputs = controls.inputs(state, base: base)
    // Row 24 hands EyesPtn 2 to the FBS controller; mouth openness is the
    // mouth FixedRate (OCIChar.ChangeMouthOpen), not the voice-driven rate.
    #expect(inputs.eyesPattern == 2 && inputs.eyebrowPattern == 9 && inputs.mouthPattern == 21)
    #expect(inputs.mouthFixedRate == 0.25 && inputs.mouthOpenRate == base.mouthOpenRate && inputs.eyesOpenMax == 0.75)
    #expect(inputs.eyesOpenRate == base.eyesOpenRate && inputs.eyebrowOpenRate == base.eyebrowOpenRate)
    // Blinking off: the held (or replayed) eyes rate and eyebrows at 1.
    state.blink = false
    inputs = controls.inputs(state, base: base)
    #expect(inputs.eyesOpenRate == 0.75 && inputs.eyebrowOpenRate == 1)
    state.heldEyesOpenRate = 1
    #expect(controls.inputs(state, base: base).eyesOpenRate == 1)
    // An unknown saved row loads as row 0; out-of-range saved patterns keep
    // the contract default (FBS ChangePtn ignores them); wide rates clamp.
    var odd = savedFace; odd.eyesPattern = 77; odd.eyebrowPattern = 40; odd.mouthPattern = 50; odd.eyesOpen = 1.5; odd.mouthOpen = 3
    inputs = controls.inputs(odd, base: base)
    #expect(inputs.eyesPattern == 0 && inputs.eyebrowPattern == 0 && inputs.mouthPattern == 0)
    #expect(inputs.eyesOpenMax == 1 && inputs.mouthFixedRate == 1)
    // A contract without the full catalog maps IDs below the FBS count.
    let partial = try SourceStudioExpressionControls(contract: expressionStateContract(rows: false))
    #expect(!partial.eyeCatalogComplete && partial.eyeRows.count == 28 && partial.eyeRow(27)?.pattern == 27 && partial.eyeRow(33) == nil)
    #expect(partial.diagnostics(savedFace).contains { $0.contains("only the ordinary cha_eyeset rows") })
}

@Test func sourceStudioExpressionDiagnosticsNameEveryUndrawnField() throws {
    let controls = try SourceStudioExpressionControls(contract: expressionStateContract())
    #expect(controls.diagnostics(savedFace).isEmpty)
    var state = savedFace
    state.eyesPattern = 21; state.mouthPattern = 21; state.tears = 2; state.cheek = 0.5; state.lipSync = true
    let lines = controls.diagnostics(state)
    #expect(lines.count == 5)
    #expect(lines.contains { $0.contains("Eyes pattern 21") && $0.contains("gag-eye object 1") })
    #expect(lines.contains { $0.contains("Mouth pattern 21") && $0.contains("tongue") })
    #expect(lines.contains { $0.contains("Tears level 2") && $0.contains("not assembled") })
    #expect(lines.contains { $0.contains("Cheek 0.5") && $0.contains("_overcolor2") })
    #expect(lines.contains { $0.contains("Lip sync") })
    state = savedFace; state.eyesPattern = 77
    #expect(controls.diagnostics(state).first?.contains("not a cha_eyeset row") == true)
}

@Test func sourceStudioExpressionEditsDiffOnlyChangedSavedFields() throws {
    #expect(savedFace.statusEdit(from: savedFace).isEmpty && savedFace.mouthEdit(from: savedFace) == nil)
    var state = savedFace
    state.blink = false; state.heldEyesOpenRate = 1
    // The native held rate is not an original value: only eyesBlink moves.
    #expect(state.statusEdit(from: savedFace) == .init(eyesBlink: false) && state.mouthEdit(from: savedFace) == nil)
    state.mouthOpen = 0.5; state.lipSync = true; state.tears = 1; state.cheek = 0.25; state.neckLookPattern = 4
    #expect(state.statusEdit(from: savedFace) == .init(eyesBlink: false, neckLookPtn: 4, tearsLv: 1, hohoAkaRate: 0.25))
    #expect(state.mouthEdit(from: savedFace) == .init(mouthOpen: 0.5, lipSync: true))
    #expect(state.statusEdit(from: savedFace).editedKeys == ["eyesBlink", "neckLookPtn", "tearsLv", "hohoAkaRate"])
}

@Test func sourceStudioExpressionStateRoundTripsTheNativeDocumentAndLegacyDecodesNil() throws {
    var object = StudioObject(name: "Source character", kind: .character)
    object.sourceObjectKey = 42
    var state = savedFace; state.blink = false; state.heldEyesOpenRate = 1; state.eyesPattern = 24; state.cheek = 0.5
    object.sourceExpression = state
    var document = StudioDocument(); document.objects = [object]
    let encoded = try CardIO.encode(document, keyword: CardIO.sceneKeyword, thumbnail: nil)
    let decoded = try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: encoded)
    #expect(decoded == document && decoded.objects[0].sourceExpression == state)
    // A document written before the field existed decodes nil (saved state).
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
    var objects = try #require(legacy["objects"] as? [[String: Any]])
    objects[0].removeValue(forKey: "sourceExpression"); legacy["objects"] = objects
    let old = try JSONDecoder().decode(StudioDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(old.objects[0].sourceExpression == nil && old.objects[0].sourceObjectKey == 42)
}

@Test func sourceStudioExpressionContractRejectsMalformedEyeCatalogRows() throws {
    let contract = try expressionStateContract()
    #expect(contract.eyeCatalog?.rows?.count == 24 && contract.patternCount("mouth") == 43)
    func mutated(_ change: (inout [[String: Any]]) -> Void) throws -> Data {
        var root = try #require(JSONSerialization.jsonObject(with: expressionStateContractJSON()) as? [String: Any])
        var catalog = try #require(root["eyeCatalog"] as? [String: Any])
        var rows = try #require(catalog["rows"] as? [[String: Any]])
        change(&rows); catalog["rows"] = rows; root["eyeCatalog"] = catalog
        return try JSONSerialization.data(withJSONObject: root)
    }
    // A row whose FBS pattern is outside the eyes controller, or a duplicate
    // row ID, rejects the whole contract.
    #expect(throws: (any Error).self) { try SourceExpressionContract.decode(mutated { $0[3]["pattern"] = 28 }) }
    #expect(throws: (any Error).self) { try SourceExpressionContract.decode(mutated { $0[4]["id"] = 3 }) }
    #expect(throws: Never.self) { try SourceExpressionContract.decode(mutated { _ in }) }
}

private func expressionStateContractJSON() throws -> Data {
    let inputs: [String: Any] = [
        "eyebrowPattern": 0, "eyesPattern": 0, "mouthPattern": 0,
        "eyebrowOpenRate": 1, "eyesOpenRate": 1, "mouthOpenRate": 0,
        "eyebrowOpenMax": 1, "eyesOpenMax": 0.92, "mouthOpenMax": 1,
        "blinkRate": 1, "mouthFixedRate": -1,
    ]
    let controllers: [[String: Any]] = [("eyebrow", 17), ("eyes", 28), ("mouth", 43)].map { id, count in
        func channel(_ index: Int) -> [String: Any] { ["index": index, "name": "channel-\(index)", "frameIndex": index, "frameWeight": 100] }
        return ["id": id, "openMin": 0, "openMax": 1, "fixedRate": -0.1, "syncBlink": id == "eyebrow", "sourcePatternCount": count,
                "targets": [["nodeName": "face-node", "meshName": id, "meshSourceID": "synthetic:\(id)", "channelCount": 2,
                             "controlledChannelIndices": [0, 1],
                             "patterns": (0..<count).map { ["index": $0, "close": channel(0), "open": channel(1)] }]]]
    }
    let rows: [[String: Any]] = (0..<10).map { ["id": $0, "name": "row \($0)", "pattern": $0, "eyeBase": 1, "eyeHitomi": 1,
                                                "eyeObjectNumber": 0, "mainTexture": "0", "expressionTexture": "0"] }
    return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "weightUnit": "percent", "transitionSeconds": 0.15,
        "updateOrder": ["eyebrow", "eyes", "mouth"], "controllers": controllers, "defaults": inputs, "presets": [],
        "eyeCatalog": ["table": "cha_eyeset_00", "ordinaryRows": Array(rows.prefix(7)), "rows": rows]])
}

private extension SourceStudioExpressionState {
    func with(_ change: (inout SourceStudioExpressionState) -> Void) -> SourceStudioExpressionState {
        var copy = self; change(&copy); return copy
    }
}

@Test func sourceStudioExpressionSceneExportPatchesMouthBytesAndCardStatusThenReimports() throws {
    typealias F = OriginalCardFixture
    let status = F.pack(F.map([("version", .string("0.0.0")), ("coordinateType", .integer(1)), ("eyesPtn", .integer(0)),
                               ("tearsLv", .integer(0)), ("eyesBlink", .bool(true))]))
    let original = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene(card: try outfitCard(png: Data(), trailer: Data(), status: status)).data)
    let before = try #require(original.snapshot.roots[0].character)
    #expect(before.mouthOpen == 0.25 && before.lipSync)
    // Saved values write nothing.
    #expect(try original.editedData(.init(mouth: [10: .init(mouthOpen: 0.25, lipSync: true)])) == original.preservedData)
    // mouthOpen 0.25 -> 0.5 changes two bytes of its little-endian float and
    // lipSync one byte; the file keeps its length and every other byte.
    let changed = try original.editedData(.init(mouth: [10: .init(mouthOpen: 0.5, lipSync: false)]))
    #expect(changed.count == original.preservedData.count)
    let offsets = original.preservedData.indices.filter { original.preservedData[$0] != changed[$0] }
    // 0.25 = 00 00 80 3e and 0.5 = 00 00 00 3f (little endian): the float's
    // two high bytes, then the lipSync byte right after it.
    #expect(offsets.count == 3 && offsets[1] == offsets[0] + 1 && offsets[2] == offsets[0] + 2)
    #expect(original.preservedData[offsets[2]] == 1 && changed[offsets[2]] == 0)
    let after = try KoikatsuSceneReader.decodeDocument(changed)
    let record = try #require(after.snapshot.roots[0].character)
    #expect(record.mouthOpen == 0.5 && !record.lipSync && record.cardData == before.cardData)
    #expect(record.lookAtTarget == before.lookAtTarget && record.neckData == before.neckData && after.trailingData == original.trailingData)
    #expect(try after.editedData(.init(mouth: [10: .init(mouthOpen: 0.25, lipSync: true)])) == original.preservedData)
    // Out-of-range or nonfinite openness and unknown characters are refused.
    for value: Float in [1.5, -0.25, .nan] {
        #expect(throws: (any Error).self, Comment(rawValue: "\(value)")) { try original.editedData(.init(mouth: [10: .init(mouthOpen: value)])) }
    }
    #expect(throws: (any Error).self) { try original.editedData(.init(mouth: [20: .init(lipSync: false)])) }
    // Combined with the face-state Status edit in the embedded card: export ->
    // reimport reads every edited value back.
    let combined = try original.editedData(.init(cards: [10: .init(faceState: .init(eyesPtn: 24, eyesBlink: false, tearsLv: 2))],
                                                 mouth: [10: .init(mouthOpen: 0.75)]))
    let reread = try #require(KoikatsuSceneReader.decodeDocument(combined).snapshot.roots[0].character)
    let face = try reread.card().savedStatusFace()
    #expect(face.eyesPtn == 24 && !face.eyesBlink && face.tearsLv == 2 && reread.mouthOpen == 0.75 && reread.lipSync)
    #expect(try reread.card().savedStatusWear() == before.card().savedStatusWear())
}

private let expressionPreviewVariables = ["IKKOKU_STUDIO_SCENARIO_SCENE", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT",
                                          "IKKOKU_MAKER_LIBRARY", "IKKOKU_STUDIO_LOOK_SETTINGS"]

/// The Studio scenario scene's source character (`key`) with the converted
/// Maker library and the recovered look settings, as the app imports it.
private func expressionPreview(key: Int32 = 65) throws -> SourceStudioCharacterPreview {
    let scene = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_STUDIO_SCENARIO_SCENE"))
    let data = try Data(contentsOf: scene)
    let reference = SourceStudioCharacterReference(sceneFile: scene.path, sceneSHA256: OriginalCardFixture.hash(data),
        rigFile: try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR"),
        boneCatalogFile: try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT"), objectKey: key,
        makerLibraryFile: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY"),
        lookSettingsFile: try SourceFixtureSupport.require("IKKOKU_STUDIO_LOOK_SETTINGS"))
    return try SourceStudioCharacterPreview(reference: reference, resources: ResourceStore(device: try #require(MTLCreateSystemDefaultDevice())))
}

private func expressionFrameWeights(_ preview: SourceStudioCharacterPreview) throws -> [[Float]] {
    try preview.frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(), world: matrix_identity_float4x4, objectID: 1)
        .items.map { $0.morphWeights.flatMap { [Float($0.index), $0.weight] } }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(expressionPreviewVariables) && MTLCreateSystemDefaultDevice() != nil,
               "Requires the Studio scenario scene, source avatar, pose contract, Maker library, look settings and a Metal device"))
func sourceStudioExpressionEditRendersWithoutRebuildingAndRejectsAtomically() throws {
    let preview = try expressionPreview()
    let saved = preview.savedExpression
    #expect(preview.expressionState == saved)
    let rig = ObjectIdentifier(preview.preview), pose = preview.pose
    let before = try expressionFrameWeights(preview), inputsBefore = try #require(preview.expressionInputs)
    let diagnosticsBefore = preview.expressionDiagnostics
    // Each pattern and rate moves the rendered morph weights; nothing is
    // rebuilt (same SourceRigPreview instance and restored pose).
    let edits: [(String, (inout SourceStudioExpressionState) -> Void)] = [
        ("eyebrow", { $0.eyebrowPattern = $0.eyebrowPattern == 3 ? 4 : 3 }),
        ("eyes", { $0.eyesPattern = $0.eyesPattern == 2 ? 3 : 2 }),
        ("mouth", { $0.mouthPattern = $0.mouthPattern == 6 ? 7 : 6 }),
        ("mouth open", { $0.mouthOpen = $0.mouthOpen == 1 ? 0.5 : 1 }),
        ("eyes open", { $0.eyesOpen = 0.5 }),
        // Blinking off alone keeps open eyes open (forced rate 1); with the
        // slider moved the held openness shows.
        ("blink off + eyes open", { $0.blink = false; $0.eyesOpen = 0.5 }),
    ]
    for (name, change) in edits {
        var state = saved; change(&state)
        try preview.setExpressionState(state.settled(from: saved))
        #expect(try expressionFrameWeights(preview) != before, Comment(rawValue: name))
        #expect(ObjectIdentifier(preview.preview) == rig && preview.pose.localMatrices == pose.localMatrices, Comment(rawValue: name))
        try preview.setExpressionState(nil)
        #expect(try expressionFrameWeights(preview) == before && preview.expressionInputs == inputsBefore, Comment(rawValue: name))
    }
    // Tears and cheek have no default-path consumer: identical weights,
    // reported per character.
    var undrawn = saved; undrawn.tears = 2; undrawn.cheek = 0.5; undrawn.lipSync = !saved.lipSync
    try preview.setExpressionState(undrawn)
    #expect(try expressionFrameWeights(preview) == before)
    #expect(preview.expressionDiagnostics.contains { $0.hasPrefix("Tears level 2") } && preview.expressionDiagnostics.contains { $0.hasPrefix("Cheek 0.5") })
    // A rejected edit (an eyebrow pattern past the controller) changes nothing.
    var bad = saved; bad.mouthPattern = 3; bad.eyebrowPattern = 17
    #expect(throws: (any Error).self) { try preview.setExpressionState(bad) }
    #expect(preview.expressionState == undrawn)
    try preview.setExpressionState(nil)
    #expect(preview.expressionState == saved && preview.expressionDiagnostics == diagnosticsBefore)
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(expressionPreviewVariables) && MTLCreateSystemDefaultDevice() != nil,
               "Requires the Studio scenario scene, source avatar, pose contract, Maker library, look settings and a Metal device"))
func sourceStudioExpressionPortsBlinkFlagMouthFixedRateAndEyeLookGuide() throws {
    let preview = try expressionPreview()
    var saved = preview.savedExpression
    if !saved.blink {
        // Start from a blinking state so the toggle below is the State panel's.
        try preview.setExpressionState(saved.with { $0.blink = true }.settled(from: saved)); saved = preview.expressionState
    }
    var blinking = saved; blinking.eyesOpen = 0.5
    try preview.setExpressionState(blinking.settled(from: saved))
    // ChangeEyesBlinkFlag(false): the fixed sentinel, eyes and brows forced to 1.
    let off = preview.expressionState.with { $0.blink = false }.settled(from: preview.expressionState)
    try preview.setExpressionState(off)
    var inputs = try #require(preview.effectiveExpressionInputs())
    #expect(inputs.blinkRate == -1 && inputs.eyesOpenRate == 1 && inputs.eyebrowOpenRate == 1 && inputs.eyesOpenMax == 0.5)
    // ChangeEyesOpenMax while not blinking forces the slider's value.
    let slider = preview.expressionState.with { $0.eyesOpen = 0.25 }.settled(from: preview.expressionState)
    try preview.setExpressionState(slider)
    inputs = try #require(preview.effectiveExpressionInputs())
    #expect(slider.heldEyesOpenRate == nil && inputs.eyesOpenRate == 0.25 && inputs.eyesOpenMax == 0.25)
    // Mouth openness is the mouth FixedRate.
    try preview.setExpressionState(slider.with { $0.mouthOpen = 0.75 })
    #expect(preview.effectiveExpressionInputs()?.mouthFixedRate == 0.75)
    // Eye look pattern 4 aims at the look-at guide: the camera position no
    // longer changes the gaze, while pattern 1 (TARGET) follows it.
    func rates(pattern: Int, camera: Float3) throws -> [Double] {
        try preview.setExpressionState(preview.expressionState.with { $0.eyesLookPattern = pattern })
        preview.resetEyeLook()
        for _ in 0..<30 { try preview.updateEyeLook(deltaTime: 1 / 30, cameraModelPosition: camera) }
        let live = try #require(preview.eyeLookRates)
        return live.horizontal + [live.vertical]
    }
    let left = Float3(-2, 1.4, 1.5), right = Float3(2, 1.0, 1.5)
    #expect(try rates(pattern: 1, camera: left) != rates(pattern: 1, camera: right))
    #expect(preview.eyeLookFollowsGuide == false)
    #expect(try rates(pattern: 4, camera: left) == rates(pattern: 4, camera: right))
    #expect(preview.eyeLookFollowsGuide && preview.expressionDiagnostics.contains { $0.contains("look-at guide") })
    // A neck pattern edit re-resolves only the neck: FIX (4) holds the saved
    // fixAngle, and the eye runtime keeps running.
    try preview.setExpressionState(preview.expressionState.with { $0.neckLookPattern = 4 })
    #expect(!preview.hasLiveNeckLook && preview.eyeLookRates != nil)
    try preview.setExpressionState(preview.expressionState.with { $0.neckLookPattern = 1 })
    #expect(preview.hasLiveNeckLook && preview.eyeLookRates != nil)
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(expressionPreviewVariables) && MTLCreateSystemDefaultDevice() != nil,
               "Requires the Studio scenario scene, source avatar, pose contract, Maker library, look settings and a Metal device"))
func sourceStudioExpressionCheckpointKeepsCurrentNeckPatternAndGaze() throws {
    let preview = try expressionPreview()
    let kinematics = SourceStudioKinematicState(enableFK: false, enableIK: false,
        activeFK: [Bool](repeating: false, count: 7), activeIK: [Bool](repeating: false, count: 5))
    func pose() throws -> RigPose { try preview.editedPose(kinematics: kinematics, animationElapsed: 0.5) }
    func gaze(_ camera: Float3) throws {
        for _ in 0..<8 {
            try preview.updateNeckLook(deltaTime: 1 / 30, cameraModelPosition: camera,
                kinematics: kinematics, animationElapsed: 0.5)
        }
    }
    try preview.setExpressionState(preview.expressionState.with { $0.neckLookPattern = 4 })
    let fixed = try pose(), fixedCheckpoint = preview.captureDynamicsCheckpoint()
    try preview.setExpressionState(preview.expressionState.with { $0.neckLookPattern = 1 })
    try gaze(Float3(-2, 1.4, 1.5))
    let lookingLeft = try pose()
    #expect(lookingLeft.localMatrices != fixed.localMatrices)
    try preview.restoreDynamicsCheckpoint(fixedCheckpoint)
    #expect(preview.expressionState.neckLookPattern == 1)
    #expect(try pose().localMatrices == lookingLeft.localMatrices)

    // The pattern can stay the same while the live runtime changes. Rolling
    // back dynamics must retain the current gaze, including a runtime reset.
    let leftCheckpoint = preview.captureDynamicsCheckpoint()
    try gaze(Float3(2, 1, 1.5))
    let lookingRight = try pose()
    #expect(lookingRight.localMatrices != lookingLeft.localMatrices)
    try preview.restoreDynamicsCheckpoint(leftCheckpoint)
    #expect(try pose().localMatrices == lookingRight.localMatrices)
    let rightCheckpoint = preview.captureDynamicsCheckpoint()
    preview.resetNeckLook()
    let reset = try pose()
    #expect(reset.localMatrices != lookingRight.localMatrices)
    try preview.restoreDynamicsCheckpoint(rightCheckpoint)
    #expect(try pose().localMatrices == reset.localMatrices)
}
