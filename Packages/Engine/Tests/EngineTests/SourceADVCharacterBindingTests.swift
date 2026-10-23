import Foundation
import Testing
@testable import Gameplay

// G-T02: SaveData.Heroine/Player parameters bound to the ADV interpreter
// (HeroineParam, ParameterFile). Every table, name and program here is
// synthetic; expected values follow the recovered SaveData/ADV source cited in
// docs/reference/gameplay/adv.md ("Character parameters").

private func callName(_ name: String, _ id: Int32, _ category: Int32) -> SourceCharacterTables.CallName {
    .init(name: name, id: id, category: category, bundle: "synthetic/callname.unity3d")
}

/// Personality 0's list has normal IDs 1, 7 and special (category 0) IDs 3, 5;
/// the player list holds the default ID 7. Voice numbers 0, -5, -100.
private let tables = SourceCharacterTables(
    callNames: ["c00": [callName("CallA", 1, 2), callName("CallC", 3, 0), callName("CallE", 5, 0), callName("Default", 7, 2)],
                "c12": [callName("TwelveDefault", 7, 1)],
                "player": [callName("Default", 7, 2), callName("PlayerSpecial", 9, 0)]],
    callDefaultID: 7, voiceNumbers: [0, -5, -100])

private func heroine(_ edit: (inout SourceHeroineParameters) -> Void = { _ in }) -> SourceHeroineParameters {
    var value = SourceHeroineParameters()
    value.parameter.lastname = "Last"
    value.parameter.firstname = "First"
    value.parameter.nickname = "Nick"
    edit(&value)
    return value
}

private func binding(_ heroine: SourceHeroineParameters = heroine(), player: SourcePlayerParameters? = SourcePlayerParameters(callDefaultID: 7),
                     tables: SourceCharacterTables? = tables) -> SourceADVCharacterBinding {
    SourceADVCharacterBinding(heroine: heroine, player: player, tables: tables)
}

private func command(_ id: Int, _ args: [String], multi: Bool = false) -> SourceADVProgram.Command {
    .init(id: id, args: args, multi: multi)
}

/// Runs a program to its end with one frame per batch; faults are kept on the machine.
private func run(_ commands: [SourceADVProgram.Command], character: SourceADVCharacterBinding? = binding(),
                 library: SourceADVParameterLibrary? = nil) throws -> SourceADVInterpreter {
    var vm = try SourceADVInterpreter(program: .init(name: "synthetic", commands: commands), character: character, parameterLibrary: library)
    do { try vm.start() } catch { guard vm.fault != nil else { throw error } }
    var frames = 0
    while vm.fault == nil, !vm.closed, !vm.exhausted, frames < 1000 {
        do { try vm.tick(deltaTime: 1000) } catch { guard vm.fault != nil else { throw error } }
        frames += 1
    }
    return vm
}

private func encodedRoundTrip(_ vm: SourceADVInterpreter) throws -> SourceADVInterpreter {
    try JSONDecoder().decode(SourceADVInterpreter.self, from: JSONEncoder().encode(vm))
}

// MARK: - Model

@Test func sourceCharacterKeyTablesFollowParamsReflection() {
    let heroineKeys = SourceHeroineParameters.keys
    #expect(heroineKeys.count == 58) // 25 + 4 fields, 8 + 13 properties, 6 Replace, 2 HExperience.
    #expect(Set(heroineKeys.map(\.key)).count == heroineKeys.count)
    #expect(heroineKeys.filter(\.writable).count == 29)
    #expect(heroineKeys.filter { $0.command == .replace }.map(\.key) == ["H", "H姓", "H名", "H名前", "Hあだ名", "Pあだ名"])
    #expect(heroineKeys.allSatisfy { $0.command == .replace || $0.key.hasPrefix("H_") })
    #expect(heroineKeys.first { $0.key == "H_callID" }?.member == "SaveData.CharaData.callID")
    #expect(heroineKeys.first { $0.key == "H_voiceNo" }?.writable == false)
    let playerKeys = SourcePlayerParameters.keys
    #expect(playerKeys.count == 31) // 9 + 4 fields, voiceNo + 13 properties, 4 Replace.
    #expect(Set(playerKeys.map(\.key)).count == playerKeys.count)
    #expect(!playerKeys.contains { $0.key == "P_playTime" || $0.key == "P_playTimeCalc" })
    #expect(playerKeys.filter { $0.command == .replace }.map(\.key) == ["P", "P姓", "P名", "P名前"])
}

