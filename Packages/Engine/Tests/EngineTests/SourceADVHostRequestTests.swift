import Foundation
import Testing
@testable import Gameplay

// Expected values below are derived by hand from the recovered handlers
// (`ADV.Commands.*`.Do, `CommandBase.Initialize`, `CommandList.Add`,
// `TextScenario.MessageWindowProc`) and Unity Mono's mscorlib parsers.
// All strings are synthetic.

private typealias Request = SourceADVHostRequest
private func command(_ id: Int, _ args: String..., multi: Bool = false) -> SourceADVProgram.Command { .init(id: id, args: args, multi: multi) }
private func machine(_ commands: [SourceADVProgram.Command], variables: [String: SourceADVValue] = [:],
                     sceneFadeRegulate: Bool = true) throws -> SourceADVInterpreter {
    try SourceADVInterpreter(program: .init(name: "synthetic", commands: commands), variables: variables, sceneFadeRegulate: sceneFadeRegulate)
}
private func single(_ commands: [SourceADVProgram.Command], variables: [String: SourceADVValue] = [:]) throws -> Request.Command? {
    var vm = try machine(commands, variables: variables)
    try vm.start()
    return vm.drainRequests().first?.command
}
private func fault(_ commands: [SourceADVProgram.Command], variables: [String: SourceADVValue] = [:]) -> SourceADVInterpreter.Fault? {
    guard var vm = try? machine(commands, variables: variables) else { return nil }
    _ = try? vm.start()
    return vm.fault
}
private let current = Int32.max

@Test func sourceCLRInt32ParseFollowsMonoFastPath() {
    func value(_ text: String) -> Int32? { if case .value(let v) = SourceCLR.int32(text) { return v }; return nil }
    func throwsFormat(_ text: String) -> Bool { if case .exception = SourceCLR.int32(text) { return true }; return false }
    func unsupported(_ text: String) -> Bool { if case .unsupported = SourceCLR.int32(text) { return true }; return false }
    #expect(value("42") == 42)
    #expect(value(" \t-7 ") == -7)
    #expect(value("+3") == 3)
    #expect(value("2147483647") == .max)
    #expect(value("-2147483648") == .min)
    #expect(value("12\u{0}junk") == 12) // NUL terminates the Mono scan.
    #expect(value("\u{3000}5") == 5)    // Ideographic space is char.IsWhiteSpace.
    for text in ["", " ", "+", "-", "+-1", "1 2", "2147483648", "-2147483649", "mobNo", "通常", "１", "1.5", "0x10"] {
        #expect(throwsFormat(text), "\(text)")
    }
    #expect(unsupported("\u{200B}5")) // Unicode-version dependent white space class.
}

