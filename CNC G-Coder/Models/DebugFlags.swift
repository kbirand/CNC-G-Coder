import Foundation

/// Launch-argument debug switches read once (`-debugRenderLog 1` …).
enum DebugFlags {
    /// Print SwiftUI's `_printChanges()` from the main views' bodies.
    nonisolated static let renderLog = UserDefaults.standard.bool(forKey: "debugRenderLog")
    /// Print one `[job]` line per second while a program streams: elapsed,
    /// preview-clock time vs the program's estimated total, matched move and
    /// acknowledged line — what the job bar's progress and remaining show.
    nonisolated static let jobLog = UserDefaults.standard.bool(forKey: "debugJobLog")
}
