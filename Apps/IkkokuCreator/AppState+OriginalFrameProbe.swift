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
                    let all = try probe.captureTranslatedShader(frameURL: input, programURL: translatedProgram, resources: host.renderer.resources, queue: host.renderer.gpu.commandQueue, allFamilies: true)
                    try ImageIO.writePNG(all, to: output.appendingPathComponent("native-translated.png"))
                    if ProcessInfo.processInfo.environment["IKKOKU_ORIGINAL_FRAME_FAMILIES"] == "1",
                       let source = try? JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [String: Any],
                       let meshes = source["meshes"] as? [[String: Any]] {
                        let families = Set(meshes.flatMap { $0["materials"] as? [[String: Any]] ?? [] }.compactMap { ($0["shader"] as? String)?.components(separatedBy: "/").last }.filter { $0 != "shadowcast" })
                        for family in families.sorted() {
                            let program = output.appendingPathComponent("shaders/\(family)/program.json")
                            guard FileManager.default.fileExists(atPath: program.path) else { throw OriginalFrameProbe.ProbeError.invalid("Missing translated shader \(family)") }
                            try ImageIO.writePNG(probe.captureTranslatedShader(frameURL: input, programURL: program, resources: host.renderer.resources, queue: host.renderer.gpu.commandQueue, families: [family]), to: output.appendingPathComponent("native-translated-\(family).png"))
                        }
                        // Silhouette attribution slice: render explicit family subsets
                        // (comma-separated names, semicolon-separated sets) side by side
                        // to find which pair reproduces the hair-crown residual. Written
                        // as native-pair-* so the family-only comparison glob is untouched.
                        if let setsSpec = ProcessInfo.processInfo.environment["IKKOKU_ORIGINAL_FRAME_FAMILY_SETS"] {
                            for spec in setsSpec.split(separator: ";") {
                                let members = Set(spec.split(separator: ",").map(String.init))
                                guard !members.isEmpty, families.isSuperset(of: members) else { throw OriginalFrameProbe.ProbeError.invalid("Unknown family set \(spec)") }
                                let render = try probe.captureTranslatedShader(frameURL: input, programURL: translatedProgram, resources: host.renderer.resources, queue: host.renderer.gpu.commandQueue, families: members)
                                try ImageIO.writePNG(render, to: output.appendingPathComponent("native-pair-\(spec).png"))
                            }
                        }
                        // Opt-in 24-bit depth emulation (see captureTranslatedShader):
                        // re-render the full-character view, the per-family views and
                        // the family-set views with fragment depth quantized to the
                        // 24-bit depth grid of the original capture's D3D11 device.
                        // Written as native-translated24*/native-pair24-* so the gated
                        // comparison globs (native-translated.png, native-translated-*.png)
                        // are untouched.
                        if ProcessInfo.processInfo.environment["IKKOKU_ORIGINAL_FRAME_DEPTH24"] == "1" {
                            try ImageIO.writePNG(probe.captureTranslatedShader(frameURL: input, programURL: translatedProgram, resources: host.renderer.resources, queue: host.renderer.gpu.commandQueue, allFamilies: true, depth24Quantized: true), to: output.appendingPathComponent("native-translated24.png"))
                            for family in families.sorted() {
                                let program = output.appendingPathComponent("shaders/\(family)/program.json")
                                try ImageIO.writePNG(probe.captureTranslatedShader(frameURL: input, programURL: program, resources: host.renderer.resources, queue: host.renderer.gpu.commandQueue, families: [family], depth24Quantized: true), to: output.appendingPathComponent("native-translated24-\(family).png"))
                            }
                            if let setsSpec = ProcessInfo.processInfo.environment["IKKOKU_ORIGINAL_FRAME_FAMILY_SETS"] {
                                for spec in setsSpec.split(separator: ";") {
                                    let members = Set(spec.split(separator: ",").map(String.init))
                                    guard !members.isEmpty, families.isSuperset(of: members) else { throw OriginalFrameProbe.ProbeError.invalid("Unknown family set \(spec)") }
                                    let render = try probe.captureTranslatedShader(frameURL: input, programURL: translatedProgram, resources: host.renderer.resources, queue: host.renderer.gpu.commandQueue, families: members, depth24Quantized: true)
                                    try ImageIO.writePNG(render, to: output.appendingPathComponent("native-pair24-\(spec).png"))
                                }
                            }
                        }
                        if let traceSpec = ProcessInfo.processInfo.environment["IKKOKU_ORIGINAL_FRAME_TRACE_PIXELS"] {
                            var pixels: [(x: Int, y: Int)] = []
                            for spec in traceSpec.split(separator: ";") {
                                let parts = spec.split(separator: ",")
                                guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else { throw OriginalFrameProbe.ProbeError.invalid("Invalid trace pixel \(spec)") }
                                pixels.append((x: x, y: y))
                            }
                            let trace = try probe.captureTranslatedDrawTrace(frameURL: input, programURL: translatedProgram, resources: host.renderer.resources, queue: host.renderer.gpu.commandQueue, pixels: pixels)
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            try encoder.encode(trace).write(to: output.appendingPathComponent("native-draw-trace.json"))
                        }
                    }
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
