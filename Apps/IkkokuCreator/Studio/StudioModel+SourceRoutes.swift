import SwiftUI
import simd
import CoreMath
import Scene
import Renderer
import Studio
import Character
import ShaderTypes

/// ST-T11: one route point handle the editor selects, the point itself or
/// its aid (the curve control point `OCIRoutePoint` keeps under the point,
/// whose guide is shown only for a Curve connection).
struct SourceRoutePointSelection: Equatable, Sendable {
    var index: Int
    var aid = false

    init(index: Int, aid: Bool = false) { self.index = index; self.aid = aid }

    /// Pick ids of route point handles: `0xFB00_0000 | index << 1 | aid`,
    /// below the IK (`0xFC`), IK chain, bone and gizmo ranges.
    static let pickBase: UInt32 = 0xFB00_0000
    var pickID: UInt32 { Self.pickBase | (UInt32(index & 0x7F_FFFF) << 1) | (aid ? 1 : 0) }
    init?(pick id: UInt32) {
        guard id & 0xFF00_0000 == Self.pickBase else { return nil }
        index = Int((id & 0x00FF_FFFF) >> 1); aid = id & 1 == 1
    }
}

/// The route editor's runtime bookkeeping (never document state).
struct SourceRouteEditorState {
    /// The route whose point a guide drag is moving. Its playback clock keeps
    /// the path it was built with until the drag ends, so a drag over a
    /// playing route does not rebuild and fast-forward the tween on every
    /// mouse event; `staleClocks` lists the routes to rebuild at mouseUp.
    var dragging: UUID?
    var staleClocks: Set<UUID> = []
    /// Each route's editor line in world space, rebuilt only when the route
    /// world or the playback record changes (a playing route redraws the
    /// frame every tick, the line does not move).
    var lines: [UUID: (world: float4x4, route: KoikatsuRouteRecord, batch: GizmoBatch)] = [:]
}

/// A route point guide drag: a translate drag moves the point (route-local)
/// or its aid (point-local); the start point's drag rotates it.
struct SourceRoutePointDrag {
    let gizmo: GizmoDrag
    let route: UUID
    let point: SourceRoutePointSelection
    /// The handle's engine-space local position at mouseDown.
    let startLocal: Float3
    /// The frame `startLocal` lives in: the route's world matrix for a point,
    /// times the point's local matrix for an aid.
    let parentFrame: float4x4
    /// The start point's world rotation at mouseDown and its parent's (the
    /// route's) world rotation, for the rotate drag.
    let startWorldRotation: simd_quatf
    let parentRotation: simd_quatf
}

/// The route guides of one frame, kept so an orbit or pan drag can rebuild
/// the camera-sized handles without walking the scene again (`CameraReuse`).
struct SourceRouteGuides {
    var lines: [GizmoBatch] = []
    var handles: [(position: Float3, id: UInt32, color: Float4, selected: Bool)] = []
    var gizmo: (mode: GizmoMode, origin: Float3, orientation: simd_quatf)?

    func batches(camera: OrbitCamera, viewport: SIMD2<Float>, highlight: GizmoAxis?) -> [GizmoBatch] {
        var result = lines
        for handle in handles {
            let size = camera.worldUnitsPerPixel(at: handle.position, viewport: viewport)
            result.append(GizmoBuilder.handle(at: handle.position, size: size * (handle.selected ? 9 : 6),
                                              color: handle.color, id: handle.id))
        }
        if let gizmo {
            let size = camera.worldUnitsPerPixel(at: gizmo.origin, viewport: viewport) * 90
            result += GizmoBuilder.build(mode: gizmo.mode, origin: gizmo.origin, orientation: gizmo.orientation,
                                         size: size, highlight: highlight)
        }
        return result
    }
}

extension SourceRouteRuntime {
    /// Applies the document's edit state (nil: the authored record) and
    /// reports whether playback changed: points, loop or orientation, as
    /// opposed to the line's visibility or colour only.
    mutating func apply(_ state: SourceStudioRouteState?) -> Bool {
        let next = state.map { $0.record(authored: authored) } ?? authored
        let playback = next.points != route.points || next.loop != route.loop || next.orientation != route.orientation
        route = next; applied = state
        if playback { pointLocals = SourceStudioRoutePlayback.pointLocals(from: next) }
        return playback
    }
}

