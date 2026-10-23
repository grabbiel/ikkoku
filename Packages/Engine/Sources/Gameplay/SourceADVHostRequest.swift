import Foundation

/// A presentation command the native ADV interpreter cannot perform itself.
///
/// Arguments are parsed exactly as the recovered handler's `Do()` parses them
/// after `CommandBase.Initialize` (defaults) and `TextScenario.ReplaceVars`
/// (whole-argument variable substitution). Character numbers keep the source
/// meaning: `2147483647` (`int.MaxValue`) selects the current character.
public struct SourceADVHostRequest: Codable, Equatable, Sendable {
    /// How the request gates the source `MessageWindowProc` advance.
    public enum Blocking: String, Codable, Sendable {
        /// `Process()` is the base `true`: never delays the next batch.
        case none
        /// The next batch waits for `SourceADVInterpreter.acknowledge`.
        case acknowledge
        /// A `Text` batch advances only on explicit Next input.
        case next
    }
    public var requestID: Int
    /// Source command index (`localLine`) and ordinal.
    public var pc: Int
    public var commandID: Int
    /// `RequestNextLine` count when the command ran. A higher batch number
    /// means the source ran `CommandList.ProcessEnd` for earlier batches.
    public var batch: Int
    public var blocking: Blocking
    public var command: Command

    public enum Command: Equatable, Sendable {
        case charaLookNeck(LookNeck)
        case charaLookEyes(LookEyes)
        case bgmPlay(BGMPlay)
        case charaExpression([ExpressionEntry])
        case charaMotion([Motion])
        case text(Text)
        case mapChange(MapChange)
        case nullLoad(NullLoad)
        case nullSet(NullSet)
        case sceneFade(SceneFade)

        public var kind: String {
            switch self {
            case .charaLookNeck: "charaLookNeck"
            case .charaLookEyes: "charaLookEyes"
            case .bgmPlay: "bgmPlay"
            case .charaExpression: "charaExpression"
            case .charaMotion: "charaMotion"
            case .text: "text"
            case .mapChange: "mapChange"
            case .nullLoad: "nullLoad"
            case .nullSet: "nullSet"
            case .sceneFade: "sceneFade"
            }
        }
    }

    /// `ADV.Commands.Chara.LookNeck.Do`: `ChangeLookNeckPtn(ptn, rate)`.
    public struct LookNeck: Codable, Equatable, Sendable { public var chara: Int32; public var pattern: Int32; public var rate: Float }
    /// `ADV.Commands.Chara.LookEyes.Do`: `ChangeLookEyesPtn(ptn)`.
    public struct LookEyes: Codable, Equatable, Sendable { public var chara: Int32; public var pattern: Int32 }

    /// `ADV.Commands.Sound.BGM.Play.Do`. Exactly one of `number` (an
    /// `int.TryParse` value or the matched `Illusion.Game.BGM` index, then
    /// `SettingBGM(int)`) or `bundle` (`SettingBGM(string)`) is set.
    public struct BGMPlay: Codable, Equatable, Sendable {
        public var number: Int32?
        public var enumName: String?
        public var bundle: String?
        /// Non-empty `Asset` argument assigned to `setting.assetName`.
        public var asset: String?
        public var delay: Float
        public var fade: Float?
        public var isAsync: Bool
        public var pitch: Float?
        public var panStereo: Float?
        public var time: Float?
        public var volume: Float?
    }

