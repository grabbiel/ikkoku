import SwiftUI
import simd
import Character
import Scene

struct SliderGroupList: View {
    @Bindable var model: MakerModel
    let tab: SliderTab
    var body: some View {
        ForEach(SliderRegistry.shared.groups(for: tab), id: \.group) { g in
            SectionBox(title: g.group) {
                ForEach(g.sliders) { def in
                    SliderRow(label: def.label,
                              value: Binding(get: { model.card.slider(def.id) }, set: { model.card.setSlider(def.id, $0) }),
                              range: def.minValue...def.maxValue, defaultValue: def.defaultValue)
                }
            }
        }
    }
}

struct PresetRow: View {
    @Bindable var model: MakerModel
    let presets: [SliderPreset]
    var body: some View {
        SectionBox(title: "Presets") {
            ItemGrid(entries: presets.map { .init(id: $0.id, name: $0.name) }, selected: nil, allowNone: false) { id in
                if let p = presets.first(where: { $0.id == id }) { model.apply(preset: p) }
            }
        }
    }
}

struct FacePanel: View {
    @Bindable var model: MakerModel
    var body: some View {
        let tex = model.library.catalog.textures
        VStack(alignment: .leading, spacing: 10) {
            PresetRow(model: model, presets: SliderPresets.face)
            SectionBox(title: "Gaze") {
                Picker("Eyes look", selection: $model.card.expression.gazeMode) {
                    Text("Front").tag(0); Text("At camera").tag(1); Text("Away").tag(2)
                }.pickerStyle(.segmented)
                Toggle("Head follows too", isOn: Binding(get: { model.card.expression.headLook ?? false }, set: { model.card.expression.headLook = $0 }))
            }
            SectionBox(title: "Eye style") {
                StylePicker(label: "Iris", count: max(tex.iris?.count ?? 1, 1), index: $model.card.face.irisStyle)
                SliderRow(label: "Iris size", value: $model.card.face.irisSize)
                Toggle("Same colour for both eyes", isOn: $model.card.face.sameIrisColor).font(.callout)
                ColorRow(label: model.card.face.sameIrisColor ? "Iris colour" : "Left iris", color: $model.card.face.irisColorLeft)
                if !model.card.face.sameIrisColor { ColorRow(label: "Right iris", color: $model.card.face.irisColorRight) }
                StylePicker(label: "Highlight", count: max(tex.highlight?.count ?? 1, 1), index: $model.card.face.highlightStyle)
                FloatRow(label: "Highlight strength", value: $model.card.face.highlightStrength)
                ColorRow(label: "Eye white", color: $model.card.face.eyeWhiteColor)
            }
            SectionBox(title: "Eyebrows & lashes") {
                StylePicker(label: "Eyebrow style", count: max(tex.eyebrow?.count ?? 1, 1), index: $model.card.face.eyebrowStyle)
                ColorRow(label: "Eyebrow colour", color: $model.card.face.eyebrowColor)
                StylePicker(label: "Eyelash style", count: max(tex.eyelash?.count ?? 1, 1), index: $model.card.face.eyelashStyle)
                ColorRow(label: "Eyelash colour", color: $model.card.face.eyelashColor)
            }
            SectionBox(title: "Makeup") {
                ColorRow(label: "Eyeshadow", color: $model.card.face.eyeshadow.color)
                FloatRow(label: "Eyeshadow strength", value: $model.card.face.eyeshadow.strength)
                ColorRow(label: "Blush", color: $model.card.face.blush.color)
                FloatRow(label: "Blush strength", value: $model.card.face.blush.strength)
                ColorRow(label: "Lipstick", color: $model.card.face.lip.color)
                FloatRow(label: "Lipstick strength", value: $model.card.face.lip.strength)
            }
            SliderGroupList(model: model, tab: .face)
            Button("Reset face sliders") { model.resetSliders(tab: .face) }
        }
    }
}

struct BodyPanel: View {
    @Bindable var model: MakerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PresetRow(model: model, presets: SliderPresets.body)
            SectionBox(title: "Skin") {
                ColorRow(label: "Skin tone", color: $model.card.body.skinTone)
                ColorRow(label: "Shade tint", color: $model.card.body.skinShadeTint)
                FloatRow(label: "Gloss", value: $model.card.body.skinGloss)
                ColorRow(label: "Nails", color: $model.card.body.nailColor)
            }
            SliderGroupList(model: model, tab: .body)
            Button("Reset body sliders") { model.resetSliders(tab: .body) }
        }
    }
}

