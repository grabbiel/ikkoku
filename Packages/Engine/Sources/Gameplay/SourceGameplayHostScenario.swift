import Foundation

/// A JSON-scripted run of `SourceGameplayHost` (A-T01): a controlled catalog,
/// a start state and steps that stage cycle operations, run the host, persist
/// and reload it, and assert its state. The app runs it headlessly behind
/// `IKKOKU_GAMEPLAY_SCENARIO`; the Engine tests run the same file, so CI
/// exercises the scenario the app lane uses.
public struct SourceGameplayHostScenario: Codable, Sendable {
    public static let schemaVersion = 1

    public struct Start: Codable, Sendable {
        /// Source weekday name (`SourceGameplayWeek.sourceName`).
        public var week: String
        /// With `isOpening` the cycle starts at WakeUp, otherwise at MyHouse.
        public var isOpening: Bool
        /// Catalog name of the map the session starts on.
        public var map: String
        public var heroines: [SourceGameplayNativeState.Heroine]
        /// `Manager.Game.Player`'s parameters; absent, a catalog with character
        /// tables creates the new-game player.
        public var player: SourcePlayerParameters?
        /// Seconds per ADV frame.
        public var frameDelta: Float
    }

    /// One step. `op` is `perform`, `run`, `reload` or `assert`; the other
    /// fields belong to the op that reads them.
    public struct Step: Codable, Sendable {
        public var op: String
        /// perform: `nextPeriod`, `changePeriod`, `changeWeek`, `nextWeek`,
        /// `reloadNightMenuWeek`, `completeNightMenu`, `beginMapMove` or `finishMapMove`.
        public var operation: String?
        /// perform changePeriod: the target; assert: the committed period (source name).
        public var period: String?
        /// perform changeWeek/reloadNightMenuWeek: the target; assert: the committed weekday.
        public var week: String?
        /// perform nextWeek: the source `plus` argument (default 1).
        public var plus: Int32?
        /// run: a `StopCondition` raw value (default `idle`).
        public var until: String?
        /// reload: where the snapshot is persisted before it is read back;
        /// absent keeps it in memory.
        public var path: String?
        /// assert: the weekday `persistWeek` saved.
        public var savedWeek: String?
        /// assert: the active map's catalog name.
        public var activeMap: String?
        public var completedEvents: [Int]?
        /// assert: the asset ID of the running event.
        public var runningEvent: Int?
        public var idle: Bool?
        /// assert: the saved heroine whose `heroineParameters` are checked.
        public var heroine: Int?
        /// assert: original keys (`H_intimacy`, `H名`, …) to `"<type>:<value>"`
        /// as the key's getter reads them, for example `"System.Int32:6"`.
        public var heroineParameters: [String: String]?
        /// assert: the running event's ADV variables, `"<type>:<value>"`.
        public var eventVariables: [String: String]?
        /// assert: the running event's ParameterFile insertion count.
        public var insertions: Int?
    }

    /// Where a `run` step stops: before the first step at which it holds.
    public enum StopCondition: String, Codable, Sendable, CaseIterable {
        case idle, eventRunning, mapLoading, barrier
        /// The running event's ParameterFile has inserted its library program.
        case parameterInserted

        public func holds(_ host: SourceGameplayHost) -> Bool {
            switch self {
            case .idle: return host.isIdle
            case .eventRunning: return host.event != nil
            case .mapLoading: return host.mapLoad != nil
            case .barrier: return host.session.outstandingBarrier != nil
            case .parameterInserted: return host.event?.interpreter.insertions.isEmpty == false
            }
        }
    }

    public struct Report: Codable, Sendable, Equatable {
        public struct StepResult: Codable, Sendable, Equatable {
            public var op: String
            public var ok: Bool
            public var detail: String
        }
        public struct Reload: Codable, Sendable, Equatable {
            /// Index into the scenario's steps.
            public var step: Int
            public var bytes: Int
            public var path: String?
        }
        public struct Summary: Codable, Sendable, Equatable {
            public var period: String
            public var week: String
            public var savedWeek: String
            public var activeMap: Int
            public var completedEvents: [Int]
            public var runningEvent: Int?
            public var idle: Bool

            public init(_ host: SourceGameplayHost) {
                period = host.session.cycle.period.sourceName
                week = host.session.cycle.week.sourceName
                savedWeek = host.state.savedWeek.sourceName
                activeMap = host.state.activeMap
                completedEvents = host.state.completedEvents
                runningEvent = host.event?.selection.assetID
                idle = host.isIdle
            }
        }
        public var schemaVersion: Int
        /// The snapshot format: native host state, never original SaveData (G12).
        public var saveFormat: String
        public var scenario: String
        /// The start, then one result per scenario step.
        public var steps: [StepResult]
        public var reloads: [Reload]
        /// Every host operation in order, across reloads.
        public var trace: [SourceGameplayHost.TraceEntry]
        public var finalState: Summary?
        public var passed: Int
        public var failed: Int

