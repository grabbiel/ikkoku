import Foundation

public struct SourceFixedEventTable: Codable, Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var asset: String
        public var bundle: String
        public var isVisible: Bool
        public var cycles: [String]
        public var map: String
        public var weeks: [String]
        public var layerName: String
        public var coordinate: String
        public var afterDay: Int
        public init(asset: String, bundle: String = "", isVisible: Bool = false, cycles: [String], map: String,
                    weeks: [String] = [], layerName: String = "", coordinate: String = "", afterDay: Int = 0) {
            self.asset = asset; self.bundle = bundle; self.isVisible = isVisible; self.cycles = cycles
            self.map = map; self.weeks = weeks; self.layerName = layerName; self.coordinate = coordinate; self.afterDay = afterDay
        }
    }
    public struct Schedule: Codable, Sendable {
        public var heroineID: Int
        public var entries: [Entry]
    }
    public struct ClassSchedule: Codable, Sendable {
        public struct Day: Codable, Sendable { public var week: SourceGameplayWeek; public var lessons: [String] }
        public var classIndex: Int
        public var days: [Day]
    }
    public var schemaVersion: Int
    public var schedules: [Schedule]
    public var classSchedules: [ClassSchedule]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw SourceGameplayExecutionError.invalidData("Fixed-event table exceeds 16 MiB") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.schedules.count <= 10_000,
              value.schedules.reduce(0, { $0 + $1.entries.count }) <= 100_000,
              value.classSchedules.count <= 1000,
              value.classSchedules.allSatisfy({ $0.days.count <= 7 && $0.days.allSatisfy { $0.lessons.count == 2 } }) else {
            throw SourceGameplayExecutionError.invalidData("Invalid fixed-event table schema or limits")
        }
        return value
    }
    public func entries(for heroineID: Int) -> [Entry] { schedules.filter { $0.heroineID == heroineID }.flatMap(\.entries) }
    public func lessons(classIndex: Int, week: SourceGameplayWeek) -> [String]? {
        classSchedules.last { $0.classIndex == classIndex }?.days.last { $0.week == week }?.lessons
    }
}

public enum SourceGameplayExecutionError: Error, Equatable, LocalizedError {
    case invalidData(String)
    case unsupported(String)
    case missingVariable(String)
    case invalidCast(String)
    case budgetExceeded
    public var errorDescription: String? {
        switch self {
        case .invalidData(let detail): "Invalid source gameplay data: \(detail)"
        case .unsupported(let detail): "Unsupported source gameplay operation: \(detail)"
        case .missingVariable(let name): "Missing source ADV variable: \(name)"
        case .invalidCast(let detail): "Invalid source ADV conversion: \(detail)"
        case .budgetExceeded: "Source ADV instruction or recursion budget exceeded"
        }
    }
}

public enum SourceFixedEventScheduler {
    public struct WaitPoint: Codable, Sendable {
        public var id: String
        public var mapNo: Int
        public var layers: [String]
        public init(id: String, mapNo: Int, layers: [String]) { self.id = id; self.mapNo = mapNo; self.layers = layers }
    }
    public struct Context: Codable, Sendable {
        public var isTaked: Bool
        public var eventAfterDay: Int
        public var completedEvents: [Int]
        public var week: SourceGameplayWeek
        public var period: SourceGameplayPeriod
        public var mapNumbers: [String: Int]
        public var waitPoints: [WaitPoint]
        public var lessons: [String]?
        public init(isTaked: Bool = false, eventAfterDay: Int = 0, completedEvents: [Int] = [],
                    week: SourceGameplayWeek, period: SourceGameplayPeriod, mapNumbers: [String: Int] = [:],
                    waitPoints: [WaitPoint] = [], lessons: [String]? = nil) {
            self.isTaked = isTaked; self.eventAfterDay = eventAfterDay; self.completedEvents = completedEvents
            self.week = week; self.period = period; self.mapNumbers = mapNumbers; self.waitPoints = waitPoints; self.lessons = lessons
        }
    }
    public struct Selection: Codable, Sendable, Equatable {
        public var entryIndex: Int
        public var assetID: Int
        public var mapNo: Int
        public var waitPointID: String?
        public var layerIndex: Int
        public var entry: SourceFixedEventTable.Entry
    }
    public static let periodLabels = ["起床", "朝", "登校", "朝ホームルーム", "授業1", "昼休み", "授業2", "帰りホームルーム", "部活時間", "放課後", "帰宅", "自宅"]
    public static let weekLabels = ["月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日", "休日"]

    /// Only the first unfinished event is eligible for consideration. Failure
    /// does not search later events, even if one of them could otherwise match.
    public static func select(entries: [SourceFixedEventTable.Entry], context: Context) throws -> Selection? {
        guard entries.count <= 100_000, context.waitPoints.count <= 100_000, context.completedEvents.count <= 100_000 else {
            throw SourceGameplayExecutionError.invalidData("Fixed-event input count limit")
        }
        guard !context.isTaked else { return nil }
        let completed = Set(context.completedEvents)
        for (index, entry) in entries.enumerated() {
            guard let id = Int32(entry.asset.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SourceGameplayExecutionError.invalidData("Event asset must parse as Int32")
            }
            if completed.contains(Int(id)) { continue }
            guard context.eventAfterDay >= entry.afterDay else { return nil }
            if !entry.weeks.isEmpty {
                if entry.weeks.contains("平日") {
                    guard context.week.rawValue <= SourceGameplayWeek.friday.rawValue else { return nil }
                } else if !entry.weeks.contains(weekLabels[context.week.rawValue]) { return nil }
            }
            guard entry.cycles.contains(periodLabels[context.period.rawValue]) else { return nil }
            let mapNo = context.mapNumbers[entry.map] ?? -1
            if !entry.layerName.isEmpty && context.period.isAction {
                for point in context.waitPoints where point.mapNo == mapNo {
                    if let layer = point.layers.firstIndex(of: entry.layerName) {
                        return .init(entryIndex: index, assetID: Int(id), mapNo: point.mapNo, waitPointID: point.id, layerIndex: layer, entry: entry)
                    }
                }
                return nil
            }
            if context.period == .lesson1 || context.period == .lesson2 {
                guard let lessons = context.lessons, lessons.count == 2 else {
                    throw SourceGameplayExecutionError.invalidData("Lesson event requires the class's two source lessons")
                }
                let lesson = lessons[context.period == .lesson1 ? 0 : 1]
                guard lesson.isEmpty || entry.map.range(of: lesson, options: .literal) != nil else { return nil }
            }
            return .init(entryIndex: index, assetID: Int(id), mapNo: mapNo, waitPointID: nil, layerIndex: -1, entry: entry)
        }
        return nil
    }
}
