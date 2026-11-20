import Foundation
import simd
import CoreMath
import Assets
import Scene
import Renderer
import Character
import Gameplay

public enum StudioObjectKind: String, Codable, Sendable { case character, item, light, camera, folder }

public struct StudioTransform: Codable, Sendable, Equatable {
    public var position = Float3.zero
    public var rotation = Float3.zero { didSet { rotationOverride = nil } } // Editable Euler XYZ degrees
    /// Exact imported quaternion; an explicit Euler edit replaces it.
    public var rotationOverride: Float4? {
        // Cheap tidy-up only: `currentSourceEuler` checks the bits itself.
        didSet { if let sourceEuler, !sourceEuler.describes(rotationOverride) { self.sourceEuler = nil } }
    }
    public var scale = Float3(repeating: 1)
    /// The original's own Euler angles for `rotationOverride` (#391); read
    /// through `currentSourceEuler`.
    public var sourceEuler: SourceEuler?
    public init() {}

    /// A source scene object's transform: its stored position and scale in
    /// engine coordinates, its exact quaternion, and the Euler angles the
    /// original stores and shows for it.
    public init(source: KoikatsuChangeAmount) {
        position = UnityCoordinates.position(source.position)
        scale = source.scale
        setSourceEuler(source.rotationDegrees)
    }

    /// CharaStudio's rotation numbers (#391): Z-X-Y Euler degrees in Unity
    /// coordinates, recorded for one exact `rotationOverride`.
    public struct SourceEuler: Codable, Sendable, Equatable {
        public var degrees: Float3
        /// The override these degrees describe, compared by its bits.
        public var override: Float4
        public init(degrees: Float3, override: Float4) { self.degrees = degrees; self.override = override }

        func describes(_ rotation: Float4?) -> Bool {
            guard let rotation else { return false }
            return (0..<4).allSatisfy { override[$0].bitPattern == rotation[$0].bitPattern }
        }
    }

    /// The original's Euler angles while they still describe this rotation:
    /// only while `rotationOverride` holds exactly the bits they were recorded
    /// for. Any other rotation write (the gizmo, reparenting, a plug-in clone,
    /// IK, an engine-Euler edit) changes or clears the override, which retires
    /// them whichever path made the write.
    public var currentSourceEuler: Float3? {
        guard let sourceEuler, sourceEuler.describes(rotationOverride) else { return nil }
        return sourceEuler.degrees
    }

    /// A source object's Rotation row: the original's angles, or else the
    /// current rotation decomposed the way the original stores rotations.
    public var sourceRotationDegrees: Float3 {
        currentSourceEuler ?? UnityCoordinates.sourceEulerDegrees(quaternion)
    }

    /// Rotates to the original's Euler `degrees` and records them, as the
    /// original derives its transform from its three stored angles.
    public mutating func setSourceEuler(_ degrees: Float3) {
        let rotation = UnityCoordinates.eulerDegrees(degrees)
        self.rotation = rotation.eulerXYZ.radiansToDegrees
        rotationOverride = rotation.vector
        sourceEuler = SourceEuler(degrees: degrees, override: rotation.vector)
    }

    /// The record an original-format export writes for this transform, or nil
    /// when it still matches `original`. An unchanged rotation keeps the
    /// original's bytes; a changed one writes the original's angles while
    /// they are current (#391: an inspector commit changes only its own
    /// component), and otherwise a fresh decomposition.
    public func sourceChangeAmount(original: KoikatsuChangeAmount) -> KoikatsuChangeAmount? {
        let rotationChanged: Bool
        if let degrees = currentSourceEuler {
            rotationChanged = degrees != original.rotationDegrees
        } else {
            let originalRotation = UnityCoordinates.eulerDegrees(original.rotationDegrees)
            rotationChanged = quaternion.vector != originalRotation.vector && quaternion.vector != -originalRotation.vector
        }
        guard position != UnityCoordinates.position(original.position) || scale != original.scale || rotationChanged else { return nil }
        return KoikatsuChangeAmount(
            position: UnityCoordinates.position(position),
            rotationDegrees: rotationChanged ? sourceRotationDegrees : original.rotationDegrees,
            scale: scale)
    }
    public var matrix: float4x4 { Transform.trs(position, quaternion, scale) }
    public var quaternion: simd_quatf {
        rotationOverride.map { simd_quatf(vector: $0) } ?? simd_quatf(eulerXYZ: rotation.degreesToRadians)
    }

    /// The inspector's vector rows. A source object's Rotation row edits the
    /// original's Euler angles (`sourceRotation`, #391).
    public enum Vector: Sendable { case position, rotation, scale, sourceRotation }

