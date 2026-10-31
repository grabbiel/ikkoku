import Foundation
import Dispatch
import CryptoKit
import os
import Testing
import Scene
@testable import Character

private func shapeReuseData(label: String = "幅") throws -> Data {
    let mask = [true, false, false], off = [false, false, false]
    return try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1, "coordinateSystem": "UnityLeftHandedYUp", "rotationUnit": "degrees", "valueRange": [0, 1],
        "domains": [["id": "body", "valueCount": 1, "defaultValues": [0.5], "sourceNames": ["源"], "destinationNames": ["骨"],
            "slots": [["index": 0, "label": label, "bindings": [["sourceName": "源", "sourceIndex": 0,
                "positionMask": mask, "rotationMask": off, "scaleMask": off]]]],
            "channels": [["name": "源", "samples": [
                ["key": 0, "position": [0, 0, 0], "rotationDegrees": [0, 0, 0], "scale": [1, 1, 1]],
                ["key": 1, "position": [2, 0, 0], "rotationDegrees": [0, 0, 0], "scale": [1, 1, 1]]]]],
            "directTargets": [["sourceName": "源", "destinationName": "骨", "positionMask": mask, "rotationMask": off, "scaleMask": off]],
            "unportedDestinationNames": []]]
    ] as [String: Any], options: .sortedKeys)
}
private func shapeReuseContract() throws -> SourceShapeContract { try SourceShapeContract.decode(shapeReuseData()) }
private func shapeReuseKey(_ digit: String = "a") -> SourceShapeReuseKey {
    SourceShapeReuseKey(sha256: String(repeating: digit, count: 64), byteCount: 100)!
}

/// Explicit worker release only. Full-suite scheduling cannot cause a timed
/// auto-release to hide a cancellation/retention failure; the process watchdog bounds the test.
private final class ShapeReuseBarrier: Sendable {
    private struct State: Sendable { var arrived = false; var waiter: CheckedContinuation<Void, Never>? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = DispatchSemaphore(value: 0)
    func waitOnWorker() {
        let waiter = state.withLock { value in
            value.arrived = true; let waiter = value.waiter; value.waiter = nil; return waiter
        }
        waiter?.resume(); gate.wait()
    }
    func arrival() async {
        await withCheckedContinuation { continuation in
            let arrived = state.withLock { value in
                if value.arrived { return true }
                value.waiter = continuation; return false
            }
            if arrived { continuation.resume() }
        }
    }
    func release() { gate.signal() }
}

@Test func sourceShapeLogicalChargeIncludesNativeElementsAndUnicode() throws {
    let contract = try shapeReuseContract()
    // One domain, slot, binding, channel and direct target, two samples, two
    // String-array elements, 21 Float elements, 18 Bool elements and 50 UTF8 bytes.
    let expected = MemoryLayout<SourceShapeContract>.stride + MemoryLayout<SourceShapeDomain>.stride
        + MemoryLayout<SourceShapeSlot>.stride + MemoryLayout<SourceShapeBinding>.stride
        + MemoryLayout<SourceShapeChannel>.stride + 2 * MemoryLayout<SourceShapeSample>.stride
        + MemoryLayout<SourceShapeDirectTarget>.stride + 2 * MemoryLayout<String>.stride
        + 21 * MemoryLayout<Float>.stride + 18 * MemoryLayout<Bool>.stride + 50
    #expect(contract.decodedCacheLogicalByteCount == expected)
    let longer = try SourceShapeContract.decode(shapeReuseData(label: "🧵幅"))
    #expect(longer.decodedCacheLogicalByteCount == expected + 4)
    let admission = SourceShapeReuseAdmission(), epoch = SourceShapeReuseEpoch()
    let entry = try #require(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: epoch, admission: admission))
    let entryMetadata = MemoryLayout<SourceShapeReuseKey>.stride + 64 + MemoryLayout<SourceShapeReuseEpoch>.stride
        + 2 * MemoryLayout<Int>.stride + 2 * MemoryLayout<AnyObject>.stride
    #expect(entry.logicalCharge == expected + entryMetadata)
    let snapshot = try #require(SourceShapeReuseSnapshot(entries: [entry], epoch: epoch, admission: admission))
    let references = MemoryLayout<[SourceShapeReuseEntry]>.stride + MemoryLayout<SourceShapeReuseEpoch>.stride
        + MemoryLayout<Int>.stride + 3 * MemoryLayout<AnyObject>.stride
    #expect(snapshot.logicalReferenceBytes == references)
    #expect(admission.counts.logicalBytes == entry.logicalCharge)
    let sizes = ["contract": MemoryLayout<SourceShapeContract>.stride, "domain": MemoryLayout<SourceShapeDomain>.stride,
        "slot": MemoryLayout<SourceShapeSlot>.stride, "binding": MemoryLayout<SourceShapeBinding>.stride,
        "channel": MemoryLayout<SourceShapeChannel>.stride, "sample": MemoryLayout<SourceShapeSample>.stride,
        "target": MemoryLayout<SourceShapeDirectTarget>.stride, "string": MemoryLayout<String>.stride,
        "float": MemoryLayout<Float>.stride, "bool": MemoryLayout<Bool>.stride,
        "syntheticPayload": expected, "entryMetadata": entryMetadata, "oneEntrySnapshot": references,
        "sixEntrySnapshot": references + 5 * MemoryLayout<AnyObject>.stride]
    let encoded = try JSONSerialization.data(withJSONObject: sizes, options: .sortedKeys)
    print("sourceShapeReuseNativeLogicalBytes " + String(decoding: encoded, as: UTF8.self))
}

@Test func sourceShapeLogicalChargeOverflowDoesNotWrap() {
    var sum = SourceShapeLogicalCharge()
    let first = sum.add(Int.max), overflow = sum.add(1), negative = sum.add(-1)
    #expect(first && !overflow && !negative); #expect(sum.bytes == Int.max)
    var product = SourceShapeLogicalCharge()
    let multiplied = product.product(Int.max, 2), invalid = product.product(-1, 1), zero = product.product(0, Int.max)
    #expect(!multiplied && !invalid && zero); #expect(product.bytes == 0)
}

@Test func sourceShapeReuseRejectsInvalidKeysAndForeignSnapshots() throws {
    for hash in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
        #expect(SourceShapeReuseKey(sha256: hash, byteCount: 100) == nil)
    }
    #expect(SourceShapeReuseKey(sha256: shapeReuseKey().sha256, byteCount: -1) == nil)
    #expect(SourceShapeReuseKey(sha256: shapeReuseKey().sha256, byteCount: 100, decoderVersion: 2) == nil)
    let a = SourceShapeReuseAdmission(), b = SourceShapeReuseAdmission(), epoch = SourceShapeReuseEpoch()
    let contract = try shapeReuseContract()
    let entry = try #require(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: epoch, admission: a))
    #expect(SourceShapeReuseSnapshot(entries: [entry], epoch: epoch, admission: b) == nil)
    #expect(SourceShapeReuseSnapshot(entries: [entry], epoch: .init(), admission: a) == nil)
    #expect(SourceShapeReuseSnapshot(entries: [entry, entry], epoch: epoch, admission: a) == nil)
    let snapshot = try #require(SourceShapeReuseSnapshot(entries: [entry], epoch: epoch, admission: a))
    #expect(snapshot.contract(for: shapeReuseKey("b"), epoch: epoch) == nil)
    #expect(snapshot.contract(for: shapeReuseKey(), epoch: .init()) == nil)
    let wrongSize = try #require(SourceShapeReuseKey(sha256: shapeReuseKey().sha256, byteCount: 101))
    #expect(snapshot.contract(for: wrongSize, epoch: epoch) == nil)
    #expect(SourceMakerShapeReuse.Candidate(snapshot: snapshot, epoch: epoch, admission: b) == nil)
    #expect(SourceMakerShapeReuse.Candidate(snapshot: snapshot, epoch: .init(), admission: a) == nil)
}

