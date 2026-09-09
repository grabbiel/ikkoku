import SwiftUI
import AppKit
import simd
import Scene
import Renderer
import Character
import Studio

struct StudioView: View {
    @Bindable var model: StudioModel
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            workspace.frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    ViewportView(renderer: model.host.renderer, handler: model)
                    toolbar
                }
                if model.showTimeline { Divider(); timelineBar }
            }
            Divider()
            inspector.frame(width: 350)
        }
    }

    // MARK: Workspace

    private var workspace: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workspace").font(.headline)
                Spacer()
                addMenu
            }.padding(8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.doc.flattened(), id: \.object.id) { entry in
                        WorkspaceRow(object: entry.object, depth: entry.depth, selected: model.selection == entry.object.id) {
                            model.selection = entry.object.id
                        } toggleVisible: {
                            model.update(entry.object.id) { $0.visible.toggle() }
                        }
                    }
                }.padding(4)
            }
            Divider()
            HStack {
                Button { model.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate")
                Button { model.deleteSelection() } label: { Image(systemName: "trash") }.help("Delete")
                Spacer()
                Text("\(model.doc.objects.count) objects").font(.caption).foregroundStyle(.secondary)
            }.padding(6).controlSize(.small)
        }
    }

    private var addMenu: some View {
        Menu {
            Menu("Character") {
                Button("Female") { model.addCharacter(sex: .female) }
                Button("Male") { model.addCharacter(sex: .male) }
                Button("From Maker") { if let c = app.maker?.card { model.addCharacter(c) } }
                Button("From card…") { app.openCard() }
            }
            Menu("Item") {
                let cats = Dictionary(grouping: model.library.catalog.items, by: \.category)
                ForEach(cats.keys.sorted(), id: \.self) { cat in
                    Menu(cat) {
                        ForEach(cats[cat]!) { it in
                            Button { model.addItem(id: it.id) } label: {
                                if let u = Thumbs.url("item", it.id), let img = NSImage(contentsOf: u) { Label { Text(it.name) } icon: { Image(nsImage: img) } }
                                else { Text(it.name) }
                            }
                        }
                    }
                }
                if model.library.catalog.items.isEmpty { Text("No items in catalog") }
            }
            Menu("Light") {
                Button("Directional") { model.addLight(.directional) }
                Button("Point") { model.addLight(.point) }
                Button("Spot") { model.addLight(.spot) }
            }
            Button("Camera") { model.addCamera() }
            Button("Folder") { model.addFolder() }
        } label: { Label("Add", systemImage: "plus") }
        .controlSize(.small).fixedSize()
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $model.gizmoMode) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").tag(GizmoMode.translate)
                Image(systemName: "arrow.triangle.2.circlepath").tag(GizmoMode.rotate)
                Image(systemName: "arrow.up.left.and.arrow.down.right").tag(GizmoMode.scale)
            }.pickerStyle(.segmented).frame(width: 120).help("Gizmo: T / R / S")
            Toggle(isOn: $model.localSpace) { Text(model.localSpace ? "Local" : "World").frame(width: 42) }.toggleStyle(.button)
            if model.selectedObject?.kind == .character {
                Divider().frame(height: 18)
                Picker("", selection: $model.poseMode) { ForEach(PoseMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 150)
                if model.poseMode == .fk {
                    Picker("", selection: $model.fkGroup) { ForEach(FKGroup.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 120)
                }
            }
            Divider().frame(height: 18)
            ForEach(0..<5, id: \.self) { i in
                Button { model.loadCameraSlot(i) } label: { Text("\(i + 1)").frame(width: 14) }
                    .foregroundStyle(model.doc.cameraSlots[i] == nil ? .secondary : .primary)
                    .help("Camera slot \(i + 1) (Shift+\(i + 1) saves)")
            }
            Menu {
                ForEach(0..<10, id: \.self) { i in Button("Save slot \(i + 1)") { model.saveCameraSlot(i) } }
                Divider()
                ForEach(0..<10, id: \.self) { i in Button("Load slot \(i + 1)") { model.loadCameraSlot(i) }.disabled(model.doc.cameraSlots[i] == nil) }
                Divider()
                Button("Focus selection (F)") { model.focusSelection() }
                Button("Reset camera") { model.resetCamera() }
            } label: { Image(systemName: "camera") }.fixedSize()
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.undoStack.isEmpty)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(model.redoStack.isEmpty)
            Toggle(isOn: $model.showGizmos) { Image(systemName: "scope") }.toggleStyle(.button).help("Show gizmos (H)")
            Toggle(isOn: $model.liveAnimation) { Image(systemName: "wind") }.toggleStyle(.button).help("Idle animation (blink, breathing)")
            Toggle(isOn: $model.showTimeline) { Image(systemName: "timeline.selection") }.toggleStyle(.button).help("Timeline")
            Toggle(isOn: $model.doc.effects.showGrid) { Image(systemName: "grid") }.toggleStyle(.button).help("Grid (G)")
            Button { app.captureScreenshot() } label: { Label("Capture", systemImage: "camera.viewfinder") }
        }
        .controlSize(.small)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }

    // MARK: Timeline

    private var timelineBar: some View {
        HStack(spacing: 10) {
            Button { model.timelinePlaying.toggle() } label: { Image(systemName: model.timelinePlaying ? "pause.fill" : "play.fill") }
                .help("Play / pause (Space in the viewport)")
            Button { model.timelinePlaying = false; model.timelineTime = 0 } label: { Image(systemName: "backward.end.fill") }
            Text(String(format: "%.2f s", model.timelineTime)).font(.caption.monospacedDigit()).frame(width: 52)
            ZStack(alignment: .leading) {
                Slider(value: $model.timelineTime, in: 0...max(model.doc.timeline.duration, 0.1))
                GeometryReader { geo in
                    ForEach(model.selectedKeyframes) { k in
                        let x = CGFloat(k.time / max(model.doc.timeline.duration, 0.1)) * geo.size.width
                        Rectangle().fill(Color.accentColor).frame(width: 3, height: 10).position(x: x, y: geo.size.height - 3)
                    }
                }.allowsHitTesting(false)
            }
            Text("Length").font(.caption)
            TextField("", value: $model.doc.timeline.duration, format: .number.precision(.fractionLength(1))).textFieldStyle(.roundedBorder).frame(width: 48).font(.caption)
            Toggle("Loop", isOn: $model.doc.timeline.loop).font(.caption)
            Divider().frame(height: 16)
            Button { model.addKeyframe() } label: { Label("Key", systemImage: "diamond.fill").labelStyle(.titleAndIcon).fixedSize() }.help("Add keyframe for the selected object at the current time (K in the viewport)")
                .disabled(model.selectedObject == nil)
            Menu {
                ForEach(model.selectedKeyframes) { k in Button("Delete key at \(String(format: "%.2f", k.time)) s") { model.deleteKeyframe(k.id) } }
                Divider()
                Button("Clear timeline") { model.clearTimeline() }
            } label: { Image(systemName: "diamond") }.fixedSize()
            Text("\(model.doc.timeline.keyframes.count) keys").font(.caption).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.inspectorTab) {
                ForEach(StudioModel.InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(8)
            ScrollView {
                Group {
                    switch model.inspectorTab {
                    case .object: ObjectInspector(model: model)
                    case .pose: PoseInspector(model: model)
                    case .face: FaceInspector(model: model)
                    case .clothes: ClothesInspector(model: model)
                    case .scene: SceneInspector(model: model)
                    }
                }.padding(12)
            }
            Divider()
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(6)
        }
    }
}

