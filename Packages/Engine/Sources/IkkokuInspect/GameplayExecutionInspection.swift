import Foundation
import Gameplay

private func gameplayExecutionData(_ url: URL) throws -> Data {
    let limit = 16 * 1024 * 1024
    let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard properties.isRegularFile == true, let size = properties.fileSize, size <= limit else {
        throw SourceGameplayExecutionError.invalidData("Execution input must be a regular file no larger than 16 MiB")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: limit + 1) ?? Data()
    guard bytes.count <= limit else { throw SourceGameplayExecutionError.invalidData("Execution input grew beyond 16 MiB") }
    return bytes
}
private func gameplayJSONObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
}

func inspectFixedEventExecution(url: URL) throws -> [String: Any] {
    struct Request: Decodable {
        struct Case: Decodable { var name: String?; var heroineID: Int; var context: SourceFixedEventScheduler.Context }
        var tablePath: String
        var cases: [Case]
    }
    let request = try JSONDecoder().decode(Request.self, from: gameplayExecutionData(url))
    guard request.cases.count <= 10_000 else { throw SourceGameplayExecutionError.invalidData("Scheduler case count") }
    let tableURL = URL(fileURLWithPath: request.tablePath, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    let table = try SourceFixedEventTable.decode(gameplayExecutionData(tableURL))
    var cases: [[String: Any]] = []
    for item in request.cases {
        do {
            let selection = try SourceFixedEventScheduler.select(entries: table.entries(for: item.heroineID), context: item.context)
            cases.append(["name": item.name ?? "", "heroineID": item.heroineID,
                          "selection": try gameplayJSONObject(selection), "error": NSNull()])
        } catch {
            cases.append(["name": item.name ?? "", "heroineID": item.heroineID, "selection": NSNull(),
                          "error": (error as? LocalizedError)?.errorDescription ?? String(describing: error)])
        }
    }
    return ["schemaVersion": 1, "tablePath": tableURL.path, "caseCount": cases.count, "cases": cases,
            "scope": "Source fixed-event selection only; scene and NPC event execution are not dispatched."]
}

func inspectADVExecution(url: URL) throws -> [String: Any] {
    struct Input: Decodable {
        struct Tick: Decodable { var deltaTime: Float; var requestNext: Bool?; var acknowledge: [Int]? }
        struct Case: Decodable {
            var name: String?
            var program: SourceADVProgram
            var variables: [String: SourceADVValue]?
            var ticks: [Tick]?
            var instructionBudget: Int?
            /// Scripted host: acknowledge every blocking request right after
            /// the frame that issued it, and press Next whenever a Text batch
            /// waits for it. MapChange acknowledgements carry `mapVariables`.
            var autoAcknowledge: Bool?
            var autoNext: Bool?
            var mapVariables: [String: String]?
            var sceneFadeRegulate: Bool?
            /// "summary" (default: identity, pc, blocking, kind) or "full".
            var requestDetail: String?
            /// "full" (default: every variable in every snapshot) or "changes"
            /// (only variables whose value changed since the previous snapshot).
            var variableDetail: String?
            /// Binds `currentHeroine` (and `Manager.Game.Player`) with the
            /// collection's character tables, seeded as `SetADVParam(scenario)`.
            var character: CaseCharacter?
        }
        struct CaseCharacter: Decodable { var heroine: SourceHeroineParameters; var player: SourcePlayerParameters? }
        var cases: [Case]
        /// Paths relative to the input file: `Manager.Game.scenarioParameterDic`
        /// for ParameterFile, and the call-name/voice tables for bound characters.
        var parameterLibraryPath: String?
        var characterTablesPath: String?
    }
    let data = try gameplayExecutionData(url)
    let input: Input
    if let collection = try? JSONDecoder().decode(Input.self, from: data) { input = collection }
    else if let single = try? JSONDecoder().decode(Input.Case.self, from: data) { input = Input(cases: [single]) }
    else {
        input = Input(cases: [.init(name: nil, program: try SourceADVProgram.decode(data), variables: nil, ticks: nil, instructionBudget: nil,
                                    autoAcknowledge: nil, autoNext: nil, mapVariables: nil, sceneFadeRegulate: nil, requestDetail: nil,
                                    variableDetail: nil, character: nil)],
                      parameterLibraryPath: nil, characterTablesPath: nil)
    }
    func relative(_ path: String) -> URL { URL(fileURLWithPath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL }
    let library = try input.parameterLibraryPath.map { try SourceADVParameterLibrary.decode(gameplayExecutionData(relative($0))) }
    let tables = try input.characterTablesPath.map { try SourceCharacterTables.decode(gameplayExecutionData(relative($0))) }
    guard input.cases.count <= 1000, input.cases.reduce(0, { $0 + ($1.ticks?.count ?? 0) }) <= 100_000 else {
        throw SourceGameplayExecutionError.invalidData("ADV execution scenario/frame count")
    }
    var cases: [[String: Any]] = [], totalInstructions = 0, emittedStateEntries = 0, totalRequests = 0
    for item in input.cases {
        let budget = item.instructionBudget ?? 10_000
        guard (1...100_000).contains(budget) else { throw SourceGameplayExecutionError.invalidData("ADV instruction budget must be 1...100000") }
        guard ["summary", "full"].contains(item.requestDetail ?? "summary") else {
            throw SourceGameplayExecutionError.invalidData("ADV requestDetail must be summary or full")
        }
        let full = item.requestDetail == "full"
        guard ["full", "changes"].contains(item.variableDetail ?? "full") else {
            throw SourceGameplayExecutionError.invalidData("ADV variableDetail must be full or changes")
        }
        let changesOnly = item.variableDetail == "changes"
        let binding = item.character.map { SourceADVCharacterBinding(heroine: $0.heroine, player: $0.player, tables: tables) }
        var machine = try SourceADVInterpreter(program: item.program, variables: item.variables ?? [:],
                                               sceneFadeRegulate: item.sceneFadeRegulate ?? true,
                                               character: binding, parameterLibrary: library)
        var reportedVariables: [String: SourceADVValue] = [:], reportedInsertions = 0
        func drain(_ machine: inout SourceADVInterpreter) throws -> [Any] {
            let drained = machine.drainRequests()
            totalRequests += drained.count
            return try drained.map { request -> Any in
                if full { return try gameplayJSONObject(request) }
                return ["requestID": request.requestID, "pc": request.pc, "commandID": request.commandID, "batch": request.batch,
                        "blocking": request.blocking.rawValue, "kind": request.command.kind]
            }
        }
        /// Runs after the frame's snapshot, so a snapshot shows what the frame issued.
        func acknowledgeAll(_ machine: inout SourceADVInterpreter) throws -> [Int] {
            guard item.autoAcknowledge == true else { return [] }
            let ids = machine.pending.map(\.requestID)
            for pending in machine.pending {
                try machine.acknowledge(pending.requestID, variables: pending.gate == .mapLoading ? item.mapVariables ?? [:] : [:])
            }
            return ids
        }
        func snapshot(_ machine: inout SourceADVInterpreter) throws -> [String: Any] {
            let requests = try drain(&machine)
            let variables = changesOnly ? machine.variables.filter { reportedVariables[$0.key] != $0.value } : machine.variables
            reportedVariables = machine.variables
            let insertions = Array(machine.insertions[reportedInsertions...])
            reportedInsertions = machine.insertions.count
            emittedStateEntries += 1 + variables.count + machine.waits.count + requests.count + machine.pending.count + insertions.count
            guard emittedStateEntries <= 1_000_000 else { throw SourceGameplayExecutionError.invalidData("ADV trace output state limit") }
            var state: [String: Any] = ["pc": machine.pc, "status": machine.status, "variables": try gameplayJSONObject(variables),
                    "commandCount": machine.commands.count, "insertions": try gameplayJSONObject(insertions),
                    "waits": try gameplayJSONObject(machine.waits), "fault": try gameplayJSONObject(machine.fault),
                    "closed": machine.closed, "executedInstructions": machine.executedInstructions, "batch": machine.batch,
                    "awaitingNext": machine.awaitingNext, "pending": try gameplayJSONObject(machine.pending),
                    "sceneFadeRegulate": machine.sceneFadeRegulate, "requests": requests]
            state["acknowledged"] = try acknowledgeAll(&machine)
            return state
        }
        var snapshots: [[String: Any]] = []
        do { try machine.start(instructionBudget: budget) } catch { if machine.fault == nil { throw error } }
        snapshots.append(try snapshot(&machine))
        for tick in item.ticks ?? [] {
            guard totalInstructions + machine.executedInstructions < 1_000_000 else {
                throw SourceGameplayExecutionError.invalidData("ADV trace total instruction limit")
            }
            for requestID in tick.acknowledge ?? [] { try machine.acknowledge(requestID) }
            let next = tick.requestNext ?? false || (item.autoNext == true && machine.awaitingNext)
            do { try machine.tick(deltaTime: tick.deltaTime, requestNext: next, instructionBudget: min(budget, 1_000_000 - totalInstructions - machine.executedInstructions)) }
            catch { if machine.fault == nil { throw error } }
            snapshots.append(try snapshot(&machine))
        }
        totalInstructions += machine.executedInstructions
        guard totalInstructions <= 1_000_000 else { throw SourceGameplayExecutionError.invalidData("ADV trace total instruction limit") }
        var result: [String: Any] = ["name": item.name ?? item.program.name, "snapshots": snapshots]
        if let character = machine.character {
            emittedStateEntries += machine.replaces.count
            result["replaces"] = machine.replaces
            result["heroine"] = try gameplayJSONObject(character.heroine)
        }
        cases.append(result)
    }
    return ["schemaVersion": 3, "caseCount": cases.count, "executedInstructions": totalInstructions, "requestCount": totalRequests, "cases": cases,
            "scope": "Bounded source scalar ADV commands, typed host requests for presentation commands, and HeroineParam/ParameterFile over "
                + "a bound native heroine and parameter library; unsupported operations fault with pc and reason. "
                + "No presentation is performed and Close does not unload a native scene."]
}
