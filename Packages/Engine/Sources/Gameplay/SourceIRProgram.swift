import Foundation
import CryptoKit

public enum SourcePluginError: Error, CustomStringConvertible {
    case invalid(String), budget, runtime(String)
    public var description: String {
        switch self {
        case .invalid(let reason): return "Invalid translated plugin: \(reason)"
        case .budget: return "Translated plugin exceeded its callback instruction or call-depth budget."
        case .runtime(let reason): return "Translated plugin callback failed: \(reason)"
        }
    }
}

/// The Roslyn output is data interpreted by the native host, not a dynamically
/// loaded DLL. Every operation still crosses the same explicit Unity API seam.
public struct SourceIRProgram: Decodable, Sendable {
    public struct Identity: Codable, Sendable, Equatable {
        public let sourceSHA256: String, type: String
        public let symbols: [String]
        public let assemblyName: String?, assemblySHA256: String?, pluginGUID: String?
    }
    public enum Primitive: Decodable, Sendable {
        case bool(Bool), number(Double), string(String)
        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let b = try? value.decode(Bool.self) { self = .bool(b) }
            else if let n = try? value.decode(Double.self), n.isFinite { self = .number(n) }
            else if let s = try? value.decode(String.self), s.utf8.count <= 65536 { self = .string(s) }
            else { throw SourcePluginError.invalid("Invalid IR primitive.") }
        }
    }
    public struct Node: Decodable, Sendable {
        public let kind: String, type: String?, name: String?, value: Primitive?, children: [Node]?
        var args: [Node] { children ?? [] }
    }
    public struct Field: Decodable, Sendable { public let name: String, type: String, initializer: Node; public let serialized: Bool? }
    public struct Parameter: Decodable, Sendable { public let name: String, type: String }
    public struct Method: Decodable, Sendable {
        public let name: String, symbol: String, `static`: Bool, returnType: String
        public let parameters: [Parameter], body: Node, lifecycle: String?
    }
    public struct Source: Decodable, Sendable { public let sha256: String }
    public let schemaVersion: Int, status: String, mode: String, type: String
    public let source: Source, identity: Identity, fields: [Field], methods: [Method]
    public let semanticSurfaceSHA256: String, bridgeSHA256: String, emitterSHA256: String
    public static let lifecycleNames: Set<String> = ["Awake", "OnEnable", "Start", "FixedUpdate", "Update", "LateUpdate", "OnDisable", "OnDestroy"]
    static let types: Set<String> = ["Void", "Float", "Double", "Int32", "Bool", "String", "Vector3", "Object", "Transform", "Space"]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4 * 1024 * 1024 else { throw SourcePluginError.invalid("IR exceeds 4 MiB.") }
        let program = try JSONDecoder().decode(Self.self, from: data)
        try program.validate()
        return program
    }

    public func validate() throws {
        func hash(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard schemaVersion == 1, status == "ready", mode == "component" || mode == "methods",
              type.utf8.elementsEqual(identity.type.utf8), source.sha256 == identity.sourceSHA256,
              [source.sha256, semanticSurfaceSHA256, bridgeSHA256, emitterSHA256].allSatisfy(hash),
              identity.assemblySHA256.map(hash) != false,
              identity.pluginGUID.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) != false,
              fields.count <= 512, !methods.isEmpty, methods.count <= 512,
              Set(fields.map(\.name)).count == fields.count, Set(methods.map(\.name)).count == methods.count,
              identity.symbols == methods.map(\.symbol) else { throw SourcePluginError.invalid("Program identity, mode or symbol topology differs from supported Roslyn IR.") }
        var count = 0
        func visit(_ node: Node, depth: Int) throws {
            count += 1
            guard count <= 50000, depth <= 24, node.args.count <= 2048,
                  node.type.map({ Self.types.contains($0) }) != false,
                  node.name.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) != false else { throw SourcePluginError.invalid("Oversized or untyped IR node.") }
            let arity: ClosedRange<Int>
            switch node.kind {
            case "literal", "ref", "field", "space", "empty": arity = 0...0
            case "member", "convert", "unary", "local", "expression": arity = 1...1
            case "binary", "assign": arity = 2...2
            case "conditional", "if": arity = 3...3
            case "return": arity = 0...1
            case "block", "declarations": arity = 0...2048
            case "call":
                guard let target = methods.first(where: { $0.name == node.name }) else { throw SourcePluginError.invalid("Unknown internal method.") }
                arity = target.parameters.count...target.parameters.count
            case "api":
                let signatures: [String: ClosedRange<Int>] = ["transform": 0...1, "gameObject": 0...0,
                    "position": 1...1, "localPosition": 1...1, "localScale": 1...1,
                    "deltaTime": 0...0, "fixedDeltaTime": 0...0, "vector.zero": 0...0, "vector.one": 0...0,
                    "vector.init": 3...3, "math.Clamp01": 1...1, "math.Sqrt": 1...1, "math.Lerp": 3...3,
                    "world.Instantiate": 1...1, "world.Destroy": 1...1, "setActive": 2...2, "translate": 3...3]
                guard let signature = node.name.flatMap({ signatures[$0] }) else { throw SourcePluginError.invalid("Unmapped API: \(node.name ?? "nil").") }
                arity = signature
            default: throw SourcePluginError.invalid("Unmapped IR node: \(node.kind).")
            }
            guard arity.contains(node.args.count) else { throw SourcePluginError.invalid("Invalid IR arity.") }
            for child in node.args { try visit(child, depth: depth + 1) }
        }
        for field in fields {
            guard ["Float", "Double", "Int32", "Bool", "String", "Vector3", "Space"].contains(field.type), !field.name.isEmpty else {
                throw SourcePluginError.invalid("Unsupported component field.")
            }
            try visit(field.initializer, depth: 0)
        }
        var callbacks = Set<String>()
        for method in methods {
            guard !method.name.isEmpty, Self.types.contains(method.returnType), method.parameters.count <= 64,
                  Set(method.parameters.map(\.name)).count == method.parameters.count,
                  method.parameters.allSatisfy({ Self.types.contains($0.type) && $0.type != "Void" }),
                  method.static == (mode == "methods") else { throw SourcePluginError.invalid("Invalid method signature.") }
            if let lifecycle = method.lifecycle {
                guard Self.lifecycleNames.contains(lifecycle), lifecycle == method.name, method.returnType == "Void",
                      method.parameters.isEmpty, !method.static, callbacks.insert(lifecycle).inserted else {
                    throw SourcePluginError.invalid("Invalid lifecycle callback.")
                }
            }
            try visit(method.body, depth: 0)
        }
    }
}