    /// One inspector field's commit (#390): writes only its own component, onto
    /// the transform as it is now. A field must not write back the whole vector
    /// it last read, since a second field committed before the view re-renders
    /// would undo the first one's write.
    ///
    /// `sourceRotation` commits as CharaStudio's end-of-edit does (#391): the
    /// value modulo 360, sign kept, replaces its component only when it
    /// differs, and the rotation is rebuilt from the three angles, so the
    /// other two keep their exact values.
    public mutating func set(_ vector: Vector, _ component: Int, to value: Float) {
        switch vector {
        case .position: position[component] = value
        case .rotation: rotation[component] = value
        case .scale: scale[component] = value
        case .sourceRotation:
            var degrees = sourceRotationDegrees
            let angle = value.truncatingRemainder(dividingBy: 360)
            guard angle != degrees[component] else { return }
            degrees[component] = angle
            setSourceEuler(degrees)
        }
    }
}

/// One node of the studio workspace tree.
///
/// #409: every undo step keeps its own copy of the `objects` array once an
/// edit writes to it, so each inline byte of an object is paid again per
/// step. The nine fields that are large inline and seldom edited (the
/// character card, the source character reference, its expression,
/// kinematics, animation, voice and route state, the light and the saved
/// camera) therefore live in one shared box, `StudioObjectColdFields`, which
/// takes the stride from 1,584 B to 464 B. The pose delta stays inline (32 B,
/// four dictionary references): a pose edit is the most frequent object edit,
/// and boxing it made every one copy the whole box (#409's W23 diagnostic).
/// They read and write like stored properties. A read borrows the field in
/// the box (`_read`), so reading a member or testing for nil copies nothing.
/// A write first copies the box unless this value holds the only reference to
/// it, so no copy of an object ever sees another copy's edits, and an edit of
/// any other field leaves the box shared with the undo steps. A repeated edit
/// (a drag) should therefore write through the document's array in place
/// (`doc.objects[i].field = …`), not through a copy of the object: a copy
/// shares the box and makes every write copy it again. Objects whose boxed fields are all nil or
/// default (most items and folders) share one empty box that is never
/// written (`StudioObjectColdFields.empty`). `Codable` keeps the synthesized format of
/// the unboxed struct (flat keys, in declaration order, optionals omitted
/// when nil; see `CodingKeys`), and `==` compares every field.
public struct StudioObject: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var kind: StudioObjectKind
    public var parent: UUID?
    public var visible = true
    public var locked = false
    public var transform = StudioTransform()
    /// The boxed fields, shared between copies of this object until one of
    /// them writes a boxed field (`uniqueCold()`).
    private(set) var cold: StudioObjectColdFields
    // character
    public var card: CharacterCard? {
        _read { yield cold.card }
        _modify { let box = uniqueCold(); yield &box.card }
    }
    public var sourceCharacter: SourceStudioCharacterReference? {
        _read { yield cold.sourceCharacter }
        _modify { let box = uniqueCold(); yield &box.sourceCharacter }
    }
    /// Import baselines let original-format export reject native rename/type
    /// edits without confusing retained placeholders with rendered characters.
    public var sourcePreviewName: String?
    public var sourcePreviewKind: StudioObjectKind?
    public var sourceAttachmentPoint: Int32?
    /// Original catalog bone IDs and Unity local Euler degrees; separate from
    /// the prototype skeleton's rest-relative pose deltas.
    public var sourceFKRotations: [Int: Float3]?
    public var sourceIKOverrides: [Int32: SourceStudioIKEdit]?
    /// Edited face shape slot rates in contract order; nil keeps the card's
    /// saved values. Export writes the array back into the embedded card.
    public var sourceFaceValues: [Float]?
    /// Edited body shape slot rates in contract order; nil keeps the card's
    /// saved values. Export writes the array back into the embedded card.
    public var sourceBodyValues: [Float]?
    /// Edited card colors keyed by the draft color ID; nil keeps the card's
    /// saved colors. Export writes each differing color back into the embedded
    /// card together with any shape arrays.
    public var sourceColorEdits: [String: Float4]?
    /// Selected saved outfit (ChaFileStatus.coordinateType, 0...6); nil keeps
    /// the card's saved outfit. The preview rebuilds for it and export writes
    /// it into the embedded card's Status block. Documents saved before this
    /// field existed decode it as nil.
    public var sourceOutfit: Int?
    /// Edited clothes state (ChaFileStatus.clothesState, nine ClothesKind
    /// bytes 0 on ... 3 off) as the rendered outfit holds it after the
    /// CharaStudio SetClothesState rules; nil keeps the state the card's saved
    /// bytes load as. Export writes it into the embedded card's Status block
    /// when it differs from the saved bytes. Older documents decode nil.
    public var sourceClothesState: [UInt8]?
    /// Edited accessory visibility (ChaFileStatus.showAccessory, 20 slots);
    /// nil keeps the card's saved flags. Older documents decode nil.
    public var sourceShowAccessory: [Bool]?
    /// Edited shoes type (ChaFileStatus.shoesType, 0 indoor, 1 outdoor;
    /// CharaStudio's State panel shoes buttons); nil keeps the card's saved
    /// value. Export writes it into the embedded card's Status block when it
    /// differs. Older documents decode nil.
    public var sourceShoesType: Int?
    /// Edited face state (ST-C04, the CharaStudio State panel's expression,
    /// look, tears and cheek controls); nil keeps the values the scene load
    /// leaves. Export writes the changed Status fields into the embedded card
    /// and mouthOpen/lipSync into the character record. Older documents
    /// decode nil.
    public var sourceExpression: SourceStudioExpressionState? {
        _read { yield cold.sourceExpression }
        _modify { let box = uniqueCold(); yield &box.sourceExpression }
    }
    public var sourceKinematics: SourceStudioKinematicState? {
        _read { yield cold.sourceKinematics }
        _modify { let box = uniqueCold(); yield &box.sourceKinematics }
    }
    /// Original catalog IDs and timing; nil resumes the source scene's values.
    public var sourceAnimation: SourceStudioAnimationState? {
        _read { yield cold.sourceAnimation }
        _modify { let box = uniqueCold(); yield &box.sourceAnimation }
    }
    public var sourceVoice: SourceStudioVoiceState? {
        _read { yield cold.sourceVoice }
        _modify { let box = uniqueCold(); yield &box.sourceVoice }
    }
    /// ST-T11: an imported route's edited points and settings (CharaStudio's
    /// route point guides and route panels); nil keeps the record's own.
    /// Set on a route record or a copy of one; export writes it into the
    /// record (`SourceSceneEdits.routes`). Older documents decode nil.
    public var sourceRoute: SourceStudioRouteState? {
        _read { yield cold.sourceRoute }
        _modify { let box = uniqueCold(); yield &box.sourceRoute }
    }
    /// Inline, not boxed: written by every pose edit (see above).
    public var poseDelta = PoseDelta()
    public var ikTargets: [IKChain: IKTarget] = [:]
    public var animationPreset: String?
    public var clothingVisible = true
    public var accessoriesVisible = true
    public var handGestureL = 0
    public var handGestureR = 0
    // item
    public var itemID: String?
    /// Local converted glTF/GLB path. Kept separate from catalog IDs and persisted in scene cards.
    public var assetFile: String?
    public var sourceObjectKey: Int32?
    /// ST-T03: the source record this object copies (`Studio.Duplicate`),
    /// set on a duplicate of a source object or of another copy instead of
    /// `sourceObjectKey`, which only ever names the record an object IS. The
    /// copy renders and edits like its source record and exports as a new
    /// record built from that record's bytes. Documents saved before this
    /// field existed decode it as nil.
    public var sourceDuplicateOf: Int32?
    /// The source record whose data this object shows: its own record, or
    /// the record it was duplicated from.
    public var sourceRecordKey: Int32? { sourceObjectKey ?? sourceDuplicateOf }
    /// The source record's kind, which selects the Studio scale rule; nil in
    /// documents saved before it was recorded, whose placeholders are folders.
    public var sourceRecordKind: KoikatsuObjectKind?
    public var tint: RGB?
    public var emissive: Float = 0
    // light
    public var light: SceneLight? {
        _read { yield cold.light }
        _modify { let box = uniqueCold(); yield &box.light }
    }
    // camera
    public var fov: Float = 30
    public var savedCamera: OrbitCamera? {
        _read { yield cold.savedCamera }
        _modify { let box = uniqueCold(); yield &box.savedCamera }
    }

    public init(name: String, kind: StudioObjectKind) {
        self.name = name; self.kind = kind; cold = .empty
    }

    /// The box, made this value's own before a boxed field is written: the
    /// shared empty box, or a box another value also holds (an undo step, a
    /// snapshot, a copy sent to another task), is copied first and the other
    /// holders keep the original. The empty box is recognised by identity, so
    /// it is never written whatever its reference count.
    private mutating func uniqueCold() -> StudioObjectColdFields {
        if cold === StudioObjectColdFields.empty || !isKnownUniquelyReferenced(&cold) {
            cold = StudioObjectColdFields(copying: cold)
        }
        return cold
    }

    public static func character(_ card: CharacterCard) -> StudioObject {
        var o = StudioObject(name: card.profile.name, kind: .character)
        o.card = card
        return o
    }
    public static func item(id: String, name: String) -> StudioObject {
        var o = StudioObject(name: name, kind: .item)
        o.itemID = id
        return o
    }
    public static func light(_ kind: LightKind) -> StudioObject {
        var o = StudioObject(name: kind.rawValue.capitalized + " light", kind: .light)
        var l = SceneLight(kind: kind)
        switch kind {
        case .directional: l.rotation = Float3(50, -30, 0); l.intensity = 0.6
        case .point: l.position = Float3(0.6, 1.5, 0.6); l.range = 3; l.intensity = 0.5; l.color = Float3(1, 0.9, 0.8)
        case .spot: l.position = Float3(0, 2.4, 1.2); l.rotation = Float3(-60, 0, 0); l.range = 6; l.spotAngle = 45; l.intensity = 0.7
        }
        o.light = l
        o.transform.position = l.position
        o.transform.rotation = l.rotation
        return o
    }

    /// One field of the Pose tab's IK "Target" row (#393): writes `component`
    /// onto the chain's target as it is now, so a second field committed
    /// before the inspector re-renders keeps the first field's write. A chain
    /// without a target, or a component outside 0...2, is left alone.
    public mutating func setIKTarget(_ chain: IKChain, component: Int, to value: Float) {
        guard (0..<3).contains(component) else { return }
        ikTargets[chain]?.position[component] = value
    }
}