@Test func sourceShapeReuseCopiedHoldersKeepCreditsUntilLastRelease() throws {
    var ledger: SourceShapeReuseAdmission? = .init(maximumEntries: 1, maximumSnapshots: 1)
    weak var observedLedger = ledger
    let epoch = SourceShapeReuseEpoch(), contract = try shapeReuseContract()
    var entry = SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: epoch, admission: ledger!)
    try #require(entry != nil); weak var observedEntry = entry
    let charge = entry!.logicalCharge
    var first = SourceShapeReuseSnapshot(entries: [entry!], epoch: epoch, admission: ledger!)
    try #require(first != nil); weak var observedSnapshot = first
    var copy = first
    entry = nil; first = nil
    #expect(observedEntry != nil && observedSnapshot != nil)
    #expect(ledger!.counts == .init(entries: 1, logicalBytes: charge, snapshots: 1))
    ledger = nil
    #expect(observedLedger != nil && copy != nil)
    copy = nil
    #expect(observedEntry == nil && observedSnapshot == nil && observedLedger == nil)
}

@Test func sourceShapeReuseNativeValueCopyIsImmutableAndOutsideLedgerLifetime() throws {
    let ledger = SourceShapeReuseAdmission(), epoch = SourceShapeReuseEpoch(), contract = try shapeReuseContract()
    var entry = SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: epoch, admission: ledger)
    try #require(entry != nil); weak var observedEntry = entry
    var snapshot = SourceShapeReuseSnapshot(entries: [entry!], epoch: epoch, admission: ledger)
    let native = try #require(snapshot?.contract(for: shapeReuseKey(), epoch: epoch))
    var detachedDomains = native.domains; detachedDomains.removeAll()
    #expect(detachedDomains.isEmpty && entry!.contract.domains.count == 1)
    entry = nil; snapshot = nil
    #expect(observedEntry == nil && ledger.counts == .init())
    let domain = try #require(native.domain("body")), state = try domain.makeState(values: [0.25])
    #expect(state["源"]?.position.x == 0.5)
}

