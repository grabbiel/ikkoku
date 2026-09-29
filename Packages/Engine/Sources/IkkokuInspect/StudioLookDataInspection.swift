import Foundation
import simd
import Assets
import Character
import Scene
import Studio

/// Saved look-at data per character for the `look-data` command: card Status
/// look fields, the decoded neck/eyes record payloads, the effective neck
/// pattern, and - when the prefab look settings JSON is supplied - the state
/// name and lookType name the effective patterns resolve to, plus the
/// neckOverride the Studio preview would apply (SourceStudioNeckLookOverride).
/// Data extraction only; no gaze solver, curve evaluation or look capture is
/// executed here.
func inspectStudioLookData(url: URL, settingsURL: URL?) throws -> [String: Any] {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: 256 * 1024 * 1024 + 1) ?? Data()
    let document = try KoikatsuSceneReader.decodeDocument(data)
    let settings = try settingsURL.map { try PrefabLookSettings(url: $0) }

    var characters: [[String: Any]] = []
    var stack = document.snapshot.roots
    while let object = stack.popLast() {
        stack += object.children
        if let record = object.character {
            var entry: [String: Any] = ["sourceKey": object.sourceKey, "name": object.name ?? NSNull(),
                                        "sex": record.sex]
            var diagnostics: [String] = []

            var status: SourceStudioLookStatus?
            do {
                let card = try record.card()
                let saved = try card.block(named: "Status").map {
                    try SourceMessagePack.decode($0.data).stringKeyedMap()
                } ?? [:]
                status = SourceStudioLookStatus(status: saved)
                diagnostics += status!.diagnostics
            } catch {
                diagnostics.append("Embedded card Status could not be decoded: \(error).")
            }
            entry["cardStatus"] = status.map(cardStatusReport) ?? [:]

            var neck: SourceStudioNeckLookData?
            do { neck = try SourceStudioNeckLookData(bytes: record.neckData) }
            catch { diagnostics.append("Saved neck look bytes are invalid: \(error).") }
            entry["neckBytes"] = neck.map(neckReport) ?? [:]

            var eyes: SourceStudioEyeLookData?
            do { eyes = try SourceStudioEyeLookData(bytes: record.eyesData, sceneVersion: document.snapshot.version) }
            catch { diagnostics.append("Saved eye look bytes are invalid: \(error).") }
            entry["eyesBytes"] = eyes.map(eyeReport) ?? [:]

            // Studio's UpdateState order ends with ChangeLookNeckPtn, so the
            // card pattern wins over the saved neck bytes' ptnNo. Without a
            // readable card the saved ptnNo is all that remains.
            let effectiveNeck: Int32?
            if let status, let neck { effectiveNeck = SourceStudioLookData.effectiveNeckPattern(status: status, savedNeckPatternNumber: neck.patternNumber) }
            else { effectiveNeck = status?.neckLookPtn ?? neck?.patternNumber }
            entry["effectiveNeckPattern"] = effectiveNeck.map { Int($0) } ?? NSNull()

            // The override the Studio preview resolves from the same inputs.
            // Settings that exist but fail the preview's strict neck loader are
            // reported instead of guessing a lookType.
            if settings != nil, settings?.neckLookSettings == nil {
                diagnostics.append("Look settings JSON does not satisfy the preview's neck look loader; neckOverride reports no lookType.")
            }
            let neckOverride = SourceStudioNeckLookOverride.resolve(effectivePattern: effectiveNeck,
                settings: settings?.neckLookSettings, savedBoneCount: neck?.fixAngles.count)
            // editedPose skips the override while the saved FK neck group is
            // active (FK owns the neck), so report what the preview renders.
            let fkOwnsNeck = record.enableFK && record.activeFK.count > 1 && record.activeFK[1]
            let applied = fkOwnsNeck ? SourceStudioNeckLookOverride.Applied.none : neckOverride.applied
            let reason = fkOwnsNeck && neckOverride.applied != .none
                ? "FK owns the neck (saved FK neck group active); the preview skips the \(neckOverride.applied.rawValue) override."
                : neckOverride.reason
            entry["neckOverride"] = ["lookType": neckOverride.lookType?.rawValue ?? NSNull(),
                                     "applied": applied.rawValue, "reason": reason]

            // No scene record stores an eye pattern, so the card value is the
            // only saved one and the prefab EyeLookController.ptnNo is the
            // fallback CharaStudio keeps when the card is silent.
            var effectiveEyes = status?.eyesLookPtn
            if effectiveEyes == nil, let preset = settings?.eyeControllerPattern {
                effectiveEyes = preset
            } else if effectiveEyes == nil, settings == nil {
                diagnostics.append("No card eyesLookPtn and no prefab look settings; the eyes pattern is unknown.")
            }
            entry["effectiveEyesPattern"] = effectiveEyes.map { Int($0) } ?? NSNull()

            if let settings {
                entry["neckPatternState"] = settings.neckState(effectiveNeck, label: "neck", diagnostics: &diagnostics)
                entry["eyesPatternState"] = settings.eyeState(effectiveEyes, label: "eyes", diagnostics: &diagnostics)
            }
            entry["diagnostics"] = diagnostics
            characters.append(entry)
            stack += record.accessoryChildren.values.flatMap { $0 }
        }
    }
    characters.sort { ($0["sourceKey"] as? Int32 ?? 0) < ($1["sourceKey"] as? Int32 ?? 0) }
    var report: [String: Any] = ["version": document.snapshot.version,
                                 "scene": url.path, "characterCount": characters.count,
                                 "characters": characters,
                                 "scope": "Saved look-at bytes and card Status fields only; no gaze solving."]
    if let settings {
        report["lookSettings"] = settings.summary
    }
    return report
}

