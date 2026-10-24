import Foundation
import CryptoKit
import simd
import CoreMath
import Renderer
import ShaderTypes
import Scene
import Assets

/// Opt-in diagnostics for one synchronous candidate. These leaf intervals do
/// not overlap; component/body-mask loads include their texture creation, while
/// compose includes encoding and the existing synchronous GPU completion wait.
public final class SourceAppearanceTimings {
    public enum Phase: String { case bindingPreparation, pixelReadHash, pipelineCreation, composeEncodeWait, componentLoad, bodyMaskLoad }
    public struct Sample: Encodable {
        public let milliseconds: [String: Double]
        public let calls: [String: Int]
    }
    private var milliseconds: [String: Double] = [:]
    private var calls: [String: Int] = [:]
    public init() {}
    public var sample: Sample { Sample(milliseconds: milliseconds, calls: calls) }

    public static func measure<T>(_ timings: SourceAppearanceTimings?, _ phase: Phase,
                                  _ body: () throws -> T) rethrows -> T {
        guard let timings else { return try body() }
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            timings.milliseconds[phase.rawValue, default: 0] += (ProcessInfo.processInfo.systemUptime - start) * 1000
            timings.calls[phase.rawValue, default: 0] += 1
        }
        return try body()
    }
}

/// A synchronous candidate's new base textures stay private until commit. Cache
/// hits are never owned here. Abandoned loads release their own handles through
/// leases, including partial loads; appearances retain any unpublished handles
/// they use if another consumer publishes the same key before commit.
public final class SourceAppearanceLoadTransaction {
    fileprivate let resources: ResourceStore
    private var created: [String: SourceAppearanceTextureLease] = [:]
    private var committed = false

    public init(resources: ResourceStore) { self.resources = resources }

    fileprivate func texture(data: Data, key: String, srgb: Bool) throws -> TextureHandle {
        precondition(!committed, "Appearance transaction is already committed.")
        let fullKey = "\(key)#\(srgb)"
        if let lease = created[fullKey] { return lease.handle }
        return try resources.texture(data: data, key: key, srgb: srgb, cacheNew: false) { handle in
            self.created[fullKey] = SourceAppearanceTextureLease(resources: self.resources, handle: handle)
        }
    }

    fileprivate func owner(for materials: [String: [MaterialState]]) -> SourceAppearanceTextureOwner {
        let used = Set(materials.values.flatMap { $0 }.flatMap(\.textureHandles))
        let leases = created.values.filter { used.contains($0.handle) }
        return SourceAppearanceTextureOwner(leases: Dictionary(uniqueKeysWithValues: leases.map { ($0.handle, $0) }))
    }

    /// Call only after candidate validation, alongside the final non-suspending
    /// state replacement. A collision keeps the candidate's appearance lease;
    /// it never overwrites or releases the already-published shared texture.
    public func commit() {
        precondition(!committed, "Appearance transaction is already committed.")
        for (key, lease) in created where resources.cacheTextureIfAbsent(lease.handle, key: key) {
            lease.transferToCache()
        }
        created.removeAll()
        committed = true
    }
}

/// Explicit appearance choices for the imported-model preview. This maps recovered
/// texture inputs to the native toon shader; it does not claim source shader parity.
public struct SourcePreviewAppearance: Sendable {
    /// Ordered material slots. Source renderers can draw the same submesh twice.
    public let materials: [String: [MaterialState]]
    let textureOwner: SourceAppearanceTextureOwner?

    /// Component-local mesh names become slot-local without changing source node
    /// or catalog identities. Shared body coverage materials keep their names.
    public func renaming(_ names: Set<String>, prefix: String) -> Self {
        Self(materials: Dictionary(uniqueKeysWithValues: materials.map {
            (names.contains($0.key) ? prefix + $0.key : $0.key, $0.value)
        }), textureOwner: textureOwner)
    }

    public func merging(_ other: Self) -> Self {
        let merged = materials.merging(other.materials) { _, replacement in replacement }
        let handles = Set(merged.values.flatMap { $0 }.flatMap(\.textureHandles))
        let leases = (textureOwner?.leases ?? [:]).merging(other.textureOwner?.leases ?? [:]) { _, replacement in replacement }
        return Self(materials: merged, textureOwner: SourceAppearanceTextureOwner(leases: leases.filter { handles.contains($0.key) }))
    }

