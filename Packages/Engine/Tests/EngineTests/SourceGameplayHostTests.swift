import Foundation
import Testing
import Gameplay

// A-T01: the native gameplay host over the synthetic catalog shipped in
// Tools/verification/scenarios/gameplay-controlled-event.json (the app lane's
// scenario). No original data, NPC, scene or presentation runs: the host
// completes every barrier from its own state, and the caller can only stage
// operations and step it (`session` is read-only outside the host).

private typealias Entry = SourceGameplayHost.TraceEntry

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

private func shippedScenario() throws -> SourceGameplayHostScenario {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("Tools/verification/scenarios/gameplay-controlled-event.json")
    return try SourceGameplayHostScenario.decode(Data(contentsOf: url))
}

/// The shipped start state, optionally with other heroines or another program for event 9001.
private func controlledHost(heroines: [SourceGameplayNativeState.Heroine]? = nil,
                            commands: [SourceADVProgram.Command]? = nil) throws -> SourceGameplayHost {
    var scenario = try shippedScenario()
    if let heroines { scenario.start.heroines = heroines }
    if let commands { scenario.catalog.programs[0].program = SourceADVProgram(name: "variant", commands: commands) }
    return try scenario.makeHost()
}

/// A barrier as the session issues it (its initializer is internal to Gameplay).
private func barrier(_ id: Int, _ effect: SourceGameplayDeferredEffect) throws -> SourceGameplayBarrier {
    let object: [String: Any] = ["id": id, "effect": try JSONSerialization.jsonObject(with: JSONEncoder().encode(effect))]
    return try JSONDecoder().decode(SourceGameplayBarrier.self, from: JSONSerialization.data(withJSONObject: object))
}

private func reloaded(_ host: SourceGameplayHost) throws -> SourceGameplayHost {
    let data = try host.snapshot()
    let resumed = try SourceGameplayHost.resume(data, catalog: host.catalog)
    #expect(resumed == host)
    #expect(try resumed.snapshot() == data)
    return resumed
}

private func hostError(_ body: () throws -> Void) -> SourceGameplayHostError? {
    do { try body() } catch let error as SourceGameplayHostError { return error } catch { return nil }
    return nil
}

@Test func sourceGameplayHostRunsAControlledEventFromPeriodSelectionToCompletion() throws {
    var host = try controlledHost()
    #expect(host.isIdle)
    var log = try host.perform(.nextPeriod())
    // Period selection is staged; the committed period moves only after its barriers.
    #expect(host.session.cycle.period == .wakeUp)
    #expect(!host.readyForCommand)
    log += try host.run()

    let expected: [Entry] = try [
        .staged(.nextPeriod()),
        .acknowledged(barrier(0, .prepareNextPeriodSceneBarrier)),
        .performed(.updateTimeZone(0)), .performed(.updateMapSunlight(.morning)),
        .acknowledged(barrier(1, .replacePeriodAfterADVBarrier(.morning))),
        .performed(.setMiniMapAndCameraActive(false)), .performed(.clearPlayerNextFlag),
        .committed(.nextPeriod(), period: .morning, week: .monday),
        // The Morning routine selects heroine 1's first unfinished event.
        .eventSelected(heroineID: 1, assetID: 9001, mapNo: 1),
        // VAR, Calc, IF (jump to "met"), Wait 0.5 s; then two 0.25 s frames.
        .advFrame(assetID: 9001, batch: 2, pc: 7, status: "waiting"),
        .advFrame(assetID: 9001, batch: 2, pc: 7, status: "waiting"),
        .advFrame(assetID: 9001, batch: 3, pc: 8, status: "awaitingHost"),
        // MapChange: the host loads the map, then acknowledges the request.
        .mapLoadStarted(requestID: 0, from: 1, to: 2),
        .mapLoaded(requestID: 0, map: 2),
        .advFrame(assetID: 9001, batch: 4, pc: 10, status: "closed"),
        .eventCompleted(heroineID: 1, assetID: 9001),
    ]
    #expect(log == expected)
    #expect(host.isIdle)
    #expect(host.session.cycle.period == .morning)
    #expect(host.session.nextBarrierID == 2)
    #expect(host.state.activeMap == 2)
    #expect(host.state.completedEvents == [9001])
    #expect(host.state.timeZone == 0)
    #expect(host.state.mapSunlight == SourceGameplayNativeState.MapSunlight(map: 1, period: .morning))
    #expect(!host.state.player.nextFlag)
    let noEvent = host.event == nil
    #expect(noEvent)
    let idleStep = try host.step()
    #expect(idleStep.isEmpty)
}