// MARK: - The boxed fields (#409)

/// `StudioObject`'s boxed fields, in their declaration order there.
///
/// `@unchecked Sendable` is sound because a box is never written while
/// another value can see it. `StudioObject` writes a field only through
/// `uniqueCold()`, which copies the box when it is the shared `empty` box or
/// `isKnownUniquelyReferenced` does not hold, and keeps no other reference to
/// it. So once a second object value holds the box (an undo step, a
/// snapshot, a copy sent to another task), no one writes it again; it is
/// read-only from then on, like the buffer of a standard library collection.
/// Every field is a `Sendable` value.
final class StudioObjectColdFields: @unchecked Sendable {
    var card: CharacterCard?
    var sourceCharacter: SourceStudioCharacterReference?
    var sourceExpression: SourceStudioExpressionState?
    var sourceKinematics: SourceStudioKinematicState?
    var sourceAnimation: SourceStudioAnimationState?
    var sourceVoice: SourceStudioVoiceState?
    var sourceRoute: SourceStudioRouteState?
    var light: SceneLight?
    var savedCamera: OrbitCamera?

    /// The box of every object whose boxed fields are all nil or default:
    /// most of a scene's items and folders. One instance is shared by all of
    /// them and never written (`uniqueCold()` checks for it by identity), so
    /// such an object costs only its inline bytes, and a load allocates no box
    /// for it.
    static let empty = StudioObjectColdFields(card: nil, sourceCharacter: nil, sourceExpression: nil, sourceKinematics: nil,
                                              sourceAnimation: nil, sourceVoice: nil, sourceRoute: nil,
                                              light: nil, savedCamera: nil)

