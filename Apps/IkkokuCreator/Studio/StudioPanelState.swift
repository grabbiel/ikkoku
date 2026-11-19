import Foundation
import AppKit
import Renderer
import Studio

// R7 phase 2, item 7 follow-ups (C4): the workspace tree, the toolbar and the
// timeline bar read the document for what they show. Every write to it (each
// frame of an FK drag, say) re-evaluated them and laid the window out again,
// although what they show had not changed. The model now publishes what they
// show, as it does for the Object tab (`objectInspectorState`), so a write
// that changes none of it invalidates none of them.

/// Where the workspace, toolbar and timeline read their document-derived
/// state. `IKKOKU_PERF_PANEL_STATE` is a measurement control, read once at
/// launch: "document" reads the document in each panel's body as before,
/// and "published" (the default) reads what the model publishes.
enum StudioPanelStateMode: String, Sendable {
    case document, published

    static let current: StudioPanelStateMode =
        ProcessInfo.processInfo.environment["IKKOKU_PERF_PANEL_STATE"].flatMap(Self.init(rawValue:)) ?? .published

    var publishes: Bool { self == .published }
}

/// The workspace tree's rows and object count, as the panel shows them.
struct StudioWorkspaceState: Equatable {
    var entries: [WorkspaceEntry] = []
    var objectCount = 0
    /// #410: the workspace slots, the rows the list builds ahead of any
    /// scroll (`StudioWorkspaceContent`): the most rows the tallest screen
    /// could show at once, its visible height over a one-line row and its gap
    /// (`rowPitch`), plus `slotMargin`, so the rows a load builds are slots
    /// and a load never inserts a row that is built. A slot past the scene's
    /// rows is empty and 0 pt high. Rows past the slots are in a lazy stack.
    /// `IKKOKU_PERF_WORKSPACE_SLOT_CAP=<k>` is a measurement control, read
    /// once at launch, that replaces it (0: every row in the lazy stack).
    @MainActor static var slotCap: Int {
        if let override = slotCapOverride { return override }
        let tallest = NSScreen.screens.map(\.visibleFrame.height).max() ?? 0
        return Int((max(tallest, 1_000) / rowPitch).rounded(.up)) + slotMargin
    }
    /// A one-line `WorkspaceRow` (21 pt, `workspaceRowHeight` in `studio-load`) and the 1 pt gap.
    static let rowPitch: CGFloat = 22
    static let slotMargin = 16
    static let slotCapOverride: Int? =
        ProcessInfo.processInfo.environment["IKKOKU_PERF_WORKSPACE_SLOT_CAP"].flatMap { Int($0) }.map { max(0, $0) }

    @MainActor init() {}

    @MainActor init(model: StudioModel) {
        let selection = model.selection
        let doc = model.doc
        let activeCamera = model.activeSourceCameraView
        // #387 round 3: by index, reading each object in place, instead of
        // `flattened()`, which copied every object twice.
        let objects = doc.objects
        entries = doc.flattenedIndices().map { row in
            let id = objects[row.index].id, name = objects[row.index].name
            // A source camera placeholder reads "IKKOKU-MIRROR" over
            // "camera 2", the title the status line and the view indicator use.
            let label = model.workspaceLabel(id: id, name: name, sourceObjectKey: objects[row.index].sourceObjectKey,
                                             sourceDuplicateOf: objects[row.index].sourceDuplicateOf,
                                             sceneSHA256: doc.sourceSceneSHA256)
            var marker: WorkspaceEntry.CameraMarker?
            if let activeCamera, activeCamera.id == id {
                marker = activeCamera.fallbackReason.map { .savedCameraShown(reason: $0) } ?? .viewing
            }
            return WorkspaceEntry(id: id, name: name, kind: objects[row.index].kind,
                                  visible: objects[row.index].visible, depth: row.depth, selected: selection == id,
                                  cameraPlaceholder: label.sourceCamera, keyDetail: label.keyDetail, cameraMarker: marker)
        }
        objectCount = doc.objects.count
    }

    /// These rows with `selection` selected: what `init(model:)` builds when
    /// only the selection changed (#387 round 3), since `selected` is the
    /// one field that reads it (`selection == id`, per row, so a repeated
    /// id's rows and a selection that is no row behave as there).
    func selecting(_ selection: UUID?) -> StudioWorkspaceState {
        var state = self
        for index in state.entries.indices where state.entries[index].selected != (state.entries[index].id == selection) {
            state.entries[index].selected.toggle()
        }
        return state
    }
}

/// Everything `StudioWorkspaceState` is built from, cheap to build and
/// compare, so a refresh rebuilds the rows only when one of these changed
/// (`StudioModel.workspaceKey()`). Per object, in document order: its id,
/// parent (the tree order and depth), name, kind and visibility, and what
/// its source camera label reads (record key, copy source, camera entry).
/// Then the selection, the scene identity and the active source camera's
/// view. The Debug freshness check compares the published rows with a fresh
/// build after every run-loop turn, so an input missing here fails the lanes.
struct StudioWorkspaceKey: Equatable {
    struct Item: Equatable {
        let id: UUID
        let parent: UUID?
        let name: String
        let kind: StudioObjectKind
        let visible: Bool
        let sourceObjectKey: Int32?
        let sourceDuplicateOf: Int32?
        let cameraSceneSHA256: String?
        let cameraObjectKey: Int32?
    }
    var items: [Item] = []
    var selection: UUID?
    var sceneSHA256: String?
    var activeCamera: StudioModel.SourceCameraView?
}

/// The toolbar's fields that come from the document and the source runtime.
/// Its other fields are the model's own stored settings, which it observes
/// directly.
struct StudioToolbarDocumentState: Equatable {
    var selectedIsCharacter = false
    var cameraSlotsFilled: [Bool] = []
    var hasSourceRoutes = false
    var showGrid = false

    @MainActor init() {}

    @MainActor init(model: StudioModel) {
        selectedIsCharacter = model.selectedObject?.kind == .character
        cameraSlotsFilled = model.doc.cameraSlots.map { $0 != nil }
        hasSourceRoutes = model.hasSourceRoutes
        showGrid = model.doc.effects.showGrid
    }
}

/// The timeline bar's fields that come from the document: its length, loop,
/// the selection's keys and the key count.
struct StudioTimelineDocumentState: Equatable {
    var duration: Float = 0
    var loop = false
    var keys: [StudioTimelineState.Key] = []
    var keyCount = 0
    var hasSelection = false

    @MainActor init() {}

    @MainActor init(model: StudioModel) {
        let timeline = model.doc.timeline
        duration = timeline.duration
        loop = timeline.loop
        keys = model.selectedKeyframes.map { .init(id: $0.id, time: $0.time) }
        keyCount = timeline.keyframes.count
        hasSelection = model.selectedObject != nil
    }
}

extension StudioModel {
    /// The workspace tree as the panel shows it: what the model publishes,
    /// or with `IKKOKU_PERF_PANEL_STATE=document` a build from the document,
    /// which the reading view then observes.
    var shownWorkspaceState: StudioWorkspaceState {
        StudioPanelStateMode.current.publishes ? workspaceState : StudioWorkspaceState(model: self)
    }

    var shownToolbarDocumentState: StudioToolbarDocumentState {
        StudioPanelStateMode.current.publishes ? toolbarDocumentState : StudioToolbarDocumentState(model: self)
    }

    var shownTimelineDocumentState: StudioTimelineDocumentState {
        StudioPanelStateMode.current.publishes ? timelineDocumentState : StudioTimelineDocumentState(model: self)
    }
}
