import Foundation
import Testing
@testable import Character

private func playbackNear(_ actual: Float, _ expected: Float) {
    #expect(abs(actual - expected) <= max(0.0000001, abs(expected) * 0.0000001))
}

@Test func sourceBlinkDefaultsAndStrictDeadline() throws {
    var blink = SourceBlinkPlayback()
    #expect(blink.snapshot.frequency == 30)
    #expect(blink.snapshot.baseSpeed == 0.15)
    #expect(blink.snapshot.mode == 0 && blink.snapshot.deadline == 0)
    let noInt: (Int, Int) throws -> Int = { _, _ in Issue.record("Unexpected random integer"); return 0 }
    let noFloat: (Float, Float) throws -> Float = { _, _ in Issue.record("Unexpected random float"); return 0 }
    #expect(try blink.update(time: 0, randomInteger: noInt, randomFloat: noFloat) == 1)
    var requests: [String] = []
    let first = try blink.update(time: 0.1, randomInteger: { lo, hi in
        #expect(lo == 0 && hi == 3); requests.append("int"); return 0
    }, randomFloat: { lo, hi in
        #expect(lo == 0 && hi == 0.05); requests.append("float"); return 0
    })
    #expect(first == 1)
    #expect(requests == ["float", "int"])
    #expect(blink.snapshot.mode == 1 && blink.snapshot.count == 1)
    let deadline = blink.snapshot.deadline
    #expect(try blink.update(time: deadline, randomInteger: noInt, randomFloat: noFloat) == 0)
    #expect(blink.snapshot.mode == 1 && blink.snapshot.count == 1)
    #expect(try blink.update(time: deadline.nextUp, randomInteger: noInt, randomFloat: { _, _ in 0 }) == 0)
    #expect(blink.snapshot.mode == -1 && blink.snapshot.count == 0)
}

@Test func sourceBlinkClosedHoldCountsCallsNotElapsedSeconds() throws {
    var blink = SourceBlinkPlayback()
    try blink.forceClose(at: 0, randomInteger: { _, _ in 2 }, randomFloat: { _, _ in 0 })
    for expected in [2, 1] {
        #expect(try blink.update(time: 100, randomInteger: { _, _ in -1 }, randomFloat: { _, _ in .nan }) == 0)
        #expect(blink.snapshot.mode == 1 && blink.snapshot.count == expected)
    }
    #expect(try blink.update(time: 100, randomFloat: { _, _ in 0 }) == 0)
    #expect(blink.snapshot.mode == -1 && blink.snapshot.count == 0)
    // No catch-up loop: opening starts now even after a 100-second frame.
    playbackNear(blink.snapshot.deadline, 100.15)
    #expect(try blink.update(time: 100) == 0)
}

@Test func sourceBlinkForcedMotionDefersOutputAndRebasesProgress() throws {
    var blink = SourceBlinkPlayback()
    try blink.forceClose(at: 0, randomInteger: { _, _ in 0 }, randomFloat: { _, _ in 0 })
    #expect(blink.snapshot.openness == 1)
    playbackNear(try blink.update(time: 0.075), 0.5)
    try blink.forceOpen(at: 0.075, randomFloat: { _, _ in 0.05 })
    playbackNear(blink.snapshot.openness, 0.5)
    playbackNear(try blink.update(time: 0.075), 0)
    playbackNear(try blink.update(time: 0.175), 0.5)
}

@Test func sourceBlinkFixedFlagsFreezeButSettersStillOperate() throws {
    var blink = SourceBlinkPlayback()
    try blink.forceClose(at: 0, randomInteger: { _, _ in 1 }, randomFloat: { _, _ in 0 })
    _ = try blink.update(time: 0.075)
    blink.setFixedFlags(128)
    let frozen = blink.snapshot
    _ = try blink.update(time: 100, randomInteger: { _, _ in -1 }, randomFloat: { _, _ in .nan })
    #expect(blink.snapshot == frozen)
    #expect(blink.expressionBlinkRate == -1)
    try blink.forceOpen(at: 100, randomFloat: { _, _ in 0 })
    #expect(blink.snapshot.mode == -1 && blink.snapshot.fixedFlags == 128)
    blink.setFixedFlags(0)
    _ = try blink.update(time: 100)
    #expect(blink.expressionBlinkRate == 0)
}

