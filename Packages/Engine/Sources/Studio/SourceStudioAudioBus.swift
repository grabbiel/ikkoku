import Foundation
@preconcurrency import AVFAudio
import Scene

/// Native voice output. Master gain is a distinct mixer stage, so the installed
/// AudioListener.volume adapter never overwrites personality/per-voice gains.
@MainActor public final class SourceStudioAudioBus {
    public let engine: AVAudioEngine
    public let voiceMixer: AVAudioMixerNode
    /// The voices' parsed catalog and decoded clips, kept between plays (#445).
    public let voices = SourceStudioVoiceLibrary()
    public var voiceVolume: Float {
        get { voiceMixer.outputVolume }
        set { if newValue.isFinite { voiceMixer.outputVolume = min(max(newValue, 0), 1) } }
    }
    public var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { if newValue.isFinite { engine.mainMixerNode.outputVolume = min(max(newValue, 0), 1) } }
    }
    public init() {
        engine = AVAudioEngine(); voiceMixer = AVAudioMixerNode()
        engine.attach(voiceMixer); engine.connect(voiceMixer, to: engine.mainMixerNode, format: nil)
    }
    public func startOutput() throws { if !engine.isRunning { try engine.start() } }
    public func stopOutput() { engine.stop() }
    /// Offline rendering is for deterministic generated-tone verification. It
    /// does not connect/start the hardware output device.
    public func enableOfflineRendering(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2) throws {
        guard sampleRate.isFinite, sampleRate > 0, channels == 1 || channels == 2,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            throw RigError.invalid("Invalid offline voice format.")
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    }
}

@MainActor public final class SourceStudioVoicePlayer {
    public let bus: SourceStudioAudioBus
    public private(set) var control: SourceStudioVoiceControl
    public let pitch: Float
    public var volume: Float {
        get { mixer.outputVolume }
        set { if newValue.isFinite { mixer.outputVolume = min(max(newValue, 0), 1) } }
    }
    public private(set) var diagnostic: String?
    public var repeatMode: Int32 {
        get { control.state.repeatMode }
        set { control.state.repeatMode = newValue }
    }
    private let catalog: SourceStudioVoiceCatalog, directory: URL
    private let node = AVAudioPlayerNode(), rate = AVAudioUnitVarispeed(), mixer = AVAudioMixerNode()
    private var generation: UInt64 = 0
    private var connected = false
    public init(bus: SourceStudioAudioBus, state: SourceStudioVoiceState, catalog: SourceStudioVoiceCatalog,
                directory: URL, pitch: Float = 1, volume: Float = 1) throws {
        guard pitch.isFinite, (0.25...4).contains(pitch), volume.isFinite, (0...1).contains(volume) else { throw RigError.invalid("Invalid Studio voice pitch or volume.") }
        self.bus = bus; control = try .init(state: state); self.catalog = catalog; self.directory = directory; self.pitch = pitch
        bus.engine.attach(node); bus.engine.attach(rate); bus.engine.attach(mixer)
        rate.rate = pitch; mixer.outputVolume = volume
    }
    /// Plays playlist entry `index` now: a clip the bus's `voices` hold plays
    /// at once, another is read, verified and decoded on the caller's thread
    /// first (offline renders and checks; the Studio uses `start`).
    @discardableResult public func play(index: Int = 0) throws -> Bool {
        guard control.state.playlist.indices.contains(index) else { return control.play(index, available: false) }
        stop()
        let clip = try resolve(index)
        if let buffer = bus.voices.clip(clip.sha256) { try schedule(buffer, index: index); return true }
        let buffer: AVAudioPCMBuffer
        do { buffer = try SourceStudioVoiceLibrary.decode(clip, directory: directory) }
        catch { unavailable(index, error); throw error }
        bus.voices.insert(buffer, for: clip.sha256)
        try schedule(buffer, index: index)
        return true
    }

    /// How `start` began a play.
    public enum Start: Sendable, Equatable {
        /// The clip was cached: it plays now.
        case playing
        /// The clip loads off the main thread; `loaded` reports the play.
        case loading
        /// The playlist is empty or `index` is outside it.
        case unavailable
    }

    /// #445: the Studio's play of playlist entry `index`. A cached clip plays
    /// at once; another is read, verified and decoded off the main thread
    /// (`SourceStudioVoiceLibrary.loadClip`), and plays when it is ready
    /// unless the player stopped or started another play since, which
    /// discards it without a report. `loaded` reports the play that a load
    /// started or failed, on the main thread.
    @discardableResult public func start(index: Int = 0, loaded: @escaping @MainActor (Result<Void, any Error>) -> Void) throws -> Start {
        guard control.state.playlist.indices.contains(index) else { _ = control.play(index, available: false); return .unavailable }
        stop()
        let clip = try resolve(index)
        if let buffer = bus.voices.clip(clip.sha256) { try schedule(buffer, index: index); return .playing }
        let expected = generation
        bus.voices.loadClip(clip, directory: directory) { [weak self] result in
            guard let self, self.generation == expected else { return }
            do { try self.schedule(result.get(), index: index); loaded(.success(())) }
            catch { self.unavailable(index, error); loaded(.failure(error)) }
        }
        return .loading
    }

    /// The playlist entry's converted clip, or the error a missing row gives.
    private func resolve(_ index: Int) throws -> SourceStudioVoiceCatalog.Clip {
        do { return try catalog.clip(control.state.playlist[index]) }
        catch { unavailable(index, error); throw error }
    }

    private func unavailable(_ index: Int, _ error: any Error) {
        _ = control.play(index, available: false); diagnostic = String(describing: error)
    }

    /// Connects the graph for `buffer` and plays it; at its end the playlist
    /// advances through `start`, as a click would.
    private func schedule(_ buffer: AVAudioPCMBuffer, index: Int) throws {
        if connected { bus.engine.disconnectNodeOutput(node); bus.engine.disconnectNodeOutput(rate); bus.engine.disconnectNodeOutput(mixer) }
        bus.engine.connect(node, to: rate, format: buffer.format)
        bus.engine.connect(rate, to: mixer, format: buffer.format)
        bus.engine.connect(mixer, to: bus.voiceMixer, format: buffer.format)
        connected = true
        try bus.startOutput()
        _ = control.play(index, available: true); diagnostic = nil
        let expected = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected, let next = self.control.completed() else { return }
                do {
                    _ = try self.start(index: next) { [weak self] result in
                        if case .failure(let error) = result { self?.diagnostic = String(describing: error) }
                    }
                } catch { self.diagnostic = String(describing: error) }
            }
        }
        node.play()
    }
    public func stop() { generation &+= 1; node.stop(); control.stop() }
    public func dispose() {
        stop(); bus.engine.detach(node); bus.engine.detach(rate); bus.engine.detach(mixer); connected = false
    }
    public var elapsedSourceSeconds: Double {
        guard let time = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: time), playerTime.sampleRate > 0 else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }
}