        public func json() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }
    }

    public var schemaVersion: Int
    public var name: String
    public var catalog: SourceGameplayEventCatalog
    public var start: Start
    public var steps: [Step]

    public static func decode(_ data: Data) throws -> SourceGameplayHostScenario {
        guard data.count <= 16 * 1024 * 1024 else { throw SourceGameplayHostScenarioError("the scenario exceeds 16 MiB") }
        let scenario = try JSONDecoder().decode(SourceGameplayHostScenario.self, from: data)
        guard scenario.schemaVersion == Self.schemaVersion else {
            throw SourceGameplayHostScenarioError("unsupported scenario schema version \(scenario.schemaVersion)")
        }
        guard scenario.steps.count <= 10_000 else { throw SourceGameplayHostScenarioError("more than 10,000 steps") }
        return scenario
    }

    /// The host at the scenario's start.
    public func makeHost() throws -> SourceGameplayHost {
        let week = try Self.week(start.week)
        let cycle = SourceGameplayCycle(isOpening: start.isOpening, week: week)
        guard let map = catalog.mapNumbers[start.map] else { throw SourceGameplayHostError.unknownMap(start.map) }
        let state = SourceGameplayNativeState(cycle: cycle, activeMap: map, heroines: start.heroines,
                                              player: .init(parameters: start.player))
        return try SourceGameplayHost(catalog: catalog, cycle: cycle, state: state, frameDelta: start.frameDelta)
    }

    /// Runs every step in order; after a failed step the rest are reported as
    /// not run. `store` persists a reload's snapshot at the step's path (nil:
    /// in memory) and returns the bytes read back, which must decode to an
    /// identical host.
    public func run(store: (Data, String?) throws -> Data) -> Report {
        var report = Report(schemaVersion: 1,
                            saveFormat: "\(SourceGameplayHost.format) schema \(SourceGameplayHost.schemaVersion) (native, not original SaveData)",
                            scenario: name, steps: [], reloads: [], trace: [], finalState: nil, passed: 0, failed: 0)
        var failed = false
        var host: SourceGameplayHost?
        do {
            host = try makeHost()
            report.steps.append(.init(op: "start", ok: true, detail: "catalog \(catalog.name)"))
        } catch {
            report.steps.append(.init(op: "start", ok: false, detail: Self.describe(error)))
            failed = true
        }
        for (index, step) in steps.enumerated() {
            guard !failed, var current = host else {
                report.steps.append(.init(op: step.op, ok: false, detail: "not run: an earlier step failed"))
                continue
            }
            do {
                let detail = try execute(step, index: index, host: &current, report: &report, store: store)
                report.steps.append(.init(op: step.op, ok: true, detail: detail))
            } catch {
                report.steps.append(.init(op: step.op, ok: false, detail: Self.describe(error)))
                failed = true
            }
            host = current
        }
        report.finalState = host.map { Report.Summary($0) }
        report.passed = report.steps.filter { $0.ok }.count
        report.failed = report.steps.count - report.passed
        return report
    }

    private func execute(_ step: Step, index: Int, host: inout SourceGameplayHost, report: inout Report,
                         store: (Data, String?) throws -> Data) throws -> String {
        switch step.op {
        case "perform":
            let operation = try Self.operation(step)
            report.trace += try host.perform(operation)
            return "staged \(operation)"
        case "run":
            guard let stop = StopCondition(rawValue: step.until ?? "idle") else {
                throw SourceGameplayHostScenarioError("unknown run condition '\(step.until ?? "")'")
            }
            // Entries reach the report even when a later step throws.
            var entries: [SourceGameplayHost.TraceEntry] = []
            defer { report.trace += entries }
            while !stop.holds(host) {
                guard entries.count < 100_000 else { throw SourceGameplayHostError.stepBudgetExceeded(100_000) }
                let next = try host.step()
                if next.isEmpty { break }
                entries += next
            }
            guard stop.holds(host) else { throw SourceGameplayHostScenarioError("the host went idle before \(stop.rawValue)") }
            return "\(entries.count) trace entries, stopped at \(stop.rawValue)"
        case "reload":
            let data = try host.snapshot()
            let stored = try store(data, step.path)
            let resumed = try SourceGameplayHost.resume(stored, catalog: catalog)
            guard resumed == host, try resumed.snapshot() == data else {
                throw SourceGameplayHostScenarioError("the reloaded host differs from the persisted one")
            }
            host = resumed
            report.reloads.append(.init(step: index, bytes: data.count, path: step.path))
            return "persisted and reloaded \(data.count) bytes"
        case "assert":
            return try check(step, host)
        default:
            throw SourceGameplayHostScenarioError("unknown op '\(step.op)'")
        }
    }

    private func check(_ step: Step, _ host: SourceGameplayHost) throws -> String {
        var checked: [String] = []
        func expect(_ label: String, _ expected: String, _ actual: String) throws {
            guard expected == actual else { throw SourceGameplayHostScenarioError("\(label): expected \(expected), got \(actual)") }
            checked.append("\(label) \(expected)")
        }
        if let period = step.period {
            try expect("period", Self.period(period).sourceName, host.session.cycle.period.sourceName)
        }
        if let week = step.week { try expect("week", Self.week(week).sourceName, host.session.cycle.week.sourceName) }
        if let week = step.savedWeek { try expect("savedWeek", Self.week(week).sourceName, host.state.savedWeek.sourceName) }
        if let map = step.activeMap {
            guard let number = catalog.mapNumbers[map] else { throw SourceGameplayHostError.unknownMap(map) }
            let active = host.state.activeMap
            let activeName = catalog.mapNumbers.filter { $0.value == active }.keys.sorted().first ?? "unnamed"
            try expect("activeMap", "\(map) (\(number))", "\(activeName) (\(active))")
        }
        if let events = step.completedEvents { try expect("completedEvents", "\(events)", "\(host.state.completedEvents)") }
        if let asset = step.runningEvent {
            try expect("runningEvent", "\(asset)", host.event.map { "\($0.selection.assetID)" } ?? "none")
        }
        if let idle = step.idle { try expect("idle", "\(idle)", "\(host.isIdle)") }
        if let expected = step.heroineParameters {
            guard let id = step.heroine, let saved = host.state.heroines.first(where: { $0.id == id }) else {
                throw SourceGameplayHostScenarioError("assert heroineParameters names no saved heroine")
            }
            for (name, value) in expected.sorted(by: { $0.key < $1.key }) {
                guard let key = SourceHeroineParameters.keys.first(where: { $0.key == name }) else {
                    throw SourceGameplayHostScenarioError("unknown heroine parameter key '\(name)'")
                }
                var copy = saved.parameters // Getters may cache or clamp; the saved state is not changed.
                let read = try copy.read(key, player: host.state.player.parameters, tables: catalog.characterTables)
                try expect("heroine \(id) \(name)", value, "\(read.typeName):\(read.sourceString)")
            }
        }
        if let expected = step.eventVariables {
            guard let event = host.event else { throw SourceGameplayHostScenarioError("assert eventVariables without a running event") }
            for (name, value) in expected.sorted(by: { $0.key < $1.key }) {
                let actual = event.interpreter.variables[name].map { "\($0.typeName):\($0.sourceString)" } ?? "missing"
                try expect("event variable \(name)", value, actual)
            }
        }
        if let count = step.insertions {
            try expect("insertions", "\(count)", host.event.map { "\($0.interpreter.insertions.count)" } ?? "none")
        }
        guard !checked.isEmpty else { throw SourceGameplayHostScenarioError("assert declares nothing") }
        return "checked " + checked.joined(separator: ", ")
    }

    static func operation(_ step: Step) throws -> SourceGameplayCycleOperation {
        switch step.operation ?? "" {
        case "nextPeriod": return .nextPeriod()
        case "changePeriod": return try .changePeriod(period(step.period))
        case "changeWeek": return try .changeWeek(week(step.week))
        case "nextWeek": return .nextWeek(step.plus ?? 1)
        case "reloadNightMenuWeek": return try .reloadNightMenuWeek(week(step.week))
        case "completeNightMenu": return .completeNightMenu()
        case "beginMapMove": return .beginMapMove
        case "finishMapMove": return .finishMapMove
        default: throw SourceGameplayHostScenarioError("unknown operation '\(step.operation ?? "")'")
        }
    }

    static func period(_ name: String?) throws -> SourceGameplayPeriod {
        guard let period = SourceGameplayPeriod.allCases.first(where: { $0.sourceName == name }) else {
            throw SourceGameplayHostScenarioError("unknown period '\(name ?? "")'")
        }
        return period
    }

    static func week(_ name: String?) throws -> SourceGameplayWeek {
        guard let week = SourceGameplayWeek.allCases.first(where: { $0.sourceName == name }) else {
            throw SourceGameplayHostScenarioError("unknown weekday '\(name ?? "")'")
        }
        return week
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// A scenario that cannot run as written, or an assertion that failed.
public struct SourceGameplayHostScenarioError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