@Test func sourceBlinkFrequencyOnlyReschedulesIdleAndSupportsZero() throws {
    var blink = SourceBlinkPlayback()
    try blink.setFrequency(0, at: 10, randomInteger: { lo, hi in
        #expect(lo == 0 && hi == 0); return 0
    })
    #expect(blink.snapshot.deadline == 10)
    #expect(try blink.update(time: 10) == 1)
    try blink.forceClose(at: 10, randomInteger: { _, _ in 0 }, randomFloat: { _, _ in 0 })
    let deadline = blink.snapshot.deadline
    try blink.setFrequency(255, at: 11, randomInteger: { _, _ in Issue.record("Active phase drew frequency"); return 0 })
    #expect(blink.snapshot.frequency == 255 && blink.snapshot.deadline == deadline)
    _ = try blink.update(time: 11, randomFloat: { _, _ in 0 })
    _ = try blink.update(time: 12, randomInteger: { lo, hi in #expect(lo == 0 && hi == 255); return 254 })
    #expect(blink.snapshot.mode == 0)
    playbackNear(blink.snapshot.deadline, 62.8)
}

@Test func sourceBlinkSetSpeedPreservesSourceClamp() throws {
    var blink = SourceBlinkPlayback()
    try blink.setSpeed(0.2)
    #expect(blink.snapshot.baseSpeed == 1)
    try blink.setSpeed(-1)
    #expect(blink.snapshot.baseSpeed == 1)
    try blink.setSpeed(2)
    try blink.forceClose(at: 1, randomInteger: { _, _ in 0 }, randomFloat: { _, hi in hi })
    playbackNear(blink.snapshot.calculatedSpeed, 2.05)
    playbackNear(try blink.update(time: 2.025), 0.5)
}

@Test func sourceBlinkInvalidNativeInputsAreAtomic() throws {
    var blink = SourceBlinkPlayback()
    let initial = blink.snapshot
    #expect(throws: SourceExpressionPlaybackError.self) { try blink.update(time: .nan) }
    #expect(throws: SourceExpressionPlaybackError.self) { try blink.update(time: -1) }
    #expect(throws: SourceExpressionPlaybackError.self) { try blink.setSpeed(.infinity) }
    #expect(throws: SourceExpressionPlaybackError.self) { try blink.setFrequency(0, at: 0, randomInteger: { _, _ in 1 }) }
    #expect(throws: SourceExpressionPlaybackError.self) {
        try blink.update(time: 1, randomInteger: { _, _ in 3 }, randomFloat: { _, _ in 0 })
    }
    #expect(throws: SourceExpressionPlaybackError.self) { try blink.forceOpen(at: 1, randomFloat: { _, _ in .nan }) }
    #expect(blink.snapshot == initial)
    try blink.setSpeed(.greatestFiniteMagnitude)
    let beforeOverflow = blink.snapshot
    #expect(throws: SourceExpressionPlaybackError.self) {
        try blink.forceOpen(at: .greatestFiniteMagnitude, randomFloat: { _, _ in 0 })
    }
    #expect(blink.snapshot == beforeOverflow)
}

@Test func sourceExpressionProgressStartsAndEndsInSourceOrder() throws {
    var progress = try SourceExpressionProgress()
    #expect(progress.rate == 1 && progress.count == 0 && progress.progressTime == 0.15)
    // Constructor's rate does not imply End() has run.
    playbackNear(try progress.calculate(deltaTime: 0.075), 0.5)
    progress.end()
    #expect(progress.count == 0.15 && progress.rate == 1)
    progress.start()
    #expect(progress.count == 0 && progress.rate == 0)
    playbackNear(try progress.calculate(deltaTime: 0.05), 1 / 3)
    #expect(try progress.calculate(deltaTime: 100) == 1)
    #expect(progress.count == 0.15)
    try progress.setProgressTime(0.3)
    #expect(progress.count == 0.15 && progress.rate == 1)
    playbackNear(try progress.calculate(deltaTime: 0), 0.5)
    try progress.setProgressTime(0)
    #expect(try progress.calculate(deltaTime: 0) == 1 && progress.count == 0)
}

@Test func sourceExpressionRandomProgressReturnsCompletionBeforeRestart() throws {
    var progress = SourceExpressionRandomProgress()
    try progress.initialize(minimum: 0.1, maximum: 0.2, randomFloat: { lo, _ in lo })
    playbackNear(try progress.calculate(deltaTime: 0.05), 0.5)
    let completed = try progress.calculate(deltaTime: 0.05, randomFloat: { lo, hi in
        #expect(lo == 0.1 && hi == 0.2); return hi
    })
    #expect(completed == 1 && progress.progress.rate == 0 && progress.progress.count == 0)
    #expect(progress.progress.progressTime == 0.2)
    // New interval affects the next draw, not the current period.
    playbackNear(try progress.calculate(deltaTime: 0.1, minimum: 0.4, maximum: 0.5), 0.5)
    #expect(progress.progress.progressTime == 0.2)
    let nextCompleted = try progress.calculate(deltaTime: 0.1, randomFloat: { lo, hi in
        #expect(lo == 0.4 && hi == 0.5); return lo
    })
    #expect(nextCompleted == 1)
    #expect(progress.progress.progressTime == 0.4)
}

@Test func sourceExpressionProgressRejectsInvalidIntervalsWithoutMutation() throws {
    #expect(throws: SourceExpressionPlaybackError.self) { try SourceExpressionProgress(progressTime: -1) }
    var progress = try SourceExpressionProgress()
    #expect(throws: SourceExpressionPlaybackError.self) { try progress.calculate(deltaTime: .infinity) }
    #expect(throws: SourceExpressionPlaybackError.self) { try progress.setProgressTime(-1) }
    #expect(progress.count == 0 && progress.progressTime == 0.15)
    var random = SourceExpressionRandomProgress()
    #expect(throws: SourceExpressionPlaybackError.self) { try random.initialize(minimum: 1, maximum: 0) }
    #expect(throws: SourceExpressionPlaybackError.self) { try random.calculate(deltaTime: 1, minimum: 0) }
    #expect(throws: SourceExpressionPlaybackError.self) { try random.calculate(deltaTime: 1, randomFloat: { _, _ in 99 }) }
    #expect(random.progress.count == 0 && random.progress.rate == 1)
}

