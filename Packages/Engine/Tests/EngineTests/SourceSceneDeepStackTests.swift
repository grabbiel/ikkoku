import Foundation
import CryptoKit
import Darwin
import Metal
import os
import Testing
import Renderer
@testable import Studio

// #321 / #326: a scene decode (`KoikatsuSceneReader.decodeDocument`)
// recurses once per nesting level, and so do the legacy upgrade, the
// insertion stage, the export's edit, the layout import and a record
// comparison. The reader accepts `KoikatsuBinaryReader.maximumLevels`
// (65 before #326). Each of those operations runs on the decode stack
// (`SourceStudioCharacterBatch.onDecodeStack`, `stackSize`): in line on a
// thread that has it (the character batch's workers), otherwise on a thread
// of its own. The walks left on a caller's stack fit half the main thread's
// 8 MiB, and no deep tree is released on a GCD worker's 512 KiB.
//
// The scenes here are synthetic, written by `TopologyScene`, never a user
// scene: nested folders, and nested characters each held by the previous
// one's accessory point (a character level adds `character(depth:)`'s
// frame, the deepest chain per level). Writing and releasing them recurse
// too, so the tests do both on threads of 8 MiB or more (`liveTickOffPool`,
// `onThread`), never on the Swift concurrency pool's 512 KiB.

/// The deepest scene the reader accepts.
private let deepestLevels = KoikatsuBinaryReader.maximumLevels
private let gcdWorkerStack = 512 * 1024
private let mainThreadStack = 8 << 20
/// Larger than the decode stack: every operation runs in line on it, so
/// `stackTaken` sees all of it.
private let measuringStack = 96 << 20

private enum DeepChain: String, CaseIterable { case folders, characters }

/// Object 0 holds object 1, which holds object 2, and so on down to object
/// `levels - 1`.
private func deepScene(levels: Int, chain: DeepChain) -> Data {
    var scene = TopologyScene(roots: [])
    var node: TopologyNode?
    for key in stride(from: Int32(levels - 1), through: 0, by: -1) {
        switch chain {
        case .folders: node = .folder(key, node.map { [$0] } ?? [])
        case .characters:
            let groups: [(point: Int32, children: [TopologyNode])] = [(point: Int32(0), children: node.map { [$0] } ?? [])]
            node = .character(key, groups)
            scene.lookAt[key] = 1000 + key
        }
    }
    scene.roots = node.map { [$0] } ?? []
    return scene.data
}

/// The scene written to `folder`, and a reference whose object key the
/// scene does not hold: a first half decodes the whole scene, walks every
/// object, finds no record and refuses before it reads any other file.
private func deepReference(_ data: Data, chain: DeepChain, in folder: URL) throws -> SourceStudioCharacterReference {
    let scene = folder.appendingPathComponent("deep-\(chain.rawValue).png")
    try data.write(to: scene)
    let absent = folder.appendingPathComponent("absent.json").path
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return SourceStudioCharacterReference(sceneFile: scene.path, sceneSHA256: hash, rigFile: absent,
                                          boneCatalogFile: absent, objectKey: -1)
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-321-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A 0.0.7 scene of nested folders: the legacy upgrade reads it twice and
/// compares its records.
private func deepLegacyFolders(levels: Int) -> Data {
    var out = SceneDocumentBytes(data: OriginalCardFixture.png)
    out.s("0.0.7"); out.i(1); out.i(0)
    for key in 0..<Int32(levels) { out.header(3, key); out.s("Folder"); out.i(key == Int32(levels - 1) ? 0 : 1) }
    out.tail()
    return out.data
}

/// Runs `body` on a thread of its own with `stack` bytes.
private func onThread<T: Sendable>(stack: Int, _ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread { continuation.resume(with: Result { try body() }) }
        thread.stackSize = stack
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

/// #326: runs `body` on the decode stack, as the Studio's scene operations
/// do. A record comparison (`KoikatsuObjectRecord.==`) recurses through both
/// subtrees, and in Debug it stops the process on any smaller stack.
func onDecodeStack<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
    try SourceStudioCharacterBatch.onDecodeStack("Ikkoku test", body)
}

/// What a thread smaller than the deepest release must not drop: it keeps
/// its inputs and results here, and the test drops them on a thread of
/// 8 MiB or more.
private final class Kept: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    subscript<T>(_ key: String) -> T {
        lock.lock(); defer { lock.unlock() }
        return values[key] as! T
    }
    func keep(_ key: String, _ value: Any) { lock.lock(); values[key] = value; lock.unlock() }
    /// Drops one value on the calling thread.
    func drop(_ key: String) {
        lock.lock(); let dropped = values.removeValue(forKey: key); lock.unlock()
        withExtendedLifetime(dropped) {}
    }
    /// Drops every value on the calling thread.
    func dropAll() {
        lock.lock(); let dropped = values; values = [:]; lock.unlock()
        withExtendedLifetime(dropped) {}
    }
}