    /// `Manager.Game.Expression.Pattern`.
    public struct Pattern: Codable, Equatable, Sendable { public var pattern: Int32; public var blend: Bool }
    /// Fields `Manager.Game.Expression.Initialize` parsed successfully; nil
    /// fields have their `use*` flag false. Converted ADV expressions always
    /// carry `isChangeSkip = true`, so `Change` applies only these fields.
    public struct Expression: Codable, Equatable, Sendable {
        public var eyebrow: Pattern?
        public var eyes: Pattern?
        public var mouth: Pattern?
        public var eyebrowOpen: Float?
        public var eyesOpen: Float?
        public var mouthOpen: Float?
        public var eyesLook: Int32?
        public var cheekRedRate: Float?
        public var highlight: Bool?
        public var tearsLevel: Int32?
        public var blink: Bool?
        public init() {}
    }
    /// One `ADV.Commands.Base.Expression.Convert` entry.
    ///
    /// With `lookupKey`, the source first looks the key up in the scenario's
    /// ExpLoad table (always empty here: ExpLoad is unsupported) and then the
    /// character personality table (`Manager.Game.GetExpression`); a hit is
    /// applied instead of `expression`. A nil `expression` means the source's
    /// fallback parse changes nothing. When both are set
    /// (`requiresLookupMiss`), the key is itself a valid pattern: a table hit
    /// would consume a different argument count, so the host must reject the
    /// request if the key exists.
    public struct ExpressionEntry: Codable, Equatable, Sendable {
        public var chara: Int32
        public var lookupKey: String?
        public var expression: Expression?
        public var requiresLookupMiss: Bool { lookupKey != nil && expression != nil }
    }

    /// One `ADV.Commands.Base.Motion.Data`, parsed with exceptions swallowed
    /// as in the source: fields after a failed parse stay nil (`chara` 0).
    public struct Motion: Codable, Equatable, Sendable {
        public var chara: Int32 = 0
        public var state: String?
        public var bundle: String?
        public var asset: String?
        public var ikBundle: String?
        public var ikAsset: String?
        public var shakeBundle: String?
        public var shakeAsset: String?
        public var overrideBundle: String?
        public var overrideAsset: String?
        public var layers: [Int32]?
    }

    /// One `ADV.Commands.Base.Voice.Data`, parsed with exceptions swallowed.
    /// Nil `personality`/`pitch` take the bound character's `voiceNo` /
    /// `voicePitch` (0 / 1 without a character); an empty bundle takes the
    /// scenario's per-personality `bundleVoices` memory (host state).
    public struct Voice: Codable, Equatable, Sendable {
        public var chara: Int32 = 0
        public var bundle: String?
        public var asset: String?
        public var personality: Int32?
        public var pitch: Float?
    }

    /// `ADV.Commands.Base.Text.Do`. `name`/`text` are before
    /// `TextScenario.ReplaceText` (host name tags). The lists are the
    /// scenario's `CurrentCharaData` at that moment (one inner array per
    /// Voice/Expression/Motion command since the last advance) that
    /// `Text.Next` plays in step with the voice list.
    public struct Text: Codable, Equatable, Sendable {
        public var name: String
        public var text: String
        public var voices: [[Voice]]?
        public var expressions: [[ExpressionEntry]]?
        public var motions: [[Motion]]?
    }

    /// `ADV.Commands.Game.MapChange.Do`. `mapNumber` is the `int.TryParse`
    /// value; otherwise the host converts `mapName` (`Map.ConvertMapNo`).
    /// `fade` is the `Scene.Data.FadeType` name. The acknowledgement carries
    /// the action scene's ADV variables, written as String values.
    public struct MapChange: Codable, Equatable, Sendable {
        public var mapNumber: Int32?
        public var mapName: String?
        public var fade: String
    }

    /// `ADV.Commands.Base.NullLoad.Do`: bundle `map/advpos/<version:00>/<name>.unity3d`
    /// where a nil `map` (source "デフォルト") means `default`, otherwise the
    /// host's `Map.GetParam(map).AssetName.ToLower()`.
    public struct NullLoad: Codable, Equatable, Sendable { public var version: Int32; public var map: String? }

    /// `ADV.Commands.Base.NullSet.Do`: target `Base`, `Camera` or `Chara`;
    /// nil (no match) does nothing in the source.
    public struct NullSet: Codable, Equatable, Sendable { public var name: String; public var target: String? }

    /// `ADV.Commands.Effect.SceneFade.Do`. `time` nil keeps the scene fade's
    /// current time. A texture is loaded when `textureBundle` is set.
    public struct SceneFade: Codable, Equatable, Sendable {
        public var fadeIn: Bool
        public var time: Float?
        public var textureBundle: String?
        public var textureAsset: String?
    }
}

