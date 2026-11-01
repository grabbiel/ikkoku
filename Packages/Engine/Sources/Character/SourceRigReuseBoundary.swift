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
    /// `entry`'s decoded rig under a replacement's new epoch (#192-C). It
    /// shares `entry`'s permit, so the ledger charges the rig once while
    /// both live and returns the permit when the last of them is released.
    /// Only a replacement worker re-stamps, and only entries its seeding
    /// input carried from the session it replaces.
    fileprivate init(restamping entry: SourceRigReuseEntry, epoch: SourceRigReuseEpoch) {
        rig = entry.rig; key = entry.key; self.epoch = epoch; logicalCharge = entry.logicalCharge; permit = entry.permit
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
        /// A replacement's seeding input only: the replaced session's entries,
        /// re-stamped into `epoch` on a key hit (#192-C). Empty otherwise.
        fileprivate var carried: [SourceRigReuseEntry] = []
    }
    public struct Candidate: Sendable {
        fileprivate let admission: SourceRigReuseAdmission, epoch: SourceRigReuseEpoch
        /// nil is an explicit clear-on-success intent, not a failed preparation.
        fileprivate let snapshot: SourceRigReuseSnapshot?
    }
    /// A prospective new session, separate from ordinary selection publication.
    /// It retains only the ledger and epoch identities, not the old snapshot or
    /// an empty replacement snapshot. Creation does not invalidate current work.
    public struct Replacement: Sendable {
        fileprivate let admission: SourceRigReuseAdmission
        fileprivate let expectedEpoch: SourceRigReuseEpoch, epoch: SourceRigReuseEpoch
        public var input: Input { .init(admission: admission, epoch: epoch, snapshot: nil) }
    }
    public struct Sample: Sendable, Encodable {
        public let hits: Int, misses: Int, admitted: Int, intrinsicBypasses: Int, capacityBypasses: Int
        /// The hits a replacement took from the session it replaces (#192-C),
        /// counted in `hits` too.
        public let carried: Int
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
    public func prospectiveReplacement() -> Replacement {
        .init(admission: admission, expectedEpoch: epoch, epoch: .init())
    }
    /// The replacement's seeding input, or nil when the live ledger cannot
    /// admit the card's rigs and one snapshot now (CXM1).
    ///
    /// The input carries the current snapshot's entries when that session is
    /// the one the replacement replaces (#192-C). A rig whose exact bytes the
    /// session already holds is then re-stamped into the new epoch with the
    /// old entry's permit instead of being decoded again, so a reimport over
    /// a cached session needs permits only for the rigs it does not carry.
    /// Before #192-C every reimport over a cached session was declined: the
    /// old entries hold their permits until the replacement commits.
    ///
    /// `fileSizes` are the byte counts of the card's distinct rig files, nil
    /// when unknown. A file can be carried only if its size equals a carried
    /// key's, so the files that cannot are a lower bound on the permits the
    /// seed needs. The guard declines only a seed that surely overflows. A
    /// size that matches but whose bytes differ decodes and needs a permit
    /// the guard did not count; the worker's own limits then clear the staged
    /// snapshot as before, and never the current one.
    public func seedingInput(for replacement: Replacement, fileSizes: [Int?]) -> Input? {
        guard replacement.admission === admission else { return nil }
        var input = replacement.input
        if replacement.expectedEpoch == epoch, let snapshot, snapshot.epoch == epoch { input.carried = snapshot.entries }
        let carriedSizes = Set(input.carried.map { $0.key.byteCount })
        let uncarried = fileSizes.filter { size in size.map { !carriedSizes.contains($0) } ?? true }.count
        let live = admission.counts
        guard uncarried <= admission.maximumEntries - live.entries,
              live.snapshots < admission.maximumSnapshots else { return nil }
        return input
    }
    /// `seedingInput(for:fileSizes:)` with `entries` files of unknown size:
    /// every file counts as needing a permit.
    public func seedingInput(for replacement: Replacement, entries: Int) -> Input? {
        guard entries >= 0 else { return nil }
        return seedingInput(for: replacement, fileSizes: Array(repeating: nil, count: entries))
    }
    /// The byte counts `seedingInput(for:fileSizes:)` takes, from the files'
    /// metadata (no read; symbolic links resolved, as the load resolves
    /// them); nil for a file whose size is unavailable.
    public nonisolated static func fileSizes(_ files: [URL]) -> [Int?] {
        files.map { try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize }
    }
    /// Call only at successful new-session publication, after all owner gates.
    /// A nil candidate publishes an empty session (including reference fallback);
    /// failed preparation must instead drop the token without calling this method.
    /// Old holders keep their permits; no counter lock surrounds ARC replacement.
    @discardableResult public func commitReplacement(_ replacement: Replacement, candidate: Candidate?) -> Bool {
        guard replacement.admission === admission, replacement.expectedEpoch == epoch else { return false }
        if let candidate {
            guard candidate.admission === admission, candidate.epoch == replacement.epoch else { return false }
        }
        epoch = replacement.epoch
        snapshot = candidate?.snapshot
        return true
    }
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
    /// The replaced session's entries a replacement may re-stamp (#192-C).
    private let carried: [SourceRigReuseKey: SourceRigReuseEntry]
    private var hits = 0, misses = 0, admitted = 0, intrinsicBypasses = 0, capacityBypasses = 0, carriedHits = 0
    private var clearOnCommit = false
    init(_ input: SourceMakerRigReuse.Input) {
        self.input = input
        entries = input.snapshot?.entries ?? []
        index = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        carried = Dictionary(input.carried.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
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
        if let old = carried[key] {
            // The same bytes the replaced session decoded: no decode, and no
            // new permit. A staged clear or a full snapshot keeps it out of
            // the candidate, as for any other entry.
            hits += 1; carriedHits += 1
            guard !clearOnCommit, entries.count < input.admission.maximumEntries else {
                capacityBypasses += 1; clearOnCommit = true; return old.rig
            }
            let entry = SourceRigReuseEntry(restamping: old, epoch: input.epoch)
            entries.append(entry); index[key] = entry
            return entry.rig
        }
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
            intrinsicBypasses: intrinsicBypasses, capacityBypasses: capacityBypasses, carried: carriedHits,
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