/// Depth first, every record of the tree with its level (roots are 1).
private func levelCount(_ roots: [KoikatsuObjectRecord]) -> (records: Int, levels: Int) {
    var stack = roots.map { ($0, 1) }, records = 0, levels = 0
    while let (record, level) = stack.popLast() {
        records += 1; levels = max(levels, level)
        stack += record.children.map { ($0, level + 1) }
        for children in (record.character?.accessoryChildren ?? [:]).values { stack += children.map { ($0, level + 1) } }
    }
    return (records, levels)
}

/// The stack `body` takes below the caller's frame, in bytes. The thread's
/// free stack is filled with a pattern first; afterwards the lowest address
/// that no longer holds it marks the deepest frame. A frame that leaves its
/// lowest bytes unwritten reads a little short, so the result is a lower
/// bound. The calling thread needs far more stack than `body` takes.
@inline(never)
private func stackTaken(by body: () throws -> Void) rethrows -> Int {
    let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
    let bottom = top - UInt(pthread_get_stacksize_np(pthread_self()))
    var anchor = 0
    let here = withUnsafeMutablePointer(to: &anchor) { UInt(bitPattern: $0) }
    // Clear of the guard page below, and of this frame and memset's above.
    let low = bottom + 64 * 1024, high = (here - 16 * 1024) & ~UInt(15)
    precondition(low < high, "the calling thread's stack is too small to measure on")
    let pattern = UInt64(0xA5A5_A5A5_A5A5_A5A5)
    memset(UnsafeMutableRawPointer(bitPattern: low)!, 0xA5, Int(high - low))
    try body()
    var address = low
    while address < high, UnsafePointer<UInt64>(bitPattern: address)!.pointee == pattern { address += 8 }
    return Int(here - address)
}

/// What a worker callback saw, published to the waiting test by `done`.
private final class Observed: @unchecked Sendable {
    var stackSizes: [Int] = []
    let lock = NSLock()
    let done = DispatchSemaphore(value: 0)
    func record(_ size: Int) {
        lock.lock(); stackSizes.append(size); lock.unlock()
        done.signal()
    }
}

@Test func theReaderReadsItsLevelCapAndRefusesOneLevelMore() async throws {
    let (deepest, refusal) = try await liveTickOffPool { () -> (Int, String) in
        var depth = 0, level = try KoikatsuSceneReader.decodeDocument(deepScene(levels: deepestLevels, chain: .folders)).snapshot.roots
        while let object = level.first { depth += 1; level = object.children }
        do { _ = try KoikatsuSceneReader.decodeDocument(deepScene(levels: deepestLevels + 1, chain: .folders)); return (depth, "decoded") }
        catch { return (depth, String(describing: error)) }
    }
    #expect(deepest == deepestLevels)
    #expect(refusal == #"limitExceeded("objects nested more than \#(deepestLevels) levels deep (Ikkoku reads at most \#(deepestLevels))")"#)
}

/// The negative control: the stack the first half takes on the deepest
/// scenes the reader accepts, measured where it all runs in line, against a
/// GCD worker's 512 KiB. Release takes far less, so only Debug is held to it.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device for the store"))
func theDeepestScenesFirstHalfNeedsMoreThanAGCDWorkersStack() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var taken: [DeepChain: (decode: Int, release: Int, firstHalf: Int, outcome: String)] = [:]
    for chain in DeepChain.allCases {
        taken[chain] = try await onThread(stack: measuringStack) { () -> (decode: Int, release: Int, firstHalf: Int, outcome: String) in
            let data = deepScene(levels: deepestLevels, chain: chain)
            let reference = try deepReference(data, chain: chain, in: folder)
            // The decode alone (its result is kept), then the release alone.
            var document: KoikatsuSceneDocument?
            let decode = try stackTaken { document = try KoikatsuSceneReader.decodeDocument(data) }
            let release = stackTaken { document = nil }
            var outcome = "assembled"
            let firstHalf = stackTaken {
                do { _ = try SourceStudioCharacterPreview.assemble(reference: reference, resources: resources) }
                catch { outcome = String(describing: error) }
            }
            return (decode, release, firstHalf, outcome)
        }
        let measured = try #require(taken[chain])
        print("[#326 deep stack] \(deepestLevels) nested \(chain.rawValue): the decode took \(measured.decode / 1024) KiB of stack, "
              + "its release \(measured.release / 1024) KiB, the first half \(measured.firstHalf / 1024) KiB")
        #expect(measured.outcome == "Source character record is missing.", "\(chain.rawValue)")
        // The batch's workers hold it with half their stack to spare.
        #expect(measured.firstHalf < SourceStudioCharacterBatch.stackSize / 2, "\(chain.rawValue): \(measured.firstHalf) bytes")
        // Releasing the tree recurses too, but far less: the main thread holds
        // it. No deep tree dies on a GCD worker: a preview's record is shallow
        // (`theDeepestPreviewRecordHoldsNoSubtree`), and so is the hidden card
        // check's (`theHiddenCardCheckHoldsNoSceneSubtree`).
        #expect(measured.release < mainThreadStack / 2, "\(chain.rawValue): \(measured.release) bytes")
    }
    #if DEBUG
    let deepest = taken.values.map { $0.firstHalf }.max() ?? 0
    #expect(deepest > gcdWorkerStack, "\(deepest) bytes: a GCD worker could hold the deepest first half")
    #endif
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device for the store"))
func theCharacterBatchDecodesTheDeepestScenesOnItsOwnStack() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let references = try await liveTickOffPool { () -> [SourceStudioCharacterReference] in
        try DeepChain.allCases.map { try deepReference(deepScene(levels: deepestLevels, chain: $0), chain: $0, in: folder) }
    }
    let observed = Observed()
    let outcomes = try await liveTickOffPool { () -> [String] in
        let batch = SourceStudioCharacterBatch(requests: references.map { .init(reference: $0) }, resources: resources,
                                               assembled: { _ in observed.record(pthread_get_stacksize_np(pthread_self())) })
        let outcomes = references.indices.map { index -> String in
            do { _ = try batch.assembly(index); return "assembled" } catch { return String(describing: error) }
        }
        for _ in references { observed.done.wait() }
        return outcomes
    }
    #expect(outcomes == Array(repeating: "Source character record is missing.", count: references.count))
    #expect(observed.stackSizes.count == references.count
            && observed.stackSizes.allSatisfy { $0 >= SourceStudioCharacterBatch.stackSize }, "\(observed.stackSizes)")
}

