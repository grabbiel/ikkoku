import Foundation

/// How a host must treat one `SourceGameplayDeferredEffect` (G-T01).
public enum SourceGameplayEffectTiming: String, Codable, Sendable {
    /// Performed by the host as soon as it is released, in source order. The
    /// session does not wait for it.
    case synchronousWork
    /// The host must finish the work and acknowledge it before any later
    /// effect of the same operation is released or the operation commits.
    case completionBarrier
}

extension SourceGameplayDeferredEffect {
    /// Exhaustive on purpose: a new effect does not compile until classified.
    /// The basis of each row is the recovered contract in
    /// docs/reference/gameplay/cycle.md ("Session host and effect inventory").
    /// Where completion of a source step has not been recovered, the effect is
    /// conservatively a barrier: an unneeded acknowledgement is safe, while a
    /// missing wait would let later work run before the source would.
    public var timing: SourceGameplayEffectTiming {
        switch self {
        // Source Change(Week) is a direct call (only the four completion
        // commits of the cycle are coroutine boundaries): weekday display,
        // saved weekday and the per-heroine daily counters run inline.
        case .updateWeekDisplay, .persistWeek, .advanceCharacterDays:
            return .synchronousWork
        // Direct Change(Type): clock zone, current-map sunlight and the
        // minimap/camera switch run inline. Sunlight still needs a loaded map.
        case .updateTimeZone, .updateMapSunlight, .setMiniMapAndCameraActive:
            return .synchronousWork
        // Change(Type) replaces the running period coroutine only after ADV
        // processing ends. Whether the source runs the following
        // minimap/camera switch before that wait ends is not recorded, so the
        // session holds every later effect until this is acknowledged.
        case .replacePeriodAfterADVBarrier:
            return .completionBarrier
        // _Next waits for additive scenes, map loading and fade before its
        // Change(Type); clearing the player's next flag follows inline.
        case .prepareNextPeriodSceneBarrier:
            return .completionBarrier
        case .clearPlayerNextFlag:
            return .synchronousWork
        // MapMove entry. The opening tutorial is a recorded wait. The source
        // also waits for a fade before the first timed iteration, but no
        // effect is recorded as that fade, and NPC loading, character/camera
        // preparation and the cut-in have no recovered completion rule: all
        // of them are conservative barriers so ticks cannot start early.
        case .loadNPCs, .openingTutorial, .prepareMapMoveCharactersAndCamera, .startTimeZoneCutIn:
            return .completionBarrier
        // The MapMove loop's exit waits for its scene barrier.
        case .finishMapMoveAndWaitForSceneBarrier:
            return .completionBarrier
        // MyHouse tail: the recovered completion has exactly two waits, the
        // night menu (before completeNightMenu is requested) and player
        // initialization. Parameter correction, companion and Saturday
        // teacher clearing and the action-count reset run inline.
        case .ensurePlayerCreatedAndInitialized:
            return .completionBarrier
        case .correctGameParameters, .clearCachedCompanions, .resetPlayerActionCount, .clearSaturdayTeachers:
            return .synchronousWork
        }
    }
}

/// The effect-producing `SourceGameplayCycle` operations, as persisted data.
/// Cases and labels mirror the cycle methods; the timer operations produce no
/// effects and are separate `SourceGameplaySession` methods.
public enum SourceGameplayCycleOperation: Equatable, Sendable, Codable {
    case changePeriod(SourceGameplayPeriod)
    case changeWeek(SourceGameplayWeek)
    case nextWeek(Int32)
    case nextPeriod(returningToTitle: Bool = false, gameEnded: Bool = false)
    case reloadNightMenuWeek(SourceGameplayWeek)
    case completeNightMenu(returningToTitle: Bool = false, gameEnded: Bool = false)
    case beginMapMove
    case finishMapMove
}

