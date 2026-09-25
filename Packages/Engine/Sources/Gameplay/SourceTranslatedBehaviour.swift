import Foundation

/// Explicit host seam for translated Unity calls. Handles retain their host identity;
/// the bridge never rewrites card IDs, asset IDs or plug-in GUIDs.
public protocol SourceAPIObject: AnyObject {
    var sourceIdentity: String { get }
    var transform: any SourceAPITransform { get }
    func setActive(_ active: Bool)
}

public enum SourceAPISpace: Sendable { case world, local }

/// The native scene adapter must implement Unity position/parent and self-space
/// semantics. Values at this seam remain in Unity's source coordinate basis;
/// the scene adapter performs the native basis conversion at its boundary.
/// Translate in local space rotates the delta but does not scale it.
public protocol SourceAPITransform: AnyObject {
    var position: SIMD3<Float> { get set }
    var localPosition: SIMD3<Float> { get set }
    var localScale: SIMD3<Float> { get set }
    func translate(_ delta: SIMD3<Float>, relativeTo: SourceAPISpace)
}

public protocol SourceAPIWorld: AnyObject {
    /// Clone through the asset/entity host. Object and asset identity are distinct.
    func instantiate(_ original: any SourceAPIObject) -> any SourceAPIObject
    /// The host implements Unity's end-of-frame destruction barrier.
    func destroy(_ object: any SourceAPIObject)
}

/// Values are supplied by the engine loop; the translation does not read wall time.
public final class SourceAPIContext {
    public let world: any SourceAPIWorld
    public fileprivate(set) var deltaTime: Float = 0
    public fileprivate(set) var fixedDeltaTime: Float = 0
    /// Supply the project's configured timestep before component field initializers
    /// or Awake can read Time.fixedDeltaTime. No project timestep is guessed.
    public init(world: any SourceAPIWorld, deltaTime: Float = 0, fixedDeltaTime: Float) throws {
        self.world = world
        try configureClocks(deltaTime: deltaTime, fixedDeltaTime: fixedDeltaTime)
    }
    /// Changes both clocks atomically. A paused rendered frame may have zero delta;
    /// the configured physics interval must remain strictly positive.
    public func configureClocks(deltaTime: Float, fixedDeltaTime: Float) throws {
        guard deltaTime.isFinite, deltaTime >= 0, fixedDeltaTime.isFinite, fixedDeltaTime > 0 else {
            throw SourceTranslationClockError.invalidDelta
        }
        self.deltaTime = deltaTime
        self.fixedDeltaTime = fixedDeltaTime
    }
}

open class SourceTranslatedBehaviour {
    public let context: SourceAPIContext
    public let gameObject: any SourceAPIObject
    public var transform: any SourceAPITransform { gameObject.transform }
    public init(context: SourceAPIContext, gameObject: any SourceAPIObject) {
        self.context = context
        self.gameObject = gameObject
    }
    open func sourceAwake() {}
    open func sourceOnEnable() {}
    open func sourceStart() {}
    open func sourceUpdate() {}
    open func sourceFixedUpdate() {}
    open func sourceLateUpdate() {}
    open func sourceOnDisable() {}
    open func sourceOnDestroy() {}
}

public enum SourceTranslationClockError: Error { case invalidDelta }

/// One enabled component's bounded lifecycle. The host owns enable/disable order,
/// scene barriers and destruction. This does not simulate the whole Unity player.
public final class SourceBehaviourDriver {
    public let component: SourceTranslatedBehaviour
    private var didAwake = false
    private var didStart = false
    public init(_ component: SourceTranslatedBehaviour) { self.component = component }
    public func awake() {
        guard !didAwake else { return }
        didAwake = true
        component.sourceAwake()
    }
    private func startIfNeeded() {
        awake()
        guard !didStart else { return }
        didStart = true
        component.sourceStart()
    }
    public func update(deltaTime: Float) throws {
        guard deltaTime.isFinite, deltaTime >= 0 else { throw SourceTranslationClockError.invalidDelta }
        component.context.deltaTime = deltaTime
        startIfNeeded()
        component.sourceUpdate()
    }
    public func fixedUpdate(fixedDeltaTime: Float) throws {
        guard fixedDeltaTime.isFinite, fixedDeltaTime > 0 else { throw SourceTranslationClockError.invalidDelta }
        component.context.fixedDeltaTime = fixedDeltaTime
        // Unity Time.deltaTime inside FixedUpdate is the fixed duration.
        component.context.deltaTime = fixedDeltaTime
        startIfNeeded()
        component.sourceFixedUpdate()
    }
}

public enum SourceAPIMath {
    // Deliberately branch rather than min/max: source Clamp01 preserves NaN.
    public static func clamp01(_ value: Float) -> Float {
        if value < 0 { return 0 }
        if value > 1 { return 1 }
        return value
    }
    public static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * clamp01(t)
    }
    public static func sqrt(_ value: Float) -> Float { value.squareRoot() }
}
