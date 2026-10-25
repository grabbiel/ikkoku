import Foundation
import CryptoKit
import os
import Scene

/// Immutable holders retain reservations independently of worker slots,
/// cancellation, actor delivery and source-session epochs.
final class SourceRigReuseAdmission: Sendable {
    struct Counts: Sendable, Equatable {
        var entries = 0, logicalBytes = 0, snapshots = 0
    }
    let maximumBytes: Int, maximumEntries: Int, maximumSnapshots: Int
    private let state = OSAllocatedUnfairLock(initialState: Counts())
    init(maximumBytes: Int = 64 * 1024 * 1024, maximumEntries: Int = 16, maximumSnapshots: Int = 4) {
        // Smaller limits support deterministic saturation checks; callers cannot
        // enlarge the per-Maker retention bound.
        precondition((0...64 * 1024 * 1024).contains(maximumBytes)
            && (1...16).contains(maximumEntries) && (1...4).contains(maximumSnapshots))
        self.maximumBytes = maximumBytes; self.maximumEntries = maximumEntries; self.maximumSnapshots = maximumSnapshots
    }
    var counts: Counts { state.withLock { $0 } }
    fileprivate func entryPermit(charge: Int) -> EntryPermit? {
        guard charge >= 0 else { return nil }
        let admitted = state.withLock { value in
            guard value.entries < self.maximumEntries, charge <= self.maximumBytes - value.logicalBytes else { return false }
            value.entries += 1; value.logicalBytes += charge; return true
        }
        return admitted ? EntryPermit(owner: self, charge: charge) : nil
    }
    fileprivate func snapshotPermit() -> SnapshotPermit? {
        let admitted = state.withLock { value in
            guard value.snapshots < self.maximumSnapshots else { return false }
            value.snapshots += 1; return true
        }
        return admitted ? SnapshotPermit(owner: self) : nil
    }
    fileprivate func releaseEntry(charge: Int) {
        state.withLock { value in
            precondition(value.entries > 0 && value.logicalBytes >= charge)
            value.entries -= 1; value.logicalBytes -= charge
        }
    }
    fileprivate func releaseSnapshot() {
        state.withLock { value in precondition(value.snapshots > 0); value.snapshots -= 1 }
    }
    fileprivate final class EntryPermit: Sendable {
        let owner: SourceRigReuseAdmission, charge: Int
        init(owner: SourceRigReuseAdmission, charge: Int) { self.owner = owner; self.charge = charge }
        deinit { owner.releaseEntry(charge: charge) }
    }
    fileprivate final class SnapshotPermit: Sendable {
        let owner: SourceRigReuseAdmission
        init(owner: SourceRigReuseAdmission) { self.owner = owner }
        deinit { owner.releaseSnapshot() }
    }
}

struct SourceRigReuseEpoch: Hashable, Sendable { private let identity = UUID() }
struct SourceRigReuseKey: Hashable, Sendable {
    let sha256: String, byteCount: Int, decoderVersion: Int
    init?(sha256: String, byteCount: Int, decoderVersion: Int = 1) {
        guard byteCount >= 0, decoderVersion == 1, sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.sha256 = sha256; self.byteCount = byteCount; self.decoderVersion = decoderVersion
    }
}

final class SourceRigReuseEntry: Sendable {
    let rig: SourceRig, key: SourceRigReuseKey, epoch: SourceRigReuseEpoch, logicalCharge: Int
    fileprivate let permit: SourceRigReuseAdmission.EntryPermit
    convenience init?(rig: SourceRig, key: SourceRigReuseKey, epoch: SourceRigReuseEpoch, admission: SourceRigReuseAdmission) {
        guard let charge = Self.charge(rig: rig, key: key) else { return nil }
        self.init(rig: rig, key: key, epoch: epoch, admission: admission, measuredCharge: charge)
    }
    /// File-private callers have just measured this exact rig/key. Admission
    /// still checks the live byte/entry limits; no second payload traversal.
    fileprivate init?(rig: SourceRig, key: SourceRigReuseKey, epoch: SourceRigReuseEpoch,
                      admission: SourceRigReuseAdmission, measuredCharge: Int) {
        guard let permit = admission.entryPermit(charge: measuredCharge) else { return nil }
        self.rig = rig; self.key = key; self.epoch = epoch; self.logicalCharge = measuredCharge; self.permit = permit
    }
    static func charge(rig: SourceRig, key: SourceRigReuseKey) -> Int? {
        guard let rigBytes = rig.decodedCacheLogicalByteCount else { return nil }
        // Stored field/permit payloads are charged; class allocation headers and
        // allocator overhead remain excluded. The rig's inline stride is in rigBytes.
        var charge = ReuseCharge()
        guard charge.add(rigBytes), charge.add(MemoryLayout<SourceRigReuseKey>.stride), charge.add(key.sha256.utf8.count),
              charge.add(MemoryLayout<SourceRigReuseEpoch>.stride), charge.add(MemoryLayout<Int>.stride),
              charge.add(MemoryLayout<SourceRigReuseAdmission.EntryPermit>.stride),
              charge.add(MemoryLayout<SourceRigReuseAdmission>.stride), charge.add(MemoryLayout<Int>.stride) else { return nil }
        return charge.bytes
    }
}

