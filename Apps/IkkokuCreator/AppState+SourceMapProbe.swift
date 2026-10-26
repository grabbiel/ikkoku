import Foundation
import simd
import CoreMath
import Renderer
import Studio
import Scene
import ShaderTypes

extension AppState {
    /// The Unity depth-normals far plane both sides encode with: the original
    /// probe (`Tools/reverse/fixtures/OriginalMapProbe.cs`, `DepthFar33` /
    /// `DepthFar34`, `UseMap`) renders its depth pass with the same far plane,
    /// so equal encodings mean equal metres. Map 34's outside geometry reaches
    /// about 800 m through its windows, and the other maps' outdoor geometry
    /// further: 25 m (map 33's small room) would clip it on the original side only.
    static func sourceMapProbeDepthFar(map: Int) -> Float { map == 33 ? 25 : 1000 }

    /// The map-only passes compare the map's solid draws, as the original probe
    /// does (its renderers whose materials are all `RenderType=Opaque`, the tag
    /// Unity's depth-normals replacement selects by): item and lightmapped draws
    /// without alpha test or blending. Sky, particle, cutout and blended draws
    /// are counted, not drawn.
    static func isSolidSourceMapDraw(_ item: RenderItem) -> Bool {
        let draw = SourceStudioMapAsset.Draw(item.material)
        let alpha = MaterialFlagAlphaTest.rawValue | MaterialFlagAlphaBlend.rawValue
        return (draw == .item || draw == .lightmapped) && !item.material.transparent && item.material.uniforms.flags & alpha == 0
    }