@Test func sourceCharacterDefaultsAreTheNewGameObjects() throws {
    let fresh = SourceHeroineParameters()
    #expect(fresh.callID == -1 && fresh.schoolClass == -1 && fresh.schoolClassIndex == -1)
    #expect(fresh.isVirgin && fresh.isAnalVirgin && fresh.talkTimeMax == 4 && fresh.talkTime == 4)
    #expect(fresh.parameter.birthMonth == 1 && fresh.parameter.birthDay == 1 && fresh.parameter.weakPoint == -1)
    #expect(fresh.hAreaExps == Array(repeating: 0, count: 6))
    // Lenient decoding: missing keys keep the new-game value.
    let decoded = try JSONDecoder().decode(SourceHeroineParameters.self, from: Data(#"{"favor": 12}"#.utf8))
    var expected = fresh
    expected.favor = 12
    #expect(decoded == expected)
    let player = SourcePlayerParameters(callDefaultID: 7)
    #expect(player.callID == 7 && player.schoolClass == 1 && player.schoolClassIndex == 20 && player.actionCount == 5)
    // The player's call ID comes from the tables, so it is required.
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(SourcePlayerParameters.self, from: Data("{}".utf8)) }
}

@Test func sourceConvertToInt32UsesMonoStyledParse() {
    func value(_ text: String) -> Int32? { if case .value(let v) = SourceCLR.int32Integer(text) { return v }; return nil }
    func throwsFormat(_ text: String) -> Bool { if case .exception = SourceCLR.int32Integer(text) { return true }; return false }
    #expect(value("6") == 6)
    #expect(value(" \t-7 ") == -7)
    #expect(value("+3") == 3)
    #expect(value("- 4") == -4)     // NumberStyles.Integer skips white space after the sign.
    #expect(value("+ 4") == 4)
    #expect(value("2147483647") == .max)
    #expect(value("-2147483648") == .min)
    #expect(value("12\u{0}junk") == 12)
    #expect(value("12 \u{0}x") == 12)
    for text in ["", " ", "+", "-", "- ", "+-1", "1 2", "2147483648", "-2147483649", "6.0", "1e3", "0x10", "True"] {
        #expect(throwsFormat(text), "\(text)")
    }
    if case .unsupported = SourceCLR.int32Integer("６") {} else { Issue.record("non-ASCII digits are unsupported") }
}

// MARK: - Seed

@Test func sourceHeroineSeedMatchesSetADVParamScenario() throws {
    let vm = try SourceADVInterpreter(program: .init(name: "empty", commands: []), character: binding())
    let keys = SourceHeroineParameters.keys
    for key in keys where key.command != .replace {
        let value = try #require(vm.variables[key.key], "\(key.key)")
        let expected = key.command == .int ? "System.Int32" : key.command == .bool ? "System.Boolean" : "System.String"
        #expect(value.typeName == expected, "\(key.key)")
    }
    #expect(vm.variables.count == keys.filter { $0.command != .replace }.count)
    let vars = vm.variables
    #expect(vars["H_favor"] == .integer(0))
    #expect(vars["H_callID"] == .integer(-1))
    #expect(vars["H_callMyID"] == .integer(7))          // Own -1, then Game.Player.callID.
    #expect(vars["H_isNickNameNormal"] == .boolean(true)) // c00 ID 7 is not special.
    #expect(vars["H_voiceNo"] == .integer(0))
    #expect(vars["H_ChaVoice"] == .string("c00"))
    #expect(vars["H_ChaName"] == .string("c00"))
    #expect(vars["H_FixCharaIDOrPersonality"] == .integer(0))
    #expect(vars["H_isTeacher"] == .boolean(false))
    #expect(vars["H_relation"] == .integer(-1))
    #expect(vars["H_NowCoordinate"] == .integer(0))
    #expect(vars["H_Name"] == .string("Last First"))
    #expect(vars["H_birthMonth"] == .integer(1))
    #expect(vars["H_weakPoint"] == .integer(-1))
    #expect(vars["H_HExperience"] == .string("初めて"))
    #expect(vars["H_HExperienceIndex"] == .integer(0))
    #expect(vm.replaces == ["H": "", "H姓": "Last", "H名": "First", "H名前": "Last First", "Hあだ名": "Nick", "Pあだ名": ""])
    // voiceNo's first read is cached on the bound heroine.
    #expect(vm.character?.heroine.cachedVoiceNo == 0)
}

@Test func sourceHeroineGettersKeepTheirSourceSideEffectsAndBranches() throws {
    // HExperience clamps lewdness after H_lewdness was read (Params order).
    let clamped = try SourceADVInterpreter(program: .init(name: "empty", commands: []),
                                           character: binding(heroine { $0.lewdness = 150 }))
    #expect(clamped.variables["H_lewdness"] == .integer(150))
    #expect(clamped.character?.heroine.lewdness == 100)
    func experience(_ edit: (inout SourceHeroineParameters) -> Void) throws -> SourceADVValue? {
        try SourceADVInterpreter(program: .init(name: "empty", commands: []), character: binding(heroine(edit))).variables["H_HExperienceIndex"]
    }
    #expect(try experience { $0.hCount = 1 } == .integer(1))
    #expect(try experience { $0.hCount = 1; $0.countKokanH = 100; $0.countAnalH = 100; $0.hAreaExps = [0] + Array(repeating: 100, count: 5) }
            == .integer(2))
    #expect(try experience { $0.hCount = 1; $0.lewdness = 100; $0.countKokanH = 100; $0.countAnalH = 100
        $0.hAreaExps = [0] + Array(repeating: 100, count: 5) } == .integer(3))
    // Fixed characters: teachers, voice numbers and ChaName/ChaVoice formatting.
    let teacher = try SourceADVInterpreter(program: .init(name: "empty", commands: []), character: binding(heroine { $0.fixCharaID = -3 }))
    #expect(teacher.variables["H_isTeacher"] == .boolean(true))
    #expect(teacher.variables["H_ChaName"] == .string("c-3"))
    #expect(teacher.variables["H_voiceNo"] == .integer(0))  // -3 has no voice entry: personality.
    let fixed = try SourceADVInterpreter(program: .init(name: "empty", commands: []), character: binding(heroine { $0.fixCharaID = -5 }))
    #expect(fixed.variables["H_voiceNo"] == .integer(-5))
    #expect(fixed.variables["H_ChaVoice"] == .string("c-5"))
    // relation / isNickNameEvent read talkEvent; NowCoordinate reads the dress state.
    let related = try SourceADVInterpreter(program: .init(name: "empty", commands: []), character: binding(heroine {
        $0.talkEvent = [2, 90]; $0.coordinates = [4, 5, 6]; $0.isDresses = [true, false, false]
    }))
    #expect(related.variables["H_relation"] == .integer(1))
    #expect(related.variables["H_isNickNameEvent"] == .boolean(true))
    #expect(related.variables["H_NowCoordinate"] == .integer(5))
    let dressed = try SourceADVInterpreter(program: .init(name: "empty", commands: []),
                                           character: binding(heroine { $0.coordinates = [4, 5]; $0.isDresses = [true, true] }))
    #expect(dressed.variables["H_NowCoordinate"] == .integer(5))
    #expect(throws: SourceGameplayExecutionError.unsupported("ADV character source exception: Heroine.NowCoordinate: IndexOutOfRangeException")) {
        try SourceADVInterpreter(program: .init(name: "empty", commands: []), character: binding(heroine { $0.coordinates = []; $0.isDresses = [true] }))
    }
    // Without a Game player the default call ID comes from the tables.
    let alone = try SourceADVInterpreter(program: .init(name: "empty", commands: []), character: binding(player: nil))
    #expect(alone.variables["H_callMyID"] == .integer(7))
}

