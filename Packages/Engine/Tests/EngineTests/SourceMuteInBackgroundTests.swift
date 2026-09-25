import Foundation
import Testing
import Gameplay
import Studio

@Test func sourceMuteConfigurationMatchesInitialBindSemantics() throws {
    let key = "[Config]\nMute In Background="
    for (text, expected) in [("", false), (key + "TrUe", true), (key + "true # comment", false),
        (key + "true\nMute In Background=invalid", false), (key + "invalid\nMute In Background=true", true),
        (key + "\0 true \0", true), ("[config]\nMute In Background=true", false)] {
        #expect(try SourceMuteInBackgroundPlugin.readConfiguration(Data(text.utf8)) == expected)
    }
    #expect(throws: (any Error).self) { try SourceMuteInBackgroundPlugin.readConfiguration(Data("[ Config ]\nMute In Background=true".utf8)) }
    #expect(throws: (any Error).self) { try SourceMuteInBackgroundPlugin.readConfiguration(Data("[Unrelated]\nBad[Key]=1".utf8)) }
    #expect(throws: (any Error).self) { try SourceMuteInBackgroundPlugin.readConfiguration(Data(repeating: 0, count: 1024 * 1024 + 1)) }
    for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
        let bom: [UInt8] = encoding == .utf16LittleEndian ? [0xff,0xfe] : encoding == .utf16BigEndian ? [0xfe,0xff] : encoding == .utf32LittleEndian ? [0xff,0xfe,0,0] : [0,0,0xfe,0xff]
        #expect(try SourceMuteInBackgroundPlugin.readConfiguration(Data(bom) + (key + "true").data(using: encoding)!) == true)
    }
}

@MainActor @Test func sourceMuteFocusPreservesMasterPCMAndPersonalityGains() {
    let bus = SourceStudioAudioBus(); bus.masterVolume = 0.73; bus.voiceVolume = 0.4
    let adapter = SourceMuteInBackgroundPlugin(enabled: true, readVolume: { bus.masterVolume }, writeVolume: { bus.masterVolume = $0 })
    adapter.onApplicationFocus(false)
    #expect(bus.masterVolume == 0 && bus.voiceVolume == 0.4 && adapter.originalVolume == 0.73)
    adapter.enabled = false; adapter.onApplicationFocus(true)
    #expect(bus.masterVolume == 0.73 && bus.voiceVolume == 0.4 && adapter.originalVolume == nil)
    adapter.enabled = true; adapter.onApplicationFocus(false); adapter.onApplicationFocus(false); adapter.onApplicationFocus(true)
    #expect(bus.masterVolume == 0 && bus.voiceVolume == 0.4) // Original 1.1 repeated-loss quirk.
}

@Test func sourceMuteFocusHostDefersInitialFocusOnceAndRestoresReplacedAdapter() {
    var volume: Float = 0.8
    func adapter(_ enabled: Bool) -> SourceMuteInBackgroundPlugin {
        SourceMuteInBackgroundPlugin(enabled: enabled, readVolume: { volume }, writeVolume: { volume = $0 })
    }
    let host = SourceApplicationFocusHost(), first = adapter(true)
    host.mount(first) // Mounted before the host application can report focus.
    #expect(host.awaitingInitialFocus && volume == 0.8 && first.originalVolume == nil)
    host.deliverInitialFocus(false)
    #expect(!host.awaitingInitialFocus && volume == 0 && first.originalVolume == 0.8)
    host.deliverInitialFocus(false) // A second sample would save zero through the repeated-loss quirk.
    #expect(volume == 0 && first.originalVolume == 0.8)
    host.focusChanged(true)
    #expect(volume == 0.8 && first.originalVolume == nil)
    host.focusChanged(false); let second = adapter(true); host.mount(second)
    let replaced = host.adapter === second
    #expect(volume == 0.8 && first.originalVolume == nil && replaced && host.awaitingInitialFocus)
    host.focusChanged(true); host.deliverInitialFocus(false) // A real change supersedes the pending sample.
    #expect(volume == 0.8 && second.originalVolume == nil && !host.awaitingInitialFocus)
    host.focusChanged(false); #expect(volume == 0)
    host.mount(nil)
    let unmounted = host.adapter == nil
    #expect(volume == 0.8 && unmounted && !host.awaitingInitialFocus)
    host.focusChanged(false); host.deliverInitialFocus(false); #expect(volume == 0.8)
    let disabled = adapter(false); host.mount(disabled); host.deliverInitialFocus(false); host.focusChanged(false)
    #expect(volume == 0.8 && disabled.originalVolume == nil) // Installed default configuration.
}

private struct MuteOracle: Decodable {
    struct Step: Decodable { let enabled: Bool?, volume: Float?, focus: Bool? }
    struct Scenario: Decodable { let name: String, volume: Float, steps: [Step] }
    struct Configuration: Decodable { let name: String, data: Data }
    struct Inputs: Decodable { let configurations: [Configuration], cases: [Scenario] }
    struct State: Decodable { let enabled: Bool, volume: Float, original: Float? }
    struct Trace: Decodable { let name: String, states: [State] }
    struct ConfigResult: Decodable { let name: String, value: Bool?, error: String? }
    struct Results: Decodable { let configurations: [ConfigResult], cases: [Trace] }
    let inputs: Inputs, results: Results
}

@Test func sourceMuteMatchesUntouchedRecoveredCSharpAndInstalledConfigReader() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_MUTE_PLUGIN_ORACLE"] else { return }
    let oracle = try JSONDecoder().decode(MuteOracle.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(oracle.inputs.configurations.count == oracle.results.configurations.count)
    for (input, result) in zip(oracle.inputs.configurations, oracle.results.configurations) {
        #expect(input.name == result.name)
        if result.error != nil {
            #expect(throws: (any Error).self) { try SourceMuteInBackgroundPlugin.readConfiguration(input.data) }
        } else { #expect(try SourceMuteInBackgroundPlugin.readConfiguration(input.data) == result.value, "\(input.name)") }
    }
    #expect(oracle.inputs.cases.count == oracle.results.cases.count)
    for (input, trace) in zip(oracle.inputs.cases, oracle.results.cases) {
        var volume = input.volume
        let adapter = SourceMuteInBackgroundPlugin(readVolume: { volume }, writeVolume: { volume = $0 })
        func check(_ expected: MuteOracle.State) {
            #expect(adapter.enabled == expected.enabled && volume == expected.volume && adapter.originalVolume == expected.original, "\(input.name)")
        }
        #expect(input.name == trace.name && trace.states.count == input.steps.count + 1)
        check(trace.states[0])
        for (step, expected) in zip(input.steps, trace.states.dropFirst()) {
            if let enabled = step.enabled { adapter.enabled = enabled }
            if let changed = step.volume { volume = changed }
            if let focus = step.focus { adapter.onApplicationFocus(focus) }
            check(expected)
        }
    }
}
