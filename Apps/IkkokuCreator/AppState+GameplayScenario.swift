import Foundation
import Gameplay
import Renderer

extension AppState {
    /// A-T01 headless gameplay host: runs the JSON `SourceGameplayHostScenario`
    /// at `path` (a controlled catalog, period selection, the event it starts,
    /// persist/reload steps and assertions), writes the report through the
    /// checked `CaptureOutput` writer and exits 0 when every step passed, 1
    /// otherwise. It runs before the engine and both editors are created, so
    /// the gameplay host never shares their state.
    ///
    /// A reload step with a `path` writes the host snapshot there through the
    /// same checked writer and resumes from the bytes read back from disk.
    static func runGameplayScenario(path: String, reportPath: String?) -> Never {
        do {
            guard let reportPath else {
                print("[ikkoku] gameplay scenario failed: IKKOKU_GAMEPLAY_SCENARIO needs IKKOKU_GAMEPLAY_SCENARIO_REPORT.")
                exit(1)
            }
            let scenario = try SourceGameplayHostScenario.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
            let report = scenario.run { snapshot, snapshotPath in
                guard let snapshotPath else { return snapshot }
                let url = URL(fileURLWithPath: snapshotPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try CaptureOutput.writeJSON(snapshot, to: url)
                return try Data(contentsOf: url)
            }
            let reportURL = URL(fileURLWithPath: reportPath)
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CaptureOutput.writeJSON(try report.json(), to: reportURL)
            print("[ikkoku] gameplay scenario: \(report.passed) passed, \(report.failed) failed")
            exit(report.failed == 0 ? 0 : 1)
        } catch {
            print("[ikkoku] gameplay scenario failed: \(error)")
            exit(1)
        }
    }
}
