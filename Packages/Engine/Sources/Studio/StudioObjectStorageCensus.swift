import Foundation
import Darwin

/// How many distinct `objects` buffers a set of Studio documents holds, and
/// their malloc sizes (#409 measurement). The current document and the undo
/// and redo steps share a buffer until an edit copies it, so the count is the
/// number of whole-array copies the history keeps alive.
///
/// It only reads: `withUnsafeBufferPointer` on a native array gives its
/// storage's element address without copying, and buffers are told apart by
/// that address. An empty array holds no buffer of its own and is not counted.
public enum StudioObjectStorageCensus {
    public struct Count: Sendable, Equatable {
        /// Distinct `_ContiguousArrayStorage<StudioObject>` buffers.
        public var buffers = 0
        /// The capacity the buffers hold, in objects.
        public var capacity = 0
        /// Σ `malloc_size` of the buffers' allocations: the storage header and
        /// the elements, rounded as malloc rounds. 0 for a buffer malloc does
        /// not recognise (see `headerBytes`).
        public var bytes = 0
        public init() {}
    }

    /// The bytes before the first element in a `_ContiguousArrayStorage` on
    /// 64-bit platforms: the object header (isa, refcount) and the array body
    /// (count, capacity and flags), 32 bytes, which `StudioObject`'s 16-byte
    /// alignment keeps.
    public static let headerBytes = 32

    public static func count(_ documents: [StudioDocument]) -> Count {
        var seen = Set<UInt>(), result = Count()
        for document in documents {
            document.objects.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
                let address = UInt(bitPattern: base)
                guard seen.insert(address).inserted else { return }
                result.buffers += 1
                result.capacity += document.objects.capacity
                result.bytes += malloc_size(UnsafeRawPointer(base) - headerBytes)
            }
        }
        return result
    }
}
