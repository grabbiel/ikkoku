import SwiftUI
import AppKit
import simd
import CoreMath
import Scene
import Renderer
import Character
import Studio
import Assets

enum PoseMode: String, CaseIterable, Identifiable { case object = "Object", fk = "FK", ik = "IK"; var id: String { rawValue } }

enum FKGroup: String, CaseIterable, Identifiable {
    case body = "Body", hands = "Hands", face = "Head & bust", all = "All"
    var id: String { rawValue }
    func contains(_ bone: String) -> Bool {
        let finger = ["thumb", "index", "middle", "ring", "pinky"].contains { bone.hasPrefix($0) }
        switch self {
        case .all: return true
        case .hands: return finger
        case .face: return bone.hasPrefix("head") || bone.hasPrefix("neck") || bone.hasPrefix("eye") || bone.hasPrefix("bust") || bone == "jaw"
        case .body: return !finger && !bone.hasPrefix("eye") && bone != "head_top" && bone != "root" && !bone.hasPrefix("bust")
        }
    }
}

/// CharaStudio-like scene editor: object tree, gizmos, FK/IK posing, lights, camera slots, captures.
@MainActor @Observable
final class StudioModel: ViewportInputHandler {
    let host: EngineHost
    var doc = StudioDocument() { didSet { refresh() } }
    var selection: UUID? { didSet { if selection != oldValue { selectedBone = nil; refresh() } } }
    var gizmoMode: GizmoMode = .translate { didSet { refresh() } }
    var localSpace = true { didSet { refresh() } }
    var poseMode: PoseMode = .object { didSet { refresh() } }
    var fkGroup: FKGroup = .body { didSet { refresh() } }
    var selectedBone: Int? { didSet { refresh() } }
    var selectedIK: IKChain? { didSet { refresh() } }
    var showGizmos = true { didSet { refresh() } }
    var inspectorTab: InspectorTab = .object
    var viewportSize = SIMD2<Float>(1600, 1200)
    var status = "Ready"
    var frame = RenderFrame()
    var captureSize: (Int, Int) { (doc.captureWidth, doc.captureHeight) }
    var sceneURL: URL?
    private(set) var undoStack: [StudioDocument] = []
    private(set) var redoStack: [StudioDocument] = []
    @ObservationIgnored private var instances: [UUID: CharacterInstance] = [:]
    @ObservationIgnored private var nextInstanceID: UInt64 = 100
    @ObservationIgnored private var drag: DragState?
    @ObservationIgnored private var hoverAxis: GizmoAxis?
    @ObservationIgnored private var lastUndoPush = Date.distantPast
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startTime = CFAbsoluteTimeGetCurrent()
    @ObservationIgnored private var animTime: Double = 0
    var liveAnimation = true
    var isActiveMode = false
    // Timeline
    var timelinePlaying = false
    var timelineTime: Float = 0 { didSet { refresh() } }
    var showTimeline = true

    enum InspectorTab: String, CaseIterable, Identifiable { case object = "Object", pose = "Pose", face = "Face", clothes = "Clothes", scene = "Scene"; var id: String { rawValue } }

    private enum DragState {
        case orbit, pan
        case gizmo(GizmoDrag, start: StudioTransform)
        case bone(GizmoDrag, boneIndex: Int, startWorldRot: simd_quatf, startDelta: PoseDelta)
        case ik(GizmoDrag, chain: IKChain, start: Float3)
    }

    init(host: EngineHost) {
        self.host = host
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard isActiveMode, drag == nil else { return }
        if timelinePlaying {
            var t = timelineTime + 1.0 / 30.0
            if t > doc.timeline.duration { t = doc.timeline.loop ? 0 : doc.timeline.duration; if !doc.timeline.loop { timelinePlaying = false } }
            timelineTime = t          // triggers refresh
            return
        }
        guard liveAnimation, doc.objects.contains(where: { $0.kind == .character }) else { return }
        animTime = CFAbsoluteTimeGetCurrent() - startTime
        refresh()
    }

