import Foundation

// G-T02: the original saved-character data the ADV interpreter reads and
// writes. Source: `SaveData.CharaData.Params` builds one `Params.Data`
// (`command`, `key`, getter, optional setter) per public instance field and
// property of the concrete `SaveData.Heroine`/`SaveData.Player` whose type is
// `string`, `int` or `bool` (`Utils.Type.GetPublicFields/GetPublicProperties`,
// `Data.Cast(Type)`), prefixed `H_`/`P_`. Only fields get a setter
// (`FieldInfo.SetValue(chara, Convert.ChangeType(o, FieldType))`); a property
// write goes through `Pointer.value`'s null-safe `set.Call` and changes
// nothing. `Heroine.Params`/`Player.Params` append the Replace keys and the
// heroine's `HExperience` keys. The per-key table is in
// docs/reference/gameplay/adv.md ("Character parameters").

/// The `ChaFileParameter` members `SaveData.CharaData` exposes
/// (`ChaFileParameter.MemberInit` defaults; the byte members widen to int).
public struct SourceChaFileParameterSubset: Codable, Sendable, Equatable {
    public var lastname = ""
    public var firstname = ""
    public var nickname = ""
    public var personality: Int32 = 0
    public var bloodType: UInt8 = 0
    public var birthMonth: UInt8 = 1
    public var birthDay: UInt8 = 1
    public var clubActivities: UInt8 = 0
    public var weakPoint: Int32 = -1

    public init() {}
    private enum CodingKeys: String, CodingKey {
        case lastname, firstname, nickname, personality, bloodType, birthMonth, birthDay, clubActivities, weakPoint
    }
    /// Missing keys keep the `MemberInit` default.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try box.decodeIfPresent(T.self, forKey: key) ?? fallback }
        lastname = try value(.lastname, lastname); firstname = try value(.firstname, firstname); nickname = try value(.nickname, nickname)
        personality = try value(.personality, personality); bloodType = try value(.bloodType, bloodType)
        birthMonth = try value(.birthMonth, birthMonth); birthDay = try value(.birthDay, birthDay)
        clubActivities = try value(.clubActivities, clubActivities); weakPoint = try value(.weakPoint, weakPoint)
    }
}

/// Lookup tables the getters and `CallNameChange` read. Built privately from
/// the original bundles (`etcetra/list/nickname/`, `etcetra/list/config/`) by
/// `Tools/reverse/analysis/adv_character_tables.py`; never bundled.
public struct SourceCharacterTables: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    /// One `NickName.Param` that `SaveData.LoadNickNameParam` keeps.
    public struct CallName: Codable, Sendable, Equatable {
        public var name: String
        public var id: Int32
        public var category: Int32
        public var bundle: String
        /// `NickName.Param.isSpecial`: `Category == 0`.
        public var isSpecial: Bool { category == 0 }
        public init(name: String, id: Int32, category: Int32, bundle: String) {
            self.name = name; self.id = id; self.category = category; self.bundle = bundle
        }
    }
    public var schemaVersion: Int
    /// `SaveData.nicNameDic`: NickName asset name (`player`, `cNN`) to the
    /// params with a non-empty Name and an ID other than -1, in load order.
    public var callNames: [String: [CallName]]
    /// `SaveData.callDefaultID` after `SaveData.InitializeCall` (Manager.Game.Awake).
    public var callDefaultID: Int32
    /// `Manager.Voice.voiceInfoDic` keys (`VoiceInfo.Param.No`).
    public var voiceNumbers: [Int32]

    public init(callNames: [String: [CallName]], callDefaultID: Int32, voiceNumbers: [Int32]) {
        schemaVersion = Self.schemaVersion; self.callNames = callNames; self.callDefaultID = callDefaultID; self.voiceNumbers = voiceNumbers
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw SourceGameplayExecutionError.invalidData("Character tables exceed 16 MiB") }
        let tables = try JSONDecoder().decode(Self.self, from: data)
        try tables.validate()
        return tables
    }
    func validate() throws {
        guard schemaVersion == Self.schemaVersion, callNames.count <= 1000, voiceNumbers.count <= 100_000,
              callNames.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.count <= 100_000
                  && $0.value.allSatisfy { $0.name.utf8.count <= 4096 && $0.bundle.utf8.count <= 4096 } }) else {
            throw SourceGameplayExecutionError.invalidData("Character table schema or limits")
        }
    }
}

