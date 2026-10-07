import Foundation

// The GRBL / FluidNC wire protocol as pure data: axes and positions, the
// `<…>` status report parser, response classification, firmware
// identification, real-time bytes and the G-code line builders. Everything
// here is `nonisolated` and side-effect free so the controller, the streamer
// and the tests can use it from any context. Ported from the iOS pendant
// (CNC Jogger) and extended with the fields the machine window needs.

// MARK: - Axes and positions

/// One of the three linear machine axes.
nonisolated enum Axis: String, CaseIterable, Codable, Sendable {
    case x = "X"
    case y = "Y"
    case z = "Z"

    /// Letter used in G-code words, e.g. `X10.000`.
    var gcodeLetter: String { rawValue }
}

/// Direction of travel along an axis.
nonisolated enum JogDirection: Int, Sendable {
    case negative = -1
    case positive = 1

    var sign: Double { Double(rawValue) }
}

/// An absolute X/Y/Z position in millimetres.
nonisolated struct MachinePosition: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = MachinePosition(x: 0, y: 0, z: 0)

    subscript(axis: Axis) -> Double {
        get {
            switch axis {
            case .x: x
            case .y: y
            case .z: z
            }
        }
        set {
            switch axis {
            case .x: x = newValue
            case .y: y = newValue
            case .z: z = newValue
            }
        }
    }

    /// Fixed three-decimal formatting used by GRBL and the DRO.
    static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    func formatted(_ axis: Axis) -> String {
        Self.format(self[axis])
    }

    /// Compact single-line representation, e.g. `X10.000 Y-5.250 Z2.000`.
    var summary: String {
        Axis.allCases.map { "\($0.gcodeLetter)\(formatted($0))" }.joined(separator: " ")
    }

    /// The first three comma-separated numbers of a report field
    /// (`10.000,20.000,-5.000`); extra axes (A, B…) are ignored.
    fileprivate static func parse(field: Substring) -> MachinePosition? {
        let values = field.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count >= 3 else { return nil }
        return MachinePosition(x: values[0], y: values[1], z: values[2])
    }
}

// MARK: - Machine state

/// Machine state as reported in the first field of a GRBL `<…>` status report.
/// `Hold` and `Door` carry their sub-state (`Hold:0` = hold complete, `Hold:1`
/// = still decelerating; `Door:0…3`). States neither firmware documents in
/// common (`Homing`, `Starting`, `Critical`…) are kept verbatim as `.other`
/// instead of being flattened to "unknown", so the pill can still show them.
nonisolated enum MachineState: Equatable, Sendable {
    case idle, run, jog
    case hold(Int?)
    case alarm, home
    case door(Int?)
    case check, sleep
    case other(String)

    /// Parses `Idle`, `Hold:0`, `Door:1`, `Homing`…
    init(reportField: Substring) {
        let parts = reportField.split(separator: ":", maxSplits: 1)
        let name = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let sub = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        switch name {
        case "Idle": self = .idle
        case "Run": self = .run
        case "Jog": self = .jog
        case "Hold": self = .hold(sub)
        case "Alarm": self = .alarm
        case "Home": self = .home
        case "Door": self = .door(sub)
        case "Check": self = .check
        case "Sleep": self = .sleep
        default: self = .other(name.isEmpty ? "Unknown" : name)
        }
    }

    /// The report spelling, e.g. `Idle`, `Hold:0`, `Homing`.
    var name: String {
        switch self {
        case .idle: "Idle"
        case .run: "Run"
        case .jog: "Jog"
        case .hold(let sub): sub.map { "Hold:\($0)" } ?? "Hold"
        case .alarm: "Alarm"
        case .home: "Home"
        case .door(let sub): sub.map { "Door:\($0)" } ?? "Door"
        case .check: "Check"
        case .sleep: "Sleep"
        case .other(let name): name
        }
    }

    /// Whether the operator may issue a jog from this state.
    var allowsJog: Bool {
        switch self {
        case .idle, .jog: true
        default: false
        }
    }

    /// Whether an automatic positioning move may be started.
    var allowsMotion: Bool { self == .idle }

    /// `Hold:0` — the machine has come to rest and may be resumed.
    var isHoldComplete: Bool { self == .hold(0) }
}