    private init(card: CharacterCard?, sourceCharacter: SourceStudioCharacterReference?,
                 sourceExpression: SourceStudioExpressionState?, sourceKinematics: SourceStudioKinematicState?,
                 sourceAnimation: SourceStudioAnimationState?, sourceVoice: SourceStudioVoiceState?,
                 sourceRoute: SourceStudioRouteState?, light: SceneLight?, savedCamera: OrbitCamera?) {
        self.card = card; self.sourceCharacter = sourceCharacter; self.sourceExpression = sourceExpression
        self.sourceKinematics = sourceKinematics; self.sourceAnimation = sourceAnimation; self.sourceVoice = sourceVoice
        self.sourceRoute = sourceRoute; self.light = light; self.savedCamera = savedCamera
    }

    /// A new box with `other`'s fields, for the value about to write one.
    convenience init(copying other: StudioObjectColdFields) {
        self.init(card: other.card, sourceCharacter: other.sourceCharacter, sourceExpression: other.sourceExpression,
                  sourceKinematics: other.sourceKinematics, sourceAnimation: other.sourceAnimation,
                  sourceVoice: other.sourceVoice, sourceRoute: other.sourceRoute,
                  light: other.light, savedCamera: other.savedCamera)
    }

    /// The box for these fields: the shared `empty` box when every one is nil
    /// or default, otherwise a new one.
    static func holding(card: CharacterCard?, sourceCharacter: SourceStudioCharacterReference?,
                        sourceExpression: SourceStudioExpressionState?, sourceKinematics: SourceStudioKinematicState?,
                        sourceAnimation: SourceStudioAnimationState?, sourceVoice: SourceStudioVoiceState?,
                        sourceRoute: SourceStudioRouteState?, light: SceneLight?,
                        savedCamera: OrbitCamera?) -> StudioObjectColdFields {
        if card == nil, sourceCharacter == nil, sourceExpression == nil, sourceKinematics == nil, sourceAnimation == nil,
           sourceVoice == nil, sourceRoute == nil, light == nil, savedCamera == nil {
            return empty
        }
        return StudioObjectColdFields(card: card, sourceCharacter: sourceCharacter, sourceExpression: sourceExpression,
                                      sourceKinematics: sourceKinematics, sourceAnimation: sourceAnimation,
                                      sourceVoice: sourceVoice, sourceRoute: sourceRoute,
                                      light: light, savedCamera: savedCamera)
    }

    /// Whether every field is nil or default, as in `empty`.
    var holdsDefaults: Bool {
        card == nil && sourceCharacter == nil && sourceExpression == nil && sourceKinematics == nil && sourceAnimation == nil
            && sourceVoice == nil && sourceRoute == nil && light == nil && savedCamera == nil
    }
}

extension StudioObjectColdFields: Equatable {
    /// The same box, or boxes whose fields are all equal. An object and its
    /// undo steps share a box until a boxed field is written, so the identity
    /// test skips comparing the card in nearly every comparison.
    static func == (lhs: StudioObjectColdFields, rhs: StudioObjectColdFields) -> Bool {
        lhs === rhs || (lhs.card == rhs.card && lhs.sourceCharacter == rhs.sourceCharacter
            && lhs.sourceExpression == rhs.sourceExpression && lhs.sourceKinematics == rhs.sourceKinematics
            && lhs.sourceAnimation == rhs.sourceAnimation && lhs.sourceVoice == rhs.sourceVoice
            && lhs.sourceRoute == rhs.sourceRoute && lhs.light == rhs.light
            && lhs.savedCamera == rhs.savedCamera)
    }
}

