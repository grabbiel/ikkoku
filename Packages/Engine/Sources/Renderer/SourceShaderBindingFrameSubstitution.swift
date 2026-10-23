import Foundation

/// Proof of concept for R1/CMT-04: rewrites an original-player frame
/// description (`frame.json`) so that `TranslatedSourceShaderProbe` binds the
/// native `SourceShaderBindingSet` values instead of the captured ones.
///
/// Only binding values change: material vectors, texture scale/offset, render
/// queue, sampler state of texture rows and global vectors are replaced by the
/// native value wherever it is resolved; a texture slot the native recipe
/// leaves empty is removed so the probe binds the Unity default. Geometry,
/// camera, light and texture pixels stay the capture's — an asset texture is
/// kept only when its native identity matches the captured texture, and a
/// runtime composite keeps the captured render-target content. Every input
/// the native data cannot supply keeps the captured value and is counted by
/// reason in the report, so a run on the result shows what native bindings
/// change, not a mixture presented as native.
public enum SourceShaderBindingFrameSubstitution {
    public struct Report: Codable, Sendable, Equatable {
        public var scope: String
        /// Category → inputs whose bound value now comes from the native set.
        public var substituted: [String: Int]
        /// Reason → inputs that keep the captured value.
        public var keptCapture: [String: Int]
        /// Substituted inputs whose float32 value differs from the capture's.
        public var changedValues: Int
    }

    public enum SubstitutionError: Error, CustomStringConvertible, Equatable {
        case invalid(String)
        public var description: String { switch self { case .invalid(let message): message } }
    }

