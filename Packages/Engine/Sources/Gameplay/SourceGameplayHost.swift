import Foundation

// A-T01: the native gameplay host. `SourceGameplaySession` (G-T01) orders what
// the cycle owes; this host owns the native state those effects change, runs
// the fixed event a period selects through `SourceADVInterpreter`, and
// completes each barrier from its own state instead of from caller-injected
// completions. Contract: docs/reference/gameplay/cycle.md ("Gameplay host").

/// Controlled content a `SourceGameplayHost` plays: fixed-event schedules, the
/// ADV program of each event, map names and wait points. The verification
/// scenario supplies a synthetic catalog; no original table or scenario is
/// bundled.
public struct SourceGameplayEventCatalog: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    /// The ADV program a fixed event runs, keyed by the event's asset ID
    /// (`SourceFixedEventScheduler.Selection.assetID`).
    public struct EventProgram: Codable, Sendable, Equatable {
        public var assetID: Int
        public var program: SourceADVProgram
        public init(assetID: Int, program: SourceADVProgram) {
            self.assetID = assetID
            self.program = program
        }
    }

    public var schemaVersion: Int
    public var name: String
    /// Fixed-event schedules and class lessons in the converted table format.
    public var fixedEvents: SourceFixedEventTable
    /// Native `Map.ConvertMapNo`: map name to map number, for fixed-event
    /// entries and MapChange requests. Only these maps exist for the host.
    public var mapNumbers: [String: Int]
    public var waitPoints: [SourceFixedEventScheduler.WaitPoint]
    public var programs: [EventProgram]

    public func program(for assetID: Int) -> SourceADVProgram? {
        programs.first { $0.assetID == assetID }?.program
    }

    /// Schema, limits and completeness: every fixed-event asset parses as the
    /// scheduler's Int32 and has exactly one ADV program.
    public func validate() throws {
        func invalid(_ detail: String) -> SourceGameplayHostError { .invalidCatalog(detail) }
        guard schemaVersion == Self.schemaVersion else { throw invalid("unsupported catalog schema version \(schemaVersion)") }
        guard name.utf8.count <= 4096 else { throw invalid("name exceeds 4096 bytes") }
        do { try fixedEvents.validate() } catch { throw invalid("fixed-event table schema or limits") }
        guard mapNumbers.count <= 10_000, waitPoints.count <= 100_000, programs.count <= 10_000 else {
            throw invalid("map, wait-point or program count limit")
        }
        guard Set(programs.map(\.assetID)).count == programs.count else { throw invalid("duplicate event program asset IDs") }
        for item in programs {
            do { try item.program.validate() } catch { throw invalid("event \(item.assetID) ADV program schema or limits") }
        }
        for schedule in fixedEvents.schedules {
            for entry in schedule.entries {
                guard let id = Int32(entry.asset.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw invalid("fixed-event asset '\(entry.asset)' is not an Int32")
                }
                guard program(for: Int(id)) != nil else { throw invalid("fixed event \(id) has no ADV program") }
            }
        }
    }
}

/// Native, versioned save state the host owns (A-T01). This is **not** the
/// original `SaveData` layout and holds no recovered campaign state (G12):
/// each field is a native placeholder for the source value its comment names,
/// changed only by the host operation that performs the matching effect.
public struct SourceGameplayNativeState: Codable, Sendable, Equatable {
    public struct Player: Codable, Sendable, Equatable {
        /// Placeholder for the source player's next flag. `clearPlayerNextFlag`
        /// clears it; no native code sets it yet.
        public var nextFlag: Bool
        public init(nextFlag: Bool = false) { self.nextFlag = nextFlag }
    }

    /// Placeholder for one saved heroine. `id` is the fixed-event schedule's
    /// heroine ID; no original character data is bound (G-T02).
    public struct Heroine: Codable, Sendable, Equatable {
        public var id: Int
        public var fixCharaID: Int
        public var classIndex: Int
        public var isTaked: Bool
        public var eventAfterDay: Int
        /// How many times the host applied the source per-heroine daily
        /// increment (`advanceCharacterDays`); the original counters it would
        /// change are not modelled.
        public var dailyIncrements: Int
        public init(id: Int, fixCharaID: Int = 0, classIndex: Int = 0, isTaked: Bool = false,
                    eventAfterDay: Int = 0, dailyIncrements: Int = 0) {
            self.id = id
            self.fixCharaID = fixCharaID
            self.classIndex = classIndex
            self.isTaked = isTaked
            self.eventAfterDay = eventAfterDay
            self.dailyIncrements = dailyIncrements
        }
    }