@Test func sourceGameplayHostHoldsPeriodChangesUntilTheRunningEventEnds() throws {
    var host = try controlledHost()
    _ = try host.perform(.nextPeriod())
    _ = try host.run(until: { $0.mapLoad != nil })
    #expect(host.event?.selection.assetID == 9001)

    // Direct Change(Type) during the event: its inline work runs at once, the
    // ADV-gated period-routine replacement waits for the event to end.
    _ = try host.perform(.changePeriod(.hr1))
    let held = try #require(host.session.outstandingBarrier)
    #expect(held.effect == .replacePeriodAfterADVBarrier(.hr1))
    var log: [Entry] = []
    while host.event != nil {
        log += try host.step()
        #expect(host.session.cycle.period == .morning)
        #expect(host.session.outstandingBarrier == held)
    }
    let duringEvent: [Entry] = [
        .performed(.updateTimeZone(0)), .performed(.updateMapSunlight(.hr1)),
        .mapLoaded(requestID: 0, map: 2),
        .advFrame(assetID: 9001, batch: 4, pc: 10, status: "closed"),
        .eventCompleted(heroineID: 1, assetID: 9001),
    ]
    #expect(log == duringEvent)
    // Sunlight ran inline while the old map was still active.
    #expect(host.state.mapSunlight == SourceGameplayNativeState.MapSunlight(map: 1, period: .hr1))
    let afterEvent: [Entry] = [
        .acknowledged(held), .performed(.setMiniMapAndCameraActive(false)),
        .committed(.changePeriod(.hr1), period: .hr1, week: .monday),
        // The completed event is skipped; no other event is scheduled.
        .noEventSelected(.hr1),
    ]
    let rest = try host.run()
    #expect(rest == afterEvent)

    // _Next during an event waits at its scene barrier, so its inline work
    // (here sunlight) follows the map load.
    host = try controlledHost()
    _ = try host.perform(.nextPeriod())
    _ = try host.run(until: { $0.mapLoad != nil })
    _ = try host.perform(.nextPeriod())
    let scene = try #require(host.session.outstandingBarrier)
    #expect(scene.effect == .prepareNextPeriodSceneBarrier)
    while host.event != nil {
        _ = try host.step()
        #expect(host.session.outstandingBarrier == scene)
        #expect(host.state.mapSunlight == SourceGameplayNativeState.MapSunlight(map: 1, period: .morning))
    }
    _ = try host.run()
    #expect(host.session.cycle.period == .gotoSchool)
    #expect(host.state.mapSunlight == SourceGameplayNativeState.MapSunlight(map: 2, period: .gotoSchool))
    #expect(host.isIdle)
}

private enum Drive: Sendable {
    case perform(SourceGameplayCycleOperation)
    case run(SourceGameplayHostScenario.StopCondition)
}

private struct ReloadPoint {
    var barrier: SourceGameplayBarrier?
    var mapLoading: Bool
    var advWaiting: Bool
    var eventRunning: Bool
}

private struct DriveResult {
    var log: [Entry] = []
    var host: SourceGameplayHost
    var steps = 0
    var reloadPoint: ReloadPoint?
}

/// Period selection, a mid-event period change, a backward day change that
/// must not rerun the completed event, and a plain _Next.
private let controlledScript: [Drive] = [
    .perform(.nextPeriod()), .run(.mapLoading), .perform(.changePeriod(.hr1)), .run(.idle),
    .perform(.changePeriod(.morning)), .run(.idle), .perform(.nextPeriod()), .run(.idle),
]

