import Foundation

/// The automated run a launch's `IKKOKU_*` environment requests, checked once at
/// startup before any work (A06).
///
/// Startup used to discover the request piecemeal: each hook read its own
/// variables, the first mode it reached exited, and a variable that no reached
/// code read was silently ignored. `validate` classifies every variable the app
/// reads up front and rejects, in one error that names each offending variable:
///
/// - more than one capture mode (only the first that startup reaches would run);
/// - a mode without the variable it writes to (`IKKOKU_CAPTURE_RIG`, `_MODEL` and
///   `_SCENE` need `IKKOKU_AUTOCAPTURE`; each scenario needs its report path);
/// - a capture option that the requested mode never reads, or that depends on
///   another option or value that is absent;
/// - options whose combination would capture other content than requested, such
///   as `IKKOKU_CARD` discarding the `IKKOKU_SOURCE_CARD` preview;
/// - an empty value, an unknown `IKKOKU_CAPTURE_*`, `IKKOKU_ORIGINAL_FRAME_*` or
///   `IKKOKU_BENCHMARK_*` name, or a value that the mode would replace with its
///   default or ignore.
///
/// Startup inputs (`IKKOKU_SOURCE_SCENE`, `IKKOKU_SOURCE_CARD`, plugin mounts …)
/// and data sources (`IKKOKU_SOURCE_AVATAR`, catalogs …) are not capture options:
/// an interactive launch reads them too, and one environment file often supplies
/// them to several modes, so a mode that does not read them ignores them. Only an
/// empty value is rejected for them.
///
/// The check is pure: it reads only the dictionary it is given. Whether an input
/// loads is decided when it is read; in an automated run (`isAutomated`) a failed
/// input then exits 1, naming the variable, its value and the error
/// (`CaptureInputError`).
public struct CaptureRequest: Sendable, Equatable {
    /// What the launch does. At most one mode runs per launch.
    public enum Mode: Sendable, Hashable, CaseIterable {
        /// No headless mode: the editor window opens, for a user or for
        /// `IKKOKU_CAPTURE_UI`.
        case interactive
        /// `IKKOKU_ORIGINAL_FRAME_PROBE`: diagnostic renders beside the frame file.
        case originalFrameProbe
        /// `IKKOKU_LIVE_SOURCE_PROBE`: the live source-shader measurement renders,
        /// written to `IKKOKU_LIVE_SOURCE_OUTPUT` (R1/CMT-04).
        case liveSourceShaderProbe
        /// `IKKOKU_CAPTURE_RIG`: a converted source rig, written to `IKKOKU_AUTOCAPTURE`.
        case rigCapture
        /// `IKKOKU_CAPTURE_MODEL`: one static model, written to `IKKOKU_AUTOCAPTURE`.
        case modelCapture
        /// `IKKOKU_CAPTURE_SCENE`: a native Studio scene, written to `IKKOKU_AUTOCAPTURE`.
        case sceneCapture
        /// `IKKOKU_MAKER_SCENARIO` with `IKKOKU_MAKER_SCENARIO_REPORT`.
        case makerScenario
        /// `IKKOKU_STUDIO_SCENARIO` with `IKKOKU_STUDIO_SCENARIO_REPORT`.
        case studioScenario
        /// `IKKOKU_GAMEPLAY_SCENARIO` with `IKKOKU_GAMEPLAY_SCENARIO_REPORT`: the
        /// native gameplay host (A-T01), run before the engine and editors start.
        case gameplayScenario
        /// `IKKOKU_RENDER_THUMBS`: one preview per catalog entry.
        case thumbnails
        /// `IKKOKU_AUTOCAPTURE` without a rig, model or scene capture: the Maker
        /// frame, or the Studio frame with `IKKOKU_SOURCE_SCENE`,
        /// `IKKOKU_CAPTURE_STUDIO` or `IKKOKU_LOAD_SCENE`.
        case appCapture
        /// `IKKOKU_PERF_TRACE`: the editor window opens, drives one workload
        /// (`IKKOKU_PERF_WORKLOAD`) for a fixed time, writes the per-frame report
        /// to the variable's path and exits (R7).
        case perfTrace