final class SourceRigReuseSnapshot: Sendable {
    let entries: [SourceRigReuseEntry], epoch: SourceRigReuseEpoch
    /// Separate from admitted rig payload; at most maximumSnapshots such holders.
    /// Excludes spare array capacity, class allocation headers and allocator costs.
    let logicalReferenceBytes: Int
    private let permit: SourceRigReuseAdmission.SnapshotPermit
    init?(entries: [SourceRigReuseEntry], epoch: SourceRigReuseEpoch, admission: SourceRigReuseAdmission) {
        guard entries.count <= admission.maximumEntries,
              entries.allSatisfy({ $0.permit.owner === admission && $0.epoch == epoch }),
              Set(entries.map(\.key)).count == entries.count else { return nil }
        var charge = ReuseCharge()
        guard charge.add(MemoryLayout<[SourceRigReuseEntry]>.stride), charge.add(MemoryLayout<SourceRigReuseEpoch>.stride),
              charge.add(MemoryLayout<Int>.stride), charge.add(MemoryLayout<SourceRigReuseAdmission.SnapshotPermit>.stride),
              charge.add(MemoryLayout<SourceRigReuseAdmission>.stride),
              charge.product(entries.count, MemoryLayout<SourceRigReuseEntry>.stride),
              let permit = admission.snapshotPermit() else { return nil }
        self.entries = entries; self.epoch = epoch; self.logicalReferenceBytes = charge.bytes; self.permit = permit
    }
    func rig(for key: SourceRigReuseKey, epoch requestedEpoch: SourceRigReuseEpoch) -> SourceRig? {
        guard requestedEpoch == epoch else { return nil }
        return entries.first(where: { $0.key == key })?.rig
    }
}

/// Owner-side publication only. A session reset releases this owner's snapshot,
/// but uses the same ledger until every old worker/delivery holder releases too.
@MainActor public final class SourceMakerRigReuse {
    public struct Input: Sendable {
        fileprivate let admission: SourceRigReuseAdmission, epoch: SourceRigReuseEpoch
        fileprivate let snapshot: SourceRigReuseSnapshot?
    }
    public struct Candidate: Sendable {
        fileprivate let admission: SourceRigReuseAdmission, epoch: SourceRigReuseEpoch
        /// nil is an explicit clear-on-success intent, not a failed preparation.
        fileprivate let snapshot: SourceRigReuseSnapshot?
    }
    public struct Sample: Sendable, Encodable {
        public let hits: Int, misses: Int, admitted: Int, intrinsicBypasses: Int, capacityBypasses: Int
        /// Candidate snapshot only; clear intent carries no candidate payload.
        public let clearOnCommit: Bool, retainedEntries: Int, logicalEntryBytes: Int, logicalReferenceBytes: Int
        /// One instantaneous ledger observation at worker finish, including old
        /// input/delivery holders. Excludes non-cache values and is not heap/RSS.
        public let liveEntries: Int, liveLogicalEntryBytes: Int, liveSnapshots: Int
    }
    private let admission: SourceRigReuseAdmission
    private var epoch = SourceRigReuseEpoch()
    private var snapshot: SourceRigReuseSnapshot?
    public init() { admission = SourceRigReuseAdmission() }
    init(admission: SourceRigReuseAdmission) { self.admission = admission }
    public func input() -> Input { .init(admission: admission, epoch: epoch, snapshot: snapshot) }
    public func reset() { epoch = SourceRigReuseEpoch(); snapshot = nil }
    /// Call only after the selection's existing validation/transaction succeeds.
    @discardableResult public func commit(_ candidate: Candidate?) -> Bool {
        guard let candidate, candidate.admission === admission, candidate.epoch == epoch else { return false }
        snapshot = candidate.snapshot
        return true
    }
}