@Test func sourceCLRSingleParseIsInvariantAndConservative() {
    func value(_ text: String) -> Float? { if case .value(let v) = SourceCLR.single(text) { return v }; return nil }
    func throwsFormat(_ text: String) -> Bool { if case .exception = SourceCLR.single(text) { return true }; return false }
    func unsupported(_ text: String) -> Bool { if case .unsupported = SourceCLR.single(text) { return true }; return false }
    #expect(value(".8") == 0.8)
    #expect(value("1") == 1)
    #expect(value("-.5") == -0.5)
    #expect(value("5.") == 5)
    #expect(value(" 2.5 ") == 2.5)
    #expect(value("1e-5") == 1e-5)
    #expect(value("1E+2") == 100) // Mono drops the exponent '+' and returns to the digit state.
    #expect(value("3.4028234e38") == .greatestFiniteMagnitude)
    // Mono's Single.Parse overflow check fires before the float narrowing.
    for text in ["", "  ", "abc", "1.5x", "1..5", "1e39", "3.4028235e38", "1 2"] { #expect(throwsFormat(text), "\(text)") }
    for text in ["1,000", "Infinity", "NaN", "-Infinity", ".", "1e+5.5", "１.5", "-1e39"] { #expect(unsupported(text), "\(text)") }
}

@Test func sourceCLRBooleanAndCultureComparisons() {
    func value(_ text: String) -> Bool? { if case .value(let v) = SourceCLR.boolean(text) { return v }; return nil }
    #expect(value("True") == true)
    #expect(value("FALSE") == false)
    #expect(value(" true\n") == true)
    if case .exception = SourceCLR.boolean("yes") {} else { Issue.record("yes must throw") }
    if case .unsupported = SourceCLR.boolean("Tr ue") {} else { Issue.record("punctuation-only difference is culture dependent") }
    #expect(SourceCLR.cultureEquals("In", "in", ignoreCase: true) == true)
    #expect(SourceCLR.cultureEquals("Out", "in", ignoreCase: true) == false)
    #expect(SourceCLR.cultureEquals("In", "in", ignoreCase: false) == false)
    #expect(SourceCLR.cultureEquals("StaffRoom01", "StaffRoom_01", ignoreCase: true) == nil)
    #expect(SourceCLR.cultureEquals("sound/data/bgm/bgm_32.unity3d", "Date", ignoreCase: true) == false)
    if case .value(let index) = SourceCLR.check("chara", ignoreCase: true, names: ["Base", "Camera", "Chara"]) { #expect(index == 2) }
    else { Issue.record("Check") }
}

@Test func sourceADVLookCommandsApplyDefaultsAndVariables() throws {
    #expect(try single([command(128)]) == .charaLookNeck(.init(chara: current, pattern: 0, rate: 1)))
    #expect(try single([command(128, "0", "3", "1")]) == .charaLookNeck(.init(chara: 0, pattern: 3, rate: 1)))
    #expect(try single([command(128, "", "1", ".5")]) == .charaLookNeck(.init(chara: current, pattern: 1, rate: 0.5)))
    #expect(try single([command(125, "mobNo", "1")], variables: ["mobNo": .integer(4)]) == .charaLookEyes(.init(chara: 4, pattern: 1)))
    #expect(try single([command(125)]) == .charaLookEyes(.init(chara: current, pattern: 0)))
    // A host variable absent under these inputs reaches int.Parse unreplaced.
    let missing = fault([command(1, "System.Int32", "x", "1", multi: true), command(125, "mobNo", "1")])
    #expect(missing?.pc == 1)
    #expect(missing?.commandID == 125)
    #expect(missing?.reason.contains("Chara.LookEyes.Do No") == true)
    #expect(fault([command(128, "0", "1", "1,5")])?.reason.contains("ADV argument form") == true)
}

@Test func sourceADVBGMPlayResolvesSourceSelectorsAndOptionalSettings() throws {
    #expect(try single([command(88, "Date", "", "0", "", "True")]) == .bgmPlay(.init(number: 13, enumName: "Date", delay: 0, isAsync: true)))
    #expect(try single([command(88, "lively", "", "0", "1", "False")])
            == .bgmPlay(.init(number: 24, enumName: "Lively", delay: 0, fade: 1, isAsync: false)))
    #expect(try single([command(88, "3")]) == .bgmPlay(.init(number: 3, delay: 0, isAsync: true)))
    #expect(try single([command(88, "sound/data/bgm/bgm_32.unity3d", "bgm_32", "0", ".8", "True")])
            == .bgmPlay(.init(bundle: "sound/data/bgm/bgm_32.unity3d", asset: "bgm_32", delay: 0, fade: 0.8, isAsync: true)))
    #expect(try single([command(88, "Config", "", "0", "", "True", "", "", "", ".5")])
            == .bgmPlay(.init(number: 27, enumName: "Config", delay: 0, isAsync: true, volume: 0.5)))
    #expect(fault([command(88, "Date", "", "soon")])?.reason.contains("Sound.BGM.Play.Do Delay") == true)
    #expect(fault([command(88, "Date", "", "0", "", "maybe")])?.reason.contains("isAsync") == true)
    #expect(fault([command(88, "Staff Room")])?.reason.contains("Enum<BGM>.FindIndex") == true)
}

