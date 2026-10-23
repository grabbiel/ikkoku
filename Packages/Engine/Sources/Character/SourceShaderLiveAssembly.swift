import Foundation
import CryptoKit
import Renderer

/// Opt-in live source-shader path (R1/CMT-04, `IKKOKU_LIVE_SOURCE_SHADERS`):
/// resolves one character's `SourceShaderBindingSet` into live materials once,
/// then marks each frame's matching `RenderItem`s so the renderer draws them
/// with the translated original programs. Every renderer slot that cannot be
/// resolved (unresolved binding input, missing texture pixels, missing vertex
/// stream, untranslated shader, ambiguous mesh mapping) keeps its native toon
/// draw and is listed in `fallbacks` — a frame never mixes the two silently.
public final class SourceShaderLiveAssembly: @unchecked Sendable {
    /// File inputs of the binding derivation and the live path.
    public struct Inputs: Sendable {
        public var programs: URL
        public var makerLibrary: URL
        public var headContract: URL
        public var supplement: URL?
        public var hiPoly: Bool
        public init(programs: URL, makerLibrary: URL, headContract: URL, supplement: URL?, hiPoly: Bool = true) {
            self.programs = programs; self.makerLibrary = makerLibrary; self.headContract = headContract; self.supplement = supplement; self.hiPoly = hiPoly
        }

        /// The native binding set for `card` (`SourceShaderBindingDerivation`).
        /// `scene` nil marks the scene-level globals unresolved with `sceneReason`
        /// (CharaStudio's `SceneInfo` → `Shader.SetGlobal*` mapping is not recovered).
        public func derive(card: SourceCharacterCard, scene: SourceShaderBindingDerivation.SceneGlobals?, sceneReason: String,
                           eyeLook: SourceShaderBindingDerivation.EyeLook?) throws -> SourceShaderBindingSet {
            func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
            let library = try SourceMakerLibrary.load(url: makerLibrary)
            let head = try Data(contentsOf: headContract)
            let catalog = try SourceShaderProgramCatalog.load(directory: programs)
            let supplementData = try supplement.map { try Data(contentsOf: $0) }
            var provenance = ["makerLibrary": makerLibrary.path, "headContract": headContract.path, "programs": programs.path]
            if let supplement { provenance["supplement"] = supplement.path }
            var bindings = try SourceShaderBindingDerivation.derive(card: card, library: library, headContract: head, catalog: catalog,
                supplement: supplementData, scene: scene ?? .originalCharacterProbeHarness, hiPoly: hiPoly, eyeLook: eyeLook, provenance: provenance)
            if scene == nil {
                // Without a recovered scene mapping the harness constants must not
                // stand in for the scene's values: every scene global is unresolved.
                for name in ["_ambientshadowG", "_LineColorG", "_linewidthG"] { bindings.globalVectors[name] = .init(unresolved: sceneReason) }
                if var ramp = bindings.globalTextures["_RampG"] { ramp.identity = nil; ramp.identityUnresolved = sceneReason; bindings.globalTextures["_RampG"] = ramp }
                bindings.provenance["sceneGlobals"] = "unresolved: \(sceneReason)"
            }
            return bindings
        }
    }

    public let bindings: SourceShaderBindingSet
    public let textureProvider: String
    /// Binding renderer index → resolved material, or why it stays toon.
    public let materials: [Int: Result<SourceShaderLiveMaterial, SourceShaderLiveReason>]
    private let streams: [String: [SourceVertexStreams]]
    /// Renderer-level notes from the last `attach` (hidden items, fallbacks).
    public private(set) var lastAttach: AttachReport = AttachReport()

    public struct AttachReport: Sendable, Equatable {
        /// Items drawn live, as `mesh slot N (family)`.
        public var live: [String] = []
        /// Items kept toon, with the reason.
        public var fallbacks: [String] = []
        /// Items the source does not draw (renderer disabled or ShadowCaster-only).
        public var hidden: [String] = []
        /// Source renderer slots with no native item to draw them.
        public var unmatched: [String] = []
    }

