import Foundation

/// Native behavior adapter recovered from the installed 1.1 managed plugin.
/// It retains even the source's repeated-focus-loss behavior: a second loss
/// while muted replaces the saved volume with zero.
public final class SourceMuteInBackgroundPlugin {
    public static let guid = "BepInEx.MuteInBackground"
    public static let version = "1.1"
    public var enabled: Bool
    public private(set) var originalVolume: Float?
    private let readVolume: () -> Float, writeVolume: (Float) -> Void
    public init(enabled: Bool = false, readVolume: @escaping () -> Float, writeVolume: @escaping (Float) -> Void) {
        self.enabled = enabled; self.readVolume = readVolume; self.writeVolume = writeVolume
    }
    public func onApplicationFocus(_ hasFocus: Bool) {
        if hasFocus {
            if let originalVolume { writeVolume(originalVolume) }
            originalVolume = nil
        } else if enabled {
            originalVolume = readVolume()
            writeVolume(0)
        }
    }
    /// Read the original key as BepInEx's initial ConfigFile load + Bind(false).
    /// Unbound duplicate keys retain their last text; a malformed final bool
    /// leaves the default false. This does not rewrite the original config.
    public static func readConfiguration(_ data: Data) throws -> Bool {
        guard data.count <= 1024 * 1024 else {
            throw SourcePluginError.invalid("Mute In Background configuration exceeds its size bound.")
        }
        // File.ReadAllLines detects these Unicode BOMs before using UTF-8.
        let text: String
        func units(_ width: Int, littleEndian: Bool) -> [UInt32] {
            let bytes = Array(data.dropFirst(width)); var result: [UInt32] = []
            for i in stride(from: 0, to: bytes.count, by: width) {
                guard i + width <= bytes.count else { result.append(0xfffd); break }
                var value: UInt32 = 0
                for j in 0..<width { value |= UInt32(bytes[i+j]) << UInt32(8 * (littleEndian ? j : width-1-j)) }
                result.append(value)
            }
            return result
        }
        if data.starts(with: [0xff, 0xfe, 0, 0]) { text = String(decoding: units(4, littleEndian: true), as: UTF32.self) }
        else if data.starts(with: [0, 0, 0xfe, 0xff]) { text = String(decoding: units(4, littleEndian: false), as: UTF32.self) }
        else if data.starts(with: [0xff, 0xfe]) { text = String(decoding: units(2, littleEndian: true).map(UInt16.init), as: UTF16.self) }
        else if data.starts(with: [0xfe, 0xff]) { text = String(decoding: units(2, littleEndian: false).map(UInt16.init), as: UTF16.self) }
        else { text = String(decoding: data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data, as: UTF8.self) }
        var section = "", lastValue: String?
        let invalid = CharacterSet(charactersIn: "=\n\t\\\"'[]")
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard section == section.trimmingCharacters(in: .whitespacesAndNewlines),
                  section.rangeOfCharacter(from: invalid) == nil, key.rangeOfCharacter(from: invalid) == nil else {
                throw SourcePluginError.invalid("Invalid BepInEx configuration section or key.")
            }
            if section == "Config", key == "Mute In Background" {
                lastValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // bool.Parse accepts case-insensitive words and surrounding whitespace
        // or null characters; ConfigEntryBase catches conversion failures.
        return lastValue?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))).lowercased() == "true"
    }
}

/// Host side of Unity's OnApplicationFocus for the one mounted focus adapter.
/// A host can mount before it can observe focus (SwiftUI builds app state before
/// NSApplication exists), so the initial sample may arrive later. It is
/// delivered at most once, and a real focus change supersedes it; a duplicate
/// false sample would otherwise trigger the repeated-loss quirk and save zero.
public final class SourceApplicationFocusHost {
    public private(set) var adapter: SourceMuteInBackgroundPlugin?
    public private(set) var awaitingInitialFocus = false
    public init() {}
    /// Restores the replaced adapter's saved volume before installing `next`.
    public func mount(_ next: SourceMuteInBackgroundPlugin?) {
        adapter?.onApplicationFocus(true)
        adapter = next; awaitingInitialFocus = next != nil
    }
    public func deliverInitialFocus(_ hasFocus: Bool) {
        guard awaitingInitialFocus else { return }
        awaitingInitialFocus = false
        adapter?.onApplicationFocus(hasFocus)
    }
    public func focusChanged(_ hasFocus: Bool) {
        awaitingInitialFocus = false
        adapter?.onApplicationFocus(hasFocus)
    }
}