extension StudioModel {
    // MARK: Route state

    /// ST-T11: a route object's edit state: the document's edits, or the
    /// record's own state (the import's record, or the original's for a copy).
    func sourceRouteState(_ id: UUID) -> SourceStudioRouteState? {
        guard let runtime = sourceRouteRuntime(id: id, document: doc) else { return nil }
        return doc.object(id)?.sourceRoute ?? SourceStudioRouteState(record: runtime.authored)
    }

    /// The record the route's playback, line and children currently use.
    func sourceRoutePlaybackRecord(_ id: UUID) -> KoikatsuRouteRecord? {
        sourceRouteRuntime(id: id, document: doc)?.route
    }

    func isSourceRoutePlaying(_ id: UUID) -> Bool {
        sourceRoutePlayState[id]?.playing ?? sourceRoutes[id]?.route.active ?? false
    }

    /// The selected route point, if it still names a point of the selected
    /// route (an aid only while its point is a curve): a delete or an undo
    /// can leave `selectedRoutePoint` past the end.
    var selectedSourceRoutePoint: SourceRoutePointSelection? {
        guard let point = selectedRoutePoint, let id = selection, let state = sourceRouteState(id),
              state.points.indices.contains(point.index), !point.aid || state.points[point.index].isCurve else { return nil }
        return point
    }

    /// Every route edit goes through here: the inspector, the point guides
    /// and the scenario runner. A setting CharaStudio greys out while the
    /// route plays is refused with the reason in `status`; a delete stops the
    /// route first (`OCIRoute.DeletePoint` calls `Stop`). A state equal to the
    /// record's own is stored as nil, so an edit undone by hand exports
    /// nothing. Returns whether the change was accepted.
    @discardableResult
    func editSourceRoute(_ id: UUID, _ setting: SourceStudioRouteState.Setting, point: Int? = nil,
                         pushHistory: Bool = true, _ change: (inout SourceStudioRouteState) throws -> Void) -> Bool {
        guard let i = doc.index(of: id), let runtime = sourceRouteRuntime(id: id, document: doc) else {
            status = "Route edits need an imported route."
            return false
        }
        let playing = isSourceRoutePlaying(id)
        if playing && setting.lockedWhilePlaying {
            status = "Route \(runtime.objectKey): stop the route first; CharaStudio greys out \(setting) while it plays."
            return false
        }
        var state = doc.objects[i].sourceRoute ?? SourceStudioRouteState(record: runtime.authored)
        if let point, setting == .speed || setting == .ease, state.speedAndEaseLocked(at: point) {
            status = "Route \(runtime.objectKey): point \(point) is linked to the curve before it, which sets its speed and ease."
            return false
        }
        do { try change(&state) } catch {
            status = "Route \(runtime.objectKey): \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            return false
        }
        let value: SourceStudioRouteState? = state == SourceStudioRouteState(record: runtime.authored) ? nil : state
        guard value != doc.objects[i].sourceRoute else { return true }
        if pushHistory { pushUndo(force: true) }
        if setting == .delete, playing { sourceRoutePlayState[id] = (playing: false, start: 0) }
        doc.objects[i].sourceRoute = value
        return true
    }

    /// The route panel's "add point" (`OCIRoute.AddPoint`): appends after the
    /// last point and selects the new point, as CharaStudio selects its node.
    @discardableResult
    func addSourceRoutePoint(_ id: UUID) -> Int? {
        var added: Int?
        guard editSourceRoute(id, .addPoint, { added = try $0.addPoint() }), let added else { return nil }
        selectedRoutePoint = .init(index: added)
        status = "Route point \(added) added"
        return added
    }

    /// Deleting a route point node (`OCIRoutePoint.OnDelete` →
    /// `OCIRoute.DeletePoint`).
    @discardableResult
    func deleteSourceRoutePoint(_ id: UUID, index: Int) -> Bool {
        guard editSourceRoute(id, .delete, { try $0.deletePoint(index) }) else { return false }
        selectedRoutePoint = nil
        status = "Route point \(index) deleted"
        return true
    }

