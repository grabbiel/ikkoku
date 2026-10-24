import Foundation
import Metal

/// A 256-byte aligned range written by `FrameRing.allocate`. Bind `buffer` at `offset`.
/// The bytes stay valid until the command buffer passed to `FrameRing.endFrame` completes.
public struct FrameAllocation {
    public let buffer: any MTLBuffer
    public let offset: Int
}

/// Recoverable `FrameRing` failures. None of them terminates the process.
public enum FrameRingError: Error, Equatable, CustomStringConvertible {
    /// `allocate` ran outside `beginFrame` … `endFrame`/`abandonFrame`.
    case noOpenFrame
    /// A negative request, or one too large to align.
    case invalidByteCount(Int)
    /// The request did not fit the frame's region and the device refused an
    /// overflow buffer of `bytes` (or `bytes` exceeds `maxBufferLength`).
    case allocationFailed(bytes: Int)

    public var description: String {
        switch self {
        case .noOpenFrame: return "Frame uniform allocation outside an open frame."
        case let .invalidByteCount(count): return "Frame uniform allocation of \(count) bytes is invalid."
        case let .allocationFailed(bytes): return "Could not allocate a \(bytes)-byte frame uniform overflow buffer."
        }
    }
}

/// Per-frame uniform storage: `regionCount` fixed regions of one shared buffer,
/// plus overflow buffers for whatever a frame cannot fit in its region.
///
/// Lifetime contract. `beginFrame` opens a frame and `allocate` writes into it.
/// Exactly one call closes it: `endFrame(retainedUntilCompletionOf:)`, immediately
/// before that command buffer is committed, or `abandonFrame()` when nothing that
/// references the frame will be committed.
///
/// A region is reused only after every command buffer ended with it has completed.
/// Frame indices therefore choose a *preferred* region; a frame whose preferred
/// region is still in flight takes another free one, and when every region is in
/// flight it places all of its data in overflow buffers. This holds whatever order
/// concurrent callers commit in, so the frame-slot semaphore is not relied on for
/// uniform-data safety.
///
/// An allocation that does not fit the region goes to an overflow buffer of at
/// least `overflowChunkSize` bytes. Overflow buffers return to a small pool only
/// when their command buffer completes (immediately on abandon), so recycled
/// storage is never still being read by the GPU. Growth fails only when Metal
/// refuses the buffer, as `FrameRingError.allocationFailed`.
///
/// Skin palettes (G4). `allocatePalettes` places a frame's palettes in its
/// region's palette buffer, one growable shared buffer per region. The buffer
/// follows the region's in-flight rule above, so it is rewritten only after
/// every command buffer that read it has completed. When a frame needs more
/// than the buffer holds, the region gets a new buffer of twice the size (at
/// least `minimumPaletteCapacity`, doubled until it fits); the old one stays
/// alive for the command buffers and allocations that still reference it.
/// After the largest frame has been seen, palettes cost no allocation. A
/// frame without a region (every region in flight) places its palettes in
/// overflow buffers like any other allocation.
///
/// Callers serialize one open frame at a time (`Renderer` holds its render lock).
/// Completion handlers run on Metal threads and only touch lock-protected state.
///
/// Sendable invariant: the open-frame state (`isOpen`, `region`, the cursors,
/// `overflow`, `frameStatistics` and `paletteBuffers`) is only touched by the
/// one caller that holds the open frame, which the caller serializes; a
/// region's palette buffer is only written while that region is the open
/// frame's region, which is never in flight. Everything a completion handler
/// touches (`inFlight`, `pool` and the creation counters) is behind `lock`.
public final class FrameRing: @unchecked Sendable {
    public static let alignment = 256
    public static let defaultRegionSize = 8 * 1024 * 1024
    /// Smallest palette buffer a region creates; growth doubles from here.
    public static let minimumPaletteCapacity = 64 * 1024