    public func replacingBodyMask(data: Data, resources: ResourceStore) throws -> Self {
        guard var body = materials["o_body_a/0"] else { throw RigError.invalid("Body coverage material is missing.") }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let mask = try resources.texture(data: data, key: "maker-body-mask:" + key + ":" + UUID().uuidString, srgb: false)
        for i in body.indices {
            body[i].bodyMask = mask
            body[i].uniforms.sourceAlphaA = 1; body[i].uniforms.sourceAlphaB = 1
            body[i].setFlag(MaterialFlagHasBodyMask, true)
            body[i].setFlag(MaterialFlagSourceBodyMask, true)
        }
        var result = materials; result["o_body_a/0"] = body
        var leases = textureOwner?.leases ?? [:]
        leases[mask] = SourceAppearanceTextureLease(resources: resources, handle: mask)
        let used = Set(result.values.flatMap { $0 }.flatMap(\.textureHandles))
        return Self(materials: result, textureOwner: SourceAppearanceTextureOwner(leases: leases.filter { used.contains($0.key) }))
    }

    public func removingBodyMask() -> Self {
        var result = materials
        if var body = result["o_body_a/0"] {
            for i in body.indices {
                body[i].bodyMask = nil
                body[i].setFlag(MaterialFlagHasBodyMask, false)
                body[i].setFlag(MaterialFlagSourceBodyMask, false)
            }
            result["o_body_a/0"] = body
        }
        let used = Set(result.values.flatMap { $0 }.flatMap(\.textureHandles))
        return Self(materials: result, textureOwner: SourceAppearanceTextureOwner(leases: (textureOwner?.leases ?? [:]).filter { used.contains($0.key) }))
    }