    /// Keeps each route runtime equal to its document edit state, after the
    /// prune in `refreshFrame`. A change that moves the path (points, loop,
    /// orientation) drops the route's playback clock, which the next
    /// placement rebuilds from the route's play start; during a point drag
    /// that rebuild waits for mouseUp. Nothing runs for an unchanged route
    /// but one comparison.
    func applySourceRouteEdits() {
        for (id, runtime) in sourceRoutes {
            let state = doc.object(id)?.sourceRoute
            guard state != runtime.applied else { continue }
            var updated = runtime
            let playback = updated.apply(state)
            sourceRoutes[id] = updated
            guard playback else { continue }
            if sourceRouteEditor.dragging == id {
                sourceRouteEditor.staleClocks.insert(id)
            } else {
                sourceRouteClocks[id] = nil
                sourceRouteFallbackReported.remove(id)
            }
        }
    }

    // MARK: Guides

    /// A route point's engine-space local matrix under the route.
    static func sourceRoutePointLocal(_ point: SourceStudioRouteState.Point) -> float4x4 {
        Transform.trs(UnityCoordinates.position(point.position), UnityCoordinates.eulerDegrees(point.rotationDegrees), point.scale)
    }
    /// An aid's engine-space local matrix under its point.
    static func sourceRouteAidLocal(_ point: SourceStudioRouteState.Point) -> float4x4 {
        Transform.trs(UnityCoordinates.position(point.aidPosition), UnityCoordinates.eulerDegrees(point.aidRotationDegrees), point.aidScale)
    }

    /// Where a selected handle's guide sits and how it drags: the start point
    /// rotates, every other point and an aid translate.
    private func sourceRouteHandleFrame(route id: UUID, point: SourceRoutePointSelection, state: SourceStudioRouteState) throws
        -> (mode: GizmoMode, origin: Float3, orientation: simd_quatf, startLocal: Float3, parentFrame: float4x4,
            startWorldRotation: simd_quatf, parentRotation: simd_quatf) {
        let routeWorld = try sourceObjectWorldMatrix(id)
        let routeRotation = routeWorld.rotationQuaternion
        let value = state.points[point.index]
        let pointWorld = routeWorld * Self.sourceRoutePointLocal(value)
        let pointRotation = (routeRotation * UnityCoordinates.eulerDegrees(value.rotationDegrees)).normalized
        if point.aid {
            let aidRotation = (pointRotation * UnityCoordinates.eulerDegrees(value.aidRotationDegrees)).normalized
            let origin = (pointWorld * Self.sourceRouteAidLocal(value)).translation
            return (.translate, origin, localSpace ? aidRotation : .identity, UnityCoordinates.position(value.aidPosition),
                    pointWorld, aidRotation, pointRotation)
        }
        return (point.index == 0 ? .rotate : .translate, pointWorld.translation, localSpace ? pointRotation : .identity,
                UnityCoordinates.position(value.position), routeWorld, pointRotation, routeRotation)
    }

