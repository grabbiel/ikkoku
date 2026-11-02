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

extension SourceStudioAnimationCatalog {
    /// `state`'s clip, decoded once per catalog identity into `cache`. Without
    /// a catalog, or when the clip does not resolve, nil; with `required` (an
    /// edited state) the error is thrown instead.
    public static func resolve(_ state: SourceStudioAnimationState, catalog: Self?, directory: URL?, required: Bool,
                               cache: inout [String: SourceStudioAnimation]) throws -> SourceStudioAnimation? {
        let key = "\(state.group)/\(state.category)/\(state.no)"
        if let cached = cache[key] { return cached }
        guard let catalog, let directory else {
            if required { throw RigError.invalid("Studio animation catalog is not configured.") }
            return nil
        }
        do {
            let value = try catalog.resolve(state, directory: directory)
            cache[key] = value
            return value
        } catch {
            if required { throw error }
            return nil
        }
    }
}

extension SourceStudioAnimation {
    /// The clip's height parameter from the card: its saved body height slot,
    /// or 0.5 when the card saves none.
    public static func cardHeight(_ bodyValues: [Float]) -> Float { bodyValues.first ?? 0.5 }

    /// The clip's height parameter: the edited body height slot, else the
    /// card's (`cardHeight`). Rebuilding an original character after a shape
    /// edit recomputes the load-time height the same way.
    public static func height(editedBody: [Float]?, cardHeight: Float) -> Float { editedBody?.first ?? cardHeight }

    /// The one time advance a save, an export or a clock rebase writes: for
    /// a built character (`SourceStudioCharacterPreview.savedAnimationState`)
    /// and for one with no preview (`SourceStudioAnimationClock`). The state
    /// is `edited` (the document's animation edit), else `saved` (the scene
    /// record's); the clip's speed, length and loop, with the state's speed,
    /// forceLoop and normalizedTime (the clock's start), drive `clock` for
    /// `elapsed` seconds of the Studio clock. Nil when nothing is edited and
    /// the saved clip does not resolve: the saved state is kept as it is.
    public static func savedState(saved: SourceStudioAnimationState, edited: SourceStudioAnimationState?, elapsed: Float, height: Float,
                                  playback: inout Playback,
                                  resolve: (SourceStudioAnimationState, _ required: Bool) throws -> SourceStudioAnimation?) throws -> SourceStudioAnimationState? {
        var state = edited ?? saved
        guard let animation = try resolve(state, edited != nil) else { return nil }
        let clock = try animation.clock(state: state, elapsed: elapsed, height: height, playback: &playback)
        state.normalizedTime = clock.normalizedTime
        return state
    }
}

/// The saved animation clock of a source character with no preview: a hidden
/// character the import left unbuilt, or one a native load has not built.
/// CharaStudio keeps such a character animating: its body Animator
/// (`p_cf_body_bone` in `chara/oo_base.unity3d`) culls with AlwaysAnimate,
/// and hiding a character switches off only its render objects, never the
/// Animator's GameObject, so a save reads the advanced normalizedTime. This
/// reads only the card's body height and the catalog clip (no rig, no GPU)
/// and runs `SourceStudioAnimation.savedState`, the time advance a built
/// character's `savedAnimationState` runs, so both write the same state.
///
/// Thread-safe: an export computes its states on a worker thread, a save or
/// a clock rebase on the main thread. Scene seeds (saved state and card
/// height) and decoded clips are cached until `clear()`.
public final class SourceStudioAnimationClock: @unchecked Sendable {
    public struct Request: Sendable {
        public let reference: SourceStudioCharacterReference
        /// The document's animation edit, if any.
        public let edited: SourceStudioAnimationState?
        /// The document's edited body shape rates, if any.
        public let bodyValues: [Float]?
        public init(reference: SourceStudioCharacterReference, edited: SourceStudioAnimationState?, bodyValues: [Float]?) {
            self.reference = reference; self.edited = edited; self.bodyValues = bodyValues
        }
    }
    private struct Seed { let saved: SourceStudioAnimationState, cardHeight: Result<Float, Error> }
    private let lock = NSLock()
    private var seeds: [String: Result<Seed, Error>] = [:]
    private var catalogs: [String: Result<SourceStudioAnimationCatalog, Error>] = [:]
    private var clips: [String: [String: SourceStudioAnimation]] = [:]

