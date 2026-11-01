import Foundation
import Character
import CoreMath
import Renderer
import Scene
import Studio

/// JSON-driven Maker scenario: a scripted sequence of checklist moves over the
/// imported source card, run headlessly behind `IKKOKU_MAKER_SCENARIO` so the
/// `docs/component-audit/README.md` checklist items that are scriptable through
/// `MakerModel`'s own API (outfit switch, shape/color edits, export and
/// reimport) run in the verification lane instead of by hand. The scenario
/// asserts only what `exportSourceCard` actually writes — `faceValues`,
/// `bodyValues` and the `sourceColorEdits` colors — never the selected
/// outfit, which is a view choice the export does not store.
struct MakerScenario: Decodable {
    struct Step: Decodable {
        /// `"customization"`, `"selectCoordinate"`, `"setFace"`, `"setBody"`,
        /// `"setColor"`, `"resetShapes"`, `"export"`, `"reimport"`, `"assert"`.
        let op: String
        /// customization only: the new `applySourceCustomization` flag.
        let on: Bool?
        /// selectCoordinate/setFace/setBody: the outfit index or shape slot.
        let index: Int?
        let value: Float?
        let id: String?
        let rgba: [Float]?
        let path: String?
        /// assert only: the outfit the draft must show (a view state, only
        /// assertable before a reimport; export does not write it).
        let coordinate: Int?
        /// assert only: the face slot and rate the Maker must show.
        let face: SlotValue?
        /// assert only: the body slot and rate the Maker must show.
        let body: SlotValue?
        /// assert only: the draft color and rgba the Maker must show.
        let color: ColorValue?
        /// assert only: a color id that must be in `sourceAppearanceAppliedFields`.
        let colorApplied: String?
        /// assert only: a substring one import/appearance diagnostic must contain.
        let diagnosticContains: String?
        let selection: SelectionValue?
        let expectFailure: Bool?, unchanged: Bool?
        let resourcesAtMost: String?
        /// reimport only: sample the process footprint around the import
        /// (#192-C timing). Lane scenarios leave it unset and sample nothing.
        let footprint: Bool?
        /// Any step: the decoded-rig hits and misses of the head selection it
        /// committed (`SourceSelectionTiming.headRigReuse`).
        let rigReuse: RigReuseValue?
        /// Any step: outcomes of the current initial-load sample, the startup
        /// import's until a reimport or reload records its own (CXM1).
        let initialLoad: InitialLoadValue?
        struct RigReuseValue: Decodable { let hits: Int, misses: Int }
        struct InitialLoadValue: Decodable { let geometry: String?, referenceLoad: String?, cachePublication: String? }
        struct SelectionValue: Decodable {
            let kind: String, slot: Int, sourceID: Int
            let coordinate: Int?
            func destination(currentCoordinate: Int) throws -> SourceMakerSelectionSlot {
                switch kind {
                case "hair": return .hair(slot)
                case "clothes": return .clothes(coordinate: coordinate ?? currentCoordinate, slot: slot)
                default: throw SourceCharacterCardError.invalid("Unknown Maker selection kind.")
                }
            }
            @MainActor func apply(to maker: MakerModel, beforePreparation: (@Sendable () -> Void)? = nil) async throws {
                try validate(currentCoordinate: maker.sourceBoneModifierCoordinate)
                if kind == "head" {
                    try await maker.selectSourceHead(sourceID, beforePreparation: beforePreparation)
                } else {
                    try await maker.selectSourceAsset(destination(currentCoordinate: maker.sourceBoneModifierCoordinate),
                        id: sourceID, beforePreparation: beforePreparation)
                }
            }
            func validate(currentCoordinate: Int) throws {
                if kind == "head" {
                    guard slot == 0, coordinate == nil else { throw SourceCharacterCardError.invalid("Head selection has no part slot or outfit.") }
                } else { _ = try destination(currentCoordinate: currentCoordinate).destination() }
            }
        }

        struct SlotValue: Decodable { let index: Int; let value: Float }
        struct ColorValue: Decodable { let id: String; let rgba: [Float] }

        private enum CodingKeys: String, CodingKey {
            case op, on, index, value, id, rgba, path, coordinate, face, body, color,
                 colorApplied, diagnosticContains, selection, expectFailure, unchanged, resourcesAtMost, rigReuse, initialLoad
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            op = try c.decode(String.self, forKey: .op)
            on = try c.decodeIfPresent(Bool.self, forKey: .on)
            index = try c.decodeIfPresent(Int.self, forKey: .index)
            value = try c.decodeIfPresent(Float.self, forKey: .value)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            rgba = try c.decodeIfPresent([Float].self, forKey: .rgba)
            path = try c.decodeIfPresent(String.self, forKey: .path)
            // Same rule as the Studio scenario's `activeCamera`/`sourceRuntime`
            // fix (PR #69): every assert field decodes with `decodeIfPresent`
            // so an absent key stays `nil` ("not asserted") and a bare assert
            // never grows phantom expectations.
            coordinate = try c.decodeIfPresent(Int.self, forKey: .coordinate)
            face = try c.decodeIfPresent(SlotValue.self, forKey: .face)
            body = try c.decodeIfPresent(SlotValue.self, forKey: .body)
            color = try c.decodeIfPresent(ColorValue.self, forKey: .color)
            colorApplied = try c.decodeIfPresent(String.self, forKey: .colorApplied)
            diagnosticContains = try c.decodeIfPresent(String.self, forKey: .diagnosticContains)
            selection = try c.decodeIfPresent(SelectionValue.self, forKey: .selection)
            expectFailure = try c.decodeIfPresent(Bool.self, forKey: .expectFailure)
            unchanged = try c.decodeIfPresent(Bool.self, forKey: .unchanged)
            resourcesAtMost = try c.decodeIfPresent(String.self, forKey: .resourcesAtMost)
            rigReuse = try c.decodeIfPresent(RigReuseValue.self, forKey: .rigReuse)
            initialLoad = try c.decodeIfPresent(InitialLoadValue.self, forKey: .initialLoad)
        }
    }