extension SourceGameplayCycle {
    /// Runs one operation exactly as the matching method does, including its
    /// errors. A thrown error leaves the cycle unchanged.
    public mutating func apply(_ operation: SourceGameplayCycleOperation) throws -> [SourceGameplayDeferredEffect] {
        switch operation {
        case .changePeriod(let value): return changePeriod(value)
        case .changeWeek(let value): return changeWeek(value)
        case .nextWeek(let plus): return try nextWeek(plus)
        case .nextPeriod(let returningToTitle, let gameEnded):
            return nextPeriod(returningToTitle: returningToTitle, gameEnded: gameEnded)
        case .reloadNightMenuWeek(let value): return try reloadNightMenuWeek(value)
        case .completeNightMenu(let returningToTitle, let gameEnded):
            return try completeNightMenu(returningToTitle: returningToTitle, gameEnded: gameEnded)
        case .beginMapMove: return try beginMapMove()
        case .finishMapMove: return try finishMapMove()
        }
    }
}

/// One issued completion barrier. IDs are unique within a session and
/// increase in issue order; `effect` keeps the original command identity.
public struct SourceGameplayBarrier: Equatable, Sendable, Codable {
    public let id: Int
    public let effect: SourceGameplayDeferredEffect
    /// The only acknowledgement the session accepts while this is outstanding.
    public var acknowledgement: SourceGameplayAcknowledgement { .init(barrierID: id, effect: effect) }
}

/// A host's statement that it finished one barrier: both the issued ID and
/// the exact barrier effect must match the outstanding barrier.
public struct SourceGameplayAcknowledgement: Equatable, Sendable, Codable {
    public var barrierID: Int
    public var effect: SourceGameplayDeferredEffect
    public init(barrierID: Int, effect: SourceGameplayDeferredEffect) {
        self.barrierID = barrierID
        self.effect = effect
    }
}

public enum SourceGameplaySessionError: Error, Equatable, LocalizedError {
    case transitionInFlight(SourceGameplayBarrier)
    case unknownAcknowledgement(SourceGameplayAcknowledgement)
    case duplicateAcknowledgement(SourceGameplayAcknowledgement)
    case outOfOrderAcknowledgement(expected: SourceGameplayBarrier, received: SourceGameplayAcknowledgement)
    case mismatchedAcknowledgement(expected: SourceGameplayBarrier, received: SourceGameplayAcknowledgement)
    case synchronousWorkPending(Int)
    case barrierIDsExhausted
    case unsupportedSchemaVersion(Int)
    case inconsistentSnapshot(String)

    public var errorDescription: String? {
        switch self {
        case .transitionInFlight(let barrier):
            "Gameplay barrier \(barrier.id) (\(barrier.effect)) must be acknowledged before another cycle operation."
        case .unknownAcknowledgement(let value):
            "Gameplay barrier \(value.barrierID) was never issued by this session."
        case .duplicateAcknowledgement(let value):
            "Gameplay barrier \(value.barrierID) was already acknowledged."
        case .outOfOrderAcknowledgement(let expected, let received):
            "Gameplay barrier \(received.barrierID) cannot be acknowledged before barrier \(expected.id) (\(expected.effect))."
        case .mismatchedAcknowledgement(let expected, let received):
            "Gameplay barrier \(expected.id) is \(expected.effect), not \(received.effect)."
        case .synchronousWorkPending(let count):
            "Take the \(count) released synchronous gameplay effect(s) before acknowledging the next barrier."
        case .barrierIDsExhausted: "Gameplay barrier IDs are exhausted."
        case .unsupportedSchemaVersion(let version): "Unsupported gameplay session schema version \(version)."
        case .inconsistentSnapshot(let detail): "Inconsistent gameplay session snapshot: \(detail)."
        }
    }
}

/// Platform-neutral host state for `SourceGameplayCycle` (G-T01). It executes
/// no scene, NPC, ADV, menu or save work; it orders what a host owes.
///
/// An effect-producing operation is staged on a copy of the committed cycle.
/// Its returned effects are then released in source order: synchronous work
/// goes to `synchronousWork` until the first barrier, which stays outstanding
/// until acknowledged; the next run of synchronous work follows, and so on.
/// `cycle` becomes the staged target only after the operation's last barrier,
/// so no period or weekday advance is committed while one of its
/// dependencies is open, and no other cycle operation (including the timer)
/// is accepted meanwhile. Synchronous work released before a barrier must be
/// taken before that barrier is acknowledged. The in-flight target and the
/// released effects are visible to the host for presentation.
///
/// A snapshot is the whole value (schema version 1). Decoding replays the
/// in-flight operation on the committed cycle and rejects any snapshot whose
/// effects, target, barrier IDs or position disagree with that replay.
public struct SourceGameplaySession: Sendable, Equatable, Codable {
    public static let schemaVersion = 1