    public init(bindings: SourceShaderBindingSet, programs: URL, resources: ResourceStore,
                textures: any SourceShaderLiveTextureProvider, streams: [String: [SourceVertexStreams]],
                anisotropicFiltering: String?, conventions: SourceShaderLiveConventions = .probe) {
        self.bindings = bindings; self.streams = streams; self.textureProvider = textures.label
        var materials: [Int: Result<SourceShaderLiveMaterial, SourceShaderLiveReason>] = [:]
        for (index, renderer) in bindings.renderers.enumerated() where renderer.visible {
            guard renderer.material.shader != "Shader Forge/shadowcast" else { continue }
            do {
                materials[index] = .success(try SourceShaderLiveMaterial.resolve(renderer: renderer, bindings: bindings, programs: programs,
                    resources: resources, textures: textures, anisotropicFiltering: anisotropicFiltering, conventions: conventions))
            } catch let reason as SourceShaderLiveReason { materials[index] = .failure(reason) }
            catch { materials[index] = .failure(SourceShaderLiveReason("\(error)")) }
        }
        self.materials = materials
    }

    /// Splits a native mesh name (`hair-0/cf_hair_b_03_00/0`) into the source
    /// renderer name and submesh index.
    public static func sourceMesh(_ name: String) -> (mesh: String, submesh: Int)? {
        let parts = name.split(separator: "/")
        guard parts.count >= 2, let submesh = Int(parts[parts.count - 1]), submesh >= 0 else { return nil }
        return (String(parts[parts.count - 2]), submesh)
    }

