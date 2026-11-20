import Foundation
import Darwin

/// How many distinct `objects` buffers a set of Studio documents holds, and
/// their malloc sizes (#409 measurement). The current document and the undo
/// and redo steps share a buffer until an edit copies it, so the count is the
/// number of whole-array copies the history keeps alive. A patch step (#446)
/// keeps only its own small list of objects.
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

    public static func count(_ documents: [StudioDocument]) -> Count { count(lists: documents.map(\.objects)) }

    /// The current document and every object list `history` keeps: each
    /// whole document step's list and each patch step's objects (#446). A
    /// patch step's other fields hold no object list.
    public static func count(current: StudioDocument, history: StudioUndoHistory<StudioDocument>) -> Count {
        var lists = [current.objects]
        for step in history.undoSteps + history.redoSteps {
            switch step {
            case .document(let document): lists.append(document.objects)
            case .patch(let patch): lists.append(patch.before)
            }
        }
        return count(lists: lists)
    }

    public static func count(lists: [[StudioObject]]) -> Count {
        var seen = Set<UInt>(), result = Count()
        for list in lists {
            list.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
                let address = UInt(bitPattern: base)
                guard seen.insert(address).inserted else { return }
                result.buffers += 1
                result.capacity += list.capacity
                result.bytes += malloc_size(UnsafeRawPointer(base) - headerBytes)
            }
        }
        return result
    }
}
