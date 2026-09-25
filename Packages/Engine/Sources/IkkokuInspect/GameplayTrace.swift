import Foundation
import Gameplay

private struct GameplayTraceInput: Decodable {
    struct Number: Decodable {
        let binary: Double
        let decimal: Decimal?

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            binary = try value.decode(Double.self)
            decimal = try? value.decode(Decimal.self)
        }

        /// Decimal avoids accepting fractional arguments rounded to whole
        /// numbers by binary64 decoding. Foundation Decimal has finite precision
        /// (up to 38 significant decimal digits); this is not a raw-token check.
        var exactInt32: Int32? {
            guard let decimal, !decimal.isNaN,
                  decimal >= Decimal(Int32.min), decimal <= Decimal(Int32.max) else { return nil }
            let candidate = NSDecimalNumber(decimal: decimal).int32Value
            return Decimal(candidate) == decimal ? candidate : nil
        }
    }
    struct Initial: Decodable { var isOpening: Bool?; var week: Number? }
    struct Command: Decodable {
        var op: String
        var value: Number?
        var deltaTime: Float?
        var cursorLocked: Bool?, gameRegulated: Bool?
        var advProcessing: Bool?, talkSceneActive: Bool?, interactionSceneActive: Bool?
        var returningToTitle: Bool?, gameEnded: Bool?
    }
    struct Step: Decodable { var command: Command }
    struct Scenario: Decodable { var name: String; var initial: Initial?; var steps: [Step] }
    var cases: [Scenario]
}