        /// How messages name the mode, with the variable that selects it.
        public var label: String {
            switch self {
            case .interactive: return "the interactive editor"
            case .originalFrameProbe: return "the original-frame probe (IKKOKU_ORIGINAL_FRAME_PROBE)"
            case .liveSourceShaderProbe: return "the live source-shader probe (IKKOKU_LIVE_SOURCE_PROBE)"
            case .rigCapture: return "source rig capture (IKKOKU_CAPTURE_RIG)"
            case .modelCapture: return "static model capture (IKKOKU_CAPTURE_MODEL)"
            case .sceneCapture: return "native scene capture (IKKOKU_CAPTURE_SCENE)"
            case .makerScenario: return "the Maker scenario (IKKOKU_MAKER_SCENARIO)"
            case .studioScenario: return "the Studio scenario (IKKOKU_STUDIO_SCENARIO)"
            case .gameplayScenario: return "the gameplay scenario (IKKOKU_GAMEPLAY_SCENARIO)"
            case .thumbnails: return "catalog thumbnails (IKKOKU_RENDER_THUMBS)"
            case .appCapture: return "the Maker/Studio app capture (IKKOKU_AUTOCAPTURE without a rig, model or scene capture)"
            case .perfTrace: return "the performance trace (IKKOKU_PERF_TRACE)"
            }
        }
    }

    public let mode: Mode
    /// `IKKOKU_CAPTURE_UI`: snapshot the editor window, alone or after an app capture.
    public let capturesWindow: Bool

    public init(mode: Mode, capturesWindow: Bool) {
        self.mode = mode
        self.capturesWindow = capturesWindow
    }

    /// True when the launch must end with an exit status instead of waiting for a
    /// user, so a startup input that fails exits 1 rather than becoming an alert.
    public var isAutomated: Bool { mode != .interactive || capturesWindow }

    /// Every `IKKOKU_*` variable the app reads, each classified exactly once: mode
    /// selectors, capture options, window-capture options, startup inputs and data
    /// sources.
    public static var knownVariables: [String] {
        var names: [String] = [autocapture, windowCapture]
        names += modeSelectors.map { $0.variable }
        names += scopedOptions.map { $0.variable }
        names += windowOptions
        names += startupInputs
        names += dataSources
        return names
    }

