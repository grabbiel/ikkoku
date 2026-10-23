import Foundation
import Testing
import Renderer

// A06: one startup check classifies the capture environment before any work and
// rejects conflicting modes, options that no requested mode reads, combinations
// that would capture other content, and values a mode would ignore.

/// The `CaptureRequestError` that `validate` throws for `environment`, or nil when it validates.
private func captureRequestFailure(_ environment: [String: String]) -> CaptureRequestError? {
    do { _ = try CaptureRequest.validate(environment) } catch let error as CaptureRequestError { return error } catch { return nil }
    return nil
}

/// The variables of each reported problem, in report order; empty when the environment validates.
private func captureRequestProblems(_ environment: [String: String]) -> [[String]] {
    captureRequestFailure(environment)?.problems.map { $0.variables } ?? []
}

/// The printed message for `environment`; empty when it validates.
private func captureRequestMessage(_ environment: [String: String]) -> String {
    captureRequestFailure(environment).map { String(describing: $0) } ?? ""
}

private struct CaptureRecipe {
    let source: String
    let environment: [String: String]
    let mode: CaptureRequest.Mode
    var capturesWindow = false
}

/// Every documented recipe and verification-lane launch must keep validating.
/// Paths are placeholders: the check never reads the files.
@Test func captureRequestAcceptsTheDocumentedRecipes() {
    let png = "/captures/out.png"
    let probeBase: [String: String] = [
        "IKKOKU_SOURCE_AVATAR": "/rigs/source-avatar.json", "IKKOKU_STUDIO_ANIMATION_CATALOG": "/animation/catalog.json",
        "IKKOKU_CAPTURE_W": "600", "IKKOKU_CAPTURE_H": "800", "IKKOKU_CAPTURE_GRID": "0", "IKKOKU_CAPTURE_GIZMOS": "0",
        "IKKOKU_AUTOCAPTURE": png, "IKKOKU_NATIVE_PLUGIN_REPORT": "/captures/adapters.json",
        "IKKOKU_APPLICATION_FOCUS": "0,1", "IKKOKU_MUTE_BACKGROUND_CONFIG": "/plugins/mute.cfg",
    ]
    var probeRun = probeBase
    probeRun["IKKOKU_SOURCE_SCENE"] = "/scenes/controlled.png"
    probeRun["IKKOKU_STUDIO_ANIMATION_TIME"] = "0.5"
    probeRun["IKKOKU_SOURCE_PLUGIN_PROFILE"] = "/captures/profile.json"
    probeRun["IKKOKU_SOURCE_PLUGIN_STEPS"] = "30"
    probeRun["IKKOKU_SAVE_SCENE"] = "/captures/native.png"
    probeRun["IKKOKU_BENCHMARK_OUTPUT"] = "/captures/benchmark.json"
    probeRun["IKKOKU_BENCHMARK_SIMULATION_FRAMES"] = "30"
    probeRun["IKKOKU_NATIVE_PLUGIN_MANIFESTS"] = "[\"/plugins/mute.json\",\"/plugins/names.json\"]"
    var probeReload = probeBase
    probeReload["IKKOKU_CAPTURE_SCENE"] = "/captures/native.png"
    var probeContinue = probeReload
    probeContinue["IKKOKU_SOURCE_PLUGIN_STEPS"] = "30"
    probeContinue["IKKOKU_SAVE_SCENE"] = "/captures/continued-native.png"

    let recipes: [CaptureRecipe] = [
        CaptureRecipe(source: "plain launch", environment: [:], mode: .interactive),
        CaptureRecipe(source: "cards.md GUI imports",
                      environment: ["IKKOKU_OPEN_RIG": "/rigs/neutral-rig.json", "IKKOKU_SOURCE_CARD": "/cards/card.png"],
                      mode: .interactive),
        CaptureRecipe(source: "build guide model capture",
                      environment: ["IKKOKU_CAPTURE_MODEL": "/models/chair.gltf", "IKKOKU_AUTOCAPTURE": png], mode: .modelCapture),
        CaptureRecipe(source: "build guide scene capture",
                      environment: ["IKKOKU_CAPTURE_SCENE": "/scenes/native.png", "IKKOKU_AUTOCAPTURE": png], mode: .sceneCapture),
        CaptureRecipe(source: "build guide Studio UI capture",
                      environment: ["IKKOKU_CAPTURE_UI": png, "IKKOKU_CAPTURE_UI_MODE": "studio"],
                      mode: .interactive, capturesWindow: true),
        CaptureRecipe(source: "A-T05 forced timeout",
                      environment: ["IKKOKU_CAPTURE_UI": png, "IKKOKU_CAPTURE_UI_TIMEOUT": "0.05"],
                      mode: .interactive, capturesWindow: true),
        CaptureRecipe(source: "A-T05 UI report",
                      environment: ["IKKOKU_CAPTURE_UI": png, "IKKOKU_CAPTURE_UI_REPORT": "/captures/ui.json"],
                      mode: .interactive, capturesWindow: true),
        CaptureRecipe(source: "A-T05 thumbnails", environment: ["IKKOKU_RENDER_THUMBS": "/captures/thumbs"], mode: .thumbnails),
        CaptureRecipe(source: "reverse README mirrored model",
                      environment: ["IKKOKU_CAPTURE_MODEL": "/models/chair.gltf", "IKKOKU_AUTOCAPTURE": png,
                                    "IKKOKU_CAPTURE_MIRROR": "1", "IKKOKU_CAPTURE_W": "640", "IKKOKU_CAPTURE_H": "480",
                                    "IKKOKU_CAPTURE_YAW": "45"],
                      mode: .modelCapture),
        CaptureRecipe(source: "reverse README height probe",
                      environment: ["IKKOKU_CAPTURE_RIG": "/rigs/neutral-rig.json", "IKKOKU_SHAPE_CONTRACT": "/rigs/contract.json",
                                    "IKKOKU_SOURCE_HEIGHT": "0.5", "IKKOKU_RIG_BONES": "1", "IKKOKU_AUTOCAPTURE": png],
                      mode: .rigCapture),
        CaptureRecipe(source: "reverse README clothed avatar",
                      environment: ["IKKOKU_CAPTURE_RIG": "/rigs/source-avatar.json", "IKKOKU_SOURCE_BODY": "defaults",
                                    "IKKOKU_SOURCE_FACE": "defaults", "IKKOKU_CAPTURE_PRESET": "face",
                                    "IKKOKU_CAPTURE_SHADOWS": "0", "IKKOKU_AUTOCAPTURE": png],
                      mode: .rigCapture),
        CaptureRecipe(source: "reverse README synthetic source scene",
                      environment: ["IKKOKU_SOURCE_SCENE": "/scenes/synthetic-current.png", "IKKOKU_AUTOCAPTURE": png],
                      mode: .appCapture),
        CaptureRecipe(source: "cards.md source-card face capture",
                      environment: ["IKKOKU_CAPTURE_RIG": "/rigs/source-avatar.json", "IKKOKU_SOURCE_CARD": "/cards/card.png",
                                    "IKKOKU_SOURCE_EXPRESSION": "defaults", "IKKOKU_CAPTURE_PRESET": "face",
                                    "IKKOKU_CAPTURE_W": "900", "IKKOKU_CAPTURE_H": "900", "IKKOKU_AUTOCAPTURE": png],
                      mode: .rigCapture),
        CaptureRecipe(source: "card-appearance.md edit and export",
                      environment: ["IKKOKU_SOURCE_CARD": "/cards/card.png", "IKKOKU_SOURCE_COORDINATE": "0",
                                    "IKKOKU_SOURCE_COLOR_EDITS": "/cards/color-edits.json",
                                    "IKKOKU_EXPORT_SOURCE_CARD": "/cards/edited.png", "IKKOKU_AUTOCAPTURE": png],
                      mode: .appCapture),
        CaptureRecipe(source: "dynamics.md one-second playback",
                      environment: ["IKKOKU_SOURCE_PLAYBACK_SECONDS": "1", "IKKOKU_CAPTURE_PRESET": "full",
                                    "IKKOKU_AUTOCAPTURE": png],
                      mode: .appCapture),
        CaptureRecipe(source: "renderer.md family sets",
                      environment: ["IKKOKU_ORIGINAL_FRAME_PROBE": "/probe/frame.json", "IKKOKU_ORIGINAL_FRAME_FAMILIES": "1",
                                    "IKKOKU_ORIGINAL_FRAME_FAMILY_SETS": "main_hair,main_hair_front"],
                      mode: .originalFrameProbe),
        CaptureRecipe(source: "renderer.md depth24 and draw trace",
                      environment: ["IKKOKU_ORIGINAL_FRAME_PROBE": "/probe/frame.json", "IKKOKU_ORIGINAL_FRAME_FAMILIES": "1",
                                    "IKKOKU_ORIGINAL_FRAME_DEPTH24": "1", "IKKOKU_ORIGINAL_FRAME_TRACE_PIXELS": "393,96;363,98"],
                      mode: .originalFrameProbe),
        CaptureRecipe(source: "plugin-execution.md deterministic frames",
                      environment: ["IKKOKU_SOURCE_PLUGIN_PROFILE": "/plugins/profile.json", "IKKOKU_SOURCE_PLUGIN_STEPS": "30",
                                    "IKKOKU_SOURCE_PLUGIN_DELTA": "0.0333333333", "IKKOKU_STUDIO_ANIMATION_TIME": "0.5",
                                    "IKKOKU_CAPTURE_GRID": "0", "IKKOKU_CAPTURE_GIZMOS": "0", "IKKOKU_AUTOCAPTURE": png],
                      mode: .appCapture),
        CaptureRecipe(source: "studio_execution_probe run phase", environment: probeRun, mode: .appCapture),
        CaptureRecipe(source: "studio_execution_probe reload phase", environment: probeReload, mode: .sceneCapture),
        CaptureRecipe(source: "studio_execution_probe continue phase", environment: probeContinue, mode: .sceneCapture),
        CaptureRecipe(source: "app-smoke startup-mute-capture",
                      environment: ["IKKOKU_SOURCE_PLUGIN_PROFILE": "/plugins/profile.json",
                                    "IKKOKU_NATIVE_PLUGIN_MANIFEST": "/plugins/mute.json",
                                    "IKKOKU_MUTE_BACKGROUND_CONFIG": "/plugins/mute.cfg", "IKKOKU_SOURCE_PLUGIN_STEPS": "30",
                                    "IKKOKU_SOURCE_PLUGIN_DELTA": "0.0333333333", "IKKOKU_APPLICATION_FOCUS": "0,1",
                                    "IKKOKU_NATIVE_PLUGIN_REPORT": "/captures/mute-gain.json", "IKKOKU_AUTOCAPTURE": png],
                      mode: .appCapture),
        CaptureRecipe(source: "app-smoke studio-inspector-capture",
                      environment: ["IKKOKU_SOURCE_SCENE": "/scenes/scene.png", "IKKOKU_SOURCE_AVATAR": "/rigs/source-avatar.json",
                                    "IKKOKU_CAPTURE_UI": png, "IKKOKU_CAPTURE_UI_MODE": "studio",
                                    "IKKOKU_CAPTURE_UI_STUDIO_TAB": "pose", "IKKOKU_CAPTURE_UI_REPORT": "/captures/pose.json"],
                      mode: .interactive, capturesWindow: true),
        CaptureRecipe(source: "studio-scenarios lane",
                      environment: ["IKKOKU_STUDIO_SCENARIO": "/scenarios/s.json", "IKKOKU_STUDIO_SCENARIO_REPORT": "/captures/s.json",
                                    "IKKOKU_SOURCE_SCENE": "/scenes/scene.png", "IKKOKU_SOURCE_AVATAR": "/rigs/source-avatar.json",
                                    "IKKOKU_STUDIO_ANIMATION_CATALOG": "/animation/catalog.json", "IKKOKU_MAKER_LIBRARY": "none"],
                      mode: .studioScenario),
        CaptureRecipe(source: "maker-scenarios lane",
                      environment: ["IKKOKU_MAKER_SCENARIO": "/scenarios/m.json", "IKKOKU_MAKER_SCENARIO_REPORT": "/captures/m.json",
                                    "IKKOKU_SOURCE_CARD": "/cards/card.png", "IKKOKU_SOURCE_AVATAR": "/rigs/source-avatar.json"],
                      mode: .makerScenario),
        CaptureRecipe(source: "gameplay-scenarios lane",
                      environment: ["IKKOKU_GAMEPLAY_SCENARIO": "/scenarios/g.json",
                                    "IKKOKU_GAMEPLAY_SCENARIO_REPORT": "/captures/g.json"],
                      mode: .gameplayScenario),
        CaptureRecipe(source: "gameplay scenario with a shared environment file",
                      environment: ["IKKOKU_GAMEPLAY_SCENARIO": "/scenarios/g.json",
                                    "IKKOKU_GAMEPLAY_SCENARIO_REPORT": "/captures/g.json",
                                    "IKKOKU_SOURCE_AVATAR": "/rigs/source-avatar.json", "IKKOKU_SOURCE_SCENE": "/scenes/scene.png"],
                      mode: .gameplayScenario),
        CaptureRecipe(source: "ST-T04 item catalog preview and export",
                      environment: ["IKKOKU_SOURCE_SCENE": "/scenes/scene.png", "IKKOKU_STUDIO_ITEM_CATALOG": "/catalog/items.json",
                                    "IKKOKU_BENCHMARK_OUTPUT": "/captures/benchmark.json",
                                    "IKKOKU_EXPORT_SOURCE_SCENE": "/captures/export.png", "IKKOKU_AUTOCAPTURE": png],
                      mode: .appCapture),
        CaptureRecipe(source: "app capture, then the window",
                      environment: ["IKKOKU_AUTOCAPTURE": png, "IKKOKU_CAPTURE_UI": "/captures/ui.png"],
                      mode: .appCapture, capturesWindow: true),
        CaptureRecipe(source: "shared environment file in a scene capture",
                      environment: ["IKKOKU_CAPTURE_SCENE": "/scenes/native.png", "IKKOKU_AUTOCAPTURE": png,
                                    "IKKOKU_SOURCE_SCENE": "/scenes/fixtures.json", "IKKOKU_MOD_LIBRARY": "/mods/library.json",
                                    "IKKOKU_NATIVE_PLUGIN_MANIFEST": "/plugins/mute.json",
                                    "IKKOKU_SOURCE_DYNAMICS_REFERENCE": "/dynamics/reference.json"],
                      mode: .sceneCapture),
        CaptureRecipe(source: "native Studio capture options",
                      environment: ["IKKOKU_AUTOCAPTURE": png, "IKKOKU_CAPTURE_STUDIO": "1", "IKKOKU_CAPTURE_POSE": "wave",
                                    "IKKOKU_CAPTURE_ITEMS": "chair,room_classroom", "IKKOKU_CAPTURE_TIMELINE": "1",
                                    "IKKOKU_CAPTURE_EXPR": "eyes=1,mouth=3,brows=2,head=0,gaze=1",
                                    "IKKOKU_CAPTURE_SLIDERS": "eye.size=80,body.height=-50", "IKKOKU_CAPTURE_OUTFIT": "1",
                                    "IKKOKU_CAPTURE_HAIR": "bob", "IKKOKU_CAPTURE_TICKS": "10", "IKKOKU_CAPTURE_SEX": "m",
                                    "IKKOKU_CAPTURE_PRESET": "Upper"],
                      mode: .appCapture),
    ]
    for recipe in recipes {
        let message = captureRequestMessage(recipe.environment)
        #expect(message.isEmpty, Comment(rawValue: "\(recipe.source): \(message)"))
        guard let request = try? CaptureRequest.validate(recipe.environment) else { continue }
        #expect(request.mode == recipe.mode, Comment(rawValue: recipe.source))
        #expect(request.capturesWindow == recipe.capturesWindow, Comment(rawValue: recipe.source))
    }
}

