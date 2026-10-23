import Foundation
import Testing
import Gameplay

// G-T01: synthetic host traces only. No original data, scene, NPC or ADV runs;
// the tests stand in for a host that completes every barrier it is given.

@Test func sourceGameplayEffectTimingInventory() {
    // The documented inventory (docs/reference/gameplay/cycle.md): 11
    // synchronous effects and 8 barriers, 3 of them conservative.
    let synchronous: [SourceGameplayDeferredEffect] = [
        .persistWeek(.monday), .updateWeekDisplay(.monday), .advanceCharacterDays(1), .updateTimeZone(0),
        .updateMapSunlight(.wakeUp), .setMiniMapAndCameraActive(true), .clearPlayerNextFlag,
        .correctGameParameters, .clearCachedCompanions, .resetPlayerActionCount(5), .clearSaturdayTeachers
    ]
    let barriers: [SourceGameplayDeferredEffect] = [
        .replacePeriodAfterADVBarrier(.wakeUp), .prepareNextPeriodSceneBarrier, .loadNPCs(shuffle: true),
        .openingTutorial, .prepareMapMoveCharactersAndCamera, .startTimeZoneCutIn(.lunchTime),
        .finishMapMoveAndWaitForSceneBarrier, .ensurePlayerCreatedAndInitialized
    ]
    #expect(synchronous.allSatisfy { $0.timing == .synchronousWork })
    #expect(barriers.allSatisfy { $0.timing == .completionBarrier })
}

@Test func sourceGameplaySessionHoldsNextPeriodUntilBarriersAcknowledged() throws {
    var session = SourceGameplaySession(cycle: SourceGameplayCycle(week: .monday))
    try session.perform(.nextPeriod())
    // _Next waits for its scene barrier before Change(Type) releases any work.
    #expect(session.takeSynchronousWork().isEmpty)
    let scene = try #require(session.outstandingBarrier)
    #expect(scene.effect == .prepareNextPeriodSceneBarrier)
    #expect(session.cycle.period == .wakeUp)
    #expect(session.transition?.target.period == .morning)
    #expect(throws: SourceGameplaySessionError.transitionInFlight(scene)) { try session.perform(.nextPeriod()) }
    #expect(throws: SourceGameplaySessionError.transitionInFlight(scene)) { try session.perform(.changeWeek(.friday)) }
    #expect(session.cycle.period == .wakeUp)
    #expect(session.cycle.week == .monday)

    try session.acknowledge(scene.acknowledgement)
    #expect(session.takeSynchronousWork() == [.updateTimeZone(0), .updateMapSunlight(.morning)])
    let adv = try #require(session.outstandingBarrier)
    #expect(adv.effect == .replacePeriodAfterADVBarrier(.morning))
    #expect(adv.id == scene.id + 1)
    #expect(session.cycle.period == .wakeUp) // Still the committed period.

    try session.acknowledge(adv.acknowledgement)
    #expect(session.takeSynchronousWork() == [.setMiniMapAndCameraActive(false), .clearPlayerNextFlag])
    let idle = session.transition == nil
    #expect(idle)
    #expect(session.cycle.period == .morning)
    #expect(session.nextBarrierID == 2)
}

@Test func sourceGameplaySessionNightMenuAdvancesDayOnlyAfterItsBarriers() throws {
    var session = SourceGameplaySession(cycle: SourceGameplayCycle(isOpening: false, week: .friday))
    try session.perform(.completeNightMenu())
    #expect(session.takeSynchronousWork() == [.correctGameParameters, .clearCachedCompanions])
    var barrier = try #require(session.outstandingBarrier)
    #expect(barrier.effect == .ensurePlayerCreatedAndInitialized)
    try session.acknowledge(barrier.acknowledgement)
    // Source order: action-count reset, NextWeek, Saturday teachers, then _Next.
    #expect(session.takeSynchronousWork() == [.resetPlayerActionCount(5), .updateWeekDisplay(.saturday),
        .persistWeek(.saturday), .advanceCharacterDays(1), .clearSaturdayTeachers])
    barrier = try #require(session.outstandingBarrier)
    #expect(barrier.effect == .prepareNextPeriodSceneBarrier)
    #expect(session.cycle.week == .friday)
    #expect(session.cycle.period == .myHouse)
    try session.acknowledge(barrier.acknowledgement)
    #expect(session.takeSynchronousWork() == [.updateTimeZone(0), .updateMapSunlight(.wakeUp)])
    barrier = try #require(session.outstandingBarrier)
    #expect(barrier.effect == .replacePeriodAfterADVBarrier(.wakeUp))
    #expect(session.cycle.week == .friday)
    try session.acknowledge(barrier.acknowledgement)
    #expect(session.takeSynchronousWork() == [.setMiniMapAndCameraActive(false), .clearPlayerNextFlag])
    #expect(session.cycle.week == .saturday)
    #expect(session.cycle.period == .wakeUp)
}

