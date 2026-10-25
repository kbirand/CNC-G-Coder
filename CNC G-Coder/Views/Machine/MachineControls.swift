import SwiftUI

/// Reset / Hold–Resume / Check, spindle and coolant, and the "More" menu
/// (Sleep, Door). Home and Unlock live in the DRO's button grid. The spindle and coolant toggles show what the
/// controller reports in `A:`, not what was last clicked, so a program's
/// `M3`/`M5` and a stop's `M5 M9` are reflected too.
struct MachineControls: View {
    @Bindable var machine: MachineController
    /// `param.millSpeed` — the isolation spindle speed is the natural default.
    var defaultSpindleRPM: Double

    @AppStorage(MachineSettings.Keys.spindleMin) private var spindleMin = MachineSettings.Defaults.spindleMin
    @AppStorage(MachineSettings.Keys.spindleMax) private var spindleMax = MachineSettings.Defaults.spindleMax

    @State private var rpmText = ""
    @State private var toolBusy = false
    @State private var toolMessage: String?
    @State private var toolFailed = false
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MachineSectionLabel(title: "Machine")
            primaryRow
            holdRow
            spindleRow
            if machine.isCarvera { toolRow }
        }
        .controlSize(.small)
        .machinePanel()
        .onAppear { if rpmText.isEmpty { rpmText = formatMM(defaultSpindleRPM, decimals: 0) } }
    }

    private var primaryRow: some View {
        HStack(spacing: 6) {
            Button("Reset", systemImage: "arrow.counterclockwise") { Task { await machine.softReset() } }
                .disabled(!machine.isConnected)
                .help("Ctrl‑X soft reset — stops everything; position is lost if the machine was moving")
            Spacer(minLength: 0)
            moreMenu
        }
    }

    private var holdRow: some View {
        HStack(spacing: 6) {
            Button("Hold", systemImage: "pause.fill") { machine.feedHold() }
                .disabled(!machine.isConnected || !isMoving)
                .help("! — feed hold (decelerate and wait)")
            Button("Resume", systemImage: "play.fill") { machine.resume() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!machine.isConnected || !isHeld)
                .help("~ — cycle start / resume")
            Toggle("Check", systemImage: "checkmark.seal", isOn: Binding(
                get: { machine.machineState == .check },
                set: { on in Task { await machine.checkMode(on) } }
            ))
            .toggleStyle(.button)
            .disabled(!machine.isConnected || machine.isStreaming || !(machine.machineState == .idle || machine.machineState == .check))
            .help("$C — check mode: G-code is parsed but nothing moves")
            Spacer(minLength: 0)
        }
    }

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

    private var spindleRow: some View {
        HStack(spacing: 6) {
            Toggle("Spindle", systemImage: "fan.fill", isOn: Binding(
                get: { spindleOn },
                set: { on in Task { await machine.spindle(on: on, rpm: rpm) } }
            ))
            .toggleStyle(.button)
            .tint(.orange)
            .help(spindleOn ? "M5 — spindle off" : "M3 S\(Int(rpm)) — spindle on")
            TextField("RPM", text: $rpmText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 62)
                .onSubmit { if spindleOn { Task { await machine.spindle(on: true, rpm: rpm) } } }
                .help("Spindle speed, clamped to \(Int(spindleMin))–\(Int(spindleMax)) rpm (Settings → Machine)")
            Text("rpm").foregroundStyle(.secondary)
            Toggle("Coolant", systemImage: "drop.fill", isOn: Binding(
                get: { coolantOn },
                set: { on in Task { await machine.coolant(flood: on) } }
            ))
            .toggleStyle(.button)
            .tint(.cyan)
            .help(coolantOn ? "M9 — coolant off" : "M8 — flood coolant on")
            Spacer(minLength: 0)
        }
        .disabled(!machine.manualControlsEnabled)
    }

    /// Carvera: the tool the status reports (`T:`), named from the rack;
    /// a manual `T<n> M6` to any slot; and the changer's own chores —
    /// calibrate the tool length on the tool setter (`M491`, the probe
    /// too), tell the firmware which bit was inserted by hand (`M493.2`),
    /// drop the tool, clamp or unclamp the collet (`M490`).
    private var toolRow: some View {
        let slots = max(model.parameters.profile.toolChange.automaticSlots ?? 6, model.tools.rack.keys.max() ?? 0)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Menu {
                    Section("Change to") {
                        ForEach(1...max(slots, 1), id: \.self) { slot in
                            Button(rackLabel(slot)) { runTool("T\(slot) M6", label: String(localized: "Tool change to T\(slot)")) }
                                .disabled(machine.status.tool == slot)
                        }
                        Button("Probe (T0)") { runTool("T0 M6", label: String(localized: "Tool change to the probe")) }
                            .disabled(machine.status.tool == 0)
                        Button("Nothing — drop the tool (T-1)") { runTool("T-1 M6", label: String(localized: "Drop tool")) }
                            .disabled(machine.status.tool == -1)
                    }
                    Divider()
                    Button("Calibrate Tool Length (M491)") { runTool("M491", label: String(localized: "Calibrate")) }
                        .help("The tool setter measures the bit (or the wireless probe) in the spindle and the firmware stores its length — what clears “Probe not calibrated”")
                    Button("Check Tool for Breakage (M491.1)") { runTool("M491.1", label: String(localized: "Tool break check")) }
                        .help("Measures the tool again and halts if its length changed by more than 0.1 mm")
                    Menu("Set Tool Number Without Changing") {
                        ForEach(1...max(slots, 1), id: \.self) { slot in
                            Button(rackLabel(slot)) { sendTool("M493.2 T\(slot)") }
                        }
                        Button("Probe (T0)") { sendTool("M493.2 T0") }
                        Button("Nothing (T-1)") { sendTool("M493.2 T-1") }
                    }
                    .help("You put a bit in by hand: tell the firmware which one (M493.2), then calibrate")
                    Divider()
                    Button("Unclamp Collet (M490.2)") { sendTool("M490.2") }
                    Button("Clamp Collet (M490.1)") { sendTool("M490.1") }
                    Divider()
                    Section("Wireless probe") {
                        Button("Pair Wireless Probe (M471)") { pairProbe() }
                            .help("Puts the machine's receiver into pairing mode; then hold the probe's button until its light shows it paired. Needed once for a new probe.")
                        Button("Probe Laser On (M472)") { sendTool("M472") }
                            .help("Lights the wireless probe's pointer laser (it goes off by itself)")
                    }
                } label: {
                    Label(currentToolText, systemImage: "wrench.and.screwdriver")
                }
                .fixedSize()
                .disabled(!machine.manualControlsEnabled || machine.machineState != .idle || toolBusy)
                .help("The bit in the spindle, as the machine reports it. Change to any slot (T<n> M6: the changer parks the current bit, picks the new one and probes its length), calibrate the tool length, or tell the firmware what you inserted by hand.")
                if toolBusy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            if let toolMessage {
                Label(toolMessage, systemImage: toolFailed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(toolFailed ? .red : .green)
                    .lineLimit(2)
            }
            if let volts = machine.status.probeVoltage, volts > 0 {
                Text("Wireless probe \(formatMM(volts, decimals: 2)) V")
                    .font(.caption)
                    .foregroundStyle(volts < 3.5 ? Color.orange : Color.secondary)
                    .help("The wireless probe's battery, as the machine reports it (W:). Charge it below about 3.5 V.")
            }
        }
    }

    /// `M471`: the receiver listens; the probe's own button finishes it.
    private func pairProbe() {
        toolMessage = nil
        Task {
            do {
                try await machine.send("M471")
                toolFailed = false
                toolMessage = String(localized: "Pairing mode set — now hold the probe's button until its light confirms. Its voltage appears here once it talks.")
            } catch {
                toolFailed = true
                toolMessage = error.localizedDescription
            }
        }
    }

    /// A changer routine the machine works through (tool change, calibration).
    private func runTool(_ line: String, label: String) {
        toolBusy = true
        toolMessage = nil
        Task {
            let failure = await machine.runCarveraAutomation(line, label: label)
            toolBusy = false
            toolFailed = failure != nil
            toolMessage = failure ?? String(localized: "\(label) done.")
        }
    }

    /// A setting the firmware takes at once.
    private func sendTool(_ line: String) {
        toolMessage = nil
        Task {
            do { try await machine.send(line) } catch { toolFailed = true; toolMessage = error.localizedDescription }
        }
    }

    private var currentToolText: String {
        guard let tool = machine.status.tool else { return String(localized: "Tool: —") }
        switch tool {
        case -1: return String(localized: "Tool: none")
        case 0: return String(localized: "Tool: T0 probe")
        default: return "T\(tool)" + (model.tools.rackTool(slot: tool).map { " · \($0.name)" } ?? "")
        }
    }

    private func rackLabel(_ slot: Int) -> String {
        "T\(slot)" + (model.tools.rackTool(slot: slot).map { " · \($0.name)" } ?? String(localized: " · empty"))
    }

    private var spindleOn: Bool {
        let a = machine.status.accessories
        return a.contains("S") || a.contains("C")
    }

    private var coolantOn: Bool {
        machine.status.accessories.contains("F")
    }

    /// Typed RPM clamped to the configured spindle range.
    private var rpm: Double {
        let typed = parseNumber(rpmText) ?? defaultSpindleRPM
        let lo = min(spindleMin, spindleMax), hi = max(spindleMin, spindleMax)
        return min(max(typed, lo), hi)
    }

    private var moreMenu: some View {
        Menu {
            Button("Sleep", systemImage: "moon.zzz") { Task { await machine.sleep() } }
                .disabled(machine.machineState != .idle)
            Button("Safety Door", systemImage: "door.left.hand.open") { machine.door() }
            Divider()
            Button("Query Parser State ($G)") { Task { try? await machine.send(GRBLCommand.parserState) } }
            Button("Query Offsets ($#)") { Task { try? await machine.send(GRBLCommand.offsets) } }
            Button("Build Info ($I)") { Task { try? await machine.send(GRBLCommand.buildInfo) } }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!machine.isConnected || machine.jobLocksControls)
        .help("More: Sleep ($SLP — steppers and spindle off until a reset), Safety Door (the door-open hold), and queries whose answers appear in the console: parser state ($G), work offsets ($#), build info ($I)")
    }
}