@Test func sourceHeroineSeedNamesTheMissingTable() {
    // H_voiceNo is the first getter in param.datas order that reads a table.
    #expect(throws: SourceGameplayExecutionError.unsupported("ADV character table not bound: Manager.Voice.voiceInfoDic (etcetra/list/config)")) {
        try SourceADVInterpreter(program: .init(name: "empty", commands: []), character: binding(tables: nil))
    }
    // A personality with no list throws KeyNotFoundException in the source.
    #expect(throws: SourceGameplayExecutionError.unsupported("ADV character source exception: SaveData.GetCallNameList: KeyNotFoundException for c03")) {
        try SourceADVInterpreter(program: .init(name: "empty", commands: []), character: binding(heroine { $0.parameter.personality = 3 }))
    }
}

// MARK: - HeroineParam

@Test func sourceHeroineParamWritesEveryKeyThroughItsGetterTypeAndSetter() throws {
    for key in SourceHeroineParameters.keys {
        let base = try SourceADVInterpreter(program: .init(name: "empty", commands: []), character: binding())
        var probe = base.character!.heroine
        let before = try probe.read(key, player: base.character!.player, tables: tables)
        // A value of the getter's type that differs from the current one.
        let text: String
        switch before {
        case .integer(let value): text = String(value == 3 ? 5 : 3)
        case .boolean(let value): text = value ? "false" : "TRUE"
        default: text = "Synthetic"
        }
        let vm = try run([command(165, [key.key, text])])
        #expect(vm.fault == nil, "\(key.key): \(vm.fault?.reason ?? "")")
        let expected = try SourceValConvert.changeType(text, to: {
            switch before { case .integer: .int; case .boolean: .bool; default: .string }
        }(), site: "test")
        #expect(vm.variables[key.key] == expected, "\(key.key)")
        var after = vm.character!.heroine
        let read = try after.read(key, player: vm.character!.player, tables: tables)
        if key.writable {
            #expect(read == expected, "\(key.key) field takes the value")
        } else if key.key == "H_HExperience" || key.key == "H_HExperienceIndex" || key.command == .replace || key.key == "H_isNickNameNormal" {
            #expect(read == before, "\(key.key) property is unchanged")
        } else {
            #expect(read == before, "\(key.key) property is unchanged")
        }
        // The Replace keys are refreshed from the getters after every write.
        #expect(vm.replaces["H名前"] == "Last First", "\(key.key)")
        // Text the type cannot parse throws in Convert.ChangeType.
        guard key.command == .int || key.command == .bool else { continue }
        let bad = try run([command(165, [key.key, "not-a-value"])])
        #expect(bad.fault?.pc == 0, "\(key.key)")
        #expect(bad.fault?.reason.contains("Convert.ChangeType") == true, "\(key.key)")
        #expect(bad.character?.heroine == base.character?.heroine, "\(key.key)")
    }
}

