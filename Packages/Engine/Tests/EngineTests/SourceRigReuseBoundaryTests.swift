import Foundation
import Dispatch
import os
import simd
import Testing
import Assets
import CoreMath
@testable import Scene
@testable import Character

private func reuseRig(parts: Int = 1) throws -> SourceRig {
    let definition = try RigDefinition(nodes: [.init(name: "肌", sourceID: "node", parent: nil)],
        skins: [.init(name: "skin", meshNode: 0, joints: [0], inverseBindMatrices: [matrix_identity_float4x4], rootJoint: 0)])
    let mesh = MeshData(name: "mesh", positions: [.zero, Float3(1, 0, 0), Float3(0, 1, 0)],
        normals: [Float3](repeating: Float3(0, 0, 1), count: 3),
        tangents: [Float4](repeating: Float4(1, 0, 0, 1), count: 3),
        uvs: [.zero, Float2(1, 0), Float2(0, 1)],
        joints: [SIMD4<UInt16>](repeating: .zero, count: 3), weights: [Float4](repeating: Float4(1, 0, 0, 0), count: 3),
        indices: [0, 1, 2], morphTargets: [.init(name: "smile", positionDeltas: [Float3](repeating: .zero, count: 3),
            normalDeltas: [Float3](repeating: .zero, count: 3))])
    return SourceRig(sourcePrefab: "fixture", rig: definition,
        parts: (0..<parts).map { _ in .init(mesh: mesh, node: 0, skin: 0, rendererEnabled: true) }, morphChannelCount: 1)
}
private func reuseKey(_ digit: Character = "a") -> SourceRigReuseKey {
    SourceRigReuseKey(sha256: String(repeating: String(digit), count: 64), byteCount: 100)!
}

private func reuseEncodedRig(_ name: String = "fixture") throws -> Data {
    let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    return try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1, "coordinateSpace": "unity-left-handed-y-up", "matrixLayout": "column-major",
        "uvConvention": "unity-source", "sourcePrefab": name,
        "nodes": [["name": "root", "sourceID": "root", "translation": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]]],
        "skins": [["name": "skin", "meshNode": 0, "joints": [0], "inverseBindMatrices": [identity]]],
        "meshes": [["name": "part", "node": 0, "skin": 0,
            "positions": [[0, 0, 1], [1, 0, 1], [0, 1, 1]], "normals": [[0, 0, 1], [0, 0, 1], [0, 0, 1]],
            "tangents": [], "uv0": [], "joints": [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]],
            "weights": [[1, 0, 0, 0], [1, 0, 0, 0], [1, 0, 0, 0]],
            "submeshes": [["indices": [0, 1, 2]]], "morphChannels": []]]
    ] as [String: Any], options: .sortedKeys)
}