    /// Validates `environment` (normally `ProcessInfo.processInfo.environment`).
    /// - Throws: `CaptureRequestError` listing every problem found.
    public static func validate(_ environment: [String: String]) throws -> CaptureRequest {
        var problems: [CaptureRequestError.Problem] = []
        // Variables whose problem is already reported; later checks skip them so
        // each cause is reported once.
        var settled: Set<String> = []
        func isSet(_ variable: String) -> Bool { environment[variable] != nil }
        func report(_ variables: [String], _ reason: String) {
            problems.append(CaptureRequestError.Problem(variables: variables, reason: reason))
            settled.formUnion(variables)
        }

        // 1. Empty values and misspelled capture names.
        for variable in knownVariables where environment[variable]?.isEmpty == true {
            report([variable], "is set but empty")
        }
        let known = Set(knownVariables)
        for variable in environment.keys.sorted() where !known.contains(variable)
            && capturePrefixes.contains(where: { variable.hasPrefix($0) }) {
            report([variable], "is not a capture variable this app reads; check the spelling")
        }

        // 2. At most one mode. IKKOKU_AUTOCAPTURE is the output of a rig, model or
        // scene capture; otherwise it selects the app capture itself.
        var selected = modeSelectors.filter { isSet($0.variable) }
        let writesAutocapture: Set<Mode> = [.rigCapture, .modelCapture, .sceneCapture]
        if isSet(autocapture), !selected.contains(where: { writesAutocapture.contains($0.mode) }) {
            selected.append(ModeSelector(autocapture, .appCapture))
        }
        let requested = joinedList(selected.map { $0.mode.label }, "and")
        if selected.count > 1 {
            report(selected.map { $0.variable }, "only one capture mode runs per launch, but these request \(requested)")
        }
        let modes: Set<Mode> = selected.isEmpty ? Set([Mode.interactive]) : Set(selected.map { $0.mode })
        // The one requested mode, or nil when the modes conflict.
        let single: Mode? = modes.count == 1 ? modes.first : nil

        // 3. What each mode needs.
        for selector in selected {
            switch selector.mode {
            case .rigCapture, .modelCapture, .sceneCapture:
                if !isSet(autocapture) { report([selector.variable], "writes its PNG to IKKOKU_AUTOCAPTURE, which is not set") }
            case .makerScenario:
                if !isSet("IKKOKU_MAKER_SCENARIO_REPORT") {
                    report([selector.variable], "writes its report to IKKOKU_MAKER_SCENARIO_REPORT, which is not set")
                }
            case .studioScenario:
                if !isSet("IKKOKU_STUDIO_SCENARIO_REPORT") {
                    report([selector.variable], "writes its report to IKKOKU_STUDIO_SCENARIO_REPORT, which is not set")
                }
            case .liveSourceShaderProbe:
                if !isSet("IKKOKU_LIVE_SOURCE_OUTPUT") {
                    report([selector.variable], "writes its renders to IKKOKU_LIVE_SOURCE_OUTPUT, which is not set")
                }
            case .gameplayScenario:
                if !isSet("IKKOKU_GAMEPLAY_SCENARIO_REPORT") {
                    report([selector.variable], "writes its report to IKKOKU_GAMEPLAY_SCENARIO_REPORT, which is not set")
                }
            default:
                break
            }
        }

        // 4. The window capture needs the editor window, which only an interactive
        // launch or an app capture that returns to it opens. The performance trace
        // keeps the window but drives it itself, so a snapshot would race it.
        let capturesWindow = isSet(windowCapture)
        let closing = selected.filter { $0.mode != .appCapture && $0.mode != .perfTrace }
        if capturesWindow, let trace = selected.first(where: { $0.mode == .perfTrace }) {
            report([windowCapture, trace.variable], "the performance trace drives the editor window for its whole run; "
                       + "capture the window in a separate launch")
        }
        if capturesWindow, !closing.isEmpty {
            let exiting = joinedList(closing.map { $0.mode.label }, "and")
            var variables: [String] = [windowCapture]
            variables += closing.map { $0.variable }
            report(variables, "the window capture needs the editor window, but \(exiting) exits before it opens; "
                       + "set IKKOKU_CAPTURE_UI alone or with an IKKOKU_AUTOCAPTURE app capture")
        }

        // 5. Capture options outside every mode that reads them.
        let current = selected.isEmpty ? "this launch requests no capture mode" : "this launch runs \(requested)"
        for option in scopedOptions where isSet(option.variable) && !settled.contains(option.variable)
            && option.modes.isDisjoint(with: modes) {
            let readers = joinedList(Mode.allCases.filter { option.modes.contains($0) }.map { $0.label }, "or")
            report([option.variable], "has no effect here: only \(readers) reads it, and \(current)")
        }
        if !capturesWindow {
            for variable in windowOptions where isSet(variable) && !settled.contains(variable) {
                report([variable], "has no effect here: only the window capture reads it, and IKKOKU_CAPTURE_UI is not set")
            }
        }

        // 6. Options that act only together with another option or value.
        for dependency in dependencies where isSet(dependency.variable) && !settled.contains(dependency.variable) {
            if let when = dependency.when, environment[dependency.variable] != when { continue }
            let present = environment[dependency.requires]
            let satisfied = dependency.value.map { present == $0 } ?? (present != nil)
            guard !satisfied else { continue }
            let needed = dependency.value.map { "\(dependency.requires)=\($0)" } ?? dependency.requires
            report([dependency.variable], "has no effect without \(needed)")
        }

        // 7. Combinations that would capture other content than requested.
        for conflict in conflicts where isSet(conflict.variable) && !conflict.modes.isDisjoint(with: modes) {
            let others = conflict.others.filter { isSet($0) }
            guard !others.isEmpty else { continue }
            var variables: [String] = [conflict.variable]
            variables += others
            report(variables, conflict.reason)
        }

        // 8. Values the mode would replace with its default or ignore.
        for rule in valueRules where !settled.contains(rule.variable) {
            guard let value = environment[rule.variable], let problem = rule.check.problem(value) else { continue }
            report([rule.variable], problem)
        }
        if single == .rigCapture, let preset = environment["IKKOKU_CAPTURE_PRESET"],
           !settled.contains("IKKOKU_CAPTURE_PRESET"), preset != "face" {
            report(["IKKOKU_CAPTURE_PRESET"], "source rig capture frames the whole rig and supports only 'face', got '\(preset)'")
        }
        if single == .sceneCapture {
            let overlays: [String] = ["IKKOKU_CAPTURE_GRID", "IKKOKU_CAPTURE_GIZMOS"]
            for variable in overlays where environment[variable] == "1" && !settled.contains(variable) {
                report([variable], "native scene capture always hides the grid and gizmos; only 0 is accepted")
            }
        }
        if capturesWindow, isSet(UICaptureReadiness.timeoutVariable), !settled.contains(UICaptureReadiness.timeoutVariable) {
            do { _ = try UICaptureReadiness.fromEnvironment(environment) }
            catch { report([UICaptureReadiness.timeoutVariable], String(describing: error)) }
        }

        guard problems.isEmpty else { throw CaptureRequestError(problems: problems) }
        return CaptureRequest(mode: selected.first?.mode ?? .interactive, capturesWindow: capturesWindow)
    }
}

/// Why a capture environment was rejected (A06): every problem found, each
/// naming the variables involved.
public struct CaptureRequestError: Error, Equatable, Sendable, CustomStringConvertible {
    public struct Problem: Equatable, Sendable, CustomStringConvertible {
        /// The variables involved, in a stable order.
        public let variables: [String]
        public let reason: String

        public init(variables: [String], reason: String) {
            self.variables = variables
            self.reason = reason
        }

        public var description: String { "\(variables.joined(separator: ", ")): \(reason)" }
    }