@Test func sourceGameplaySessionRejectsInvalidAcknowledgementsWithoutMutation() throws {
    var session = SourceGameplaySession(cycle: SourceGameplayCycle(week: .monday))
    try session.perform(.changePeriod(.lunchTime))
    let periodBarrier = try #require(session.outstandingBarrier)
    #expect(periodBarrier.effect == .replacePeriodAfterADVBarrier(.lunchTime))

    // Released work precedes its barrier: it must be taken first.
    var before = session
    #expect(throws: SourceGameplaySessionError.synchronousWorkPending(2)) {
        try session.acknowledge(periodBarrier.acknowledgement)
    }
    #expect(session == before)
    #expect(session.takeSynchronousWork() == [.updateTimeZone(1), .updateMapSunlight(.lunchTime)])
    try session.acknowledge(periodBarrier.acknowledgement)
    #expect(session.takeSynchronousWork() == [.setMiniMapAndCameraActive(true)])

    // Idle: an issued ID is a duplicate, anything else is unknown.
    before = session
    #expect(throws: SourceGameplaySessionError.duplicateAcknowledgement(periodBarrier.acknowledgement)) {
        try session.acknowledge(periodBarrier.acknowledgement)
    }
    let unissued = SourceGameplayAcknowledgement(barrierID: 1, effect: .loadNPCs(shuffle: true))
    #expect(throws: SourceGameplaySessionError.unknownAcknowledgement(unissued)) { try session.acknowledge(unissued) }
    #expect(session == before)

    // MapMove entry issues four consecutive barriers (IDs 1...4).
    try session.perform(.beginMapMove)
    #expect(session.takeSynchronousWork().isEmpty)
    let npcs = try #require(session.outstandingBarrier)
    #expect(npcs.id == 1)
    try session.acknowledge(npcs.acknowledgement)
    let tutorial = try #require(session.outstandingBarrier)
    #expect(tutorial.effect == .openingTutorial)
    #expect(tutorial.id == 2)
    #expect(session.nextBarrierID == 5)

    before = session
    let early = SourceGameplayAcknowledgement(barrierID: 3, effect: .prepareMapMoveCharactersAndCamera)
    let last = SourceGameplayAcknowledgement(barrierID: 4, effect: .startTimeZoneCutIn(.lunchTime))
    let wrongEffect = SourceGameplayAcknowledgement(barrierID: 2, effect: .prepareNextPeriodSceneBarrier)
    let notIssued = SourceGameplayAcknowledgement(barrierID: 5, effect: .openingTutorial)
    let negative = SourceGameplayAcknowledgement(barrierID: -1, effect: .openingTutorial)
    let rejected: [(SourceGameplayAcknowledgement, SourceGameplaySessionError)] = [
        (npcs.acknowledgement, .duplicateAcknowledgement(npcs.acknowledgement)),
        (periodBarrier.acknowledgement, .duplicateAcknowledgement(periodBarrier.acknowledgement)),
        (early, .outOfOrderAcknowledgement(expected: tutorial, received: early)),
        (last, .outOfOrderAcknowledgement(expected: tutorial, received: last)),
        (wrongEffect, .mismatchedAcknowledgement(expected: tutorial, received: wrongEffect)),
        (notIssued, .unknownAcknowledgement(notIssued)),
        (negative, .unknownAcknowledgement(negative))
    ]
    for (acknowledgement, error) in rejected {
        #expect(throws: error) { try session.acknowledge(acknowledgement) }
        #expect(session == before, "\(acknowledgement)")
    }
    // Every other cycle operation, including the timer, waits as well.
    #expect(throws: SourceGameplaySessionError.transitionInFlight(tutorial)) {
        try session.tickMapMove(deltaTime: 1, cursorLocked: true, gameRegulated: false)
    }
    #expect(throws: SourceGameplaySessionError.transitionInFlight(tutorial)) { try session.addTimer(0.5) }
    #expect(throws: SourceGameplaySessionError.transitionInFlight(tutorial)) { try session.actionEnd() }
    #expect(throws: SourceGameplaySessionError.transitionInFlight(tutorial)) { try session.perform(.finishMapMove) }
    #expect(session == before)

    // The exact acknowledgement still succeeds afterwards.
    try session.acknowledge(tutorial.acknowledgement)
    #expect(session.outstandingBarrier?.effect == .prepareMapMoveCharactersAndCamera)
}