extension StudioObject {
    /// The keys the synthesized conformance of the unboxed struct used: every
    /// stored field, boxed ones included, in declaration order. Saved scene
    /// cards keep them flat; the box itself has no key.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, kind, parent, visible, locked, transform, card, sourceCharacter, sourcePreviewName,
             sourcePreviewKind, sourceAttachmentPoint, sourceFKRotations, sourceIKOverrides, sourceFaceValues,
             sourceBodyValues, sourceColorEdits, sourceOutfit, sourceClothesState, sourceShowAccessory,
             sourceShoesType, sourceExpression, sourceKinematics, sourceAnimation, sourceVoice, sourceRoute,
             poseDelta, ikTargets, animationPreset, clothingVisible, accessoriesVisible, handGestureL,
             handGestureR, itemID, assetFile, sourceObjectKey, sourceDuplicateOf, sourceRecordKind, tint,
             emissive, light, fov, savedCamera
    }

    /// Decodes as the synthesized conformance did: in key order, a
    /// non-optional field's key is required (its default is not used), an
    /// optional one's may be missing, and unknown keys are ignored. An object
    /// whose boxed fields are all nil or default gets the shared empty box.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(StudioObjectKind.self, forKey: .kind)
        parent = try c.decodeIfPresent(UUID.self, forKey: .parent)
        visible = try c.decode(Bool.self, forKey: .visible)
        locked = try c.decode(Bool.self, forKey: .locked)
        transform = try c.decode(StudioTransform.self, forKey: .transform)
        let card = try c.decodeIfPresent(CharacterCard.self, forKey: .card)
        let sourceCharacter = try c.decodeIfPresent(SourceStudioCharacterReference.self, forKey: .sourceCharacter)
        sourcePreviewName = try c.decodeIfPresent(String.self, forKey: .sourcePreviewName)
        sourcePreviewKind = try c.decodeIfPresent(StudioObjectKind.self, forKey: .sourcePreviewKind)
        sourceAttachmentPoint = try c.decodeIfPresent(Int32.self, forKey: .sourceAttachmentPoint)
        sourceFKRotations = try c.decodeIfPresent([Int: Float3].self, forKey: .sourceFKRotations)
        sourceIKOverrides = try c.decodeIfPresent([Int32: SourceStudioIKEdit].self, forKey: .sourceIKOverrides)
        sourceFaceValues = try c.decodeIfPresent([Float].self, forKey: .sourceFaceValues)
        sourceBodyValues = try c.decodeIfPresent([Float].self, forKey: .sourceBodyValues)
        sourceColorEdits = try c.decodeIfPresent([String: Float4].self, forKey: .sourceColorEdits)
        sourceOutfit = try c.decodeIfPresent(Int.self, forKey: .sourceOutfit)
        sourceClothesState = try c.decodeIfPresent([UInt8].self, forKey: .sourceClothesState)
        sourceShowAccessory = try c.decodeIfPresent([Bool].self, forKey: .sourceShowAccessory)
        sourceShoesType = try c.decodeIfPresent(Int.self, forKey: .sourceShoesType)
        let sourceExpression = try c.decodeIfPresent(SourceStudioExpressionState.self, forKey: .sourceExpression)
        let sourceKinematics = try c.decodeIfPresent(SourceStudioKinematicState.self, forKey: .sourceKinematics)
        let sourceAnimation = try c.decodeIfPresent(SourceStudioAnimationState.self, forKey: .sourceAnimation)
        let sourceVoice = try c.decodeIfPresent(SourceStudioVoiceState.self, forKey: .sourceVoice)
        let sourceRoute = try c.decodeIfPresent(SourceStudioRouteState.self, forKey: .sourceRoute)
        poseDelta = try c.decode(PoseDelta.self, forKey: .poseDelta)
        ikTargets = try c.decode([IKChain: IKTarget].self, forKey: .ikTargets)
        animationPreset = try c.decodeIfPresent(String.self, forKey: .animationPreset)
        clothingVisible = try c.decode(Bool.self, forKey: .clothingVisible)
        accessoriesVisible = try c.decode(Bool.self, forKey: .accessoriesVisible)
        handGestureL = try c.decode(Int.self, forKey: .handGestureL)
        handGestureR = try c.decode(Int.self, forKey: .handGestureR)
        itemID = try c.decodeIfPresent(String.self, forKey: .itemID)
        assetFile = try c.decodeIfPresent(String.self, forKey: .assetFile)
        sourceObjectKey = try c.decodeIfPresent(Int32.self, forKey: .sourceObjectKey)
        sourceDuplicateOf = try c.decodeIfPresent(Int32.self, forKey: .sourceDuplicateOf)
        sourceRecordKind = try c.decodeIfPresent(KoikatsuObjectKind.self, forKey: .sourceRecordKind)
        tint = try c.decodeIfPresent(RGB.self, forKey: .tint)
        emissive = try c.decode(Float.self, forKey: .emissive)
        let light = try c.decodeIfPresent(SceneLight.self, forKey: .light)
        fov = try c.decode(Float.self, forKey: .fov)
        let savedCamera = try c.decodeIfPresent(OrbitCamera.self, forKey: .savedCamera)
        cold = .holding(card: card, sourceCharacter: sourceCharacter, sourceExpression: sourceExpression,
                        sourceKinematics: sourceKinematics, sourceAnimation: sourceAnimation, sourceVoice: sourceVoice,
                        sourceRoute: sourceRoute, light: light, savedCamera: savedCamera)
    }

    /// Encodes as the synthesized conformance did: every key in
    /// `CodingKeys` order, a nil optional writes no key, and a dictionary
    /// keyed by `StableEncodingKey` takes the key-ordered overload (#394).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encode(visible, forKey: .visible)
        try c.encode(locked, forKey: .locked)
        try c.encode(transform, forKey: .transform)
        try c.encodeIfPresent(cold.card, forKey: .card)
        try c.encodeIfPresent(cold.sourceCharacter, forKey: .sourceCharacter)
        try c.encodeIfPresent(sourcePreviewName, forKey: .sourcePreviewName)
        try c.encodeIfPresent(sourcePreviewKind, forKey: .sourcePreviewKind)
        try c.encodeIfPresent(sourceAttachmentPoint, forKey: .sourceAttachmentPoint)
        try c.encodeIfPresent(sourceFKRotations, forKey: .sourceFKRotations)
        try c.encodeIfPresent(sourceIKOverrides, forKey: .sourceIKOverrides)
        try c.encodeIfPresent(sourceFaceValues, forKey: .sourceFaceValues)
        try c.encodeIfPresent(sourceBodyValues, forKey: .sourceBodyValues)
        try c.encodeIfPresent(sourceColorEdits, forKey: .sourceColorEdits)
        try c.encodeIfPresent(sourceOutfit, forKey: .sourceOutfit)
        try c.encodeIfPresent(sourceClothesState, forKey: .sourceClothesState)
        try c.encodeIfPresent(sourceShowAccessory, forKey: .sourceShowAccessory)
        try c.encodeIfPresent(sourceShoesType, forKey: .sourceShoesType)
        try c.encodeIfPresent(cold.sourceExpression, forKey: .sourceExpression)
        try c.encodeIfPresent(cold.sourceKinematics, forKey: .sourceKinematics)
        try c.encodeIfPresent(cold.sourceAnimation, forKey: .sourceAnimation)
        try c.encodeIfPresent(cold.sourceVoice, forKey: .sourceVoice)
        try c.encodeIfPresent(cold.sourceRoute, forKey: .sourceRoute)
        try c.encode(poseDelta, forKey: .poseDelta)
        try c.encode(ikTargets, forKey: .ikTargets)
        try c.encodeIfPresent(animationPreset, forKey: .animationPreset)
        try c.encode(clothingVisible, forKey: .clothingVisible)
        try c.encode(accessoriesVisible, forKey: .accessoriesVisible)
        try c.encode(handGestureL, forKey: .handGestureL)
        try c.encode(handGestureR, forKey: .handGestureR)
        try c.encodeIfPresent(itemID, forKey: .itemID)
        try c.encodeIfPresent(assetFile, forKey: .assetFile)
        try c.encodeIfPresent(sourceObjectKey, forKey: .sourceObjectKey)
        try c.encodeIfPresent(sourceDuplicateOf, forKey: .sourceDuplicateOf)
        try c.encodeIfPresent(sourceRecordKind, forKey: .sourceRecordKind)
        try c.encodeIfPresent(tint, forKey: .tint)
        try c.encode(emissive, forKey: .emissive)
        try c.encodeIfPresent(cold.light, forKey: .light)
        try c.encode(fov, forKey: .fov)
        try c.encodeIfPresent(cold.savedCamera, forKey: .savedCamera)
    }
}