    // MARK: Timeline

    func addKeyframe() {
        guard let o = selectedObject, o.kind == .character || o.kind == .item || o.kind == .light else { return }
        pushUndo(force: true)
        doc.timeline.insert(Keyframe(time: timelineTime, object: o))
        status = "Keyframe at \(String(format: "%.2f", timelineTime)) s"
    }
    func deleteKeyframe(_ id: UUID) { pushUndo(force: true); doc.timeline.keyframes.removeAll { $0.id == id } }
    func clearTimeline() { pushUndo(force: true); doc.timeline = Timeline(); timelineTime = 0; timelinePlaying = false }
    var selectedKeyframes: [Keyframe] { selection.map { doc.timeline.keyframes(for: $0) } ?? [] }

    /// The object as it should appear at the current timeline time (keyframes override the stored state while playing/scrubbing).
    private func timelineState(_ o: StudioObject) -> StudioObject {
        guard !doc.timeline.keyframes.isEmpty, let k = doc.timeline.sample(object: o.id, time: timelineTime) else { return o }
        var r = o
        r.transform = k.transform
        r.poseDelta = k.poseDelta
        r.ikTargets = k.ikTargets
        r.handGestureL = k.handGestureL
        r.handGestureR = k.handGestureR
        r.animationPreset = k.animationPreset
        if let e = k.expression { r.card?.expression = e }
        return r
    }

    var library: AssetLibrary { host.library }
    var selectedObject: StudioObject? { selection.flatMap { doc.object($0) } }
    var selectedInstance: CharacterInstance? { selection.flatMap { instances[$0] } }

    // MARK: Object management

    private func pushUndo(force: Bool = false) {
        if !force && Date().timeIntervalSince(lastUndoPush) < 0.4 { return }
        undoStack.append(doc)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastUndoPush = Date()
    }

    func undo() { guard let d = undoStack.popLast() else { return }; redoStack.append(doc); doc = d; status = "Undo" }
    func redo() { guard let d = redoStack.popLast() else { return }; undoStack.append(doc); doc = d; status = "Redo" }

    func add(_ object: StudioObject, select: Bool = true) {
        pushUndo(force: true)
        var o = object
        if let sel = selectedObject, sel.kind == .folder { o.parent = sel.id }
        doc.objects.append(o)
        if select { selection = o.id }
        status = "Added \(o.name)"
    }

    func addCharacter(_ card: CharacterCard) {
        var o = StudioObject.character(card)
        let count = doc.objects.filter { $0.kind == .character }.count
        o.transform.position = Float3(Float(count) * 0.7 - Float(count) * 0.35, 0, 0)
        add(o)
    }
    func addCharacter(sex: Sex) { addCharacter(sex == .female ? .defaultFemale() : .defaultMale()) }
    func addItem(id: String) {
        guard let e = library.catalog.item(id) else { return }
        add(.item(id: id, name: e.name))
    }
    func addLight(_ kind: LightKind) { add(.light(kind)) }
    func addFolder() { add(StudioObject(name: "Folder", kind: .folder)) }
    func addCamera() {
        var o = StudioObject(name: "Camera \(doc.objects.filter { $0.kind == .camera }.count + 1)", kind: .camera)
        o.savedCamera = doc.camera
        o.transform.position = doc.camera.position
        add(o)
    }

    func deleteSelection() {
        guard let id = selection else { return }
        pushUndo(force: true)
        doc.remove(id)
        instances[id] = nil
        selection = nil
    }

    func duplicateSelection() {
        guard var o = selectedObject else { return }
        pushUndo(force: true)
        o.id = UUID()
        o.name += " copy"
        o.transform.position.x += 0.5
        doc.objects.append(o)
        selection = o.id
    }

