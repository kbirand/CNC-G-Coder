import Foundation

/// Locates the external CLI tools installed by Homebrew.
nonisolated enum ToolLocator {
    static func find(_ name: String) -> URL? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static var pcb2gcode: URL? { find("pcb2gcode") }
    static var gerbv: URL? { find("gerbv") }
}