private func values(_ vector: SIMD4<Float>) -> [Float] { [vector.x, vector.y, vector.z, vector.w] }

private func cardStatusReport(_ status: SourceStudioLookStatus) -> [String: Any] {
    ["eyesLookPtn": status.eyesLookPtn.map { Int($0) } ?? NSNull(),
     "neckLookPtn": status.neckLookPtn.map { Int($0) } ?? NSNull(),
     "eyesTargetType": status.eyesTargetType.map { Int($0) } ?? NSNull(),
     "neckTargetType": status.neckTargetType.map { Int($0) } ?? NSNull(),
     "eyesTargetRate": status.eyesTargetRate.map { Double($0) } ?? NSNull(),
     "neckTargetRate": status.neckTargetRate.map { Double($0) } ?? NSNull(),
     "eyesTargetAngle": status.eyesTargetAngle.map { Double($0) } ?? NSNull(),
     "neckTargetAngle": status.neckTargetAngle.map { Double($0) } ?? NSNull(),
     "eyesTargetRange": status.eyesTargetRange.map { Double($0) } ?? NSNull(),
     "neckTargetRange": status.neckTargetRange.map { Double($0) } ?? NSNull()]
}

private func neckReport(_ neck: SourceStudioNeckLookData) -> [String: Any] {
    ["patternNumber": Int(neck.patternNumber), "fixAnglesXYZW": neck.fixAngles.map { values($0.vector) }]
}

private func eyeReport(_ eyes: SourceStudioEyeLookData) -> [String: Any] {
    ["fixAnglesXYZW": eyes.fixAngles.map { values($0.vector) },
     "angleH": eyes.angleH.map { $0.map(Double.init) } ?? NSNull(),
     "angleV": eyes.angleV.map { $0.map(Double.init) } ?? NSNull()]
}

/// The prefab oo_base look settings exported by
/// Tools/reverse/studio_look_settings.py (schema 1). Only the pattern ->
/// state/lookType tables and the EyeLookController default pattern are read.
private struct PrefabLookSettings {
    struct State { let name: String?, lookType: String? }
    let summary: [String: Any]
    let neckStates: [State]
    let eyeStates: [State]
    let eyeControllerPattern: Int32?
    /// The same JSON through the Studio preview's strict loader, so the
    /// neckOverride line is resolved by the preview's own code; nil when the
    /// preview would refuse the file (missing curve, calcLerp, ...).
    let neckLookSettings: SourceStudioNeckLookSettings?

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        neckLookSettings = try? SourceStudioNeckLookSettings(json: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RigError.invalid("Look settings JSON is not a JSON object.")
        }
        func states(_ component: String, _ stateKey: String, _ nameKey: String) throws -> [State] {
            guard let section = root[component] as? [String: Any],
                  let list = section[stateKey] as? [[String: Any]] else {
                throw RigError.invalid("Look settings JSON is missing \(component).\(stateKey).")
            }
            return list.map { state in
                State(name: state[nameKey] as? String,
                      lookType: (state["lookType"] as? [String: Any])?["name"] as? String)
            }
        }
        neckStates = try states("neck", "neckTypeStates", "name")
        eyeStates = try states("eyes", "eyeTypeStates", "comment")
        let controller = root["eyeController"] as? [String: Any]
        eyeControllerPattern = (controller?["ptnNo"] as? Int).flatMap { Int32(exactly: $0) }
        summary = ["path": url.path, "schema": root["schema"] ?? NSNull(),
                   "neckStateCount": neckStates.count, "eyeStateCount": eyeStates.count]
    }

    func neckState(_ pattern: Int32?, label: String, diagnostics: inout [String]) -> [String: Any] {
        state(pattern, from: neckStates, label: label, count: neckStates.count, diagnostics: &diagnostics)
    }

    func eyeState(_ pattern: Int32?, label: String, diagnostics: inout [String]) -> [String: Any] {
        state(pattern, from: eyeStates, label: label, count: eyeStates.count, diagnostics: &diagnostics)
    }

    private func state(_ pattern: Int32?, from states: [State], label: String, count: Int,
                       diagnostics: inout [String]) -> [String: Any] {
        guard let pattern else { return [:] }
        guard (0..<Int32(count)).contains(pattern) else {
            diagnostics.append("Effective \(label) pattern \(pattern) is outside the prefab's \(count) look states.")
            return ["pattern": Int(pattern), "state": NSNull(), "lookType": NSNull()]
        }
        return ["pattern": Int(pattern), "state": states[Int(pattern)].name ?? NSNull(),
                "lookType": states[Int(pattern)].lookType ?? NSNull()]
    }
}