    /// Where the open (or last closed) frame's bytes went.
    public struct Statistics: Sendable, Equatable {
        /// Ring region of the frame; nil when every region was still in flight.
        public var region: Int?
        /// Aligned bytes placed in the region.
        public var regionBytes = 0
        /// Aligned bytes placed in overflow buffers.
        public var overflowBytes = 0
        /// Overflow buffers the frame used (fresh or recycled).
        public var overflowBuffers = 0
        /// Aligned bytes of skin palettes placed in the region's palette buffer.
        public var paletteBytes = 0
        /// Palette buffers created for this frame: nonzero only while a
        /// region's palette buffer grows to the largest frame so far.
        public var paletteBuffersCreated = 0
        public init() {}
    }

    public let buffer: any MTLBuffer
    public let regionSize: Int
    public let regionCount: Int
    public let overflowChunkSize: Int
    private let device: any MTLDevice
    private let maxPooledOverflowBuffers: Int

    // Open-frame state, serialized by the caller.
    private var isOpen = false
    private var region: Int?
    private var cursor = 0
    private var overflow: [any MTLBuffer] = []
    private var overflowCursor = 0
    private var paletteCursor = 0
    /// One palette buffer per region, created on first use.
    private var paletteBuffers: [(any MTLBuffer)?]
    public private(set) var frameStatistics = Statistics()

    // Shared with completion handlers.
    private let lock = NSLock()
    private var inFlight: [Int]
    private var pool: [any MTLBuffer] = []
    private var createdOverflowBuffers = 0
    private var createdPaletteBuffers = 0

    public init?(device: any MTLDevice,
                 regionSize: Int = FrameRing.defaultRegionSize,
                 regionCount: Int = GPUContext.maxFramesInFlight,
                 overflowChunkSize: Int? = nil) {
        guard regionSize > 0, regionCount > 0, regionSize <= Int.max - FrameRing.alignment else { return nil }
        let aligned = FrameRing.align(regionSize)
        let (length, overflowed) = aligned.multipliedReportingOverflow(by: regionCount)
        guard !overflowed, let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        buffer.label = "FrameRing"
        self.buffer = buffer
        self.device = device
        self.regionSize = aligned
        self.regionCount = regionCount
        self.overflowChunkSize = FrameRing.align(min(max(overflowChunkSize ?? aligned, 1), Int.max - FrameRing.alignment))
        self.maxPooledOverflowBuffers = 2 * regionCount
        self.inFlight = Array(repeating: 0, count: regionCount)
        self.paletteBuffers = Array(repeating: nil, count: regionCount)
    }

    /// Opens a frame. Call once per frame, before any allocation.
    /// A frame left open by the previous call is dropped as if abandoned, except
    /// that its overflow buffers are not recycled (they may have been submitted).
    public func beginFrame(_ frameIndex: Int) {
        overflow = []
        let preferred = ((frameIndex % regionCount) + regionCount) % regionCount
        var chosen: Int?
        lock.lock()
        for step in 0..<regionCount where inFlight[(preferred + step) % regionCount] == 0 {
            chosen = (preferred + step) % regionCount
            break
        }
        lock.unlock()
        region = chosen
        cursor = 0
        overflowCursor = 0
        paletteCursor = 0
        frameStatistics = Statistics()
        frameStatistics.region = chosen
        isOpen = true
    }

    /// Bytes the open frame has placed so far (region plus overflow).
    public var bytesUsed: Int { frameStatistics.regionBytes + frameStatistics.overflowBytes }

    /// Copies `value` into the open frame.
    public func allocate<T>(_ value: T) throws -> FrameAllocation {
        let target = try allocate(byteCount: MemoryLayout<T>.stride)
        target.buffer.contents().storeBytes(of: value, toByteOffset: target.offset, as: T.self)
        return target
    }