@Test func captureRequestIsAutomatedForEveryModeAndTheWindowCapture() throws {
    let interactive = try CaptureRequest.validate([:])
    #expect(interactive.mode == .interactive)
    #expect(!interactive.isAutomated)
    #expect(CaptureRequest(mode: .interactive, capturesWindow: true).isAutomated)
    for mode in CaptureRequest.Mode.allCases where mode != .interactive {
        #expect(CaptureRequest(mode: mode, capturesWindow: false).isAutomated, Comment(rawValue: mode.label))
    }
}

@Test func captureRequestRejectsConflictingModesNamingEach() {
    let rigAndScene: [String: String] = ["IKKOKU_CAPTURE_RIG": "/rig.json", "IKKOKU_CAPTURE_SCENE": "/scene.png",
                                         "IKKOKU_AUTOCAPTURE": "/out.png"]
    let rigAndSceneExpected: [[String]] = [["IKKOKU_CAPTURE_RIG", "IKKOKU_CAPTURE_SCENE"]]
    #expect(captureRequestProblems(rigAndScene) == rigAndSceneExpected)
    let rigAndSceneMessage = captureRequestMessage(rigAndScene)
    #expect(rigAndSceneMessage.contains("only one capture mode runs per launch"))
    #expect(rigAndSceneMessage.contains("source rig capture (IKKOKU_CAPTURE_RIG)"))

    // IKKOKU_AUTOCAPTURE is a mode of its own beside thumbnails, scenarios and the probe.
    let thumbnailsAndCapture: [[String]] = [["IKKOKU_RENDER_THUMBS", "IKKOKU_AUTOCAPTURE"]]
    #expect(captureRequestProblems(["IKKOKU_RENDER_THUMBS": "/thumbs", "IKKOKU_AUTOCAPTURE": "/out.png"]) == thumbnailsAndCapture)
    let probeAndScenario: [[String]] = [["IKKOKU_ORIGINAL_FRAME_PROBE", "IKKOKU_MAKER_SCENARIO"]]
    #expect(captureRequestProblems(["IKKOKU_ORIGINAL_FRAME_PROBE": "/frame.json", "IKKOKU_MAKER_SCENARIO": "/m.json",
                                    "IKKOKU_MAKER_SCENARIO_REPORT": "/m-report.json"]) == probeAndScenario)

    // The window capture needs the editor, which every mode except the app capture never opens.
    let windowAndRig: [[String]] = [["IKKOKU_CAPTURE_UI", "IKKOKU_CAPTURE_RIG"]]
    #expect(captureRequestProblems(["IKKOKU_CAPTURE_UI": "/ui.png", "IKKOKU_CAPTURE_RIG": "/rig.json",
                                    "IKKOKU_AUTOCAPTURE": "/out.png"]) == windowAndRig)
    let windowAndScenario: [[String]] = [["IKKOKU_CAPTURE_UI", "IKKOKU_STUDIO_SCENARIO"]]
    #expect(captureRequestProblems(["IKKOKU_CAPTURE_UI": "/ui.png", "IKKOKU_STUDIO_SCENARIO": "/s.json",
                                    "IKKOKU_STUDIO_SCENARIO_REPORT": "/s-report.json"]) == windowAndScenario)

    // A-T01: the gameplay scenario is a mode of its own and exits before any window opens.
    let gameplayAndStudio: [[String]] = [["IKKOKU_GAMEPLAY_SCENARIO", "IKKOKU_STUDIO_SCENARIO"]]
    #expect(captureRequestProblems(["IKKOKU_GAMEPLAY_SCENARIO": "/g.json", "IKKOKU_GAMEPLAY_SCENARIO_REPORT": "/g-report.json",
                                    "IKKOKU_STUDIO_SCENARIO": "/s.json",
                                    "IKKOKU_STUDIO_SCENARIO_REPORT": "/s-report.json"]) == gameplayAndStudio)
    let gameplayAndCapture: [[String]] = [["IKKOKU_GAMEPLAY_SCENARIO", "IKKOKU_AUTOCAPTURE"]]
    #expect(captureRequestProblems(["IKKOKU_GAMEPLAY_SCENARIO": "/g.json", "IKKOKU_GAMEPLAY_SCENARIO_REPORT": "/g-report.json",
                                    "IKKOKU_AUTOCAPTURE": "/out.png"]) == gameplayAndCapture)
    let windowAndGameplay: [[String]] = [["IKKOKU_CAPTURE_UI", "IKKOKU_GAMEPLAY_SCENARIO"]]
    #expect(captureRequestProblems(["IKKOKU_CAPTURE_UI": "/ui.png", "IKKOKU_GAMEPLAY_SCENARIO": "/g.json",
                                    "IKKOKU_GAMEPLAY_SCENARIO_REPORT": "/g-report.json"]) == windowAndGameplay)
    #expect(captureRequestMessage(["IKKOKU_GAMEPLAY_SCENARIO": "/g.json", "IKKOKU_GAMEPLAY_SCENARIO_REPORT": "/g-report.json",
                                   "IKKOKU_AUTOCAPTURE": "/out.png"]).contains("the gameplay scenario (IKKOKU_GAMEPLAY_SCENARIO)"))
}

