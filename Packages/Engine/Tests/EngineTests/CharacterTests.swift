import Testing
import Foundation
import Character
import Studio
import Scene
import CoreMath
import simd

@Test func cardRoundTripsThroughPNG() throws {
    var card = CharacterCard.defaultFemale()
    card.profile.name = "Test 太郎"
    card.face.sliders["eye.size"] = 42
    card.body.sliders["body.height"] = -20
    card.hair.baseColor = RGB(hex: 0x123456)
    let png = try CardIO.encode(card, keyword: CardIO.cardKeyword, thumbnail: nil)
    #expect(png.count > 100)
    let back = try CardIO.decode(CharacterCard.self, keyword: CardIO.cardKeyword, from: png)
    #expect(back == card)
    #expect(CardIO.thumbnail(from: png) != nil)
    // A second write replaces the payload instead of appending another chunk.
    var card2 = card
    card2.profile.name = "Second"
    let png2 = try CardIO.encode(card2, keyword: CardIO.cardKeyword, thumbnail: CardIO.thumbnail(from: png))
    let back2 = try CardIO.decode(CharacterCard.self, keyword: CardIO.cardKeyword, from: png2)
    #expect(back2.profile.name == "Second")
}

@Test func sceneRoundTripsThroughPNG() throws {
    var doc = StudioDocument()
    var c = StudioObject.character(.defaultMale())
    c.poseDelta.rotations["upperarm_L"] = Float3(0, 0, 30)
    c.ikTargets[.handL] = IKTarget(enabled: true, position: Float3(0.3, 1.2, 0.2))
    doc.objects.append(c)
    doc.objects.append(.light(.spot))
    doc.cameraSlots[2] = doc.camera
    let png = try CardIO.encode(doc, keyword: CardIO.sceneKeyword, thumbnail: nil)
    let back = try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: png)
    #expect(back == doc)
    #expect(back.objects.count == 2)
    #expect(back.objects[0].ikTargets[.handL]?.enabled == true)
}

@Test func sliderRegistryHasUniqueIDsAndGroups() {
    let ids = SliderRegistry.shared.sliders.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(SliderRegistry.shared.groups(for: .face).count >= 5)
    #expect(SliderRegistry.shared.groups(for: .body).count >= 5)
    #expect(SliderRegistry.shared.slider("eye.size")?.tab == .face)
    #expect(SliderRegistry.shared.slider("body.height")?.tab == .body)
}

