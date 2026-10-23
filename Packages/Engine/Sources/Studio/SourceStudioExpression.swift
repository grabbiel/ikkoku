import Foundation
import Assets
import Character
import Scene

/// ST-C04: one source character's face state as the CharaStudio State panel
/// edits it (MPCharCtrl.EtcInfo, LookAtInfo, NeckInfo and OtherInfo). Every
/// member except `heldEyesOpenRate` is a saved original value:
///
/// | member | saved as | State panel control → method chain |
/// |---|---|---|
/// | `eyebrowPattern` | Status.eyebrowPtn | piEyebrows → ChaControl.ChangeEyebrowPtn |
/// | `eyesPattern` | Status.eyesPtn (cha_eyeset row ID) | piEyes → ChaControl.ChangeEyesPtn |
/// | `mouthPattern` | Status.mouthPtn | piMouth → ChaControl.ChangeMouthPtn |
/// | `eyesOpen` | Status.eyesOpenMax | sliderEyesOpen → OCIChar.ChangeEyesOpen → ChangeEyesOpenMax |
/// | `blink` | Status.eyesBlink | toggleBlink → OCIChar.ChangeBlink → ChangeEyesBlinkFlag |
/// | `mouthOpen` | OICharInfo.mouthOpen (scene record) | sliderMouthOpen → OCIChar.ChangeMouthOpen |
/// | `lipSync` | OICharInfo.lipSync (scene record) | toggleLipSync → OCIChar.ChangeLipSync |
/// | `eyesLookPattern` | Status.eyesLookPtn | LookAtInfo.buttonMode → OCIChar.ChangeLookEyesPtn |
/// | `neckLookPattern` | Status.neckLookPtn | NeckInfo.buttonMode {0,1,3,4} → ChangeLookNeckPtn |
/// | `tears` | Status.tearsLv | OtherInfo.tears → OCIChar.SetTearsLv |
/// | `cheek` | Status.hohoAkaRate | OtherInfo.cheek → OCIChar.SetHohoAkaRate → ChangeHohoAkaRate |
///
/// Documents saved before this type existed decode `StudioObject.sourceExpression`
/// as nil, which keeps the saved values.
public struct SourceStudioExpressionState: Codable, Sendable, Equatable, Hashable {
    public var eyebrowPattern: Int
    public var eyesPattern: Int
    public var mouthPattern: Int
    public var eyesOpen: Float
    public var blink: Bool
    public var mouthOpen: Float
    public var lipSync: Bool
    public var eyesLookPattern: Int
    public var neckLookPattern: Int
    public var tears: Int
    public var cheek: Float
    /// Native runtime, not an original saved value: the eyes FBS openRate the
    /// original holds while blinking is off, when it differs from the load
    /// replay's `eyesOpen`. ChangeEyesBlinkFlag(false) forces it to 1 and
    /// only ChangeEyesOpenMax (the eye-openness slider) moves it again, while
    /// a scene load replays ChangeBlink then ChangeEyesOpen and leaves
    /// `eyesOpen`. Kept so undo/redo and a native save restore the rendered
    /// eyes; original export cannot carry it (a reload replays the load).
    public var heldEyesOpenRate: Float?

    public init(eyebrowPattern: Int, eyesPattern: Int, mouthPattern: Int, eyesOpen: Float, blink: Bool,
                mouthOpen: Float, lipSync: Bool, eyesLookPattern: Int, neckLookPattern: Int, tears: Int, cheek: Float,
                heldEyesOpenRate: Float? = nil) {
        self.eyebrowPattern = eyebrowPattern; self.eyesPattern = eyesPattern; self.mouthPattern = mouthPattern
        self.eyesOpen = eyesOpen; self.blink = blink; self.mouthOpen = mouthOpen; self.lipSync = lipSync
        self.eyesLookPattern = eyesLookPattern; self.neckLookPattern = neckLookPattern
        self.tears = tears; self.cheek = cheek; self.heldEyesOpenRate = heldEyesOpenRate
    }

    /// The FBS eyes openRate a load replay leaves while blinking is off:
    /// ChangeEyesOpenMax forces Mathf.Clamp(eyesOpenMax, 0, 1).
    public var replayEyesOpenRate: Float { min(max(eyesOpen, 0), 1) }

    /// The eyes openRate the FBS controller holds while blinking is off.
    public var eyesOpenRate: Float { heldEyesOpenRate ?? replayEyesOpenRate }

