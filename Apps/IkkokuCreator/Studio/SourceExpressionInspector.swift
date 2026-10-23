import SwiftUI
import Studio
import Character

/// Observes document edits, never the renderer's frame clock or frame output.
/// The preview owns immutable option lists and edit-time diagnostics.
struct SourceExpressionInspector: View {
    let model: StudioModel
    let object: StudioObject
    let preview: SourceStudioCharacterPreview

    var body: some View {
        SectionBox(title: "Expression") {
            Picker("Eyebrows", selection: binding(\.eyebrowPattern)) {
                ForEach(options(Array(0..<preview.expressionControls.eyebrowPatternCount), saved: preview.savedExpression.eyebrowPattern), id: \.self) { Text("Pattern \($0)").tag($0) }
            }
            Picker("Eyes", selection: binding(\.eyesPattern)) {
                ForEach(preview.expressionControls.eyeRows, id: \.id) { Text("\($0.id): \($0.name)").tag($0.id) }
                if preview.expressionControls.eyeRow(preview.savedExpression.eyesPattern) == nil {
                    Text("Saved pattern \(preview.savedExpression.eyesPattern)").tag(preview.savedExpression.eyesPattern)
                }
            }
            Picker("Mouth", selection: binding(\.mouthPattern)) {
                ForEach(options(Array(0..<preview.expressionControls.mouthPatternCount), saved: preview.savedExpression.mouthPattern), id: \.self) { Text("Pattern \($0)").tag($0) }
            }
            FloatRow(label: "Eyes open", value: binding(\.eyesOpen))
            Toggle("Blink", isOn: binding(\.blink))
            FloatRow(label: "Mouth open", value: binding(\.mouthOpen))
            Toggle("Lip sync", isOn: binding(\.lipSync))
            Picker("Eye look", selection: binding(\.eyesLookPattern)) {
                ForEach(options(SourceStudioExpressionControls.eyesLookPatterns, saved: preview.savedExpression.eyesLookPattern), id: \.self) { Text(lookName($0, eyes: true)).tag($0) }
            }
            Picker("Neck look", selection: binding(\.neckLookPattern)) {
                ForEach(options(SourceStudioExpressionControls.neckLookPatterns, saved: preview.savedExpression.neckLookPattern), id: \.self) { Text(lookName($0, eyes: false)).tag($0) }
            }
            .disabled((try? model.sourceFKOwnsNeck(object.id)) == true)
            .help("Turn off the FK neck group to edit neck look.")
            Picker("Tears", selection: binding(\.tears)) {
                ForEach(options(SourceStudioExpressionControls.tearsLevels, saved: preview.savedExpression.tears), id: \.self) { Text($0 == 0 ? "None" : "Level \($0)").tag($0) }
            }
            FloatRow(label: "Cheek", value: binding(\.cheek))
            Button("Reset to card") {
                do { try model.resetSourceExpression(object.id) }
                catch { model.status = "Expression reset: \(error)" }
            }
            if !preview.expressionDiagnostics.isEmpty {
                Text(preview.expressionDiagnostics.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("studio.face.source.expression")
    }

    private func binding<T>(_ path: WritableKeyPath<SourceStudioExpressionState, T>) -> Binding<T> {
        Binding(get: { (object.sourceExpression ?? preview.savedExpression)[keyPath: path] }, set: { value in
            // Read the current preview, so successive slider events never
            // overwrite another field with an earlier view's snapshot.
            var next = preview.expressionState
            next[keyPath: path] = value
            do { try model.setSourceExpression(object.id, next) }
            catch { model.status = "Expression edit: \(error)" }
        })
    }

    private func options(_ values: [Int], saved: Int) -> [Int] {
        values.contains(saved) ? values : values + [saved]
    }

    private func lookName(_ value: Int, eyes: Bool) -> String {
        switch value {
        case 0: "Forward"
        case 1: "Camera"
        case 2: eyes ? "Control" : "Away (saved)"
        case 3: eyes ? "Away" : "Animation"
        case 4: eyes ? "Look-at guide" : "Fixed"
        default: "Saved pattern \(value)"
        }
    }
}