private struct PlaybackReference: Decodable {
    struct Scenario: Decodable { let name: String; let actions: [Action] }
    struct Action: Decodable {
        let operation: String, time: Float?, value: Float?, integers: [Int]?, floats: [Float]?
        let expected: SourceBlinkPlayback.Snapshot
        let expressionBlinkRate: Float, randomRequests: [Request]
    }
    struct Request: Decodable, Equatable {
        let kind: String, minimum: Float, maximum: Float, value: Float
    }
    struct ProgressAction: Decodable {
        struct Expected: Decodable { let count: Float, rate: Float, progressTime: Float }
        let operation: String, delta: Float?, value: Float?, minimum: Float?, maximum: Float?
        let floats: [Float]?, result: Float?, expected: Expected, minimumTime: Float?, maximumTime: Float?
    }
    let schemaVersion: Int, scenarios: [Scenario]
    let progressActions: [ProgressAction], randomProgressActions: [ProgressAction]
}

@Test func sourceExpressionProgressMatchesIndependentFloat32TemporalOracle() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_ANIMATION_PLAYBACK_REFERENCE"] else { return }
    let reference = try JSONDecoder().decode(PlaybackReference.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var progress = try SourceExpressionProgress()
    for action in reference.progressActions {
        switch action.operation {
        case "start": progress.start()
        case "end": progress.end()
        case "duration": try progress.setProgressTime(#require(action.value))
        case "calculate":
            let result = try progress.calculate(deltaTime: #require(action.delta))
            #expect(result == action.result)
        default: Issue.record("Unknown progress action")
        }
        #expect(progress.count == action.expected.count && progress.rate == action.expected.rate)
        #expect(progress.progressTime == action.expected.progressTime)
    }
    var random = SourceExpressionRandomProgress()
    for action in reference.randomProgressActions {
        var draws = action.floats ?? []
        let floating: (Float, Float) throws -> Float = { _, _ in
            let value = try #require(draws.first); draws.removeFirst(); return value
        }
        if action.operation == "initialize" {
            try random.initialize(minimum: #require(action.minimum), maximum: #require(action.maximum), randomFloat: floating)
        } else {
            let result = try random.calculate(deltaTime: #require(action.delta), minimum: action.minimum, maximum: action.maximum, randomFloat: floating)
            #expect(result == action.result)
        }
        #expect(draws.isEmpty)
        #expect(random.progress.count == action.expected.count && random.progress.rate == action.expected.rate)
        #expect(random.progress.progressTime == action.expected.progressTime)
        #expect(random.minimumTime == action.minimumTime && random.maximumTime == action.maximumTime)
    }
}

@Test func sourceBlinkMatchesIndependentFloat32TemporalOracle() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_ANIMATION_PLAYBACK_REFERENCE"] else { return }
    let reference = try JSONDecoder().decode(PlaybackReference.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(reference.schemaVersion == 1 && reference.scenarios.count == 8)
    for scenario in reference.scenarios {
        var blink = SourceBlinkPlayback()
        for action in scenario.actions {
            var integers = action.integers ?? [], floats = action.floats ?? [], requests: [PlaybackReference.Request] = []
            let integer: (Int, Int) throws -> Int = { lo, hi in
                let value = try #require(integers.first); integers.removeFirst()
                requests.append(.init(kind: "integer", minimum: Float(lo), maximum: Float(hi), value: Float(value)))
                return value
            }
            let floating: (Float, Float) throws -> Float = { lo, hi in
                let value = try #require(floats.first); floats.removeFirst()
                requests.append(.init(kind: "float", minimum: lo, maximum: hi, value: value))
                return value
            }
            switch action.operation {
            case "update": _ = try blink.update(time: #require(action.time), randomInteger: integer, randomFloat: floating)
            case "forceOpen": try blink.forceOpen(at: #require(action.time), randomFloat: floating)
            case "forceClose": try blink.forceClose(at: #require(action.time), randomInteger: integer, randomFloat: floating)
            case "frequency": try blink.setFrequency(UInt8(#require(action.value)), at: #require(action.time), randomInteger: integer)
            case "speed": try blink.setSpeed(#require(action.value))
            case "flags": blink.setFixedFlags(UInt8(try #require(action.value)))
            default: Issue.record("Unknown playback operation in \(scenario.name)")
            }
            #expect(integers.isEmpty && floats.isEmpty)
            #expect(requests == action.randomRequests)
            // All source operations round through binary32; compare every state field exactly.
            #expect(blink.snapshot == action.expected)
            #expect(blink.expressionBlinkRate == action.expressionBlinkRate)
        }
    }
}