/// Each scene path's stack (`stackTaken`) on the deepest scenes the reader
/// accepts, what it counted, and a folder's refusal one level past the cap:
/// the decode, the legacy upgrade (folders), the export (a move of the
/// deepest object, and a deletion of the deepest folder or the root
/// character), the insertion stage (a record at the cap), the layout import
/// (folders; it imports folders and items) and the record walks of the
/// import and export.
private func scenePaths(_ chain: DeepChain) throws -> (taken: [String: Int], counts: [String: Int], refusal: String?) {
    let deepest = Int32(deepestLevels - 1)
    let data = deepScene(levels: deepestLevels, chain: chain)
    var taken: [String: Int] = [:], counts: [String: Int] = [:]
    var decoded: KoikatsuSceneDocument?
    taken["decode"] = try stackTaken { decoded = try KoikatsuSceneReader.decodeDocument(data) }
    let document = decoded!
    decoded = nil
    func exported(_ edits: SourceSceneEdits) throws -> Int {
        let edited = try document.editedData(edits)
        return SourceSceneInsertionPlan.records(try KoikatsuSceneReader.decodeDocument(edited).snapshot).count
    }
    let moved = KoikatsuChangeAmount(position: SIMD3(1, 2, 3), rotationDegrees: .zero, scale: .one)
    taken["export (move the deepest)"] = try stackTaken {
        counts["export (move)"] = try exported(.init(transforms: [.init(.object(deepest), transform: moved)]))
    }
    // The export refuses to delete a character's accessory child on its own,
    // so the nested characters go from the root down.
    let deletion: Int32 = chain == .folders ? deepest : 0
    taken["export (delete \(chain == .folders ? "the deepest" : "the root"))"] = try stackTaken {
        counts["export (delete)"] = try exported(.init(deletions: [deletion]))
    }
    // The export adds nothing onto a character's accessory point but a
    // duplicate beside its original, so the nested characters take a copy of
    // the deepest, and only a folder can pass the cap.
    let atTheCap: SourceSceneInsertion = chain == .folders
        ? .init(.folder(name: "New"), parent: .source(deepest - 1))
        : .init(.duplicate(of: deepest), parent: .source(deepest - 1), attachment: 0)
    taken["insertion (at the cap)"] = try stackTaken {
        let stage = try document.inserting([atTheCap])
        counts["insertion"] = SourceSceneInsertionPlan.records(stage.document.snapshot).count
    }
    var refusal: String?
    if chain == .folders {
        refusal = "inserted"
        taken["insertion (a folder past the cap)"] = stackTaken {
            do { _ = try document.inserting([.init(.folder(name: "New"), parent: .source(deepest))]) }
            catch { refusal = String(describing: error) }
        }
        let legacy = try KoikatsuSceneReader.decodeDocument(deepLegacyFolders(levels: deepestLevels))
        taken["legacy upgrade"] = try stackTaken {
            let upgraded = try legacy.upgraded()
            counts["legacy upgrade"] = upgraded.isLegacy ? 0 : levelCount(upgraded.snapshot.roots).levels
        }
        let catalog = try JSONDecoder().decode(KoikatsuAssetCatalog.self, from: Data(#"{"version": 1, "items": []}"#.utf8))
        taken["layout import"] = try stackTaken {
            let imported = try KoikatsuLayoutImporter.convert(document.snapshot, catalog: catalog,
                                                              catalogDirectory: FileManager.default.temporaryDirectory)
            counts["layout import"] = imported.objects.count
        }
    }
    taken["record walks"] = stackTaken {
        counts["records"] = SourceSceneInsertionPlan.records(document.snapshot).count
        _ = SourceSceneInsertionPlan.usedKeys(document.snapshot)
        _ = SourceStudioCameraObjects.activeAtLoad(document.snapshot)
        _ = SourceStudioRoutePlayback.samples(in: document.snapshot, elapsed: 0)
        _ = document.snapshot.containsCharacter
    }
    return (taken, counts, refusal)
}

/// The scene paths on the deepest scenes (`scenePaths`), twice. Where
/// everything runs in line, each takes less than half the decode stack. On a
/// thread of the main thread's 8 MiB, the routed operations hop
/// (`onDecodeStack`), and what stays on the caller takes less than half of
/// it.
@Test func theScenePathsHoldTheDeepestScenesOnHalfOfEachStack() async throws {
    for chain in DeepChain.allCases {
        // Checks stay in the test's task: the threads return what they compare.
        let inLine = try await onThread(stack: measuringStack) { try scenePaths(chain) }
        for (path, bytes) in inLine.taken.sorted(by: { $0.key < $1.key }) {
            print("[#326 deep stack] \(deepestLevels) nested \(chain.rawValue), \(path): \(bytes / 1024) KiB of stack in line")
            #expect(bytes < SourceStudioCharacterBatch.stackSize / 2, "\(chain.rawValue), \(path): \(bytes) bytes")
        }
        // A decode stack no larger than the main thread's would run all of it
        // in line on the 8 MiB thread below, and overflow it.
        try #require(SourceStudioCharacterBatch.stackSize > mainThreadStack, "\(SourceStudioCharacterBatch.stackSize) bytes")
        let onMain = try await onThread(stack: mainThreadStack) { try scenePaths(chain) }
        for (path, bytes) in onMain.taken.sorted(by: { $0.key < $1.key }) {
            print("[#326 deep stack] \(deepestLevels) nested \(chain.rawValue), \(path): \(bytes / 1024) KiB on the caller's stack")
            #expect(bytes < mainThreadStack / 2, "\(chain.rawValue), \(path): \(bytes) bytes on the caller")
        }
        var expected = ["export (move)": deepestLevels, "export (delete)": chain == .folders ? deepestLevels - 1 : 0,
                        "insertion": deepestLevels + 1, "records": deepestLevels]
        if chain == .folders { expected["layout import"] = deepestLevels; expected["legacy upgrade"] = deepestLevels }
        #expect(inLine.counts == expected && onMain.counts == expected, "\(chain.rawValue)")
        let capRefusal = "limitExceeded(\"objects nested more than \(deepestLevels) levels deep (Ikkoku reads at most \(deepestLevels))\")"
        #expect(inLine.refusal == (chain == .folders ? capRefusal : nil) && onMain.refusal == inLine.refusal, "\(chain.rawValue)")
    }
}

/// The cost of the batch's own threads (#321) against the GCD workers they
/// replace: a full-width batch of first halves that fail at once (a missing
/// scene file). `create` is the batch's init on the calling thread (the
/// main thread in the Studio), `all` runs until every worker reported; the
/// same first halves on GCD workers are the baseline. Printed, not asserted.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device for the store"))
func theCharacterBatchThreadHopCostsMicroseconds() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let width = SourceStudioCharacterBatch.defaultWidth, rounds = 50
    let missing = SourceStudioCharacterReference(sceneFile: "/nonexistent/ikkoku-321/scene.png", sceneSHA256: "",
                                                 rigFile: "", boneCatalogFile: "", objectKey: 0)
    struct Times: Sendable { var create: [Double] = [], all: [Double] = [], gcdCreate: [Double] = [], gcdAll: [Double] = [], reported: [Int] = [] }
    let times = try await liveTickOffPool { () -> Times in
        let requests = Array(repeating: SourceStudioCharacterBatch.Request(reference: missing), count: width)
        let done = DispatchSemaphore(value: 0)
        var times = Times()
        func microseconds(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 }
        for _ in 0..<rounds {
            var start = DispatchTime.now().uptimeNanoseconds
            let batch = SourceStudioCharacterBatch(requests: requests, resources: resources, width: width,
                                                   assembled: { _ in done.signal() })
            times.create.append(microseconds(since: start))
            for _ in 0..<width { done.wait() }
            times.all.append(microseconds(since: start))
            times.reported.append(batch.assembledCount)
            start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<width {
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = try? SourceStudioCharacterPreview.assemble(reference: missing, resources: resources)
                    done.signal()
                }
            }
            times.gcdCreate.append(microseconds(since: start))
            for _ in 0..<width { done.wait() }
            times.gcdAll.append(microseconds(since: start))
        }
        return times
    }
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    print(String(format: "[#321 hop] width %d, %d rounds, medians: batch threads create %.0f µs, all %.0f µs; "
                 + "GCD workers create %.0f µs, all %.0f µs", width, rounds, median(times.create), median(times.all),
                 median(times.gcdCreate), median(times.gcdAll)))
    #expect(times.reported == Array(repeating: width, count: rounds))
}