extension SourceADVHostRequest.Command: Codable {
    private enum CodingKeys: String, CodingKey { case kind, arguments }
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try box.decode(String.self, forKey: .kind)
        switch kind {
        case "charaLookNeck": self = .charaLookNeck(try box.decode(SourceADVHostRequest.LookNeck.self, forKey: .arguments))
        case "charaLookEyes": self = .charaLookEyes(try box.decode(SourceADVHostRequest.LookEyes.self, forKey: .arguments))
        case "bgmPlay": self = .bgmPlay(try box.decode(SourceADVHostRequest.BGMPlay.self, forKey: .arguments))
        case "charaExpression": self = .charaExpression(try box.decode([SourceADVHostRequest.ExpressionEntry].self, forKey: .arguments))
        case "charaMotion": self = .charaMotion(try box.decode([SourceADVHostRequest.Motion].self, forKey: .arguments))
        case "text": self = .text(try box.decode(SourceADVHostRequest.Text.self, forKey: .arguments))
        case "mapChange": self = .mapChange(try box.decode(SourceADVHostRequest.MapChange.self, forKey: .arguments))
        case "nullLoad": self = .nullLoad(try box.decode(SourceADVHostRequest.NullLoad.self, forKey: .arguments))
        case "nullSet": self = .nullSet(try box.decode(SourceADVHostRequest.NullSet.self, forKey: .arguments))
        case "sceneFade": self = .sceneFade(try box.decode(SourceADVHostRequest.SceneFade.self, forKey: .arguments))
        default: throw SourceGameplayExecutionError.invalidData("Unknown ADV host request kind \(kind)")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(kind, forKey: .kind)
        switch self {
        case .charaLookNeck(let value): try box.encode(value, forKey: .arguments)
        case .charaLookEyes(let value): try box.encode(value, forKey: .arguments)
        case .bgmPlay(let value): try box.encode(value, forKey: .arguments)
        case .charaExpression(let value): try box.encode(value, forKey: .arguments)
        case .charaMotion(let value): try box.encode(value, forKey: .arguments)
        case .text(let value): try box.encode(value, forKey: .arguments)
        case .mapChange(let value): try box.encode(value, forKey: .arguments)
        case .nullLoad(let value): try box.encode(value, forKey: .arguments)
        case .nullSet(let value): try box.encode(value, forKey: .arguments)
        case .sceneFade(let value): try box.encode(value, forKey: .arguments)
        }
    }
}

/// Source `TextScenario.CurrentCharaData` lists consumed by the next Text.
/// `CurrentCharaData.Clear` runs only on the `MessageWindowProc` advance.
public struct SourceADVTextBindings: Codable, Equatable, Sendable {
    public var voices: [[SourceADVHostRequest.Voice]]?
    public var expressions: [[SourceADVHostRequest.ExpressionEntry]]?
    public var motions: [[SourceADVHostRequest.Motion]]?
    public init() {}
}

/// Handler argument parsing for the presentation commands. Every function
/// receives the final argument array (defaults applied, variables replaced)
/// and mirrors the cited handler's `Do()`; a definite source exception that
/// the handler does not catch, or an unmodelled form, throws.
enum SourceADVHandlerArguments {
    typealias Request = SourceADVHostRequest

    static let bgmNames = ["Title", "MapMoveDay", "MapMoveEve", "Custom", "Communication", "Encounter", "Lover", "Anger",
                           "HSceneGentle", "HScene", "HScenePeep", "Sad", "Reminiscence", "Date", "MorningMenu", "NightMenu",
                           "SystemMenu", "StaffRoom", "Daytime", "Evening", "Memories", "StaffRoom_01", "NightMenu_01", "Cool",
                           "Lively", "Park", "Caffe", "Config"]
    static let fadeTypeNames = ["None", "InOut", "In", "Out"]
    static let nullSetTargets = ["Base", "Camera", "Chara"]