/// Only the worker waits. Arrival resumes the test without blocking MainActor.
/// The timeout is a deadlock guard, not a performance assertion.
private final class RigReuseBarrier: Sendable {
    private struct State: Sendable {
        var arrived = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = DispatchSemaphore(value: 0)
    func waitOnWorker() throws {
        let waiter = state.withLock { value in
            value.arrived = true
            let waiter = value.waiter; value.waiter = nil
            return waiter
        }
        waiter?.resume()
        guard gate.wait(timeout: .now() + 30) == .success else { throw BarrierError.timeout }
    }
    func arrival() async {
        await withCheckedContinuation { continuation in
            let alreadyArrived = state.withLock { value in
                if value.arrived { return true }
                value.waiter = continuation; return false
            }
            if alreadyArrived { continuation.resume() }
        }
    }
    func release() { gate.signal() }
    private enum BarrierError: Error { case timeout }
}

@Test func sourceRigLogicalChargeCountsNativeLayoutStringsAndDenseMorphs() throws {
    let rig = try reuseRig()
    // An independently authored tiny value: one node/skin/name entry and one
    // three-vertex primitive with tangent, UV0, skin data and dense morph arrays.
    let hierarchy = MemoryLayout<RigDefinition.Node>.stride + MemoryLayout<RigDefinition.Skin>.stride
        + 3 * MemoryLayout<Int>.stride + MemoryLayout<Bool>.stride
        + MemoryLayout<float4x4>.stride + MemoryLayout<(String, [Int])>.stride
        + 3 + 4 + 4 + 3 // node name/id, skin name, names-dictionary UTF8 key
    let geometry = MemoryLayout<SourceRig.Part>.stride + MemoryLayout<MeshData.MorphTarget>.stride
        + 3 * (4 * MemoryLayout<Float3>.stride + 2 * MemoryLayout<Float4>.stride
            + MemoryLayout<Float2>.stride + MemoryLayout<SIMD4<UInt16>>.stride + MemoryLayout<UInt32>.stride)
        + 4 + 5 // mesh and morph names
    let expected = MemoryLayout<SourceRig>.stride + 7 + hierarchy + geometry
    #expect(rig.decodedCacheLogicalByteCount == expected)
    #expect(try reuseRig(parts: 2).decodedCacheLogicalByteCount == expected + geometry)
    let unicode = SourceRig(sourcePrefab: "🧵", rig: rig.rig, parts: rig.parts, morphChannelCount: 1)
    #expect(unicode.decodedCacheLogicalByteCount == expected - 7 + 4)
}

@Test func sourceRigLogicalChargeCountsOptionalArraysAndBypassesExtras() throws {
    let source = try reuseRig()
    var mesh = source.parts[0].mesh
    mesh.uvs1 = [Float2](repeating: .zero, count: 3); mesh.uvs2 = mesh.uvs1
    mesh.colors = [Float4](repeating: .zero, count: 3); mesh.regions = [1, 2, 3]
    func value(_ mesh: MeshData) -> SourceRig {
        SourceRig(sourcePrefab: source.sourcePrefab, rig: source.rig,
            parts: [.init(mesh: mesh, node: 0, skin: 0, rendererEnabled: true)], morphChannelCount: 1)
    }
    #expect(value(mesh).decodedCacheLogicalByteCount == source.decodedCacheLogicalByteCount.map {
        $0 + 6 * MemoryLayout<Float2>.stride + 3 * MemoryLayout<Float4>.stride + 3 * MemoryLayout<UInt8>.stride
    })
    mesh.extras = .string("unsupported retention")
    #expect(value(mesh).decodedCacheLogicalByteCount == nil)
    #expect(SourceRigReuseEntry(rig: value(mesh), key: reuseKey(), epoch: .init(), admission: .init()) == nil)
    #expect(value(mesh).parts[0].mesh.positions == source.parts[0].mesh.positions)
}

@Test func sourceRigLogicalChargeOverflowDoesNotAllocateOrWrap() {
    var sum = SourceRigLogicalCharge()
    let maximumAdded = sum.add(Int.max)
    #expect(maximumAdded)
    let overflowAdded = sum.add(1)
    #expect(!overflowAdded); #expect(sum.bytes == Int.max)
    var product = SourceRigLogicalCharge()
    let overflowMultiplied = product.product(Int.max, 2)
    #expect(!overflowMultiplied); #expect(product.bytes == 0)
    let negativeAdded = product.add(-1), negativeMultiplied = product.product(-1, 8)
    #expect(!negativeAdded); #expect(!negativeMultiplied)
    let zeroMultiplied = product.product(0, Int.max)
    #expect(zeroMultiplied); #expect(product.bytes == 0)
}