struct HairPanel: View {
    @Bindable var model: MakerModel
    var body: some View {
        let styles = model.library.catalog.hair(for: model.card.sex)
        VStack(alignment: .leading, spacing: 10) {
            SectionBox(title: "Colours") {
                ColorRow(label: "Base", color: $model.card.hair.baseColor)
                ColorRow(label: "Shade", color: $model.card.hair.shadeColor)
                ColorRow(label: "Highlight", color: $model.card.hair.highlightColor)
                ColorRow(label: "Outline", color: $model.card.hair.outlineColor)
                FloatRow(label: "Gloss", value: $model.card.hair.gloss)
                Button("Derive shade/highlight from base") {
                    let b = model.card.hair.baseColor
                    model.card.hair.shadeColor = b.scaled(0.62)
                    model.card.hair.highlightColor = b.mixed(.white, 0.7)
                    model.card.hair.outlineColor = b.scaled(0.35)
                }
            }
            ForEach(HairSlot.allCases, id: \.self) { slot in
                let slotStyles = styles.filter { ($0.slot ?? "back") == slot.rawValue || ($0.slot == nil && slot == .back) || $0.slot == "any" }
                if !slotStyles.isEmpty || slot == .back {
                    SectionBox(title: "\(slot.rawValue.capitalized) hair") {
                        ItemGrid(entries: slotStyles.map { .init(id: $0.id, name: $0.name, thumb: Thumbs.url("hair", $0.id)) },
                                 selected: model.card.hair.parts[slot]?.styleID, allowNone: true) { id in
                            model.card.hair.parts[slot] = HairPart(styleID: id)
                        }
                    }
                }
            }
        }
    }
}

