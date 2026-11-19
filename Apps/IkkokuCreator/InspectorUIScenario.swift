import Foundation
import AppKit
import SwiftUI
import CryptoKit
import Character
import Studio

/// R7 phase 2, item 7: Object-tab checks that need the real window, entered
/// through the Studio scenario mode (`{"steps": [], "inspectorUI": {"steps": [...]}}`).
/// The checklist runner works on `StudioModel` alone; these steps act on the
/// SwiftUI inspector as AppKit sees it: they focus its text fields and type
/// into the field editor, change the selection while a field is being edited,
/// and read the accessibility tree and the Tab key-view loop. Every step
/// starts a new undo gesture (`endUndoCoalescing`) and waits for SwiftUI to
/// commit it, so each state is the one a user would reach click by click.
struct InspectorUIScenario: Decodable {
    struct Step: Decodable {
        /// `"select"` (`key`), `"deselect"`, `"focus"` (`field`), `"type"` (`text`, `replace`),
        /// `"delete"` (`key`: selects it, then deletes the selection), `"undo"`, `"redo"`,
        /// `"cycle"` (`keys`, `count`: selects each key in turn, -1 deselects),
        /// `"snapshot"` (keeps the document and the undo depths for `unchanged`),
        /// `"keyLoop"` (walks the Tab key-view loop) and `"assert"`. Added with the
        /// kept views: `"probe"` (`field`: remembers that field and its centre),
        /// `"press"` (`label`: presses the accessibility element with that label or
        /// title, a section's disclosure triangle), `"activateWell"` (activates the
        /// inspector's first visible colour well), `"routePoint"` (`index`: selects
        /// that point of the selected route) and `"closeColorPanel"`. Added for
        /// #333: `"tab"` (`label`: shows that inspector tab, such as `clothes`) and
        /// `"addCharacter"` (`sex`: `female` or `male`; the toolbar's Add ▸ Character,
        /// which adds a native character and selects it). Added for #383:
        /// `"parentMenu"` (the Parent popup: closed it holds only the current parent;
        /// opened, its options are the Picker's, None and then every object that is not
        /// the selection or one of its descendants, in document order; with `key`, it
        /// chooses that source key's object, or None for -1, and the document's parent
        /// follows). Added for #410: `"selectRow"` (`index`: selects the object at that
        /// workspace row) and `"scrollWorkspace"` (`toEnd`: scrolls the workspace to
        /// the end of its rows, or back to the top).
        let op: String
        let key: Int32?
        let keys: [Int32]?
        let count: Int?
        /// `"name"` or `"vectorN"`: the N-th number field of the Transform rows
        /// (position x, y, z, rotation x, y, z, scale x, y, z).
        let field: String?
        let text: String?
        /// type: replace the field's text instead of appending to it.
        let replace: Bool?
        let label: String?
        let index: Int?
        let sex: String?
        // assert only; an absent key is not checked.
        let name: String?
        let positionX: Float?
        let exists: Bool?
        let undoCount: Int?
        let redoCount: Int?
        /// The document and undo depths equal the last `snapshot`.
        let unchanged: Bool?
        /// The first responder is a text field's field editor.
        let editing: Bool?
        let inspectorView: String?
        /// Strings some accessibility element in the window must, or must not, carry
        /// as its label, title or value.
        let axContains: [String]?
        let axAbsent: [String]?
        /// keyLoop only: how many key views in the loop may lie outside the visible window,
        /// and how many views the loop must have.
        let hiddenKeyViews: Int?
        let keyViews: Int?
        /// assert with `field`: the text that visible field shows.
        let fieldText: String?
        /// How many colour wells in the window are active.
        let activeWells: Int?
        /// Whether a click at the probed field's centre reaches that field, and
        /// whether it can become the first responder (a refused attempt changes
        /// nothing; an accepted one is undone with no first responder).
        let probeHit: Bool?
        let probeFocusable: Bool?
        // Added for #333 (the Clothes tab laid out wider than the inspector).
        /// Whether everything in the inspector's scroll view lies within its
        /// visible width: see `inspectorFit(_:)`.
        let inspectorFits: Bool?
        // Added for #410 (the workspace stack keeps empty slots).
        /// Whether every fully visible workspace row keeps the stack's
        /// geometry and the empty slots add nothing: see
        /// `workspaceGeometry(_:studio:)`.
        let workspaceGeometry: Bool?
        /// `scrollWorkspace`: to the end (true) or the top (false).
        let toEnd: Bool?
    }

    let steps: [Step]

    /// Waits up to this long for the window and the inspector.
    static let windowTimeout: Double = 30
    /// Each step's settle time: enough run-loop turns for SwiftUI to commit a selection.
    static let settleNanoseconds: UInt64 = 300_000_000

    @MainActor func run(studio: StudioModel) async -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = []
        func record(_ op: String, _ ok: Bool, _ detail: String) { rows.append(.init(op: op, ok: ok, detail: detail)) }
        func report() -> StudioScenario.Report {
            let failed = rows.filter { !$0.ok }.count
            return .init(steps: rows, passed: rows.count - failed, failed: failed)
        }
        func settle() async { try? await Task.sleep(nanoseconds: Self.settleNanoseconds) }