// MARK: - Status report

/// The `Ov:` percentages of a status report.
nonisolated struct GRBLOverrides: Equatable, Sendable {
    var feed: Int
    var rapid: Int
    var spindle: Int
}

/// A parsed GRBL real-time status report, e.g.
/// `<Idle|MPos:10.000,20.000,-5.000|FS:0,0|WCO:0.000,0.000,0.000|Bf:15,128|Ov:100,100,100>`.
nonisolated struct GRBLStatus: Equatable, Sendable {
    var state: MachineState = .other("Unknown")
    /// Nil until `MPos` has been seen, or `WPos` with a known work offset.
    var machinePosition: MachinePosition?
    /// `WPos`, or `MPos − WCO` when the offset is known.
    var workPosition: MachinePosition?
    /// The work-coordinate offset this report was resolved with (reported or cached).
    var workOffset: MachinePosition?
    var feedRate: Double = 0
    var spindleSpeed: Double = 0
    /// `Bf:` — free planner blocks.
    var plannerBlocks: Int?
    /// `Bf:` — free bytes in the serial receive buffer.
    var rxBytes: Int?
    var overrides: GRBLOverrides?
    /// `Pn:` input-pin letters (`XYZPDHRS`), empty when no pin is active.
    var pins: String = ""
    /// `A:` accessory letters (`S`/`C` spindle, `F` flood, `M` mist).
    var accessories: String = ""
    /// `Ln:` — the line number of the executing block ($10 bit / FluidNC).
    var lineNumber: Int?
    /// FluidNC `SD:pct,path` while a card job runs.
    var sdPercent: Double?
    var sdPath: String?

    /// Whether any position has been received.
    var hasPosition: Bool { machinePosition != nil || workPosition != nil }

    /// Parses a status report line. Returns `nil` for anything that is not a
    /// `<…>` report. `lastWorkOffset` is the WCO cached from earlier reports:
    /// GRBL only sends `WCO:` every few reports (and right after it changes),
    /// so the work position of the reports in between is derived from it. A
    /// `WPos`-only report with no cached offset leaves `machinePosition` nil
    /// rather than guessing (the pendant copied WPos into it, which lied to
    /// the DRO until the first `WCO:`).
    static func parse(_ line: String, lastWorkOffset: MachinePosition? = nil) -> GRBLStatus? {
        var text = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard text.hasPrefix("<"), text.hasSuffix(">"), text.count >= 2 else { return nil }
        text = text.dropFirst().dropLast()

        let fields = text.split(separator: "|")
        guard let stateField = fields.first else { return nil }

        var status = GRBLStatus()
        status.state = MachineState(reportField: stateField)

        var machine: MachinePosition?
        var work: MachinePosition?
        var workOffset = lastWorkOffset

        for field in fields.dropFirst() {
            let parts = field.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let payload = parts[1]
            let numbers = payload.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

            switch key {
            case "MPos":
                machine = MachinePosition.parse(field: payload)
            case "WPos":
                work = MachinePosition.parse(field: payload)
            case "WCO":
                if let wco = MachinePosition.parse(field: payload) { workOffset = wco }
            case "FS":
                if numbers.count >= 2 {
                    status.feedRate = numbers[0]
                    status.spindleSpeed = numbers[1]
                }
            case "F":
                if let feed = numbers.first { status.feedRate = feed }
            case "Bf":
                if numbers.count >= 2 {
                    status.plannerBlocks = Int(numbers[0])
                    status.rxBytes = Int(numbers[1])
                }
            case "Ov":
                if numbers.count >= 3 {
                    status.overrides = GRBLOverrides(feed: Int(numbers[0]), rapid: Int(numbers[1]), spindle: Int(numbers[2]))
                }
            case "Pn":
                status.pins = String(payload).trimmingCharacters(in: .whitespaces)
            case "A":
                status.accessories = String(payload).trimmingCharacters(in: .whitespaces)
            case "Ln":
                status.lineNumber = numbers.first.map { Int($0) }
            case "SD":
                // `SD:12.50,/sd/board.nc` — the path may itself contain commas, so
                // only the first one separates the percentage.
                let sdParts = payload.split(separator: ",", maxSplits: 1)
                if let first = sdParts.first { status.sdPercent = Double(first.trimmingCharacters(in: .whitespaces)) }
                if sdParts.count > 1 { status.sdPath = String(sdParts[1]) }
            default:
                continue
            }
        }

        // GRBL reports either MPos or WPos depending on $10; derive the other from WCO.
        status.workOffset = workOffset
        if let machine {
            status.machinePosition = machine
            if let workOffset {
                status.workPosition = MachinePosition(
                    x: machine.x - workOffset.x,
                    y: machine.y - workOffset.y,
                    z: machine.z - workOffset.z
                )
            } else if let work {
                status.workPosition = work
            }
        } else if let work {
            status.workPosition = work
            if let workOffset {
                status.machinePosition = MachinePosition(
                    x: work.x + workOffset.x,
                    y: work.y + workOffset.y,
                    z: work.z + workOffset.z
                )
            }
        }

        return status
    }
}

