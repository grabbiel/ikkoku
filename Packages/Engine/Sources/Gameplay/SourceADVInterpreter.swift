import Foundation

public enum SourceADVValue: Equatable, Sendable, Codable {
    case integer(Int32), float(Float), boolean(Bool), string(String)
    public var typeName: String {
        switch self { case .integer: "System.Int32"; case .float: "System.Single"; case .boolean: "System.Boolean"; case .string: "System.String" }
    }
    public var sourceString: String {
        switch self {
        case .integer(let value): String(value)
        case .float(let value): String(format: "%.7g", locale: Locale(identifier: "en_US_POSIX"), Double(value)).replacingOccurrences(of: "e", with: "E")
        case .boolean(let value): value ? "True" : "False"
        case .string(let value): value
        }
    }
    private enum CodingKeys: String, CodingKey { case type, value }
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let type = try box.decode(String.self, forKey: .type), value = try box.decode(String.self, forKey: .value)
        self = try Self.cast(.string(value), to: type)
    }
    public func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(typeName, forKey: .type)
        // The interchange format preserves float32 bits; source ToString uses
        // seven significant digits only when executing a source conversion.
        if case .float(let value) = self { try box.encode(String(value), forKey: .value) }
        else { try box.encode(sourceString, forKey: .value) }
    }
    static func cast(_ value: Self, to type: String) throws -> Self {
        let text = value.sourceString.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "System.Int32":
            switch value {
            case .integer: return value
            case .boolean(let value): return .integer(value ? 1 : 0)
            case .float: throw SourceGameplayExecutionError.invalidCast("Source ValData.Cast unboxes a boxed Single as Int32")
            case .string: return .integer(Int32(text) ?? 0)
            }
        case "System.Single":
            let number = Float(text) ?? 0
            guard number.isFinite else { throw SourceGameplayExecutionError.invalidCast("Nonfinite Single") }
            return .float(number)
        case "System.Boolean":
            switch value {
            case .integer(let value): return .boolean(value > 0)
            case .float: throw SourceGameplayExecutionError.invalidCast("Source boolean conversion unboxes Single as Int32")
            case .boolean: return value
            case .string: return .boolean(text.lowercased() == "true")
            }
        case "System.String": return .string(value.sourceString)
        default: throw SourceGameplayExecutionError.unsupported("VAR type \(type)")
        }
    }
    static func convertLiteral(_ text: String, to type: String) throws -> Self {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "System.Int32": if let n = Int32(clean) { return .integer(n) }
        case "System.Single": if let n = Float(clean), n.isFinite { return .float(n) }
        case "System.Boolean":
            if clean.lowercased() == "true" { return .boolean(true) }
            if clean.lowercased() == "false" { return .boolean(false) }
        case "System.String": return .string(text)
        default: break
        }
        throw SourceGameplayExecutionError.invalidCast("Convert.ChangeType literal to \(type)")
    }
    static func checkLiteral(_ text: String) throws -> Self {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased() == "true" { return .boolean(true) }
        if clean.lowercased() == "false" { return .boolean(false) }
        for (prefix, radix) in [("0x", 16), ("0b", 2), ("0o", 8)] where text.lowercased().hasPrefix(prefix) {
            guard let n = UInt32(text.dropFirst(2), radix: radix) else { throw SourceGameplayExecutionError.invalidCast("Integer literal") }
            return .integer(Int32(bitPattern: n))
        }
        if let n = Int32(clean) { return .integer(n) }
        if text.contains(".") {
            guard !text.lowercased().contains("e"), !text.lowercased().hasSuffix("d"),
                  let n = Float(text.lowercased().hasSuffix("f") ? String(text.dropLast()) : text), n.isFinite else {
                throw SourceGameplayExecutionError.unsupported("Extended/scientific IF literal")
            }
            return .float(n)
        }
        // Source also supports additional numeric suffixes and exponent forms.
        if ["e", "d", "f"].contains(where: { text.lowercased().contains($0) }) || ["l", "u", "m"].contains(where: { text.lowercased().hasSuffix($0) }) {
            throw SourceGameplayExecutionError.unsupported("Extended/scientific IF literal")
        }
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 { return .string(String(text.dropFirst().dropLast())) }
        return .string(text)
    }
}

