import Foundation
import simd
import CoreMath
import Scene
import Gameplay

/// The scene-facing Unity subset. All exposed coordinates remain in Unity's
/// basis; conversion happens exactly once at the native document boundary.
public final class SourceStudioPluginWorld: SourceAPIEventWorld {
    public typealias AttachmentFrame = (matrix: float4x4, rotation: simd_quatf)
    public typealias AttachmentResolver = (StudioObject, StudioObject) throws -> AttachmentFrame
    public private(set) var document: StudioDocument
    public private(set) var identities: [UUID: String]
    public private(set) var cloneSerial: UInt64
    public var sourceActivationChanged: (() -> Void)?
    public var sourceObjectsCloned: (([(any SourceAPIObject, any SourceAPIObject)]) throws -> Void)?
    private let attachment: AttachmentResolver?
    private var handles: [UUID: Object] = [:], pending = Set<UUID>()
    private var fault: (any Error)?
    private struct Snapshot {
        let document: StudioDocument, identities: [UUID: String], cloneSerial: UInt64, pending: Set<UUID>, fault: (any Error)?
    }
    private var transactions: [Snapshot] = []

    public init(document: StudioDocument, identities: [UUID: String] = [:], cloneSerial: UInt64 = 0,
                attachment: AttachmentResolver? = nil) throws {
        try document.validateHierarchy()
        self.document = document; self.identities = identities; self.cloneSerial = cloneSerial; self.attachment = attachment
        guard document.objects.count <= 10000, identities.count <= 10000,
              Set(identities.values.map { Data($0.utf8) }).count == identities.count,
              identities.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else { throw SourcePluginError.invalid("Invalid plugin world identity map.") }
        for object in document.objects where self.identities[object.id] == nil {
            if let key = object.sourceObjectKey, let hash = document.sourceSceneSHA256 { self.identities[object.id] = "source:\(hash)/object/\(key)" }
            else { self.identities[object.id] = "native:\(object.id.uuidString)" }
        }
        guard Set(self.identities.values.map { Data($0.utf8) }).count == self.identities.count else { throw SourcePluginError.invalid("Plugin object identities collide.") }
    }
    public func replaceDocument(_ value: StudioDocument) throws {
        guard transactions.isEmpty else { throw SourcePluginError.runtime("Cannot replace a document inside a plugin callback.") }
        try value.validateHierarchy()
        guard Set(value.objects.map(\.id)) == Set(document.objects.map(\.id)) else { throw SourcePluginError.runtime("Scene object topology changed; reload translated plugins to bind the new scene.") }
        document = value
    }
    public func object(id: UUID) throws -> any SourceAPIObject {
        guard document.object(id) != nil else { throw SourcePluginError.invalid("Plugin target object is absent.") }
        if let handle = handles[id] { return handle }
        guard let identity = identities[id] else { throw SourcePluginError.invalid("Plugin target identity is absent.") }
        let handle = Object(world: self, id: id, identity: identity); handles[id] = handle; return handle
    }
    public func object(sourceKey: Int32) throws -> any SourceAPIObject {
        let matches = document.objects.filter { $0.sourceObjectKey == sourceKey }
        guard matches.count == 1 else { throw SourcePluginError.invalid("Original plugin target does not bind uniquely.") }
        return try object(id: matches[0].id)
    }
    public func restoredObject(identity: String, destroyed: Bool) throws -> any SourceAPIObject {
        let matches = identities.filter { $0.value.utf8.elementsEqual(identity.utf8) }
        guard matches.count == 1, let id = matches.first?.key,
              destroyed == (document.object(id) == nil) else { throw SourcePluginError.invalid("Saved plugin object identity or destruction state differs.") }
        if !destroyed { return try object(id: id) }
        if let handle = handles[id] { return handle }
        let handle = Object(world: self, id: id, identity: identity); handles[id] = handle; return handle
    }
    private func owned(_ object: any SourceAPIObject) -> Object? {
        guard let object = object as? Object, object.world === self else { recordSourceFault(SourcePluginError.runtime("A plugin passed a foreign object handle.")); return nil }; return object
    }
    public func isSourceAlive(_ object: any SourceAPIObject) -> Bool {
        guard let handle = object as? Object, handle.world === self else { return false }; return document.object(handle.id) != nil
    }
    public func isSourceActive(_ object: any SourceAPIObject) -> Bool {
        guard let handle = object as? Object, handle.world === self else { return false }
        return document.isVisible(handle.id) && !pending.contains(handle.id) && !pending.contains(where: { document.isDescendant(handle.id, of: $0) })
    }
    public func instantiate(_ original: any SourceAPIObject) -> any SourceAPIObject {
        guard let handle = owned(original) else { return original }
        do {
            guard let root = document.object(handle.id), document.objects.count < 10000, cloneSerial < UInt64.max else { throw SourcePluginError.runtime("Clone target missing or object limit reached.") }
            let originals = document.objects.filter { $0.id == root.id || document.isDescendant($0.id, of: root.id) }
            guard originals.count + document.objects.count <= 10000 else { throw SourcePluginError.budget }
            let rootFrame = try worldFrame(root), remap = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, UUID()) })
            // A sheared world matrix cannot be represented by an unparented TRS.
            // Reject the entire callback instead of silently changing the clone.
            let scale = rootFrame.matrix.scaleFactors
            let reconstructed = Transform.trs(rootFrame.matrix.translation, rootFrame.rotation, scale)
            guard matrixError(reconstructed, rootFrame.matrix) < 0.0001 else { throw SourcePluginError.runtime("Cannot clone an unparented sheared/reflected world transform.") }
            cloneSerial += 1
            for (index, original) in originals.enumerated() {
                var clone = original
                clone.id = remap[original.id]!
                if original.id == root.id {
                    clone.parent = nil; clone.sourceAttachmentPoint = nil
                    clone.transform.position = rootFrame.matrix.translation
                    clone.transform.rotation = rootFrame.rotation.eulerXYZ.radiansToDegrees
                    clone.transform.rotationOverride = rootFrame.rotation.vector; clone.transform.scale = scale
                    clone.name += " (Clone)"
                } else { clone.parent = original.parent.flatMap { remap[$0] } }
                // Retain sourceCharacter/card/asset references; a runtime instance
                // must not pretend to be another saved original object dictionary key.
                clone.sourceObjectKey = nil
                document.objects.append(clone)
                identities[clone.id] = "\(handle.sourceIdentity)/clone/\(cloneSerial)/\(index)"
            }
            let pairs = try originals.map { (try object(id: $0.id), try object(id: remap[$0.id]!)) }
            try sourceObjectsCloned?(pairs)
            return try object(id: remap[root.id]!)
        } catch { recordSourceFault(error); return original }
    }
    public func destroy(_ object: any SourceAPIObject) {
        guard let handle = owned(object), document.object(handle.id) != nil else { return }
        pending.insert(handle.id)
        sourceActivationChanged?()
    }
    public func pendingSourceDestruction() -> [any SourceAPIObject] {
        document.objects.filter { object in pending.contains(object.id) || pending.contains(where: { document.isDescendant(object.id, of: $0) }) }
            .compactMap { try? self.object(id: $0.id) }
    }
    public func completeSourceDestruction() {
        let ids = pending; pending.removeAll()
        for id in ids { document.remove(id) }
        // Retain identity tombstones so a native save can restore destroyed
        // bindings without resurrecting an original source object.
        // Existing script handles survive as dead handles, matching deferred
        // destruction. Future transform access reports a callback failure.
    }
    public func beginSourceTransaction() throws {
        guard transactions.count < 64 else { throw SourcePluginError.budget }
        transactions.append(.init(document: document, identities: identities, cloneSerial: cloneSerial, pending: pending, fault: fault))
        if transactions.count == 1 { fault = nil }
    }
    public func commitSourceTransaction() throws {
        try checkSourceFault()
        guard !transactions.isEmpty else { throw SourcePluginError.runtime("Unbalanced plugin transaction.") }
        transactions.removeLast()
    }
    public func rollbackSourceTransaction() {
        guard let saved = transactions.popLast() else { return }
        document = saved.document; identities = saved.identities; cloneSerial = saved.cloneSerial; pending = saved.pending; fault = saved.fault
    }
    public func recordSourceFault(_ error: any Error) { if fault == nil { fault = error } }
    public func checkSourceFault() throws { if let fault { throw fault } }
    private func matrixError(_ a: float4x4, _ b: float4x4) -> Float {
        (0..<4).flatMap { i in (0..<4).map { j in abs(a[i][j] - b[i][j]) } }.max() ?? 0
    }
    private func parentFrame(_ object: StudioObject) throws -> AttachmentFrame {
        guard let id = object.parent, let parent = document.object(id) else {
            guard object.parent == nil else { throw SourcePluginError.runtime("Missing plugin transform parent.") }
            return (matrix_identity_float4x4, .identity)
        }
        var frame = try worldFrame(parent)
        if object.sourceAttachmentPoint != nil {
            guard let attachment else { throw SourcePluginError.runtime("Original attachment transform adapter is unavailable.") }
            let local = try attachment(object, parent)
            frame.matrix = frame.matrix * local.matrix; frame.rotation = (frame.rotation * local.rotation).normalized
        }
        return frame
    }
    private func worldFrame(_ object: StudioObject) throws -> AttachmentFrame {
        var current = object, matrix = object.transform.matrix, rotation = object.transform.quaternion
        var visited: Set<UUID> = [object.id]
        while let id = current.parent {
            guard visited.insert(id).inserted, let parent = document.object(id) else { throw SourcePluginError.runtime("Invalid plugin transform hierarchy.") }
            if current.sourceAttachmentPoint != nil {
                guard let attachment else { throw SourcePluginError.runtime("Original attachment transform adapter is unavailable.") }
                let local = try attachment(current, parent)
                matrix = local.matrix * matrix; rotation = local.rotation * rotation
            }
            matrix = parent.transform.matrix * matrix; rotation = parent.transform.quaternion * rotation
            current = parent
        }
        return (matrix, rotation.normalized)
    }
    private func read(_ id: UUID, _ field: String) -> SIMD3<Float> {
        do {
            guard let object = document.object(id) else { throw SourcePluginError.runtime("Transform belongs to a destroyed object.") }
            switch field {
            case "localPosition": return UnityCoordinates.position(object.transform.position)
            case "localScale": return object.transform.scale
            default: return UnityCoordinates.position(try worldFrame(object).matrix.translation)
            }
        } catch { recordSourceFault(error); return .zero }
    }
    private func write(_ id: UUID, _ field: String, _ value: SIMD3<Float>) {
        do {
            guard (0..<3).allSatisfy({ value[$0].isFinite }), let index = document.index(of: id) else { throw SourcePluginError.runtime("Nonfinite or dead plugin transform write.") }
            switch field {
            case "localPosition": document.objects[index].transform.position = UnityCoordinates.position(value)
            case "localScale": document.objects[index].transform.scale = value
            default:
                let parent = try parentFrame(document.objects[index]).matrix
                guard parent.determinant.isFinite, abs(parent.determinant) > 1e-10 else { throw SourcePluginError.runtime("Cannot set world position under a singular parent.") }
                document.objects[index].transform.position = parent.inverse.transformPoint(UnityCoordinates.position(value))
            }
        } catch { recordSourceFault(error) }
    }
    private func translate(_ id: UUID, _ value: SIMD3<Float>, _ space: SourceAPISpace) {
        do {
            guard (0..<3).allSatisfy({ value[$0].isFinite }), let object = document.object(id) else { throw SourcePluginError.runtime("Nonfinite or dead plugin Translate.") }
            let frame = try worldFrame(object)
            let delta = UnityCoordinates.direction(value)
            let next = frame.matrix.translation + (space == .world ? delta : frame.rotation.act(delta))
            write(id, "position", UnityCoordinates.position(next))
        } catch { recordSourceFault(error) }
    }
    private final class Object: SourceAPIObject, SourceAPITransform {
        unowned let world: SourceStudioPluginWorld
        let id: UUID, sourceIdentity: String
        init(world: SourceStudioPluginWorld, id: UUID, identity: String) { self.world = world; self.id = id; sourceIdentity = identity }
        var transform: any SourceAPITransform { self }
        func setActive(_ active: Bool) {
            guard let index = world.document.index(of: id) else { world.recordSourceFault(SourcePluginError.runtime("SetActive on a destroyed object.")); return }
            if world.document.objects[index].visible != active {
                world.document.objects[index].visible = active
                world.sourceActivationChanged?()
            }
        }
        var position: SIMD3<Float> { get { world.read(id, "position") } set { world.write(id, "position", newValue) } }
        var localPosition: SIMD3<Float> { get { world.read(id, "localPosition") } set { world.write(id, "localPosition", newValue) } }
        var localScale: SIMD3<Float> { get { world.read(id, "localScale") } set { world.write(id, "localScale", newValue) } }
        func translate(_ delta: SIMD3<Float>, relativeTo: SourceAPISpace) { world.translate(id, delta, relativeTo) }
    }
}