// MARK: - Response classification

/// One inbound line, sorted by what the controller has to do with it. Status
/// reports are only recognised here; the caller parses them with
/// `GRBLStatus.parse` because that needs the cached work offset.
nonisolated enum GRBLResponse: Equatable, Sendable {
    case ok
    case error(Int)
    case alarm(Int)
    /// `<…>` report.
    case status
    /// `[MSG:…]` — the text after `MSG:` (FluidNC: `INFO: …`, `ERR: …`, `WARN: …`).
    case message(String)
    /// `[PRB:x,y,z:1]` — the trigger point in machine coordinates and whether the probe made contact.
    case probe(MachinePosition, success: Bool)
    /// `[GC:G0 G54 G17 …]` — the parser-state words.
    case parserState([String])
    /// `[G54:…]`, `[G28:…]`, `[G92:…]`, `[TLO:0.000]` (name "TLO", value in `z`).
    case offset(name: String, MachinePosition)
    /// `[VER:…]` payload.
    case version(String)
    /// `[OPT:…]` payload.
    case options(String)
    /// The welcome banner (`Grbl 1.1h ['$' for help]`, `Grbl 3.9 [FluidNC v3.9.9 …]`).
    case welcome(String)
    /// `$10=1` / `$/axes/x/max_travel_mm=310.000` — the key keeps its leading `$`
    /// so GRBL numbers and FluidNC paths share one form.
    case setting(key: String, value: String)
    case other(String)

    /// The welcome banner is the only line starting with `Grbl ` — both firmwares
    /// print it on boot, after a soft reset and when check mode ends. FluidNC's
    /// `[MSG:INFO: FluidNC v…]` and `[VER:…]` lines mention the firmware but are
    /// not reboots, so they must not count.
    static func isBanner(_ line: String) -> Bool {
        line.hasPrefix("Grbl ")
    }

    static func classify(_ line: String) -> GRBLResponse {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .other(text) }

        if text == "ok" { return .ok }
        if text.hasPrefix("error:") {
            if let code = leadingInt(text.dropFirst("error:".count)) { return .error(code) }
            return .other(text)
        }
        if text.hasPrefix("ALARM:") {
            if let code = leadingInt(text.dropFirst("ALARM:".count)) { return .alarm(code) }
            return .other(text)
        }
        if text.hasPrefix("<"), text.hasSuffix(">") { return .status }
        if isBanner(text) { return .welcome(text) }

        if text.hasPrefix("["), text.hasSuffix("]"), text.count >= 2 {
            let inner = text.dropFirst().dropLast()
            let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let tag = String(parts[0])
            let payload = parts.count > 1 ? String(parts[1]) : ""
            switch tag {
            case "MSG":
                return .message(payload)
            case "PRB":
                // `x,y,z:1` — the success flag follows the last colon.
                let probeParts = payload.split(separator: ":", omittingEmptySubsequences: false)
                guard probeParts.count >= 2, let position = MachinePosition.parse(field: probeParts[0]) else {
                    return .other(text)
                }
                return .probe(position, success: probeParts[1].trimmingCharacters(in: .whitespaces) == "1")
            case "GC":
                return .parserState(payload.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
            case "VER":
                return .version(payload)
            case "OPT":
                return .options(payload)
            case "TLO":
                // Grbl prints one value; FluidNC 4 prints one per axis.
                if let position = MachinePosition.parse(field: Substring(payload)) {
                    return .offset(name: tag, position)
                }
                guard let value = Double(payload.trimmingCharacters(in: .whitespaces)) else { return .other(text) }
                return .offset(name: tag, MachinePosition(x: 0, y: 0, z: value))
            case "G54", "G55", "G56", "G57", "G58", "G59", "G28", "G30", "G92":
                guard let position = MachinePosition.parse(field: Substring(payload)) else { return .other(text) }
                return .offset(name: tag, position)
            default:
                return .other(text)
            }
        }

        if text.hasPrefix("$"), let equals = text.firstIndex(of: "=") {
            let key = String(text[..<equals])
            let value = String(text[text.index(after: equals)...])
            return .setting(key: key, value: value)
        }

        return .other(text)
    }

    /// The integer at the start of `text`, ignoring whatever follows it
    /// (FluidNC may append the message: `error:20 (Unsupported GCode command)`).
    private static func leadingInt(_ text: Substring) -> Int? {
        let digits = text.drop(while: { $0 == " " }).prefix(while: { $0.isNumber })
        return Int(digits)
    }
}

