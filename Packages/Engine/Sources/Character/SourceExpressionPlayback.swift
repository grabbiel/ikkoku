import Foundation

public enum SourceExpressionPlaybackError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// The recovered FBSBlinkControl clock. Time is Unity's scaled, absolute Time.time;
/// calling once per displayed frame matters because the closed hold is frame-counted.
public struct SourceBlinkPlayback: Sendable {
    public struct Snapshot: Codable, Sendable, Equatable {
        public var fixedFlags: UInt8 = 0
        public var frequency: UInt8 = 30
        public var mode: Int = 0
        public var baseSpeed: Float = 0.15
        public var calculatedSpeed: Float = 0
        public var deadline: Float = 0
        public var count: Int = 0
        public var openness: Float = 1
    }

    public private(set) var snapshot = Snapshot()
    public init() {}

    /// FaceBlendShape passes this sentinel when any fixed flag is set. The eye
    /// controller then retains its own previous openness instead of overwriting it.
    public var expressionBlinkRate: Float { snapshot.fixedFlags == 0 ? snapshot.openness : -1 }

    public mutating func setFixedFlags(_ flags: UInt8) { snapshot.fixedFlags = flags }

    /// Preserves the source setter's surprising Max(1, value), not its inspector range.
    public mutating func setSpeed(_ value: Float) throws {
        try finite(value, "Blink speed")
        snapshot.baseSpeed = max(1, value)
    }

    public mutating func setFrequency(_ value: UInt8, at time: Float,
        randomInteger: (Int, Int) throws -> Int = { lower, upper in lower == upper ? lower : Int.random(in: lower..<upper) }
    ) throws {
        try clock(time)
        var next = self
        next.snapshot.frequency = value
        if next.snapshot.mode == 0 { try next.scheduleIdle(at: time, randomInteger: randomInteger) }
        self = next
    }

    public mutating func forceOpen(at time: Float,
        randomFloat: (Float, Float) throws -> Float = { Float.random(in: $0...$1) }
    ) throws {
        try clock(time)
        var next = self
        try next.scheduleMotion(at: time, randomFloat: randomFloat)
        next.snapshot.mode = -1
        self = next
    }

    public mutating func forceClose(at time: Float,
        randomInteger: (Int, Int) throws -> Int = { lower, upper in lower == upper ? lower : Int.random(in: lower..<upper) },
        randomFloat: (Float, Float) throws -> Float = { Float.random(in: $0...$1) }
    ) throws {
        try clock(time)
        var next = self
        try next.scheduleMotion(at: time, randomFloat: randomFloat)
        next.snapshot.count = try integerDraw(0, 3, randomInteger) + 1
        next.snapshot.mode = 1
        self = next
    }

    /// Calculates this frame before advancing the state, exactly like CalcBlink.
    /// A long frame advances at most one state; it never catches up skipped blinks.
    /// Invalid inputs/draws leave playback state unchanged (external RNG state is owned by the caller).
    @discardableResult public mutating func update(time: Float,
        randomInteger: (Int, Int) throws -> Int = { lower, upper in lower == upper ? lower : Int.random(in: lower..<upper) },
        randomFloat: (Float, Float) throws -> Float = { Float.random(in: $0...$1) }
    ) throws -> Float {
        try clock(time)
        var next = self
        let remaining = max(0, snapshot.deadline - time)
        let rate: Float
        switch snapshot.mode {
        case 0: rate = 1
        case 1: rate = min(max(remaining / snapshot.calculatedSpeed, 0), 1)
        default: rate = min(max(1 - remaining / snapshot.calculatedSpeed, 0), 1)
        }
        if snapshot.fixedFlags == 0 { next.snapshot.openness = rate }
        if snapshot.fixedFlags == 0 && time > snapshot.deadline {
            switch snapshot.mode {
            case 0:
                try next.forceClose(at: time, randomInteger: randomInteger, randomFloat: randomFloat)
            case 1:
                next.snapshot.count -= 1
                if next.snapshot.count <= 0 { try next.forceOpen(at: time, randomFloat: randomFloat) }
            case -1:
                try next.scheduleIdle(at: time, randomInteger: randomInteger)
                next.snapshot.mode = 0
            default: break
            }
        }
        self = next
        return snapshot.openness
    }

    private mutating func scheduleMotion(at time: Float, randomFloat: (Float, Float) throws -> Float) throws {
        snapshot.calculatedSpeed = snapshot.baseSpeed + (try floatDraw(0, 0.05, randomFloat))
        snapshot.deadline = time + snapshot.calculatedSpeed
        try finite(snapshot.calculatedSpeed, "Blink duration")
        try finite(snapshot.deadline, "Blink deadline")
    }

