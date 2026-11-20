import Foundation
import Studio
import Scene

extension StudioModel {
    /// The inspector's Play playlist (#445: off the main thread where it can
    /// be). The catalog and decoded clips are kept between plays
    /// (`SourceStudioVoiceLibrary`); a catalog or clip not kept yet loads in
    /// the background with "Loading voice…" shown, and plays when ready
    /// unless a newer play, a stop or a scene change came first. A stale
    /// load never reports.
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
            let voices = sourceAudioBus.voices, request = voices.request(id)
            if let catalog = voices.cachedCatalog(at: path) {
                try startSourceVoice(id, index: index, initial: inputs.initial, character: character, catalog: catalog, path: path)
                return
            }
            status = Self.sourceVoiceLoadingStatus
            voices.loadCatalog(at: path) { [weak self] result in
                guard let self, voices.isCurrent(id, request) else { return }
                do { try self.startSourceVoice(id, index: index, initial: inputs.initial, character: character, catalog: result.get(), path: path) }
                catch { self.status = "Voice: \(error)" }
            }
        } catch { status = "Voice: \(error)" }
    }
    /// Plays `id`'s playlist with `catalog`: a new player at the object's
    /// current voice state, its clip now when kept, else when loaded.
    private func startSourceVoice(_ id: UUID, index: Int, initial: SourceStudioVoiceState, character: SourceStudioVoiceCharacter,
                                  catalog: SourceStudioVoiceCatalog, path: String) throws {
        let bus = sourceAudioBus
        bus.voiceVolume = catalog.voiceVolume ?? 1
        let player = try SourceStudioVoicePlayer(bus: bus, state: doc.object(id)?.sourceVoice ?? initial,
            catalog: catalog, directory: URL(fileURLWithPath: path).deletingLastPathComponent(), pitch: character.pitch,
            volume: catalog.volume(personality: character.personality))
        sourceVoicePlayers[id] = player
        let started = try player.start(index: index) { [weak self, weak player] result in
            // Only the object's current player reports (`start` already
            // dropped a load its own stop or replay overtook).
            guard let self, let player, self.sourceVoicePlayers[id] === player else { return }
            switch result {
            case .success: self.status = "Playing voice playlist."
            case .failure(let error): self.status = "Voice: \(error)"
            }
        }
        switch started {
        case .playing: status = "Playing voice playlist."
        case .loading: status = Self.sourceVoiceLoadingStatus
        case .unavailable: status = "The voice playlist is empty or the selected index is unavailable."
        }
    }
    func stopSourceVoice(_ id: UUID) {
        sourceVoiceLibrary?.cancelRequest(id)
        sourceVoicePlayers.removeValue(forKey: id)?.dispose()
        if status == Self.sourceVoiceLoadingStatus { status = "Voice stopped." }
    }
    /// Stops every voice and releases what the voices kept (#445): New
    /// Scene, Open and an import's commit come here, so a scene that never
    /// plays a voice holds no catalog or clip.
    func stopSourceVoices() {
        for player in sourceVoicePlayers.values { player.dispose() }
        sourceVoicePlayers.removeAll(); sourceVoiceLibrary?.releaseAll(); stopSourceAudioOutput()
        if status == Self.sourceVoiceLoadingStatus { status = "Voice stopped." }
    }
    /// The status while a play waits for its catalog or clip; a stop that
    /// ends the wait replaces it.
    static let sourceVoiceLoadingStatus = "Loading voice…"
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
