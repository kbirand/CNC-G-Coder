import SwiftUI

/// Settings → Machine: every `machine.*` key (`MachineSettings.Keys`). These
/// describe the machine and the shop, so they are app-wide `UserDefaults`
/// like the backlash play — never project fields.
struct MachineSettingsPane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(MachineSettings.Keys.transport) private var transport = MachineSettings.Defaults.transport
    @AppStorage(MachineSettings.Keys.host) private var host = MachineSettings.Defaults.host
    @AppStorage(MachineSettings.Keys.port) private var port = MachineSettings.Defaults.port
    @AppStorage(MachineSettings.Keys.serialPath) private var serialPath = MachineSettings.Defaults.serialPath
    @AppStorage(MachineSettings.Keys.baud) private var baud = MachineSettings.Defaults.baud
    @AppStorage(MachineSettings.Keys.pollMs) private var pollMs = MachineSettings.Defaults.pollMs
    @AppStorage(MachineSettings.Keys.autoReconnect) private var autoReconnect = MachineSettings.Defaults.autoReconnect
    @AppStorage(MachineSettings.Keys.consoleShowStatus) private var consoleShowStatus = MachineSettings.Defaults.consoleShowStatus
    @AppStorage(MachineSettings.Keys.showSimulator) private var showSimulator = MachineSettings.Defaults.showSimulator

    @AppStorage(MachineSettings.Keys.jogFeed) private var jogFeed = MachineSettings.Defaults.jogFeed
    @AppStorage(MachineSettings.Keys.jogStep) private var jogStep = MachineSettings.Defaults.jogStep
    @AppStorage(MachineSettings.Keys.jogSegmentMs) private var jogSegmentMs = MachineSettings.Defaults.jogSegmentMs

    @AppStorage(MachineSettings.Keys.probeFeedFast) private var probeFeedFast = MachineSettings.Defaults.probeFeedFast
    @AppStorage(MachineSettings.Keys.probeFeedSlow) private var probeFeedSlow = MachineSettings.Defaults.probeFeedSlow
    @AppStorage(MachineSettings.Keys.probeMaxTravel) private var probeMaxTravel = MachineSettings.Defaults.probeMaxTravel
    @AppStorage(MachineSettings.Keys.probeRetract) private var probeRetract = MachineSettings.Defaults.probeRetract
    @AppStorage(MachineSettings.Keys.probePlateThickness) private var probePlateThickness = MachineSettings.Defaults.probePlateThickness

    @AppStorage(MachineSettings.Keys.safeZWork) private var safeZWork = MachineSettings.Defaults.safeZWork
    @AppStorage(MachineSettings.Keys.safeZBelowTop) private var safeZBelowTop = MachineSettings.Defaults.safeZBelowTop
    @AppStorage(MachineSettings.Keys.spindleMin) private var spindleMin = MachineSettings.Defaults.spindleMin
    @AppStorage(MachineSettings.Keys.spindleMax) private var spindleMax = MachineSettings.Defaults.spindleMax
    @AppStorage(MachineSettings.Keys.spindleWarmupSeconds) private var spindleWarmup = MachineSettings.Defaults.spindleWarmupSeconds
    @AppStorage(MachineSettings.Keys.applyBacklash) private var applyBacklash = MachineSettings.Defaults.applyBacklash
    @AppStorage(MachineSettings.Keys.heightMapApplyBelowZ) private var applyBelowZ = MachineSettings.Defaults.heightMapApplyBelowZ
    @AppStorage(MachineSettings.Keys.confirmContinue) private var confirmContinue = MachineSettings.Defaults.confirmContinue
    @AppStorage(MachineSettings.Keys.autoSaveWorkZero) private var autoSaveWorkZero = MachineSettings.Defaults.autoSaveWorkZero
    @AppStorage(MachineSettings.Keys.streamWindowBytes) private var streamWindowBytes = MachineSettings.Defaults.streamWindowBytes

    var body: some View {
        Form {
            connectionSection
            jogSection
            probeSection
            motionSection
            programSection
            AxisCalibrationSection(machine: model.machine)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }

    private var connectionSection: some View {
        Section("Connection") {
            Picker("Transport:", selection: $transport) {
                Text("Wi‑Fi (telnet)").tag(TransportKind.tcp.rawValue)
                Text("USB serial").tag(TransportKind.serial.rawValue)
                Text("Simulator (built in)").tag(TransportKind.simulator.rawValue)
            }
            .help("How the app reaches the controller: FluidNC over the network (telnet, port 23), any Grbl-type controller over its USB serial port, or the built-in simulator for trying the panel without a machine.")
            TextField("Host:", text: $host)
                .help("The controller's host name or IP address on the Wi‑Fi link (e.g. fluidnc.local or 192.168.1.50)")
            TextField("Port:", value: $port, format: .number.grouping(.never))
                .help("TCP port of the telnet service — 23 on FluidNC")
            TextField("Serial port:", text: $serialPath)
                .help("The USB serial device (/dev/cu.…); the connection bar lists the ports it finds")
            TextField("Baud:", value: $baud, format: .number.grouping(.never))
                .help("Serial speed: 115200 for Grbl and FluidNC")
            TextField("Status poll (ms):", value: $pollMs, format: .number.grouping(.never))
                .help("How often the position is asked for (?) — 200 ms gives 5 reports a second; shorter is smoother but loads the link")
            Toggle("Reconnect automatically when the link drops", isOn: $autoReconnect)
                .help("Open the connection again after it was lost, e.g. a Wi‑Fi dropout. A running job is not resumed by itself.")
            Toggle("Show status reports in the console", isOn: $consoleShowStatus)
                .help("Include every ? poll and <…> report in the Console tab — useful for diagnosing, noisy otherwise")
            Toggle("Show the Simulator in the connection picker", isOn: $showSimulator)
                .help("Offer the built-in FluidNC simulator as a third transport in the connection bar")
            Text("A simulated FluidNC for trying the panel without a machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var jogSection: some View {
        Section("Jog") {
            TextField("Default feed (mm/min):", value: $jogFeed, format: numberFormat)
                .help("Jog speed the panel starts with; also used by Go to and saved positions")
            TextField("Default step (mm, 0 = continuous):", value: $jogStep, format: numberFormat)
                .help("Distance of one click on a jog button when the panel starts")
            TextField("Continuous jog segment (ms):", value: $jogSegmentMs, format: .number.grouping(.never))
                .help("Length of the short jog commands sent one after another while a button is held, on firmware that cannot cancel a long jog")
            Text("Segment feeding is used when the firmware cannot cancel a long jog in flight (Grbl, or FluidNC without soft limits); shorter segments stop sooner but load the link more.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var probeSection: some View {
        Section("Z probe") {
            TextField("Fast feed (mm/min):", value: $probeFeedFast, format: numberFormat)
                .help("Speed of the first probe pass, which only has to find the surface")
            TextField("Slow feed (mm/min):", value: $probeFeedSlow, format: numberFormat)
                .help("Speed of the second pass, which sets the Z — slower is more precise")
            TextField("Max travel (mm):", value: $probeMaxTravel, format: numberFormat)
                .help("How far down a probe may go before it gives up; the probe fails (no alarm) if nothing is touched")
            TextField("Retract after probe (mm):", value: $probeRetract, format: numberFormat)
                .help("How far the bit backs off between the passes and after the last one")
            TextField("Plate thickness (mm):", value: $probePlateThickness, format: numberFormat)
                .help("What work Z reads at the trigger point: 0 for the bit touching the copper, the plate's thickness when probing on a touch plate")
            Text("0 when the bit touches the copper itself (clip on the board); the plate's thickness when probing through a touch plate on the mask side.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var motionSection: some View {
        Section("Motion") {
            TextField("Safe work Z for Go to Work Zero (mm):", value: $safeZWork, format: numberFormat)
                .help("Go to Work Zero first rises to this work Z, then moves over X0 Y0 — high enough to clear clamps")
            TextField("Safe Z below top of travel (mm):", value: $safeZBelowTop, format: numberFormat)
                .help("Safe Z and the parked height for tool changes: this far below the top of the Z travel, so the move never hits the limit switch")
            TextField("Spindle minimum (rpm):", value: $spindleMin, format: numberFormat)
                .help("Lowest speed the panel's Spindle button will send — the speed your spindle actually starts at")
            TextField("Spindle maximum (rpm):", value: $spindleMax, format: numberFormat)
                .help("Highest speed the panel's Spindle button will send")
            TextField("Spindle warm-up before resuming (s):", value: $spindleWarmup, format: numberFormat)
                .help("Pause after the spindle is switched on in a resume preamble (Continue, Send from line) before the bit moves")
        }
    }

    private var programSection: some View {
        Section("Programs") {
            Toggle("Apply backlash compensation when sending", isOn: $applyBacklash)
                .help("Rewrite every program sent to the machine for the play set in Machine setup (the program files on disk are not changed)")
            Toggle("Confirm before continuing after a tool change", isOn: $confirmContinue)
                .help("Show the resume preamble in a sheet before Continue sends it, instead of resuming at once")
            Text("Off: Continue in the tool-change banner resumes at once (the banner shows the lines it will send). Send from line… always shows its preamble first.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Save the work zero when a program is sent", isOn: $autoSaveWorkZero)
                .help("Each Send adds a Work entry to the Positions tab, named after the program and the time, with the machine coordinates of the work origin")
            Text("After a crash, reset or re-homing, Use as zero on that entry re-establishes the same origin without touching off again. The newest \(SavedPositionsStore.automaticLimit) are kept; entries you save yourself are never removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Stream window (bytes, 0 = automatic):", value: $streamWindowBytes, format: .number.grouping(.never))
                .help("How many unacknowledged bytes stay in flight while a program streams; 0 picks 128 on USB serial and 512 over Wi‑Fi, or the receive buffer the controller reports if larger")
            Text("Short segments around corners and holes need many lines per second: on a Wi‑Fi link a small window waits for an acknowledgement every few lines and the cut crawls. Raise it if arcs run slower than the feed; a Grbl board on USB must stay at 128.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Height map applies to moves at or below Z (mm):", value: $applyBelowZ, format: numberFormat)
                .help("Moves below this work Z are warped by the probed surface; travel above it stays flat")
            Text("Rapids above this Z (safe-height travel) are left alone; everything at or below it is warped by the probed surface.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var numberFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...3)).grouping(.never)
    }
}

/// Settings → Machine → Axis calibration: FluidNC's `axes/<a>/steps_per_mm`,
/// read from the controller, corrected from a measured jog and written back
/// (`$/axes/x/steps_per_mm=` at once, `$CD=<config>` to make it stick).
/// Steps/mm belong to the machine, so nothing here is stored in the app
/// except the config filename to write.
private struct AxisCalibrationSection: View {
    @Bindable var machine: MachineController
    @AppStorage(MachineSettings.Keys.configFilename) private var configFilename = MachineSettings.Defaults.configFilename
    @State private var rows: [Axis: CalibrationRow] = [.x: CalibrationRow(), .y: CalibrationRow()]
    @State private var reportedFilename = ""
    @State private var saveToFile = true
    @State private var busy = false
    @State private var message: String?

    private var available: Bool { machine.supportsStepsCalibration }
    private var fileToWrite: String { configFilename.isEmpty ? reportedFilename : configFilename }

    var body: some View {
        Section("Axis calibration (steps/mm)") {
            if !available {
                Text(machine.isConnected
                     ? "Steps/mm can be read and changed on FluidNC controllers only (this one reports \(machine.firmware.description))."
                     : "Connect to the machine in the Machine panel to read and change the steps/mm of each axis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField(String(localized: "Config file:"), text: $configFilename, prompt: Text(reportedFilename.isEmpty ? String(localized: "as reported by the controller") : reportedFilename))
                    .help("The FluidNC config file to save into; empty = the one the controller reports with Read")
                Button("Read") { Task { await readAll() } }
                    .disabled(!available || busy)
                    .help("Reads the config filename and the current steps/mm of X and Y from the controller")
            }
            Toggle("Save to the config file after applying (survives a reboot)", isOn: $saveToFile)
                .help("Also run $CD=<config file> after Apply, which writes the running configuration to that file; off, the new steps/mm last until the controller reboots")
            ForEach([Axis.x, Axis.y], id: \.self) { axis in
                axisRows(axis)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.hasPrefix("Error") ? .red : .secondary)
            }
            Text("""
            How to measure: put a dial indicator or a ruler against the spindle (or stick a pencil in the collet and mark the bed), jog the axis a little in the direction you will measure so the backlash is taken up, zero the indicator, then jog a known distance in that same direction — the longer the better, 100 mm beats 10 mm. Enter the commanded and the measured distance: new steps/mm = current × commanded ÷ measured (10 mm commanded, 9.85 mm measured on 800 steps/mm → 812.18). Apply writes the running config at once; with the toggle on it also runs $CD=<config file>, which rewrites that file from the running config. Re-measure afterwards. If repeated measurements disagree by more than a few hundredths, that is backlash or a loose pulley, not steps/mm — fix that first.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { if available { Task { await readAll() } } }
        .onChange(of: available) { if available { Task { await readAll() } } }
    }

    @ViewBuilder
    private func axisRows(_ axis: Axis) -> some View {
        let row = rows[axis] ?? CalibrationRow()
        let corrected = MachineController.correctedSteps(current: row.current ?? 0, commanded: row.commanded, measured: row.measured)
        LabeledContent("\(axis.rawValue) steps/mm now:") {
            Text(row.current.map { GRBLCommand.number($0) } ?? "—")
                .monospacedDigit()
        }
        TextField("\(axis.rawValue) jog commanded (mm):", value: binding(axis, \.commanded), format: distanceFormat)
            .help("The distance you told the machine to move along \(axis.rawValue) (after taking up the backlash)")
        TextField("\(axis.rawValue) travel measured (mm):", value: binding(axis, \.measured), format: distanceFormat)
            .help("The distance the \(axis.rawValue) axis really moved, by indicator or ruler")
        HStack {
            LabeledContent("New \(axis.rawValue) steps/mm:") {
                Text(corrected.map { GRBLCommand.number($0) } ?? "—")
                    .monospacedDigit()
            }
            Spacer()
            Button("Apply to \(axis.rawValue)") {
                guard let corrected else { return }
                Task { await apply(axis, corrected) }
            }
            .disabled(!available || busy || corrected == nil || row.current == nil || abs(row.commanded - row.measured) < 1e-6)
            .help("Write the new steps/mm to the controller ($/axes/\(axis.rawValue.lowercased())/steps_per_mm=) and, with the toggle above, save it to the config file")
        }
    }

    private func binding(_ axis: Axis, _ keyPath: WritableKeyPath<CalibrationRow, Double>) -> Binding<Double> {
        Binding(get: { (rows[axis] ?? CalibrationRow())[keyPath: keyPath] },
                set: { value in var row = rows[axis] ?? CalibrationRow(); row[keyPath: keyPath] = value; rows[axis] = row })
    }

    private var distanceFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...3)).grouping(.never)
    }

    private func readAll() async {
        guard available, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            reportedFilename = try await machine.readConfigFilename()
            for axis in [Axis.x, Axis.y] {
                let value = try await machine.readStepsPerMM(axis)
                rows[axis, default: CalibrationRow()].current = value
            }
            message = String(localized: "Read from the controller (config file \(reportedFilename)).")
        } catch {
            message = String(localized: "Error: \(error.localizedDescription)")
        }
    }

    private func apply(_ axis: Axis, _ value: Double) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let change = try await machine.writeStepsPerMM(axis, value, saveTo: saveToFile ? fileToWrite : nil)
            rows[axis, default: CalibrationRow()].current = change.current
            // The correction has been applied: the next measurement starts from scratch.
            rows[axis, default: CalibrationRow()].measured = rows[axis]?.commanded ?? 100
            message = String(localized: "\(axis.rawValue): \(GRBLCommand.number(change.previous)) → \(GRBLCommand.number(change.current)) steps/mm")
                + (change.savedTo.map { ", saved to \($0)." } ?? ". Running config only — it resets at the next reboot.")
        } catch {
            message = String(localized: "Error: \(error.localizedDescription)")
        }
    }

    struct CalibrationRow {
        var current: Double?
        var commanded: Double = 100
        var measured: Double = 100
    }
}
