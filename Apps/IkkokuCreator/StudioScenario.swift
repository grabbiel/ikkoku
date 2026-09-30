import Foundation
import CoreMath
import Scene
import Studio

/// JSON-driven Studio scenario: a scripted sequence of checklist moves over the
/// imported source scene, run headlessly behind `IKKOKU_STUDIO_SCENARIO` so the
/// `docs/component-audit/README.md` checklist items that are scriptable through
/// `StudioModel`'s own API run in the verification lane instead of by hand.
/// Objects are addressed by SOURCE KEY (`sourceObjectKey`), never by the native
/// UUIDs, so a scenario survives the export/reimport round trip it scripts.
struct StudioScenario: Decodable {
    struct Step: Decodable {
        /// `"select"`, `"setVisible"`, `"rename"`, `"toggleCamera"`, `"toggleRoute"`,
        /// `"undo"`, `"redo"`,
        /// `"setFace"`, `"setBody"`, `"setColor"`, `"export"`, `"reimport"`, `"assert"`.
        let op: String
        let key: Int32?
        let visible: Bool?
        let name: String?
        let index: Int?
        let value: Float?
        let id: String?
        let rgba: [Float]?
        let path: String?
        /// assert only: the face slot and rate the object must show.
        let face: SlotValue?
        /// assert only: the body slot and rate the object must show (the
        /// mirror of `face`, so the body-shape half of ST-T06 is assertable).
        let body: SlotValue?
        /// assert only: the draft color and rgba the object must show.
        let color: ColorValue?
        /// assert only: `.some(nil)` when the JSON says `activeCamera: null`
        /// (the orbit controller owns the view), `.some(.some(key))` when it
        /// names the camera object, `nil` when the check is not declared.
        let activeCamera: Int32??
        /// assert only: the route object's expected play state.
        let routePlaying: RoutePlayingValue?
        /// assert only: the source runtime cache census
        /// (`StudioModel.sourceRuntimeCounts()`); every field is optional and
        /// only the fields present in the JSON are compared — like the
        /// `activeCamera` fix, an absent key must stay "not asserted".
        let sourceRuntime: SourceRuntimeValue?
        /// assert only: a substring one import diagnostic must contain.
        let diagnosticContains: String?

        struct SlotValue: Decodable { let index: Int; let value: Float }
        struct ColorValue: Decodable { let id: String; let rgba: [Float] }
        struct RoutePlayingValue: Decodable { let key: Int32; let playing: Bool }
        struct SourceRuntimeValue: Decodable {
            let cameras: Int?
            let items: Int?
            let routes: Int?
            let sceneLight: Bool?
        }

        private enum CodingKeys: String, CodingKey {
            case op, key, visible, name, index, value, id, rgba, path, face, body, color,
                 activeCamera, routePlaying, sourceRuntime, diagnosticContains
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            op = try c.decode(String.self, forKey: .op)
            key = try c.decodeIfPresent(Int32.self, forKey: .key)
            visible = try c.decodeIfPresent(Bool.self, forKey: .visible)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            index = try c.decodeIfPresent(Int.self, forKey: .index)
            value = try c.decodeIfPresent(Float.self, forKey: .value)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            rgba = try c.decodeIfPresent([Float].self, forKey: .rgba)
            path = try c.decodeIfPresent(String.self, forKey: .path)
            face = try c.decodeIfPresent(SlotValue.self, forKey: .face)
            body = try c.decodeIfPresent(SlotValue.self, forKey: .body)
            color = try c.decodeIfPresent(ColorValue.self, forKey: .color)
            routePlaying = try c.decodeIfPresent(RoutePlayingValue.self, forKey: .routePlaying)
            // Same rule as `activeCamera`: an absent `sourceRuntime` key must
            // stay `nil` ("not asserted"); every field of the struct is
            // optional, so a present object only asserts the keys it names.
            sourceRuntime = try c.decodeIfPresent(SourceRuntimeValue.self, forKey: .sourceRuntime)
            diagnosticContains = try c.decodeIfPresent(String.self, forKey: .diagnosticContains)
            // `decodeIfPresent` reads both `null` and an absent key as `nil`;
            // `contains` distinguishes "assert the orbit view" from "no
            // camera check declared", so the camera check is decoded by hand.
            // The explicit `if` is required: the equivalent ternary infers as
            // `Int32?`, which assigns `.some(nil)` into the `Int32??` even for
            // an absent key, and then every bare assert on a scene with an
            // active camera fails its phantom "expected none" camera check.
            if c.contains(.activeCamera) {
                activeCamera = try c.decodeIfPresent(Int32.self, forKey: .activeCamera)
            } else {
                activeCamera = nil
            }
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