// MARK: - Firmware identification

/// Which firmware answered and its version, from the banner or `$I`'s `[VER:]`.
nonisolated struct FirmwareInfo: Equatable, Sendable {
    enum Kind: String, Sendable { case grbl, fluidnc, unknown }

    var kind: Kind = .unknown
    /// `1.1h` / `3.9.9`.
    var version: String = ""
    var banner: String?

    var description: String {
        switch kind {
        case .grbl: version.isEmpty ? "Grbl" : "Grbl \(version)"
        case .fluidnc: version.isEmpty ? "FluidNC" : "FluidNC \(version)"
        case .unknown: "Unknown"
        }
    }

    /// `[VER:3.9 FluidNC v3.9.9 (wifi):]` or `[VER:1.1h.20190825:]` (Grbl appends the
    /// build date and, after the colon, an optional build string).
    static func parse(versionLine: String) -> FirmwareInfo? {
        let text = versionLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("[VER:"), text.hasSuffix("]") else { return nil }
        let payload = String(text.dropFirst("[VER:".count).dropLast())
        return parse(payload: payload, banner: nil)
    }

    /// `Grbl 1.1h ['$' for help]` or `Grbl 3.9 [FluidNC v3.9.9 (wifi) '$' for help]`.
    static func parse(banner: String) -> FirmwareInfo? {
        let text = banner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GRBLResponse.isBanner(text) else { return nil }
        return parse(payload: String(text.dropFirst("Grbl ".count)), banner: text)
    }

    /// Shared tail: `3.9 FluidNC v3.9.9 (wifi):`, `1.1h.20190825:`, `1.1h ['$' for help]`…
    private static func parse(payload: String, banner: String?) -> FirmwareInfo {
        var info = FirmwareInfo()
        info.banner = banner
        if let range = payload.range(of: "FluidNC") {
            info.kind = .fluidnc
            // Version follows "FluidNC " as "v3.9.9"; stop at whitespace or a bracket/paren.
            var rest = Substring(payload[range.upperBound...]).drop(while: { $0 == " " })
            if rest.hasPrefix("v") || rest.hasPrefix("V") { rest = rest.dropFirst() }
            info.version = String(rest.prefix(while: { !$0.isWhitespace && $0 != "(" && $0 != "]" && $0 != ":" }))
            return info
        }
        info.kind = .grbl
        let first = payload.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "[" }).first.map(String.init) ?? ""
        info.version = stripBuildDate(first)
        return info
    }

    /// `1.1h.20190825` → `1.1h`: Grbl's `[VER:]` suffixes an eight-digit build date.
    private static func stripBuildDate(_ version: String) -> String {
        guard let dot = version.lastIndex(of: ".") else { return version }
        let tail = version[version.index(after: dot)...]
        if tail.count == 8, tail.allSatisfy(\.isNumber) { return String(version[..<dot]) }
        return version
    }
}

