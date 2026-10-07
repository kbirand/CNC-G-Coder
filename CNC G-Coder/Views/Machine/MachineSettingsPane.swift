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
            TextField("Host:", text: $host)
            TextField("Port:", value: $port, format: .number.grouping(.never))
            TextField("Serial port:", text: $serialPath)
            TextField("Baud:", value: $baud, format: .number.grouping(.never))
            TextField("Status poll (ms):", value: $pollMs, format: .number.grouping(.never))
            Toggle("Reconnect automatically when the link drops", isOn: $autoReconnect)
            Toggle("Show status reports in the console", isOn: $consoleShowStatus)
            Toggle("Show the Simulator in the connection picker", isOn: $showSimulator)
            Text("A simulated FluidNC for trying the panel without a machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var jogSection: some View {
        Section("Jog") {
            TextField("Default feed (mm/min):", value: $jogFeed, format: numberFormat)
            TextField("Default step (mm, 0 = continuous):", value: $jogStep, format: numberFormat)
            TextField("Continuous jog segment (ms):", value: $jogSegmentMs, format: .number.grouping(.never))
            Text("Segment feeding is used when the firmware cannot cancel a long jog in flight (Grbl, or FluidNC without soft limits); shorter segments stop sooner but load the link more.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var probeSection: some View {
        Section("Z probe") {
            TextField("Fast feed (mm/min):", value: $probeFeedFast, format: numberFormat)
            TextField("Slow feed (mm/min):", value: $probeFeedSlow, format: numberFormat)
            TextField("Max travel (mm):", value: $probeMaxTravel, format: numberFormat)
            TextField("Retract after probe (mm):", value: $probeRetract, format: numberFormat)
            TextField("Plate thickness (mm):", value: $probePlateThickness, format: numberFormat)
            Text("0 when the bit touches the copper itself (clip on the board); the plate's thickness when probing through a touch plate on the mask side.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var motionSection: some View {
        Section("Motion") {
            TextField("Safe work Z for Go to Work Zero (mm):", value: $safeZWork, format: numberFormat)
            TextField("Safe Z below top of travel (mm):", value: $safeZBelowTop, format: numberFormat)
            TextField("Spindle minimum (rpm):", value: $spindleMin, format: numberFormat)
            TextField("Spindle maximum (rpm):", value: $spindleMax, format: numberFormat)
            TextField("Spindle warm-up before resuming (s):", value: $spindleWarmup, format: numberFormat)
        }
    }

    private var programSection: some View {
        Section("Programs") {
            Toggle("Apply backlash compensation when sending", isOn: $applyBacklash)
            Toggle("Confirm before continuing after a tool change", isOn: $confirmContinue)
            Text("Off: Continue in the tool-change banner resumes at once (the banner shows the lines it will send). Send from line… always shows its preamble first.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Height map applies to moves at or below Z (mm):", value: $applyBelowZ, format: numberFormat)
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
                TextField("Config file:", text: $configFilename, prompt: Text(reportedFilename.isEmpty ? "as reported by the controller" : reportedFilename))
                Button("Read") { Task { await readAll() } }
                    .disabled(!available || busy)
                    .help("Reads the config filename and the current steps/mm of X and Y from the controller")
            }
            Toggle("Save to the config file after applying (survives a reboot)", isOn: $saveToFile)
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
        TextField("\(axis.rawValue) travel measured (mm):", value: binding(axis, \.measured), format: distanceFormat)
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
            message = "Read from the controller (config file \(reportedFilename))."
        } catch {
            message = "Error: \(error.localizedDescription)"
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
            message = "\(axis.rawValue): \(GRBLCommand.number(change.previous)) → \(GRBLCommand.number(change.current)) steps/mm"
                + (change.savedTo.map { ", saved to \($0)." } ?? ". Running config only — it resets at the next reboot.")
        } catch {
            message = "Error: \(error.localizedDescription)"
        }
    }

    struct CalibrationRow {
        var current: Double?
        var commanded: Double = 100
        var measured: Double = 100
    }
}