@Test func captureRequestRejectsAModeWithoutItsOutput() {
    for selector in ["IKKOKU_CAPTURE_RIG", "IKKOKU_CAPTURE_MODEL", "IKKOKU_CAPTURE_SCENE"] {
        let expected: [[String]] = [[selector]]
        #expect(captureRequestProblems([selector: "/input"]) == expected)
        #expect(captureRequestMessage([selector: "/input"]).contains("IKKOKU_AUTOCAPTURE, which is not set"))
    }
    let makerScenario: [[String]] = [["IKKOKU_MAKER_SCENARIO"]]
    #expect(captureRequestProblems(["IKKOKU_MAKER_SCENARIO": "/m.json"]) == makerScenario)
    let studioScenario: [[String]] = [["IKKOKU_STUDIO_SCENARIO"]]
    #expect(captureRequestProblems(["IKKOKU_STUDIO_SCENARIO": "/s.json"]) == studioScenario)
    let gameplayScenario: [[String]] = [["IKKOKU_GAMEPLAY_SCENARIO"]]
    #expect(captureRequestProblems(["IKKOKU_GAMEPLAY_SCENARIO": "/g.json"]) == gameplayScenario)
    #expect(captureRequestMessage(["IKKOKU_GAMEPLAY_SCENARIO": "/g.json"])
        .contains("writes its report to IKKOKU_GAMEPLAY_SCENARIO_REPORT, which is not set"))
    // A report without its scenario reaches no mode that writes it.
    let reportOnly: [[String]] = [["IKKOKU_STUDIO_SCENARIO_REPORT"]]
    #expect(captureRequestProblems(["IKKOKU_STUDIO_SCENARIO_REPORT": "/s.json"]) == reportOnly)
    let gameplayReportOnly: [[String]] = [["IKKOKU_GAMEPLAY_SCENARIO_REPORT"]]
    #expect(captureRequestProblems(["IKKOKU_GAMEPLAY_SCENARIO_REPORT": "/g.json"]) == gameplayReportOnly)
    // A capture option inside the gameplay scenario has no effect there.
    let widthInGameplay: [[String]] = [["IKKOKU_CAPTURE_W"]]
    #expect(captureRequestProblems(["IKKOKU_GAMEPLAY_SCENARIO": "/g.json", "IKKOKU_GAMEPLAY_SCENARIO_REPORT": "/g-report.json",
                                    "IKKOKU_CAPTURE_W": "900"]) == widthInGameplay)
}

