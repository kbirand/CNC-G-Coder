import Foundation
import Observation
import CoreGraphics

// The GRBL / FluidNC session, ported from the pendant's GRBLController and
// grown into the machine window's model: connection lifecycle over either
// transport, identification, status polling with a deadline and dead-link
// detection, one serialized send queue, the acknowledgement FIFO shared in
// order with the job streamer, jogging, zeroing, probing, overrides and the
// console. Everything runs on the main actor; the transports are actors.

nonisolated enum GRBLCommandError: LocalizedError {
    case controllerError(code: Int)
    case alarm(code: Int)
    case cancelled
    case disconnected
    case notReady(MachineState)
    case refused(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .controllerError(let code): "error:\(code) — \(GRBLError.description(for: code))"
        case .alarm(let code): "ALARM:\(code) — \(GRBLAlarm.description(for: code))"
        case .cancelled: "Command cancelled."
        case .disconnected: "Not connected to the controller."
        case .notReady(let state): "Machine is \(state.name); wait until it is Idle."
        case .refused(let reason): reason
        case .timeout: "No reply from the controller."
        }
    }

    var code: Int? {
        if case .controllerError(let code) = self { return code }
        return nil
    }
}

@MainActor
@Observable
final class MachineController {

    weak var app: AppModel?

    enum Phase: Equatable, Sendable { case disconnected, connecting, connected, unresponsive }

    // MARK: Observable state

    private(set) var phase: Phase = .disconnected
    private(set) var transportKind: TransportKind?
    private(set) var endpointDescription = ""
    private(set) var firmware = FirmwareInfo()
    private(set) var status = GRBLStatus() {
        didSet {
            // Coarse, rarely-changing views of the report, for views that
            // must not re-render on every poll (the window title, enable
            // states, the 3D scene): Observation fires on every assignment,
            // so these are only written when they actually change.
            if machineState != status.state { machineState = status.state }
            let known = status.workPosition != nil
            if positionKnown != known { positionKnown = known }
            let spindle = status.spindleSpeed > 0 || status.accessories.contains("S") || status.accessories.contains("C")
            if spindleRunning != spindle { spindleRunning = spindle }
            // The WCO cache is only ever replaced by a reported one: GRBL
            // sends it every few reports, and WPos-only reports need it.
            if let wco = status.workOffset, workOffset != wco { workOffset = wco }
        }
    }
    /// `status.state`, published only when it changes.
    private(set) var machineState: MachineState = GRBLStatus().state
    /// A work position has been reported (published only when that changes).
    private(set) var positionKnown = false
    /// The report says the spindle turns (S > 0 or the CW/CCW accessory flag).
    private(set) var spindleRunning = false
    private(set) var alarmCode: Int?
    /// False after an alarm that loses position or a reset while moving;
    /// Go-to, Safe Z, Probe and Send stay disabled until `$H` or an explicit Unlock.
    private(set) var positionTrusted = true
    /// True after a successful `$H`, or at connect when the controller is not
    /// in alarm and reports a position.
    private(set) var homed = false
    /// Machine-coordinate travel per axis (FluidNC `$/axes/…`, Grbl `$130–132`).
    private(set) var axisRanges: [Axis: ClosedRange<Double>] = [:]
    /// Where homing leaves each axis (machine coordinates), when known.
    private(set) var homePosition: [Axis: Double] = [:]
    /// `[GC:…]` words.
    private(set) var parserState: [String] = []
    /// "G54"…"G59", "G28", "G30", "G92", "TLO" (z).
    private(set) var offsets: [String: MachinePosition] = [:]
    private(set) var lastError: String?
    /// A program was running when the link dropped (see stopSpindleAfterLostJob).
    private var jobLostLink = false

    /// Dismisses the error line in the window.
    func clearError() { lastError = nil }
    private(set) var isContinuousJogging = false

    struct ProbeResult: Equatable, Sendable {
        var position: MachinePosition
        var success: Bool
        var date: Date
    }
    private(set) var lastProbe: ProbeResult?

    struct ConsoleEntry: Identifiable, Equatable, Sendable {
        enum Direction: Sendable { case sent, received, info, warning, error, status }
        let id: UUID
        let date: Date
        let direction: Direction
        let text: String
    }
    private(set) var console: [ConsoleEntry] = []
    var consoleShowStatus = MachineSettings.consoleShowStatus
    private(set) var commandHistory: [String] = []

    let streamer = JobStreamer()
    let positions = SavedPositionsStore()

    /// Whether a FluidNC axis has soft limits (long-jog mode needs them).
    private(set) var softLimits: [Axis: Bool] = [:]

    var isConnected: Bool { phase == .connected || phase == .unresponsive }
    var isStreaming: Bool { streamer.isActive }
    /// A job that is running, paused or stopping blocks manual commands;
    /// a suspended one (tool change) hands the machine back to the operator.
    var jobBlocksCommands: Bool { streamer.isActive && !streamer.isSuspended }
    var canJog: Bool { phase == .connected && machineState.allowsJog && alarmCode == nil && !jobBlocksCommands }
    var canMove: Bool { phase == .connected && machineState.allowsMotion && alarmCode == nil && !isContinuousJogging && !jobBlocksCommands }
    var isSuspendedForToolChange: Bool {
        if case .suspended(.toolChange) = streamer.state { return true }
        return false
    }
    var canProbe: Bool { canMove && positionTrusted && workOffset != nil }
    var activeWCS: String { parserState.first { $0.hasPrefix("G5") && $0.count == 3 } ?? "G54" }

    var statusSummary: String {
        switch phase {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .unresponsive: return "Unresponsive"
        case .connected: break
        }
        if let alarmCode {
            let text = GRBLAlarm.description(for: alarmCode)
            let short = text.split(separator: ".").first.map(String.init) ?? text
            return "Alarm \(alarmCode) — \(short)"
        }
        return machineState.name
    }

    // MARK: Private state

    private enum Endpoint {
        case tcp(host: String, port: UInt16), serial(path: String, baud: Int)
        /// The bundled simulator, launched by `SimulatorLauncher` on a free port at connect.
        case simulator

        var isSimulator: Bool { if case .simulator = self { return true } else { return false } }
    }

    /// A send-response line waiting for its `ok`/`error:`. `probe` carries
    /// the `[PRB:]` printed before the ack when the line was a `G38`.
    private final class PendingAck {
        let line: String
        let continuation: CheckedContinuation<Void, Error>
        var probe: (position: MachinePosition, success: Bool)?
        var timeoutTask: Task<Void, Never>?
        var pausesPolling = false
        /// The continuation was already resumed (timed out, or failed); the
        /// entry stays in `ackOrder` as a tombstone so the late reply keeps
        /// the FIFO in step instead of being taken for the next line's.
        var resumed = false
        init(line: String, continuation: CheckedContinuation<Void, Error>) {
            self.line = line
            self.continuation = continuation
        }
    }

    /// Who the next acknowledgement belongs to, in send order: the
    /// controller's own commands and the streamer's lines share one queue
    /// because the firmware answers strictly in order.
    private enum AckOwner { case command(PendingAck), job }

    private struct Outbound {
        let data: Data
    }

    private var transport: (any MachineTransport)?
    private var endpoint: Endpoint?
    private var readerTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var jogTask: Task<Void, Never>?
    private var identifyTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var outbound: [Outbound] = []
    private var ackOrder: [AckOwner] = []
    /// Cached `WCO:` — GRBL only reports it every few status lines.
    /// The last reported work offset (WCO), published only when it changes.
    private(set) var workOffset: MachinePosition?
    @ObservationIgnored private var statusSerial = 0
    /// The reported work position interpolated between status reports (see
    /// MotionInterpolator): the 3D bit samples it every rendered frame, the
    /// 2D marker and the reveal read `smoothedWorkPosition`, refreshed at
    /// ~30 Hz while connected.
    let motion = MotionInterpolator()
    private(set) var smoothedWorkPosition: MachinePosition?
    private var motionTask: Task<Void, Never>?
    private var inboundSerial = 0
    private var pollMisses = 0
    private var pollPausedCount = 0
    private var awaitingFirstReport = false
    private var settingsSeen: [String: String] = [:]
    /// A probe sequence left the parser in G91 (it failed mid-way): send
    /// `G90` as soon as the controller accepts G-code again.
    private var needsG90Restore = false
    private var userDisconnected = false

    private static let consoleLimit = 2000
    private static let historyLimit = 100
    private static let pollMissLimit = 10

    init() {
        streamer.controller = self
    }

    // MARK: - Connection lifecycle

    /// Connects with the Machine settings (transport, host/port or serial path).
    func connect() async {
        switch TransportKind(rawValue: MachineSettings.transport) ?? .tcp {
        case .serial: await connect(serialPath: MachineSettings.serialPath, baud: MachineSettings.baud)
        case .simulator: await connectSimulator()
        case .tcp: await connect(tcpHost: MachineSettings.host, port: UInt16(clamping: MachineSettings.port))
        }
    }

    /// Launches the built-in FluidNC simulator and connects to it.
    func connectSimulator() async {
        await connect(to: .simulator)
    }

    func connect(tcpHost: String, port: UInt16) async {
        let host = tcpHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { lastError = "Enter the controller's address."; return }
        await connect(to: .tcp(host: host, port: port))
    }

    func connect(serialPath: String, baud: Int) async {
        let path = serialPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { lastError = "Choose a serial port."; return }
        await connect(to: .serial(path: path, baud: baud))
    }

