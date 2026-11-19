import Testing
import Foundation
import CoreMath
import Scene
@testable import Character
@testable import Studio

// #409 review aid, removed before merge together with `LegacyStudioObject`:
// the boxed `StudioObject`'s hand-written Codable against the synthesized
// conformance of the struct it replaces, byte for byte.

/// `StudioObject`'s stored properties before #409 (b4834fe1), in their order,
/// with the synthesized `Codable` and `Equatable`. Importing `Character`
/// brings the key-ordered dictionary overloads (#394) the original picked up.
struct LegacyStudioObject: Codable, Equatable {
    var id = UUID()
    var name: String
    var kind: StudioObjectKind
    var parent: UUID?
    var visible = true
    var locked = false
    var transform = StudioTransform()
    var card: CharacterCard?
    var sourceCharacter: SourceStudioCharacterReference?
    var sourcePreviewName: String?
    var sourcePreviewKind: StudioObjectKind?
    var sourceAttachmentPoint: Int32?
    var sourceFKRotations: [Int: Float3]?
    var sourceIKOverrides: [Int32: SourceStudioIKEdit]?
    var sourceFaceValues: [Float]?
    var sourceBodyValues: [Float]?
    var sourceColorEdits: [String: Float4]?
    var sourceOutfit: Int?
    var sourceClothesState: [UInt8]?
    var sourceShowAccessory: [Bool]?
    var sourceShoesType: Int?
    var sourceExpression: SourceStudioExpressionState?
    var sourceKinematics: SourceStudioKinematicState?
    var sourceAnimation: SourceStudioAnimationState?
    var sourceVoice: SourceStudioVoiceState?
    var sourceRoute: SourceStudioRouteState?
    var poseDelta = PoseDelta()
    var ikTargets: [IKChain: IKTarget] = [:]
    var animationPreset: String?
    var clothingVisible = true
    var accessoriesVisible = true
    var handGestureL = 0
    var handGestureR = 0
    var itemID: String?
    var assetFile: String?
    var sourceObjectKey: Int32?
    var sourceDuplicateOf: Int32?
    var sourceRecordKind: KoikatsuObjectKind?
    var tint: RGB?
    var emissive: Float = 0
    var light: SceneLight?
    var fov: Float = 30
    var savedCamera: OrbitCamera?

    /// The same object, field by field through the accessors (not Codable).
    init(_ o: StudioObject) {
        id = o.id; name = o.name; kind = o.kind; parent = o.parent; visible = o.visible; locked = o.locked
        transform = o.transform; card = o.card; sourceCharacter = o.sourceCharacter
        sourcePreviewName = o.sourcePreviewName; sourcePreviewKind = o.sourcePreviewKind
        sourceAttachmentPoint = o.sourceAttachmentPoint; sourceFKRotations = o.sourceFKRotations
        sourceIKOverrides = o.sourceIKOverrides; sourceFaceValues = o.sourceFaceValues; sourceBodyValues = o.sourceBodyValues
        sourceColorEdits = o.sourceColorEdits; sourceOutfit = o.sourceOutfit; sourceClothesState = o.sourceClothesState
        sourceShowAccessory = o.sourceShowAccessory; sourceShoesType = o.sourceShoesType
        sourceExpression = o.sourceExpression; sourceKinematics = o.sourceKinematics; sourceAnimation = o.sourceAnimation
        sourceVoice = o.sourceVoice; sourceRoute = o.sourceRoute; poseDelta = o.poseDelta; ikTargets = o.ikTargets
        animationPreset = o.animationPreset; clothingVisible = o.clothingVisible; accessoriesVisible = o.accessoriesVisible
        handGestureL = o.handGestureL; handGestureR = o.handGestureR; itemID = o.itemID; assetFile = o.assetFile
        sourceObjectKey = o.sourceObjectKey; sourceDuplicateOf = o.sourceDuplicateOf; sourceRecordKind = o.sourceRecordKind
        tint = o.tint; emissive = o.emissive; light = o.light; fov = o.fov; savedCamera = o.savedCamera
    }
}

private func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys] // CardIO.encode's setting
    return try encoder.encode(value)
}

