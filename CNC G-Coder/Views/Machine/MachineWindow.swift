import SwiftUI
import Combine

/// The tabs of the Machine window's right column.
nonisolated enum MachineTab: String, CaseIterable, Identifiable {
    case program, probe, heightMap, console, macros

    var id: String { rawValue }

    var title: String {
        switch self {
        case .program: "Program"
        case .probe: "Probe"
        case .heightMap: "Height Map"
        case .console: "Console"
        case .macros: "Macros"
        }
    }

    var systemImage: String {
        switch self {
        case .program: "doc.text"
        case .probe: "arrow.down.to.line"
        case .heightMap: "square.grid.3x3"
        case .console: "terminal"
        case .macros: "command"
        }
    }
}

/// Content of `Window("Machine", id: "machine")`, the stand-alone variant of
/// the main window's `MachineInspector`: the connection bar across the top,
/// the pendant column (DRO, controls, positions, jog, overrides) on the left
/// and the Program / Probe / Height Map / Console / Macros tabs on the right. The controller is handed to every subview explicitly from
/// `model.machine`; nothing here reaches it through the environment, so the
/// views can be previewed and reused with any controller instance.
struct MachineWindow: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("machine.tab") private var tabRaw = MachineTab.program.rawValue

    private var tab: Binding<MachineTab> {
        Binding(
            get: { MachineTab(rawValue: tabRaw) ?? .program },
            set: { tabRaw = $0.rawValue }
        )
    }

    var body: some View {
        MachineWindowBody(machine: model.machine, tab: tab,
                          defaultSpindleRPM: Double(model.parameters.millSpeed) ?? MachineSettings.spindleMax)
            .navigationTitle(windowTitle)
            .frame(minWidth: 1100, minHeight: 720)
    }

    /// "Front copper — 42 %" while a job runs, so the progress shows in the
    /// window list and the Dock menu even when the window is behind.
    private var windowTitle: String {
        let streamer = model.machine.streamer
        guard streamer.isActive, let program = streamer.program else { return "Machine" }
        let percent = Int((streamer.progressFraction * 100).rounded())
        return "\(program.kind.displayName) — \(percent) %"
    }
}

/// Split out so the window title's observation of the streamer does not
/// re-render the whole layout on every progress change: the layout below
/// only observes what each subview reads.
private struct MachineWindowBody: View {
    @Bindable var machine: MachineController
    @Binding var tab: MachineTab
    var defaultSpindleRPM: Double

    var body: some View {
        VStack(spacing: 0) {
            MachineConnectionBar(machine: machine)
            MachineErrorLine(machine: machine)
            Divider()
            HStack(spacing: 0) {
                leftColumn
                    .frame(width: 400)
                Divider()
                rightColumn
            }
        }
        .background {
            // ⌘. stops everything from anywhere in the window; the button is
            // invisible but keeps the shortcut in the responder chain.
            Button("Stop") { Task { await machine.stop() } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!machine.isConnected)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MachineDRO(machine: machine)
                MachineControls(machine: machine, defaultSpindleRPM: defaultSpindleRPM)
                PositionsSection(machine: machine)
                JogPad(machine: machine)
                OverridesView(machine: machine)
            }
            .padding(14)
        }
    }

    private var rightColumn: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(MachineTab.allCases) { t in
                    Label(t.title, systemImage: t.systemImage).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .program: ProgramTab(machine: machine, tab: $tab)
        case .probe: ProbeTab(machine: machine)
        case .heightMap: HeightMapTab(machine: machine)
        case .console: ConsoleTab(machine: machine)
        case .macros: MacrosTab(machine: machine)
        }
    }
}

/// Why the last command was refused or failed — a silent refusal looks like
/// a dead button. Shared by the Machine window and the main window's panel.
struct MachineErrorLine: View {
    @Bindable var machine: MachineController

    var body: some View {
        if let message = machine.lastError, !message.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    machine.clearError()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }
}

// MARK: - Shared UI helpers

extension MachineController {
    /// Manual controls (jog, zero, spindle, probe) are locked while a program
    /// is being streamed — except in the tool-change suspension, where the
    /// operator has to jog, re-zero and probe before continuing.
    var jobLocksControls: Bool { isStreaming && !isSuspendedForToolChange }

    /// Jog/zero/spindle: connected, not alarmed, and no job owning the machine.
    var manualControlsEnabled: Bool { isConnected && !jobLocksControls && alarmCode == nil }

    /// Automatic positioning (Go to, Safe Z, saved positions): additionally
    /// needs a trusted position and the machine at rest.
    var positioningEnabled: Bool { manualControlsEnabled && canMove && positionTrusted }
}

/// Section title in the pendant column.
struct MachineSectionLabel: View {
    var title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Rounded panel background used by every block in the pendant column.
struct MachinePanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func machinePanel() -> some View { modifier(MachinePanel()) }
}

/// Colour per axis, shared by the DRO and the jog pad.
nonisolated func axisTint(_ axis: Axis) -> Color {
    switch axis {
    case .x: .red
    case .y: .green
    case .z: .blue
    }
}

/// Parses a number the way the parameter fields do: dot or comma decimal,
/// whitespace ignored, nil for anything else.
nonisolated func parseNumber(_ text: String) -> Double? {
    let normalised = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
    guard let value = Double(normalised), value.isFinite else { return nil }
    return value
}

/// Always a dot decimal separator, no grouping, up to three decimals, so
/// values read like the DRO and the G-code.
nonisolated func formatMM(_ value: Double, decimals: Int = 3) -> String {
    var s = String(format: "%.\(decimals)f", value)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return s == "-0" ? "0" : s
}
