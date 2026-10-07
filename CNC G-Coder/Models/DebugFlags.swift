import Foundation

/// Launch-argument debug switches read once (`-debugRenderLog 1` …).
enum DebugFlags {
    /// Print SwiftUI's `_printChanges()` from the main views' bodies.
    nonisolated static let renderLog = UserDefaults.standard.bool(forKey: "debugRenderLog")
}