    static func value<T>(_ result: SourceCLRResult<T>, _ site: String) throws -> T {
        switch result {
        case .value(let value): return value
        case .exception(let detail): throw SourceGameplayExecutionError.invalidArgument("\(site): \(detail)")
        case .unsupported(let detail): throw SourceGameplayExecutionError.unsupported("ADV argument form at \(site): \(detail)")
        }
    }
    /// Value, nil for a definite (swallowed) exception, or throw if unmodelled.
    static func swallowed<T>(_ result: SourceCLRResult<T>, _ site: String) throws -> T? {
        switch result {
        case .value(let value): return value
        case .exception: return nil
        case .unsupported(let detail): throw SourceGameplayExecutionError.unsupported("ADV argument form at \(site): \(detail)")
        }
    }

    static func lookNeck(_ a: [String]) throws -> Request.LookNeck {
        .init(chara: try value(SourceCLR.int32(a[0]), "Chara.LookNeck.Do No"),
              pattern: try value(SourceCLR.int32(a[1]), "Chara.LookNeck.Do Ptn"),
              rate: try value(SourceCLR.single(a[2]), "Chara.LookNeck.Do Rate"))
    }
    static func lookEyes(_ a: [String]) throws -> Request.LookEyes {
        .init(chara: try value(SourceCLR.int32(a[0]), "Chara.LookEyes.Do No"),
              pattern: try value(SourceCLR.int32(a[1]), "Chara.LookEyes.Do Ptn"))
    }

    static func bgmPlay(_ a: [String]) throws -> Request.BGMPlay {
        var play = Request.BGMPlay(delay: 0, isAsync: true)
        switch SourceCLR.int32(a[0]) {
        case .value(let number): play.number = number
        case .unsupported(let detail): throw SourceGameplayExecutionError.unsupported("ADV argument form at Sound.BGM.Play.Do Bundle: \(detail)")
        case .exception:
            let index = try value(SourceCLR.check(a[0], ignoreCase: true, names: bgmNames), "Sound.BGM.Play.Do Enum<BGM>.FindIndex")
            if index >= 0 { play.number = Int32(index); play.enumName = bgmNames[index] } else { play.bundle = a[0] }
        }
        play.asset = SourceADVArgs.safeProc(a, 1)
        play.delay = try value(SourceCLR.single(a[2]), "Sound.BGM.Play.Do Delay")
        if let text = SourceADVArgs.safeProc(a, 3) { play.fade = try value(SourceCLR.single(text), "Sound.BGM.Play.Do Fade") }
        play.isAsync = try value(SourceCLR.boolean(a[4]), "Sound.BGM.Play.Do isAsync")
        func optional(_ index: Int, _ label: String) throws -> Float? {
            guard let text = SourceADVArgs.safeProc(a, index) else { return nil }
            return try value(SourceCLR.single(text), "Sound.BGM.Play.Do \(label)")
        }
        play.pitch = try optional(5, "Pitch")
        play.panStereo = try optional(6, "PanStereo")
        play.time = try optional(7, "Time")
        play.volume = try optional(8, "Volume")
        return play
    }

