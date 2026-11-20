import Foundation
import Testing
@preconcurrency import AVFAudio
import Studio

/// #445: the voices' kept catalog and clips, and the background play.
/// Generated tones and catalogs only.
private enum VoiceFixture {
    static let rows: [SourceStudioVoiceState.Selection] = [.init(group: 4, category: 5, no: 6), .init(group: 4, category: 5, no: 7)]

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-voice-library-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 48 kHz 16-bit mono tone of `seconds` at `amplitude`, written as the
    /// WAV `name` (the converter's format); returns its bytes. Written byte
    /// by byte: an `AVAudioFile` writer may still hold its last frames when
    /// the test reads the file.
    @discardableResult
    static func tone(_ name: String, in directory: URL, amplitude: Float, seconds: Double = 0.5) throws -> Data {
        let frames = Int(48_000 * seconds)
        var data = Data()
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + 2 * frames)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(48_000)); le(UInt32(96_000)); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(UInt32(2 * frames))
        for i in 0..<frames { le(Int16(amplitude * 32_767 * sin(2 * .pi * 440 * Float(i) / 48_000))) }
        try data.write(to: directory.appendingPathComponent(name))
        return data
    }

    /// A catalog whose rows name `files` with `hashes`, written as `catalog.json`.
    @discardableResult
    static func catalog(in directory: URL, files: [(file: String, sha256: String)]) throws -> URL {
        let entries = zip(rows, files).map { row, clip -> [String: Any] in
            ["group": row.group, "category": row.category, "no": row.no, "bundle": "generated", "asset": clip.file,
             "file": clip.file, "sha256": clip.sha256]
        }
        let url = directory.appendingPathComponent("catalog.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "kind": "ikkoku-studio-voice-catalog", "entries": entries])
            .write(to: url)
        return url
    }

    static func buffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)); buffer.frameLength = frames
        return buffer
    }

    /// The RMS of `passes` × 4096 rendered frames after the first pass.
    @MainActor static func renderRMS(_ bus: SourceStudioAudioBus, passes: Int = 4) throws -> (rms: Float, samples: [Float]) {
        let output = try #require(AVAudioPCMBuffer(pcmFormat: bus.engine.manualRenderingFormat, frameCapacity: 4096))
        var sum: Float = 0, samples: [Float] = []
        for pass in 0..<passes {
            #expect(try bus.engine.renderOffline(4096, to: output) == .success)
            if pass > 0 { for i in 0..<Int(output.frameLength) { let x = output.floatChannelData![0][i]; sum += x * x; samples.append(x) } }
        }
        return (sqrt(sum / Float(max(samples.count, 1))), samples)
    }
}

/// Reports collected by escaping main-actor callbacks.
@MainActor private final class Reports { var values: [Int] = [] }

/// A main-actor result handed back through a continuation; only the test's
/// main-actor code touches it.
private struct Handed<T>: @unchecked Sendable { let value: T }

@MainActor private func wait<T>(_ start: (@escaping @MainActor (Result<T, any Error>) -> Void) -> Void) async -> Result<T, any Error> {
    await withCheckedContinuation { (continuation: CheckedContinuation<Handed<Result<T, any Error>>, Never>) in
        start { continuation.resume(returning: Handed(value: $0)) }
    }.value
}

@MainActor @Test func sourceStudioVoiceCatalogIsReadOncePerUnchangedFile() async throws {
    let directory = try VoiceFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let data = try VoiceFixture.tone("a.wav", in: directory, amplitude: 0.25)
    let url = try VoiceFixture.catalog(in: directory, files: [("a.wav", OriginalCardFixture.hash(data))])
    let library = SourceStudioVoiceLibrary()
    #expect(library.cachedCatalog(at: url.path) == nil)
    let first = try await wait { library.loadCatalog(at: url.path, completion: $0) }.get()
    #expect(first.entries.count == 1 && library.catalogLoads == 1)
    // Kept: the same file gives the parsed catalog back without a read.
    let kept = try #require(library.cachedCatalog(at: url.path))
    #expect(kept.entries.count == 1 && library.catalogLoads == 1)
    #expect(try kept.clip(VoiceFixture.rows[0]) == .init(file: "a.wav", sha256: OriginalCardFixture.hash(data)))
    #expect(throws: (any Error).self) { try kept.clip(VoiceFixture.rows[1]) }
    // A changed file (another row) is read again.
    let other = try VoiceFixture.tone("b.wav", in: directory, amplitude: 0.5)
    try VoiceFixture.catalog(in: directory, files: [("a.wav", OriginalCardFixture.hash(data)), ("b.wav", OriginalCardFixture.hash(other))])
    #expect(library.cachedCatalog(at: url.path) == nil)
    let second = try await wait { library.loadCatalog(at: url.path, completion: $0) }.get()
    #expect(second.entries.count == 2 && library.catalogLoads == 2 && library.cachedCatalog(at: url.path) != nil)
    // Released (New Scene, Open): nothing is kept.
    library.releaseAll()
    #expect(library.cachedCatalog(at: url.path) == nil)
}

