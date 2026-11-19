import Foundation
import os
import Character
import Renderer
import Scene

/// R7 phase 2 item 6 (S1): the source character builds of one Studio
/// operation (a scene import, an undo or redo rebuild, a duplicate).
///
/// The first half of every build (`SourceStudioCharacterPreview.assemble`:
/// file reads, the scene record, the converted Maker assembly with its rig
/// decodes, the contracts) starts at once on worker threads of the batch's
/// own, at most `width` at a time, in request order. It registers nothing,
/// so it may run concurrently. Characters that read the same converted rig file share one
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
/// Threads of its own, not the Swift concurrency pool: the builds block on
/// file reads, on each other's rig decodes and on texture uploads, and
/// blocking work stays off the cooperative pool (`docs/reference/performance.md`,
/// the pool rule). Not GCD workers either (#321): `assemble` decodes the whole
/// scene, and the decode recurses once per nesting level, up to the reader's
/// `KoikatsuBinaryReader.maximumLevels` (#326). In Debug, a first half
/// takes 7.6 KiB of stack a level through nested folders and 17 KiB through
/// nested characters, many times a GCD worker's 512 KiB on the deepest
/// scenes (`SourceSceneDeepStackTests`). The workers get `stackSize`, the
/// stack every scene decode runs on (`onDecodeStack`, #326).
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
        guard workers > 0 else { return }
        // The calling thread (the main thread in the Studio) starts one
        // worker, which starts the others: the init then takes about 25 µs
        // for 22 workers, against 12 µs for 22 GCD dispatches (Release).
        Self.startWorker(1, of: workers, qos: qos) { [self] in
            for index in stride(from: 2, through: workers, by: 1) {
                Self.startWorker(index, of: workers, qos: qos) { [self] in work() }
            }
            work()
        }
    }

    /// Each worker's stack, and every scene decode's (#321, #326): 64 MiB,
    /// against a GCD worker's 512 KiB and the main thread's 8 MiB. It is
    /// address space: a page is committed only when the stack reaches it.
    /// The deepest walk it serves, a decode of `maximumLevels` nested
    /// characters, takes 17 KiB a level in Debug and 3 KiB in Release
    /// (`SourceSceneDeepStackTests`), so half of it holds 1,000 levels.
    public static let stackSize = 64 << 20

    private static func startWorker(_ index: Int, of count: Int, qos: DispatchQoS.QoSClass,
                                    _ body: @escaping @Sendable () -> Void) {
        startThread("Ikkoku character assembly \(index) of \(count)", qos: QualityOfService(qos), body)
    }

    /// Starts `body` on a thread of its own with `stackSize`.
    private static func startThread(_ name: String, qos: QualityOfService, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.stackSize = stackSize
        thread.qualityOfService = qos
        thread.name = name
        thread.start()
    }

    /// #326: runs `body` on a thread of its own with `stackSize`, at the
    /// calling thread's QoS, and returns its result: `onDecodeStack`'s hop,
    /// and the hidden characters' clock (`SourceStudioAnimationClock.readSeeds`),
    /// which reads its scene on its utility warm-up and on an export's GCD
    /// worker and drops the tree there too. One thread per call
    /// (`theDecodeThreadHandOffNeverRunsAhead` prints the cost).
    ///
    /// The hand-off: the thread takes `gate` and only then signals
    /// `started`. The caller waits on `started` (the thread's start, a few
    /// microseconds), then blocks on `gate` until `body` has returned, so it
    /// can never take `gate` first and read no result. The result leaves
    /// the thread before `gate` opens, and the caller takes it out of its
    /// box: the caller then holds its only reference, so a decoded tree
    /// dies where the caller drops it, not whenever this thread ends (#326).
    ///
    /// Why a lock and not a semaphore: priority inversion. A main-thread save
    /// or clock rebase (`SourceStudioAnimationClock.savedStates`) blocks on
    /// the clock's unfair lock, which the utility warm-up holds while it
    /// loads; the warm-up blocks here, on `gate`, which this thread holds.
    /// An unfair lock passes a waiter's priority to its owner, so the
    /// main thread's priority reaches the warm-up and, through `gate`, this
    /// decode. A semaphore has no owner: the chain would stop at the warm-up
    /// and the main thread would wait on a utility-QoS decode.
    static func onDecodeThread<T: Sendable>(_ name: String, _ body: @escaping @Sendable () -> T) -> T {
        let gate = OSAllocatedUnfairLock(), started = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<T?>(initialState: nil)
        let qos = DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .default
        startThread(name, qos: QualityOfService(qos)) {
            gate.lock()
            started.signal()
            do {
                let value = body()
                result.withLock { $0 = value }
            }
            gate.unlock()
        }
        started.wait()
        gate.lock(); gate.unlock()
        return result.withLock { value -> T? in
            defer { value = nil }
            return value
        }!
    }

    /// #326: runs `body` on a stack of at least `stackSize`: in line on a
    /// thread that has it (the batch's workers, a decode thread), otherwise
    /// on a thread of its own (`onDecodeThread`, one hop of 32–41 µs in
    /// Release). Each operation that walks a decoded scene's tree
    /// recursively wraps itself in it: the decode (`KoikatsuSceneReader`),
    /// the legacy upgrade, the insertion stage, the export's edit and the
    /// layout import. A nested one runs in line.
    static func onDecodeStack<T: Sendable>(_ name: String, _ body: @escaping @Sendable () throws -> T) throws -> T {
        if pthread_get_stacksize_np(pthread_self()) >= stackSize {
            try requireDecodeStack()
            return try body()
        }
        return try onDecodeThread(name) { Result { try requireDecodeStack(); return try body() } }.get()
    }

    /// #326, Debug: throws unless the calling thread has at least
    /// `stackSize` of stack, so a scene walk that would run on a smaller
    /// stack (a GCD worker's 512 KiB, the main thread's 8 MiB) fails with
    /// this error instead of overflowing it. `onDecodeStack` checks it before
    /// its body, the clock's read (`SourceStudioAnimationClock.readScene`)
    /// before its decode, and the reader before each root object
    /// (`KoikatsuBinaryReader.object`), so a root read outside a routed
    /// operation fails a Debug test. Nothing in Release.
    static func requireDecodeStack() throws {
        #if DEBUG
        let size = pthread_get_stacksize_np(pthread_self())
        guard size >= stackSize else {
            throw RigError.invalid("A scene decode ran on a \(size / 1024) KiB stack, not \(stackSize / 1024) KiB (#326).")
        }
        #endif
    }

    #if DEBUG
    /// #326, Debug: `KoikatsuObjectRecord.==` recurses through the whole
    /// subtree, so it runs on the decode stack too (the legacy upgrade's
    /// read-back and the insertion stage's check, both in `onDecodeStack`).
    /// `==` cannot throw: on a smaller stack it stops the process, unless the
    /// calling thread holds a `ComparisonReport` (tests only), which counts
    /// the comparison instead.
    static func checkComparisonStack() {
        let size = pthread_get_stacksize_np(pthread_self())
        guard size < stackSize else { return }
        if let report = Thread.current.threadDictionary[ComparisonReport.key] as? ComparisonReport { report.count += 1; return }
        preconditionFailure("A scene record comparison ran on a \(size / 1024) KiB stack, not \(stackSize / 1024) KiB (#326).")
    }

    /// Tests only: installed in a thread's dictionary, it counts the record
    /// comparisons made on that thread below `stackSize`.
    final class ComparisonReport: NSObject {
        static let key = "com.grabbiel.Ikkoku.326.comparisonReport"
        var count = 0
    }
    #endif

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

private extension QualityOfService {
    /// The thread QoS of a GCD QoS class, as the global queue of that class runs it.
    init(_ qos: DispatchQoS.QoSClass) {
        switch qos {
        case .userInteractive: self = .userInteractive
        case .userInitiated: self = .userInitiated
        case .utility: self = .utility
        case .background: self = .background
        case .default, .unspecified: self = .default
        @unknown default: self = .default
        }
    }
}
