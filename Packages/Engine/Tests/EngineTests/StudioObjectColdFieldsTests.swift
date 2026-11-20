import Testing
import Foundation
import CoreMath
import Scene
import Character
@testable import Studio

/// #409: `StudioObject`'s nine boxed fields (`StudioObjectColdFields`). A
/// write never reaches another copy of the object, an edit of any other field
/// keeps the box shared, the box crosses tasks as a value, objects without
/// boxed fields share one empty box that is never written, `==` compares
/// contents, and the saved keys stay those of the unboxed struct.

private let objectID = UUID(uuidString: "4C0D0409-0000-4000-8000-000000000409")!

private let samplePose = PoseDelta(rotations: ["cf_j_neck": Float3(10, 0, 0)], translations: ["cf_j_hips": Float3(0, 0.1, 0)])

private func sampleCard(_ name: String) -> CharacterCard {
    var card = CharacterCard()
    card.id = UUID(uuidString: "4C0D0409-0000-4000-8000-0000000000CA")!
    card.profile.name = name
    return card
}

private let sampleReference = SourceStudioCharacterReference(
    sceneFile: "/synthetic/scene.png", sceneSHA256: String(repeating: "a", count: 64), rigFile: "/synthetic/rig.json",
    boneCatalogFile: "/synthetic/bones.json", objectKey: 7)

private let sampleExpression = SourceStudioExpressionState(
    eyebrowPattern: 1, eyesPattern: 2, mouthPattern: 3, eyesOpen: 0.5, blink: false, mouthOpen: 0.25, lipSync: true,
    eyesLookPattern: 1, neckLookPattern: 2, tears: 1, cheek: 0.5)

private let sampleKinematics = SourceStudioKinematicState(
    enableFK: true, enableIK: false, activeFK: Array(repeating: true, count: 7), activeIK: Array(repeating: false, count: 5))

/// `SourceStudioAnimationState` has no memberwise initializer outside its module.
private func sampleAnimation(speed: Float = 1.5) throws -> SourceStudioAnimationState {
    let json = #"{"group":1,"category":2,"no":3,"speed":\#(speed),"pattern":0.25,"normalizedTime":0.5,"forceLoop":true,"optionParameters":[0.125,0.25]}"#
    return try JSONDecoder().decode(SourceStudioAnimationState.self, from: Data(json.utf8))
}

private let sampleVoice = SourceStudioVoiceState(playlist: [.init(group: 1, category: 2, no: 3)], repeatMode: 1)

private let sampleRoute = SourceStudioRouteState(points: [], loop: true, visibleLine: false, orientation: 1, color: SIMD4<Float>(1, 0, 0, 1))

private func sampleLight(intensity: Float = 0.7) -> SceneLight {
    var light = SceneLight(kind: .spot)
    light.intensity = intensity
    return light
}

private func sampleCamera(distance: Float = 4) -> OrbitCamera {
    var camera = OrbitCamera()
    camera.distance = distance
    return camera
}

/// A character with every boxed field set; two calls build equal objects
/// that hold separate boxes.
private func populated() throws -> StudioObject {
    var object = StudioObject(name: "Populated", kind: .character)
    object.id = objectID
    object.card = sampleCard("Boxed A")
    object.sourceCharacter = sampleReference
    object.sourceExpression = sampleExpression
    object.sourceKinematics = sampleKinematics
    object.sourceAnimation = try sampleAnimation()
    object.sourceVoice = sampleVoice
    object.sourceRoute = sampleRoute
    object.poseDelta = samplePose
    object.light = sampleLight()
    object.savedCamera = sampleCamera()
    return object
}