/// A studio scene: object tree, camera slots, character light and effects. Saved as a PNG "scene card".
public struct StudioDocument: Codable, Sendable, Equatable {
    public var version = 1
    public var name = "Untitled scene"
    public var objects: [StudioObject] = []
    public var camera = OrbitCamera()
    public var cameraSlots: [OrbitCamera?] = Array(repeating: nil, count: 10)
    public var mainLight = MainLight()
    public var effects = SceneEffects()
    public var captureWidth = 1920
    public var captureHeight = 1080
    public var timeline = Timeline()
    public var sourceSceneFile: String?
    public var sourceSceneSHA256: String?
    public var sourceVoiceCatalogFile: String?
    public var sourcePreviewDiagnostics: [String]?
    public var sourcePluginState: SourceStudioPluginState?
    public var sourceNativePlugins: [SourceNativePluginReference]?
    /// Exact plugin library revisions (P-T02). It resolves against its recorded
    /// generation, never a newer one. Documents saved before this field existed
    /// decode it as nil; their profile state and adapter references are unchanged.
    public var sourcePluginLibrary: SourcePluginLibrarySelection?
    public var sourcePluginLibraryConfiguration: SourceStudioPluginConfiguration?
    /// The libraries and file digests this document's paths were saved against
    /// (A-T02). `resolvingResources(current:catalog:)` relocates the paths of a
    /// moved library from it and reports every reference it cannot verify.
    /// Documents saved before this field existed, and documents with no file
    /// reference, decode it as nil; see `StudioResourceReferences.swift`.
    public var resourceBinding: ResourceBinding?