    /// Copies an array into the open frame. The allocation addresses element 0.
    ///
    /// The copy deliberately avoids a `withUnsafeBytes` closure. With Xcode 27.0
    /// (Swift 6.4) in Release, that closure overwrote the Swift error register
    /// with `MTLBuffer.contents()` before tail-calling memmove. `withUnsafeBytes`
    /// then returned that pointer as a thrown error. This function did not check
    /// the register after a call that cannot throw, so it passed the pointer to
    /// its caller. `Renderer.prepare` crashed retaining it on the first skinned
    /// frame (R6; docs/reference/renderer.md#renderer-limits-and-resource-lifetime-r6-first-slice).
    public func allocate<T>(array: [T]) throws -> FrameAllocation {
        let byteCount = MemoryLayout<T>.stride * array.count
        let target = try allocate(byteCount: max(byteCount, 1))
        if byteCount > 0 {
            FrameRing.copy(array, byteCount: byteCount, to: target.buffer.contents().advanced(by: target.offset))
        }
        return target
    }

    /// `elements` is the array's own storage for the duration of the call
    /// (implicit array-to-pointer argument conversion).
    private static func copy<T>(_ elements: UnsafePointer<T>, byteCount: Int, to destination: UnsafeMutableRawPointer) {
        destination.copyMemory(from: elements, byteCount: byteCount)
    }

    /// Copies each palette into the open frame (see "Skin palettes" above) and
    /// returns their allocations in the same order. Each allocation addresses
    /// its palette's element 0 at a 256-byte aligned offset; an empty palette
    /// takes one aligned slot. Throws `FrameRingError.allocationFailed` when
    /// Metal refuses a grown buffer; earlier allocations stay valid.
    public func allocatePalettes<T>(_ palettes: [[T]]) throws -> [FrameAllocation] {
        guard isOpen else { throw FrameRingError.noOpenFrame }
        guard let region else { return try palettes.map { try allocate(array: $0) } }
        var total = 0
        for palette in palettes {
            let (bytes, overflowed) = MemoryLayout<T>.stride.multipliedReportingOverflow(by: palette.count)
            guard !overflowed, bytes <= Int.max - FrameRing.alignment else { throw FrameRingError.invalidByteCount(bytes) }
            let (sum, sumOverflowed) = total.addingReportingOverflow(FrameRing.align(max(bytes, 1)))
            guard !sumOverflowed, sum <= Int.max - FrameRing.alignment else { throw FrameRingError.invalidByteCount(sum) }
            total = sum
        }
        var buffer = paletteBuffers[region]
        if buffer == nil || total > buffer!.length - paletteCursor {
            // Earlier palettes of this frame keep the buffer they were written to.
            buffer = try grownPaletteBuffer(from: buffer?.length ?? 0, minimumLength: total, region: region)
            paletteBuffers[region] = buffer
            paletteCursor = 0
        }
        let target = buffer!
        var allocations: [FrameAllocation] = []
        allocations.reserveCapacity(palettes.count)
        for palette in palettes {
            let bytes = MemoryLayout<T>.stride * palette.count
            if bytes > 0 { FrameRing.copy(palette, byteCount: bytes, to: target.contents().advanced(by: paletteCursor)) }
            allocations.append(FrameAllocation(buffer: target, offset: paletteCursor))
            paletteCursor += FrameRing.align(max(bytes, 1))
        }
        frameStatistics.paletteBytes += total
        return allocations
    }

    /// Palette buffers created over the ring's lifetime.
    public var paletteBuffersCreated: Int { lock.lock(); defer { lock.unlock() }; return createdPaletteBuffers }

    /// A new palette buffer for `region`: twice `length` (at least
    /// `minimumPaletteCapacity`), doubled until `minimumLength` fits, capped at
    /// the device's largest buffer.
    private func grownPaletteBuffer(from length: Int, minimumLength: Int, region: Int) throws -> any MTLBuffer {
        func doubled(_ value: Int) -> Int { value > Int.max / 2 ? Int.max : value * 2 }
        var capacity = max(FrameRing.minimumPaletteCapacity, doubled(length))
        while capacity < minimumLength { capacity = doubled(capacity) }
        capacity = min(capacity, device.maxBufferLength)
        guard capacity >= minimumLength, let created = device.makeBuffer(length: capacity, options: .storageModeShared) else {
            throw FrameRingError.allocationFailed(bytes: max(capacity, minimumLength))
        }
        created.label = "FrameRing palettes \(region)"
        lock.lock(); createdPaletteBuffers += 1; lock.unlock()
        frameStatistics.paletteBuffersCreated += 1
        return created
    }

