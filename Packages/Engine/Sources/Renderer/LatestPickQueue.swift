import Foundation
import os
import CoreMath

/// Hover picking for the latest pointer position only (R7 phase 2, item 5).
///
/// A pointer can move more often than a GPU pick round trip completes. The
/// queue keeps at most one pick in flight: a move while one is in flight only
/// records its position, replacing any earlier waiting position. A finished
/// pick applies only when it answers the latest move and was taken against the
/// owner's current context (the frame and viewport it was rendered from).
/// Otherwise it is stale and dropped, and the latest move, if it still has no
/// answer, is picked again against the current context. A move that was
/// answered stays answered: a later context change does not pick it again.
///
/// A plain value with no threads of its own: its owner calls it from one
/// actor (the Studio's main actor), runs the picks it returns
/// (`Renderer.pick(frame:pixel:size:completion:)`) and hands each finished
/// one back through `finish`.
public struct LatestPickQueue<Context: Equatable & Sendable>: Sendable {
    /// One pick to run: the move it answers, its pixel and the context to take it against.
    public struct Request: Equatable, Sendable {
        public let move: UInt64
        public let pixel: Float2
        public let context: Context
    }

    public enum Outcome: Equatable, Sendable {
        /// The result answers the latest move against the current context.
        case apply
        /// The result belongs to an older move, an older context or a
        /// cancelled request; it is dropped.
        case stale
    }

    /// Counts since the queue was created.
    public struct Statistics: Equatable, Sendable {
        public var moves = 0
        /// Moves that waited because a pick was in flight.
        public var coalesced = 0
        /// Picks handed to the owner to run (first picks and re-picks).
        public var issued = 0
        public var applied = 0
        public var stale = 0
        public init() {}
    }

    public private(set) var inFlight: Request?
    public private(set) var statistics = Statistics()
    /// The latest move without an applied answer.
    private var waiting: (move: UInt64, pixel: Float2)?
    private var moves: UInt64 = 0

    public init() {}

    /// True when no pick is in flight. A waiting move always has one in
    /// flight, so an idle queue has nothing left to do.
    public var isIdle: Bool { inFlight == nil }

    /// Records a pointer move. Returns the pick to run now, or nil when one
    /// is already in flight (this move waits for it).
    public mutating func move(to pixel: Float2, context: Context) -> Request? {
        moves &+= 1
        statistics.moves += 1
        waiting = (moves, pixel)
        guard inFlight == nil else { statistics.coalesced += 1; return nil }
        return issue(context)
    }

    /// Hands back a finished pick. `current` is the owner's context now.
    /// Returns whether to apply its result and the next pick to run, if any.
    /// A request that is not the one in flight (already finished, or unknown)
    /// is stale and changes nothing.
    public mutating func finish(_ request: Request, current: Context) -> (outcome: Outcome, next: Request?) {
        guard request == inFlight else { return (.stale, nil) }
        inFlight = nil
        if let waiting, waiting.move == request.move, request.context == current {
            self.waiting = nil
            statistics.applied += 1
            return (.apply, nil)
        }
        statistics.stale += 1
        guard waiting != nil else { return (.stale, nil) }
        return (.stale, issue(current))
    }

    /// Forgets the waiting move, so the pick in flight finishes stale and
    /// nothing is picked again (the owner no longer wants a hover).
    public mutating func cancel() { waiting = nil }

    private mutating func issue(_ context: Context) -> Request {
        let request = Request(move: waiting!.move, pixel: waiting!.pixel, context: context)
        inFlight = request
        statistics.issued += 1
        return request
    }
}

/// Hands finished asynchronous picks from the Metal completion thread to the
/// actor that applies them, which can also wait for one: a click first
/// settles the hover pick in flight, as the synchronous hover pick had already
/// done by then. Sendable without `@unchecked`: the deliveries are behind an
/// `OSAllocatedUnfairLock`, and the semaphore only wakes a waiter.
public final class PickMailbox<Request: Sendable>: Sendable {
    private let deliveries = OSAllocatedUnfairLock<[(request: Request, result: RenderPickResult)]>(initialState: [])
    private let arrived = DispatchSemaphore(value: 0)

    public init() {}

    /// Called from any thread when a pick finishes.
    public func deliver(_ request: Request, _ result: RenderPickResult) {
        deliveries.withLock { $0.append((request, result)) }
        arrived.signal()
    }

    /// The oldest undelivered pick, if any.
    public func take() -> (request: Request, result: RenderPickResult)? {
        deliveries.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }

    /// Blocks until a pick is waiting to be taken; false after `timeout` seconds without one.
    public func waitForDelivery(timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while deliveries.withLock({ $0.isEmpty }) {
            // A signal can be left over from a delivery someone already took;
            // the loop then checks again.
            if arrived.wait(timeout: deadline) == .timedOut { return deliveries.withLock { !$0.isEmpty } }
        }
        return true
    }
}