    public init() {
        camera.target = Float3(0, 0.9, 0); camera.distance = 3.4; camera.yaw = 0.35; camera.pitch = 0.12
    }

    public func object(_ id: UUID) -> StudioObject? { objects.first { $0.id == id } }
    public func index(of id: UUID) -> Int? { objects.firstIndex { $0.id == id } }
    public func children(of id: UUID?) -> [StudioObject] { objects.filter { $0.parent == id } }

    /// Validate imported documents before publishing them to the editor/renderer.
    public func validateHierarchy() throws {
        var byID: [UUID: StudioObject] = [:]
        for object in objects {
            guard byID.updateValue(object, forKey: object.id) == nil else { throw StudioHierarchyError.duplicate(object.id) }
        }
        for object in objects {
            if let parent = object.parent, byID[parent] == nil { throw StudioHierarchyError.missingParent(parent) }
        }
        var complete = Set<UUID>()
        for object in objects where !complete.contains(object.id) {
            var path = Set<UUID>()
            var current: UUID? = object.id
            while let id = current, !complete.contains(id) {
                guard path.insert(id).inserted else { throw StudioHierarchyError.cycle(id) }
                current = byID[id]?.parent
            }
            complete.formUnion(path)
        }
    }

    /// Validate decoded cameras (scene camera, saved slots and camera objects)
    /// before they drive the viewport; see `OrbitCamera.validate()`.
    public func validateCameras() throws {
        try camera.validate()
        for slot in cameraSlots { try slot?.validate() }
        for object in objects { try object.savedCamera?.validate() }
    }

    /// World matrix including parents.
    public func worldMatrix(of id: UUID) -> float4x4 {
        guard let o = object(id) else { return matrix_identity_float4x4 }
        var m = o.transform.matrix
        var p = o.parent
        var visited: Set<UUID> = [id]
        while let pid = p, visited.insert(pid).inserted, let po = object(pid) {
            m = po.transform.matrix * m; p = po.parent
        }
        return m
    }

    public func isVisible(_ id: UUID) -> Bool {
        var cur: UUID? = id
        var visited = Set<UUID>()
        while let c = cur {
            guard visited.insert(c).inserted, let o = object(c), o.visible else { return false }
            cur = o.parent
        }
        return true
    }

    public func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        var cur = object(id)?.parent
        var visited = Set<UUID>()
        while let c = cur, visited.insert(c).inserted { if c == ancestor { return true }; cur = object(c)?.parent }
        return false
    }

    public mutating func remove(_ id: UUID) {
        let victims = objects.filter { $0.id == id || isDescendant($0.id, of: id) }.map(\.id)
        objects.removeAll { victims.contains($0.id) }
        timeline.keyframes.removeAll { victims.contains($0.object) }
    }

    /// Depth-first ordered list of (object, depth) for the tree view.
    public func flattened() -> [(object: StudioObject, depth: Int)] {
        var out: [(StudioObject, Int)] = []
        let children = Dictionary(grouping: objects, by: \.parent)
        var stack = (children[nil] ?? []).reversed().map { ($0, 0) }
        var visited = Set<UUID>()
        while let (object, depth) = stack.popLast() {
            guard visited.insert(object.id).inserted else { continue }
            out.append((object, depth))
            stack.append(contentsOf: (children[object.id] ?? []).reversed().map { ($0, depth + 1) })
        }
        return out
    }

    /// `flattened()` as indices into `objects` (#387 round 3): the same
    /// rows in the same order, with the same rule for a repeated id (its
    /// first row in that order) and for objects in a cycle or under a
    /// missing parent (left out), without copying any object.
    public func flattenedIndices() -> [(index: Int, depth: Int)] {
        var children: [UUID?: [Int]] = [:]
        for index in objects.indices { children[objects[index].parent, default: []].append(index) }
        var out: [(index: Int, depth: Int)] = []
        out.reserveCapacity(objects.count)
        var stack = (children[nil] ?? []).reversed().map { ($0, 0) }
        var visited = Set<UUID>(minimumCapacity: objects.count)
        while let (index, depth) = stack.popLast() {
            guard visited.insert(objects[index].id).inserted else { continue }
            out.append((index, depth))
            stack.append(contentsOf: (children[objects[index].id] ?? []).reversed().map { ($0, depth + 1) })
        }
        return out
    }
}

