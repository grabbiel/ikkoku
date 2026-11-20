import Foundation

/// When a Studio edit takes an undo snapshot (#390). The editor keeps one
/// snapshot of the document per undo step, taken before the step's first
/// edit. Real edits closer than `coalescingWindow` to the step before them
/// join it (a slider drag, typing), unless the step is forced or the window
/// was ended (`endCoalescing`: a new gesture, and every Undo, #448).
///
/// An object edit that leaves the object as it was starts no step and does
/// not restart the window. That covers a field committing the value it
/// already shows (a Tab walk) and a second binding write of the same value.
/// So the undo history follows the real edits, not how long the writes in
/// between took.
public struct StudioUndoSteps: Sendable {
    public static let coalescingWindow: TimeInterval = 0.4

    private var lastStep = Date.distantPast

    public init() {}

    /// Whether an edit at `now` starts a new undo step: it is forced, or it
    /// falls outside the coalescing window of the last step. Starting a step
    /// restarts the window.
    public mutating func startsStep(at now: Date, force: Bool = false) -> Bool {
        if !force && now.timeIntervalSince(lastStep) < Self.coalescingWindow { return false }
        lastStep = now
        return true
    }

    /// What an object edit is to the undo history (#446).
    public enum ObjectEdit: Sendable, Equatable {
        /// The edit left the object as it was: no step (#390).
        case unchanged
        /// It changed the object inside the open step's window.
        case coalesced
        /// It changed the object and starts a new step.
        case startsStep
    }

    /// Applies `change` to `object` and says what the edit is to the
    /// history. The caller then records the object as it was (a new step) or
    /// adds it to the open step (coalesced), before writing `object` back.
    public mutating func objectEdit(_ object: inout StudioObject, at now: Date, _ change: (inout StudioObject) -> Void) -> ObjectEdit {
        var edited = object
        change(&edited)
        let changed = edited != object
        object = edited
        guard changed else { return .unchanged }
        return startsStep(at: now) ? .startsStep : .coalesced
    }

    /// Applies `change` to `object`. Returns true when the edit changed the
    /// object and starts a new undo step. The caller then snapshots the
    /// document, which still holds the object as it was, before writing
    /// `object` back.
    public mutating func edit(_ object: inout StudioObject, at now: Date, _ change: (inout StudioObject) -> Void) -> Bool {
        objectEdit(&object, at: now, change) == .startsStep
    }

    /// Ends the coalescing window: the next real edit starts its own step.
    public mutating func endCoalescing() { lastStep = .distantPast }
}