/// Every boxed and unboxed field set to a value other than its default.
private func everyField() throws -> StudioObject {
    var o = StudioObject(name: "Every field", kind: .character)
    o.id = UUID(uuidString: "4C0D0409-0000-4000-8000-000000000001")!
    o.parent = UUID(uuidString: "4C0D0409-0000-4000-8000-000000000002")!
    o.visible = false; o.locked = true
    o.transform.position = Float3(1, 2, 3); o.transform.rotationOverride = Float4(0, 0.2, 0, 0.9797959)
    var card = CharacterCard(); card.id = UUID(uuidString: "4C0D0409-0000-4000-8000-000000000003")!; card.profile.name = "Legacy"
    o.card = card
    o.sourceCharacter = SourceStudioCharacterReference(
        sceneFile: "/synthetic/scene.png", sceneSHA256: String(repeating: "b", count: 64), rigFile: "/synthetic/rig.json",
        boneCatalogFile: "/synthetic/bones.json", objectKey: 9, makerLibraryFile: "/synthetic/maker.json")
    o.sourcePreviewName = "Preview"; o.sourcePreviewKind = .item; o.sourceAttachmentPoint = 4
    o.sourceFKRotations = [3: Float3(1, 2, 3), 1: Float3(4, 5, 6)]
    o.sourceIKOverrides = [5: SourceStudioIKEdit(position: Float3(0, 1, 0)), 2: SourceStudioIKEdit(position: .zero, rotationDegrees: Float3(0, 90, 0))]
    o.sourceFaceValues = [0.25, 0.5]; o.sourceBodyValues = [0.75]; o.sourceColorEdits = ["skin": Float4(1, 0.5, 0.5, 1), "hair": Float4(0, 0, 0, 1)]
    o.sourceOutfit = 3; o.sourceClothesState = [0, 1, 2, 3, 0, 1, 2, 3, 0]; o.sourceShowAccessory = (0..<20).map { $0 % 2 == 0 }
    o.sourceShoesType = 1
    o.sourceExpression = SourceStudioExpressionState(
        eyebrowPattern: 4, eyesPattern: 5, mouthPattern: 6, eyesOpen: 0.75, blink: true, mouthOpen: 0.5, lipSync: false,
        eyesLookPattern: 2, neckLookPattern: 3, tears: 2, cheek: 0.25, heldEyesOpenRate: 1)
    o.sourceKinematics = SourceStudioKinematicState(enableFK: false, enableIK: true, activeFK: (0..<7).map { $0 % 2 == 1 },
                                                    activeIK: (0..<5).map { $0 % 2 == 0 })
    let animation = #"{"group":4,"category":5,"no":6,"speed":0.5,"pattern":0.75,"normalizedTime":0.125,"forceLoop":false,"optionParameters":[0.5,0.75]}"#
    o.sourceAnimation = try JSONDecoder().decode(SourceStudioAnimationState.self, from: Data(animation.utf8))
    o.sourceVoice = SourceStudioVoiceState(playlist: [.init(group: 1, category: 2, no: 3), .init(group: 0, category: 0, no: 1)], repeatMode: 2)
    o.sourceRoute = SourceStudioRouteState(points: [], loop: false, visibleLine: true, orientation: 2, color: SIMD4<Float>(0, 1, 0, 1))
    o.poseDelta = PoseDelta(rotations: ["cf_j_neck": Float3(10, 0, 0)], translations: ["cf_j_hips": Float3(0, 0.1, 0)],
                            scales: ["cf_j_head": Float3(1.1, 1.1, 1.1)], skinScales: ["cf_s_waist": Float3(0.9, 1, 0.9)])
    o.ikTargets = [.footR: IKTarget(enabled: true, position: Float3(0, 0.1, 0), pole: Float3(0, 0.5, 1)), .handL: IKTarget(enabled: true)]
    o.animationPreset = "wave"; o.clothingVisible = false; o.accessoriesVisible = false; o.handGestureL = 2; o.handGestureR = 3
    o.itemID = "item_1"; o.assetFile = "/synthetic/item.glb"; o.sourceObjectKey = 21; o.sourceDuplicateOf = 22
    o.sourceRecordKind = .route; o.tint = RGB(0.25, 0.5, 0.75); o.emissive = 0.5
    var light = SceneLight(kind: .point); light.intensity = 0.3; light.castsShadow = false
    o.light = light; o.fov = 45
    var camera = OrbitCamera(); camera.distance = 5; camera.orientationOverride = Float4(0, 0, 0, 1)
    o.savedCamera = camera
    return o
}

/// Objects as the editor makes them, plus one with every field set.
private func corpus() throws -> [StudioObject] {
    var character = StudioObject.character(CharacterCard())
    character.id = UUID(uuidString: "4C0D0409-0000-4000-8000-000000000010")!
    var camera = StudioObject(name: "Camera", kind: .camera)
    camera.savedCamera = OrbitCamera()
    return [try everyField(), StudioObject(name: "Prop", kind: .item), StudioObject(name: "Folder", kind: .folder),
            StudioObject.item(id: "item_2", name: "Item"), StudioObject.light(.spot), StudioObject.light(.directional),
            character, camera]
}

@Test func boxedObjectsEncodeTheLegacyBytesAndKeyOrder() throws {
    for object in try corpus() {
        let legacy = LegacyStudioObject(object)
        #expect(try sortedJSON(object) == sortedJSON(legacy), "\(object.name)")
        #expect(try recordedKeys(object) == recordedKeys(legacy), "\(object.name)")
    }
    let objects = try corpus()
    #expect(try sortedJSON(objects) == sortedJSON(objects.map(LegacyStudioObject.init)))
}