    /// Marks `frame`'s items of this character for live drawing. Items whose
    /// slot resolved get `sourceShader`; items the source does not draw are
    /// hidden; everything else keeps the native draw and is reported.
    /// `overrides` holds per-frame material values by source mesh name.
    @discardableResult
    public func attach(to frame: inout RenderFrame, resources: ResourceStore, items range: Range<Int>? = nil,
                       overrides: [String: [String: [Float]]] = [:]) -> AttachReport {
        var report = AttachReport()
        let indices = range ?? frame.items.indices
        // Native items per (source mesh, submesh): distinct vertex sources there
        // would make the slot mapping ambiguous.
        var owners: [String: Set<String>] = [:]
        var parsed: [Int: (mesh: String, submesh: Int, pass: Int)] = [:]
        var passCounter: [String: Int] = [:]
        for index in indices {
            let item = frame.items[index]
            guard item.visible, let name = resources.mesh(item.mesh)?.name, let source = Self.sourceMesh(name) else { continue }
            let owner = "\(item.mesh.id)#\(item.deformKey ?? 0)"
            owners["\(source.mesh)/\(source.submesh)", default: []].insert(owner)
            let pass = passCounter[owner, default: 0]; passCounter[owner] = pass + 1
            parsed[index] = (source.mesh, source.submesh, pass)
        }
        var used = Set<Int>()
        for index in indices.sorted() {
            guard let source = parsed[index] else { continue }
            let label = "\(source.mesh)/\(source.submesh) pass \(source.pass)"
            guard owners["\(source.mesh)/\(source.submesh)"]?.count == 1 else {
                report.fallbacks.append("\(label): several native parts share this source renderer name; mapping ambiguous"); continue
            }
            let candidates = bindings.renderers.indices.filter { bindings.renderers[$0].mesh == source.mesh && bindings.renderers[$0].submesh == source.submesh }
                .sorted { bindings.renderers[$0].materialSlot < bindings.renderers[$1].materialSlot }
            guard !candidates.isEmpty else { report.fallbacks.append("\(label): no source renderer in the binding set"); continue }
            let visible = candidates.filter { bindings.renderers[$0].visible }
            if visible.isEmpty {
                // Every source renderer of this name is disabled: the source draws nothing.
                frame.items[index].visible = false
                report.hidden.append("\(label): \(bindings.renderers[candidates[0]].visibility)"); continue
            }
            // Two enabled renderers with one name cannot be told apart natively.
            guard Set(visible.map { bindings.renderers[$0].materialSlot }).count == visible.count else {
                report.fallbacks.append("\(label): several enabled source renderers share this name; mapping ambiguous"); continue
            }
            guard visible.indices.contains(source.pass) else {
                report.fallbacks.append("\(label): the source renderer has no material slot for this native pass"); continue
            }
            let rendererIndex = visible[source.pass]
            used.insert(rendererIndex)
            let renderer = bindings.renderers[rendererIndex]
            let slotLabel = "\(renderer.mesh) slot \(renderer.materialSlot)"
            if renderer.material.shader == "Shader Forge/shadowcast" {
                frame.items[index].visible = false
                report.hidden.append("\(slotLabel): ShadowCaster-only source shader (no forward pass)"); continue
            }
            switch materials[rendererIndex] {
            case .success(let material)?:
                guard let mesh = resources.mesh(frame.items[index].mesh) else { continue }
                let candidates = (streams[renderer.mesh] ?? []).filter { $0.vertexCount == mesh.vertexCount }
                let reads = material.passes.flatMap(\.vertexInputs)
                func readsUV(_ set: Int) -> Bool { reads.contains { $0.semantic == "TEXCOORD" && $0.index == set } }
                // UV1/UV2 the converted mesh lacks would alias UV0; the source stream supplies them.
                let missingUV = [1, 2].filter { readsUV($0) && !($0 == 1 ? mesh.carriesUV1 : mesh.carriesUV2) }
                let needsStreams = readsUV(3) || reads.contains { $0.semantic == "COLOR" } || !missingUV.isEmpty
                if needsStreams && candidates.count != 1 {
                    let channels = (readsUV(3) ? ["UV3"] : []) + (reads.contains { $0.semantic == "COLOR" } ? ["COLOR"] : []) + missingUV.map { "UV\($0) (the converted mesh has none)" }
                    report.fallbacks.append("\(slotLabel) (\(material.family)): " + (candidates.isEmpty ? "no source vertex stream for this mesh (reads \(channels.joined(separator: ", ")))"
                                                                                         : "source vertex stream ambiguous (\(candidates.count) source meshes of this name and vertex count)")); continue
                }
                let stream = candidates.count == 1 ? candidates[0] : nil
                frame.items[index].sourceShader = SourceShaderLiveDraw(material: material, streams: stream,
                    vectorOverrides: overrides[renderer.mesh] ?? [:], sourceOrder: rendererIndex)
                var sources: [String] = [], conventions: [String] = []
                if needsStreams, let stream {
                    for set in missingUV {
                        if (set == 1 ? stream.uv1 : stream.uv2) != nil { sources.append("TEXCOORD\(set) from the source stream") }
                        else { conventions.append("TEXCOORD\(set) absent in the source mesh: zero") }
                    }
                    if stream.uv3 == nil && readsUV(3) { conventions.append("TEXCOORD3 absent in the source mesh: zero") }
                    if stream.colors == nil && reads.contains(where: { $0.semantic == "COLOR" }) { conventions.append("COLOR absent in the source mesh: white") }
                }
                report.live.append("\(slotLabel) (\(material.family))" + (sources.isEmpty ? "" : "; " + sources.joined(separator: ", "))
                                   + (conventions.isEmpty ? "" : "; convention (capture fixture default, Unity's missing-channel value unverified): " + conventions.joined(separator: ", ")))
            case .failure(let reason)?:
                report.fallbacks.append("\(slotLabel) (\(SourceShaderLiveMaterial.family(of: renderer.material.shader) ?? "?")): \(reason.text)")
            case nil:
                report.fallbacks.append("\(slotLabel): not resolved")
            }
        }
        for (index, renderer) in bindings.renderers.enumerated() where renderer.visible && !used.contains(index) && renderer.material.shader != "Shader Forge/shadowcast" {
            report.unmatched.append("\(renderer.mesh) slot \(renderer.materialSlot) (\(SourceShaderLiveMaterial.family(of: renderer.material.shader) ?? "?")): no native item draws this source slot")
        }
        lastAttach = report
        return report
    }

    /// Per-material resolution summary (status lines, stable order).
    public var resolution: [String] {
        bindings.renderers.indices.compactMap { index in
            let renderer = bindings.renderers[index]
            let label = "\(renderer.mesh) slot \(renderer.materialSlot) (\(SourceShaderLiveMaterial.family(of: renderer.material.shader) ?? renderer.material.shader ?? "?"))"
            switch materials[index] {
            case .success(let material)?:
                return "\(label): live" + (material.conventions.isEmpty ? "" : "; conventions: " + material.conventions.joined(separator: "; "))
            case .failure(let reason)?: return "\(label): toon — \(reason.text)"
            case nil: return renderer.visible ? "\(label): not drawn (ShadowCaster-only)" : "\(label): source renderer disabled (\(renderer.visibility))"
            }
        }
    }
}
