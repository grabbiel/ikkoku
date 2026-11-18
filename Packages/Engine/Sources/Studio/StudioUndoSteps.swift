import Foundation

/// When a Studio edit takes an undo snapshot (#390). The editor keeps one
/// snapshot of the document per undo step, taken before the step's first
/// edit. Real edits closer than `coalescingWindow` to the step before them
/// join it (a slider drag, typing), unless the step is forced or the window
/// was ended (`endCoalescing`: a new gesture).
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

    /// Applies `change` to `object`. Returns true when the edit changed the
    /// object and starts a new undo step. The caller then snapshots the
    /// document, which still holds the object as it was, before writing
    /// `object` back.
    public mutating func edit(_ object: inout StudioObject, at now: Date, _ change: (inout StudioObject) -> Void) -> Bool {
        var edited = object
        change(&edited)
        let changed = edited != object
        object = edited
        return changed && startsStep(at: now)
    }

    /// Ends the coalescing window: the next real edit starts its own step.
    public mutating func endCoalescing() { lastStep = .distantPast }
}