    /// Ports the setters' runtime side effects for an edit from `previous`
    /// (the State panel changes one control at a time; a multi-field edit
    /// applies them in AddObjectAssist.UpdateState order, ChangeBlink before
    /// ChangeEyesOpen): blinking on lets the blink clock drive the eyes;
    /// ChangeEyesBlinkFlag(false) forces the eyes (and eyebrows) open rate to
    /// 1; ChangeEyesOpenMax while not blinking forces it to the clamped
    /// openness. The incoming `heldEyesOpenRate` is ignored; the result
    /// stores nil when the held rate equals the load replay's.
    public func settled(from previous: SourceStudioExpressionState) -> SourceStudioExpressionState {
        var next = self
        if next.blink { next.heldEyesOpenRate = nil }
        else if next.eyesOpen.bitPattern != previous.eyesOpen.bitPattern { next.heldEyesOpenRate = nil }
        else if previous.blink { next.heldEyesOpenRate = 1 }
        else { next.heldEyesOpenRate = previous.heldEyesOpenRate }
        if let held = next.heldEyesOpenRate, held == next.replayEyesOpenRate { next.heldEyesOpenRate = nil }
        return next
    }

    /// The card Status edits for every saved field that differs from `saved`
    /// (empty when only scene-record fields or the native held rate differ).
    public func statusEdit(from saved: SourceStudioExpressionState) -> SourceCharacterCard.StatusFaceEdit {
        var edit = SourceCharacterCard.StatusFaceEdit()
        if eyebrowPattern != saved.eyebrowPattern { edit.eyebrowPtn = eyebrowPattern }
        if eyesPattern != saved.eyesPattern { edit.eyesPtn = eyesPattern }
        if mouthPattern != saved.mouthPattern { edit.mouthPtn = mouthPattern }
        if eyesOpen.bitPattern != saved.eyesOpen.bitPattern { edit.eyesOpenMax = eyesOpen }
        if blink != saved.blink { edit.eyesBlink = blink }
        if eyesLookPattern != saved.eyesLookPattern { edit.eyesLookPtn = eyesLookPattern }
        if neckLookPattern != saved.neckLookPattern { edit.neckLookPtn = neckLookPattern }
        if tears != saved.tears { edit.tearsLv = tears }
        if cheek.bitPattern != saved.cheek.bitPattern { edit.hohoAkaRate = cheek }
        return edit
    }

    /// The scene-record edit (OICharInfo.mouthOpen / lipSync), nil when both
    /// equal `saved`.
    public func mouthEdit(from saved: SourceStudioExpressionState) -> SourceSceneEdits.MouthEdit? {
        let edit = SourceSceneEdits.MouthEdit(mouthOpen: mouthOpen.bitPattern != saved.mouthOpen.bitPattern ? mouthOpen : nil,
                                              lipSync: lipSync != saved.lipSync ? lipSync : nil)
        return edit.mouthOpen == nil && edit.lipSync == nil ? nil : edit
    }
}

/// The State panel's option lists for one assembled character, from the
/// expression contract (FBS pattern counts, cha_eyeset rows) and the recovered
/// MPCharCtrl button sets. Validation accepts a field's saved value even when
/// the panel could not select it, so Reset and an unchanged field never fail.
public struct SourceStudioExpressionControls: Sendable {
    /// MPCharCtrl.NeckInfo.patterns: the four neck buttons' neckLookPtn values.
    public static let neckLookPatterns = [0, 1, 3, 4]
    /// MPCharCtrl.LookAtInfo.buttonMode indices; OnClick passes the index as
    /// the eyesLookPtn and pattern 4 switches the target to the look-at guide.
    public static let eyesLookPatterns = Array(0...4)
    /// MPCharCtrl.OtherInfo.tears buttons; ChaControl's tears table has
    /// four rows (tearsLv 0 none ... 3), the byte UpdateVisible indexes.
    public static let tearsLevels = Array(0...3)
    /// FBSBase.GetMaxPtn of the eyebrow and mouth controllers.
    public let eyebrowPatternCount: Int, mouthPatternCount: Int, eyesPatternCount: Int
    /// The cha_eyeset rows the eyes buttons step through, in list order. When
    /// the contract predates `eyeCatalog.rows`, the IDs below the FBS pattern
    /// count are offered with an identity mapping and reported.
    public let eyeRows: [SourceExpressionContract.EyeRow]
    public let eyeCatalogComplete: Bool

