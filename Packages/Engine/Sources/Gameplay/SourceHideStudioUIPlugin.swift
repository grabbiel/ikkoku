import Foundation

/// The Studio-only visibility state of the exact HideAllUI 2.3.2 adapter.
/// Initializing the handler does not write host surface state. The native host
/// applies this layer over its own panel/gizmo preferences, which stay intact.
/// This is not a general Unity Canvas or keyboard-input implementation.
public struct SourceHideStudioUIPlugin: Equatable, Sendable {
    public static let guid = "keelhauled.hideallui"
    public static let version = "2.3.2"
    public private(set) var visible = true

    public init() {}

    @discardableResult public mutating func toggle() -> Bool {
        visible.toggle()
        return visible
    }

    /// Ikkoku recovery policy: removing this adapter's hiding leaves the host's
    /// authored visibility preferences in force. Original HideAllUI does not
    /// serialize its handler state; a newly mounted/restored handler is visible.
    public mutating func reveal() { visible = true }

    public enum ShortcutAction: Equatable, Sendable {
        /// Continue the existing viewport shortcuts, including ordinary playback.
        case continueViewport
        /// Do not handle or fall through to playback (inactive/text/modifier case).
        case unhandled
        /// Consume key repeat without changing visibility or playback.
        case consume
        case toggleVisibility
    }

    /// The app calls this only from the viewport's first-responder key handler.
    /// Keeping ownership explicit also permits deterministic inactive/focus tests.
    /// An absent adapter leaves existing viewport shortcut behavior unchanged.
    public static func shortcutAction(isSpace: Bool, hasModifiers: Bool, isRepeat: Bool,
                                      ownsInput: Bool, mounted: Bool) -> ShortcutAction {
        guard ownsInput else { return .unhandled }
        guard mounted, isSpace else { return .continueViewport }
        guard !hasModifiers else { return .unhandled }
        return isRepeat ? .consume : .toggleVisibility
    }

    /// Bounded configuration support: default or explicitly unmodified Space.
    /// Other shortcuts/encodings are rejected, never silently changed to Space.
    /// Unrelated entries remain untouched in the immutable packaged bytes.
    public static func validateConfiguration(_ data: Data) throws {
        guard data.count <= 1024 * 1024 else {
            throw SourcePluginError.invalid("HideAllUI configuration exceeds its size bound.")
        }
        let bytes = data.starts(with: [0xef, 0xbb, 0xbf]) ? Data(data.dropFirst(3)) : data
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw SourcePluginError.invalid("HideAllUI configuration currently requires UTF-8.")
        }
        var section = "", shortcut: String?
        let invalid = CharacterSet(charactersIn: "=\n\t\\\"'[]")
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard section == section.trimmingCharacters(in: .whitespacesAndNewlines),
                  section.rangeOfCharacter(from: invalid) == nil, key.rangeOfCharacter(from: invalid) == nil else {
                throw SourcePluginError.invalid("Invalid HideAllUI configuration section or key.")
            }
            if section == "Keyboard shortcuts", key == "Hide UI" {
                shortcut = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard shortcut == nil || shortcut == "Space" else {
            throw SourcePluginError.invalid("HideAllUI currently supports only unmodified Space in Studio.")
        }
    }
}
