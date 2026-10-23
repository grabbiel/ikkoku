import Foundation

/// `Manager.Game.scenarioParameterDic`: `Game.Awake` loads every
/// `ScenarioData` in the bundles under `adv/scenario/common_param/`
/// (subdirectories included, bundle names sorted ordinally); a later asset with
/// the same name replaces an earlier one. `ParameterFile` inserts the named
/// list after its own line. Built privately by
/// `Tools/reverse/analysis/adv_character_tables.py`; never bundled.
public struct SourceADVParameterLibrary: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var programs: [String: [SourceADVProgram.Command]]

    public init(programs: [String: [SourceADVProgram.Command]]) {
        schemaVersion = Self.schemaVersion
        self.programs = programs
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw SourceGameplayExecutionError.invalidData("Parameter library exceeds 16 MiB") }
        let library = try JSONDecoder().decode(Self.self, from: data)
        try library.validate()
        return library
    }
    func validate() throws {
        guard schemaVersion == Self.schemaVersion, programs.count <= 10_000,
              programs.reduce(0, { $0 + $1.value.count }) <= 100_000,
              programs.allSatisfy({ $0.key.utf8.count <= 4096
                  && $0.value.allSatisfy { $0.args.count <= 1024 && $0.args.allSatisfy { $0.utf8.count <= 65536 } } }) else {
            throw SourceGameplayExecutionError.invalidData("Parameter library schema or limits")
        }
    }
}

/// The interpreter's `TextScenario.currentHeroine` (`currentChara.heroine`),
/// `Manager.Game.Player`, and the tables their getters read.
public struct SourceADVCharacterBinding: Codable, Sendable, Equatable {
    public var heroine: SourceHeroineParameters
    /// `Manager.Game.Player`; nil models no `Manager.Game` instance, so
    /// `callMyID` falls back to `SaveData.callDefaultID` directly.
    public var player: SourcePlayerParameters?
    public var tables: SourceCharacterTables?

    public init(heroine: SourceHeroineParameters, player: SourcePlayerParameters?, tables: SourceCharacterTables?) {
        self.heroine = heroine; self.player = player; self.tables = tables
    }

    func validate() throws {
        try heroine.validate()
        try tables?.validate()
    }

    /// `Heroine.SetADVParam(scenario)` (CharaChange): every Int, BOOL and
    /// String key's getter in `param.datas` order into `Vars` (typed: the
    /// conversion to the value's own type is the identity), then every Replace
    /// key into `Replaces`.
    mutating func seed(variables: inout [String: SourceADVValue], replaces: inout [String: String]) throws {
        for key in SourceHeroineParameters.keys where key.command != .replace {
            variables[key.key] = try heroine.read(key, player: player, tables: tables)
        }
        try refreshReplaces(&replaces)
    }

    /// `Heroine.SetADVParam(scenario, key, o)` (HeroineParam): an unknown key
    /// does nothing; otherwise the getter runs (`data.value.GetType()`), `o`
    /// converts to that type, a field takes the value (a property is
    /// unchanged), `Vars[key]` is set, `H_callID` runs `CallNameChange`, and
    /// every Replace key is refreshed. Effects before a throw are kept, as in
    /// the source.
    mutating func setHeroine(_ name: String, _ value: String, variables: inout [String: SourceADVValue],
                             replaces: inout [String: String]) throws {
        guard let key = SourceHeroineParameters.keys.first(where: { $0.key == name }) else { return }
        let current = try heroine.read(key, player: player, tables: tables)
        let converted = try SourceValConvert.changeType(value, to: Self.command(of: current), site: "SaveData.Heroine.SetADVParam(\(name))")
        heroine.write(key, converted)
        variables[key.key] = converted
        if name == "H_callID" { try callNameChange(variables: &variables, replaces: &replaces) }
        try refreshReplaces(&replaces)
    }

    /// `Player.SetADVParam(scenario, key, o)` (PlayerParam): as the heroine's,
    /// without the call-name path or the Replace refresh. No installed scenario
    /// uses PlayerParam; the native command is not implemented.
    mutating func setPlayer(_ name: String, _ value: String, variables: inout [String: SourceADVValue]) throws {
        guard let key = SourcePlayerParameters.keys.first(where: { $0.key == name }) else { return }
        guard player != nil else { throw SourceGameplayExecutionError.unsupported("ADV character source exception: Manager.Game.Player is null") }
        let current = try player!.read(key, tables: tables)
        let converted = try SourceValConvert.changeType(value, to: Self.command(of: current), site: "SaveData.Player.SetADVParam(\(name))")
        player!.write(key, converted)
        variables[key.key] = converted
    }

    /// `Player.SetADVParam(scenario)`: the player's typed seed.
    mutating func seedPlayer(variables: inout [String: SourceADVValue], replaces: inout [String: String]) throws {
        guard player != nil else { throw SourceGameplayExecutionError.unsupported("ADV character source exception: Manager.Game.Player is null") }
        for key in SourcePlayerParameters.keys where key.command != .replace {
            variables[key.key] = try player!.read(key, tables: tables)
        }
        for key in SourcePlayerParameters.keys where key.command == .replace {
            replaces[key.key] = try player!.read(key, tables: tables).sourceString
        }
    }

    /// `Heroine.CallNameChange(scenario)`: for `callMyID != -1`, the call-name
    /// voice bundle and file names, the new `callName` field, `Vars["H_callName"]`
    /// and `Replaces["Pあだ名"]`.
    mutating func callNameChange(variables: inout [String: SourceADVValue], replaces: inout [String: String]) throws {
        let id = try heroine.callMyID(player, tables)
        guard id != -1 else { return }
        let data = try SourceCallNames.fileData(heroine.parameter.personality, id, tables)
        variables["callBundle"] = .string(data.bundle)
        for (index, file) in data.files.enumerated() { variables["callName\(index)"] = .string(file) }
        heroine.callName = data.name
        variables["H_callName"] = .string(heroine.callName)
        replaces["P" + sourceCharacterNameSuffixes[3]] = heroine.callName
    }

    private mutating func refreshReplaces(_ replaces: inout [String: String]) throws {
        for key in SourceHeroineParameters.keys where key.command == .replace {
            replaces[key.key] = try heroine.read(key, player: player, tables: tables).sourceString
        }
    }

    private static func command(of value: SourceADVValue) -> SourceCharacterParameterKey.Command {
        switch value {
        case .integer: .int
        case .boolean: .bool
        case .string, .float: .string // No key has a float value.
        }
    }
}
