import Foundation
import Testing
import Metal
import Assets
import simd
import CoreMath
import Scene
import Character
import Studio
import Renderer

/// Builds pattern entries shaped exactly like
/// `Tools/reverse/studio_hand_animation.py --all-patterns` output.
private func patternJSON(id: Int, name: String = "Goo", state: String = "goo",
                         stop: Float = 0.2, rate: Float = 30, loop: Bool = true,
                         frameTimes: String, bones: String) -> String {
    """
    {"id":\(id),"name":"\(name)","state":"\(state)",
     "clip":{"startTime":0,"stopTime":\(stop),"sampleRate":\(rate),"loop":\(loop)},
     "frameTimes":[\(frameTimes)],"bones":{\(bones)}}
    """
}

private let twoFrameRotation = #""cf":{"frames":[[0,0,0,1],[0,0.5,0,0.5]],"scale":[[1,1,1],[1,2,1]]}"#
private let broadcastRotation = #""cf":{"frames":[[0,0.5,0,0.5]]}"#

private func handJSON(_ patterns: [String]) -> String {
    #"{"patterns":[\#(patterns.joined(separator: ","))]}"#
}

private let defaultPatterns = handJSON([
    patternJSON(id: 1, frameTimes: "0.0,0.033333335", bones: twoFrameRotation),
    patternJSON(id: 2, name: "Scissors", state: "scissors", frameTimes: "0.0", bones: broadcastRotation),
])

private func patternsDocument(hands: String,
                              kind: String = "ikkoku-studio-hand-patterns",
                              scope: String = "hand-anime-table-states-generic-transforms",
                              coordinateSpace: String = "unity-left-handed-y-up",
                              schemaVersion: Int = 1,
                              infoHash: String = String(repeating: "b", count: 64)) -> Data {
    Data("""
    {"schemaVersion":\(schemaVersion),"converterVersion":"1.0.0","kind":"\(kind)",
     "coordinateSpace":"\(coordinateSpace)","scope":"\(scope)",
     "source":{"bundleSHA256":"\(String(repeating: "a", count: 64))","bundle":"/original/base/00.unity3d",
               "infoBundleSHA256":"\(infoHash)","infoBundle":"/original/info/00.unity3d"},
     "hands":\(hands),
     "diagnostics":["Pattern IDs come from the Studio HandAnime tables."]}
    """.utf8)
}

private func bothHands(_ left: String = defaultPatterns, _ right: String = defaultPatterns) -> String {
    #"{"L":\#(left),"R":\#(right)}"#
}

private let defaultDocument = patternsDocument(hands: bothHands())

private func patternsRig(withFinger: Bool = true) throws -> RigDefinition {
    var nodes: [RigDefinition.Node] = [
        .init(name: "root", sourceID: "root", parent: nil, translation: Float3(0.2, -0.3, 0.4), scale: Float3(2, 1, 3)),
        .init(name: "cf", sourceID: "cf-1", parent: 0, translation: Float3(0.1, 0.2, 0.3)),
    ]
    if withFinger { nodes.append(.init(name: "extra", sourceID: "extra-1", parent: 1, translation: Float3(0, 0.1, 0))) }
    return try RigDefinition(nodes: nodes, skins: [])
}

private func sampled(_ evaluation: SourceStudioHandPatterns.Evaluation) throws -> [String: SourceStudioHandPose.Bone] {
    guard case let .channels(bones) = evaluation else { Issue.record("expected sampled channels"); return [:] }
    return bones
}

private func components(_ actual: [Float]?, _ expected: [Float], tolerance: Float = 0.00001) -> Bool {
    guard let actual, actual.count == expected.count else { return false }
    return zip(actual, expected).allSatisfy { abs($0 - $1) < tolerance }
}

private func near(_ actual: float4x4, _ expected: float4x4, tolerance: Float = 0.00001) -> Bool {
    (0..<4).allSatisfy { column in (0..<4).allSatisfy { row in abs(actual[column][row] - expected[column][row]) < tolerance } }
}

private func length(_ value: [Float]?) -> Float {
    guard let value, value.count == 4 else { return -1 }
    return simd_length(Float4(value[0], value[1], value[2], value[3]))
}