/// Runs `script`, round-tripping the whole host through JSON before step
/// `reloadBefore` (zero-based over every `step()` call).
private func drive(_ start: SourceGameplayHost, _ script: [Drive], reloadBefore: Int? = nil) throws -> DriveResult {
    var result = DriveResult(host: start)
    for item in script {
        switch item {
        case .perform(let operation):
            result.log += try result.host.perform(operation)
        case .run(let stop):
            while !stop.holds(result.host) {
                if result.steps == reloadBefore {
                    let host = result.host
                    result.reloadPoint = ReloadPoint(barrier: host.session.outstandingBarrier, mapLoading: host.mapLoad != nil,
                                                     advWaiting: host.event?.interpreter.waits.isEmpty == false,
                                                     eventRunning: host.event != nil)
                    result.host = try reloaded(host)
                }
                result.steps += 1
                let entries = try result.host.step()
                if entries.isEmpty { break }
                result.log += entries
            }
        }
    }
    return result
}

@Test func sourceGameplayHostReloadAtEveryStepResumesIdentically() throws {
    let start = try controlledHost()
    let reference = try drive(start, controlledScript)
    #expect(reference.host.session.cycle.period == .gotoSchool)
    #expect(reference.host.session.cycle.week == .tuesday)
    #expect(reference.host.state.savedWeek == .tuesday)
    #expect(reference.host.state.completedEvents == [9001])
    #expect(reference.host.state.heroines.map(\.dailyIncrements) == [1])
    #expect(reference.host.state.heroines.map(\.eventAfterDay) == [1])
    let selections = reference.log.filter { entry in
        if case .eventSelected = entry { return true }
        return false
    }
    #expect(selections.count == 1) // Tuesday Morning does not rerun the completed event.
    #expect(reference.steps > 15)

    var points: [ReloadPoint] = []
    for index in 0..<reference.steps {
        let resumed = try drive(start, controlledScript, reloadBefore: index)
        #expect(resumed.log == reference.log, "reload before step \(index)")
        #expect(resumed.host == reference.host, "reload before step \(index)")
        if let point = resumed.reloadPoint { points.append(point) }
    }
    #expect(points.count == reference.steps)
    // The reloads cover both session barriers, the ADV-gated one while the
    // event runs, the MapChange load and the ADV Wait.
    let sceneBarrier = points.contains { $0.barrier?.effect == .prepareNextPeriodSceneBarrier }
    let heldADVBarrier = points.contains { $0.eventRunning && $0.barrier?.effect == .replacePeriodAfterADVBarrier(.hr1) }
    let idleADVBarrier = points.contains { !$0.eventRunning && $0.barrier?.effect == .replacePeriodAfterADVBarrier(.morning) }
    let mapLoad = points.contains { $0.mapLoading }
    let advWait = points.contains { $0.advWaiting }
    #expect(sceneBarrier)
    #expect(heldADVBarrier)
    #expect(idleADVBarrier)
    #expect(mapLoad)
    #expect(advWait)
}