        var window: NSWindow?
        let start = Date()
        while Date().timeIntervalSince(start) < Self.windowTimeout {
            window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.isKeyWindow }
                ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil }
            if window != nil, studio.displayedInspectorView != nil { break }
            await settle()
        }
        guard let window else {
            record("window", false, "no visible window after \(Self.windowTimeout) s")
            return report()
        }
        window.makeKeyAndOrderFront(nil)
        await settle()
        record("window", true, "window \(Int(window.frame.width))x\(Int(window.frame.height)) pt")

        func object(_ key: Int32?) -> StudioObject? {
            guard let key else { return nil }
            return studio.doc.flattened().map(\.object).first { $0.sourceObjectKey == key }
        }
        var snapshot: (doc: StudioDocument, undo: Int, redo: Int)?
        var probe: (field: NSTextField, center: CGPoint)?

        for step in steps {
            studio.endUndoCoalescing()
            switch step.op {
            case "select":
                guard let id = object(step.key)?.id else { record(step.op, false, "no object with source key \(step.key ?? -1)"); continue }
                studio.selection = id
                await settle()
                record(step.op, true, "selected source key \(step.key!)")
            case "deselect":
                studio.selection = nil
                await settle()
                record(step.op, true, "selection cleared")
            case "focus":
                guard let fieldName = step.field, let field = Self.textField(fieldName, in: window) else {
                    record(step.op, false, "no visible field '\(step.field ?? "")' in the inspector"); continue
                }
                let ok = window.makeFirstResponder(field)
                await settle()
                record(step.op, ok && Self.editedField(window) === field, "focused \(fieldName) ('\(field.stringValue)')")
            case "type":
                guard let editor = window.firstResponder as? NSTextView, let text = step.text else {
                    record(step.op, true, "nothing to type into: the first responder is \(Self.describe(window.firstResponder))"); continue
                }
                if step.replace == true { editor.selectAll(nil) } else { editor.moveToEndOfDocument(nil) }
                editor.insertText(text, replacementRange: editor.selectedRange())
                await settle()
                record(step.op, true, "typed '\(text)' into \(Self.describe(window.firstResponder)): '\(editor.string)'")
            case "delete":
                guard let id = object(step.key)?.id else { record(step.op, false, "no object with source key \(step.key ?? -1)"); continue }
                studio.selection = id
                await settle()
                studio.endUndoCoalescing()
                studio.deleteSelection()
                await settle()
                let gone = studio.doc.object(id) == nil
                record(step.op, gone, gone ? "deleted source key \(step.key!)" : "source key \(step.key!) is still in the document")
            case "undo":
                studio.undo()
                await settle()
                record(step.op, true, studio.status)
            case "redo":
                studio.redo()
                await settle()
                record(step.op, true, studio.status)
            case "cycle":
                let keys = step.keys ?? [], count = step.count ?? 1
                var missing: [Int32] = []
                for _ in 0..<count {
                    for key in keys {
                        studio.endUndoCoalescing()
                        if key < 0 { studio.selection = nil } else if let id = object(key)?.id { studio.selection = id } else { missing.append(key) }
                        await settle()
                    }
                }
                record(step.op, missing.isEmpty, "\(count) cycles over \(keys)" + (missing.isEmpty ? "" : "; missing \(missing)"))
            case "probe":
                guard let fieldName = step.field, let field = Self.textField(fieldName, in: window) else {
                    record(step.op, false, "no visible field '\(step.field ?? "")' in the inspector"); continue
                }
                let frame = field.convert(field.bounds, to: nil)
                probe = (field, CGPoint(x: frame.midX, y: frame.midY))
                record(step.op, true, "probed \(fieldName) at \(Int(frame.midX)),\(Int(frame.midY))")
            case "press":
                guard let label = step.label, let element = Self.accessibilityElement(label, in: window) else {
                    record(step.op, false, "no accessibility element labelled '\(step.label ?? "")'"); continue
                }
                _ = element.object.perform(NSSelectorFromString("accessibilityPerformPress"))
                await settle()
                record(step.op, true, "pressed \(element.role) '\(label)'")
            case "activateWell":
                guard let well = Self.colorWells(in: window).first(where: { !$0.visibleRect.isEmpty && $0.isEnabled }) else {
                    record(step.op, false, "no visible colour well"); continue
                }
                well.activate(true)
                await settle()
                record(step.op, well.isActive, "colour well active \(well.isActive)")
            case "selectRow":
                let entries = studio.shownWorkspaceState.entries
                guard let index = step.index, entries.indices.contains(index) else {
                    record(step.op, false, "no workspace row \(step.index ?? -1) of \(entries.count)"); continue
                }
                studio.selection = entries[index].id
                await settle()
                record(step.op, true, "selected workspace row \(index)")
            case "scrollWorkspace":
                guard let scroll = Self.workspaceScrollView(window), let document = scroll.documentView else {
                    record(step.op, false, "no workspace scroll view"); continue
                }
                // The lazy stack may correct the document's height once it lays
                // out what the scroll shows, so scroll again until it holds.
                let toEnd = step.toEnd ?? true
                var heights: [Int] = []
                for _ in 0..<4 {
                    let height = document.frame.height
                    Self.scrollWorkspace(scroll, toEnd: toEnd)
                    await settle()
                    heights.append(Int(document.frame.height))
                    if document.frame.height == height { break }
                }
                record(step.op, true, "workspace scrolled to the \(toEnd ? "end" : "top") in \(heights.count) scrolls, "
                       + "document \(heights.map(String.init).joined(separator: " > ")) pt")
            case "routePoint":
                guard let index = step.index else { record(step.op, false, "no index"); continue }
                studio.selectedRoutePoint = .init(index: index)
                await settle()
                record(step.op, true, "route point \(index)")
            case "outfit":
                // The Clothes tab's outfit picker on the selected source
                // character; waits until its build has finished.
                guard let index = step.index, let id = studio.selection, let before = studio.sourceShapePreview(for: id)?.coordinate else {
                    record(step.op, false, "no index, or the selection is not a built source character"); continue
                }
                studio.selectSourceOutfit(id, coordinate: index)
                let deadline = Date().addingTimeInterval(Self.windowTimeout)
                repeat { await settle() } while studio.pendingSourceOutfits[id] != nil && Date() < deadline
                let after = studio.sourceShapePreview(for: id)?.coordinate
                record(step.op, after == index, "outfit \(before) to \(index): shows \(after.map { "\($0)" } ?? "none")")
            case "tab":
                guard let label = step.label?.lowercased(),
                      let tab = StudioModel.InspectorTab.allCases.first(where: { $0.rawValue.lowercased() == label }) else {
                    record(step.op, false, "no inspector tab '\(step.label ?? "")'"); continue
                }
                studio.inspectorTab = tab
                await settle()
                record(step.op, true, "inspector tab \(tab.rawValue)")
            case "addCharacter":
                guard let sex = ["female": Sex.female, "male": Sex.male][step.sex ?? ""] else {
                    record(step.op, false, "addCharacter: sex must be \"female\" or \"male\""); continue
                }
                let before = Set(studio.doc.objects.map(\.id))
                studio.addCharacter(sex: sex)
                await settle()
                guard let added = studio.doc.objects.first(where: { !before.contains($0.id) }), added.kind == .character,
                      added.sourceCharacter == nil, studio.selection == added.id else {
                    record(step.op, false, "addCharacter: no new selected native character: \(studio.status)"); continue
                }
                record(step.op, true, "added native \(step.sex!) character \"\(added.name)\"")
            case "parentMenu":
                guard let id = studio.selection, let popup = Self.parentPopUp(in: window), let menu = popup.menu else {
                    record(step.op, false, "no selection or no visible Parent popup"); continue
                }
                var problems: [String] = []
                let doc = studio.doc
                let current = doc.object(id)?.parent
                let title = current.map { doc.object($0)?.name ?? "" } ?? "None"
                if popup.numberOfItems != 1 || popup.titleOfSelectedItem != title {
                    problems.append("closed: \(popup.numberOfItems) items, title '\(popup.titleOfSelectedItem ?? "-")', expected 1 item '\(title)'")
                }
                // What AppKit asks the delegate when the menu opens.
                menu.delegate?.menuNeedsUpdate?(menu)
                // The SwiftUI Picker's options, by the document's linear functions.
                let options = doc.objects.filter { $0.id != id && !doc.isDescendant($0.id, of: id) }
                let ids = menu.items.map { $0.representedObject as? UUID }
                if menu.items.map(\.title) != ["None"] + options.map(\.name) || ids != [nil] + options.map(\.id) {
                    problems.append("opened: \(menu.items.count) options, expected \(options.count + 1) in document order")
                }
                if (popup.selectedItem?.representedObject as? UUID) != current { problems.append("opened: the current parent is not the selected option") }
                var chose = ""
                if let key = step.key {
                    let target: UUID? = key < 0 ? nil : object(key)?.id
                    if let item = menu.items.first(where: { ($0.representedObject as? UUID) == target }), key < 0 || target != nil {
                        popup.select(item)
                        _ = popup.sendAction(popup.action, to: popup.target)
                        chose = ", chose '\(item.title)'"
                    } else { problems.append("no option for source key \(key)") }
                }
                menu.delegate?.menuDidClose?(menu)
                await settle()
                let after = studio.doc.object(id)?.parent
                if let key = step.key, after != (key < 0 ? nil : object(key)?.id) {
                    problems.append("parent after the choice is not source key \(key): \(studio.status)")
                }
                let afterTitle = after.map { studio.doc.object($0)?.name ?? "" } ?? "None"
                if popup.numberOfItems != 1 || popup.titleOfSelectedItem != afterTitle {
                    problems.append("closed again: \(popup.numberOfItems) items, title '\(popup.titleOfSelectedItem ?? "-")', expected 1 item '\(afterTitle)'")
                }
                record(step.op, problems.isEmpty, (problems + ["\(options.count + 1) options\(chose), parent '\(afterTitle)'"]).joined(separator: "; "))
            case "closeColorPanel":
                if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
                await settle()
                record(step.op, true, "colour panel closed")
            case "snapshot":
                snapshot = (studio.doc, studio.undoStack.count, studio.redoStack.count)
                record(step.op, true, "undo \(studio.undoStack.count), redo \(studio.redoStack.count)")
            case "keyLoop":
                // Each Tab is its own gesture, as each step is, and the views
                // re-render before the next one (#390).
                let loop = await Self.keyLoop(window, beforeEachMove: { studio.endUndoCoalescing() }, afterEachMove: { await settle() })
                let ok = (step.hiddenKeyViews.map { loop.hidden <= $0 } ?? true) && (step.keyViews.map { loop.views.count == $0 } ?? true)
                record(step.op, ok, "\(loop.views.count) key views, \(loop.hidden) outside the visible window, sha \(loop.sha): " + loop.views.joined(separator: " > "))
            case "assert":
                var problems: [String] = []
                let target = object(step.key)
                let editedField = Self.editedField(window)
                let ax = Self.accessibilityStrings(window)
                var seen: [String] = []
                if let target { seen.append("name '\(target.name)'"); seen.append("position.x \(target.transform.position.x)") }
                seen.append("undo \(studio.undoStack.count)"); seen.append("redo \(studio.redoStack.count)")
                seen.append("editing \(editedField.map { Self.describe($0) } ?? "none")")
                seen.append("inspector \(studio.displayedInspectorView ?? "nil")")
                seen.append("ax \(ax.count) strings, sha \(Self.sha(ax.sorted()))")
                if let exists = step.exists, exists != (target != nil) { problems.append("exists \(target != nil), expected \(exists)") }
                if let name = step.name, target?.name != name { problems.append("name '\(target?.name ?? "-")', expected '\(name)'") }
                if let x = step.positionX {
                    if let actual = target?.transform.position.x {
                        if abs(actual - x) > StudioScenario.tolerance { problems.append("position.x \(actual), expected \(x)") }
                    } else { problems.append("no object for position.x") }
                }
                if let n = step.undoCount, n != studio.undoStack.count { problems.append("undo \(studio.undoStack.count), expected \(n)") }
                if let n = step.redoCount, n != studio.redoStack.count { problems.append("redo \(studio.redoStack.count), expected \(n)") }
                if step.unchanged == true {
                    if let snapshot {
                        if snapshot.doc != studio.doc { problems.append("document changed since the snapshot") }
                        if snapshot.undo != studio.undoStack.count || snapshot.redo != studio.redoStack.count {
                            problems.append("undo/redo \(studio.undoStack.count)/\(studio.redoStack.count), snapshot \(snapshot.undo)/\(snapshot.redo)")
                        }
                    } else { problems.append("no snapshot") }
                }
                if let editing = step.editing, editing != (editedField != nil) { problems.append("editing \(editedField != nil), expected \(editing)") }
                if let view = step.inspectorView, view != studio.displayedInspectorView { problems.append("inspector \(studio.displayedInspectorView ?? "nil"), expected \(view)") }
                for text in step.axContains ?? [] where !ax.contains(where: { $0.contains(text) }) { problems.append("no accessibility element shows '\(text)'") }
                for text in step.axAbsent ?? [] where ax.contains(where: { $0.contains(text) }) { problems.append("an accessibility element shows '\(text)'") }
                if let expected = step.fieldText {
                    if let fieldName = step.field, let field = Self.textField(fieldName, in: window) {
                        // Reading a field being edited would validate it, so read its field editor.
                        let shown = field === editedField ? (window.firstResponder as? NSTextView)?.string ?? "" : field.stringValue
                        seen.append("\(fieldName) shows '\(shown)'")
                        if shown != expected { problems.append("\(fieldName) shows '\(shown)', expected '\(expected)'") }
                    } else { problems.append("no visible field '\(step.field ?? "")'") }
                }
                let wells = Self.colorWells(in: window).filter(\.isActive).count
                seen.append("active wells \(wells)")
                if let n = step.activeWells, n != wells { problems.append("active wells \(wells), expected \(n)") }
                if let expected = step.inspectorFits {
                    let fit = Self.inspectorFit(window)
                    seen.append(fit.detail)
                    if expected != fit.fits { problems.append("inspector fits \(fit.fits), expected \(expected)") }
                }
                if let expected = step.workspaceGeometry {
                    let geometry = Self.workspaceGeometry(window, studio: studio)
                    seen.append(geometry.detail)
                    if expected != geometry.ok { problems.append("workspace geometry \(geometry.ok), expected \(expected)") }
                }
                if step.probeHit != nil || step.probeFocusable != nil {
                    if let probe, let content = window.contentView {
                        let hit = content.hitTest(content.superview?.convert(probe.center, from: nil) ?? probe.center)
                        let reaches = hit.map { $0 === probe.field || $0.isDescendant(of: probe.field) } ?? false
                        seen.append("probe hit \(hit.map { Self.describe($0) } ?? "nil")")
                        if let expected = step.probeHit, expected != reaches { problems.append("probe hit \(reaches), expected \(expected)") }
                        if let expected = step.probeFocusable {
                            let focused = window.makeFirstResponder(probe.field) && Self.editedField(window) === probe.field
                            seen.append("probe focusable \(focused)")
                            if focused { window.makeFirstResponder(nil) }
                            if expected != focused { problems.append("probe focusable \(focused), expected \(expected)") }
                        }
                    } else { problems.append("no probe") }
                }
                if !problems.isEmpty, step.axContains != nil || step.axAbsent != nil { seen.append("ax strings: " + ax.joined(separator: " | ")) }
                record(step.op, problems.isEmpty, (problems + ["seen: " + seen.joined(separator: ", ")]).joined(separator: "; "))
            default:
                record(step.op, false, "unknown op")
            }
        }
        return report()
    }

    // MARK: AppKit reads

    /// The visible, editable and enabled text fields under `view`, top to bottom,
    /// then left to right. Kept, hidden inspector views are disabled.
    @MainActor static func visibleTextFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        func visit(_ v: NSView) {
            if let field = v as? NSTextField, field.isEditable, field.isEnabled, !field.isHiddenOrHasHiddenAncestor, !field.visibleRect.isEmpty {
                found.append(field)
            }
            v.subviews.forEach(visit)
        }
        visit(view)
        return found.sorted { a, b in
            let fa = a.convert(a.bounds, to: nil), fb = b.convert(b.bounds, to: nil)
            if abs(fa.maxY - fb.maxY) > 2 { return fa.maxY > fb.maxY }
            return fa.minX < fb.minX
        }
    }

    /// The inspector's Name field, or the N-th Transform number field below it
    /// in the same scroll view.
    @MainActor static func textField(_ name: String, in window: NSWindow) -> NSTextField? {
        guard let content = window.contentView else { return nil }
        let fields = visibleTextFields(in: content)
        guard let nameField = fields.first(where: { ($0.placeholderString ?? $0.placeholderAttributedString?.string) == "Name" }) else { return nil }
        if name == "name" { return nameField }
        guard name.hasPrefix("vector"), let index = Int(name.dropFirst("vector".count)) else { return nil }
        let scope = nameField.enclosingScrollView?.documentView ?? content
        let top = nameField.convert(nameField.bounds, to: nil).minY
        let numbers = visibleTextFields(in: scope).filter { $0 !== nameField && $0.convert($0.bounds, to: nil).maxY <= top }
        return index < numbers.count ? numbers[index] : nil
    }

    /// The Object tab's visible Parent popup (`StudioParentPopUp`).
    @MainActor static func parentPopUp(in window: NSWindow) -> NSPopUpButton? {
        var found: NSPopUpButton?
        func visit(_ v: NSView) {
            if found == nil, let popup = v as? NSPopUpButton, popup.accessibilityLabel() == "Parent",
               !popup.isHiddenOrHasHiddenAncestor, !popup.visibleRect.isEmpty { found = popup }
            v.subviews.forEach(visit)
        }
        if let content = window.contentView { visit(content) }
        return found
    }

    /// The colour wells in the window.
    @MainActor static func colorWells(in window: NSWindow) -> [NSColorWell] {
        var found: [NSColorWell] = []
        func visit(_ v: NSView) {
            if let well = v as? NSColorWell { found.append(well) }
            v.subviews.forEach(visit)
        }
        if let content = window.contentView { visit(content) }
        return found
    }

    /// The first accessibility element (depth first) whose label or title is `text`.
    @MainActor static func accessibilityElement(_ text: String, in window: NSWindow) -> (object: NSObject, role: String)? {
        var visited = 0
        func get(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func visit(_ element: Any, depth: Int) -> (object: NSObject, role: String)? {
            guard depth < 80, visited < 20_000, let object = element as? NSObject else { return nil }
            visited += 1
            let role = get(object, "accessibilityRole") as? String ?? ""
            let names = ["accessibilityLabel", "accessibilityTitle"].compactMap { get(object, $0) as? String }
            if names.contains(text), object.responds(to: NSSelectorFromString("accessibilityPerformPress")) { return (object, role) }
            for child in get(object, "accessibilityChildren") as? [Any] ?? [] {
                if let found = visit(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return visit(window, depth: 0)
    }

    /// The text field whose field editor is the first responder.
    @MainActor static func editedField(_ window: NSWindow) -> NSTextField? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor.delegate as? NSTextField
    }

    @MainActor static func describe(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            guard let field = editor.delegate as? NSTextField else { return "field editor (no field)" }
            return "field editor of " + describe(field)
        }
        if let field = responder as? NSTextField {
            let placeholder = field.placeholderString ?? field.placeholderAttributedString?.string ?? ""
            let where_ = field.window == nil ? "detached" : (field.visibleRect.isEmpty ? "not visible" : "visible")
            return "text field '\(placeholder)' (\(where_))"
        }
        return String(describing: type(of: responder))
    }

    /// The label, title and value of every accessibility element in the window, as
    /// "role: text"; an element that carries none of them is left out. The getters
    /// are called by selector: SwiftUI's elements implement them without being
    /// `NSAccessibilityProtocol` values to Swift.
    @MainActor static func accessibilityStrings(_ window: NSWindow) -> [String] {
        var strings: [String] = []
        var visited = 0
        func get(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func visit(_ element: Any, depth: Int) {
            guard depth < 80, visited < 20_000, let object = element as? NSObject else { return }
            visited += 1
            let role = get(object, "accessibilityRole") as? String ?? ""
            for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text = get(object, name) as? String, !text.isEmpty { strings.append("\(role): \(text)") }
            }
            for child in get(object, "accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        return strings
    }

    /// Walks the Tab key-view loop from the window's first key view and back to
    /// it (at most 80 steps), naming each view; `hidden` counts the views that
    /// lie outside the visible window. Ends with no first responder. Each move
    /// (the start, every Tab and the end) runs between `beforeEachMove` and
    /// `afterEachMove`; the runner uses them to make each Tab its own gesture
    /// and let the views re-render before the next one (#390), as separate Tab
    /// presses would. A view is named as it is right after the move.
    @MainActor static func keyLoop(_ window: NSWindow, beforeEachMove: () -> Void = {},
                                   afterEachMove: () async -> Void = {}) async -> (views: [String], hidden: Int, sha: String) {
        beforeEachMove()
        window.makeFirstResponder(nil)
        await afterEachMove()
        var views: [String] = [], hidden = 0
        var first: NSView?
        for _ in 0..<80 {
            beforeEachMove()
            // From a field being edited, step from the field: its field editor is not in the loop.
            if let current = editedField(window) ?? (window.firstResponder as? NSView) {
                window.selectKeyView(following: current)
            } else {
                window.selectNextKeyView(nil)
            }
            let responder = window.firstResponder
            let view: NSView? = editedField(window) ?? (responder as? NSView)
            let named = view.map { view in
                let frame = view.convert(view.bounds, to: nil)
                return (name: "\(describe(view))@\(Int(frame.minX)),\(Int(frame.minY))",
                        hidden: view.visibleRect.isEmpty || view.isHiddenOrHasHiddenAncestor)
            }
            await afterEachMove()
            guard let view, let named else { break }
            if view === first { break }
            if first == nil { first = view }
            if named.hidden { hidden += 1 }
            views.append(named.name)
        }
        beforeEachMove()
        window.makeFirstResponder(nil)
        await afterEachMove()
        return (views, hidden, sha(views))
    }

    /// The inspector column's scroll view: the tallest scroll view at the
    /// window's trailing edge that is not inside another scroll view.
    @MainActor static func inspectorScrollView(_ window: NSWindow) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        let edge = content.convert(content.bounds, to: nil).maxX
        var found: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView {
                if !scroll.isHiddenOrHasHiddenAncestor, abs(scroll.convert(scroll.bounds, to: nil).maxX - edge) <= 2 {
                    found.append(scroll)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(content)
        return found.max { $0.bounds.height < $1.bounds.height }
    }

    /// Whether everything in the inspector's scroll view lies within its visible
    /// width (#333): its document view is no wider than its clip view, and no
    /// accessibility element inside it (SwiftUI's text is not an NSView, so
    /// views alone would miss it) extends past the clip view on either side,
    /// judged by `InspectorFitRule` (a section's disclosure triangle passes only
    /// at its header offset, 10 pt before the leading edge, with its title
    /// visible). The detail names the scroller style, whether the vertical
    /// scroller shows, how many triangles were accepted at the header offset, up
    /// to eight elements past the visible width, and each segmented row's
    /// natural width, laid-out width and margins (`segmentedRows`).
    @MainActor static func inspectorFit(_ window: NSWindow) -> (fits: Bool, detail: String) {
        guard let scroll = inspectorScrollView(window) else { return (false, "no inspector scroll view") }
        let clip = scroll.contentView
        let visible = window.convertToScreen(clip.convert(clip.bounds, to: nil))
        var leaves: [(role: String, name: String, frame: CGRect)] = [], visited = 0
        func get(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        // The frame getter returns a struct, so it is called through its
        // implementation, not `perform`, and not through key-value coding,
        // which throws for an element that only forwards the selector.
        typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
        let frameSelector = NSSelectorFromString("accessibilityFrame")
        func frame(_ object: NSObject) -> CGRect? {
            guard object.responds(to: frameSelector), let implementation = object.method(for: frameSelector) else { return nil }
            return unsafeBitCast(implementation, to: FrameGetter.self)(object, frameSelector)
        }
        func visit(_ element: Any, depth: Int) {
            guard depth < 80, visited < 20_000, let object = element as? NSObject else { return }
            visited += 1
            let role = get(object, "accessibilityRole") as? String ?? ""
            // A legacy scroller and its parts (knob, arrows) sit beside the clip
            // view by design, so the whole scroll bar subtree is skipped.
            if role == "AXScrollBar" { return }
            let children = get(object, "accessibilityChildren") as? [Any] ?? []
            if children.isEmpty, let f = frame(object), f.width > 0, f.height > 0 {
                let name = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
                    .compactMap { get(object, $0) as? String }.first { !$0.isEmpty } ?? ""
                leaves.append((role, name, f))
            }
            children.forEach { visit($0, depth: depth + 1) }
        }
        visit(scroll, depth: 0)
        let document = scroll.documentView?.frame.width ?? 0
        let judgement = InspectorFitRule.judge(leaves.map { InspectorFitRule.Element(role: $0.role, name: $0.name, frame: $0.frame) },
                                               visible: visible, document: document, clip: clip.bounds.width)
        let vertical = scroll.hasVerticalScroller && !(scroll.verticalScroller?.isHidden ?? true)
        let offenders = judgement.offenders
        let rows = segmentedRows(scroll, visible: visible, labels: leaves.filter { $0.role == "AXStaticText" }.map { ($0.name, $0.frame) })
        let scrollers = scroll.scrollerStyle == .legacy ? "legacy" : "overlay"
        var detail = "inspector scroll view: clip \(Int(clip.bounds.width)) pt, document \(Int(document)) pt, "
        detail += "\(scrollers) scrollers, vertical scroller \(vertical ? "shown" : "not shown"), \(leaves.count) elements, "
        detail += "\(judgement.triangles) titled disclosure triangles at the header offset, "
        detail += "\(offenders.count) past the visible width (\(Int(visible.width)) pt)"
        if !offenders.isEmpty { detail += ": " + offenders.prefix(8).joined(separator: "; ") }
        detail += "; segmented rows (natural/width lead+trail): " + (rows.isEmpty ? "none" : rows.joined(separator: ", "))
        return (judgement.fits, detail)
    }

    /// #410: the workspace rows' geometry as the lazy stack in a scroll view
    /// defined it before its empty slots, at 47ac6316 in
    /// `Apps/IkkokuCreator/Studio/StudioView.swift`.
    enum WorkspaceGeometry {
        /// `LazyVStack(spacing: 1)`, line 131: between two rows (now the top
        /// padding of every row but the first, `WorkspaceSlot`).
        static let rowGap: CGFloat = 1
        /// `}.padding(4)`, line 151: around the rows (leading, trailing, above the first, below the last).
        static let inset: CGFloat = 4
        /// `WorkspaceRow`: `.padding(.vertical, 3).padding(.horizontal, 6)`, line 563.
        static let rowPadding: CGFloat = 6
        /// `HStack(spacing: 6)`, line 540, after `Spacer().frame(width: CGFloat(entry.depth) * 14)`, line 541.
        static let rowSpacing: CGFloat = 6
        static let indent: CGFloat = 14
        /// Half a point at 2x, for rounding.
        static let tolerance: CGFloat = 0.51
    }

    /// #410: the workspace column's scroll view: the tallest scroll view at
    /// the window's leading edge that is not inside another scroll view.
    @MainActor static func workspaceScrollView(_ window: NSWindow) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        let edge = content.convert(content.bounds, to: nil).minX
        var found: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView {
                if !scroll.isHiddenOrHasHiddenAncestor, abs(scroll.convert(scroll.bounds, to: nil).minX - edge) <= 2 {
                    found.append(scroll)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(content)
        return found.max { $0.bounds.height < $1.bounds.height }
    }

    /// #410: scrolls `scroll` to the end of its document or back to its top,
    /// as dragging the scroller there would.
    @MainActor static func scrollWorkspace(_ scroll: NSScrollView, toEnd: Bool) {
        guard let document = scroll.documentView else { return }
        let clip = scroll.contentView, insets = clip.contentInsets
        let travel = document.frame.height - clip.bounds.height
        // A flipped document starts at y 0, an unflipped one at its height.
        let y = document.isFlipped ? (toEnd ? max(-insets.top, travel + insets.bottom) : -insets.top)
                                   : (toEnd ? -insets.bottom : max(-insets.bottom, travel + insets.top))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// #410: how far the visible area of `scroll` is from the end of its
    /// document, in points (0 at the end).
    @MainActor static func workspaceEndGap(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return 0 }
        let clip = scroll.contentView, insets = clip.contentInsets
        return document.isFlipped ? document.frame.height + insets.bottom - clip.bounds.maxY : clip.bounds.minY + insets.bottom
    }

    /// #410: whether the workspace stack keeps its geometry
    /// (`WorkspaceGeometry`) on every fully visible row, read through
    /// accessibility in the window, and whether its empty slots add nothing.
    /// A row is found by its eye button, the trailing button; its icon is the
    /// leading element on the eye's line. Its height is `WorkspaceRow`'s own
    /// for its entry (the fitting height, as the stack lays it out), centred
    /// on the icon, so its top and bottom follow. The list must be at its
    /// start (rows numbered from the first) or its end (from the last). Each
    /// pair of rows must be `rowGap` apart; each icon must start
    /// `inset + rowPadding + indent x depth + rowSpacing` after the visible
    /// area's leading edge and each eye end `rowPadding + inset` before its
    /// trailing edge. At the start the first row's top is `inset` below the
    /// top; at the end the last row's bottom is `inset` above the bottom, and
    /// nothing accessible lies below it, so the empty slots (`WorkspaceSlot`)
    /// add no height and no element. The detail gives the raw values.
    @MainActor static func workspaceGeometry(_ window: NSWindow, studio: StudioModel) -> (ok: Bool, detail: String) {
        typealias G = WorkspaceGeometry
        let state = studio.shownWorkspaceState
        let entries = state.entries
        guard let scroll = workspaceScrollView(window), let document = scroll.documentView else {
            return (false, "no workspace scroll view")
        }
        let clipView = scroll.contentView
        let clip = window.convertToScreen(clipView.convert(clipView.bounds, to: nil))
        func get(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
        let frameSelector = NSSelectorFromString("accessibilityFrame")
        func frame(_ object: NSObject) -> CGRect? {
            guard object.responds(to: frameSelector), let implementation = object.method(for: frameSelector) else { return nil }
            return unsafeBitCast(implementation, to: FrameGetter.self)(object, frameSelector)
        }
        var leaves: [(role: String, frame: CGRect)] = [], visited = 0
        func visit(_ element: Any, depth: Int) {
            guard depth < 80, visited < 20_000, let object = element as? NSObject else { return }
            visited += 1
            let role = get(object, "accessibilityRole") as? String ?? ""
            if role == "AXScrollBar" { return }
            let children = get(object, "accessibilityChildren") as? [Any] ?? []
            if children.isEmpty, let f = frame(object), f.width > 0, f.height > 0, f.intersects(clip) {
                leaves.append((role, f))
            }
            children.forEach { visit($0, depth: depth + 1) }
        }
        visit(scroll, depth: 0)
        // One row per eye button: the element that starts in the trailing
        // 40 pt (a row's text ends before its eye), top to bottom (screen y
        // grows upwards). The button or its image, whichever is the leaf.
        let eyes = leaves.filter { $0.frame.minX > clip.maxX - 40 }.sorted { $0.frame.midY > $1.frame.midY }
        let flipped = document.isFlipped
        let atStart = flipped ? clipView.bounds.minY <= -clipView.contentInsets.top + G.tolerance
                              : clipView.bounds.maxY >= document.frame.height + clipView.contentInsets.top - G.tolerance
        let atEnd = flipped ? clipView.bounds.maxY >= document.frame.height + clipView.contentInsets.bottom - G.tolerance
                            : clipView.bounds.minY <= -clipView.contentInsets.bottom + G.tolerance
        var offenders: [String] = []
        guard atStart || atEnd else {
            return (false, "workspace neither at its start nor at its end (clip \(clipView.bounds), document \(document.frame.height) pt)")
        }
        let width = clip.width - 2 * G.inset
        var measured: [(row: Int, top: CGFloat, bottom: CGFloat)] = []
        var leading: [CGFloat] = [], trailing: [CGFloat] = [], heights: [CGFloat] = []
        for (order, eye) in eyes.enumerated() {
            let row = atStart ? order : entries.count - eyes.count + order
            guard entries.indices.contains(row) else { offenders.append("eye \(order) maps to no row (\(row) of \(entries.count))"); continue }
            let line = leaves.filter { abs($0.frame.midY - eye.frame.midY) <= 3 }
            guard let icon = line.min(by: { $0.frame.minX < $1.frame.minX }) else { continue }
            let entry = entries[row]
            let height = NSHostingView(rootView: WorkspaceRow(entry: entry, select: {}, toggleVisible: {}).frame(width: width)).fittingSize.height
            let top = icon.frame.midY + height / 2, bottom = icon.frame.midY - height / 2
            guard top <= clip.maxY + G.tolerance, bottom >= clip.minY - G.tolerance else { continue }
            let lead = icon.frame.minX - clip.minX - (G.rowPadding + G.indent * CGFloat(entry.depth) + G.rowSpacing)
            let trail = clip.maxX - eye.frame.maxX - G.rowPadding
            leading.append(lead); trailing.append(trail); heights.append(height)
            if abs(lead - G.inset) > G.tolerance { offenders.append("row \(row) leading inset \(lead)") }
            if abs(trail - G.inset) > G.tolerance { offenders.append("row \(row) trailing inset \(trail)") }
            measured.append((row, top, bottom))
        }
        var gaps: [CGFloat] = []
        for (a, b) in zip(measured, measured.dropFirst()) where b.row == a.row + 1 {
            let gap = a.bottom - b.top
            gaps.append(gap)
            if abs(gap - G.rowGap) > G.tolerance { offenders.append("rows \(a.row)-\(b.row) gap \(gap)") }
        }
        var edges: [String] = []
        if atStart, let first = measured.first, first.row == 0 {
            let inset = clip.maxY - first.top
            edges.append(String(format: "top inset %.2f", inset))
            if abs(inset - G.inset) > G.tolerance { offenders.append("top inset \(inset)") }
        }
        if atEnd, let last = measured.last, last.row == entries.count - 1 {
            let inset = last.bottom - clip.minY
            edges.append(String(format: "bottom inset %.2f", inset))
            if abs(inset - G.inset) > G.tolerance { offenders.append("bottom inset \(inset) (the empty slots add height)") }
            let below = leaves.filter { $0.frame.maxY < last.bottom - G.tolerance }
            if !below.isEmpty { offenders.append("\(below.count) elements below the last row (\(Set(below.map(\.role)).sorted().joined(separator: ", ")))") }
        }
        if measured.count < 2 { offenders.append("only \(measured.count) rows measured") }
        func range(_ values: [CGFloat]) -> String {
            guard let low = values.min(), let high = values.max() else { return "-" }
            return low == high ? String(format: "%.2f", low) : String(format: "%.2f-%.2f", low, high)
        }
        var detail = "workspace \(entries.count) rows in \(state.rowCapacity) slots (\(max(0, state.rowCapacity - entries.count)) empty), "
        detail += "\(atStart ? "at the start" : "")\(atStart && atEnd ? " and " : "")\(atEnd ? "at the end" : ""), "
        detail += "document \(Int(document.frame.height)) pt; eyes \(eyes.count), measured \(measured.count); heights \(range(heights)), "
        detail += "gaps \(range(gaps)), leading \(range(leading)), trailing \(range(trailing))"
        detail += edges.isEmpty ? "" : "; " + edges.joined(separator: ", ")
        detail += "; selected entries \(entries.filter(\.selected).count)"
        if !offenders.isEmpty { detail += "; " + offenders.prefix(8).joined(separator: "; ") }
        return (offenders.isEmpty, detail)
    }

    /// Each segmented control in the inspector's document view, top to bottom, as
    /// "label natural/width lead+trail": the row's label (the static text level
    /// with the control and nearest before it, else its segment titles), the
    /// control's natural width (`intrinsicContentSize`, the width it asks for),
    /// its laid-out width (smaller when the row compresses it), and its leading
    /// and trailing margins to the visible width (negative past it), in points.
    @MainActor static func segmentedRows(_ scroll: NSScrollView, visible: CGRect, labels: [(name: String, frame: CGRect)]) -> [String] {
        guard let window = scroll.window, let document = scroll.documentView else { return [] }
        var controls: [NSSegmentedControl] = []
        func find(_ view: NSView) {
            if let control = view as? NSSegmentedControl, !control.isHiddenOrHasHiddenAncestor { controls.append(control); return }
            view.subviews.forEach(find)
        }
        find(document)
        let framed = controls.map { ($0, window.convertToScreen($0.convert($0.bounds, to: nil))) }
            .sorted { $0.1.maxY > $1.1.maxY }
        return framed.map { control, f in
            let level = labels.filter { $0.frame.maxX <= f.minX + 1 && abs($0.frame.midY - f.midY) < f.height / 2 }
            let titles: [String] = (0..<control.segmentCount).compactMap { control.label(forSegment: $0) }
            let label = level.max { $0.frame.maxX < $1.frame.maxX }?.name ?? titles.joined(separator: "|")
            let natural = Int(control.intrinsicContentSize.width.rounded()), width = Int(f.width.rounded())
            let lead = Int((f.minX - visible.minX).rounded()), trail = Int((visible.maxX - f.maxX).rounded())
            return "\(label) \(natural)/\(width) \(lead)+\(trail)"
        }
    }

    static func sha(_ lines: [String]) -> String {
        SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