/// Value conversion the parameter setters use.
enum SourceValConvert {
    /// `ValData.Convert(o, type)` = `System.Convert.ChangeType(o, type)` on the
    /// string a command passes, to the runtime type of the key's current value.
    static func changeType(_ text: String, to type: SourceCharacterParameterKey.Command, site: String) throws -> SourceADVValue {
        switch type {
        case .int: return .integer(try SourceADVHandlerArguments.value(SourceCLR.int32Integer(text), "\(site) Convert.ChangeType Int32"))
        case .bool: return .boolean(try SourceADVHandlerArguments.value(SourceCLR.boolean(text), "\(site) Convert.ChangeType Boolean"))
        case .string, .replace: return .string(text)
        }
    }
    /// `int.ToString(format)` for "00"/"000": a sign, then at least `width` digits.
    static func padded(_ value: Int32, _ width: Int) -> String {
        let digits = String(value.magnitude)
        return (value < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
    /// `Illusion.Extensions.MinusThroughToString(format)`: `ToString()` when negative.
    static func minusThrough(_ value: Int32, _ width: Int) -> String { value < 0 ? String(value) : padded(value, width) }
}

/// One `SaveData.CharaData.Params.Data` key.
public struct SourceCharacterParameterKey: Sendable, Equatable {
    /// `Params.Data.Command`.
    public enum Command: String, Codable, Sendable { case replace = "Replace", int = "Int", string = "String", bool = "BOOL" }
    /// The original key (`H_favor`, `P_callID`, `H姓`, …); never renamed.
    public let key: String
    public let command: Command
    /// The recovered class and member the getter reads.
    public let member: String
    /// A public field: `SetADVParam(scenario, key, o)` writes it.
    public let writable: Bool
}

/// Thrown when a key's getter needs a table the binding does not carry.
private func unbound(_ what: String) -> SourceGameplayExecutionError {
    .unsupported("ADV character table not bound: \(what)")
}
/// A definite exception in an original getter or setter.
private func throwsInSource(_ detail: String) -> SourceGameplayExecutionError {
    .unsupported("ADV character source exception: \(detail)")
}

/// `SaveData.CharaData.Names`: the Replace key suffixes (Last, First, Full, Nick).
let sourceCharacterNameSuffixes = ["姓", "名", "名前", "あだ名"]

/// The source call-name lookups shared by heroines and players.
enum SourceCallNames {
    /// `SaveData.GetCallNameList(personality)`: `nicNameDic[personality < 0 ? "player" : $"c{personality:00}"]`.
    static func list(_ personality: Int32, _ tables: SourceCharacterTables?) throws -> [SourceCharacterTables.CallName] {
        guard let tables else { throw unbound("SaveData.nicNameDic (etcetra/list/nickname)") }
        let name = personality < 0 ? "player" : "c" + SourceValConvert.padded(personality, 2)
        guard let list = tables.callNames[name] else { throw throwsInSource("SaveData.GetCallNameList: KeyNotFoundException for \(name)") }
        return list
    }
    /// `SaveData.GetCallName(personality, id)`; a missing ID is null, whose use throws.
    static func find(_ personality: Int32, _ id: Int32, _ tables: SourceCharacterTables?) throws -> SourceCharacterTables.CallName {
        guard let entry = try list(personality, tables).first(where: { $0.id == id }) else {
            throw throwsInSource("SaveData.GetCallName: no call name \(id) (NullReferenceException)")
        }
        return entry
    }
    /// `SaveData.FindCallFileData(personality, id)`: bundle, display name and
    /// the `namelist_[sp_]PP_{0:00}_III` voice asset names for 0...2.
    static func fileData(_ personality: Int32, _ id: Int32, _ tables: SourceCharacterTables?) throws
        -> (name: String, bundle: String, files: [String]) {
        let list = try list(personality, tables)
        guard let entry = list.first(where: { $0.id == id }) else {
            throw throwsInSource("SaveData.FindCallFileData: no call name \(id) (NullReferenceException)")
        }
        var number = id, prefix = "namelist_"
        if entry.isSpecial {
            prefix += "sp_"
            let (offset, overflow) = number.subtractingReportingOverflow(list.filter(\.isSpecial).map(\.id).min()!)
            guard !overflow else { throw throwsInSource("SaveData.FindCallFileData: special ID offset overflow") }
            number = offset
        }
        let stem = prefix + SourceValConvert.padded(personality, 2) + "_"
        let tail = "_" + SourceValConvert.padded(number, 3)
        return (entry.name, entry.bundle, (0..<3).map { stem + SourceValConvert.padded(Int32($0), 2) + tail })
    }
}

/// `SaveData.Heroine` state that its `Params` keys read and write, plus the
/// runtime members their getters depend on. Defaults are `new
/// SaveData.Heroine(isRandomize: false)` with a new `ChaFileControl`: the
/// field initializers, `CharaData` defaults and `ChaFileParameter.MemberInit`.
/// Decoding is lenient: a missing key keeps that default.
public struct SourceHeroineParameters: Codable, Sendable, Equatable {
    // SaveData.CharaData public fields.
    public var callID: Int32 = -1
    public var callName = ""
    public var schoolClass: Int32 = -1
    public var schoolClassIndex: Int32 = -1
    /// `CharaData.charFileInitialized` (auto-property; `Load` sets it).
    public var charFileInitialized = false
    /// `CharaData.parameter` (`charFile.parameter`).
    public var parameter = SourceChaFileParameterSubset()
    // SaveData.Heroine public fields.
    public var favor: Int32 = 0
    public var lewdness: Int32 = 0
    public var hCount: Int32 = 0
    public var isStaff = false
    public var isGirlfriend = false
    public var isAnger = false
    public var anger: Int32 = 0
    public var fixCharaID: Int32 = 0
    public var isTaked = false
    public var isDate = false
    public var nickNameTalkCount: Int32 = 0
    public var myRoomCount: Int32 = 0
    public var confessed = false
    public var isVirgin = true
    public var isAnalVirgin = true
    public var isKiss = false
    public var countNamaInsert: Int32 = 0
    public var countHoushi: Int32 = 0
    public var eventAfterDay: Int32 = 0
    public var isFirstGirlfriend = false
    public var intimacy: Int32 = 0
    public var talkTimeMax: Int32 = 4
    public var talkTime: Int32 = 4
    public var isTalkPoint = false
    public var isLunch = false
    // Members the getters read (not keys themselves).
    /// `hAreaExps` (6 areas), `countKokanH`, `countAnalH`: `HExperience`.
    public var hAreaExps: [Float] = Array(repeating: 0, count: 6)
    public var countKokanH: Float = 0
    public var countAnalH: Float = 0
    /// `m_TalkEvent` (a HashSet; kept sorted): `relation`, `isNickNameEvent`,
    /// and the fixed-event scheduler's completion check.
    public var talkEvent: [Int32] = []
    /// Runtime `coordinates`/`isDresses` (null until the action scene sets them): `NowCoordinate`.
    public var coordinates: [Int32]?
    public var isDresses: [Bool]?
    /// `cachedVoiceNo`: the first `voiceNo` read caches its result.
    public var cachedVoiceNo: Int32?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case callID, callName, schoolClass, schoolClassIndex, charFileInitialized, parameter
        case favor, lewdness, hCount, isStaff, isGirlfriend, isAnger, anger, fixCharaID, isTaked, isDate
        case nickNameTalkCount, myRoomCount, confessed, isVirgin, isAnalVirgin, isKiss, countNamaInsert, countHoushi
        case eventAfterDay, isFirstGirlfriend, intimacy, talkTimeMax, talkTime, isTalkPoint, isLunch
        case hAreaExps, countKokanH, countAnalH, talkEvent, coordinates, isDresses, cachedVoiceNo
    }
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try box.decodeIfPresent(T.self, forKey: key) ?? fallback }
        callID = try value(.callID, callID); callName = try value(.callName, callName)
        schoolClass = try value(.schoolClass, schoolClass); schoolClassIndex = try value(.schoolClassIndex, schoolClassIndex)
        charFileInitialized = try value(.charFileInitialized, charFileInitialized); parameter = try value(.parameter, parameter)
        favor = try value(.favor, favor); lewdness = try value(.lewdness, lewdness); hCount = try value(.hCount, hCount)
        isStaff = try value(.isStaff, isStaff); isGirlfriend = try value(.isGirlfriend, isGirlfriend); isAnger = try value(.isAnger, isAnger)
        anger = try value(.anger, anger); fixCharaID = try value(.fixCharaID, fixCharaID); isTaked = try value(.isTaked, isTaked)
        isDate = try value(.isDate, isDate); nickNameTalkCount = try value(.nickNameTalkCount, nickNameTalkCount)
        myRoomCount = try value(.myRoomCount, myRoomCount); confessed = try value(.confessed, confessed)
        isVirgin = try value(.isVirgin, isVirgin); isAnalVirgin = try value(.isAnalVirgin, isAnalVirgin); isKiss = try value(.isKiss, isKiss)
        countNamaInsert = try value(.countNamaInsert, countNamaInsert); countHoushi = try value(.countHoushi, countHoushi)
        eventAfterDay = try value(.eventAfterDay, eventAfterDay); isFirstGirlfriend = try value(.isFirstGirlfriend, isFirstGirlfriend)
        intimacy = try value(.intimacy, intimacy); talkTimeMax = try value(.talkTimeMax, talkTimeMax); talkTime = try value(.talkTime, talkTime)
        isTalkPoint = try value(.isTalkPoint, isTalkPoint); isLunch = try value(.isLunch, isLunch)
        hAreaExps = try value(.hAreaExps, hAreaExps); countKokanH = try value(.countKokanH, countKokanH); countAnalH = try value(.countAnalH, countAnalH)
        talkEvent = try value(.talkEvent, talkEvent)
        coordinates = try box.decodeIfPresent([Int32].self, forKey: .coordinates)
        isDresses = try box.decodeIfPresent([Bool].self, forKey: .isDresses)
        cachedVoiceNo = try box.decodeIfPresent(Int32.self, forKey: .cachedVoiceNo)
        try validate()
    }

    func validate() throws {
        guard callName.utf8.count <= 65536, parameter.lastname.utf8.count <= 65536, parameter.firstname.utf8.count <= 65536,
              parameter.nickname.utf8.count <= 65536, hAreaExps.count <= 1024, hAreaExps.allSatisfy(\.isFinite),
              countKokanH.isFinite, countAnalH.isFinite, talkEvent.count <= 100_000, Set(talkEvent).count == talkEvent.count,
              (coordinates?.count ?? 0) <= 1024, (isDresses?.count ?? 0) <= 1024 else {
            throw SourceGameplayExecutionError.invalidData("Heroine parameter limits")
        }
    }

    /// `HeroineKey` keys in `param.datas` order: `Heroine` fields, inherited
    /// `CharaData` fields, `Heroine` then `CharaData` properties (Mono
    /// reflection order; no value depends on it, see adv.md), then the
    /// `Heroine.Params` additions.
    public static let keys: [SourceCharacterParameterKey] = {
        func field(_ name: String, _ command: SourceCharacterParameterKey.Command, _ owner: String = "SaveData.Heroine") -> SourceCharacterParameterKey {
            .init(key: "H_" + name, command: command, member: "\(owner).\(name)", writable: true)
        }
        func property(_ name: String, _ command: SourceCharacterParameterKey.Command, _ owner: String = "SaveData.Heroine") -> SourceCharacterParameterKey {
            .init(key: "H_" + name, command: command, member: "\(owner).\(name)", writable: false)
        }
        let heroineFields: [(String, SourceCharacterParameterKey.Command)] = [
            ("favor", .int), ("lewdness", .int), ("hCount", .int), ("isStaff", .bool), ("isGirlfriend", .bool), ("isAnger", .bool),
            ("anger", .int), ("fixCharaID", .int), ("isTaked", .bool), ("isDate", .bool), ("nickNameTalkCount", .int),
            ("myRoomCount", .int), ("confessed", .bool), ("isVirgin", .bool), ("isAnalVirgin", .bool), ("isKiss", .bool),
            ("countNamaInsert", .int), ("countHoushi", .int), ("eventAfterDay", .int), ("isFirstGirlfriend", .bool),
            ("intimacy", .int), ("talkTimeMax", .int), ("talkTime", .int), ("isTalkPoint", .bool), ("isLunch", .bool)]
        let heroineProperties: [(String, SourceCharacterParameterKey.Command)] = [
            ("isTeacher", .bool), ("FixCharaIDOrPersonality", .int), ("ChaName", .string), ("ChaVoice", .string), ("voiceNo", .int),
            ("relation", .int), ("isNickNameEvent", .bool), ("NowCoordinate", .int)]
        let hExperience = "SaveData.Heroine.HExperience"
        return heroineFields.map { field($0.0, $0.1) } + SourceCharacterData.fields.map { field($0.0, $0.1, "SaveData.CharaData") }
            + heroineProperties.map { property($0.0, $0.1) }
            + SourceCharacterData.properties.map { property($0.0, $0.1, "SaveData.CharaData") }
            + [.init(key: "H", command: .replace, member: "string.Empty", writable: false)]
            + zip(sourceCharacterNameSuffixes, ["lastname", "firstname", "Name", "nickname"]).map {
                .init(key: "H" + $0.0, command: .replace, member: "SaveData.CharaData.\($0.1)", writable: false)
            }
            + [.init(key: "P" + sourceCharacterNameSuffixes[3], command: .replace, member: "SaveData.CharaData.callName", writable: false),
               .init(key: "H_HExperience", command: .string, member: hExperience + ".ToString()", writable: false),
               .init(key: "H_HExperienceIndex", command: .int, member: "(int)" + hExperience, writable: false)]
    }()

    /// `Heroine.HExperienceKind` member names (`H_HExperience` is `ToString()`).
    public static let hExperienceNames = ["初めて", "不慣れ", "慣れ", "淫乱"]

    /// `Heroine.HExperience`: clamps `lewdness` to 0...100 as a side effect.
    mutating func hExperience() throws -> Int32 {
        lewdness = min(max(lewdness, 0), 100)
        guard hCount >= 1 else { return 0 }
        guard !hAreaExps.isEmpty else { throw throwsInSource("Heroine.HExperience: new float[-1] (OverflowException)") }
        let areas = hAreaExps.dropFirst()
        let practised = countKokanH >= 100 && countAnalH >= 100 && !areas.contains { $0 < 100 }
        return !practised ? 1 : (lewdness != 100 ? 2 : 3)
    }
    var fixCharaIDOrPersonality: Int32 { fixCharaID == 0 ? parameter.personality : fixCharaID }
    /// `CharaData.callMyID`: own call ID, else `Manager.Game.Player.callID`
    /// (when a Game instance exists), else `SaveData.callDefaultID`.
    func callMyID(_ player: SourcePlayerParameters?, _ tables: SourceCharacterTables?) throws -> Int32 {
        var id = callID
        if id == -1 {
            if let player { id = player.callID }
            if id == -1 {
                guard let tables else { throw unbound("SaveData.callDefaultID") }
                id = tables.callDefaultID
            }
        }
        return id
    }
    /// `Heroine.voiceNo`: cached `voiceInfoDic[FixCharaIDOrPersonality].No`, else `personality`.
    mutating func voiceNo(_ tables: SourceCharacterTables?) throws -> Int32 {
        if let cachedVoiceNo { return cachedVoiceNo }
        guard let tables else { throw unbound("Manager.Voice.voiceInfoDic (etcetra/list/config)") }
        let key = fixCharaIDOrPersonality
        let value = tables.voiceNumbers.contains(key) ? key : parameter.personality
        cachedVoiceNo = value
        return value
    }

    /// The `Params.Data` getter for `key` (side effects included).
    mutating func read(_ key: SourceCharacterParameterKey, player: SourcePlayerParameters?,
                       tables: SourceCharacterTables?) throws -> SourceADVValue {
        let name = key.key.hasPrefix("H_") ? String(key.key.dropFirst(2)) : key.key
        switch name {
        case "favor": return .integer(favor)
        case "lewdness": return .integer(lewdness)
        case "hCount": return .integer(hCount)
        case "isStaff": return .boolean(isStaff)
        case "isGirlfriend": return .boolean(isGirlfriend)
        case "isAnger": return .boolean(isAnger)
        case "anger": return .integer(anger)
        case "fixCharaID": return .integer(fixCharaID)
        case "isTaked": return .boolean(isTaked)
        case "isDate": return .boolean(isDate)
        case "nickNameTalkCount": return .integer(nickNameTalkCount)
        case "myRoomCount": return .integer(myRoomCount)
        case "confessed": return .boolean(confessed)
        case "isVirgin": return .boolean(isVirgin)
        case "isAnalVirgin": return .boolean(isAnalVirgin)
        case "isKiss": return .boolean(isKiss)
        case "countNamaInsert": return .integer(countNamaInsert)
        case "countHoushi": return .integer(countHoushi)
        case "eventAfterDay": return .integer(eventAfterDay)
        case "isFirstGirlfriend": return .boolean(isFirstGirlfriend)
        case "intimacy": return .integer(intimacy)
        case "talkTimeMax": return .integer(talkTimeMax)
        case "talkTime": return .integer(talkTime)
        case "isTalkPoint": return .boolean(isTalkPoint)
        case "isLunch": return .boolean(isLunch)
        case "callID": return .integer(callID)
        case "callName": return .string(callName)
        case "schoolClass": return .integer(schoolClass)
        case "schoolClassIndex": return .integer(schoolClassIndex)
        case "isTeacher": return .boolean((-4 ... -1).contains(fixCharaID))
        case "FixCharaIDOrPersonality": return .integer(fixCharaIDOrPersonality)
        case "ChaName": return .string("c" + SourceValConvert.minusThrough(fixCharaIDOrPersonality, 2))
        case "ChaVoice": return .string("c" + SourceValConvert.minusThrough(try voiceNo(tables), 2))
        case "voiceNo": return .integer(try voiceNo(tables))
        case "relation":
            if isGirlfriend { return .integer(2) }
            if talkEvent.contains(2) { return .integer(1) }
            return .integer(talkEvent.contains(0) || talkEvent.contains(1) ? 0 : -1)
        case "isNickNameEvent": return .boolean(talkEvent.contains(89) || talkEvent.contains(90))
        case "NowCoordinate":
            guard let isDresses, !isDresses.isEmpty else {
                guard let coordinates, !coordinates.isEmpty else { return .integer(0) } // SafeGet(0)
                return .integer(coordinates[0])
            }
            guard let coordinates else { throw throwsInSource("Heroine.NowCoordinate: coordinates is null (NullReferenceException)") }
            let index = isDresses.firstIndex(of: false) ?? coordinates.count - 1
            guard coordinates.indices.contains(index) else { throw throwsInSource("Heroine.NowCoordinate: IndexOutOfRangeException") }
            return .integer(coordinates[index])
        case "isNickNameNormal":
            return .boolean(!(try SourceCallNames.find(parameter.personality, callMyID(player, tables), tables).isSpecial))
        case "callMyID": return .integer(try callMyID(player, tables))
        case "HExperience": return .string(Self.hExperienceNames[Int(try hExperience())])
        case "HExperienceIndex": return .integer(try hExperience())
        case "H": return .string("")
        default:
            if let common = SourceCharacterData.read(name, parameter: parameter, charFileInitialized: charFileInitialized) { return common }
            if key.key == "H" + sourceCharacterNameSuffixes[0] { return .string(parameter.lastname) }
            if key.key == "H" + sourceCharacterNameSuffixes[1] { return .string(parameter.firstname) }
            if key.key == "H" + sourceCharacterNameSuffixes[2] { return .string(parameter.lastname + " " + parameter.firstname) }
            if key.key == "H" + sourceCharacterNameSuffixes[3] { return .string(parameter.nickname) }
            if key.key == "P" + sourceCharacterNameSuffixes[3] { return .string(callName) }
            throw SourceGameplayExecutionError.invalidData("Unknown heroine parameter key \(key.key)")
        }
    }

    /// The field setter; a property key changes nothing.
    mutating func write(_ key: SourceCharacterParameterKey, _ value: SourceADVValue) {
        guard key.writable else { return }
        let name = String(key.key.dropFirst(2))
        switch (name, value) {
        case ("favor", .integer(let v)): favor = v
        case ("lewdness", .integer(let v)): lewdness = v
        case ("hCount", .integer(let v)): hCount = v
        case ("isStaff", .boolean(let v)): isStaff = v
        case ("isGirlfriend", .boolean(let v)): isGirlfriend = v
        case ("isAnger", .boolean(let v)): isAnger = v
        case ("anger", .integer(let v)): anger = v
        case ("fixCharaID", .integer(let v)): fixCharaID = v
        case ("isTaked", .boolean(let v)): isTaked = v
        case ("isDate", .boolean(let v)): isDate = v
        case ("nickNameTalkCount", .integer(let v)): nickNameTalkCount = v
        case ("myRoomCount", .integer(let v)): myRoomCount = v
        case ("confessed", .boolean(let v)): confessed = v
        case ("isVirgin", .boolean(let v)): isVirgin = v
        case ("isAnalVirgin", .boolean(let v)): isAnalVirgin = v
        case ("isKiss", .boolean(let v)): isKiss = v
        case ("countNamaInsert", .integer(let v)): countNamaInsert = v
        case ("countHoushi", .integer(let v)): countHoushi = v
        case ("eventAfterDay", .integer(let v)): eventAfterDay = v
        case ("isFirstGirlfriend", .boolean(let v)): isFirstGirlfriend = v
        case ("intimacy", .integer(let v)): intimacy = v
        case ("talkTimeMax", .integer(let v)): talkTimeMax = v
        case ("talkTime", .integer(let v)): talkTime = v
        case ("isTalkPoint", .boolean(let v)): isTalkPoint = v
        case ("isLunch", .boolean(let v)): isLunch = v
        case ("callID", .integer(let v)): callID = v
        case ("callName", .string(let v)): callName = v
        case ("schoolClass", .integer(let v)): schoolClass = v
        case ("schoolClassIndex", .integer(let v)): schoolClassIndex = v
        default: preconditionFailure("Heroine field \(key.key) written with \(value.typeName)")
        }
    }
}

