import Testing
import CoreMath
import Character

private func colorClose(_ a: Float4, _ b: Float4) -> Bool { (0..<4).allSatisfy { abs(a[$0] - b[$0]) < 0.00001 } }

@Test func sourceColorCompositionMatchesAnalyticHeadWhiteClothesAndHairCases() throws {
    let color = Float4(0.25, 0.5, 0.75, 0.8), secondary = Float4(0.2, 0.4, 0.6, 0.9)
    let head = try SourceColorComposition.sample(kind: .head, main: Float4(0.4, 0.2, 0.8, 0.3), mask: Float4(1, 0, 0.8, 0), colors: [color, secondary])
    #expect(colorClose(head, Float4(0.32, 0.16, 0.64, 1)))
    let white = try SourceColorComposition.sample(kind: .eyeWhite, main: Float4(0.25, 0.9, 0.1, 0), mask: .zero, colors: [Float4(0.8, 0.6, 0.4, 0.5), secondary])
    #expect(colorClose(white, Float4(0.35, 0.45, 0.55, 1)))
    let clothes = try SourceColorComposition.sample(kind: .clothes, main: Float4(1, 0.5, 0.2, 0.5), mask: Float4(1, 0, 0, 0), colors: [color, secondary, .one])
    #expect(colorClose(clothes, Float4(0.125, 0.125, 0.075, 0.25)))
    let hair = try SourceColorComposition.sample(kind: .hair, main: .zero, mask: Float4(1, 0, 0, 0), colors: [color, secondary, .one])
    #expect(colorClose(hair, Float4(0.25, 0.5, 0.75, 1)))
}

@Test func sourceColorCompositionEyeBlendClampsAndPremultipliesSourceAlpha() throws {
    let color = Float4(0.25, 0.5, 0.75, 0.8), main = Float4(0.25, 0.9, 0.8, 0.5)
    let zero = try SourceColorComposition.sample(kind: .eye, main: main, mask: .zero, colors: [color], blend: 0)
    let one = try SourceColorComposition.sample(kind: .eye, main: main, mask: .zero, colors: [color], blend: 1)
    #expect(colorClose(zero, Float4(0.025, 0.05, 0.075, 0.16)))
    #expect(colorClose(one, Float4(0, 0, 0.2, 0.16)))
    for value: Float in [0, 0.5, 1] {
        let result = try SourceColorComposition.sample(kind: .eye, main: Float4(value, 0, 0, 1), mask: .zero, colors: [.one], blend: 1)
        #expect((0..<4).allSatisfy { result[$0].isFinite && (0...1).contains(result[$0]) })
    }
}

@Test func sourceColorCompositionRejectsInvalidCountsNonfiniteAndUnnormalizedColorInputs() throws {
    for kind: SourceColorComposition.Kind in [.head, .eye, .eyeWhite, .hair, .clothes] {
        #expect(throws: (any Error).self) { try SourceColorComposition.sample(kind: kind, main: .one, mask: .zero, colors: []) }
    }
    for color in [Float4(.nan, 0, 0, 1), Float4(.infinity, 0, 0, 1), Float4(-0.1, 0, 0, 1), Float4(1.1, 0, 0, 1)] {
        #expect(throws: (any Error).self) { try SourceColorComposition.sample(kind: .eye, main: .one, mask: .zero, colors: [color]) }
    }
    for value: Float in [.nan, .infinity, -0.1, 1.1] {
        #expect(throws: (any Error).self) { try SourceColorComposition.sample(kind: .eye, main: .one, mask: .zero, colors: [.one], blend: value) }
    }
    #expect(throws: (any Error).self) { try SourceColorComposition.sample(kind: .eye, main: Float4(.nan, 0, 0, 1), mask: .zero, colors: [.one]) }
    #expect(throws: (any Error).self) { try SourceColorComposition.sample(kind: .eye, main: .one, mask: Float4(.infinity, 0, 0, 1), colors: [.one]) }
}
