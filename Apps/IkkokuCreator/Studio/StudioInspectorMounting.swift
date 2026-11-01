import SwiftUI
import AppKit

// R7 phase 2, item 7: the inspector keeps views it has built while they are
// not shown, so the next selection reuses them instead of building its
// controls again. A hidden view keeps its layout but takes no space, draws
// nothing, takes no clicks, keys or accessibility queries, and its controls
// write nothing to the model.

/// Which inspector views stay mounted while hidden. `IKKOKU_PERF_KEEP_MOUNTED`
/// is a measurement control, read once at launch: "off" builds and drops
/// them as before item 7, "tab" keeps only the Object tab while nothing is
/// selected, and "on" (the default) also keeps each kind's section.
enum StudioInspectorMounting: String, Sendable {
    case off, tab, on

    static let current: StudioInspectorMounting =
        ProcessInfo.processInfo.environment["IKKOKU_PERF_KEEP_MOUNTED"].flatMap(Self.init(rawValue:)) ?? .on

    var keepsTab: Bool { self != .off }
    var keepsSections: Bool { self == .on }
}

extension View {
    /// Hides a kept inspector view in a `ZStack(alignment: .top)` of kept
    /// views. Its height is fixed, as a scroll view's content is, and framed
    /// to zero while hidden, so it keeps its layout but takes no space. Its
    /// width is reported as at most the width proposed to it while hidden: a
    /// hidden view wider than the inspector (a route section, say) would
    /// otherwise widen the stack and move what is shown. At zero opacity
    /// SwiftUI does not draw it and leaves it out of the accessibility tree;
    /// disabled, its controls leave the Tab key-view loop and refuse focus.
    /// (`accessibilityHidden(false)` is not used for the shown state: it
    /// exposes elements a view hides itself, such as the placeholder's
    /// image.) Picker labels need `inspectorKeptLabel()` too.
    func inspectorHidden(_ hidden: Bool) -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(height: hidden ? 0 : nil, alignment: .top)
            // A minimum alone makes the frame min(child, proposal) wide, with
            // the child laid out at the proposal as before; with no minimum
            // the frame takes the child's size.
            .frame(minWidth: hidden ? 0 : nil, alignment: .topLeading)
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .disabled(hidden)
    }

    /// A Picker's label in kept inspector views. SwiftUI keeps a Picker's
    /// label in the accessibility tree at zero opacity, so the label hides
    /// itself while its views are hidden.
    func inspectorKeptLabel() -> some View { modifier(InspectorKeptLabel()) }
}

private struct InspectorKeptLabel: ViewModifier {
    @Environment(\.inspectorKeptHidden) private var tabHidden
    @Environment(\.inspectorSectionHidden) private var sectionHidden
    func body(content: Content) -> some View { content.accessibilityHidden(tabHidden || sectionHidden) }
}

/// What a kept inspector view holds besides its views: the last state it
/// showed, an empty AppKit view behind it, and the sections the user
/// collapsed in it. Keep it non-generic: the CI compiler (Swift 6.3.3)
/// crashes in its Release optimizer (the early performance inliner) on the
/// deinit of a generic `InspectorKeptViews<Shown>`. Readers get the state
/// back as the kept view's type through `keptState(as:)`.
@MainActor final class InspectorKeptViews {
    /// The last state the kept view showed, of that view's own type.
    var state: Any?

    /// The kept state as the kept view's type. A state of another type is a
    /// bug: Debug stops on it, and Release drops it, so the view is built
    /// again from the model's state the next time it shows, as when nothing
    /// was kept.
    func keptState<Shown>(as type: Shown.Type) -> Shown? {
        guard let state else { return nil }
        if let kept = state as? Shown { return kept }
        assertionFailure("InspectorKeptViews holds \(Swift.type(of: state)), not \(type)")
        self.state = nil
        return nil
    }
    /// Set by `InspectorAnchor` when SwiftUI makes it.
    weak var anchor: InspectorAnchorView?
    let sections = InspectorSectionExpansion()

    /// Hiding the views does what removing them from the window did. A text
    /// field being edited in them loses its field editor without the
    /// end-of-editing commit (what was typed has already been applied), and
    /// the window becomes the first responder. An active colour well stops
    /// taking the colour panel's colour. Sections built anew start expanded,
    /// so collapsed ones expand again.
    func didHide() {
        anchor?.releaseControls()
        sections.expandAll()
    }
}

/// An empty view behind kept inspector views; its frame is theirs, so it
/// finds the AppKit controls they hold.
final class InspectorAnchorView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The anchor's frame in window coordinates, a point wider on each side.
    private var area: CGRect { convert(bounds, to: nil).insetBy(dx: -1, dy: -1) }

    private func holds(_ view: NSView) -> Bool {
        view.window === window && view.enclosingScrollView === enclosingScrollView
            && area.contains(view.convert(view.bounds, to: nil))
    }

    func releaseControls() {
        guard let window else { return }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSTextField, holds(field) {
            field.abortEditing()
            if window.firstResponder !== window { window.makeFirstResponder(nil) }
        }
        if NSColorPanel.sharedColorPanelExists, let content = window.contentView {
            var wells: [NSColorWell] = []
            func visit(_ view: NSView) {
                if let well = view as? NSColorWell, well.isActive, holds(well) { wells.append(well) }
                view.subviews.forEach(visit)
            }
            visit(content)
            wells.forEach { $0.deactivate() }
        }
    }
}

struct InspectorAnchor: NSViewRepresentable {
    let kept: InspectorKeptViews
    func makeNSView(context: Context) -> InspectorAnchorView {
        let view = InspectorAnchorView()
        kept.anchor = view
        return view
    }
    func updateNSView(_ nsView: InspectorAnchorView, context: Context) {}
}

/// Sections (`SectionBox`) the user collapsed in kept inspector views. A
/// kept kind section's sections are also noted with the tab's, which expands
/// them when the whole tab is hidden.
@MainActor final class InspectorSectionExpansion {
    private var collapsed: [UUID: Binding<Bool>] = [:]
    weak var parent: InspectorSectionExpansion?

    func note(_ token: UUID, expanded: Bool, binding: Binding<Bool>) {
        collapsed[token] = expanded ? nil : binding
        parent?.note(token, expanded: expanded, binding: binding)
    }

    func forget(_ token: UUID) {
        collapsed[token] = nil
        parent?.forget(token)
    }

    func expandAll() {
        guard !collapsed.isEmpty else { return }
        let bindings = collapsed.values
        collapsed = [:]
        for binding in bindings { binding.wrappedValue = true }
    }
}

private struct InspectorSectionExpansionKey: EnvironmentKey {
    static let defaultValue: InspectorSectionExpansion? = nil
}

private struct InspectorKeptHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

private struct InspectorSectionHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The kept inspector views a `SectionBox` belongs to (R7 item 7).
    var inspectorSectionExpansion: InspectorSectionExpansion? {
        get { self[InspectorSectionExpansionKey.self] }
        set { self[InspectorSectionExpansionKey.self] = newValue }
    }

    /// Whether the kept Object tab is hidden (R7 item 7).
    var inspectorKeptHidden: Bool {
        get { self[InspectorKeptHiddenKey.self] }
        set { self[InspectorKeptHiddenKey.self] = newValue }
    }

    /// Whether the kept kind section around is hidden (R7 item 7).
    var inspectorSectionHidden: Bool {
        get { self[InspectorSectionHiddenKey.self] }
        set { self[InspectorSectionHiddenKey.self] = newValue }
    }
}
