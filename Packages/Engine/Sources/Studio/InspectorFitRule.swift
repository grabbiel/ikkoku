import Foundation

/// The judgement of #333's fit check: whether every accessibility element of
/// the Studio inspector's scroll view lies within its visible width. The app's
/// `InspectorUIScenario.inspectorFit` collects the elements from the window;
/// this rule is pure, so it is tested without a window (InspectorFitRuleTests).
///
/// An element passes when it lies within the visible width, with 1 pt of
/// tolerance on either side. The one exception is a section's disclosure
/// triangle. SwiftUI exposes a `DisclosureGroup`'s label as the triangle's
/// own title, with no separate static text, and the triangle's element spans
/// the chevron and that title, starting `triangleLead` (10 pt) before the
/// visible leading edge in every run where the column fits (#333's
/// diagnostics: 'Clothes state' at x -10...110). A triangle past the visible
/// width passes only when it has a title, starts at exactly that offset
/// (within the tolerance) and does not extend past the trailing edge. A
/// column shifted sideways moves its triangles off that offset, so it fails.
///
/// The rule before it skipped any titled triangle whose title appeared as a
/// static text anywhere, wherever the triangle lay, so a shifted column whose
/// only element past the edge was a titled triangle passed.
public enum InspectorFitRule {
    /// One accessibility element: its role, its label, title or value, and its frame (screen coordinates).
    public struct Element: Sendable, Equatable {
        public var role: String
        public var name: String
        public var frame: CGRect

        public init(role: String, name: String, frame: CGRect) {
            self.role = role
            self.name = name
            self.frame = frame
        }
    }

    public struct Judgement: Sendable, Equatable {
        /// The elements past the visible width that the rule does not accept, as
        /// "role 'name' x minX...maxX" relative to the visible leading edge.
        public var offenders: [String]
        /// The disclosure triangles past the visible width accepted at the header offset.
        public var triangles: Int
        public var elements: Int
        /// The document view is no wider than the clip view (within the tolerance).
        public var documentFits: Bool

        public var fits: Bool { offenders.isEmpty && elements > 0 && documentFits }
    }

    /// How far a section's disclosure triangle starts before the visible leading edge when the column fits.
    public static let triangleLead: CGFloat = 10
    public static let tolerance: CGFloat = 1

    /// Judges `elements` against the clip view's `visible` rect (screen coordinates) and the document and clip widths.
    public static func judge(_ elements: [Element], visible: CGRect, document: CGFloat, clip: CGFloat) -> Judgement {
        func inside(_ f: CGRect) -> Bool { f.minX >= visible.minX - tolerance && f.maxX <= visible.maxX + tolerance }
        var offenders: [String] = [], triangles = 0
        for element in elements where !inside(element.frame) {
            let f = element.frame
            if element.role == "AXDisclosureTriangle", !element.name.isEmpty,
               abs(f.minX - (visible.minX - triangleLead)) <= tolerance, f.maxX <= visible.maxX + tolerance {
                triangles += 1
                continue
            }
            offenders.append("\(element.role) '\(element.name.prefix(40))' x \(Int(f.minX - visible.minX))...\(Int(f.maxX - visible.minX))")
        }
        return Judgement(offenders: offenders, triangles: triangles, elements: elements.count,
                         documentFits: document <= clip + tolerance)
    }
}