@Test func sourceRigReuseRejectsInvalidKeysAndCrossLedgerOrEpochSnapshots() throws {
    for hash in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
        #expect(SourceRigReuseKey(sha256: hash, byteCount: 100) == nil)
    }
    #expect(SourceRigReuseKey(sha256: String(repeating: "a", count: 64), byteCount: -1) == nil)
    #expect(SourceRigReuseKey(sha256: String(repeating: "a", count: 64), byteCount: 100, decoderVersion: 2) == nil)
    let a = SourceRigReuseAdmission(), b = SourceRigReuseAdmission(), epoch = SourceRigReuseEpoch()
    let entry = try #require(SourceRigReuseEntry(rig: reuseRig(), key: reuseKey(), epoch: epoch, admission: a))
    #expect(SourceRigReuseSnapshot(entries: [entry], epoch: epoch, admission: b) == nil)
    #expect(SourceRigReuseSnapshot(entries: [entry], epoch: .init(), admission: a) == nil)
    #expect(SourceRigReuseSnapshot(entries: [entry, entry], epoch: epoch, admission: a) == nil)
    #expect(a.counts.snapshots == 0 && b.counts == .init())
    let snapshot = try #require(SourceRigReuseSnapshot(entries: [entry], epoch: epoch, admission: a))
    #expect(snapshot.rig(for: reuseKey(), epoch: epoch)?.parts[0].mesh.positions == entry.rig.parts[0].mesh.positions)
    #expect(snapshot.rig(for: reuseKey(), epoch: .init()) == nil)
    #expect(snapshot.rig(for: reuseKey("b"), epoch: epoch) == nil)
    #expect(snapshot.rig(for: SourceRigReuseKey(sha256: reuseKey().sha256, byteCount: 101)!, epoch: epoch) == nil)
}

@Test func sourceRigReuseOldAndCopiedHoldersKeepCreditsUntilLastRelease() throws {
    var owner: SourceRigReuseAdmission? = .init(maximumEntries: 1, maximumSnapshots: 1)
    weak var observedOwner = owner
    let epoch = SourceRigReuseEpoch()
    var entry = SourceRigReuseEntry(rig: try reuseRig(), key: reuseKey(), epoch: epoch, admission: owner!)
    try #require(entry != nil)
    weak var observedEntry = entry
    let charge = entry!.logicalCharge
    var first = SourceRigReuseSnapshot(entries: [entry!], epoch: epoch, admission: owner!)
    try #require(first != nil)
    weak var observedSnapshot = first
    var copy = first
    entry = nil; first = nil
    #expect(observedEntry != nil && observedSnapshot != nil)
    #expect(owner!.counts == .init(entries: 1, logicalBytes: charge, snapshots: 1))
    #expect(SourceRigReuseEntry(rig: try reuseRig(), key: reuseKey("b"), epoch: .init(), admission: owner!) == nil)
    owner = nil // Reservations must strongly retain their ledger after Maker closes.
    #expect(observedOwner != nil)
    #expect(copy?.rig(for: reuseKey(), epoch: epoch)?.sourcePrefab == "fixture")
    copy = nil
    #expect(observedEntry == nil && observedSnapshot == nil && observedOwner == nil)
}

@Test func sourceRigReuseEntryByteAndSnapshotCapsBypassWithoutEarlyCreditRelease() throws {
    let rig = try reuseRig(), epoch = SourceRigReuseEpoch(), measurement = SourceRigReuseAdmission()
    let sample = try #require(SourceRigReuseEntry(rig: rig, key: reuseKey(), epoch: epoch, admission: measurement))
    let admission = SourceRigReuseAdmission(maximumBytes: sample.logicalCharge * 2, maximumEntries: 2, maximumSnapshots: 2)
    var entries: [SourceRigReuseEntry?] = [
        SourceRigReuseEntry(rig: rig, key: reuseKey(), epoch: epoch, admission: admission),
        SourceRigReuseEntry(rig: rig, key: reuseKey(), epoch: epoch, admission: admission)]
    #expect(entries.allSatisfy { $0 != nil }) // Distinct same-content objects each charge.
    #expect(admission.counts.entries == 2 && admission.counts.logicalBytes == sample.logicalCharge * 2)
    #expect(SourceRigReuseEntry(rig: rig, key: reuseKey("b"), epoch: epoch, admission: admission) == nil)
    var snapshots: [SourceRigReuseSnapshot?] = (0..<2).map { _ in
        SourceRigReuseSnapshot(entries: [entries[0]!], epoch: epoch, admission: admission)
    }
    #expect(snapshots.allSatisfy { $0 != nil })
    #expect(SourceRigReuseSnapshot(entries: [], epoch: .init(), admission: admission) == nil)
    entries[0] = nil
    #expect(admission.counts.entries == 2)
    snapshots[0] = nil
    #expect(admission.counts.snapshots == 1 && admission.counts.entries == 2)
    snapshots[1] = nil
    #expect(admission.counts.snapshots == 0 && admission.counts.entries == 1)
    entries[1] = nil
    #expect(admission.counts == .init())
    let tooSmall = SourceRigReuseAdmission(maximumBytes: sample.logicalCharge - 1)
    #expect(SourceRigReuseEntry(rig: rig, key: reuseKey(), epoch: epoch, admission: tooSmall) == nil)
    #expect(tooSmall.counts == .init())
    #expect(SourceRigReuseEntry(rig: rig, key: reuseKey("b"), epoch: .init(), admission: admission) != nil)
}