/// `SaveData.Player` state its `Params` keys read and write. Defaults are
/// `new SaveData.Player(isRandomize: false)`: field initializers plus
/// `Player.Initialize` (`schoolClass` 1, `schoolClassIndex` 20, `callID =
/// SaveData.callDefaultID`, which `Manager.Game.Awake` sets before `NewGame`).
public struct SourcePlayerParameters: Codable, Sendable, Equatable {
    public var callID: Int32
    public var callName = ""
    public var schoolClass: Int32 = 1
    public var schoolClassIndex: Int32 = 20
    public var charFileInitialized = false
    public var parameter = SourceChaFileParameterSubset()
    public var intellect: Int32 = 0
    public var physical: Int32 = 0
    public var hentai: Int32 = 0
    public var actionCount: Int32 = 5
    public var girlfriendedCnt: Int32 = 0
    public var hcount: Int32 = 0
    public var hPeopleCount: Int32 = 0
    public var orgCount: Int32 = 0
    public var changeClothesType: Int32 = 0
    public var cachedVoiceNo: Int32?

    /// A new-game player; `callDefaultID` is `SourceCharacterTables.callDefaultID`.
    public init(callDefaultID: Int32) { callID = callDefaultID }

    private enum CodingKeys: String, CodingKey {
        case callID, callName, schoolClass, schoolClassIndex, charFileInitialized, parameter
        case intellect, physical, hentai, actionCount, girlfriendedCnt, hcount, hPeopleCount, orgCount, changeClothesType, cachedVoiceNo
    }
    /// `callID` is required (its default comes from the tables); other missing keys keep their default.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try box.decodeIfPresent(T.self, forKey: key) ?? fallback }
        callID = try box.decode(Int32.self, forKey: .callID)
        callName = try value(.callName, callName); schoolClass = try value(.schoolClass, schoolClass)
        schoolClassIndex = try value(.schoolClassIndex, schoolClassIndex); charFileInitialized = try value(.charFileInitialized, charFileInitialized)
        parameter = try value(.parameter, parameter); intellect = try value(.intellect, intellect); physical = try value(.physical, physical)
        hentai = try value(.hentai, hentai); actionCount = try value(.actionCount, actionCount)
        girlfriendedCnt = try value(.girlfriendedCnt, girlfriendedCnt); hcount = try value(.hcount, hcount)
        hPeopleCount = try value(.hPeopleCount, hPeopleCount); orgCount = try value(.orgCount, orgCount)
        changeClothesType = try value(.changeClothesType, changeClothesType)
        cachedVoiceNo = try box.decodeIfPresent(Int32.self, forKey: .cachedVoiceNo)
        guard callName.utf8.count <= 65536, parameter.lastname.utf8.count <= 65536, parameter.firstname.utf8.count <= 65536,
              parameter.nickname.utf8.count <= 65536 else { throw SourceGameplayExecutionError.invalidData("Player parameter limits") }
    }

    /// `Player.Params` keys: `Player` fields (`playTimeCalc` float and
    /// `playTime` uint are not string/int/bool), `CharaData` fields, the
    /// `voiceNo` override, `CharaData` properties, then the Replace keys.
    public static let keys: [SourceCharacterParameterKey] = {
        let fields: [(String, SourceCharacterParameterKey.Command)] = [
            ("intellect", .int), ("physical", .int), ("hentai", .int), ("actionCount", .int), ("girlfriendedCnt", .int),
            ("hcount", .int), ("hPeopleCount", .int), ("orgCount", .int), ("changeClothesType", .int)]
        return fields.map { .init(key: "P_" + $0.0, command: $0.1, member: "SaveData.Player.\($0.0)", writable: true) }
            + SourceCharacterData.fields.map { .init(key: "P_" + $0.0, command: $0.1, member: "SaveData.CharaData.\($0.0)", writable: true) }
            + [.init(key: "P_voiceNo", command: .int, member: "SaveData.Player.voiceNo", writable: false)]
            + SourceCharacterData.properties.map { .init(key: "P_" + $0.0, command: $0.1, member: "SaveData.CharaData.\($0.0)", writable: false) }
            + [.init(key: "P", command: .replace, member: "string.Empty", writable: false)]
            + zip(sourceCharacterNameSuffixes.prefix(3), ["lastname", "firstname", "Name"]).map {
                .init(key: "P" + $0.0, command: .replace, member: "SaveData.CharaData.\($0.1)", writable: false)
            }
    }()

    /// `CharaData.callMyID` for the Game's own player.
    func callMyID(_ tables: SourceCharacterTables?) throws -> Int32 {
        guard callID == -1 else { return callID }
        guard let tables else { throw unbound("SaveData.callDefaultID") }
        return tables.callDefaultID
    }
    /// `Player.voiceNo`: cached `voiceInfoDic[-100].No`, else `personality`.
    mutating func voiceNo(_ tables: SourceCharacterTables?) throws -> Int32 {
        if let cachedVoiceNo { return cachedVoiceNo }
        guard let tables else { throw unbound("Manager.Voice.voiceInfoDic (etcetra/list/config)") }
        let value = tables.voiceNumbers.contains(-100) ? -100 : parameter.personality
        cachedVoiceNo = value
        return value
    }
    mutating func read(_ key: SourceCharacterParameterKey, tables: SourceCharacterTables?) throws -> SourceADVValue {
        let name = key.key.hasPrefix("P_") ? String(key.key.dropFirst(2)) : key.key
        switch name {
        case "intellect": return .integer(intellect)
        case "physical": return .integer(physical)
        case "hentai": return .integer(hentai)
        case "actionCount": return .integer(actionCount)
        case "girlfriendedCnt": return .integer(girlfriendedCnt)
        case "hcount": return .integer(hcount)
        case "hPeopleCount": return .integer(hPeopleCount)
        case "orgCount": return .integer(orgCount)
        case "changeClothesType": return .integer(changeClothesType)
        case "callID": return .integer(callID)
        case "callName": return .string(callName)
        case "schoolClass": return .integer(schoolClass)
        case "schoolClassIndex": return .integer(schoolClassIndex)
        case "voiceNo": return .integer(try voiceNo(tables))
        case "isNickNameNormal": return .boolean(!(try SourceCallNames.find(-1, callMyID(tables), tables).isSpecial))
        case "callMyID": return .integer(try callMyID(tables))
        case "P": return .string("")
        default:
            if let common = SourceCharacterData.read(name, parameter: parameter, charFileInitialized: charFileInitialized) { return common }
            if key.key == "P" + sourceCharacterNameSuffixes[0] { return .string(parameter.lastname) }
            if key.key == "P" + sourceCharacterNameSuffixes[1] { return .string(parameter.firstname) }
            if key.key == "P" + sourceCharacterNameSuffixes[2] { return .string(parameter.lastname + " " + parameter.firstname) }
            throw SourceGameplayExecutionError.invalidData("Unknown player parameter key \(key.key)")
        }
    }
    mutating func write(_ key: SourceCharacterParameterKey, _ value: SourceADVValue) {
        guard key.writable else { return }
        switch (String(key.key.dropFirst(2)), value) {
        case ("intellect", .integer(let v)): intellect = v
        case ("physical", .integer(let v)): physical = v
        case ("hentai", .integer(let v)): hentai = v
        case ("actionCount", .integer(let v)): actionCount = v
        case ("girlfriendedCnt", .integer(let v)): girlfriendedCnt = v
        case ("hcount", .integer(let v)): hcount = v
        case ("hPeopleCount", .integer(let v)): hPeopleCount = v
        case ("orgCount", .integer(let v)): orgCount = v
        case ("changeClothesType", .integer(let v)): changeClothesType = v
        case ("callID", .integer(let v)): callID = v
        case ("callName", .string(let v)): callName = v
        case ("schoolClass", .integer(let v)): schoolClass = v
        case ("schoolClassIndex", .integer(let v)): schoolClassIndex = v
        default: preconditionFailure("Player field \(key.key) written with \(value.typeName)")
        }
    }
}