    private func connect(to endpoint: Endpoint) async {
        guard phase == .disconnected else { return }
        phase = .connecting
        lastError = nil
        alarmCode = nil
        status = GRBLStatus()
        workOffset = nil
        firmware = FirmwareInfo()
        axisRanges = [:]
        homePosition = [:]
        softLimits = [:]
        parserState = []
        offsets = [:]
        homed = false
        positionTrusted = true
        pollMisses = 0
        pollPausedCount = 0
        userDisconnected = false
        self.endpoint = endpoint

        let transport: any MachineTransport
        let kind: TransportKind
        let description: String
        switch endpoint {
        case .tcp(let host, let port):
            transport = TCPTransport(host: host, port: port)
            kind = .tcp
            description = transport.endpointDescription
        case .serial(let path, let baud):
            transport = SerialTransport(path: path, baud: baud)
            kind = .serial
            description = transport.endpointDescription
        case .simulator:
            log(.info, "Starting the simulator…")
            let port: UInt16
            do {
                port = try await SimulatorLauncher.shared.start()
            } catch {
                phase = .disconnected
                lastError = error.localizedDescription
                log(.error, error.localizedDescription)
                let tail = await SimulatorLauncher.shared.logTail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty, !error.localizedDescription.contains(tail) {
                    for line in tail.split(separator: "\n").suffix(20) { log(.error, "simulator: \(line)") }
                }
                return
            }
            transport = TCPTransport(host: "127.0.0.1", port: port)
            kind = .simulator
            description = "Simulator (\(SimulatorLauncher.firmwareDescription), port \(port))"
        }
        log(.info, "Connecting to \(description)…")
        do {
            try await transport.open()
        } catch {
            phase = .disconnected
            lastError = error.localizedDescription
            log(.error, error.localizedDescription)
            if endpoint.isSimulator { await SimulatorLauncher.shared.stop() }
            return
        }
        for warning in await transport.takeWarnings() { log(.warning, warning) }

        self.transport = transport
        transportKind = kind
        endpointDescription = description
        phase = .connected
        awaitingFirstReport = true
        log(.info, "Connected to \(description).")

        readerTask = Task { [weak self] in
            for await line in transport.lines {
                self?.handle(line: line)
            }
            self?.handleDisconnect()
        }
        startPolling()
        await identify()
    }

    func disconnect() async {
        userDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await closeLink()
        if endpoint?.isSimulator == true { await SimulatorLauncher.shared.stop() }
    }

    private func closeLink() async {
        stopContinuousJog()
        pollTask?.cancel()
        readerTask?.cancel()
        identifyTask?.cancel()
        let transport = self.transport
        await transport?.close()
        handleDisconnect()
    }

    private func handleDisconnect() {
        guard phase != .disconnected else { return }
        pollTask?.cancel()
        readerTask?.cancel()
        identifyTask?.cancel()
        sendTask?.cancel()
        pollTask = nil
        readerTask = nil
        identifyTask = nil
        sendTask = nil
        jogTask?.cancel()
        jogTask = nil
        isContinuousJogging = false
        outbound.removeAll()
        transport = nil
        phase = .disconnected
        failPendingAcks(with: .disconnected)
        if streamer.isActive { jobLostLink = true }
        streamer.noteLinkLost()
        status = GRBLStatus()
        homed = false
        motionTask?.cancel()
        motionTask = nil
        motion.reset()
        smoothedWorkPosition = nil
        log(.info, "Disconnected.")
        // A simulator whose link dropped is of no further use; a reconnect
        // launches a fresh one. (A user disconnect stops it in `disconnect()`.)
        if !userDisconnected, endpoint?.isSimulator == true { Task { await SimulatorLauncher.shared.stop() } }
        if !userDisconnected, MachineSettings.autoReconnect { startReconnect() }
    }

    private func startReconnect() {
        guard reconnectTask == nil, let endpoint else { return }
        reconnectTask = Task { [weak self] in
            for attempt in 1...20 {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.phase == .disconnected else { break }
                self.log(.info, "Reconnecting (attempt \(attempt))…")
                await self.connect(to: endpoint)
                if self.phase == .connected { break }
            }
            self?.reconnectTask = nil
        }
    }

    // MARK: - Identification

