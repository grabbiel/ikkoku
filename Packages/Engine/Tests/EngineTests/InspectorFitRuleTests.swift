import Foundation
import Testing
import Studio

// #333: the fit check's rule for the Studio inspector, judged on synthetic
// accessibility frames. The visible width is the clip view of a 350 pt column
// with a legacy scroller (333 pt) at the window's trailing edge.

private let visible = CGRect(x: 1060, y: 100, width: 333, height: 700)

private func element(_ role: String, _ name: String, x: CGFloat, width: CGFloat, y: CGFloat = 200) -> InspectorFitRule.Element {
    .init(role: role, name: name, frame: CGRect(x: visible.minX + x, y: y, width: width, height: 20))
}

/// The Clothes state section of a column shifted `shift` pt sideways: its header's triangle element, spanning the
/// chevron and the title from 10 pt before the leading edge when the column fits (x -10...110, as in the app's
/// accessibility tree), and a row's label and picker. `titleText` adds a separate static text with the title, which
/// SwiftUI's `DisclosureGroup` does not expose but the previous rule relied on.
private func clothesSection(shift: CGFloat, titleText: Bool = false) -> [InspectorFitRule.Element] {
    [element("AXDisclosureTriangle", "Clothes state", x: -10 + shift, width: 120, y: 180)]
        + (titleText ? [element("AXStaticText", "Clothes state", x: 14 + shift, width: 90, y: 180)] : [])
        + [element("AXStaticText", "Top", x: 12 + shift, width: 30),
           element("AXRadioButton", "On", x: 113 + shift, width: 50),
           element("AXRadioButton", "Off", x: 268 + shift, width: 50)]
}

/// The rule before #333's fix: a titled triangle past the visible width was skipped wherever it lay, when a static
/// text with its title appeared anywhere.
private func previousRuleFits(_ elements: [InspectorFitRule.Element]) -> Bool {
    func past(_ f: CGRect) -> Bool { f.minX < visible.minX - 1 || f.maxX > visible.maxX + 1 }
    let titles = Set(elements.filter { $0.role == "AXStaticText" }.map(\.name))
    return !elements.isEmpty && elements.allSatisfy {
        !past($0.frame) || ($0.role == "AXDisclosureTriangle" && !$0.name.isEmpty && titles.contains($0.name))
    }
}

@Test func inspectorFitAcceptsTheTriangleAtItsHeaderOffset() {
    for titleText in [false, true] {
        for shift: CGFloat in [-1, 0, 1] {
            let judgement = InspectorFitRule.judge(clothesSection(shift: shift, titleText: titleText),
                                                   visible: visible, document: 333, clip: 333)
            #expect(judgement.fits, "shift \(shift), title text \(titleText): \(judgement.offenders)")
            #expect(judgement.triangles == 1)
        }
    }
}

@Test func inspectorFitFailsAShiftedColumnWithATitledTriangle() {
    // The negative case: shifted 6 pt either way, every element except the triangle stays within the visible width.
    // With a static text carrying the title, the previous rule skipped the triangle by its title and passed the column.
    for titleText in [false, true] {
        for shift: CGFloat in [-6, 6] {
            let elements = clothesSection(shift: shift, titleText: titleText)
            #expect(previousRuleFits(elements) == titleText)
            let judgement = InspectorFitRule.judge(elements, visible: visible, document: 333, clip: 333)
            #expect(!judgement.fits)
            #expect(judgement.triangles == 0)
            #expect(judgement.offenders == ["AXDisclosureTriangle 'Clothes state' x \(Int(-10 + shift))...\(Int(110 + shift))"])
        }
    }
}

@Test func inspectorFitNeedsATitledTriangleWithinTheTrailingEdge() {
    var untitled = clothesSection(shift: 0)
    untitled[0].name = ""
    #expect(InspectorFitRule.judge(untitled, visible: visible, document: 333, clip: 333).offenders == ["AXDisclosureTriangle '' x -10...110"])

    var wide = clothesSection(shift: 0)
    wide[0].frame.size.width = 345
    #expect(InspectorFitRule.judge(wide, visible: visible, document: 333, clip: 333).offenders == ["AXDisclosureTriangle 'Clothes state' x -10...335"])
    wide[0].frame.size.width = 344
    #expect(InspectorFitRule.judge(wide, visible: visible, document: 333, clip: 333).fits)
}

@Test func inspectorFitNeedsADocumentNoWiderThanTheClipAndSomeElements() {
    let wideDocument = InspectorFitRule.judge(clothesSection(shift: 0), visible: visible, document: 362, clip: 333)
    #expect(wideDocument.offenders.isEmpty && !wideDocument.documentFits && !wideDocument.fits)
    #expect(!InspectorFitRule.judge([], visible: visible, document: 333, clip: 333).fits)
    // A label cut off at the leading edge, #333's symptom.
    var cut = clothesSection(shift: 0)
    cut[1].frame.origin.x = visible.minX - 14
    #expect(InspectorFitRule.judge(cut, visible: visible, document: 333, clip: 333).offenders == ["AXStaticText 'Top' x -14...16"])
}
