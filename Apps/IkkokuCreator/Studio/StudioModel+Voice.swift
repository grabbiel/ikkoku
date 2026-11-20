import Foundation
import Studio
import Scene

extension StudioModel {
    func playSourceVoice(_ id: UUID, index: Int = 0) {
        do {
            guard let object = doc.object(id), let path = doc.sourceVoiceCatalogFile ?? ProcessInfo.processInfo.environment["IKKOKU_STUDIO_VOICE_CATALOG"] else {
                throw RigError.invalid("Configure a converted Studio voice catalog before playback.")
            }
            // A-T02: the scene's own catalog failed its resource check; never read it.
            guard !resourceBlockedVoiceCatalogs.contains(path) || doc.sourceVoiceCatalogFile == nil else {
                throw RigError.invalid("The scene's voice catalog is unresolved; see the source compatibility details.")
            }
            if let previous = sourceVoicePlayers.removeValue(forKey: id) { previous.dispose() }
            let inputs = try sourceVoiceInputs(object)
            let character = try inputs.character.get()
            let catalogURL = URL(fileURLWithPath: path), catalog = try SourceStudioVoiceCatalog.load(url: catalogURL)
            sourceAudioBus.voiceVolume = catalog.voiceVolume ?? 1
            let player = try SourceStudioVoicePlayer(bus: sourceAudioBus, state: object.sourceVoice ?? inputs.initial,
                catalog: catalog, directory: catalogURL.deletingLastPathComponent(), pitch: character.pitch, volume: catalog.volume(personality: character.personality))
            sourceVoicePlayers[id] = player
            if try player.play(index: index) { status = "Playing voice playlist." }
            else { status = "The voice playlist is empty or the selected index is unavailable." }
        } catch { status = "Voice: \(error)" }
    }
    func stopSourceVoice(_ id: UUID) { sourceVoicePlayers.removeValue(forKey: id)?.dispose() }
    func stopSourceVoices() {
        for player in sourceVoicePlayers.values { player.dispose() }
        sourceVoicePlayers.removeAll(); stopSourceAudioOutput()
    }
    func pruneSourceVoices() {
        let ids = Set(doc.objects.filter { $0.sourceCharacter != nil }.map(\.id))
        for id in sourceVoicePlayers.keys.filter({ !ids.contains($0) }) { stopSourceVoice(id) }
        // #437: once per scene change, never per edit, the voice inputs keep
        // only the references the document and its history hold.
        guard doc.sourceSceneSHA256 != sourceVoiceInputScene else { return }
        sourceVoiceInputScene = doc.sourceSceneSHA256
        var keys = Set<SourceStudioVoiceInputCache.Key>()
        for object in doc.objects { if let reference = object.sourceCharacter { keys.insert(.init(reference)) } }
        undoHistory.forEachObject { object in if let reference = object.sourceCharacter { keys.insert(.init(reference)) } }
        sourceVoiceInputCache.retain(keys)
        if let pending = sourceVoicePendingCheck,
           !pending.keys.contains(where: { keys.contains(.init(sceneSHA256: pending.sceneSHA256, objectKey: $0)) }) {
            pending.check.cancel(); sourceVoicePendingCheck = nil
        }
    }
    func setSourceVoiceRepeat(_ id: UUID, mode: Int32) {
        do {
            guard (0...2).contains(mode), let object = doc.object(id) else { throw RigError.invalid("Invalid voice repeat setting.") }
            // The saved state alone: a card the voice cannot read never blocks a repeat change.
            var voice = try object.sourceVoice ?? sourceVoiceInputs(object).initial
            voice.repeatMode = mode
            update(id) { $0.sourceVoice = voice }
            sourceVoicePlayers[id]?.repeatMode = mode
        } catch { status = "Voice: \(error)" }
    }
    /// What a voice play or repeat change reads for `object` (#437): the
    /// cache's entry; else the built preview's, read without settling the
    /// live step (`sourceVoicePreviewInputs`); else a native reload's check;
    /// else one read of the scene file, under today's SHA guard and errors.
    /// Each is kept, so a character's scene is decoded at most once. Built
    /// and cached characters play the content they were imported with, as
    /// their previews show it; a scene file changed since is not read again.
    func sourceVoiceInputs(_ object: StudioObject) throws -> SourceStudioVoiceInputs {
        guard let reference = object.sourceCharacter else { throw RigError.invalid("Selected object is not an original character.") }
        let key = SourceStudioVoiceInputCache.Key(reference)
        if !sourceVoiceInputCache.contains(key), let pending = sourceVoicePendingCheck,
           pending.sceneSHA256 == key.sceneSHA256, pending.keys.contains(key.objectKey) {
            // Waits for the check's worker, done long before a click.
            for (objectKey, inputs) in zip(pending.keys, pending.check.voiceInputs()) {
                sourceVoiceInputCache.insert(inputs, for: .init(sceneSHA256: pending.sceneSHA256, objectKey: objectKey))
            }
            sourceVoicePendingCheck = nil
        }
        return try sourceVoiceInputCache.inputs(for: reference, built: sourceVoicePreviewInputs(object.id, reference: reference))
    }
}
