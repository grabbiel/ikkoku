import Foundation
import Testing
@testable import Studio
import Character
import Scene

/// #437: a Studio voice play reads its card voice parameters and saved
/// playlist from what already holds them (a built preview, the import's
/// hidden card check, a reload's check, the cache) and decodes a scene at
/// most once per scene and character. `SourceSceneDecodeProbe` counts the
/// decodes on the decode entry points, for this test's task alone.
private struct VoiceScene {
    let directory: URL, file: URL, bytes: Data
    let reference: SourceStudioCharacterReference, record: KoikatsuCharacterRecord

    init(card: Data = OriginalCardFixture.card(), key: Int32 = 10) throws {
        bytes = SceneDocumentBytes.scene(card: card).data
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-voice-inputs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("scene.png")
        try bytes.write(to: file)
        reference = SourceStudioCharacterReference(sceneFile: file.path, sceneSHA256: OriginalCardFixture.hash(bytes),
            rigFile: "rig", boneCatalogFile: "bones", objectKey: key)
        // Decoded outside any probe, as a build or an import decodes it.
        record = try #require(KoikatsuSceneReader.decodeDocument(bytes).snapshot.roots[0].character)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// The card's voice parameters as a play reads them, or the error a play rethrows.
private func voice(_ inputs: SourceStudioVoiceInputs) -> String {
    switch inputs.character {
    case .success(let character): "personality \(character.personality) pitch \(character.pitch)"
    case .failure(let error): "error \(error)"
    }
}

private func expectedVoice(_ record: KoikatsuCharacterRecord) -> String {
    do {
        let character = try SourceStudioVoiceCharacter(card: record.card())
        return "personality \(character.personality) pitch \(character.pitch)"
    } catch { return "error \(error)" }
}

private func parameterCard(personality: Int64) -> Data {
    var blocks = OriginalCardFixture.blocks()
    blocks.removeAll { $0.name == "Parameter" }
    blocks.append(.init(name: "Parameter", version: "0.0.5", data: OriginalCardFixture.pack(OriginalCardFixture.map([
        ("personality", .integer(personality)), ("voiceRate", .float(0.25))]))))
    return OriginalCardFixture.card(blocks: blocks)
}

@Test func aVoicePlayOnABuiltCharacterDecodesNoScene() throws {
    let scene = try VoiceScene(card: parameterCard(personality: 21)); defer { scene.remove() }
    // What the build's first half computes from the card it decoded.
    let built = SourceStudioVoiceInputs(card: Result { try scene.record.card() }, record: scene.record)
    var cache = SourceStudioVoiceInputCache()
    let probe = SourceSceneDecodeProbe()
    let resolved = try SourceSceneDecodeProbe.$current.withValue(probe) {
        try (0..<5).map { _ in try cache.inputs(for: scene.reference, built: built) }
    }
    #expect(probe.count == 0)
    for inputs in resolved {
        #expect(inputs.initial == SourceStudioVoiceState(record: scene.record))
        #expect(voice(inputs) == expectedVoice(scene.record))
    }
    #expect(voice(resolved[0]).hasPrefix("personality 21 "))
    // Kept: with the preview gone, the next play still decodes nothing.
    let later = try SourceSceneDecodeProbe.$current.withValue(probe) { try cache.inputs(for: scene.reference, built: nil) }
    #expect(probe.count == 0 && later.initial == resolved[0].initial)
}

@Test func aVoicePlayOnAnUnbuiltCharacterDecodesItsSceneAtMostOnce() throws {
    let first = try VoiceScene(card: parameterCard(personality: 3)), second = try VoiceScene(card: parameterCard(personality: 4))
    defer { first.remove(); second.remove() }
    #expect(first.reference.sceneSHA256 != second.reference.sceneSHA256)
    var cache = SourceStudioVoiceInputCache()
    let probe = SourceSceneDecodeProbe()
    try SourceSceneDecodeProbe.$current.withValue(probe) {
        for _ in 0..<3 { _ = try cache.inputs(for: first.reference, built: nil) }
        #expect(probe.count == 1)
        // The same object key in another scene is another character.
        for _ in 0..<3 { _ = try cache.inputs(for: second.reference, built: nil) }
        #expect(probe.count == 2)
    }
    let inputs = try cache.inputs(for: first.reference, built: nil)
    #expect(inputs.initial == SourceStudioVoiceState(record: first.record) && voice(inputs).hasPrefix("personality 3 "))
    #expect(voice(try cache.inputs(for: second.reference, built: nil)).hasPrefix("personality 4 "))

    // A record the scene does not hold: today's error, and nothing kept.
    let missing = SourceStudioCharacterReference(sceneFile: first.file.path, sceneSHA256: first.reference.sceneSHA256,
        rigFile: "rig", boneCatalogFile: "bones", objectKey: 99)
    #expect(throws: (any Error).self) { _ = try cache.inputs(for: missing, built: nil) }
    do { _ = try cache.inputs(for: missing, built: nil) } catch { #expect("\(error)".contains("Original voice character is missing.")) }
    #expect(cache.count == 2)

    // The file changed since the import: a key no one covered fails with
    // today's error before any decode and keeps nothing; a covered key still
    // plays the content its reference names (no per-play recheck).
    try second.bytes.write(to: first.file)
    var cold = SourceStudioVoiceInputCache()
    let changed = SourceSceneDecodeProbe()
    SourceSceneDecodeProbe.$current.withValue(changed) {
        do { _ = try cold.inputs(for: first.reference, built: nil); Issue.record("a changed scene file resolved") } catch {
            #expect("\(error)".contains("Original voice scene changed; reimport before playing."))
        }
    }
    #expect(changed.count == 0 && cold.count == 0)
    let warm = try SourceSceneDecodeProbe.$current.withValue(changed) { try cache.inputs(for: first.reference, built: nil) }
    #expect(changed.count == 0 && voice(warm).hasPrefix("personality 3 "))
}

@Test func anImportsHiddenCardCheckGivesTheVoiceInputsWithNoSceneDecode() throws {
    let scene = try VoiceScene(card: parameterCard(personality: 21)); defer { scene.remove() }
    let queue = DispatchQueue(label: "com.grabbiel.Ikkoku.tests.437")
    let probe = SourceSceneDecodeProbe()
    var cache = SourceStudioVoiceInputCache()
    try SourceSceneDecodeProbe.$current.withValue(probe) {
        let check = SourceStudioCharacterPreview.CardCheck(records: [scene.record], queue: queue)
        queue.sync {}
        let voices = check.voiceInputs()
        #expect(voices.count == 1 && check.problems().count == 1)
        cache.insert(voices[0], for: .init(scene.reference))
        for _ in 0..<3 {
            let inputs = try cache.inputs(for: scene.reference, built: nil)
            #expect(inputs.initial == SourceStudioVoiceState(record: scene.record) && voice(inputs) == expectedVoice(scene.record))
        }
    }
    #expect(probe.count == 0)
}

@Test func aNativeReloadFindsTheDocumentsCharacterRecordsInOneWalk() throws {
    let scene = try VoiceScene(); defer { scene.remove() }
    let document = try KoikatsuSceneReader.decodeDocument(scene.bytes)
    let found = SourceStudioCharacterPreview.characterRecords([10, 99], in: document)
    #expect(Array(found.keys) == [10])
    let record = try #require(found[10])
    #expect(record.accessoryChildren.isEmpty && record.cardData == scene.record.cardData)
    #expect(SourceStudioVoiceInputs(record: record).initial == SourceStudioVoiceState(record: scene.record))
}

@Test func aRepeatChangeReadsTheSavedStateEvenWhenTheCardHasNoVoiceParameters() throws {
    var blocks = OriginalCardFixture.blocks()
    blocks.removeAll { $0.name == "Parameter" }
    let scene = try VoiceScene(card: OriginalCardFixture.card(blocks: blocks)); defer { scene.remove() }
    var cache = SourceStudioVoiceInputCache()
    let inputs = try cache.inputs(for: scene.reference, built: nil)
    #expect(inputs.initial == SourceStudioVoiceState(record: scene.record))
    #expect(throws: (any Error).self) { _ = try inputs.character.get() }
    #expect(voice(inputs).contains("Source character has no voice parameters."))
}
