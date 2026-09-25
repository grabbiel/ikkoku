import Foundation
import CryptoKit
import Metal
import CoreMath
import Scene
import Renderer
import Assets
import ShaderTypes

/// Each composed texture is shared independently. A derived appearance keeps only
/// leases for handles still used by its material slots, so edits cannot retain an
/// unbounded chain of fully replaced appearances.
final class SourceAppearanceTextureLease: @unchecked Sendable {
    let resources: ResourceStore
    let handle: TextureHandle
    init(resources: ResourceStore, handle: TextureHandle) { self.resources = resources; self.handle = handle }
    deinit { resources.unregister(texture: handle) }
}

final class SourceAppearanceTextureOwner: Sendable {
    let leases: [TextureHandle: SourceAppearanceTextureLease]
    init(leases: [TextureHandle: SourceAppearanceTextureLease]) { self.leases = leases }
}

/// Explicit material/texture bindings produced by the source converter. Geometry
/// selection and identity checks are separate from scalar color composition.
public struct SourceAppearanceBindings: Codable, Sendable {
    public struct Texture: Codable, Sendable {
        public let file: String, sha256: String
        public let width: Int, height: Int
        public let wrap: String?
    }
    public struct Pattern: Codable, Sendable {
        public let selection: String, color: String, tiling: String
        public let resolverProperties: [String]
        public let textures: [String: Texture]
    }
    public struct Layer: Codable, Sendable {
        public let selection: String, color: String, kind: String
        public let layout: String?, transform: [Float]?
        public let resolverProperties: [String]
        public let textures: [String: Texture]
        public let mask: Texture?
    }
    public struct Entry: Codable, Sendable {
        public let parts: [String]
        public let pass: Int
        public let kind: String
        public let colors: [String]
        public let requirements: [String: Int]
        public let resolverProperties: [String]
        public let main: Texture?, mask: Texture?
        public let blend: String?
        public let patterns: [Pattern]?, layers: [Layer]?
    }
    public let schemaVersion: Int
    public let entries: [Entry]
    public let limitations: [String]

    public func restricted(to parts: Set<String>) -> Self {
        Self(schemaVersion: schemaVersion, entries: entries.filter { Set($0.parts).isSubset(of: parts) }, limitations: limitations)
    }

    /// Catalog accessory entries use slot zero; the scene assembly supplies the
    /// actual slot without changing the original card or its resolver records.
    public func contextualized(accessorySlot: Int) throws -> Self {
        guard (0..<128).contains(accessorySlot) else { throw RigError.invalid("Invalid accessory slot.") }
        func rewrite(_ value: Any) -> Any {
            if let string = value as? String {
                if string.hasPrefix("accessory.parts.0.") { return "accessory.parts.\(accessorySlot)." + string.dropFirst("accessory.parts.0.".count) }
                return string.replacingOccurrences(of: "accessory0.", with: "accessory\(accessorySlot).")
            }
            if let array = value as? [Any] { return array.map(rewrite) }
            if let map = value as? [String: Any] { return Dictionary(uniqueKeysWithValues: map.map { (rewrite($0.key) as! String, rewrite($0.value)) }) }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: rewrite(object)))
    }

    public static func load(url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw RigError.invalid("Appearance binding manifest exceeds 1 MiB.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.entries.count <= 256 else { throw RigError.invalid("Unsupported appearance binding manifest.") }
        return value
    }
}

public extension SourcePreviewAppearance {
    struct CardApplication: Sendable {
        public let appearance: SourcePreviewAppearance
        public let appliedFields: Set<String>
        public let diagnostics: [String]
    }