struct ClothesPanel: View {
    @Bindable var model: MakerModel
    @State private var slot: ClothSlot = .top
    var body: some View {
        let cat = model.library.catalog
        VStack(alignment: .leading, spacing: 10) {
            Picker("Outfit", selection: $model.card.currentOutfit) {
                ForEach(0..<model.card.outfits.count, id: \.self) { i in Text(model.card.outfits[i].name).tag(i) }
            }
            Picker("Slot", selection: $slot) {
                ForEach(ClothSlot.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.menu)
            let items = cat.clothes(slot: slot.rawValue, sex: model.card.sex)
            ItemGrid(entries: items.map { .init(id: $0.id, name: $0.name, thumb: Thumbs.url("cloth", $0.id)) },
                     selected: model.card.outfit.items[slot]?.itemID, allowNone: true) { id in
                var item = model.card.outfit.items[slot] ?? ClothItem()
                item.itemID = id
                model.card.outfit.items[slot] = item
            }
            if let item = model.card.outfit.items[slot], item.itemID != nil {
                let entry = item.itemID.flatMap { cat.cloth($0) }
                let names = entry?.colors ?? ["Colour 1", "Colour 2", "Colour 3"]
                SectionBox(title: "Colours") {
                    ForEach(0..<min(3, names.count), id: \.self) { i in
                        ColorRow(label: names[i], color: Binding(get: { model.card.outfit.items[slot]?.colors[i] ?? .white },
                                                                  set: { model.card.outfit.items[slot]?.colors[i] = $0 }))
                    }
                    let patterns = cat.textures.patterns ?? []
                    HStack {
                        Text("Pattern").font(.callout).frame(width: 118, alignment: .leading)
                        Picker("", selection: Binding(get: { model.card.outfit.items[slot]?.pattern ?? 0 }, set: { model.card.outfit.items[slot]?.pattern = $0 })) {
                            Text("None").tag(0)
                            ForEach(0..<patterns.count, id: \.self) { i in Text(patterns[i].replacingOccurrences(of: "pattern_", with: "").replacingOccurrences(of: ".png", with: "").capitalized).tag(i + 1) }
                        }.labelsHidden()
                    }
                    if (model.card.outfit.items[slot]?.pattern ?? 0) > 0 {
                        ColorRow(label: "Pattern colour", color: Binding(get: { model.card.outfit.items[slot]?.patternColor ?? .white }, set: { model.card.outfit.items[slot]?.patternColor = $0 }))
                        FloatRow(label: "Pattern scale", value: Binding(get: { model.card.outfit.items[slot]?.patternScale ?? 4 }, set: { model.card.outfit.items[slot]?.patternScale = $0 }), range: 1...16)
                    }
                    FloatRow(label: "Gloss", value: Binding(get: { model.card.outfit.items[slot]?.gloss ?? 0.25 }, set: { model.card.outfit.items[slot]?.gloss = $0 }))
                }
                Picker("State", selection: Binding(get: { model.card.outfit.states[slot] ?? .on }, set: { model.card.outfit.states[slot] = $0 })) {
                    ForEach(ClothState.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.segmented)
            }
        }
    }
}

struct AccessoryPanel: View {
    @Bindable var model: MakerModel
    var body: some View {
        let cat = model.library.catalog
        let i = model.selectedAccessory
        VStack(alignment: .leading, spacing: 10) {
            Picker("Slot", selection: $model.selectedAccessory) {
                ForEach(0..<model.card.accessories.count, id: \.self) { k in
                    let name = model.card.accessories[k].itemID.flatMap { cat.accessory($0)?.name } ?? "Empty"
                    Text("Slot \(k + 1): \(name)").tag(k)
                }
            }
            ItemGrid(entries: cat.accessories.map { .init(id: $0.id, name: $0.name, thumb: Thumbs.url("acc", $0.id)) }, selected: model.card.accessories[i].itemID, allowNone: true) { id in
                model.card.accessories[i].itemID = id
                if let id, let e = cat.accessory(id), let p = e.parent { model.card.accessories[i].parent = p }
            }
            if model.card.accessories[i].itemID != nil {
                SectionBox(title: "Attach") {
                    let bones = model.character.skeleton?.bones.map(\.name) ?? ["head"]
                    Picker("Parent bone", selection: $model.card.accessories[i].parent) {
                        ForEach(bones, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Visible", isOn: $model.card.accessories[i].visible)
                    VectorRow(label: "Position", value: $model.card.accessories[i].position, step: 0.005, format: "%.3f")
                    VectorRow(label: "Rotation", value: $model.card.accessories[i].rotation, step: 5, format: "%.0f")
                    VectorRow(label: "Scale", value: $model.card.accessories[i].scale, step: 0.05, format: "%.2f")
                }
                SectionBox(title: "Colours") {
                    let names = model.card.accessories[i].itemID.flatMap { cat.accessory($0)?.colors } ?? ["Colour 1", "Colour 2", "Colour 3"]
                    ForEach(0..<min(3, names.count), id: \.self) { k in
                        ColorRow(label: names[k], color: $model.card.accessories[i].colors[k])
                    }
                }
            }
        }
    }
}

struct VectorRow: View {
    let label: String
    @Binding var value: SIMD3<Float>
    var step: Float
    var format: String
    var body: some View {
        HStack {
            Text(label).font(.callout).frame(width: 70, alignment: .leading)
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 2) {
                    Text(["X", "Y", "Z"][i]).font(.caption2).foregroundStyle(.secondary)
                    TextField("", value: Binding(get: { value[i] }, set: { value[i] = $0 }), format: .number.precision(.fractionLength(format == "%.0f" ? 0 : (format == "%.2f" ? 2 : 3))))
                        .textFieldStyle(.roundedBorder).font(.caption).frame(width: 54)
                    Stepper("", value: Binding(get: { value[i] }, set: { value[i] = $0 }), step: step).labelsHidden()
                }
            }
        }
    }
}

struct ProfilePanel: View {
    @Bindable var model: MakerModel
    static let personalities = ["Cheerful", "Serious", "Gentle", "Tomboy", "Shy", "Lively", "Mysterious", "Confident", "Playful", "Cool", "Airhead", "Bookworm", "Sporty", "Elegant"]
    static let clubs = ["None", "Swimming", "Tea ceremony", "Cheerleading", "Cooking", "Manga", "Music", "Track & field", "Drama"]
    static let traits = ["Kind", "Clumsy", "Ambitious", "Lazy", "Romantic", "Honest", "Stubborn", "Curious", "Loyal", "Dreamy", "Brave", "Timid"]
    static let hobbies = ["Reading", "Gaming", "Sports", "Cooking", "Music", "Drawing", "Movies", "Travel", "Photography", "Fashion", "Gardening", "Stargazing"]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionBox(title: "Identity") {
                LabeledContent("Name") { TextField("Name", text: $model.card.profile.name) }
                LabeledContent("Nickname") { TextField("Nickname", text: $model.card.profile.nickname) }
                Picker("Sex", selection: $model.card.sex) { Text("Female").tag(Sex.female); Text("Male").tag(Sex.male) }
                    .onChange(of: model.card.sex) { _, s in model.card.body.bodyID = s == .female ? "body_f" : "body_m" }
                Picker("Personality", selection: $model.card.profile.personality) { ForEach(Self.personalities, id: \.self) { Text($0).tag($0) } }
                Picker("Blood type", selection: $model.card.profile.bloodType) { ForEach(["A", "B", "O", "AB"], id: \.self) { Text($0).tag($0) } }
                HStack {
                    Picker("Birthday", selection: $model.card.profile.birthMonth) { ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) } }
                    Picker("", selection: $model.card.profile.birthDay) { ForEach(1...31, id: \.self) { Text("\($0)").tag($0) } }.labelsHidden().frame(width: 70)
                }
                Picker("Club", selection: $model.card.profile.club) { ForEach(Self.clubs, id: \.self) { Text($0).tag($0) } }
            }
            SectionBox(title: "Traits") { TagToggles(all: Self.traits, selected: $model.card.profile.traits, max: 3) }
            SectionBox(title: "Hobbies") { TagToggles(all: Self.hobbies, selected: $model.card.profile.hobbies, max: 4) }
            SectionBox(title: "Notes") { TextEditor(text: $model.card.profile.notes).frame(height: 80).font(.callout) }
        }
    }
}

struct TagToggles: View {
    let all: [String]
    @Binding var selected: [String]
    let max: Int
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 4) {
            ForEach(all, id: \.self) { t in
                let on = selected.contains(t)
                Button { if on { selected.removeAll { $0 == t } } else if selected.count < max { selected.append(t) } } label: {
                    Text(t).font(.caption).frame(maxWidth: .infinity).padding(4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12)))
                }.buttonStyle(.plain)
            }
        }
    }
}