    /// The route lines (every visible route whose line is on, in its own
    /// colour, as `OCIRoute.OnVisible` shows `line`) and, for the selected
    /// route, a handle per point and per curve aid plus the selected
    /// handle's guide.
    func sourceRouteGuides() -> SourceRouteGuides {
        var guides = SourceRouteGuides()
        if sourceRouteEditor.lines.count > sourceRoutes.count {
            sourceRouteEditor.lines = sourceRouteEditor.lines.filter { sourceRoutes[$0.key] != nil }
        }
        for (id, runtime) in sourceRoutes where runtime.route.visibleLine && runtime.route.points.count > 1 {
            guard runtime.sceneSHA256 == doc.sourceSceneSHA256, doc.isVisible(id),
                  let world = try? sourceObjectWorldMatrix(id) else { continue }
            if let cached = sourceRouteEditor.lines[id], cached.world == world, cached.route == runtime.route {
                guides.lines.append(cached.batch); continue
            }
            let color = runtime.route.color
            let vertices = SourceStudioRoutePlayback.pathLines(route: runtime.route, routeWorld: world,
                                                               pointLocals: runtime.pointLocals)
                .map { GizmoVertex(position: $0, color: color) }
            let batch = GizmoBatch(primitive: .lines, vertices: vertices, depthTest: true)
            sourceRouteEditor.lines[id] = (world, runtime.route, batch)
            if !vertices.isEmpty { guides.lines.append(batch) }
        }
        guard let id = selection, let state = sourceRouteState(id), let routeWorld = try? sourceObjectWorldMatrix(id) else { return guides }
        let selected = selectedSourceRoutePoint
        for (index, point) in state.points.enumerated() {
            let pointWorld = routeWorld * Self.sourceRoutePointLocal(point)
            let handle = SourceRoutePointSelection(index: index)
            guides.handles.append((pointWorld.translation, handle.pickID,
                                   selected == handle ? Float4(1, 0.9, 0.2, 1) : index == 0 ? Float4(0.35, 1, 0.45, 1) : Float4(0.3, 0.9, 1, 0.9),
                                   selected == handle))
            guard point.isCurve else { continue }
            let aid = SourceRoutePointSelection(index: index, aid: true)
            guides.handles.append(((pointWorld * Self.sourceRouteAidLocal(point)).translation, aid.pickID,
                                   selected == aid ? Float4(1, 0.9, 0.2, 1) : Float4(1, 0.45, 0.85, 0.9), selected == aid))
        }
        if let selected, let frame = try? sourceRouteHandleFrame(route: id, point: selected, state: state) {
            guides.gizmo = (frame.mode, frame.origin, frame.orientation)
        }
        return guides
    }

    /// Scenario support: the pixel a route handle projects to.
    func sourceRouteHandlePixel(_ id: UUID, point: SourceRoutePointSelection) -> SIMD2<Float>? {
        guard let state = sourceRouteState(id), state.points.indices.contains(point.index),
              let routeWorld = try? sourceObjectWorldMatrix(id) else { return nil }
        let value = state.points[point.index]
        var world = routeWorld * Self.sourceRoutePointLocal(value)
        if point.aid { world = world * Self.sourceRouteAidLocal(value) }
        return viewCamera.project(world.translation, viewport: viewportSize)
    }

    /// Scenario support: candidate pixels on the selected handle's guide for
    /// one axis (along a translate arrow, around a rotate ring), so the
    /// runner can find one the pick pass attributes to that axis.
    func sourceRouteGuidePixels(axis: GizmoAxis) -> [SIMD2<Float>] {
        guard let id = selection, let point = selectedSourceRoutePoint, let state = sourceRouteState(id),
              let frame = try? sourceRouteHandleFrame(route: id, point: point, state: state),
              (1...3).contains(axis.rawValue) else { return [] }
        let size = viewCamera.worldUnitsPerPixel(at: frame.origin, viewport: viewportSize) * 90
        let axes = [Float3(1, 0, 0), Float3(0, 1, 0), Float3(0, 0, 1)].map { frame.orientation.act($0) }
        let direction = axes[axis.rawValue - 1]
        var points: [Float3] = []
        if frame.mode == .rotate {
            let (u, v) = (axes[axis.rawValue % 3], axes[(axis.rawValue + 1) % 3])
            for step in 0..<24 {
                let angle = Float(step) * .pi / 12
                points.append(frame.origin + (u * cos(angle) + v * sin(angle)) * size * 0.9)
            }
        } else {
            for fraction: Float in [0.92, 0.88, 0.96, 0.84, 0.7, 0.5, 0.3] { points.append(frame.origin + direction * size * fraction) }
        }
        return points.compactMap { viewCamera.project($0, viewport: viewportSize) }
    }

