import Foundation

/// CPU-only Maker assembly work. One operation runs on a dedicated serial queue;
/// only the newest waiting operation is retained. Cancellation resumes callers
/// promptly, but cannot interrupt a synchronous decoder already running. Its
/// discarded result never reaches the caller or allocates preview resources.
@MainActor
public final class SourceMakerPreparationQueue<Value: Sendable> {
    private struct Request {
        let id: UUID
        let operation: @Sendable () throws -> Value
        var continuation: CheckedContinuation<Value, any Error>?
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
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                cancel()
                let request = Request(id: id, operation: operation, continuation: continuation)
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
        let operation = request.operation, id = request.id
        queue.async { [weak self] in
            let result = Result { try operation() }
            Task { @MainActor [weak self] in self?.finished(id: id, result: result) }
        }
    }

    private func finished(id: UUID, result: Result<Value, any Error>) {
        guard running?.id == id else { return }
        let continuation = running?.continuation
        running = nil
        if let next = pending { pending = nil; start(next) }
        continuation?.resume(with: result)
        if running == nil {
            let waiters = idleWaiters; idleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
}
