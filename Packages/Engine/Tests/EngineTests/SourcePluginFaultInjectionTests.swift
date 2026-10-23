import Foundation
import Testing
import CryptoKit
import simd
import CoreMath
import Gameplay
import Studio

// P-T04 Swift slice: seeded IR/manifest mutation, budget exhaustion, lifecycle
// failure injection and host failure injection. Every rejected operation must
// leave the full plugin snapshot (document, identities, clone serial, pending
// destruction, fault, bindings, clock and trace) exactly as before it.
// The original-C# and generated-Swift differential legs live in
// Tools/translation/tests/test_translation.py and need .NET/swiftc.

// MARK: - Deterministic generator

/// SplitMix64 (Steele, Lea and Flood 2014). A fixed seed reproduces every
/// mutation on every machine, unlike the seeded system generator.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(next() % UInt64(bound)) }
    mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

// MARK: - Mutable IR model and JSON writer

private enum FuzzValue { case bool(Bool), number(Double), string(String) }

private struct FuzzNode {
    var kind: String
    var type: String?
    var name: String?
    var value: FuzzValue?
    var children: [FuzzNode]?
    init(_ kind: String, _ type: String? = nil, _ name: String? = nil, _ children: [FuzzNode] = [], value: FuzzValue? = nil) {
        self.kind = kind; self.type = type; self.name = name; self.children = children; self.value = value
    }
    var args: [FuzzNode] { children ?? [] }
}

private struct FuzzField { var name: String, type: String, initializer: FuzzNode, serialized: Bool? }
private struct FuzzParameter { var name: String, type: String }
private struct FuzzMethod {
    var name: String, symbol: String, isStatic: Bool, returnType: String
    var parameters: [FuzzParameter], body: FuzzNode, lifecycle: String?
    static func callback(_ name: String, _ statements: [FuzzNode]) -> FuzzMethod {
        FuzzMethod(name: name, symbol: "M:Fuzz.Component.\(name)", isStatic: false, returnType: "Void",
                   parameters: [], body: IR.block(statements), lifecycle: name)
    }
    static func helper(_ name: String, returns: String = "Void", parameters: [FuzzParameter] = [], isStatic: Bool = false, body: [FuzzNode]) -> FuzzMethod {
        FuzzMethod(name: name, symbol: "M:Fuzz.Component.\(name)", isStatic: isStatic, returnType: returns,
                   parameters: parameters, body: IR.block(body), lifecycle: nil)
    }
}

private struct FuzzProgram {
    static let hash = String(repeating: "a", count: 64)
    var schemaVersion = 1
    var status = "ready"
    var mode = "component"
    var type = "Fuzz.Component"
    var identityType: String?
    var sourceSHA256 = FuzzProgram.hash
    var identitySourceSHA256: String?
    var bridgeSHA256 = FuzzProgram.hash
    var pluginGUID: String? = "Fuzz.Plugin_é"
    var symbols: [String]?
    var fields: [FuzzField] = []
    var methods: [FuzzMethod] = []
    var omitted: Set<String> = []
}