struct WorkspaceRow: View {
    let object: StudioObject
    let depth: Int
    let selected: Bool
    let select: () -> Void
    let toggleVisible: () -> Void
    var icon: String {
        switch object.kind {
        case .character: return "person.fill"; case .item: return "cube.fill"; case .light: return "lightbulb.fill"
        case .camera: return "camera.fill"; case .folder: return "folder.fill"
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: CGFloat(depth) * 14)
            Image(systemName: icon).foregroundStyle(object.kind == .light ? .yellow : .secondary).frame(width: 16)
            Text(object.name).lineLimit(1).font(.callout)
            Spacer()
            Button(action: toggleVisible) { Image(systemName: object.visible ? "eye" : "eye.slash").foregroundStyle(.secondary) }.buttonStyle(.plain)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.3) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

// MARK: - Inspector panels

struct ObjectInspector: View {
    @Bindable var model: StudioModel
    @Environment(AppState.self) private var app
    var body: some View {
        if let o = model.selectedObject, let i = model.doc.index(of: o.id) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: Binding(get: { o.name }, set: { v in model.update(o.id) { $0.name = v } }))
                HStack {
                    Toggle("Visible", isOn: Binding(get: { o.visible }, set: { v in model.update(o.id) { $0.visible = v } }))
                    Toggle("Locked", isOn: Binding(get: { o.locked }, set: { v in model.update(o.id) { $0.locked = v } }))
                }
                Picker("Parent", selection: Binding(get: { o.parent }, set: { model.setParent(o.id, to: $0) })) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.doc.objects.filter { $0.id != o.id && !model.doc.isDescendant($0.id, of: o.id) }) { p in Text(p.name).tag(UUID?.some(p.id)) }
                }
                SectionBox(title: "Transform") {
                    VectorRow(label: "Position", value: Binding(get: { model.doc.objects[i].transform.position }, set: { v in model.update(o.id) { $0.transform.position = v } }), step: 0.05, format: "%.3f")
                    VectorRow(label: "Rotation", value: Binding(get: { model.doc.objects[i].transform.rotation }, set: { v in model.update(o.id) { $0.transform.rotation = v } }), step: 5, format: "%.0f")
                    VectorRow(label: "Scale", value: Binding(get: { model.doc.objects[i].transform.scale }, set: { v in model.update(o.id) { $0.transform.scale = v } }), step: 0.1, format: "%.2f")
                    Button("Reset transform") { model.update(o.id) { $0.transform = StudioTransform() } }
                }
                switch o.kind {
                case .character:
                    SectionBox(title: "Character") {
                        Text(o.card?.profile.name ?? "").font(.callout)
                        HStack {
                            Button("Edit in Maker") { if let c = o.card { app.maker?.load(card: c); app.mode = .maker } }
                            Button("Replace from Maker") { if let c = app.maker?.card { model.update(o.id) { $0.card = c; $0.name = c.profile.name } } }
                        }
                        Toggle("Show clothing", isOn: Binding(get: { o.clothingVisible }, set: { v in model.update(o.id) { $0.clothingVisible = v } }))
                        Toggle("Show accessories", isOn: Binding(get: { o.accessoriesVisible }, set: { v in model.update(o.id) { $0.accessoriesVisible = v } }))
                    }
                case .item:
                    SectionBox(title: "Item") {
                        ColorRow(label: "Tint", color: Binding(get: { o.tint ?? .white }, set: { v in model.update(o.id) { $0.tint = v } }))
                        FloatRow(label: "Emissive", value: Binding(get: { o.emissive }, set: { v in model.update(o.id) { $0.emissive = v } }), range: 0...2)
                        Button("Clear tint") { model.update(o.id) { $0.tint = nil } }
                    }
                case .light:
                    if let l = o.light {
                        SectionBox(title: "Light") {
                            Toggle("Enabled", isOn: Binding(get: { l.enabled }, set: { v in model.update(o.id) { $0.light?.enabled = v } }))
                            ColorRow(label: "Colour", color: Binding(get: { RGB(l.color.x, l.color.y, l.color.z) }, set: { v in model.update(o.id) { $0.light?.color = v.float3 } }))
                            FloatRow(label: "Intensity", value: Binding(get: { l.intensity }, set: { v in model.update(o.id) { $0.light?.intensity = v } }), range: 0...4)
                            if l.kind != .directional { FloatRow(label: "Range", value: Binding(get: { l.range }, set: { v in model.update(o.id) { $0.light?.range = v } }), range: 0.1...20) }
                            if l.kind == .spot {
                                FloatRow(label: "Spot angle", value: Binding(get: { l.spotAngle }, set: { v in model.update(o.id) { $0.light?.spotAngle = v } }), range: 5...120)
                                FloatRow(label: "Spot blend", value: Binding(get: { l.spotBlend }, set: { v in model.update(o.id) { $0.light?.spotBlend = v } }))
                            }
                            Text("Position and direction come from the transform above.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .camera:
                    SectionBox(title: "Camera") {
                        HStack {
                            Button("Look through") { model.lookThrough(o.id) }
                            Button("Update from view") { model.updateCameraObject(o.id) }
                        }
                    }
                case .folder: EmptyView()
                }
            }
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "cursorarrow.click", description: Text("Click an object in the viewport or the workspace."))
        }
    }
}