    let steps: [Step]

    struct Report: Encodable {
        struct StepResult: Encodable {
            let op: String
            let ok: Bool
            let detail: String
            let selectionMilliseconds: Double?
            let selectionStages: MakerModel.SourceSelectionTiming?
            let initialLoad: MakerModel.SourceInitialLoadTiming?
            let mainActorMaximumGapMilliseconds: Double?
            let mainActorHeartbeatCount: Int?
            let resourcesBefore: ResourceStore.Statistics?
            let resources: ResourceStore.Statistics?
            let footprint: MakerScenarioFootprint.Sample?
        }
        let steps: [StepResult]
        let passed: Int
        let failed: Int
        /// Captured before scenario edits/reimports; later successful reloads
        /// have their own step samples, and failures cannot reuse this value.
        let startupInitialLoad: MakerModel.SourceInitialLoadTiming?

        func json() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }
    }

    /// Numeric compares (shape rates) match within this bound.
    static let tolerance: Float = 1e-5
    /// Color components compare within one 8-bit step: the card stores colors
    /// as bytes, so a round trip cannot carry more precision than 1/255.
    static let colorTolerance: Float = 1.0 / 255.0

    /// Runs the steps against the imported card. A failing step records its
    /// detail and the run continues; a failed `export`/`reimport` stops it,
    /// because every later step depends on the file they were to write. An
    /// explicitly expected, atomically unchanged reimport failure can continue.
    static func run(_ scenario: MakerScenario, maker: MakerModel, app: AppState) async -> Report {
        let startupInitialLoad = maker.sourceInitialLoadTiming
        var results: [Report.StepResult] = []
        var heldSelection: (task: Task<Void, Error>, gate: MakerSelectionGate)?
        defer { heldSelection?.gate.release(); heldSelection?.task.cancel() }
        var heartbeat: MakerSelectionHeartbeat?
        var inactiveStudioFrame: RenderFrame?
        struct SelectionState: Equatable {
            let preview: ObjectIdentifier?, card: Data?, face: [Float], body: [Float], coordinate: Int
            let rigURL: URL?, headID: Int, expressions: SourceExpressionInputs?
            let colors: [String: Float4]
            let customization: Bool, applyBoneModifiers: Bool, boneModifierHash: String?
        }
        func selectionState() -> SelectionState {
            SelectionState(preview: maker.sourceRigPreview.map(ObjectIdentifier.init), card: maker.importedSourceCard?.preservedData,
                face: maker.sourceFaceValues, body: maker.sourceBodyValues, coordinate: maker.sourceBoneModifierCoordinate,
                rigURL: maker.sourceRigURL, headID: maker.sourceHeadID, expressions: maker.sourceExpressionInputs,
                colors: Dictionary(uniqueKeysWithValues: (maker.sourceAppearanceDraft?.colors ?? []).map { ($0.id, $0.rgba) }),
                customization: maker.applySourceCustomization, applyBoneModifiers: maker.applySourceBoneModifiers,
                boneModifierHash: maker.sourceBoneModifiers?.source.payloadSHA256)
        }
        func showEmptyStudio() throws -> RenderFrame {
            guard let studio = app.studio else { throw RigError.invalid("Mode check needs Studio.") }
            studio.liveAnimation = false; studio.timelinePlaying = false
            studio.newScene()
            app.mode = .studio // Exercise the same app transition as the mode picker.
            let frame = maker.host.renderer.currentFrame()
            guard frame.items.isEmpty, frame.skinSets.isEmpty, frame.gizmos.isEmpty, frame.lights.isEmpty else {
                throw RigError.invalid("Mode check expected an empty Studio frame.")
            }
            return frame
        }
        func studioFrameMatches(_ expected: RenderFrame) -> Bool {
            let actual = maker.host.renderer.currentFrame()
            return app.mode == .studio && !maker.isActiveMode && app.studio?.doc.objects.isEmpty == true
                && actual.items.isEmpty && actual.skinSets.isEmpty && actual.camera == expected.camera
                && actual.mainLight == expected.mainLight && actual.effects == expected.effects
                && actual.sceneBounds == expected.sceneBounds && actual.time == expected.time
                && actual.gizmos.count == expected.gizmos.count && actual.lights.count == expected.lights.count
        }
        func sameStaticFrame(_ a: RenderFrame, _ b: RenderFrame) -> Bool {
            a.camera == b.camera && a.mainLight == b.mainLight && a.effects == b.effects && a.lights == b.lights
                && a.sceneBounds == b.sceneBounds && a.time == b.time && a.skinSets == b.skinSets
                && a.gizmos.count == b.gizmos.count && a.items.count == b.items.count
                && zip(a.items, b.items).allSatisfy {
                    $0.mesh == $1.mesh && $0.model == $1.model && $0.material == $1.material && $0.objectID == $1.objectID
                        && $0.deformKey == $1.deformKey && $0.skinSet == $1.skinSet && $0.hiddenKey == $1.hiddenKey
                        && $0.visible == $1.visible && $0.hiddenRegions == $1.hiddenRegions && $0.order == $1.order
                        && $0.castsShadow == $1.castsShadow && $0.outline == $1.outline && $0.outlineScale == $1.outlineScale
                        && $0.morphWeights.map(\.index) == $1.morphWeights.map(\.index)
                        && $0.morphWeights.map(\.weight) == $1.morphWeights.map(\.weight)
                }
        }
        // The file the model currently holds: the `IKKOKU_SOURCE_CARD` import,
        // replaced by each `reimport`. The export guard below never deletes it.
        var heldCardPath = ProcessInfo.processInfo.environment["IKKOKU_SOURCE_CARD"].map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL)
                .standardizedFileURL.resolvingSymlinksInPath().path
        }
        var stepStart = ProcessInfo.processInfo.systemUptime
        var resourcesBefore: ResourceStore.Statistics?
        var resourceSnapshots: [String: ResourceStore.Statistics] = [:]
        @discardableResult
        func record(_ step: Step, _ ok: Bool, _ detail: String,
                    initialLoad: MakerModel.SourceInitialLoadTiming? = nil,
                    footprint: MakerScenarioFootprint.Sample? = nil) -> Bool {
            var problems: [String] = []
            if let expected = step.rigReuse {
                if let sample = maker.sourceSelectionTiming?.headRigReuse {
                    if sample.hits != expected.hits || sample.misses != expected.misses {
                        problems.append("rigReuse \(sample.hits)/\(sample.misses), expected \(expected.hits)/\(expected.misses)")
                    }
                } else { problems.append("rigReuse: no head selection sample") }
            }
            if let expected = step.initialLoad {
                if let sample = (initialLoad ?? maker.sourceInitialLoadTiming)?.preparation {
                    for (name, actual, wanted) in [("geometry", sample.geometryOutcome.rawValue, expected.geometry),
                                                   ("referenceLoad", sample.referenceLoad.rawValue, expected.referenceLoad),
                                                   ("cachePublication", sample.cachePublication.rawValue, expected.cachePublication)]
                    where wanted != nil && wanted != actual {
                        problems.append("initialLoad \(name) \(actual), expected \(wanted!)")
                    }
                } else { problems.append("initialLoad: no sample") }
            }
            let passed = ok && problems.isEmpty
            let shown = problems.isEmpty ? detail : detail + "; " + problems.joined(separator: "; ")
            results.append(Report.StepResult(op: step.op, ok: passed, detail: shown,
                selectionMilliseconds: step.op == "selectAsset" ? (ProcessInfo.processInfo.systemUptime - stepStart) * 1000 : nil,
                selectionStages: ["selectAsset", "finishSelection"].contains(step.op) ? maker.sourceSelectionTiming : nil,
                initialLoad: initialLoad,
                mainActorMaximumGapMilliseconds: heartbeat?.maximumGapMilliseconds,
                mainActorHeartbeatCount: heartbeat?.count,
                resourcesBefore: resourcesBefore,
                resources: ["selectAsset", "captureResources", "beginSelection", "finishSelection"].contains(step.op) || step.resourcesAtMost != nil || resourcesBefore != nil ? maker.host.renderer.resources.statistics() : nil,
                footprint: footprint))
            return passed
        }
        func insideLocal(_ path: String) -> URL? {
            let fm = FileManager.default
            let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).standardizedFileURL
            let resolved = URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL.resolvingSymlinksInPath()
            let local = cwd.appendingPathComponent(".local").resolvingSymlinksInPath().path
            guard resolved.path == local || resolved.path.hasPrefix(local + "/") else { return nil }
            return resolved
        }
        func floatEqual(_ a: Float, _ b: Float) -> Bool { (a - b).magnitude <= tolerance }
        func colorEqual(_ a: Float4, _ b: [Float]) -> Bool {
            (0..<4).allSatisfy { (a[$0] - b[$0]).magnitude <= colorTolerance }
        }
        /// The color the Maker UI shows: the draft's current rgba for a
        /// supported id (the same list the color sliders bind to).
        func draftColor(_ colorID: String) -> Float4? { maker.sourceAppearanceDraft?.color(colorID) }
        func assertSlot(_ step: Step, face: Bool) -> String? {
            guard let slot = face ? step.face : step.body else { return nil }
            let label = face ? "face" : "body"
            let values = face ? maker.sourceFaceValues : maker.sourceBodyValues
            guard values.indices.contains(slot.index) else {
                return "assert \(label): slot \(slot.index) outside \(values.count) imported values"
            }
            guard floatEqual(values[slot.index], slot.value) else {
                return "assert \(label): slot \(slot.index) is \(values[slot.index]), expected \(slot.value)"
            }
            return nil
        }

        scenarioLoop: for step in scenario.steps {
            stepStart = ProcessInfo.processInfo.systemUptime
            resourcesBefore = nil
            heartbeat = nil
            switch step.op {
            case "customization":
                guard let on = step.on else { record(step, false, "customization: missing on"); continue }
                maker.applySourceCustomization = on
                record(step, true, "applySourceCustomization=\(on) · \(maker.sourceCoordinateCount) coordinates")
            case "selectCoordinate":
                guard let index = step.index else { record(step, false, "selectCoordinate: missing index"); continue }
                do {
                    try maker.selectSourceCoordinate(index)
                    let shown = maker.sourceAppearanceDraft?.coordinate ?? -1
                    record(step, true, "outfit \(index) shown as \(shown) · \(maker.status)")
                } catch { record(step, false, "selectCoordinate: \(error)") }
            case "selectAsset":
                guard let selection = step.selection else { record(step, false, "selectAsset: missing selection"); continue }
                let preview = maker.sourceRigPreview.map(ObjectIdentifier.init)
                let bytes = maker.importedSourceCard?.preservedData
                let face = maker.sourceFaceValues, body = maker.sourceBodyValues
                let coordinate = maker.sourceBoneModifierCoordinate
                let colors = Dictionary(uniqueKeysWithValues: (maker.sourceAppearanceDraft?.colors ?? []).map { ($0.id, $0.rgba) })
                let resources = maker.host.renderer.resources.statistics()
                resourcesBefore = resources
                var failure: Error?
                let pulse = MakerSelectionHeartbeat()
                heartbeat = pulse
                let pulseTask = Task { await pulse.run() }
                let beforeState = selectionState()
                let beforeFrame = maker.host.renderer.currentFrame()
                do { try await selection.apply(to: maker) }
                catch { failure = error }
                pulseTask.cancel(); pulse.sample()
                if (failure != nil) != (step.expectFailure == true) {
                    record(step, false, "selectAsset: \(failure.map(String.init(describing:)) ?? "expected failure but selection succeeded")"); continue
                }
                if step.unchanged == true || step.expectFailure == true {
                    let nextColors = Dictionary(uniqueKeysWithValues: (maker.sourceAppearanceDraft?.colors ?? []).map { ($0.id, $0.rgba) })
                    guard preview == maker.sourceRigPreview.map(ObjectIdentifier.init), bytes == maker.importedSourceCard?.preservedData,
                          face == maker.sourceFaceValues, body == maker.sourceBodyValues, coordinate == maker.sourceBoneModifierCoordinate,
                          colors == nextColors, beforeState == selectionState(),
                          maker.liveAnimation || sameStaticFrame(beforeFrame, maker.host.renderer.currentFrame()) else {
                        record(step, false, "selectAsset: rejected/no-op selection changed the preview or editor state"); continue
                    }
                    if step.unchanged == true {
                        let after = maker.host.renderer.resources.statistics()
                        guard resources.meshes == after.meshes, resources.textures == after.textures,
                              resources.meshBufferBytes == after.meshBufferBytes, resources.deformBuffers == after.deformBuffers else {
                            record(step, false, "selectAsset: no-op changed GPU resource counts"); continue
                        }
                    }
                }
                record(step, true, failure.map { "rejected atomically: \($0)" } ?? "selected \(selection.kind) slot \(selection.slot), source ID \(selection.sourceID)")
            case "beginSelection":
                guard heldSelection == nil, let selection = step.selection else {
                    record(step, false, "beginSelection needs one selection and no held request"); continue
                }
                do {
                    try selection.validate(currentCoordinate: maker.sourceBoneModifierCoordinate)
                    let gate = MakerSelectionGate()
                    let preview = maker.sourceRigPreview.map(ObjectIdentifier.init)
                    let bytes = maker.importedSourceCard?.preservedData
                    let resources = maker.host.renderer.resources.statistics()
                    resourcesBefore = resources
                    let task = Task {
                        defer { gate.finished() }
                        try await selection.apply(to: maker, beforePreparation: { gate.arriveAndWait() })
                    }
                    heldSelection = (task, gate)
                    let arrived = await gate.arrival()
                    let after = maker.host.renderer.resources.statistics()
                    record(step, arrived && maker.sourceSelectionPending != nil && preview == maker.sourceRigPreview.map(ObjectIdentifier.init)
                        && bytes == maker.importedSourceCard?.preservedData && resources.meshes == after.meshes && resources.textures == after.textures,
                        "worker reached=\(arrived), pending=\(maker.sourceSelectionPending != nil), previewSame=\(preview == maker.sourceRigPreview.map(ObjectIdentifier.init)), cardSame=\(bytes == maker.importedSourceCard?.preservedData); meshes \(resources.meshes)→\(after.meshes), textures \(resources.textures)→\(after.textures)")
                } catch { record(step, false, "beginSelection: \(error)") }
            case "finishSelection":
                guard let held = heldSelection else { record(step, false, "finishSelection has no held request"); continue }
                let beforeRelease = selectionState()
                let beforeFrame = maker.host.renderer.currentFrame()
                let beforeClock = maker.sourceAnimationTime
                let beforeResources = maker.host.renderer.resources.statistics()
                resourcesBefore = beforeResources
                held.gate.release()
                let result = await held.task.result
                await maker.waitForSourceSelectionPreparation()
                heldSelection = nil
                switch result {
                case .success:
                    let after = selectionState()
                    record(step, step.expectFailure != true && maker.sourceSelectionPending == nil
                        && beforeRelease.face == after.face && beforeRelease.body == after.body && beforeRelease.colors == after.colors
                        && beforeRelease.coordinate == after.coordinate && beforeRelease.customization == after.customization
                        && beforeRelease.applyBoneModifiers == after.applyBoneModifiers && beforeRelease.boneModifierHash == after.boneModifierHash
                        && beforeRelease.expressions == after.expressions
                        && (maker.liveAnimation ? maker.sourceAnimationTime >= beforeClock : maker.sourceAnimationTime == beforeClock),
                        "held selection committed with latest edits/modes/expressions; clock \(beforeClock)→\(maker.sourceAnimationTime)")
                case .failure(let error):
                    let afterResources = maker.host.renderer.resources.statistics()
                    let expectedError = step.diagnosticContains.map { String(describing: error).contains($0) } ?? (error is CancellationError)
                    let framePreserved = inactiveStudioFrame.map(studioFrameMatches)
                        ?? (maker.liveAnimation || sameStaticFrame(beforeFrame, maker.host.renderer.currentFrame()))
                    record(step, step.expectFailure == true && expectedError && maker.sourceSelectionPending == nil
                        && beforeRelease == selectionState() && beforeResources.meshes == afterResources.meshes
                        && beforeResources.textures == afterResources.textures && beforeResources.deformBuffers == afterResources.deformBuffers && framePreserved,
                        "held selection: \(error); contextSame=\(beforeRelease == selectionState()), pending=\(maker.sourceSelectionPending != nil), inactiveFramePreserved=\(framePreserved); meshes \(beforeResources.meshes)→\(afterResources.meshes), textures \(beforeResources.textures)→\(afterResources.textures), deform \(beforeResources.deformBuffers)→\(afterResources.deformBuffers)")
                }
            case "mode":
                do {
                    switch step.id {
                    case "studio": inactiveStudioFrame = try showEmptyStudio()
                    case "maker": app.mode = .maker; inactiveStudioFrame = nil
                    default: throw RigError.invalid("Mode check needs maker or studio.")
                    }
                    record(step, true, "active mode: \(app.mode.rawValue)")
                } catch { record(step, false, "mode: \(error)") }
            case "queueSelectionThenStudio":
                guard heldSelection == nil, app.mode == .maker, let selection = step.selection else {
                    record(step, false, "queueSelectionThenStudio needs an active Maker and no held request"); continue
                }
                do {
                    let before = selectionState(), resources = maker.host.renderer.resources.statistics()
                    let gate = MakerSelectionGate(); gate.release() // Records entry without holding a faulty implementation.
                    let task = Task {
                        defer { gate.finished() }
                        try await selection.apply(to: maker, beforePreparation: { gate.arriveAndWait() })
                    }
                    inactiveStudioFrame = try showEmptyStudio() // No yield: the queued Task has not entered yet.
                    let result = await task.result
                    await maker.waitForSourceSelectionPreparation()
                    let enteredWorker = await gate.arrival()
                    let after = maker.host.renderer.resources.statistics()
                    let cancelled: Bool
                    if case .failure(let error) = result { cancelled = error is CancellationError } else { cancelled = false }
                    let framePreserved = inactiveStudioFrame.map(studioFrameMatches) == true
                    record(step, cancelled && !enteredWorker && before == selectionState() && maker.sourceSelectionPending == nil
                        && resources.meshes == after.meshes && resources.textures == after.textures
                        && resources.deformBuffers == after.deformBuffers && framePreserved,
                        "queued inactive selection cancelled=\(cancelled), enteredWorker=\(enteredWorker), contextSame=\(before == selectionState()), studioFramePreserved=\(framePreserved)")
                } catch { record(step, false, "queueSelectionThenStudio: \(error)") }
            case "supersedeSelection":
                guard let held = heldSelection, let selection = step.selection else {
                    record(step, false, "supersedeSelection needs a held request and replacement"); continue
                }
                do {
                    let replacement = Task { try await selection.apply(to: maker) }
                    // The old caller must finish while its worker is still held.
                    let old = await held.task.result
                    held.gate.release()
                    try await replacement.value
                    await maker.waitForSourceSelectionPreparation()
                    heldSelection = nil
                    if case .failure(let error) = old, error is CancellationError {
                        record(step, true, "superseded caller cancelled before worker release; replacement completed")
                    } else { record(step, false, "superseded caller did not cancel promptly") }
                } catch { held.gate.release(); heldSelection = nil; record(step, false, "supersedeSelection: \(error)") }
            case "boneModifiers":
                guard let on = step.on else { record(step, false, "boneModifiers needs on"); continue }
                maker.applySourceBoneModifiers = on
                record(step, true, "applySourceBoneModifiers=\(on)")
            case "advanceMotion":
                guard let value = step.value else { record(step, false, "advanceMotion needs seconds"); continue }
                do {
                    try maker.advanceSourceMotion(deltaTime: value)
                    maker.refresh()
                    record(step, true, "source clock=\(maker.sourceAnimationTime)")
                } catch { record(step, false, "advanceMotion: \(error)") }
            case "liveAnimation":
                guard let on = step.on else { record(step, false, "liveAnimation needs on"); continue }
                maker.liveAnimation = on
                record(step, true, "liveAnimation=\(on)")
            case "mouthOpen":
                guard let value = step.value, value.isFinite, (0...1).contains(value), var inputs = maker.sourceExpressionInputs else {
                    record(step, false, "mouthOpen needs expressions and a normalized rate"); continue
                }
                inputs.mouthOpenRate = value
                maker.sourceExpressionInputs = inputs
                record(step, true, "mouthOpenRate=\(value)")
            case "cancelSelection":
                maker.cancelSourceSelection()
                record(step, maker.sourceSelectionPending == nil, "cancelled pending selection")
            case "closeSource":
                maker.closeSourceRig()
                record(step, maker.sourceRigPreview == nil && maker.sourceSelectionPending == nil, "closed source preview")
            case "reloadCard":
                guard let path = heldCardPath else { record(step, false, "reloadCard has no imported path"); continue }
                do {
                    try maker.importSourceCardSettings(url: URL(fileURLWithPath: path), recordInitialLoad: true)
                    record(step, true, "reloaded committed input", initialLoad: maker.sourceInitialLoadTiming)
                }
                catch { record(step, false, "reloadCard: \(error)") }
            case "clearModLibrary":
                do { try maker.setModLibrary(nil); record(step, true, "replaced mod library") }
                catch { record(step, false, "clearModLibrary: \(error)") }
            case "captureResources":
                guard let id = step.id else { record(step, false, "captureResources: missing id"); continue }
                resourceSnapshots[id] = maker.host.renderer.resources.statistics()
                record(step, true, "captured resource counts: \(id)")
            case "setFace", "setBody":
                let face = step.op == "setFace"
                guard let index = step.index, let value = step.value, value.isFinite else {
                    record(step, false, "\(step.op): index/value missing or not finite"); continue
                }
                var values = face ? maker.sourceFaceValues : maker.sourceBodyValues
                guard values.indices.contains(index) else {
                    record(step, false, "\(step.op): slot \(index) outside \(values.count) imported values"); continue
                }
                values[index] = value
                if face { maker.sourceFaceValues = values } else { maker.sourceBodyValues = values }
                record(step, true, "\(face ? "face" : "body") slot \(index)=\(value)")
            case "setColor", "setColorDraft":
                guard let colorID = step.id, let rgba = step.rgba, rgba.count == 4,
                      rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    record(step, false, "setColor: id and rgba [4] in 0...1 are required"); continue
                }
                guard draftColor(colorID) != nil else {
                    record(step, false, "setColor: \"\(colorID)\" is not a supported color field"); continue
                }
                do {
                    maker.setSourceColor(colorID, rgba: Float4(rgba))
                    if step.op == "setColor" { try maker.applySourceAppearance() }
                    guard let shown = draftColor(colorID), colorEqual(shown, rgba) else {
                        record(step, false, "setColor: \"\(colorID)\" did not take the edit: \(maker.status)"); continue
                    }
                    record(step, true, "color \"\(colorID)\"=\(rgba)")
                } catch { record(step, false, "setColor: \(error)") }
            case "resetShapes":
                guard maker.sourceRigPreview != nil else { record(step, false, "resetShapes: no source rig loaded"); continue }
                maker.resetSourceShapes()
                record(step, true, "shapes reset to contract defaults · \(maker.sourceFaceValues.count) face, \(maker.sourceBodyValues.count) body values")
            case "export":
                guard let path = step.path, let url = insideLocal(path) else {
                    record(step, false, "export: path must stay under .local/: \(step.path ?? "<missing>")")
                    break scenarioLoop
                }
                do {
                    // The lane may name a report directory that does not exist
                    // yet; write(to:) needs the parent, so create it (.local/
                    // was proven by insideLocal before we get here).
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Export refuses the imported card's own path to preserve
                    // it; a lane rerun must not fail on its own stale
                    // artifact, so a previous edited copy under .local/ is
                    // cleared first — but never the file the model currently
                    // holds (the Studio scenario's sourceSceneFile rule).
                    if FileManager.default.fileExists(atPath: url.path),
                       url.path != heldCardPath {
                        try FileManager.default.removeItem(at: url)
                    }
                    try maker.exportSourceCard(to: url)
                    record(step, true, "exported edited card to \(path)")
                } catch {
                    record(step, false, "export failed, stopping: \(error)")
                    break scenarioLoop
                }
            case "reimport":
                guard let path = step.path, let url = insideLocal(path) else {
                    record(step, false, "reimport: path must stay under .local/: \(step.path ?? "<missing>")")
                    break scenarioLoop
                }
                let expectsFailure = step.expectFailure == true
                // Fault controls are explicit and static. Ordinary reimports
                // retain their stop-on-error behavior and add no snapshots.
                if expectsFailure && (step.unchanged != true || maker.liveAnimation || step.diagnosticContains?.isEmpty != false) {
                    record(step, false, "expected-failure reimport needs unchanged, static animation and an error substring")
                    break scenarioLoop
                }
                let before = expectsFailure ? selectionState() : nil
                let beforeFrame = expectsFailure ? maker.host.renderer.currentFrame() : nil
                let beforeClock = expectsFailure ? maker.sourceAnimationTime : nil
                let beforeResources = expectsFailure ? maker.host.renderer.resources.statistics() : nil
                let hadInitialSample = maker.sourceInitialLoadTiming != nil
                resourcesBefore = beforeResources
                let sampler = step.footprint == true ? MakerScenarioFootprint() : nil
                defer { _ = sampler?.finish() }
                do {
                    try maker.importSourceCardSettings(url: url, recordInitialLoad: true)
                    let footprint = sampler?.finish()
                    if expectsFailure {
                        record(step, false, "expected-failure reimport unexpectedly succeeded; stopping",
                               initialLoad: maker.sourceInitialLoadTiming)
                        break scenarioLoop
                    }
                    heldCardPath = url.path
                    record(step, true, "reimported \(path): \(maker.status)", initialLoad: maker.sourceInitialLoadTiming,
                           footprint: footprint)
                } catch {
                    guard expectsFailure, let before, let beforeFrame, let beforeClock, let beforeResources else {
                        record(step, false, "reimport failed, stopping: \(error)")
                        break scenarioLoop
                    }
                    let afterResources = maker.host.renderer.resources.statistics()
                    let resourcesSame = beforeResources.meshes == afterResources.meshes
                        && beforeResources.textures == afterResources.textures
                        && beforeResources.deformBuffers == afterResources.deformBuffers
                        && beforeResources.hiddenBuffers == afterResources.hiddenBuffers
                        && beforeResources.meshBufferBytes == afterResources.meshBufferBytes
                        && beforeResources.deformBufferBytes == afterResources.deformBufferBytes
                        && beforeResources.hiddenBufferBytes == afterResources.hiddenBufferBytes
                        && beforeResources.retiring == afterResources.retiring
                    // The identical preview owns immutable shape/expression
                    // contracts; selectionState also checks rig URL/card bytes.
                    let stateSame = before == selectionState()
                    let frameSame = sameStaticFrame(beforeFrame, maker.host.renderer.currentFrame())
                    let clockSame = beforeClock == maker.sourceAnimationTime
                    let sampleCleared = maker.sourceInitialLoadTiming == nil
                    let expectedError = step.diagnosticContains.map { String(describing: error).contains($0) } == true
                    let passed = expectedError && stateSame && frameSame && clockSame && resourcesSame
                        && sampleCleared && maker.sourceSelectionPending == nil
                    record(step, passed,
                        "expected reimport failure: \(error); contextSame=\(stateSame), frameSame=\(frameSame), clockSame=\(clockSame), resourcesSame=\(resourcesSame), priorSample=\(hadInitialSample), sampleCleared=\(sampleCleared)")
                    if !passed { break scenarioLoop }
                }
            case "assert":
                var problems: [String] = []
                if let on = step.on, maker.applySourceCustomization != on { problems.append("assert customization flag changed") }
                if let expected = step.selection {
                    do {
                        if expected.kind == "head" {
                            guard expected.slot == 0, expected.coordinate == nil, let card = maker.importedSourceCard,
                                  let url = maker.sourceRigURL, let preview = maker.sourceRigPreview,
                                  let contract = preview.contract, let expressions = preview.expressionContract else {
                                throw RigError.invalid("Head selection has no complete preview/contracts.")
                            }
                            try SourceMakerLibrary.validateAssemblyIdentity(card: card)
                            let identity = try card.customization()
                            let manifest = try JSONDecoder().decode(SourceAvatarManifest.self, from: Data(contentsOf: url))
                            guard identity.headID == expected.sourceID, maker.sourceHeadID == expected.sourceID,
                                  (manifest.headID ?? 0) == expected.sourceID else {
                                throw RigError.invalid("Head selection card/preview/manifest identities differ.")
                            }
                            let folder = url.deletingLastPathComponent()
                            let expectedContract = try SourceShapeContract.decode(Data(contentsOf: folder.appendingPathComponent("character-shape-contract.json")))
                            let expectedExpressions = try SourceExpressionContract.decode(Data(contentsOf: folder.appendingPathComponent("source-expression-contract.json")))
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                            let targets = expressions.controllers.flatMap { $0.targets.map(\.meshSourceID) }
                            guard try encoder.encode(contract) == encoder.encode(expectedContract),
                                  targets == expectedExpressions.controllers.flatMap({ $0.targets.map(\.meshSourceID) }),
                                  preview.supportsExpressions, preview.supportsFaceCustomization else {
                                throw RigError.invalid("Selected head reused different shape/expression bindings.")
                            }
                        } else {
                            let destination = try expected.destination(currentCoordinate: maker.sourceBoneModifierCoordinate).destination()
                            let row = maker.sourceAssetSelections.first { $0.property == destination.property }
                            if row?.sourceID != expected.sourceID || row?.savedID != expected.sourceID || row?.modGUID != nil || row?.entry == nil {
                                problems.append("assert selection: \(destination.property) did not resolve vanilla ID \(expected.sourceID)")
                            }
                        }
                    } catch { problems.append("assert selection: \(error)") }
                }
                if let id = step.resourcesAtMost {
                    if let previous = resourceSnapshots[id] {
                        let current = maker.host.renderer.resources.statistics()
                        if current.meshes > previous.meshes || current.textures > previous.textures || current.meshBufferBytes > previous.meshBufferBytes
                            || current.deformBuffers > previous.deformBuffers || current.deformBufferBytes > previous.deformBufferBytes {
                            problems.append("assert resources: repeated selection exceeded warmed mesh/texture/deform counts")
                        }
                    } else { problems.append("assert resources: unknown snapshot \(id)") }
                }
                if let expected = step.coordinate {
                    let shown = maker.sourceAppearanceDraft?.coordinate
                    if shown != expected {
                        problems.append("assert coordinate: draft shows \(shown.map(String.init) ?? "none"), expected \(expected)")
                    }
                }
                if let problem = assertSlot(step, face: true) { problems.append(problem) }
                if problems.isEmpty, let problem = assertSlot(step, face: false) { problems.append(problem) }
                if problems.isEmpty, let edit = step.color {
                    if edit.rgba.count != 4 || !edit.rgba.allSatisfy({ $0.isFinite }) {
                        problems.append("assert color: rgba must be four finite components")
                    } else if let value = draftColor(edit.id) {
                        if !colorEqual(value, edit.rgba) {
                            problems.append("assert color: \"\(edit.id)\" is (\(value.x), \(value.y), \(value.z), \(value.w)), expected \(edit.rgba)")
                        }
                    } else {
                        problems.append("assert color: \"\(edit.id)\" is not a supported color field")
                    }
                }
                if problems.isEmpty, let colorID = step.colorApplied,
                   !maker.sourceAppearanceAppliedFields.contains(colorID) {
                    problems.append("assert colorApplied: \"\(colorID)\" is not an applied appearance field")
                }
                if problems.isEmpty, let needle = step.diagnosticContains {
                    let diagnostics = maker.sourceCardDiagnostics + maker.sourceAppearanceDiagnostics
                    if !diagnostics.contains(where: { $0.contains(needle) }) {
                        problems.append("assert diagnosticContains: no diagnostic contains \"\(needle)\"")
                    }
                }
                if problems.isEmpty {
                    record(step, true, "assert passed (\(step.coordinate.map(String.init) ?? "coordinate n/a"))")
                } else {
                    record(step, false, problems.joined(separator: "; "))
                }
            default:
                record(step, false, "unknown op \"\(step.op)\"")
            }
        }
        let passed = results.filter(\.ok).count
        return Report(steps: results, passed: passed, failed: results.count - passed, startupInitialLoad: startupInitialLoad)
    }
}


