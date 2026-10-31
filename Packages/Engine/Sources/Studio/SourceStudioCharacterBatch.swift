import Foundation
import Character
import Renderer

/// R7 phase 2 item 6 (S1): the source character builds of one Studio
/// operation (a scene import, an undo or redo rebuild, a duplicate).
///
/// The first half of every build (`SourceStudioCharacterPreview.assemble`:
/// file reads, the scene record, the converted Maker assembly with its rig
/// decodes, the contracts) starts at once on GCD worker threads, at most
/// `width` at a time, in request order. It registers nothing, so it may run
/// concurrently. Characters that read the same converted rig file share one
/// decode (`rigs`), and each first half starts every decode its card selects
/// at once (`SourceRigDecodeShare.prefetch`).
///
/// The owner runs the second half (`build(_:)`: the resource registration
/// and evaluation in `init(assembly:resources:)`) one request at a time, in
/// its original order, on a thread it chooses. Meshes then get the same
/// store IDs, in the same order, as a fully sequential build, and the
/// renderer's draw-order tie-breaks see no difference.
///
/// Cancellation (`cancel()`): queued assemblies never start, a running one
/// finishes and is dropped, and `build(_:)` throws `CancellationError`. An
/// assembly holds no store resource, so nothing needs releasing. A preview
/// the owner already built releases its meshes and buffers when the owner
/// drops it (`SourceRigPreview.deinit`).
///
/// GCD threads, not the Swift concurrency pool: the builds block on file
/// reads, on each other's rig decodes and on texture uploads, and blocking
/// work stays off the cooperative pool (`docs/reference/performance.md`,
/// the pool rule).
public final class SourceStudioCharacterBatch: @unchecked Sendable {
    public struct Request: Sendable {
        public let reference: SourceStudioCharacterReference
        public let coordinate: Int?
        /// A loaded preview's `donation` for this character, if any.
        public let donation: SourceStudioCharacterPreview.Donation?
        public init(reference: SourceStudioCharacterReference, coordinate: Int? = nil,
                    donation: SourceStudioCharacterPreview.Donation? = nil) {
            self.reference = reference; self.coordinate = coordinate; self.donation = donation
        }
    }

    public let requests: [Request]
    public let rigs: SourceRigDecodeShare
    private let resources: ResourceStore
    private let condition = NSCondition()
    // Guarded by `condition`.
    private var assemblies: [Result<SourceStudioCharacterPreview.Assembly, Error>?]
    private var next = 0
    private var cancelled = false
    private var finished = 0
    private var running = 0
    private let assembled: (@Sendable (Int) -> Void)?

    /// Starts every request's first half. `assembled` is called on a worker
    /// thread after each one finishes (successfully or not), with its index.
    public init(requests: [Request], resources: ResourceStore, rigs: SourceRigDecodeShare = .init(),
                width: Int = SourceStudioCharacterBatch.defaultWidth, qos: DispatchQoS.QoSClass = .userInitiated,
                assembled: (@Sendable (Int) -> Void)? = nil) {
        self.requests = requests
        self.resources = resources
        self.rigs = rigs
        self.assembled = assembled
        assemblies = Array(repeating: nil, count: requests.count)
        let workers = min(max(1, width), requests.count)
        for _ in 0..<workers {
            DispatchQueue.global(qos: qos).async { [self] in work() }
        }
    }

    /// The worker count: the performance cores less one for the main thread
    /// and the renderer, at least two.
    public static var defaultWidth: Int { max(2, ProcessInfo.processInfo.activeProcessorCount - 2) }

    public var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    /// First halves finished so far (successful or not).
    public var assembledCount: Int {
        condition.lock(); defer { condition.unlock() }
        return finished
    }

    /// First halves running now. After `cancel()` it only falls.
    public var runningCount: Int {
        condition.lock(); defer { condition.unlock() }
        return running
    }

    /// Stops the batch: no further first half starts, finished assemblies are
    /// dropped, and every waiting or later `build` throws `CancellationError`.
    public func cancel() {
        condition.lock()
        cancelled = true
        assemblies = assemblies.map { _ in nil }
        condition.broadcast()
        condition.unlock()
        rigs.stopPrefetching()
    }

    /// Waits for request `index`'s first half and returns it, or throws its
    /// error or `CancellationError`.
    public func assembly(_ index: Int) throws -> SourceStudioCharacterPreview.Assembly {
        condition.lock()
        while !cancelled, assemblies[index] == nil { condition.wait() }
        if cancelled { condition.unlock(); throw CancellationError() }
        let result = assemblies[index]!
        // The preview owns what it needs; the batch keeps no second reference.
        assemblies[index] = nil
        condition.unlock()
        return try result.get()
    }

    /// The second half of request `index` on the calling thread: registers
    /// its resources and returns the preview, or throws exactly what the full
    /// `SourceStudioCharacterPreview` init would have thrown.
    public func build(_ index: Int) throws -> SourceStudioCharacterPreview {
        let assembly = try assembly(index)
        if isCancelled { throw CancellationError() }
        return try SourceStudioCharacterPreview(assembly: assembly, resources: resources)
    }

    // MARK: Ordered runs off the main thread

    /// One step of an ordered run: request `index`'s second half, or the
    /// owner's work number `index` that must run on the main thread between
    /// them (an item load in the Studio import), all in the original order.
    public enum Step: Sendable, Equatable { case character(Int), main(Int) }

    /// A built preview crossing from the build queue to the main thread. The
    /// build queue drops its reference before delivery, so the main thread is
    /// its only owner from then on.
    public struct Delivery: @unchecked Sendable {
        public let index: Int
        public let result: Result<SourceStudioCharacterPreview, Error>
    }

    /// Runs `steps` in order on the serial `queue`: each character's second
    /// half on that queue, each `.main` step synchronously on the main queue.
    /// `built` receives every character's outcome on the main queue as soon
    /// as it is ready, and `finished` runs on the main queue after the last
    /// step. After `cancel()` no further step starts and neither callback
    /// runs again; a preview already built is dropped on the queue.
    ///
    /// The main thread must never wait on `queue` while a run is in flight:
    /// a `.main` step blocks the queue until the main queue runs it.
    public func run(_ steps: [Step], on queue: DispatchQueue,
                    main: @escaping @MainActor @Sendable (Int) -> Void,
                    built: @escaping @MainActor @Sendable (Delivery) -> Void,
                    finished: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [self] in
            for step in steps {
                if isCancelled { return }
                switch step {
                case .main(let index):
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated { if !self.isCancelled { main(index) } }
                    }
                case .character(let index):
                    let delivery = Delivery(index: index, result: Result { try build(index) })
                    if isCancelled { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { if !self.isCancelled { built(delivery) } }
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if !self.isCancelled { finished() } }
            }
        }
    }

    private func work() {
        while true {
            condition.lock()
            guard !cancelled, next < requests.count else { condition.unlock(); return }
            let index = next
            next += 1
            running += 1
            condition.unlock()
            let request = requests[index]
            let result = Result {
                try SourceStudioCharacterPreview.assemble(reference: request.reference, resources: resources,
                    coordinate: request.coordinate, sharing: request.donation, rigs: rigs)
            }
            condition.lock()
            finished += 1
            running -= 1
            if !cancelled { assemblies[index] = result }
            condition.broadcast()
            condition.unlock()
            assembled?(index)
        }
    }
}
