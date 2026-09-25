import Foundation
import CryptoKit
import Testing
import Studio
import Scene
import CoreMath
import Assets

private struct SceneDocumentBytes {
    var data = Data()
    mutating func i(_ value: Int32) { data += OriginalCardFixture.i32(value) }
    mutating func f(_ value: Float) { i(Int32(bitPattern: value.bitPattern)) }
    mutating func b(_ value: Bool) { data.append(value ? 1 : 0) }
    mutating func s(_ value: String) { data += OriginalCardFixture.string(value) }
    mutating func color() { s(#"{"r":0.2,"g":0.4,"b":0.8,"a":1}"#) }
    mutating func transform() { for v: Float in [1, 2, 3, 0, 15, 0, 1, 1, 1] { f(v) } }
    mutating func header(_ kind: Int32, _ key: Int32) { i(kind); i(key); transform(); i(1); b(true) }
    mutating func bone(_ key: Int32) { i(key); transform() }
    mutating func folder(_ key: Int32) { header(3, key); s("Child"); i(0) }
    mutating func camera() { i(2); for v: Float in [1, 2, 3, 10, 20, 30, 0, 0, -5, 23] { f(v) } }
    mutating func character(_ card: Data, both: Bool) {
        header(0, 10); i(1); data += card
        i(2); i(1); bone(101); i(2); bone(102)
        i(1); i(3); bone(103)
        i(1); i(7); i(1); folder(11)
        for v: Int32 in [1, 2, 3, 4, 5, 6] { i(v) }
        f(0.125); data += Data([0, 1, 2, 3, 4]); f(0.25); b(true); bone(104)
        b(both); for v in [true, false, true, false, true] { b(v) }
        b(true); for v in [false, true, false, false, false, false, false] { b(v) }
        for v in [true, false, true, false, true, false, true, false] { b(v) }
        f(1.25); f(0.375); b(true); b(false)
        i(1); for v: Int32 in [4, 5, 6, 2] { i(v) }
        b(false); f(1.125); b(false); color(); f(0.25); f(0.75)
        for value in [Data([0, 1, 255]), Data([2, 3, 254])] { i(Int32(value.count)); data += value }
        f(0.625); i(1); i(7); i(1); i(1); i(8); i(0)
    }
    mutating func route() {
        header(4, 20); s("Route"); i(1); folder(21); i(2)
        for index: Int32 in 0..<2 {
            bone(201 + index); f(2.5 + Float(index)); i(21); i(index); bone(211 + index); b(true); b(index == 1)
        }
        b(false); b(true); b(true); i(2); color()
    }
    mutating func tail() {
        i(-1); transform(); i(0); b(true); i(3); f(0.2)
        b(true); color(); f(0.1); b(true); for v: Float in [0.4, 0.8, 0.6] { f(v) }
        b(false); f(0.95); f(0.6); b(true); b(false); color(); f(1); f(0)
        b(false); color(); color(); i(-1); b(true); b(false); b(true); f(0.3); color(); f(0.7); i(2); f(0.9)
        for _ in 0..<11 { camera() }
        for map in [false, true] { color(); f(1.5); f(45); f(180); b(true); if map { i(1) } }
        for no: Int32 in [12, 13] { i(2); i(no); b(false) }
        i(1); s("sample.wav"); b(false); s("background.png"); s("frame.png"); s("【KStudio】")
    }
    static func scene(card: Data = OriginalCardFixture.card(), both: Bool = false) -> (data: Data, objectEnd: Int, baseEnd: Int) {
        var value = Self(data: OriginalCardFixture.png)
        value.s("1.0.4.2"); value.i(2); value.i(10); value.character(card, both: both); value.i(20); value.route()
        let objectEnd = value.data.count; value.tail(); let baseEnd = value.data.count
        value.s("KKEx"); value.i(3)
        let payload = OriginalCardFixture.pack(OriginalCardFixture.map([("example.scene", .array([.integer(7), OriginalCardFixture.map([("opaque", .binary(Data([0, 255])))] )]))]))
        value.i(Int32(payload.count)); value.data += payload
        return (value.data, objectEnd, baseEnd)
    }
}

@Test func KoikatsuSceneDocumentReadsCharacterRoutesAllTailAndExactBytes() throws {
    let input = SceneDocumentBytes.scene()
    let document = try KoikatsuSceneReader.decodeDocument(input.data)
    #expect(document.snapshot.objectSectionEndOffset == input.objectEnd)
    #expect(document.baseSceneEndOffset == input.baseEnd && document.preservedData == input.data)
    let record = try #require(document.snapshot.roots[0].character)
    #expect(record.sex == 1 && record.kinematicMode == 1)
    #expect(record.bones.count == 2 && record.bones[1]?.sourceKey == 101)
    #expect(record.ikTargets[3]?.sourceKey == 103 && record.lookAtTarget.sourceKey == 104)
    #expect(record.accessoryChildren[7]?.first?.sourceKey == 11)
    #expect(record.animation.group == 2 && record.animation.category == 3 && record.animation.no == 4)
    #expect(record.handPatterns == [5, 6] && record.animationSpeed == 1.25 && record.animationPattern == 0.375)
    #expect(record.fluidLevels == Data([0, 1, 2, 3, 4]) && record.mouthOpen == 0.25 && record.lipSync)
    #expect(record.voices[0].group == 4 && record.voiceRepeat == 2)
    #expect(record.animationOptionParameters == SIMD2<Float>(0.25, 0.75) && record.animationNormalizedTime == 0.625)
    #expect(record.neckData == Data([0, 1, 255]) && record.eyesData == Data([2, 3, 254]))
    #expect(record.accessoryGroupStates == [7: 1] && record.accessoryStates == [8: 0])
    #expect(try record.card().customization().faceValues.count == 52)
    let route = try #require(document.snapshot.roots[1].route)
    #expect(route.points.count == 2 && route.points[1].speed == 3.5 && route.points[1].connection == 1)
    #expect(route.points[1].aid.sourceKey == 212 && route.points[1].linked && route.loop)
    #expect(document.snapshot.roots[1].children.first?.sourceKey == 21)
    let settings = document.settings
    #expect(settings.map == -1 && settings.colorCorrection == 3 && settings.ramp == 2)
    #expect(settings.floatSettings["bloomThreshold"] == 0.6 && settings.boolSettings["faceShadow"] == true)
    #expect(settings.cameraSlots.count == 10 && settings.camera.fieldOfView == 23)
    #expect(settings.mapLight.type == 1 && settings.characterLight.rotation == SIMD2<Float>(45, 180))
    #expect(settings.backgroundMusic.catalogNumber == 12 && settings.environmentSound.catalogNumber == 13)
    #expect(settings.outsideSound.fileName == "sample.wav" && settings.background == "background.png" && settings.frame == "frame.png")
    let extensions = document.extensions()
    #expect(extensions.version == 3 && extensions.payload != nil)
    let plugins = try #require(extensions.payload).stringKeyedMap()
    #expect(plugins["example.scene"]?.arrayValue?.first?.integerValue == 7)
}

@Test func KoikatsuSceneEmbeddedLegacyDataStopsAtFollowingBoneDictionary() throws {
    let trailer = OriginalCardFixture.legacy(OriginalCardFixture.map([("legacy.example", OriginalCardFixture.plugin(5))]))
    let bytes = OriginalCardFixture.card(trailer: trailer)
    let record = try #require(KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene(card: bytes).data).snapshot.roots[0].character)
    #expect(record.cardData == bytes && record.bones.count == 2)
    #expect(try record.card().extensions().format == "trailer-v2")
}

@Test func KoikatsuSceneDocumentRejectsTruncatedTailAndMalformedEmbeddedCard() throws {
    let input = SceneDocumentBytes.scene()
    // Every tail byte is required, including the original writer marker.
    for length in input.objectEnd..<input.baseEnd {
        #expect(throws: (any Error).self) { try KoikatsuSceneReader.decodeDocument(input.data.prefix(length)) }
    }
    let bad = SceneDocumentBytes.scene(card: OriginalCardFixture.card(product: 101))
    #expect(throws: (any Error).self) { try KoikatsuSceneReader.decodeDocument(bad.data) }
    #expect(try KoikatsuSceneReader.decode(input.data.prefix(input.objectEnd)).roots.count == 2)
    var sliced = Data([9, 8, 7]); sliced.append(input.data)
    #expect(try KoikatsuSceneReader.decodeDocument(sliced.dropFirst(3)).preservedData == input.data)
}

@Test func KoikatsuSceneUnknownAndCorruptExtensionsRemainPreserved() throws {
    let input = SceneDocumentBytes.scene()
    for trailer in [Data([0, 255, 3]), OriginalCardFixture.string("KKEx") + OriginalCardFixture.i32(3) + OriginalCardFixture.i32(99) + Data([0x81])] {
        let data = input.data.prefix(input.baseEnd) + trailer
        let document = try KoikatsuSceneReader.decodeDocument(data)
        #expect(document.trailingData == trailer && document.preservedData == data)
        #expect(document.extensions().payload == nil && !document.extensions().diagnostics.isEmpty)
    }
}

@Test func KoikatsuSceneCharacterRestoresSavedFKAndOriginalDualModePrecedence() throws {
    let rig = try RigDefinition(nodes: [
        .init(name: "root", sourceID: "root", parent: nil),
        .init(name: "head", sourceID: "head", parent: 0), .init(name: "neck", sourceID: "neck", parent: 0),
    ], skins: [])
    let catalog: [SourceStudioPose.Bone] = [.init(id: 1, name: "head", group: 10, level: 0), .init(id: 2, name: "neck", group: 10, level: 0)]
    for both in [false, true] {
        let record = try #require(KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene(both: both).data).snapshot.roots[0].character)
        let result = try record.makePose(rig: rig, catalog: catalog, baseline: rig.restPose, characterRoot: 0)
        #expect(result.controller.enableIK == both && result.controller.enableFK == !both)
        #expect(result.controller.activeFK == record.activeFK && result.controller.activeIK == record.activeIK)
        if both { #expect(result.pose.localMatrices == rig.restPose.localMatrices) }
        else {
            let expected = Transform.rotation(UnityCoordinates.eulerDegrees(SIMD3<Float>(0, 15, 0)))
            for c in 0..<4 { for r in 0..<4 { #expect(abs(result.pose.localMatrices[1][c][r] - expected[c][r]) < 0.00001) } }
        }
        #expect(!result.deferredEffects.isEmpty && !result.diagnostics.isEmpty)
    }
}

@Test func KoikatsuSceneMatchesIndependentFullFixtureWhenSupplied() throws {
    guard let directory = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_SCENE_FIXTURES"] else { return }
    for name in ["current", "legacy-card", "both-modes"] {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("synthetic-\(name)")
        let data = try Data(contentsOf: url.appendingPathExtension("png"))
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathExtension("json"))) as? [String: Any])
        let document = try KoikatsuSceneReader.decodeDocument(data)
        #expect(document.snapshot.objectSectionEndOffset == report["objectSectionEndOffset"] as? Int)
        #expect(document.baseSceneEndOffset == report["baseSceneEndOffset"] as? Int)
        #expect(document.trailingData.count == report["trailingBytes"] as? Int)
        let roots = try #require(report["roots"] as? [String: [String: Any]])
        let expected = try #require(roots["10"]), card = try #require(expected["card"] as? [String: Any])
        let character = try #require(document.snapshot.roots[0].character)
        #expect(OriginalCardFixture.hash(character.cardData) == card["sha256"] as? String)
        #expect(character.enableIK == expected["enableIK"] as? Bool)
        #expect(character.activeFK == expected["activeFK"] as? [Bool])
        #expect(character.animationNormalizedTime == 0.625 && character.bones[1]?.transform.rotationDegrees == SIMD3<Float>(0, 15, 0))
    }
}

@Test func KoikatsuSceneReadsExplicitOriginalSceneDirectoryWhenSupplied() throws {
    guard let directory = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_ORIGINAL_SCENES"] else { return }
    let base = URL(fileURLWithPath: directory)
    let files = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]))
    var count = 0, characters = 0, kinds: [Int32: Int] = [:]
    func visit(_ object: KoikatsuObjectRecord) throws {
        kinds[object.kind.rawValue, default: 0] += 1
        for child in object.children { try visit(child) }
        if let character = object.character {
            characters += 1
            _ = try character.card()
            for children in character.accessoryChildren.values { for child in children { try visit(child) } }
        }
    }
    for case let file as URL in files where file.pathExtension.lowercased() == "png" {
        kinds = [:]; let previousCharacterCount = characters
        let input = try Data(contentsOf: file)
        let document = try KoikatsuSceneReader.decodeDocument(input)
        #expect(document.preservedData == input && document.settings.cameraSlots.count == 10)
        for object in document.snapshot.roots { try visit(object) }
        let extended = document.extensions()
        let plugins = (try? extended.payload?.stringKeyedMap()) ?? [:]
        let report: [String: Any] = ["file": file.lastPathComponent, "sha256": OriginalCardFixture.hash(input),
            "bytes": input.count, "roots": document.snapshot.roots.count,
            "kindCounts": Dictionary(uniqueKeysWithValues: kinds.map { (String($0.key), $0.value) }),
            "characters": characters - previousCharacterCount,
            "objectSectionEndOffset": document.snapshot.objectSectionEndOffset,
            "baseSceneEndOffset": document.baseSceneEndOffset, "trailingBytes": document.trailingData.count,
            "extendedSaveVersion": extended.version as Any? ?? NSNull(),
            "plugins": plugins.keys.sorted().map { id in
                ["id": id, "version": plugins[id]?.arrayValue?.first?.integerValue as Any? ?? NSNull(),
                 "recordSlots": plugins[id]?.arrayValue?.count as Any? ?? NSNull()] as [String: Any]
            }, "extensionDiagnostics": extended.diagnostics, "preservedExactBytes": document.preservedData == input]
        print("ORIGINAL_STUDIO_REPORT " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        count += 1
    }
    #expect(count > 0)
    print("Original Studio framing validation: \(count) files, \(characters) embedded characters; thumbnails were not rendered.")
}
