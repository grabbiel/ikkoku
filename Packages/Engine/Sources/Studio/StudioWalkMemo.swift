import Foundation

/// A memo for one walk over a fixed object list, where each object's value
/// is evaluated recursively through its parents. This is the Studio frame
/// rebuild's world matrix walk (#387). Each index is evaluated once, and
/// later queries get the stored result (the value, or the error it threw)
/// instead of evaluating the parent chain again. That makes the walk O(N)
/// instead of O(N · depth).
///
/// A stored result answers exactly what evaluating again would, provided
/// that:
/// - a query for an index that is still being evaluated is a parent cycle,
///   and throws `cycle()` there, where a visited-set walk would;
/// - each evaluation names every outside state it reads that can change
///   during the walk with `depend(on:)`, and the walk calls
///   `invalidate(_:)` after that state changes. That drops every stored
///   result that read the state, directly or through a parent;
/// - side effects an evaluation repeats on every query go through
///   `emit(_:)`. They reach `sink` at once, and a stored result replays
///   them in order each time it answers, including the events its parents'
///   evaluations emitted, so the sink sees the sequence a walk without the
///   memo produces.
///
/// Build it for one walk and drop it after. It is not thread-safe.
///
/// Its code is `@inlinable` so that a client module compiles it for its own
/// types (#387 round 3). Unspecialized, every entry access went through the
/// runtime's generic metadata and value witnesses: 6-9 ms of a 3,769-object
/// frame rebuild, and a quarter of a 32-object one.
public final class StudioWalkMemo<Key: Hashable, Value, Event> {
    @usableFromInline struct Entry {
        @usableFromInline let result: Result<Value, any Error>
        @usableFromInline let events: [Event]
        @usableFromInline let keys: [Key]

        @inlinable init(result: Result<Value, any Error>, events: [Event], keys: [Key]) {
            self.result = result
            self.events = events
            self.keys = keys
        }
    }

    @usableFromInline var entries: [Entry?]
    @usableFromInline var evaluating: [Bool]
    @usableFromInline var dependents: [Key: [Int]] = [:]
    // Events and keys of the evaluations in progress, appended in order; an
    // evaluation's own are the suffix from where it started.
    @usableFromInline var eventLog: [Event] = []
    @usableFromInline var keyLog: [Key] = []
    @usableFromInline var depth = 0
    @usableFromInline let sink: (Event) -> Void

    /// `count` is the number of indices; `sink` receives every emitted or
    /// replayed event.
    @inlinable public init(count: Int, sink: @escaping (Event) -> Void) {
        entries = Array(repeating: nil, count: count)
        evaluating = Array(repeating: false, count: count)
        self.sink = sink
    }

    /// The value at `index`: the stored result, with its events replayed,
    /// or `evaluate()`'s, stored. A query for an index whose evaluation is in
    /// progress throws `cycle()` and stores nothing for it.
    @inlinable public func value(at index: Int, cycle: () -> any Error, _ evaluate: () throws -> Value) throws -> Value {
        if let entry = entries[index] {
            for event in entry.events { emit(event) }
            if depth > 0 { keyLog.append(contentsOf: entry.keys) }
            return try entry.result.get()
        }
        guard !evaluating[index] else { throw cycle() }
        evaluating[index] = true
        let firstEvent = eventLog.count, firstKey = keyLog.count
        depth += 1
        let result = Result { try evaluate() }
        depth -= 1
        evaluating[index] = false
        let keys = Array(keyLog[firstKey...])
        entries[index] = Entry(result: result, events: Array(eventLog[firstEvent...]), keys: keys)
        for key in keys { dependents[key, default: []].append(index) }
        if depth == 0 {
            eventLog.removeAll(keepingCapacity: true)
            keyLog.removeAll(keepingCapacity: true)
        }
        return try result.get()
    }

    /// A side effect of the evaluation in progress: it reaches the sink now,
    /// and every later answer from that evaluation's result replays it.
    @inlinable public func emit(_ event: Event) {
        sink(event)
        if depth > 0 { eventLog.append(event) }
    }

    /// The evaluation in progress read state that `invalidate(key)` reports
    /// as changed.
    @inlinable public func depend(on key: Key) {
        if depth > 0 { keyLog.append(key) }
    }

    /// The state named `key` changed: drop every stored result that read it.
    /// Call it between queries, not during an evaluation. A result that
    /// depended on several keys may be dropped again after a later change
    /// of another one; that only costs an evaluation.
    @inlinable public func invalidate(_ key: Key) {
        assert(depth == 0, "a Studio walk memo invalidated during an evaluation")
        guard !dependents.isEmpty, let indices = dependents.removeValue(forKey: key) else { return }
        for index in indices { entries[index] = nil }
    }
}