    func setParent(_ id: UUID, to parent: UUID?) {
        guard let i = doc.index(of: id) else { return }
        if let p = parent, p == id || doc.isDescendant(p, of: id) { return }
        pushUndo(force: true)
        let world = doc.worldMatrix(of: id)
        doc.objects[i].parent = parent
        // keep world placement
        let parentWorld = parent.map { doc.worldMatrix(of: $0) } ?? matrix_identity_float4x4
        let local = parentWorld.inverse * world
        doc.objects[i].transform.position = local.translation
        doc.objects[i].transform.rotation = local.rotationQuaternion.eulerXYZ.radiansToDegrees
        doc.objects[i].transform.scale = local.scaleFactors
    }

    func update(_ id: UUID, _ change: (inout StudioObject) -> Void) {
        guard let i = doc.index(of: id) else { return }
        pushUndo()
        change(&doc.objects[i])
    }
    func updateSelected(_ change: (inout StudioObject) -> Void) { if let id = selection { update(id, change) } }

    // MARK: Scene I/O

    func newScene() { pushUndo(force: true); doc = StudioDocument(); instances.removeAll(); selection = nil; sceneURL = nil }

    func saveScene(to url: URL) throws {
        var f = frame
        f.effects.showGrid = false
        f.gizmos = []
        let thumb = host.renderer.capture(frame: f, width: 640, height: 360)
        let data = try CardIO.encode(doc, keyword: CardIO.sceneKeyword, thumbnail: thumb)
        try data.write(to: url)
        sceneURL = url
        status = "Saved scene \(url.lastPathComponent)"
    }

