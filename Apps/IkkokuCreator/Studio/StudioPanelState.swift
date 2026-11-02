import Foundation
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

    @MainActor init() {}

    @MainActor init(model: StudioModel) {
        let selection = model.selection
        let doc = model.doc
        let activeCamera = model.activeSourceCameraView
        entries = doc.flattened().map { entry in
            // A source camera placeholder reads "IKKOKU-MIRROR" over
            // "camera 2", the title the status line and the view indicator use.
            let label = model.workspaceLabel(of: entry.object, sceneSHA256: doc.sourceSceneSHA256)
            var marker: WorkspaceEntry.CameraMarker?
            if let activeCamera, activeCamera.id == entry.object.id {
                marker = activeCamera.fallbackReason.map { .savedCameraShown(reason: $0) } ?? .viewing
            }
            return WorkspaceEntry(id: entry.object.id, name: entry.object.name, kind: entry.object.kind,
                                  visible: entry.object.visible, depth: entry.depth, selected: selection == entry.object.id,
                                  cameraPlaceholder: label.sourceCamera, keyDetail: label.keyDetail, cameraMarker: marker)
        }
        objectCount = doc.objects.count
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
