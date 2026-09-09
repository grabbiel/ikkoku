import SwiftUI
import Character
import Renderer

struct MakerView: View {
    @Bindable var model: MakerModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker("", selection: $model.tab) {
                    ForEach(MakerTab.allCases) { t in Image(systemName: t.symbol).tag(t).help(t.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(8)
                Text(model.tab.rawValue).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                ScrollView {
                    Group {
                        switch model.tab {
                        case .face: FacePanel(model: model)
                        case .body: BodyPanel(model: model)
                        case .hair: HairPanel(model: model)
                        case .clothes: ClothesPanel(model: model)
                        case .accessories: AccessoryPanel(model: model)
                        case .profile: ProfilePanel(model: model)
                        }
                    }
                    .padding(12)
                }
                Divider()
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(6)
            }
            .frame(width: 400)
            Divider()
            ZStack(alignment: .top) {
                ViewportView(renderer: model.host.renderer, handler: model)
                viewportToolbar
            }
        }
    }

    private var viewportToolbar: some View {
        HStack(spacing: 10) {
            Picker("Outfit", selection: $model.card.currentOutfit) {
                ForEach(0..<model.card.outfits.count, id: \.self) { i in Text(model.card.outfits[i].name).tag(i) }
            }.frame(width: 190)
            Divider().frame(height: 18)
            expressionPickers
            Divider().frame(height: 18)
            ForEach(CameraPreset.allCases) { p in Button(p.rawValue) { model.apply(preset: p) } }
            Toggle(isOn: $model.showBones) { Image(systemName: "figure.walk") }.toggleStyle(.button).help("Show bones")
            Toggle(isOn: $model.showGrid) { Image(systemName: "grid") }.toggleStyle(.button).help("Show grid")
            Toggle(isOn: $model.liveAnimation) { Image(systemName: "wind") }.toggleStyle(.button).help("Idle animation (blink, breathing)")
            Spacer()
            Button { model.randomize() } label: { Label("Random", systemImage: "dice") }
            Button { model.newCharacter(sex: model.card.sex) } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
        }
        .controlSize(.small)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }

    private var expressionPickers: some View {
        HStack(spacing: 6) {
            Picker("Brows", selection: $model.card.expression.eyebrows) {
                ForEach(0..<ExpressionPresets.eyebrowPatterns.count, id: \.self) { Text(ExpressionPresets.eyebrowPatterns[$0].name).tag($0) }
            }.frame(width: 110)
            Picker("Eyes", selection: $model.card.expression.eyes) {
                ForEach(0..<ExpressionPresets.eyePatterns.count, id: \.self) { Text(ExpressionPresets.eyePatterns[$0].name).tag($0) }
            }.frame(width: 110)
            Picker("Mouth", selection: $model.card.expression.mouth) {
                ForEach(0..<ExpressionPresets.mouthPatterns.count, id: \.self) { Text(ExpressionPresets.mouthPatterns[$0].name).tag($0) }
            }.frame(width: 110)
        }
    }
}