    /// In check order: empty and unknown names, modes, options, combinations, values.
    public let problems: [Problem]

    public init(problems: [Problem]) {
        self.problems = problems
    }

    /// Every variable named by a problem, sorted, without duplicates.
    public var variables: [String] { Set(problems.flatMap { $0.variables }).sorted() }

    public var description: String {
        let offending = variables.joined(separator: ", ")
        let lines = problems.map { "  - \($0)" }.joined(separator: "\n")
        return "invalid capture request; offending variables: \(offending)\n\(lines)"
    }
}

/// A capture input that could not be used (A06): the variable, its value (normally
/// a path) and why. An automated run prints it and exits 1 instead of capturing
/// other content than was requested.
public struct CaptureInputError: Error, Equatable, Sendable, CustomStringConvertible {
    public let variable: String
    public let value: String
    public let reason: String

    public init(variable: String, value: String, reason: String) {
        self.variable = variable
        self.value = value
        self.reason = reason
    }

    public var description: String { "\(variable)=\(value): \(reason)" }
}

// MARK: - Inventory

extension CaptureRequest {
    struct ModeSelector: Sendable {
        let variable: String
        let mode: Mode
        init(_ variable: String, _ mode: Mode) {
            self.variable = variable
            self.mode = mode
        }
    }

    struct ScopedOption: Sendable {
        let variable: String
        /// The modes that read it.
        let modes: Set<Mode>
        init(_ variable: String, _ modes: Set<Mode>) {
            self.variable = variable
            self.modes = modes
        }
    }

    struct Dependency: Sendable {
        let variable: String
        let requires: String
        /// The value `requires` must have; nil when being set is enough.
        let value: String?
        /// The dependency applies only when `variable` has this value; nil: whenever set.
        let when: String?
        init(_ variable: String, requires: String, value: String? = nil, when: String? = nil) {
            self.variable = variable
            self.requires = requires
            self.value = value
            self.when = when
        }
    }

    struct Conflict: Sendable {
        /// The modes in which the combination is checked.
        let modes: Set<Mode>
        let variable: String
        let others: [String]
        let reason: String
    }

    struct ValueRule: Sendable {
        let variable: String
        let check: ValueCheck
        init(_ variable: String, _ check: ValueCheck) {
            self.variable = variable
            self.check = check
        }
    }

    static let autocapture = "IKKOKU_AUTOCAPTURE"
    static let windowCapture = "IKKOKU_CAPTURE_UI"

    /// The variables that select a mode, in the order startup reaches them.
    static let modeSelectors: [ModeSelector] = [
        ModeSelector("IKKOKU_GAMEPLAY_SCENARIO", .gameplayScenario),
        ModeSelector("IKKOKU_ORIGINAL_FRAME_PROBE", .originalFrameProbe),
        ModeSelector("IKKOKU_LIVE_SOURCE_PROBE", .liveSourceShaderProbe),
        ModeSelector("IKKOKU_CAPTURE_RIG", .rigCapture),
        ModeSelector("IKKOKU_CAPTURE_MODEL", .modelCapture),
        ModeSelector("IKKOKU_CAPTURE_SCENE", .sceneCapture),
        ModeSelector("IKKOKU_MAKER_SCENARIO", .makerScenario),
        ModeSelector("IKKOKU_STUDIO_SCENARIO", .studioScenario),
        ModeSelector("IKKOKU_RENDER_THUMBS", .thumbnails),
        ModeSelector("IKKOKU_PERF_TRACE", .perfTrace),
    ]