// #326, the hidden characters' clock: `SourceStudioAnimationClock` reads its
// scene on GCD workers (its utility warm-up, an export's user-initiated
// worker), with 512 KiB of stack, so its read, decode and drop run on a
// thread of the batch's size (`SourceStudioCharacterBatch.onDecodeThread`).

/// Runs `body` on a thread of its own with a GCD worker's stack and `qos`,
/// as the clock's warm-up and an export's worker run.
private func onSmallThread<T: Sendable>(qos: QualityOfService, _ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: body()) }
        thread.stackSize = gcdWorkerStack
        thread.qualityOfService = qos
        thread.start()
    }
}

/// Under 1 MiB: a GCD worker's stack, or a thread given its 512 KiB (pthread
/// reports 524 KiB for both).
private func isSmallStack(_ bytes: Int) -> Bool { bytes < 1 << 20 }

/// A thread's stack, QoS and whether the decode's stack check passes there.
private struct DecodeThreadState: Sendable, Equatable {
    let stack: Int, qos: UInt32, checkPasses: Bool
    static var current: Self {
        let passes = (try? SourceStudioCharacterBatch.requireDecodeStack()) != nil
        return .init(stack: pthread_get_stacksize_np(pthread_self()), qos: qos_class_self().rawValue, checkPasses: passes)
    }
}