    public static func load(url: URL, resources: ResourceStore, modLibrary: SourceModLibrary? = nil,
                            transaction: SourceAppearanceLoadTransaction? = nil) throws -> Self {
        guard transaction == nil || transaction?.resources === resources else {
            throw RigError.invalid("Appearance transaction belongs to a different resource store.")
        }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1 else { throw RigError.invalid("Unsupported preview appearance schema.") }
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        func contained(_ path: String) throws -> URL {
            let file = directory.appendingPathComponent(path).resolvingSymlinksInPath()
            guard !path.isEmpty, !path.hasPrefix("/"), file.path.hasPrefix(directory.path + "/") else {
                throw RigError.invalid("Preview resources must remain inside their appearance folder.")
            }
            return file
        }
        let mods: SourceModLibrary
        if let modLibrary { mods = modLibrary }
        else {
            mods = try SourceModLibrary(packages: (document.modPackages ?? []).map {
                try SourceModPackage.load(url: contained($0))
            })
        }
        // Explicit source identities bind converted textures to known native shader
        // inputs. Material, shader and catalog conversion remain separate adapters.
        func loadTexture(_ data: Data, key: String, srgb: Bool) throws -> TextureHandle {
            if let transaction { return try transaction.texture(data: data, key: key, srgb: srgb) }
            return try resources.texture(data: data, key: key, srgb: srgb)
        }
        func texture(_ path: String?, srgb: Bool = true) throws -> TextureHandle? {
            guard let path else { return nil }
            if let binding = document.textureBindings?[path] {
                guard let resolved = try mods.texture(bundlePath: binding.bundlePath, assetName: binding.assetName) else {
                    throw RigError.invalid("No mounted mod provides '\(binding.bundlePath)' / '\(binding.assetName)'.")
                }
                return try loadTexture(resolved.data, key: resolved.cacheKey + "#\(srgb)", srgb: srgb)
            }
            let file = try contained(path)
            return try loadTexture(Data(contentsOf: file), key: file.path + "#\(srgb)", srgb: srgb)
        }
        var materials: [String: [MaterialState]] = [:]
        for entry in document.parts {
            guard !entry.part.isEmpty, (entry.pass ?? 0) == (materials[entry.part]?.count ?? 0), entry.color.count == 4,
                  entry.color.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  ["OPAQUE", "MASK", "BLEND"].contains(entry.alphaMode) else {
                throw RigError.invalid("Invalid or duplicate preview material '\(entry.part)'.")
            }
            let kind: MaterialKind
            switch entry.kind {
            case "skin": kind = MaterialKindSkin
            case "hair": kind = MaterialKindHair
            case "cloth": kind = MaterialKindCloth
            case "unlit": kind = MaterialKindUnlit
            case "item": kind = MaterialKindItem
            default: throw RigError.invalid("Unsupported preview material kind '\(entry.kind)'.")
            }
            var material = MaterialState(uniforms: .make(kind: kind))
            material.uniforms.baseColor = Float4(entry.color)
            for value in [entry.specularStrength, entry.rimStrength].compactMap({ $0 }) {
                guard value.isFinite, (0...1).contains(value) else { throw RigError.invalid("Preview lighting strengths must be in 0...1.") }
            }
            if let value = entry.specularStrength { material.uniforms.params.y = value }
            if let value = entry.rimStrength {
                material.uniforms.rim.x *= value
                material.uniforms.rim.y *= value
                material.uniforms.rim.z *= value
            }
            material.uniforms.outline.w = entry.outline == false ? 0 : 0.8
            material.base = try texture(entry.texture)
            material.bodyMask = try texture(entry.bodyMask, srgb: false)
            if let highlights = entry.irisHighlights {
                guard highlights.colors.count == 2, highlights.colors.allSatisfy({ $0.count == 4 && $0.allSatisfy({ $0.isFinite && (0...1).contains($0) }) }),
                      highlights.strength.isFinite, (0...1).contains(highlights.strength) else {
                    throw RigError.invalid("Source iris highlights require two colors and a normalized strength.")
                }
                material.overlay0 = try texture(highlights.upper)
                material.overlay1 = try texture(highlights.lower)
                material.setFlag(MaterialFlagHasOverlay0, material.overlay0 != nil)
                material.setFlag(MaterialFlagHasOverlay1, material.overlay1 != nil)
                material.uniforms.overlayColor0 = Float4(highlights.colors[0])
                material.uniforms.overlayColor1 = Float4(highlights.colors[1])
                material.uniforms.eye.w = highlights.strength
                material.setFlag(MaterialFlagSourceIrisHighlights, true)
            }
            if let alpha = entry.sourceBodyAlpha {
                guard material.bodyMask != nil, alpha.count == 2,
                      alpha.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw RigError.invalid("Source body coverage requires a mask and two normalized alpha values.")
                }
                material.uniforms.sourceAlphaA = alpha[0]
                material.uniforms.sourceAlphaB = alpha[1]
                material.setFlag(MaterialFlagSourceBodyMask, true)
            }
            material.setFlag(MaterialFlagHasBaseTexture, material.base != nil)
            material.setFlag(MaterialFlagHasBodyMask, material.bodyMask != nil)
            material.setFlag(MaterialFlagDoubleSided, entry.doubleSided ?? false)
            material.setFlag(MaterialFlagNoOutline, entry.outline == false)
            material.setFlag(MaterialFlagAlphaTest, entry.alphaMode == "MASK")
            material.transparent = entry.alphaMode == "BLEND"
            materials[entry.part, default: []].append(material)
        }
        return Self(materials: materials, textureOwner: transaction?.owner(for: materials))
    }

    private struct Document: Decodable {
        let schemaVersion: Int, parts: [Entry]
        let modPackages: [String]?, textureBindings: [String: TextureBinding]?
    }
    private struct TextureBinding: Decodable { let bundlePath: String, assetName: String }
    private struct Entry: Decodable {
        let part: String, kind: String, color: [Float], alphaMode: String
        let texture: String?, bodyMask: String?, doubleSided: Bool?, outline: Bool?
        let sourceBodyAlpha: [Float]?
        let pass: Int?
        let specularStrength: Float?, rimStrength: Float?
        let irisHighlights: IrisHighlights?
    }
    private struct IrisHighlights: Decodable {
        let upper: String, lower: String, colors: [[Float]], strength: Float
    }
}
