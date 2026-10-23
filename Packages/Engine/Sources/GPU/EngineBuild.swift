import Foundation

/// How the Engine package itself was compiled, for performance reports (R7).
///
/// The app and the Engine package can be optimized differently: Xcode's Debug
/// configuration builds both `-Onone`, but a measurement build may optimize only
/// the package. A report has to say which code it timed, so this reads the
/// assert configuration the *package* was compiled with. The value is computed
/// by a non-inlinable function in this module, so a client's own optimization
/// level cannot change it.
public enum EngineBuild {
    /// `"debug"` for `-Onone`, `"release"` for `-O`/`-Osize`, `"unchecked"` for `-Ounchecked`.
    public static let assertConfiguration: String = currentAssertConfiguration()

    /// True unless the package was compiled `-Onone`.
    public static var isOptimized: Bool { assertConfiguration != "debug" }

    @inline(never)
    private static func currentAssertConfiguration() -> String {
        if _isDebugAssertConfiguration() { return "debug" }
        if _isFastAssertConfiguration() { return "unchecked" }
        return "release"
    }
}