@Test func sourceADVExpressionConvertKeepsLookupAndExplicitForms() throws {
    #expect(try single([command(112, "0", "smile")]) == .charaExpression([.init(chara: 0, lookupKey: "smile", expression: nil)]))
    #expect(try single([command(112, "0", "smile", "1", "angry")])
            == .charaExpression([.init(chara: 0, lookupKey: "smile", expression: nil), .init(chara: 1, lookupKey: "angry", expression: nil)]))
    #expect(try single([command(112, "", "smile")]) == .charaExpression([.init(chara: current, lookupKey: "smile", expression: nil)]))
    #expect(try single([command(112, "0")]) == .charaExpression([]))
    var full = Request.Expression()
    full.eyebrow = .init(pattern: 3, blend: true); full.eyes = .init(pattern: 1, blend: false); full.mouth = .init(pattern: 2, blend: true)
    full.eyebrowOpen = 1; full.eyesOpen = 1; full.mouthOpen = 0.5; full.eyesLook = 0; full.cheekRedRate = 0.3
    full.highlight = true; full.tearsLevel = 0; full.blink = false
    let explicit = try single([command(112, "0", "3", "1,False", "2", "1", "1", "0.5", "0", "0.3", "True", "0", "False")])
    #expect(explicit == .charaExpression([.init(chara: 0, lookupKey: "3", expression: full)]))
    if case .charaExpression(let entries)? = explicit { #expect(entries[0].requiresLookupMiss) }
    // An empty second argument skips the lookup; empty fields keep use* false.
    var sparse = Request.Expression()
    sparse.eyes = .init(pattern: 2, blend: true); sparse.mouth = .init(pattern: 1, blend: true); sparse.mouthOpen = 0.5
    #expect(try single([command(112, "0", "", "2", "1", "", "", "0.5")]) == .charaExpression([.init(chara: 0, lookupKey: nil, expression: sparse)]))
    // A failing field ends Expression.Initialize; the exception is swallowed.
    var partial = Request.Expression()
    partial.eyes = .init(pattern: 2, blend: true)
    #expect(try single([command(112, "0", "", "2", "x")]) == .charaExpression([.init(chara: 0, lookupKey: nil, expression: partial)]))
    // Convert's lookup-path int.Parse(No) is outside any try block.
    let malformed = fault([command(112, "first", "smile")])
    #expect(malformed?.reason.contains("Base.Expression.Convert No") == true)
    #expect(fault([command(112, "mobNo", "smile")], variables: [:])?.pc == 0)
    #expect(try single([command(112, "mobNo", "smile")], variables: ["mobNo": .integer(9)])
            == .charaExpression([.init(chara: 9, lookupKey: "smile", expression: nil)]))
}

@Test func sourceADVMotionDataSwallowsParseFailuresLikeSource() throws {
    #expect(try single([command(106, "0", "Stand_00")]) == .charaMotion([.init(chara: 0, state: "Stand_00")]))
    let full = try single([command(106, "1", "Sit", "bundle", "asset", "ikB", "ikA", "", "", "", "", "0,2")])
    #expect(full == .charaMotion([.init(chara: 1, state: "Sit", bundle: "bundle", asset: "asset", ikBundle: "ikB", ikAsset: "ikA",
                                        shakeBundle: "", shakeAsset: "", overrideBundle: "", overrideAsset: "", layers: [0, 2])]))
    #expect(try single([command(106, "1", "Sit", "", "", "", "", "", "", "", "", "0,x")])
            == .charaMotion([.init(chara: 1, state: "Sit", bundle: "", asset: "", ikBundle: "", ikAsset: "", shakeBundle: "",
                                   shakeAsset: "", overrideBundle: "", overrideAsset: "", layers: nil)]))
    // Unreplaced "mobNo": int.Parse throws inside Data's try; the loop resumes
    // one argument later and the state name is parsed as another No.
    #expect(try single([command(106, "mobNo", "Stand")]) == .charaMotion([.init(chara: 0), .init(chara: 0)]))
    // Two motion groups of eleven arguments each.
    let two = Array(repeating: "", count: 9)
    #expect(try single([.init(id: 106, args: ["0", "A"] + two + ["1", "B"])])
            == .charaMotion([.init(chara: 0, state: "A", bundle: "", asset: "", ikBundle: "", ikAsset: "", shakeBundle: "", shakeAsset: "",
                                   overrideBundle: "", overrideAsset: ""), .init(chara: 1, state: "B")]))
    // Voice.Data: a failed Personality ends that entry after cnt passed it, so
    // the Pitch argument is read as the next entry's No (which fails too).
    var vm = try machine([command(17, "0", "", "v", "x", "1.2", multi: true), command(16, "n", "t")])
    try vm.start()
    #expect(vm.drainRequests().map(\.command) == [.text(.init(name: "n", text: "t", voices: [[.init(chara: 0, bundle: "", asset: "v"), .init(chara: 0)]]))])
}