@Test func boxedAndLegacyObjectsDecodeEachOthersBytes() throws {
    for object in try corpus() {
        let legacy = LegacyStudioObject(object)
        let fromLegacy = try JSONDecoder().decode(StudioObject.self, from: sortedJSON(legacy))
        #expect(fromLegacy == object, "\(object.name)")
        #expect(LegacyStudioObject(fromLegacy) == legacy, "\(object.name)")
        let fromBoxed = try JSONDecoder().decode(LegacyStudioObject.self, from: sortedJSON(object))
        #expect(fromBoxed == legacy, "\(object.name)")
    }
}

/// The outcome of one decode, comparable across the two types.
private enum Outcome: Equatable {
    case decoded(LegacyStudioObject)
    case keyNotFound(String), valueNotFound(String), typeMismatch(String), dataCorrupted(String), other
    init(_ body: () throws -> LegacyStudioObject) {
        do { self = .decoded(try body()) } catch let error as DecodingError {
            func path(_ context: DecodingError.Context) -> String { context.codingPath.map(\.stringValue).joined(separator: ".") }
            switch error {
            case .keyNotFound(let key, let context): self = .keyNotFound(path(context) + "/" + key.stringValue)
            case .valueNotFound(_, let context): self = .valueNotFound(path(context))
            case .typeMismatch(_, let context): self = .typeMismatch(path(context))
            case .dataCorrupted(let context): self = .dataCorrupted(path(context))
            @unknown default: self = .other
            }
        } catch { self = .other }
    }
}

/// Every key missing, null or of the wrong type, and unknown keys: both
/// decoders accept the same inputs into the same values and reject the rest
/// at the same key.
@Test func boxedAndLegacyDecodersAgreeOnEditedInputs() throws {
    let base = try #require(try JSONSerialization.jsonObject(with: sortedJSON(everyField())) as? [String: Any])
    var variants: [(String, [String: Any])] = [("unchanged", base)]
    for key in base.keys.sorted() {
        var missing = base; missing[key] = nil; variants.append(("missing \(key)", missing))
        var null = base; null[key] = NSNull(); variants.append(("null \(key)", null))
        var wrong = base; wrong[key] = ["unexpected": true]; variants.append(("wrong type \(key)", wrong))
    }
    var unknown = base; unknown["futureField"] = [1, 2]; unknown["cold"] = ["card": NSNull()]
    variants.append(("unknown keys", unknown))
    for (label, json) in variants {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let boxed = Outcome { LegacyStudioObject(try JSONDecoder().decode(StudioObject.self, from: data)) }
        let legacy = Outcome { try JSONDecoder().decode(LegacyStudioObject.self, from: data) }
        #expect(boxed == legacy, "\(label)")
    }
}

/// Saved scene cards (IKKOKU_STUDIO_OBJECT_CODING_SCENES: files or folders of
/// Ikkoku scene cards, separated by ":"). For each card the boxed type reads
/// and writes the objects exactly as the legacy type does, and re-saving the
/// document writes the payload's own bytes when an Ikkoku build of the same
/// format saved it (reported per card).
@Test(.enabled(if: ProcessInfo.processInfo.environment["IKKOKU_STUDIO_OBJECT_CODING_SCENES"] != nil))
func savedSceneCardsKeepTheirBytes() throws {
    struct LegacyObjects: Decodable { var objects: [LegacyStudioObject] }
    let roots = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_OBJECT_CODING_SCENES", default: ""].split(separator: ":").map(String.init)
    var files: [URL] = []
    for root in roots {
        let url = URL(fileURLWithPath: root)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &directory) else { Issue.record("missing \(root)"); continue }
        if directory.boolValue {
            files += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.path < $1.path }
        } else {
            files.append(url)
        }
    }
    var cards = 0, objects = 0, identical = 0
    for file in files {
        guard let payload = CardIO.extractChunk(from: try Data(contentsOf: file), keyword: CardIO.sceneKeyword) else { continue }
        cards += 1
        let document = try JSONDecoder().decode(StudioDocument.self, from: payload)
        let legacy = try JSONDecoder().decode(LegacyObjects.self, from: payload).objects
        objects += legacy.count
        #expect(document.objects.map(LegacyStudioObject.init) == legacy, "\(file.lastPathComponent)")
        #expect(try sortedJSON(document.objects) == sortedJSON(legacy), "\(file.lastPathComponent)")
        let resaved = try sortedJSON(document) == payload
        if resaved { identical += 1 }
        print("[409-coding] \(file.lastPathComponent): \(legacy.count) objects, re-save \(resaved ? "identical" : "differs")")
    }
    print("[409-coding] \(cards) scene cards, \(objects) objects, \(identical) re-saved identical")
    #expect(cards > 0)
}
