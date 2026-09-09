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