    /// A staged operation that has not committed yet.
    public struct Transition: Sendable, Equatable, Codable {
        public let operation: SourceGameplayCycleOperation
        /// Every effect the operation returned, in source order.
        public let effects: [SourceGameplayDeferredEffect]
        /// The cycle state committed after the last barrier.
        public let target: SourceGameplayCycle
        /// The ID of the first barrier in `effects`; later ones are consecutive.
        public let firstBarrierID: Int
        /// Effects already released: synchronous work handed to the host and
        /// barriers acknowledged. While in flight it indexes the outstanding
        /// barrier.
        public fileprivate(set) var released: Int

        fileprivate init(operation: SourceGameplayCycleOperation, effects: [SourceGameplayDeferredEffect],
                         target: SourceGameplayCycle, firstBarrierID: Int) {
            self.operation = operation
            self.effects = effects
            self.target = target
            self.firstBarrierID = firstBarrierID
            self.released = 0
        }
    }

    /// The last fully committed cycle state.
    public private(set) var cycle: SourceGameplayCycle
    public private(set) var transition: Transition?
    /// Released synchronous work not yet taken by the host, in source order.
    public private(set) var synchronousWork: [SourceGameplayDeferredEffect] = []
    /// The ID the next issued barrier receives.
    public private(set) var nextBarrierID = 0

    public init(cycle: SourceGameplayCycle = SourceGameplayCycle()) {
        self.cycle = cycle
    }

    public var outstandingBarrier: SourceGameplayBarrier? {
        guard let transition, transition.released < transition.effects.count else { return nil }
        // Earlier barriers of this operation were acknowledged in order.
        let acknowledged = transition.effects[..<transition.released].filter { $0.timing == .completionBarrier }.count
        return SourceGameplayBarrier(id: transition.firstBarrierID + acknowledged,
                                     effect: transition.effects[transition.released])
    }

    /// Stages one cycle operation and releases its effects up to the first
    /// barrier. A rejected source operation throws its `SourceGameplayCycleError`
    /// and leaves the session unchanged.
    public mutating func perform(_ operation: SourceGameplayCycleOperation) throws {
        try requireNoOutstandingBarrier()
        var target = cycle
        let effects = try target.apply(operation)
        let barriers = effects.filter { $0.timing == .completionBarrier }.count
        let (end, overflow) = nextBarrierID.addingReportingOverflow(barriers)
        guard !overflow else { throw SourceGameplaySessionError.barrierIDsExhausted }
        transition = Transition(operation: operation, effects: effects, target: target, firstBarrierID: nextBarrierID)
        nextBarrierID = end
        release()
    }

    /// Completes the outstanding barrier. Every rejection leaves the session
    /// unchanged. Because barriers are acknowledged strictly in issue order and
    /// operations never overlap, every issued ID below the outstanding one has
    /// been acknowledged already.
    public mutating func acknowledge(_ acknowledgement: SourceGameplayAcknowledgement) throws {
        let id = acknowledgement.barrierID
        guard id >= 0, id < nextBarrierID else {
            throw SourceGameplaySessionError.unknownAcknowledgement(acknowledgement)
        }
        guard let barrier = outstandingBarrier, id >= barrier.id else {
            throw SourceGameplaySessionError.duplicateAcknowledgement(acknowledgement)
        }
        guard id == barrier.id else {
            throw SourceGameplaySessionError.outOfOrderAcknowledgement(expected: barrier, received: acknowledgement)
        }
        guard acknowledgement.effect == barrier.effect else {
            throw SourceGameplaySessionError.mismatchedAcknowledgement(expected: barrier, received: acknowledgement)
        }
        // Work released before this barrier precedes it in source order.
        guard synchronousWork.isEmpty else {
            throw SourceGameplaySessionError.synchronousWorkPending(synchronousWork.count)
        }
        transition?.released += 1
        release()
    }

