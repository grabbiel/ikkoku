import SwiftUI
import Character
import Scene
import Studio

// R7 phase 2, item 7: the Object tab's sections for each kind of object. Each
// is a view that is Equatable on what it shows. With
// `StudioInspectorMounting.keepsSections`, a section stays mounted once it
// has been shown, hidden with the last state it showed, so a change of kind
// shows it again instead of building it.

extension StudioModel {
    /// Edits `id` while it is the selection. A kept inspector view hidden
    /// with an earlier object's state writes nothing.
    func inspectorUpdate(_ id: UUID, _ change: (inout StudioObject) -> Void) {
        guard selection == id else { return }
        update(id, change)
    }
}

/// The Character section and, for an original character, the Voice section.
struct ObjectCharacterSections: View, Equatable {
    let model: StudioModel
    let id: UUID
    let cardName: String
    let isSourceCharacter: Bool
    let clothingVisible: Bool
    let accessoriesVisible: Bool
    @Environment(AppState.self) private var app

    init(model: StudioModel, state o: ObjectInspectorState) {
        self.model = model
        id = o.id; cardName = o.cardName; isSourceCharacter = o.isSourceCharacter
        clothingVisible = o.clothingVisible; accessoriesVisible = o.accessoriesVisible
    }

    static func == (a: Self, b: Self) -> Bool {
        a.model === b.model && a.id == b.id && a.cardName == b.cardName && a.isSourceCharacter == b.isSourceCharacter
            && a.clothingVisible == b.clothingVisible && a.accessoriesVisible == b.accessoriesVisible
    }