    /// Numeric compares (shape rates, color components) match within this bound.
    static let tolerance: Float = 1e-5

    /// Runs the steps against the imported scene. A failing step records its
    /// detail and the run continues; a failed `export`/`reimport` stops it,
    /// because every later step depends on the file they were to write.
    static func run(_ scenario: StudioScenario, studio: StudioModel) -> Report {
        var results: [Report.StepResult] = []
        @discardableResult
        func record(_ step: Step, _ ok: Bool, _ detail: String) -> Bool {
            results.append(Report.StepResult(op: step.op, ok: ok, detail: detail))
            return ok
        }
        func object(_ step: Step) -> UUID? {
            guard let key = step.key else { return nil }
            return studio.doc.objects.first { $0.sourceObjectKey == key }?.id
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
        /// The rate the inspector shows for one slot: the document edit when
        /// present, the rendered character's card-saved array otherwise (the
        /// same rule as `StudioView.sourceShapeBinding`).
        func shapeValues(of id: UUID, face: Bool) -> [Float]? {
            guard let i = studio.doc.index(of: id) else { return nil }
            if let edited = face ? studio.doc.objects[i].sourceFaceValues : studio.doc.objects[i].sourceBodyValues {
                return edited
            }
            guard let preview = studio.sourceShapePreview(for: id) else { return nil }
            return face ? preview.savedFaceValues : preview.savedBodyValues
        }
        /// The color the inspector shows: the document edit, otherwise the
        /// card's saved color (the rule of `StudioView.sourceColorBinding`).
        func effectiveColor(of id: UUID, colorID: String) -> Float4? {
            guard let i = studio.doc.index(of: id) else { return nil }
            if let edited = studio.doc.objects[i].sourceColorEdits?[colorID] { return edited }
            return studio.sourceShapePreview(for: id)?.savedColors[colorID]
        }
        func assertShape(_ step: Step, id: UUID, face: Bool) -> String? {
            guard let slot = face ? step.face : step.body else { return nil }
            let label = face ? "face" : "body"
            guard let values = shapeValues(of: id, face: face) else {
                return "assert \(label): object \(step.key!) has no shape values (no edit, no rendered character preview)"
            }
            guard values.indices.contains(slot.index) else {
                return "assert \(label): slot \(slot.index) outside \(values.count) saved/edited values"
            }
            guard floatEqual(values[slot.index], slot.value) else {
                return "assert \(label): slot \(slot.index) is \(values[slot.index]), expected \(slot.value)"
            }
            return nil
        }
        func assertColor(_ step: Step, id: UUID) -> String? {
            guard let edit = step.color else { return nil }
            guard edit.rgba.count == 4, edit.rgba.allSatisfy({ $0.isFinite }) else {
                return "assert color: rgba must be four finite components"
            }
            guard let value = effectiveColor(of: id, colorID: edit.id) else {
                return "assert color: \"\(edit.id)\" has no edit and is not a saved card color"
            }
            let expected = Float4(edit.rgba)
            guard floatEqual(value.x, expected.x), floatEqual(value.y, expected.y),
                  floatEqual(value.z, expected.z), floatEqual(value.w, expected.w) else {
                return "assert color: \"\(edit.id)\" is (\(value.x), \(value.y), \(value.z), \(value.w)), expected \(edit.rgba)"
            }
            return nil
        }

        scenarioLoop: for step in scenario.steps {
            // Steps run microseconds apart, inside the editor's 0.4 s
            // edit-coalescing window (startup's import opens it too), so an
            // edit could silently share the previous snapshot and `undo` would
            // restore the wrong document. Every step is its own gesture.
            studio.endUndoCoalescing()
            switch step.op {
            case "select":
                guard let id = object(step) else { record(step, false, "select: no object with source key \(step.key ?? -1)"); continue }
                studio.selection = id
                record(step, true, "selected source key \(step.key!)")
            case "setVisible":
                guard let id = object(step) else { record(step, false, "setVisible: no object with source key \(step.key ?? -1)"); continue }
                guard let visible = step.visible else { record(step, false, "setVisible: missing visible"); continue }
                studio.update(id) { $0.visible = visible }
                record(step, true, "source key \(step.key!) visible=\(visible)")
            case "rename":
                guard let id = object(step) else { record(step, false, "rename: no object with source key \(step.key ?? -1)"); continue }
                guard let name = step.name, !name.isEmpty else { record(step, false, "rename: missing name"); continue }
                studio.update(id) { $0.name = name }
                record(step, true, "source key \(step.key!) renamed to \"\(name)\"")
            case "toggleCamera":
                guard let id = object(step) else { record(step, false, "toggleCamera: no object with source key \(step.key ?? -1)"); continue }
                studio.toggleSourceCamera(id)
                record(step, true, studio.status)
            case "toggleRoute":
                guard let id = object(step) else { record(step, false, "toggleRoute: no object with source key \(step.key ?? -1)"); continue }
                studio.toggleSourceRoute(id)
                record(step, true, studio.status)
            case "undo":
                guard !studio.undoStack.isEmpty else { record(step, false, "undo: undo stack is empty"); continue }
                studio.undo()
                record(step, true, studio.status)
            case "redo":
                guard !studio.redoStack.isEmpty else { record(step, false, "redo: redo stack is empty"); continue }
                studio.redo()
                record(step, true, studio.status)
            case "newScene":
                studio.newScene()
                record(step, true, studio.status)
            case "setFace", "setBody":
                let face = step.op == "setFace"
                guard let id = object(step) else { record(step, false, "\(step.op): no object with source key \(step.key ?? -1)"); continue }
                guard let index = step.index, let value = step.value, value.isFinite else {
                    record(step, false, "\(step.op): index/value missing or not finite"); continue
                }
                guard var values = shapeValues(of: id, face: face) else {
                    record(step, false, "\(step.op): object \(step.key!) has no shape values (not a rendered source character)"); continue
                }
                guard values.indices.contains(index) else {
                    record(step, false, "\(step.op): slot \(index) outside \(values.count) saved/edited values"); continue
                }
                values[index] = value
                do {
                    if face {
                        try studio.setSourceShapeValues(id, face: values, body: studio.doc.object(id)?.sourceBodyValues)
                    } else {
                        try studio.setSourceShapeValues(id, face: studio.doc.object(id)?.sourceFaceValues, body: values)
                    }
                    record(step, true, "source key \(step.key!) \(face ? "face" : "body") slot \(index)=\(value)")
                } catch { record(step, false, "\(step.op): \(error)") }
            case "setColor":
                guard let id = object(step) else { record(step, false, "setColor: no object with source key \(step.key ?? -1)"); continue }
                guard let colorID = step.id, let rgba = step.rgba, rgba.count == 4,
                      rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    record(step, false, "setColor: id and rgba [4] in 0...1 are required"); continue
                }
                do {
                    try studio.setSourceColorEdit(id, colorID: colorID, rgba: Float4(rgba))
                    record(step, true, "source key \(step.key!) color \"\(colorID)\"=\(rgba)")
                } catch { record(step, false, "setColor: \(error)") }
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
                    // Export refuses an existing filename to protect the source
                    // scene; a lane rerun must not fail on its own stale
                    // artifact, so a previous report output under .local/ is
                    // cleared first — never the imported scene itself.
                    if FileManager.default.fileExists(atPath: url.path),
                       url.path != studio.doc.sourceSceneFile.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try studio.exportSourceScene(to: url)
                    record(step, true, "exported edited original scene to \(path)")
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
                    // The same inputs the `IKKOKU_SOURCE_SCENE` startup import
                    // used (see AppState.importSourceScenePreview(url:)).
                    guard let rig = try EngineHost.locateSourceAvatar() else {
                        throw RigError.invalid("Export the original clothed avatar before previewing source scenes.")
                    }
                    let catalog = rig.deletingLastPathComponent()
                        .appendingPathComponent("../studio-pose/contract.json").standardizedFileURL
                    try studio.importSourceScenePreview(sceneURL: url, rigURL: rig, boneCatalogURL: catalog)
                    record(step, true, "reimported \(path): \(studio.doc.objects.count) objects")
                } catch {
                    record(step, false, "reimport failed, stopping: \(error)")
                    break scenarioLoop
                }
            case "assert":
                var problems: [String] = []
                let needsObject = step.name != nil || step.visible != nil || step.face != nil || step.body != nil || step.color != nil
                var id: UUID?
                if needsObject, step.key == nil {
                    problems.append("assert: name/visible/face/color need a key")
                } else if needsObject {
                    if let found = object(step) {
                        id = found
                    } else {
                        problems.append("assert: no object with source key \(step.key!)")
                    }
                }
                if let id {
                    if let expected = step.visible, studio.doc.object(id)?.visible != expected {
                        problems.append("assert visible: source key \(step.key!) is \(studio.doc.object(id)!.visible), expected \(expected)")
                    }
                    if let expected = step.name, studio.doc.object(id)?.name != expected {
                        problems.append("assert name: source key \(step.key!) is \"\(studio.doc.object(id)!.name)\", expected \"\(expected)\"")
                    }
                    if problems.isEmpty, let problem = assertShape(step, id: id, face: true) { problems.append(problem) }
                    if problems.isEmpty, let problem = assertShape(step, id: id, face: false) { problems.append(problem) }
                    if problems.isEmpty, let problem = assertColor(step, id: id) { problems.append(problem) }
                }
                if let expectedKey = step.activeCamera {
                    let active = studio.activeSourceCamera.flatMap { studio.doc.object($0)?.sourceObjectKey }
                    if active != expectedKey {
                        problems.append("assert activeCamera: active is \(active.map(String.init) ?? "none"), expected \(expectedKey.map(String.init) ?? "none")")
                    }
                }
                if let route = step.routePlaying {
                    if let routeID = studio.doc.objects.first(where: { $0.sourceObjectKey == route.key })?.id {
                        // The play state the inspector reports for a route is
                        // per-selection; selecting it mirrors the UI path.
                        studio.selection = routeID
                        let playing = studio.selectedRoutePlaying
                        if playing != route.playing {
                            problems.append("assert routePlaying: route \(route.key) is \(playing), expected \(route.playing)")
                        }
                    } else {
                        problems.append("assert routePlaying: no route with source key \(route.key)")
                    }
                }
                if let runtime = step.sourceRuntime {
                    let counts = studio.sourceRuntimeCounts()
                    if let expected = runtime.cameras, counts.cameras != expected {
                        problems.append("assert sourceRuntime: cameras cache has \(counts.cameras) live entries, expected \(expected)")
                    }
                    if let expected = runtime.items, counts.items != expected {
                        problems.append("assert sourceRuntime: items cache has \(counts.items) live entries, expected \(expected)")
                    }
                    if let expected = runtime.routes, counts.routes != expected {
                        problems.append("assert sourceRuntime: routes cache has \(counts.routes) live entries, expected \(expected)")
                    }
                    if let expected = runtime.sceneLight, counts.sceneLight != expected {
                        problems.append("assert sourceRuntime: scene light applies=\(counts.sceneLight), expected \(expected)")
                    }
                }
                if let needle = step.diagnosticContains {
                    let diagnostics = studio.doc.sourcePreviewDiagnostics ?? []
                    if !diagnostics.contains(where: { $0.contains(needle) }) {
                        problems.append("assert diagnosticContains: no diagnostic contains \"\(needle)\"")
                    }
                }
                if problems.isEmpty {
                    record(step, true, "assert passed for source key \(step.key.map(String.init) ?? "n/a")")
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