/// The decode thread has the batch's stack and its caller's QoS, here a
/// utility thread with a GCD worker's 512 KiB. In Debug the stack check
/// refuses the caller's thread and passes on the decode thread.
@Test func theDecodeThreadHasTheBatchStackAndItsCallersQoS() async {
    let (caller, decode) = await onSmallThread(qos: .utility) { () -> (DecodeThreadState, DecodeThreadState) in
        (.current, SourceStudioCharacterBatch.onDecodeThread("test") { .current })
    }
    let utility = QOS_CLASS_UTILITY.rawValue
    #if DEBUG
    let checkPasses = false
    #else
    let checkPasses = true
    #endif
    #expect(isSmallStack(caller.stack) && caller.qos == utility && caller.checkPasses == checkPasses, "\(caller)")
    #expect(decode.stack >= SourceStudioCharacterBatch.stackSize && decode.qos == utility && decode.checkPasses, "\(decode)")
}

/// The hand-off under repetition: 1,000 calls from a utility thread with a
/// GCD worker's stack. Each result comes from the decode thread (another
/// thread, with the batch's stack), and the body's last write is visible
/// when the call returns, so the caller never ran ahead of it. Also prints
/// the cost of a hop, the clock's added cost per scene file it reads.
@Test func theDecodeThreadHandOffNeverRunsAhead() async {
    let rounds = 1000
    let (failures, times) = await onSmallThread(qos: .utility) { () -> ([String], [Double]) in
        let caller = pthread_mach_thread_np(pthread_self())
        let finished = OSAllocatedUnfairLock(initialState: 0)
        var failures: [String] = [], times: [Double] = []
        for round in 1...rounds {
            let start = DispatchTime.now().uptimeNanoseconds
            let seen = SourceStudioCharacterBatch.onDecodeThread("test") { () -> (thread: UInt32, stack: Int) in
                let seen = (thread: pthread_mach_thread_np(pthread_self()), stack: pthread_get_stacksize_np(pthread_self()))
                finished.withLock { $0 = round }
                return seen
            }
            let done = finished.withLock { $0 }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
            if seen.thread == caller || seen.stack < SourceStudioCharacterBatch.stackSize || done != round {
                failures.append("round \(round): thread \(seen.thread), \(seen.stack) bytes, finished \(done)")
            }
        }
        return (failures, times)
    }
    #expect(failures.isEmpty, "\(failures.count) failures, first \(failures.prefix(3))")
    let sorted = times.sorted()
    print(String(format: "[#326 decode hop] %d calls from a utility thread: median %.0f µs, p95 %.0f µs",
                 rounds, sorted[rounds / 2], sorted[rounds * 95 / 100]))
}

private final class Handed: Sendable {}

/// The decode thread hands its result over and keeps none of it (#326):
/// once the caller drops what came back, it is gone, whether or not the
/// thread has ended. A decoded tree therefore dies where its caller drops
/// it (`theDeepestPreviewRecordHoldsNoSubtree`). The thread usually ends
/// first, so a hand-off that kept the result fails only some rounds.
@Test func theDecodeThreadKeepsNoReferenceToItsResult() {
    var kept = 0
    for _ in 0..<1000 {
        weak var handed: Handed?
        do {
            let value = SourceStudioCharacterBatch.onDecodeThread("Ikkoku test") { Handed() }
            handed = value
        }
        if handed != nil { kept += 1 }
    }
    #expect(kept == 0, "\(kept) of 1,000 results outlived their caller's reference")
}