    /// ST-A11 evidence, `IKKOKU_SOURCE_MAP_PROBE=<directory>` with
    /// `IKKOKU_SOURCE_SCENE` and `IKKOKU_AUTOCAPTURE`: after the source scene
    /// capture frame is built, writes the map's solid draws alone
    /// (`isSolidSourceMapDraw`), from the same camera and at the same size, as
    /// the replacement passes `compare_original_map.py` compares with the
    /// original player's: `native-map-geometry.png` (white on black) and
    /// `native-map-depth-normals.png` (Unity's depth-normals encoding over
    /// `sourceMapProbeDepthFar(map:)`), plus `native-map.json` (the map census,
    /// the camera matrices, the map root matrix and every draw's model matrix).
    /// With baked lightmaps it also writes the solid lightmapped draws'
    /// irradiance (`SourceStudioMapMaterial.irradiance`: the decoded lightmap
    /// alone, and the two negative-control variants) from the linear HDR scene
    /// target, `native-map-irradiance-<variant>.rgba16f.deflate`. With a cube
    /// sky or particles (slice 3) it also writes each group alone over a
    /// transparent black background, in the same format:
    /// `native-map-sky-<variant>.rgba16f.deflate` (`SourceStudioSkyMaterial
    /// .Variant`: the formula and its three negative controls) and
    /// `native-map-particles-<variant>.rgba16f.deflate` (`SourceStudioParticleInputs
    /// .Variant`: the formula and its two negative controls). Slice 4 adds the
    /// mob silhouettes (`native-map-silhouettes-<variant>`,
    /// `SourceStudioSilhouetteInputs.Variant`) and the unlit draws
    /// (`native-map-unlit-<variant>`, `SourceStudioUnlitInputs.Variant`), each
    /// alone the same way. None of these images carries the editor grid. A scene whose map is not drawn fails, naming the
    /// status line.
    static func writeSourceMapProbe(studio: StudioModel, renderer: Renderer, directory: URL, width: Int, height: Int) throws {
        let census = studio.sourceMapCensus()
        let items = studio.currentSourceMapItems
        guard !items.isEmpty, let request = studio.sourceMapRequest else {
            throw RigError.invalid("IKKOKU_SOURCE_MAP_PROBE: the scene's map is not drawn (\(census.line ?? "the scene names no map")).")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var frame = studio.frame
        frame.items = items
        frame.gizmos = []
        // The HDR images hold the map's draws alone: no editor grid over them.
        frame.effects.showGrid = false
        let far = sourceMapProbeDepthFar(map: Int(request.map))
        let solid = items.filter(isSolidSourceMapDraw)
        var solidFrame = frame
        solidFrame.items = solid
        for (name, depthNormals) in [("native-map-geometry.png", false), ("native-map-depth-normals.png", true)] {
            try CaptureOutput.writePNG(renderer.captureSourceGeometry(frame: solidFrame, width: width, height: height, depthNormals: depthNormals, far: far),
                                       to: directory.appendingPathComponent(name))
        }
        func writeHDR(_ probe: RenderFrame, _ name: String) throws {
            guard let bits = renderer.captureSceneHDR(frame: probe, width: width, height: height) else {
                throw RigError.invalid("IKKOKU_SOURCE_MAP_PROBE: the \(name) capture failed.")
            }
            let packed = try (bits.withUnsafeBytes { Data($0) } as NSData).compressed(using: .zlib) as Data
            try packed.write(to: directory.appendingPathComponent(name))
        }
        let hdrFormat = "RGBA float16 little-endian, rows top-down, raw DEFLATE (RFC 1951): the linear HDR scene target after the MSAA resolve, before bloom, grading and the sRGB composite"
        var irradiance: [String: Any] = ["written": false]
        let lightmapped = solid.filter { SourceStudioMapAsset.Draw($0.material) == .lightmapped }
        if !lightmapped.isEmpty {
            var files: [String: String] = [:]
            for variant in SourceStudioMapMaterial.IrradianceVariant.allCases {
                var probe = frame
                probe.items = lightmapped.compactMap { item in
                    guard let material = SourceStudioMapMaterial.irradiance(item.material, variant: variant) else { return nil }
                    var copy = item
                    copy.material = material
                    return copy
                }
                let name = "native-map-irradiance-\(variant.rawValue).rgba16f.deflate"
                try writeHDR(probe, name)
                files[variant.rawValue] = name
            }
            irradiance = ["written": true, "files": files, "draws": lightmapped.count, "otherDraws": items.count - lightmapped.count,
                          "format": hdrFormat]
        }
        // Slice 3: the sky (the formula and its controls) and the particles, each group alone, over transparent black.
        var groups: [String: Any] = [:]
        let skies = items.filter { SourceStudioMapAsset.Draw($0.material) == .sky }
        if skies.isEmpty {
            groups["sky"] = ["written": false]
        } else {
            var files: [String: String] = [:]
            for variant in SourceStudioSkyMaterial.Variant.allCases {
                var probe = frame
                probe.items = skies.compactMap { item in
                    guard let material = SourceStudioSkyMaterial.variant(item.material, variant) else { return nil }
                    var copy = item
                    copy.material = material
                    return copy
                }
                probe.effects.transparentBackground = true
                let name = "native-map-sky-\(variant.rawValue).rgba16f.deflate"
                try writeHDR(probe, name)
                files[variant.rawValue] = name
            }
            groups["sky"] = ["written": true, "files": files, "draws": skies.count, "rotationDegrees": skies.map { $0.material.uniforms.params.x },
                             "background": "transparent black", "format": hdrFormat]
        }
        // Slices 3 and 4: the particles, the mob silhouettes and the unlit draws, each group alone over
        // transparent black, as the formula and its negative controls.
        func writeGroup(_ group: String, _ draw: SourceStudioMapAsset.Draw, _ variants: [String],
                        _ variant: (MaterialState, String) -> MaterialState?) throws {
            let members = items.filter { SourceStudioMapAsset.Draw($0.material) == draw }
            guard !members.isEmpty else {
                groups[group] = ["written": false]
                return
            }
            var files: [String: String] = [:]
            for name in variants {
                var probe = frame
                probe.items = members.compactMap { item in
                    guard let material = variant(item.material, name) else { return nil }
                    var copy = item
                    copy.material = material
                    return copy
                }
                probe.effects.transparentBackground = true
                let file = "native-map-\(group)-\(name).rgba16f.deflate"
                try writeHDR(probe, file)
                files[name] = file
            }
            groups[group] = ["written": true, "files": files, "draws": members.count, "background": "transparent black", "format": hdrFormat]
        }
        try writeGroup("particles", .particle, SourceStudioParticleInputs.Variant.allCases.map(\.rawValue)) { material, name in
            SourceStudioParticleInputs.Variant(rawValue: name).flatMap { SourceStudioParticleInputs.variant(material, $0) }
        }
        try writeGroup("silhouettes", .silhouette, SourceStudioSilhouetteInputs.Variant.allCases.map(\.rawValue)) { material, name in
            SourceStudioSilhouetteInputs.Variant(rawValue: name).flatMap { SourceStudioSilhouetteInputs.variant(material, $0) }
        }
        try writeGroup("unlit", .unlit, SourceStudioUnlitInputs.Variant.allCases.map(\.rawValue)) { material, name in
            SourceStudioUnlitInputs.Variant(rawValue: name).flatMap { SourceStudioUnlitInputs.variant(material, $0) }
        }
        let camera = frame.camera
        func columns(_ m: float4x4) -> [Float] { (0..<4).flatMap { c in (0..<4).map { r in m[c][r] } } }
        let document: [String: Any] = [
            "schemaVersion": 1,
            "scope": "ST-A11: the source scene's converted map draws alone, from the capture camera, as geometry and Unity depth-normals; engine basis (Unity z negated), column-major matrices.",
            "width": width, "height": height, "depthFar": far,
            "census": try JSONSerialization.jsonObject(with: JSONEncoder().encode(census)),
            "sceneSHA256": request.sceneSHA256,
            "irradiance": irradiance, "sky": groups["sky"] as Any, "particles": groups["particles"] as Any,
            "silhouettes": groups["silhouettes"] as Any, "unlit": groups["unlit"] as Any,
            "solidDraws": solid.count,
            "map": request.map, "sunLightType": request.sunLightType,
            "transform": ["position": [request.transform.position.x, request.transform.position.y, request.transform.position.z],
                          "rotationDegrees": [request.transform.rotationDegrees.x, request.transform.rotationDegrees.y, request.transform.rotationDegrees.z]],
            "mapRoot": columns(try SourceStudioMapPlacement.mapRootMatrix(request.transform)),
            "camera": ["view": columns(camera.viewMatrix()), "projection": columns(camera.projectionMatrix(aspect: Float(width) / Float(height))),
                       "fovDegrees": camera.fovDegrees, "near": camera.near],
            "draws": items.map { ["mesh": $0.mesh.id, "model": columns($0.model), "objectID": $0.objectID, "pickOccluder": $0.pickOccluder,
                                  "castsShadow": $0.castsShadow, "outline": $0.outline,
                                  "draw": SourceStudioMapAsset.Draw($0.material).rawValue, "solid": isSolidSourceMapDraw($0)] as [String: Any] },
        ]
        try CaptureOutput.writeJSON(JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
                                    to: directory.appendingPathComponent("native-map.json"))
        print("[ikkoku] source map probe: \(items.count) draws written to \(directory.path)")
    }
}
