import Foundation

public struct SourceMakerPreparationQueueTiming: Sendable, Encodable {
    /// Pending slot plus serial dispatch before the operation starts.
    public let residenceMilliseconds: Double
    /// Synchronous closure execution (including any caller-provided hook).
    public let operationMilliseconds: Double
    /// Worker completion to entry on MainActor, before continuation resumption.
    public let deliveryMilliseconds: Double
}

/// CPU-only Maker assembly work. One operation runs on a dedicated serial queue;
/// only the newest waiting operation is retained. Cancellation resumes callers
/// promptly, but cannot interrupt a synchronous decoder already running. Its
/// discarded result never reaches the caller or allocates preview resources.
@MainActor
public final class SourceMakerPreparationQueue<Value: Sendable> {
    public struct MeasuredValue: Sendable {
        public let value: Value, timing: SourceMakerPreparationQueueTiming
    }
    private struct Completion: Sendable {
        let value: Value, timing: SourceMakerPreparationQueueTiming?
    }
    private struct WorkerTiming: Sendable {
        let enqueued: TimeInterval, started: TimeInterval, ended: TimeInterval
    }
    private struct Request {
        let id: UUID
        let operation: @Sendable () throws -> Value
        let enqueued: TimeInterval?
        var continuation: CheckedContinuation<Completion, any Error>?
    }
    private let queue = DispatchQueue(label: "ikkoku.maker-preparation", qos: .userInitiated)
    private var running: Request?
    private var pending: Request?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isRunning: Bool { running != nil }
    public var hasPending: Bool { pending != nil }

    /// Waits for discarded CPU work too, without blocking the caller's thread.
    public func drain() async {
        if running == nil { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public func prepare(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await enqueue(operation, measured: false).value
    }

    /// Only successful, still-current work returns a sample. Cancellation and
    /// failure preserve their original errors; discarded work publishes nothing.
    public func prepareWithTiming(_ operation: @escaping @Sendable () throws -> Value) async throws -> MeasuredValue {
        let result = try await enqueue(operation, measured: true)
        guard let timing = result.timing else { preconditionFailure("Measured preparation lost its timestamps.") }
        return MeasuredValue(value: result.value, timing: timing)
    }

    private func enqueue(_ operation: @escaping @Sendable () throws -> Value, measured: Bool) async throws -> Completion {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                cancel()
                let request = Request(id: id, operation: operation,
                    enqueued: measured ? ProcessInfo.processInfo.systemUptime : nil, continuation: continuation)
                if running == nil { start(request) } else { pending = request }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    /// Cancels both callers and drops queued input. A running decode retains its
    /// slot until it finishes, bounding simultaneous memory and CPU work.
    public func cancel() {
        running?.continuation?.resume(throwing: CancellationError())
        running?.continuation = nil
        pending?.continuation?.resume(throwing: CancellationError())
        pending = nil
    }

    private func cancel(id: UUID) {
        if running?.id == id {
            running?.continuation?.resume(throwing: CancellationError())
            running?.continuation = nil
        }
        if pending?.id == id {
            pending?.continuation?.resume(throwing: CancellationError())
            pending = nil
        }
    }

    private func start(_ request: Request) {
        running = request
        let operation = request.operation, id = request.id, enqueued = request.enqueued
        queue.async { [weak self] in
            let started = enqueued.map { (enqueued: $0, started: ProcessInfo.processInfo.systemUptime) }
            let result = Result { try operation() }
            let timing = started.map { WorkerTiming(enqueued: $0.enqueued, started: $0.started, ended: ProcessInfo.processInfo.systemUptime) }
            Task { @MainActor [weak self] in self?.finished(id: id, result: result, timing: timing) }
        }
    }

    private func finished(id: UUID, result: Result<Value, any Error>, timing: WorkerTiming?) {
        guard running?.id == id else { return }
        let sample = timing.map { SourceMakerPreparationQueueTiming(residenceMilliseconds: ($0.started - $0.enqueued) * 1000,
            operationMilliseconds: ($0.ended - $0.started) * 1000,
            deliveryMilliseconds: (ProcessInfo.processInfo.systemUptime - $0.ended) * 1000) }
        let continuation = running?.continuation
        running = nil
        if let next = pending { pending = nil; start(next) }
        continuation?.resume(with: result.map { Completion(value: $0, timing: sample) })
        if running == nil {
            let waiters = idleWaiters; idleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
}