/// A deterministic scenario barrier on the CPU worker, never the main actor.
/// Both normal arrival and an early validation failure wake the scenario.
nonisolated private final class MakerSelectionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var arrived = false, released = false, complete = false
    private var waiter: CheckedContinuation<Bool, Never>?
    func arriveAndWait() {
        condition.lock()
        arrived = true; waiter?.resume(returning: true); waiter = nil
        while !released { condition.wait() }
        condition.unlock()
    }
    func arrival() async -> Bool {
        await withCheckedContinuation { continuation in
            condition.lock(); defer { condition.unlock() }
            if arrived || complete { continuation.resume(returning: arrived) } else { waiter = continuation }
        }
    }
    func finished() {
        condition.lock(); complete = true; waiter?.resume(returning: arrived); waiter = nil; condition.unlock()
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

/// Scenario-only responsiveness evidence. A presented frame can continue on the
/// render thread even while input is blocked, so sample the actual main actor.
private final class MakerSelectionHeartbeat {
    private var last = ProcessInfo.processInfo.systemUptime
    private(set) var maximumGapMilliseconds = 0.0
    private(set) var count = 0
    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        maximumGapMilliseconds = max(maximumGapMilliseconds, (now - last) * 1000)
        last = now; count += 1
    }
    func run() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
            sample()
        }
    }
}

