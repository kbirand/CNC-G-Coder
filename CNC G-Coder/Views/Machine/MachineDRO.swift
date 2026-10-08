import SwiftUI

/// Digital read-out: work position large, machine position small ("—" until
/// the controller has reported one), a status strip with the live feed and
/// spindle speed, buffer and pin state, and a grid of icon
/// buttons: Zero XY / Zero Z / Zero All / Probe Z and Go to Work Zero /
/// Safe Z / Home / Unlock. Clicking a work value opens a popover that sets
/// that axis (`G10 L20`) — that is where the per-axis zero lives.
struct MachineDRO: View {
    @Bindable var machine: MachineController

    @State private var editingAxis: Axis?
    @State private var editText = ""
    @State private var confirmHome = false
    @State private var probing = false
    @State private var probeResult: (text: String, failed: Bool)?

    var body: some View {
        let _ = DebugFlags.renderLog ? Self._printChanges() : ()
        VStack(alignment: .leading, spacing: 8) {
            MachineSectionLabel(title: "Position", detail: wcsLabel)
                .help(parserStateTooltip)
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
        machine.parserState.isEmpty ? "Modal state unknown ($G)" : "[GC:" + machine.parserState.joined(separator: " ") + "]"
    }

    // MARK: Buttons

    /// Two rows of four equal cells; each button fills its cell so the grid
    /// follows the panel width.
    private var buttonGrid: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                droButton("Zero XY", "scope", help: "Make the current position work X0 Y0 (G10 L20)", enabled: canZero) {
                    Task { await machine.zero(axes: [.x, .y]) }
                }
                droButton("Zero Z", "arrow.down.to.line.compact", help: "Make the current position work Z0 (G10 L20)", enabled: canZero) {
                    Task { await machine.zero(axes: [.z]) }
                }
                droButton("Zero All", "target", help: "Make the current position work X0 Y0 Z0 (G10 L20)", enabled: canZero) {
                    Task { await machine.zero(axes: Axis.allCases) }
                }
                droButton(probing ? "Probing…" : "Probe Z", "arrow.down.to.line",
                          help: "Two-pass Z touch-off with the settings of the Probe tab; work Z is set at the trigger point",
                          enabled: canProbeZ) { probeZ() }
            }
            GridRow {
                droButton("Work Zero", "house", help: "Go to work zero: rapid up to the safe work Z, then to work X0 Y0", enabled: machine.positioningEnabled) {
                    Task { await machine.goToWorkZero() }
                }
                droButton("Safe Z", "arrow.up.to.line", help: "Rapid Z to just below the top of travel (G53)",
                          enabled: machine.positioningEnabled && machine.safePositionLine() != nil) {
                    Task { await machine.safePosition() }
                }
                droButton("Home", "house.fill", help: "$H — home every axis", enabled: canHome) { confirmHome = true }
                droButton("Unlock", "lock.open", help: "$X — clear the alarm without homing",
                          enabled: machine.isConnected && !machine.jobLocksControls) {
                    Task { await machine.unlock() }
                }
            }
        }
    }

    private func droButton(_ title: String, _ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(DROButtonLabelStyle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!enabled)
        .help(help)
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
