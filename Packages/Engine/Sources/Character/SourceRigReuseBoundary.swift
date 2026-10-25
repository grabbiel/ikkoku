import Foundation
import os
import Scene

/// No Maker integration yet. Immutable holders retain reservations independently
/// of worker slots, cancellation, actor delivery and source-session epochs.
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
    init?(rig: SourceRig, key: SourceRigReuseKey, epoch: SourceRigReuseEpoch, admission: SourceRigReuseAdmission) {
        guard let rigBytes = rig.decodedCacheLogicalByteCount else { return nil }
        // Stored field/permit payloads are charged; class allocation headers and
        // allocator overhead remain excluded. The rig's inline stride is in rigBytes.
        var charge = ReuseCharge()
        guard charge.add(rigBytes), charge.add(MemoryLayout<SourceRigReuseKey>.stride), charge.add(key.sha256.utf8.count),
              charge.add(MemoryLayout<SourceRigReuseEpoch>.stride), charge.add(MemoryLayout<Int>.stride),
              charge.add(MemoryLayout<SourceRigReuseAdmission.EntryPermit>.stride),
              charge.add(MemoryLayout<SourceRigReuseAdmission>.stride), charge.add(MemoryLayout<Int>.stride),
              let permit = admission.entryPermit(charge: charge.bytes) else { return nil }
        self.rig = rig; self.key = key; self.epoch = epoch; self.logicalCharge = charge.bytes; self.permit = permit
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
