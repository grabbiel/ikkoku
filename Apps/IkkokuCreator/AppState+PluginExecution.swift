import Foundation
import AppKit
import Observation
import Studio
import Gameplay
import Renderer

extension AppState {
    /// The variables `configureStudioExecution` reads, in its order.
    static let studioExecutionInputs = ["IKKOKU_STUDIO_ANIMATION_TIME", "IKKOKU_STUDIO_PLUGIN_SELECTION", "IKKOKU_SOURCE_PLUGIN_PROFILE",
        "IKKOKU_NATIVE_PLUGIN_MANIFEST", "IKKOKU_NATIVE_PLUGIN_MANIFESTS", "IKKOKU_MUTE_BACKGROUND_CONFIG", "IKKOKU_SOURCE_PLUGIN_STEPS",
        "IKKOKU_APPLICATION_FOCUS", "IKKOKU_NATIVE_PLUGIN_REPORT"]

    /// Startup's Studio execution inputs (#459): run by `LaunchInputGate` at once after a synchronous
    /// launch import, or from the end of a background one (`deferred`, interactive and performance-trace
    /// launches). A failure exits 1 in an automated run and otherwise shows the alert naming the input.
    /// Only the deferred path prints its outcome and records it in a performance trace
    /// (`details.launchStudioExecution`), so the synchronous paths' output is unchanged.
    func applyStudioExecution(_ studio: StudioModel, automated: Bool, deferred: Bool) {
        do { try AppState.configureStudioExecution(studio) }
        catch {
            if automated { print("[ikkoku] studio execution failed: \(error)"); exit(1) }
            if deferred { print("[ikkoku] studio execution failed: \(error)") }
            errorMessage = "Studio execution: \(error)"
            return
        }
        let env = ProcessInfo.processInfo.environment
        let inputs = Self.studioExecutionInputs.filter { env[$0] != nil }
        guard deferred, !inputs.isEmpty else { return }
        let packages = studio.sourcePluginSession?.library.packages.count ?? 0
        let native = studio.doc.sourceNativePlugins?.count ?? 0
        let built = studio.sourcePreviewCharacterOutcome().built
        print("[ikkoku] launch studio inputs applied after the background scene import: \(inputs.joined(separator: ", ")); "
              + "\(packages) plugin packages, \(native) native plugins, running \(studio.sourcePluginsRunning); \(built) characters built")
        if let trace = PerfTrace.active {
            trace.details["launchStudioExecution"] = ["appliedAfterImport": true, "inputs": inputs, "sourcePluginPackages": packages,
                "nativePlugins": native, "sourcePluginsRunning": studio.sourcePluginsRunning, "charactersBuilt": built] as [String: Any]
        }
    }

    /// While the launch inputs wait (#459), New Scene, Open or another import cancels the launch import, whose end
    /// then never comes: the inputs are dropped with one line saying so. What such a command changes is the import's
    /// progress (`sourceBuildProgress`, labelled with the scene while it imports); the check runs on a later
    /// main-actor turn, so a commit has opened the gate by then. A replacement import of the same file keeps the
    /// label, and the drop is reported when that import ends.
    func watchLaunchImport(_ studio: StudioModel, gate: LaunchInputGate) {
        guard gate.isHolding, let importing = studio.sourceBuildProgress?.label else { return }
        withObservationTracking { _ = studio.sourceBuildProgress } onChange: {
            Task { @MainActor in
                guard gate.isHolding else { return }
                if studio.sourceBuildProgress?.label == importing { self.watchLaunchImport(studio, gate: gate); return }
                let env = ProcessInfo.processInfo.environment
                let inputs = Self.studioExecutionInputs.filter { env[$0] != nil }
                if gate.drop(), !inputs.isEmpty {
                    print("[ikkoku] launch studio inputs dropped: the launch scene import (\(importing)) was cancelled before it committed "
                          + "(New Scene, Open or another import); not applied: \(inputs.joined(separator: ", "))")
                }
            }
        }
    }

