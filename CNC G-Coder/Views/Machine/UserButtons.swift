import SwiftUI

/// User buttons on the Control tab: one per macro in
/// `MachineSettings.macros`, wrapped into rows. A button runs its macro with
/// the machine idle; a macro marked "allow while running" stays enabled
/// during a job (its lines go out between the program's). "Edit…" switches
/// the panel to the Macros tab, where the list is maintained.
struct UserButtonsSection: View {
    @Bindable var machine: MachineController
    var editMacros: () -> Void

    /// Observed only so the grid re-reads `MachineSettings.macros` after an
    /// edit in the Macros tab; the JSON itself is decoded by the accessor.
    @AppStorage(MachineSettings.Keys.macros) private var macrosJSON = ""
    @State private var running: UUID?

    private var macros: [MachineSettings.Macro] { _ = macrosJSON; return MachineSettings.macros }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MachineSectionLabel(title: "User buttons", detail: macros.isEmpty ? nil : "\(macros.count)")
                Button("Edit…", systemImage: "pencil") { editMacros() }
                    .help("Add, rename or reorder the buttons (Macros tab)")
            }
            if macros.isEmpty {
                Text("No macros yet. Each macro in the Macros tab becomes a button here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                grid
            }
        }
        .controlSize(.small)
        .machinePanel()
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 160), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(macros) { macro in
                userButton(macro)
            }
        }
    }

    private func userButton(_ macro: MachineSettings.Macro) -> some View {
        Button {
            run(macro)
        } label: {
            HStack(spacing: 4) {
                if running == macro.id {
                    ProgressView().controlSize(.mini)
                } else if let icon = macro.icon {
                    Image(systemName: icon)
                }
                Text(macro.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(macro.allowWhileRunning ? .orange : .accentColor)
        .disabled(!isEnabled(macro))
        .help(macro.lines.joined(separator: String(localized: "  ·  ")) + (macro.allowWhileRunning ? String(localized: "  (allowed while a program runs)") : String(localized: "")))
    }

    private func isEnabled(_ macro: MachineSettings.Macro) -> Bool {
        guard machine.isConnected, machine.alarmCode == nil, running == nil, !macro.lines.isEmpty else { return false }
        if machine.jobBlocksCommands { return macro.allowWhileRunning }
        return machine.machineState == .idle
    }

    private func run(_ macro: MachineSettings.Macro) {
        running = macro.id
        Task {
            await machine.runMacro(macro)
            running = nil
        }
    }
}