    /// `Manager.Game.Expression.Pattern(arg, isThrow: true)`; nil = it throws.
    static func pattern(_ text: String, _ site: String) throws -> Request.Pattern? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var result = Request.Pattern(pattern: 0, blend: true)
        if let first = SourceADVArgs.safeProc(parts, 0) {
            guard let number = try swallowed(SourceCLR.int32(first), site) else { return nil }
            result.pattern = number
        }
        if let second = SourceADVArgs.safeProc(parts, 1) {
            guard let blend = try swallowed(SourceCLR.boolean(second), site) else { return nil }
            result.blend = blend
        }
        return result
    }

    /// `Expression.Data(args, ref cnt)` -> `Data.Initialize` with exceptions
    /// swallowed: `No`, then 11 `Expression.Initialize` fields until one throws.
    static func explicitExpression(_ a: [String], _ cnt: inout Int) throws -> (Int32, Request.Expression) {
        let site = "Base.Expression.Data.Initialize"
        var expression = Request.Expression()
        let start = cnt
        cnt += 1
        guard let chara = try swallowed(SourceCLR.int32(a[start]), site + " No") else { return (0, expression) }
        for field in 0..<11 {
            let index = cnt
            cnt += 1
            guard let text = SourceADVArgs.safeProc(a, index) else { continue }
            switch field {
            case 0...2:
                guard let parsed = try pattern(text, site + " Pattern") else { return (chara, expression) }
                if field == 0 { expression.eyebrow = parsed } else if field == 1 { expression.eyes = parsed } else { expression.mouth = parsed }
            case 3, 4, 5, 7:
                guard let parsed = try swallowed(SourceCLR.single(text), site) else { return (chara, expression) }
                switch field { case 3: expression.eyebrowOpen = parsed; case 4: expression.eyesOpen = parsed
                case 5: expression.mouthOpen = parsed; default: expression.cheekRedRate = parsed }
            case 6, 9:
                guard let parsed = try swallowed(SourceCLR.int32(text), site) else { return (chara, expression) }
                if field == 6 { expression.eyesLook = parsed } else { expression.tearsLevel = parsed }
            default:
                guard let parsed = try swallowed(SourceCLR.boolean(text), site) else { return (chara, expression) }
                if field == 8 { expression.highlight = parsed } else { expression.blink = parsed }
            }
        }
        return (chara, expression)
    }

    /// `ADV.Commands.Base.Expression.Convert` (shared by Chara.Expression).
    static func expressions(_ a: [String]) throws -> [Request.ExpressionEntry] {
        guard a.count > 1 else { return [] }
        var entries: [Request.ExpressionEntry] = [], cnt = 0
        while !SourceADVArgs.isNullOrEmpty(a, cnt) {
            let check = SourceADVArgs.safeProc(a, cnt + 1)
            if let check {
                // Outside any try block: a malformed No stops the command.
                let chara = try value(SourceCLR.int32(a[cnt]), "Base.Expression.Convert No")
                if try pattern(check, "Base.Expression.Convert lookup key") == nil {
                    // The fallback parse fails at the eyebrow pattern either way:
                    // two arguments, no field changed.
                    entries.append(.init(chara: chara, lookupKey: check, expression: nil))
                    cnt += 2
                    continue
                }
            }
            let (chara, expression) = try explicitExpression(a, &cnt)
            entries.append(.init(chara: chara, lookupKey: check, expression: expression))
        }
        return entries
    }

    /// `ADV.Commands.Base.Motion.Convert` with an empty `motionDic` (only the
    /// unsupported MotionLoad fills it), then `Motion.Data(args, ref cnt)`.
    static func motions(_ a: [String]) throws -> [Request.Motion] {
        guard a.count > 1 else { return [] }
        let site = "Base.Motion.Data"
        var entries: [Request.Motion] = [], cnt = 0
        while !SourceADVArgs.isNullOrEmpty(a, cnt) {
            var motion = Request.Motion()
            defer { entries.append(motion) }
            let start = cnt
            cnt += 1
            guard let chara = try swallowed(SourceCLR.int32(a[start]), site + " No") else { continue }
            motion.chara = chara
            let stateIndex = cnt
            cnt += 1
            guard a.indices.contains(stateIndex) else { continue }
            motion.state = a[stateIndex]
            motion.bundle = SourceADVArgs.safeGet(a, cnt); cnt += 1
            motion.asset = SourceADVArgs.safeGet(a, cnt); cnt += 1
            motion.ikBundle = SourceADVArgs.safeGet(a, cnt); cnt += 1
            motion.ikAsset = SourceADVArgs.safeGet(a, cnt); cnt += 1
            motion.shakeBundle = SourceADVArgs.safeGet(a, cnt); cnt += 1
            motion.shakeAsset = SourceADVArgs.safeGet(a, cnt); cnt += 1
            motion.overrideBundle = SourceADVArgs.safeGet(a, cnt); cnt += 1
            motion.overrideAsset = SourceADVArgs.safeGet(a, cnt); cnt += 1
            let layerIndex = cnt
            cnt += 1
            if let text = SourceADVArgs.safeProc(a, layerIndex) {
                // `s.Split(',').Select(int.Parse).ToArray()`: one failure leaves layerNo null.
                var layers: [Int32]? = []
                for part in text.split(separator: ",", omittingEmptySubsequences: false) {
                    guard let number = try swallowed(SourceCLR.int32(String(part)), site + " LayerNo") else { layers = nil; break }
                    layers?.append(number)
                }
                motion.layers = layers
            }
        }
        return entries
    }

    /// `ADV.Commands.Base.Voice.Do` loop over `Voice.Data(args, ref cnt)`.
    static func voices(_ a: [String]) throws -> [Request.Voice] {
        guard a.count > 1 else { return [] }
        let site = "Base.Voice.Data"
        var entries: [Request.Voice] = [], cnt = 0
        while !SourceADVArgs.isNullOrEmpty(a, cnt) {
            var voice = Request.Voice()
            defer { entries.append(voice) }
            let start = cnt
            cnt += 1
            guard let chara = try swallowed(SourceCLR.int32(a[start]), site + " No") else { continue }
            voice.chara = chara
            voice.bundle = SourceADVArgs.safeGet(a, cnt); cnt += 1
            voice.asset = SourceADVArgs.safeGet(a, cnt); cnt += 1
            let personalityIndex = cnt
            cnt += 1
            if let text = SourceADVArgs.safeProc(a, personalityIndex) {
                guard let personality = try swallowed(SourceCLR.int32(text), site + " Personality") else { continue }
                voice.personality = personality
            }
            let pitchIndex = cnt
            cnt += 1
            if let text = SourceADVArgs.safeProc(a, pitchIndex) {
                guard let pitch = try swallowed(SourceCLR.single(text), site + " Pitch") else { continue }
                voice.pitch = pitch
            }
        }
        return entries
    }

    static func mapChange(_ a: [String]) throws -> Request.MapChange {
        var change = Request.MapChange(fade: fadeTypeNames[1])
        switch SourceCLR.int32(a[0]) {
        case .value(let number): change.mapNumber = number
        case .exception: change.mapName = a[0]
        case .unsupported(let detail): throw SourceGameplayExecutionError.unsupported("ADV argument form at Game.MapChange.Do No: \(detail)")
        }
        let text = a[1]
        var fade = 1
        if !text.isEmpty {
            let index = try value(SourceCLR.check(text, ignoreCase: true, names: fadeTypeNames), "Game.MapChange.Do Fade Check")
            if index >= 0 { fade = index }
            else if let flag = try swallowed(SourceCLR.boolean(text), "Game.MapChange.Do Fade bool.TryParse") {
                if !flag { fade = 0 }
            } else {
                // int.TryParse success clamps the unchanged default (1), so
                // every remaining form keeps InOut; only unmodelled forms fault.
                _ = try swallowed(SourceCLR.int32(text), "Game.MapChange.Do Fade int.TryParse")
            }
        }
        change.fade = fadeTypeNames[fade]
        return change
    }

    static func nullLoad(_ a: [String]) throws -> Request.NullLoad {
        .init(version: try value(SourceCLR.int32(a[0]), "Base.NullLoad.Do Version"), map: a[1] == "デフォルト" ? nil : a[1])
    }

    static func nullSet(_ a: [String]) throws -> Request.NullSet {
        let index = try value(SourceCLR.check(a[1], ignoreCase: true, names: nullSetTargets), "Base.NullSet.Do Type Check")
        return .init(name: a[0], target: index >= 0 ? nullSetTargets[index] : nil)
    }

    static func sceneFade(_ a: [String]) throws -> Request.SceneFade {
        guard let fadeIn = SourceCLR.cultureEquals(a[0], "in", ignoreCase: true) else {
            throw SourceGameplayExecutionError.unsupported("ADV argument form at Effect.SceneFade.Do Fade: culture comparison")
        }
        var fade = Request.SceneFade(fadeIn: fadeIn)
        if let text = SourceADVArgs.safeProc(a, 1) { fade.time = try value(SourceCLR.single(text), "Effect.SceneFade.Do Time") }
        guard a[2].isEmpty else {
            throw SourceGameplayExecutionError.unsupported("ADV argument form at Effect.SceneFade.Do Color: GetColor needs float.TryParse(Any) and ColorUtility")
        }
        if !a[3].isEmpty { fade.textureBundle = a[3]; fade.textureAsset = SourceADVArgs.safeGet(a, 4) }
        return fade
    }
}
