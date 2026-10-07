import Foundation

/// The serial ports a controller could be behind. macOS exposes every port
/// twice; the `cu.` (call-up) node is the one for a program that dials out,
/// `tty.` blocks in open until carrier detect, which a USB-UART never raises.
nonisolated enum SerialPorts {

    /// Every `/dev/cu.*` path, sorted, with the ports that are never a CNC
    /// controller (Bluetooth, Apple's debug consoles) listed last.
    static func list() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let ports = names.filter { $0.hasPrefix("cu.") }.map { "/dev/" + $0 }
        let (unlikely, likely) = ports.reduce(into: ([String](), [String]())) { groups, port in
            if isUnlikelyController(port) { groups.0.append(port) } else { groups.1.append(port) }
        }
        let byName: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        return likely.sorted(by: byName) + unlikely.sorted(by: byName)
    }

    /// Bluetooth ports (paired headsets, phones) and Apple's own debug
    /// consoles are always present and never the machine.
    static func isUnlikelyController(_ path: String) -> Bool {
        let name = path.lowercased()
        return name.contains("bluetooth") || name.contains("debug-console") || name.contains("wlan-debug")
    }
}