    /// mouseDown on the selected handle's guide axis. The caller pushes the
    /// undo snapshot when this returns a drag.
    func beginSourceRoutePointDrag(axis: GizmoAxis, ray: Ray, cameraForward: Float3) -> SourceRoutePointDrag? {
        guard let id = selection, let point = selectedSourceRoutePoint, let state = sourceRouteState(id) else { return nil }
        do {
            let frame = try sourceRouteHandleFrame(route: id, point: point, state: state)
            guard let gizmo = GizmoDrag(mode: frame.mode, axis: axis, origin: frame.origin, orientation: frame.orientation,
                                        ray: ray, cameraForward: cameraForward) else { return nil }
            sourceRouteEditor.dragging = id
            return SourceRoutePointDrag(gizmo: gizmo, route: id, point: point, startLocal: frame.startLocal,
                                        parentFrame: frame.parentFrame, startWorldRotation: frame.startWorldRotation,
                                        parentRotation: frame.parentRotation)
        } catch {
            status = "Route point guide: \(error)"
            return nil
        }
    }

    func dragSourceRoutePoint(_ drag: SourceRoutePointDrag, ray: Ray) {
        if drag.gizmo.mode == .rotate {
            guard let rotation = drag.gizmo.rotation(for: ray) else { return }
            let local = (drag.parentRotation.inverse * rotation * drag.startWorldRotation).normalized
            editSourceRoute(drag.route, .move, pushHistory: false) { try $0.rotateStart(to: UnityCoordinates.sourceEulerDegrees(local)) }
            return
        }
        guard let translation = drag.gizmo.translation(for: ray) else { return }
        let local = UnityCoordinates.position(drag.startLocal + drag.parentFrame.inverse.transformDirection(translation))
        editSourceRoute(drag.route, .move, pushHistory: false) {
            if drag.point.aid { try $0.moveAid(drag.point.index, to: local) } else { try $0.movePoint(drag.point.index, to: local) }
        }
    }

    /// The drag ended (mouseUp, or a gesture that replaced it): a route whose
    /// path moved during the drag rebuilds its playback clock now.
    func endSourceRoutePointDrag(_ drag: SourceRoutePointDrag) {
        sourceRouteEditor.dragging = nil
        guard sourceRouteEditor.staleClocks.remove(drag.route) != nil else { return }
        sourceRouteClocks[drag.route] = nil
        sourceRouteFallbackReported.remove(drag.route)
        refresh()
    }

    // MARK: Duplicate

    /// ST-T03 / ST-T11: the preview of a route character's copy, built from
    /// its original's reference (a route child's document entry is a
    /// placeholder without one). The one construction site for copies, so a
    /// faster or asynchronous character build can route it.
    func makeSourceRouteCharacterPreview(like original: SourceStudioCharacterPreview) throws -> SourceStudioCharacterPreview {
        let preview = try SourceStudioCharacterPreview(reference: original.reference, resources: host.renderer.resources)
        preview.automaticBlink = sourceAutomaticBlink
        return preview
    }

    /// The runtime entries a duplicated route subtree renders from: a route
    /// copy shares its original's runtime (the copy's document entry carries
    /// the same edits) and, like CharaStudio's Save + Import of a playing
    /// route, plays from point 0 at the duplicate instant; a route character
    /// copy gets its own preview.
    func copySourceRouteRuntime(from original: UUID, to copy: UUID) {
        if let runtime = sourceRoutes[original] {
            sourceRoutes[copy] = runtime
            sourceRoutePlayState[copy] = isSourceRoutePlaying(original)
                ? (playing: true, start: sourceAnimationTime) : (playing: false, start: 0)
        }
        if let preview = sourceRouteCharacterPreviews[original] {
            do { sourceRouteCharacterPreviews[copy] = try makeSourceRouteCharacterPreview(like: preview) }
            catch { status = "Route character copy: \(error)" }
        }
    }
}

/// The route panels (`MPRouteCtrl`, `MPRoutePointCtrl`): play state, loop,
/// line, orientation and colour of the route; add and delete points; the
/// selected point's position (or the start point's rotation), speed, ease,
/// connection and link. The controls CharaStudio greys out while the route
/// plays are disabled the same way.
struct SourceRouteInspector: View {
    let model: StudioModel
    let id: UUID
    let playing: Bool
    let route: SourceStudioRouteState
    let point: SourceRoutePointSelection?