extension StudioDocument {
    /// One object list's answers to `object(_:)`, `index(of:)`, `isVisible(_:)`
    /// and `isDescendant(_:of:)` by hash instead of a scan of `objects` per
    /// call, so a walk over every object (the Studio frame rebuild, the
    /// inspector's parent list) is O(N · depth) instead of O(N² · depth)
    /// (#383). The answers are the document functions' own, including for a
    /// repeated id (its first object, as `objects.first` finds it), a missing
    /// parent and a cycle (the same visited-set walks).
    ///
    /// It holds a copy of the list it was built from and is never updated:
    /// build it where the list is fixed for the walk and drop it after, so
    /// there is nothing to invalidate when the document changes.
    public struct Lookup: Sendable {
        public let objects: [StudioObject]
        private let indexByID: [UUID: Int]

        public init(_ objects: [StudioObject]) {
            self.objects = objects
            var indexByID = [UUID: Int](minimumCapacity: objects.count)
            // Backwards, so the first object of a repeated id is the one kept.
            for index in objects.indices.reversed() { indexByID[objects[index].id] = index }
            self.indexByID = indexByID
        }

        public func index(of id: UUID) -> Int? { indexByID[id] }
        public func object(_ id: UUID) -> StudioObject? { indexByID[id].map { objects[$0] } }

        /// Every listed object's first index and its parent's, for a walk
        /// by index that neither hashes ids nor copies objects (#387 round
        /// 3). `first[i]` is `index(of: objects[i].id)`; `parent[i]` is
        /// `index(of:)` of `objects[i]`'s parent id, `noParent` for a root
        /// and `missingParent` for a parent id the list lacks. Like the
        /// lookup, it answers for the list it was built from only.
        public struct Indices: Sendable, Equatable {
            public static let noParent = -1, missingParent = -2
            public let first: [Int]
            public let parent: [Int]
            public init(first: [Int], parent: [Int]) {
                self.first = first
                self.parent = parent
            }
        }

        /// `Indices` for this list, in one pass of 2N hash lookups.
        public func indices() -> Indices {
            var first: [Int] = [], parent: [Int] = []
            first.reserveCapacity(objects.count)
            parent.reserveCapacity(objects.count)
            for index in objects.indices {
                first.append(indexByID[objects[index].id] ?? index) // every listed id is there
                parent.append(objects[index].parent.map { indexByID[$0] ?? Indices.missingParent } ?? Indices.noParent)
            }
            return Indices(first: first, parent: parent)
        }

        /// `StudioDocument.isVisible(_:)`.
        public func isVisible(_ id: UUID) -> Bool {
            var cur: UUID? = id
            var visited = Set<UUID>()
            while let c = cur {
                guard visited.insert(c).inserted, let i = indexByID[c], objects[i].visible else { return false }
                cur = objects[i].parent
            }
            return true
        }

        /// `isVisible(_:)` for every object of the list in one O(N) pass,
        /// for a walk that tests them all (#387). Entry `i` is
        /// `isVisible(objects[i].id)`: every object of a repeated id gets
        /// its first object's answer, and objects in or below a cycle or
        /// under a missing parent get `false`, as there.
        public func visibleFlags() -> [Bool] { visibleFlags(indices()) }

        /// `visibleFlags()` from this list's `indices()`, already built for
        /// the walk that also needs them.
        public func visibleFlags(_ indices: Indices) -> [Bool] {
            precondition(indices.first.count == objects.count, "Studio lookup indices built from another object list")
            // Per first index: 0 not reached, 1 on the current chain,
            // 2 visible, 3 hidden. Every object on one chain shares its end's
            // answer: each one walked on was visible itself.
            var state = [UInt8](repeating: 0, count: objects.count)
            var chain: [Int] = []
            for start in objects.indices {
                let index = indices.first[start]
                guard state[index] == 0 else { continue }
                chain.removeAll(keepingCapacity: true)
                var current = index
                var answer: UInt8 = 3
                while true {
                    if state[current] >= 2 { answer = state[current]; break }
                    if state[current] == 1 { break } // a cycle
                    state[current] = 1
                    chain.append(current)
                    guard objects[current].visible else { break }
                    let next = indices.parent[current]
                    if next == Indices.noParent { answer = 2; break }
                    if next == Indices.missingParent { break }
                    current = next
                }
                for i in chain { state[i] = answer }
            }
            return indices.first.map { state[$0] == 2 }
        }

        /// `StudioDocument.isDescendant(_:of:)`.
        public func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
            var cur = indexByID[id].flatMap { objects[$0].parent }
            var visited = Set<UUID>()
            while let c = cur, visited.insert(c).inserted {
                if c == ancestor { return true }
                cur = indexByID[c].flatMap { objects[$0].parent }
            }
            return false
        }
    }
}

public enum StudioHierarchyError: Error, CustomStringConvertible {
    case duplicate(UUID), missingParent(UUID), cycle(UUID)
    public var description: String {
        switch self {
        case .duplicate(let id): return "Scene contains duplicate object ID \(id)."
        case .missingParent(let id): return "Scene references missing parent \(id)."
        case .cycle(let id): return "Scene hierarchy contains a cycle at \(id)."
        }
    }
}