private func normalized(_ value: [Float]) -> [Float] {
    let scale = length(value)
    return value.map { $0 / scale }
}

@Test func studioHandPatternsSampleAdjacentFramesAndBroadcastConstantClips() throws {
    let document = try SourceStudioHandPatterns.decode(defaultDocument)
    #expect(document.hands.count == 2 && document.hands["L"]?.patterns.count == 2
            && document.diagnostics.count == 1 && document.source.infoBundleSHA256.allSatisfy { $0 == "b" })
    // Half a frame into pattern 1: every component is the mean of the two dense frames.
    let half = try sampled(document.pose(hand: "L", pattern: 1, elapsed: 0.016666668))
    #expect(half.count == 1 && components(half["cf"]?.rotation, normalized([0, 0.25, 0, 0.75])))
    #expect(components(half["cf"]?.scale, [1, 1.5, 1]) && half["cf"]?.position == nil)
    // A pattern whose clip has no dense slots replays its single constant frame.
    let broadcast = try sampled(document.pose(hand: "R", pattern: 2, elapsed: 0.19))
    #expect(components(broadcast["cf"]?.rotation, normalized([0, 0.5, 0, 0.5])) && broadcast["cf"]?.scale == nil)
    // Sampled quaternions stay unit length even between non-unit adjacent frames.
    #expect(abs(length(half["cf"]?.rotation) - 1) < 0.00001 && abs(length(broadcast["cf"]?.rotation) - 1) < 0.00001)
    #expect(throws: (any Error).self) { try document.pose(hand: "X", pattern: 1, elapsed: 0) }
    #expect(throws: (any Error).self) { try document.pose(hand: "L", pattern: 1, elapsed: .nan) }
}

@Test func studioHandPatternsWrapTheStudioClockIntoTheLoop() throws {
    let document = try SourceStudioHandPatterns.decode(defaultDocument)
    let duration: Float = 0.2
    let first = try sampled(document.pose(hand: "L", pattern: 1, elapsed: 0.05))
    // One whole loop plus the same phase gives the identical sample.
    let later = try sampled(document.pose(hand: "L", pattern: 1, elapsed: 0.05 + 7 * duration))
    #expect(components(first["cf"]?.rotation, later["cf"]?.rotation ?? [])
            && components(first["cf"]?.scale, later["cf"]?.scale ?? []))
    // Landing exactly on the loop boundary restarts from the first frame.
    let boundary = try sampled(document.pose(hand: "L", pattern: 1, elapsed: 3 * duration))
    #expect(components(boundary["cf"]?.rotation, [0, 0, 0, 1]))
    // Past the stop time the phase folds back, so 0.25 s behaves like 0.05 s.
    let wrapped = try sampled(document.pose(hand: "L", pattern: 1, elapsed: 0.25))
    #expect(components(wrapped["cf"]?.rotation, first["cf"]?.rotation ?? []))
    #expect(components(wrapped["cf"]?.scale, first["cf"]?.scale ?? []))
}

@Test func studioHandPatternZeroLeavesTheIncomingPoseUntouched() throws {
    let rig = try patternsRig()
    let document = try SourceStudioHandPatterns.decode(defaultDocument)
    guard case .noChange = try document.pose(hand: "L", pattern: 0, elapsed: 0.1) else {
        Issue.record("pattern 0 must report noChange"); return
    }
    var pose = rig.restPose
    // The node holds a authored non-identity matrix, so an accidental write would show.
    let authored = Transform.trs(Float3(0.1, 0.2, 0.3), simd_quatf(angle: 0.3, axis: Float3(0, 1, 0)), Float3(1, 2, 1))
    pose.localMatrices[1] = authored
    #expect(try document.apply(.noChange, to: rig, on: &pose) == nil)
    #expect(pose.localMatrices[1] == authored && pose.localMatrices[0] == rig.restPose.localMatrices[0])
}