    /// Reserves `byteCount` uninitialized bytes in the open frame.
    public func allocate(byteCount: Int) throws -> FrameAllocation {
        guard isOpen else { throw FrameRingError.noOpenFrame }
        guard byteCount >= 0, byteCount <= Int.max - FrameRing.alignment else { throw FrameRingError.invalidByteCount(byteCount) }
        // A zero-byte request still occupies a slot, so every offset is inside its buffer.
        let size = max(byteCount, 1)
        let aligned = FrameRing.align(size)
        if let region, size <= regionSize - cursor {
            let offset = region * regionSize + cursor
            cursor += aligned
            frameStatistics.regionBytes = min(cursor, regionSize)
            return FrameAllocation(buffer: buffer, offset: offset)
        }
        if let current = overflow.last, size <= current.length - overflowCursor {
            let offset = overflowCursor
            overflowCursor += aligned
            frameStatistics.overflowBytes += aligned
            return FrameAllocation(buffer: current, offset: offset)
        }
        let added = try overflowBuffer(minimumLength: aligned)
        overflow.append(added)
        overflowCursor = aligned
        frameStatistics.overflowBytes += aligned
        frameStatistics.overflowBuffers = overflow.count
        return FrameAllocation(buffer: added, offset: 0)
    }

    /// Closes the frame and keeps its region and overflow buffers out of reuse
    /// until `commandBuffer` completes. Call before committing it.
    public func endFrame(retainedUntilCompletionOf commandBuffer: any MTLCommandBuffer) {
        guard isOpen else { return }
        isOpen = false
        let lease = Lease(region: region, overflow: overflow)
        overflow = []
        if let region {
            lock.lock(); inFlight[region] += 1; lock.unlock()
        }
        commandBuffer.addCompletedHandler { [self] _ in self.retire(lease) }
    }

    /// Closes a frame that will not be submitted. Its region stays free and its
    /// overflow buffers are recycled at once.
    public func abandonFrame() {
        guard isOpen else { return }
        isOpen = false
        lock.lock(); recycleLocked(overflow); lock.unlock()
        overflow = []
    }

    /// True while a submitted command buffer may still read `region`.
    public func isRegionInFlight(_ region: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.indices.contains(region) && inFlight[region] > 0
    }

    /// Overflow buffers created over the ring's lifetime (recycled ones count once).
    public var overflowBuffersCreated: Int { lock.lock(); defer { lock.unlock() }; return createdOverflowBuffers }

    /// Completed overflow buffers waiting for reuse (at most `2 * regionCount`).
    public var pooledOverflowBuffers: Int { lock.lock(); defer { lock.unlock() }; return pool.count }

    private func overflowBuffer(minimumLength: Int) throws -> any MTLBuffer {
        lock.lock()
        if let index = pool.firstIndex(where: { $0.length >= minimumLength }) {
            let reused = pool.remove(at: index)
            lock.unlock()
            return reused
        }
        lock.unlock()
        let length = max(minimumLength, overflowChunkSize)
        guard length <= device.maxBufferLength,
              let created = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw FrameRingError.allocationFailed(bytes: length)
        }
        created.label = "FrameRing overflow"
        lock.lock(); createdOverflowBuffers += 1; lock.unlock()
        return created
    }

    private func retire(_ lease: Lease) {
        lock.lock(); defer { lock.unlock() }
        if let region = lease.region { inFlight[region] -= 1 }
        recycleLocked(lease.overflow)
    }

    private func recycleLocked(_ buffers: [any MTLBuffer]) {
        for candidate in buffers where pool.count < maxPooledOverflowBuffers { pool.append(candidate) }
    }

    /// Region and overflow buffers held by one submitted frame.
    private final class Lease: @unchecked Sendable {
        let region: Int?
        let overflow: [any MTLBuffer]
        init(region: Int?, overflow: [any MTLBuffer]) { self.region = region; self.overflow = overflow }
    }

    private static func align(_ n: Int) -> Int {
        (n + alignment - 1) & ~(alignment - 1)
    }
}
