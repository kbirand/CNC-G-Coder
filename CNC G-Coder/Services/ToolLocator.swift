import Foundation

/// Locates the external CLI tools: the copy bundled inside the app first
/// (Contents/Helpers, see Scripts/bundle-pcb2gcode.sh), else Homebrew's.
nonisolated enum ToolLocator {
    static func find(_ name: String) -> URL? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            return helper
        }
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