@Test func sourceShapeReuseEntryAndSnapshotCapsReleaseWithoutEarlyCredits() throws {
    let contract = try shapeReuseContract(), epoch = SourceShapeReuseEpoch()
    let charge = try #require(SourceShapeReuseEntry.charge(contract: contract, key: shapeReuseKey()))
    let ledger = SourceShapeReuseAdmission(maximumBytes: charge * 2, maximumEntries: 2, maximumSnapshots: 2)
    var entries: [SourceShapeReuseEntry?] = (0..<2).map { _ in SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: epoch, admission: ledger) }
    #expect(entries.allSatisfy { $0 != nil }); #expect(ledger.counts.entries == 2 && ledger.counts.logicalBytes == charge * 2)
    #expect(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey("b"), epoch: epoch, admission: ledger) == nil)
    var snapshots: [SourceShapeReuseSnapshot?] = (0..<2).map { _ in SourceShapeReuseSnapshot(entries: [entries[0]!], epoch: epoch, admission: ledger) }
    #expect(snapshots.allSatisfy { $0 != nil })
    #expect(SourceShapeReuseSnapshot(entries: [], epoch: epoch, admission: ledger) == nil)
    entries[0] = nil; snapshots[0] = nil
    #expect(ledger.counts.entries == 2 && ledger.counts.snapshots == 1)
    snapshots[1] = nil
    #expect(ledger.counts.entries == 1 && ledger.counts.snapshots == 0)
    entries[1] = nil
    #expect(ledger.counts == .init())
    let small = SourceShapeReuseAdmission(maximumBytes: charge - 1)
    #expect(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: epoch, admission: small) == nil)
    #expect(small.counts == .init())
    #expect(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: .init(), admission: ledger) != nil)
}

@Test func sourceShapeReuseConcurrentAdmissionStaysWithinOneLedger() throws {
    let contract = try shapeReuseContract(), ledger = SourceShapeReuseAdmission(maximumEntries: 4), epoch = SourceShapeReuseEpoch()
    let held = OSAllocatedUnfairLock(initialState: [SourceShapeReuseEntry]())
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
        if let entry = SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: epoch, admission: ledger) {
            held.withLock { $0.append(entry) }
        }
    }
    #expect(held.withLock { $0.count } == 4 && ledger.counts.entries == 4)
    // Move strong references out before their destructors can call a ledger.
    var released: [SourceShapeReuseEntry]? = held.withLock { value in let old = value; value = []; return old }
    #expect(released?.count == 4); released = nil
    #expect(ledger.counts == .init())
}

@MainActor @Test func sourceShapeReuseResetRejectsStaleAndForeignCandidates() throws {
    let ledger = SourceShapeReuseAdmission(), epoch = SourceShapeReuseEpoch(), owner = SourceMakerShapeReuse(admission: ledger, epoch: epoch)
    let contract = try shapeReuseContract()
    var candidate: SourceMakerShapeReuse.Candidate? = try {
        let entry = try #require(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: epoch, admission: ledger))
        let snapshot = try #require(SourceShapeReuseSnapshot(entries: [entry], epoch: epoch, admission: ledger))
        return try #require(SourceMakerShapeReuse.Candidate(snapshot: snapshot, epoch: epoch, admission: ledger))
    }()
    #expect(owner.commit(candidate)); let counts = ledger.counts
    #expect(owner.commit(candidate)); #expect(ledger.counts == counts) // Idempotent publication, not new admission.
    let foreign = SourceMakerShapeReuse.Candidate(snapshot: nil, epoch: epoch, admission: .init())
    #expect(!owner.commit(foreign)); #expect(ledger.counts == counts)
    owner.reset()
    #expect(owner.input().snapshot == nil && ledger.counts == counts)
    #expect(!owner.commit(candidate))
    candidate = nil
    #expect(ledger.counts == .init())
}

@MainActor @Test func sourceShapeReuseReplacementReleasesOutsideCounterLock() throws {
    let ledger = SourceShapeReuseAdmission(maximumEntries: 2, maximumSnapshots: 2), epoch = SourceShapeReuseEpoch()
    let owner = SourceMakerShapeReuse(admission: ledger, epoch: epoch), contract = try shapeReuseContract()
    weak var first: SourceShapeReuseSnapshot?
    try {
        let entry = try #require(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: epoch, admission: ledger))
        let snapshot = try #require(SourceShapeReuseSnapshot(entries: [entry], epoch: epoch, admission: ledger)); first = snapshot
        let candidate = try #require(SourceMakerShapeReuse.Candidate(snapshot: snapshot, epoch: epoch, admission: ledger))
        #expect(owner.commit(candidate))
    }()
    #expect(first != nil && ledger.counts.entries == 1)
    try {
        let entry = try #require(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey("b"), epoch: epoch, admission: ledger))
        let snapshot = try #require(SourceShapeReuseSnapshot(entries: [entry], epoch: epoch, admission: ledger))
        let candidate = try #require(SourceMakerShapeReuse.Candidate(snapshot: snapshot, epoch: epoch, admission: ledger))
        #expect(owner.commit(candidate)) // Last old references deinit synchronously and acquire the counter lock.
    }()
    #expect(first == nil && ledger.counts.entries == 1 && ledger.counts.snapshots == 1)
    owner.reset()
    #expect(ledger.counts == .init())
}