    /// Capture options and the modes that read them; every other mode ignores them.
    static let scopedOptions: [ScopedOption] = [
        ScopedOption("IKKOKU_ORIGINAL_FRAME_FAMILIES", [.originalFrameProbe]),
        ScopedOption("IKKOKU_ORIGINAL_FRAME_FAMILY_SETS", [.originalFrameProbe]),
        ScopedOption("IKKOKU_ORIGINAL_FRAME_DEPTH24", [.originalFrameProbe]),
        ScopedOption("IKKOKU_ORIGINAL_FRAME_TRACE_PIXELS", [.originalFrameProbe]),
        ScopedOption("IKKOKU_MAKER_SCENARIO_REPORT", [.makerScenario]),
        ScopedOption("IKKOKU_STUDIO_SCENARIO_REPORT", [.studioScenario]),
        ScopedOption("IKKOKU_GAMEPLAY_SCENARIO_REPORT", [.gameplayScenario]),
        ScopedOption("IKKOKU_SOURCE_EXPRESSION", [.rigCapture, .liveSourceShaderProbe]),
        ScopedOption("IKKOKU_LIVE_SOURCE_OUTPUT", [.liveSourceShaderProbe]),
        ScopedOption("IKKOKU_LIVE_SOURCE_TEXTURE_PROVIDER", [.liveSourceShaderProbe]),
        ScopedOption("IKKOKU_STUDIO_HAND_POSE", [.liveSourceShaderProbe]),
        // The Studio app capture's live source-shader status (R1/CMT-04).
        ScopedOption("IKKOKU_LIVE_SOURCE_REPORT", [.appCapture]),
        ScopedOption("IKKOKU_SOURCE_HEIGHT", [.rigCapture]),
        ScopedOption("IKKOKU_CAPTURE_SHADOWS", [.rigCapture]),
        ScopedOption("IKKOKU_RIG_BONES", [.rigCapture]),
        ScopedOption("IKKOKU_CAPTURE_MIRROR", [.modelCapture]),
        ScopedOption("IKKOKU_CAPTURE_W", [.rigCapture, .modelCapture, .sceneCapture, .appCapture]),
        ScopedOption("IKKOKU_CAPTURE_H", [.rigCapture, .modelCapture, .sceneCapture, .appCapture]),
        ScopedOption("IKKOKU_CAPTURE_YAW", [.rigCapture, .modelCapture, .appCapture]),
        ScopedOption("IKKOKU_CAPTURE_PRESET", [.rigCapture, .appCapture]),
        ScopedOption("IKKOKU_SOURCE_BODY", [.rigCapture, .appCapture]),
        ScopedOption("IKKOKU_SOURCE_FACE", [.rigCapture, .appCapture]),
        ScopedOption("IKKOKU_SAVE_SCENE", [.sceneCapture, .appCapture]),
        // Native scene capture always hides both; it accepts only 0 (step 8).
        ScopedOption("IKKOKU_CAPTURE_GRID", [.sceneCapture, .appCapture]),
        ScopedOption("IKKOKU_CAPTURE_GIZMOS", [.sceneCapture, .appCapture]),
        // Capture-only focus evidence for mounted adapters (A-T04, A06): the
        // report is a required output, so it needs a run that exits.
        ScopedOption("IKKOKU_NATIVE_PLUGIN_REPORT", [.sceneCapture, .appCapture]),
        ScopedOption("IKKOKU_APPLICATION_FOCUS", [.sceneCapture, .appCapture]),
        ScopedOption("IKKOKU_CARD", [.appCapture]),
        ScopedOption("IKKOKU_CAPTURE_SEX", [.appCapture]),
        ScopedOption("IKKOKU_SOURCE_COORDINATE", [.appCapture]),
        ScopedOption("IKKOKU_SOURCE_COLOR_EDITS", [.appCapture]),
        ScopedOption("IKKOKU_CAPTURE_SLIDERS", [.appCapture]),
        ScopedOption("IKKOKU_CAPTURE_EXPR", [.appCapture]),
        ScopedOption("IKKOKU_CAPTURE_OUTFIT", [.appCapture]),
        ScopedOption("IKKOKU_CAPTURE_HAIR", [.appCapture]),
        ScopedOption("IKKOKU_SOURCE_PLAYBACK_SECONDS", [.appCapture]),
        ScopedOption("IKKOKU_CAPTURE_TICKS", [.appCapture]),
        ScopedOption("IKKOKU_CAPTURE_STUDIO", [.appCapture]),
        ScopedOption("IKKOKU_CAPTURE_POSE", [.appCapture]),
        ScopedOption("IKKOKU_CAPTURE_ITEMS", [.appCapture]),
        ScopedOption("IKKOKU_CAPTURE_TIMELINE", [.appCapture]),
        ScopedOption("IKKOKU_EXPORT_SOURCE_CARD", [.appCapture]),
        ScopedOption("IKKOKU_SAVE_CARD", [.appCapture]),
        ScopedOption("IKKOKU_LOAD_SCENE", [.appCapture]),
        ScopedOption("IKKOKU_EXPORT_SOURCE_SCENE", [.appCapture]),
        ScopedOption("IKKOKU_SOURCE_SCENE_EDITS", [.appCapture]),
        ScopedOption("IKKOKU_BENCHMARK_OUTPUT", [.appCapture]),
        ScopedOption("IKKOKU_BENCHMARK_FRAMES", [.appCapture]),
        ScopedOption("IKKOKU_BENCHMARK_SIMULATION_FRAMES", [.appCapture]),
        ScopedOption("IKKOKU_PERF_WORKLOAD", [.perfTrace]),
        ScopedOption("IKKOKU_PERF_SECONDS", [.perfTrace]),
        ScopedOption("IKKOKU_PERF_WARMUP_SECONDS", [.perfTrace]),
        ScopedOption("IKKOKU_PERF_WINDOW_W", [.perfTrace]),
        ScopedOption("IKKOKU_PERF_WINDOW_H", [.perfTrace]),
        ScopedOption("IKKOKU_PERF_INPUT_HZ", [.perfTrace]),
        ScopedOption("IKKOKU_PERF_CHARACTERS", [.perfTrace]),
    ]