    private mutating func scheduleIdle(at time: Float, randomInteger: (Int, Int) throws -> Int) throws {
        let draw = try integerDraw(0, Int(snapshot.frequency), randomInteger)
        let frequency = Float(snapshot.frequency)
        // Keep both source InverseLerp and Lerp operations, including float32 rounding.
        let fraction = frequency == 0 ? 0 : min(max(Float(draw) / frequency, 0), 1)
        let amount = frequency * fraction
        snapshot.deadline = time + 0.2 * amount
        try finite(snapshot.deadline, "Blink deadline")
    }
}

/// Recovered TimeProgressCtrl. Construction starts at rate 1 with count 0;
/// callers such as FBSBase.Init explicitly call end() to initialize a completed blend.
public struct SourceExpressionProgress: Sendable {
    public private(set) var count: Float = 0
    public private(set) var rate: Float = 1
    public private(set) var progressTime: Float

    public init(progressTime: Float = 0.15) throws {
        try duration(progressTime)
        self.progressTime = progressTime
    }
    public mutating func start() { count = 0; rate = 0 }
    public mutating func end() { count = progressTime; rate = 1 }
    public mutating func setProgressTime(_ value: Float) throws {
        try duration(value)
        progressTime = value
    }
    @discardableResult public mutating func calculate(deltaTime: Float) throws -> Float {
        try duration(deltaTime)
        let next = count + deltaTime
        try finite(next, "Expression elapsed time")
        if next < progressTime {
            count = next
            rate = min(max(count / progressTime, 0), 1)
        } else { end() }
        return rate
    }
}

/// Recovered TimeProgressCtrlRandom. A completed calculate returns 1 even though
/// it has already restarted internally at rate 0; its caller relies on that event.
public struct SourceExpressionRandomProgress: Sendable {
    public private(set) var progress: SourceExpressionProgress
    public private(set) var minimumTime: Float = 0.1
    public private(set) var maximumTime: Float = 0.2

    public init() { progress = try! SourceExpressionProgress() }

    public mutating func initialize(minimum: Float, maximum: Float,
        randomFloat: (Float, Float) throws -> Float = { Float.random(in: $0...$1) }
    ) throws {
        try interval(minimum, maximum)
        let draw = try floatDraw(minimum, maximum, randomFloat)
        var next = self
        next.minimumTime = minimum; next.maximumTime = maximum
        try next.progress.setProgressTime(draw)
        next.progress.start()
        self = next
    }

    @discardableResult public mutating func calculate(deltaTime: Float,
        minimum: Float? = nil, maximum: Float? = nil,
        randomFloat: (Float, Float) throws -> Float = { Float.random(in: $0...$1) }
    ) throws -> Float {
        guard (minimum == nil) == (maximum == nil) else {
            throw SourceExpressionPlaybackError.invalid("Random progress needs both interval endpoints.")
        }
        var next = self
        if let minimum, let maximum {
            try interval(minimum, maximum)
            next.minimumTime = minimum; next.maximumTime = maximum
        }
        let result = try next.progress.calculate(deltaTime: deltaTime)
        if result == 1 {
            let draw = try floatDraw(next.minimumTime, next.maximumTime, randomFloat)
            try next.progress.setProgressTime(draw)
            next.progress.start()
        }
        self = next
        return result
    }
}

private func finite(_ value: Float, _ label: String) throws {
    guard value.isFinite else { throw SourceExpressionPlaybackError.invalid("\(label) must be finite.") }
}
private func clock(_ value: Float) throws {
    try finite(value, "Playback time")
    guard value >= 0 else { throw SourceExpressionPlaybackError.invalid("Playback time must be nonnegative.") }
}
private func duration(_ value: Float) throws {
    try finite(value, "Expression duration")
    guard value >= 0 else { throw SourceExpressionPlaybackError.invalid("Expression duration must be nonnegative.") }
}
private func interval(_ lower: Float, _ upper: Float) throws {
    try duration(lower); try duration(upper)
    guard lower <= upper else { throw SourceExpressionPlaybackError.invalid("Random duration interval must be ordered.") }
}
private func integerDraw(_ lower: Int, _ upper: Int, _ random: (Int, Int) throws -> Int) throws -> Int {
    let result = try random(lower, upper)
    guard lower == upper ? result == lower : result >= lower && result < upper else {
        throw SourceExpressionPlaybackError.invalid("Random integer must be in the requested half-open source interval.")
    }
    return result
}
private func floatDraw(_ lower: Float, _ upper: Float, _ random: (Float, Float) throws -> Float) throws -> Float {
    let result = try random(lower, upper)
    guard result.isFinite, result >= lower, result <= upper else {
        throw SourceExpressionPlaybackError.invalid("Random float must be in the requested closed source interval.")
    }
    return result
}