@MainActor @Test func sourceShapeReuseCancelledWorkerRetainsResetCreditsUntilDrain() async throws {
    let ledger = SourceShapeReuseAdmission(maximumEntries: 1, maximumSnapshots: 1), epoch = SourceShapeReuseEpoch()
    let owner = SourceMakerShapeReuse(admission: ledger, epoch: epoch), contract = try shapeReuseContract(), barrier = ShapeReuseBarrier()
    let queue = SourceMakerPreparationQueue<SourceMakerShapeReuse.Input?>()
    defer { barrier.release() }
    var input: SourceMakerShapeReuse.Input? = try {
        let entry = try #require(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: epoch, admission: ledger))
        let snapshot = try #require(SourceShapeReuseSnapshot(entries: [entry], epoch: epoch, admission: ledger))
        let candidate = try #require(SourceMakerShapeReuse.Candidate(snapshot: snapshot, epoch: epoch, admission: ledger))
        #expect(owner.commit(candidate)); return owner.input()
    }()
    weak var observed = input?.snapshot
    let running = Task { [held = input!] in try await queue.prepare { barrier.waitOnWorker(); return held } }
    await barrier.arrival(); owner.reset(); input = nil
    running.cancel()
    do { _ = try await running.value; Issue.record("Cancelled worker returned a retained input") }
    catch { #expect(error is CancellationError) }
    #expect(queue.isRunning && observed != nil && ledger.counts.entries == 1 && ledger.counts.snapshots == 1)
    #expect(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: owner.input().epoch, admission: ledger) == nil)
    barrier.release(); await queue.drain()
    let drained = try await queue.prepare { nil }
    #expect(drained == nil && observed == nil && ledger.counts == .init())
    #expect(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: owner.input().epoch, admission: ledger) != nil)
}

@MainActor @Test func sourceShapeReuseDeliveredSnapshotRetainsCreditsAcrossNextWorker() async throws {
    let contract = try shapeReuseContract(), ledger = SourceShapeReuseAdmission(maximumEntries: 1, maximumSnapshots: 1), epoch = SourceShapeReuseEpoch()
    let queue = SourceMakerPreparationQueue<SourceShapeReuseSnapshot?>()
    var delivered = try await queue.prepare {
        let entry = try #require(SourceShapeReuseEntry(contract: contract, key: shapeReuseKey(), epoch: epoch, admission: ledger))
        return try #require(SourceShapeReuseSnapshot(entries: [entry], epoch: epoch, admission: ledger))
    }
    weak var observed = delivered
    let next = try await queue.prepare {
        guard let entry = SourceShapeReuseEntry(contract: contract, key: shapeReuseKey("b"), epoch: .init(), admission: ledger) else { return nil }
        return SourceShapeReuseSnapshot(entries: [entry], epoch: entry.epoch, admission: ledger)
    }
    #expect(next == nil && observed != nil && ledger.counts.entries == 1 && ledger.counts.snapshots == 1)
    delivered = nil
    #expect(observed == nil && ledger.counts == .init())
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SHAPE_REUSE_CONTRACTS"]), "Requires six pinned converted shape contracts"))
func sourceShapeReuseRepresentativeNativeChargesFitProvisionalBound() throws {
    struct Fixture: Decodable { let label: String, path: String, size: Int, sha256: String }
    let file = try SourceFixtureSupport.require("IKKOKU_SHAPE_REUSE_CONTRACTS")
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
    try #require(fixtures.count == 6 && Set(fixtures.map(\.label)).count == 6)
    let ledger = SourceShapeReuseAdmission(), epoch = SourceShapeReuseEpoch()
    var entries: [SourceShapeReuseEntry] = [], charges: [[String: Any]] = []
    for fixture in fixtures {
        try #require((1...64 * 1024 * 1024).contains(fixture.size))
        let bytes: Data = try {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: fixture.path))
            defer { try? handle.close() }
            return try handle.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data()
        }()
        try #require(bytes.count == fixture.size)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try #require(digest == fixture.sha256)
        let key = try #require(SourceShapeReuseKey(sha256: digest, byteCount: bytes.count))
        let contract = try SourceShapeContract.decode(bytes)
        let entry = try #require(SourceShapeReuseEntry(contract: contract, key: key, epoch: epoch, admission: ledger))
        let payload = try #require(contract.decodedCacheLogicalByteCount)
        entries.append(entry); charges.append(["label": fixture.label, "encodedBytes": bytes.count,
            "decodedPayloadBytes": payload, "entryLogicalBytes": entry.logicalCharge])
    }
    let total = entries.reduce(0) { $0 + $1.logicalCharge }
    #expect(ledger.counts.entries == 6 && ledger.counts.logicalBytes == total && total <= 8 * 1024 * 1024)
    let snapshot = try #require(SourceShapeReuseSnapshot(entries: entries, epoch: epoch, admission: ledger))
    let output = try JSONSerialization.data(withJSONObject: ["contracts": charges, "logicalEntryBytes": total,
        "snapshotReferenceBytes": snapshot.logicalReferenceBytes, "entryCap": ledger.maximumEntries,
        "logicalByteCap": ledger.maximumBytes, "snapshotCap": ledger.maximumSnapshots], options: .sortedKeys)
    print("sourceShapeReuseRepresentativeCharges " + String(decoding: output, as: UTF8.self))
}

