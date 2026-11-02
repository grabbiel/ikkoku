import SwiftUI
import AppKit

// R7 item 7 follow-up C1: hiding a kept inspector view without disabling it.
// `inspectorHidden` disables a hidden kept view so its controls leave the Tab
// key-view loop, and disabling and enabling them again costs 6–9 ms of
// AppKit layout and SwiftUI graph update per deselect, select from nothing,
// undo or redo. In `container` mode each kept view is hosted in an AppKit
// view of its own, which is set hidden instead. AppKit leaves a hidden view
// and everything inside it out of the key-view loop and the accessibility
// tree, whatever SwiftUI builds there, and draws nothing.

/// How kept inspector views are hidden. `IKKOKU_PERF_KEPT_HIDING` is a
/// measurement control, read once at launch: `disabled` (the default) hides
/// them with `inspectorHidden` (zero height and opacity, no hits, disabled),
/// and `container` hosts each one in an `InspectorKeptContainerView` that is
/// set hidden.
enum StudioKeptHiding: String, Sendable {
    case disabled, container

    static let current: StudioKeptHiding =
        ProcessInfo.processInfo.environment["IKKOKU_PERF_KEPT_HIDING"].flatMap(Self.init(rawValue:)) ?? .disabled
}

extension View {
    /// Hides a kept inspector view the way `StudioKeptHiding.current` says.
    @ViewBuilder func inspectorKeptHiding(_ hidden: Bool) -> some View {
        switch StudioKeptHiding.current {
        case .disabled: inspectorHidden(hidden)
        case .container: InspectorKeptContainer(hidden: hidden, content: self)
        }
    }
}

/// Lets the content's geometry callback reach its container, which is made
/// after the content. It is not nested in the generic `InspectorKeptContainer`:
/// Swift 6.3.3 (Xcode 26.6, CI's Release build) crashes optimizing the deinit
/// of a class nested there.
final class InspectorKeptContainerCoordinator {
    weak var view: InspectorKeptContainerView?
}

/// A kept inspector view in its own hosting view. Shown, it has its
/// content's size at the proposed width. Hidden, it has zero height and its
/// content's width, at most the proposed width (as `inspectorHidden` reports),
/// so it takes no space and widens nothing; its content keeps its layout.
struct InspectorKeptContainer<Content: View>: NSViewRepresentable {
    let hidden: Bool
    let content: Content

    func makeCoordinator() -> InspectorKeptContainerCoordinator { InspectorKeptContainerCoordinator() }

    func makeNSView(context: Context) -> InspectorKeptContainerView {
        let view = InspectorKeptContainerView(rootView: root(context))
        context.coordinator.view = view
        view.update(rootView: nil, hidden: hidden)
        return view
    }

    func updateNSView(_ view: InspectorKeptContainerView, context: Context) {
        view.update(rootView: root(context), hidden: hidden)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: InspectorKeptContainerView, context: Context) -> CGSize? {
        view.size(proposedWidth: proposal.width)
    }

    /// The content in the inspector's environment (a nested hosting view
    /// starts from an empty one), at its own height, telling the container
    /// when that height changes inside it, as when a section collapses.
    private func root(_ context: Context) -> AnyView {
        let coordinator = context.coordinator
        return AnyView(
            content
                .environment(\.self, context.environment)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    coordinator.view?.contentSizeChanged(size)
                }
        )
    }
}

final class InspectorKeptContainerView: NSView {
    private let controller: NSHostingController<AnyView>
    /// The content's size at `measuredWidth`; nil when it must be measured again.
    private var measured: CGSize?
    private var measuredWidth: CGFloat = -1
    /// The content's size as it last reported it from inside.
    private var reported: CGSize?