@Test func sourceHeroineParamUsesTheCapturedKeyAndTheReplacedValue() throws {
    // args[0] is captured before ReplaceVars; args[1] is replaced.
    let vm = try run([
        command(1, ["System.String", "H_favor", "H_anger"], multi: true), // H_favor now names another key.
        command(1, ["System.Int32", "amount", "42"], multi: true),
        command(165, ["H_favor", "amount"]),
    ])
    #expect(vm.fault == nil)
    #expect(vm.character?.heroine.favor == 42)
    #expect(vm.character?.heroine.anger == 0)
    #expect(vm.variables["H_favor"] == .integer(42))
    // A Single produced by Clamp converts through its seven-digit string.
    let fraction = try run([command(1, ["System.Single", "v", "6.5"], multi: true), command(165, ["H_intimacy", "v"])])
    #expect(fraction.fault?.reason.contains("Convert.ChangeType Int32: Int32.Parse: format") == true)
    #expect(fraction.character?.heroine.intimacy == 0)
}

@Test func sourceHeroineParamUnknownKeyIsANoOp() throws {
    let base = try SourceADVInterpreter(program: .init(name: "empty", commands: []), character: binding())
    for name in ["H_unknown", "favor", "P_intellect", "h_favor", ""] {
        let vm = try run([command(165, [name, "1"])])
        #expect(vm.fault == nil, "\(name)")
        #expect(vm.exhausted, "\(name)")
        #expect(vm.variables == base.variables, "\(name)")
        #expect(vm.replaces == base.replaces, "\(name)")
        #expect(vm.character == base.character, "\(name)")
    }
}

@Test func sourceHeroineParamFaultsLikeTheSource() throws {
    let unbound = try run([command(165, ["H_favor", "1"])], character: nil)
    #expect(unbound.fault?.reason.contains("ADV command ID 165 at pc 0: HeroineParam has no bound current heroine") == true)
    let noValue = try run([command(165, ["H_favor"])])
    #expect(noValue.fault?.reason.contains("HeroineParam args[1] (IndexOutOfRangeException)") == true)
    let noKey = try run([command(165, [])])
    #expect(noKey.fault?.reason.contains("HeroineParam args[0] (IndexOutOfRangeException)") == true)
}

