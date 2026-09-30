import Foundation
import Character
import CoreMath

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

        struct SlotValue: Decodable { let index: Int; let value: Float }
        struct ColorValue: Decodable { let id: String; let rgba: [Float] }

        private enum CodingKeys: String, CodingKey {
            case op, on, index, value, id, rgba, path, coordinate, face, body, color,
                 colorApplied, diagnosticContains
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
        }
    }

    let steps: [Step]

    struct Report: Encodable {
        struct StepResult: Encodable {
            let op: String
            let ok: Bool
            let detail: String
        }
        let steps: [StepResult]
        let passed: Int
        let failed: Int

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
    /// because every later step depends on the file they were to write.
    static func run(_ scenario: MakerScenario, maker: MakerModel) -> Report {
        var results: [Report.StepResult] = []
        // The file the model currently holds: the `IKKOKU_SOURCE_CARD` import,
        // replaced by each `reimport`. The export guard below never deletes it.
        var heldCardPath = ProcessInfo.processInfo.environment["IKKOKU_SOURCE_CARD"].map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL)
                .standardizedFileURL.resolvingSymlinksInPath().path
        }
        @discardableResult
        func record(_ step: Step, _ ok: Bool, _ detail: String) -> Bool {
            results.append(Report.StepResult(op: step.op, ok: ok, detail: detail))
            return ok
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
            case "setColor":
                guard let colorID = step.id, let rgba = step.rgba, rgba.count == 4,
                      rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    record(step, false, "setColor: id and rgba [4] in 0...1 are required"); continue
                }
                guard draftColor(colorID) != nil else {
                    record(step, false, "setColor: \"\(colorID)\" is not a supported color field"); continue
                }
                do {
                    maker.setSourceColor(colorID, rgba: Float4(rgba))
                    try maker.applySourceAppearance()
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
                do {
                    try maker.importSourceCardSettings(url: url)
                    heldCardPath = url.path
                    record(step, true, "reimported \(path): \(maker.status)")
                } catch {
                    record(step, false, "reimport failed, stopping: \(error)")
                    break scenarioLoop
                }
            case "assert":
                var problems: [String] = []
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
        return Report(steps: results, passed: passed, failed: results.count - passed)
    }
}