public protocol SourceAPITransactionWorld: SourceAPIWorld {
    func beginSourceTransaction() throws
    func commitSourceTransaction() throws
    func rollbackSourceTransaction()
    func checkSourceFault() throws
}

public enum SourceIRValue {
    case void, float(Float), double(Double), int32(Int32), bool(Bool), string(String), vector(SIMD3<Float>)
    case object(any SourceAPIObject), transform(any SourceAPITransform), space(SourceAPISpace)
    public var type: String {
        switch self {
        case .void: return "Void"
        case .float: return "Float"
        case .double: return "Double"
        case .int32: return "Int32"
        case .bool: return "Bool"
        case .string: return "String"
        case .vector: return "Vector3"
        case .object: return "Object"
        case .transform: return "Transform"
        case .space: return "Space"
        }
    }
    func number() throws -> Double {
        switch self { case .float(let n): return Double(n); case .double(let n): return n; case .int32(let n): return Double(n)
        default: throw SourcePluginError.runtime("Expected numeric value, got \(type).") }
    }
    func boolean() throws -> Bool {
        guard case .bool(let value) = self else { throw SourcePluginError.runtime("Expected Bool.") }; return value
    }
    func vector() throws -> SIMD3<Float> {
        guard case .vector(let value) = self else { throw SourcePluginError.runtime("Expected Vector3.") }; return value
    }
    func object() throws -> any SourceAPIObject {
        guard case .object(let value) = self else { throw SourcePluginError.runtime("Expected GameObject.") }; return value
    }
    func transform() throws -> any SourceAPITransform {
        guard case .transform(let value) = self else { throw SourcePluginError.runtime("Expected Transform.") }; return value
    }
}