    /// The map and period of the last `updateMapSunlight`.
    public struct MapSunlight: Codable, Sendable, Equatable {
        public var map: Int
        public var period: SourceGameplayPeriod
    }

    /// The weekday `persistWeek` saved.
    public var savedWeek: SourceGameplayWeek
    /// The weekday `updateWeekDisplay` shows.
    public var displayedWeek: SourceGameplayWeek
    /// The clock zone `updateTimeZone` set.
    public var timeZone: Int
    public var mapSunlight: MapSunlight?
    /// `setMiniMapAndCameraActive`; native default false.
    public var miniMapAndCameraActive: Bool
    /// The loaded map's number; a MapChange replaces it when its load ends.
    public var activeMap: Int
    public var player: Player
    public var heroines: [Heroine]
    /// Completed fixed-event asset IDs in completion order; the scheduler
    /// skips them, so a completed event does not run again.
    public var completedEvents: [Int]

    /// The state of a new native session on `cycle`: its weekday saved and
    /// shown, its period's clock zone, no sunlight applied yet.
    public init(cycle: SourceGameplayCycle, activeMap: Int, heroines: [Heroine] = [], player: Player = Player()) {
        savedWeek = cycle.week
        displayedWeek = cycle.week
        timeZone = cycle.period.timeZone
        mapSunlight = nil
        miniMapAndCameraActive = false
        self.activeMap = activeMap
        self.player = player
        self.heroines = heroines
        completedEvents = []
    }

    func validate(against catalog: SourceGameplayEventCatalog) throws {
        func inconsistent(_ detail: String) -> SourceGameplayHostError { .inconsistentState(detail) }
        let maps = Set(catalog.mapNumbers.values)
        guard maps.contains(activeMap) else { throw inconsistent("active map \(activeMap) is not in the catalog") }
        if let mapSunlight, !maps.contains(mapSunlight.map) {
            throw inconsistent("sunlight map \(mapSunlight.map) is not in the catalog")
        }
        guard (0...4).contains(timeZone) else { throw inconsistent("clock zone \(timeZone) is outside 0...4") }
        guard heroines.count <= 10_000, Set(heroines.map(\.id)).count == heroines.count else {
            throw inconsistent("heroine IDs must be unique (at most 10,000 heroines)")
        }
        guard heroines.allSatisfy({ $0.eventAfterDay >= 0 && $0.dailyIncrements >= 0 }) else {
            throw inconsistent("heroine day counters must be nonnegative")
        }
        guard completedEvents.count <= 100_000, Set(completedEvents).count == completedEvents.count else {
            throw inconsistent("completed events must be unique")
        }
        guard completedEvents.allSatisfy({ catalog.program(for: $0) != nil }) else {
            throw inconsistent("a completed event is not in the catalog")
        }
    }
}

