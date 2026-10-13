import SwiftUI

/// Digital read-out: work position large, machine position small ("—" until
/// the controller has reported one), a status strip with the live feed and
/// spindle speed, buffer and pin state, and a grid of icon buttons — by
/// default Zero XY / Zero Z / Zero All / Probe Z and Go to Work Zero /
/// Safe Z / Home / Unlock. The grid is `MachineSettings.droButtons`: the
/// slider button at the top right opens `DROButtonsCustomizeSheet`, where
/// the cells are reordered, removed and added from the built-in actions
/// (`DROBuiltIn`) and the macros (a macro cell runs it like a user button).
/// Clicking a work value opens a popover that sets that axis (`G10 L20`) —
/// that is where the per-axis zero lives.
struct MachineDRO: View {
    @Bindable var machine: MachineController
    /// Speed of the Spindle cell (`param.millSpeed`, clamped to the spindle range).
    var defaultSpindleRPM: Double = MachineSettings.spindleMax

    /// Observed only so the grid re-reads the layout and the macros after
    /// an edit; the JSON itself is decoded by the accessors.
    @AppStorage(MachineSettings.Keys.droButtons) private var droButtonsJSON = ""
    @AppStorage(MachineSettings.Keys.macros) private var macrosJSON = ""

    @State private var editingAxis: Axis?
    @State private var editText = ""
    @State private var confirmHome = false
    @State private var probing = false
    @State private var probeResult: (text: String, failed: Bool)?
    @State private var runningMacro: UUID?
    @State private var customizing = false

