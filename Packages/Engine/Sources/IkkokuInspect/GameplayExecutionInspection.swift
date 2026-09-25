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
        struct Tick: Decodable { var deltaTime: Float; var requestNext: Bool? }
        struct Case: Decodable {
            var name: String?
            var program: SourceADVProgram
            var variables: [String: SourceADVValue]?
            var ticks: [Tick]?
            var instructionBudget: Int?
        }
        var cases: [Case]
    }
    let data = try gameplayExecutionData(url)
    let input: Input
    if let collection = try? JSONDecoder().decode(Input.self, from: data) { input = collection }
    else if let single = try? JSONDecoder().decode(Input.Case.self, from: data) { input = Input(cases: [single]) }
    else { input = Input(cases: [.init(name: nil, program: try SourceADVProgram.decode(data), variables: nil, ticks: nil, instructionBudget: nil)]) }
    guard input.cases.count <= 1000, input.cases.reduce(0, { $0 + ($1.ticks?.count ?? 0) }) <= 100_000 else {
        throw SourceGameplayExecutionError.invalidData("ADV execution scenario/frame count")
    }
    var cases: [[String: Any]] = [], totalInstructions = 0, emittedStateEntries = 0
    for item in input.cases {
        let budget = item.instructionBudget ?? 10_000
        guard (1...100_000).contains(budget) else { throw SourceGameplayExecutionError.invalidData("ADV instruction budget must be 1...100000") }
        var machine = try SourceADVInterpreter(program: item.program, variables: item.variables ?? [:])
        func snapshot(_ machine: SourceADVInterpreter) throws -> [String: Any] {
            emittedStateEntries += 1 + machine.variables.count + machine.waits.count
            guard emittedStateEntries <= 1_000_000 else { throw SourceGameplayExecutionError.invalidData("ADV trace output state limit") }
            return ["pc": machine.pc, "status": machine.status, "variables": try gameplayJSONObject(machine.variables),
             "waits": try gameplayJSONObject(machine.waits), "fault": try gameplayJSONObject(machine.fault),
             "closed": machine.closed, "executedInstructions": machine.executedInstructions]
        }
        var snapshots: [[String: Any]] = []
        do { try machine.start(instructionBudget: budget) } catch { if machine.fault == nil { throw error } }
        snapshots.append(try snapshot(machine))
        for tick in item.ticks ?? [] {
            guard totalInstructions + machine.executedInstructions < 1_000_000 else {
                throw SourceGameplayExecutionError.invalidData("ADV trace total instruction limit")
            }
            do { try machine.tick(deltaTime: tick.deltaTime, requestNext: tick.requestNext ?? false, instructionBudget: min(budget, 1_000_000 - totalInstructions - machine.executedInstructions)) }
            catch { if machine.fault == nil { throw error } }
            snapshots.append(try snapshot(machine))
        }
        totalInstructions += machine.executedInstructions
        guard totalInstructions <= 1_000_000 else { throw SourceGameplayExecutionError.invalidData("ADV trace total instruction limit") }
        cases.append(["name": item.name ?? item.program.name, "snapshots": snapshots])
    }
    return ["schemaVersion": 1, "caseCount": cases.count, "executedInstructions": totalInstructions, "cases": cases,
            "scope": "Bounded source scalar ADV commands; unsupported operations fault with pc and reason. Close does not unload a native scene."]
}