/// The clock's warm-up (#326, P1) runs on a utility GCD worker and reads
/// its scene there; the read, the decode and the drop of the records run on
/// the decode thread instead (`readSeeds`). On the deepest character chain
/// the reader accepts, the root's and the deepest character's seeds load.
/// Without the hop, a Debug run refuses the decode (`requireDecodeStack`)
/// and the seeds are that error; a Release one would overflow the worker.
@Test func theClockWarmUpDecodesTheDeepestCharacterChainOnTheDecodeThread() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // Written, and decoded for the expected states, off the pool: both recurse.
    let (scene, expected) = try await liveTickOffPool { () -> (SourceStudioCharacterReference, [Int32: SourceStudioAnimationState]) in
        let data = deepScene(levels: deepestLevels, chain: .characters)
        var expected: [Int32: SourceStudioAnimationState] = [:]
        var level = try KoikatsuSceneReader.decodeDocument(data).snapshot.roots
        while let object = level.first, let character = object.character {
            expected[object.sourceKey] = SourceStudioAnimationState(record: character)
            level = character.accessoryChildren[0] ?? []
        }
        return (try deepReference(data, chain: .characters, in: folder), expected)
    }
    #expect(expected.count == deepestLevels)
    let keys: [Int32] = [0, Int32(deepestLevels - 1)]
    let references = keys.map {
        SourceStudioCharacterReference(sceneFile: scene.sceneFile, sceneSHA256: scene.sceneSHA256, rigFile: scene.rigFile,
                                       boneCatalogFile: scene.boneCatalogFile, objectKey: $0)
    }
    let clock = SourceStudioAnimationClock()
    let warmUp = await withCheckedContinuation { continuation in
        let requests = references.map { SourceStudioAnimationClock.Request(reference: $0, edited: nil, bodyValues: nil) }
        clock.beginWarmUp(requests, generation: clock.generation) { loaded in
            continuation.resume(returning: (loaded: loaded, stack: pthread_get_stacksize_np(pthread_self())))
        }
    }
    #expect(warmUp.loaded && isSmallStack(warmUp.stack), "\(warmUp)")
    for (key, reference) in zip(keys, references) {
        let seed = clock.cachedSeed(reference)
        #expect((try? seed?.get().saved) == expected[key], "\(key): \(String(describing: seed))")
    }
}

/// The hidden card check (#326, P3) keeps shallow copies of its records,
/// with no accessory children, and its worker's block captures no record:
/// a worker that drops the last reference releases no subtree. Here the
/// character's accessory child dies with the caller's records, before the
/// check is asked for its problems.
@Test func theHiddenCardCheckHoldsNoSceneSubtree() throws {
    weak var child: KoikatsuObjectRecord?
    var hadChild = false
    let check = try { () throws -> SourceStudioCharacterPreview.CardCheck in
        let document = try KoikatsuSceneReader.decodeDocument(deepScene(levels: 2, chain: .characters))
        let character = try #require(document.snapshot.roots.first?.character)
        child = character.accessoryChildren[0]?.first
        hadChild = child != nil
        return SourceStudioCharacterPreview.CardCheck(records: [character])
    }()
    #expect(hadChild && child == nil)
    #expect(check.records.count == 1 && check.records.allSatisfy { $0.accessoryChildren.isEmpty })
    #expect(check.problems().count == 1)
}

