import SwiftUI
import AppKit
import Studio

/// The Object tab's Parent control (#383). A SwiftUI `Picker` sizes itself to
/// its widest option. With an option per object (3,768 on the corpus scene),
/// every inspector update measured all of their names again (CoreText
/// typesetting under `FlexibleButtonFrameLayout`, 209-225 ms of text metrics
/// per select, Duplicate or Undo, also while the tab was kept hidden). This
/// popup holds only the current parent until it opens. Its options are then
/// built from the document as it is, in the Picker's order and with its
/// filter: None, then every object that is not this one and not one of its
/// descendants, in document order. A choice makes the Picker's call, under
/// the same check that the object is still the selection.
struct StudioParentPopUp: NSViewRepresentable {
    let model: StudioModel
    let id: UUID
    let parent: UUID?
    /// "None", or the parent's name.
    let title: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.menu?.delegate = context.coordinator
        button.setAccessibilityLabel("Parent")
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.id = id
        coordinator.parent = parent
        coordinator.title = title
        coordinator.showCurrent(in: button)
        // Kept hidden (`inspectorHidden`): disabled, out of the
        // accessibility tree and hidden, as the Picker's popup was.
        let hidden = context.environment.inspectorKeptHidden || context.environment.inspectorSectionHidden
        button.isEnabled = context.environment.isEnabled
        button.isHidden = hidden
        button.setAccessibilityElement(!hidden)
    }

    /// The size of the current parent's title, never of the options: the
    /// popup is measured with one item, and only that size is reported.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let ideal = context.coordinator.idealSize
        guard let width = proposal.width, width.isFinite else { return ideal }
        return CGSize(width: min(ideal.width, width), height: ideal.height)
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        weak var model: StudioModel?
        weak var button: NSPopUpButton?
        var id: UUID?
        var parent: UUID?
        var title = ""
        private(set) var idealSize = CGSize.zero

        /// One item, the current parent, unless that is what it shows.
        func showCurrent(in button: NSPopUpButton) {
            if button.numberOfItems == 1, let item = button.item(at: 0), item.title == title,
               item.representedObject as? UUID == parent { return }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = parent
            button.menu?.items = [item]
            button.select(item)
            idealSize = button.intrinsicContentSize
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let model, let id else { return }
            let doc = model.doc
            let lookup = StudioDocument.Lookup(doc.objects)
            var items = [NSMenuItem(title: "None", action: nil, keyEquivalent: "")]
            for o in doc.objects where o.id != id && !lookup.isDescendant(o.id, of: id) {
                let item = NSMenuItem(title: o.name, action: nil, keyEquivalent: "")
                item.representedObject = o.id
                items.append(item)
            }
            menu.items = items
            popUp(of: menu)?.select(items.first { $0.representedObject as? UUID == parent })
        }

        /// No key equivalents: without this, NSMenu builds the options to
        /// look for one on key presses.
        func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                                  action: UnsafeMutablePointer<Selector?>) -> Bool { false }

        func menuDidClose(_ menu: NSMenu) {
            // Back to the one item after the choice's action has been sent.
            DispatchQueue.main.async { [weak self] in
                guard let self, let button = self.popUp(of: menu) else { return }
                self.showCurrent(in: button)
            }
        }

        @objc func choose(_ sender: NSPopUpButton) {
            let chosen = sender.selectedItem?.representedObject as? UUID
            guard let model, let id, model.selection == id else { return }
            model.setParent(id, to: chosen)
        }

        private func popUp(of menu: NSMenu) -> NSPopUpButton? { button?.menu === menu ? button : nil }
    }
}