public enum SourceGameplayHostError: Error, Equatable, LocalizedError {
    /// The operation would release an effect this host cannot perform.
    case unsupportedOperation(SourceGameplayCycleOperation, SourceGameplayDeferredEffect)
    case unsupportedEffect(SourceGameplayDeferredEffect)
    /// A command arrived while released work, a barrier, a commit or a period
    /// entry was still pending.
    case hostBusy(String)
    /// Nothing the host runs can complete this barrier.
    case barrierBlocked(SourceGameplayBarrier)
    /// The running event issued a request this non-presenting host cannot perform.
    case unsupportedRequest(requestID: Int, detail: String)
    case unknownMap(String)
    case missingEventProgram(Int)
    case counterOverflow(String)
    case stepBudgetExceeded(Int)
    case invalidCatalog(String)
    case inconsistentState(String)
    /// The data is not a host snapshot; carries the format marker found.
    case unrecognizedSnapshot(String?)
    case unsupportedSchemaVersion(Int)
    case snapshotTooLarge(Int)
    /// The snapshot was saved with other content than the catalog supplied.
    case catalogMismatch(expected: String, found: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let operation, let effect):
            "The gameplay host cannot perform \(effect), which \(operation) would release."
        case .unsupportedEffect(let effect): "The gameplay host cannot perform \(effect)."
        case .hostBusy(let reason): "The gameplay host cannot take a command yet: \(reason)."
        case .barrierBlocked(let barrier):
            "Gameplay barrier \(barrier.id) (\(barrier.effect)) waits on work the host is not running."
        case .unsupportedRequest(let id, let detail): "ADV request \(id) is unsupported by the gameplay host: \(detail)."
        case .unknownMap(let map): "Map \(map) is not in the gameplay host's catalog."
        case .missingEventProgram(let id): "Fixed event \(id) has no ADV program."
        case .counterOverflow(let detail): "Gameplay host counter overflow: \(detail)."
        case .stepBudgetExceeded(let steps): "The gameplay host did not settle within \(steps) steps."
        case .invalidCatalog(let detail): "Invalid gameplay event catalog: \(detail)."
        case .inconsistentState(let detail): "Inconsistent gameplay host state: \(detail)."
        case .unrecognizedSnapshot(let format): "Not a gameplay host snapshot (format \(format ?? "missing"))."
        case .unsupportedSchemaVersion(let version): "Unsupported gameplay host schema version \(version)."
        case .snapshotTooLarge(let bytes): "Gameplay host snapshot of \(bytes) bytes exceeds 16 MiB."
        case .catalogMismatch(let expected, let found):
            "The snapshot's event catalog '\(found)' differs from the expected catalog '\(expected)'."
        }
    }
}