    /// Applies the Studio execution inputs. A failed input throws a `CaptureInputError`
    /// naming its variable and value (A06); startup exits 1 on it in an automated run
    /// and shows it as an alert otherwise.
    static func configureStudioExecution(_ studio: StudioModel) throws {
        let env = ProcessInfo.processInfo.environment
        try applyStudioInput("IKKOKU_STUDIO_ANIMATION_TIME", env) { value in
            guard let seconds = Float(value) else { throw SourcePluginError.invalid("Invalid source animation capture time.") }
            studio.liveAnimation = false
            try studio.setSourceAnimationTime(seconds)
        }
        try applyStudioInput("IKKOKU_STUDIO_PLUGIN_SELECTION", env) { path in
            guard env["IKKOKU_SOURCE_PLUGIN_PROFILE"] == nil, env["IKKOKU_NATIVE_PLUGIN_MANIFEST"] == nil,
                  env["IKKOKU_NATIVE_PLUGIN_MANIFESTS"] == nil else {
                throw SourcePluginError.invalid("A plugin library selection cannot be combined with separate profiles or adapter manifests.")
            }
            let request = try StudioPluginLibraryRequest.load(url: URL(fileURLWithPath: path))
            let prepared = try studio.prepareSourcePluginLibrary(selection: request.selection, resolution: request.selection.resolve(),
                configuration: request.configuration, document: studio.doc)
            studio.commitSourcePlugins(prepared, running: true)
        }
        try applyStudioInput("IKKOKU_SOURCE_PLUGIN_PROFILE", env) { path in
            try studio.loadSourcePlugins(profileURL: URL(fileURLWithPath: path))
        }
        try applyStudioInput("IKKOKU_NATIVE_PLUGIN_MANIFEST", env) { path in
            try studio.loadSourceNativePlugin(url: URL(fileURLWithPath: path))
        }
        try applyStudioInput("IKKOKU_NATIVE_PLUGIN_MANIFESTS", env) { json in
            let paths = try JSONDecoder().decode([String].self, from: Data(json.utf8))
            guard paths.count <= 32 else { throw SourcePluginError.invalid("Excessive native plugin capture mounts.") }
            for path in paths { try studio.loadSourceNativePlugin(url: URL(fileURLWithPath: path)) }
        }
        try applyStudioInput("IKKOKU_MUTE_BACKGROUND_CONFIG", env) { path in
            try studio.configureSourceMutePlugin(configURL: URL(fileURLWithPath: path))
        }
        try applyStudioInput("IKKOKU_SOURCE_PLUGIN_STEPS", env) { value in
            guard let steps = Int(value), (0...10_000).contains(steps),
                  let delta = Float(env["IKKOKU_SOURCE_PLUGIN_DELTA"] ?? "0.0333333333"), delta.isFinite, delta >= 0 else {
                throw SourcePluginError.invalid("Invalid deterministic plugin capture steps.")
            }
            for _ in 0..<steps { try studio.stepSourcePlugins(deltaTime: delta, advanceAnimation: studio.liveAnimation) }
            studio.sourcePluginsRunning = false; studio.liveAnimation = false
        }
        try captureSourceFocus(studio, env: env)
    }

    /// Runs `apply` with the value of `variable` when it is set, rethrowing a failure as a
    /// `CaptureInputError` that names the variable and its value.
    private static func applyStudioInput(_ variable: String, _ env: [String: String],
                                         _ apply: (String) throws -> Void) throws {
        guard let value = env[variable] else { return }
        do { try apply(value) }
        catch { throw CaptureInputError(variable: variable, value: value, reason: String(describing: error)) }
    }

    /// `IKKOKU_APPLICATION_FOCUS=0,1` calls the same focus consumer as the AppKit
    /// observers directly; it does not post notifications or prove registration.
    /// `IKKOKU_NATIVE_PLUGIN_REPORT` records mounts, observers
    /// and generated-tone gain after each event. Headless captures exit before
    /// launching finishes, so they also record the deferred initial-focus state.
    /// `launchFinished` lets the probe reject a sample taken before then (A-T04).
    private static func captureSourceFocus(_ studio: StudioModel, env: [String: String]) throws {
        let events: [Bool] = try env["IKKOKU_APPLICATION_FOCUS"].map { value in
            try value.split(separator: ",", omittingEmptySubsequences: false).map { text -> Bool in
                guard text == "0" || text == "1" else { throw SourcePluginError.invalid("Application focus events must be comma-separated 0 or 1.") }
                return text == "1"
            }
        } ?? []
        guard events.count <= 64, events.isEmpty || studio.sourceFocus.adapter != nil else {
            throw SourcePluginError.invalid("Application focus events require a mounted Mute adapter and at most 64 events.")
        }
        guard let path = env["IKKOKU_NATIVE_PLUGIN_REPORT"] else {
            for focused in events { studio.receiveSourceApplicationFocus(focused) }
            return
        }
        func sample(_ focus: Bool?) throws -> [String: Any] {
            let rms = try studio.measureGeneratedToneRMS()
            var row: [String: Any] = ["masterVolume": studio.sourceAudioBus.masterVolume, "voiceVolume": studio.sourceAudioBus.voiceVolume, "toneRMS": rms]
            if let focus { row["focus"] = focus }
            if let original = studio.sourceFocus.adapter?.originalVolume { row["originalVolume"] = original }
            return row
        }
        let mount = studio.sourceFocusState(), initial = try sample(nil)
        var trace = [initial]
        for focused in events { studio.receiveSourceApplicationFocus(focused); trace.append(try sample(focused)) }
        let references = try (studio.doc.sourceNativePlugins ?? []).map { reference -> Any in
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference))
        }
        let report: [String: Any] = ["schemaVersion": 1, "applicationCreated": NSApp != nil,
            "launchFinished": NSRunningApplication.current.isFinishedLaunching, "nativePlugins": references,
            "accessoryNamesEnabled": studio.sourceAccessoryNamesEnabled, "sourceAnimationTime": studio.sourceAnimationTime, "mount": mount, "focusTrace": trace, "final": studio.sourceFocusState()]
        try CaptureOutput.writeJSON(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                                    to: URL(fileURLWithPath: path))
        print("[ikkoku] native plugin report written to \(path)")
    }
}

/// The same selection/configuration values the inspector passes to the model.
/// Capture input only; native scenes store both directly and need no request file.
struct StudioPluginLibraryRequest: Codable, Sendable {
    let selection: SourcePluginLibrarySelection
    let configuration: SourceStudioPluginConfiguration
    static func load(url: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw SourcePluginError.invalid("Plugin selection request exceeds 1 MiB.") }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