/// A06 decision: the native plugin report and focus events are capture-only
/// evidence, so a launch that would stay open (or exit through a scenario that
/// never writes the report) is rejected up front instead of leaving a required
/// output to an alert.
@Test func captureRequestKeepsTheNativePluginReportInsideACapture() throws {
    let mounts: [String: String] = ["IKKOKU_SOURCE_PLUGIN_PROFILE": "/profile.json", "IKKOKU_NATIVE_PLUGIN_MANIFEST": "/mute.json",
                                    "IKKOKU_NATIVE_PLUGIN_REPORT": "/report.json", "IKKOKU_APPLICATION_FOCUS": "0,1"]
    let interactiveExpected: [[String]] = [["IKKOKU_NATIVE_PLUGIN_REPORT"], ["IKKOKU_APPLICATION_FOCUS"]]
    #expect(captureRequestProblems(mounts) == interactiveExpected)
    #expect(captureRequestMessage(mounts).contains("this launch requests no capture mode"))

    var scenario = mounts
    scenario["IKKOKU_STUDIO_SCENARIO"] = "/s.json"
    scenario["IKKOKU_STUDIO_SCENARIO_REPORT"] = "/s-report.json"
    #expect(captureRequestProblems(scenario) == interactiveExpected)

    var appCapture = mounts
    appCapture["IKKOKU_AUTOCAPTURE"] = "/out.png"
    #expect(try CaptureRequest.validate(appCapture).mode == .appCapture)
    var sceneCapture = appCapture
    sceneCapture["IKKOKU_CAPTURE_SCENE"] = "/scene.png"
    #expect(try CaptureRequest.validate(sceneCapture).mode == .sceneCapture)
}