@MainActor @Test func sourceStudioVoiceClipsAreDecodedOnlyFromBytesOfTheirIdentity() async throws {
    let directory = try VoiceFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let quiet = try VoiceFixture.tone("a.wav", in: directory, amplitude: 0.25)
    let identity = OriginalCardFixture.hash(quiet), clip = SourceStudioVoiceCatalog.Clip(file: "a.wav", sha256: identity)
    let library = SourceStudioVoiceLibrary()
    let buffer = try await wait { library.loadClip(clip, directory: directory, completion: $0) }.get()
    #expect(buffer.frameLength == 24_000)
    #expect(library.clipLoads == 1)
    #expect(library.clipCount == 1)
    // The same samples as an independent decode of the file.
    let file = try AVAudioFile(forReading: directory.appendingPathComponent("a.wav"))
    let independent = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: independent)
    #expect(independent.frameLength == buffer.frameLength && independent.format == buffer.format)
    #expect(Array(UnsafeBufferPointer(start: independent.floatChannelData![0], count: Int(independent.frameLength)))
            == Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
    #expect(library.clip(identity) === buffer && library.clipHits == 1)
    // The file changes on disk: its identity's audio stays what was verified,
    // and a read of the file is refused.
    try VoiceFixture.tone("a.wav", in: directory, amplitude: 0.5)
    #expect(library.clip(identity) === buffer)
    #expect(throws: (any Error).self) { try SourceStudioVoiceLibrary.decode(clip, directory: directory) }
    // Once released, the next play reads the file again and fails, keeping nothing.
    library.releaseCaches()
    let changed = await wait { library.loadClip(clip, directory: directory, completion: $0) }
    #expect(throws: (any Error).self) { try changed.get() }
    #expect(library.clipCount == 0 && library.clipBytes == 0 && library.clipLoads == 2)
    // A row whose file escapes the catalog's folder is refused before any read.
    #expect(throws: (any Error).self) {
        try SourceStudioVoiceLibrary.decode(.init(file: "../a.wav", sha256: identity), directory: directory.appendingPathComponent("sub"))
    }
}

@MainActor @Test func sourceStudioVoiceClipCacheKeepsTheMostRecentlyPlayedWithinItsBytes() async throws {
    let one = try VoiceFixture.buffer(frames: 1000), bytes = SourceStudioVoiceLibrary.bytes(of: one)
    #expect(bytes == 4000)
    let library = SourceStudioVoiceLibrary(clipCapacityBytes: 2 * bytes)
    let two = try VoiceFixture.buffer(frames: 1000), three = try VoiceFixture.buffer(frames: 1000)
    library.insert(one, for: "1"); library.insert(two, for: "2")
    _ = library.clip("1")                       // 1 is now the most recently played
    library.insert(three, for: "3")             // so 2 goes
    #expect(library.clip("1") === one && library.clip("2") == nil && library.clip("3") === three)
    #expect(library.clipCount == 2 && library.clipBytes == 2 * bytes)
    // A clip larger than the whole cache is never kept and evicts nothing.
    library.insert(try VoiceFixture.buffer(frames: 3000), for: "big")
    #expect(library.clip("big") == nil && library.clipCount == 2)
    // Released: nothing is kept, and a load started before the release keeps nothing.
    let directory = try VoiceFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let data = try VoiceFixture.tone("a.wav", in: directory, amplitude: 0.25, seconds: 0.01)
    let clip = SourceStudioVoiceCatalog.Clip(file: "a.wav", sha256: OriginalCardFixture.hash(data))
    let loaded = await wait { completion in
        library.loadClip(clip, directory: directory, completion: completion)
        library.releaseCaches()
    }
    #expect((try? loaded.get()) != nil)
    #expect(library.clipCount == 0 && library.clipBytes == 0 && library.clip(clip.sha256) == nil)
}

@MainActor @Test func sourceStudioVoiceRequestsEndOnANewerPlayAStopOrARelease() {
    let library = SourceStudioVoiceLibrary(), a = UUID(), b = UUID()
    let first = library.request(a), other = library.request(b)
    #expect(library.isCurrent(a, first) && library.isCurrent(b, other))
    let second = library.request(a)
    #expect(!library.isCurrent(a, first) && library.isCurrent(a, second))
    library.cancelRequest(a)
    #expect(!library.isCurrent(a, second) && library.isCurrent(b, other))
    library.releaseAll()
    #expect(!library.isCurrent(b, other))
}