private struct GameplayTraceInputError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Runs synthetic control-state commands, never original scripts or plug-ins.
/// The oracle's expected state fields are deliberately ignored by Decodable.
func inspectGameplayTrace(url: URL) throws -> [String: Any] {
    let maximumBytes = 16 * 1024 * 1024
    let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard resource.isRegularFile == true, let size = resource.fileSize,
          size <= maximumBytes else {
        throw GameplayTraceInputError(message: "Gameplay trace must be a regular JSON file of at most 16 MiB.")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else {
        throw GameplayTraceInputError(message: "Gameplay trace exceeded the 16 MiB limit while reading.")
    }
    let input = try JSONDecoder().decode(GameplayTraceInput.self, from: data)
    guard input.cases.count <= 10_000 else {
        throw GameplayTraceInputError(message: "Gameplay trace exceeds 10,000 scenarios.")
    }
    let actionCount = input.cases.reduce(0) { $0 + $1.steps.count }
    guard actionCount <= 100_000 else {
        throw GameplayTraceInputError(message: "Gameplay trace exceeds 100,000 actions.")
    }

    func state(_ cycle: SourceGameplayCycle) -> [String: Any] {
        ["period": cycle.period.rawValue, "week": cycle.week.rawValue,
         "timer": Double(cycle.timer), "timePass": Double(cycle.timePass),
         "timerVisible": cycle.timerVisible, "isOpening": cycle.isOpening,
         "isShufflePoped": cycle.isShufflePoped, "mapMoveActive": cycle.mapMoveActive,
         "isAction": cycle.isAction, "isActionEnd": cycle.isActionEnd]
    }
    func errorCode(_ error: SourceGameplayCycleError) -> String {
        switch error {
        case .invalidWeekAdvance: "invalidWeekAdvance"
        case .nonFiniteTimerInput: "nonFiniteTimerInput"
        case .invalidFrameDelta: "invalidFrameDelta"
        case .mapMoveNotActive: "mapMoveNotActive"
        case .mapMoveNotAvailable: "mapMoveNotAvailable"
        case .nightMenuNotActive: "nightMenuNotActive"
        }
    }
    var scenarios: [[String: Any]] = []
    for scenario in input.cases {
        guard scenario.name.utf8.count <= 4096 else {
            throw GameplayTraceInputError(message: "Gameplay scenario name exceeds 4,096 bytes.")
        }
        let initialWeekNumber = scenario.initial?.week
        let initialWeekRaw = initialWeekNumber == nil ? Int32(6) : initialWeekNumber?.exactInt32
        guard let initialWeekRaw, let initialWeek = SourceGameplayWeek(rawValue: Int(initialWeekRaw)) else {
            throw GameplayTraceInputError(message: "Gameplay initial weekday must be an integer from 0 through 6.")
        }
        var cycle = SourceGameplayCycle(isOpening: scenario.initial?.isOpening ?? true, week: initialWeek)
        let initial = state(cycle)
        var steps: [[String: Any]] = []
        for step in scenario.steps {
            let command = step.command
            var effects: [SourceGameplayDeferredEffect] = []
            var failure: SourceGameplayCycleError?
            func integerValue() throws -> Int32 {
                guard let value = command.value, let integer = value.exactInt32 else {
                    throw GameplayTraceInputError(message: "\(command.op) requires an exact Int32 value.")
                }
                return integer
            }
            func weekValue() throws -> SourceGameplayWeek {
                guard let week = SourceGameplayWeek(rawValue: Int(try integerValue())) else {
                    throw GameplayTraceInputError(message: "\(command.op) weekday must be from 0 through 6.")
                }
                return week
            }
            do {
                switch command.op {
                case "changePeriod":
                    guard let period = SourceGameplayPeriod(rawValue: Int(try integerValue())) else {
                        throw GameplayTraceInputError(message: "changePeriod requires a period from 0 through 11.")
                    }
                    effects = cycle.changePeriod(period)
                case "changeWeek": effects = cycle.changeWeek(try weekValue())
                case "nextWeek": effects = try cycle.nextWeek(command.value == nil ? 1 : integerValue())
                case "nextPeriod":
                    effects = cycle.nextPeriod(returningToTitle: command.returningToTitle ?? false, gameEnded: command.gameEnded ?? false)
                case "reloadNightMenuWeek": effects = try cycle.reloadNightMenuWeek(weekValue())
                case "completeNightMenu":
                    effects = try cycle.completeNightMenu(returningToTitle: command.returningToTitle ?? false, gameEnded: command.gameEnded ?? false)
                case "actionEnd": cycle.actionEnd()
                case "addTimer":
                    guard let value = command.value else {
                        throw GameplayTraceInputError(message: "addTimer requires a numeric value.")
                    }
                    try cycle.addTimer(Float(value.binary))
                case "beginMapMove": effects = try cycle.beginMapMove()
                case "tickMapMove":
                    guard let deltaTime = command.deltaTime, let cursorLocked = command.cursorLocked,
                          let gameRegulated = command.gameRegulated else {
                        throw GameplayTraceInputError(message: "tickMapMove requires deltaTime, cursorLocked, and gameRegulated.")
                    }
                    try cycle.tickMapMove(deltaTime: deltaTime, cursorLocked: cursorLocked,
                                          gameRegulated: gameRegulated, advProcessing: command.advProcessing ?? false,
                                          talkSceneActive: command.talkSceneActive ?? false,
                                          interactionSceneActive: command.interactionSceneActive ?? false)
                case "finishMapMove": effects = try cycle.finishMapMove()
                default: throw GameplayTraceInputError(message: "Unknown gameplay operation: \(command.op)")
                }
            } catch let error as SourceGameplayCycleError {
                failure = error
            }
            let days = effects.compactMap { effect -> Int? in
                if case .advanceCharacterDays(let days) = effect { return days }
                return nil
            }
            steps.append(["operation": command.op, "state": state(cycle),
                          "effects": effects.map { String(describing: $0) },
                          "elapsedCharacterDays": days,
                          "error": failure.map(errorCode) as Any? ?? NSNull()])
        }
        scenarios.append(["name": scenario.name, "initial": initial, "steps": steps])
    }
    return ["schemaVersion": 1, "scenarioCount": scenarios.count, "actionCount": actionCount,
            "scope": "Source cycle control state; returned scene, NPC, ADV, menu, and save effects are not executed.",
            "cases": scenarios]
}