@Test func captureRequestRejectsOptionsThatNoRequestedModeReads() {
    let widthOnly: [[String]] = [["IKKOKU_CAPTURE_W"]]
    #expect(captureRequestProblems(["IKKOKU_CAPTURE_W": "900"]) == widthOnly)
    let card: [[String]] = [["IKKOKU_CARD"]]
    #expect(captureRequestProblems(["IKKOKU_CARD": "/card.png"]) == card)

    let mirrorInScene: [String: String] = ["IKKOKU_CAPTURE_MIRROR": "1", "IKKOKU_CAPTURE_SCENE": "/scene.png",
                                           "IKKOKU_AUTOCAPTURE": "/out.png"]
    let mirrorExpected: [[String]] = [["IKKOKU_CAPTURE_MIRROR"]]
    #expect(captureRequestProblems(mirrorInScene) == mirrorExpected)
    let mirrorMessage = captureRequestMessage(mirrorInScene)
    #expect(mirrorMessage.contains("only static model capture (IKKOKU_CAPTURE_MODEL) reads it"))
    #expect(mirrorMessage.contains("this launch runs native scene capture"))

    let sceneOptions: [String: String] = ["IKKOKU_CAPTURE_SCENE": "/scene.png", "IKKOKU_AUTOCAPTURE": "/out.png",
                                          "IKKOKU_CAPTURE_YAW": "30", "IKKOKU_LOAD_SCENE": "/other.png"]
    let sceneExpected: [[String]] = [["IKKOKU_CAPTURE_YAW"], ["IKKOKU_LOAD_SCENE"]]
    #expect(captureRequestProblems(sceneOptions) == sceneExpected)

    // A window option without the window capture is reported once, not also as a missing dependency.
    let studioTab: [[String]] = [["IKKOKU_CAPTURE_UI_STUDIO_TAB"]]
    #expect(captureRequestProblems(["IKKOKU_CAPTURE_UI_STUDIO_TAB": "pose"]) == studioTab)
    #expect(captureRequestMessage(["IKKOKU_CAPTURE_UI_STUDIO_TAB": "pose"]).contains("IKKOKU_CAPTURE_UI is not set"))
}

