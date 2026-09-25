import Foundation

public protocol SourceAPIEventWorld: SourceAPITransactionWorld {
    var sourceActivationChanged: (() -> Void)? { get set }
    var sourceObjectsCloned: (([(any SourceAPIObject, any SourceAPIObject)]) throws -> Void)? { get set }
    func isSourceActive(_ object: any SourceAPIObject) -> Bool
    func isSourceAlive(_ object: any SourceAPIObject) -> Bool
    func pendingSourceDestruction() -> [any SourceAPIObject]
    func completeSourceDestruction()
    func recordSourceFault(_ error: any Error)
}

public struct SourcePluginBindingState: Codable, Sendable, Equatable {
    public let pluginGUID: String, type: String, sourceSHA256: String, objectIdentity: String
    public let fields: [String: SourceIRStoredValue]
    public let awake: Bool, started: Bool, enabled: Bool
    public let destroyed: Bool?
}

public struct SourcePluginClockState: Codable, Sendable, Equatable {
    public let elapsedTime: Double, accumulator: Double, deltaTime: Float, fixedDeltaTime: Float
}

/// Executes interpreted components on one host thread. The host controls elapsed
/// time, paused/scrubbed state and the frame barrier; scripts cannot read wall time.
public final class SourcePluginRuntime {
    private final class Entry {
        let component: SourceIRComponent
        var awake = false, started = false, active = false, enabled = true, destroying = false
        init(_ component: SourceIRComponent) { self.component = component }
    }
    public let world: any SourceAPIEventWorld, context: SourceAPIContext
    public private(set) var callbackTrace: [String] = []
    public private(set) var elapsedTime: Double = 0
    private var entries: [Entry] = [], accumulator: Double = 0, eventDepth = 0
    private let maximumFixedSteps: Int
    public init(world: any SourceAPIEventWorld, fixedDeltaTime: Float, maximumFixedSteps: Int = 64) throws {
        guard (1...1000).contains(maximumFixedSteps) else { throw SourcePluginError.invalid("Invalid fixed-step bound.") }
        self.world = world; self.maximumFixedSteps = maximumFixedSteps
        context = try SourceAPIContext(world: world, fixedDeltaTime: fixedDeltaTime)
        world.sourceActivationChanged = { [weak self] in
            guard let self else { return }
            do { try self.synchronizeActivation() } catch { self.world.recordSourceFault(error) }
        }
        world.sourceObjectsCloned = { [weak self] pairs in
            guard let self else { return }
            try self.transaction {
                let originals = self.entries
                for (source, clone) in pairs {
                    for original in originals where !original.destroying && original.component.gameObject === source {
                        let index = try self.attach(program: original.component.program, object: clone)
                        let copied = self.entries[index]
                        try copied.component.copySerializedFields(from: original.component)
                        copied.enabled = original.enabled
                    }
                }
                try self.synchronizeActivation()
            }
        }
    }
    @discardableResult public func attach(program: SourceIRProgram, object: any SourceAPIObject, saved: SourcePluginBindingState? = nil) throws -> Int {
        guard program.mode == "component", (world.isSourceAlive(object) || saved?.destroyed == true), entries.count < 1024 else { throw SourcePluginError.invalid("Invalid or excessive component attachment.") }
        let component = try SourceIRComponent(program: program, context: context, gameObject: object), entry = Entry(component)
        if let saved {
            guard saved.type.utf8.elementsEqual(program.type.utf8), saved.sourceSHA256 == program.source.sha256,
                  saved.pluginGUID.utf8.elementsEqual((program.identity.pluginGUID ?? "").utf8),
                  saved.objectIdentity.utf8.elementsEqual(object.sourceIdentity.utf8) else {
                throw SourcePluginError.invalid("Saved plugin state does not match its program and object identities.")
            }
            try component.restoreFields(saved.fields)
            entry.awake = saved.awake; entry.started = saved.started; entry.enabled = saved.enabled
            entry.destroying = saved.destroyed == true
            entry.active = saved.awake && saved.enabled && world.isSourceActive(object)
        }
        entries.append(entry); return entries.count - 1
    }
    public func component(at index: Int) throws -> SourceIRComponent {
        guard entries.indices.contains(index) else { throw SourcePluginError.invalid("Unknown plugin component.") }; return entries[index].component
    }
    public func setEnabled(_ enabled: Bool, at index: Int) throws {
        guard entries.indices.contains(index) else { throw SourcePluginError.invalid("Unknown plugin component.") }
        try transaction { entries[index].enabled = enabled; try synchronizeActivation() }
    }
    public func start() throws { try transaction { try synchronizeActivation() } }
    private func callback(_ event: String, _ entry: Entry) throws {
        guard entry.component.program.methods.contains(where: { $0.lifecycle == event }) else { return }
        // The trace is bounded independently of program state and contains no
        // card payloads; exact source GUID/type/object identities remain readable.
        if callbackTrace.count == 4096 { callbackTrace.removeFirst(1024) }
        callbackTrace.append("\(entry.component.program.identity.pluginGUID ?? "")/\(entry.component.program.type)/\(entry.component.gameObject.sourceIdentity):\(event)")
        try entry.component.callback(event)
    }
    private func synchronizeActivation() throws {
        eventDepth += 1; defer { eventDepth -= 1 }
        guard eventDepth <= 8 else { throw SourcePluginError.budget }
        for entry in entries where !entry.destroying {
            let live = world.isSourceAlive(entry.component.gameObject)
            let activeObject = live && world.isSourceActive(entry.component.gameObject)
            if activeObject && !entry.awake {
                entry.awake = true
                try callback("Awake", entry)
            }
            let afterAwake = world.isSourceAlive(entry.component.gameObject) && entry.enabled && world.isSourceActive(entry.component.gameObject)
            if afterAwake != entry.active {
                entry.active = afterAwake
                try callback(afterAwake ? "OnEnable" : "OnDisable", entry)
            }
        }
    }
    private func startIfNeeded(_ entry: Entry) throws {
        if !entry.started { entry.started = true; try callback("Start", entry) }
    }
    /// A failed tick rolls back scene mutations, fields, lifecycle flags, clocks,
    /// pending destruction and accumulated time as one unit.
    public func step(deltaTime: Float, afterUpdate: (() throws -> Void)? = nil) throws {
        guard deltaTime.isFinite, deltaTime >= 0 else { throw SourcePluginError.invalid("Invalid plugin frame delta.") }
        try transaction {
            accumulator += Double(deltaTime)
            let interval = Double(context.fixedDeltaTime)
            let rawSteps = floor((accumulator + interval * 1e-7) / interval)
            guard rawSteps <= Double(maximumFixedSteps) else { throw SourcePluginError.budget }
            let steps = Int(rawSteps)
            try synchronizeActivation()
            for _ in 0..<steps {
                try context.configureClocks(deltaTime: context.fixedDeltaTime, fixedDeltaTime: context.fixedDeltaTime)
                for entry in entries where entry.active && !entry.destroying {
                    try startIfNeeded(entry)
                    if entry.active { try callback("FixedUpdate", entry) }
                }
                accumulator = max(0, accumulator - interval)
            }
            try context.configureClocks(deltaTime: deltaTime, fixedDeltaTime: context.fixedDeltaTime)
            for entry in entries where entry.active && !entry.destroying {
                try startIfNeeded(entry)
                if entry.active { try callback("Update", entry) }
            }
            try afterUpdate?()
            // Unity 5.6 runs Start and LateUpdate for a component cloned during
            // Update, but its first Update is deferred until the next frame.
            for entry in entries where entry.active && !entry.destroying {
                try startIfNeeded(entry)
                if entry.active { try callback("LateUpdate", entry) }
            }
            while true {
                let pending = Set(world.pendingSourceDestruction().map { ObjectIdentifier($0) })
                let batch = entries.filter { pending.contains(ObjectIdentifier($0.component.gameObject)) && !$0.destroying }
                if batch.isEmpty { break }
                for entry in batch {
                    entry.destroying = true
                    if entry.active { entry.active = false; try callback("OnDisable", entry) }
                    if entry.awake { try callback("OnDestroy", entry) }
                }
            }
            world.completeSourceDestruction()
            elapsedTime += Double(deltaTime)
        }
    }
    public func savedBindings() throws -> [SourcePluginBindingState] {
        try entries.map { entry in
            .init(pluginGUID: entry.component.program.identity.pluginGUID ?? "", type: entry.component.program.type,
                sourceSHA256: entry.component.program.source.sha256, objectIdentity: entry.component.gameObject.sourceIdentity,
                fields: try entry.component.savedFields(), awake: entry.awake, started: entry.started, enabled: entry.enabled, destroyed: entry.destroying)
        }
    }
    public func savedClock() -> SourcePluginClockState {
        .init(elapsedTime: elapsedTime, accumulator: accumulator, deltaTime: context.deltaTime, fixedDeltaTime: context.fixedDeltaTime)
    }
    public func restoreClock(_ state: SourcePluginClockState) throws {
        guard state.elapsedTime.isFinite, state.elapsedTime >= 0, state.accumulator.isFinite,
              state.accumulator >= 0, state.accumulator < Double(context.fixedDeltaTime),
              state.fixedDeltaTime == context.fixedDeltaTime else { throw SourcePluginError.invalid("Saved plugin clock differs from its configured timebase.") }
        try context.configureClocks(deltaTime: state.deltaTime, fixedDeltaTime: state.fixedDeltaTime)
        elapsedTime = state.elapsedTime; accumulator = state.accumulator
    }
    private func transaction(_ body: () throws -> Void) throws {
        let states = try entries.map { (try $0.component.savedFields(), $0.awake, $0.started, $0.active, $0.enabled, $0.destroying) }
        let count = entries.count
        let time = elapsedTime, accumulated = accumulator, delta = context.deltaTime, fixed = context.fixedDeltaTime, trace = callbackTrace
        try world.beginSourceTransaction()
        do { try body(); try world.checkSourceFault(); try world.commitSourceTransaction() }
        catch {
            if entries.count > count { entries.removeLast(entries.count - count) }
            for (entry, state) in zip(entries, states) {
                try? entry.component.restoreFields(state.0)
                entry.awake = state.1; entry.started = state.2; entry.active = state.3; entry.enabled = state.4; entry.destroying = state.5
            }
            elapsedTime = time; accumulator = accumulated; callbackTrace = trace
            try? context.configureClocks(deltaTime: delta, fixedDeltaTime: fixed)
            world.rollbackSourceTransaction(); throw error
        }
    }
}