@Test func sourceGameplayHostAppliesPeriodWeekAndMapEffectsAndRejectsUnsupportedOperations() throws {
    let heroines: [SourceGameplayNativeState.Heroine] = [.init(id: 1, fixCharaID: -5), .init(id: 2, fixCharaID: 0, eventAfterDay: 3)]
    var host = try controlledHost(heroines: heroines)

    // Forward Change(Type) into an action period: zone 1, sunlight on the
    // active map, minimap and camera on; event 9001 is not a LunchTime event.
    var log = try host.perform(.changePeriod(.lunchTime))
    log += try host.run()
    #expect(log.last == .noEventSelected(.lunchTime))
    #expect(host.session.cycle.period == .lunchTime)
    #expect(host.state.timeZone == 1)
    #expect(host.state.mapSunlight == SourceGameplayNativeState.MapSunlight(map: 1, period: .lunchTime))
    #expect(host.state.miniMapAndCameraActive)
    #expect(host.state.savedWeek == .monday)

    // MapMove needs NPC loading, the tutorial and camera/cut-in hosts.
    var before = host
    #expect(throws: SourceGameplayHostError.unsupportedOperation(.beginMapMove, .loadNPCs(shuffle: true))) {
        try host.perform(.beginMapMove)
    }
    #expect(throws: SourceGameplayCycleError.mapMoveNotActive) { try host.perform(.finishMapMove) }
    #expect(host == before)

    // A backward change advances the weekday: saved and shown weekday, and the
    // daily increment per heroine (event-after days only for fixCharaID <= -5).
    log = try host.perform(.changePeriod(.morning))
    log += try host.run(until: { $0.event != nil })
    #expect(log.contains(.performed(.advanceCharacterDays(1))))
    #expect(host.session.cycle.week == .tuesday)
    #expect(host.state.savedWeek == .tuesday)
    #expect(host.state.displayedWeek == .tuesday)
    #expect(host.state.heroines.map(\.dailyIncrements) == [1, 1])
    #expect(host.state.heroines.map(\.eventAfterDay) == [1, 3])
    #expect(!host.state.miniMapAndCameraActive)
    #expect(host.event?.selection.assetID == 9001)
    _ = try host.run()
    #expect(host.state.activeMap == 2)
    #expect(host.state.completedEvents == [9001])

    // nextWeek(7) is a direct Change(Week): seven days and no period routine.
    log = try host.perform(.nextWeek(7))
    log += try host.run()
    let week: [Entry] = [
        .staged(.nextWeek(7)), .performed(.updateWeekDisplay(.tuesday)), .performed(.persistWeek(.tuesday)),
        .performed(.advanceCharacterDays(7)), .committed(.nextWeek(7), period: .morning, week: .tuesday),
    ]
    #expect(log == week)
    #expect(host.state.heroines.map(\.dailyIncrements) == [8, 8])
    #expect(host.state.heroines.map(\.eventAfterDay) == [8, 3])

    // Sunlight follows the active map; the night-menu tail is unsupported.
    _ = try host.perform(.changePeriod(.myHouse))
    _ = try host.run()
    #expect(host.state.mapSunlight == SourceGameplayNativeState.MapSunlight(map: 2, period: .myHouse))
    #expect(host.state.timeZone == 4)
    before = host
    #expect(throws: SourceGameplayHostError.unsupportedOperation(.completeNightMenu(), .correctGameParameters)) {
        try host.perform(.completeNightMenu())
    }
    #expect(host == before)

    // A command while an operation is staged is refused without mutation.
    _ = try host.perform(.nextPeriod())
    before = host
    let busy = hostError { _ = try host.perform(.changeWeek(.friday)) }
    var refused = false
    if case .hostBusy? = busy { refused = true }
    #expect(refused)
    #expect(host == before)
    _ = try host.run()
    // _Next from MyHouse wraps to WakeUp without a day change.
    #expect(host.session.cycle.period == .wakeUp)
    #expect(host.session.cycle.week == .tuesday)
    #expect(host.isIdle)
}

@Test func sourceGameplayHostStopsOnRequestsAndCommandsItCannotPerform() throws {
    let cases: [([SourceADVProgram.Command], SourceGameplayHostError)] = [
        ([.init(id: 16, args: ["Synthetic", "Synthetic line."])],
         .unsupportedRequest(requestID: 0, detail: "text needs a presentation host")),
        ([.init(id: 169, args: ["Nowhere", "None"])], .unknownMap("Nowhere")),
        ([.init(id: 169, args: ["7", "None"])], .unknownMap("7")),
        // The default fade is InOut, which needs a presentation host.
        ([.init(id: 169, args: ["SyntheticHall"])],
         .unsupportedRequest(requestID: 0, detail: "mapChange with fade InOut needs a presentation host")),
    ]
    for (commands, error) in cases {
        var host = try controlledHost(commands: commands)
        _ = try host.perform(.nextPeriod())
        _ = try host.run(until: { $0.event?.interpreter.requests.isEmpty == false })
        let before = host
        #expect(throws: error) { try host.step() }
        #expect(host == before, "\(error)")
        // The failure is deterministic: the event never completes by itself.
        #expect(throws: error) { try host.step() }
    }

    // An unported ADV command faults the frame; the host keeps its last state.
    var host = try controlledHost(commands: [.init(id: 165)])
    _ = try host.perform(.nextPeriod())
    _ = try host.run(until: { $0.event != nil })
    let before = host
    #expect(throws: SourceGameplayExecutionError.unsupported("ADV command ID 165 at pc 0")) { try host.step() }
    #expect(host == before)
}

// MARK: - Snapshots

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FixtureError(description: "not a JSON object")
    }
    return object
}

private func setting(_ object: [String: Any], _ path: ArraySlice<String>, _ value: Any?) -> [String: Any] {
    var copy = object
    guard let key = path.first else { return copy }
    if path.count == 1 {
        copy[key] = value
    } else {
        copy[key] = setting(copy[key] as? [String: Any] ?? [:], path.dropFirst(), value)
    }
    return copy
}

