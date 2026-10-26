import Foundation
import AppKit
import simd
import CoreMath
import CryptoKit
import Scene
import Renderer
import Character
import Gameplay
import Studio
import ShaderTypes

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
        /// `"setClothesState"`, `"setAccessoryVisible"`, `"setShoesType"`, `"setExpression"`, `"resetExpression"`,
        /// `"setAnimation"`, `"setAnimationSpeed"`, `"setForceLoop"`, `"setFKEnabled"`,
        /// `"setFK"`, `"setPoseMode"`, `"selectBone"`, `"dragGizmo"`, `"hoverGizmo"`,
        /// `"captureBone"`, `"captureObject"`, `"captureRender"`, `"advance"`, `"orbit"`,
        /// `"setAutomaticBlink"`, `"addCharacter"`, `"setIKEnabled"`, `"setIKTarget"`,
        /// `"captureIKPose"`, `"editDuringAdvance"`, `"backgroundBuild"`, `"delete"`, `"setParent"`, `"duplicate"`,
        /// `"addFolder"`, `"addCamera"`, `"addLight"`, `"export"`, `"exportRejected"`, `"reimport"`,
        /// `"focus"`, `"selectRoutePoint"`, `"dragRoutePoint"`, `"editRoute"`, `"captureRoute"`, `"setShowSourceMap"`,
        /// `"assert"`, `"assertRejected"`.
        let op: String
        let key: Int32?
        /// ST-T03: with `key`, address the n-th copy (document order) of that
        /// source record instead of the record itself; a copy has no source
        /// key until an export and reimport give it one.
        let copy: Int?
        /// ST-T03: address the added native object with this name instead of
        /// a source key (a new folder, camera or light before export).
        let added: String?
        /// assert only: the looked-through camera must be a copy of this
        /// source camera (`Studio.Duplicate` hands the view to the copy).
        let activeCopyOf: Int32?
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
        /// editDuringAdvance: the edit that lands while a live step runs off
        /// the main thread: `"none"`, `"move"` (the character `key` 0.25 m
        /// along x), `"setFK"` (`key`, `bone`, `rotation`), `"undo"` or `"redo"`.
        let edit: String?
        /// backgroundBuild: the operation run both with synchronous and with
        /// background source character builds (R7 phase 2, item 6):
        /// `"import"`, `"importTwice"` (a second import replaces the first in
        /// flight), `"importThenNewScene"` (New Scene cancels the import) or
        /// `"duplicate"` (`key`, then undo).
        let build: String?
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
        /// Exact labels consumed by ClothesInspector, compared as UTF-8 bytes.
        /// This model assertion does not stand in for a displayed AX/UI check.
        let accessoryLabels: AccessoryLabelsValue?
        /// Exact resident metadata consumed by the plugin panel, not AX evidence.
        let pluginMount: [PluginMountSummary.Section]?
        /// setParent only (ST-T03): the new parent's source key, `null` for
        /// the root — `.some(nil)` — and `nil` when the key is absent, which
        /// the op refuses, like the hand-decoded `activeCamera` check.
        let parent: Int32??
        /// assert only: one parent's children in tree order, by source key.
        let children: ChildrenValue?
        /// assert only: source keys no document object may carry (deleted).
        let absent: [Int32]?
        /// selectRoutePoint only (ST-T11): pick the point's aid handle
        /// instead of the point's own.
        let aid: Bool?
        /// editRoute only (ST-T11): the route edit the inspector makes.
        let routeEdit: RouteEditValue?
        /// assert only (ST-T11): the route's edit state and playback record.
        let route: RouteValue?
        /// assert only (ST-T11): how many route lines the current frame
        /// draws (the depth-tested line batches; light glyphs are not).
        let routeLines: Int?
        /// assert only (ST-A11): the source scene's map as the render path
        /// sees it (`StudioModel.sourceMapCensus()`); only named fields are checked.
        let sourceMap: SourceMapValue?

        /// One route panel edit, applied through `StudioModel.editSourceRoute`
        /// and the add/delete point calls the inspector buttons make.
        /// `setting` is "add", "delete", "move" (`index`, `position`, `aid`),
        /// "rotateStart" (`rotation`), "speed" (`index`, `value`), "ease"
        /// (`index`, `ease`), "connection" (`index`, `curve`), "link"
        /// (`index`, `on`), "loop", "line" (`on`), "orientation"
        /// (`orientation`) or "color" (`rgb`). `refused` turns the step into
        /// a negative control: the edit must be refused with a status
        /// containing it and leave the document unchanged.
        struct RouteEditValue: Decodable {
            let setting: String
            let index: Int?
            let position: [Float]?
            let aid: Bool?
            let rotation: [Float]?
            let value: Float?
            let ease: Int32?
            let curve: Bool?
            let on: Bool?
            let orientation: Int32?
            let rgb: [Float]?
            let refused: String?
        }
        /// The route state readback: every field is optional and only the
        /// fields present are compared; the playback record is always checked
        /// against the state (`SourceStudioRouteState.record(authored:)`).
        struct RouteValue: Decodable {
            struct Point: Decodable {
                let index: Int
                let position: [Float]?
                let rotation: [Float]?
                let aid: [Float]?
                let aidInitialized: Bool?
                let speed: Float?
                let ease: Int32?
                let curve: Bool?
                let link: Bool?
                /// whether the point came from the record (false: added).
                let sourced: Bool?
            }
            let key: Int32
            let copy: Int?
            let points: Int?
            /// whether the document holds a route edit (nil: the record's own).
            let edited: Bool?
            let loop: Bool?
            let line: Bool?
            let orientation: Int32?
            let rgb: [Float]?
            let point: [Point]?
            /// position tolerance in metres (default 1e-5).
            let within: Float?
            /// a `captureRoute` label: every point and setting must equal the
            /// captured state (positions within `within`), so an export and
            /// reimport or a native reload proves the edits survived.
            let from: String?
            /// the playback record's point and aid keys, in point order.
            let keys: [Int32]?
            let aidKeys: [Int32]?
        }

        struct ChildrenValue: Decodable {
            /// the parent's source key; absent or null is the root.
            let parent: Int32?
            /// the parent's copy index (with `parent`, like a step's `copy`).
            let parentCopy: Int?
            /// the children's source keys, or `labels`: "622" for a source
            /// record, "copy:962" for a copy, "native:Folder" for an added
            /// object (one of the two is required).
            let keys: [Int32]?
            let labels: [String]?
        }

        struct AccessoryLabelsValue: Decodable {
            let key: Int32
            let labels: [String]
            let mounted: Bool
            let loadedSlots: [Int]
        }
        /// setClothesState: the clothes state 0...3 (on, half, half 2, off)
        /// for the CharaStudio row in `index` (0 top ... 7 shoes);
        /// setShoesType: the shoes type (0 indoor, 1 outdoor).
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
            /// whether the document holds a wear edit (sourceClothesState,
            /// sourceShowAccessory or sourceShoesType non-nil); false proves a
            /// return to saved.
            let edited: Bool?
            /// the rendered shoesType, and the card's saved one as imported.
            let shoesType: Int?, savedShoesType: Int?
            /// exactly the drawn clothing renderers, by source mesh name
            /// without the assembly's "clothes-<kind>/" prefix (sorted).
            let drawn: [String]?
            /// the ChangeAlphaMask (_alpha_a, _alpha_b) the body renders with.
            let bodyAlpha: [Float]?
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
            /// the n-th copy of `key` instead of the record itself.
            let copy: Int?
            /// the `captureObject` label to measure against: by default the
            /// object must have moved beyond the numeric tolerance; `within`
            /// flips the check to "it is still within that bound", like `fk`.
            let from: String
            let within: Float?
            /// with `within`: the world rotation must also be held within this
            /// many degrees of the capture (the angle between the two
            /// rotations), so a reparent proves the whole world pose stayed.
            let rotationWithin: Float?
        }
        /// ST-A11: `none` asserts the document names no map (no request, no
        /// draws, no status line); the other fields compare the census. Each
        /// `pickNothingAt` point (viewport fractions, origin top-left) must
        /// pick id 0 — map pixels never select or highlight anything — and
        /// each `pickSomethingAt` point a nonzero id (the map does not hide
        /// what stands in front of it).
        struct SourceMapValue: Decodable {
            let none: Bool?
            let map: Int32?
            let draws: Int?
            let lineContains: String?
            let lineAbsent: String?
            let loading: Bool?
            let pickNothingAt: [[Float]]?
            let pickSomethingAt: [[Float]]?
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
                 render, exportIdenticalToSource, errorContains, outfit, accessoryLabels, pluginMount, state, clothes, expression,
                 sex, character, chain, delta, ik, edit, build, parent, children, absent, copy, added, activeCopyOf,
                 aid, routeEdit, route, routeLines, sourceMap
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            op = try c.decode(String.self, forKey: .op)
            edit = try c.decodeIfPresent(String.self, forKey: .edit)
            build = try c.decodeIfPresent(String.self, forKey: .build)
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
            accessoryLabels = try c.decodeIfPresent(AccessoryLabelsValue.self, forKey: .accessoryLabels)
            pluginMount = try c.decodeIfPresent([PluginMountSummary.Section].self, forKey: .pluginMount)
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
            if c.contains(.parent) {
                parent = try c.decodeIfPresent(Int32.self, forKey: .parent)
            } else {
                parent = nil
            }
            children = try c.decodeIfPresent(ChildrenValue.self, forKey: .children)
            absent = try c.decodeIfPresent([Int32].self, forKey: .absent)
            copy = try c.decodeIfPresent(Int.self, forKey: .copy)
            added = try c.decodeIfPresent(String.self, forKey: .added)
            activeCopyOf = try c.decodeIfPresent(Int32.self, forKey: .activeCopyOf)
            aid = try c.decodeIfPresent(Bool.self, forKey: .aid)
            routeEdit = try c.decodeIfPresent(RouteEditValue.self, forKey: .routeEdit)
            route = try c.decodeIfPresent(RouteValue.self, forKey: .route)
            routeLines = try c.decodeIfPresent(Int.self, forKey: .routeLines)
            sourceMap = try c.decodeIfPresent(SourceMapValue.self, forKey: .sourceMap)
        }
    }

    let steps: [Step]
    let pluginLibrary: PluginLibraryScenario?
    let hideStudioUI: HideStudioUIScenario?

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
            if let name = step.added {
                return studio.doc.objects.first { $0.sourceRecordKey == nil && $0.name == name }?.id
            }
            guard let key = step.key else { return nil }
            return objectID(key: key, copy: step.copy)
        }
        func objectID(key: Int32, copy: Int?) -> UUID? {
            guard let copy else { return studio.doc.objects.first { $0.sourceObjectKey == key }?.id }
            let copies = studio.doc.objects.filter { $0.sourceObjectKey == nil && $0.sourceDuplicateOf == key }
            return copies.indices.contains(copy) ? copies[copy].id : nil
        }
        /// The object a step names, for messages.
        func describe(_ step: Step) -> String {
            if let name = step.added { return "added \"\(name)\"" }
            guard let key = step.key else { return "<no key>" }
            return step.copy.map { "copy \($0) of source key \(key)" } ?? "source key \(key)"
        }
        /// The label `children` compares: the source key, `copy:<key>` or `native:<name>`.
        func treeLabel(_ object: StudioObject) -> String {
            if let key = object.sourceObjectKey { return String(key) }
            if let key = object.sourceDuplicateOf { return "copy:\(key)" }
            return "native:\(object.name)"
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
        /// ST-T11: `captureRoute` edit states by label.
        var capturedRoutes: [String: SourceStudioRouteState] = [:]
        /// World rotations recorded by the same `captureObject` steps.
        var capturedObjectRotations: [String: simd_quatf] = [:]
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

        /// ST-A11: the source map census and picks over the current frame.
        func assertSourceMap(_ check: Step.SourceMapValue, problems: inout [String], details: inout [String]) {
            let census = studio.sourceMapCensus()
            if check.none == true, census.map != nil || census.draws != 0 || census.line != nil {
                problems.append("assert sourceMap: expected no map, found map \(census.map.map(String.init) ?? "none"), \(census.draws) draws, line \(census.line ?? "none")")
            }
            if let expected = check.map, census.map != expected {
                problems.append("assert sourceMap: map \(census.map.map(String.init) ?? "none"), expected \(expected)")
            }
            if let expected = check.draws, census.draws != expected {
                problems.append("assert sourceMap: \(census.draws) map draws, expected \(expected)")
            }
            if let expected = check.loading, census.loading != expected {
                problems.append("assert sourceMap: loading \(census.loading), expected \(expected)")
            }
            if let fragment = check.lineContains, !(census.line ?? "").contains(fragment) {
                problems.append("assert sourceMap: status line \"\(census.line ?? "")\" lacks \"\(fragment)\"")
            }
            if let fragment = check.lineAbsent, (census.line ?? "").contains(fragment) {
                problems.append("assert sourceMap: status line \"\(census.line ?? "")\" contains \"\(fragment)\"")
            }
            let size = studio.viewportSize
            for (points, nothing) in [(check.pickNothingAt ?? [], true), (check.pickSomethingAt ?? [], false)] {
                for point in points {
                    guard point.count == 2, (0...1).contains(point[0]), (0...1).contains(point[1]) else {
                        problems.append("assert sourceMap: pick point \(point) is not two viewport fractions"); continue
                    }
                    let id = studio.pickID(at: SIMD2<Float>(point[0] * size.x, point[1] * size.y))
                    if nothing, id != 0 { problems.append("assert sourceMap: pick at \(point) found id \(id), expected nothing (0)") }
                    if !nothing, id == 0 { problems.append("assert sourceMap: pick at \(point) found nothing, expected an object") }
                }
            }
            details.append("map \(census.map.map(String.init) ?? "none"), \(census.draws) draws, \(census.triangles) triangles, \(census.textureBytes) texture bytes, line \(census.line ?? "none")")
        }

        /// An object's world displacement from a `captureObject` position, read
        /// through `StudioModel.sourceObjectWorldMatrix` (the placement walk
        /// `refresh()` renders with), so it measures what the view shows.
        func assertPosition(_ step: Step) -> String? {
            guard let check = step.position else { return nil }
            guard let id = objectID(key: check.key, copy: check.copy) else {
                return "assert position: no object with source key \(check.key)\(check.copy.map { " copy \($0)" } ?? "")"
            }
            guard let base = capturedObjectPositions[check.from] else {
                return "assert position: no captureObject position recorded under \"\(check.from)\""
            }
            let now: Float3, world: float4x4
            do { world = try studio.sourceObjectWorldMatrix(id); now = world.translation }
            catch { return "assert position: object \(check.key) world position unavailable: \(error)" }
            let dx = now.x - base.x, dy = now.y - base.y, dz = now.z - base.z
            let moved = (dx * dx + dy * dy + dz * dz).squareRoot()
            if let bound = check.within {
                guard moved <= bound else {
                    return "assert position: object \(check.key) sits \(moved) from \"\(check.from)\" at (\(now.x), \(now.y), \(now.z)), expected it held within \(bound)"
                }
                if let degrees = check.rotationWithin {
                    guard let base = capturedObjectRotations[check.from] else {
                        return "assert position: no captureObject rotation recorded under \"\(check.from)\""
                    }
                    // The angle of the difference rotation from atan2, which
                    // stays exact near zero where acos of a float dot product
                    // rounds one ulp below 1 to about 0.06 degrees.
                    let delta = simd_normalize(base).inverse * simd_normalize(world.rotationQuaternion)
                    let angle = 2 * atan2(simd_length(delta.imag), abs(delta.real)) * 180 / .pi
                    guard angle <= degrees else {
                        return "assert position: object \(check.key) turned \(angle)° from \"\(check.from)\", expected it held within \(degrees)°"
                    }
                }
            } else {
                guard moved > tolerance else {
                    return "assert position: object \(check.key) moved only \(moved) from \"\(check.from)\" — it did not move"
                }
            }
            return nil
        }

        /// ST-T11: a route's edit state readback (the document's edits, or the
        /// record's own state) and its playback record, which must always be
        /// the state's record: what the children follow is what is edited.
        func assertRoute(_ step: Step, details: inout [String]) -> String? {
            guard let check = step.route else { return nil }
            guard let id = objectID(key: check.key, copy: check.copy), let state = studio.sourceRouteState(id),
                  let runtime = studio.sourceRouteRuntime(id: id, document: studio.doc) else {
                return "assert route: \(check.key)\(check.copy.map { " copy \($0)" } ?? "") is not an imported route"
            }
            var problems: [String] = []
            if runtime.route != state.record(authored: runtime.authored) {
                problems.append("the playback record differs from the edit state")
            }
            let tolerance = check.within ?? 0.00001
            func near(_ a: SIMD3<Float>, _ b: [Float]?) -> Bool {
                guard let b, b.count == 3 else { return false }
                return simd_length(a - SIMD3(b[0], b[1], b[2])) <= tolerance
            }
            func text(_ v: SIMD3<Float>) -> String { "(\(v.x), \(v.y), \(v.z))" }
            let edited = studio.doc.object(id)?.sourceRoute != nil
            details.append("route \(check.key)\(check.copy.map { " copy \($0)" } ?? ""): \(state.points.count) points, edited \(edited), loop \(state.loop), line \(state.visibleLine), orientation \(state.orientation), colour \(state.color); "
                + state.points.enumerated().map { i, p in
                    "\(i)\(p.sourceIndex == nil ? "+" : ""): \(text(p.position)) rot \(text(p.rotationDegrees)) speed \(p.speed) ease \(p.easeType) \(p.isCurve ? "curve" : "line")\(p.linked ? " link" : "") aid \(text(p.aidPosition))\(p.aidInitialized ? "" : " (uninit)")"
                }.joined(separator: "; "))
            if let expected = check.points, state.points.count != expected { problems.append("\(state.points.count) points, expected \(expected)") }
            if let expected = check.keys, runtime.route.points.map(\.bone.sourceKey) != expected {
                problems.append("point keys \(runtime.route.points.map(\.bone.sourceKey)), expected \(expected)")
            }
            if let expected = check.aidKeys, runtime.route.points.map(\.aid.sourceKey) != expected {
                problems.append("aid keys \(runtime.route.points.map(\.aid.sourceKey)), expected \(expected)")
            }
            if let label = check.from {
                if let base = capturedRoutes[label] {
                    func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_length(a - b) <= tolerance }
                    if base.points.count != state.points.count { problems.append("\(state.points.count) points, \"\(label)\" has \(base.points.count)") }
                    for (i, (p, q)) in zip(state.points, base.points).enumerated() {
                        let same = close(p.position, q.position) && close(p.rotationDegrees, q.rotationDegrees) && close(p.scale, q.scale)
                            && close(p.aidPosition, q.aidPosition) && close(p.aidRotationDegrees, q.aidRotationDegrees) && close(p.aidScale, q.aidScale)
                            && abs(p.speed - q.speed) <= 0.000001 && p.easeType == q.easeType && p.connection == q.connection
                            && p.linked == q.linked && p.aidInitialized == q.aidInitialized
                        if !same { problems.append("point \(i) differs from \"\(label)\": \(p) vs \(q)") }
                    }
                    if state.loop != base.loop || state.visibleLine != base.visibleLine || state.orientation != base.orientation
                        || simd_length(state.color - base.color) > tolerance {
                        problems.append("settings differ from \"\(label)\"")
                    }
                } else { problems.append("no captureRoute state recorded under \"\(label)\"") }
            }
            if let expected = check.edited, edited != expected { problems.append("document edit \(edited), expected \(expected)") }
            if let expected = check.loop, state.loop != expected { problems.append("loop \(state.loop), expected \(expected)") }
            if let expected = check.line, state.visibleLine != expected { problems.append("line \(state.visibleLine), expected \(expected)") }
            if let expected = check.orientation, state.orientation != expected { problems.append("orientation \(state.orientation), expected \(expected)") }
            if let expected = check.rgb, !near(SIMD3(state.color.x, state.color.y, state.color.z), expected) {
                problems.append("colour \(state.color), expected \(expected)")
            }
            for expected in check.point ?? [] {
                guard state.points.indices.contains(expected.index) else { problems.append("no point \(expected.index)"); continue }
                let p = state.points[expected.index]
                if expected.position != nil, !near(p.position, expected.position) { problems.append("point \(expected.index) at \(text(p.position)), expected \(expected.position!)") }
                if expected.rotation != nil, !near(p.rotationDegrees, expected.rotation) { problems.append("point \(expected.index) rotation \(text(p.rotationDegrees)), expected \(expected.rotation!)") }
                if expected.aid != nil, !near(p.aidPosition, expected.aid) { problems.append("point \(expected.index) aid \(text(p.aidPosition)), expected \(expected.aid!)") }
                if let value = expected.aidInitialized, p.aidInitialized != value { problems.append("point \(expected.index) aid initialized \(p.aidInitialized), expected \(value)") }
                if let value = expected.speed, abs(p.speed - value) > 0.000001 { problems.append("point \(expected.index) speed \(p.speed), expected \(value)") }
                if let value = expected.ease, p.easeType != value { problems.append("point \(expected.index) ease \(p.easeType), expected \(value)") }
                if let value = expected.curve, p.isCurve != value { problems.append("point \(expected.index) curve \(p.isCurve), expected \(value)") }
                if let value = expected.link, p.linked != value { problems.append("point \(expected.index) link \(p.linked), expected \(value)") }
                if let value = expected.sourced, (p.sourceIndex != nil) != value { problems.append("point \(expected.index) sourced \(p.sourceIndex != nil), expected \(value)") }
            }
            return problems.isEmpty ? nil : "assert route: route \(check.key) " + problems.joined(separator: "; ")
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

        func assertPluginMount(_ step: Step, details: inout [String]) -> String? {
            guard let expected = step.pluginMount else { return nil }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            do {
                let actual = try encoder.encode(studio.sourcePluginMountSummary?.sections ?? [])
                guard actual == (try encoder.encode(expected)) else {
                    return "assert pluginMount: resident sections differ: \(String(decoding: actual, as: UTF8.self))"
                }
                details.append("pluginMount: \(String(decoding: actual, as: UTF8.self))")
                return nil
            } catch { return "assert pluginMount: \(error)" }
        }

        func assertAccessoryLabels(_ step: Step, details: inout [String]) -> String? {
            guard let check = step.accessoryLabels else { return nil }
            guard check.labels.count == 20 else { return "assert accessoryLabels: expected exactly 20 labels" }
            guard let object = studio.doc.objects.first(where: { $0.sourceObjectKey == check.key }),
                  let preview = studio.sourceShapePreview(for: object.id) else {
                return "assert accessoryLabels: source key \(check.key) is not a rendered character"
            }
            let actual = studio.sourceAccessoryLabels(for: object.id)
            guard actual.count == 20 else { return "assert accessoryLabels: received \(actual.count) labels, expected 20" }
            for (index, pair) in zip(actual, check.labels).enumerated() where !pair.0.utf8.elementsEqual(pair.1.utf8) {
                return "assert accessoryLabels: row \(index) is \(String(reflecting: pair.0)), expected \(String(reflecting: pair.1)) (UTF-8)"
            }
            let refs = (studio.doc.sourceNativePlugins ?? []).filter { $0.adapterID == SourceNativePluginPackage.accessoryAdapter && $0.enabled }
            guard studio.sourceAccessoryNamesEnabled == check.mounted, refs.count == (check.mounted ? 1 : 0) else {
                return "assert accessoryLabels: runtime mounted=\(studio.sourceAccessoryNamesEnabled), saved enabled references=\(refs.count), expected mounted=\(check.mounted)"
            }
            guard check.loadedSlots == preview.savedAccessorySlots else {
                return "assert accessoryLabels: loaded slots are \(preview.savedAccessorySlots), expected \(check.loadedSlots)"
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let references = (try? encoder.encode(refs)).flatMap { String(data: $0, encoding: .utf8) } ?? "<encoding failed>"
            details.append("accessoryLabels \(check.key): \(actual.map { String(reflecting: $0) }); coordinate \(preview.coordinate), loaded slots \(preview.savedAccessorySlots); native references \(references)")
            return nil
        }

        /// Synchronous label construction only: excludes SwiftUI layout/display,
        /// package loading, frame refresh, GPU work and all validation below.
        func measureAccessoryLabels(_ step: Step) {
            guard let count = step.index, (100...2_000).contains(count),
                  let id = object(step), let preview = studio.sourceShapePreview(for: id),
                  step.accessoryLabels?.key == step.key else {
                record(step, false, "measureAccessoryLabels: rendered key, matching accessoryLabels and index 100...2000 required"); return
            }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let beforeDocument = try encoder.encode(studio.doc)
                let beforeFrame = studio.host.renderer.currentFrame()
                let beforeTime = studio.sourceAnimationTime
                func resources() -> [Int] {
                    let value = studio.host.renderer.resources.statistics()
                    return [value.meshes, value.textures, value.deformBuffers, value.hiddenBuffers,
                        value.meshBufferBytes, value.deformBufferBytes, value.hiddenBufferBytes, value.retiring]
                }
                let beforeResources = resources()
                var samples: [Double] = []; samples.reserveCapacity(count)
                var labels: [[String]] = []; labels.reserveCapacity(count)
                for _ in 0..<count {
                    let start = ProcessInfo.processInfo.systemUptime
                    let value = studio.sourceAccessoryLabels(for: id)
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    samples.append(elapsed * 1_000); labels.append(value)
                }
                // Consume every returned value after timing; no optimizer-only sink
                // or validation/serialization cost enters the recorded interval.
                let expected = step.accessoryLabels!.labels
                let labelsMatch = labels.allSatisfy { value in
                    value.count == expected.count && zip(value, expected).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
                }
                let afterFrame = studio.host.renderer.currentFrame()
                let sameFrame = beforeFrame.camera == afterFrame.camera && beforeFrame.mainLight == afterFrame.mainLight
                    && beforeFrame.effects == afterFrame.effects && beforeFrame.lights == afterFrame.lights
                    && beforeFrame.sceneBounds == afterFrame.sceneBounds && beforeFrame.time == afterFrame.time
                    && beforeFrame.skinSets == afterFrame.skinSets && beforeFrame.gizmos.count == afterFrame.gizmos.count
                    && beforeFrame.items.count == afterFrame.items.count && zip(beforeFrame.items, afterFrame.items).allSatisfy {
                        $0.mesh == $1.mesh && $0.model == $1.model && $0.objectID == $1.objectID && $0.material == $1.material
                    }
                var details: [String] = []
                let problem = assertAccessoryLabels(step, details: &details)
                let unchanged = beforeDocument == (try encoder.encode(studio.doc))
                    && studio.sourceShapePreview(for: id) === preview && resources() == beforeResources
                    && studio.sourceAnimationTime == beforeTime && sameFrame
                let sorted = Array(samples.dropFirst()).sorted()
                let detail = "synchronous label construction ms: first=\(samples[0]), warm median=\(sorted[sorted.count / 2]), p95=\(sorted[Int(Double(sorted.count - 1) * 0.95)]), count=\(count); mounted=\(studio.sourceAccessoryNamesEnabled); all UTF-8 labels match=\(labelsMatch), document/preview/resources/sampled frame fields unchanged=\(unchanged); resources=\(beforeResources)"
                record(step, problem == nil && labelsMatch && unchanged, detail + (problem.map { "; " + $0 } ?? ""))
            } catch { record(step, false, "measureAccessoryLabels: \(error)") }
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
            let edited = object.sourceClothesState != nil || object.sourceShowAccessory != nil || object.sourceShoesType != nil
            let drawn = preview.drawnClothingMeshes
            func list<T>(_ values: [T]) -> String { "[" + values.map { "\($0)" }.joined(separator: ",") + "]" }
            details.append("clothes \(check.key): state \(list(preview.clothesState)), saved \(list(preview.savedWear.clothesState)), loaded \(list(preview.loadedClothesState)), shoesType \(preview.shoesType) (saved \(preview.savedWear.shoesType)); garments drawn \(list(evaluation.renderedClothing)) of \(list(preview.wearLayout.clothingKinds)); clothing renderers drawn \(list(drawn)); accessories drawn \(list(evaluation.renderedAccessories)), off \(list(off)); body alpha (\(evaluation.bodyAlpha.x), \(evaluation.bodyAlpha.y)); document edited \(edited); fallbacks \(evaluation.fallbacks)")
            var problems: [String] = []
            if let expected = check.state, preview.clothesState.map(Int.init) != expected { problems.append("state is \(list(preview.clothesState)), expected \(list(expected))") }
            if let expected = check.saved, preview.savedWear.clothesState.map(Int.init) != expected { problems.append("saved state is \(list(preview.savedWear.clothesState)), expected \(list(expected))") }
            if let expected = check.rendered, evaluation.renderedClothing != expected.sorted() { problems.append("drawn garments are \(list(evaluation.renderedClothing)), expected \(list(expected.sorted()))") }
            if let expected = check.accessories, evaluation.renderedAccessories != expected.sorted() { problems.append("drawn accessories are \(list(evaluation.renderedAccessories)), expected \(list(expected.sorted()))") }
            if let expected = check.accessoriesOff, off != expected.sorted() { problems.append("hidden accessory slots are \(list(off)), expected \(list(expected.sorted()))") }
            if let expected = check.edited, edited != expected { problems.append("document wear edit is \(edited), expected \(expected)") }
            if let expected = check.fallbacks, evaluation.fallbacks.count != expected { problems.append("\(evaluation.fallbacks.count) fallbacks, expected \(expected)") }
            if let expected = check.shoesType, preview.shoesType != expected { problems.append("shoesType is \(preview.shoesType), expected \(expected)") }
            if let expected = check.savedShoesType, preview.savedWear.shoesType != expected { problems.append("saved shoesType is \(preview.savedWear.shoesType), expected \(expected)") }
            if let expected = check.drawn, drawn != expected.sorted() { problems.append("drawn clothing renderers are \(list(drawn)), expected \(list(expected.sorted()))") }
            if let expected = check.bodyAlpha, [evaluation.bodyAlpha.x, evaluation.bodyAlpha.y] != expected { problems.append("body alpha is (\(evaluation.bodyAlpha.x), \(evaluation.bodyAlpha.y)), expected \(list(expected))") }
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

        /// The preconditions and pixel scan `dragGizmo` and `hoverGizmo`
        /// share: the step names the selected FK guide (`setPoseMode fk`,
        /// `selectBone`) and an axis ring the view shows. Records the failure
        /// and returns nil otherwise.
        func locateGuideAxis(_ step: Step) -> (id: UUID, boneID: Int32, axis: GizmoAxis, axisName: String, anchor: SIMD2<Float>, start: SIMD2<Float>)? {
            let op = step.op
            guard let id = object(step) else { record(step, false, "\(op): no object with source key \(step.key ?? -1)"); return nil }
            guard let boneID = step.bone, let axisName = step.axis else {
                record(step, false, "\(op): bone and axis (\"x\", \"y\" or \"z\") are required"); return nil
            }
            guard let axis = GizmoAxis(rawValue: ["x": 1, "y": 2, "z": 3][axisName] ?? -1) else {
                record(step, false, "\(op): unknown axis \"\(axisName)\", expected \"x\", \"y\" or \"z\""); return nil
            }
            // The real handlers only reach the guide path through this
            // state, so say so here instead of reporting a bare miss
            // after the pixel scan.
            guard studio.poseMode == .fk else {
                record(step, false, "\(op): pose mode is \(studio.poseMode.rawValue), run setPoseMode fk first"); return nil
            }
            guard studio.selection == id, let node = studio.selectedBone,
                  let preview = studio.sourceShapePreview(for: id),
                  preview.controller.targets.contains(where: { $0.node == node && $0.bone.id == Int(boneID) && $0.hasGuide }) else {
                record(step, false, "\(op): source key \(step.key!) bone \(boneID) is not the selected guide (run selectBone first)"); return nil
            }
            guard let anchor = studio.sourceGuidePixel(of: Int(boneID)) else {
                record(step, false, "\(op): bone \(boneID) does not project into the view camera"); return nil
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
                record(step, false, "\(op): no pixel within ±120 px of bone \(boneID)'s projection (\(anchor.x), \(anchor.y)) picks axis \(axisName) (id \(wanted)); "
                    + (seen.isEmpty ? "the scan sees no axis ring at all (anchor pixel picks \(picked(anchor)))"
                                    : "the scan sees \(seen.joined(separator: " and ")) but not the \(axisName) ring (edge-on to the camera?)"))
                return nil
            }
            return (id, boneID, axis, axisName, anchor, start)
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
            case "loadNativePlugin":
                guard studio.isActiveMode, let path = step.path ?? ProcessInfo.processInfo.environment["IKKOKU_NATIVE_PLUGIN_MANIFEST"] else {
                    record(step, false, "loadNativePlugin: active Studio and path or IKKOKU_NATIVE_PLUGIN_MANIFEST required"); continue
                }
                do {
                    try studio.loadSourceNativePlugin(url: URL(fileURLWithPath: path))
                    record(step, true, studio.status)
                } catch { record(step, false, "loadNativePlugin: \(error)") }
            case "unloadPlugins":
                guard studio.isActiveMode else { record(step, false, "unloadPlugins: Studio must be active"); continue }
                studio.unloadSourcePluginsInteractively()
                record(step, studio.doc.sourceNativePlugins == nil && !studio.sourceAccessoryNamesEnabled, studio.status)
            case "measureAccessoryLabels":
                measureAccessoryLabels(step)
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
            case "setClothesState", "setAccessoryVisible", "setShoesType":
                let op = step.op
                guard let id = object(step) else { record(step, false, "\(op): no object with source key \(step.key ?? -1)"); continue }
                let index = step.index ?? 0
                guard op == "setShoesType" || step.index != nil else { record(step, false, "\(op): index (the clothes row 0...7 or accessory slot 0...19) is required"); continue }
                guard op == "setAccessoryVisible" ? step.on != nil : step.state != nil else {
                    record(step, false, op == "setAccessoryVisible" ? "setAccessoryVisible: on is required" : "\(op): state is required"); continue
                }
                // The Clothes tab's rows, shoes-type buttons and accessory
                // toggles call the same StudioModel methods, so the lane
                // drives the app's path.
                let before = (studio.doc.object(id)?.sourceClothesState, studio.doc.object(id)?.sourceShowAccessory,
                              studio.sourceShapePreview(for: id).map { ($0.clothesState, $0.showAccessory, ObjectIdentifier($0), $0.shoesType) },
                              studio.doc.object(id)?.sourceShoesType)
                do {
                    if op == "setAccessoryVisible" { try studio.setSourceAccessoryVisible(id, slot: index, visible: step.on!) }
                    else if op == "setShoesType" { try studio.setSourceShoesType(id, type: step.state!) }
                    else { try studio.setSourceClothesState(id, kind: index, state: step.state!) }
                    if let expected = step.errorContains {
                        record(step, false, "\(op): the edit was accepted, expected a refusal containing \"\(expected)\"")
                    } else {
                        let preview = studio.sourceShapePreview(for: id), object = studio.doc.object(id)
                        record(step, true, "source key \(step.key!) \(op) \(index) -> \(step.state.map(String.init) ?? String(step.on!)); rendered state \(preview.map { $0.clothesState.map(String.init).joined(separator: ",") } ?? "none"), shoesType \(preview.map { String($0.shoesType) } ?? "none"), drawn garments \(preview.map { $0.wearEvaluation.renderedClothing.map(String.init).joined(separator: ",") } ?? "none"), drawn accessories \(preview.map { $0.wearEvaluation.renderedAccessories.map(String.init).joined(separator: ",") } ?? "none"), document edited \(object?.sourceClothesState != nil || object?.sourceShowAccessory != nil || object?.sourceShoesType != nil)")
                    }
                } catch {
                    guard let expected = step.errorContains else { record(step, false, "\(op): \(error)"); continue }
                    let after = studio.sourceShapePreview(for: id)
                    let unchanged = studio.doc.object(id)?.sourceClothesState == before.0 && studio.doc.object(id)?.sourceShowAccessory == before.1
                        && studio.doc.object(id)?.sourceShoesType == before.3
                        && after.map(ObjectIdentifier.init) == before.2?.2 && after?.clothesState == before.2?.0 && after?.showAccessory == before.2?.1
                        && after?.shoesType == before.2?.3
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
                guard let pixels = step.pixels, pixels.count == 2, pixels.allSatisfy({ $0.isFinite }) else {
                    record(step, false, "dragGizmo: bone, axis (\"x\", \"y\" or \"z\") and pixels [dx, dy] are required"); continue
                }
                guard let located = locateGuideAxis(step) else { continue }
                let (id, boneID, axisName, start) = (located.id, located.boneID, located.axisName, located.start)
                func picked(_ p: SIMD2<Float>) -> UInt32 { studio.pickID(at: p) }
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
            case "hoverGizmo":
                // R7 phase 2, item 5: the REAL `mouseMoved` hover, which picks
                // asynchronously for the latest position only. Moves go over
                // the guide's ring and off it, partly faster than a pick
                // completes; `settleHoverPicks` (what a click does first) then
                // applies what the app's own completion path decides. The
                // highlight is read from the frame the app built.
                guard let located = locateGuideAxis(step) else { continue }
                let start = located.start, ringID = PickIDs.gizmo(located.axis)
                // An off-gizmo pixel: the first corner of the scan box that picks no axis.
                let corners: [SIMD2<Float>] = [SIMD2(-120, -120), SIMD2(120, -120), SIMD2(-120, 120), SIMD2(120, 120)]
                guard let off = corners.map({ located.anchor + $0 }).first(where: { PickIDs.axis(from: studio.pickID(at: $0)) == nil }) else {
                    record(step, false, "hoverGizmo: every corner of the ±120 px box around bone \(located.boneID) picks a gizmo axis"); continue
                }
                /// The gizmo-axis batches of the current frame drawn in the highlight color.
                func highlighted() -> [UInt32] {
                    let hi = simd_make_float3(GizmoBuilder.highlightColor)
                    return studio.frame.gizmos.filter { batch in
                        PickIDs.axis(from: batch.objectID) != nil && batch.vertices.contains { simd_make_float3($0.color) == hi }
                    }.map(\.objectID)
                }
                func axisText(_ a: GizmoAxis?) -> String { a.map { "\($0)" } ?? "none" }
                let before = studio.hoverPickStatistics
                var failures: [String] = []
                var phases: [String] = []
                func expectHover(_ label: String, axis: GizmoAxis?, at p: SIMD2<Float>) {
                    guard studio.settleHoverPicks() else { failures.append("\(label): no hover pick result within 2 s"); return }
                    let hovered = studio.hoveredGizmoAxis, lit = highlighted()
                    // What the synchronous pick (the pre-item-5 hover) finds at the final position.
                    let synchronous = PickIDs.axis(from: studio.pickID(at: p))
                    phases.append("\(label): hover \(axisText(hovered)), highlighted ids \(lit.map { String($0, radix: 16) }), synchronous pick \(axisText(synchronous))")
                    if hovered != axis || hovered != synchronous { failures.append("\(label): hover \(axisText(hovered)), expected \(axisText(axis)) (synchronous pick \(axisText(synchronous)))") }
                    if lit != (axis == nil ? [] : [ringID]) { failures.append("\(label): highlighted ids \(lit), expected \(axis == nil ? [] : [ringID])") }
                }
                // Over the ring, off it and back without waiting: one pick runs,
                // the later moves wait, the first result is stale (it answers
                // the first move) and the last move's applies.
                studio.mouseMoved(to: start); studio.mouseMoved(to: off); studio.mouseMoved(to: start)
                expectHover("on-off-on", axis: located.axis, at: start)
                studio.mouseMoved(to: off)
                expectHover("off", axis: nil, at: off)
                // Onto the ring and straight off: the ring's result arrives
                // stale and is dropped, so the highlight never lights.
                studio.mouseMoved(to: start); studio.mouseMoved(to: off)
                expectHover("on-off", axis: nil, at: off)
                let after = studio.hoverPickStatistics
                let moves = after.moves - before.moves, coalesced = after.coalesced - before.coalesced
                let issued = after.issued - before.issued, applied = after.applied - before.applied, stale = after.stale - before.stale
                if moves != 6 || coalesced != 3 || stale < 2 || applied != 3 {
                    failures.append("hover picks: \(moves) moves, \(coalesced) coalesced, \(issued) issued, \(applied) applied, \(stale) stale; expected 6 moves, 3 coalesced, 3 applied and at least 2 stale")
                }
                record(step, failures.isEmpty, (failures.isEmpty ? "" : failures.joined(separator: "; ") + " | ")
                    + "ring pixel (\(start.x), \(start.y)), off pixel (\(off.x), \(off.y)); " + phases.joined(separator: "; ")
                    + "; hover picks: \(moves) moves, \(coalesced) coalesced, \(issued) issued, \(applied) applied, \(stale) stale")
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
                guard let id = object(step) else { record(step, false, "captureObject: no object \(describe(step))"); continue }
                guard let label = step.name, !label.isEmpty else {
                    record(step, false, "captureObject: name (the capture label) is required"); continue
                }
                do {
                    let world = try studio.sourceObjectWorldMatrix(id), position = world.translation
                    capturedObjectPositions[label] = position
                    capturedObjectRotations[label] = world.rotationQuaternion
                    record(step, true, "captured object \(describe(step)) world position (\(position.x), \(position.y), \(position.z)) as \"\(label)\"")
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
            case "editDuringAdvance":
                // R7 phase 2, item 3: the live step starts the way the timer
                // starts it, off the main thread; the edit lands through the
                // app's own method while the step is in flight; the step then
                // completes as its completion handler completes it. The step
                // commits before the edit, the clock moves exactly one step,
                // and the presented frame is byte-identical to a full
                // main-thread rebuild of the edited document at that clock.
                // The reuse count is the contract: every frame without an
                // edit, every frame but the moved character's after a
                // document-only edit, none once the edit reached a preview.
                let edit = step.edit ?? ""
                var target: UUID?
                switch edit {
                case "none":
                    break
                case "undo", "redo":
                    guard !(edit == "undo" ? studio.undoStack : studio.redoStack).isEmpty else {
                        record(step, false, "editDuringAdvance: the \(edit) stack is empty"); continue
                    }
                case "move", "setFK":
                    guard let id = object(step) else {
                        record(step, false, "editDuringAdvance: no object with source key \(step.key ?? -1)"); continue
                    }
                    if edit == "setFK" {
                        guard step.bone != nil, let rotation = step.rotation, rotation.count == 3, rotation.allSatisfy({ $0.isFinite }) else {
                            record(step, false, "editDuringAdvance: setFK needs bone and rotation [3 finite degrees]"); continue
                        }
                    }
                    target = id
                default:
                    record(step, false, "editDuringAdvance: edit must be none, move, setFK, undo or redo"); continue
                }
                let clock = studio.sourceAnimationTime
                guard studio.startLiveFrameAsTimer() else {
                    record(step, false, "editDuringAdvance: the live step ran on the main thread, so no edit could land during it"); continue
                }
                let requested = studio.lastLiveStepFrameRequests
                switch edit {
                case "move": studio.update(target!) { $0.transform.position.x += 0.25 }
                case "setFK":
                    let rotation = step.rotation!
                    studio.setSourceFKRotation(target!, boneID: Int(step.bone!), degrees: Float3(rotation[0], rotation[1], rotation[2]))
                case "undo": studio.undo()
                case "redo": studio.redo()
                default: break
                }
                studio.completeLiveFrame()
                let reused = studio.lastRefreshLiveFramesReused
                guard let raced = captureStudioRender(), let racedBytes = renderBytes(raced) else {
                    record(step, false, "editDuringAdvance: the presented frame did not render"); continue
                }
                studio.refresh()
                guard let rebuilt = captureStudioRender(), let rebuiltBytes = renderBytes(rebuilt) else {
                    record(step, false, "editDuringAdvance: the rebuilt frame did not render"); continue
                }
                let difference = pixelDifference(racedBytes, rebuiltBytes)
                let expectedReuse = edit == "none" ? requested : edit == "move" ? requested - 1 : 0
                var problems: [String] = []
                if studio.sourceAnimationTime.bitPattern != (clock + 1 / 30).bitPattern {
                    problems.append("clock \(clock) moved to \(studio.sourceAnimationTime), not one 1/30 s step")
                }
                if difference.exactChanged != 0 {
                    problems.append("\(difference.exactChanged) pixels differ from a main-thread rebuild (max channel delta \(difference.maximum))")
                }
                if requested == 0 || reused != expectedReuse {
                    problems.append("the presenting refresh reused \(reused) of \(requested) step frames, expected \(expectedReuse)")
                }
                record(step, problems.isEmpty, problems.isEmpty
                    ? "edit \(edit) landed while the live step ran off the main thread; clock \(clock) -> \(studio.sourceAnimationTime); the presenting refresh reused \(reused) of \(requested) step frames; its \(renderSide)x\(renderSide) render is byte-identical to a main-thread rebuild"
                    : "editDuringAdvance (\(edit)): " + problems.joined(separator: "; "))
            case "backgroundBuild":
                // R7 phase 2, item 6: interactive runs build source characters
                // in the background, while captures and scenarios build them
                // synchronously. This op runs one operation synchronously
                // first, then with background builds through the app's own
                // methods, waits on the main run loop until every build is
                // installed, and compares the document summary and a 512²
                // render, which must be byte-identical. Live animation is
                // paused for the op, so the timer fires while it waits move
                // no clock. The `WhileHidden` builds hide the Studio as a
                // switch to the Maker does, with a stand-in for the Maker's
                // frame on the shared renderer, which the builds landing
                // meanwhile must leave in place; showing the Studio again
                // refreshes it, as the mode switch does.
                let build = step.build ?? ""
                let builds = ["import", "importTwice", "importThenNewScene", "importWhileHidden", "duplicate", "duplicateWhileHidden"]
                guard builds.contains(build) else {
                    record(step, false, "backgroundBuild: build must be one of \(builds.joined(separator: ", "))"); continue
                }
                guard let scenePath = ProcessInfo.processInfo.environment["IKKOKU_SOURCE_SCENE"] else {
                    record(step, false, "backgroundBuild: needs the IKKOKU_SOURCE_SCENE startup import"); continue
                }
                let wasLive = studio.liveAnimation
                studio.liveAnimation = false
                defer { studio.liveAnimation = wasLive; studio.asyncSourceBuilds = false }
                func summary() -> [String] {
                    let position = Dictionary(uniqueKeysWithValues: studio.doc.objects.enumerated().map { ($1.id, $0) })
                    var lines = studio.doc.objects.map { o in
                        "\(treeLabel(o)) \(o.kind) \"\(o.name)\" parent \(o.parent.flatMap { position[$0] }.map { String($0) } ?? "-") visible \(studio.doc.isVisible(o.id))"
                    }
                    lines += (studio.doc.sourcePreviewDiagnostics ?? []).map { "diagnostic: \($0)" }
                    let outcome = studio.sourcePreviewCharacterOutcome(), counts = studio.sourceRuntimeCounts()
                    lines.append("status: \(studio.status)")
                    lines.append("characters built \(outcome.built), retained \(outcome.retained.count); cameras \(counts.cameras), items \(counts.items), routes \(counts.routes), scene light \(counts.sceneLight)")
                    return lines
                }
                func state() -> (summary: [String], pixels: [UInt8]?) { (summary(), captureStudioRender().flatMap(renderBytes)) }
                /// Runs the main run loop until no background build is left.
                func settle() -> Bool {
                    let deadline = Date().addingTimeInterval(300)
                    while studio.isLoadingSourceScene || studio.pendingSourceCharacterBuilds > 0 {
                        if Date() > deadline { return false }
                        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
                    }
                    return true
                }
                var problems: [String] = []
                let hidden = build.hasSuffix("WhileHidden")
                /// What `AppState.mode` does for the Maker, with an empty
                /// frame standing in for the Maker's.
                func hide() {
                    studio.isActiveMode = false
                    var stand = studio.host.renderer.currentFrame()
                    stand.items = []; stand.skinSets = [:]; stand.gizmos = []
                    studio.host.renderer.submit(stand)
                }
                func show(_ label: String) {
                    if !studio.host.renderer.currentFrame().items.isEmpty {
                        problems.append("\(label): a build replaced the frame shown while the Studio was hidden")
                    }
                    studio.isActiveMode = true
                    studio.refresh()
                }
                func compare(_ label: String, _ expected: (summary: [String], pixels: [UInt8]?), _ actual: (summary: [String], pixels: [UInt8]?)) {
                    if expected.summary != actual.summary {
                        let first = zip(expected.summary, actual.summary).first { $0 != $1 }
                        problems.append("\(label): the document differs from the synchronous build: "
                            + (first.map { "\"\($0.0)\" against \"\($0.1)\"" } ?? "\(expected.summary.count) against \(actual.summary.count) lines"))
                    }
                    guard let a = expected.pixels, let b = actual.pixels else { problems.append("\(label): a frame did not render"); return }
                    let difference = pixelDifference(a, b)
                    if difference.exactChanged != 0 {
                        problems.append("\(label): \(difference.exactChanged) pixels differ from the synchronous build (max channel delta \(difference.maximum))")
                    }
                }
                var detail = ""
                do {
                    guard let rig = try EngineHost.locateSourceAvatar() else {
                        throw RigError.invalid("Export the original clothed avatar before previewing source scenes.")
                    }
                    let catalog = EngineHost.studioPoseContract(forRig: rig), url = URL(fileURLWithPath: scenePath)
                    if build.hasPrefix("duplicate") {
                        guard let id = object(step) else { record(step, false, "backgroundBuild: no object \(describe(step))"); continue }
                        studio.selection = id
                        studio.duplicateSelection()
                        let syncCopy = state()
                        studio.undo()
                        let syncUndo = state()
                        studio.asyncSourceBuilds = true
                        studio.selection = id
                        studio.duplicateSelection()
                        let copies = studio.pendingSourceCharacterBuilds
                        if hidden { hide() }
                        guard settle() else { record(step, false, "backgroundBuild: the duplicate's builds did not finish in 300 s"); continue }
                        if hidden { show("duplicate") }
                        compare("duplicate", syncCopy, state())
                        studio.undo()
                        let rebuilds = studio.pendingSourceCharacterBuilds
                        if hidden { hide() }
                        guard settle() else { record(step, false, "backgroundBuild: the undo's rebuilds did not finish in 300 s"); continue }
                        if hidden { show("undo") }
                        compare("undo", syncUndo, state())
                        if copies == 0 { problems.append("the duplicate built no character in the background") }
                        if rebuilds == 0 { problems.append("the undo rebuilt no character in the background") }
                        detail = "the duplicate built \(copies) and the undo rebuilt \(rebuilds) characters in the background"
                    } else {
                        try studio.importSourceScenePreview(sceneURL: url, rigURL: rig, boneCatalogURL: catalog)
                        let reference = state()
                        studio.asyncSourceBuilds = true
                        var outcomes: [String] = []
                        var committed: (summary: [String], pixels: [UInt8]?)?
                        func begin(_ label: String) throws {
                            try studio.beginSourceSceneImport(sceneURL: url, rigURL: rig, boneCatalogURL: catalog) { result in
                                switch result {
                                case .success:
                                    outcomes.append("\(label) committed")
                                    // At once, before any later timer fire.
                                    committed = state()
                                case .failure(let error): outcomes.append("\(label) failed: \(error)")
                                }
                            }
                        }
                        try begin("first")
                        if !studio.isLoadingSourceScene { problems.append("the import did not run in the background") }
                        if summary() != reference.summary { problems.append("the document changed before the commit") }
                        if hidden { hide() }
                        if build == "importThenNewScene" {
                            studio.newScene()
                            if studio.isLoadingSourceScene { problems.append("New Scene left the import running") }
                        } else if build == "importTwice" {
                            try begin("second")
                        }
                        guard settle() else { record(step, false, "backgroundBuild: the import did not finish in 300 s"); continue }
                        // A callback the cancel failed to stop would be queued by now.
                        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.5))
                        if hidden {
                            show("import")
                            committed = state()
                        }
                        let expected = build == "importThenNewScene" ? [] : [build == "importTwice" ? "second committed" : "first committed"]
                        if outcomes != expected { problems.append("completions \(outcomes), expected \(expected)") }
                        if build == "importThenNewScene" {
                            if !studio.doc.objects.isEmpty { problems.append("the cancelled import reached the document: \(studio.doc.objects.count) objects") }
                        } else if let committed {
                            compare("import", reference, committed)
                        }
                        detail = "completions \(outcomes.isEmpty ? "none" : outcomes.joined(separator: ", ")); \(studio.doc.objects.count) objects"
                    }
                    if studio.sourceBuildProgress != nil { problems.append("the progress line stayed after the builds") }
                } catch {
                    record(step, false, "backgroundBuild (\(build)) failed, stopping: \(error)")
                    break scenarioLoop
                }
                let claim = build == "importThenNewScene"
                    ? "New Scene cancelled the background import and nothing reached the document"
                    : "\(build) with background builds matches the synchronous build (document summary and \(renderSide)x\(renderSide) render byte-identical)"
                        + (hidden ? ", and the frame shown while the Studio was hidden stayed" : "")
                record(step, problems.isEmpty, problems.isEmpty
                    ? "\(claim); \(detail)"
                    : "backgroundBuild (\(build)): " + problems.joined(separator: "; "))
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
            case "setShowSourceMap":
                // View ▸ Show Source Map (ST-A11): runtime only, the document never changes.
                guard let on = step.on else { record(step, false, "setShowSourceMap: on is required"); continue }
                studio.showSourceMap = on
                record(step, true, "show source map \(on)")
            case "setAutomaticBlink":
                guard let on = step.on else { record(step, false, "setAutomaticBlink: on is required"); continue }
                // The Studio toggle's own property; its didSet forwards to
                // every rendered character's preview.
                studio.sourceAutomaticBlink = on
                record(step, true, "source automatic blink \(on)")
            case "delete":
                // The workspace's Delete button / key: select, then delete
                // the selection with its subtree.
                guard let id = object(step) else { record(step, false, "delete: no object with source key \(step.key ?? -1)"); continue }
                studio.selection = id
                studio.deleteSelection()
                let gone = studio.doc.object(id) == nil
                record(step, gone, gone ? "deleted source key \(step.key!) and its subtree (\(studio.doc.objects.count) objects left)"
                                        : "delete: source key \(step.key!) is still in the document")
            case "setParent":
                // The inspector's Parent picker (`StudioModel.setParent`).
                guard let id = object(step) else { record(step, false, "setParent: no object \(describe(step))"); continue }
                guard let target = step.parent else { record(step, false, "setParent: parent (a source key or null for the root) is required"); continue }
                var parentID: UUID?
                if let target {
                    guard let found = studio.doc.objects.first(where: { $0.sourceObjectKey == target })?.id else {
                        record(step, false, "setParent: no parent with source key \(target)"); continue
                    }
                    parentID = found
                }
                studio.setParent(id, to: parentID)
                let placed = studio.doc.object(id)?.parent == parentID
                record(step, placed, placed ? "\(describe(step)) now under \(target.map { "source key \($0)" } ?? "the root"): \(studio.status)"
                                            : "setParent: \(describe(step)) was not moved: \(studio.status)")
            case "duplicate":
                // The workspace's Duplicate button: select, then duplicate the
                // selection (a source object duplicates with its subtree).
                guard let id = object(step) else { record(step, false, "duplicate: no object \(describe(step))"); continue }
                studio.selection = id
                let before = studio.doc.objects.count
                studio.duplicateSelection()
                let added = studio.doc.objects.count - before
                record(step, added > 0, added > 0 ? "duplicated \(describe(step)): \(added) objects added; \(studio.status)"
                                                  : "duplicate: nothing was added: \(studio.status)")
            case "timeDuplicate":
                // Release timing probe (not a lane check): `index` rounds of
                // Duplicate then Undo on one object. Each round times the
                // whole command on the main thread, the document refreshes
                // and a copied character's preview build included; GPU
                // uploads on the render thread are not in it.
                guard let id = object(step) else { record(step, false, "timeDuplicate: no object \(describe(step))"); continue }
                let rounds = max(1, min(step.index ?? 20, 200))
                var samples: [Double] = [], added = 0
                for _ in 0..<rounds {
                    studio.selection = id
                    let before = studio.doc.objects.count
                    let start = ProcessInfo.processInfo.systemUptime
                    studio.duplicateSelection()
                    samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                    added = studio.doc.objects.count - before
                    studio.undo()
                }
                let sorted = samples.sorted()
                let summary = String(format: "median %.2f ms, p90 %.2f ms, max %.2f ms", sorted[sorted.count / 2],
                                     sorted[min(sorted.count - 1, sorted.count * 9 / 10)], sorted.last!)
                record(step, added > 0, "timeDuplicate \(describe(step)): \(rounds) rounds, \(added) objects per copy; \(summary)")
            case "addFolder", "addCamera", "addLight":
                // The workspace's add menu; `name` renames the new object.
                let before = studio.doc.objects.count
                switch step.op {
                case "addFolder": studio.addFolder()
                case "addCamera": studio.addCamera()
                default:
                    guard let kind = step.mode.flatMap(LightKind.init(rawValue:)) else {
                        record(step, false, "addLight: mode must be directional, point or spot"); continue
                    }
                    studio.addLight(kind)
                }
                guard studio.doc.objects.count == before + 1, let id = studio.doc.objects.last?.id else {
                    record(step, false, "\(step.op): nothing was added"); continue
                }
                if let name = step.name, !name.isEmpty { studio.update(id) { $0.name = name } }
                record(step, true, "\(step.op): added \"\(studio.doc.object(id)!.name)\" under \(studio.doc.object(id)!.parent == nil ? "the root" : "a folder")")
            case "exportRejected":
                // Export must refuse with this fragment and write no file.
                guard let path = step.path, let url = insideLocal(path), !isSourcePath(url) else {
                    record(step, false, "exportRejected: path must stay under .local/ and differ from the source: \(step.path ?? "<missing>")"); continue
                }
                guard let expected = step.errorContains, !expected.isEmpty else {
                    record(step, false, "exportRejected: errorContains must be nonempty"); continue
                }
                if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
                do {
                    try studio.exportSourceScene(to: url)
                    record(step, false, "exportRejected: export succeeded, expected a refusal containing \"\(expected)\"")
                } catch {
                    let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    let refused = text.contains(expected) && !FileManager.default.fileExists(atPath: url.path)
                    record(step, refused, refused ? "export refused as expected: \(text)" : "exportRejected: expected \"\(expected)\" and no file; received \(text)")
                }
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
            case "focus":
                // The F key: select the object and frame the view on it;
                // `dy`, if given, is then one scroll-wheel dolly of that delta.
                guard let id = object(step) else { record(step, false, "focus: no object \(describe(step))"); continue }
                studio.selection = id
                studio.focusSelection()
                if let dy = step.dy, dy.isFinite { studio.scrolled(delta: SIMD2<Float>(0, dy), modifiers: NSEvent.ModifierFlags()) }
                record(step, true, "focused \(describe(step)): camera target (\(studio.doc.camera.target.x), \(studio.doc.camera.target.y), \(studio.doc.camera.target.z)), distance \(studio.doc.camera.distance)")
            case "selectRoutePoint":
                // ST-T11: a click on the route point (or aid) handle the
                // selected route draws, through the view's mouseDown/mouseUp.
                guard let id = object(step), studio.sourceRouteState(id) != nil else {
                    record(step, false, "selectRoutePoint: \(describe(step)) is not an imported route"); continue
                }
                guard let index = step.index else { record(step, false, "selectRoutePoint: index is required"); continue }
                studio.selection = id
                let wanted = SourceRoutePointSelection(index: index, aid: step.aid ?? false)
                guard let pixel = studio.sourceRouteHandlePixel(id, point: wanted) else {
                    record(step, false, "selectRoutePoint: handle \(index)\(wanted.aid ? " aid" : "") does not project into the view"); continue
                }
                let picked = studio.pickID(at: pixel)
                studio.mouseDown(at: pixel, button: 0, modifiers: NSEvent.ModifierFlags())
                studio.mouseUp(at: pixel, button: 0, modifiers: NSEvent.ModifierFlags())
                let selected = studio.selectedSourceRoutePoint
                record(step, selected == wanted, selected == wanted
                    ? "clicked route \(describe(step)) handle \(index)\(wanted.aid ? " aid" : "") at pixel (\(pixel.x), \(pixel.y)), picked id \(String(picked, radix: 16)): \(studio.status)"
                    : "selectRoutePoint: pixel (\(pixel.x), \(pixel.y)) picked id \(String(picked, radix: 16)); selected point reads \(String(describing: selected))")
            case "dragRoutePoint":
                // ST-T11: a drag of the selected handle's guide axis through
                // the view's own mouseDown/mouseDragged/mouseUp.
                guard let id = object(step), let before = studio.sourceRouteState(id), studio.selection == id,
                      let point = studio.selectedSourceRoutePoint else {
                    record(step, false, "dragRoutePoint: run selectRoutePoint on \(describe(step)) first"); continue
                }
                guard let axisName = step.axis, let axis = GizmoAxis(rawValue: ["x": 1, "y": 2, "z": 3][axisName] ?? -1),
                      let pixels = step.pixels, pixels.count == 2, pixels.allSatisfy({ $0.isFinite }) else {
                    record(step, false, "dragRoutePoint: axis (\"x\", \"y\" or \"z\") and pixels [dx, dy] are required"); continue
                }
                let candidates = studio.sourceRouteGuidePixels(axis: axis)
                guard let start = candidates.first(where: { studio.pickID(at: $0) == PickIDs.gizmo(axis) }) else {
                    record(step, false, "dragRoutePoint: none of \(candidates.count) pixels on the \(axisName) guide picks it"); continue
                }
                let noModifiers = NSEvent.ModifierFlags()
                let undoDepth = studio.undoStack.count
                studio.mouseDown(at: start, button: 0, modifiers: noModifiers)
                guard studio.undoStack.count == undoDepth + 1 else {
                    studio.mouseUp(at: start, button: 0, modifiers: noModifiers)
                    record(step, false, "dragRoutePoint: mouseDown on the \(axisName) guide grabbed nothing"); continue
                }
                var previous = start, current = start
                // Main-thread time of each drag event (the edit, the route
                // runtime update with a playing route's clock retarget, and
                // the frame rebuild it triggers) and of the mouseUp.
                var eventMilliseconds: [Double] = []
                for i in 1...8 {
                    current = start + SIMD2<Float>(pixels[0], pixels[1]) * (Float(i) / 8)
                    let begin = ProcessInfo.processInfo.systemUptime
                    studio.mouseDragged(to: current, delta: current - previous, button: 0, modifiers: noModifiers)
                    eventMilliseconds.append((ProcessInfo.processInfo.systemUptime - begin) * 1_000)
                    previous = current
                }
                let upBegin = ProcessInfo.processInfo.systemUptime
                studio.mouseUp(at: current, button: 0, modifiers: noModifiers)
                let upMilliseconds = (ProcessInfo.processInfo.systemUptime - upBegin) * 1_000
                let sortedEvents = eventMilliseconds.sorted()
                let timing = String(format: "drag events median %.2f ms, max %.2f ms; mouseUp %.2f ms",
                                    sortedEvents[sortedEvents.count / 2], sortedEvents.last!, upMilliseconds)
                guard let after = studio.sourceRouteState(id) else { record(step, false, "dragRoutePoint: the route is gone"); continue }
                let old = before.points[point.index], new = after.points[point.index]
                let (from, to) = point.aid ? (old.aidPosition, new.aidPosition)
                    : point.index == 0 ? (old.rotationDegrees, new.rotationDegrees) : (old.position, new.position)
                let moved = from != to
                record(step, moved, moved
                    ? "dragged route \(describe(step)) \(point.index == 0 && !point.aid ? "start rotation" : point.aid ? "aid \(point.index)" : "point \(point.index)") along \(axisName) from pixel (\(start.x), \(start.y)) over \(pixels) px: (\(from.x), \(from.y), \(from.z)) -> (\(to.x), \(to.y), \(to.z)); \(timing)"
                    : "dragRoutePoint: the drag left the handle at (\(to.x), \(to.y), \(to.z)): \(studio.status)")
            case "captureRoute":
                guard let id = object(step), let state = studio.sourceRouteState(id) else {
                    record(step, false, "captureRoute: \(describe(step)) is not an imported route"); continue
                }
                guard let label = step.name, !label.isEmpty else { record(step, false, "captureRoute: name (the capture label) is required"); continue }
                capturedRoutes[label] = state
                record(step, true, "captured route \(describe(step)) (\(state.points.count) points) as \"\(label)\"")
            case "editRoute":
                // ST-T11: one route panel edit, through the model calls the
                // inspector controls make.
                guard let id = object(step), studio.sourceRouteState(id) != nil else {
                    record(step, false, "editRoute: \(describe(step)) is not an imported route"); continue
                }
                guard let edit = step.routeEdit else { record(step, false, "editRoute: routeEdit is required"); continue }
                func vector(_ values: [Float]?) -> SIMD3<Float>? {
                    guard let values, values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
                    return SIMD3(values[0], values[1], values[2])
                }
                let documentBefore = studio.doc.object(id)?.sourceRoute
                var accepted: Bool?
                switch (edit.setting, edit.index) {
                case ("add", _): accepted = studio.addSourceRoutePoint(id) != nil
                case ("delete", let index?): accepted = studio.deleteSourceRoutePoint(id, index: index)
                case ("move", let index?):
                    if let position = vector(edit.position) {
                        accepted = studio.editSourceRoute(id, .move) {
                            if edit.aid == true { try $0.moveAid(index, to: position) } else { try $0.movePoint(index, to: position) }
                        }
                    }
                case ("rotateStart", _):
                    if let rotation = vector(edit.rotation) { accepted = studio.editSourceRoute(id, .move) { try $0.rotateStart(to: rotation) } }
                case ("speed", let index?):
                    if let value = edit.value { accepted = studio.editSourceRoute(id, .speed, point: index) { try $0.setSpeed(index, value) } }
                case ("ease", let index?):
                    if let ease = edit.ease.flatMap(SourceStudioRoute.EaseType.init(rawValue:)) {
                        accepted = studio.editSourceRoute(id, .ease, point: index) { try $0.setEase(index, ease) }
                    }
                case ("connection", let index?):
                    if let curve = edit.curve {
                        accepted = studio.editSourceRoute(id, .connection) { try $0.setConnection(index, curve ? .curve : .line) }
                    }
                case ("link", let index?):
                    if let on = edit.on { accepted = studio.editSourceRoute(id, .link) { try $0.setLink(index, on) } }
                case ("loop", _):
                    if let on = edit.on { accepted = studio.editSourceRoute(id, .loop) { $0.loop = on } }
                case ("line", _):
                    if let on = edit.on { accepted = studio.editSourceRoute(id, .visibleLine) { $0.visibleLine = on } }
                case ("orientation", _):
                    if let orientation = edit.orientation.flatMap(SourceStudioRoute.Orientation.init(rawValue:)) {
                        accepted = studio.editSourceRoute(id, .orientation) { $0.setOrientation(orientation) }
                    }
                case ("color", _):
                    if let rgb = vector(edit.rgb) { accepted = studio.editSourceRoute(id, .color) { try $0.setColor(red: rgb.x, green: rgb.y, blue: rgb.z) } }
                default: break
                }
                guard let accepted else {
                    record(step, false, "editRoute: setting \"\(edit.setting)\" is unknown or misses its index/value"); continue
                }
                if let refused = edit.refused {
                    let unchanged = studio.doc.object(id)?.sourceRoute == documentBefore
                    let ok = !accepted && studio.status.contains(refused) && unchanged
                    record(step, ok, ok ? "route \(describe(step)) \(edit.setting) refused as expected: \(studio.status)"
                        : "editRoute: expected a refusal containing \"\(refused)\" and no change; accepted \(accepted), document unchanged \(unchanged), status \(studio.status)")
                } else {
                    let points = studio.sourceRouteState(id)?.points.count ?? 0
                    record(step, accepted, accepted ? "route \(describe(step)) \(edit.setting) applied (\(points) points): \(studio.status)"
                        : "editRoute: \(edit.setting) refused: \(studio.status)")
                }
            case "assert", "assertRejected":
                var problems: [String] = []
                var details: [String] = []
                let needsObject = step.name != nil || step.visible != nil || step.face != nil || step.body != nil || step.color != nil
                    || step.treeLabel != nil
                var id: UUID?
                if needsObject, step.key == nil {
                    problems.append("assert: name/visible/face/color/treeLabel need a key")
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
                if let key = step.activeCopyOf {
                    let active = studio.activeSourceCamera.flatMap { studio.doc.object($0) }
                    if active?.sourceObjectKey != nil || active?.sourceDuplicateOf != key {
                        problems.append("assert activeCopyOf: active is \(active.map(treeLabel) ?? "none"), expected a copy of \(key)")
                    } else {
                        details.append("looking through a copy of camera \(key)")
                    }
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
                if let problem = assertRoute(step, details: &details) { problems.append(problem) }
                if let expected = step.routeLines {
                    let drawn = studio.frame.gizmos.filter { $0.primitive == .lines && $0.depthTest && !$0.vertices.isEmpty }.count
                    if drawn != expected { problems.append("assert routeLines: the frame draws \(drawn) route lines, expected \(expected)") }
                    else { details.append("\(drawn) route lines drawn") }
                }
                if let check = step.sourceMap { assertSourceMap(check, problems: &problems, details: &details) }
                if let check = step.children {
                    var parentID: UUID?, found = true
                    if let key = check.parent {
                        parentID = objectID(key: key, copy: check.parentCopy)
                        found = parentID != nil
                    }
                    let keys = studio.doc.children(of: parentID).map(treeLabel)
                    let label = check.parent.map { "source key \($0)\(check.parentCopy.map { " copy \($0)" } ?? "")" } ?? "the root"
                    let expected = check.labels ?? check.keys?.map(String.init)
                    if !found {
                        problems.append("assert children: no parent with source key \(check.parent!)")
                    } else if let expected, keys != expected {
                        problems.append("assert children: \(label) holds [\(keys.joined(separator: ", "))], expected [\(expected.joined(separator: ", "))]")
                    } else if expected == nil {
                        problems.append("assert children: keys or labels is required")
                    } else {
                        details.append("\(label) holds [\(keys.joined(separator: ", "))]")
                    }
                }
                if let keys = step.absent {
                    let present = keys.filter { key in studio.doc.objects.contains { $0.sourceObjectKey == key } }
                    if !present.isEmpty { problems.append("assert absent: source keys \(present) are still in the document") }
                    else { details.append("source keys \(keys) absent") }
                }
                if let problem = assertEyeLook(step) { problems.append(problem) }
                if let problem = assertBlink(step) { problems.append(problem) }
                if let problem = assertHandPattern(step) { problems.append(problem) }
                // The render and export-identity checks resolve their own
                // inputs (the `from` label / the file path) inside the check
                // value, like `animation`/`fk`.
                if let problem = assertRender(step, details: &details) { problems.append(problem) }
                if let problem = assertExportIdenticalToSource(step, details: &details) { problems.append(problem) }
                if let problem = assertOutfit(step, details: &details) { problems.append(problem) }
                if let problem = assertAccessoryLabels(step, details: &details) { problems.append(problem) }
                if let problem = assertPluginMount(step, details: &details) { problems.append(problem) }
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