/// Writes `second` over `first` through `path` on an object a snapshot
/// shares: the snapshot keeps `first`, the edited object owns a new box, and
/// a later write to that box copies nothing.
private func checkIsolation<Value: Equatable>(_ path: WritableKeyPath<StudioObject, Value>, _ first: Value, _ second: Value,
                                             sourceLocation: SourceLocation = #_sourceLocation) {
    var object = StudioObject(name: "Isolated", kind: .character)
    object[keyPath: path] = first
    let snapshot = object
    #expect(snapshot.cold === object.cold, sourceLocation: sourceLocation)
    object[keyPath: path] = second
    #expect(snapshot[keyPath: path] == first, sourceLocation: sourceLocation)
    #expect(object[keyPath: path] == second, sourceLocation: sourceLocation)
    #expect(snapshot.cold !== object.cold, sourceLocation: sourceLocation)
    let owned = ObjectIdentifier(object.cold)
    object[keyPath: path] = first
    #expect(ObjectIdentifier(object.cold) == owned, sourceLocation: sourceLocation)
    #expect(snapshot[keyPath: path] == first, sourceLocation: sourceLocation)
}

@Test func boxedFieldWritesLeaveSnapshotsUnchanged() throws {
    checkIsolation(\.card, sampleCard("Boxed A"), sampleCard("Boxed B"))
    checkIsolation(\.card, sampleCard("Boxed A"), nil)
    checkIsolation(\.sourceCharacter, sampleReference, nil)
    checkIsolation(\.sourceExpression, sampleExpression, nil)
    var blinking = sampleExpression; blinking.blink = true
    checkIsolation(\.sourceExpression, sampleExpression, blinking)
    checkIsolation(\.sourceKinematics, sampleKinematics, nil)
    checkIsolation(\.sourceAnimation, try sampleAnimation(), try sampleAnimation(speed: 2))
    checkIsolation(\.sourceVoice, sampleVoice, nil)
    checkIsolation(\.sourceRoute, sampleRoute, nil)
    checkIsolation(\.light, sampleLight(), sampleLight(intensity: 0.2))
    checkIsolation(\.savedCamera, sampleCamera(), sampleCamera(distance: 9))
}

/// A write into a boxed field's own storage (a dictionary entry, one member
/// of an optional struct) copies the box too, and only once.
@Test func inPlaceBoxedFieldEditsLeaveSnapshotsUnchanged() throws {
    var object = try populated()
    let snapshot = object
    object.poseDelta.rotations["cf_j_neck"] = Float3(45, 0, 0)
    object.light?.intensity = 0.1
    let owned = ObjectIdentifier(object.cold)
    object.card?.profile.name = "Renamed"
    object.savedCamera?.distance = 1
    #expect(ObjectIdentifier(object.cold) == owned)
    #expect(try populated() == snapshot)
    #expect(snapshot.poseDelta == samplePose && snapshot.light?.intensity == 0.7)
    #expect(snapshot.card?.profile.name == "Boxed A" && snapshot.savedCamera?.distance == 4)
    #expect(object.poseDelta.rotations["cf_j_neck"] == Float3(45, 0, 0) && object.light?.intensity == 0.1)
    #expect(object.card?.profile.name == "Renamed" && object.savedCamera?.distance == 1)
}

/// The edits an undo step follows most (move, rename, show/hide) leave the
/// box shared with the step, so the step costs only the 464-byte object.
@Test func unboxedFieldEditsKeepTheBoxShared() throws {
    var object = try populated()
    let snapshot = object
    object.transform.position.x = 1
    object.name = "Moved"
    object.visible = false
    object.ikTargets[.handL] = IKTarget(enabled: true)
    object.sourceFKRotations = [1: Float3(5, 0, 0)]
    #expect(object.cold === snapshot.cold)
    #expect(object != snapshot)
}

/// A pose edit, the most frequent object edit, copies no box (#409, W23):
/// the pose delta is inline, so an edit that writes it leaves the box shared
/// with the undo step, as `update` makes it (copy, edit, compare, write
/// back), and an object on the shared empty box stays on it.
@Test func aPoseEditCopiesNoBox() throws {
    var document = StudioDocument()
    document.objects = [try populated()] + importedItems(1)
    let step = document
    for index in document.objects.indices {
        var object = document.objects[index]
        object.poseDelta.rotations["cf_j_neck", default: .zero].x += 0.5
        #expect(object != document.objects[index])
        document.objects[index] = object
    }
    #expect(document.objects[0].cold === step.objects[0].cold)
    #expect(document.objects[1].cold === StudioObjectColdFields.empty)
    #expect(step.objects[0].poseDelta == samplePose && step.objects[1].poseDelta == PoseDelta())
    #expect(document.objects[0].poseDelta != samplePose && document.objects[1].poseDelta.rotations["cf_j_neck"] == Float3(0.5, 0, 0))
}