public struct SourceADVProgram: Codable, Sendable, Equatable {
    public struct Command: Codable, Sendable, Equatable {
        public var hash: Int32
        public var version: Int32
        public var multi: Bool
        public var id: Int
        public var args: [String]
        public init(id: Int, args: [String] = [], multi: Bool = false, hash: Int32 = 0, version: Int32 = 0) {
            self.id = id; self.args = args; self.multi = multi; self.hash = hash; self.version = version
        }
    }
    public var schemaVersion: Int
    public var name: String
    public var commands: [Command]
    public init(name: String, commands: [Command]) { self.schemaVersion = 1; self.name = name; self.commands = commands }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw SourceGameplayExecutionError.invalidData("ADV program exceeds 16 MiB") }
        let program = try JSONDecoder().decode(Self.self, from: data)
        try program.validate()
        return program
    }
    func validate() throws {
        guard schemaVersion == 1, commands.count <= 100_000, name.utf8.count <= 4096,
              commands.allSatisfy({ $0.args.count <= 1024 && $0.args.allSatisfy { $0.utf8.count <= 65536 } }) else {
            throw SourceGameplayExecutionError.invalidData("ADV program schema or limits")
        }
    }
}

/// Source command batching, the bounded scalar command subset, and typed host
/// requests for the first presentation commands. Unsupported commands stop
/// with an exact source command index and reason.
///
/// The state is `Codable`: a host may save it at any frame boundary, including
/// while a Wait timer runs, a request awaits acknowledgement or a Text batch
/// awaits Next, and resume with identical results.
public struct SourceADVInterpreter: Codable, Sendable, Equatable {
    public struct Wait: Codable, Sendable, Equatable { public var pc: Int; public var duration: Float; public var elapsed: Float }
    public struct Fault: Codable, Sendable, Equatable { public var pc: Int; public var commandID: Int; public var reason: String }
    /// A blocking host request that has not been acknowledged.
    public struct Pending: Codable, Equatable, Sendable {
        public enum Gate: String, Codable, Sendable {
            /// `TextScenario.UpdateRegulate` blocks while `advScene.Map.isMapLoading`
            /// (MapChange): no command processing and no input until the host
            /// finishes. It is outside the command list, so ProcessEnd keeps it.
            case mapLoading
            /// SceneFade stays in the command list while `Process()` returns
            /// `fade.IsEnd == false`; ProcessEnd (`Result` -> `ForceEnd`) ends it.
            /// With `isSceneFadeRegulate`, `UpdateRegulate` also blocks input.
            case sceneFade
        }
        public var requestID: Int
        public var pc: Int
        public var commandID: Int
        public var gate: Gate
    }
    public static let requestQueueLimit = 100_000
    public let program: SourceADVProgram
    public private(set) var variables: [String: SourceADVValue]
    public private(set) var pc = 0
    public private(set) var executedInstructions = 0
    public private(set) var waits: [Wait] = []
    public private(set) var closed = false
    public private(set) var started = false
    public private(set) var fault: Fault?
    /// Emitted requests the host has not drained, in source execution order.
    public private(set) var requests: [SourceADVHostRequest] = []
    public private(set) var pending: [Pending] = []
    /// The current batch ran a Text command (`textHash` is non-empty).
    public private(set) var awaitingNext = false
    /// Number of `RequestNextLine` calls (batches, including local jumps).
    public private(set) var batch = 0
    public private(set) var nextRequestID = 0
    /// `TextScenario.isSceneFadeRegulate` (`MemberInit` default true).
    public private(set) var sceneFadeRegulate: Bool
    /// `TextScenario.CurrentCharaData` voice/expression/motion lists.
    public private(set) var textBindings = SourceADVTextBindings()
    private var executingPC = 0

    public var exhausted: Bool {
        pc >= program.commands.count && waits.isEmpty && pending.isEmpty && !awaitingNext && !closed && fault == nil
    }
    /// `UpdateRegulate` gates that suspend command processing and input.
    public var hostGated: Bool { pending.contains { $0.gate == .mapLoading || ($0.gate == .sceneFade && sceneFadeRegulate) } }
    public var status: String {
        if fault != nil { return "faulted" }
        if closed { return "closed" }
        if !started { return "ready" }
        if !pending.isEmpty { return "awaitingHost" }
        if awaitingNext { return "awaitingNext" }
        if !waits.isEmpty { return "waiting" }
        return exhausted ? "exhausted" : "frameBoundary"
    }