    /// Hands released synchronous work to the host, which performs it in order.
    public mutating func takeSynchronousWork() -> [SourceGameplayDeferredEffect] {
        let work = synchronousWork
        synchronousWork = []
        return work
    }

    /// Timer operations are forwarded only while nothing is in flight. Which
    /// side of a pending source wait they would apply to is not modelled.
    public mutating func actionEnd() throws {
        try requireNoOutstandingBarrier()
        cycle.actionEnd()
    }

    public mutating func addTimer(_ fraction: Float) throws {
        try requireNoOutstandingBarrier()
        try cycle.addTimer(fraction)
    }

    public mutating func tickMapMove(deltaTime: Float, cursorLocked: Bool, gameRegulated: Bool,
                                     advProcessing: Bool = false, talkSceneActive: Bool = false,
                                     interactionSceneActive: Bool = false) throws {
        try requireNoOutstandingBarrier()
        try cycle.tickMapMove(deltaTime: deltaTime, cursorLocked: cursorLocked, gameRegulated: gameRegulated,
                              advProcessing: advProcessing, talkSceneActive: talkSceneActive,
                              interactionSceneActive: interactionSceneActive)
    }

    private func requireNoOutstandingBarrier() throws {
        if let barrier = outstandingBarrier { throw SourceGameplaySessionError.transitionInFlight(barrier) }
    }

    /// Releases synchronous work up to the next barrier, or commits the staged
    /// target when no barrier remains.
    private mutating func release() {
        guard var staged = transition else { return }
        while staged.released < staged.effects.count, staged.effects[staged.released].timing == .synchronousWork {
            synchronousWork.append(staged.effects[staged.released])
            staged.released += 1
        }
        if staged.released == staged.effects.count {
            cycle = staged.target
            transition = nil
        } else {
            transition = staged
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, cycle, transition, synchronousWork, nextBarrierID
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let version = try box.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else { throw SourceGameplaySessionError.unsupportedSchemaVersion(version) }
        cycle = try box.decode(SourceGameplayCycle.self, forKey: .cycle)
        transition = try box.decodeIfPresent(Transition.self, forKey: .transition)
        synchronousWork = try box.decode([SourceGameplayDeferredEffect].self, forKey: .synchronousWork)
        nextBarrierID = try box.decode(Int.self, forKey: .nextBarrierID)
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(Self.schemaVersion, forKey: .schemaVersion)
        try box.encode(cycle, forKey: .cycle)
        try box.encodeIfPresent(transition, forKey: .transition)
        try box.encode(synchronousWork, forKey: .synchronousWork)
        try box.encode(nextBarrierID, forKey: .nextBarrierID)
    }

    /// Checks the invariants `perform`/`acknowledge` maintain, so a decoded
    /// session continues exactly as the encoded one would have.
    private func validate() throws {
        func inconsistent(_ detail: String) -> SourceGameplaySessionError { .inconsistentSnapshot(detail) }
        guard nextBarrierID >= 0 else { throw inconsistent("negative barrier counter") }
        guard synchronousWork.allSatisfy({ $0.timing == .synchronousWork }) else {
            throw inconsistent("a completion barrier is queued as synchronous work")
        }
        guard let transition else { return }
        var replayed = cycle
        let effects: [SourceGameplayDeferredEffect]
        do { effects = try replayed.apply(transition.operation) } catch {
            throw inconsistent("the in-flight operation is rejected by the committed cycle")
        }
        guard effects == transition.effects, replayed == transition.target else {
            throw inconsistent("the in-flight effects or target differ from a replay of its operation")
        }
        let barriers = effects.filter { $0.timing == .completionBarrier }.count
        guard transition.firstBarrierID >= 0, transition.firstBarrierID <= nextBarrierID,
              nextBarrierID - transition.firstBarrierID == barriers else {
            throw inconsistent("barrier IDs do not match the in-flight operation")
        }
        guard transition.released >= 0, transition.released < effects.count,
              effects[transition.released].timing == .completionBarrier else {
            throw inconsistent("the in-flight position is not at a completion barrier")
        }
    }
}
