import Foundation
import AppKit
import CoreMath
import Scene
import Character
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
        /// `"undo"`, `"redo"`, `"newScene"`, `"saveDocument"`, `"loadDocument"`,
        /// `"setFace"`, `"setBody"`, `"setColor"`, `"setAnimation"`,
        /// `"setAnimationSpeed"`, `"setForceLoop"`, `"setFKEnabled"`, `"setFK"`,
        /// `"setPoseMode"`, `"selectBone"`, `"dragGizmo"`,
        /// `"captureBone"`, `"advance"`, `"orbit"`, `"setAutomaticBlink"`,
        /// `"export"`, `"reimport"`, `"assert"`.
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
        /// setAnimation: the clip to select, mirroring the inspector's clip
        /// popup (`StudioModel.setSourceAnimation`, phase resets to zero).
        let group: Int32?
        let category: Int32?
        let no: Int32?
        /// setAnimationSpeed: the inspector speed rate (finite and >= 0).
        let speed: Float?
        /// setForceLoop / setFKEnabled: the flag to set.
        let on: Bool?
        /// setFK / captureBone: the pose-contract catalog bone id whose world
        /// guide the edit or the capture addresses.
        let bone: Int32?
        /// setFK: the replacement local rotation in euler degrees (3 values),
        /// the number the inspector's FK readout shows.
        let rotation: [Float]?
        /// setPoseMode: the mode to select, the lowercase words "object",
        /// "fk" or "ik" (the inspector's mode picker choices).
        let mode: String?
        /// dragGizmo: the rotate-gizmo axis to grab, "x", "y" or "z".
        let axis: String?
        /// dragGizmo: the [dx, dy] pixel offset the mouse drag travels
        /// (viewport pixels, origin top-left like the view's own events).
        let pixels: [Float]?
        /// assert only: the live animation state the preview plays for the
        /// named character (the inspector readback); every field is optional
        /// and only the keys present in the JSON are compared — like the
        /// `activeCamera` fix, an absent key must stay "not asserted".
        let animation: AnimationValue?
        /// assert only: the FK edit on one guide bone, optionally plus its
        /// world displacement from a `captureBone` position.
        let fk: FKValue?
        /// advance: how many seconds of live animation to run. The op walks
        /// `StudioModel.advanceLiveFrame` in its own 1/30 s steps, so the
        /// scenario exercises the app's live tick, not a re-implementation.
        let seconds: Float?
        /// orbit: the mouse-drag deltas handed to `doc.camera.orbit(dx:dy:)`
        /// (yaw -= dx, pitch += dy, radians).
        let dx: Float?
        let dy: Float?
        /// assert only: the eye-gaze readout of a live-pattern character;
        /// every field is optional and only the keys present in the JSON are
        /// compared — like the `activeCamera` fix, an absent key stays
        /// "not asserted".
        let eyeLook: EyeLookValue?
        /// assert only: whether this card's blink control rendered a closing
        /// since the last `advance` reset (`happening`).
        let blink: BlinkValue?
        /// assert only: the saved hand-pattern numbers the character's record
        /// carries for the left and right hand (0 is "no pattern").
        let handPattern: HandPatternValue?

        struct EyeLookValue: Decodable {
            let key: Int32
            /// the look type the effective eyes pattern resolves to.
            let lookType: String?
            /// -1 or 1: the sign both horizontal iris-shift rates (L, R) must
            /// share, so orbiting to the other side of the face can assert the
            /// sign flipped.
            let horizontalSign: Int?
            /// the vertical rate must be strictly above / below this bound.
            let verticalAbove: Double?
            let verticalBelow: Double?
        }
        struct BlinkValue: Decodable {
            let key: Int32
            /// what `didBlink` must read for this card since the last
            /// `advance` reset: true proves a rendered blink, false (with a
            /// prior `advance`) proves the clock stayed open.
            let happening: Bool
        }
        struct HandPatternValue: Decodable {
            let key: Int32
            let left: Int32?
            let right: Int32?
        }

        struct SlotValue: Decodable { let index: Int; let value: Float }
        struct ColorValue: Decodable { let id: String; let rgba: [Float] }
        struct RoutePlayingValue: Decodable { let key: Int32; let playing: Bool }
        struct AnimationValue: Decodable {
            let key: Int32
            let group: Int32?
            let category: Int32?
            let no: Int32?
            let speed: Float?
            let forceLoop: Bool?
        }
        struct FKValue: Decodable {
            let key: Int32
            let bone: Int32
            /// the degrees the document must hold for the bone, if declared.
            let rotation: [Float]?
            /// a `captureBone` label to measure this bone's live world
            /// position against: by default the bone must have visibly moved
            /// (a displacement beyond the numeric tolerance); `within` flips
            /// the check to "the position was reproduced within that bound",
            /// which is how an export/reimport leg proves the edited pose —
            /// not just the edited number — survived the round trip.
            let from: String?
            let within: Float?
            /// assert a mouse or scripted drag actually turned the bone: the
            /// held rotation must have a non-zero component, because a drag's
            /// angle is not known in advance and cannot be matched exactly.
            let nonZero: Bool?
        }
        struct SourceRuntimeValue: Decodable {
            let cameras: Int?
            let items: Int?
            let routes: Int?
            let sceneLight: Bool?
            /// Scene-file re-reads by `rehydrateSourceRuntime()` so far.
            let rehydrations: Int?
        }

        private enum CodingKeys: String, CodingKey {
            case op, key, visible, name, index, value, id, rgba, path, face, body, color,
                 activeCamera, routePlaying, sourceRuntime, diagnosticContains,
                 group, category, no, speed, on, bone, rotation, animation, fk,
                 seconds, dx, dy, eyeLook, blink, handPattern, mode, axis, pixels
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
            // Same rule as `activeCamera`/`sourceRuntime`: absent keys stay
            // `nil` ("not asserted"); a present `animation`/`fk` object only
            // asserts the fields it names.
            group = try c.decodeIfPresent(Int32.self, forKey: .group)
            category = try c.decodeIfPresent(Int32.self, forKey: .category)
            no = try c.decodeIfPresent(Int32.self, forKey: .no)
            speed = try c.decodeIfPresent(Float.self, forKey: .speed)
            on = try c.decodeIfPresent(Bool.self, forKey: .on)
            bone = try c.decodeIfPresent(Int32.self, forKey: .bone)
            rotation = try c.decodeIfPresent([Float].self, forKey: .rotation)
            animation = try c.decodeIfPresent(AnimationValue.self, forKey: .animation)
            fk = try c.decodeIfPresent(FKValue.self, forKey: .fk)
            seconds = try c.decodeIfPresent(Float.self, forKey: .seconds)
            dx = try c.decodeIfPresent(Float.self, forKey: .dx)
            dy = try c.decodeIfPresent(Float.self, forKey: .dy)
            // Same rule as `activeCamera`/`sourceRuntime`: an absent key stays
            // `nil` ("not asserted"); a present check object only asserts the
            // fields it names.
            eyeLook = try c.decodeIfPresent(EyeLookValue.self, forKey: .eyeLook)
            blink = try c.decodeIfPresent(BlinkValue.self, forKey: .blink)
            handPattern = try c.decodeIfPresent(HandPatternValue.self, forKey: .handPattern)
            // setPoseMode / selectBone / dragGizmo parameters: like every
            // optional key above, an absent one stays `nil` and the op that
            // needs it reports the missing field itself.
            mode = try c.decodeIfPresent(String.self, forKey: .mode)
            axis = try c.decodeIfPresent(String.self, forKey: .axis)
            pixels = try c.decodeIfPresent([Float].self, forKey: .pixels)
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
    /// detail and the run continues; a failed `export`/`reimport` or
    /// `saveDocument`/`loadDocument` stops it, because every later step
    /// depends on the file they were to write or to read back.
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
        /// Positions recorded by `captureBone` steps, keyed by step name.
        var capturedBonePositions: [String: Float3] = [:]
        /// The state the inspector shows for a source character: the document
        /// edit when present, the card-saved state otherwise — the same rule
        /// as `StudioModel.selectedSourceAnimationState`, but by source key so
        /// the check does not depend on the current selection.
        func animationState(of id: UUID) -> SourceStudioAnimationState? {
            guard let i = studio.doc.index(of: id), let preview = studio.sourceShapePreview(for: id) else { return nil }
            return studio.doc.objects[i].sourceAnimation ?? SourceStudioAnimationState(record: preview.record)
        }
        func assertAnimation(_ step: Step, id: UUID) -> String? {
            guard let expected = step.animation else { return nil }
            guard let state = animationState(of: id) else {
                return "assert animation: object \(step.key!) has no animation state (no edit, no rendered character preview)"
            }
            if let value = expected.group, state.group != value {
                return "assert animation: group is \(state.group), expected \(value)"
            }
            if let value = expected.category, state.category != value {
                return "assert animation: category is \(state.category), expected \(value)"
            }
            if let value = expected.no, state.no != value {
                return "assert animation: no is \(state.no), expected \(value)"
            }
            if let value = expected.speed, !floatEqual(state.speed, value) {
                return "assert animation: speed is \(state.speed), expected \(value)"
            }
            if let value = expected.forceLoop, state.forceLoop != value {
                return "assert animation: forceLoop is \(state.forceLoop), expected \(value)"
            }
            return nil
        }
        /// The live position of one FK guide bone in the character's rig frame,
        /// evaluated exactly like `StudioModel.sourceCharacterGizmos` before it
        /// applies the object's own world matrix (that composition lives in
        /// `StudioModel`'s private source-world walk and stays there). A
        /// capture→edit→compare of this position shows the guide actually
        /// moved — the object frame is a static similarity through the edit.
        func boneWorld(of id: UUID, bone boneID: Int32) throws -> Float3 {
            guard let i = studio.doc.index(of: id), let preview = studio.sourceShapePreview(for: id) else {
                throw RigError.invalid("Bone capture needs a loaded source character.")
            }
            // Any catalog bone resolves, guide or not: the FK ops keep
            // requiring a guide at their own step, but the eye bones have no
            // guide (the iris shift is a texture offset) and are exactly the
            // bones a camera orbit must NOT move.
            guard let target = preview.controller.targets.first(where: { $0.bone.id == Int(boneID) }) else {
                throw RigError.invalid("Bone \(boneID) is not in this character's pose contract.")
            }
            let object = studio.doc.objects[i]
            let rig = preview.preview.source.rig
            let pose = try preview.editedPose(fkRotations: object.sourceFKRotations ?? [:], faceValues: object.sourceFaceValues, bodyValues: object.sourceBodyValues, ikTargets: object.sourceIKOverrides ?? [:], kinematics: object.sourceKinematics, animationState: object.sourceAnimation, animationElapsed: studio.sourceAnimationTime)
            let evaluated = try rig.evaluate(pose)
            return evaluated.worldMatrices[target.node].translation
        }
        /// FK edits are exported as the document's own degree values, so the
        /// live check compares the numbers the scenario wrote; the world
        /// displacement against a `captureBone` baseline is what shows the
        /// pose (not only the number) actually applies and survives export.
        func assertFK(_ step: Step, id: UUID) -> String? {
            guard let edit = step.fk else { return nil }
            guard let i = studio.doc.index(of: id) else { return "assert fk: object \(step.key!) is not in the document" }
            if let expected = edit.rotation {
                guard expected.count == 3, expected.allSatisfy({ $0.isFinite }) else {
                    return "assert fk: rotation must be three finite degrees"
                }
                guard let held = studio.doc.objects[i].sourceFKRotations?[Int(edit.bone)] else {
                    return "assert fk: object \(edit.key) holds no FK rotation for bone \(edit.bone)"
                }
                guard floatEqual(held.x, expected[0]), floatEqual(held.y, expected[1]), floatEqual(held.z, expected[2]) else {
                    return "assert fk: bone \(edit.bone) is (\(held.x), \(held.y), \(held.z)) degrees, expected \(expected)"
                }
            }
            if edit.nonZero == true {
                // A drag's angle comes out of the ring geometry, not the
                // scenario, so this only demands the rotation actually moved
                // off zero — the number itself is reported by `dragGizmo`.
                guard let held = studio.doc.objects[i].sourceFKRotations?[Int(edit.bone)] else {
                    return "assert fk: object \(edit.key) holds no FK rotation for bone \(edit.bone)"
                }
                guard held.x.magnitude > tolerance || held.y.magnitude > tolerance || held.z.magnitude > tolerance else {
                    return "assert fk: bone \(edit.bone) holds (\(held.x), \(held.y), \(held.z)) degrees — nothing rotated it"
                }
            }
            guard let label = edit.from else { return nil }
            guard let base = capturedBonePositions[label] else {
                return "assert fk: no captureBone position recorded under \"\(label)\""
            }
            let now: Float3
            do { now = try boneWorld(of: id, bone: edit.bone) }
            catch { return "assert fk: bone \(edit.bone) world position unavailable: \(error)" }
            let dx = now.x - base.x, dy = now.y - base.y, dz = now.z - base.z
            let moved = (dx * dx + dy * dy + dz * dz).squareRoot()
            if let bound = edit.within {
                guard moved <= bound else {
                    return "assert fk: bone \(edit.bone) sits \(moved) from its captured position, expected the pose reproduced within \(bound)"
                }
            } else {
                guard moved > tolerance else {
                    return "assert fk: bone \(edit.bone) moved only \(moved) from its captured position — the guide did not move"
                }
            }
            return nil
        }

        /// The rendered preview of the character a key-carrying assert names:
        /// the same live engine object the inspector's readouts use, so the
        /// eye look, blink and hand-pattern asserts read the app's own state.
        func characterPreview(_ key: Int32) -> SourceStudioCharacterPreview? {
            guard let id = studio.doc.objects.first(where: { $0.sourceObjectKey == key })?.id else { return nil }
            return studio.sourceShapePreview(for: id)
        }
        /// The eye-gaze readout: the live look type, the two horizontal iris
        /// shift rates (L, R) and the single vertical rate the calculator
        /// reported on its last stepped frame. Absent keys are not asserted.
        func assertEyeLook(_ step: Step) -> String? {
            guard let check = step.eyeLook else { return nil }
            guard let preview = characterPreview(check.key) else {
                return "assert eyeLook: source key \(check.key) is not a rendered character"
            }
            guard let rates = preview.eyeLookRates else {
                return "assert eyeLook: character \(check.key) has no live eye look\(preview.eyeLookKeptReason.map { " (\($0))" } ?? "")"
            }
            if let expected = check.lookType, rates.lookType.rawValue != expected {
                return "assert eyeLook: look type is \(rates.lookType.rawValue), expected \(expected)"
            }
            if let sign = check.horizontalSign {
                guard sign == -1 || sign == 1 else { return "assert eyeLook: horizontalSign must be -1 or 1" }
                guard rates.horizontal.count == 2, rates.horizontal.allSatisfy({ $0.isFinite }) else {
                    return "assert eyeLook: horizontal rates read \(rates.horizontal)"
                }
                guard rates.horizontal.allSatisfy({ $0 * Double(sign) > 0 }) else {
                    return "assert eyeLook: horizontal rates (\(rates.horizontal[0]), \(rates.horizontal[1])) do not share the \(sign > 0 ? "positive" : "negative") side"
                }
            }
            if let bound = check.verticalAbove, !(rates.vertical > bound) {
                return "assert eyeLook: vertical rate \(rates.vertical) is not above \(bound)"
            }
            if let bound = check.verticalBelow, !(rates.vertical < bound) {
                return "assert eyeLook: vertical rate \(rates.vertical) is not below \(bound)"
            }
            return nil
        }
        /// Whether this card's recovered blink control rendered a closing
        /// since the last `advance` reset. A card with `eyesBlink` off renders
        /// the fixed sentinel and cannot set it at all, which is what the
        /// "the Studio toggle stops it" leg asserts against.
        func assertBlink(_ step: Step) -> String? {
            guard let check = step.blink else { return nil }
            guard let preview = characterPreview(check.key) else {
                return "assert blink: source key \(check.key) is not a rendered character"
            }
            guard preview.didBlink == check.happening else {
                return "assert blink: character \(check.key) \(preview.didBlink ? "rendered a blink closing" : "stayed open") since the last advance, expected happening=\(check.happening)"
            }
            return nil
        }
        /// The hand-pattern numbers the character's record carries for each
        /// hand (the saved `handPatterns` pair the loader replays), asserted
        /// only for the hands the JSON names.
        func assertHandPattern(_ step: Step) -> String? {
            guard let check = step.handPattern else { return nil }
            guard let preview = characterPreview(check.key) else {
                return "assert handPattern: source key \(check.key) is not a rendered character"
            }
            let saved = preview.record.handPatterns
            var problems: [String] = []
            for (hand, expected) in [("left", check.left), ("right", check.right)] {
                if let expected {
                    let index = hand == "left" ? 0 : 1
                    guard saved.indices.contains(index) else {
                        problems.append("\(hand) pattern: the record carries only \(saved)")
                        continue
                    }
                    if saved[index] != expected {
                        problems.append("\(hand) saved pattern is \(saved[index]), expected \(expected)")
                    }
                }
            }
            return problems.isEmpty ? nil : "assert handPattern: character \(check.key) " + problems.joined(separator: "; ")
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
            case "saveDocument":
                // Native save (StudioModel.saveScene), not an original-scene
                // export: the file is a Studio document card. Unlike `export`
                // it overwrites its own earlier artifact on a lane rerun.
                guard let path = step.path, let url = insideLocal(path) else {
                    record(step, false, "saveDocument: path must stay under .local/: \(step.path ?? "<missing>")")
                    break scenarioLoop
                }
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try studio.saveScene(to: url)
                    record(step, true, "saved document to \(path)")
                } catch {
                    record(step, false, "saveDocument failed, stopping: \(error)")
                    break scenarioLoop
                }
            case "loadDocument":
                guard let path = step.path, let url = insideLocal(path) else {
                    record(step, false, "loadDocument: path must stay under .local/: \(step.path ?? "<missing>")")
                    break scenarioLoop
                }
                do {
                    try studio.loadScene(from: url)
                    record(step, true, "loaded document from \(path): \(studio.doc.objects.count) objects")
                } catch {
                    record(step, false, "loadDocument failed, stopping: \(error)")
                    break scenarioLoop
                }
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
            case "setAnimation":
                guard let id = object(step) else { record(step, false, "setAnimation: no object with source key \(step.key ?? -1)"); continue }
                guard let group = step.group, let category = step.category, let no = step.no else {
                    record(step, false, "setAnimation: group/category/no are required"); continue
                }
                do {
                    // A clip outside the loaded animation catalog throws here
                    // before the document changes — selecting a real entry of
                    // the catalog the lane fixture provides is the scenario's job.
                    try studio.setSourceAnimation(id, group: group, category: category, no: no)
                    record(step, true, "source key \(step.key!) animation [\(group), \(category), \(no)]")
                } catch { record(step, false, "setAnimation: \(error)") }
            case "setAnimationSpeed":
                guard let id = object(step) else { record(step, false, "setAnimationSpeed: no object with source key \(step.key ?? -1)"); continue }
                guard let speed = step.speed, speed.isFinite else {
                    record(step, false, "setAnimationSpeed: speed missing or not finite"); continue
                }
                do {
                    try studio.setSourceAnimationSpeed(id, speed)
                    record(step, true, "source key \(step.key!) animation speed \(speed)")
                } catch { record(step, false, "setAnimationSpeed: \(error)") }
            case "setForceLoop":
                guard let id = object(step) else { record(step, false, "setForceLoop: no object with source key \(step.key ?? -1)"); continue }
                guard let on = step.on else { record(step, false, "setForceLoop: on is required"); continue }
                do {
                    try studio.setSourceAnimationForceLoop(id, on)
                    record(step, true, "source key \(step.key!) forceLoop \(on)")
                } catch { record(step, false, "setForceLoop: \(error)") }
            case "setFKEnabled":
                guard let id = object(step) else { record(step, false, "setFKEnabled: no object with source key \(step.key ?? -1)"); continue }
                guard let on = step.on else { record(step, false, "setFKEnabled: on is required"); continue }
                guard studio.sourceShapePreview(for: id) != nil else {
                    record(step, false, "setFKEnabled: object \(step.key!) is not a rendered source character"); continue
                }
                // The inspector toggle acts on the current selection with no
                // id parameter; selecting first mirrors the UI path exactly.
                studio.selection = id
                studio.setSourceFKEnabled(on)
                let enabled = studio.selectedSourceIKState?.enableFK
                if enabled == on {
                    record(step, true, "source key \(step.key!) enableFK \(on)")
                } else {
                    record(step, false, "setFKEnabled: enableFK reads \(String(describing: enabled)), expected \(on)")
                }
            case "setFK":
                guard let id = object(step) else { record(step, false, "setFK: no object with source key \(step.key ?? -1)"); continue }
                guard let boneID = step.bone, let rotation = step.rotation, rotation.count == 3,
                      rotation.allSatisfy({ $0.isFinite }) else {
                    record(step, false, "setFK: bone and rotation [3 finite degrees] are required"); continue
                }
                guard let i = studio.doc.index(of: id), let preview = studio.sourceShapePreview(for: id),
                      preview.controller.targets.contains(where: { $0.bone.id == Int(boneID) && $0.hasGuide }) else {
                    record(step, false, "setFK: bone \(step.bone.map(String.init) ?? "<missing>") has no original guide on source key \(step.key ?? -1)")
                    continue
                }
                // Write through the same `setSourceFKRotation` the bone guide
                // drag calls, then evaluate the resulting pose exactly as the
                // frame builder will; a pose that does not resolve is undone.
                studio.setSourceFKRotation(id, boneID: Int(boneID), degrees: Float3(rotation[0], rotation[1], rotation[2]))
                let edited = studio.doc.objects[i]
                do {
                    _ = try preview.editedPose(fkRotations: edited.sourceFKRotations ?? [:], faceValues: edited.sourceFaceValues,
                        bodyValues: edited.sourceBodyValues, ikTargets: edited.sourceIKOverrides ?? [:],
                        kinematics: edited.sourceKinematics ?? SourceStudioKinematicState(record: preview.record),
                        animationState: edited.sourceAnimation, animationElapsed: studio.sourceAnimationTime)
                    record(step, true, "source key \(step.key!) FK bone \(boneID)=\(rotation) degrees, enableFK \(edited.sourceKinematics?.enableFK == true)")
                } catch { studio.undo(); record(step, false, "setFK: \(error)") }
            case "setPoseMode":
                // The inspector's mode Picker assigns `studio.poseMode`
                // directly; the scenario JSON spells the modes in lowercase
                // and the raw values are capitalized, so the mapping is
                // explicit and an unknown word names the accepted ones.
                guard let mode = step.mode else {
                    record(step, false, "setPoseMode: mode (\"object\", \"fk\" or \"ik\") is required"); continue
                }
                let poseMode: PoseMode
                switch mode {
                case "object": poseMode = .object
                case "fk": poseMode = .fk
                case "ik": poseMode = .ik
                default: record(step, false, "setPoseMode: unknown mode \"\(mode)\", expected \"object\", \"fk\" or \"ik\""); continue
                }
                studio.poseMode = poseMode
                record(step, true, "pose mode \(studio.poseMode.rawValue)")
            case "selectBone":
                guard let id = object(step) else { record(step, false, "selectBone: no object with source key \(step.key ?? -1)"); continue }
                guard let boneID = step.bone else {
                    record(step, false, "selectBone: bone (the pose-contract catalog id) is required"); continue
                }
                guard let preview = studio.sourceShapePreview(for: id),
                      let target = preview.controller.targets.first(where: { $0.bone.id == Int(boneID) }) else {
                    record(step, false, "selectBone: bone \(boneID) is not in source key \(step.key!)'s pose contract"); continue
                }
                // The inspector's bone popup assigns `model.selectedBone`
                // (the rig node index); `selection`'s didSet resets it, so
                // the object is selected first, exactly like the UI order.
                studio.selection = id
                studio.selectedBone = target.node
                if studio.selectedBone == target.node {
                    record(step, true, "source key \(step.key!) selected bone \(boneID) (node \(target.node), guide \(target.hasGuide))")
                } else {
                    record(step, false, "selectBone: selectedBone reads \(String(describing: studio.selectedBone)), expected node \(target.node)")
                }
            case "dragGizmo":
                guard let id = object(step) else { record(step, false, "dragGizmo: no object with source key \(step.key ?? -1)"); continue }
                guard let boneID = step.bone, let axisName = step.axis,
                      let pixels = step.pixels, pixels.count == 2, pixels.allSatisfy({ $0.isFinite }) else {
                    record(step, false, "dragGizmo: bone, axis (\"x\", \"y\" or \"z\") and pixels [dx, dy] are required"); continue
                }
                guard let axis = GizmoAxis(rawValue: ["x": 1, "y": 2, "z": 3][axisName] ?? -1) else {
                    record(step, false, "dragGizmo: unknown axis \"\(axisName)\", expected \"x\", \"y\" or \"z\""); continue
                }
                // The real handlers only reach the guide path through this
                // state, so say so here instead of reporting a bare miss
                // after the pixel scan.
                guard studio.poseMode == .fk else {
                    record(step, false, "dragGizmo: pose mode is \(studio.poseMode.rawValue), run setPoseMode fk first"); continue
                }
                guard studio.selection == id, let node = studio.selectedBone,
                      let preview = studio.sourceShapePreview(for: id),
                      preview.controller.targets.contains(where: { $0.node == node && $0.bone.id == Int(boneID) && $0.hasGuide }) else {
                    record(step, false, "dragGizmo: source key \(step.key!) bone \(step.bone!) is not the selected guide (run selectBone first)"); continue
                }
                guard let anchor = studio.sourceGuidePixel(of: Int(boneID)) else {
                    record(step, false, "dragGizmo: bone \(boneID) does not project into the view camera"); continue
                }
                let wanted = PickIDs.gizmo(axis)
                func picked(_ p: SIMD2<Float>) -> UInt32 { studio.pickID(at: p) }
                // The rotate ring of a selected guide is about 0.9 * 90
                // world-units-per-pixel (~81 px) in radius and only a few px
                // wide, so a ±120 px box around the bone's projected origin
                // covers it: a coarse pass locates the ring, a fine pass
                // around that hit lands squarely on it. The pass records the
                // first pixel of every axis ring — a ring turned nearly
                // edge-on to the camera projects to a sub-pixel sliver no
                // pixel picks, and then the failure has to name which rings
                // the camera does show.
                func scan(_ radius: Float, by: Float, centeredAt center: SIMD2<Float>) -> [GizmoAxis: SIMD2<Float>] {
                    var hits: [GizmoAxis: SIMD2<Float>] = [:]
                    var y = center.y - radius
                    while y <= center.y + radius {
                        var x = center.x - radius
                        while x <= center.x + radius {
                            let p = SIMD2<Float>(x, y)
                            if let hit = PickIDs.axis(from: picked(p)), hit.rawValue <= 3, hits[hit] == nil {
                                hits[hit] = p
                                if hits.count == 3 { return hits }
                            }
                            x += by
                        }
                        y += by
                    }
                    return hits
                }
                let coarse = scan(120, by: 10, centeredAt: anchor)
                let fine = coarse[axis].flatMap { scan(20, by: 4, centeredAt: $0) }
                guard let start = (fine ?? coarse)[axis] else {
                    let axisWord: (GizmoAxis) -> String = { $0 == .x ? "x" : $0 == .y ? "y" : "z" }
                    let seen = [GizmoAxis.x, .y, .z].compactMap { a -> String? in
                        guard let p = coarse[a] else { return nil }
                        return "\(axisWord(a)) ring at (\(p.x), \(p.y))"
                    }
                    record(step, false, "dragGizmo: no pixel within ±120 px of bone \(boneID)'s projection (\(anchor.x), \(anchor.y)) picks axis \(axisName) (id \(wanted)); "
                        + (seen.isEmpty ? "the scan sees no axis ring at all (anchor pixel picks \(picked(anchor)))"
                                        : "the scan sees \(seen.joined(separator: " and ")) but not the \(axisName) ring (edge-on to the camera?)"))
                    continue
                }
                let pickedID = picked(start)
                // One mouseDown, eight interpolated mouseDragged steps to the
                // requested offset, one mouseUp — the view's own coordinator
                // path (left button, no modifiers), nothing re-implemented.
                let noModifiers = NSEvent.ModifierFlags()
                let undoDepth = studio.undoStack.count
                studio.mouseDown(at: start, button: 0, modifiers: noModifiers)
                guard studio.undoStack.count == undoDepth + 1 else {
                    studio.mouseUp(at: start, button: 0, modifiers: noModifiers)
                    record(step, false, "dragGizmo: mouseDown picked the ring but grabbed no guide (picked id \(pickedID))"); continue
                }
                var point = start
                var previous = start
                for i in 1...8 {
                    point = start + SIMD2<Float>(pixels[0], pixels[1]) * (Float(i) / 8)
                    studio.mouseDragged(to: point, delta: point - previous, button: 0, modifiers: noModifiers)
                    previous = point
                }
                studio.mouseUp(at: point, button: 0, modifiers: noModifiers)
                let degrees = studio.doc.object(id)?.sourceFKRotations?[Int(boneID)]
                guard let held = degrees else {
                    record(step, false, "dragGizmo: the drag left no FK rotation on bone \(boneID) — mouseDragged never reached setSourceFKRotation"); continue
                }
                record(step, true, "drag bone \(boneID) axis \(axisName) from pixel (\(start.x), \(start.y)), picked id \(pickedID), over \(pixels) px: FK (\(held.x), \(held.y), \(held.z)) degrees")
            case "captureBone":
                guard let id = object(step) else { record(step, false, "captureBone: no object with source key \(step.key ?? -1)"); continue }
                guard let boneID = step.bone, let label = step.name, !label.isEmpty else {
                    record(step, false, "captureBone: bone and name (the capture label) are required"); continue
                }
                do {
                    let position = try boneWorld(of: id, bone: boneID)
                    capturedBonePositions[label] = position
                    record(step, true, "captured bone \(boneID) at (\(position.x), \(position.y), \(position.z)) as \"\(label)\"")
                } catch { record(step, false, "captureBone: \(error)") }
            case "advance":
                guard let seconds = step.seconds, seconds.isFinite, seconds > 0, seconds <= 3600 else {
                    record(step, false, "advance: seconds must be a finite duration in (0, 3600]"); continue
                }
                // A new blink observation window: a following
                // `blink {happening: true}` then proves a closing rendered
                // during exactly this scripted run, and `happening: false`
                // (after a prior advance) proves the clock stayed open.
                for preview in studio.renderedSourceCharacterPreviews { preview.resetBlinkObservation() }
                // The app's own live step, walked at its own 1/30 s cadence;
                // with `setAutomaticBlink` off the same call skips the blink
                // clocks, exactly like the timer tick.
                var remaining = seconds
                var frames = 0
                while remaining > 0 {
                    let delta = min(1 / 30, remaining)
                    studio.advanceLiveFrame(deltaTime: delta)
                    remaining -= delta
                    frames += 1
                }
                record(step, true, "advanced \(frames) live frames (\(seconds)s); animation clock \(studio.sourceAnimationTime)")
            case "orbit":
                guard let dx = step.dx, let dy = step.dy, dx.isFinite, dy.isFinite else {
                    record(step, false, "orbit: dx and dy (radian drag deltas) are required"); continue
                }
                // The view's drag gesture is refused while a source camera
                // object is looked through; the scenario mirrors that refusal
                // instead of silently orbiting a camera nobody sees through.
                guard studio.activeSourceCamera == nil else {
                    record(step, false, "orbit: camera \"\(studio.activeSourceCameraName ?? "?")\" is looked through; the drag is refused"); continue
                }
                studio.doc.camera.orbit(dx: dx, dy: dy)
                record(step, true, "orbit dx=\(dx) dy=\(dy): yaw \(studio.doc.camera.yaw), pitch \(studio.doc.camera.pitch)")
            case "setAutomaticBlink":
                guard let on = step.on else { record(step, false, "setAutomaticBlink: on is required"); continue }
                // The Studio toggle's own property; its didSet forwards to
                // every rendered character's preview.
                studio.sourceAutomaticBlink = on
                record(step, true, "source automatic blink \(on)")
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
                    if let expected = runtime.rehydrations, studio.sourceRehydrationCount != expected {
                        problems.append("assert sourceRuntime: \(studio.sourceRehydrationCount) scene-file rehydrations, expected \(expected)")
                    }
                }
                // The animation and FK checks resolve their own character by
                // the source key inside the check value, like `routePlaying`.
                if let animation = step.animation {
                    if let animationID = studio.doc.objects.first(where: { $0.sourceObjectKey == animation.key })?.id {
                        if let problem = assertAnimation(step, id: animationID) { problems.append(problem) }
                    } else {
                        problems.append("assert animation: no object with source key \(animation.key)")
                    }
                }
                if let edit = step.fk {
                    if let fkID = studio.doc.objects.first(where: { $0.sourceObjectKey == edit.key })?.id {
                        if let problem = assertFK(step, id: fkID) { problems.append(problem) }
                    } else {
                        problems.append("assert fk: no object with source key \(edit.key)")
                    }
                }
                // The eye look, blink and hand-pattern checks resolve their
                // own character by the source key inside the check value,
                // like `animation`/`fk`.
                if let problem = assertEyeLook(step) { problems.append(problem) }
                if let problem = assertBlink(step) { problems.append(problem) }
                if let problem = assertHandPattern(step) { problems.append(problem) }
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
