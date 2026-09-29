import Foundation
import Testing
import Gameplay

@Test func sourceGameplayEnumsAndDefaults() {
    #expect(SourceGameplayPeriod.allCases.map(\.rawValue) == Array(0..<12))
    #expect(SourceGameplayWeek.allCases.map(\.rawValue) == Array(0..<7))
    #expect(SourceGameplayPeriod.allCases.map(\.timeZone) == [0, 0, 0, 0, 0, 1, 1, 1, 2, 3, 3, 4])
    #expect(SourceGameplayPeriod.allCases.filter(\.isAction) == [.lunchTime, .staffTime, .afterSchool])
    #expect(SourceGameplayCycle().period == .wakeUp)
    #expect(SourceGameplayCycle().week == .holiday)
    #expect(SourceGameplayCycle(isOpening: false).period == .myHouse)
}

@Test func sourceGameplayExplicitBackwardChangeAndNextDiffer() {
    var cycle = SourceGameplayCycle(isOpening: false, week: .holiday)
    let next = cycle.nextPeriod()
    #expect(cycle.period == .wakeUp)
    #expect(cycle.week == .holiday)
    #expect(!next.contains(.advanceCharacterDays(1)))
    cycle.changePeriod(.myHouse)
    let backwards = cycle.changePeriod(.wakeUp)
    #expect(cycle.week == .monday)
    #expect(backwards.first == .updateWeekDisplay(.monday))
    #expect(backwards.contains(.advanceCharacterDays(1)))
    #expect(!cycle.changePeriod(.wakeUp).contains(.advanceCharacterDays(1)))
}

@Test func sourceGameplayWeekDistanceAndRemainder() throws {
    for plus: Int32 in [0, 7, 14] {
        var cycle = SourceGameplayCycle(week: .wednesday)
        #expect(try cycle.nextWeek(plus).contains(.advanceCharacterDays(7)))
        #expect(cycle.week == .wednesday)
    }
    var cycle = SourceGameplayCycle(week: .friday)
    #expect(cycle.changeWeek(.tuesday).contains(.advanceCharacterDays(4)))
    #expect(try cycle.nextWeek(-1).contains(.advanceCharacterDays(6)))
    #expect(cycle.week == .monday)
    #expect(throws: SourceGameplayCycleError.invalidWeekAdvance(-1)) { try cycle.nextWeek(-1) }
    #expect(cycle.week == .monday)
    // C# unchecked int addition; Monday+Int32.max has a valid positive remainder.
    #expect(try cycle.nextWeek(.max).contains(.advanceCharacterDays(1)))
    #expect(cycle.week == .tuesday)
    #expect(throws: SourceGameplayCycleError.invalidWeekAdvance(-2)) { try cycle.nextWeek(.max) }
    #expect(cycle.week == .tuesday)
}

@Test func sourceGameplayNightMenuAndLoadSynchronization() throws {
    var cycle = SourceGameplayCycle(isOpening: false)
    #expect(try cycle.reloadNightMenuWeek(.saturday) == [.updateWeekDisplay(.saturday)])
    #expect(try cycle.completeNightMenu(returningToTitle: true).isEmpty)
    #expect(cycle.period == .myHouse)
    let effects = try cycle.completeNightMenu()
    #expect(cycle.period == .wakeUp)
    #expect(cycle.week == .holiday)
    #expect(effects.contains(.resetPlayerActionCount(5)))
    #expect(effects.filter { $0 == .advanceCharacterDays(1) }.count == 1)
    #expect(throws: SourceGameplayCycleError.nightMenuNotActive) { try cycle.completeNightMenu() }
    #expect(throws: SourceGameplayCycleError.nightMenuNotActive) { try cycle.reloadNightMenuWeek(.monday) }
}