@Test func sourceHeroineParamCallIDRunsCallNameChange() throws {
    // A special entry: namelist_sp_, the ID offset by the smallest special ID.
    let special = try run([command(165, ["H_callID", "5"])])
    #expect(special.fault == nil)
    #expect(special.variables["callBundle"] == .string("synthetic/callname.unity3d"))
    #expect(special.variables["callName0"] == .string("namelist_sp_00_00_002"))
    #expect(special.variables["callName2"] == .string("namelist_sp_00_02_002"))
    #expect(special.variables["H_callName"] == .string("CallE"))
    #expect(special.variables["H_callID"] == .integer(5))
    #expect(special.character?.heroine.callName == "CallE")
    #expect(special.replaces["Pあだ名"] == "CallE")
    // H_isNickNameNormal is not re-seeded by the write (the source only refreshes Replaces).
    #expect(special.variables["H_isNickNameNormal"] == .boolean(true))
    let normal = try run([command(165, ["H_callID", "1"])])
    #expect(normal.variables["callName1"] == .string("namelist_00_01_001"))
    #expect(normal.variables["H_callName"] == .string("CallA"))
    // -1 falls back to the player's ID: CallNameChange still runs with it.
    let fallback = try run([command(165, ["H_callID", "-1"])])
    #expect(fallback.variables["H_callName"] == .string("Default"))
    // Writing H_callName directly sets the field and refreshes Pあだ名.
    let renamed = try run([command(165, ["H_callName", "Synthetic"])])
    #expect(renamed.replaces["Pあだ名"] == "Synthetic")
    #expect(renamed.variables["callBundle"] == nil)
    // An ID the list does not hold throws after the field and Vars changed.
    let missing = try run([command(165, ["H_callID", "4"])])
    #expect(missing.fault?.reason.contains("SaveData.FindCallFileData: no call name 4 (NullReferenceException)") == true)
    #expect(missing.character?.heroine.callID == 4)
    #expect(missing.variables["H_callID"] == .integer(4))
    // Tables dropped from the binding: a named fault instead of a guess.
    var bound = try SourceADVInterpreter(program: .init(name: "p", commands: [command(165, ["H_callID", "3"])]), character: binding())
    var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bound)) as! [String: Any]
    var character = data["character"] as! [String: Any]
    character["tables"] = nil
    data["character"] = character
    bound = try JSONDecoder().decode(SourceADVInterpreter.self, from: JSONSerialization.data(withJSONObject: data))
    #expect(throws: SourceGameplayExecutionError.unsupported("ADV character table not bound: SaveData.nicNameDic (etcetra/list/nickname)")) {
        try bound.start()
    }
}

@Test func sourcePlayerSetADVParamModelsPlayerParam() throws {
    var model = binding(SourceHeroineParameters())
    var variables: [String: SourceADVValue] = [:], replaces: [String: String] = [:]
    try model.seedPlayer(variables: &variables, replaces: &replaces)
    #expect(variables["P_callID"] == .integer(7))
    #expect(variables["P_voiceNo"] == .integer(-100))
    #expect(variables["P_actionCount"] == .integer(5))
    #expect(variables["P_isNickNameNormal"] == .boolean(true))
    #expect(replaces == ["P": "", "P姓": "", "P名": "", "P名前": " "])
    try model.setPlayer("P_intellect", " 12 ", variables: &variables)
    #expect(model.player?.intellect == 12)
    #expect(variables["P_intellect"] == .integer(12))
    try model.setPlayer("P_voiceNo", "3", variables: &variables)
    #expect(model.player?.cachedVoiceNo == -100)
    #expect(variables["P_voiceNo"] == .integer(3))
    try model.setPlayer("P_unknown", "3", variables: &variables)
    #expect(variables["P_unknown"] == nil)
}

// MARK: - ParameterFile

@Test func sourceParameterFileInsertsAfterItsLineInOrderAndNests() throws {
    let library = SourceADVParameterLibrary(programs: [
        "outer": [command(3, ["trace", "1", "10"], multi: true), command(201, ["inner"]), command(3, ["trace", "1", "30"], multi: true)],
        "inner": [command(3, ["trace", "1", "20"], multi: true)],
        "empty": [],
    ])
    let vm = try run([
        command(1, ["System.String", "trace", ""], multi: true),
        command(201, ["outer"]),
        command(201, ["empty"]),
        command(201, ["unknown"]),
        command(3, ["trace", "1", "40"], multi: true),
    ], character: nil, library: library)
    #expect(vm.fault == nil)
    #expect(vm.exhausted)
    // Calc concatenates strings: the execution order is outer, inner, outer, program.
    #expect(vm.variables["trace"] == .string("10203040"))
    #expect(vm.insertions.map(\.asset) == ["outer", "inner", "empty"])
    #expect(vm.insertions.map(\.pc) == [1, 3, 6])
    #expect(vm.insertions.map(\.count) == [3, 1, 0])
    #expect(vm.commands.map(\.id) == [1, 201, 3, 201, 3, 3, 201, 201, 3])
    #expect(vm.program.commands.count == 5) // The loaded asset is unchanged.
    // Re-running a ParameterFile (a backward jump) inserts the list again.
    let looped = try run([
        command(1, ["System.Int32", "n", "0"], multi: true),
        command(12, ["top"], multi: true),
        command(201, ["inner"]),
        command(3, ["n", "1", "1"], multi: true),
        command(14, ["n", "4", "1", "done", "top"]), // n > 1 jumps to done.
        command(12, ["done"], multi: true),
    ], character: nil, library: SourceADVParameterLibrary(programs: ["inner": [command(1, ["System.String", "trace", "x"], multi: true)]]))
    #expect(looped.variables["n"] == .integer(2))
    #expect(looped.insertions.map(\.pc) == [2, 2])
    #expect(looped.commands.count == 8)
}

