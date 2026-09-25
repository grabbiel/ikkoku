import Foundation

/// Shared selection helper for tests that depend on original/source fixtures
/// supplied through environment variables.
///
/// Usage:
/// ```swift
/// @Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_EXAMPLE_REFERENCE"]),
///              "Requires IKKOKU_EXAMPLE_REFERENCE"))
/// func example() throws {
///     let path = try SourceFixtureSupport.require("IKKOKU_EXAMPLE_REFERENCE")
///     // ...
/// }
/// ```
///
/// Strict mode (`IKKOKU_REQUIRE_SOURCE_FIXTURES=1`) makes `shouldRun` return
/// true even when required variables are absent or empty, so the executed test
/// fails loudly (via `require`) instead of silently skipping. Filesystem and
/// readability failures remain observable in the consuming tests.
internal enum SourceFixtureSupport {
    /// Returns true when the test should run.
    ///
    /// - In strict mode (`IKKOKU_REQUIRE_SOURCE_FIXTURES=1`) this always
    ///   returns true so missing fixtures surface as test failures.
    /// - Otherwise returns true only when every variable in `variables` is
    ///   present and nonempty in `environment`.
    static func shouldRun(_ variables: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if strictMode(environment: environment) { return true }
        return variables.allSatisfy { (environment[$0] ?? "").isEmpty == false }
    }

    /// Returns the value of `variable` from `environment`, throwing a
    /// descriptive error when the variable is absent or empty.
    static func require(_ variable: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        guard let value = environment[variable], !value.isEmpty else {
            throw SourceFixtureError.missing(variable)
        }
        return value
    }

    private static func strictMode(environment: [String: String]) -> Bool {
        (environment["IKKOKU_REQUIRE_SOURCE_FIXTURES"] ?? "") == "1"
    }
}

internal enum SourceFixtureError: Error, CustomStringConvertible, Equatable {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let name):
            return "Required source fixture environment variable \(name) is not set or is empty."
        }
    }
}
