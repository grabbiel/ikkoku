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
    /// otherwise widen the stack and move what is shown.
    ///
    /// On macOS 15 and later it stays drawn at full opacity, clipped to that
    /// zero-height frame (#440): at zero opacity SwiftUI added a hidden view's
    /// AppKit controls to their superview again on every show (they stayed in
    /// the view tree while hidden), and each re-add left AppKit observers and
    /// dependencies that were never freed. Clipped, they are not added again
    /// and nothing of them is drawn. Shown, the clip
    /// is the frame grown by `InspectorKeptClip.outset` on every side, so
    /// focus rings and shadows drawn outside the frame are not cut.
    /// Accessibility is hidden explicitly while hidden and left untouched
    /// while shown (`accessibilityHidden(false)` would expose elements a view
    /// hides itself, such as the placeholder's image). Disabled, its controls
    /// leave the Tab key-view loop and refuse focus. Picker labels need
    /// `inspectorKeptLabel()` too. One modifier chain for both states: only
    /// values change, so hiding never changes the view's identity. macOS 14
    /// keeps the zero-opacity chain, and with it #440's growth.
    @ViewBuilder func inspectorHidden(_ hidden: Bool) -> some View {
        // `accessibilityHidden(_:isEnabled:)` needs macOS 15, and the app's
        // deployment target is 14.6. The branch is constant for the process,
        // so a view never moves from one chain to the other and nothing
        // remounts; macOS 14 keeps the chain it had before #440's fix.
        if #available(macOS 15, *) {
            fixedSize(horizontal: false, vertical: true)
                .frame(height: hidden ? 0 : nil, alignment: .top)
                // A minimum alone makes the frame min(child, proposal) wide, with
                // the child laid out at the proposal as before; with no minimum
                // the frame takes the child's size.
                .frame(minWidth: hidden ? 0 : nil, alignment: .topLeading)
                .clipShape(InspectorKeptClip(hidden: hidden), style: FillStyle(antialiased: false))
                .accessibilityHidden(true, isEnabled: hidden)
                .allowsHitTesting(!hidden)
                .disabled(hidden)
        } else {
            fixedSize(horizontal: false, vertical: true)
                .frame(height: hidden ? 0 : nil, alignment: .top)
                .frame(minWidth: hidden ? 0 : nil, alignment: .topLeading)
                .opacity(hidden ? 0 : 1)
                .allowsHitTesting(!hidden)
                .disabled(hidden)
        }
    }

    /// A Picker's label in kept inspector views: the label hides itself while
    /// its views are hidden (SwiftUI kept it in the accessibility tree when
    /// hidden views were drawn at zero opacity).
    func inspectorKeptLabel() -> some View { modifier(InspectorKeptLabel()) }
}

/// The clip of a kept inspector view (`inspectorHidden`). Hidden, it is the
/// zero-height frame itself, the rectangle `.clipped()` clips to; shown, the
/// frame grown by `outset` on every side, past anything a shown view draws
/// outside its frame. Both are rectangles, never an empty path.
struct InspectorKeptClip: Shape {
    var hidden: Bool
    static let outset: CGFloat = 256

    func path(in rect: CGRect) -> Path {
        Path(hidden ? rect : rect.insetBy(dx: -Self.outset, dy: -Self.outset))
    }
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
    /// Whether the kept views in front of it are hidden (`inspectorKeptHidden`
    /// or `inspectorSectionHidden`, as `StudioParentPopUp` reads them). Read
    /// only by the inspector UI scenario's `keptControls` (#440).
    var keptHidden = false

    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The anchor's frame in window coordinates, a point wider on each side.
    private var area: CGRect { convert(bounds, to: nil).insetBy(dx: -1, dy: -1) }

    func holds(_ view: NSView) -> Bool {
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
    func updateNSView(_ nsView: InspectorAnchorView, context: Context) {
        nsView.keptHidden = context.environment.inspectorKeptHidden || context.environment.inspectorSectionHidden
    }
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

/// #366: the inspector's text fields at their own heights. On a selection
/// change SwiftUI sometimes gave one text field the measured height of another
/// (the Name field the Transform fields' height, or the reverse), and every row
/// below it moved. An explicit height keeps each one. Each height is measured
/// once from an AppKit text field with the same bezel and font as SwiftUI's
/// field: the automatic style draws the square bezel, `.roundedBorder` the
/// rounded one.
@MainActor
enum InspectorTextFieldHeight {
    /// SwiftUI's automatic style at the body font. The Name field no longer
    /// lays out with it: it is `InspectorNameField`, which sizes itself. The
    /// fit log reports this height so the object-heights check can compare it
    /// with the Name field's own height: the AppKit field must stay as tall as
    /// the SwiftUI field it replaced.
    static let name = measured(.squareBezel, .body)
    /// VectorRow's fields: `.roundedBorder` at the caption font.
    static let vector = measured(.roundedBezel, .caption1)

    private static func measured(_ bezel: NSTextField.BezelStyle, _ style: NSFont.TextStyle) -> CGFloat {
        let field = NSTextField(string: "")
        field.isBezeled = true
        field.bezelStyle = bezel
        field.font = .preferredFont(forTextStyle: style)
        return field.intrinsicContentSize.height
    }
}

/// #366: the Object tab's Name field as an AppKit text field that SwiftUI
/// sizes by asking it. With SwiftUI's `TextField`, a selection change
/// sometimes laid the field out at the Transform fields' measured height
/// (21 pt inside its 24 pt slot), even with an explicit frame. Here
/// `sizeThatFits` returns the field's own intrinsic height for any proposal,
/// so no other field's height can reach it. The field matches SwiftUI's
/// automatic style: square bezel, body font, one line, placeholder "Name"
/// (the fit log and the inspector-UI scenario ops find the field by it).
/// Every keystroke writes the binding, as `TextField` does, so the undo
/// coalescing (#390) sees the same writes.
struct InspectorNameField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "Name"
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.font = .preferredFont(forTextStyle: .body)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // The binding names the shown object; a kept view must not write to an earlier one.
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let intrinsic = field.intrinsicContentSize
        return CGSize(width: proposal.width ?? max(intrinsic.width, 0), height: intrinsic.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InspectorNameField
        init(_ parent: InspectorNameField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}
