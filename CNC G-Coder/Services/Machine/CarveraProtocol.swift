import Foundation

// What is specific to a Makera Carvera on the wire, as pure data: the
// framed packet format newer firmware speaks, the console commands the
// Smoothieware-based firmware understands, and the UDP announcement the
// machine broadcasts on the LAN. The controller decides when to use them.
//
// Facts, from the firmware and Makera's own controller sources:
//   - Wi‑Fi is TCP port 2222 (one client at a time); USB serial 115200.
//   - Older firmware talks plain text; newer firmware wraps every line in a
//     frame `8668 | length(2) | type(1) | payload | crc16(2) | 55AA`.
//     The controller probes with a plain `echo echo`: a plain `echo` back
//     means text, silence means frames.
//   - Status is the GRBL-style `<State|MPos:…|WPos:…|F:…|S:…|T:…|…>`,
//     with Tool / Wait / Pause among the states and no WCO field.
//   - `$J X1 F600` is a relative jog (no `ok`), `$J -c X1 F600` jogs until
//     Ctrl-Y (0x19), which the firmware answers with `^Y`; while a
//     continuous jog runs the status poll is `?1`, a keep-alive.
//   - Console commands (`version`, `model`, `play`, …) print their output
//     without `ok`; G-code lines and most `$` commands get `ok`.

nonisolated enum CarveraFraming {
    static let header: [UInt8] = [0x86, 0x68]
    static let footer: [UInt8] = [0x55, 0xAA]
    static let maxPayload = 8200

    enum PacketType: UInt8 {
        case controlSingle = 0xA1   // one real-time byte
        case controlMulti = 0xA2    // a command line, no newline
        case fileStart = 0xB0, fileMD5 = 0xB1, fileView = 0xB2, fileData = 0xB3, fileEnd = 0xB4, fileCancel = 0xB5, fileRetry = 0xB6
        case statusReply = 0x81     // a `<…>` report
        case diagnoseReply = 0x82   // a `{…}` report
        case loadInfo = 0x83, loadFinish = 0x84, loadError = 0x85
        case normalInfo = 0x90      // fragments of console text; '\n' ends a line
    }

    /// CRC-16/CCITT (poly 0x1021, init 0), as the firmware computes it.
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    /// One frame around `payload`.
    static func frame(_ type: PacketType, _ payload: [UInt8]) -> Data {
        let length = UInt16(1 + payload.count + 2)
        var body: [UInt8] = [UInt8(length >> 8), UInt8(length & 0xFF), type.rawValue]
        body += payload
        let crc = crc16(body)
        var out = header
        out += body
        out += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        out += footer
        return Data(out)
    }

    /// A command line: the newline is left off (the firmware's number
    /// parsers want the payload to end with the last character).
    static func encode(line: String) -> Data {
        var text = line
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        return frame(.controlMulti, Array(text.utf8))
    }

    static func encode(realtime byte: UInt8) -> Data {
        frame(.controlSingle, [byte])
    }

    /// What a frame carried, as the controller wants it.
    enum Event: Equatable, Sendable {
        case line(String)
        case loadFinish
        case loadError
    }

    /// The firmware's receive state machine, mirrored: header, length,
    /// body, footer; a bad CRC or footer drops the frame silently.
    struct Decoder: Sendable {
        private enum Phase { case header, length, body, footer }
        private var phase: Phase = .header
        private var last: UInt8 = 0
        private var packet: [UInt8] = []
        private var needed = 0
        private var footerBytes: [UInt8] = []
        private var textLine: [UInt8] = []

        init() {}

        mutating func append(_ data: Data) -> [Event] {
            var events: [Event] = []
            for byte in data { events += feed(byte) }
            return events
        }

        private mutating func feed(_ byte: UInt8) -> [Event] {
            switch phase {
            case .header:
                let previous = last
                last = byte
                if previous == CarveraFraming.header[0], byte == CarveraFraming.header[1] {
                    phase = .length
                    packet.removeAll(keepingCapacity: true)
                    needed = 2
                    last = 0
                }
                return []
            case .length:
                packet.append(byte)
                needed -= 1
                if needed == 0 {
                    let length = Int(packet[0]) << 8 | Int(packet[1])
                    if length <= CarveraFraming.maxPayload, length >= 3 {
                        phase = .body
                        needed = length
                    } else {
                        phase = .header
                    }
                }
                return []
            case .body:
                packet.append(byte)
                needed -= 1
                if needed == 0 {
                    phase = .footer
                    footerBytes.removeAll(keepingCapacity: true)
                    needed = 2
                }
                return []
            case .footer:
                footerBytes.append(byte)
                needed -= 1
                guard needed == 0 else { return [] }
                phase = .header
                guard footerBytes == CarveraFraming.footer else { return [] }
                return dispatch()
            }
        }

        private mutating func dispatch() -> [Event] {
            // packet = length(2) | type | payload | crc(2)
            guard packet.count >= 5 else { return [] }
            let body = Array(packet[0..<(packet.count - 2)])
            let received = UInt16(packet[packet.count - 2]) << 8 | UInt16(packet[packet.count - 1])
            guard CarveraFraming.crc16(body) == received else { return [] }
            let payload = Array(packet[3..<(packet.count - 2)])
            switch PacketType(rawValue: packet[2]) {
            case .loadFinish: return [.loadFinish]
            case .loadError: return [.loadError]
            case .normalInfo:
                // Fragments: a line ends at '\n' (which may be in a later frame).
                var events: [Event] = []
                for byte in payload {
                    if byte == 0x0A {
                        events.append(.line(String(decoding: textLine, as: UTF8.self).trimmingCharacters(in: .init(charactersIn: "\r"))))
                        textLine.removeAll(keepingCapacity: true)
                    } else {
                        textLine.append(byte)
                    }
                }
                return events
            case .fileStart, .fileMD5, .fileView, .fileData, .fileEnd, .fileCancel, .fileRetry:
                return []
            case .statusReply, .diagnoseReply, .loadInfo, .controlSingle, .controlMulti, nil:
                let text = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? [] : text.split(separator: "\n").map { .line(String($0).trimmingCharacters(in: .init(charactersIn: "\r"))) }
            }
        }
    }
}

