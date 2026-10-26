import Foundation
import simd
import CoreMath
import Renderer
import Studio
import Scene
import ShaderTypes

extension AppState {
    /// The Unity depth-normals far plane both sides encode with: the original
    /// probe (`Tools/reverse/fixtures/OriginalMapProbe.cs`, `DepthFar`) renders
    /// its depth pass with this far plane, so equal encodings mean equal metres.
    static let sourceMapProbeDepthFar: Float = 25

    /// ST-A11 evidence, `IKKOKU_SOURCE_MAP_PROBE=<directory>` with
    /// `IKKOKU_SOURCE_SCENE` and `IKKOKU_AUTOCAPTURE`: after the source scene
    /// capture frame is built, writes the map's draws alone, from the same
    /// camera and at the same size, as the replacement passes
    /// `compare_original_map.py` compares with the original player's:
    /// `native-map-geometry.png` (white on black) and
    /// `native-map-depth-normals.png` (Unity's depth-normals encoding over
    /// `sourceMapProbeDepthFar`), plus `native-map.json` (the map census, the
    /// camera matrices, the map root matrix and every draw's model matrix).
    /// With baked lightmaps it also writes the lightmapped draws' irradiance
    /// (`SourceStudioMapMaterial.irradiance`: the decoded lightmap alone, and
    /// the two negative-control variants) from the linear HDR scene target,
    /// `native-map-irradiance-<variant>.rgba16f.deflate`.
    /// A scene whose map is not drawn fails, naming the status line.
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
        let far = sourceMapProbeDepthFar
        for (name, depthNormals) in [("native-map-geometry.png", false), ("native-map-depth-normals.png", true)] {
            try CaptureOutput.writePNG(renderer.captureSourceGeometry(frame: frame, width: width, height: height, depthNormals: depthNormals, far: far),
                                       to: directory.appendingPathComponent(name))
        }
        var irradiance: [String: Any] = ["written": false]
        let lightmapped = items.filter { $0.material.kind == MaterialKindMap }
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
                guard let bits = renderer.captureSceneHDR(frame: probe, width: width, height: height) else {
                    throw RigError.invalid("IKKOKU_SOURCE_MAP_PROBE: the \(variant.rawValue) irradiance capture failed.")
                }
                let name = "native-map-irradiance-\(variant.rawValue).rgba16f.deflate"
                let packed = try (bits.withUnsafeBytes { Data($0) } as NSData).compressed(using: .zlib) as Data
                try packed.write(to: directory.appendingPathComponent(name))
                files[variant.rawValue] = name
            }
            irradiance = ["written": true, "files": files, "draws": lightmapped.count, "otherDraws": items.count - lightmapped.count,
                          "format": "RGBA float16 little-endian, rows top-down, raw DEFLATE (RFC 1951): the linear HDR scene target after the MSAA resolve, before bloom, grading and the sRGB composite"]
        }
        let camera = frame.camera
        func columns(_ m: float4x4) -> [Float] { (0..<4).flatMap { c in (0..<4).map { r in m[c][r] } } }
        let document: [String: Any] = [
            "schemaVersion": 1,
            "scope": "ST-A11: the source scene's converted map draws alone, from the capture camera, as geometry and Unity depth-normals; engine basis (Unity z negated), column-major matrices.",
            "width": width, "height": height, "depthFar": far,
            "census": try JSONSerialization.jsonObject(with: JSONEncoder().encode(census)),
            "sceneSHA256": request.sceneSHA256,
            "irradiance": irradiance,
            "map": request.map, "sunLightType": request.sunLightType,
            "transform": ["position": [request.transform.position.x, request.transform.position.y, request.transform.position.z],
                          "rotationDegrees": [request.transform.rotationDegrees.x, request.transform.rotationDegrees.y, request.transform.rotationDegrees.z]],
            "mapRoot": columns(try SourceStudioMapPlacement.mapRootMatrix(request.transform)),
            "camera": ["view": columns(camera.viewMatrix()), "projection": columns(camera.projectionMatrix(aspect: Float(width) / Float(height))),
                       "fovDegrees": camera.fovDegrees, "near": camera.near],
            "draws": items.map { ["mesh": $0.mesh.id, "model": columns($0.model), "objectID": $0.objectID, "pickOccluder": $0.pickOccluder,
                                  "castsShadow": $0.castsShadow, "outline": $0.outline] as [String: Any] },
        ]
        try CaptureOutput.writeJSON(JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
                                    to: directory.appendingPathComponent("native-map.json"))
        print("[ikkoku] source map probe: \(items.count) draws written to \(directory.path)")
    }
}