@Test func captureRequestRejectsOptionsMissingTheOptionTheyActWith() {
    let pose: [[String]] = [["IKKOKU_CAPTURE_POSE"]]
    #expect(captureRequestProblems(["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_CAPTURE_POSE": "wave"]) == pose)
    #expect(captureRequestMessage(["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_CAPTURE_POSE": "wave"])
        .contains("without IKKOKU_CAPTURE_STUDIO"))

    let makerTab: [String: String] = ["IKKOKU_CAPTURE_UI": "/ui.png", "IKKOKU_CAPTURE_UI_MODE": "maker",
                                      "IKKOKU_CAPTURE_UI_STUDIO_TAB": "pose"]
    let makerTabExpected: [[String]] = [["IKKOKU_CAPTURE_UI_STUDIO_TAB"]]
    #expect(captureRequestProblems(makerTab) == makerTabExpected)
    #expect(captureRequestMessage(makerTab).contains("IKKOKU_CAPTURE_UI_MODE=studio"))

    let familySets: [[String]] = [["IKKOKU_ORIGINAL_FRAME_FAMILY_SETS"]]
    #expect(captureRequestProblems(["IKKOKU_ORIGINAL_FRAME_PROBE": "/frame.json",
                                    "IKKOKU_ORIGINAL_FRAME_FAMILY_SETS": "main_hair"]) == familySets)
    let depthOn: [[String]] = [["IKKOKU_ORIGINAL_FRAME_DEPTH24"]]
    #expect(captureRequestProblems(["IKKOKU_ORIGINAL_FRAME_PROBE": "/frame.json", "IKKOKU_ORIGINAL_FRAME_DEPTH24": "1"]) == depthOn)
    // Depth emulation switched off needs nothing.
    #expect(captureRequestProblems(["IKKOKU_ORIGINAL_FRAME_PROBE": "/frame.json", "IKKOKU_ORIGINAL_FRAME_DEPTH24": "0"]).isEmpty)

    let simulation: [[String]] = [["IKKOKU_BENCHMARK_SIMULATION_FRAMES"]]
    #expect(captureRequestProblems(["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_BENCHMARK_OUTPUT": "/b.json",
                                    "IKKOKU_BENCHMARK_SIMULATION_FRAMES": "30"]) == simulation)
    // Startup inputs keep their own dependencies in every mode, the interactive editor included.
    let delta: [[String]] = [["IKKOKU_SOURCE_PLUGIN_DELTA"]]
    #expect(captureRequestProblems(["IKKOKU_SOURCE_PLUGIN_DELTA": "0.1"]) == delta)
}

