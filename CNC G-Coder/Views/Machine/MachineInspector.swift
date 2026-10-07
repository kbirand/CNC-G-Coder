import SwiftUI
import Combine

/// The tabs of the main window's Machine panel.
nonisolated enum MachineInspectorTab: String, CaseIterable, Identifiable {
    case control, positions, program, probe, heightMap, macros

    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: "Control"
        case .positions: "Positions"
        case .program: "Program"
        case .probe: "Probe"
        case .heightMap: "Height Map"
        case .macros: "Macros"
        }
    }

    var systemImage: String {
        switch self {
        case .control: "arrow.up.and.down.and.arrow.left.and.right"
        case .positions: "mappin.and.ellipse"
        case .program: "doc.text"
        case .probe: "arrow.down.to.line"
        case .heightMap: "square.grid.3x3"
        case .macros: "command"
        }
    }

    /// The panel tab that shows what a Machine-window tab shows.
    init(_ tab: MachineTab) {
        switch tab {
        case .program: self = .program
        case .probe: self = .probe
        case .heightMap: self = .heightMap
        case .macros: self = .macros
        case .console: self = .control
        }
    }
}

/// The Machine panel: the main window's right-hand inspector (toolbar
/// "Machine" toggle, View → Machine Panel ⇧⌘M, the sidebar's "Send … to
/// Machine…"). A fixed header — title row, compact connection strip with
/// the alarm banner, error line, DRO, the E-STOP button — keeps the position
/// and the stop in view on every tab; below it a tab bar (Control /
/// Positions / Program / Probe / Height Map / Macros, remembered in
/// `machine.inspectorTab`) whose content scrolls on its own. The same
/// views make up the stand-alone `MachineWindow`, opened from the button at
/// the top. The console lives in the main window's Console tab.
struct MachineInspector: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("machine.inspectorTab") private var tabRaw = MachineInspectorTab.control.rawValue

    private var tab: Binding<MachineInspectorTab> {
        Binding(
            get: { MachineInspectorTab(rawValue: tabRaw) ?? .control },
            set: { tabRaw = $0.rawValue }
        )
    }

    var body: some View {
        let _ = DebugFlags.renderLog ? Self._printChanges() : ()
        MachineInspectorBody(machine: model.machine, tab: tab,
                             defaultSpindleRPM: Double(model.parameters.millSpeed) ?? MachineSettings.spindleMax,
                             openWindow: { openWindow(id: "machine") })
            // "Send … to Machine…": the Program tab's controls consume the
            // request once they are on screen.
            .onAppear { if model.requestedMachineLayer != nil { tabRaw = MachineInspectorTab.program.rawValue } }
            .onChange(of: model.requestedMachineLayer) { _, kind in
                if kind != nil { tabRaw = MachineInspectorTab.program.rawValue }
            }
    }
}

/// Six equal-width tabs: titled with icons where the panel is wide enough,
/// icons only (titles as tooltips) at its narrowest — never clipped.
private struct MachineInspectorTabStrip: View {
    @Binding var tab: MachineInspectorTab

    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip(iconOnly: false)
            strip(iconOnly: true)
        }
    }

    private func strip(iconOnly: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(MachineInspectorTab.allCases) { t in
                tabButton(t, iconOnly: iconOnly)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(2)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tabButton(_ t: MachineInspectorTab, iconOnly: Bool) -> some View {
        let selected = t == tab
        return Button {
            tab = t
        } label: {
            Group {
                if iconOnly {
                    Image(systemName: t.systemImage)
                } else {
                    Label(t.title, systemImage: t.systemImage)
                        .lineLimit(1)
                }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .help(t.title)
    }
}

/// Split out so the panel's layout only observes what each subview reads,
/// not the whole app model.
private struct MachineInspectorBody: View {
    @Bindable var machine: MachineController
    @Binding var tab: MachineInspectorTab
    var defaultSpindleRPM: Double
    var openWindow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabPicker
            Divider()
            ScrollView {
                tabContent
                    .padding(12)
            }
        }
    }

    // MARK: Fixed header

    private var header: some View {
        VStack(spacing: 0) {
            titleRow
            MachineConnectionBar(machine: machine)
            MachineErrorLine(machine: machine)
            MachineDRO(machine: machine)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            EmergencyStopButton(machine: machine)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }

    private var titleRow: some View {
        HStack {
            Label("Machine", systemImage: "cpu")
                .font(.headline)
            Spacer()
            Button {
                openWindow()
            } label: {
                Label("Open in a window", systemImage: "macwindow")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Open the machine controls in a window of their own (with the program text and the console)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var tabPicker: some View {
        MachineInspectorTabStrip(tab: $tab)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    // MARK: Tabs

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .control: controlTab
        case .positions: PositionsSection(machine: machine, tall: true)
        case .program:
            ProgramControls(machine: machine, navigate: { tab = MachineInspectorTab($0) })
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .probe: ProbeControls(machine: machine)
        case .heightMap: HeightMapControls(machine: machine)
        case .macros:
            MacrosControls(machine: machine, bounded: true)
                .machinePanel()
        }
    }

    private var controlTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            JogPad(machine: machine)
            MachineControls(machine: machine, defaultSpindleRPM: defaultSpindleRPM)
            OverridesView(machine: machine)
            UserButtonsSection(machine: machine, editMacros: { tab = .macros })
        }
    }
}