    var body: some View {
        let _ = PerfTrace.body(.objectInspectorSection)
        let id = id
        VStack(alignment: .leading, spacing: 10) {
            SectionBox(title: "Character") {
                Text(cardName).font(.callout)
                if !isSourceCharacter {
                    HStack {
                        Button("Edit in Maker") { if let c = model.doc.object(id)?.card { app.ensureMaker()?.load(card: c); app.mode = .maker } }
                        Button("Replace from Maker") { if let c = app.ensureMaker()?.card { model.inspectorUpdate(id) { $0.card = c; $0.name = c.profile.name } } }
                    }
                    Toggle("Show clothing", isOn: Binding(get: { clothingVisible }, set: { v in model.inspectorUpdate(id) { $0.clothingVisible = v } }))
                    Toggle("Show accessories", isOn: Binding(get: { accessoriesVisible }, set: { v in model.inspectorUpdate(id) { $0.accessoriesVisible = v } }))
                } else {
                    Text("Original character: name, transform and voice are editable here. Maker editing, replacement and the prototype clothing/accessory toggles only affect unused native fields and are not available for this reference avatar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if isSourceCharacter {
                SectionBox(title: "Voice") {
                    HStack {
                        Button("Play playlist") { model.playSourceVoice(id) }
                        Button("Stop") { model.stopSourceVoice(id) }
                        Menu("Repeat") {
                            Button("Play once") { model.setSourceVoiceRepeat(id, mode: 0) }
                            Button("Repeat playlist") { model.setSourceVoiceRepeat(id, mode: 1) }
                            Button("Repeat selected") { model.setSourceVoiceRepeat(id, mode: 2) }
                        }
                    }
                }
            }
        }
    }
}

struct ObjectItemSection: View, Equatable {
    let model: StudioModel
    let id: UUID
    let tint: RGB?
    let emissive: Float

    static func == (a: Self, b: Self) -> Bool { a.model === b.model && a.id == b.id && a.tint == b.tint && a.emissive == b.emissive }

    var body: some View {
        let _ = PerfTrace.body(.objectInspectorSection)
        let id = id
        SectionBox(title: "Item") {
            ColorRow(label: "Tint", color: Binding(get: { tint ?? .white }, set: { v in model.inspectorUpdate(id) { $0.tint = v } }))
            FloatRow(label: "Emissive", value: Binding(get: { emissive }, set: { v in model.inspectorUpdate(id) { $0.emissive = v } }), range: 0...2)
            Button("Clear tint") { model.inspectorUpdate(id) { $0.tint = nil } }
        }
    }
}

struct ObjectLightSection: View, Equatable {
    let model: StudioModel
    let id: UUID
    let light: SceneLight

    static func == (a: Self, b: Self) -> Bool { a.model === b.model && a.id == b.id && a.light == b.light }

    var body: some View {
        let _ = PerfTrace.body(.objectInspectorSection)
        let id = id, l = light
        SectionBox(title: "Light") {
            Toggle("Enabled", isOn: Binding(get: { l.enabled }, set: { v in model.inspectorUpdate(id) { $0.light?.enabled = v } }))
            ColorRow(label: "Colour", color: Binding(get: { RGB(l.color.x, l.color.y, l.color.z) }, set: { v in model.inspectorUpdate(id) { $0.light?.color = v.float3 } }))
            FloatRow(label: "Intensity", value: Binding(get: { l.intensity }, set: { v in model.inspectorUpdate(id) { $0.light?.intensity = v } }), range: 0...4)
            if l.kind != .directional { FloatRow(label: "Range", value: Binding(get: { l.range }, set: { v in model.inspectorUpdate(id) { $0.light?.range = v } }), range: 0.1...20) }
            if l.kind == .spot {
                FloatRow(label: "Spot angle", value: Binding(get: { l.spotAngle }, set: { v in model.inspectorUpdate(id) { $0.light?.spotAngle = v } }), range: 5...120)
                FloatRow(label: "Spot blend", value: Binding(get: { l.spotBlend }, set: { v in model.inspectorUpdate(id) { $0.light?.spotBlend = v } }))
            }
            Text("Position and direction come from the transform above.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ObjectCameraSection: View, Equatable {
    let model: StudioModel
    let id: UUID

    static func == (a: Self, b: Self) -> Bool { a.model === b.model && a.id == b.id }

    var body: some View {
        let _ = PerfTrace.body(.objectInspectorSection)
        let id = id
        SectionBox(title: "Camera") {
            HStack {
                Button("Look through") { model.lookThrough(id) }
                Button("Update from view") { model.updateCameraObject(id) }
            }
        }
    }
}

/// A source camera placeholder's Camera section.
struct ObjectSourceCameraSection: View, Equatable {
    let model: StudioModel
    let id: UUID
    let name: String
    let looking: Bool
    let buttonTitle: String
    let stateText: String

    init(model: StudioModel, state o: ObjectInspectorState, name: String) {
        self.model = model
        id = o.id; self.name = name; looking = o.lookingThroughSourceCamera
        buttonTitle = o.sourceCameraButtonTitle; stateText = o.sourceCameraStateText
    }

    static func == (a: Self, b: Self) -> Bool {
        a.model === b.model && a.id == b.id && a.name == b.name && a.looking == b.looking
            && a.buttonTitle == b.buttonTitle && a.stateText == b.stateText
    }

    var body: some View {
        let _ = PerfTrace.body(.objectInspectorSection)
        let id = id
        SectionBox(title: "Camera") {
            Text("Source camera: \(name)").font(.callout)
            HStack {
                Button(buttonTitle) { model.toggleSourceCamera(id) }
                    .help(looking ? "Deactivate this camera object (the saved scene camera returns)" : "Look through this camera object (the orbit controller is disabled while it is active)")
            }
            Text(stateText).font(.callout)
            Text("Runtime only — original export keeps the saved camera and active flag.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension SourceRouteInspector: Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.model === b.model && a.id == b.id && a.playing == b.playing && a.route == b.route && a.point == b.point
    }
}

/// The sections `state` shows after the Transform section, in order.
struct ObjectInspectorKindSections {
    var character: ObjectCharacterSections?
    var item: ObjectItemSection?
    var light: ObjectLightSection?
    var camera: ObjectCameraSection?
    var sourceCamera: ObjectSourceCameraSection?
    var route: SourceRouteInspector?

    @MainActor init(model: StudioModel, state o: ObjectInspectorState) {
        switch o.kind {
        case .character: character = ObjectCharacterSections(model: model, state: o)
        case .item: item = ObjectItemSection(model: model, id: o.id, tint: o.tint, emissive: o.emissive)
        case .light: light = o.light.map { ObjectLightSection(model: model, id: o.id, light: $0) }
        case .camera: camera = ObjectCameraSection(model: model, id: o.id)
        case .folder: break
        }
        sourceCamera = o.sourceCameraName.map { ObjectSourceCameraSection(model: model, state: o, name: $0) }
        if o.routeIsSource, let route = o.route {
            self.route = SourceRouteInspector(model: model, id: o.id, playing: o.routePlaying, route: route, point: o.routePoint)
        }
    }
}

/// The kept sections of one Object tab.
@MainActor final class ObjectInspectorSectionsKept {
    let character = InspectorKeptViews<ObjectCharacterSections>()
    let item = InspectorKeptViews<ObjectItemSection>()
    let light = InspectorKeptViews<ObjectLightSection>()
    let camera = InspectorKeptViews<ObjectCameraSection>()
    let sourceCamera = InspectorKeptViews<ObjectSourceCameraSection>()
    let route = InspectorKeptViews<SourceRouteInspector>()

    /// Sections collapsed in a kept section also expand when the whole tab is hidden.
    func attach(to tab: InspectorSectionExpansion) {
        for sections in [character.sections, item.sections, light.sections, camera.sections, sourceCamera.sections, route.sections] {
            sections.parent = tab
        }
    }
}

/// The kind sections as children of the Object tab's stack, built and dropped
/// as the kind changes (as before item 7).
struct ObjectInspectorBuiltSections: View {
    let sections: ObjectInspectorKindSections

    var body: some View {
        if let s = sections.character { s.equatable() }
        if let s = sections.item { s.equatable() }
        if let s = sections.light { s.equatable() }
        if let s = sections.camera { s.equatable() }
        if let s = sections.sourceCamera { s.equatable() }
        if let s = sections.route { s.equatable() }
    }
}

/// The kind sections kept once shown. They stack with no spacing; each shown
/// one carries the stack's 10 points above it, so hidden ones add nothing.
struct ObjectInspectorKeptSections: View {
    let sections: ObjectInspectorKindSections
    let kept: ObjectInspectorSectionsKept

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KeptSection(shown: sections.character, kept: kept.character)
            KeptSection(shown: sections.item, kept: kept.item)
            KeptSection(shown: sections.light, kept: kept.light)
            KeptSection(shown: sections.camera, kept: kept.camera)
            KeptSection(shown: sections.sourceCamera, kept: kept.sourceCamera)
            KeptSection(shown: sections.route, kept: kept.route)
        }
    }
}

/// One kept section: absent until first shown, then shown or hidden with the
/// last state it showed.
struct KeptSection<Section: View & Equatable>: View {
    let shown: Section?
    let kept: InspectorKeptViews<Section>

    var body: some View {
        let hidden = shown == nil
        let _ = shown.map { kept.state = $0 }
        if let section = shown ?? kept.state {
            section.equatable()
                .background(InspectorAnchor(kept: kept))
                .environment(\.inspectorSectionExpansion, kept.sections)
                .environment(\.inspectorSectionHidden, hidden)
                .padding(.top, 10)
                .inspectorHidden(hidden)
                .onChange(of: hidden) { _, nowHidden in if nowHidden { kept.didHide() } }
        }
    }
}