// MARK: - Commands

nonisolated enum CarveraCommand {
    static let tcpPort: UInt16 = 2222
    static let discoveryPort: UInt16 = 3333
    /// The protocol probe: plain text answers `echo`.
    static let echoProbe = "echo echo"
    static let version = "version"
    static let model = "model"
    /// Clearance position (machine top, Makera's "G28").
    static let clearance = "G28"
    static let airOn = "M7"
    static let airOff = "M9"
    /// Stops a continuous jog; the firmware answers `^Y`.
    static let jogStop: UInt8 = 0x19
    /// Keeps a continuous jog alive: sent instead of `?` while it runs.
    static let jogKeepAlive: [UInt8] = [0x3F, 0x31]   // "?1"

    /// Relative jog: `$J X-0.100 Y0.200 F600`. The firmware prints nothing
    /// for it (no `ok`).
    static func jog(vector: [Axis: Double], feed: Double) -> String {
        var words = ["$J"]
        for axis in Axis.allCases {
            if let distance = vector[axis] { words.append("\(axis.gcodeLetter)\(GRBLCommand.number(distance))") }
        }
        words.append(GRBLCommand.feedWord(feed))
        return words.joined(separator: " ")
    }

    /// `$J -c X1 Y-1 F600`: jogs until Ctrl-Y.
    static func continuousJog(directions: [Axis: JogDirection], feed: Double) -> String {
        var words = ["$J", "-c"]
        for axis in Axis.allCases {
            if let direction = directions[axis] { words.append("\(axis.gcodeLetter)\(direction == .positive ? "1" : "-1")") }
        }
        words.append(GRBLCommand.feedWord(feed))
        return words.joined(separator: " ")
    }

    static func feedOverride(percent: Int) -> String { "M220 S\(max(10, min(300, percent)))" }
    static func spindleOverride(percent: Int) -> String { "M223 S\(max(10, min(200, percent)))" }

    /// `version = 1.0.3c` → "1.0.3c"; nil for any other line.
    static func parseVersion(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("version") else { return nil }
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// `model = C1, 1, 4, 0` → ("C1", machineModel, funcSetting). The
    /// firmware's `FuncSetting` bit 2 says the machine has a tool changer.
    static func parseModel(_ line: String) -> (name: String, model: Int, funcSetting: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("model"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let parts = trimmed[trimmed.index(after: equals)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first, !name.isEmpty else { return nil }
        return (name, parts.count > 1 ? Int(parts[1]) ?? 0 : 0, parts.count > 2 ? Int(parts[2]) ?? 0 : 0)
    }
}

// MARK: - Discovery

/// Carveras announce themselves by UDP broadcast on port 3333, once a
/// second: `name,ip,port,busy`. Listening for a few seconds lists them.
nonisolated enum CarveraDiscovery {
    struct Found: Identifiable, Hashable, Sendable {
        let name: String
        let host: String
        let port: Int
        let busy: Bool
        var id: String { "\(name)@\(host):\(port)" }
    }

    static func discover(seconds: Double = 3) async -> [Found] {
        await Task.detached(priority: .userInitiated) { () -> [Found] in
            let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard socket >= 0 else { return [] }
            defer { Darwin.close(socket) }
            var yes: Int32 = 1
            setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(socket, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = CarveraCommand.discoveryPort.bigEndian
            address.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else { return [] }
            var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var found: [Found] = []
            var buffer = [UInt8](repeating: 0, count: 256)
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                let count = Darwin.recv(socket, &buffer, buffer.count, 0)
                guard count > 0 else { continue }
                let text = String(decoding: buffer[0..<count], as: UTF8.self)
                let fields = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard fields.count >= 4 else { continue }
                let entry = Found(name: fields[0], host: fields[1], port: Int(fields[2]) ?? Int(CarveraCommand.tcpPort), busy: fields[3] == "1")
                if !found.contains(where: { $0.name == entry.name && $0.host == entry.host }) { found.append(entry) }
            }
            return found
        }.value
    }
}