@Test func sourceGameplaySessionGatesMapMoveOnEntryAndExitBarriers() throws {
    var session = SourceGameplaySession(cycle: SourceGameplayCycle(week: .monday))
    try session.perform(.changePeriod(.lunchTime))
    _ = session.takeSynchronousWork()
    let lunchTime = try #require(session.outstandingBarrier)
    try session.acknowledge(lunchTime.acknowledgement)
    _ = session.takeSynchronousWork()

    try session.perform(.beginMapMove)
    let entry: [SourceGameplayDeferredEffect] = [.loadNPCs(shuffle: true), .openingTutorial,
                                                 .prepareMapMoveCharactersAndCamera, .startTimeZoneCutIn(.lunchTime)]
    for effect in entry {
        let barrier = try #require(session.outstandingBarrier)
        #expect(barrier.effect == effect)
        #expect(!session.cycle.mapMoveActive)
        #expect(session.cycle.isOpening)
        try session.acknowledge(barrier.acknowledgement)
        #expect(session.takeSynchronousWork().isEmpty)
    }
    #expect(session.cycle.mapMoveActive)
    #expect(!session.cycle.isOpening)
    try session.tickMapMove(deltaTime: 501, cursorLocked: true, gameRegulated: false)
    #expect(session.cycle.timer == 501)

    try session.perform(.finishMapMove)
    let exit = try #require(session.outstandingBarrier)
    #expect(exit.effect == .finishMapMoveAndWaitForSceneBarrier)
    #expect(session.cycle.mapMoveActive)
    #expect(session.transition?.target.timePass == 1)
    try session.acknowledge(exit.acknowledgement)
    #expect(!session.cycle.mapMoveActive)
    #expect(session.cycle.timePass == 1)
    #expect(session.cycle.timer == 501)

    // A rejected source operation stages nothing.
    session = SourceGameplaySession(cycle: SourceGameplayCycle(week: .holiday))
    try session.perform(.changePeriod(.lunchTime))
    _ = session.takeSynchronousWork()
    let holidayLunchTime = try #require(session.outstandingBarrier)
    try session.acknowledge(holidayLunchTime.acknowledgement)
    _ = session.takeSynchronousWork()
    let before = session
    #expect(throws: SourceGameplayCycleError.mapMoveNotAvailable) { try session.perform(.beginMapMove) }
    #expect(throws: SourceGameplayCycleError.mapMoveNotActive) { try session.perform(.finishMapMove) }
    #expect(session == before)
}

private enum HostStep: Sendable {
    case perform(SourceGameplayCycleOperation)
    case tick(Float)
    case actionEnd
}

private enum HostObservation: Equatable {
    case rejected(SourceGameplayCycleError)
    case work([SourceGameplayDeferredEffect])
    case barrier(SourceGameplayBarrier)
    case committed(SourceGameplayCycle)
}

