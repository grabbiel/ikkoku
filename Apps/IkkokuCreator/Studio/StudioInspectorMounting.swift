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

/// Lays out the one shown view of several kept ones. The container takes the
/// shown view's size and spacing; every view is placed at the same origin
/// with the proposal the container had, so a hidden view keeps the layout it
/// had when it was last shown.
struct InspectorSwapLayout: Layout {
    private func shown(_ subviews: Subviews) -> LayoutSubview? {
        subviews.first { !$0[InspectorHiddenKey.self] }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        shown(subviews)?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, anchor: .topLeading, proposal: proposal) }
    }

    func spacing(subviews: Subviews, cache: inout ()) -> ViewSpacing {
        shown(subviews)?.spacing ?? ViewSpacing()
    }
}

struct InspectorHiddenKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Hides a kept inspector view inside an `InspectorSwapLayout`. At zero
    /// opacity SwiftUI does not draw it and leaves it out of the accessibility
    /// tree; disabled, its controls leave the Tab key-view loop and refuse
    /// focus. (`accessibilityHidden(false)` is not used for the shown state:
    /// it exposes elements a view hides itself, such as the placeholder's
    /// image.) Picker labels need `inspectorKeptLabel()` as well.
    func inspectorHidden(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .disabled(hidden)
            .layoutValue(key: InspectorHiddenKey.self, value: hidden)
    }

    /// Sets whether the kept views below are hidden, for the labels that
    /// read it; a view hidden by an outer kept view stays hidden.
    func inspectorKeptHidden(_ hidden: Bool) -> some View {
        transformEnvironment(\.inspectorKeptHidden) { $0 = $0 || hidden }
    }

    /// A Picker's label in kept inspector views. SwiftUI keeps a Picker's
    /// label in the accessibility tree at zero opacity, so the label hides
    /// itself while its views are hidden.
    func inspectorKeptLabel() -> some View { modifier(InspectorKeptLabel()) }
}

private struct InspectorKeptLabel: ViewModifier {
    @Environment(\.inspectorKeptHidden) private var hidden
    func body(content: Content) -> some View { content.accessibilityHidden(hidden) }
}

/// What a kept inspector view holds besides its views: the last state it
/// showed, an empty AppKit view behind it, and the sections the user
/// collapsed in it.
@MainActor final class InspectorKeptViews<Shown> {
    var state: Shown?
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

struct InspectorAnchor<Shown>: NSViewRepresentable {
    let kept: InspectorKeptViews<Shown>
    func makeNSView(context: Context) -> InspectorAnchorView {
        let view = InspectorAnchorView()
        kept.anchor = view
        return view
    }
    func updateNSView(_ nsView: InspectorAnchorView, context: Context) {}
}

/// Sections (`SectionBox`) the user collapsed in kept inspector views.
@MainActor final class InspectorSectionExpansion {
    private var collapsed: [UUID: Binding<Bool>] = [:]

    func note(_ token: UUID, expanded: Bool, binding: Binding<Bool>) {
        collapsed[token] = expanded ? nil : binding
    }

    func forget(_ token: UUID) { collapsed[token] = nil }

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

extension EnvironmentValues {
    /// The kept inspector views a `SectionBox` belongs to (R7 item 7).
    var inspectorSectionExpansion: InspectorSectionExpansion? {
        get { self[InspectorSectionExpansionKey.self] }
        set { self[InspectorSectionExpansionKey.self] = newValue }
    }

    /// Whether the kept inspector views around are hidden (R7 item 7).
    var inspectorKeptHidden: Bool {
        get { self[InspectorKeptHiddenKey.self] }
        set { self[InspectorKeptHiddenKey.self] = newValue }
    }
}