@Test func aUniquelyHeldBoxIsWrittenInPlace() throws {
    var object = try populated()
    let owned = ObjectIdentifier(object.cold)
    object.card = sampleCard("Boxed B")
    object.sourceCharacter = nil
    object.light = nil
    #expect(ObjectIdentifier(object.cold) == owned)
}

private actor SnapshotHolder {
    let object: StudioObject
    init(_ object: StudioObject) { self.object = object }
    var cardName: String? { object.card?.profile.name }
    var lightIntensity: Float? { object.light?.intensity }
    var pose: PoseDelta { object.poseDelta }
}

/// A snapshot sent to an actor and to a detached task reads the values it was
/// taken with while this task keeps writing the original's boxed fields.
@Test func aSnapshotSentToAnotherTaskKeepsItsValues() async throws {
    var original = try populated()
    let snapshot = original
    let holder = SnapshotHolder(snapshot)
    let reader = Task.detached { () -> Int in
        var mismatches = 0
        for _ in 0..<20_000 {
            if snapshot.card?.profile.name != "Boxed A" || snapshot.light?.intensity != 0.7 || snapshot.poseDelta != samplePose {
                mismatches += 1
            }
        }
        return mismatches
    }
    for step in 0..<20_000 {
        original.card?.profile.name = "Edit \(step)"
        original.light?.intensity = Float(step)
        original.poseDelta.rotations["cf_j_neck"] = Float3(Float(step), 0, 0)
    }
    #expect(await reader.value == 0)
    #expect(await holder.cardName == "Boxed A")
    #expect(await holder.lightIntensity == 0.7)
    #expect(await holder.pose == samplePose)
    #expect(original.card?.profile.name == "Edit 19999" && original.light?.intensity == 19_999)
    #expect(try populated() == snapshot)
}

@Test func boxedObjectsCompareByContents() throws {
    let a = try populated(), b = try populated()
    #expect(a.cold !== b.cold)
    #expect(a == b)
    var c = a
    #expect(c == a && c.cold === a.cold)
    c.light?.intensity = 0.1
    #expect(c != a)
    c.light?.intensity = 0.7
    #expect(c == a && c.cold !== a.cold)
    var d = a
    d.poseDelta.rotations["cf_j_spine01"] = .zero
    #expect(d != a)
    var e = a
    e.card?.profile.name = "Boxed B"
    #expect(e != a)
    var f = a
    f.name = "Other"
    #expect(f != a && f.cold === a.cold)
}

// MARK: - The shared empty box

/// Items as a source import makes them: hot fields only.
private func importedItems(_ count: Int) -> [StudioObject] {
    (0..<count).map { index in
        var item = StudioObject(name: "Item \(index)", kind: .item)
        item.itemID = "item_\(index)"; item.sourceObjectKey = Int32(index); item.sourceRecordKind = .item
        item.transform.position = Float3(Float(index), 0, 0)
        return item
    }
}