/// Each operation that walks a decoded tree recursively hops onto the decode
/// stack from any smaller one (`onDecodeStack`), on the deepest scenes: the
/// decode, the snapshot decode, the legacy upgrade, the insertion stage, the
/// export's move and deletion and the layout import, called from a thread
/// with the main thread's 8 MiB and from one with a GCD worker's 512 KiB.
/// The 8 MiB caller goes first: there an operation that does not hop fails
/// the Debug floor (`requireDecodeStack`) instead of overflowing. The
/// thread only calls them: it keeps every tree it touches, and the test
/// drops them on an 8 MiB thread (a 512 KiB stack cannot release the
/// deepest).
@Test func everyRoutedOperationRunsFromASmallerStack() async throws {
    let deepest = Int32(deepestLevels - 1)
    let kept = Kept()
    // Written and decoded off the pool: both recurse.
    try await liveTickOffPool {
        let folders = deepScene(levels: deepestLevels, chain: .folders)
        kept.keep("folders data", folders)
        kept.keep("characters data", deepScene(levels: deepestLevels, chain: .characters))
        kept.keep("folders", try KoikatsuSceneReader.decodeDocument(folders))
        kept.keep("characters", try KoikatsuSceneReader.decodeDocument(kept["characters data"]))
        kept.keep("legacy", try KoikatsuSceneReader.decodeDocument(deepLegacyFolders(levels: deepestLevels)))
    }
    let catalog = try JSONDecoder().decode(KoikatsuAssetCatalog.self, from: Data(#"{"version": 1, "items": []}"#.utf8))
    let moved = KoikatsuChangeAmount(position: SIMD3(1, 2, 3), rotationDegrees: .zero, scale: .one)
    for stack in [mainThreadStack, gcdWorkerStack] {
        let outcome = try await onThread(stack: stack) { () -> String in
            let folders: KoikatsuSceneDocument = kept["folders"], characters: KoikatsuSceneDocument = kept["characters"]
            let legacy: KoikatsuSceneDocument = kept["legacy"]
            // Keys of their own per caller: a replaced value would be released here.
            func keep(_ name: String, _ value: Any) { kept.keep("\(stack) \(name)", value) }
            do {
                keep("decoded", try KoikatsuSceneReader.decodeDocument(kept["characters data"]))
                keep("snapshot", try KoikatsuSceneReader.decode(kept["folders data"]))
                keep("upgraded", try legacy.upgraded())
                keep("staged", try folders.inserting([.init(.folder(name: "New"), parent: .source(deepest - 1))]))
                keep("moved", try characters.editedData(.init(transforms: [.init(.object(deepest), transform: moved)])))
                keep("deleted", try folders.editedData(.init(deletions: [deepest])))
                keep("imported", try KoikatsuLayoutImporter.convert(folders.snapshot, catalog: catalog,
                                                                    catalogDirectory: FileManager.default.temporaryDirectory))
                return "ran"
            } catch { return String(describing: error) }
        }
        #expect(outcome == "ran", "from \(stack / 1024) KiB")
        guard outcome == "ran" else { break }
        let levels = try await liveTickOffPool { () -> [String: Int] in
            func value<T>(_ name: String) -> T { kept["\(stack) \(name)"] }
            let decoded: KoikatsuSceneDocument = value("decoded"), snapshot: KoikatsuSceneSnapshot = value("snapshot")
            let upgraded: KoikatsuSceneDocument = value("upgraded"), staged: SourceSceneStage = value("staged")
            let imported: StudioDocument = value("imported"), moved: Data = value("moved"), deleted: Data = value("deleted")
            return ["decode": levelCount(decoded.snapshot.roots).levels, "snapshot": levelCount(snapshot.roots).levels,
                    "upgrade": upgraded.isLegacy ? 0 : levelCount(upgraded.snapshot.roots).levels,
                    "insertion": levelCount(staged.document.snapshot.roots).records,
                    "move": levelCount(try KoikatsuSceneReader.decodeDocument(moved).snapshot.roots).levels,
                    "deletion": levelCount(try KoikatsuSceneReader.decodeDocument(deleted).snapshot.roots).levels,
                    "layout import": imported.objects.count]
        }
        #expect(levels == ["decode": deepestLevels, "snapshot": deepestLevels, "upgrade": deepestLevels,
                           "insertion": deepestLevels + 1, "move": deepestLevels, "deletion": deepestLevels - 1,
                           "layout import": deepestLevels], "from \(stack / 1024) KiB")
    }
    try await liveTickOffPool { kept.dropAll() }
}

#if DEBUG
/// A record comparison recurses through both subtrees, so in Debug it is
/// caught on any stack smaller than the decode stack, here the main
/// thread's, and passes on the decode stack. A thread holding a
/// `ComparisonReport` counts it instead of stopping the process.
@Test func aRecordComparisonOffTheDecodeStackIsCaught() async throws {
    let data = deepScene(levels: 3, chain: .folders)
    let one = try KoikatsuSceneReader.decodeDocument(data), two = try KoikatsuSceneReader.decodeDocument(data)
    // Distinct objects with the same contents: `==` walks both.
    #expect(one.snapshot.roots[0] !== two.snapshot.roots[0])
    @Sendable func counted(_ compare: () -> Bool) -> (equal: Bool, caught: Int) {
        let report = SourceStudioCharacterBatch.ComparisonReport()
        Thread.current.threadDictionary[SourceStudioCharacterBatch.ComparisonReport.key] = report
        defer { Thread.current.threadDictionary.removeObject(forKey: SourceStudioCharacterBatch.ComparisonReport.key) }
        return (compare(), report.count)
    }
    let onMain = await MainActor.run { () -> (main: Bool, equal: Bool, caught: Int) in
        let result = counted { one.snapshot.roots == two.snapshot.roots }
        return (pthread_main_np() == 1, result.equal, result.caught)
    }
    #expect(onMain.main && onMain.equal && onMain.caught == 3, "\(onMain)")
    let onTheDecodeStack = try onDecodeStack { () -> [Int] in
        let result = counted { one.snapshot.roots == two.snapshot.roots }
        return [result.equal ? 1 : 0, result.caught]
    }
    #expect(onTheDecodeStack == [1, 0])
}
#endif

