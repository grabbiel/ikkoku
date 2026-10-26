import Foundation
import Testing
import Metal
import simd
import Renderer
@testable import Studio

// ST-T05a: scenes saved by CharaStudio versions 0.0.5 through 1.0.4.1, read
// with CharaStudio 1.0.4.2's load branches and saved as 1.0.4.2. Each test
// builds the same scene twice: in the older layout, and as 1.0.4.2 with the
// values the older version's load gives the fields it lacks. The upgrade of
// the first must be the second, byte for byte.

/// One scene in the layout `version` saves (KoikatsuSceneLayout).
private struct LegacyScene {
    let version: KoikatsuSceneVersion
    var out = SceneDocumentBytes(data: OriginalCardFixture.png)

    init(_ text: String) { version = KoikatsuSceneVersion(parsing: text)!; out.s(text) }
    func has(_ a: Int32, _ b: Int32, _ c: Int32 = -1, _ d: Int32 = -1) -> Bool { version >= KoikatsuSceneVersion(a, b, c, d) }

    struct Pattern { var key: Int32 = 0, path = "", clamp = true, uv = KoikatsuLegacyDefaults.patternUVJSON, rotation: Float = 0 }
    mutating func pattern(_ p: Pattern) { out.i(p.key); out.s(p.path); out.b(p.clamp); out.s(p.uv); out.f(p.rotation) }

