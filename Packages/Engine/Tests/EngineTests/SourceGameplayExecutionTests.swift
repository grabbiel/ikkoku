import Foundation
import Testing
import Gameplay

@Test func sourceFixedEventOnlyFirstUncompletedCanRun() throws {
    let first = SourceFixedEventTable.Entry(asset: "0", cycles: ["朝"], map: "room", afterDay: 3)
    let next = SourceFixedEventTable.Entry(asset: "1", cycles: ["朝"], map: "room")
    var context = SourceFixedEventScheduler.Context(week: .monday, period: .morning, mapNumbers: ["room": 8])
    #expect(try SourceFixedEventScheduler.select(entries: [first, next], context: context) == nil)
    context.completedEvents = [0]
    #expect(try SourceFixedEventScheduler.select(entries: [first, next], context: context)?.assetID == 1)
    context.isTaked = true
    #expect(try SourceFixedEventScheduler.select(entries: [first, next], context: context) == nil)
}

@Test func sourceFixedEventWeekdayMarkerOverridesExplicitHoliday() throws {
    let entry = SourceFixedEventTable.Entry(asset: "1", cycles: ["起床"], map: "missing", weeks: ["平日", "休日"])
    let holiday = SourceFixedEventScheduler.Context(week: .holiday, period: .wakeUp)
    #expect(try SourceFixedEventScheduler.select(entries: [entry], context: holiday) == nil)
    let monday = SourceFixedEventScheduler.Context(week: .monday, period: .wakeUp)
    #expect(try SourceFixedEventScheduler.select(entries: [entry], context: monday)?.mapNo == -1)
}

@Test func sourceFixedEventWaitPointAndLessonSemantics() throws {
    let entry = SourceFixedEventTable.Entry(asset: "2", cycles: ["部活時間", "授業1", "授業2"], map: "room2", layerName: "event")
    var context = SourceFixedEventScheduler.Context(week: .monday, period: .staffTime, mapNumbers: ["room2": 3], waitPoints: [
        .init(id: "first", mapNo: 3, layers: ["other", "event", "event"]), .init(id: "second", mapNo: 3, layers: ["event"])
    ])
    let selected = try SourceFixedEventScheduler.select(entries: [entry], context: context)
    #expect(selected?.waitPointID == "first")
    #expect(selected?.layerIndex == 1)
    context.period = .lesson1
    context.lessons = ["room", "elsewhere"]
    #expect(try SourceFixedEventScheduler.select(entries: [entry], context: context)?.layerIndex == -1)
    context.period = .lesson2
    #expect(try SourceFixedEventScheduler.select(entries: [entry], context: context) == nil)
}

@Test func sourceADVBatchesWaitsAndExplicitNextCancellation() throws {
    let program = SourceADVProgram(name: "waits", commands: [
        .init(id: 25, args: ["2"], multi: true), .init(id: 25, args: ["1"]), .init(id: 22)
    ])
    var vm = try SourceADVInterpreter(program: program)
    try vm.start()
    #expect(vm.pc == 2)
    #expect(vm.waits.count == 2)
    try vm.tick(deltaTime: 1)
    #expect(vm.waits.count == 1)
    #expect(vm.waits[0].elapsed == 1)
    try vm.tick(deltaTime: 0, requestNext: true)
    #expect(vm.closed)
}

@Test func sourceADVIntOverflowAndLeftToRightCalculation() throws {
    var vm = try SourceADVInterpreter(program: .init(name: "arithmetic", commands: [
        .init(id: 3, args: ["overflow", "0", "2147483647", "0", "1"], multi: true),
        .init(id: 3, args: ["order", "0", "2", "0", "3", "2", "4"], multi: true), .init(id: 22)
    ]))
    try vm.start()
    #expect(vm.variables["overflow"] == .integer(.min))
    #expect(vm.variables["order"] == .integer(20))
    #expect(vm.closed)
}

@Test func sourceADVConvertedComparersAndTypeSensitiveEquality() throws {
    for (operation, expected) in [("0", false), ("1", true)] {
        var vm = try SourceADVInterpreter(program: .init(name: "equality", commands: [
            .init(id: 14, args: ["left", operation, "right", "yes", "no"]),
            .init(id: 12, args: ["yes"], multi: true), .init(id: 1, args: ["System.Boolean", "result", "True"], multi: true), .init(id: 22),
            .init(id: 12, args: ["no"], multi: true), .init(id: 1, args: ["System.Boolean", "result", "False"], multi: true), .init(id: 22)
        ]), variables: ["left": .integer(1), "right": .float(1)])
        try vm.start()
        #expect(vm.variables["result"] == .boolean(expected))
    }
}

@Test func sourceADVFaultsExposeOriginalCommandLocation() throws {
    var vm = try SourceADVInterpreter(program: .init(name: "unsupported", commands: [.init(id: 1, args: ["System.Int32", "value", "1"], multi: true), .init(id: 165)]))
    #expect(throws: SourceGameplayExecutionError.self) { try vm.start() }
    #expect(vm.fault?.pc == 1)
    #expect(vm.fault?.commandID == 165)
    #expect(vm.variables["value"] == .integer(1))
    #expect(vm.status == "faulted")
    try vm.tick(deltaTime: 1)
    #expect(vm.pc == 2)
}

