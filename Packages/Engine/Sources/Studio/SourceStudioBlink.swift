import Foundation
import Assets
import Character
import Scene

/// Studio-side blink driver for one source character. The saved
/// ChaFileStatus.eyesBlink flag becomes the recovered control's fixed flags,
/// exactly like ChaControl.ChangeEyesBlinkFlag on card load, and the monotonic
/// Studio animation clock advances it once per displayed frame like the Maker
/// idle tick. A clock rewind (setSourceAnimationTime, a plugin rebase) cannot
/// run the control backwards, so it rebuilds the control instead.
struct SourceStudioBlink {
    let eyesBlink: Bool
    private var playback = SourceBlinkPlayback()
    private var elapsed: Float?

    init(eyesBlink: Bool) {
        self.eyesBlink = eyesBlink
        reset()
    }

    /// The EyeOpen/BrowOpenSync input: the recovered openness while the card
    /// blinks, or the fixed sentinel when the saved flag is off.
    var rate: Float { playback.expressionBlinkRate }

    /// Advances the control with the Studio clock. Returns true only when the
    /// rendered blink rate changed, so callers refresh just-opened/closing eyes.
    /// The draw hooks exist for deterministic replay exactly like
    /// SourceBlinkPlayback.update; production callers use the source defaults.
    mutating func update(elapsed newElapsed: Float,
        randomInteger: (Int, Int) throws -> Int = { lower, upper in lower == upper ? lower : Int.random(in: lower..<upper) },
        randomFloat: (Float, Float) throws -> Float = { Float.random(in: $0...$1) }
    ) throws -> Bool {
        guard newElapsed.isFinite, newElapsed >= 0 else { throw RigError.invalid("Invalid Studio blink clock.") }
        if let last = elapsed, newElapsed < last { reset() }
        elapsed = newElapsed
        let previous = playback.expressionBlinkRate
        try playback.update(time: newElapsed, randomInteger: randomInteger, randomFloat: randomFloat)
        return playback.expressionBlinkRate != previous
    }

    /// ChaFileStatus.eyesBlink as the Studio card loader reads it. A missing
    /// field is the card default true; a non-bool value is reported and keeps
    /// the true default instead of guessing a blink from foreign bytes.
    static func decode(_ status: [String: SourceMessagePackValue]) -> (blink: Bool, diagnostic: String?) {
        guard let value = status["eyesBlink"] else { return (true, nil) }
        if case .bool(let blink) = value { return (blink, nil) }
        return (true, "Saved Studio Status eyesBlink is not a bool; the card default (blinking enabled) is kept.")
    }

    /// Mirrors ChaControl.ChangeEyesBlinkFlag(blink) -> BlinkCtrl.SetFixedFlags:
    /// a non-blinking card keeps the fixed sentinel instead of scheduling blinks.
    private mutating func reset() {
        var playback = SourceBlinkPlayback()
        playback.setFixedFlags(eyesBlink ? 0 : 1)
        self.playback = playback
        elapsed = nil
    }
}