/// Synchronous worker-local state. Never crosses the preparation queue boundary.
/// It receives the exact bytes read by the original load path; callers must not
/// use it to bypass URL resolution, size/hash checks, or the original file read.
final class SourceRigReuseWorker {
    private let input: SourceMakerRigReuse.Input
    private var entries: [SourceRigReuseEntry]
    private var index: [SourceRigReuseKey: SourceRigReuseEntry]
    private var hits = 0, misses = 0, admitted = 0, intrinsicBypasses = 0, capacityBypasses = 0
    private var clearOnCommit = false
    init(_ input: SourceMakerRigReuse.Input) {
        self.input = input
        entries = input.snapshot?.entries ?? []
        index = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
    }
    func decode(_ data: Data, timings: SourceMakerPreparationTimings?) throws -> SourceRig {
        let hash = SourceMakerPreparationTimings.measure(timings, .rigReuseSHA) {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            timings?.hashed(data.count, phase: .rigReuseSHA, matches: true)
            return digest
        }
        // SHA256's canonical representation and Data.count satisfy this key's
        // checked contract. No filename or declared manifest digest substitutes.
        guard let key = SourceRigReuseKey(sha256: hash, byteCount: data.count) else {
            intrinsicBypasses += 1
            return try SourceMakerPreparationTimings.measure(timings, .rigDecode) { try SourceRig.decode(data) }
        }
        if let entry = index[key] { hits += 1; return entry.rig }
        misses += 1
        let rig = try SourceMakerPreparationTimings.measure(timings, .rigDecode) { try SourceRig.decode(data) }
        guard let charge = SourceRigReuseEntry.charge(rig: rig, key: key), charge <= input.admission.maximumBytes else {
            intrinsicBypasses += 1; return rig
        }
        guard !clearOnCommit, entries.count < input.admission.maximumEntries,
              let entry = SourceRigReuseEntry(rig: rig, key: key, epoch: input.epoch,
                                              admission: input.admission, measuredCharge: charge) else {
            capacityBypasses += 1; clearOnCommit = true; return rig
        }
        entries.append(entry); index[key] = entry; admitted += 1
        return rig
    }
    func finish() -> (SourceMakerRigReuse.Candidate, SourceMakerRigReuse.Sample) {
        let snapshot: SourceRigReuseSnapshot?
        if clearOnCommit { snapshot = nil }
        else if admitted == 0, let previous = input.snapshot { snapshot = previous }
        else {
            snapshot = SourceRigReuseSnapshot(entries: entries, epoch: input.epoch, admission: input.admission)
            if snapshot == nil { clearOnCommit = true }
        }
        // Clear intent needs no snapshot permit. It is published only by a
        // successful owner commit; failed/stale work cannot evict the old cache.
        let candidate = SourceMakerRigReuse.Candidate(admission: input.admission, epoch: input.epoch, snapshot: snapshot)
        let live = input.admission.counts
        let sample = SourceMakerRigReuse.Sample(hits: hits, misses: misses, admitted: admitted,
            intrinsicBypasses: intrinsicBypasses, capacityBypasses: capacityBypasses,
            clearOnCommit: clearOnCommit, retainedEntries: snapshot?.entries.count ?? 0,
            // Every referenced entry still owns its permit, so the sum is bounded
            // by this ledger's 64 MiB maximum rather than arbitrary Int addition.
            logicalEntryBytes: snapshot?.entries.reduce(0, { $0 + $1.logicalCharge }) ?? 0,
            logicalReferenceBytes: snapshot?.logicalReferenceBytes ?? 0,
            liveEntries: live.entries, liveLogicalEntryBytes: live.logicalBytes, liveSnapshots: live.snapshots)
        return (candidate, sample)
    }
}

private struct ReuseCharge {
    private(set) var bytes = 0
    mutating func add(_ amount: Int) -> Bool {
        guard amount >= 0 else { return false }
        let (value, overflow) = bytes.addingReportingOverflow(amount)
        guard !overflow else { return false }
        bytes = value; return true
    }
    mutating func product(_ count: Int, _ stride: Int) -> Bool {
        guard count >= 0, stride >= 0 else { return false }
        let (value, overflow) = count.multipliedReportingOverflow(by: stride)
        return !overflow && add(value)
    }
}
