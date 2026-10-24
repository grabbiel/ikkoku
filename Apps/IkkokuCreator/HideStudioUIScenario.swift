import Foundation
import AppKit
import Gameplay
import Studio
import Renderer
import simd
import ShaderTypes
import Scene

/// Bounded native-host checks for the exact Studio visibility adapter. The
/// source Unity oracle is separate; this checks Ikkoku's role/focus contract.
struct HideStudioUIScenario: Decodable {
    let manifestFile: String
    let rejectedManifestFile: String?
    let sceneFile: String
    var reload: Bool = false

    @MainActor func run(app: AppState, studio: StudioModel) -> StudioScenario.Report {
        var rows: [StudioScenario.Report.StepResult] = []
        func check(_ name: String, _ condition: Bool, _ detail: String = "") throws {
            rows.append(.init(op: name, ok: condition, detail: detail))
            if !condition { throw SourcePluginError.runtime("Visibility scenario assertion failed: \(name)") }
        }
        func counts() -> [Int] {
            let s = studio.host.renderer.resources.statistics()
            return [s.meshes, s.textures, s.deformBuffers, s.hiddenBuffers,
                    s.meshBufferBytes, s.deformBufferBytes, s.hiddenBufferBytes, s.retiring]
        }
        func sameContent(_ a: RenderFrame, _ b: RenderFrame) -> Bool {
            a.camera == b.camera && a.mainLight == b.mainLight && a.effects == b.effects
                && a.lights == b.lights && a.sceneBounds == b.sceneBounds && a.time == b.time
                && a.skinSets == b.skinSets && a.items.count == b.items.count
                && zip(a.items, b.items).allSatisfy { $0.mesh == $1.mesh && $0.model == $1.model && $0.objectID == $1.objectID }
        }
        func space(repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = []) throws -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: repeatKey, keyCode: 49) else { throw SourcePluginError.runtime("Space event unavailable.") }
            return studio.keyDown(event)
        }
        do {
            studio.liveAnimation = false; studio.sourcePluginsRunning = false
            app.maker?.liveAnimation = false; app.mode = .studio
            let manifest = URL(fileURLWithPath: manifestFile), scene = URL(fileURLWithPath: sceneFile)
            if reload {
                try studio.loadScene(from: scene)
                try check("freshProcessVisible", studio.sourceHideStudioUI != nil && studio.sourceInterfaceVisible)
                let expected = SourceNativePluginReference(package: try SourceNativePluginPackage.load(url: manifest))
                try check("freshProcessPinnedReference", studio.doc.sourceNativePlugins == [expected])
                try check("freshProcessSpace", try space() && !studio.sourceInterfaceVisible && !studio.timelinePlaying)
                studio.revealSourceInterface()
                try check("freshProcessRecovery", studio.sourceInterfaceVisible)
            } else {
                studio.doc = StudioDocument()
                let object = StudioObject(name: "Visibility guide", kind: .camera)
                studio.doc.objects = [object]; studio.selection = object.id
                studio.showGizmos = false; studio.showTimeline = false
                let start = ProcessInfo.processInfo.systemUptime
                try studio.loadSourceNativePlugin(url: manifest)
                try check("mountPreservesHiddenPreferences", studio.sourceInterfaceVisible && !studio.showGizmos && !studio.showTimeline,
                          "Mount \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms; includes package validation and refresh")
                let original = studio.doc, resources = counts(), frame = studio.host.renderer.currentFrame()
                try check("spaceHidesWithoutPlayback", try space() && !studio.sourceInterfaceVisible && !studio.timelinePlaying)
                try check("repeatConsumed", try space(repeatKey: true) && !studio.sourceInterfaceVisible && !studio.timelinePlaying)
                try check("modifiedSpaceUnhandled", try !space(modifiers: [.command]) && !studio.sourceInterfaceVisible && !studio.timelinePlaying)
                try check("hiddenFramePreservesContent", sameContent(frame, studio.host.renderer.currentFrame())
                    && studio.host.renderer.currentFrame().gizmos.isEmpty && studio.doc == original && counts() == resources)
                if let rejectedManifestFile {
                    var rejected = false
                    do { try studio.loadSourceNativePlugin(url: URL(fileURLWithPath: rejectedManifestFile)) }
                    catch { rejected = String(describing: error).contains("unmodified Space") }
                    try check("unsupportedConfigurationRollback", rejected && studio.doc == original
                        && !studio.sourceInterfaceVisible && counts() == resources)
                }
                try studio.saveScene(to: scene)
                try check("saveDoesNotReveal", !studio.sourceInterfaceVisible && studio.doc == original)
                try studio.loadScene(from: scene)
                try check("loadStartsVisibleWithoutChangingPreferences", studio.sourceInterfaceVisible
                    && studio.sourceHideStudioUI != nil && !studio.showGizmos && !studio.showTimeline)
                studio.selection = object.id; studio.showGizmos = true; studio.showTimeline = true
                let shown = studio.host.renderer.currentFrame()
                try check("guideFixtureVisible", !shown.gizmos.isEmpty)
                let repeatedResources = counts(), repeatedStart = ProcessInfo.processInfo.systemUptime
                for _ in 0..<6 { _ = try space(); _ = try space() }
                try check("repeatedEventsRetainResources", studio.sourceInterfaceVisible && counts() == repeatedResources
                    && sameContent(shown, studio.host.renderer.currentFrame()),
                    "12 events \((ProcessInfo.processInfo.systemUptime - repeatedStart) * 1000) ms; no tick work added")
                let candidates = shown.gizmos.filter { PickIDs.axis(from: $0.objectID) != nil }
                    .flatMap { $0.vertices }.prefix(128).compactMap {
                        studio.viewCamera.project(simd_make_float3($0.position), viewport: studio.viewportSize)
                    }
                guard let grabbed = candidates.first(where: { PickIDs.axis(from: studio.pickID(at: $0)) != nil }) else {
                    throw SourcePluginError.runtime("No real guide pixel found for hidden-drag regression.")
                }
                let undoDepth = studio.undoStack.count
                studio.mouseDown(at: grabbed, button: 0, modifiers: [])
                try check("guideGestureStarted", studio.undoStack.count == undoDepth + 1)
                let beforeDrag = studio.doc
                _ = try space()
                studio.mouseDragged(to: grabbed + SIMD2(30, 20), delta: SIMD2(30, 20), button: 0, modifiers: [])
                studio.mouseUp(at: grabbed, button: 0, modifiers: [])
                try check("hidingCancelsGuideGesture", studio.doc == beforeDrag)
                try check("guidesHiddenByLayer", !studio.sourceInterfaceVisible && studio.showGizmos && studio.showTimeline
                    && studio.host.renderer.currentFrame().gizmos.isEmpty)
                let cameraBefore = studio.documentCamera
                studio.mouseDown(at: SIMD2(200, 200), button: 1, modifiers: [])
                studio.mouseDragged(to: SIMD2(220, 210), delta: SIMD2(20, 10), button: 1, modifiers: [])
                studio.mouseUp(at: SIMD2(220, 210), button: 1, modifiers: [])
                try check("hiddenViewportStillOrbits", studio.documentCamera != cameraBefore && !studio.sourceInterfaceVisible)
                app.mode = .maker
                let makerFrame = studio.host.renderer.currentFrame(), inactiveResources = counts()
                try check("modeExitRevealsLayer", studio.sourceInterfaceVisible && studio.showGizmos && studio.showTimeline)
                try check("inactiveSpaceCannotSubmit", try !space() && sameContent(makerFrame, studio.host.renderer.currentFrame())
                    && makerFrame.gizmos.count == studio.host.renderer.currentFrame().gizmos.count && counts() == inactiveResources)
                let inactiveDoc = studio.doc, inactiveAdapter = studio.sourceHideStudioUI
                studio.openSourceNativePlugin()
                try check("inactiveNativeMenuCannotSubmit", studio.doc == inactiveDoc && studio.sourceHideStudioUI == inactiveAdapter
                    && sameContent(makerFrame, studio.host.renderer.currentFrame()) && counts() == inactiveResources)
                app.mode = .studio; _ = try space(); studio.revealSourceInterface()
                try check("menuRecovery", studio.sourceInterfaceVisible && studio.showGizmos && studio.showTimeline)
                _ = try space(); studio.newScene()
                try check("newSceneRevealsLayer", studio.sourceInterfaceVisible && studio.sourceHideStudioUI != nil)
                _ = try space(); studio.unloadSourcePluginLibrary()
                try check("unloadRemovesLayer", studio.sourceHideStudioUI == nil && studio.sourceInterfaceVisible
                    && studio.showGizmos && studio.showTimeline)
                try check("ordinarySpaceRetainsPlayback", try space() && studio.timelinePlaying)
                studio.timelinePlaying = false
            }
        } catch {
            rows.append(.init(op: "error", ok: false, detail: String(describing: error)))
        }
        return .init(steps: rows, passed: rows.filter(\.ok).count, failed: rows.filter { !$0.ok }.count)
    }
}