@Test func sourceADVInfiniteJumpIsBounded() throws {
    var vm = try SourceADVInterpreter(program: .init(name: "loop", commands: [.init(id: 12, args: ["again"], multi: true), .init(id: 23, args: ["again"])]))
    #expect(throws: SourceGameplayExecutionError.budgetExceeded) { try vm.start(instructionBudget: 20) }
    #expect(vm.executedInstructions == 20)
    #expect(vm.fault != nil)
}

@Test func sourceADVFloatInterchangePreservesBits() throws {
    let value = SourceADVValue.float(1.2345678)
    #expect(try JSONDecoder().decode(SourceADVValue.self, from: JSONEncoder().encode(value)) == value)
    #expect(throws: SourceGameplayExecutionError.self) {
        try SourceADVInterpreter(program: .init(name: "bad", commands: []), variables: ["invalid": .float(.nan)])
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_GAMEPLAY_EXECUTION_REFERENCE"]),
               "Requires IKKOKU_GAMEPLAY_EXECUTION_REFERENCE"))
func sourceFixedEventIndependentOriginalTableReference() throws {
    let directory = try SourceFixtureSupport.require("IKKOKU_GAMEPLAY_EXECUTION_REFERENCE")
    struct Reference: Decodable {
        struct Expected: Decodable { var entryIndex: Int; var assetID: Int; var mapNo: Int; var waitPointID: String?; var layerIndex: Int }
        struct Case: Decodable { var name: String; var heroineID: Int; var context: SourceFixedEventScheduler.Context; var expected: Expected? }
        var cases: [Case]
    }
    let folder = URL(fileURLWithPath: directory)
    let table = try SourceFixedEventTable.decode(Data(contentsOf: folder.appendingPathComponent("fixed-events.json")))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: folder.appendingPathComponent("scheduler-reference.json")))
    #expect(table.schedules.count == 4)
    #expect(table.schedules.flatMap(\.entries).count == 48)
    #expect(table.classSchedules.count == 4)
    #expect(reference.cases.count == 4032)
    for item in reference.cases {
        let result = try SourceFixedEventScheduler.select(entries: table.entries(for: item.heroineID), context: item.context)
        #expect(result?.entryIndex == item.expected?.entryIndex, "\(item.name)")
        #expect(result?.assetID == item.expected?.assetID, "\(item.name)")
        #expect(result?.mapNo == item.expected?.mapNo, "\(item.name)")
        #expect(result?.waitPointID == item.expected?.waitPointID, "\(item.name)")
        #expect(result?.layerIndex == item.expected?.layerIndex, "\(item.name)")
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_GAMEPLAY_EXECUTION_REFERENCE"]),
               "Requires IKKOKU_GAMEPLAY_EXECUTION_REFERENCE"))
func sourceADVIndependentHandDerivedReference() throws {
    let directory = try SourceFixtureSupport.require("IKKOKU_GAMEPLAY_EXECUTION_REFERENCE")
    struct Reference: Decodable {
        struct Tick: Decodable { var deltaTime: Float; var requestNext: Bool? }
        struct State: Decodable { var pc: Int; var variables: [String: SourceADVValue]; var status: String; var waitElapsed: [Float]; var faultPC: Int? }
        struct Case: Decodable { var name: String; var program: SourceADVProgram; var variables: [String: SourceADVValue]; var ticks: [Tick]; var expected: [State] }
        var cases: [Case]
    }
    let path = URL(fileURLWithPath: directory).appendingPathComponent("adv-reference.json")
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: path))
    #expect(reference.cases.count == 12)
    for item in reference.cases {
        var vm = try SourceADVInterpreter(program: item.program, variables: item.variables)
        func check(_ expected: Reference.State) {
            #expect(vm.pc == expected.pc, "\(item.name)")
            #expect(vm.variables == expected.variables, "\(item.name)")
            #expect(vm.status == expected.status, "\(item.name)")
            #expect(vm.waits.map(\.elapsed) == expected.waitElapsed, "\(item.name)")
            #expect(vm.fault?.pc == expected.faultPC, "\(item.name)")
        }
        do { try vm.start() } catch { #expect(vm.fault != nil) }
        check(item.expected[0])
        for (index, tick) in item.ticks.enumerated() {
            do { try vm.tick(deltaTime: tick.deltaTime, requestNext: tick.requestNext ?? false) } catch { #expect(vm.fault != nil) }
            check(item.expected[index + 1])
        }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_GAMEPLAY_EXECUTION_REFERENCE"]),
               "Requires IKKOKU_GAMEPLAY_EXECUTION_REFERENCE"))
func sourceADVOriginalParameterScenarioStopsAtUnportedBinding() throws {
    let directory = try SourceFixtureSupport.require("IKKOKU_GAMEPLAY_EXECUTION_REFERENCE")
    let program = try SourceADVProgram.decode(Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("original-parameter-301.json")))
    var vm = try SourceADVInterpreter(program: program)
    try vm.start()
    #expect(vm.pc == 2)
    #expect(vm.variables["H_intimacy"] == .float(6))
    #expect(throws: SourceGameplayExecutionError.self) { try vm.tick(deltaTime: 0) }
    #expect(vm.fault?.pc == 2)
    #expect(vm.fault?.commandID == 165)
}