    var body: some View {
        let _ = DebugFlags.renderLog ? Self._printChanges() : ()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MachineSectionLabel(title: "Position", detail: wcsLabel)
                    .help(parserStateTooltip)
                Button {
                    customizing = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Customize Buttons… — reorder or remove the buttons below, add built-in actions and macros")
                .accessibilityLabel("Customize Buttons")
            }
            VStack(spacing: 4) {
                ForEach(Axis.allCases, id: \.self) { axis in
                    axisRow(axis)
                }
            }
            DROStatusStrip(machine: machine)
            Divider().opacity(0.5)
            buttonGrid
            if let probeResult {
                Label(probeResult.text, systemImage: probeResult.failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(probeResult.failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .machinePanel()
        .sheet(isPresented: $customizing) {
            DROButtonsCustomizeSheet()
        }
        // Dev hook: `-debugDROCustomize 1` opens Customize Buttons… at launch.
        .onAppear { if UserDefaults.standard.bool(forKey: "debugDROCustomize") { customizing = true } }
        .alert("Run the homing cycle?", isPresented: $confirmHome) {
            Button("Home") { Task { await machine.home() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The machine seeks its limit switches on every axis and re-references the machine position.")
        }
    }

    // MARK: Rows

    private func axisRow(_ axis: Axis) -> some View {
        HStack(spacing: 10) {
            Text(axis.gcodeLetter)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(axisTint(axis).gradient, in: Circle())
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                workValueButton(axis)
                Text(machineText(axis))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func workValueButton(_ axis: Axis) -> some View {
        Button {
            editText = formatMM(machine.status.workPosition?[axis] ?? 0)
            editingAxis = axis
        } label: {
            Text(workText(axis))
                .font(.system(size: 28, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .buttonStyle(.plain)
        .disabled(!machine.manualControlsEnabled || !machine.status.hasPosition)
        .help("Click to set the work \(axis.gcodeLetter) of the current position")
        .popover(isPresented: Binding(get: { editingAxis == axis }, set: { if !$0 { editingAxis = nil } })) {
            setAxisPopover(axis)
        }
    }

    private func setAxisPopover(_ axis: Axis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set work \(axis.gcodeLetter) of the current position")
                .font(.headline)
            HStack {
                Text("\(axis.gcodeLetter) =")
                TextField("0", text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit { applySetAxis(axis) }
                    .help("The work \(axis.gcodeLetter) the current position should read — 0 makes it the origin, any other value offsets the zero by that much (G10 L20)")
                Text("mm").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { editingAxis = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Set") { applySetAxis(axis) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parseNumber(editText) == nil)
                    .help("Apply — the machine does not move; only its idea of work \(axis.gcodeLetter) changes")
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func applySetAxis(_ axis: Axis) {
        guard let value = parseNumber(editText) else { return }
        editingAxis = nil
        Task { await machine.setAxis(axis, workValue: value) }
    }

    private func workText(_ axis: Axis) -> String {
        guard let work = machine.status.workPosition else { return "—.———" }
        return work.formatted(axis)
    }

    private func machineText(_ axis: Axis) -> String {
        guard let mpos = machine.status.machinePosition else { return "M —" }
        return "M " + mpos.formatted(axis)
    }

    private var wcsLabel: String? {
        machine.isConnected ? machine.activeWCS : nil
    }

    private var parserStateTooltip: String {
        machine.parserState.isEmpty ? String(localized: "Modal state unknown ($G)") : "[GC:" + machine.parserState.joined(separator: " ") + "]"
    }

    // MARK: Buttons

    /// The configured cells, macros whose definition is gone left out.
    private var buttons: [MachineSettings.DROButton] {
        _ = droButtonsJSON
        _ = macrosJSON
        let macros = MachineSettings.macros
        return MachineSettings.droButtons.filter {
            if case .macro(let id) = $0 { return macros.contains { $0.id == id } }
            return true
        }
    }

    /// Four equal columns, as many rows as the layout needs; each button
    /// fills its cell so the grid follows the panel width.
    @ViewBuilder
    private var buttonGrid: some View {
        let buttons = buttons
        if buttons.isEmpty {
            Text("No buttons. Click the slider icon above to add some.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            let macros = MachineSettings.macros
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(buttons, id: \.self) { button in
                    switch button {
                    case .builtIn(let action):
                        builtInButton(action)
                    case .macro(let id):
                        if let macro = macros.first(where: { $0.id == id }) {
                            macroButton(macro)
                        }
                    }
                }
            }
        }
    }

    private func builtInButton(_ action: MachineSettings.DROBuiltIn) -> some View {
        Button {
            perform(action)
        } label: {
            Label(title(of: action), systemImage: action.symbol)
                .labelStyle(DROButtonLabelStyle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(tint(of: action))
        .disabled(!isEnabled(action))
        .help(action.help)
    }

    private func macroButton(_ macro: MachineSettings.Macro) -> some View {
        Button {
            run(macro)
        } label: {
            Label {
                Text(macro.name)
            } icon: {
                if runningMacro == macro.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: macro.icon ?? "command")
                }
            }
            .labelStyle(DROButtonLabelStyle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(macro.allowWhileRunning ? .orange : nil)
        .disabled(!isEnabled(macro))
        .help(macro.lines.joined(separator: String(localized: "  ·  ")) + (macro.allowWhileRunning ? String(localized: "  (allowed while a program runs)") : String(localized: "")))
    }

    private func title(of action: MachineSettings.DROBuiltIn) -> String {
        action == .probeZ && probing ? String(localized: "Probing…") : action.title
    }

    /// Spindle and Coolant show the controller's `A:` state, like the
    /// toggles of the Machine section.
    private func tint(of action: MachineSettings.DROBuiltIn) -> Color? {
        switch action {
        case .spindle: spindleOn ? .orange : nil
        case .coolant: coolantOn ? .cyan : nil
        case .resume: isHeld ? .green : nil
        default: nil
        }
    }

    private func perform(_ action: MachineSettings.DROBuiltIn) {
        switch action {
        case .zeroXY: Task { await machine.zero(axes: [.x, .y]) }
        case .zeroZ: Task { await machine.zero(axes: [.z]) }
        case .zeroAll: Task { await machine.zero(axes: Axis.allCases) }
        case .probeZ: probeZ()
        case .workZero: Task { await machine.goToWorkZero() }
        case .safeZ: Task { await machine.safePosition() }
        case .home: confirmHome = true
        case .unlock: Task { await machine.unlock() }
        case .spindle:
            let on = !spindleOn
            let rpm = spindleRPM
            Task { await machine.spindle(on: on, rpm: rpm) }
        case .coolant:
            let on = !coolantOn
            Task { await machine.coolant(flood: on) }
        case .hold: machine.feedHold()
        case .resume: machine.resume()
        case .reset: Task { await machine.softReset() }
        case .sleep: Task { await machine.sleep() }
        }
    }

    private func isEnabled(_ action: MachineSettings.DROBuiltIn) -> Bool {
        switch action {
        case .zeroXY, .zeroZ, .zeroAll: canZero
        case .probeZ: canProbeZ
        case .workZero: machine.positioningEnabled
        case .safeZ: machine.positioningEnabled && machine.safePositionLine() != nil
        case .home: canHome
        case .unlock: machine.isConnected && !machine.jobLocksControls
        case .spindle, .coolant: machine.manualControlsEnabled
        case .hold: machine.isConnected && isMoving
        case .resume: machine.isConnected && isHeld
        case .reset: machine.isConnected
        case .sleep: machine.machineState == .idle
        }
    }

    /// Same rules as the user buttons of the Control tab.
    private func isEnabled(_ macro: MachineSettings.Macro) -> Bool {
        guard machine.isConnected, machine.alarmCode == nil, runningMacro == nil, !macro.lines.isEmpty else { return false }
        if machine.jobBlocksCommands { return macro.allowWhileRunning }
        return machine.machineState == .idle
    }

    private func run(_ macro: MachineSettings.Macro) {
        runningMacro = macro.id
        Task {
            await machine.runMacro(macro)
            runningMacro = nil
        }
    }

    private var spindleOn: Bool {
        let a = machine.status.accessories
        return a.contains("S") || a.contains("C")
    }

    private var coolantOn: Bool { machine.status.accessories.contains("F") }

    private var isMoving: Bool {
        switch machine.machineState {
        case .run, .jog: true
        default: false
        }
    }

    private var isHeld: Bool {
        switch machine.machineState {
        case .hold, .door: true
        default: false
        }
    }

    /// The default spindle speed clamped to the configured range.
    private var spindleRPM: Double {
        let lo = min(MachineSettings.spindleMin, MachineSettings.spindleMax)
        let hi = max(MachineSettings.spindleMin, MachineSettings.spindleMax)
        return min(max(defaultSpindleRPM, lo), hi)
    }

    private var canZero: Bool { machine.manualControlsEnabled && machine.status.hasPosition }

    private var canHome: Bool {
        machine.isConnected && !machine.jobLocksControls
            && (machine.status.state == .idle || machine.status.state == .alarm || machine.alarmCode != nil)
    }

    /// Same rules as the Probe tab: connected, no job, no alarm, trusted
    /// position, known work offset, probe not already triggered.
    private var canProbeZ: Bool {
        !probing && machine.isConnected && !machine.jobLocksControls && machine.alarmCode == nil
            && machine.positionTrusted && machine.canProbe && !machine.status.pins.contains("P")
    }

    private func probeZ() {
        probing = true
        probeResult = nil
        Task {
            let failure = await machine.probeZ()
            probing = false
            if let failure {
                probeResult = (failure, true)
            } else {
                let z = machine.lastProbe.map { " at machine Z\(formatMM($0.position.z))" } ?? ""
                probeResult = ("Probe OK\(z) — work Z now reads \(formatMM(MachineSettings.probePlateThickness)) there.", false)
            }
        }
    }
}

/// Icon above a short label, filling the button's cell.
struct DROButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon
                .font(.system(size: 16, weight: .medium))
            configuration.title
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }
}

/// The DRO's status strip: live `F`/`S` beside their override percentages,
/// free planner blocks / RX bytes (`Bf:`), active input pins (`Pn:`, the
/// probe pin highlighted) and the accessories (`A:`).
struct DROStatusStrip: View {
    @Bindable var machine: MachineController

    var body: some View {
        HStack(spacing: 10) {
            feedSpindle
            Spacer(minLength: 0)
            buffer
            pins
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var feedSpindle: some View {
        let s = machine.status
        let ov = s.overrides
        let feed = "F\(Int(s.feedRate.rounded()))" + (ov.map { " \($0.feed)%" } ?? "")
        let spindle = "S\(Int(s.spindleSpeed.rounded()))" + (ov.map { " \($0.spindle)%" } ?? "")
        return Text(feed + "  " + spindle)
            .help("Feed and spindle as reported (FS:), with the override percentages (Ov:)")
    }

    @ViewBuilder
    private var buffer: some View {
        if let blocks = machine.status.plannerBlocks, let bytes = machine.status.rxBytes {
            Text("Bf \(blocks),\(bytes)")
                .help("Free planner blocks and receive-buffer bytes")
        }
    }

    @ViewBuilder
    private var pins: some View {
        let pins = machine.status.pins
        if !pins.isEmpty {
            HStack(spacing: 2) {
                ForEach(Array(pins), id: \.self) { pin in
                    Text(String(pin))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(pin == "P" ? Color.orange.opacity(0.8) : Color.secondary.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(pin == "P" ? .white : .secondary)
                }
            }
            .help("Active input pins (Pn:) — P = probe closed, X/Y/Z = limit switches, D = door, H = hold, R = reset, S = start")
        }
    }
}
