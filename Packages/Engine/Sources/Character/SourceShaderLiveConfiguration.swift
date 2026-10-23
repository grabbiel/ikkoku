import Foundation
import Metal
import Renderer

/// File inputs of the opt-in live source-shader path (R1/CMT-04), read from
/// the environment. Nothing here is required for the default toon renderer;
/// a missing input only keeps every character on toon, with the reason.
///
/// | Variable | Input |
/// | --- | --- |
/// | `IKKOKU_LIVE_SOURCE_SHADERS=1` | start with the opt-in on (View ▸ Live Source Shaders toggles it) |
/// | `IKKOKU_LIVE_SOURCE_PROGRAMS` | translated original programs (`<family>[_outline]/program.json`) |
/// | `IKKOKU_LIVE_SOURCE_TEXTURES` | native texture store `manifest.json` (`Tools/reverse/source_texture_store.py`) |
/// | `IKKOKU_LIVE_SOURCE_STREAMS` | source UV1/UV2/UV3/colour `manifest.json` (`Tools/reverse/source_vertex_streams.py`) |
/// | `IKKOKU_SHADER_BINDING_SUPPLEMENT` | source binding supplement (keywords, sampler state, body draw material) |
/// | `IKKOKU_HEAD_MATERIAL_CONTRACT` | head material contract; default `head-materials/contract.json` beside the source avatar |
/// | `IKKOKU_MAKER_LIBRARY` | Maker library (the app's own lookup when unset) |
public struct SourceShaderLiveConfiguration: Sendable, Equatable {
    public var enabledAtLaunch: Bool
    public var programs: URL?
    public var textures: URL?
    public var streams: URL?
    public var supplement: URL?
    public var headContract: URL?
    public var makerLibrary: URL?

    public init(enabledAtLaunch: Bool = false, programs: URL? = nil, textures: URL? = nil, streams: URL? = nil,
                supplement: URL? = nil, headContract: URL? = nil, makerLibrary: URL? = nil) {
        self.enabledAtLaunch = enabledAtLaunch; self.programs = programs; self.textures = textures; self.streams = streams
        self.supplement = supplement; self.headContract = headContract; self.makerLibrary = makerLibrary
    }

    public static func environment(_ env: [String: String], sourceAvatar: URL? = nil) -> SourceShaderLiveConfiguration {
        func url(_ key: String) -> URL? { env[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } }
        return SourceShaderLiveConfiguration(enabledAtLaunch: env["IKKOKU_LIVE_SOURCE_SHADERS"] == "1",
            programs: url("IKKOKU_LIVE_SOURCE_PROGRAMS"), textures: url("IKKOKU_LIVE_SOURCE_TEXTURES"),
            streams: url("IKKOKU_LIVE_SOURCE_STREAMS"), supplement: url("IKKOKU_SHADER_BINDING_SUPPLEMENT"),
            headContract: url("IKKOKU_HEAD_MATERIAL_CONTRACT")
                ?? sourceAvatar.map { $0.deletingLastPathComponent().appendingPathComponent("head-materials/contract.json") },
            makerLibrary: url("IKKOKU_MAKER_LIBRARY"))
    }

    /// Inputs the live path cannot run without, by variable name.
    public func missing(makerLibrary library: URL?) -> [String] {
        var missing: [String] = []
        if programs == nil { missing.append("IKKOKU_LIVE_SOURCE_PROGRAMS") }
        if textures == nil { missing.append("IKKOKU_LIVE_SOURCE_TEXTURES") }
        if (library ?? makerLibrary) == nil { missing.append("IKKOKU_MAKER_LIBRARY") }
        if headContract == nil { missing.append("IKKOKU_HEAD_MATERIAL_CONTRACT") }
        return missing
    }

    /// Loaded shared inputs: the texture provider and the vertex streams.
    /// Streams are optional; without them `main_skin` (UV3/COLOR) stays toon.
    public final class Shared: @unchecked Sendable {
        public let textures: any SourceShaderLiveTextureProvider
        public let streams: [String: [SourceVertexStreams]]
        public let notes: [String]
        public init(textures: any SourceShaderLiveTextureProvider, streams: [String: [SourceVertexStreams]], notes: [String]) {
            self.textures = textures; self.streams = streams; self.notes = notes
        }
    }

    public func loadShared(device: any MTLDevice, textures override: (any SourceShaderLiveTextureProvider)? = nil) throws -> Shared {
        let provider: any SourceShaderLiveTextureProvider
        if let override { provider = override }
        else {
            guard let textures else { throw SourceShaderLiveReason("IKKOKU_LIVE_SOURCE_TEXTURES is not set") }
            provider = try SourceShaderTextureStore(url: textures)
        }
        var notes: [String] = []
        let streams: [String: [SourceVertexStreams]]
        if let url = self.streams { streams = try SourceVertexStreams.load(manifest: url, device: device) }
        else { streams = [:]; notes.append("IKKOKU_LIVE_SOURCE_STREAMS is not set: programs reading TEXCOORD3 or COLOR (main_skin), or a TEXCOORD1/2 the converted mesh lacks (main_hair), stay toon") }
        return Shared(textures: provider, streams: streams, notes: notes)
    }

    /// The binding-derivation inputs for one character.
    public func inputs(makerLibrary library: URL?) throws -> SourceShaderLiveAssembly.Inputs {
        let missing = missing(makerLibrary: library)
        guard missing.isEmpty, let programs, let headContract, let makerLibrary = library ?? makerLibrary else {
            throw SourceShaderLiveReason("live source shaders need \(missing.joined(separator: ", "))")
        }
        return .init(programs: programs, makerLibrary: makerLibrary, headContract: headContract, supplement: supplement)
    }
}
