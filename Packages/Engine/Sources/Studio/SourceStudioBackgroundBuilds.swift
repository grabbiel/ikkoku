import Foundation

/// R7 phase 2 item 6, third part: Studio character builds that each serve
/// one purpose, such as an object's outfit selection or the validation
/// baselines of one export, keyed by that purpose and run in the background.
///
/// `start` runs a batch's second halves in request order on the owner's
/// serial build queue (`SourceStudioCharacterBatch.run`), so they stay one at
/// a time with the owner's other background builds. It then hands the main
/// actor every outcome together, once, in request order (`completion`).
/// Until then the owner keeps showing what it showed.
///
/// - **Superseded.** A newer `start` for the same key cancels the older
///   batch. Its completion never runs, and `start` returns it so the owner
///   can keep what its requests borrowed.
/// - **Cancelled.** After `cancel(_:)` or `cancelAll()` (an undo, an import,
///   New Scene, a scene load), no completion of those batches runs.
/// - **Resources.** A preview a cancelled batch already built has no owner
///   left and releases its meshes and buffers when it is dropped (R6
///   retirement).
/// - **Checks on the main actor.** The cancels run on the main actor, and
///   every callback checks them there, so a callback already queued sees
///   them.
///
/// Main-actor only, like the Studio model that owns it.
@MainActor public final class SourceStudioBackgroundBuilds<Key: Hashable & Sendable> {
    public typealias Outcome = Result<SourceStudioCharacterPreview, Error>

    /// One started batch and the outcomes delivered so far. Main-actor
    /// isolated, so the run's main-actor callbacks may share it.
    @MainActor private final class Entry {
        let batch: SourceStudioCharacterBatch
        var outcomes: [Outcome?]
        init(batch: SourceStudioCharacterBatch) {
            self.batch = batch
            outcomes = Array(repeating: nil, count: batch.requests.count)
        }
    }

    private let queue: DispatchQueue
    private var entries: [Key: Entry] = [:]

    /// `queue` must be serial; the owner's other background builds use it too.
    public init(queue: DispatchQueue) { self.queue = queue }

    /// Builds started and not yet completed, superseded or cancelled.
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var keys: [Key] { Array(entries.keys) }
    public func contains(_ key: Key) -> Bool { entries[key] != nil }
    public func batch(for key: Key) -> SourceStudioCharacterBatch? { entries[key]?.batch }

    /// Starts `batch`'s second halves for `key`, superseding the build `key`
    /// had (returned, already cancelled). `completion` gets one outcome per
    /// request, in request order, on the main actor, unless the build is
    /// superseded or cancelled first.
    @discardableResult
    public func start(_ key: Key, batch: SourceStudioCharacterBatch,
                      completion: @escaping @MainActor @Sendable ([Outcome]) -> Void) -> SourceStudioCharacterBatch? {
        let superseded = cancel(key)
        let entry = Entry(batch: batch)
        entries[key] = entry
        batch.run(batch.requests.indices.map { .character($0) }, on: queue, main: { _ in }, built: { delivery in
            // `run` delivers nothing after a cancel, which also empties the outcomes.
            guard entry.outcomes.indices.contains(delivery.index) else { return }
            entry.outcomes[delivery.index] = delivery.result
        }, finished: { [weak self] in
            guard let self, self.entries[key] === entry else { return }
            self.entries[key] = nil
            let outcomes = entry.outcomes.map { $0 ?? .failure(CancellationError()) }
            entry.outcomes.removeAll()
            completion(outcomes)
        })
        return superseded
    }

    /// Cancels `key`'s build, if any, and returns its batch.
    @discardableResult
    public func cancel(_ key: Key) -> SourceStudioCharacterBatch? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        entry.batch.cancel()
        entry.outcomes.removeAll()
        return entry.batch
    }

    /// Cancels every build and returns their batches.
    @discardableResult
    public func cancelAll() -> [SourceStudioCharacterBatch] {
        let removed = Array(entries.values)
        entries.removeAll()
        for entry in removed {
            entry.batch.cancel()
            entry.outcomes.removeAll()
        }
        return removed.map(\.batch)
    }
}