@Test func sourceGameplaySceneExitSuppressesNext() {
    var cycle = SourceGameplayCycle()
    #expect(cycle.nextPeriod(returningToTitle: true).isEmpty)
    #expect(cycle.nextPeriod(gameEnded: true).isEmpty)
    #expect(cycle.period == .wakeUp)
}

@Test func sourceGameplayMapMoveTimerAndVisibility() throws {
    var cycle = SourceGameplayCycle(week: .monday)
    cycle.changePeriod(.lunchTime)
    #expect(try cycle.beginMapMove() == [.loadNPCs(shuffle: true), .openingTutorial,
        .prepareMapMoveCharactersAndCamera, .startTimeZoneCutIn(.lunchTime)])
    #expect(!cycle.isOpening)
    try cycle.tickMapMove(deltaTime: 20, cursorLocked: false, gameRegulated: false)
    try cycle.tickMapMove(deltaTime: 20, cursorLocked: true, gameRegulated: true)
    #expect(cycle.timer == 0)
    try cycle.tickMapMove(deltaTime: 501, cursorLocked: true, gameRegulated: false, advProcessing: true)
    #expect(cycle.timer == 501)
    #expect(cycle.timePass > 1)
    #expect(!cycle.timerVisible)
    #expect(cycle.isActionEnd)
    #expect(try cycle.finishMapMove() == [.finishMapMoveAndWaitForSceneBarrier])
    #expect(cycle.timePass == 1)
    #expect(cycle.timer == 501)
    #expect(cycle.timerVisible)
    cycle.changePeriod(.staffTime)
    #expect(cycle.timer == 501) // Change does not reset the timer.
    #expect(try cycle.beginMapMove().first == .loadNPCs(shuffle: false))
    #expect(cycle.timer == 0)
}

@Test func sourceGameplayTimerFractionClampsAndGuards() throws {
    var cycle = SourceGameplayCycle()
    try cycle.addTimer(0.25)
    #expect(cycle.timer == 125)
    #expect(cycle.timePass == 0) // The display is updated by MapMove iterations.
    try cycle.addTimer(-1)
    #expect(cycle.timer == 0)
    try cycle.addTimer(.greatestFiniteMagnitude)
    #expect(cycle.timer == 500)
    #expect(throws: SourceGameplayCycleError.nonFiniteTimerInput) { try cycle.addTimer(.nan) }
    #expect(cycle.timer == 500)
    #expect(throws: SourceGameplayCycleError.mapMoveNotActive) {
        try cycle.tickMapMove(deltaTime: 1, cursorLocked: true, gameRegulated: false)
    }
    cycle.changePeriod(.lunchTime)
    #expect(cycle.isAction)
    #expect(throws: SourceGameplayCycleError.mapMoveNotAvailable) { try cycle.beginMapMove() }
    cycle.changeWeek(.monday)
    try cycle.beginMapMove()
    #expect(throws: SourceGameplayCycleError.invalidFrameDelta) {
        try cycle.tickMapMove(deltaTime: -.infinity, cursorLocked: true, gameRegulated: false)
    }
    #expect(cycle.timer == 0)
}

private struct GameplayOracle: Decodable {
    struct State: Decodable {
        var period: Int, week: Int
        var timer: Float, timePass: Float
        var timerVisible: Bool, isOpening: Bool, isShufflePoped: Bool
        var mapMoveActive: Bool, isAction: Bool, isActionEnd: Bool
    }
    struct Command: Decodable {
        var op: String
        var value: Double?
        var deltaTime: Float?
        var cursorLocked: Bool?, gameRegulated: Bool?
        var advProcessing: Bool?, talkSceneActive: Bool?, interactionSceneActive: Bool?
        var returningToTitle: Bool?, gameEnded: Bool?
    }
    struct Step: Decodable {
        var command: Command, state: State
        var elapsedCharacterDays: [Int]
        var error: String?
    }
    struct Initial: Decodable { var isOpening: Bool, week: Int }
    struct Case: Decodable { var name: String, initial: Initial, steps: [Step] }
    var schemaVersion: Int, periods: [String], weeks: [String], timeZones: [Int]
    var cases: [Case]
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_GAMEPLAY_REFERENCE"]),
               "Requires IKKOKU_GAMEPLAY_REFERENCE"))