// MARK: - Real-time bytes

/// Single-byte real-time commands. They are not newline-terminated and are
/// acted on immediately, ahead of anything in the receive buffer.
nonisolated enum GRBLRealtime {
    static let statusReport: UInt8 = 0x3F   // "?"
    static let feedHold: UInt8 = 0x21       // "!"
    static let cycleStart: UInt8 = 0x7E     // "~"
    static let softReset: UInt8 = 0x18      // Ctrl-X
    static let safetyDoor: UInt8 = 0x84
    static let jogCancel: UInt8 = 0x85
    static let feedReset: UInt8 = 0x90
    static let feedPlus10: UInt8 = 0x91
    static let feedMinus10: UInt8 = 0x92
    static let feedPlus1: UInt8 = 0x93
    static let feedMinus1: UInt8 = 0x94
    static let rapid100: UInt8 = 0x95
    static let rapid50: UInt8 = 0x96
    static let rapid25: UInt8 = 0x97
    static let spindleReset: UInt8 = 0x99
    static let spindlePlus10: UInt8 = 0x9A
    static let spindleMinus10: UInt8 = 0x9B
    static let spindlePlus1: UInt8 = 0x9C
    static let spindleMinus1: UInt8 = 0x9D
    static let spindleStopToggle: UInt8 = 0x9E
    static let floodToggle: UInt8 = 0xA0
    static let mistToggle: UInt8 = 0xA1

    /// Console label for a byte, e.g. `? (status)`, `0x85 (jog cancel)`.
    static func label(_ byte: UInt8) -> String {
        let name: String
        switch byte {
        case statusReport: name = "status report"
        case feedHold: name = "feed hold"
        case cycleStart: name = "cycle start / resume"
        case softReset: name = "soft reset"
        case safetyDoor: name = "safety door"
        case jogCancel: name = "jog cancel"
        case feedReset: name = "feed override 100%"
        case feedPlus10: name = "feed override +10%"
        case feedMinus10: name = "feed override −10%"
        case feedPlus1: name = "feed override +1%"
        case feedMinus1: name = "feed override −1%"
        case rapid100: name = "rapid override 100%"
        case rapid50: name = "rapid override 50%"
        case rapid25: name = "rapid override 25%"
        case spindleReset: name = "spindle override 100%"
        case spindlePlus10: name = "spindle override +10%"
        case spindleMinus10: name = "spindle override −10%"
        case spindlePlus1: name = "spindle override +1%"
        case spindleMinus1: name = "spindle override −1%"
        case spindleStopToggle: name = "spindle stop toggle"
        case floodToggle: name = "flood coolant toggle"
        case mistToggle: name = "mist coolant toggle"
        default: name = "unknown"
        }
        if byte >= 0x21, byte < 0x7F, let scalar = Unicode.Scalar(UInt32(byte)) {
            return "\(Character(scalar)) (\(name))"
        }
        return String(format: "0x%02X (%@)", byte, name)
    }
}

// MARK: - Command builders

