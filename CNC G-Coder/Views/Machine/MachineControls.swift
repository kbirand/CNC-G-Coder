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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MachineSectionLabel(title: "Machine")
            primaryRow
            holdRow
            spindleRow
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
    }
}
