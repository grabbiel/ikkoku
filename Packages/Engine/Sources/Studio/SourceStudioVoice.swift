import Foundation
import CryptoKit
import Character
import Scene
import Assets

public struct SourceStudioVoiceState: Codable, Sendable, Equatable {
    public struct Selection: Codable, Sendable, Equatable, Hashable {
        public var group: Int32, category: Int32, no: Int32
        public init(group: Int32, category: Int32, no: Int32) { self.group = group; self.category = category; self.no = no }
    }
    public var playlist: [Selection]
    public var repeatMode: Int32
    public init(playlist: [Selection], repeatMode: Int32) { self.playlist = playlist; self.repeatMode = repeatMode }
    public init(record: KoikatsuCharacterRecord) {
        playlist = record.voices.map { .init(group: $0.group, category: $0.category, no: $0.no) }
        repeatMode = record.voiceRepeat
    }
}

/// VoiceCtrl's control state, separate from AVAudio callbacks and source bytes.
/// Import is stopped: original scenes do not serialize an active index/clock.
public struct SourceStudioVoiceControl: Sendable {
    public var state: SourceStudioVoiceState
    public private(set) var index = -1
    public private(set) var playing = false
    public init(state: SourceStudioVoiceState) throws {
        guard state.playlist.count <= 10_000 else { throw RigError.invalid("Studio voice playlist exceeds its bound.") }
        self.state = state
    }
    /// Availability means exact catalog/asset resolution succeeded. Invalid
    /// indices reset index but do not call Stop, matching original Play ordering.
    public mutating func play(_ requested: Int, available: Bool) -> Bool {
        guard !state.playlist.isEmpty else { return false }
        guard state.playlist.indices.contains(requested) else { index = -1; return false }
        stop()
        guard available else { return false }
        index = requested; playing = true; return true
    }
    public mutating func stop() { playing = false }
    /// Completion chooses a subsequent request; missing audio is handled by
    /// the same Play path and never substituted by an unrelated clip.
    public mutating func completed() -> Int? {
        guard playing else { return nil }
        playing = false
        switch state.repeatMode {
        case 0: index += 1; return index
        case 1:
            guard !state.playlist.isEmpty else { return nil }
            index = (index + 1) % state.playlist.count; return index
        case 2: return index
        default: return nil // Unknown source enum remains preserved and inert.
        }
    }
}

public struct SourceStudioVoiceCharacter: Sendable {
    public let personality: Int
    public let pitch: Float
    public init(card: SourceCharacterCard) throws {
        guard let block = card.block(named: "Parameter") else { throw RigError.invalid("Source character has no voice parameters.") }
        let map = try SourceMessagePack.decode(block.data).stringKeyedMap()
        personality = map["personality"]?.integerValue ?? 0
        let rate: Float
        switch map["voiceRate"] {
        case .float(let number): rate = Float(number)
        case .integer(let number): rate = Float(number)
        case nil: rate = 0.5
        default: throw RigError.invalid("Invalid source voice rate.")
        }
        guard rate.isFinite else { throw RigError.invalid("Nonfinite source voice rate.") }
        pitch = 0.94 + (1.06 - 0.94) * min(max(rate, 0), 1)
    }
}

public struct SourceStudioVoiceCatalog: Decodable, Sendable {
    public struct Personality: Decodable, Sendable { public let no: Int, file: String, volume: Float }
    public struct Entry: Decodable, Sendable {
        public let group: Int32, category: Int32, no: Int32
        public let bundle: String, asset: String
        public let file: String?, sha256: String?
        public var selection: SourceStudioVoiceState.Selection { .init(group: group, category: category, no: no) }
    }
    public let schemaVersion: Int, kind: String, entries: [Entry]
    public let personalities: [Personality]?, voiceVolume: Float?
    public func volume(personality: Int) -> Float { personalities?.first(where: { $0.no == personality })?.volume ?? 0 }
    public static func load(url: URL) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: read(url, maximum: 16 * 1024 * 1024))
        guard result.schemaVersion == 1, result.kind == "ikkoku-studio-voice-catalog", result.entries.count <= 100_000,
              Set(result.entries.map(\.selection)).count == result.entries.count else { throw RigError.invalid("Invalid or ambiguous Studio voice catalog.") }
        guard result.voiceVolume.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              result.personalities?.allSatisfy({ $0.volume.isFinite && (0...1).contains($0.volume) }) ?? true,
              Set(result.personalities?.map(\.no) ?? []).count == (result.personalities?.count ?? 0) else { throw RigError.invalid("Invalid personality voice volumes.") }
        return result
    }
    public func asset(_ selection: SourceStudioVoiceState.Selection, directory: URL) throws -> URL {
        guard let entry = entries.first(where: { $0.selection == selection }), let file = entry.file, let hash = entry.sha256,
              !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else {
            throw RigError.invalid("Selected Studio voice \(selection.group)/\(selection.category)/\(selection.no) has no converted audio.")
        }
        let root = directory.resolvingSymlinksInPath(), url = root.appendingPathComponent(file).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { throw RigError.invalid("Studio voice file escapes its catalog.") }
        let bytes = try Self.read(url, maximum: 128 * 1024 * 1024)
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash else { throw RigError.invalid("Studio voice file hash does not match its identity.") }
        return url
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard v.isRegularFile == true, let size = v.fileSize, size > 0, size <= maximum else { throw RigError.invalid("Studio voice input must be a bounded regular file.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw RigError.invalid("Studio voice input exceeds its bound.") }
        return data
    }
}
