import Foundation
import Renderer
import Character
import Studio
import GPU

/// The Studio side of the opt-in live source-shader path (R1/CMT-04). Each
/// converted character gets one `SourceShaderLiveAssembly`, derived once from
/// its card and rebuilt when the preview is (outfit, colour or scene change);
/// every frame then marks that character's render items for live drawing.
/// Nothing here runs while `liveSourceShaders` is off.
extension StudioModel {
    /// CharaStudio's scene-level shader globals are not recovered: only
    /// `Studio.SceneInfo` is decompiled, not the code that turns its fields
    /// into `Shader.SetGlobal*` calls, so the harness constants must not stand in.
    static let liveSceneGlobalsReason = "CharaStudio's SceneInfo → Shader.SetGlobal mapping (_ambientshadowG, _LineColorG, _linewidthG, _RampG) is not recovered"

    var liveSourceConfiguration: SourceShaderLiveConfiguration {
        SourceShaderLiveConfiguration.environment(ProcessInfo.processInfo.environment, sourceAvatar: try? EngineHost.locateSourceAvatar())
    }

    /// Marks `frame`'s items of one character for live drawing and appends
    /// its status lines; a character whose assembly failed stays toon with the reason.
    func applyLiveSourceShaders(_ frame: inout RenderFrame, id: UUID, preview: SourceStudioCharacterPreview, lines: inout [String]) {
        let label = "Character \(preview.reference.objectKey)"
        switch liveAssembly(id: id, preview: preview) {
        case .failure(let reason):
            lines.append("\(label): toon — \(reason.text)")
        case .success(let assembly):
            // The binding set follows the card's saved wear. When the document
            // changes the clothes state or accessory visibility (ST-C03), the
            // source would enable other renderers than the ones this frame
            // draws, so the character stays toon and says why.
            if preview.clothesState != preview.loadedClothesState || preview.showAccessory != preview.savedWear.showAccessory {
                let reason = "the binding set covers the card's saved wear; this scene changes it (clothes state "
                    + preview.clothesState.map(String.init).joined(separator: ",") + ", \(preview.showAccessory.filter { $0 }.count) of 20 accessories shown)"
                liveSourceLastAttach[id] = nil; liveSourceWearChanged[id] = reason
                lines.append("\(label): toon — \(reason)")
                return
            }
            liveSourceWearChanged[id] = nil
            let report = assembly.attach(to: &frame, resources: host.renderer.resources, overrides: preview.liveIrisOverrides())
            liveSourceLastAttach[id] = report
            lines.append("\(label): \(report.live.count) live, \(report.fallbacks.count) toon, \(report.hidden.count) hidden")
            lines += report.fallbacks.map { "  toon: \($0)" } + report.hidden.map { "  hidden: \($0)" } + report.unmatched.map { "  unmatched: \($0)" }
        }
    }

    private func liveAssembly(id: UUID, preview: SourceStudioCharacterPreview) -> Result<SourceShaderLiveAssembly, SourceShaderLiveReason> {
        if let entry = liveSourceAssemblies[id], entry.preview === preview { return entry.result }
        let result: Result<SourceShaderLiveAssembly, SourceShaderLiveReason>
        do {
            let configuration = liveSourceConfiguration
            let shared: SourceShaderLiveConfiguration.Shared
            switch liveSourceShared {
            case .success(let loaded)?: shared = loaded
            case .failure(let reason)?: throw reason
            case nil:
                do { shared = try configuration.loadShared(device: host.renderer.gpu.device); liveSourceShared = .success(shared) }
                catch { let reason = SourceShaderLiveReason("live inputs unavailable: \(error)"); liveSourceShared = .failure(reason); throw reason }
            }
            let inputs = try configuration.inputs(makerLibrary: preview.reference.makerLibraryFile.map { URL(fileURLWithPath: $0) })
            let bindings = try inputs.derive(card: try preview.record.card(), scene: nil, sceneReason: Self.liveSceneGlobalsReason,
                                             eyeLook: try preview.shaderBindingEyeLook())
            // The derivation follows the card's saved outfit; another outfit's
            // renderers would map onto the wrong materials.
            guard bindings.provenance["coordinate"] == String(preview.coordinate) else {
                throw SourceShaderLiveReason("the binding set covers the card's saved outfit \(bindings.provenance["coordinate"] ?? "?"), the preview shows outfit \(preview.coordinate)")
            }
            let assembly = SourceShaderLiveAssembly(bindings: bindings, programs: inputs.programs, resources: host.renderer.resources,
                                                    textures: shared.textures, streams: shared.streams, anisotropicFiltering: nil)
            for line in shared.notes + assembly.resolution { print("[ikkoku] live source shaders, character \(preview.reference.objectKey): \(line)") }
            result = .success(assembly)
        } catch let reason as SourceShaderLiveReason { result = .failure(reason) }
        catch { result = .failure(SourceShaderLiveReason("\(error)")) }
        liveSourceAssemblies[id] = (preview, result)
        return result
    }

    /// Publishes this frame's status plus the renderer's own fallbacks from
    /// the last drawn frame, only when it changed (it is observed by the UI).
    func publishLiveSourceShaderStatus(_ lines: [String]) {
        liveSourceAssemblies = liveSourceAssemblies.filter { id, _ in doc.objects.contains { $0.id == id } }
        var status = lines.isEmpty ? ["No converted source character in the scene."] : lines
        status += host.renderer.lastSourceShaderLive.fallbacks.map { "  renderer: \($0)" }
        if status != liveSourceShaderStatus { liveSourceShaderStatus = status }
    }

    /// The live-path report of the current frame (Studio app capture).
    func liveSourceShaderReport() -> [String: Any] {
        var characters: [[String: Any]] = []
        for (id, entry) in liveSourceAssemblies.sorted(by: { $0.value.preview.reference.objectKey < $1.value.preview.reference.objectKey }) {
            var row: [String: Any] = ["objectKey": entry.preview.reference.objectKey, "coordinate": entry.preview.coordinate]
            switch entry.result {
            case .failure(let reason): row["toon"] = reason.text
            case .success(let assembly):
                row["textureProvider"] = assembly.textureProvider
                row["resolution"] = assembly.resolution
                if let reason = liveSourceWearChanged[id] { row["toon"] = reason }
                if let attach = liveSourceLastAttach[id] {
                    row["live"] = attach.live; row["fallbacks"] = attach.fallbacks; row["hidden"] = attach.hidden; row["unmatched"] = attach.unmatched
                }
            }
            characters.append(row)
        }
        return ["schemaVersion": 1, "enabled": liveSourceShaders, "sceneGlobals": "unresolved: \(Self.liveSceneGlobalsReason)",
                "characters": characters, "renderer": ["draws": host.renderer.lastSourceShaderLive.draws, "fallbacks": host.renderer.lastSourceShaderLive.fallbacks]]
    }
}