/// Keys `SaveData.CharaData` contributes to both prefixes.
enum SourceCharacterData {
    /// Public fields (`nameType` is an enum and is not a key).
    static let fields: [(String, SourceCharacterParameterKey.Command)] = [
        ("callID", .int), ("callName", .string), ("schoolClass", .int), ("schoolClassIndex", .int)]
    /// Public properties other than the abstract `voiceNo` (`voicePitch` is
    /// float; `denial`, `charFile`, `parameter`, `root`, … are other types).
    static let properties: [(String, SourceCharacterParameterKey.Command)] = [
        ("isNickNameNormal", .bool), ("callMyID", .int), ("Name", .string), ("lastname", .string), ("firstname", .string),
        ("personality", .int), ("bloodType", .int), ("birthMonth", .int), ("birthDay", .int), ("clubActivities", .int),
        ("nickname", .string), ("weakPoint", .int), ("charFileInitialized", .bool)]
    /// Table-free `CharaData` property getters over `charFile.parameter`.
    static func read(_ name: String, parameter: SourceChaFileParameterSubset, charFileInitialized: Bool) -> SourceADVValue? {
        switch name {
        case "Name": return .string(parameter.lastname + " " + parameter.firstname)
        case "lastname": return .string(parameter.lastname)
        case "firstname": return .string(parameter.firstname)
        case "personality": return .integer(parameter.personality)
        case "bloodType": return .integer(Int32(parameter.bloodType))
        case "birthMonth": return .integer(Int32(parameter.birthMonth))
        case "birthDay": return .integer(Int32(parameter.birthDay))
        case "clubActivities": return .integer(Int32(parameter.clubActivities))
        case "nickname": return .string(parameter.nickname)
        case "weakPoint": return .integer(parameter.weakPoint)
        case "charFileInitialized": return .boolean(charFileInitialized)
        default: return nil
        }
    }
}
