import SwiftUI
import Assets
import Character
import Scene
import AppKit
import CoreMath

struct SourceRigPanel: View {
    @Bindable var model: MakerModel

    var body: some View {
        if let preview = model.sourceRigPreview {
            VStack(alignment: .leading, spacing: 14) {
                Text("Original model preview").font(.title2.bold())
                Text(URL(fileURLWithPath: preview.source.sourcePrefab).deletingPathExtension().lastPathComponent)
                    .font(.headline).textSelection(.enabled)
                Text("Original geometry, shape curves and facial expressions. Materials are still being rebuilt.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if !model.sourceAssetSelections.isEmpty {
                    DisclosureGroup("Card-selected assets") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(model.sourceAssetSelections.enumerated()), id: \.offset) { _, selected in
                                    Text("\(selected.entry?.name ?? selected.property) · \(selected.status)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxHeight: 160)
                    }
                }
                if !model.sourceCardDiagnostics.isEmpty {
                    DisclosureGroup("Imported card settings") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(model.sourceCardDiagnostics.enumerated()), id: \.offset) { _, message in
                                    Text(message).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxHeight: 140)
                    }
                }
                if model.sourceCardModReport?.pluginID != nil || !model.sourceCardModDiagnostics.isEmpty {
                    DisclosureGroup("Card mod references") {
                        VStack(alignment: .leading, spacing: 6) {
                            if let report = model.sourceCardModReport {
                                let matches = report.resolutions.filter { $0.status == "resolved" }.count
                                Text("\(report.resolutions.count) references · \(matches) catalog matches")
                                    .font(.caption.bold())
                            }
                            Text("This checks availability. Converted assets are loaded by saved identity. Unconverted dependencies remain listed below.")
                                .font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(model.sourceCardModDiagnostics.enumerated()), id: \.offset) { _, message in
                                        Text(message).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let report = model.sourceCardModReport {
                                        ForEach(report.resolutions, id: \.record.index) { resolution in
                                            modReference(resolution)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 180)
                        }.textSelection(.enabled)
                    }
                }
                if preview.supportsBodyCustomization || preview.supportsFaceCustomization {
                    Toggle("Apply customization", isOn: $model.applySourceCustomization)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if preview.supportsBodyCustomization {
                                ForEach(preview.contract?.domain("body")?.slots ?? [], id: \.index) { slot in
                                    if preview.bodyCoverage?.boundSlots.contains(slot.index) == true,
                                       model.sourceBodyValues.indices.contains(slot.index) {
                                        shapeSlider(label: slot.label, value: $model.sourceBodyValues[slot.index])
                                            .disabled(model.sourceSex == 0 && slot.index == 0)
                                    }
                                }
                                Text("\(preview.bodyCoverage?.completeSlots.count ?? 0) complete body controls. Normal male height follows the original fixed value.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if preview.supportsFaceCustomization, let face = preview.contract?.domain("face") {
                                ForEach(face.slots, id: \.index) { slot in
                                    shapeSlider(label: Self.faceLabels.indices.contains(slot.index) ? Self.faceLabels[slot.index] : slot.label,
                                                value: $model.sourceFaceValues[slot.index])
                                }
                            }
                        }.padding(.trailing, 8)
                    }.disabled(!model.applySourceCustomization)
                    Button("Reset to source defaults") { model.resetSourceShapes() }
                } else {
                    Text("No supported shape curves were found for this rig.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                Divider()
                if let draft = model.sourceAppearanceDraft {
                    DisclosureGroup("Card appearance") {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.sourceCoordinateCount > 1 {
                                Picker("Outfit", selection: Binding(get: { model.sourceBoneModifierCoordinate }, set: { index in
                                    do { try model.selectSourceCoordinate(index) }
                                    catch { model.status = "Outfit: \(error)" }
                                })) {
                                    ForEach(0..<model.sourceCoordinateCount, id: \.self) { Text("Outfit \($0 + 1)").tag($0) }
                                }
                            }
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(draft.colors.filter { model.sourceAppearanceAppliedFields.contains($0.id) }) { color in
                                        ColorPicker(color.label, selection: colorBinding(color.id), supportsOpacity: false)
                                    }
                                }
                            }.frame(maxHeight: 200)
                            Button("Apply colors") {
                                do { try model.applySourceAppearance() }
                                catch { model.status = "Appearance: \(error)" }
                            }.disabled(model.sourceAppearanceAppliedFields.isEmpty)
                            Text("Export writes shape and supported color edits to a new original-format card. Other fields and plugin data are preserved.")
                                .font(.caption).foregroundStyle(.secondary)
                            if !model.sourceAppearanceDiagnostics.isEmpty {
                                DisclosureGroup("Appearance compatibility") {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(Array(model.sourceAppearanceDiagnostics.enumerated()), id: \.offset) { _, message in
                                                Text(message).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }.frame(maxHeight: 150)
                                }
                            }
                        }
                    }
                }
                if model.hasSourceIdle || model.hasSourceHairDynamics {
                    Text("Motion").font(.headline)
                    if model.hasSourceIdle { Toggle("Original idle animation", isOn: $model.sourceIdleAnimation) }
                    if model.hasSourceHairDynamics { Toggle("Original hair motion", isOn: $model.sourceHairDynamics) }
                    Divider()
                }
                if preview.supportsExpressions, let contract = preview.expressionContract {
                    Text("Expression").font(.headline)
                    Menu("Choose expression") {
                        ForEach(contract.presets, id: \.id) { preset in
                            Button(preset.label) {
                                if (0..<1).contains(preset.inputs.blinkRate) { model.sourceAutomaticBlink = false }
                                model.sourceExpressionInputs = preset.inputs
                            }
                        }
                    }
                    Toggle("Automatic blinking", isOn: $model.sourceAutomaticBlink)
                    shapeSlider(label: "Eyes open", value: expressionBinding(\.blinkRate))
                        .disabled(model.sourceAutomaticBlink)
                    shapeSlider(label: "Mouth open", value: expressionBinding(\.mouthOpenRate))
                    Divider()
                }
                Toggle("Show skeleton", isOn: $model.showBones)
                if let modifiers = model.sourceBoneModifiers {
                    Toggle("Apply bone modifiers (\(modifiers.count))", isOn: $model.applySourceBoneModifiers)
                    if model.importedSourceCard == nil, let count = modifiers.coordinateCounts.max(), count > 1 {
                        Stepper("Outfit \(model.sourceBoneModifierCoordinate + 1)", value: $model.sourceBoneModifierCoordinate, in: 0...(count - 1))
                    }
                    ForEach(Array((modifiers.diagnostics ?? []).enumerated()), id: \.offset) { _, diagnostic in
                        Text(diagnostic.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Show grid", isOn: $model.showGrid)
                HStack {
                    ForEach(CameraPreset.allCases) { preset in
                        Button(preset.rawValue) { model.apply(preset: preset) }
                    }
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Button("Use bundled prototype") { model.closeSourceRig() }
            }
            .padding(20).frame(width: 400)
        }
    }

    private func colorBinding(_ id: String) -> Binding<Color> {
        Binding(get: {
            let value = model.sourceAppearanceDraft?.color(id) ?? .one
            return Color(.sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z), opacity: Double(value.w))
        }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            model.setSourceColor(id, rgba: Float4(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent), Float(rgb.alphaComponent)))
        })
    }

    private func modReference(_ resolution: SourceCardModReferences.Resolution) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(resolution.entry?.name ?? resolution.record.name ?? "Mod reference \(resolution.record.index + 1)")
                .font(.caption.bold())
            Text(resolution.record.property ?? "No saved property").font(.caption)
            Text("\(resolution.record.modGUID ?? "No mod identity") · category \(resolution.record.category) · source slot \(resolution.record.sourceSlot)")
                .font(.caption2).foregroundStyle(.secondary)
            Text(Self.referenceStatus(resolution.status)).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(resolution.dependencies.enumerated()), id: \.offset) { _, dependency in
                Text("\(dependency.reference.role): \(Self.dependencyStatus(dependency.status)) · \(dependency.reference.assetName)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private static func referenceStatus(_ status: String) -> String {
        switch status {
        case "resolved": return "Catalog entry found; appearance not applied"
        case "shadowed": return "A preceding saved reference takes priority"
        case "unmatchedProperty": return "Saved property does not match a supported card destination"
        case "compatibilityRequired": return "Requires an unimplemented compatibility rule"
        case "libraryNotLoaded": return "Load a mod library to check availability"
        case "catalogUnavailable": return "The library has no source catalog contract"
        case "modNotMounted": return "The referenced mod is not mounted"
        case "catalogEntryMissing": return "No matching entry in the mounted catalog"
        case "metadataOnly": return "Metadata retained; destination matching unavailable"
        default: return status
        }
    }

    private static func dependencyStatus(_ status: String) -> String {
        switch status {
        case "convertedTexture": return "converted texture available"
        case "sourceOnly": return "source asset indexed; conversion pending"
        case "wrongAssetType": return "indexed asset type does not match"
        case "unresolved": return "not found in the available inventory"
        case "ambiguousSourceBundle": return "ambiguous bundle; reimport required"
        default: return status
        }
    }

    private func expressionBinding(_ key: WritableKeyPath<SourceExpressionInputs, Float>) -> Binding<Float> {
        Binding(get: { model.sourceExpressionInputs?[keyPath: key] ?? 0 }, set: { value in
            guard var inputs = model.sourceExpressionInputs else { return }
            inputs[keyPath: key] = value
            model.sourceExpressionInputs = inputs
        })
    }

    private func shapeSlider(label: String, value: Binding<Float>) -> some View {
        VStack(spacing: 4) {
            HStack { Text(label); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(2))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: 0...1)
        }
    }

    // Display translations only. Slot identity and runtime mappings come from recovered data.
    private static let faceLabels = [
        "Face width", "Upper face depth", "Upper face height", "Upper face size", "Lower face depth", "Lower face width",
        "Lower chin height", "Lower chin depth", "Jaw height", "Jaw width", "Jaw depth", "Chin tip height", "Chin tip depth", "Chin tip width",
        "Cheekbone width", "Cheekbone depth", "Cheek width", "Cheek depth", "Cheek height", "Brow height", "Brow spacing", "Brow angle",
        "Inner brow shape", "Outer brow shape", "Upper eyelid shape 1", "Upper eyelid shape 2", "Upper eyelid shape 3",
        "Lower eyelid shape 1", "Lower eyelid shape 2", "Lower eyelid shape 3", "Eye height", "Eye spacing", "Eye depth", "Eye angle",
        "Eye vertical size", "Eye horizontal size", "Inner eye position", "Outer eye height", "Nose tip height", "Nose position", "Nose bridge height",
        "Mouth height", "Mouth width", "Mouth depth", "Upper lip shape", "Lower lip shape", "Mouth corner shape", "Ear size", "Ear yaw", "Ear roll",
        "Upper ear shape", "Lower ear shape"]
}