func sourceGameplayIndependentSourceOracle() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_GAMEPLAY_REFERENCE")
    let oracle = try JSONDecoder().decode(GameplayOracle.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(oracle.schemaVersion == 1)
    #expect(oracle.periods == SourceGameplayPeriod.allCases.map(\.sourceName))
    #expect(oracle.weeks == SourceGameplayWeek.allCases.map(\.sourceName))
    #expect(oracle.timeZones == SourceGameplayPeriod.allCases.map(\.timeZone))
    #expect(oracle.cases.count == 264)
    for item in oracle.cases {
        var cycle = SourceGameplayCycle(isOpening: item.initial.isOpening, week: SourceGameplayWeek(rawValue: item.initial.week)!)
        for step in item.steps {
            let command = step.command
            var effects: [SourceGameplayDeferredEffect] = []
            var error: SourceGameplayCycleError?
            do {
                switch command.op {
                case "changePeriod": effects = cycle.changePeriod(SourceGameplayPeriod(rawValue: Int(command.value!))!)
                case "changeWeek": effects = cycle.changeWeek(SourceGameplayWeek(rawValue: Int(command.value!))!)
                case "nextWeek": effects = try cycle.nextWeek(Int32(command.value ?? 1))
                case "nextPeriod": effects = cycle.nextPeriod(returningToTitle: command.returningToTitle ?? false, gameEnded: command.gameEnded ?? false)
                case "reloadNightMenuWeek": effects = try cycle.reloadNightMenuWeek(SourceGameplayWeek(rawValue: Int(command.value!))!)
                case "completeNightMenu": effects = try cycle.completeNightMenu(returningToTitle: command.returningToTitle ?? false, gameEnded: command.gameEnded ?? false)
                case "actionEnd": cycle.actionEnd()
                case "addTimer": try cycle.addTimer(Float(command.value!))
                case "beginMapMove": effects = try cycle.beginMapMove()
                case "tickMapMove": try cycle.tickMapMove(deltaTime: command.deltaTime!, cursorLocked: command.cursorLocked!, gameRegulated: command.gameRegulated!, advProcessing: command.advProcessing ?? false, talkSceneActive: command.talkSceneActive ?? false, interactionSceneActive: command.interactionSceneActive ?? false)
                case "finishMapMove": effects = try cycle.finishMapMove()
                default: Issue.record("Unknown oracle operation \(command.op)")
                }
            } catch let value as SourceGameplayCycleError { error = value }
            #expect((error != nil) == (step.error != nil), "\(item.name): \(command.op)")
            if let error, let expected = step.error {
                #expect(String(describing: error).hasPrefix(expected), "\(item.name): \(command.op)")
            }
            #expect(effects.compactMap { effect -> Int? in
                if case .advanceCharacterDays(let days) = effect { return days }
                return nil
            } == step.elapsedCharacterDays)
            let expected = step.state
            #expect(cycle.period.rawValue == expected.period, "\(item.name): \(command.op)")
            #expect(cycle.week.rawValue == expected.week, "\(item.name): \(command.op)")
            #expect(cycle.timer == expected.timer, "\(item.name): \(command.op)")
            #expect(cycle.timePass == expected.timePass, "\(item.name): \(command.op)")
            #expect(cycle.timerVisible == expected.timerVisible)
            #expect(cycle.isOpening == expected.isOpening)
            #expect(cycle.isShufflePoped == expected.isShufflePoped)
            #expect(cycle.mapMoveActive == expected.mapMoveActive)
            #expect(cycle.isAction == expected.isAction)
            #expect(cycle.isActionEnd == expected.isActionEnd)
        }
    }
}