/// `data` with the dotted key path set to `value` (nil removes the key).
private func edited(_ data: Data, _ path: String, _ value: Any?) throws -> Data {
    let keys = path.split(separator: ".").map { String($0) }
    return try JSONSerialization.data(withJSONObject: setting(try jsonObject(data), keys[...], value))
}

private func encodedJSON<Value: Encodable>(_ value: Value) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

private func isInconsistentState(_ data: Data, _ catalog: SourceGameplayEventCatalog) -> Bool {
    do {
        _ = try SourceGameplayHost.resume(data, catalog: catalog)
    } catch SourceGameplayHostError.inconsistentState(_) {
        return true
    } catch {
        return false
    }
    return false
}

@Test func sourceGameplayHostSnapshotRejectsCorruptedAndMismatchedDataByName() throws {
    var host = try controlledHost()
    _ = try host.perform(.nextPeriod())
    _ = try host.run(until: { $0.mapLoad != nil })
    let catalog = host.catalog
    let data = try host.snapshot()
    #expect(try SourceGameplayHost.resume(data, catalog: catalog) == host)
    let root = try jsonObject(data)
    #expect(root["format"] as? String == SourceGameplayHost.format)
    #expect(root["schemaVersion"] as? Int == SourceGameplayHost.schemaVersion)

    // Not a host snapshot, another version, too large, or saved with other content.
    #expect(throws: SourceGameplayHostError.unsupportedSchemaVersion(2)) {
        try SourceGameplayHost.resume(edited(data, "schemaVersion", 2), catalog: catalog)
    }
    #expect(throws: SourceGameplayHostError.unrecognizedSnapshot("other")) {
        try SourceGameplayHost.resume(edited(data, "format", "other"), catalog: catalog)
    }
    #expect(throws: SourceGameplayHostError.unrecognizedSnapshot(nil)) {
        try SourceGameplayHost.resume(edited(data, "format", nil), catalog: catalog)
    }
    #expect(throws: SourceGameplayHostError.unrecognizedSnapshot(nil)) {
        try SourceGameplayHost.resume(JSONEncoder().encode(host.session), catalog: catalog)
    }
    let oversized = Data(count: SourceGameplayHost.snapshotLimit + 1)
    #expect(throws: SourceGameplayHostError.snapshotTooLarge(SourceGameplayHost.snapshotLimit + 1)) {
        try SourceGameplayHost.resume(oversized, catalog: catalog)
    }
    var otherCatalog = catalog
    otherCatalog.mapNumbers["SyntheticAttic"] = 3
    #expect(throws: SourceGameplayHostError.catalogMismatch(expected: catalog.name, found: catalog.name)) {
        try SourceGameplayHost.resume(data, catalog: otherCatalog)
    }
    #expect(throws: SourceGameplayHostError.invalidCatalog("fixed event 9001 has no ADV program")) {
        try SourceGameplayHost.resume(edited(data, "catalog.programs", [Any]()), catalog: catalog)
    }
    #expect(throws: DecodingError.self) { try SourceGameplayHost.resume(data.prefix(data.count / 2), catalog: catalog) }

    // States no host operation can produce.
    let heroines = try #require(root["state"] as? [String: Any])["heroines"] as? [Any]
    let duplicated: [Any] = (heroines ?? []) + (heroines ?? [])
    let tampered: [(String, Data)] = try [
        ("active map outside the catalog", edited(data, "state.activeMap", 99)),
        ("program differs from the catalog", edited(data, "event.interpreter.program.name", "tampered")),
        ("running event already completed", edited(data, "state.completedEvents", [9001])),
        ("running event of an unsaved heroine", edited(data, "event.heroineID", 2)),
        ("pending MapChange without its load", edited(data, "mapLoad", nil)),
        ("map load outside the catalog", edited(data, "mapLoad.to", 99)),
        ("period entry during the event", edited(data, "periodEntryPending", true)),
        ("zero frame duration", edited(data, "frameDelta", 0)),
        ("negative frame duration", edited(data, "frameDelta", -0.25)),
        ("duplicate heroines", edited(data, "state.heroines", duplicated)),
    ]
    for (label, tamperedData) in tampered {
        #expect(isInconsistentState(tamperedData, catalog), Comment(rawValue: label))
    }

    // The nested session and interpreter reject their own corruption by name.
    _ = try host.perform(.changePeriod(.hr1))
    let midBarrier = try host.snapshot()
    #expect(try SourceGameplayHost.resume(midBarrier, catalog: catalog) == host)
    #expect(isInconsistentState(try edited(midBarrier, "stagedOperation", encodedJSON(SourceGameplayCycleOperation.nextPeriod())),
                                catalog))
    #expect(isInconsistentState(try edited(midBarrier, "stagedOperation", nil), catalog))
    var sessionRejected = false
    do {
        _ = try SourceGameplayHost.resume(edited(midBarrier, "session.nextBarrierID", 9), catalog: catalog)
    } catch SourceGameplaySessionError.inconsistentSnapshot(_) {
        sessionRejected = true
    }
    #expect(sessionRejected)
    #expect(throws: SourceGameplayExecutionError.invalidData("ADV interpreter state limits")) {
        try SourceGameplayHost.resume(edited(midBarrier, "event.interpreter.pc", 999), catalog: catalog)
    }
}

