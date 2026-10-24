import Foundation
import Testing
import Character

/// The worker stops at a known point; no sleeps or asset timing decide a race.
private final class MakerPreparationBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var arrived = false, released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func waitOnWorker() {
        condition.lock()
        arrived = true; waiter?.resume(); waiter = nil
        while !released { condition.wait() }
        condition.unlock()
    }
    func arrival() async {
        await withCheckedContinuation { continuation in
            condition.lock(); defer { condition.unlock() }
            if arrived { continuation.resume() } else { waiter = continuation }
        }
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

@MainActor @Test func makerPreparationCancelsRunningCallerWithoutWaitingForDecoder() async throws {
    let queue = SourceMakerPreparationQueue<Int>(), barrier = MakerPreparationBarrier()
    defer { barrier.release() }
    let first = Task { try await queue.prepare { barrier.waitOnWorker(); return 1 } }
    await barrier.arrival()
    await Task.detached { first.cancel() }.value
    do { _ = try await first.value; Issue.record("Cancelled preparation returned a value") }
    catch { #expect(error is CancellationError) }
    #expect(queue.isRunning) // Decoder is still held, caller already resumed.
    barrier.release()
    #expect(try await queue.prepare { 2 } == 2)
}

@MainActor @Test func makerPreparationRunsOnlyNewestQueuedCandidate() async throws {
    let queue = SourceMakerPreparationQueue<Int>(), barrier = MakerPreparationBarrier()
    defer { barrier.release() }
    let first = Task { try await queue.prepare { barrier.waitOnWorker(); return 1 } }
    await barrier.arrival()
    let second = Task { try await queue.prepare { Issue.record("Superseded queued operation ran"); return 2 } }
    do { _ = try await first.value; Issue.record("Running caller was not superseded") }
    catch { #expect(error is CancellationError) }
    #expect(queue.isRunning && queue.hasPending)
    let third = Task { try await queue.prepare { 3 } }
    do { _ = try await second.value; Issue.record("Queued caller was not superseded") }
    catch { #expect(error is CancellationError) }
    #expect(queue.isRunning && queue.hasPending)
    barrier.release()
    #expect(try await third.value == 3)
    #expect(!queue.isRunning && !queue.hasPending)
}

@MainActor @Test func makerPreparationContextCancellationDropsQueuedInputAndPreservesErrors() async throws {
    enum Failure: Error { case fixture }
    let queue = SourceMakerPreparationQueue<Int>(), barrier = MakerPreparationBarrier()
    defer { barrier.release() }
    let first = Task { try await queue.prepare { barrier.waitOnWorker(); return 1 } }
    await barrier.arrival()
    let second = Task { try await queue.prepare { Issue.record("Cancelled queued operation ran"); return 2 } }
    _ = await first.result // The new queued request cancels the first caller.
    queue.cancel()
    do { _ = try await second.value; Issue.record("Context cancellation returned a value") }
    catch { #expect(error is CancellationError) }
    #expect(!queue.hasPending)
    barrier.release()
    do { _ = try await queue.prepare { throw Failure.fixture }; Issue.record("Worker error was lost") }
    catch { #expect(error is Failure) }
    #expect(try await queue.prepare { 4 } == 4)
}


@MainActor @Test func makerPreparationCancelledBeforeEntryDoesNotSupersedeCurrentWork() async throws {
    let queue = SourceMakerPreparationQueue<Int>(), barrier = MakerPreparationBarrier()
    defer { barrier.release() }
    let first = Task { try await queue.prepare { barrier.waitOnWorker(); return 1 } }
    await barrier.arrival()
    let cancelled = Task { @MainActor in try await queue.prepare { Issue.record("Pre-cancelled operation ran"); return 2 } }
    // This actor has not yielded, so the task cannot have entered prepare yet.
    cancelled.cancel()
    do { _ = try await cancelled.value; Issue.record("Pre-cancelled request returned a value") }
    catch { #expect(error is CancellationError) }
    #expect(queue.isRunning && !queue.hasPending)
    barrier.release()
    #expect(try await first.value == 1)
    await queue.drain()
    #expect(!queue.isRunning)
}