/// Friday (opening) through Wednesday: _Next scene and ADV barriers, both
/// MapMove gates, night-menu completion, a backward day change, direct week
/// changes, a night-menu load, rejected Holiday MapMove/weekday operations and
/// a title exit. Timers and display fractions stay exact binary fractions, so
/// the JSON round trip is exact whatever the encoder's float formatting.
private let sessionTrace: [HostStep] = {
    var steps = [HostStep](repeating: .perform(.nextPeriod()), count: 5) // WakeUp -> LunchTime
    steps += [.perform(.beginMapMove), .tick(250), .tick(375), .perform(.finishMapMove)]
    steps += [HostStep](repeating: .perform(.nextPeriod()), count: 3) // -> StaffTime
    steps += [.perform(.beginMapMove), .actionEnd, .tick(250), .perform(.finishMapMove)]
    steps += [HostStep](repeating: .perform(.nextPeriod()), count: 3) // -> MyHouse
    steps += [.perform(.completeNightMenu())] // Saturday WakeUp
    steps += [.perform(.changePeriod(.afterSchool)), .perform(.beginMapMove), .tick(500), .perform(.finishMapMove)]
    steps += [.perform(.changePeriod(.morning))] // Backward: Holiday
    steps += [HostStep](repeating: .perform(.nextPeriod()), count: 4) // -> LunchTime
    steps += [.perform(.beginMapMove)] // Rejected on Holiday.
    steps += [.perform(.changeWeek(.monday)), .perform(.nextWeek(7)), .perform(.nextWeek(-8))]
    steps += [.perform(.changePeriod(.myHouse)), .perform(.reloadNightMenuWeek(.tuesday)), .perform(.completeNightMenu())]
    steps += [.perform(.nextPeriod(returningToTitle: true))]
    return steps
}()

private func roundTrip(_ session: SourceGameplaySession) throws -> SourceGameplaySession {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(session)
    let decoded = try JSONDecoder().decode(SourceGameplaySession.self, from: data)
    #expect(decoded == session)
    #expect(try encoder.encode(decoded) == data)
    return decoded
}

/// A host that performs released work at once and completes every barrier
/// in order. `reloadAt` round-trips the session through JSON while that
/// zero-based barrier of the run is outstanding, then acknowledges it with
/// the acknowledgement captured before the reload.
private func runHost(_ steps: [HostStep], reloadAt: Int? = nil) throws
    -> (log: [HostObservation], session: SourceGameplaySession, barriers: Int) {
    var session = SourceGameplaySession(cycle: SourceGameplayCycle(isOpening: true, week: .friday))
    var log: [HostObservation] = []
    var barriers = 0
    for step in steps {
        do {
            switch step {
            case .perform(let operation): try session.perform(operation)
            case .tick(let deltaTime): try session.tickMapMove(deltaTime: deltaTime, cursorLocked: true, gameRegulated: false)
            case .actionEnd: try session.actionEnd()
            }
        } catch let error as SourceGameplayCycleError {
            log.append(.rejected(error))
        }
        log.append(.work(session.takeSynchronousWork()))
        while let barrier = session.outstandingBarrier {
            log.append(.barrier(barrier))
            if barriers == reloadAt {
                session = try roundTrip(session)
                #expect(session.outstandingBarrier == barrier)
            }
            barriers += 1
            try session.acknowledge(barrier.acknowledgement)
            log.append(.work(session.takeSynchronousWork()))
        }
        log.append(.committed(session.cycle))
    }
    return (log, session, barriers)
}

