import Foundation
import CryptoKit
import Renderer
import GPU
import Assets

extension AppState {
    /// Exits after a controlled offscreen diagnostic capture; never a desktop capture.
    static func captureOriginalFrameProbe(host: EngineHost, path: String) {
        do {
            let input = URL(fileURLWithPath: path)
            let probe = try OriginalFrameProbe.load(url: input, resources: host.renderer.resources)
            let output = input.deletingLastPathComponent()
            guard let image = host.renderer.capture(frame: probe.frame, width: probe.width, height: probe.height) else {
                throw OriginalFrameProbe.ProbeError.gpu("Native fixture capture failed")
            }
            try ImageIO.writePNG(image, to: output.appendingPathComponent("native-color.png"))
            for (name, depth) in [("native-geometry.png", false), ("native-depth-normals.png", true)] {
                try ImageIO.writePNG(probe.captureGeometry(resources: host.renderer.resources, queue: host.renderer.gpu.commandQueue, depthNormals: depth), to: output.appendingPathComponent(name))
            }
            let translatedProgram = output.appendingPathComponent("shaders/main_opaque/program.json")
            if FileManager.default.fileExists(atPath: translatedProgram.path) {
                try ImageIO.writePNG(probe.captureTranslatedShader(frameURL: input, programURL: translatedProgram, resources: host.renderer.resources, queue: host.renderer.gpu.commandQueue), to: output.appendingPathComponent("native-main_opaque.png"))
                if FileManager.default.fileExists(atPath: output.appendingPathComponent("shaders/toon_eye_lod0/program.json").path) && FileManager.default.fileExists(atPath: output.appendingPathComponent("mesh-0-uv3.bin").path) {
                    try ImageIO.writePNG(probe.captureTranslatedShader(frameURL: input, programURL: translatedProgram, resources: host.renderer.resources, queue: host.renderer.gpu.commandQueue, allFamilies: true), to: output.appendingPathComponent("native-translated.png"))
                }
            }
            let benchmark = try host.renderer.benchmark(frame: probe.frame, width: probe.width, height: probe.height)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(benchmark).write(to: output.appendingPathComponent("native-benchmark.json"))
            let report: [String: Any] = ["schemaVersion": 1, "sourceFrameFile": input.lastPathComponent, "sourceFrameSHA256": SHA256.hash(data: try Data(contentsOf: input)).map { String(format: "%02x", $0) }.joined(), "scope": "Original frozen evaluated geometry and camera; native renderer baseline. Does not validate native rigs, animation or Studio loading.", "sourceMeshes": probe.sourceMeshCount, "drawItems": probe.frame.items.count, "materialDiagnostics": probe.materialDiagnostics]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-report.json"))
            print("[ikkoku] matched-source geometry fixture captured to \(output.path)")
            exit(0)
        } catch { print("[ikkoku] original frame probe failed: \(error)"); exit(1) }
    }
}