@Test func objectsWithoutBoxedFieldsShareTheEmptyBox() throws {
    var document = StudioDocument()
    document.objects = importedItems(3) + [try populated(), StudioObject.light(.point)]
    for item in document.objects.prefix(3) { #expect(item.cold === StudioObjectColdFields.empty) }
    let decoded = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(document))
    #expect(decoded == document)
    for item in decoded.objects.prefix(3) { #expect(item.cold === StudioObjectColdFields.empty) }
    #expect(decoded.objects[3].cold !== StudioObjectColdFields.empty)
    #expect(decoded.objects[4].cold !== StudioObjectColdFields.empty)
}

/// The first boxed write on one item gives it its own box; the other items
/// and the shared box are untouched.
@Test func theFirstBoxedWriteDetachesOnlyThatItem() throws {
    var document = StudioDocument()
    document.objects = importedItems(3)
    document = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(document))
    let snapshot = document
    document.objects[1].light = sampleLight()
    #expect(document.objects[1].cold !== StudioObjectColdFields.empty && document.objects[1].light == sampleLight())
    #expect(document.objects[0].cold === StudioObjectColdFields.empty && document.objects[2].cold === StudioObjectColdFields.empty)
    #expect(document.objects[0].light == nil && snapshot.objects[1].light == nil)
    #expect(snapshot.objects[1].cold === StudioObjectColdFields.empty)
    #expect(StudioObjectColdFields.empty.holdsDefaults)
    // Written back to nil, the item keeps its own box, equal to the empty one.
    document.objects[1].light = nil
    #expect(document.objects[1].cold !== StudioObjectColdFields.empty)
    #expect(document.objects[1] == snapshot.objects[1])
}

/// 20,000 boxed writes from four tasks on copies of an item that holds the
/// shared box: every one detaches, and the shared box stays empty.
@Test func theEmptyBoxStaysEmptyUnderConcurrentEdits() async {
    let item = importedItems(1)[0]
    #expect(item.cold === StudioObjectColdFields.empty)
    let detached = await withTaskGroup(of: Int.self) { group in
        for worker in 0..<4 {
            group.addTask {
                var owned = 0
                for step in 0..<5_000 {
                    var object = item
                    switch step % 4 {
                    case 0: object.card = sampleCard("Worker \(worker)")
                    case 1: object.savedCamera = sampleCamera(distance: Float(step))
                    case 2: object.light = sampleLight(intensity: Float(step))
                    default: object.sourceVoice = sampleVoice
                    }
                    if object.cold !== StudioObjectColdFields.empty { owned += 1 }
                }
                return owned
            }
        }
        return await group.reduce(0, +)
    }
    #expect(detached == 20_000)
    #expect(StudioObjectColdFields.empty.holdsDefaults)
    #expect(item.cold === StudioObjectColdFields.empty && item.card == nil && item.light == nil && item.poseDelta == PoseDelta())
}

// MARK: - Saved keys

/// Every key the unboxed struct's synthesized conformance wrote, in its
/// declaration order. A saved scene card's objects carry these flat keys.
private let savedKeys = [
    "id", "name", "kind", "parent", "visible", "locked", "transform", "card", "sourceCharacter", "sourcePreviewName",
    "sourcePreviewKind", "sourceAttachmentPoint", "sourceFKRotations", "sourceIKOverrides", "sourceFaceValues",
    "sourceBodyValues", "sourceColorEdits", "sourceOutfit", "sourceClothesState", "sourceShowAccessory", "sourceShoesType",
    "sourceExpression", "sourceKinematics", "sourceAnimation", "sourceVoice", "sourceRoute", "poseDelta", "ikTargets",
    "animationPreset", "clothingVisible", "accessoriesVisible", "handGestureL", "handGestureR", "itemID", "assetFile",
    "sourceObjectKey", "sourceDuplicateOf", "sourceRecordKind", "tint", "emissive", "light", "fov", "savedCamera",
]

/// The keys an object always writes: its non-optional fields.
private let requiredKeys = [
    "id", "name", "kind", "visible", "locked", "transform", "poseDelta", "ikTargets", "clothingVisible",
    "accessoriesVisible", "handGestureL", "handGestureR", "emissive", "fov",
]