@Test func captureRequestRejectsCombinationsThatCaptureOtherContent() {
    let cardAndSourceCard: [[String]] = [["IKKOKU_CARD", "IKKOKU_SOURCE_CARD"]]
    #expect(captureRequestProblems(["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_CARD": "/native.png",
                                    "IKKOKU_SOURCE_CARD": "/source.png"]) == cardAndSourceCard)
    let cardAndEdits: [[String]] = [["IKKOKU_CARD", "IKKOKU_SOURCE_BODY", "IKKOKU_SOURCE_COORDINATE"]]
    #expect(captureRequestProblems(["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_CARD": "/native.png",
                                    "IKKOKU_SOURCE_BODY": "defaults", "IKKOKU_SOURCE_COORDINATE": "1"]) == cardAndEdits)
    let sexAndCard: [[String]] = [["IKKOKU_CAPTURE_SEX", "IKKOKU_CARD"]]
    #expect(captureRequestProblems(["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_CARD": "/native.png",
                                    "IKKOKU_CAPTURE_SEX": "m"]) == sexAndCard)
    let rigCardAndHeight: [[String]] = [["IKKOKU_SOURCE_CARD", "IKKOKU_SOURCE_HEIGHT"]]
    #expect(captureRequestProblems(["IKKOKU_CAPTURE_RIG": "/rig.json", "IKKOKU_AUTOCAPTURE": "/out.png",
                                    "IKKOKU_SOURCE_CARD": "/source.png", "IKKOKU_SOURCE_HEIGHT": "0.5"]) == rigCardAndHeight)
    // The app capture applies shape overrides after the card import, so there they combine.
    #expect(captureRequestProblems(["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_SOURCE_CARD": "/source.png",
                                    "IKKOKU_SOURCE_BODY": "defaults"]).isEmpty)
}

@Test func captureRequestRejectsValuesTheModeWouldIgnore() {
    func problems(_ variable: String, _ value: String, in mode: [String: String] = ["IKKOKU_AUTOCAPTURE": "/out.png"]) -> [[String]] {
        var environment = mode
        environment[variable] = value
        return captureRequestProblems(environment)
    }
    let rejected: [(String, String)] = [
        ("IKKOKU_CAPTURE_W", "900px"), ("IKKOKU_CAPTURE_H", "0"), ("IKKOKU_CAPTURE_W", "8193"),
        ("IKKOKU_CAPTURE_TICKS", "-1"), ("IKKOKU_CAPTURE_YAW", "nan"),
        ("IKKOKU_CAPTURE_PRESET", "side"), ("IKKOKU_CAPTURE_GRID", "no"), ("IKKOKU_CAPTURE_SEX", "x"),
        ("IKKOKU_CAPTURE_OUTFIT", "two"), ("IKKOKU_SOURCE_COORDINATE", "-1"),
        ("IKKOKU_CAPTURE_EXPR", "eyes=1,smile=2"), ("IKKOKU_CAPTURE_EXPR", "eyes=1,mouth=x"), ("IKKOKU_CAPTURE_EXPR", "eyes=1,"),
        ("IKKOKU_CAPTURE_SLIDERS", "eye.size=80,body.height"), ("IKKOKU_CAPTURE_SLIDERS", "=4"),
        ("IKKOKU_APPLICATION_FOCUS", "0,2"), ("IKKOKU_APPLICATION_FOCUS", ""),
        ("IKKOKU_APPLICATION_FOCUS", Array(repeating: "0", count: 65).joined(separator: ",")),
    ]
    for (variable, value) in rejected {
        let expected: [[String]] = [[variable]]
        #expect(problems(variable, value) == expected, Comment(rawValue: "\(variable)=\(value)"))
    }
    #expect(captureRequestMessage(["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_CAPTURE_W": "900px"]).contains("from 1 to 8192"))
    #expect(captureRequestMessage(["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_CAPTURE_EXPR": "smile=2"]).contains("'smile'"))
    #expect(problems("IKKOKU_CAPTURE_PRESET", "Face").isEmpty)
    #expect(problems("IKKOKU_APPLICATION_FOCUS", Array(repeating: "1", count: 64).joined(separator: ",")).isEmpty)

    // Values of options that act together with another one.
    let studio: [String: String] = ["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_CAPTURE_STUDIO": "1"]
    let timeline: [[String]] = [["IKKOKU_CAPTURE_TIMELINE"]]
    #expect(problems("IKKOKU_CAPTURE_TIMELINE", "soon", in: studio) == timeline)
    let benchmark: [String: String] = ["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_BENCHMARK_OUTPUT": "/b.json"]
    let frames: [[String]] = [["IKKOKU_BENCHMARK_FRAMES"]]
    #expect(problems("IKKOKU_BENCHMARK_FRAMES", "0", in: benchmark) == frames)
    #expect(problems("IKKOKU_BENCHMARK_FRAMES", "20", in: benchmark).isEmpty)

    // Mode-specific values: rig capture frames only the face preset, and native
    // scene capture always hides the grid and gizmos.
    let rig: [String: String] = ["IKKOKU_CAPTURE_RIG": "/rig.json", "IKKOKU_AUTOCAPTURE": "/out.png"]
    let preset: [[String]] = [["IKKOKU_CAPTURE_PRESET"]]
    #expect(problems("IKKOKU_CAPTURE_PRESET", "full", in: rig) == preset)
    #expect(problems("IKKOKU_CAPTURE_PRESET", "face", in: rig).isEmpty)
    let scene: [String: String] = ["IKKOKU_CAPTURE_SCENE": "/scene.png", "IKKOKU_AUTOCAPTURE": "/out.png"]
    let grid: [[String]] = [["IKKOKU_CAPTURE_GRID"]]
    #expect(problems("IKKOKU_CAPTURE_GRID", "1", in: scene) == grid)
    #expect(problems("IKKOKU_CAPTURE_GRID", "0", in: scene).isEmpty)
    #expect(problems("IKKOKU_CAPTURE_GRID", "1").isEmpty)

    let window: [String: String] = ["IKKOKU_CAPTURE_UI": "/ui.png"]
    let mode: [[String]] = [["IKKOKU_CAPTURE_UI_MODE"]]
    #expect(problems("IKKOKU_CAPTURE_UI_MODE", "Studio", in: window) == mode)
    let timeout: [[String]] = [["IKKOKU_CAPTURE_UI_TIMEOUT"]]
    #expect(problems("IKKOKU_CAPTURE_UI_TIMEOUT", "0", in: window) == timeout)
}

