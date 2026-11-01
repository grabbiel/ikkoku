import Foundation
import CryptoKit
import Darwin
import Metal
import Testing
import Renderer
@testable import Studio

// #321: a scene decode (`KoikatsuSceneReader.decodeDocument`) recurses once
// per nesting level, and the reader accepts at most 65 levels
// (`KoikatsuBinaryReader.object`, depth 0...64). A Debug decode of the
// 65-level installed scene needs 448 to 512 KiB of stack, a GCD worker's
// whole stack, and the Studio's character builds decoded their scene on GCD
// workers (`SourceStudioCharacterPreview.assemble`). The batch's workers now
// have the main thread's 8 MiB (`SourceStudioCharacterBatch.stackSize`).
//
// The scenes here are synthetic, written by `TopologyScene`, never a user
// scene: 65 nested folders, and 65 characters each held by the previous
// one's accessory point (a character level adds `character(depth:)`'s
// frame). Writing and releasing them recurse too, so the tests do both on a
// thread of their own with 8 MiB (`liveTickOffPool`), never on the Swift
// concurrency pool's 512 KiB.

/// The deepest scene the reader accepts.
private let deepestLevels = 65
private let gcdWorkerStack = 512 * 1024

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

@Test func theReaderRefusesAScenePast65Levels() async throws {
    let (deepest, refusal) = try await liveTickOffPool { () -> (Int, String) in
        var depth = 0, level = try KoikatsuSceneReader.decodeDocument(deepScene(levels: deepestLevels, chain: .folders)).snapshot.roots
        while let object = level.first { depth += 1; level = object.children }
        do { _ = try KoikatsuSceneReader.decodeDocument(deepScene(levels: deepestLevels + 1, chain: .folders)); return (depth, "decoded") }
        catch { return (depth, String(describing: error)) }
    }
    #expect(deepest == deepestLevels)
    #expect(refusal == #"limitExceeded("hierarchy depth exceeds 64")"#)
}

/// The negative control: the stack the first half takes on the deepest
/// scenes the reader accepts, measured on an 8 MiB thread, against a GCD
/// worker's 512 KiB. Release takes far less, so only Debug is held to it.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device for the store"))
func theDeepestScenesFirstHalfNeedsMoreThanAGCDWorkersStack() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var taken: [DeepChain: (decode: Int, firstHalf: Int, outcome: String)] = [:]
    for chain in DeepChain.allCases {
        taken[chain] = try await liveTickOffPool { () -> (decode: Int, firstHalf: Int, outcome: String) in
            let data = deepScene(levels: deepestLevels, chain: chain)
            let reference = try deepReference(data, chain: chain, in: folder)
            let decode = try stackTaken { _ = try KoikatsuSceneReader.decodeDocument(data) }
            var outcome = "assembled"
            let firstHalf = stackTaken {
                do { _ = try SourceStudioCharacterPreview.assemble(reference: reference, resources: resources) }
                catch { outcome = String(describing: error) }
            }
            return (decode, firstHalf, outcome)
        }
        let measured = try #require(taken[chain])
        print("[#321 deep stack] \(deepestLevels) nested \(chain.rawValue): the decode took \(measured.decode / 1024) KiB of stack, "
              + "the first half \(measured.firstHalf / 1024) KiB")
        #expect(measured.outcome == "Source character record is missing.", "\(chain.rawValue)")
        // The batch's workers hold it with room to spare.
        #expect(measured.firstHalf < SourceStudioCharacterBatch.stackSize / 4, "\(chain.rawValue): \(measured.firstHalf) bytes")
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