    /// OIItemInfo.Save's fields as OIItemInfo.Load reads them at this version
    /// (OIItemInfo.cs:117-174): emission from 0.0.7, the panel from 0.0.6,
    /// enableDynamicBone from 1.0.1.
    mutating func item(_ key: Int32, emission: (String, Float, Float) = (#"{"r":0.5,"g":0.25,"b":1.0,"a":1.0}"#, 0.75, 0.5),
                       panel: Pattern = Pattern(key: 2, path: "panel.png", clamp: false, uv: #"{"x":0.5,"y":0.0,"z":1.0,"w":2.0}"#, rotation: 30),
                       dynamicBone: Bool = false, children: Int32 = 0) {
        out.header(1, key); out.i(0); out.i(0); out.i(0); out.f(1)
        for index in 0..<8 { out.s("{\"r\":\(index),\"g\":0.25,\"b\":0.5,\"a\":1}") }
        for key: Int32 in [3, 4, 5] { pattern(Pattern(key: key)) }
        out.f(0.75); out.s(#"{"r":0.1,"g":0.2,"b":0.3,"a":1}"#); out.f(0.7)
        if has(0, 0, 7) { out.s(emission.0); out.f(emission.1); out.f(emission.2) }
        if has(0, 0, 6) { pattern(panel) }
        out.b(false); out.i(1); out.s("joint"); out.bone(70 + key)
        if has(1, 0, 1) { out.b(dynamicBone) }
        out.f(0.375); out.i(children)
        for index in 0..<children { out.folder(90 + index) }
    }

    /// SceneDocumentBytes.character with this version's expression count
    /// (OICharInfo.cs:299: 4 below 0.0.9).
    mutating func character(expressions: [Bool], eyes: Data, neck: Data = Data([0, 1, 255])) {
        precondition(expressions.count == (has(0, 0, 9) ? 8 : 4))
        out.header(0, 10); out.i(1); out.data += OriginalCardFixture.card()
        out.i(2); out.i(1); out.bone(101); out.i(2); out.bone(102)
        out.i(1); out.i(3); out.bone(103)
        out.i(1); out.i(7); out.i(1); out.folder(11)
        for v: Int32 in [1, 2, 3, 4, 5, 6] { out.i(v) }
        out.f(0.125); out.data += Data([0, 1, 2, 3, 4]); out.f(0.25); out.b(true); out.bone(104)
        out.b(false); for v in [true, false, true, false, true] { out.b(v) }
        out.b(true); for v in [false, true, false, false, false, false, false] { out.b(v) }
        for v in expressions { out.b(v) }
        out.f(1.25); out.f(0.375); out.b(true); out.b(false)
        out.i(1); for v: Int32 in [4, 5, 6, 2] { out.i(v) }
        out.b(false); out.f(1.125); out.b(false); out.color(); out.f(0.25); out.f(0.75)
        for value in [neck, eyes] { out.i(Int32(value.count)); out.data += value }
        out.f(0.625); out.i(1); out.i(7); out.i(1); out.i(1); out.i(8); out.i(0)
    }

    struct Point {
        var key: Int32, discarded = false, connection: Int32 = 1, aid: Int32? = nil, aidInitialized = true, link = false
    }
    /// OIRouteInfo/OIRoutePointInfo as their Load reads them
    /// (OIRouteInfo.cs:73-99, OIRoutePointInfo.cs:57-81).
    mutating func route(_ key: Int32, points: [Point], flags: [Bool] = [true, false, false], orient: Int32 = 2,
                        color: String = #"{"r":1.0,"g":0.5,"b":0.0,"a":1.0}"#) {
        out.header(4, key); out.s("Route"); out.i(1); out.folder(key + 1); out.i(Int32(points.count))
        for point in points {
            out.bone(point.key); out.f(2.5); out.i(21)
            if version == KoikatsuSceneVersion(1, 0, 3) { out.b(point.discarded) }
            if has(1, 0, 4, 1) {
                out.i(point.connection); out.bone(point.aid ?? point.key + 1); out.b(point.aidInitialized)
            }
            if has(1, 0, 4, 2) { out.b(point.link) }
        }
        if has(1, 0, 3) { for flag in flags { out.b(flag) } }
        if has(1, 0, 4) { out.i(orient) }
        if has(1, 0, 4, 1) { out.s(color) }
    }

    /// The settings (SceneDocumentBytes.tail) with every camera record in
    /// `cameraVersion`; version 1 holds one float in place of the distance
    /// (CameraControl.cs:62-82), and a version-2 copy of it the zero
    /// distance its load keeps.
    mutating func tail(cameraVersion: Int32 = 2, zeroDistance: Bool = false) {
        var rest = SceneDocumentBytes(); rest.tail()
        var tail = rest.data
        let one = SceneDocumentBytes.cameraBytes, start = tail.range(of: one + one)!.lowerBound
        var cameras = Data()
        for _ in 0..<11 {
            var c = SceneDocumentBytes()
            c.i(cameraVersion)
            let values: [Float] = cameraVersion == 1 ? [1, 2, 3, 10, 20, 30, 7.5, 23]
                : zeroDistance ? [1, 2, 3, 10, 20, 30, 0, 0, 0, 23] : [1, 2, 3, 10, 20, 30, 0, 0, -5, 23]
            for v in values { c.f(v) }
            cameras += c.data
        }
        tail.replaceSubrange(start..<(start + 11 * one.count), with: cameras)
        out.data += tail
    }
    mutating func roots(_ count: Int32) { out.i(count) }
    /// A KKEx trailer like SceneDocumentBytes.scene's.
    mutating func trailer() {
        let payload = OriginalCardFixture.pack(OriginalCardFixture.map([("example.scene", .array([.integer(7)]))]))
        out.s("KKEx"); out.i(3); out.i(Int32(payload.count)); out.data += payload
    }
    var data: Data { out.data }
}

private extension SceneDocumentBytes {
    /// One SceneDocumentBytes.camera() record.
    static var cameraBytes: Data { var c = SceneDocumentBytes(); c.camera(); return c.data }
}

private func decode(_ scene: LegacyScene) throws -> KoikatsuSceneDocument { try KoikatsuSceneReader.decodeDocument(scene.data) }

// MARK: - Versions

@Test func legacySceneVersionsCompareAsSystemVersion() {
    func v(_ text: String) -> KoikatsuSceneVersion? { KoikatsuSceneVersion(parsing: text) }
    #expect(v("1.0.4.2") == .current && v("0.0.5") == .oldestSupported)
    #expect(v("1.0") == KoikatsuSceneVersion(1, 0) && v("1.0")!.description == "1.0")
    // A missing build or revision is -1: 1.0.4 < 1.0.4.1, and 1.0.3.0 is
    // neither 1.0.3 nor below it.
    #expect(v("1.0.4")! < v("1.0.4.1")! && v("1.0.4.1")! < v("1.0.4.2")! && v("1.0")! < v("1.0.1")!)
    #expect(v("1.0.3.0")! != v("1.0.3")! && v("1.0.3.0")! > v("1.0.3")!)
    // Only canonical text: 2-4 parts of ASCII digits without leading zeros.
    for text in ["", "1", "1.0.4.2.0", "1..4", "1.0.", ".1.0", "01.0.4", "1.0.04", " 1.0.4", "1.0.4 ", "+1.0.4", "-1.0.4",
                 "1.0.x", "1.0.٤", "１.0.4", "1.0.4.2147483648"] {
        #expect(v(text) == nil, "\(text) parsed")
    }
    for text in ["0.0.5", "0.0.7", "0.1", "1.0", "1.0.3.0", "1.0.4.1", "1.0.4.2"] { #expect(KoikatsuSceneVersion.refusal(text) == nil, "\(text)") }
    #expect(KoikatsuSceneVersion.refusal("1.0.4.3")?.contains("newer than 1.0.4.2") == true)
    #expect(KoikatsuSceneVersion.refusal("2.0")?.contains("newer") == true)
    #expect(KoikatsuSceneVersion.refusal("0.0.4.9")?.contains("predates 0.0.5") == true)
    #expect(KoikatsuSceneVersion.refusal("0.0")?.contains("predates") == true)
    #expect(KoikatsuSceneVersion.refusal("1.0.04")?.contains("not a canonical version") == true)
}

@Test func legacySceneLayoutsTakeCharaStudioBranches() {
    func layout(_ text: String) -> KoikatsuSceneLayout { KoikatsuSceneLayout(KoikatsuSceneVersion(parsing: text)!) }
    let first = layout("0.0.5")
    #expect(first.legacy && !first.itemPanel && !first.itemEmission && !first.itemDynamicBone && first.characterExpressions == 4 && !first.eyeAngles)
    #expect(layout("0.0.6").itemPanel && !layout("0.0.6").itemEmission && layout("0.0.7").itemEmission && !layout("0.0.7").eyeAngles)
    #expect(layout("0.0.8").eyeAngles && layout("0.0.8").characterExpressions == 4 && layout("0.0.9").characterExpressions == 8)
    #expect(!layout("1.0.0").itemDynamicBone && layout("1.0.1").itemDynamicBone && !layout("1.0").itemDynamicBone && layout("1.0").itemPanel)
    #expect(!layout("1.0.2").routeFlags && layout("1.0.3").routeFlags && layout("1.0.3").pointDiscardedFlag && !layout("1.0.3").routeOrientation)
    #expect(layout("1.0.3.0").routeFlags && !layout("1.0.3.0").pointDiscardedFlag && !layout("1.0.3.1").pointDiscardedFlag)
    #expect(layout("1.0.4").routeOrientation && !layout("1.0.4").routeColor && !layout("1.0.4").pointAid)
    #expect(layout("1.0.4.1").routeColor && layout("1.0.4.1").pointAid && !layout("1.0.4.1").pointLink && layout("1.0.4.1").legacy)
    #expect(layout("1.0.4.2") == .current && !KoikatsuSceneLayout.current.legacy && KoikatsuSceneLayout.current.pointLink)
}

@Test func legacySceneUnknownVersionsAreRefusedByName() {
    for text in ["1.0.4.3", "1.0.5", "0.0.4", "0.0", "1.0.04", "1.0.4.2 ", "x"] {
        var scene = SceneDocumentBytes(data: OriginalCardFixture.png); scene.s(text); scene.i(0); scene.tail()
        #expect(throws: KoikatsuReadError.unsupportedVersion(text)) { try KoikatsuSceneReader.decodeDocument(scene.data) }
        let message = KoikatsuReadError.unsupportedVersion(text).errorDescription ?? ""
        #expect(message.contains("'\(text)'") || message.contains(text), "\(message)")
        #expect(message.contains("0.0.5") && message.contains("1.0.4.2"), "\(message)")
    }
}

// MARK: - Items and cameras

@Test func legacyItemsTakeConstructorDefaultsAndUpgradeToCharaStudioBytes() throws {
    let white = (KoikatsuLegacyDefaults.whiteJSON, Float(0), Float(0))
    let panel = LegacyScene.Pattern()
    for text in ["0.0.5", "0.0.6", "0.0.7", "1.0.0", "1.0.1", "1.0"] {
        var legacy = LegacyScene(text), expected = LegacyScene("1.0.4.2")
        let cameraVersion: Int32 = text == "0.0.5" ? 1 : 2
        legacy.roots(2); legacy.out.i(4); legacy.item(4, children: 1); legacy.out.i(6); legacy.item(6)
        legacy.tail(cameraVersion: cameraVersion); legacy.trailer()
        let has = (emission: legacy.has(0, 0, 7), panel: legacy.has(0, 0, 6), dynamicBone: legacy.has(1, 0, 1))
        expected.roots(2)
        for (key, children): (Int32, Int32) in [(4, 1), (6, 0)] {
            expected.out.i(key)
            if has.emission && has.panel { expected.item(key, dynamicBone: has.dynamicBone ? false : true, children: children) }
            else if has.panel { expected.item(key, emission: white, dynamicBone: true, children: children) }
            else { expected.item(key, emission: white, panel: panel, dynamicBone: true, children: children) }
        }
        expected.tail(cameraVersion: 2, zeroDistance: cameraVersion == 1); expected.trailer()

        let document = try decode(legacy)
        #expect(document.isLegacy && document.snapshot.version == text && document.dataVersion == KoikatsuSceneVersion(parsing: text)!)
        let item = try #require(document.snapshot.roots.first?.item)
        #expect(item.emissionColor == (has.emission ? SIMD4(0.5, 0.25, 1, 1) : KoikatsuLegacyDefaults.white))
        #expect(item.emissionPower == (has.emission ? 0.75 : 0) && item.lightCancel == (has.emission ? 0.5 : 0))
        #expect(item.panel == (has.panel ? KoikatsuPatternRecord(key: 2, filePath: "panel.png", clamp: false, uv: SIMD4(0.5, 0, 1, 2), rotation: 30)
                               : KoikatsuLegacyDefaults.pattern))
        #expect(item.enableDynamicBone == !has.dynamicBone)
        #expect(item.bones["joint"]?.sourceKey == 74 && item.animationNormalizedTime == 0.375)
        #expect(document.snapshot.roots.first?.children.first?.sourceKey == 90)
        // CameraData.Load keeps a version-1 record's distance at zero.
        #expect(document.settings.camera.distance == (cameraVersion == 1 ? .zero : SIMD3(0, 0, -5)) && document.settings.camera.fieldOfView == 23)
        #expect(document.settings.cameraSlots.count == 10 && document.settings.cameraSlots.allSatisfy { $0 == document.settings.camera })

        let upgraded = try document.upgraded()
        #expect(upgraded.preservedData == expected.data, "\(text): the upgrade is not CharaStudio's 1.0.4.2 save")
        #expect(!upgraded.isLegacy && upgraded.trailingData == document.trailingData && upgraded.settings == document.settings)
        #expect(upgraded.snapshot.roots == document.snapshot.roots.map { $0 }, "\(text): the upgrade reads back as another scene")
        // An export of the legacy scene, even an empty one, is that upgrade.
        #expect(try document.editedData(SourceSceneEdits()) == expected.data)
    }
}

@Test func legacyCameraVersionOneIsOnlyReadInLegacyScenes() throws {
    var current = LegacyScene("1.0.4.2"); current.roots(0); current.tail(cameraVersion: 1)
    #expect(throws: KoikatsuReadError.unsupportedVersion("camera:1")) { try decode(current) }
    var legacy = LegacyScene("1.0.1"); legacy.roots(0); legacy.tail(cameraVersion: 3)
    #expect(throws: KoikatsuReadError.unsupportedVersion("camera:3")) { try decode(legacy) }
    #expect(KoikatsuReadError.unsupportedVersion("camera:1").errorDescription?.contains("older than 1.0.4.2, 1") == true)
}

// MARK: - Characters

@Test func legacyCharactersPadExpressionsAndEyeAngles() throws {
    func floats(_ values: [Float]) -> Data { values.reduce(into: Data()) { $0 += OriginalCardFixture.i32(Int32(bitPattern: $1.bitPattern)) } }
    let quaternions = floats([0, 0.6, 0, 0.8, 0.28, 0, 0, 0.96]), angles = quaternions + floats([1.5, -2.5, 3.5, -4.5])
    let four = [true, false, true, true], eight = [true, false, true, true, false, true, false, true]
    for (text, eyes) in [("0.0.5", quaternions), ("0.0.7", quaternions), ("0.0.8", angles), ("0.0.9", angles)] {
        var legacy = LegacyScene(text), expected = LegacyScene("1.0.4.2")
        let expressions = legacy.has(0, 0, 9) ? eight : four
        legacy.roots(1); legacy.out.i(10); legacy.character(expressions: expressions, eyes: eyes); legacy.tail()
        // OICharInfo.expression is bool[8]; the four not read stay false.
        let padded = expressions + Array(repeating: false, count: 8 - expressions.count)
        // EyeLookCalc.LoadAngle reads the angles from 0.0.8; before, they
        // keep their initial zero, which a 1.0.4.2 save writes after the two
        // quaternions (SaveAngle, EyeLookCalc.cs:379-397).
        let savedEyes = eyes.count == 32 ? eyes + Data(count: 16) : eyes
        expected.roots(1); expected.out.i(10); expected.character(expressions: padded, eyes: savedEyes); expected.tail()

        let document = try decode(legacy)
        let character = try #require(document.snapshot.roots.first?.character)
        #expect(character.expressions == padded && character.eyesData == eyes, "\(text)")
        let look = try SourceStudioEyeLookData(bytes: character.eyesData, sceneVersion: text)
        #expect((look.angleH == nil) == (KoikatsuSceneVersion(parsing: text)! < KoikatsuSceneVersion(0, 0, 8)), "\(text): eye angles")
        let upgraded = try document.upgraded()
        #expect(upgraded.preservedData == expected.data, "\(text): the upgrade is not CharaStudio's 1.0.4.2 save")
        let read = try SourceStudioEyeLookData(bytes: try #require(upgraded.snapshot.roots.first?.character).eyesData, sceneVersion: "1.0.4.2")
        #expect(read.fixAngles == look.fixAngles && read.angleH != nil)
        if eyes.count == 32 { #expect(read.angleH == [0, 0] && read.angleV == [0, 0]) }
    }
}

@Test func legacyEyeDataThatIsNotTwoQuaternionsIsRefused() throws {
    for count in [0, 31, 33, 48] {
        var legacy = LegacyScene("0.0.7")
        legacy.roots(1); legacy.out.i(10); legacy.character(expressions: [false, false, false, false], eyes: Data(count: count)); legacy.tail()
        let document = try decode(legacy)
        #expect(document.snapshot.roots.first?.character?.eyesData.count == count)
        var reason = ""
        do { _ = try document.upgraded(); Issue.record("\(count) eye bytes upgraded") } catch { reason = error.localizedDescription }
        #expect(reason.contains("CharaStudio 0.0.7 scene cannot be saved as 1.0.4.2") && reason.contains("eye"), "\(reason)")
        #expect(throws: SourceSceneTopologyError.self) { try document.editedData(SourceSceneEdits()) }
    }
}

@Test func legacyEyeAngleComparatorKeepsTheEarlierRule() throws {
    // The rule before ST-T05a: pad to three parts with zeros, then
    // `major > 0 || minor > 0 || build >= 8`.
    func earlier(_ text: String) -> Bool {
        var parts = text.split(separator: ".").map { Int($0)! }
        while parts.count < 3 { parts.append(0) }
        return parts[0] > 0 || parts[1] > 0 || parts[2] >= 8
    }
    var versions = ["1.0.4.2", "1.0.4.1", "1.0.3", "0.0.8", "0.0.7", "0.1", "1.0", "0.0"]
    for a in 0...1 { for b in 0...2 { for c in 0...12 { versions.append("\(a).\(b).\(c)"); versions.append("\(a).\(b).\(c).\(c % 3)") } } }
    for text in versions { #expect(try SourceStudioLookData.readsSavedEyeAngles(sceneVersion: text) == earlier(text), "\(text)") }
    // The earlier rule also took one-part and non-canonical text; neither is
    // a version SceneInfo.Load writes, and neither now reads.
    for text in ["1", "01.0", "1.0.4.2.0"] { #expect(throws: KoikatsuReadError.self) { try SourceStudioLookData.readsSavedEyeAngles(sceneVersion: text) } }
}

// MARK: - Routes

@Test func legacyRoutesWithSavedAidsGainTheLinkFlag() throws {
    var legacy = LegacyScene("1.0.4.1"), expected = LegacyScene("1.0.4.2")
    let points = [LegacyScene.Point(key: 51, aid: 52), .init(key: 53, connection: 0, aid: 54, aidInitialized: false)]
    legacy.roots(1); legacy.out.i(30); legacy.route(30, points: points); legacy.tail()
    expected.roots(1); expected.out.i(30); expected.route(30, points: points); expected.tail()
    let document = try decode(legacy)
    let route = try #require(document.snapshot.roots.first?.route)
    #expect(route.points.map(\.aidKey) == [52, 54] && route.points.map(\.linked) == [false, false] && route.points.map(\.connection) == [1, 0])
    #expect(route.active && !route.loop && !route.visibleLine && route.orientation == 2 && route.color == SIMD4(1, 0.5, 0, 1))
    #expect(try document.upgraded().preservedData == expected.data)
}

@Test func legacyRoutePointsWithoutAidsTakeCharaStudioDefaultsAndAreRefused() throws {
    for text in ["1.0.0", "1.0.3", "1.0.4"] {
        var legacy = LegacyScene(text)
        legacy.roots(1); legacy.out.i(30)
        legacy.route(30, points: [.init(key: 51, discarded: true), .init(key: 53)], flags: [true, false, false], orient: 1)
        legacy.tail()
        let document = try decode(legacy)
        let route = try #require(document.snapshot.roots.first?.route)
        // Absent fields keep OIRouteInfo's initializers (:25-33):
        // active false, loop and visibleLine true, orient None, Color.blue.
        #expect(route.active == legacy.has(1, 0, 3) && route.loop == !legacy.has(1, 0, 3) && route.visibleLine == !legacy.has(1, 0, 3), "\(text)")
        #expect(route.orientation == (legacy.has(1, 0, 4) ? 1 : 0) && route.color == KoikatsuLegacyDefaults.blue)
        // No saved aid: InitAid allocates one at load at the prefab's place.
        for point in route.points {
            #expect(point.aidKey == nil && point.aid == nil && point.aidTransform == KoikatsuLegacyDefaults.aidTransform)
            #expect(point.connection == 0 && !point.linked && !point.aidInitialized)
        }
        var reason = ""
        do { _ = try document.upgraded(); Issue.record("\(text) upgraded") } catch { reason = error.localizedDescription }
        #expect(reason == "This CharaStudio \(text) scene cannot be saved as 1.0.4.2: route 30 point 0 saves no aid, and CharaStudio allocates its key at load (AddObjectRoute.InitAid) from state this reader does not model")
        #expect(throws: SourceSceneTopologyError.self) { try document.editedData(SourceSceneEdits()) }
        #expect(throws: SourceSceneTopologyError.self) { try document.inserting([SourceSceneInsertion(.folder(name: "F"))]) }
    }
}

@Test func legacyRoutePointFlagIsReadOnlyByVersionOneZeroThree() throws {
    // OIRoutePointInfo.Load :62 reads one bool and drops it when the version
    // equals 1.0.3; its value changes nothing.
    func scene(_ text: String, _ discarded: Bool) -> LegacyScene {
        var scene = LegacyScene(text); scene.roots(1); scene.out.i(30)
        scene.route(30, points: [.init(key: 51, discarded: discarded), .init(key: 53, discarded: !discarded)]); scene.tail(); return scene
    }
    let a = try decode(scene("1.0.3", true)), b = try decode(scene("1.0.3", false))
    #expect(a.snapshot.roots == b.snapshot.roots && a.preservedData != b.preservedData)
    // Negative control: 1.0.3.0 is not 1.0.3, so the same bytes misread.
    var relabeled = scene("1.0.3", true).data
    let range = try #require(relabeled.range(of: OriginalCardFixture.string("1.0.3")))
    relabeled.replaceSubrange(range, with: OriginalCardFixture.string("1.0.3.0"))
    #expect(throws: (any Error).self) { try KoikatsuSceneReader.decodeDocument(relabeled) }
}

// MARK: - Controls and exports

@Test func legacyLayoutsAreTakenFromTheVersionString() throws {
    // The same bytes under another version string do not read: each branch
    // follows the string, not the bytes.
    var older = LegacyScene("0.0.6"); older.roots(1); older.out.i(4); older.item(4); older.tail()
    for (from, to) in [("0.0.6", "0.0.7"), ("0.0.6", "1.0.4.2")] {
        var data = older.data
        data.replaceSubrange(try #require(data.range(of: OriginalCardFixture.string(from))), with: OriginalCardFixture.string(to))
        #expect(throws: (any Error).self) { try KoikatsuSceneReader.decodeDocument(data) }
    }
    var current = LegacyScene("1.0.4.2"); current.roots(1); current.out.i(4); current.item(4); current.tail()
    var data = current.data
    data.replaceSubrange(try #require(data.range(of: OriginalCardFixture.string("1.0.4.2"))), with: OriginalCardFixture.string("0.0.6"))
    #expect(throws: (any Error).self) { try KoikatsuSceneReader.decodeDocument(data) }
}

@Test func currentScenesAreNotUpgradedAndExportByteIdentically() throws {
    var current = LegacyScene("1.0.4.2"); current.roots(1); current.out.i(4); current.item(4); current.tail(); current.trailer()
    let document = try decode(current)
    #expect(!document.isLegacy && document.dataVersion == .current)
    #expect(try document.upgraded().preservedData == current.data)
    #expect(try document.editedData(SourceSceneEdits()) == current.data)
    let full = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    #expect(try full.upgraded() == full)
    #expect(try full.editedData(SourceSceneEdits()) == SceneDocumentBytes.scene().data)
}

@Test func legacyExportsUpgradeOnceBeforeEveryWriter() throws {
    var legacy = LegacyScene("0.0.7"); legacy.roots(1); legacy.out.i(4); legacy.item(4); legacy.tail()
    let document = try decode(legacy), upgraded = try document.upgraded()
    // An insertion stages on the upgrade, and the staged scene is 1.0.4.2.
    let stage = try document.inserting([SourceSceneInsertion(.folder(name: "F"))])
    #expect(!stage.document.isLegacy && stage.document.snapshot.roots.count == 2)
    let staged = try upgraded.inserting([SourceSceneInsertion(.folder(name: "F"))])
    #expect(stage.document.preservedData == staged.document.preservedData)
    // A transform edit on the legacy scene is the edit on its upgrade.
    let edits = SourceSceneEdits(transforms: [.init(.object(4), transform: KoikatsuChangeAmount(position: SIMD3(1, 2, 3), rotationDegrees: .zero, scale: .one))])
    #expect(try document.editedData(edits) == upgraded.editedData(edits))
    // The byte writers themselves refuse a legacy document.
    #expect(throws: SourceSceneTopologyError.self) { try document.editedBody(edits) }
}

// MARK: - The corpus fixture

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_LEGACY_SCENE"]), "Requires IKKOKU_STUDIO_LEGACY_SCENE (a 0.0.7 scene)"))
func legacyCorpusSceneUpgradesAndReadsBack() throws {
    let url = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_STUDIO_LEGACY_SCENE"))
    let data = try Data(contentsOf: url)
    let document = try KoikatsuSceneReader.decodeDocument(data)
    #expect(document.snapshot.version == "0.0.7" && document.isLegacy)
    let upgraded = try document.upgraded()
    #expect(!upgraded.isLegacy && upgraded.trailingData == document.trailingData && upgraded.settings == document.settings)
    // The PNG is kept; the rest changes only where 0.0.7 lacks fields.
    var reader = try KoikatsuBinaryReader(data); try reader.skipPNG()
    #expect(upgraded.preservedData.prefix(reader.offset) == data.prefix(reader.offset))
    var characters = 0
    func visit(_ old: KoikatsuObjectRecord, _ new: KoikatsuObjectRecord) {
        #expect(old.kind == new.kind && old.sourceKey == new.sourceKey && old.transform == new.transform)
        if let a = old.character, let b = new.character {
            characters += 1
            #expect(b.expressions == a.expressions && a.expressions.count == 8 && a.expressions.suffix(4).allSatisfy { !$0 })
            #expect(a.eyesData.count == 32 && b.eyesData == a.eyesData + Data(count: 16) && b.cardData == a.cardData)
        }
        if let a = old.item, let b = new.item { #expect(a == b && a.enableDynamicBone) }
        for (x, y) in zip(old.children, new.children) { visit(x, y) }
    }
    for (a, b) in zip(document.snapshot.roots, upgraded.snapshot.roots) { visit(a, b) }
    #expect(characters > 0 && document.snapshot.roots.count == upgraded.snapshot.roots.count)
    #expect(try document.editedData(SourceSceneEdits()) == upgraded.preservedData)
}

/// Finding 2: CharaStudio's load gives a legacy character each catalog FK
/// bone its record lacks (AddObjectAssist.InitBone :38-46, InitHairBone
/// :103-113): a fresh key and `new ChangeAmount()`, saved with the scene.
/// Our pose binds the same catalog bones (SourceStudioPose.init), each
/// unsaved one at that zero rotation, so the FK view shows them and
/// previews edits of them; the record and its export keep the saved bones
/// only, and an export that edits an unsaved one is refused.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_LEGACY_SCENE", "IKKOKU_LEGACY_SCENE_PROBE", "IKKOKU_SOURCE_AVATAR",
                                                   "IKKOKU_SOURCE_MALE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT"]) && MTLCreateSystemDefaultDevice() != nil,
               "Requires IKKOKU_STUDIO_LEGACY_SCENE, IKKOKU_LEGACY_SCENE_PROBE, both source avatars, IKKOKU_STUDIO_POSE_CONTRACT and a Metal device"))
func legacyCharacterFKBindsTheBonesCharaStudioAdds() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_STUDIO_LEGACY_SCENE")
    let probe = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_LEGACY_SCENE_PROBE"))
    let female = try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR"), male = try SourceFixtureSupport.require("IKKOKU_SOURCE_MALE_AVATAR")
    let catalog = try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT")
    let data = try Data(contentsOf: URL(fileURLWithPath: path)), document = try KoikatsuSceneReader.decodeDocument(data)
    // The VM phase labels this record l007-<short hash>, as the file names it.
    let hash = try #require(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.split(separator: "-").last)
    let resave = try KoikatsuSceneReader.decodeDocument(Data(contentsOf: probe.appendingPathComponent("resave-l007-\(hash).png")))
    func characters(_ document: KoikatsuSceneDocument) -> [Int32: KoikatsuCharacterRecord] {
        var result: [Int32: KoikatsuCharacterRecord] = [:]
        func visit(_ record: KoikatsuObjectRecord) {
            if let character = record.character { result[record.sourceKey] = character }
            record.children.forEach(visit)
            for children in record.character?.accessoryChildren.values.map({ $0 }) ?? [] { children.forEach(visit) }
        }
        document.snapshot.roots.forEach(visit)
        return result
    }
    let ours = characters(document), theirs = characters(resave), upgraded = try document.upgraded()
    #expect(!ours.isEmpty && Set(ours.keys) == Set(theirs.keys))
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    var added = 0
    for (key, character) in ours.sorted(by: { $0.key < $1.key }) {
        let saved = try #require(theirs[key])
        let missing = Set(saved.bones.keys).subtracting(character.bones.keys)
        #expect(Set(character.bones.keys).isSubset(of: saved.bones.keys))
        #expect(missing.allSatisfy { saved.bones[$0]?.transform == KoikatsuChangeAmount(position: .zero, rotationDegrees: .zero, scale: .one) },
                "character \(key): CharaStudio saved an added FK bone with a change amount")
        let preview = try SourceStudioCharacterPreview(reference: SourceStudioCharacterReference(sceneFile: path,
            sceneSHA256: OriginalCardFixture.hash(data), rigFile: character.sex == 0 ? male : female, boneCatalogFile: catalog, objectKey: key),
            resources: resources)
        #expect(preview.record.bones.keys.sorted() == character.bones.keys.sorted())
        let unsaved = preview.controller.targets.filter { character.bones[Int32($0.bone.id)] == nil }
        #expect(Set(unsaved.map { Int32($0.bone.id) }) == missing, "character \(key): our pose binds other unsaved FK bones than CharaStudio adds")
        #expect(unsaved.allSatisfy { $0.hasGuide && $0.rotation == .zero })
        added += missing.count
        // An FK edit of an unsaved bone poses (nothing traps on it) ...
        let target = try #require(unsaved.first)
        let changed = try preview.editedPose(fkRotations: [target.bone.id: .init(11, 23, 7)])
        _ = try preview.preview.source.rig.evaluate(changed)
        // ... and its export is refused: the record has no such bone.
        let edits = SourceSceneEdits(transforms: [.init(.characterFK(object: key, bone: Int32(target.bone.id)),
                                                        transform: KoikatsuChangeAmount(position: .zero, rotationDegrees: .init(11, 23, 7), scale: .one))])
        for scene in [upgraded, document] {
            do { _ = try scene.editedData(edits); Issue.record("character \(key): an unsaved FK bone was exported") }
            catch { #expect(error.localizedDescription.contains("unavailable scene transform destination"), "\(error.localizedDescription)") }
        }
    }
    #expect(added == 10)
}

/// The user's corpus (opt-in: IKKOKU_SCENE_CORPUS, read in place; see
/// `koikatsuSceneCorpusDigest`): every legacy scene decodes and upgrades,
/// and the upgrade reads back as the same scene. Every decoded field is
/// equal, apart from the eye bytes below 0.0.8, which gain the four zero
/// angles. Prints one line per version: scenes, upgraded, refusals.
@Test(.enabled(if: !(ProcessInfo.processInfo.environment["IKKOKU_SCENE_CORPUS"] ?? "").isEmpty,
               "Opt-in corpus check: IKKOKU_SCENE_CORPUS names a folder of scenes"))
func legacyCorpusScenesUpgradeAndReadBack() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["IKKOKU_SCENE_CORPUS"]!)
    let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "png" && !$0.lastPathComponent.hasPrefix("._") }
    var counts: [String: (scenes: Int, upgraded: Int, refusals: [String])] = [:]
    for url in files {
        let data = try Data(contentsOf: url), id = String(OriginalCardFixture.hash(data).prefix(12))
        let document = try KoikatsuSceneReader.decodeDocument(data)
        guard document.isLegacy else { continue }
        let version = document.snapshot.version
        counts[version, default: (0, 0, [])].scenes += 1
        let upgraded: KoikatsuSceneDocument
        do { upgraded = try document.upgraded() } catch {
            counts[version]!.refusals.append("\(id): \(error.localizedDescription)"); continue
        }
        #expect(upgraded.preservedData.prefix(32) == data.prefix(32) && !upgraded.isLegacy)
        // The legacy decode with each pre-0.0.8 eye record as 1.0.4.2 saves it.
        var expected = corpusDescription(document.snapshot.roots)
        if document.dataVersion < KoikatsuSceneVersion(0, 0, 8) {
            var eyes: [Data] = []
            func visit(_ record: KoikatsuObjectRecord) {
                if let character = record.character { eyes.append(character.eyesData) }
                record.children.forEach(visit)
                for children in record.character?.accessoryChildren.values.map({ $0 }) ?? [] { children.forEach(visit) }
            }
            document.snapshot.roots.forEach(visit)
            for value in Set(eyes) {
                expected = expected.replacingOccurrences(of: "eyesData:" + corpusDescription(value),
                                                         with: "eyesData:" + corpusDescription(value + Data(count: 16)))
            }
        }
        #expect(corpusDescription(upgraded.snapshot.roots) == expected, "\(id): the upgrade reads back as another scene")
        #expect(corpusDescription(upgraded.settings) == corpusDescription(document.settings) && upgraded.trailingData == document.trailingData)
        #expect(try document.editedData(SourceSceneEdits()) == upgraded.preservedData)
        counts[version]!.upgraded += 1
    }
    for (version, count) in counts.sorted(by: { KoikatsuSceneVersion(parsing: $0.key)! < KoikatsuSceneVersion(parsing: $1.key)! }) {
        print("[legacy-corpus] \(version): \(count.scenes) scenes, \(count.upgraded) upgraded" + count.refusals.map { "; refused \($0)" }.joined())
    }
    #expect(!counts.isEmpty)
}