    func loadScene(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let d = try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: data)
        pushUndo(force: true)
        instances.removeAll()
        selection = nil
        doc = d
        sceneURL = url
        status = "Loaded scene \(url.lastPathComponent)"
    }

    func importScene(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let d = try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: data)
        pushUndo(force: true)
        var remap: [UUID: UUID] = [:]
        for o in d.objects { remap[o.id] = UUID() }
        for var o in d.objects {
            o.id = remap[o.id]!
            o.parent = o.parent.flatMap { remap[$0] }
            doc.objects.append(o)
        }
        status = "Imported \(d.objects.count) objects"
    }

    // MARK: Camera

    func resetCamera() { doc.camera = StudioDocument().camera }
    func saveCameraSlot(_ i: Int) { guard i >= 0, i < 10 else { return }; doc.cameraSlots[i] = doc.camera; status = "Camera slot \(i + 1) saved" }
    func loadCameraSlot(_ i: Int) { guard i >= 0, i < 10, let c = doc.cameraSlots[i] else { status = "Camera slot \(i + 1) is empty"; return }; doc.camera = c }
    func focusSelection() {
        guard let id = selection else { return }
        let m = doc.worldMatrix(of: id)
        var c = doc.camera
        if let o = doc.object(id), o.kind == .character { c.target = m.transformPoint(Float3(0, 0.9, 0)); c.distance = 3 }
        else { c.target = m.translation; c.distance = max(1, c.distance * 0.6) }
        doc.camera = c
    }
    func lookThrough(_ id: UUID) { if let cam = doc.object(id)?.savedCamera { doc.camera = cam } }
    func updateCameraObject(_ id: UUID) { update(id) { $0.savedCamera = self.doc.camera; $0.transform.position = self.doc.camera.position } }

    // MARK: Frame building

    private func instance(for o: StudioObject) -> CharacterInstance {
        if let inst = instances[o.id] { return inst }
        let inst = CharacterInstance(instanceID: nextInstanceID, library: library, card: o.card ?? .defaultFemale())
        nextInstanceID += 1
        instances[o.id] = inst
        return inst
    }

    func refresh() {
        var items: [RenderItem] = []
        var skinSets: [UInt64: [float4x4]] = [:]
        var lights: [SceneLight] = []
        var gizmos: [GizmoBatch] = []
        var bounds = AABB.empty
        var lightGlyphs: [(Float3, Float3)] = []

        let animated = !doc.timeline.keyframes.isEmpty
        var animatedDoc = doc
        if animated { for i in animatedDoc.objects.indices { animatedDoc.objects[i] = timelineState(animatedDoc.objects[i]) } }
        for (index, o) in animatedDoc.objects.enumerated() {
            let objectID = UInt32(index + 1)
            let world = animatedDoc.worldMatrix(of: o.id)
            guard doc.isVisible(o.id) else { continue }
            switch o.kind {
            case .character:
                let inst = instance(for: o)
                if let card = o.card, inst.card != card { inst.card = card }
                inst.poseDelta = combinedPoseDelta(o)
                if liveAnimation {
                    inst.poseDelta.merge(LiveAnimation.breathing(time: animTime, seed: inst.instanceID, strength: 0.8))
                    let blink = (o.card?.expression.blink ?? true) ? LiveAnimation.blinkWeight(time: animTime, seed: inst.instanceID) : 0
                    inst.extraMorphs = ["exp.blink_L": blink, "exp.blink_R": blink]
                } else { inst.extraMorphs = [:] }
                inst.ikTargets = o.ikTargets
                inst.transform = world
                if liveAnimation { inst.stepHairDynamics(dt: 1.0 / 30.0) }
                inst.transform = world
                inst.gazeTarget = gazeTarget(for: o, root: world)
                inst.clothingVisible = o.clothingVisible
                inst.accessoriesVisible = o.accessoriesVisible
                let r = inst.build(objectID: objectID)
                items += r.items
                skinSets[inst.instanceID] = r.skinSet
                bounds.expand(r.bounds)
                if showGizmos, selection == o.id {
                    gizmos += characterGizmos(o, inst: inst, result: r)
                }
            case .item:
                guard let iid = o.itemID, let e = library.catalog.item(iid), let a = library.asset(e.file) else { continue }
                for part in a.parts {
                    let mat = MaterialBuilder.itemMaterial(for: part, asset: a, tint: o.tint, emissive: o.emissive)
                    let model = world * part.worldMatrix
                    var ri = RenderItem(mesh: part.mesh, material: mat, model: model, objectID: objectID)
                    ri.order = 35
                    items.append(ri)
                    bounds.expand(part.bounds.transformed(by: model))
                }
            case .light:
                guard var l = o.light else { continue }
                l.position = world.translation
                l.rotation = world.rotationQuaternion.eulerXYZ.radiansToDegrees
                lights.append(l)
                let p = l.position
                let d = l.direction
                switch l.kind {
                case .point:
                    for a in [Float3(1, 0, 0), Float3(0, 1, 0), Float3(0, 0, 1)] { lightGlyphs.append((p - a * 0.12, p + a * 0.12)) }
                case .spot:
                    lightGlyphs.append((p, p + d * 0.5))
                    let (u, v) = (normalize(cross(d, abs(d.y) < 0.9 ? Float3(0, 1, 0) : Float3(1, 0, 0))), Float3(0, 0, 0))
                    _ = v
                    let w = cross(d, u)
                    let r = tan(l.spotAngle.degreesToRadians * 0.5) * 0.5
                    for k in 0..<8 {
                        let t0 = Float(k) / 8 * 2 * .pi, t1 = Float(k + 1) / 8 * 2 * .pi
                        let c0 = p + d * 0.5 + (u * cos(t0) + w * sin(t0)) * r, c1 = p + d * 0.5 + (u * cos(t1) + w * sin(t1)) * r
                        lightGlyphs.append((c0, c1))
                        if k % 2 == 0 { lightGlyphs.append((p, c0)) }
                    }
                case .directional:
                    lightGlyphs.append((p, p + d * 0.6))
                    lightGlyphs.append((p + Float3(0.1, 0, 0), p + Float3(0.1, 0, 0) + d * 0.6))
                    lightGlyphs.append((p - Float3(0.1, 0, 0), p - Float3(0.1, 0, 0) + d * 0.6))
                }
            case .camera:
                let p = world.translation
                lightGlyphs.append((p - Float3(0.08, 0, 0), p + Float3(0.08, 0, 0)))
                lightGlyphs.append((p - Float3(0, 0.08, 0), p + Float3(0, 0.08, 0)))
                lightGlyphs.append((p, p + (o.savedCamera?.forward ?? Float3(0, 0, -1)) * 0.3))
            case .folder:
                break
            }
        }
        if !lightGlyphs.isEmpty && showGizmos {
            gizmos.append(GizmoBuilder.lines(lightGlyphs, color: Float4(1, 0.85, 0.3, 1), depthTest: false))
        }
        // Selection gizmo
        if showGizmos, let sel = selectedObject, sel.kind != .folder, poseMode == .object || sel.kind != .character {
            let m = doc.worldMatrix(of: sel.id)
            let origin = m.translation
            let orient = localSpace ? m.rotationQuaternion : .identity
            let size = doc.camera.worldUnitsPerPixel(at: origin, viewport: viewportSize) * 110
            gizmos += GizmoBuilder.build(mode: gizmoMode, origin: origin, orientation: orient, size: size, highlight: hoverAxis)
        }
        if bounds.isEmpty { bounds = AABB(min: Float3(-1, 0, -1), max: Float3(1, 2, 1)) }
        var f = RenderFrame(camera: doc.camera, mainLight: doc.mainLight, lights: lights, items: items, gizmos: gizmos, effects: doc.effects, sceneBounds: bounds)
        f.skinSets = skinSets
        frame = f
        host.renderer.submit(f)
    }

    private func combinedPoseDelta(_ o: StudioObject) -> PoseDelta {
        var d = PoseDelta()
        if let pid = o.animationPreset, let p = PosePresets.preset(pid) { d.merge(p.delta) }
        d.merge(PosePresets.handDelta(gesture: o.handGestureL, side: "L"))
        d.merge(PosePresets.handDelta(gesture: o.handGestureR, side: "R"))
        d.merge(o.poseDelta)
        return d
    }

    private func characterGizmos(_ o: StudioObject, inst: CharacterInstance, result r: CharacterInstance.BuildResult) -> [GizmoBatch] {
        var out: [GizmoBatch] = []
        guard let skel = inst.skeleton else { return out }
        let root = inst.rootMatrix
        let px = doc.camera.worldUnitsPerPixel(at: root.translation, viewport: viewportSize)
        if poseMode == .fk {
            var lines: [(Float3, Float3)] = []
            for (i, b) in skel.bones.enumerated() where i < r.worldMatrices.count && fkGroup.contains(b.name) {
                let p = (root * r.worldMatrices[i]).translation
                if let pi = b.parent, fkGroup.contains(skel.bones[pi].name) { lines.append(((root * r.worldMatrices[pi]).translation, p)) }
                let col: Float4 = selectedBone == i ? Float4(1, 0.9, 0.2, 1) : Float4(0.95, 0.95, 1.0, 0.9)
                out.append(GizmoBuilder.handle(at: p, size: px * (selectedBone == i ? 9 : 6), color: col, id: PickIDs.bone(i)))
            }
            out.append(GizmoBuilder.lines(lines, color: Float4(0.3, 0.9, 1, 0.8)))
            if let bi = selectedBone, bi < r.worldMatrices.count {
                let m = root * r.worldMatrices[bi]
                let size = doc.camera.worldUnitsPerPixel(at: m.translation, viewport: viewportSize) * 90
                out += GizmoBuilder.build(mode: .rotate, origin: m.translation, orientation: localSpace ? m.rotationQuaternion : .identity, size: size, highlight: hoverAxis)
            }
        } else if poseMode == .ik {
            for (ci, chain) in IKChain.allCases.enumerated() {
                let t = o.ikTargets[chain] ?? IKTarget()
                let pos: Float3
                if t.enabled { pos = root.transformPoint(t.position) }
                else if let jp = inst.jointPosition(chain.rawValue, pose: r.pose) { pos = root.transformPoint(jp) } else { continue }
                let col: Float4 = t.enabled ? (selectedIK == chain ? Float4(1, 0.9, 0.2, 1) : Float4(0.3, 1, 0.5, 1)) : Float4(0.7, 0.7, 0.75, 0.8)
                out.append(GizmoBuilder.handle(at: pos, size: px * 9, color: col, id: PickIDs.ik(ci)))
            }
            if let chain = selectedIK, let t = o.ikTargets[chain], t.enabled {
                let origin = root.transformPoint(t.position)
                let size = doc.camera.worldUnitsPerPixel(at: origin, viewport: viewportSize) * 90
                out += GizmoBuilder.build(mode: .translate, origin: origin, orientation: .identity, size: size, highlight: hoverAxis)
            }
        }
        return out
    }

    // MARK: Picking & input

    private func pick(_ p: SIMD2<Float>) -> UInt32 {
        host.renderer.pick(frame: frame, pixel: p, size: (Int(viewportSize.x), Int(viewportSize.y)))
    }

    private func ray(_ p: SIMD2<Float>) -> Ray { doc.camera.ray(atPixel: p, viewport: viewportSize) }

    func mouseDown(at p: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags) {
        if button != 0 || modifiers.contains(.option) { drag = modifiers.contains(.shift) || button == 2 ? .pan : .orbit; return }
        let id = pick(p)
        let r = ray(p)
        let camF = doc.camera.forward
        if let axis = PickIDs.axis(from: id) {
            if poseMode == .fk, let sel = selectedObject, sel.kind == .character, let bi = selectedBone, let inst = instances[sel.id], let skel = inst.skeleton {
                let root = inst.rootMatrix
                let world = inst.currentPose().worldMatrices(skeleton: skel)
                let m = root * world[bi]
                if let gd = GizmoDrag(mode: .rotate, axis: axis, origin: m.translation, orientation: localSpace ? m.rotationQuaternion : .identity, ray: r, cameraForward: camF) {
                    pushUndo(force: true)
                    drag = .bone(gd, boneIndex: bi, startWorldRot: m.rotationQuaternion, startDelta: sel.poseDelta)
                }
            } else if poseMode == .ik, let sel = selectedObject, let chain = selectedIK, let t = sel.ikTargets[chain], let inst = instances[sel.id] {
                let origin = inst.rootMatrix.transformPoint(t.position)
                if let gd = GizmoDrag(mode: .translate, axis: axis, origin: origin, orientation: .identity, ray: r, cameraForward: camF) {
                    pushUndo(force: true)
                    drag = .ik(gd, chain: chain, start: t.position)
                }
            } else if let sel = selectedObject {
                let m = doc.worldMatrix(of: sel.id)
                if let gd = GizmoDrag(mode: gizmoMode, axis: axis, origin: m.translation, orientation: localSpace ? m.rotationQuaternion : .identity, ray: r, cameraForward: camF) {
                    pushUndo(force: true)
                    drag = .gizmo(gd, start: sel.transform)
                }
            }
            return
        }
        if let bi = PickIDs.boneIndex(from: id) { selectedBone = bi; status = "Bone: \(selectedInstance?.skeleton?.bones[bi].name ?? "")"; return }
        if let ci = PickIDs.ikIndex(from: id), ci < IKChain.allCases.count {
            let chain = IKChain.allCases[ci]
            if let sel = selectedObject, sel.ikTargets[chain]?.enabled != true { enableIK(chain, on: true) }
            selectedIK = chain
            return
        }
        let objIndex = Int(id & PickIDs.objectMask)
        if objIndex > 0, objIndex <= doc.objects.count {
            let o = doc.objects[objIndex - 1]
            if !o.locked { selection = o.id; status = "Selected \(o.name)" }
            drag = nil
        } else {
            if !modifiers.contains(.shift) { selection = nil }
            drag = .orbit
        }
    }

    func mouseDragged(to p: SIMD2<Float>, delta: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags) {
        guard let d = drag else { return }
        let r = ray(p)
        switch d {
        case .orbit: doc.camera.orbit(dx: delta.x * 0.005, dy: delta.y * 0.005)
        case .pan: doc.camera.pan(dx: delta.x, dy: delta.y)
        case .gizmo(let gd, let start):
            guard let id = selection, let i = doc.index(of: id) else { return }
            var t = start
            let parentWorld = doc.objects[i].parent.map { doc.worldMatrix(of: $0) } ?? matrix_identity_float4x4
            switch gd.mode {
            case .translate:
                if let tr = gd.translation(for: r) {
                    var v = tr
                    if modifiers.contains(.shift) { v = (v / 0.05).rounded(.toNearestOrAwayFromZero) * 0.05 }
                    let local = parentWorld.inverse.transformDirection(v)
                    t.position = start.position + local
                }
            case .rotate:
                if let q = gd.rotation(for: r) {
                    var qq = q
                    if modifiers.contains(.shift) { let a = (q.angle / (Float.pi / 12)).rounded() * (Float.pi / 12); qq = simd_quatf(angle: a, axis: q.axis) }
                    let parentRot = parentWorld.rotationQuaternion
                    let newWorld = qq * (parentRot * start.quaternion)
                    let local = (parentRot.inverse * newWorld).normalized
                    t.rotation = local.eulerXYZ.radiansToDegrees
                }
            case .scale:
                if let s = gd.scale(for: r, size: doc.camera.worldUnitsPerPixel(at: gd.origin, viewport: viewportSize) * 110) { t.scale = start.scale * s }
            }
            doc.objects[i].transform = t
        case .bone(let gd, let bi, let startWorldRot, let startDelta):
            guard let id = selection, let i = doc.index(of: id), let inst = instances[id], let skel = inst.skeleton, let q = gd.rotation(for: r) else { return }
            var qq = q
            if modifiers.contains(.shift) { let a = (q.angle / (Float.pi / 12)).rounded() * (Float.pi / 12); qq = simd_quatf(angle: a, axis: q.axis) }
            // New world rotation for the bone (in scene space) → character root space → local → delta from rest.
            let rootRot = inst.rootMatrix.rotationQuaternion
            let newWorld = qq * startWorldRot
            let newRootSpace = (rootRot.inverse * newWorld).normalized
            var probe = inst
            _ = probe
            probe = inst
            let basePose = combinedPoseDeltaWithout(doc.objects[i], bone: skel.bones[bi].name).apply(to: skel)
            let parentRot = skel.bones[bi].parent.map { basePose.worldRotation($0, skeleton: skel) } ?? .identity
            let local = (parentRot.inverse * newRootSpace).normalized
            let rest = basePose.rotations[bi]      // includes preset/gesture contributions
            let delta = (rest.inverse * local).normalized
            var pd = startDelta
            pd.rotations[skel.bones[bi].name] = delta.eulerXYZ.radiansToDegrees
            doc.objects[i].poseDelta = pd
        case .ik(let gd, let chain, let start):
            guard let id = selection, let i = doc.index(of: id), let inst = instances[id], let tr = gd.translation(for: r) else { return }
            let local = inst.rootMatrix.inverse.transformDirection(tr)
            doc.objects[i].ikTargets[chain, default: IKTarget(enabled: true)].position = start + local
        }
    }

    /// Pose delta from presets/gestures plus the object's FK deltas except one bone (so the base for that bone is well defined).
    private func combinedPoseDeltaWithout(_ o: StudioObject, bone: String) -> PoseDelta {
        var d = PoseDelta()
        if let pid = o.animationPreset, let p = PosePresets.preset(pid) { d.merge(p.delta) }
        d.merge(PosePresets.handDelta(gesture: o.handGestureL, side: "L"))
        d.merge(PosePresets.handDelta(gesture: o.handGestureR, side: "R"))
        var own = o.poseDelta
        own.rotations[bone] = nil
        d.merge(own)
        return d
    }

    func mouseUp(at p: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags) { drag = nil }

    func mouseMoved(to p: SIMD2<Float>) {
        guard showGizmos, selection != nil else { return }
        let id = pick(p)
        let axis = PickIDs.axis(from: id)
        if axis != hoverAxis { hoverAxis = axis; refresh() }
    }

    func scrolled(delta: SIMD2<Float>, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift) { doc.camera.pan(dx: -delta.x * 4, dy: delta.y * 4) } else { doc.camera.dolly(delta.y * 0.5) }
    }
    func magnified(by amount: Float) { doc.camera.dolly(amount * 10) }

    func keyDown(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers ?? ""
        let mods = event.modifierFlags
        if let n = Int(chars), chars.count == 1, !mods.contains(.command) {
            let slot = n == 0 ? 9 : n - 1
            if mods.contains(.shift) { saveCameraSlot(slot) } else { loadCameraSlot(slot) }
            return true
        }
        switch chars {
        case " ": timelinePlaying.toggle(); return true
        case "k": addKeyframe(); return true
        case "t", "w": gizmoMode = .translate; return true
        case "r", "e": gizmoMode = .rotate; return true
        case "s": if !mods.contains(.command) { gizmoMode = .scale; return true }; return false
        case "f": focusSelection(); return true
        case "g": doc.effects.showGrid.toggle(); return true
        case "h": showGizmos.toggle(); return true
        default:
            if event.keyCode == 51 || event.keyCode == 117 { deleteSelection(); return true }
            return false
        }
    }

    // MARK: Pose helpers

    func enableIK(_ chain: IKChain, on: Bool) {
        guard let id = selection, let i = doc.index(of: id), let inst = instances[id] else { return }
        pushUndo(force: true)
        var t = doc.objects[i].ikTargets[chain] ?? IKTarget()
        if on && !t.enabled {
            let pose = inst.currentPose()
            t.position = inst.jointPosition(chain.rawValue, pose: pose) ?? .zero
        }
        t.enabled = on
        doc.objects[i].ikTargets[chain] = t
        if on { selectedIK = chain } else if selectedIK == chain { selectedIK = nil }
    }

    func resetPose() { updateSelected { $0.poseDelta = PoseDelta(); $0.ikTargets = [:]; $0.animationPreset = nil } }

    func boneRotation(_ name: String) -> Float3 { selectedObject?.poseDelta.rotations[name] ?? .zero }
    func setBoneRotation(_ name: String, _ v: Float3) { updateSelected { if v == .zero { $0.poseDelta.rotations[name] = nil } else { $0.poseDelta.rotations[name] = v } } }

    private func gazeTarget(for o: StudioObject, root: float4x4) -> Float3? {
        guard let e = o.card?.expression else { return nil }
        switch e.gazeMode {
        case 1: return doc.camera.position
        case 2: return doc.camera.position + Float3(0.9, 0.35, 0)
        case 3: return e.gazeTarget
        default: return nil
        }
    }

    /// Kept for compatibility with older call sites; gaze is now applied automatically in refresh().
    func applyGaze() {
        guard let id = selection, let i = doc.index(of: id), let inst = instances[id], let skel = inst.skeleton, var card = doc.objects[i].card else { return }
        let mode = card.expression.gazeMode
        var pd = doc.objects[i].poseDelta
        if mode == 0 { pd.rotations["eye_L"] = nil; pd.rotations["eye_R"] = nil }
        else {
            let target: Float3 = mode == 1 ? doc.camera.position : (mode == 2 ? doc.camera.position + Float3(0.8, 0.3, 0) : card.expression.gazeTarget)
            let root = inst.rootMatrix
            let pose = combinedPoseDelta(doc.objects[i]).apply(to: skel)
            let world = pose.worldMatrices(skeleton: skel)
            for name in ["eye_L", "eye_R"] {
                guard let ei = skel[name] else { continue }
                let m = root * world[ei]
                let toT = normalize(m.inverse.transformPoint(target))
                // eye bone looks along local +Z (mesh faces +Z)
                let q = simd_quatf.rotation(from: Float3(0, 0, 1), to: toT)
                var e = q.eulerXYZ.radiansToDegrees
                e = simd_clamp(e, Float3(repeating: -25), Float3(repeating: 25))
                pd.rotations[name] = e
            }
        }
        card.expression.gazeMode = mode
        doc.objects[i].poseDelta = pd
    }
}