/// The background play schedules the same audio as the immediate one, a
/// replay of a kept clip reads no file, and a play the player overtook
/// never reports or plays.
@MainActor @Test func sourceStudioVoiceBackgroundPlayRendersTheImmediatePlaysSamples() async throws {
    let directory = try VoiceFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let quiet = try VoiceFixture.tone("a.wav", in: directory, amplitude: 0.25), loud = try VoiceFixture.tone("b.wav", in: directory, amplitude: 0.5)
    let url = try VoiceFixture.catalog(in: directory, files: [("a.wav", OriginalCardFixture.hash(quiet)), ("b.wav", OriginalCardFixture.hash(loud))])
    let catalog = try SourceStudioVoiceCatalog.load(url: url)
    let state = SourceStudioVoiceState(playlist: VoiceFixture.rows, repeatMode: 0)
    func player(_ bus: SourceStudioAudioBus) throws -> SourceStudioVoicePlayer {
        try SourceStudioVoicePlayer(bus: bus, state: state, catalog: catalog, directory: directory, pitch: 1, volume: 0.4)
    }
    // Immediate (the clip decoded on this thread).
    let immediateBus = SourceStudioAudioBus(); try immediateBus.enableOfflineRendering()
    let immediate = try player(immediateBus); defer { immediate.dispose(); immediateBus.stopOutput() }
    #expect(try immediate.play(index: 1))
    let reference = try VoiceFixture.renderRMS(immediateBus)
    // Background: loading first, then the same samples.
    let bus = SourceStudioAudioBus(); try bus.enableOfflineRendering()
    let background = try player(bus); defer { background.dispose(); bus.stopOutput() }
    var started: SourceStudioVoicePlayer.Start = .unavailable
    let result = await wait { completion in
        started = (try? background.start(index: 1) { completion($0.map { _ in true }) }) ?? .unavailable
    }
    #expect(started == .loading && (try? result.get()) == true && background.control.playing && background.control.index == 1)
    let rendered = try VoiceFixture.renderRMS(bus)
    #expect(rendered.samples == reference.samples && rendered.rms > 0.01)
    // A replay of the kept clip plays at once and reads no file.
    let loads = bus.voices.clipLoads
    #expect(try background.start(index: 1) { _ in Issue.record("a kept clip never reports a load") } == .playing)
    #expect(bus.voices.clipLoads == loads && bus.voices.clipHits == 1)
    // Two quick plays of clips not kept: only the later one plays and reports.
    bus.voices.releaseCaches()
    let reports = Reports()
    let last = await wait { completion in
        _ = try? background.start(index: 0) { _ in reports.values.append(0) }
        _ = try? background.start(index: 1) { result in reports.values.append(1); completion(result.map { _ in true }) }
    }
    #expect((try? last.get()) == true && reports.values == [1] && background.control.index == 1)
    let again = try VoiceFixture.renderRMS(bus)
    #expect(abs(again.rms / reference.rms - 1) < 0.01)
}

/// The kept clip is keyed by the converted audio's identity, never by its
/// file: a catalog that names the same file with another identity plays the
/// file's new audio, not what an earlier play kept.
@MainActor @Test func sourceStudioVoiceKeptClipsFollowTheirIdentityNotTheirFile() throws {
    let directory = try VoiceFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let quiet = try VoiceFixture.tone("a.wav", in: directory, amplitude: 0.25)
    let bus = SourceStudioAudioBus(); try bus.enableOfflineRendering(); defer { bus.stopOutput() }
    let state = SourceStudioVoiceState(playlist: [VoiceFixture.rows[0]], repeatMode: 0)
    func rms(_ url: URL) throws -> Float {
        let player = try SourceStudioVoicePlayer(bus: bus, state: state, catalog: SourceStudioVoiceCatalog.load(url: url),
                                                 directory: directory, pitch: 1, volume: 1)
        defer { player.dispose() }
        #expect(try player.play())
        return try VoiceFixture.renderRMS(bus).rms
    }
    let before = try rms(VoiceFixture.catalog(in: directory, files: [("a.wav", OriginalCardFixture.hash(quiet))]))
    // The converter rewrote the file and the catalog row's identity.
    let loud = try VoiceFixture.tone("a.wav", in: directory, amplitude: 0.5)
    let after = try rms(VoiceFixture.catalog(in: directory, files: [("a.wav", OriginalCardFixture.hash(loud))]))
    #expect(before > 0.01 && abs(after / before - 2) < 0.01)
    #expect(bus.voices.clipLoads == 0 && bus.voices.clipCount == 2)
}