@Test func sourceADVTextBindsVoiceExpressionMotionAndWaitsForNext() throws {
    var vm = try machine([
        command(17, "0", "", "voice_a", multi: true), command(17, "0", "bank", "voice_b", "12", "1.2", multi: true),
        command(19, "0", "smile", multi: true), command(18, "0", "Talk", multi: true), command(16, "speaker", "line one"),
        command(17, "mobNo", "", "voice_c", multi: true), command(16, "", "line two"), command(22)
    ])
    try vm.start()
    let first = vm.drainRequests()
    #expect(first.count == 1)
    #expect(first[0].blocking == .next)
    #expect(first[0].command == .text(.init(name: "speaker", text: "line one",
        voices: [[.init(chara: 0, bundle: "", asset: "voice_a")], [.init(chara: 0, bundle: "bank", asset: "voice_b", personality: 12, pitch: 1.2)]],
        expressions: [[.init(chara: 0, lookupKey: "smile", expression: nil)]], motions: [[.init(chara: 0, state: "Talk")]])))
    #expect(vm.status == "awaitingNext")
    try vm.tick(deltaTime: 100)
    #expect(vm.pc == 5) // A Text batch never advances without Next.
    try vm.tick(deltaTime: 0, requestNext: true)
    // MessageWindowProc cleared CurrentCharaData before the next batch; the
    // unreplaced voice No is swallowed by Voice.Data (No 0, nothing else).
    #expect(vm.drainRequests().map(\.command) == [.text(.init(name: "", text: "line two", voices: [[.init(chara: 0)]]))])
    try vm.tick(deltaTime: 0, requestNext: true)
    #expect(vm.closed)
}

