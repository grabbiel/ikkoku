import Foundation
import Character

/// Who owns the Studio status line's native IK report (R4, the #110 follow-up).
///
/// The frame builder hands every frame's unsolved chains to `update`. The
/// report writes the status line when a chain fails that was not failing
/// before. When chains solve again it narrows or clears its own message, but
/// only while the status line still shows that message, so any status written
/// since survives. A failed chain keeps its pre-IK pose; this type only
/// decides the text.
public struct StudioIKStatusReport: Equatable, Sendable {
    /// One native character's IK chain.
    public struct Chain: Hashable, Sendable {
        public let object: UUID
        public let chain: IKChain
        public init(object: UUID, chain: IKChain) { self.object = object; self.chain = chain }
    }

    /// One chain left unsolved in a frame: the character's name for the
    /// message, and why the solver refused it.
    public struct Failure: Equatable, Sendable {
        public let chain: Chain
        public let character: String
        public let reason: String
        public init(chain: Chain, character: String, reason: String) {
            self.chain = chain; self.character = character; self.reason = reason
        }
    }

    /// The unsolved chains last reported, in frame order.
    public private(set) var failures: [Failure] = []
    /// The report's current message, which the status line shows while the
    /// report owns it; nil when no chain is unsolved.
    public private(set) var message: String?

    public init() {}

    /// Takes this frame's unsolved chains (document order, then `IKChain`
    /// order), the chains whose targets are enabled, and the status line's
    /// current text. Returns the text to write to the status line, or nil to
    /// leave it as it is.
    ///
    /// - A chain that newly fails (or fails for a new reason) writes the
    ///   message naming every unsolved chain.
    /// - When chains solve again, the message is narrowed to the chains still
    ///   unsolved, or replaced by a "solved again" line when none is, but only
    ///   while `status` is still this report's message.
    /// - An unchanged set of failures writes nothing, so a status written
    ///   after the report is not overwritten on the next frame.
    public mutating func update(failures new: [Failure], enabled: Set<Chain>, status: String) -> String? {
        guard new != failures else { return nil }
        let ownsStatus = message.map { $0 == status } ?? false
        let previous = failures
        failures = new
        guard !new.isEmpty else {
            message = nil
            guard ownsStatus else { return nil }
            let solved = previous.filter { enabled.contains($0.chain) }
            return solved.isEmpty ? "Ready" : Self.solvedMessage(solved)
        }
        let text = Self.unsolvedMessage(new)
        message = text
        let added = new.contains { !previous.contains($0) }
        return added || ownsStatus ? text : nil
    }

    /// "Left hand IK left unsolved: IK reach is not finite." for each chain,
    /// joined by " · ". The character is named ("… left unsolved on Hana: …")
    /// only when the chains belong to more than one character.
    public static func unsolvedMessage(_ failures: [Failure]) -> String {
        let named = Set(failures.map(\.chain.object)).count > 1
        return failures.map { failure in
            "\(failure.chain.chain.label) IK left unsolved\(named ? " on \(failure.character)" : ""): \(failure.reason)"
        }.joined(separator: " · ")
    }

    /// "Left hand IK solved again." / "Left hand and Right hand IK solved again."
    public static func solvedMessage(_ failures: [Failure]) -> String {
        let named = Set(failures.map(\.chain.object)).count > 1
        let labels = failures.map { "\($0.chain.chain.label)\(named ? " on \($0.character)" : "")" }
        let list = labels.count < 2 ? labels.joined()
            : labels.dropLast().joined(separator: ", ") + " and " + labels.last!
        return "\(list) IK solved again."
    }
}

/// How the Studio editor names a source camera object (ST-A06) in the
/// workspace tree, the status line, the view indicator and the Object tab:
/// the record's name, with its source key where it disambiguates.
public enum SourceStudioCameraLabel {
    /// The importer's name for a camera record that has none.
    public static func fallbackName(_ key: Int32) -> String { "Source camera \(key)" }

    /// The tree and inspector title: "IKKOKU-MIRROR (camera 2)". An unnamed
    /// record's fallback name, "Source camera 2", already carries the key.
    public static func title(name: String, key: Int32) -> String {
        name == fallbackName(key) ? name : "\(name) (camera \(key))"
    }

    /// The camera after the words "source camera" in a sentence:
    /// `"IKKOKU-MIRROR" (camera 2)`, or just `2` for an unnamed record.
    public static func reference(name: String, key: Int32) -> String {
        name == fallbackName(key) ? "\(key)" : "\"\(name)\" (camera \(key))"
    }

    /// Why the view shows the saved camera instead of looking through the
    /// active camera, completing "source camera … ": "has a mirrored parent".
    public static func fallbackReason(_ error: Error) -> String {
        if let error = error as? SourceStudioCameraObjectError {
            switch error {
            case .reflectedFrame("parent frame"): return "has a mirrored parent"
            case .reflectedFrame(let frame): return "has a mirrored \(frame)"
            }
        }
        return "cannot be placed (\(error))"
    }

    /// The view indicator under the status line. While the view looks through
    /// the camera: `Viewing through source camera "IKKOKU-CONTROL" (camera 3)
    /// (runtime only)`. While it falls back: `Saved camera shown: source
    /// camera "IKKOKU-MIRROR" (camera 2) has a mirrored parent`.
    public static func indicator(name: String, key: Int32, fallbackReason: String?) -> String {
        let camera = reference(name: name, key: key)
        guard let fallbackReason else { return "Viewing through source camera \(camera) (runtime only)" }
        return "Saved camera shown: source camera \(camera) \(fallbackReason)"
    }
}
