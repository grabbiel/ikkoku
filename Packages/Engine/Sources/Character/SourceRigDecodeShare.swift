import Foundation
import CryptoKit
import Scene

/// The decode step `SourceMakerLibrary.prepare` reads every converted rig
/// file through: the Maker's bounded reuse worker (#192) or a Studio batch
/// share. Without one, `prepare` decodes each file itself.
protocol SourceRigDecoding: AnyObject {
    func decode(_ data: Data, timings: SourceMakerPreparationTimings?) throws -> SourceRig
}

extension SourceRigReuseWorker: SourceRigDecoding {}
extension SourceRigDecodeShare: SourceRigDecoding {}

/// R7 phase 2 item 6 (C8/S2): one decode per distinct converted rig file
/// across a batch of source character builds (a Studio scene import or an
/// undo rebuild), so characters that share a base body, head or garment
/// decode it once.
///
/// The key is the Maker reuse boundary's own `SourceRigReuseKey`: the
/// SHA-256 and byte count of the exact bytes the load path read, decoder
/// version 1. A hit returns the value `SourceRig.decode` produced from
/// identical bytes, and a file's name or path never stands in for its
/// content. `SourceRig` is an immutable value, so every build that receives
/// it holds its own copy-on-write view.
///
/// Thread-safe. Concurrent builds of the same file wait for the first decode
/// instead of repeating it. Each decode is a leaf (it never calls back into
/// the share), so waits cannot form a cycle. A failed decode is not
/// retained: the builds already waiting on it receive the same error, and a
/// later request decodes again.
///
/// The share keeps every decoded rig until it is released. The batch owner
/// drops it when the batch ends, so nothing outlives the batch. That is why
/// it has no admission budget, unlike the Maker's long-lived reuse boundary.
///
/// Prefetch (R7 phase 2 item 6 follow-up): each preparation decodes its
/// files one after another, and every character asks for the shared base
/// files in the same order, so without a prefetch a batch's distinct
/// decodes run nearly in sequence. `prefetch` starts the decodes a
/// character's card selects at once, as soon as the card is read; the
/// preparation then finds each one finished or in flight. A prefetched
/// decode is an ordinary request here, keyed by the bytes it read, so it
/// never decides what a preparation receives.
public final class SourceRigDecodeShare: @unchecked Sendable {
    public struct Counts: Sendable, Equatable {
        /// Decodes run (successful or not), requests answered from a finished
        /// decode, requests that waited for one in flight, failed decodes,
        /// and files `prefetch` started (read and decoded or found).
        public var decodes = 0, hits = 0, waits = 0, failures = 0, prefetches = 0
        public init(decodes: Int = 0, hits: Int = 0, waits: Int = 0, failures: Int = 0, prefetches: Int = 0) {
            self.decodes = decodes; self.hits = hits; self.waits = waits; self.failures = failures
            self.prefetches = prefetches
        }
    }
    /// One key's decode: written once under `condition`, read under it.
    private final class Slot {
        var result: Result<SourceRig, Error>?
    }
    private let condition = NSCondition()
    private var slots: [SourceRigReuseKey: Slot] = [:]
    private var tally = Counts()
    /// Files `prefetch` was given, and whether it stopped (guarded by `condition`).
    private var prefetched = Set<URL>()
    private var prefetchStopped = false
    private let prefetchGroup = DispatchGroup()
    /// Whether `prefetch` starts decodes (default on; off is a measurement
    /// control that keeps the decodes where the preparations ask for them).
    public let prefetches: Bool

    public init(prefetches: Bool = true) { self.prefetches = prefetches }

    public var counts: Counts {
        condition.lock(); defer { condition.unlock() }
        return tally
    }

    /// Distinct rigs retained now.
    public var retained: Int {
        condition.lock(); defer { condition.unlock() }
        return slots.values.filter { if case .success = $0.result { return true }; return false }.count
    }

    /// `SourceRig.decode(data)`, shared by content.
    public func decode(_ data: Data) throws -> SourceRig { try decode(data, timings: nil) }

    /// Starts reading and decoding each of `urls` that no earlier call named,
    /// all at once on GCD worker threads (`qos`), and returns. A later
    /// `decode` of the same bytes waits for that decode or answers from it;
    /// bytes that differ (the file changed in between) decode on their own.
    /// A file that cannot be read is skipped, and a failed decode is not
    /// retained (see the type), so a wrong or stale list costs time only.
    public func prefetch(_ urls: [URL], qos: DispatchQoS.QoSClass = .userInitiated) {
        guard prefetches, !urls.isEmpty else { return }
        condition.lock()
        let fresh = prefetchStopped ? [] : urls.filter { prefetched.insert($0).inserted }
        tally.prefetches += fresh.count
        condition.unlock()
        for url in fresh {
            DispatchQueue.global(qos: qos).async(group: prefetchGroup) { [self] in
                condition.lock(); let stopped = prefetchStopped; condition.unlock()
                guard !stopped, let data = try? Data(contentsOf: url) else { return }
                _ = try? decode(data, timings: nil)
            }
        }
    }

    /// Starts no further prefetched decode (the batch was cancelled); one
    /// already running finishes.
    public func stopPrefetching() {
        condition.lock(); prefetchStopped = true; condition.unlock()
    }

    /// Waits until every prefetched decode started so far has finished or
    /// been skipped (tests).
    func waitForPrefetches() { prefetchGroup.wait() }

    func decode(_ data: Data, timings: SourceMakerPreparationTimings?) throws -> SourceRig {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let key = SourceRigReuseKey(sha256: hash, byteCount: data.count) else {
            return try SourceMakerPreparationTimings.measure(timings, .rigDecode) { try SourceRig.decode(data) }
        }
        condition.lock()
        if let slot = slots[key] {
            if slot.result == nil {
                tally.waits += 1
                while slot.result == nil { condition.wait() }
            } else {
                tally.hits += 1
            }
            let result = slot.result!
            condition.unlock()
            return try result.get()
        }
        let slot = Slot()
        slots[key] = slot
        tally.decodes += 1
        condition.unlock()
        let result = Result { try SourceMakerPreparationTimings.measure(timings, .rigDecode) { try SourceRig.decode(data) } }
        condition.lock()
        slot.result = result
        if case .failure = result {
            tally.failures += 1
            slots[key] = nil
        }
        condition.broadcast()
        condition.unlock()
        return try result.get()
    }
}
