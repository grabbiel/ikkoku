import Foundation
import Testing
import Studio

// Synthetic records following the observed BinaryWriter call order. No game assets or
// decompiled implementation are included in these fixtures.
struct StudioBytes {
    var data = Data()
    mutating func i32(_ value: Int32) {
        let bits = UInt32(bitPattern: value)
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
    }
    mutating func f32(_ value: Float) { i32(Int32(bitPattern: value.bitPattern)) }
    mutating func bool(_ value: Bool) { data.append(value ? 1 : 0) }
    mutating func string(_ value: String) {
        let bytes = Array(value.utf8)
        var length = bytes.count
        while length >= 128 { data.append(UInt8(length & 127) | 128); length >>= 7 }
        data.append(UInt8(length)); data.append(contentsOf: bytes)
    }
    mutating func transform() {
        for value: Float in [1, 2, 3, 20, -40, 60, 1, 2, 0.5] { f32(value) }
    }
    mutating func header(kind: Int32, key: Int32) {
        i32(kind); i32(key); transform(); i32(1); bool(true)
    }
    mutating func pattern(_ key: Int32) {
        i32(key); string("纹理/地板.png"); bool(true)
        string(#"{"x":0.25,"y":0.5,"z":2,"w":3}"#); f32(45)
    }
    mutating func item(bone: String = "chair_joint") {
        header(kind: 1, key: 13)
        i32(7); i32(8); i32(9); f32(1.25)
        for index in 0..<8 { string("{\"r\":\(index),\"g\":0.25,\"b\":0.5,\"a\":1}") }
        for key: Int32 in [3, 4, 5] { pattern(key) }
        f32(0.75); string(#"{"r":0.1,"g":0.2,"b":0.3,"a":1}"#); f32(0.7)
        string(#"{"r":0.4,"g":0.5,"b":0.6,"a":1}"#); f32(2); f32(0.25)
        pattern(-1); bool(true)
        i32(1); string(bone); i32(77); transform() // OIBoneInfo omits kind/tree/visible.
        bool(false); f32(0.375)
        i32(0) // children
    }
    mutating func light() {
        header(kind: 2, key: 14); i32(22)
        for value: Float in [0.2, 0.4, 0.8, 1, 1.5, 10, 45] { f32(value) }
        bool(true); bool(false); bool(true)
    }
    static var png: Data {
        // A complete, valid 1×1 transparent PNG; reader only needs its container framing.
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
    static func prefix(version: String = "1.0.4.2", rootCount: Int32 = 1) -> StudioBytes {
        var bytes = StudioBytes(data: png)
        bytes.string(version); bytes.i32(rootCount)
        return bytes
    }
    static func scene() -> Data {
        var bytes = prefix()
        bytes.i32(40) // root dictionary key is separate from the object's key.
        bytes.header(kind: 3, key: 10)
        bytes.string(String(repeating: "庭", count: 60)) // 180 UTF-8 bytes, two-byte length.
        bytes.i32(3)
        bytes.header(kind: 5, key: 12); bytes.string("Camera A"); bytes.bool(true)
        bytes.item(); bytes.light()
        return bytes.data
    }
}

@Test func KoikatsuDecodesRealBinaryWriterLayoutAndNestedObjects() throws {
    var data = StudioBytes.scene()
    let objectEnd = data.count
    data.append(contentsOf: [0xAA, 0xBB, 0xCC]) // Unparsed scene settings and extension data.
    let scene = try KoikatsuSceneReader.decode(data)
    #expect(scene.version == "1.0.4.2")
    #expect(scene.objectSectionEndOffset == objectEnd)
    let root = try #require(scene.roots.first)
    #expect(root.rootDictionaryKey == 40)
    #expect(root.sourceKey == 10)
    #expect(root.kind == .folder)
    #expect(root.name == String(repeating: "庭", count: 60))
    #expect(root.transform.position == SIMD3<Float>(1, 2, 3))
    #expect(root.transform.rotationDegrees == SIMD3<Float>(20, -40, 60))
    #expect(root.transform.scale == SIMD3<Float>(1, 2, 0.5))
    #expect(root.treeState == 1 && root.visible)
    #expect(root.children.map(\.kind) == [.camera, .item, .light])
    #expect(root.children.allSatisfy { $0.rootDictionaryKey == nil })
    #expect(root.children[0].cameraActive == true)
    #expect(root.children[0].name == "Camera A")
    let item = try #require(root.children[1].item)
    #expect(item.group == 7 && item.category == 8 && item.no == 9)
    #expect(item.colors.count == 8 && item.colors[7].x == 7)
    #expect(item.patterns[2].key == 5)
    #expect(item.patterns[2].uv == SIMD4<Float>(0.25, 0.5, 2, 3))
    #expect(item.patterns[2].filePath == "纹理/地板.png")
    #expect(item.alpha == 0.75 && item.lineWidth == 0.7)
    #expect(item.emissionPower == 2 && item.lightCancel == 0.25)
    #expect(item.panel.key == -1 && item.enableFK)
    #expect(item.bones["chair_joint"]?.sourceKey == 77)
    #expect(item.bones["chair_joint"]?.transform == root.transform)
    #expect(!item.enableDynamicBone && item.animationNormalizedTime == 0.375)
    let light = try #require(root.children[2].light)
    #expect(light.no == 22)
    #expect(light.color == SIMD4<Float>(0.2, 0.4, 0.8, 1))
    #expect(light.intensity == 1.5 && light.range == 10 && light.spotAngle == 45)
    #expect(light.shadow && !light.enable && light.drawTarget)
}

@Test func KoikatsuRejectsEveryTruncatedObjectSection() {
    let complete = StudioBytes.scene()
    for length in 0..<complete.count {
        #expect(throws: KoikatsuReadError.self) { try KoikatsuSceneReader.decode(complete.prefix(length)) }
    }
}

@Test func KoikatsuIsolatedRecordsPreserveCameraDistanceAndRoll() throws {
    var transform = StudioBytes(); transform.transform()
    let value = try KoikatsuSceneReader.decodeChangeAmount(transform.data)
    #expect(value.rotationDegrees == SIMD3<Float>(20, -40, 60))
    var camera = StudioBytes(); camera.i32(2)
    for value: Float in [1, 2, 3, 10, 20, 30, 0.5, 1, -4, 23] { camera.f32(value) }
    #expect(camera.data.count == 44)
    let record = try KoikatsuSceneReader.decodeCamera(camera.data)
    #expect(record.position == SIMD3<Float>(1, 2, 3))
    #expect(record.rotationDegrees.z == 30)
    #expect(record.distance == SIMD3<Float>(0.5, 1, -4))
    #expect(record.fieldOfView == 23)
    #expect(throws: KoikatsuReadError.self) { try KoikatsuSceneReader.decodeCamera(camera.data.dropLast()) }
    camera.data.append(0)
    #expect(throws: KoikatsuReadError.self) { try KoikatsuSceneReader.decodeCamera(camera.data) }
}

@Test func KoikatsuRejectsUnknownVersionsAndUnskippableKinds() {
    let unsupported = StudioBytes.prefix(version: "1.0.5.0", rootCount: 0)
    #expect(throws: KoikatsuReadError.unsupportedVersion("1.0.5.0")) { try KoikatsuSceneReader.decode(unsupported.data) }
    for kind: Int32 in [6, -1, 99] {
        var bytes = StudioBytes.prefix(); bytes.i32(0); bytes.i32(kind)
        #expect(throws: KoikatsuReadError.unsupportedObjectKind(kind)) { try KoikatsuSceneReader.decode(bytes.data) }
    }
}

@Test func KoikatsuRejectsMalformedCountsStringsAndNonfiniteNumbers() {
    for count: Int32 in [-1, 100_001] {
        #expect(throws: KoikatsuReadError.self) { try KoikatsuSceneReader.decode(StudioBytes.prefix(rootCount: count).data) }
    }
    for length: [UInt8] in [[0x80, 0x80, 0x80, 0x80, 0x08], [0xFF, 0xFF, 0x7F], [1, 0xFF]] {
        var data = StudioBytes.png; data.append(contentsOf: length)
        #expect(throws: KoikatsuReadError.self) { try KoikatsuSceneReader.decode(data) }
    }
    var bytes = StudioBytes(); bytes.transform()
    bytes.data.replaceSubrange(0..<4, with: [0, 0, 128, 127]) // +infinity
    #expect(throws: KoikatsuReadError.self) { try KoikatsuSceneReader.decodeChangeAmount(bytes.data) }
}

@Test func KoikatsuRejectsDuplicateHierarchyKeysAndExcessDepth() {
    var duplicate = StudioBytes.prefix()
    duplicate.i32(1); duplicate.header(kind: 3, key: 1); duplicate.string("root"); duplicate.i32(1)
    duplicate.header(kind: 5, key: 1); duplicate.string("duplicate"); duplicate.bool(false)
    #expect(throws: KoikatsuReadError.self) { try KoikatsuSceneReader.decode(duplicate.data) }
    var deep = StudioBytes.prefix(); deep.i32(0)
    for key: Int32 in 0...65 {
        deep.header(kind: 3, key: key); deep.string("folder"); deep.i32(key == 65 ? 0 : 1)
    }
    #expect(throws: KoikatsuReadError.limitExceeded("hierarchy depth exceeds 64")) { try KoikatsuSceneReader.decode(deep.data) }
}

@Test func KoikatsuHandlesDataWithNonzeroStartIndex() throws {
    var wrapped = Data([9, 8, 7]); wrapped.append(StudioBytes.scene())
    let sliced = wrapped.dropFirst(3)
    #expect(sliced.startIndex == 3)
    #expect(try KoikatsuSceneReader.decode(sliced).roots.first?.sourceKey == 10)
}
