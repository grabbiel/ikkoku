import SwiftUI
import AppKit
import simd
import CoreMath
import Scene
import Renderer
import Character
import Studio
import Assets
import CryptoKit
import Gameplay

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
    var doc = StudioDocument() { didSet { pruneSourceVoices(); refresh() } }
    var selection: UUID? { didSet { if selection != oldValue { selectedBone = nil; selectedSourceIK = nil; refresh() } } }
    var gizmoMode: GizmoMode = .translate { didSet { refresh() } }
    var localSpace = true { didSet { refresh() } }
    var poseMode: PoseMode = .object { didSet { refresh() } }
    var fkGroup: FKGroup = .body { didSet { refresh() } }
    var selectedBone: Int? { didSet { refresh() } }
    var selectedSourceIK: Int32? { didSet { refresh() } }
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
    @ObservationIgnored private var sourceInstances: [UUID: SourceStudioCharacterPreview] = [:]
    let sourceAudioBus = SourceStudioAudioBus()
    @ObservationIgnored var sourceVoicePlayers: [UUID: SourceStudioVoicePlayer] = [:]
    @ObservationIgnored private var nextInstanceID: UInt64 = 100
    @ObservationIgnored private var drag: DragState?
    @ObservationIgnored private var hoverAxis: GizmoAxis?
    @ObservationIgnored private var lastUndoPush = Date.distantPast
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startTime = CFAbsoluteTimeGetCurrent()
    @ObservationIgnored private var animTime: Double = 0
    private(set) var sourceAnimationTime: Float = 0
    @ObservationIgnored var sourcePluginSession: SourceStudioPluginSession?
    let sourceFocus = SourceApplicationFocusHost()
    @ObservationIgnored var sourceFocusObservers: [NSObjectProtocol] = []
    @ObservationIgnored var sourceLaunchObserver: NSObjectProtocol?
    var sourcePluginsRunning = false
    var sourceAccessoryNamesEnabled = false
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
        case sourceBone(GizmoDrag, boneID: Int, startWorld: simd_quatf, parentWorld: simd_quatf)
        case sourceIK(GizmoDrag, target: Int32, start: SourceStudioIKEdit, characterWorld: float4x4, characterRotation: simd_quatf, startWorldRotation: simd_quatf)
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
        if sourcePluginsRunning, sourcePluginSession != nil {
            do { try stepSourcePlugins(deltaTime: 1 / 30, advanceAnimation: liveAnimation) }
            catch { status = "Plugin execution: \(error)" }
            return
        }
        guard liveAnimation, doc.objects.contains(where: { $0.kind == .character }) else { return }
        animTime = CFAbsoluteTimeGetCurrent() - startTime
        sourceAnimationTime += 1 / 30
        for preview in sourceInstances.values { try? preview.setDynamicsStep(elapsed: sourceAnimationTime, deltaTime: 1 / 30) }
        refresh()
    }

    /// Stable original animation clock for scrubbing and matched-frame captures.
    func setSourceAnimationTime(_ seconds: Float) throws {
        guard seconds.isFinite, (0...86_400).contains(seconds) else { throw RigError.invalid("Studio animation time must be between zero and one day.") }
        sourceAnimationTime = seconds
        for preview in sourceInstances.values { preview.clearDynamicsStep(); preview.resetAnimationPlayback() }
        refresh()
    }

    func advancePluginAnimation(by delta: Float) throws {
        guard delta.isFinite, delta >= 0, sourceAnimationTime + delta <= 86_400 else { throw SourcePluginError.invalid("Studio simulation clock is out of range.") }
        sourceAnimationTime += delta
        for preview in sourceInstances.values { try preview.setDynamicsStep(elapsed: sourceAnimationTime, deltaTime: delta) }
    }
    func capturePluginDynamics() -> [UUID: SourceStudioCharacterPreview.DynamicsCheckpoint] {
        sourceInstances.mapValues { $0.captureDynamicsCheckpoint() }
    }
    func restorePluginDynamics(time: Float, checkpoints: [UUID: SourceStudioCharacterPreview.DynamicsCheckpoint]) throws {
        sourceAnimationTime = time
        sourceInstances = sourceInstances.filter { checkpoints[$0.key] != nil }
        for (id, checkpoint) in checkpoints { try sourceInstances[id]?.restoreDynamicsCheckpoint(checkpoint) }
    }
    func stopBenchmarkTimer() { timer?.invalidate(); timer = nil }

    /// Installed accessory-name adapter consumes the resolved source selections;
    /// source slots, UAR identities and card bytes are never written by labels.
    func sourceAccessoryLabels(for id: UUID) -> [String] {
        guard let preview = sourceInstances[id] else { return [] }
        var names: [Int: String] = [:]
        for slot in 0..<20 {
            let property = "outfit\(preview.coordinate).accessory\(slot).ChaFileAccessory.PartsInfo.id"
            if let selection = preview.selections.first(where: { $0.property.utf8.elementsEqual(property.utf8) }),
               selection.status == "converted", let entry = selection.entry { names[slot] = entry.name }
        }
        let rows = (0..<20).map { SourceStudioAccessoryNamesPlugin.Row(text: String(format: "スロット%02d", $0 + 1)) }
        guard sourceAccessoryNamesEnabled else { return rows.compactMap(\.text) }
        return SourceStudioAccessoryNamesPlugin.update(rows, accessoryNames: names).compactMap(\.text)
    }

    func pluginAttachmentFrame(child: StudioObject, parent: StudioObject) throws -> SourceStudioPluginWorld.AttachmentFrame {
        if sourceInstances[parent.id] == nil, let reference = parent.sourceCharacter {
            sourceInstances[parent.id] = try SourceStudioCharacterPreview(reference: reference, resources: host.renderer.resources)
        }
        guard let point = child.sourceAttachmentPoint, let preview = sourceInstances[parent.id] else {
            throw SourcePluginError.runtime("Source plugin attachment has no converted character parent.")
        }
        return try (preview.attachmentMatrix(pointID: point, fkRotations: parent.sourceFKRotations ?? [:], ikTargets: parent.sourceIKOverrides ?? [:], kinematics: parent.sourceKinematics, animationState: parent.sourceAnimation, animationElapsed: sourceAnimationTime),
            preview.attachmentRotation(pointID: point, fkRotations: parent.sourceFKRotations ?? [:], ikTargets: parent.sourceIKOverrides ?? [:], kinematics: parent.sourceKinematics, animationState: parent.sourceAnimation, animationElapsed: sourceAnimationTime))
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

    func undo() { guard let d = undoStack.popLast() else { return }; redoStack.append(doc); sourceInstances.removeAll(); doc = d; do { try restoreSourcePlugins(); status = "Undo" } catch { status = "Plugin restore: \(error)" } }
    func redo() { guard let d = redoStack.popLast() else { return }; undoStack.append(doc); sourceInstances.removeAll(); doc = d; do { try restoreSourcePlugins(); status = "Redo" } catch { status = "Plugin restore: \(error)" } }

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

    /// Import a converted static prefab, retaining the glTF node transforms and materials.
    func importModel(from url: URL) throws {
        let asset = try library.importStaticAsset(url: url)
        var object = StudioObject(name: url.deletingPathExtension().lastPathComponent, kind: .item)
        object.assetFile = url.standardizedFileURL.path
        add(object)
        let bounds = asset.bounds.transformed(by: doc.worldMatrix(of: object.id))
        doc.camera.target = bounds.center
        doc.camera.distance = max(bounds.radius, 0.1) / sin(doc.camera.fovDegrees.degreesToRadians * 0.5) * 1.15
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

    /// Explicit preview: unsupported original records remain named tree nodes
    /// and are retained in the hash-verified source file, never guessed assets.
    func importSourceScenePreview(sceneURL: URL, rigURL: URL, boneCatalogURL: URL) throws {
        let handle = try FileHandle(forReadingFrom: sceneURL); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 256 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 256 * 1024 * 1024 else { throw RigError.invalid("Source scene exceeds 256 MiB.") }
        let source = try KoikatsuSceneReader.decodeDocument(bytes)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var imported = StudioDocument(), previews: [UUID: SourceStudioCharacterPreview] = [:]
        imported.sourceNativePlugins = doc.sourceNativePlugins
        imported.name = sceneURL.deletingPathExtension().lastPathComponent + " — source preview"
        imported.sourceSceneFile = sceneURL.path; imported.sourceSceneSHA256 = hash
        imported.sourceVoiceCatalogFile = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_VOICE_CATALOG"]
        var diagnostics = ["Source scene preview uses converted card selections, shape settings, static ABMX, expressions and saved FK. Missing assets and unimplemented consumers remain listed below."]
        let makerLibrary = try EngineHost.locateMakerLibrary()
        let attachmentURL = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_ATTACHMENT_CATALOG"].map { URL(fileURLWithPath: $0) }
            ?? boneCatalogURL.deletingLastPathComponent().appendingPathComponent("attachments.json")
        let attachmentPath = FileManager.default.fileExists(atPath: attachmentURL.path) ? attachmentURL.path : nil
        let animationPath = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_ANIMATION_CATALOG"]
        var bounds = AABB.empty, stack = source.snapshot.roots.reversed().map { ($0, Optional<UUID>.none, false, Optional<Int32>.none) }
        while let (record, parent, routeChild, attachmentPoint) = stack.popLast() {
            var object = StudioObject(name: record.name ?? "Source object \(record.sourceKey)", kind: .folder)
            object.parent = parent; object.visible = record.visible; object.sourceObjectKey = record.sourceKey
            object.sourceAttachmentPoint = attachmentPoint
            object.transform.position = UnityCoordinates.position(record.transform.position)
            object.transform.scale = record.transform.scale
            let rotation = UnityCoordinates.eulerDegrees(record.transform.rotationDegrees)
            object.transform.rotation = rotation.eulerXYZ.radiansToDegrees
            object.transform.rotationOverride = rotation.vector
            if record.character != nil, !routeChild {
                let selectedRig = record.character?.sex == 0
                    ? (try EngineHost.locateSourceAvatar(sex: .male) ?? rigURL) : rigURL
                let reference = SourceStudioCharacterReference(sceneFile: sceneURL.path, sceneSHA256: hash,
                    rigFile: selectedRig.path, boneCatalogFile: boneCatalogURL.path, objectKey: record.sourceKey,
                    makerLibraryFile: makerLibrary?.sourceURL.path, attachmentCatalogFile: attachmentPath, animationCatalogFile: animationPath,
                    dynamicsFile: ProcessInfo.processInfo.environment["IKKOKU_STUDIO_DYNAMICS"])
                do {
                    let preview = try SourceStudioCharacterPreview(reference: reference, resources: host.renderer.resources)
                    object.kind = .character; object.name = "Source character \(record.sourceKey)"
                    object.sourceCharacter = reference; previews[object.id] = preview
                    diagnostics += preview.diagnostics.map { "Character \(record.sourceKey): \($0)" }
                } catch { diagnostics.append("Character \(record.sourceKey) retained without rendering: \(error)") }
            } else if record.kind != .folder {
                object.name = "Unrendered source \(record.kind) \(record.sourceKey)"
                diagnostics.append("Object \(record.sourceKey) (\(record.kind)) retained without rendering\(routeChild ? "; route animation is unresolved" : "").")
            }
            object.sourcePreviewName = object.name; object.sourcePreviewKind = object.kind
            imported.objects.append(object)
            stack += record.children.reversed().map { ($0, object.id, routeChild || record.kind == .route, Optional<Int32>.none) }
            if let character = record.character {
                for key in character.accessoryChildren.keys.sorted().reversed() {
                    stack += (character.accessoryChildren[key] ?? []).reversed().map { ($0, object.id, routeChild, Optional(key)) }
                }
            }
        }
        imported.sourcePreviewDiagnostics = diagnostics
        try imported.validateHierarchy()
        for object in imported.objects {
            if let preview = previews[object.id], imported.isVisible(object.id) {
                let f = try preview.frame(camera: imported.camera, mainLight: imported.mainLight, effects: imported.effects,
                    world: try sourceWorldMatrix(of: object.id, document: imported, previews: previews), objectID: 1)
                bounds.expand(f.sceneBounds)
            }
        }
        imported.camera = try source.settings.camera.nativeCamera()
        imported.cameraSlots = try source.settings.cameraSlots.map { try $0.nativeCamera() }
        pushUndo(force: true)
        stopSourceVoices(); sourcePluginSession = nil; sourcePluginsRunning = false; sourceAnimationTime = 0; sourceInstances = previews; instances = [:]; doc = imported; self.sceneURL = nil
        selection = imported.objects.first(where: { $0.sourceCharacter != nil })?.id
        status = "Source preview · \(previews.count) converted characters · \(imported.objects.count - previews.count) retained tree nodes. See source compatibility details."
    }

    func importKoikatsuLayout(sceneURL: URL, catalogURL: URL) throws {
        let snapshot = try KoikatsuSceneReader.decode(Data(contentsOf: sceneURL))
        let catalog = try JSONDecoder().decode(KoikatsuAssetCatalog.self, from: Data(contentsOf: catalogURL))
        let imported = try KoikatsuLayoutImporter.convert(snapshot, catalog: catalog,
                                                        catalogDirectory: catalogURL.deletingLastPathComponent())
        var bounds = AABB.empty
        var loaded: [String: LoadedAsset] = [:]
        for object in imported.objects {
            guard let path = object.assetFile else { continue }
            let asset: LoadedAsset
            if let cached = loaded[path] { asset = cached }
            else { asset = try library.importStaticAsset(url: URL(fileURLWithPath: path)); loaded[path] = asset }
            bounds.expand(asset.bounds.transformed(by: imported.worldMatrix(of: object.id)))
        }
        pushUndo(force: true)
        doc.objects.append(contentsOf: imported.objects)
        if !bounds.isEmpty {
            doc.camera.target = bounds.center
            doc.camera.distance = max(bounds.radius, 0.1) / sin(doc.camera.fovDegrees.degreesToRadians * 0.5) * 1.15
        }
        selection = imported.objects.first?.id
        status = "Imported \(imported.objects.count) object transforms. Source materials, animation and scene settings were not applied."
    }

    func newScene() {
        pushUndo(force: true); sourcePluginSession = nil; sourcePluginsRunning = false; stopSourceVoices()
        sourceAnimationTime = 0; sourceInstances.removeAll(); instances.removeAll()
        var empty = StudioDocument(); empty.sourceNativePlugins = doc.sourceNativePlugins
        doc = empty; selection = nil; sceneURL = nil
    }

    func saveScene(to url: URL) throws {
        var savedDocument = doc
        if let session = sourcePluginSession {
            try session.world.replaceDocument(doc)
            savedDocument = try session.savedDocument()
        }
        for i in savedDocument.objects.indices {
            let object = savedDocument.objects[i]
            if let preview = sourceInstances[object.id], preview.hasSavedAnimation || object.sourceAnimation != nil {
                savedDocument.objects[i].sourceAnimation = try preview.savedAnimationState(animationState: object.sourceAnimation, animationElapsed: sourceAnimationTime)
            }
        }
        var f = frame
        f.effects.showGrid = false
        f.gizmos = []
        let thumb = host.renderer.capture(frame: f, width: 640, height: 360)
        let data = try CardIO.encode(savedDocument, keyword: CardIO.sceneKeyword, thumbnail: thumb)
        try data.write(to: url)
        sceneURL = url
        status = "Saved scene \(url.lastPathComponent)"
    }

    /// Export supported edits into a new original-format scene. Native object
    /// UUIDs never replace the original object, bone or plug-in identities.
    func exportSourceScene(to url: URL) throws {
        guard let path = doc.sourceSceneFile, let expected = doc.sourceSceneSHA256 else { throw RigError.invalid("Import an original Studio scene first.") }
        guard url.resolvingSymlinksInPath().path != URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
              !FileManager.default.fileExists(atPath: url.path) else { throw RigError.invalid("Choose a new filename for the edited original scene.") }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 256 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 256 * 1024 * 1024, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected else {
            throw RigError.invalid("The original scene changed; reimport before exporting edits.")
        }
        let source = try KoikatsuSceneReader.decodeDocument(bytes)
        try SourceSceneExportValidation.validate(doc, against: source.snapshot)
        guard doc.effects == SceneEffects(), doc.mainLight == MainLight(), doc.timeline.keyframes.isEmpty else {
            throw RigError.invalid("Original-scene export does not yet serialize native lighting, effects or timeline edits.")
        }
        var records: [Int32: (KoikatsuObjectRecord, Int32?, Int32?)] = [:]
        func index(_ record: KoikatsuObjectRecord, parent: Int32?, attachment: Int32? = nil) {
            records[record.sourceKey] = (record, parent, attachment)
            for child in record.children { index(child, parent: record.sourceKey) }
            for (point, children) in record.character?.accessoryChildren ?? [:] {
                for child in children { index(child, parent: record.sourceKey, attachment: point) }
            }
        }
        for root in source.snapshot.roots { index(root, parent: nil) }
        guard doc.objects.count == records.count, Set(doc.objects.compactMap(\.sourceObjectKey)).count == records.count else {
            throw RigError.invalid("Original-scene export does not yet support adding, duplicating or deleting objects.")
        }
        var edits = SourceSceneEdits()
        for object in doc.objects {
            guard let key = object.sourceObjectKey, let (original, parent, attachment) = records[key],
                  object.parent.flatMap({ doc.object($0)?.sourceObjectKey }) == parent,
                  object.sourceAttachmentPoint == attachment, object.visible == original.visible else {
                throw RigError.invalid("Original-scene export does not yet support reparenting or visibility edits.")
            }
            let originalRotation = UnityCoordinates.eulerDegrees(original.transform.rotationDegrees)
            let rotationChanged = object.transform.quaternion.vector != originalRotation.vector
                && object.transform.quaternion.vector != -originalRotation.vector
            if object.transform.position != UnityCoordinates.position(original.transform.position)
                || object.transform.scale != original.transform.scale
                || rotationChanged {
                edits.transforms.append(.init(.object(key), transform: .init(
                    position: UnityCoordinates.position(object.transform.position),
                    rotationDegrees: rotationChanged ? UnityCoordinates.sourceEulerDegrees(object.transform.quaternion) : original.transform.rotationDegrees,
                    scale: object.transform.scale)))
            }
            if let rotations = object.sourceFKRotations, !rotations.isEmpty {
                guard let preview = sourceInstances[object.id], let character = original.character else { throw RigError.invalid("Source FK character is not loaded.") }
                var groups = character.activeFK
                for (id, degrees) in rotations {
                    guard let boneID = Int32(exactly: id), let bone = character.bones[boneID],
                          let target = preview.controller.targets.first(where: { $0.bone.id == id }) else { throw RigError.invalid("Export cannot add a previously absent FK record.") }
                    edits.transforms.append(.init(.characterFK(object: key, bone: boneID), transform: .init(
                        position: bone.transform.position, rotationDegrees: degrees, scale: bone.transform.scale)))
                    for (i, group) in SourceStudioPose.Group.fkParts.enumerated() where !group.intersection(target.bone.fkGroup).isEmpty { groups[i] = true }
                }
                edits.kinematics[key] = .init(enableFK: true, enableIK: false, activeFK: groups)
            }
            if let character = original.character {
                try SourceStudioIKEditing.appendEdits(objectKey: key, record: character, overrides: object.sourceIKOverrides ?? [:], state: object.sourceKinematics, to: &edits)
            }
            if let character = original.character, let preview = sourceInstances[object.id] {
                let animation = try preview.savedAnimationState(animationState: object.sourceAnimation, animationElapsed: sourceAnimationTime)
                if animation != SourceStudioAnimationState(record: character) { edits.animations[key] = animation }
            } else if object.sourceAnimation != nil { throw RigError.invalid("Animation edits require a loaded source character.") }
            if let voice = object.sourceVoice {
                guard let character = original.character else { throw RigError.invalid("Voice edits require an original character.") }
                if voice != SourceStudioVoiceState(record: character) { edits.voices[key] = voice }
            }
        }
        if doc.camera != (try source.settings.camera.nativeCamera()) { edits.currentCamera = doc.camera.sourceCameraRecord() }
        guard doc.cameraSlots.count == 10 else { throw RigError.invalid("Original scene export requires ten camera slots.") }
        for (i, camera) in doc.cameraSlots.enumerated() {
            guard i < source.settings.cameraSlots.count, let camera else { throw RigError.invalid("Original scene export cannot remove a camera slot.") }
            if camera != (try source.settings.cameraSlots[i].nativeCamera()) { edits.cameraSlots[i] = camera.sourceCameraRecord() }
        }
        if !edits.transforms.isEmpty || !edits.kinematics.isEmpty || !edits.animations.isEmpty || !edits.voices.isEmpty || edits.currentCamera != nil || !edits.cameraSlots.isEmpty {
            var thumbnailFrame = frame; thumbnailFrame.gizmos = []; thumbnailFrame.effects.showGrid = false
            guard let image = host.renderer.capture(frame: thumbnailFrame, width: 640, height: 360) else { throw RigError.invalid("Could not render the edited Studio thumbnail.") }
            edits.thumbnailData = try ImageIO.pngData(image)
        }
        try source.editedData(edits).write(to: url, options: .atomic)
        status = "Exported edited original scene to \(url.lastPathComponent)"
    }

    /// Deterministic integration input using original object/bone IDs. This
    /// exercises the same document fields and guide callbacks as the viewport.
    func applySourceCaptureEdits(_ data: Data) throws {
        struct Edit: Decodable { let objectKey: Int32; let position: [Float]?; let fkRotations: [String: [Float]]?; let ikTargets: [String: SourceStudioIKEdit]?; let kinematics: SourceStudioKinematicState? }
        let edits = try JSONDecoder().decode([Edit].self, from: data)
        guard edits.count <= 1000, Set(edits.map(\.objectKey)).count == edits.count else { throw RigError.invalid("Duplicate or oversized Studio capture edit set.") }
        var candidate = doc
        for edit in edits {
            guard let i = candidate.objects.firstIndex(where: { $0.sourceObjectKey == edit.objectKey }) else { throw RigError.invalid("Studio capture object is missing.") }
            func vector(_ values: [Float]) throws -> Float3 {
                guard values.count == 3, values.allSatisfy(\.isFinite) else { throw RigError.invalid("Studio capture requires three finite coordinates.") }
                return Float3(values)
            }
            if let position = edit.position { candidate.objects[i].transform.position = UnityCoordinates.position(try vector(position)) }
            if let rotations = edit.fkRotations {
                guard let preview = sourceInstances[candidate.objects[i].id] else { throw RigError.invalid("Studio capture guide has no source character.") }
                var changes = candidate.objects[i].sourceFKRotations ?? [:]
                for (key, values) in rotations {
                    guard let id = Int(key) else { throw RigError.invalid("Studio capture bone key is not an integer.") }
                    changes[id] = try vector(values)
                }
                _ = try preview.editedPose(fkRotations: changes)
                candidate.objects[i].sourceFKRotations = changes
            }
            if let targets = edit.ikTargets {
                guard let preview = sourceInstances[candidate.objects[i].id] else { throw RigError.invalid("Studio capture IK has no source character.") }
                var changes = candidate.objects[i].sourceIKOverrides ?? [:]
                for (key, value) in targets {
                    guard let id = Int32(key) else { throw RigError.invalid("Studio capture IK key is not an integer.") }
                    changes[id] = value
                }
                try SourceStudioIKEditing.validate(changes)
                _ = try preview.editedPose(fkRotations: candidate.objects[i].sourceFKRotations ?? [:], ikTargets: changes, kinematics: edit.kinematics, animationState: candidate.objects[i].sourceAnimation, animationElapsed: sourceAnimationTime)
                candidate.objects[i].sourceIKOverrides = changes
            }
            if let state = edit.kinematics { try state.validate(); candidate.objects[i].sourceKinematics = state }
        }
        doc = candidate
    }

    func sourceBenchmarkMetadata() -> [String: Any] {
        ["sourceSceneSHA256": doc.sourceSceneSHA256 ?? "", "sourceObjectCount": doc.objects.count, "animationElapsedSeconds": sourceAnimationTime,
         "renderedCharacters": sourceInstances.count,
         "characters": doc.objects.compactMap { object -> [String: Any]? in
             guard let preview = sourceInstances[object.id] else { return nil }
             return ["objectKey": object.sourceObjectKey ?? -1, "coordinate": preview.coordinate,
                 "selectedAssets": preview.selections.count,
                 "convertedAssets": preview.selections.filter { $0.status == "converted" }.count,
                 "emptyAssets": preview.selections.filter { $0.status == "empty" }.count,
                 "missingAssets": preview.selections.filter { $0.entry == nil }.map(\.property), "diagnostics": preview.diagnostics]
         }, "diagnostics": doc.sourcePreviewDiagnostics ?? []]
    }

    func loadScene(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let d = try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: data)
        try d.validateHierarchy()
        pushUndo(force: true)
        stopSourceVoices()
        instances.removeAll()
        sourceInstances.removeAll()
        sourceAnimationTime = 0
        selection = nil
        doc = d
        try restoreSourcePlugins()
        sceneURL = url
        status = "Loaded scene \(url.lastPathComponent)"
    }

    func importScene(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let d = try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: data)
        guard d.sourcePluginState == nil, d.sourceNativePlugins?.isEmpty != false else { throw SourcePluginError.invalid("Open a plugin-bound scene separately; merging would change its object or configuration identities.") }
        try d.validateHierarchy()
        pushUndo(force: true)
        var remap: [UUID: UUID] = [:]
        for o in d.objects { remap[o.id] = UUID() }
        for var o in d.objects {
            o.id = remap[o.id]!
            o.parent = o.parent.flatMap { remap[$0] }
            doc.objects.append(o)
        }
        for var key in d.timeline.keyframes {
            guard let id = remap[key.object] else { continue }
            key.id = UUID()
            key.object = id
            doc.timeline.insert(key)
        }
        status = "Imported \(d.objects.count) objects"
    }

    // MARK: Camera

    func resetCamera() { doc.camera = StudioDocument().camera }
    func saveCameraSlot(_ i: Int) { guard i >= 0, i < 10 else { return }; doc.cameraSlots[i] = doc.camera; status = "Camera slot \(i + 1) saved" }
    func loadCameraSlot(_ i: Int) { guard i >= 0, i < 10, let c = doc.cameraSlots[i] else { status = "Camera slot \(i + 1) is empty"; return }; doc.camera = c }
    func focusSelection() {
        guard let id = selection else { return }
        guard let m = try? sourceWorldMatrix(of: id, document: doc, previews: sourceInstances) else {
            status = "Cannot focus an unresolved source attachment."; return
        }
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
        let currentIDs = Set(doc.objects.filter { $0.kind == .character && $0.sourceCharacter != nil }.map(\.id))
        sourceInstances = sourceInstances.filter { currentIDs.contains($0.key) }
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
            let world: float4x4
            do { world = try sourceWorldMatrix(of: o.id, document: animatedDoc, previews: sourceInstances) }
            catch { status = "Source attachment: \(error)"; continue }
            guard doc.isVisible(o.id) else { continue }
            switch o.kind {
            case .character:
                if let reference = o.sourceCharacter {
                    do {
                        let preview: SourceStudioCharacterPreview
                        if let cached = sourceInstances[o.id], cached.reference == reference { preview = cached }
                        else {
                            preview = try SourceStudioCharacterPreview(reference: reference, resources: host.renderer.resources)
                            sourceInstances[o.id] = preview
                        }
                        let rendered = try preview.frame(camera: doc.camera, mainLight: doc.mainLight, effects: doc.effects,
                            world: world, objectID: objectID, fkRotations: o.sourceFKRotations ?? [:], ikTargets: o.sourceIKOverrides ?? [:], kinematics: o.sourceKinematics, animationState: o.sourceAnimation, animationElapsed: sourceAnimationTime)
                        if showGizmos, selection == o.id { gizmos += try sourceCharacterGizmos(o, preview: preview, world: world) }
                        items += rendered.items; skinSets.merge(rendered.skinSets) { _, new in new }
                        bounds.expand(rendered.sceneBounds)
                    } catch { status = "Source character \(o.sourceObjectKey ?? 0): \(error)" }
                    continue
                }
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
                guard let file = o.assetFile ?? o.itemID.flatMap({ library.catalog.item($0)?.file }),
                      let a = library.asset(file) else { continue }
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
            do {
                let m = try sourceWorldMatrix(of: sel.id, document: doc, previews: sourceInstances)
                let origin = m.translation
                let orient = try localSpace ? sourceWorldRotation(of: sel.id) : .identity
                let size = doc.camera.worldUnitsPerPixel(at: origin, viewport: viewportSize) * 110
                gizmos += GizmoBuilder.build(mode: gizmoMode, origin: origin, orientation: orient, size: size, highlight: hoverAxis)
            } catch { status = "Source object guide: \(error)" }
        }
        if bounds.isEmpty { bounds = AABB(min: Float3(-1, 0, -1), max: Float3(1, 2, 1)) }
        var f = RenderFrame(camera: doc.camera, mainLight: doc.mainLight, lights: lights, items: items, gizmos: gizmos, effects: doc.effects, sceneBounds: bounds)
        f.skinSets = skinSets
        frame = f
        host.renderer.submit(f)
    }

    private func sourceWorldMatrix(of id: UUID, document: StudioDocument,
                                   previews: [UUID: SourceStudioCharacterPreview]) throws -> float4x4 {
        guard var object = document.object(id) else { throw RigError.invalid("Missing Studio object.") }
        var world = object.transform.matrix, visited: Set<UUID> = [id]
        while let parentID = object.parent {
            guard visited.insert(parentID).inserted, let parent = document.object(parentID) else { throw RigError.invalid("Invalid Studio parent hierarchy.") }
            if let point = object.sourceAttachmentPoint {
                guard let preview = previews[parentID] else { throw RigError.invalid("Attachment parent has no converted character.") }
                world = try preview.attachmentMatrix(pointID: point, fkRotations: parent.sourceFKRotations ?? [:], ikTargets: parent.sourceIKOverrides ?? [:], kinematics: parent.sourceKinematics, animationState: parent.sourceAnimation, animationElapsed: sourceAnimationTime) * world
            }
            world = parent.transform.matrix * world; object = parent
        }
        return world
    }

    private func sourceWorldRotation(of id: UUID) throws -> simd_quatf {
        guard var object = doc.object(id) else { throw RigError.invalid("Missing Studio guide object.") }
        var rotation = object.transform.quaternion, visited: Set<UUID> = [id]
        while let parentID = object.parent {
            guard visited.insert(parentID).inserted, let parent = doc.object(parentID) else { throw RigError.invalid("Invalid Studio guide hierarchy.") }
            if let point = object.sourceAttachmentPoint {
                guard let preview = sourceInstances[parentID] else { throw RigError.invalid("Missing attachment guide parent.") }
                rotation = try preview.attachmentRotation(pointID: point, fkRotations: parent.sourceFKRotations ?? [:], ikTargets: parent.sourceIKOverrides ?? [:], kinematics: parent.sourceKinematics, animationState: parent.sourceAnimation, animationElapsed: sourceAnimationTime) * rotation
            }
            rotation = parent.transform.quaternion * rotation; object = parent
        }
        return rotation.normalized
    }

    /// Attachment space is part of an object's parent frame for guide edits,
    /// just as it is for rendering. Keep the rotation separate from world scale.
    private func sourceParentFrame(of object: StudioObject) throws -> (matrix: float4x4, rotation: simd_quatf) {
        guard let parentID = object.parent else { return (matrix_identity_float4x4, .identity) }
        var matrix = try sourceWorldMatrix(of: parentID, document: doc, previews: sourceInstances)
        var rotation = try sourceWorldRotation(of: parentID)
        if let point = object.sourceAttachmentPoint {
            guard let parent = doc.object(parentID), let preview = sourceInstances[parentID] else {
                throw RigError.invalid("Missing source attachment parent for guide edit.")
            }
            matrix = try matrix * preview.attachmentMatrix(pointID: point, fkRotations: parent.sourceFKRotations ?? [:], ikTargets: parent.sourceIKOverrides ?? [:], kinematics: parent.sourceKinematics, animationState: parent.sourceAnimation, animationElapsed: sourceAnimationTime)
            rotation = try rotation * preview.attachmentRotation(pointID: point, fkRotations: parent.sourceFKRotations ?? [:], ikTargets: parent.sourceIKOverrides ?? [:], kinematics: parent.sourceKinematics, animationState: parent.sourceAnimation, animationElapsed: sourceAnimationTime)
        }
        guard matrix.determinant.isFinite, abs(matrix.determinant) > 1e-8 else {
            throw RigError.invalid("Cannot edit through a singular parent transform.")
        }
        return (matrix, rotation.normalized)
    }

    private func sourceCharacterGizmos(_ object: StudioObject, preview: SourceStudioCharacterPreview, world: float4x4) throws -> [GizmoBatch] {
        if poseMode == .ik { return try sourceIKGizmos(object, preview: preview, world: world) }
        guard poseMode == .fk else { return [] }
        let rig = preview.preview.source.rig
        let pose = try preview.editedPose(fkRotations: object.sourceFKRotations ?? [:], ikTargets: object.sourceIKOverrides ?? [:], kinematics: object.sourceKinematics, animationState: object.sourceAnimation, animationElapsed: sourceAnimationTime)
        let evaluated = try rig.evaluate(pose)
        var result: [GizmoBatch] = []
        for target in preview.controller.targets where target.hasGuide {
            let matrix = world * evaluated.worldMatrices[target.node]
            let size = doc.camera.worldUnitsPerPixel(at: matrix.translation, viewport: viewportSize)
            result.append(GizmoBuilder.handle(at: matrix.translation, size: size * (selectedBone == target.node ? 9 : 6),
                color: selectedBone == target.node ? Float4(1, 0.9, 0.2, 1) : Float4(0.3, 0.9, 1, 0.85), id: PickIDs.bone(target.node)))
            if selectedBone == target.node {
                result += try GizmoBuilder.build(mode: .rotate, origin: matrix.translation,
                    orientation: localSpace ? sourceWorldRotation(of: object.id) * SourceStudioGuide.rotation(node: target.node, rig: rig, pose: pose) : .identity, size: size * 90, highlight: hoverAxis)
            }
        }
        return result
    }

    private func sourceGuides(_ object: StudioObject, preview: SourceStudioCharacterPreview) throws -> [SourceStudioIK.Guide] {
        try preview.editedIKGuides(fkRotations: object.sourceFKRotations ?? [:], ikTargets: object.sourceIKOverrides ?? [:], kinematics: object.sourceKinematics, animationState: object.sourceAnimation, animationElapsed: sourceAnimationTime)
    }
    private func sourceIKCharacterFrame(_ object: StudioObject, preview: SourceStudioCharacterPreview) throws -> (matrix: float4x4, rotation: simd_quatf) {
        let pose = try preview.editedPose(fkRotations: object.sourceFKRotations ?? [:], ikTargets: object.sourceIKOverrides ?? [:], kinematics: object.sourceKinematics, animationState: object.sourceAnimation, animationElapsed: sourceAnimationTime)
        let parent = try preview.ikCharacterFrame(pose: pose)
        return (try sourceWorldMatrix(of: object.id, document: doc, previews: sourceInstances) * parent.matrix,
                try sourceWorldRotation(of: object.id) * parent.rotation)
    }
    private func sourceIKGizmos(_ object: StudioObject, preview: SourceStudioCharacterPreview, world: float4x4) throws -> [GizmoBatch] {
        var result: [GizmoBatch] = []
        for guide in try sourceGuides(object, preview: preview) {
            let origin = world.transformPoint(guide.position), size = doc.camera.worldUnitsPerPixel(at: world.transformPoint(guide.position), viewport: viewportSize)
            let selected = selectedSourceIK == guide.targetID
            let color = selected ? Float4(1,0.9,0.2,1) : guide.active ? Float4(0.3,1,0.5,1) : Float4(0.7,0.7,0.75,0.85)
            result.append(GizmoBuilder.handle(at: origin, size: size * (selected ? 10 : 7), color: color, id: SourceStudioIKEditing.pickID(guide.targetID)))
            if selected {
                let mode: GizmoMode = gizmoMode == .rotate && guide.rotationEnabled ? .rotate : .translate
                result += try GizmoBuilder.build(mode: mode, origin: origin, orientation: localSpace ? sourceWorldRotation(of: object.id) * guide.rotation : .identity, size: size * 90, highlight: hoverAxis)
            }
        }
        return result
    }
    var selectedSourceIKState: SourceStudioKinematicState? {
        guard let object = selectedObject, let preview = sourceInstances[object.id] else { return nil }
        return object.sourceKinematics ?? SourceStudioKinematicState(record: preview.record)
    }
    var sourceIKAvailable: Bool { selection.flatMap { sourceInstances[$0] }?.ikGuides.isEmpty == false }
    func setSourceFKEnabled(_ enabled: Bool) {
        guard let id = selection, let i = doc.index(of: id), var state = selectedSourceIKState else { return }
        pushUndo(force: true); state.enableFK = enabled; if enabled { state.enableIK = false }
        doc.objects[i].sourceKinematics = state
    }
    func setSourceIKEnabled(_ enabled: Bool) {
        guard let id = selection, let i = doc.index(of: id), var state = selectedSourceIKState else { return }
        pushUndo(force: true); state.enableIK = enabled; if enabled { state.enableFK = false }
        doc.objects[i].sourceKinematics = state
    }
    func setSourceIKGroup(_ group: Int, enabled: Bool) {
        guard let id = selection, let i = doc.index(of: id), var state = selectedSourceIKState, state.activeIK.indices.contains(group) else { return }
        pushUndo(force: true); state.activeIK[group] = enabled
        if enabled { state.enableIK = true; state.enableFK = false }
        doc.objects[i].sourceKinematics = state
    }
    private func sourceIKValue(_ object: StudioObject, target: Int32, preview: SourceStudioCharacterPreview) throws -> SourceStudioIKEdit {
        if let value = object.sourceIKOverrides?[target] { return value }
        if let value = preview.record.ikTargets[target]?.transform { return .init(value) }
        guard let guide = try sourceGuides(object, preview: preview).first(where: { $0.targetID == target }) else { throw RigError.invalid("Source IK target is unavailable.") }
        let pose = try preview.editedPose(fkRotations: object.sourceFKRotations ?? [:], ikTargets: object.sourceIKOverrides ?? [:], kinematics: object.sourceKinematics, animationState: object.sourceAnimation, animationElapsed: sourceAnimationTime)
        let character = try preview.ikCharacterFrame(pose: pose)
        return try SourceStudioIKEditing.fromWorld(target: target, position: guide.position, rotation: guide.rotationEnabled ? guide.rotation : nil, characterWorld: character.matrix, characterRotation: character.rotation, preserving: .init(position: .zero))
    }
    var selectedSourceIKValue: SourceStudioIKEdit? {
        guard let object = selectedObject, let preview = sourceInstances[object.id], let target = selectedSourceIK else { return nil }
        return try? sourceIKValue(object, target: target, preview: preview)
    }
    func setSourceIKValue(_ target: Int32, edit: SourceStudioIKEdit, pushHistory: Bool = true) {
        guard let id = selection, let i = doc.index(of: id), var state = selectedSourceIKState else { return }
        do {
            try SourceStudioIKEditing.validate([target: edit])
            let group = try SourceStudioIKEditing.groupIndex(target: target)
            if pushHistory { pushUndo(force: true) }
            state.enableIK = true; state.enableFK = false; state.activeIK[group] = true
            var changes = doc.objects[i].sourceIKOverrides ?? [:]; changes[target] = edit
            doc.objects[i].sourceIKOverrides = changes; doc.objects[i].sourceKinematics = state
        } catch { status = "Source IK guide: \(error)" }
    }
    func resetSourcePoseEdits() {
        updateSelected { $0.sourceFKRotations = nil; $0.sourceIKOverrides = nil; $0.sourceKinematics = nil }
        selectedSourceIK = nil; selectedBone = nil
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
            if poseMode == .fk, let sel = selectedObject, let preview = sourceInstances[sel.id], let bi = selectedBone,
               let target = preview.controller.targets.first(where: { $0.node == bi && $0.hasGuide }) {
                do {
                    let rig = preview.preview.source.rig
                    let pose = try preview.editedPose(fkRotations: sel.sourceFKRotations ?? [:], ikTargets: sel.sourceIKOverrides ?? [:], kinematics: sel.sourceKinematics, animationState: sel.sourceAnimation, animationElapsed: sourceAnimationTime)
                    let evaluated = try rig.evaluate(pose)
                    let root = try sourceWorldMatrix(of: sel.id, document: doc, previews: sourceInstances)
                    let matrix = root * evaluated.worldMatrices[bi]
                    let rootRotation = try sourceWorldRotation(of: sel.id)
                    let worldRotation = try rootRotation * SourceStudioGuide.rotation(node: bi, rig: rig, pose: pose)
                    let parentRotation = try rig.nodes[bi].parent.map { try rootRotation * SourceStudioGuide.rotation(node: $0, rig: rig, pose: pose) } ?? rootRotation
                    if let gd = GizmoDrag(mode: .rotate, axis: axis, origin: matrix.translation,
                        orientation: localSpace ? worldRotation : .identity, ray: r, cameraForward: camF) {
                        pushUndo(force: true)
                        drag = .sourceBone(gd, boneID: target.bone.id, startWorld: worldRotation, parentWorld: parentRotation)
                    }
                } catch { status = "Source guide: \(error)" }
            } else if poseMode == .fk, let sel = selectedObject, sel.kind == .character, let bi = selectedBone, let inst = instances[sel.id], let skel = inst.skeleton {
                let root = inst.rootMatrix
                let world = inst.currentPose().worldMatrices(skeleton: skel)
                let m = root * world[bi]
                if let gd = GizmoDrag(mode: .rotate, axis: axis, origin: m.translation, orientation: localSpace ? m.rotationQuaternion : .identity, ray: r, cameraForward: camF) {
                    pushUndo(force: true)
                    drag = .bone(gd, boneIndex: bi, startWorldRot: m.rotationQuaternion, startDelta: sel.poseDelta)
                }
            } else if poseMode == .ik, let sel = selectedObject, let preview = sourceInstances[sel.id], let target = selectedSourceIK {
                do {
                    let guides = try sourceGuides(sel, preview: preview)
                    guard let guide = guides.first(where: { $0.targetID == target }) else { return }
                    let character = try sourceIKCharacterFrame(sel, preview: preview)
                    let objectWorld = try sourceWorldMatrix(of: sel.id, document: doc, previews: sourceInstances)
                    let origin = objectWorld.transformPoint(guide.position)
                    let worldRotation = try sourceWorldRotation(of: sel.id) * guide.rotation
                    let mode: GizmoMode = gizmoMode == .rotate && guide.rotationEnabled ? .rotate : .translate
                    let start = try sourceIKValue(sel, target: target, preview: preview)
                    if let gd = GizmoDrag(mode: mode, axis: axis, origin: origin, orientation: localSpace ? worldRotation : .identity, ray: r, cameraForward: camF) {
                        pushUndo(force: true)
                        drag = .sourceIK(gd, target: target, start: start, characterWorld: character.matrix, characterRotation: character.rotation, startWorldRotation: worldRotation)
                    }
                } catch { status = "Source IK guide: \(error)" }
            } else if poseMode == .ik, let sel = selectedObject, let chain = selectedIK, let t = sel.ikTargets[chain], let inst = instances[sel.id] {
                let origin = inst.rootMatrix.transformPoint(t.position)
                if let gd = GizmoDrag(mode: .translate, axis: axis, origin: origin, orientation: .identity, ray: r, cameraForward: camF) {
                    pushUndo(force: true)
                    drag = .ik(gd, chain: chain, start: t.position)
                }
            } else if let sel = selectedObject {
                do {
                    let m = try sourceWorldMatrix(of: sel.id, document: doc, previews: sourceInstances)
                    let rotation = try localSpace ? sourceWorldRotation(of: sel.id) : .identity
                    if let gd = GizmoDrag(mode: gizmoMode, axis: axis, origin: m.translation, orientation: rotation, ray: r, cameraForward: camF) {
                        pushUndo(force: true)
                        drag = .gizmo(gd, start: sel.transform)
                    }
                } catch { status = "Source object guide: \(error)" }
            }
            return
        }
        if let bi = PickIDs.boneIndex(from: id) {
            selectedBone = bi
            let sourceName = selection.flatMap { sourceInstances[$0] }?.controller.targets.first { $0.node == bi }?.bone.name
            status = "Bone: \(sourceName ?? selectedInstance?.skeleton?.bones[bi].name ?? "")"; return
        }
        if let target = SourceStudioIKEditing.targetID(fromPick: id), let object = selectedObject, sourceInstances[object.id] != nil {
            selectedSourceIK = target; if let group = try? SourceStudioIKEditing.groupIndex(target: target) { setSourceIKGroup(group, enabled: true) }
            status = SourceStudioIKEditing.labels[Int(target)]; return
        }
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
        case .sourceIK(let gd, let target, let start, let characterWorld, let characterRotation, let startWorldRotation):
            do {
                let position = gd.mode == .translate ? gd.origin + (gd.translation(for: r) ?? .zero) : gd.origin
                let rotation = gd.mode == .rotate ? gd.rotation(for: r).map { $0 * startWorldRotation } : nil
                let edit = try SourceStudioIKEditing.fromWorld(target: target, position: position, rotation: rotation, characterWorld: characterWorld, characterRotation: characterRotation, preserving: start)
                setSourceIKValue(target, edit: edit, pushHistory: false)
            } catch { status = "Source IK guide: \(error)" }
        case .sourceBone(let gd, let boneID, let startWorld, let parentWorld):
            guard let id = selection, let i = doc.index(of: id), let rotation = gd.rotation(for: r) else { return }
            let local = (parentWorld.inverse * rotation * startWorld).normalized
            var edits = doc.objects[i].sourceFKRotations ?? [:]
            edits[boneID] = UnityCoordinates.sourceEulerDegrees(local)
            doc.objects[i].sourceFKRotations = edits
            if let preview = sourceInstances[id] {
                var state = doc.objects[i].sourceKinematics ?? SourceStudioKinematicState(record: preview.record)
                state.enableFK = true; state.enableIK = false
                if let target = preview.controller.targets.first(where: { $0.bone.id == boneID }) {
                    for (j, group) in SourceStudioPose.Group.fkParts.enumerated() where !group.intersection(target.bone.fkGroup).isEmpty { state.activeFK[j] = true }
                }
                doc.objects[i].sourceKinematics = state
            }
        case .orbit: doc.camera.orbit(dx: delta.x * 0.005, dy: delta.y * 0.005)
        case .pan: doc.camera.pan(dx: delta.x, dy: delta.y)
        case .gizmo(let gd, let start):
            guard let id = selection, let i = doc.index(of: id) else { return }
            var t = start
            let parentFrame: (matrix: float4x4, rotation: simd_quatf)
            do { parentFrame = try sourceParentFrame(of: doc.objects[i]) }
            catch { status = "Source object guide: \(error)"; return }
            switch gd.mode {
            case .translate:
                if let tr = gd.translation(for: r) {
                    var v = tr
                    if modifiers.contains(.shift) { v = (v / 0.05).rounded(.toNearestOrAwayFromZero) * 0.05 }
                    let local = parentFrame.matrix.inverse.transformDirection(v)
                    t.position = start.position + local
                }
            case .rotate:
                if let q = gd.rotation(for: r) {
                    var qq = q
                    if modifiers.contains(.shift) { let a = (q.angle / (Float.pi / 12)).rounded() * (Float.pi / 12); qq = simd_quatf(angle: a, axis: q.axis) }
                    let parentRot = parentFrame.rotation
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