/// Bit-preserving state encoding also retains NaN/infinity produced by original
/// floating-point equations; it never normalizes plug-in names or GUIDs.
public enum SourceIRStoredValue: Codable, Sendable, Equatable {
    case float(UInt32), double(UInt64), int32(Int32), bool(Bool), string(String), vector([UInt32]), space(Int)
    init(_ value: SourceIRValue) throws {
        switch value {
        case .float(let x): self = .float(x.bitPattern)
        case .double(let x): self = .double(x.bitPattern)
        case .int32(let x): self = .int32(x)
        case .bool(let x): self = .bool(x)
        case .string(let x): self = .string(x)
        case .vector(let x): self = .vector([x.x.bitPattern, x.y.bitPattern, x.z.bitPattern])
        case .space(let x): self = .space(x == .world ? 0 : 1)
        default: throw SourcePluginError.runtime("Object handles cannot be persisted as value fields.")
        }
    }
    func value() throws -> SourceIRValue {
        switch self {
        case .float(let x): return .float(Float(bitPattern: x))
        case .double(let x): return .double(Double(bitPattern: x))
        case .int32(let x): return .int32(x)
        case .bool(let x): return .bool(x)
        case .string(let x):
            guard x.utf8.count <= 65536 else { throw SourcePluginError.invalid("Oversized saved string.") }; return .string(x)
        case .vector(let x):
            guard x.count == 3 else { throw SourcePluginError.invalid("Invalid saved vector.") }
            return .vector(SIMD3(Float(bitPattern: x[0]), Float(bitPattern: x[1]), Float(bitPattern: x[2])))
        case .space(let x):
            guard x == 0 || x == 1 else { throw SourcePluginError.invalid("Invalid saved Space.") }; return .space(x == 0 ? .world : .local)
        }
    }
}