    public static func substitute(bindings: SourceShaderBindingSet, frame data: Data, catalog: SourceShaderProgramCatalog) throws -> (frame: Data, report: Report) {
        typealias Row = [String: Any]
        guard var frame = try JSONSerialization.jsonObject(with: data) as? Row, var meshes = frame["meshes"] as? [Row],
              var textureRows = frame["textures"] as? [Row] else { throw SubstitutionError.invalid("Capture frame lacks meshes or textures") }
        var report = Report(scope: "Translated-probe frame whose binding values come from the native shader binding set where resolved; "
                                + "geometry, camera, light and texture pixels are the capture's.", substituted: [:], keptCapture: [:], changedValues: 0)
        func keep(_ reason: String) { report.keptCapture[reason, default: 0] += 1 }
        func use(_ category: String, changed: Bool) { report.substituted[category, default: 0] += 1; if changed { report.changedValues += 1 } }
        func floats(_ value: Any?) -> [Float]? {
            if let number = value as? NSNumber { return [number.floatValue] }
            return (value as? [NSNumber])?.map(\.floatValue)
        }
        var rowIndex: [String: Int] = [:]
        for (index, row) in textureRows.enumerated() { if let file = row["file"] as? String { rowIndex[file] = index } }
        var samplerFiles = Set<String>()
        /// Applies a native identity's sampler state to the captured texture row.
        func applySampler(file: String, identity: SourceShaderBindingSet.TextureIdentity) {
            guard let index = rowIndex[file], samplerFiles.insert(file).inserted else { return }
            guard let filter = identity.filter, let wrap = identity.wrap, let aniso = identity.aniso else { keep("sampler state not derived"); return }
            let row = textureRows[index]
            let changed = row["filter"] as? String != filter || row["wrap"] as? String != wrap || (row["aniso"] as? NSNumber)?.intValue != aniso
            textureRows[index]["filter"] = filter; textureRows[index]["wrap"] = wrap; textureRows[index]["aniso"] = aniso
            use("sampler", changed: changed)
        }
        func matches(_ identity: SourceShaderBindingSet.TextureIdentity, _ row: Row) -> Bool {
            let type = identity.kind == .asset ? "Texture2D" : "RenderTexture"
            guard row["textureType"] as? String == type else { return false }
            if identity.kind == .asset, identity.name != row["name"] as? String { return false }
            if let width = identity.width, (row["width"] as? NSNumber)?.intValue != width { return false }
            if let height = identity.height, (row["height"] as? NSNumber)?.intValue != height { return false }
            return true
        }

        var matched = Set<Int>()
        for meshIndex in meshes.indices {
            guard let name = meshes[meshIndex]["name"] as? String, var materials = meshes[meshIndex]["materials"] as? [Row] else {
                throw SubstitutionError.invalid("Capture mesh \(meshIndex) lacks a name or materials")
            }
            // Every slot is drawn: one beyond the submesh count goes over the
            // last submesh (Unity's extra-material rule, which the probe follows).
            for slot in materials.indices {
                guard let shader = materials[slot]["shader"] as? String, shader != "Shader Forge/shadowcast" else { continue }
                let candidates = bindings.renderers.indices.filter { !matched.contains($0) && bindings.renderers[$0].mesh == name && bindings.renderers[$0].materialSlot == slot }
                guard let index = candidates.first(where: { bindings.renderers[$0].visible }) ?? candidates.first else { keep("no native renderer"); continue }
                matched.insert(index)
                let material = bindings.renderers[index].material
                guard material.shader == shader else { keep("native shader differs or is unknown"); continue }
                if let queue = material.queue {
                    use("queue", changed: (materials[slot]["queue"] as? NSNumber)?.intValue != queue); materials[slot]["queue"] = queue
                } else { keep("render queue not derived") }
                var properties = materials[slot]["properties"] as? Row ?? [:]
                let declared = catalog.properties(for: shader)
                for input in catalog.inputs(for: shader) {
                    switch input.source {
                    case .builtin, .globalVector, .globalTexture:
                        continue
                    case .materialVector:
                        guard let values = material.vectors[input.name]?.values, !values.isEmpty else {
                            keep(material.vectors[input.name]?.unresolved ?? material.unresolved ?? "vector not derived"); continue
                        }
                        let previous = floats(properties[input.name]) ?? declared[input.name]?.defaultValue
                        let scalar = properties[input.name] is NSNumber || (properties[input.name] == nil && (declared[input.name]?.type ?? 2) >= 2)
                        let lanes = max(1, input.dimension)
                        let changed = previous.map { old in (0..<min(lanes, values.count, old.count)).contains { values[$0] != old[$0] } } ?? true
                        properties[input.name] = scalar ? values[0] as Any : values as Any
                        use("vector", changed: changed)
                    case .materialTextureTransform:
                        let base = String(input.name.dropLast(3))
                        guard let texture = material.textures[base], let scale = texture.scale, let offset = texture.offset else {
                            keep(material.textures[base]?.transformUnresolved ?? material.unresolved ?? "texture transform not derived"); continue
                        }
                        // The probe reads `_ST` from the bound texture entry; an
                        // unbound slot samples a constant default texture.
                        guard var entry = properties[base] as? Row else { continue }
                        let changed = floats(entry["scale"]) != scale || floats(entry["offset"]) != offset
                        entry["scale"] = scale; entry["offset"] = offset; properties[base] = entry
                        use("textureTransform", changed: changed)
                    case .materialTexture:
                        guard let texture = material.textures[input.name], texture.identityUnresolved == nil else {
                            keep(material.textures[input.name]?.identityUnresolved ?? material.unresolved ?? "texture not derived"); continue
                        }
                        let entry = properties[input.name] as? Row
                        guard let identity = texture.identity else {
                            if entry != nil { properties[input.name] = nil; use("texture", changed: true) } else { use("texture", changed: false) }
                            continue
                        }
                        guard let file = entry?["file"] as? String, let row = rowIndex[file].map({ textureRows[$0] }), matches(identity, row) else {
                            keep("native texture pixels are not available to the probe (identity differs from the capture)"); continue
                        }
                        use(identity.kind == .asset ? "texture" : "runtimeCompositeTexture (captured content)", changed: false)
                        applySampler(file: file, identity: identity)
                    }
                }
                materials[slot]["properties"] = properties
            }
            meshes[meshIndex]["materials"] = materials
        }
        var globals = frame["globals"] as? Row ?? [:]
        var seen = Set<String>()
        for renderer in bindings.renderers where renderer.visible {
            guard let shader = renderer.material.shader else { continue }
            for input in catalog.inputs(for: shader) where (input.source == .globalVector || input.source == .globalTexture) && seen.insert(input.name).inserted {
                if input.source == .globalVector {
                    guard let values = bindings.globalVectors[input.name]?.values else { keep(bindings.globalVectors[input.name]?.unresolved ?? "global not derived"); continue }
                    // The probe reads globals before any `_ST` convention, so an
                    // unrecorded global keeps the probe's own default.
                    guard let previous = globals[input.name] else { keep("global absent from the capture (probe default kept)"); continue }
                    let scalar = previous is NSNumber
                    use("globalVector", changed: floats(previous).map { old in (0..<min(old.count, values.count)).contains { values[$0] != old[$0] } } ?? true)
                    globals[input.name] = scalar ? values[0] as Any : values as Any
                } else {
                    guard let identity = bindings.globalTextures[input.name]?.identity, let file = globals[input.name] as? String,
                          let row = rowIndex[file].map({ textureRows[$0] }), matches(identity, row) else {
                        keep(bindings.globalTextures[input.name]?.identityUnresolved ?? "native global texture is not the captured one"); continue
                    }
                    use("globalTexture", changed: false)
                    applySampler(file: file, identity: identity)
                }
            }
        }
        frame["meshes"] = meshes; frame["textures"] = textureRows; frame["globals"] = globals
        frame["nativeBindingSubstitution"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
        return (try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]), report)
    }
}