    public init(program: SourceADVProgram, variables: [String: SourceADVValue] = [:], sceneFadeRegulate: Bool = true) throws {
        try program.validate()
        try Self.validate(variables)
        self.program = program; self.variables = variables; self.sceneFadeRegulate = sceneFadeRegulate
    }
    private static func validate(_ variables: [String: SourceADVValue]) throws {
        guard variables.count <= 10_000, variables.allSatisfy({ key, value in
            guard key.utf8.count <= 65536 else { return false }
            if case .float(let number) = value { return number.isFinite }
            return value.sourceString.utf8.count <= 65536
        }) else { throw SourceGameplayExecutionError.invalidData("ADV variable count/value limits") }
    }
    private enum CodingKeys: String, CodingKey {
        case program, variables, pc, executedInstructions, waits, closed, started, fault, requests, pending
        case awaitingNext, batch, nextRequestID, sceneFadeRegulate, textBindings, executingPC
    }
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        program = try box.decode(SourceADVProgram.self, forKey: .program)
        variables = try box.decode([String: SourceADVValue].self, forKey: .variables)
        pc = try box.decode(Int.self, forKey: .pc)
        executedInstructions = try box.decode(Int.self, forKey: .executedInstructions)
        waits = try box.decode([Wait].self, forKey: .waits)
        closed = try box.decode(Bool.self, forKey: .closed)
        started = try box.decode(Bool.self, forKey: .started)
        fault = try box.decodeIfPresent(Fault.self, forKey: .fault)
        requests = try box.decode([SourceADVHostRequest].self, forKey: .requests)
        pending = try box.decode([Pending].self, forKey: .pending)
        awaitingNext = try box.decode(Bool.self, forKey: .awaitingNext)
        batch = try box.decode(Int.self, forKey: .batch)
        nextRequestID = try box.decode(Int.self, forKey: .nextRequestID)
        sceneFadeRegulate = try box.decode(Bool.self, forKey: .sceneFadeRegulate)
        textBindings = try box.decode(SourceADVTextBindings.self, forKey: .textBindings)
        executingPC = try box.decode(Int.self, forKey: .executingPC)
        try program.validate()
        try Self.validate(variables)
        let lines = 0..<max(program.commands.count, 1)
        guard (0...program.commands.count).contains(pc), lines.contains(executingPC), executedInstructions >= 0, batch >= 0,
              nextRequestID >= 0, requests.count <= Self.requestQueueLimit, waits.count <= 100_000,
              waits.allSatisfy({ lines.contains($0.pc) && $0.duration.isFinite && $0.elapsed.isFinite }),
              pending.allSatisfy({ lines.contains($0.pc) && (0..<nextRequestID).contains($0.requestID) }),
              requests.allSatisfy({ lines.contains($0.pc) && (0..<nextRequestID).contains($0.requestID) }) else {
            throw SourceGameplayExecutionError.invalidData("ADV interpreter state limits")
        }
    }

    public mutating func start(instructionBudget: Int = 10_000) throws {
        guard !started else { return }
        started = true
        try runBatch(instructionBudget: instructionBudget)
    }
    /// One source frame (`MessageWindowProc`). Explicit Next advances a batch
    /// even while Wait timers or a SceneFade run (ProcessEnd ends them) and is
    /// required after a Text batch; it is ignored while an `UpdateRegulate`
    /// gate holds. The host forwards Next only once the text display is
    /// complete (the source's first click on incomplete text only completes
    /// it). No choice input is faked.
    public mutating func tick(deltaTime: Float, requestNext: Bool = false, instructionBudget: Int = 10_000) throws {
        guard deltaTime.isFinite, deltaTime >= 0 else { throw SourceGameplayExecutionError.invalidData("ADV frame delta") }
        guard started else { try start(instructionBudget: instructionBudget); return }
        guard fault == nil, !closed, !hostGated else { return }
        for index in waits.indices {
            let value = waits[index].elapsed + deltaTime
            guard value.isFinite else { throw SourceGameplayExecutionError.invalidData("ADV wait elapsed overflow") }
            waits[index].elapsed = value
        }
        waits.removeAll { $0.elapsed >= $0.duration }
        let processing = !waits.isEmpty || !pending.isEmpty
        if requestNext || (!awaitingNext && !processing) {
            textBindings = .init() // CurrentCharaData.Clear() before RequestNextLine.
            try runBatch(instructionBudget: instructionBudget)
        }
    }
    /// Returns and removes the queued requests in emission order.
    public mutating func drainRequests() -> [SourceADVHostRequest] {
        defer { requests.removeAll() }
        return requests
    }
    /// Completes a blocking request. MapChange acknowledgements carry the
    /// action scene's `Cycle.ADVVariables` values, stored as String variables
    /// as `MapChange.Do` does; the source writes them before any later command
    /// runs because MapChange ends its batch and the map gate holds.
    /// Acknowledging an issued request that no longer blocks is a no-op.
    public mutating func acknowledge(_ requestID: Int, variables hostVariables: [String: String] = [:]) throws {
        guard (0..<nextRequestID).contains(requestID) else { throw SourceGameplayExecutionError.invalidData("Unknown ADV request \(requestID)") }
        guard let index = pending.firstIndex(where: { $0.requestID == requestID }) else {
            guard hostVariables.isEmpty else { throw SourceGameplayExecutionError.invalidData("ADV request \(requestID) is not a pending MapChange") }
            return
        }
        if pending[index].gate != .mapLoading, !hostVariables.isEmpty {
            throw SourceGameplayExecutionError.invalidData("Only MapChange acknowledgements carry ADV variables")
        }
        let incoming = hostVariables.mapValues { SourceADVValue.string($0) }
        try Self.validate(incoming)
        guard variables.merging(incoming, uniquingKeysWith: { $1 }).count <= 10_000 else {
            throw SourceGameplayExecutionError.invalidData("ADV variable count")
        }
        variables.merge(incoming) { $1 }
        pending.remove(at: index)
    }
    /// The host could not perform an issued request (for example a missing
    /// character): the source would throw inside the handler and stop.
    public mutating func hostFailure(_ request: SourceADVHostRequest, reason: String) {
        guard fault == nil, (0..<nextRequestID).contains(request.requestID), program.commands.indices.contains(request.pc),
              program.commands[request.pc].id == request.commandID else { return }
        fault = .init(pc: request.pc, commandID: request.commandID,
                      reason: SourceGameplayExecutionError.hostFailure("request \(request.requestID) \(request.command.kind): \(reason)").errorDescription ?? reason)
        waits.removeAll(); pending.removeAll(); awaitingNext = false
    }
    private mutating func runBatch(instructionBudget: Int) throws {
        var remaining = instructionBudget
        do { try requestLine(remaining: &remaining, depth: 0) }
        catch {
            fault = .init(pc: executingPC, commandID: program.commands.indices.contains(executingPC) ? program.commands[executingPC].id : -1,
                          reason: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
            throw error
        }
    }
    private mutating func requestLine(remaining: inout Int, depth: Int) throws {
        guard depth <= 64 else { throw SourceGameplayExecutionError.budgetExceeded }
        // CommandList.ProcessEnd and textHash.Clear() on each RequestNextLine.
        waits.removeAll()
        pending.removeAll { $0.gate == .sceneFade }
        awaitingNext = false
        batch += 1
        while pc < program.commands.count && !closed {
            guard remaining > 0 else { throw SourceGameplayExecutionError.budgetExceeded }
            remaining -= 1; executingPC = pc; executedInstructions += 1
            let command = program.commands[pc], line = pc
            pc += 1
            try execute(command, line: line, remaining: &remaining, depth: depth)
            if !command.multi && command.id != 0 { break }
        }
    }
    private func replace(_ text: String) -> String { variables[text]?.sourceString ?? text }
    private func arguments(_ raw: [String], defaults: [String]) -> [String] { SourceADVArgs.initialize(raw, defaults: defaults) }
    /// `CommandList.Add`: `Initialize` defaults, then `ReplaceVars` on every
    /// argument (none of the presentation handlers override `ConvertBeforeArgsProc`).
    private func handlerArguments(_ command: SourceADVProgram.Command, defaults: [String]?) -> [String] {
        SourceADVArgs.initialize(command.args, defaults: defaults).map(replace)
    }
    private mutating func emit(_ command: SourceADVProgram.Command, line: Int, _ blocking: SourceADVHostRequest.Blocking,
                               _ payload: SourceADVHostRequest.Command, gate: Pending.Gate? = nil) throws {
        guard requests.count < Self.requestQueueLimit else { throw SourceGameplayExecutionError.invalidData("ADV undrained host request limit") }
        requests.append(.init(requestID: nextRequestID, pc: line, commandID: command.id, batch: batch, blocking: blocking, command: payload))
        if let gate { pending.append(.init(requestID: nextRequestID, pc: line, commandID: command.id, gate: gate)) }
        nextRequestID += 1
    }
    private mutating func jump(_ target: String, remaining: inout Int, depth: Int) throws {
        guard !target.contains(":") else { throw SourceGameplayExecutionError.unsupported("External ADV file jump: \(target)") }
        for (index, command) in program.commands.enumerated() where command.id == 12 {
            guard let label = command.args.first else { throw SourceGameplayExecutionError.invalidData("Tag has no label") }
            if replace(label) == target {
                pc = index
                try requestLine(remaining: &remaining, depth: depth + 1)
                break
            }
        }
        // Missing tags return false in the original and continue the current batch.
    }
    /// `CommandBase.currentCharaDefaultIndex` (`int.MaxValue`) as an argument default.
    static let currentChara = String(Int32.max)
    private mutating func execute(_ command: SourceADVProgram.Command, line: Int, remaining: inout Int, depth: Int) throws {
        switch command.id {
        case 0, 12: break // None/Tag
        case 1:
            let a = arguments(command.args, defaults: ["int", "", ""])
            guard a.count == 3 else { throw SourceGameplayExecutionError.unsupported("VAR random alternatives require a source RNG adapter") }
            var value = a[2], referenceCount = 0
            while value.hasPrefix("*") { referenceCount += 1; value.removeFirst() }
            guard referenceCount <= 64 else { throw SourceGameplayExecutionError.invalidData("VAR reference depth") }
            var source = SourceADVValue.string(value)
            for _ in 0..<referenceCount {
                guard let resolved = variables[source.sourceString] else { throw SourceGameplayExecutionError.missingVariable(source.sourceString) }
                source = resolved
            }
            if referenceCount > 0 { source = .string(try SourceADVValue.cast(source, to: a[0]).sourceString) }
            guard variables.count < 10_000 || variables[a[1]] != nil else { throw SourceGameplayExecutionError.invalidData("ADV variable count") }
            variables[a[1]] = try SourceADVValue.cast(source, to: a[0])
        case 3: try calculate(arguments(command.args, defaults: ["", "", "0"]))
        case 4:
            let a = arguments(command.args, defaults: ["Answer", "0", "0", "0"])
            let numbers = a[1...3].map { Float(replace($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard numbers.allSatisfy({ $0?.isFinite == true }) else { throw SourceGameplayExecutionError.invalidCast("Clamp Single arguments") }
            let value = numbers[0]!, low = numbers[1]!, high = numbers[2]!
            guard variables.count < 10_000 || variables[a[0]] != nil else { throw SourceGameplayExecutionError.invalidData("ADV variable count") }
            variables[a[0]] = .float(value < low ? low : (value > high ? high : value))
        case 14:
            let raw = arguments(command.args, defaults: ["a", "", "b", "tagA", "tagB"])
            guard let comparator = Int(raw[1]), comparator >= 0 else { throw SourceGameplayExecutionError.invalidData("IF requires converted nonnegative comparer ID") }
            let passed: Bool
            if !(0..<6).contains(comparator) { passed = variables[raw[0]] != nil }
            else {
                let left = try variables[raw[0]] ?? SourceADVValue.checkLiteral(raw[0])
                let right = try variables[raw[2]] ?? SourceADVValue.convertLiteral(raw[2], to: left.typeName)
                passed = try compare(left, right, operation: comparator)
            }
            try jump(replace(raw[passed ? 3 : 4]), remaining: &remaining, depth: depth)
        case 15:
            let raw = arguments(command.args, defaults: ["a", "Case,Tag"])
            guard let value = variables[raw[0]] else { throw SourceGameplayExecutionError.missingVariable(raw[0]) }
            var answers: [String: String] = [:]
            for item in raw.dropFirst() {
                let parts = item.components(separatedBy: ",")
                let key = parts.count == 1 ? "default" : parts[0], target = parts.count == 1 ? parts[0] : parts[1]
                guard answers.updateValue(target, forKey: key) == nil else { throw SourceGameplayExecutionError.invalidData("Duplicate Switch case") }
            }
            guard let target = answers[value.sourceString] ?? answers["default"] else { throw SourceGameplayExecutionError.invalidData("Missing Switch default") }
            try jump(target, remaining: &remaining, depth: depth)
        case 22: closed = true; waits.removeAll(); pending.removeAll() // Host must still perform scene release/unload.
        case 23:
            guard let target = command.args.first else { throw SourceGameplayExecutionError.invalidData("Jump argument") }
            try jump(replace(target), remaining: &remaining, depth: depth)
        case 25:
            let a = arguments(command.args, defaults: ["0"])
            let duration = Float(replace(a[0]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            guard duration.isFinite else { throw SourceGameplayExecutionError.invalidData("Nonfinite Wait duration") }
            waits.append(.init(pc: line, duration: duration, elapsed: 0))
        case 16:
            // Text.Do: Data(args) without defaults; ReplaceText runs on the host.
            let a = handlerArguments(command, defaults: nil)
            try emit(command, line: line, .next, .text(.init(name: a.first ?? "", text: a.count > 1 ? a[1] : "", voices: textBindings.voices,
                                                             expressions: textBindings.expressions, motions: textBindings.motions)))
            awaitingNext = true
        case 17:
            let entries = try SourceADVHandlerArguments.voices(handlerArguments(command, defaults: [Self.currentChara]))
            textBindings.voices = (textBindings.voices ?? []) + [entries]
        case 18:
            let entries = try SourceADVHandlerArguments.motions(handlerArguments(command, defaults: [Self.currentChara]))
            textBindings.motions = (textBindings.motions ?? []) + [entries]
        case 19:
            let entries = try SourceADVHandlerArguments.expressions(handlerArguments(command, defaults: [Self.currentChara]))
            textBindings.expressions = (textBindings.expressions ?? []) + [entries]
        case 35:
            try emit(command, line: line, .none, .nullLoad(try SourceADVHandlerArguments.nullLoad(handlerArguments(command, defaults: ["0", ""]))))
        case 37:
            try emit(command, line: line, .none, .nullSet(try SourceADVHandlerArguments.nullSet(handlerArguments(command, defaults: ["", "Base"]))))
        case 44:
            let fade = try SourceADVHandlerArguments.sceneFade(handlerArguments(command, defaults: ["in", "", "", "", "none"]))
            try emit(command, line: line, .acknowledge, .sceneFade(fade), gate: .sceneFade)
        case 45:
            sceneFadeRegulate = try SourceADVHandlerArguments.value(SourceCLR.boolean(handlerArguments(command, defaults: ["True"])[0]),
                                                                   "Effect.SceneFadeRegulate.Do Flag")
        case 88:
            let defaults = ["", "", "0", "", "True", "", "", "", ""]
            try emit(command, line: line, .none, .bgmPlay(try SourceADVHandlerArguments.bgmPlay(handlerArguments(command, defaults: defaults))))
        case 106:
            try emit(command, line: line, .none, .charaMotion(try SourceADVHandlerArguments.motions(handlerArguments(command, defaults: [Self.currentChara]))))
        case 112:
            try emit(command, line: line, .none,
                     .charaExpression(try SourceADVHandlerArguments.expressions(handlerArguments(command, defaults: [Self.currentChara]))))
        case 125:
            try emit(command, line: line, .none, .charaLookEyes(try SourceADVHandlerArguments.lookEyes(handlerArguments(command, defaults: [Self.currentChara, "0"]))))
        case 128:
            let a = handlerArguments(command, defaults: [Self.currentChara, "0", "1"])
            try emit(command, line: line, .none, .charaLookNeck(try SourceADVHandlerArguments.lookNeck(a)))
        case 169:
            // MapChange.Do writes Cycle.ADVVariables synchronously; that is
            // only equivalent to writing them at acknowledgement when MapChange
            // ends its batch (every installed record does).
            guard !command.multi else { throw SourceGameplayExecutionError.unsupported("MapChange inside a Multi batch needs synchronous host variables") }
            let change = try SourceADVHandlerArguments.mapChange(handlerArguments(command, defaults: ["0", "1"]))
            try emit(command, line: line, .acknowledge, .mapChange(change), gate: .mapLoading)
        default: throw SourceGameplayExecutionError.unsupported("ADV command ID \(command.id) at pc \(line)")
        }
    }
    private func compare(_ left: SourceADVValue, _ right: SourceADVValue, operation: Int) throws -> Bool {
        if operation == 0 { return left == right }
        if operation == 1 { return left != right }
        let order: Int
        switch (left, right) {
        case (.integer(let a), .integer(let b)): order = a == b ? 0 : (a < b ? -1 : 1)
        case (.float(let a), .float(let b)): order = a == b ? 0 : (a < b ? -1 : 1)
        case (.boolean(let a), .boolean(let b)): order = a == b ? 0 : (a ? 1 : -1)
        case (.string, .string): throw SourceGameplayExecutionError.unsupported("Culture-sensitive string ordering")
        default: throw SourceGameplayExecutionError.invalidCast("Source IComparable operand types differ")
        }
        switch operation { case 2: return order >= 0; case 3: return order <= 0; case 4: return order > 0; case 5: return order < 0; default: return false }
    }
    private mutating func calculate(_ a: [String]) throws {
        guard a.count >= 3, a.count % 2 == 1, let formula = Int(a[1]), (0...4).contains(formula) else {
            throw SourceGameplayExecutionError.invalidData("Converted Calc arguments")
        }
        let answer: SourceADVValue
        if let existing = variables[a[0]] { answer = existing }
        else {
            let text = replace(a[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            if Int32(text) != nil { answer = .integer(0) }
            else if Float(text) != nil { answer = .float(0) }
            else if ["true", "false"].contains(text.lowercased()) { answer = .boolean(false) }
            else { answer = .string("") }
        }
        func operand(_ text: String) throws -> SourceADVValue { try SourceADVValue.cast(variables[text] ?? .string(text), to: answer.typeName) }
        var result = try operand(a[2]), index = 3
        while index < a.count {
            guard let op = Int(a[index]), (0...3).contains(op) else { throw SourceGameplayExecutionError.invalidData("Calc binary operator") }
            result = try arithmetic(result, operand(a[index + 1]), operation: op + 1)
            index += 2
        }
        guard variables.count < 10_000 || variables[a[0]] != nil else { throw SourceGameplayExecutionError.invalidData("ADV variable count") }
        variables[a[0]] = try arithmetic(answer, result, operation: formula)
    }
    private func arithmetic(_ left: SourceADVValue, _ right: SourceADVValue, operation: Int) throws -> SourceADVValue {
        if operation == 0 { return right }
        switch (left, right) {
        case (.integer(let a), .integer(let b)):
            switch operation {
            case 1: return .integer(a &+ b)
            case 2: return .integer(a &- b)
            case 3: return .integer(a &* b)
            default:
                guard b != 0, !(a == .min && b == -1) else { throw SourceGameplayExecutionError.invalidData("Int32 division by zero/overflow") }
                return .integer(a / b)
            }
        case (.float(let a), .float(let b)):
            let value: Float
            switch operation { case 1: value = a + b; case 2: value = a - b; case 3: value = a * b; default: value = a / b }
            guard value.isFinite else { throw SourceGameplayExecutionError.invalidData("Nonfinite Calc result") }
            return .float(value)
        case (.boolean(let a), .boolean(let b)):
            switch operation { case 1, 3: return .boolean(a || b); case 2: return .boolean(a && !b); default: return .boolean(a && b) }
        case (.string(let a), .string(let b)):
            if operation == 1 { return .string(a + b) }
            if operation == 2 {
                guard !b.isEmpty else { throw SourceGameplayExecutionError.invalidData("String.Replace empty search") }
                return .string(a.replacingOccurrences(of: b, with: "", options: .literal))
            }
            fallthrough
        default: throw SourceGameplayExecutionError.unsupported("Calc operand operation")
        }
    }
}