    public init() {}

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        seeds.removeAll(); catalogs.removeAll(); clips.removeAll()
    }

    /// Each request's state after `elapsed` seconds of the Studio clock,
    /// in order. `.success(nil)` keeps the saved state: nothing is edited
    /// and the clip, the card or the record cannot be read, which is what a
    /// character whose build failed keeps. An edited state that cannot be
    /// advanced is a failure, as it is for a built character. Each distinct
    /// scene file is read once, its SHA-256 checked; `scene` is used instead
    /// for references to its hash.
    public func savedStates(_ requests: [Request], elapsed: Float,
                            scene: (document: KoikatsuSceneDocument, sha256: String)? = nil) -> [Result<SourceStudioAnimationState?, Error>] {
        lock.lock(); defer { lock.unlock() }
        loadSeeds(requests.map(\.reference), scene: scene)
        return requests.map { (request: Request) -> Result<SourceStudioAnimationState?, Error> in
            // Explicit types: Swift 6.3.3 (CI) does not infer this
            // multi-statement closure's Result type from the return.
            Result<SourceStudioAnimationState?, Error> {
                let reference = request.reference
                let required = request.edited != nil
                let seed: Seed
                do { seed = try seeds[Self.seedKey(reference)]!.get() } catch { if required { throw error }; return nil }
                let cardHeight: Float
                do { cardHeight = try seed.cardHeight.get() } catch { if required { throw error }; return nil }
                let catalog: SourceStudioAnimationCatalog?
                do { catalog = try reference.animationCatalogFile.map { try self.catalog($0) } } catch { if required { throw error }; return nil }
                let file = reference.animationCatalogFile ?? ""
                let directory = reference.animationCatalogFile.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
                var playback = SourceStudioAnimation.Playback()
                let height = SourceStudioAnimation.height(editedBody: request.bodyValues, cardHeight: cardHeight)
                return try SourceStudioAnimation.savedState(saved: seed.saved, edited: request.edited, elapsed: elapsed, height: height,
                                                            playback: &playback) { state, required in
                    try SourceStudioAnimationCatalog.resolve(state, catalog: catalog, directory: directory, required: required,
                                                             cache: &clips[file, default: [:]])
                }
            }
        }
    }

    private static func seedKey(_ reference: SourceStudioCharacterReference) -> String { "\(reference.sceneSHA256)/\(reference.objectKey)" }

    private func catalog(_ file: String) throws -> SourceStudioAnimationCatalog {
        if let cached = catalogs[file] { return try cached.get() }
        let loaded = Result { try SourceStudioAnimationCatalog.load(url: URL(fileURLWithPath: file)) }
        catalogs[file] = loaded
        return try loaded.get()
    }

    /// Fills `seeds` for every reference without one, reading each scene
    /// file once.
    private func loadSeeds(_ references: [SourceStudioCharacterReference], scene: (document: KoikatsuSceneDocument, sha256: String)?) {
        var missing: [String: (sha256: String, keys: Set<Int32>)] = [:]
        for reference in references where seeds[Self.seedKey(reference)] == nil {
            missing[reference.sceneFile, default: (reference.sceneSHA256, [])].keys.insert(reference.objectKey)
            if missing[reference.sceneFile]!.sha256 != reference.sceneSHA256 {
                seeds[Self.seedKey(reference)] = .failure(RigError.invalid("Two references name one scene file with different hashes."))
            }
        }
        for (file, wanted) in missing {
            let document: Result<KoikatsuSceneDocument, Error>
            if let scene, scene.sha256 == wanted.sha256 { document = .success(scene.document) } else {
                document = Result { try Self.readScene(file, sha256: wanted.sha256) }
            }
            let records = document.map { Self.characterRecords($0, keys: wanted.keys) }
            for key in wanted.keys where seeds["\(wanted.sha256)/\(key)"] == nil {
                seeds["\(wanted.sha256)/\(key)"] = records.flatMap { records in
                    guard let record = records[key] else { return .failure(RigError.invalid("Source character record is missing.")) }
                    let height = Result { SourceStudioAnimation.cardHeight(try record.card().customization().bodyValues) }
                    return .success(Seed(saved: SourceStudioAnimationState(record: record), cardHeight: height))
                }
            }
        }
    }

    private static func readScene(_ file: String, sha256: String) throws -> KoikatsuSceneDocument {
        let maximum = 256 * 1024 * 1024
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file)); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw RigError.invalid("The referenced source scene changed; import it again to update this character.")
        }
        return try KoikatsuSceneReader.decodeDocument(data)
    }

    /// The character records with `keys`, found as a preview's assembly
    /// finds its own: roots, children and accessory children.
    private static func characterRecords(_ scene: KoikatsuSceneDocument, keys: Set<Int32>) -> [Int32: KoikatsuCharacterRecord] {
        var stack = scene.snapshot.roots, found: [Int32: KoikatsuCharacterRecord] = [:]
        while let object = stack.popLast(), found.count < keys.count {
            if keys.contains(object.sourceKey), let character = object.character, found[object.sourceKey] == nil { found[object.sourceKey] = character }
            stack += object.children
            if let character = object.character { stack += character.accessoryChildren.values.flatMap { $0 } }
        }
        return found
    }
}
