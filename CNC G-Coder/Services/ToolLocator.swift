import Foundation

/// Locates the external CLI tools: the copy bundled inside the app first
/// (Contents/Helpers, see Scripts/bundle-pcb2gcode.sh), else Homebrew's.
nonisolated enum ToolLocator {
    /// The App Store build (AppStore configuration): no pcb2gcode — it is
    /// GPL-3 — so the native engine does everything and the app never
    /// mentions an engine choice.
    #if APP_STORE
    static let isAppStoreBuild = true
    #else
    static let isAppStoreBuild = false
    #endif

    static func find(_ name: String) -> URL? {
        if isAppStoreBuild { return nil }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            return helper
        }
        // A sandboxed app may only run what it ships with.
        guard !FileAccess.isSandboxed else { return nil }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static var pcb2gcode: URL? { find("pcb2gcode") }
    /// Whether pcb2gcode is the app's own copy (no installation needed).
    static var pcb2gcodeIsBundled: Bool {
        pcb2gcode?.path.hasPrefix(Bundle.main.bundlePath) ?? false
    }
}
