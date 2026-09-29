import Foundation
import Testing
import Assets
import Scene
import Character
@testable import Studio

/// Deterministic lower-bound draws: valid for every requested half-open integer
/// and closed float interval, so both playback instances consume identical
/// values in identical order and the sequences must match exactly.
private func lowerBoundInteger(_ lower: Int, _ upper: Int) throws -> Int { lower }
private func lowerBoundFloat(_ lower: Float, _ upper: Float) throws -> Float { lower }

@Test func studioBlinkSequenceMatchesRawPlayback() throws {
    var reference = SourceBlinkPlayback()
    var driver = SourceStudioBlink(eyesBlink: true)
    #expect(driver.rate == reference.expressionBlinkRate)
    var elapsed: Float = 0
    var previous = driver.rate
    var sawClosing = false, sawClosed = false, sawReopenAfterClose = false
    for _ in 0..<4000 {
        elapsed += 1 / 30
        _ = try reference.update(time: elapsed, randomInteger: lowerBoundInteger, randomFloat: lowerBoundFloat)
        let changed = try driver.update(elapsed: elapsed, randomInteger: lowerBoundInteger, randomFloat: lowerBoundFloat)
        #expect(driver.rate == reference.expressionBlinkRate)
        #expect(changed == (driver.rate != previous))
        previous = driver.rate
        if driver.rate < 1 { sawClosing = true }
        if driver.rate == 0 { sawClosed = true }
        if sawClosed && driver.rate == 1 { sawReopenAfterClose = true }
    }
    // The injected lower-bound draws schedule an idle deadline of zero, so the
    // control must actually cycle open/close/open rather than stay static.
    #expect(sawClosing && sawClosed && sawReopenAfterClose)
}

@Test func studioBlinkFixedFlagCardStaysSentinelAndDrawsNothing() throws {
    var driver = SourceStudioBlink(eyesBlink: false)
    // ChaControl.ChangeEyesBlinkFlag(false) fixes the control; the expression
    // input is the sentinel and no scheduling draw may run.
    #expect(driver.rate == -1)
    var elapsed: Float = 0
    for _ in 0..<600 {
        elapsed += 1 / 30
        let changed = try driver.update(elapsed: elapsed,
            randomInteger: { _, _ in Issue.record("Fixed blink control scheduled a draw"); return 0 },
            randomFloat: { _, _ in Issue.record("Fixed blink control scheduled a draw"); return 0 })
        #expect(!changed && driver.rate == -1)
    }
}

@Test func studioBlinkClockRewindResetsToSavedFlag() throws {
    var driver = SourceStudioBlink(eyesBlink: true)
    _ = try driver.update(elapsed: 1 / 30, randomInteger: lowerBoundInteger, randomFloat: lowerBoundFloat)
    _ = try driver.update(elapsed: 2 / 30, randomInteger: lowerBoundInteger, randomFloat: lowerBoundFloat)
    #expect(driver.rate < 1)
    // Equal timestamps are not a rewind: the closing sequence repeats its rate.
    let closing = try driver.update(elapsed: 0.15, randomInteger: lowerBoundInteger, randomFloat: lowerBoundFloat)
    #expect(closing && driver.rate < 1)
    #expect(try !driver.update(elapsed: 0.15, randomInteger: lowerBoundInteger, randomFloat: lowerBoundFloat))
    // A backwards seek cannot run the control in reverse, so the control is
    // rebuilt with the saved flag and openness returns to its initial value.
    #expect(try !driver.update(elapsed: 0.12, randomInteger: lowerBoundInteger, randomFloat: lowerBoundFloat))
    #expect(driver.rate == 1)
    #expect(throws: RigError.self) { try driver.update(elapsed: -0.1) }
    #expect(throws: RigError.self) { try driver.update(elapsed: .nan) }
}

@Test func studioEyesBlinkDecodingKeepsCardDefaultForForeignBytes() throws {
    typealias Value = SourceMessagePackValue
    #expect(SourceStudioBlink.decode([:]) == (blink: true, diagnostic: nil))
    #expect(SourceStudioBlink.decode(["eyesBlink": .bool(true)]) == (blink: true, diagnostic: nil))
    #expect(SourceStudioBlink.decode(["eyesBlink": .bool(false)]) == (blink: false, diagnostic: nil))
    // Non-bool values never guess a blink: the true card default is kept and the
    // foreign value is reported once.
    for foreign: Value in [.integer(0), .unsigned(1), .float(1), .string("true"), .null, .array([.bool(false)])] {
        let decoded = SourceStudioBlink.decode(["eyesBlink": foreign])
        #expect(decoded.blink == true)
        #expect(decoded.diagnostic?.contains("eyesBlink") == true)
    }
}