@Test func sourceADVJumpKeepsTextBindingsButEndsTextWait() throws {
    // Jump inside a batch runs RequestNextLine (ProcessEnd, textHash.Clear)
    // without CurrentCharaData.Clear.
    var vm = try machine([command(19, "0", "smile", multi: true), command(16, "a", "b", multi: true), command(23, "next", multi: true),
                          command(22), command(12, "next", multi: true), command(16, "c", "d")])
    try vm.start()
    let requests = vm.drainRequests()
    #expect(requests.map(\.batch) == [1, 2])
    if case .text(let text) = requests[1].command { #expect(text.expressions == [[.init(chara: 0, lookupKey: "smile", expression: nil)]]) }
    #expect(vm.awaitingNext)
}

@Test func sourceADVRequestsKeepSourceOrderInsideMultiBatches() throws {
    var vm = try machine([command(128, "0", "1", "1", multi: true), command(88, "Date", multi: true), command(25, "1", multi: true),
                          command(112, "0", "smile", multi: true), command(125, "0", "1"), command(37, "pos", "Camera")])
    try vm.start()
    let requests = vm.drainRequests()
    #expect(requests.map(\.requestID) == [0, 1, 2, 3])
    #expect(requests.map(\.pc) == [0, 1, 3, 4])
    #expect(requests.map(\.command.kind) == ["charaLookNeck", "bgmPlay", "charaExpression", "charaLookEyes"])
    #expect(Set(requests.map(\.batch)) == [1])
    #expect(requests.allSatisfy { $0.blocking == .none })
    #expect(vm.status == "waiting") // Only the Wait delays the next batch.
    try vm.tick(deltaTime: 1)
    #expect(vm.drainRequests().map(\.command) == [.nullSet(.init(name: "pos", target: "Camera"))])
}

@Test func sourceADVMapChangeHoldsTheUpdateRegulateGateUntilAcknowledged() throws {
    #expect(try single([command(169, "12", "None")]) == .mapChange(.init(mapNumber: 12, fade: "None")))
    #expect(try single([command(169, "school", "FALSE")]) == .mapChange(.init(mapName: "school", fade: "None")))
    #expect(try single([command(169, "1", "TRUE")]) == .mapChange(.init(mapNumber: 1, fade: "InOut")))
    #expect(try single([command(169, "1", "3")]) == .mapChange(.init(mapNumber: 1, fade: "InOut"))) // int.TryParse clamps the default.
    #expect(try single([command(169, "1", "out")]) == .mapChange(.init(mapNumber: 1, fade: "Out")))
    #expect(try single([command(169)]) == .mapChange(.init(mapNumber: 0, fade: "InOut")))
    #expect(fault([command(169, "1", "None", multi: true)])?.reason.contains("Multi batch") == true)
    var vm = try machine([command(25, "5", multi: true), command(169, "1", "None"), command(1, "System.Int32", "after", "1"), command(22)])
    try vm.start()
    let request = try #require(vm.drainRequests().first)
    #expect(request.blocking == .acknowledge)
    #expect(vm.hostGated)
    try vm.tick(deltaTime: 10, requestNext: true)
    #expect(vm.pc == 2) // Next is ignored and Wait timers do not run while the gate holds.
    #expect(vm.waits.first?.elapsed == 0)
    #expect(throws: SourceGameplayExecutionError.self) { try vm.acknowledge(99) }
    try vm.acknowledge(request.requestID, variables: ["mapName": "school"])
    #expect(vm.variables["mapName"] == .string("school"))
    try vm.tick(deltaTime: 5)
    #expect(vm.variables["after"] == .integer(1))
}

@Test func sourceADVSceneFadeBlockingFollowsSceneFadeRegulate() throws {
    #expect(try single([command(44, "Out", "", "", "", "none")]) == .sceneFade(.init(fadeIn: false)))
    #expect(try single([command(44, "in", "2")]) == .sceneFade(.init(fadeIn: true, time: 2)))
    #expect(try single([command(44, "in", "", "", "fade/tex.unity3d", "black")])
            == .sceneFade(.init(fadeIn: true, textureBundle: "fade/tex.unity3d", textureAsset: "black")))
    #expect(fault([command(44, "in", "", "1,0,0")])?.reason.contains("GetColor") == true)
    let program = [command(44, "out"), command(22)]
    // Default isSceneFadeRegulate: UpdateRegulate holds while the fade runs.
    var held = try machine(program)
    try held.start()
    try held.tick(deltaTime: 1, requestNext: true)
    #expect(held.pc == 1)
    try held.acknowledge(0)
    try held.tick(deltaTime: 0)
    #expect(held.closed)
    // Without the regulate flag the fade is ordinary processing: Next ends it.
    var cancelable = try machine([command(45, "FALSE"), command(44, "out"), command(22)])
    try cancelable.start()
    #expect(!cancelable.sceneFadeRegulate)
    try cancelable.tick(deltaTime: 0)
    #expect(cancelable.status == "awaitingHost")
    try cancelable.tick(deltaTime: 1)
    #expect(cancelable.pc == 2)
    try cancelable.tick(deltaTime: 0, requestNext: true)
    #expect(cancelable.closed)
    try cancelable.acknowledge(0) // Already ended by ProcessEnd: a no-op.
    #expect(fault([command(45, "sometimes")])?.reason.contains("SceneFadeRegulate") == true)
    var defaulted = try machine([command(45)], sceneFadeRegulate: false)
    try defaulted.start()
    #expect(defaulted.sceneFadeRegulate)
}

