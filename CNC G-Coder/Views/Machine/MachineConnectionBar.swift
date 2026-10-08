import SwiftUI

/// Transport picker, endpoint entry, Connect/Disconnect, the state pill and
/// the firmware badge, with the alarm banner underneath while the controller
/// is in alarm. Connection defaults live in `MachineSettings` (app-wide, like
/// the backlash play): the fields here edit the same keys as the Settings
/// pane.
struct MachineConnectionBar: View {
    @Bindable var machine: MachineController

    @AppStorage(MachineSettings.Keys.transport) private var transport = MachineSettings.Defaults.transport
    @AppStorage(MachineSettings.Keys.host) private var host = MachineSettings.Defaults.host
    @AppStorage(MachineSettings.Keys.port) private var port = MachineSettings.Defaults.port
    @AppStorage(MachineSettings.Keys.serialPath) private var serialPath = MachineSettings.Defaults.serialPath
    @AppStorage(MachineSettings.Keys.baud) private var baud = MachineSettings.Defaults.baud
    @AppStorage(MachineSettings.Keys.showSimulator) private var showSimulator = MachineSettings.Defaults.showSimulator

    @State private var ports: [String] = []
    @State private var confirmDisconnect = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                connectionRows
                if kind == .simulator {
                    Text("Simulated FluidNC with real-time motion. Work zero and a probe surface are preset so the sample programs run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            MachineAlarmBanner(machine: machine)
            MachineSpindleWarning(machine: machine)
        }
        .onAppear { refreshPorts() }
        .alert("Disconnect while a program is running?", isPresented: $confirmDisconnect) {
            Button("Stop Job and Disconnect", role: .destructive) {
                Task {
                    await machine.streamer.stop()
                    await machine.disconnect()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The job will be stopped (feed hold, then reset) before the link is closed.")
        }
    }

    /// One row in the Machine window; the main window's panel is too narrow
    /// for it and gets two rows, or three at its narrowest.
    private var connectionRows: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                transportPicker
                endpointFields
                connectButton
                Spacer(minLength: 8)
                statePill
                firmwareBadge
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    transportPicker
                    endpointFields
                }
                stateRow
            }
            VStack(alignment: .leading, spacing: 8) {
                transportPicker
                HStack(spacing: 8) { endpointFields }
                stateRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kind: TransportKind { TransportKind(rawValue: transport) ?? .tcp }
    /// The simulator entry is a setting; a stored "simulator" transport is
    /// shown regardless so nobody is stranded on an entry that disappeared.
    private var simulatorOffered: Bool { showSimulator || kind == .simulator }
    private var isTCP: Bool { kind == .tcp }
    private var editable: Bool { machine.phase == .disconnected }
    private var isSimulator: Bool { machine.isConnected && machine.transportKind == .simulator }

    private var transportPicker: some View {
        Picker("", selection: $transport) {
            Label("Wi‑Fi", systemImage: "wifi").tag(TransportKind.tcp.rawValue)
            Label("USB", systemImage: "cable.connector").tag(TransportKind.serial.rawValue)
            if simulatorOffered {
                Label("Simulator", systemImage: "play.rectangle").tag(TransportKind.simulator.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(!editable)
        .help(simulatorOffered
              ? "Telnet over the LAN (port 23), the USB serial port, or the built-in FluidNC simulator"
              : "Telnet over the LAN (port 23) or the USB serial port")
    }

    private var stateRow: some View {
        HStack(spacing: 8) {
            connectButton
            Spacer(minLength: 4)
            statePill
            firmwareBadge
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var endpointFields: some View {
        if kind == .simulator {
            // The caption sits under the picker on its own line (see body).
            EmptyView()
        } else if isTCP {
            TextField("Host", text: $host)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 90, idealWidth: 150, maxWidth: 220)
                .disabled(!editable)
                .onSubmit { if editable { Task { await connect() } } }
                .help("The controller's host name or IP address (e.g. fluidnc.local or 192.168.1.50). Return connects.")
            TextField("Port", value: $port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .disabled(!editable)
                .help("TCP port of the telnet service — 23 on FluidNC")
        } else {
            Picker("", selection: $serialPath) {
                if serialPath.isEmpty || !ports.contains(serialPath) {
                    Text(serialPath.isEmpty ? "Choose a port…" : serialPath).tag(serialPath)
                }
                ForEach(ports, id: \.self) { path in
                    Text(path.replacingOccurrences(of: "/dev/cu.", with: "")).tag(path)
                }
            }
            .labelsHidden()
            .frame(minWidth: 110, idealWidth: 190, maxWidth: 240)
            .disabled(!editable)
            .onHover { if $0 { refreshPorts() } }
            .help("The USB serial port the controller is on (/dev/cu.…); the list is rescanned when you open it")
            Button {
                refreshPorts()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan /dev/cu.*")
            .disabled(!editable)
            TextField("Baud", value: $baud, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .disabled(!editable)
                .help("Serial speed: 115200 for Grbl and FluidNC")
        }
    }

    private var connectButton: some View {
        Button {
            if machine.isConnected || machine.phase == .unresponsive {
                if machine.isStreaming { confirmDisconnect = true } else { Task { await machine.disconnect() } }
            } else if machine.phase == .connecting {
                Task { await machine.disconnect() }
            } else {
                Task { await connect() }
            }
        } label: {
            HStack(spacing: 6) {
                if machine.phase == .connecting {
                    ProgressView().controlSize(.small)
                    Text("Cancel")
                } else {
                    Image(systemName: machine.phase == .disconnected ? "bolt.fill" : "xmark")
                    Text(machine.phase == .disconnected ? "Connect" : "Disconnect")
                }
            }
            .frame(minWidth: 96)
        }
        .buttonStyle(.borderedProminent)
        .tint(machine.phase == .disconnected ? .accentColor : .red)
        .disabled(machine.phase == .disconnected && !endpointValid)
        .keyboardShortcut("k", modifiers: .command)
        .help(connectHelp)
    }

    private var connectHelp: String {
        switch machine.phase {
        case .disconnected:
            endpointValid ? "Open the link and identify the controller (⌘K) — status reports start at once"
                          : "Fill in the host and port, or choose a serial port, first"
        case .connecting: "Give up the connection attempt"
        case .unresponsive: "The controller stopped answering — close the link (⌘K)"
        case .connected: machine.isStreaming ? "Close the link; a running job is stopped first, after a confirmation (⌘K)"
                                             : "Close the link (⌘K). The controller keeps its state — a spindle left on stays on."
        }
    }

    private var endpointValid: Bool {
        switch kind {
        case .simulator: return true
        case .tcp: return !host.trimmingCharacters(in: .whitespaces).isEmpty && port > 0 && port < 65536
        case .serial: return !serialPath.isEmpty
        }
    }

    private var statePill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 9, height: 9)
                .shadow(color: stateColor.opacity(0.7), radius: machine.isConnected ? 4 : 0)
            Text(stateText)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            if isSimulator {
                // So nobody takes the simulator's Idle for the machine's.
                Text("SIM")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.25), in: Capsule())
                    .foregroundStyle(.orange)
                    .help("Connected to the built-in simulator, not a machine")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(stateColor.opacity(0.14), in: Capsule())
        .help(machine.endpointDescription.isEmpty ? "Not connected" : machine.endpointDescription)
        .animation(.easeInOut(duration: 0.2), value: stateColor)
    }

    @ViewBuilder
    private var firmwareBadge: some View {
        if isSimulator {
            Text("Simulator")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .help("Built-in simulator (\(machine.firmware.description)) — " + machine.endpointDescription)
        } else if machine.isConnected, machine.firmware.kind != .unknown {
            Text(machine.firmware.description)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .help(machine.firmware.banner ?? machine.firmware.description)
        }
    }

    private var stateText: String {
        switch machine.phase {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .unresponsive: "Not responding"
        case .connected: machine.statusSummary
        }
    }

    /// State colours: green idle, blue moving, orange held/door/check, red alarm.
    private var stateColor: Color {
        switch machine.phase {
        case .disconnected: return .secondary
        case .connecting: return .yellow
        case .unresponsive: return .red
        case .connected: break
        }
        if machine.alarmCode != nil { return .red }
        switch machine.status.state {
        case .idle: return .green
        case .run, .jog, .home: return .blue
        case .hold, .door, .check, .sleep: return .orange
        case .alarm: return .red
        case .other: return .secondary
        }
    }

    private func connect() async {
        switch kind {
        case .simulator: await machine.connectSimulator()
        case .tcp: await machine.connect(tcpHost: host.trimmingCharacters(in: .whitespaces), port: UInt16(clamping: port))
        case .serial: await machine.connect(serialPath: serialPath, baud: baud)
        }
    }

    private func refreshPorts() {
        ports = SerialPorts.list()
        if serialPath.isEmpty, let first = ports.first(where: { !SerialPorts.isUnlikelyController($0) }) {
            serialPath = first
        }
    }
}

/// Red banner with the decoded alarm text and Unlock / Home / Reset. When the
/// alarm is one that loses the position (hard/soft limit, abort during
/// motion…) it says so: Unlock keeps whatever the controller believes, Home
/// re-references the machine.
struct MachineAlarmBanner: View {
    @Bindable var machine: MachineController

    private var isShown: Bool {
        machine.isConnected && (machine.alarmCode != nil || machine.status.state == .alarm)
    }

    var body: some View {
        if isShown {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    description
                    Spacer(minLength: 8)
                    buttons
                }
                VStack(alignment: .leading, spacing: 8) {
                    description
                    buttons
                }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.gradient)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var description: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(message).font(.callout)
                if !machine.positionTrusted {
                    Text("Position may be lost — Home recommended. Unlock keeps the position as-is (FluidNC also marks the axes homed).")
                        .font(.caption)
                        .opacity(0.9)
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Unlock", systemImage: "lock.open.fill") { Task { await machine.unlock() } }
                .help("$X — clear the alarm and keep the position the controller has. Fine after an E-stop at rest; after a limit hit the position may be off.")
            Button("Home", systemImage: "house.fill") { Task { await machine.home() } }
                .help("$H — run the homing cycle: every axis seeks its switch and the machine position is referenced again. The safe choice when the position may be lost.")
            Button("Reset", systemImage: "arrow.counterclockwise") { Task { await machine.softReset() } }
                .help("Ctrl‑X soft reset of the controller — stops everything; the alarm usually stays until Unlock or Home")
        }
    }

    private var title: String {
        machine.alarmCode.map { "Alarm \($0)" } ?? "Alarm"
    }

    private var message: String {
        machine.alarmCode.map { GRBLAlarm.description(for: $0) }
            ?? "The machine is locked. Home to reference it, or Unlock to continue."
    }
}


/// The spindle is turning while no program runs — after a job failed on a
/// dropped link, say, the controller keeps its last M3. One click stops it.
struct MachineSpindleWarning: View {
    @Bindable var machine: MachineController

    private var isShown: Bool {
        guard machine.isConnected, !machine.streamer.isActive else { return false }
        let s = machine.status
        return s.spindleSpeed > 0 || s.accessories.contains("S") || s.accessories.contains("C")
    }

    var body: some View {
        if isShown {
            HStack(spacing: 10) {
                Image(systemName: "fan.fill")
                    .symbolEffect(.rotate)
                Text("The spindle is running at \(Int(machine.status.spindleSpeed)) rpm with no program active.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Stop spindle", systemImage: "stop.fill") {
                    Task { await machine.spindle(on: false, rpm: 0) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .help("M5 — switch the spindle off")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.18))
        }
    }
}