    var body: some View {
        SectionBox(title: "Route") {
            Text("Route: \(playing ? "Playing" : "Stopped")").font(.callout)
            HStack {
                Button(playing ? "Stop" : "Play") { model.toggleSourceRoute(id) }
                    .help(playing ? "Stop this route (Stop pins its children to point 0)" : "Play this route from the current time")
            }
            Toggle("Loop", isOn: Binding(get: { route.loop }, set: { v in model.editSourceRoute(id, .loop) { $0.loop = v } }))
                .disabled(playing)
            Toggle("Show line", isOn: Binding(get: { route.visibleLine }, set: { v in model.editSourceRoute(id, .visibleLine) { $0.visibleLine = v } }))
            Picker("Orient", selection: Binding(get: { route.orientation }, set: { v in
                model.editSourceRoute(id, .orientation) { $0.setOrientation(SourceStudioRoute.Orientation(rawValue: v) ?? .none) }
            })) {
                Text("None").tag(Int32(0)); Text("XY").tag(Int32(1)); Text("Y").tag(Int32(2))
            }.disabled(playing)
            ColorRow(label: "Line colour", color: Binding(get: { RGB(route.color.x, route.color.y, route.color.z) }, set: { v in
                let c = v.float3
                model.editSourceRoute(id, .color) { try $0.setColor(red: c.x, green: c.y, blue: c.z) }
            }))
            HStack {
                Button("Add point") { model.addSourceRoutePoint(id) }
                    .disabled(playing || route.points.count >= SourceStudioRouteState.pointLimit)
                Text("\(route.points.count) of \(SourceStudioRouteState.pointLimit) points").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Point", selection: Binding(get: { point?.index ?? -1 }, set: { model.selectedRoutePoint = $0 < 0 ? nil : .init(index: $0) })) {
                Text("None").tag(-1)
                ForEach(route.points.indices, id: \.self) { i in Text(i == 0 ? "Start" : "Point \(i)").tag(i) }
            }
            if let point, route.points.indices.contains(point.index) { pointControls(point.index) }
            Text("Point moves, added and deleted points and these settings are written into the exported original scene; the play state is saved as the route's active flag.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func pointControls(_ index: Int) -> some View {
        let value = route.points[index]
        let locked = playing || route.speedAndEaseLocked(at: index)
        if index == 0 {
            VectorRow(label: "Rotation", value: Binding(get: { value.rotationDegrees }, set: { v in
                model.editSourceRoute(id, .move) { try $0.rotateStart(to: v) }
            }), step: 5, format: "%.1f")
        } else {
            VectorRow(label: "Position", value: Binding(get: { value.position }, set: { v in
                model.editSourceRoute(id, .move) { try $0.movePoint(index, to: v) }
            }), step: 0.05, format: "%.3f")
            Button("Delete point") { model.deleteSourceRoutePoint(id, index: index) }
        }
        FloatRow(label: "Speed", value: Binding(get: { value.speed }, set: { v in
            model.editSourceRoute(id, .speed, point: index) { try $0.setSpeed(index, v) }
        }), range: SourceStudioRouteState.speedRange).disabled(locked)
        Picker("Ease", selection: Binding(get: { value.easeType }, set: { v in
            model.editSourceRoute(id, .ease, point: index) { try $0.setEase(index, SourceStudioRoute.EaseType(rawValue: v) ?? .linear) }
        })) {
            ForEach(SourceStudioRouteState.easeChoices, id: \.ease) { choice in Text(choice.name).tag(choice.ease.rawValue) }
            if !SourceStudioRouteState.easeChoices.contains(where: { $0.ease.rawValue == value.easeType }) {
                Text("Saved (\(value.easeType))").tag(value.easeType)
            }
        }.disabled(locked)
        Picker("Connection", selection: Binding(get: { value.connection }, set: { v in
            model.editSourceRoute(id, .connection) { try $0.setConnection(index, SourceStudioRoute.Connection(rawValue: v) ?? .line) }
        })) {
            Text("Line").tag(Int32(0)); Text("Curve").tag(Int32(1))
        }.disabled(playing)
        Toggle("Link", isOn: Binding(get: { value.linked }, set: { v in model.editSourceRoute(id, .link) { try $0.setLink(index, v) } }))
            .disabled(playing)
        if value.isCurve {
            Button("Select aid") { model.selectedRoutePoint = .init(index: index, aid: true) }
        }
    }
}
