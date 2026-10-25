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

    /// Carvera: the tool the status reports (`T:`), named from the rack,
    /// and a manual `T<n> M6` to any slot of the changer.
    private var toolRow: some View {
        let slots = max(model.parameters.profile.toolChange.automaticSlots ?? 6, model.tools.rack.keys.max() ?? 0)
        return HStack(spacing: 6) {
            Menu {
                ForEach(1...max(slots, 1), id: \.self) { slot in
                    Button(rackLabel(slot)) { Task { try? await machine.send("T\(slot) M6") } }
                        .disabled(machine.status.tool == slot)
                }
                Divider()
                Button("Probe (T0)") { Task { try? await machine.send("T0 M6") } }
                    .disabled(machine.status.tool == 0)
            } label: {
                Label(currentToolText, systemImage: "wrench.and.screwdriver")
            }
            .fixedSize()
            .disabled(!machine.manualControlsEnabled || machine.machineState != .idle)
            .help("The bit in the spindle, as the machine reports it. Pick a slot to run a tool change now (T<n> M6: the changer parks the current bit, picks the new one and probes its length).")
            Spacer(minLength: 0)
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
