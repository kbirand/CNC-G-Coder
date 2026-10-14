import Foundation

/// App-wide machine-control preferences (`machine.*` in `UserDefaults`). Like
/// the backlash play, these describe the machine and the shop, not a board,
/// so they are deliberately not `ParametersStore`/project fields. Views bind
/// to them with `@AppStorage(MachineSettings.Keys.host)`; code reads the typed
/// accessors, which fall back to the defaults below when a key is unset.
nonisolated enum MachineSettings {

    enum Keys {
        static let transport = "machine.transport"
        static let host = "machine.host"
        static let port = "machine.port"
        static let serialPath = "machine.serialPath"
        static let baud = "machine.baud"
        static let pollMs = "machine.pollMs"
        static let jogFeed = "machine.jogFeed"
        static let jogStep = "machine.jogStep"
        static let jogSegmentMs = "machine.jogSegmentMs"
        static let probeFeedFast = "machine.probe.feedFast"
        static let probeFeedSlow = "machine.probe.feedSlow"
        static let probeMaxTravel = "machine.probe.maxTravel"
        static let probeRetract = "machine.probe.retract"
        static let probePlateThickness = "machine.probe.plateThickness"
        static let safeZWork = "machine.safeZWork"
        static let safeZBelowTop = "machine.safeZBelowTop"
        static let spindleMin = "machine.spindleMin"
        static let spindleMax = "machine.spindleMax"
        static let spindleWarmupSeconds = "machine.spindleWarmup"
        static let autoReconnect = "machine.autoReconnect"
        static let consoleShowStatus = "machine.consoleShowStatus"
        static let macros = "machine.macros"
        static let applyBacklash = "machine.applyBacklash"
        static let fitArcs = "machine.fitArcs"
        static let heightMapApplyBelowZ = "machine.heightMap.applyBelowZ"
        static let confirmContinue = "machine.confirmContinue"
        /// Send shows `StartJobSheet` (which layer, side, tool, depth) before streaming.
        static let confirmSend = "machine.confirmSend"
        /// Record the work zero (as a machine point) in Positions when a program is sent.
        static let autoSaveWorkZero = "machine.autoSaveWorkZero"
        static let toolReference = "machine.toolReference"
        /// Bytes kept in flight while streaming; 0 = automatic (see JobStreamer.windowBudget).
        static let streamWindowBytes = "machine.streamWindowBytes"
        /// Which list the Positions tab shows: "machine" or "workZero".
        static let positionsKind = "machine.positionsKind"
        static let showSimulator = "machine.showSimulator"
        static let simBoardX = "machine.sim.boardX"
        static let simBoardY = "machine.sim.boardY"
        static let simBoardThickness = "machine.sim.boardThickness"
        /// FluidNC config file `$CD=` writes to ("" = the one the controller reports).
        static let configFilename = "machine.configFilename"
        /// The DRO's button grid: a JSON array of `DROButton.storageString`.
        static let droButtons = "machine.droButtons"
    }

    enum Defaults {
        static let transport = "tcp"
        static let host = "192.168.1.39"
        static let port = 23
        static let serialPath = ""
        static let baud = 115200
        static let pollMs = 200
        static let jogFeed = 500.0
        /// 0 = continuous jog.
        static let jogStep = 1.0
        static let jogSegmentMs = 50
        static let probeFeedFast = 100.0
        static let probeFeedSlow = 20.0
        static let probeMaxTravel = 20.0
        static let probeRetract = 2.0
        /// 0: the bit touches the copper itself (clip on the board).
        static let probePlateThickness = 0.0
        static let safeZWork = 5.0
        static let safeZBelowTop = 2.0
        static let spindleMin = 6000.0
        static let spindleMax = 12000.0
        static let spindleWarmupSeconds = 3.0
        static let autoReconnect = true
        static let consoleShowStatus = false
        static let applyBacklash = true
        static let fitArcs = false
        static let heightMapApplyBelowZ = 1.0
        /// Continue after a tool change runs at once; on, the preamble sheet asks first.
        static let confirmContinue = false
        static let confirmSend = true
        static let autoSaveWorkZero = true
        static let streamWindowBytes = 0
        /// The built-in simulator is a developer/try-out feature: hidden from
        /// the connection picker unless asked for in Settings.
        static let showSimulator = false
        static let simBoardX = 11.0
        static let simBoardY = 71.0
        static let simBoardThickness = 1.6
        static let configFilename = ""
    }

    /// Step sizes offered by the jog pad; 0 (continuous) is a separate UI entry.
    static let jogStepPresets: [Double] = [0.01, 0.1, 1, 5, 10]
    static let jogFeedPresets: [Double] = [10, 50, 100, 500, 1000, 2000]

    // MARK: - Typed accessors

    private static var defaults: UserDefaults { .standard }

    static var transport: String {
        get { defaults.string(forKey: Keys.transport) ?? Defaults.transport }
        set { defaults.set(newValue, forKey: Keys.transport) }
    }
    static var host: String {
        get { defaults.string(forKey: Keys.host) ?? Defaults.host }
        set { defaults.set(newValue, forKey: Keys.host) }
    }
    static var port: Int {
        get { int(Keys.port, Defaults.port) }
        set { defaults.set(newValue, forKey: Keys.port) }
    }
    static var serialPath: String {
        get { defaults.string(forKey: Keys.serialPath) ?? Defaults.serialPath }
        set { defaults.set(newValue, forKey: Keys.serialPath) }
    }
    static var baud: Int {
        get { int(Keys.baud, Defaults.baud) }
        set { defaults.set(newValue, forKey: Keys.baud) }
    }
    static var pollMs: Int {
        get { int(Keys.pollMs, Defaults.pollMs) }
        set { defaults.set(newValue, forKey: Keys.pollMs) }
    }
    static var jogFeed: Double {
        get { double(Keys.jogFeed, Defaults.jogFeed) }
        set { defaults.set(newValue, forKey: Keys.jogFeed) }
    }
    static var jogStep: Double {
        get { double(Keys.jogStep, Defaults.jogStep) }
        set { defaults.set(newValue, forKey: Keys.jogStep) }
    }
    static var jogSegmentMs: Int {
        get { int(Keys.jogSegmentMs, Defaults.jogSegmentMs) }
        set { defaults.set(newValue, forKey: Keys.jogSegmentMs) }
    }
    static var probeFeedFast: Double {
        get { double(Keys.probeFeedFast, Defaults.probeFeedFast) }
        set { defaults.set(newValue, forKey: Keys.probeFeedFast) }
    }
    static var probeFeedSlow: Double {
        get { double(Keys.probeFeedSlow, Defaults.probeFeedSlow) }
        set { defaults.set(newValue, forKey: Keys.probeFeedSlow) }
    }
    static var probeMaxTravel: Double {
        get { double(Keys.probeMaxTravel, Defaults.probeMaxTravel) }
        set { defaults.set(newValue, forKey: Keys.probeMaxTravel) }
    }

    /// Where the Simulator lays its PCB on the bed (machine XY of the
    /// lower-left corner) and how thick it is; the preset work zero sits on
    /// the board's top at that corner.
    static var simBoardX: Double {
        get { double(Keys.simBoardX, Defaults.simBoardX) }
        set { defaults.set(newValue, forKey: Keys.simBoardX) }
    }
    static var simBoardY: Double {
        get { double(Keys.simBoardY, Defaults.simBoardY) }
        set { defaults.set(newValue, forKey: Keys.simBoardY) }
    }
    static var simBoardThickness: Double {
        get { double(Keys.simBoardThickness, Defaults.simBoardThickness) }
        set { defaults.set(newValue, forKey: Keys.simBoardThickness) }
    }
    static var probeRetract: Double {
        get { double(Keys.probeRetract, Defaults.probeRetract) }
        set { defaults.set(newValue, forKey: Keys.probeRetract) }
    }
    static var probePlateThickness: Double {
        get { double(Keys.probePlateThickness, Defaults.probePlateThickness) }
        set { defaults.set(newValue, forKey: Keys.probePlateThickness) }
    }
    static var safeZWork: Double {
        get { double(Keys.safeZWork, Defaults.safeZWork) }
        set { defaults.set(newValue, forKey: Keys.safeZWork) }
    }
    static var safeZBelowTop: Double {
        get { double(Keys.safeZBelowTop, Defaults.safeZBelowTop) }
        set { defaults.set(newValue, forKey: Keys.safeZBelowTop) }
    }
    static var spindleMin: Double {
        get { double(Keys.spindleMin, Defaults.spindleMin) }
        set { defaults.set(newValue, forKey: Keys.spindleMin) }
    }
    static var spindleMax: Double {
        get { double(Keys.spindleMax, Defaults.spindleMax) }
        set { defaults.set(newValue, forKey: Keys.spindleMax) }
    }
    static var spindleWarmupSeconds: Double {
        get { double(Keys.spindleWarmupSeconds, Defaults.spindleWarmupSeconds) }
        set { defaults.set(newValue, forKey: Keys.spindleWarmupSeconds) }
    }
    static var autoReconnect: Bool {
        get { bool(Keys.autoReconnect, Defaults.autoReconnect) }
        set { defaults.set(newValue, forKey: Keys.autoReconnect) }
    }
    static var consoleShowStatus: Bool {
        get { bool(Keys.consoleShowStatus, Defaults.consoleShowStatus) }
        set { defaults.set(newValue, forKey: Keys.consoleShowStatus) }
    }
    static var fitArcs: Bool {
        get { bool(Keys.fitArcs, Defaults.fitArcs) }
        set { defaults.set(newValue, forKey: Keys.fitArcs) }
    }
    static var applyBacklash: Bool {
        get { bool(Keys.applyBacklash, Defaults.applyBacklash) }
        set { defaults.set(newValue, forKey: Keys.applyBacklash) }
    }
    static var heightMapApplyBelowZ: Double {
        get { double(Keys.heightMapApplyBelowZ, Defaults.heightMapApplyBelowZ) }
        set { defaults.set(newValue, forKey: Keys.heightMapApplyBelowZ) }
    }
    static var confirmContinue: Bool {
        get { bool(Keys.confirmContinue, Defaults.confirmContinue) }
        set { defaults.set(newValue, forKey: Keys.confirmContinue) }
    }
    static var confirmSend: Bool {
        get { bool(Keys.confirmSend, Defaults.confirmSend) }
        set { defaults.set(newValue, forKey: Keys.confirmSend) }
    }
    static var streamWindowBytes: Int {
        get { defaults.object(forKey: Keys.streamWindowBytes) == nil ? Defaults.streamWindowBytes : defaults.integer(forKey: Keys.streamWindowBytes) }
        set { defaults.set(newValue, forKey: Keys.streamWindowBytes) }
    }
    static var autoSaveWorkZero: Bool {
        get { bool(Keys.autoSaveWorkZero, Defaults.autoSaveWorkZero) }
        set { defaults.set(newValue, forKey: Keys.autoSaveWorkZero) }
    }
    static var showSimulator: Bool {
        get { bool(Keys.showSimulator, Defaults.showSimulator) }
        set { defaults.set(newValue, forKey: Keys.showSimulator) }
    }

    // MARK: - Macros

    /// A named list of lines sent one after another, like a tiny program.
    /// Every macro is also a user button on the Control tab: `icon` is an
    /// optional SF Symbol for it, and `allowWhileRunning` keeps the button
    /// enabled while a program is streaming (the lines then go out between
    /// the program's — only for short commands such as `M8`/`M9`).
    struct Macro: Codable, Identifiable, Equatable, Sendable {
        var id: UUID
        var name: String
        var lines: [String]
        var icon: String?
        var allowWhileRunning: Bool

        init(id: UUID = UUID(), name: String, lines: [String], icon: String? = nil, allowWhileRunning: Bool = false) {
            self.id = id
            self.name = name
            self.lines = lines
            self.icon = icon
            self.allowWhileRunning = allowWhileRunning
        }

        private enum CodingKeys: String, CodingKey { case id, name, lines, icon, allowWhileRunning }

        /// `id` is optional in the JSON so a hand-written defaults entry still loads.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            lines = try container.decodeIfPresent([String].self, forKey: .lines) ?? []
            let symbol = try container.decodeIfPresent(String.self, forKey: .icon)?.trimmingCharacters(in: .whitespaces)
            icon = (symbol?.isEmpty ?? true) ? nil : symbol
            allowWhileRunning = try container.decodeIfPresent(Bool.self, forKey: .allowWhileRunning) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(lines, forKey: .lines)
            try container.encodeIfPresent(icon, forKey: .icon)
            if allowWhileRunning { try container.encode(true, forKey: .allowWhileRunning) }
        }
    }

    static let defaultMacros: [Macro] = [
        Macro(name: "Spindle warm-up", lines: ["M3 S6000", "G4 P3", "M3 S12000", "G4 P3", "M5"], icon: "fan.fill"),
        Macro(name: "Go to work zero", lines: ["G90 G0 Z5", "G0 X0 Y0"], icon: "scope"),
        Macro(name: "Spindle & coolant off", lines: ["M5", "M9"], icon: "power"),
    ]

    /// A fixed conductive spot on the machine bed (a block or a switch-type
    /// tool setter wired in parallel with the probe input). Probing it before
    /// and after a bit change measures the stickout difference, so work Z0
    /// can be restored when the board surface itself can no longer be probed
    /// (a solder-masked board). A machine property, like backlash — never a
    /// project field.
    struct ToolReference: Codable, Equatable {
        /// Machine XY of the spot.
        var x: Double
        var y: Double
        /// Machine Z of the probe contact (PRB) when the reference was set.
        var contactZ: Double
        /// Machine Z of work Z0 (the work offset's Z) when it was set.
        var workZeroZ: Double
        var savedAt: Date
    }

    /// Stored as a JSON string, like `macros`.
    static var toolReference: ToolReference? {
        get {
            guard let text = defaults.string(forKey: Keys.toolReference), let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ToolReference.self, from: data)
        }
        set {
            guard let newValue else { defaults.removeObject(forKey: Keys.toolReference); return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(newValue), let text = String(data: data, encoding: .utf8) else { return }
            defaults.set(text, forKey: Keys.toolReference)
        }
    }

    /// Stored as a JSON string (`[{"name":…,"lines":[…]}]`) so it is readable
    /// and editable with `defaults read`. Unset or unreadable → `defaultMacros`.
    static var macros: [Macro] {
        get {
            guard let text = defaults.string(forKey: Keys.macros), let data = text.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([Macro].self, from: data) else {
                return defaultMacros
            }
            return decoded
        }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(newValue), let text = String(data: data, encoding: .utf8) else { return }
            defaults.set(text, forKey: Keys.macros)
        }
    }

    // MARK: - DRO buttons

    /// The built-in actions the DRO's button grid can hold. The first eight
    /// are the default grid; the rest are offered in Customize Buttons…
    enum DROBuiltIn: String, CaseIterable, Sendable {
        case zeroXY, zeroZ, zeroAll, probeZ, workZero, safeZ, home, unlock
        case spindle, coolant, hold, resume, reset, sleep

        var title: String {
            switch self {
            case .zeroXY: String(localized: "Zero XY")
            case .zeroZ: String(localized: "Zero Z")
            case .zeroAll: String(localized: "Zero All")
            case .probeZ: String(localized: "Probe Z")
            case .workZero: String(localized: "Work Zero")
            case .safeZ: String(localized: "Safe Z")
            case .home: String(localized: "Home")
            case .unlock: String(localized: "Unlock")
            case .spindle: String(localized: "Spindle")
            case .coolant: String(localized: "Coolant")
            case .hold: String(localized: "Hold")
            case .resume: String(localized: "Resume")
            case .reset: String(localized: "Reset")
            case .sleep: String(localized: "Sleep")
            }
        }

        var symbol: String {
            switch self {
            case .zeroXY: "scope"
            case .zeroZ: "arrow.down.to.line.compact"
            case .zeroAll: "target"
            case .probeZ: "arrow.down.to.line"
            case .workZero: "house"
            case .safeZ: "arrow.up.to.line"
            case .home: "house.fill"
            case .unlock: "lock.open"
            case .spindle: "fan.fill"
            case .coolant: "drop.fill"
            case .hold: "pause.fill"
            case .resume: "play.fill"
            case .reset: "arrow.counterclockwise"
            case .sleep: "moon.zzz"
            }
        }

        var help: String {
            switch self {
            case .zeroXY: String(localized: "Make the current position work X0 Y0 (G10 L20)")
            case .zeroZ: String(localized: "Make the current position work Z0 (G10 L20)")
            case .zeroAll: String(localized: "Make the current position work X0 Y0 Z0 (G10 L20)")
            case .probeZ: String(localized: "Two-pass Z touch-off with the settings of the Probe tab; work Z is set at the trigger point")
            case .workZero: String(localized: "Go to work zero: rapid up to the safe work Z, then to work X0 Y0")
            case .safeZ: String(localized: "Rapid Z to just below the top of travel (G53)")
            case .home: String(localized: "$H — home every axis")
            case .unlock: String(localized: "$X — clear the alarm without homing")
            case .spindle: String(localized: "M3/M5 — spindle on or off at the default speed (orange while it runs)")
            case .coolant: String(localized: "M8/M9 — flood coolant on or off")
            case .hold: String(localized: "! — feed hold (decelerate and wait)")
            case .resume: String(localized: "~ — cycle start / resume")
            case .reset: String(localized: "Ctrl‑X soft reset — stops everything; position is lost if the machine was moving")
            case .sleep: String(localized: "$SLP — sleep: spindle and steppers off until a reset")
            }
        }
    }

    /// One cell of the DRO's button grid: a built-in action or a macro of
    /// `macros` (by id). Stored as strings — `"zeroXY"`, `"macro:<uuid>"` —
    /// so `defaults read` shows the layout.
    enum DROButton: Hashable, Sendable {
        case builtIn(DROBuiltIn)
        case macro(UUID)

        var storageString: String {
            switch self {
            case .builtIn(let action): action.rawValue
            case .macro(let id): "macro:" + id.uuidString
            }
        }

        init?(storageString: String) {
            let text = storageString.trimmingCharacters(in: .whitespaces)
            if let action = DROBuiltIn(rawValue: text) {
                self = .builtIn(action)
            } else if text.hasPrefix("macro:"), let id = UUID(uuidString: String(text.dropFirst(6))) {
                self = .macro(id)
            } else {
                return nil
            }
        }
    }

    /// Two rows of four: the grid as it was before it became customizable.
    static let defaultDROButtons: [DROButton] =
        ([.zeroXY, .zeroZ, .zeroAll, .probeZ, .workZero, .safeZ, .home, .unlock] as [DROBuiltIn]).map(DROButton.builtIn)

    /// Unset or unreadable → `defaultDROButtons`. Unknown entries are
    /// skipped and duplicates folded so the grid's `ForEach` keys stay unique.
    static var droButtons: [DROButton] {
        get {
            guard let text = defaults.string(forKey: Keys.droButtons), let data = text.data(using: .utf8),
                  let strings = try? JSONDecoder().decode([String].self, from: data) else {
                return defaultDROButtons
            }
            var seen = Set<DROButton>()
            return strings.compactMap(DROButton.init(storageString:)).filter { seen.insert($0).inserted }
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue.map(\.storageString)),
                  let text = String(data: data, encoding: .utf8) else { return }
            defaults.set(text, forKey: Keys.droButtons)
        }
    }

    // MARK: - Helpers

    /// `object(forKey:)` rather than `integer(forKey:)` so an unset key yields the
    /// default instead of 0, and a value typed as a string (from `defaults write`)
    /// is still accepted.
    private static func int(_ key: String, _ fallback: Int) -> Int {
        switch defaults.object(forKey: key) {
        case let value as Int: value
        case let value as Double: Int(value)
        case let value as String: Int(value.trimmingCharacters(in: .whitespaces)) ?? fallback
        default: fallback
        }
    }

    private static func double(_ key: String, _ fallback: Double) -> Double {
        switch defaults.object(forKey: key) {
        case let value as Double where value.isFinite: value
        case let value as Int: Double(value)
        case let value as String: Double(value.trimmingCharacters(in: .whitespaces)) ?? fallback
        default: fallback
        }
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        switch defaults.object(forKey: key) {
        case let value as Bool: value
        case let value as Int: value != 0
        case let value as String: (value as NSString).boolValue
        default: fallback
        }
    }
}