/// Runs `walk` where it all runs in line, measured, and then, when it took
/// less than `half`, for real on a thread of `half` bytes: a walk that needs
/// more fails the expectation instead of overflowing the thread. The walk is
/// iterative, so its stack does not grow with the depth: a recursion at the
/// cap took 0.6 MiB (Release) to 9.6 MiB (Debug).
private func onHalfItsStack<T: Sendable>(_ name: String, half: Int, _ walk: @escaping @Sendable () throws -> T) async throws -> T? {
    let taken = try await onThread(stack: measuringStack) { () -> Int in
        var result: T?
        let bytes = try stackTaken { result = try walk() }
        withExtendedLifetime(result) {}
        return bytes
    }
    print("[#326 deep stack] \(deepestLevels) levels, \(name): \(taken / 1024) KiB of stack")
    #expect(taken < 256 * 1024, "\(name): \(taken) bytes, as a recursion takes")
    #expect(taken < half, "\(name): \(taken) bytes")
    guard taken < half else { return nil }
    return try await onThread(stack: half) { try walk() }
}

/// The walks that stay on a caller's stack (#326), iterative, on half the
/// main thread's 8 MiB at the deepest scenes: the export's insertions (an
/// added chain of folders, parents first, in document order), the route
/// stepping (a route at the deepest level) and whether the tree holds a
/// character (one at the deepest level, and none).
@Test func theCallerWalksHoldTheDeepestScenesOnHalfTheMainThreadsStack() async throws {
    let half = mainThreadStack / 2
    var document = StudioDocument()
    var parent: UUID?, chain: [UUID] = []
    for index in 0..<deepestLevels {
        var object = StudioObject(name: "Added \(index)", kind: .folder)
        object.parent = parent; parent = object.id
        document.objects.append(object); chain.append(object.id)
    }
    let second = StudioObject(name: "Second", kind: .folder)
    document.objects.append(second)
    let added = document
    let insertions = try await onHalfItsStack("export insertions", half: half) { () -> [String] in
        let (insertions, objects) = try SourceSceneExportValidation.insertions(added)
        return zip(insertions, objects).map { "\($0.parent) \($1)" }
    }
    let expected = (0..<deepestLevels).map { "\($0 == 0 ? SourceSceneInsertion.Parent.root : .inserted($0 - 1)) \(chain[$0])" }
        + ["\(SourceSceneInsertion.Parent.root) \(second.id)"]
    #expect(insertions == expected)

    // Nested folders down to a route, or a character, at the deepest level.
    let deepest = Int32(deepestLevels - 1)
    let kept = Kept()
    try await liveTickOffPool {
        for (name, leaf) in [("route", TopologyNode.route(deepest, [])), ("character", .character(deepest, []))] {
            var node = leaf
            for key in stride(from: deepest - 1, through: 0, by: -1) { node = .folder(key, [node]) }
            var scene = TopologyScene(roots: [node])
            if name == "character" { scene.lookAt[deepest] = 1000 + deepest }
            kept.keep(name, try KoikatsuSceneReader.decode(scene.data))
        }
        kept.keep("folders", try KoikatsuSceneReader.decode(deepScene(levels: deepestLevels, chain: .folders)))
    }
    let routes = try await onHalfItsStack("route stepping", half: half) { () -> [Int32] in
        let scene: KoikatsuSceneSnapshot = kept["route"]
        return try SourceStudioRoutePlayback.steppedRoutes(in: scene, deltaTimes: [1 / 30]).map(\.sourceKey)
    }
    #expect(routes == [deepest])
    let characters = try await onHalfItsStack("contains a character", half: half) { () -> [Bool] in
        let character: KoikatsuSceneSnapshot = kept["character"], folders: KoikatsuSceneSnapshot = kept["folders"]
        return [character.containsCharacter, folders.containsCharacter]
    }
    #expect(characters == [true, false])
    try await liveTickOffPool { kept.dropAll() }
}

private final class WeakRecord: @unchecked Sendable { weak var value: KoikatsuObjectRecord? }

/// A preview's record is a shallow copy (#326): its assembly takes the
/// character record without its accessory children (`characterRecord`).
/// The deepest chain's first character, copied, holds none of the levels
/// below it: once the scene is dropped, the next level is gone while the
/// copy lives, so a preview dropped on the Studio's build queue (GCD)
/// releases no subtree.
@Test func theDeepestPreviewRecordHoldsNoSubtree() async throws {
    let kept = Kept(), child = WeakRecord()
    let held = try await liveTickOffPool { () -> (source: Int, copy: Int) in
        let scene = try KoikatsuSceneReader.decodeDocument(deepScene(levels: deepestLevels, chain: .characters))
        let source = scene.snapshot.roots.first?.character
        child.value = source?.accessoryChildren[0]?.first
        let copy = try SourceStudioCharacterPreview.characterRecord(0, in: scene)
        kept.keep("copy", copy)
        return (source?.accessoryChildren.count ?? 0, copy.accessoryChildren.count)
    }
    // The scene is gone (dropped on that 8 MiB thread); the copy is kept.
    #expect(held.source == 1 && held.copy == 0, "\(held)")
    #expect(child.value == nil, "the copy holds the next level")
    try await liveTickOffPool { kept.dropAll() }
}
