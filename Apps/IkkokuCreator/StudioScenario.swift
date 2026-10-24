import Foundation
import AppKit
import simd
import CoreMath
import CryptoKit
import Scene
import Renderer
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
        /// `"setFace"`, `"setBody"`, `"setColor"`, `"resetShape"`, `"resetColors"`, `"setOutfit"`,
        /// `"setClothesState"`, `"setAccessoryVisible"`, `"setExpression"`, `"resetExpression"`,
        /// `"setAnimation"`, `"setAnimationSpeed"`, `"setForceLoop"`, `"setFKEnabled"`,
        /// `"setFK"`, `"setPoseMode"`, `"selectBone"`, `"dragGizmo"`,
        /// `"captureBone"`, `"captureObject"`, `"captureRender"`, `"advance"`, `"orbit"`,
        /// `"setAutomaticBlink"`, `"addCharacter"`, `"setIKEnabled"`, `"setIKTarget"`,
        /// `"captureIKPose"`, `"export"`, `"reimport"`, `"assert"`, `"assertRejected"`.
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
        /// resetShape: the domain to reset — the same `face` key that asserts
        /// carry as a `{index, value}` slot, spelled `true`/`false` only for
        /// this operation.
        let faceReset: Bool?
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
        /// assert only: a substring the app's status line (`StudioModel.status`)
        /// must contain, read after any `view` check in the same step, so a
        /// look-through rejection the render camera reported is visible.
        let statusContains: String?
        /// assert only: a substring the view indicator under the status line
        /// (`StudioModel.activeSourceCameraView`) must contain; with no source
        /// camera active the indicator is empty and contains nothing.
        let indicatorContains: String?
        /// assert only, with `key`: the object's workspace tree label
        /// (`StudioModel.workspaceLabel`, which the tree rows display).
        let treeLabel: String?
        /// assert only: the camera the preview renders from
        /// (`StudioModel.viewCamera`, the camera `refresh()` hands the
        /// renderer): the saved scene camera, or the look-through camera of
        /// the source camera object with this key.
        let view: ViewValue?
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
        /// assert only: one object's world displacement from a `captureObject`
        /// position (the placement `refresh()` renders it at, so a route
        /// child's position follows its route's `childRoot`).
        let position: PositionValue?
        /// advance: how many seconds of live animation to run. The op walks
        /// `StudioModel.advanceLiveFrame` in its own 1/30 s steps, so the
        /// scenario exercises the app's live tick, not a re-implementation.
        let seconds: Float?
        /// orbit: the mouse-drag deltas handed to `StudioModel.orbitCamera(dx:dy:)`,
        /// the method the viewport's orbit drag calls
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
        /// assert only: the current render compared with a `captureRender`
        /// capture, resolved by the `from` label like `animation`/`fk`; at
        /// least one of the two bounds must be named to assert anything.
        let render: RenderValue?
        /// assert only: the sha256 of this exported `.local/` file must equal
        /// the source identity captured at scenario start, the
        /// byte-identity check for edits made back to the card's saved values.
        let exportIdenticalToSource: String?
        /// assertRejected only: exactly one assertion must fail with this
        /// diagnostic fragment, so negative controls cannot pass on unrelated failures.
        /// setOutfit: the selection must be refused with this fragment and
        /// leave the document's outfit and the rendered preview unchanged.
        let errorContains: String?
        /// assert only: the outfit the named character's live preview
        /// assembled, read from the rendered preview (not the document).
        let outfit: OutfitValue?
        /// setClothesState: the clothes state 0...3 (on, half, half 2, off)
        /// for the CharaStudio row in `index` (0 top ... 7 shoes).
        let state: Int?
        /// assert only: the named character's live wear readback (rendered
        /// preview and document); only the fields present are compared.
        let clothes: ClothesValue?
        /// setExpression and assert share a partial face-state object.
        let expression: ExpressionValue?

        struct ExpressionValue: Decodable {
            let eyebrowPattern, eyesPattern, mouthPattern: Int?
            let eyesOpen, mouthOpen: Float?
            let blink, lipSync: Bool?
            let eyesLookPattern, neckLookPattern, tears: Int?
            let cheek, heldEyesOpenRate: Float?
            let edited, followsGuide: Bool?
            let diagnosticContains: String?

            func applying(to state: SourceStudioExpressionState) -> SourceStudioExpressionState {
                var next = state
                if let eyebrowPattern { next.eyebrowPattern = eyebrowPattern }
                if let eyesPattern { next.eyesPattern = eyesPattern }
                if let mouthPattern { next.mouthPattern = mouthPattern }
                if let eyesOpen { next.eyesOpen = eyesOpen }
                if let mouthOpen { next.mouthOpen = mouthOpen }
                if let blink { next.blink = blink }
                if let lipSync { next.lipSync = lipSync }
                if let eyesLookPattern { next.eyesLookPattern = eyesLookPattern }
                if let neckLookPattern { next.neckLookPattern = neckLookPattern }
                if let tears { next.tears = tears }
                if let cheek { next.cheek = cheek }
                if let heldEyesOpenRate { next.heldEyesOpenRate = heldEyesOpenRate }
                return next
            }
        }
        /// addCharacter: the Add ▸ Character choice, `"female"` or `"male"`.
        let sex: String?
        /// setIKEnabled / setIKTarget / captureIKPose: the NATIVE character's
        /// object name. A character the scenario added has no source key; a
        /// name that is not exactly one native character fails the step.
        let character: String?
        /// setIKEnabled / setIKTarget / captureIKPose: the `IKChain` raw value
        /// ("hand_L", "hand_R", "foot_L", "foot_R").
        let chain: String?
        /// setIKTarget: one click of the Target row's Stepper on `axis`
        /// (`advanced(by:)`; the row's step is 0.02). `value` instead types
        /// the component into the row's text field.
        let delta: Float?
        /// assert only: one native IK chain, read from the rendered character.
        let ik: IKValue?

        struct IKValue: Decodable {
            let character: String
            let chain: String
            /// the document target's enabled flag (the Pose tab's toggle).
            let enabled: Bool?
            /// the document target the Target row shows (root space); a null
            /// component is not asserted. Compared within `tolerance`.
            let target: [Float?]?
            /// whether the frame builder's check (`CharacterInstance.ikFailures()`)
            /// solves the chain: false is the "IK left unsolved" case.
            let solved: Bool?
            /// the chain end's root-space distance to the document target must
            /// be at most this many metres.
            let reachesTarget: Float?
            /// a `captureIKPose` label. By default the chain must have moved
            /// beyond `tolerance`; with `within`, both the largest quaternion
            /// component difference of the three chain bones and the largest
            /// joint displacement (metres) must be at most `within`.
            let from: String?
            let within: Float?
        }

        struct ClothesValue: Decodable {
            let key: Int32
            /// the nine clothes-state bytes the rendered preview holds.
            let state: [Int]?
            /// the embedded card's saved Status.clothesState as imported.
            let saved: [Int]?
            /// exactly the clothing kinds with at least one drawn renderer.
            let rendered: [Int]?
            /// exactly the accessory slots with at least one drawn renderer.
            let accessories: [Int]?
            /// exactly the slots whose rendered showAccessory flag is off.
            let accessoriesOff: [Int]?
            /// whether the document holds a wear edit (sourceClothesState or
            /// sourceShowAccessory non-nil); false proves a return to saved.
            let edited: Bool?
            /// exact number of fallback lines (states drawn dressed instead).
            let fallbacks: Int?
            /// a substring one of the preview's wear diagnostics (current
            /// fallbacks) or import diagnostics must contain.
            let diagnosticContains: String?
        }

        struct OutfitValue: Decodable {
            let key: Int32
            /// the outfit index the rendered preview assembled.
            let coordinate: Int?
            /// the embedded card's saved Status.coordinateType as imported.
            let saved: Int?
            /// a selection property (e.g. `outfit3.ChaFileClothes.ClothesTop`)
            /// the preview must have resolved to a library entry: converted
            /// geometry, or the library's explicit empty ("none") entry.
            let resolved: String?
            /// a selection property the preview must report as
            /// `conversionMissing`, with an import diagnostic naming it.
            let missing: String?
        }

        struct RenderValue: Decodable {
            /// the `captureRender` label whose pixels are the baseline.
            let from: String
            /// the render changed at least this many pixels against the capture
            /// (a pixel counts as changed when one of R, G, B or A moves by
            /// more than 2/255 — noise below that stays invisible).
            let changedPixelsAtLeast: Int?
            /// the render changed at most this many pixels against the capture
            /// (0 allows no pixel to exceed the 2/255 channel tolerance).
            let changedPixelsAtMost: Int?
            /// Optional stricter bound on the largest channel difference;
            /// zero requires exact restoration of every rendered RGBA8 byte.
            let maxChannelDeltaAtMost: Int?
        }

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
        struct ViewValue: Decodable {
            /// true: the view must be exactly the saved camera `doc.camera`.
            let saved: Bool?
            /// the source camera object the view must look through: its
            /// world position and forward, read through the same placement
            /// walk `refresh()` uses, and not the saved camera.
            let key: Int32?
        }
        struct PositionValue: Decodable {
            let key: Int32
            /// the `captureObject` label to measure against: by default the
            /// object must have moved beyond the numeric tolerance; `within`
            /// flips the check to "it is still within that bound", like `fk`.
            let from: String
            let within: Float?
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
                 activeCamera, routePlaying, sourceRuntime, diagnosticContains, statusContains, indicatorContains, treeLabel, view,
                 group, category, no, speed, on, bone, rotation, animation, fk, position,
                 seconds, dx, dy, eyeLook, blink, handPattern, mode, axis, pixels,
                 render, exportIdenticalToSource, errorContains, outfit, state, clothes, expression,
                 sex, character, chain, delta, ik
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
            // A boolean is valid only for resetShape. A malformed assertion
            // such as face:true must fail decoding rather than assert nothing.
            if op == "resetShape" {
                faceReset = try c.decodeIfPresent(Bool.self, forKey: .face)
                face = nil
            } else {
                faceReset = nil
                face = try c.decodeIfPresent(SlotValue.self, forKey: .face)
            }
            body = try c.decodeIfPresent(SlotValue.self, forKey: .body)
            color = try c.decodeIfPresent(ColorValue.self, forKey: .color)
            routePlaying = try c.decodeIfPresent(RoutePlayingValue.self, forKey: .routePlaying)
            // Same rule as `activeCamera`: an absent `sourceRuntime` key must
            // stay `nil` ("not asserted"); every field of the struct is
            // optional, so a present object only asserts the keys it names.
            sourceRuntime = try c.decodeIfPresent(SourceRuntimeValue.self, forKey: .sourceRuntime)
            diagnosticContains = try c.decodeIfPresent(String.self, forKey: .diagnosticContains)
            statusContains = try c.decodeIfPresent(String.self, forKey: .statusContains)
            indicatorContains = try c.decodeIfPresent(String.self, forKey: .indicatorContains)
            treeLabel = try c.decodeIfPresent(String.self, forKey: .treeLabel)
            view = try c.decodeIfPresent(ViewValue.self, forKey: .view)
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
            position = try c.decodeIfPresent(PositionValue.self, forKey: .position)
            seconds = try c.decodeIfPresent(Float.self, forKey: .seconds)
            dx = try c.decodeIfPresent(Float.self, forKey: .dx)
            dy = try c.decodeIfPresent(Float.self, forKey: .dy)
            // Same rule as `activeCamera`/`sourceRuntime`: an absent key stays
            // `nil` ("not asserted"); a present check object only asserts the
            // fields it names.
            eyeLook = try c.decodeIfPresent(EyeLookValue.self, forKey: .eyeLook)
            blink = try c.decodeIfPresent(BlinkValue.self, forKey: .blink)
            handPattern = try c.decodeIfPresent(HandPatternValue.self, forKey: .handPattern)
            // Same rule as `animation`/`fk`: an absent key stays `nil`
            // ("not asserted"); a present `render` object only asserts the
            // bounds it names, and `exportIdenticalToSource` is a bare path.
            render = try c.decodeIfPresent(RenderValue.self, forKey: .render)
            exportIdenticalToSource = try c.decodeIfPresent(String.self, forKey: .exportIdenticalToSource)
            errorContains = try c.decodeIfPresent(String.self, forKey: .errorContains)
            outfit = try c.decodeIfPresent(OutfitValue.self, forKey: .outfit)
            state = try c.decodeIfPresent(Int.self, forKey: .state)
            clothes = try c.decodeIfPresent(ClothesValue.self, forKey: .clothes)
            expression = try c.decodeIfPresent(ExpressionValue.self, forKey: .expression)
            // Native IK parameters: absent keys stay `nil` like every optional
            // above, and the op that needs one reports it missing.
            sex = try c.decodeIfPresent(String.self, forKey: .sex)
            character = try c.decodeIfPresent(String.self, forKey: .character)
            chain = try c.decodeIfPresent(String.self, forKey: .chain)
            delta = try c.decodeIfPresent(Float.self, forKey: .delta)
            ik = try c.decodeIfPresent(IKValue.self, forKey: .ik)
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

    /// One native IK chain as rendered: the local rotations of its upper,
    /// lower and end bones and their root-space joint positions.
    struct IKPoseCapture {
        let rotations: [simd_quatf]
        let joints: [Float3]
    }

    /// Numeric compares (shape rates, color components) match within this bound.
    static let tolerance: Float = 1e-5

    /// Runs the steps against the imported scene. A failing step records its
    /// detail and the run continues; a failed `export`/`reimport` or
    /// `saveDocument`/`loadDocument` stops it, because every later step
    /// depends on the file they were to write or to read back.
    static func run(_ scenario: StudioScenario, studio: StudioModel) -> Report {
        var results: [Report.StepResult] = []
        // Freeze the imported source identity before any export/reimport step.
        // Comparing against doc.sourceSceneFile later can compare an export
        // with itself after reimport and falsely certify a changed scene.
        let originalSourcePath = studio.doc.sourceSceneFile.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let originalSourceSHA256 = studio.doc.sourceSceneSHA256
        func isSourcePath(_ url: URL) -> Bool {
            let current = studio.doc.sourceSceneFile.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            return url.path == originalSourcePath || url.path == current
        }
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
        /// Native IK chain poses recorded by `captureIKPose` steps, keyed by label.
        var capturedIKPoses: [String: IKPoseCapture] = [:]
        /// World positions recorded by `captureObject` steps, keyed by step name.
        var capturedObjectPositions: [String: Float3] = [:]
        /// Pixels recorded by `captureRender` steps (raw RGBA8), keyed by label.
        var capturedRenders: [String: (width: Int, height: Int, bytes: [UInt8])] = [:]
        /// The single headless render size every `captureRender` uses, so a
        /// baseline and its comparison frame always share a resolution and the
        /// pixel counts mean the same thing across a scenario.
        let renderSide = 512
        /// Reads `image`'s RGBA8 pixels into a flat buffer, or nil when the
        /// bitmap context could not be built.
        func renderBytes(_ image: CGImage) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let read = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            return read ? bytes : nil
        }
        /// Pixels that differ between two equal-size RGBA8 buffers, counting a
        /// pixel as changed when any of its four channels moves by more than 2.
        func pixelDifference(_ a: [UInt8], _ b: [UInt8]) -> (changed: Int, exactChanged: Int, maximum: Int) {
            var count = 0, exactCount = 0, maximum = 0
            for i in stride(from: 0, to: a.count, by: 4) {
                var delta = 0
                for channel in 0..<4 { delta = max(delta, abs(Int(a[i + channel]) - Int(b[i + channel]))) }
                if delta > 2 { count += 1 }
                if delta > 0 { exactCount += 1 }
                maximum = max(maximum, delta)
            }
            return (count, exactCount, maximum)
        }
        /// The current frame rendered offscreen at `renderSide`² from the live
        /// camera, gizmos and grid stripped exactly like the export thumbnail,
        /// so captures stay comparable while the scenario selects nothing.
        func captureStudioRender() -> CGImage? {
            var f = studio.frame
            f.gizmos = []
            f.effects.showGrid = false
            return studio.host.renderer.capture(frame: f, width: renderSide, height: renderSide)
        }
        /// Pixels the current render moved against a `captureRender` baseline.
        func assertRender(_ step: Step, details: inout [String]) -> String? {
            guard let check = step.render else { return nil }
            guard check.changedPixelsAtLeast != nil || check.changedPixelsAtMost != nil else {
                return "assert render: name changedPixelsAtLeast or changedPixelsAtMost"
            }
            let minimum = check.changedPixelsAtLeast ?? 0, maximum = check.changedPixelsAtMost ?? renderSide * renderSide
            guard (0...renderSide * renderSide).contains(minimum),
                  (0...renderSide * renderSide).contains(maximum), minimum <= maximum else {
                return "assert render: bounds must satisfy 0 <= minimum <= maximum <= \(renderSide * renderSide)"
            }
            if let bound = check.maxChannelDeltaAtMost, !(0...255).contains(bound) {
                return "assert render: maxChannelDeltaAtMost must be in 0...255"
            }
            guard let base = capturedRenders[check.from] else {
                return "assert render: no captureRender pixels recorded under \"\(check.from)\""
            }
            guard let now = captureStudioRender() else {
                return "assert render: the current frame did not render at \(renderSide)x\(renderSide)"
            }
            guard now.width == base.width, now.height == base.height else {
                return "assert render: current render is \(now.width)x\(now.height), the capture was \(base.width)x\(base.height)"
            }
            guard let nowBytes = renderBytes(now) else {
                return "assert render: the current render's pixels could not be read"
            }
            let difference = pixelDifference(base.bytes, nowBytes), changed = difference.changed
            details.append("render \(renderSide)x\(renderSide): \(changed) pixels differ by >2/255 against \"\(check.from)\"; bounds \(minimum)...\(maximum); exactChangedPixels=\(difference.exactChanged), maxChannelDelta=\(difference.maximum)")
            if let bound = check.changedPixelsAtLeast, changed < bound {
                return "assert render: \(changed) pixels changed against \"\(check.from)\", expected at least \(bound) — the frame did not visibly update"
            }
            if let bound = check.changedPixelsAtMost, changed > bound {
                return "assert render: \(changed) pixels changed against \"\(check.from)\", expected at most \(bound) — the frame did not restore the captured state"
            }
            if let bound = check.maxChannelDeltaAtMost, difference.maximum > bound {
                return "assert render: maxChannelDelta \(difference.maximum) exceeds \(bound) against \"\(check.from)\""
            }
            return nil
        }
        /// Byte identity between an exported file and the imported original
        /// scene: how "a value or color edited back to the card's saved
        /// rate/rgba exports byte-identical bytes" is proven.
        func assertExportIdenticalToSource(_ step: Step, details: inout [String]) -> String? {
            guard let path = step.exportIdenticalToSource else { return nil }
            guard let url = insideLocal(path) else {
                return "assert exportIdenticalToSource: path must stay under .local/: \(path)"
            }
            guard let scenePath = originalSourcePath, let sourceSHA = originalSourceSHA256 else {
                return "assert exportIdenticalToSource: the scenario started without an imported original scene"
            }
            guard url.path != scenePath else {
                return "assert exportIdenticalToSource: output must differ from the original source path"
            }
            guard let exported = try? Data(contentsOf: url) else {
                return "assert exportIdenticalToSource: \"\(path)\" could not be read"
            }
            let exportedSHA = SHA256.hash(data: exported).map { String(format: "%02x", $0) }.joined()
            guard exportedSHA == sourceSHA else {
                return "assert exportIdenticalToSource: exported SHA256 \(exportedSHA) differs from initial source SHA256 \(sourceSHA)"
            }
            details.append("export \(path): \(exported.count) bytes; SHA256 \(exportedSHA) equals initial source")
            return nil
        }
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
        /// The one native (non-source) character named `name`: a character the
        /// scenario added (Add ▸ Character) has no source key to address it by.
        func nativeCharacter(_ name: String?) throws -> UUID {
            guard let name else { throw RigError.invalid("character (the native character's name) is required") }
            let matches = studio.doc.objects.filter { $0.kind == .character && $0.sourceCharacter == nil && $0.name == name }
            guard matches.count == 1 else {
                throw RigError.invalid("\(matches.count) native characters are named \"\(name)\", expected exactly one")
            }
            return matches[0].id
        }
        func ikChain(_ raw: String?) throws -> IKChain {
            guard let raw, let chain = IKChain(rawValue: raw) else {
                throw RigError.invalid("chain must be one of \(IKChain.allCases.map(\.rawValue)), got \(raw ?? "nothing")")
            }
            return chain
        }
        /// The chain as the preview draws it. The Pose tab works on the
        /// selection, so the character is selected first; the pose is
        /// `CharacterInstance.currentPose()` of the app's own instance — the
        /// pose `build` renders — after `refresh()` handed it the document's
        /// targets, and the failures are the frame builder's `ikFailures()`.
        func renderedIKPose(_ id: UUID, _ chain: IKChain) throws -> (pose: IKPoseCapture, failures: [IKChain: MathContractError]) {
            studio.selection = id
            guard let instance = studio.selectedInstance, let skeleton = instance.skeleton else {
                throw RigError.invalid("the character has no rendered instance with a skeleton")
            }
            let names = [chain.bones.upper, chain.bones.lower, chain.bones.end]
            let indices = names.compactMap { skeleton[$0] }
            guard indices.count == 3 else { throw RigError.invalid("the skeleton lacks one of \(names)") }
            let pose = instance.currentPose()
            let world = pose.worldMatrices(skeleton: skeleton)
            return (IKPoseCapture(rotations: indices.map { pose.rotations[$0] }, joints: indices.map { world[$0].translation }),
                    instance.ikFailures())
        }
        /// Largest quaternion component difference (q and -q are one rotation)
        /// and largest joint displacement between two chain poses, and whether
        /// every number is bit-identical.
        func ikDifference(_ a: IKPoseCapture, _ b: IKPoseCapture) -> (rotation: Float, joint: Float, identical: Bool) {
            var rotation: Float = 0, joint: Float = 0
            for (p, q) in zip(a.rotations, b.rotations) {
                rotation = max(rotation, min(simd_reduce_max(simd_abs(p.vector - q.vector)), simd_reduce_max(simd_abs(p.vector + q.vector))))
            }
            for (p, q) in zip(a.joints, b.joints) { joint = max(joint, simd_length(p - q)) }
            let identical = zip(a.rotations, b.rotations).allSatisfy { $0.vector == $1.vector }
                && zip(a.joints, b.joints).allSatisfy { $0 == $1 }
            return (rotation, joint, identical)
        }
        func describe(_ v: Float3) -> String { "(\(v.x), \(v.y), \(v.z))" }
        /// The native IK readback: the document target the Pose tab shows,
        /// and the rendered chain (`renderedIKPose`) against a capture.
        func assertIK(_ step: Step, details: inout [String]) -> String? {
            guard let check = step.ik else { return nil }
            let id: UUID, chain: IKChain
            do { id = try nativeCharacter(check.character); chain = try ikChain(check.chain) }
            catch { return "assert ik: \(error)" }
            let target = studio.doc.object(id)?.ikTargets[chain]
            if let expected = check.enabled, (target?.enabled ?? false) != expected {
                return "assert ik: \(chain.label) IK is \((target?.enabled ?? false) ? "on" : "off"), expected \(expected ? "on" : "off")"
            }
            if let expected = check.target {
                guard expected.count == 3, let position = target?.position else {
                    return "assert ik: target needs three components (null skips one) and the chain needs a target"
                }
                for (axis, value) in expected.enumerated() {
                    if let value, !floatEqual(position[axis], value) {
                        return "assert ik: target \(describe(position)) differs from \(expected) on axis \(axis)"
                    }
                }
            }
            let rendered: (pose: IKPoseCapture, failures: [IKChain: MathContractError])
            do { rendered = try renderedIKPose(id, chain) } catch { return "assert ik: \(error)" }
            let end = rendered.pose.joints[2]
            var line = "\(chain.label): end \(describe(end))"
            if let position = target?.position { line += ", target \(describe(position)), distance \(simd_length(end - position))" }
            line += rendered.failures[chain].map { ", unsolved: \($0)" } ?? ", solved"
            if let expected = check.solved, (rendered.failures[chain] == nil) != expected {
                details.append(line)
                return expected ? "assert ik: \(chain.label) IK left unsolved: \(rendered.failures[chain]!)"
                                : "assert ik: \(chain.label) IK solved, expected it unsolved"
            }
            if let bound = check.reachesTarget {
                guard let position = target?.position else { return "assert ik: \(chain.label) has no target to reach" }
                let distance = simd_length(end - position)
                guard distance <= bound else {
                    details.append(line)
                    return "assert ik: \(chain.label) end sits \(distance) m from its target, expected at most \(bound)"
                }
            }
            if let label = check.from {
                guard let base = capturedIKPoses[label] else { return "assert ik: no captureIKPose recorded under \"\(label)\"" }
                let difference = ikDifference(base, rendered.pose)
                line += "; against \"\(label)\": rotation \(difference.rotation), joints \(difference.joint) m, bit-identical \(difference.identical)"
                if let bound = check.within {
                    guard difference.rotation <= bound, difference.joint <= bound else {
                        details.append(line)
                        return "assert ik: \(chain.label) differs from \"\(label)\" by rotation \(difference.rotation), joints \(difference.joint) m, expected within \(bound)"
                    }
                } else {
                    guard difference.rotation > tolerance || difference.joint > tolerance else {
                        details.append(line)
                        return "assert ik: \(chain.label) moved only rotation \(difference.rotation), joints \(difference.joint) m from \"\(label)\""
                    }
                }
            }
            details.append(line)
            return nil
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

        /// An object's world displacement from a `captureObject` position, read
        /// through `StudioModel.sourceObjectWorldMatrix` (the placement walk
        /// `refresh()` renders with), so it measures what the view shows.
        func assertPosition(_ step: Step) -> String? {
            guard let check = step.position else { return nil }
            guard let id = studio.doc.objects.first(where: { $0.sourceObjectKey == check.key })?.id else {
                return "assert position: no object with source key \(check.key)"
            }
            guard let base = capturedObjectPositions[check.from] else {
                return "assert position: no captureObject position recorded under \"\(check.from)\""
            }
            let now: Float3
            do { now = try studio.sourceObjectWorldMatrix(id).translation }
            catch { return "assert position: object \(check.key) world position unavailable: \(error)" }
            let dx = now.x - base.x, dy = now.y - base.y, dz = now.z - base.z
            let moved = (dx * dx + dy * dy + dz * dz).squareRoot()
            if let bound = check.within {
                guard moved <= bound else {
                    return "assert position: object \(check.key) sits \(moved) from \"\(check.from)\" at (\(now.x), \(now.y), \(now.z)), expected it held within \(bound)"
                }
            } else {
                guard moved > tolerance else {
                    return "assert position: object \(check.key) moved only \(moved) from \"\(check.from)\" — it did not move"
                }
            }
            return nil
        }

        /// The camera the preview renders from, through `StudioModel.viewCamera`
        /// (which reports a rejected look-through in the status line and falls
        /// back to the saved camera), against either the saved camera or the
        /// named camera object's world placement.
        func assertView(_ step: Step, details: inout [String]) -> String? {
            guard let check = step.view else { return nil }
            guard (check.saved == true) != (check.key != nil), check.saved != false else {
                return "assert view: name exactly one of saved: true or key"
            }
            let view = studio.viewCamera, saved = studio.doc.camera
            let at = "(\(view.position.x), \(view.position.y), \(view.position.z))"
            let looking = "(\(view.forward.x), \(view.forward.y), \(view.forward.z))"
            if check.saved == true {
                guard view == saved else {
                    return "assert view: renders from \(at), expected the saved camera at (\(saved.position.x), \(saved.position.y), \(saved.position.z))"
                }
                details.append("view is the saved camera at \(at) looking \(looking)")
                return nil
            }
            let key = check.key!
            guard let id = studio.doc.objects.first(where: { $0.sourceObjectKey == key })?.id else {
                return "assert view: no object with source key \(key)"
            }
            let world: float4x4
            do { world = try studio.sourceObjectWorldMatrix(id) }
            catch { return "assert view: camera \(key) world placement unavailable: \(error)" }
            let offset = simd_distance(view.position, world.translation)
            let forward = simd_normalize(world.rotationQuaternion.act(Float3(0, 0, -1)))
            let turn = atan2(simd_length(simd_cross(view.forward, forward)), simd_dot(view.forward, forward)) * 180 / .pi
            guard view != saved, offset <= tolerance, turn <= 0.01 else {
                return "assert view: renders from \(at), \(offset) from camera \(key) and \(turn) degrees off its forward\(view == saved ? " (the saved camera)" : ""), expected it looked through camera \(key)"
            }
            details.append("view looks through camera \(key) from \(at) looking \(looking) (\(offset) m, \(turn) degrees from its placement)")
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

        /// The live outfit readback: the rendered preview's assembled outfit,
        /// the card's saved outfit and its resolved selections/diagnostics.
        func assertOutfit(_ step: Step, details: inout [String]) -> String? {
            guard let check = step.outfit else { return nil }
            guard let preview = characterPreview(check.key) else {
                return "assert outfit: source key \(check.key) is not a rendered character"
            }
            details.append("outfit \(check.key): rendered \(preview.coordinate), saved \(preview.savedCoordinate), \(preview.outfitCount) saved outfits")
            if let expected = check.coordinate, preview.coordinate != expected {
                return "assert outfit: character \(check.key) coordinate is \(preview.coordinate), expected \(expected)"
            }
            if let expected = check.saved, preview.savedCoordinate != expected {
                return "assert outfit: character \(check.key) saved coordinate is \(preview.savedCoordinate), expected \(expected)"
            }
            func selection(_ property: String) -> SourceMakerLibrary.Selection? {
                preview.selections.first { $0.property.utf8.elementsEqual(property.utf8) }
            }
            if let property = check.resolved {
                guard let found = selection(property) else { return "assert outfit: no selection \(property)" }
                guard found.status == "converted" || found.status == "empty", let entry = found.entry, entry.id == found.sourceID else {
                    return "assert outfit: \(property) is \(found.status), expected a resolved library entry"
                }
                details.append("\(property): \(found.status) library entry category \(entry.category) ID \(entry.id) (saved \(found.savedID))")
            }
            if let property = check.missing {
                guard let found = selection(property) else { return "assert outfit: no selection \(property)" }
                guard found.status == "conversionMissing", found.entry == nil else {
                    return "assert outfit: \(property) is \(found.status), expected conversionMissing"
                }
                guard preview.diagnostics.contains(where: { $0.hasPrefix(property + ": conversionMissing") }) else {
                    return "assert outfit: no preview diagnostic reports \(property) as conversionMissing"
                }
                details.append("\(property): conversionMissing, source ID \(found.sourceID), diagnosed")
            }
            return nil
        }

        /// The live wear readback (ST-C03): the rendered preview's clothes
        /// state, drawn garments/accessories and fallbacks, plus whether the
        /// document holds a wear edit.
        func assertClothes(_ step: Step, details: inout [String]) -> String? {
            guard let check = step.clothes else { return nil }
            guard let object = studio.doc.objects.first(where: { $0.sourceObjectKey == check.key }),
                  let preview = studio.sourceShapePreview(for: object.id) else {
                return "assert clothes: source key \(check.key) is not a rendered character"
            }
            let evaluation = preview.wearEvaluation
            let off = preview.showAccessory.indices.filter { !preview.showAccessory[$0] }
            let edited = object.sourceClothesState != nil || object.sourceShowAccessory != nil
            func list<T>(_ values: [T]) -> String { "[" + values.map { "\($0)" }.joined(separator: ",") + "]" }
            details.append("clothes \(check.key): state \(list(preview.clothesState)), saved \(list(preview.savedWear.clothesState)), loaded \(list(preview.loadedClothesState)), shoesType \(preview.savedWear.shoesType); garments drawn \(list(evaluation.renderedClothing)) of \(list(preview.wearLayout.clothingKinds)); accessories drawn \(list(evaluation.renderedAccessories)), off \(list(off)); body alpha (\(evaluation.bodyAlpha.x), \(evaluation.bodyAlpha.y)); document edited \(edited); fallbacks \(evaluation.fallbacks)")
            var problems: [String] = []
            if let expected = check.state, preview.clothesState.map(Int.init) != expected { problems.append("state is \(list(preview.clothesState)), expected \(list(expected))") }
            if let expected = check.saved, preview.savedWear.clothesState.map(Int.init) != expected { problems.append("saved state is \(list(preview.savedWear.clothesState)), expected \(list(expected))") }
            if let expected = check.rendered, evaluation.renderedClothing != expected.sorted() { problems.append("drawn garments are \(list(evaluation.renderedClothing)), expected \(list(expected.sorted()))") }
            if let expected = check.accessories, evaluation.renderedAccessories != expected.sorted() { problems.append("drawn accessories are \(list(evaluation.renderedAccessories)), expected \(list(expected.sorted()))") }
            if let expected = check.accessoriesOff, off != expected.sorted() { problems.append("hidden accessory slots are \(list(off)), expected \(list(expected.sorted()))") }
            if let expected = check.edited, edited != expected { problems.append("document wear edit is \(edited), expected \(expected)") }
            if let expected = check.fallbacks, evaluation.fallbacks.count != expected { problems.append("\(evaluation.fallbacks.count) fallbacks, expected \(expected)") }
            if let needle = check.diagnosticContains, !(preview.wearDiagnostics + preview.diagnostics).contains(where: { $0.contains(needle) }) {
                problems.append("no wear or import diagnostic contains \"\(needle)\"")
            }
            return problems.isEmpty ? nil : "assert clothes: character \(check.key) " + problems.joined(separator: "; ")
        }

        func assertExpression(_ step: Step, details: inout [String]) -> String? {
            guard let check = step.expression else { return nil }
            guard let id = object(step), let preview = studio.sourceShapePreview(for: id), let object = studio.doc.object(id) else {
                return "assert expression: key needs a loaded source character"
            }
            let state = preview.expressionState
            details.append("expression \(step.key!): \(state); document edited \(object.sourceExpression != nil); diagnostics \(preview.expressionDiagnostics)")
            if check.applying(to: state) != state { return "assert expression: rendered fields differ from requested values" }
            if let edited = check.edited, (object.sourceExpression != nil) != edited { return "assert expression: document edited mismatch" }
            if (object.sourceExpression ?? preview.savedExpression) != state { return "assert expression: document and rendered state differ" }
            if let followsGuide = check.followsGuide, preview.eyeLookFollowsGuide != followsGuide { return "assert expression: eye target mismatch" }
            if let needle = check.diagnosticContains, !preview.expressionDiagnostics.contains(where: { $0.contains(needle) }) {
                return "assert expression: no diagnostic contains \(needle)"
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
            case "resetShape":
                guard let id = object(step) else { record(step, false, "resetShape: no object with source key \(step.key ?? -1)"); continue }
                guard let face = step.faceReset else {
                    record(step, false, "resetShape: face must be true (face domain) or false (body domain)"); continue
                }
                // The inspector's "Reset to card" button and this op share
                // `StudioModel.resetSourceShape`, so the lane proves the app's
                // own reset path, not a re-implementation of it.
                do {
                    try studio.resetSourceShape(id, face: face)
                    record(step, true, "source key \(step.key!) \(face ? "face" : "body") shape reset to the card's saved values")
                } catch { record(step, false, "resetShape: \(error)") }
            case "resetColors":
                guard let id = object(step) else { record(step, false, "resetColors: no object with source key \(step.key ?? -1)"); continue }
                // Same shared path as the inspector's "Reset to card" button.
                do {
                    try studio.resetSourceColorEdits(id)
                    record(step, true, "source key \(step.key!) color edits cleared, the card's saved colors render again")
                } catch { record(step, false, "resetColors: \(error)") }
            case "setOutfit":
                guard let id = object(step) else { record(step, false, "setOutfit: no object with source key \(step.key ?? -1)"); continue }
                guard let index = step.index else { record(step, false, "setOutfit: index (the outfit 0...6) is required"); continue }
                // The inspector's Outfit picker calls the same
                // StudioModel.setSourceOutfit, so the lane drives the app's path.
                let before = (studio.doc.object(id)?.sourceOutfit, studio.sourceShapePreview(for: id).map(ObjectIdentifier.init))
                do {
                    try studio.setSourceOutfit(id, coordinate: index)
                    if let expected = step.errorContains {
                        record(step, false, "setOutfit: outfit \(index) was accepted, expected a refusal containing \"\(expected)\"")
                    } else {
                        let preview = studio.sourceShapePreview(for: id)
                        record(step, true, "source key \(step.key!) outfit \(index) selected; rendered \(preview.map { String($0.coordinate) } ?? "none"), document sourceOutfit \(studio.doc.object(id)?.sourceOutfit.map(String.init) ?? "nil")")
                    }
                } catch {
                    guard let expected = step.errorContains else { record(step, false, "setOutfit: \(error)"); continue }
                    let unchanged = studio.doc.object(id)?.sourceOutfit == before.0
                        && studio.sourceShapePreview(for: id).map(ObjectIdentifier.init) == before.1
                    let matched = String(describing: error).contains(expected)
                    record(step, matched && unchanged, matched && unchanged ? "refused as expected, document and preview unchanged: \(error)"
                        : "expected a refusal containing \"\(expected)\" that leaves the outfit unchanged; received \(error), unchanged=\(unchanged)")
                }
            case "setClothesState", "setAccessoryVisible":
                let op = step.op
                guard let id = object(step) else { record(step, false, "\(op): no object with source key \(step.key ?? -1)"); continue }
                guard let index = step.index else { record(step, false, "\(op): index (the clothes row 0...7 or accessory slot 0...19) is required"); continue }
                guard op == "setAccessoryVisible" ? step.on != nil : step.state != nil else {
                    record(step, false, op == "setAccessoryVisible" ? "setAccessoryVisible: on is required" : "setClothesState: state (0...3) is required"); continue
                }
                // The Clothes tab's rows and accessory toggles call the same
                // StudioModel methods, so the lane drives the app's path.
                let before = (studio.doc.object(id)?.sourceClothesState, studio.doc.object(id)?.sourceShowAccessory,
                              studio.sourceShapePreview(for: id).map { ($0.clothesState, $0.showAccessory, ObjectIdentifier($0)) })
                do {
                    if op == "setAccessoryVisible" { try studio.setSourceAccessoryVisible(id, slot: index, visible: step.on!) }
                    else { try studio.setSourceClothesState(id, kind: index, state: step.state!) }
                    if let expected = step.errorContains {
                        record(step, false, "\(op): the edit was accepted, expected a refusal containing \"\(expected)\"")
                    } else {
                        let preview = studio.sourceShapePreview(for: id), object = studio.doc.object(id)
                        record(step, true, "source key \(step.key!) \(op) \(index) -> \(step.state.map(String.init) ?? String(step.on!)); rendered state \(preview.map { $0.clothesState.map(String.init).joined(separator: ",") } ?? "none"), drawn garments \(preview.map { $0.wearEvaluation.renderedClothing.map(String.init).joined(separator: ",") } ?? "none"), drawn accessories \(preview.map { $0.wearEvaluation.renderedAccessories.map(String.init).joined(separator: ",") } ?? "none"), document edited \(object?.sourceClothesState != nil || object?.sourceShowAccessory != nil)")
                    }
                } catch {
                    guard let expected = step.errorContains else { record(step, false, "\(op): \(error)"); continue }
                    let after = studio.sourceShapePreview(for: id)
                    let unchanged = studio.doc.object(id)?.sourceClothesState == before.0 && studio.doc.object(id)?.sourceShowAccessory == before.1
                        && after.map(ObjectIdentifier.init) == before.2?.2 && after?.clothesState == before.2?.0 && after?.showAccessory == before.2?.1
                    let matched = String(describing: error).contains(expected)
                    record(step, matched && unchanged, matched && unchanged ? "refused as expected, document and preview unchanged: \(error)"
                        : "expected a refusal containing \"\(expected)\" that leaves the wear unchanged; received \(error), unchanged=\(unchanged)")
                }
            case "setExpression", "resetExpression":
                guard let id = object(step), let preview = studio.sourceShapePreview(for: id) else {
                    record(step, false, "expression: key needs a loaded source character"); continue
                }
                guard step.op == "resetExpression" || step.expression != nil else {
                    record(step, false, "setExpression: expression fields are required"); continue
                }
                let before = (studio.doc.object(id)?.sourceExpression, preview.expressionState,
                              ObjectIdentifier(preview), studio.undoStack.count)
                do {
                    let next = step.op == "resetExpression" ? nil : step.expression!.applying(to: preview.expressionState)
                    try studio.setSourceExpression(id, next)
                    if let expected = step.errorContains {
                        record(step, false, "expression: edit accepted, expected refusal containing \(expected)")
                    } else {
                        record(step, true, "source key \(step.key!) expression \(preview.expressionState)")
                    }
                } catch {
                    guard let expected = step.errorContains else { record(step, false, "expression: \(error)"); continue }
                    let after = studio.sourceShapePreview(for: id)
                    let unchanged = studio.doc.object(id)?.sourceExpression == before.0 && after?.expressionState == before.1
                        && after.map(ObjectIdentifier.init) == before.2 && studio.undoStack.count == before.3
                    let matched = String(describing: error).contains(expected)
                    record(step, matched && unchanged, "expression refusal: \(error); document, preview and undo unchanged=\(unchanged)")
                }
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
            case "addCharacter":
                // The Studio toolbar's Add ▸ Character ▸ Female/Male button.
                guard let sex = ["female": Sex.female, "male": Sex.male][step.sex ?? ""] else {
                    record(step, false, "addCharacter: sex must be \"female\" or \"male\""); continue
                }
                let before = Set(studio.doc.objects.map(\.id))
                studio.addCharacter(sex: sex)
                guard let added = studio.doc.objects.first(where: { !before.contains($0.id) }), added.kind == .character,
                      added.sourceCharacter == nil, studio.selection == added.id else {
                    record(step, false, "addCharacter: no new selected native character: \(studio.status)"); continue
                }
                record(step, true, "added native \(step.sex!) character \"\(added.name)\": \(studio.status)")
            case "setIKEnabled":
                do {
                    let id = try nativeCharacter(step.character), chain = try ikChain(step.chain)
                    guard let on = step.on else { record(step, false, "setIKEnabled: on is required"); continue }
                    // The Pose tab's IK row toggle works on the selection.
                    studio.selection = id
                    studio.enableIK(chain, on: on)
                    guard let target = studio.doc.object(id)?.ikTargets[chain], target.enabled == on else {
                        record(step, false, "setIKEnabled: \(chain.label) IK did not turn \(on ? "on" : "off")"); continue
                    }
                    record(step, true, "\(chain.label) IK \(on ? "on" : "off"), target \(describe(target.position)); status \"\(studio.status)\"")
                } catch { record(step, false, "setIKEnabled: \(error)") }
            case "setIKTarget":
                do {
                    let id = try nativeCharacter(step.character), chain = try ikChain(step.chain)
                    guard let axis = ["x": 0, "y": 1, "z": 2][step.axis ?? ""], (step.delta == nil) != (step.value == nil) else {
                        record(step, false, "setIKTarget: axis (\"x\", \"y\" or \"z\") and exactly one of delta or value are required"); continue
                    }
                    // The Target row is shown only for an enabled chain.
                    guard let target = studio.doc.object(id)?.ikTargets[chain], target.enabled else {
                        record(step, false, "setIKTarget: \(chain.label) IK is off; run setIKEnabled first"); continue
                    }
                    var position = target.position
                    if let delta = step.delta { position[axis] = position[axis].advanced(by: delta) }
                    else { position[axis] = step.value! }
                    studio.selection = id
                    studio.setIKTarget(id, chain, position: position)
                    let now = studio.doc.object(id)?.ikTargets[chain]?.position ?? .zero
                    record(step, true, "\(chain.label) target \(describe(target.position)) → \(describe(now)); status \"\(studio.status)\"")
                } catch { record(step, false, "setIKTarget: \(error)") }
            case "captureIKPose":
                do {
                    let id = try nativeCharacter(step.character), chain = try ikChain(step.chain)
                    guard let label = step.name, !label.isEmpty else {
                        record(step, false, "captureIKPose: name (the capture label) is required"); continue
                    }
                    let rendered = try renderedIKPose(id, chain)
                    capturedIKPoses[label] = rendered.pose
                    let joints = rendered.pose.joints.map(describe).joined(separator: ", ")
                    let rotations = rendered.pose.rotations.map { "(\($0.vector.x), \($0.vector.y), \($0.vector.z), \($0.vector.w))" }.joined(separator: ", ")
                    record(step, true, "captured \(chain.label) as \"\(label)\": joints \(joints); rotations \(rotations); \(rendered.failures[chain].map { "unsolved: \($0)" } ?? "no IK failure")")
                } catch { record(step, false, "captureIKPose: \(error)") }
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
            case "captureObject":
                guard let id = object(step) else { record(step, false, "captureObject: no object with source key \(step.key ?? -1)"); continue }
                guard let label = step.name, !label.isEmpty else {
                    record(step, false, "captureObject: name (the capture label) is required"); continue
                }
                do {
                    let position = try studio.sourceObjectWorldMatrix(id).translation
                    capturedObjectPositions[label] = position
                    record(step, true, "captured object \(step.key!) world position (\(position.x), \(position.y), \(position.z)) as \"\(label)\"")
                } catch { record(step, false, "captureObject: \(error)") }
            case "captureRender":
                guard let label = step.name, !label.isEmpty else {
                    record(step, false, "captureRender: name (the capture label) is required"); continue
                }
                guard let image = captureStudioRender(), let bytes = renderBytes(image) else {
                    record(step, false, "captureRender: the current frame did not render at \(renderSide)x\(renderSide)"); continue
                }
                if let path = step.path {
                    guard let url = insideLocal(path), !isSourcePath(url) else {
                        record(step, false, "captureRender: output must stay under .local/ and differ from both initial and current source paths"); continue
                    }
                    do {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try CaptureOutput.writePNG(image, to: url)
                    } catch { record(step, false, "captureRender: \(error)"); continue }
                }
                capturedRenders[label] = (image.width, image.height, bytes)
                record(step, true, "captured the current render as \(image.width)x\(image.height) RGBA8 under \"\(label)\"")
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
                studio.orbitCamera(dx: dx, dy: dy)
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
                guard !isSourcePath(url) else {
                    record(step, false, "export: output must differ from both initial and current source paths")
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
                    if FileManager.default.fileExists(atPath: url.path) {
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
                    let catalog = EngineHost.studioPoseContract(forRig: rig)
                    try studio.importSourceScenePreview(sceneURL: url, rigURL: rig, boneCatalogURL: catalog)
                    record(step, true, "reimported \(path): \(studio.doc.objects.count) objects")
                } catch {
                    record(step, false, "reimport failed, stopping: \(error)")
                    break scenarioLoop
                }
            case "assert", "assertRejected":
                var problems: [String] = []
                var details: [String] = []
                let needsObject = step.name != nil || step.visible != nil || step.face != nil || step.body != nil || step.color != nil
                    || step.treeLabel != nil
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
                    if let expected = step.treeLabel, let object = studio.doc.object(id) {
                        let label = studio.workspaceLabel(of: object, sceneSHA256: studio.doc.sourceSceneSHA256).title
                        if label != expected {
                            problems.append("assert treeLabel: source key \(step.key!) reads \"\(label)\" in the tree, expected \"\(expected)\"")
                        } else {
                            details.append("tree label \"\(label)\"")
                        }
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
                if let problem = assertPosition(step) { problems.append(problem) }
                if let problem = assertEyeLook(step) { problems.append(problem) }
                if let problem = assertBlink(step) { problems.append(problem) }
                if let problem = assertHandPattern(step) { problems.append(problem) }
                // The render and export-identity checks resolve their own
                // inputs (the `from` label / the file path) inside the check
                // value, like `animation`/`fk`.
                if let problem = assertRender(step, details: &details) { problems.append(problem) }
                if let problem = assertExportIdenticalToSource(step, details: &details) { problems.append(problem) }
                if let problem = assertOutfit(step, details: &details) { problems.append(problem) }
                if let problem = assertClothes(step, details: &details) { problems.append(problem) }
                if let problem = assertExpression(step, details: &details) { problems.append(problem) }
                if let problem = assertIK(step, details: &details) { problems.append(problem) }
                if let needle = step.diagnosticContains {
                    let diagnostics = studio.doc.sourcePreviewDiagnostics ?? []
                    if !diagnostics.contains(where: { $0.contains(needle) }) {
                        problems.append("assert diagnosticContains: no diagnostic contains \"\(needle)\"")
                    }
                }
                // After the view check, which reads `viewCamera` and so lets a
                // rejected look-through report itself in the status line.
                if let problem = assertView(step, details: &details) { problems.append(problem) }
                if let needle = step.statusContains, !studio.status.contains(needle) {
                    problems.append("assert statusContains: status \"\(studio.status)\" does not contain \"\(needle)\"")
                }
                if let needle = step.indicatorContains {
                    let indicator = studio.activeSourceCameraView?.indicator ?? ""
                    if !indicator.contains(needle) {
                        problems.append("assert indicatorContains: view indicator \"\(indicator)\" does not contain \"\(needle)\"")
                    } else {
                        details.append("view indicator \"\(indicator)\"")
                    }
                }
                if step.op == "assertRejected" {
                    guard let expected = step.errorContains, !expected.isEmpty else {
                        record(step, false, "assertRejected: errorContains must be nonempty"); continue
                    }
                    let matched = problems.count == 1 && problems[0].contains(expected)
                    record(step, matched, matched ? "rejected as expected: \(problems[0])" : "expected one failure containing \"\(expected)\"; received \(problems)")
                } else if problems.isEmpty {
                    record(step, true, (["assert passed for source key \(step.key.map(String.init) ?? "n/a")"] + details).joined(separator: "; "))
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
