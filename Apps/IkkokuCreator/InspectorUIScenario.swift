import Foundation
import AppKit
import SwiftUI
import CryptoKit
import Character
import Studio
import Renderer

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
        /// workspace row), `"scrollWorkspace"` (`toEnd`: scrolls the workspace to
        /// the end of its rows, or back to the top), `"newScene"`,
        /// `"addFolders"` (`count` folders at the root), `"eyeFocus"` (`count`
        /// focus moves; `capture`: see `eyeFocus(_:studio:moves:capture:settle:)`)
        /// and `"workspaceBodies"` (`label`: `select`, `toggle` or `refresh`;
        /// `count` actions from row `index`: see `workspaceBodies(_:action:count:index:settle:)`).
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
        /// `eyeFocus`: where to write a PNG of the workspace with the first
        /// eye that took keyboard focus.
        let capture: String?
    }

    let steps: [Step]

    /// Waits up to this long for the window and the inspector.
    static let windowTimeout: Double = 30
    /// Each step's settle time: enough run-loop turns for SwiftUI to commit a selection.
    static let settleNanoseconds: UInt64 = 300_000_000
    /// #410: `scrollWorkspace` waits this many settles after its one jump
    /// (0.9 s, fixed before any run with it), with no further scroll input.
    static let scrollSettles = 3

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
                // One jump, as dragging the scroller there would, then no more
                // scroll input: a lazy stack may correct the document's height
                // once it lays out what the jump shows (#410: it estimates the
                // children it has not built), so wait `scrollSettles` settles
                // and log the height after each. The geometry assert that
                // follows judges what is left.
                let toEnd = step.toEnd ?? true
                var heights = [Int(document.frame.height)]
                Self.scrollWorkspace(scroll, toEnd: toEnd)
                for _ in 0..<Self.scrollSettles {
                    await settle()
                    heights.append(Int(document.frame.height))
                }
                record(step.op, true, "workspace scrolled to the \(toEnd ? "end" : "top") in one jump; document "
                       + "\(heights.map(String.init).joined(separator: " > ")) pt (before, then after each of \(Self.scrollSettles) settles of "
                       + "\(Self.settleNanoseconds / 1_000_000) ms)")
            case "newScene":
                studio.newScene()
                await settle()
                let state = studio.shownWorkspaceState
                record(step.op, studio.doc.objects.isEmpty, "new scene: \(state.entries.count) rows, \(StudioWorkspaceState.slotCap) slots")
            case "addFolders":
                // #410: `count` folders at the root (none selected, as `add`
                // nests a new object in a selected folder).
                guard let count = step.count, count > 0 else { record(step.op, false, "addFolders needs a count"); continue }
                studio.selection = nil
                let before = studio.shownWorkspaceState.entries.count
                for index in 0..<count { studio.add(StudioObject(name: "Folder \(index + 1)", kind: .folder), select: false) }
                await settle()
                let state = studio.shownWorkspaceState
                record(step.op, state.entries.count == before + count, "added \(count) folders: \(state.entries.count) rows, \(StudioWorkspaceState.slotCap) slots")
            case "workspaceBodies":
                let result = await Self.workspaceBodies(studio, action: step.label ?? "", count: step.count ?? 3,
                                                        index: step.index ?? 1, settle: settle)
                record(step.op, result.ok, result.detail)
            case "eyeFocus":
                let result = await Self.eyeFocus(window, studio: studio, moves: step.count ?? 2, capture: step.capture, settle: settle)
                record(step.op, result.ok, result.detail)
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

    /// #425: whether the Studio toolbar adds its empty marker views (`StudioToolbarMarker`) and counts
    /// its work (`StudioToolbarFitCounts`): only while `IKKOKU_CAPTURE_UI_FIT_LOG` is set, so a normal
    /// launch's toolbar has no markers and pays one Bool test per count.
    static let toolbarMarkers = ProcessInfo.processInfo.environment["IKKOKU_CAPTURE_UI_FIT_LOG"] != nil

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

    /// #363 and #366's diagnostic, a part of `IKKOKU_CAPTURE_UI_FIT_LOG`'s lines
    /// (`AppState.logUICaptureFit`), so nothing runs unless that log is on. It
    /// reads AppKit state only and lays nothing out:
    /// - the toolbar's three-segment pickers, the pose mode's Object/FK/IK
    ///   (`pose`) and the gizmo's images (`gizmo`): frame and host frame in
    ///   window points, intrinsic width, segment distribution, control size,
    ///   font size and each segment's set width (0 is automatic) (#363);
    /// - the inspector clip's top and scroll offset, then the AppKit controls in
    ///   its document view in reading order, each as its distance from the
    ///   clip's top and its height, marked `(off)` while disabled (a kept view
    ///   hidden behind the shown one); the name field's sizing; the Parent
    ///   popup's intrinsic height; the window's first responder (#366).
    /// After the capture (`afterCapture`), and only then, it also reads each
    /// picker segment's accessibility frame, as `inspectorFit` reads its elements.
    @MainActor static func layoutProbe(_ window: NSWindow, afterCapture: Bool) -> String {
        guard let content = window.contentView else { return "no content view" }
        let scroll = inspectorScrollView(window)
        func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
        func f(_ value: CGFloat) -> String { String(format: "%.1f", value) }
        typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
        let frameSelector = NSSelectorFromString("accessibilityFrame")
        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        func segmentFrames(_ control: NSSegmentedControl) -> String {
            guard control.responds(to: childrenSelector),
                  let children = control.perform(childrenSelector)?.takeUnretainedValue() as? [Any] else { return "?" }
            let frames: [String] = children.compactMap { child in
                guard let object = child as? NSObject, object.responds(to: frameSelector),
                      let implementation = object.method(for: frameSelector) else { return nil }
                let frame = window.convertFromScreen(unsafeBitCast(implementation, to: FrameGetter.self)(object, frameSelector))
                return "\(f(frame.minX))+\(f(frame.width))"
            }
            return frames.isEmpty ? "?" : frames.joined(separator: " ")
        }
        var pickers: [String] = []
        func findPickers(_ view: NSView) {
            if let control = view as? NSSegmentedControl, control.segmentCount == 3,
               !(scroll.map { control.isDescendant(of: $0) } ?? false) {
                let labels = (0..<3).map { control.label(forSegment: $0) ?? "" }
                let name = labels == ["Object", "FK", "IK"] ? "pose" : labels.allSatisfy(\.isEmpty) ? "gizmo" : labels.joined(separator: "/")
                let frame = rect(control), host = control.superview.map(rect) ?? .zero
                var text = "\(name) x \(f(frame.minX))+\(f(frame.width)) y \(f(frame.minY))+\(f(frame.height))"
                    + " host \(f(host.minX))+\(f(host.width)) intrinsic \(f(control.intrinsicContentSize.width))"
                    + " distribution \(control.segmentDistribution.rawValue) size \(control.controlSize.rawValue)"
                    + " font \(f(control.font?.pointSize ?? 0)) widths " + (0..<3).map { f(control.width(forSegment: $0)) }.joined(separator: "/")
                if control.needsLayout { text += " needsLayout" }
                if control.isHiddenOrHasHiddenAncestor { text += " hidden" }
                if afterCapture { text += " segments " + segmentFrames(control) }
                pickers.append(text)
                return
            }
            view.subviews.forEach(findPickers)
        }
        findPickers(content)
        var line = "toolbar " + (pickers.isEmpty ? "no pickers" : pickers.joined(separator: "; "))
        // The toolbar's horizontal scroll view (the pickers' enclosing one): its visible
        // width, its content's width and whether a horizontal scroller shows.
        var toolbarScroll: NSScrollView?
        func findToolbarScroll(_ view: NSView) {
            if toolbarScroll == nil, let control = view as? NSSegmentedControl, control.segmentCount == 3,
               let enclosing = control.enclosingScrollView, enclosing !== scroll {
                toolbarScroll = enclosing
            }
            if toolbarScroll == nil { view.subviews.forEach(findToolbarScroll) }
        }
        findToolbarScroll(content)
        // #425: every AppKit control in the toolbar's content, left to right, as kind@x+width: under
        // `root`, and inside `region` (window coordinates) when one is given.
        func toolbarItems(_ root: NSView, region: NSRect?) -> String {
            var items: [(x: CGFloat, text: String)] = []
            func findItems(_ view: NSView) {
                guard items.count < 40, !(scroll.map { view === $0 } ?? false) else { return }
                if let control = view as? NSControl {
                    let frame = rect(control)
                    guard region.map({ $0.insetBy(dx: -1, dy: -1).contains(frame) }) ?? true else { return }
                    let kind: String
                    switch control {
                    case is NSSegmentedControl: kind = "segmented"
                    case is NSPopUpButton: kind = "popup"
                    case let button as NSButton: kind = button.title.isEmpty ? "button" : "button(\(button.title.prefix(8)))"
                    default: kind = String(describing: type(of: control))
                    }
                    items.append((frame.minX, "\(kind)@\(f(frame.minX))+\(f(frame.width))"))
                    return
                }
                view.subviews.forEach(findItems)
            }
            findItems(root)
            return "; items " + (items.isEmpty ? "none" : items.sorted { $0.x < $1.x }.map(\.text).joined(separator: " "))
        }
        if let toolbarScroll {
            let shown = toolbarScroll.hasHorizontalScroller && !(toolbarScroll.horizontalScroller?.isHidden ?? true)
            line += "; scroll clip \(f(toolbarScroll.contentView.bounds.width)) content \(f(toolbarScroll.documentView?.frame.width ?? 0))"
                + " at \(f(toolbarScroll.contentView.bounds.minX)) scroller \(shown ? "shown" : "not shown")"
            if let document = toolbarScroll.documentView { line += toolbarItems(document, region: nil) }
        }
        // #425: the toolbar variant ViewThatFits shows (full, compact, or compact in the scroll
        // view), its width, and the width it was offered, from the fit log's marker views.
        var markers: [String: NSView] = [:]
        func findMarkers(_ view: NSView) {
            if let name = view.identifier?.rawValue, name.hasPrefix("studio.toolbar.") { markers[name] = view }
            view.subviews.forEach(findMarkers)
        }
        findMarkers(content)
        if let shown = markers["studio.toolbar.full"] ?? markers["studio.toolbar.compact"] {
            let variant = shown.identifier?.rawValue == "studio.toolbar.full" ? "full"
                : shown.enclosingScrollView != nil ? "scroll" : "compact"
            line += "; variant \(variant) width \(f(rect(shown).width)) available "
                + (markers["studio.toolbar.available"].map { f(rect($0).width) } ?? "?")
            // Both markers at once would mean ViewThatFits kept a variant it does not show.
            if markers["studio.toolbar.full"] != nil, markers["studio.toolbar.compact"] != nil { line += " (both markers)" }
            if toolbarScroll == nil, let available = markers["studio.toolbar.available"] {
                line += toolbarItems(content, region: rect(available))
            }
        } else if toolbarScroll == nil {
            line += "; variant none"
        }
        guard let scroll, let document = scroll.documentView else { return line + " | rows: no inspector scroll view" }
        let clip = scroll.contentView, top = rect(clip).maxY
        var rows: [(top: CGFloat, text: String)] = [], name: NSTextField? = nil, popup: NSPopUpButton? = nil
        var fieldIntrinsics: [CGFloat] = []
        func findControls(_ view: NSView) {
            guard rows.count < 64 else { return }
            if let control = view as? NSControl, !control.isHiddenOrHasHiddenAncestor {
                let frame = rect(control)
                let kind: String
                switch control {
                case let field as NSTextField:
                    if field.placeholderString == "Name", name == nil { name = field }
                    kind = field.placeholderString == "Name" ? "name" : field.isEditable ? "field" : "text"
                    if kind == "field" { fieldIntrinsics.append(field.intrinsicContentSize.height) }
                case let button as NSPopUpButton:
                    if popup == nil { popup = button }
                    kind = "popup"
                case let button as NSButton: kind = "button(\(button.title.prefix(8)))"
                case is NSSegmentedControl: kind = "segmented"
                case is NSStepper: kind = "stepper"
                case is NSSlider: kind = "slider"
                default: kind = "\(type(of: control))"
                }
                rows.append((top - frame.maxY, "\(kind)@\(f(top - frame.maxY))+\(f(frame.height))" + (control.isEnabled ? "" : "(off)")))
            }
            view.subviews.forEach(findControls)
        }
        findControls(document)
        rows.sort { $0.top < $1.top }
        line += " | inspector top \(f(top)) offset \(f(clip.bounds.minY)) document height \(f(document.frame.height))"
        line += " | rows " + rows.prefix(20).map { $0.text }.joined(separator: " ")
        if let name {
            line += " | name height \(f(name.frame.height)) intrinsic \(f(name.intrinsicContentSize.height)) size \(name.controlSize.rawValue)"
                + " bezel \(name.isBezeled ? Int(name.bezelStyle.rawValue) : -1) font \(f(name.font?.pointSize ?? 0))"
        } else {
            line += " | no name field"
        }
        if let popup { line += " | popup height \(f(popup.frame.height)) intrinsic \(f(popup.intrinsicContentSize.height))" }
        // #366 R2: the explicit text-field heights the inspector lays out with,
        // to compare with the fields' own intrinsic heights (the Name field's
        // above; here every other editable field's, the Transform rows on the
        // Object tab).
        line += " | heights name \(f(InspectorTextFieldHeight.name)) vector \(f(InspectorTextFieldHeight.vector))"
            + " fields " + (fieldIntrinsics.isEmpty ? "none" : fieldIntrinsics.map(f).joined(separator: ","))
        let responder = window.firstResponder
        var responderText = responder.map { "\(type(of: $0))" } ?? "none"
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            responderText += " editing " + (editor.delegate.map { $0 === name ? "name" : "\(type(of: $0))" } ?? "nothing")
        }
        return line + " | first responder " + responderText
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
        /// The row icon's `.frame(width: 16)`, lines 545 and 548. Accessibility
        /// gives an image the bounds of its symbol, which can be narrower, so
        /// the icon is placed by its centre and the eye (line 561, no frame) by
        /// its centre and its laid-out width (`eyeWidth(visible:)`).
        static let iconWidth: CGFloat = 16
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
        var iconWidths: [CGFloat] = [], eyeWidths: [CGFloat] = [], diagnostics: [String] = []
        for (order, eye) in eyes.enumerated() {
            let row = atStart ? order : entries.count - eyes.count + order
            guard entries.indices.contains(row) else { offenders.append("eye \(order) maps to no row (\(row) of \(entries.count))"); continue }
            let line = leaves.filter { abs($0.frame.midY - eye.frame.midY) <= 3 }
            guard let icon = line.min(by: { $0.frame.minX < $1.frame.minX }) else { continue }
            let entry = entries[row]
            let height = WorkspaceRow.fittingHeight(entry, width: width)
            let top = icon.frame.midY + height / 2, bottom = icon.frame.midY - height / 2
            guard top <= clip.maxY + G.tolerance, bottom >= clip.minY - G.tolerance else { continue }
            let lead = icon.frame.midX - G.iconWidth / 2 - clip.minX - (G.rowPadding + G.indent * CGFloat(entry.depth) + G.rowSpacing)
            let trail = clip.maxX - (eye.frame.midX + eyeWidth(visible: entry.visible) / 2) - G.rowPadding
            leading.append(lead); trailing.append(trail); heights.append(height)
            iconWidths.append(icon.frame.width); eyeWidths.append(eye.frame.width)
            if diagnostics.count < 3 { diagnostics.append(String(format: "row %d depth %d icon %@ x %.1f w %.1f, eye %@ x %.1f w %.1f h %.1f", row, entry.depth, icon.role, icon.frame.minX - clip.minX, icon.frame.width, eye.role, clip.maxX - eye.frame.maxX, eye.frame.width, eye.frame.height)) }
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
            // A list shorter than the visible area ends at its document's end.
            let documentFrame = window.convertToScreen(document.convert(document.bounds, to: nil))
            let floor = max(clip.minY, documentFrame.minY)
            let inset = last.bottom - floor
            edges.append(String(format: "bottom inset %.2f%@", inset, floor > clip.minY ? " (from the document's end)" : ""))
            if abs(inset - G.inset) > G.tolerance { offenders.append("bottom inset \(inset) (the empty slots add height)") }
            let below = leaves.filter { $0.frame.maxY < last.bottom - G.tolerance }
            if !below.isEmpty { offenders.append("\(below.count) elements below the last row (\(Set(below.map(\.role)).sorted().joined(separator: ", ")))") }
        }
        // Two rows give a gap; a one-row scene (#410: 63 empty slots) has only its row.
        if measured.count < min(2, entries.count) { offenders.append("only \(measured.count) rows measured") }
        func range(_ values: [CGFloat]) -> String {
            guard let low = values.min(), let high = values.max() else { return "-" }
            return low == high ? String(format: "%.2f", low) : String(format: "%.2f-%.2f", low, high)
        }
        let slots = StudioWorkspaceState.slotCap
        var detail = "workspace \(entries.count) rows, \(slots) slots (\(max(0, slots - entries.count)) empty), "
        detail += "\(atStart ? "at the start" : "")\(atStart && atEnd ? " and " : "")\(atEnd ? "at the end" : ""), "
        detail += "document \(Int(document.frame.height)) pt; eyes \(eyes.count), measured \(measured.count); heights \(range(heights)), "
        detail += "gaps \(range(gaps)), leading \(range(leading)), trailing \(range(trailing))"
        detail += ", icon widths \(range(iconWidths)), eye widths \(range(eyeWidths)), clip width \(String(format: "%.1f", clip.width)) [" + diagnostics.joined(separator: "; ") + "]"
        detail += edges.isEmpty ? "" : "; " + edges.joined(separator: ", ")
        detail += "; selected entries \(entries.filter(\.selected).count)"
        if !offenders.isEmpty { detail += "; " + offenders.prefix(8).joined(separator: "; ") }
        return (offenders.isEmpty, detail)
    }

    /// #410: the workspace bodies each of `count` actions evaluates: the
    /// panel (`StudioWorkspacePanel`), the list, slots, rows and empty slots.
    /// `select` moves the selection between rows `index` and `index + 1`;
    /// `toggle` hides and shows again, as its eye does, the object of the
    /// first row from `index` on with no children (not a camera); `refresh`
    /// runs the Studio refresh with nothing changed. A selection change or a
    /// toggle may evaluate the list once, at most two slots and two rows and
    /// no empty slot, so the eager slots never re-evaluate as a whole; an
    /// idle refresh may evaluate none of them.
    @MainActor static func workspaceBodies(_ studio: StudioModel, action: String, count: Int, index: Int,
                                           settle: () async -> Void) async -> (ok: Bool, detail: String) {
        let entries = studio.shownWorkspaceState.entries
        var target = index
        switch action {
        case "select":
            guard index + 1 < entries.count else { return (false, "no workspace rows \(index) and \(index + 1) of \(entries.count)") }
        case "toggle":
            guard let leaf = entries.indices.dropFirst(index).first(where: {
                !entries[$0].cameraPlaceholder && entries[$0].kind != .camera
                    && ($0 + 1 == entries.count || entries[$0 + 1].depth <= entries[$0].depth)
            }) else { return (false, "no workspace row from \(index) of \(entries.count) to toggle") }
            target = leaf
        case "refresh": break
        default: return (false, "workspaceBodies needs the label select, toggle or refresh")
        }
        let views: [PerfTrace.ViewBody] = [.studioWorkspace, .studioWorkspaceList, .studioWorkspaceSlot,
                                           .studioWorkspaceRow, .studioWorkspacePlaceholder]
        PerfTrace.scenarioBodyCounts = [Int](repeating: 0, count: PerfTrace.ViewBody.allCases.count)
        defer { PerfTrace.scenarioBodyCounts = nil }
        func counts() -> [Int] { views.map { PerfTrace.scenarioBodyCounts?[$0.rawValue] ?? 0 } }
        var per: [String] = [], problems: [String] = []
        for step in 0..<max(1, count) {
            let before = counts()
            studio.endUndoCoalescing()
            switch action {
            case "select": studio.selection = entries[index + step % 2].id
            case "toggle": studio.update(entries[target].id) { $0.visible.toggle() }
            default: studio.refresh()
            }
            await settle()
            let delta = zip(counts(), before).map { $0 - $1 }
            let (list, slots, rows, empty) = (delta[1], delta[2], delta[3], delta[4])
            per.append(delta.map(String.init).joined(separator: "/"))
            let name = "\(action) \(step + 1)"
            if action == "refresh" {
                if list + slots + rows + empty > 0 {
                    problems.append("\(name) evaluated the list \(list), \(slots) slots, \(rows) rows, \(empty) empty slots")
                }
            } else {
                if list > 1 { problems.append("\(name) evaluated the list \(list) times") }
                if slots > 2 { problems.append("\(name) evaluated \(slots) slots") }
                if rows > 2 { problems.append("\(name) evaluated \(rows) rows") }
                if empty > 0 { problems.append("\(name) evaluated \(empty) empty slots") }
            }
        }
        var detail = "\(action) ×\(max(1, count))" + (action == "refresh" ? "" : " from row \(target)")
        detail += " in \(entries.count) rows, \(StudioWorkspaceState.slotCap) slots; panel/list/slots/rows/empty slots per action: "
        detail += per.joined(separator: ", ")
        if !problems.isEmpty { detail += "; " + problems.joined(separator: "; ") }
        return (problems.isEmpty, detail)
    }

    /// #410: the workspace eyes draw their own keyboard focus ring in place of
    /// the system's focus effect. This moves keyboard focus onto a workspace
    /// eye by the first way that works, and says which:
    /// - "Tab": with Full Keyboard Access on (System Settings), Tab key
    ///   events from no first responder until an eye has focus (at most
    ///   `maxTabs`). `-AppleKeyboardUIMode 2` in the app's argument domain does
    ///   not turn it on (AppKit does not read it from there; the detail gives
    ///   both values), so a machine with it off skips this.
    /// - "accessibility": setting the eye's accessibility focus, as an
    ///   assistive app moving the keyboard focus does.
    /// - "render" when neither takes: the row drawn alone (`ImageRenderer`)
    ///   with and without `focusShown` must differ by the ring, around the eye
    ///   only.
    /// With real focus it checks, against a render of the workspace with no
    /// focus (`cacheDisplay`, as the UI capture draws), that the focused eye's
    /// ring draws, and then makes `moves` more moves, each to the next eye,
    /// checking that the ring follows and counting the list, row and
    /// empty-slot bodies each move evaluates (at most one list and two rows).
    /// In every case it presses an eye through accessibility, as VoiceOver
    /// does, twice, which must hide its object and show it again. The
    /// workspace is scrolled to the top first, so the n-th eye on screen is
    /// row n. `capture` gets a PNG of the workspace with the first focused eye
    /// (or, for "render", of the focused row).
    @MainActor static func eyeFocus(_ window: NSWindow, studio: StudioModel, moves: Int, capture: String?,
                                    settle: () async -> Void) async -> (ok: Bool, detail: String) {
        guard let scroll = workspaceScrollView(window) else { return (false, "no workspace scroll view") }
        let mode = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleKeyboardUIMode"]
        let fullKeyboardAccess = NSApp.isFullKeyboardAccessEnabled
        var problems: [String] = [], seen: [String] = ["full keyboard access \(fullKeyboardAccess) "
            + "(AppleKeyboardUIMode: argument \(mode.map { "\($0)" } ?? "none"), defaults \(UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode")))"]
        scrollWorkspace(scroll, toEnd: false)
        window.makeFirstResponder(nil)
        // The window's accessibility tree is built when it is first read.
        _ = accessibilityStrings(window)
        await settle()
        let clipView = scroll.contentView
        let clip = clipView.convert(clipView.bounds, to: nil)
        guard let baseline = renderPixels(window, clip) else { return (false, "the workspace did not render") }
        let startEyes = workspaceEyes(window, scroll: scroll)
        seen.append("\(startEyes.count) eyes on screen")
        guard startEyes.count > moves + 1 else {
            return (false, "\(startEyes.count) workspace eyes on screen, too few for \(moves) moves; trailing elements: "
                    + trailingElements(window, scroll: scroll).prefix(4).joined(separator: " | "))
        }
        PerfTrace.scenarioBodyCounts = [Int](repeating: 0, count: PerfTrace.ViewBody.allCases.count)
        defer { PerfTrace.scenarioBodyCounts = nil }
        func bodies(_ view: PerfTrace.ViewBody) -> Int { PerfTrace.scenarioBodyCounts?[view.rawValue] ?? 0 }
        func tab() {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                                                   isARepeat: false, keyCode: 48) else { continue }
                NSApp.sendEvent(event)
            }
        }
        typealias FocusSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setFocusSelector = NSSelectorFromString("setAccessibilityFocused:")
        func focusThroughAccessibility(_ row: Int) {
            guard let eye = workspaceEyes(window, scroll: scroll).dropFirst(row).first,
                  eye.element.responds(to: setFocusSelector), let implementation = eye.element.method(for: setFocusSelector) else { return }
            unsafeBitCast(implementation, to: FocusSetter.self)(eye.element, setFocusSelector, true)
        }
        func focused() -> (row: Int, eye: WorkspaceEye)? {
            let eyes = workspaceEyes(window, scroll: scroll)
            return eyes.firstIndex(where: \.focused).map { (row: $0, eye: eyes[$0]) }
        }
        // The ring's pixels: those around `eye` that differ from the render with no focus.
        func ring(_ eye: WorkspaceEye, in pixels: Pixels) -> Int {
            changedPixels(baseline, pixels, rect: clip, region: eye.frame.insetBy(dx: -4, dy: -4))
        }
        var path = "render", found: (row: Int, eye: WorkspaceEye)?, tabs = 0
        if fullKeyboardAccess {
            while found == nil, tabs < Self.maxTabs {
                tab(); tabs += 1
                await settle()
                found = focused()
            }
            if found != nil { path = "Tab" } else { seen.append("no eye took focus in \(tabs) Tabs") }
        }
        if found == nil {
            focusThroughAccessibility(0)
            await settle()
            found = focused()
            if found != nil { path = "accessibility" }
        }
        seen.append("focus check: \(path)")
        var pressRow = 0
        if var current = found {
            seen.append("row \(current.row)'s eye focused" + (path == "Tab" ? " after \(tabs) Tabs" : "") + ", label '\(current.eye.label)'")
            pressRow = current.row
            guard let first = renderPixels(window, clip) else { return (false, "the workspace did not render with focus") }
            let firstRing = ring(current.eye, in: first)
            seen.append("ring \(firstRing) px")
            if firstRing < Self.ringPixels { problems.append("row \(current.row)'s focused eye draws \(firstRing) px of ring, fewer than \(Self.ringPixels)") }
            if let capture {
                do {
                    _ = try CaptureOutput.writePNG(first.image, to: URL(fileURLWithPath: capture))
                    seen.append("capture \(first.width)x\(first.height) px")
                } catch { problems.append("capture: \(error)") }
            }
            for move in 1...max(1, moves) {
                let before = (bodies(.studioWorkspaceList), bodies(.studioWorkspaceRow), bodies(.studioWorkspacePlaceholder))
                studio.endUndoCoalescing()
                if path == "Tab" { tab() } else { focusThroughAccessibility(current.row + 1) }
                await settle()
                let list = bodies(.studioWorkspaceList) - before.0, rows = bodies(.studioWorkspaceRow) - before.1
                let slots = bodies(.studioWorkspacePlaceholder) - before.2
                guard let next = focused(), let pixels = renderPixels(window, clip) else {
                    problems.append("move \(move): no workspace eye has focus"); break
                }
                let left = ring(current.eye, in: pixels), drawn = ring(next.eye, in: pixels)
                seen.append("move \(move): row \(current.row) > \(next.row), list \(list), rows \(rows), empty slots \(slots), "
                            + "ring left \(left) px, drawn \(drawn) px")
                if next.row == current.row { problems.append("move \(move): focus stayed on row \(current.row)") }
                if list > 1 { problems.append("move \(move) evaluated the list \(list) times") }
                if rows > 2 { problems.append("move \(move) evaluated \(rows) rows") }
                if slots > 0 { problems.append("move \(move) evaluated \(slots) empty slots") }
                if drawn < Self.ringPixels { problems.append("move \(move): row \(next.row)'s eye draws \(drawn) px of ring") }
                if left > Self.ringResidue { problems.append("move \(move): row \(current.row)'s eye still differs by \(left) px") }
                current = next
            }
            pressRow = current.row
        } else {
            // No real focus: the row drawn alone, with and without the ring.
            let entries = studio.shownWorkspaceState.entries
            guard let entry = entries.first else { return (false, "no workspace rows") }
            let width = clip.width - 2 * WorkspaceGeometry.inset
            let ringOn = renderRow(entry, width: width, focusShown: true), ringOff = renderRow(entry, width: width, focusShown: false)
            if let ringOn, let ringOff, let changes = changedBounds(ringOff, ringOn) {
                let bounds = changes.bounds
                seen.append(String(format: "ring %d px in %.1fx%.1f pt at %.1f pt from the row's trailing edge (row %.1fx%.1f pt)",
                                   changes.count, bounds.width, bounds.height, width - bounds.maxX, width, CGFloat(ringOn.height) / changes.scale))
                if changes.count < Self.ringPixels { problems.append("the focused row draws \(changes.count) px of ring") }
                // The ring surrounds the eye, the row's last element, and nothing else changes.
                if width - bounds.maxX > WorkspaceGeometry.rowPadding { problems.append("the ring is not at the row's trailing end") }
                if bounds.width > 40 || bounds.height > 30 { problems.append("the focused row changes more than the eye's ring") }
                if let capture {
                    do {
                        _ = try CaptureOutput.writePNG(ringOn.image, to: URL(fileURLWithPath: capture))
                        seen.append("capture \(ringOn.width)x\(ringOn.height) px")
                    } catch { problems.append("capture: \(error)") }
                }
            } else if ringOn == nil || ringOff == nil {
                problems.append("the row did not render")
            } else {
                problems.append("the focused row draws no ring")
            }
        }
        // VoiceOver reaches the eye and presses it: hide, then show again.
        let entries = studio.shownWorkspaceState.entries
        if entries.indices.contains(pressRow) {
            let id = entries[pressRow].id
            for press in 1...2 {
                let was = studio.doc.object(id)?.visible
                studio.endUndoCoalescing()
                guard let eye = workspaceEyes(window, scroll: scroll).dropFirst(pressRow).first, eye.pressable else {
                    problems.append("press \(press): row \(pressRow)'s eye has no accessibility press"); break
                }
                if press == 1 { seen.append("row \(pressRow)'s eye: accessibility button '\(eye.label)'") }
                _ = eye.element.perform(NSSelectorFromString("accessibilityPerformPress"))
                await settle()
                let now = studio.doc.object(id)?.visible
                seen.append("press \(press): visible \(was.map { "\($0)" } ?? "-") > \(now.map { "\($0)" } ?? "-")")
                if was == nil || now != was.map({ !$0 }) { problems.append("press \(press) did not toggle row \(pressRow)'s visibility") }
            }
        } else { problems.append("no entry for row \(pressRow)") }
        window.makeFirstResponder(nil)
        await settle()
        return (problems.isEmpty, (problems + ["seen: " + seen.joined(separator: "; ")]).joined(separator: "; "))
    }

    /// `eyeFocus`: Tabs to reach a workspace eye, the ring's least pixels
    /// (it is 2 pt wide, 1 to 3 pt outside the eye, about 160 px at 1x; each
    /// eye is read within 4 pt of its frame, which no neighbour's ring
    /// reaches) and the most pixels an eye may still differ by once focus
    /// left it.
    static let maxTabs = 120
    static let ringPixels = 40
    static let ringResidue = 8

    /// `eyeFocus` "render": `entry`'s row alone at `width`, with or without its
    /// focus ring, at the main screen's scale.
    @MainActor static func renderRow(_ entry: WorkspaceEntry, width: CGFloat, focusShown: Bool) -> Pixels? {
        let renderer = ImageRenderer(content: WorkspaceRow(entry: entry, focusShown: focusShown, select: {}, toggleVisible: {})
            .frame(width: width))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.cgImage else { return nil }
        return pixels(of: image)
    }

    /// The pixels that differ between two renders of the same size (more than
    /// 24 in a channel), and their bounds in points.
    static func changedBounds(_ a: Pixels, _ b: Pixels) -> (count: Int, bounds: CGRect, scale: CGFloat)? {
        guard a.width == b.width, a.height == b.height, a.width > 0 else { return nil }
        var count = 0, minX = a.width, minY = a.height, maxX = -1, maxY = -1
        for y in 0..<a.height {
            for x in 0..<a.width {
                let offset = (y * a.width + x) * 4
                for channel in 0..<4 where abs(Int(a.bytes[offset + channel]) - Int(b.bytes[offset + channel])) > 24 {
                    count += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    break
                }
            }
        }
        guard count > 0 else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return (count, CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                              width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale), scale)
    }

    struct WorkspaceEye {
        let element: NSObject
        /// In window coordinates.
        let frame: CGRect
        let focused: Bool
        let pressable: Bool
        let label: String
    }

    /// #410: the workspace's eye buttons on screen, top to bottom, read through
    /// accessibility: the buttons that start in the visible area's trailing
    /// 40 pt (a row's text ends before its eye).
    @MainActor static func workspaceEyes(_ window: NSWindow, scroll: NSScrollView) -> [WorkspaceEye] {
        let clipView = scroll.contentView
        let clip = window.convertToScreen(clipView.convert(clipView.bounds, to: nil))
        func get(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
        typealias FlagGetter = @convention(c) (AnyObject, Selector) -> Bool
        let frameSelector = NSSelectorFromString("accessibilityFrame"), focusSelector = NSSelectorFromString("isAccessibilityFocused")
        let pressSelector = NSSelectorFromString("accessibilityPerformPress")
        var eyes: [(element: NSObject, screen: CGRect)] = [], visited = 0
        func visit(_ element: Any, depth: Int) {
            guard depth < 80, visited < 20_000, let object = element as? NSObject else { return }
            visited += 1
            let role = get(object, "accessibilityRole") as? String ?? ""
            if role == "AXScrollBar" { return }
            if role == "AXButton", object.responds(to: frameSelector), let implementation = object.method(for: frameSelector) {
                let frame = unsafeBitCast(implementation, to: FrameGetter.self)(object, frameSelector)
                if frame.width > 0, frame.height > 0, frame.intersects(clip), frame.minX > clip.maxX - 40 { eyes.append((object, frame)) }
            }
            (get(object, "accessibilityChildren") as? [Any] ?? []).forEach { visit($0, depth: depth + 1) }
        }
        visit(scroll, depth: 0)
        return eyes.sorted { $0.screen.midY > $1.screen.midY }.map { eye -> WorkspaceEye in
            var focused = false
            if eye.element.responds(to: focusSelector), let implementation = eye.element.method(for: focusSelector) {
                focused = unsafeBitCast(implementation, to: FlagGetter.self)(eye.element, focusSelector)
            }
            let label = ["accessibilityLabel", "accessibilityTitle"].compactMap { get(eye.element, $0) as? String }.first { !$0.isEmpty } ?? ""
            return WorkspaceEye(element: eye.element, frame: window.convertFromScreen(eye.screen), focused: focused,
                                pressable: eye.element.responds(to: pressSelector), label: label)
        }
    }

    /// The laid-out width of the eye button's symbol (`WorkspaceRow`), which
    /// has no frame of its own.
    @MainActor static func eyeWidth(visible: Bool) -> CGFloat {
        NSHostingView(rootView: Image(systemName: visible ? "eye" : "eye.slash")).fittingSize.width
    }

    /// The first accessibility elements in the workspace's trailing 40 pt, for
    /// a failure's detail: role, offset from the trailing edge, size, children
    /// and whether each takes a press.
    @MainActor static func trailingElements(_ window: NSWindow, scroll: NSScrollView) -> [String] {
        let clipView = scroll.contentView
        let clip = window.convertToScreen(clipView.convert(clipView.bounds, to: nil))
        func get(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
        let frameSelector = NSSelectorFromString("accessibilityFrame")
        var found: [String] = [], visited = 0
        func visit(_ element: Any, depth: Int) {
            guard depth < 80, visited < 20_000, found.count < 8, let object = element as? NSObject else { return }
            visited += 1
            let role = get(object, "accessibilityRole") as? String ?? "?"
            let children = get(object, "accessibilityChildren") as? [Any] ?? []
            if object.responds(to: frameSelector), let implementation = object.method(for: frameSelector) {
                let frame = unsafeBitCast(implementation, to: FrameGetter.self)(object, frameSelector)
                if frame.width > 0, frame.height > 0, frame.intersects(clip), frame.minX > clip.maxX - 40 {
                    found.append(String(format: "%@ d%d at -%.1f %.1fx%.1f, %d children%@", role, depth, clip.maxX - frame.minX,
                                        frame.width, frame.height, children.count,
                                        object.responds(to: NSSelectorFromString("accessibilityPerformPress")) ? ", press" : ""))
                }
            }
            children.forEach { visit($0, depth: depth + 1) }
        }
        visit(scroll, depth: 0)
        return found
    }

    /// A render of part of the window, as 8-bit RGBA rows from the top.
    struct Pixels {
        let image: CGImage
        let width: Int, height: Int
        let bytes: [UInt8]
    }

    /// Draws `rect` (window coordinates) of the window's content the way the
    /// UI capture does (`cacheDisplay`, no screen recording).
    @MainActor static func renderPixels(_ window: NSWindow, _ rect: CGRect) -> Pixels? {
        guard let content = window.contentView else { return nil }
        let area = content.convert(rect, from: nil)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: area) else { return nil }
        content.cacheDisplay(in: area, to: rep)
        guard let image = rep.cgImage else { return nil }
        return pixels(of: image)
    }

    /// `image` as 8-bit RGBA rows from the top.
    static func pixels(of image: CGImage) -> Pixels? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(image: image, width: width, height: height, bytes: bytes) : nil
    }

    /// How many pixels of `region` (window coordinates, within `rect`, the
    /// area both renders show) differ by more than 24 in a channel.
    static func changedPixels(_ a: Pixels, _ b: Pixels, rect: CGRect, region: CGRect) -> Int {
        guard a.width == b.width, a.height == b.height, rect.width > 0, rect.height > 0 else { return -1 }
        let area = region.intersection(rect)
        guard !area.isNull, !area.isEmpty else { return 0 }
        let sx = CGFloat(a.width) / rect.width, sy = CGFloat(a.height) / rect.height
        let x0 = max(0, Int(((area.minX - rect.minX) * sx).rounded(.down))), x1 = min(a.width, Int(((area.maxX - rect.minX) * sx).rounded(.up)))
        // Rows run from the top; window y grows upwards.
        let y0 = max(0, Int(((rect.maxY - area.maxY) * sy).rounded(.down))), y1 = min(a.height, Int(((rect.maxY - area.minY) * sy).rounded(.up)))
        guard x0 < x1, y0 < y1 else { return 0 }
        var changed = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let offset = (y * a.width + x) * 4
                for channel in 0..<4 where abs(Int(a.bytes[offset + channel]) - Int(b.bytes[offset + channel])) > 24 {
                    changed += 1
                    break
                }
            }
        }
        return changed
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