private func shapeReuseEncoded(_ contract: SourceShapeContract) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(contract)
}

/// Error identity, not NSError descriptions (which include unstable object addresses).
private func shapeReuseFailure(_ action: () throws -> Void) -> [String: String] {
    do { try action(); Issue.record("Invalid shape preparation was accepted"); return [:] }
    catch let error as SourceShapeError { return ["shape": error.errorDescription ?? ""] }
    catch RigError.invalid(let reason) { return ["rig": reason] }
    catch let error as DecodingError {
        let kind: String, context: DecodingError.Context
        switch error {
        case .dataCorrupted(let value): kind = "dataCorrupted"; context = value
        case .keyNotFound(let key, let value): kind = "keyNotFound:" + key.stringValue; context = value
        case .typeMismatch(let type, let value): kind = "typeMismatch:" + String(describing: type); context = value
        case .valueNotFound(let type, let value): kind = "valueNotFound:" + String(describing: type); context = value
        @unknown default: return ["unknownDecodingError": "true"]
        }
        return ["decode": kind, "path": context.codingPath.map(\.stringValue).joined(separator: "/"), "detail": context.debugDescription]
    } catch {
        let error = error as NSError
        var result = ["domain": error.domain, "code": String(error.code), "path": error.userInfo[NSFilePathErrorKey] as? String ?? ""]
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            result["underlyingDomain"] = underlying.domain; result["underlyingCode"] = String(underlying.code)
            result["underlyingPath"] = underlying.userInfo[NSFilePathErrorKey] as? String ?? ""
        }
        return result
    }
}

@MainActor @Test func sourceShapeReuseWorkerHashesBytesAndSkipsOnlyWarmDecode() throws {
    let owner = SourceMakerShapeReuse(), data = try shapeReuseData(), changed = try shapeReuseData(label: "高")
    #expect(data.count == changed.count && data != changed)
    try {
        let worker = SourceShapeReuseWorker(owner.input()), timings = SourceMakerPreparationTimings()
        let decoded = try worker.decode(data, timings: timings), original = try SourceShapeContract.decode(data)
        let actual = try shapeReuseEncoded(decoded), expected = try shapeReuseEncoded(original)
        #expect(actual == expected)
        let (candidate, sample) = worker.finish()
        #expect(sample.misses == 1 && sample.hits == 0 && sample.admitted == 1)
        #expect(timings.sample.intervals["shapeDecode"]?.calls == 1 && timings.sample.intervals["shapeReuseAdmission"]?.calls == 1)
        #expect(timings.sample.bytesHashed["shapeReuseSHA"] == data.count)
        #expect(owner.commit(candidate))
    }()
    let worker = SourceShapeReuseWorker(owner.input()), timings = SourceMakerPreparationTimings()
    let warm = try worker.decode(data, timings: timings)
    #expect(warm.domains[0].slots[0].label == "幅")
    #expect(timings.sample.intervals["shapeDecode"] == nil && timings.sample.intervals["shapeReuseAdmission"] == nil)
    #expect(timings.sample.intervals["shapeReuseSHA"]?.calls == 1 && timings.sample.bytesHashed["shapeReuseSHA"] == data.count)
    let different = try worker.decode(changed, timings: timings)
    #expect(different.domains[0].slots[0].label == "高")
    let (candidate, sample) = worker.finish()
    #expect(sample.hits == 1 && sample.misses == 1 && sample.admitted == 1 && sample.retainedEntries == 2)
    #expect(timings.sample.intervals["shapeDecode"]?.calls == 1 && timings.sample.bytesHashed["shapeReuseSHA"] == data.count + changed.count)
    #expect(owner.commit(candidate))
    // Nil timing collectors still perform real cache work, without a clock/sample collector.
    let noTimings = SourceShapeReuseWorker(owner.input())
    let nilValue = try noTimings.decode(changed, timings: nil), nilBytes = try shapeReuseEncoded(nilValue)
    let expected = try shapeReuseEncoded(different)
    #expect(nilBytes == expected && noTimings.finish().1.hits == 1)
}