    func applying(_ card: SourceCardAppearance, bindings: SourceAppearanceBindings, directory: URL,
                  resources: ResourceStore) throws -> CardApplication {
        var materials = self.materials, applied = Set<String>(), diagnostics = card.diagnostics + bindings.limitations
        var leases = textureOwner?.leases ?? [:]
        // Count every prospective output, including repeated recipes over one cached
        // source texture. Preflight before reading pixels or allocating Metal textures.
        var totalOutputBytes = 0
        for entry in bindings.entries where SourceColorComposition.Kind(rawValue: entry.kind) != nil {
            guard let texture = entry.main ?? entry.mask else { continue }
            let width = texture.width, height = texture.height
            guard (1...4096).contains(width), (1...4096).contains(height), width * height <= 4_194_304 else {
                throw RigError.invalid("Invalid bounded appearance output dimensions.")
            }
            totalOutputBytes += width * height * 4
            guard totalOutputBytes <= 128 * 1024 * 1024 else {
                throw RigError.invalid("Composed appearance outputs exceed 128 MiB.")
            }
        }
        let directory = directory.resolvingSymlinksInPath()
        var bytesByPath: [String: [UInt8]] = [:], totalBytes = 0
        func pixels(_ input: SourceAppearanceBindings.Texture) throws -> [UInt8] {
            guard (1...4096).contains(input.width), (1...4096).contains(input.height),
                  input.width * input.height <= 4_194_304, !input.file.isEmpty, !input.file.hasPrefix("/") else {
                throw RigError.invalid("Invalid bounded appearance texture.")
            }
            let url = directory.appendingPathComponent(input.file).resolvingSymlinksInPath()
            guard url.path.hasPrefix(directory.path + "/") else { throw RigError.invalid("Appearance texture escapes its directory.") }
            let expected = input.width * input.height * 4
            if let cached = bytesByPath[url.path] {
                guard cached.count == expected, SHA256.hash(data: Data(cached)).map({ String(format: "%02x", $0) }).joined() == input.sha256 else {
                    throw RigError.invalid("Conflicting appearance texture metadata.")
                }
                return cached
            }
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let data = try file.read(upToCount: expected + 1) ?? Data()
            totalBytes += data.count
            guard totalBytes <= 128 * 1024 * 1024, data.count == expected,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == input.sha256 else {
                throw RigError.invalid("Appearance texture has changed or exceeds its size limit.")
            }
            let result = [UInt8](data); bytesByPath[url.path] = result; return result
        }
        func linear(_ color: Float4) -> Float4 {
            Float4((0..<4).map { i in i == 3 ? color[i] : color[i] <= 0.04045 ? color[i] / 12.92 : pow((color[i] + 0.055) / 1.055, 2.4) })
        }
        func vector(_ path: String, count: Int) -> [Float]? {
            guard let values = card.value(path)?.arrayValue, values.count == count else { return nil }
            let numbers = (0..<count).compactMap { card.number(path + "." + String($0)) }
            return numbers.count == count && numbers.allSatisfy({ (0...1).contains($0) }) ? numbers : nil
        }
        func isModded(_ properties: [String]) -> Bool {
            properties.contains { card.modProperties.contains($0.replacingOccurrences(of: "{coordinate}", with: String(card.coordinate))) }
        }
        func sampled(_ bytes: [UInt8], _ meta: SourceAppearanceBindings.Texture, uv: Float2) -> Float4 {
            // Converted source pixels are upright; Unity texture UVs are bottom-up.
            let point = Float2(uv.x * Float(meta.width) - 0.5, (1 - uv.y) * Float(meta.height) - 0.5)
            let x = Int(floor(point.x)), y = Int(floor(point.y))
            let fraction = point - Float2(Float(x), Float(y))
            func axis(_ n: Int, _ count: Int) -> Int {
                meta.wrap == "repeat" ? ((n % count) + count) % count : min(max(n, 0), count - 1)
            }
            func texel(_ x: Int, _ y: Int) -> Float4 {
                let i = (axis(y, meta.height) * meta.width + axis(x, meta.width)) * 4
                return Float4(Float(bytes[i]), Float(bytes[i+1]), Float(bytes[i+2]), Float(bytes[i+3])) / 255
            }
            let top = texel(x,y) + fraction.x * (texel(x+1,y) - texel(x,y))
            let bottom = texel(x,y+1) + fraction.x * (texel(x+1,y+1) - texel(x,y+1))
            return top + fraction.y * (bottom - top)
        }
        for entry in bindings.entries {
            guard !entry.parts.isEmpty, entry.parts.count <= 64, (0..<16).contains(entry.pass),
                  entry.colors.count <= 3, entry.requirements.count <= 64, entry.resolverProperties.count <= 64,
                  (entry.patterns?.count ?? 0) <= 3, (entry.layers?.count ?? 0) <= 8 else {
                throw RigError.invalid("Invalid appearance material binding.")
            }
            let unsupported = entry.requirements.filter { card.value($0.key)?.integerValue != $0.value }.keys.sorted()
            let modded = entry.resolverProperties.map { $0.replacingOccurrences(of: "{coordinate}", with: String(card.coordinate)) }
                .filter { card.modProperties.contains($0) }
            guard unsupported.isEmpty && modded.isEmpty else {
                diagnostics.append("\(entry.parts.joined(separator: ", ")) kept reference material; unmatched selections: \((unsupported + modded).joined(separator: ", ")).")
                continue
            }
            let colors = entry.colors.compactMap { card.color($0) }
            guard colors.count == entry.colors.count else {
                diagnostics.append("\(entry.parts.joined(separator: ", ")) kept reference material because color fields are missing or unsupported."); continue
            }
            for part in entry.parts {
                guard let surfaces = materials[part], surfaces.indices.contains(entry.pass) else { throw RigError.invalid("Appearance binding targets an absent material: \(part).") }
            }
            var texture: TextureHandle?
            if let kind = SourceColorComposition.Kind(rawValue: entry.kind) {
                guard let dimensions = entry.main ?? entry.mask else { throw RigError.invalid("A texture recipe needs source pixels.") }
                let main = try entry.main.map(pixels), mask = try entry.mask.map(pixels)
                let blend: Float
                if let path = entry.blend {
                    guard let value = card.number(path), (0...1).contains(value) else { diagnostics.append("Skipped \(entry.parts): invalid \(path)."); continue }
                    blend = value
                } else { blend = 0 }
                _ = try SourceColorComposition.sample(kind: kind, main: .one, mask: .zero, colors: colors, blend: blend)
                var patterns: [(Int, SourceAppearanceBindings.Texture, [UInt8], Float4, Float2)] = []
                if let definitions = entry.patterns {
                    guard kind == .clothes, definitions.count == 3 else { throw RigError.invalid("Pattern recipes require three clothes channels.") }
                    for (index, pattern) in definitions.enumerated() {
                        guard pattern.textures.count <= 512, pattern.resolverProperties.count <= 8 else { throw RigError.invalid("Invalid pattern catalog bound.") }
                        guard !isModded(pattern.resolverProperties), let id = card.value(pattern.selection)?.integerValue else {
                            diagnostics.append("Skipped unresolved or modded pattern: \(pattern.selection)."); continue
                        }
                        if id == 0 { continue }
                        guard let meta = pattern.textures[String(id)], let color = card.color(pattern.color),
                              let scale = vector(pattern.tiling, count: 2) else {
                            diagnostics.append("Skipped unavailable pattern or parameters: \(pattern.selection)=\(id)."); continue
                        }
                        guard meta.wrap == "repeat" || meta.wrap == "clamp" else { throw RigError.invalid("Unsupported source pattern wrapping.") }
                        patterns.append((index, meta, try pixels(meta), color, Float2(scale)))
                        applied.insert(pattern.color)
                    }
                }
                var layers: [(SourceAppearanceBindings.Layer, SourceAppearanceBindings.Texture, [UInt8], Float4, Float4?, [UInt8]?)] = []
                if let definitions = entry.layers {
                    guard kind == .head else { throw RigError.invalid("Face layers require the recovered head composition.") }
                    for layer in definitions {
                        guard ["cheek", "lipline", "paint", "mole"].contains(layer.kind), layer.textures.count <= 512,
                              layer.resolverProperties.count <= 8 else { throw RigError.invalid("Invalid face layer recipe.") }
                        guard !isModded(layer.resolverProperties), let id = card.value(layer.selection)?.integerValue else {
                            diagnostics.append("Skipped unresolved or modded face layer: \(layer.selection)."); continue
                        }
                        if id == 0 { continue }
                        guard let meta = layer.textures[String(id)], let color = card.color(layer.color) else {
                            diagnostics.append("Skipped unavailable face layer: \(layer.selection)=\(id)."); continue
                        }
                        var layout: Float4?
                        if let path = layer.layout {
                            guard let values = vector(path, count: 4) else { diagnostics.append("Skipped invalid face layout: \(path)."); continue }
                            layout = Float4(values)
                        }
                        guard meta.wrap == "repeat" || meta.wrap == "clamp",
                              layer.transform == nil || (layer.transform!.count == 4 && layer.transform!.allSatisfy({ $0.isFinite && abs($0) <= 100 })),
                              !["paint", "mole"].contains(layer.kind) || layout != nil else {
                            throw RigError.invalid("Unsupported source face layer sampling.")
                        }
                        if layer.kind == "paint" && layer.mask == nil { throw RigError.invalid("Face paint requires its source mask.") }
                        layers.append((layer, meta, try pixels(meta), color, layout, try layer.mask.map(pixels)))
                        applied.insert(layer.color)
                    }
                }
                let count = dimensions.width * dimensions.height
                var output = [UInt8](repeating: 0, count: count * 4)
                for pixel in 0..<count {
                    let offset = pixel * 4
                    func sample(_ bytes: [UInt8]?, fallback: Float4) -> Float4 {
                        guard let bytes else { return fallback }
                        return Float4(Float(bytes[offset]), Float(bytes[offset + 1]), Float(bytes[offset + 2]), Float(bytes[offset + 3])) / 255
                    }
                    let uv = Float2((Float(pixel % dimensions.width) + 0.5) / Float(dimensions.width),
                                    1 - (Float(pixel / dimensions.width) + 0.5) / Float(dimensions.height))
                    var effectiveColors = colors
                    for (index, meta, bytes, patternColor, tiling) in patterns {
                        let patternUV = uv * (Float2(repeating: 20) - 19 * tiling)
                        effectiveColors[index] = SourceColorComposition.patternColor(base: colors[index], pattern: patternColor,
                            red: sampled(bytes, meta, uv: patternUV).x)
                    }
                    var result = SourceColorComposition.compose(kind: kind, main: sample(main, fallback: .one),
                        mask: (entry.mask != nil && mask != nil && (entry.mask!.width != dimensions.width || entry.mask!.height != dimensions.height))
                            ? sampled(mask!, entry.mask!, uv: uv) : sample(mask, fallback: .zero), colors: effectiveColors, blend: blend)
                    for (layer, meta, bytes, color, layout, maskBytes) in layers {
                        var layerUV = uv
                        if let layout { layerUV = SourceColorComposition.faceUV(uv, layout: layout, kind: layer.kind) }
                        else if let transform = layer.transform {
                            layerUV = (uv + Float2(transform[0], transform[1]) - Float2(repeating: 1)) * (Float2(repeating: 1) - Float2(transform[2], transform[3])) + Float2(repeating: 0.5)
                        }
                        let attenuation: Float
                        if let maskBytes, let mask = layer.mask { attenuation = sampled(maskBytes, mask, uv: uv).x }
                        else { attenuation = 1 }
                        result = SourceColorComposition.layer(base: result, texture: sampled(bytes, meta, uv: layerUV), color: color, mask: attenuation)
                    }
                    for channel in 0..<4 { output[offset + channel] = UInt8((min(max(result[channel], 0), 1) * 255).rounded(.toNearestOrEven)) }
                }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
                    width: dimensions.width, height: dimensions.height, mipmapped: false)
                descriptor.usage = .shaderRead; descriptor.storageMode = .shared
                guard let gpu = resources.device.makeTexture(descriptor: descriptor) else { throw ResourceError.bufferAllocation }
                output.withUnsafeBytes { gpu.replace(region: MTLRegionMake2D(0, 0, dimensions.width, dimensions.height), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: dimensions.width * 4) }
                let handle = resources.register(texture: gpu)
                texture = handle
                leases[handle] = SourceAppearanceTextureLease(resources: resources, handle: handle)
            } else if !["tint", "highlightUpper", "highlightLower"].contains(entry.kind) || colors.count != 1 {
                throw RigError.invalid("Unsupported appearance recipe \(entry.kind).")
            }
            for part in entry.parts {
                var material = materials[part]![entry.pass]
                if let texture {
                    material.base = texture; material.uniforms.baseColor = .one
                    material.setFlag(MaterialFlagHasBaseTexture, true)
                } else if entry.kind == "highlightUpper" { material.uniforms.overlayColor0 = linear(colors[0]) }
                else if entry.kind == "highlightLower" { material.uniforms.overlayColor1 = linear(colors[0]) }
                else { material.uniforms.baseColor = linear(colors[0]) }
                materials[part]![entry.pass] = material
            }
            applied.formUnion(entry.colors)
        }
        let usedHandles = Set(materials.values.flatMap { $0 }.flatMap(\.textureHandles))
        let owner = SourceAppearanceTextureOwner(leases: leases.filter { usedHandles.contains($0.key) })
        return CardApplication(appearance: Self(materials: materials, textureOwner: owner), appliedFields: applied, diagnostics: diagnostics)
    }
}