/// An object with every optional field set as well.
private func everyField() throws -> StudioObject {
    var object = try populated()
    object.parent = UUID(uuidString: "4C0D0409-0000-4000-8000-0000000000AA")!
    object.sourcePreviewName = "Preview"; object.sourcePreviewKind = .character; object.sourceAttachmentPoint = 3
    object.sourceFKRotations = [1: Float3(5, 0, 0)]; object.sourceIKOverrides = [2: SourceStudioIKEdit(position: Float3(0, 1, 0))]
    object.sourceFaceValues = [0.25]; object.sourceBodyValues = [0.5]; object.sourceColorEdits = ["skin": Float4(1, 0.5, 0.5, 1)]
    object.sourceOutfit = 2; object.sourceClothesState = [0, 1, 2, 3, 0, 1, 2, 3, 0]
    object.sourceShowAccessory = Array(repeating: true, count: 20); object.sourceShoesType = 1
    object.animationPreset = "idle"; object.itemID = "item"; object.assetFile = "/synthetic/item.glb"
    object.sourceObjectKey = 11; object.sourceDuplicateOf = 12; object.sourceRecordKind = .item
    object.tint = RGB(0.5, 0.25, 1)
    return object
}

@Test func savedKeysStayFlatAndUnchanged() throws {
    #expect(StudioObject.CodingKeys.allCases.map(\.stringValue) == savedKeys)
    #expect(try recordedKeys(everyField()) == savedKeys)
    #expect(try recordedKeys(StudioObject(name: "Prop", kind: .item)) == requiredKeys)
    let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(everyField())) as? [String: Any])
    #expect(Set(json.keys) == Set(savedKeys))
    #expect(json["cold"] == nil)
    let card = try #require(json["card"] as? [String: Any])
    #expect((card["profile"] as? [String: Any])?["name"] as? String == "Boxed A")
}

private func minimalJSON(removing removed: String? = nil, adding extra: [String: Any] = [:]) throws -> Data {
    var prop = StudioObject(name: "Prop", kind: .item)
    prop.id = objectID // fixed, so two calls decode equal objects
    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(prop)) as? [String: Any])
    #expect(Set(json.keys) == Set(requiredKeys))
    if let removed { json[removed] = nil }
    json.merge(extra) { _, new in new }
    return try JSONSerialization.data(withJSONObject: json)
}

@Test func decodingTreatsMissingAndUnknownKeysAsBefore() throws {
    // Missing optional keys, boxed or not, decode nil; the box takes its defaults.
    let minimal = try JSONDecoder().decode(StudioObject.self, from: minimalJSON())
    #expect(minimal.card == nil && minimal.light == nil && minimal.savedCamera == nil && minimal.sourceRoute == nil)
    #expect(minimal.parent == nil && minimal.itemID == nil && minimal.poseDelta == PoseDelta())
    #expect(minimal.cold === StudioObjectColdFields.empty)
    // Unknown keys are ignored, and an explicit null reads as a missing key.
    let extra = try JSONDecoder().decode(StudioObject.self, from: minimalJSON(adding: ["futureField": 1, "cold": ["card": 1], "light": NSNull()]))
    #expect(extra == minimal)
    // A non-optional field's key is required even though the field has a default.
    for key in ["poseDelta", "fov", "visible"] {
        do {
            _ = try JSONDecoder().decode(StudioObject.self, from: minimalJSON(removing: key))
            Issue.record("decoded without \(key)")
        } catch DecodingError.keyNotFound(let missing, _) {
            #expect(missing.stringValue == key)
        }
    }
}

/// Undo and Redo bring back boxed-field edits like any other, byte for byte.
@Test func undoAndRedoRestoreBoxedFieldEdits() throws {
    func bytes(_ document: StudioDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys] // CardIO.encode's setting
        return try encoder.encode(document)
    }
    var history = StudioUndoHistory<StudioDocument>()
    var current = StudioDocument()
    current.objects = [try populated(), StudioObject(name: "Prop", kind: .item)]
    let start = try bytes(current)
    history.record(current)
    current.objects[0].light?.intensity = 0.2
    current.objects[0].card?.profile.name = "Renamed"
    let renamed = try bytes(current)
    history.record(current)
    current.objects[0].poseDelta.rotations["cf_j_neck"] = Float3(45, 0, 0)
    current.objects[0].transform.position.x = 1
    let posed = try bytes(current)
    #expect(Set([start, renamed, posed]).count == 3)

    var step: StudioDocument?
    step = history.stepBack(leaving: current)
    current = try #require(step)
    #expect(try bytes(current) == renamed)
    step = history.stepBack(leaving: current)
    current = try #require(step)
    #expect(try bytes(current) == start)
    #expect(try populated() == current.objects[0])
    step = history.stepForward(leaving: current)
    current = try #require(step)
    #expect(try bytes(current) == renamed)
    step = history.stepForward(leaving: current)
    current = try #require(step)
    #expect(try bytes(current) == posed)
    #expect(current.objects[0].poseDelta.rotations["cf_j_neck"] == Float3(45, 0, 0))
}