    /// Options read only by the window capture.
    static let windowOptions: [String] = [
        "IKKOKU_CAPTURE_UI_TAB", "IKKOKU_CAPTURE_UI_MODE", "IKKOKU_CAPTURE_UI_STUDIO_TAB",
        "IKKOKU_CAPTURE_UI_REPORT", UICaptureReadiness.timeoutVariable,
    ]

    /// Inputs startup loads in any mode that builds the Maker and Studio, including
    /// an interactive launch; rig capture also reads `IKKOKU_SOURCE_CARD`,
    /// `IKKOKU_BONE_MODIFIERS` and `IKKOKU_MOD_LIBRARY`, and native scene capture
    /// the Studio execution inputs.
    static let startupInputs: [String] = [
        "IKKOKU_SOURCE_SCENE", "IKKOKU_MOD_LIBRARY", "IKKOKU_OPEN_RIG", "IKKOKU_BONE_MODIFIERS",
        "IKKOKU_SOURCE_CARD", "IKKOKU_STUDIO_ANIMATION_TIME", "IKKOKU_SOURCE_PLUGIN_PROFILE",
        "IKKOKU_NATIVE_PLUGIN_MANIFEST", "IKKOKU_NATIVE_PLUGIN_MANIFESTS", "IKKOKU_MUTE_BACKGROUND_CONFIG",
        "IKKOKU_SOURCE_PLUGIN_STEPS", "IKKOKU_SOURCE_PLUGIN_DELTA",
        // The Studio's live source-shader opt-in at launch (View ▸ Live Source Shaders).
        "IKKOKU_LIVE_SOURCE_SHADERS",
    ]

    /// Where original or converted data and settings come from; consulted wherever
    /// they apply, in any mode.
    static let dataSources: [String] = [
        "IKKOKU_ASSETS", "IKKOKU_SOURCE_AVATAR", "IKKOKU_SOURCE_MALE_AVATAR", "IKKOKU_MAKER_LIBRARY",
        "IKKOKU_SHAPE_CONTRACT", "IKKOKU_MOD_PROFILE", "IKKOKU_MOD_CATALOG_CONTRACT", "IKKOKU_SOURCE_ANIMATION",
        "IKKOKU_STUDIO_ANIMATION_CATALOG", "IKKOKU_STUDIO_ATTACHMENT_CATALOG", "IKKOKU_STUDIO_ITEM_CATALOG",
        "IKKOKU_STUDIO_DYNAMICS", "IKKOKU_STUDIO_HAND_PATTERNS", "IKKOKU_STUDIO_LOOK_SETTINGS",
        "IKKOKU_STUDIO_VOICE_CATALOG",
        // Live source-shader inputs (`SourceShaderLiveConfiguration`).
        "IKKOKU_LIVE_SOURCE_PROGRAMS", "IKKOKU_LIVE_SOURCE_TEXTURES", "IKKOKU_LIVE_SOURCE_STREAMS",
        "IKKOKU_SHADER_BINDING_SUPPLEMENT", "IKKOKU_HEAD_MATERIAL_CONTRACT",
        // `0` turns off the build checkout's development defaults (EngineHost, T-T02).
        "IKKOKU_SOURCE_TREE_FALLBACKS",
    ]

    /// Name prefixes used only by capture variables: an unknown name with one of
    /// these is a misspelling, not some other tool's fixture.
    static let capturePrefixes: [String] = ["IKKOKU_CAPTURE_", "IKKOKU_ORIGINAL_FRAME_", "IKKOKU_BENCHMARK_", "IKKOKU_LIVE_SOURCE_", "IKKOKU_PERF_"]

