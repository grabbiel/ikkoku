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
public final class SourceRigDecodeShare: @unchecked Sendable {
    public struct Counts: Sendable, Equatable {
        /// Decodes run (successful or not), requests answered from a finished
        /// decode, requests that waited for one in flight, and failed decodes.
        public var decodes = 0, hits = 0, waits = 0, failures = 0
        public init(decodes: Int = 0, hits: Int = 0, waits: Int = 0, failures: Int = 0) {
            self.decodes = decodes; self.hits = hits; self.waits = waits; self.failures = failures
        }
    }
    /// One key's decode: written once under `condition`, read under it.
    private final class Slot {
        var result: Result<SourceRig, Error>?
    }
    private let condition = NSCondition()
    private var slots: [SourceRigReuseKey: Slot] = [:]
    private var tally = Counts()

    public init() {}

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