@Test func sourceRigReuseConcurrentAdmissionsStayWithinOneLedger() throws {
    let rig = try reuseRig(), epoch = SourceRigReuseEpoch(), admission = SourceRigReuseAdmission(maximumEntries: 4)
    let held = OSAllocatedUnfairLock(initialState: [SourceRigReuseEntry]())
    DispatchQueue.concurrentPerform(iterations: 64) { _ in
        if let entry = SourceRigReuseEntry(rig: rig, key: reuseKey(), epoch: epoch, admission: admission) {
            held.withLock { $0.append(entry) }
        }
    }
    #expect(held.withLock { $0.count } == 4)
    #expect(admission.counts.entries == 4)
    held.withLock { $0.removeAll() }
    #expect(admission.counts == .init())
}

@Test func sourceRigReuseSnapshotNativeReferenceChargeIsSeparate() throws {
    let admission = SourceRigReuseAdmission(), epoch = SourceRigReuseEpoch()
    let entry = try #require(SourceRigReuseEntry(rig: reuseRig(), key: reuseKey(), epoch: epoch, admission: admission))
    let snapshot = try #require(SourceRigReuseSnapshot(entries: [entry], epoch: epoch, admission: admission))
    let expected = MemoryLayout<[SourceRigReuseEntry]>.stride + MemoryLayout<SourceRigReuseEpoch>.stride
        + MemoryLayout<Int>.stride + 3 * MemoryLayout<AnyObject>.stride // permit field, permit owner, one entry reference
    #expect(snapshot.logicalReferenceBytes == expected)
    #expect(admission.counts.logicalBytes == entry.logicalCharge)
    let rigBytes = try #require(entry.rig.decodedCacheLogicalByteCount)
    let entryFields = MemoryLayout<SourceRigReuseKey>.stride + 64 + MemoryLayout<SourceRigReuseEpoch>.stride
        + 2 * MemoryLayout<Int>.stride + 2 * MemoryLayout<AnyObject>.stride
    #expect(entry.logicalCharge == rigBytes + entryFields)
    let nativeBytes = ["syntheticRig": rigBytes, "entryIncludingKeyAndPermit": entry.logicalCharge,
        "oneEntrySnapshot": expected, "sixteenEntrySnapshot": expected + 15 * MemoryLayout<AnyObject>.stride,
        "sourceRigStride": MemoryLayout<SourceRig>.stride, "partStride": MemoryLayout<SourceRig.Part>.stride,
        "nodeStride": MemoryLayout<RigDefinition.Node>.stride, "skinStride": MemoryLayout<RigDefinition.Skin>.stride,
        "morphStride": MemoryLayout<MeshData.MorphTarget>.stride, "float3Stride": MemoryLayout<Float3>.stride]
    let encoded = try JSONSerialization.data(withJSONObject: nativeBytes, options: .sortedKeys)
    print("sourceRigReuseNativeLogicalBytes " + String(decoding: encoded, as: UTF8.self))
}