// MARK: - Key order

/// The keys `value.encode(to:)` writes at its top level, in call order. It
/// encodes no values (sorted output hides the order, so JSON cannot show it).
func recordedKeys<Value: Encodable>(_ value: Value) throws -> [String] {
    let recorder = TopLevelKeyRecorder()
    try value.encode(to: recorder)
    return recorder.keys
}

final class TopLevelKeyRecorder: Encoder {
    var keys: [String] = []
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> { KeyedEncodingContainer(Keys<Key>(recorder: self)) }
    func unkeyedContainer() -> any UnkeyedEncodingContainer { Discard() }
    func singleValueContainer() -> any SingleValueEncodingContainer { Discard() }

    struct Keys<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let recorder: TopLevelKeyRecorder
        var codingPath: [any CodingKey] { [] }
        private func record(_ key: Key) { recorder.keys.append(key.stringValue) }
        mutating func encodeNil(forKey key: Key) { record(key) }
        mutating func encode(_ value: Bool, forKey key: Key) { record(key) }
        mutating func encode(_ value: String, forKey key: Key) { record(key) }
        mutating func encode(_ value: Double, forKey key: Key) { record(key) }
        mutating func encode(_ value: Float, forKey key: Key) { record(key) }
        mutating func encode(_ value: Int, forKey key: Key) { record(key) }
        mutating func encode(_ value: Int8, forKey key: Key) { record(key) }
        mutating func encode(_ value: Int16, forKey key: Key) { record(key) }
        mutating func encode(_ value: Int32, forKey key: Key) { record(key) }
        mutating func encode(_ value: Int64, forKey key: Key) { record(key) }
        mutating func encode(_ value: UInt, forKey key: Key) { record(key) }
        mutating func encode(_ value: UInt8, forKey key: Key) { record(key) }
        mutating func encode(_ value: UInt16, forKey key: Key) { record(key) }
        mutating func encode(_ value: UInt32, forKey key: Key) { record(key) }
        mutating func encode(_ value: UInt64, forKey key: Key) { record(key) }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) { record(key) }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            record(key)
            return TopLevelKeyRecorder().container(keyedBy: keyType)
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer { record(key); return Discard() }
        mutating func superEncoder() -> any Encoder { TopLevelKeyRecorder() }
        mutating func superEncoder(forKey key: Key) -> any Encoder { record(key); return TopLevelKeyRecorder() }
    }

    /// Takes nested values (the key-ordered dictionary arrays, #394) and drops them.
    struct Discard: UnkeyedEncodingContainer, SingleValueEncodingContainer {
        var codingPath: [any CodingKey] { [] }
        var count = 0
        mutating func encodeNil() {}
        mutating func encode(_ value: Bool) {}
        mutating func encode(_ value: String) {}
        mutating func encode(_ value: Double) {}
        mutating func encode(_ value: Float) {}
        mutating func encode(_ value: Int) {}
        mutating func encode(_ value: Int8) {}
        mutating func encode(_ value: Int16) {}
        mutating func encode(_ value: Int32) {}
        mutating func encode(_ value: Int64) {}
        mutating func encode(_ value: UInt) {}
        mutating func encode(_ value: UInt8) {}
        mutating func encode(_ value: UInt16) {}
        mutating func encode(_ value: UInt32) {}
        mutating func encode(_ value: UInt64) {}
        mutating func encode<T: Encodable>(_ value: T) {}
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            TopLevelKeyRecorder().container(keyedBy: keyType)
        }
        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { Discard() }
        mutating func superEncoder() -> any Encoder { TopLevelKeyRecorder() }
    }
}