@Test func expressionPatternsResolveToMorphNames() {
    for p in ExpressionPresets.eyePatterns + ExpressionPresets.mouthPatterns + ExpressionPresets.eyebrowPatterns {
        for k in p.weights.keys { #expect(k.hasPrefix("exp.")) }
    }
}

@Test func gizmoDragTranslatesAlongAxis() throws {
    let ray = Ray(origin: Float3(0, 1, 5), direction: Float3(0, 0, -1))
    let drag = try #require(GizmoDrag(mode: .translate, axis: .x, origin: Float3(0, 1, 0), orientation: .identity, ray: ray, cameraForward: Float3(0, 0, -1)))
    let ray2 = Ray(origin: Float3(0.5, 1, 5), direction: Float3(0, 0, -1))
    let t = try #require(drag.translation(for: ray2))
    #expect(abs(t.x - 0.5) < 1e-4 && abs(t.y) < 1e-4 && abs(t.z) < 1e-4)
}

@Test func poseDeltaMergeAccumulates() {
    var a = PoseDelta(rotations: ["head": Float3(10, 0, 0)])
    a.merge(PoseDelta(rotations: ["head": Float3(5, 5, 0)], scales: ["head": Float3(repeating: 1.2)]))
    #expect(a.rotations["head"] == Float3(15, 5, 0))
    #expect(a.scales["head"] == Float3(repeating: 1.2))
}

// MARK: - Prototype gaze contracts (R4)

private func gazeSkeleton() throws -> Skeleton {
    try Skeleton(bones: [
        Skeleton.Bone(name: "root", parent: nil), Skeleton.Bone(name: "neck", parent: 0, restTranslation: Float3(0, 1.45, 0)),
        Skeleton.Bone(name: "head", parent: 1, restTranslation: Float3(0, 0.08, 0.01)),
        Skeleton.Bone(name: "eye_L", parent: 2, restTranslation: Float3(0.03, 0.06, 0.08)),
        Skeleton.Bone(name: "eye_R", parent: 2, restTranslation: Float3(-0.03, 0.06, 0.08))])
}

/// The former `CharacterInstance.applyGaze` body, the unchecked reference.
private func formerGaze(_ pose: Pose, _ skel: Skeleton, root rootMatrix: float4x4, target gazeTarget: Float3, headLook: Bool) -> Pose {
    var target = gazeTarget
    var p = pose
    let rootInv = rootMatrix.inverse
    if let hi = skel["head"] {
        let headPos = (rootMatrix * p.worldMatrices(skeleton: skel)[hi]).translation
        let d = target - headPos
        let minDist: Float = 1.6
        if length(d) < minDist, length_squared(d) > 1e-6 { target = headPos + normalize(d) * minDist }
    }
    let localTarget = rootInv.transformPoint(target)
    if headLook, let hi = skel["head"] {
        let m = p.worldMatrices(skeleton: skel)[hi]
        let d = m.inverse.transformPoint(localTarget)
        if length_squared(d) > 1e-6 {
            let dn = normalize(d)
            var yaw = atan2(dn.x, max(dn.z, 0.05)), pitch = atan2(-dn.y, max(dn.z, 0.05))
            yaw = clamp(yaw, -0.6, 0.6); pitch = clamp(pitch, -0.35, 0.35)
            let qh = simd_quatf(angle: yaw * 0.7, axis: Float3(0, 1, 0)) * simd_quatf(angle: pitch * 0.7, axis: Float3(1, 0, 0))
            p.rotations[hi] = (p.rotations[hi] * qh).normalized
            if let ni = skel["neck"] {
                let qn = simd_quatf(angle: yaw * 0.3, axis: Float3(0, 1, 0)) * simd_quatf(angle: pitch * 0.3, axis: Float3(1, 0, 0))
                p.rotations[ni] = (p.rotations[ni] * qn).normalized
            }
        }
    }
    let world = p.worldMatrices(skeleton: skel)
    for name in ["eye_L", "eye_R"] {
        guard let ei = skel[name], ei < world.count else { continue }
        let dir = world[ei].inverse.transformPoint(localTarget)
        guard length_squared(dir) > 1e-6 else { continue }
        let d = normalize(dir)
        var yaw = atan2(d.x, max(d.z, 0.05))
        var pitch = atan2(-d.y, max(d.z, 0.05))
        let limit: Float = 0.42
        yaw = clamp(yaw, -limit, limit); pitch = clamp(pitch, -limit * 0.7, limit * 0.7)
        let q = simd_quatf(angle: yaw, axis: Float3(0, 1, 0)) * simd_quatf(angle: pitch, axis: Float3(1, 0, 0))
        p.rotations[ei] = (p.rotations[ei] * q).normalized
    }
    return p
}

@Test func characterGazeMatchesFormerGazeAndKeepsDegenerateFramesUnchanged() throws {
    let skeleton = try gazeSkeleton()
    var pose = skeleton.restPose
    pose.rotations[1] = simd_quatf(angle: 0.2, axis: Float3(0, 1, 0))
    let root = Transform.trs(Float3(0.5, 0, -1), simd_quatf(angle: 0.6, axis: Float3(0, 1, 0)), Float3(repeating: 1.05))
    // Far, near (inside the convergence limit) and off-axis targets, with and without head look.
    let targets = [Float3(2, 1.8, 3), Float3(0.6, 1.6, -0.6), Float3(-3, 0.5, -2)]
    for target in targets {
        for headLook in [false, true] {
            let gazed = CharacterGaze.apply(to: pose, skeleton: skeleton, rootMatrix: root, target: target, headLook: headLook)
            #expect(gazed == formerGaze(pose, skeleton, root: root, target: target, headLook: headLook))
            #expect(gazed != pose)
        }
    }

    let target = targets[0]
    // A nonfinite target, a root without an inverse or a pose of another skeleton leaves the pose unchanged.
    #expect(CharacterGaze.apply(to: pose, skeleton: skeleton, rootMatrix: root, target: Float3(.nan, 1, 1), headLook: true) == pose)
    #expect(CharacterGaze.apply(to: pose, skeleton: skeleton, rootMatrix: Transform.scale(0), target: target, headLook: true) == pose)
    let short = try Skeleton(bones: [Skeleton.Bone(name: "root", parent: nil)]).restPose
    #expect(CharacterGaze.apply(to: short, skeleton: skeleton, rootMatrix: root, target: target, headLook: true) == short)
    // A collapsed eye has no frame to aim: it keeps its rotation while the other eye still turns.
    var collapsed = pose
    collapsed.scales[3] = .zero
    let gazed = CharacterGaze.apply(to: collapsed, skeleton: skeleton, rootMatrix: root, target: target, headLook: false)
    #expect(gazed.rotations[3].vector == collapsed.rotations[3].vector)
    #expect(gazed.rotations[4].vector != collapsed.rotations[4].vector)
    #expect(gazed.rotations.allSatisfy { q in (0..<4).allSatisfy { q.vector[$0].isFinite } })
}