@Test func sourceParameterFileWithoutALibraryIsUnsupported() throws {
    let vm = try run([command(201, ["anything"])], character: nil)
    #expect(vm.fault?.reason.contains("ADV command ID 201 at pc 0: ParameterFile has no bound Manager.Game.scenarioParameterDic") == true)
}

@Test func sourceOriginalParameterShapeFinishesWithSourceValues() throws {
    // The shape of original parameter asset 301: Calc, Clamp, HeroineParam.
    let library = SourceADVParameterLibrary(programs: ["301": [
        command(3, ["H_intimacy", "1", "6"], multi: true),
        command(4, ["H_intimacy", "H_intimacy", "0", "100"]),
        command(165, ["H_intimacy", "H_intimacy"]),
    ]])
    let vm = try run([command(201, ["301"])], library: library)
    #expect(vm.fault == nil)
    #expect(vm.exhausted)
    #expect(vm.character?.heroine.intimacy == 6)
    #expect(vm.variables["H_intimacy"] == .integer(6)) // Clamp's Single 6 converted back to Int32.
    // Clamp bounds the stored value.
    let high = try run([command(201, ["301"])], character: binding(heroine { $0.intimacy = 98 }), library: library)
    #expect(high.character?.heroine.intimacy == 100)
}

// MARK: - Persistence

@Test func sourceBoundInterpreterSavesAndResumesMidScenario() throws {
    let library = SourceADVParameterLibrary(programs: ["bump": [
        command(3, ["H_favor", "1", "5"], multi: true), command(25, ["1"]), command(165, ["H_favor", "H_favor"]),
    ]])
    let program = SourceADVProgram(name: "persist", commands: [
        command(201, ["bump"]), command(165, ["H_callID", "3"]), command(22, []),
    ])
    var reference = try SourceADVInterpreter(program: program, character: binding(), parameterLibrary: library)
    try reference.start()
    try reference.tick(deltaTime: 0.25) // Calc, then the Wait runs.
    #expect(reference.status == "waiting")
    #expect(reference.insertions.count == 1)
    var resumed = try encodedRoundTrip(reference)
    #expect(resumed == reference)
    for _ in 0..<8 {
        try reference.tick(deltaTime: 0.25)
        try resumed.tick(deltaTime: 0.25)
        resumed = try encodedRoundTrip(resumed)
        #expect(resumed == reference)
    }
    #expect(reference.closed)
    #expect(reference.character?.heroine.favor == 5)
    #expect(reference.character?.heroine.callName == "CallC")
    // The derived command list must replay from the library.
    var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as! [String: Any]
    var insertions = data["insertions"] as! [[String: Any]]
    insertions[0]["asset"] = "other"
    data["insertions"] = insertions
    #expect(throws: SourceGameplayExecutionError.invalidData("ADV ParameterFile insertion does not replay")) {
        try JSONDecoder().decode(SourceADVInterpreter.self, from: JSONSerialization.data(withJSONObject: data))
    }
}

@Test func sourceInterpreterStateFromBeforeBindingsDecodes() throws {
    var vm = try SourceADVInterpreter(program: .init(name: "old", commands: [command(1, ["System.Int32", "x", "1"]), command(25, ["2"])]))
    try vm.start()
    try vm.tick(deltaTime: 0)
    var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(vm)) as! [String: Any]
    for key in ["insertions", "replaces", "character", "parameterLibrary"] { data[key] = nil }
    let old = try JSONDecoder().decode(SourceADVInterpreter.self, from: JSONSerialization.data(withJSONObject: data))
    #expect(old == vm)
    #expect(old.character == nil)
    #expect(old.commands == old.program.commands)
}