@MainActor @Test func sourceShapeReuseWorkerPreservesTypedDecodeFailures() throws {
    let owner = SourceMakerShapeReuse(), ledger = owner.input().admission
    var invalidSchema = try #require(try JSONSerialization.jsonObject(with: shapeReuseData()) as? [String: Any])
    invalidSchema["schemaVersion"] = 2
    let cases = [Data("{".utf8), try JSONSerialization.data(withJSONObject: invalidSchema), Data("{\"domains\":[]}".utf8)]
    for data in cases {
        let worker = SourceShapeReuseWorker(owner.input()), timings = SourceMakerPreparationTimings()
        let expected = shapeReuseFailure { _ = try SourceShapeContract.decode(data) }
        let actual = shapeReuseFailure { _ = try worker.decode(data, timings: timings) }
        #expect(actual == expected && !actual.isEmpty)
        #expect(timings.sample.intervals["shapeDecode"]?.failures == 1 && timings.sample.intervals["shapeReuseAdmission"] == nil)
        #expect(timings.sample.bytesHashed["shapeReuseSHA"] == data.count && ledger.counts == .init())
    }
}

@MainActor @Test func sourceShapeReuseWorkerIntrinsicBypassPreservesSnapshot() throws {
    let data = try shapeReuseData(), contract = try SourceShapeContract.decode(data)
    let charge = try #require(SourceShapeReuseEntry.charge(contract: contract, key: shapeReuseKey()))
    let ledger = SourceShapeReuseAdmission(maximumBytes: charge), owner = SourceMakerShapeReuse(admission: ledger)
    try {
        let worker = SourceShapeReuseWorker(owner.input()); _ = try worker.decode(data, timings: nil)
        #expect(owner.commit(worker.finish().0))
    }()
    weak var previous = owner.input().snapshot
    let large = try shapeReuseData(label: String(repeating: "幅", count: 100))
    let worker = SourceShapeReuseWorker(owner.input()), decoded = try worker.decode(large, timings: nil)
    let (candidate, sample) = worker.finish()
    #expect(decoded.domains[0].slots[0].label.utf8.count == 300)
    #expect(sample.intrinsicBypasses == 1 && sample.capacityBypasses == 0 && !sample.clearOnCommit && sample.admitted == 0)
    let sameSnapshot = candidate.snapshot === previous
    #expect(sameSnapshot && ledger.counts.entries == 1 && ledger.counts.snapshots == 1)
    #expect(owner.commit(candidate))
    let emptyLedger = SourceShapeReuseAdmission(maximumBytes: 0), emptyOwner = SourceMakerShapeReuse(admission: emptyLedger)
    let empty = SourceShapeReuseWorker(emptyOwner.input()); _ = try empty.decode(data, timings: nil)
    let emptyResult = empty.finish()
    #expect(emptyResult.1.intrinsicBypasses == 1 && !emptyResult.1.clearOnCommit && emptyLedger.counts == .init())
}

@MainActor @Test func sourceShapeReuseWorkerCapacityClearRequiresCommitAndDrain() throws {
    let ledger = SourceShapeReuseAdmission(maximumEntries: 1), owner = SourceMakerShapeReuse(admission: ledger)
    let a = try shapeReuseData(), b = try shapeReuseData(label: "高")
    try {
        let worker = SourceShapeReuseWorker(owner.input()); _ = try worker.decode(a, timings: nil)
        #expect(owner.commit(worker.finish().0))
    }()
    var held: SourceMakerShapeReuse.Input? = owner.input(); weak var old = held?.snapshot
    let clear = try { () -> SourceMakerShapeReuse.Candidate in
        let worker = SourceShapeReuseWorker(owner.input()); _ = try worker.decode(b, timings: nil)
        let (candidate, sample) = worker.finish()
        #expect(sample.capacityBypasses == 1 && sample.clearOnCommit && sample.admitted == 0 && candidate.snapshot == nil)
        return candidate
    }()
    let unchangedBeforeCommit = owner.input().snapshot === old
    #expect(unchangedBeforeCommit && ledger.counts.entries == 1)
    #expect(owner.commit(clear))
    #expect(old != nil && ledger.counts.entries == 1) // Captured input still owns its credits.
    try {
        let worker = SourceShapeReuseWorker(owner.input()); _ = try worker.decode(b, timings: nil)
        #expect(worker.finish().1.capacityBypasses == 1)
    }()
    held = nil
    #expect(old == nil && ledger.counts == .init())
    try {
        let worker = SourceShapeReuseWorker(owner.input()); _ = try worker.decode(b, timings: nil)
        let (candidate, sample) = worker.finish()
        #expect(sample.admitted == 1 && !sample.clearOnCommit); #expect(owner.commit(candidate))
    }()
    let recovered = SourceShapeReuseWorker(owner.input()); _ = try recovered.decode(b, timings: nil)
    #expect(recovered.finish().1.hits == 1)
}