private enum FuzzJSON {
    static func string(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            if scalar == "\"" { out += "\\\"" }
            else if scalar == "\\" { out += "\\\\" }
            else if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
            else { out.unicodeScalars.append(scalar) }
        }
        return out + "\""
    }
    static func number(_ value: Double) -> String { value.isFinite ? "\(value)" : "0" }
    static func flag(_ value: Bool) -> String { value ? "true" : "false" }
    static func array(_ items: [String]) -> String { "[" + items.joined(separator: ",") + "]" }
    /// Members keep their written order; nil values and omitted keys are left out.
    static func object(_ members: KeyValuePairs<String, String?>, omitting omitted: Set<String> = []) -> String {
        var parts: [String] = []
        for (key, value) in members where !omitted.contains(key) {
            if let value { parts.append(FuzzJSON.string(key) + ":" + value) }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

extension FuzzNode {
    var json: String {
        let literal: String?
        switch value {
        case .bool(let flag)?: literal = FuzzJSON.flag(flag)
        case .number(let number)?: literal = FuzzJSON.number(number)
        case .string(let text)?: literal = FuzzJSON.string(text)
        case nil: literal = nil
        }
        let nested: String? = children.map { nodes in FuzzJSON.array(nodes.map { $0.json }) }
        return FuzzJSON.object(["kind": FuzzJSON.string(kind), "type": type.map(FuzzJSON.string),
                                "name": name.map(FuzzJSON.string), "value": literal, "children": nested])
    }
    func collect(_ prefix: [Int], into paths: inout [[Int]]) {
        paths.append(prefix)
        for (index, child) in args.enumerated() { child.collect(prefix + [index], into: &paths) }
    }
    func node(at path: ArraySlice<Int>) -> FuzzNode {
        guard let first = path.first, args.indices.contains(first) else { return self }
        return args[first].node(at: path.dropFirst())
    }
    mutating func update(at path: ArraySlice<Int>, _ body: (inout FuzzNode) -> Void) {
        guard let first = path.first else { body(&self); return }
        guard var nodes = children, nodes.indices.contains(first) else { return }
        nodes[first].update(at: path.dropFirst(), body)
        children = nodes
    }
}

private enum FuzzSlot { case field(Int), method(Int) }

extension FuzzProgram {
    func json() -> String {
        let fieldJSON: [String] = fields.map { field in
            FuzzJSON.object(["name": FuzzJSON.string(field.name), "type": FuzzJSON.string(field.type),
                             "initializer": field.initializer.json, "serialized": field.serialized.map(FuzzJSON.flag)])
        }
        let methodJSON: [String] = methods.map { method in
            let parameters = method.parameters.map { FuzzJSON.object(["name": FuzzJSON.string($0.name), "type": FuzzJSON.string($0.type)]) }
            return FuzzJSON.object(["name": FuzzJSON.string(method.name), "symbol": FuzzJSON.string(method.symbol),
                                    "static": FuzzJSON.flag(method.isStatic), "returnType": FuzzJSON.string(method.returnType),
                                    "parameters": FuzzJSON.array(parameters), "body": method.body.json,
                                    "lifecycle": method.lifecycle.map(FuzzJSON.string)])
        }
        let symbolList: [String] = symbols ?? methods.map { $0.symbol }
        let identity = FuzzJSON.object(["sourceSHA256": FuzzJSON.string(identitySourceSHA256 ?? sourceSHA256),
                                        "type": FuzzJSON.string(identityType ?? type),
                                        "symbols": FuzzJSON.array(symbolList.map(FuzzJSON.string)),
                                        "pluginGUID": pluginGUID.map(FuzzJSON.string)])
        return FuzzJSON.object(["schemaVersion": "\(schemaVersion)", "status": FuzzJSON.string(status),
                                "mode": FuzzJSON.string(mode), "type": FuzzJSON.string(type),
                                "source": FuzzJSON.object(["sha256": FuzzJSON.string(sourceSHA256)]),
                                "identity": identity, "fields": FuzzJSON.array(fieldJSON), "methods": FuzzJSON.array(methodJSON),
                                "semanticSurfaceSHA256": FuzzJSON.string(FuzzProgram.hash), "bridgeSHA256": FuzzJSON.string(bridgeSHA256),
                                "emitterSHA256": FuzzJSON.string(FuzzProgram.hash)], omitting: omitted)
    }
    func data() -> Data { Data(json().utf8) }
    func nodePaths() -> [(FuzzSlot, [Int])] {
        var result: [(FuzzSlot, [Int])] = []
        for (index, field) in fields.enumerated() {
            var paths: [[Int]] = []; field.initializer.collect([], into: &paths)
            for path in paths { result.append((FuzzSlot.field(index), path)) }
        }
        for (index, method) in methods.enumerated() {
            var paths: [[Int]] = []; method.body.collect([], into: &paths)
            for path in paths { result.append((FuzzSlot.method(index), path)) }
        }
        return result
    }
    func node(_ slot: FuzzSlot, _ path: [Int]) -> FuzzNode {
        switch slot {
        case .field(let index): return fields[index].initializer.node(at: path[...])
        case .method(let index): return methods[index].body.node(at: path[...])
        }
    }
    mutating func update(_ slot: FuzzSlot, _ path: [Int], _ body: (inout FuzzNode) -> Void) {
        switch slot {
        case .field(let index): fields[index].initializer.update(at: path[...], body)
        case .method(let index): methods[index].body.update(at: path[...], body)
        }
    }
}

/// Builders for the IR shapes the Roslyn frontend emits.
private enum IR {
    static func float(_ value: Float) -> FuzzNode { FuzzNode("literal", "Float", value: .number(Double(value))) }
    static func double(_ value: Double) -> FuzzNode { FuzzNode("literal", "Double", value: .number(value)) }
    static func int32(_ value: Int32) -> FuzzNode { FuzzNode("literal", "Int32", value: .number(Double(value))) }
    static func bool(_ value: Bool) -> FuzzNode { FuzzNode("literal", "Bool", value: .bool(value)) }
    static func string(_ value: String) -> FuzzNode { FuzzNode("literal", "String", value: .string(value)) }
    static func field(_ name: String, _ type: String) -> FuzzNode { FuzzNode("field", type, name) }
    static func ref(_ name: String, _ type: String) -> FuzzNode { FuzzNode("ref", type, name) }
    static func api(_ name: String, _ type: String, _ args: [FuzzNode] = []) -> FuzzNode { FuzzNode("api", type, name, args) }
    static var transform: FuzzNode { api("transform", "Transform") }
    static var gameObject: FuzzNode { api("gameObject", "Object") }
    static var one: FuzzNode { api("vector.one", "Vector3") }
    static var worldSpace: FuzzNode { FuzzNode("space", "Space", "World") }
    static var selfSpace: FuzzNode { FuzzNode("space", "Space", "Self") }
    static func vector(_ x: Float, _ y: Float, _ z: Float) -> FuzzNode { api("vector.init", "Vector3", [float(x), float(y), float(z)]) }
    static func binary(_ op: String, _ type: String, _ left: FuzzNode, _ right: FuzzNode) -> FuzzNode { FuzzNode("binary", type, op, [left, right]) }
    static func unary(_ op: String, _ type: String, _ operand: FuzzNode) -> FuzzNode { FuzzNode("unary", type, op, [operand]) }
    static func assign(_ target: FuzzNode, _ op: String, _ value: FuzzNode) -> FuzzNode { FuzzNode("assign", nil, op, [target, value]) }
    static func expression(_ value: FuzzNode) -> FuzzNode { FuzzNode("expression", nil, nil, [value]) }
    static func block(_ statements: [FuzzNode]) -> FuzzNode { FuzzNode("block", nil, nil, statements) }
    static func when(_ condition: FuzzNode, _ then: FuzzNode, _ otherwise: FuzzNode = FuzzNode("empty")) -> FuzzNode {
        FuzzNode("if", nil, nil, [condition, then, otherwise])
    }
    static func call(_ name: String, _ type: String = "Void", _ args: [FuzzNode] = []) -> FuzzNode { FuzzNode("call", type, name, args) }
    static func translate(_ delta: FuzzNode, _ space: FuzzNode = IR.worldSpace) -> FuzzNode {
        expression(api("translate", "Void", [transform, delta, space]))
    }
    static func increment(_ name: String, by amount: Float = 1) -> FuzzNode { assign(field(name, "Float"), "+=", float(amount)) }
    static func equals(_ name: String, _ code: Int32) -> FuzzNode { binary("==", "Bool", field(name, "Int32"), int32(code)) }
    static func instantiate() -> FuzzNode { api("world.Instantiate", "Object", [gameObject]) }
    static func destroy() -> FuzzNode { expression(api("world.Destroy", "Void", [gameObject])) }
    static func setActive(_ active: Bool) -> FuzzNode { expression(api("setActive", "Void", [gameObject, bool(active)])) }
}

// MARK: - Templates

private enum FuzzTemplates {
    static func floats(_ names: [String]) -> [FuzzField] {
        names.map { FuzzField(name: $0, type: "Float", initializer: IR.float(0), serialized: true) }
    }
    /// Locals, declarations, lanes of a transform property, conditionals,
    /// short circuit, calls and every value type, without clone/destroy.
    static func motion() -> FuzzProgram {
        var program = FuzzProgram()
        program.fields = [
            FuzzField(name: "ticks", type: "Float", initializer: IR.float(0), serialized: true),
            FuzzField(name: "speed", type: "Float", initializer: IR.float(0.5), serialized: false),
            FuzzField(name: "flag", type: "Bool", initializer: IR.bool(false), serialized: true),
            FuzzField(name: "label", type: "String", initializer: IR.string("fuzz"), serialized: true),
            FuzzField(name: "count", type: "Int32", initializer: IR.int32(0), serialized: true),
            FuzzField(name: "offset", type: "Vector3", initializer: IR.vector(1, 2, 3), serialized: true),
            FuzzField(name: "mode", type: "Space", initializer: IR.worldSpace, serialized: false),
            FuzzField(name: "total", type: "Double", initializer: IR.double(0), serialized: true)]
        let ticks = IR.field("ticks", "Float"), step = IR.ref("step", "Float"), flag = IR.field("flag", "Bool")
        let offset = IR.field("offset", "Vector3"), total = IR.field("total", "Double")
        let lane = FuzzNode("member", "Float", "x", [IR.api("localPosition", "Vector3", [IR.transform])])
        program.methods = [
            .callback("Awake", [IR.assign(offset, "=", IR.binary("*", "Vector3", offset, IR.float(0.5)))]),
            .callback("Start", [IR.assign(total, "+=", FuzzNode("convert", "Double", nil, [IR.api("fixedDeltaTime", "Float")]))]),
            .callback("FixedUpdate", [IR.assign(total, "+=", IR.double(0.25))]),
            .callback("Update", [
                FuzzNode("declarations", nil, nil, [FuzzNode("local", "Float", "step", [IR.binary("*", "Float", IR.api("deltaTime", "Float"), IR.field("speed", "Float"))])]),
                IR.assign(ticks, "+=", step),
                IR.when(IR.binary(">", "Bool", ticks, IR.float(0.001)), IR.translate(IR.binary("*", "Vector3", offset, step), IR.field("mode", "Space"))),
                IR.assign(lane, "=", IR.api("math.Clamp01", "Float", [ticks])),
                IR.assign(flag, "=", IR.binary("||", "Bool", flag, IR.binary(">=", "Bool", ticks, IR.float(0.01)))),
                IR.assign(ticks, "=", IR.call("Helper", "Float", [ticks]))]),
            .callback("LateUpdate", [
                FuzzNode("local", "Float", "half", [FuzzNode("conditional", "Float", nil, [flag, IR.float(0.5), IR.float(0.25)])]),
                IR.when(IR.unary("!", "Bool", flag), FuzzNode("return")),
                IR.assign(IR.field("count", "Int32"), "=", IR.int32(2))]),
            .callback("OnDisable", [IR.assign(IR.field("label", "String"), "=", IR.string("off"))]),
            .helper("Helper", returns: "Float", parameters: [FuzzParameter(name: "x", type: "Float")],
                    body: [FuzzNode("return", nil, nil, [IR.api("math.Lerp", "Float", [IR.ref("x", "Float"), IR.float(1), IR.float(0.5)])])])]
        return program
    }
    /// One guarded self-clone in Update and a self-destroy in LateUpdate. The
    /// serialized guard is copied, so clones never clone again.
    static func spawn() -> FuzzProgram {
        var program = FuzzProgram()
        program.fields = [
            FuzzField(name: "spawned", type: "Bool", initializer: IR.bool(false), serialized: true),
            FuzzField(name: "hits", type: "Float", initializer: IR.float(0), serialized: true),
            FuzzField(name: "scratch", type: "Float", initializer: IR.float(3), serialized: false)]
        let spawned = IR.field("spawned", "Bool")
        program.methods = [
            .callback("Awake", [IR.increment("scratch")]),
            .callback("OnEnable", [IR.increment("scratch", by: 0.5)]),
            .callback("Start", [IR.increment("hits", by: 0.25)]),
            .callback("Update", [
                IR.increment("hits"), IR.translate(IR.one, IR.selfSpace),
                IR.when(IR.unary("!", "Bool", spawned), IR.block([
                    IR.assign(spawned, "=", IR.bool(true)),
                    IR.expression(IR.api("setActive", "Void", [IR.instantiate(), IR.bool(true)]))]))]),
            .callback("LateUpdate", [IR.when(IR.binary(">=", "Bool", IR.field("hits", "Float"), IR.float(2)), IR.destroy())]),
            .callback("OnDisable", [IR.increment("hits", by: 10)]),
            .callback("OnDestroy", [IR.assign(IR.field("scratch", "Float"), "=", IR.float(-1)), IR.translate(IR.one)])]
        return program
    }
    /// A second, fixed component proves that a rejected operation of the
    /// fuzzed component does not leave callbacks or fields of another entry.
    static func observer() -> FuzzProgram {
        var program = FuzzProgram()
        program.type = "Fuzz.Observer"; program.pluginGUID = "Fuzz.Observer"
        program.fields = floats(["awakes", "enables", "updates", "disables", "destroys"])
        program.methods = [
            .callback("Awake", [IR.increment("awakes")]),
            .callback("OnEnable", [IR.increment("enables")]),
            .callback("Update", [IR.increment("updates"), IR.translate(IR.one)]),
            .callback("OnDisable", [IR.increment("disables")]),
            .callback("OnDestroy", [IR.increment("destroys")])]
        return program
    }
}

// MARK: - Mutations

private enum FuzzMutation {
    static let kinds = ["literal", "ref", "field", "space", "empty", "member", "convert", "unary", "local", "expression", "binary",
                        "assign", "conditional", "if", "return", "block", "declarations", "call", "api", "loop", "lambda", ""]
    static let types = ["Void", "Float", "Double", "Int32", "Bool", "String", "Vector3", "Object", "Transform", "Space", "Int64", "Matrix4x4"]
    // `world.Instantiate` is deliberately absent: a clone created inside the
    // destruction barrier can chain toward the 1024-entry limit with quadratic
    // world lookups. Clone rollback has its own directed tests below.
    static let apis = ["transform", "gameObject", "position", "localPosition", "localScale", "deltaTime", "fixedDeltaTime", "vector.zero",
                       "vector.one", "vector.init", "math.Clamp01", "math.Sqrt", "math.Lerp", "world.Destroy", "setActive", "translate",
                       "arbitrary.Reflection", "Input.GetKey"]
    static let operators = ["+", "-", "*", "/", "<", ">", "<=", ">=", "==", "!=", "&&", "||", "!", "=", "+=", "-=", "*=", "/=",
                            "%", "<<", "??", "x", "y", "z", "w", "World", "Self", "Local"]
    // Finite only: JSON cannot carry NaN/infinity, and Float literals beyond
    // Float range must be rejected rather than stored as infinity.
    static let constants: [Double] = [0, -0.0, 1, -1, 0.5, 0.1, 1.401298464324817e-45, 3.4028234663852886e38, 3.5e38, 1e39,
                                      1e308, -1e308, 5e-324, 2147483647, 2147483648, -2147483649, 16777217, 1e16]
    static let lifecycleNames = ["Awake", "OnEnable", "Start", "FixedUpdate", "Update", "LateUpdate", "OnDisable", "OnDestroy", "OnGUI", "Reset", ""]
    static func snippets() -> [FuzzNode] {
        [IR.float(1), IR.double(2), IR.int32(3), IR.bool(true), IR.string("s"), IR.field("ticks", "Float"), IR.field("hits", "Float"),
         IR.field("flag", "Bool"), IR.ref("step", "Float"), IR.api("deltaTime", "Float"), IR.api("fixedDeltaTime", "Float"),
         IR.one, IR.vector(1, 2, 3), IR.api("position", "Vector3", [IR.transform]), IR.api("localScale", "Vector3", [IR.transform]),
         IR.gameObject, IR.transform, IR.api("transform", "Transform", [IR.gameObject]), IR.api("math.Sqrt", "Float", [IR.float(-1)]),
         IR.binary("/", "Vector3", IR.one, IR.float(0)), FuzzNode("member", "Float", "x", [IR.one]),
         FuzzNode("convert", "Double", nil, [IR.float(1)]), FuzzNode("convert", "Float", nil, [IR.double(1e300)]),
         IR.worldSpace, IR.selfSpace, FuzzNode("empty"), FuzzNode("return"), IR.block([]),
         IR.translate(IR.one), IR.translate(IR.binary("/", "Vector3", IR.one, IR.float(0))), IR.setActive(false), IR.setActive(true),
         IR.destroy(), IR.increment("ticks"), IR.increment("hits", by: 3e38),
         IR.assign(IR.api("localScale", "Vector3", [IR.transform]), "=", IR.vector(0, 0, 0)),
         IR.assign(IR.api("localScale", "Vector3", [IR.transform]), "=", IR.vector(-1, 1, 1)),
         IR.assign(IR.api("position", "Vector3", [IR.transform]), "=", IR.vector(Float.greatestFiniteMagnitude, 0, 0)),
         IR.assign(FuzzNode("member", "Float", "y", [IR.api("localPosition", "Vector3", [IR.transform])]), "-=", IR.float(0.25)),
         FuzzNode("local", "Float", "fresh", [IR.float(4)]), IR.expression(IR.call("Helper", "Float", [IR.float(2)]))]
    }

    static func apply(_ program: inout FuzzProgram, _ rng: inout SplitMix64) -> String {
        let paths = program.nodePaths()
        guard !paths.isEmpty else { return "empty" }
        let (slot, path) = rng.pick(paths)
        let node = program.node(slot, path)
        switch rng.below(15) {
        case 0:
            let kind = rng.pick(kinds)
            program.update(slot, path) { $0.kind = kind }
            return "kind:\(kind)"
        case 1:
            let type: String? = rng.chance(15) ? nil : rng.pick(types)
            program.update(slot, path) { $0.type = type }
            return "type:\(type ?? "nil")"
        case 2:
            let name: String?
            switch node.kind {
            case "api": name = rng.pick(apis)
            case "call": name = rng.pick(program.methods.map { $0.name } + ["Missing", ""])
            case "field", "ref", "local": name = rng.pick(program.fields.map { $0.name } + ["step", "undefined", ""])
            default: name = rng.chance(20) ? nil : rng.pick(operators)
            }
            program.update(slot, path) { $0.name = name }
            return "name:\(name ?? "nil")"
        case 3:
            let value: FuzzValue?
            switch rng.below(6) {
            case 0: value = nil
            case 1: value = .bool(rng.chance(50))
            case 2: value = .string(rng.chance(10) ? String(repeating: "x", count: 65537) : "text")
            default: value = .number(rng.pick(constants))
            }
            program.update(slot, path) { $0.value = value }
            return "value"
        case 4:
            let extra = rng.pick(snippets()), choice = rng.below(4)
            program.update(slot, path) { target in
                var nodes = target.args
                switch choice {
                case 0: nodes.append(extra)
                case 1: if !nodes.isEmpty { nodes.removeLast() }
                case 2: nodes.removeAll()
                default: target.children = nil; return
                }
                target.children = nodes
            }
            return "arity:\(choice)"
        case 5:
            program.update(slot, path) { target in
                var nodes = target.args
                guard nodes.count >= 2 else { return }
                nodes.swapAt(0, nodes.count - 1); target.children = nodes
            }
            return "swap"
        case 6:
            let replacement = rng.pick(snippets())
            program.update(slot, path) { $0 = replacement }
            return "replace:\(replacement.kind)/\(replacement.name ?? "")"
        case 7:
            let count = node.args.count
            guard count > 0 else { return "duplicate:none" }
            let index = rng.below(count), copies = rng.pick([1, 2, 3, 2049])
            program.update(slot, path) { target in
                var nodes = target.args
                let copied = Array(repeating: nodes[index], count: copies)
                nodes.insert(contentsOf: copied, at: index)
                target.children = nodes
            }
            return "duplicate:\(copies)"
        case 8:
            switch rng.below(3) {
            case 0:
                let count = node.args.count
                guard count > 0 else { return "truncate:none" }
                let index = rng.below(count)
                program.update(slot, path) { target in
                    var nodes = target.args; nodes.remove(at: index); target.children = nodes
                }
            case 1: if !program.methods.isEmpty { program.methods.remove(at: rng.below(program.methods.count)) }
            default: if !program.fields.isEmpty { program.fields.remove(at: rng.below(program.fields.count)) }
            }
            return "truncate"
        case 9:
            // Validation accepts depth 24; the interpreter's evaluation stack
            // is 16, so 14-24 must be a runtime budget error, not a trap.
            // Total depth stays <= 40 so JSON decoding recursion stays small
            // on a test thread's stack.
            let deepest = paths.map { $0.1.count }.max() ?? 0
            let depth = min(rng.pick([1, 4, 8, 13, 14, 20, 23, 30]), 40 - deepest)
            guard depth > 0 else { return "nest:none" }
            let statement = ["block", "declarations", "if", "local", "assign", "expression", "return", "empty"].contains(node.kind)
            program.update(slot, path) { target in
                for _ in 0..<depth { target = statement ? IR.block([target]) : FuzzNode("unary", target.type, "+", [target]) }
            }
            return "nest:\(depth)"
        case 10:
            guard !program.methods.isEmpty else { return "lifecycle:none" }
            let index = rng.below(program.methods.count)
            switch rng.below(7) {
            case 0: program.methods[index].lifecycle = rng.pick(lifecycleNames)
            case 1:
                let name = rng.pick(lifecycleNames)
                program.methods[index].name = name; program.methods[index].lifecycle = name
            case 2: program.methods[index].parameters.append(FuzzParameter(name: "extra", type: rng.pick(types)))
            case 3: program.methods[index].returnType = rng.pick(types)
            case 4: program.methods[index].isStatic.toggle()
            case 5: let copy = program.methods[index]; program.methods.append(copy)
            default: program.methods[index].lifecycle = nil
            }
            return "lifecycle"
        case 11:
            guard !program.fields.isEmpty else { return "field:none" }
            let index = rng.below(program.fields.count)
            switch rng.below(5) {
            case 0: program.fields[index].type = rng.pick(types)
            case 1: let copy = program.fields[index]; program.fields.append(copy)
            case 2: program.fields[index].serialized = nil
            case 3: program.fields[index].name = rng.pick(["", "undefined", "ticks"])
            default: program.fields[index].initializer = rng.pick(snippets())
            }
            return "field"
        case 12:
            let guids: [String?] = [nil, "", String(repeating: "g", count: 1025), "Fuzz.Plugin_e\u{301}"]
            switch rng.below(10) {
            case 0: program.schemaVersion = rng.pick([0, 2, -1])
            case 1: program.status = "rejected"
            case 2: program.mode = rng.pick(["methods", "Component", ""])
            case 3: program.identityType = program.type + "x"
            case 4: program.sourceSHA256 = String(repeating: "A", count: 64)
            case 5: program.identitySourceSHA256 = String(repeating: "b", count: 64)
            case 6: program.bridgeSHA256 = String(repeating: "a", count: 63)
            case 7: program.pluginGUID = rng.pick(guids)
            case 8: program.symbols = Array(program.methods.map { $0.symbol }.reversed())
            default: program.omitted.insert(rng.pick(["identity", "fields", "methods", "source", "status", "schemaVersion"]))
            }
            return "header"
        case 13:
            switch rng.below(4) {
            case 0: program.fields += (0..<513).map { FuzzField(name: "bulk\($0)", type: "Float", initializer: IR.float(0), serialized: true) }
            case 1: if !program.methods.isEmpty { program.methods[0].parameters = (0..<65).map { FuzzParameter(name: "p\($0)", type: "Float") } }
            case 2: if !program.methods.isEmpty { program.methods[0].body = IR.block(Array(repeating: FuzzNode("empty"), count: 2049)) }
            default: program.methods += (0..<513).map { FuzzMethod.helper("Bulk\($0)", body: []) }
            }
            return "oversized"
        default:
            // A callback receives another callback's body: valid shapes, wrong content.
            guard program.methods.count >= 2 else { return "bodies:none" }
            let a = rng.below(program.methods.count), b = rng.below(program.methods.count)
            let body = program.methods[a].body
            program.methods[a].body = program.methods[b].body; program.methods[b].body = body
            return "bodies"
        }
    }

    /// Byte-level damage: truncated streams, foreign tokens, duplicated runs.
    static func corrupt(_ data: Data, _ rng: inout SplitMix64) -> Data {
        var bytes = [UInt8](data)
        guard bytes.count > 8 else { return data }
        switch rng.below(3) {
        case 0: bytes.removeLast(1 + rng.below(bytes.count - 1))
        case 1:
            let index = rng.below(bytes.count), replacement = rng.pick(Array("{}[]\",:0-e".utf8))
            bytes[index] = replacement
        default:
            let start = rng.below(bytes.count - 4), chunk = Array(bytes[start..<(start + 4)])
            bytes.insert(contentsOf: chunk, at: start)
        }
        return Data(bytes)
    }
}

// MARK: - Snapshots, invariants and outcomes

/// Everything a rejected operation could leave behind. Rows use host
/// identities instead of clone UUIDs, so two runs compare too.
private struct PluginSnapshot: Equatable {
    struct Row: Equatable {
        let identity: String, parent: String?, name: String, visible: Bool, attachment: Int32?
        let transform: [UInt32]
    }
    let rows: [Row]
    let identities: [String]
    let cloneSerial: UInt64
    let pending: [String]
    let faultFree: Bool
    let bindings: [SourcePluginBindingState]
    let clock: SourcePluginClockState
    let trace: [String]

    init(_ world: SourceStudioPluginWorld, _ runtime: SourcePluginRuntime) throws {
        let ids = world.identities
        var rows: [Row] = []
        for object in world.document.objects {
            let t = object.transform
            var bits: [UInt32] = []
            for v in [t.position, t.rotation, t.scale] { bits += [v.x.bitPattern, v.y.bitPattern, v.z.bitPattern] }
            if let r = t.rotationOverride { bits += [r.x.bitPattern, r.y.bitPattern, r.z.bitPattern, r.w.bitPattern] }
            let parent: String? = object.parent.map { ids[$0] ?? "?" }
            rows.append(Row(identity: ids[object.id] ?? "?", parent: parent, name: object.name, visible: object.visible,
                            attachment: object.sourceAttachmentPoint, transform: bits))
        }
        self.rows = rows
        identities = ids.values.sorted()
        cloneSerial = world.cloneSerial
        pending = world.pendingSourceDestruction().map { $0.sourceIdentity }.sorted()
        var clean = true
        do { try world.checkSourceFault() } catch { clean = false }
        faultFree = clean
        bindings = try runtime.savedBindings()
        clock = runtime.savedClock()
        trace = runtime.callbackTrace
    }
}

private func category(_ error: any Error) -> String {
    if let plugin = error as? SourcePluginError {
        switch plugin {
        case .invalid: return "invalid"
        case .budget: return "budget"
        case .runtime: return "runtime"
        }
    }
    return error is DecodingError ? "decoding" : "undefined: \(error)"
}

private func outcome(_ body: () throws -> Void) -> String {
    do { try body(); return "ok" } catch { return category(error) }
}

/// Load-time failures may also be Foundation file errors (a missing file).
private func isDefinedLoadError(_ error: any Error) -> Bool {
    error is SourcePluginError || error is DecodingError || error is CocoaError || error is POSIXError
}

private func storedType(_ value: SourceIRStoredValue) -> String {
    switch value {
    case .float: return "Float"
    case .double: return "Double"
    case .int32: return "Int32"
    case .bool: return "Bool"
    case .string: return "String"
    case .vector(let lanes): return lanes.count == 3 ? "Vector3" : "BadVector"
    case .space: return "Space"
    }
}

/// Invariants that every committed operation keeps: finite host transforms,
/// declared field identities/types and no fault left outside a transaction.
private func invariantViolations(_ world: SourceStudioPluginWorld, _ runtime: SourcePluginRuntime) throws -> [String] {
    var violations: [String] = []
    for object in world.document.objects {
        let t = object.transform
        var values: [Float] = []
        for v in [t.position, t.rotation, t.scale] { values += [v.x, v.y, v.z] }
        if let r = t.rotationOverride { values += [r.x, r.y, r.z, r.w] }
        if !values.allSatisfy({ $0.isFinite }) { violations.append("nonfinite transform: \(object.name)") }
    }
    for (index, binding) in try runtime.savedBindings().enumerated() {
        let declared = try runtime.component(at: index).program.fields
        if Set(binding.fields.keys) != Set(declared.map { $0.name }) { violations.append("field identities of entry \(index)") }
        for field in declared where binding.fields[field.name].map(storedType) != field.type {
            violations.append("field type \(index)/\(field.name)")
        }
    }
    do { try world.checkSourceFault() } catch { violations.append("residual fault: \(error)") }
    return violations
}

private func setField(_ runtime: SourcePluginRuntime, _ index: Int, _ name: String, _ value: SourceIRStoredValue) throws {
    let component = try runtime.component(at: index)
    var fields = try component.savedFields()
    fields[name] = value
    try component.restoreFields(fields)
}

private func setFieldEverywhere(_ runtime: SourcePluginRuntime, _ name: String, _ value: SourceIRStoredValue) throws {
    for index in try runtime.savedBindings().indices { try setField(runtime, index, name, value) }
}

private func storedFloat(_ runtime: SourcePluginRuntime, _ index: Int, _ name: String) throws -> Float {
    let bindings = try runtime.savedBindings()
    guard bindings.indices.contains(index), case .float(let bits)? = bindings[index].fields[name] else {
        throw SourcePluginError.invalid("Missing fixture float: \(name).")
    }
    return Float(bitPattern: bits)
}

/// Trace entries reduced to `[clone.]Event`; identities are checked by snapshots.
private func events(_ trace: [String]) -> [String] {
    trace.map { entry in (entry.contains("/clone/") ? "clone." : "") + (entry.split(separator: ":").last.map(String.init) ?? "") }
}

private func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private struct PluginHost {
    let world: SourceStudioPluginWorld, runtime: SourcePluginRuntime
    init(_ objects: [StudioObject], attachment: SourceStudioPluginWorld.AttachmentResolver? = nil) throws {
        var document = StudioDocument(); document.objects = objects
        world = try SourceStudioPluginWorld(document: document, attachment: attachment)
        runtime = try SourcePluginRuntime(world: world, fixedDeltaTime: 0.02)
    }
    func snapshot() throws -> PluginSnapshot { try PluginSnapshot(world, runtime) }
    @discardableResult func attach(_ program: SourceIRProgram, to object: StudioObject) throws -> Int {
        try runtime.attach(program: program, object: world.object(id: object.id))
    }
}

private final class HostFaultSwitch {
    var calls = 0
    var failAt: Int?
}

private enum HostFault: Error, Equatable { case injected(Int) }

// MARK: - Seeded IR fuzzing

private struct FuzzRun { var outcomes: [String] = []; var ending: PluginSnapshot? }

/// Each operation either commits with the invariants intact or throws a
/// defined error and restores the full snapshot it started from.
private func runFuzzScenario(_ program: SourceIRProgram, observer: SourceIRProgram, objects: [StudioObject],
                             plan: [Float], context: String) throws -> FuzzRun {
    let host = try PluginHost(objects)
    try host.attach(observer, to: objects[1])
    var run = FuzzRun()
    func perform(_ label: String, _ body: () throws -> Void) throws {
        let before = try host.snapshot()
        do {
            try body()
            run.outcomes.append(label + ":ok")
            let violations = try invariantViolations(host.world, host.runtime)
            #expect(violations.isEmpty, "\(context) \(label): \(violations)")
        } catch {
            let kind = category(error)
            run.outcomes.append(label + ":" + kind)
            #expect(error is SourcePluginError, "\(context) \(label): undefined error \(error)")
            let after = try host.snapshot()
            #expect(after == before, "\(context) \(label): rejected operation left partial state")
        }
    }
    try perform("attach") { _ = try host.attach(program, to: objects[0]) }
    try perform("start") { try host.runtime.start() }
    for (index, delta) in plan.enumerated() {
        // Bounded scenario: a mutated guard may clone every frame.
        if try host.runtime.savedBindings().count > 128 { run.outcomes.append("stopped"); break }
        try perform("step\(index)") { try host.runtime.step(deltaTime: delta) }
    }
    run.ending = try host.snapshot()
    return run
}

@Test func sourcePluginSeededIRMutationsLoadDeterministicallyOrFailWithoutPartialState() throws {
    let objects = [StudioObject(name: "FuzzTarget", kind: .folder), StudioObject(name: "Observer", kind: .folder)]
    let observer = try SourceIRProgram.decode(FuzzTemplates.observer().data())
    let deltas: [Float] = [1.4, -1, .nan, .infinity, .greatestFiniteMagnitude]
    var rejected = 0, clean = 0, failed = 0
    let seeds: [(template: Int, seed: UInt64)] = [(0, 0x5EED_0001), (1, 0x5EED_0002), (0, 0x5EED_0003), (1, 0x5EED_0004)]
    for (template, seed) in seeds {
        var rng = SplitMix64(seed: seed)
        for iteration in 0..<64 {
            var program = template == 0 ? FuzzTemplates.motion() : FuzzTemplates.spawn()
            var labels: [String] = []
            if iteration > 0 { for _ in 0..<(1 + rng.below(3)) { labels.append(FuzzMutation.apply(&program, &rng)) } }
            var data = program.data()
            if iteration > 0, rng.chance(10) { data = FuzzMutation.corrupt(data, &rng); labels.append("bytes") }
            // 0.02/0.01/0 run one fixed step per frame; the replacements are
            // the fixed-step budget (70 steps) and invalid frame deltas.
            var plan: [Float] = [0.02, 0.01, 0]
            if iteration > 0, rng.chance(15) { let slot = rng.below(plan.count); plan[slot] = rng.pick(deltas) }
            let context = "template \(template) seed \(seed) iteration \(iteration) \(labels) plan \(plan)"
            let decoded: SourceIRProgram
            do { decoded = try SourceIRProgram.decode(data) } catch {
                #expect(isDefinedLoadError(error), "\(context): undefined decode error \(error)")
                rejected += 1; continue
            }
            let first = try runFuzzScenario(decoded, observer: observer, objects: objects, plan: plan, context: context)
            let second = try runFuzzScenario(decoded, observer: observer, objects: objects, plan: plan, context: context)
            #expect(first.outcomes == second.outcomes, "\(context): nondeterministic outcomes")
            #expect(first.ending == second.ending, "\(context): nondeterministic final state")
            let allCommitted = first.outcomes.allSatisfy { $0.hasSuffix(":ok") }
            if iteration == 0 { #expect(allCommitted, "\(context): unmutated template failed \(first.outcomes)") }
            if allCommitted { clean += 1 } else { failed += 1 }
        }
    }
    #expect(rejected > 0 && clean > 0, "rejected \(rejected) clean \(clean) failed \(failed)")
}

// MARK: - Seeded manifest fuzzing

private typealias FuzzDependency = (guid: String, minimumVersion: String?, required: Bool)

private struct FuzzManifest {
    struct Component { var type: String, file: String, sha256: String }
    var schemaVersion = 1
    var kind = "ikkoku-translated-plugin"
    var guid: String
    var version = "1.0"
    var name = "Fuzz manifest"
    var processes = ["CharaStudio"]
    var dependencies: [FuzzDependency] = []
    var incompatibilities: [String] = []
    var components: [Component]
    var omitted: Set<String> = []
    var wrongTypeKey: String?
    var truncateAt: Int?
    var padding = 0
    init(guid: String, type: String, sha256: String) {
        self.guid = guid
        components = [Component(type: type, file: "program.json", sha256: sha256)]
    }
    func json() -> String {
        func entry(_ key: String, _ json: String) -> String? { wrongTypeKey == key ? "17" : json }
        let identity = FuzzJSON.object(["guid": FuzzJSON.string(guid), "version": FuzzJSON.string(version), "name": FuzzJSON.string(name)])
        let dependencyJSON: [String] = dependencies.map { dependency in
            FuzzJSON.object(["guid": FuzzJSON.string(dependency.guid), "minimumVersion": dependency.minimumVersion.map(FuzzJSON.string),
                             "required": FuzzJSON.flag(dependency.required)])
        }
        let componentJSON: [String] = components.map { component in
            FuzzJSON.object(["type": FuzzJSON.string(component.type),
                             "program": FuzzJSON.object(["file": FuzzJSON.string(component.file), "sha256": FuzzJSON.string(component.sha256)])])
        }
        let body = FuzzJSON.object(["schemaVersion": entry("schemaVersion", "\(schemaVersion)"), "kind": entry("kind", FuzzJSON.string(kind)),
                                    "identity": entry("identity", identity),
                                    "processes": entry("processes", FuzzJSON.array(processes.map(FuzzJSON.string))),
                                    "dependencies": entry("dependencies", FuzzJSON.array(dependencyJSON)),
                                    "incompatibilities": entry("incompatibilities", FuzzJSON.array(incompatibilities.map(FuzzJSON.string))),
                                    "components": entry("components", FuzzJSON.array(componentJSON))], omitting: omitted)
        return body + String(repeating: " ", count: padding)
    }
    func data() -> Data {
        let bytes = Data(json().utf8)
        guard let truncateAt else { return bytes }
        return bytes.prefix(truncateAt)
    }
    mutating func mutate(_ rng: inout SplitMix64, program bytes: inout Data) -> String {
        guard let first = components.first else { return "none" }
        switch rng.below(16) {
        case 0: schemaVersion = rng.pick([0, 2]); return "schemaVersion"
        case 1: kind = rng.pick(["", "ikkoku-native-adapter"]); return "kind"
        case 2: guid = rng.pick(["", String(repeating: "g", count: 1025), "Other.GUID", "Fuzz.Manifest_e\u{301}"]); return "guid"
        case 3: version = rng.pick(["", String(repeating: "9", count: 1025), "1.0.0.0.0"]); return "version"
        case 4: name = ""; return "name"
        case 5:
            let options: [[String]] = [[""], Array(repeating: "CharaStudio", count: 33), ["Koikatu"], ["charastudio.exe"], []]
            processes = rng.pick(options); return "processes"
        case 6:
            let required: FuzzDependency = (guid: "Fuzz.Dependency", minimumVersion: "1.0", required: true)
            let optional: FuzzDependency = (guid: "Fuzz.Optional", minimumVersion: "9.0", required: false)
            let empty: FuzzDependency = (guid: "", minimumVersion: nil, required: true)
            let options: [[FuzzDependency]] = [[required, required], [empty], Array(repeating: optional, count: 129), [optional], [required]]
            dependencies = rng.pick(options); return "dependencies"
        case 7:
            let options: [[String]] = [[""], Array(repeating: "X", count: 129), [guid]]
            incompatibilities = rng.pick(options); return "incompatibilities"
        case 8:
            let options: [[Component]] = [[], [first, first], Array(repeating: first, count: 129)]
            components = rng.pick(options); return "components"
        case 9: components[0].type = rng.pick(["", "Fuzz.Other", "fuzz.component"]); return "componentType"
        case 10: components[0].file = rng.pick(["", "/program.json", "../program.json", "missing.json", "./program.json", "sub/../program.json"]); return "file"
        case 11:
            let hash = first.sha256
            components[0].sha256 = rng.pick([String(repeating: "0", count: 64), String(hash.dropLast()), hash.uppercased()]); return "sha256"
        case 12: bytes.append(32); return "programChanged"
        case 13: omitted.insert(rng.pick(["identity", "processes", "components", "kind", "dependencies"])); return "omitted"
        case 14: wrongTypeKey = rng.pick(["processes", "identity", "components", "schemaVersion"]); return "wrongType"
        default:
            if rng.chance(50) { truncateAt = rng.below(200) } else { padding = 1024 * 1024 }
            return "size"
        }
    }
}

@Test func sourcePluginSeededManifestMutationsLoadOrFailWithDefinedErrors() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-manifest-fuzz-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var program = FuzzTemplates.motion(); program.pluginGUID = "Fuzz.Manifest_é"
    let programData = program.data()
    var loaded = 0, rejected = 0
    for seed: UInt64 in [0x3A41_0001, 0x3A41_0002] {
        var rng = SplitMix64(seed: seed)
        for iteration in 0..<40 {
            let directory = root.appendingPathComponent("\(seed)-\(iteration)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var manifest = FuzzManifest(guid: "Fuzz.Manifest_é", type: program.type, sha256: sha256Hex(programData))
            var bytes = programData, label = "none"
            if iteration > 0 { label = manifest.mutate(&rng, program: &bytes) }
            try bytes.write(to: directory.appendingPathComponent("program.json"))
            let url = directory.appendingPathComponent("manifest.json")
            try manifest.data().write(to: url)
            let context = "seed \(seed) iteration \(iteration) \(label)"
            func load() -> String {
                do {
                    let package = try SourcePluginPackage.load(url: url)
                    let library = outcome { _ = try SourcePluginLibrary(packages: [package]) }
                    return "loaded \(package.programs.count) \(sha256Hex(package.manifestData)) library \(library)"
                } catch { return isDefinedLoadError(error) ? "rejected \(error)" : "undefined \(error)" }
            }
            let first = load(), second = load()
            #expect(first == second, "\(context): nondeterministic load")
            #expect(!first.hasPrefix("undefined"), "\(context): \(first)")
            #expect(!first.contains("library undefined"), "\(context): \(first)")
            if iteration == 0 { #expect(first.hasPrefix("loaded 1 ") && first.hasSuffix("library ok"), "\(context): \(first)") }
            if first.hasPrefix("loaded") {
                loaded += 1
                let package = try SourcePluginPackage.load(url: url)
                #expect(package.ordinalGUID == Data(manifest.guid.utf8), "\(context)")
                #expect(package.programs.count == manifest.components.count, "\(context)")
                let typed = package.programs.allSatisfy { $0.type.utf8.elementsEqual(program.type.utf8) }
                #expect(typed, "\(context)")
            } else { rejected += 1 }
        }
    }
    #expect(loaded > 0 && rejected > 0, "loaded \(loaded) rejected \(rejected)")
}

// MARK: - Interpreter versus an independent Swift evaluation

private enum ReferenceValue {
    case float(Float), double(Double), bool(Bool)
    var f: Float { if case .float(let x) = self { return x }; return .nan }
    var d: Double { if case .double(let x) = self { return x }; return .nan }
    var b: Bool { if case .bool(let x) = self { return x }; return false }
    var stored: SourceIRStoredValue {
        switch self {
        case .float(let x): return .float(x.bitPattern)
        case .double(let x): return .double(x.bitPattern)
        case .bool(let x): return .bool(x)
        }
    }
}

/// Typed random expressions paired with their value computed by ordinary Swift
/// arithmetic. Conversions mirror the interpreter's argument path exactly
/// (`Float` operands of Unity APIs travel through `Double`), so the bits of
/// NaN/infinity results must agree as well. `-0.0` literals are left out.
private enum ReferenceExpressions {
    static let floats: [Float] = [0, 1, -1, 0.5, 0.1, 3, -2.5, 16_777_216, 1e20, .leastNonzeroMagnitude, .leastNormalMagnitude,
                                  .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
    static let doubles: [Double] = [0, 1, -1, 0.1, 2.5, 1e308, -1e308, 1e-308, 5e-324, 3.5e38, 16_777_217, 1e39]
    static let comparisons = ["<", ">", "<=", ">=", "==", "!="]
    static let arithmetic = ["+", "-", "*", "/"]
    static func clamp01(_ v: Float) -> Float {
        if v < 0 { return 0 }
        if v > 1 { return 1 }
        return v
    }
    static func through(_ v: Float) -> Float { Float(Double(v)) }
    static func apply(_ op: String, _ x: Float, _ y: Float) -> Float {
        switch op {
        case "+": return x + y
        case "-": return x - y
        case "*": return x * y
        default: return x / y
        }
    }
    static func apply(_ op: String, _ x: Double, _ y: Double) -> Double {
        switch op {
        case "+": return x + y
        case "-": return x - y
        case "*": return x * y
        default: return x / y
        }
    }
    static func compare(_ op: String, _ x: Double, _ y: Double) -> Bool {
        switch op {
        case "<": return x < y
        case ">": return x > y
        case "<=": return x <= y
        case ">=": return x >= y
        case "==": return x == y
        default: return x != y
        }
    }
    static func make(_ type: String, _ depth: Int, _ rng: inout SplitMix64, _ inputs: [String: ReferenceValue]) -> (FuzzNode, ReferenceValue) {
        let leaf = depth <= 0 || rng.chance(25)
        switch type {
        case "Float":
            if leaf {
                if rng.chance(40) {
                    let name = rng.pick(["a", "b", "c"])
                    return (IR.field(name, "Float"), inputs[name] ?? .float(.nan))
                }
                let value = rng.pick(floats); return (IR.float(value), .float(value))
            }
            switch rng.below(9) {
            case 0:
                let (node, value) = make("Float", depth - 1, &rng, inputs)
                return (IR.unary("-", "Float", node), .float(-value.f))
            case 1, 2:
                let op = rng.pick(arithmetic)
                let (left, x) = make("Float", depth - 1, &rng, inputs)
                let (right, y) = make("Float", depth - 1, &rng, inputs)
                return (IR.binary(op, "Float", left, right), .float(apply(op, x.f, y.f)))
            case 3:
                let (node, value) = make("Float", depth - 1, &rng, inputs)
                return (IR.api("math.Clamp01", "Float", [node]), .float(clamp01(through(value.f))))
            case 4:
                let (node, value) = make("Float", depth - 1, &rng, inputs)
                return (IR.api("math.Sqrt", "Float", [node]), .float(through(value.f).squareRoot()))
            case 5:
                let (from, x) = make("Float", depth - 1, &rng, inputs)
                let (to, y) = make("Float", depth - 1, &rng, inputs)
                let (t, z) = make("Float", depth - 1, &rng, inputs)
                let a = through(x.f), b = through(y.f)
                return (IR.api("math.Lerp", "Float", [from, to, t]), .float(a + (b - a) * clamp01(through(z.f))))
            case 6:
                let (condition, c) = make("Bool", depth - 1, &rng, inputs)
                let (then, x) = make("Float", depth - 1, &rng, inputs)
                let (otherwise, y) = make("Float", depth - 1, &rng, inputs)
                return (FuzzNode("conditional", "Float", nil, [condition, then, otherwise]), c.b ? x : y)
            case 7:
                let lane = rng.below(3)
                let (nx, x) = make("Float", depth - 1, &rng, inputs)
                let (ny, y) = make("Float", depth - 1, &rng, inputs)
                let (nz, z) = make("Float", depth - 1, &rng, inputs)
                let lanes = [through(x.f), through(y.f), through(z.f)]
                return (FuzzNode("member", "Float", ["x", "y", "z"][lane], [IR.api("vector.init", "Vector3", [nx, ny, nz])]), .float(lanes[lane]))
            default:
                let (node, value) = make("Double", depth - 1, &rng, inputs)
                return (FuzzNode("convert", "Float", nil, [node]), .float(Float(value.d)))
            }
        case "Double":
            if leaf {
                if rng.chance(40) {
                    let name = rng.pick(["p", "q"])
                    return (IR.field(name, "Double"), inputs[name] ?? .double(.nan))
                }
                let value = rng.pick(doubles); return (IR.double(value), .double(value))
            }
            switch rng.below(5) {
            case 0:
                let (node, value) = make("Double", depth - 1, &rng, inputs)
                return (IR.unary("-", "Double", node), .double(-value.d))
            case 1, 2:
                let op = rng.pick(arithmetic)
                let (left, x) = make("Double", depth - 1, &rng, inputs)
                let (right, y) = make("Double", depth - 1, &rng, inputs)
                return (IR.binary(op, "Double", left, right), .double(apply(op, x.d, y.d)))
            case 3:
                let (condition, c) = make("Bool", depth - 1, &rng, inputs)
                let (then, x) = make("Double", depth - 1, &rng, inputs)
                let (otherwise, y) = make("Double", depth - 1, &rng, inputs)
                return (FuzzNode("conditional", "Double", nil, [condition, then, otherwise]), c.b ? x : y)
            default:
                let (node, value) = make("Float", depth - 1, &rng, inputs)
                return (FuzzNode("convert", "Double", nil, [node]), .double(Double(value.f)))
            }
        default:
            if leaf { let value = rng.chance(50); return (IR.bool(value), .bool(value)) }
            switch rng.below(5) {
            case 0, 1:
                let op = rng.pick(comparisons)
                let (left, x) = make("Float", depth - 1, &rng, inputs)
                let (right, y) = make("Float", depth - 1, &rng, inputs)
                return (IR.binary(op, "Bool", left, right), .bool(compare(op, Double(x.f), Double(y.f))))
            case 2:
                let op = rng.pick(comparisons)
                let (left, x) = make("Double", depth - 1, &rng, inputs)
                let (right, y) = make("Double", depth - 1, &rng, inputs)
                return (IR.binary(op, "Bool", left, right), .bool(compare(op, x.d, y.d)))
            case 3:
                let (node, value) = make("Bool", depth - 1, &rng, inputs)
                return (IR.unary("!", "Bool", node), .bool(!value.b))
            default:
                let op = rng.pick(["&&", "||"])
                let (left, x) = make("Bool", depth - 1, &rng, inputs)
                let (right, y) = make("Bool", depth - 1, &rng, inputs)
                return (IR.binary(op, "Bool", left, right), .bool(op == "&&" ? (x.b && y.b) : (x.b || y.b)))
            }
        }
    }
}

@Test func sourcePluginInterpreterMatchesIndependentSwiftEvaluationBitForBit() throws {
    var rng = SplitMix64(seed: 0xD1FF_0001)
    for programIndex in 0..<8 {
        let a = rng.pick(ReferenceExpressions.floats), b = rng.pick(ReferenceExpressions.floats)
        let c = rng.pick(ReferenceExpressions.floats)
        let p = rng.pick(ReferenceExpressions.doubles), q = rng.pick(ReferenceExpressions.doubles)
        let inputs: [String: ReferenceValue] = ["a": .float(a), "b": .float(b), "c": .float(c), "p": .double(p), "q": .double(q)]
        var program = FuzzProgram(); program.type = "Fuzz.Reference"
        program.fields = [
            FuzzField(name: "a", type: "Float", initializer: IR.float(a), serialized: true),
            FuzzField(name: "b", type: "Float", initializer: IR.float(b), serialized: true),
            FuzzField(name: "c", type: "Float", initializer: IR.float(c), serialized: true),
            FuzzField(name: "p", type: "Double", initializer: IR.double(p), serialized: true),
            FuzzField(name: "q", type: "Double", initializer: IR.double(q), serialized: true)]
        var statements: [FuzzNode] = [], expected: [(String, ReferenceValue)] = []
        for index in 0..<32 {
            let type = rng.pick(["Float", "Double", "Bool"])
            let (node, value) = ReferenceExpressions.make(type, 4, &rng, inputs)
            let name = "out\(index)"
            let zero = type == "Float" ? IR.float(0) : (type == "Double" ? IR.double(0) : IR.bool(false))
            program.fields.append(FuzzField(name: name, type: type, initializer: zero, serialized: true))
            statements.append(IR.assign(IR.field(name, type), "=", node))
            expected.append((name, value))
        }
        program.methods = [.callback("Update", statements)]
        let decoded = try SourceIRProgram.decode(program.data())
        let object = StudioObject(name: "Reference", kind: .folder)
        let host = try PluginHost([object])
        try host.attach(decoded, to: object)
        try host.runtime.start()
        try host.runtime.step(deltaTime: 0.02)
        let fields = try host.runtime.savedBindings()[0].fields
        for (name, value) in expected {
            let actual = fields[name], wanted = value.stored
            #expect(actual == wanted, "program \(programIndex) \(name)")
        }
    }
}

// MARK: - Budgets

@Test func sourcePluginBudgetsFailWithBudgetErrorAndRestoreFullSnapshots() throws {
    var program = FuzzProgram(); program.type = "Fuzz.Budget"
    program.fields = FuzzTemplates.floats(["hits", "burned", "fixedTicks", "deep"])
        + [FuzzField(name: "mode", type: "Int32", initializer: IR.int32(0), serialized: true)]
    // 64 Burn calls cost about 25,000 instructions (over the 20,000 callback
    // fuel); 16 cost about 6,300. Deep has 20 nested unary nodes: accepted by
    // validation (depth 22 <= 24) but beyond the 16-level evaluation stack.
    var deep = IR.float(1)
    for _ in 0..<20 { deep = IR.unary("-", "Float", deep) }
    let burn = [IR.translate(IR.one)] + Array(repeating: IR.increment("burned"), count: 128)
    program.methods = [
        .callback("FixedUpdate", [IR.increment("fixedTicks")]),
        .callback("Update", [IR.increment("hits"), IR.translate(IR.one),
            IR.when(IR.equals("mode", 1), IR.expression(IR.call("SpendHalf"))),
            IR.when(IR.equals("mode", 2), IR.expression(IR.call("Spend"))),
            IR.when(IR.equals("mode", 3), IR.expression(IR.call("Deep"))),
            IR.when(IR.equals("mode", 4), IR.expression(IR.call("Recurse"))),
            IR.when(IR.equals("mode", 5), IR.expression(IR.call("Ping")))]),
        .helper("Burn", body: burn),
        .helper("Spend", body: Array(repeating: IR.expression(IR.call("Burn")), count: 64)),
        .helper("SpendHalf", body: Array(repeating: IR.expression(IR.call("Burn")), count: 16)),
        .helper("Deep", body: [IR.assign(IR.field("deep", "Float"), "=", deep)]),
        .helper("Recurse", body: [IR.increment("hits"), IR.translate(IR.one), IR.expression(IR.call("Recurse"))]),
        .helper("Ping", body: [IR.increment("hits"), IR.expression(IR.call("Pong"))]),
        .helper("Pong", body: [IR.translate(IR.one), IR.expression(IR.call("Ping"))])]
    let decoded = try SourceIRProgram.decode(program.data())
    let target = StudioObject(name: "Budget", kind: .folder), witness = StudioObject(name: "Witness", kind: .folder)
    let host = try PluginHost([target, witness])
    try host.attach(try SourceIRProgram.decode(FuzzTemplates.observer().data()), to: witness)
    try host.attach(decoded, to: target)
    try host.runtime.start()
    try host.runtime.step(deltaTime: 0.02)

    // Fuel is per callback: two frames of ~6,300 instructions both commit.
    try setField(host.runtime, 1, "mode", .int32(1))
    try host.runtime.step(deltaTime: 0.02)
    try host.runtime.step(deltaTime: 0.02)
    #expect(try storedFloat(host.runtime, 1, "burned") == 2 * 16 * 128)

    for mode: Int32 in [2, 3, 4, 5] {
        try setField(host.runtime, 1, "mode", .int32(mode))
        let before = try host.snapshot()
        let result = outcome { try host.runtime.step(deltaTime: 0.02) }
        #expect(result == "budget", "mode \(mode)")
        let after = try host.snapshot()
        #expect(after == before, "mode \(mode) left partial state")
    }

    // Fixed-step catch-up: 1.28 s is exactly 64 steps of 0.02 (float32) and
    // commits; 1.4 s is 70 steps and is rejected before any callback.
    try setField(host.runtime, 1, "mode", .int32(0))
    let ticks = try storedFloat(host.runtime, 1, "fixedTicks")
    try host.runtime.step(deltaTime: 1.28)
    #expect(try storedFloat(host.runtime, 1, "fixedTicks") == ticks + 64)
    let before = try host.snapshot()
    do { let result = outcome { try host.runtime.step(deltaTime: 1.4) }; #expect(result == "budget") }
    do { let result = outcome { try host.runtime.step(deltaTime: -1) }; #expect(result == "invalid") }
    do { let result = outcome { try host.runtime.step(deltaTime: .nan) }; #expect(result == "invalid") }
    let after = try host.snapshot()
    #expect(after == before)
    try host.runtime.step(deltaTime: 0.02)

    // Static limits reject before execution.
    var nested = program
    var tooDeep = IR.float(1)
    for _ in 0..<30 { tooDeep = IR.unary("-", "Float", tooDeep) }
    nested.methods.append(.helper("TooDeep", body: [IR.assign(IR.field("deep", "Float"), "=", tooDeep)]))
    do { let result = outcome { _ = try SourceIRProgram.decode(nested.data()) }; #expect(result == "invalid") }
    var wide = program
    wide.methods.append(.helper("Wide", body: Array(repeating: FuzzNode("empty"), count: 2049)))
    do { let result = outcome { _ = try SourceIRProgram.decode(wide.data()) }; #expect(result == "invalid") }
    do { let result = outcome { _ = try SourceIRProgram.decode(Data(repeating: 32, count: 4 * 1024 * 1024 + 1)) }; #expect(result == "invalid") }
    let context = try SourceAPIContext(world: host.world, fixedDeltaTime: 0.02), handle = try host.world.object(id: target.id)
    do { let result = outcome { _ = try SourceIRComponent(program: decoded, context: context, gameObject: handle, instructionLimit: 99) }; #expect(result == "invalid") }
    do { let result = outcome { _ = try SourceIRComponent(program: decoded, context: context, gameObject: handle, instructionLimit: 1_000_001) }; #expect(result == "invalid") }
    let spare = try SourceStudioPluginWorld(document: StudioDocument())
    do { let result = outcome { _ = try SourcePluginRuntime(world: spare, fixedDeltaTime: 0.02, maximumFixedSteps: 0) }; #expect(result == "invalid") }
    do { let result = outcome { _ = try SourcePluginRuntime(world: spare, fixedDeltaTime: 0.02, maximumFixedSteps: 1001) }; #expect(result == "invalid") }
}

@Test func sourceIRComponentDirectInvocationBoundsFuelAndChecksArguments() throws {
    var program = FuzzProgram(); program.type = "Fuzz.Utility"; program.mode = "methods"
    program.methods = [
        .helper("Sum", returns: "Float", parameters: [FuzzParameter(name: "a", type: "Float"), FuzzParameter(name: "b", type: "Float")],
                isStatic: true, body: [FuzzNode("return", nil, nil, [IR.binary("+", "Float", IR.ref("a", "Float"), IR.ref("b", "Float"))])]),
        .helper("Wide", isStatic: true, body: Array(repeating: IR.translate(IR.one), count: 40))]
    let decoded = try SourceIRProgram.decode(program.data())
    let object = StudioObject(name: "Utility", kind: .folder)
    let host = try PluginHost([object])
    let context = try SourceAPIContext(world: host.world, fixedDeltaTime: 0.02), handle = try host.world.object(id: object.id)
    // 40 translates cost about 200 instructions: over a 100-instruction budget.
    let limited = try SourceIRComponent(program: decoded, context: context, gameObject: handle, instructionLimit: 100)
    let sum = try limited.invoke("Sum", arguments: [.float(1.5), .float(2.25)])
    var total: Float = .nan
    if case .float(let value) = sum { total = value }
    #expect(total == 3.75)
    let before = host.world.document
    do { let result = outcome { _ = try limited.invoke("Wide") }; #expect(result == "budget") }
    #expect(host.world.document == before)
    do { let result = outcome { _ = try limited.invoke("Sum", arguments: [.double(1.5), .float(2.25)]) }; #expect(result == "runtime") }
    do { let result = outcome { _ = try limited.invoke("Sum", arguments: [.float(1.5)]) }; #expect(result == "runtime") }
    do { let result = outcome { _ = try limited.invoke("Missing") }; #expect(result == "runtime") }
    // The same body commits with the default budget, and fuel resets per call.
    let unlimited = try SourceIRComponent(program: decoded, context: context, gameObject: handle)
    _ = try unlimited.invoke("Wide")
    _ = try unlimited.invoke("Wide")
    #expect(host.world.document != before)
}

// MARK: - Activation callbacks under failure

@Test func sourcePluginActivationPingPongExhaustsEventDepthAndRollsBack() throws {
    var program = FuzzProgram(); program.type = "Fuzz.PingPong"
    program.fields = FuzzTemplates.floats(["flips"])
    program.methods = [
        .callback("OnEnable", [IR.increment("flips"), IR.translate(IR.one), IR.setActive(false)]),
        .callback("OnDisable", [IR.increment("flips"), IR.translate(IR.one), IR.setActive(true)])]
    let target = StudioObject(name: "PingPong", kind: .folder), witness = StudioObject(name: "Witness", kind: .folder)
    let host = try PluginHost([target, witness])
    try host.attach(try SourceIRProgram.decode(FuzzTemplates.observer().data()), to: witness)
    try host.attach(try SourceIRProgram.decode(program.data()), to: target)
    let before = try host.snapshot()
    do { let result = outcome { try host.runtime.start() }; #expect(result == "budget") }
    let after = try host.snapshot()
    #expect(after == before)
    let visible = host.world.document.objects.allSatisfy { $0.visible }
    let asleep = try host.runtime.savedBindings().allSatisfy { !$0.awake && !$0.started }
    #expect(visible && asleep)
}

/// Code k makes callback k fail after it changed a field and the world:
/// 1/4/7 with a runtime error, 2/5/8 with a rejected nonfinite host write,
/// 3/6 by exhausting the recursion budget.
private enum LifecycleFixture {
    static let codes: [String: Int32] = ["Awake": 1, "OnEnable": 2, "Start": 3, "FixedUpdate": 4, "Update": 5, "LateUpdate": 6, "OnDisable": 7, "OnDestroy": 8]
    static func failure(_ name: String, _ code: Int32) -> FuzzNode {
        switch code {
        case 3, 6: return IR.expression(IR.call(name))
        case 2, 5, 8: return IR.translate(IR.binary("/", "Vector3", IR.one, IR.float(0)))
        default: return IR.expression(IR.binary("+", "Int32", IR.int32(1), IR.int32(1)))
        }
    }
    static func program() -> FuzzProgram {
        var program = FuzzProgram(); program.type = "Fuzz.Lifecycle"
        program.fields = [
            FuzzField(name: "fail", type: "Int32", initializer: IR.int32(0), serialized: true),
            FuzzField(name: "clone", type: "Bool", initializer: IR.bool(false), serialized: true),
            FuzzField(name: "destroy", type: "Bool", initializer: IR.bool(false), serialized: true),
            FuzzField(name: "hits", type: "Float", initializer: IR.float(0), serialized: true),
            FuzzField(name: "transient", type: "Float", initializer: IR.float(7), serialized: false)]
        program.methods = ["Awake", "OnEnable", "Start", "FixedUpdate", "Update", "LateUpdate", "OnDisable", "OnDestroy"].map { name in
            let code = codes[name] ?? 0
            var statements = [IR.increment("hits"), IR.translate(IR.one)]
            if name == "Awake" { statements.append(IR.increment("transient")) }
            if name == "Update" {
                statements.append(IR.when(IR.field("clone", "Bool"), IR.expression(IR.instantiate())))
                statements.append(IR.when(IR.field("destroy", "Bool"), IR.destroy()))
            }
            statements.append(IR.when(IR.equals("fail", code), failure(name, code)))
            return FuzzMethod.callback(name, statements)
        }
        return program
    }
}

@Test func sourcePluginLifecycleFailuresRollBackAndRetryMatchesCleanRun() throws {
    let program = try SourceIRProgram.decode(LifecycleFixture.program().data())
    let target = StudioObject(name: "Lifecycle", kind: .folder)
    typealias Operation = (label: String, failing: [Int32], run: (SourcePluginRuntime) throws -> Void)
    let operations: [Operation] = [
        ("start", [1, 2], { try $0.start() }),
        ("frame", [3, 4, 5, 6], { try $0.step(deltaTime: 0.02) }),
        ("arm-clone", [], { try setField($0, 0, "clone", .bool(true)) }),
        ("clone-frame", [1, 2, 3, 4, 5, 6], { try $0.step(deltaTime: 0.02) }),
        ("disarm-clone", [], { try setFieldEverywhere($0, "clone", .bool(false)) }),
        ("disable-clone", [7], { try $0.setEnabled(false, at: 1) }),
        ("enable-clone", [2], { try $0.setEnabled(true, at: 1) }),
        ("arm-destroy", [], { try setField($0, 0, "destroy", .bool(true)) }),
        ("destroy-frame", [4, 5, 6, 7, 8], { try $0.step(deltaTime: 0.02) }),
        ("after-destroy", [4, 5, 6], { try $0.step(deltaTime: 0.02) })]

    let clean = try PluginHost([target])
    try clean.attach(program, to: target)
    for operation in operations { try operation.run(clean.runtime) }

    let injected = try PluginHost([target])
    try injected.attach(program, to: target)
    for operation in operations {
        for code in operation.failing {
            try setFieldEverywhere(injected.runtime, "fail", .int32(code))
            let before = try injected.snapshot()
            let result = outcome { try operation.run(injected.runtime) }
            #expect(result == (code == 3 || code == 6 ? "budget" : "runtime"), "\(operation.label) code \(code)")
            let after = try injected.snapshot()
            #expect(after == before, "\(operation.label) code \(code) left partial state")
            try setFieldEverywhere(injected.runtime, "fail", .int32(0))
        }
        try operation.run(injected.runtime)
    }
    let cleanState = try clean.snapshot(), injectedState = try injected.snapshot()
    #expect(injectedState == cleanState)
    // plugin-execution.md ordering: synchronous Awake/OnEnable, clone
    // Awake/OnEnable inside Instantiate, same-frame clone Start/LateUpdate,
    // synchronous OnDisable on Destroy and OnDestroy at the frame barrier.
    #expect(events(cleanState.trace) == [
        "Awake", "OnEnable",
        "Start", "FixedUpdate", "Update", "LateUpdate",
        "FixedUpdate", "Update", "clone.Awake", "clone.OnEnable", "LateUpdate", "clone.Start", "clone.LateUpdate",
        "clone.OnDisable", "clone.OnEnable",
        "FixedUpdate", "clone.FixedUpdate", "Update", "OnDisable", "clone.Update", "clone.LateUpdate", "OnDestroy",
        "clone.FixedUpdate", "clone.Update", "clone.LateUpdate"])
    let destroyed = cleanState.bindings.map { $0.destroyed == true }
    #expect(destroyed == [true, false])
    #expect(clean.world.document.objects.count == 1)
}

@Test func sourcePluginRejectedAttachRollsBackClonesAndOtherCallbacks() throws {
    // Regression: field initializers ran Instantiate outside a runtime
    // transaction, so the clone's activation pass woke other entries and a
    // later initializer failure left their Awake/OnEnable fields and trace.
    var program = FuzzProgram(); program.type = "Fuzz.Initializer"
    let spawned = IR.api("position", "Vector3", [IR.api("transform", "Transform", [IR.instantiate()])])
    program.fields = [FuzzField(name: "spawned", type: "Vector3", initializer: spawned, serialized: true),
                      FuzzField(name: "broken", type: "Float", initializer: IR.bool(true), serialized: true)]
    program.methods = [.callback("Update", [])]
    let target = StudioObject(name: "Target", kind: .folder), witness = StudioObject(name: "Witness", kind: .folder)
    let host = try PluginHost([target, witness])
    try host.attach(try SourceIRProgram.decode(FuzzTemplates.observer().data()), to: witness)
    let before = try host.snapshot()
    do { let result = outcome { _ = try host.attach(SourceIRProgram.decode(program.data()), to: target) }; #expect(result == "runtime") }
    let after = try host.snapshot()
    #expect(after == before)
    #expect(host.world.document.objects.count == 2 && host.runtime.callbackTrace.isEmpty)
    program.fields.removeLast()
    let index = try host.attach(try SourceIRProgram.decode(program.data()), to: target)
    #expect(index == 1)
    #expect(host.world.document.objects.count == 3)
}

// MARK: - Host failure injection

private enum AttachedFixture {
    static func program() -> FuzzProgram {
        var program = FuzzProgram(); program.type = "Fuzz.Attached"
        program.fields = FuzzTemplates.floats(["hits", "disables", "lates"])
            + [FuzzField(name: "clone", type: "Bool", initializer: IR.bool(false), serialized: true)]
        let position = IR.api("position", "Vector3", [IR.transform])
        // Seven resolver calls per Update: two per Translate (world frame and
        // parent frame) and three for the position read, its type-checking
        // read and the parent-frame write.
        program.methods = [
            .callback("Update", [IR.increment("hits"), IR.when(IR.field("clone", "Bool"), IR.expression(IR.instantiate())),
                                 IR.translate(IR.one), IR.translate(IR.one, IR.selfSpace),
                                 IR.assign(position, "=", IR.binary("+", "Vector3", position, IR.vector(0, 1, 0)))]),
            .callback("LateUpdate", [IR.increment("lates")]),
            .callback("OnDisable", [IR.increment("disables")])]
        return program
    }
    static func objects() -> [StudioObject] {
        var parent = StudioObject(name: "Character", kind: .folder); parent.transform.position = SIMD3(1, 0, 2)
        var child = StudioObject(name: "Accessory", kind: .folder); child.parent = parent.id; child.sourceAttachmentPoint = 17
        return [parent, child, StudioObject(name: "Witness", kind: .folder)]
    }
    static func resolver(_ faults: HostFaultSwitch) -> SourceStudioPluginWorld.AttachmentResolver {
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)), point = SIMD3<Float>(1, 2, 3)
        return { _, _ in
            faults.calls += 1
            if faults.failAt == faults.calls { throw HostFault.injected(faults.calls) }
            return (Transform.trs(point, rotation, SIMD3<Float>(repeating: 1)), rotation)
        }
    }
}

@Test func sourcePluginAttachmentResolverFailureAtEveryCallRollsBack() throws {
    let objects = AttachedFixture.objects(), program = try SourceIRProgram.decode(AttachedFixture.program().data())
    let observer = try SourceIRProgram.decode(FuzzTemplates.observer().data())
    func makeHost(_ faults: HostFaultSwitch) throws -> PluginHost {
        let host = try PluginHost(objects, attachment: AttachedFixture.resolver(faults))
        try host.attach(observer, to: objects[2])
        try host.attach(program, to: objects[1])
        try host.runtime.start()
        try host.runtime.step(deltaTime: 0.02)
        return host
    }
    let cleanFaults = HostFaultSwitch(), clean = try makeHost(cleanFaults)
    let faults = HostFaultSwitch(), injected = try makeHost(faults)
    for call in 1...7 {
        faults.failAt = faults.calls + call
        let before = try injected.snapshot()
        do {
            try injected.runtime.step(deltaTime: 0.02)
            Issue.record("resolver call \(call) did not reject the frame")
        } catch let fault as HostFault {
            #expect(fault == .injected(faults.failAt ?? -1), "call \(call)")
        } catch { Issue.record("call \(call): unexpected \(error)") }
        let after = try injected.snapshot()
        #expect(after == before, "resolver call \(call) left partial state")
        faults.failAt = nil
        try injected.runtime.step(deltaTime: 0.02)
        try clean.runtime.step(deltaTime: 0.02)
    }
    let injectedState = try injected.snapshot(), cleanState = try clean.snapshot()
    #expect(injectedState == cleanState)

    // A resolver failure while cloning the attached object leaves no clone.
    try setField(injected.runtime, 1, "clone", .bool(true))
    faults.failAt = faults.calls + 1
    let before = try injected.snapshot()
    #expect(throws: HostFault.self) { try injected.runtime.step(deltaTime: 0.02) }
    let after = try injected.snapshot()
    #expect(after == before)
    faults.failAt = nil
    try injected.runtime.step(deltaTime: 0.02)
    #expect(injected.world.document.objects.count == objects.count + 1 && injected.world.cloneSerial == 1)
}

@Test func sourcePluginAfterUpdateHostFailureRollsBackHostAndCallbackEffects() throws {
    let objects = AttachedFixture.objects(), faults = HostFaultSwitch()
    let host = try PluginHost(objects, attachment: AttachedFixture.resolver(faults))
    try host.attach(try SourceIRProgram.decode(FuzzTemplates.observer().data()), to: objects[2])
    try host.attach(try SourceIRProgram.decode(AttachedFixture.program().data()), to: objects[1])
    try host.runtime.start()
    try host.runtime.step(deltaTime: 0.02)
    let before = try host.snapshot()
    // The host consumer deactivates the attached object (OnDisable runs) and
    // then fails, as an Animator/dynamics afterUpdate stage may.
    let world = host.world, accessory = objects[1].id
    do {
        try host.runtime.step(deltaTime: 0.02, afterUpdate: {
            try world.object(id: accessory).setActive(false)
            throw HostFault.injected(0)
        })
        Issue.record("afterUpdate failure was ignored")
    } catch let fault as HostFault { #expect(fault == .injected(0)) }
    let after = try host.snapshot()
    #expect(after == before)
    #expect(try storedFloat(host.runtime, 1, "disables") == 0)
    try host.runtime.step(deltaTime: 0.02, afterUpdate: { try world.object(id: accessory).setActive(false) })
    #expect(try storedFloat(host.runtime, 1, "disables") == 1)
}

@Test func sourceStudioPluginSessionStepFailureKeepsSavedDocument() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-session-faults-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var program = AttachedFixture.program(); program.pluginGUID = "Fuzz.Session"
    let bytes = program.data()
    try bytes.write(to: directory.appendingPathComponent("program.json"))
    let manifest = directory.appendingPathComponent("manifest.json")
    try FuzzManifest(guid: "Fuzz.Session", type: program.type, sha256: sha256Hex(bytes)).data().write(to: manifest)
    let objects = AttachedFixture.objects()
    var document = StudioDocument(); document.objects = objects
    let profile = directory.appendingPathComponent("profile.json")
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixedDeltaTime": 0.02, "packages": [["manifest": manifest.path,
        "bindings": [["type": program.type, "objectID": objects[1].id.uuidString]]]]]).write(to: profile)
    let faults = HostFaultSwitch()
    let session = try SourceStudioPluginSession(profileURL: profile, document: document, attachment: AttachedFixture.resolver(faults))
    let saved = try session.step(document: session.savedDocument(), deltaTime: 0.02)
    let before = try session.savedDocument()
    #expect(throws: HostFault.self) { _ = try session.step(document: saved, deltaTime: 0.02, afterUpdate: { throw HostFault.injected(0) }) }
    #expect(try session.savedDocument() == before)
    faults.failAt = faults.calls + 3
    #expect(throws: HostFault.self) { _ = try session.step(document: saved, deltaTime: 0.02) }
    #expect(try session.savedDocument() == before)
    faults.failAt = nil
    let advanced = try session.step(document: saved, deltaTime: 0.02)
    #expect(advanced != before)
    #expect(advanced.sourcePluginState?.bindings.first?.fields["hits"] != before.sourcePluginState?.bindings.first?.fields["hits"])
}