@Test func captureRequestRejectsEmptyValuesAndMisspelledCaptureNames() throws {
    let emptyOutput: [[String]] = [["IKKOKU_AUTOCAPTURE"]]
    #expect(captureRequestProblems(["IKKOKU_AUTOCAPTURE": ""]) == emptyOutput)
    #expect(captureRequestMessage(["IKKOKU_AUTOCAPTURE": ""]).contains("is set but empty"))
    let emptyInput: [[String]] = [["IKKOKU_SOURCE_SCENE"]]
    #expect(captureRequestProblems(["IKKOKU_SOURCE_SCENE": ""]) == emptyInput)

    let misspelled: [[String]] = [["IKKOKU_CAPTURE_WIDTH"]]
    #expect(captureRequestProblems(["IKKOKU_AUTOCAPTURE": "/out.png", "IKKOKU_CAPTURE_WIDTH": "900"]) == misspelled)
    #expect(captureRequestMessage(["IKKOKU_CAPTURE_WIDTH": "900"]).contains("check the spelling"))

    // Other tools' fixture variables in a shared environment file are not capture names.
    let fixture = try CaptureRequest.validate(["IKKOKU_SOURCE_DYNAMICS_REFERENCE": "/dynamics/reference.json",
                                               "IKKOKU_REQUIRE_SOURCE_FIXTURES": "1"])
    #expect(fixture.mode == .interactive)
}

@Test func captureRequestErrorListsEveryOffendingVariableInOneMessage() throws {
    let failure = try #require(captureRequestFailure(["IKKOKU_CAPTURE_RIG": "/rig.json", "IKKOKU_CAPTURE_MIRROR": "1",
                                                      "IKKOKU_CARD": "/card.png"]))
    let problems: [[String]] = [["IKKOKU_CAPTURE_RIG"], ["IKKOKU_CAPTURE_MIRROR"], ["IKKOKU_CARD"]]
    #expect(failure.problems.map { $0.variables } == problems)
    let variables: [String] = ["IKKOKU_CAPTURE_MIRROR", "IKKOKU_CAPTURE_RIG", "IKKOKU_CARD"]
    #expect(failure.variables == variables)
    let lines = String(describing: failure).split(separator: "\n").map { String($0) }
    #expect(lines.count == 4)
    #expect(lines.first == "invalid capture request; offending variables: IKKOKU_CAPTURE_MIRROR, IKKOKU_CAPTURE_RIG, IKKOKU_CARD")
    #expect(lines.dropFirst().allSatisfy { $0.hasPrefix("  - IKKOKU_") })
}

@Test func captureRequestInventoryClassifiesEachVariableOnce() {
    let names = CaptureRequest.knownVariables
    #expect(Set(names).count == names.count)
    #expect(names.allSatisfy { $0.hasPrefix("IKKOKU_") })
    for name in ["IKKOKU_AUTOCAPTURE", "IKKOKU_CAPTURE_UI", "IKKOKU_CARD", "IKKOKU_LOAD_SCENE", "IKKOKU_NATIVE_PLUGIN_REPORT",
                 "IKKOKU_CAPTURE_UI_TIMEOUT", "IKKOKU_SOURCE_AVATAR", "IKKOKU_GAMEPLAY_SCENARIO",
                 "IKKOKU_GAMEPLAY_SCENARIO_REPORT"] {
        #expect(names.contains(name), Comment(rawValue: name))
    }
}

@Test func captureInputErrorNamesTheVariableValueAndReason() {
    let error = CaptureInputError(variable: "IKKOKU_CARD", value: "/cards/missing.png", reason: "no file exists at this path")
    #expect(String(describing: error) == "IKKOKU_CARD=/cards/missing.png: no file exists at this path")
}
