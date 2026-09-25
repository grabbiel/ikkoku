import Foundation
import CryptoKit
import Character
import Scene

/// Exact original catalog selection and the native playback clock. The saved
/// source values remain unchanged unless explicit animation overrides are made.
public struct SourceStudioAnimationState: Codable, Sendable, Equatable {
    public var group: Int32, category: Int32, no: Int32
    public var speed: Float, pattern: Float, normalizedTime: Float, forceLoop: Bool
    public var optionParameters: SIMD2<Float>
    public init(record: KoikatsuCharacterRecord) {
        group = record.animation.group; category = record.animation.category; no = record.animation.no
        speed = record.animationSpeed; pattern = record.animationPattern; normalizedTime = record.animationNormalizedTime
        forceLoop = record.forceLoop; optionParameters = record.animationOptionParameters
    }
}

public struct SourceStudioAnimationCatalog: Decodable, Sendable {
    public struct Entry: Decodable, Sendable {
        public let group: Int32, category: Int32, no: Int32
        public let bundle: String, controller: String, state: String, optionItems: Bool
        public let file: String?, sha256: String?, stateID: String?, unboundPaths: [UInt32]?, diagnostic: String?
        public let lowDetailOnlyPaths: [UInt32]?
    }
    public let schemaVersion: Int, kind: String, catalogSHA256: String, entries: [Entry]
    public static func load(url: URL) throws -> Self {
        let data = try boundedData(url, maximum: 8 * 1024 * 1024)
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.kind == "ikkoku-studio-animation-catalog", value.entries.count <= 100_000,
              Set(value.entries.map { "\($0.group)/\($0.category)/\($0.no)" }).count == value.entries.count,
              value.entries.allSatisfy({ entry in
                  let low = entry.lowDetailOnlyPaths ?? []
                  return Set(low).count == low.count && Set(low).isSubset(of: Set(entry.unboundPaths ?? []))
              }) else {
            throw RigError.invalid("Invalid or ambiguous Studio animation catalog.")
        }
        return value
    }
    public func resolve(_ state: SourceStudioAnimationState, directory: URL) throws -> SourceStudioAnimation {
        guard let entry = entries.first(where: { $0.group == state.group && $0.category == state.category && $0.no == state.no }) else {
            throw RigError.invalid("Studio animation catalog identity \(state.group)/\(state.category)/\(state.no) is not converted.")
        }
        guard let file = entry.file, let hash = entry.sha256, let stateID = entry.stateID,
              !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else {
            throw RigError.invalid(entry.diagnostic ?? "Studio animation conversion is unavailable.")
        }
        let root = directory.resolvingSymlinksInPath(), url = root.appendingPathComponent(file).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { throw RigError.invalid("Studio animation escapes its catalog directory.") }
        let data = try Self.boundedData(url, maximum: 64 * 1024 * 1024)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
            throw RigError.invalid("Studio animation conversion hash differs from its catalog.")
        }
        let library = try SourceAnimationLibrary.decode(data), selected = try library.state(id: stateID)
        guard selected.name.utf8.elementsEqual(entry.state.utf8), library.source.controllerName.utf8.elementsEqual(entry.controller.utf8),
              Set(library.clips.flatMap(\.unboundPathHashes)) == Set(entry.unboundPaths ?? []) else {
            throw RigError.invalid("Studio animation state/controller or binding identities differ from the catalog.")
        }
        return SourceStudioAnimation(entry: entry, library: library, stateID: stateID)
    }
    private static func boundedData(_ url: URL, maximum: Int) throws -> Data {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true, let size = properties.fileSize, size > 0, size <= maximum else {
            throw RigError.invalid("Studio animation input must be a bounded regular file.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw RigError.invalid("Studio animation input exceeds its limit.") }
        return data
    }
}

public struct SourceStudioAnimation: Sendable {
    public let entry: SourceStudioAnimationCatalog.Entry, library: SourceAnimationLibrary, stateID: String
    /// Cache the completed fixed-step boundary, never a partial rendered tail.
    /// Incremental frames then match a fresh deterministic sample bit for bit.
    public struct Playback: Sendable {
        fileprivate var state: SourceStudioAnimationState?, height: Float = 0, elapsed: Float = 0
        fileprivate var fullSteps = 0, boundary: Clock?
        public fileprivate(set) var lastAdvanceSteps = 0
        public init() {}
        public mutating func reset() { self = Self() }
    }
    public struct Clock: Sendable, Equatable {
        public private(set) var normalizedTime: Float
        public init(normalizedTime: Float) throws {
            guard normalizedTime.isFinite, normalizedTime >= 0 else { throw RigError.invalid("Invalid saved animation time.") }
            self.normalizedTime = normalizedTime
        }
        /// CharAnimeCtrl.LateUpdate restarts a forced nonlooping state at zero;
        /// overshoot is discarded once per update, not carried into a new loop.
        public mutating func advance(deltaTime: Float, speed: Float, stateSpeed: Float, duration: Float,
                                     loops: Bool, forceLoop: Bool) throws {
            guard deltaTime.isFinite, deltaTime >= 0, speed.isFinite, speed >= 0,
                  stateSpeed.isFinite, stateSpeed >= 0, duration.isFinite, duration > 0 else {
                throw RigError.invalid("Invalid Studio animation playback clock input.")
            }
            let next = normalizedTime + deltaTime * speed * stateSpeed / duration
            guard next.isFinite else { throw RigError.invalid("Studio animation time overflowed.") }
            normalizedTime = forceLoop && !loops && next >= 1 ? 0 : next
        }
    }
    public func parameters(height: Float) throws -> [String: Float] {
        guard height.isFinite else { throw RigError.invalid("Studio animation height is not finite.") }
        // Normal AnimeLoadInfo sets height but deliberately does not set motion
        // or the H-only option parameters, even when the saved fields are nonzero.
        return library.parameters.contains(where: { $0.name == "height" && $0.type == "float" }) ? ["height": height] : [:]
    }
    public func clock(state: SourceStudioAnimationState, elapsed: Float, height: Float) throws -> Clock {
        var playback = Playback()
        return try clock(state: state, elapsed: elapsed, height: height, playback: &playback)
    }
    public func clock(state: SourceStudioAnimationState, elapsed: Float, height: Float, playback: inout Playback) throws -> Clock {
        guard elapsed.isFinite, (0...86_400).contains(elapsed) else { throw RigError.invalid("Studio animation time must be between zero and one day.") }
        let params = try parameters(height: height), selected = try library.state(id: stateID)
        let speed = try library.stateSpeed(stateID: stateID, floatParameters: params)
        let duration = try library.stateDuration(stateID: stateID, floatParameters: params)
        // A fixed simulation step makes capture time, attachments and guides
        // identical regardless of viewport refresh count or rendering speed.
        let steps = Int(floor(elapsed * 60)), step: Float = 1 / 60
        let reuse = playback.state == state && playback.height == height && elapsed >= playback.elapsed && steps >= playback.fullSteps
        var clock = try reuse ? playback.boundary ?? Clock(normalizedTime: state.normalizedTime) : Clock(normalizedTime: state.normalizedTime)
        let start = reuse ? playback.fullSteps : 0
        for _ in start..<steps { try clock.advance(deltaTime: step, speed: state.speed, stateSpeed: speed, duration: duration, loops: selected.loop, forceLoop: state.forceLoop) }
        playback.state = state; playback.height = height; playback.elapsed = elapsed
        playback.fullSteps = steps; playback.boundary = clock; playback.lastAdvanceSteps = steps - start
        let remainder = max(0, elapsed - Float(steps) / 60)
        if remainder > 0 { try clock.advance(deltaTime: remainder, speed: state.speed, stateSpeed: speed, duration: duration, loops: selected.loop, forceLoop: state.forceLoop) }
        return clock
    }
    public func pose(state: SourceStudioAnimationState, elapsed: Float, height: Float, rig: RigDefinition, baseline: RigPose) throws -> RigPose {
        let clock = try clock(state: state, elapsed: elapsed, height: height)
        return try library.applying(stateID: stateID, normalizedTime: clock.normalizedTime,
            floatParameters: parameters(height: height), to: rig, baseline: baseline, allowingUnbound: true)
    }
    public func pose(state: SourceStudioAnimationState, elapsed: Float, height: Float, rig: RigDefinition, baseline: RigPose, playback: inout Playback) throws -> RigPose {
        let clock = try clock(state: state, elapsed: elapsed, height: height, playback: &playback)
        return try library.applying(stateID: stateID, normalizedTime: clock.normalizedTime,
            floatParameters: parameters(height: height), to: rig, baseline: baseline, allowingUnbound: true)
    }
}