@Test func sourceGameplaySessionReloadAtEveryBarrierIsDeterministic() throws {
    let reference = try runHost(sessionTrace)
    let issued = reference.log.compactMap { observation -> SourceGameplayBarrier? in
        if case .barrier(let barrier) = observation { return barrier }
        return nil
    }
    #expect(issued.count == reference.barriers)
    #expect(issued.map(\.id) == Array(0..<reference.barriers))
    #expect(reference.session.nextBarrierID == reference.barriers)
    #expect(issued.contains { $0.effect == .prepareNextPeriodSceneBarrier })
    #expect(issued.contains { $0.effect == .finishMapMoveAndWaitForSceneBarrier })
    #expect(issued.contains { $0.effect == .replacePeriodAfterADVBarrier(.lunchTime) })
    #expect(issued.contains { $0.effect == .ensurePlayerCreatedAndInitialized })
    #expect(reference.log.contains(.rejected(.mapMoveNotAvailable)))
    #expect(reference.log.contains(.rejected(.invalidWeekAdvance(-1))))
    #expect(reference.session.cycle.week == .wednesday)
    #expect(reference.session.cycle.period == .wakeUp)
    #expect(reference.barriers == 52)

    for index in 0..<reference.barriers {
        let resumed = try runHost(sessionTrace, reloadAt: index)
        #expect(resumed.log == reference.log, "reload at barrier \(index)")
        #expect(resumed.session == reference.session, "reload at barrier \(index)")
    }
}

@Test func sourceGameplaySessionSnapshotRejectsUnknownVersionAndInconsistentState() throws {
    var session = SourceGameplaySession(cycle: SourceGameplayCycle(week: .monday))
    try session.perform(.changePeriod(.lunchTime)) // Two released effects, then a barrier.
    var restored = try roundTrip(session)
    #expect(restored.takeSynchronousWork() == [.updateTimeZone(1), .updateMapSunlight(.lunchTime)])
    #expect(restored.outstandingBarrier == session.outstandingBarrier)

    let data = try JSONEncoder().encode(session)
    let parsed = try JSONSerialization.jsonObject(with: data)
    let object = try #require(parsed as? [String: Any])
    #expect(object["schemaVersion"] as? Int == SourceGameplaySession.schemaVersion)
    func edited(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var copy = object
        edit(&copy)
        return try JSONSerialization.data(withJSONObject: copy)
    }
    func editedTransition(_ key: String, _ value: Any) throws -> Data {
        try edited { root in
            var transition = root["transition"] as? [String: Any] ?? [:]
            transition[key] = value
            root["transition"] = transition
        }
    }
    func isInconsistent(_ data: Data) -> Bool {
        do {
            _ = try JSONDecoder().decode(SourceGameplaySession.self, from: data)
        } catch SourceGameplaySessionError.inconsistentSnapshot(_) {
            return true
        } catch {
            return false
        }
        return false
    }

    #expect(throws: SourceGameplaySessionError.unsupportedSchemaVersion(2)) {
        try JSONDecoder().decode(SourceGameplaySession.self, from: edited { $0["schemaVersion"] = 2 })
    }
    #expect(throws: SourceGameplaySessionError.unsupportedSchemaVersion(0)) {
        try JSONDecoder().decode(SourceGameplaySession.self, from: edited { $0["schemaVersion"] = 0 })
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceGameplaySession.self, from: edited { $0["schemaVersion"] = nil })
    }
    // Positions 0, 1 and 3 are synchronous work; 4 is past the end.
    for released in [0, 1, 3, 4] {
        #expect(isInconsistent(try editedTransition("released", released)), "released \(released)")
    }
    #expect(isInconsistent(try edited { $0["nextBarrierID"] = 3 }))
    #expect(isInconsistent(try editedTransition("firstBarrierID", 1)))
    let tutorial = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SourceGameplayDeferredEffect.openingTutorial))
    #expect(isInconsistent(try edited { $0["synchronousWork"] = [tutorial] }))
    let otherTarget = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SourceGameplayCycle(week: .friday)))
    #expect(isInconsistent(try editedTransition("target", otherTarget)))
    let otherOperation = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SourceGameplayCycleOperation.beginMapMove))
    #expect(isInconsistent(try editedTransition("operation", otherOperation)))

    // The committed cycle itself rejects states no operation can produce.
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceGameplaySession.self, from: edited { root in
            var cycle = root["cycle"] as? [String: Any] ?? [:]
            cycle["timer"] = -1
            root["cycle"] = cycle
        })
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceGameplaySession.self, from: edited { root in
            var cycle = root["cycle"] as? [String: Any] ?? [:]
            cycle["mapMoveActive"] = true
            root["cycle"] = cycle
        })
    }
}