@MainActor @Test func sourceShapeReuseWorkerSnapshotExhaustionDoesNotPublishOnFailure() throws {
    let ledger = SourceShapeReuseAdmission(maximumEntries: 2, maximumSnapshots: 1), owner = SourceMakerShapeReuse(admission: ledger)
    let a = try shapeReuseData(), b = try shapeReuseData(label: "高")
    try {
        let worker = SourceShapeReuseWorker(owner.input()); _ = try worker.decode(a, timings: nil)
        #expect(owner.commit(worker.finish().0))
    }()
    weak var old = owner.input().snapshot
    let rejected = try { () -> SourceMakerShapeReuse.Candidate in
        let worker = SourceShapeReuseWorker(owner.input()); _ = try worker.decode(b, timings: nil)
        let (candidate, sample) = worker.finish()
        #expect(sample.admitted == 1 && sample.capacityBypasses == 1 && sample.clearOnCommit)
        #expect(sample.liveEntries == 2 && sample.liveSnapshots == 1 && candidate.snapshot == nil)
        return candidate
    }()
    // Later transaction failure does not call commit. The new entry dies with
    // the worker; the previous owner snapshot and its permit are untouched.
    #expect(ledger.counts.entries == 1 && ledger.counts.snapshots == 1 && old != nil)
    let unchanged = owner.input().snapshot === old
    #expect(unchanged)
    owner.reset()
    try {
        let worker = SourceShapeReuseWorker(owner.input()); _ = try worker.decode(a, timings: nil)
        #expect(owner.commit(worker.finish().0))
    }()
    #expect(!owner.commit(rejected)) // A stale clear cannot evict the new epoch.
    let warm = SourceShapeReuseWorker(owner.input()); _ = try warm.decode(a, timings: nil)
    #expect(warm.finish().1.hits == 1)
}