    /// `$I`, `$G`, `$#` and the axis ranges. Runs at connect and after every
    /// banner (reset); each query times out on its own so a board that is
    /// still booting cannot hang the sequence.
    private func identify() async {
        identifyTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runIdentify()
        }
        identifyTask = task
        await task.value
    }

    private func runIdentify() async {
        settingsSeen.removeAll()
        let timeout: Duration = .seconds(5)
        do { try await sendInternal(GRBLCommand.buildInfo, timeout: timeout) } catch { log(.warning, "$I: \(error.localizedDescription)") }
        if Task.isCancelled { return }
        if firmware.kind == .unknown, let banner = firmware.banner, let info = FirmwareInfo.parse(banner: banner) {
            firmware = info
        }
        do { try await sendInternal(GRBLCommand.parserState, timeout: timeout) } catch { log(.warning, "$G: \(error.localizedDescription)") }
        if Task.isCancelled { return }
        do { try await sendInternal(GRBLCommand.offsets, timeout: timeout) } catch { log(.warning, "$#: \(error.localizedDescription)") }
        if Task.isCancelled { return }
        seedWorkOffset()
        await restoreG90IfNeeded(timeout: timeout)
        await stopSpindleAfterLostJob(timeout: timeout)
        if Task.isCancelled { return }

        switch firmware.kind {
        case .fluidnc:
            for axis in Axis.allCases {
                let name = axis.rawValue.lowercased()
                let keys = ["axes/\(name)/max_travel_mm", "axes/\(name)/homing/mpos_mm",
                            "axes/\(name)/homing/positive_direction", "axes/\(name)/soft_limits"]
                for key in keys {
                    do { try await sendInternal(GRBLCommand.fluidNCSetting(key), timeout: timeout) } catch { break }
                    if Task.isCancelled { return }
                }
                let travel = settingsSeen["$/axes/\(name)/max_travel_mm"].flatMap(Double.init)
                let mpos = settingsSeen["$/axes/\(name)/homing/mpos_mm"].flatMap(Double.init) ?? 0
                let directionKey = "$/axes/\(name)/homing/positive_direction"
                if settingsSeen[directionKey] == nil {
                    log(.warning, "\(axis.rawValue): homing direction not reported — assuming it homes toward +; the travel box may be mirrored.")
                }
                let positive = (settingsSeen[directionKey] ?? "true").lowercased() == "true"
                softLimits[axis] = (settingsSeen["$/axes/\(name)/soft_limits"] ?? "false").lowercased() == "true"
                if let travel, travel > 0 {
                    axisRanges[axis] = positive ? (mpos - travel)...mpos : mpos...(mpos + travel)
                    homePosition[axis] = mpos
                }
            }
        case .grbl:
            do { try await sendInternal(GRBLCommand.settings, timeout: timeout) } catch { log(.warning, "$$: \(error.localizedDescription)") }
            if Task.isCancelled { return }
            for (axis, key) in [(Axis.x, "$130"), (.y, "$131"), (.z, "$132")] {
                if let travel = settingsSeen[key].flatMap(Double.init), travel > 0 {
                    axisRanges[axis] = (-travel)...0
                    homePosition[axis] = 0
                }
            }
        case .unknown:
            break
        }
        let ranges = Axis.allCases.compactMap { axis -> String? in
            guard let range = axisRanges[axis] else { return nil }
            return "\(axis.rawValue) \(GRBLCommand.number(range.lowerBound))…\(GRBLCommand.number(range.upperBound))"
        }
        log(.info, "Identified \(firmware.description)" + (ranges.isEmpty ? "" : " — travel " + ranges.joined(separator: ", ")) + ".")
    }

    /// The parser is in G91 (a probe sequence that failed mid-way, before or
    /// after a reconnect): the flag is derived from `$G`, and `G90` is sent
    /// as soon as the controller accepts G-code — now, unless it is in alarm
    /// (then `unlock`/`home` do it).
    /// A program died with the link: the controller kept its last M3, so
    /// the bit may be spinning in the copper. Stop it as soon as we are back.
    private func stopSpindleAfterLostJob(timeout: Duration) async {
        guard jobLostLink else { return }
        jobLostLink = false
        _ = await waitForStatus(timeout: 2) { _ in true }
        let s = status
        let spinning = s.spindleSpeed > 0 || s.accessories.contains("S") || s.accessories.contains("C")
        guard spinning || s.state.isHoldComplete || s.state == .run else { return }
        log(.warning, "Reconnected after the program was cut off — stopping the spindle.")
        if case .hold = s.state {
            // Held by our last-ditch `!`: a reset ends the hold and the spindle together.
            sendRealtime(GRBLRealtime.softReset)
            _ = await waitForStatus(timeout: 3) { $0.state == .idle || $0.state == .alarm }
        }
        do { try await sendInternal(GRBLCommand.spindleOff, timeout: timeout) } catch { log(.warning, "M5: \(error.localizedDescription)") }
        lastError = "The program was cut off by the connection; the spindle has been stopped. Check the bit, then use Send from line… to resume."
    }

    private func restoreG90IfNeeded(timeout: Duration) async {
        needsG90Restore = parserState.contains("G91")
        guard needsG90Restore, alarmCode == nil, status.state != .alarm else { return }
        do {
            try await sendInternal("G90", timeout: timeout)
            needsG90Restore = false
            log(.info, "The parser was in G91 — G90 restored.")
        } catch {
            log(.warning, "G90: \(error.localizedDescription)")
        }
    }

    /// WCO = active G5x + G92 + TLO, from `$#`, so a `WPos`-only controller
    /// has a machine position before its first `WCO:` field.
    private func seedWorkOffset() {
        guard workOffset == nil, let base = offsets[activeWCS] else { return }
        var wco = base
        if let g92 = offsets["G92"] {
            wco.x += g92.x; wco.y += g92.y; wco.z += g92.z
        }
        if let tlo = offsets["TLO"] { wco.z += tlo.z }
        workOffset = wco
    }

    // MARK: - Inbound lines

    private func handle(line: String) {
        inboundSerial += 1
        pollMisses = 0
        let response = GRBLResponse.classify(line)

        switch response {
        case .status:
            guard var parsed = GRBLStatus.parse(line, lastWorkOffset: workOffset) else { return }
            // Overrides, accessories and the buffer state are only reported
            // every few reports (or on change): carry the last known values
            // so the readouts do not blink between a value and "—".
            let reportedOverrides = parsed.overrides != nil   // A: only ever comes with Ov:
            if !reportedOverrides {
                parsed.overrides = status.overrides
                parsed.accessories = status.accessories
            }
            if parsed.plannerBlocks == nil { parsed.plannerBlocks = status.plannerBlocks; parsed.rxBytes = status.rxBytes }
            status = parsed
            statusSerial += 1
            if let work = parsed.workPosition { recordPositionSample(work) }
            if phase == .unresponsive {
                phase = .connected
                log(.info, "Link recovered.")
            }
            if parsed.state != .alarm, alarmCode != nil { alarmCode = nil }
            if awaitingFirstReport {
                awaitingFirstReport = false
                if parsed.state != .alarm, parsed.hasPosition { homed = true }
            }
            if consoleShowStatus { log(.status, line) }
            streamer.noteStatus(parsed)

        case .ok:
            if case .command(let entry) = ackOrder.first, !entry.resumed { log(.received, line) }
            popAck(response)

        case .error(let code):
            log(code == 130 ? .info : .error, line + (code == 130 ? "" : " — " + GRBLError.description(for: code)))
            popAck(response)

        case .alarm(let code):
            // Never touches the FIFO: the alarming line still gets its own
            // ok/error:. It does stop everything that moves.
            alarmCode = code
            if GRBLAlarm.losesPosition(code) { positionTrusted = false }
            lastError = GRBLCommandError.alarm(code: code).localizedDescription
            log(.error, "ALARM:\(code) — \(GRBLAlarm.description(for: code))")
            stopContinuousJog()
            streamer.noteResponse(response, forLine: nil)

        case .welcome(let text):
            bannerReceived(text)

        case .probe(let position, let success):
            lastProbe = ProbeResult(position: position, success: success, date: Date())
            log(.received, line)
            switch ackOrder.first {
            case .job: streamer.noteResponse(response, forLine: nil)
            case .command(let entry): if entry.line.uppercased().hasPrefix("G38") { entry.probe = (position, success) }
            case nil: break
            }

        case .message(let text):
            log(text.hasPrefix("ERR") ? .warning : .info, line)

        case .parserState(let words):
            parserState = words
            log(.received, line)

        case .offset(let name, let position):
            offsets[name] = position
            log(.received, line)

        case .version:
            if let info = FirmwareInfo.parse(versionLine: line) {
                var merged = info
                merged.banner = firmware.banner
                firmware = merged
            }
            log(.received, line)

        case .setting(let key, let value):
            settingsSeen[key] = value
            log(.received, line)

        case .options, .other:
            log(.received, line)
        }
    }

    private func popAck(_ response: GRBLResponse) {
        guard let head = ackOrder.first else { return }
        ackOrder.removeFirst()
        switch head {
        case .job:
            streamer.noteResponse(response, forLine: nil)
        case .command(let entry):
            // A timed-out line's late reply: consumed, nothing to resume.
            guard !entry.resumed else { return }
            entry.resumed = true
            entry.timeoutTask?.cancel()
            if entry.pausesPolling { pollPausedCount = max(0, pollPausedCount - 1) }
            switch response {
            case .error(let code): entry.continuation.resume(throwing: GRBLCommandError.controllerError(code: code))
            default: entry.continuation.resume(returning: ())
            }
        }
    }

    private func failPendingAcks(with error: GRBLCommandError) {
        let waiting = ackOrder
        ackOrder.removeAll()
        pollPausedCount = 0
        for owner in waiting {
            if case .command(let entry) = owner, !entry.resumed {
                entry.resumed = true
                entry.timeoutTask?.cancel()
                entry.continuation.resume(throwing: error)
            }
        }
    }

    /// Any banner means the controller restarted: whatever was in flight is
    /// gone, the parser is back to defaults, and the firmware is asked again.
    private func bannerReceived(_ text: String) {
        log(.info, text)
        if let info = FirmwareInfo.parse(banner: text) {
            if firmware.kind == .unknown || info.kind != firmware.kind { firmware = info } else { firmware.banner = text }
        }
        failPendingAcks(with: .cancelled)
        streamer.noteBanner()
        status = GRBLStatus()
        alarmCode = nil
        awaitingFirstReport = true
        jogTask?.cancel()
        jogTask = nil
        isContinuousJogging = false
        statusSerial += 1   // re-arm the poll loop at once
        identifyTask?.cancel()
        identifyTask = Task { [weak self] in
            guard let self else { return }
            await self.runIdentify()
        }
    }

    // MARK: - Sending

    /// Sends a G-code or `$` line and waits for its `ok` (throws on
    /// `error:N`, alarm, reset or disconnect). Refused while a job is
    /// running, paused or stopping — a suspended job hands the machine back.
    func send(_ line: String, log: Bool = true) async throws {
        guard !jobBlocksCommands else { throw GRBLCommandError.refused("A program is being sent — stop it first.") }
        try await sendInternal(line, log: log)
    }

    /// The send-response path without the job guard: for the streamer's own
    /// drain/park/restore lines and the controller's sequences.
    func sendInternal(_ line: String, log: Bool = true, timeout: Duration? = nil) async throws {
        _ = try await sendEntry(line, log: log, timeout: timeout)
    }

    private func sendEntry(_ line: String, log shouldLog: Bool, timeout: Duration?) async throws -> PendingAck {
        guard transport != nil, isConnected else { throw GRBLCommandError.disconnected }
        var pending: PendingAck?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let entry = PendingAck(line: line, continuation: continuation)
            pending = entry
            ackOrder.append(.command(entry))
            var timeout = timeout
            if pausesPolling(line) {
                entry.pausesPolling = true
                pollPausedCount += 1
                // Polling must not stay paused for good when the ack never
                // comes; the tombstone in `ackOrder` absorbs a late one.
                if timeout == nil { timeout = .seconds(5) }
            }
            if let timeout {
                entry.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.timeOut(entry)
                }
            }
            if shouldLog { self.log(.sent, line) }
            enqueue(Data((line + "\n").utf8))
        }
        guard let pending else { throw GRBLCommandError.cancelled }
        return pending
    }

    /// Same as `sendInternal`, returning the `[PRB:]` the controller
    /// printed for this line (nil when it printed none).
    private func sendExpectingProbe(_ line: String) async throws -> (position: MachinePosition, success: Bool)? {
        try await sendEntry(line, log: true, timeout: nil).probe
    }

    /// The caller stops waiting, but the entry stays in `ackOrder`: the
    /// firmware answers strictly in order, so the reply that eventually
    /// comes (an EEPROM write finishing, a slow `$I`) must still pop this
    /// entry and not the one behind it. Only the controller's own commands
    /// have timeouts; the streamer's lines (and its `StreamWindow`) never do.
    private func timeOut(_ entry: PendingAck) {
        guard !entry.resumed, ackOrder.contains(where: {
            if case .command(let e) = $0 { return e === entry }
            return false
        }) else { return }
        entry.resumed = true
        if entry.pausesPolling { pollPausedCount = max(0, pollPausedCount - 1) }
        log(.warning, "No reply to \(entry.line).")
        entry.continuation.resume(throwing: GRBLCommandError.timeout)
    }

    /// Lines that make a Grbl board write EEPROM (its RX interrupt is off
    /// meanwhile, so a `?` would be lost). Only over USB serial on Grbl.
    private func pausesPolling(_ line: String) -> Bool {
        guard firmware.kind == .grbl, transportKind == .serial else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces).uppercased()
        if trimmed.hasPrefix("$"), trimmed.contains("="), !trimmed.hasPrefix("$J=") { return true }
        if trimmed.hasPrefix("$RST") { return true }
        let words = GCodeWords.scan(line)
        return words.contains { $0.letter == "G" && ($0.value == 10 || $0.value == 28.1 || $0.value == 30.1) }
    }

    /// A program line from the streamer: queued in order, acknowledged
    /// through the streamer, not echoed in the console (a job is thousands
    /// of lines).
    func enqueueJobLine(_ text: String) {
        guard transport != nil, isConnected else { return }
        ackOrder.append(.job)
        enqueue(Data((text + "\n").utf8))
    }

    /// Sends a real-time byte ahead of anything queued. Never acknowledged.
    func sendRealtime(_ byte: UInt8) {
        guard transport != nil, isConnected else { return }
        if byte != GRBLRealtime.statusReport { log(.sent, GRBLRealtime.label(byte)) }
        enqueue(Data([byte]), urgent: true)
    }

    private func enqueue(_ data: Data, urgent: Bool = false) {
        if urgent { outbound.insert(Outbound(data: data), at: 0) } else { outbound.append(Outbound(data: data)) }
        pump()
    }

    /// One task writes the queue in order; it ends when the queue is empty
    /// and is started again by the next enqueue.
    private func pump() {
        guard sendTask == nil, let transport else { return }
        sendTask = Task { [weak self] in
            while let self, !self.outbound.isEmpty {
                let item = self.outbound.removeFirst()
                do {
                    try await transport.send(data: item.data)
                } catch {
                    self.lastError = error.localizedDescription
                    self.log(.error, "Write failed: \(error.localizedDescription)")
                    // The transport closed itself; the reader will notice.
                    break
                }
            }
            self?.sendTask = nil
            if self?.outbound.isEmpty == false { self?.pump() }
        }
    }

    func sync() async throws {
        try await sendInternal(GRBLCommand.sync)
    }

    /// From the console field: records history; single real-time characters
    /// go out as such.
    func sendConsoleCommand(_ text: String) async {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if commandHistory.last != line {
            commandHistory.append(line)
            if commandHistory.count > Self.historyLimit { commandHistory.removeFirst(commandHistory.count - Self.historyLimit) }
        }
        switch line {
        case "?":
            let shown = consoleShowStatus
            consoleShowStatus = true
            sendRealtime(GRBLRealtime.statusReport)
            _ = await waitForStatus(timeout: 1) { _ in true }
            consoleShowStatus = shown
            return
        case "!": feedHold(); return
        case "~": resume(); return
        default: break
        }
        do {
            try await send(line)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Polling

    /// `?` every `pollMs`; after each one, wait for the next report or
    /// `max(2 × pollMs, 500 ms)` — a lost `?` (Grbl writing EEPROM) must not
    /// stop polling for good. Ten deadlines in a row with no inbound line
    /// at all mean the link is dead even though writes still succeed.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isConnected else { return }
                // Twice as often while a program runs: the live marker and
                // the follow mode move with every report.
                let interval = self.streamer.isActive ? max(MachineSettings.pollMs / 2, 50) : max(MachineSettings.pollMs, 50)
                if self.pollPausedCount > 0 {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                let before = self.statusSerial
                let inboundBefore = self.inboundSerial
                let start = ContinuousClock.now
                self.sendRealtime(GRBLRealtime.statusReport)
                let deadline = start + .milliseconds(max(2 * interval, 500))
                while self.statusSerial == before, ContinuousClock.now < deadline, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if Task.isCancelled { return }
                if self.statusSerial == before, self.inboundSerial == inboundBefore {
                    self.pollMisses += 1
                    if self.pollMisses == Self.pollMissLimit { self.linkUnresponsive() }
                }
                let elapsed = start.duration(to: ContinuousClock.now)
                let rest = Duration.milliseconds(interval) - elapsed
                if rest > .zero { try? await Task.sleep(for: rest) }
            }
        }
    }

    private func linkUnresponsive() {
        guard phase == .connected else { return }
        phase = .unresponsive
        lastError = "The controller stopped answering."
        log(.warning, "No reply from the controller for \(Self.pollMissLimit) status polls — link unresponsive.")
        if streamer.isActive {
            // The socket may still carry bytes one way: a feed hold costs
            // nothing and stops the buffered moves if it gets through.
            jobLostLink = true
            sendRealtime(GRBLRealtime.feedHold)
        }
        streamer.noteLinkLost()
        if MachineSettings.autoReconnect {
            Task { [weak self] in
                guard let self else { return }
                await self.closeLink()
            }
        }
    }

    /// Waits for a status report that satisfies `predicate` (polling keeps
    /// running meanwhile; an extra `?` is sent right away).
    func waitForStatus(timeout: TimeInterval, _ predicate: (GRBLStatus) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var seen = statusSerial
        sendRealtime(GRBLRealtime.statusReport)
        while ContinuousClock.now < deadline {
            guard isConnected else { return false }
            if statusSerial != seen {
                seen = statusSerial
                if predicate(status) { return true }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return predicate(status)
    }

    // MARK: - Machine controls

    /// `Hold` (any sub-state): a queued `G4 P0` cannot be acknowledged here.
    private var isHeld: Bool {
        if case .hold = status.state { return true }
        return false
    }

    func feedHold() { sendRealtime(GRBLRealtime.feedHold) }
    func resume() { sendRealtime(GRBLRealtime.cycleStart) }
    func door() { sendRealtime(GRBLRealtime.safetyDoor) }

    /// Ctrl-X. Resetting while anything moves loses steps, so the position
    /// is only trusted afterwards when the machine was at rest.
    func softReset() async {
        let atRest: Bool
        switch status.state {
        case .idle, .alarm, .check, .sleep: atRest = true
        case .hold(let sub): atRest = sub == 0
        default: atRest = false
        }
        if !atRest { positionTrusted = false }
        jogTask?.cancel()
        jogTask = nil
        isContinuousJogging = false
        sendRealtime(GRBLRealtime.softReset)
        failPendingAcks(with: .cancelled)
        statusSerial += 1
    }

    /// Cancels whatever moves: the app's jog loop and the controller's jog
    /// always, a feed hold only when something is running (a `!` in Idle
    /// would park the machine in `Hold:0`). A running job gets the
    /// streamer's full stop sequence.
    func stop() async {
        if streamer.isActive, !streamer.isSuspended {
            await streamer.stop()
            return
        }
        let wasJogging = isContinuousJogging || jogTask != nil
        stopContinuousJog()
        sendRealtime(GRBLRealtime.jogCancel)
        var held = false
        switch status.state {
        case .run, .hold, .door: held = true
        default: break
        }
        if held {
            feedHold()
        } else if !wasJogging, !isHeld {
            // The jog loop ends with its own sync; otherwise flush here.
            try? await sync()
        }
    }

    /// E-STOP: everything at once, nothing waited for. The app's jog loop is
    /// cancelled, then jog cancel (0x85), feed hold (`!`) and soft reset
    /// (0x18) go out in one write — GRBL acts on real-time characters as
    /// they arrive, so the reset lands milliseconds after the hold. A job
    /// ends as "Emergency stop" before the controller's banner arrives (the
    /// banner then runs the usual re-identify). The position is only
    /// distrusted when the machine was in motion (Run, Jog, decelerating
    /// Hold): a reset at rest loses nothing.
    func emergencyStop() {
        guard transport != nil, isConnected else { return }
        let wasMoving: Bool
        switch status.state {
        case .run, .jog: wasMoving = true
        case .hold(let sub): wasMoving = sub != 0
        default: wasMoving = false
        }
        jogTask?.cancel()
        jogTask = nil
        isContinuousJogging = false
        log(.error, "EMERGENCY STOP (0x85 ! 0x18)")
        enqueue(Data([GRBLRealtime.jogCancel, GRBLRealtime.feedHold, GRBLRealtime.softReset]), urgent: true)
        if wasMoving { positionTrusted = false }
        streamer.noteEmergencyStop()
        failPendingAcks(with: .cancelled)
        lastError = wasMoving ? "Emergency stop — the machine was moving: home before the next move." : "Emergency stop."
        app?.appendLog("[machine] EMERGENCY STOP\n")
        statusSerial += 1
    }

    func unlock() async {
        do {
            try await send(GRBLCommand.unlock)
            alarmCode = nil
            lastError = nil
            // Unlock keeps the position as-is (FluidNC also marks the axes homed).
            positionTrusted = true
            if firmware.kind == .fluidnc { homed = true }
            if needsG90Restore {
                needsG90Restore = false
                try? await send("G90")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func home() async {
        do {
            try await send(GRBLCommand.home)
            alarmCode = nil
            homed = true
            positionTrusted = true
            workOffset = nil
            try? await send(GRBLCommand.offsets)
            seedWorkOffset()
            if needsG90Restore {
                needsG90Restore = false
                try? await send("G90")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func checkMode(_ on: Bool) async {
        guard on != (status.state == .check) else { return }
        do { try await send(GRBLCommand.checkMode) } catch { lastError = error.localizedDescription }
    }

    func sleep() async {
        guard status.state == .idle else { lastError = "Sleep is only allowed when Idle."; return }
        do { try await send(GRBLCommand.sleep) } catch { lastError = error.localizedDescription }
    }

    func spindle(on: Bool, rpm: Double) async {
        let line: String
        if on {
            let clamped = min(max(rpm, MachineSettings.spindleMin), MachineSettings.spindleMax)
            if clamped != rpm { log(.info, "Spindle speed clamped to \(Int(clamped)) rpm.") }
            line = GRBLCommand.spindleOn(rpm: clamped)
        } else {
            line = GRBLCommand.spindleOff
        }
        do { try await send(line) } catch { lastError = error.localizedDescription }
    }

    func coolant(flood: Bool) async {
        do { try await send(flood ? "M8" : GRBLCommand.coolantOff) } catch { lastError = error.localizedDescription }
    }

    // MARK: Overrides (real-time; `Ov:` in the status report is the display)

    /// −10, −1, 0 (= reset to 100 %), +1, +10.
    func overrideFeed(_ delta: Int) {
        switch delta {
        case ..<(-5): sendRealtime(GRBLRealtime.feedMinus10)
        case -5..<0: sendRealtime(GRBLRealtime.feedMinus1)
        case 0: sendRealtime(GRBLRealtime.feedReset)
        case 1...5: sendRealtime(GRBLRealtime.feedPlus1)
        default: sendRealtime(GRBLRealtime.feedPlus10)
        }
    }

    /// 25, 50 or 100 %.
    func overrideRapid(_ percent: Int) {
        switch percent {
        case ...25: sendRealtime(GRBLRealtime.rapid25)
        case 26...50: sendRealtime(GRBLRealtime.rapid50)
        default: sendRealtime(GRBLRealtime.rapid100)
        }
    }

    func overrideSpindle(_ delta: Int) {
        switch delta {
        case ..<(-5): sendRealtime(GRBLRealtime.spindleMinus10)
        case -5..<0: sendRealtime(GRBLRealtime.spindleMinus1)
        case 0: sendRealtime(GRBLRealtime.spindleReset)
        case 1...5: sendRealtime(GRBLRealtime.spindlePlus1)
        default: sendRealtime(GRBLRealtime.spindlePlus10)
        }
    }

    // MARK: - Coordinates

    /// `G10 L20 P0 …`: the current position becomes zero on those axes
    /// (persistent, unlike G92).
    func zero(axes: [Axis]) async {
        guard !axes.isEmpty else { return }
        guard canMove || streamer.isSuspended else { lastError = "Zeroing needs the machine Idle."; return }
        do {
            try await send(GRBLCommand.zero(axes: axes))
            log(.info, "Zeroed " + axes.map(\.rawValue).joined() + ".")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setAxis(_ axis: Axis, workValue: Double) async {
        guard canMove || streamer.isSuspended else { lastError = "Setting a coordinate needs the machine Idle."; return }
        do { try await send(GRBLCommand.setAxis(axis, workValue: workValue)) } catch { lastError = error.localizedDescription }
    }

    /// `G10 L2 P0 X Y Z`: the work origin goes back to a stored machine
    /// point without any motion — the way to restore a work zero after a
    /// reset or re-homing. `$#` is read back so the DRO shows the new work
    /// coordinates before the controller's next `WCO:` field.
    func setWorkOrigin(machine target: MachinePosition) async {
        guard isConnected else { lastError = "Not connected."; return }
        guard !jobBlocksCommands else { lastError = "A program is being sent — stop it first."; return }
        guard alarmCode == nil, status.state != .alarm else { lastError = "Clear the alarm first."; return }
        guard status.state == .idle || streamer.isSuspended else {
            lastError = "Setting the work origin needs the machine Idle (now \(status.state.name))."
            return
        }
        do {
            try await send(GRBLCommand.setOrigin(machine: target))
            log(.info, "Work origin set to machine \(target.summary) (no motion).")
            workOffset = nil
            try? await send(GRBLCommand.offsets)
            seedWorkOffset()
            if workOffset == nil { workOffset = target }
            statusSerial += 1
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Up to the work safe height (only when below it — never down to it),
    /// then to work X0 Y0. Both legs pass the travel pre-flight first.
    func goToWorkZero() async {
        guard canMove else { lastError = GRBLCommandError.notReady(status.state).localizedDescription; return }
        guard positionTrusted else { lastError = "Position may be lost — home first."; return }
        guard status.workOffset != nil, let work = status.workPosition else {
            lastError = "Work offset unknown — wait for a status report."
            return
        }
        // Rise to the safe work Z first, but never above the top of travel:
        // zeroed near the top (fresh after homing) the safe height would be
        // out of range and the move must not be refused for that.
        var safeZ = MachineSettings.safeZWork
        if let range = axisRanges[.z], let wco = status.workOffset {
            safeZ = min(safeZ, range.upperBound - wco.z - 0.5)
        }
        var lines: [String] = []
        if work.z < safeZ - 1e-6 { lines.append("G90 G0 Z" + GRBLCommand.number(safeZ)) }
        lines.append("G90 G0 X0 Y0")
        if let reason = preflight(lines: lines) {
            lastError = reason
            log(.warning, "Go to work zero refused: " + reason)
            return
        }
        lastError = nil
        do {
            for line in lines { try await send(line) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// `G53 G90 G0 Z<top − safeZBelowTop>`; nil while the Z range is unknown
    /// or the machine is not homed.
    func safePositionLine() -> String? {
        guard homed, positionTrusted, let range = axisRanges[.z] else { return nil }
        return GRBLCommand.safePosition(machineZ: range.upperBound - MachineSettings.safeZBelowTop)
    }

    func safePosition() async {
        guard let line = safePositionLine() else {
            lastError = homed ? "Z travel unknown — the firmware did not report it." : "Home the machine first."
            return
        }
        guard canMove else { lastError = GRBLCommandError.notReady(status.state).localizedDescription; return }
        do { try await send(line) } catch { lastError = error.localizedDescription }
    }

    /// Absolute machine move in the Z-first / Z-last safe order.
    func goTo(machine target: MachinePosition, feed: Double) async throws {
        guard isConnected else { throw GRBLCommandError.disconnected }
        guard status.state.allowsMotion, alarmCode == nil else { throw GRBLCommandError.notReady(status.state) }
        guard homed, positionTrusted else { throw GRBLCommandError.refused("Home the machine before moving to machine coordinates.") }
        guard let current = status.machinePosition else { throw GRBLCommandError.refused("Machine position unknown.") }
        if let reason = travelViolation(machine: target) { throw GRBLCommandError.refused(reason) }
        for leg in GRBLCommand.safeMoveLegs(from: current, to: target, feed: feed) {
            try await send(leg)
        }
    }

    private func travelViolation(machine p: MachinePosition, label: String = "Target") -> String? {
        guard let wco = status.workOffset else { return nil }
        for axis in Axis.allCases {
            guard let range = axisRanges[axis], let kind = PreflightIssue.Kind(axis: axis, machine: p[axis], range: range) else { continue }
            let issue = PreflightIssue(axis: axis, line: 0, work: p[axis] - wco[axis], machine: p[axis], kind: kind)
            return travelSentence(issue, subject: label, range: range, wco: wco)
        }
        return nil
    }

    /// One readable sentence for a travel violation: what the line reaches,
    /// by how much it misses the travel, and what to do about it.
    private func travelSentence(_ issue: PreflightIssue, subject: String, range: ClosedRange<Double>, wco: MachinePosition) -> String {
        func mm(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: "-0.0", with: "0.0") }
        let axis = issue.axis.rawValue
        switch issue.kind {
        case .aboveTop:
            let over = issue.machine - range.upperBound
            let headroom = range.upperBound - wco.z
            let zero = headroom < 0.05 ? "work Z0 is at the very top" : "work Z0 is only \(mm(headroom)) mm below the top"
            return "Can't send: \(subject) rises to Z \(mm(issue.work)), which is \(mm(over)) mm above the top of Z travel (\(zero)). Zero Z on the board surface, lower Travel/Tool-change Z in the sidebar, or use Clamp Z."
        case .belowBottom:
            let under = range.lowerBound - issue.machine
            return "Can't send: \(subject) goes to Z \(mm(issue.work)) (machine \(mm(issue.machine))), which is \(mm(under)) mm below the bottom of Z travel. Zero Z higher on the board or reduce the cutting depth."
        case .outside:
            return "Can't send: \(subject) reaches \(axis) \(mm(issue.work)) (machine \(mm(issue.machine))), outside the \(mm(range.lowerBound))…\(mm(range.upperBound)) mm travel. Move the work zero away from the edge or change 'X0 Y0 at' in Machine setup."
        }
    }

    /// The work Z that keeps a program just inside the top of Z travel —
    /// what "Clamp Z to top" replaces higher Z words with. Nil until the
    /// travel and the work offset are known.
    func clampZWork() -> Double? {
        guard let range = axisRanges[.z], let wco = status.workOffset else { return nil }
        return range.upperBound - wco.z - 0.5
    }

    // MARK: - Jogging

    /// One relative step.
    func jog(axis: Axis, direction: JogDirection, distance: Double, feed: Double) async {
        await jog(vector: [axis: direction.sign * abs(distance)], feed: feed)
    }

    func jog(vector: [Axis: Double], feed: Double) async {
        guard canJog, !vector.isEmpty, feed > 0 else { return }
        do {
            try await send(GRBLCommand.jog(vector: vector, feed: feed))
        } catch let error as GRBLCommandError {
            switch error.code {
            case 130: break
            case 15: lastError = "Jog target exceeds the machine travel."
            default: lastError = error.localizedDescription
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Hold-to-jog. FluidNC with soft limits on the axis (and homed) gets one
    /// long jog that the firmware clamps to the travel, cancelled on
    /// release; otherwise short segments are fed in step with the wall
    /// clock — never more than three in flight nor ~200 ms ahead — so a
    /// release overruns by at most a few segments even on Grbl, which
    /// cannot cancel a segment it has already started.
    func startContinuousJog(directions: [Axis: JogDirection], feed: Double) {
        guard canJog, jogTask == nil, !directions.isEmpty, feed > 0 else { return }
        isContinuousJogging = true
        let longVector = longJogVector(directions)
        jogTask = Task { [weak self] in
            guard let self else { return }
            if let longVector {
                await self.runLongJog(vector: longVector, feed: feed)
            } else {
                await self.runSegmentJog(directions: directions, feed: feed)
            }
            self.isContinuousJogging = false
            self.jogTask = nil
        }
    }

    /// Releases the jog: the loop sees the flag, the cancel goes out now.
    func stopContinuousJog() {
        guard isContinuousJogging || jogTask != nil else { return }
        isContinuousJogging = false
        sendRealtime(GRBLRealtime.jogCancel)
    }

    /// The long-jog distances (to each limit, minus a hair) when every axis
    /// qualifies; nil to use segments instead.
    private func longJogVector(_ directions: [Axis: JogDirection]) -> [Axis: Double]? {
        guard firmware.kind == .fluidnc, homed, positionTrusted, let position = status.machinePosition else { return nil }
        var vector: [Axis: Double] = [:]
        for (axis, direction) in directions {
            guard softLimits[axis] == true, let range = axisRanges[axis] else { return nil }
            let remaining = direction == .positive ? range.upperBound - position[axis] : position[axis] - range.lowerBound
            let distance = remaining - 0.1
            guard distance > 0.05 else {
                lastError = "\(axis.rawValue) is at its limit."
                return [:]
            }
            vector[axis] = direction.sign * distance
        }
        return vector
    }

    private func runLongJog(vector: [Axis: Double], feed: Double) async {
        guard !vector.isEmpty else { return }
        do {
            try await sendInternal(GRBLCommand.jog(vector: vector, feed: feed))
        } catch let error as GRBLCommandError {
            if error.code != 130 { lastError = error.localizedDescription }
        } catch {
            lastError = error.localizedDescription
        }
        var reports = 0
        var seen = statusSerial
        while isContinuousJogging {
            try? await Task.sleep(for: .milliseconds(20))
            if statusSerial != seen {
                seen = statusSerial
                reports += 1
                // Back to Idle after it started moving: the limit was reached.
                if reports >= 2, status.state == .idle { break }
            }
        }
        isContinuousJogging = false
        sendRealtime(GRBLRealtime.jogCancel)
        // A sync in Hold would wait for an ack that cannot come until the
        // hold is released, leaving `jogTask` set and jogging refused.
        if !isHeld { try? await sync() }
    }

    /// Counters the segment tasks share (all on the main actor).
    private final class JogCounters {
        var sent = 0
        var acked = 0
        var inFlight = 0
        var stalled: String?
    }

    private func runSegmentJog(directions: [Axis: JogDirection], feed: Double) async {
        let segmentMs = max(MachineSettings.jogSegmentMs, 10)
        let segmentDistance = max(feed / 60 * Double(segmentMs) / 1000, 0.01)
        let line = GRBLCommand.jog(vector: directions.mapValues { $0.sign * segmentDistance }, feed: feed)
        let counters = JogCounters()
        let t0 = ContinuousClock.now
        var seen = statusSerial
        var recentPositions: [MachinePosition] = []

        while isContinuousJogging, counters.stalled == nil {
            // Stall guard: once two segments are acknowledged, an Idle state
            // or a position that no longer changes means the axis stopped.
            if statusSerial != seen {
                seen = statusSerial
                if counters.acked >= 2 {
                    if status.state == .idle { counters.stalled = "axis at limit"; break }
                    if let position = status.machinePosition {
                        recentPositions.append(position)
                        if recentPositions.count > 3 { recentPositions.removeFirst() }
                        if recentPositions.count == 3, recentPositions.allSatisfy({ $0 == recentPositions[0] }) {
                            counters.stalled = "axis at limit"
                            break
                        }
                    }
                }
            }
            let elapsedMs = t0.duration(to: ContinuousClock.now).seconds * 1000
            let aheadMs = Double(counters.sent * segmentMs) - elapsedMs
            if counters.inFlight >= 3 || aheadMs > 200 {
                try? await Task.sleep(for: .milliseconds(min(segmentMs, 20)))
                continue
            }
            counters.sent += 1
            counters.inFlight += 1
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.sendInternal(line, log: false)
                    counters.acked += 1
                } catch let error as GRBLCommandError {
                    switch error.code {
                    case 130: break
                    case 15: counters.stalled = "axis at limit"
                    default: counters.stalled = error.localizedDescription
                    }
                } catch {
                    counters.stalled = error.localizedDescription
                }
                counters.inFlight -= 1
            }
        }
        if let stalled = counters.stalled { log(.info, "Jog stopped: \(stalled).") }
        isContinuousJogging = false
        sendRealtime(GRBLRealtime.jogCancel)
        // A sync in Hold would wait for an ack that cannot come until the
        // hold is released, leaving `jogTask` set and jogging refused.
        if !isHeld { try? await sync() }
    }


    // MARK: - Position smoothing

    private func recordPositionSample(_ position: MachinePosition) {
        motion.push(position, at: ProcessInfo.processInfo.systemUptime)
        if smoothedWorkPosition == nil { smoothedWorkPosition = position }
        if motionTask == nil { startMotionTicks() }
    }

    /// ~30 Hz: publishes the interpolated position for the SwiftUI side.
    private func startMotionTicks() {
        motionTask?.cancel()
        motionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                guard self.isConnected else { self.motionTask = nil; return }
                guard let next = self.motion.position(at: ProcessInfo.processInfo.systemUptime) else { continue }
                if let current = self.smoothedWorkPosition, Self.distance(current, next) < 1e-4 { continue }
                self.smoothedWorkPosition = next
                if UserDefaults.standard.bool(forKey: "debugMotionLog") {
                    print(String(format: "[smooth] %.4f %.4f %.4f %.4f", ProcessInfo.processInfo.systemUptime, next.x, next.y, next.z))
                }
            }
        }
    }

    private static func distance(_ a: MachinePosition, _ b: MachinePosition) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
    }

    // MARK: - Probing

    /// Two-pass Z touch-off at the current XY: fast down, back off, slow
    /// down, then the active system's Z origin is placed at the trigger
    /// point (minus the plate). Nil on success; the message otherwise.
    func probeZ() async -> String? {
        guard isConnected else { return "Not connected." }
        guard !jobBlocksCommands else { return "A program is being sent." }
        guard status.state == .idle else { return "The machine must be Idle to probe (now \(status.state.name))." }
        guard alarmCode == nil else { return "Clear the alarm first." }
        guard positionTrusted else { return "Position may be lost — home the machine first." }
        guard status.workOffset != nil else { return "Work offset unknown — wait for a status report." }
        guard !status.pins.contains("P") else { return "Probe already triggered — check the clip and the bit." }

        let spec = ZProbeSpec(maxTravel: MachineSettings.probeMaxTravel, feedFast: MachineSettings.probeFeedFast,
                              feedSlow: MachineSettings.probeFeedSlow, retract: MachineSettings.probeRetract,
                              plateThickness: MachineSettings.probePlateThickness)
        var remaining: Double?
        if let position = status.machinePosition, let range = axisRanges[.z] { remaining = position.z - range.lowerBound }
        if let reason = ProbeRoutines.validate(spec, remainingZTravel: remaining) { return reason }
        if let g92 = offsets["G92"], g92 != .zero { log(.warning, "A G92 offset is active (\(g92.summary)); the probe sets the \(activeWCS) origin.") }
        if let tlo = offsets["TLO"], tlo.z != 0 { log(.warning, "A tool length offset of \(GRBLCommand.number(tlo.z)) is active.") }

        let head = ProbeRoutines.zProbeHead(spec)
        log(.info, "Probing Z: fast \(GRBLCommand.number(spec.maxTravel)) mm at F\(Int(spec.feedFast)), slow at F\(Int(spec.feedSlow)), plate \(GRBLCommand.number(spec.plateThickness)).")
        do {
            try await sendInternal(head[0])
            needsG90Restore = true
            let fast = try await sendExpectingProbe(head[1])
            guard let fast, fast.success, alarmCode == nil else {
                return await probeFailed("The probe did not make contact within \(GRBLCommand.number(spec.maxTravel)) mm.")
            }
            try await sendInternal(head[2])
            let slow = try await sendExpectingProbe(head[3])
            guard let slow, slow.success, alarmCode == nil else {
                return await probeFailed("The probe lost contact on the slow pass.")
            }
            // On the contact point: make this position read `plate`.
            try await sendInternal(ProbeRoutines.originLine(plate: spec.plateThickness))
            // Read the offsets straight back (`$#`) so the DRO shows the new Z
            // at once (GRBL puts WCO: in a status report only every few
            // reports) and the controller's view can be checked.
            workOffset = nil
            try? await sendInternal(GRBLCommand.offsets)
            seedWorkOffset()
            statusSerial += 1
            let expectedOrigin = ProbeRoutines.expectedOrigin(prbMachineZ: slow.position.z, plate: spec.plateThickness)
            if let origin = offsets[activeWCS]?.z, abs(origin - expectedOrigin) > 0.05 {
                log(.warning, "\(activeWCS) Z origin reads \(GRBLCommand.number(origin)) after the probe, expected about \(GRBLCommand.number(expectedOrigin)) (PRB − plate); \(offsetsSummary).")
            }
            for line in ProbeRoutines.zProbeTail(spec) { try await sendInternal(line) }
            needsG90Restore = false
            // Verify against the controller's own report after the retract;
            // if the origin did not land, set it from here (the retract is
            // an exact incremental move from the contact point).
            let expected = spec.plateThickness + abs(spec.retract)
            var settled = await waitForFreshStatus(timeout: 4)
            var workZ = status.workPosition?.z
            if settled, let z = workZ, abs(z - expected) > 0.05 {
                log(.warning, "After the retract the controller reads work Z\(GRBLCommand.number(z)) instead of Z\(GRBLCommand.number(expected)); \(offsetsSummary); WCO \(status.workOffset?.summary ?? "?"). Setting the origin again from this position.")
                try await sendInternal("G10 L20 P0 Z" + GRBLCommand.number(expected))
                workOffset = nil
                try? await sendInternal(GRBLCommand.offsets)
                seedWorkOffset()
                statusSerial += 1
                settled = await waitForFreshStatus(timeout: 4)
                workZ = status.workPosition?.z
            }
            var note = "Probe Z: contact at machine Z \(GRBLCommand.number(slow.position.z)) → work Z\(GRBLCommand.number(spec.plateThickness)) there"
            if let origin = offsets[activeWCS]?.z { note += " (\(activeWCS) Z origin now \(GRBLCommand.number(origin)))" }
            if let workZ { note += "; after the \(GRBLCommand.number(abs(spec.retract))) mm retract the DRO reads Z\(GRBLCommand.number(workZ))" }
            log(.info, note + ".")
            if settled, let workZ, abs(workZ - expected) > 0.05 {
                let message = "Probe Z could not make the controller read Z\(GRBLCommand.number(expected)) after the retract (it reads Z\(GRBLCommand.number(workZ)); \(offsetsSummary); status WCO \(status.workOffset?.summary ?? "?")). Please send the Console lines from this probe."
                log(.warning, message)
                lastError = message
            }
            return nil
        } catch {
            return await probeFailed("Probe failed: \(error.localizedDescription)")
        }
    }

    /// `probeZ` at work X0/Y0: a height map is stored relative to the Z
    /// probed there, so after a tool change the new bit must be measured at
    /// the origin for the map to stay valid. Rapids across at the present
    /// (parked, safe) Z after the travel pre-flight, waits for the move to
    /// finish, then probes. Nil on success; the message otherwise.
    func probeZAtWorkOrigin() async -> String? {
        guard isConnected else { return "Not connected." }
        guard !jobBlocksCommands else { return "A program is being sent." }
        guard status.state == .idle else { return "The machine must be Idle to probe (now \(status.state.name))." }
        guard alarmCode == nil else { return "Clear the alarm first." }
        guard positionTrusted else { return "Position may be lost — home the machine first." }
        guard status.workOffset != nil else { return "Work offset unknown — wait for a status report." }
        let travel = "G90 G0 X0 Y0"
        if let reason = preflight(lines: [travel]) { return "Cannot move to the work origin: " + reason }
        log(.info, "Moving to work X0 Y0 to probe Z at the origin.")
        do {
            try await sendInternal(travel)
            try await sync()
        } catch {
            return "Could not move to the work origin: \(error.localizedDescription)"
        }
        guard await waitForStatus(timeout: 5, { $0.state == .idle }) else {
            return "The machine did not come to rest at the work origin (now \(status.state.name))."
        }
        return await probeZ()
    }

    /// `$#` as last read: the active system, G92 and TLO — the three parts of WCO.
    private var offsetsSummary: String {
        let wcs = offsets[activeWCS].map { "\(activeWCS) \($0.summary)" } ?? "\(activeWCS) unknown"
        let g92 = offsets["G92"].map { "G92 \($0.summary)" } ?? "G92 unknown"
        let tlo = offsets["TLO"].map { "TLO \(GRBLCommand.number($0.z))" } ?? "TLO unknown"
        return "$#: \(wcs), \(g92), \(tlo)"
    }

    /// Waits for the next status report after now (not one already parsed),
    /// then for Idle with a position. False on timeout.
    private func waitForFreshStatus(timeout: TimeInterval) async -> Bool {
        let before = statusSerial
        let deadline = ContinuousClock.now + .seconds(timeout)
        while statusSerial == before, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard statusSerial != before else { return false }
        return await waitForStatus(timeout: timeout) { $0.state == .idle && $0.workPosition != nil }
    }

    private func probeFailed(_ message: String) async -> String {
        log(.error, message)
        if alarmCode == nil, isConnected {
            try? await sendInternal("G90")
            needsG90Restore = false
        }
        return message
    }

    /// The machine position of design (0,0) for programs of `side` now:
    /// `(0,0).applying(T) + WCO` in XY, the work offset's Z — what a height
    /// map's `probedDesignOrigin` is compared with. Nil without a work offset.
    func currentDesignOrigin(side: BoardSide) -> MachinePosition? {
        guard let wco = status.workOffset else { return nil }
        let frame = app?.heightMapFrame(side: side) ?? .identity
        let p = CGPoint.zero.applying(frame)
        return MachinePosition(x: p.x + wco.x, y: p.y + wco.y, z: wco.z)
    }

    /// The machine's XY travel in work coordinates (needs the axis ranges
    /// from identification and a work offset).
    // MARK: - Axis calibration (FluidNC steps/mm)

    /// What `calibrateSteps` did, for the UI and the dev script.
    struct StepsChange {
        var axis: Axis
        var previous: Double
        var current: Double
        /// The config file the running config was dumped to, nil when not saved.
        var savedTo: String?
    }

    /// The firmware supports `$/axes/<a>/steps_per_mm` reads and writes.
    var supportsStepsCalibration: Bool { isConnected && firmware.kind == .fluidnc }

    private func settingPath(for axis: Axis) -> String { "axes/\(axis.rawValue.lowercased())/steps_per_mm" }

    /// Reads the controller's current steps/mm for an axis (`$/axes/x/steps_per_mm`).
    func readStepsPerMM(_ axis: Axis) async throws -> Double {
        guard supportsStepsCalibration else { throw GRBLCommandError.refused("Connect to a FluidNC controller first.") }
        let line = GRBLCommand.fluidNCSetting(settingPath(for: axis))
        try await sendInternal(line, timeout: .seconds(5))
        guard let text = settingsSeen[line], let value = Double(text) else {
            throw GRBLCommandError.refused("The controller did not report \(axis.rawValue) steps/mm.")
        }
        return value
    }

    /// The config file the controller booted from (`$Config/Filename`), e.g. "raptorex.yaml".
    func readConfigFilename() async throws -> String {
        guard supportsStepsCalibration else { throw GRBLCommandError.refused("Connect to a FluidNC controller first.") }
        try await sendInternal("$Config/Filename", timeout: .seconds(5))
        guard let name = settingsSeen["$Config/Filename"], !name.isEmpty else {
            throw GRBLCommandError.refused("The controller did not report its config filename.")
        }
        return name
    }

    /// The corrected steps/mm after a jog of `commanded` mm travelled `measured` mm.
    nonisolated static func correctedSteps(current: Double, commanded: Double, measured: Double) -> Double? {
        guard current > 0, commanded > 0, measured > 0 else { return nil }
        return current * commanded / measured
    }

    /// Writes a new steps/mm to the running config (`$/axes/x/steps_per_mm=`,
    /// effective at once) and, with `saveTo`, dumps the running config to that
    /// file (`$CD=<file>`) so it survives a reboot. Idle only.
    @discardableResult
    func writeStepsPerMM(_ axis: Axis, _ value: Double, saveTo file: String?) async throws -> StepsChange {
        guard supportsStepsCalibration else { throw GRBLCommandError.refused("Connect to a FluidNC controller first.") }
        guard machineState == .idle, alarmCode == nil else { throw GRBLCommandError.refused("The machine must be Idle to change steps/mm (now \(machineState.name)).") }
        guard value > 0, value.isFinite else { throw GRBLCommandError.refused("Steps/mm must be a positive number.") }
        let previous = (try? await readStepsPerMM(axis)) ?? 0
        let formatted = GRBLCommand.number(value)
        try await sendInternal("$/\(settingPath(for: axis))=\(formatted)", timeout: .seconds(5))
        var change = StepsChange(axis: axis, previous: previous, current: value, savedTo: nil)
        if let file, !file.isEmpty {
            try await sendInternal("$CD=\(file)", timeout: .seconds(10))
            change.savedTo = file
        }
        change.current = (try? await readStepsPerMM(axis)) ?? value
        log(.info, "\(axis.rawValue) steps/mm \(GRBLCommand.number(previous)) → \(GRBLCommand.number(change.current))" + (change.savedTo.map { ", saved to \($0)" } ?? " (running config only)"))
        return change
    }

    var workTravelRect: CGRect? {
        guard let x = axisRanges[.x], let y = axisRanges[.y], let wco = workOffset else { return nil }
        return CGRect(x: x.lowerBound - wco.x, y: y.lowerBound - wco.y,
                      width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound)
    }

    /// The top of the Z travel in work coordinates.
    var workTravelTopZ: Double? {
        guard let z = axisRanges[.z], let wco = workOffset else { return nil }
        return z.upperBound - wco.z
    }

    /// The bottom of the Z travel (the bed) in work coordinates.
    var workTravelBottomZ: Double? {
        guard let z = axisRanges[.z], let wco = workOffset else { return nil }
        return z.lowerBound - wco.z
    }

    /// The home corner (where homing leaves X and Y) in work coordinates.
    var workHomeCorner: CGPoint? {
        guard let x = homePosition[.x], let y = homePosition[.y], let wco = status.workOffset else { return nil }
        return CGPoint(x: x - wco.x, y: y - wco.y)
    }

    /// Probes a height map through the streamer; a completed map is stored
    /// for the project and saved, and the loaded program (if of that side
    /// and sent with the map) is prepared again with the new one. The
    /// frame (design → work) is taken once, at the start.
    func probeHeightMap(_ map: HeightMap) async {
        let frame = app?.heightMapFrame(side: map.side) ?? .identity
        await streamer.probe(map: map, frame: frame)
        guard streamer.state == .probing else { return }
        await streamer.waitUntilFinished()
        guard streamer.state == .completed, var result = streamer.heightMapTarget, result.isComplete else {
            log(.warning, "Height map not stored: \(streamer.lastMessage ?? "incomplete").")
            return
        }
        if let wco = status.workOffset {
            let p = CGPoint.zero.applying(frame)
            result.probedDesignOrigin = MachinePosition(x: p.x + wco.x, y: p.y + wco.y, z: wco.z)
        }
        result.probedAt = Date()
        result.firmwareVersion = firmware.description
        app?.saveHeightMap(result)
        let deviation = result.maxDeviation.map { String(format: "%.3f", $0) } ?? "?"
        log(.info, "Height map \(result.nx)×\(result.ny) stored (\(result.side.title) side, max deviation \(deviation) mm).")
        if applyHeightMap, streamer.program?.kind.boardSide == result.side { await reprepareLoadedProgram() }
    }

    /// Whether programs are prepared with their side's height map — the
    /// Program tab's "Apply height map" and the Height Map tab's "Use height
    /// map for sending" are the same switch.
    var applyHeightMap = false

    /// Prepares the loaded program again with the current `applyHeightMap`
    /// (and the stored map of its side), when that changes its options.
    /// Returns what went wrong, or nil.
    @discardableResult
    func reprepareLoadedProgram() async -> String? {
        guard let program = streamer.program, !streamer.isActive else { return nil }
        guard let layer = app?.preview.document?.layers.first(where: { $0.id == program.kind }) else { return nil }
        let map = applyHeightMap ? app?.heightMaps[program.kind.boardSide] : nil
        let options = ProgramOptions(applyBacklash: program.options.applyBacklash, heightMap: map,
                                     applyBelowZ: MachineSettings.heightMapApplyBelowZ,
                                     frame: app?.heightMapFrame(side: program.kind.boardSide) ?? .identity,
                                     clampZAboveWork: program.options.clampZAboveWork)
        guard options != program.options else { return nil }
        do {
            _ = try await prepareProgram(layer: layer, name: program.name, options: options)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Programs

    /// Prepares a layer's program off the main actor and loads it into the streamer.
    func prepareProgram(layer: ParsedLayer, name: String, options: ProgramOptions) async throws -> MachineProgram {
        guard !streamer.isActive else { throw GRBLCommandError.refused("A program is active — stop it first.") }
        let backlash = BacklashCompensation.Settings.current
        let fileURL = layer.fileURL
        let program = try await Task.detached(priority: .userInitiated) { () throws -> MachineProgram in
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            return try ProgramPreparer.prepare(sourceText: text, layer: layer, name: name, options: options, backlash: backlash)
        }.value
        // A prepare superseded by a newer selection (the Program tab cancels
        // its task) must not replace the program that selection loaded.
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: program.url)
            throw CancellationError()
        }
        streamer.load(program)
        for note in program.notes { log(.info, note) }
        app?.appendLog("[machine] Prepared \(program.name): " + program.notes.joined(separator: " ") + "\n")
        return program
    }

    /// Why the program cannot be sent now, or nil.
    func preflight(_ program: MachineProgram) -> String? {
        preflightResult(program)?.message
    }

    /// The pre-flight as data: readiness problems come back as a message
    /// alone; travel violations list every offending move (one issue per
    /// move and axis) so the UI can offer "Clamp Z to top" when the only
    /// trouble is Z above the top of travel. Nil when the program may go.
    func preflightResult(_ program: MachineProgram) -> PreflightResult? {
        if let reason = readinessProblem() { return PreflightResult(message: reason) }
        guard let wco = workOffset else { return PreflightResult(message: "Work offset unknown — wait for a status report.") }
        var issues: [PreflightIssue] = []
        for move in program.parsed.moves {
            let work = MachinePosition(x: move.end.x, y: move.end.y, z: move.zEnd)
            let machine = MachinePosition(x: work.x + wco.x, y: work.y + wco.y, z: work.z + wco.z)
            for axis in Axis.allCases {
                guard let range = axisRanges[axis], let kind = PreflightIssue.Kind(axis: axis, machine: machine[axis], range: range) else { continue }
                issues.append(PreflightIssue(axis: axis, line: move.sourceLine, work: work[axis], machine: machine[axis], kind: kind))
            }
        }
        guard let first = issues.first, let range = axisRanges[first.axis] else { return nil }
        var message = travelSentence(first, subject: "line \(first.line)", range: range, wco: wco)
        let lines = Set(issues.map(\.line)).count
        if lines > 1 { message += " \(lines) lines are affected in total." }
        let canClampZ = issues.allSatisfy { $0.axis == .z && $0.kind == .aboveTop }
        return PreflightResult(message: message, issues: issues, canClampZ: canClampZ,
                               clampZWork: canClampZ ? clampZWork() : nil)
    }

    /// The same travel check for a handful of lines (resume preamble, probe
    /// program): absolute work coordinates, `G53` lines in machine coordinates.
    func preflight(lines: [String]) -> String? {
        if let reason = readinessProblem() { return reason }
        guard let wco = status.workOffset else { return "Work offset unknown — wait for a status report." }
        var work = status.workPosition ?? .zero
        for (index, line) in lines.enumerated() {
            let words = GCodeWords.scan(line)
            guard GCodeWords.hasAxisWords(words) else { continue }
            let machineCoordinates = words.contains { $0.letter == "G" && $0.value == 53 }
            var target = machineCoordinates ? (status.machinePosition ?? .zero) : work
            for w in words {
                switch w.letter {
                case "X": target.x = w.value
                case "Y": target.y = w.value
                case "Z": target.z = w.value
                default: break
                }
            }
            let machine = machineCoordinates ? target
                : MachinePosition(x: target.x + wco.x, y: target.y + wco.y, z: target.z + wco.z)
            if let reason = travelViolation(machine: machine, label: "Line \(index + 1)") { return reason }
            if !machineCoordinates { work = target }
        }
        return nil
    }

    private func readinessProblem() -> String? {
        guard isConnected else { return "Not connected." }
        guard phase == .connected else { return "The controller is not answering." }
        guard alarmCode == nil else { return "Clear the alarm first (\(statusSummary))." }
        guard machineState == .idle else { return "The machine must be Idle (now \(machineState.name))." }
        guard positionTrusted else { return "Position may be lost — home the machine first." }
        guard homed else { return "Home the machine first." }
        return nil
    }

    /// The preamble that resumes the loaded program at `line` from the
    /// machine's present position (see `ProgramPreparer.resumePreamble`).
    func resumePreamble(line: Int) -> [String]? {
        guard let program = streamer.program else { return nil }
        let clamped = min(max(line, 1), program.lines.count)
        let modal = ProgramPreparer.modalState(lines: program.lines, before: clamped)
        let plungeFeed = program.parsed.moves.lazy.filter { $0.kind == .plunge }.compactMap(\.feed).min()
            ?? modal.feed ?? 60
        // Unknown Z counts as below: the retract to the safe position is the
        // conservative choice.
        let belowSafe = status.workPosition.map { $0.z < program.safeZ - 1e-6 } ?? true
        let segmentStart = program.segments.contains { $0.resumeLine == clamped }
        return ProgramPreparer.resumePreamble(
            modal: modal, zSafe: program.safeZ, safePositionLine: safePositionLine(), machineZBelowSafe: belowSafe,
            backlash: BacklashCompensation.Settings.current, backlashApplied: program.backlashApplied,
            plungeFeed: plungeFeed, warmupSeconds: MachineSettings.spindleWarmupSeconds, segmentStart: segmentStart)
    }

    /// Continue after a tool change / pause with the computed preamble.
    func continueJob() async {
        guard let line = streamer.resumeLine, let preamble = resumePreamble(line: line) else { return }
        await streamer.continueAfterSuspend(preamble: preamble)
    }

    /// Send the loaded program from a line with the computed preamble.
    func sendFromLine(_ line: Int) async {
        guard let preamble = resumePreamble(line: line) else { return }
        await streamer.start(fromLine: line, preamble: preamble)
    }

    /// Runs a macro's lines in order (Idle only, unless the macro is marked
    /// `allowWhileRunning`: then its lines are queued between a running
    /// program's). `@goto <saved position>` expands to the safe legs to that
    /// machine position and always needs the machine Idle.
    func runMacro(_ macro: MachineSettings.Macro) async {
        let whileRunning = macro.allowWhileRunning && jobBlocksCommands
        if whileRunning {
            guard isConnected, alarmCode == nil else { lastError = GRBLCommandError.notReady(status.state).localizedDescription; return }
        } else {
            guard canMove else { lastError = GRBLCommandError.notReady(status.state).localizedDescription; return }
        }
        log(.info, "Macro: \(macro.name)" + (whileRunning ? " (while the program runs)" : ""))
        do {
            for raw in macro.lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                if line.lowercased().hasPrefix("@goto ") {
                    let name = line.dropFirst("@goto ".count).trimmingCharacters(in: .whitespaces)
                    guard let saved = positions.positions.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                        throw GRBLCommandError.refused("No saved position named “\(name)”.")
                    }
                    try await goTo(machine: saved.position, feed: MachineSettings.jogFeed)
                } else if whileRunning {
                    try await sendInternal(line)
                } else {
                    try await send(line)
                }
            }
        } catch {
            lastError = error.localizedDescription
            log(.error, "Macro \(macro.name) stopped: \(error.localizedDescription)")
        }
    }

    // MARK: - Console

    func clearConsole() { console.removeAll() }

    private func log(_ direction: ConsoleEntry.Direction, _ text: String) {
        console.append(ConsoleEntry(id: UUID(), date: Date(), direction: direction, text: text))
        if console.count > Self.consoleLimit {
            console.removeFirst(console.count - Self.consoleLimit)
        }
    }

    /// Job events from the streamer: console and the app log.
    func noteJob(_ text: String) {
        log(.info, text)
        app?.appendLog("[machine] \(text)\n")
    }

    func noteJobFinished(_ state: JobStreamer.State) {
        let name = streamer.jobName
        switch state {
        case .completed: noteJob("\(name): done (\(streamer.ackedLine) lines acknowledged, \(Int(streamer.elapsed)) s).")
        case .failed(let reason): noteJob("\(name): ended — \(reason).")
        default: break
        }
    }
}

/// One move of a program that leaves the machine's travel on one axis.
nonisolated struct PreflightIssue: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Z above the top of travel — the retract height has nowhere to go.
        case aboveTop
        /// Z below the bottom of travel.
        case belowBottom
        /// X or Y outside the travel.
        case outside

        init?(axis: Axis, machine value: Double, range: ClosedRange<Double>, tolerance: Double = 0.001) {
            if value > range.upperBound + tolerance { self = axis == .z ? .aboveTop : .outside }
            else if value < range.lowerBound - tolerance { self = axis == .z ? .belowBottom : .outside }
            else { return nil }
        }
    }

    var axis: Axis
    /// 1-based source line (0 for a single target such as "Go to").
    var line: Int
    var work: Double
    var machine: Double
    var kind: Kind
}

/// Result of `MachineController.preflightResult`: the message for the UI,
/// the offending moves, and whether "Clamp Z to top" would fix all of them.
nonisolated struct PreflightResult: Sendable {
    var message: String
    var issues: [PreflightIssue] = []
    /// Every issue is a Z above the top of travel: clamping Z makes the program sendable.
    var canClampZ = false
    /// The work Z the clamp would use (`MachineController.clampZWork`).
    var clampZWork: Double? = nil
}