struct PoseInspector: View {
    @Bindable var model: StudioModel
    var body: some View {
        if let o = model.selectedObject, o.kind == .character {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Mode", selection: $model.poseMode) { ForEach(PoseMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                SectionBox(title: "Pose presets") {
                    let cats = Dictionary(grouping: PosePresets.all, by: \.category)
                    ForEach(cats.keys.sorted(), id: \.self) { cat in
                        Text(cat).font(.caption).foregroundStyle(.secondary)
                        ItemGrid(entries: cats[cat]!.map { .init(id: $0.id, name: $0.name) }, selected: o.animationPreset, allowNone: false) { id in
                            model.update(o.id) { $0.animationPreset = id }
                        }
                    }
                    Button("Reset pose (clear FK/IK)") { model.resetPose() }
                }
                SectionBox(title: "Hands") {
                    Picker("Left hand", selection: Binding(get: { o.handGestureL }, set: { v in model.update(o.id) { $0.handGestureL = v } })) {
                        ForEach(0..<PosePresets.handGestures.count, id: \.self) { Text(PosePresets.handGestures[$0].name).tag($0) }
                    }
                    Picker("Right hand", selection: Binding(get: { o.handGestureR }, set: { v in model.update(o.id) { $0.handGestureR = v } })) {
                        ForEach(0..<PosePresets.handGestures.count, id: \.self) { Text(PosePresets.handGestures[$0].name).tag($0) }
                    }
                }
                SectionBox(title: "FK") {
                    Picker("Group", selection: $model.fkGroup) { ForEach(FKGroup.allCases) { Text($0.rawValue).tag($0) } }
                    if let skel = model.selectedInstance?.skeleton {
                        let bones = skel.bones.enumerated().filter { model.fkGroup.contains($0.element.name) }
                        Picker("Bone", selection: Binding(get: { model.selectedBone ?? -1 }, set: { model.selectedBone = $0 < 0 ? nil : $0 })) {
                            Text("None").tag(-1)
                            ForEach(bones, id: \.offset) { Text($0.element.name).tag($0.offset) }
                        }
                        if let bi = model.selectedBone, bi < skel.count {
                            let name = skel.bones[bi].name
                            VectorRow(label: "Rotate", value: Binding(get: { model.boneRotation(name) }, set: { model.setBoneRotation(name, $0) }), step: 5, format: "%.0f")
                            Button("Reset bone") { model.setBoneRotation(name, .zero) }
                            Text("Drag the ring gizmo in the viewport to rotate. Shift snaps to 15°.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                SectionBox(title: "IK") {
                    ForEach(IKChain.allCases, id: \.self) { chain in
                        let t = o.ikTargets[chain] ?? IKTarget()
                        HStack {
                            Toggle(chain.label, isOn: Binding(get: { t.enabled }, set: { model.enableIK(chain, on: $0) }))
                            Spacer()
                            if t.enabled { Button("Select") { model.selectedIK = chain; model.poseMode = .ik }.controlSize(.small) }
                        }
                        if t.enabled {
                            VectorRow(label: "Target", value: Binding(get: { t.position }, set: { v in model.update(o.id) { $0.ikTargets[chain]?.position = v } }), step: 0.02, format: "%.3f")
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a character", systemImage: "figure.stand", description: Text("Posing works on characters."))
        }
    }
}

struct FaceInspector: View {
    @Bindable var model: StudioModel
    var body: some View {
        if let o = model.selectedObject, o.kind == .character, let i = model.doc.index(of: o.id), o.card != nil {
            let exp = Binding<ExpressionState>(get: { model.doc.objects[i].card?.expression ?? ExpressionState() }, set: { v in model.update(o.id) { $0.card?.expression = v } })
            VStack(alignment: .leading, spacing: 10) {
                SectionBox(title: "Expression") {
                    Picker("Eyebrows", selection: exp.eyebrows) { ForEach(0..<ExpressionPresets.eyebrowPatterns.count, id: \.self) { Text(ExpressionPresets.eyebrowPatterns[$0].name).tag($0) } }
                    Picker("Eyes", selection: exp.eyes) { ForEach(0..<ExpressionPresets.eyePatterns.count, id: \.self) { Text(ExpressionPresets.eyePatterns[$0].name).tag($0) } }
                    Picker("Mouth", selection: exp.mouth) { ForEach(0..<ExpressionPresets.mouthPatterns.count, id: \.self) { Text(ExpressionPresets.mouthPatterns[$0].name).tag($0) } }
                    FloatRow(label: "Eyes open", value: exp.eyeOpen)
                    FloatRow(label: "Mouth open", value: exp.mouthOpen)
                    FloatRow(label: "Blush", value: exp.blush)
                }
                SectionBox(title: "Gaze") {
                    Picker("Mode", selection: exp.gazeMode) {
                        Text("Front").tag(0); Text("Follow camera").tag(1); Text("Avert").tag(2); Text("Fixed target").tag(3)
                    }
                    if exp.wrappedValue.gazeMode == 3 { VectorRow(label: "Target", value: exp.gazeTarget, step: 0.1, format: "%.2f") }
                    Toggle("Head follows (neck look)", isOn: Binding(get: { exp.wrappedValue.headLook ?? false }, set: { exp.wrappedValue.headLook = $0 }))
                    Toggle("Auto blink", isOn: exp.blink)
                    Text("Follow camera keeps the eyes on the viewer; Fixed target uses the point above (scene space).").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            ContentUnavailableView("Select a character", systemImage: "face.smiling", description: Text("Expressions work on characters."))
        }
    }
}

struct ClothesInspector: View {
    @Bindable var model: StudioModel
    var body: some View {
        if let o = model.selectedObject, o.kind == .character, let i = model.doc.index(of: o.id), let card = o.card {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Outfit", selection: Binding(get: { card.currentOutfit }, set: { v in model.update(o.id) { $0.card?.currentOutfit = v } })) {
                    ForEach(0..<card.outfits.count, id: \.self) { Text(card.outfits[$0].name).tag($0) }
                }
                SectionBox(title: "Clothing state") {
                    ForEach(ClothSlot.allCases, id: \.self) { slot in
                        if card.outfit.items[slot]?.itemID != nil {
                            HStack {
                                Text(slot.label).font(.callout).frame(width: 120, alignment: .leading)
                                Picker("", selection: Binding(get: { model.doc.objects[i].card?.outfit.states[slot] ?? .on }, set: { v in model.update(o.id) { $0.card?.outfit.states[slot] = v } })) {
                                    ForEach(ClothState.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                                }.pickerStyle(.segmented).labelsHidden()
                            }
                        }
                    }
                    HStack {
                        Button("All on") { model.update(o.id) { $0.card?.outfit.states = [:] } }
                        Button("All off") { model.update(o.id) { for s in ClothSlot.allCases { $0.card?.outfit.states[s] = .off } } }
                    }
                }
                SectionBox(title: "Accessories") {
                    ForEach(0..<card.accessories.count, id: \.self) { k in
                        if card.accessories[k].itemID != nil {
                            Toggle(model.library.catalog.accessory(card.accessories[k].itemID!)?.name ?? "Accessory \(k + 1)",
                                   isOn: Binding(get: { model.doc.objects[i].card?.accessories[k].visible ?? true }, set: { v in model.update(o.id) { $0.card?.accessories[k].visible = v } }))
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a character", systemImage: "tshirt", description: Text("Clothing states work on characters."))
        }
    }
}

struct SceneInspector: View {
    @Bindable var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionBox(title: "Character light") {
                FloatRow(label: "Horizontal", value: $model.doc.mainLight.rotation.y, range: -180...180)
                FloatRow(label: "Vertical", value: $model.doc.mainLight.rotation.x, range: -89...89)
                FloatRow(label: "Intensity", value: $model.doc.mainLight.intensity, range: 0...2)
                ColorRow(label: "Colour", color: Binding(get: { RGB(model.doc.mainLight.color.x, model.doc.mainLight.color.y, model.doc.mainLight.color.z) }, set: { model.doc.mainLight.color = $0.float3 }))
                Toggle("Follow camera (Koikatsu style)", isOn: $model.doc.mainLight.cameraRelative)
                Toggle("Cast shadows", isOn: $model.doc.mainLight.castsShadow)
                FloatRow(label: "Shadow strength", value: $model.doc.mainLight.shadowStrength)
                FloatRow(label: "Shadow softness", value: $model.doc.effects.shadowSoftness, range: 0...3)
            }
            SectionBox(title: "Ambient & background") {
                ColorRow(label: "Ambient sky", color: Binding(get: { RGB(model.doc.effects.ambientSky.x, model.doc.effects.ambientSky.y, model.doc.effects.ambientSky.z) }, set: { model.doc.effects.ambientSky = $0.float3 }))
                ColorRow(label: "Ambient ground", color: Binding(get: { RGB(model.doc.effects.ambientGround.x, model.doc.effects.ambientGround.y, model.doc.effects.ambientGround.z) }, set: { model.doc.effects.ambientGround = $0.float3 }))
                ColorRow(label: "Background top", color: Binding(get: { RGB(model.doc.effects.backgroundTop.x, model.doc.effects.backgroundTop.y, model.doc.effects.backgroundTop.z) }, set: { model.doc.effects.backgroundTop = $0.float3 }))
                ColorRow(label: "Background bottom", color: Binding(get: { RGB(model.doc.effects.backgroundBottom.x, model.doc.effects.backgroundBottom.y, model.doc.effects.backgroundBottom.z) }, set: { model.doc.effects.backgroundBottom = $0.float3 }))
                Toggle("Transparent background (captures)", isOn: $model.doc.effects.transparentBackground)
                Toggle("Show grid", isOn: $model.doc.effects.showGrid)
            }
            SectionBox(title: "Screen effects") {
                Toggle("Bloom", isOn: $model.doc.effects.bloomEnabled)
                FloatRow(label: "Bloom intensity", value: $model.doc.effects.bloomIntensity, range: 0...1.5)
                FloatRow(label: "Bloom threshold", value: $model.doc.effects.bloomThreshold, range: 0...2)
                Toggle("Vignette", isOn: $model.doc.effects.vignetteEnabled)
                FloatRow(label: "Vignette amount", value: $model.doc.effects.vignetteIntensity)
                FloatRow(label: "Exposure", value: $model.doc.effects.exposure, range: 0.3...2)
                FloatRow(label: "Contrast", value: $model.doc.effects.contrast, range: 0.5...1.6)
                FloatRow(label: "Saturation", value: $model.doc.effects.saturation, range: 0...2)
                FloatRow(label: "Temperature", value: $model.doc.effects.temperature, range: -1...1)
                FloatRow(label: "Outline width", value: $model.doc.effects.outlineWidth, range: 0...3)
                Toggle("Anti-aliasing (FXAA)", isOn: $model.doc.effects.fxaa)
                Toggle("Fog", isOn: $model.doc.effects.fogEnabled)
                if model.doc.effects.fogEnabled {
                    FloatRow(label: "Fog start", value: $model.doc.effects.fogStart, range: 0...30)
                    FloatRow(label: "Fog end", value: $model.doc.effects.fogEnd, range: 1...80)
                    ColorRow(label: "Fog colour", color: Binding(get: { RGB(model.doc.effects.fogColor.x, model.doc.effects.fogColor.y, model.doc.effects.fogColor.z) }, set: { model.doc.effects.fogColor = $0.float3 }))
                }
            }
            SectionBox(title: "Capture") {
                Picker("Resolution", selection: Binding(get: { "\(model.doc.captureWidth)x\(model.doc.captureHeight)" }, set: { v in
                    let p = v.split(separator: "x").compactMap { Int($0) }
                    if p.count == 2 { model.doc.captureWidth = p[0]; model.doc.captureHeight = p[1] }
                })) {
                    Text("HD 1280×720").tag("1280x720"); Text("FHD 1920×1080").tag("1920x1080"); Text("WQHD 2560×1440").tag("2560x1440")
                    Text("4K 3840×2160").tag("3840x2160"); Text("Portrait 1080×1920").tag("1080x1920"); Text("Square 2048").tag("2048x2048")
                }
                Text("Capture with ⇧⌘P or the Capture button. Transparent background applies to captures.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
