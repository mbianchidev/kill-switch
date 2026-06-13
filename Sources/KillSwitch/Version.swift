import Foundation

/// The app's version string.
///
/// Local `swift build` uses the `"dev"` fallback below. The release workflow
/// (`.github/workflows/release.yml`) overwrites this file at build time with the
/// real release version (e.g. `"v1.1.2"`) so the running app knows its own
/// version and can compare it against the latest GitHub release.
enum AppVersion {
    static let current = "dev"

    /// True when running a local/unreleased build (no version was injected).
    static var isDev: Bool { current == "dev" }
}
