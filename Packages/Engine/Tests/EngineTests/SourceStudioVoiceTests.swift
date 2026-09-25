import Foundation
import Testing
@preconcurrency import AVFAudio
import Studio
import Character
import Scene
import Gameplay

private let voiceSelections: [SourceStudioVoiceState.Selection] = [.init(group: 4, category: 5, no: 6), .init(group: 4, category: 5, no: 7)]

@Test func sourceStudioVoiceOrderedNoneAllSelectAndStopMatchRecoveredControl() throws {
    for mode: Int32 in [0,1,2] {
        var control = try SourceStudioVoiceControl(state: .init(playlist: voiceSelections, repeatMode: mode))
        #expect(control.index == -1 && !control.playing) // Scene load never auto-plays.
        let started = control.play(0, available: true); #expect(started)
        let completed = control.completed(); let next = try #require(completed)
        #expect(next == (mode == 2 ? 0 : 1))
        let nextStarted = control.play(next, available: true); #expect(nextStarted)
        let finished = control.completed(); let last = try #require(finished)
        #expect(last == (mode == 0 ? 2 : 0))
        let restarted = control.play(last, available: true); #expect(restarted == (mode != 0))
        if mode == 0 { #expect(control.index == -1 && !control.playing) }
        control.stop(); let ignored = control.completed(); #expect(ignored == nil)
    }
    var control = try SourceStudioVoiceControl(state: .init(playlist: voiceSelections, repeatMode: 0))
    let started = control.play(0, available: true), invalid = control.play(5, available: true)
    #expect(started && !invalid)
    #expect(control.playing && control.index == -1) // Range check happens before Stop.
    let afterInvalid = control.completed(); #expect(afterInvalid == 0)
    let missing = control.play(1, available: false); #expect(!missing && !control.playing)
}

@Test func sourceStudioVoicePitchUsesCardVoiceRateAndClampedLerp() throws {
    for (rate, expected): (Double, Float) in [(-1,0.94),(0,0.94),(0.5,1),(1,1.06),(2,1.06)] {
        var blocks = OriginalCardFixture.blocks()
        blocks.removeAll { $0.name == "Parameter" }
        // Original card parameters are MessagePack maps, not native card sliders.
        blocks.append(.init(name: "Parameter", version: "0.0.5", data: OriginalCardFixture.pack(OriginalCardFixture.map([
            ("personality",.integer(21)),("voiceRate",.float(rate))]))))
        let card = try SourceCharacterCard.decode(OriginalCardFixture.card(blocks: blocks))
        let value = try SourceStudioVoiceCharacter(card: card)
        #expect(value.personality == 21 && abs(value.pitch - expected) < 0.000001)
    }
}

@Test func sourceStudioVoiceEditedPlaylistPreservesOrderIdentityAndTrailingData() throws {
    let original = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    let before = try #require(original.snapshot.roots[0].character)
    let state = SourceStudioVoiceState(playlist: [voiceSelections[1], voiceSelections[0], voiceSelections[1]], repeatMode: 1)
    let changed = try original.editedData(.init(voices: [10: state])), after = try KoikatsuSceneReader.decodeDocument(changed)
    let record = try #require(after.snapshot.roots[0].character)
    #expect(SourceStudioVoiceState(record: record) == state)
    #expect(record.cardData == before.cardData && record.animation == before.animation && record.animationNormalizedTime == before.animationNormalizedTime)
    #expect(record.neckData == before.neckData && after.settings == original.settings && after.trailingData == original.trailingData)
    #expect(try after.editedData(.init(voices: [10: .init(record: before)])) == original.preservedData)
    #expect(throws: (any Error).self) { try original.editedData(.init(voices: [20: state])) }
}

@MainActor @Test func sourceStudioVoiceNativeOfflineMasterVolumePreservesPerVoiceGain() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-generated-voice-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)); buffer.frameLength = 48_000
    let samples = try #require(buffer.floatChannelData)[0]
    for i in 0..<48_000 { samples[i] = 0.25 * sin(2 * .pi * 440 * Float(i) / 48_000) }
    let tone = directory.appendingPathComponent("generated-440hz.wav")
    do { let file = try AVAudioFile(forWriting: tone, settings: format.settings); try file.write(from: buffer) }
    let data = try Data(contentsOf: tone)
    let manifest: [String: Any] = ["schemaVersion": 1, "kind": "ikkoku-studio-voice-catalog", "entries": [
        ["group": 4,"category": 5,"no": 6,"bundle": "generated-test-tone", "asset": "440hz", "file": tone.lastPathComponent,"sha256": OriginalCardFixture.hash(data)]]]
    let catalogURL = directory.appendingPathComponent("catalog.json")
    try JSONSerialization.data(withJSONObject: manifest).write(to: catalogURL)
    let catalog = try SourceStudioVoiceCatalog.load(url: catalogURL)
    func render(master: Float, loseFocus: Bool = false, restoreFocus: Bool = false) throws -> Float {
        let bus = SourceStudioAudioBus(); try bus.enableOfflineRendering(); bus.masterVolume = master
        let mute = SourceMuteInBackgroundPlugin(enabled: true, readVolume: { bus.masterVolume }, writeVolume: { bus.masterVolume = $0 })
        if loseFocus { mute.onApplicationFocus(false) }
        if restoreFocus { mute.onApplicationFocus(true) }
        let player = try SourceStudioVoicePlayer(bus: bus, state: .init(playlist: [voiceSelections[0]], repeatMode: 0),
            catalog: catalog, directory: directory, pitch: 1, volume: 0.4)
        defer { player.dispose(); bus.stopOutput() }
        #expect(try player.play())
        #expect(player.volume == 0.4 && bus.masterVolume == (loseFocus && !restoreFocus ? 0 : master))
        let output = try #require(AVAudioPCMBuffer(pcmFormat: bus.engine.manualRenderingFormat, frameCapacity: 4096))
        var sum: Float = 0, count = 0
        for pass in 0..<4 {
            let status = try bus.engine.renderOffline(4096, to: output)
            #expect(status == .success)
            if pass > 0 { for i in 0..<Int(output.frameLength) { let x = output.floatChannelData![0][i]; sum += x*x; count += 1 } }
        }
        #expect(player.elapsedSourceSeconds > 0 && player.volume == 0.4)
        player.stop(); #expect(!player.control.playing)
        return sqrt(sum / Float(count))
    }
    let full = try render(master: 1), quiet = try render(master: 0.25), mute = try render(master: 0)
    #expect(full > 0.01 && abs(quiet / full - 0.25) < 0.002 && mute == 0)
    let background = try render(master: 0.73, loseFocus: true), foreground = try render(master: 0.73, loseFocus: true, restoreFocus: true)
    #expect(background == 0 && abs(foreground / full - 0.73) < 0.002)
    try Data([0]).write(to: tone)
    #expect(throws: (any Error).self) { try catalog.asset(voiceSelections[0], directory: directory) }
    #expect(throws: (any Error).self) { try catalog.asset(voiceSelections[1], directory: directory) }
}