    init(rootView: AnyView) {
        controller = NSHostingController(rootView: rootView)
        // The container sizes the hosting view; its content adds no constraints.
        controller.sizingOptions = []
        super.init(frame: .zero)
        let host = controller.view
        host.translatesAutoresizingMaskIntoConstraints = true
        addSubview(host)
        #if DEBUG
        InspectorKeptInvariant.register(self)
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The hosting view keeps its top at the container's top.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilityElement() -> Bool { false }
    /// A hidden container lists nothing, so no path into the accessibility
    /// tree reaches its content.
    override func accessibilityChildren() -> [Any]? { isHidden ? [] : super.accessibilityChildren() }

    /// Takes the content's new root (nil keeps it) and hides or shows the view.
    /// Before it hides, editing in it ends as removing it from the window
    /// did: a field being edited loses its field editor without the
    /// end-of-editing commit (`InspectorKeptViews.didHide` does the rest).
    func update(rootView: AnyView?, hidden: Bool) {
        if let rootView {
            controller.rootView = rootView
            if !isHidden { measured = nil }
        }
        guard hidden != isHidden else { return }
        if hidden { releaseFirstResponder() }
        isHidden = hidden
        if !hidden { measured = nil; needsLayout = true }
        #if DEBUG
        InspectorKeptInvariant.changed()
        #endif
    }

    /// The content's size at the proposed width; zero height while hidden.
    func size(proposedWidth: CGFloat?) -> CGSize {
        let width = proposedWidth ?? .greatestFiniteMagnitude
        if measured == nil || measuredWidth != width {
            measured = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            measuredWidth = width
        }
        let size = measured ?? .zero
        return isHidden ? CGSize(width: min(size.width, width), height: 0) : size
    }

    override func layout() {
        super.layout()
        guard !isHidden else { return }
        let height = max(bounds.height, measured?.height ?? 0)
        controller.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
    }

    /// The content's own size changed inside it (a section collapsed, a
    /// field wrapped): measure again.
    func contentSizeChanged(_ size: CGSize) {
        // Only a change from the last report: a layout this causes reports
        // the same size again, which must not start another.
        guard size != reported else { return }
        reported = size
        guard let measured, abs(size.height - measured.height) > 0.5 || abs(size.width - measured.width) > 0.5 else { return }
        self.measured = nil
        guard !isHidden else { return }
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    private func releaseFirstResponder() {
        guard let window else { return }
        let responder = window.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSTextField, field.isDescendant(of: self) {
            field.abortEditing()
            if window.firstResponder !== window { window.makeFirstResponder(nil) }
        } else if let view = responder as? NSView, view.isDescendant(of: self) {
            window.makeFirstResponder(nil)
        }
    }
}

#if DEBUG
/// Debug builds check, after every main run-loop turn in which a kept
/// container was hidden or shown, that nothing inside a hidden one can take
/// the keyboard or be reached by accessibility: no view in the key-view loop,
/// not the first responder, and no accessibility element.
@MainActor enum InspectorKeptInvariant {
    private static let containers = NSHashTable<InspectorKeptContainerView>.weakObjects()
    private static var dirty = false
    private static var observer: CFRunLoopObserver?

    static func register(_ view: InspectorKeptContainerView) {
        containers.add(view)
        guard observer == nil else { return }
        let created = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1) { _, _ in
            MainActor.assumeIsolated { check() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        observer = created
    }

    static func changed() { dirty = true }

    private static func check() {
        guard dirty else { return }
        dirty = false
        let hidden = containers.allObjects.filter { $0.isHidden && $0.window != nil }
        for group in Dictionary(grouping: hidden, by: { ObjectIdentifier($0.window!) }).values {
            guard let window = group.first?.window else { continue }
            check(window, hidden: group)
        }
    }

    private static func check(_ window: NSWindow, hidden: [InspectorKeptContainerView]) {
        func inside(_ view: NSView) -> Bool { hidden.contains { view.isDescendant(of: $0) } }

        // The key-view loop as AppKit walks it (a query: nothing moves).
        var seen = Set<ObjectIdentifier>()
        var next = window.contentView?.nextValidKeyView
        while let view = next, seen.count < 2_000, seen.insert(ObjectIdentifier(view)).inserted {
            assert(!inside(view), "a view in a hidden kept inspector view is in the key-view loop: \(view)")
            next = view.nextValidKeyView
        }

        // The first responder, or the field whose editor it is.
        var responder = window.firstResponder as? NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { responder = field }
        if let responder { assert(!inside(responder), "the first responder is in a hidden kept inspector view: \(responder)") }

        // Every accessibility element, by its nearest view. The getters are
        // called by selector: SwiftUI's elements implement them without being
        // `NSAccessibilityProtocol` values to Swift.
        var visited = 0
        func get(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func nearestView(_ object: NSObject) -> NSView? {
            var current: NSObject? = object
            for _ in 0..<80 {
                guard let element = current else { return nil }
                if let view = element as? NSView { return view }
                current = get(element, "accessibilityParent") as? NSObject
            }
            return nil
        }
        func visit(_ element: Any, depth: Int) {
            guard depth < 80, visited < 20_000, let object = element as? NSObject else { return }
            visited += 1
            if let view = nearestView(object) {
                assert(!inside(view), "an accessibility element of a hidden kept inspector view is reachable: \(object)")
            }
            for child in get(object, "accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
    }
}
#endif