/// Execution has finite fuel even when a translated method recursively calls
/// itself. The scene host and component fields roll back a failed callback.
public final class SourceIRComponent {
    public let program: SourceIRProgram, context: SourceAPIContext, gameObject: any SourceAPIObject
    public private(set) var fields: [String: SourceIRValue] = [:]
    private let instructionLimit: Int
    private var fuel = 0, callDepth = 0, invocationDepth = 0, evaluationDepth = 0
    private enum Flow { case next, returned(SourceIRValue) }
    private indirect enum Location {
        case local(Int, String), field(String), lane(Location, Int), property(any SourceAPITransform, String)
    }
    public init(program: SourceIRProgram, context: SourceAPIContext, gameObject: any SourceAPIObject, instructionLimit: Int = 20000) throws {
        guard (100...1000000).contains(instructionLimit) else { throw SourcePluginError.invalid("Invalid execution budget.") }
        try program.validate()
        self.program = program; self.context = context; self.gameObject = gameObject; self.instructionLimit = instructionLimit
        fuel = instructionLimit
        let world = context.world as? any SourceAPITransactionWorld
        try world?.beginSourceTransaction()
        do {
            var locals: [[String: SourceIRValue]] = [[:]]
            for field in program.fields {
                let value = try expression(field.initializer, &locals)
                guard value.type == field.type else { throw SourcePluginError.runtime("Field initializer type mismatch.") }
                fields[field.name] = value
            }
            try world?.checkSourceFault(); try world?.commitSourceTransaction()
        } catch { world?.rollbackSourceTransaction(); throw error }
    }
    private func consume() throws { fuel -= 1; if fuel < 0 || callDepth > 8 { throw SourcePluginError.budget } }
    private func enterEvaluation() throws {
        guard evaluationDepth < 16 else { throw SourcePluginError.budget }
        evaluationDepth += 1
    }
    public func invoke(_ name: String, arguments: [SourceIRValue] = []) throws -> SourceIRValue {
        let saved = fields, world = context.world as? any SourceAPITransactionWorld
        if invocationDepth == 0 { fuel = instructionLimit; callDepth = 0 }
        invocationDepth += 1; defer { invocationDepth -= 1 }
        guard invocationDepth <= 8 else { throw SourcePluginError.budget }
        try world?.beginSourceTransaction()
        do {
            let value = try call(name, arguments: arguments)
            try world?.checkSourceFault(); try world?.commitSourceTransaction()
            return value
        } catch { fields = saved; world?.rollbackSourceTransaction(); throw error }
    }
    public func callback(_ name: String) throws {
        guard program.methods.contains(where: { $0.lifecycle == name }) else { return }
        _ = try invoke(name)
    }
    public func savedFields() throws -> [String: SourceIRStoredValue] { try fields.mapValues(SourceIRStoredValue.init) }
    public func copySerializedFields(from original: SourceIRComponent) throws {
        guard program.source.sha256 == original.program.source.sha256,
              program.type.utf8.elementsEqual(original.program.type.utf8),
              program.fields.allSatisfy({ $0.serialized != nil }) else {
            throw SourcePluginError.invalid("Clone requires matching programs with recovered field serialization metadata.")
        }
        for field in program.fields where field.serialized == true { fields[field.name] = original.fields[field.name] }
    }
    public func restoreFields(_ saved: [String: SourceIRStoredValue]) throws {
        guard Set(saved.keys) == Set(program.fields.map(\.name)) else { throw SourcePluginError.invalid("Saved field identities differ from the translated component.") }
        let values = try saved.mapValues { try $0.value() }
        guard program.fields.allSatisfy({ values[$0.name]?.type == $0.type }) else { throw SourcePluginError.invalid("Saved field types differ from the translated component.") }
        fields = values
    }
    private func call(_ name: String, arguments: [SourceIRValue]) throws -> SourceIRValue {
        try consume(); callDepth += 1; defer { callDepth -= 1 }
        guard let method = program.methods.first(where: { $0.name == name }), arguments.count == method.parameters.count,
              zip(arguments, method.parameters).allSatisfy({ $0.type == $1.type }) else { throw SourcePluginError.runtime("Method arguments do not match \(name).") }
        var locals = [Dictionary(uniqueKeysWithValues: zip(method.parameters.map(\.name), arguments))]
        let result = try statement(method.body, &locals)
        let value: SourceIRValue
        switch result { case .next: value = .void; case .returned(let result): value = result }
        guard value.type == method.returnType else { throw SourcePluginError.runtime("Method return type mismatch.") }
        return value
    }
    private func expression(_ node: SourceIRProgram.Node, _ locals: inout [[String: SourceIRValue]]) throws -> SourceIRValue {
        try enterEvaluation(); defer { evaluationDepth -= 1 }
        try consume()
        let a = node.args, name = node.name ?? "", result: SourceIRValue
        switch node.kind {
        case "literal":
            switch (node.type, node.value) {
            case ("Bool", .bool(let v)): result = .bool(v)
            case ("String", .string(let v)): result = .string(v)
            case ("Float", .number(let n)) where Float(n).isFinite: result = .float(Float(n))
            case ("Double", .number(let n)): result = .double(n)
            case ("Int32", .number(let n)):
                guard let value = Int32(exactly: n) else { throw SourcePluginError.invalid("Int32 literal out of range.") }; result = .int32(value)
            default: throw SourcePluginError.invalid("Literal type mismatch.")
            }
        case "ref", "field": result = try get(location(node, &locals), locals)
        case "member":
            guard let lane = ["x": 0, "y": 1, "z": 2][name] else { throw SourcePluginError.invalid("Unknown vector member.") }
            result = .float(try expression(a[0], &locals).vector()[lane])
        case "space":
            guard name == "World" || name == "Self" else { throw SourcePluginError.invalid("Unknown Space.") }; result = .space(name == "World" ? .world : .local)
        case "convert":
            let value = try expression(a[0], &locals).number()
            guard node.type == "Float" || node.type == "Double" else { throw SourcePluginError.invalid("Unsupported conversion.") }
            result = node.type == "Float" ? .float(Float(value)) : .double(value)
        case "unary":
            let value = try expression(a[0], &locals)
            if name == "!" { result = .bool(try !value.boolean()) }
            else if name == "+" { result = value }
            else if name == "-" {
                switch value { case .float(let x): result = .float(-x); case .double(let x): result = .double(-x); default: throw SourcePluginError.runtime("Unsupported unary operand.") }
            } else { throw SourcePluginError.invalid("Unknown unary operator.") }
        case "binary":
            let left = try expression(a[0], &locals)
            if name == "&&", try !left.boolean() { result = .bool(false) }
            else if name == "||", try left.boolean() { result = .bool(true) }
            else { result = try binary(name, left, expression(a[1], &locals)) }
        case "conditional": result = try expression(a[expression(a[0], &locals).boolean() ? 1 : 2], &locals)
        case "call":
            var values: [SourceIRValue] = []
            for child in a { values.append(try expression(child, &locals)) }
            result = try call(name, arguments: values)
        case "api":
            var values: [SourceIRValue] = []
            for child in a { values.append(try expression(child, &locals)) }
            result = try api(name, values)
            try (context.world as? any SourceAPITransactionWorld)?.checkSourceFault()
        default: throw SourcePluginError.runtime("Statement used as expression: \(node.kind).")
        }
        guard result.type == node.type else { throw SourcePluginError.runtime("IR expression type mismatch at \(node.kind)/\(name).") }
        return result
    }
    private func binary(_ op: String, _ a: SourceIRValue, _ b: SourceIRValue) throws -> SourceIRValue {
        if case .bool(let x) = a, case .bool(let y) = b {
            switch op { case "&&": return .bool(x && y); case "||": return .bool(x || y); case "==": return .bool(x == y); case "!=": return .bool(x != y); default: break }
        }
        if case .vector(let x) = a {
            if case .vector(let y) = b {
                if op == "+" { return .vector(x + y) }; if op == "-" { return .vector(x - y) }
            } else if case .float(let n) = b {
                if op == "*" { return .vector(x * n) }; if op == "/" { return .vector(x / n) }
            }
        }
        if case .float(let n) = a, case .vector(let x) = b, op == "*" { return .vector(n * x) }
        guard a.type == b.type, ["Float", "Double", "Int32"].contains(a.type) else { throw SourcePluginError.runtime("Unsupported binary operand types.") }
        let x = try a.number(), y = try b.number()
        switch op {
        case "<": return .bool(x < y); case ">": return .bool(x > y); case "<=": return .bool(x <= y); case ">=": return .bool(x >= y)
        case "==": return .bool(x == y); case "!=": return .bool(x != y)
        default: break
        }
        if case .float(let x) = a, case .float(let y) = b {
            switch op { case "+": return .float(x + y); case "-": return .float(x - y); case "*": return .float(x * y); case "/": return .float(x / y); default: break }
        } else if a.type == "Double" {
            switch op { case "+": return .double(x + y); case "-": return .double(x - y); case "*": return .double(x * y); case "/": return .double(x / y); default: break }
        }
        throw SourcePluginError.runtime("Unsupported arithmetic operator or Int32 arithmetic.")
    }
    private func api(_ name: String, _ a: [SourceIRValue]) throws -> SourceIRValue {
        switch name {
        case "gameObject": return .object(gameObject)
        case "transform": return .transform(try a.first.map { try $0.object().transform } ?? gameObject.transform)
        case "position": return .vector(try a[0].transform().position)
        case "localPosition": return .vector(try a[0].transform().localPosition)
        case "localScale": return .vector(try a[0].transform().localScale)
        case "deltaTime": return .float(context.deltaTime)
        case "fixedDeltaTime": return .float(context.fixedDeltaTime)
        case "vector.zero": return .vector(.zero)
        case "vector.one": return .vector(SIMD3(repeating: 1))
        case "vector.init": return .vector(try SIMD3(Float(a[0].number()), Float(a[1].number()), Float(a[2].number())))
        case "math.Clamp01": return .float(try SourceAPIMath.clamp01(Float(a[0].number())))
        case "math.Sqrt": return .float(try SourceAPIMath.sqrt(Float(a[0].number())))
        case "math.Lerp": return .float(try SourceAPIMath.lerp(Float(a[0].number()), Float(a[1].number()), Float(a[2].number())))
        case "world.Instantiate": return .object(try context.world.instantiate(a[0].object()))
        case "world.Destroy": context.world.destroy(try a[0].object()); return .void
        case "setActive": try a[0].object().setActive(a[1].boolean()); return .void
        case "translate":
            guard case .space(let space) = a[2] else { throw SourcePluginError.runtime("Translate requires Space.") }
            try a[0].transform().translate(a[1].vector(), relativeTo: space); return .void
        default: throw SourcePluginError.invalid("Unknown API.")
        }
    }
    private func location(_ node: SourceIRProgram.Node, _ locals: inout [[String: SourceIRValue]]) throws -> Location {
        try enterEvaluation(); defer { evaluationDepth -= 1 }
        try consume()
        let name = node.name ?? ""
        switch node.kind {
        case "ref":
            guard let scope = locals.indices.reversed().first(where: { locals[$0][name] != nil }) else { throw SourcePluginError.runtime("Undefined local: \(name).") }
            return .local(scope, name)
        case "field":
            guard fields[name] != nil else { throw SourcePluginError.runtime("Undefined field: \(name).") }; return .field(name)
        case "member":
            guard let lane = ["x": 0, "y": 1, "z": 2][name] else { throw SourcePluginError.runtime("Invalid vector lane.") }
            return .lane(try location(node.args[0], &locals), lane)
        case "api" where ["position", "localPosition", "localScale"].contains(name):
            return .property(try expression(node.args[0], &locals).transform(), name)
        default: throw SourcePluginError.runtime("Invalid assignment destination.")
        }
    }
    private func get(_ location: Location, _ locals: [[String: SourceIRValue]]) throws -> SourceIRValue {
        switch location {
        case .local(let scope, let name): return locals[scope][name]!
        case .field(let name): return fields[name]!
        case .lane(let base, let lane): return .float(try get(base, locals).vector()[lane])
        case .property(let transform, let name):
            switch name { case "position": return .vector(transform.position); case "localPosition": return .vector(transform.localPosition); default: return .vector(transform.localScale) }
        }
    }
    private func set(_ location: Location, _ value: SourceIRValue, _ locals: inout [[String: SourceIRValue]]) throws {
        guard try get(location, locals).type == value.type else { throw SourcePluginError.runtime("Assignment changes value type.") }
        switch location {
        case .local(let scope, let name): locals[scope][name] = value
        case .field(let name): fields[name] = value
        case .lane(let base, let lane):
            var vector = try get(base, locals).vector(); vector[lane] = Float(try value.number()); try set(base, .vector(vector), &locals)
        case .property(let transform, let name):
            let vector = try value.vector()
            switch name { case "position": transform.position = vector; case "localPosition": transform.localPosition = vector; default: transform.localScale = vector }
        }
        try (context.world as? any SourceAPITransactionWorld)?.checkSourceFault()
    }
    private func statement(_ node: SourceIRProgram.Node, _ locals: inout [[String: SourceIRValue]]) throws -> Flow {
        try enterEvaluation(); defer { evaluationDepth -= 1 }
        try consume(); let a = node.args
        switch node.kind {
        case "empty": return .next
        case "block", "declarations":
            if node.kind == "block" { locals.append([:]) }
            defer { if node.kind == "block" { locals.removeLast() } }
            for child in a { let result = try statement(child, &locals); if case .returned = result { return result } }
            return .next
        case "local":
            guard let name = node.name, locals[locals.count - 1][name] == nil else { throw SourcePluginError.runtime("Duplicate local declaration.") }
            let value = try expression(a[0], &locals)
            guard value.type == node.type else { throw SourcePluginError.runtime("Local initializer type mismatch.") }
            locals[locals.count - 1][name] = value; return .next
        case "assign":
            let target = try location(a[0], &locals), op = node.name ?? ""
            guard ["=", "+=", "-=", "*=", "/="].contains(op) else { throw SourcePluginError.invalid("Invalid assignment operator.") }
            let old = op == "=" ? nil : try get(target, locals)
            let value = try expression(a[1], &locals)
            try set(target, old.map { try binary(String(op.prefix(1)), $0, value) } ?? value, &locals); return .next
        case "expression": _ = try expression(a[0], &locals); return .next
        case "return": return .returned(try a.first.map { try expression($0, &locals) } ?? .void)
        case "if": return try statement(a[expression(a[0], &locals).boolean() ? 1 : 2], &locals)
        default: throw SourcePluginError.runtime("Expression used as statement.")
        }
    }
}