@Test func studioHandPatternWithoutAClipReportsADiagnosticAndDoesNotGuess() throws {
    let rig = try patternsRig()
    let document = try SourceStudioHandPatterns.decode(defaultDocument)
    let evaluation = try document.pose(hand: "R", pattern: 40, elapsed: 0.05)
    guard case let .unknown(diagnostic) = evaluation else { Issue.record("expected unknown diagnostic"); return }
    #expect(diagnostic.contains("40") && diagnostic.contains("info/00.unity3d"))
    var pose = rig.restPose
    #expect(try document.apply(evaluation, to: rig, on: &pose) == diagnostic)
    #expect(pose.localMatrices == rig.restPose.localMatrices)
}

@Test func studioHandPatternsReplaceOnlyTheAnimatedChannels() throws {
    let rig = try patternsRig()
    let document = try SourceStudioHandPatterns.decode(defaultDocument)
    var basePose = rig.restPose
    let shapedTranslation = Float3(0.4, -0.5, 0.6)
    let shapedScale = Float3(1.2, 0.8, 1.5)
    basePose.localMatrices[1] = Transform.trs(shapedTranslation,
        simd_quatf(angle: .pi / 4, axis: Float3(1, 0, 0)), shapedScale)
    #expect(try document.apply(try document.pose(hand: "L", pattern: 1, elapsed: 0), to: rig, on: &basePose) == nil)
    // The pattern frame animates rotation and scale, so the card-pose translation
    // survives and the recorded channels replace everything else with frame 0.
    #expect(near(basePose.localMatrices[1], Transform.trs(shapedTranslation, .identity, Float3(1, 1, 1))))
    #expect(basePose.localMatrices[0] == rig.restPose.localMatrices[0])
    #expect(basePose.localMatrices[2] == rig.restPose.localMatrices[2])
    // A bone the rig never has cannot be patched at all.
    let strict = try SourceStudioHandPatterns.decode(onePatternLeft(
        #""absent":{"frames":[[0,0,0,1]]}"#, frameTimes: "0.0"))
    #expect(throws: (any Error).self) {
        try strict.apply(try strict.pose(hand: "L", pattern: 1, elapsed: 0), to: rig, on: &basePose)
    }
}

/// A document whose only left-hand pattern carries `bones` on a single frame grid.
private func onePatternLeft(_ bones: String, frameTimes: String,
                            parameters: (Float, Float, Bool) = (0.2, 30, true)) -> Data {
    patternsDocument(hands: bothHands(handJSON([patternJSON(
        id: 1, stop: parameters.0, rate: parameters.1, loop: parameters.2,
        frameTimes: frameTimes, bones: bones)])))
}

/// Same, with two patterns on the left hand for ID-shape rejections.
private func twoPatternsLeft(first: String, second: String) -> Data {
    patternsDocument(hands: bothHands(handJSON([
        patternJSON(id: 1, frameTimes: "0.0", bones: first),
        patternJSON(id: 2, frameTimes: "0.0", bones: second)])))
}

@Test func studioHandPatternsDocumentValidationRejectsMalformedLibraries() throws {
    let documents: [(String, Data)] = [
        ("kind", patternsDocument(hands: bothHands(), kind: "other-kind")),
        ("scope", patternsDocument(hands: bothHands(), scope: "default-state-single-clip-generic-transforms")),
        ("space", patternsDocument(hands: bothHands(), coordinateSpace: "native-right-handed-y-up")),
        ("missingHand", patternsDocument(hands: #"{"L":\#(defaultPatterns)}"#)),
        ("unknownHand", patternsDocument(hands: #"{"X":\#(defaultPatterns),"R":\#(defaultPatterns)}"#)),
        ("shortHash", patternsDocument(hands: bothHands(), infoHash: String(repeating: "b", count: 63))),
        ("schemaVersion", patternsDocument(hands: bothHands(), schemaVersion: 2)),
        ("emptyPatterns", patternsDocument(hands: bothHands(#"{"patterns":[]}"#))),
        ("duplicateId", patternsDocument(hands: bothHands(handJSON([
            patternJSON(id: 1, frameTimes: "0.0", bones: broadcastRotation),
            patternJSON(id: 1, name: "Scissors", state: "scissors", frameTimes: "0.0", bones: broadcastRotation),
        ])))),
        ("gappedIds", patternsDocument(hands: bothHands(handJSON([
            patternJSON(id: 1, frameTimes: "0.0", bones: broadcastRotation),
            patternJSON(id: 3, name: "Scissors", state: "scissors", frameTimes: "0.0", bones: broadcastRotation),
        ])))),
        ("nonLooping", onePatternLeft(broadcastRotation, frameTimes: "0.0", parameters: (0.2, 30, false))),
        ("zeroStopTime", onePatternLeft(broadcastRotation, frameTimes: "0.0", parameters: (0, 30, true))),
        ("emptyFrameTimes", onePatternLeft(broadcastRotation, frameTimes: "")),
        ("framesDisagreeWithGrid", onePatternLeft(twoFrameRotation, frameTimes: "0.0,0.05")),
        ("descendingFrameTimes", onePatternLeft(twoFrameRotation, frameTimes: "0.033333335,0.0")),
        ("channelCountMismatch", onePatternLeft(twoFrameRotation, frameTimes: "0.0")),
        ("shortRotationFrame", onePatternLeft(#""cf":{"frames":[[0,0,0]]}"#, frameTimes: "0.0")),
        ("infiniteFrame", onePatternLeft(#""cf":{"frames":[[0,1e999,0,1]]}"#, frameTimes: "0.0")),
        ("identityRotationFrame", onePatternLeft(#""cf":{"frames":[[0,0,0,0]]}"#, frameTimes: "0.0")),
        ("shortScaleFrame", onePatternLeft(#""cf":{"frames":[[0,0,0,1]],"scale":[[1,1]]}"#, frameTimes: "0.0")),
    ]
    for (name, json) in documents {
        #expect(throws: (any Error).self, "\(name) must be rejected") {
            try SourceStudioHandPatterns.decode(json)
        }
    }
}

/// The Studio preview applies the saved `[L, R]` pair through this helper
/// after body animation and before FK/IK.
@Test func studioHandPatternSavedPairAppliesBothHandsAndReportsUnknowns() throws {
    let rig = try patternsRig()
    let left = handJSON([patternJSON(id: 1, frameTimes: "0.0", bones: #""cf":{"frames":[[0,0.5,0,0.5]]}"#)])
    let right = handJSON([patternJSON(id: 1, frameTimes: "0.0", bones: #""extra":{"frames":[[0,0,0.5,0.5]]}"#)])
    let document = try SourceStudioHandPatterns.decode(patternsDocument(hands: bothHands(left, right)))
    var pose = rig.restPose
    #expect(try document.applySaved([1, 1], to: rig, on: &pose, elapsed: 0) == [])
    #expect(pose.localMatrices[1] != rig.restPose.localMatrices[1] && pose.localMatrices[2] != rig.restPose.localMatrices[2])
    // Pattern 0 disables the hand Animator, so both hands keep the incoming pose.
    var disabled = rig.restPose
    #expect(try document.applySaved([0, 0], to: rig, on: &disabled, elapsed: 0.3) == [])
    #expect(disabled.localMatrices == rig.restPose.localMatrices)
    // One saved pattern without a clip explains itself and never guesses.
    var partial = rig.restPose
    let diagnostics = try document.applySaved([1, 40], to: rig, on: &partial, elapsed: 0)
    #expect(diagnostics.count == 1 && diagnostics[0].contains("40"))
    #expect(partial.localMatrices[1] != rig.restPose.localMatrices[1] && partial.localMatrices[2] == rig.restPose.localMatrices[2])
    // A record without the two saved entries changes nothing and says so.
    var truncated = rig.restPose
    let malformed = try document.applySaved([1], to: rig, on: &truncated, elapsed: 0)
    #expect(malformed.count == 1 && truncated.localMatrices == rig.restPose.localMatrices)
}

/// A converted synthetic Studio scene whose saved patterns are `[5, 6]` shows
/// the preview applying the library between body animation and FK/IK, and
/// reporting instead of guessing when the library is not configured.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func studioHandPatternsPreviewAppliesSavedPatternsAfterAnimationWhenSupplied() throws {
    let env = ProcessInfo.processInfo.environment
    guard let scenes = env["IKKOKU_STUDIO_SCENE_FIXTURES"], let rig = env["IKKOKU_SOURCE_AVATAR"],
          let catalog = env["IKKOKU_STUDIO_POSE_CONTRACT"],
          let patterns = env["IKKOKU_STUDIO_HAND_PATTERNS"] else { return }
    let scene = URL(fileURLWithPath: scenes).appendingPathComponent("synthetic-current.png")
    let data = try Data(contentsOf: scene)
    func makePreview(_ library: String?) throws -> SourceStudioCharacterPreview {
        try SourceStudioCharacterPreview(reference: SourceStudioCharacterReference(
            sceneFile: scene.path, sceneSHA256: OriginalCardFixture.hash(data), rigFile: rig,
            boneCatalogFile: catalog, objectKey: 10, handPatternsFile: library),
            resources: ResourceStore(device: try #require(MTLCreateSystemDefaultDevice())))
    }
    let without = try makePreview(nil), with = try makePreview(patterns)
    let saved = with.record.handPatterns
    #expect(saved.count == 2 && saved.contains { $0 != 0 })
    #expect(without.diagnostics.contains { $0.contains("never guessed") }
            && !with.diagnostics.contains { $0.contains("never guessed") })
    #expect(with.diagnostics.contains { $0.contains("restarts the loop at frame 0") })
    let library = try SourceStudioHandPatterns.load(url: URL(fileURLWithPath: patterns))
    let sourceRig = with.preview.source.rig, finger = try sourceRig.uniqueNode(named: "cf_j_index01_L")
    let elapsed: Float = 0.107
    let plain = try without.editedPose(animationElapsed: elapsed)
    let applied = try with.editedPose(animationElapsed: elapsed)
    #expect(applied.localMatrices[finger] != plain.localMatrices[finger])
    // The preview's pose equals the same saved pair applied directly onto the
    // unpatterned pose at one clock instant, so the pattern really sits between
    // the body animation and the FK/IK consumers.
    var direct = plain
    #expect(try library.applySaved(saved, to: sourceRig, on: &direct, elapsed: elapsed) == [])
    #expect(applied.localMatrices == direct.localMatrices)
    // Both saved patterns loop over 0.1666667 s, so one loop later the pose repeats.
    let later = try with.editedPose(animationElapsed: elapsed + 44 * 0.16666674613952637)
    #expect(near(later.localMatrices[finger], applied.localMatrices[finger]))
}

/// `Tools/reverse/studio_hand_animation.py --all-patterns` plus the PR #18
/// fitted default-pose capture produce the same channels for pattern 1 at
/// 0.107 s; the contract keeps the expected numbers outside tracked files.
@Test func studioHandPatternOneMatchesTheFittedDefaultPoseCapture() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_HAND_PATTERN_CONTRACT"] else { return }
    struct Contract: Decodable {
        struct Bone: Decodable { let rotation: [Float], scale: [Float]? }
        struct Hand: Decodable { let bones: [String: Bone] }
        let schemaVersion: Int, library: String, pattern: Int, elapsed: Float
        let hands: [String: Hand]
    }
    let contract = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(contract.schemaVersion == 1 && contract.pattern == 1 && contract.elapsed == 0.107)
    let library = try SourceStudioHandPatterns.load(url: URL(fileURLWithPath: contract.library))
    for (hand, expected) in contract.hands {
        let bones = try sampled(library.pose(hand: hand, pattern: contract.pattern, elapsed: contract.elapsed))
        #expect(Set(bones.keys) == Set(expected.bones.keys), "\(hand) hand covers exactly the captured bones")
        for (name, bone) in expected.bones {
            #expect(components(bones[name]?.rotation, bone.rotation, tolerance: 0.000001), "\(hand)/\(name) rotation")
            #expect((bone.scale == nil) == (bones[name]?.scale == nil), "\(hand)/\(name) channels match capture")
            if let scale = bone.scale { #expect(components(bones[name]?.scale, scale, tolerance: 0.000001)) }
        }
    }
}
