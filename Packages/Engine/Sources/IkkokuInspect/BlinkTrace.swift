import Foundation
import Character

private struct BlinkTraceDocument: Decodable {
    struct Scenario: Decodable { let name: String; let actions: [Action] }
    struct Action: Decodable {
        let operation: String
        let time: Float?, value: Float?
        let integers: [Int]?, floats: [Float]?
    }
    let schemaVersion: Int
    let scenarios: [Scenario]
}

/// Replays explicit source-range random draws. Expected results in an oracle input
/// are deliberately not decoded or used to compute native output.
func inspectBlinkTrace(url: URL) throws -> [String: Any] {
    func invalid(_ message: String) -> SourceExpressionPlaybackError {
        .invalid("Blink trace: \(message)")
    }
    let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0, size <= 16 * 1024 * 1024 else {
        throw invalid("input must be a regular file of 1 byte through 16 MiB.")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
    guard data.count <= 16 * 1024 * 1024 else { throw invalid("input exceeds 16 MiB.") }
    let document = try JSONDecoder().decode(BlinkTraceDocument.self, from: data)
    guard document.schemaVersion == 1, document.scenarios.count <= 1000,
          document.scenarios.reduce(0, { $0 + $1.actions.count }) <= 100_000 else {
        throw invalid("unsupported schema or scenario/action limits exceeded.")
    }
    var scenarios: [[String: Any]] = []
    for scenario in document.scenarios {
        guard !scenario.name.isEmpty, scenario.name.utf8.count <= 1024 else { throw invalid("invalid scenario name.") }
        var playback = SourceBlinkPlayback(), actions: [[String: Any]] = []
        for (index, action) in scenario.actions.enumerated() {
            var integerIndex = 0, floatIndex = 0, requests: [[String: Any]] = []
            let integers = action.integers ?? [], floats = action.floats ?? []
            guard integers.count <= 2, floats.count <= 1 else { throw invalid("too many draws at \(scenario.name)/\(index).") }
            let integer: (Int, Int) throws -> Int = { lower, upper in
                guard integerIndex < integers.count else { throw invalid("missing integer draw at \(scenario.name)/\(index).") }
                let value = integers[integerIndex]; integerIndex += 1
                requests.append(["kind": "integer", "minimum": lower, "maximum": upper, "value": value])
                return value
            }
            let floating: (Float, Float) throws -> Float = { lower, upper in
                guard floatIndex < floats.count else { throw invalid("missing float draw at \(scenario.name)/\(index).") }
                let value = floats[floatIndex]; floatIndex += 1
                requests.append(["kind": "float", "minimum": lower, "maximum": upper, "value": value])
                return value
            }
            func time() throws -> Float {
                guard let result = action.time else { throw invalid("missing time at \(scenario.name)/\(index).") }
                return result
            }
            func value() throws -> Float {
                guard let result = action.value, result.isFinite else { throw invalid("missing/invalid value at \(scenario.name)/\(index).") }
                return result
            }
            func byte() throws -> UInt8 {
                guard let result = UInt8(exactly: try value()) else { throw invalid("value must be an integer in 0...255.") }
                return result
            }
            switch action.operation {
            case "update": _ = try playback.update(time: time(), randomInteger: integer, randomFloat: floating)
            case "forceOpen": try playback.forceOpen(at: time(), randomFloat: floating)
            case "forceClose": try playback.forceClose(at: time(), randomInteger: integer, randomFloat: floating)
            case "frequency": try playback.setFrequency(byte(), at: time(), randomInteger: integer)
            case "speed": try playback.setSpeed(value())
            case "flags": playback.setFixedFlags(try byte())
            default: throw invalid("unknown operation '\(action.operation)'.")
            }
            guard integerIndex == integers.count, floatIndex == floats.count else {
                throw invalid("unused random draws at \(scenario.name)/\(index).")
            }
            let snapshot = try JSONSerialization.jsonObject(with: JSONEncoder().encode(playback.snapshot))
            var record: [String: Any] = ["operation": action.operation, "snapshot": snapshot,
                "expressionBlinkRate": playback.expressionBlinkRate, "randomRequests": requests]
            if let time = action.time { record["time"] = time }
            if let value = action.value { record["value"] = value }
            actions.append(record)
        }
        scenarios.append(["name": scenario.name, "actions": actions])
    }
    return ["schemaVersion": 1, "kind": "ikkoku-native-blink-trace", "scenarios": scenarios]
}