    static let dependencies: [Dependency] = [
        Dependency("IKKOKU_CAPTURE_POSE", requires: "IKKOKU_CAPTURE_STUDIO"),
        Dependency("IKKOKU_CAPTURE_ITEMS", requires: "IKKOKU_CAPTURE_STUDIO"),
        Dependency("IKKOKU_CAPTURE_TIMELINE", requires: "IKKOKU_CAPTURE_STUDIO"),
        Dependency("IKKOKU_SOURCE_SCENE_EDITS", requires: "IKKOKU_SOURCE_SCENE"),
        Dependency("IKKOKU_BENCHMARK_FRAMES", requires: "IKKOKU_BENCHMARK_OUTPUT"),
        Dependency("IKKOKU_BENCHMARK_SIMULATION_FRAMES", requires: "IKKOKU_BENCHMARK_OUTPUT"),
        Dependency("IKKOKU_BENCHMARK_SIMULATION_FRAMES", requires: "IKKOKU_SOURCE_SCENE"),
        Dependency("IKKOKU_SOURCE_PLUGIN_DELTA", requires: "IKKOKU_SOURCE_PLUGIN_STEPS"),
        Dependency("IKKOKU_CAPTURE_UI_STUDIO_TAB", requires: "IKKOKU_CAPTURE_UI_MODE", value: "studio"),
        Dependency("IKKOKU_ORIGINAL_FRAME_FAMILY_SETS", requires: "IKKOKU_ORIGINAL_FRAME_FAMILIES", value: "1"),
        Dependency("IKKOKU_ORIGINAL_FRAME_TRACE_PIXELS", requires: "IKKOKU_ORIGINAL_FRAME_FAMILIES", value: "1"),
        Dependency("IKKOKU_ORIGINAL_FRAME_DEPTH24", requires: "IKKOKU_ORIGINAL_FRAME_FAMILIES", value: "1", when: "1"),
    ]

    static let conflicts: [Conflict] = [
        // `MakerModel.load(card:)` clears the imported source card and rig preview.
        Conflict(modes: [.appCapture], variable: "IKKOKU_CARD",
                 others: ["IKKOKU_SOURCE_CARD", "IKKOKU_OPEN_RIG", "IKKOKU_BONE_MODIFIERS", "IKKOKU_SOURCE_BODY",
                          "IKKOKU_SOURCE_FACE", "IKKOKU_SOURCE_COORDINATE", "IKKOKU_SOURCE_COLOR_EDITS",
                          "IKKOKU_SOURCE_PLAYBACK_SECONDS", "IKKOKU_EXPORT_SOURCE_CARD"],
                 reason: "IKKOKU_CARD loads a native card, which discards the source preview the other variables load or edit"),
        // `IKKOKU_CAPTURE_SEX=m` starts a new bundled character unless a source card
        // was imported, so it either replaces the loaded character or is ignored.
        Conflict(modes: [.appCapture], variable: "IKKOKU_CAPTURE_SEX",
                 others: ["IKKOKU_CARD", "IKKOKU_SOURCE_CARD", "IKKOKU_OPEN_RIG", "IKKOKU_BONE_MODIFIERS"],
                 reason: "IKKOKU_CAPTURE_SEX starts a bundled character, which would discard the character the other variables load, or be ignored for an imported source card"),
        Conflict(modes: [.rigCapture], variable: "IKKOKU_SOURCE_CARD",
                 others: ["IKKOKU_SOURCE_BODY", "IKKOKU_SOURCE_FACE", "IKKOKU_SOURCE_HEIGHT", "IKKOKU_BONE_MODIFIERS"],
                 reason: "rig capture takes shape and bone-modifier settings from IKKOKU_SOURCE_CARD, so separate overrides cannot also apply"),
    ]

    static let valueRules: [ValueRule] = [
        ValueRule("IKKOKU_CAPTURE_W", .integer(1...8192)),
        ValueRule("IKKOKU_CAPTURE_H", .integer(1...8192)),
        ValueRule("IKKOKU_CAPTURE_YAW", .finiteNumber),
        ValueRule("IKKOKU_CAPTURE_PRESET", .oneOfIgnoringCase(["face", "upper", "full"])),
        ValueRule("IKKOKU_CAPTURE_SHADOWS", .oneOf(["0", "1"])),
        ValueRule("IKKOKU_RIG_BONES", .oneOf(["0", "1"])),
        ValueRule("IKKOKU_CAPTURE_MIRROR", .oneOf(["0", "1"])),
        ValueRule("IKKOKU_CAPTURE_GRID", .oneOf(["0", "1"])),
        ValueRule("IKKOKU_CAPTURE_GIZMOS", .oneOf(["0", "1"])),
        ValueRule("IKKOKU_ORIGINAL_FRAME_FAMILIES", .oneOf(["0", "1"])),
        ValueRule("IKKOKU_ORIGINAL_FRAME_DEPTH24", .oneOf(["0", "1"])),
        ValueRule("IKKOKU_LIVE_SOURCE_SHADERS", .oneOf(["0", "1"])),
        ValueRule("IKKOKU_LIVE_SOURCE_TEXTURE_PROVIDER", .oneOf(["store", "capture"])),
        ValueRule("IKKOKU_CAPTURE_SEX", .oneOf(["m", "f"])),
        ValueRule("IKKOKU_CAPTURE_UI_MODE", .oneOf(["maker", "studio"])),
        ValueRule("IKKOKU_CAPTURE_TICKS", .integer(0...Int.max)),
        ValueRule("IKKOKU_CAPTURE_OUTFIT", .integer(0...Int.max)),
        ValueRule("IKKOKU_SOURCE_COORDINATE", .integer(0...Int.max)),
        ValueRule("IKKOKU_CAPTURE_TIMELINE", .finiteNumber),
        // The renderer and Studio benchmarks check their own frame ranges.
        ValueRule("IKKOKU_BENCHMARK_FRAMES", .integer(1...Int.max)),
        ValueRule("IKKOKU_BENCHMARK_SIMULATION_FRAMES", .integer(1...Int.max)),
        ValueRule("IKKOKU_CAPTURE_EXPR", .pairs(keys: ["eyes", "mouth", "brows", "head", "gaze"], integerValues: true)),
        ValueRule("IKKOKU_CAPTURE_SLIDERS", .pairs(keys: nil, integerValues: false)),
        ValueRule("IKKOKU_APPLICATION_FOCUS", .focusEvents),
        ValueRule("IKKOKU_PERF_WORKLOAD", .oneOf(perfWorkloads)),
        ValueRule("IKKOKU_PERF_SECONDS", .integer(1...600)),
        ValueRule("IKKOKU_PERF_WARMUP_SECONDS", .integer(0...120)),
        ValueRule("IKKOKU_PERF_WINDOW_W", .integer(640...8192)),
        ValueRule("IKKOKU_PERF_WINDOW_H", .integer(480...8192)),
        ValueRule("IKKOKU_PERF_INPUT_HZ", .integer(1...1000)),
        ValueRule("IKKOKU_PERF_CHARACTERS", .integer(1...32)),
    ]

