/// #459: holds the launch-time Studio execution inputs (plug-in profile, selection,
/// adapter manifests, deterministic steps …) until the launch scene's import has
/// ended, and runs them exactly once.
///
/// A capture, a scenario or a headless launch imports the scene synchronously, so
/// the import has ended before startup reaches the inputs, and `run` runs them at
/// once, where startup always ran them. An interactive or performance-trace launch
/// imports in the background: its commit comes after startup returns, so `run`
/// holds the work and `open` (the import's end, success or failure) runs it.
///
/// The work runs at most once, whatever the order or number of calls: a second
/// `run`, or `open` after the work ran, is ignored. `drop` discards held work, for
/// an import that will not end (New Scene, Open or another import cancelled it).
/// The gate is pure bookkeeping; reporting is the caller's.
@MainActor
public final class LaunchInputGate {
    /// What a call did.
    public enum Outcome: Equatable, Sendable {
        /// The work ran now.
        case ran
        /// The work waits for `open` (`run`), or `open` has nothing to run yet.
        case held
        /// Nothing happened: the work already ran, was dropped, or was already given.
        case ignored
    }

    private enum State {
        /// The import runs; `work` is the held work, once given.
        case waiting(work: (() -> Void)?)
        /// The import ended before the work was given.
        case open
        /// The work ran or was dropped.
        case closed
    }

    private var state: State

    /// `waitsForImport`: whether a launch scene import was started (it may already
    /// have ended by the time `run` is called).
    public init(waitsForImport: Bool) {
        state = waitsForImport ? .waiting(work: nil) : .open
    }

    /// True while the import has not ended and the gate is not closed.
    public var isWaiting: Bool {
        if case .waiting = state { return true }
        return false
    }

    /// True while work is held for `open`.
    public var isHolding: Bool {
        if case .waiting(let work) = state { return work != nil }
        return false
    }

    /// Gives the work: runs it now when the import has ended, else holds it.
    @discardableResult
    public func run(_ work: @escaping () -> Void) -> Outcome {
        switch state {
        case .open:
            state = .closed
            work()
            return .ran
        case .waiting(nil):
            state = .waiting(work: work)
            return .held
        case .waiting, .closed:
            return .ignored
        }
    }

    /// The import ended (committed or failed): runs the held work, if any.
    @discardableResult
    public func open() -> Outcome {
        switch state {
        case .waiting(let work?):
            state = .closed
            work()
            return .ran
        case .waiting(nil):
            state = .open
            return .held
        case .open, .closed:
            return .ignored
        }
    }

    /// Discards the work, held or still to be given, while the import has not
    /// ended. Returns true when the gate was waiting (the caller reports the drop).
    @discardableResult
    public func drop() -> Bool {
        guard case .waiting = state else { return false }
        state = .closed
        return true
    }
}