// MARK: - Shipped scenario (the app's IKKOKU_GAMEPLAY_SCENARIO run)

@Test func sourceGameplayHostShippedScenarioPersistsReloadsAndResumesIdentically() throws {
    let scenario = try shippedScenario()
    var stored: [String: Data] = [:]
    let report = scenario.run { data, path in
        if let path { stored[path] = data }
        return data
    }
    let failures = report.steps.filter { !$0.ok }.map { "\($0.op): \($0.detail)" }.joined(separator: "; ")
    #expect(report.failed == 0, Comment(rawValue: failures))
    #expect(report.passed == scenario.steps.count + 1)
    #expect(report.reloads.map(\.step) == [5, 8, 12])
    #expect(Set(stored.keys) == Set(scenario.steps.compactMap(\.path)))
    #expect(stored.keys.allSatisfy { $0.hasPrefix(".local/verification/") })
    #expect(report.saveFormat.contains("not original SaveData"))
    let summary = try #require(report.finalState)
    #expect(summary.period == "Morning")
    #expect(summary.week == "Tuesday")
    #expect(summary.savedWeek == "Tuesday")
    #expect(summary.activeMap == 2)
    #expect(summary.completedEvents == [9001])
    #expect(summary.idle)

    // The ADV-gated period change acknowledges only after the event completed.
    let completed = try #require(report.trace.firstIndex(of: .eventCompleted(heroineID: 1, assetID: 9001)))
    let hr1Index = report.trace.firstIndex { entry in
        if case .acknowledged(let barrier) = entry { return barrier.effect == .replacePeriodAfterADVBarrier(.hr1) }
        return false
    }
    let hr1 = try #require(hr1Index)
    #expect(completed < hr1)

    // Without the reloads, the trace and the final state are identical.
    var plain = scenario
    plain.steps.removeAll { $0.op == "reload" }
    let uninterrupted = plain.run { data, _ in data }
    #expect(uninterrupted.failed == 0)
    #expect(uninterrupted.trace == report.trace)
    #expect(uninterrupted.finalState == report.finalState)

    // The report is the JSON object the app writes.
    let parsed = try JSONSerialization.jsonObject(with: report.json())
    #expect(parsed is [String: Any])
}

@Test func sourceGameplayHostScenarioStopsAtACorruptedReload() throws {
    let scenario = try shippedScenario()
    // The store hands back other bytes for the mid-barrier reload (step 8).
    let report = scenario.run { data, path in
        path?.contains("adv-barrier") == true ? Data("{}".utf8) : data
    }
    #expect(report.steps.count == scenario.steps.count + 1)
    let failedStep = report.steps[9]
    #expect(failedStep.op == "reload")
    #expect(!failedStep.ok)
    #expect(failedStep.detail.contains("Not a gameplay host snapshot"))
    #expect(report.steps[..<9].allSatisfy { $0.ok })
    #expect(report.steps[10...].allSatisfy { !$0.ok && $0.detail.hasPrefix("not run") })
    #expect(report.failed == report.steps.count - 9)
    #expect(report.reloads.map(\.step) == [5])
}