    /// `IKKOKU_PERF_WORKLOAD` values, in the order `docs/reference/performance.md` lists them.
    public static let perfWorkloads: [String] = [
        "studio-idle", "studio-orbit", "studio-fk-drag", "studio-hover", "maker-slider", "maker-idle",
        "studio-native", "startup",
    ]
}

/// The value syntax a capture option accepts.
enum ValueCheck: Sendable {
    case oneOf([String])
    case oneOfIgnoringCase([String])
    case integer(ClosedRange<Int>)
    case finiteNumber
    /// Comma-separated `key=value` pairs; `keys` lists the accepted keys, or nil for any.
    case pairs(keys: [String]?, integerValues: Bool)
    /// `IKKOKU_APPLICATION_FOCUS`: at most 64 comma-separated 0 (loss) or 1 (gain).
    case focusEvents

    /// Why `value` is not accepted, or nil when it is.
    func problem(_ value: String) -> String? {
        switch self {
        case .oneOf(let allowed):
            if allowed.contains(value) { return nil }
            return "must be \(quotedList(allowed)), got '\(value)'"
        case .oneOfIgnoringCase(let allowed):
            if allowed.contains(value.lowercased()) { return nil }
            return "must be \(quotedList(allowed)), got '\(value)'"
        case .integer(let range):
            if let number = Int(value), range.contains(number) { return nil }
            let bounds = range.upperBound == Int.max
                ? "an integer of at least \(range.lowerBound)"
                : "an integer from \(range.lowerBound) to \(range.upperBound)"
            return "must be \(bounds), got '\(value)'"
        case .finiteNumber:
            if let number = Float(value), number.isFinite { return nil }
            return "must be a finite number, got '\(value)'"
        case .pairs(let keys, let integerValues):
            for piece in value.split(separator: ",", omittingEmptySubsequences: false) {
                let parts = piece.split(separator: "=", omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else {
                    return "must be comma-separated key=value pairs; '\(piece)' is not one"
                }
                let key = String(parts[0])
                if let keys, !keys.contains(key) {
                    return "has unknown key '\(key)'; the keys are \(joinedList(keys, "and"))"
                }
                let valid = integerValues ? Int(parts[1]) != nil : (Float(parts[1])?.isFinite ?? false)
                if !valid {
                    let kind = integerValues ? "an integer" : "a finite number"
                    return "'\(piece)' needs \(kind) after '='"
                }
            }
            return nil
        case .focusEvents:
            let events = value.split(separator: ",", omittingEmptySubsequences: false)
            if events.count <= 64, events.allSatisfy({ $0 == "0" || $0 == "1" }) { return nil }
            return "must list at most 64 comma-separated focus events, each 0 (loss) or 1 (gain), got '\(value)'"
        }
    }
}

/// "a", "a and b", "a, b and c".
private func joinedList(_ items: [String], _ conjunction: String) -> String {
    guard let last = items.last, items.count > 1 else { return items.first ?? "" }
    return "\(items.dropLast().joined(separator: ", ")) \(conjunction) \(last)"
}

/// "'a' or 'b'".
private func quotedList(_ items: [String]) -> String {
    joinedList(items.map { "'\($0)'" }, "or")
}