    public init(contract: SourceExpressionContract) throws {
        guard let eyebrow = contract.patternCount("eyebrow"), let mouth = contract.patternCount("mouth"),
              let eyes = contract.patternCount("eyes") else { throw RigError.invalid("Expression contract lacks a face controller.") }
        eyebrowPatternCount = eyebrow; mouthPatternCount = mouth; eyesPatternCount = eyes
        if let rows = contract.eyeCatalog?.rows, !rows.isEmpty {
            eyeRows = rows; eyeCatalogComplete = true
        } else {
            let known = Dictionary(uniqueKeysWithValues: (contract.eyeCatalog?.ordinaryRows ?? []).map { ($0.id, $0) })
            eyeRows = (0..<eyes).map { known[$0] ?? .init(id: $0, name: "Pattern \($0)", pattern: $0, eyeBase: 1, eyeHitomi: 1,
                                                           eyeObjectNumber: 0, mainTexture: "0", expressionTexture: "0") }
            eyeCatalogComplete = false
        }
    }

    public func eyeRow(_ id: Int) -> SourceExpressionContract.EyeRow? { eyeRows.first { $0.id == id } }

    /// Every field either keeps its saved value or holds a value the State
    /// panel can set: patterns inside their controller/list, look patterns
    /// among the panel's buttons, tears 0...3, finite rates in 0...1, and a
    /// held eyes rate only while blinking is off.
    public func validate(_ state: SourceStudioExpressionState, saved: SourceStudioExpressionState) throws {
        func check(_ ok: Bool, _ message: String) throws { if !ok { throw RigError.invalid(message) } }
        try check(state.eyebrowPattern == saved.eyebrowPattern || (0..<eyebrowPatternCount).contains(state.eyebrowPattern),
                  "Eyebrow pattern must be in 0...\(eyebrowPatternCount - 1).")
        try check(state.eyesPattern == saved.eyesPattern || eyeRow(state.eyesPattern) != nil,
                  "Eyes pattern \(state.eyesPattern) is not a cha_eyeset row.")
        try check(state.mouthPattern == saved.mouthPattern || (0..<mouthPatternCount).contains(state.mouthPattern),
                  "Mouth pattern must be in 0...\(mouthPatternCount - 1).")
        for (name, value, old) in [("Eye openness", state.eyesOpen, saved.eyesOpen), ("Mouth openness", state.mouthOpen, saved.mouthOpen),
                                   ("Cheek", state.cheek, saved.cheek)] {
            try check(value.bitPattern == old.bitPattern || (value.isFinite && (0...1).contains(value)), "\(name) must be finite and in 0...1.")
        }
        try check(state.eyesLookPattern == saved.eyesLookPattern || Self.eyesLookPatterns.contains(state.eyesLookPattern),
                  "Eye look pattern must be one of \(Self.eyesLookPatterns.map(String.init).joined(separator: ", ")).")
        try check(state.neckLookPattern == saved.neckLookPattern || Self.neckLookPatterns.contains(state.neckLookPattern),
                  "Neck look pattern must be one of \(Self.neckLookPatterns.map(String.init).joined(separator: ", ")).")
        try check(state.tears == saved.tears || Self.tearsLevels.contains(state.tears), "Tears level must be in 0...3.")
        if let held = state.heldEyesOpenRate {
            try check(!state.blink && held.isFinite && (0...1).contains(held), "A held eyes open rate needs blinking off and a rate in 0...1.")
        }
    }

    /// The expression controller inputs this state renders: the FBS patterns
    /// (the eyes row's EyesPtn; a pattern ChangePtn would ignore keeps the
    /// contract default), the clamped eye openness, the mouth openness as the
    /// mouth FixedRate (OCIChar.ChangeMouthOpen without a playing voice), and
    /// while blinking is off the forced eyes/eyebrow open rates.
    public func inputs(_ state: SourceStudioExpressionState, base: SourceExpressionInputs) -> SourceExpressionInputs {
        var inputs = base
        if (0..<eyebrowPatternCount).contains(state.eyebrowPattern) { inputs.eyebrowPattern = state.eyebrowPattern }
        // ChangeEyesPtn rewrites an unknown row ID to row 0.
        inputs.eyesPattern = (eyeRow(state.eyesPattern) ?? eyeRow(0))?.pattern ?? base.eyesPattern
        if (0..<mouthPatternCount).contains(state.mouthPattern) { inputs.mouthPattern = state.mouthPattern }
        inputs.eyesOpenMax = state.eyesOpen.isFinite ? min(max(state.eyesOpen, 0), 1) : base.eyesOpenMax
        // FixedRate replaces the openness outright (FBSBase.CalculateBlendShape
        // clamps the percentage), so values above 1 render as 1 and negatives
        // fall back to the voice rate, which is 0 without a playing voice.
        inputs.mouthFixedRate = state.mouthOpen.isFinite ? min(max(state.mouthOpen, -1), 1) : base.mouthFixedRate
        if !state.blink {
            inputs.eyesOpenRate = state.eyesOpenRate
            inputs.eyebrowOpenRate = 1
        }
        return inputs
    }

