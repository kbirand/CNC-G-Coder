import Foundation

/// The app's version and the git commit it was built from. `GitStamp` is
/// generated into `$(BUILT_PRODUCTS_DIR)/GitCommit.swift` by the "Stamp git
/// commit" build phase (`git rev-parse --short HEAD`, "-dirty" appended when
/// the working tree had uncommitted changes) and compiled in. Shown in About,
/// Settings → General and the Log at launch, and written into every saved
/// project (`ProjectDocument.savedWith`) so a board can be traced to the
/// build that made it.
nonisolated enum BuildInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    static var commit: String { GitStamp.commit.isEmpty ? "unknown" : GitStamp.commit }
    /// The commit's date as git prints it (`%ci`), empty when unknown.
    static var commitDate: String { GitStamp.date }
    /// "1.0 (1) · abc1234"
    static var summary: String { "\(version) (\(build)) · \(commit)" }
}
