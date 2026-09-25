import Foundation

/// Original ActionGame.Cycle.Type values; the numeric order is saved/script data.
public enum SourceGameplayPeriod: Int, CaseIterable, Codable, Sendable {
    case wakeUp = 0, morning, gotoSchool, hr1, lesson1, lunchTime
    case lesson2, hr2, staffTime, afterSchool, gotoMyHouse, myHouse

    public var sourceName: String {
        ["WakeUp", "Morning", "GotoSchool", "HR1", "Lesson1", "LunchTime",
         "Lesson2", "HR2", "StaffTime", "AfterSchool", "GotoMyHouse", "MyHouse"][rawValue]
    }
    public var timeZone: Int {
        switch self {
        case .wakeUp, .morning, .gotoSchool, .hr1, .lesson1: 0
        case .lunchTime, .lesson2, .hr2: 1
        case .staffTime: 2
        case .afterSchool, .gotoMyHouse: 3
        case .myHouse: 4
        }
    }
    public var isAction: Bool { self == .lunchTime || self == .staffTime || self == .afterSchool }
}

/// Holiday is the seventh source weekday, not an extra day outside the week.
public enum SourceGameplayWeek: Int, CaseIterable, Codable, Sendable {
    case monday = 0, tuesday, wednesday, thursday, friday, saturday, holiday
    public var sourceName: String {
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Holiday"][rawValue]
    }
}

public enum SourceGameplayCycleError: Error, Equatable, LocalizedError {
    case invalidWeekAdvance(Int32)
    case nonFiniteTimerInput
    case invalidFrameDelta
    case mapMoveNotActive
    case mapMoveNotAvailable
    case nightMenuNotActive

    public var errorDescription: String? {
        switch self {
        case .invalidWeekAdvance(let value): "Source weekday arithmetic produced an invalid weekday: \(value)."
        case .nonFiniteTimerInput: "Gameplay timer input must be finite."
        case .invalidFrameDelta: "Gameplay frame duration must be finite and nonnegative."
        case .mapMoveNotActive: "The source MapMove timer has not been started."
        case .mapMoveNotAvailable: "This period does not enter source MapMove on this weekday."
        case .nightMenuNotActive: "Completing the source night menu requires MyHouse."
        }
    }
}

/// Commands owed to the surrounding source systems. Returning one never means
/// that the corresponding scene, NPC, menu, or ADV behavior has been executed.
public enum SourceGameplayDeferredEffect: Equatable, Sendable {
    case persistWeek(SourceGameplayWeek)
    case updateWeekDisplay(SourceGameplayWeek)
    case advanceCharacterDays(Int)
    case updateTimeZone(Int)
    case updateMapSunlight(SourceGameplayPeriod)
    case replacePeriodAfterADVBarrier(SourceGameplayPeriod)
    case setMiniMapAndCameraActive(Bool)
    case prepareNextPeriodSceneBarrier
    case clearPlayerNextFlag
    case loadNPCs(shuffle: Bool)
    case openingTutorial
    case prepareMapMoveCharactersAndCamera
    case startTimeZoneCutIn(SourceGameplayPeriod)
    case finishMapMoveAndWaitForSceneBarrier
    case correctGameParameters
    case clearCachedCompanions
    case ensurePlayerCreatedAndInitialized
    case resetPlayerActionCount(Int)
    case clearSaturdayTeachers
}

/// Pure control-state translation of ActionGame.Cycle. It deliberately does not
/// run source coroutines: the host must satisfy their scene/ADV/fade barriers
/// before committing the matching completion operation below.
public struct SourceGameplayCycle: Sendable {
    public static let timeLimit: Float = 500
    public static let eventLimit: Float = 499
    public private(set) var period: SourceGameplayPeriod
    public private(set) var week: SourceGameplayWeek
    public private(set) var timer: Float = 0
    /// Native inactive-clock defaults. Initial Unity Canvas/TimeUI prefab values
    /// have not been imported; these become source-derived on MapMove entry.
    public private(set) var timePass: Float = 0
    public private(set) var timerVisible = false
    public private(set) var isOpening: Bool
    public private(set) var isShufflePoped = false
    public private(set) var mapMoveActive = false
    public var isAction: Bool { period.isAction }
    public var isActionEnd: Bool { timer >= Self.timeLimit }

    /// SaveData's original defaults are opening=true and week=Holiday.
    public init(isOpening: Bool = true, week: SourceGameplayWeek = .holiday) {
        self.isOpening = isOpening
        self.week = week
        self.period = isOpening ? .wakeUp : .myHouse
    }

    /// A direct backward Change(Type) advances one weekday. An equal period does
    /// not. No timer reset occurs here; the source resets it inside MapMove.
    @discardableResult public mutating func changePeriod(_ value: SourceGameplayPeriod) -> [SourceGameplayDeferredEffect] {
        var effects: [SourceGameplayDeferredEffect] = []
        if period.rawValue > value.rawValue {
            effects += changeWeek(SourceGameplayWeek(rawValue: (week.rawValue + 1) % 7)!)
        }
        effects += setPeriod(value)
        return effects
    }

    /// Source Change(Week) counts forward to the requested weekday. Requesting
    /// the current weekday advances character age by a full seven days.
    @discardableResult public mutating func changeWeek(_ value: SourceGameplayWeek) -> [SourceGameplayDeferredEffect] {
        var days = (value.rawValue - week.rawValue + 7) % 7
        if days == 0 { days = 7 }
        week = value
        return [.updateWeekDisplay(value), .persistWeek(value), .advanceCharacterDays(days)]
    }