/// The process footprint around one scenario reimport (#192-C timing):
/// `phys_footprint` before, sampled every millisecond on a thread of its own
/// while the import runs on the main thread, and after it returns, plus the
/// kernel's lifetime peak before and after, which catches a spike shorter
/// than the sampling interval when it sets a new process maximum.
nonisolated final class MakerScenarioFootprint: @unchecked Sendable {
    nonisolated struct Sample: Encodable, Sendable {
        let beforeBytes: UInt64, peakBytes: UInt64, afterBytes: UInt64
        let lifetimePeakBeforeBytes: Int64, lifetimePeakAfterBytes: Int64
        let samples: Int
    }
    private let lock = NSLock()
    private var running = true, peak: UInt64 = 0, count = 0, result: Sample?
    private let before: (UInt64, Int64), done = DispatchSemaphore(value: 0)
    init() {
        before = Self.read()
        peak = before.0
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let now = Self.read().0
                lock.withLock { peak = max(peak, now); count += 1 }
                usleep(1000)
            }
            done.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }
    /// Stops the sampler (once) and returns the sample.
    func finish() -> Sample {
        if let result = lock.withLock({ result }) { return result }
        lock.withLock { running = false }
        done.wait()
        let after = Self.read()
        let sample = lock.withLock {
            Sample(beforeBytes: before.0, peakBytes: max(peak, after.0), afterBytes: after.0,
                   lifetimePeakBeforeBytes: before.1, lifetimePeakAfterBytes: after.1, samples: count)
        }
        lock.withLock { result = sample }
        return sample
    }
    /// `phys_footprint` and `ledger_phys_footprint_peak` (TASK_VM_INFO).
    private static func read() -> (UInt64, Int64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? (info.phys_footprint, info.ledger_phys_footprint_peak) : (0, 0)
    }
}