@MainActor @Test func sourceShapeReuseCancelledCandidateDoesNotPublishOrEvict() async throws {
    let ledger = SourceShapeReuseAdmission(maximumEntries: 2), owner = SourceMakerShapeReuse(admission: ledger)
    let a = try shapeReuseData(), b = try shapeReuseData(label: "高"), barrier = ShapeReuseBarrier()
    let queue = SourceMakerPreparationQueue<SourceMakerShapeReuse.Candidate?>()
    defer { barrier.release() }
    try {
        let worker = SourceShapeReuseWorker(owner.input()); _ = try worker.decode(a, timings: nil)
        #expect(owner.commit(worker.finish().0))
    }()
    weak var old = owner.input().snapshot
    let running = Task { [input = owner.input()] in try await queue.prepare {
        let worker = SourceShapeReuseWorker(input); _ = try worker.decode(b, timings: nil)
        let candidate = worker.finish().0
        barrier.waitOnWorker()
        return candidate
    } }
    await barrier.arrival(); running.cancel()
    do { _ = try await running.value; Issue.record("Cancelled candidate was delivered") }
    catch { #expect(error is CancellationError) }
    let unchanged = owner.input().snapshot === old
    #expect(unchanged && ledger.counts.entries == 2)
    barrier.release(); await queue.drain()
    let drained = try await queue.prepare { nil }
    #expect(drained == nil && ledger.counts.entries == 1 && ledger.counts.snapshots == 1)
    let worker = SourceShapeReuseWorker(owner.input()); _ = try worker.decode(b, timings: nil)
    #expect(worker.finish().1.misses == 1) // The canceled candidate never warmed the owner.
}

@MainActor @Test func sourceMakerShapeReusePreservesReadAndFailureOrder() throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let libraryURL = directory.appendingPathComponent("library.json"), manifestURL = directory.appendingPathComponent("source-avatar.json")
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": [], "assemblies": []]).write(to: libraryURL)
    let library = try SourceMakerLibrary.load(url: libraryURL), card = try AppearanceTestFixture.card()
    var manifest: [String: Any] = ["schemaVersion": 1, "kind": "koikatsu-female-avatar", "name": "fixture", "sex": 1, "headID": 0,
        "bodySkeleton": "missing-body-master.json", "headSkeleton": "missing-head-master.json",
        "body": ["file": "missing-body.json"], "head": ["file": "missing-head.json"], "clothes": [], "hair": []]
    func writeManifest() throws { try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL) }
    try writeManifest()
    let shapeURL = directory.appendingPathComponent("character-shape-contract.json")
    let expressionURL = directory.appendingPathComponent("source-expression-contract.json")
    let data = try shapeReuseData(), changed = try shapeReuseData(label: "高")
    let ledger = SourceShapeReuseAdmission(), owner = SourceMakerShapeReuse(admission: ledger)
    try {
        let worker = SourceShapeReuseWorker(owner.input()); _ = try worker.decode(data, timings: nil)
        #expect(owner.commit(worker.finish().0))
    }()
    let initialCounts = ledger.counts
    weak var initialSnapshot = owner.input().snapshot
    func compareFailure(hashCalls: Int?, decodeCalls: Int?) -> ([String: String], SourceMakerPreparationTimings.Sample) {
        let plain = SourceMakerPreparationTimings(), cached = SourceMakerPreparationTimings()
        let expected = shapeReuseFailure { _ = try SourceMakerHeadPreparation.prepare(card: card, library: library,
            coordinate: 0, baseURL: manifestURL, timings: plain) }
        let actual = shapeReuseFailure { _ = try SourceMakerHeadPreparation.prepare(card: card, library: library,
            coordinate: 0, baseURL: manifestURL, timings: cached, shapeReuse: owner.input()) }
        #expect(actual == expected && !actual.isEmpty)
        #expect(plain.sample.intervals["shapeReuseSHA"] == nil && plain.sample.intervals["shapeReuseAdmission"] == nil)
        #expect(cached.sample.intervals["shapeReuseSHA"]?.calls == hashCalls && cached.sample.intervals["shapeDecode"]?.calls == decodeCalls)
        let unchanged = owner.input().snapshot === initialSnapshot
        #expect(unchanged && ledger.counts == initialCounts)
        return (actual, cached.sample)
    }
    // Wrong selected identity wins even with a missing shape and expression file.
    manifest["sex"] = 0; try writeManifest()
    let wrongIdentity = compareFailure(hashCalls: nil, decodeCalls: nil)
    #expect(wrongIdentity.0["rig"] == "Selected card and head assembly identities differ.")
    manifest["sex"] = 1; try writeManifest()
    let missing = compareFailure(hashCalls: nil, decodeCalls: nil)
    #expect(missing.1.intervals["shapeRead"]?.failures == 1 && missing.1.intervals["expressionRead"] == nil)
    // A cached digest does not authorize a companion symlink outside the selected folder.
    let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try data.write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: shapeURL, withDestinationURL: outside)
    let escaping = compareFailure(hashCalls: nil, decodeCalls: nil)
    #expect(escaping.0["rig"] == "Head assembly input escapes its folder.")
    try FileManager.default.removeItem(at: shapeURL)
    // Sparse file exercises the real bounded read and oversize-before-SHA order.
    try Data().write(to: shapeURL)
    let handle = try FileHandle(forWritingTo: shapeURL)
    try handle.truncate(atOffset: UInt64(64 * 1024 * 1024 + 1)); try handle.close()
    let oversized = compareFailure(hashCalls: nil, decodeCalls: nil)
    #expect(oversized.0["rig"] == "Head assembly input exceeds its size limit.")
    #expect(oversized.1.bytesRead["shapeRead"] == 64 * 1024 * 1024 + 1)
    // Warm bytes still read/hash, then the original missing expression failure wins.
    try data.write(to: shapeURL)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: shapeURL.path)
    let warm = compareFailure(hashCalls: 1, decodeCalls: nil)
    #expect(warm.1.bytesRead["shapeRead"] == data.count && warm.1.bytesHashed["shapeReuseSHA"] == data.count)
    #expect(warm.1.intervals["expressionRead"]?.failures == 1)
    // Same path, length and timestamp do not hide changed bytes. A later failure
    // must drop the newly admitted contract rather than warming/clearing the owner.
    try changed.write(to: shapeURL)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: shapeURL.path)
    let changedRead = compareFailure(hashCalls: 1, decodeCalls: 1)
    #expect(changedRead.1.intervals["shapeReuseAdmission"]?.calls == 1 && changedRead.1.intervals["expressionRead"]?.failures == 1)
    // Malformed shape must fail before an independently malformed later expression.
    let malformed = Data("{".utf8)
    try malformed.write(to: shapeURL); try malformed.write(to: expressionURL)
    let shapeFailure = compareFailure(hashCalls: 1, decodeCalls: 1)
    let decoderFailure = shapeReuseFailure { _ = try SourceShapeContract.decode(malformed) }
    #expect(shapeFailure.0 == decoderFailure && shapeFailure.1.intervals["expressionRead"] == nil)
    #expect(shapeFailure.1.intervals["shapeDecode"]?.failures == 1 && shapeFailure.1.intervals["shapeReuseAdmission"] == nil)
    // A successful shape hit does not suppress the later expression decoder.
    try data.write(to: shapeURL)
    let expressionFailure = compareFailure(hashCalls: 1, decodeCalls: nil)
    #expect(expressionFailure.1.intervals["expressionDecode"]?.failures == 1)
}