@MainActor @Test func sourceRigReuseCancelledWorkerRetainsOldEpochCreditsUntilDrain() async throws {
    let admission = SourceRigReuseAdmission(maximumEntries: 1, maximumSnapshots: 1)
    let epoch = SourceRigReuseEpoch(), rig = try reuseRig(), barrier = RigReuseBarrier()
    let queue = SourceMakerPreparationQueue<SourceRigReuseSnapshot?>()
    defer { barrier.release() }
    var input: SourceRigReuseSnapshot? = try {
        let entry = try #require(SourceRigReuseEntry(rig: rig, key: reuseKey(), epoch: epoch, admission: admission))
        return try #require(SourceRigReuseSnapshot(entries: [entry], epoch: epoch, admission: admission))
    }()
    weak var observed = input
    let running = Task { [snapshot = input!] in
        try await queue.prepare { try barrier.waitOnWorker(); return snapshot }
    }
    await barrier.arrival()
    input = nil
    running.cancel()
    do { _ = try await running.value; Issue.record("Cancelled work returned its retained snapshot") }
    catch { #expect(error is CancellationError) }
    #expect(queue.isRunning && observed != nil)
    #expect(admission.counts.entries == 1 && admission.counts.snapshots == 1)
    // Session reset changes the epoch, but must not reset this same ledger.
    #expect(SourceRigReuseEntry(rig: rig, key: reuseKey(), epoch: .init(), admission: admission) == nil)
    barrier.release()
    await queue.drain()
    // drain marks actor delivery; a following serial operation also establishes
    // that the previous dispatch closure has finished unwinding its input.
    #expect(try await queue.prepare { nil } == nil)
    #expect(observed == nil && admission.counts == .init())
    #expect(SourceRigReuseEntry(rig: rig, key: reuseKey(), epoch: .init(), admission: admission) != nil)
}

@MainActor @Test func sourceRigReuseDeliveredCandidateRetainsCreditsAcrossNextWorker() async throws {
    let admission = SourceRigReuseAdmission(maximumEntries: 1, maximumSnapshots: 1)
    let epoch = SourceRigReuseEpoch(), rig = try reuseRig()
    let queue = SourceMakerPreparationQueue<SourceRigReuseSnapshot?>()
    var delivered = try await queue.prepare {
        let entry = try #require(SourceRigReuseEntry(rig: rig, key: reuseKey(), epoch: epoch, admission: admission))
        return try #require(SourceRigReuseSnapshot(entries: [entry], epoch: epoch, admission: admission))
    }
    weak var observed = delivered
    #expect(!queue.isRunning && delivered != nil)
    // A completed candidate may wait for owner validation/publication while a
    // following worker runs. Its strong permit still consumes the same budget.
    let next = try await queue.prepare {
        guard let entry = SourceRigReuseEntry(rig: rig, key: reuseKey("b"), epoch: .init(), admission: admission) else { return nil }
        return SourceRigReuseSnapshot(entries: [entry], epoch: entry.epoch, admission: admission)
    }
    #expect(next == nil && observed != nil)
    #expect(admission.counts.entries == 1 && admission.counts.snapshots == 1)
    delivered = nil
    #expect(observed == nil && admission.counts == .init())
}

@MainActor @Test func sourceRigReuseHashesActualBytesAndPublishesOnlyAcceptedCandidates() throws {
    let session = SourceMakerRigReuse(), data = try reuseEncodedRig(), timings = SourceMakerPreparationTimings()
    let worker = SourceRigReuseWorker(session.input())
    let first = try worker.decode(data, timings: timings), second = try worker.decode(data, timings: timings)
    #expect(first.rig.identity === second.rig.identity)
    let (candidate, sample) = worker.finish()
    #expect(sample.hits == 1 && sample.misses == 1 && sample.admitted == 1 && sample.retainedEntries == 1)
    #expect(timings.sample.intervals["rigDecode"]?.calls == 1)
    #expect(timings.sample.intervals["rigReuseSHA"]?.calls == 2)
    #expect(timings.sample.bytesHashed["rigReuseSHA"] == data.count * 2)
    // A prepared-but-unpublished value must not become another worker's hit.
    let unpublished = SourceRigReuseWorker(session.input())
    #expect(try unpublished.decode(data, timings: nil).rig.identity !== first.rig.identity)
    #expect(session.commit(candidate))
    let next = SourceRigReuseWorker(session.input())
    #expect(try next.decode(data, timings: nil).rig.identity === first.rig.identity)
    let changedBytes = data + Data(" ".utf8)
    let changed = try next.decode(changedBytes, timings: nil)
    #expect(changed.rig.identity !== first.rig.identity) // equivalent JSON still has different source bytes
    #expect(changed.parts[0].mesh.positions == first.parts[0].mesh.positions)
    #expect(changed.parts[0].mesh.indices == first.parts[0].mesh.indices)
    #expect(changed.parts[0].mesh.positions == [Float3(0, 0, -1), Float3(1, 0, -1), Float3(0, 1, -1)])
    #expect(changed.parts[0].mesh.indices == [0, 2, 1]) // conversion remains exactly once
    let nextSample = next.finish().1
    #expect(nextSample.hits == 1 && nextSample.misses == 1)
}

@MainActor @Test func sourceRigReuseInvalidBytesKeepDecodeErrorAndDoNotPublish() throws {
    let session = SourceMakerRigReuse(), worker = SourceRigReuseWorker(session.input())
    let malformed = Data("not JSON".utf8), timings = SourceMakerPreparationTimings()
    func corruptContext(_ operation: () throws -> SourceRig) -> [String] {
        do { _ = try operation(); Issue.record("Malformed bytes were accepted"); return [] }
        catch DecodingError.dataCorrupted(let context) { return [context.debugDescription] + context.codingPath.map(\.stringValue) }
        catch { Issue.record("Unexpected decoding error: \(error)"); return [] }
    }
    #expect(corruptContext { try worker.decode(malformed, timings: timings) } == corruptContext { try SourceRig.decode(malformed) })
    #expect(timings.sample.intervals["rigDecode"]?.failures == 1)
    #expect(timings.sample.bytesHashed["rigReuseSHA"] == malformed.count)
    #expect(worker.finish().1.retainedEntries == 0)
    let data = try reuseEncodedRig(), value = try worker.decode(data, timings: nil)
    let candidate = worker.finish().0
    let foreign = SourceMakerRigReuse()
    #expect(!foreign.commit(candidate))
    session.reset()
    #expect(!session.commit(candidate))
    #expect(try SourceRigReuseWorker(session.input()).decode(data, timings: nil).rig.identity !== value.rig.identity)
}

@MainActor @Test func sourceRigReuseCapacityClearRequiresCommitAndLastHolderRelease() throws {
    let ledger = SourceRigReuseAdmission(maximumEntries: 1)
    let session = SourceMakerRigReuse(admission: ledger)
    let oldData = try reuseEncodedRig("old"), newData = try reuseEncodedRig("new")
    func populate(_ data: Data) throws {
        let worker = SourceRigReuseWorker(session.input())
        _ = try worker.decode(data, timings: nil)
        #expect(session.commit(worker.finish().0))
    }
    try populate(oldData)
    var heldInput: SourceMakerRigReuse.Input? = session.input()
    var worker: SourceRigReuseWorker? = SourceRigReuseWorker(heldInput!)
    let value = try worker!.decode(newData, timings: nil)
    #expect(value.sourcePrefab == "new") // capacity must never reject valid geometry
    let (clear, sample) = worker!.finish()
    #expect(sample.clearOnCommit && sample.capacityBypasses == 1 && sample.retainedEntries == 0)
    // Simulate a later appearance failure: simply do not commit its candidate.
    let oldCheck = SourceRigReuseWorker(session.input())
    _ = try oldCheck.decode(oldData, timings: nil)
    #expect(oldCheck.finish().1.hits == 1 && ledger.counts.entries == 1)
    #expect(session.commit(clear))
    worker = nil
    #expect(ledger.counts.entries == 1) // heldInput and oldCheck still own the old epoch snapshot
    heldInput = nil
    // oldCheck deliberately remains held until this helper returns.
    func releasedCandidate() throws -> SourceMakerRigReuse.Candidate {
        let blocked = SourceRigReuseWorker(session.input())
        _ = try blocked.decode(newData, timings: nil)
        return blocked.finish().0
    }
    try withExtendedLifetime(oldCheck) {
        #expect(session.commit(try releasedCandidate()))
        #expect(ledger.counts.entries == 1)
    }
}

@MainActor @Test func sourceRigReuseSuccessfulClearAllowsDifferentKeyAfterOldInputDies() throws {
    let ledger = SourceRigReuseAdmission(maximumEntries: 1), data = try reuseEncodedRig("next")
    let session = SourceMakerRigReuse(admission: ledger)
    func oldSessionWork() throws {
        let first = SourceRigReuseWorker(session.input())
        _ = try first.decode(reuseEncodedRig("first"), timings: nil)
        #expect(session.commit(first.finish().0))
        let following = SourceRigReuseWorker(session.input())
        _ = try following.decode(data, timings: nil)
        let (clear, sample) = following.finish()
        #expect(sample.clearOnCommit)
        #expect(session.commit(clear))
        withExtendedLifetime((first, following)) { #expect(ledger.counts.entries == 1) }
    }
    try oldSessionWork()
    #expect(ledger.counts == .init())
    let next = SourceRigReuseWorker(session.input())
    _ = try next.decode(data, timings: nil)
    let (candidate, sample) = next.finish()
    #expect(sample.admitted == 1 && !sample.clearOnCommit && sample.retainedEntries == 1)
    #expect(session.commit(candidate))
}

@MainActor @Test func sourceRigReuseIntrinsicOversizeDoesNotEvictUsefulSnapshot() throws {
    let data = try reuseEncodedRig(), decoded = try SourceRig.decode(data)
    let key = SourceRigReuseKey(sha256: OriginalCardFixture.hash(data), byteCount: data.count)!
    let limit = try #require(SourceRigReuseEntry.charge(rig: decoded, key: key))
    let ledger = SourceRigReuseAdmission(maximumBytes: limit), session = SourceMakerRigReuse(admission: ledger)
    let initial = SourceRigReuseWorker(session.input())
    _ = try initial.decode(data, timings: nil)
    #expect(session.commit(initial.finish().0))
    let oversized = SourceRigReuseWorker(session.input())
    let value = try oversized.decode(reuseEncodedRig(String(repeating: "x", count: 2048)), timings: nil)
    #expect(value.sourcePrefab.count == 2048)
    let (candidate, sample) = oversized.finish()
    #expect(sample.intrinsicBypasses == 1 && !sample.clearOnCommit && sample.retainedEntries == 1)
    #expect(session.commit(candidate))
    let next = SourceRigReuseWorker(session.input())
    _ = try next.decode(data, timings: nil)
    #expect(next.finish().1.hits == 1)
}

@MainActor @Test func sourceRigReuseFullSnapshotBudgetClearsOnlyAfterSuccess() throws {
    let ledger = SourceRigReuseAdmission(maximumSnapshots: 1), session = SourceMakerRigReuse(admission: ledger)
    func initialCommit() throws {
        let worker = SourceRigReuseWorker(session.input())
        _ = try worker.decode(reuseEncodedRig("first"), timings: nil)
        #expect(session.commit(worker.finish().0))
    }
    try initialCommit()
    var held: SourceMakerRigReuse.Input? = session.input()
    var worker: SourceRigReuseWorker? = SourceRigReuseWorker(held!)
    let data = try reuseEncodedRig("second")
    _ = try worker!.decode(data, timings: nil)
    let (clear, sample) = worker!.finish()
    #expect(sample.admitted == 1 && sample.capacityBypasses == 0 && sample.clearOnCommit)
    #expect(ledger.counts.entries == 2 && ledger.counts.snapshots == 1)
    worker = nil
    #expect(ledger.counts.entries == 1 && ledger.counts.snapshots == 1)
    #expect(session.commit(clear))
    #expect(ledger.counts.entries == 1 && ledger.counts.snapshots == 1)
    held = nil
    #expect(ledger.counts == .init())
    let next = SourceRigReuseWorker(session.input())
    _ = try next.decode(data, timings: nil)
    let (candidate, nextSample) = next.finish()
    #expect(!nextSample.clearOnCommit && nextSample.retainedEntries == 1)
    #expect(session.commit(candidate))
}