@Test func sourceADVNullCommandsCarrySourceTargets() throws {
    #expect(try single([command(35, "0", "デフォルト")]) == .nullLoad(.init(version: 0, map: nil)))
    #expect(try single([command(35, "1", "room")]) == .nullLoad(.init(version: 1, map: "room")))
    #expect(fault([command(35, "v1", "room")])?.reason.contains("NullLoad.Do Version") == true)
    #expect(try single([command(37, "seat", "chara")]) == .nullSet(.init(name: "seat", target: "Chara")))
    #expect(try single([command(37, "seat")]) == .nullSet(.init(name: "seat", target: "Base")))
    #expect(try single([command(37, "seat", "other")]) == .nullSet(.init(name: "seat", target: nil)))
}

@Test func sourceADVHostFailureFaultsAtTheRequestCommand() throws {
    var vm = try machine([command(1, "System.Int32", "x", "1", multi: true), command(128, "7", "1", "1"), command(22)])
    try vm.start()
    let request = try #require(vm.drainRequests().first)
    vm.hostFailure(request, reason: "character 7 is not loaded")
    #expect(vm.fault?.pc == 1)
    #expect(vm.fault?.commandID == 128)
    #expect(vm.fault?.reason.contains("character 7") == true)
    #expect(vm.status == "faulted")
}

@Test func sourceADVSaveRestoreMidWaitMatchesUninterruptedRun() throws {
    let program = SourceADVProgram(name: "save", commands: [
        command(25, "1.5", multi: true), command(128, "0", "1", "1"), command(44, "out"), command(17, "0", "", "v", multi: true),
        command(16, "n", "t"), command(169, "1", "None"), command(1, "System.Int32", "done", "1", multi: true), command(22)
    ])
    struct Frame: Equatable { var pc: Int; var status: String; var requests: [Request]; var variables: [String: SourceADVValue] }
    func run(saving: Bool) throws -> [Frame] {
        var vm = try SourceADVInterpreter(program: program)
        var frames: [Frame] = []
        func step(_ body: (inout SourceADVInterpreter) throws -> Void) throws {
            if saving { vm = try JSONDecoder().decode(SourceADVInterpreter.self, from: JSONEncoder().encode(vm)) }
            try body(&vm)
            let requests = vm.drainRequests()
            for pending in vm.pending { try vm.acknowledge(pending.requestID, variables: pending.gate == .mapLoading ? ["map": "1"] : [:]) }
            frames.append(.init(pc: vm.pc, status: vm.status, requests: requests, variables: vm.variables))
        }
        try step { try $0.start() }
        for _ in 0..<10 { try step { try $0.tick(deltaTime: 0.5, requestNext: $0.awaitingNext) } }
        return frames
    }
    let plain = try run(saving: false), restored = try run(saving: true)
    #expect(plain == restored)
    #expect(plain.last?.status == "closed")
    #expect(plain.flatMap(\.requests).map(\.command.kind) == ["charaLookNeck", "sceneFade", "text", "mapChange"])
    // A state saved while a request is pending stays blocked after decoding.
    var vm = try SourceADVInterpreter(program: program)
    try vm.start()
    for _ in 0..<3 { try vm.tick(deltaTime: 0.5) }
    #expect(vm.status == "awaitingHost")
    var copy = try JSONDecoder().decode(SourceADVInterpreter.self, from: JSONEncoder().encode(vm))
    try copy.tick(deltaTime: 1, requestNext: true)
    #expect(copy.pc == vm.pc)
    #expect(copy.pending == vm.pending)
    // Corrupt state is rejected.
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(vm)) as? [String: Any])
    object["pc"] = 99
    #expect(throws: (any Error).self) { try JSONDecoder().decode(SourceADVInterpreter.self, from: JSONSerialization.data(withJSONObject: object)) }
}

@Test func sourceADVHostRequestJSONRoundTrips() throws {
    var vm = try machine([command(88, "Date", multi: true), command(112, "0", "3", "1", "2", multi: true), command(16, "n", "t")])
    try vm.start()
    let requests = vm.drainRequests()
    let decoded = try JSONDecoder().decode([Request].self, from: JSONEncoder().encode(requests))
    #expect(decoded == requests)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(requests[0])) as? [String: Any])
    #expect((object["command"] as? [String: Any])?["kind"] as? String == "bgmPlay")
}
