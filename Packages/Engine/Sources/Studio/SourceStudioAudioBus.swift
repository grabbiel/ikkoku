import Foundation
@preconcurrency import AVFAudio
import Scene

/// Native voice output. Master gain is a distinct mixer stage, so the installed
/// AudioListener.volume adapter never overwrites personality/per-voice gains.
@MainActor public final class SourceStudioAudioBus {
    public let engine: AVAudioEngine
    public let voiceMixer: AVAudioMixerNode
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
    @discardableResult public func play(index: Int = 0) throws -> Bool {
        guard control.state.playlist.indices.contains(index) else { return control.play(index, available: false) }
        stop()
        let url: URL
        do { url = try catalog.asset(control.state.playlist[index], directory: directory) }
        catch { _ = control.play(index, available: false); diagnostic = String(describing: error); throw error }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= 48_000 * 60 * 20, file.processingFormat.channelCount <= 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RigError.invalid("Converted Studio voice exceeds its duration/channel bounds.")
        }
        try file.read(into: buffer)
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
                do { _ = try self.play(index: next) } catch { self.diagnostic = String(describing: error) }
            }
        }
        node.play()
        return true
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