    /// Uses source unchecked Int32 addition and C# signed remainder. A negative
    /// result would enter Change(Week)'s nonterminating search in the original;
    /// reject it without changing native state.
    @discardableResult public mutating func nextWeek(_ plus: Int32 = 1) throws -> [SourceGameplayDeferredEffect] {
        let raw = (Int32(week.rawValue) &+ plus) % 7
        guard let value = SourceGameplayWeek(rawValue: Int(raw)) else {
            throw SourceGameplayCycleError.invalidWeekAdvance(raw)
        }
        return changeWeek(value)
    }

    /// Commits _Next after its additive-scene/map/fade waits have completed.
    /// Unlike direct Change(Type), wrapping MyHouse -> WakeUp does not advance
    /// the weekday. MyHouse performs NextWeek itself before calling Next.
    @discardableResult public mutating func nextPeriod(returningToTitle: Bool = false, gameEnded: Bool = false) -> [SourceGameplayDeferredEffect] {
        guard !returningToTitle, !gameEnded else { return [] }
        let value = SourceGameplayPeriod(rawValue: (period.rawValue + 1) % 12)!
        return [.prepareNextPeriodSceneBarrier] + setPeriod(value) + [.clearPlayerNextFlag]
    }

    /// The NightMenu load callback synchronizes the saved weekday directly:
    /// unlike Change(Week), it does not age characters or persist another save.
    @discardableResult public mutating func reloadNightMenuWeek(_ value: SourceGameplayWeek) throws -> [SourceGameplayDeferredEffect] {
        guard period == .myHouse else { throw SourceGameplayCycleError.nightMenuNotActive }
        week = value
        return [.updateWeekDisplay(value)]
    }

    /// Commit the end of MyHouse after the menu and player-initialization waits.
    /// The source resets actionCount to 5 and explicitly advances the weekday.
    @discardableResult public mutating func completeNightMenu(returningToTitle: Bool = false, gameEnded: Bool = false) throws -> [SourceGameplayDeferredEffect] {
        guard period == .myHouse else { throw SourceGameplayCycleError.nightMenuNotActive }
        guard !returningToTitle, !gameEnded else { return [] }
        isShufflePoped = false
        var effects: [SourceGameplayDeferredEffect] = [
            .correctGameParameters, .clearCachedCompanions,
            .ensurePlayerCreatedAndInitialized, .resetPlayerActionCount(5)
        ]
        effects += try nextWeek()
        effects += [.clearSaturdayTeachers]
        effects += nextPeriod()
        return effects
    }

    public mutating func actionEnd() { timer = Self.timeLimit }

    public mutating func addTimer(_ fraction: Float) throws {
        guard fraction.isFinite else { throw SourceGameplayCycleError.nonFiniteTimerInput }
        // Keep the multiplication and addition separate, as in the original IL.
        let amount = Self.timeLimit * fraction
        let value = timer + amount
        timer = value < 0 ? 0 : (value > Self.timeLimit ? Self.timeLimit : value)
    }

    /// Enters the timed part of LunchTime, StaffTime, or AfterSchool. Holiday
    /// handlers skip MapMove even though the period-level isAction stays true.
    @discardableResult public mutating func beginMapMove() throws -> [SourceGameplayDeferredEffect] {
        guard isAction, week != .holiday else { throw SourceGameplayCycleError.mapMoveNotAvailable }
        var effects: [SourceGameplayDeferredEffect] = [.loadNPCs(shuffle: !isShufflePoped)]
        timer = 0
        timePass = 0
        timerVisible = true
        mapMoveActive = true
        if isOpening {
            isOpening = false
            effects.append(.openingTutorial)
        }
        isShufflePoped = true
        effects += [.prepareMapMoveCharactersAndCamera, .startTimeZoneCutIn(period)]
        return effects
    }

    /// One source MapMove do/while iteration, after tutorial and fade waits.
    /// ADV/Talk/interaction-scene flags hide the clock; Game.IsRegulate(true),
    /// supplied separately by the host, controls whether the timer advances.
    public mutating func tickMapMove(deltaTime: Float, cursorLocked: Bool, gameRegulated: Bool,
                                     advProcessing: Bool = false, talkSceneActive: Bool = false,
                                     interactionSceneActive: Bool = false) throws {
        guard mapMoveActive else { throw SourceGameplayCycleError.mapMoveNotActive }
        guard deltaTime.isFinite, deltaTime >= 0 else { throw SourceGameplayCycleError.invalidFrameDelta }
        if cursorLocked && !gameRegulated {
            let value = timer + deltaTime
            guard value.isFinite else { throw SourceGameplayCycleError.nonFiniteTimerInput }
            timer = value // The original frame increment is not clamped at 500.
        }
        timePass = timer / Self.timeLimit
        timerVisible = !advProcessing && !talkSceneActive && !interactionSceneActive
    }

    /// Commit after the MapMove do/while has observed isActionEnd. The source
    /// forces the displayed fraction to 1 while retaining the overshot timer.
    @discardableResult public mutating func finishMapMove() throws -> [SourceGameplayDeferredEffect] {
        guard mapMoveActive, isActionEnd else { throw SourceGameplayCycleError.mapMoveNotActive }
        mapMoveActive = false
        timePass = 1
        timerVisible = true
        return [.finishMapMoveAndWaitForSceneBarrier]
    }

    private mutating func setPeriod(_ value: SourceGameplayPeriod) -> [SourceGameplayDeferredEffect] {
        period = value
        mapMoveActive = false
        return [.updateTimeZone(value.timeZone), .updateMapSunlight(value),
                .replacePeriodAfterADVBarrier(value), .setMiniMapAndCameraActive(value.isAction)]
    }
}