    /// What this state saves but the native default (toon) path does not
    /// draw, one line per field, recomputed per state and never accumulated.
    public func diagnostics(_ state: SourceStudioExpressionState) -> [String] {
        var lines: [String] = []
        if !eyeCatalogComplete {
            lines.append("The expression contract carries only the ordinary cha_eyeset rows; eyes IDs map to the same FBS pattern.")
        }
        if let row = eyeRow(state.eyesPattern) {
            if !row.isOrdinary {
                lines.append("Eyes pattern \(row.id) (\(row.name)) renders its FBS pattern \(row.pattern) only; the row's eye-base/iris visibility (\(row.eyeBase)/\(row.eyeHitomi)), gag-eye object \(row.eyeObjectNumber) and expression texture \(row.expressionTexture) are not drawn.")
            }
        } else {
            lines.append("Saved eyes pattern \(state.eyesPattern) is not a cha_eyeset row; ChangeEyesPtn loads it as row 0 (a CharaStudio save then writes 0), and the native preview renders row 0.")
        }
        if !(0..<eyebrowPatternCount).contains(state.eyebrowPattern) {
            lines.append("Saved eyebrow pattern \(state.eyebrowPattern) is outside the controller's \(eyebrowPatternCount) patterns; FBS ChangePtn ignores it.")
        }
        if !(0..<mouthPatternCount).contains(state.mouthPattern) {
            lines.append("Saved mouth pattern \(state.mouthPattern) is outside the controller's \(mouthPatternCount) patterns; FBS ChangePtn ignores it.")
        } else if state.mouthPattern == 21 || state.mouthPattern == 22 {
            lines.append("Mouth pattern \(state.mouthPattern) switches \(state.mouthPattern == 21 ? "the tongue state to 1 and " : "")the mouth width adjustment off (ChaControl.ChangeMouthPtn); neither is drawn natively.")
        }
        if state.tears != 0 {
            lines.append("Tears level \(state.tears) is saved and exported, but the tear meshes (cf_O_namida_*) are not assembled, so no tears render.")
        }
        if state.cheek != 0 {
            lines.append("Cheek \(state.cheek) is saved and exported, but the default toon path has no face _overcolor2 blush consumer, so it does not render.")
        }
        if state.lipSync {
            lines.append("Lip sync is saved and exported; voice lip sync is not modelled, so the mouth keeps the mouth openness even while a voice plays.")
        }
        return lines
    }
}

extension SourceStudioExpressionState {
    /// The card's saved face-state Status fields, read field by field: a token
    /// of another MessagePack type keeps its ChaFileStatus.MemberInit default
    /// and is reported once (eyesBlink keeps SourceStudioBlink.decode's own
    /// report). Export of an edit to such a field is refused by the card
    /// writer, which never rewrites a token it cannot read.
    static func savedFace(status: [String: SourceMessagePackValue]) -> (face: SourceCharacterCard.StatusFace, diagnostics: [String]) {
        if let face = try? SourceCharacterCard.StatusFace(status: status) { return (face, []) }
        var face = SourceCharacterCard.StatusFace.memberInit, notes: [String] = []
        for key in ["eyebrowPtn", "eyesPtn", "mouthPtn", "eyesOpenMax", "eyesBlink", "eyesLookPtn", "neckLookPtn", "tearsLv", "hohoAkaRate"] {
            guard let value = status[key] else { continue }
            do {
                let one = try SourceCharacterCard.StatusFace(status: [key: value])
                switch key {
                case "eyebrowPtn": face.eyebrowPtn = one.eyebrowPtn
                case "eyesPtn": face.eyesPtn = one.eyesPtn
                case "mouthPtn": face.mouthPtn = one.mouthPtn
                case "eyesOpenMax": face.eyesOpenMax = one.eyesOpenMax
                case "eyesBlink": face.eyesBlink = one.eyesBlink
                case "eyesLookPtn": face.eyesLookPtn = one.eyesLookPtn
                case "neckLookPtn": face.neckLookPtn = one.neckLookPtn
                case "tearsLv": face.tearsLv = one.tearsLv
                default: face.hohoAkaRate = one.hohoAkaRate
                }
            } catch {
                if key != "eyesBlink" { notes.append("Saved Status.\(key) is unreadable (\(error)); its ChaFileStatus default renders.") }
            }
        }
        return (face, notes)
    }
}
