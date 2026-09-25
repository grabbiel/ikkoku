import Foundation
import CryptoKit
import Studio
import Scene

extension StudioModel {
    func playSourceVoice(_ id: UUID, index: Int = 0) {
        do {
            guard let object = doc.object(id), let path = doc.sourceVoiceCatalogFile ?? ProcessInfo.processInfo.environment["IKKOKU_STUDIO_VOICE_CATALOG"] else {
                throw RigError.invalid("Configure a converted Studio voice catalog before playback.")
            }
            if let previous = sourceVoicePlayers.removeValue(forKey: id) { previous.dispose() }
            let record = try sourceVoiceRecord(object)
            let character = try SourceStudioVoiceCharacter(card: record.card())
            let catalogURL = URL(fileURLWithPath: path), catalog = try SourceStudioVoiceCatalog.load(url: catalogURL)
            sourceAudioBus.voiceVolume = catalog.voiceVolume ?? 1
            let player = try SourceStudioVoicePlayer(bus: sourceAudioBus, state: object.sourceVoice ?? .init(record: record),
                catalog: catalog, directory: catalogURL.deletingLastPathComponent(), pitch: character.pitch, volume: catalog.volume(personality: character.personality))
            sourceVoicePlayers[id] = player
            if try player.play(index: index) { status = "Playing voice playlist." }
            else { status = "The voice playlist is empty or the selected index is unavailable." }
        } catch { status = "Voice: \(error)" }
    }
    func stopSourceVoice(_ id: UUID) { sourceVoicePlayers.removeValue(forKey: id)?.dispose() }
    func stopSourceVoices() {
        for player in sourceVoicePlayers.values { player.dispose() }
        sourceVoicePlayers.removeAll(); sourceAudioBus.stopOutput()
    }
    func pruneSourceVoices() {
        let ids = Set(doc.objects.filter { $0.sourceCharacter != nil }.map(\.id))
        for id in sourceVoicePlayers.keys.filter({ !ids.contains($0) }) { stopSourceVoice(id) }
    }
    func setSourceVoiceRepeat(_ id: UUID, mode: Int32) {
        do {
            guard (0...2).contains(mode), let object = doc.object(id) else { throw RigError.invalid("Invalid voice repeat setting.") }
            var voice = try object.sourceVoice ?? SourceStudioVoiceState(record: sourceVoiceRecord(object))
            voice.repeatMode = mode
            update(id) { $0.sourceVoice = voice }
            sourceVoicePlayers[id]?.repeatMode = mode
        } catch { status = "Voice: \(error)" }
    }
    private func sourceVoiceRecord(_ object: StudioObject) throws -> KoikatsuCharacterRecord {
        guard let reference = object.sourceCharacter else { throw RigError.invalid("Selected object is not an original character.") }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: reference.sceneFile)); defer { try? handle.close() }
        let data = try handle.read(upToCount: 256 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 256 * 1024 * 1024, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == reference.sceneSHA256 else {
            throw RigError.invalid("Original voice scene changed; reimport before playing.")
        }
        var stack = try KoikatsuSceneReader.decodeDocument(data).snapshot.roots
        while let record = stack.popLast() {
            if record.sourceKey == reference.objectKey, let character = record.character { return character }
            stack += record.children
            for children in (record.character?.accessoryChildren ?? [:]).values { stack += children }
        }
        throw RigError.invalid("Original voice character is missing.")
    }
}
