import Foundation
import os

/// One persistent ledger per Maker. Only numeric counters live under its lock;
/// replacing/destroying a holder must never release another permit under this lock.
final class SourceShapeReuseAdmission: Sendable {
    struct Counts: Sendable, Equatable {
        var entries = 0, logicalBytes = 0, snapshots = 0
    }
    let maximumBytes: Int, maximumEntries: Int, maximumSnapshots: Int
    private let state = OSAllocatedUnfairLock(initialState: Counts())
    init(maximumBytes: Int = 8 * 1024 * 1024, maximumEntries: Int = 6, maximumSnapshots: Int = 4) {
        precondition((0...8 * 1024 * 1024).contains(maximumBytes)
            && (1...6).contains(maximumEntries) && (1...4).contains(maximumSnapshots))
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
    private func releaseEntry(charge: Int) {
        state.withLock { value in
            precondition(value.entries > 0 && value.logicalBytes >= charge)
            value.entries -= 1; value.logicalBytes -= charge
        }
    }
    private func releaseSnapshot() {
        state.withLock { value in precondition(value.snapshots > 0); value.snapshots -= 1 }
    }
    fileprivate final class EntryPermit: Sendable {
        let owner: SourceShapeReuseAdmission, charge: Int
        init(owner: SourceShapeReuseAdmission, charge: Int) { self.owner = owner; self.charge = charge }
        deinit { owner.releaseEntry(charge: charge) }
    }
    fileprivate final class SnapshotPermit: Sendable {
        let owner: SourceShapeReuseAdmission
        init(owner: SourceShapeReuseAdmission) { self.owner = owner }
        deinit { owner.releaseSnapshot() }
    }
}

struct SourceShapeReuseEpoch: Hashable, Sendable { private let identity = UUID() }
struct SourceShapeReuseKey: Hashable, Sendable {
    let sha256: String, byteCount: Int, decoderVersion: Int
    init?(sha256: String, byteCount: Int, decoderVersion: Int = 1) {
        guard byteCount >= 0, decoderVersion == 1, sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.sha256 = sha256; self.byteCount = byteCount; self.decoderVersion = decoderVersion
    }
}

/// Stored element/UTF8 charge, not heap/RSS. All arithmetic fails closed for
/// cache admission without changing whether the original contract can decode.
struct SourceShapeLogicalCharge {
    private(set) var bytes = 0
    mutating func add(_ amount: Int) -> Bool {
        guard amount >= 0 else { return false }
        let (sum, overflow) = bytes.addingReportingOverflow(amount)
        guard !overflow else { return false }
        bytes = sum; return true
    }
    mutating func product(_ count: Int, _ stride: Int) -> Bool {
        guard count >= 0, stride >= 0 else { return false }
        let (amount, overflow) = count.multipliedReportingOverflow(by: stride)
        return !overflow && add(amount)
    }
    mutating func strings(_ values: [String]) -> Bool {
        guard product(values.count, MemoryLayout<String>.stride) else { return false }
        for value in values { guard add(value.utf8.count) else { return false } }
        return true
    }
}

extension SourceShapeContract {
    /// Inline structs include their Array/String fields. Their element buffers
    /// and every UTF8 occurrence are charged separately, even when COW shares
    /// or inlines storage. Excludes spare capacity, allocator/object headers,
    /// temporary Data/decoder storage and native non-cache value copies.
    var decodedCacheLogicalByteCount: Int? {
        var charge = SourceShapeLogicalCharge()
        guard charge.add(MemoryLayout<Self>.stride), charge.add(coordinateSystem.utf8.count), charge.add(rotationUnit.utf8.count),
              charge.product(valueRange.count, MemoryLayout<Float>.stride),
              charge.product(domains.count, MemoryLayout<SourceShapeDomain>.stride) else { return nil }
        for domain in domains {
            guard charge.add(domain.id.utf8.count), charge.product(domain.defaultValues.count, MemoryLayout<Float>.stride),
                  charge.strings(domain.sourceNames), charge.strings(domain.destinationNames), charge.strings(domain.unportedDestinationNames),
                  charge.product(domain.slots.count, MemoryLayout<SourceShapeSlot>.stride),
                  charge.product(domain.channels.count, MemoryLayout<SourceShapeChannel>.stride),
                  charge.product(domain.directTargets.count, MemoryLayout<SourceShapeDirectTarget>.stride) else { return nil }
            for slot in domain.slots {
                guard charge.add(slot.label.utf8.count), charge.product(slot.bindings.count, MemoryLayout<SourceShapeBinding>.stride) else { return nil }
                for binding in slot.bindings {
                    guard charge.add(binding.sourceName.utf8.count), charge.product(binding.positionMask.count, MemoryLayout<Bool>.stride),
                          charge.product(binding.rotationMask.count, MemoryLayout<Bool>.stride),
                          charge.product(binding.scaleMask.count, MemoryLayout<Bool>.stride) else { return nil }
                }
            }
            for channel in domain.channels {
                guard charge.add(channel.name.utf8.count), charge.product(channel.samples.count, MemoryLayout<SourceShapeSample>.stride) else { return nil }
                for sample in channel.samples {
                    guard charge.product(sample.position.count, MemoryLayout<Float>.stride),
                          charge.product(sample.rotationDegrees.count, MemoryLayout<Float>.stride),
                          charge.product(sample.scale.count, MemoryLayout<Float>.stride) else { return nil }
                }
            }
            for target in domain.directTargets {
                guard charge.add(target.sourceName.utf8.count), charge.add(target.destinationName.utf8.count),
                      charge.product(target.positionMask.count, MemoryLayout<Bool>.stride),
                      charge.product(target.rotationMask.count, MemoryLayout<Bool>.stride),
                      charge.product(target.scaleMask.count, MemoryLayout<Bool>.stride) else { return nil }
            }
        }
        return charge.bytes
    }
}

final class SourceShapeReuseEntry: Sendable {
    let contract: SourceShapeContract, key: SourceShapeReuseKey, epoch: SourceShapeReuseEpoch, logicalCharge: Int
    fileprivate let permit: SourceShapeReuseAdmission.EntryPermit
    init?(contract: SourceShapeContract, key: SourceShapeReuseKey, epoch: SourceShapeReuseEpoch, admission: SourceShapeReuseAdmission) {
        guard let charge = Self.charge(contract: contract, key: key), let permit = admission.entryPermit(charge: charge) else { return nil }
        self.contract = contract; self.key = key; self.epoch = epoch; self.logicalCharge = charge; self.permit = permit
    }
    static func charge(contract: SourceShapeContract, key: SourceShapeReuseKey) -> Int? {
        guard let payload = contract.decodedCacheLogicalByteCount else { return nil }
        var charge = SourceShapeLogicalCharge()
        guard charge.add(payload), charge.add(MemoryLayout<SourceShapeReuseKey>.stride), charge.add(key.sha256.utf8.count),
              charge.add(MemoryLayout<SourceShapeReuseEpoch>.stride), charge.add(MemoryLayout<Int>.stride),
              charge.add(MemoryLayout<SourceShapeReuseAdmission.EntryPermit>.stride),
              charge.add(MemoryLayout<SourceShapeReuseAdmission>.stride), charge.add(MemoryLayout<Int>.stride) else { return nil }
        return charge.bytes
    }
}

final class SourceShapeReuseSnapshot: Sendable {
    let entries: [SourceShapeReuseEntry], epoch: SourceShapeReuseEpoch, logicalReferenceBytes: Int
    fileprivate let permit: SourceShapeReuseAdmission.SnapshotPermit
    init?(entries: [SourceShapeReuseEntry], epoch: SourceShapeReuseEpoch, admission: SourceShapeReuseAdmission) {
        guard entries.count <= admission.maximumEntries,
              entries.allSatisfy({ $0.permit.owner === admission && $0.epoch == epoch }),
              Set(entries.map(\.key)).count == entries.count else { return nil }
        var charge = SourceShapeLogicalCharge()
        guard charge.add(MemoryLayout<[SourceShapeReuseEntry]>.stride), charge.add(MemoryLayout<SourceShapeReuseEpoch>.stride),
              charge.add(MemoryLayout<Int>.stride), charge.add(MemoryLayout<SourceShapeReuseAdmission.SnapshotPermit>.stride),
              charge.add(MemoryLayout<SourceShapeReuseAdmission>.stride), charge.product(entries.count, MemoryLayout<SourceShapeReuseEntry>.stride),
              let permit = admission.snapshotPermit() else { return nil }
        self.entries = entries; self.epoch = epoch; self.logicalReferenceBytes = charge.bytes; self.permit = permit
    }
    func contract(for key: SourceShapeReuseKey, epoch requested: SourceShapeReuseEpoch) -> SourceShapeContract? {
        guard requested == epoch else { return nil }
        return entries.first { $0.key == key }?.contract
    }
}

/// Boundary only: not connected to Maker preparation yet. This persistent ledger
/// outlives reset snapshots while any old captured/delivery holder still exists.
@MainActor public final class SourceMakerShapeReuse {
    public struct Input: Sendable {
        let admission: SourceShapeReuseAdmission, epoch: SourceShapeReuseEpoch
        let snapshot: SourceShapeReuseSnapshot?
    }
    public struct Candidate: Sendable {
        let admission: SourceShapeReuseAdmission, epoch: SourceShapeReuseEpoch
        /// nil represents a clear-on-success intent, never an error fallback.
        let snapshot: SourceShapeReuseSnapshot?
        init?(snapshot: SourceShapeReuseSnapshot?, epoch: SourceShapeReuseEpoch, admission: SourceShapeReuseAdmission) {
            if let snapshot { guard snapshot.epoch == epoch && snapshot.permit.owner === admission else { return nil } }
            self.snapshot = snapshot; self.epoch = epoch; self.admission = admission
        }
    }
    private let admission: SourceShapeReuseAdmission
    private var epoch: SourceShapeReuseEpoch
    private var snapshot: SourceShapeReuseSnapshot?
    public init() { admission = .init(); epoch = .init() }
    init(admission: SourceShapeReuseAdmission, epoch: SourceShapeReuseEpoch = .init()) { self.admission = admission; self.epoch = epoch }
    public func input() -> Input { .init(admission: admission, epoch: epoch, snapshot: snapshot) }
    public func reset() {
        epoch = .init()
        // No admission lock is held while releasing the replaced ARC graph.
        snapshot = nil
    }
    @discardableResult public func commit(_ candidate: Candidate?) -> Bool {
        guard let candidate, candidate.admission === admission, candidate.epoch == epoch else { return false }
        // Reference replacement can synchronously deinit permits and reenter
        // admission. Keep it outside the counter-only ledger lock.
        snapshot = candidate.snapshot
        return true
    }
}