/// Native gameplay host (A-T01): one `SourceGameplaySession`, the native state
/// its effects change, the active map and at most one running fixed event.
///
/// A caller stages cycle operations with `perform(_:)` and advances the host
/// with `step()`, one unit of host work at a time, in this priority:
///
/// 1. released synchronous work, applied to the native state in source order;
/// 2. reporting the staged operation's commit once its last barrier and work are done;
/// 3. the outstanding barrier, completed by the host operation it waits for:
///    `prepareNextPeriodSceneBarrier` when no map loads and no event runs
///    (the host treats a running ADV event as an additive scene, conservatively),
///    `replacePeriodAfterADVBarrier` when no ADV event runs, which replaces the
///    period routine;
/// 4. the running event (also while a barrier waits for it): drain its
///    requests, finish a map load, complete it on Close or exhaustion, or tick
///    one frame of `frameDelta` seconds;
/// 5. the new period routine's fixed-event check, which may start an event.
///
/// Operations that would release an effect the host cannot perform (NPC
/// loading, the tutorial, MapMove camera/cut-in, the night-menu tail) are
/// rejected before staging. The running event may issue only MapChange without
/// a fade: this host presents nothing, so any presentation request stops it
/// with `unsupportedRequest` instead of being skipped. A throwing step or
/// command leaves the host unchanged.
///
/// The whole host is `Codable` (schema version 1, format marker
/// `ikkoku.native-gameplay-host`) and resumes identically from any step
/// boundary. It is native state, not an original campaign save (G12).
public struct SourceGameplayHost: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let format = "ikkoku.native-gameplay-host"
    public static let snapshotLimit = 16 * 1024 * 1024

    /// The fixed event a period routine selected, with its ADV interpreter.
    public struct ActiveEvent: Codable, Sendable, Equatable {
        public let heroineID: Int
        public let selection: SourceFixedEventScheduler.Selection
        public fileprivate(set) var interpreter: SourceADVInterpreter
    }

    /// A MapChange whose map load has started and not finished.
    public struct MapLoad: Codable, Sendable, Equatable {
        public let requestID: Int
        public let from: Int
        public let to: Int
    }

    /// One observable host operation, in the order performed.
    public enum TraceEntry: Codable, Sendable, Equatable {
        case staged(SourceGameplayCycleOperation)
        /// Released synchronous work, applied to the native state.
        case performed(SourceGameplayDeferredEffect)
        /// A barrier the host completed and acknowledged.
        case acknowledged(SourceGameplayBarrier)
        /// The staged operation committed and all of its work is performed.
        case committed(SourceGameplayCycleOperation, period: SourceGameplayPeriod, week: SourceGameplayWeek)
        case eventSelected(heroineID: Int, assetID: Int, mapNo: Int)
        case noEventSelected(SourceGameplayPeriod)
        /// One ADV frame (the first one starts the program).
        case advFrame(assetID: Int, batch: Int, pc: Int, status: String)
        case mapLoadStarted(requestID: Int, from: Int, to: Int)
        case mapLoaded(requestID: Int, map: Int)
        /// The completion flag was persisted in `state.completedEvents`.
        case eventCompleted(heroineID: Int, assetID: Int)
    }

    public let catalog: SourceGameplayEventCatalog
    /// Seconds per ADV frame; finite and positive.
    public let frameDelta: Float
    public private(set) var session: SourceGameplaySession
    public private(set) var state: SourceGameplayNativeState
    public private(set) var event: ActiveEvent?
    public private(set) var mapLoad: MapLoad?
    /// The staged operation until its commit is reported.
    public private(set) var stagedOperation: SourceGameplayCycleOperation?
    /// The replaced period routine has not checked fixed events yet.
    public private(set) var periodEntryPending = false

    public init(catalog: SourceGameplayEventCatalog, cycle: SourceGameplayCycle, state: SourceGameplayNativeState,
                frameDelta: Float) throws {
        self.catalog = catalog
        self.frameDelta = frameDelta
        self.session = SourceGameplaySession(cycle: cycle)
        self.state = state
        try validate()
    }

    /// No work is pending that must finish before another cycle operation.
    public var readyForCommand: Bool {
        session.synchronousWork.isEmpty && stagedOperation == nil && !periodEntryPending
    }

    /// Nothing to do until the next command: `step()` would return no entries.
    public var isIdle: Bool { readyForCommand && event == nil }

    /// Whether the host performs `effect`. Exhaustive on purpose: a new effect
    /// does not compile until the host decides.
    public static func supports(_ effect: SourceGameplayDeferredEffect) -> Bool {
        switch effect {
        case .persistWeek, .updateWeekDisplay, .advanceCharacterDays, .updateTimeZone, .updateMapSunlight,
             .setMiniMapAndCameraActive, .clearPlayerNextFlag, .replacePeriodAfterADVBarrier, .prepareNextPeriodSceneBarrier:
            return true
        // No NPC population, tutorial, MapMove presentation, game parameters,
        // companions, player creation, action count or teachers exist yet.
        case .loadNPCs, .openingTutorial, .prepareMapMoveCharactersAndCamera, .startTimeZoneCutIn,
             .finishMapMoveAndWaitForSceneBarrier, .correctGameParameters, .clearCachedCompanions,
             .ensurePlayerCreatedAndInitialized, .resetPlayerActionCount, .clearSaturdayTeachers:
            return false
        }
    }

    /// Stages one cycle operation, such as the period selection that starts a
    /// day's event. The host must be `readyForCommand`; a running event may
    /// continue. Cycle errors propagate; nothing changes on a throw.
    @discardableResult
    public mutating func perform(_ operation: SourceGameplayCycleOperation) throws -> [TraceEntry] {
        guard readyForCommand else { throw SourceGameplayHostError.hostBusy(busyReason) }
        var probe = session.cycle
        let effects = try probe.apply(operation)
        if let missing = effects.first(where: { !Self.supports($0) }) {
            throw SourceGameplayHostError.unsupportedOperation(operation, missing)
        }
        try session.perform(operation)
        stagedOperation = operation
        return [.staged(operation)]
    }

    /// Performs the next unit of host work and returns what it did; an empty
    /// result means the host is idle. A throw leaves the host unchanged.
    public mutating func step() throws -> [TraceEntry] {
        var next = self
        let entries = try next.advance()
        self = next
        return entries
    }

    /// Steps until `stop` holds before a step or the host is idle. Each step
    /// commits on its own, so a budget error keeps the steps already made.
    public mutating func run(maxSteps: Int = 10_000,
                             until stop: (SourceGameplayHost) -> Bool = { _ in false }) throws -> [TraceEntry] {
        var entries: [TraceEntry] = []
        var steps = 0
        while !stop(self) {
            guard steps < maxSteps else { throw SourceGameplayHostError.stepBudgetExceeded(maxSteps) }
            let next = try step()
            if next.isEmpty { break }
            entries += next
            steps += 1
        }
        return entries
    }

    /// Canonical JSON (sorted keys) of the whole host.
    public func snapshot() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes and validates a snapshot, requiring it to carry `catalog`.
    public static func resume(_ data: Data, catalog: SourceGameplayEventCatalog) throws -> SourceGameplayHost {
        guard data.count <= snapshotLimit else { throw SourceGameplayHostError.snapshotTooLarge(data.count) }
        let host = try JSONDecoder().decode(SourceGameplayHost.self, from: data)
        guard host.catalog == catalog else {
            throw SourceGameplayHostError.catalogMismatch(expected: catalog.name, found: host.catalog.name)
        }
        return host
    }

    // MARK: - Host work

    private var busyReason: String {
        if let barrier = session.outstandingBarrier { return "barrier \(barrier.id) (\(barrier.effect)) is outstanding" }
        if !session.synchronousWork.isEmpty { return "\(session.synchronousWork.count) released effect(s) are not performed" }
        if let stagedOperation { return "\(stagedOperation) has not reported its commit" }
        return "the new period's fixed-event check has not run"
    }

    private mutating func advance() throws -> [TraceEntry] {
        let work = session.takeSynchronousWork()
        if !work.isEmpty {
            var entries: [TraceEntry] = []
            for effect in work {
                try performWork(effect)
                entries.append(.performed(effect))
            }
            if let commit = reportCommit() { entries.append(commit) }
            return entries
        }
        if let commit = reportCommit() { return [commit] }
        let barrier = session.outstandingBarrier
        if let barrier, try completeBarrier(barrier) {
            try session.acknowledge(barrier.acknowledgement)
            return [.acknowledged(barrier)]
        }
        if event != nil { return try advanceEvent() }
        if let barrier { throw SourceGameplayHostError.barrierBlocked(barrier) }
        if periodEntryPending { return [try enterPeriod()] }
        return []
    }

    private mutating func reportCommit() -> TraceEntry? {
        guard let operation = stagedOperation, session.transition == nil, session.synchronousWork.isEmpty else { return nil }
        stagedOperation = nil
        return .committed(operation, period: session.cycle.period, week: session.cycle.week)
    }

    /// Performs the host side of `barrier`; false while it waits on the running event.
    private mutating func completeBarrier(_ barrier: SourceGameplayBarrier) throws -> Bool {
        switch barrier.effect {
        case .prepareNextPeriodSceneBarrier:
            // _Next waits for additive scenes, map loading and fade. Maps load
            // only for a running event, the host presents no fades, and the
            // running ADV event counts as an additive scene (not recovered;
            // waiting is the conservative choice).
            return event == nil && mapLoad == nil
        case .replacePeriodAfterADVBarrier:
            // Change(Type) replaces the period coroutine only after ADV
            // processing ends; the new period's routine then runs.
            guard event == nil else { return false }
            periodEntryPending = true
            return true
        default:
            throw SourceGameplayHostError.unsupportedEffect(barrier.effect)
        }
    }

    private mutating func performWork(_ effect: SourceGameplayDeferredEffect) throws {
        switch effect {
        case .persistWeek(let week): state.savedWeek = week
        case .updateWeekDisplay(let week): state.displayedWeek = week
        case .advanceCharacterDays(let days):
            // Source Change(Week): the per-heroine daily increment `days` times,
            // plus EventAfterDayAdd(days) when fixCharaID <= -5.
            for index in state.heroines.indices {
                let heroine = state.heroines[index]
                let (count, countOverflow) = heroine.dailyIncrements.addingReportingOverflow(days)
                guard !countOverflow else { throw SourceGameplayHostError.counterOverflow("heroine \(heroine.id) daily increments") }
                state.heroines[index].dailyIncrements = count
                if heroine.fixCharaID <= -5 {
                    let (after, afterOverflow) = heroine.eventAfterDay.addingReportingOverflow(days)
                    guard !afterOverflow else { throw SourceGameplayHostError.counterOverflow("heroine \(heroine.id) event-after days") }
                    state.heroines[index].eventAfterDay = after
                }
            }
        case .updateTimeZone(let zone): state.timeZone = zone
        case .updateMapSunlight(let period):
            state.mapSunlight = SourceGameplayNativeState.MapSunlight(map: state.activeMap, period: period)
        case .setMiniMapAndCameraActive(let active): state.miniMapAndCameraActive = active
        case .clearPlayerNextFlag: state.player.nextFlag = false
        case .replacePeriodAfterADVBarrier, .prepareNextPeriodSceneBarrier, .loadNPCs, .openingTutorial,
             .prepareMapMoveCharactersAndCamera, .startTimeZoneCutIn, .finishMapMoveAndWaitForSceneBarrier,
             .correctGameParameters, .clearCachedCompanions, .ensurePlayerCreatedAndInitialized,
             .resetPlayerActionCount, .clearSaturdayTeachers:
            throw SourceGameplayHostError.unsupportedEffect(effect)
        }
    }

    private mutating func advanceEvent() throws -> [TraceEntry] {
        guard var running = event else { return [] }
        let assetID = running.selection.assetID
        let requests = running.interpreter.drainRequests()
        if !requests.isEmpty {
            var entries: [TraceEntry] = []
            for request in requests {
                guard case .mapChange(let change) = request.command else {
                    throw SourceGameplayHostError.unsupportedRequest(
                        requestID: request.requestID, detail: "\(request.command.kind) needs a presentation host")
                }
                guard change.fade == "None" else {
                    throw SourceGameplayHostError.unsupportedRequest(
                        requestID: request.requestID, detail: "mapChange with fade \(change.fade) needs a presentation host")
                }
                guard mapLoad == nil else {
                    throw SourceGameplayHostError.unsupportedRequest(
                        requestID: request.requestID, detail: "a second map change while a map loads")
                }
                let target = try mapNumber(change)
                mapLoad = MapLoad(requestID: request.requestID, from: state.activeMap, to: target)
                entries.append(.mapLoadStarted(requestID: request.requestID, from: state.activeMap, to: target))
            }
            event = running
            return entries
        }
        if let load = mapLoad {
            state.activeMap = load.to
            // Cycle.ADVVariables is not recovered; the host supplies none.
            try running.interpreter.acknowledge(load.requestID)
            mapLoad = nil
            event = running
            return [.mapLoaded(requestID: load.requestID, map: load.to)]
        }
        if running.interpreter.closed || running.interpreter.exhausted {
            state.completedEvents.append(assetID)
            event = nil
            return [.eventCompleted(heroineID: running.heroineID, assetID: assetID)]
        }
        try running.interpreter.tick(deltaTime: frameDelta)
        event = running
        return [.advFrame(assetID: assetID, batch: running.interpreter.batch, pc: running.interpreter.pc,
                          status: running.interpreter.status)]
    }

    private func mapNumber(_ change: SourceADVHostRequest.MapChange) throws -> Int {
        if let number = change.mapNumber {
            guard catalog.mapNumbers.values.contains(Int(number)) else { throw SourceGameplayHostError.unknownMap(String(number)) }
            return Int(number)
        }
        let name = change.mapName ?? ""
        guard let number = catalog.mapNumbers[name] else { throw SourceGameplayHostError.unknownMap(name) }
        return number
    }

    /// Native policy: every period routine checks fixed events, heroines in
    /// saved order, and the first selection runs. Which source period bodies
    /// check them is not translated (cycle.md, "Gameplay dependency map").
    private mutating func enterPeriod() throws -> TraceEntry {
        periodEntryPending = false
        let cycle = session.cycle
        for heroine in state.heroines {
            let context = SourceFixedEventScheduler.Context(
                isTaked: heroine.isTaked, eventAfterDay: heroine.eventAfterDay, completedEvents: state.completedEvents,
                week: cycle.week, period: cycle.period, mapNumbers: catalog.mapNumbers, waitPoints: catalog.waitPoints,
                lessons: catalog.fixedEvents.lessons(classIndex: heroine.classIndex, week: cycle.week))
            guard let selection = try SourceFixedEventScheduler.select(entries: catalog.fixedEvents.entries(for: heroine.id),
                                                                       context: context) else { continue }
            guard let program = catalog.program(for: selection.assetID) else {
                throw SourceGameplayHostError.missingEventProgram(selection.assetID)
            }
            let interpreter = try SourceADVInterpreter(program: program)
            event = ActiveEvent(heroineID: heroine.id, selection: selection, interpreter: interpreter)
            return .eventSelected(heroineID: heroine.id, assetID: selection.assetID, mapNo: selection.mapNo)
        }
        return .noEventSelected(cycle.period)
    }

    // MARK: - Persistence

    private enum CodingKeys: String, CodingKey {
        case format, schemaVersion, catalog, frameDelta, session, state, event, mapLoad, stagedOperation, periodEntryPending
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let format = try box.decodeIfPresent(String.self, forKey: .format)
        guard format == Self.format else { throw SourceGameplayHostError.unrecognizedSnapshot(format) }
        let version = try box.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else { throw SourceGameplayHostError.unsupportedSchemaVersion(version) }
        catalog = try box.decode(SourceGameplayEventCatalog.self, forKey: .catalog)
        frameDelta = try box.decode(Float.self, forKey: .frameDelta)
        session = try box.decode(SourceGameplaySession.self, forKey: .session)
        state = try box.decode(SourceGameplayNativeState.self, forKey: .state)
        event = try box.decodeIfPresent(ActiveEvent.self, forKey: .event)
        mapLoad = try box.decodeIfPresent(MapLoad.self, forKey: .mapLoad)
        stagedOperation = try box.decodeIfPresent(SourceGameplayCycleOperation.self, forKey: .stagedOperation)
        periodEntryPending = try box.decode(Bool.self, forKey: .periodEntryPending)
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(Self.format, forKey: .format)
        try box.encode(Self.schemaVersion, forKey: .schemaVersion)
        try box.encode(catalog, forKey: .catalog)
        try box.encode(frameDelta, forKey: .frameDelta)
        try box.encode(session, forKey: .session)
        try box.encode(state, forKey: .state)
        try box.encodeIfPresent(event, forKey: .event)
        try box.encodeIfPresent(mapLoad, forKey: .mapLoad)
        try box.encodeIfPresent(stagedOperation, forKey: .stagedOperation)
        try box.encode(periodEntryPending, forKey: .periodEntryPending)
    }

    /// The invariants `perform` and `step` maintain, so a decoded host resumes
    /// exactly as the encoded one would have. The session and interpreter
    /// validate their own state while decoding.
    private func validate() throws {
        func inconsistent(_ detail: String) -> SourceGameplayHostError { .inconsistentState(detail) }
        try catalog.validate()
        guard frameDelta.isFinite, frameDelta > 0 else { throw inconsistent("the ADV frame duration must be finite and positive") }
        try state.validate(against: catalog)
        let owed = session.synchronousWork + (session.transition?.effects ?? [])
        if let effect = owed.first(where: { !Self.supports($0) }) { throw SourceGameplayHostError.unsupportedEffect(effect) }
        if let transition = session.transition, stagedOperation != transition.operation {
            throw inconsistent("the staged operation differs from the session's in-flight operation")
        }
        if session.transition == nil, !session.synchronousWork.isEmpty, stagedOperation == nil {
            throw inconsistent("released work has no staged operation")
        }
        if periodEntryPending, event != nil { throw inconsistent("a period entry is pending while an event runs") }
        if let event {
            guard state.heroines.contains(where: { $0.id == event.heroineID }) else {
                throw inconsistent("the running event's heroine is not saved")
            }
            let entries = catalog.fixedEvents.entries(for: event.heroineID)
            let selection = event.selection
            let assetID = Int32(selection.entry.asset.trimmingCharacters(in: .whitespacesAndNewlines)).map { Int($0) }
            guard entries.indices.contains(selection.entryIndex), entries[selection.entryIndex] == selection.entry,
                  assetID == selection.assetID else {
                throw inconsistent("the running event is not its heroine's catalog entry")
            }
            guard catalog.program(for: selection.assetID) == event.interpreter.program else {
                throw inconsistent("the running event's ADV program differs from the catalog")
            }
            guard !state.completedEvents.contains(selection.assetID) else {
                throw inconsistent("the running event is already completed")
            }
            guard event.interpreter.fault == nil else { throw inconsistent("the running event has faulted") }
            // A pending MapChange is either loading or still queued for the host.
            let queued = Set(event.interpreter.requests.map(\.requestID))
            for pending in event.interpreter.pending
            where pending.requestID != mapLoad?.requestID && !queued.contains(pending.requestID) {
                throw inconsistent("ADV request \(pending.requestID) is pending but neither queued nor loading")
            }
        }
        if let mapLoad {
            guard let event, event.interpreter.pending.contains(where: { $0.requestID == mapLoad.requestID && $0.gate == .mapLoading }) else {
                throw inconsistent("a map load has no pending MapChange")
            }
            guard mapLoad.from == state.activeMap, catalog.mapNumbers.values.contains(mapLoad.to) else {
                throw inconsistent("the map load does not start at the active map or ends outside the catalog")
            }
        }
    }
}