/// Builds the G-code and `$` command lines understood by GRBL / FluidNC.
/// No trailing newline; numbers are three-decimal, feeds integer.
nonisolated enum GRBLCommand {
    static let unlock = "$X"
    static let home = "$H"
    static let parserState = "$G"
    static let offsets = "$#"
    static let buildInfo = "$I"
    static let settings = "$$"
    static let checkMode = "$C"
    static let sleep = "$SLP"
    /// A zero-length dwell: its `ok` arrives only after the planner has drained.
    static let sync = "G4 P0"
    static let spindleOff = "M5"
    static let coolantOff = "M9"

    static func number(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    static func feedWord(_ feed: Double) -> String {
        "F\(Int(feed.rounded()))"
    }

    /// Relative jog of `distance` mm along one axis, e.g. `$J=G91 G21 X-0.100 F500`.
    static func jog(axis: Axis, distance: Double, feed: Double) -> String {
        "$J=G91 G21 \(axis.gcodeLetter)\(number(distance)) \(feedWord(feed))"
    }

    /// Relative jog along several axes at once; axes are emitted in X, Y, Z order
    /// whatever the dictionary's order.
    static func jog(vector: [Axis: Double], feed: Double) -> String {
        var words = ["$J=G91", "G21"]
        for axis in Axis.allCases {
            if let distance = vector[axis] { words.append("\(axis.gcodeLetter)\(number(distance))") }
        }
        words.append(feedWord(feed))
        return words.joined(separator: " ")
    }

    /// Linear move to an absolute machine coordinate, only for the axes supplied.
    static func moveToMachine(x: Double? = nil, y: Double? = nil, z: Double? = nil, feed: Double) -> String {
        var words = ["G53", "G90", "G1"]
        if let x { words.append("X\(number(x))") }
        if let y { words.append("Y\(number(y))") }
        if let z { words.append("Z\(number(z))") }
        words.append(feedWord(feed))
        return words.joined(separator: " ")
    }

    /// Splits a go-to into legs so the spindle moves away from the work before it moves across it.
    /// If the target Z is higher than the current Z, Z moves first; otherwise Z moves last.
    static func safeMoveLegs(from current: MachinePosition, to target: MachinePosition, feed: Double) -> [String] {
        let zLeg = moveToMachine(z: target.z, feed: feed)
        let xyLeg = moveToMachine(x: target.x, y: target.y, feed: feed)
        return target.z >= current.z ? [zLeg, xyLeg] : [xyLeg, zLeg]
    }

    /// Sets the current position as work zero on the given axes: `G10 L20 P0 X0 Y0`.
    /// `P0` = the active coordinate system; `G10 L20` is persistent, unlike `G92`.
    static func zero(axes: [Axis]) -> String {
        var words = ["G10", "L20", "P0"]
        for axis in Axis.allCases where axes.contains(axis) {
            words.append("\(axis.gcodeLetter)0")
        }
        return words.joined(separator: " ")
    }

    /// Makes the current position read `workValue` on `axis`: `G10 L20 P0 X5.000`.
    static func setAxis(_ axis: Axis, workValue: Double) -> String {
        "G10 L20 P0 \(axis.gcodeLetter)\(number(workValue))"
    }

    /// Places the active system's origin at an absolute machine coordinate:
    /// `G10 L2 P0 Z-12.345`. Used after probing, where the trigger point is
    /// known in machine coordinates and the tool may have overshot since.
    static func setOrigin(_ axis: Axis, machineValue: Double) -> String {
        "G10 L2 P0 \(axis.gcodeLetter)\(number(machineValue))"
    }

    /// Places the active system's origin at a stored machine point on all
    /// three axes at once: `G10 L2 P0 X11.000 Y71.000 Z-81.000`. Nothing
    /// moves — the work coordinates simply read relative to that point.
    static func setOrigin(machine position: MachinePosition) -> String {
        "G10 L2 P0 " + Axis.allCases.map { "\($0.gcodeLetter)\(number(position[$0]))" }.joined(separator: " ")
    }

    /// `M3 S12000` (or `M4` counter-clockwise).
    static func spindleOn(rpm: Double, clockwise: Bool = true) -> String {
        "\(clockwise ? "M3" : "M4") S\(Int(rpm.rounded()))"
    }

    /// Straight probe: `G38.2 Z-20.000 F100`. `mode` is the G38 variant
    /// (2 = toward, error on miss; 3 = toward, no error; 4/5 = away).
    static func probe(axis: Axis, distance: Double, feed: Double, mode: Int = 2) -> String {
        "G38.\(mode) \(axis.gcodeLetter)\(number(distance)) \(feedWord(feed))"
    }

    /// Rapid to a machine Z: `G53 G90 G0 Z-2.000`.
    static func safePosition(machineZ: Double) -> String {
        "G53 G90 G0 Z\(number(machineZ))"
    }

    /// FluidNC config query: `$/axes/z/max_travel_mm`. Accepts the path with or
    /// without its leading `$` / `/`.
    static func fluidNCSetting(_ path: String) -> String {
        var trimmed = Substring(path.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("$") { trimmed = trimmed.dropFirst() }
        if trimmed.hasPrefix("/") { trimmed = trimmed.dropFirst() }
        return "$/\(trimmed)"
    }
}
